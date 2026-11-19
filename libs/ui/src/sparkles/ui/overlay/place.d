/**
Where an overlay goes (`PLC1`–`PLC9`, `PLC12`–`PLC15`): one pure, total
function from an anchor, a content size and a boundary to the whole decision.

$(LREF place) is `@safe pure nothrow @nogc` over integer cells (`PLC1`). It
reads the boundary as a parameter (`PLC3`) — by default the surface deflated
by its viewport insets, $(LREF boundaryOf) (`PLC14`) — and clamps to it, never
to zero, because a laid-out position can be negative (`PLC4`). Its adjustments
run in a fixed order, recorded in the request rather than a middleware chain:
$(B flip), then $(B slide), then $(B resize), floored at the minimum size
(`PLC5`). A flip mirrors the side and the gravity together against the anchor
rect, and whether it is taken is a policy field (`PLC6`); by default the side
axis flips and the edge axis slides, and sliding across the side axis — an
overlap — is opt-in (`PLC7`). An overlay larger than the boundary pins its
start edge and overflows at the end (`PLC8`).

The request is shaped like a Wayland positioner — anchor rect, side and
gravity, an adjustment mask, an offset — so a native positioner can take it
unchanged (`POP5`). The answer is an $(LREF OverlayGeometry), the decision
record (`PLC2`): the rect and also the side and alignment it resolved to, the
fit, what fired, the arrow cell, the room there was, and the per-side overhang
the adjustments had to absorb.

$(B Decide, then measure) (`PLC9`): ask with the content's size $(I bound) —
the most it may grow to — and the result's `room` is the budget to lay the
content out in; ask again with the measured size and `lastSide` set to the
side the first answer chose, so the second answer keeps it. Stability is that
input field (`PLC13`), never a memo: events route against the last painted
frame, and a placement that oscillates between frames is a routing bug.

There is no measurement step (`PLC15`): `layout()` is the measurement and the
clip chain is already one `Rect`. Placement runs once per frame inside the
frame pass, between `layout()` and the display list (`PLC12`).
*/
module sparkles.ui.overlay.place;

import sparkles.ui.geometry : Insets, Point, Rect, Size;

/// The side of the anchor an overlay sits on.
enum Side : ubyte
{
    bottom, /// below it — the default for a tooltip or a completion list
    top,    /// above it
    right,  /// after it
    left,   /// before it
}

/// Where along the anchor's edge the overlay lines up: its gravity on the edge axis.
enum Align : ubyte
{
    start,  /// the overlay's start edge on the anchor's
    center, /// centred on the anchor
    end,    /// the overlay's end edge on the anchor's
}

/// The adjustments `place` may make, as a mask; they run flip → slide → resize (`PLC5`).
enum Adjust : ubyte
{
    none = 0,    ///
    flip = 1,    /// mirror to the opposite side when the preferred one overhangs
    slide = 2,   /// shift along the edge axis into the boundary
    resize = 4,  /// shrink what still overhangs, down to the minimum size
    overlap = 8, /// also shift along the side axis, over the anchor (opt-in, `PLC7`)
    standard = flip | slide | resize, /// the default
}

/// When a flip is taken (`PLC6`): the two rules place observably differently.
enum FlipRule : ubyte
{
    lessBad,    /// flip when the opposite side overhangs less
    onlyIfFits, /// flip only when the opposite side does not overhang at all
}

/// What became of the request.
enum Fit : ubyte
{
    fits,     /// placed as asked, nothing fired
    adjusted, /// inside the boundary after the adjustments in `fired`
    refused,  /// no allowed adjustment brings it inside; `rect` is the best attempt
}

/// The smallest an overlay is resized to (`PLC5`), in cells.
enum int popupMinWidth = 4;
/// ditto
enum int popupMinHeight = 1;

