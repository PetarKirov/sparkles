// `hue --gui` — the raylib GPU rendering backend.
//
// A third consumer of hue's (source, events, theme) triple: instead of folding
// the highlight-event stream into ANSI escapes or HTML markup, it folds it into
// raylib draw calls — "styled runs as data", the GPU backend sparkles:syntax was
// designed for (docs/specs/syntax §2). A read-only, windowed, syntax-highlighted
// view with a live theme previewer, mirroring hue's terminal Previewer on the GPU.
//
// Compiled only by the `gui` build configuration (version(HueGui)); the default
// terminal build never references raylib. Build: dub build :hue -c gui.
//
// The raylib scaffolding here (FontSet, glyph fallback, the draw primitive) is a
// deliberate COPY of apps/terminal's text-rendering core, authored in the shape
// the shared sparkles:raylib-text library will own (issue #121 M5) so the
// extraction is a move, not a redesign. The pure text-layout logic lives in the
// raylib-free `gui_text` module (unit-tested by `dub test :hue`).
module gui;

version (HueGui):

import raylib;

import core.stdc.stdarg : va_list; // for the TraceLogCallback bridge (NFR7)

// The shared raylib text core (extracted in M5). Pulls raylib-d + libs
// "raylib" transitively, so it is present only in the `gui` build.
import sparkles.raylib_text : TextStyle, FontSet, drawText;

// hue-specific viewport/search layout (raylib-free, so it stays testable).
import gui_text : columnWidth, lineCount, Match, buildLineStarts, findMatches;

// Markdown-preview model + layout (raylib-free) and the ANSI attribute bits.
import gui_preview : PreviewModel, PreviewLine, BandKind,
    buildRawPlines, quoteBarColors, quoteBarCycle, stripSgr;
import gui_ansi : Attr, decodeAnsi;

// The composable markdown view (M10): the preview is one widget tree; the
// identity channel + keyed cells drive selection/search/copy.
import sparkles.syntax.md.model : MdBlock, MdBlockKind, Span;
import sparkles.syntax.md.render_widgets : foldableSpans,
    highlightedFenceRenderer, MdViewOptions, MdViewTheme, viewMarkdown;

// The explorer pane (XPL2): the same tree model the TUI workspace uses.
import explorer : ExplorerTui, explorerGlyphs;
import sparkles.ui.components.tree_widget : treeView;

// 2D table grid selection (TBL): pure region/serialize logic over grid hits.
import sparkles.ui.components.table : GridHit;
import table_select : TableRegion, TableCopyFormat, tableSelection, serializeTable;

// Selective import avoids sparkles.syntax.Color clashing with raylib.Color:
// bare `Color` is unambiguously raylib's; the theme color type is reached only
// through StyleSpec.fg/bg (never named here).
import sparkles.syntax : HighlightEvent, LabelId, LabelSet, Theme, StyleSpec, TextAttr, UnderlineStyle,
    ResolvedTheme, resolveTheme, byStyledLine, byStyledSpan, RgbColor, toRgb;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : mix;

import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;
import sparkles.twoslash.overlay : BelowBlock, errIsWarning, highlightSignature,
    InlineDecoration, planTwoslash, TwoslashPlan, withoutQuickinfoPrefix;
import sparkles.twoslash.render_widgets : viewHoverPopup;

// The shared visual language: the twoslash palette is the single source for the
// error/warn/tag/highlight colors this backend used to hand-copy as literals, and
// the widget views drive the hover popup (so the GUI matches the TUI/HTML chrome).
import sparkles.ui.style : defaultTwoslashPalette, Palette, resolveSlot,
    schemeForBackground, Slot, UiTextStyle = TextStyle, Visual;
import sparkles.ui.geometry : Constraints, Point, Rect;
import sparkles.ui.canvas : DrawOp, LineStyle, OpKind;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state;
import sparkles.ui.state : DisclosureState, DocRow, documentRows, HoverTarget,
    hoverTargets, KeyedRect, keyedRects, scrollbarThumb, selectionRects,
    sourceOffsetAt, Timeline;
import sparkles.ui.widget : TextSpan, WidgetTree;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_raylib : RaylibCanvas, rlBg;

// The multi-document set the twoslash view navigates with `[`/`]` (`GNV1`), plus
// the two entry points a navigation reload needs.
import source_set : SourceEntry, SourceSet;
import sparkles.twoslash.ingest : loadTwoslashFile;
import sparkles.syntax.ts.highlighter : highlightInjected;

/// The window's default font size in pixels (Ctrl-±/theme cycling arrive in M3).
private enum defaultFontSize = 18;

/// A short tag for a raylib `TraceLogLevel`, embedded in the bridged message.
private string raylibLevelTag(int logLevel) @safe pure nothrow @nogc
{
    switch (logLevel)
    {
        case TraceLogLevel.LOG_TRACE:   return "trace";
        case TraceLogLevel.LOG_DEBUG:   return "debug";
        case TraceLogLevel.LOG_INFO:    return "info";
        case TraceLogLevel.LOG_WARNING: return "warning";
        case TraceLogLevel.LOG_ERROR:   return "error";
        case TraceLogLevel.LOG_FATAL:   return "fatal";
        default:                        return "log";
    }
}

/// Bridges raylib's `TraceLog` output into `sparkles.base.logger` (hue spec
/// `NFR7`). raylib hands us a printf-style format + `va_list`; we render it
/// into a stack buffer and emit through the logger at $(B trace) level, so its
/// chatter obeys hue's log level — silent under the default warning threshold
/// (`DEG1`) — instead of going straight to stderr. `extern(C) @nogc nothrow`
/// to match `TraceLogCallback`; installed before `InitWindow`.
extern (C) private void raylibTraceLog(int logLevel, const(char)* text, va_list args)
    @nogc nothrow
{
    import core.stdc.stdio : vsnprintf;
    import sparkles.base.logger : trace;

    char[1024] buf = void;
    const written = () @trusted { return vsnprintf(buf.ptr, buf.length, text, args); }();
    if (written <= 0)
        return;
    const len = written < cast(int) buf.length ? cast(size_t) written : buf.length - 1;
    const msg = () @trusted { return cast(const(char)[]) buf[0 .. len]; }();
    trace(i"raylib[$(raylibLevelTag(logLevel))]: $(msg)");
}

/// Sane concrete fallbacks when a theme leaves the page fore-/background unset
/// (the GPU has no "terminal default" to defer to, unlike the ANSI backend).
private enum RgbColor hardFallbackFg = RgbColor(0xcd, 0xd6, 0xf4);
private enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x2e);

/// Translucent overlays for search matches: all matches, and the current one.
private enum Color matchTint = Color(255, 215, 0, 70);
private enum Color currentMatchTint = Color(255, 145, 0, 130);

/// The interactive input mode (M4): normal keys, or typing a search / goto line.
private enum Mode
{
    normal,
    search,
    gotoLine,
}

/// A loaded document — the highlight inputs the viewer needs to show one file.
struct LoadedDoc
{
    const(char)[] source;
    const(HighlightEvent)[] events;
    PreviewModel preview;
    TwoslashReturn twoslash; /// empty `code` ⇒ not a twoslash document
}

/// Loads a document by path. Supplied by `app.d`, which owns the grammar registry
/// and cache, so the GUI navigates a set (`GNV1`) without duplicating that
/// pipeline — the same delegate seam `gallery.writeGallery` uses.
alias DocLoader = LoadedDoc delegate(string path) @system;

