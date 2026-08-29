/**
The top layer: one ordered, frame-built collection of overlay records, where
$(B index order is paint order is reverse hit order).

$(H2 Openness is membership, not a flag)

An overlay is open because it is $(I in) this frame's arena, and invisible
because it is absent (`LYR1`, `LYR9`). That is not a corpus law — Textual keeps
invisible widgets behind a flag and derives both views from it — but sparkles
has a paint walk and $(B two) hit walks, each of which would have to honour such
a flag independently, and one of them will forget. Membership cannot be
forgotten by one walk and not another.

The same reasoning makes the arena $(B frame-built) rather than mutated. It is
rebuilt from the application's state each frame, exactly as the widget tree is,
which dissolves a whole class of re-entrancy: a cascade that closes three
overlays and reopens one during dismissal needs no re-check, because the reopened
one simply appears in the next frame's arena (`DSM6`).

$(H2 What ordering buys, and what it costs)

Every subject in the catalog that gets nesting and LIFO dismissal right owns one
ordered collection; the ones keeping only a per-surface boolean reconstruct the
ordering ad hoc at each site that needs it. Ordering here is a $(B closed band
vocabulary) plus index within a band (`LYR2`) — deliberately not a per-overlay
integer, because the corpus documents that failure twice: a priority chosen "to
beat" three particular strangers, in a codebase where nobody can see all four.

$(H2 The parent link)

Each record carries one parent index and the ancestor relation is a $(B query
over list order), never a stored tree (`LYR4`). The parent must be strictly
earlier in the list, which is what turns a possibly-cyclic graph of connections
into a well-formed forest by construction rather than by validation.

Spec: `docs/specs/ui/popup.md` `LYR1`–`LYR4`, `LYR9`, `LYR10`, `LYR12`, `POP7`.
*/
module sparkles.ui.overlay.arena;

import sparkles.base.buffer : SharedBuffer;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.layout : Frame, OutOfFlow, translateSubtree;
import sparkles.ui.overlay.anchor : Anchor, AnchorKind, AnchorSource,
    resolveAnchor;
import sparkles.ui.overlay.place : Fit, OverlayGeometry, place, Placement, Side;
import sparkles.ui.state : clippedSelectionRects, rectOfKey, Timeline;
import sparkles.ui.widget : HitBehavior, WidgetTree;

@safe:

/**
The closed band vocabulary (`LYR2`, `LYR12`).

Declaration order is the ladder: a later band paints over an earlier one, and
within a band index order decides. Each rung has a named owner, which is what
keeps the vocabulary from growing on request:

$(LIST
    * `adorn` carries the dock hint — never focusable, never a dismissal parent.
    * `popup` carries menus, dropdowns, context menus and hovercards. It is the
        $(B only) band that participates in the dismissal stack.
    * `hint` carries tooltips: never a dismissal parent, never focusable.
    * `notify` carries toasts, which must stay visible and clickable while a
        modal overlay is open — the opposite of every anchored overlay's
        contract, and the reason a notifier shares the solve and nothing else.
)
*/
enum OverlayBand : ubyte
{
    adorn,  /// ditto
    popup,  /// ditto
    hint,   /// ditto
    notify, /// ditto
}

/**
A generational handle: a slot plus a generation (`LYR3`).

A frame-built arena guarantees that a handle held across a frame boundary is
stale, so staleness must be $(B distinguishable) rather than merely unlikely —
which a bare index is not, since the next frame will reuse it for something
else. `gen == 0` is the null handle, so a default-constructed `OverlayId` names
nothing and cannot accidentally name slot zero.
*/
struct OverlayId
{
    uint slot; /// index into the arena at the frame it was minted
    uint gen;  /// mint generation; `0` is the null handle

@safe pure nothrow @nogc const:

    /// Whether this handle names anything at all.
    bool valid() => gen != 0;
}

/// `POP7`'s $(B stated) capacity — a bound, not an unbounded list. Waiting
/// consumers: a dock hint (1), a menu with two submenu levels (3), a tooltip
/// (1), a notifier stack. Reaching it degrades; it does not assert.
enum size_t maxOverlays = 8;

/// ditto — the depth a `parent` chain may reach before a cascade is refused.
/// GPUI asserts depth `< 10`; Qt bounds its close loop at 1024.
enum size_t maxOverlayDepth = 4;

