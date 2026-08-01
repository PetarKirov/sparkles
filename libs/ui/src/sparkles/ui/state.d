/**
The state level (STM) of $(MREF sparkles,ui): presentation-free interaction
state machines fed the shared `sparkles:input` events — pure logic over
abstract input, producing state and derived geometry in abstract units, with
no draw calls and no device units.

Every machine is a $(B Regular value) advanced by transformations
(`state.stepped(…) → state`; the caller assigns), never by mutating shared
locals — so behavior can be snapshotted, replayed and diffed in tests. And
every machine exists $(B once): where behavior was written per backend it
diverged (two scrollbar thumb formulas scrolling the same document
differently; one copy affordance flashing on a timer while another held until
the next event), which is precisely the "correctness does not compose" defect
this level removes.

$(LIST
    * $(LREF HoverState) + $(LREF hoverTargets) — which element is hot (`STM4`)
    * $(LREF scrollbarThumb) + $(LREF ScrollState) — one thumb formula (`STM2`)
    * $(LREF Selection) — normalized anchor/focus, no `-1` sentinel (`STM3`)
    * $(LREF DisclosureState) — one opened/closed set for tree expansion
        $(I and) content folding (`STM5`)
    * $(LREF Timeline) — transient effects as modes, not bare counters (`STM6`)
    * $(LREF FocusState) — keyboard focus + deterministic traversal (`STM7`)
    * $(LREF SplitState) — a draggable pane divider (`STM8`)
)
*/
module sparkles.ui.state;

import sparkles.base.term_control : PointerShape;
import sparkles.input : PointerAction, PointerEvent;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.layout : childClipOf, Frame, unclipped;
import sparkles.ui.widget : TextSpan, Visibility, WidgetKind, WidgetTree;

@safe:

/// A hit-testable region: the node's frame plus the id reported when the pointer
/// is over it. `hitId == 0` means "not hit-testable" and is never reported hot.
struct HoverTarget
{
    Rect rect;
    size_t hitId;
}

/**
Extracts the hit-testable regions of a laid-out tree, in paint order — the
topmost element comes last, matching $(LREF HoverState)'s later-wins rule — so
hit testing is computed $(B once) by the toolkit and every backend consumes the
result (`INP10`).

Invisible subtrees contribute nothing, and a clipping container clips its
descendants' targets through the same $(REF childClipOf, sparkles,ui,layout)
the display list scissors with — a token scrolled out of a viewport can
neither be painted nor be hot, by construction.
*/
HoverTarget[] hoverTargets(in WidgetTree tree, in Frame[] frames) pure nothrow
{
    HoverTarget[] targets;

    void walk(uint idx, in Rect clip)
    {
        const node = tree.nodes[idx];
        if (node.visibility != Visibility.visible)
            return;
        const rect = frames[idx].rect;
        if (node.hitId != 0)
        {
            const visible = rect.intersection(clip);
            if (!visible.empty)
                targets ~= HoverTarget(visible, node.hitId);
        }
        const childClip = childClipOf(node, rect, clip);
        foreach (ci; node.children)
            walk(ci, childClip);
    }

    walk(tree.root, unclipped());
    return targets;
}

/// Tracks which target is currently under the pointer. Backend-agnostic: the GUI
/// feeds it `GetMousePosition`, the TUI feeds it terminal mouse reports.
struct HoverState
{
@safe pure nothrow @nogc:

    /// The hot target's id (0 = nothing hot).
    size_t hot;

    /**
    Recomputes `hot` from `ev` against `targets` (topmost — latest in the slice —
    wins on overlap). A `PointerAction.leave` event makes nothing hot — that is
    how "the pointer left the viewport" is spelled in the shared vocabulary.
    Returns `true` iff `hot` changed (the caller's cue to repaint).
    */
    bool update(in PointerEvent ev, scope const HoverTarget[] targets)
    {
        const size_t previous = hot;
        size_t found;
        if (ev.action != PointerAction.leave)
            foreach (t; targets)
                if (t.hitId != 0 && t.rect.contains(ev.pos))
                    found = t.hitId; // later target wins → topmost
        hot = found;
        return hot != previous;
    }

    /// `true` iff `id` is the hot target (and non-zero).
    bool isHot(size_t id) const scope
        => id != 0 && id == hot;
}

@("ui.state.hover.topmostWinsAndChangeDetect")
@safe
unittest
{
    const targets = [
        HoverTarget(Rect(0, 0, 10, 3), 1),
        HoverTarget(Rect(2, 1, 4, 1), 2), // overlaps target 1, added later ⇒ topmost
    ];

    HoverState h;
    assert(h.hot == 0);

    // Over the overlap region: the later (topmost) target wins.
    assert(h.update(PointerEvent(action: PointerAction.move, pos: Point(3, 1)), targets));
    assert(h.hot == 2 && h.isHot(2) && !h.isHot(1));

    // Move to a region only target 1 covers.
    assert(h.update(PointerEvent(action: PointerAction.move, pos: Point(8, 0)), targets));
    assert(h.hot == 1);

    // No change ⇒ returns false.
    assert(!h.update(PointerEvent(action: PointerAction.move, pos: Point(9, 2)), targets));
    assert(h.hot == 1);

    // Pointer leaves the viewport ⇒ nothing hot.
    assert(h.update(PointerEvent(action: PointerAction.leave, pos: Point(3, 1)), targets));
    assert(h.hot == 0);
}

@("ui.state.hoverTargets.pipelineRoundTrip")
@safe unittest
{
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // A widget's hit identity survives the pipeline: two hover tokens in a
    // 2-row scrolled viewport — one visible, one scrolled out — plus a hidden
    // one. Only the visible token is hit-testable, and HoverState consumes
    // the result directly.
    auto b = Builder();
    const seen = b.add(Widget(kind: WidgetKind.text, text: "visible", hitId: 7));
    Widget hiddenW = Widget(kind: WidgetKind.text, text: "ghost", hitId: 8,
        visibility: Visibility.hidden);
    const hidden = b.add(hiddenW);
    const gone = b.add(Widget(kind: WidgetKind.text, text: "scrolled", hitId: 9));
    Widget viewW = Widget(kind: WidgetKind.column,
        children: [seen, hidden, gone],
        height: SizeSpec.fixed(2), clipY: true);
    const view = b.add(viewW);
    auto tree = b.finish(view);

    auto frames = layout(tree);
    const targets = hoverTargets(tree, frames);
    assert(targets.length == 1);
    assert(targets[0].hitId == 7);
    assert(targets[0].rect == Rect(0, 0, 7, 1));

    // The state machine's first real consumer: hover the visible token.
    HoverState h;
    assert(h.update(PointerEvent(action: PointerAction.move, pos: Point(2, 0)), targets));
    assert(h.isHot(7));
    // Row 2 belongs to the scrolled-out token — but it is clipped, so nothing.
    h.update(PointerEvent(action: PointerAction.move, pos: Point(2, 2)), targets);
    assert(h.hot == 0);
}