/**
Opens the raylib window and paints the highlighted file. M1 draws the whole
file with the initially selected theme; scrolling/gutter (M2), sizing/resize
and live theme cycling (M3), and search (M4) build on top.

`names`/`themes` are the sorted, parallel built-in theme arrays; `startIdx` is
the initially selected theme. Returns a process exit code.
*/
int runGui(
    string title,
    const(char)[] source,
    const(HighlightEvent)[] events,
    LabelSet labels,
    const(string)[] names,
    immutable(Theme)[] themes,
    size_t startIdx,
    PreviewModel preview = PreviewModel.init,
    string fontName = "monospace",
    int fontSize = defaultFontSize,
    int windowWidth = 800,
    int windowHeight = 600,
    bool lineNumbers = true,
    bool codeLineNumbers = true,
    bool ansiCopyStrip = false,          // --ansi-copy=strip (SEL7/CLI10); default raw
    TableCopyFormat tableCopy = TableCopyFormat.tsv, // --table-copy (TBL2/CLI11)
    SourceSet* set = null,               // the document set to navigate (GNV1)
    DocLoader loadDoc = null,            // loads a set entry (supplied by app.d)
    TsConfigCache* tsCache = null,       // fence highlighting for the widget view
    TwoslashReturn twoslash = TwoslashReturn.init, // twoslash document payload
    string docPath = null,               // on-disk path (reveal in the tree)
    bool startInTree = false,            // a directory target opens in the tree
    string treeRoot = null,              // explorer root (default: docPath's dir)
    FontSet.FaceOverrides faces = FontSet.FaceOverrides.init, // per-style fonts
) @system
{
    import std.stdio : stderr;
    import std.string : toStringz;
    import std.process : environment;
    import std.conv : to, text;

    // Debug/CI capture: HUE_GUI_SCREENSHOT=<path> renders a few frames, writes a
    // PNG, and exits — the golden-frame harness the syntax spec's totality and
    // M5's byte-identical-render checks rely on (skipTest-gated when headless).
    const shotPath = environment.get("HUE_GUI_SCREENSHOT", "");
    // HUE_GUI_FLASH=1: alternate the clear color every ~0.5 s and skip the
    // pane fill — a ghosting discriminator. If the background flashes
    // everywhere but stale text rides on top, the ghost is DRAWN each frame;
    // any region that does NOT flash is not being cleared/presented.
    const flashDebug = environment.get("HUE_GUI_FLASH", "").length != 0;
    // HUE_GUI_SCREENSHOT_FRAME=<n> delays the capture (default 20) so a QA
    // harness can drive synthetic input first.
    int shotFrame = 20;
    try
        if (environment.get("HUE_GUI_SCREENSHOT_FRAME", null).length)
            shotFrame = environment.get("HUE_GUI_SCREENSHOT_FRAME").to!int;
    catch (Exception)
    {
    }
    // Debug/CI: HUE_GUI_TOP=<n> sets the initial scroll line (clamped) so a
    // golden capture can exercise the culled viewport; HUE_GUI_FONTSIZE overrides
    // the --font-size for deterministic captures.
    // `--font-size` arrives in points; convert to pixels (96-DPI, 1pt = 1/72in)
    // exactly like apps/terminal so both raylib apps size a font identically.
    int fontSizePx = cast(int)(fontSize * 96.0 / 72.0 + 0.5);
    long initialTop;
    try
    {
        initialTop = environment.get("HUE_GUI_TOP", "0").to!long;
        // HUE_GUI_FONTSIZE stays in pixels so golden captures are deterministic.
        if (environment.get("HUE_GUI_FONTSIZE", null).length)
            fontSizePx = environment.get("HUE_GUI_FONTSIZE").to!int;
    }
    catch (Exception)
    {
    }
    if (fontSizePx < 6)
        fontSizePx = 6;

    // Route raylib's own trace log through sparkles' logger (NFR7) before it
    // opens anything, so its init chatter obeys hue's log level instead of
    // writing to stderr. Its default LOG_INFO threshold still gates what it
    // hands us; everything bridged lands at trace level (silent by default).
    SetTraceLogCallback(&raylibTraceLog);

    InitWindow(800, 600, ("hue — " ~ title).toStringz);
    scope (exit) CloseWindow();
    SetWindowState(ConfigFlags.FLAG_WINDOW_RESIZABLE);
    SetTargetFPS(60);
    SetExitKey(KeyboardKey.KEY_NULL); // arrow/close-button handling only (M3 adds keys)

    // LoadFontEx uploads a GPU texture, so the FontSet must load after InitWindow.
    // `fontName` may be a path, a family, or a fontconfig preference list.
    FontSet fonts;
    if (!FontSet.tryLoad(fontName, fontSizePx, fonts, null, faces))
    {
        stderr.writeln("hue --gui: could not load a font from '", fontName,
            "' (is fontconfig available?)");
        return 1;
    }
    scope (exit) fonts.unload();

    // `--window-width`/`--window-height` are in cells (like apps/terminal); size
    // the window to the loaded cell metrics.
    if (windowWidth > 0 && windowHeight > 0)
        SetWindowSize(windowWidth * fonts.cellW(), windowHeight * fonts.cellH());

    // The current document. Mutable so a document set can be navigated in place
    // (`GNV1`) — the window, font atlas and grammar cache are reused; only these
    // change. With no set they are simply the arguments, unchanged.
    const(char)[] curSource = source;
    const(HighlightEvent)[] curEvents = events;
    PreviewModel curPreview = preview;
    TwoslashReturn curTw = twoslash;
    string curName = title;
    string curSummary = set !is null && !set.empty ? set.current.summary : "";
    size_t srcTotal = lineCount(curSource);

    // Markdown-preview state (M4). A markdown file opens in preview by default;
    // Tab toggles to the raw highlighted-source view. `HUE_GUI_PREVIEW=0/1`
    // pins the initial mode for deterministic golden captures.
    bool showPreview = curPreview.present || curTw.code.length != 0;
    if (environment.get("HUE_GUI_PREVIEW", "") == "0")
        showPreview = false;
    else if (environment.get("HUE_GUI_PREVIEW", "") == "1")
        showPreview = curPreview.present || curTw.code.length != 0;
    PreviewLine[] plines; // the raw (highlighted-source) view's wrapped lines

    // The markdown widget pipeline (M10): the preview is one laid-out tree.
    // `mdRows` (per-visual-row text + source range) and the keyed cell rects
    // are the identity channel the interactions run on.
    WidgetTree mdTree;
    Frame[] mdFrames;
    DrawOp[] mdOps;
    DocRow[] mdRows;
    HoverTarget[] mdTargets;
    KeyedRect[] mdCells;
    // Document structure resolved once per document: fence bodies (for the
    // copy affordance) and table cells in document order.
    static struct MdFence { Span body; bool isAnsi; }
    static struct MdCell { int table; size_t row, col; Span span; }
    MdFence[] mdFences;
    MdCell[] mdCellList;
    size_t copiedFenceSrc = size_t.max; // body start of the just-copied fence
    // Source-anchored identity bases (see the markdown view's options).
    enum size_t fenceHitBase = size_t.max / 2 + 1;
    enum size_t foldHitBase = size_t.max / 4 * 3 + 1;
    enum size_t tableKeyBase = 1;

    // Content folding (`FLD`): the shared disclosure machine, keyed by source
    // span start, plus the document's foldable spans (the FSR3 provider).
    DisclosureState!size_t mdFolds = DisclosureState!size_t(true);
    Span[] mdFoldable;

    int lastWidthCols = -1;
    // Resize debounce: during a drag the column count changes almost every frame,
    // so re-wrap only once the width has held steady for a few frames — the drag
    // pays one relayout when it settles instead of one per frame. Discrete width
    // changes (theme / font size / gutter toggles) relayout immediately, so this
    // branch only ever debounces a live window resize.
    int prevWidthCols = -1;
    int resizeSettle;
    enum resizeSettleFrames = 4; // ~66 ms at 60 FPS

    // The live theme state: ←/→ browse `themes`, re-resolving and repainting —
    // the GPU counterpart of hue's terminal Previewer.
    size_t themeIdx = startIdx;
    ResolvedTheme current;
    RgbColor pageFg, pageBg, gutterFg;
    RgbColor[quoteBarCycle] quoteBars;   // per-depth block-quote gutter colors
    RgbColor scrollbarTrack, scrollbarThumb; // link-tinted — distinct from the
    // grayscale structural bands (page / code header / code panel)

    // Line-number gutter width in cells (0 when off) — a stable size from the
    // source line count so toggling wrapping never oscillates the layout.
    int gutterCols() => lineNumbers ? digitCount(srcTotal) + 1 : 0;

    // The right gutter reserved for the scrollbar == its expanded (hover) width,
    // so the expanded handle fills the gutter exactly instead of overlapping text.
    int scrollbarGutter() => cast(int)(fonts.cellW() * 1.5f);

    // Preview columns available for the current window/font: the screen minus the
    // 1-cell left text padding, the scrollbar gutter on the right, and the line-
    // number gutter. Re-laying-out on change keeps wrapping correct.
    // The explorer pane (XPL2): tree left, document right — the TUI
    // workspace's model, painted through RaylibCanvas. 'e' toggles it.
    import std.path : dirName;

    ExplorerTui tree;
    bool treeVisible = startInTree;
    bool treeFocused = startInTree;
    enum treeCols = 32;
    int treePx() => treeVisible ? (treeCols + 1) * fonts.cellW() : 0;

    int widthCols()
    {
        const cw = fonts.cellW();
        const w = (GetScreenWidth() - cw - scrollbarGutter() - gutterCols() * cw
            - treePx()) / cw;
        return w < 8 ? 8 : w;
    }

    // Fence renderer for the widget view: ` ```ansi ` fences decode through
    // the off-screen VT into resolved-color spans (fg + bg + attrs); every
    // other language goes through the shared injection-aware highlighter.
    TextSpan[][] delegate(const(char)[], const(char)[]) @safe mdFenceRenderer()
    {
        auto highlight = tsCache !is null
            ? highlightedFenceRenderer(tsCache, &current, pageFg) : null;
        return delegate TextSpan[][] (const(char)[] lang, const(char)[] body_)
            @trusted {
            if (lang != "ansi")
                return highlight !is null ? highlight(lang, body_) : null;
            TextSpan[][] lines;
            foreach (ref ln; decodeAnsi(body_))
            {
                TextSpan[] spans;
                foreach (ref sp; ln.spans)
                    spans ~= TextSpan(sp.text,
                        textStyle: attrsToTextStyle(sp.attrs),
                        fg: sp.fgDefault ? pageFg : sp.fg, hasFg: true,
                        bg: sp.bg, hasBg: !sp.bgDefault);
                lines ~= spans;
            }
            return lines;
        };
    }

    // Rebuild the markdown widget pipeline (theme/width/document dependent):
    // view → layout → display list, plus the derived row index, hit targets
    // and keyed cell rects, and the document's fence/cell structure.
    void rebuildMd()
    {
        if (curTw.code.length)
        {
            // A twoslash document: the whole-document widget view (code lines
            // as resolved spans + fused decorations + interleaved blocks).
            import sparkles.twoslash.render_widgets : viewTwoslashDocument;

            mdTree = viewTwoslashDocument(curTw, curEvents, &current, pageFg,
                tsCache);
            mdFrames = layout(mdTree, Constraints(maxW: lastWidthCols));
            mdOps = buildDisplayList(mdTree, mdFrames,
                defaultTwoslashPalette(schemeForBackground(pageBg)),
                pageFg, pageBg);
            mdRows = documentRows(mdTree, mdFrames);
            mdTargets = hoverTargets(mdTree, mdFrames);
            mdCells = null;
            mdFences.length = 0;
            mdCellList.length = 0;
            return;
        }
        MdViewOptions opt = {
            theme: MdViewTheme.derive(current, pageFg, pageBg),
            fenceHitBase: fenceHitBase,
            tableKeyBase: tableKeyBase,
            copiedFence: copiedFenceSrc,
            fenceRenderer: mdFenceRenderer(),
            foldedSpans: mdFolds.exceptions,
            foldHitBase: foldHitBase,
        };
        mdFoldable = foldableSpans(curPreview.doc);
        mdTree = viewMarkdown(curPreview.doc, opt);
        mdFrames = layout(mdTree, Constraints(maxW: lastWidthCols));
        mdOps = buildDisplayList(mdTree, mdFrames,
            themes[themeIdx].effectivePalette, pageFg, pageBg);
        mdRows = documentRows(mdTree, mdFrames);
        mdTargets = hoverTargets(mdTree, mdFrames);
        mdCells = keyedRects(mdTree, mdFrames);

        mdFences.length = 0;
        mdCellList.length = 0;
        int tableIdx = -1;
        void collect(in MdBlock blk)
        {
            if (blk.kind == MdBlockKind.codeFence)
                mdFences ~= MdFence(blk.codeBody, blk.infoLang == "ansi");
            if (blk.kind == MdBlockKind.table)
            {
                ++tableIdx;
                foreach (ri, ref const row; blk.children)
                    foreach (ci, ref const cell; row.children)
                        mdCellList ~= MdCell(tableIdx, ri, ci, cell.span);
            }
            foreach (ref const c; blk.children)
                collect(c);
        }
        collect(curPreview.doc.root);
    }

    // A table's grid dimensions from the collected cell list.
    static struct Dims { size_t rows, cols; }
    static Dims tableDims(in MdCell[] cells, int table)
    {
        Dims d;
        foreach (ref const mc; cells)
            if (mc.table == table)
            {
                if (mc.row + 1 > d.rows)
                    d.rows = mc.row + 1;
                if (mc.col + 1 > d.cols)
                    d.cols = mc.col + 1;
            }
        return d;
    }

    // Both views reflow on resize. The markdown preview lays its widget tree
    // out to the new width; the raw view wraps the highlighted source into
    // visual lines (`PreviewLine[]`) so line numbers track the source line.
    void relayout()
    {
        lastWidthCols = widthCols();
        if (showPreview && (curPreview.present || curTw.code.length))
            rebuildMd();
        else
            plines = buildRawPlines(curSource, curEvents, current, pageFg, pageBg, lastWidthCols);
    }

    void applyTheme(size_t i)
    {
        themeIdx = i;
        current = resolveTheme(themes[i], labels);
        pageFg = toRgb(current.defaults.fg, hardFallbackFg);
        pageBg = toRgb(current.defaults.bg, hardFallbackBg);
        gutterFg = mix(pageFg, pageBg, 0.5); // muted line numbers
        quoteBars = quoteBarColors(current, pageFg, pageBg);
        // Scrollbar chrome: tint toward the theme's link color so the hover track
        // and thumb read as a distinct hue against the grayscale bg/code bands.
        const linkC = toRgb(current[current.labels.resolve("markup.link")].fg, pageFg);
        scrollbarTrack = mix(pageBg, linkC, 0.22);
        scrollbarThumb = mix(pageBg, linkC, 0.5);
        SetWindowTitle(text("hue — ", title, " — ", names[i],
            " (", i + 1, "/", names.length, ")").toStringz);
        // The explorer pane follows the theme too — page colors and the
        // palette its slots resolve against, not just the syntax colors.
        tree.theme = current;
        tree.themeValue = &themes[i];
        tree.pageFg = pageFg;
        tree.pageBg = pageBg;
        if (tree.root.length)
            tree.rebuild();
        relayout();  // preview colors follow the theme
    }

    tree.chromeRows = 0; // the GUI pane is all tree rows
    tree.root = treeRoot.length ? treeRoot
        : (docPath.length ? dirName(docPath) : ".");
    applyTheme(themeIdx);
    if (docPath.length)
        tree.reveal(docPath);

    auto lineStarts = buildLineStarts(curSource);

    SmallBuffer!(char, 4096) buf; // reused, NUL-terminated for raylib
    long top = initialTop; // index of the first visible line

    // Search / goto state (M4).
    Mode mode = Mode.normal;
    SmallBuffer!(char, 256) query;
    Match[] matches;
    size_t curMatch;


    /// Loads the set's currently-selected document in place (`GNV1`): re-read,
    /// re-highlight, rebuild the preview model, relayout. Scroll and search reset;
    /// the theme and the view toggles persist (`GNV3`). A document that fails to
    /// load is reported and the previous one stays on screen.
    bool openPath(string path, string name, string summary)
    {
        if (loadDoc is null)
            return false;
        LoadedDoc doc;
        try
            doc = loadDoc(path);
        catch (Exception ex)
        {
            stderr.writeln("hue: ", path, ": ", ex.msg);
            return false;
        }

        curSource = doc.source;
        curEvents = doc.events;
        curPreview = doc.preview;
        curTw = doc.twoslash;
        curName = name;
        curSummary = summary;
        srcTotal = lineCount(curSource);
        lineStarts = buildLineStarts(curSource);
        showPreview = curPreview.present || curTw.code.length != 0;

        top = 0;            // a new document starts at the top (`GNV3`)
        query.clear();
        matches = null;
        curMatch = 0;
        mode = Mode.normal;

        lastWidthCols = -1; // force the re-layout even at an unchanged width
        relayout();
        SetWindowTitle(("hue — " ~ curName).toStringz);
        tree.reveal(path); // the explorer follows the open document (XPL3/4)
        return true;
    }

    // Enter/l/double-click on a tree row opens a file (or toggles a dir).
    void activateTree()
    {
        if (tree.sel >= cast(long) tree.rows.length)
            return;
        if (!tree.activate() && tree.picked.length)
        {
            import std.path : baseName;

            const path = tree.picked;
            tree.picked = null;
            if (openPath(path, baseName(path), ""))
                treeFocused = false;
        }
    }

    /// ditto — the set's currently-selected entry (`GNV1`).
    bool loadSelected()
    {
        if (set is null || set.empty)
            return false;
        return openPath(set.current.path, set.current.name, set.current.summary);
    }

    // Recompute all match ranges for the current query — an extra decoration
    // layer over the styled spans (the pure mapping lives in gui_text).
    void recompute()
    {
        matches = findMatches(curSource, query[], lineStarts);
        curMatch = 0;
    }

    // Lines wrap, so source coordinates must be mapped to visual (`plines`) rows.
    // The first visual row at/after source line `srcLine`.
    long visualOfSrc(size_t srcLine)
    {
        foreach (idx, ref pl; plines)
            if (pl.showNumber && pl.srcLine >= srcLine)
                return cast(long) idx;
        return plines.length ? cast(long) plines.length - 1 : 0;
    }

    // The visual row a match falls on (its source line's wrapped row covering the
    // match column), else that source line's first row.
    long visualOfMatch(in Match m)
    {
        foreach (idx, ref pl; plines)
            if (pl.srcLine == m.line && pl.wrapColOffset <= cast(long) m.col
                && cast(long) m.col < pl.wrapColOffset + lineCols(pl))
                return cast(long) idx;
        return visualOfSrc(m.line);
    }

    // Center the given match in the viewport (as far as clamping allows).
    void jumpToMatch(size_t i, int visibleRows)
    {
        if (matches.length == 0)
            return;
        curMatch = i % matches.length;
        top = visualOfMatch(matches[curMatch]) - visibleRows / 2;
    }

    // Debug/CI: HUE_GUI_SEARCH=<text> preselects a search (highlights + jump to
    // the first match) so a golden capture exercises the match overlay.
    foreach (ch; environment.get("HUE_GUI_SEARCH", ""))
        query ~= ch;
    if (query.length)
    {
        recompute();
        if (matches.length)
            top = visualOfMatch(matches[0]);
    }

    Scrollbar sb;
    Scrollbar treeSb; // the tree pane's — same behavior, its own state
    float wheelAccum = 0; // fractional wheel deltas accumulate to whole rows

    // Fullscreen (F11): a manual borderless toggle. raylib's
    // ToggleBorderlessWindowed forces the primary monitor and, on some
    // compositors, drops the window decorations on the way back. Managing the
    // undecorated flag + geometry ourselves restores decorations reliably and
    // keeps the window on its current monitor (on X11; on Wayland the app can't
    // set its own position, so it stays put — never yanked to the primary).
    bool isFullscreen;
    int savedX, savedY, savedW, savedH;

    // Code-block copy button: the STM6 timeline for the brief "copied"
    // checkmark feedback (the copied fence itself is `copiedFenceSrc`).
    Timeline copiedFlash;
    bool copiedShown; // the ✔ glyph is in the tree; rebuild when the flash ends

    // Twoslash hover latch: the open popup's node (+1; 0 = none), its rect
    // (pointer hysteresis), and the token-underline fade (STM6).
    size_t hotNode = 0;
    Rectangle hotPopup;
    bool havePopup = false;
    Timeline fade;
    int forceHover = -1; // HUE_GUI_HOVER=<n>: force the Nth popup (goldens)
    try
        forceHover = environment.get("HUE_GUI_HOVER", null).length
            ? environment.get("HUE_GUI_HOVER").to!int : -1;
    catch (Exception)
    {
    }

    // Mouse selection has two regimes (a drag stays in the one it starts in, TBL4):
    //  • text  (SEL): a source byte range [selMin, selMax). Prose/code map a click
    //    char-precisely; an ANSI body line selects its whole fence-body span (SEL6).
    //  • table (TBL): a 2D grid selection inside one table, resolved from anchor +
    //    head cells (from the table map) under Shift/Alt.
    enum Regime { none, text, table }
    Regime regime;
    bool selecting;
    // text regime — anchor/head each a source span (char ⇒ lo==hi; ANSI ⇒ block).
    long anchorLo, anchorHi, headLo, headHi;
    // table regime.
    int selTable = -1;
    GridHit tblAnchor, tblHead;
    bool tblShift, tblAlt;

    // Copy modes (SEL7/TBL2), toggleable at runtime ('y' ANSI, 't' table); a
    // toggle flashes the new mode in the status bar for a moment.
    bool ansiStrip = ansiCopyStrip;
    TableCopyFormat tableFmt = tableCopy;
    string copyModeMsg;
    Timeline toast;

    // The text-regime selection as a source range [selMin, selMax) — the union of
    // the anchor and head spans (a char point is a zero-width span).
    long selMin() => anchorLo < headLo ? anchorLo : headLo;
    long selMax() => anchorHi > headHi ? anchorHi : headHi;

    // Copy the current selection: a text range → `source[min..max]` (SGR-stripped
    // when `ansiStrip`); a table region → TSV / markdown cells (SEL7/TBL2).
    void copySelection()
    {
        if (regime == Regime.text && selMax() > selMin() && selMax() <= source.length)
        {
            auto txt = source[cast(size_t) selMin() .. cast(size_t) selMax()];
            SetClipboardText((ansiStrip ? stripSgr(txt) : txt).toStringz);
        }
        else if (regime == Regime.table && selTable >= 0)
        {
            // Cell content = its raw source slice (through the cell spans the
            // document walk collected — the same identity the tint uses).
            const dims = tableDims(mdCellList, selTable);
            const reg = tableSelection(tblAnchor, tblHead, tblShift, tblAlt,
                dims.rows, dims.cols);
            const(char)[] cellText(size_t r, size_t c)
            {
                foreach (ref const mc; mdCellList)
                    if (mc.table == selTable && mc.row == r && mc.col == c
                        && mc.span.end <= source.length)
                        return source[mc.span.start .. mc.span.end];
                return "";
            }
            const txt = serializeTable(reg, &cellText, tableFmt);
            if (txt.length)
                SetClipboardText(txt.toStringz);
        }
    }

    // 'z': toggle the innermost fold at the text selection (else the top
    // visible row) — unfold the innermost folded region first, else fold the
    // innermost foldable one.
    void toggleFold()
    {
        long off = -1;
        if (regime == Regime.text && selMax() > selMin())
            off = selMin();
        else if (mdRows.length)
        {
            const t0 = cast(size_t)(top >= 0
                && top < cast(long) mdRows.length ? top : 0);
            if (mdRows[t0].srcStart != size_t.max)
                off = cast(long) mdRows[t0].srcStart;
        }
        if (off < 0)
            return;
        size_t best = size_t.max, bestLen = size_t.max;
        foreach (sp; mdFoldable)
            if (!mdFolds.isOpen(sp.start) && off >= cast(long) sp.start
                && off < cast(long) sp.end && sp.end - sp.start < bestLen)
            {
                best = sp.start;
                bestLen = sp.end - sp.start;
            }
        if (best == size_t.max)
            foreach (sp; mdFoldable)
                if (mdFolds.isOpen(sp.start) && off >= cast(long) sp.start
                    && off < cast(long) sp.end && sp.end - sp.start < bestLen)
                {
                    best = sp.start;
                    bestLen = sp.end - sp.start;
                }
        if (best == size_t.max)
            return;
        mdFolds = mdFolds.toggled(best);
        rebuildMd();
    }

    int frame = 0;
    while (!WindowShouldClose())
    {
        const cellW = fonts.cellW();
        const cellH = fonts.cellH();
        const screenW = GetScreenWidth();
        const screenH = GetScreenHeight();
        const visibleRows = screenH / cellH;
        // With a set header bar, BOTH panes start under it (nothing hides
        // beneath the bar any more); the panes are docRows tall.
        const treeTopRows = set !is null && !set.empty ? 1 : 0;
        const docRows = visibleRows - treeTopRows;
        const docY0 = treeTopRows * cellH;


        // Reflow (both views wrap) when the window width in columns changes — but
        // debounced: only once the width has held steady for `resizeSettleFrames`
        // frames, so a drag that sweeps many widths re-wraps once at the end. While
        // the drag is in flight the (slightly stale) wrapped lines keep painting.
        const wc = widthCols();
        if (wc != lastWidthCols)
        {
            resizeSettle = (wc == prevWidthCols) ? resizeSettle + 1 : 0;
            if (resizeSettle >= resizeSettleFrames)
                relayout();
        }
        prevWidthCols = wc;
        // The active view's visual-line space (scroll/selection/search).
        const mdActive = showPreview && (curPreview.present || curTw.code.length);
        const total = mdActive ? mdRows.length : plines.length;
        const maxTop = total > docRows ? cast(long)(total - docRows) : 0;

        // F11 toggles borderless fullscreen on the window's current monitor;
        // active in any input mode. Reflow-on-resize keeps working because the
        // screen size changes.
        if (IsKeyPressed(KeyboardKey.KEY_F11))
        {
            if (!isFullscreen)
            {
                const wp = GetWindowPosition();
                savedX = cast(int) wp.x;
                savedY = cast(int) wp.y;
                savedW = GetScreenWidth();
                savedH = GetScreenHeight();
                const mon = GetCurrentMonitor();
                const mp = GetMonitorPosition(mon);
                SetWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED);
                SetWindowPosition(cast(int) mp.x, cast(int) mp.y);
                SetWindowSize(GetMonitorWidth(mon), GetMonitorHeight(mon));
                isFullscreen = true;
            }
            else
            {
                ClearWindowState(ConfigFlags.FLAG_WINDOW_UNDECORATED);
                SetWindowSize(savedW, savedH);
                SetWindowPosition(savedX, savedY);
                isFullscreen = false;
            }
        }

        const inputMode = mode != Mode.normal;
        if (inputMode)
        {
            // Typing a search query or a goto-line number.
            for (int c = GetCharPressed(); c > 0; c = GetCharPressed())
            {
                if (c < 32 || c >= 127)
                    continue;
                if (mode == Mode.gotoLine && (c < '0' || c > '9'))
                    continue;
                if (query.length < 255)
                    query ~= cast(char) c;
                if (mode == Mode.search)
                    recompute();
            }
            if (IsKeyPressed(KeyboardKey.KEY_BACKSPACE) && query.length)
            {
                query.popBack();
                if (mode == Mode.search)
                    recompute();
            }
            if (IsKeyPressed(KeyboardKey.KEY_ENTER))
            {
                if (mode == Mode.search)
                {
                    // Jump to the first match whose visual row is at/after the
                    // current top (matches are in source order → visual order), wrap.
                    size_t i;
                    while (i < matches.length && visualOfMatch(matches[i]) < top)
                        ++i;
                    jumpToMatch(i < matches.length ? i : 0, visibleRows);
                }
                else if (query.length) // gotoLine → the source line's visual row
                {
                    try
                    {
                        const n = query[].to!long;
                        top = visualOfSrc(cast(size_t)(n > 0 ? n - 1 : 0));
                    }
                    catch (Exception)
                    {
                    }
                }
                mode = Mode.normal;
            }
            if (IsKeyPressed(KeyboardKey.KEY_ESCAPE))
            {
                mode = Mode.normal;
                query.clear(); // cancelling clears the query (and search highlights)
                matches = null;
            }
        }
        else
        {
            // Normal mode: scroll, theme cycling, font sizing, match nav, and the
            // keys that enter the input modes.

            // 'e' toggles the explorer pane (XPL2); focus follows visibility.
            if (pressed(KeyboardKey.KEY_E))
            {
                treeVisible = !treeVisible;
                treeFocused = treeVisible;
                lastWidthCols = -1;
                relayout();
            }

            if (treeFocused && treeVisible)
            {
                // The explorer pane's keys: row navigation + open/close.
                tree.height = visibleRows;
                if (pressed(KeyboardKey.KEY_J) || pressed(KeyboardKey.KEY_DOWN))
                {
                    ++tree.sel;
                    tree.clamp();
                }
                if (pressed(KeyboardKey.KEY_K) || pressed(KeyboardKey.KEY_UP))
                {
                    --tree.sel;
                    tree.clamp();
                }
                if (pressed(KeyboardKey.KEY_HOME))
                {
                    tree.sel = 0;
                    tree.clamp();
                }
                if (pressed(KeyboardKey.KEY_END))
                {
                    tree.sel = cast(long) tree.rows.length - 1;
                    tree.clamp();
                }
                if (IsKeyPressed(KeyboardKey.KEY_ENTER) || pressed(KeyboardKey.KEY_L))
                    activateTree();
                if (pressed(KeyboardKey.KEY_H))
                {
                    // Close the selected dir, or jump to the parent row.
                    if (tree.sel < cast(long) tree.rows.length)
                    {
                        const node = tree.rows[cast(size_t) tree.sel].node;
                        const v = tree.data.nodes[node].value;
                        if (v.isDir && tree.open.isOpen(v.path))
                        {
                            tree.open = tree.open.closed(v.path);
                            tree.rebuild();
                        }
                        else if (tree.data.nodes[node].parent != uint.max)
                        {
                            const par = tree.data.nodes[node].parent;
                            foreach (i, ref const r; tree.rows)
                                if (r.node == par)
                                {
                                    tree.sel = cast(long) i;
                                    break;
                                }
                            tree.clamp();
                        }
                    }
                }
            }
            else
            {
                // Scroll: wheel, ↑/↓ (one line), j/k, PageUp/Down, Home/End.
                if (pressed(KeyboardKey.KEY_J) || pressed(KeyboardKey.KEY_DOWN))
                    ++top;
                if (pressed(KeyboardKey.KEY_K) || pressed(KeyboardKey.KEY_UP))
                    --top;
                if (pressed(KeyboardKey.KEY_HOME))
                    top = 0;
                if (pressed(KeyboardKey.KEY_END))
                    top = maxTop;
            }
            // The wheel scrolls the pane under the cursor (tree or document).
            // High-resolution wheels deliver FRACTIONAL deltas; accumulate to
            // whole rows so gentle scrolling is never truncated to nothing.
            const wheel = GetMouseWheelMove();
            if (wheel != 0)
            {
                wheelAccum += wheel * 3;
                const steps = cast(long) wheelAccum;
                if (steps != 0)
                {
                    wheelAccum -= steps;
                    if (treeVisible && GetMousePosition().x < treeCols * cellW)
                        tree.scrollBy(-steps);
                    else
                        top -= steps;
                }
            }
            if (pressed(KeyboardKey.KEY_PAGE_DOWN))
                top += visibleRows;
            if (pressed(KeyboardKey.KEY_PAGE_UP))
                top -= visibleRows;

            // Live theme cycling (← previous, → next, wrapping).
            if (pressed(KeyboardKey.KEY_RIGHT))
                applyTheme(themeIdx + 1 == themes.length ? 0 : themeIdx + 1);
            if (pressed(KeyboardKey.KEY_LEFT))
                applyTheme(themeIdx == 0 ? themes.length - 1 : themeIdx - 1);

            // Font sizing: Ctrl-'=' / Ctrl-'-' (reload faces + re-measure). A
            // discrete keypress, so reflow immediately (the cell size — and thus
            // the column count — changed) rather than waiting out the resize debounce.
            const ctrl = IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL);
            if (ctrl && pressed(KeyboardKey.KEY_EQUAL))
            {
                fonts.reload(fonts.size() + 2);
                relayout();
            }
            else if (ctrl && pressed(KeyboardKey.KEY_MINUS) && fonts.size() > 6)
            {
                fonts.reload(fonts.size() - 2);
                relayout();
            }

            // Match navigation: n next, Shift-n previous.
            if (matches.length && pressed(KeyboardKey.KEY_N))
            {
                const shift = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                    || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
                jumpToMatch(shift ? curMatch + matches.length - 1 : curMatch + 1, visibleRows);
            }

            // `[` / `]` (and the mouse back/forward buttons) walk the document
            // set; `i` returns to the index view (`GNV1`/`GAL5`).
            if (set !is null && !set.empty && loadDoc !is null)
            {
                const back = IsKeyPressed(KeyboardKey.KEY_LEFT_BRACKET)
                    || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_BACK);
                const fwd = IsKeyPressed(KeyboardKey.KEY_RIGHT_BRACKET)
                    || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_FORWARD);
                if ((back || fwd) && set.move(back ? -1 : 1))
                    loadSelected();
                if (IsKeyPressed(KeyboardKey.KEY_I))
                {
                    treeVisible = true;
                    treeFocused = true;
                    lastWidthCols = -1;
                    relayout();
                }
            }

            // Tab toggles the decorated view ↔ raw highlighted source.
            if ((curPreview.present || curTw.code.length) && IsKeyPressed(KeyboardKey.KEY_TAB))
            {
                showPreview = !showPreview;
                lastWidthCols = -1; // force a reflow on next frame
                relayout();
            }

            // 'l' toggles the file line-number gutter (changes the wrap width).
            if (!treeFocused && pressed(KeyboardKey.KEY_L))
            {
                lineNumbers = !lineNumbers;
                lastWidthCols = -1; // gutter width changed → reflow
                relayout();
            }

            // Ctrl-C copies the current selection to the clipboard; plain 'c'
            // toggles the in-panel code-block line numbers.
            if (ctrl && IsKeyPressed(KeyboardKey.KEY_C))
                copySelection();
            else if (!ctrl && !treeFocused && pressed(KeyboardKey.KEY_C))
            {
                codeLineNumbers = !codeLineNumbers;
                lastWidthCols = -1;
                relayout();
            }

            // Copy-mode toggles (SEL7/TBL2): 'y' ANSI raw↔strip, 't' table
            // TSV↔markdown. They only change how a copy renders — no relayout.
            if (pressed(KeyboardKey.KEY_Y))
            {
                ansiStrip = !ansiStrip;
                copyModeMsg = ansiStrip ? "ansi-copy: strip" : "ansi-copy: raw";
                toast = Timeline.triggered(toastCfg);
            }
            // 'z' toggles the innermost fold at the selection (else the top
            // row) — the FLD5 keyboard entry, over the row's source identity.
            if (mdActive && !treeFocused && pressed(KeyboardKey.KEY_Z))
                toggleFold();
            if (pressed(KeyboardKey.KEY_T))
            {
                tableFmt = tableFmt == TableCopyFormat.tsv
                    ? TableCopyFormat.markdown : TableCopyFormat.tsv;
                copyModeMsg = tableFmt == TableCopyFormat.tsv
                    ? "table-copy: tsv" : "table-copy: markdown";
                toast = Timeline.triggered(toastCfg);
            }

            // Enter an input mode: '/' search (raw view only), 'g' goto-line.
            if (!treeFocused && !showPreview && IsKeyPressed(KeyboardKey.KEY_SLASH))
            {
                mode = Mode.search;
                query.clear();
                matches = null;
            }
            else if (!treeFocused && IsKeyPressed(KeyboardKey.KEY_G))
            {
                mode = Mode.gotoLine;
                query.clear();
            }
        }

        // Interactive scrollbar (hover-expand + thumb drag + track click),
        // adapted from apps/terminal's ScrollbarState. Runs every frame so the
        // width animates even while a search is being typed.
        {
            // Both widths scale with the font: the expanded (hover) handle equals
            // the reserved scrollbar gutter (1.5 cells) so it fills the gutter
            // without overlapping text; the idle rail is a thin ~⅓ cell.
            const float hoverW = cast(float) scrollbarGutter();
            const float idleW = cellW / 3.0f < 2.0f ? 2.0f : cellW / 3.0f;
            const float sbMaxW = hoverW;
            if (maxTop > 0)
            {
                const trackH = cast(float)(screenH - docY0);
                const g = thumbGeometry(total, docRows, top, maxTop,
                    screenH - docY0);
                const pos = GetMousePosition();
                const hoverTrack = pos.x >= screenW - sbMaxW;
                const hoverThumb = hoverTrack && pos.y >= docY0 + g.y
                    && pos.y <= docY0 + g.y + g.h;
                sb.isHovered = hoverTrack || sb.isDragging;
                sb.targetWidth = sb.isHovered ? hoverW : idleW;

                if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT) && hoverTrack)
                {
                    if (hoverThumb)
                    {
                        sb.isDragging = true;
                        sb.dragStartY = pos.y;
                        sb.dragStartOffset = top;
                    }
                    else // click on the track: center the viewport on the click
                        top = cast(long)((pos.y - docY0) / trackH * total) - docRows / 2;
                }
                if (sb.isDragging)
                {
                    if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
                        sb.isDragging = false;
                    else if (g.movable > 0)
                        top = sb.dragStartOffset
                            + cast(long)((pos.y - sb.dragStartY) * maxTop / g.movable);
                }
            }
            else
            {
                sb.isHovered = false;
                sb.targetWidth = idleW;
            }
            // Ease the width toward its target (matches the terminal's 15/s rate).
            sb.currentWidth += (sb.targetWidth - sb.currentWidth) * 15.0f * GetFrameTime();
        }

        // The tree pane's scrollbar — the SAME hover-expand behavior as the
        // document's (one affordance, two panes): animated width, faint track
        // on hover, draggable thumb, track click centers.
        tree.height = visibleRows - treeTopRows;
        const treePaneRows = tree.bodyRows;
        const treeMaxTop = cast(long) tree.rows.length - treePaneRows;
        if (treeVisible && treeMaxTop > 0 && treePaneRows > 0)
        {
            const float hoverW = cast(float) scrollbarGutter();
            const float idleW = cellW / 3.0f < 2.0f ? 2.0f : cellW / 3.0f;
            const trackTop = treeTopRows * cellH;
            const trackH = screenH - trackTop;
            const tg = thumbGeometry(tree.rows.length, treePaneRows, tree.top,
                treeMaxTop, trackH);
            const pos = GetMousePosition();
            const edge = treeCols * cellW;
            const hoverTrack = pos.x >= edge - hoverW && pos.x < edge
                && pos.y >= trackTop;
            const hoverThumb = hoverTrack && pos.y >= trackTop + tg.y
                && pos.y <= trackTop + tg.y + tg.h;
            treeSb.isHovered = hoverTrack || treeSb.isDragging;
            treeSb.targetWidth = treeSb.isHovered ? hoverW : idleW;

            if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT) && hoverTrack)
            {
                if (hoverThumb)
                {
                    treeSb.isDragging = true;
                    treeSb.dragStartY = pos.y;
                    treeSb.dragStartOffset = tree.top;
                }
                else // track click: center the pane on the click
                {
                    tree.top = cast(long)((pos.y - trackTop) / cast(float) trackH
                        * tree.rows.length) - treePaneRows / 2;
                    tree.scrollBy(0); // clamp
                }
            }
            if (treeSb.isDragging)
            {
                if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
                    treeSb.isDragging = false;
                else if (tg.movable > 0)
                {
                    tree.top = treeSb.dragStartOffset
                        + cast(long)((pos.y - treeSb.dragStartY) * treeMaxTop
                            / tg.movable);
                    tree.scrollBy(0); // clamp
                }
            }
            treeSb.currentWidth += (treeSb.targetWidth - treeSb.currentWidth)
                * 15.0f * GetFrameTime();
        }
        else
        {
            treeSb.isHovered = false;
            treeSb.isDragging = false;
        }

        top = top < 0 ? 0 : (top > maxTop ? maxTop : top);
        const topLine = cast(size_t) top;

        BeginDrawing();
        // GL scissor state is global; a scissor leaked from any earlier path
        // (or left over across the buffer swap) would CLIP the clear below —
        // exactly the "documents ghost over each other" failure. Start every
        // frame from a clean state so the clear always covers the window.
        EndScissorMode();
        if (flashDebug)
            ClearBackground((frame / 30) % 2 == 0
                ? Color(70, 20, 20, 255) : Color(20, 20, 70, 255));
        else
        {
            ClearBackground(rl(pageBg));
            // Panes own their background: an explicit fill over the document
            // region every frame, so its pixels never depend on the clear
            // alone (the tree pane and header fill their own rects).
            DrawRectangle(treePx(), 0, screenW - treePx(), screenH, rl(pageBg));
        }

        // One-cell background padding on the left, the scrollbar gutter on the
        // right, plus the optional line-number gutter; text starts at `contentX`.
        const padX = cellW;
        const rightPad = scrollbarGutter();
        const gcols = gutterCols();
        // Text starts after the tree pane (when visible), the 1-cell left
        // padding, and the line-number gutter.
        const gutterPx = treePx() + padX + gcols * cellW;

        if (mdActive)
        {
            // The widget path: paint the tree's precomputed ops through the
            // raylib canvas, offset by the scroll position and culled to the
            // viewport rows (raylib clips px; the cull skips dead draw calls).
            auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                gutterPx, cast(float)(docY0 - top * cellH));
            // The pane's base clip: content (an unwrappable code line inside
            // a fence, a wide table) never bleeds past the pane or under the
            // header — the same rule the tree pane follows.
            canvas.pushClip(Rect(0, cast(int) top,
                (screenW - rightPad - gutterPx) / cellW, docRows));
            foreach (ref op; mdOps)
            {
                const oy = op.rect.y;
                if (op.kind != OpKind.pushClip && op.kind != OpKind.popClip
                    && (oy + op.rect.height <= top || oy > top + docRows))
                    continue;
                paint(canvas, (&op)[0 .. 1]);
            }
            canvas.popClip();

            // Source line numbers in the gutter — from the row's source range
            // (first visual row of each source line only).
            if (gcols > 0)
            {
                size_t prevLine = size_t.max;
                foreach (row; 0 .. docRows)
                {
                    const vi = topLine + row;
                    if (vi >= mdRows.length)
                        break;
                    if (mdRows[vi].srcStart == size_t.max)
                        continue;
                    const ln = srcLineOf(lineStarts, mdRows[vi].srcStart);
                    if (ln == prevLine)
                        continue;
                    prevLine = ln;
                    const s = cstrOf(buf, uintToBuf(ln + 1));
                    drawText(fonts, s,
                        gutterPx - (s.length + 1) * cast(float) cellW,
                        docY0 + row * cast(float) cellH, TextStyle(0), rl(gutterFg));
                }
            }
        }
        else
            // The raw view under the same pane clip (long lines don't wrap).
            BeginScissorMode(treePx(), docY0,
                screenW - rightPad - treePx(), screenH - docY0);
            drawPreview(fonts, plines, topLine, docRows, cellW, cellH,
                pageFg, pageBg, gutterFg, quoteBars, padX, rightPad, gcols, buf,
                treePx(), docY0);
            EndScissorMode();

        copiedFlash = copiedFlash.stepped(frameMs(), copiedCfg);
        // The ✔ glyph lives in the widget tree: rebuild when the flash ends so
        // the header reverts to the copy affordance.
        if (copiedShown && !copiedFlash.visible)
        {
            copiedShown = false;
            copiedFenceSrc = size_t.max;
            if (mdActive)
                rebuildMd();
        }

        bool copyClicked; // a click landing on a copy button is not a selection

        // The fence copy affordance: the header band is the hit target (its
        // source-anchored id resolves the fence body); a click copies and the
        // ✔ glyph — part of the widget tree — holds for the flash duration.
        if (mdActive)
        {
            const mp = GetMousePosition();
            const dp = Point(cast(int)((mp.x - gutterPx) / cellW),
                cast(int)(top + cast(long)((mp.y - docY0) / cellH)));
            if (mp.x >= gutterPx && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
                foreach_reverse (ref const tgt; mdTargets)
                {
                    if (tgt.hitId >= foldHitBase && tgt.rect.contains(dp))
                    {
                        mdFolds = mdFolds.toggled(tgt.hitId - foldHitBase);
                        rebuildMd();
                        copyClicked = true; // not a selection either
                        break;
                    }
                    if (tgt.hitId >= fenceHitBase && tgt.rect.contains(dp))
                    {
                        const bodyStart = tgt.hitId - fenceHitBase;
                        foreach (ref const f; mdFences)
                            if (f.body.start == bodyStart
                                && f.body.end <= source.length)
                            {
                                auto fbody = source[f.body.start .. f.body.end];
                                // Match the selection copy mode (SEL7).
                                const txt = (ansiStrip && f.isAnsi)
                                    ? stripSgr(fbody) : fbody;
                                SetClipboardText(txt.toStringz);
                                copiedFenceSrc = bodyStart;
                                copiedFlash = Timeline.triggered(copiedCfg);
                                copiedShown = true;
                                copyClicked = true;
                                rebuildMd(); // the header now shows the ✔
                                break;
                            }
                        break;
                    }
                }
        }

        // Mouse selection (both views). `hitAt` classifies the cursor: over a
        // table → a grid cell (`TBL`); else a source byte span (`SEL`) — a
        // char point for prose/code (through the identity channel on the
        // widget path), or a decoration row's whole source span.
        struct Hit { bool ok, table; long lo, hi; int tableIdx; GridHit cell; }
        Hit hitAt(float mx, float my)
        {
            Hit h;
            if (my < 0)
                return h;
            if (mdActive)
            {
                const cx = cast(int)((mx - gutterPx) / cellW);
                const cy = top + cast(long)((my - docY0) / cellH);
                if (mx < gutterPx || cy < 0 || cy >= cast(long) mdRows.length)
                    return h;
                const p = Point(cx, cast(int) cy);
                const off = sourceOffsetAt(mdTree, mdFrames, p);
                // Inside a keyed table cell: a grid hit (2-D regime anchor),
                // with the char offset relative to the cell's source span.
                foreach (ref const kr; mdCells)
                    if (kr.rect.contains(p))
                    {
                        const cellStart = kr.key - tableKeyBase;
                        foreach (mi, ref const mc; mdCellList)
                            if (mc.span.start == cellStart)
                            {
                                h.table = true;
                                h.tableIdx = mc.table;
                                h.cell = GridHit(mc.row, mc.col,
                                    off >= cast(long) cellStart
                                        ? cast(size_t)(off - cellStart) : 0);
                                h.lo = h.hi = off >= 0 ? off : cast(long) cellStart;
                                h.ok = true;
                                return h;
                            }
                        break;
                    }
                if (off >= 0) // char-precise content
                {
                    h.ok = true;
                    h.lo = h.hi = off;
                    return h;
                }
                // Decoration under the cursor (band/border/pre-styled ANSI):
                // fall back to the row's whole source span (block-granular).
                if (mdRows[cast(size_t) cy].srcStart != size_t.max)
                {
                    h.ok = true;
                    h.lo = cast(long) mdRows[cast(size_t) cy].srcStart;
                    h.hi = cast(long) mdRows[cast(size_t) cy].srcEnd;
                }
                return h;
            }
            const row = cast(int)((my - docY0) / cellH);
            if (row < 0 || topLine + row >= plines.length || mx < gutterPx)
                return h; // left of the content (tree/scrollbar) hits nothing
            const pl = plines[topLine + row];
            const rx = gutterPx + runStartCells(pl) * cellW;
            const x = mx <= rx ? 0 : cast(int)((mx - rx) / cellW);
            const o = srcOffsetAtCol(pl, x);
            if (o >= 0)
            {
                h.ok = true;
                h.lo = o;
                h.hi = o;
            }
            return h;
        }

        {
            const mp = GetMousePosition();
            const overSb = mp.x >= screenW - scrollbarGutter();
            const overTree = treeVisible && mp.x < treeCols * cellW;
            if (overTree && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
            {
                treeFocused = true;
                const row = tree.top
                    + cast(long)((mp.y - treeTopRows * cellH) / cellH);
                if (row >= 0 && row < cast(long) tree.rows.length)
                {
                    const again = row == tree.sel;
                    tree.sel = row;
                    tree.clamp();
                    if (again)
                        activateTree();
                }
            }
            else if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT)
                && !overSb && !overTree)
                treeFocused = false;
            const shiftMod = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT) || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
            const altMod = IsKeyDown(KeyboardKey.KEY_LEFT_ALT) || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT);
            if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT) && !overSb
                && !overTree && !copyClicked && !treeSb.isDragging && !sb.isDragging)
            {
                const h = hitAt(mp.x, mp.y);
                selecting = h.ok;
                if (h.table)
                {
                    regime = Regime.table;
                    selTable = h.tableIdx;
                    tblAnchor = tblHead = h.cell;
                    tblShift = tblAlt = false;
                }
                else if (h.ok)
                {
                    regime = Regime.text;
                    anchorLo = headLo = h.lo;
                    anchorHi = headHi = h.hi;
                }
                else
                    regime = Regime.none;
            }
            if (selecting && IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT))
            {
                const h = hitAt(mp.x, mp.y);
                if (regime == Regime.table && h.table && h.tableIdx == selTable)
                {
                    tblHead = h.cell;
                    tblShift = shiftMod;
                    tblAlt = altMod;
                }
                else if (regime == Regime.text && h.ok)
                {
                    // Extend over anything with a source span — including a table
                    // line's block span, so a drag from outside sweeps across it.
                    headLo = h.lo;
                    headHi = h.hi;
                }
            }
            if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
                selecting = false;
        }

        // Selection highlight — a translucent tint. `tintRow` takes content columns
        // (0 = the content origin, i.e. after `gutterPx`).
        void tintRow(long screenRow, int xStartCol, int xEndCol)
        {
            if (screenRow < 0 || screenRow >= docRows || xEndCol <= xStartCol)
                return;
            DrawRectangle(gutterPx + xStartCol * cellW,
                cast(int)(docY0 + screenRow * cellH),
                (xEndCol - xStartCol) * cellW, cellH, alpha(quoteBars[1], 80));
        }
        // Tint a source byte range on the widget path: the toolkit derives the
        // char-precise rects (document cell coordinates) once for any backend.
        void tintSrcRange(long lo, long hi)
        {
            if (hi <= lo)
                return;
            foreach (r; selectionRects(mdTree, mdFrames,
                cast(size_t) lo, cast(size_t) hi))
                tintRow(r.y - top, r.x, r.x + r.width);
        }
        if (regime == Regime.text && selMax() > selMin())
        {
            const smin = selMin(), smax = selMax();
            if (mdActive)
                // One pass covers prose, code and table cells alike — every
                // span with source identity inside [smin, smax) tints.
                tintSrcRange(smin, smax);
            else
                foreach (row; 0 .. docRows)
                {
                    const vi = topLine + row;
                    if (vi >= plines.length)
                        break;
                    const pl = plines[vi];
                    const startCol = runStartCells(pl);
                    int c;
                    foreach (r; pl.runs)
                    {
                        const rc = cast(int) columnWidth(r.text);
                        if (r.srcStart != size_t.max)
                        {
                            const rStart = cast(long) r.srcStart;
                            const rEnd = rStart + cast(long) r.text.length;
                            if (rEnd > smin && rStart < smax)
                            {
                                const bStart = (smin > rStart ? smin : rStart) - rStart;
                                const bEnd = (smax < rEnd ? smax : rEnd) - rStart;
                                const colStart = cast(int) columnWidth(r.text[0 .. bStart]);
                                const colEnd = cast(int) columnWidth(r.text[0 .. bEnd]);
                                tintRow(row, startCol + c + colStart, startCol + c + colEnd);
                            }
                        }
                        c += rc;
                    }
                }
        }
        else if (mdActive && regime == Regime.table && selTable >= 0)
        {
            const dims = tableDims(mdCellList, selTable);
            const reg = tableSelection(tblAnchor, tblHead, tblShift, tblAlt,
                dims.rows, dims.cols);
            foreach (ref const mc; mdCellList)
            {
                if (mc.table != selTable)
                    continue;
                if (reg.subCell)
                {
                    if (mc.row == reg.row && mc.col == reg.col)
                        tintSrcRange(cast(long)(mc.span.start + reg.charLo),
                            cast(long)(mc.span.start + reg.charHi));
                }
                else if (mc.row >= reg.rowLo && mc.row <= reg.rowHi
                    && mc.col >= reg.colLo && mc.col <= reg.colHi)
                    tintSrcRange(cast(long) mc.span.start, cast(long) mc.span.end);
            }
        }

        // Search-match overlay (raw view only): translucent tint over each visible
        // match, remapped onto the wrapped visual line via each line's srcLine +
        // wrapColOffset (the current match brighter).
        if (!showPreview)
            foreach (i, m; matches)
                foreach (row; 0 .. docRows)
                {
                    const vi = topLine + row;
                    if (vi >= plines.length)
                        break;
                    const pl = plines[vi];
                    const off = pl.wrapColOffset;
                    const rowCols = lineCols(pl);
                    if (pl.srcLine != m.line || cast(long) m.col < off
                        || cast(long) m.col >= off + rowCols)
                        continue;
                    const vc = cast(int) m.col - off;
                    const remain = off + rowCols - cast(int) m.col;
                    const cols = cast(int) m.cols < remain ? cast(int) m.cols : remain;
                    DrawRectangle(gutterPx + vc * cellW,
                        cast(int)(docY0 + row * cellH),
                        cols * cellW, cellH, i == curMatch ? currentMatchTint : matchTint);
                    break; // the match starts on this visual row
                }

        // Twoslash hover: pointer → byte (the identity channel) → hover node;
        // the token's dotted underline fades in and the popup (the shared
        // viewHoverPopup chrome via drawPopup) draws on top, with pointer
        // hysteresis so moving down into the open popup keeps it open.
        if (mdActive && curTw.code.length && tsCache !is null)
        {
            const mp = GetMousePosition();
            size_t overNode = 0;
            if (mp.x >= gutterPx)
            {
                const off = sourceOffsetAt(mdTree, mdFrames,
                    Point(cast(int)((mp.x - gutterPx) / cellW),
                        cast(int)(top + cast(long)((mp.y - docY0) / cellH))));
                if (off >= 0)
                    foreach (ni, ref const n; curTw.nodes)
                        if (n.type == NodeType.hover && off >= cast(long) n.start
                            && off < cast(long)(n.start + n.length))
                            overNode = ni + 1;
            }
            if (overNode == 0 && hotNode != 0 && havePopup
                && mp.x >= hotPopup.x && mp.x <= hotPopup.x + hotPopup.width
                && mp.y >= hotPopup.y && mp.y <= hotPopup.y + hotPopup.height)
                overNode = hotNode; // still over the open popup → keep it open
            bool forced = false;
            if (forceHover >= 0)
            {
                int seen = 0;
                foreach (ni, ref const n; curTw.nodes)
                    if (n.type == NodeType.hover && seen++ == forceHover)
                    {
                        overNode = ni + 1;
                        forced = true;
                        break;
                    }
            }
            if (overNode != hotNode)
                fade = Timeline.init;
            hotNode = overNode;
            if (hotNode != 0)
            {
                if (!fade.visible)
                    fade = Timeline.triggered(fadeCfg);
                fade = forced ? Timeline(Timeline.Phase.hold, 0)
                    : fade.stepped(frameMs(), fadeCfg);
            }
            havePopup = false;
            if (hotNode != 0)
            {
                // The token's geometry through the identity channel.
                const n = curTw.nodes[hotNode - 1];
                auto rects = selectionRects(mdTree, mdFrames,
                    n.start, n.start + n.length);
                if (rects.length)
                {
                    const r = rects[0];
                    const hx = gutterPx + r.x * cellW;
                    const hy = cast(int)(docY0 + (r.y - top) * cellH);
                    const hw = r.width * cellW;
                    const uy = hy + cellH - 2;
                    const uc = Color(pageFg.r, pageFg.g, pageFg.b,
                        cast(ubyte)(fade.alphaPercent(fadeCfg) * 255 / 100));
                    for (int i = 0; i + 2 <= hw; i += 4)
                        DrawRectangle(hx + i, uy, 2, 1, uc);
                    hotPopup = drawPopup(fonts, buf, curTw, hotNode - 1,
                        cast(float) hx, cast(float)(hy + cellH),
                        cellW, cellH, current, *tsCache,
                        defaultTwoslashPalette(schemeForBackground(pageBg)),
                        pageFg, pageBg);
                    havePopup = true;
                }
            }
        }

        // The explorer pane (XPL2): the tree's widget view painted through
        // RaylibCanvas at the window's left edge, viewport-sliced, with a
        // hairline divider. The whole pane clips at its own width.
        if (treeVisible)
        {
            tree.height = visibleRows - treeTopRows;
            tree.scrollBy(0); // bounds only — never yank the view to the cursor
            DrawRectangle(0, 0, treeCols * cellW, screenH,
                rl(mix(pageBg, pageFg, 0.03)));
            DrawRectangle(treeCols * cellW + cellW / 2, 0, 1, screenH,
                rl(gutterFg));

            import sparkles.ui.geometry : SizeSpec;
            import sparkles.ui.widget : Builder, Widget, WidgetKind;

            auto tb = Builder();
            const tFirst = cast(size_t) tree.top;
            const tLast = tFirst + visibleRows > tree.rows.length
                ? tree.rows.length : tFirst + visibleRows;
            const selNode = tree.sel < cast(long) tree.rows.length
                ? tree.rows[cast(size_t) tree.sel].node : uint.max;
            const tv = treeView(tb, tree.data, tree.rows[tFirst .. tLast],
                (uint i) @safe => tree.open.isOpen(tree.data.nodes[i].value.path),
                selNode, explorerGlyphs, tree.selBg, hasSelectionBg: true);
            Widget paneW = Widget(kind: WidgetKind.column, children: [tv],
                width: SizeSpec.fixed(treeCols), clipX: true);
            auto wt = tb.finish(tb.add(paneW));
            auto tOps = buildDisplayList(wt, layout(wt),
                themes[themeIdx].effectivePalette, pageFg, pageBg);
            auto tCanvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                0, cast(float)(treeTopRows * cellH));
            paint(tCanvas, tOps);

            // The pane's scrollbar: the same animated-width thumb + hover
            // track as the document's, in the pane's theme tint.
            if (treeMaxTop > 0 && treePaneRows > 0)
            {
                const trackTop = treeTopRows * cellH;
                const trackH = screenH - trackTop;
                const tg = thumbGeometry(tree.rows.length, treePaneRows,
                    tree.top, treeMaxTop, trackH);
                const w = treeSb.currentWidth;
                const x = treeCols * cellW - w;
                if (treeSb.isHovered || treeSb.isDragging)
                    DrawRectangle(cast(int) x, trackTop, cast(int) w,
                        trackH, rl(tree.sbTrack));
                DrawRectangle(cast(int) x, cast(int)(trackTop + tg.y),
                    cast(int) w, cast(int) tg.h, rl(tree.sbThumb));
            }
        }

        // Scrollbar: an animated-width thumb, plus a faint track while hovered
        // or dragging. Colors follow the theme's muted gutter tone.
        if (maxTop > 0)
        {
            const g = thumbGeometry(total, docRows, top, maxTop, screenH - docY0);
            const w = sb.currentWidth;
            const x = screenW - w;
            // Distinct link-tinted chrome (the gutter behind it is empty page bg):
            // a subtle full-height track on hover, a brighter thumb on top.
            if (sb.isHovered || sb.isDragging)
                DrawRectangle(cast(int) x, docY0, cast(int) w, screenH - docY0,
                    rl(scrollbarTrack));
            DrawRectangle(cast(int) x, cast(int)(docY0 + g.y), cast(int) w,
                cast(int) g.h, rl(scrollbarThumb));
        }

        // A header bar when navigating a document set (`GNV2`): the entry name and
        // summary on the left, the set position + keys on the right. Drawn over the
        // top row so scrolled content passes under it.
        if (set !is null && !set.empty && loadDoc !is null)
        {
            DrawRectangle(0, 0, screenW, cellH, rl(mix(pageBg, pageFg, 0.12)));
            DrawRectangle(0, cellH - 1, screenW, 1, rl(gutterFg));
            const left = curSummary.length ? curName ~ "  " ~ curSummary : curName;
            drawText(fonts, cstrOf(buf, left), cast(float) cellW, 0, TextStyle(0), rl(pageFg));
            const pos = text(set.index + 1, "/", set.length, "   [ ] prev/next   i index");
            const px = cast(float)(screenW - cast(int)((pos.length + 1) * cellW));
            drawText(fonts, cstrOf(buf, pos), px, 0, TextStyle(0), rl(gutterFg));
        }

        // Input line at the bottom: '/query' while searching, ':n' while going
        // to a line. Shows a match count for searches.
        if (inputMode)
        {
            const barY = screenH - cellH;
            DrawRectangle(0, barY, screenW, cellH, rl(gutterFg));
            auto lineText = mode == Mode.search
                ? text("/", query[], "   ", matches.length, " matches")
                : text(":", query[]);
            drawText(fonts, cstrOf(buf, lineText), 4, cast(float) barY, TextStyle(0), rl(pageBg));
        }
        // Copy-mode toast (when not typing): flashes the mode after a 'y'/'t' toggle.
        else if (toast.visible)
        {
            toast = toast.stepped(frameMs(), toastCfg);
            const barY = screenH - cellH;
            DrawRectangle(0, barY, screenW, cellH, rl(gutterFg));
            drawText(fonts, cstrOf(buf, copyModeMsg), 4, cast(float) barY, TextStyle(0), rl(pageBg));
        }

        EndScissorMode(); // never let a scissor survive the frame
        EndDrawing();

        // On-demand atlas growth: drawText requests any covered-but-unrasterized
        // codepoints (emoji, CJK, higher-plane icons) as it draws; grow the atlas
        // after EndDrawing so the reupload never lands mid-frame.
        fonts.flushPending();

        ++frame;
        if (shotPath.length)
        {
            // Warm up for a number of frames before capturing: the glyph atlas
            // uploads over the first frames, and under a headless GL context the
            // framebuffer swap lags the draw, so an early TakeScreenshot grabs a
            // black frame. ~20 frames is reliably past both.
            if (frame == shotFrame)
                TakeScreenshot(shotPath.toStringz);
            if (frame >= shotFrame + 1)
                break;
        }
    }

    return 0;
}

