/** Shared scroll position, spring/fling motion, touch tracking and overlay-bar state. */
module sparkles.ui.components.scroll_body;

import std.math : exp, isFinite;
import sparkles.input : PointerAction, PointerEvent, WheelEvent;
import sparkles.ui.components.scroll_view : OverlayBar;
import sparkles.ui.scroll_motion : ScrollMotion;

/// The monotonic clock, in seconds: what a caller of
/// `ScrollBody.scroll(w, seconds)` and the drag methods passes. The body
/// itself reads no clock, so its tests can drive time.
double scrollSeconds() @safe nothrow @nogc
{
    import core.time : MonoTime;

    return MonoTime.currTime.ticks / cast(double) MonoTime.ticksPerSecond;
}

/// One vertical scroll body, in caller-chosen content units.
struct ScrollBody
{
    /// The position, in content units.
    ScrollMotion motion;
    /// The bar's grab and fade.
    OverlayBar bar;
    /// The content's and the viewport's heights, as last laid out.
    long content, viewport;
    /// The bar's node in the last tree (`uint.max`: none).
    uint barNode = uint.max;
    /// A touch screen: the bar fades when idle.
    bool touch;
    /// Draw the bar at its full width (`scrollbar.touchWidth`).
    bool wide;
    private bool dragging;
    private double pointer = 0, sampledAt = 0, dragVelocity = 0;
    // A trackpad's precise scroll: its filtered velocity, when it was last
    // sampled, and when it last moved (`scroll(w, seconds)`).
    private double wheelVelocity = 0, wheelSampledAt = 0, wheelMovedAt = -double.infinity;

    /// Begins a content drag; pointer coordinates use the same units as pos.
    /// Times are monotonic seconds supplied by the caller, with no clock owned here.
    void beginDrag(double at, double seconds) @safe pure nothrow @nogc
    {
        if (!at.isFinite || !seconds.isFinite) return;
        motion.stop();
        dragging = true;
        pointer = at;
        sampledAt = seconds;
        dragVelocity = 0;
        bar.anim.stepFade(true, 0);
    }

    /// Follows the finger exactly, retaining a filtered actual-content velocity.
    void dragTo(double at, double seconds) @safe pure nothrow @nogc
    {
        if (!dragging || !at.isFinite || !seconds.isFinite || at == pointer) return;
        const before = motion.pos;
        motion.drag(pointer - at, limit);
        const dt = seconds - sampledAt;
        if (dt > 0)
        {
            const weight = 1 - exp(-dt / 0.04);
            dragVelocity += ((motion.pos - before) / dt - dragVelocity) * weight;
            sampledAt = seconds;
        }
        pointer = at;
        bar.anim.stepFade(true, 0);
    }

    /// Releases into a fling; a held/stale contact releases without momentum.
    void endDrag(double seconds) @safe pure nothrow @nogc
    {
        if (!dragging) return;
        dragging = false;
        if (seconds.isFinite && seconds >= sampledAt && seconds - sampledAt <= 0.1)
            motion.fling(dragVelocity);
        dragVelocity = 0;
    }

    /// Cancels a contact without releasing a fling (capture went to an editor).
    void cancelDrag() @safe pure nothrow @nogc
    {
        dragging = false;
        dragVelocity = 0;
    }

    /// The largest position.
    double limit() const @safe pure nothrow @nogc
        => content > viewport ? content - viewport : 0;

    /// A wheel notch eases, a drag follows (`WheelEvent.precise`).
    void scroll(in WheelEvent w) @safe pure nothrow @nogc
    {
        const rows = w.exactY;
        if (w.precise)
            motion.drag(rows, limit);
        else
            motion.nudge(rows, limit);
        bar.anim.stepFade(true, 0);
    }

