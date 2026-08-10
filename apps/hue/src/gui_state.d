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

    /**
    Begins a drag from the press's hit: `true` when a drag actually starts —
    the caller's cue to take the pointer capture. The regime and anchors come
    from what was under the pointer; a miss still runs (regime `none`,
    nothing selecting), exactly as the inline version did.

    Templated over the hit (`ok`/`table`/`tableIdx`/`cell`/`lo`/`hi`) because
    the concrete hit type is frame-local to the GUI's `hitAt` — and a test's
    fake hit is then just another instantiation.
    */
    bool begin(H)(in H h)
    {
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
        return selecting;
    }

    /// Extends the running drag with the hover's hit. A table drag only
    /// follows hits in $(B its own) table and carries the modifier snapshot
    /// its copy serializes with; a text drag extends over anything with a
    /// source span — including a table line's block span, so a drag from
    /// outside sweeps across it.
    void extend(H)(in H h, bool shiftMod, bool altMod)
    {
        if (regime == Regime.table && h.table && h.tableIdx == selTable)
        {
            tblHead = h.cell;
            tblShift = shiftMod;
            tblAlt = altMod;
        }
        else if (regime == Regime.text && h.ok)
        {
            headLo = h.lo;
            headHi = h.hi;
        }
    }
}

version (unittest)
{
    /// The hit shape `begin`/`extend` are generic over, as a test fake.
    private struct FakeHit
    {
        bool ok, table;
        long lo, hi;
        int tableIdx;
        GridHit cell;
    }
}

@("gui_state.SelectionDrag.beginPicksTheRegime")
@safe pure nothrow @nogc
unittest
{
    SelectionDrag d;

    // A text hit: anchors collapse onto the hit span; the caller captures.
    assert(d.begin(FakeHit(ok: true, lo: 10, hi: 14)));
    assert(d.regime == Regime.text);
    assert(d.selMin == 10 && d.selMax == 14);

    // A table hit: the drag binds to THAT table, modifiers reset.
    d.tblShift = true;
    assert(d.begin(FakeHit(ok: true, table: true, tableIdx: 2,
        cell: GridHit(row: 1, col: 3))));
    assert(d.regime == Regime.table);
    assert(d.selTable == 2);
    assert(!d.tblShift && !d.tblAlt);

    // A miss: nothing selecting, regime cleared — but the call still runs.
    assert(!d.begin(FakeHit()));
    assert(d.regime == Regime.none);
}

@("gui_state.SelectionDrag.extendFollowsItsRegime")
@safe pure nothrow @nogc
unittest
{
    SelectionDrag d;

    // A table drag ignores hits in OTHER tables and text spans...
    cast(void) d.begin(FakeHit(ok: true, table: true, tableIdx: 1,
        cell: GridHit(row: 0, col: 0)));
    d.extend(FakeHit(ok: true, table: true, tableIdx: 7,
        cell: GridHit(row: 9, col: 9)), true, false);
    assert(d.tblHead == GridHit(row: 0, col: 0) && !d.tblShift);
    // ...and follows its own, carrying the modifier snapshot.
    d.extend(FakeHit(ok: true, table: true, tableIdx: 1,
        cell: GridHit(row: 2, col: 4)), true, true);
    assert(d.tblHead == GridHit(row: 2, col: 4));
    assert(d.tblShift && d.tblAlt);

    // A text drag extends over any source span — a table's block span too.
    cast(void) d.begin(FakeHit(ok: true, lo: 5, hi: 8));
    d.extend(FakeHit(ok: true, table: true, tableIdx: 3, lo: 40, hi: 44),
        false, false);
    assert(d.selMax == 44, "a text drag sweeps across a table from outside");
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

    /**
    Steps the debounce with this frame's width and answers whether to relayout
    $(B now): only when the width differs from the laid-out one $(B and) has
    held steady for `settleFrames` consecutive frames — so a drag that sweeps
    many widths re-wraps once at the end, while discrete changes (theme, font
    size, gutter toggles) relayout through their own immediate paths.
    */
    bool step(int widthCols, int laidOutCols) @safe pure nothrow @nogc
    {
        bool fire = false;
        if (widthCols != laidOutCols)
        {
            settle = (widthCols == prevWidthCols) ? settle + 1 : 0;
            if (settle >= settleFrames)
                fire = true;
        }
        prevWidthCols = widthCols;
        return fire;
    }
}

@("gui_state.ResizeDebounce.firesOnceSteady")
@safe pure nothrow @nogc
unittest
{
    // A drag sweeping widths: every new width resets the count; only a width
    // that holds for settleFrames consecutive frames fires.
    ResizeDebounce rd;
    assert(!rd.step(80, 100)); // differs from laid-out, first sighting
    assert(!rd.step(78, 100)); // still sweeping: reset
    assert(!rd.step(78, 100)); // settle = 1
    assert(!rd.step(78, 100)); // settle = 2
    assert(!rd.step(78, 100)); // settle = 3
    assert(rd.step(78, 100));  // settle = 4: fire

    // At the laid-out width nothing fires and nothing accumulates.
    ResizeDebounce quiet;
    foreach (i; 0 .. 10)
        assert(!quiet.step(100, 100));
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


/**
The match to jump to on Enter in search mode: the first whose visual row is
at/after `top` — matches are in source order, so visual order — wrapping to
the first match when the viewport sits past every one. `visualOf(i)` names
the i-th match's visual row, so the scan is testable with a plain array.
*/
size_t firstMatchAtOrAfter(alias visualOf)(size_t matchCount, long top)
{
    size_t i;
    while (i < matchCount && visualOf(i) < top)
        ++i;
    return i < matchCount ? i : 0;
}

@("gui_state.firstMatchAtOrAfter")
@safe pure nothrow @nogc
unittest
{
    static immutable long[] rows = [3, 10, 42];
    alias at = i => rows[i];

    assert(firstMatchAtOrAfter!at(rows.length, 0) == 0);
    assert(firstMatchAtOrAfter!at(rows.length, 4) == 1);
    assert(firstMatchAtOrAfter!at(rows.length, 10) == 1, "at counts");
    assert(firstMatchAtOrAfter!at(rows.length, 11) == 2);
    // Past every match: wrap to the first.
    assert(firstMatchAtOrAfter!at(rows.length, 100) == 0);
    // No matches at all: index 0 (the caller guards on emptiness as before).
    assert(firstMatchAtOrAfter!at(0, 5) == 0);
}

/**
Parses the goto-line query (`:` mode) into the 0-based source line: 1-based
input, non-positive clamps to the first line, non-numeric (or empty) is `-1` —
no jump. Deliberately $(B not) range-checked against the document: the
original handler set the viewport top even past the last line (the view model
clamps), and this is only the parse half of that decision.
*/
long parseGotoLine(scope const(char)[] query) @safe pure nothrow
{
    import std.conv : to;

    if (query.length == 0)
        return -1;
    long n;
    try
        n = query.to!long;
    catch (Exception)
        return -1;
    return n > 0 ? n - 1 : 0;
}

@("gui_state.parseGotoLine")
@safe pure nothrow
unittest
{
    // 1-based in, 0-based out; zero and negatives clamp to the first line.
    assert(parseGotoLine("1") == 0);
    assert(parseGotoLine("42") == 41);
    assert(parseGotoLine("0") == 0);
    assert(parseGotoLine("-5") == 0);
    // Garbage or nothing typed: no jump.
    assert(parseGotoLine("abc") == -1);
    assert(parseGotoLine("") == -1);
    assert(parseGotoLine("12x") == -1);
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