/// Paint the markdown preview: `plines` index-culled to the viewport. Each line
/// draws its full-width band, then `quoteDepth` gutter bars, its muted `leader`
/// (bullet/marker), and its styled runs (per-run background + `drawText`). The
/// gutter/scrollbar/search of the raw view are intentionally absent (glow-like).
private void drawPreview(
    ref FontSet fonts,
    const(PreviewLine)[] plines,
    size_t topLine,
    int visibleRows,
    int cellW,
    int cellH,
    RgbColor pageFg,
    RgbColor pageBg,
    RgbColor gutterFg,
    const RgbColor[quoteBarCycle] quoteBars,
    int padX,
    int rightPad,
    int gutterCols,
    ref SmallBuffer!(char, 4096) buf,
    int paneX = 0,
    int y0 = 0,
) @system
{
    const screenW = GetScreenWidth();
    // Content starts after the workspace's tree pane (`paneX`), the 1-cell
    // left padding, and the line-number gutter; bands span from there to the
    // scrollbar gutter on the right.
    const originX = paneX + padX + gutterCols * cellW;
    const bandW = (screenW - rightPad) - originX;
    foreach (row; 0 .. visibleRows)
    {
        const li = topLine + row;
        if (li >= plines.length)
            break;
        const pl = plines[li];
        const y = y0 + row * cast(float) cellH;

        // Band behind the line (code panel / header / table / heading), inset to
        // the padded content column so the padding stays page-background.
        if (pl.band != BandKind.none && pl.band != BandKind.rule)
            DrawRectangle(originX, cast(int) y, bandW, cellH, rl(pl.bandBg));

        // Source (physical) line number in the gutter, right-aligned — only on the
        // first visual row of a wrapped physical line.
        if (gutterCols > 0 && pl.showNumber)
        {
            const s = cstrOf(buf, uintToBuf(pl.srcLine + 1));
            drawText(fonts, s, originX - (s.length + 1) * cast(float) cellW, y,
                TextStyle(0), rl(gutterFg));
        }

        // Quote gutter: one `│` bar per depth (2 cols each). A callout paints
        // every bar in its accent (`barFg`); otherwise each depth takes its color
        // from the theme-derived cycle.
        foreach (d; 0 .. pl.quoteDepth)
        {
            const barColor = pl.hasBarFg ? pl.barFg : quoteBars[d % quoteBarCycle];
            drawText(fonts, cstrOf(buf, "│"), originX + d * 2 * cast(float) cellW, y,
                TextStyle(0), rl(barColor));
        }

        const contentCol = pl.quoteDepth * 2 + pl.indentCols;
        float x = originX + contentCol * cast(float) cellW;

        // Leader (bullet / number / checkbox / heading marker) — colored when the
        // layouter gave it an accent (heading icon, checked box, callout icon).
        if (pl.leader.length)
        {
            const lfg = pl.hasLeaderFg ? pl.leaderFg : gutterFg;
            drawText(fonts, cstrOf(buf, pl.leader), x, y, TextStyle(0), rl(lfg));
            x += columnWidth(pl.leader) * cellW;
        }

        // Styled runs.
        foreach (r; pl.runs)
        {
            if (r.text.length == 0)
                continue;
            const wpx = cast(int)(columnWidth(r.text) * cellW);
            if (r.hasBg)
                DrawRectangle(cast(int) x, cast(int) y, wpx, cellH, rl(r.bg));
            drawText(fonts, cstrOf(buf, r.text), x, y, mapAttrs(r.attrs), rl(r.fg));
            x += wpx;
        }
    }
}

