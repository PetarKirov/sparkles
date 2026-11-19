/**
What an overlay is positioned against (`ANC1`–`ANC6`): the anchor a caller
asks for, and the anchor the frame resolves it to.

The two are different types (`ANC2`). An $(LREF Anchor) is a request — a
Regular value in integer cells, with no live handle, closure or lifetime
(`ANC1`) — and $(LREF resolveAnchor) never writes its answer back into it: the
answer is a $(LREF ResolvedAnchor), the rect $(REF place, sparkles,ui,overlay,place)
reads, with a verdict saying how much of the anchor the frame still shows.

A key anchor resolves through the same clip chain the display list scissors
with (`ANC3`), so a widget scrolled out of its viewport answers `hidden`
rather than a full rect, and one the frame no longer draws answers `gone` —
the distinction `keyTargets` cannot make, since it drops a fully clipped entry.
A point anchor is a 1×1 cell, never 0×0 (`ANC4`). Whether an anchor follows
what it names frame by frame is a field of the request (`ANC5`); whether it
still names anything is a set test over the frame's keyed targets (`ANC6`).
*/
module sparkles.ui.overlay.anchor;

import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.layout : childClipOf, Frame, unclipped;
import sparkles.ui.state : KeyTarget, selectionRects;
import sparkles.ui.widget : Visibility, WidgetTree;

/// What an $(LREF Anchor) names.
enum AnchorKind : ubyte
{
    rect,      /// a rect in the overlay's coordinate space
    key,       /// the widget whose `Widget.key` is `key`
    point,     /// one cell: a pointer or a caret
    textRange, /// source bytes `[textStart, textEnd)`: the first row they cover
    corner,    /// a corner cell of the surface
}

/// The corner a `corner` anchor names.
enum Corner : ubyte
{
    topLeft,     ///
    topRight,    ///
    bottomLeft,  ///
    bottomRight, ///
}

/**
Whether an anchor follows what it names (`ANC5`). A point or text anchor is
`latched` by default: it holds where it was when the overlay opened — at the
press on the TUI, which has no key release — rather than chasing a pointer.
A widget anchor is `live`: the tree is rebuilt every frame, and the anchor
re-resolves with it.
*/
enum Tracking : ubyte
{
    latched, /// resolved once; the caller keeps the resolution
    live,    /// resolved again every frame
}

/**
The anchor an overlay asks for: a closed sum over rect, key, point, text range
and corner, plus an optional rect to keep clear and a tracking policy
(`ANC1`). Build one with a named constructor; the fields a kind does not use
stay at `.init`.

A key anchor names a $(I domain-derived) key (`ANC6`): frame-to-frame
stability of a widget key is an authoring convention — every current
consumer derives it from a domain index — not a toolkit guarantee.
*/
struct Anchor
{
    AnchorKind kind;          ///
    Rect rect;                /// `rect`: the rect itself
    size_t key;               /// `key`: the widget key
    Point point;              /// `point`: the cell
    size_t textStart;         /// `textRange`: the first byte
    size_t textEnd;           /// `textRange`: one past the last byte
    Corner corner;            /// `corner`: which one
    Rect avoid;               /// a rect the overlay must keep clear; empty for none
    Tracking tracking;        ///

@safe pure nothrow @nogc:

    /// An anchor on a rect.
    static Anchor ofRect(in Rect r, Tracking tracking = Tracking.live)
        => Anchor(kind: AnchorKind.rect, rect: r, tracking: tracking);

    /// An anchor on the widget keyed `key`; live, since the tree is rebuilt.
    static Anchor ofKey(size_t key)
    in (key != 0, "key 0 names no widget")
        => Anchor(kind: AnchorKind.key, key: key, tracking: Tracking.live);

    /// An anchor on one cell; latched (`ANC5`).
    static Anchor atPoint(in Point p, Tracking tracking = Tracking.latched)
        => Anchor(kind: AnchorKind.point, point: p, tracking: tracking);

    /// An anchor on the first row source bytes `[start, end)` cover; latched.
    static Anchor ofText(size_t start, size_t end, Tracking tracking = Tracking.latched)
    in (start <= end)
        => Anchor(kind: AnchorKind.textRange, textStart: start, textEnd: end, tracking: tracking);

    /// An anchor on a corner cell of the surface.
    static Anchor atCorner(Corner c)
        => Anchor(kind: AnchorKind.corner, corner: c, tracking: Tracking.live);

    /// This anchor, keeping `r` clear.
    Anchor avoiding(in Rect r) const
    {
        Anchor a = this;
        a.avoid = r;
        return a;
    }
}

