/**
The command-line surface: option groups, the seven subcommands, the root
`HueCli` — moved out of `app.d` so the configuration bridge below is
unit-testable (`app.d` is excluded from the unittest build) — plus that
bridge itself:

$(LIST
    * `cliOverlay` turns the parsed command line into a `Sparse!HueConfig`
        using `CommandNode.seenOptions`, so the CLI is `CFG2`'s highest
        layer: only flags the user actually typed override the files;
    * `loadConfigFor` resolves the full five-layer stack for one invocation;
    * `viewRenderOptionsOf` / `guiOptionsOf` project the effective config
        into the structs the sinks consume — the projections that replaced
        the hand-copied blocks (and the `copyGui` drift bug) in `app.d`.
)

The duplicate `--theme` collapses here: the root option and the flattened
`GuiOptions.theme` both map to `appearance.theme`, root winning — everything
downstream reads the config, so the dead `gui.theme` path is gone.

The subcommand `run` bodies import their executors from `app` lazily
(template-instantiation time), so this module compiles without `app.d` in
the unittest build.
*/
module cli;

import std.sumtype : match, SumType;

import sparkles.core_cli.args;

import sparkles.base.logger : LogLevel, warning;
import sparkles.base.term_caps : isTerminal, StdStream;
import sparkles.source_view.markdown : OverflowPolicy, ScrollOverflow,
    WrapAtOverflow, WrapOverflow;

import ansi_model : BackgroundMode;
import diff_commutative : CommutativeKind;
import diff_structural : StructuralPolicy;
import diff_view : DiffLayout;
import viewer_model : ScrollAnchorMode;
import sparkles.diff : WhitespaceMode;

import sparkles.ui_app.backend : Backend, BackendPolicy,
    hostPickBackend = pickBackend, platformForcedBackend;
import sparkles.ui_app.display : displayAvailable;
import sparkles.ui_app.gui_options : defaultTheme, GuiOptions;

import settings : AnsiCopyMode, DefaultView, HueConfig, TableCopyMode;
import settings_load : LoadedConfig, loadHueConfig;
import settings_overlay : applyOverlay, Origin, OriginKind, Sparse;

// ── Option Groupings & Subcommands ──────────────────────────────────────────

/// Supported document overlay kinds.
enum OverlayKind
{
    @(Description("type annotations from a twoslash JSON payload (artifact: the payload; or make it the target — *.twoslash.json)"))
    twoslash,

    @(Description("code coverage from .lst, .gcov, .info or .json (artifact: the coverage report; or --cov=<artifact>)"))
    coverage,
}

/// Standalone overlay configuration.
struct OverlayOptions
{
    @(Option("twoslash", description: "Render a TypeScript twoslash JSON payload as type-annotated overlay (compatibility alias for --overlay twoslash=<path>)."))
    string twoslash;

    @(Option("overlay", description: "Attach an overlay: <kind>[=<artifact>] (e.g. twoslash=nodes.json, coverage=cov.json). Can be specified multiple times."))
    string[] overlays;

    @(Option("cov", description: "Attach a code coverage artifact (.lst, .gcov, .info, .json) to the document (compatibility alias for --overlay coverage=<artifact>)."))
    string cov;

    @(Option("no-auto-cov", description: "Do not look for a coverage artifact in build/coverage when none is named."))
    bool noAutoCov;

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

    @(Option("diff-show-formatting", description: "Show whitespace-only hunks in full instead of folding them to a badge."))
    bool diffShowFormatting;

    @(Option("diff-context", description: "Unchanged lines kept around each hunk (default 3)."))
    int diffContext = 3;

    @(Option("diff-chrome", description: "Render the file header, hunk headers and elided-context bands (default on; --no-diff-chrome leaves only the rows)."))
    bool diffChrome = true;
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
    int width;
    int height;
    bool groupThemes = true;
    int treeWidth = 32;
    int tabWidth = 4;
    bool listWhitespace = false;
    bool lineNumbers = true;
    string gutter = "all";
    bool codeLineNumbers = true;
    string codeOverflow = "scroll";
    int codeMaxLines = -1;
    string tableOverflow = "scroll";
    int tableMaxLines = -1;
    string ansiCopy = "raw";
    string tableCopy = "auto";
    string[] include;
    string[] exclude;
    bool noLiveTypes = false;
    string diffLayout = "unified";
    bool diffShowFormatting;
    bool diffChrome = true;
    GuiOptions gui;
    bool formatPreview = false;  /// `FMV8`: start in the format preview
    int formatWidth = 0;         /// ruler column (0 = discover)
    string formatter;            /// preferred formatter name
    string scrollAnchor = "segment"; /// `NAV5`: what a re-layout pins
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

