/**
`hue` — an interactive syntax-highlighting file viewer and live theme previewer.

Highlights a source file in the terminal (ANSI) or as HTML. On a GUI-enabled
build hue opens the raylib window automatically when a display is available
(force with `--gui`, suppress with `--no-gui`/`--tui`); otherwise, in a tty it
opens the live terminal previewer: browse the built-in themes with ↑/↓, and
press Enter to print the whole file in the chosen theme.

    hue [--html] [--gui|--no-gui] [--theme <name>] [path]

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
import std.stdio : stderr, write;
import std.string : chompPrefix;

import sparkles.syntax;
import sparkles.twoslash;
import sparkles.core_cli.args;

import sparkles.base.logger : initLogger, LogLevel, warning;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_control : CtlSeq;
import sparkles.core_cli.key_input : stdioKeySession;
import sparkles.core_cli.term_caps : isTerminal, StdStream;

import previewer : BackgroundMode, backgroundOptions, Previewer, runLoop, TermOut;

struct CliParams
{
    @CliOption("html", "Output formatted HTML instead of ANSI terminal escapes.")
    bool html;

    @CliOption("theme", "Syntax highlighting theme name.")
    string theme = "catppuccin-mocha";

    @CliOption("gui", "Force the raylib GPU window (requires the 'gui' build configuration). With neither --gui nor --no-gui, hue opens the window automatically when a display is available and falls back to the terminal otherwise.")
    bool gui;

    @CliOption("no-gui", "Force terminal output (previewer / ANSI / HTML) even when a display is available.")
    bool noGui;

    @CliOption("tui", "Alias for --no-gui.")
    bool tui;

    @CliOption("twoslash", "Render a TypeScript twoslash JSON payload (its `code` + nodes) as a type-annotated overlay.")
    string twoslash;

    @CliOption("markdown", "Treat the input as Markdown and render the decorated preview (the default for .md files) in the active sink; forces the preview for a non-.md extension or stdin.")
    bool markdown;

    @CliOption("raw", "Render highlighted source instead of the markdown preview, in every sink (the preview is the default for .md files).")
    bool raw;

    @CliOption("font", "--gui font: a path, a family name, or a fontconfig preference list (comma-separated; the first installed family wins).")
    string font = defaultGuiFont;

    @CliOption("font-size", "--gui font size in points (like the terminal).")
    int fontSize = 14;

    @CliOption("window-width", "--gui initial window width in cells (like the terminal).")
    int windowWidth = 100;

    @CliOption("window-height", "--gui initial window height in cells.")
    int windowHeight = 30;

    @CliOption("line-numbers", "--gui: show the file line-number gutter (default on; disable with =false; toggle at runtime with 'l').")
    bool lineNumbers = true;

    @CliOption("code-line-numbers", "--gui: number the lines inside each code block (default on; disable with =false; toggle at runtime with 'c').")
    bool codeLineNumbers = true;

    @CliOption("background", "Terminal background mode: no-background (foreground only), spans (only where the theme sets one), or full (fill every line edge-to-edge; the default).")
    string background = "full";
}

/// Parses the `--background` value (`CLI8`) into a `BackgroundMode`; an unknown
/// name warns and falls back to `full` (mirrors the `--theme` fallback).
private BackgroundMode parseBackgroundMode(string name)
{
    switch (name)
    {
        case "no-background": return BackgroundMode.noBackground;
        case "spans":         return BackgroundMode.spans;
        case "full":          return BackgroundMode.full;
        default:
            warning(i"unknown --background '$(name)'; using 'full'");
            return BackgroundMode.full;
    }
}

/// Default `--gui` font: FiraCode Nerd Font Mono, then a fontconfig preference
/// list of popular coding fonts (Nerd-Font variants first for icon glyphs),
/// ending in a generic monospace — the first installed family wins, so hue
/// renders on a sensible font even when none of the named ones are present.
/// The markdown preview's decorations (heading/callout/link icons, checkboxes)
/// are Nerd-Font glyphs; with a non-Nerd `--font` they degrade to tofu.
enum defaultGuiFont =
    "FiraCode Nerd Font Mono,JetBrainsMono Nerd Font Mono,JetBrains Mono," ~
    "CaskaydiaCove Nerd Font Mono,Cascadia Code,Hack Nerd Font Mono,Hack," ~
    "Iosevka Term,Iosevka,Source Code Pro,DejaVu Sans Mono,monospace";

/// Heuristic for whether a graphical display is available, used to pick the GUI
/// vs the terminal by default (no `--gui`/`--no-gui`). On Linux/BSD a display is
/// present when `$DISPLAY` (X11) or `$WAYLAND_DISPLAY` is set; on macOS/Windows a
/// local session is assumed to have one unless we are in an SSH login
/// (`$SSH_CONNECTION`). A false negative just falls back to the terminal, and
/// `--gui` overrides it, so the heuristic only has to be right most of the time.
private bool displayAvailable()
{
    import std.process : environment;

    version (OSX)
        return environment.get("SSH_CONNECTION", "").length == 0;
    else version (Windows)
        return environment.get("SSH_CONNECTION", "").length == 0;
    else
        return environment.get("DISPLAY", "").length != 0
            || environment.get("WAYLAND_DISPLAY", "").length != 0;
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
    const bgMode = parseBackgroundMode(cli.background);

    // Twoslash mode consumes a JSON payload (its own `code` + nodes) instead of
    // a source file — a fourth consumer of the syntax pipeline that overlays the
    // twoslash decorations. See src/twoslash_mode.d.
    if (cli.twoslash.length)
        return runTwoslashMode(cli, themeName);

    // With a path argument, highlight that file; otherwise highlight hue's own
    // source, embedded at compile time via `import()`. That works from any
    // install location — the build-time `__FILE_FULL_PATH__` would not exist in
    // a released (nix-packaged or copied) binary.
    const hasFile = args.length > 1;
    const sourcePath = hasFile ? args[1] : "app.d";
    const source = hasFile ? readText(sourcePath) : import("app.d");
    const lang = canonicalLanguage(sourcePath.extension.chompPrefix("."));

    // Markdown files render the decorated preview by default in every sink (MOD8);
    // `--markdown` forces it for a non-.md extension, `--raw` suppresses it.
    const isMarkdownPreview = !cli.raw && (lang == "markdown" || cli.markdown);

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
            bgMode.backgroundOptions(detectColorDepth(), italics: true));
        write(output[]);
        return 0;
    }

    // Sorted theme names, plus the parallel theme values the previewer/GUI index
    // per frame (avoids per-frame GC AA lookups; `.keys` already returns a fresh
    // array, so no `.dup`). Shared by the GUI and terminal previewer paths.
    string[] names = builtinThemes.keys;
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : map;
    import std.array : array;
    sort(names);
    immutable(Theme)[] themes = names.map!(n => *(n in builtinThemes)).array;

    size_t idx = 0;
    foreach (i, n; names) if (n == themeName) { idx = i; break; }

    // Third sink: the raylib GPU window. A third consumer of the same
    // (source, events, theme) triple — folds styled runs into draw calls
    // instead of ANSI/HTML. Compiled only into the `gui` build; the default
    // terminal build has no window.
    //
    // Mode selection: explicit flags win — `--gui` forces the window (even with
    // no display; raylib surfaces any failure), `--no-gui`/`--tui`/`--html`
    // force the terminal. With no mode flag, autodetect on a GUI-enabled build:
    // open the window when a display is available and stdout is a tty, otherwise
    // fall through to the terminal dispatch below.
    bool guiCompiledIn = false;
    version (HueGui) guiCompiledIn = true;

    bool wantGui;
    if (cli.gui)
        wantGui = true;
    else if (cli.noGui || cli.tui || html)
        wantGui = false;
    else
        wantGui = guiCompiledIn && isTerminal(StdStream.stdout) && displayAvailable();

    if (wantGui)
    {
        version (HueGui)
        {
            import gui : runGui;
            import gui_preview : buildPreviewModel, PreviewModel;

            // Markdown files open in a rendered preview (Tab toggles to raw);
            // other files pass an empty model and use the raw view only.
            PreviewModel preview;
            if (isMarkdownPreview)
                preview = buildPreviewModel(registry, cache, source);
            return runGui(baseName(sourcePath), source, events[], labels, names,
                themes, idx, preview, cli.font, cli.fontSize,
                cli.windowWidth, cli.windowHeight, cli.lineNumbers, cli.codeLineNumbers);
        }
        else
        {
            // Reached only via explicit `--gui` on a build without GUI support
            // (autodetect never sets wantGui here — guiCompiledIn is false).
            stderr.writeln("hue: this build has no GUI support (built with " ~
                "-c no-gui); use the default build: dub build :hue");
            return 1;
        }
    }

    const interactive = !html &&
        isTerminal(StdStream.stdin) && isTerminal(StdStream.stdout);

    if (!interactive)
    {
        if (html)
        {
            // A markdown file renders the rich HTML preview (HTM5); `--raw` and a
            // non-markdown file emit highlighted source.
            if (isMarkdownPreview)
                return emitMarkdownHtml(source, theme, registry, cache);

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
        background: bgMode,
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

/// Prose + callout + table styling for the markdown HTML preview, layered over
/// the theme's syntax stylesheet (`.syn-root` carries the page fg/bg). Callout
/// accents mirror the GUI preview (blue / green / purple / yellow / red).
private enum markdownPreviewCss =
    ".md { max-width: 48em; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }\n" ~
    ".md pre.code-fence { padding: .75em 1em; overflow-x: auto; border-radius: 6px; }\n" ~
    ".md :not(pre) > code { padding: .1em .35em; border-radius: 3px; background: #8882; }\n" ~
    ".md blockquote { border-left: 3px solid #8888; margin: 1em 0; padding: 0 1em; opacity: .85; }\n" ~
    ".md table { border-collapse: collapse; margin: 1em 0; }\n" ~
    ".md th, .md td { border: 1px solid #8884; padding: .3em .6em; }\n" ~
    ".md img { max-width: 100%; }\n" ~
    ".callout { border-left: 4px solid; margin: 1em 0; padding: .1em 1em; border-radius: 4px; background: #8881; }\n" ~
    ".callout-title { font-weight: 600; margin: .4em 0; }\n" ~
    ".callout-note { border-color: #539bf5; }\n" ~
    ".callout-tip { border-color: #57ab5a; }\n" ~
    ".callout-important { border-color: #986ee2; }\n" ~
    ".callout-warning { border-color: #c69026; }\n" ~
    ".callout-caution { border-color: #e5534b; }\n";

/**
Render `source` as a rich HTML markdown preview (`HTM5`): the `MdDoc → HTML`
emitter (`renderMarkdownHtml`) wrapped in the theme's stylesheet, with fenced
code blocks syntax-highlighted (a `fence` hook reusing the injection-aware
pipeline) and callouts / aligned tables styled. This is the default for a `.md`
file under `--html`; `--raw` emits highlighted source instead. The markdown
grammars come from the nix bundle ($SPARKLES_TS_GRAMMAR_PATH); without them
`extractMarkdown` yields an empty document (a warning is logged). Writes to
stdout and returns the exit code.
*/
int emitMarkdownHtml(scope const(char)[] source, in ResolvedTheme theme,
    ref GrammarRegistry registry, ref TsConfigCache cache) @system
{
    auto doc = extractMarkdown(registry, source);
    if (doc.root.children.length == 0 && source.length)
        warning(i"no markdown grammar (set SPARKLES_TS_GRAMMAR_PATH) — empty output");

    // Highlight a fence body with its language, wrapped in the same `.syn-root`
    // classes the theme stylesheet defines — so fences match the GUI preview
    // instead of rendering as plain escaped text.
    const(char)[] highlightFence(const(char)[] infoLang, const(char)[] code)
    {
        SmallBuffer!HighlightEvent ev;
        const canon = canonicalLanguage(infoLang);
        auto r = highlightInjected(cache, canon, code, ev);
        if (r.hasError)
            ev ~= HighlightEvent.sourceSpan(0, code.length);
        SmallBuffer!char b;
        b ~= `<pre class="syn-root code-fence"><code>`;
        renderHtml(code, ev[], theme, b, HtmlOptions(mode: HtmlMode.cssClasses));
        b ~= "</code></pre>";
        return b[].idup;
    }

    SmallBuffer!char output;
    output ~= "<style>\n";
    writeThemeStylesheet(theme, output);
    output ~= markdownPreviewCss;
    output ~= "</style>\n<article class=\"syn-root md\">\n";
    renderMarkdownHtml(doc, output, MarkdownHtmlOptions(), &highlightFence);
    output ~= "\n</article>\n";
    write(output[]);
    return 0;
}