/// How much of a resolved anchor the frame shows.
enum AnchorVerdict : ubyte
{
    visible, /// all of it
    clipped, /// part of it: a scroll viewport or a clipping ancestor cuts it
    hidden,  /// none of it, but the frame still lays it out: scrolled away
    gone,    /// the frame does not draw it at all
}

/**
An anchor as one frame resolved it (`ANC2`): the rect placement reads, the
part of it the frame shows, and the verdict.

`rect` is the whole anchor even when it is clipped, since an overlay sits
against the widget rather than its visible sliver; `visible` is what the clip
chain leaves. Only `gone` has no rect.
*/
struct ResolvedAnchor
{
    Rect rect;                                 /// the whole anchor
    Rect visible;                              /// the part the frame shows
    AnchorVerdict verdict = AnchorVerdict.gone; ///
    Rect avoid;                                /// carried over from the request

@safe pure nothrow @nogc:

    /// Whether the anchor resolved to anything the frame lays out.
    bool opCast(T : bool)() const => verdict != AnchorVerdict.gone;

    /// Whether any of it is on screen.
    bool shown() const => verdict == AnchorVerdict.visible || verdict == AnchorVerdict.clipped;
}

/// A resolution of `r` against `clip`: visible, clipped or hidden.
private ResolvedAnchor seen(in Rect r, in Rect clip, in Rect avoid) @safe pure nothrow @nogc
{
    const v = r.intersection(clip);
    const verdict = v.empty ? AnchorVerdict.hidden
        : v == r ? AnchorVerdict.visible : AnchorVerdict.clipped;
    return ResolvedAnchor(r, v, verdict, avoid);
}

/// A corner cell of `surface`.
private Rect cornerCell(in Rect surface, Corner c) @safe pure nothrow @nogc
{
    const right = surface.width > 0 ? surface.right - 1 : surface.x;
    const bottom = surface.height > 0 ? surface.bottom - 1 : surface.y;
    final switch (c)
    {
        case Corner.topLeft: return Rect(surface.x, surface.y, 1, 1);
        case Corner.topRight: return Rect(right, surface.y, 1, 1);
        case Corner.bottomLeft: return Rect(surface.x, bottom, 1, 1);
        case Corner.bottomRight: return Rect(right, bottom, 1, 1);
    }
}

/**
The widget keyed `key` in a laid-out tree, through the clip chain the display
list scissors with (`ANC3`): `visible`, `clipped` or `hidden` while the frame
lays it out, `gone` when no drawn widget carries the key.
*/
ResolvedAnchor resolveKey(in WidgetTree tree, in Frame[] frames, size_t key) @safe pure nothrow @nogc
{
    ResolvedAnchor found;
    bool walk(uint idx, in Rect clip)
    {
        const node = &tree.nodes[idx];
        if (node.visibility == Visibility.collapsed)
            return false;
        const rect = frames[idx].rect;
        if (node.key == key)
        {
            found = node.visibility == Visibility.visible ? seen(rect, clip, Rect.init)
                : ResolvedAnchor(rect, Rect.init, AnchorVerdict.hidden);
            return true;
        }
        const childClip = childClipOf(*node, rect, clip);
        foreach (ci; node.children)
            if (walk(ci, childClip))
                return true;
        return false;
    }
    if (key != 0 && tree.nodes.length && frames.length == tree.nodes.length)
        walk(tree.root, unclipped());
    return found;
}

/**
`anchor` resolved against one laid-out frame: `surface` is the overlay's
coordinate space (the corners), `tree` and `frames` the content a key or text
anchor names. A rect or point anchor is visible wherever it lies inside
`surface`.
*/
ResolvedAnchor resolveAnchor(in Anchor anchor, in Rect surface,
    in WidgetTree tree = WidgetTree.init, in Frame[] frames = null) @safe
{
    ResolvedAnchor r;
    final switch (anchor.kind)
    {
        case AnchorKind.rect:
            r = seen(anchor.rect, surface, Rect.init);
            break;
        case AnchorKind.point:
            r = seen(Rect(anchor.point.x, anchor.point.y, 1, 1), surface, Rect.init);
            break;
        case AnchorKind.corner:
            r = surface.empty ? ResolvedAnchor.init : seen(cornerCell(surface, anchor.corner), surface, Rect.init);
            break;
        case AnchorKind.key:
            r = resolveKey(tree, frames, anchor.key);
            break;
        case AnchorKind.textRange:
            // `selectionRects` is clipped already, so a range scrolled away
            // leaves none: hidden or gone cannot be told apart here, and an
            // empty answer reads as hidden.
            const rows = tree.nodes.length && frames.length == tree.nodes.length
                ? selectionRects(tree, frames, anchor.textStart, anchor.textEnd) : null;
            if (!rows.length)
            {
                r = ResolvedAnchor(Rect.init, Rect.init, tree.nodes.length ? AnchorVerdict.hidden : AnchorVerdict.gone);
                break;
            }
            Rect first = rows[0];
            foreach (row; rows[1 .. $])
                if (row.y == first.y && row.x == first.right)
                    first.size.width += row.width;
            r = ResolvedAnchor(first, first, AnchorVerdict.visible);
            break;
    }
    r.avoid = anchor.avoid;
    return r;
}

