/**
The board's camera (`CAM1`–`CAM5`): the one mapping between an infinite world
and the viewport the host gave us.

$(B Magnification is an exponent and a mantissa), for the same reason a float
is. The exponent is $(LREF Camera.zoom): a power of two, in $(B cells) — one
world cell occupies `2^level` cells above 0, `2^-level` world cells share one
cell below it. The mantissa is $(LREF Camera.scalePercent): how large a cell is
$(B drawn), in `[100, 200)`% of the target's natural cell.

The split is what lets one camera serve both targets honestly. A terminal cell
cannot be subdivided, so the terminal pins the mantissa at 100 and zooms by
octaves — which is all a cell grid can express. A window can draw a cell at any
pixel size, so it moves the mantissa in small steps and only carries into the
exponent when the mantissa leaves its octave. The user sees a continuous zoom
in the window and a stepped one in the terminal, and both are looking at the
same world through the same camera.

$(B The cell mapping does not depend on the mantissa) — that is the point.
`worldToScreen` answers cells, in integer arithmetic with a documented rounding
direction, so a hit test and a paint agree exactly on either target. The
mantissa reaches the screen only where sub-cell resolution exists at all: the
pixel size the board's canvas is built at, and the pixel positions the pointer
arrives in (`HST18`).

$(B Everything is pure.) The camera is the piece most likely to be wrong in a
way no screenshot would catch — an off-by-one in a round-trip, a pivot that
drifts a cell per zoom step, a cull rect one row short — so it holds no state
but its own two fields, and the whole surface is tested at runtime without a
window, a terminal, or a frame.

$(B Tested at runtime, deliberately.) `Point`/`Size` are union-backed
(`Vector` overlays named fields on an array), so a named-field read is not
available in CTFE — `static assert` over this math would not compile, and the
suite below runs rather than evaluates (`CAM5`).
*/
module camera;

import sparkles.ui.geometry : Point, Rect, Size;

/// The zoom range, in octaves. Eight steps out and four in is what a board
/// with room for a few thousand nodes needs: far enough to lose a node in a
/// cell, close enough to label one.
enum int minZoom = -8;
/// ditto
enum int maxZoom = 4;

/// The mantissa's octave, in percent. `[100, 200)` — at 200 it is another
/// exponent step, which is what `normalize` carries.
enum int scaleBase = 100;
/// ditto
enum int scaleTop = 200;

/**
Where the viewport looks, and how far in.

`origin` is the $(B world) cell at the viewport's top-left, in world units.
Unbounded in both directions, because an infinite canvas has no edge to clamp
to — a board that stopped scrolling would be a document, not a canvas.
*/
struct Camera
{
    Point origin;   /// the world cell at the viewport's top-left
    int zoom;       /// the exponent: octaves of world cells per screen cell

    /**
    The mantissa: how large a cell is $(B drawn), in percent of the target's
    natural cell, kept in `[100, 200)`.

    A window moves this; a terminal leaves it at 100 because a cell there is
    indivisible and claiming otherwise would be a lie the renderer could not
    honour. Nothing in the cell mapping reads it — it reaches the screen as
    the pixel size the board's canvas is built at, and as the divisor turning
    a pixel pointer position back into a board cell.
    */
    int scalePercent = scaleBase;

@safe pure nothrow @nogc:

    /// How many screen cells one world cell covers (≥ 1), and how many world
    /// cells share one screen cell (≥ 1). Exactly one of them is > 1.
    int cellsPerWorld() const scope => zoom > 0 ? 1 << zoom : 1;
    /// ditto
    int worldPerCell() const scope => zoom < 0 ? 1 << -zoom : 1;

    /**
    World → screen.

    Zoomed out, several world cells collapse onto one screen cell, so this
    floors — and floors $(B toward negative infinity), not toward zero: C
    division truncates, which would fold the two cells either side of the
    origin onto the same screen cell and make the mapping discontinuous
    exactly where a user is most likely to be working.
    */
    Point worldToScreen(in Point world) const scope
        => Point(
            divFloor(world.x - origin.x, worldPerCell) * cellsPerWorld,
            divFloor(world.y - origin.y, worldPerCell) * cellsPerWorld);

