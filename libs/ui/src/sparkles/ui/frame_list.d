/**
One frame's drawing as one op stream, in absolute cells — and the questions a
post-process asks of it (`EFX23`).

An application that composes its frame from several subtrees — a document
pane, a file tree, a modal laid out on its own and centred — has each one's
display list in that subtree's own coordinates. Painting them is easy (a
canvas per origin); asking "where did the focused panel land, where is the
selection, what is under the pointer" is not, and the answer used to be
re-derived by hand: the same centring and subtraction the paint site had just
done, written a second time for the CRT's halo — which is how the halo came
to sit three rows below the picker it outlines.

$(LREF FrameList) removes the second derivation. Paint sites $(I emit) their
operations into it with the origin they were placed at; it translates each
into absolute cells, records it, and paints it through the one canvas
immediately — so the paint order against anything the application still draws
outside the vocabulary (a sub-cell hairline, a pixel-positioned toast) is
exactly what it was. What the frame emitted is then there to be read, and the
harvest functions below read it by $(REF Slot, sparkles,ui,style).

$(B Text is borrowed.) A recorded text run points into whatever arena interned
it, which a paint site may reset for its next subtree within the same frame.
The stream is for $(I geometry) once painted: every harvest function reads
rects, slots and scroll extents, never the text.
*/
module sparkles.ui.frame_list;

import sparkles.ui.canvas : DrawOp, isCanvas, OpKind, RuleEdge;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui.state : scrollbarThumb, ThumbGeometry;
import sparkles.ui.style : Slot;

/// A run of emitted operations the application names as one region — a
/// pane, a modal — with the extent it actually painted.
struct FrameGroup
{
    size_t begin;  /// first operation, index into `FrameList.ops`
    size_t end;    /// one past the last
    bool focused;  /// the region that holds the input focus
    Rect extent;   /// union of its operations' rects, each cut to its clip
}

/// See the module documentation.
struct FrameList
{
    private
    {
        DrawOp[] _store;
        size_t _length;
        FrameGroup[] _groups;
        size_t _groupCount;
        size_t[8] _open;     // indices of the groups currently open
        size_t _openDepth;
        Rect[16] _clips;     // the absolute clip stack while recording
        size_t _clipDepth;
    }

    // The two `emit`s come before the `@safe:` below on purpose: they are
    // templates over the canvas, and a canvas's painting may be `@system`
    // (a GPU one is). Their attributes are the canvas's, inferred.

    /**
    Translates each of `src` by `(dx, dy)` cells, records it, and paints it
    through `canvas` — the origin a paint site used to give a canvas of its
    own, expressed as a move of the operations instead.
    */
    void emit(Canvas)(ref Canvas canvas, in DrawOp[] src, int dx, int dy)
    if (isCanvas!Canvas)
    {
        foreach (ref const s; src)
            emit(canvas, s, dx, dy);
    }

    /// ditto — one operation.
    void emit(Canvas)(ref Canvas canvas, in DrawOp src, int dx = 0, int dy = 0)
    if (isCanvas!Canvas)
    {
        DrawOp op = src;
        op.translate(dx, dy);
        record(op);
        paint(canvas, (() @trusted => (&op)[0 .. 1])());
    }


@safe:

    /// Forgets the previous frame, keeping the storage.
    void reset() pure nothrow @nogc
    {
        _length = 0;
        _groupCount = 0;
        _openDepth = 0;
        _clipDepth = 0;
    }

    /// Everything emitted this frame, in paint order, in absolute cells.
    const(DrawOp)[] ops() const return scope pure nothrow @nogc
        => _store[0 .. _length];

    /// The groups this frame named, in the order they began.
    const(FrameGroup)[] groups() const return scope pure nothrow @nogc
        => _groups[0 .. _groupCount];

    /**
    Opens a named region; every operation emitted until the matching
    $(LREF endGroup) belongs to it. Regions nest.
    */
    void beginGroup(bool focused = false) pure nothrow
    {
        if (_groupCount == _groups.length)
            _groups.length = _groups.length ? _groups.length * 2 : 8;
        _groups[_groupCount] = FrameGroup(begin: _length, end: _length,
            focused: focused);
        if (_openDepth < _open.length)
            _open[_openDepth++] = _groupCount;
        ++_groupCount;
    }

    /// ditto
    void endGroup() pure nothrow @nogc
    {
        if (_openDepth == 0)
            return;
        const g = _open[--_openDepth];
        _groups[g].end = _length;
    }

