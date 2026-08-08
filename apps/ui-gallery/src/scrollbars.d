/**
Driving a scrollbar the way the toolkit intends — once, for every bar in the
gallery.

The first version of this application rendered its bars with the position-only
`scrollbar` overload and kept a bare `ScrollState`. That draws a correct thumb
and is otherwise inert: no grab, no hover, no capture, no easing. All four live
on $(REF ScrollView, sparkles,ui,scroll_view), which folds both axes' machines,
the capture protocol and the hover-expand easing into one per-frame transition —
and an application that reaches past it to `ScrollState` has opted out of the
whole thing without noticing.

$(B The cell backend cannot render hue's bar.) hue's window draws a ⅓-cell rail
easing open to 1.5 cells, which is sub-cell geometry reachable only by driving
the canvas directly. The gallery is a pure host consumer and paints through the
widget display list on both targets, so its bar eases between $(B one and two
whole columns) instead. The easing is the same value at the same rate; what
differs is that the result is quantised, so the animation reads as a short
delay before the bar widens rather than as a smooth slide. See `UGL-O6`.
*/
module scrollbars;

import sparkles.input : InputCapabilities, PointerAction, PointerButton,
    PointerEvent;
import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;
import sparkles.ui.geometry : Rect, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.scroll_view : ScrollExtents, ScrollPointer, ScrollView;
import sparkles.ui.state : CaptureState;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

@safe:

/**
Capture ids, one per grabbable affordance.

Distinct and non-zero, because `CaptureState` arbitrates by id: two affordances
sharing one would each believe they owned a drag the other started.
*/
enum size_t capContentBar = 1; /// the shell's content pane
enum size_t capDemoBar = 2;    /// the Scrolling page's specimen
enum size_t capSplit = 3;      /// the Split page's divider
enum size_t capChromeBar = 4;  /// the Components page's live scroll view

/// The columns a vertical bar's gutter reserves. Fixed, so the pane's width
/// does not change when the bar expands — a page that reflowed on hover would
/// be unreadable.
enum int gutterCells = 2;

/// What one bar scrolls over, in cells.
struct BarGeometry
{
    long content;  /// total rows
    long viewport; /// rows visible at once
    int track;     /// the bar's own length, in cells
}

/// `true` iff there is anything to scroll. An inert bar is not drawn, and
/// `ScrollView` drops hover and any grab for an axis that is not live.
bool live(in BarGeometry g) pure nothrow @nogc
    => g.content > g.viewport && g.track > 0;

/**
The bar as a widget: a fixed-width gutter holding one or two glyph columns.

Two columns rather than one while expanded — the cell analogue of hue's
hover-widened rail. The width comes from the eased animation rather than
straight from `hovered || dragging`, so the bar widens a beat after the pointer
arrives and narrows a beat after it leaves, instead of snapping.
*/
uint verticalBar(ref Builder b, in ScrollView sv, in BarGeometry g,
    size_t hitId)
{
    if (!g.live)
        return b.add(Widget(
            kind: WidgetKind.box,
            width: SizeSpec.fixed(gutterCells),
        ));

    const wide = sv.vAnim.width >= 1.5f;
    // Expanded also brightens the track: a one-column bar has no width to
    // spare on a target that rounds it away, and a track that only appears on
    // hover is the affordance saying it is grabbable.
    const glyphs = wide
        ? ScrollbarGlyphs(thumb: '█', track: '░')
        : ScrollbarGlyphs(thumb: '█', track: '│');

    auto columns = new uint[](wide ? 2 : 1);
    foreach (i; 0 .. columns.length)
        columns[i] = scrollbar(b, sv.v, g.content, g.viewport, g.track, glyphs);

    // The hit id sits on the whole gutter, not on the glyph columns — so the
    // grab zone is the bar's EXPANDED width whatever width it is drawn at.
    // Sizing the zone to the current width instead would make the bar hardest
    // to hit precisely while it is still thin, which is every time.
    return b.add(Widget(
        kind: WidgetKind.row,
        children: columns,
        width: SizeSpec.fixed(gutterCells),
        // Right-aligned inside that gutter, so the pane's text edge stays put
        // and only the bar moves outward as it widens.
        alignX: Alignment.end,
        hitId: hitId,
    ));
}

/**
Eases a bar toward its hovered or idle width.

`dtSeconds` of zero means the target has no frame clock — a terminal wakes on
input and reports nothing else. Easing against a zero delta never converges, so
the width snaps instead: the affordance still appears, it simply appears at
once. The same collapse the `Timeline` machine names for the same reason.
*/
void easeVertical(ref ScrollView sv, in InputCapabilities caps, float dtSeconds)
{
    enum float expanded = 2.0f;
    enum float idle = 1.0f;

    if (dtSeconds > 0)
        return sv.easeV(expanded, idle, caps, dtSeconds);
    sv.vAnim.width = sv.v.expanded(caps) ? expanded : idle;
}

