/**
$(B lantern) — hue's key guide: the framework machine bound to hue's table.

The machine itself — the pending path, the reveal delay, the panel's own keys
— lives in $(MREF sparkles,ui,lantern) (`LTN1`–`LTN12`), and takes the
binding table as a parameter. This module pins that parameter to
$(REF hueBindings, keymap), so every hue call site steps the guide through
one door and no site can pair the machine with a different table by accident.

The tests here are hue's $(I policy) through the machine — the fold family
descends and executes, the leader reaches three levels, a diff session
rebinds `z` — while the machine's own semantics (unbound vs consumed, the
delay clock, scroll clamping) are pinned beside the machine itself.
*/
module lantern;

import sparkles.input.events : KeyEvent;

import ui_lantern = sparkles.ui.lantern;
public import sparkles.ui.lantern : defaultDelay, LanternState, StepKind,
    tick, untilShown;

import keymap : Command, hueBindings, KeyContext;

/// The framework's step result with hue's command type.
alias LanternStep = ui_lantern.LanternStep!Command;

/// $(REF step, sparkles,ui,lantern) over $(REF hueBindings, keymap).
LanternStep step(ref LanternState s, in KeyEvent raw, in KeyContext ctx)
    @safe pure nothrow @nogc
    => ui_lantern.step(s, hueBindings, raw, ctx);

// ---------------------------------------------------------------------------
// Tests — hue's policy through the machine.
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : Duration, msecs;
    import sparkles.input.events : Key, Mods;
    import keymap : InputMode, KeyCommand;

    LanternStep ch(ref LanternState s, dchar c, KeyContext ctx = KeyContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => step(s, KeyEvent(Key.char_, c, m), ctx);
    LanternStep nk(ref LanternState s, Key k, KeyContext ctx = KeyContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => step(s, KeyEvent(k, 0, m), ctx);
}

@("lantern.prefixDescendsThenExecutes")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    // `z` names a group, so it descends rather than resolving to anything.
    assert(ch(s, 'z').kind == StepKind.descend);
    assert(s.active && s.pending.length == 1);
    // …and the next key resolves under it, ending the sequence.
    const r = ch(s, 'c');
    assert(r.kind == StepKind.execute && r.cmd.cmd == Command.foldClose);
    assert(!s.active, "a command ends the sequence");
}

@("lantern.unrecognisedKeyEndsTheSequenceWithoutRunning")
@safe pure nothrow @nogc
unittest
{
    // The old "an unrecognised key just disarms" behaviour, now stated once.
    LanternState s;
    assert(ch(s, 'z').kind == StepKind.descend);
    assert(ch(s, 'q').kind == StepKind.closed);
    assert(!s.active);

    // Crucially it does NOT fall through to `q`'s meaning at the root — the
    // key is spent ending the sequence, exactly as the fold block used to.
    LanternState t;
    assert(ch(t, 'j').kind == StepKind.execute, "…whereas at rest it resolves");
}

@("lantern.unboundKeysStaySeparateFromConsumedOnes")
@safe pure nothrow @nogc
unittest
{
    // `unbound` exists so a host can tell "the guide declined this" from "the
    // guide handled it and there is nothing to do". Collapsing the two would
    // silently eat every key hue has not bound.
    LanternState s;
    assert(ch(s, '!').kind == StepKind.unbound);
    assert(nk(s, Key.f5).kind == StepKind.unbound);
    assert(!s.active);
}

@("lantern.escapeAndBackspaceNavigateTheSequence")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    // Backspace steps back a level; from the last one it closes.
    assert(ch(s, ' ').kind == StepKind.descend);
    assert(ch(s, 'v').kind == StepKind.descend);
    assert(s.pending.length == 2);
    assert(nk(s, Key.backspace).kind == StepKind.descend);
    assert(s.pending.length == 1, "one level back, not all the way out");
    assert(nk(s, Key.backspace).kind == StepKind.closed);
    assert(!s.active);

    // Escape abandons the whole sequence from any depth.
    assert(ch(s, ' ').kind == StepKind.descend);
    assert(ch(s, 'v').kind == StepKind.descend);
    assert(nk(s, Key.escape).kind == StepKind.closed);
    assert(!s.active);

    // At rest, Backspace is not the guide's — the host keeps it.
    assert(nk(s, Key.backspace).kind == StepKind.unbound);
}

