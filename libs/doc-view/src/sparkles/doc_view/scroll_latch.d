/**
Which scroller a gesture belongs to in a document with scrollers inside it
(`SCV12`): the document itself, or a code block or a table that scrolls in
place.

Choosing per event — the innermost thing under the pointer — makes a drag
fight itself. The document moves, a block slides under the finger and takes
the scroll, reaches its edge and hands it back, the next block takes it.
Browsers settled this as $(I latching): the scroller is chosen where the
gesture starts and keeps the whole of it, fling included; one already at its
edge in the gesture's direction is passed over then, and nothing hands over
mid-gesture. A wheel turned after a pause starts a new gesture, so notch by
notch a block still scrolls to its edge and the next notch the document.

The latch owns a nested target's motion (`ScrollMotion`): a drag follows,
a notch eases, and `step` advances it every frame. The document's own
scroll, and a windowed grid's (hue's `DSN4`), stay the caller's: `feed`
reports `false` for them.
*/
module sparkles.doc_view.scroll_latch;

import core.time : MonoTime, msecs;

import sparkles.ui.scroll_motion : ScrollMotion;

import sparkles.doc_view.viewer_model : ViewerModel;

/// What a gesture is latched to.
enum LatchTarget : ubyte
{
    none,     /// no gesture yet
    document, /// the document's own scroll (the caller's)
    grid,     /// a windowed grid owning the vertical axis (the caller's)
    fence,    /// a code block's body
    table,    /// a table's interior
}

/// One gesture's scroller, and a nested one's motion (`SCV12`).
struct ScrollLatch
{
    /// What the current gesture scrolls.
    LatchTarget target;
    /// The fence's `bodyStart` or the table's `spanStart`.
    size_t id;
    /// The axis a nested target scrolls on.
    bool horizontal;
    /// A nested target's position on that axis. `instant` — a target that
    /// does not animate (a terminal, hue) — jumps in whole cells.
    ScrollMotion motion;
    /// A pause this long between events starts a new gesture, for a
    /// producer that cannot say where one begins.
    enum gap = 150.msecs;

    private MonoTime lastAt;

    /**
    A scroll of (`dx`, `dy`) cells over visual row `row`. On a gesture's
    first event — `begins`, a pause, or nothing latched — it picks the
    target: the code block or table under the pointer when it can move that
    way, else the grid when `gridOwnsVertical` and the scroll is vertical,
    else the document. A nested target takes the scroll (a drag `precise`
    followed, a notch eased) and `true` comes back; the document's and the
    grid's are the caller's.
    */
    bool feed(ref ViewerModel vm, long row, float dx, float dy, bool precise,
        bool begins, bool gridOwnsVertical = false) @system
    {
        const now = MonoTime.currTime;
        if (begins || target == LatchTarget.none || now - lastAt > gap)
            pick(vm, row, dx, dy, gridOwnsVertical);
        lastAt = now;
        if (target != LatchTarget.fence && target != LatchTarget.table)
            return false;
        // Off its axis a nested gesture moves nothing — and the document
        // does not take it either: the gesture is the block's.
        const d = horizontal ? dx : dy;
        if (d != 0)
        {
            const limit = max(vm);
            if (precise)
                motion.drag(d, limit);
            else
                motion.nudge(d, limit);
            apply(vm);
        }
        return true;
    }

    /// One frame of a nested target's motion; true while it needs the next.
    bool step(ref ViewerModel vm, float dt) @system
    {
        if ((target != LatchTarget.fence && target != LatchTarget.table) || !motion.active)
            return false;
        const more = motion.step(dt, max(vm));
        apply(vm);
        return more;
    }

    /// Ends the gesture: the next event picks again.
    void release() @safe pure nothrow @nogc
    {
        target = LatchTarget.none;
        motion.stop();
    }

    private void pick(ref ViewerModel vm, long row, float dx, float dy,
        bool gridOwnsVertical) @system
    {
        const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
        horizontal = ax > ay;
        const d = horizontal ? dx : dy;
        motion.stop();
        const fb = vm.fenceBoxAtRow(row);
        if (fb != size_t.max && movable(vm.fenceScrollPos(fb, horizontal),
                vm.fenceScrollMax(fb, horizontal), d))
            return latch(LatchTarget.fence, fb, vm.fenceScrollPos(fb, horizontal),
                vm.fenceScrollMax(fb, horizontal));
        if (!horizontal && gridOwnsVertical)
        {
            target = LatchTarget.grid;
            return;
        }
        const tb = vm.tableBoxAtRow(row);
        if (tb != size_t.max && movable(vm.tableScrollPos(tb, horizontal),
                vm.tableScrollMax(tb, horizontal), d))
            return latch(LatchTarget.table, tb, vm.tableScrollPos(tb, horizontal),
                vm.tableScrollMax(tb, horizontal));
        target = LatchTarget.document;
    }

