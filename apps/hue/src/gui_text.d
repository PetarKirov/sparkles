// Pure text-layout logic for the raylib GPU backend (`hue --gui`).
//
// Deliberately raylib-free: this is the app-agnostic core the shared
// `sparkles:raylib-text` library will own after a second caller (apps/terminal)
// validates the boundary (issue #121 M5). Authoring it here — in the library's
// final shape — lets M5 be a move, not a redesign, and lets `dub test :hue`
// exercise the fallback decision, atlas membership, cell-metric guard,
// TextStyle→draw-op mapping, and grapheme encoding with no GL context.
//
// Compiled in every hue configuration EXCEPT `application` (the default terminal
// build has no use for it); the raylib `gui.d` and the `unittest` build both use it.
module gui_text;

@safe:

/// Minimal per-run/per-cell text attributes the renderer honors. Owned here
/// (not by sparkles:syntax) so each caller translates its own vocabulary into
/// it — hue maps `FontStyle`, apps/terminal will map `GhosttyStyle`. Colors are
/// NOT here: the caller resolves fg/bg and passes the raylib color to `drawText`.
struct TextStyle
{
    enum uint bold          = 1 << 0;
    enum uint italic        = 1 << 1;
    enum uint underline     = 1 << 2; /// any underline style collapses to one bit
    enum uint strikethrough = 1 << 3;

    uint bits;

    /// `true` iff every bit of `flag` is set.
    bool has(uint flag) const pure nothrow @nogc => (bits & flag) != 0;
}

/// Which loaded font a codepoint is drawn from.
enum FontSlot
{
    primary, /// the primary monospace face
    regular, /// a regular (non-Nerd) fallback for missing glyphs
    nerd,    /// a Nerd-Font fallback for Private-Use-Area icons
}

/**
The font-fallback decision as a pure function of glyph-presence booleans — the
heart of the per-glyph selection, decoupled from any real `Font`/GL lookup so
it is unit-testable. ASCII always uses the primary; otherwise primary →
regular fallback → Nerd fallback, first that has the glyph, else primary
(raylib renders `?`/tofu rather than crashing — renderers are total).
*/
FontSlot chooseFontSlot(int codepoint,
    bool primaryHasGlyph,
    bool regularAvailable, bool regularHasGlyph,
    bool nerdAvailable, bool nerdHasGlyph) pure nothrow @nogc
{
    if (codepoint < 128)
        return FontSlot.primary;
    if (primaryHasGlyph)
        return FontSlot.primary;
    if (regularAvailable && regularHasGlyph)
        return FontSlot.regular;
    if (nerdAvailable && nerdHasGlyph)
        return FontSlot.nerd;
    return FontSlot.primary;
}

///
@("gui_text.chooseFontSlot.decisionTable")
pure nothrow @nogc
unittest
{
    // ASCII ignores every fallback flag.
    assert(chooseFontSlot('a', false, true, true, true, true) == FontSlot.primary);
    // Non-ASCII the primary has → primary.
    assert(chooseFontSlot(0x2192, true, true, true, true, true) == FontSlot.primary);
    // Primary lacks it, a regular fallback has it → regular.
    assert(chooseFontSlot(0x2192, false, true, true, true, true) == FontSlot.regular);
    // Primary and regular lack it, Nerd has it → nerd.
    assert(chooseFontSlot(0xE0A0, false, true, false, true, true) == FontSlot.nerd);
    // Regular fallback unavailable is skipped even if "has" is spuriously true.
    assert(chooseFontSlot(0xE0A0, false, false, true, true, true) == FontSlot.nerd);
    // Nobody has it → primary (tofu), never a crash.
    assert(chooseFontSlot(0x1F600, false, true, false, true, false) == FontSlot.primary);
}

/// Cell-metric zero-guard: a degenerate font metric of `< 1` px would divide
/// every grid computation by zero, so clamp to 1.
int guardCell(float measured) pure nothrow @nogc
    => measured < 1.0f ? 1 : cast(int) measured;

///
@("gui_text.guardCell.clamp")
pure nothrow @nogc
unittest
{
    assert(guardCell(0) == 1);
    assert(guardCell(0.4f) == 1);
    assert(guardCell(-3) == 1);
    assert(guardCell(12.9f) == 12);
    assert(guardCell(20) == 20);
}

/// The concrete per-glyph draw decisions of the raylib primitive, as pure data
/// so the mapping is testable without GL.
struct GlyphDrawOps
{
    int italicOffset;   /// x-shift for a crude italic slant (raylib can't shear)
    bool fakeBold;      /// redraw one pixel right to thicken strokes
    bool underline;     /// draw an underline rectangle
    bool strikethrough; /// draw a strikethrough rectangle
}

