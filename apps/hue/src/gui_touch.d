/**
Pure touch-gesture classification for the Android GUI — no raylib, no
platform calls, host-tested. The frame loop feeds one-finger pointer samples
(raylib maps the first touch to the mouse) into [TouchScroller.update] and
acts on the returned [TouchScroller.Frame]:

$(LIST
    * $(B tap) — press and release within the slop radius and under the
        long-press threshold: the touch spelling of a click (fold chevrons,
        tree rows, toolbar buttons, the fence copy button);
    * $(B drag) — movement past the slop radius: kinetic scrolling with a
        fling tail (never starts a selection);
    * $(B long-press) — held still past the threshold: enters selection at
        the anchor, after which the existing drag-extends-selection machinery
        takes over (the scroller stops classifying until release).
)
*/
module gui_touch;

/// See the module header. One instance per pointer; value semantics.
struct TouchScroller
{
    // Tunables (pixels are physical; callers scale slop by cell height).
    float slopPx = 12;         /// movement below this radius = still a tap
    float longPressMs = 500;   /// press held this long (within slop) = long-press
    float flingFriction = 4.5; /// exponential decay rate of the fling (1/s)
    float minFlingSpeed = 60;  /// px/s below which momentum stops

    /// One frame's verdict. At most one of `tap`/`longPress` is set, and only
    /// on the frame the gesture resolves.
    struct Frame
    {
        float scrollPx = 0; /// vertical scroll to apply (+ = content down, toward later lines)
        bool tap;           /// completed tap (fired on release)
        bool longPress;     /// hold threshold crossed (fired once, mid-press)
        bool dragging;      /// a scroll drag is in progress
        float x = 0, y = 0; /// gesture anchor (the press position)
    }

    private bool wasDown_, dragging_, longFired_;
    private float startX_ = 0, startY_ = 0, lastY_ = 0;
    private float holdMs_ = 0;
    private float velocity_ = 0; // finger velocity at release, px/s

    /// Feed one frame: `down` = primary pointer held, `x`/`y` = its position,
    /// `dtMs` = frame duration.
    Frame update(bool down, float x, float y, float dtMs) @safe pure nothrow @nogc
    {
        import std.math.exponential : exp;

        Frame f;
        f.x = startX_;
        f.y = startY_;
        const dt = dtMs <= 0 ? 1e-4f : dtMs / 1000;

        if (down && !wasDown_)
        {
            // Press: new gesture; a touch also stops any running fling.
            startX_ = x;
            startY_ = y;
            lastY_ = y;
            holdMs_ = 0;
            dragging_ = false;
            longFired_ = false;
            velocity_ = 0;
            f.x = x;
            f.y = y;
        }
        else if (down)
        {
            holdMs_ += dtMs;
            const dx = x - startX_;
            const dy = y - startY_;
            if (!dragging_ && !longFired_)
            {
                if (dx * dx + dy * dy > slopPx * slopPx)
                    dragging_ = true;
                else if (holdMs_ >= longPressMs)
                {
                    longFired_ = true;
                    f.longPress = true;
                }
            }
            if (dragging_)
            {
                const step = y - lastY_;
                // Finger down (+y) reveals earlier lines: content follows the
                // finger, so the view scrolls toward the start (negative).
                f.scrollPx = -step;
                velocity_ = step / dt;
            }
        }
        else if (wasDown_)
        {
            // Release: resolve the gesture.
            if (dragging_)
            {
                if (velocity_ > -minFlingSpeed && velocity_ < minFlingSpeed)
                    velocity_ = 0; // too slow — no fling tail
            }
            else
            {
                if (!longFired_ && holdMs_ < longPressMs)
                    f.tap = true;
                velocity_ = 0;
            }
            dragging_ = false;
        }
        else if (velocity_ != 0)
        {
            // Idle: the fling tail — exponential decay to a full stop.
            f.scrollPx = -velocity_ * dt;
            velocity_ *= exp(-flingFriction * dt);
            if (velocity_ > -minFlingSpeed && velocity_ < minFlingSpeed)
                velocity_ = 0;
        }

        f.dragging = dragging_;
        lastY_ = y;
        wasDown_ = down;
        return f;
    }

    /// Abandon the in-flight gesture without resolving it — the spelling for
    /// "something else took the pointer" (a second finger landing: a pinch is
    /// not a tap that happens to have two contacts).
    ///
    /// Feeding [update] a synthetic `down: false` does $(I not) do this: the
    /// release branch cannot tell a real lift from a fake one, so it resolves
    /// the gesture — firing a tap, or letting a fling tail keep running.
    void cancel() @safe pure nothrow @nogc
    {
        wasDown_ = false;
        dragging_ = false;
        longFired_ = false;
        holdMs_ = 0;
        velocity_ = 0;
    }
}