// ── Document rows (the identity channel, aggregated) ────────────────────────

/// One visual row of a laid-out document: its concatenated visible text (for
/// incremental search) and the source byte range its content came from (for
/// line-granular selection and copy) — `TextSpan.srcStart` aggregated per row.
struct DocRow
{
    const(char)[] text;
    size_t srcStart = size_t.max;
    size_t srcEnd;
}

/**
Aggregates a laid-out tree into per-visual-row text + source ranges: every
visible text/rich node contributes its (wrapped) lines at their frame rows.
Rows are indexed from the root's top; text appends in tree walk order (left to
right for a column-of-rows document). Synthetic spans (icons, bullets, guides)
carry no source identity and never widen a row's range.
*/
DocRow[] documentRows(in WidgetTree tree, in Frame[] frames)
{
    const total = frames.length ? frames[tree.root].rect.height : 0;
    auto rows = new DocRow[](total > 0 ? total : 0);

    void addText(int y, const(char)[] text, size_t srcStart, size_t srcEnd)
    {
        if (y < 0 || y >= cast(int) rows.length)
            return;
        rows[y].text ~= text;
        if (srcStart != size_t.max)
        {
            if (srcStart < rows[y].srcStart)
                rows[y].srcStart = srcStart;
            if (srcEnd > rows[y].srcEnd)
                rows[y].srcEnd = srcEnd;
        }
    }

    void walk(uint idx)
    {
        const node = tree.nodes[idx];
        if (node.visibility != Visibility.visible)
            return;
        // Text rows start inside the node's padding (display-list parity).
        const inner = frames[idx].rect.deflate(node.padding);
        final switch (node.kind) with (WidgetKind)
        {
            case text:
                if (frames[idx].lines.length)
                    foreach (li, ln; frames[idx].lines)
                        addText(inner.y + cast(int) li, ln, size_t.max, 0);
                else
                    addText(inner.y, node.text, size_t.max, 0);
                break;
            case rich:
                if (frames[idx].spanLines.length)
                {
                    foreach (li, line; frames[idx].spanLines)
                        foreach (ref const s; line)
                            addText(inner.y + cast(int) li, s.text,
                                s.srcStart, s.srcEnd);
                }
                else
                    foreach (ref const s; node.spans)
                        addText(inner.y, s.text, s.srcStart, s.srcEnd);
                break;
            case glyph, line, box:
                break;
            case row, column, stack, panel, popup:
                foreach (ci; node.children)
                    walk(ci);
                break;
        }
    }

    walk(tree.root);
    return rows;
}

/**
The char-precise inverse of the identity channel: the source byte offset of
the content cell at document coordinate `p`, or `-1` when nothing with source
identity is there. Mirrors the display list's span placement (padding inset,
one row per wrapped line, hang indent on continuations, one column per
codepoint), so a pointer hit on the painted glyph maps to the byte that
produced it — the shared hit-test for precise selection on every backend.
The topmost (latest-painted) content under the point wins.
*/
long sourceOffsetAt(in WidgetTree tree, in Frame[] frames, Point p)
{
    long found = -1;

    void checkRow(scope const TextSpan[] spans, int x, int y)
    {
        import sparkles.ui.geometry : cellsOf;

        if (y != p.y)
            return;
        foreach (ref const s; spans)
        {
            const w = cast(int) cellsOf(s.text);
            if (p.x >= x && p.x < x + w && s.srcStart != size_t.max)
            {
                // Column → byte: stride codepoints (the layout's own measure).
                import std.utf : stride;

                size_t o;
                foreach (_; 0 .. p.x - x)
                    o += stride(s.text[o .. $]);
                found = cast(long)(s.srcStart + o);
            }
            x += w;
        }
    }

    void walk(uint idx)
    {
        const node = tree.nodes[idx];
        if (node.visibility != Visibility.visible)
            return;
        const inner = frames[idx].rect.deflate(node.padding);
        if (node.kind == WidgetKind.rich)
        {
            if (frames[idx].spanLines.length)
                foreach (li, line; frames[idx].spanLines)
                    checkRow(line, inner.x + (li ? node.hangIndent : 0),
                        inner.y + cast(int) li);
            else
                checkRow(node.spans, inner.x, inner.y);
        }
        foreach (ci; node.children)
            walk(ci);
    }

    walk(tree.root);
    return found;
}

/**
Char-precise selection geometry: the 1-row cell rects covering source bytes
`[lo, hi)` in a laid-out tree — the paint side of the identity channel, one
rect per covered span segment per wrapped row (same placement rules as
$(LREF sourceOffsetAt)). Backends tint these; none re-derives byte→column.
*/
Rect[] selectionRects(in WidgetTree tree, in Frame[] frames,
    size_t lo, size_t hi)
{
    import sparkles.ui.geometry : cellsOf;

    Rect[] result;

    void checkRow(scope const TextSpan[] spans, int x, int y)
    {
        foreach (ref const s; spans)
        {
            const w = cast(int) cellsOf(s.text);
            if (s.srcStart != size_t.max && s.srcEnd > lo && s.srcStart < hi)
            {
                size_t bStart = lo > s.srcStart ? lo - s.srcStart : 0;
                size_t bEnd = (hi < s.srcEnd ? hi : s.srcEnd) - s.srcStart;
                if (bStart > s.text.length)
                    bStart = s.text.length;
                if (bEnd > s.text.length)
                    bEnd = s.text.length;
                if (bEnd > bStart)
                {
                    const c0 = cast(int) cellsOf(s.text[0 .. bStart]);
                    const c1 = cast(int) cellsOf(s.text[0 .. bEnd]);
                    if (c1 > c0)
                        result ~= Rect(x + c0, y, c1 - c0, 1);
                }
            }
            x += w;
        }
    }

    void walk(uint idx)
    {
        const node = tree.nodes[idx];
        if (node.visibility != Visibility.visible)
            return;
        const inner = frames[idx].rect.deflate(node.padding);
        if (node.kind == WidgetKind.rich)
        {
            if (frames[idx].spanLines.length)
                foreach (li, line; frames[idx].spanLines)
                    checkRow(line, inner.x + (li ? node.hangIndent : 0),
                        inner.y + cast(int) li);
            else
                checkRow(node.spans, inner.x, inner.y);
        }
        foreach (ci; node.children)
            walk(ci);
    }

    walk(tree.root);
    return result;
}

