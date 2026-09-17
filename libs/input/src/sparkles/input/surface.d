/**
What a pointer event means when it lands where the surface is not (`PTR3`).

A drawn surface does not always fill the window it lives in. A warped one is the
clearest case — hue's CRT tube rounds its corners, leaving 1.2% of the window
with no UI beneath it at the default curvature and 7.7% at the maximum — but the
shape is general: any target whose image is inset, letterboxed, rotated or
projected has window pixels that address nothing. Where the window system draws
the pointer, those pixels are reachable, so $(B what a click there means) is a
question someone has to answer.

This module is that answer, and only that answer. Translating a window position
into a surface position belongs to whatever owns the projection; delivering the
result belongs to the frame loop. Neither is here. What is here is the policy in
between, isolated so it can be stated in tests rather than discovered in an app.

The rule has two halves, and the second half is the one that is easy to miss:

$(UL
$(LI $(B Uncaptured) — a move becomes `leave`, so hover clears rather than
    sticking to whatever was last hot; a press is swallowed.)
$(LI $(B Captured) — while the UI believes a button is down, every event is
    clamped onto the surface and delivered. A scrollbar drag that strays off
    the surface must keep dragging, and a release out there must still arrive,
    or the button stays down forever and the grab never ends.)
)
*/
module sparkles.input.surface;

import sparkles.input.events : Event, Point, PointerAction, PointerButton;

/// What the host does with one event whose position left the surface.
enum PointerRoute : ubyte
{
    /// Hand it on at $(LREF PointerDecision.pos).
    deliver,
    /// Rewrite it as `PointerAction.leave`: nothing can be hot.
    leave,
    /// Swallow it.
    drop,
}

/// ditto
struct PointerDecision
{
    PointerRoute route;
    Point pos;
}

/// Pins a point inside `[0, w) × [0, h)`.
Point clampToSurface(in Point p, int w, int h) @safe pure nothrow @nogc
{
    static int pin(int v, int hi) => v < 0 ? 0 : (v >= hi ? hi - 1 : v);
    return Point(pin(p.x, w > 0 ? w : 1), pin(p.y, h > 0 ? h : 1));
}

/// Whether a translated point has any UI under it.
bool onSurface(in Point p, int w, int h) @safe pure nothrow @nogc
    => p.x >= 0 && p.x < w && p.y >= 0 && p.y < h;

/**
The held-button level $(B as the UI sees it), which is not the same as the level
the window system reports: an event this policy swallows never happened as far
as the UI is concerned, so a press dropped off the surface must not start a capture.
Only delivered events move this.
*/
struct PointerCapture
{
    private uint held;

    /// Whether the UI currently believes a button is down.
    bool captured() const @safe pure nothrow @nogc => held != 0;

    /// Records an event that $(B was) delivered.
    void noteDelivered(PointerAction a, PointerButton b) @safe pure nothrow @nogc
    {
        if (b == PointerButton.none)
            return;
        const bit = 1u << cast(uint) b;
        if (a == PointerAction.press)
            held |= bit;
        else if (a == PointerAction.release)
            held &= ~bit;
    }

    /// Forgets every button — for a focus loss, where releases never arrive.
    void reset() @safe pure nothrow @nogc { held = 0; }

    /**
    Where a pointer event translated to `mapped` should go.

    `release` is delivered clamped whatever the capture state says. A release is
    the only way a button level comes back down, so dropping one strands the
    UI holding a button nobody is pressing.
    */
    PointerDecision route(PointerAction a, in Point mapped, int w, int h)
        const @safe pure nothrow @nogc
    {
        if (onSurface(mapped, w, h))
            return PointerDecision(PointerRoute.deliver, mapped);
        if (captured || a == PointerAction.release)
            return PointerDecision(PointerRoute.deliver, clampToSurface(mapped, w, h));
        if (a == PointerAction.move || a == PointerAction.drag || a == PointerAction.leave)
            return PointerDecision(PointerRoute.leave, clampToSurface(mapped, w, h));
        return PointerDecision(PointerRoute.drop, mapped);
    }

    /**
    ditto, for a wheel or gesture event — which has no button of its own and so
    no `leave` spelling. Off the surface and uncaptured, it is simply swallowed.
    */
    PointerDecision routeWheel(in Point mapped, int w, int h)
        const @safe pure nothrow @nogc
    {
        if (onSurface(mapped, w, h))
            return PointerDecision(PointerRoute.deliver, mapped);
        if (captured)
            return PointerDecision(PointerRoute.deliver, clampToSurface(mapped, w, h));
        return PointerDecision(PointerRoute.drop, mapped);
    }
}

