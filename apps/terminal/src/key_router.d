/**
The one door every key goes through, on the desktop and on Android (`TKM1`,
`TKM4`, `TKM5`): the terminal's binding table, stepped through the toolkit's
lantern machine, and the guide panel that lists it.

A key comes out of $(LREF KeyRouter.route) as one of three answers — run a
command, swallow it (a prefix, a guide key), or hand it to the program — so a
component's `handle` never tests a key itself. The panel is painted from
`bindingsAt` over the same table, so what it lists is what the keys do.
*/
module key_router;

import core.time : Duration, msecs;

import sparkles.input.events : KeyAction, KeyEvent;
import sparkles.ui.lantern : LanternState;

import keymap : Binding, Chord, KeyCommand, KeysConfig, TermCommand, TermContext, TermScope;
import settings : TerminalConfig;

/// What to do with a key.
enum Route : ubyte
{
    /// Not the terminal's: encode it for the program (`TKM2`).
    program,
    /// The terminal took it (a prefix, the guide's own keys).
    consumed,
    /// Run `command`.
    execute,
}

/// ditto
struct Routed
{
    Route route;
    KeyCommand command;
}

/// The table in effect, the guide's state and its timing.
struct KeyRouter
{
    /// The merged table (`terminalBindings`).
    immutable(Binding)[] table;
    /// The leader chord in effect (`lantern.leader`).
    Chord leader;
    /// The pending path and whether the panel shows.
    LanternState lantern;
    /// How long a pending prefix waits before the panel shows (`lantern.delayMs`).
    Duration delay = 400.msecs;
    /// `lantern.enabled`: off, a prefix still works but the panel never shows
    /// on its own (an explicit `?` still opens it).
    bool guideEnabled = true;

    /**
    (Re)builds the table from the configuration: the leader, the `keys`
    overlay and the guide's timing (`TKM5`, `TKM8`). Problems land in
    `warnings`; the table is always usable.
    */
    void configure(TerminalConfig c, ref string[] warnings) @safe
    {
        import keymap : leaderChord, terminalBindings;

        leader = leaderChord(c.lantern.leader, warnings);
        table = terminalBindings(leader, c.keys, warnings);
        delay = c.lantern.delayMs.msecs;
        guideEnabled = c.lantern.enabled;
        lantern = LanternState.init;
    }

    /**
    Steps one key event. A release is the program's unless a sequence is
    pending (kitty's release reports must not be eaten mid-typing, `TPR16`).
    */
    Routed route(in KeyEvent k, in TermContext ctx) @safe
    {
        import sparkles.ui.lantern : step, StepKind;

        if (k.action == KeyAction.release)
            return Routed(lantern.active ? Route.consumed : Route.program);
        // At the root a key is the terminal's only when a row names it exactly:
        // the toolkit's matcher tolerates extra modifiers, but Ctrl+Alt+= is
        // the program's, not a sloppy Ctrl+= (`TKM2`).
        if (!lantern.active && !lantern.shown && !claimsExactly(k, ctx))
            return Routed(Route.program);
        const r = step(lantern, table, k, ctx);
        final switch (r.kind)
        {
            case StepKind.unbound:
                return Routed(Route.program);
            case StepKind.execute:
                return Routed(Route.execute, r.cmd);
            case StepKind.consumed:
            case StepKind.descend:
            case StepKind.closed:
                return Routed(Route.consumed);
        }
    }

    /// Whether a row reachable in `ctx` names `k` with exactly its modifiers.
    private bool claimsExactly(in KeyEvent raw, in TermContext ctx) const @safe pure nothrow @nogc
    {
        import sparkles.ui.keymap : normalise, ShiftReq;
        import sparkles.input.events : Key;

        const k = normalise(raw);
        foreach (ref row; table)
        {
            if (!ctx.reachable(row.scope_))
                continue;
            const c = row.path[0];
            if (c.key != k.key || c.ctrl != k.mods.ctrl || c.alt != k.mods.alt
                || c.super_ != k.mods.super_)
                continue;
            if ((c.shift == ShiftReq.yes && !k.mods.shift)
                || (c.shift == ShiftReq.no && k.mods.shift))
                continue;
            if (c.key != Key.char_
                || (c.chEnd ? k.ch >= c.ch && k.ch <= c.chEnd : k.ch == c.ch))
                return true;
        }
        return false;
    }

    /// Advances the guide's clock by a frame: a prefix pending for `delay`
    /// opens the panel (unless the guide is turned off).
    void tick(Duration elapsed) @safe pure nothrow @nogc
    {
        import sparkles.ui.lantern : tick;

        if (guideEnabled)
            tick(lantern, elapsed, delay);
    }

    /// How long until the panel would show — when to wake the loop; `max`
    /// when nothing is pending.
    Duration untilShown() const @safe pure nothrow @nogc
    {
        import sparkles.ui.lantern : untilShown;

        return guideEnabled ? untilShown(lantern, delay) : Duration.max;
    }

    /// Opens the guide at the root (the `MENU` extra key, `TKM7`).
    void openGuide() @safe pure nothrow @nogc
    {
        lantern = LanternState.init;
        lantern.shown = true;
    }

    /// Closes the guide and forgets any pending path.
    void closeGuide() @safe pure nothrow @nogc
    {
        lantern = LanternState.init;
    }
}