    /**
    A wheel event at `seconds` (monotonic, the caller's clock), with this
    body's own momentum (`INP26`): a precise scroll follows the fingers, and
    when they lift (`WheelEvent.ends`) the view flings at the velocity they
    had — the same fling a touch drag releases into (`endDrag`), so a
    trackpad coasts as a phone does. The platform's own inertia
    (`WheelEvent.momentum`) is ignored, so the view coasts once. A notch
    eases, as `scroll(w)` does.

    Nothing is held open between events: a source that never reports `ends`
    (a touch recognizer's fling tail, a continuous wheel) just scrolls.
    */
    void scroll(in WheelEvent w, double seconds) @safe pure nothrow @nogc
    {
        if (w.momentum)
            return;
        if (!w.precise)
        {
            scroll(w);
            return;
        }
        if (w.begins)
        {
            motion.stop();
            wheelVelocity = 0;
            wheelSampledAt = seconds;
        }
        const rows = w.exactY;
        if (rows != 0 && seconds.isFinite)
        {
            const before = motion.pos;
            motion.drag(rows, limit);
            const dt = seconds - wheelSampledAt;
            if (dt > 0)
            {
                const weight = 1 - exp(-dt / 0.04);
                wheelVelocity += ((motion.pos - before) / dt - wheelVelocity) * weight;
            }
            wheelSampledAt = seconds;
            wheelMovedAt = seconds;
        }
        else if (rows != 0)
            motion.drag(rows, limit);
        bar.anim.stepFade(true, 0);
        // Fingers that rested before lifting release without momentum.
        if (w.ends && seconds.isFinite && seconds - wheelMovedAt <= 0.1)
            motion.fling(wheelVelocity);
        if (w.ends)
            wheelVelocity = 0;
    }

    /// A key moved the view `rows`: eased.
    void by(double rows) @safe pure nothrow @nogc
    {
        motion.nudge(rows, limit);
        bar.anim.stepFade(true, 0);
    }

    /// The bar dragged the view to `pos` rows: at once.
    void barTo(double pos) @safe pure nothrow @nogc
    {
        motion.jumpTo(pos, limit);
        bar.anim.stepFade(true, 0);
    }

    /// One frame: true while the motion or the fade needs the next.
    bool animate(float dt) @safe pure nothrow @nogc
    {
        if (dragging) motion.drag(0, limit);
        const moving = !dragging && motion.step(dt, limit);
        if (!touch)
            return moving;
        bar.anim.stepFade(moving || dragging || bar.grabbed, dt);
        return moving || bar.anim.fading;
    }
}

/// What one pointer event did to a $(LREF TouchPan).
enum TouchStep : ubyte
{
    ignored,   /// Not the captured touch, or none is captured.
    holding,   /// Still undecided: within the slop, or travelling sideways.
    panning,   /// The drag scrolls the body.
    tapped,    /// Released within the slop: the press was a tap.
    cancelled, /// Left the surface, or lifted after travelling too far sideways.
}

/**
One finger on a $(LREF ScrollBody): the press captures it, a drag that travels
`slop` vertically (and more vertically than sideways) pans the body under the
finger and flings on release, and a release that stayed within `slop` on both
axes is a tap. Positions are the pointer's own units; `rowUnits` of them make
one of the body's content units.
*/
struct TouchPan
{
    private PointerEvent press_;
    private bool active_, panning_;

    /// A touch is captured.
    bool active() const @safe pure nothrow @nogc => active_;

    /// The captured touch pans the body.
    bool panning() const @safe pure nothrow @nogc => panning_;

    /// The press that started the captured touch.
    PointerEvent press() const @safe pure nothrow @nogc => press_;

    /// Whether `event` belongs to the captured touch.
    bool captures(in PointerEvent event) const @safe pure nothrow @nogc
        => active_ && event.pointerId == press_.pointerId;

    /// Capture the touch `press` and begin dragging `body` (touch fading, smooth motion).
    void begin(ref ScrollBody body, in PointerEvent press, int rowUnits, double seconds)
        @safe pure nothrow @nogc
    {
        active_ = true;
        panning_ = false;
        press_ = press;
        body.touch = true;
        body.motion.instant = false;
        body.beginDrag(press.pos.y / cast(double) unit(rowUnits), seconds);
    }