@("ui.state.selectionRects.charPrecise")
@safe unittest
{
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;
    import sparkles.ui.wrap : TextWrap;

    auto b = Builder();
    Widget para = Widget(kind: WidgetKind.rich, wrap: TextWrap.greedy, spans: [
        TextSpan("alpha beta", srcStart: 50, srcEnd: 60),
    ]);
    para.width.max = 5;
    const t = b.add(para);
    auto tree = b.finish(b.container(WidgetKind.column, [t]));
    auto frames = layout(tree);

    // Select "pha be" (bytes 52..58): tail of row 0, head of row 1.
    const rects = selectionRects(tree, frames, 52, 58);
    assert(rects.length == 2);
    assert(rects[0] == Rect(2, 0, 3, 1)); // "pha"
    assert(rects[1] == Rect(0, 1, 2, 1)); // "be"
}

/// A keyed node's identity + laid-out geometry (see $(LREF keyedRects)).
struct KeyedRect
{
    size_t key;
    Rect rect;
}

/// All keyed visible nodes' `(key, frame rect)` in paint order — the geometry
/// side of widget identity: a view stamps domain keys (e.g. source-anchored
/// table cells) and a backend resolves them back to document structure
/// without re-deriving the tree shape.
KeyedRect[] keyedRects(in WidgetTree tree, in Frame[] frames) pure nothrow
{
    KeyedRect[] result;

    void walk(uint idx)
    {
        const node = tree.nodes[idx];
        if (node.visibility != Visibility.visible)
            return;
        if (node.key != 0)
            result ~= KeyedRect(node.key, frames[idx].rect);
        foreach (ci; node.children)
            walk(ci);
    }

    walk(tree.root);
    return result;
}

@("ui.state.sourceOffsetAt.charPreciseThroughWrap")
@safe unittest
{
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;
    import sparkles.ui.wrap : TextWrap;

    // "alpha beta" wrapped at 7 → "alpha" / "beta"; identity at bytes 50..60.
    auto b = Builder();
    Widget para = Widget(kind: WidgetKind.rich, wrap: TextWrap.greedy, spans: [
        TextSpan("• ", noBreak: true),               // synthetic leader
        TextSpan("alpha beta", srcStart: 50, srcEnd: 60),
    ]);
    para.width.max = 7;
    para.hangIndent = 2;
    const t = b.add(para);
    auto tree = b.finish(b.container(WidgetKind.column, [t]));
    auto frames = layout(tree);

    assert(sourceOffsetAt(tree, frames, Point(0, 0)) == -1);      // the leader
    assert(sourceOffsetAt(tree, frames, Point(2, 0)) == 50);      // 'a'lpha
    assert(sourceOffsetAt(tree, frames, Point(4, 0)) == 52);      // al'p'ha
    assert(sourceOffsetAt(tree, frames, Point(2, 1)) == 56);      // 'b'eta (hang)
    assert(sourceOffsetAt(tree, frames, Point(1, 1)) == -1);      // hang gutter
    assert(sourceOffsetAt(tree, frames, Point(30, 0)) == -1);     // past the text
}

@("ui.state.documentRows.textAndSourceRanges")
@safe unittest
{
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;
    import sparkles.ui.wrap : TextWrap;

    // A wrapped rich paragraph with source identity + a synthetic leader.
    auto b = Builder();
    Widget para = Widget(kind: WidgetKind.rich, wrap: TextWrap.greedy, spans: [
        TextSpan("• ", noBreak: true),                    // synthetic
        TextSpan("alpha beta gamma", srcStart: 100, srcEnd: 116),
    ]);
    para.width.max = 9;
    const t = b.add(para);
    auto tree = b.finish(b.container(WidgetKind.column, [t]));
    auto frames = layout(tree);

    auto rows = documentRows(tree, frames);
    assert(rows.length >= 2);
    assert(rows[0].text == "• alpha" || rows[0].text == "• alpha ");
    assert(rows[0].srcStart == 100);           // the leader added no identity
    assert(rows[1].srcStart > 100 && rows[1].srcEnd <= 116);
}

// ── Scrollbar (STM2) ─────────────────────────────────────────────────────────

/// A scrollbar thumb's resolved geometry on its track, in abstract units.
struct ThumbGeometry
{
    int start;  /// offset of the thumb's leading edge within the track
    int extent; /// thumb length (≥ 1 whenever the track is non-empty)
}

/**
The one thumb formula (`STM2`) — every backend renders this; none owns its own.
`content`/`viewport` are in content units (lines, cells); `track` is the
scrollbar's length in the backend's track units — cells for the TUI, pixels
for the GUI, whose grabbable-minimum thumb is `minExtent` (1 cell vs ~24 px).
Integer-exact: the thumb spans the whole track when everything fits, never
leaves it, and reaches the far end exactly at `offset == content - viewport`.
*/
ThumbGeometry scrollbarThumb(long content, long viewport, long offset, int track,
    int minExtent = 1) pure nothrow @nogc
{
    if (track <= 0)
        return ThumbGeometry(0, 0);
    if (content <= viewport || content <= 0)
        return ThumbGeometry(0, track); // everything visible: thumb = track

    auto extent = cast(int) (cast(long) track * viewport / content);
    if (extent < minExtent)
        extent = minExtent;
    if (extent < 1)
        extent = 1;
    if (extent > track)
        extent = track;

    const maxOffset = content - viewport;
    auto clamped = offset < 0 ? 0 : (offset > maxOffset ? maxOffset : offset);
    const start = cast(int) (cast(long) (track - extent) * clamped / maxOffset);
    return ThumbGeometry(start, extent);
}

