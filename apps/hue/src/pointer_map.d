/**
Pointer input policy for a warped canvas (`PTR2`, `PTR3`).

With `appearance.pointer.mode = system` the window system draws the pointer, so
input arrives in $(B screen) space while the UI lives in texture space. The host
translates each event's position through
$(REF CrtEffect.mapPointerToUi, sparkles,ui_raylib,crt) — and then has to answer
what happens to the positions that translate to nothing, because a warped image
does not fill its window: the tube's rounded corners leave the window's own
corners with no UI point under them at all (1.2% of the window at the default
curvature, 7.7% at the maximum — the edges themselves are seated flush by
`CRT10`, so the dead area is corners only).

This module is that answer, and only that answer: the geometry is the canvas
backend's and the plumbing is the frame loop's, but $(B what a click in the
bezel means) is policy, so it lives somewhere it can be stated in a test.

The rule has two halves, and the second half is the one that is easy to miss:

$(UL
$(LI $(B Uncaptured) — a move becomes `leave`, so hover clears rather than
    sticking to whatever was last hot; a press is swallowed.)
$(LI $(B Captured) — while the UI believes a button is down, every event is
    clamped onto the surface and delivered. A scrollbar drag that strays into
    the bezel must keep dragging, and a release out there must still arrive, or
    the button stays down forever and the grab never ends.)
)
*/
module pointer_map;

import sparkles.input.events : Point, PointerAction, PointerButton;

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
as the UI is concerned, so a press dropped in the bezel must not start a capture.
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

@("pointer_map.clampToSurface.pinsInsideTheHalfOpenRect")
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

@("pointer_map.route.onSurfaceIsAlwaysDelivered")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;
    const d = c.route(PointerAction.move, Point(10, 10), 100, 50);
    assert(d.route == PointerRoute.deliver);
    assert(d.pos == Point(10, 10));
}

@("pointer_map.route.uncapturedOffSurfaceClearsHoverAndSwallowsClicks")
@safe pure nothrow @nogc
unittest
{
    PointerCapture c;
    assert(!c.captured);

    // A move into the bezel must not leave the last row hot.
    assert(c.route(PointerAction.move, Point(-3, 10), 100, 50).route == PointerRoute.leave);
    // A click out there does nothing at all...
    assert(c.route(PointerAction.press, Point(-3, 10), 100, 50).route == PointerRoute.drop);
    // ...and therefore must not start a capture.
    const dropped = c.route(PointerAction.press, Point(-3, 10), 100, 50);
    if (dropped.route == PointerRoute.deliver)
        c.noteDelivered(PointerAction.press, PointerButton.left);
    assert(!c.captured);
}

@("pointer_map.route.aDragSurvivesTheBezel")
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
    // this is the scrollbar grab that used to die at the window edge.
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

@("pointer_map.route.releaseIsNeverDroppedEvenUncaptured")
@safe pure nothrow @nogc
unittest
{
    // A release with no recorded press (focus was lost mid-drag, say) still
    // has to reach the UI so nothing is left holding a button.
    PointerCapture c;
    assert(c.route(PointerAction.release, Point(-9, -9), 100, 50).route
        == PointerRoute.deliver);
}

@("pointer_map.capture.tracksEachButtonIndependently")
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

@("pointer_map.routeWheel.needsTheSurfaceOrACapture")
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
