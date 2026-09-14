/**
The placement solve: one pure, total function from an anchor, a content size and
a boundary to a decision record.

$(H2 Why the result is a record and not a rect)

Returning only an offset is the named anti-pattern of the
[anchored-overlay catalog](../../../../../../docs/research/anchored-overlays/index.md),
and the corpus prices it. Among the subjects that need the resolved side for
anything, every one whose result $(I discards) it either pays to recover it —
Compose with a downcast plus a one-frame-late coordinate comparison plus a
duplicated clamp, WPF re-deriving the direction as two `BitVector32` bits, GPUI
reinventing its flip at three call sites — or forecloses the feature entirely.

Sparkles was the sharpest case in that corpus, because the datum already existed
with nothing producing it: `Decoration.arrow`/`arrowOffset` were documented
"backends place it", and consequently all four canvases hard-coded the arrow to
the top edge and none clamped the offset against the box. So $(LREF place)
returns $(LREF OverlayGeometry) — the whole decision record — and discarding it
is the mistake (`PLC2`, `PLC10`).

$(H2 The precedence is fixed in the value)

$(B flip, then slide, then resize) — resize last, floored at the caller's
minimum (`PLC5`). Not a middleware chain, not a per-call ordering: GTK4's
`GdkAnchorHints` and the Wayland positioner both fix this order, and keeping the
mask structurally isomorphic to `(anchor rect, gravity, constraint-adjustment,
offset)` is what keeps a future native positioner cheap (`POP5`).

$(H2 What integer cells buy, and what they cost)

`LAY3`'s integer cells delete the fractional-pixel, DPR and transform concerns
that dominate the web subjects, and make the caret exact rather than
approximate. They cost two things this module has to honour:

$(LIST
    * A laid-out position may legitimately be $(B negative) — content scrolled
        above or left of a viewport — so the clamp is to the $(B boundary),
        never to `0`. That is the whole of `PLC4`, and the bug in the
        `clampOrigin` this module retires.
    * `Point`/`Size` are `Vector`-backed unions, so a named-field read is
        unavailable in CTFE. $(LREF place) is therefore $(B not)
        `@ctfe`-evaluable and must not be specified as such; it is covered by
        runtime property tests instead (`PLC1`, `PRN11`).
)

$(H2 What this module deliberately does not do)

It queries nothing. The boundary and the coordinate space are explicit
parameters, never derived inside the solve (`PLC3`), and there is no
`getClippingRect` step because the clip stack is already threaded to every node
by $(REF childClipOf, sparkles,ui,layout) and `layout()` is the measurement
(`PLC15`).

Right-to-left resolution is $(B absent), not forgotten. The catalog's reference
implementation carries a `physical()` step that resolves a logical alignment
before the solve — the shape that makes an RTL omission unrepresentable — but
`sparkles:ui` has no reading-direction vocabulary anywhere, so shipping one here
would be untested policy with no consumer. It belongs in front of this function
when the toolkit grows one.

Spec: `docs/specs/ui/popup.md` `PLC1`–`PLC15`.
*/
module sparkles.ui.overlay.place;

import sparkles.ui.geometry : Insets, Point, Rect, Size;
import sparkles.ui.overlay.anchor : AnchorRect;
import sparkles.ui.style : BoxSide, isVertical, opposite;

@safe pure nothrow @nogc:

/**
Which edge of the $(B anchor) the overlay attaches to.

`Side.bottom` means the overlay hangs below the anchor, so its own $(I top) edge
faces the anchor and its arrow hangs off that top edge. An alias rather than a
new enum: the toolkit has one side vocabulary, and the four canvases drifting
into private notions of "the arrow edge" is precisely the defect `PLC10`
retires (`PRN8`).
*/
alias Side = BoxSide;

/// Cross-axis alignment: which of the overlay's edges lines up with the
/// anchor's. `start` is the left or top edge, depending on the axis.
enum Align : ubyte
{
    start,  /// the overlay's start edge meets the anchor's start edge
    center, /// centres on the anchor
    end,    /// the overlay's end edge meets the anchor's end edge
}

/**
Which adjustments the caller permits — and, on the result, which actually fired.

Structurally GTK4's `GdkAnchorHints` / `xdg_positioner`'s
`constraint_adjustment`, so a native windowing backend can forward the request
unchanged (`POP5`). Named against the $(I anchor's) axes rather than the
screen's: "main" is the axis the side points along, "cross" is the edge the
overlay attaches across. The mapping to xdg's absolute X/Y is a rotation by the
resolved side, which the request already carries.
*/
enum Adjust : ubyte
{
    none = 0,
    flipMain = 1 << 0,    /// cross to the opposite side of the anchor
    slideMain = 1 << 1,   /// shift along the side axis (detaches; opt-in)
    flipCross = 1 << 2,   /// mirror the alignment (opt-in)
    slideCross = 1 << 3,  /// shift along the edge axis
    resizeMain = 1 << 4,  /// shrink to the room at the resolved side
    resizeCross = 1 << 5, /// shrink to the boundary's cross extent (opt-in)
}