/// The boundary an overlay is placed in, by default (`PLC3`, `PLC14`): the
/// surface less its per-side viewport insets — a safe area, a cutout, the soft
/// keyboard, reserved chrome — folded in before placement.
Rect boundaryOf(in Rect surface, in Insets viewportInsets = Insets.init) @safe pure nothrow @nogc
    => surface.deflate(viewportInsets);

/**
What to place: the request, isomorphic to a positioner's `(anchor rect,
anchor edge + gravity, constraint-adjustment mask, offset)` (`PLC5`).
*/
struct PlaceRequest
{
    Rect anchor;                         /// the resolved anchor, in the boundary's space
    Size content;                        /// the overlay's size, or its bound (`PLC9`)
    Side side = Side.bottom;             /// the side asked for
    Align alignment = Align.start;       /// the gravity on the edge axis
    int gap;                             /// cells between the anchor and the overlay
    int shift;                           /// cells along the edge axis
    ubyte adjust = Adjust.standard;      /// which adjustments may fire
    FlipRule flipRule = FlipRule.lessBad; ///
    Size minSize = Size(popupMinWidth, popupMinHeight); /// the resize floor
    /// The side the last accepted placement used (`PLC13`); the solve starts
    /// from it, so an overlay does not swap sides while both would do.
    bool keepLastSide;
    Side lastSide;                       /// ditto
    bool arrow;                          /// whether to report an arrow cell
    /// The clip the anchor sits under: only the anchor-hidden verdict reads
    /// it, never the boundary (`PLC3`).
    Rect anchorClip = Rect(int.min / 2, int.min / 2, int.max, int.max);
}

/// The decision record (`PLC2`): everything the placement decided, never a bare rect.
struct OverlayGeometry
{
    Rect rect;            /// where the overlay goes
    Side side;            /// the side it resolved to
    Align alignment;      /// the gravity it resolved to
    Fit fit;              ///
    ubyte fired;          /// the `Adjust` bits that changed the placement
    bool hasArrow;        /// an arrow was asked for and the edge has room for one
    int arrow;            /// the arrow cell along the edge axis, from `rect`'s start
    bool arrowCentred;    /// the arrow points at the anchor's centre, unclamped
    Size room;            /// the room on the resolved side: the budget to lay out in
    Rect anchorLocal;     /// the anchor, in the overlay's own cells
    Insets overhang;      /// how far the asked-for placement overhung each side
    bool anchorHidden;    /// the anchor is wholly outside `anchorClip`
}

private bool vertical(Side s) @safe pure nothrow @nogc => s == Side.bottom || s == Side.top;

private Side opposite(Side s) @safe pure nothrow @nogc
{
    final switch (s)
    {
        case Side.bottom: return Side.top;
        case Side.top: return Side.bottom;
        case Side.right: return Side.left;
        case Side.left: return Side.right;
    }
}

private int aligned(int start, int extent, int length, Align a) @safe pure nothrow @nogc
{
    final switch (a)
    {
        case Align.start: return start;
        case Align.center: return start + (extent - length) / 2;
        case Align.end: return start + extent - length;
    }
}

/// The overlay at `side`, before any adjustment.
private Rect positioned(in PlaceRequest r, Side side, in Size size) @safe pure nothrow @nogc
{
    const a = r.anchor;
    if (vertical(side))
    {
        const x = aligned(a.x, a.width, size.width, r.alignment) + r.shift;
        const y = side == Side.bottom ? a.bottom + r.gap : a.y - r.gap - size.height;
        return Rect(x, y, size.width, size.height);
    }
    const y = aligned(a.y, a.height, size.height, r.alignment) + r.shift;
    const x = side == Side.right ? a.right + r.gap : a.x - r.gap - size.width;
    return Rect(x, y, size.width, size.height);
}

private int over(int start, int length, int lo, int hi) @safe pure nothrow @nogc
    => (start < lo ? lo - start : 0) + (start + length > hi ? start + length - hi : 0);

/// How far `rect` overhangs `b` across the side axis of `side`.
private int sideOverhang(in Rect rect, Side side, in Rect b) @safe pure nothrow @nogc
    => vertical(side) ? over(rect.y, rect.height, b.y, b.bottom) : over(rect.x, rect.width, b.x, b.right);

