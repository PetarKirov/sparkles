/**
One frame's input, folded from an event stream (`IXB7`, `UIA7`).

hue's frame loop reads input in ~23 places — "is the left button down here",
"where is the pointer", "did the wheel move" — each a separate poll against
raylib. An event stream cannot be read twenty-three times: it is drained once.

So this is the fold between the two shapes. $(LREF FrameInput) is the flags
those sites already want; $(LREF foldFrame) derives them from a sequence of
`sparkles:input` events. The sites keep their structure and stop naming a
backend, which is the whole `UIA7` move.

$(B It is a pure function of a sequence,) which is the point: `gui.d` has no
tests and cannot get any while its input is entangled with a live window, but
the fold has no window in it. Feeding it a scripted event list is how a
click-then-drag, or a press that leaves its target before release, becomes a
unittest — the coverage the screenshot oracle cannot provide, because a capture
of a startup frame says nothing about what a drag does.
*/
module frame_input;

import sparkles.input.events : Event, GestureEvent, Gesture, KeyEvent, match,
    PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.input.gesture : PointF;

@safe:

/**
The pointer/wheel/gesture state of one frame.

Edges (`pressed`, `released`) are true only on the frame they occur; `down` is
the level, carried across frames by $(LREF foldFrame)'s `prior` argument, since
a stream reports transitions and a caller asking "is it held" wants the state.
*/
struct FrameInput
{
    PointF pos;            /// last reported pointer position
    bool leftPressed;      /// left button went down this frame
    bool leftReleased;     /// left button came up this frame
    bool leftDown;         /// left button is held (level, not edge)
    bool backPressed;      /// thumb "back" button, for document-set navigation
    bool forwardPressed;   /// thumb "forward"
    int wheelCells;        /// rows to scroll — already in cells (`INP12`)

    // Resolved touch gestures. A tap arrives as press+release in the pointer
    // fields above; these are the two that have no other spelling.
    bool longPress;
    float pinch = 0;       /// scale ratio; 0 = no pinch this frame
    PointF anchor;         /// where the gesture began, not where it is now
}

/**
Folds `events` into one frame's state, carrying the button level from `prior`.

Pointer position tracks the last event that carried one — including the
release, so a site reading `pos` after `leftReleased` sees where the release
landed rather than a stale motion.
*/
FrameInput foldFrame(R)(R events, in FrameInput prior = FrameInput.init)
{
    FrameInput f;
    f.pos = prior.pos;
    f.anchor = prior.anchor;
    f.leftDown = prior.leftDown;

    foreach (e; events)
        e.match!(
            (in PointerEvent p) {
                f.pos = PointF(p.pos.x, p.pos.y);
                if (p.button == PointerButton.left)
                {
                    if (p.action == PointerAction.press)
                    {
                        f.leftPressed = true;
                        f.leftDown = true;
                    }
                    else if (p.action == PointerAction.release)
                    {
                        f.leftReleased = true;
                        f.leftDown = false;
                    }
                }
                else if (p.action == PointerAction.press)
                {
                    if (p.button == PointerButton.back)
                        f.backPressed = true;
                    else if (p.button == PointerButton.forward)
                        f.forwardPressed = true;
                }
            },
            (in WheelEvent w) {
                // Already cells (INP12) — accumulate, never re-multiply.
                f.wheelCells += w.dy;
                f.pos = PointF(w.pos.x, w.pos.y);
            },
            (in GestureEvent g) {
                f.anchor = PointF(g.pos.x, g.pos.y);
                if (g.gesture == Gesture.longPress)
                    f.longPress = true;
                else
                    f.pinch = g.scale;
            },
            (in _) {},
        );
    return f;
}

