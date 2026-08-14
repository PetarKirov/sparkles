#!/usr/bin/env dub
/+ dub.sdl:
    name "anchored_overlays_place_reference"
    targetPath "build"
    dependency "sparkles:ui" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The reference placement pipeline — `place()` as the catalog concluded it must
 * be: **one `@safe pure nothrow @nogc` function over Regular values that returns
 * geometry _metadata_, not a point.**
 *
 * Returning only an offset is the mistake this survey identified in the field
 * and in this repo. [../compose.md](../compose.md) records the cost precisely:
 * because Compose's `PopupPositionProvider` returns an `IntOffset` and nothing
 * else, drawing a caret cost "a downcast, an extra frame and a duplicated clamp
 * that does not agree with the original". [../proposal.md](../proposal.md) § 3.2
 * makes the counter-requirement — the solver reports the resolved **side**, the
 * resolved **alignment** and the **arrow cell** alongside the rect, because a
 * cell backend picks the border cap and the arrow glyph from the side at paint
 * time, and the static-HTML emitter picks them at emit time with no later
 * measurement pass available at all.
 *
 * What this program demonstrates, one case per section, each rendered as cells:
 *
 *   1. the axis split — **flip on the main axis, slide on the cross axis,
 *      resize last** ([../proposal.md](../proposal.md) § 3.3, GTK4's
 *      `GdkAnchorHints` / `xdg_positioner`'s `constraint_adjustment`);
 *   2. the **start-edge pin**: when the content is larger than the boundary the
 *      start edge wins and the end overflows (Textual's `translate_inside`,
 *      react-aria's `getDelta`, GPUI's right-then-left clamp);
 *   3. the pin is against the **boundary**, never against the coordinate
 *      origin. That is the defect [../features-people-forget.md](../features-people-forget.md)
 *      § 11 found in *both* this repo's `clampOrigin`
 *      (`libs/twoslash/src/sparkles/twoslash/render_widgets.d:430`, which floors
 *      at `0`) and Avalonia's `ManagedPopupPositioner.cs:182` (which subtracts
 *      `X` from `bounds.Width` instead of from `bounds.Right`, so it is correct
 *      only when the work area starts at the origin). Case 9 asserts it, and
 *      prints what `clampOrigin` would have produced;
 *   4. the **arrow cell** as an overlay-local index that is clamped into the
 *      edge's interior and reports whether it reached the anchor's centre — the
 *      datum `BoxStyle.arrow`/`arrowOffset` already declares and nothing in
 *      `sparkles:ui` produces today;
 *   5. **RTL as a pre-solver resolution**, never a flag inside the solver
 *      (the Angular CDK bug in [../proposal.md](../proposal.md) § 2's dimension
 *      notes: CDK resolves `start`/`end` through `_isRtl()` in two places and
 *      forgets it in a third);
 *   6. `anchorHidden` as a **hide verdict, not a close**.
 *
 * Every case is checked by `checkInvariants` before it is printed, so the
 * program is a self-checking oracle rather than a printer: the placed rect is
 * inside the boundary whenever it fits, its origin is never below the
 * boundary's origin (the anti-clamp-to-zero invariant), the arrow cell is
 * strictly inside the attached edge, and **placement is idempotent** — feeding
 * the resolved side and alignment back in reproduces the same rect and reports
 * no further flip.
 *
 * Companion to [../proposal.md](../proposal.md) § 3.2–3.3 and
 * [../concepts.md](../concepts.md) § "Collision geometry".
 *
 * Run with: dub run --single place-reference.d
 *
 * Portability: pure integer geometry — no clock, no display, no terminal.
 * Deterministic everywhere. Build `checked`, never `release`: the invariants
 * below are `assert`s, and `-release` would delete them.
 *
 * Note: `Point`/`Size` are `Vector`-backed unions, so a named-field read is not
 * available in CTFE (`libs/ui/src/sparkles/ui/geometry.d:34-40`). Everything
 * here is therefore a *runtime* demonstration; nothing is a `static assert`.
 */
module anchored_overlays_place_reference;

import std.format : format;
import std.stdio : writefln, writeln;

import sparkles.ui.geometry : Point, Rect, Size;

// ---------------------------------------------------------------------------
// The vocabulary
// ---------------------------------------------------------------------------

/// Which edge of the **anchor** the overlay attaches to. `Side.bottom` means the
/// overlay hangs below the anchor and its own *top* edge faces it.
enum Side : ubyte
{
    top,    /// above the anchor
    bottom, /// below the anchor
    left,   /// left of the anchor
    right,  /// right of the anchor
}

/// Cross-axis alignment, in **physical** terms. `start` is the left/top edge; a
/// logical (writing-order) alignment is resolved to one of these before the
/// solver runs — see $(LREF physical).
enum Align : ubyte { start, center, end }

