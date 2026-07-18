// The interactive live theme previewer's allocation-free core.
//
// Startup (file read, tree-sitter parse, building the theme list) is GC and
// lives in `app.d`; everything here — building a frame and pushing it to the
// terminal, plus the key-driven loop — is `@nogc nothrow`, so a theme switch
// never triggers a GC pause. The whole frame is assembled into one reused
// `SmallBuffer` and flushed with a single `fwrite`; the theme is re-resolved
// into one reused stack buffer on change (see `writeThemeStyles`).
module previewer;

import core.stdc.stdio : FILE, fflush, fwrite;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_control : CtlSeq;
import sparkles.base.styled_template : writeStyled;

import sparkles.syntax : AnsiOptions, ColorDepth, HighlightEvent, LabelSet,
    renderAnsi, ResolvedTheme, StyleSpec, Theme,
    writeStyleTransition, writeThemeStyles;

import sparkles.core_cli.key_input : Key, KeySession;
import sparkles.core_cli.term_caps : StdStream, terminalSize;

/// The first `n` lines of `s` (including the newline that ends line `n`), or all
/// of `s` when it has fewer. The previewer only shows the top of the file, so
/// slicing here keeps the highlight fold O(visible lines), not O(file).
const(char)[] firstLines(return scope const(char)[] s, size_t n) @safe pure nothrow @nogc
{
    if (n == 0)
        return s;
    size_t seen = 0;
    foreach (i, char c; s)
        if (c == '\n' && ++seen == n)
            return s[0 .. i + 1];
    return s;
}

/// A minimal `@nogc` byte sink over a C `FILE*` (stdout). One `put` + `flush`
/// per frame keeps the whole repaint to a single write; `fwrite` short-writes
/// are looped over (mirrors `sparkles.base.logger`'s `fwriteAll`).
struct TermOut
{
    private FILE* fp;

    /// A sink writing to C stdout.
    static TermOut standard() @trusted @nogc nothrow
    {
        import core.stdc.stdio : stdout;

        return TermOut(stdout);
    }

    /// Writes all of `data`, looping over partial `fwrite`s.
    void put(scope const(char)[] data) @trusted @nogc nothrow
    {
        size_t off = 0;
        while (off < data.length)
        {
            const n = fwrite(data.ptr + off, 1, data.length - off, fp);
            if (n == 0)
                break; // write error; nothing a nothrow sink can do
            off += n;
        }
    }

    /// Emits a fixed control sequence (a `string`-typed enum).
    void put(CtlSeq seq) @trusted @nogc nothrow
    {
        put(cast(string) seq);
    }

    void flush() @trusted @nogc nothrow
    {
        fflush(fp);
    }
}

/// The reusable previewer state: parsed source + events, the theme list, and
/// the reused frame/style buffers. Built once at startup, then driven by
/// `runLoop`. `themes[idx]` and `names[idx]` are parallel.
struct Previewer
{
    string title;                 /// file base name shown in the header
    const(char)[] source;         /// the whole file (rendered viewport-sliced)
    const(HighlightEvent)[] events; /// parsed once; re-rendered per frame
    LabelSet labels;              /// the vocabulary `styleBuf` is sized against
    const(string)[] names;        /// sorted theme names (parallel to `themes`)
    immutable(Theme)[] themes;    /// theme data (parallel to `names`)

    // Reused per-frame scratch — no per-frame heap (spills to malloc, never GC,
    // only on very large terminals).
    private SmallBuffer!(char, 16384) frame;
    private SmallBuffer!(StyleSpec, 128) styleBuf; /// current resolved theme's table
    private StyleSpec resolvedDefaults;
    private size_t resolvedIdx = size_t.max; /// which theme is in styleBuf
    private size_t codeStart, codeEnd;       /// the code slice within `frame`

    /// The theme count (rows to page through).
    size_t themeCount() const @safe pure nothrow @nogc => names.length;

    /// The last-rendered highlighted code, sliced out of `frame` — written to
    /// the primary screen after the alt screen is left.
    const(char)[] lastCode() const @safe pure nothrow @nogc
        => frame[][codeStart .. codeEnd];

