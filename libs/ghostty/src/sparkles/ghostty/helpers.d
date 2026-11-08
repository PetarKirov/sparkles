/**
 * D conveniences over the libghostty-vt 1.0 C API: terminal creation with an
 * explicit scrollback bound, typed mode access, type-checked effect
 * callbacks, the `GhosttyStyle` flag word, and the Kitty layer masks.
 *
 * Everything here is a thin seam over `sparkles.ghostty.c`; the C header stays
 * the single source of layout and enum values. Function-like C macros
 * (`GHOSTTY_STYLE_UNDERLINE`, `GHOSTTY_IMAGE_LAYER_MASK_*`) are re-expressed
 * from their header definitions, which ImportC cannot import.
 */
module sparkles.ghostty.helpers;

import sparkles.ghostty.c;

version (unittest) private
{
    GhosttyTerminal feed(GhosttyTerminal t, in char[] bytes) @system nothrow @nogc
    {
        ghostty_terminal_vt_write(t, cast(const(ubyte)*) bytes.ptr, bytes.length);
        return t;
    }

    size_t totalRows(GhosttyTerminal t) @system nothrow @nogc
    {
        GhosttyTerminalScrollbar bar;
        assert(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) == GHOSTTY_SUCCESS);
        return cast(size_t) bar.total;
    }
}

// ─── Terminal ───────────────────────────────────────────────────────────────

/**
 * Creates a `cols` × `rows` terminal keeping about `scrollbackLines` lines of
 * history: `0` keeps none, `size_t.max` keeps everything.
 *
 * libghostty-vt 1.0 bounds history by bytes (10,000 by default, about one
 * page) as well as by lines; the byte bound is lifted here so the line bound
 * alone decides, which is what the pre-1.0 `max_scrollback` option did. On
 * failure `*terminal` is left `null`.
 */
GhosttyResult newTerminal(GhosttyTerminal* terminal, ushort cols, ushort rows,
    size_t scrollbackLines = 0, GhosttyAllocator* allocator = null)
    @system nothrow @nogc
{
    auto r = ghostty_terminal_new(allocator, terminal, cols, rows);
    if (r != GHOSTTY_SUCCESS)
        return r;
    size_t bytes = scrollbackLines == 0 ? 0 : size_t.max;
    r = ghostty_terminal_set(*terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes);
    if (r == GHOSTTY_SUCCESS && scrollbackLines != 0)
        r = ghostty_terminal_set(*terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            &scrollbackLines);
    if (r != GHOSTTY_SUCCESS)
    {
        ghostty_terminal_free(*terminal);
        *terminal = null;
    }
    return r;
}

///
@("ghostty.helpers.newTerminal.scrollbackBound")
@system nothrow @nogc
unittest
{
    // 400 short lines: far past the 1.0 byte default of about one page.
    static immutable char[400 * 2] lines = () {
        char[400 * 2] b;
        foreach (i; 0 .. 400)
            b[2 * i .. 2 * i + 2] = "x\n";
        return b;
    }();

    GhosttyTerminal all, none;
    assert(newTerminal(&all, 10, 4, size_t.max) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(all);
    assert(newTerminal(&none, 10, 4) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(none);

    assert(all.feed(lines).totalRows >= 400, "unbounded history keeps every line");
    assert(none.feed(lines).totalRows == 4, "no history keeps only the screen");
}

/// Reads the current value of `mode` into `*value`.
GhosttyResult terminalModeGet(GhosttyTerminal terminal, GhosttyMode mode, bool* value)
    @system nothrow @nogc
{
    GhosttyTerminalModeConfig c = { mode: mode };
    const r = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &c);
    if (r == GHOSTTY_SUCCESS)
        *value = c.value;
    return r;
}

/// Sets the current value of `mode`; a reset restores its default.
GhosttyResult terminalModeSet(GhosttyTerminal terminal, GhosttyMode mode, bool value)
    @system nothrow @nogc
{
    GhosttyTerminalModeConfig c = { mode: mode, value: value };
    return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &c);
}

/// Sets both the current value of `mode` and the value a reset (RIS) restores.
GhosttyResult terminalModeSetDefault(GhosttyTerminal terminal, GhosttyMode mode, bool value)
    @system nothrow @nogc
{
    GhosttyTerminalModeConfig c = { mode: mode, value: value };
    return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &c);
}