    private void record(scope ref DrawOp op) pure nothrow
    {
        if (_length == _store.length)
            _store.length = _store.length ? _store.length * 2 : 256;
        // The one escape: an operation's text is a borrow from the arena that
        // interned it (see the module note), and the stream keeps that borrow
        // past the call. It is only ever read for geometry afterwards.
        () @trusted { _store[_length++] = *(cast(DrawOp*) &op); }();

        // Track the clip so an operation's contribution to its region is
        // what could actually have been painted: a document line wider than
        // its pane is cut to the pane, not counted to its full length.
        final switch (op.kind)
        {
            case OpKind.pushClip:
                const outer = _clipDepth ? _clips[_clipDepth - 1] : op.rect;
                const inner = op.rect.intersection(outer);
                if (_clipDepth < _clips.length)
                    _clips[_clipDepth++] = inner;
                grow(inner);
                break;
            case OpKind.popClip:
                if (_clipDepth)
                    --_clipDepth;
                break;
            case OpKind.pushEffect:
            case OpKind.popEffect:
                break;
            case OpKind.fillRect:
            case OpKind.textRun:
            case OpKind.glyph:
            case OpKind.line:
            case OpKind.rule:
            case OpKind.scrollbar:
            case OpKind.image:
                grow(_clipDepth ? op.rect.intersection(_clips[_clipDepth - 1])
                    : op.rect);
                break;
        }
    }

    private void grow(in Rect r) pure nothrow @nogc
    {
        if (r.empty)
            return;
        foreach (i; 0 .. _openDepth)
        {
            auto e = &_groups[_open[i]].extent;
            *e = e.empty ? r : union_(*e, r);
        }
    }
}

private Rect union_(in Rect a, in Rect b) @safe pure nothrow @nogc
{
    const x0 = a.x < b.x ? a.x : b.x;
    const y0 = a.y < b.y ? a.y : b.y;
    const ax1 = a.x + a.width, bx1 = b.x + b.width;
    const ay1 = a.y + a.height, by1 = b.y + b.height;
    return Rect(x0, y0, (ax1 > bx1 ? ax1 : bx1) - x0, (ay1 > by1 ? ay1 : by1) - y0);
}

// ---------------------------------------------------------------------------
// The harvest: questions answered from what the frame emitted.
// ---------------------------------------------------------------------------

/**
The focused region's painted extent: the $(I last) focused group — a modal
painted over the panes is the one the user is looking at — or `false` when
no group claims focus.
*/
bool focusedExtent(in FrameList list, out Rect extent) @safe pure nothrow @nogc
{
    foreach_reverse (ref const g; list.groups)
        if (g.focused && !g.extent.empty)
        {
            extent = g.extent;
            return true;
        }
    return false;
}

/// The rect of the first operation carrying `slot` within `within` (or
/// anywhere, when `within` is empty) — "where is the selection".
bool firstOfSlot(in DrawOp[] ops, Slot slot, out Rect rect,
    in Rect within = Rect.init) @safe pure nothrow @nogc
{
    foreach (ref const op; ops)
    {
        if (op.slot != slot)
            continue;
        const r = op.rect;
        if (!within.empty && r.intersection(within).empty)
            continue;
        rect = r;
        return true;
    }
    return false;
}

/**
The topmost text run under `at` — "what is the pointer over", answered with
what was drawn there rather than with the pointer's row re-divided by hand.
*/
bool textAt(in DrawOp[] ops, in Point at, out Rect rect) @safe pure nothrow @nogc
{
    foreach_reverse (ref const op; ops)
        if (op.kind == OpKind.textRun && op.rect.contains(at))
        {
            rect = op.rect;
            return true;
        }
    return false;
}