    /// Renders the $(I entire) source with theme `idx` into the frame buffer and
    /// returns the bytes — used to print the whole highlighted file to the
    /// primary screen once the user selects a theme (Enter), rather than the
    /// viewport slice `buildFrame` shows. `@nogc` (the buffer spills to malloc,
    /// never the GC, for a large file).
    const(char)[] renderFull(size_t idx, ColorDepth depth) @safe @nogc nothrow
    {
        const theme = themeView(idx);
        frame.clear();
        renderAnsi(source, events, theme, frame,
            AnsiOptions(depth: depth, italics: true, emitBackground: true));
        return frame[];
    }

    /// Resolves theme `idx` into the reused `styleBuf` (only when it changed)
    /// and returns a `ResolvedTheme` borrowing it. The borrow is sound because
    /// renderAnsi takes `in ResolvedTheme` and never escapes the slice, and the
    /// buffer is only rewritten on the next theme change.
    private ResolvedTheme themeView(size_t idx) @safe @nogc nothrow
    in (idx < names.length)
    {
        if (idx != resolvedIdx)
        {
            styleBuf.clear();
            styleBuf.writeThemeStyles(themes[idx], labels, resolvedDefaults);
            resolvedIdx = idx;
        }
        return () @trusted {
            return ResolvedTheme(labels,
                cast(immutable(StyleSpec)[]) styleBuf[],
                resolvedDefaults);
        }();
    }

    /// Builds the whole frame for theme `idx` into `frame` (`@nogc nothrow`):
    /// sync markers, the theme backdrop via back-color-erase, header, the
    /// highlighted viewport, and the theme-list window.
    void buildFrame(size_t idx, ushort width, ushort height, ColorDepth depth)
        @safe @nogc nothrow
    in (idx < names.length)
    {
        import std.algorithm.comparison : min;

        const theme = themeView(idx);
        const chrome = StyleSpec(fg: resolvedDefaults.fg, bg: resolvedDefaults.bg);

        enum win = 7;
        const reserved = 4u + win; // header + hint + 2 separators + theme list
        const maxCode = (height > reserved) ? height - reserved : 10;
        const shown = source.firstLines(maxCode);
        const sepLen = width ? min(60, cast(size_t) width) : 60;

        frame.clear();
        frame.put(CtlSeq.syncBegin);
        // Open the theme fg/bg before erasing: terminals with back-color-erase
        // fill erased cells with the current SGR background, so the whole
        // viewport picks up the theme backdrop with no per-line padding.
        writeStyleTransition(frame, StyleSpec.init, chrome, depth);
        frame.put(CtlSeq.eraseDisplay);
        frame.put(CtlSeq.cursorHome);

        // Header + hint.
        writeStyled(frame, i" $(title)  —  $(names[idx]) ($(idx + 1)/$(names.length))\n");
        frame.put(" ↑/↓ switch   enter: print full file   any other key: quit\n");
        putSeparator(sepLen);

        // Code lines carry their own per-span styling — start from a clean slate.
        writeStyleTransition(frame, chrome, StyleSpec.init, depth);
        codeStart = frame[].length;
        renderAnsi(shown, events, theme, frame,
            AnsiOptions(depth: depth, italics: true, emitBackground: true));
        codeEnd = frame[].length;
        writeStyleTransition(frame, StyleSpec.init, chrome, depth);

        putSeparator(sepLen);

        // The scrolling theme-list window around `idx`.
        size_t vs = (idx < win / 2) ? 0 : idx - win / 2;
        vs = (vs + win > names.length) ? (names.length > win ? names.length - win : 0) : vs;
        foreach (i; vs .. (vs + win > names.length ? names.length : vs + win))
        {
            frame.put(i == idx ? "❯ " : "  ");
            frame.put(names[i]);
            frame.put("\n");
        }

        writeStyleTransition(frame, chrome, StyleSpec.init, depth);
        frame.put(CtlSeq.syncEnd);
    }

    private void putSeparator(size_t n) @safe @nogc nothrow
    {
        foreach (_; 0 .. n)
            frame.put("─");
        frame.put("\n");
    }

    /// The assembled frame bytes (valid until the next `buildFrame`).
    const(char)[] frameBytes() const @safe pure nothrow @nogc => frame[];
}

/// How the previewer loop ended: the theme `idx` last shown, and whether the
/// user `selected` it (pressed Enter) versus quit/aborted (any other key).
struct LoopResult
{
    size_t idx;
    bool selected;
}