/// `true` while the eased width has not reached its target — the cue to ask
/// for another frame, so an animation that nobody is driving still finishes.
bool easing(in ScrollView sv, in InputCapabilities caps) pure nothrow @nogc
{
    const target = sv.v.expanded(caps) ? 2.0f : 1.0f;
    const delta = sv.vAnim.width - target;
    return delta > 0.01f || delta < -0.01f;
}

/**
One pointer event, delivered to one bar.

`barRect` comes from the frames the painter used, so the grab zone cannot drift
from the drawn bar (`IXR27`). Returns `true` iff the bar consumed the event —
which it does for the whole span of a grab, wherever the pointer strays, since
the press owns the drag.
*/
bool driveVertical(ref ScrollView sv, ref CaptureState capture, size_t capId,
    in PointerEvent p, in Rect barRect, in BarGeometry g)
{
    const grabbed = sv.v.dragging;
    const over = barRect.contains(p.pos);

    const sp = ScrollPointer(
        over: over,
        // Only the primary button grabs: a right-click on the bar is a
        // context menu everywhere else, and would be a jump here.
        pressed: p.action == PointerAction.press
            && p.button == PointerButton.left,
        released: p.action == PointerAction.release,
        // Track-relative, and clamped nowhere: `ScrollState.draggedTo` clamps
        // the resulting offset, so a pointer dragged above the track's top
        // pins the thumb there instead of wrapping.
        trackPos: p.pos.y - barRect.y,
    );

    capture = sv.stepV(capture, capId, g.live, sp, sv.v.offset,
        ScrollExtents(g.content, g.viewport, g.track));

    // The release frees the pointer for every affordance, not just this one —
    // a per-affordance release is how a capture leaks, and the one that forgets
    // leaves everything else dead.
    if (sp.released)
        capture = capture.released();

    return grabbed || sv.v.dragging || (over && sp.pressed);
}

/// The painted rect of the node carrying `hitId`, or an empty rect.
///
/// Looked up in the very frames the display list was built from, which is the
/// only way a grab zone and a drawn bar are guaranteed to agree.
Rect rectOf(in WidgetTree tree, in Frame[] frames, size_t hitId)
    pure nothrow @nogc
{
    if (hitId == 0)
        return Rect.init;
    foreach (i, ref node; tree.nodes)
        if (node.hitId == hitId)
            return frames[i].rect;
    return Rect.init;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : cellPointer, mousePointer, Point;

    private enum g = BarGeometry(content: 100, viewport: 10, track: 10);
    private enum bar = Rect(40, 1, 1, 10);

    private PointerEvent at(PointerAction a, int y)
        => PointerEvent(action: a, button: PointerButton.left,
            pos: Point(40, y));
}

@("ui_gallery.scrollbars.pressOnTheTrackJumpsAndGrabs")
@safe unittest
{
    ScrollView sv;
    CaptureState cap;

    // A press halfway down a 10-cell track over 100 rows in a 10-row viewport
    // puts the thumb's leading edge under the pointer.
    assert(driveVertical(sv, cap, capContentBar, at(PointerAction.press, 6),
        bar, g));
    assert(sv.v.dragging);
    assert(sv.v.offset > 0);
    assert(!cap.available(capDemoBar), "the grab owns the pointer");
}

@("ui_gallery.scrollbars.pressOnTheThumbDoesNotMoveIt")
@safe unittest
{
    // The defect a hand-rolled bar always has: taking hold of the handle
    // snaps it under the pointer before the drag has begun.
    ScrollView sv;
    CaptureState cap;
    sv.v = sv.v.scrolledTo(45);

    // Aim at the thumb the formula actually produced, not at a hardcoded cell:
    // its extent is one cell here, so being off by one lands on the track and
    // the test would pass for the wrong reason.
    const thumb = sv.v.thumb(g.content, g.viewport, g.track);
    const before = sv.v.offset;
    driveVertical(sv, cap, capContentBar,
        at(PointerAction.press, bar.y + thumb.start), bar, g);
    assert(sv.v.offset == before, "the thumb was grabbed in place");
    assert(sv.v.dragging);

    // And the drag then moves relative to the grab: one cell down the track
    // is one cell of thumb travel, not a jump to wherever the pointer is.
    auto down = PointerEvent(action: PointerAction.drag,
        button: PointerButton.left,
        pos: Point(bar.x, bar.y + thumb.start + 1));
    driveVertical(sv, cap, capContentBar, down, bar, g);
    assert(sv.v.offset > before);
}

@("ui_gallery.scrollbars.aGrabKeepsTheDragWhereverThePointerStrays")
@safe unittest
{
    ScrollView sv;
    CaptureState cap;
    driveVertical(sv, cap, capContentBar, at(PointerAction.press, 2), bar, g);

    // Far outside the bar's rect. The press owns the drag, so the bar still
    // consumes it and still moves — this is the whole point of the capture.
    auto away = PointerEvent(action: PointerAction.drag,
        button: PointerButton.left, pos: Point(3, 9));
    assert(driveVertical(sv, cap, capContentBar, away, bar, g));
    assert(sv.v.dragging);
    const dragged = sv.v.offset;

    auto up = PointerEvent(action: PointerAction.release,
        button: PointerButton.left, pos: Point(3, 9));
    driveVertical(sv, cap, capContentBar, up, bar, g);
    assert(!sv.v.dragging, "the release ended the grab");
    assert(sv.v.offset == dragged, "and kept the offset");
    assert(cap.isFree, "…and freed the pointer for everything else");
}