    /// Release the captured touch without a fling or a tap.
    void cancel(ref ScrollBody body) @safe pure nothrow @nogc
    {
        active_ = panning_ = false;
        body.cancelDrag();
    }

    /// Feed a later event; only the captured touch's events are taken.
    TouchStep track(ref ScrollBody body, in PointerEvent event, int rowUnits, int slop, double seconds)
        @safe pure nothrow @nogc
    {
        if (!captures(event)) return TouchStep.ignored;
        if (event.action == PointerAction.leave)
        {
            cancel(body);
            return TouchStep.cancelled;
        }
        const dx = event.pos.x - press_.pos.x, dy = event.pos.y - press_.pos.y;
        const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
        if (!panning_ && ay >= slop && ay > ax) panning_ = true;
        if (panning_)
        {
            body.dragTo(event.pos.y / cast(double) unit(rowUnits), seconds);
            if (event.action == PointerAction.release)
            {
                body.endDrag(seconds);
                active_ = panning_ = false;
            }
            return TouchStep.panning;
        }
        if (event.action != PointerAction.release) return TouchStep.holding;
        cancel(body);
        return ax < slop && ay < slop ? TouchStep.tapped : TouchStep.cancelled;
    }

    private static int unit(int rowUnits) @safe pure nothrow @nogc => rowUnits > 0 ? rowUnits : 1;
}

/// A short touch taps, a vertical drag pans and flings, a sideways one does neither.
@("ui.scroll_body.touchPan")
@safe pure nothrow @nogc unittest
{
    import sparkles.input : Point;
    ScrollBody body;
    body.content = 100;
    body.viewport = 10;
    TouchPan pan;
    static PointerEvent at(PointerAction action, int x, int y, ubyte id = 0)
        => PointerEvent(action, pos: Point(x, y), pointerId: id);

    pan.begin(body, at(PointerAction.press, 50, 100), 10, 0);
    assert(pan.active && body.touch);
    assert(pan.track(body, at(PointerAction.drag, 52, 102, 7), 10, 4, 0.01) == TouchStep.ignored);
    assert(pan.track(body, at(PointerAction.drag, 52, 102), 10, 4, 0.01) == TouchStep.holding);
    assert(pan.track(body, at(PointerAction.release, 52, 102), 10, 4, 0.02) == TouchStep.tapped);
    assert(!pan.active && body.motion.pos == 0);

    pan.begin(body, at(PointerAction.press, 50, 100), 10, 1);
    assert(pan.track(body, at(PointerAction.drag, 50, 80), 10, 4, 1.01) == TouchStep.panning);
    assert(pan.panning && body.motion.pos == 2);
    assert(pan.track(body, at(PointerAction.release, 50, 70), 10, 4, 1.02) == TouchStep.panning);
    assert(!pan.active && body.motion.active, "a moving release flings");

    pan.begin(body, at(PointerAction.press, 50, 100), 10, 2);
    assert(pan.track(body, at(PointerAction.drag, 80, 103), 10, 4, 2.01) == TouchStep.holding);
    assert(pan.track(body, at(PointerAction.release, 80, 103), 10, 4, 2.02) == TouchStep.cancelled);
    pan.begin(body, at(PointerAction.press, 50, 100), 10, 3);
    assert(pan.track(body, at(PointerAction.leave, 50, 100), 10, 4, 3.01) == TouchStep.cancelled);
    assert(!pan.active);
}

