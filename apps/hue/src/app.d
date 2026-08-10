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
import sparkles.syntax.md.model : MdDoc;
import sparkles.syntax.md.render_widgets : CodeOverflow;
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

struct CliParams
{
    @(Option("html", description: "Output formatted HTML instead of ANSI terminal escapes."))
    bool html;

    // The window/font/theme/backend-force vocabulary is the host's now
    // (`CLI1`-`CLI3`): one declaration, one set of defaults, one help text.
    // USER-VISIBLE (`UIAPP-O1`): --font-size 14 -> 18 and --theme
    // catppuccin-mocha -> tokyo-night; hue gains --font-dir and
    // --font-codepoint-map (previously Android-internal).
    mixin GuiCliFields;

    @(Option("include", description: "Explorer glob(s) to always show (overrides hidden, git-ignored, and --exclude); matched against the entry name and its root-relative path. Repeatable."))
    string[] include;

    @(Option("exclude", description: "Explorer glob(s) to hide. Repeatable; --include wins."))
    string[] exclude;

    @(Option("tree-width", description: "Explorer pane width in cells (default 32)."))
    int treeWidth = 32;

    @(Option("tab-width", description: "Tab stops in the raw source view: a tab advances to the next multiple of this many columns."))
    int tabWidth = 4;

    @(Option("list-whitespace", description: "Render whitespace visibly in the raw view, vim's 'list' style: tabs as '→', spaces and trailing runs as '·', no-break spaces as '␣'."))
    bool listWhitespace;

    @(Option("twoslash", description: "Render a TypeScript twoslash JSON payload (its `code` + nodes) as a type-annotated overlay. Compatibility spelling of --overlay twoslash=<path>; a *.twoslash.json target needs no flag."))
    string twoslash;

    @(Option("overlay", description: "Attach an overlay to the document: <kind>[=<artifact>] (see --list-overlays). E.g. --overlay twoslash=nodes.json."))
    string overlay;

    @(Option("list-overlays", description: "List the registered overlay kinds and exit."))
    bool listOverlays;

    @(Option("markdown", description: "Treat the input as Markdown and render the decorated preview (the default for .md files) in the active sink; forces the preview for a non-.md extension or stdin."))
    bool markdown;

    @(Option("raw", description: "Render highlighted source instead of the markdown preview, in every sink (the preview is the default for .md files)."))
    bool raw;

    @(Option("diff", description: "Diff the two positional file arguments in-process and render the result in the active sink."))
    bool diff;

    @(Option("patch", description: "Treat the input (a file target or piped stdin) as a unified diff; piped stdin is also sniffed without the flag."))
    bool patch;

    @(Option("pr", description: "Open a pull request as a diff session: a number (in this repository), owner/repo#number, or a forge URL. Fetched natively over the forge API; the token comes from $GITHUB_TOKEN, $GH_TOKEN, or gh's config — never a prompt."))
    string pr;

    @(Option("staged", description: "Diff the index (staged changes) against HEAD or the given revision; implies --diff."))
    bool staged;

    @(Option("diff-ignore-whitespace", description: "How much whitespace difference counts as the same line: exact (default), trailing (git --ignore-space-at-eol), change (git -b), all (git -w). An ignored difference is never a change, not a change that is hidden."))
    string diffIgnoreWhitespace = "exact";

    @(Option("diff-preview", description: "With --diff over two markdown files: diff the rendered DOCUMENTS instead of their source — the new document as it now stands, with removed blocks struck through in place and changed words marked. Rewrapping and table re-alignment become invisible, because neither changes a block's content."))
    bool diffPreview;

    @(Option("diff-structural", description: "Whether the grammar gets asked if a change is real: auto (default, when a grammar exists and the file is under the size ceiling), on (ignore the ceiling), off. Token-stream-identical hunks fold as formatting-only; the parser can only demote a change, never hide one."))
    string diffStructural = "auto";

    @(Option("diff-commutative", description: "Containers whose child order carries no meaning, as language:node pairs added to the defaults (D imports, markdown reference definitions); off claims no permutation at all. A hunk that only permutes such a container folds as 'reordered'."))
    string diffCommutative = "default";

    @(Option("diff-layout", description: "Diff layout: unified (default, one column) or split (two aligned panes). A split narrower than 80 columns degrades to unified, where the same diff reads better."))
    string diffLayout = "unified";

    @(Option("line-numbers", description: "--gui: show the file line-number gutter (default on; disable with =false; toggle at runtime with 'l')."))
    bool lineNumbers = true;

