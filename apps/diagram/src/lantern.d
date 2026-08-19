/**
$(B lantern) — the board's key guide: the framework machine bound to the
board's table.

The machine itself — the pending path, the reveal, the panel's own keys —
lives in $(MREF sparkles,ui,lantern) (`LTN1`–`LTN12`) and takes the binding
table as a parameter. This module pins that parameter to
$(REF diagramBindings, keymap), so every board call site steps the guide
through one door and no site can pair the machine with a different table by
accident.

$(B The board's table has no prefixes yet), so the delay clock has nothing to
time: `?` is a `reveal` row, which opens the panel outright, and the next
command closes it. $(REF tick, sparkles,ui,lantern) is re-exported anyway —
the moment a group row lands (a `z`-family for zoom, say), the host wires one
`wakeIn` and the descend path works with no change here.

The tests are the board's $(I policy) through the machine — `?` reveals, a
command closes, an unbound key leaves the panel alone — while the machine's
own semantics (the delay, scrolling, backspace) are pinned beside the machine.
*/
module lantern;

import sparkles.input.events : KeyEvent;

import ui_lantern = sparkles.ui.lantern;
public import sparkles.ui.lantern : defaultDelay, LanternState, StepKind, tick,
    untilShown;

import keymap : diagramBindings, DiagramCommand, DiagramContext;

/// The framework's step result with the board's command type.
alias LanternStep = ui_lantern.LanternStep!DiagramCommand;

/// $(REF step, sparkles,ui,lantern) over $(REF diagramBindings, keymap).
LanternStep step(ref LanternState s, in KeyEvent raw, in DiagramContext ctx)
    @safe pure nothrow @nogc
    => ui_lantern.step(s, diagramBindings, raw, ctx);

// ---------------------------------------------------------------------------
// Tests — the board's policy through the machine.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Key, Mods;

    LanternStep ch(ref LanternState s, dchar c,
        DiagramContext ctx = DiagramContext.init, Mods m = Mods())
        @safe pure nothrow @nogc
        => step(s, KeyEvent(Key.char_, c, m), ctx);
    LanternStep nk(ref LanternState s, Key k,
        DiagramContext ctx = DiagramContext.init, Mods m = Mods())
        @safe pure nothrow @nogc
        => step(s, KeyEvent(k, 0, m), ctx);
}

@("diagram.lantern.questionMarkRevealsWithoutRunningAnything")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    // A `reveal` row is consumed by the guide, never dispatched — which is
    // why `showGuide`'s arm in the input system is empty.
    const r = ch(s, '?');
    assert(r.kind == StepKind.consumed);
    assert(s.shown);
    assert(!s.active, "nothing is pending — the panel is at the root");
}

@("diagram.lantern.theNextCommandClosesThePanelAndRuns")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    cast(void) ch(s, '?');
    assert(s.shown);

    // Reading the guide and then acting on it is one keystroke, not two: the
    // key that resolves both closes the panel and does its job.
    const r = ch(s, 'v');
    assert(r.kind == StepKind.execute && r.cmd.cmd == DiagramCommand.toolSelect);
    assert(!s.shown);
}

@("diagram.lantern.anUnboundKeyLeavesTheGuideAlone")
@safe pure nothrow @nogc
unittest
{
    // `unbound` is the machine saying "do whatever you would have done" — the
    // host must not treat it as consumed, or a label edit could never type.
    LanternState s;
    assert(ch(s, 'z').kind == StepKind.unbound);

    cast(void) ch(s, '?');
    assert(ch(s, 'z').kind == StepKind.unbound);
    assert(s.shown, "an unbound key is not an answer, so the panel stays up");
}

@("diagram.lantern.aLabelEditNeverReachesTheGuide")
@safe pure nothrow @nogc
unittest
{
    // `?` is a board-scope row, and the edit scope is terminal — so typing a
    // question mark into a label types it (`IXN5`) instead of opening the
    // guide over the very text being edited.
    LanternState s;
    const editing = DiagramContext(isEditing: true);
    assert(ch(s, '?', editing).kind == StepKind.unbound);
    assert(!s.shown);
}

@("diagram.lantern.gridSettingsKeysStillResolveWhileTheGuideShows")
@safe pure nothrow @nogc
unittest
{
    // The guide is a panel, not a mode: the scopes underneath it resolve
    // exactly as they did, so the reader can act on what they just read.
    LanternState s;
    const open = DiagramContext(gridSettingsOpen: true);
    cast(void) ch(s, '?', open);
    const r = nk(s, Key.enter, open);
    assert(r.kind == StepKind.execute && r.cmd.cmd == DiagramCommand.gridApply);
    assert(!s.shown);
}