/// The source (physical) line containing byte `off` — a binary search over the
/// line-start offsets (the preview gutter's row → line number mapping).
private size_t srcLineOf(scope const size_t[] lineStarts, size_t off)
    @safe pure nothrow @nogc
{
    size_t lo = 0, hi = lineStarts.length;
    while (lo + 1 < hi)
    {
        const mid = (lo + hi) / 2;
        if (lineStarts[mid] <= off)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

/// Maps `gui_ansi.Attr` bits onto the toolkit's per-span text chrome — the
/// decoded-ANSI fence renderer stamps these on its resolved-color spans.
private UiTextStyle attrsToTextStyle(ubyte attrs) pure nothrow @nogc @safe
{
    import sparkles.base.term_style : UStyle = UnderlineStyle;

    UiTextStyle t;
    t.bold = (attrs & Attr.bold) != 0;
    t.italic = (attrs & Attr.italic) != 0;
    t.strikethrough = (attrs & Attr.strikethrough) != 0;
    if (attrs & Attr.underline)
        t.underline = UStyle.single;
    return t;
}

/// Maps `gui_ansi.Attr` bits (used by the preview model) onto raylib-text's
/// `TextStyle` — the preview counterpart of `mapStyle`.
private TextStyle mapAttrs(ubyte attrs) pure nothrow @nogc @safe
{
    TextStyle t;
    if (attrs & Attr.bold)
        t.bits |= TextStyle.bold;
    if (attrs & Attr.italic)
        t.bits |= TextStyle.italic;
    if (attrs & Attr.underline)
        t.bits |= TextStyle.underline;
    if (attrs & Attr.strikethrough)
        t.bits |= TextStyle.strikethrough;
    return t;
}

/// Animated, draggable scrollbar state (mirrors apps/terminal's ScrollbarState):
/// `currentWidth` eases toward `targetWidth` (4 idle → 12 on hover/drag); a drag
/// records the grab point so the thumb tracks the cursor.
private struct Scrollbar
{
    float currentWidth = 4.0f;
    float targetWidth = 4.0f;
    bool isHovered;
    bool isDragging;
    float dragStartY = 0.0f;
    long dragStartOffset = 0;
}

/// The scrollbar thumb's vertical geometry for the current viewport.
private struct ThumbGeometry
{
    float y;       /// thumb top (px)
    float h;       /// thumb height (px, min 24)
    float movable; /// track travel available to the thumb (px)
}

/// ditto — the one STM2 formula (the TUI renders the same geometry), with the
/// GUI's 24 px grabbable minimum; the float fields only carry the animation.
private ThumbGeometry thumbGeometry(size_t total, int visibleRows, long top,
    long maxTop, int screenH) pure nothrow @nogc @safe
{
    const g = scrollbarThumb(total, visibleRows, top, screenH, minExtent: 24);
    return ThumbGeometry(g.start, g.extent, screenH - g.extent);
}

/// An RGB triple as a raylib color with an explicit alpha (for overlays).
private Color alpha(RgbColor c, ubyte a) pure nothrow @nogc @trusted
    => Color(c.r, c.g, c.b, a);

/// Draws styled text `text` (highlighted into `ev`) run-by-run starting at
/// `(x, y)`; returns the ending pen x. Used for popup / query type signatures.
private float drawStyledRuns(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    scope const(char)[] text, const(HighlightEvent)[] ev, float x, float y,
    in ResolvedTheme theme, RgbColor fallbackFg) @system
{
    const cellW = fonts.cellW();
    float cx = x;
    foreach (sp; byStyledSpan(ev))
    {
        const run = text[sp.start .. sp.end];
        if (run.length == 0)
            continue;
        const spec = theme[sp.label];
        drawText(fonts, cstrOf(buf, run), cx, y, mapStyle(spec), rl(toRgb(spec.fg, fallbackFg)));
        cx += columnWidth(run) * cellW;
    }
    return cx;
}

/// The floating hover popup: a bordered box with the re-highlighted type
/// signature and (if present) the docs, anchored at `(x, y)`.
/// The floating hover popup, built from the shared `viewHoverPopup` widget view
/// (surface panel + docs + `@param` chips — the same chrome as the TUI/HTML) and
/// painted through `RaylibCanvas`. The type signature (row 0) is a single
/// `Slot.code` run in the widget model, so it is overpainted with the per-token
/// re-highlighted signature — the one thing the widget model leaves to the painter.
private Rectangle drawPopup(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    in TwoslashReturn tw, size_t nodeIndex, float x, float y, int cellW, int cellH,
    in ResolvedTheme theme, ref TsConfigCache cache, in Palette pal,
    RgbColor pageFg, RgbColor pageBg) @system
{
    // Render JSDoc docs as markdown (bold/italic/code/links/lists/fences), via the
    // grammar registry — falls back to plain lines without it.
    auto tree = viewHoverPopup(tw, nodeIndex, cache.registry);
    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);

    auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH, x, y);
    paint(canvas, ops);

    // Overpaint the signature row with the re-highlighted signature (same text
    // and cell position the widget reserved), clearing its `Slot.code` glyphs
    // back to the surface first so nothing double-strikes.
    const sigText = withoutQuickinfoPrefix(tw.nodes[nodeIndex].text);
    const surf = resolveSlot(pal, Slot.surface, pageFg, pageBg);
    foreach (ref op; ops)
        if (op.kind == OpKind.textRun)
        {
            const sx = x + op.rect.x * cellW;
            const sy = y + op.rect.y * cellH;
            DrawRectangle(cast(int) sx, cast(int) sy, op.rect.width * cellW, cellH, rlBg(surf));
            SmallBuffer!HighlightEvent sig;
            highlightSignature(cache, sigText, sig);
            drawStyledRuns(fonts, buf, sigText, sig[], sx, sy, theme, pageFg);
            break;
        }

    // The popup's on-screen rect (px), for the caller's pointer hysteresis.
    const box = frames[tree.root].rect;
    return Rectangle(x, y, cast(float)(box.width * cellW), cast(float)(box.height * cellH));
}