    /**
    Screen → world.

    The inverse where one exists. Zoomed in it is exact; zoomed out a screen
    cell covers `worldPerCell²` world cells and this answers the top-left one
    of them, which is the cell a click means (the one the painter drew there).
    */
    Point screenToWorld(in Point screen) const scope
        => Point(
            origin.x + divFloor(screen.x, cellsPerWorld) * worldPerCell,
            origin.y + divFloor(screen.y, cellsPerWorld) * worldPerCell);

    /**
    Zoom by `delta` steps, keeping the world cell under `pivot` where it is.

    The property a wheel-zoom lives or dies by: the content under the pointer
    must not move. Read the world cell first, move the level, then place the
    origin so that cell lands back on the same screen cell. Clamped, and a
    clamped step is a no-op rather than a partial move — panning slightly on a
    zoom that did not happen is worse than doing nothing.
    */
    void zoomAt(int delta, in Point pivot) scope
    {
        const want = zoom + delta;
        const next = want < minZoom ? minZoom : (want > maxZoom ? maxZoom : want);
        if (next == zoom)
            return;

        const anchor = screenToWorld(pivot);
        zoom = next;
        // Where `anchor` would land now, relative to the origin — subtract it
        // back out so the anchor sits under the pivot again.
        const after = worldToScreen(anchor);
        const dx = divFloor(pivot.x - after.x, cellsPerWorld) * worldPerCell;
        const dy = divFloor(pivot.y - after.y, cellsPerWorld) * worldPerCell;
        origin = Point(origin.x - dx, origin.y - dy);
    }

    /**
    Zoom by a $(B ratio) — `ratioPercent` of the current magnification —
    keeping the world cell under `pivot` where it is. The window's wheel and
    pinch (`IXN4`): `110` is a notch in, `91` a notch out.

    A ratio and not an increment, because zoom is perceived multiplicatively:
    a fixed number of percentage points would be a large step near 100% and an
    imperceptible one near 200%, so the same wheel notch would feel different
    depending on where the mantissa happened to be. A pinch gives a ratio
    directly.

    The mantissa moves first and carries into the exponent when it leaves its
    octave, so a run of notches is smooth rather than a staircase: only the
    carry changes the cell mapping, and between carries the board is simply
    drawn at a different pixel size. `pivot` is in $(B cells), the unit the
    exponent works in — the refinement between two carries moves nothing in
    cell space and so needs no anchor.

    Returns `true` when the exponent carried, which is when the caller
    re-derives anything measured in cells.
    */
    bool zoomByRatio(int ratioPercent, in Point pivot) scope
    {
        if (ratioPercent <= 0)
            return false;
        int next = cast(int)(cast(long) scalePercent * ratioPercent / scaleBase);
        if (next < 1)
            next = 1; // a ratio past the floor clamps rather than wrapping

        // Renormalize into `[100, 200)`, counting octaves. 200% of one octave
        // IS 100% of the next, which is the whole identity this rests on.
        int carry;
        while (next >= scaleTop)
        {
            next /= 2;
            ++carry;
        }
        while (next < scaleBase)
        {
            next *= 2;
            --carry;
        }

        // A carry the exponent cannot take pins the mantissa at the edge of
        // the range rather than wrapping into a zoom that did not happen.
        if (carry != 0)
        {
            const before = zoom;
            zoomAt(carry, pivot);
            if (zoom == before)
            {
                scalePercent = carry > 0 ? scaleTop - 1 : scaleBase;
                return false;
            }
        }
        scalePercent = next;
        return carry != 0;
    }

    /// The board's cell size in pixels at this magnification, from the
    /// target's natural one. A terminal passes 1 and gets 1 back.
    int cellPixels(int naturalPx) const scope
        => naturalPx <= 1 ? 1
            : (naturalPx * scalePercent + scaleBase / 2) / scaleBase;

