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
import table_select : TableCopyFormat;

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

    @CliOption("ansi-copy", "--gui: how a selection over a ```ansi block copies — 'raw' (escape codes) or 'strip' (SGR removed). Default raw; toggle at runtime with 'y'.")
    string ansiCopy = "raw";

    @CliOption("table-copy", "--gui: how a table grid selection copies — 'tsv' (tab-separated) or 'markdown'. Default tsv; toggle at runtime with 't'.")
    string tableCopy = "tsv";

    @CliOption("out", "Output directory for the static HTML gallery a directory target renders into (with --html); defaults to <target>/html.")
    string outDir;
}

/// Parses `--table-copy` (`CLI11`) into a `TableCopyFormat`; unknown → `tsv`.
private TableCopyFormat parseTableCopy(string name)
{
    import table_select : TableCopyFormat;

    switch (name)
    {
        case "markdown": return TableCopyFormat.markdown;
        case "tsv":      return TableCopyFormat.tsv;
        default:
            warning(i"unknown --table-copy '$(name)'; using 'tsv'");
            return TableCopyFormat.tsv;
    }
}

/// `true` iff `path` names an existing directory — the multi-document target
/// (`SRC4`). A missing or unreadable path is not a directory (the file paths
/// below then report it).
private bool isDirectoryPath(string path) @trusted nothrow
{
    import std.file : exists, isDir;

    try
        return path.length != 0 && path.exists && path.isDir;
    catch (Exception)
        return false;
}

