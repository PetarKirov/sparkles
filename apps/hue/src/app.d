/**
`hue` — an interactive syntax-highlighting file viewer and live theme previewer.

Highlights a source file in the terminal (ANSI) or as HTML. In a tty it opens a
live previewer: browse the built-in themes with ↑/↓, and press Enter to print
the whole file in the chosen theme.

    hue [--html] [--theme <name>] [path]

With no path, `hue` highlights its own source.

$(B Implementation:) the full `sparkles:syntax` precise pipeline (tree-sitter
parse → highlights query → event stream → ANSI/HTML renderer). Grammars come
from the nix bundle ($SPARKLES_TS_GRAMMAR_PATH); without it the program degrades
to plain text. Startup is GC; the interactive render/output core
($(MREF previewer)) is `@nogc`.
*/
module app;

import std.file : readText;
import std.path : baseName, extension;
import std.stdio : write;
import std.string : chompPrefix;

import sparkles.syntax;
import sparkles.core_cli.args;

import sparkles.base.logger : initLogger, LogLevel, warning;
import sparkles.base.smallbuffer : SmallBuffer;
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
            "Highlight a source file in the terminal or as HTML, or browse syntax themes live.",
            null
        )
    );

    initLogger(LogLevel.warning); // hue only emits degradation warnings

    bool html = cli.html;
    string themeName = cli.theme;

    // With a path argument, highlight that file; otherwise highlight hue's own
    // source, embedded at compile time via `import()`. That works from any
    // install location — the build-time `__FILE_FULL_PATH__` would not exist in
    // a released (nix-packaged or copied) binary.
    const hasFile = args.length > 1;
    const sourcePath = hasFile ? args[1] : "app.d";
    const source = hasFile ? readText(sourcePath) : import("app.d");
    const lang = canonicalLanguage(sourcePath.extension.chompPrefix("."));

    const labels = LabelSet.standard();

    // `.get`'s default is `lazy`, so the warning fires only on a miss.
    const theme = resolveTheme(builtinThemes.get(themeName, {
            warning(i"theme '$(themeName)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    // Engine side: any failure falls back to plain text. Use the injection-aware
    // path so that markdown (and other languages with injections.scm) get their
    // fenced code blocks / inline content highlighted by nested grammars.
    SmallBuffer!HighlightEvent events;
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);

    auto res = highlightInjected(cache, lang, source, events);
    if (res.hasError)
    {
        warning(i"no grammar for '$(lang)' — rendering as plain text");
        events ~= HighlightEvent.sourceSpan(0, source.length);
    }

    // Render the whole file to ANSI and write it — used by both non-interactive
    // paths (piped/redirected output, and no key session available).
    int emitAnsiWholeFile()
    {
        SmallBuffer!char output;
        renderAnsi(source, events[], theme, output,
            AnsiOptions(depth: detectColorDepth(), italics: true, emitBackground: true));
        write(output[]);
        return 0;
    }

    const interactive = !html &&
        isTerminal(StdStream.stdin) && isTerminal(StdStream.stdout);

    if (!interactive)
    {
        if (html)
        {
            // The `.syn-root` rule writeThemeStylesheet emits carries the
            // default fg/bg; give the wrapper that class so it applies, instead
            // of re-deriving the same colors into a duplicate `pre {}` rule.
            SmallBuffer!char output;
            output ~= "<style>\npre { padding: 1em; }\n";
            writeThemeStylesheet(theme, output);
            output ~= "</style>\n<pre class=\"syn-root\"><code>";
            renderHtml(source, events[], theme, output,
                HtmlOptions(mode: HtmlMode.cssClasses));
            output ~= "</code></pre>\n";
            write(output[]);
            return 0;
        }
        return emitAnsiWholeFile();
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
        return emitAnsiWholeFile();
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

    const result = runLoop(prev, sink, sess, idx, depth);

    // Restore the terminal (the alt screen's contents are discarded on exit).
    // On selection (Enter), print the whole file highlighted with the chosen
    // theme onto the primary screen; on quit/abort, print nothing.
    sink.put(CtlSeq.showCursor);
    sink.put(CtlSeq.exitAltScreen);
    if (result.selected)
        sink.put(prev.renderFull(result.idx, depth));
    sink.flush();
    return 0;
}
