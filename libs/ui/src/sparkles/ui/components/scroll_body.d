/** Shared scroll position, spring/fling motion, touch tracking and overlay-bar state. */
module sparkles.ui.components.scroll_body;

import std.math : exp, isFinite;
import sparkles.input : WheelEvent;
import sparkles.ui.components.scroll_view : OverlayBar;
import sparkles.ui.scroll_motion : ScrollMotion;

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