/// The widest entry name in cells — the index view's summary column offset.
private size_t maxNameCols(scope const SourceEntry[] entries) @safe pure nothrow
{
    size_t w;
    foreach (ref const e; entries)
        if (e.name.length > w)
            w = e.name.length;
    return w;
}

/// `IsKeyPressed` plus auto-repeat while held, so PageDown/j/k etc. repeat.
private bool pressed(int key) @system
    => IsKeyPressed(key) || IsKeyPressedRepeat(key);

// Transient-effect configs (STM6): the copy-✔ flash, the copy-mode toast, and
// the hover-underline fade — one Timeline machine, three configurations. The
// TUI runs the same machine with `holdUntilDismissed` (no frame clock).
private enum copiedCfg = Timeline.Config(holdMs: 1200);
private enum toastCfg = Timeline.Config(holdMs: 1600);
private enum fadeCfg = Timeline.Config(fadeInMs: 300, holdUntilDismissed: true);

/// This frame's duration in Timeline milliseconds.
private int frameMs() @system => cast(int)(GetFrameTime() * 1000);

/// Decimal digit count (at least 1, for 0).
private int digitCount(size_t n) pure nothrow @nogc @safe
{
    int d = 1;
    while (n >= 10)
    {
        n /= 10;
        ++d;
    }
    return d;
}

