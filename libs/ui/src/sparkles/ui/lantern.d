/**
$(B lantern) — the key guide (`LTN`), as a pure state machine.

Inspired by [which-key.nvim](https://github.com/folke/which-key.nvim): press a
prefix, wait a moment, and a panel lights up showing every key that can follow
it. The name is sparkles' own, and so is the mechanism — what is borrowed is
the $(I idea) that a keymap should be able to explain itself.

$(B What this module is.) The decision half: which chords are pending, whether
the panel is showing, and what a key does about it. No panel is drawn here —
that is a widget tree built by
$(REF viewLantern, sparkles,ui,components,lantern_view) from
$(REF bindingsAt, sparkles,ui,keymap) — and no window, timer or frame loop is
touched. The whole machine is $(D @safe pure nothrow @nogc) over a
$(REF SmallBuffer, sparkles,base,smallbuffer) of at most
$(REF maxPathLength, sparkles,ui,keymap) chords, so it is checkable in a
unittest exactly like the keymap it drives.

$(B Why a machine rather than a flag.) A prefix held as a `bool` plus a
frame countdown works for exactly one prefix, one level deep, on one backend
that happens to have frames. A leader key needs three levels, every backend,
and a delay measured in time rather than in frames; and the guide needs to
know $(I which) prefix is pending in order to have anything to show. All
three fall out of keeping the pending path here.

$(B The delay is the whole trick, and it is which-key's.) A prefix that opened
its panel instantly would punish anyone who already knows the keys; one that
never opened would not be a guide. So `zc` typed quickly closes a fold and
shows nothing, while `z` held for a beat lights the panel — the same
keystrokes teach or get out of the way depending only on how fast you are.

$(B The table is the application's.) $(LREF step) takes it as a parameter,
the same way $(REF resolve, sparkles,ui,keymap) does; the row that opens the
panel outright is the one the table marks `reveal`, so "show me everything"
is table data rather than a command the machine has to know by name.
*/
module sparkles.ui.lantern;

import core.time : Duration, msecs;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input.events : Key, KeyEvent;

import sparkles.ui.keymap : Chord, KeyCommand, maxPathLength, normalise,
    ResolveKind, resolve, resolveAlways, ShiftReq;

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
    /// $(LREF LanternState.waited) reaches the delay, or immediately by a
    /// `reveal` row.
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
struct LanternStep(Cmd)
if (is(Cmd == enum))
{
    StepKind kind;
    KeyCommand!Cmd cmd; /// meaningful when `kind == StepKind.execute`
}

/// Scrolls the panel, when it is showing and tall enough to need it.
private enum scrollStep = 5;

private alias CmdOf(B) = typeof(B.init.cmd);

/**
Feeds one key to the guide.

Resolution order, and every step of it is load-bearing:

$(OL
    $(LI $(B Always-available bindings first) (`LTN10`). Fullscreen and the
    platform dismiss key outrank a pending prefix, so a half-typed sequence
    can never trap you in a fullscreen window.)
    $(LI $(B The panel's own keys, while a sequence is in flight) (`LTN9`).
    Escape abandons it, Backspace steps back one level, `Ctrl-D`/`Ctrl-U`
    scroll. These are which-key's, and they are only live while something is
    pending — Backspace at rest still belongs to whatever the host wants it
    for.)
    $(LI $(B Otherwise, the table.) A group descends, a command executes and
    ends the sequence — unless the row is marked `reveal`, which opens the
    panel at the root instead — and anything else ends it without running,
    stated once instead of per prefix.)
)
*/
LanternStep!(CmdOf!B) step(B, Ctx)(ref LanternState s, scope const(B)[] table,
    in KeyEvent raw, in Ctx ctx)
{
    alias Cmd = CmdOf!B;
    alias Step = LanternStep!Cmd;
    const k = normalise(raw);

    // (1) The always-available bindings outrank a pending prefix.
    if (s.active)
    {
        const a = resolveAlways(table, k, ctx);
        if (a.kind == ResolveKind.command)
            return Step(StepKind.execute, KeyCommand!Cmd(a.cmd, a.arg));
    }

    // (2) The panel's own keys, while a sequence is in flight.
    if (s.active)
    {
        if (k.key == Key.escape)
        {
            s.reset();
            return Step(StepKind.closed);
        }
        if (k.key == Key.backspace)
        {
            s.pending.popBack();
            s.waited = Duration.zero;
            if (!s.active)
            {
                s.reset();
                return Step(StepKind.closed);
            }
            return Step(StepKind.descend);
        }
        if (s.shown && k.mods.ctrl && k.key == Key.char_)
        {
            if (k.ch == 'd')
            {
                s.scroll += scrollStep;
                return Step(StepKind.consumed);
            }
            if (k.ch == 'u')
            {
                s.scroll -= scrollStep;
                if (s.scroll < 0)
                    s.scroll = 0;
                return Step(StepKind.consumed);
            }
        }
    }

    // (3) The table.
    const r = resolve(table, s.pending[], k, ctx);
    final switch (r.kind)
    {
        case ResolveKind.group:
            s.pending ~= chordOf(k);
            s.waited = Duration.zero;
            s.shown = false;
            s.scroll = 0;
            return Step(StepKind.descend);

        case ResolveKind.command:
            s.reset();
            if (r.reveal)
            {
                s.shown = true;
                return Step(StepKind.consumed);
            }
            return Step(StepKind.execute, KeyCommand!Cmd(r.cmd, r.arg));

        case ResolveKind.none:
            if (s.active)
            {
                s.reset();
                return Step(StepKind.closed);
            }
            return Step(StepKind.unbound);
    }
}

