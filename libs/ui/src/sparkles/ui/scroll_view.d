/**
The scroll container (`SCV1`–`SCV3`, `SCV6`): one scrollable viewport's
whole scrolling interaction as $(B one value) — both axes' STM9 machines,
the px hover-expand easings, and the per-frame transition that owns
liveness, hover, clamping and the STM11 capture protocol. The application
supplies geometry and reads offsets back; it never runs a grab.

Before this, every pane assembled the same orchestration by hand — sync
the machine from the pane's offset, hit-test the hit zone, gate the press
on `capture.available`, route the drag by the machine's flag, release on
button-up, ease the width — once per axis, per pane, per backend. The
`ScrollView` is that orchestration written once. Offsets are content
units, so the SAME value serves a cell backend and a px backend: only
`ScrollPointer.trackPos` and `ScrollExtents.track` are in backend space.

The container does NOT route: which pane a wheel or pointer event belongs
to stays with the workspace/dock composition (`DCK7`/`DCK13`); a host
feeds this value only events it already routed here.
*/
module sparkles.ui.scroll_view;

import sparkles.base.term_control : PointerShape;
import sparkles.input.capability : InputCapabilities;
import sparkles.ui.state : CaptureState, ScrollAxis, ScrollbarState;

@safe:

/// The hover-expand animation state for px backends: eased every frame
/// toward the idle rail or the expanded gutter extent. Pure floats — cell
/// backends simply never read it. (Moved here from `ui_raylib.scrollbar`;
/// the px layout/draw functions still live there.)
struct ScrollbarAnim
{
    float width = 4.0f;

    /// Eases `width` toward `target` at the shared 15/s rate.
    void step(float target, float dt) pure nothrow @nogc
    {
        width += (target - width) * 15.0f * dt;
    }
}

/// The pointer input one axis consumes for one frame (`SCV3`) —
/// backend-neutral: the host derives it from its pointer source (the
/// folded frame input on the GPU host, decoded events on the terminal)
/// and its own hit-zone geometry.
struct ScrollPointer
{
    bool over;     /// the pointer is inside the bar's hit zone
    bool pressed;  /// the primary button went down this frame
    bool released; /// the primary button came up this frame
    int trackPos;  /// pointer position along the track, in track units
}

/// The extents one axis scrolls over (`SCV2`): content and viewport in
/// content units, the track length in the backend's track units, and the
/// smallest grabbable thumb.
struct ScrollExtents
{
    long content;
    long viewport;
    int track;
    int minExtent = 1;
}

/**
One scrollable viewport (`SCV1`). Owned by the scrollable $(B model), not
by a host: both backends step the same value, so the machines cannot fork
per target.
*/
struct ScrollView
{
    ScrollbarState v = ScrollbarState(ScrollAxis.vertical);
    ScrollbarState h = ScrollbarState(ScrollAxis.horizontal);
    ScrollbarAnim vAnim;
    ScrollbarAnim hAnim;

pure nothrow @nogc:

    /// `offset` clamped into `[0, content − viewport]` (`SCV2`).
    static long clampOffset(long offset, long content, long viewport)
    {
        const max = content > viewport ? content - viewport : 0;
        return offset < 0 ? 0 : (offset > max ? max : offset);
    }

    /**
    One frame of one axis: sync from the pane's `offset` (clamped), hover
    from the host's hit test, then the whole press-grab-drag-release
    interaction gated through the container-issued capture id. A press
    takes the capture; button-up ends the grab (the host's central
    `capture.released()` frees ownership). When `live` is false — the
    content fits, or an input mode suppresses the bar — the axis drops
    hover and any grab. Read the result back from `v.offset` / `h.offset`.
    */
    CaptureState stepV(CaptureState capture, size_t capId, bool live,
        in ScrollPointer p, long offset, in ScrollExtents e)
    {
        v = run(v, capture, capId, live, p, offset, e);
        return capture;
    }

    /// ditto
    CaptureState stepH(CaptureState capture, size_t capId, bool live,
        in ScrollPointer p, long offset, in ScrollExtents e)
    {
        h = run(h, capture, capId, live, p, offset, e);
        return capture;
    }

    /// A routed wheel/keys scroll in content units, clamped (`SCV3`).
    /// (Routing itself is the composition's job, `DCK7`.)
    void wheeledV(long delta, in ScrollExtents e)
    {
        v = v.scrolledTo(clampOffset(v.offset + delta, e.content, e.viewport));
    }

    /// ditto
    void wheeledH(long delta, in ScrollExtents e)
    {
        h = h.scrolledTo(clampOffset(h.offset + delta, e.content, e.viewport));
    }

    /// Eases the px extents toward expanded/idle per the axis' state and
    /// the target's declared capabilities (`IXB10`) — no-hover targets
    /// stay permanently expanded.
    void easeV(float expanded, float idle, in InputCapabilities caps, float dt)
    {
        vAnim.step(v.expanded(caps) ? expanded : idle, dt);
    }