@("gui_touch.cancelResolvesNothing")
@safe pure nothrow @nogc
unittest
{
    // A press that a second finger interrupts must not become a tap — the
    // bug a synthetic pointer-up caused, since `update` cannot distinguish it
    // from a real release.
    TouchScroller t;
    t.update(true, 100, 100, 16);
    t.cancel();
    auto f = t.update(false, 100, 100, 16);
    assert(!f.tap && !f.longPress && !f.dragging);
    assert(f.scrollPx == 0);

    // …and a fling in flight is stopped dead rather than coasting on through
    // whatever took the pointer.
    TouchScroller g;
    g.update(true, 10, 400, 16);
    foreach (i; 0 .. 4)
        g.update(true, 10, 400 - 30 * (i + 1), 16);
    g.update(false, 10, 280, 16);
    assert(g.update(false, 10, 280, 16).scrollPx > 0); // coasting
    g.cancel();
    assert(g.update(false, 10, 280, 16).scrollPx == 0);
}

@("gui_touch.tapUnderSlop")
@safe pure nothrow @nogc
unittest
{
    TouchScroller t;
    auto f = t.update(true, 100, 100, 16);
    assert(!f.tap && !f.dragging && !f.longPress);
    f = t.update(true, 104, 103, 16); // within slop
    assert(!f.dragging && f.scrollPx == 0);
    f = t.update(false, 104, 103, 16); // release fast
    assert(f.tap && !f.longPress);
    assert(f.x == 100 && f.y == 100); // anchor = press position
    // No fling after a tap.
    f = t.update(false, 104, 103, 16);
    assert(f.scrollPx == 0);
}

@("gui_touch.dragScrollsAndFlings")
@safe pure nothrow @nogc
unittest
{
    TouchScroller t;
    t.update(true, 100, 400, 16);
    // Sweep up fast (finger -30 px/frame → content toward later lines).
    float total = 0;
    foreach (i; 0 .. 5)
    {
        const f = t.update(true, 100, 400 - 30 * (i + 1), 16);
        total += f.scrollPx;
        // Every frame drags, the first included: `dragging_` is set AND
        // consumed in the same iteration, so no frame is spent crossing the
        // slop threshold.
        assert(f.dragging);
    }
    assert(total == 150); // exactly 5 × 30 px of forward scroll

    // Release at speed → fling continues in the same direction, decaying.
    auto f = t.update(false, 100, 250, 16);
    assert(!f.dragging && !f.tap);
    f = t.update(false, 100, 250, 16);
    assert(f.scrollPx > 0);
    float prev = f.scrollPx;
    foreach (i; 0 .. 200)
    {
        f = t.update(false, 100, 250, 16);
        assert(f.scrollPx >= 0 && f.scrollPx <= prev + 1e-3);
        prev = f.scrollPx;
    }
    assert(f.scrollPx == 0); // decayed to a full stop
}

@("gui_touch.pressStopsARunningFling")
@safe pure nothrow @nogc
unittest
{
    // Touching the screen while content is coasting must stop it dead — the
    // `velocity_ = 0` in the press branch. Otherwise the fling fights the new
    // gesture.
    TouchScroller t;
    t.update(true, 10, 400, 16);
    foreach (i; 0 .. 4)
        t.update(true, 10, 400 - 30 * (i + 1), 16);
    t.update(false, 10, 280, 16);
    assert(t.update(false, 10, 280, 16).scrollPx > 0); // coasting

    t.update(true, 10, 280, 16); // finger back down
    // The press frame itself scrolls nothing, and no tail survives it.
    assert(t.update(true, 10, 280, 16).scrollPx == 0);
}

@("gui_touch.longPressFiresOnceNoTapNoDrag")
@safe pure nothrow @nogc
unittest
{
    TouchScroller t;
    t.update(true, 50, 60, 16);
    bool fired;
    foreach (i; 0 .. 60) // ~1 s held still
    {
        const f = t.update(true, 52, 61, 16);
        assert(!f.tap && !f.dragging);
        if (f.longPress)
        {
            assert(!fired); // exactly once
            fired = true;
        }
    }
    assert(fired);
    // Movement after the long-press does NOT become a scroll drag (the
    // selection machinery owns the pointer now)…
    const move = t.update(true, 52, 200, 16);
    assert(!move.dragging && move.scrollPx == 0);
    // …and release is neither a tap nor a fling.
    const up = t.update(false, 52, 200, 16);
    assert(!up.tap);
    assert(t.update(false, 52, 200, 16).scrollPx == 0);
}

@("gui_touch.slowDragNoFling")
@safe pure nothrow @nogc
unittest
{
    TouchScroller t;
    t.update(true, 10, 100, 16);
    t.update(true, 10, 120, 16); // past slop → dragging
    t.update(true, 10, 120.5, 16); // nearly stopped
    t.update(false, 10, 120.5, 16);
    // Slow release → no momentum.
    assert(t.update(false, 10, 120.5, 16).scrollPx == 0);
}