/// Fractional contact motion, release inertia, interruption and bounds share
/// one state regardless of the app's input adapter.
@("ui.scroll_body.touchDragAndMomentum")
@safe pure nothrow @nogc unittest
{
    ScrollBody body;
    body.content = 100;
    body.viewport = 10;
    body.beginDrag(10, 0);
    body.dragTo(9.25, 0.02);
    assert(body.motion.pos == 0.75 && body.motion.frac == 0.75);
    assert(!body.animate(0.016f), "a held drag has no autonomous motion");
    body.endDrag(0.02);
    assert(body.animate(0.016f) && body.motion.pos > 0.75);
    body.beginDrag(9.25, 0.04);
    const stopped = body.motion.pos;
    assert(!body.animate(0.016f) && body.motion.pos == stopped);
    body.dragTo(8.25, 0.06);
    body.dragTo(8.25, 0.3); // release events repeat the last pointer position
    body.endDrag(0.3);
    assert(!body.motion.active, "holding before release suppresses stale velocity");
    body.beginDrag(10, 1);
    body.dragTo(0, 1.02);
    body.cancelDrag();
    assert(!body.motion.active, "capture transferred without a fling");
    body.motion.jumpTo(89, body.limit);
    body.beginDrag(10, 2);
    body.dragTo(0, 2.02);
    body.endDrag(2.02);
    cast(void) body.animate(0.1f);
    assert(body.motion.pos == 90 && !body.motion.active);
    body.content = 5;
    body.beginDrag(10, 3);
    cast(void) body.animate(0.016f);
    assert(body.motion.pos == 0);
    body.cancelDrag();
}

/// Wheel notches accumulate an eased target; precise deltas follow directly.
@("ui.scroll_body.wheelAndInstantTargets")
@safe pure nothrow @nogc unittest
{
    ScrollBody body;
    body.content = 100;
    body.viewport = 10;
    body.by(3);
    body.by(3);
    assert(body.motion.target == 6 && body.motion.pos == 0);
    foreach (i; 0 .. 180) cast(void) body.animate(1.0f / 60);
    assert(body.motion.pos == 6 && !body.motion.active);
    body.scroll(WheelEvent(dy: 0, precise: true, fdy: 0.25));
    assert(body.motion.pos == 6.25);
    body.motion.instant = true;
    body.by(3);
    assert(body.motion.pos == 9 && !body.motion.active);
}

/// A trackpad flings when its fingers lift, from the velocity they had; the
/// platform's own inertia after the lift scrolls nothing (`INP26`).
@("ui.scroll_body.trackpadFlingsOnLift")
@safe pure nothrow @nogc unittest
{
    ScrollBody body;
    body.content = 1000;
    body.viewport = 10;
    body.scroll(WheelEvent(precise: true, fdy: 0.5, begins: true), 0);
    foreach (i; 1 .. 6)
        body.scroll(WheelEvent(precise: true, fdy: 0.5), i * 0.01);
    const lifted = body.motion.pos;
    assert(lifted == 3, "the fingers are followed exactly");
    body.scroll(WheelEvent(precise: true, ends: true), 0.06);
    assert(body.motion.active, "the lift flings");
    foreach (_; 0 .. 4)
        body.scroll(WheelEvent(precise: true, fdy: 5, momentum: true), 0.07);
    assert(body.motion.pos == lifted, "the platform's inertia is not applied too");
    cast(void) body.animate(0.016f);
    assert(body.motion.pos > lifted, "the fling carries the view on");

    // A new touch stops the coast.
    body.scroll(WheelEvent(precise: true, begins: true), 0.2);
    assert(!body.motion.active);

    // Fingers that rest before lifting do not fling.
    const rested = body.motion.pos;
    body.scroll(WheelEvent(precise: true, fdy: 0.5), 0.21);
    body.scroll(WheelEvent(precise: true, ends: true), 0.5);
    assert(!body.motion.active && body.motion.pos == rested + 0.5);

    // A source that never ends (a touch recognizer's tail) just scrolls,
    // and leaves nothing that holds later notches back.
    body.scroll(WheelEvent(precise: true, fdy: 1, begins: true), 1);
    body.scroll(WheelEvent(dy: 3), 1.1);
    assert(body.motion.target == body.motion.pos + 3 || body.motion.active);
}