/**
One overlay this frame: what it is anchored to, where the solve put it, and how
it participates in paint, hit testing and the cascade.
*/
struct OverlayRecord
{
    /// This record's handle, minted by $(LREF OverlayArena.push).
    OverlayId id;
    /// The overlay this one cascaded from; a null handle means root-owned.
    /// Guaranteed strictly earlier in the list (`LYR4`).
    OverlayId parent;
    /// Which band, and therefore where in the paint ladder.
    OverlayBand band = OverlayBand.popup;
    /// The widget node this record $(B emits) — a `panel` in the frame's tree.
    /// The content is authored as a child of its anchor; only the emission is
    /// hoisted (`POP3`).
    uint node = uint.max;
    /// Per-record scope membership. The parent link alone does not cover focus
    /// containment or scope-keyed modality: two sibling overlays may share a
    /// containment scope without either being the other's parent (`LYR4`).
    size_t scopeKey;
    /// What this overlay is positioned against, and what it asked for.
    Anchor anchor;
    /// ditto
    Placement placement;
    /// What the solve answered. Filled in by the overlay pass.
    OverlayGeometry resolved;
    /// Whether this overlay hides what is behind it from the hit walks.
    HitBehavior hit;
    /// The fade/hold clock, composed rather than reinvented (`STM6`).
    Timeline life;
    /// The frame this record first appeared in — `DSM9`'s one-frame exemption
    /// from outside dismissal, since an overlay's hit rect is one frame stale
    /// by construction.
    uint openedFrame;
    /// The hit id of the element that opened this overlay, so focus can be
    /// returned to it and so a re-activation can be recognised.
    size_t triggerHit;

@safe pure nothrow @nogc const:

    /**
    Whether this record contributes paint, and whether it contributes hit
    entries. Derived, never stored — `LYR10` requires an overlay animating $(I
    out) to keep painting while taking no input, and a stored pair of flags is
    two more things the three walks could disagree about.

    A closing surface that kept its hit entries would swallow input for the
    length of its own fade, which reads to a user as a dead click.
    */
    bool contributesPaint()
        => !resolved.anchorHidden && resolved.fit != typeof(resolved.fit).refused
            && life.visible;

    /// ditto
    bool contributesHits()
        => contributesPaint && life.phase != Timeline.Phase.fadeOut;
}

/**
The ordered, frame-built arena (`LYR1`).

Bounded by $(LREF maxOverlays) — a `SharedBuffer`, so a frame with no overlays
costs no allocation and a frame with eight costs none either (`POP7`).
*/
struct OverlayArena
{
    /// The records, in paint order.
    SharedBuffer!(OverlayRecord, maxOverlays) records;
    /// The next generation to mint. Starts at 1 so `gen == 0` stays null.
    uint nextGen = 1;

@safe pure nothrow @nogc:

    /// How many overlays are open this frame.
    size_t length() const scope => records.length;
    /// ditto
    bool empty() const scope => records.length == 0;
    /// Whether the stated capacity is reached.
    bool full() const scope => records.length >= maxOverlays;

    /// The record at `i`, in paint order.
    ref OverlayRecord opIndex(size_t i) return
    in (i < records.length)
        => records[i];

    /// ditto — `scope`-callable, so a reader can take the arena as `in` and
    /// still index it (the buffer holds a pointer once it outgrows its inline
    /// storage, which is what makes the qualifier necessary).
    ref const(OverlayRecord) opIndex(size_t i) const return scope
    in (i < records.length)
        => records[i];

    /**
    Appends `r` and mints its handle.

    Returns the null handle when the stated capacity is reached, or when `r`'s
    parent is not already in the arena. A runaway cascade $(B degrades) — the
    surface that would not fit simply does not open — rather than asserting: the
    capacity is a policy bound, and a policy bound is not an invariant violation.
    */
    OverlayId push(OverlayRecord r)
    {
        if (full)
            return OverlayId.init;
        // `LYR4`: the parent must be strictly earlier, which is what makes a
        // well-formed forest out of whatever graph a caller had in mind.
        if (r.parent.valid)
        {
            const p = indexOf(r.parent);
            if (p >= records.length)
                return OverlayId.init;
            if (depthOf(r.parent) + 1 >= maxOverlayDepth)
                return OverlayId.init;
        }
        r.id = OverlayId(cast(uint) records.length, nextGen++);
        records ~= r;
        return r.id;
    }