/// Reading direction. An *input to the resolution step*, never a flag consulted
/// inside the solver.
enum Direction : ubyte { ltr, rtl }

/// Which adjustments the caller permits — and, on the result, which ones
/// actually fired. Structurally GTK4's `GdkAnchorHints` / `xdg_positioner`'s
/// `constraint_adjustment`, so a future native-windowing backend can forward it.
enum Adjust : ubyte
{
    none = 0,
    flipMain = 1 << 0,    /// cross to the opposite side of the anchor
    slideMain = 1 << 1,   /// shift along the side axis (detaches; opt-in)
    flipCross = 1 << 2,   /// mirror the alignment (opt-in; Floating UI's rule)
    slideCross = 1 << 3,  /// shift along the edge axis
    resizeMain = 1 << 4,  /// shrink to the room at the resolved side
    resizeCross = 1 << 5, /// shrink to the boundary's cross extent (opt-in)
}

/// How good the resulting placement is, worst-wins.
enum Fit : ubyte
{
    exact,       /// placed as asked
    slid,        /// shifted along an axis to stay inside
    flipped,     /// crossed to the other side of the anchor
    shrunk,      /// the content was capped
    overflowing, /// it does not fit and we are the host — nobody clips for us
}

/// The genuine fork the survey found: GTK4 accepts a flip when it is *less bad*;
/// `xdg_positioner` reverts unless the flipped position is fully unconstrained.
enum FlipAcceptance : ubyte { revertUnlessFree, lessBadWins }

/// Bit tests spelled once, so the solver reads as prose.
bool has(Adjust a, Adjust f) @safe pure nothrow @nogc => (a & f) != 0;
/// ditto
Adjust plus(Adjust a, Adjust f) @safe pure nothrow @nogc => cast(Adjust)(a | f);

/// The opposite side, for a main-axis flip.
Side opposite(Side s) @safe pure nothrow @nogc
{
    final switch (s)
    {
        case Side.top: return Side.bottom;
        case Side.bottom: return Side.top;
        case Side.left: return Side.right;
        case Side.right: return Side.left;
    }
}

/// The mirrored alignment. `center` is its own mirror.
Align mirror(Align a) @safe pure nothrow @nogc
    => a == Align.start ? Align.end : (a == Align.end ? Align.start : Align.center);

/**
The placement **request**. Never written back to by the solver (`D15.C6`): what
the caller asked for stays readable next to what it got.
*/
struct PlacementPolicy
{
    Side side = Side.bottom;      /// the preferred anchor edge
    Align align_ = Align.center;  /// the preferred cross-axis alignment
    Direction direction = Direction.ltr; /// resolved away before the solve
    int sideOffset;               /// the gutter, in cells, applied BEFORE testing
    int alignOffset;              /// a nudge along the edge axis, in cells
    /// The default is the proposal's `popupCollision`: flip the side axis, slide
    /// the edge axis, cap the height. Side-axis slide and cross-axis flip are
    /// opt-in, because both detach the overlay from its anchor.
    Adjust adjust = cast(Adjust)(Adjust.flipMain | Adjust.slideCross | Adjust.resizeMain);
    FlipAcceptance acceptance = FlipAcceptance.revertUnlessFree;
    bool arrow = true;            /// reserve an arrow cell on the attached edge
}

/**
The resolved anchor. `rect` is what the solver places against; `clip` is the
anchor's clipping ancestor, which governs **only** the `anchorHidden` verdict —
the placement boundary is a separate parameter (`D3.C3`).
*/
struct Anchor
{
    Rect rect; /// the anchor's cell rect
    Rect clip; /// the clipping ancestor

@safe pure nothrow @nogc:

    /// An anchor with no clipping ancestor: it clips to itself, so it is always
    /// visible.
    static Anchor unclipped(in Rect r) => Anchor(r, r);

    /// An anchor inside a scrolling viewport, which may have scrolled out of it.
    static Anchor within(in Rect r, in Rect clip) => Anchor(r, clip);

    /// The part of the anchor its clip stack actually leaves on screen.
    Rect visible() const scope => rect.intersection(clip);

    /// The anchor left its clip entirely — a HIDE verdict, not a close.
    bool hidden() const scope => visible.empty;
}