// ---------------------------------------------------------------------------
// Tests — the input oracle `gui.d` cannot host itself.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Point;

    Event press(int x, int y, PointerButton b = PointerButton.left)
        => Event(PointerEvent(action: PointerAction.press, button: b,
            pos: Point(x, y)));
    Event release(int x, int y, PointerButton b = PointerButton.left)
        => Event(PointerEvent(action: PointerAction.release, button: b,
            pos: Point(x, y)));
    Event drag(int x, int y)
        => Event(PointerEvent(action: PointerAction.drag,
            button: PointerButton.left, pos: Point(x, y)));
}

@("frame_input.edgesAreOneFrame")
@safe unittest
{
    // A press is an edge and a level; the NEXT frame keeps the level only.
    const down = foldFrame([press(10, 20)]);
    assert(down.leftPressed && down.leftDown && !down.leftReleased);
    assert(down.pos == PointF(10, 20));

    const held = foldFrame([drag(12, 22)], down);
    assert(!held.leftPressed, "an edge must not survive its frame");
    assert(held.leftDown, "the level must survive");
    assert(held.pos == PointF(12, 22));

    const up = foldFrame([release(14, 24)], held);
    assert(up.leftReleased && !up.leftDown);
    // The release position is what a site reads after it — not a stale motion.
    assert(up.pos == PointF(14, 24));

    const idle = foldFrame(Event[].init, up);
    assert(!idle.leftReleased && !idle.leftDown);
    assert(idle.pos == PointF(14, 24), "position persists when nothing moves");
}

@("frame_input.pressAndReleaseInOneFrame")
@safe unittest
{
    // A tap arrives as both in one drain — the touch recogniser's spelling.
    // Both edges must be visible, and the level must end low: a site that
    // only checked `leftDown` would miss the tap entirely.
    const tap = foldFrame([press(5, 5), release(5, 5)]);
    assert(tap.leftPressed && tap.leftReleased && !tap.leftDown);
}

@("frame_input.wheelAccumulatesInCells")
@safe unittest
{
    // INP12: the producer already multiplied, so the fold sums and never
    // scales. Two notches in one frame is one scroll of six.
    const w = foldFrame([
        Event(WheelEvent(dy: 3, pos: Point(1, 1))),
        Event(WheelEvent(dy: 3, pos: Point(1, 1))),
    ]);
    assert(w.wheelCells == 6);

    // Opposite directions cancel rather than fighting.
    const z = foldFrame([
        Event(WheelEvent(dy: 3)), Event(WheelEvent(dy: -3)),
    ]);
    assert(z.wheelCells == 0);
    // And a frame with no wheel reports none, rather than inheriting.
    assert(foldFrame(Event[].init, w).wheelCells == 0);
}

@("frame_input.thumbButtonsAreSeparate")
@safe unittest
{
    // Back/forward navigate the document set and must not read as a click —
    // `PointerButton.none` sits mid-enum, so an index cast would confuse them.
    const b = foldFrame([press(0, 0, PointerButton.back)]);
    assert(b.backPressed && !b.leftPressed && !b.leftDown);

    const f = foldFrame([press(0, 0, PointerButton.forward)]);
    assert(f.forwardPressed && !f.backPressed);
}

@("frame_input.gesturesCarryTheirAnchor")
@safe unittest
{
    // The anchor is where the gesture BEGAN: slop can exceed half a toolbar
    // segment, so acting on the live pointer aims at the wrong thing.
    const lp = foldFrame([Event(GestureEvent(Gesture.longPress, Point(40, 90)))]);
    assert(lp.longPress && lp.anchor == PointF(40, 90));
    assert(lp.pinch == 0, "a long press does not scale");

    const pz = foldFrame([Event(GestureEvent(Gesture.pinch, Point(7, 8), 1.5))]);
    assert(pz.pinch == 1.5 && !pz.longPress);

    // A quiet frame clears the gesture flags but keeps the anchor, so a
    // handler reacting one frame later still knows where it happened.
    const after = foldFrame(Event[].init, lp);
    assert(!after.longPress && after.anchor == PointF(40, 90));
}