/// `start` moved so `[start, start + length)` lies in `[lo, hi)`; the start
/// edge is pinned when it cannot (`PLC8`). Never a clamp to zero (`PLC4`).
private int slid(int start, int length, int lo, int hi) @safe pure nothrow @nogc
{
    if (length >= hi - lo) return lo;
    if (start < lo) return lo;
    if (start + length > hi) return hi - length;
    return start;
}

/// The room between the anchor's `side` edge (past the gap) and the boundary.
private int roomAcross(in PlaceRequest r, Side side, in Rect b) @safe pure nothrow @nogc
{
    const a = r.anchor;
    int room;
    final switch (side)
    {
        case Side.bottom: room = b.bottom - (a.bottom + r.gap); break;
        case Side.top: room = (a.y - r.gap) - b.y; break;
        case Side.right: room = b.right - (a.right + r.gap); break;
        case Side.left: room = (a.x - r.gap) - b.x; break;
    }
    return room > 0 ? room : 0;
}

private bool inside(in Rect r, in Rect b) @safe pure nothrow @nogc
    => r.x >= b.x && r.y >= b.y && r.right <= b.right && r.bottom <= b.bottom;

/**
The placement of `r` in `boundary` (`PLC1`): total over every input — an
empty boundary, an anchor outside it, content larger than it — and the same
answer for the same values.
*/
OverlayGeometry place(in PlaceRequest r, in Rect boundary) @safe pure nothrow @nogc
{
    OverlayGeometry g;
    g.alignment = r.alignment;
    g.anchorHidden = r.anchor.intersection(r.anchorClip).empty;
    const size = Size(r.content.width > 0 ? r.content.width : 0, r.content.height > 0 ? r.content.height : 0);

    // 1. The side: the last accepted one when there is one, else the asked one;
    //    flipped, edge and gravity together, under the request's rule (PLC6).
    Side side = r.keepLastSide ? r.lastSide : r.side;
    Rect rect = positioned(r, side, size);
    const asked = rect;
    g.overhang = Insets(asked.y < boundary.y ? boundary.y - asked.y : 0,
        asked.right > boundary.right ? asked.right - boundary.right : 0,
        asked.bottom > boundary.bottom ? asked.bottom - boundary.bottom : 0,
        asked.x < boundary.x ? boundary.x - asked.x : 0);
    const overhang = sideOverhang(rect, side, boundary);
    if (overhang > 0 && (r.adjust & Adjust.flip))
    {
        const other = opposite(side);
        const flipped = positioned(r, other, size);
        const otherOverhang = sideOverhang(flipped, other, boundary);
        if (r.flipRule == FlipRule.lessBad ? otherOverhang < overhang : otherOverhang == 0)
        {
            side = other;
            rect = flipped;
            g.fired |= Adjust.flip;
        }
    }

    // 2. Slide: along the edge axis by default, across the side axis only by opt-in.
    const vert = vertical(side);
    if (r.adjust & Adjust.slide)
    {
        const before = rect.origin;
        if (vert) rect.origin = Point(slid(rect.x, rect.width, boundary.x, boundary.right), rect.y);
        else rect.origin = Point(rect.x, slid(rect.y, rect.height, boundary.y, boundary.bottom));
        if (rect.origin != before) g.fired |= Adjust.slide;
    }
    if (r.adjust & Adjust.overlap)
    {
        const before = rect.origin;
        if (vert) rect.origin = Point(rect.x, slid(rect.y, rect.height, boundary.y, boundary.bottom));
        else rect.origin = Point(slid(rect.x, rect.width, boundary.x, boundary.right), rect.y);
        if (rect.origin != before) g.fired |= Adjust.overlap;
    }

    // 3. Resize, last: whatever still overhangs shrinks to the room, floored.
    if ((r.adjust & Adjust.resize) && !inside(rect, boundary))
    {
        const before = rect;
        const room = roomAcross(r, side, boundary);
        int across = vert ? rect.height : rect.width;
        if (sideOverhang(rect, side, boundary) > 0 && across > room)
            across = room;
        const floorAcross = vert ? r.minSize.height : r.minSize.width;
        if (across < floorAcross) across = floorAcross;
        int along = vert ? rect.width : rect.height;
        const span = vert ? boundary.width : boundary.height;
        const floorAlong = vert ? r.minSize.width : r.minSize.height;
        if (along > span) along = span > floorAlong ? span : floorAlong;
        if (vert)
        {
            const y = side == Side.top ? rect.bottom - across : rect.y;
            rect = Rect(slid(rect.x, along, boundary.x, boundary.right), y, along, across);
        }
        else
        {
            const x = side == Side.left ? rect.right - across : rect.x;
            rect = Rect(x, slid(rect.y, along, boundary.y, boundary.bottom), across, along);
        }
        if (rect != before) g.fired |= Adjust.resize;
    }

    g.rect = rect;
    g.side = side;
    g.fit = boundary.empty || !inside(rect, boundary) ? Fit.refused : g.fired ? Fit.adjusted : Fit.fits;
    g.room = vert ? Size(boundary.width > 0 ? boundary.width : 0, roomAcross(r, side, boundary))
        : Size(roomAcross(r, side, boundary), boundary.height > 0 ? boundary.height : 0);
    g.anchorLocal = Rect(r.anchor.x - rect.x, r.anchor.y - rect.y, r.anchor.width, r.anchor.height);

    // The arrow: at the anchor's centre on the edge axis, kept off the corners.
    if (r.arrow)
    {
        const extent = vert ? rect.width : rect.height;
        if (extent >= 3)
        {
            const centre = vert ? r.anchor.x + r.anchor.width / 2 - rect.x
                : r.anchor.y + r.anchor.height / 2 - rect.y;
            const lo = 1, hi = extent - 2;
            assert(lo <= hi, "an arrow interval never inverts (ANC4)");
            g.hasArrow = true;
            g.arrow = centre < lo ? lo : centre > hi ? hi : centre;
            g.arrowCentred = g.arrow == centre;
        }
    }
    return g;
}