/**
The placement **result**: geometry metadata, not a point. Every field here is
one a backend or an emitter would otherwise have to re-derive — which is exactly
what [../compose.md](../compose.md), [../avalonia.md](../avalonia.md) and hue's
three `clampOrigin` call sites each ended up doing, differently.
*/
struct PlacedOverlay
{
    Rect rect;          /// resolved, integer cells, already pinned
    Side side;          /// post-flip anchor edge we attached to
    Align align_;       /// post-flip, post-RTL cross alignment
    int arrowCell = -1; /// overlay-local index along the attached edge; -1 = none
    bool arrowCentred;  /// false ⇒ the arrow could not reach the anchor's centre
    bool flippedMain;   /// the side axis crossed to the other side of the anchor
    bool flippedCross;  /// the alignment was mirrored (RTL resolution, or flipCross)
    bool anchorHidden;  /// the anchor left its clip
    Size available;     /// room actually left at the resolved side
    Adjust applied;     /// which adjustments fired
    Fit fit;            /// the worst thing that happened
}

// ---------------------------------------------------------------------------
// The pipeline
// ---------------------------------------------------------------------------

/**
Step 0 — **logical → physical**, run *before* the solver and never inside it.

Under RTL, `start` is the right edge, the left/right sides swap, and the sign of
the edge-axis offset flips with them. Angular CDK resolves this inside its
solver and forgets it in one of three places; GTK4 negates the offset on the
flipped branch for the analogous reason and Avalonia's RTL mirror omits it.
Keeping it a separate pure step makes the omission unrepresentable.
*/
PlacementPolicy physical(in PlacementPolicy p) @safe pure nothrow @nogc
{
    if (p.direction == Direction.ltr)
        return p;

    PlacementPolicy r = p;
    r.direction = Direction.ltr;
    r.alignOffset = -p.alignOffset;
    if (p.side == Side.left)
        r.side = Side.right;
    else if (p.side == Side.right)
        r.side = Side.left;
    else
        r.align_ = mirror(p.align_);
    return r;
}

/**
Place `content` against `anchor` inside `boundary`, under `policy`.

Per-axis and total: the **main** (side) axis flips then optionally resizes; the
**cross** (edge) axis aligns, optionally mirrors, then slides — end edge first,
start edge last, so an overlay larger than the boundary pins its start and
overflows its end. The start pin is against `boundary`, **not** against `0`.
*/
PlacedOverlay place(in Anchor anchor, in Size content, in Rect boundary,
    in PlacementPolicy policy) @safe pure nothrow @nogc