/// Bit tests, spelled once, so the solve reads as prose.
bool has(Adjust a, Adjust f) => (a & f) != 0;
/// ditto
Adjust plus(Adjust a, Adjust f) => cast(Adjust)(a | f);

/**
How good the resulting placement is — worst wins.

`overflowing` and `refused` are different answers and a consumer must treat them
differently. `overflowing` means the overlay is placed and usable but larger
than the boundary on some axis, with its start edge pinned and its end
overflowing (`PLC8`) — the deliberate outcome when the policy forbids resizing.
`refused` means there is no honest placement at all: the boundary cannot hold
even the caller's minimum size. A refused overlay must $(B not) be painted; the
arena drops it, which is `DSM1`'s mandatory `unplaceable` cause.
*/
enum Fit : ubyte
{
    exact,       /// placed exactly as asked
    slid,        /// shifted along an axis to stay inside
    flipped,     /// crossed to the other side of the anchor
    shrunk,      /// the content was capped, but not below the floor
    overflowing, /// placed, but it does not fit — we are the host, nobody clips
    refused,     /// no placement exists; do not paint this
}

/**
The genuine fork the survey found, and it is observable inside one toolkit:
GTK4 accepts a flip whenever it is $(I less bad); `xdg_positioner` reverts
unless the flipped position is fully unconstrained. The two produce different
placements for the same input, so this is a policy field rather than a choice
baked into the solve (`PLC6`).
*/
enum FlipAcceptance : ubyte
{
    revertUnlessFree, /// flip only when the other side fits completely
    lessBadWins,      /// flip whenever the other side has more room
}

/// Which edge is pinned when the overlay simply cannot fit the boundary on an
/// axis (`PLC8`). A Sparkles decision, not a consensus — the majority of
/// shift-style implementations pin the start, but Avalonia pins the end and
/// Compose centres.
enum OverflowPin : ubyte
{
    startEdge, /// the start edge pins; the end overflows
    endEdge,   /// the end edge pins; the start overflows
}

/// The mirrored alignment — what a cross-axis flip resolves to.
Align mirror(Align a)
    => a == Align.start ? Align.end : (a == Align.end ? Align.start : Align.center);

/**
The placement $(B request): everything the caller asks for, and nothing the
solve decides.

Never written back to (`ANC2`), so what was asked stays readable beside what was
got — which is what lets `PLC13`'s stability field be an explicit input rather
than a hidden memo.
*/
struct Placement
{
    /// The preferred anchor edge.
    Side side = Side.bottom;
    /// The preferred cross-axis alignment.
    Align alignment = Align.center;
    /// The gutter between anchor and overlay, in cells, folded in $(B before)
    /// the constraint test. Zero by default: with a zero-cell corridor the
    /// pointer-travel problem does not arise at all (`TRG12`).
    int sideOffset;
    /// A nudge along the edge axis, in cells.
    int alignOffset;
    /// Reserve a cell on the attached edge for the arrow. A placement
    /// $(B input); the resolved cell is an output (`PLC10`).
    bool arrow;
    /// The floor the resize step stops at (`PLC5`). Zero on an axis means
    /// "one cell" — a caller with a real minimum passes the theme's
    /// `popupMinWidth`/`popupMinHeight`.
    Size minSize;
    /// The ceiling, applied to the content before anything else. `0` means
    /// unbounded.
    Size maxSize;
    /// Which adjustments are permitted. The default flips the side axis,
    /// slides the edge axis and caps the main extent; side-axis slide and
    /// cross-axis flip are opt-in because both detach the overlay from its
    /// anchor (`PLC7`).
    Adjust adjust = cast(Adjust)(Adjust.flipMain | Adjust.slideCross
        | Adjust.resizeMain);
    /// How eagerly a flip is accepted (`PLC6`).
    FlipAcceptance acceptance = FlipAcceptance.revertUnlessFree;
    /// Which edge pins when nothing fits (`PLC8`).
    OverflowPin pin = OverflowPin.startEdge;
    /// The side accepted last frame, carried forward by the caller (`PLC13`).
    ///
    /// An $(B explicit input), never a hidden memo, because events route
    /// against the last painted frame: an oscillating placement is a routing
    /// bug, not a visual one. The solve starts from this side rather than from
    /// `side`, so once flipped it stays flipped until the original side
    /// genuinely fits again.
    Side lastGoodSide = Side.bottom;
    /// ditto
    bool haveLastGood;
}

/// Named presets, so a consumer picks a behaviour rather than assembling flag
/// soup at each call site.
immutable Placement popupCollision = Placement.init;

