/**
The state level (STM) of $(MREF sparkles,ui): presentation-free interaction
state machines fed the shared `sparkles:input` events. U1 ships
$(LREF HoverState) — a pure hit-test over $(LREF HoverTarget)s that factors out
`runGuiTwoslash`'s ad-hoc `HoverHit[]` scan, so the GUI and the interactive TUI
overlay compute "which node is hot" identically. Scroll, selection, and
disclosure machines are later work.
*/
module sparkles.ui.state;

import sparkles.input : PointerAction, PointerEvent;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.layout : childClipOf, Frame, unclipped;
import sparkles.ui.widget : Visibility, WidgetTree;

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