/// Maps a `TextStyle` + font size to the draw operations the primitive performs.
GlyphDrawOps drawOps(TextStyle s, int fontSize) pure nothrow @nogc
    => GlyphDrawOps(
        italicOffset: s.has(TextStyle.italic) ? fontSize / 6 : 0,
        fakeBold: s.has(TextStyle.bold),
        underline: s.has(TextStyle.underline),
        strikethrough: s.has(TextStyle.strikethrough));

///
@("gui_text.drawOps.mapping")
pure nothrow @nogc
unittest
{
    assert(drawOps(TextStyle(0), 18) == GlyphDrawOps(0, false, false, false));

    const italic = drawOps(TextStyle(TextStyle.italic), 18);
    assert(italic.italicOffset == 3 && !italic.fakeBold);

    const all = drawOps(TextStyle(TextStyle.bold | TextStyle.italic
        | TextStyle.underline | TextStyle.strikethrough), 24);
    assert(all == GlyphDrawOps(4, true, true, true));
}

@("gui_text.TextStyle.flags")
pure nothrow @nogc
unittest
{
    const s = TextStyle(TextStyle.bold | TextStyle.underline);
    assert(s.has(TextStyle.bold) && s.has(TextStyle.underline));
    assert(!s.has(TextStyle.italic) && !s.has(TextStyle.strikethrough));
    assert(TextStyle(0).bits == 0 && !TextStyle(0).has(TextStyle.bold));
}

/// The monospace column width of a UTF-8 run: the number of codepoints (each
/// non-continuation byte begins one). A fixed cell advance keeps runs on a
/// perfect grid — unlike `MeasureTextEx`, which sums glyph advances and drifts.
/// Combining marks and wide/tab characters are one column for now (a v1 limit;
/// hue is monospace, fixed-advance).
size_t columnWidth(scope const(char)[] run) pure nothrow @nogc
{
    size_t cols;
    foreach (ubyte c; run)
        if ((c & 0xC0) != 0x80) // not a UTF-8 continuation byte
            ++cols;
    return cols;
}

///
@("gui_text.columnWidth.codepoints")
pure nothrow @nogc
unittest
{
    assert(columnWidth("") == 0);
    assert(columnWidth("main()") == 6);
    assert(columnWidth("  int") == 5);
    // '→' (U+2192) is one 3-byte codepoint → one column.
    assert(columnWidth("a→b") == 3);
    // 'é' as e + U+0301 counts as two columns (no grapheme clustering in v1).
    assert(columnWidth("é") == 2);
}

/// The number of display lines in `source`, matching `byStyledLine`'s line
/// indexing: one per `\n`, plus a final line for trailing content. A trailing
/// newline does not add an empty last line (editor convention); empty source
/// is zero lines. Used for viewport clamping, the gutter, and the scrollbar.
size_t lineCount(scope const(char)[] source) pure nothrow @nogc
{
    if (source.length == 0)
        return 0;
    size_t n;
    foreach (c; source)
        if (c == '\n')
            ++n;
    if (source[$ - 1] != '\n')
        ++n;
    return n;
}

///
@("gui_text.lineCount.conventions")
pure nothrow @nogc
unittest
{
    assert(lineCount("") == 0);
    assert(lineCount("a") == 1);
    assert(lineCount("a\n") == 1);      // trailing newline is not an extra line
    assert(lineCount("a\nb") == 2);
    assert(lineCount("a\nb\n") == 2);
    assert(lineCount("\n") == 1);       // one (empty) line before the newline
    assert(lineCount("\n\n") == 2);
}

/// An inclusive codepoint range in the glyph atlas.
struct CodepointRange
{
    int lo, hi;
}

/// The single source of truth for the glyph atlas passed to `LoadFontEx`:
/// ASCII + Latin-1, General Punctuation through Miscellaneous Symbols & Arrows,
/// and the Nerd-Font Private-Use-Area ranges (Powerline, Font Awesome,
/// Devicons, …). Lifted verbatim from apps/terminal's `getRequiredCodepoints`.
static immutable CodepointRange[] atlasRanges = [
    CodepointRange(0x20, 0xFF),
    CodepointRange(0x2000, 0x2BFF),
    CodepointRange(0xE0A0, 0xE0D4),
    CodepointRange(0xE200, 0xE2A9),
    CodepointRange(0xE300, 0xE3E3),
    CodepointRange(0xE5FA, 0xE6B1),
    CodepointRange(0xE700, 0xE7C5),
    CodepointRange(0xF000, 0xF2E0),
    CodepointRange(0xF300, 0xF372),
    CodepointRange(0xF400, 0xF533),
    CodepointRange(0xF500, 0xFD46),
];

