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
import viewer_model : GutterSelection;
import diff_commutative : CommutativeKind;
import diff_session : AnchoredThread, SessionHeader, ThreadComment;
import forge : CommentThread, PullRequest, ThreadSide;
import diff_structural : StructuralPolicy;
import diff_view : DiffLayout, DiffViewOptions;
import sparkles.diff : WhitespaceMode;
import sparkles.docs.source_set : SourceEntry, SourceSet;
import table_select : TableCopyFormat;
import dsv_view : resolveTableCopy;

import sparkles.ui_app.gui_options : defaultGuiFont, defaultGuiFontFamily,
    defaultTheme, GuiOptions;
import sparkles.ui_app.backend : Backend, BackendPolicy,
    hostPickBackend = pickBackend, platformForcedBackend;
import sparkles.ui_app.display : displayAvailable;

import cli;
import settings : HueConfig;
import settings_load : LoadedConfig;
import settings_store : ConfigStore;

// ── Subcommand Handlers ─────────────────────────────────────────────────────

/// Resolves `--twoslash` / `--cov` / `--overlay <kind>[=<artifact>]` into the
/// document target and the per-kind artifacts.
///
/// The two kinds attach differently, which is why `coverage` cannot simply
/// join the `twoslash` arm: a twoslash payload *is* the document (the overlay
/// carries its own `code`), whereas a coverage report decorates a document
/// named separately. So `twoslash` retargets and `coverage` only records its
/// artifact.
private bool resolveOverlayTarget(in HueCli root, ref bool forceTwoslash,
    ref string target, ref string coverageArtifact)
{
    if (root.overlay.twoslash.length != 0)
    {
        forceTwoslash = true;
        target = root.overlay.twoslash;
    }
    if (root.overlay.cov.length != 0)
        coverageArtifact = root.overlay.cov;
    foreach (ovl; root.overlay.overlays)
    {
        if (ovl.length == 0)
            continue;
        import std.string : indexOf;
        const eq = ovl.indexOf('=');
        const kind = eq >= 0 ? ovl[0 .. eq] : ovl;
        const artifact = eq >= 0 ? ovl[eq + 1 .. $] : "";
        switch (kind)
        {
            case "twoslash":
                forceTwoslash = true;
                if (artifact.length)
                    target = artifact;
                break;
            case "coverage":
                coverageArtifact = artifact;
                break;
            default:
                stderr.writeln("hue: unknown overlay kind '", kind,
                    "' (see --list-overlays)");
                return false;
        }
    }
    return true;
}

int executeView(in HueCli root, in View view)
{
    import sparkles.docs.source_set : collectSources, SourceEntry, SourceSet;

    initLogger(root.logLevel);

    if (root.overlay.listOverlays)
    {
        import std.stdio : writeln;
        writeln("twoslash    type annotations from a twoslash JSON payload " ~
            "(artifact: the payload; or make it the target — *.twoslash.json)");
        writeln("coverage    code coverage from .lst, .gcov, .info or .json " ~
            "(artifact: the coverage report; or --cov=<artifact>)");
        return 0;
    }

    bool forceTwoslash;
    string target = view.paths.length ? view.paths[0] : "";
    string coverageArtifact;
    if (!resolveOverlayTarget(root, forceTwoslash, target, coverageArtifact))
        return 1;

    ref const(HueConfig) eff = effectiveConfig();
    const labels = LabelSet.standard();
    const theme = resolveNamedTheme(eff.appearance.theme, labels);
    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, view.markdown, view.raw,
        view.patch, eff.diff.ignoreWhitespace, eff.diff.structural,
        parseCommutative(view.diffOptions.diffCommutative));
    pipeline.diffContext = eff.diff.context;
    pipeline.minPairSimilarity = eff.diff.minPairSimilarity;
    pipeline.maxEditDistance = eff.diff.maxEditDistance;
    pipeline.forceDsv = view.dsv;
    pipeline.dsvDelimiter = view.dsvDelimiter;
    pipeline.dsvQuote = view.dsvQuote;
    pipeline.dsvHeader = view.dsvHeader;
    pipeline.coverageArtifact = coverageArtifact;
    pipeline.autoCoverage = !root.overlay.noAutoCov;

    const backend = view.sink.resolveBackend(root.gui);

    // `FPR10`: fork the format zygote for the interactive views while the
    // process is still single-threaded (the fork-safety window). A refusal
    // is quiet — the preview falls back to its worker-thread backend.
    version (HueDmdFmt)
        if (backend == Backend.gui || backend == Backend.tui)
        {
            import format_dmd : startFormatForkServer;

            cast(void) startFormatForkServer();
        }

    // The CLI is already merged into the effective config as its highest
    // layer, so this projection carries every flag AND the file layers.
    auto opt = viewRenderOptionsOf(eff);

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

                auto themeSet = sortedThemes(opt.theme, opt.groupThemes);
                auto pl = &pipeline;
                return runWorkspace(target, isDir: true, WorkspaceDoc.init,
                    delegate WorkspaceDoc(string path) @system
                        => pl.load(path),
                    themeSet.names, themeSet.themes, themeSet.idx, labels,
                    &cache, opt.include.dup, opt.exclude.dup, opt.treeWidth,
                    opt.tabWidth, opt.listWhitespace, liveTypes: !opt.noLiveTypes,
                    codeOverflow: parseOverflow(opt.codeOverflow, "--code-overflow"),
                    codeMaxLines: opt.codeMaxLines,
                    tableOverflow: parseOverflow(opt.tableOverflow, "--table-overflow"),
                    tableMaxLines: opt.tableMaxLines,
                    tableCopyFlag: opt.tableCopy,
                    configStore: &gStore);
            }
        const openSet = backend == Backend.gui
            || (forceTwoslash && backend == Backend.tui);
        if (!openSet)
            return runDirectoryTarget(target, forceTwoslash, opt.theme, view.sink.html, "");
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

    // `FMV8`: the one-shot sinks render the FORMATTED buffer — synchronous,
    // through the standard pipeline, no ruler drawn.
    if (view.formatPreview && (backend == Backend.ansi || backend == Backend.html))
    {
        import format_preview : formatDocumentForSink;

        if (const err = formatDocumentForSink(pipeline, doc,
                view.formatWidth, view.formatter))
        {
            stderr.writeln("hue: ", err);
            return 1;
        }
    }

    return renderDocument(backend, opt, doc, labels, theme, registry, cache,
        haveSet ? &docSet : null, &pipeline, dirTarget);
}

