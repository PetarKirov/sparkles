/**
Gesture recognition (`GST1`–`GST5`): a stream transducer that turns raw
pointer samples into the shared vocabulary.

Pure, device-coordinate, host-tested — no windowing library, no platform call.
Adapters own polling; this owns policy, which is what lets one recogniser serve
every target. A terminal on a touchscreen delivers the same press/drag/release
stream `sparkles:tui` already decodes, so nothing here is raylib- or
Android-specific.

$(B What comes out.) Gestures that already have a spelling are emitted in it
(`GST2`): a tap is `PointerEvent(press)` then `(release)`, a drag or fling is a
`WheelEvent`. Downstream code therefore never branches on modality — a tap
$(I is) a click, and a drag $(I is) a scroll. Only long-press and pinch, which
have no existing spelling, arrive as `GestureEvent`.

$(B Coordinates.) Recognition thresholds are physical distances — a slop radius
of twelve pixels is not expressible in cells — so this runs in device space,
upstream of the cell quantisation, and the adapter converts the output
(`GST4`). That is the same "events for edges, pixels for geometry" split the
scrollbars already use.

Extracted from `apps/hue`'s `gui_touch.d`, which was pure and host-tested but
filed under an application (`IXR16`).
*/
module sparkles.input.gesture;

import sparkles.input.events;

/// Device-space position: sub-cell, because recognition thresholds are
/// physical distances rather than grid steps.
struct PointF
{
    float x = 0;
    float y = 0;
}

/// Recognition tunables, in physical pixels. A caller scales `slopPx` by its
/// cell height so the radius tracks the rendered text size.
struct GestureConfig
{
    float slopPx = 12;         /// movement below this radius stays a tap
    float longPressMs = 500;   /// held this long within slop = long-press
    float flingFriction = 4.5; /// exponential decay of the fling tail (1/s)
    float minFlingSpeed = 60;  /// px/s below which momentum stops
    float pinchIn = 0.87;      /// separation ratio that reads as zoom out
    float pinchOut = 1.15;     /// …and as zoom in
    float cellH = 16;          /// device px per row, for scroll quantisation
}

/**
One recogniser per surface. Value semantics; `@safe pure nothrow @nogc`
throughout.

Feed raw samples with $(LREF pointer), advance time with $(LREF tick), and
drain resolved events with $(LREF next) — the same drain shape adapters
already use. Positions come out in device space; the adapter quantises.
*/
struct GestureRecognizer
{
    /// See $(LREF GestureConfig).
    GestureConfig cfg;

@safe pure nothrow @nogc:

    private
    {
        // Single-pointer gesture state (the primary contact).
        bool wasDown_, dragging_, longFired_;
        float startX_ = 0, startY_ = 0, lastY_ = 0;
        float holdMs_ = 0;
        float velocity_ = 0; // px/s at release

        // Multi-touch: a pinch owns the pointer until EVERY contact lifts.
        ubyte contacts_;
        bool pinching_;
        float prevPinchDist_ = 0;
        float pinchScale_ = 1;
        bool pinchPending_;

        // Pixels since the last `tick`, and the last per-sample step (for the
        // release velocity). Scroll is coalesced into ONE wheel event per
        // tick rather than one per sample: that matches how a frame loop
        // consumes it, and — the reason it is not merely tidier — it bounds
        // the queue. Emitting per sample overflowed a fixed queue and silently
        // dropped rows.
        float pendingPx_ = 0;
        float lastStepPx_ = 0;

        // Deepest simultaneous resolution: press + release + one gesture + one
        // wheel step.
        Event[4] queue_;
        ubyte queued_;

        void emit(Event e)
        {
            assert(queued_ < queue_.length, "gesture queue overflow");
            if (queued_ < queue_.length)
                queue_[queued_++] = e;
        }
    }

    /// The number of live contacts, as the adapter last reported it.
    ubyte contacts() const => contacts_;

    /// `true` while a scroll drag owns the pointer — a host can suppress
    /// hover or press affordances for its duration.
    bool dragging() const => dragging_;

    /**
    Abandon the in-flight gesture without resolving it: the spelling for
    "something else took the pointer".

    Feeding $(LREF pointer) a synthetic release does $(I not) do this — the
    release path cannot tell a real lift from a fake one, so it resolves the
    gesture, firing a tap and leaving any fling tail running. That distinction
    was a real defect before this type existed.
    */
    void cancel()
    {
        wasDown_ = dragging_ = longFired_ = false;
        holdMs_ = velocity_ = 0;
        pendingPx_ = lastStepPx_ = 0;
    }