    /// The index of `h`, or `length` when the handle is stale or absent.
    size_t indexOf(OverlayId h) const
    {
        if (!h.valid)
            return records.length;
        foreach (i, ref const rec; records[])
            if (rec.id == h)
                return i;
        return records.length;
    }

    /// Whether `h` names a record in this frame's arena.
    bool isOpen(OverlayId h) const => indexOf(h) < records.length;

    /// The frontmost record of `band`, or the null handle when it is empty.
    OverlayId topmost(OverlayBand band) const
    {
        OverlayId found;
        foreach (ref const rec; records[])
            if (rec.band == band)
                found = rec.id;
        return found;
    }

    /**
    Whether `candidate` is `maybeAncestor` or descends from it — a query over
    list order, never a stored tree (`LYR4`).

    Bounded by $(LREF maxOverlayDepth) rather than trusting the parent-is-earlier
    invariant to terminate the walk: a cycle here would hang a frame, and the
    bound costs one comparison.
    */
    bool isWithin(OverlayId maybeAncestor, OverlayId candidate) const
    {
        if (!maybeAncestor.valid || !candidate.valid)
            return false;
        auto at = candidate;
        foreach (_; 0 .. maxOverlayDepth + 1)
        {
            if (at == maybeAncestor)
                return true;
            const i = indexOf(at);
            if (i >= records.length)
                return false;
            at = records[i].parent;
        }
        return false;
    }

    /// How many ancestors `h` has; `0` for a root-owned overlay.
    size_t depthOf(OverlayId h) const
    {
        size_t d;
        auto at = h;
        foreach (_; 0 .. maxOverlayDepth + 1)
        {
            const i = indexOf(at);
            if (i >= records.length)
                break;
            at = records[i].parent;
            if (!at.valid)
                break;
            ++d;
        }
        return d;
    }

    /**
    This arena truncated at `index` — the whole of cascading dismissal (`DSM6`).

    Closing an overlay closes everything opened after it, and because index
    order is the ladder, "everything after it" is a slice. The reopen-during-
    dismissal re-check that the popover specification requires has no analogue
    here: the arena is rebuilt next frame from application state, so a surface
    that reopens simply appears.
    */
    OverlayArena truncatedAt(size_t index) const
    {
        OverlayArena cut;
        cut.nextGen = nextGen;
        foreach (i, ref const rec; records[])
        {
            if (i >= index)
                break;
            cut.records ~= rec;
        }
        return cut;
    }

    /**
    The frontmost overlay whose resolved rect contains `p`, or the null handle.

    Front-to-back is $(B reverse) index order, because index order is paint
    order: the last thing painted is the first thing hit. Only records that
    contribute hit entries answer, so a surface fading out is transparent to
    the pointer while still on screen (`LYR10`).
    */
    OverlayId hitAt(in Point p) const scope
    {
        foreach_reverse (ref const rec; records[])
            if (rec.contributesHits && rec.resolved.rect.contains(p))
                return rec.id;
        return OverlayId.init;
    }

    /// The index at which dismissing `h` truncates: `h` itself, or `length`
    /// when the handle is stale (dismissing nothing removes nothing).
    size_t cascadeFrom(OverlayId h) const => indexOf(h);
}

/// The hoist set `a` implies over a tree of `nodeCount` nodes.
OutOfFlow hoistedBy(in OverlayArena a, size_t nodeCount) pure nothrow
{
    if (a.empty)
        return OutOfFlow.init;
    auto flags = new bool[](nodeCount);
    foreach (ref const rec; a.records[])
        if (rec.node < nodeCount)
            flags[rec.node] = true;
    return OutOfFlow(flags);
}

@("ui.overlay.arena.indexOrderIsPaintOrder")
@safe pure nothrow @nogc unittest
{
    OverlayArena a;
    const hint = a.push(OverlayRecord(band: OverlayBand.hint, node: 1));
    const menu = a.push(OverlayRecord(band: OverlayBand.popup, node: 2));

    assert(a.length == 2);
    assert(a[0].id == hint && a[1].id == menu, "insertion order is the order");
    assert(a.isOpen(hint) && a.isOpen(menu));
    assert(a.topmost(OverlayBand.popup) == menu);
    assert(!a.topmost(OverlayBand.adorn).valid, "an empty band names nothing");
}