    /**
    A pointer position in $(B pixels) → the board cell it names.

    The window's hit-test entry (`HST18` reports pixels there precisely so a
    board can do this). `originPx` is where the board's canvas starts, so the
    chrome above and left of it is subtracted before the divide.
    */
    Point pixelToCell(in Point pixel, in Point originPx, int cellPxW,
        int cellPxH) const scope
        => Point(
            divFloor(pixel.x - originPx.x, cellPxW > 0 ? cellPxW : 1),
            divFloor(pixel.y - originPx.y, cellPxH > 0 ? cellPxH : 1));

    /// Pan by a screen-cell delta, converted to world units. Unbounded.
    void panBy(int screenDx, int screenDy) scope
    {
        origin = Point(
            origin.x - screenDx * worldPerCell / cellsPerWorld,
            origin.y - screenDy * worldPerCell / cellsPerWorld);
    }

    /**
    The world rectangle a `viewport`-sized surface shows — what culling tests
    against.

    Rounded $(B outward): a node straddling the right edge is partly visible
    and must be drawn, so the rect covers the last partly-shown world cell
    rather than the last fully-shown one.
    */
    Rect visibleWorldRect(in Size viewport) const scope
    {
        const w = ceilDiv(viewport.width, cellsPerWorld) * worldPerCell;
        const h = ceilDiv(viewport.height, cellsPerWorld) * worldPerCell;
        return Rect(origin.x, origin.y, w, h);
    }
}

/**
The tightest world rectangle containing every rect in `bounds`.

What fit-all and the minimap's content fit measure. Empty in, empty out — a
board with nothing on it has no content bounds, and callers branch on that
rather than being handed a rectangle at the origin that means "nothing".
*/
Rect contentBounds(scope const Rect[] bounds) @safe pure nothrow @nogc
{
    int x0 = int.max, y0 = int.max, x1 = int.min, y1 = int.min;
    bool any;
    foreach (ref b; bounds)
    {
        if (b.empty)
            continue;
        any = true;
        if (b.x < x0) x0 = b.x;
        if (b.y < y0) y0 = b.y;
        if (b.right > x1) x1 = b.right;
        if (b.bottom > y1) y1 = b.bottom;
    }
    return any ? Rect(x0, y0, x1 - x0, y1 - y0) : Rect(0, 0, 0, 0);
}

/**
The minimap's fit of `content` into `panel` (`CAM4`).

One integer divisor for both axes, so the overview is never stretched — a
minimap that distorted the board would misreport where things are, which is
its only job. Returns how many world cells share one panel cell (≥ 1).
*/
int minimapDivisor(in Rect content, in Size panel) @safe pure nothrow @nogc
{
    if (content.empty || panel.width <= 0 || panel.height <= 0)
        return 1;
    const dx = ceilDiv(content.width, panel.width);
    const dy = ceilDiv(content.height, panel.height);
    const d = dx > dy ? dx : dy;
    return d < 1 ? 1 : d;
}

/// A world point in the minimap panel's local cells, under `divisor`.
Point worldToMinimap(in Point world, in Rect content, int divisor)
    @safe pure nothrow @nogc
    => Point(
        divFloor(world.x - content.x, divisor),
        divFloor(world.y - content.y, divisor));

/// …and back: the world cell a panel cell stands for — what a minimap scrub
/// converts a click into.
Point minimapToWorld(in Point panel, in Rect content, int divisor)
    @safe pure nothrow @nogc
    => Point(content.x + panel.x * divisor, content.y + panel.y * divisor);

