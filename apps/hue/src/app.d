// `hue` — the `sparkles:syntax` precise-mode pipeline as an interactive app:
// file → tree-sitter parse → highlights query → event stream → ANSI (stdout)
// or HTML. Grammars come from the nix bundle ($SPARKLES_TS_GRAMMAR_PATH,
// exported by the devshell and baked into the nix package); without it the
// program degrades to plain text — the totality law in action.
//
// Usage: hue [--html] [--theme <theme>] [path] (defaults to this file itself)
//   Interactive TUI (tty, no --html): ↑/↓ to switch themes live; any other key quits.

module app;

import std.array : appender;
import std.file : exists, readText;
import std.path : baseName, extension;
import std.stdio : stderr, write, writef, writeln;

import sparkles.syntax;
import sparkles.core_cli.args;

import sparkles.base.term_control : CtlSeq;
import sparkles.core_cli.key_input : Key, stdioKeySession;
import sparkles.core_cli.term_caps : isTerminal, StdStream, terminalSize;

struct CliParams
{
    @CliOption("html", "Output formatted HTML instead of ANSI terminal escapes.")
    bool html;

    @CliOption("theme", "Syntax highlighting theme name.")
    string theme = "catppuccin-mocha";
}

// `CtlSeq` is a `string`-based enum; `std.stdio.write` formats enums by their
// symbolic member name (e.g. "enterAltScreen"), not the underlying escape
// sequence, so writing one directly silently prints garbage instead of
// control codes. Route every use through an explicit cast to `string`.
void writeCtl(CtlSeq seq)
{
    write(cast(string) seq);
}

// The first `n` lines of `s` (including the newline that ends line `n`), or all
// of `s` when it has fewer. The previewer only ever shows the top of the file,
// so slicing here keeps the highlight fold O(visible lines) instead of
// O(file) — the difference between a 40-line viewport and a multi-thousand-line
// source on every keystroke.
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

