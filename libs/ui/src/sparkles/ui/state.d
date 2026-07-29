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
)
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
scrollbar's length in cells. Integer-exact: the thumb spans the whole track
when everything fits, never leaves it, and reaches the far end exactly at
`offset == content - viewport`.
*/
ThumbGeometry scrollbarThumb(long content, long viewport, long offset, int track)
    pure nothrow @nogc
{
    if (track <= 0)
        return ThumbGeometry(0, 0);
    if (content <= viewport || content <= 0)
        return ThumbGeometry(0, track); // everything visible: thumb = track

    auto extent = cast(int) (cast(long) track * viewport / content);
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

    /// Jumped so the thumb's leading edge lands at `trackPos` — the inverse
    /// mapping a click/drag on the scrollbar track needs.
    ScrollState draggedTo(int trackPos, long content, long viewport, int track) const
    {
        const limit = maxOffset(content, viewport);
        const thumb = scrollbarThumb(content, viewport, offset, track);
        const span = track - thumb.extent;
        if (span <= 0 || limit == 0)
            return ScrollState(0);
        auto p = trackPos < 0 ? 0 : (trackPos > span ? span : trackPos);
        return ScrollState(cast(long) p * limit / span);
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

// ── Selection (STM3) ─────────────────────────────────────────────────────────

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