/// Formats `v` into a thread-local buffer as decimal digits (no allocation).
private char[] uintToBuf(size_t v) @safe nothrow
{
    static char[20] buf;
    if (v == 0)
    {
        buf[0] = '0';
        return buf[0 .. 1];
    }
    size_t i = buf.length;
    while (v)
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return buf[i .. $];
}

/// Copies `s` into `buf` with a trailing NUL, returning the NUL-terminated
/// slice (excluding the NUL) that raylib's `DrawTextEx` can read directly.
private const(char)[] cstrOf(ref SmallBuffer!(char, 4096) buf, scope const(char)[] s) @safe
{
    buf.clear();
    buf ~= s;
    buf ~= '\0';
    return buf[][0 .. $ - 1];
}

/// Translates sparkles:syntax's backend-neutral `TermStyle` attributes into the
/// renderer's `TextStyle`. On the shaped `TermStyle`, underline is a first-class
/// `UnderlineStyle` field (bit-3 of `attrs` is strikethrough). The terminal will
/// translate `GhosttyStyle` the same way onto the shared library type in M5.
TextStyle mapStyle(in StyleSpec spec) pure nothrow @nogc @safe
{
    TextStyle t;
    if (spec.attrs.has(TextAttr.bold))
        t.bits |= TextStyle.bold;
    if (spec.attrs.has(TextAttr.italic))
        t.bits |= TextStyle.italic;
    if (spec.attrs.has(TextAttr.strikethrough))
        t.bits |= TextStyle.strikethrough;
    if (spec.underline != UnderlineStyle.none)
        t.bits |= TextStyle.underline;
    return t;
}