    /**
    Feed one raw sample. `id` is the platform's stable contact id (`0` = the
    mouse or the first finger), `down` that contact's button state, `at` its
    device-space position.

    Report every live contact each frame, then call $(LREF tick).
    */
    void pointer(ubyte id, bool down, PointF at)
    {
        if (id != 0)
            return; // secondary contacts are counted, not tracked — see setContacts
        if (pinching_)
            return; // a pinch owns the pointer; nothing resolves under it

        if (down && !wasDown_)
        {
            startX_ = at.x;
            startY_ = at.y;
            lastY_ = at.y;
            holdMs_ = 0;
            dragging_ = false;
            longFired_ = false;
            velocity_ = 0; // a new touch stops a running fling
        }
        else if (down)
        {
            const dx = at.x - startX_;
            const dy = at.y - startY_;
            if (!dragging_ && !longFired_ && dx * dx + dy * dy > cfg.slopPx * cfg.slopPx)
                dragging_ = true;
        }
        else if (wasDown_ && !dragging_ && !longFired_ && holdMs_ < cfg.longPressMs)
        {
            // A tap: emitted in the vocabulary that already exists, at the
            // ANCHOR rather than the release point — a tap acts where it began
            // (slop can exceed a target's width).
            emit(Event(PointerEvent(action: PointerAction.press,
                button: PointerButton.left, pos: Point(0, 0))));
            emit(Event(PointerEvent(action: PointerAction.release,
                button: PointerButton.left, pos: Point(0, 0))));
        }

        if (down && dragging_)
        {
            // Finger down (+y) reveals earlier lines: the content follows the
            // finger, so the view scrolls toward the start.
            lastStepPx_ = at.y - lastY_;
            pendingPx_ += -lastStepPx_;
        }

        if (!down)
            dragging_ = false;
        lastY_ = at.y;
        wasDown_ = down;
    }

    /// Report how many contacts are live this frame. Two or more latch a
    /// pinch, which is released only at ZERO — dropping to one would otherwise
    /// start a fresh gesture on the remaining finger and fire a spurious tap.
    void setContacts(ubyte n, PointF a, PointF b)
    {
        contacts_ = n;
        if (n >= 2)
        {
            if (!pinching_)
            {
                pinching_ = true;
                cancel();
                prevPinchDist_ = 0;
            }
            const dx = b.x - a.x, dy = b.y - a.y;
            const dist = sqrtApprox(dx * dx + dy * dy);
            if (prevPinchDist_ > 0)
            {
                const ratio = dist / prevPinchDist_;
                if (ratio > cfg.pinchOut || ratio < cfg.pinchIn)
                {
                    pinchScale_ = ratio;
                    pinchPending_ = true;
                    prevPinchDist_ = dist;
                }
            }
            else
                prevPinchDist_ = dist;
        }
        else if (n == 0)
        {
            pinching_ = false;
            prevPinchDist_ = 0;
        }
    }

    /// Advance time with no new sample: the fling tail and the long-press
    /// threshold both resolve without further input (`GST5`).
    void tick(float dtMs)
    {
        const dt = dtMs <= 0 ? 1e-4f : dtMs / 1000;

        // Velocity is computed HERE, where the real frame duration is known.
        // Deriving it in `pointer` needs a dt that call does not have, and
        // inventing one makes every fling wrong by that factor.
        if (wasDown_ && dragging_)
        {
            velocity_ = lastStepPx_ / dt;
            lastStepPx_ = 0;
        }

        flushScroll();

        if (pinching_)
        {
            if (pinchPending_)
            {
                emit(Event(GestureEvent(Gesture.pinch, Point(0, 0), pinchScale_)));
                pinchPending_ = false;
            }
            return;
        }

        if (wasDown_ && !dragging_ && !longFired_)
        {
            holdMs_ += dtMs;
            if (holdMs_ >= cfg.longPressMs)
            {
                longFired_ = true;
                emit(Event(GestureEvent(Gesture.longPress, Point(0, 0))));
            }
        }
        else if (!wasDown_ && velocity_ != 0)
        {
            // The fling tail: exponential decay to a full stop.
            pendingPx_ = -velocity_ * dt;
            flushScroll();
            velocity_ *= expApprox(-cfg.flingFriction * dt);
            if (velocity_ > -cfg.minFlingSpeed && velocity_ < cfg.minFlingSpeed)
                velocity_ = 0;
        }
    }