/// ditto — a dropdown caps its height rather than jumping above its trigger:
/// a list that flips sides under the user's cursor loses their place.
immutable Placement dropdownCollision = Placement(
    adjust: cast(Adjust)(Adjust.slideCross | Adjust.resizeMain));

/// ditto — a hint has no content worth preserving, so it may go anywhere it
/// fits.
immutable Placement hintCollision = Placement(
    adjust: cast(Adjust)(Adjust.flipMain | Adjust.flipCross | Adjust.slideCross
        | Adjust.resizeMain));

/**
The placement $(B result): the whole decision record (`PLC2`).

Every field is one a backend or an emitter would otherwise re-derive — which is
exactly what Compose, Avalonia and hue's three `clampOrigin` call sites each
ended up doing, differently.
*/
struct OverlayGeometry
{
    /// The resolved rect in integer cells, clamped to the $(B boundary) and
    /// never to zero (`PLC4`).
    Rect rect;
    /// The anchor edge actually attached to, post-flip. This is the field whose
    /// absence the corpus pays for, and the one the canvases need for the arrow.
    Side side = Side.bottom;
    /// The cross-axis alignment actually used, post-mirror.
    Align alignment = Align.center;
    /// The worst thing that happened.
    Fit fit;
    /// Which of the $(I permitted) adjustments fired. Always a subset of the
    /// request's mask — a result that claimed an adjustment the caller forbade
    /// would be unusable as a check. The mandatory boundary pin is not in here;
    /// it is the solve's own invariant, and it shows in `adjusted` and `fit`.
    Adjust applied;
    /// The arrow's cell along the attached edge, overlay-local from the box
    /// origin with the border inset included, so the legal interval is
    /// `[1, extent - 2]` and it can never land on a corner glyph (`ANC4`).
    int arrowCell;
    /// Whether an arrow is drawable at all. `false` when the caller did not ask
    /// for one, or when the attached edge is too short to hold one — in which
    /// case the caret is $(B suppressed) rather than jammed into a corner.
    bool arrowVisible;
    /// Whether the arrow reached the anchor's centre cell exactly. When
    /// `false`, the caret was clamped and points only approximately: a consumer
    /// may prefer the categorical `alignment` to a numeric origin it cannot
    /// trust (`PLC11`).
    bool arrowCentred;
    /// The room actually available at the resolved side, in cells. Callers used
    /// to compute this themselves — `width - anchor.x - 1`, and each site got
    /// the fencepost differently.
    Size available;
    /// The anchor expressed in overlay-local cells, so a consumer drawing a
    /// connector does not re-subtract the origin.
    Rect anchorLocal;
    /// How far each edge moved from the un-slid ask, in cells, signed along the
    /// axis: positive is right or down. A pure translation moves all four edges
    /// alike. All zero for a `Fit.exact` placement — and non-zero whenever the
    /// mandatory boundary pin fired, which is how a caller sees a move its own
    /// policy did not permit.
    Insets adjusted;
    /// The anchor resolved but its clip left nothing on screen. A $(B hide)
    /// verdict, known before placement rather than computed after it (`DSM8`) —
    /// the overlay stays open and unpainted, ready for the next scroll.
    bool anchorHidden;

@safe pure nothrow @nogc const:

    /// Whether this geometry should be painted at all. A hidden anchor and a
    /// refused placement both answer `false`, and they are different states:
    /// the first survives to the next frame, the second is dropped.
    bool paintable() => !anchorHidden && fit != Fit.refused;
}

/**
Place `content` against `anchor` inside `boundary`, under `req`.

Per axis: the $(B main) (side) axis flips, then slides if permitted, then
resizes — floored at `req.minSize`. The $(B cross) (edge) axis aligns, optionally
mirrors, then slides end-edge-first so the start edge wins the tie, which is
what pins the start and overflows the end (`PLC8`). Every clamp is against
`boundary`, never against the coordinate origin (`PLC4`).

The `out` contract is the executable form of that last sentence, and the reason
this function exists: `clampOrigin` clamped to `0`, which is wrong for any
boundary that does not start at the surface origin — a pane in a split, a
viewport scrolled right.
*/
OverlayGeometry place(in Placement req, in AnchorRect anchor, in Size content,
    in Rect boundary)
