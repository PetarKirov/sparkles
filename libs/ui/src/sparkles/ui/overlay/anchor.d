/**
What an anchored overlay is positioned against, and how that resolves.

The anchor is the placement seam's $(B input): a Regular POD in integer cells,
with no live handle, no closure and no lifetime (`ANC1`). Every subject the
[anchored-overlay catalog](../../../../../../docs/research/anchored-overlays/index.md)
surveyed reduces its anchor to a rect-plus-gravity value before any placement
arithmetic — the Wayland positioner makes the copy normative, Avalonia's
positioner parameters are literally a `record struct`, GTK4's layout equality
compares ten POD fields. The narrowing is deliberate and is about the seam, not
about every use a subject makes of an anchor reference.

The uses that genuinely need a handle elsewhere each get an explicit
value-shaped substitute here rather than a pointer:

$(LIST
    * the clipping boundary becomes a $(B parameter) of the solve (`PLC3`),
    * anchor liveness becomes a $(B field) on the resolution (`ANC6`),
    * re-measurement is simply the next frame, because the tree is rebuilt.
)

$(LREF Anchor) and $(LREF AnchorRect) are deliberately $(B different types).
The solve must never write its resolution back into the request: a design that
aliases the two is forced to re-introduce the request later, once something
needs to know what was asked for rather than what happened (`ANC2`).

Resolution is one pure function over producers the frame already derived —
$(REF rectOfKey, sparkles,ui,state) for a keyed widget,
$(REF clippedSelectionRects, sparkles,ui,state) for a source range. Both are
clip-aware and both distinguish "names nothing" from "scrolled out of its
viewport", which is the distinction an overlay's hide-versus-close verdict rests
on (`DSM8`).

Spec: `docs/specs/ui/popup.md` `ANC1`–`ANC9`.
*/
module sparkles.ui.overlay.anchor;

import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.state : KeyLookup, RangeLookup;

@safe pure nothrow @nogc:

/// Which producer resolves an anchor, and therefore which of its fields carry
/// meaning. A closed sum: a kind nobody can name is a placement nobody can
/// audit.
enum AnchorKind : ubyte
{
    key,       /// a `Widget.key`, resolved through `rectOfKey`
    rect,      /// a cell rect the caller computed (the dock hint has no widget)
    point,     /// a pointer or caret cell, materialised 1×1
    textRange, /// source bytes, resolved through `clippedSelectionRects`
    spot,      /// a boundary-relative area, for a screen-anchored surface
}

/// Whether an anchor re-resolves every frame or is frozen at open (`ANC5`).
///
/// This is a per-anchor $(B policy field), not a fixed rule, because the corpus
/// splits on it for good reasons: WPF, ImGui and Neovim latch, while Helix
/// ships a live per-frame point anchor with row hysteresis. A widget anchor is
/// naturally `live` — the tree is rebuilt, so the rect is re-derived anyway. A
/// point anchor defaults to `latched`, and on the terminal it is latched at
/// $(B press), because there is no key release to latch at (`INP16`).
enum AnchorTracking : ubyte
{
    latched, /// frozen at open; the default for a point or cursor anchor
    live,    /// re-resolved each frame
}

/// A boundary-relative area for a screen-anchored surface — a toast, a
/// notifier, a centred modal (`ANC8`).
///
/// The nine CSS grid areas rather than the four corners the spec's prose names:
/// a centred surface is not a corner, and widening the sum is what keeps the
/// primitive count at one instead of growing a second engine for the case.
enum Spot : ubyte
{
    topLeft,    /// ditto
    top,        /// ditto
    topRight,   /// ditto
    left,       /// ditto
    center,     /// ditto
    right,      /// ditto
    bottomLeft, /// ditto
    bottom,     /// ditto
    bottomRight, /// ditto
}

/**
The placement request's anchor half — what to position against.

Regular (`PRN6`): total `==`, independent copies, no handle, no closure, no
lifetime. Two of these compare equal iff they name the same thing, which is what
lets a caller keep one across frames and ask whether anything changed.
*/
struct Anchor
{
    /// Which of the fields below carry meaning.
    AnchorKind kind;
    /// `kind == key`: the `Widget.key` to resolve. Key `0` is "unkeyed" and so
    /// is not a name — it resolves to `missing`.
    size_t key;
    /// `kind == rect | point`: the cell rect itself.
    Rect rect;
    /// `kind == textRange`: source byte offsets, half-open `[srcLo, srcHi)`.
    size_t srcLo;
    /// ditto
    size_t srcHi;
    /// `kind == spot`: which boundary-relative area.
    Spot spot;
    /// A rect the overlay should avoid covering, beyond the anchor itself —
    /// ImGui's `r_avoid`. Empty means none.
    Rect avoid;
    /// Whether the anchor re-resolves per frame (`ANC5`).
    AnchorTracking tracking = AnchorTracking.latched;

@safe pure nothrow @nogc:

    /// A keyed widget. `live` by default: the tree is rebuilt each frame, so
    /// the rect is re-derived whether or not anyone asked.
    static Anchor ofKey(size_t k, AnchorTracking t = AnchorTracking.live)
        => Anchor(kind: AnchorKind.key, key: k, tracking: t);

    /// A rect the caller worked out itself, for a surface with no widget
    /// behind it — the dock hint is the in-tree example.
    static Anchor ofRect(in Rect r, AnchorTracking t = AnchorTracking.live)
        => Anchor(kind: AnchorKind.rect, rect: r, tracking: t);

    /// A pointer or caret cell. Materialised $(B 1×1), never `0×0` (`ANC4`) —
    /// an empty anchor rect has no centre to align to and no edge to flip
    /// about, so every downstream computation on it is degenerate.
    static Anchor atPoint(in Point p, AnchorTracking t = AnchorTracking.latched)
        => Anchor(kind: AnchorKind.point, rect: Rect(p.x, p.y, 1, 1),
            tracking: t);

    /// A source byte range, resolved through the clip-aware producer.
    static Anchor ofRange(size_t lo, size_t hi,
        AnchorTracking t = AnchorTracking.live)
    in (lo <= hi, "a source range runs forwards")
        => Anchor(kind: AnchorKind.textRange, srcLo: lo, srcHi: hi,
            tracking: t);

    /// A boundary-relative area (`ANC8`).
    static Anchor at(Spot s) => Anchor(kind: AnchorKind.spot, spot: s);
}

/**
The resolved anchor — where the thing actually is this frame, and whether it is
there at all.

A separate type from $(LREF Anchor) on purpose (`ANC2`). The three failure modes
are kept apart because a caller that cannot tell them apart writes a silent bug
for each, and because two of them lead to $(B opposite) actions: an anchor that
is gone must close the overlay (mandatory, bypassing the dismissal policy word),
while an anchor that is merely clipped must $(B hide) it and keep it open, ready
for the next scroll to bring it back (`DSM8`).
*/
struct AnchorRect
{
    /// The rect to solve against, in cells. Meaningless unless `live`.
    Rect primary;
    /// The anchor resolved to something this frame. `false` ⇒ it is gone, and
    /// the overlay must close.
    bool live;
    /// It resolved, but the clip stack left none of it on screen. `true` ⇒
    /// hide, do not close.
    bool clipped;
    /// More than one element carried the name (`ANC7`). The resolver refuses
    /// rather than picking a winner, so `live` is `false` when this is set.
    bool ambiguous;

@safe pure nothrow @nogc const:

    /// The anchor is usable: it resolved, it is unambiguous, and some of it is
    /// on screen.
    bool ok() => live && !clipped;
}

/**
Everything this frame derived that an anchor may resolve through (`ANC3`).

Borrowed views, gathered once by the host and never stored by
$(LREF resolveAnchor) — which is what keeps resolution a pure function of the
frame rather than a query against a live tree.
*/
struct AnchorSource
{
    /// The lookup for `AnchorKind.key`, already performed by the host through
    /// $(REF rectOfKey, sparkles,ui,state). Passing the $(I answer) rather than
    /// the tree keeps this module free of the widget model.
    KeyLookup keyed;
    /// The lookup for `AnchorKind.textRange`, from
    /// $(REF clippedSelectionRects, sparkles,ui,state).
    RangeLookup range;
    /// The box a `AnchorKind.spot` anchor is measured against — normally the
    /// placement boundary.
    Rect boundary;
}