@("ui.overlay.arena.staleHandlesAreDistinguishable")
@safe pure nothrow @nogc unittest
{
    // `LYR3`. A frame-built arena guarantees a handle held across a frame is
    // stale, so staleness must be detectable — a bare index is not, because the
    // next frame reuses it for a different overlay.
    OverlayArena first;
    const held = first.push(OverlayRecord(node: 1));

    OverlayArena next;          // the next frame, same slot, new generation
    next.nextGen = first.nextGen;
    const fresh = next.push(OverlayRecord(node: 9));

    assert(held.slot == fresh.slot, "the slot is reused, as it must be");
    assert(held != fresh && !next.isOpen(held),
        "the generation is what makes last frame's handle recognisably dead");
    assert(!OverlayId.init.valid, "and a default handle names nothing");
}

@("ui.overlay.arena.membershipIsOpenness")
@safe pure nothrow @nogc unittest
{
    // `LYR9`: an invisible overlay is ABSENT, not flagged. Sparkles has a paint
    // walk and two hit walks; a flag is three chances for one of them to forget.
    // There is deliberately no `visible` field on a record to forget.
    static assert(!__traits(hasMember, OverlayRecord, "visible"));
    static assert(!__traits(hasMember, OverlayRecord, "open"));

    OverlayArena a;
    a.push(OverlayRecord(node: 1));
    assert(a.length == 1);
    assert(a.truncatedAt(0).empty, "closing it is removing it");
}

@("ui.overlay.arena.aFadingOverlayPaintsButTakesNoHits")
@safe pure nothrow @nogc unittest
{
    // `LYR10`. Events route against the LAST PAINTED frame, so a closing
    // surface that kept its hit entries would swallow input for the length of
    // its own fade — which reads as a dead click, not as an animation.
    OverlayRecord r;
    r.life = Timeline(phase: Timeline.Phase.hold);
    assert(r.contributesPaint && r.contributesHits);

    r.life = Timeline(phase: Timeline.Phase.fadeOut);
    assert(r.contributesPaint, "it is still on screen");
    assert(!r.contributesHits, "and it must not take the click");

    r.life = Timeline(phase: Timeline.Phase.idle);
    assert(!r.contributesPaint && !r.contributesHits);

    // A hidden anchor withdraws both — the overlay stays open, ready for the
    // next scroll to bring its anchor back (`DSM8`).
    r.life = Timeline(phase: Timeline.Phase.hold);
    r.resolved.anchorHidden = true;
    assert(!r.contributesPaint && !r.contributesHits);
}

@("ui.overlay.arena.theParentIsAlwaysEarlier")
@safe pure nothrow @nogc unittest
{
    // `LYR4`: the strictly-earlier rule is what makes a well-formed forest out
    // of whatever graph a caller had in mind — enforced at `push`, so a cycle
    // is unrepresentable rather than merely invalid.
    OverlayArena a;
    const root = a.push(OverlayRecord(node: 1));
    const sub = a.push(OverlayRecord(parent: root, node: 2));
    const subsub = a.push(OverlayRecord(parent: sub, node: 3));

    assert(a.indexOf(root) < a.indexOf(sub));
    assert(a.depthOf(root) == 0 && a.depthOf(sub) == 1 && a.depthOf(subsub) == 2);
    assert(a.isWithin(root, subsub) && a.isWithin(root, root));
    assert(!a.isWithin(subsub, root), "ancestry is not symmetric");

    // A parent that is not in this arena cannot be adopted.
    OverlayArena other;
    assert(!other.push(OverlayRecord(parent: root, node: 4)).valid);
}

@("ui.overlay.arena.cascadeIsATruncation")
@safe pure nothrow @nogc unittest
{
    // `DSM6`. Closing an overlay closes everything opened after it, and because
    // index order IS the ladder, that is a slice rather than a graph walk.
    OverlayArena a;
    const root = a.push(OverlayRecord(node: 1));
    a.push(OverlayRecord(parent: root, node: 2));
    a.push(OverlayRecord(parent: root, node: 3));

    const cut = a.truncatedAt(a.cascadeFrom(root));
    assert(cut.empty, "closing the root closes its whole chain");

    const keepRoot = a.truncatedAt(1);
    assert(keepRoot.length == 1 && keepRoot[0].node == 1);
    assert(keepRoot.nextGen == a.nextGen,
        "generations never rewind, or a stale handle could come back to life");

    // A stale handle dismisses nothing rather than truncating at zero — which
    // would close every overlay on screen.
    assert(a.cascadeFrom(OverlayId.init) == a.length);
    assert(a.truncatedAt(a.cascadeFrom(OverlayId.init)).length == a.length);
}