/**
Whether `anchor` still names something the frame draws (`ANC6`): a set test
over the frame's keyed targets for a key anchor; every other kind names a
place rather than a widget and is always live.
*/
bool anchorLive(in Anchor anchor, in KeyTarget[] targets) @safe pure nothrow @nogc
{
    if (anchor.kind != AnchorKind.key)
        return true;
    foreach (t; targets)
        if (t.key == anchor.key)
            return true;
    return false;
}


/// A point anchor is one cell; the request is never written back (`ANC2`, `ANC4`).
@("overlay.anchor.pointIsOneCell")
@safe unittest
{
    const request = Anchor.atPoint(Point(3, 4));
    assert(request.tracking == Tracking.latched, "a point latches by default");
    const r = resolveAnchor(request, Rect(0, 0, 10, 10));
    assert(r.rect == Rect(3, 4, 1, 1) && r.verdict == AnchorVerdict.visible);
    assert(request.kind == AnchorKind.point && request.rect == Rect.init, "the request is unchanged");
    assert(resolveAnchor(Anchor.atPoint(Point(30, 4)), Rect(0, 0, 10, 10)).verdict == AnchorVerdict.hidden);
}

/// Corners are cells of the surface, whatever its origin.
@("overlay.anchor.corners")
@safe unittest
{
    const surface = Rect(-5, 2, 10, 4);
    assert(resolveAnchor(Anchor.atCorner(Corner.topLeft), surface).rect == Rect(-5, 2, 1, 1));
    assert(resolveAnchor(Anchor.atCorner(Corner.bottomRight), surface).rect == Rect(4, 5, 1, 1));
    assert(!resolveAnchor(Anchor.atCorner(Corner.topRight), Rect(0, 0, 0, 0)));
}

/// A keyed widget scrolled out of its viewport is hidden, not a full rect,
/// and a key the frame does not draw is gone (`ANC3`, `ANC6`).
@("overlay.anchor.keyThroughTheClipChain")
@safe unittest
{
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyTargets;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    Builder b;
    const a = b.add(Widget(kind: WidgetKind.text, text: "first", key: 11));
    const c = b.add(Widget(kind: WidgetKind.text, text: "second", key: 12));
    const d = b.add(Widget(kind: WidgetKind.text, text: "third", key: 13));
    const viewport = b.add(Widget(kind: WidgetKind.column, children: [a, c, d],
        height: SizeSpec.fixed(2), clipY: true));
    auto tree = b.finish(viewport);
    const frames = layout(tree);
    const surface = Rect(0, 0, 20, 10);

    const first = resolveAnchor(Anchor.ofKey(11), surface, tree, frames);
    assert(first.verdict == AnchorVerdict.visible && first.rect == frames[a].rect);
    const third = resolveAnchor(Anchor.ofKey(13), surface, tree, frames);
    assert(third.verdict == AnchorVerdict.hidden, "below the viewport: laid out, not shown");
    assert(third.rect == frames[d].rect, "the whole rect stays known");
    assert(resolveAnchor(Anchor.ofKey(99), surface, tree, frames).verdict == AnchorVerdict.gone);

    const targets = keyTargets(tree, frames);
    assert(anchorLive(Anchor.ofKey(11), targets));
    assert(!anchorLive(Anchor.ofKey(13), targets), "liveness is membership of the drawn set");
    assert(anchorLive(Anchor.atPoint(Point(0, 0)), targets));
}

/// The avoid rect travels from the request to the resolution.
@("overlay.anchor.avoidTravels")
@safe unittest
{
    const r = resolveAnchor(Anchor.ofRect(Rect(1, 1, 2, 1)).avoiding(Rect(0, 3, 5, 2)), Rect(0, 0, 9, 9));
    assert(r.avoid == Rect(0, 3, 5, 2) && r.shown);
}
