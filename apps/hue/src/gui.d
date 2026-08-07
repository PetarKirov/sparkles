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


import core.stdc.stdarg : va_list; // for the TraceLogCallback bridge (NFR7)
import core.time : dur, Duration, MonoTime, usecs;

import sparkles.event_horizon.sched : Sched;

// The shared raylib text core (extracted in M5). Pulls raylib-d + libs
// "raylib" transitively, so it is present only in the `gui` build.
import sparkles.raylib_text : displayMetrics, DisplayMetrics, FontSet,
    drawText, pixelsForPoints, TextStyle;

// The shared scroll-step convention: this file is a wheel PRODUCER, so it
// applies the notch multiplier itself (INP12).
import sparkles.base.term_control : PointerShape;
import sparkles.input.events : Event, Key, KeyEvent, linesPerNotch, match,
    Mods, PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.input.frame : InputFrame, foldFrame, pointerFor;
import keymap : Binding, bindingsAt, Chord, Command, commandFor, InputMode,
    KeyContext;
import lantern : LanternState, ltnStep = step, ltnTick = tick,
    LtnStepKind = StepKind;
import lantern_view : BoxLayout, LabelArena, LanternStyle, Placement,
    viewLantern;
import sparkles.input.capability : InputCapabilities, mousePointer,
    touchPointer;

// hue-specific viewport/search layout (raylib-free, so it stays testable).
import gui_text : Match;

// Markdown-preview model (raylib-free) and the ANSI-fence decoder.
import diff_session : DiffSession;
import diff_view : TypeOverlay;
import document : DiffSides, Document;
import gui_preview : PreviewModel, stripSgr;
import sparkles.diff.model : DiffDoc;
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
import sparkles.twoslash.render_widgets : abbrevRegion, viewHoverPopup;
import sparkles.twoslash.signature_layout : ExpandedRegions;

// The shared visual language: the twoslash palette is the single source for the
// error/warn/tag/highlight colors this backend used to hand-copy as literals, and
// the widget views drive the hover popup (so the GUI matches the TUI/HTML chrome).
import sparkles.ui.style : defaultTwoslashPalette, Palette, Visual,
    resolveSlot, schemeForBackground, Slot, UiTextStyle = TextStyle;
import sparkles.ui.components.chrome : actionBar, headerBar;
import sparkles.ui.dock : DockAxis, DockContainer, PaneId, RouteKind;
import sparkles.ui.geometry : Constraints, Point, Rect;
import sparkles.ui.canvas : DrawOp, LineStyle, OpKind, RuleEdge;
import sparkles.ui.layout : layout;
import sparkles.ui.scroll_view : ScrollExtents, ScrollPointer;
import sparkles.ui.state : CaptureState, hoverTargets, HoverState, keyAt,
    keyTargets, KeyTarget, PressState, ScrollAxis, ScrollbarState,
    scrollbarThumb, selectionRects, sourceOffsetAt, wantedPointerShape,
    SplitState, Timeline;
import sparkles.ui.display_list : buildDisplayList, buildDisplayListInto;
import sparkles.ui.widget : Builder;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_raylib : drawScrollbar, namedKey, RaylibCanvas, RaylibEvents,
    ScrollbarAnim,
    traceLevelTag, traceLogTo, Window, WindowRequest,
    scrollbarLayout, toRaylibCursor;

// Live D types (`PRJ12`-`PRJ16`): the `twoslash-extract --serve` oracle beside
// the window. A subprocess, never a link-time dependency (`PRJ13`).
import live_types : applyTip, LiveTypesSession;

// The multi-document set the twoslash view navigates with `[`/`]` (`GNV1`), plus
// the two entry points a navigation reload needs.
import source_set : SourceEntry, SourceSet;
import sparkles.twoslash.ingest : loadTwoslashFile;
import sparkles.syntax.ts.highlighter : highlightInjected;

/// Which selection regime a drag runs (`SEL`/`TBL`).
private enum Regime
{
    none,
    text,
    table,
}

/// The mouse-selection drag state (M15 GROUP-S of the GuiState hoist):
/// which regime the drag runs (text span vs table grid), the live anchors,
/// and the modifier snapshot a table drag copies with.
private struct SelectionDrag
{
    Regime regime;
    bool selecting;
    long anchorLo, anchorHi, headLo, headHi;
    int selTable = -1;
    GridHit tblAnchor, tblHead;
    bool tblShift, tblAlt;

    long selMin() const @safe pure nothrow @nogc
        => anchorLo < headLo ? anchorLo : headLo;
    long selMax() const @safe pure nothrow @nogc
        => anchorHi > headHi ? anchorHi : headHi;
}

/// The two panes this host composes. Identities, not indices: the
/// container resolves them to frames.
private enum PaneId treePane = 1, docPane = 2;

/// The workspace panes (M15 GROUP-P of the GuiState hoist): the explorer
/// tree pane (XPL2), and the dock container that arranges it beside the
/// document (C-2a) — the container owns the tiling, the STM8 divider
/// drag, focus and its own pointer capture. Scrolling moved off with C-1:
/// each scrollable model owns its `ScrollView` (`vm.scroll` /
/// `tree.scroll`) — machines, offsets and px easings as one value both
/// backends step.
private struct Panes
{
    ExplorerTui tree;
    DockContainer dock;

    /// The key guide's pending path and panel state (`LTN2`). Owned here
    /// because it is view state like any other, and because both panes feed
    /// it — the guide is not the viewer's or the tree's.
    LanternState lantern;

    /// Whether the explorer pane is shown at all ('e' toggles it).
    bool treeVisible() const @safe pure nothrow
        => dock.layout.visible(treePane);

    /// ditto
    void treeVisible(bool v) @safe pure nothrow
    {
        dock.layout.setVisible(treePane, v);
    }

    /// Whether the explorer pane holds focus (`DCK6`, container-owned).
    bool treeFocused() const @safe pure nothrow @nogc
        => dock.focused == treePane;

    /// ditto
    void treeFocused(bool v) @safe pure nothrow @nogc
    {
        dock.focused = v ? treePane : docPane;
    }
}

/// The input-routing state (M15 GROUP-I of the GuiState hoist): which
/// line-input surface owns the keyboard ('/' search, ':' goto) and its
/// typed query, pointer-capture ownership (STM11), and the per-frame
/// `FrameInput` fold carry (IXB7 — the button level lives across frames).
private struct InputState
{
    Mode mode = Mode.normal;
    SmallBuffer!(char, 256) query;
    CaptureState capture;
    InputFrame fin;
}

/// The copy modes (M15 GROUP-C of the GuiState hoist), toggleable at
/// runtime and seeded from the CLI: 'y' flips ANSI strip-vs-raw (SEL7),
/// 't' flips the table serialization (TBL2); a toggle flashes the new
/// mode in the status bar (`Flashes.toast`).
private struct CopyModes
{
    bool ansiStrip;
    TableCopyFormat tableFmt;
}

/// The transient feedback state (M15 GROUP-T of the GuiState hoist): the
/// copied-checkmark flash beside a fence's copy button (the copied fence
/// itself is `vm.copiedFenceSrc`), the copy-mode toast a 'y'/'t' toggle
/// flashes in the status bar, and the armed vim 'z' fold sequence ('z'
/// arms it for ~a second; the next key picks the op).
private struct Flashes
{
    Timeline copiedFlash;
    bool copiedShown; // the ✔ glyph is in the tree; rebuild when the flash ends
    string copyModeMsg;
    Timeline toast;
}

/// The twoslash hover latch (M15 GROUP-T): the open popup's node (+1;
/// 0 = none), its rect (pointer hysteresis), the token-underline fade
/// (STM6), and — per popup, not persistent — which collapsed signature
/// runs the reader opened, with where they landed so a click can name one.
private struct HoverPopup
{
    size_t hotNode = 0;
    PixelRect hotPopup;
    bool havePopup = false;
    ExpandedRegions expandedRegions;
    KeyTarget[] popupKeys;
    size_t popupNode = size_t.max;
    Timeline fade;
    int forceHover = -1; // HUE_GUI_HOVER=<n>: force the Nth popup (goldens)
}

/// The live-resize relayout debounce (M15 GROUP-W of the GuiState hoist):
/// during a drag the column count changes almost every frame, so re-wrap
/// only once the width has held steady for `settleFrames` frames — the drag
/// pays one relayout when it settles instead of one per frame. Discrete
/// width changes (theme / font size / gutter toggles) relayout immediately,
/// so this only ever debounces a live window resize.
private struct ResizeDebounce
{
    int prevWidthCols = -1;
    int settle;
    enum settleFrames = 4; // ~66 ms at 60 FPS
}

/// The window's default font size in pixels (Ctrl-±/theme cycling arrive in M3).
private enum defaultFontSize = 18;


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
    trace(i"raylib[$(traceLevelTag(logLevel))]: $(msg)");
}

/// Sane concrete fallbacks when a theme leaves the page fore-/background unset
/// (the GPU has no "terminal default" to defer to, unlike the ANSI backend).
private enum RgbColor hardFallbackFg = RgbColor(0xcd, 0xd6, 0xf4);
private enum RgbColor hardFallbackBg = RgbColor(0x1e, 0x1e, 0x2e);

/// Translucent overlays for search matches: all matches, and the current one.
/// A translucent overlay colour: RGB plus its own alpha, so the constants
/// below need no backend type (`UIA7`).
private struct Tint { RgbColor rgb; ubyte alpha; }
private enum Tint matchTint = Tint(RgbColor(255, 215, 0), 70);
private enum Tint currentMatchTint = Tint(RgbColor(255, 145, 0), 130);

/// The interactive input mode (M4): normal keys, or typing a search / goto line.
private enum Mode
{
    normal,
    search,
    gotoLine,
}