in (anchor.live, "a dead anchor is a close decision, not a placement problem")
in (!boundary.empty, "the boundary must cover at least one cell")
out (g; !g.paintable || (req.pin == OverflowPin.startEdge
        ? g.rect.x >= boundary.x && g.rect.y >= boundary.y
        : g.rect.right <= boundary.right && g.rect.bottom <= boundary.bottom),
    "the PINNED edge lands on the BOUNDARY, never on the coordinate origin")
{
    // Step 0 — the hide verdict, known before any arithmetic. `DSM8` makes this
    // a property of the anchor and its clip, not a fit computed afterwards.
    if (anchor.clipped)
        return OverlayGeometry(anchorHidden: true, fit: Fit.refused);

    const floorW = req.minSize.width > 0 ? req.minSize.width : 1;
    const floorH = req.minSize.height > 0 ? req.minSize.height : 1;

    // Step 1 — can the boundary hold anything at all? A boundary narrower than
    // the floor has no honest placement, and saying so is more useful than
    // returning a two-column popup nobody can read.
    if (boundary.width < floorW || boundary.height < floorH)
        return OverlayGeometry(fit: Fit.refused, anchorLocal: anchor.primary);

    // The ceiling is applied to the ask, before the side is chosen — `PLC9`:
    // the side is chosen from a size BOUND, and the bound is what `layout()`
    // is then given.
    const wantW = capped(content.width, req.maxSize.width);
    const wantH = capped(content.height, req.maxSize.height);

    // `PLC13` — start from the side accepted last frame, so a marginal fit does
    // not oscillate between frames. Only when it is on the same axis as the
    // request: a caller that changed axis changed its mind.
    const startSide = req.haveLastGood && req.lastGoodSide.isVertical
            == req.side.isVertical
        ? req.lastGoodSide
        : req.side;

    const vertical = startSide.isVertical;
    const arrowGap = req.arrow ? 1 : 0;

    // --- main (side) axis ---------------------------------------------------
    const bLo = vertical ? boundary.y : boundary.x;
    const bHi = vertical ? boundary.bottom : boundary.right;
    const aLo = vertical ? anchor.primary.y : anchor.primary.x;
    const aHi = vertical ? anchor.primary.bottom : anchor.primary.right;
    const mainWant = vertical ? wantH : wantW;
    const mainFloor = vertical ? floorH : floorW;

    // The gutter and the arrow clearance fold in BEFORE the constraint test —
    // xdg_positioner's rule. Testing the un-offset rect re-introduces exactly
    // the overflow the flip just resolved.
    const gap = req.sideOffset + arrowGap;
    bool atEnd = startSide == Side.bottom || startSide == Side.right;
    int room = atEnd ? bHi - (aHi + gap) : (aLo - gap) - bLo;
    int other = atEnd ? (aLo - gap) - bLo : bHi - (aHi + gap);

    Adjust applied = Adjust.none;
    bool flippedMain;
    if (mainWant > room && req.adjust.has(Adjust.flipMain))
    {
        const accept = req.acceptance == FlipAcceptance.revertUnlessFree
            ? mainWant <= other  // xdg: revert unless the flip is FULLY free
            : other > room;      // gtk4: accept whenever it is less bad
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
        // `PLC5`'s floor: resize is the LAST step and it stops here. Shrinking
        // past the floor does not make the overlay fit, it makes it useless.
        mainLen = room > mainFloor ? room : mainFloor;
        if (mainLen != mainWant)
            applied = applied.plus(Adjust.resizeMain);
    }

    const mainAsked = atEnd ? aHi + gap : aLo - gap - mainLen;
    int mainPos = mainAsked;
    if (req.adjust.has(Adjust.slideMain) && mainPos + mainLen > bHi)
        mainPos = bHi - mainLen;
    // The boundary pin is NOT an optional adjustment — it is the invariant the
    // `out` contract states, and it runs whether or not sliding was permitted.
    // Reporting it in `applied` would let the result claim an adjustment the
    // caller forbade; it shows up in `adjusted` and in `fit` instead.
    mainPos = pinned(mainPos, mainLen, bLo, bHi, req.pin);
    if (mainPos != mainAsked && req.adjust.has(Adjust.slideMain))
        applied = applied.plus(Adjust.slideMain);

    // --- cross (edge) axis --------------------------------------------------
    const cbLo = vertical ? boundary.x : boundary.y;
    const cbHi = vertical ? boundary.right : boundary.bottom;
    const caLo = vertical ? anchor.primary.x : anchor.primary.y;
    const caHi = vertical ? anchor.primary.right : anchor.primary.bottom;
    const crossWant = vertical ? wantW : wantH;
    const crossFloor = vertical ? floorW : floorH;

    int crossLen = crossWant;
    if (crossLen > cbHi - cbLo && req.adjust.has(Adjust.resizeCross))
    {
        const room2 = cbHi - cbLo;
        crossLen = room2 > crossFloor ? room2 : crossFloor;
        if (crossLen != crossWant)
            applied = applied.plus(Adjust.resizeCross);
    }

    int alignedAt(Align a) => a == Align.start
        ? caLo
        : (a == Align.end ? caHi - crossLen : caLo + ((caHi - caLo) - crossLen) / 2);

    Align alignment = req.alignment;
    int crossPos = alignedAt(alignment) + req.alignOffset;

    if (req.adjust.has(Adjust.flipCross)
        && (crossPos < cbLo || crossPos + crossLen > cbHi))
    {
        const m = mirror(alignment);
        const mp = alignedAt(m) + req.alignOffset;
        if (mp >= cbLo && mp + crossLen <= cbHi)
        {
            alignment = m;
            crossPos = mp;
            applied = applied.plus(Adjust.flipCross);
        }
    }

    const crossAsked = crossPos;
    if (req.adjust.has(Adjust.slideCross) && crossPos + crossLen > cbHi)
        crossPos = cbHi - crossLen;   // the end edge first …
    crossPos = pinned(crossPos, crossLen, cbLo, cbHi, req.pin); // … pin last
    if (crossPos != crossAsked && req.adjust.has(Adjust.slideCross))
        applied = applied.plus(Adjust.slideCross);

    const rect = vertical
        ? Rect(crossPos, mainPos, crossLen, mainLen)
        : Rect(mainPos, crossPos, mainLen, crossLen);

    // --- the arrow ----------------------------------------------------------
    // The attached edge always runs along the cross axis, so the caret is one
    // integer: an overlay-local cell on that edge, clamped strictly inside it so
    // it can never overwrite a corner glyph. A short edge can INVERT the legal
    // interval, so the guard is a length test rather than a clamp trusted to
    // cope — a clamp silently returns `max` where the interval inverts (`ANC4`).
    int arrowCell;
    bool arrowVisible, arrowCentred;
    if (req.arrow && crossLen >= 3)
    {
        const lo = 1, hi = crossLen - 2;
        assert(lo <= hi, "an arrow interval must never invert");
        const want = caLo + (caHi - caLo) / 2 - crossPos;
        arrowCell = want < lo ? lo : (want > hi ? hi : want);
        arrowVisible = true;
        arrowCentred = arrowCell == want;
    }

    const askedRect = vertical
        ? Rect(crossAsked, mainAsked, crossLen, mainLen)
        : Rect(mainAsked, crossAsked, mainLen, crossLen);
    // Signed edge movement. A translation moves all four edges alike; a size
    // change is reported through `applied`/`fit`, not here.
    const moved = rect.origin != askedRect.origin;

    const inside = boundary.intersection(rect) == rect;
    const fit = !inside
        ? Fit.overflowing
        : applied.has(Adjust.resizeMain) || applied.has(Adjust.resizeCross)
            ? Fit.shrunk
            : applied.has(Adjust.flipMain) || applied.has(Adjust.flipCross)
                ? Fit.flipped
                // `moved` and not merely `applied`: the boundary pin can shift
                // an overlay whose policy forbade sliding, and calling that
                // placement `exact` would be a lie a consumer acts on.
                : moved
                    ? Fit.slid
                    : Fit.exact;

    return OverlayGeometry(
        rect: rect,
        side: flippedMain ? startSide.opposite : startSide,
        alignment: alignment,
        fit: fit,
        applied: applied,
        arrowCell: arrowCell,
        arrowVisible: arrowVisible,
        arrowCentred: arrowCentred,
        available: vertical ? Size(cbHi - cbLo, room) : Size(room, cbHi - cbLo),
        anchorLocal: Rect(anchor.primary.x - rect.x, anchor.primary.y - rect.y,
            anchor.primary.width, anchor.primary.height),
        adjusted: Insets(
            top: rect.y - askedRect.y,
            right: rect.right - askedRect.right,
            bottom: rect.bottom - askedRect.bottom,
            left: rect.x - askedRect.x),
        anchorHidden: false,
    );
}