/**
Scroll position as a value (`STM2`): the offset of the first visible content
unit, advanced by transformations that clamp against `content`/`viewport` —
the caller assigns the result and reads `offset` back into `Widget.childOffset`.
*/
struct ScrollState
{
    long offset;

@safe pure nothrow @nogc:

    /// The largest valid offset for this content/viewport pair.
    static long maxOffset(long content, long viewport)
        => content > viewport ? content - viewport : 0;

    /// Scrolled by `delta` units (positive = towards the end), clamped.
    ScrollState scrolledBy(long delta, long content, long viewport) const
    {
        auto o = offset + delta;
        const limit = maxOffset(content, viewport);
        if (o < 0)
            o = 0;
        if (o > limit)
            o = limit;
        return ScrollState(o);
    }

    /// Jumped so the thumb's leading edge lands at `trackPos - grab` — the
    /// inverse mapping a click/drag on the scrollbar needs. `grab` is the
    /// pointer's offset within the thumb from $(LREF pressedAt), so a drag
    /// moves the thumb relative to where it was grabbed instead of snapping
    /// its leading edge under the pointer.
    ScrollState draggedTo(int trackPos, long content, long viewport,
        int track, int grab = 0, int minExtent = 1) const
    {
        const limit = maxOffset(content, viewport);
        const thumb = scrollbarThumb(content, viewport, offset, track,
            minExtent);
        const span = track - thumb.extent;
        if (span <= 0 || limit == 0)
            return ScrollState(0);
        const at = trackPos - grab;
        auto p = at < 0 ? 0 : (at > span ? span : at);
        return ScrollState(cast(long) p * limit / span);
    }

    /// A scrollbar press: $(B inside the thumb) it grabs in place — the
    /// state is unchanged and `grab` receives the pointer's offset within
    /// the thumb (a click on the handle must not move it); $(B on the
    /// track) it jumps the thumb's leading edge to the pointer (`grab` 0).
    ScrollState pressedAt(int trackPos, long content, long viewport,
        int track, out int grab, int minExtent = 1) const
    {
        const thumb = scrollbarThumb(content, viewport, offset, track,
            minExtent);
        if (trackPos >= thumb.start && trackPos < thumb.start + thumb.extent)
        {
            grab = trackPos - thumb.start;
            return this;
        }
        grab = 0;
        return draggedTo(trackPos, content, viewport, track,
            minExtent: minExtent);
    }
}

@("ui.state.scrollbarThumb.propertyWithinTrack")
@safe pure nothrow @nogc
unittest
{
    // At every (content, viewport, offset), the thumb stays within the track,
    // has extent ≥ 1, starts at 0 for offset 0, and ends flush at max offset.
    foreach (content; [1L, 5L, 40L, 1000L])
        foreach (viewport; [1L, 10L, 40L])
            foreach (track; [1, 3, 10, 25])
            {
                const limit = ScrollState.maxOffset(content, viewport);
                foreach (offset; [0L, 1L, limit / 2, limit])
                {
                    const t = scrollbarThumb(content, viewport, offset, track);
                    assert(t.extent >= 1 && t.extent <= track);
                    assert(t.start >= 0 && t.start + t.extent <= track);
                    if (offset == 0)
                        assert(t.start == 0);
                    if (offset == limit)
                        assert(t.start + t.extent == track); // flush at the end
                }
            }
}

@("ui.state.scrollState.clampAndDrag")
@safe pure nothrow @nogc
unittest
{
    // 100 lines in a 10-line viewport.
    auto s = ScrollState(0).scrolledBy(-5, 100, 10);
    assert(s.offset == 0);                       // clamped at the top
    s = s.scrolledBy(1000, 100, 10);
    assert(s.offset == 90);                      // clamped at the bottom
    // Dragging the thumb to the top / bottom of a 10-cell track.
    assert(s.draggedTo(0, 100, 10, 10).offset == 0);
    assert(ScrollState(0).draggedTo(10, 100, 10, 10).offset == 90);
}

@("ui.state.scrollState.thumbPressGrabsInPlace")
@safe pure nothrow @nogc
unittest
{
    // 40 units in a 10-unit viewport on a 10-cell track: thumb extent
    // 10*10/40 = 2, at offset 12 it starts at 12*8/30 = 3 → cells [3, 5).
    const s = ScrollState(12);
    int grab;

    // A press INSIDE the thumb grabs in place — the offset must not move.
    assert(s.pressedAt(4, 40, 10, 10, grab).offset == 12);
    assert(grab == 1);
    // The drag then moves the thumb relative to the grab point: one cell
    // down lands the leading edge at 4 → 4*30/8 = 15.
    assert(s.draggedTo(5, 40, 10, 10, grab).offset == 15);

    // A press on the TRACK jumps the leading edge to the pointer.
    assert(s.pressedAt(8, 40, 10, 10, grab).offset == 30);
    assert(grab == 0);
    assert(s.pressedAt(0, 40, 10, 10, grab).offset == 0);
}

// ── Selection (STM3) ─────────────────────────────────────────────────────────


/// Which way a scrollbar runs — the track coordinate's axis. Decides the
/// resize pointer shape and which pane extent the bar scrolls.
enum ScrollAxis : ubyte
{
    vertical,   /// the usual right-edge bar (`ns-resize`)
    horizontal, /// a bottom-edge bar for clipped-wide content (`ew-resize`)
}

/**
The whole scrollbar as one machine (`STM9`, `IXB1`): geometry (`STM2`),
the grab-relative interaction (a press on the handle grabs in place, on the
track jumps; drags move relative to the grab; the grab owns the pointer
until release), hover, and the wanted pointer shape — axis-aware, so a
vertical and a horizontal bar run the same logic in every backend.

Positions are track-relative units along the bar's axis (cells or px — the
machine is unit-agnostic like `SplitState`). External scrolls (wheel, keys)
keep the machine in sync by assigning `offset` through $(LREF scrolledTo).
*/
struct ScrollbarState
{
    ScrollAxis axis;
    long offset;   /// first visible content unit (the pane reads this back)
    bool dragging; /// a live grab owns the pointer until `released`
    bool hovered;  /// the pointer sits on the bar (hover chrome / shape)
    private int grab; // pointer offset within the grabbed thumb

@safe pure nothrow @nogc:

    /// A press at `trackPos`: on the thumb it grabs in place, on the track
    /// it jumps the leading edge there; either way the grab begins.
    ScrollbarState pressed(int trackPos, long content, long viewport,
        int track, int minExtent = 1) const
    {
        int g;
        const next = ScrollState(offset)
            .pressedAt(trackPos, content, viewport, track, g, minExtent);
        return ScrollbarState(axis, next.offset, true, hovered, g);
    }

    /// A drag while grabbed: the thumb follows relative to the grab point,
    /// wherever the pointer strays. A no-op unless dragging.
    ScrollbarState dragged(int trackPos, long content, long viewport,
        int track, int minExtent = 1) const
    {
        if (!dragging)
            return this;
        const next = ScrollState(offset)
            .draggedTo(trackPos, content, viewport, track, grab, minExtent);
        return ScrollbarState(axis, next.offset, true, hovered, grab);
    }

    /// Released: the offset stays, the grab ends.
    ScrollbarState released() const
        => ScrollbarState(axis, offset, false, hovered);

    /// Hover state from a hit test (the bar's own rect, backend-measured).
    ScrollbarState hoveredNow(bool over) const
        => ScrollbarState(axis, offset, dragging, over, grab);

    /// An external scroll (wheel, keys, a reveal) moved the pane.
    ScrollbarState scrolledTo(long offset_) const
        => ScrollbarState(axis, offset_, dragging, hovered, grab);

    /// The thumb for a `track`-unit-long bar (STM2's one formula).
    ThumbGeometry thumb(long content, long viewport, int track,
        int minExtent = 1) const
        => scrollbarThumb(content, viewport, offset, track, minExtent);

    /// The pointer shape this bar wants while hovered or grabbed: the
    /// resize shape along its axis; `default_` when idle. A live grab
    /// outranks hover — hosts re-assert it every drag (terminals may reset
    /// the pointer when a drag starts).
    PointerShape shape() const
        => dragging || hovered
            ? (axis == ScrollAxis.vertical
                ? PointerShape.nsResize : PointerShape.ewResize)
            : PointerShape.default_;
}

@("ui.state.scrollbarState.grabDragReleaseAndShape")
@safe pure nothrow @nogc
unittest
{
    // 40 units in a 10-unit viewport, 10-cell track: thumb [3, 5) at 12.
    auto sb = ScrollbarState(ScrollAxis.vertical, 12);
    assert(sb.shape == PointerShape.default_);

    // A press on the handle grabs in place; the drag moves grab-relative.
    sb = sb.pressed(4, 40, 10, 10);
    assert(sb.dragging && sb.offset == 12);
    assert(sb.shape == PointerShape.nsResize);
    sb = sb.dragged(5, 40, 10, 10);
    assert(sb.offset == 15);
    sb = sb.released();
    assert(!sb.dragging && sb.offset == 15);

    // A track press jumps the leading edge to the pointer.
    sb = sb.pressed(0, 40, 10, 10);
    assert(sb.offset == 0);
    sb = sb.released();

    // Drags without a grab are no-ops; a horizontal bar wants ew-resize.
    assert(sb.dragged(9, 40, 10, 10) == sb);
    auto hb = ScrollbarState(ScrollAxis.horizontal).hoveredNow(true);
    assert(hb.shape == PointerShape.ewResize);

    // External scrolls keep the machine in sync.
    assert(sb.scrolledTo(30).thumb(40, 10, 10).start == 8);
}

/**
The one pointer-shape decision (`IXB4`): what the terminal/window pointer
should look like given the workspace's interaction state. Live grabs
outrank hover — a divider drag holds `ew-resize` and a grabbed bar holds
its axis shape wherever the pointer strays — then divider hover, then any
hovered bar's shape. Pass the bars in priority order (horizontal before
vertical keeps `ew-resize` winning ties, matching both shipped hosts).

Every host consumes this ONE function: the TUI writes the result as
OSC 22 (re-asserting mid-grab — terminals may reset the pointer when a
drag starts), the GUI maps it to the window cursor.
*/
PointerShape wantedPointerShape(in SplitState split, bool overDivider,
    scope const(ScrollbarState)[] bars...) @safe pure nothrow @nogc
{
    if (split.dragging)
        return PointerShape.ewResize;
    foreach (ref const b; bars)
        if (b.dragging)
            return b.shape;
    if (overDivider)
        return PointerShape.ewResize;
    foreach (ref const b; bars)
        if (b.hovered)
            return b.shape;
    return PointerShape.default_;
}

@("ui.state.wantedPointerShape.priority")
@safe pure nothrow @nogc
unittest
{
    const idleV = ScrollbarState(ScrollAxis.vertical);
    const idleH = ScrollbarState(ScrollAxis.horizontal);
    const split = SplitState(32);

    assert(wantedPointerShape(split, false, idleH, idleV)
        == PointerShape.default_);
    // A live divider drag outranks everything.
    assert(wantedPointerShape(split.started(32), true,
        idleH.hoveredNow(true), idleV) == PointerShape.ewResize);
    // A grabbed bar outranks divider hover; its axis picks the shape.
    const grabbedV = idleV.pressed(0, 100, 10, 10);
    assert(wantedPointerShape(split, true, idleH, grabbedV)
        == PointerShape.nsResize);
    // Divider hover outranks bar hover; bar hover wins over idle.
    assert(wantedPointerShape(split, true, idleH.hoveredNow(true), idleV)
        == PointerShape.ewResize);
    assert(wantedPointerShape(split, false, idleH, idleV.hoveredNow(true))
        == PointerShape.nsResize);
}

/**
A selection as one Regular value (`STM3`): an `anchor` (where it started) and a
`focus` (where it is now) over any ordered position type — `long` line numbers,
byte offsets, or a comparable (line, column) pair. "No selection" is a $(B mode)
(`active == false`), not a `-1` sentinel, and `lo`/`hi` present the normalized
bounds so consumers never re-derive min/max.
*/
struct Selection(T)
{
    bool active;
    T anchor;
    T focus;

@safe pure nothrow @nogc:

