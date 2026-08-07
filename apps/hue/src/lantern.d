/**
$(B lantern) — hue's key guide (`LTN`), as a pure state machine.

Inspired by [which-key.nvim](https://github.com/folke/which-key.nvim): press a
prefix, wait a moment, and a panel lights up showing every key that can follow
it. The name is hue's own, and so is the mechanism — what is borrowed is the
$(I idea) that a keymap should be able to explain itself.

$(B What this module is.) The decision half: which chords are pending, whether
the panel is showing, and what a key does about it. No panel is drawn here —
that is a $(MREF sparkles,ui) widget tree built from
$(REF bindingsAt, keymap) — and no window, timer or frame loop is touched. The
whole machine is $(D @safe pure nothrow @nogc) over a
$(REF SmallBuffer, sparkles,base,smallbuffer) of at most
$(REF maxPathLength, keymap) chords, so it is checkable in a unittest exactly
like the keymap it drives.

$(B Why a machine rather than a flag.) hue already had a prefix — `z` — and it
was a `bool` in $(REF KeyContext, keymap) plus a 60-frame countdown in the GUI's
frame loop. That works for exactly one prefix, one level deep, on one backend
that happens to have frames. A leader key needs three levels, both backends, and
a delay measured in time rather than in frames; and the guide needs to know
$(I which) prefix is pending in order to have anything to show. All three fall
out of keeping the pending path here.

$(B The delay is the whole trick, and it is which-key's.) A prefix that opened
its panel instantly would punish anyone who already knows the keys; one that
never opened would not be a guide. So `zc` typed quickly closes a fold and shows
nothing, while `z` held for a beat lights the panel — the same keystrokes teach
or get out of the way depending only on how fast you are.
*/
module lantern;

import core.time : Duration, msecs, seconds;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input.events : Key, KeyEvent;

import keymap : Chord, Command, KeyCommand, KeyContext, ResolveKind,
    maxPathLength, matches, normalise, resolve, resolveAlways, ShiftReq;

@safe pure nothrow @nogc:

/// How long a prefix waits before the panel appears. which-key's default, and
/// for the same reason: long enough that a known sequence never sees it, short
/// enough that hesitating is answered.
enum defaultDelay = 200.msecs;

/**
The pending key path, and whether the panel is up.

Small enough to live beside the rest of a backend's view state, and copyable —
a test constructs one directly rather than driving a session to reach a state.
*/
struct LanternState
{
    /// The chords typed so far. Empty means no sequence is in flight.
    SmallBuffer!(Chord, maxPathLength) pending;
    /// Whether the panel is being shown. Set by $(LREF tick) once
    /// $(LREF LanternState.waited) reaches the delay, or immediately by an
    /// explicit request.
    bool shown;
    /// Time since the current prefix was entered.
    Duration waited;
    /// The panel's scroll offset in rows, for a binding set taller than it.
    int scroll;

    // A module-level attribute label does not reach inside an aggregate, so
    // the members carry their own.
@safe pure nothrow @nogc:

    /// Whether a sequence is in flight at all.
    bool active() const scope => pending.length > 0;

    /// Forgets the sequence and hides the panel.
    void reset()
    {
        pending.clear();
        shown = false;
        waited = Duration.zero;
        scroll = 0;
    }
}

/// What the host should do with the key it just handed over.
enum StepKind : ubyte
{
    /// Not bound here. The host may do whatever it would have done — this is
    /// how an unbound key stays unbound rather than being silently eaten.
    unbound,
    /// The guide took the key and there is nothing to run (a scroll, an
    /// explicit open).
    consumed,
    /// A prefix was entered; more keys are expected.
    descend,
    /// A command resolved. Run $(LREF LanternStep.cmd).
    execute,
    /// The sequence ended without a command — cancelled, or a key that names
    /// nothing under this prefix.
    closed,
}

/// ditto
struct LanternStep
{
    StepKind kind;
    KeyCommand cmd; /// meaningful when `kind == StepKind.execute`
}

/// Scrolls the panel, when it is showing and tall enough to need it.
private enum scrollStep = 5;