/// `v` capped at `ceiling`, where `0` means unbounded.
private int capped(int v, int ceiling) => ceiling > 0 && v > ceiling ? ceiling : v;

/**
Bring `[pos, pos+len)` inside `[lo, hi)`, or — when it cannot be — pin the edge
`pin` names and let the other overflow (`PLC8`).

Every clamp here is against the boundary, never against `0`, which is the whole
of `PLC4`. The two cases are separated on purpose: clamping the end and then the
start in sequence is what produces the bug where an overlay wider than its
boundary pins its start and $(I still) reports an end inside it.
*/
private int pinned(int pos, int len, int lo, int hi, OverflowPin pin)
{
    if (len > hi - lo)  // it cannot fit: one edge is chosen, the other overflows
        return pin == OverflowPin.startEdge ? lo : hi - len;
    if (pos + len > hi) // it fits: the end edge first …
        pos = hi - len;
    return pos < lo ? lo : pos;  // … and the start edge wins the tie
}

@("ui.overlay.place.clampsToTheBoundaryNeverToZero")
@safe pure nothrow @nogc unittest
{
    // `PLC4`, the executable form. This is the defect `clampOrigin` shipped:
    // it clamped to `0`, which is only correct when the boundary starts at the
    // surface origin. A pane in a split does not, and neither does a viewport
    // scrolled right — so the popup jumped to the far side of the divider.
    const anchor = AnchorRect(primary: Rect(52, 10, 4, 1), live: true);
    const boundary = Rect(40, 0, 30, 24);   // a right-hand pane

    const g = place(Placement.init, anchor, Size(60, 3), boundary);
    assert(g.rect.x == 40, "pinned to the pane's left edge, not to column 0");
    assert(g.rect.x != 0);

    // And with a boundary whose origin IS zero the two rules agree, which is
    // why the bug survived: every test anyone wrote used the whole screen.
    const g0 = place(Placement.init, AnchorRect(primary: Rect(12, 10, 4, 1),
        live: true), Size(60, 3), Rect(0, 0, 30, 24));
    assert(g0.rect.x == 0);
}