    /**
    Pop the next resolved event, or `Event(NoEvent())` when drained.

    Positions are device-space in `x`/`y` as floats folded into the cell
    `Point`; the adapter re-expresses them (`GST4`). `anchor` reports where the
    in-flight gesture began, for adapters that need it.
    */
    Event next()
    {
        if (queued_ == 0)
            return Event(NoEvent());
        const e = queue_[0];
        foreach (i; 1 .. queued_)
            queue_[i - 1] = queue_[i];
        --queued_;
        return e;
    }

    /// Where the in-flight (or most recent) gesture began, in device space.
    PointF anchor() const => PointF(startX_, startY_);

    private float scrollAccum_ = 0;

    // Pixels accumulate; whole rows are emitted, at most one event per tick.
    // The fractional remainder is carried, so a slow drag is never truncated
    // to nothing.
    private void flushScroll()
    {
        if (pendingPx_ == 0)
            return;
        scrollAccum_ += pendingPx_;
        pendingPx_ = 0;
        const rows = cast(int)(scrollAccum_ / cfg.cellH);
        if (rows == 0)
            return;
        scrollAccum_ -= rows * cfg.cellH;

        // Merge into an undrained wheel event rather than queueing a second.
        // Scrolling is additive, so this is exact — and it means a caller that
        // ticks several times before draining gets the same total instead of
        // overflowing a bounded queue. (An adapter drains every frame; this
        // just removes the footgun.)
        foreach (i; 0 .. queued_)
        {
            bool merged = false;
            queue_[i].match!(
                (ref WheelEvent w) { w.dy += rows; merged = true; },
                (ref _) {},
            );
            if (merged)
                return;
        }
        // `precise`: already whole rows, so no consumer multiplies (INP12).
        emit(Event(WheelEvent(dy: rows, pos: Point(0, 0), precise: true)));
    }

    // The module is `@nogc pure nothrow`; std.math's exp/sqrt are not `pure`
    // in all configurations, and the precision needed here is low.
    private static float expApprox(float x)
    {
        // e^x for small negative x, via a short series — the decay factor is
        // always in (0, 1] for the friction/dt this is called with.
        float term = 1, sum = 1;
        foreach (i; 1 .. 8)
        {
            term *= x / i;
            sum += term;
        }
        return sum < 0 ? 0 : sum;
    }

    private static float sqrtApprox(float v)
    {
        if (v <= 0)
            return 0;
        float g = v;
        foreach (_; 0 .. 12)
            g = 0.5f * (g + v / g);
        return g;
    }
}

// ---------------------------------------------------------------------------
// Tests — ported from apps/hue/src/gui_touch.d, whose four cases are the
// regression net for this extraction. `pointer` + `tick` replaces the old
// polled `update(down, x, y, dt)`; the assertions are on drained events rather
// than a returned Frame.
// ---------------------------------------------------------------------------

version (unittest)
private struct Drain
{
    int scrollRows;
    int presses, releases, longPresses, pinches;
    float lastScale = 1;

    void run(ref GestureRecognizer g) @safe pure nothrow @nogc
    {
        for (auto e = g.next(); !isNoEvent(e); e = g.next())
            e.match!(
                (in PointerEvent p) {
                    if (p.action == PointerAction.press) ++presses;
                    else if (p.action == PointerAction.release) ++releases;
                },
                (in WheelEvent w) { scrollRows += w.dy; },
                (in GestureEvent ge) {
                    if (ge.gesture == Gesture.longPress) ++longPresses;
                    else { ++pinches; lastScale = ge.scale; }
                },
                (_) {},
            );
    }
}

version (unittest)
private bool isNoEvent(in Event e) @safe pure nothrow @nogc
    => e.match!((in NoEvent _) => true, _ => false);