@("ui.overlay.arena.capacityDegradesRatherThanAsserting")
@safe pure nothrow @nogc unittest
{
    // `POP7` wants a STATED capacity. Reaching it is a policy bound, not an
    // invariant violation, so the surface that will not fit simply does not
    // open — a runaway cascade degrades instead of killing the frame.
    OverlayArena a;
    foreach (i; 0 .. maxOverlays)
        assert(a.push(OverlayRecord(node: cast(uint) i)).valid);
    assert(a.full);
    assert(!a.push(OverlayRecord(node: 99)).valid, "refused, not asserted");
    assert(a.length == maxOverlays);

    // Depth is bounded independently of width.
    OverlayArena d;
    auto at = d.push(OverlayRecord(node: 0));
    size_t depth;
    foreach (i; 1 .. maxOverlays)
    {
        const next = d.push(OverlayRecord(parent: at, node: cast(uint) i));
        if (!next.valid)
            break;
        at = next;
        ++depth;
    }
    assert(depth + 1 <= maxOverlayDepth, "a cascade cannot outrun its bound");
}

@("ui.overlay.arena.hoistedByIsMembership")
@safe pure nothrow unittest
{
    OverlayArena empty;
    assert(!hoistedBy(empty, 12).any,
        "no overlays ⇒ nothing hoisted, and no allocation to find that out");
}

@("ui.overlay.arena.hoistedByFlagsExactlyTheEmittedNodes")
@safe unittest
{
    OverlayArena a;
    a.push(OverlayRecord(node: 3));
    a.push(OverlayRecord(node: 7));

    const flags = hoistedBy(a, 10);
    assert(flags[3] && flags[7]);
    assert(!flags[0] && !flags[4] && !flags[9]);
    assert(!flags[99], "out of range is in flow, not an error");
    assert(flags.any);
}

/**
The overlay pass (`PLC12`): resolve each record's anchor, solve its placement,
and move its subtree there — once per frame, inside the existing frame pass,
with $(B no observer machinery).

That last clause is the whole saving. Floating UI needs a three-method
measurement `Platform` and 264 lines of `autoUpdate` observers because it cannot
see the layout; here `layout()` $(I is) the measurement and the clip chain is
already threaded to every node, so the entire apparatus collapses to "recompute
between `layout` and the display list".

Call it after `layout(tree, hoistedBy(arena, tree.nodes.length))` and before
building the display list. `frames` is updated in place for the hoisted
subtrees; the returned arena carries each record's `resolved` geometry.

An anchor that no longer resolves yields `Fit.refused`, which withdraws the
record from paint and hits without removing it — deciding whether it should
$(I close) is dismissal's business, and dismissal is a separate stage.
*/
OverlayArena placeOverlays(in WidgetTree tree, scope Frame[] frames,
    OverlayArena arena, in Rect boundary)
in (frames.length == tree.nodes.length,
    "frames must be the layout of exactly this tree")
{
    OverlayArena solved = arena;
    foreach (i; 0 .. solved.length)
    {
        auto rec = &solved[i];
        if (rec.node >= tree.nodes.length)
        {
            rec.resolved = OverlayGeometry(fit: Fit.refused);
            continue;
        }

        // The producers a record's anchor kind needs, and only those: a rect
        // or spot anchor answers for itself, so neither walk runs for one.
        AnchorSource src;
        final switch (rec.anchor.kind)
        {
            case AnchorKind.key:
                src.keyed = rectOfKey(tree, frames, rec.anchor.key);
                break;
            case AnchorKind.textRange:
                src.range = clippedSelectionRects(tree, frames,
                    rec.anchor.srcLo, rec.anchor.srcHi);
                break;
            case AnchorKind.spot:
                src.boundary = boundary;
                break;
            case AnchorKind.rect:
            case AnchorKind.point:
                break;
        }

        const a = resolveAnchor(rec.anchor, src);
        if (!a.live)
        {
            // Gone, or ambiguous. Either way there is nothing to place against.
            rec.resolved = OverlayGeometry(fit: Fit.refused);
            continue;
        }

        const at = frames[rec.node].rect;
        rec.resolved = place(rec.placement, a, at.size, boundary);
        if (rec.resolved.paintable)
            translateSubtree(tree, rec.node,
                rec.resolved.rect.origin - at.origin, frames);
    }
    return solved;
}