///
@("ghostty.helpers.terminalMode.roundTripAndReset")
@system nothrow @nogc
unittest
{
    GhosttyTerminal t;
    assert(newTerminal(&t, 10, 2) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(t);

    bool on = true;
    assert(terminalModeGet(t, GHOSTTY_MODE_BRACKETED_PASTE, &on) == GHOSTTY_SUCCESS && !on);
    assert(terminalModeSet(t, GHOSTTY_MODE_BRACKETED_PASTE, true) == GHOSTTY_SUCCESS);
    assert(terminalModeGet(t, GHOSTTY_MODE_BRACKETED_PASTE, &on) == GHOSTTY_SUCCESS && on);
    t.feed("\x1bc"); // RIS restores the default
    assert(terminalModeGet(t, GHOSTTY_MODE_BRACKETED_PASTE, &on) == GHOSTTY_SUCCESS && !on);

    assert(terminalModeSetDefault(t, GHOSTTY_MODE_GRAPHEME_CLUSTER, true) == GHOSTTY_SUCCESS);
    t.feed("\x1bc");
    assert(terminalModeGet(t, GHOSTTY_MODE_GRAPHEME_CLUSTER, &on) == GHOSTTY_SUCCESS && on,
        "a reset default survives RIS");
}

/// The callback type `ghostty_terminal_set` expects for effect option `opt`.
template EffectFn(GhosttyTerminalOption opt)
{
    static if (opt == GHOSTTY_TERMINAL_OPT_WRITE_PTY) alias EffectFn = GhosttyTerminalWritePtyFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_BELL) alias EffectFn = GhosttyTerminalBellFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_ENQUIRY) alias EffectFn = GhosttyTerminalEnquiryFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_XTVERSION) alias EffectFn = GhosttyTerminalXtversionFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_TITLE_CHANGED) alias EffectFn = GhosttyTerminalTitleChangedFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_PWD_CHANGED) alias EffectFn = GhosttyTerminalPwdChangedFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_SIZE) alias EffectFn = GhosttyTerminalSizeFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_COLOR_SCHEME) alias EffectFn = GhosttyTerminalColorSchemeFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES) alias EffectFn = GhosttyTerminalDeviceAttributesFn;
    else static if (opt == GHOSTTY_TERMINAL_OPT_RENDER_HOLD) alias EffectFn = GhosttyTerminalRenderHoldFn;
    else static assert(0, "no callback type mapped for this terminal option");
}

/**
 * Installs effect callback `fn` for option `opt`, rejecting at compile time a
 * function whose signature differs from the header's typedef. (The C setter
 * takes a `const void*`, so a plain call would accept any function.) `null`
 * removes the callback.
 */
GhosttyResult setEffect(GhosttyTerminalOption opt, F)(GhosttyTerminal terminal, F fn)
{
    static assert(is(F : EffectFn!opt) || is(F == typeof(null)),
        "effect callback " ~ F.stringof ~ " does not match " ~ EffectFn!opt.stringof);
    return (() @trusted => ghostty_terminal_set(terminal, opt, cast(const(void)*) fn))();
}