int executeDiff(in HueCli root, in Diff diff)
{
    initLogger(root.logLevel);

    ref const(HueConfig) eff = effectiveConfig();
    const labels = LabelSet.standard();
    const theme = resolveNamedTheme(eff.appearance.theme, labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, false, false,
        false, eff.diff.ignoreWhitespace, eff.diff.structural,
        parseCommutative(diff.diff.diffCommutative));
    pipeline.diffContext = eff.diff.context;
    pipeline.minPairSimilarity = eff.diff.minPairSimilarity;
    pipeline.maxEditDistance = eff.diff.maxEditDistance;

    const backend = diff.sink.resolveBackend(root.gui);

    auto opt = viewRenderOptionsOf(eff);

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

int executePr(in HueCli root, in Pr pr)
{
    initLogger(root.logLevel);

    ref const(HueConfig) eff = effectiveConfig();
    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(eff.appearance.theme, {
            warning(i"theme '$(eff.appearance.theme)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);
    auto pipeline = DocumentPipeline(&registry, &cache, false, false,
        false, eff.diff.ignoreWhitespace, eff.diff.structural,
        parseCommutative(pr.diff.diffCommutative));
    pipeline.diffContext = eff.diff.context;
    pipeline.minPairSimilarity = eff.diff.minPairSimilarity;
    pipeline.maxEditDistance = eff.diff.maxEditDistance;

    const backend = pr.sink.resolveBackend(root.gui);

    auto opt = viewRenderOptionsOf(eff);

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

/// Resolves a built-in theme by name against `labels`, warning and falling back
/// to the default dark theme on a miss — the `--theme` policy, shared with
/// `--dark-theme`.
private ResolvedTheme resolveNamedTheme(string name, LabelSet labels)
{
    // `.get`'s default is `lazy`, so the warning fires only on a miss.
    return resolveTheme(builtinThemes.get(name, {
            warning(i"theme '$(name)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);
}

/// `true` when the run's HTML leaves its rules to a **shared stylesheet**
/// rather than a per-page `<style>` block: either a second theme has to be
/// scoped (`--dark-theme`) or the caller named an href to link.
private bool usesSharedStylesheet(in Gallery g) @safe pure nothrow @nogc
    => g.darkTheme.length != 0 || g.stylesheet.length != 0;

/**
Batch-extracts an eager twoslash payload for every `.d` entry in `set` —
`twoslash-extract --dub --stdout`, not `--serve`. Committed `*.twoslash.json`
payloads are left for `loadTwoslashFile` at render time. A missing extractor
or a failed analysis drops that entry (`GAL9`).

`jobs` extractions run at once (0 = `hwParallelism`). Results are folded back
in set order, so the page set and index order do not depend on completion
order — the page *contents* are not reproducible either way, see the note in
the body.
*/
private TwoslashReturn[string] extractTwoslashSources(ref SourceSet set,
    uint jobs) @system
{
    import sparkles.docs.source_set : SourceEntry, isDSource, isTwoslashPayload, twoslashTally;

    TwoslashReturn[string] payloads;
    version (Posix)
    {
        import core.atomic : atomicOp;
        import live_types : extractTwoslash, liveTypesBinary;
        import sparkles.base.hw_caps : hwParallelism;
        import std.parallelism : parallel, TaskPool;
        import std.range : iota;

        if (!liveTypesBinary().length)
        {
            size_t dropped;
            SourceEntry[] kept;
            foreach (ref e; set.entries)
            {
                if (isTwoslashPayload(e.path))
                    kept ~= e;
                else
                    ++dropped;
            }
            if (dropped)
                stderr.writeln("hue: twoslash-extract not found on PATH ",
                    "(build it, or set $SPARKLES_TWOSLASH_EXTRACT); ",
                    "skipping ", dropped, " .d source(s)");
            set.entries = kept;
            set.index = 0;
            return payloads;
        }

        // Which entries need an analysis, in set order.
        size_t[] dAt;
        foreach (i, ref e; set.entries)
            if (isDSource(e.path))
                dAt ~= i;

        // One `twoslash-extract` per file, several at a time. Each is a whole
        // DMD analysis in its own process (`PRJ13`), so this is process-level
        // parallelism with nothing shared — no tree-sitter cache is touched
        // here, and rendering stays single-threaded below.
        // A plain result record rather than `Expected`, which disables default
        // construction and so cannot back a preallocated array.
        static struct Extracted
        {
            TwoslashReturn value;
            string error;
        }

        auto results = new Extracted[dAt.length];
        const workers = jobs ? jobs : hwParallelism();
        shared size_t done;
        if (dAt.length)
        {
            auto pool = new TaskPool(workers > 1 ? workers - 1 : 0);
            scope (exit)
                pool.finish(true);
            foreach (k; pool.parallel(iota(dAt.length), 1))
            {
                auto r = extractTwoslash(set.entries[dAt[k]].path);
                results[k] = r.hasError
                    ? Extracted(TwoslashReturn.init, r.error)
                    : Extracted(r.value, null);
                // Completion order, not start order: with N in flight there is
                // no meaningful "now starting" line to print.
                const n = atomicOp!"+="(done, 1);
                synchronized
                    stderr.writeln("hue: extracted ", set.entries[dAt[k]].path,
                        " (", n, "/", dAt.length, ")");
            }
        }

        // Fold back in set order, so which pages exist and how the index is
        // ordered never depend on completion order.
        //
        // That is as far as this can go: the pages themselves are not
        // reproducible run-to-run even at `--jobs 1`, because the extractor
        // is not. Three sequential `twoslash-extract --stdout` runs over one
        // unchanged file produce three different payloads — the hover for a
        // template instance names whichever `__unittest_LNNN_C1` DMD's
        // instance cache walks to first. Nothing here can fix that; it is
        // upstream of the seam (`PRJ13`).
        SourceEntry[] kept;
        size_t k;
        foreach (i, ref e; set.entries)
        {
            if (!isDSource(e.path))
            {
                kept ~= e;
                continue;
            }
            auto res = results[k++];
            if (res.error.length)
            {
                stderr.writeln("hue: skipping '", e.path, "': ", res.error);
                continue;
            }
            e.summary = twoslashTally(res.value.nodes);
            payloads[e.path] = res.value;
            kept ~= e;
        }
        set.entries = kept;
        set.index = 0;
    }
    else
    {
        SourceEntry[] kept;
        foreach (ref e; set.entries)
            if (isTwoslashPayload(e.path))
                kept ~= e;
        if (kept.length != set.entries.length)
            stderr.writeln("hue: batch twoslash extract is not available on this ",
                "platform; skipping .d sources");
        set.entries = kept;
        set.index = 0;
    }
    return payloads;
}

/// The payload `renderOne` paints: a batch-extracted `.d` source, or a
/// committed `*.twoslash.json` loaded from disk.
private TwoslashReturn twoslashPayloadFor(in SourceEntry e,
    TwoslashReturn[string] payloads) @system
{
    if (auto p = e.path in payloads)
        return *p;
    auto twRes = loadTwoslashFile(e.path);
    if (twRes.hasError)
        throw new Exception(twRes.error.toString);
    return twRes.value;
}

int executeGallery(in HueCli root, in Gallery gallery)
{
    initLogger(root.logLevel);
    import sparkles.docs.fragment : FragmentOptions, plainFragment, twoslashFragment;
    import sparkles.docs.options : ChromePalette, GalleryOptions, themeChrome;
    import sparkles.docs.page_shell : writeGallery;
    import sparkles.docs.source_set : collectSources, SourceEntry;
    import std.path : buildPath;
    import sparkles.docs.assets : stylesheetAssetPath, StylesheetContent, themeStylesheet,
        writeStylesheetAsset, writeStylesheetFile;

    string dir = gallery.dir.length ? gallery.dir : ".";
    bool twoslash = gallery.twoslash || root.overlay.twoslash.length != 0;
    auto set = collectSources(dir, twoslash, gallery.recursive, gallery.root);
    TwoslashReturn[string] payloads;
    if (twoslash)
        payloads = extractTwoslashSources(set, gallery.jobs);
    if (set.empty)
        warning(i"no renderable files in '$(dir)' — writing an empty gallery index");

    const themeName = effectiveConfig().appearance.theme;
    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(themeName, {
            warning(i"theme '$(themeName)' not found; falling back to the default dark theme");
            return builtinDark;
        }()), labels);

    const dark = gallery.darkTheme.length
        ? resolveNamedTheme(gallery.darkTheme, labels) : ResolvedTheme.init;

    // A shared stylesheet replaces the per-page `<style>` block: at gallery
    // scale that copy is paid once per page, and a second theme cannot live in
    // a per-page block at all (its rules need an `html.dark` scope).
    const sharedCss = usesSharedStylesheet(gallery);
    const fragOpt = FragmentOptions(embedStyles: !sharedCss);

    auto registry = defaultRegistry();
    auto cache = TsConfigCache.create(&registry, labels);

    string renderOne(in SourceEntry e)
    {
        SmallBuffer!HighlightEvent ev;
        if (twoslash)
        {
            const tw = twoslashPayloadFor(e, payloads);
            if (highlightInjected(cache, tw.effectiveLanguage, tw.code, ev).hasError)
                ev ~= HighlightEvent.sourceSpan(0, tw.code.length);
            return twoslashFragment(tw, ev[], theme, cache, fragOpt);
        }
        const src = readText(e.path);
        const lang = canonicalLanguageOfPath(e.path);
        if (highlightInjected(cache, lang, src, ev).hasError)
            ev ~= HighlightEvent.sourceSpan(0, src.length);
        return plainFragment(src, ev[], theme, fragOpt);
    }

    const outDir = gallery.outDir.length ? gallery.outDir : buildPath(dir, "html");

    // The page surround comes from the theme (`GAL6`) — the same source the
    // `.syn-root` rule comes from, so the pane and the surround cannot drift.
    const chrome = themeChrome(theme);
    const darkChrome = gallery.darkTheme.length
        ? themeChrome(dark) : ChromePalette.init;

    // The stylesheet the pages need. `--stylesheet` names an href the caller
    // will serve; otherwise a shared run self-hosts one beside the pages, so a
    // gallery is portable on its own.
    const css = sharedCss || gallery.emitStylesheet.length
        ? themeStylesheet(theme, dark, StylesheetContent(twoslash: twoslash))
        : null;
    string href = gallery.stylesheet;
    if (sharedCss && href.length == 0)
    {
        // Self-host beside the pages and link it *relatively*: the gallery has
        // to keep working wherever it is copied or served from, so the href is
        // the in-tree asset path, not the absolute file the writer returns.
        writeStylesheetAsset(outDir, css);
        href = stylesheetAssetPath;
    }
    if (gallery.emitStylesheet.length)
        writeStylesheetFile(gallery.emitStylesheet, css);

    // The docs-site sidebar on every page (`DOC8`): load the tree once, render
    // it once, and every page splices the same markup. A missing or malformed
    // file is a hard error — a silently absent sidebar would ship as a visual
    // regression no exit code reports.
    string sidebarHtml;
    if (gallery.sidebar.length)
    {
        import sparkles.docs.sidebar : loadSidebarFile, sidebarNav;

        auto loaded = loadSidebarFile(gallery.sidebar);
        if (loaded.hasError)
        {
            stderr.writeln("hue: cannot load sidebar ", gallery.sidebar, ": ",
                loaded.error);
            return 1;
        }
        sidebarHtml = sidebarNav(loaded.value, gallery.siteBase);
    }

    const gopt = twoslash
        ? GalleryOptions(
            titlePrefix: "twoslash",
            heading: "twoslash overlay examples",
            indexTitle: "twoslash examples",
            blurb: "Rendered by <code>hue gallery --twoslash</code>. Open one and " ~
                "hover the underlined tokens to see the popups.",
            chrome: chrome, darkChrome: darkChrome, stylesheetHref: href,
            repoUrl: gallery.repoUrl, repoPrefix: gallery.repoPrefix,
            sidebarHtml: sidebarHtml)
        : GalleryOptions(
            titlePrefix: "hue",
            heading: "hue gallery",
            blurb: "Rendered by <code>hue gallery</code>.",
            chrome: chrome, darkChrome: darkChrome, stylesheetHref: href,
            repoUrl: gallery.repoUrl, repoPrefix: gallery.repoPrefix,
            sidebarHtml: sidebarHtml);

    const n = writeGallery(set, outDir, gopt, &renderOne);
    stderr.writeln("hue: wrote ", n, " page(s) + index.html to ", outDir);
    return 0;
}

int executeTheme(in HueCli root, in ThemeCmd cmd)
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

int executeOverlay(in HueCli root, in OverlayCmd cmd)
{
    initLogger(root.logLevel);
    import std.stdio : writeln;

    writeln("Available overlays:");
    writeln("  twoslash    Type annotations and hover queries from TypeScript twoslash JSON payload");
    writeln("  coverage    Per-line execution counts from a DMD .lst, gcov, LCOV or llvm-cov/V8 JSON report");
    return 0;
}

int executeConfig(in HueCli root, in ConfigCmd cmd)
{
    initLogger(root.logLevel);
    import std.array : appender;
    import std.stdio : writeln;

    const action = cmd.show ? "show" : cmd.action;
    switch (action)
    {
        case "show":
        {
            // CFG10: every effective setting with the origin that supplied
            // it — the five layers made observable.
            import settings_io : renderConfigShow;

            auto w = appender!string;
            renderConfigShow(w, loadedConfig(), changedOnly: cmd.changed);
            write(w[]);
            return 0;
        }
        case "write":
        {
            // CFG13: the commented starting file, from the same reflection
            // `show` renders — the two cannot disagree.
            import std.file : exists, mkdirRecurse, fileWrite = write;
            import std.path : dirName;
            import settings_io : renderStarterConfig;

            const path = loadedConfig().userFilePath;
            if (!path.length)
            {
                stderr.writeln("hue: no writable config location (no config dir; pass --config)");
                return 1;
            }
            if (path.exists && !cmd.force)
            {
                stderr.writeln("hue: ", path,
                    " already exists — pass --force to overwrite");
                return 1;
            }
            auto w = appender!string;
            renderStarterConfig(w);
            try
            {
                const dir = path.dirName;
                if (dir.length && dir != ".")
                    mkdirRecurse(dir);
                fileWrite(path, w[]);
            }
            catch (Exception e)
            {
                stderr.writeln("hue: ", e.msg);
                return 1;
            }
            writeln("wrote ", path);
            return 0;
        }
        case "save":
            // CFG11's machinery lands with the settings pane: a bare CLI
            // process has no session toggles to persist.
            stderr.writeln("hue: `config save` persists a session's runtime " ~
                "toggles — run it from inside hue, not the bare CLI");
            return 1;
        default:
            stderr.writeln("hue: unknown config action '", action,
                "' (show | write | save)");
            return 1;
    }
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
                parseDiffLayout(opt.diffLayout), opt.gutter, opt.lineNumbers);
        case Backend.tui:
            return runTuiSink(opt, doc, labels, theme, cache,
                docSet, pipeline);
        case Backend.ansi:
            return runAnsiSink(opt, doc, theme, cache);
    }
}

// ── Helper Utilities ────────────────────────────────────────────────────────





private int runDirectoryTarget(string dir, bool twoslash, string themeName,
    bool isHtml, string outDirParam) @system
{
    import std.path : buildPath;
    import std.stdio : writeln;

    import sparkles.docs.fragment : plainFragment, twoslashFragment;
    import sparkles.docs.options : GalleryOptions, themeChrome;
    import sparkles.docs.page_shell : writeGallery;
    import sparkles.docs.source_set : collectSources, SourceEntry;

    auto set = collectSources(dir, twoslash);
    TwoslashReturn[string] payloads;

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

    if (twoslash)
        // `view <dir> --html --overlay twoslash`: no --jobs of its own, so auto.
        payloads = extractTwoslashSources(set, 0);
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
            const tw = twoslashPayloadFor(e, payloads);
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

    // The page surround comes from the theme (`GAL6`) — the same source the
    // `.syn-root` rule comes from, so the pane and the surround cannot drift.
    const chrome = themeChrome(theme);
    const opt = twoslash
        ? GalleryOptions(
            titlePrefix: "twoslash",
            heading: "twoslash overlay examples",
            indexTitle: "twoslash examples",
            blurb: "Rendered by <code>hue --twoslash --html</code>. Open one and " ~
                "hover the underlined tokens to see the popups.",
            chrome: chrome)
        : GalleryOptions(
            titlePrefix: "hue",
            heading: "hue gallery",
            blurb: "Rendered by <code>hue --html</code>.",
            chrome: chrome);

    const n = writeGallery(set, outDir, opt, &renderOne);
    stderr.writeln("hue: wrote ", n, " page(s) + index.html to ", outDir);
    return 0;
}

/// Parses the `--background` value (`CLI8`) into a `BackgroundMode`; an unknown
/// name warns and falls back to `full` (mirrors the `--theme` fallback).

private DiffViewOptions htmlDiffOptions(DiffLayout layout) @safe pure nothrow @nogc
{
    DiffViewOptions opt;
    opt.layout = layout;
    return opt;
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

// The configuration resolved once in `main` for this invocation. A module
// global rather than a field threaded through every `executeX(in HueCli, …)`
// signature: every reader lives in this module, and the interactive shells
// will get their own explicitly-threaded handle (the settings pane's store).
private LoadedConfig gConfig;

/// The runtime store the interactive shells share: the settings pane
/// mutates `gStore.resolved`, saves rewrite the user overlay (`SET*`).
private ConfigStore gStore;

/// The effective five-layer configuration for this invocation (`CFG2`).
ref const(LoadedConfig) loadedConfig() @safe nothrow @nogc => gConfig;

/// ditto
ref const(HueConfig) effectiveConfig() @safe nothrow @nogc => gConfig.effective;

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

    auto parsed = parseCli!HueCli(args);
    if (!parsed)
        return reportCliError(parsed.error);

    // Resolve defaults → user file → project file → env → CLI before any
    // subcommand runs; load failures degrade to located warnings (CFG8).
    gConfig = loadConfigFor(parsed.value);
    gStore = ConfigStore.from(gConfig);
    foreach (w; gConfig.warnings)
        warning(i"$(w)");

    // CFG6: publish the merged binding table before any backend starts, so
    // resolution, the guide and `bindingsAt` all read the user's keys.
    if (gConfig.effective.keys.length)
    {
        import keymap : hueBindings, installBindings;
        import keymap_config : applyKeysOverlay;

        installBindings(applyKeysOverlay(hueBindings, gConfig.effective.keys,
            (string w) @safe { warning(i"$(w)"); }));
    }

    return runParsedCli(parsed.value);
}

// ── The four sinks — each a `final switch` over the document's kind ─────────

/// Static ANSI to stdout (piped / redirected / non-tty).
private int runAnsiSink(in ViewRenderOptions opt, ref Document doc,
    in ResolvedTheme theme, ref TsConfigCache cache) @system
{
    GutterSelection gutterSel;
    if (!gutterSel.parse(opt.gutter))
        warning(i"unknown gutter channel in `$(opt.gutter)`; showing what was recognized");
    if (!opt.lineNumbers)
        gutterSel.numbers = false;

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
                // The pager case (`DSG6`): a DSV document IS its grid, and a
                // non-interactive emit can never scroll — the whole grid
                // emits, ignoring any vertical clamp (which stays honored
                // for tables embedded in markdown documents).
                tableMaxLines: doc.kind == ContentKind.dsv ? 0
                    : opt.tableMaxLines < 0 ? 0 : opt.tableMaxLines,
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
            // One sink for the `code` kind, overlay or not: the widget tree,
            // through the same display list → `CellGrid` → `writeAnsi` path
            // that markdown and diff already take.
            //
            // It used to fall back to the event-stream `renderAnsi` when no
            // overlay was attached, which meant a single flag changed how the
            // file itself rendered — `--cov` reflowed long lines, expanded
            // tabs and padded rows, and dropping the flag undid all three.
            // A viewer's output should not depend on which decorations happen
            // to be on it.
            //
            // The cost is that a plain `hue file.d` now expands tabs and pads
            // rows to the grid width, as markdown and diff always have.
            {
                import document : coverageTintedRanges;
                import sparkles.syntax.render.widgets : CodeViewOptions,
                    viewCodeDocumentInto;
                import sparkles.ui.widget : Builder;
                import sparkles.ui.display_list : buildDisplayList;
                import sparkles.ui.geometry : Constraints;
                import sparkles.ui.interp.cells : BgEmit, CellGrid;
                import sparkles.ui.interp.immediate : paint;
                import sparkles.ui.layout : layout;
                import sparkles.ui.style : defaultTwoslashPalette;
                import sparkles.ui.wrap : TextWrap;

                const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
                const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);

                CodeViewOptions copt;
                if (doc.hasCoverage)
                    copt.tintedRanges = coverageTintedRanges(doc.coverage);
                // A writer emitting to a stream has no pane to reflow to.
                copt.wrap = TextWrap.none;

                // The gutter is composed after the document is laid out (its
                // cells are indexed by *visual* row), so the same builder is
                // re-rooted rather than a second tree being built.
                auto b = Builder();
                const docRoot = viewCodeDocumentInto(b, doc.source, doc.events,
                    (() @trusted => &theme)(), pageFg, copt);
                auto tree = staticGutter(b, docRoot, doc, gutterSel);
                // Unconstrained, so the grid is as wide as the longest line.
                // Constraining it to `previewWidth()` with wrapping off does
                // not fit a long line — it CLIPS it, losing the tail silently.
                auto frames = layout(tree, Constraints());
                const r = frames[tree.root].rect;
                auto grid = CellGrid(r.width, r.height, pageFg, pageBg);
                paint(grid, buildDisplayList(tree, frames,
                    defaultTwoslashPalette(), pageFg, pageBg));
                grid.writeAnsi(output, depth,
                    bgMode == BackgroundMode.full ? BgEmit.full
                    : bgMode == BackgroundMode.spans ? BgEmit.spans : BgEmit.none);
                output ~= '\n';
            }
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

/**
The gutter for a static sink: coverage only, composed after layout.

A writer emitting to a stream shows no line numbers — that is the interactive
views' chrome, and adding it here would change the output of every plain
`hue view`. Coverage is here because the reader asked for it.

Laid out unconstrained in both passes: a stream has no pane to wrap to, so the
row count cannot change between them.
*/
private auto staticGutter(B)(ref B b, uint docRoot, in Document doc,
    in GutterSelection sel) @system
{
    import sparkles.ui.widget : Builder, WidgetTree;
    import document : coverageChannel;
    import gui_text : buildLineStarts, lineCount;
    import sparkles.code_instrumentation : maxCountWidth;
    import sparkles.ui.components.gutter : GutterChannel, gutterWidth,
        withGutterColumns, withinBudget;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : documentRows;
    import viewer_model : digitCount, lineNumberCells, lineNumberChannelId,
        srcLineOf;

    // Line numbers are opt-in here and on by default in a pane, which is the
    // one place the two disagree. A stream's output IS the text: a reader pipes
    // it into a file, a pager or a clipboard, and numbers welded to the left of
    // every line make it unusable as source. So they render when named
    // (`--gutter numbers`) and not when the default `all` is in force. The
    // interactive backends have a selection model — the numbers are chrome
    // there, outside what a copy takes.
    const wantNumbers = sel.explicit && sel.numbers;
    const wantCoverage = sel.coverage && doc.hasCoverage;

    auto pass1 = b.finish(docRoot);
    if (!wantNumbers && !wantCoverage)
        return pass1;

    const rows = documentRows(pass1, layout(pass1, Constraints()));
    auto starts = buildLineStarts(doc.source);
    size_t lineOf(size_t off) @safe => srcLineOf(starts, off);

    // No icon channel: the static sinks have no fold state, so it would have no
    // provider — reserving a strip for it would be an empty column.
    GutterChannel[] chans;
    if (wantNumbers)
    {
        const width = digitCount(lineCount(doc.source));
        auto ch = GutterChannel(id: lineNumberChannelId, width: width);
        ch.cells = lineNumberCells(rows, width, &lineOf);
        chans ~= ch;
    }
    if (wantCoverage)
        chans ~= coverageChannel(doc.coverage, rows, &lineOf);
    if (chans.length == 0)
        return pass1;
    return b.finish(withGutterColumns(b, chans, rows.length, docRoot));
}

/// Static HTML to stdout.
private int runHtmlSink(ref Document doc, in ResolvedTheme theme,
    ref GrammarRegistry registry, ref TsConfigCache cache,
    DiffLayout diffLayout = DiffLayout.unified, string gutter = "all",
    bool lineNumbers = true) @system
{
    GutterSelection gutterSel;
    if (!gutterSel.parse(gutter))
        warning(i"unknown gutter channel in `$(gutter)`; showing what was recognized");
    if (!lineNumbers)
        gutterSel.numbers = false;

    final switch (doc.kind) with (ContentKind)
    {
        case twoslash:
            import sparkles.docs.fragment : twoslashFragment;
            write(twoslashFragment(doc.twoslash, doc.events, theme, cache));
            return 0;
        case markdown:
            return emitMarkdownHtml(doc.source, theme, registry, cache);
        case code:
            // One sink, overlay or not — the same widget tree the diff view
            // writes through. It used to emit a `plainFragment` when no
            // coverage was attached and a full page when there was, so the
            // *kind of document* produced depended on an unrelated flag.
            //
            // The consequence is that `--html` on code now emits a standalone
            // page rather than a `<pre>` fragment, which is what `--diff`
            // already did. The gallery keeps its own fragment writer.
            {
                import document : coverageTintedRanges;
                import sparkles.syntax.render.widgets : CodeViewOptions,
                    viewCodeDocumentInto;
                import sparkles.ui.widget : Builder;
                import sparkles.ui.interp.html : writeWidgetHtmlPage;
                import sparkles.ui.style : defaultTwoslashPalette;
                import sparkles.ui.wrap : TextWrap;

                const pageFg = toRgb(theme.defaults.fg, hardFallbackFg);
                const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);

                CodeViewOptions copt;
                if (doc.hasCoverage)
                    copt.tintedRanges = coverageTintedRanges(doc.coverage);
                copt.wrap = TextWrap.none;   // a document, not a pane

                SmallBuffer!char htmlOut;
                auto b = Builder();
                const docRoot = viewCodeDocumentInto(b, doc.source, doc.events,
                    (() @trusted => &theme)(), pageFg, copt);
                writeWidgetHtmlPage(htmlOut, staticGutter(b, docRoot, doc, gutterSel),
                    defaultTwoslashPalette(), pageFg, pageBg, doc.title);
                write(htmlOut[]);
                return 0;
            }
        case dsv:
        {
            // The markdown arm re-extracts markdown from `doc.source` (the
            // adapter's decoded buffer — useless here), and the widget-HTML
            // interpreter cannot lay out the table view's absolutely
            // positioned stack. The semantic route is also what `DSG6`
            // wants: the adapter's already-built `MdDoc` through the shared
            // `MdDoc → HTML` emitter (the `HTM5` machinery), yielding a
            // real `<table>` with the theme stylesheet.
            import std.conv : text;
            import sparkles.syntax.md.render_html : renderMarkdownHtml;

            const pageBg = toRgb(theme.defaults.bg, hardFallbackBg);
            SmallBuffer!char output;
            output ~= "<style>\n";
            writeThemeStylesheet(theme, output);
            output ~= markdownPreviewCss;
            // `DSG2`'s HTML half: the header row pins while the page
            // scrolls, over the theme's own background.
            output ~= text("thead th{position:sticky;top:0;background-color:#",
                hex2(pageBg.r), hex2(pageBg.g), hex2(pageBg.b), "}\n");
            output ~= "</style>\n<article class=\"syn-root md\">\n";
            renderMarkdownHtml(doc.preview.doc, output);
            output ~= "\n</article>\n";
            write(output[]);
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

/// A `<link rel="stylesheet">` for `href` (attribute-escaped).
private string stylesheetLink(string href) @safe pure
{
    import std.array : replace;

    return "<link rel=\"stylesheet\" href=\"" ~ href.replace("\"", "&quot;") ~ "\">\n";
}

/// The interactive terminal (alt screen). Posix gets the full-screen viewers;
/// elsewhere the theme-selection previewer (no raw-termios TUI) fills in.
private int runTuiSink(in ViewRenderOptions opt, ref Document doc, in LabelSet labels,
    in ResolvedTheme theme, ref TsConfigCache cache,
    scope SourceSet* docSet, scope DocumentPipeline* pipeline = null) @system
{
    import sparkles.docs.source_set : SourceSet;

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
            reloadDiff: reloadDiff,
            formatPreview: opt.formatPreview,
            formatWidth: opt.formatWidth,
            formatterName: opt.formatter,
            tableCopyFlag: opt.tableCopy,
            scrollAnchor: parseScrollAnchor(opt.scrollAnchor),
            gutter: opt.gutter, lineNumbers: opt.lineNumbers,
            configStore: &gStore);
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
    import sparkles.docs.source_set : SourceSet;

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
        // Rebuilt from the effective config rather than dup-copied from the
        // `in` view: identical value (that is where `opt.gui` came from),
        // and the Android arm below needs it mutable.
        GuiOptions gui = guiOptionsOf(effectiveConfig());
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
            gutter: opt.gutter,
            codeLineNumbers: opt.codeLineNumbers,
            ansiCopyStrip: opt.ansiCopy == "strip",
            tableCopy: resolveTableCopy(opt.tableCopy,
                doc.kind == ContentKind.dsv),
            tableCopyFlag: opt.tableCopy,
            dsvText: doc.dsvText,
            dsvInfo: doc.dsvInfo,
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
            formatPreview: opt.formatPreview,
            formatWidth: opt.formatWidth,
            formatterName: opt.formatter,
            scrollAnchor: parseScrollAnchor(opt.scrollAnchor),
            treeWidth: opt.treeWidth,
            tabWidth: opt.tabWidth,
            listWhitespace: opt.listWhitespace,
            liveTypes: !opt.noLiveTypes,
            initialDiff: doc.diffDoc,
            initialDiffSides: doc.diffSides,
            initialDiffSession: doc.diffSession,
            initialCoverage: doc.coverage,
            initialHasCoverage: doc.hasCoverage,
            capture: capture,
            configStore: &gStore,
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
/// Two lowercase hex digits of one channel (CSS color assembly).
private string hex2(ubyte v) @safe pure nothrow
{
    static immutable char[16] d = "0123456789abcdef";
    return [d[v >> 4], d[v & 0xF]].idup;
}

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
    import sparkles.docs.assets : markdownPreviewCss;

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
    {
        output ~= "<style>\n";
        writeThemeStylesheet(theme, output);
        output ~= markdownPreviewCss;
        output ~= "</style>\n";
    }
    output ~= "<article class=\"syn-root md\">\n";
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