@("input.gesture.tapUnderSlopBecomesPressRelease")
@safe pure nothrow @nogc
unittest
{
    // A tap has no gesture case of its own: it arrives as the click it is.
    GestureRecognizer g;
    Drain d;
    g.pointer(0, true, PointF(100, 100));
    g.tick(16);
    d.run(g);
    assert(d.presses == 0 && d.releases == 0); // nothing on press alone

    g.pointer(0, true, PointF(104, 103)); // within slop
    g.tick(16);
    d.run(g);
    assert(d.scrollRows == 0);

    g.pointer(0, false, PointF(104, 103)); // release, fast
    g.tick(16);
    d.run(g);
    assert(d.presses == 1 && d.releases == 1);
    assert(d.longPresses == 0);
    assert(g.anchor().x == 100 && g.anchor().y == 100);
}

@("input.gesture.dragScrollsAndFlings")
@safe pure nothrow @nogc
unittest
{
    GestureRecognizer g;
    g.cfg.cellH = 10;
    Drain d;
    g.pointer(0, true, PointF(100, 400));
    g.tick(16);
    foreach (i; 0 .. 5)
    {
        g.pointer(0, true, PointF(100, 400 - 30 * (i + 1)));
        g.tick(16);
    }
    d.run(g);
    assert(d.scrollRows == 15); // 150 px at 10 px/row, all of it
    assert(d.presses == 0);     // a drag is never a click

    // Release at speed → the fling continues, decaying to a stop.
    g.pointer(0, false, PointF(100, 250));
    g.tick(16);
    const beforeTail = d.scrollRows;
    d.run(g);
    foreach (_; 0 .. 400)
    {
        g.tick(16);
        d.run(g);
    }
    assert(d.scrollRows > beforeTail); // it coasted
    const settled = d.scrollRows;
    foreach (_; 0 .. 50)
    {
        g.tick(16);
        d.run(g);
    }
    assert(d.scrollRows == settled); // and stopped
}

@("input.gesture.longPressFiresOnceAndLocksOut")
@safe pure nothrow @nogc
unittest
{
    GestureRecognizer g;
    Drain d;
    g.pointer(0, true, PointF(50, 60));
    g.tick(16);
    foreach (_; 0 .. 60) // ~1 s held still
    {
        g.pointer(0, true, PointF(52, 61));
        g.tick(16);
        d.run(g);
    }
    assert(d.longPresses == 1); // exactly once

    // Movement afterwards is not a scroll drag; release is not a tap.
    g.pointer(0, true, PointF(52, 200));
    g.tick(16);
    g.pointer(0, false, PointF(52, 200));
    g.tick(16);
    d.run(g);
    assert(d.scrollRows == 0);
    assert(d.presses == 0 && d.releases == 0);
}

@("input.gesture.slowDragNoFling")
@safe pure nothrow @nogc
unittest
{
    GestureRecognizer g;
    g.cfg.cellH = 10;
    Drain d;
    g.pointer(0, true, PointF(10, 100));
    g.tick(16);
    g.pointer(0, true, PointF(10, 120)); // past slop → dragging
    g.tick(16);
    g.pointer(0, true, PointF(10, 120.5)); // nearly stopped
    g.tick(16);
    g.pointer(0, false, PointF(10, 120.5));
    g.tick(16);
    d.run(g);
    const atRelease = d.scrollRows;
    foreach (_; 0 .. 20)
    {
        g.tick(16);
        d.run(g);
    }
    assert(d.scrollRows == atRelease); // no momentum from a slow release
}

@("input.gesture.pinchCancelsAndScales")
@safe pure nothrow @nogc
unittest
{
    // The defect this type exists to prevent: a second contact arriving
    // mid-press must NOT resolve the press as a tap.
    GestureRecognizer g;
    Drain d;
    g.pointer(0, true, PointF(100, 100));
    g.tick(16);
    g.setContacts(2, PointF(100, 100), PointF(200, 100));
    g.tick(16);
    g.setContacts(2, PointF(100, 100), PointF(260, 100)); // spread 1.6×
    g.tick(16);
    d.run(g);
    assert(d.presses == 0 && d.releases == 0, "a pinch is not a tap");
    assert(d.pinches >= 1);
    assert(d.lastScale > 1); // zoom in

    // Dropping to ONE contact must not start a fresh gesture — only zero ends
    // the pinch.
    g.setContacts(1, PointF(100, 100), PointF());
    g.pointer(0, false, PointF(100, 100));
    g.tick(16);
    d.run(g);
    assert(d.presses == 0 && d.releases == 0, "lifting one finger is not a tap");
}