/// The interactive core: repaint, flush, read a key, repeat — `@nogc nothrow`,
/// so a theme switch allocates nothing. `@system` only because raw terminal I/O
/// (the key delegate, `fwrite`) is inherently unsafe. `idx` starts at the
/// caller's chosen theme.
LoopResult runLoop(ref Previewer prev, ref TermOut sink, ref KeySession sess,
    size_t idx, ColorDepth depth) @system @nogc nothrow
{
    while (true)
    {
        const sz = terminalSize(StdStream.stdout);
        prev.buildFrame(idx, sz.width, sz.height, depth);
        sink.put(prev.frameBytes());
        sink.flush();

        final switch (sess.next())
        {
            case Key.up:
                idx = (idx == 0) ? prev.themeCount() - 1 : idx - 1;
                break;
            case Key.down:
                idx = (idx + 1 == prev.themeCount()) ? 0 : idx + 1;
                break;
            case Key.enter:
                return LoopResult(idx, true);   // select → print the full file
            case Key.cancel, Key.other:
                return LoopResult(idx, false);  // quit → print nothing
        }
    }
}

version (unittest)
{
    import sparkles.syntax : builtinDark;

    // A minimal previewer over a tiny source and two (identical) themes.
    private Previewer testPreviewer()
    {
        static immutable src = "module x;\nint y = 42;\n// note\n";
        static HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
        static immutable(Theme)[2] themes = [builtinDark, builtinDark];
        static immutable string[2] names = ["catppuccin-mocha", "dracula"];

        Previewer prev;
        prev.title = "sample.d";
        prev.source = src;
        prev.events = ev[];
        prev.labels = LabelSet.standard();
        prev.names = names[];
        prev.themes = themes[];
        return prev;
    }
}

@("previewer.buildFrame.structure")
@system
unittest
{
    import std.algorithm.searching : canFind;

    auto prev = testPreviewer();
    prev.buildFrame(0, 80, 24, ColorDepth.trueColor);
    const f = prev.frameBytes();

    assert(f.canFind("\x1b[?2026h"), "syncBegin missing");   // begin sync
    assert(f.canFind("\x1b[?2026l"), "syncEnd missing");     // end sync
    assert(f.canFind("\x1b[2J"), "eraseDisplay missing");    // back-color-erase
    assert(f.canFind("catppuccin-mocha"), "theme name missing"); // header + list
    assert(f.canFind("sample.d"), "title missing");
    assert(prev.lastCode().length > 0, "no code slice recorded");
    // The code slice sits inside the frame and highlights the source.
    assert(f.canFind(prev.lastCode()));
}

@("previewer.buildFrame.steadyStateZeroAlloc")
@system
unittest
{
    import core.memory : GC;

    auto prev = testPreviewer();

    // Warm up: grow the frame buffer and resolve both themes once.
    foreach (i; 0 .. 4)
        prev.buildFrame(i % 2, 80, 24, ColorDepth.trueColor);

    const before = GC.stats.allocatedInCurrentThread;
    foreach (i; 0 .. 16)
        prev.buildFrame(i % 2, 80, 24, ColorDepth.trueColor);
    const delta = GC.stats.allocatedInCurrentThread - before;
    assert(delta == 0, "buildFrame is not zero-GC in steady state");
}

@("previewer.renderFull.coversWholeFile")
@system
unittest
{
    import std.algorithm.searching : canFind;

    // A source taller than a small viewport, with a distinctive last line.
    static immutable src = "a0\na1\na2\na3\na4\na5\na6\na7\na8\nLAST_LINE\n";
    static HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    Previewer prev;
    prev.title = "t";
    prev.source = src;
    prev.events = ev[];
    prev.labels = LabelSet.standard();
    prev.names = names[];
    prev.themes = themes[];

    // height 14 → reserved 11 → maxCode 3 visible lines: the viewport truncates.
    prev.buildFrame(0, 40, 14, ColorDepth.trueColor);
    assert(!prev.lastCode().canFind("LAST_LINE"), "viewport should truncate");

    const full = prev.renderFull(0, ColorDepth.trueColor);
    assert(full.canFind("a0") && full.canFind("LAST_LINE"),
        "renderFull must cover the whole file");
}
