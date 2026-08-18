/**
The State machines page: one tile per machine, each printing its own value.

The toolkit's interaction state is a set of Regular values advanced by
transformation — `state = state.stepped(…)`, never `state.mutate()`. That is
easy to say and hard to appreciate until you watch the values change: every
tile here shows the machine's current fields, so a press or a drag is visibly a
transition between two values rather than a side effect somewhere.

The two that repay attention are `PressState` and `CaptureState`. A press arms;
a release $(B over the same target) activates. A press owns the drag until it
ends. Both are one line to state and are the two things every hand-rolled
`if (clicked && inRect)` gets wrong.
*/
module pages.machines_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.state : CaptureState, DisclosureState, FocusState,
    PressState, ScrollState, Selection, Timeline;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import keymap : GalleryCommand;
import state : GalleryState, hitMachines, MachinesDemo;

@safe:

/// ditto
// The page's keys are `galleryBindings` rows in `GalleryScope.pageMachines`.

/// The focus order the `f` key walks — the same identity space `hoverTargets`
/// uses, so a view's focus order is its paint order unless it says otherwise.
private static immutable size_t[] focusOrder =
    [hitMachines + 1, hitMachines + 2, hitMachines + 3];

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const m = s.machines;

    uint[] body_;
    body_ ~= heading(b, "State · the interaction machines");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Every machine below is a plain value. Nothing here registers a "
        ~ "callback or mutates a shared flag, which is why a scripted event "
        ~ "list replayed through the headless host reproduces exactly what "
        ~ "your keystrokes produce.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "HoverState — topmost wins", [
        row(b, [
            tile(b, s, hitMachines + 1, "one"),
            tile(b, s, hitMachines + 2, "two"),
            tile(b, s, hitMachines + 3, "three"),
        ]),
        kv(b, "hot", s.hover.hot == 0 ? "nothing" : idName(s.hover.hot),
            14, Slot.chromeAccent),
        label(b, s.pointerAffordances
            ? "Move the pointer over a tile."
            : "This target has no pointer — the tiles stay cold.", Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "PressState — arm, then activate on the same target", [
        kv(b, "armed", s.press.armed == 0 ? "—" : idName(s.press.armed), 14),
        kv(b, "activated", s.press.activated == 0 ? "—" : idName(s.press.activated), 14),
        label(b, "Press one tile and release over another: nothing fires.",
            Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "FocusState — deterministic traversal", [
        kv(b, "focused", s.focus.focused == 0 ? "nothing" : idName(s.focus.focused), 14),
        row(b, [
            label(b, "order", Slot.muted),
            label(b, "one → two → three → (wrap)", Slot.code),
        ]),
        label(b, "Press f to advance, F to go back.", Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "Selection!int — anchor and focus, normalised", [
        kv(b, "active", m.selection.active ? "yes" : "no", 14),
        kv(b, "anchor / focus", text(m.selection.anchor, " / ", m.selection.focus), 14),
        kv(b, "lo … hi", text(m.selection.lo, " … ", m.selection.hi), 14),
        selectionStrip(b, m.selection),
        label(b, "a moves the anchor, e extends the focus. There is no "
            ~ "'no selection' sentinel — an empty range is empty.", Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "DisclosureState — a polarity plus exceptions", [
        kv(b, "default", m.folds.defaultOpen ? "open" : "closed", 14),
        kv(b, "exceptions", text(m.folds.exceptions.length, " keys"), 14),
        row(b, [
            label(b, "0…5", Slot.muted),
            b.add(Widget(
                kind: WidgetKind.row,
                children: discloseChips(b, m.folds),
                gap: 1,
            )),
        ]),
        label(b, "d toggles key 3; D flips the polarity. 'open all' is a "
            ~ "reset, not an enumeration.", Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "Timeline — a mode machine, not four timers", [
        kv(b, "phase", phaseName(m.pulse.phase), 14),
        kv(b, "elapsed", text(m.pulse.elapsedMs, " ms"), 14),
        kv(b, "alpha", text(m.pulse.alphaPercent(pulseConfig), " %"), 14),
        label(b, s.hasFrameClock
            ? "p triggers it; this target has a frame clock, so it times out."
            : "p triggers it; this target has no frame clock, so it holds "
            ~ "until the next event.", Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "CaptureState — press owns the drag", [
        kv(b, "owner", m.capture.isFree ? "free" : idName(ownerOf(m.capture)), 14),
        label(b, "Whatever the press landed on keeps every subsequent move "
            ~ "until the release, however far the pointer travels.", Slot.muted),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "ScrollState — clamped by transformation", [
        kv(b, "offset", s.demoView.v.offset.text, 14),
        kv(b, "max for this pane", ScrollState.maxOffset(200,
            s.contentHeight).text, 14),
        label(b, "This is the shell's own scroll offset — the page you are "
            ~ "reading is inside it.", Slot.muted),
    ]);

    return column(b, body_);
}

/// The pulse's timing. A visible fade on both ends, so the phases are
/// distinguishable rather than a flash.
enum Timeline.Config pulseConfig =
    Timeline.Config(fadeInMs: 200, holdMs: 800, fadeOutMs: 400);

private uint tile(ref Builder b, in GalleryState s, size_t id, string name)
{
    const hot = s.pointerAffordances && s.hover.isHot(id);
    const armed = s.press.isArmed(id);
    const focused = s.focus.isFocused(id);
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, focused ? "▸ " ~ name : "  " ~ name,
            armed || hot ? Slot.chromeAccent : Slot.code)],
        slot: armed ? Slot.chromeFocused : (hot ? Slot.selection : Slot.chip),
        width: SizeSpec.fixed(12),
        hitId: id,
        paintBackground: true,
    ));
}

/// Six cells, the selected range lit — a `Selection` is easier to read as a
/// picture than as two integers.
private uint selectionStrip(ref Builder b, in Selection!int sel)
{
    auto cells = new uint[](8);
    foreach (i; 0 .. 8)
        cells[i] = b.add(Widget(
            kind: WidgetKind.panel,
            children: [label(b, text(i),
                sel.contains(cast(int) i) ? Slot.chromeAccent : Slot.muted)],
            slot: sel.contains(cast(int) i) ? Slot.selection : Slot.chip,
            paintBackground: true,
            width: SizeSpec.fixed(3),
        ));
    return b.add(Widget(kind: WidgetKind.row, children: cells, gap: 1));
}

private uint[] discloseChips(ref Builder b, in DisclosureState!size_t d)
{
    auto chips = new uint[](6);
    foreach (i; 0 .. 6)
        chips[i] = chip(b, text(i), d.isOpen(i));
    return chips;
}

private string idName(size_t id)
{
    switch (id - hitMachines)
    {
        case 1: return "one";
        case 2: return "two";
        case 3: return "three";
        default: return text(id);
    }
}

private string phaseName(Timeline.Phase p)
{
    final switch (p) with (Timeline.Phase)
    {
        case idle: return "idle";
        case fadeIn: return "fadeIn";
        case hold: return "hold";
        case fadeOut: return "fadeOut";
    }
}

/// `CaptureState` reports freedom rather than an owner, so the page asks the
/// only question it can: which of the three tiles owns it.
private size_t ownerOf(in CaptureState c)
{
    foreach (id; focusOrder)
        if (c.ownedBy(id))
            return id;
    return 0;
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.machAnchor:
            // Anchor the selection one step along. `started` rather than a
            // struct literal: `active` is the first field, so a positional
            // construction would set the flag and leave the anchor at zero.
            s.machines.selection = Selection!int.started(
                (s.machines.selection.anchor + 1) % 8);
            return true;
        case GalleryCommand.machExtend:
            s.machines.selection = s.machines.selection.extended(
                (s.machines.selection.focus + 1) % 8);
            return true;
        case GalleryCommand.machFocusNext:
            s.focus = s.focus.next(focusOrder);
            return true;
        case GalleryCommand.machFocusPrev:
            s.focus = s.focus.previous(focusOrder);
            return true;
        case GalleryCommand.machFoldToggle:
            s.machines.folds = s.machines.folds.toggled(3);
            return true;
        case GalleryCommand.machFoldPolarity:
            s.machines.folds = s.machines.folds.defaultOpen
                ? typeof(s.machines.folds).allClosed
                : typeof(s.machines.folds).allOpen;
            return true;
        case GalleryCommand.machPulse:
            s.machines.pulse = Timeline.triggered(pulseConfig);
            return true;
        default:
            return false;
    }
}

version (unittest)
{
    import keymap : commandFor, GalleryContext, GalleryScope;

    // Tests drive the page exactly as the shell does: the key resolves in
    // the page's scope and the command dispatches above.
    private bool handleKey(ref GalleryState s, in KeyEvent k) @safe
    {
        const r = commandFor(k, GalleryContext(
            pageScope: GalleryScope.pageMachines, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }
}

/// ditto — a press on a tile focuses it, which is the affordance a pointer
/// target expects and the keyboard route already has.
bool handleActivate(ref GalleryState s, size_t id)
{
    foreach (candidate; focusOrder)
        if (candidate == id)
        {
            s.focus = FocusState(id);
            return true;
        }
    return false;
}

/// The page's animation: advanced by the shell, since only it has the clock.
void step(ref GalleryState s, int dtMs)
{
    if (s.machines.pulse.visible && dtMs > 0)
        s.machines.pulse = s.machines.pulse.stepped(dtMs, pulseConfig);
}

/// ditto — whether the page wants another frame.
bool animating(in GalleryState s) => s.machines.pulse.visible;

@("ui_gallery.pages.machinesFocusTraversalWrapsBothWays")
@safe unittest
{
    GalleryState s;
    assert(s.focus.focused == 0);

    handleKey(s, KeyEvent(Key.char_, 'f'));
    assert(s.focus.isFocused(focusOrder[0]), "nothing focused → the first");
    handleKey(s, KeyEvent(Key.char_, 'f'));
    handleKey(s, KeyEvent(Key.char_, 'f'));
    assert(s.focus.isFocused(focusOrder[2]));
    handleKey(s, KeyEvent(Key.char_, 'f'));
    assert(s.focus.isFocused(focusOrder[0]), "and wraps");

    handleKey(s, KeyEvent(Key.char_, 'F'));
    assert(s.focus.isFocused(focusOrder[2]), "backwards wraps too");
}

@("ui_gallery.pages.machinesSelectionIsNormalised")
@safe unittest
{
    // `lo`/`hi` are ordered whichever way the selection was dragged, which is
    // what lets `contains` be a single comparison and not four.
    GalleryState s;
    s.machines.selection = Selection!int.started(5).extended(2);
    assert(s.machines.selection.lo == 2 && s.machines.selection.hi == 5);
    assert(s.machines.selection.contains(3));
    assert(!s.machines.selection.contains(6));

    s.machines.selection = Selection!int.started(2).extended(5);
    assert(s.machines.selection.lo == 2 && s.machines.selection.hi == 5,
        "dragging the other way gives the same range");
}

@("ui_gallery.pages.machinesPulseRunsToIdle")
@safe unittest
{
    // Every phase is reachable and the machine returns to idle — a Timeline
    // that stuck in `hold` would keep the frame loop awake forever.
    GalleryState s;
    handleKey(s, KeyEvent(Key.char_, 'p'));
    assert(s.machines.pulse.phase == Timeline.Phase.fadeIn);
    assert(animating(s));

    bool[Timeline.Phase.max + 1] seen;
    foreach (_; 0 .. 200)
    {
        seen[s.machines.pulse.phase] = true;
        step(s, 16);
    }
    static foreach (m; __traits(allMembers, Timeline.Phase))
        assert(seen[__traits(getMember, Timeline.Phase, m)],
            "the pulse never reaches Timeline.Phase." ~ m);
    assert(!animating(s), "and stops asking for frames");
}

@("ui_gallery.pages.machinesDisclosureFlipIsAReset")
@safe unittest
{
    GalleryState s;
    handleKey(s, KeyEvent(Key.char_, 'd'));
    assert(s.machines.folds.isOpen(3));
    assert(s.machines.folds.exceptions.length == 1);

    // Flipping the polarity clears the exception list rather than inverting
    // every key — O(1) whatever the tree's size.
    handleKey(s, KeyEvent(Key.char_, 'D'));
    assert(s.machines.folds.defaultOpen);
    assert(s.machines.folds.exceptions.length == 0);
    foreach (i; 0 .. 6)
        assert(s.machines.folds.isOpen(i));
}

@("ui_gallery.pages.machinesTileActivationFocuses")
@safe unittest
{
    GalleryState s;
    assert(handleActivate(s, focusOrder[1]));
    assert(s.focus.isFocused(focusOrder[1]));
    assert(!handleActivate(s, 42), "an id this page did not mint is not its own");
}