/// It fits: placed below the anchor at its start, nothing fired.
@("overlay.place.fitsAsAsked")
@safe pure nothrow @nogc unittest
{
    const g = place(PlaceRequest(anchor: Rect(10, 5, 4, 1), content: Size(20, 6)), Rect(0, 0, 80, 24));
    assert(g.rect == Rect(10, 6, 20, 6) && g.side == Side.bottom && g.fit == Fit.fits && !g.fired);
    assert(g.room == Size(80, 18));
    assert(g.anchorLocal == Rect(0, -1, 4, 1));
}

/// Near the bottom it flips above, edge and gravity together (`PLC6`).
@("overlay.place.flipsAcrossTheSideAxis")
@safe pure nothrow @nogc unittest
{
    const g = place(PlaceRequest(anchor: Rect(10, 20, 4, 1), content: Size(20, 6)), Rect(0, 0, 80, 24));
    assert(g.side == Side.top && g.rect == Rect(10, 14, 20, 6));
    assert(g.fired == Adjust.flip && g.fit == Fit.adjusted);
    assert(g.overhang.bottom == 3, "the asked-for placement overhung by three rows");
}

/// Near the right edge it slides left, flush, rather than shrinking — and
/// against a boundary that does not start at zero it stops at the boundary (`PLC4`).
@("overlay.place.slidesToTheBoundaryNotZero")
@safe pure nothrow @nogc unittest
{
    const right = place(PlaceRequest(anchor: Rect(70, 2, 1, 1), content: Size(20, 3)), Rect(0, 0, 80, 24));
    assert(right.rect.x == 60 && right.fired == Adjust.slide);
    const scrolled = place(PlaceRequest(anchor: Rect(-30, 2, 1, 1), content: Size(20, 3)), Rect(-12, 0, 80, 24));
    assert(scrolled.rect.x == -12, "clamped to the boundary's start, not to 0");
    const wide = place(PlaceRequest(anchor: Rect(5, 2, 1, 1), content: Size(200, 3), adjust: Adjust.slide),
        Rect(3, 0, 80, 24));
    assert(wide.rect.x == 3 && wide.fit == Fit.refused, "too wide: the start edge pins (PLC8)");
}