@("ui.overlay.place.negativePositionsAreLegitimate")
@safe pure nothrow @nogc unittest
{
    // A boundary may start left of or above the origin — content scrolled out
    // of a viewport lays out at negative cells (`geometry.d`'s own note). A
    // clamp to zero would drag the overlay to a place its anchor is not.
    const boundary = Rect(-20, -8, 40, 20);
    const anchor = AnchorRect(primary: Rect(-18, -6, 2, 1), live: true);
    const g = place(Placement.init, anchor, Size(10, 3), boundary);
    assert(g.rect.x < 0 && g.rect.y < 0, "negative is a real answer");
    assert(g.rect.x >= boundary.x && g.rect.y >= boundary.y);
}

@("ui.overlay.place.flipMirrorsTheSideAndReportsIt")
@safe pure nothrow @nogc unittest
{
    // The result carries the resolved side. Every subject that discarded it
    // paid to re-derive it, and the re-derivations disagreed with the placement
    // they were supposed to describe.
    const boundary = Rect(0, 0, 80, 24);
    const anchor = AnchorRect(primary: Rect(10, 22, 6, 1), live: true);

    const g = place(Placement.init, anchor, Size(20, 8), boundary);
    assert(g.side == Side.top, "no room below; it went above");
    assert(g.applied.has(Adjust.flipMain) && g.fit == Fit.flipped);
    assert(g.rect.bottom <= anchor.primary.y, "above means above");

    // With room, nothing moves and the request is honoured verbatim.
    const roomy = place(Placement.init,
        AnchorRect(primary: Rect(10, 2, 6, 1), live: true), Size(20, 8), boundary);
    assert(roomy.side == Side.bottom && roomy.fit == Fit.exact);
    assert(roomy.applied == Adjust.none && roomy.adjusted == Insets.init);
}

@("ui.overlay.place.resizeIsLastAndStopsAtTheFloor")
@safe pure nothrow @nogc unittest
{
    // `PLC5`: flip, then slide, then resize — and the resize floors. Shrinking
    // past the floor does not make an overlay fit, it makes it unreadable.
    const boundary = Rect(0, 0, 80, 12);
    const anchor = AnchorRect(primary: Rect(10, 6, 6, 1), live: true);
    auto req = Placement.init;
    req.minSize = Size(24, 5);

    // Neither side has 20 rows; it flips to the roomier one, then caps.
    const g = place(req, anchor, Size(30, 20), boundary);
    assert(g.applied.has(Adjust.resizeMain));
    assert(g.rect.height >= req.minSize.height, "never below the floor");

    // A boundary that cannot hold the floor has no honest placement at all.
    const tiny = place(req, AnchorRect(primary: Rect(1, 1, 1, 1), live: true),
        Size(30, 20), Rect(0, 0, 10, 3));
    assert(tiny.fit == Fit.refused && !tiny.paintable,
        "refused is not overflowing — do not paint it");
}

@("ui.overlay.place.theArrowIsClampedInsideTheEdgeOrSuppressed")
@safe pure nothrow @nogc unittest
{
    // The two live defects `PLC10`/`PLC11` retire: nothing in `sparkles:ui`
    // clamped `arrowOffset` against the box, so `arrowOffset >= width - 2`
    // unconditionally overwrote a corner glyph.
    const boundary = Rect(0, 0, 80, 24);
    auto req = Placement.init;
    req.arrow = true;

    // An anchor far left of a wide overlay drags the caret to the interval's
    // low end — clamped, and honestly reported as not centred.
    const off = place(req, AnchorRect(primary: Rect(0, 4, 1, 1), live: true),
        Size(40, 4), boundary);
    assert(off.arrowVisible);
    assert(off.arrowCell >= 1 && off.arrowCell <= off.rect.width - 2,
        "strictly inside the edge: a caret never lands on a corner");

    // An edge too short to hold one suppresses the caret rather than jamming
    // it into a corner — there is no legal cell, so there is no arrow.
    auto narrow = req;
    narrow.adjust = Adjust.none;
    const none = place(narrow, AnchorRect(primary: Rect(4, 4, 1, 1), live: true),
        Size(2, 3), boundary);
    assert(!none.arrowVisible, "no legal cell ⇒ no caret");

    // Centred when it can be, and it says so.
    const mid = place(req, AnchorRect(primary: Rect(20, 4, 4, 1), live: true),
        Size(10, 4), boundary);
    assert(mid.arrowVisible && mid.arrowCentred);
}