    @(Option("line-numbers", description: "Show the file line-number gutter (default on). Shorthand for dropping it from --gutter."))
    bool lineNumbers = true;

    @(Option("gutter", description: "Which gutter channels to show: 'all', 'none', or a comma-separated list of numbers, icons, coverage."))
    string gutter = "all";

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

    @(Option("table-copy", description: "How a table grid selection copies: 'auto' (source for DSV, else tsv), 'tsv', 'markdown' or 'source' (the DSV dialect)."))
    string tableCopy = "auto";

    @(Option("include", description: "Explorer glob(s) to always show. Repeatable."))
    string[] include;

    @(Option("exclude", description: "Explorer glob(s) to hide. Repeatable."))
    string[] exclude;

    @(Option("no-live-types", description: "Disable live D types in the interactive views."))
    bool noLiveTypes;

    @(Option("format-preview", description: "Start in the in-memory format preview: the buffer reformats through the language's formatter; the file is never written."))
    bool formatPreview;

    @(Option("format-width", description: "Ruler column for the format preview (default: discover from .editorconfig)."))
    int formatWidth = 0;

    @(Option("formatter", description: "Formatter for the format preview; a miss lists the candidates."))
    string formatter;

    @(Option("scroll-anchor", description: "What a resize or font change keeps at the top: segment (the exact wrapped segment, default) or line (the source line's first segment)."))
    string scrollAnchor = "segment";

    @Flatten
    DiffOptions diffOptions;

    int run(Program)(in Program program)
    {
        import app : executeView;

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
        import app : executeDiff;

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
        import app : executePr;

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

    @(Option("twoslash", description: "Render twoslash overlays: committed *.twoslash.json payloads, and .d sources extracted via twoslash-extract --dub."))
    bool twoslash;

    @(Option("jobs|j", description: "Extractor processes to run at once for --twoslash (0 = one per usable CPU)."))
    uint jobs;

    @(Option("repo-url", description: "Blob base for the breadcrumb forge links, e.g. https://github.com/owner/repo/blob/main."))
    string repoUrl;

    @(Option("repo-prefix", description: "The gallery root's path inside that repository, when it is not the repo root."))
    string repoPrefix;

    @(Option("markdown", description: "Treat input files as Markdown."))
    bool markdown;

    @(Option("raw", description: "Render raw source without markdown preview."))
    bool raw;

    @(Option("dark-theme", description: "Second theme for dark mode: --theme becomes the light theme and this one's rules are emitted under an html.dark scope in the shared stylesheet, so one page serves both. Implies a shared stylesheet, so the pages carry no style block; pair with --stylesheet or --emit-stylesheet."))
    string darkTheme;

    @(Option("stylesheet", description: "Link this href from the emitted pages instead of embedding the theme stylesheet in a style block. Write the file itself with --emit-stylesheet."))
    string stylesheet;

    @(Option("emit-stylesheet", description: "Also write the stylesheet the pages need (both themes when --dark-theme is set) to this file."))
    string emitStylesheet;

    @(Option("recursive|r", description: "Render the whole subtree, mirroring its directory structure in the output, with an index per directory. Git-ignored files are skipped."))
    bool recursive;

    @(Option("root", description: "Directory the mirrored output paths are relative to (default: the gallery target). Also the base for view-on-GitHub links."))
    string root;

    @(Option("sidebar", description: "Render the docs-site sidebar on every page: path to a VitePress-shaped sidebar.json (e.g. docs/.vitepress/sidebar.json)."))
    string sidebar;

    @(Option("site-base", description: "Base URL the sidebar's site-absolute routes resolve against, e.g. https://docs.example (default: none, links stay root-absolute)."))
    string siteBase;

    int run(Program)(in Program program)
    {
        import app : executeGallery;

        return executeGallery(program.value, this);
    }
}

@(Command("site",
    shortDescription: "Render the docs site's source listings: link-driven discovery, mirrored pages, manifest.json",
))
struct Site
{
    @(Option("out|o", description: "Output directory for the listing pages + manifest.json (default: <repo-root>/docs/public/src)."))
    string outDir;

