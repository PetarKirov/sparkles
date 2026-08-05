/**
`hue` — an interactive syntax-highlighting file viewer and live theme previewer.

Highlights a source file in the terminal (ANSI) or as HTML. On a GUI-enabled
build hue opens the raylib window automatically when a display is available
(force with `--gui`, suppress with `--no-gui`/`--tui`); otherwise, in a Posix
tty it opens the full-screen terminal viewer (scrolling, ←/→ theme cycling,
search, mouse selection).

    hue [--html] [--gui|--no-gui] [--theme <name>] [path]

With no path, `hue` highlights its own source.

$(B Implementation:) the full `sparkles:syntax` precise pipeline (tree-sitter
parse → highlights query → event stream → ANSI/HTML renderer). Grammars come
from the nix bundle ($SPARKLES_TS_GRAMMAR_PATH); without it the program degrades
to plain text.
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
import sparkles.base.term_caps : isTerminal, StdStream;

import ansi_model : BackgroundMode, backgroundOptions;
import document : ContentKind, Document, DocumentPipeline, hueFenceRenderer;
import source_set : SourceSet;
import table_select : TableCopyFormat;

struct CliParams
{
    @CliOption("html", "Output formatted HTML instead of ANSI terminal escapes.")
    bool html;

    @CliOption("theme", "Syntax highlighting theme name.")
    string theme = "catppuccin-mocha";

    @CliOption("include", "Explorer glob(s) to always show (overrides hidden, git-ignored, and --exclude); matched against the entry name and its root-relative path. Repeatable.")
    string[] include;

    @CliOption("exclude", "Explorer glob(s) to hide. Repeatable; --include wins.")
    string[] exclude;

    @CliOption("tree-width", "Explorer pane width in cells (default 32).")
    int treeWidth = 32;

    @CliOption("tab-width", "Tab stops in the raw source view: a tab advances to the next multiple of this many columns.")
    int tabWidth = 4;

    @CliOption("list-whitespace", "Render whitespace visibly in the raw view, vim's 'list' style: tabs as '→', spaces and trailing runs as '·', no-break spaces as '␣'.")
    bool listWhitespace;

    @CliOption("gui", "Force the raylib GPU window (requires the 'gui' build configuration). With neither --gui nor --no-gui, hue opens the window automatically when a display is available and falls back to the terminal otherwise.")
    bool gui;

    @CliOption("no-gui", "Force terminal output (previewer / ANSI / HTML) even when a display is available.")
    bool noGui;

    @CliOption("tui", "Alias for --no-gui.")
    bool tui;

    @CliOption("twoslash", "Render a TypeScript twoslash JSON payload (its `code` + nodes) as a type-annotated overlay. Compatibility spelling of --overlay twoslash=<path>; a *.twoslash.json target needs no flag.")
    string twoslash;

    @CliOption("overlay", "Attach an overlay to the document: <kind>[=<artifact>] (see --list-overlays). E.g. --overlay twoslash=nodes.json.")
    string overlay;

    @CliOption("list-overlays", "List the registered overlay kinds and exit.")
    bool listOverlays;

    @CliOption("markdown", "Treat the input as Markdown and render the decorated preview (the default for .md files) in the active sink; forces the preview for a non-.md extension or stdin.")
    bool markdown;

    @CliOption("raw", "Render highlighted source instead of the markdown preview, in every sink (the preview is the default for .md files).")
    bool raw;

    @CliOption("diff", "Diff the two positional file arguments in-process and render the result in the active sink.")
    bool diff;

    @CliOption("patch", "Treat the input (a file target or piped stdin) as a unified diff; piped stdin is also sniffed without the flag.")
    bool patch;

    @CliOption("font", "--gui font: a path, a family name, or a fontconfig preference list (comma-separated; the first installed family wins).")
    string font = defaultGuiFont;

    @CliOption("font-bold", "--gui bold face: a family, fontconfig pattern, or font file (default: the --font family's bold variant).")
    string fontBold;

    @CliOption("font-italic", "--gui italic face: a family, fontconfig pattern, or font file (default: the --font family's italic variant; absent, italic text renders upright — hue never fakes a slant).")
    string fontItalic;

    @CliOption("font-bold-italic", "--gui bold-italic face (default: the --font family's bold-italic variant).")
    string fontBoldItalic;

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

    @CliOption("no-live-types", "Disable live D types in the interactive views: opening a .d file normally starts a twoslash-extract oracle beside it, underlines every hover span, and resolves a token's type when you point at it. Needs twoslash-extract on PATH (or $SPARKLES_TWOSLASH_EXTRACT); without it the viewer says so once and carries on.")
    bool noLiveTypes;
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

    auto registry = defaultRegistry();
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
                throw new Exception(twRes.error.toString);
            const tw = twRes.value;
            if (highlightInjected(cache, tw.effectiveLanguage, tw.code, ev).hasError)
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

version (Android)
{
    /// The bundled on-device family (nix/packages/android/hue.nix ships all
    /// four styled faces + charset sidecars); the desktop list follows so a
    /// bundle-less build still finds something.
    enum androidGuiFontFamily = "Maple Mono NF CN";
    enum androidGuiFont = androidGuiFontFamily ~ "," ~ defaultGuiFont;

    /// Uiua's non-ASCII primitive glyphs, formatted subscripts, and
    /// canonicalized identifier suffixes render from the bundled Uiua386 —
    /// the Android spelling of ghostty's font-codepoint-map (mirrors the
    /// machine config's uiua386glyphs.nix).
    enum androidUiuaCodepointMap =
        "U+00A4,U+00AC,U+00AF-U+00B1,U+00D7,U+00F7,U+02D9,U+02DC,U+03B7," ~
        "U+03C0,U+03C4,U+1D62-U+1D63,U+2032-U+2034,U+203C,U+2045," ~
        "U+207F-U+2089,U+208B,U+2091,U+2099,U+2102,U+2198-U+2199,U+21A5," ~
        "U+21A7,U+21AF,U+21BB,U+21CC,U+21E1,U+2202,U+220A,U+2218,U+221A," ~
        "U+221E,U+2220,U+2227-U+222B,U+2235,U+223F,U+224D,U+2260-U+2261," ~
        "U+2264-U+2265,U+2282-U+2283,U+228F,U+2293,U+2295,U+2297," ~
        "U+2299-U+229C,U+229E-U+229F,U+22A1-U+22A3,U+22A5,U+22B8,U+22C5," ~
        "U+22D5,U+22EF,U+2305,U+2308,U+230A,U+2315,U+231D-U+231F,U+2335," ~
        "U+2346,U+2349,U+234F,U+2356,U+235A,U+235C,U+2361-U+2365,U+2369," ~
        "U+25A1,U+25B3,U+25BD,U+25C7,U+25CC,U+25E0-U+25E1,U+25EB,U+25F0," ~
        "U+25F4,U+25FF,U+2607,U+266D,U+2682,U+27DC,U+2919-U+291A,U+2938," ~
        "U+29B7,U+29C5-U+29C6,U+29C8,U+29CB,U+29FB,U+2A02,U+2A2A,U+2A2C," ~
        "U+2A5C,U+2B1A,U+2BFE,U+1D110=Uiua386";
}

/// The grammar registry every sink resolves through. Desktop: the nix grammar
/// bundle via `$SPARKLES_TS_GRAMMAR_PATH`. Android: the soname layout —
/// parsers are APK native libraries the dynamic linker resolves, queries come
/// from the extracted assets.
private GrammarRegistry defaultRegistry() @safe
{
    version (Android)
    {
        import android_glue : androidDataDir;
        import android_paths : grammarQueriesRoot;

        return GrammarRegistry.fromSonames(grammarQueriesRoot(androidDataDir()));
    }
    else
        return GrammarRegistry.fromEnvironment();
}

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

/// The render sink a run paints into — one choice, made once. The old code
/// spread this across `wantGui`, `html`, and an `interactive` tty check; the
/// content question ("what is this document?") lives in `document.detect`.
enum Backend : ubyte
{
    gui,  /// the raylib window
    tui,  /// the interactive terminal (alt screen)
    html, /// static HTML on stdout
    ansi, /// static ANSI on stdout (piped / redirected)
}

/// Picks the sink: explicit flags win (`--gui`; `--no-gui`/`--tui`/`--html`
/// force the terminal), then autodetect — a GUI build with a display and a
/// tty opens the window; a tty gets the interactive viewer; anything else
/// streams ANSI.
private Backend pickBackend(in CliParams cli)
{
    // Android: the library runs inside a NativeActivity — no tty, no argv, no
    // $DISPLAY. The window *is* the app; every other sink is meaningless.
    //
    // Note the heuristic below could not stand in for this: on Android
    // `isTerminal` and `displayAvailable` are both false, which would answer
    // `ansi`. The Android fact is not "no display" but "the surface IS the
    // app" — a statement about the process model, which only hue can make.
    version (Android)
        return Backend.gui;
    else
    {
        bool guiCompiledIn = false;
        version (HueGui) guiCompiledIn = true;

        if (cli.gui)
            return Backend.gui; // even without GUI support: the sink reports it
        if (cli.html)
            return Backend.html;
        if (!cli.noGui && !cli.tui && guiCompiledIn
            && isTerminal(StdStream.stdout) && displayAvailable())
            return Backend.gui;
        if (isTerminal(StdStream.stdin) && isTerminal(StdStream.stdout))
            return Backend.tui;
        return Backend.ansi;
    }
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

    int rc; // the sink's status; also what the Android scope(exit) reports

    // The Android boot preamble: reroute logs to logcat (stderr goes nowhere
    // in a NativeActivity), re-enable the HUE_GUI_* debug hooks from the
    // on-device env file, and materialize the APK asset bundle (fonts,
    // grammar queries, sample docs) into the data dir.
    version (Android)
    {
        import android_glue : extractAssetsIfNeeded, installLogcatSink, loadDebugEnv;
        import core.stdc.stdlib : exit;

        // Android recreates an activity (rotation, task eviction) in the SAME
        // process, calling android_main → main again, and a statically linked
        // druntime cannot rt_init twice — it crashes on the new glue thread.
        // So the process must end when main does.
        //
        // `scope (exit)` rather than a tail call: main has many early returns
        // (--list-overlays, the CLI-error paths, a failed document load) and a
        // tail-position exit silently misses every one of them. It also makes
        // the JNI thread-attach safe by construction — the glue thread never
        // unwinds far enough for ART's "exiting without DetachCurrentThread"
        // check to fire.
        //
        // The status itself is not meaningful here: an early return leaves
        // `rc` at 0, and nothing observes a NativeActivity's exit code anyway
        // — the requirement is that the process ENDS, on every path.
        scope (exit) exit(rc);

        installLogcatSink(LogLevel.warning);
        loadDebugEnv();
        if (!extractAssetsIfNeeded())
            warning(i"hue: asset bundle missing — plain text, built-in document only");
    }

    if (cli.listOverlays)
    {
        import std.stdio : writeln;

        // The registry has one kind today; fold ranges, coverage and tracing
        // overlays register here as they land (`OVL1`).
        writeln("twoslash    type annotations from a twoslash JSON payload " ~
            "(artifact: the payload; or make it the target — *.twoslash.json)");
        return 0;
    }

    // `--overlay <kind>[=<artifact>]` (`OVL4`); `--twoslash <path>` is the old
    // spelling of `--overlay twoslash=<path>`. Either only names the target
    // and forces the kind — a `*.twoslash.json` path needs no flag at all.
    bool forceTwoslash = cli.twoslash.length != 0;
    string target = forceTwoslash ? cli.twoslash : (args.length > 1 ? args[1] : "");
    if (cli.overlay.length)
    {
        import std.string : indexOf;

        const eq = cli.overlay.indexOf('=');
        const kind = eq >= 0 ? cli.overlay[0 .. eq] : cli.overlay;
        if (kind != "twoslash")
        {
            stderr.writeln("hue: unknown overlay kind '", kind,
                "' (see --list-overlays)");
            return 1;
        }
        forceTwoslash = true;
        if (eq >= 0)
            target = cli.overlay[eq + 1 .. $];
    }

    const labels = LabelSet.standard();
    // `.get`'s default is `lazy`, so the warning fires only on a miss.
    const theme = resolveTheme(builtinThemes.get(cli.theme, {
            warning(i"theme '$(cli.theme)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, cli.markdown, cli.raw,
        cli.patch);

    const backend = pickBackend(cli);

    // A directory target is a multi-document set (`SRC4`). Interactive sinks
    // open the set (the GUI index view / `[`-`]` navigation); static sinks
    // render the gallery (`--html`) or a listing.
    import source_set : collectSources, SourceSet;

    SourceSet docSet;
    bool haveSet;
    string dirTarget;
    if (isDirectoryPath(target))
    {
        // The interactive terminal opens the split-pane workspace (`XPL2`)
        // with the explorer focused: picking a file fills the viewer pane
        // beside it — one loop, no full-screen transitions. Android is Posix
        // but has no terminal: never import the raw-termios workspace there
        // (the gate also keeps workspace.d out of the Android module graph).
        version (Android) {}
        else version (Posix)
            if (backend == Backend.tui)
            {
                import workspace : runWorkspace, WorkspaceDoc;

                auto themeSet = sortedThemes(cli.theme);
                auto pl = &pipeline;
                return runWorkspace(target, isDir: true, WorkspaceDoc.init,
                    delegate WorkspaceDoc(string path) @system
                        => pl.load(path),
                    themeSet.names, themeSet.themes, themeSet.idx, labels,
                    &cache, cli.include.dup, cli.exclude.dup, cli.treeWidth,
                    cli.tabWidth, cli.listWhitespace, liveTypes: !cli.noLiveTypes);
            }
        const openSet = backend == Backend.gui
            || (forceTwoslash && backend == Backend.tui);
        if (!openSet)
            return runDirectoryTarget(cli, target, forceTwoslash, cli.theme);
        docSet = collectSources(target, twoslash: forceTwoslash);
        if (docSet.empty)
        {
            stderr.writeln("hue: no renderable files in '", target, "'");
            return 1;
        }
        haveSet = true;
        dirTarget = target; // the explorer pane roots here (XPL2)
        target = docSet.current.path;
    }

    // One loader for every sink. With no target, hue views its own source,
    // embedded at compile time via `import()` (a released binary has no
    // build-tree `__FILE_FULL_PATH__` to read). A piped stdin that smells
    // like a unified diff (or is forced by `--patch`) becomes a diff
    // document (`DVS2` — the `git diff | hue` pager path).
    Document doc;
    try
    {
        if (cli.diff)
        {
            // `hue --diff <old> <new>`: two positional files, diffed
            // in-process (`DVS1`).
            if (args.length <= 2)
            {
                stderr.writeln("hue: --diff needs two file arguments");
                return 1;
            }
            doc = pipeline.loadDiffPair(args[1], args[2]);
        }
        else if (target.length == 0 && !isTerminal(StdStream.stdin))
        {
            const stdinText = readStdinText();
            import document : looksLikePatch;

            if (stdinText.length && (cli.patch || looksLikePatch(stdinText)))
                doc = pipeline.fromPatchSource("", "stdin", stdinText);
            else if (stdinText.length)
                doc = pipeline.fromSource("", "stdin", stdinText,
                    cli.markdown ? "markdown" : "");
            else
                doc = pipeline.fromSource("", "app.d", import("app.d"), "d");
        }
        else
            doc = target.length
                ? pipeline.load(target, forceTwoslash)
                // The built-in self-view carries NO path — it is not a file. A
                // synthetic "app.d" here made the explorer's reveal() re-root to
                // dirname("app.d") == "." at startup (XPF3), clobbering the real
                // tree root (on Android: the unreadable "/" → an empty tree).
                : pipeline.fromSource("", "app.d", import("app.d"), "d");
    }
    catch (Exception e)
    {
        stderr.writeln("hue: ", e.msg);
        return 1;
    }

    final switch (backend)
    {
        case Backend.gui:
            rc = runGuiSink(cli, doc, labels, theme, cache,
                haveSet ? &docSet : null, &pipeline, dirTarget);
            break;
        case Backend.html:
            rc = runHtmlSink(doc, theme, registry, cache);
            break;
        case Backend.tui:
            rc = runTuiSink(cli, doc, labels, theme, cache,
                haveSet ? &docSet : null, &pipeline);
            break;
        case Backend.ansi:
            rc = runAnsiSink(cli, doc, theme, cache);
            break;
    }

    return rc; // on Android the scope(exit) above ends the process first
}

// ── The four sinks — each a `final switch` over the document's kind ─────────

/// Static ANSI to stdout (piped / redirected / non-tty).
private int runAnsiSink(in CliParams cli, ref Document doc,
    in ResolvedTheme theme, ref TsConfigCache cache) @system
{
    // The headless TUI-frame capture hook works from a pipe (see runTuiSink).
    if (doc.kind == ContentKind.twoslash && tryTwoslashCapture(doc, theme, cache))
        return 0;

    SmallBuffer!char output;
    const depth = detectColorDepth();
    const bgMode = parseBackgroundMode(cli.background);
    final switch (doc.kind) with (ContentKind)
    {
        case twoslash:
            renderTwoslashAnsi(doc.twoslash, doc.events, theme, cache, output,
                TwoslashAnsiOptions(depth: depth, italics: true, emitBackground: true));
            break;
        case markdown:
            // The decorated preview (ANS3), rendered through the composable
            // markdown widget view — the M10 swap: viewMarkdown → layout →
            // CellGrid → ANSI. One view, every backend.
            import sparkles.syntax.md.render_widgets : MdViewOptions,
                MdViewTheme, viewMarkdown;
            import sparkles.ui.display_list : buildDisplayList;
            import sparkles.ui.geometry : Constraints;
            import sparkles.ui.interp.cells : BgEmit, CellGrid;
            import sparkles.ui.interp.immediate : paint;
            import sparkles.ui.layout : layout;
            import sparkles.ui.style : defaultTwoslashPalette;

            const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            MdViewOptions opt = {
                theme: MdViewTheme.derive(theme, pageFg, pageBg),
                fenceRenderer: hueFenceRenderer(&cache, &theme, pageFg),
            };
            auto tree = viewMarkdown(doc.preview.doc, opt);
            auto frames = layout(tree, Constraints(maxW: previewWidth()));
            const r = frames[tree.root].rect;
            auto grid = CellGrid(r.width, r.height, pageFg, pageBg);
            paint(grid, buildDisplayList(tree, frames, defaultTwoslashPalette(),
                pageFg, pageBg));
            grid.writeAnsi(output, depth,
                bgMode == BackgroundMode.full ? BgEmit.full
                : bgMode == BackgroundMode.spans ? BgEmit.spans : BgEmit.none);
            output ~= '\n';
            break;
        case code:
            renderAnsi(doc.source, doc.events, theme, output,
                bgMode.backgroundOptions(depth, italics: true));
            break;
        case diff:
            // The diff view (ANS4): the same widget→cells→SGR pipeline as
            // the markdown arm, over `viewDiffDoc` — the pager path
            // (`git diff | hue`).
            import diff_view : viewDiffDoc;
            import sparkles.ui.display_list : buildDisplayList;
            import sparkles.ui.geometry : Constraints;
            import sparkles.ui.interp.cells : BgEmit, CellGrid;
            import sparkles.ui.interp.immediate : paint;
            import sparkles.ui.layout : layout;
            import sparkles.ui.style : defaultTwoslashPalette;

            import diff_view : DiffViewOptions;
            import sparkles.syntax.md.render_widgets : highlightedFenceRenderer;

            const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            DiffViewOptions dopt;
            if (doc.diffSides.oldText.length || doc.diffSides.newText.length)
            {
                auto style = highlightedFenceRenderer(&cache, &theme, pageFg);
                dopt.oldStyled = style(doc.diffSides.lang, doc.diffSides.oldText);
                dopt.newStyled = style(doc.diffSides.lang, doc.diffSides.newText);
            }
            auto tree = viewDiffDoc(doc.diffDoc, dopt);
            auto frames = layout(tree, Constraints(maxW: previewWidth()));
            const r = frames[tree.root].rect;
            auto grid = CellGrid(r.width, r.height, pageFg, pageBg);
            paint(grid, buildDisplayList(tree, frames, defaultTwoslashPalette(),
                pageFg, pageBg));
            grid.writeAnsi(output, depth,
                bgMode == BackgroundMode.full ? BgEmit.full
                : bgMode == BackgroundMode.spans ? BgEmit.spans : BgEmit.none);
            output ~= '\n';
            break;
    }
    write(output[]);
    return 0;
}

/// Static HTML to stdout.
private int runHtmlSink(ref Document doc, in ResolvedTheme theme,
    ref GrammarRegistry registry, ref TsConfigCache cache) @system
{
    final switch (doc.kind) with (ContentKind)
    {
        case twoslash:
            import gallery : twoslashFragment;

            write(twoslashFragment(doc.twoslash, doc.events, theme, cache));
            return 0;
        case markdown:
            // The rich preview (HTM5); `--raw` loads the document as `code`.
            return emitMarkdownHtml(doc.source, theme, registry, cache);
        case code:
            // The same builder feeds the gallery, so both emit identical content.
            import gallery : plainFragment;

            write(plainFragment(doc.source, doc.events, theme));
            return 0;
        case diff:
            // The diff view as a self-contained widget-HTML page — the
            // parity interpreter (`interp/html.d`), no bespoke emitter.
            import diff_view : viewDiffDoc;
            import sparkles.ui.interp.html : writeWidgetHtmlPage;
            import sparkles.ui.style : defaultTwoslashPalette;

            import diff_view : DiffViewOptions;
            import sparkles.syntax.md.render_widgets : highlightedFenceRenderer;

            const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            DiffViewOptions dopt;
            if (doc.diffSides.oldText.length || doc.diffSides.newText.length)
            {
                auto style = highlightedFenceRenderer(&cache, &theme, pageFg);
                dopt.oldStyled = style(doc.diffSides.lang, doc.diffSides.oldText);
                dopt.newStyled = style(doc.diffSides.lang, doc.diffSides.newText);
            }
            SmallBuffer!char htmlOut;
            writeWidgetHtmlPage(htmlOut, viewDiffDoc(doc.diffDoc, dopt),
                defaultTwoslashPalette(), pageFg, pageBg, doc.title);
            write(htmlOut[]);
            return 0;
    }
}

/// The interactive terminal (alt screen). Posix gets the full-screen viewers;
/// elsewhere the theme-selection previewer (no raw-termios TUI) fills in.
private int runTuiSink(in CliParams cli, ref Document doc, in LabelSet labels,
    in ResolvedTheme theme, ref TsConfigCache cache,
    scope SourceSet* docSet, scope DocumentPipeline* pipeline = null) @system
{
    import source_set : SourceSet;

    // The headless QA capture hook still short-circuits a twoslash target.
    if (doc.kind == ContentKind.twoslash && tryTwoslashCapture(doc, theme, cache))
        return 0;

    auto themeSet = sortedThemes(cli.theme);

    version (Android)
    {
        // Unreachable (pickBackend always answers gui on Android), but the
        // gate keeps the raw-termios workspace out of the module graph.
        return runAnsiSink(cli, doc, theme, cache);
    }
    else version (Posix)
    {
        // The split-pane workspace (XPL2): the viewer pane on the document,
        // the explorer pane hidden until `e` (revealed at this file). One
        // loop hosts both — no full-screen transitions.
        import workspace : runWorkspace, WorkspaceDoc, WsLoader;

        WsLoader loader;
        if (pipeline !is null)
        {
            auto pl = pipeline; // capture the pointer, not the scope param
            loader = delegate WorkspaceDoc(string path) @system
                => pl.load(path);
        }
        return runWorkspace(doc.path, isDir: false, doc,
            loader, themeSet.names, themeSet.themes, themeSet.idx, labels,
            &cache, cli.include.dup, cli.exclude.dup, cli.treeWidth,
            cli.tabWidth, cli.listWhitespace, liveTypes: !cli.noLiveTypes);
    }
    else
    {
        // Non-Posix: no raw-termios TUI (sparkles:tui's reader is Posix-only) —
        // degrade to the whole-file ANSI emit (D6 retired the previewer).
        return runAnsiSink(cli, doc, theme, cache);
    }
}

/// The raylib window (a build without it reports rather than falls through —
/// `--gui` is explicit intent).
private int runGuiSink(in CliParams cli, ref Document doc, in LabelSet labels,
    in ResolvedTheme theme, ref TsConfigCache cache,
    scope SourceSet* docSet, scope DocumentPipeline* pipeline,
    string treeRoot = null) @system
{
    import source_set : SourceSet;

    version (HueGui)
    {
        import gui : LoadedDoc, runGui;
        import sparkles.raylib_text : FontSet;

        // A directory target opens in the tree; decided before the Android
        // default below widens treeRoot (browsing samples is opt-in there —
        // the built-in document stays the landing view).
        const startInTree = treeRoot.length != 0;

        // Android: with no explicit directory target, the explorer roots at
        // the extracted sample documents — the app-accessible browse surface.
        version (Android)
        {
            import std.file : exists;

            import android_glue : androidDataDir;
            import android_paths : docsDir;

            if (treeRoot.length == 0)
            {
                const dd = docsDir(androidDataDir());
                if (dd.exists)
                    treeRoot = dd;
            }
        }

        // The document loader the viewer calls when navigating a set (`GNV1`):
        // the one pipeline again — the GUI never duplicates it. A twoslash
        // payload rides along, so mixed sets navigate through one window.
        LoadedDoc loadDoc(string path) @system
            => pipeline.load(path);

        auto themeSet = sortedThemes(cli.theme);
        // Font selection: Android has no CLI, so the bundled defaults stand
        // in for the desktop flags — the Maple family for the primary and
        // all three styled faces (the fontconfig-free override resolution
        // picks its -Bold/-Italic/-BoldItalic siblings) + the Uiua386
        // codepoint map.
        version (Android)
        {
            const fontName = androidGuiFont;
            const faceOv = FontSet.FaceOverrides(androidGuiFontFamily,
                androidGuiFontFamily, androidGuiFontFamily);
            string[] cpMaps = [androidUiuaCodepointMap];
        }
        else
        {
            const fontName = cli.font;
            const faceOv = FontSet.FaceOverrides(cli.fontBold, cli.fontItalic,
                cli.fontBoldItalic);
            string[] cpMaps = null;
        }

        return runGui(doc.title, doc.source, doc.events, labels, themeSet.names,
            themeSet.themes, themeSet.idx, doc.preview, fontName, cli.fontSize,
            cli.windowWidth, cli.windowHeight, cli.lineNumbers, cli.codeLineNumbers,
            cli.ansiCopy == "strip", parseTableCopy(cli.tableCopy),
            docSet, &loadDoc, &cache, doc.twoslash,
            doc.path, startInTree: startInTree, treeRoot,
            faceOv, doc.lang,
            cli.include.dup, cli.exclude.dup, cli.treeWidth,
            cli.tabWidth, cli.listWhitespace, cpMaps,
            liveTypes: !cli.noLiveTypes, initialDiff: doc.diffDoc,
            initialDiffSides: doc.diffSides);
    }
    else
    {
        stderr.writeln("hue: this build has no GUI support (built with " ~
            "-c no-gui); use the default build: dub build :hue");
        return 1;
    }
}

/// Sorted theme names + the parallel theme values the previewer/GUI index per
/// frame (avoids per-frame GC AA lookups), plus the start index for `name`.
private auto sortedThemes(string name)
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : sort;
    import std.array : array;

    static struct ThemeSet
    {
        string[] names;
        immutable(Theme)[] themes;
        size_t idx;
    }

    ThemeSet s;
    s.names = builtinThemes.keys;
    sort(s.names);
    s.themes = s.names.map!(n => *(n in builtinThemes)).array;
    foreach (i, n; s.names)
        if (n == name)
        {
            s.idx = i;
            break;
        }
    return s;
}

/**
QA-capture hook: `HUE_TWOSLASH_TUI_CAPTURE=<cols>x<rows>[,<selIdx>]` renders one
TUI frame to a styled `<pre>` on stdout (a headless browser screenshots it), so
the TUI mode is captured headlessly alongside GUI/HTML. Works from a pipe as
well as a tty. See apps/hue/tools. Returns `true` when it emitted.
*/
private bool tryTwoslashCapture(ref Document doc, in ResolvedTheme theme,
    ref TsConfigCache cache) @system
{
    // Android: no terminal to capture for — and the gate keeps twoslash_tui.d
    // (raw-termios TUI) out of the Android module graph.
    version (Android)
        return false;
    else version (Posix)
    {
        import std.process : environment;

        const cap = environment.get("HUE_TWOSLASH_TUI_CAPTURE", "");
        if (!cap.length)
            return false;

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
        write(captureTuiFrameHtml(doc.title, doc.twoslash, doc.events, theme,
            cache, cols, rows, sel));
        return true;
    }
    else
        return false;
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

/// The column width the terminal markdown preview wraps to: the terminal width
/// (capped for prose readability), or 80 when it can't be detected (piped).
/// Slurps piped stdin to EOF (the `git diff | hue` pager path); empty when
/// nothing was piped.
private string readStdinText() @system
{
    import std.stdio : stdin;

    ubyte[] raw;
    foreach (chunk; stdin.byChunk(64 * 1024))
        raw ~= chunk;
    return cast(string) raw;
}

private int previewWidth() @system
{
    import sparkles.base.term_caps : terminalSize, StdStream;

    const w = terminalSize(StdStream.stdout).width;
    if (w <= 0)
        return 80;
    return w > 120 ? 120 : cast(int) w;
}

/// Fallback page colors when a theme leaves the default fg/bg unset (mirrors the
/// GUI's `hardFallback*`), so the preview always has a sane backdrop.
private enum RgbColor hardFallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x1e);
