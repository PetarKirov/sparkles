/**
`hue` — an interactive syntax-highlighting file viewer and live theme previewer.

Highlights a source file in the terminal (ANSI) or as HTML. On a GUI-enabled
build hue opens the raylib window automatically when a display is available
(force with `--gui`, suppress with `--no-gui`/`--tui`); otherwise, in a Posix
tty it opens the full-screen terminal viewer (scrolling, ←/→ theme cycling,
search, mouse selection).

    hue [view] [--html] [--gui|--no-gui] [--theme <name>] [path]
    hue diff <old> <new>
    hue pr <pr-number-or-url>
    hue gallery <directory>
    hue theme [--list] [<name>]
    hue overlay [--list] [<kind>]
    hue config [--show]

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
import std.sumtype : match, SumType;

import sparkles.syntax;
import sparkles.syntax.md.model : MdDoc;
import sparkles.syntax.md.render_widgets : OverflowPolicy, ScrollOverflow,
    WrapAtOverflow, WrapOverflow;
import sparkles.twoslash;
import sparkles.core_cli.args;

import sparkles.base.logger : initLogger, LogLevel, warning;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_caps : isTerminal, StdStream;

import ansi_model : BackgroundMode, backgroundOptions;
import document : ContentKind, Document, DocumentPipeline, hueFenceRenderer;
import diff_commutative : CommutativeKind;
import diff_session : AnchoredThread, SessionHeader, ThreadComment;
import forge : CommentThread, PullRequest, ThreadSide;
import diff_structural : StructuralPolicy;
import diff_view : DiffLayout, DiffViewOptions;
import sparkles.diff : WhitespaceMode;
import source_set : SourceSet;
import table_select : TableCopyFormat;

import sparkles.ui_app.gui_options : defaultGuiFont, defaultGuiFontFamily,
    defaultTheme, GuiOptions;
import sparkles.ui_app.backend : Backend, BackendPolicy,
    hostPickBackend = pickBackend, platformForcedBackend;
import sparkles.ui_app.display : displayAvailable;

// ── Option Groupings & Subcommands ──────────────────────────────────────────

/// Standalone overlay configuration.
struct OverlayOptions
{
    @(Option("twoslash", description: "Render a TypeScript twoslash JSON payload as type-annotated overlay (compatibility alias for --overlay twoslash=<path>)."))
    string twoslash;

    @(Option("overlay", description: "Attach an overlay: <kind>[=<artifact>] (e.g. twoslash=nodes.json, coverage=cov.json). Can be specified multiple times."))
    string[] overlays;

    @(Option("list-overlays", description: "List registered overlay kinds."))
    bool listOverlays;
}

/// Standalone diff configuration.
struct DiffOptions
{
    @(Option("diff-ignore-whitespace", description: "Whitespace difference mode: exact | trailing | change | all."))
    string diffIgnoreWhitespace = "exact";

    @(Option("diff-preview", description: "Diff rendered Markdown documents instead of raw source."))
    bool diffPreview;

    @(Option("diff-structural", description: "Grammar-aware structural diff: auto | on | off."))
    string diffStructural = "auto";

    @(Option("diff-commutative", description: "Containers whose child order carries no meaning (e.g. D imports)."))
    string diffCommutative = "default";

    @(Option("diff-layout", description: "Diff layout: unified (default) or split."))
    string diffLayout = "unified";
}

/// Output rendering sink options (mutually exclusive choices for document rendering).
struct RenderSinkOptions
{
    @(Option("backend|sink", description: "Target rendering backend: gui | tui | html | ansi (default: auto-detected)."))
    string backend = "auto";

    @(Option("html", description: "Output formatted HTML instead of ANSI escapes (shorthand for --backend=html)."))
    bool html;

    @(Option("tui", description: "Force terminal output (alias for --no-gui / --backend=tui)."))
    bool tui;

    @(Option("ansi", description: "Output formatted ANSI escapes (shorthand for --backend=ansi)."))
    bool ansi;

    Backend resolveBackend(in GuiOptions guiOpt) const
    {
        Backend forced;
        if (platformForcedBackend(forced))
            return forced; // Android: the surface IS the app

        if (backend == "gui") return Backend.gui;
        if (backend == "tui") return Backend.tui;
        if (backend == "html" || html) return Backend.html;
        if (backend == "ansi" || ansi) return Backend.ansi;

        bool guiCompiledIn = false;
        version (HueGui) guiCompiledIn = true;

        const wantGui = (backend == "gui") || guiOpt.gui;
        const wantNoGui = tui || guiOpt.tui || guiOpt.noGui;

        return hostPickBackend(BackendPolicy(
            forceGui: wantGui,
            forceNoGui: wantNoGui,
            forceTui: tui || guiOpt.tui,
            forceHtml: html,
            guiCompiledIn: guiCompiledIn,
            stdinTty: isTerminal(StdStream.stdin),
            stdoutTty: isTerminal(StdStream.stdout),
            displayPresent: displayAvailable(),
        ));
    }
}

/// Render settings passed down to active sinks.
struct ViewRenderOptions
{
    string theme;
    string background = "full";
    bool groupThemes = true;
    int treeWidth = 32;
    int tabWidth = 4;
    bool listWhitespace = false;
    bool lineNumbers = true;
    bool codeLineNumbers = true;
    string codeOverflow = "scroll";
    int codeMaxLines = -1;
    string tableOverflow = "scroll";
    int tableMaxLines = -1;
    string ansiCopy = "raw";
    string tableCopy = "tsv";
    string[] include;
    string[] exclude;
    bool noLiveTypes = false;
    string diffLayout = "unified";
    GuiOptions gui;
}

// ── Subcommands ─────────────────────────────────────────────────────────────

@(Command("view", isDefault: true,
    shortDescription: "View and syntax-highlight a file, directory, or twoslash overlay",
))
struct View
{
    @(Argument("paths", description: "File or directory to view (default: hue's own source).", optional: true))
    string[] paths;

    @Flatten("Output Sinks")
    RenderSinkOptions sink;

    @(Option("markdown", description: "Treat the input as Markdown and render the decorated preview."))
    bool markdown;

    @(Option("language|lang", description: "Override syntax language (e.g. 'd', 'rust', 'markdown', 'json')."))
    string language;

    @(Option("raw", description: "Render highlighted source instead of markdown preview."))
    bool raw;

    @(Option("patch", description: "Treat the input as a unified diff."))
    bool patch;

    @(Option("dsv", description: "Treat the input as delimiter-separated values and render the grid preview."))
    bool dsv;

    @(Option("dsv-delimiter", description: "Force the DSV delimiter (a char, tab, or \\t; default: sniffed from the content)."))
    string dsvDelimiter;

    @(Option("dsv-quote", description: "Force the DSV quote character (default: sniffed)."))
    string dsvQuote;

    @(Option("dsv-header", description: "Whether the first DSV record is a header: auto, yes or no."))
    string dsvHeader = "auto";

    @(Option("tree-width", description: "Explorer pane width in cells (default 32)."))
    int treeWidth = 32;

    @(Option("tab-width", description: "Tab stops in the raw source view: a tab advances to the next multiple of this many columns."))
    int tabWidth = 4;

    @(Option("list-whitespace", description: "Render whitespace visibly in the raw view, vim's 'list' style."))
    bool listWhitespace;

    @(Option("line-numbers", description: "--gui: show the file line-number gutter (default on)."))
    bool lineNumbers = true;

    @(Option("code-line-numbers", description: "--gui: number the lines inside each code block (default on)."))
    bool codeLineNumbers = true;

    @(Option("code-overflow", description: "How a code-block line longer than its panel behaves: 'scroll', 'wrap', or 'wrap-at:N' (wrap to N cells total, then scroll)."))
    string codeOverflow = "scroll";

    @(Option("code-max-lines", description: "A code block taller than this many lines shows a fixed-height vertical viewport (-1 auto, 0 disables)."))
    int codeMaxLines = -1;

    @(Option("table-overflow", description: "How a table wider than its panel behaves: 'scroll', 'wrap', or 'wrap-at:N' (wrap to N cells total, then scroll)."))
    string tableOverflow = "scroll";

    @(Option("table-max-lines", description: "A table taller than this many interior lines shows a fixed-height vertical viewport (-1 auto, 0 disables)."))
    int tableMaxLines = -1;

    @(Option("group-themes", description: "Group the theme cycle by light/dark (default on)."))
    bool groupThemes = true;

    @(Option("ansi-copy", description: "--gui: how a selection over a ```ansi block copies: 'raw' or 'strip'."))
    string ansiCopy = "raw";

    @(Option("table-copy", description: "--gui: how a table grid selection copies: 'tsv' or 'markdown'."))
    string tableCopy = "tsv";

    @(Option("include", description: "Explorer glob(s) to always show. Repeatable."))
    string[] include;

    @(Option("exclude", description: "Explorer glob(s) to hide. Repeatable."))
    string[] exclude;

    @(Option("no-live-types", description: "Disable live D types in the interactive views."))
    bool noLiveTypes;

    @Flatten
    DiffOptions diffOptions;

    int run(Program)(in Program program)
    {
        return executeView(program.value, this);
    }
}

@(Command("diff",
    shortDescription: "Diff two files or git revisions with syntax highlighting and structural awareness",
))
struct Diff
{
    @(Argument("targets", description: "Old and new files to diff, or git revspec and path filters.", optional: true))
    string[] targets;

    @(Option("staged", description: "Diff the index (staged changes) against HEAD or the given revision."))
    bool staged;

    @Flatten("Diff Options")
    DiffOptions diff;

    @Flatten("Output Sinks")
    RenderSinkOptions sink;

    @(Option("line-numbers", description: "--gui: show line-number gutter."))
    bool lineNumbers = true;

    @(Option("code-overflow", description: "How code-block lines behave: 'scroll', 'wrap', or 'wrap-at:N'."))
    string codeOverflow = "scroll";

    @(Option("code-max-lines", description: "Max code block lines before vertical scrollbar."))
    int codeMaxLines = -1;

    @(Option("table-overflow", description: "How a wide table behaves: 'scroll', 'wrap', or 'wrap-at:N'."))
    string tableOverflow = "scroll";

    @(Option("table-max-lines", description: "Max table interior lines before vertical scrollbar."))
    int tableMaxLines = -1;

    int run(Program)(in Program program)
    {
        return executeDiff(program.value, this);
    }
}

@(Command("pr",
    shortDescription: "Open a GitHub/GitLab pull request as a diff session with review comments",
))
struct Pr
{
    @(Argument("pr", description: "Pull request identifier (e.g. 123, owner/repo#123, or forge URL)."))
    string pr;

    @Flatten("Diff Options")
    DiffOptions diff;

    @Flatten("Output Sinks")
    RenderSinkOptions sink;

    @(Option("line-numbers", description: "--gui: show line-number gutter."))
    bool lineNumbers = true;

    @(Option("code-overflow", description: "How code-block lines behave: 'scroll', 'wrap', or 'wrap-at:N'."))
    string codeOverflow = "scroll";

    @(Option("code-max-lines", description: "Max code block lines before vertical scrollbar."))
    int codeMaxLines = -1;

    @(Option("table-overflow", description: "How a wide table behaves: 'scroll', 'wrap', or 'wrap-at:N'."))
    string tableOverflow = "scroll";

    @(Option("table-max-lines", description: "Max table interior lines before vertical scrollbar."))
    int tableMaxLines = -1;

    int run(Program)(in Program program)
    {
        return executePr(program.value, this);
    }
}

@(Command("gallery",
    shortDescription: "Batch render a directory into a static HTML syntax/theme gallery",
))
struct Gallery
{
    @(Argument("dir", description: "Directory to render as a gallery (default: current directory).", optional: true))
    string dir = ".";

    @(Option("out|o", description: "Output directory for the static HTML gallery (defaults to <dir>/html)."))
    string outDir;

    @(Option("twoslash", description: "Render TypeScript twoslash JSON payloads in the gallery."))
    bool twoslash;

    @(Option("markdown", description: "Treat input files as Markdown."))
    bool markdown;

    @(Option("raw", description: "Render raw source without markdown preview."))
    bool raw;

    int run(Program)(in Program program)
    {
        return executeGallery(program.value, this);
    }
}

@(Command("theme",
    shortDescription: "Inspect, list, and preview built-in color themes",
))
struct ThemeCmd
{
    @(Option("list|l", description: "List all built-in themes."))
    bool list;

    @(Argument("name", description: "Theme name to inspect.", optional: true))
    string name;

    int run(Program)(in Program program)
    {
        return executeTheme(program.value, this);
    }
}

@(Command("overlay",
    shortDescription: "Inspect available document overlays (twoslash, code coverage, trace)",
))
struct OverlayCmd
{
    @(Option("list|l", description: "List registered overlay kinds."))
    bool list;

    @(Argument("kind", description: "Overlay kind to inspect.", optional: true))
    string kind;

    int run(Program)(in Program program)
    {
        return executeOverlay(program.value, this);
    }
}

@(Command("config",
    shortDescription: "Display resolved configuration, fonts, and theme settings",
))
struct ConfigCmd
{
    @(Argument("action", description: "Config action: show | write | save (default: show).", optional: true))
    string action = "show";

    @(Option("show", description: "Show resolved configuration."))
    bool show;

    int run(Program)(in Program program)
    {
        return executeConfig(program.value, this);
    }
}

// ── Root Command ────────────────────────────────────────────────────────────

@(Command("hue",
    shortDescription: "Interactive syntax-highlighting file viewer, twoslash overlay renderer, and diff inspector",
))
struct HueCli
{
    @(Option("log-level", description: "Log level: trace | info | warning | error | critical | off (default: warning)."))
    LogLevel logLevel = LogLevel.warning;

    @(Option("theme", description: "Colour theme, by name (see sparkles.ui.themes for the built-in set)."))
    string theme = defaultTheme;

    @(Option("background", description: "Terminal background mode: no-background, spans, or full."))
    string background = "full";

    @Flatten("Overlay Options")
    OverlayOptions overlay;

    @Flatten("GUI Options")
    GuiOptions gui;

    @Subcommands
    SumType!(View, Diff, Pr, Gallery, ThemeCmd, OverlayCmd, ConfigCmd) command;
}

// ── Subcommand Handlers ─────────────────────────────────────────────────────

private bool resolveOverlayTarget(in HueCli root, ref bool forceTwoslash, ref string target)
{
    if (root.overlay.twoslash.length != 0)
    {
        forceTwoslash = true;
        target = root.overlay.twoslash;
    }
    foreach (ovl; root.overlay.overlays)
    {
        if (ovl.length == 0)
            continue;
        import std.string : indexOf;
        const eq = ovl.indexOf('=');
        const kind = eq >= 0 ? ovl[0 .. eq] : ovl;
        if (kind != "twoslash")
        {
            stderr.writeln("hue: unknown overlay kind '", kind, "' (see --list-overlays)");
            return false;
        }
        forceTwoslash = true;
        if (eq >= 0)
            target = ovl[eq + 1 .. $];
    }
    return true;
}

private GuiOptions copyGui(in GuiOptions g)
{
    GuiOptions res;
    res.font = g.font;
    res.fontSize = g.fontSize;
    res.fontBold = g.fontBold;
    res.fontItalic = g.fontItalic;
    res.fontBoldItalic = g.fontBoldItalic;
    res.fontCodepointMap = g.fontCodepointMap.dup;
    res.fontDir = g.fontDir.dup;
    res.theme = g.theme;
    res.windowWidth = g.windowWidth;
    res.windowHeight = g.windowHeight;
    res.noGui = g.noGui;
    res.gui = g.gui;
    res.tui = g.tui;
    return res;
}

private int executeView(in HueCli root, in View view)
{
    import source_set : collectSources, SourceEntry, SourceSet;

    initLogger(root.logLevel);

    if (root.overlay.listOverlays)
    {
        import std.stdio : writeln;
        writeln("twoslash    type annotations from a twoslash JSON payload " ~
            "(artifact: the payload; or make it the target — *.twoslash.json)");
        return 0;
    }

    bool forceTwoslash;
    string target = view.paths.length ? view.paths[0] : "";
    if (!resolveOverlayTarget(root, forceTwoslash, target))
        return 1;

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(root.theme, {
            warning(i"theme '$(root.theme)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, view.markdown, view.raw,
        view.patch, parseWhitespaceMode(view.diffOptions.diffIgnoreWhitespace),
        parseStructural(view.diffOptions.diffStructural),
        parseCommutative(view.diffOptions.diffCommutative));
    pipeline.forceDsv = view.dsv;
    pipeline.dsvDelimiter = view.dsvDelimiter;
    pipeline.dsvQuote = view.dsvQuote;
    pipeline.dsvHeader = view.dsvHeader;

    const backend = view.sink.resolveBackend(root.gui);

    ViewRenderOptions opt;
    opt.theme = root.theme;
    opt.background = root.background;
    opt.groupThemes = view.groupThemes;
    opt.treeWidth = view.treeWidth;
    opt.tabWidth = view.tabWidth;
    opt.listWhitespace = view.listWhitespace;
    opt.lineNumbers = view.lineNumbers;
    opt.codeLineNumbers = view.codeLineNumbers;
    opt.codeOverflow = view.codeOverflow;
    opt.codeMaxLines = view.codeMaxLines;
    opt.tableOverflow = view.tableOverflow;
    opt.tableMaxLines = view.tableMaxLines;
    opt.ansiCopy = view.ansiCopy;
    opt.tableCopy = view.tableCopy;
    opt.include = view.include.dup;
    opt.exclude = view.exclude.dup;
    opt.noLiveTypes = view.noLiveTypes;
    opt.diffLayout = view.diffOptions.diffLayout;
    opt.gui = copyGui(root.gui);

    SourceSet docSet;
    bool haveSet;
    string dirTarget;
    if (isDirectoryPath(target))
    {
        version (Android) {}
        else version (Posix)
            if (backend == Backend.tui)
            {
                import workspace : runWorkspace, WorkspaceDoc;

                auto themeSet = sortedThemes(root.theme, view.groupThemes);
                auto pl = &pipeline;
                return runWorkspace(target, isDir: true, WorkspaceDoc.init,
                    delegate WorkspaceDoc(string path) @system
                        => pl.load(path),
                    themeSet.names, themeSet.themes, themeSet.idx, labels,
                    &cache, view.include.dup, view.exclude.dup, view.treeWidth,
                    view.tabWidth, view.listWhitespace, liveTypes: !view.noLiveTypes,
                    codeOverflow: parseOverflow(view.codeOverflow, "--code-overflow"),
                    codeMaxLines: view.codeMaxLines,
                    tableOverflow: parseOverflow(view.tableOverflow, "--table-overflow"),
                    tableMaxLines: view.tableMaxLines);
            }
        const openSet = backend == Backend.gui
            || (forceTwoslash && backend == Backend.tui);
        if (!openSet)
            return runDirectoryTarget(target, forceTwoslash, root.theme, view.sink.html, "");
        docSet = collectSources(target, twoslash: forceTwoslash);
        if (docSet.empty)
        {
            stderr.writeln("hue: no renderable files in '", target, "'");
            return 1;
        }
        haveSet = true;
        dirTarget = target;
        target = docSet.current.path;
    }

    Document doc;
    try
    {
        if (target == "-" || (target.length == 0 && !isTerminal(StdStream.stdin)))
        {
            const stdinText = readStdinText();
            import document : looksLikePatch;

            if (stdinText.length && (view.patch || looksLikePatch(stdinText)))
                doc = pipeline.fromPatchSource("", "stdin", stdinText);
            else if (stdinText.length)
            {
                const string lang = view.language.length
                    ? canonicalLanguage(view.language)
                    : (view.markdown ? "markdown" : "");
                doc = pipeline.fromSource("", "stdin", stdinText, lang);
            }
            else
                doc = pipeline.fromSource("", "app.d", import("app.d"), "d");
        }
        else
            doc = (target.length && target != "-")
                ? pipeline.load(target, forceTwoslash, view.language)
                : pipeline.fromSource("", "app.d", import("app.d"),
                    view.language.length ? canonicalLanguage(view.language) : "d");
    }
    catch (Exception e)
    {
        stderr.writeln("hue: ", e.msg);
        return 1;
    }

    return renderDocument(backend, opt, doc, labels, theme, registry, cache,
        haveSet ? &docSet : null, &pipeline, dirTarget);
}

private int executeDiff(in HueCli root, in Diff diff)
{
    initLogger(root.logLevel);

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(root.theme, {
            warning(i"theme '$(root.theme)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, false, false,
        false, parseWhitespaceMode(diff.diff.diffIgnoreWhitespace),
        parseStructural(diff.diff.diffStructural),
        parseCommutative(diff.diff.diffCommutative));

    const backend = diff.sink.resolveBackend(root.gui);

    ViewRenderOptions opt;
    opt.theme = root.theme;
    opt.background = root.background;
    opt.lineNumbers = diff.lineNumbers;
    opt.codeOverflow = diff.codeOverflow;
    opt.codeMaxLines = diff.codeMaxLines;
    opt.tableOverflow = diff.tableOverflow;
    opt.tableMaxLines = diff.tableMaxLines;
    opt.diffLayout = diff.diff.diffLayout;
    opt.gui = copyGui(root.gui);

    Document doc;
    try
    {
        import std.file : exists, isFile;

        static bool isFilePath(string p) @system
        {
            try
                return p.exists && p.isFile;
            catch (Exception)
                return false;
        }

        if (!diff.staged && diff.targets.length > 1 && isFilePath(diff.targets[0])
            && isFilePath(diff.targets[1]))
            doc = diff.diff.diffPreview && isMarkdownPath(diff.targets[0])
                && isMarkdownPath(diff.targets[1])
                ? pipeline.loadDiffPreview(diff.targets[0], diff.targets[1])
                : pipeline.loadDiffPair(diff.targets[0], diff.targets[1]);
        else
        {
            string revspec;
            string[] filters;
            foreach (a; diff.targets)
                if (revspec.length == 0 && !isFilePath(a))
                    revspec = a;
                else
                    filters ~= a;
            doc = diff.diff.diffPreview
                ? pipeline.loadGitDiffPreview(revspec, diff.staged, filters)
                : pipeline.loadGitDiff(revspec, diff.staged, filters);
        }
    }
    catch (Exception e)
    {
        stderr.writeln("hue: ", e.msg);
        return 1;
    }

    return renderDocument(backend, opt, doc, labels, theme, registry, cache,
        null, &pipeline, null);
}

private int executePr(in HueCli root, in Pr pr)
{
    initLogger(root.logLevel);

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(root.theme, {
            warning(i"theme '$(root.theme)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, false, false,
        false, parseWhitespaceMode(pr.diff.diffIgnoreWhitespace),
        parseStructural(pr.diff.diffStructural),
        parseCommutative(pr.diff.diffCommutative));

    const backend = pr.sink.resolveBackend(root.gui);

    ViewRenderOptions opt;
    opt.theme = root.theme;
    opt.background = root.background;
    opt.lineNumbers = pr.lineNumbers;
    opt.codeOverflow = pr.codeOverflow;
    opt.codeMaxLines = pr.codeMaxLines;
    opt.tableOverflow = pr.tableOverflow;
    opt.tableMaxLines = pr.tableMaxLines;
    opt.diffLayout = pr.diff.diffLayout;
    opt.gui = copyGui(root.gui);

    Document doc;
    try
    {
        import forge_client : fetchPullRequest;
        import std.conv : text;

        auto fetched = fetchPullRequest(pr.pr);
        if (fetched.hasError)
        {
            stderr.writeln("hue: ", fetched.error.toString());
            return 1;
        }
        const got = fetched.value;
        doc = pipeline.fromPatchSource(null,
            text(got.repo.owner, "/", got.repo.name, " #",
                got.pr.number), got.patch);
        doc.diffSession.header = prHeader(registry, got.pr);
        doc.diffSession.threads = prThreads(registry, got.threads);
        if (got.threadsNote.length)
            warning(i"review threads unavailable: $(got.threadsNote)");
    }
    catch (Exception e)
    {
        stderr.writeln("hue: ", e.msg);
        return 1;
    }

    return renderDocument(backend, opt, doc, labels, theme, registry, cache,
        null, &pipeline, null);
}

private int executeGallery(in HueCli root, in Gallery gallery)
{
    initLogger(root.logLevel);
    import gallery : GalleryOptions, plainFragment, twoslashFragment, writeGallery;
    import source_set : collectSources, SourceEntry;
    import std.path : buildPath;

    string dir = gallery.dir.length ? gallery.dir : ".";
    bool twoslash = gallery.twoslash || root.overlay.twoslash.length != 0;
    auto set = collectSources(dir, twoslash);
    if (set.empty)
        warning(i"no renderable files in '$(dir)' — writing an empty gallery index");

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(root.theme, {
            warning(i"theme '$(root.theme)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);

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

    const outDir = gallery.outDir.length ? gallery.outDir : buildPath(dir, "html");
    const gopt = twoslash
        ? GalleryOptions(
            titlePrefix: "twoslash",
            heading: "twoslash overlay examples",
            indexTitle: "twoslash examples",
            blurb: "Rendered by <code>hue gallery --twoslash</code>. Open one and " ~
                "hover the underlined tokens to see the popups.")
        : GalleryOptions(
            titlePrefix: "hue",
            heading: "hue gallery",
            blurb: "Rendered by <code>hue gallery</code>.");

    const n = writeGallery(set, outDir, gopt, &renderOne);
    stderr.writeln("hue: wrote ", n, " page(s) + index.html to ", outDir);
    return 0;
}

private int executeTheme(in HueCli root, in ThemeCmd cmd)
{
    initLogger(root.logLevel);
    import std.stdio : writeln;

    if (cmd.list || cmd.name.length == 0)
    {
        writeln("Available themes:");
        foreach (name; builtinThemes.byKey)
            writeln("  ", name);
        return 0;
    }

    if (auto p = cmd.name in builtinThemes)
    {
        writeln("Theme '", cmd.name, "':");
        writeln("  Foreground: ", p.defaultFg);
        writeln("  Background: ", p.defaultBg);
        return 0;
    }

    stderr.writeln("hue: unknown theme '", cmd.name, "'");
    return 1;
}

private int executeOverlay(in HueCli root, in OverlayCmd cmd)
{
    initLogger(root.logLevel);
    import std.stdio : writeln;

    writeln("Available overlays:");
    writeln("  twoslash    Type annotations and hover queries from TypeScript twoslash JSON payload");
    return 0;
}

private int executeConfig(in HueCli root, in ConfigCmd cmd)
{
    initLogger(root.logLevel);
    import std.stdio : writeln;

    writeln("Hue Configuration:");
    writeln("  Theme:       ", root.theme);
    writeln("  Background:  ", root.background);
    writeln("  Log Level:   ", root.logLevel);
    writeln("  GUI Font:    ", root.gui.font);
    writeln("  Font Size:   ", root.gui.fontSize);
    writeln("  Display:     ", displayAvailable() ? "present" : "absent");
    return 0;
}

private int renderDocument(Backend backend, in ViewRenderOptions opt, ref Document doc,
    in LabelSet labels, in ResolvedTheme theme, ref GrammarRegistry registry,
    ref TsConfigCache cache, scope SourceSet* docSet,
    scope DocumentPipeline* pipeline, string dirTarget)
{
    final switch (backend)
    {
        case Backend.gui:
            return runGuiSink(opt, doc, labels, theme, cache,
                docSet, pipeline, dirTarget);
        case Backend.html:
            return runHtmlSink(doc, theme, registry, cache,
                parseDiffLayout(opt.diffLayout));
        case Backend.tui:
            return runTuiSink(opt, doc, labels, theme, cache,
                docSet, pipeline);
        case Backend.ansi:
            return runAnsiSink(opt, doc, theme, cache);
    }
}

// ── Helper Utilities ────────────────────────────────────────────────────────

/// Parses a `--code-overflow`/`--table-overflow` value into the shared
/// `OverflowPolicy`: `scroll`, `wrap`, or `wrap-at:N` (N > 0); anything else
/// warns and falls back to `scroll`.
private OverflowPolicy parseOverflow(string name, string flag)
{
    import std.algorithm.searching : startsWith;
    import std.conv : ConvException, to;

    switch (name)
    {
        case "wrap":   return OverflowPolicy(WrapOverflow());
        case "scroll": return OverflowPolicy(ScrollOverflow());
        default:
            if (name.startsWith("wrap-at:"))
            {
                try
                {
                    const n = name["wrap-at:".length .. $].to!int;
                    if (n > 0)
                        return OverflowPolicy(WrapAtOverflow(n));
                }
                catch (ConvException)
                {
                }
            }
            warning(i"unknown $(flag) '$(name)'; using 'scroll'");
            return OverflowPolicy(ScrollOverflow());
    }
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

private int runDirectoryTarget(string dir, bool twoslash, string themeName,
    bool isHtml, string outDirParam) @system
{
    import std.path : buildPath;
    import std.stdio : writeln;

    import gallery : GalleryOptions, plainFragment, twoslashFragment, writeGallery;
    import source_set : collectSources, SourceEntry;

    auto set = collectSources(dir, twoslash);

    if (!isHtml)
    {
        if (set.empty)
        {
            stderr.writeln("hue: no renderable files in '", dir, "'");
            return 1;
        }
        foreach (ref const e; set.entries)
            writeln(e.name, "  ", e.summary);
        stderr.writeln("hue: ", set.length, " document(s); add --html [--out <dir>] " ~
            "or use 'hue gallery " ~ dir ~ "' to render them as a gallery");
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

    const outDir = outDirParam.length ? outDirParam : buildPath(dir, "html");
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

private DiffViewOptions htmlDiffOptions(DiffLayout layout) @safe pure nothrow @nogc
{
    DiffViewOptions opt;
    opt.layout = layout;
    return opt;
}

private DiffLayout parseDiffLayout(string spelling) @safe
{
    switch (spelling)
    {
        case "unified": return DiffLayout.unified;
        case "split":   return DiffLayout.split;
        default:
            warning(i"unknown --diff-layout '$(spelling)'; using unified");
            return DiffLayout.unified;
    }
}

private WhitespaceMode parseWhitespaceMode(string spelling) @safe
{
    switch (spelling)
    {
        case "exact":    return WhitespaceMode.exact;
        case "trailing": return WhitespaceMode.trailing;
        case "change":   return WhitespaceMode.change;
        case "all":      return WhitespaceMode.all;
        default:
            warning(i"unknown --diff-ignore-whitespace '$(spelling)'; using exact");
            return WhitespaceMode.exact;
    }
}

private SessionHeader prHeader(ref GrammarRegistry reg, in PullRequest pr) @system
{
    import sparkles.syntax.md.model : extractMarkdown;

    SessionHeader h = {
        present: true,
        title: pr.title,
        state: pr.draft ? "draft" : pr.state,
        author: pr.author,
        baseRef: pr.baseRef,
        headRef: pr.headRef,
    };
    if (pr.description.length)
        h.description = extractMarkdown(reg, pr.description);
    return h;
}

private AnchoredThread[] prThreads(ref GrammarRegistry reg,
    in CommentThread[] threads) @system
{
    import sparkles.syntax.md.model : extractMarkdown;

    AnchoredThread[] out_;
    foreach (ref t; threads)
    {
        AnchoredThread a = {
            path: t.path,
            line: t.line,
            oldSide: t.side == ThreadSide.oldSide,
            resolved: t.resolved,
            outdated: t.outdated,
        };
        foreach (ref c; t.comments)
            a.comments ~= ThreadComment(c.author, shortDate(c.createdAt),
                c.body_.length ? extractMarkdown(reg, c.body_) : MdDoc.init);
        out_ ~= a;
    }
    return out_;
}

private string shortDate(string iso) @safe pure nothrow
    => iso.length >= 10 ? iso[0 .. 10] : iso;

private StructuralPolicy parseStructural(string spelling) @safe
{
    import diff_structural : parseStructuralPolicy;

    bool ok;
    const p = parseStructuralPolicy(spelling, ok);
    if (!ok)
        warning(i"unknown --diff-structural '$(spelling)'; using auto");
    return p;
}

private CommutativeKind[] parseCommutative(string spelling) @safe
{
    import diff_commutative : parseCommutativeKinds;

    bool ok;
    auto kinds = parseCommutativeKinds(spelling, ok);
    if (!ok)
        warning(i"--diff-commutative wants language:node entries; ignoring the malformed ones in '$(spelling)'");
    return kinds;
}

private bool isMarkdownPath(string path) @safe
    => canonicalLanguage(path.extension.chompPrefix(".")) == "markdown";

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

int main(string[] args)
{
    initLogger(LogLevel.warning);

    version (Android)
    {
        import android_glue : extractAssetsIfNeeded, installLogcatSink, loadDebugEnv;
        import core.stdc.stdlib : exit;

        installLogcatSink(LogLevel.warning);
        loadDebugEnv();
        if (!extractAssetsIfNeeded())
            warning(i"hue: asset bundle missing — plain text, built-in document only");
    }

    return runCli!HueCli(args);
}

// ── The four sinks — each a `final switch` over the document's kind ─────────

/// Static ANSI to stdout (piped / redirected / non-tty).
private int runAnsiSink(in ViewRenderOptions opt, ref Document doc,
    in ResolvedTheme theme, ref TsConfigCache cache) @system
{
    if (doc.kind == ContentKind.twoslash && tryTwoslashCapture(doc, theme, cache))
        return 0;

    SmallBuffer!char output;
    const depth = detectColorDepth();
    const bgMode = parseBackgroundMode(opt.background);
    final switch (doc.kind) with (ContentKind)
    {
        case twoslash:
            renderTwoslashAnsi(doc.twoslash, doc.events, theme, cache, output,
                TwoslashAnsiOptions(depth: depth, italics: true, emitBackground: true));
            break;
        case markdown:
        case dsv:
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
            MdViewOptions mopt = {
                theme: MdViewTheme.derive(theme, pageFg, pageBg),
                maxWidth: previewWidth(),
                fenceRenderer: hueFenceRenderer(&cache, &theme, pageFg),
                diffBlocks: doc.preview.decorations,
                codeOverflow: parseOverflow(opt.codeOverflow, "--code-overflow"),
                codeMaxLines: opt.codeMaxLines < 0 ? 0 : opt.codeMaxLines,
                tableOverflow: parseOverflow(opt.tableOverflow, "--table-overflow"),
                tableMaxLines: opt.tableMaxLines < 0 ? 0 : opt.tableMaxLines,
                tableExtras: doc.preview.tableExtras,
            };
            auto tree = viewMarkdown(doc.preview.doc, mopt);
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
            dopt.layout = parseDiffLayout(opt.diffLayout);
            auto tree = viewDiffDoc(doc.diffDoc, dopt,
                doc.diffSides, highlightedFenceRenderer(&cache, &theme, pageFg),
                doc.diffSession, null, previewWidth());
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
    ref GrammarRegistry registry, ref TsConfigCache cache,
    DiffLayout diffLayout = DiffLayout.unified) @system
{
    final switch (doc.kind) with (ContentKind)
    {
        case twoslash:
            import gallery : twoslashFragment;

            write(twoslashFragment(doc.twoslash, doc.events, theme, cache));
            return 0;
        case markdown:
            return emitMarkdownHtml(doc.source, theme, registry, cache);
        case code:
            import gallery : plainFragment;

            write(plainFragment(doc.source, doc.events, theme));
            return 0;
        case dsv:
        {
            import sparkles.syntax.md.render_widgets : MdViewOptions,
                MdViewTheme, viewMarkdown;
            import sparkles.ui.interp.html : writeWidgetHtmlPage;
            import sparkles.ui.style : defaultTwoslashPalette;

            // The markdown arm re-extracts markdown from `doc.source`, which
            // for DSV is the adapter's decoded buffer — render the already
            // built widget tree instead (the diff arm's route, `DSG6`).
            const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            MdViewOptions mopt = {
                theme: MdViewTheme.derive(theme, pageFg, pageBg),
                maxWidth: previewWidth(),
                tableExtras: doc.preview.tableExtras,
            };
            SmallBuffer!char htmlOut;
            writeWidgetHtmlPage(htmlOut, viewMarkdown(doc.preview.doc, mopt),
                defaultTwoslashPalette(), pageFg, pageBg, doc.title);
            write(htmlOut[]);
            return 0;
        }
        case diff:
            import diff_view : viewDiffDoc;
            import sparkles.ui.interp.html : writeWidgetHtmlPage;
            import sparkles.ui.style : defaultTwoslashPalette;

            import diff_view : DiffViewOptions;
            import sparkles.syntax.md.render_widgets : highlightedFenceRenderer;

            const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            SmallBuffer!char htmlOut;
            writeWidgetHtmlPage(htmlOut,
                viewDiffDoc(doc.diffDoc, htmlDiffOptions(diffLayout), doc.diffSides,
                    highlightedFenceRenderer(&cache, &theme, pageFg),
                    doc.diffSession),
                defaultTwoslashPalette(), pageFg, pageBg, doc.title);
            write(htmlOut[]);
            return 0;
    }
}

/// The interactive terminal (alt screen). Posix gets the full-screen viewers;
/// elsewhere the theme-selection previewer (no raw-termios TUI) fills in.
private int runTuiSink(in ViewRenderOptions opt, ref Document doc, in LabelSet labels,
    in ResolvedTheme theme, ref TsConfigCache cache,
    scope SourceSet* docSet, scope DocumentPipeline* pipeline = null) @system
{
    import source_set : SourceSet;

    if (doc.kind == ContentKind.twoslash && tryTwoslashCapture(doc, theme, cache))
        return 0;

    auto themeSet = sortedThemes(opt.theme, opt.groupThemes);

    version (Android)
    {
        return runAnsiSink(opt, doc, theme, cache);
    }
    else version (Posix)
    {
        import workspace : runWorkspace, WorkspaceDoc, WsLoader;

        WsLoader loader;
        if (pipeline !is null)
        {
            auto pl = pipeline;
            loader = delegate WorkspaceDoc(string path) @system
                => pl.load(path);
        }
        WorkspaceDoc delegate() @system reloadDiff;
        if (pipeline !is null && doc.diffSession.stageable)
        {
            auto pl = pipeline;
            auto paths = doc.diffPaths.dup;
            reloadDiff = delegate WorkspaceDoc() @system
                => pl.loadGitDiff(null, false, paths.dup);
        }
        return runWorkspace(doc.path, isDir: false, doc,
            loader, themeSet.names, themeSet.themes, themeSet.idx, labels,
            &cache, opt.include.dup, opt.exclude.dup, opt.treeWidth,
            opt.tabWidth, opt.listWhitespace, liveTypes: !opt.noLiveTypes,
            diffLayout: parseDiffLayout(opt.diffLayout),
            codeOverflow: parseOverflow(opt.codeOverflow, "--code-overflow"),
            codeMaxLines: opt.codeMaxLines,
            tableOverflow: parseOverflow(opt.tableOverflow, "--table-overflow"),
            tableMaxLines: opt.tableMaxLines,
            reloadDiff: reloadDiff);
    }
    else
    {
        return runAnsiSink(opt, doc, theme, cache);
    }
}

/// The raylib window (a build without it reports rather than falls through —
/// `--gui` is explicit intent).
private int runGuiSink(in ViewRenderOptions opt, ref Document doc, in LabelSet labels,
    in ResolvedTheme theme, ref TsConfigCache cache,
    scope SourceSet* docSet, scope DocumentPipeline* pipeline,
    string treeRoot = null) @system
{
    import source_set : SourceSet;

    version (HueGui)
    {
        import gui : GuiArgs, LoadedDoc, runGui;
        import sparkles.raylib_text : FontSet;

        const startInTree = treeRoot.length != 0;

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

        LoadedDoc loadDoc(string path) @system
            => pipeline.load(path);

        auto themeSet = sortedThemes(opt.theme, opt.groupThemes);
        GuiOptions gui = copyGui(opt.gui);
        version (Android)
        {
            gui.font = defaultGuiFont;
            gui.fontBold = defaultGuiFontFamily;
            gui.fontItalic = defaultGuiFontFamily;
            gui.fontBoldItalic = defaultGuiFontFamily;
        }

        import std.process : environment;
        import gui_state : GuiCapture;

        auto capture = GuiCapture.fromEnv(
            (string name, string fallback) => environment.get(name, fallback));
        version (Android)
        {
            import android_glue : androidDataDir;

            if (capture.screenshotPath.length && capture.screenshotPath[0] != '/')
                capture.screenshotPath = androidDataDir() ~ "/" ~ capture.screenshotPath;
        }

        return runGui(GuiArgs(
            title: doc.title,
            source: doc.source,
            events: doc.events,
            labels: labels,
            names: themeSet.names,
            themes: themeSet.themes,
            startIdx: themeSet.idx,
            preview: doc.preview,
            gui: gui,
            lineNumbers: opt.lineNumbers,
            codeLineNumbers: opt.codeLineNumbers,
            ansiCopyStrip: opt.ansiCopy == "strip",
            tableCopy: parseTableCopy(opt.tableCopy),
            codeOverflow: parseOverflow(opt.codeOverflow, "--code-overflow"),
            codeMaxLines: opt.codeMaxLines,
            tableOverflow: parseOverflow(opt.tableOverflow, "--table-overflow"),
            tableMaxLines: opt.tableMaxLines,
            set: docSet,
            loadDoc: &loadDoc,
            tsCache: &cache,
            twoslash: doc.twoslash,
            docPath: doc.path,
            startInTree: startInTree,
            treeRoot: treeRoot,
            docLang: doc.lang,
            includeGlobs: opt.include.dup,
            excludeGlobs: opt.exclude.dup,
            treeWidth: opt.treeWidth,
            tabWidth: opt.tabWidth,
            listWhitespace: opt.listWhitespace,
            liveTypes: !opt.noLiveTypes,
            initialDiff: doc.diffDoc,
            initialDiffSides: doc.diffSides,
            initialDiffSession: doc.diffSession,
            capture: capture,
        ));
    }
    else
    {
        stderr.writeln("hue: this build has no GUI support (built with " ~
            "-c no-gui); use the default build: dub build :hue");
        return 1;
    }
}

/// Sorted theme names + the parallel theme values the previewer/GUI index per
/// Whether a theme reads as LIGHT (its document background's relative
/// luminance above the midpoint) — the `--group-themes` partition key.
private bool isLightTheme(in Theme t) @safe pure nothrow @nogc
{
    import sparkles.base.term_color : toRgb;

    const bg = toRgb(t.defaultBg, RgbColor(0x1e, 0x1e, 0x1e));
    return 2126 * cast(int) bg.r + 7152 * cast(int) bg.g
        + 722 * cast(int) bg.b > 10_000 * 128;
}

/// frame (avoids per-frame GC AA lookups), plus the start index for `name`.
/// With `grouped` (`--group-themes`, the default), the alphabetical order is
/// stably partitioned dark-first: ←/→ walks each brightness group as one
/// contiguous run, so rapidly cycling dark themes never flashes a light
/// background (and vice versa) until the boundary is crossed deliberately.
private auto sortedThemes(string name, bool grouped = true)
{
    import std.algorithm.iteration : map;
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.range : iota;

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
    if (grouped)
    {
        auto order = iota(s.names.length).array;
        sort!((a, b) => cast(int) isLightTheme(s.themes[a])
            < cast(int) isLightTheme(s.themes[b]),
            SwapStrategy.stable)(order);
        s.names = order.map!(i => s.names[i]).array;
        s.themes = order.map!(i => s.themes[i]).array;
    }
    foreach (i, n; s.names)
        if (n == name)
        {
            s.idx = i;
            break;
        }
    return s;
}

@("app.sortedThemes.groupsByBrightness")
@system unittest
{
    // Grouped (the default): each brightness forms ONE contiguous run —
    // cycling inside a group can never flash the other's background.
    const g = sortedThemes("catppuccin-mocha");
    int transitions;
    foreach (i; 1 .. g.themes.length)
        if (isLightTheme(g.themes[i]) != isLightTheme(g.themes[i - 1]))
            ++transitions;
    assert(transitions <= 1, "brightness groups must be contiguous");
    assert(g.names[g.idx] == "catppuccin-mocha", "selection survives");

    // Ungrouped keeps the plain alphabetical order.
    import std.algorithm.sorting : isSorted;

    const u = sortedThemes("catppuccin-mocha", false);
    assert(u.names.isSorted);
    assert(u.names[u.idx] == "catppuccin-mocha");
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