int main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "highlight-file",
            "The full precise-mode pipeline: file -> tree-sitter parse -> highlights query -> event stream -> ANSI (stdout) or HTML.",
            null
        )
    );

    bool html = cli.html;
    string themeName = cli.theme;

    string sourcePath = args.length > 1 ? args[1] : __FILE_FULL_PATH__;
    string source = (args.length > 1 || sourcePath.exists) ? readText(sourcePath) : q{
module sample;

import std.stdio : writeln;

void main()
{
    writeln("Hello, syntax!");
    int x = 42;
    if (x > 0)
        writeln("positive");
}
};
    sourcePath = (args.length <= 1 && !sourcePath.exists) ? "sample.d" : sourcePath;
    const lang = canonicalLanguage(sourcePath.extension.length ? sourcePath.extension[1 .. $] : "");

    const labels = LabelSet.standard();

    auto t = themeName in builtinThemes;
    if (!t) stderr.writef("Warning: theme '%s' not found. Falling back to default dark theme.\n", themeName);
    const(Theme)* themeVal = t ? t : &builtinDark;
    const theme = resolveTheme(*themeVal, labels);

    // Engine side: any failure falls back to plain text. Use the injection-aware
    // path so that markdown (and other languages with injections.scm) get their
    // fenced code blocks / inline content highlighted by nested grammars.
    auto events = appender!(HighlightEvent[]);
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);

    auto res = highlightInjected(cache, lang, source, events);
    if (res.hasError)
    {
        stderr.writeln("note: no grammar for '", lang, "' — plain text");
        events ~= HighlightEvent.sourceSpan(0, source.length);
    }

    const interactive = !html &&
        isTerminal(StdStream.stdin) && isTerminal(StdStream.stdout);

    if (!interactive)
    {
        auto output = appender!string;
        if (html)
        {
            import std.format : format;
            string bgStr = theme.defaults.bg.isSet ? format("background: #%02x%02x%02x;", theme.defaults.bg.rgb.r, theme.defaults.bg.rgb.g, theme.defaults.bg.rgb.b) : "";
            string fgStr = theme.defaults.fg.isSet ? format("color: #%02x%02x%02x;", theme.defaults.fg.rgb.r, theme.defaults.fg.rgb.g, theme.defaults.fg.rgb.b) : "";
            output ~= format("<style>\npre { %s %s padding: 1em; }\n", bgStr, fgStr);
            writeThemeStylesheet(theme, output);
            output ~= "</style>\n<pre><code>";
            renderHtml(source, events[], theme, output,
                HtmlOptions(mode: HtmlMode.cssClasses));
            output ~= "</code></pre>\n";
        }
        else
            renderAnsi(source, events[], theme, output,
                AnsiOptions(depth: detectColorDepth(), italics: true, emitBackground: true));

        write(output[]);
        return 0;
    }

    string[] names = builtinThemes.keys.dup;
    import std.algorithm.sorting : sort;
    sort(names);

    size_t idx = 0;
    foreach (i, n; names) if (n == themeName) { idx = i; break; }

    auto sessFactory = stdioKeySession();
    if (sessFactory is null)
    {
        auto output = appender!string;
        renderAnsi(source, events[], theme, output,
            AnsiOptions(depth: detectColorDepth(), italics: true, emitBackground: true));
        write(output[]);
        return 0;
    }
    auto sess = sessFactory();
    scope (exit) sess.finish();

    writeCtl(CtlSeq.enterAltScreen);
    writeCtl(CtlSeq.hideCursor);
    scope (exit)
    {
        writeCtl(CtlSeq.showCursor);
        writeCtl(CtlSeq.exitAltScreen);
    }

    // Emits the SGR transition from `from` to `to` directly to stdout.
    void emitSgr(in StyleSpec from, in StyleSpec to, ColorDepth depth)
    {
        import sparkles.base.smallbuffer : SmallBuffer;
        SmallBuffer!(char, 64) sgr;
        writeStyleTransition(sgr, from, to, depth);
        write(sgr[]);
    }

    // Color depth is a stable property of the session — probe once, not per
    // frame. Resolved themes are memoized: switching revisits themes, and each
    // resolveTheme allocates a fresh label→style table.
    const depth = detectColorDepth();
    ResolvedTheme[string] resolvedCache;

    ref const(ResolvedTheme) resolveCached(string name)
    {
        if (auto r = name in resolvedCache)
            return *r;
        auto tp = name in builtinThemes;
        resolvedCache[name] = resolveTheme(tp ? *tp : builtinDark, labels);
        return resolvedCache[name];
    }

    string lastRendered;
    while (true)
    {
        const cur = names[idx];
        const resolved = resolveCached(cur);
        const chrome = StyleSpec(fg: resolved.defaults.fg, bg: resolved.defaults.bg);

        import std.algorithm.comparison : min;
        const sz = terminalSize();
        enum win = 7;
        const reserved = 4u + win; // header + hint + 2 separators + theme list
        const maxCode = (sz.height > reserved) ? sz.height - reserved : 10;

        // Render only the visible slice: highlighting the whole file every frame
        // and then discarding all but `maxCode` lines was the theme-switch
        // regression (O(file) render + idup + splitLines per keystroke).
        // renderAnsi clamps spans to the sliced length, so the shared event
        // stream needs no filtering.
        const shown = source.firstLines(maxCode);

        import sparkles.base.smallbuffer : SmallBuffer;
        SmallBuffer!(char, 8192) buf;
        renderAnsi(shown, events[], resolved, buf,
            AnsiOptions(depth: depth, italics: true, emitBackground: true));
        lastRendered = buf[].idup;

        import std.string : splitLines;
        auto view = lastRendered.splitLines();

        writeCtl(CtlSeq.syncBegin);
        // Open the theme's fg/bg before erasing: terminals with "back color
        // erase" (xterm, kitty, alacritty, ghostty, iTerm2, Windows Terminal —
        // effectively universal) fill erased cells with the *current* SGR
        // background, so the whole alt-screen viewport picks up the theme's
        // backdrop with no per-line padding needed.
        emitSgr(StyleSpec.init, chrome, depth);
        writeCtl(CtlSeq.eraseDisplay);
        writeCtl(CtlSeq.cursorHome);

        writef(" %s  —  %s (%d/%d)\n", baseName(sourcePath), cur, idx + 1, names.length);
        write(" ↑/↓ switch   any other key quits\n");
        const sepLen = sz.width ? min(60, sz.width) : 60;
        foreach (_; 0 .. sepLen) write('─');
        write('\n');

        // Code lines already carry their own per-span (incl. background)
        // styling — start them from a clean slate rather than the chrome
        // style above.
        emitSgr(chrome, StyleSpec.init, depth);
        foreach (l; view) write(l, "\n");
        emitSgr(StyleSpec.init, chrome, depth);

        foreach (_; 0 .. sepLen) write('─');
        write('\n');

        size_t vs = (idx < win / 2) ? 0 : idx - win / 2;
        vs = (vs + win > names.length) ? (names.length > win ? names.length - win : 0) : vs;
        foreach (i; vs .. (vs + win > names.length ? names.length : vs + win))
            write(i == idx ? "❯ " : "  ", names[i], "\n");

        emitSgr(chrome, StyleSpec.init, depth);
        writeCtl(CtlSeq.syncEnd);

        final switch (sess.next())
        {
            case Key.up:   idx = (idx == 0) ? names.length - 1 : idx - 1; break;
            case Key.down: idx = (idx + 1 == names.length) ? 0 : idx + 1; break;
            case Key.enter, Key.cancel, Key.other:
                goto done;
        }
    }
done:;

    writeCtl(CtlSeq.showCursor);
    writeCtl(CtlSeq.exitAltScreen);
    write(lastRendered);
    return 0;
}