/**
Renders a directory of documents (`SRC4`) — the static HTML **gallery** under
`--html` (`HTM6`/`GAL2`): one page per entry plus an `index.html`, into `--out`
(default `<dir>/html`). Without `--html` a directory degrades to a static listing
rather than a crash (the interactive index view is `GAL5`).
*/
private int runDirectoryTarget(in CliParams cli, string dir, bool twoslash,
    string themeName) @system
{
    import std.path : buildPath;
    import std.stdio : writeln;

    import gallery : GalleryOptions, plainFragment, twoslashFragment, writeGallery;
    import source_set : collectSources, SourceEntry;

    auto set = collectSources(dir, twoslash);

    if (!cli.html)
    {
        // A static listing — the `SRC4` degradation for a directory in a mode that
        // renders one document at a time.
        if (set.empty)
        {
            stderr.writeln("hue: no renderable files in '", dir, "'");
            return 1;
        }
        foreach (ref const e; set.entries)
            writeln(e.name, "  ", e.summary);
        stderr.writeln("hue: ", set.length, " document(s); add --html [--out <dir>] " ~
            "to render them as a gallery");
        return 0;
    }

    if (set.empty)
        warning(i"no renderable files in '$(dir)' — writing an empty gallery index");

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(themeName, {
            warning(i"theme '$(themeName)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);

    // One entry → its content fragment. Throwing here is how `writeGallery` learns
    // to report-and-skip the entry (`GAL9`).
    string renderOne(in SourceEntry e)
    {
        SmallBuffer!HighlightEvent ev;
        if (twoslash)
        {
            auto twRes = loadTwoslashFile(e.path);
            if (twRes.hasError)
                throw new Exception(twRes.error.msg);
            const tw = twRes.value;
            if (highlightInjected(cache, "typescript", tw.code, ev).hasError)
                ev ~= HighlightEvent.sourceSpan(0, tw.code.length);
            return twoslashFragment(tw, ev[], theme, cache);
        }
        const src = readText(e.path);
        const lang = canonicalLanguage(e.path.extension.chompPrefix("."));
        if (highlightInjected(cache, lang, src, ev).hasError)
            ev ~= HighlightEvent.sourceSpan(0, src.length);
        return plainFragment(src, ev[], theme);
    }

    const outDir = cli.outDir.length ? cli.outDir : buildPath(dir, "html");
    const opt = twoslash
        ? GalleryOptions(
            titlePrefix: "twoslash",
            heading: "twoslash overlay examples",
            indexTitle: "twoslash examples",
            blurb: "Rendered by <code>hue --twoslash --html</code>. Open one and " ~
                "hover the underlined tokens to see the popups.")
        : GalleryOptions(
            titlePrefix: "hue",
            heading: "hue gallery",
            blurb: "Rendered by <code>hue --html</code>.");

    const n = writeGallery(set, outDir, opt, &renderOne);
    stderr.writeln("hue: wrote ", n, " page(s) + index.html to ", outDir);
    return 0;
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

    // A directory target is a multi-document set (`SRC4`). With `--html` it renders
    // as a static gallery; with `--gui` it opens the interactive index view
    // (`GAL5`) below; otherwise it degrades to a listing.
    const dirTarget = args.length > 1 && isDirectoryPath(args[1]);
    if (dirTarget && !cli.gui)
        return runDirectoryTarget(cli, args[1], twoslash: false, themeName);

    // With a path argument, highlight that file; otherwise highlight hue's own
    // source, embedded at compile time via `import()`. That works from any
    // install location — the build-time `__FILE_FULL_PATH__` would not exist in
    // a released (nix-packaged or copied) binary.
    import source_set : collectSources, SourceSet;

    // With a directory target the set drives the viewer; the first entry is the
    // document loaded up front (the index view opens on top of it).
    SourceSet docSet;
    bool haveSet;
    if (dirTarget)
    {
        docSet = collectSources(args[1], twoslash: false);
        if (docSet.empty)
        {
            stderr.writeln("hue: no renderable files in '", args[1], "'");
            return 1;
        }
        haveSet = true;
    }

    const hasFile = args.length > 1;
    const sourcePath = haveSet ? docSet.current.path : (hasFile ? args[1] : "app.d");
    const source = haveSet ? readText(sourcePath)
        : (hasFile ? readText(sourcePath) : import("app.d"));
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
        import gui_preview : layoutPreview, quoteBarColors;
        import preview_ansi : renderPreviewAnsi;

        SmallBuffer!char output;
        const depth = detectColorDepth();
        if (isMarkdownPreview)
        {
            // A markdown file renders the decorated preview (ANS3): the shared
            // layoutPreview painted to SGR cells by preview_ansi, so the terminal
            // matches the GUI. `--raw` takes the source path below.
            const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            auto model = buildMdPreview(registry, cache, source);
            auto plines = layoutPreview(model, theme, pageFg, pageBg, previewWidth());
            renderPreviewAnsi(output, plines, pageFg, pageBg,
                quoteBarColors(theme, pageFg, pageBg), depth, bgMode);
        }
        else
        {
            renderAnsi(source, events[], theme, output,
                bgMode.backgroundOptions(depth, italics: true));
        }
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
            import gui_preview : PreviewModel;

            // Markdown files open in a rendered preview (Tab toggles to raw);
            // other files pass an empty model and use the raw view only.
            PreviewModel preview;
            if (isMarkdownPreview)
                preview = buildMdPreview(registry, cache, source);

            // The document loader the viewer calls when navigating a set (`GNV1`):
            // app.d owns the grammar registry + cache, so the GUI never duplicates
            // this pipeline.
            import gui : LoadedDoc;

            LoadedDoc loadDoc(string path) @system
            {
                LoadedDoc doc;
                doc.source = readText(path);
                const l = canonicalLanguage(path.extension.chompPrefix("."));
                SmallBuffer!HighlightEvent ev;
                if (highlightInjected(cache, l, doc.source, ev).hasError)
                    ev ~= HighlightEvent.sourceSpan(0, doc.source.length);
                doc.events = ev[].dup;
                // Same rule as the up-front document (`CLI9` --raw wins).
                if (!cli.raw && (l == "markdown" || cli.markdown))
                    doc.preview = buildMdPreview(registry, cache, doc.source);
                return doc;
            }

            return runGui(baseName(sourcePath), source, events[], labels, names,
                themes, idx, preview, cli.font, cli.fontSize,
                cli.windowWidth, cli.windowHeight, cli.lineNumbers, cli.codeLineNumbers,
                cli.ansiCopy == "strip", parseTableCopy(cli.tableCopy),
                haveSet ? &docSet : null, haveSet ? &loadDoc : null);
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
            // The same builder feeds the gallery, so both emit identical content.
            import gallery : plainFragment;

            write(plainFragment(source, events[], theme));
            return 0;
        }
        return emitAnsiWholeFile();
    }

    const depth = detectColorDepth();

    version (Posix)
    {
        // The full-screen scrolling viewer (tui.md T1): the terminal port of the
        // GUI, painting the shared PreviewLine[] into alt-screen cells. A markdown
        // file starts in the decorated preview (Tab toggles to raw source); other
        // files show highlighted source. Scroll with arrows / PageUp-Down /
        // Home-End (or j/k/g/G), cycle themes with ←/→, quit with q.
        import gui_preview : PreviewModel;
        import tui : PreviewTui, runPreviewTui;

        PreviewModel tuiModel;
        if (isMarkdownPreview)
            tuiModel = buildMdPreview(registry, cache, source);
        auto t = PreviewTui(
            title: baseName(sourcePath),
            source: source,
            events: events[],
            model: tuiModel,
            labels: labels,
            names: names,
            themes: themes,
            background: bgMode,
            depth: depth,
        );
        return runPreviewTui(t, idx, isMarkdownPreview);
    }
    else
    {
        // Non-Posix: the shipped theme-selection previewer (no raw-termios TUI).
        auto sessFactory = stdioKeySession();
        if (sessFactory is null)
            return emitAnsiWholeFile();
        auto sess = sessFactory();
        scope (exit) sess.finish();

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
        // theme; on quit/abort, print nothing.
        sink.put(CtlSeq.showCursor);
        sink.put(CtlSeq.exitAltScreen);
        if (result.selected)
            sink.put(prev.renderFull(result.idx, depth));
        sink.flush();
        return 0;
    }
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

/// Build the markdown preview model, supplying the off-screen-VT ansi-fence
/// decoder only on a GUI-enabled build (`gui_ansi.decodeAnsi` pulls
/// sparkles:ghostty). Without it — the terminal / HTML paths and the `no-gui`
/// build — ` ```ansi ` fences degrade to stripped plain text (see gui_preview).
private auto buildMdPreview(ref GrammarRegistry registry, ref TsConfigCache cache,
    scope const(char)[] source) @system
{
    import gui_preview : buildPreviewModel;

    version (HueGui)
    {
        import gui_ansi : decodeAnsi;
        return buildPreviewModel(registry, cache, source, &decodeAnsi);
    }
    else
        return buildPreviewModel(registry, cache, source);
}

/// The column width the terminal markdown preview wraps to: the terminal width
/// (capped for prose readability), or 80 when it can't be detected (piped).
private int previewWidth() @system
{
    import sparkles.core_cli.term_caps : terminalSize, StdStream;

    const w = terminalSize(StdStream.stdout).width;
    if (w <= 0)
        return 80;
    return w > 120 ? 120 : cast(int) w;
}

/// Fallback page colors when a theme leaves the default fg/bg unset (mirrors the
/// GUI's `hardFallback*`), so the preview always has a sane backdrop.
private enum RgbColor hardFallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x1e);

/**
The `--twoslash <nodes.json>` path: load a TypeScript twoslash payload, highlight
its `code` as TypeScript, and render the twoslash overlay — as HTML (`--html`),
the raylib GUI (`--gui`), or ANSI (the default). The nodes are opaque data; the
overlay renderers live in `sparkles:twoslash`.
*/
int runTwoslashMode(in CliParams cli, string themeName) @system
{
    import source_set : SourceSet;

    // The document set, when `--twoslash` names a directory (`GNV1`).
    SourceSet docSet;
    bool haveSet;

    // `--twoslash <dir>` is a set of payloads: `--html` renders the static gallery
    // (`GAL2`), `--gui` opens the first payload with `[`/`]` navigation (`GNV1`).
    string[] setPaths;
    if (isDirectoryPath(cli.twoslash))
    {
        // `--html` renders the static gallery; an interactive run (GUI or TUI)
        // opens the set and navigates it.
        const wantInteractive = cli.gui
            || (isTerminal(StdStream.stdout) && isTerminal(StdStream.stdin));
        if (cli.html || !wantInteractive)
            return runDirectoryTarget(cli, cli.twoslash, twoslash: true, themeName);

        import source_set : collectSources;

        auto found = collectSources(cli.twoslash, twoslash: true);
        if (found.empty)
        {
            stderr.writeln("hue: no *.twoslash.json payloads in '", cli.twoslash, "'");
            return 1;
        }
        docSet = found;
        haveSet = true;
        setPaths = [found.current.path];
    }

    auto twRes = loadTwoslashFile(setPaths.length ? setPaths[0] : cli.twoslash);
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

            const guiTitle = haveSet ? docSet.current.name : baseName(cli.twoslash);
            return runGuiTwoslash(guiTitle, tw, events[], labels, theme, cache,
                haveSet ? &docSet : null, cli.lineNumbers);
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
        import gallery : twoslashFragment;

        write(twoslashFragment(tw, events[], theme, cache));
        return 0;
    }

    // QA-capture hook: HUE_TWOSLASH_TUI_CAPTURE=<cols>x<rows>[,<selIdx>] renders one
    // TUI frame to a styled <pre> on stdout (a headless browser screenshots it), so
    // the TUI mode is captured headlessly alongside GUI/HTML. See apps/hue/tools.
    version (Posix)
    {
        import std.process : environment;

        const cap = environment.get("HUE_TWOSLASH_TUI_CAPTURE", "");
        if (cap.length)
        {
            import twoslash_tui : captureTuiFrameHtml;
            import std.string : split;
            import std.conv : to;

            int cols = 100, rows = 30, sel = -1;
            try
            {
                auto parts = cap.split(",");
                auto wh = parts[0].split("x");
                if (wh.length == 2)
                {
                    cols = wh[0].to!int;
                    rows = wh[1].to!int;
                }
                if (parts.length > 1)
                    sel = parts[1].to!int;
            }
            catch (Exception)
            {
            }
            write(captureTuiFrameHtml(baseName(cli.twoslash), tw, events[], theme, cache,
                cols, rows, sel));
            return 0;
        }
    }

    // An interactive terminal: the live TUI overlay (mouse + keyboard). A pipe or
    // redirect (not a tty) falls through to the non-interactive ANSI render below,
    // so `hue --twoslash x.json | less` and CI capture still work.
    version (Posix)
    {
        if (isTerminal(StdStream.stdout) && isTerminal(StdStream.stdin))
        {
            import twoslash_tui : runTuiTwoslash;

            const tuiTitle = haveSet ? docSet.current.name : baseName(cli.twoslash);
            return runTuiTwoslash(tuiTitle, tw, events[], theme, cache,
                haveSet ? &docSet : null);
        }
    }

    SmallBuffer!char output;
    renderTwoslashAnsi(tw, events[], theme, cache, output,
        TwoslashAnsiOptions(depth: detectColorDepth(), italics: true, emitBackground: true));
    write(output[]);
    return 0;
}