    /// ditto
    void easeH(float expanded, float idle, in InputCapabilities caps, float dt)
    {
        hAnim.step(h.expanded(caps) ? expanded : idle, dt);
    }

    /// `true` while either axis owns the pointer. Hosts composing shapes
    /// need grab and hover apart, because a grab outranks every hover —
    /// including one belonging to a different affordance (`DCK9`).
    bool grabbing() const => v.dragging || h.dragging;

    /// The one pointer shape this viewport wants (`SCV6`): a live grab
    /// outranks hover, vertical outranks horizontal on ties.
    PointerShape shape() const
        => v.dragging ? v.shape()
            : h.dragging ? h.shape()
                : v.hovered ? v.shape()
                    : h.hovered ? h.shape() : PointerShape.default_;

    private static ScrollbarState run(ScrollbarState bar,
        ref CaptureState capture, size_t capId, bool live,
        in ScrollPointer p, long offset, in ScrollExtents e)
    {
        if (!live)
            return bar.hoveredNow(false).released();
        bar = bar.scrolledTo(clampOffset(offset, e.content, e.viewport))
            .hoveredNow(p.over || bar.dragging);
        if (p.over && p.pressed && capture.available(capId))
        {
            bar = bar.pressed(p.trackPos, e.content, e.viewport, e.track,
                e.minExtent);
            capture = capture.capturedBy(capId);
        }
        else if (bar.dragging)
            bar = p.released
                ? bar.released()
                : bar.dragged(p.trackPos, e.content, e.viewport, e.track,
                    e.minExtent);
        return bar;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui.scrollView.grabLifecycleWithCapture")
@safe pure nothrow @nogc
unittest
{
    // 400 rows in a 100-row viewport over a 400-unit track: 1 track unit
    // per row, so positions map 1:1 and the math is readable.
    const e = ScrollExtents(content: 400, viewport: 100, track: 400);
    ScrollView sv;
    CaptureState cap;
    enum id = 7;

    // A press on the track jumps the leading edge and takes the capture.
    cap = sv.stepV(cap, id, true,
        ScrollPointer(over: true, pressed: true, trackPos: 200), 0, e);
    assert(sv.v.dragging);
    assert(!cap.available(3)); // some other affordance may not act
    assert(cap.available(id)); // already mine

    // The drag tracks wherever the pointer strays; over is irrelevant now.
    cap = sv.stepV(cap, id, true,
        ScrollPointer(over: false, trackPos: 300), sv.v.offset, e);
    const grabbed = sv.v.offset;
    assert(sv.v.dragging && grabbed > 0);

    // Button-up ends the grab; the host frees the capture centrally.
    cap = sv.stepV(cap, id, true,
        ScrollPointer(over: false, released: true, trackPos: 300),
        sv.v.offset, e);
    cap = cap.released();
    assert(!sv.v.dragging && sv.v.offset == grabbed);
    assert(cap.isFree);
}

@("ui.scrollView.livenessAndClamp")
@safe pure nothrow @nogc
unittest
{
    const e = ScrollExtents(content: 50, viewport: 100, track: 100);
    ScrollView sv;
    CaptureState cap;

    // Content fits: not live — hover and grabs drop, presses do nothing.
    sv.h = sv.h.hoveredNow(true);
    cap = sv.stepH(cap, 1, false,
        ScrollPointer(over: true, pressed: true, trackPos: 10), 0, e);
    assert(!sv.h.hovered && !sv.h.dragging && cap.isFree);

    // The synced offset clamps into [0, content − viewport] (SCV2).
    const wide = ScrollExtents(content: 300, viewport: 100, track: 100);
    cap = sv.stepH(cap, 1, true, ScrollPointer(), 999, wide);
    assert(sv.h.offset == 200);
    assert(ScrollView.clampOffset(-5, 300, 100) == 0);

    // A routed wheel scroll clamps the same way (SCV3).
    sv.wheeledH(1000, wide);
    assert(sv.h.offset == 200);
    sv.wheeledH(-1000, wide);
    assert(sv.h.offset == 0);
}

@("ui.scrollView.captureArbitration")
@safe pure nothrow @nogc
unittest
{
    // While another affordance owns the pointer, a press over the bar must
    // not grab — the negation-chain bug made unrepresentable (STM11).
    const e = ScrollExtents(content: 400, viewport: 100, track: 400);
    ScrollView sv;
    auto cap = CaptureState().capturedBy(99);
    cap = sv.stepV(cap, 7, true,
        ScrollPointer(over: true, pressed: true, trackPos: 200), 0, e);
    assert(!sv.v.dragging && sv.v.offset == 0);
}

@("ui.scrollView.pointerShapePriority")
@safe pure nothrow @nogc
unittest
{
    ScrollView sv;
    assert(sv.shape() == PointerShape.default_);
    sv.h = sv.h.hoveredNow(true);
    assert(sv.shape() == PointerShape.ewResize);
    // A vertical grab outranks the horizontal hover.
    sv.v = sv.v.pressed(0, 400, 100, 400);
    assert(sv.shape() == PointerShape.nsResize);
}