@("input.surface.clampToSurface.pinsInsideTheHalfOpenRect")
@safe pure nothrow @nogc
unittest
{
    assert(clampToSurface(Point(-5, -5), 100, 50) == Point(0, 0));
    assert(clampToSurface(Point(500, 500), 100, 50) == Point(99, 49));
    assert(clampToSurface(Point(40, 20), 100, 50) == Point(40, 20));
    // A degenerate surface still yields an addressable point.
    assert(clampToSurface(Point(7, 7), 0, 0) == Point(0, 0));

    assert(onSurface(Point(0, 0), 100, 50));
    assert(!onSurface(Point(100, 20), 100, 50));
    assert(!onSurface(Point(20, -1), 100, 50));
}

@("input.surface.route.onSurfaceIsAlwaysDelivered")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;
    const d = c.route(PointerAction.move, Point(10, 10), 100, 50);
    assert(d.route == PointerRoute.deliver);
    assert(d.pos == Point(10, 10));
}

@("input.surface.route.uncapturedOffSurfaceClearsHoverAndSwallowsClicks")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;
    assert(!c.captured);

    // A move off the surface must not leave the last row hot.
    assert(c.route(PointerAction.move, Point(-3, 10), 100, 50).route == PointerRoute.leave);
    // A click out there does nothing at all...
    assert(c.route(PointerAction.press, Point(-3, 10), 100, 50).route == PointerRoute.drop);
    // ...and therefore must not start a capture.
    const dropped = c.route(PointerAction.press, Point(-3, 10), 100, 50);
    if (dropped.route == PointerRoute.deliver)
        c.noteDelivered(PointerAction.press, PointerButton.left);
    assert(!c.captured);
}

@("input.surface.route.aDragSurvivesLeavingTheSurface")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;

    // Press on the surface: the UI saw it, so the capture is real.
    const press = c.route(PointerAction.press, Point(90, 20), 100, 50);
    assert(press.route == PointerRoute.deliver);
    c.noteDelivered(PointerAction.press, PointerButton.left);
    assert(c.captured);

    // Now stray outside. The drag must keep arriving, pinned to the edge —
    // this is the scrollbar grab that used to die at the surface edge.
    const strayed = c.route(PointerAction.drag, Point(140, 20), 100, 50);
    assert(strayed.route == PointerRoute.deliver);
    assert(strayed.pos == Point(99, 20));

    // And the release must land, or the button never comes up.
    const rel = c.route(PointerAction.release, Point(140, 80), 100, 50);
    assert(rel.route == PointerRoute.deliver);
    assert(rel.pos == Point(99, 49));
    c.noteDelivered(PointerAction.release, PointerButton.left);
    assert(!c.captured);
}

@("input.surface.route.releaseIsNeverDroppedEvenUncaptured")
@safe pure nothrow @nogc
unittest
{
    // A release with no recorded press (focus was lost mid-drag, say) still
    // has to reach the UI so nothing is left holding a button.
    PointerCapture c;
    assert(c.route(PointerAction.release, Point(-9, -9), 100, 50).route
        == PointerRoute.deliver);
}

@("input.surface.capture.tracksEachButtonIndependently")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;
    c.noteDelivered(PointerAction.press, PointerButton.left);
    c.noteDelivered(PointerAction.press, PointerButton.right);
    assert(c.captured);
    c.noteDelivered(PointerAction.release, PointerButton.left);
    assert(c.captured, "the right button is still down");
    c.noteDelivered(PointerAction.release, PointerButton.right);
    assert(!c.captured);

    c.noteDelivered(PointerAction.press, PointerButton.middle);
    assert(c.captured);
    c.reset();
    assert(!c.captured);

    // A button-less event never moves the level.
    c.noteDelivered(PointerAction.press, PointerButton.none);
    assert(!c.captured);
}

@("input.surface.routeWheel.needsTheSurfaceOrACapture")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;
    assert(c.routeWheel(Point(10, 10), 100, 50).route == PointerRoute.deliver);
    assert(c.routeWheel(Point(-1, 10), 100, 50).route == PointerRoute.drop);

    c.noteDelivered(PointerAction.press, PointerButton.left);
    const held = c.routeWheel(Point(-1, 10), 100, 50);
    assert(held.route == PointerRoute.deliver);
    assert(held.pos == Point(0, 10));
}