in (content.width > 0 && content.height > 0, "an empty overlay is not a placement problem")
in (!boundary.empty, "the boundary must cover at least one cell")
out (r; r.rect.x >= boundary.x && r.rect.y >= boundary.y,
    "the start edge pins to the BOUNDARY, never to the coordinate origin")
{
    const req = physical(policy);
    const vertical = req.side == Side.top || req.side == Side.bottom;

    // --- main (side) axis --------------------------------------------------
    const int bLo = vertical ? boundary.y : boundary.x;
    const int bHi = vertical ? boundary.bottom : boundary.right;
    const int aLo = vertical ? anchor.rect.y : anchor.rect.x;
    const int aHi = vertical ? anchor.rect.bottom : anchor.rect.right;
    const int mainWant = vertical ? content.height : content.width;

    // The gutter is folded in BEFORE the constraint test, never after it
    // (xdg_positioner's rule; testing the un-offset rect re-introduces exactly
    // the overflow the flip just resolved).
    bool atEnd = req.side == Side.bottom || req.side == Side.right;
    int room = atEnd ? bHi - (aHi + req.sideOffset) : (aLo - req.sideOffset) - bLo;
    int other = atEnd ? (aLo - req.sideOffset) - bLo : bHi - (aHi + req.sideOffset);

    Adjust applied = Adjust.none;
    bool flippedMain;
    if (mainWant > room && req.adjust.has(Adjust.flipMain))
    {
        const accept = req.acceptance == FlipAcceptance.revertUnlessFree
            ? mainWant <= other      // xdg: revert unless the flip is FULLY free
            : other > room;          // gtk4: accept whenever it is less bad
        if (accept)
        {
            flippedMain = true;
            atEnd = !atEnd;
            const swap = room;
            room = other;
            other = swap;
            applied = applied.plus(Adjust.flipMain);
        }
    }

    int mainLen = mainWant;
    if (mainLen > room && req.adjust.has(Adjust.resizeMain))
    {
        mainLen = room > 1 ? room : 1;
        applied = applied.plus(Adjust.resizeMain);
    }

    int mainPos = atEnd ? aHi + req.sideOffset : aLo - req.sideOffset - mainLen;
    const int mainAsked = mainPos;
    if (req.adjust.has(Adjust.slideMain) && mainPos + mainLen > bHi)
        mainPos = bHi - mainLen;
    if (mainPos < bLo)
        mainPos = bLo;               // the START pin — to the boundary, not to 0
    if (mainPos != mainAsked)
        applied = applied.plus(Adjust.slideMain);

    // --- cross (edge) axis -------------------------------------------------
    const int cbLo = vertical ? boundary.x : boundary.y;
    const int cbHi = vertical ? boundary.right : boundary.bottom;
    const int caLo = vertical ? anchor.rect.x : anchor.rect.y;
    const int caHi = vertical ? anchor.rect.right : anchor.rect.bottom;
    const int crossWant = vertical ? content.width : content.height;

    int crossLen = crossWant;
    if (crossLen > cbHi - cbLo && req.adjust.has(Adjust.resizeCross))
    {
        crossLen = cbHi - cbLo;
        applied = applied.plus(Adjust.resizeCross);
    }

    int alignedAt(Align a) => a == Align.start
        ? caLo
        : (a == Align.end ? caHi - crossLen : caLo + ((caHi - caLo) - crossLen) / 2);

    Align align_ = req.align_;
    int crossPos = alignedAt(align_) + req.alignOffset;
    // RTL mirroring already happened in `physical`; report it as a cross flip.
    bool flippedCross = req.align_ != policy.align_;

    if (req.adjust.has(Adjust.flipCross) && (crossPos < cbLo || crossPos + crossLen > cbHi))
    {
        const m = mirror(align_);
        const mp = alignedAt(m) + req.alignOffset;
        if (mp >= cbLo && mp + crossLen <= cbHi)
        {
            align_ = m;
            crossPos = mp;
            flippedCross = !flippedCross;
            applied = applied.plus(Adjust.flipCross);
        }
    }

    const int crossAsked = crossPos;
    if (req.adjust.has(Adjust.slideCross) && crossPos + crossLen > cbHi)
        crossPos = cbHi - crossLen;  // end edge first …
    if (crossPos < cbLo)
        crossPos = cbLo;             // … START pin last, so the start edge wins
    if (crossPos != crossAsked)
        applied = applied.plus(Adjust.slideCross);

    const rect = vertical
        ? Rect(crossPos, mainPos, crossLen, mainLen)
        : Rect(mainPos, crossPos, mainLen, crossLen);

    // --- the arrow ---------------------------------------------------------
    // The attached edge always runs along the cross axis, so the arrow is one
    // integer: an overlay-local index into that edge, clamped strictly inside it
    // so it can never overwrite a corner glyph (the unclamped `arrowOffset`
    // defect, D4.C3). A 1x1 anchor can invert the interval if the edge is too
    // short to hold an arrow, so assert rather than trust the clamp (D1.C8).
    int arrowCell = -1;
    bool arrowCentred;
    if (policy.arrow && crossLen >= 3)
    {
        const int lo = 1, hi = crossLen - 2;
        assert(lo <= hi, "an arrow interval must never invert");
        const int want = caLo + (caHi - caLo) / 2 - crossPos;
        arrowCell = want < lo ? lo : (want > hi ? hi : want);
        arrowCentred = arrowCell == want;
    }

    const inside = boundary.intersection(rect) == rect;
    const fit = !inside
        ? Fit.overflowing
        : applied.has(Adjust.resizeMain) || applied.has(Adjust.resizeCross)
            ? Fit.shrunk
            : flippedMain || applied.has(Adjust.flipCross)
                ? Fit.flipped
                : applied.has(Adjust.slideCross) || applied.has(Adjust.slideMain)
                    ? Fit.slid
                    : Fit.exact;

    return PlacedOverlay(
        rect: rect,
        side: flippedMain ? opposite(req.side) : req.side,
        align_: align_,
        arrowCell: arrowCell,
        arrowCentred: arrowCentred,
        flippedMain: flippedMain,
        flippedCross: flippedCross,
        anchorHidden: anchor.hidden,
        available: vertical ? Size(cbHi - cbLo, room) : Size(room, cbHi - cbLo),
        applied: applied,
        fit: fit,
    );
}

/**
`clampOrigin` as `libs/twoslash/src/sparkles/twoslash/render_widgets.d:430` has
it today — one axis, one direction, against a **scalar** extent, floored at zero.
Reproduced verbatim so case 9 can print the divergence rather than describe it.
*/
int clampOriginToday(int anchor, int width, int extent) @safe pure nothrow @nogc
{
    const over = anchor + width - extent;
    const shifted = over > 0 ? anchor - over : anchor;
    return shifted < 0 ? 0 : shifted;
}

// ---------------------------------------------------------------------------
// The invariants — asserted for every case, so this is an oracle
// ---------------------------------------------------------------------------