@("ui.overlay.place.stabilityKeepsTheAcceptedSide")
@safe pure nothrow @nogc unittest
{
    // `PLC13`. Events route against the LAST PAINTED frame's hit data, so an
    // oscillating placement is a routing bug, not a cosmetic one: the overlay
    // is drawn where it is not, and clicks land on whatever is underneath.
    const boundary = Rect(0, 0, 80, 24);
    const anchor = AnchorRect(primary: Rect(10, 15, 6, 1), live: true);

    const first = place(Placement.init, anchor, Size(20, 10), boundary);
    assert(first.side == Side.top, "8 rows below, 15 above — it flips");

    // Next frame the content shrinks to something that fits below again. With
    // `revertUnlessFree` and the accepted side carried forward, it stays put
    // rather than snapping back and forth as the content breathes.
    auto stable = Placement.init;
    stable.lastGoodSide = first.side;
    stable.haveLastGood = true;
    const second = place(stable, anchor, Size(20, 8), boundary);
    assert(second.side == Side.top, "the accepted side holds");

    // Without the field it snaps back — which is the oscillation.
    const unstable = place(Placement.init, anchor, Size(20, 8), boundary);
    assert(unstable.side == Side.bottom);
}

@("ui.overlay.place.reportsTheRoomAndTheLocalAnchor")
@safe pure nothrow @nogc unittest
{
    // `PLC2`: the fields callers used to re-derive. `available` replaces
    // `width - anchor.x - 1`, whose fencepost each of hue's three sites got
    // differently; `anchorLocal` replaces re-subtracting the origin.
    const boundary = Rect(0, 0, 80, 24);
    const anchor = AnchorRect(primary: Rect(10, 4, 6, 1), live: true);
    const g = place(Placement.init, anchor, Size(20, 6), boundary);

    assert(g.available.height == boundary.bottom - anchor.primary.bottom,
        "the room below the anchor, computed once");
    assert(g.anchorLocal.x == anchor.primary.x - g.rect.x);
    assert(g.anchorLocal.y == anchor.primary.y - g.rect.y);
    assert(g.anchorLocal.size == anchor.primary.size);
}

@("ui.overlay.place.aHiddenAnchorHidesRatherThanCloses")
@safe pure nothrow @nogc unittest
{
    // `DSM8`: the hide-versus-fit split is a property of the anchor and its
    // clip, known BEFORE placement, not a verdict computed after it.
    const g = place(Placement.init,
        AnchorRect(live: true, clipped: true), Size(10, 3), Rect(0, 0, 80, 24));
    assert(g.anchorHidden && !g.paintable);
    assert(g.fit == Fit.refused);
}