@("ui.overlay.arena.placeOverlaysMovesTheSubtreeNotJustItsRoot")
@safe unittest
{
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // A host with a hoisted overlay carrying a child of its own. Moving only
    // the record's own node would leave the content behind at the origin —
    // painted, but somewhere else entirely.
    auto b = Builder();
    const label = b.add(Widget(kind: WidgetKind.text, text: "menu", key: 5));
    const item = b.add(Widget(kind: WidgetKind.text, text: "Open"));
    const card = b.add(Widget(kind: WidgetKind.panel, children: [item]));
    auto tree = b.finish(b.container(WidgetKind.column, [label, card]));

    OverlayArena a;
    a.push(OverlayRecord(node: card, anchor: Anchor.ofKey(5),
        life: Timeline(phase: Timeline.Phase.hold)));

    auto frames = layout(tree, hoistedBy(a, tree.nodes.length));
    const before = frames[item].rect.origin;
    const solved = placeOverlays(tree, frames, a, Rect(0, 0, 40, 12));

    const g = solved[0].resolved;
    assert(g.paintable && g.side == Side.bottom);
    assert(g.rect.y == 1, "it hangs below the one-row label it is keyed to");
    assert(frames[card].rect.origin == g.rect.origin);
    assert(frames[item].rect.origin == before + (g.rect.origin - Point(0, 0)),
        "the child moved with its parent");
    assert(frames[item].rect.y == g.rect.y, "and landed inside it");
}

@("ui.overlay.arena.aDeadAnchorIsRefusedRatherThanPlacedAtZero")
@safe unittest
{
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // The key names nothing in this tree. Placing against a default rect would
    // put the overlay at the origin, looking deliberate; refusing says so.
    auto b = Builder();
    const card = b.add(Widget(kind: WidgetKind.panel,
        children: [b.add(Widget(kind: WidgetKind.text, text: "x"))]));
    auto tree = b.finish(b.container(WidgetKind.column, [card]));

    OverlayArena a;
    a.push(OverlayRecord(node: card, anchor: Anchor.ofKey(404),
        life: Timeline(phase: Timeline.Phase.hold)));

    auto frames = layout(tree, hoistedBy(a, tree.nodes.length));
    const solved = placeOverlays(tree, frames, a, Rect(0, 0, 40, 12));
    assert(solved[0].resolved.fit == Fit.refused);
    assert(!solved[0].contributesPaint && !solved[0].contributesHits);
}

@("ui.overlay.arena.hitAtIsFrontToBack")
@safe pure nothrow @nogc unittest
{
    // Index order is paint order, so the FIRST thing hit is the LAST thing
    // painted. A forward scan here would hand a click to whatever is furthest
    // back — the exact inversion, and silent, because both find something.
    OverlayArena a;
    auto back = OverlayRecord(node: 1, life: Timeline(phase: Timeline.Phase.hold));
    back.resolved.rect = Rect(0, 0, 20, 10);
    const backId = a.push(back);

    auto front = OverlayRecord(node: 2, life: Timeline(phase: Timeline.Phase.hold));
    front.resolved.rect = Rect(4, 2, 6, 4);
    const frontId = a.push(front);

    assert(a.hitAt(Point(5, 3)) == frontId, "the overlap goes to the front one");
    assert(a.hitAt(Point(1, 1)) == backId, "outside it, to the one behind");
    assert(!a.hitAt(Point(99, 99)).valid);

    // A surface fading out is transparent to the pointer while still painted.
    a[1].life = Timeline(phase: Timeline.Phase.fadeOut);
    assert(a[1].contributesPaint && !a[1].contributesHits);
    assert(a.hitAt(Point(5, 3)) == backId, "the click falls through it");
}