/**
The `--twoslash <nodes.json>` path: load a TypeScript twoslash payload, highlight
its `code` as TypeScript, and render the twoslash overlay — as HTML (`--html`),
the raylib GUI (`--gui`), or ANSI (the default). The nodes are opaque data; the
overlay renderers live in `sparkles:twoslash`.
*/
int runTwoslashMode(in CliParams cli, string themeName) @system
{
    auto twRes = loadTwoslashFile(cli.twoslash);
    if (twRes.hasError)
    {
        stderr.writeln("hue: ", twRes.error.msg);
        return 1;
    }
    const tw = twRes.value;

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(themeName, {
            warning(i"theme '$(themeName)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    // Highlight the display source as TypeScript (twoslash's own language),
    // degrading to plain text without the grammar — the overlay never fails.
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);
    SmallBuffer!HighlightEvent events;
    auto res = highlightInjected(cache, "typescript", tw.code, events);
    if (res.hasError)
    {
        warning(i"no typescript grammar — rendering the snippet as plain text");
        events ~= HighlightEvent.sourceSpan(0, tw.code.length);
    }

    if (cli.gui)
    {
        version (HueGui)
        {
            import gui : runGuiTwoslash;
            return runGuiTwoslash(baseName(cli.twoslash), tw, events[], labels, theme, cache);
        }
        else
        {
            stderr.writeln("hue: this build has no GUI support; " ~
                "rebuild the gui configuration: dub build :hue -c gui");
            return 1;
        }
    }

    if (cli.html)
    {
        SmallBuffer!char output;
        output ~= "<style>\n";
        writeThemeStylesheet(theme, output);
        writeTwoslashStyles(output);
        output ~= "</style>\n<pre class=\"syn-root twoslash\"><code>";
        renderTwoslashHtml(tw, events[], theme, cache, output);
        output ~= "</code></pre>\n";
        write(output[]);
        return 0;
    }

    SmallBuffer!char output;
    renderTwoslashAnsi(tw, events[], theme, cache, output,
        TwoslashAnsiOptions(depth: detectColorDepth(), italics: true, emitBackground: true));
    write(output[]);
    return 0;
}