@("lantern.alwaysBindingsOutrankAPendingPrefix")
@safe pure nothrow @nogc
unittest
{
    // You can always leave fullscreen, even half-way through a sequence. The
    // previous `if` chain got this by testing F11 above the armed-fold block;
    // here it is the machine's step (1).
    LanternState s;
    assert(ch(s, 'z').kind == StepKind.descend);
    const r = nk(s, Key.f11);
    assert(r.kind == StepKind.execute && r.cmd.cmd == Command.toggleFullscreen);
    assert(s.active, "…and the sequence survives, as the frame counter did");
}

@("lantern.leaderReachesThreeLevels")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    assert(ch(s, ' ').kind == StepKind.descend);
    assert(ch(s, 'u').kind == StepKind.descend);
    const r = ch(s, 't');
    assert(r.kind == StepKind.execute && r.cmd.cmd == Command.themeNext);

    // The shifted sibling is a different binding at the same depth.
    LanternState t;
    ch(t, ' ');
    ch(t, 'u');
    const p = ch(t, 'T', KeyContext.init, Mods(shift: true));
    assert(p.kind == StepKind.execute && p.cmd.cmd == Command.themePrev);
}

@("lantern.foldLevelsCarryTheirArgument")
@safe pure nothrow @nogc
unittest
{
    // One ranged row, nine keys: `z3` must arrive as foldLevel(3).
    LanternState s;
    ch(s, 'z');
    assert(ch(s, '3').cmd == KeyCommand(Command.foldLevel, 3));

    LanternState t;
    ch(t, 'z');
    assert(ch(t, '9').cmd == KeyCommand(Command.foldLevel, 9));

    // …and there is no level 0, so the sequence ends without running.
    LanternState u;
    ch(u, 'z');
    assert(ch(u, '0').kind == StepKind.closed);
}

@("lantern.diffSessionRebindsTheFoldFamily")
@safe pure nothrow @nogc
unittest
{
    // `DVG3`: over a diff session the `z` family folds files, and the levels
    // are unbound rather than meaning something else — a flat file list has no
    // nesting for them to act on.
    const diff = KeyContext(hasDiffSession: true);

    LanternState s;
    ch(s, 'z', diff);
    assert(ch(s, 'c', diff).cmd.cmd == Command.diffToggleFile);

    LanternState t;
    ch(t, 'z', diff);
    assert(ch(t, 'm', diff).cmd.cmd == Command.diffCollapseAll);

    LanternState u;
    ch(u, 'z', diff);
    assert(ch(u, '3', diff).kind == StepKind.closed, "no levels over a file list");
}

@("lantern.panelWaitsForTheDelayThenShows")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    ch(s, 'z');
    assert(!s.shown, "a prefix does not open the panel by itself");

    tick(s, 100.msecs);
    assert(!s.shown, "…nor before the delay elapses");
    assert(untilShown(s) == 100.msecs, "the host can sleep exactly this long");

    tick(s, 100.msecs);
    assert(s.shown);
    assert(untilShown(s) == Duration.max, "nothing left to wait for");

    // Descending a level restarts the clock, so each step gets its own beat.
    LanternState t;
    ch(t, ' ');
    tick(t, 500.msecs);
    assert(t.shown);
    ch(t, 'v');
    assert(!t.shown && t.waited == Duration.zero);
}

@("lantern.explicitRequestOpensImmediately")
@safe pure nothrow @nogc
unittest
{
    // `<leader>?` is the "show me everything" door: no delay, and it leaves the
    // panel up rather than running a command — the table row's `reveal` flag,
    // consumed by the machine (`LTN11`).
    LanternState s;
    ch(s, ' ');
    assert(ch(s, '?').kind == StepKind.consumed);
    assert(s.shown, "shown at once, not after the delay");
    assert(!s.active, "…and at the root, so it lists everything");
}

@("lantern.inputModeKeepsTheGuideOutOfTheWay")
@safe pure nothrow @nogc
unittest
{
    // While a line editor owns the keyboard, a letter is text. The leader must
    // not open a menu in the middle of a search query.
    const typing = KeyContext(mode: InputMode.search);
    LanternState s;
    assert(ch(s, ' ', typing).kind == StepKind.unbound);
    assert(ch(s, 'z', typing).kind == StepKind.unbound);
    assert(!s.active);

    // Escape still cancels the editor rather than being swallowed as a
    // panel-close, because nothing is pending for it to close.
    assert(nk(s, Key.escape, typing).cmd.cmd == Command.inputCancel);
}