/**
Paints the guide panel along the bottom of a pane `cols` × `rows` cells whose
top-left pixel is (`x`, `y`), in the chrome colours derived from the
terminal's own foreground and background (D17, `THM7`). Nothing when the
panel is not shown or lists nothing.
*/
void paintGuide(H)(ref H h, ref KeyRouter router, in TermContext ctx, int cols,
    int rows, int x, int y, RgbColor fg, RgbColor bg) @system
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.base.term_color : Color;
    import sparkles.ui.components.lantern_view : BoxLayout, LabelArena, LanternStyle,
        Placement, viewLantern;
    import sparkles.ui.display_list : buildDisplayListInto;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.theme : Theme;
    import sparkles.ui.widget : Builder;
    import sparkles.ui_app.host : FrameOps;

    import keymap : bindingsAt;

    if (!router.lantern.shown || cols <= 0 || rows <= 0)
        return;
    SharedBuffer!(Binding, 64) listed;
    bindingsAt(listed, router.table, ctx, router.lantern.pending[]);
    if (listed.length == 0)
        return;

    static LabelArena labels;
    Builder b;
    BoxLayout box;
    const root = viewLantern(b, labels, listed[], router.lantern.pending.length, cols,
        box, Placement.classic, LanternStyle.init, 0, router.lantern.scroll);
    auto tree = b.finish(root);
    auto frames = layout(tree, Constraints(maxW: cols));
    const dy = rows - frames[tree.root].rect.height;

    const palette = Theme(defaultFg: Color.fromRgb(fg), defaultBg: Color.fromRgb(bg))
        .effectivePalette();
    static FrameOps ops;
    ops.reset();
    buildDisplayListInto(tree, frames, palette, fg, bg, ops);
    foreach (ref op; ops.ops[0 .. ops.length])
        op.translate(0, dy > 0 ? dy : 0);

    auto c = h.canvas;
    c.originX = x;
    c.originY = y;
    paint(c, ops[]);
}

import sparkles.base.term_color : RgbColor;

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

@("key_router.route.threeAnswers")
@safe unittest
{
    import sparkles.input.events : Key, Mods;

    KeyRouter r;
    string[] warnings;
    r.configure(TerminalConfig.init, warnings);
    assert(warnings.length == 0);

    // The program's key, the terminal's chord, and a release.
    assert(r.route(KeyEvent(Key.char_, 'x'), TermContext.init).route == Route.program);
    const copy = r.route(KeyEvent(Key.char_, 'c', Mods(ctrl: true, shift: true)),
        TermContext.init);
    assert(copy.route == Route.execute && copy.command.cmd == TermCommand.copy);
    KeyEvent up = KeyEvent(Key.char_, 'x');
    up.action = KeyAction.release;
    assert(r.route(up, TermContext.init).route == Route.program);

    // The leader is swallowed and leaves a pending prefix; the guide shows
    // only after the delay, and a path typed faster runs without it (`TKM5`).
    const lead = KeyEvent(Key.char_, ' ', Mods(ctrl: true, shift: true));
    assert(r.route(lead, TermContext.init).route == Route.consumed);
    assert(r.untilShown == 400.msecs);
    r.tick(399.msecs);
    assert(!r.lantern.shown);
    r.tick(1.msecs);
    assert(r.lantern.shown);
    const k = r.route(KeyEvent(Key.char_, 'k'), TermContext.init);
    assert(k.route == Route.execute && k.command.cmd == TermCommand.toggleExtraKeys);
    assert(!r.lantern.shown);
}

@("key_router.configure.guideOffAndDelayZero")
@safe unittest
{
    import sparkles.input.events : Key, Mods;

    TerminalConfig c;
    c.lantern.delayMs = 0;
    KeyRouter r;
    string[] warnings;
    r.configure(c, warnings);
    cast(void) r.route(KeyEvent(Key.char_, ' ', Mods(ctrl: true, shift: true)),
        TermContext.init);
    r.tick(Duration.zero);
    assert(r.lantern.shown, "a zero delay shows the guide at once");

    c.lantern.enabled = false;
    r.configure(c, warnings);
    cast(void) r.route(KeyEvent(Key.char_, ' ', Mods(ctrl: true, shift: true)),
        TermContext.init);
    r.tick(10_000.msecs);
    assert(!r.lantern.shown && r.lantern.active, "off: the prefix works, no panel");
}

@("key_router.route.everyUnclaimedKeyReachesTheProgram")
@safe unittest
{
    import std.traits : EnumMembers;

    import sparkles.input.events : Key, Mods;
    import sparkles.ui.keymap : normalise;

    // `TKM2`, swept: every named key and every printable ASCII character,
    // under every modifier combination, as a press — the table's own chords
    // and the leader aside, each one is routed to the program.
    KeyRouter r;
    string[] warnings;
    r.configure(TerminalConfig.init, warnings);
    size_t swept, claimed;
    void check(KeyEvent k)
    {
        r.closeGuide();
        const mine = r.route(k, TermContext.init).route != Route.program;
        r.closeGuide();
        if (mine)
        {
            claimed++;
            // Claimed means: exactly a row's chord, every modifier as written.
            const n = normalise(k);
            assert(!n.mods.alt && !n.mods.super_ && n.mods.ctrl,
                "only plain Ctrl and Ctrl+Shift chords are the terminal's");
        }
        swept++;
    }
    foreach (bits; 0 .. 16)
    {
        const m = Mods(ctrl: (bits & 1) != 0, shift: (bits & 2) != 0,
            alt: (bits & 4) != 0, super_: (bits & 8) != 0);
        foreach (key; EnumMembers!Key)
            if (key != Key.char_ && key != Key.none)
                check(KeyEvent(key, 0, m));
        foreach (dchar c; 0x20 .. 0x7F)
            check(KeyEvent(Key.char_, c, m));
    }
    // At most each one-key pane row (and the leader), spelled with and
    // without Shift where the row ignores it, or as an uppercase letter.
    size_t rootRows;
    foreach (ref row; r.table)
        rootRows += row.scope_ == TermScope.pane && row.path[0].ctrl;
    assert(claimed > 0 && claimed <= 2 * rootRows, "only the table's few chords are claimed");
    assert(swept > 1500);
}