/**
Advances the delay clock.

Called once per frame (GUI) or per poll timeout (TUI) with however long has
passed. Only a pending sequence has a clock — at rest this does nothing, so a
host may call it unconditionally.
*/
void tick(ref LanternState s, Duration elapsed, Duration delay = defaultDelay)
    @safe pure nothrow @nogc
{
    if (!s.active || s.shown)
        return;
    s.waited += elapsed;
    if (s.waited >= delay)
        s.shown = true;
}

/// How long until the panel would appear — what a TUI passes as its poll
/// timeout so the panel opens on time with no keystroke to wake it (`LTN4`).
/// `Duration.max` when nothing is pending, i.e. block until a key arrives.
Duration untilShown(in LanternState s, Duration delay = defaultDelay)
    @safe pure nothrow @nogc
{
    if (!s.active || s.shown)
        return Duration.max;
    return s.waited >= delay ? Duration.zero : delay - s.waited;
}

/// The chord a live event names, for pushing onto the pending path.
///
/// Shift is recorded as what was actually pressed — never `ignore`, which is a
/// table row's way of saying "don't care" and would be a lie about a
/// keystroke. $(REF acceptsTyped, sparkles,ui,keymap) is what reconciles the
/// two directions.
private Chord chordOf(in KeyEvent k) @safe pure nothrow @nogc
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
// Tests — over the keymap module's miniature app. An application's own
// policy (which prefixes exist, what they lead to) is tested beside its
// table.
// ---------------------------------------------------------------------------

version (UiKeymapFixtures)
{
    import core.time : seconds;
    import sparkles.input.events : Mods;
    import sparkles.ui.keymap : TestBinding, testBindings, TestCommand,
        TestContext;

    LanternStep!TestCommand ch(ref LanternState s, dchar c,
        TestContext ctx = TestContext.init, Mods m = Mods())
        @safe pure nothrow @nogc
        => step(s, testBindings, KeyEvent(Key.char_, c, m), ctx);
    LanternStep!TestCommand nk(ref LanternState s, Key k,
        TestContext ctx = TestContext.init, Mods m = Mods())
        @safe pure nothrow @nogc
        => step(s, testBindings, KeyEvent(k, 0, m), ctx);
}

@("ui.lantern.prefixDescendsThenExecutes")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    // `z` names a group, so it descends rather than resolving to anything.
    assert(ch(s, 'z').kind == StepKind.descend);
    assert(s.active && s.pending.length == 1);
    // …and the next key resolves under it, ending the sequence.
    const r = ch(s, 'c');
    assert(r.kind == StepKind.execute && r.cmd.cmd == TestCommand.foldClose);
    assert(!s.active, "a command ends the sequence");

    // A ranged row carries its argument through the machine.
    LanternState t;
    ch(t, 'z');
    assert(ch(t, '3').cmd == KeyCommand!TestCommand(TestCommand.foldLevel, 3));
}