    /// A selection started at `at` (anchor = focus; empty but active).
    static Selection started(T at) => Selection(true, at, at);

    /// This selection extended to `to` (starts one if inactive).
    Selection extended(T to) const
        => active ? Selection(true, anchor, to) : started(to);

    /// The empty, inactive selection.
    static Selection cleared() => Selection.init;

    /// Normalized bounds (`lo <= hi`); meaningful only while `active`.
    T lo() const => focus < anchor ? focus : anchor;
    /// ditto
    T hi() const => anchor < focus ? focus : anchor;

    /// `true` iff `pos` lies within the (inclusive) selected range.
    bool contains(T pos) const
        => active && !(pos < lo) && !(hi < pos);
}

@("ui.state.selection.anchorFocusNormalization")
@safe pure nothrow @nogc
unittest
{
    alias Sel = Selection!long;
    auto s = Sel.started(7);
    assert(s.active && s.lo == 7 && s.hi == 7 && s.contains(7));

    s = s.extended(3); // dragged upward: focus < anchor still normalizes
    assert(s.lo == 3 && s.hi == 7);
    assert(s.contains(3) && s.contains(5) && s.contains(7) && !s.contains(8));

    assert(!Sel.cleared.active);
    assert(!Sel.cleared.contains(0)); // inactive contains nothing
    // Extending an inactive selection starts one.
    assert(Sel.cleared.extended(4) == Sel.started(4));
}

// ── Disclosure (STM5) ────────────────────────────────────────────────────────

/**
One opened/collapsed machine (`STM5`) serving $(B both) tree expand/collapse
and content folding — the same question over different keys. The state is a
default polarity plus a sorted set of $(B exceptions), so a tree (default
closed, opening nodes) and a folded document (default open, closing regions)
share the machine, and "open all" / "close all" are O(1) resets rather than
enumerations.

Transformations return new values (the exception set is copied on change), so
the state is Regular: snapshot it, compare it, replay it.
*/
struct DisclosureState(Key)
{
    /// What a key not in `exceptions` is.
    bool defaultOpen;
    /// Sorted, unique keys that differ from the default.
    Key[] exceptions;

@safe pure nothrow:

    /// `true` iff `k` is open under the current polarity + exceptions.
    bool isOpen(in Key k) const @nogc
        => defaultOpen != inExceptions(k);

    /// This state with `k` toggled.
    DisclosureState toggled(Key k) const
        => DisclosureState(defaultOpen,
            inExceptions(k) ? without(k) : withKey(k));

    /// This state with `k` forced open / closed.
    DisclosureState opened(Key k) const
        => isOpen(k) ? DisclosureState(defaultOpen, exceptions.dup) : toggled(k);
    /// ditto
    DisclosureState closed(Key k) const
        => isOpen(k) ? toggled(k) : DisclosureState(defaultOpen, exceptions.dup);

    /// Everything open / everything closed (`zR` / `zM`): a polarity reset.
    static DisclosureState allOpen() => DisclosureState(true, null);
    /// ditto
    static DisclosureState allClosed() => DisclosureState(false, null);

    private bool inExceptions(in Key k) const @nogc
    {
        size_t lo = 0, hi = exceptions.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (exceptions[mid] < k)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < exceptions.length && !(k < exceptions[lo]) && !(exceptions[lo] < k);
    }

    private Key[] withKey(Key k) const
    {
        size_t lo = 0, hi = exceptions.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (exceptions[mid] < k)
                lo = mid + 1;
            else
                hi = mid;
        }
        auto result = new Key[](exceptions.length + 1);
        result[0 .. lo] = exceptions[0 .. lo];
        result[lo] = k;
        result[lo + 1 .. $] = exceptions[lo .. $];
        return result;
    }

    private Key[] without(in Key k) const
    {
        Key[] result;
        result.reserve(exceptions.length);
        foreach (e; exceptions)
            if (e < k || k < e)
                result ~= e;
        return result;
    }
}

@("ui.state.disclosure.servesTreeAndFolding")
@safe pure nothrow
unittest
{
    // A tree: default closed, the user opens nodes (keyed here by id).
    alias Tree = DisclosureState!int;
    auto t = Tree.allClosed;
    assert(!t.isOpen(3));
    t = t.toggled(3);
    assert(t.isOpen(3) && !t.isOpen(4));
    t = t.opened(5).opened(1);
    assert(t.exceptions == [1, 3, 5]); // sorted, unique
    t = t.closed(3);
    assert(!t.isOpen(3) && t.isOpen(1) && t.isOpen(5));

    // A folded document: default open, folds are closed regions (keyed by
    // source span start — any orderable key works).
    alias Folds = DisclosureState!size_t;
    auto f = Folds.allOpen;
    assert(f.isOpen(120));
    f = f.closed(120);
    assert(!f.isOpen(120) && f.isOpen(300));
    assert(Folds.allOpen.isOpen(120)); // zR: O(1) reset, not an enumeration

    // Regular: value copies compare and diverge independently.
    const snapshot = f;
    f = f.toggled(300);
    assert(snapshot != f && !snapshot.isOpen(120) && snapshot.isOpen(300));
}

// ── Timeline (STM6) ──────────────────────────────────────────────────────────

/**
Transient-effect timing as a mode machine (`STM6`): `idle → fadeIn → hold →
fadeOut → idle`, advanced by $(D stepped(dtMs, config)) — replacing the four
hand-decremented `float` timers in the GUI. A backend with no frame clock (the
event-driven TUI) collapses it without changing the caller: configure
`holdUntilDismissed` and call $(LREF Timeline.dismissed) on the next event.
*/
struct Timeline
{
    /// The phase of the effect.
    enum Phase : ubyte
    {
        idle,    /// not showing
        fadeIn,  /// appearing
        hold,    /// fully visible
        fadeOut, /// disappearing
    }

    /// Phase durations. `holdUntilDismissed` is the event-scoped mode: `hold`
    /// persists until $(LREF dismissed) — a mode, not a magic duration.
    static struct Config
    {
        int fadeInMs;
        int holdMs = 1200;
        int fadeOutMs;
        bool holdUntilDismissed;
    }