void checkInvariants(in Anchor anchor, in Size content, in Rect boundary,
    in PlacementPolicy policy, in PlacedOverlay r) @safe
{
    // I1. The start edge pins to the BOUNDARY. This is the whole clamp-to-zero
    //     defect: it must hold for a boundary that starts anywhere, including
    //     at negative coordinates (content scrolled above/left of a viewport).
    assert(r.rect.x >= boundary.x && r.rect.y >= boundary.y,
        "placed rect escaped the boundary's start edge");

    // I2. Whenever it fits, it is fully inside.
    if (r.fit != Fit.overflowing)
        assert(boundary.intersection(r.rect) == r.rect,
            "a non-overflowing placement must be inside the boundary");

    // I3. The arrow is strictly inside the attached edge — never on a corner.
    const vertical = r.side == Side.top || r.side == Side.bottom;
    const edgeLen = vertical ? r.rect.width : r.rect.height;
    if (r.arrowCell >= 0)
    {
        assert(r.arrowCell >= 1 && r.arrowCell <= edgeLen - 2,
            "the arrow cell overwrote a corner of the overlay's edge");
        // …and when it reached the anchor, it really points at it.
        if (r.arrowCentred)
        {
            const base = vertical ? r.rect.x : r.rect.y;
            const aLo = vertical ? anchor.rect.x : anchor.rect.y;
            const aHi = vertical ? anchor.rect.right : anchor.rect.bottom;
            assert(base + r.arrowCell == aLo + (aHi - aLo) / 2,
                "a centred arrow must land on the anchor's centre cell");
        }
    }

    // I4. Flipping is idempotent: re-placing at the RESOLVED side and alignment
    //     (physical, so RTL is already resolved) reproduces the same geometry
    //     and reports no further flip. A solver that fails this oscillates.
    PlacementPolicy again = policy;
    again.side = r.side;
    again.align_ = r.align_;
    again.direction = Direction.ltr;
    again.alignOffset = policy.direction == Direction.rtl
        ? -policy.alignOffset : policy.alignOffset;
    const twice = place(anchor, content, boundary, again);
    assert(twice.rect == r.rect, "re-placement moved the overlay");
    assert(twice.arrowCell == r.arrowCell, "re-placement moved the arrow");
    assert(!twice.flippedMain && !twice.flippedCross, "re-placement flipped again");
}

// ---------------------------------------------------------------------------
// Rendering the result as cells
// ---------------------------------------------------------------------------

/// A character grid covering `world`, so a placement can be *seen*.
struct Grid
{
    enum int maxW = 96, maxH = 40;

    Rect world;
    char[maxW * maxH] cells = '.';

@safe pure nothrow @nogc:

    this(in Rect world)
    in (world.width > 0 && world.width <= maxW, "world too wide to draw")
    in (world.height > 0 && world.height <= maxH, "world too tall to draw")
    {
        this.world = world;
        cells[] = '.';
    }

    void set(int x, int y, char c) scope
    {
        if (world.contains(Point(x, y)))
            cells[(y - world.y) * maxW + (x - world.x)] = c;
    }

    void fill(in Rect r, char c) scope
    {
        foreach (y; r.y .. r.bottom)
            foreach (x; r.x .. r.right)
                set(x, y, c);
    }
}

/// The union of two rectangles (either may be empty).
Rect unite(in Rect a, in Rect b) @safe pure nothrow @nogc
{
    if (a.empty)
        return b;
    if (b.empty)
        return a;
    const x0 = a.x < b.x ? a.x : b.x;
    const y0 = a.y < b.y ? a.y : b.y;
    const x1 = a.right > b.right ? a.right : b.right;
    const y1 = a.bottom > b.bottom ? a.bottom : b.bottom;
    return Rect(x0, y0, x1 - x0, y1 - y0);
}

/// `r` grown by `n` cells on every side.
Rect inflate(in Rect r, int n) @safe pure nothrow @nogc
    => Rect(r.x - n, r.y - n, r.width + 2 * n, r.height + 2 * n);

/// The arrow glyph for the edge the overlay attached along.
char arrowGlyph(Side s) @safe pure nothrow @nogc
{
    final switch (s)
    {
        case Side.bottom: return '^'; // overlay below ⇒ arrow on its top edge
        case Side.top: return 'v';
        case Side.right: return '<';
        case Side.left: return '>';
    }
}