    private void latch(LatchTarget t, size_t at, double pos, double limit)
        @safe pure nothrow @nogc
    {
        target = t;
        id = at;
        motion.jumpTo(pos, limit);
    }

    // Whether a scroller at `pos` of `limit` can move towards `d`'s sign.
    private static bool movable(double pos, double limit, float d)
        @safe pure nothrow @nogc
        => limit > 0 && (d > 0 ? pos < limit : d < 0 ? pos > 0 : false);

    private double max(ref ViewerModel vm) const @system
        => target == LatchTarget.fence ? vm.fenceScrollMax(id, horizontal)
            : vm.tableScrollMax(id, horizontal);

    private void apply(ref ViewerModel vm) @system
    {
        const p = motion.instant ? cast(double) motion.whole : motion.pos;
        // The latched axis moves; the other stays exactly where it is.
        if (target == LatchTarget.fence)
            cast(void) vm.setFenceScroll(id,
                horizontal ? p : vm.fenceScrollPos(id, true),
                horizontal ? vm.fenceScrollPos(id, false) : p);
        else
            cast(void) vm.setTableScroll(id,
                horizontal ? p : vm.tableScrollPos(id, true),
                horizontal ? vm.tableScrollPos(id, false) : p);
    }
}

version (unittest)
{
    // A paragraph row, a wide table (two rows) in a 30-cell pane, another
    // paragraph row: the table scrolls sideways, the document does not.
    private ViewerModel wideTable() @system
    {
        import sparkles.syntax : MdDoc, MdInline, MdInlineKind;
        import sparkles.syntax.md.model : MdBlock, MdBlockKind, Span;
        import sparkles.twoslash.protocol : TwoslashReturn;
        import sparkles.ui.themes : builtinDark;
        import sparkles.doc_view.preview_model : PreviewModel;

        ViewerModel vm;
        vm.themes = [builtinDark];
        vm.names = ["dark"];
        vm.widthCols = 30;
        vm.applyTheme(0);
        string src;
        foreach (_; 0 .. 25)
            src ~= "a";
        foreach (_; 0 .. 25)
            src ~= "b";
        static MdBlock tcell(size_t s, size_t e)
            => MdBlock(kind: MdBlockKind.tableCell, span: Span(s, e),
                inlines: [MdInline(kind: MdInlineKind.text, span: Span(s, e))]);
        auto trow = MdBlock(kind: MdBlockKind.tableRow, span: Span(0, 50),
            children: [tcell(0, 25), tcell(25, 50)]);
        auto md = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.table, span: Span(0, 50),
                children: [trow, trow]),
        ]), src);
        vm.setDocument("wide.md", "", src, null,
            PreviewModel(present: true, doc: md), TwoslashReturn.init, "markdown");
        return vm;
    }

    private long tableRow(ref ViewerModel vm) @system
    {
        foreach (row; 0 .. cast(long) vm.rows.length)
            if (vm.tableAtRow(row) == 0)
                return row;
        assert(0, "no table row");
    }
}

@("scroll_latch.aGestureOverATableStaysTheTables")
@system unittest
{
    auto vm = wideTable();
    const row = tableRow(vm);
    ScrollLatch l;

    // A sideways drag over the table: the table's, between cells.
    assert(l.feed(vm, row, 2.5f, 0, precise: true, begins: true));
    assert(l.target == LatchTarget.table);
    assert(vm.tableScrollPos(0, true) == 2.5, "followed 1:1, fraction kept");

    // Pushed past its edge, it stops there: the gesture never hands over.
    assert(l.feed(vm, row, 500, 0, precise: true, begins: false));
    assert(vm.tableScrollPos(0, true) == vm.tableScrollMax(0, true));
    assert(l.target == LatchTarget.table);

    // A new gesture the same way finds it at its edge: the document's.
    assert(!l.feed(vm, row, 1, 0, precise: true, begins: true));
    assert(l.target == LatchTarget.document);
    // And one started elsewhere stays the document's over the table too.
    assert(!l.feed(vm, row, -1, 0, precise: true, begins: false));
    assert(l.target == LatchTarget.document);
}

@("scroll_latch.aNotchOverABlockEases")
@system unittest
{
    auto vm = wideTable();
    const row = tableRow(vm);
    ScrollLatch l;
    assert(l.feed(vm, row, 3, 0, precise: false, begins: true));
    assert(vm.tableScrollPos(0, true) == 0, "a notch eases: nothing yet");
    while (l.step(vm, 1.0f / 60)) {}
    assert(vm.tableScrollPos(0, true) == 3, "then arrives");
}

