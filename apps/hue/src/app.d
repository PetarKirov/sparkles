// `hue` — the `sparkles:syntax` precise-mode pipeline as an interactive app:
// file → tree-sitter parse → highlights query → event stream → ANSI (stdout)
// or HTML. Grammars come from the nix bundle ($SPARKLES_TS_GRAMMAR_PATH,
// exported by the devshell and baked into the nix package); without it the
// program degrades to plain text — the totality law in action.
//
// Usage: hue [--html] [--theme <theme>] [path] (defaults to this file itself)
//   Interactive TUI (tty, no --html): ↑/↓ to switch themes live; any other key quits.
//
// Startup here is GC (CLI parse, file read, tree-sitter parse, theme list); the
// interactive render/output core lives in `previewer.d` and is @nogc.

module app;

import std.array : appender;
import std.file : exists, readText;
import std.path : baseName, extension;
import std.stdio : stderr, write, writef, writeln;

import sparkles.syntax;
import sparkles.core_cli.args;

import sparkles.base.term_control : CtlSeq;
import sparkles.core_cli.key_input : stdioKeySession;
import sparkles.core_cli.term_caps : isTerminal, StdStream;

import previewer : Previewer, runLoop, TermOut;

struct CliParams
{
    @CliOption("html", "Output formatted HTML instead of ANSI terminal escapes.")
    bool html;

    @CliOption("theme", "Syntax highlighting theme name.")
    string theme = "catppuccin-mocha";
}

int main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "hue",
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

    // Sorted theme names, plus the parallel theme values the previewer indexes
    // per frame (avoids per-frame GC AA lookups; `.keys` already returns a
    // fresh array, so no `.dup`).
    string[] names = builtinThemes.keys;
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : map;
    import std.array : array;
    sort(names);
    immutable(Theme)[] themes = names.map!(n => *(n in builtinThemes)).array;

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

    const depth = detectColorDepth();
    auto prev = Previewer(
        title: baseName(sourcePath),
        source: source,
        events: events[],
        labels: labels,
        names: names,
        themes: themes,
    );

    auto sink = TermOut.standard();
    sink.put(CtlSeq.enterAltScreen);
    sink.put(CtlSeq.hideCursor);
    sink.flush();

    runLoop(prev, sink, sess, idx, depth);

    // Restore the terminal, then leave the last highlighted frame on the primary
    // screen (the alt screen's contents are discarded on exit).
    sink.put(CtlSeq.showCursor);
    sink.put(CtlSeq.exitAltScreen);
    sink.put(prev.lastCode());
    sink.flush();
    return 0;
}