/**
The one resolution (`ANC1`, `ANC3`, `ANC6`).

Liveness is a set/identity test over the frame's own derived lookups — no
observers, no event source, nothing to unsubscribe. Note what this makes
$(B true by construction): an anchor is live exactly when this frame's tree
still contains it, so a widget that stopped being rendered closes its overlay
without anyone having to notice and say so.

$(B Frame-to-frame stability of a key is an authoring convention, not a toolkit
guarantee) (`ANC6`). Every current consumer derives its keys from a domain index
— a source offset, a row number — and an anchor id must be domain-derived too. A
key minted from a loop counter silently re-points the overlay when the list
reorders.
*/
AnchorRect resolveAnchor(in Anchor a, in AnchorSource src)
{
    final switch (a.kind)
    {
        case AnchorKind.key:
            if (src.keyed.ambiguous)
                return AnchorRect(ambiguous: true);
            if (src.keyed.missing)
                return AnchorRect.init;
            return AnchorRect(primary: src.keyed.rect, live: true,
                clipped: src.keyed.clipped);

        case AnchorKind.rect:
        case AnchorKind.point:
            // A caller-supplied rect answers for itself. An empty one is not a
            // degenerate anchor to be tolerated — it is an absent one, and
            // reporting it as such is what stops the solve centring on a rect
            // with no centre (`ANC4`).
            return a.rect.empty
                ? AnchorRect.init
                : AnchorRect(primary: a.rect, live: true);

        case AnchorKind.textRange:
            if (src.range.missing)
                return AnchorRect.init;
            if (src.range.clipped)
                return AnchorRect(live: true, clipped: true);
            // The first row. A range that spans a wrap point wants all of them
            // (`ANC9`), which is latent: today a hover anchor is a space-free
            // identifier and the wrap engine never splits a word, so the first
            // rect is the whole of it.
            return AnchorRect(primary: src.range.rects[0], live: true);

        case AnchorKind.spot:
            return src.boundary.empty
                ? AnchorRect.init
                : AnchorRect(primary: spotRect(a.spot, src.boundary),
                    live: true);
    }
}

/**
The 1×1 cell a $(LREF Spot) names inside `boundary`.

One cell rather than the whole area, so a screen-anchored surface goes through
exactly the same solve as every other overlay: `bottomRight` plus a `top` side
places a toast above the bottom-right corner, with the same flip, slide and
resize ladder. That is what keeps the primitive count at one (`ANC8`).
*/
Rect spotRect(Spot s, in Rect boundary)
in (!boundary.empty, "a spot is measured against a real boundary")
{
    // The far edge is exclusive, so the last addressable cell is `right - 1`.
    const lo = boundary.origin;
    const mid = Point(boundary.x + boundary.width / 2,
        boundary.y + boundary.height / 2);
    const hi = Point(boundary.right - 1, boundary.bottom - 1);

    int px, py;
    final switch (s)
    {
        case Spot.topLeft:     px = lo.x;  py = lo.y;  break;
        case Spot.top:         px = mid.x; py = lo.y;  break;
        case Spot.topRight:    px = hi.x;  py = lo.y;  break;
        case Spot.left:        px = lo.x;  py = mid.y; break;
        case Spot.center:      px = mid.x; py = mid.y; break;
        case Spot.right:       px = hi.x;  py = mid.y; break;
        case Spot.bottomLeft:  px = lo.x;  py = hi.y;  break;
        case Spot.bottom:      px = mid.x; py = hi.y;  break;
        case Spot.bottomRight: px = hi.x;  py = hi.y;  break;
    }
    return Rect(px, py, 1, 1);
}

@("ui.overlay.anchor.pointIsOneCellNeverZero")
@safe pure nothrow @nogc unittest
{
    // `ANC4`. A `0×0` anchor has no centre to align to and no edge to flip
    // about, so every downstream computation on it is degenerate — the
    // constructor is the only place that can make the mistake impossible.
    const a = Anchor.atPoint(Point(7, 3));
    assert(a.rect == Rect(7, 3, 1, 1));
    assert(!a.rect.empty);
    assert(a.tracking == AnchorTracking.latched,
        "a cursor anchor latches by default — the TUI has no key release");
    assert(Anchor.ofKey(9).tracking == AnchorTracking.live,
        "a widget anchor re-resolves: the tree is rebuilt anyway");
}

@("ui.overlay.anchor.requestAndResolutionAreDifferentTypes")
@safe pure nothrow @nogc unittest
{
    // `ANC2`: the solve must never write its resolution back into the request.
    // The types not being assignable to one another is the enforcement.
    static assert(!is(Anchor : AnchorRect) && !is(AnchorRect : Anchor));
    static assert(!__traits(compiles, { Anchor a; AnchorRect r; a = r; }));
}