/**
Feeds one key to the guide.

Resolution order, and every step of it is load-bearing:

$(OL
    $(LI $(B Always-available bindings first.) Fullscreen and the platform
    dismiss key outrank a pending prefix, so a half-typed sequence can never
    trap you in a fullscreen window. This preserves exactly what the previous
    `if` chain did by testing F11 before the armed-fold block.)
    $(LI $(B The panel's own keys, while a sequence is in flight.) Escape
    abandons it, Backspace steps back one level, `Ctrl-D`/`Ctrl-U` scroll.
    These are which-key's, and they are only live while something is pending —
    Backspace at rest still belongs to whatever the host wants it for.)
    $(LI $(B Otherwise, the table.) A group descends, a command executes and
    ends the sequence, and anything else ends it without running — which is the
    old "an unrecognised key just disarms" behaviour, now stated once instead of
    per prefix.)
)
*/
LanternStep step(ref LanternState s, in KeyEvent raw, in KeyContext ctx)
{
    const k = normalise(raw);

    // (1) The always-available bindings outrank a pending prefix.
    if (s.active)
    {
        const a = resolveAlways(k, ctx);
        if (a.kind == ResolveKind.command)
            return LanternStep(StepKind.execute, KeyCommand(a.cmd, a.arg));
    }

    // (2) The panel's own keys, while a sequence is in flight.
    if (s.active)
    {
        if (k.key == Key.escape)
        {
            s.reset();
            return LanternStep(StepKind.closed);
        }
        if (k.key == Key.backspace)
        {
            s.pending.popBack();
            s.waited = Duration.zero;
            if (!s.active)
            {
                s.reset();
                return LanternStep(StepKind.closed);
            }
            return LanternStep(StepKind.descend);
        }
        if (s.shown && k.mods.ctrl && k.key == Key.char_)
        {
            if (k.ch == 'd')
            {
                s.scroll += scrollStep;
                return LanternStep(StepKind.consumed);
            }
            if (k.ch == 'u')
            {
                s.scroll -= scrollStep;
                if (s.scroll < 0)
                    s.scroll = 0;
                return LanternStep(StepKind.consumed);
            }
        }
    }

    // (3) The table.
    const r = resolve(s.pending[], k, ctx);
    final switch (r.kind)
    {
        case ResolveKind.group:
            s.pending ~= chordOf(k);
            s.waited = Duration.zero;
            s.shown = false;
            s.scroll = 0;
            return LanternStep(StepKind.descend);

        case ResolveKind.command:
            s.reset();
            if (r.cmd == Command.lanternAll)
            {
                s.shown = true;
                return LanternStep(StepKind.consumed);
            }
            return LanternStep(StepKind.execute, KeyCommand(r.cmd, r.arg));

        case ResolveKind.none:
            if (s.active)
            {
                s.reset();
                return LanternStep(StepKind.closed);
            }
            return LanternStep(StepKind.unbound);
    }
}

/**
Advances the delay clock.

Called once per frame (GUI) or per poll timeout (TUI) with however long has
passed. Only a pending sequence has a clock — at rest this does nothing, so a
host may call it unconditionally.
*/
void tick(ref LanternState s, Duration elapsed, Duration delay = defaultDelay)
{
    if (!s.active || s.shown)
        return;
    s.waited += elapsed;
    if (s.waited >= delay)
        s.shown = true;
}

/// How long until the panel would appear — what a TUI passes as its poll
/// timeout so the panel opens on time with no keystroke to wake it. `Duration.max`
/// when nothing is pending, i.e. block until a key arrives.
Duration untilShown(in LanternState s, Duration delay = defaultDelay)
{
    if (!s.active || s.shown)
        return Duration.max;
    return s.waited >= delay ? Duration.zero : delay - s.waited;
}

/// The chord a live event names, for pushing onto the pending path.
///
/// Shift is recorded as what was actually pressed — never `ignore`, which is a
/// table row's way of saying "don't care" and would be a lie about a keystroke.
/// $(REF acceptsTyped, keymap) is what reconciles the two directions.
private Chord chordOf(in KeyEvent k)
{
    Chord c;
    c.key = k.key;
    c.ch = k.key == Key.char_ ? k.ch : 0;
    c.shift = k.mods.shift ? ShiftReq.yes : ShiftReq.no;
    c.ctrl = k.mods.ctrl;
    c.alt = k.mods.alt;
    return c;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;

    LanternStep ch(ref LanternState s, dchar c, KeyContext ctx = KeyContext.init,
        Mods m = Mods())
        => step(s, KeyEvent(Key.char_, c, m), ctx);
    LanternStep nk(ref LanternState s, Key k, KeyContext ctx = KeyContext.init,
        Mods m = Mods())
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
    // here it is step (1).
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

@("lantern.tickIsInertAtRest")
@safe pure nothrow @nogc
unittest
{
    // A host calls this unconditionally every frame; it must cost nothing and
    // must never open a panel with no sequence behind it.
    LanternState s;
    tick(s, 10.seconds);
    assert(!s.shown && !s.active);
    assert(untilShown(s) == Duration.max, "…and never asks to be woken");
}

@("lantern.explicitRequestOpensImmediately")
@safe pure nothrow @nogc
unittest
{
    // `<leader>?` is the "show me everything" door: no delay, and it leaves the
    // panel up rather than running a command.
    LanternState s;
    ch(s, ' ');
    assert(ch(s, '?').kind == StepKind.consumed);
    assert(s.shown, "shown at once, not after the delay");
    assert(!s.active, "…and at the root, so it lists everything");
}

@("lantern.scrollingOnlyAppliesToAShownPanel")
@safe pure nothrow @nogc
unittest
{
    const ctrl = Mods(ctrl: true);
    LanternState s;
    ch(s, ' ');

    // Before the panel is up, Ctrl-D is not the guide's to take.
    assert(ch(s, 'd', KeyContext.init, ctrl).kind == StepKind.closed);

    LanternState t;
    ch(t, ' ');
    tick(t, 500.msecs);
    assert(ch(t, 'd', KeyContext.init, ctrl).kind == StepKind.consumed);
    assert(t.scroll == scrollStep && t.active, "scrolling keeps the sequence");
    ch(t, 'u', KeyContext.init, ctrl);
    assert(t.scroll == 0);
    ch(t, 'u', KeyContext.init, ctrl);
    assert(t.scroll == 0, "and never scrolls above the first row");
}

@("lantern.inputModeKeepsTheGuideOutOfTheWay")
@safe pure nothrow @nogc
unittest
{
    import keymap : InputMode;

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