/// A loaded document — the pipeline's `Document` Whole itself, so the
/// navigation boundary loses nothing (content kind and diff payload ride
/// along; this transport used to drop the kind, forcing payload-presence
/// inference in the viewer).
alias LoadedDoc = Document;

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
    int tabWidth = 4,                    // tab stops in the raw view
    bool listWhitespace = false,         // vim 'list' whitespace glyphs
    string[] codepointMaps = null,       // --font-codepoint-map entries (Android defaults)
    bool liveTypes = true,               // live D types via the oracle (PRJ12)
    DiffDoc initialDiff = DiffDoc.init,  // diff document payload (ContentKind.diff)
    DiffSides[] initialDiffSides = null, // per-file side texts (DVM5)
    DiffSession initialDiffSession = DiffSession.init, // changed-file session (DVS4)
) @system
{
    import std.stdio : stderr;
    import std.string : toStringz;
    import std.process : environment;
    import std.conv : to, text;

    // Debug/CI capture: HUE_GUI_SCREENSHOT=<path> renders a few frames, writes a
    // PNG, and exits — the golden-frame harness the syntax spec's totality and
    // M5's byte-identical-render checks rely on (skipTest-gated when headless).
    // Android anchors relative paths in the app data dir (CWD is '/', not
    // writable); pull the PNG with `adb shell run-as`.
    auto shotPath = environment.get("HUE_GUI_SCREENSHOT", "");
    version (Android)
    {
        import android_glue : androidDataDir;

        if (shotPath.length && shotPath[0] != '/')
            shotPath = androidDataDir() ~ "/" ~ shotPath;
    }
    // HUE_GUI_FLASH=1: alternate the clear color every ~0.5 s and skip the
    // pane fill — a ghosting discriminator. If the background flashes
    // everywhere but stale text rides on vm.top, the ghost is DRAWN each frame;
    // any region that does NOT flash is not being cleared/presented.
    const flashDebug = environment.get("HUE_GUI_FLASH", "").length != 0;
    // HUE_GUI_SCREENSHOT_FRAME=<n> delays the capture (default 20) so a QA
    // harness can drive synthetic input first.
    int shotFrame = 20;
    // Capture bookkeeping: when the git worker was first seen idle, when the
    // shot was taken, and how long we will wait for the former.
    int settledAt = -1;
    int shotAt = -1;
    enum shotSettleCap = 240; // ~4 s at 60 FPS
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
    // Resolved against the real display below, once the window exists; this
    // is the nominal-DPI fallback for the paths that read it earlier.
    int fontSizePx = pixelsForPoints(fontSize, DisplayMetrics.init);
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
    traceLogTo(&raylibTraceLog);

    // The frame cadence's owner (M17, event-horizon SPEC §15.3 GUI shape):
    // when the ring is available, raylib's own pacing is disabled
    // (`targetFps: 0`) and the loop paces on absolute frame deadlines via
    // `Sched.tick` — parking in the ring, where subprocess and watch
    // completions run between frames. Where loop creation fails (Android's
    // app seccomp blocks io_uring), raylib keeps its SetTargetFPS sleep —
    // the explicit fallback arm, selected once here.
    import sparkles.event_horizon.sched : Sched, SchedOptions;

    SchedOptions schedOpts;
    schedOpts.stackSize = 1024 * 1024;
    schedOpts.maxFibers = 16;
    Sched sched;
    const asyncLoop = !Sched.create(sched, schedOpts).hasError;

    // Android: 0×0 = the native surface resolution (a non-zero size is NOT
    // ignored there — raylib letterboxes it onto the screen); the surface is
    // the app, so no resizable state and no cell-sizing either.
    // 0×0 on Android = the native surface resolution; the surface IS the app,
    // so it is neither sized nor resizable there.
    version (Android)
        auto window = Window.open(WindowRequest(
            title: "hue — " ~ title, width: 0, height: 0, resizable: false,
            targetFps: asyncLoop ? 0 : 60));
    else
        auto window = Window.open(WindowRequest(
            title: "hue — " ~ title, width: 800, height: 600,
            targetFps: asyncLoop ? 0 : 60));

    // LoadFontEx uploads a GPU texture, so the FontSet must load after InitWindow.
    // `fontName` may be a path, a family, or a fontconfig preference list.
    // Android resolves against the extracted asset fonts + /system/fonts (no
    // fontconfig), and scales the point size by the panel density — 14 pt is
    // unreadable on a 400-dpi screen. HUE_GUI_FONTSIZE (applied by the caller)
    // stays the deterministic override for goldens.
    FontSet.FontSources fontSrc;
    version (Android)
    {
        import android_glue : androidDataDir;
        import android_paths : fontsDir;

        fontSrc = FontSet.FontSources([fontsDir(androidDataDir()), "/system/fonts"],
            useFontconfig: false);
    }

    // Resolve the point size against the real panel. This is no longer an
    // Android special case: a HiDPI desktop has the same problem, and used to
    // get the same 19 px as a 96 dpi one (IXR28). The clamp that keeps the
    // atlas bounded is the library's now, not a magic 4 here.
    //
    // HUE_GUI_FONTSIZE stays the deterministic override for goldens, so it
    // suppresses scaling entirely rather than being scaled itself.
    if (environment.get("HUE_GUI_FONTSIZE", "").length == 0)
        fontSizePx = pixelsForPoints(fontSize, displayMetrics());
    FontSet fonts;
    if (!FontSet.tryLoad(fontName, fontSizePx, fonts, codepointMaps, faces, fontSrc))
    {
        stderr.writeln("hue --gui: could not load a font from '", fontName,
            "' (is fontconfig available?)");
        version (Android)
        {
            import sparkles.base.logger : error;

            error(i"hue: no font resolved from '$(fontName)'");
        }
        return 1;
    }
    scope (exit) fonts.unload();

    // `--window-width`/`--window-height` are in cells (like apps/terminal); size
    // the window to the loaded cell metrics.
    version (Android) {}
    else if (windowWidth > 0 && windowHeight > 0)
        window.resize(windowWidth * fonts.cellW(), windowHeight * fonts.cellH());

    // The document pipeline's Whole (PRN1 / the C1 diagnosis): one value owns
    // the document, its theme-resolved colors, widget pipeline, folding,
    // document scroll and search. Window resources and the still-separate
    // interaction groups remain here until HUE-O1 consolidates their ownership.
    ViewerModel vm;
    vm.names = names;
    vm.themes = themes;
    vm.labels = labels;
    vm.cache = tsCache;
    vm.decodeAnsi = (const(char)[] b) => decodeAnsi(b);
    vm.themeIdx = startIdx;
    vm.tabWidth = tabWidth < 1 ? 1 : tabWidth;
    vm.listWhitespace = listWhitespace;
    vm.codeLineNumbers = codeLineNumbers;

    ResizeDebounce rd;

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

    Panes pn;
    pn.tree.includeGlobs = includeGlobs;
    pn.tree.excludeGlobs = excludeGlobs;
    // The pane arrangement is the toolkit's dock container (C-2a), run in
    // CELLS exactly as the terminal host runs it — the pointer is
    // converted at the boundary, which is the only difference a pixel
    // target makes here. --tree-width seeds the sidebar's extent; the
    // container's STM8 divider drag moves it.
    {
        const t = pn.dock.layout.addLeaf(treePane,
            extent: treeWidth < 12 ? 12 : treeWidth, minExtent: 12);
        const d = pn.dock.layout.addLeaf(docPane);
        pn.dock.layout.root = pn.dock.layout.addSplit(DockAxis.horizontal,
            [t, d]);
    }
    pn.treeVisible = startInTree;
    pn.treeFocused = startInTree;

    // The container's frames, refreshed only when an input to them moves —
    // the arrangement is read many times a frame and changes rarely.
    void arrangePanes()
    {
        const cw = fonts.cellW();
        const ch = fonts.cellH();
        auto tn = pn.dock.layout.nodeOf(treePane);
        pn.dock.layout.nodes[tn].maxExtent =
            (window.width / cw) / 2 < 12 ? 12 : (window.width / cw) / 2;
        // Each pane wears one header row, and the container reserves it
        // (DCK10): the content rects below already exclude it, which is
        // what lets the hit tests stop subtracting chrome by hand.
        pn.dock.layout.nodes[tn].headerExtent = 1;
        pn.dock.layout.nodes[pn.dock.layout.nodeOf(docPane)].headerExtent = 1;
        // The document-set bar spans BOTH panes, so it is not a pane's
        // header: the container's area simply starts below it.
        const setRows = set !is null && !set.empty ? 1 : 0;
        pn.dock.arrange(Rect(0, setRows, window.width / cw,
            window.height / ch - setRows));
    }

    /// A pane's content rect in cells (empty when the pane is hidden) —
    /// the container's answer, not a hand-subtracted one.
    Rect paneContent(PaneId p)
    {
        foreach (ref f; pn.dock.paneFrames)
            if (f.pane == p)
                return f.rect;
        return Rect.init;
    }

    int treeCols() => pn.dock.paneExtent(treePane);
    int treePx() => pn.dock.paneOrigin(docPane) * fonts.cellW();

    int widthCols()
    {
        const cw = fonts.cellW();
        const w = (window.width - cw - scrollbarGutter() - gutterCols() * cw
            - treePx()) / cw;
        return w < 8 ? 8 : w;
    }

    // Input routing (search/goto line input, pointer capture, the per-frame
    // event fold); the match set and its rects live in `vm`.
    InputState inp;

    // Every view reflows on resize: the model lays the active widget tree
    // out to the new width (raw source rows wrap greedily; line numbers
    // derive from each row's source range).
    void relayout()
    {
        vm.relayout(widthCols());
    }

    // Ctrl-± / pinch zoom: reload every face at the new size and reflow (the
    // cell size — and thus the column count — changed).
    void bumpFontSize(int delta)
    {
        const next = fonts.size() + delta;
        if (next < 6)
            return;
        fonts.reload(next);
        relayout();
    }

    // 'e' / the toolbar: toggle the explorer pane (XPL2); focus follows.
    void toggleExplorer()
    {
        pn.treeVisible = !pn.treeVisible;
        pn.treeFocused = pn.treeVisible;
        vm.widthCols = -1;
        relayout();
    }

    // Tab / the toolbar: preview ↔ raw view (when the document has a preview).
    void toggleView()
    {
        if (!vm.preview.present && vm.tw.code.length == 0)
            return;
        vm.showPreview = !vm.showPreview;
        vm.widthCols = -1; // force a reflow on next frame
        relayout();
    }

    void applyTheme(size_t i)
    {
        vm.widthCols = widthCols();
        vm.applyTheme(i);
        window.title(text("hue — ", title, " — ", names[i],
            " (", i + 1, "/", names.length, ")").toStringz);
        // The explorer pane follows the theme too — page colors and the
        // palette its slots resolve against, not just the syntax colors.
        pn.tree.theme = vm.current;
        pn.tree.themeValue = &themes[i];
        pn.tree.pageFg = vm.pageFg;
        pn.tree.pageBg = vm.pageBg;
        if (pn.tree.root.length)
            pn.tree.rebuild();
    }

    pn.tree.chromeRows = 0; // the GUI pane is all tree rows
    pn.tree.root = treeRoot.length ? treeRoot
        : (docPath.length ? dirName(docPath) : ".");
    // The frames must exist before the first layout: everything below reads
    // the document pane's width through the container, and an unarranged
    // container reports nothing.
    arrangePanes();
    applyTheme(vm.themeIdx); // resolves the theme before the first document
    vm.setDocument(title, set !is null && !set.empty ? set.current.summary : "",
        source, events, preview, twoslash, docLang, initialDiff,
        initialDiffSides, initialDiffSession);
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
        pn.tree.reveal(docPath);

    SmallBuffer!(char, 4096) buf; // reused, NUL-terminated for raylib

    // Live D types (`PRJ12`): a `.d` file that arrived without a payload gets a
    // `twoslash-extract --dub --serve` oracle of its own. The session is per
    // open document — opening another file ends the previous one — and the
    // notice (no binary, or a child that died) is printed once per window.
    LiveTypesSession* liveSession;
    /// `DVT1`: the two oracles a diff needs — one per side of the focused
    /// file. A diff's sides are two different texts, so one session cannot
    /// answer for both.
    LiveTypesSession*[2] diffLive;
    bool liveNoticeShown;

    void noteLive(string why)
    {
        if (liveNoticeShown)
            return;
        liveNoticeShown = true;
        stderr.writeln("hue: live D types unavailable: ", why);
    }

    void stopDiffTypes()
    {
        foreach (ref s; diffLive)
        {
            if (s is null)
                continue;
            s.shutdown();
            s = null;
        }
    }

    void stopLive()
    {
        stopDiffTypes();
        if (liveSession is null)
            return;
        liveSession.shutdown();
        liveSession = null;
    }

    /// `DVT1`/`T0`: one analyzer per side of a two-file `.d` diff — the same
    /// scope the terminal workspace uses, against the same shared model, so
    /// the two backends cannot drift on when types appear.
    void startDiffTypes()
    {
        import std.algorithm.searching : endsWith;
        import std.file : exists, isFile;

        stopDiffTypes();
        if (!liveTypes || !vm.showPreview || vm.diffSession.empty
            || vm.diffSession.entries.length != 1)
            return;
        const paths = [vm.diffSession.entries[0].oldPath,
            vm.diffSession.entries[0].newPath];
        foreach (p; paths)
        {
            if (!p.endsWith(".d"))
                return;
            bool ok;
            try
                ok = p.exists && p.isFile;
            catch (Exception)
                ok = false;
            if (!ok)
                return;
        }
        if (vm.diffTypes.length < 1)
            vm.diffTypes.length = 1;
        foreach (i, p; paths)
        {
            string reason;
            diffLive[i] = LiveTypesSession.start(p, reason);
            if (diffLive[i] is null)
                noteLive(reason);
        }
    }

    // `PRJ12`: triggered by the document open, never from the render path.
    void startLive(string path, bool alreadyHasPayload)
    {
        import std.algorithm.searching : endsWith;

        stopLive();
        if (!liveTypes || alreadyHasPayload || !path.endsWith(".d"))
            return;
        string reason;
        liveSession = LiveTypesSession.start(path, reason);
        if (liveSession is null)
            noteLive(reason);
    }

    scope (exit) stopLive();

    // The document hue opened with (a payload target needs no oracle).
    if (docPath.length)
        startLive(docPath, vm.tw.code.length != 0);
    startDiffTypes();

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
            doc.twoslash, doc.lang, doc.diffDoc, doc.diffSides, doc.diffSession,
            doc.diffEmphasis);
        inp.query.clear();
        inp.mode = Mode.normal;
        window.title(("hue — " ~ name).toStringz);
        pn.tree.reveal(path); // the explorer follows the open document (XPL3/4)
        startLive(path, vm.tw.code.length != 0);
        return true;
    }

    // Enter/l/double-click on a tree row opens a file (or toggles a dir).
    void activateTree()
    {
        if (pn.tree.sel >= cast(long) pn.tree.rows.length)
            return;
        if (!pn.tree.activate() && pn.tree.picked.length)
        {
            import std.path : baseName;

            const path = pn.tree.picked;
            pn.tree.picked = null;
            if (openPath(path, baseName(path), ""))
                pn.treeFocused = false;
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
        inp.query ~= ch;
    if (inp.query.length)
    {
        vm.search(inp.query[]);
        if (vm.matches.length)
            vm.top = vm.visualOfMatch(vm.matches[0]);
    }

    // Debug/CI: HUE_GUI_LANTERN=<keys> seeds the guide's pending path and
    // shows it at once, so a golden capture can hold the panel open — there is
    // otherwise no way to photograph something that only exists between two
    // keystrokes. An empty value shows the root listing.
    if (auto seed = environment.get("HUE_GUI_LANTERN", null))
    {
        foreach (ch; seed)
            pn.lantern.pending ~= Chord(key: Key.char_, ch: ch);
        pn.lantern.shown = true;
    }


    // The ONE input source (IXB7/UIA7): raylib's polled state is synthesised
    // into `sparkles:input` events by the backend adapter, drained once per
    // frame here, and folded into the flags the sites below read. hue names no
    // raylib input call.
    //
    // `poll(sink, 1, 1)` — a cell of 1×1 px means positions arrive in PIXELS,
    // which is the unit hue's chrome already works in. Converting coordinates
    // at the same time as the seam would have made a behaviour change
    // indistinguishable from a refactor.
    RaylibEvents inputSource;
    Event[] evBuf;
    KeyEvent[] keyBuf;

    // The key guide's per-frame scratch, hoisted out of the loop so a panel
    // that is up every frame costs no allocation to repaint: the label arena
    // and the display-list sink are cleared and refilled, never regrown
    // (`NFR2`, via `buildDisplayListInto`).
    LabelArena ltnLabels;
    SmallBuffer!(DrawOp, 256) ltnOps;

    // Pointer capture (STM11, closing IXR6's GUI half). Every draggable
    // affordance takes an id and asks `inp.capture.available(id)` — "free, or
    // already mine" — in place of the allow-list of negations it used to
    // carry (`!split.dragging && !docSb.dragging && !treeVSb.dragging && …`),
    // which every NEW affordance had to be added to inside every OTHER
    // affordance's condition. The Android toolbar became a fourth owner of
    // one screen row and that list did not grow with it.
    //
    // These are the WITHIN-pane affordances. Pane- and chrome-level
    // ownership (which pane the pointer is in, the divider between them)
    // is the container's own capture — the same two levels the terminal
    // host has, where a pane's grabs live inside its `handle`.
    enum size_t capContainer = 1, capDocSb = 2, capTreeSb = 3,
        capDocHSb = 4, capTreeHSb = 5, capSelection = 6;

    Flashes flash;
    HoverPopup pop;
    try
        pop.forceHover = environment.get("HUE_GUI_HOVER", null).length
            ? environment.get("HUE_GUI_HOVER").to!int : -1;
    catch (Exception)
    {
    }

    // Mouse selection has two regimes (a drag stays in the one it starts in, TBL4):
    //  • text  (SEL): a source byte range [drag.selMin, drag.selMax). Prose/code map a click
    //    char-precisely; an ANSI body line selects its whole fence-body span (SEL6).
    //  • table (TBL): a 2D grid selection inside one table, resolved from anchor +
    //    head cells (from the table map) under Shift/Alt.
    SelectionDrag drag;

    auto cm = CopyModes(ansiStrip: ansiCopyStrip, tableFmt: tableCopy);

    // The text-regime selection as a source range [drag.selMin, drag.selMax) — the union of
    // the anchor and head spans (a char point is a zero-width span).

    // The one clipboard seam. raylib's Android SetClipboardText is an
    // unimplemented no-op (a TRACELOG warning — see rcore_android.c), so
    // Android goes through the JNI ClipboardManager bridge instead.
    // Takes a slice: the Android side needs a length to transcode to UTF-16,
    // and only the raylib path wants NUL termination.
    void copyToClipboard(scope const(char)[] text)
    {
        version (Android)
        {
            import android_glue : setClipboardText;
            import sparkles.base.logger : warning;

            if (!setClipboardText(text))
                warning(i"copy: JNI clipboard bridge failed");
        }
        else
            window.clipboard(text.toStringz);
    }

    // Copy the current selection: a text range → `vm.source[min..max]`
    // (SGR-stripped when `cm.ansiStrip`); a table region → TSV / markdown cells
    // (SEL7/TBL2). Always slices `vm.source` — the DISPLAYED document — not
    // the `source` parameter hue launched with: after navigating a set or
    // opening a file from the explorer the two differ, and the selection/
    // fence offsets belong to the current document.
    void copySelection()
    {
        if (drag.regime == Regime.text && drag.selMax() > drag.selMin()
            && drag.selMax() <= vm.source.length)
        {
            auto txt = vm.source[cast(size_t) drag.selMin() .. cast(size_t) drag.selMax()];
            copyToClipboard(cm.ansiStrip ? stripSgr(txt) : txt);
        }
        else if (drag.regime == Regime.table && drag.selTable >= 0)
        {
            // Cell content = its raw source slice (through the cell spans the
            // document walk collected — the same identity the tint uses).
            const dims = vm.tableDims(drag.selTable);
            const reg = tableSelection(drag.tblAnchor, drag.tblHead, drag.tblShift, drag.tblAlt,
                dims.rows, dims.cols);
            const(char)[] cellText(size_t r, size_t c)
            {
                foreach (ref const mc; vm.cellList)
                    if (mc.table == drag.selTable && mc.row == r && mc.col == c
                        && mc.span.end <= vm.source.length)
                        return vm.source[mc.span.start .. mc.span.end];
                return "";
            }
            const txt = serializeTable(reg, &cellText, cm.tableFmt);
            if (txt.length)
                copyToClipboard(txt);
        }
    }

    // 'z': toggle the innermost fold at the text selection (else the top
    // visible row) — the model owns the region choice and the rebuild.
    void foldAtCursor(ViewerModel.FoldOp op)
    {
        long off = -1;
        if (drag.regime == Regime.text && drag.selMax() > drag.selMin())
            off = drag.selMin();
        else if (vm.rows.length)
        {
            const t0 = cast(size_t)(vm.top >= 0
                && vm.top < cast(long) vm.rows.length ? vm.top : 0);
            if (vm.rows[t0].srcStart != size_t.max)
                off = cast(long) vm.rows[t0].srcStart;
        }
        vm.foldAt(off, op);
    }

    // A pane's header bar through the SHARED chrome component (the same
    // headerBar + Slot.chromeFocused + bold title the TUI paints): built
    // fresh per frame, painted at pixel (x, y) spanning widthCols cells.
    void drawChromeBar(int x, int y, int widthCols_, string title_,
        string center, string trailing, bool focused)
    {
        import sparkles.ui.geometry : SizeSpec;
        import sparkles.ui.widget : Builder, Widget, WidgetKind;

        auto b = Builder();
        const name = b.add(Widget(kind: WidgetKind.text, text: title_,
            slot: focused ? Slot.chromeAccent : Slot.gutter,
            textStyle: UiTextStyle(bold: focused)));
        uint[] mid;
        if (center.length)
            mid ~= b.add(Widget(kind: WidgetKind.text, text: center,
                slot: Slot.gutter));
        uint[] tail;
        if (trailing.length)
            tail ~= b.add(Widget(kind: WidgetKind.text, text: trailing,
                slot: Slot.gutter));
        const bar = headerBar(b, [name], mid, tail, focused);
        Widget colW = Widget(kind: WidgetKind.column, children: [bar],
            width: SizeSpec.fixed(widthCols_));
        auto wt = b.finish(b.add(colW));
        auto ops = buildDisplayList(wt, layout(wt),
            themes[vm.themeIdx].effectivePalette, vm.pageFg, vm.pageBg);
        auto c = RaylibCanvas(&fonts, &buf, fonts.cellW(), fonts.cellH(),
            x, y);
        paint(c, ops);
    }


    int frame = 0;
    // What this target's input actually offers (IXB10/TGT5). This is the one
    // place the platform is named for interaction purposes: components ask the
    // capability, not the platform, so a hover-driven affordance degrades by
    // declaration instead of by a `version (Android)` at every site.
    version (Android)
        const InputCapabilities caps = touchPointer;
    else
        const InputCapabilities caps = mousePointer;

    // Touch interaction (Android): raylib maps the first touch to the mouse;
    // `sparkles:input`'s recogniser classifies those samples into taps,
    // drag-scrolls, long-presses and pinches; hue only consumes the result.
    // Desktop input is untouched — the helpers below are the only seam.
    version (Android)
    {
        import sparkles.input.gesture : GestureRecognizer, PointF;
        import sparkles.input.events : Gesture, GestureEvent, isNoEvent, match,
            NoEvent, PointerAction, PointerEvent, WheelEvent;

        // The recogniser is `sparkles:input`'s (IXB8): hue no longer classifies
        // taps, drags, flings, long-presses or pinches — it consumes what they
        // resolve to. The frame flags below are set purely by draining it.
        //
        // hue still POLLS raylib rather than consuming `RaylibEvents` (that is
        // IXB7/M17), so it drives the recogniser itself for now; the drain is
        // the same either way, which is what makes that later switch small.
        bool touchTap, touchLongPress;
        float touchPinch = 0;

        // A tap is the touch spelling of a click; a long-press starts a
        // selection (drag-extends via the existing machinery).
        //
        // KNOWN LIMITATION: a tap resolves on RELEASE, so the scrollbar thumb
        // drags never engage on touch — `isDragging` is set and cleared in the
        // same frame, because `IsMouseButtonReleased` is true then too. A tap
        // in the track still jumps the viewport via the track-click branch.
        // Fixing it needs a press-down seam distinct from "a tap happened",
        // which is what the shared scrollbar component (IXB1) will provide;
        // adding a second ad-hoc one here is what the component exists to stop.
        bool clickPressed() => touchTap;
        bool selectStartPressed() => touchLongPress;

        // The bottom toolbar's product policy: which segments exist and what
        // they do. The geometry, the hit test and the press contract are the
        // toolkit's `actionBar` + `PressState` (IXB9), so nothing here knows
        // where a segment sits.
        enum toolbarSegments = 5;

        // The hit-id block this bar owns. Segment i is `toolbarHitBase + i`;
        // an activation maps back by subtracting the base. Non-zero because
        // `0` is `hitId`'s "not hit-testable".
        enum size_t toolbarHitBase = 0x7B_00;

        // The press in flight over the bar, across frames: a press arms a
        // segment, a release over the SAME segment activates it (STM10).
        PressState toolbarPress;

        // The last segment is context-sensitive: with a live selection there
        // is otherwise NO touch route to copy it (a long-press-drag creates a
        // selection, and Ctrl-C is the only caller of copySelection), which
        // made the spec's "Copy … works" true only with a keyboard attached.
        bool hasSelection() =>
            (drag.regime == Regime.text && drag.selMax() > drag.selMin()) ||
            (drag.regime == Regime.table && drag.selTable >= 0);

        string[toolbarSegments] toolbarLabels() => [
            "◀ thm", "thm ▶", "view", "tree", hasSelection() ? "copy" : "ln №",
        ];
    }
    else
    {
        bool clickPressed() => inp.fin.leftPressed;
        bool selectStartPressed() => inp.fin.leftPressed;
    }

    // The frame clock (asyncLoop only): absolute deadlines, missed frames
    // skipped — the Ticker discipline, inline at the embedding hatch.
    import core.time : MonoTime;

    enum framePeriod = 1_000_000.usecs / 60;
    auto nextFrame = MonoTime.currTime + framePeriod;

    while (!window.shouldClose())
    {
        // Pace + pump: park in the ring until the frame deadline; any async
        // completions (subprocesses, watches, timers) dispatch during the
        // park. Raylib is sampled below as before — it no longer sleeps
        // (`targetFps: 0`), so the cadence belongs to event-horizon.
        if (asyncLoop)
            pumpUntilFrame(sched, nextFrame, framePeriod);

        // Gesture thresholds are PHYSICAL, so they track the cell size: a
        // pinch or Ctrl-± changes it, and values fixed before the loop would
        // misclassify after any zoom. Set before the drain, because the drain
        // is what advances the recogniser.
        inputSource.gestures.cfg.slopPx =
            fonts.cellH() / 2.0f > 8 ? fonts.cellH() / 2.0f : 8;
        inputSource.gestures.cfg.cellH = fonts.cellH();

        // Drain, then fold. `inp.fin` carries the button LEVEL across frames, which
        // an event stream reports only as transitions.
        evBuf.length = 0;
        inputSource.poll((Event e) { evBuf ~= e; }, 1, 1);
        keyBuf.length = 0;
        foreach (e; evBuf)
            e.match!((in KeyEvent k) { keyBuf ~= k; }, (in _) {});
        inp.fin = foldFrame(evBuf, inp.fin);

        // Live D types (`PRJ12`/`PRJ14`): drain the oracle's non-blocking
        // output. The lazy payload attaches to the open document (every hover
        // span gets its underline); each tip answer fills one node in place —
        // the popup is rebuilt from `vm.tw` every frame, so a resolved hover
        // simply appears, with no relayout.
        if (liveSession !is null)
        {
            liveSession.poll();
            if (liveSession.payloadReady)
            {
                vm.tw = liveSession.takePayload();
                vm.showPreview = true;
                vm.widthCols = -1; // force the relayout at an unchanged width
                relayout();
            }
            foreach (a; liveSession.takeAnswers())
                applyTip(vm.tw, a);
            if (liveSession.failed)
            {
                noteLive(liveSession.reason);
                stopLive();
            }
        }

        // `DVT1`: the diff's two side oracles. A payload that does not
        // describe its side is refused by `TypeOverlay.attach`, so a stale
        // one leaves that side plain rather than mis-anchored.
        foreach (i, sess; diffLive)
        {
            if (sess is null)
                continue;
            sess.poll();
            if (sess.payloadReady && i < vm.diffSides.length + 1
                && vm.diffTypes.length >= 1 && vm.diffSides.length >= 1)
            {
                const sideText = i == 0
                    ? vm.diffSides[0].oldText : vm.diffSides[0].newText;
                auto overlay = TypeOverlay.attach(sess.takePayload(), sideText);
                if (i == 0)
                    vm.diffTypes[0].old_ = overlay;
                else
                    vm.diffTypes[0].new_ = overlay;
                vm.widthCols = -1; // force the relayout at an unchanged width
                relayout();
            }
            if (sess.failed)
            {
                noteLive(sess.reason);
                sess.shutdown();
                diffLive[i] = null;
            }
        }

        const cellW = fonts.cellW();
        const cellH = fonts.cellH();
        const screenW = window.width;
        const screenH = window.height;
        // The same surface in the toolkit's unit: chrome that names cells
        // and edges (UIA2) rather than pixels reads these.
        const screenCols = screenW / cellW;
        const screenRows = screenH / cellH;
        const visibleRows = screenH / cellH;
        // With a set header bar, BOTH panes start under it (nothing hides
        // beneath the bar any more); the panes are docRows tall.
        const treeTopRows = set !is null && !set.empty ? 1 : 0;
        // Each pane renders the shared headerBar chrome on its first row
        // (title + focus indication — the same component the TUI paints),
        // and the CONTAINER reserved that row: these three come from the
        // frames it produced rather than from chrome arithmetic repeated
        // at every site that needed them (DCK10/DCK11).
        const docCells = paneContent(docPane);
        const docRows = docCells.height;
        const docY0 = docCells.y * cellH;
        const hdrY = (docCells.y - 1) * cellH;

        // Hoisted above the touch block on purpose: the Android toolbar's tap
        // handler lives there and must obey the SAME gate as the toolbar's
        // paint (which is `if (!inputMode)`), or the bar stays live while the
        // '/' search line covers it. `mode` is not written between here and
        // the block's old position, so this is a pure move.
        const inputMode = inp.mode != Mode.normal;

        // The bottom band the Android toolbar owns while it is drawn. Both
        // panes' horizontal scrollbars anchor above it, so one press cannot
        // be consumed by two handlers: their zone (`screenH - hIdleH - 4`)
        // otherwise sits INSIDE the toolbar row, they are evaluated first,
        // and the toolbar is drawn last — so a tap on `◀ thm` both started an
        // h-scroll drag and cycled the theme. (The general answer is IXB3's
        // pointer ownership in the shared workspace shell; this is the local
        // one until that lands.)
        version (Android)
            const int bottomChromeH = inputMode ? 0 : cellH;
        else
            const int bottomChromeH = 0;

        version (Android)
        {
            // The toolbar, built ONCE per frame (IXB9). The tap handler below
            // hit-tests these frames and the painter at the end of the loop
            // draws them — so "where is segment 3" has a single answer, where
            // it used to be `screenW / 5` computed independently at each end,
            // ~1200 lines apart (IXR27).
            //
            // `collapsed` while an input line owns the row: that one
            // assignment governs both paint and hit test, because
            // `hoverTargets` skips non-visible nodes. The old code needed the
            // `!inputMode` gate repeated at both ends and had it at only one.
            import sparkles.ui.geometry : SizeSpec;
            import sparkles.ui.widget : Builder, Visibility, Widget, WidgetKind;

            auto barB = Builder();
            const barLabels = toolbarLabels();
            const barRoot = actionBar(barB, barLabels[], toolbarHitBase,
                toolbarPress);
            if (inputMode)
                barB.nodes[barRoot].visibility = Visibility.collapsed;
            Widget barColW = Widget(kind: WidgetKind.column, children: [barRoot],
                width: SizeSpec.fixed(screenW / cellW));
            auto barTree = barB.finish(barB.add(barColW));
            auto barFrames = layout(barTree);
            const barTargets = hoverTargets(barTree, barFrames);
            // `toolbarY`, not `barY`: the input-line blocks below already own
            // that name for the same row.
            const toolbarY = screenH - cellH;

            // The gesture ANCHOR in the bar's cell space: a tap is a release
            // within the slop radius of its press, and slop can exceed half a
            // segment on a narrow screen, so the anchor is what was aimed at.
            Point barCell(in PointF p) => Point(
                cast(int)(p.x / cellW), cast(int)((p.y - toolbarY) / cellH));

            // hue no longer DRIVES a recogniser — `RaylibEvents` owns the one
            // in `sparkles:input`, and a second would recognise every gesture
            // twice. What remains here is hue's policy over resolved results.
            //
            // A tap is a press+release pair inside ONE drain, so the toolbar's
            // STM10 contract sees both edges of the same frame: a press that
            // travelled off its segment before release does not activate it
            // (IXB9). Positions carry the gesture ANCHOR — `RaylibEvents`
            // stamps it — so a tap acts where it began, not where slop left it.
            if (inp.fin.leftPressed || inp.fin.leftReleased)
            {
                const cell = barCell(inp.fin.pos);
                HoverState hh;
                hh.update(PointerEvent(action: PointerAction.move,
                    pos: cell), barTargets);
                if (inp.fin.leftPressed)
                    toolbarPress = toolbarPress.pressed(hh.hot);
                if (inp.fin.leftReleased)
                    toolbarPress = toolbarPress.released(hh.hot);
            }

            touchTap = inp.fin.leftPressed;
            touchLongPress = inp.fin.longPress;
            touchPinch = inp.fin.pinch;

            // Pinch → font size. Which gesture means "zoom", and by how much,
            // is hue's decision; that a pinch happened is the framework's.
            //
            // Fixed ±2 px steps: coarse, since the Android font size is
            // DPI-scaled (a 420 dpi panel puts it near 49 px, so a step is
            // ~4 %), and each pays a full atlas rebuild. Left alone until
            // pinch is exercised on hardware (AND6).
            if (touchPinch > 1)
                bumpFontSize(2);
            else if (touchPinch != 0 && touchPinch < 1)
                bumpFontSize(-2);

            // Drag/fling need no case of their own any more: the recogniser
            // resolves them to `WheelEvent`s on the shared stream, and the
            // wheel block above already routes those by the pane under
            // `inp.fin.pos` — which for a gesture IS the anchor, because
            // `RaylibEvents` stamps resolved events with it. One routing rule,
            // one code path, touch and wheel alike.

            // Which segments exist and what they do is hue's policy; that a
            // press on one of them activated is the toolkit's (IXB9). No
            // geometry here at all — and no `!inputMode` gate, because a
            // collapsed bar contributes no hit targets, so `activated` cannot
            // fire while an input line owns the row.
            if (toolbarPress.activated != 0)
            {
                switch (toolbarPress.activated - toolbarHitBase)
                {
                    case 0: applyTheme(vm.themeIdx == 0 ? themes.length - 1 : vm.themeIdx - 1); break;
                    case 1: applyTheme(vm.themeIdx + 1 == themes.length ? 0 : vm.themeIdx + 1); break;
                    case 2: toggleView(); break;
                    case 3: toggleExplorer(); break;
                    default:
                        if (hasSelection())
                            copySelection();
                        else
                        {
                            lineNumbers = !lineNumbers;
                            vm.widthCols = -1;
                            relayout();
                        }
                        break;
                }
                touchTap = false; // consumed — never reaches the panes
                toolbarPress = toolbarPress.cancelled();
            }

            // The system back button: close the explorer, else leave (the
            // activity finishes). A hover popup needs no case of its own —
            // it follows the pointer, and the pointer is wherever the last
            // tap landed, so tapping elsewhere already dismisses it.
            if (keyBuf.hasKey(Key.back))
            {
                if (pn.treeVisible)
                    toggleExplorer();
                else
                    break;
            }
        }


        // Reflow (both views wrap) when the window width in columns changes — but
        // debounced: only once the width has held steady for `settleFrames`
        // frames, so a drag that sweeps many widths re-wraps once at the end. While
        // the drag is in flight the (slightly stale) wrapped lines keep painting.
        const wc = widthCols();
        if (wc != vm.widthCols)
        {
            rd.settle = (wc == rd.prevWidthCols) ? rd.settle + 1 : 0;
            if (rd.settle >= ResizeDebounce.settleFrames)
                relayout();
        }
        rd.prevWidthCols = wc;
        // The one visual-line space (scroll/selection/search): the active
        // widget tree's rows, whichever view kind built it.
        const total = vm.rows.length;
        const maxTop = total > docRows ? cast(long)(total - docRows) : 0;
        const dhx = vm.hOverflows() ? cast(int) vm.hsb.offset : 0;

        // F11 toggles borderless fullscreen on the window's vm.current monitor;
        // active in any input mode. Reflow-on-resize keeps working because the
        // screen size changes.
        if (keyBuf.hasKey(Key.f11))
        {
            // The window owns the manoeuvre AND the saved geometry, and is a
            // no-op where the target has no fullscreen concept — which is what
            // stops this running on Android, where the surface is already the
            // screen and the dance had nothing to act on.
            window.toggleFullscreen();
        }

        // Hoisted out of the normal-mode branch below: the paint pass
        // enumerates the guide's items against the SAME context the keys
        // resolved through, so what the panel lists cannot disagree with what
        // a press would do.
        KeyContext kctx;

        if (pn.treeFocused && pn.tree.searching)
        {
            // The tree pane's live filter (broot mode): typed chars narrow
            // per keystroke; Enter keeps the filtered tree, Esc clears it.
            foreach (k; keyBuf)
                if (k.key == Key.char_ && k.ch != '/')
                    pn.tree.filterInput(k.ch);
            if (keyBuf.hasKey(Key.backspace))
                pn.tree.filterBackspace();
            if (keyBuf.hasKey(Key.enter))
                pn.tree.filterAccept();
            if (keyBuf.hasKey(Key.escape))
                pn.tree.filterCancel();
        }
        else if (inputMode)
        {
            // Typing a search query or a goto-line number.
            foreach (k; keyBuf)
            {
                if (k.key != Key.char_)
                    continue;
                const c = k.ch;
                if (c < 32 || c >= 127)
                    continue;
                if (inp.mode == Mode.gotoLine && (c < '0' || c > '9'))
                    continue;
                if (inp.query.length < 255)
                    inp.query ~= cast(char) c;
                if (inp.mode == Mode.search)
                    vm.search(inp.query[]);
            }
            if (keyBuf.hasKey(Key.backspace) && inp.query.length)
            {
                inp.query.popBack();
                if (inp.mode == Mode.search)
                    vm.search(inp.query[]);
            }
            if (keyBuf.hasKey(Key.enter))
            {
                if (inp.mode == Mode.search)
                {
                    // Jump to the first match whose visual row is at/after the
                    // vm.current vm.top (vm.matches are in source order → visual order), wrap.
                    size_t i;
                    while (i < vm.matches.length && vm.visualOfMatch(vm.matches[i]) < vm.top)
                        ++i;
                    jumpToMatch(i < vm.matches.length ? i : 0, visibleRows);
                }
                else if (inp.query.length) // gotoLine → the source line's visual row
                {
                    try
                    {
                        const n = inp.query[].to!long;
                        const line = cast(size_t)(n > 0 ? n - 1 : 0);
                        if (line < vm.lineStarts.length)
                            vm.revealOffset(vm.lineStarts[line]); // FLD6
                        vm.top = vm.visualOfSrc(line);
                    }
                    catch (Exception)
                    {
                    }
                }
                inp.mode = Mode.normal;
            }
            if (keyBuf.hasKey(Key.escape))
            {
                inp.mode = Mode.normal;
                inp.query.clear(); // cancelling clears the query (and search highlights)
                vm.matches = null;
            }
        }
        else
        {
            // Normal mode. The ~45 `IsKeyPressed` sites this replaced are now
            // one tested table (`keymap.commandFor`) plus one dispatch — and
            // the dispatch is a `final switch`, so the compiler proves every
            // command has an arm. Each arm's body is the original body,
            // unchanged; what moved is the DECISION, which is the part that
            // was untestable.
            // Set exactly where the original did — the tree arms below read
            // it through `clamp`, and they only fire with the tree focused.
            if (pn.treeFocused && pn.treeVisible)
                pn.tree.height = visibleRows;

            kctx = KeyContext(
                mode: InputMode.normal,
                treeFocused: pn.treeFocused,
                treeVisible: pn.treeVisible,
                hasMatches: vm.matches.length > 0,
                hasDocSet: set !is null && !set.empty && loadDoc !is null,
                // Only while the diff view is actually showing: Tab drops to
                // the raw patch text, where files are not a navigable unit.
                hasDiffSession: vm.showPreview && !vm.diffSession.empty,
                showPreview: vm.showPreview,
            );

            // The key sequence's delay runs on wall time, not a frame count:
            // `lantern` owns the pending path, and the panel's appearance must
            // not depend on how fast this machine renders.
            ltnTick(pn.lantern, dur!"msecs"(frameMs(window.frameSeconds)));

            foreach (kev; keyBuf)
            {
                // `lantern` owns the pending key path (`LTN2`): a prefix
                // descends and nothing runs, a leaf resolves. Only `execute`
                // reaches the dispatch below, so the arms are unchanged.
                const st = ltnStep(pn.lantern, kev, kctx);
                if (st.kind != LtnStepKind.execute)
                    continue;
                const kc = st.cmd;
                final switch (kc.cmd)
                {
                case Command.none:
                    break;

                case Command.toggleFullscreen:
                    break; // handled before the mode branches, with the window

                case Command.dismiss:
                    // Android's Back runs its chain before the mode branches,
                    // alongside the window handling — a second arm here would
                    // fire it twice, because `IsKeyPressed` reads per-frame
                    // state while `GetKeyPressed` drains a queue and both see
                    // the same press.
                    break;

                case Command.inputBackspace:
                case Command.inputAccept:
                case Command.inputCancel:
                    break; // unreachable in normal mode

                // ── explorer pane ────────────────────────────────────────
                case Command.treeDown:
                    ++pn.tree.sel;
                    pn.tree.clamp();
                    break;
                case Command.treeUp:
                    --pn.tree.sel;
                    pn.tree.clamp();
                    break;
                case Command.treePageDown:
                    pn.tree.sel += visibleRows;
                    pn.tree.clamp();
                    break;
                case Command.treePageUp:
                    pn.tree.sel -= visibleRows;
                    pn.tree.clamp();
                    break;
                case Command.treeHome:
                    pn.tree.sel = 0;
                    pn.tree.clamp();
                    break;
                case Command.treeEnd:
                    pn.tree.sel = cast(long) pn.tree.rows.length - 1;
                    pn.tree.clamp();
                    break;
                case Command.treeActivate:
                    activateTree();
                    break;
                case Command.treeRefresh:
                    pn.tree.refreshNow(); // XPF4
                    break;
                case Command.treeReroot:
                    pn.tree.rerootSel(); // XPF3
                    break;
                case Command.treeToggleIgnored:
                    pn.tree.toggleIgnored(); // XPF2
                    break;
                case Command.treeParent:
                    pn.tree.rerootParent(); // XPF3
                    break;
                case Command.treeNextChange:
                    pn.tree.jumpChange(1); // XPF1
                    break;
                case Command.treePrevChange:
                    pn.tree.jumpChange(-1); // XPF1
                    break;
                case Command.treeCloseAll:
                    pn.tree.closeAll(); // XPF3
                    break;
                case Command.treeToggleHidden:
                    pn.tree.toggleHidden(); // XPF2
                    break;
                case Command.treeCollapseOrUp:
                    // Close the selected dir, or jump to the parent row.
                    if (pn.tree.sel < cast(long) pn.tree.rows.length)
                    {
                        const node = pn.tree.rows[cast(size_t) pn.tree.sel].node;
                        const v = pn.tree.data.nodes[node].value;
                        if (v.isDir && pn.tree.open.isOpen(v.path))
                        {
                            pn.tree.open = pn.tree.open.closed(v.path);
                            pn.tree.rebuild();
                        }
                        else if (pn.tree.data.nodes[node].parent != uint.max)
                        {
                            const par = pn.tree.data.nodes[node].parent;
                            foreach (i, ref const r; pn.tree.rows)
                                if (r.node == par)
                                {
                                    pn.tree.sel = cast(long) i;
                                    break;
                                }
                            pn.tree.clamp();
                        }
                    }
                    break;
                case Command.treeFilter:
                    pn.tree.filterStart();
                    break;

                // ── viewer ───────────────────────────────────────────────
                case Command.viewDown:
                    ++vm.top;
                    break;
                case Command.viewUp:
                    --vm.top;
                    break;
                case Command.viewHome:
                case Command.viewTop:
                    vm.top = 0;
                    break;
                case Command.viewEnd:
                case Command.viewBottom:
                    vm.top = maxTop;
                    break;
                case Command.quit:
                    // The TUI has always had `q`; the GUI gains it here so one
                    // table describes both. The window close path is the same
                    // one `shouldClose` drives.
                    return 0;
                case Command.toggleHoverRegions:
                case Command.cycleHoverPopup:
                    // TUI-only affordances so far: the terminal has no pointer
                    // to name a twoslash signature run, so Enter opens the
                    // popup whole and `p` steps between them. The GUI reaches
                    // both with the mouse, so the keys resolve to nothing here
                    // rather than growing a second, worse spelling of hover.
                    break;
                case Command.viewPageDown:
                    vm.top += visibleRows;
                    break;
                case Command.viewPageUp:
                    vm.top -= visibleRows;
                    break;

                // ── shared, normal mode ──────────────────────────────────
                case Command.toggleExplorer:
                    toggleExplorer(); // XPL2
                    break;
                case Command.themeNext:
                    applyTheme(vm.themeIdx + 1 == themes.length ? 0 : vm.themeIdx + 1);
                    break;
                case Command.themePrev:
                    applyTheme(vm.themeIdx == 0 ? themes.length - 1 : vm.themeIdx - 1);
                    break;
                case Command.fontBigger:
                    bumpFontSize(2);
                    break;
                case Command.fontSmaller:
                    bumpFontSize(-2);
                    break;
                case Command.matchNext:
                    jumpToMatch(vm.curMatch + 1, visibleRows);
                    break;
                case Command.matchPrev:
                    jumpToMatch(vm.curMatch + vm.matches.length - 1, visibleRows);
                    break;
                case Command.setPrev:
                    if (set.move(-1))
                        loadSelected();
                    break;
                case Command.setNext:
                    if (set.move(1))
                        loadSelected();
                    break;
                case Command.setIndex:
                    pn.treeVisible = true;
                    pn.treeFocused = true;
                    vm.widthCols = -1;
                    relayout();
                    break;
                // The diff session (`DVG1`/`DVG3`): the model owns the
                // selection, the fold state and the scroll that follows them.
                case Command.diffNextFile:    vm.diffMoveFile(1);  break;
                case Command.diffPrevFile:    vm.diffMoveFile(-1); break;
                case Command.diffNextHunk:    vm.diffMoveHunk(1);  break;
                case Command.diffPrevHunk:    vm.diffMoveHunk(-1); break;
                case Command.diffToggleFile:  vm.diffToggleFile(); break;
                case Command.diffCollapseAll: vm.diffSetAllFiles(true); break;
                case Command.diffExpandAll:   vm.diffSetAllFiles(false); break;
                case Command.diffToggleStructural:
                    vm.diffToggleStructural();
                    break;
                case Command.diffToggleFormatting:
                    vm.diffToggleFormatting();
                    break;
                case Command.diffToggleLayout:
                    vm.diffToggleLayout();
                    break;
                case Command.diffToggleContext:
                    vm.diffToggleContext();
                    break;
                case Command.diffToggleGap:
                    vm.diffToggleGapNearCursor();
                    break;
                case Command.toggleView:
                    toggleView();
                    break;
                case Command.copySelection:
                    copySelection();
                    break;
                case Command.toggleLineNumbers:
                    lineNumbers = !lineNumbers;
                    vm.widthCols = -1; // gutter width changed → reflow
                    relayout();
                    break;
                case Command.toggleCodeLineNumbers:
                    codeLineNumbers = !codeLineNumbers;
                    vm.codeLineNumbers = codeLineNumbers;
                    vm.widthCols = -1;
                    relayout();
                    break;
                case Command.toggleAnsiCopy:
                    cm.ansiStrip = !cm.ansiStrip;
                    flash.copyModeMsg = cm.ansiStrip ? "ansi-copy: strip" : "ansi-copy: raw";
                    flash.toast = Timeline.triggered(toastCfg);
                    break;
                case Command.toggleTableCopy:
                    cm.tableFmt = cm.tableFmt == TableCopyFormat.tsv
                        ? TableCopyFormat.markdown : TableCopyFormat.tsv;
                    flash.copyModeMsg = cm.tableFmt == TableCopyFormat.tsv
                        ? "table-copy: tsv" : "table-copy: markdown";
                    flash.toast = Timeline.triggered(toastCfg);
                    break;
                case Command.startSearch:
                    inp.mode = Mode.search;
                    inp.query.clear();
                    vm.matches = null;
                    break;
                case Command.startGoto:
                    inp.mode = Mode.gotoLine;
                    inp.query.clear();
                    break;
                case Command.lanternAll:
                    // `lantern` shows the panel itself and never hands this
                    // one out as a command to run.
                    break;

                // ── the `z` fold sequence (FLD5) ─────────────────────────
                case Command.foldToggle:
                    foldAtCursor(ViewerModel.FoldOp.toggle);
                    break;
                case Command.foldClose:
                    foldAtCursor(ViewerModel.FoldOp.close);
                    break;
                case Command.foldOpen:
                    foldAtCursor(ViewerModel.FoldOp.open);
                    break;
                case Command.foldOpenAll:
                    vm.setAllFolds(false);
                    break;
                case Command.foldCloseAll:
                    vm.setAllFolds(true);
                    break;
                case Command.foldLevel:
                    vm.foldToLevel(kc.arg); // z1–z9, vim's foldlevel
                    break;
                }
            }

            // ── not keyboard, so not the keymap's business ───────────────

            // The wheel scrolls the pane under the cursor (tree or document).
            // High-resolution wheels deliver FRACTIONAL deltas; accumulate to
            // whole rows so gentle scrolling is never truncated to nothing.
            // The producer owns BOTH the notch→cells multiplication (INP12)
            // and the fractional accumulation (M14's `wheelSteps`), so hue's
            // own accumulator is gone: multiplying again here is precisely the
            // double-scaling `frame_input`'s wheel test pins.
            //
            // The sign also moves with it. `GetMouseWheelMove` is POSITIVE
            // scrolling up; `WheelEvent.dy` follows the web's `deltaY`, where
            // up is NEGATIVE. So the two subtractions below become additions —
            // the same direction, expressed against the other convention.
            if (inp.fin.wheelCells != 0)
            {
                // WHERE a wheel goes is the container's (DCK7): the pane
                // under the pointer, regardless of focus, with chrome
                // falling back to the focused pane so a notch is never
                // dropped. What scrolling MEANS is still the pane's.
                const wheelRoute = pn.dock.handle(Event(WheelEvent(
                    dy: inp.fin.wheelCells,
                    pos: pointerFor(inp.fin, cellW, cellH).pos)));
                if (wheelRoute.kind == RouteKind.pane)
                {
                    if (wheelRoute.pane == treePane)
                        pn.tree.scrollBy(inp.fin.wheelCells);
                    else
                        vm.top += inp.fin.wheelCells;
                }
            }

            // The mouse back/forward buttons walk the document set regardless
            // of which pane has focus — the keyboard's `[`/`]` are focus
            // dependent and go through the keymap above.
            if (set !is null && !set.empty && loadDoc !is null)
            {
                const back = inp.fin.backPressed;
                const fwd = inp.fin.forwardPressed;
                if ((back || fwd) && set.move(back ? -1 : 1))
                    loadSelected();
            }
        }

        // The pane divider (STM8): hovering it shows the resize cursor; a
        // grab drags the split live. The drag owns the pointer, so nothing
        // below starts a selection or a scrollbar drag mid-resize.
        // One release frees the pointer for everyone (STM11). Central on
        // purpose: a per-affordance release is how a capture leaks — the one
        // that forgets leaves the pointer owned and every other affordance
        // dead until the process restarts.
        if (inp.fin.leftReleased)
            inp.capture = inp.capture.released();

        // The pane arrangement, and the divider drag inside it, belong to
        // the container (DCK3). This host reads a polled pointer rather
        // than an event queue, so it synthesises the one event the
        // container needs — in cells, its unit — and lets the routing
        // decide. A frame the container consumed is a frame the panes'
        // own affordances sit out, which is how the divider drag keeps
        // the pointer without any of them naming it.
        arrangePanes();
        const dockRoute = pn.dock.handle(
            Event(pointerFor(inp.fin, cellW, cellH)));
        if (dockRoute.relayout)
            arrangePanes(); // the width change reflows via the debounce
        // The container owns the pointer during a divider drag. Mirror that
        // into the pane-level machine so every affordance's existing
        // `available` gate still sees a busy pointer — one ownership fact,
        // asked at two levels, instead of a second negation chain. The
        // central release above frees it.
        if (dockRoute.kind == RouteKind.container)
            inp.capture = inp.capture.capturedBy(capContainer);

        // Interactive scrollbar (hover-expand + thumb grab + track jump):
        // the ONE STM9 machine in px track units (a thumb press grabs in
        // place, a track press jumps the leading edge — the shared
        // semantics), with the hover-expand width eased per frame.
        {
            // Both widths scale with the font: the expanded (hover) handle equals
            // the reserved scrollbar gutter (1.5 cells) so it fills the gutter
            // without overlapping text; the idle rail is a thin ~⅓ cell.
            const float hoverW = cast(float) scrollbarGutter();
            const float idleW = cellW / 3.0f < 2.0f ? 2.0f : cellW / 3.0f;
            const pos = inp.fin.pos;
            const docVLive = maxTop > 0;
            inp.capture = vm.scroll.stepV(inp.capture, capDocSb, docVLive,
                ScrollPointer(over: pos.x >= screenW - hoverW,
                    pressed: clickPressed(), released: inp.fin.leftReleased,
                    trackPos: cast(int)(pos.y - docY0)),
                vm.top,
                ScrollExtents(total, docRows, cast(int)(screenH - docY0),
                    minExtent: 24));
            if (docVLive)
                vm.top = vm.scroll.v.offset;
            vm.scroll.easeV(hoverW, idleW, caps, window.frameSeconds);
        }

        // The tree pane's scrollbar — the SAME hover-expand behavior as the
        // document's (one affordance, two panes): animated width, faint track
        // on hover, draggable thumb, track click centers.
        pn.tree.height = visibleRows - treeTopRows - 1; // − the header row
        const treePaneRows = pn.tree.bodyRows;
        const treeMaxTop = cast(long) pn.tree.rows.length - treePaneRows;
        {
            const float hoverW = cast(float) scrollbarGutter();
            const float idleW = cellW / 3.0f < 2.0f ? 2.0f : cellW / 3.0f;
            const trackTop = (treeTopRows + 1) * cellH;
            const pos = inp.fin.pos;
            const edge = treeCols * cellW;
            const treeVLive = pn.treeVisible && treeMaxTop > 0
                && treePaneRows > 0;
            inp.capture = pn.tree.scroll.stepV(inp.capture, capTreeSb,
                treeVLive,
                ScrollPointer(over: pos.x >= edge - hoverW && pos.x < edge
                        && pos.y >= trackTop,
                    pressed: clickPressed(), released: inp.fin.leftReleased,
                    trackPos: cast(int)(pos.y - trackTop)),
                pn.tree.top,
                ScrollExtents(pn.tree.rows.length, treePaneRows,
                    cast(int)(screenH - trackTop), minExtent: 24));
            if (treeVLive)
            {
                pn.tree.top = pn.tree.scroll.v.offset;
                pn.tree.scrollBy(0); // clamp
                pn.tree.scroll.easeV(hoverW, idleW, caps,
                    window.frameSeconds);
            }
        }

        // The one pointer-shape decision, composed by the container
        // (DCK9) from its dividers and the shapes this host's panes want:
        // live grabs outrank hover — a scrollbar drag straying over the
        // divider stays ns-resize, a divider drag stays ew-resize — then
        // hover by orientation, else the default arrow. The terminal host
        // composes the identical result and writes it as OSC 22.
        PointerShape paneGrab()
        {
            if (vm.scroll.grabbing)
                return vm.scroll.shape();
            if (pn.tree.scroll.grabbing)
                return pn.tree.scroll.shape();
            return PointerShape.default_;
        }

        PointerShape paneHover()
        {
            const v = vm.scroll.shape();
            return v != PointerShape.default_ ? v : pn.tree.scroll.shape();
        }

        window.pointerShape(pn.dock.shape(paneGrab(), paneHover()));

        vm.top = vm.top < 0 ? 0 : (vm.top > maxTop ? maxTop : vm.top);
        const topLine = cast(size_t) vm.top;

        // M16: every input block runs BEFORE the frame draws — the
        // painter renders the post-input state (one frame less input
        // latency, and the M17 event drain slots in here wholesale).
        // One-cell background padding on the left, the scrollbar gutter on the
        // right, plus the optional line-number gutter; text starts at `contentX`.
        const padX = cellW;
        const rightPad = scrollbarGutter();
        const gcols = gutterCols();
        // Text starts after the tree pane (when visible), the 1-cell left
        // padding, and the line-number gutter.
        const gutterPx = treePx() + padX + gcols * cellW;


        // The ✔ glyph lives in the widget tree: rebuild when the flash ends so
        // the header reverts to the copy affordance.
        if (flash.copiedShown && !flash.copiedFlash.visible)
        {
            flash.copiedShown = false;
            vm.copiedFenceSrc = size_t.max;
            vm.rebuild();
        }

        bool copyClicked; // a click landing on a copy button is not a selection

        // The fence copy affordance: the header band is the hit target (its
        // source-anchored id resolves the fence body); a click copies and the
        // ✔ glyph — part of the widget tree — holds for the flash duration.
        // (Views without hit targets — raw, twoslash — have an empty list.)
        {
            const mp = inp.fin.pos;
            const dp = Point(cast(int)((mp.x - gutterPx) / cellW) + dhx,
                cast(int)(vm.top + cast(long)((mp.y - docY0) / cellH)));
            // The fold column: a click on a marker toggles its region.
            if (mp.x >= treePx() && mp.x < treePx() + cellW
                && clickPressed())
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
            if (mp.x >= gutterPx && clickPressed())
                foreach_reverse (ref const tgt; vm.targets)
                {
                    if (tgt.hitId >= vm.foldHitBase && tgt.rect.contains(dp))
                    {
                        vm.folds = vm.folds.toggled(tgt.hitId - vm.foldHitBase);
                        vm.rebuild();
                        copyClicked = true; // not a selection either
                        break;
                    }
                    // Ordered by range, highest base first: a code-group
                    // tab's ids sit BELOW the fence ids, so this test must
                    // follow them or it would swallow every fence hit.
                    if (tgt.hitId >= vm.codeTabHitBase
                        && tgt.hitId < vm.fenceHitBase
                        && tgt.rect.contains(dp))
                    {
                        vm.activateCodeTab(tgt.hitId - vm.codeTabHitBase);
                        copyClicked = true; // not a selection either
                        break;
                    }
                    if (tgt.hitId >= vm.fenceHitBase && tgt.rect.contains(dp))
                    {
                        const bodyStart = tgt.hitId - vm.fenceHitBase;
                        foreach (ref const f; vm.fences)
                            if (f.body.start == bodyStart
                                && f.body.end <= vm.source.length)
                            {
                                // vm.source, not the launch-time `source`
                                // parameter: the fence offsets belong to the
                                // DISPLAYED document (explorer/set navigation
                                // rebinds it).
                                auto fbody = vm.source[f.body.start .. f.body.end];
                                // Match the selection copy mode (SEL7).
                                const txt = (cm.ansiStrip && f.isAnsi)
                                    ? stripSgr(fbody) : fbody;
                                copyToClipboard(txt);
                                vm.copiedFenceSrc = bodyStart;
                                flash.copiedFlash = Timeline.triggered(copiedCfg);
                                flash.copiedShown = true;
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
            const cx = cast(int)((mx - gutterPx) / cellW) + dhx;
            const cy = vm.top + cast(long)((my - docY0) / cellH);
            if (mx < gutterPx || cy < 0 || cy >= cast(long) vm.rows.length)
                return h; // left of the content (tree/gutter) hits nothing
            const p = Point(cx, cast(int) cy);
            const off = sourceOffsetAt(vm.tree, vm.frames, p);
            // Inside a keyed table cell: a grid hit (2-D drag.regime anchor),
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
            const mp = inp.fin.pos;
            const overSb = mp.x >= screenW - scrollbarGutter();
            const overTree = pn.treeVisible && mp.x < treeCols * cellW;
            // The pane's scrollbar strip is NOT a row: without this gate a
            // scrollbar click also row-selects, and a double click "re-hits"
            // the row under the cursor and opens it.
            const overTreeSb = overTree && treeMaxTop > 0
                && mp.x >= treeCols * cellW - scrollbarGutter();
            // The document pane's horizontal bar (IXB2): same pattern.
            {
                const float hHoverH2 = cast(float) scrollbarGutter();
                const float hIdleH2 = cellH / 3.0f < 2.0f ? 2.0f : cellH / 3.0f;
                const live = vm.hOverflows() && inp.mode == Mode.normal;
                const over = live && mp.x >= gutterPx
                    && mp.y >= screenH - bottomChromeH
                        - (vm.hsb.expanded(caps) ? hHoverH2 : hIdleH2) - 4
                    && mp.y < screenH - bottomChromeH;
                inp.capture = vm.scroll.stepH(inp.capture, capDocHSb, live,
                    ScrollPointer(over: over, pressed: clickPressed(),
                        released: inp.fin.leftReleased,
                        trackPos: cast(int)((mp.x - gutterPx) / cellW)),
                    vm.hsb.offset,
                    ScrollExtents(vm.contentCols, vm.widthCols, vm.widthCols));
                vm.scroll.easeH(hHoverH2, hIdleH2, caps, window.frameSeconds);
            }

            // The tree's horizontal bar (IXB2): the pane's bottom edge,
            // with the SAME hover-expand animation as the vertical bars
            // (the drag itself runs the shared STM9 machine).
            const float hHoverH = cast(float) scrollbarGutter();
            const float hIdleH = cellH / 3.0f < 2.0f ? 2.0f : cellH / 3.0f;
            const hLive = pn.tree.hOverflows() && !pn.tree.searching;
            const overHBar = hLive && overTree
                && mp.y >= screenH - bottomChromeH
                    - (pn.tree.hsb.expanded(caps) ? hHoverH : hIdleH) - 4
                && mp.y < screenH - bottomChromeH;
            inp.capture = pn.tree.scroll.stepH(inp.capture, capTreeHSb, hLive,
                ScrollPointer(over: overHBar, pressed: clickPressed(),
                    released: inp.fin.leftReleased,
                    trackPos: cast(int)(mp.x / cellW)),
                pn.tree.hsb.offset,
                ScrollExtents(pn.tree.contentCols, treeCols - 1,
                    treeCols - 1));
            pn.tree.scroll.easeH(hHoverH, hIdleH, caps, window.frameSeconds);
            // A row click is not a drag, so it takes no id — it only needs
            // the pointer to be unowned. Focus is NOT set here: the press
            // already moved it to the pane it landed in, which is the
            // container's click-to-focus (DCK6).
            if (overTree && !overTreeSb && !overHBar && inp.capture.isFree
                && clickPressed())
            {
                // The container answers which of the pane's CONTENT cells
                // this is (DCK11) — the row cannot drift from the header
                // above it, and a screenshot could never have told us if
                // it had.
                Point tcell;
                const inTree = pn.dock.contentCell(
                    pointerFor(inp.fin, cellW, cellH).pos, treePane, tcell);
                const row = pn.tree.top + tcell.y;
                if (inTree && row >= 0 && row < cast(long) pn.tree.rows.length)
                {
                    const again = row == pn.tree.sel;
                    pn.tree.sel = row;
                    pn.tree.clamp();
                    if (again)
                        activateTree();
                }
            }
            // A click on a collapsed `\u2026` in the open popup opens that one run.
            // The popup's geometry is last frame's, which is what the reader
            // aimed at; keys are cell-relative to the box.
            bool popupClicked;
            if (pop.havePopup && pop.popupKeys.length && clickPressed()
                && mp.x >= pop.hotPopup.x && mp.x <= pop.hotPopup.x + pop.hotPopup.width
                && mp.y >= pop.hotPopup.y && mp.y <= pop.hotPopup.y + pop.hotPopup.height)
            {
                popupClicked = true; // never a selection, hit or miss
                const k = keyAt(pop.popupKeys,
                    Point(cast(int)((mp.x - pop.hotPopup.x) / cellW),
                        cast(int)((mp.y - pop.hotPopup.y) / cellH)));
                if (k != 0)
                {
                    const r = abbrevRegion(k);
                    pop.expandedRegions[r] = !pop.expandedRegions.get(r, false);
                }
            }
            // Levels, not edges — see `RaylibEvents.modifiers`.
            const shiftMod = inputSource.modifiers.shift;
            const altMod = inputSource.modifiers.alt;
            // The five-term negation chain this replaces was the clearest
            // instance of the allow-list defect: every new draggable had to be
            // added here, and to every other affordance's condition. A popup
            // click is not a draggable — it consumes the press outright.
            if (selectStartPressed() && !overSb && !overTree && !copyClicked
                && !popupClicked && inp.capture.available(capSelection))
            {
                const h = hitAt(mp.x, mp.y);
                drag.selecting = h.ok;
                if (drag.selecting)
                    inp.capture = inp.capture.capturedBy(capSelection);
                if (h.table)
                {
                    drag.regime = Regime.table;
                    drag.selTable = h.tableIdx;
                    drag.tblAnchor = drag.tblHead = h.cell;
                    drag.tblShift = drag.tblAlt = false;
                }
                else if (h.ok)
                {
                    drag.regime = Regime.text;
                    drag.anchorLo = drag.headLo = h.lo;
                    drag.anchorHi = drag.headHi = h.hi;
                }
                else
                    drag.regime = Regime.none;
            }
            if (drag.selecting && inp.fin.leftDown)
            {
                const h = hitAt(mp.x, mp.y);
                if (drag.regime == Regime.table && h.table && h.tableIdx == drag.selTable)
                {
                    drag.tblHead = h.cell;
                    drag.tblShift = shiftMod;
                    drag.tblAlt = altMod;
                }
                else if (drag.regime == Regime.text && h.ok)
                {
                    // Extend over anything with a source span — including a table
                    // line's block span, so a drag from outside sweeps across it.
                    drag.headLo = h.lo;
                    drag.headHi = h.hi;
                }
            }
            if (inp.fin.leftReleased)
                drag.selecting = false;
        }


        window.beginFrame();
        // The chrome fills below go through the backend adapter, not raylib
        // (UIA7). Pixel-space because hue's chrome is pixel-positioned — a
        // 1 px divider, a `cellH - 1` band — and quantising to cells would
        // move it. Chrome that can become a widget should (UIA2); this is the
        // seam for what has not yet.
        auto chrome = RaylibCanvas(&fonts, &buf, cellW, cellH);
        // GL scissor state is global; a scissor leaked from any earlier path
        // (or left over across the buffer swap) would CLIP the clear below —
        // exactly the "documents ghost over each other" failure. Start every
        // frame from a clean state so the clear always covers the window.
        window.resetClip();
        if (flashDebug)
            window.clear((frame / 30) % 2 == 0
                ? RgbColor(70, 20, 20) : RgbColor(20, 20, 70));
        else
        {
            window.clear(vm.pageBg);
            // Panes own their background: an explicit fill over the document
            // region every frame, so its pixels never depend on the clear
            // alone (the tree pane and header fill their own rects).
            chrome.fillPixels(treePx(), 0, screenW - treePx(), screenH, vm.pageBg);
        }

        // The gutter strip (the fold column + line numbers) sits on its own
        // theme-derived band, visually distinct from the document.
        if (!flashDebug)
            chrome.fillPixels(treePx(), docY0, gutterPx - treePx(),
                screenH - docY0, vm.gutterBg);

        // The document pane's header — the SHARED chrome (headerBar +
        // Slot.chromeFocused + bold title), same look as the TUI's.
        {
            import std.conv : text;

            drawChromeBar(treePx(), hdrY, (screenW - treePx()) / cellW,
                vm.title,
                text(names[vm.themeIdx], " · ",
                    vm.showPreview ? "preview" : "raw"),
                text(vm.top + 1, "/", total),
                focused: !pn.treeFocused || !pn.treeVisible);
        }

        // The one painter: the active tree's precomputed ops through the
        // raylib canvas, offset by the scroll position and culled to the
        // viewport rows (raylib clips px; the cull skips dead draw calls).
        {
            auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                cast(float)(gutterPx - dhx * cellW),
                cast(float)(docY0 - vm.top * cellH));
            // The pane's base clip: content (an unwrappable code line inside
            // a fence, a wide table) never bleeds past the pane or under the
            // header — the same rule the tree pane follows.
            canvas.pushClip(Rect(dhx, cast(int) vm.top,
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

            // Fold markers in the gutter's fold column (FLD5): ▾ on an
            // open region's first row, ▸ on a folded one's placeholder;
            // click toggles. The placeholder itself renders unobstructed —
            // its inline marker is disabled (inlineFoldMarker: false), so
            // the column is the one fold affordance.
            foreach (ref const fm; vm.foldMarkers)
            {
                if (fm.row < topLine || fm.row >= topLine + docRows)
                    continue;
                drawText(fonts, cstrOf(buf, fm.open ? "▾" : "▸"),
                    cast(float)(treePx() + 2),
                    docY0 + (fm.row - topLine) * cast(float) cellH,
                    TextStyle(0), vm.gutterFg);
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
                        docY0 + row * cast(float) cellH, TextStyle(0), vm.gutterFg);
                }
            }
        }

        flash.copiedFlash = flash.copiedFlash.stepped(frameMs(window.frameSeconds), copiedCfg);
        // Selection highlight — a translucent tint. `tintRow` takes content columns
        // (0 = the content origin, i.e. after `gutterPx`).
        void tintRow(long screenRow, int xStartCol, int xEndCol)
        {
            if (screenRow < 0 || screenRow >= docRows || xEndCol <= xStartCol)
                return;
            // Content-anchored and whole-cell, so it says so: the gutter
            // and the first document row are both cell multiples (UIA2).
            chrome.fillRect(Rect(gutterPx / cellW + xStartCol,
                cast(int)(docY0 / cellH + screenRow),
                xEndCol - xStartCol, 1),
                Visual(bg: vm.quoteBars[1], bgAlpha: 80, hasBg: true));
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
        if (drag.regime == Regime.text && drag.selMax() > drag.selMin())
            // One pass covers prose, code and table cells alike — every
            // span with source identity inside [smin, smax) tints.
            tintSrcRange(drag.selMin(), drag.selMax());
        else if (drag.regime == Regime.table && drag.selTable >= 0)
        {
            const dims = vm.tableDims(drag.selTable);
            const reg = tableSelection(drag.tblAnchor, drag.tblHead, drag.tblShift, drag.tblAlt,
                dims.rows, dims.cols);
            foreach (ref const mc; vm.cellList)
            {
                if (mc.table != drag.selTable)
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
                    const t = i == vm.curMatch ? currentMatchTint : matchTint;
                    chrome.fillRect(Rect(gutterPx / cellW + r.x,
                        cast(int)(docY0 / cellH + row), r.width, 1),
                        Visual(bg: t.rgb, bgAlpha: t.alpha, hasBg: true));
                }

        // Twoslash hover: pointer → byte (the identity channel) → hover node;
        // the token's dotted underline fades in and the popup (the shared
        // viewHoverPopup chrome via drawPopup) draws on vm.top, with pointer
        // hysteresis so moving down into the open popup keeps it open.
        if (vm.showPreview && vm.tw.code.length && tsCache !is null)
        {
            const mp = inp.fin.pos;
            size_t overNode = 0;
            if (mp.x >= gutterPx)
            {
                const off = sourceOffsetAt(vm.tree, vm.frames,
                    Point(cast(int)((mp.x - gutterPx) / cellW) + dhx,
                        cast(int)(vm.top + cast(long)((mp.y - docY0) / cellH))));
                if (off >= 0)
                    foreach (ni, ref const n; vm.tw.nodes)
                        if (n.type == NodeType.hover && off >= cast(long) n.start
                            && off < cast(long)(n.start + n.length))
                            overNode = ni + 1;
            }
            if (overNode == 0 && pop.hotNode != 0 && pop.havePopup
                && mp.x >= pop.hotPopup.x && mp.x <= pop.hotPopup.x + pop.hotPopup.width
                && mp.y >= pop.hotPopup.y && mp.y <= pop.hotPopup.y + pop.hotPopup.height)
                overNode = pop.hotNode; // still over the open popup → keep it open
            bool forced = false;
            if (pop.forceHover >= 0)
            {
                int seen = 0;
                foreach (ni, ref const n; vm.tw.nodes)
                    if (n.type == NodeType.hover && seen++ == pop.forceHover)
                    {
                        overNode = ni + 1;
                        forced = true;
                        break;
                    }
            }
            if (overNode != pop.hotNode)
                pop.fade = Timeline.init;
            pop.hotNode = overNode;
            // A lazy span (underlined, no text yet) resolves on demand: ask the
            // oracle for this node's tip. The request is deduped per node, so
            // holding the pointer still costs one round trip (~0.6 ms warm);
            // the popup stays empty until the answer lands a frame or two later.
            if (liveSession !is null && pop.hotNode != 0
                && !vm.tw.nodes[pop.hotNode - 1].text.length)
                liveSession.requestTip(pop.hotNode - 1);
            if (pop.hotNode != 0)
            {
                if (!pop.fade.visible)
                    pop.fade = Timeline.triggered(fadeCfg);
                pop.fade = forced ? Timeline(Timeline.Phase.hold, 0)
                    : pop.fade.stepped(frameMs(window.frameSeconds), fadeCfg);
            }
            pop.havePopup = false;
            if (pop.hotNode != 0)
            {
                // The token's geometry through the identity channel.
                const n = vm.tw.nodes[pop.hotNode - 1];
                auto rects = selectionRects(vm.tree, vm.frames,
                    n.start, n.start + n.length);
                if (rects.length)
                {
                    const r = rects[0];
                    const hx = gutterPx + r.x * cellW;
                    const hy = cast(int)(docY0 + (r.y - vm.top) * cellH);
                    const hw = r.width * cellW;
                    const uy = hy + cellH - 2;
                    // The hot token's emphasis stroke: the same hue as the
                    // always-on `Slot.hoverUnderline` marker under every hover
                    // span, but at the fade's full strength so the pointed-at
                    // token stands out from its neighbours.
                    const uv = resolveSlot(
                        defaultTwoslashPalette(schemeForBackground(vm.pageBg)),
                        Slot.hoverUnderline, vm.pageFg, vm.pageBg);
                    const ua = cast(ubyte)(pop.fade.alphaPercent(fadeCfg) * 255 / 100);
                    for (int i = 0; i + 2 <= hw; i += 4)
                        chrome.fillPixels(hx + i, uy, 2, 1, uv.fg, ua);
                    // Room from the anchor to the document pane's right edge,
                    // in cells — the popup is capped to it and, failing that,
                    // slid left inside it.
                    const availCells = (screenW - cast(int) rightPad - hx) / cellW;
                    // A different token is a different question: drop what the
                    // last popup had opened.
                    if (pop.popupNode != pop.hotNode)
                    {
                        pop.expandedRegions = null;
                        pop.popupNode = pop.hotNode;
                    }
                    pop.hotPopup = drawPopup(fonts, buf, vm.tw, pop.hotNode - 1,
                        cast(float) hx, cast(float)(hy + cellH),
                        cellW, cellH, vm.current, *tsCache,
                        defaultTwoslashPalette(schemeForBackground(vm.pageBg)),
                        vm.pageFg, vm.pageBg, availCells,
                        pop.expandedRegions, pop.popupKeys);
                    // Zero width ⇒ a lazy node drew no popup (nothing to keep
                    // the pointer inside yet).
                    pop.havePopup = pop.hotPopup.width > 0;
                }
            }
        }

        // The explorer pane (XPL2): the tree's widget view painted through
        // RaylibCanvas at the window's left edge, viewport-sliced, with a
        // hairline divider. The whole pane clips at its own width.
        if (pn.treeVisible && pn.tree.git.poll())
            pn.tree.rebuild(); // a finished async git refresh paints this frame
        if (pn.treeVisible)
        {
            pn.tree.height = visibleRows - treeTopRows - 1; // − the header row
            pn.tree.width = treeCols; // the shared overflow check uses it
            pn.tree.scrollBy(0); // bounds only — never yank the view to the cursor
            chrome.fillPixels(0, 0, treeCols * cellW, screenH, mix(vm.pageBg, vm.pageFg, 0.03));
            // The divider rule, in the toolkit's vocabulary (UIA2): hue
            // names the column and the edge, the backend decides how thin a
            // hairline is on this display.
            chrome.rule(Rect(treeCols, 0, 1, screenRows),
                RuleEdge.centerX, Visual(fg: vm.gutterFg));

            // The explorer pane's header — the shared chrome, focused when
            // the tree holds the input focus.
            {
                import std.conv : text;
                import std.path : baseName;

                drawChromeBar(0, hdrY, treeCols, baseName(pn.tree.root),
                    null,
                    text(pn.tree.rows.length ? pn.tree.sel + 1 : 0, "/",
                        pn.tree.rows.length),
                    focused: pn.treeFocused);
            }

            import sparkles.ui.geometry : SizeSpec;
            import sparkles.ui.widget : Builder, Widget, WidgetKind;

            auto tb = Builder();
            const tFirst = cast(size_t) pn.tree.top;
            const tLast = tFirst + visibleRows > pn.tree.rows.length
                ? pn.tree.rows.length : tFirst + visibleRows;
            const selNode = pn.tree.sel < cast(long) pn.tree.rows.length
                ? pn.tree.rows[cast(size_t) pn.tree.sel].node : uint.max;
            const tv = treeView(tb, pn.tree.data, pn.tree.rows[tFirst .. tLast],
                (uint i) @safe => pn.tree.open.isOpen(pn.tree.data.nodes[i].value.path),
                selNode, explorerGlyphs, pn.tree.selBg, hasSelectionBg: true);
            Widget paneW = Widget(kind: WidgetKind.column, children: [tv],
                width: SizeSpec.fixed(treeCols), clipX: true);
            auto wt = tb.finish(tb.add(paneW));
            auto tOps = buildDisplayList(wt, layout(wt),
                themes[vm.themeIdx].effectivePalette, vm.pageFg, vm.pageBg);
            const thx = pn.tree.hOverflows() ? cast(int) pn.tree.hsb.offset : 0;
            auto tCanvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                cast(float)(-thx * cellW), cast(float)((treeTopRows + 1) * cellH));
            tCanvas.pushClip(Rect(thx, 0, treeCols - thx, pn.tree.bodyRows));
            paint(tCanvas, tOps);
            tCanvas.popClip();

            // The horizontal bar (IXB2): the pane's bottom edge — the same
            // animated-height thumb + hover track as the vertical bars, in
            // the pane's theme tint; the offset comes from the STM9 machine
            // (hidden while the filter line owns the row).
            if (pn.tree.hOverflows() && !pn.tree.searching)
            {
                const l = scrollbarLayout(pn.tree.hsb, pn.tree.scroll.hAnim,
                    pn.tree.contentCols, treeCols - 1,
                    Rect(0, 0, treeCols * cellW, screenH));
                drawScrollbar(l, pn.tree.hsb, pn.tree.sbTrack, pn.tree.sbThumb);
            }

            // The live-filter input line, pinned to the pane's bottom row
            // (the GUI pane has no status bar; the TUI shows it there).
            if (pn.tree.searching)
            {
                const barY = screenH - cellH;
                chrome.fillPixels(0, barY, treeCols * cellW, cellH, vm.gutterFg);
                buf.clear();
                buf ~= "/";
                buf ~= pn.tree.filterQuery;
                buf ~= "▏\0";
                drawText(fonts, buf[][0 .. $ - 1], 4, cast(float) barY,
                    TextStyle(0), vm.pageBg);
            }

            // The pane's scrollbar: the same animated-width thumb + hover
            // track as the document's, in the pane's theme tint.
            if (treeMaxTop > 0 && treePaneRows > 0)
            {
                const trackTop = (treeTopRows + 1) * cellH;
                const l = scrollbarLayout(
                    pn.tree.scroll.v.scrolledTo(pn.tree.top),
                    pn.tree.scroll.vAnim, pn.tree.rows.length, treePaneRows,
                    Rect(0, trackTop, treeCols * cellW, screenH - trackTop));
                drawScrollbar(l, pn.tree.scroll.v, pn.tree.sbTrack,
                    pn.tree.sbThumb);
            }
        }

        // The document pane's horizontal bar (IXB2), over its bottom edge.
        if (vm.hOverflows() && inp.mode == Mode.normal)
        {
            const l = scrollbarLayout(vm.hsb, vm.scroll.hAnim, vm.contentCols,
                vm.widthCols, Rect(gutterPx, 0, screenW - gutterPx, screenH));
            drawScrollbar(l, vm.hsb, vm.sbTrack, vm.sbThumb);
        }

        // Scrollbar: an animated-width thumb, plus a faint track while hovered
        // or dragging. Colors follow the theme's muted gutter tone.
        if (maxTop > 0)
        {
            // Distinct link-tinted chrome (the gutter behind it is empty page
            // bg): a subtle full-height track on hover, a brighter thumb.
            const l = scrollbarLayout(vm.scroll.v.scrolledTo(vm.top),
                vm.scroll.vAnim, total, docRows,
                Rect(0, docY0, screenW, screenH - docY0));
            drawScrollbar(l, vm.scroll.v, vm.sbTrack, vm.sbThumb);
        }

        // A header bar when navigating a document set (`GNV2`): the entry name and
        // summary on the left, the set position + keys on the right. Drawn over the
        // vm.top row so scrolled content passes under it.
        if (set !is null && !set.empty && loadDoc !is null)
        {
            chrome.fillPixels(0, 0, screenW, cellH, mix(vm.pageBg, vm.pageFg, 0.12));
            chrome.rule(Rect(0, 0, screenCols, 1), RuleEdge.bottom,
                Visual(fg: vm.gutterFg));
            const left = vm.summary.length ? vm.title ~ "  " ~ vm.summary : vm.title;
            drawText(fonts, cstrOf(buf, left), cast(float) cellW, 0, TextStyle(0), vm.pageFg);
            const pos = text(set.index + 1, "/", set.length, "   [ ] prev/next   i index");
            const px = cast(float)(screenW - cast(int)((pos.length + 1) * cellW));
            drawText(fonts, cstrOf(buf, pos), px, 0, TextStyle(0), vm.gutterFg);
        }

        // Bottom toolbar (Android): the SAME tree and frames the tap handler
        // hit-tested at the top of the loop, painted through RaylibCanvas
        // (IXB9). Nothing here measures a label or divides a width — a
        // collapsed bar simply produces no ops, which is also what made it
        // untappable.
        version (Android)
        {
            chrome.rule(Rect(0, toolbarY / cellH - 1, screenCols, 1),
                RuleEdge.bottom, Visual(fg: vm.gutterFg));
            auto barOps = buildDisplayList(barTree, barFrames,
                themes[vm.themeIdx].effectivePalette, vm.pageFg, vm.pageBg);
            auto barCanvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                0, cast(float) toolbarY);
            paint(barCanvas, barOps);
        }

        // Input line at the bottom: '/query' while searching, ':n' while going
        // to a line. Shows a match count for searches.
        if (inputMode)
        {
            const barY = screenH - cellH;
            chrome.fillPixels(0, barY, screenW, cellH, vm.gutterFg);
            auto lineText = inp.mode == Mode.search
                ? text("/", inp.query[], "   ", vm.matches.length, " matches")
                : text(":", inp.query[]);
            drawText(fonts, cstrOf(buf, lineText), 4, cast(float) barY, TextStyle(0), vm.pageBg);
        }
        // Copy-mode toast (when not typing): flashes the mode after a 'y'/'t' toggle.
        else if (flash.toast.visible)
        {
            flash.toast = flash.toast.stepped(frameMs(window.frameSeconds), toastCfg);
            const barY = screenH - cellH;
            chrome.fillPixels(0, barY, screenW, cellH, vm.gutterFg);
            drawText(fonts, cstrOf(buf, flash.copyModeMsg), 4, cast(float) barY, TextStyle(0), vm.pageBg);
        }

        // The key guide (`LTN5`), last so it sits over everything — it is a
        // transient answer to "what can I press", not part of the document.
        if (pn.lantern.shown)
        {
            SmallBuffer!(Binding, 128) listed;
            bindingsAt(listed, kctx, pn.lantern.pending[]);
            if (listed.length)
            {
                Builder ltnBuilder;
                BoxLayout ltnBox;
                const ltnRoot = viewLantern(ltnBuilder, ltnLabels, listed[],
                    pn.lantern.pending.length, screenW / cellW, ltnBox,
                    Placement.classic, LanternStyle.init, 0,
                    pn.lantern.scroll);
                auto ltnTree = ltnBuilder.finish(ltnRoot);
                // Bounded to the window, so a `classic` panel actually
                // spans it rather than shrinking to its content.
                auto ltnFrames = layout(ltnTree,
                    Constraints(maxW: screenW / cellW));
                const panel = ltnFrames[ltnTree.root].rect;

                const panelY = screenH - panel.height * cellH
                    - (inputMode ? cellH : 0);
                // A reused sink, so a panel that is up every frame costs no
                // allocation to repaint (`NFR2`).
                // A scissor from the viewer pane is still live at this
                // point; the panel is chrome over everything, not content
                // inside a pane.
                window.resetClip();
                ltnOps.clear();
                buildDisplayListInto(ltnTree, ltnFrames,
                    themes[vm.themeIdx].effectivePalette, vm.pageFg, vm.pageBg,
                    ltnOps);
                auto ltnCanvas = RaylibCanvas(&fonts, &buf, cellW, cellH,
                    0, cast(float) panelY);
                paint(ltnCanvas, ltnOps[]);
            }
        }

        window.resetClip(); // never let a scissor survive the frame
        window.endFrame();

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
            //
            // Then WAIT OUT the async git-status worker. Its landing rebuilds
            // the tree, so a capture that races it is not reproducible: four
            // runs of one binary produced two different images, differing in
            // the explorer's selection — which quietly made this fixture
            // useless as a regression oracle. Two frames after it settles,
            // the rebuild it triggered has been laid out and painted.
            if (!(pn.treeVisible && pn.tree.git.refreshing) && settledAt < 0)
                settledAt = frame;
            const settled = settledAt >= 0 && frame >= settledAt + 2;
            // A worker that never finishes must not hang the capture: past
            // the cap, shoot anyway and let the diff say so.
            if (shotAt < 0 && frame >= shotFrame
                && (settled || frame >= shotFrame + shotSettleCap))
            {
                window.screenshot(shotPath.toStringz);
                shotAt = frame;
            }
            if (shotAt >= 0 && frame >= shotAt + 1)
                break;
        }
    }

    return 0;
}

/**
One frame's pacing and async pump — the `Sched.tick` embedding hatch
(event-horizon SPEC §7.2), the incremental-migration shape for a loop the
application still owns: park in the ring until the frame deadline, running
any completions that arrive meanwhile. When nothing is armed (`drained` —
no oracle, no subprocess, no watch), a plain sleep paces the remainder:
there is nothing to wake for, and that is raylib's own idle behavior.

Absolute deadlines, missed frames skipped (the `Ticker` discipline): a
slow frame does not queue a burst of stale ones.
*/
private void pumpUntilFrame(ref Sched sched, ref MonoTime nextFrame,
    Duration period) @system
{
    import core.thread : Thread;
    import core.time : MonoTime;

    import sparkles.event_horizon.loop : RunStatus;

    for (;;)
    {
        const now = MonoTime.currTime;
        if (now >= nextFrame)
            break;
        auto r = sched.tick(nextFrame - now);
        if (r.hasError)
            break;
        if (r.value == RunStatus.drained)
        {
            const left = nextFrame - MonoTime.currTime;
            if (left > Duration.zero)
                Thread.sleep(left);
            break;
        }
    }
    nextFrame += period;
    const after = MonoTime.currTime;
    if (nextFrame <= after)
        nextFrame = after + period; // missed frames: skip, never replay
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

/// An RGB triple as a raylib color with an explicit alpha (for overlays).

/// The floating hover popup, built from the shared `viewHoverPopup` widget view
/// (surface panel + docs + `@param` chips — the same chrome as the TUI/HTML) and
/// painted through `RaylibCanvas`. The type signature renders as resolved
/// syntax-colored spans (`signatureSpans`) inside the widget model itself, so
/// nothing overpaints the toolkit's output.
private PixelRect drawPopup(ref FontSet fonts, ref SmallBuffer!(char, 4096) buf,
    in TwoslashReturn tw, size_t nodeIndex, float x, float y, int cellW, int cellH,
    in ResolvedTheme theme, ref TsConfigCache cache, in Palette pal,
    RgbColor pageFg, RgbColor pageBg, int availCells,
    ExpandedRegions expanded, out KeyTarget[] keys) @system
{
    import sparkles.twoslash.render_widgets : clampOrigin, effectivePopupWidth,
        HoverViewOptions, signatureSpans;

    // Render JSDoc docs as markdown (bold/italic/code/links/lists/fences), via the
    // grammar registry — falls back to plain lines without it.
    auto sig = signatureSpans(cache, tw.effectiveLanguage,
        (() @trusted => &theme)(), pageFg,
        withoutQuickinfoPrefix(tw.nodes[nodeIndex].text));
    // The docs are markdown, and the theme + fence highlighter are the ones
    // the preview uses — so a fence in a tooltip gets the same chrome as one
    // in the document, including the `unittest` label on a runnable example.
    import sparkles.syntax.md.render_widgets : highlightedFenceRenderer,
        MdViewTheme;

    auto tree = viewHoverPopup(tw, nodeIndex, cache.registry,
        HoverViewOptions(maxWidth: effectivePopupWidth(pal, availCells),
            sigSpans: sig, expanded: expanded, nodeKey: nodeIndex + 1,
            mdTheme: MdViewTheme.derive(theme, pageFg, pageBg),
            fenceRenderer: highlightedFenceRenderer(&cache,
                (() @trusted => &theme)(), pageFg)));
    // A lazy hover span (live types: the underline is up, the type has not
    // arrived yet) views as an EMPTY tree — there is nothing to lay out, and
    // the zero rect tells the caller there is no popup to keep the pointer in.
    if (!tree.nodes.length)
        return PixelRect(x, y, 0, 0);
    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);

    // A popup anchored near the right edge slides left rather than being
    // squeezed into a two-word column. `availCells` was measured from the
    // anchor, so the window edge is `x + availCells` cells out.
    const box = frames[tree.root].rect;
    const px = availCells > 0
        ? cast(float) clampOrigin(cast(int) x, box.width * cellW,
            cast(int) x + availCells * cellW)
        : x;

    auto canvas = RaylibCanvas(&fonts, &buf, cellW, cellH, px, y);
    paint(canvas, ops);

    // Where each collapsible run landed, in cells relative to the popup — the
    // caller turns a click into the region under it.
    keys = keyTargets(tree, frames);

    // The popup's on-screen rect (px), for the caller's pointer hysteresis —
    // the drawn rect, not the anchor, or the pointer leaves a shifted popup
    // the moment it moves onto it.
    return PixelRect(px, y, cast(float)(box.width * cellW),
        cast(float)(box.height * cellH));
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


// Transient-effect configs (STM6): the copy-✔ flash, the copy-mode toast, and
// the hover-underline fade — one Timeline machine, three configurations. The
// TUI runs the same machine with `holdUntilDismissed` (no frame clock).
private enum copiedCfg = Timeline.Config(holdMs: 1200);
private enum toastCfg = Timeline.Config(holdMs: 1600);
private enum fadeCfg = Timeline.Config(fadeInMs: 300, holdUntilDismissed: true);

/// A frame duration in Timeline milliseconds. Takes the seconds rather than
/// reading a clock, so it stays a pure conversion and the window stays the one
/// thing that knows how long a frame took.
private int frameMs(float seconds) @safe pure nothrow @nogc
    => cast(int)(seconds * 1000);

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

/// A pixel-space rectangle — the popup's own geometry. Local rather than the
/// backend's `Rectangle`, so hue names no raylib type; `sparkles.ui.Rect` is
/// integer CELLS and cannot express a sub-cell popup edge.
struct PixelRect
{
    float x = 0, y = 0, width = 0, height = 0;
}

/// `true` iff this frame's keys include `k` — the edge query the input-mode
/// blocks want, over the drained stream rather than a second poll.
private bool hasKey(scope const KeyEvent[] keys, Key k) @safe pure nothrow @nogc
{
    foreach (e; keys)
        if (e.key == k)
            return true;
    return false;
}