@("ui.overlay.place.propertiesHoldAcrossTheMatrix")
@safe pure nothrow @nogc unittest
{
    // `PRN11` + the V0 acceptance gate. A systematic sweep rather than a random
    // one: the interesting inputs are the degenerate and the boundary-adjacent
    // ones, and a sweep hits every one of them on every run instead of some of
    // them sometimes. 4 boundaries x 13 anchors x 5 contents x 4 sides x 3
    // alignments x 2 acceptances x 2 pins = 24960 solves.
    static immutable Rect[] boundaries = [
        Rect(0, 0, 80, 24),      // the ordinary screen
        Rect(40, 0, 30, 24),     // a right-hand pane: origin is NOT zero
        Rect(-20, -8, 40, 20),   // scrolled out of a viewport: negative origin
        Rect(3, 3, 6, 4),        // smaller than most content
    ];
    static immutable Size[] contents = [
        Size(1, 1), Size(3, 2), Size(20, 6), Size(40, 20), Size(200, 100),
    ];
    static immutable Side[] sides =
        [Side.top, Side.right, Side.bottom, Side.left];
    static immutable Align[] alignments = [Align.start, Align.center, Align.end];

    foreach (ref const b; boundaries)
    {
        // Anchor positions worth solving: each corner, each edge midpoint, the
        // centre, and four just outside — an anchor scrolled past the boundary
        // is a real frame, not a malformed input.
        immutable Point[13] spots = [
            Point(b.x, b.y), Point(b.right - 1, b.y),
            Point(b.x, b.bottom - 1), Point(b.right - 1, b.bottom - 1),
            Point(b.x + b.width / 2, b.y),
            Point(b.x + b.width / 2, b.bottom - 1),
            Point(b.x, b.y + b.height / 2),
            Point(b.right - 1, b.y + b.height / 2),
            Point(b.x + b.width / 2, b.y + b.height / 2),
            Point(b.x - 4, b.y), Point(b.right + 4, b.y),
            Point(b.x, b.y - 4), Point(b.x, b.bottom + 4),
        ];

        foreach (ref const p; spots)
        foreach (ref const c; contents)
        foreach (s; sides)
        foreach (al; alignments)
        foreach (acc; [FlipAcceptance.revertUnlessFree, FlipAcceptance.lessBadWins])
        foreach (pin; [OverflowPin.startEdge, OverflowPin.endEdge])
        {
            auto req = Placement.init;
            req.side = s;
            req.alignment = al;
            req.acceptance = acc;
            req.pin = pin;
            req.arrow = true;
            req.minSize = Size(4, 3);

            const anchor = AnchorRect(primary: Rect(p.x, p.y, 2, 1), live: true);
            const g = place(req, anchor, c, b);

            if (!g.paintable)
            {
                assert(g.fit == Fit.refused, "unpaintable means refused");
                continue;
            }

            // 1. Inside the boundary, or it says so. Nobody clips for us.
            const inside = b.intersection(g.rect) == g.rect;
            assert(inside || g.fit == Fit.overflowing,
                "a placement outside the boundary must report overflowing");

            // 2. `PLC4`/`PLC8`. The pinned edge lands on the BOUNDARY. Stated
            //    separately from the `out` contract because the failure it
            //    guards is silent: with `b.x == 0` a clamp-to-zero passes, and
            //    every test anyone wrote used the whole screen.
            if (pin == OverflowPin.startEdge)
                assert(g.rect.x >= b.x && g.rect.y >= b.y);
            else
                assert(g.rect.right <= b.right && g.rect.bottom <= b.bottom);

            // 3. No adjustment fires that the caller did not permit.
            assert((g.applied & ~req.adjust) == 0);

            // 4. `PLC5`'s floor: the resize step never shrinks past it. Which
            //    axis "main" names depends on the RESOLVED side, not on the
            //    requested one — a flip keeps the axis, so either works, but
            //    reading it off the result is the honest spelling.
            const mainLen = g.side.isVertical ? g.rect.height : g.rect.width;
            const crossLen = g.side.isVertical ? g.rect.width : g.rect.height;
            const mainFloor = g.side.isVertical
                ? req.minSize.height : req.minSize.width;
            const crossFloor = g.side.isVertical
                ? req.minSize.width : req.minSize.height;
            assert(!g.applied.has(Adjust.resizeMain) || mainLen >= mainFloor);
            assert(!g.applied.has(Adjust.resizeCross) || crossLen >= crossFloor);

            // 5. A flip mirrors the side; it never rotates it. `PLC6`: the
            //    anchor edge and the gravity move together, so the axis is
            //    invariant.
            assert(g.side == s || g.side == s.opposite);
            assert(g.side.isVertical == s.isVertical);

            // 6. `ANC4`/`PLC10`: the caret is strictly inside the edge it hangs
            //    off, or there is no caret. Never a corner glyph.
            const edge = g.side.isVertical ? g.rect.width : g.rect.height;
            assert(!g.arrowVisible
                || (g.arrowCell >= 1 && g.arrowCell <= edge - 2));
            assert(!g.arrowVisible || edge >= 3);

            // 7. `PLC12`: one solve per frame is only correct if the solve is
            //    deterministic. Two calls on identical inputs must agree.
            assert(place(req, anchor, c, b) == g);

            // 8. `PLC13`: feeding the accepted side back must not move it.
            //    This is the anti-oscillation property, and the reason the
            //    field is an input rather than a memo.
            auto again = req;
            again.lastGoodSide = g.side;
            again.haveLastGood = true;
            assert(place(again, anchor, c, b).side == g.side,
                "the accepted side must be a fixed point");
        }
    }
}

@("ui.overlay.place.appliedIsAlwaysASubsetOfWhatWasPermitted")
@safe pure nothrow @nogc unittest
{
    // A solve that fires an adjustment the caller forbade is not a placement,
    // it is a surprise. `dropdownCollision` is the case that matters: a list
    // that flips above its trigger under the user's cursor loses their place,
    // so it caps its height instead.
    const boundary = Rect(0, 0, 80, 24);
    const anchor = AnchorRect(primary: Rect(10, 20, 6, 1), live: true);
    const g = place(dropdownCollision, anchor, Size(20, 15), boundary);

    assert(!g.applied.has(Adjust.flipMain), "flipping was not permitted");
    assert(g.side == Side.bottom, "it stayed below its trigger");
    assert(g.applied.has(Adjust.resizeMain) && g.fit == Fit.shrunk);
    assert((g.applied & ~dropdownCollision.adjust) == 0);
}