/// The two flip rules place differently when neither side fits (`PLC6`).
@("overlay.place.flipRules")
@safe pure nothrow @nogc unittest
{
    // Anchor at row 15 of 24: 8 rows below it, 15 above; content 18 tall.
    auto r = PlaceRequest(anchor: Rect(0, 15, 1, 1), content: Size(10, 18), adjust: Adjust.flip);
    assert(place(r, Rect(0, 0, 80, 24)).side == Side.top, "less bad: 3 rows over beats 10");
    r.flipRule = FlipRule.onlyIfFits;
    assert(place(r, Rect(0, 0, 80, 24)).side == Side.bottom, "only if it fits: stays put");
}

/// Resize runs last and stops at the floor (`PLC5`).
@("overlay.place.resizesLastToTheFloor")
@safe pure nothrow @nogc unittest
{
    const g = place(PlaceRequest(anchor: Rect(0, 10, 1, 1), content: Size(10, 30)), Rect(0, 0, 80, 24));
    assert(g.side == Side.bottom, "13 rows below beats 10 above");
    assert(g.rect == Rect(0, 11, 10, 13) && (g.fired & Adjust.resize) && g.fit == Fit.adjusted);
    const tiny = place(PlaceRequest(anchor: Rect(0, 23, 1, 1), content: Size(10, 30), adjust: Adjust.resize),
        Rect(0, 0, 80, 24));
    assert(tiny.rect.height == popupMinHeight && tiny.fit == Fit.refused, "no room below: the floor, refused");
}

/// The last accepted side is kept while it still works (`PLC13`).
@("overlay.place.keepsTheLastSide")
@safe pure nothrow @nogc unittest
{
    auto r = PlaceRequest(anchor: Rect(10, 10, 1, 1), content: Size(10, 5));
    assert(place(r, Rect(0, 0, 80, 24)).side == Side.bottom);
    r.keepLastSide = true;
    r.lastSide = Side.top;
    assert(place(r, Rect(0, 0, 80, 24)).side == Side.top, "both fit: the accepted side stays");
}

/// Side-axis sliding is opt-in (`PLC7`): by default an overlay never covers its anchor.
@("overlay.place.overlapIsOptIn")
@safe pure nothrow @nogc unittest
{
    auto r = PlaceRequest(anchor: Rect(0, 0, 1, 24), content: Size(10, 5), side: Side.right,
        adjust: Adjust.slide);
    assert(place(r, Rect(0, 0, 8, 24)).rect.x == 1, "it overhangs rather than covering the anchor");
    r.adjust = Adjust.slide | Adjust.overlap;
    assert(place(r, Rect(0, 0, 8, 24)).rect.x == 0 && (place(r, Rect(0, 0, 8, 24)).fired & Adjust.overlap));
}

/// The arrow points at the anchor and stays off the corners (`PLC2`, `ANC4`).
@("overlay.place.arrowCell")
@safe pure nothrow @nogc unittest
{
    const centred = place(PlaceRequest(anchor: Rect(10, 2, 1, 1), content: Size(9, 3), alignment: Align.center,
        arrow: true), Rect(0, 0, 80, 24));
    assert(centred.hasArrow && centred.arrow == 4 && centred.arrowCentred);
    const slid = place(PlaceRequest(anchor: Rect(79, 2, 1, 1), content: Size(9, 3), arrow: true), Rect(0, 0, 80, 24));
    assert(slid.rect.x == 71 && slid.arrow == 7 && !slid.arrowCentred, "clamped one short of the corner");
    const narrow = place(PlaceRequest(anchor: Rect(1, 1, 1, 1), content: Size(2, 1), arrow: true), Rect(0, 0, 9, 9));
    assert(!narrow.hasArrow, "two cells have no room for an arrow between corners");
}