/// `true` iff `cp` is in the glyph atlas — the pure membership test.
bool isRequiredCodepoint(int cp) pure nothrow @nogc
{
    foreach (r; atlasRanges)
        if (cp >= r.lo && cp <= r.hi)
            return true;
    return false;
}

/// The flattened atlas passed to `LoadFontEx`. GC array, built once at startup.
int[] getRequiredCodepoints() nothrow
{
    size_t total;
    foreach (r; atlasRanges)
        total += r.hi - r.lo + 1;

    auto cps = new int[](total);
    size_t n;
    foreach (r; atlasRanges)
        for (int cp = r.lo; cp <= r.hi; ++cp)
            cps[n++] = cp;
    return cps;
}

///
@("gui_text.atlas.membershipAndFlatten")
unittest
{
    // Boundary membership.
    assert(isRequiredCodepoint(0x20) && isRequiredCodepoint(0xFF));
    assert(isRequiredCodepoint(0x2000) && isRequiredCodepoint(0x2BFF));
    assert(isRequiredCodepoint(0xE0A0) && isRequiredCodepoint(0xF533));
    // Gaps between ranges are absent.
    assert(!isRequiredCodepoint(0x1000));
    assert(!isRequiredCodepoint(0x2C00));
    assert(!isRequiredCodepoint(0xE0D5));

    // The flattened list matches the summed range widths (the last two Nerd
    // ranges overlap in the verbatim terminal atlas, so entries are not unique
    // nor globally sorted — LoadFontEx tolerates the duplicates) and every
    // entry is a member.
    const cps = getRequiredCodepoints();
    size_t expected;
    foreach (r; atlasRanges)
        expected += r.hi - r.lo + 1;
    assert(cps.length == expected);

    import std.algorithm.searching : all;
    assert(cps.all!(cp => isRequiredCodepoint(cp)));
}

/**
Encodes a grapheme cluster (base codepoint plus any combining marks, ZWJ
joiners, variation selectors — at most 16) into a single NUL-terminated UTF-8
buffer, so raylib's `DrawTextEx` draws it as one unit (drawing only the base
would drop accents and emoji modifiers). Invalid codepoints become U+FFFD;
overflow of the 64-byte buffer stops cleanly. Returns the slice up to (not
including) the terminating NUL — `result.ptr[result.length] == '\0'`.

Not used by hue's per-run drawing (it copies whole runs), but it is the
terminal's per-cell need and belongs to the same shared primitive; authored
here so M5 extracts it with its test intact.
*/
const(char)[] encodeGraphemeCluster(scope const(uint)[] codepoints, return ref char[64] buf)
    pure nothrow @nogc
{
    import std.utf : encode;
    import std.typecons : Yes;

    size_t len;
    const n = codepoints.length < 16 ? codepoints.length : 16;
    foreach (i; 0 .. n)
    {
        char[4] u8 = void;
        const u8n = encode!(Yes.useReplacementDchar)(u8, cast(dchar) codepoints[i]);
        if (len + u8n >= buf.length) // keep room for the NUL
            break;
        buf[len .. len + u8n] = u8[0 .. u8n];
        len += u8n;
    }
    buf[len] = '\0';
    return buf[0 .. len];
}

///
@("gui_text.encodeGraphemeCluster.cases")
pure nothrow @nogc
unittest
{
    char[64] buf = void;

    // ASCII base.
    assert(encodeGraphemeCluster([cast(uint) 'M'], buf) == "M");
    assert(buf[1] == '\0'); // NUL-terminated right after

    // Base + combining acute (é as e + U+0301): both codepoints present.
    const acute = encodeGraphemeCluster([cast(uint) 'e', 0x0301], buf);
    assert(acute.length == 3 && acute[0] == 'e'); // 'e' + 2-byte U+0301
    assert(buf[acute.length] == '\0');

    // More than 16 codepoints is truncated at 16.
    uint[32] many = 'a';
    const capped = encodeGraphemeCluster(many[], buf);
    assert(capped.length == 16);

    // Buffer overflow stops cleanly with a valid NUL (all 3-byte glyphs).
    uint[64] wide = 0x2192; // '→', 3 bytes each
    const clipped = encodeGraphemeCluster(wide[], buf);
    assert(clipped.length < buf.length && buf[clipped.length] == '\0');
}