/**
The camera's frustum drawn in panel space — the "you are here" box.

At least one cell in each dimension: a viewport that shrinks below the divisor
would otherwise render as nothing, and an invisible frustum is worse than an
imprecise one.
*/
Rect minimapFrustum(in Camera cam, in Size viewport, in Rect content,
    int divisor) @safe pure nothrow @nogc
{
    const world = cam.visibleWorldRect(viewport);
    const tl = worldToMinimap(world.origin, content, divisor);
    const w = ceilDiv(world.width, divisor);
    const h = ceilDiv(world.height, divisor);
    return Rect(tl.x, tl.y, w < 1 ? 1 : w, h < 1 ? 1 : h);
}

// ── integer helpers, with the rounding written down ─────────────────────────

/// Division that floors toward negative infinity (C's truncates toward zero).
/// The whole camera depends on this: truncation makes `-1 / 2` and `0 / 2`
/// both zero, folding two world cells onto one screen cell across the origin.
int divFloor(int a, int b) @safe pure nothrow @nogc
{
    const q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

/// Division rounding away from zero — what "cover the partial cell too" means.
int ceilDiv(int a, int b) @safe pure nothrow @nogc
    => a <= 0 ? 0 : (a + b - 1) / b;

// ---------------------------------------------------------------------------
// Tests (`CAM5`): runtime, not CTFE — the union-backed vectors have no
// compile-time field reads.
// ---------------------------------------------------------------------------

@("diagram.camera.divFloorRoundsTowardNegativeInfinity")
@safe pure nothrow @nogc
unittest
{
    // The property C division does not have, and the reason this exists.
    assert(divFloor(4, 2) == 2);
    assert(divFloor(5, 2) == 2);
    assert(divFloor(-1, 2) == -1, "truncation would answer 0");
    assert(divFloor(-2, 2) == -1);
    assert(divFloor(-3, 2) == -2);
    assert(divFloor(0, 2) == 0);
}

@("diagram.camera.roundTripsWithinACellAtEveryZoom")
@safe pure nothrow @nogc
unittest
{
    // `CAM2`: screen→world→screen must land on the same screen cell at every
    // level. Zoomed out several world cells share a screen cell, so the world
    // round-trip is only exact zoomed in — the SCREEN round-trip is the one
    // that has to hold, because that is what a click does.
    foreach (level; minZoom .. maxZoom + 1)
    {
        auto cam = Camera(Point(-13, 7), level);
        foreach (sx; -4 .. 5)
            foreach (sy; -4 .. 5)
            {
                const screen = Point(sx * 3, sy * 3);
                const back = cam.worldToScreen(cam.screenToWorld(screen));
                // Within one screen cell of the input, and exactly on it
                // wherever a screen cell maps to a single world cell.
                const dx = back.x - screen.x;
                const dy = back.y - screen.y;
                assert(dx <= 0 && dx > -cam.cellsPerWorld - 1);
                assert(dy <= 0 && dy > -cam.cellsPerWorld - 1);
            }
    }
}

@("diagram.camera.worldRoundTripIsExactWhenACellIsNotShared")
@safe pure nothrow @nogc
unittest
{
    // Zoomed in (or at 1:1) the mapping is a bijection on world cells.
    foreach (level; 0 .. maxZoom + 1)
    {
        auto cam = Camera(Point(5, -9), level);
        foreach (wx; -6 .. 7)
            foreach (wy; -6 .. 7)
            {
                const w = Point(wx, wy);
                assert(cam.screenToWorld(cam.worldToScreen(w)) == w);
            }
    }
}

@("diagram.camera.zoomKeepsThePivotCellStationary")
@safe pure nothrow @nogc
unittest
{
    // `CAM2`, and the property a wheel zoom lives or dies by: whatever is
    // under the pointer stays under the pointer. Checked over a run of steps,
    // because a per-step drift of one cell is exactly the bug that hides in a
    // single-step test.
    const pivot = Point(37, 11);
    auto cam = Camera(Point(4, -2), 0);

    foreach (_; 0 .. 6)
    {
        const before = cam.screenToWorld(pivot);
        cam.zoomAt(1, pivot);
        assert(cam.screenToWorld(pivot) == before, "zoom in moved the pivot");
    }
    foreach (_; 0 .. 12)
    {
        const before = cam.screenToWorld(pivot);
        cam.zoomAt(-1, pivot);
        // Zoomed out a screen cell covers a block of world cells; the pivot's
        // cell must stay inside the block it was in, which at the top-left
        // rounding this uses means it is the block's own corner.
        const now = cam.screenToWorld(pivot);
        assert(now.x <= before.x && now.y <= before.y);
        assert(before.x - now.x < cam.worldPerCell);
        assert(before.y - now.y < cam.worldPerCell);
    }
}

@("diagram.camera.fineZoomCarriesIntoTheOctave")
@safe pure nothrow @nogc
unittest
{
    // The window's zoom: notches that stay smooth, carrying into the exponent
    // only when the mantissa leaves its octave. A 10% notch takes about seven
    // to double, so eight of them cross exactly one — and the magnification
    // must climb monotonically through the carry, never jump back.
    auto cam = Camera(Point(0, 0), 0, scaleBase);
    int carries;
    long previous = magnification(cam);

    foreach (_; 0 .. 8)
    {
        if (cam.zoomByRatio(110, Point(20, 10)))
            ++carries;
        const now = magnification(cam);
        assert(now > previous, "a zoom step never goes backwards");
        assert(cam.scalePercent >= scaleBase && cam.scalePercent < scaleTop,
            "the mantissa stays inside its octave");
        previous = now;
    }
    assert(carries == 1, "eight notches of 10% cross exactly one octave");
    assert(cam.zoom == 1);

    // …and back down through the same boundary, monotonically.
    const top = magnification(cam);
    foreach (_; 0 .. 8)
    {
        const was = magnification(cam);
        cam.zoomByRatio(91, Point(20, 10));
        assert(magnification(cam) < was, "and never forwards on the way out");
        assert(cam.scalePercent >= scaleBase && cam.scalePercent < scaleTop);
    }
    assert(magnification(cam) < top);

    // It lands NEAR where it started, not exactly on it: the mantissa is an
    // integer percentage, so every notch truncates a little and a there-and-
    // back drifts down. That is why `IXN4` gives the keyboard a `0` — a reset
    // is the only thing that restores an exact magnification, and pretending
    // otherwise would mean carrying a rational and rounding at every read.
    const drift = magnification(cam);
    assert(drift > 800 && drift < 1200, "within ~20% of the 1000 it began at");
}

@("diagram.camera.fineZoomLeavesTheCellMappingAlone")
@safe pure nothrow @nogc
unittest
{
    // The property the split exists for: between carries, zooming changes how
    // large a cell is DRAWN and nothing else. A hit test and a paint therefore
    // agree on either target, and the terminal — which pins the mantissa —
    // loses no correctness by not having one.
    auto cam = Camera(Point(7, -3), 0, scaleBase);
    const before = cam.worldToScreen(Point(11, 5));

    assert(!cam.zoomByRatio(140, Point(0, 0)), "×1.4 does not leave the octave");
    assert(cam.scalePercent == 140);
    assert(cam.worldToScreen(Point(11, 5)) == before, "cells did not move");
    assert(cam.zoom == 0 && cam.origin == Point(7, -3));

    // Only the pixel size moved — a 10 px cell is drawn at 14.
    assert(cam.cellPixels(10) == 14);
    // …and a terminal cell is still one cell.
    assert(cam.cellPixels(1) == 1);
}

@("diagram.camera.pixelPointerLandsOnTheCellItPointsAt")
@safe pure nothrow @nogc
unittest
{
    // `HST18` gives the window pixel positions precisely so this is possible:
    // divide by the board's DRAWN cell size, not the font's, or every hit test
    // drifts as soon as the user zooms.
    auto cam = Camera(Point(0, 0), 0, 150);
    const originPx = Point(200, 40); // the board canvas starts after chrome
    const w = cam.cellPixels(10);    // 15
    const h = cam.cellPixels(20);    // 30
    assert(w == 15 && h == 30);

    assert(cam.pixelToCell(Point(200, 40), originPx, w, h) == Point(0, 0));
    assert(cam.pixelToCell(Point(214, 69), originPx, w, h) == Point(0, 0),
        "anywhere inside the cell is that cell");
    assert(cam.pixelToCell(Point(215, 70), originPx, w, h) == Point(1, 1));

    // Left of and above the board is negative, not zero — a drag that leaves
    // the canvas must keep reporting where it went.
    assert(cam.pixelToCell(Point(199, 39), originPx, w, h) == Point(-1, -1));
}

@("diagram.camera.terminalKeepsTheOctavesAndLosesNothing")
@safe pure nothrow @nogc
unittest
{
    // The terminal's zoom is the exponent alone: a cell there is indivisible,
    // so a mantissa would be a claim the renderer could not honour. Everything
    // the cell mapping does is identical to the window's at the same exponent.
    auto tui = Camera(Point(4, 4), 0, scaleBase);
    auto gui = Camera(Point(4, 4), 0, 175);
    tui.zoomAt(2, Point(9, 3));
    gui.zoomAt(2, Point(9, 3));

    assert(tui.zoom == gui.zoom && tui.origin == gui.origin);
    foreach (i; -5 .. 6)
    {
        const p = Point(i * 4, i * 3);
        assert(tui.worldToScreen(p) == gui.worldToScreen(p));
        assert(tui.screenToWorld(p) == gui.screenToWorld(p));
    }
    assert(tui.visibleWorldRect(Size(80, 24))
        == gui.visibleWorldRect(Size(80, 24)));
}

@("diagram.camera.fineZoomClampsAtTheEnds")
@safe pure nothrow @nogc
unittest
{
    // A carry the exponent cannot take pins the mantissa at the edge rather
    // than wrapping into an octave that does not exist.
    auto cam = Camera(Point(0, 0), maxZoom, scaleTop - 1);
    assert(!cam.zoomByRatio(150, Point(0, 0)));
    assert(cam.zoom == maxZoom && cam.scalePercent == scaleTop - 1);

    cam = Camera(Point(0, 0), minZoom, scaleBase);
    assert(!cam.zoomByRatio(50, Point(0, 0)));
    assert(cam.zoom == minZoom && cam.scalePercent == scaleBase);

    // A ratio far past the floor lands on the floor rather than wrapping —
    // a pinch can deliver one in a single gesture.
    cam = Camera(Point(0, 0), 0, scaleBase);
    cam.zoomByRatio(1, Point(0, 0));
    assert(cam.zoom >= minZoom && cam.zoom < 0);
    assert(cam.scalePercent >= scaleBase && cam.scalePercent < scaleTop);
    assert(!cam.zoomByRatio(0, Point(0, 0)), "a zero ratio is not a zoom");
}

/// Total magnification in permille, for the monotonicity assertions above:
/// `2^zoom` scaled by the mantissa.
version (unittest)
private long magnification(in Camera c) @safe pure nothrow @nogc
{
    const octave = c.zoom >= 0 ? 1000L << c.zoom : 1000L >> -c.zoom;
    return octave * c.scalePercent / scaleBase;
}

@("diagram.camera.zoomClampsWithoutPanning")
@safe pure nothrow @nogc
unittest
{
    // A clamped step is a no-op, not a partial one: panning on a zoom that did
    // not happen is worse than doing nothing.
    auto cam = Camera(Point(3, 3), maxZoom);
    const before = cam;
    cam.zoomAt(1, Point(10, 10));
    assert(cam.zoom == before.zoom && cam.origin == before.origin);

    cam = Camera(Point(3, 3), minZoom);
    const floor = cam;
    cam.zoomAt(-1, Point(10, 10));
    assert(cam.zoom == floor.zoom && cam.origin == floor.origin);
}

@("diagram.camera.panIsUnbounded")
@safe pure nothrow @nogc
unittest
{
    // `CAM2`: an infinite canvas has no edge, so there is nothing to clamp to
    // and a long drag in one direction keeps going.
    auto cam = Camera(Point.init, 0);
    foreach (_; 0 .. 1000)
        cam.panBy(-50, -50);
    assert(cam.origin.x == 50_000 && cam.origin.y == 50_000);

    foreach (_; 0 .. 2000)
        cam.panBy(50, 50);
    assert(cam.origin.x == -50_000 && cam.origin.y == -50_000);
}

@("diagram.camera.visibleRectCoversPartialCells")
@safe pure nothrow @nogc
unittest
{
    // `CAM3`: culling must not drop a node straddling the edge, so the rect
    // rounds outward.
    auto cam = Camera(Point(10, 20), 0);
    const r = cam.visibleWorldRect(Size(80, 24));
    assert(r == Rect(10, 20, 80, 24));

    // Zoomed out 2×: 80 screen cells show 160 world cells.
    cam.zoom = -1;
    assert(cam.visibleWorldRect(Size(80, 24)) == Rect(10, 20, 160, 48));

    // Zoomed in 2×: 80 screen cells show 40 world cells — and an odd viewport
    // still covers the half-shown column.
    cam.zoom = 1;
    assert(cam.visibleWorldRect(Size(80, 24)) == Rect(10, 20, 40, 12));
    assert(cam.visibleWorldRect(Size(81, 24)) == Rect(10, 20, 41, 12));
}

@("diagram.camera.contentBoundsIgnoresEmptyAndReportsNothing")
@safe pure nothrow @nogc
unittest
{
    // `CAM3`. An empty board has no bounds — callers branch on that rather
    // than fitting to a rectangle at the origin that means "nothing".
    assert(contentBounds(null).empty);

    const Rect[3] some = [
        Rect(10, 10, 5, 5),
        Rect(0, 0, 0, 0),   // a freed slot: not content
        Rect(-3, 40, 2, 2),
    ];
    assert(contentBounds(some[]) == Rect(-3, 10, 18, 32));
}

@("diagram.camera.minimapFitsWithoutDistorting")
@safe pure nothrow @nogc
unittest
{
    // `CAM4`: one divisor for both axes. A minimap that stretched the board
    // would misreport where things are, which is its only job.
    const content = Rect(0, 0, 400, 100);
    const panel = Size(40, 20);
    const d = minimapDivisor(content, panel);
    assert(d == 10, "the wider axis chooses the divisor");

    // The far corner still lands inside the panel.
    const corner = worldToMinimap(Point(399, 99), content, d);
    assert(corner.x < panel.width && corner.y < panel.height);

    // A scrub round-trips to the top-left world cell of the block it named.
    foreach (px; 0 .. panel.width)
    {
        const w = minimapToWorld(Point(px, 0), content, d);
        assert(worldToMinimap(w, content, d).x == px);
    }

    // Content smaller than the panel is never magnified.
    assert(minimapDivisor(Rect(0, 0, 4, 4), panel) == 1);
    // Nothing to fit: a usable answer rather than a division by zero.
    assert(minimapDivisor(Rect(0, 0, 0, 0), panel) == 1);
    assert(minimapDivisor(content, Size(0, 0)) == 1);
}

@("diagram.camera.frustumIsNeverInvisible")
@safe pure nothrow @nogc
unittest
{
    // `CAM4`: zoomed far out over a large board the frustum can round to
    // nothing, and an invisible "you are here" box is worse than an imprecise
    // one.
    const content = Rect(0, 0, 100_000, 100_000);
    const panel = Size(20, 10);
    const d = minimapDivisor(content, panel);

    auto cam = Camera(Point(0, 0), maxZoom);
    const f = minimapFrustum(cam, Size(80, 24), content, d);
    assert(f.width >= 1 && f.height >= 1);

    // And it tracks the camera: panning right moves the box right.
    cam.origin = Point(50_000, 0);
    const moved = minimapFrustum(cam, Size(80, 24), content, d);
    assert(moved.x > f.x);
}