@("ui.overlay.anchor.goneAndClippedAreDifferentAnswers")
@safe pure nothrow @nogc unittest
{
    // `DSM8`: anchor gone closes (mandatory); anchor clipped hides. A resolver
    // that collapses them either leaves a popup pinned to a stale rect or
    // destroys state the next scroll would have restored.
    const gone = resolveAnchor(Anchor.ofKey(4), AnchorSource.init);
    assert(!gone.live && !gone.clipped && !gone.ok);

    AnchorSource clipped;
    clipped.keyed = KeyLookup(count: 1, clipped: true);
    const hid = resolveAnchor(Anchor.ofKey(4), clipped);
    assert(hid.live && hid.clipped && !hid.ok,
        "found, nothing on screen — hide, do not close");

    AnchorSource shown;
    shown.keyed = KeyLookup(count: 1, rect: Rect(3, 4, 10, 1));
    const hit = resolveAnchor(Anchor.ofKey(4), shown);
    assert(hit.ok && hit.primary == Rect(3, 4, 10, 1));
}

@("ui.overlay.anchor.ambiguityRefusesRatherThanPicks")
@safe pure nothrow @nogc unittest
{
    // `ANC7`: a duplicate key is an ambiguity with no positional fallback.
    // Adopting `keyAt`'s last-in-paint-order-wins here would reproduce CSS
    // anchor positioning's documented N-instances-resolve-to-the-last-match
    // failure, in which an overlay silently tracks a different element.
    AnchorSource twice;
    twice.keyed = KeyLookup(count: 2, rect: Rect(1, 1, 4, 1));
    const r = resolveAnchor(Anchor.ofKey(4), twice);
    assert(r.ambiguous && !r.live && !r.ok);
    assert(r.primary == Rect.init, "a refused lookup reports no geometry");
}

@("ui.overlay.anchor.emptyRectIsAbsentNotDegenerate")
@safe pure nothrow @nogc unittest
{
    const empty = resolveAnchor(Anchor.ofRect(Rect(5, 5, 0, 3)),
        AnchorSource.init);
    assert(!empty.live, "a zero-extent rect is an absent anchor");
    const real_ = resolveAnchor(Anchor.ofRect(Rect(5, 5, 2, 3)),
        AnchorSource.init);
    assert(real_.ok && real_.primary == Rect(5, 5, 2, 3));
}

@("ui.overlay.anchor.spotsLandInsideTheBoundary")
@safe pure nothrow @nogc unittest
{
    // `ANC8`: a screen-anchored surface shares the anchor sum and the solve, so
    // a spot must behave like any other anchor — one addressable cell, always
    // inside the boundary, never on the exclusive far edge.
    const b = Rect(10, 4, 80, 24);
    static foreach (s; [Spot.topLeft, Spot.top, Spot.topRight, Spot.left,
            Spot.center, Spot.right, Spot.bottomLeft, Spot.bottom,
            Spot.bottomRight])
    {{
        const r = spotRect(s, b);
        assert(r.size == typeof(r.size)(1, 1));
        assert(b.contains(r.origin), "a spot is inside its boundary");
    }}
    assert(spotRect(Spot.topLeft, b).origin == Point(10, 4));
    assert(spotRect(Spot.bottomRight, b).origin == Point(89, 27),
        "the far edge is exclusive, so the last cell is right-1/bottom-1");
    assert(spotRect(Spot.center, b).origin == Point(50, 16));
}

@("ui.overlay.anchor.rangeResolvesThroughTheClipAwareProducer")
@safe pure nothrow @nogc unittest
{
    AnchorSource src;
    src.range = RangeLookup(count: 0);
    assert(!resolveAnchor(Anchor.ofRange(4, 9), src).live);

    src.range = RangeLookup(count: 1, clipped: true);
    const scrolledOut = resolveAnchor(Anchor.ofRange(4, 9), src);
    assert(scrolledOut.live && scrolledOut.clipped && !scrolledOut.ok);
}

@("ui.overlay.anchor.isRegular")
@safe pure nothrow @nogc unittest
{
    // `PRN6`. Equality is total and structural, a copy is independent, and
    // there is nothing to keep alive — which is the whole reason the placement
    // seam takes a value rather than a reference to the thing it points at.
    const a = Anchor.atPoint(Point(2, 2));
    Anchor b = a;
    assert(a == b);
    b.rect = Rect(9, 9, 1, 1);
    assert(a != b, "a copy is independent");
    assert(a == Anchor.atPoint(Point(2, 2)), "equal iff they name the same");
    assert(Anchor.ofRange(1, 5) != Anchor.ofRange(1, 6));
}