/// Paint the boundary frame, the anchor and the placed overlay into one grid.
Grid draw(in Anchor anchor, in Rect boundary, in PlacedOverlay r) @safe pure nothrow @nogc
{
    const world = unite(inflate(boundary, 1), unite(anchor.rect, r.rect));
    auto g = Grid(world);

    g.fill(boundary, ' ');
    // The frame sits one cell OUTSIDE the boundary, so it never collides with
    // a placed cell — everything drawn on it is genuinely out of bounds.
    const f = inflate(boundary, 1);
    foreach (x; f.x .. f.right)
    {
        g.set(x, f.y, '-');
        g.set(x, f.bottom - 1, '-');
    }
    foreach (y; f.y .. f.bottom)
    {
        g.set(f.x, y, '|');
        g.set(f.right - 1, y, '|');
    }
    g.set(f.x, f.y, '+');
    g.set(f.right - 1, f.y, '+');
    g.set(f.x, f.bottom - 1, '+');
    g.set(f.right - 1, f.bottom - 1, '+');

    g.fill(anchor.rect, 'A');
    g.fill(r.rect, '#');
    if (r.arrowCell >= 0)
    {
        const c = arrowGlyph(r.side);
        final switch (r.side)
        {
            case Side.bottom: g.set(r.rect.x + r.arrowCell, r.rect.y, c); break;
            case Side.top: g.set(r.rect.x + r.arrowCell, r.rect.bottom - 1, c); break;
            case Side.right: g.set(r.rect.x, r.rect.y + r.arrowCell, c); break;
            case Side.left: g.set(r.rect.right - 1, r.rect.y + r.arrowCell, c); break;
        }
    }
    return g;
}

