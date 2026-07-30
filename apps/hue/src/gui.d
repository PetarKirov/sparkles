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
import gui_text : columnWidth, Match;

// Markdown-preview model (raylib-free) and the ANSI-fence decoder.
import gui_preview : PreviewModel, stripSgr;
import gui_ansi : decodeAnsi;
import viewer_model : Dims, MdCell, MdFence, ViewerModel;

// The composable markdown view (M10): the preview is one widget tree; the

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
    ResolvedTheme, RgbColor, toRgb;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : mix;

import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;
import sparkles.twoslash.overlay : withoutQuickinfoPrefix;
import sparkles.twoslash.render_widgets : viewHoverPopup;

// The shared visual language: the twoslash palette is the single source for the
// error/warn/tag/highlight colors this backend used to hand-copy as literals, and
// the widget views drive the hover popup (so the GUI matches the TUI/HTML chrome).
import sparkles.ui.style : defaultTwoslashPalette, Palette,
    schemeForBackground, Slot;
import sparkles.ui.geometry : Constraints, Point, Rect;
import sparkles.ui.canvas : DrawOp, LineStyle, OpKind;
import sparkles.ui.layout : layout;
import sparkles.ui.state : scrollbarThumb, selectionRects, sourceOffsetAt,
    SplitState, Timeline;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_raylib : RaylibCanvas;

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
    string lang;             /// canonical language (CST fold provider)
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
    string docLang = null,               // canonical language (CST folds)
    string[] includeGlobs = null,        // explorer globs (XPF2)
    string[] excludeGlobs = null,        // ditto
    int treeWidth = 32,                  // explorer pane width in cells
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
    // everywhere but stale text rides on vm.top, the ghost is DRAWN each frame;
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

    // The viewer's Whole (PRN1 / the C1 diagnosis): one value owns the
    // document, its theme-resolved colors, the widget pipeline, folding,
    // scroll and search — everything the painters and interactions read.
    // The window, fonts, explorer pane and input translation stay here.
    ViewerModel vm;
    vm.names = names;
    vm.themes = themes;
    vm.labels = labels;
    vm.cache = tsCache;
    vm.decodeAnsi = (const(char)[] b) => decodeAnsi(b);
    vm.themeIdx = startIdx;

    // Resize debounce: during a drag the column count changes almost every frame,
    // so re-wrap only once the width has held steady for a few frames — the drag
    // pays one relayout when it settles instead of one per frame. Discrete width
    // changes (theme / font size / gutter toggles) relayout immediately, so this
    // branch only ever debounces a live window resize.
    int prevWidthCols = -1;
    int resizeSettle;
    enum resizeSettleFrames = 4; // ~66 ms at 60 FPS

    // Line-number gutter width in cells (0 when off) — a stable size from the
    // source line count so toggling wrapping never oscillates the layout.
    int gutterCols() => lineNumbers ? digitCount(vm.srcTotal) + 1 : 0;

    // The right gutter reserved for the scrollbar == its expanded (hover) width,
    // so the expanded handle fills the gutter exactly instead of overlapping text.
    int scrollbarGutter() => cast(int)(fonts.cellW() * 1.5f);

    // Preview columns available for the vm.current window/font: the screen minus the
    // 1-cell left text padding, the scrollbar gutter on the right, and the line-
    // number gutter. Re-laying-out on change keeps wrapping correct.
    // The explorer pane (XPL2): tree left, document right — the TUI
    // workspace's model, painted through RaylibCanvas. 'e' toggles it.
    import std.path : dirName;

    ExplorerTui tree;
    tree.includeGlobs = includeGlobs;
    tree.excludeGlobs = excludeGlobs;
    bool treeVisible = startInTree;
    bool treeFocused = startInTree;
    // The tree/document split (STM8): --tree-width seeds it; dragging the
    // divider resizes it live (cell-granular, like the TUI's).
    auto split = SplitState(treeWidth < 12 ? 12 : treeWidth);
    int treeCols() => split.size;
    int treePx() => treeVisible ? (treeCols + 1) * fonts.cellW() : 0;

    int widthCols()
    {
        const cw = fonts.cellW();
        const w = (GetScreenWidth() - cw - scrollbarGutter() - gutterCols() * cw
            - treePx()) / cw;
        return w < 8 ? 8 : w;
    }

    // Search / goto input state; the match set and its rects live in `vm`.
    Mode mode = Mode.normal;
    SmallBuffer!(char, 256) query;

    // Every view reflows on resize: the model lays the active widget tree
    // out to the new width (raw source rows wrap greedily; line numbers
    // derive from each row's source range).
    void relayout()
    {
        vm.relayout(widthCols());
    }

    void applyTheme(size_t i)
    {
        vm.widthCols = widthCols();
        vm.applyTheme(i);
        SetWindowTitle(text("hue — ", title, " — ", names[i],
            " (", i + 1, "/", names.length, ")").toStringz);
        // The explorer pane follows the theme too — page colors and the
        // palette its slots resolve against, not just the syntax colors.
        tree.theme = vm.current;
        tree.themeValue = &themes[i];
        tree.pageFg = vm.pageFg;
        tree.pageBg = vm.pageBg;
        if (tree.root.length)
            tree.rebuild();
    }

    tree.chromeRows = 0; // the GUI pane is all tree rows
    tree.root = treeRoot.length ? treeRoot
        : (docPath.length ? dirName(docPath) : ".");
    applyTheme(vm.themeIdx); // resolves the theme before the first document
    vm.setDocument(title, set !is null && !set.empty ? set.current.summary : "",
        source, events, preview, twoslash, docLang);
    // A markdown file opens in preview by default; Tab toggles to the raw
    // highlighted-source view. `HUE_GUI_PREVIEW=0/1` pins the initial mode
    // for deterministic golden captures.
    if (environment.get("HUE_GUI_PREVIEW", "") == "0" && vm.showPreview)
    {
        vm.showPreview = false;
        vm.rebuild();
    }
    vm.top = initialTop;
    if (docPath.length)
        tree.reveal(docPath);

    SmallBuffer!(char, 4096) buf; // reused, NUL-terminated for raylib

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

        vm.widthCols = widthCols();
        vm.setDocument(name, summary, doc.source, doc.events, doc.preview,
            doc.twoslash, doc.lang);
        query.clear();
        mode = Mode.normal;
        SetWindowTitle(("hue — " ~ name).toStringz);
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

    // Center the given match in the viewport (as far as clamping allows) —
    // unfolding any region that hides it first (`FLD6`).
    void jumpToMatch(size_t i, int visibleRows)
    {
        if (vm.matches.length == 0)
            return;
        vm.curMatch = i % vm.matches.length;
        vm.revealOffset(vm.matches[vm.curMatch].start);
        vm.top = vm.visualOfMatch(vm.matches[vm.curMatch]) - visibleRows / 2;
    }

    // Debug/CI: HUE_GUI_SEARCH=<text> preselects a search (highlights + jump to
    // the first match) so a golden capture exercises the match overlay.
    foreach (ch; environment.get("HUE_GUI_SEARCH", ""))
        query ~= ch;
    if (query.length)
    {
        vm.search(query[]);
        if (vm.matches.length)
            vm.top = vm.visualOfMatch(vm.matches[0]);
    }

    Scrollbar sb;
    Scrollbar treeSb; // the tree pane's — same behavior, its own state
    float wheelAccum = 0; // fractional wheel deltas accumulate to whole rows

    // Fullscreen (F11): a manual borderless toggle. raylib's
    // ToggleBorderlessWindowed forces the primary monitor and, on some
    // compositors, drops the window decorations on the way back. Managing the
    // undecorated flag + geometry ourselves restores decorations reliably and
    // keeps the window on its vm.current monitor (on X11; on Wayland the app can't
    // set its own position, so it stays put — never yanked to the primary).
    bool isFullscreen;
    int savedX, savedY, savedW, savedH;

    // Code-block copy button: the STM6 timeline for the brief "copied"
    // checkmark feedback (the copied fence itself is `vm.copiedFenceSrc`).
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

    // Copy the vm.current selection: a text range → `source[min..max]` (SGR-stripped
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
            const dims = vm.tableDims(selTable);
            const reg = tableSelection(tblAnchor, tblHead, tblShift, tblAlt,
                dims.rows, dims.cols);
            const(char)[] cellText(size_t r, size_t c)
            {
                foreach (ref const mc; vm.cellList)
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
    // visible row) — the model owns the region choice and the rebuild.
    void foldAtCursor(ViewerModel.FoldOp op)
    {
        long off = -1;
        if (regime == Regime.text && selMax() > selMin())
            off = selMin();
        else if (vm.rows.length)
        {
            const t0 = cast(size_t)(vm.top >= 0
                && vm.top < cast(long) vm.rows.length ? vm.top : 0);
            if (vm.rows[t0].srcStart != size_t.max)
                off = cast(long) vm.rows[t0].srcStart;
        }
        vm.foldAt(off, op);
    }

    // The vim fold family: 'z' arms a pending sequence for ~a second; the
    // next key picks the op (a/z toggle, c close, o open, R all-open,
    // M all-fold).
    int foldSeqFrames;

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
        if (wc != vm.widthCols)
        {
            resizeSettle = (wc == prevWidthCols) ? resizeSettle + 1 : 0;
            if (resizeSettle >= resizeSettleFrames)
                relayout();
        }
        prevWidthCols = wc;
        // The one visual-line space (scroll/selection/search): the active
        // widget tree's rows, whichever view kind built it.
        const total = vm.rows.length;
        const maxTop = total > docRows ? cast(long)(total - docRows) : 0;

        // F11 toggles borderless fullscreen on the window's vm.current monitor;
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
        if (treeFocused && tree.searching)
        {
            // The tree pane's live filter (broot mode): typed chars narrow
            // per keystroke; Enter keeps the filtered tree, Esc clears it.
            for (int c = GetCharPressed(); c > 0; c = GetCharPressed())
                if (c != '/')
                    tree.filterInput(cast(dchar) c);
            if (IsKeyPressed(KeyboardKey.KEY_BACKSPACE))
                tree.filterBackspace();
            if (IsKeyPressed(KeyboardKey.KEY_ENTER))
                tree.filterAccept();
            if (IsKeyPressed(KeyboardKey.KEY_ESCAPE))
                tree.filterCancel();
        }
        else if (inputMode)
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
                    vm.search(query[]);
            }
            if (IsKeyPressed(KeyboardKey.KEY_BACKSPACE) && query.length)
            {
                query.popBack();
                if (mode == Mode.search)
                    vm.search(query[]);
            }
            if (IsKeyPressed(KeyboardKey.KEY_ENTER))
            {
                if (mode == Mode.search)
                {
                    // Jump to the first match whose visual row is at/after the
                    // vm.current vm.top (vm.matches are in source order → visual order), wrap.
                    size_t i;
                    while (i < vm.matches.length && vm.visualOfMatch(vm.matches[i]) < vm.top)
                        ++i;
                    jumpToMatch(i < vm.matches.length ? i : 0, visibleRows);
                }
                else if (query.length) // gotoLine → the source line's visual row
                {
                    try
                    {
                        const n = query[].to!long;
                        const line = cast(size_t)(n > 0 ? n - 1 : 0);
                        if (line < vm.lineStarts.length)
                            vm.revealOffset(vm.lineStarts[line]); // FLD6
                        vm.top = vm.visualOfSrc(line);
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
                vm.matches = null;
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
                vm.widthCols = -1;
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
                const treeShift = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                    || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
                if (pressed(KeyboardKey.KEY_R))
                {
                    // r = manual refresh (XPF4); Shift-R = re-root to the
                    // selected item (XPF3).
                    if (treeShift)
                        tree.rerootSel();
                    else
                        tree.refreshNow();
                }
                if (treeShift && pressed(KeyboardKey.KEY_I))
                    tree.toggleIgnored(); // XPF2
                if (pressed(KeyboardKey.KEY_U))
                    tree.rerootParent(); // XPF3
                // Next/prev git change (XPF1) — the pane owns the brackets
                // while focused.
                if (pressed(KeyboardKey.KEY_RIGHT_BRACKET))
                    tree.jumpChange(1);
                if (pressed(KeyboardKey.KEY_LEFT_BRACKET))
                    tree.jumpChange(-1);
                if (pressed(KeyboardKey.KEY_C))
                    tree.closeAll(); // XPF3
                if (treeShift && pressed(KeyboardKey.KEY_H))
                    tree.toggleHidden(); // XPF2
                else if (pressed(KeyboardKey.KEY_H))
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
                    ++vm.top;
                if (pressed(KeyboardKey.KEY_K) || pressed(KeyboardKey.KEY_UP))
                    --vm.top;
                if (pressed(KeyboardKey.KEY_HOME))
                    vm.top = 0;
                if (pressed(KeyboardKey.KEY_END))
                    vm.top = maxTop;
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
                        vm.top -= steps;
                }
            }
            if (pressed(KeyboardKey.KEY_PAGE_DOWN))
                vm.top += visibleRows;
            if (pressed(KeyboardKey.KEY_PAGE_UP))
                vm.top -= visibleRows;

            // Live theme cycling (← previous, → next, wrapping).
            if (pressed(KeyboardKey.KEY_RIGHT))
                applyTheme(vm.themeIdx + 1 == themes.length ? 0 : vm.themeIdx + 1);
            if (pressed(KeyboardKey.KEY_LEFT))
                applyTheme(vm.themeIdx == 0 ? themes.length - 1 : vm.themeIdx - 1);

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
            if (vm.matches.length && pressed(KeyboardKey.KEY_N))
            {
                const shift = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                    || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
                jumpToMatch(shift ? vm.curMatch + vm.matches.length - 1 : vm.curMatch + 1, visibleRows);
            }

            // `[` / `]` (and the mouse back/forward buttons) walk the document
            // set; `i` returns to the index view (`GNV1`/`GAL5`).
            if (set !is null && !set.empty && loadDoc !is null)
            {
                // With the tree focused the brackets belong to the pane
                // (next/prev git change); the mouse back/forward buttons
                // navigate the set regardless of focus.
                const back = (!treeFocused
                        && IsKeyPressed(KeyboardKey.KEY_LEFT_BRACKET))
                    || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_BACK);
                const fwd = (!treeFocused
                        && IsKeyPressed(KeyboardKey.KEY_RIGHT_BRACKET))
                    || IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_FORWARD);
                if ((back || fwd) && set.move(back ? -1 : 1))
                    loadSelected();
                if (IsKeyPressed(KeyboardKey.KEY_I))
                {
                    treeVisible = true;
                    treeFocused = true;
                    vm.widthCols = -1;
                    relayout();
                }
            }

            // Tab toggles the decorated view ↔ raw highlighted source.
            if ((vm.preview.present || vm.tw.code.length) && IsKeyPressed(KeyboardKey.KEY_TAB))
            {
                vm.showPreview = !vm.showPreview;
                vm.widthCols = -1; // force a reflow on next frame
                relayout();
            }

            // 'l' toggles the file line-number gutter (changes the wrap width).
            if (!treeFocused && pressed(KeyboardKey.KEY_L))
            {
                lineNumbers = !lineNumbers;
                vm.widthCols = -1; // gutter width changed → reflow
                relayout();
            }

            // A pending fold sequence claims the next key (see below).
            const foldSeq = !treeFocused && foldSeqFrames > 0;

            // Ctrl-C copies the current selection to the clipboard; plain 'c'
            // toggles the in-panel code-block line numbers.
            if (ctrl && IsKeyPressed(KeyboardKey.KEY_C))
                copySelection();
            else if (!ctrl && !treeFocused && !foldSeq
                && pressed(KeyboardKey.KEY_C))
            {
                codeLineNumbers = !codeLineNumbers;
                vm.widthCols = -1;
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
            // The FLD5 fold family over the row's source identity (no-ops
            // in views without foldable spans): 'z' arms the sequence; then
            // a/z toggle, c close, o open, Shift-R open-all, Shift-M
            // fold-all. The armed state expires after ~1 s.
            if (foldSeq)
            {
                --foldSeqFrames;
                bool consumed = true;
                if (pressed(KeyboardKey.KEY_A) || pressed(KeyboardKey.KEY_Z))
                    foldAtCursor(ViewerModel.FoldOp.toggle);
                else if (pressed(KeyboardKey.KEY_C))
                    foldAtCursor(ViewerModel.FoldOp.close);
                else if (pressed(KeyboardKey.KEY_O))
                    foldAtCursor(ViewerModel.FoldOp.open);
                else if (pressed(KeyboardKey.KEY_R))
                    vm.setAllFolds(false);
                else if (pressed(KeyboardKey.KEY_M))
                    vm.setAllFolds(true);
                else
                {
                    consumed = false;
                    // z1–z9: fold to nesting level (vim's foldlevel).
                    foreach (n; 0 .. 9)
                        if (pressed(KeyboardKey.KEY_ONE + n))
                        {
                            vm.foldToLevel(n + 1);
                            consumed = true;
                            break;
                        }
                }
                if (consumed)
                    foldSeqFrames = 0;
            }
            else if (!treeFocused && pressed(KeyboardKey.KEY_Z))
                foldSeqFrames = 60;
            if (pressed(KeyboardKey.KEY_T))
            {
                tableFmt = tableFmt == TableCopyFormat.tsv
                    ? TableCopyFormat.markdown : TableCopyFormat.tsv;
                copyModeMsg = tableFmt == TableCopyFormat.tsv
                    ? "table-copy: tsv" : "table-copy: markdown";
                toast = Timeline.triggered(toastCfg);
            }

            // Enter an input mode: '/' filters the tree pane when focused,
            // else searches (raw view only); 'g' goto-line.
            if (treeFocused && IsKeyPressed(KeyboardKey.KEY_SLASH))
                tree.filterStart();
            else if (!treeFocused && !vm.showPreview && IsKeyPressed(KeyboardKey.KEY_SLASH))
            {
                mode = Mode.search;
                query.clear();
                vm.matches = null;
            }
            else if (!treeFocused && IsKeyPressed(KeyboardKey.KEY_G))
            {
                mode = Mode.gotoLine;
                query.clear();
            }
        }

        // The pane divider (STM8): hovering it shows the resize cursor; a
        // grab drags the split live. The drag owns the pointer, so nothing
        // below starts a selection or a scrollbar drag mid-resize.
        if (treeVisible)
        {
            const mp = GetMousePosition();
            const divX = treeCols * cellW + cellW / 2;
            const zone = mp.x >= divX - 4 && mp.x <= divX + 4;
            SetMouseCursor(zone || split.dragging
                ? MouseCursor.MOUSE_CURSOR_RESIZE_EW
                : MouseCursor.MOUSE_CURSOR_DEFAULT);
            if (zone && !split.dragging
                && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
                split = split.started(cast(int)(mp.x / cellW));
            if (split.dragging)
            {
                const maxCols = (screenW / cellW) / 2 < 12
                    ? 12 : (screenW / cellW) / 2;
                split = IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT)
                    ? split.released()
                    : split.draggedTo(cast(int)(mp.x / cellW), 12, maxCols);
                // The width change reflows through the resize debounce.
            }
        }
        else
            SetMouseCursor(MouseCursor.MOUSE_CURSOR_DEFAULT);

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
                const g = thumbGeometry(total, docRows, vm.top, maxTop,
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
                        sb.dragStartOffset = vm.top;
                    }
                    else // click on the track: center the viewport on the click
                        vm.top = cast(long)((pos.y - docY0) / trackH * total) - docRows / 2;
                }
                if (sb.isDragging)
                {
                    if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
                        sb.isDragging = false;
                    else if (g.movable > 0)
                        vm.top = sb.dragStartOffset
                            + cast(long)((pos.y - sb.dragStartY) * maxTop / g.movable);
                }
            }
            else
            {
                sb.isHovered = false;
                sb.targetWidth = idleW;
            }
            // Ease the width toward its target (vm.matches the terminal's 15/s rate).
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

        vm.top = vm.top < 0 ? 0 : (vm.top > maxTop ? maxTop : vm.top);
        const topLine = cast(size_t) vm.top;

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
            ClearBackground(rl(vm.pageBg));
            // Panes own their background: an explicit fill over the document
            // region every frame, so its pixels never depend on the clear
            // alone (the tree pane and header fill their own rects).
            DrawRectangle(treePx(), 0, screenW - treePx(), screenH, rl(vm.pageBg));
        }

        // One-cell background padding on the left, the scrollbar gutter on the
        // right, plus the optional line-number gutter; text starts at `contentX`.
        const padX = cellW;
        const rightPad = scrollbarGutter();
        const gcols = gutterCols();
        // Text starts after the tree pane (when visible), the 1-cell left
        // padding, and the line-number gutter.
        const gutterPx = treePx() + padX + gcols * cellW;

        // The one painter: the active tree's precomputed ops through the
        // raylib canvas, offset by the scroll position and culled to the
        // viewport rows (raylib clips px; the cull skips dead draw calls).
        {
            auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                gutterPx, cast(float)(docY0 - vm.top * cellH));
            // The pane's base clip: content (an unwrappable code line inside
            // a fence, a wide table) never bleeds past the pane or under the
            // header — the same rule the tree pane follows.
            canvas.pushClip(Rect(0, cast(int) vm.top,
                (screenW - rightPad - gutterPx) / cellW, docRows));
            foreach (ref op; vm.ops)
            {
                const oy = op.rect.y;
                if (op.kind != OpKind.pushClip && op.kind != OpKind.popClip
                    && (oy + op.rect.height <= vm.top || oy > vm.top + docRows))
                    continue;
                paint(canvas, (&op)[0 .. 1]);
            }
            canvas.popClip();

            // Fold markers in the pane's left padding column (FLD5): ▾ on
            // an open region's first row, ▸ on a folded one; click toggles.
            foreach (ref const fm; vm.foldMarkers)
            {
                if (fm.row < topLine || fm.row >= topLine + docRows)
                    continue;
                const g2 = cstrOf(buf, fm.open ? "▾" : "▸");
                drawText(fonts, g2, cast(float)(treePx() + 2),
                    docY0 + (fm.row - topLine) * cast(float) cellH,
                    TextStyle(0), rl(vm.gutterFg));
            }

            // Source line numbers in the gutter — from the row's source range
            // (first visual row of each source line only).
            if (gcols > 0)
            {
                size_t prevLine = size_t.max;
                foreach (row; 0 .. docRows)
                {
                    const vi = topLine + row;
                    if (vi >= vm.rows.length)
                        break;
                    if (vm.rows[vi].srcStart == size_t.max)
                        continue;
                    const ln = srcLineOf(vm.lineStarts, vm.rows[vi].srcStart);
                    if (ln == prevLine)
                        continue;
                    prevLine = ln;
                    const s = cstrOf(buf, uintToBuf(ln + 1));
                    drawText(fonts, s,
                        gutterPx - (s.length + 1) * cast(float) cellW,
                        docY0 + row * cast(float) cellH, TextStyle(0), rl(vm.gutterFg));
                }
            }
        }

        copiedFlash = copiedFlash.stepped(frameMs(), copiedCfg);
        // The ✔ glyph lives in the widget tree: rebuild when the flash ends so
        // the header reverts to the copy affordance.
        if (copiedShown && !copiedFlash.visible)
        {
            copiedShown = false;
            vm.copiedFenceSrc = size_t.max;
            vm.rebuild();
        }

        bool copyClicked; // a click landing on a copy button is not a selection

        // The fence copy affordance: the header band is the hit target (its
        // source-anchored id resolves the fence body); a click copies and the
        // ✔ glyph — part of the widget tree — holds for the flash duration.
        // (Views without hit targets — raw, twoslash — have an empty list.)
        {
            const mp = GetMousePosition();
            const dp = Point(cast(int)((mp.x - gutterPx) / cellW),
                cast(int)(vm.top + cast(long)((mp.y - docY0) / cellH)));
            // The fold column: a click on a marker toggles its region.
            if (mp.x >= treePx() && mp.x < treePx() + cellW
                && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
            {
                const row = vm.top + cast(long)((mp.y - docY0) / cellH);
                foreach (ref const fm; vm.foldMarkers)
                    if (cast(long) fm.row == row)
                    {
                        vm.folds = vm.folds.toggled(fm.key);
                        vm.rebuild();
                        copyClicked = true; // not a selection
                        break;
                    }
            }
            if (mp.x >= gutterPx && IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
                foreach_reverse (ref const tgt; vm.targets)
                {
                    if (tgt.hitId >= vm.foldHitBase && tgt.rect.contains(dp))
                    {
                        vm.folds = vm.folds.toggled(tgt.hitId - vm.foldHitBase);
                        vm.rebuild();
                        copyClicked = true; // not a selection either
                        break;
                    }
                    if (tgt.hitId >= vm.fenceHitBase && tgt.rect.contains(dp))
                    {
                        const bodyStart = tgt.hitId - vm.fenceHitBase;
                        foreach (ref const f; vm.fences)
                            if (f.body.start == bodyStart
                                && f.body.end <= source.length)
                            {
                                auto fbody = source[f.body.start .. f.body.end];
                                // Match the selection copy mode (SEL7).
                                const txt = (ansiStrip && f.isAnsi)
                                    ? stripSgr(fbody) : fbody;
                                SetClipboardText(txt.toStringz);
                                vm.copiedFenceSrc = bodyStart;
                                copiedFlash = Timeline.triggered(copiedCfg);
                                copiedShown = true;
                                copyClicked = true;
                                vm.rebuild(); // the header now shows the ✔
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
            const cx = cast(int)((mx - gutterPx) / cellW);
            const cy = vm.top + cast(long)((my - docY0) / cellH);
            if (mx < gutterPx || cy < 0 || cy >= cast(long) vm.rows.length)
                return h; // left of the content (tree/gutter) hits nothing
            const p = Point(cx, cast(int) cy);
            const off = sourceOffsetAt(vm.tree, vm.frames, p);
            // Inside a keyed table cell: a grid hit (2-D regime anchor),
            // with the char offset relative to the cell's source span.
            foreach (ref const kr; vm.cells)
                if (kr.rect.contains(p))
                {
                    const cellStart = kr.key - vm.tableKeyBase;
                    foreach (mi, ref const mc; vm.cellList)
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
            if (vm.rows[cast(size_t) cy].srcStart != size_t.max)
            {
                h.ok = true;
                h.lo = cast(long) vm.rows[cast(size_t) cy].srcStart;
                h.hi = cast(long) vm.rows[cast(size_t) cy].srcEnd;
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
                && !overTree && !copyClicked && !treeSb.isDragging && !sb.isDragging
                && !split.dragging)
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
                (xEndCol - xStartCol) * cellW, cellH, alpha(vm.quoteBars[1], 80));
        }
        // Tint a source byte range on the widget path: the toolkit derives the
        // char-precise rects (document cell coordinates) once for any backend.
        void tintSrcRange(long lo, long hi)
        {
            if (hi <= lo)
                return;
            foreach (r; selectionRects(vm.tree, vm.frames,
                cast(size_t) lo, cast(size_t) hi))
                tintRow(r.y - vm.top, r.x, r.x + r.width);
        }
        if (regime == Regime.text && selMax() > selMin())
            // One pass covers prose, code and table cells alike — every
            // span with source identity inside [smin, smax) tints.
            tintSrcRange(selMin(), selMax());
        else if (regime == Regime.table && selTable >= 0)
        {
            const dims = vm.tableDims(selTable);
            const reg = tableSelection(tblAnchor, tblHead, tblShift, tblAlt,
                dims.rows, dims.cols);
            foreach (ref const mc; vm.cellList)
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

        // Search-match overlay (raw view only): a translucent tint over each
        // visible match, its rects derived once from the identity channel
        // (the vm.current match brighter).
        if (!vm.showPreview)
            foreach (i, rects; vm.matchRects)
                foreach (ref const r; rects)
                {
                    const row = r.y - vm.top;
                    if (row < 0 || row >= docRows)
                        continue;
                    DrawRectangle(gutterPx + r.x * cellW,
                        cast(int)(docY0 + row * cellH), r.width * cellW, cellH,
                        i == vm.curMatch ? currentMatchTint : matchTint);
                }

        // Twoslash hover: pointer → byte (the identity channel) → hover node;
        // the token's dotted underline fades in and the popup (the shared
        // viewHoverPopup chrome via drawPopup) draws on vm.top, with pointer
        // hysteresis so moving down into the open popup keeps it open.
        if (vm.showPreview && vm.tw.code.length && tsCache !is null)
        {
            const mp = GetMousePosition();
            size_t overNode = 0;
            if (mp.x >= gutterPx)
            {
                const off = sourceOffsetAt(vm.tree, vm.frames,
                    Point(cast(int)((mp.x - gutterPx) / cellW),
                        cast(int)(vm.top + cast(long)((mp.y - docY0) / cellH))));
                if (off >= 0)
                    foreach (ni, ref const n; vm.tw.nodes)
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
                foreach (ni, ref const n; vm.tw.nodes)
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
                const n = vm.tw.nodes[hotNode - 1];
                auto rects = selectionRects(vm.tree, vm.frames,
                    n.start, n.start + n.length);
                if (rects.length)
                {
                    const r = rects[0];
                    const hx = gutterPx + r.x * cellW;
                    const hy = cast(int)(docY0 + (r.y - vm.top) * cellH);
                    const hw = r.width * cellW;
                    const uy = hy + cellH - 2;
                    const uc = Color(vm.pageFg.r, vm.pageFg.g, vm.pageFg.b,
                        cast(ubyte)(fade.alphaPercent(fadeCfg) * 255 / 100));
                    for (int i = 0; i + 2 <= hw; i += 4)
                        DrawRectangle(hx + i, uy, 2, 1, uc);
                    hotPopup = drawPopup(fonts, buf, vm.tw, hotNode - 1,
                        cast(float) hx, cast(float)(hy + cellH),
                        cellW, cellH, vm.current, *tsCache,
                        defaultTwoslashPalette(schemeForBackground(vm.pageBg)),
                        vm.pageFg, vm.pageBg);
                    havePopup = true;
                }
            }
        }

        // The explorer pane (XPL2): the tree's widget view painted through
        // RaylibCanvas at the window's left edge, viewport-sliced, with a
        // hairline divider. The whole pane clips at its own width.
        if (treeVisible && tree.git.poll())
            tree.rebuild(); // a finished async git refresh paints this frame
        if (treeVisible)
        {
            tree.height = visibleRows - treeTopRows;
            tree.scrollBy(0); // bounds only — never yank the view to the cursor
            DrawRectangle(0, 0, treeCols * cellW, screenH,
                rl(mix(vm.pageBg, vm.pageFg, 0.03)));
            DrawRectangle(treeCols * cellW + cellW / 2, 0, 1, screenH,
                rl(vm.gutterFg));

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
                themes[vm.themeIdx].effectivePalette, vm.pageFg, vm.pageBg);
            auto tCanvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                0, cast(float)(treeTopRows * cellH));
            paint(tCanvas, tOps);

            // The live-filter input line, pinned to the pane's bottom row
            // (the GUI pane has no status bar; the TUI shows it there).
            if (tree.searching)
            {
                const barY = screenH - cellH;
                DrawRectangle(0, barY, treeCols * cellW, cellH,
                    rl(vm.gutterFg));
                buf.clear();
                buf ~= "/";
                buf ~= tree.filterQuery;
                buf ~= "▏\0";
                drawText(fonts, buf[][0 .. $ - 1], 4, cast(float) barY,
                    TextStyle(0), rl(vm.pageBg));
            }

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
            const g = thumbGeometry(total, docRows, vm.top, maxTop, screenH - docY0);
            const w = sb.currentWidth;
            const x = screenW - w;
            // Distinct link-tinted chrome (the gutter behind it is empty page bg):
            // a subtle full-height track on hover, a brighter thumb on vm.top.
            if (sb.isHovered || sb.isDragging)
                DrawRectangle(cast(int) x, docY0, cast(int) w, screenH - docY0,
                    rl(vm.sbTrack));
            DrawRectangle(cast(int) x, cast(int)(docY0 + g.y), cast(int) w,
                cast(int) g.h, rl(vm.sbThumb));
        }

        // A header bar when navigating a document set (`GNV2`): the entry name and
        // summary on the left, the set position + keys on the right. Drawn over the
        // vm.top row so scrolled content passes under it.
        if (set !is null && !set.empty && loadDoc !is null)
        {
            DrawRectangle(0, 0, screenW, cellH, rl(mix(vm.pageBg, vm.pageFg, 0.12)));
            DrawRectangle(0, cellH - 1, screenW, 1, rl(vm.gutterFg));
            const left = vm.summary.length ? vm.title ~ "  " ~ vm.summary : vm.title;
            drawText(fonts, cstrOf(buf, left), cast(float) cellW, 0, TextStyle(0), rl(vm.pageFg));
            const pos = text(set.index + 1, "/", set.length, "   [ ] prev/next   i index");
            const px = cast(float)(screenW - cast(int)((pos.length + 1) * cellW));
            drawText(fonts, cstrOf(buf, pos), px, 0, TextStyle(0), rl(vm.gutterFg));
        }

        // Input line at the bottom: '/query' while searching, ':n' while going
        // to a line. Shows a match count for searches.
        if (inputMode)
        {
            const barY = screenH - cellH;
            DrawRectangle(0, barY, screenW, cellH, rl(vm.gutterFg));
            auto lineText = mode == Mode.search
                ? text("/", query[], "   ", vm.matches.length, " vm.matches")
                : text(":", query[]);
            drawText(fonts, cstrOf(buf, lineText), 4, cast(float) barY, TextStyle(0), rl(vm.pageBg));
        }
        // Copy-mode toast (when not typing): flashes the mode after a 'y'/'t' toggle.
        else if (toast.visible)
        {
            toast = toast.stepped(frameMs(), toastCfg);
            const barY = screenH - cellH;
            DrawRectangle(0, barY, screenW, cellH, rl(vm.gutterFg));
            drawText(fonts, cstrOf(buf, copyModeMsg), 4, cast(float) barY, TextStyle(0), rl(vm.pageBg));
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

/// The floating hover popup, built from the shared `viewHoverPopup` widget view
/// (surface panel + docs + `@param` chips — the same chrome as the TUI/HTML) and
/// painted through `RaylibCanvas`. The type signature renders as resolved
/// syntax-colored spans (`signatureSpans`) inside the widget model itself, so
/// nothing overpaints the toolkit's output.
private Rectangle drawPopup(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    in TwoslashReturn tw, size_t nodeIndex, float x, float y, int cellW, int cellH,
    in ResolvedTheme theme, ref TsConfigCache cache, in Palette pal,
    RgbColor pageFg, RgbColor pageBg) @system
{
    import sparkles.twoslash.render_widgets : signatureSpans;

    // Render JSDoc docs as markdown (bold/italic/code/links/lists/fences), via the
    // grammar registry — falls back to plain lines without it.
    auto sig = signatureSpans(cache, (() @trusted => &theme)(), pageFg,
        withoutQuickinfoPrefix(tw.nodes[nodeIndex].text));
    auto tree = viewHoverPopup(tw, nodeIndex, cache.registry, sig);
    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);

    auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH, x, y);
    paint(canvas, ops);

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

/// An RGB triple as a raylib color (fully opaque).
Color rl(RgbColor c) pure nothrow @nogc @trusted => Color(c.r, c.g, c.b, 255);