/**
The thumb of the first scrollbar carrying `slot`, in the track's own units:
`unitsPerCell` of them per cell along the track, with the grabbable minimum
`minExtent` — the same `STM2` formula every backend paints with, applied to
the extents the operation carries.

`track` receives the scrollbar's rect in cells, so a caller can place the
thumb; `thumb` its span along the track in units.
*/
bool scrollbarThumbOf(in DrawOp[] ops, Slot slot, int unitsPerCell,
    int minExtent, out Rect track, out ThumbGeometry thumb) @safe pure nothrow @nogc
{
    foreach (ref const op; ops)
    {
        if (op.kind != OpKind.scrollbar || op.slot != slot)
            continue;
        track = op.rect;
        const vertical = op.ruleEdge == RuleEdge.left
            || op.ruleEdge == RuleEdge.right || op.ruleEdge == RuleEdge.centerX;
        const cells = vertical ? track.height : track.width;
        thumb = scrollbarThumb(op.barContent, op.barViewport, op.barOffset,
            cells * unitsPerCell, minExtent);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui.frameList.emitTranslatesRecordsAndPaints")
@safe nothrow unittest
{
    import sparkles.ui.canvas : fillRectOp, popClipOp, pushClipOp,
        RecordingCanvas, textRunOp;

    // A subtree laid out at its own origin, placed at (10, 4): what used to be
    // a second canvas with an origin is the same operations, moved.
    const DrawOp[3] local = [
        pushClipOp(Rect(0, 0, 5, 2)),
        textRunOp(Rect(1, 0, 20, 1), "a line wider than its pane"),
        popClipOp(),
    ];
    RecordingCanvas painted;
    FrameList list;
    list.beginGroup(focused: true);
    list.emit(painted, local[], 10, 4);
    list.endGroup();

    assert(list.ops.length == 3);
    assert(list.ops[1].rect == Rect(11, 4, 20, 1), "absolute cells");
    // Painted immediately, in the same order: the canvas saw the moved ops.
    assert(painted.ops.length && painted.ops[$ - 1].kind == OpKind.popClip);

    // The group's extent is what could have been PAINTED — the run is cut to
    // its clip, not counted at its full width.
    Rect focus;
    assert(focusedExtent(list, focus));
    assert(focus == Rect(10, 4, 5, 2));

    // Reset keeps nothing but the storage.
    list.reset();
    assert(list.ops.length == 0 && list.groups.length == 0);
    assert(!focusedExtent(list, focus));
    cast(void) fillRectOp(Rect.init);
}

@("ui.frameList.theLastFocusedGroupIsTheOneOnTop")
@safe nothrow unittest
{
    import sparkles.ui.canvas : fillRectOp, RecordingCanvas;
    import sparkles.ui.style : Visual;

    RecordingCanvas c;
    FrameList list;
    // A focused pane, then a modal over it: the modal is where the eye is.
    list.beginGroup(focused: true);
    list.emit(c, fillRectOp(Rect(0, 0, 40, 20)));
    list.endGroup();
    list.beginGroup(focused: false);
    list.emit(c, fillRectOp(Rect(40, 0, 40, 20)));
    list.endGroup();
    list.beginGroup(focused: true);
    list.emit(c, fillRectOp(Rect(20, 5, 30, 8), Slot.surface));
    list.endGroup();

    Rect focus;
    assert(focusedExtent(list, focus) && focus == Rect(20, 5, 30, 8));
    assert(list.groups.length == 3 && list.groups[1].extent == Rect(40, 0, 40, 20));
}

@("ui.frameList.harvestsBySlotAndByPosition")
@safe pure nothrow unittest
{
    import sparkles.ui.canvas : fillRectOp, Scrollbar, textRunOp;

    DrawOp[] ops = [
        fillRectOp(Rect(0, 3, 12, 1), Slot.selection),
        textRunOp(Rect(1, 3, 6, 1), "readme"),
        textRunOp(Rect(20, 7, 9, 1), "fn main()"),
        fillRectOp(Rect(20, 9, 15, 1), Slot.selection),
        DrawOp(Scrollbar(rect: Rect(79, 1, 1, 20), content: 200, viewport: 20,
            offset: 90, edge: RuleEdge.right, slot: Slot.thumb)),
    ];

    Rect r;
    assert(firstOfSlot(ops, Slot.selection, r) && r == Rect(0, 3, 12, 1));
    // Restricted to a region — the document's selection, not the tree's.
    assert(firstOfSlot(ops, Slot.selection, r, Rect(15, 0, 60, 20))
        && r == Rect(20, 9, 15, 1));
    assert(!firstOfSlot(ops, Slot.focusRing, r));

    assert(textAt(ops, Point(22, 7), r) && r == Rect(20, 7, 9, 1));
    assert(!textAt(ops, Point(50, 7), r), "nothing drawn there");

    // The thumb from the extents the operation carries — 20 cells of 16 px,
    // a tenth visible, scrolled to the middle.
    Rect track;
    ThumbGeometry thumb;
    assert(scrollbarThumbOf(ops, Slot.thumb, 16, 16, track, thumb));
    assert(track == Rect(79, 1, 1, 20));
    assert(thumb.extent == 32 && thumb.start == 144);
}