void printGrid(in Grid g) @safe
{
    foreach (i; 0 .. g.world.height)
    {
        char[Grid.maxW] buf;
        const w = g.world.width;
        buf[0 .. w] = g.cells[i * Grid.maxW .. i * Grid.maxW + w];
        writeln("  ", buf[0 .. w].idup);
    }
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

string rectText(in Rect r) @safe => format!"(%d,%d %dx%d)"(r.x, r.y, r.width, r.height);

string adjustText(Adjust a) @safe
{
    if (a == Adjust.none)
        return "none";
    string s;
    static foreach (name; ["flipMain", "slideMain", "flipCross", "slideCross",
            "resizeMain", "resizeCross"])
        if (a.has(__traits(getMember, Adjust, name)))
            s ~= (s.length ? "|" : "") ~ name;
    return s;
}

/// One row of the case table.
struct Case
{
    string label;
    Anchor anchor;
    Size content;
    Rect boundary;
    PlacementPolicy policy;
    string note;
}

void report(int n, const Case c, in PlacedOverlay r) @safe
{
    writefln!"=== %d. %s ==="(n, c.label);
    printGrid(draw(c.anchor, c.boundary, r));
    writefln!"  ask       side=%s align=%s dir=%s offset=(%d,%d) adjust=%s"(
        c.policy.side, c.policy.align_, c.policy.direction,
        c.policy.sideOffset, c.policy.alignOffset, adjustText(c.policy.adjust));
    writefln!"  boundary  %s   anchor %s   content %dx%d"(
        rectText(c.boundary), rectText(c.anchor.rect), c.content.width, c.content.height);
    writefln!"  got       rect=%s side=%s align=%s fit=%s applied=%s"(
        rectText(r.rect), r.side, r.align_, r.fit, adjustText(r.applied));
    writefln!"  metadata  arrowCell=%d (centred %s) flippedMain=%s flippedCross=%s"(
        r.arrowCell, r.arrowCentred ? "yes" : "no", r.flippedMain, r.flippedCross);
    writefln!"            anchorHidden=%s available=%dx%d"(
        r.anchorHidden, r.available.width, r.available.height);
    if (c.note.length)
        writeln("  note      ", c.note);
    writeln();
}

// ---------------------------------------------------------------------------

void main() @safe
{
    writeln("place() — the reference placement pipeline, in cells");
    writeln("legend: '+-|' the boundary frame (drawn just outside it), 'A' anchor,");
    writeln("        '#' overlay, '^v<>' the arrow cell, '.' outside the boundary");
    writeln();

    // The default policy (`popupCollision`): flip the side axis, slide the edge
    // axis, cap the height. Everything else is opt-in, per case.
    PlacementPolicy pol;

    auto crossFlip = pol;
    crossFlip.align_ = Align.start;
    crossFlip.adjust = pol.adjust.plus(Adjust.flipCross);

    auto rtl = pol;
    rtl.align_ = Align.start;
    rtl.direction = Direction.rtl;

    auto cases = [
        Case("fits as preferred",
            Anchor.unclipped(Rect(11, 2, 4, 1)), Size(12, 3), Rect(0, 0, 26, 9), pol,
            "nothing fired: the arrow sits on the anchor's centre cell"),
        Case("flips on the main axis (no room below)",
            Anchor.unclipped(Rect(11, 6, 4, 1)), Size(12, 3), Rect(0, 0, 26, 9), pol,
            "2 cells below, 6 above: the side is REPORTED, so the backend "
                ~ "picks 'v' without re-deriving it"),
        Case("shifts on the cross axis (near the right edge)",
            Anchor.unclipped(Rect(22, 2, 3, 1)), Size(12, 3), Rect(0, 0, 26, 9), pol,
            "the rect slid 4 cells left; the arrow tracked the anchor and is "
                ~ "still centred"),
        Case("BOTH axes constrained",
            Anchor.unclipped(Rect(22, 6, 3, 1)), Size(12, 3), Rect(0, 0, 26, 9), pol,
            "flip on the main axis AND slide on the cross axis, in one solve"),
        Case("content wider than the boundary",
            Anchor.unclipped(Rect(7, 2, 4, 1)), Size(24, 3), Rect(0, 0, 18, 8), pol,
            "the START edge is pinned and the end overflows — never the reverse, "
                ~ "or the text the arrow points at scrolls off"),
        Case("content taller than the boundary",
            Anchor.unclipped(Rect(9, 4, 4, 1)), Size(10, 14), Rect(0, 0, 22, 9), pol,
            "neither side fits, so no flip is accepted (revertUnlessFree) and "
                ~ "the height is capped to the room actually there"),
        Case("clipped / offscreen anchor",
            Anchor.within(Rect(28, 3, 4, 1), Rect(0, 0, 26, 9)), Size(12, 3),
            Rect(0, 0, 26, 9), pol,
            "anchorHidden is a HIDE verdict, not a close; the arrow could not "
                ~ "reach the anchor, and says so"),
        Case("RTL alignment",
            Anchor.unclipped(Rect(10, 2, 6, 1)), Size(12, 3), Rect(0, 0, 26, 9), rtl,
            "align=start resolved to the RIGHT edge BEFORE the solver ran; the "
                ~ "solver itself is purely physical"),
        Case("boundary whose origin is NOT (0,0)",
            Anchor.unclipped(Rect(7, 5, 3, 1)), Size(14, 3), Rect(6, 3, 20, 8), pol,
            "the pin is to boundary.x = 6 — clamping at 0 would leave the "
                ~ "overlay 4 cells outside its own boundary"),
        Case("cross-axis alignment flip (opt-in)",
            Anchor.unclipped(Rect(17, 2, 6, 1)), Size(12, 3), Rect(0, 0, 26, 9), crossFlip,
            "Floating UI's rule: try the other alignment on the SAME side "
                ~ "before sliding"),
    ];

    foreach (i, ref c; cases)
    {
        const r = place(c.anchor, c.content, c.boundary, c.policy);
        checkInvariants(c.anchor, c.content, c.boundary, c.policy, r);
        report(cast(int) i + 1, c, r);
    }

    // -- The case-specific assertions, stated as the specification will state them.
    writeln("=== what the cases pin ===");

    const fits = place(cases[0].anchor, cases[0].content, cases[0].boundary, cases[0].policy);
    assert(fits.fit == Fit.exact && fits.applied == Adjust.none);
    assert(fits.side == Side.bottom && !fits.flippedMain);
    writeln("  1  a preferred placement fires no adjustment at all");

    const flipped = place(cases[1].anchor, cases[1].content, cases[1].boundary, cases[1].policy);
    assert(flipped.side == Side.top && flipped.flippedMain);
    assert(flipped.rect.bottom <= cases[1].anchor.rect.y, "a flipped overlay must clear the anchor");
    writeln("  2  a main-axis flip is reported as a resolved side, not inferred");

    const slid = place(cases[2].anchor, cases[2].content, cases[2].boundary, cases[2].policy);
    assert(slid.side == Side.bottom && slid.applied.has(Adjust.slideCross));
    assert(slid.rect.right == cases[2].boundary.right, "a cross-axis slide pins the end edge");
    assert(slid.arrowCentred, "the arrow follows the anchor after a slide");
    writeln("  3  sliding moves the rect and the arrow independently");

    const both = place(cases[3].anchor, cases[3].content, cases[3].boundary, cases[3].policy);
    assert(both.applied.has(Adjust.flipMain) && both.applied.has(Adjust.slideCross));
    writeln("  4  the two axes are solved independently, so both may fire");

    const wide = place(cases[4].anchor, cases[4].content, cases[4].boundary, cases[4].policy);
    assert(wide.rect.x == cases[4].boundary.x, "the START edge wins when the content is too wide");
    assert(wide.rect.right > cases[4].boundary.right && wide.fit == Fit.overflowing);
    writeln("  5  oversize content pins its start edge and REPORTS the overflow");

    const tall = place(cases[5].anchor, cases[5].content, cases[5].boundary, cases[5].policy);
    assert(tall.fit == Fit.shrunk && tall.applied.has(Adjust.resizeMain));
    assert(tall.rect.height == tall.available.height, "a capped overlay takes the room reported");
    assert(!tall.flippedMain, "revertUnlessFree refuses a flip that does not fit either");
    writeln("  6  resize is the LAST resort, and the cap equals the reported room");

    const hidden = place(cases[6].anchor, cases[6].content, cases[6].boundary, cases[6].policy);
    assert(hidden.anchorHidden, "an anchor outside its clip must be reported hidden");
    assert(!hidden.rect.empty, "a hidden anchor still yields geometry — hide, do not close");
    assert(!hidden.arrowCentred, "the arrow clamped, and said so");
    writeln("  7  anchorHidden hides; the geometry survives, and the arrow admits it clamped");

    // RTL: `start` is the right edge. The same request under LTR lands elsewhere.
    auto asLtr = cases[7].policy;
    asLtr.direction = Direction.ltr;
    const rtlPlaced = place(cases[7].anchor, cases[7].content, cases[7].boundary, cases[7].policy);
    const ltrPlaced = place(cases[7].anchor, cases[7].content, cases[7].boundary, asLtr);
    assert(rtlPlaced.align_ == Align.end && rtlPlaced.flippedCross);
    assert(ltrPlaced.align_ == Align.start && !ltrPlaced.flippedCross);
    assert(rtlPlaced.rect.right == cases[7].anchor.rect.right, "RTL start aligns the RIGHT edges");
    assert(ltrPlaced.rect.x == cases[7].anchor.rect.x, "LTR start aligns the LEFT edges");
    writefln!"  8  align=start ⇒ x=%d under RTL, x=%d under LTR — resolved before the solve"(
        rtlPlaced.rect.x, ltrPlaced.rect.x);

    // The clamp-to-zero case, stated twice: once at a positive boundary origin,
    // once at a negative one, where a legitimate placement is itself negative.
    const off = place(cases[8].anchor, cases[8].content, cases[8].boundary, cases[8].policy);
    const aligned = cases[8].anchor.rect.x
        + (cases[8].anchor.rect.width - cases[8].content.width) / 2;
    assert(off.rect.x == cases[8].boundary.x, "the pin is the boundary's start edge");
    assert(off.rect.x != 0, "a boundary that does not start at 0 must not pin at 0");
    assert(off.fit != Fit.overflowing && cases[8].boundary.intersection(off.rect) == off.rect);
    const todayAbs = clampOriginToday(aligned, cases[8].content.width, cases[8].boundary.right);
    const todayRel = clampOriginToday(aligned, cases[8].content.width, cases[8].boundary.width);
    writefln!"  9  centred x would be %d; place() pins %d (boundary.x)"(aligned, off.rect.x);
    writefln!("     clampOrigin(%d,%d,extent) gives %d absolute / %d pane-relative — %d cells"
        ~ " outside a boundary that starts at %d")(
        aligned, cases[8].content.width, todayAbs, todayRel,
        cases[8].boundary.x - todayAbs, cases[8].boundary.x);

    // A viewport scrolled above/left of the origin: positions are legitimately
    // negative, and clamping at zero detaches the overlay from its anchor.
    const negBoundary = Rect(-4, -2, 20, 8);
    const negAnchor = Anchor.unclipped(Rect(-3, 0, 3, 1));
    const neg = place(negAnchor, Size(14, 3), negBoundary, pol);
    checkInvariants(negAnchor, Size(14, 3), negBoundary, pol, neg);
    const negAligned = negAnchor.rect.x + (negAnchor.rect.width - 14) / 2;
    assert(neg.rect.x == negBoundary.x && neg.rect.x < 0,
        "a negative boundary origin is a legal placement, not an error to clamp away");
    writefln!"     negative-origin boundary %s: place() pins x=%d, clampOrigin gives %d"(
        rectText(negBoundary), neg.rect.x,
        clampOriginToday(negAligned, 14, negBoundary.right));

    const crossFlipped = place(cases[9].anchor, cases[9].content, cases[9].boundary, cases[9].policy);
    auto noFlip = cases[9].policy;
    noFlip.adjust = pol.adjust;
    noFlip.align_ = Align.start;
    const wouldSlide = place(cases[9].anchor, cases[9].content, cases[9].boundary, noFlip);
    assert(crossFlipped.align_ == Align.end && crossFlipped.flippedCross);
    assert(crossFlipped.fit == Fit.flipped && wouldSlide.fit == Fit.slid);
    writefln!" 10  flipCross lands x=%d (align=end); sliding alone would land x=%d"(
        crossFlipped.rect.x, wouldSlide.rect.x);

    writeln();
    writeln("=== invariants held for every case ===");
    writeln("  I1  rect.origin >= boundary.origin           (the pin is the boundary, not 0)");
    writeln("  I2  fit != overflowing => rect inside boundary");
    writeln("  I3  1 <= arrowCell <= edgeLen - 2            (never a corner glyph)");
    writeln("  I4  place(resolved side/align) == the same rect, with no further flip");
}