    @(Option("repo-root", description: "Repository root the discovery and the mirrored paths are relative to (default: the current directory)."))
    string repoRoot;

    @(Option("config", description: "Site knobs file (default: <repo-root>/docs/hue-site.json; absent means all defaults)."))
    string config;

    @(Option("dark-theme", description: "Second theme for dark mode, emitted under an html.dark scope in the shared stylesheet (see hue gallery --dark-theme)."))
    string darkTheme;

    @(Option("no-twoslash", description: "Render .d sources as plain listings instead of batch-extracting twoslash overlays (they are on by default)."))
    bool noTwoslash;

    @(Option("jobs|j", description: "Extractor processes to run at once for twoslash (0 = one per usable CPU)."))
    uint jobs;

    @(Option("sidebar", description: "sidebar.json rendered as a site sidebar on every page (default: <repo-root>/docs/.vitepress/sidebar.json when present; pass an empty value to disable)."))
    string sidebar = "auto";

    @(Option("site-base", description: "Base URL the sidebar's site-absolute routes resolve against (default: none, links stay root-absolute)."))
    string siteBase;

    @(Option("repo-url", description: "Blob base for the breadcrumb forge links, e.g. https://github.com/owner/repo/blob/main."))
    string repoUrl;

    @(Option("title-prefix", description: "The <title> prefix every listing page carries (default: sparkles)."))
    string titlePrefix = "sparkles";