    Phase phase = Phase.idle;
    int elapsedMs;

@safe pure nothrow @nogc:

    /// A freshly-triggered effect (restarts if already running).
    static Timeline triggered(in Config cfg)
        => Timeline(cfg.fadeInMs > 0 ? Phase.fadeIn : Phase.hold, 0);

    /// Advanced by `dtMs` milliseconds.
    Timeline stepped(int dtMs, in Config cfg) const
    {
        auto t = Timeline(phase, elapsedMs + (dtMs > 0 ? dtMs : 0));
        for (;;)
        {
            const limit = t.phase == Phase.fadeIn ? cfg.fadeInMs
                : t.phase == Phase.hold ? (cfg.holdUntilDismissed ? int.max : cfg.holdMs)
                : t.phase == Phase.fadeOut ? cfg.fadeOutMs
                : int.max;
            if (t.phase == Phase.idle || t.elapsedMs < limit || limit == int.max)
                return t;
            const next = t.phase == Phase.fadeIn ? Phase.hold
                : t.phase == Phase.hold ? Phase.fadeOut : Phase.idle;
            t = Timeline(next, t.elapsedMs - limit);
        }
    }

    /// Dismissed by an event (the no-frame-clock collapse): holding ends now.
    Timeline dismissed(in Config cfg) const
        => phase == Phase.hold || phase == Phase.fadeIn
            ? Timeline(cfg.fadeOutMs > 0 ? Phase.fadeOut : Phase.idle, 0)
            : this;

    /// `true` while anything should be painted.
    bool visible() const => phase != Phase.idle;

    /// Opacity in percent (fades ramp linearly; `hold` is 100, `idle` 0).
    int alphaPercent(in Config cfg) const
    {
        final switch (phase) with (Phase)
        {
            case idle: return 0;
            case hold: return 100;
            case fadeIn:
                return cfg.fadeInMs <= 0 ? 100 : 100 * elapsedMs / cfg.fadeInMs;
            case fadeOut:
                return cfg.fadeOutMs <= 0 ? 0
                    : 100 - 100 * elapsedMs / cfg.fadeOutMs;
        }
    }
}

@("ui.state.timeline.timedFlash")
@safe pure nothrow @nogc
unittest
{
    // The GUI copy ✔: no fades, 1200 ms hold.
    const cfg = Timeline.Config();
    auto t = Timeline.triggered(cfg);
    assert(t.visible && t.phase == Timeline.Phase.hold && t.alphaPercent(cfg) == 100);
    t = t.stepped(1000, cfg);
    assert(t.visible);
    t = t.stepped(300, cfg); // 1300 ms total > 1200 hold, no fadeOut → idle
    assert(!t.visible && t.alphaPercent(cfg) == 0);
}

@("ui.state.timeline.eventScopedCollapse")
@safe pure nothrow @nogc
unittest
{
    // The TUI copy ✔: event-driven, no frame clock — hold until dismissed.
    const cfg = Timeline.Config(holdUntilDismissed: true);
    auto t = Timeline.triggered(cfg);
    t = t.stepped(1_000_000, cfg); // however long: still held
    assert(t.visible);
    t = t.dismissed(cfg); // the next event ends it
    assert(!t.visible);
}

@("ui.state.timeline.fadePhases")
@safe pure nothrow @nogc
unittest
{
    const cfg = Timeline.Config(fadeInMs: 100, holdMs: 200, fadeOutMs: 100);
    auto t = Timeline.triggered(cfg);
    assert(t.phase == Timeline.Phase.fadeIn && t.alphaPercent(cfg) == 0);
    t = t.stepped(50, cfg);
    assert(t.alphaPercent(cfg) == 50);
    t = t.stepped(100, cfg); // 50 ms into hold — carry crosses the boundary
    assert(t.phase == Timeline.Phase.hold && t.alphaPercent(cfg) == 100);
    t = t.stepped(200, cfg); // 50 ms into fadeOut
    assert(t.phase == Timeline.Phase.fadeOut && t.alphaPercent(cfg) == 50);
    t = t.stepped(60, cfg);
    assert(t.phase == Timeline.Phase.idle);
}

// ── Focus (STM7) ─────────────────────────────────────────────────────────────

/**
Keyboard focus as a value (`STM7`): which element (by hit identity) holds
focus, with traversal defined $(B once) over the caller-supplied order — the
same identity space as $(LREF hoverTargets), so a view's focus order is its
paint order unless it says otherwise. `0` means "nothing focused" (the same
"not addressable" convention as `hitId`).
*/
struct FocusState
{
    size_t focused;

@safe pure nothrow @nogc:

    /// `true` iff `id` (non-zero) holds focus.
    bool isFocused(size_t id) const
        => id != 0 && id == focused;

    /// Focus moved forward / backward through `order` (wrapping; focuses the
    /// first/last element when nothing is focused; empty order clears).
    FocusState next(scope const size_t[] order) const
        => moved(order, 1);
    /// ditto
    FocusState previous(scope const size_t[] order) const
        => moved(order, -1);

    /// Focus cleared.
    static FocusState cleared() => FocusState(0);

    private FocusState moved(scope const size_t[] order, int step) const
    {
        if (order.length == 0)
            return FocusState(0);
        ptrdiff_t at = -1;
        foreach (i, id; order)
            if (id == focused)
            {
                at = i;
                break;
            }
        const n = cast(ptrdiff_t) order.length;
        if (at < 0)
            return FocusState(order[step > 0 ? 0 : n - 1]);
        return FocusState(order[((at + step) % n + n) % n]);
    }
}

@("ui.state.focus.deterministicTraversal")
@safe pure nothrow @nogc
unittest
{
    static immutable size_t[] order = [7, 3, 9];
    auto f = FocusState.cleared;
    assert(!f.isFocused(7));
    f = f.next(order);
    assert(f.isFocused(7)); // nothing focused → first
    f = f.next(order);
    assert(f.isFocused(3));
    f = f.previous(order);
    assert(f.isFocused(7));
    f = f.previous(order); // wraps to the end
    assert(f.isFocused(9));
    assert(!FocusState.cleared.next(null).isFocused(7)); // empty order clears
}