@("scroll_latch.withinACellOnlyThePaintedFractionMoves")
@system unittest
{
    import sparkles.ui.canvas : DrawOp, match, OpKind, PushShift;
    import sparkles.doc_view.view_ops : emitVisibleOps;

    auto vm = wideTable();
    const row = tableRow(vm);
    ScrollLatch l;
    assert(l.feed(vm, row, 2, 0, precise: true, begins: true));
    const built = vm.ops.length;
    const before = vm.ops.ptr;
    // A quarter of a cell further: no rebuild, the painted shift says it.
    assert(l.feed(vm, row, 0.25f, 0, precise: true, begins: false));
    assert(vm.ops.ptr is before && vm.ops.length == built, "the layout stands");
    float dx = 1;
    emitVisibleOps(vm, 50, (ref DrawOp op) {
        op.payload.match!((ref PushShift s) { if (s.key && (s.axes & 1)) dx = s.dx; },
            (ref _) {});
    });
    assert(dx == -0.25f, "the table's scrolled parts are painted a quarter cell on");
}

@("scroll_latch.aBlockScrollingBothWaysMovesOneAxisAtATime")
@system unittest
{
    import sparkles.syntax : MdDoc;
    import sparkles.syntax.md.model : MdBlock, MdBlockKind, Span;
    import sparkles.twoslash.protocol : TwoslashReturn;
    import sparkles.ui.themes : builtinDark;
    import sparkles.doc_view.preview_model : PreviewModel;

    // Twelve 80-cell lines in a 30-cell pane, five lines shown: the block
    // overflows on both axes.
    string src;
    foreach (_; 0 .. 12)
    {
        foreach (c; 0 .. 80)
            src ~= "x";
        src ~= "\n";
    }
    ViewerModel vm;
    vm.themes = [builtinDark];
    vm.names = ["dark"];
    vm.widthCols = 30;
    vm.codeMaxLines = 5;
    vm.applyTheme(0);
    vm.setDocument("code.md", "", src, null, PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [
            MdBlock(kind: MdBlockKind.codeFence, span: Span(0, src.length),
                codeBody: Span(0, src.length))]), src)),
        TwoslashReturn.init, "markdown");
    long row = -1;
    foreach (r; 0 .. cast(long) vm.rows.length)
        if (vm.fenceBodyAtRow(r) != size_t.max)
        {
            row = r;
            break;
        }
    assert(row >= 0, "precondition: a fence body row");
    const fb = vm.fenceBodyAtRow(row);
    assert(vm.fenceScrollMax(fb, true) > 0 && vm.fenceScrollMax(fb, false) > 0,
        "precondition: it scrolls both ways");

    ScrollLatch l;
    assert(l.feed(vm, row, 0, 2.5f, precise: true, begins: true));
    assert(vm.fenceScrollPos(fb, false) == 2.5 && vm.fenceScrollPos(fb, true) == 0,
        "down only");
    assert(l.feed(vm, row, 7.25f, 0, precise: true, begins: true));
    assert(vm.fenceScrollPos(fb, true) == 7.25 && vm.fenceScrollPos(fb, false) == 2.5,
        "across only — down stays where it was");
    assert(l.feed(vm, row, 1, 0, precise: true, begins: false));
    assert(vm.fenceScrollPos(fb, true) == 8.25 && vm.fenceScrollPos(fb, false) == 2.5);
}

@("scroll_latch.aTablesBordersAreTheTables")
@system unittest
{
    // The rows of the table's frame carry no source; a scroll on one is
    // still the table's.
    auto vm = wideTable();
    long[] borders;
    foreach (r; 0 .. cast(long) vm.rows.length)
        if (vm.tableAtRow(r) == size_t.max && vm.tableBoxAtRow(r) == 0)
            borders ~= r;
    assert(borders.length >= 2, "the top and bottom borders at least");
    foreach (r; borders)
    {
        ScrollLatch l;
        assert(l.feed(vm, r, 1, 0, precise: true, begins: true));
        assert(l.target == LatchTarget.table);
        vm.tableScrollAt.clear();
    }
}

@("scroll_latch.aBlocksBarSlidesWithItsFraction")
@system unittest
{
    import sparkles.ui.canvas : DrawOp, match, Scrollbar;
    import sparkles.doc_view.view_ops : emitVisibleOps;

    auto vm = wideTable();
    ScrollLatch l;
    assert(l.feed(vm, tableRow(vm), 2.25f, 0, precise: true, begins: true));
    int whole = -1;
    ubyte frac;
    emitVisibleOps(vm, 50, (ref DrawOp op) {
        op.payload.match!((ref Scrollbar b) { whole = b.offset; frac = b.offsetFrac; },
            (ref _) {});
    });
    assert(whole == 2 && frac == 64, "the thumb a quarter cell past 2, like the content");
}