/// Total display columns of a wrapped line's runs (for search-overlay remapping).
private int lineCols(in PreviewLine pl) @safe
{
    int c;
    foreach (r; pl.runs)
        c += cast(int) columnWidth(r.text);
    return c;
}

/// The byte index in `t` at display column `targetCol` (for column → file-offset).
private size_t byteAtColumn(const(char)[] t, int targetCol) @safe
{
    import std.utf : decode;
    size_t i;
    int c;
    while (i < t.length && c < targetCol)
    {
        const s = i;
        decode(t, i);
        c += cast(int) columnWidth(t[s .. i]);
    }
    return i;
}

/// The source-file offset at display column `col` within a line's runs — walking
/// only source-backed runs (decorations/gutters are skipped), so a click in a
/// gutter snaps to the adjacent content. -1 if the line has no selectable content.
private long srcOffsetAtCol(in PreviewLine pl, int col) @safe
{
    long lastEnd = -1;
    int c;
    foreach (r; pl.runs)
    {
        const rc = cast(int) columnWidth(r.text);
        if (r.srcStart != size_t.max)
        {
            if (col <= c)
                return cast(long) r.srcStart;
            if (col < c + rc)
                return cast(long) r.srcStart + cast(long) byteAtColumn(r.text, col - c);
            lastEnd = cast(long)(r.srcStart + r.text.length);
        }
        c += rc;
    }
    return lastEnd;
}

/// Columns from the content origin to where a line's runs begin (after the quote
/// gutter, indent, and leader), matching `drawPreview`'s layout.
private int runStartCells(in PreviewLine pl) @safe
    => pl.quoteDepth * 2 + pl.indentCols + cast(int) columnWidth(pl.leader);

/// An RGB triple as a raylib color (fully opaque).
Color rl(RgbColor c) pure nothrow @nogc @trusted => Color(c.r, c.g, c.b, 255);
