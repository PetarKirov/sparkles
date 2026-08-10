/**
The GUI workspace's state vocabulary (`P2.B1`).

The M15 GuiState groups, moved out of `gui.d` verbatim so the state and its
small transition logic sit in a $(B tested) module while `gui.d` keeps the
frame assembly. First slice of the hue migration
([PLAN P2.B](../../../docs/specs/ui-app/PLAN.md#p2b--appshue)): no behavior
change — the golden-frame screenshots are the oracle.
*/
module gui_state;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input.frame : InputFrame;
import sparkles.twoslash.signature_layout : ExpandedRegions;
import sparkles.ui.components.table : GridHit;
import sparkles.ui.dock : DockContainer, PaneId;
import sparkles.ui.state : CaptureState, KeyTarget, Timeline;

import explorer : ExplorerTui;
import lantern : LanternState;
import table_select : TableCopyFormat;

/// Which selection regime a drag runs (`SEL`/`TBL`).
enum Regime
{
    none,
    text,
    table,
}

/// The mouse-selection drag state (M15 GROUP-S of the GuiState hoist):
/// which regime the drag runs (text span vs table grid), the live anchors,
/// and the modifier snapshot a table drag copies with.
struct SelectionDrag
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


/// container resolves them to frames.
enum PaneId treePane = 1, docPane = 2;

/// The workspace panes (M15 GROUP-P of the GuiState hoist): the explorer
/// tree pane (XPL2), and the dock container that arranges it beside the
/// document (C-2a) — the container owns the tiling, the STM8 divider
/// drag, focus and its own pointer capture. Scrolling moved off with C-1:
/// each scrollable model owns its `ScrollView` (`vm.scroll` /
/// `tree.scroll`) — machines, offsets and px easings as one value both
/// backends step.
struct Panes
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
struct InputState
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
struct CopyModes
{
    bool ansiStrip;
    TableCopyFormat tableFmt;
}

/// The transient feedback state (M15 GROUP-T of the GuiState hoist): the
/// copied-checkmark flash beside a fence's copy button (the copied fence
/// itself is `vm.copiedFenceSrc`), the copy-mode toast a 'y'/'t' toggle
/// flashes in the status bar, and the armed vim 'z' fold sequence ('z'
/// arms it for ~a second; the next key picks the op).
struct Flashes
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
struct HoverPopup
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
struct ResizeDebounce
{
    int prevWidthCols = -1;
    int settle;
    enum settleFrames = 4; // ~66 ms at 60 FPS
}

/// The interactive input mode (M4): normal keys, or typing a search / goto line.
enum Mode
{
    normal,
    search,
    gotoLine,
}


/// A pixel-space rectangle — the popup's own geometry. Local rather than the
/// backend's `Rectangle`, so hue names no raylib type; `sparkles.ui.Rect` is
/// integer CELLS and cannot express a sub-cell popup edge.
struct PixelRect
{
    float x = 0, y = 0, width = 0, height = 0;
}


// ---------------------------------------------------------------------------
// Tests — the first coverage gui.d's state has ever had.
// ---------------------------------------------------------------------------

@("gui_state.SelectionDrag.normalizedSpan")
@safe pure nothrow @nogc
unittest
{
    // The drag's anchors may run backwards (drag upward); the span is
    // normalized on read, never by mutating the anchors.
    SelectionDrag d;
    d.anchorLo = 40; d.anchorHi = 45;
    d.headLo = 10; d.headHi = 15;
    assert(d.selMin == 10);
    assert(d.selMax == 45);

    d.headLo = 50; d.headHi = 60;
    assert(d.selMin == 40);
    assert(d.selMax == 60);
}

@("gui_state.Panes.focusIsContainerOwned")
@safe pure nothrow
unittest
{
    // Focus lives on the dock (DCK6), not as a duplicated flag: the pane
    // accessors are views over it, so the two can never disagree.
    Panes p;
    p.treeFocused = true;
    assert(p.treeFocused);
    assert(p.dock.focused == treePane);

    p.treeFocused = false;
    assert(!p.treeFocused);
    assert(p.dock.focused == docPane);
}

@("gui_state.defaults")
@safe pure nothrow @nogc
unittest
{
    // The startup regime the frame assembly assumes.
    assert(InputState.init.mode == Mode.normal);
    assert(SelectionDrag.init.regime == Regime.none);
    assert(SelectionDrag.init.selTable == -1);
    assert(HoverPopup.init.hotNode == 0);
    assert(HoverPopup.init.popupNode == size_t.max);
    assert(HoverPopup.init.forceHover == -1);
    assert(ResizeDebounce.init.prevWidthCols == -1);
    static assert(ResizeDebounce.settleFrames == 4);
}