    @(Option("code-line-numbers", description: "--gui: number the lines inside each code block (default on; disable with =false; toggle at runtime with 'c')."))
    bool codeLineNumbers = true;

    @(Option("code-overflow", description: "How a code-block line longer than its panel behaves: 'scroll' (per-block horizontal scrolling — a sideways wheel or Shift+wheel over the block; the default) or 'wrap' (in-panel wrapping past the number gutter)."))
    string codeOverflow = "scroll";

    @(Option("code-max-lines", description: "A code block taller than this many lines shows a fixed-height vertical viewport with its own scrollbar (scroll mode). Default -1 = auto: fit the whole block, borders included, in the document pane, so its bottom border stays in view; 0 disables."))
    int codeMaxLines = -1;

    @(Option("group-themes", description: "Group the theme cycle by light/dark (default on; disable with =false): each brightness forms one contiguous run, so rapidly cycling dark themes never flashes a light background."))
    bool groupThemes = true;

    @(Option("background", description: "Terminal background mode: no-background (foreground only), spans (only where the theme sets one), or full (fill every line edge-to-edge; the default)."))
    string background = "full";

    @(Option("ansi-copy", description: "--gui: how a selection over a ```ansi block copies — 'raw' (escape codes) or 'strip' (SGR removed). Default raw; toggle at runtime with 'y'."))
    string ansiCopy = "raw";

    @(Option("table-copy", description: "--gui: how a table grid selection copies — 'tsv' (tab-separated) or 'markdown'. Default tsv; toggle at runtime with 't'."))
    string tableCopy = "tsv";

    @(Option("out", description: "Output directory for the static HTML gallery a directory target renders into (with --html); defaults to <target>/html."))
    string outDir;

    @(Option("no-live-types", description: "Disable live D types in the interactive views: opening a .d file normally starts a twoslash-extract oracle beside it, underlines every hover span, and resolves a token's type when you point at it. Needs twoslash-extract on PATH (or $SPARKLES_TWOSLASH_EXTRACT); without it the viewer says so once and carries on."))
    bool noLiveTypes;

    /// Everything that is not an option: the target to view (a file, a
    /// directory, or nothing — hue then views its own source). `--diff` reads
    /// two of them as the old/new file, and `--diff`/`--staged` over git
    /// revisions read the first non-file as the revspec and the rest as path
    /// filters.
    @(Argument("path", description: "File or directory to view (default: hue's own source).", optional: true))
    string[] paths;
}