    int run(Program)(in Program program)
    {
        import app : executeSite;

        return executeSite(program.value, this);
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
        import app : executeTheme;

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
        import app : executeOverlay;

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

    @(Option("changed", description: "config show: only settings whose value did not come from the compiled default."))
    bool changed;

    @(Option("force", description: "config write: overwrite an existing file."))
    bool force;

    int run(Program)(in Program program)
    {
        import app : executeConfig;

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

    @(Option("config", description: "Configuration file to read instead of the platform default (the CFG2 user layer)."))
    string configFile;

    @(Option("theme", description: "Colour theme, by name (see sparkles.ui.themes for the built-in set)."))
    string theme = defaultTheme;

    @(Option("background", description: "Terminal background mode: no-background, spans, or full."))
    string background = "full";

    @(Option("width", description: "Columns a one-shot (--ansi/--html) render lays out in (default: the terminal's, capped at 120)."))
    int width;

    @(Option("height", description: "Minimum rows a one-shot (--ansi/--html) render fills; shorter content is padded (default: the content's own height)."))
    int height;

    @Flatten("Overlay Options")
    OverlayOptions overlay;

    @Flatten("GUI Options")
    GuiOptions gui;

    @Subcommands
    SumType!(View, Diff, Pr, Gallery, Site, ThemeCmd, OverlayCmd, ConfigCmd) command;
}

// ── CLI value parsing (string → enum, warn-and-default) ─────────────────────

/// Parses a `--background` value; unknown spellings warn and fall back.
BackgroundMode parseBackgroundMode(string name) @safe
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

DiffLayout parseDiffLayout(string spelling) @safe
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

/// `NAV5`: the anchor mode named on the command line.
ScrollAnchorMode parseScrollAnchor(string spelling) @safe
{
    switch (spelling)
    {
        case "segment": return ScrollAnchorMode.segment;
        case "line":    return ScrollAnchorMode.line;
        default:
            warning(i"unknown --scroll-anchor '$(spelling)'; using segment");
            return ScrollAnchorMode.segment;
    }
}

WhitespaceMode parseWhitespaceMode(string spelling) @safe
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

StructuralPolicy parseStructural(string spelling) @safe
{
    import diff_structural : parseStructuralPolicy;

    bool ok;
    const p = parseStructuralPolicy(spelling, ok);
    if (!ok)
        warning(i"unknown --diff-structural '$(spelling)'; using auto");
    return p;
}

CommutativeKind[] parseCommutative(string spelling) @safe
{
    import diff_commutative : parseCommutativeKinds;

    bool ok;
    auto kinds = parseCommutativeKinds(spelling, ok);
    if (!ok)
        warning(i"--diff-commutative wants language:node entries; ignoring the malformed ones in '$(spelling)'");
    return kinds;
}

AnsiCopyMode parseAnsiCopy(string spelling) @safe
{
    switch (spelling)
    {
        case "raw":   return AnsiCopyMode.raw;
        case "strip": return AnsiCopyMode.strip;
        default:
            warning(i"unknown --ansi-copy '$(spelling)'; using raw");
            return AnsiCopyMode.raw;
    }
}

TableCopyMode parseTableCopy(string spelling) @safe
{
    switch (spelling)
    {
        case "auto":     return TableCopyMode.detect;
        case "tsv":      return TableCopyMode.tsv;
        case "markdown": return TableCopyMode.markdown;
        case "source":   return TableCopyMode.source;
        default:
            warning(i"unknown --table-copy '$(spelling)'; using auto");
            return TableCopyMode.detect;
    }
}

/// Parses a `--code-overflow`/`--table-overflow` value into the shared
/// `OverflowPolicy`: `scroll`, `wrap`, or `wrap-at:N` (N > 0); anything else
/// warns and falls back to `scroll`.
OverflowPolicy parseOverflow(string name, string flag)
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

// ── Enum → CLI spelling (the sinks still speak the flag vocabulary) ─────────
//
// `ViewRenderOptions` keeps its historical string fields; these unparse the
// config's enums back into the exact flag spellings its consumers parse.
// Total by construction, and pinned against the parsers by test below.

string cliText(BackgroundMode m) @safe pure nothrow @nogc
{
    final switch (m)
    {
        case BackgroundMode.noBackground: return "no-background";
        case BackgroundMode.spans:        return "spans";
        case BackgroundMode.full:         return "full";
    }
}

string cliText(DiffLayout l) @safe pure nothrow @nogc
{
    final switch (l)
    {
        case DiffLayout.unified: return "unified";
        case DiffLayout.split:   return "split";
    }
}

string cliText(ScrollAnchorMode m) @safe pure nothrow @nogc
{
    final switch (m)
    {
        case ScrollAnchorMode.segment: return "segment";
        case ScrollAnchorMode.line:    return "line";
    }
}

string cliText(AnsiCopyMode m) @safe pure nothrow @nogc
{
    final switch (m)
    {
        case AnsiCopyMode.raw:   return "raw";
        case AnsiCopyMode.strip: return "strip";
    }
}

string cliText(TableCopyMode m) @safe pure nothrow @nogc
{
    final switch (m)
    {
        case TableCopyMode.detect:   return "auto";
        case TableCopyMode.tsv:      return "tsv";
        case TableCopyMode.markdown: return "markdown";
        case TableCopyMode.source:   return "source";
    }
}

// ── The CLI layer (CFG2's highest) ──────────────────────────────────────────

/**
The parsed command line as a sparse overlay: a field is set iff its flag was
explicitly typed (`CommandNode.seenOptions`), so an untouched flag can never
shadow a config file. String-domain flags parse to their enums here — the one
place CLI spellings and wire spellings meet.
*/
Sparse!HueConfig cliOverlay(in CommandNode!HueCli root)
{
    Sparse!HueConfig o;
    const rs = root.seenOptions;

    // The flattened GuiOptions duplicate of --theme maps first, so the root
    // option wins when both somehow appear — the collapse of the old
    // two-declarations seam.
    if ("gui.theme" in rs)
        o.appearance.theme = root.value.gui.theme;
    if ("theme" in rs)
        o.appearance.theme = root.value.theme;
    if ("background" in rs)
        o.appearance.background = parseBackgroundMode(root.value.background);
    if ("width" in rs)
        o.appearance.width = root.value.width;
    if ("height" in rs)
        o.appearance.height = root.value.height;
    if ("gui.font" in rs)
        o.appearance.fonts.family = root.value.gui.font;
    if ("gui.fontSize" in rs)
        o.appearance.fonts.size = root.value.gui.fontSize;
    if ("gui.fontBold" in rs)
        o.appearance.fonts.bold = root.value.gui.fontBold;
    if ("gui.fontItalic" in rs)
        o.appearance.fonts.italic = root.value.gui.fontItalic;
    if ("gui.fontBoldItalic" in rs)
        o.appearance.fonts.boldItalic = root.value.gui.fontBoldItalic;
    if ("gui.fontCodepointMap" in rs)
        o.appearance.fonts.codepointMap = root.value.gui.fontCodepointMap.dup;
    if ("gui.fontDir" in rs)
        o.appearance.fonts.fontDir = root.value.gui.fontDir.dup;
    if ("gui.windowWidth" in rs)
        o.appearance.window.width = root.value.gui.windowWidth;
    if ("gui.windowHeight" in rs)
        o.appearance.window.height = root.value.gui.windowHeight;

    root.command.match!(
            (in CommandNode!View v) {
                const s = v.seenOptions;
                if ("treeWidth" in s)
                    o.panes.tree.width = v.value.treeWidth;
                if ("include" in s)
                    o.panes.tree.include = v.value.include.dup;
                if ("exclude" in s)
                    o.panes.tree.exclude = v.value.exclude.dup;
                if ("tabWidth" in s)
                    o.panes.viewer.tabWidth = v.value.tabWidth;
                if ("listWhitespace" in s)
                    o.panes.viewer.listWhitespace = v.value.listWhitespace;
                if ("lineNumbers" in s)
                    o.panes.viewer.lineNumbers = v.value.lineNumbers;
                if ("gutter" in s)
                    o.panes.viewer.gutter = v.value.gutter;
                if ("codeLineNumbers" in s)
                    o.panes.viewer.codeLineNumbers = v.value.codeLineNumbers;
                if ("codeOverflow" in s)
                    o.panes.viewer.codeOverflow = v.value.codeOverflow;
                if ("codeMaxLines" in s)
                    o.panes.viewer.codeMaxLines = v.value.codeMaxLines;
                if ("tableOverflow" in s)
                    o.panes.viewer.tableOverflow = v.value.tableOverflow;
                if ("tableMaxLines" in s)
                    o.panes.viewer.tableMaxLines = v.value.tableMaxLines;
                if ("groupThemes" in s)
                    o.appearance.groupThemes = v.value.groupThemes;
                if ("ansiCopy" in s)
                    o.behaviour.ansiCopy = parseAnsiCopy(v.value.ansiCopy);
                if ("tableCopy" in s)
                    o.behaviour.tableCopy = parseTableCopy(v.value.tableCopy);
                if ("noLiveTypes" in s)
                    o.behaviour.liveTypes = !v.value.noLiveTypes;
                if ("scrollAnchor" in s)
                    o.behaviour.scrollAnchor = parseScrollAnchor(v.value.scrollAnchor);
                if ("raw" in s && v.value.raw)
                    o.behaviour.defaultView = DefaultView.raw;
                if ("formatPreview" in s)
                    o.format.preview = v.value.formatPreview;
                if ("formatWidth" in s)
                    o.format.width = v.value.formatWidth;
                if ("formatter" in s)
                    o.format.formatter = v.value.formatter;
                diffFlagsInto(o, s, v.value.diffOptions, "diffOptions.");
            },
            (in CommandNode!Diff d) {
                const s = d.seenOptions;
                if ("lineNumbers" in s)
                    o.panes.viewer.lineNumbers = d.value.lineNumbers;
                if ("codeOverflow" in s)
                    o.panes.viewer.codeOverflow = d.value.codeOverflow;
                if ("codeMaxLines" in s)
                    o.panes.viewer.codeMaxLines = d.value.codeMaxLines;
                if ("tableOverflow" in s)
                    o.panes.viewer.tableOverflow = d.value.tableOverflow;
                if ("tableMaxLines" in s)
                    o.panes.viewer.tableMaxLines = d.value.tableMaxLines;
                diffFlagsInto(o, s, d.value.diff, "diff.");
            },
            (in CommandNode!Pr p) {
                const s = p.seenOptions;
                if ("lineNumbers" in s)
                    o.panes.viewer.lineNumbers = p.value.lineNumbers;
                if ("codeOverflow" in s)
                    o.panes.viewer.codeOverflow = p.value.codeOverflow;
                if ("codeMaxLines" in s)
                    o.panes.viewer.codeMaxLines = p.value.codeMaxLines;
                if ("tableOverflow" in s)
                    o.panes.viewer.tableOverflow = p.value.tableOverflow;
                if ("tableMaxLines" in s)
                    o.panes.viewer.tableMaxLines = p.value.tableMaxLines;
                diffFlagsInto(o, s, p.value.diff, "diff.");
            },
            (in CommandNode!Gallery g) {
                if ("outDir" in g.seenOptions)
                    o.behaviour.galleryOut = g.value.outDir;
            },
            (x) {},
        );

    return o;
}

/// The `@Flatten`ed diff group, shared by view/diff/pr under their own
/// flatten prefixes.
private void diffFlagsInto(ref Sparse!HueConfig o, const bool[string] seen,
    in DiffOptions dopt, string prefix)
{
    if (prefix ~ "diffIgnoreWhitespace" in seen)
        o.diff.ignoreWhitespace = parseWhitespaceMode(dopt.diffIgnoreWhitespace);
    if (prefix ~ "diffStructural" in seen)
        o.diff.structural = parseStructural(dopt.diffStructural);
    if (prefix ~ "diffLayout" in seen)
        o.diff.layout = parseDiffLayout(dopt.diffLayout);
    if (prefix ~ "diffPreview" in seen)
        o.diff.preview = dopt.diffPreview;
    if (prefix ~ "diffShowFormatting" in seen)
        o.diff.showFormatting = dopt.diffShowFormatting;
    if (prefix ~ "diffChrome" in seen)
        o.diff.chrome = dopt.diffChrome;
    if (prefix ~ "diffContext" in seen)
        o.diff.context = dopt.diffContext;
}

// ── The whole stack for one invocation ──────────────────────────────────────

/// Where the project-file walk starts: the viewed target when there is one,
/// the working directory otherwise.
string walkStartFor(in CommandNode!HueCli root)
{
    import std.file : getcwd;
    import std.path : dirName;
    import source_loc : parseSourceLoc;

    string start;
    try
        start = getcwd();
    catch (Exception)
        start = null;
    root.command.match!(
        (in CommandNode!View v) {
            if (v.value.paths.length && v.value.paths[0] != "-")
            {
                const loc = parseSourceLoc(v.value.paths[0]);
                const t = loc.path.length ? loc.path : v.value.paths[0];
                start = isDirectoryPath(t) ? t : t.dirName;
            }
        },
        (x) {},
    );
    return start;
}

/// `true` iff `path` names an existing directory — the multi-document target
/// (`SRC4`). A missing or unreadable path is not a directory (the file paths
/// then report it).
bool isDirectoryPath(string path) @trusted nothrow
{
    import std.file : exists, isDir;

    try
        return path.length != 0 && path.exists && path.isDir;
    catch (Exception)
        return false;
}

/// Resolves all five CFG2 layers for this invocation. On Android the user
/// file lives in the app data dir (`CFG12`) and the project walk is skipped.
LoadedConfig loadConfigFor(in CommandNode!HueCli root)
{
    string userPath = root.value.configFile;
    string walkStart;
    version (Android)
    {
        import android_glue : androidDataDir;
        import android_paths : configPath;

        if (!userPath.length)
            userPath = configPath(androidDataDir());
    }
    else
        walkStart = walkStartFor(root);

    auto lc = loadHueConfig(userPath, walkStart,
        (scope const(char)[] name) @safe {
            import std.process : environment;

            return cast(const(char)[]) environment.get(name.idup, null);
        });
    applyOverlay(lc.effective, lc.origins, cliOverlay(root),
        Origin(OriginKind.cli, "cli"));
    return lc;
}

// ── Projections into the sink structs ───────────────────────────────────────

/// The one place `ViewRenderOptions` is filled: from the effective config
/// (the CLI already merged in as the highest layer), never from CLI structs
/// field by field.
// By value, not `in`: the projection returns slices of the config, which
// dip1000 forbids escaping from a `scope` view; one struct copy per
// invocation is free.
ViewRenderOptions viewRenderOptionsOf(const HueConfig eff) @safe
{
    ViewRenderOptions opt;
    opt.theme = eff.appearance.theme;
    opt.background = cliText(eff.appearance.background);
    opt.groupThemes = eff.appearance.groupThemes;
    opt.width = eff.appearance.width;
    opt.height = eff.appearance.height;
    opt.treeWidth = eff.panes.tree.width;
    opt.tabWidth = eff.panes.viewer.tabWidth;
    opt.listWhitespace = eff.panes.viewer.listWhitespace;
    opt.lineNumbers = eff.panes.viewer.lineNumbers;
    opt.gutter = eff.panes.viewer.gutter;
    opt.codeLineNumbers = eff.panes.viewer.codeLineNumbers;
    opt.codeOverflow = eff.panes.viewer.codeOverflow;
    opt.codeMaxLines = eff.panes.viewer.codeMaxLines;
    opt.tableOverflow = eff.panes.viewer.tableOverflow;
    opt.tableMaxLines = eff.panes.viewer.tableMaxLines;
    opt.ansiCopy = cliText(eff.behaviour.ansiCopy);
    opt.tableCopy = cliText(eff.behaviour.tableCopy);
    opt.include = eff.panes.tree.include.dup;
    opt.exclude = eff.panes.tree.exclude.dup;
    opt.noLiveTypes = !eff.behaviour.liveTypes;
    opt.diffLayout = cliText(eff.diff.layout);
    opt.diffShowFormatting = eff.diff.showFormatting;
    opt.diffChrome = eff.diff.chrome;
    opt.gui = guiOptionsOf(eff);
    opt.scrollAnchor = cliText(eff.behaviour.scrollAnchor);
    opt.formatPreview = eff.format.preview;
    opt.formatWidth = eff.format.width;
    opt.formatter = eff.format.formatter;
    return opt;
}

/// The `GuiOptions` the window/font setup consumes, from the effective
/// config — this projection replaced `copyGui`, whose 13 hand-copied fields
/// had already dropped two once. Backend-choice flags (`gui`/`tui`/`noGui`)
/// are per-invocation (`CFG7`), resolved from the CLI struct before this
/// projection runs, and stay default here.
/// ditto (by value for the same dip1000 reason)
GuiOptions guiOptionsOf(const HueConfig eff) @safe
{
    GuiOptions g;
    g.font = eff.appearance.fonts.family;
    g.fontSize = eff.appearance.fonts.size;
    g.fontBold = eff.appearance.fonts.bold;
    g.fontItalic = eff.appearance.fonts.italic;
    g.fontBoldItalic = eff.appearance.fonts.boldItalic;
    g.fontCodepointMap = eff.appearance.fonts.codepointMap.dup;
    g.fontDir = eff.appearance.fonts.fontDir.dup;
    g.theme = eff.appearance.theme;
    g.windowWidth = eff.appearance.window.width;
    g.windowHeight = eff.appearance.window.height;
    return g;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("cli.cliOverlay.sparsityAndCollapse")
@system unittest
{
    import settings_overlay : Origins;

    // Only typed flags land in the overlay; --theme wins over the flattened
    // GuiOptions duplicate; per-subcommand flags map at their level.
    auto parsed = parseCli!HueCli([
        "hue", "--theme", "builtin-dark", "view", "--tree-width", "40",
        "--table-copy", "markdown", "--diff-layout", "split", "x.d",
    ]);
    assert(parsed, parsed.error.message);
    auto o = cliOverlay(parsed.value);

    assert(o.appearance.theme.get == "builtin-dark");
    assert(o.panes.tree.width.get == 40);
    assert(o.behaviour.tableCopy.get == TableCopyMode.markdown);
    assert(o.diff.layout.get == DiffLayout.split);

    // Untyped flags stay unset — the config file gets to speak.
    assert(o.appearance.background.isNull);
    assert(o.panes.viewer.tabWidth.isNull);
    assert(o.panes.viewer.lineNumbers.isNull);
    assert(o.appearance.fonts.size.isNull);
    assert(o.behaviour.liveTypes.isNull);

    // Applied as the top layer, it overrides; untouched fields survive.
    HueConfig eff;
    Origins!HueConfig origins;
    eff.panes.viewer.tabWidth = 8; // pretend a file set this
    applyOverlay(eff, origins, o, Origin(OriginKind.cli, "cli"));
    assert(eff.appearance.theme == "builtin-dark");
    assert(eff.panes.tree.width == 40);
    assert(eff.panes.viewer.tabWidth == 8);
}

@("cli.cliText.pinnedToParsers")
@safe unittest
{
    import std.meta : AliasSeq;

    // The unparse helpers must speak exactly what the parsers accept — a
    // drift here silently reroutes a config value through a parser's
    // warn-and-default arm.
    static foreach (m; __traits(allMembers, BackgroundMode))
        assert(parseBackgroundMode(cliText(__traits(getMember, BackgroundMode, m)))
            == __traits(getMember, BackgroundMode, m));
    static foreach (m; __traits(allMembers, DiffLayout))
        assert(parseDiffLayout(cliText(__traits(getMember, DiffLayout, m)))
            == __traits(getMember, DiffLayout, m));
    static foreach (m; __traits(allMembers, ScrollAnchorMode))
        assert(parseScrollAnchor(cliText(__traits(getMember, ScrollAnchorMode, m)))
            == __traits(getMember, ScrollAnchorMode, m));
    static foreach (m; __traits(allMembers, AnsiCopyMode))
        assert(parseAnsiCopy(cliText(__traits(getMember, AnsiCopyMode, m)))
            == __traits(getMember, AnsiCopyMode, m));
    static foreach (m; __traits(allMembers, TableCopyMode))
        assert(parseTableCopy(cliText(__traits(getMember, TableCopyMode, m)))
            == __traits(getMember, TableCopyMode, m));
}

@("cli.projections.roundTrip")
@safe unittest
{
    HueConfig eff;
    eff.appearance.theme = "builtin-dark";
    eff.appearance.fonts.size = 13;
    eff.appearance.window.width = 120;
    eff.panes.tree.width = 40;
    eff.panes.viewer.lineNumbers = false;
    eff.behaviour.tableCopy = TableCopyMode.source;
    eff.behaviour.liveTypes = false;
    eff.diff.layout = DiffLayout.split;

    const opt = viewRenderOptionsOf(eff);
    assert(opt.theme == "builtin-dark");
    assert(opt.treeWidth == 40);
    assert(opt.lineNumbers == false);
    assert(opt.tableCopy == "source");
    assert(opt.noLiveTypes == true);
    assert(opt.diffLayout == "split");
    assert(opt.gui.font == eff.appearance.fonts.family);
    assert(opt.gui.fontSize == 13);
    assert(opt.gui.theme == "builtin-dark");
    assert(opt.gui.windowWidth == 120);
}

@("cli.defaultViewInvocation")
@system unittest
{
    // 1. `hue` -> selects View with empty paths
    const bare = parseCli!HueCli(["hue"]);
    assert(bare, bare.error.message);
    assert(bare.value.commandSelected);
    bare.value.command.match!(
        (const CommandNode!View v) { assert(v.value.paths.length == 0); },
        (_ ) { assert(false, "Expected View command"); }
    );

    // 2. `hue .` -> selects View with paths = ["."]
    const dot = parseCli!HueCli(["hue", "."]);
    assert(dot, dot.error.message);
    assert(dot.value.commandSelected);
    dot.value.command.match!(
        (const CommandNode!View v) { assert(v.value.paths == ["."]); },
        (_ ) { assert(false, "Expected View command"); }
    );

    // 3. `hue <path>` -> selects View with paths = ["<path>"]
    const path = parseCli!HueCli(["hue", "some/path.d"]);
    assert(path, path.error.message);
    assert(path.value.commandSelected);
    path.value.command.match!(
        (const CommandNode!View v) { assert(v.value.paths == ["some/path.d"]); },
        (_ ) { assert(false, "Expected View command"); }
    );

    // 4. `hue 'File "foo.py", line 7, in func'` -> selects View with the traceback string
    const tb = parseCli!HueCli(["hue", `File "/home/some/path/exception_hooks.py", line 7, in do_stuff`]);
    assert(tb, tb.error.message);
    assert(tb.value.commandSelected);
    tb.value.command.match!(
        (const CommandNode!View v) { assert(v.value.paths == [`File "/home/some/path/exception_hooks.py", line 7, in do_stuff`]); },
        (_ ) { assert(false, "Expected View command"); }
    );

    // 5. `hue diff a.d b.d` -> selects Diff
    const diff = parseCli!HueCli(["hue", "diff", "a.d", "b.d"]);
    assert(diff, diff.error.message);
    assert(diff.value.commandSelected);
    diff.value.command.match!(
        (const CommandNode!Diff d) { assert(d.value.targets == ["a.d", "b.d"]); },
        (_ ) { assert(false, "Expected Diff command"); }
    );
}