@("ui.lantern.unrecognisedKeyEndsTheSequenceWithoutRunning")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    assert(ch(s, 'z').kind == StepKind.descend);
    assert(ch(s, 'q').kind == StepKind.closed);
    assert(!s.active);

    // Crucially it does NOT fall through to the key's meaning at the root —
    // the key is spent ending the sequence.
    LanternState t;
    assert(ch(t, 'j').kind == StepKind.execute, "…whereas at rest it resolves");
}

@("ui.lantern.unboundKeysStaySeparateFromConsumedOnes")
@safe pure nothrow @nogc
unittest
{
    // `unbound` exists so a host can tell "the guide declined this" from "the
    // guide handled it and there is nothing to do". Collapsing the two would
    // silently eat every key the app has not bound.
    LanternState s;
    assert(ch(s, '!').kind == StepKind.unbound);
    assert(nk(s, Key.f5).kind == StepKind.unbound);
    assert(!s.active);
}

@("ui.lantern.escapeAndBackspaceNavigateTheSequence")
@safe pure nothrow @nogc
unittest
{
    LanternState s;
    // Backspace steps back a level; from the last one it closes. The fixture
    // has no two-level group, so descend once and step out.
    assert(ch(s, 'z').kind == StepKind.descend);
    assert(nk(s, Key.backspace).kind == StepKind.closed);
    assert(!s.active);

    // Escape abandons the whole sequence.
    assert(ch(s, 'z').kind == StepKind.descend);
    assert(nk(s, Key.escape).kind == StepKind.closed);
    assert(!s.active);

    // At rest, Backspace is not the guide's — the host keeps it.
    assert(nk(s, Key.backspace).kind == StepKind.unbound);
}

@("ui.lantern.alwaysBindingsOutrankAPendingPrefix")
@safe pure nothrow @nogc
unittest
{
    // You can always leave fullscreen, even half-way through a sequence —
    // the first-declared scope resolves before the panel's own keys.
    LanternState s;
    assert(ch(s, 'z').kind == StepKind.descend);
    const r = nk(s, Key.f11);
    assert(r.kind == StepKind.execute && r.cmd.cmd == TestCommand.leave);
    assert(s.active, "…and the sequence survives");
}

@("ui.lantern.panelWaitsForTheDelayThenShows")
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
}

@("ui.lantern.tickIsInertAtRest")
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

@("ui.lantern.revealRowOpensThePanelImmediately")
@safe pure nothrow @nogc
unittest
{
    // The "show me everything" door: no delay, and it leaves the panel up
    // rather than running a command — `Binding.reveal` as table data, not a
    // command the machine knows by name.
    LanternState s;
    assert(ch(s, '?').kind == StepKind.consumed);
    assert(s.shown, "shown at once, not after the delay");
    assert(!s.active, "…and at the root, so it lists everything");
}

@("ui.lantern.scrollingOnlyAppliesToAShownPanel")
@safe pure nothrow @nogc
unittest
{
    const ctrl = Mods(ctrl: true);
    LanternState s;
    ch(s, 'z');

    // Before the panel is up, Ctrl-D is not the guide's to take.
    assert(ch(s, 'd', TestContext.init, ctrl).kind == StepKind.closed);

    LanternState t;
    ch(t, 'z');
    tick(t, 500.msecs);
    assert(ch(t, 'd', TestContext.init, ctrl).kind == StepKind.consumed);
    assert(t.scroll == scrollStep && t.active, "scrolling keeps the sequence");
    ch(t, 'u', TestContext.init, ctrl);
    assert(t.scroll == 0);
    ch(t, 'u', TestContext.init, ctrl);
    assert(t.scroll == 0, "and never scrolls above the first row");
}

@("ui.lantern.inputModeKeepsTheGuideOutOfTheWay")
@safe pure nothrow @nogc
unittest
{
    // While a line editor owns the keyboard, a letter is text. A prefix must
    // not open a menu in the middle of a search query — the input scope is
    // terminal, so the machine reports the key unbound and the host keeps
    // typing with it.
    const typing = TestContext(typing: true);
    LanternState s;
    assert(ch(s, 'z', typing).kind == StepKind.unbound);
    assert(!s.active);

    // The editor's own keys still resolve through the input scope.
    assert(nk(s, Key.enter, typing).cmd.cmd == TestCommand.accept);
}