/// Parses `--code-overflow` into a `CodeOverflow`; unknown → `scroll`.
private CodeOverflow parseCodeOverflow(string name)
{
    switch (name)
    {
        case "wrap":   return CodeOverflow.wrap;
        case "scroll": return CodeOverflow.scroll;
        default:
            warning(i"unknown --code-overflow '$(name)'; using 'scroll'");
            return CodeOverflow.scroll;
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

// The font default is the host's (`CLI3`): the shared cascade already leads
// with the bundled Maple family, so the Android prepend this file carried is
// gone — the shared default IS the Android answer now.


/// The grammar registry every sink resolves through. Desktop: the nix grammar
/// bundle via `$SPARKLES_TS_GRAMMAR_PATH`. Android: the soname layout —
/// parsers are APK native libraries the dynamic linker resolves, queries come
/// from the extracted assets.
/// The HTML sink's diff options: the layout the reviewer asked for, at
/// whatever width the page ends up — a browser is not a fixed-width pane, so
/// the narrow-pane degradation (`DVL3`) does not apply there.
private DiffViewOptions htmlDiffOptions(DiffLayout layout) @safe pure nothrow @nogc
{
    DiffViewOptions opt;
    opt.layout = layout;
    return opt;
}

/// `DVL3`: the `--diff-layout` spelling. Unknown spellings warn and fall back
/// to `unified` rather than failing the run.
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

/// `DVN1`: the `--diff-ignore-whitespace` spelling as a mode. An unknown
/// spelling warns and falls back to `exact` rather than failing the run — the
/// totality law: a bad flag must not cost the reviewer their diff.
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

/// `DPR2`: the PR's metadata and description as a session header. The
/// description is parsed as markdown here so the view can render it through
/// hue's own preview rather than as a wall of raw text.
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

/// `DPR3`: the forge's conversations as the view's own anchored threads —
/// each comment's markdown parsed here, so the renderer draws a review
/// comment the way it draws every other piece of markdown hue shows.
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

/// An ISO-8601 timestamp trimmed to its date. A review thread wants "when,
/// roughly"; the clock time is noise beside the comment it labels.
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

/// `--diff-preview` needs two markdown files: the rendered-preview diff has
/// no meaning for a document the markdown renderer cannot draw.
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

/// Heuristic for whether a graphical display is available, used to pick the GUI
/// vs the terminal by default (no `--gui`/`--no-gui`). On Linux/BSD a display is
// The sink vocabulary and the decision are the host's now (`P2.B2`, `BKD1`/
// `BKD2` — the library preserved hue's rules verbatim, "--gui wins even
// uncompiled" included; the Android fact is `BKD4`; the display probe is
// `BKD3`'s socket-level one rather than the env heuristic this replaced).
import sparkles.ui_app.gui_options : defaultGuiFont, defaultGuiFontFamily,
    GuiCliFields, uiuaCodepointMap;
import sparkles.ui_app.backend : Backend, BackendPolicy,
    hostPickBackend = pickBackend, platformForcedBackend;
import sparkles.ui_app.display : displayAvailable;

/// The one choice, made once: hue's part is only assembling the policy —
/// which flags were given, what this build compiled in, what the process
/// sees — and the pure picker answers.
private Backend pickBackend(in CliParams cli)
{
    Backend forced;
    if (platformForcedBackend(forced))
        return forced; // Android: the surface IS the app (`BKD4`)

    bool guiCompiledIn = false;
    version (HueGui) guiCompiledIn = true;

    return hostPickBackend(BackendPolicy(
        forceGui: cli.gui,
        forceNoGui: cli.noGui,
        forceTui: cli.tui,
        forceHtml: cli.html,
        guiCompiledIn: guiCompiledIn,
        stdinTty: isTerminal(StdStream.stdin),
        stdoutTty: isTerminal(StdStream.stdout),
        displayPresent: displayAvailable(),
    ));
}

int main(string[] args)
{
    auto parsed = parseCli!CliParams(
        args,
        HelpInfo(
            "hue",
            "Highlight a source file in the terminal or as HTML, or browse syntax themes live.",
            null
        )
    );
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

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
    string target = forceTwoslash ? cli.twoslash
        : (cli.paths.length ? cli.paths[0] : "");
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
        cli.patch, parseWhitespaceMode(cli.diffIgnoreWhitespace),
        parseStructural(cli.diffStructural),
        parseCommutative(cli.diffCommutative));

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

                auto themeSet = sortedThemes(cli.theme, cli.groupThemes);
                auto pl = &pipeline;
                return runWorkspace(target, isDir: true, WorkspaceDoc.init,
                    delegate WorkspaceDoc(string path) @system
                        => pl.load(path),
                    themeSet.names, themeSet.themes, themeSet.idx, labels,
                    &cache, cli.include.dup, cli.exclude.dup, cli.treeWidth,
                    cli.tabWidth, cli.listWhitespace, liveTypes: !cli.noLiveTypes,
                    codeOverflow: parseCodeOverflow(cli.codeOverflow),
                    codeMaxLines: cli.codeMaxLines);
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
        if (cli.pr.length)
        {
            // `DPR1`: a pull request IS a diff session — fetched through the
            // forge seam, assembled into a patch, and then handed to exactly
            // the pipeline a local diff uses.
            import forge_client : fetchPullRequest;
            import std.conv : text;

            auto fetched = fetchPullRequest(cli.pr);
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
        else if (cli.diff || cli.staged)
        {
            import std.file : exists, isFile;

            static bool isFilePath(string p) @system
            {
                try
                    return p.exists && p.isFile;
                catch (Exception)
                    return false;
            }

            if (!cli.staged && cli.paths.length > 1 && isFilePath(cli.paths[0])
                && isFilePath(cli.paths[1]))
                // `hue --diff <old> <new>`: two positional files, diffed
                // in-process (`DVS1`) — or, for markdown under
                // `--diff-preview`, diffed as documents (`DVN6`).
                doc = cli.diffPreview && isMarkdownPath(cli.paths[0])
                    && isMarkdownPath(cli.paths[1])
                    ? pipeline.loadDiffPreview(cli.paths[0], cli.paths[1])
                    : pipeline.loadDiffPair(cli.paths[0], cli.paths[1]);
            else
            {
                // Git revisions (`DVS3`): `hue --diff [<rev>[..<rev>]]
                // [paths…]` — a positional naming an existing file is a
                // path filter, the first non-file is the revspec.
                string revspec;
                string[] filters;
                foreach (a; cli.paths)
                    if (revspec.length == 0 && !isFilePath(a))
                        revspec = a;
                    else
                        filters ~= a;
                // `DVN6`: the same revision diff, rendered as a document.
                doc = cli.diffPreview
                    ? pipeline.loadGitDiffPreview(revspec, cli.staged, filters)
                    : pipeline.loadGitDiff(revspec, cli.staged, filters);
            }
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
            rc = runHtmlSink(doc, theme, registry, cache,
                parseDiffLayout(cli.diffLayout));
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
                // The width bound sizes the fence chrome (the layout
                // constraint below is the same number).
                maxWidth: previewWidth(),
                fenceRenderer: hueFenceRenderer(&cache, &theme, pageFg),
                diffBlocks: doc.preview.decorations, // `DVN6`
                codeOverflow: parseCodeOverflow(cli.codeOverflow),
                // A static sink has no pane to fit: `auto` never clips.
                codeMaxLines: cli.codeMaxLines < 0 ? 0 : cli.codeMaxLines,
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
            dopt.layout = parseDiffLayout(cli.diffLayout);
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
private int runTuiSink(in CliParams cli, ref Document doc, in LabelSet labels,
    in ResolvedTheme theme, ref TsConfigCache cache,
    scope SourceSet* docSet, scope DocumentPipeline* pipeline = null) @system
{
    import source_set : SourceSet;

    // The headless QA capture hook still short-circuits a twoslash target.
    if (doc.kind == ContentKind.twoslash && tryTwoslashCapture(doc, theme, cache))
        return 0;

    auto themeSet = sortedThemes(cli.theme, cli.groupThemes);

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
        // `DST2`: a stageable worktree diff can be re-read after a patch is
        // applied — the same invocation, run again, which is exactly what
        // makes the staged rows leave the view.
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
            &cache, cli.include.dup, cli.exclude.dup, cli.treeWidth,
            cli.tabWidth, cli.listWhitespace, liveTypes: !cli.noLiveTypes,
            diffLayout: parseDiffLayout(cli.diffLayout),
            codeOverflow: parseCodeOverflow(cli.codeOverflow),
            codeMaxLines: cli.codeMaxLines,
            reloadDiff: reloadDiff);
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

        auto themeSet = sortedThemes(cli.theme, cli.groupThemes);
        // Font selection: Android has no CLI, so the bundled defaults stand
        // in for the desktop flags — the Maple family for the primary and
        // all three styled faces (the fontconfig-free override resolution
        // picks its -Bold/-Italic/-BoldItalic siblings) + the Uiua386
        // codepoint map.
        version (Android)
        {
            const fontName = defaultGuiFont;
            const faceOv = FontSet.FaceOverrides(defaultGuiFontFamily,
                defaultGuiFontFamily, defaultGuiFontFamily);
            string[] cpMaps = [uiuaCodepointMap];
        }
        else
        {
            const fontName = cli.font;
            const faceOv = FontSet.FaceOverrides(cli.fontBold, cli.fontItalic,
                cli.fontBoldItalic);
            string[] cpMaps = null;
        }

        // The deterministic-capture hooks (`CLI6`): the environment is read
        // HERE, once, and the frame code receives values. Android anchors a
        // relative screenshot path in the app data dir (CWD is '/', not
        // writable); pull the PNG with `adb shell run-as`.
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

        return runGui(doc.title, doc.source, doc.events, labels, themeSet.names,
            themeSet.themes, themeSet.idx, doc.preview, fontName, cli.fontSize,
            cli.windowWidth, cli.windowHeight, cli.lineNumbers, cli.codeLineNumbers,
            cli.ansiCopy == "strip", parseTableCopy(cli.tableCopy),
            parseCodeOverflow(cli.codeOverflow), cli.codeMaxLines,
            docSet, &loadDoc, &cache, doc.twoslash,
            doc.path, startInTree: startInTree, treeRoot,
            faceOv, doc.lang,
            cli.include.dup, cli.exclude.dup, cli.treeWidth,
            cli.tabWidth, cli.listWhitespace, cpMaps,
            liveTypes: !cli.noLiveTypes, initialDiff: doc.diffDoc,
            initialDiffSides: doc.diffSides,
            initialDiffSession: doc.diffSession,
            capture: capture);
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