@("ui_gallery.scrollbars.aBusyPointerCannotStartASecondGrab")
@safe unittest
{
    // While another affordance owns the pointer a press over the bar must do
    // nothing — the arbitration `CaptureState` exists for.
    ScrollView sv;
    auto cap = CaptureState().capturedBy(capSplit);
    driveVertical(sv, cap, capContentBar, at(PointerAction.press, 6), bar, g);
    assert(!sv.v.dragging && sv.v.offset == 0);
}

@("ui_gallery.scrollbars.anInertBarNeitherHoversNorGrabs")
@safe unittest
{
    // Content that fits: the bar is not drawn and must not be grabbable, or a
    // press on empty gutter would jump a document that cannot scroll.
    ScrollView sv;
    CaptureState cap;
    enum fits = BarGeometry(content: 5, viewport: 10, track: 10);

    driveVertical(sv, cap, capContentBar, at(PointerAction.press, 4), bar, fits);
    assert(!sv.v.dragging && !sv.v.hovered && cap.isFree);

    auto b = Builder();
    const node = verticalBar(b, sv, fits, 42);
    assert(b.nodes[node].children.length == 0, "an inert bar draws nothing");
    assert(b.nodes[node].hitId == 0, "…and is not hit-testable");
}

@("ui_gallery.scrollbars.theWidthEasesRatherThanSnapping")
@safe unittest
{
    // With a frame clock the bar widens over several frames, so hovering it
    // reads as an animation instead of a jump. This is the assertion that
    // fails if the width is taken straight from `hovered || dragging`.
    ScrollView sv;
    sv.vAnim.width = 1.0f;
    sv.v = sv.v.hoveredNow(true);

    assert(easing(sv, mousePointer));
    easeVertical(sv, mousePointer, 1.0f / 60);
    assert(sv.vAnim.width > 1.0f && sv.vAnim.width < 2.0f,
        "one frame is not the whole transition");

    int frames = 1;
    while (easing(sv, mousePointer) && frames < 600)
    {
        easeVertical(sv, mousePointer, 1.0f / 60);
        ++frames;
    }
    assert(frames > 3, "the transition takes more than a frame or two");
    assert(!easing(sv, mousePointer), "…and it converges");
}

@("ui_gallery.scrollbars.withoutAFrameClockTheWidthSnaps")
@safe unittest
{
    // A terminal reports no frame time. Easing against a zero delta never
    // converges, so the affordance would never appear at all.
    ScrollView sv;
    sv.vAnim.width = 1.0f;
    sv.v = sv.v.hoveredNow(true);

    easeVertical(sv, cellPointer, 0);
    assert(sv.vAnim.width == 2.0f);
    assert(!easing(sv, cellPointer), "nothing left to animate");
}

@("ui_gallery.scrollbars.aTargetWithoutHoverIsPermanentlyGrabbable")
@safe unittest
{
    // `IXB10`: hover-expand presumes a pointer that can rest somewhere. Where
    // there is none the honest bar is always wide enough to grab, not a rail
    // waiting for a hover that never comes.
    import sparkles.input : touchPointer;

    ScrollView sv;
    easeVertical(sv, touchPointer, 0);
    assert(sv.vAnim.width == 2.0f);

    auto b = Builder();
    const node = verticalBar(b, sv, g, 7);
    assert(b.nodes[node].children.length == 2, "two columns, unprompted");
}

@("ui_gallery.scrollbars.theBarKeepsItsGutterWhicheverWidthItIs")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    // The pane beside it must not reflow when the bar widens — text jumping
    // sideways as you reach for the scrollbar is worse than a static gutter.
    foreach (width; [1.0f, 2.0f])
    {
        ScrollView sv;
        sv.vAnim.width = width;
        auto b = Builder();
        const node = verticalBar(b, sv, g, 7);
        auto tree = b.finish(node);
        assert(layout(tree, Constraints(maxW: 40))[node].rect.width
            == gutterCells);
    }
}

@("ui_gallery.scrollbars.rectOfFindsThePaintedBar")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    ScrollView sv;
    auto b = Builder();
    const node = verticalBar(b, sv, g, 99);
    auto tree = b.finish(node);
    auto frames = layout(tree, Constraints(maxW: 40));

    assert(rectOf(tree, frames, 99) == frames[node].rect);
    assert(rectOf(tree, frames, 98) == Rect.init, "an unknown id has no rect");
    assert(rectOf(tree, frames, 0) == Rect.init, "zero is not a target");
}
