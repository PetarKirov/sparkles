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

@safe:

/// A hit-testable region: the node's frame plus the id reported when the pointer
/// is over it. `hitId == 0` means "not hit-testable" and is never reported hot.
struct HoverTarget
{
    Rect rect;
    size_t hitId;
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