/++
Translates one event onto the surface and rules on it, in one step.

The whole of $(LREF PointerCapture)'s policy applied to a real event: the
position is mapped by `toSurface`, the decision is taken, and the event is
rewritten — a `leave` also clearing the button, since nothing is pressed at a
position nothing occupies.

Returns `false` for an event the host must $(B drop); `admitted` is only
meaningful when it returns `true`.

Templated on the mapper so attributes infer and a caller whose projection is
`@nogc` keeps a `@nogc` intake — and so this is testable with an arithmetic
stand-in rather than a live projection.
+/
bool admitOntoSurface(Map)(ref PointerCapture capture, scope Map toSurface,
    in Event e, out Event admitted, int w, int h)
{
    import sparkles.input.events : FocusEvent, GestureEvent, match,
        PointerEvent, WheelEvent;

    admitted = e;
    bool keep = true;
    e.match!(
        (in PointerEvent p) {
            const d = capture.route(p.action, toSurface(p.pos), w, h);
            PointerEvent q = p;
            q.pos = d.pos;
            final switch (d.route)
            {
            case PointerRoute.deliver:
                capture.noteDelivered(q.action, q.button);
                break;
            case PointerRoute.leave:
                q.action = PointerAction.leave;
                q.button = PointerButton.none;
                break;
            case PointerRoute.drop:
                keep = false;
                break;
            }
            admitted = Event(q);
        },
        (in WheelEvent wv) {
            const d = capture.routeWheel(toSurface(wv.pos), w, h);
            WheelEvent q = wv;
            q.pos = d.pos;
            keep = d.route == PointerRoute.deliver;
            admitted = Event(q);
        },
        (in GestureEvent g) {
            const d = capture.routeWheel(toSurface(g.pos), w, h);
            GestureEvent q = g;
            q.pos = d.pos;
            keep = d.route == PointerRoute.deliver;
            admitted = Event(q);
        },
        (in FocusEvent f) {
            // A window that loses focus mid-drag never gets the release, so
            // the level would stay down forever.
            if (!f.focused)
                capture.reset();
        },
        (in _) {}
    );
    return keep;
}

@("input.surface.admitOntoSurface.mapsRewritesAndDrops")
@safe
unittest
{
    import sparkles.input.events : FocusEvent, match, PointerEvent, WheelEvent;

    // A projection that shifts everything left by 40 — enough to push the low
    // end off the surface, which is the whole point.
    static Point shift(in Point p) @safe pure nothrow @nogc
        => Point(p.x - 40, p.y);

    PointerCapture c;
    Event got;

    // On the surface after mapping: delivered at the MAPPED position.
    assert(admitOntoSurface(c, &shift, Event(PointerEvent(PointerAction.move,
        PointerButton.none, Point(60, 10))), got, 100, 50));
    got.match!((in PointerEvent p) { assert(p.pos == Point(20, 10)); }, (in _) { assert(false); });

    // Off it: rewritten to `leave`, with the button cleared.
    assert(admitOntoSurface(c, &shift, Event(PointerEvent(PointerAction.drag,
        PointerButton.left, Point(10, 10))), got, 100, 50));
    got.match!(
        (in PointerEvent p) {
            assert(p.action == PointerAction.leave);
            assert(p.button == PointerButton.none);
        },
        (in _) { assert(false); });

    // A press out there is dropped, and starts no capture.
    assert(!admitOntoSurface(c, &shift, Event(PointerEvent(PointerAction.press,
        PointerButton.left, Point(10, 10))), got, 100, 50));
    assert(!c.captured);

    // A press ON the surface does, and then a wheel off it still arrives.
    assert(admitOntoSurface(c, &shift, Event(PointerEvent(PointerAction.press,
        PointerButton.left, Point(60, 10))), got, 100, 50));
    assert(c.captured);
    assert(admitOntoSurface(c, &shift, Event(WheelEvent(0, 1, Point(10, 10))), got, 100, 50));

    // Losing focus forgets the button nobody will send a release for.
    assert(admitOntoSurface(c, &shift, Event(FocusEvent(false)), got, 100, 50));
    assert(!c.captured);
}