///
@("ghostty.helpers.setEffect.checksTheSignature")
@system nothrow @nogc
unittest
{
    static extern (C) void bell(GhosttyTerminal, void*) nothrow @nogc {}
    static extern (C) void wrong(GhosttyTerminal, void*, int) nothrow @nogc {}

    GhosttyTerminal t;
    assert(newTerminal(&t, 10, 2) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(t);
    assert(t.setEffect!GHOSTTY_TERMINAL_OPT_BELL(&bell) == GHOSTTY_SUCCESS);
    assert(t.setEffect!GHOSTTY_TERMINAL_OPT_BELL(null) == GHOSTTY_SUCCESS);
    static assert(!__traits(compiles, t.setEffect!GHOSTTY_TERMINAL_OPT_BELL(&wrong)));
}

// ─── Formatter ──────────────────────────────────────────────────────────────

/**
 * Creates a plain-text formatter over `terminal`: soft-wrapped rows joined
 * when `unwrap`, trailing blanks dropped when `trim`, only `*selection` when
 * one is given (else scrollback and screen). On failure `*formatter` is left
 * `null`.
 */
GhosttyResult newPlainFormatter(GhosttyFormatter* formatter, GhosttyTerminal terminal,
    bool unwrap, bool trim = true, const(GhosttySelection)* selection = null)
    @system nothrow @nogc
{
    auto r = ghostty_formatter_terminal_new(null, formatter, terminal);
    if (r != GHOSTTY_SUCCESS)
        return r;
    GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    if ((r = ghostty_formatter_set(*formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)) == GHOSTTY_SUCCESS
        && (r = ghostty_formatter_set(*formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap)) == GHOSTTY_SUCCESS
        && (r = ghostty_formatter_set(*formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim)) == GHOSTTY_SUCCESS
        && selection !is null)
        r = ghostty_formatter_set(*formatter, GHOSTTY_FORMATTER_OPT_SELECTION, selection);
    if (r != GHOSTTY_SUCCESS)
    {
        ghostty_formatter_free(*formatter);
        *formatter = null;
    }
    return r;
}

///
@("ghostty.helpers.newPlainFormatter.wholeScreenAndSelection")
@system nothrow @nogc
unittest
{
    GhosttyTerminal t;
    assert(newTerminal(&t, 5, 2) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(t);
    t.feed("abcdefg");

    char[32] buf;
    const(char)[] format(bool unwrap, const(GhosttySelection)* sel = null)
    {
        GhosttyFormatter f;
        assert(newPlainFormatter(&f, t, unwrap, true, sel) == GHOSTTY_SUCCESS);
        scope (exit) ghostty_formatter_free(f);
        size_t n;
        assert(ghostty_formatter_format_buf(f, cast(ubyte*) buf.ptr, buf.length, &n)
            == GHOSTTY_SUCCESS);
        return buf[0 .. n];
    }
    assert(format(true) == "abcdefg");
    assert(format(false) == "abcde\nfg");

    GhosttySelection sel;
    GhosttyPoint p0 = { tag: GHOSTTY_POINT_TAG_ACTIVE, value: { coordinate: { x: 1, y: 0 } } };
    GhosttyPoint p1 = { tag: GHOSTTY_POINT_TAG_ACTIVE, value: { coordinate: { x: 2, y: 0 } } };
    assert(ghostty_terminal_grid_ref(t, p0, &sel.start) == GHOSTTY_SUCCESS);
    assert(ghostty_terminal_grid_ref(t, p1, &sel.end) == GHOSTTY_SUCCESS);
    assert(format(true, &sel) == "bc");
}

// ─── Style ──────────────────────────────────────────────────────────────────

// Read through UFCS (`style.bold`), these keep the field-style spelling of
// the pre-1.0 `GhosttyStyle`, whose booleans are now bits of `flags`.
@safe pure nothrow @nogc
{
    bool bold(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_BOLD) != 0; ///
    bool italic(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_ITALIC) != 0; ///
    bool faint(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_FAINT) != 0; ///
    bool blink(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_BLINK) != 0; ///
    bool inverse(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_INVERSE) != 0; ///
    bool invisible(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_INVISIBLE) != 0; ///
    bool strikethrough(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) != 0; ///
    bool overline(in GhosttyStyle s) => (s.flags & GHOSTTY_STYLE_FLAG_OVERLINE) != 0; ///

    /// The underline kind (`GHOSTTY_SGR_UNDERLINE_*`), `GHOSTTY_STYLE_UNDERLINE`.
    int underline(in GhosttyStyle s)
        => (s.flags & GHOSTTY_STYLE_UNDERLINE_MASK) >> GHOSTTY_STYLE_UNDERLINE_SHIFT;
}

///
@("ghostty.helpers.style.flagAccessors")
@system nothrow @nogc
unittest
{
    GhosttyTerminal t;
    assert(newTerminal(&t, 10, 2) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(t);
    t.feed("\x1b[1;3;7;9;4:3mx");

    GhosttyPoint p = { tag: GHOSTTY_POINT_TAG_ACTIVE };
    GhosttyGridRef r;
    GhosttyStyle s;
    assert(ghostty_terminal_grid_ref(t, p, &r) == GHOSTTY_SUCCESS);
    assert(ghostty_grid_ref_style(&r, &s) == GHOSTTY_SUCCESS);
    assert(s.bold && s.italic && s.inverse && s.strikethrough);
    assert(!s.faint && !s.blink && !s.invisible && !s.overline);
    assert(s.underline == GHOSTTY_SGR_UNDERLINE_CURLY);
}

// ─── Kitty graphics ─────────────────────────────────────────────────────────

/// The `GHOSTTY_IMAGE_LAYER_MASK_*` bit for `layer`.
uint layerMask(GhosttyImageLayer layer) @safe pure nothrow @nogc => 1u << layer;

/// The mask `GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER` reads as "every layer".
enum uint allLayers = 0;