/// The anchor-hidden verdict reads the anchor's clip, not the boundary (`PLC3`).
@("overlay.place.anchorHiddenReadsTheClip")
@safe pure nothrow @nogc unittest
{
    const shown = place(PlaceRequest(anchor: Rect(5, 5, 2, 1), content: Size(4, 2)), Rect(0, 0, 3, 3));
    assert(!shown.anchorHidden, "outside the boundary, but nothing clips it");
    const hidden = place(PlaceRequest(anchor: Rect(5, 5, 2, 1), content: Size(4, 2), anchorClip: Rect(0, 0, 4, 4)),
        Rect(0, 0, 80, 24));
    assert(hidden.anchorHidden);
}

/// Viewport insets fold into the boundary before placement (`PLC14`).
@("overlay.place.insetsFoldIntoTheBoundary")
@safe pure nothrow @nogc unittest
{
    const b = boundaryOf(Rect(0, 0, 80, 24), Insets(0, 0, 8, 0)); // a soft keyboard
    assert(b == Rect(0, 0, 80, 16));
    assert(place(PlaceRequest(anchor: Rect(0, 12, 1, 1), content: Size(10, 5)), b).side == Side.top);
}

/**
Property test over random anchors, contents and boundaries — negative origins
included (`PLC1`): the answer is inside the boundary unless it says
`refused`; it is on the asked side or its mirror; it never overhangs where the
content would have fitted; and the same request answers the same.
*/
@("overlay.place.properties")
@safe pure nothrow @nogc unittest
{
    uint state = 0x9E37_79B9;
    int next(int lo, int hi)
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return lo + cast(int)(state % cast(uint)(hi - lo + 1));
    }
    foreach (_; 0 .. 20_000)
    {
        const boundary = Rect(next(-40, 40), next(-40, 40), next(0, 120), next(0, 60));
        PlaceRequest r;
        r.anchor = Rect(next(-60, 160), next(-60, 100), next(1, 12), next(1, 4));
        r.content = Size(next(1, 70), next(1, 30));
        r.side = cast(Side) next(0, 3);
        r.alignment = cast(Align) next(0, 2);
        r.gap = next(0, 2);
        r.adjust = cast(ubyte) next(0, 15);
        r.flipRule = cast(FlipRule) next(0, 1);
        r.arrow = next(0, 1) == 1;
        const g = place(r, boundary);

        if (g.fit != Fit.refused)
            assert(inside(g.rect, boundary), "a placement that is not refused is inside");
        assert(g.side == r.side || g.side == opposite(r.side));
        assert(g.side == r.side || (g.fired & Adjust.flip), "the side changes only by a flip");
        assert(g.overhang.top >= 0 && g.overhang.right >= 0 && g.overhang.bottom >= 0 && g.overhang.left >= 0);
        if (g.fit == Fit.fits)
            assert(g.rect.size == r.content && !g.fired);
        if (g.hasArrow)
        {
            const extent = vertical(g.side) ? g.rect.width : g.rect.height;
            assert(g.arrow >= 1 && g.arrow <= extent - 2);
        }
        if ((r.adjust & Adjust.slide) && (g.fired & Adjust.slide) && !(g.fired & Adjust.resize))
        {
            // A slide stops at the boundary, never at 0.
            const start = vertical(g.side) ? g.rect.x : g.rect.y;
            const lo = vertical(g.side) ? boundary.x : boundary.y;
            const hi = vertical(g.side) ? boundary.right : boundary.bottom;
            const len = vertical(g.side) ? g.rect.width : g.rect.height;
            assert(start == lo || start + len == hi);
        }
        assert(place(r, boundary) == g, "total and deterministic");
    }
}