// ── Pane splitter (STM8) ─────────────────────────────────────────────────────

/**
A draggable divider between two panes as a value (`STM8`): the leading
pane's size plus the drag in progress, advanced by transformations that
clamp against the host's `[minSize, maxSize]` — the workspace's
tree/document split, or any two-pane layout. Units are the caller's (cells
or pixels); the machine only does arithmetic on them, so both a cell grid
and a pixel canvas run the same drag.
*/
struct SplitState
{
    int size;      /// the leading pane's current size
    bool dragging;
    private int grabPos;  // pointer position at grab
    private int grabSize; // pane size at grab

@safe pure nothrow @nogc:

    /// Grabs the divider at pointer position `pos`.
    SplitState started(int pos) const
        => SplitState(size, true, pos, size);

    /// Dragged to pointer position `pos`: the pane resizes by the pointer's
    /// delta since the grab, clamped to `[minSize, maxSize]`. A no-op
    /// unless dragging — hosts can feed every motion event unconditionally.
    SplitState draggedTo(int pos, int minSize, int maxSize) const
    {
        if (!dragging)
            return this;
        auto s = grabSize + (pos - grabPos);
        if (s < minSize)
            s = minSize;
        if (s > maxSize)
            s = maxSize;
        return SplitState(s, true, grabPos, grabSize);
    }

    /// Released: the size stays, the drag ends.
    SplitState released() const => SplitState(size);

    /// Clamped into `[minSize, maxSize]` — e.g. after a window resize
    /// shrinks the space the pane may occupy.
    SplitState clamped(int minSize, int maxSize) const
    {
        auto s = size < minSize ? minSize : (size > maxSize ? maxSize : size);
        return SplitState(s, dragging, grabPos, grabSize);
    }
}

@("ui.state.split.dragClampAndRelease")
@safe pure nothrow @nogc
unittest
{
    // Grab at 32, drag right by 8, left past the minimum, release.
    auto sp = SplitState(32).started(32);
    assert(sp.dragging && sp.size == 32);
    sp = sp.draggedTo(40, 12, 60);
    assert(sp.size == 40);
    sp = sp.draggedTo(0, 12, 60);
    assert(sp.size == 12);          // clamped at the minimum
    sp = sp.draggedTo(100, 12, 60);
    assert(sp.size == 60);          // clamped at the maximum
    sp = sp.released();
    assert(!sp.dragging && sp.size == 60);

    // Not dragging ⇒ motion is a no-op; clamped() still applies bounds.
    assert(sp.draggedTo(5, 12, 60).size == 60);
    assert(sp.clamped(12, 40).size == 40);

    // The delta is grab-relative, so a grab away from the divider's exact
    // column drags without a jump.
    auto off = SplitState(32).started(33).draggedTo(41, 12, 60);
    assert(off.size == 40);
}

// ── Element state (WGT5) ─────────────────────────────────────────────────────

/**
Per-element state addressed by `Widget.key` (`WGT5`): scroll offsets, focus
and animation phase survive a view rebuild because $(B identity) — not
equality — decides which element is "the same one" across frames. Element
state lives here, never in the widget value, which is what keeps widget
equality total (and conflating the two is the classic reconciliation bug).

One store per state type; a view steps the state it `require`s and writes the
derived values (e.g. `ScrollState.offset` → `Widget.childOffset`) back into
the tree it builds. After a rebuild, $(LREF ElementStore.retain) sweeps state
whose element no longer exists.
*/
struct ElementStore(S)
{
    private size_t[] keys;
    private S[] states;

@safe:

    /// The state for `key`, created as `initial` on first sight. Returns a
    /// reference so the caller steps it in place.
    ref S require(size_t key, S initial = S.init) return
    {
        foreach (i, k; keys)
            if (k == key)
                return states[i];
        keys ~= key;
        states ~= initial;
        return states[$ - 1];
    }

    /// The state for `key`, or `null` when the element has none yet.
    inout(S)* find(size_t key) inout return
    {
        foreach (i, k; keys)
            if (k == key)
                return &states[i];
        return null;
    }

    /// Drops state whose key is not in `live` — call after a rebuild with the
    /// new tree's keys so vanished elements don't leak state (or resurrect it).
    void retain(scope const size_t[] live)
    {
        size_t kept;
        foreach (i, k; keys)
        {
            bool found;
            foreach (l; live)
                if (l == k)
                {
                    found = true;
                    break;
                }
            if (found)
            {
                keys[kept] = keys[i];
                states[kept] = states[i];
                kept++;
            }
        }
        keys = keys[0 .. kept];
        states = states[0 .. kept];
    }

    /// Number of live elements.
    size_t length() const pure nothrow @nogc => keys.length;
}

/// The keys present in `tree`, in arena order — `ElementStore.retain`'s input.
size_t[] elementKeys(in WidgetTree tree) pure nothrow
{
    size_t[] keys;
    foreach (ref node; tree.nodes)
        if (node.key != 0)
            keys ~= node.key;
    return keys;
}

@("ui.state.elementStore.identityCarriesStateAcrossRebuilds")
@safe unittest
{
    ElementStore!ScrollState store;

    // Frame 1: a scroll view keyed 42 scrolls down.
    store.require(42) = store.require(42).scrolledBy(7, 100, 10);
    assert(store.require(42).offset == 7);

    // Frame 2 (a rebuild): the same key finds the same state.
    assert(store.find(42) !is null && store.find(42).offset == 7);
    assert(store.find(99) is null);

    // The element vanishes from the tree: retain sweeps its state, so a later
    // element reusing the key starts fresh instead of resurrecting it.
    store.require(99);
    store.retain([99]);
    assert(store.length == 1 && store.find(42) is null);
    assert(store.require(42).offset == 0);
}

@("ui.state.elementKeys.collectsKeyedNodes")
@safe unittest
{
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    auto b = Builder();
    Widget viewport = Widget(kind: WidgetKind.column, key: 42, clipY: true);
    const v = b.add(viewport);
    const t = b.add(Widget(kind: WidgetKind.text, text: "anonymous"));
    const root = b.container(WidgetKind.column, [v, t]);
    auto tree = b.finish(root);

    assert(elementKeys(tree) == [42]); // key 0 nodes are anonymous
}
