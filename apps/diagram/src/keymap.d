/**
The board's keyboard policy as $(B data) — one table, read both ways.

$(MREF systems,input)'s `onKey` was a ~140-line `if` chain testing `k.ch` twice
per binding (`'v' || 'V'`), with the modal layers expressed as early returns
before it: a label edit claimed the keyboard, grid settings claimed 1/2/3 and
the arrows, and everything else fell through to the board. The policy was
readable only by reading the chain, and nothing could enumerate it — so the
status row advertised keys by hand.

This module is the one declaration ($(REF Binding, sparkles,ui,keymap) rows
over the board's own command and scope enums): $(LREF commandFor) resolves a
key, $(LREF bindingsAt) enumerates what is reachable, and
$(MREF lantern) renders the second so the guide cannot disagree with the
first.

$(B Scopes are the modal layers.) Declaration order is precedence
(`docs/specs/ui/keymap.md` `KEY2`), which is exactly what the chain's
statement order used to mean:

$(UL
    $(LI $(LREF DiagramScope.edit) — a label edit owns the keyboard
    (`IXN5`). Marked $(REF terminalScope, sparkles,ui,keymap), so an unbound
    printable stops here rather than reaching the board's tool switches: it
    is text, and the dispatcher types it.)
    $(LI $(LREF DiagramScope.settings) — the settings pane (`SET2`). Terminal,
    unlike the three-fixture panel it replaced: a
    $(REF PropertyTree, sparkles,ui,property_tree) navigates with `j`/`k` and
    edits with `+`/`-`, and this board binds `d` to pan and `q` to quit, so a
    pane that let unbound keys through would pan the camera underneath itself
    and quit the application from a typo.)
    $(LI $(LREF DiagramScope.board) — the tools, the camera and the
    selection.)
)

$(B Shift is a binding property, not a duplicated row.)
$(REF normalise, sparkles,ui,keymap) folds `'V'` into `'v'` + Shift once, so
`chord('v')` covers both spellings and the table says nothing about case.
*/
module keymap;

import sparkles.input.events : Key, KeyEvent;
import ui_keymap = sparkles.ui.keymap;
public import sparkles.ui.keymap : Chord, chord, chordRange, hidesLaterScopes,
    maxPathLength, ModeReq, ResolveKind, ShiftReq, terminalScope;

/// The board's binding row, resolution result, and resolved command.
alias Binding = ui_keymap.Binding!(DiagramCommand, DiagramScope);
/// ditto
alias Resolution = ui_keymap.Resolution!DiagramCommand;
/// ditto
alias KeyCommand = ui_keymap.KeyCommand!DiagramCommand;

/**
What a key asks the board to do. `none` means "not bound here" — the
dispatcher needs no catch-all, and in a label edit it is what makes a
printable key text.

Names describe the $(I effect), not the key: `panUp` is `w`, the up arrow, and
whatever a future table binds to it.
*/
enum DiagramCommand : ubyte
{
    none,

    // The shell.
    quit,        /// `q` — bypasses the dismissal chain
    dismiss,     /// Esc / Back — walks the chain (`IXN6`)
    showGuide,   /// `?` — the key guide (`LTN`); the guide consumes it

    // Tools (`IXN2`).
    toolSelect, toolRect, toolConnect,

    // The camera (`IXN3`).
    fitAll, zoomReset, zoomIn, zoomOut,
    panUp, panDown, panLeft, panRight,
    panArm,      /// Space — hold to pan where releases exist, sticky where not

    // The world.
    toggleMinimap,
    groupSelection, ungroupSelection,
    deleteSelection,

    // The label edit (`IXN5`).
    editCommit, editCancel, editErase,

    // The settings pane (`SET`). Navigation and editing are the property
    // tree's own named verbs (`PRT23`): the component supplies them, this
    // table decides which keys reach them.
    settingsOpen,      /// `,` on the board
    settingsClose,
    settingsUp, settingsDown, settingsPageUp, settingsPageDown,
    settingsHome, settingsEnd,
    settingsCollapse, settingsExpand, settingsActivate,
    settingsDec, settingsInc,
    settingsPreview,   /// `v` — one history entry per drag (`PRT19`)
    settingsUndo, settingsRedo, settingsReset,
    settingsFilter, settingsMatchNext, settingsMatchPrev, settingsReveal,
    settingsSave,
    gridPreset,        /// `1`–`3` — the ranged arg names the fixture
}

/**
Which surface a binding belongs to — and, by declaration order, when it
resolves.

`always` is empty, as it is in the gallery: it exists because the framework
reads the first-declared scope for the keys that outrank a pending prefix
($(REF resolveAlways, sparkles,ui,keymap), `LTN10`).
*/
enum DiagramScope : ubyte
{
    /// resolves in every context, even mid-sequence; empty today
    always,
    /// a label edit: modal, and it swallows what it does not answer
    @terminalScope @hidesLaterScopes edit,
    /// the settings pane: modal, and it swallows what it does not answer
    @terminalScope @hidesLaterScopes settings,
    /// the board itself — tools, camera, selection
    board,
}

/**
Everything outside the key that changes what it means, plus the framework's
context hooks.

The two modal facts the chain used to test by early return. `editing` is both
a scope gate and the framework's $(REF ModeReq, sparkles,ui,keymap) hook, so a
row could be written "only while typing" without naming the scope.
*/
struct DiagramContext
{
    bool isEditing;      /// a label edit is open (`World.isEditing`)
    bool settingsOpen;   /// the settings pane shows (`World.settingsOpen`)

@safe pure nothrow @nogc const:

    bool reachable(DiagramScope s)
    {
        final switch (s) with (DiagramScope)
        {
            case always: return true;
            case edit: return isEditing;
            case settings: return settingsOpen;
            case board: return !isEditing && !settingsOpen;
        }
    }

    /// The `ModeReq` hook: a line editor owns the keyboard.
    bool editing() => isEditing;
}

/// The framework's row builder with the board's types pinned.
private alias bind = ui_keymap.bind;

/**
The board's keyboard policy. Rows are grouped by scope; within a scope the
keys are disjoint, so order never decides an outcome here.
*/
immutable Binding[] diagramBindings = [
    // ── a label edit owns the keyboard (`IXN5`) ──────────────────────────
    bind(DiagramScope.edit, chord(Key.enter), DiagramCommand.editCommit,
        "commit label"),
    bind(DiagramScope.edit, chord(Key.escape), DiagramCommand.editCancel,
        "cancel label"),
    bind(DiagramScope.edit, chord(Key.back), DiagramCommand.editCancel,
        "cancel label"),
    bind(DiagramScope.edit, chord(Key.backspace), DiagramCommand.editErase,
        "erase"),

    // ── the settings pane, while open (`SET2`) ───────────────────────────
    // Both spellings of every move, because this pane is the one surface a
    // reader may meet with either a vi hand or an arrow hand.
    bind(DiagramScope.settings, chord(Key.escape),
        DiagramCommand.settingsClose, "close"),
    bind(DiagramScope.settings, chord(Key.back),
        DiagramCommand.settingsClose, "close"),
    bind(DiagramScope.settings, chord('j'), DiagramCommand.settingsDown, "down"),
    bind(DiagramScope.settings, chord(Key.down), DiagramCommand.settingsDown, "down"),
    bind(DiagramScope.settings, chord('k'), DiagramCommand.settingsUp, "up"),
    bind(DiagramScope.settings, chord(Key.up), DiagramCommand.settingsUp, "up"),
    bind(DiagramScope.settings, chord(Key.pageDown),
        DiagramCommand.settingsPageDown, "page down"),
    bind(DiagramScope.settings, chord(Key.pageUp),
        DiagramCommand.settingsPageUp, "page up"),
    bind(DiagramScope.settings, chord(Key.home), DiagramCommand.settingsHome, "first row"),
    bind(DiagramScope.settings, chord(Key.end), DiagramCommand.settingsEnd, "last row"),
    bind(DiagramScope.settings, chord('h'), DiagramCommand.settingsCollapse, "collapse"),
    bind(DiagramScope.settings, chord(Key.left), DiagramCommand.settingsCollapse, "collapse"),
    bind(DiagramScope.settings, chord('l'), DiagramCommand.settingsExpand, "expand"),
    bind(DiagramScope.settings, chord(Key.right), DiagramCommand.settingsExpand, "expand"),
    bind(DiagramScope.settings, chord(Key.enter),
        DiagramCommand.settingsActivate, "open / toggle"),
    // `+`/`-` and their unshifted spellings, exactly as the board's zoom does.
    bind(DiagramScope.settings, chord('+'), DiagramCommand.settingsInc, "next value"),
    bind(DiagramScope.settings, chord('='), DiagramCommand.settingsInc, "next value"),
    bind(DiagramScope.settings, chord('-'), DiagramCommand.settingsDec, "previous value"),
    bind(DiagramScope.settings, chord('_'), DiagramCommand.settingsDec, "previous value"),
    bind(DiagramScope.settings, chord('v'), DiagramCommand.settingsPreview,
        "preview drag"),
    bind(DiagramScope.settings, chord('u'), DiagramCommand.settingsUndo, "undo"),
    bind(DiagramScope.settings, Chord(key: Key.char_, ch: 'r', ctrl: true),
        DiagramCommand.settingsRedo, "redo"),
    bind(DiagramScope.settings, chord('r'), DiagramCommand.settingsReset,
        "reset to default"),
    bind(DiagramScope.settings, chord('/'), DiagramCommand.settingsFilter, "filter"),
    bind(DiagramScope.settings, chord('n'), DiagramCommand.settingsMatchNext,
        "next match"),
    bind(DiagramScope.settings, chord('p'), DiagramCommand.settingsMatchPrev,
        "previous match"),
    bind(DiagramScope.settings, chord('.'), DiagramCommand.settingsReveal,
        "reveal in tree"),
    bind(DiagramScope.settings, chord('s'), DiagramCommand.settingsSave, "save"),
    bind(DiagramScope.settings, chordRange('1', '3'),
        DiagramCommand.gridPreset, "grid fixture"),

    // ── tools (`IXN2`) ───────────────────────────────────────────────────
    bind(DiagramScope.board, chord('v'), DiagramCommand.toolSelect, "select tool"),
    bind(DiagramScope.board, chord('r'), DiagramCommand.toolRect, "rect tool"),
    bind(DiagramScope.board, chord('c'), DiagramCommand.toolConnect, "connect tool"),

    // ── the camera (`IXN3`) ──────────────────────────────────────────────
    bind(DiagramScope.board, chord('f'), DiagramCommand.fitAll, "fit content"),
    bind(DiagramScope.board, chord('0'), DiagramCommand.zoomReset, "reset zoom"),
    bind(DiagramScope.board, chord('+'), DiagramCommand.zoomIn, "zoom in"),
    bind(DiagramScope.board, chord('='), DiagramCommand.zoomIn, "zoom in"),
    bind(DiagramScope.board, chord('-'), DiagramCommand.zoomOut, "zoom out"),
    bind(DiagramScope.board, chord('_'), DiagramCommand.zoomOut, "zoom out"),
    // WASD pan — one step per press/repeat, never a held-key continuous move,
    // so a terminal without releases can pan too (`IXN3`).
    bind(DiagramScope.board, chord('w'), DiagramCommand.panUp, "pan up"),
    bind(DiagramScope.board, chord('s'), DiagramCommand.panDown, "pan down"),
    bind(DiagramScope.board, chord('a'), DiagramCommand.panLeft, "pan left"),
    bind(DiagramScope.board, chord('d'), DiagramCommand.panRight, "pan right"),
    bind(DiagramScope.board, chord(Key.up), DiagramCommand.panUp, "pan up"),
    bind(DiagramScope.board, chord(Key.down), DiagramCommand.panDown, "pan down"),
    bind(DiagramScope.board, chord(Key.left), DiagramCommand.panLeft, "pan left"),
    bind(DiagramScope.board, chord(Key.right), DiagramCommand.panRight, "pan right"),
    bind(DiagramScope.board, chord(' '), DiagramCommand.panArm, "pan (hold)"),

    // ── the world ────────────────────────────────────────────────────────
    bind(DiagramScope.board, chord('m'), DiagramCommand.toggleMinimap, "minimap"),
    bind(DiagramScope.board, chord(','), DiagramCommand.settingsOpen, "settings"),
    bind(DiagramScope.board, chord('g'), DiagramCommand.groupSelection, "group"),
    bind(DiagramScope.board, chord('u'), DiagramCommand.ungroupSelection, "ungroup"),
    bind(DiagramScope.board, chord(Key.delete_), DiagramCommand.deleteSelection,
        "delete selection"),
    bind(DiagramScope.board, chord(Key.backspace), DiagramCommand.deleteSelection,
        "delete selection"),

    // ── the shell ────────────────────────────────────────────────────────
    // `reveal` (`LTN`): the guide opens the panel instead of dispatching, so
    // this row's arm in the input system is deliberately empty. Board scope,
    // not `always` — typing `?` into a label must type it (`IXN5`).
    bind(DiagramScope.board, chord('?'), DiagramCommand.showGuide,
        "show all keys", reveal: true),
    bind(DiagramScope.board, chord('q'), DiagramCommand.quit, "quit"),
    bind(DiagramScope.board, chord(Key.escape), DiagramCommand.dismiss, "dismiss"),
    bind(DiagramScope.board, chord(Key.back), DiagramCommand.dismiss, "dismiss"),
];

/// $(REF commandFor, sparkles,ui,keymap) over $(LREF diagramBindings).
KeyCommand commandFor(in KeyEvent raw, in DiagramContext ctx)
    @safe pure nothrow @nogc
    => ui_keymap.commandFor(diagramBindings, raw, ctx);

/// $(REF bindingsAt, sparkles,ui,keymap) over $(LREF diagramBindings).
void bindingsAt(Sink)(ref Sink sink, in DiagramContext ctx,
    scope const Chord[] prefix = null)
{
    ui_keymap.bindingsAt(sink, diagramBindings, ctx, prefix);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;

    KeyCommand ch(dchar c, DiagramContext ctx = DiagramContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => commandFor(KeyEvent(Key.char_, c, m), ctx);
    KeyCommand nk(Key k, DiagramContext ctx = DiagramContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => commandFor(KeyEvent(k, 0, m), ctx);
}

@("diagram.keymap.caseIsNotATableConcern")
@safe pure nothrow @nogc
unittest
{
    // The old chain spelled every letter twice (`'v' || 'V'`). Normalisation
    // does it once, so one row covers both — including a producer that sends
    // the shifted character with no modifier at all.
    assert(ch('v').cmd == DiagramCommand.toolSelect);
    assert(ch('V').cmd == DiagramCommand.toolSelect);
    assert(ch('v', DiagramContext.init, Mods(shift: true)).cmd
        == DiagramCommand.toolSelect);
}

@("diagram.keymap.aLabelEditOwnsTheKeyboard")
@safe pure nothrow @nogc
unittest
{
    const editing = DiagramContext(isEditing: true);

    // The edit scope's own keys resolve…
    assert(nk(Key.enter, editing).cmd == DiagramCommand.editCommit);
    assert(nk(Key.escape, editing).cmd == DiagramCommand.editCancel);
    assert(nk(Key.backspace, editing).cmd == DiagramCommand.editErase);

    // …and everything else is text, not a board command: a terminal scope
    // stops resolution, so `v` does NOT switch tools mid-label (`IXN5`).
    assert(ch('v', editing).cmd == DiagramCommand.none);
    assert(ch('q', editing).cmd == DiagramCommand.none);
    assert(nk(Key.up, editing).cmd == DiagramCommand.none);
}

@("diagram.keymap.theSettingsPaneOwnsTheKeyboard")
@safe pure nothrow @nogc
unittest
{
    const open = DiagramContext(settingsOpen: true);

    // Its own keys resolve, in both spellings…
    assert(ch('j', open).cmd == DiagramCommand.settingsDown);
    assert(nk(Key.down, open).cmd == DiagramCommand.settingsDown);
    assert(nk(Key.enter, open).cmd == DiagramCommand.settingsActivate);
    assert(ch('1', open).cmd == DiagramCommand.gridPreset);
    assert(ch('3', open).arg == 2, "the ranged row carries which key landed");

    // …and NOTHING else does. This is the change from the three-fixture
    // panel, which took only first refusal: `d` would have panned the board
    // under the pane, and `q` would have quit the application from a typo.
    assert(ch('d', open).cmd == DiagramCommand.none);
    assert(ch('q', open).cmd == DiagramCommand.none);
    assert(ch('g', open).cmd == DiagramCommand.none);
    assert(ch('w', open).cmd == DiagramCommand.none);

    // Esc is the pane's own close, not the board's dismissal chain.
    assert(nk(Key.escape, open).cmd == DiagramCommand.settingsClose);

    // Closed, the pane's keys mean what the board says: `1` is unbound, `j`
    // is nothing, `d` pans.
    assert(ch('1').cmd == DiagramCommand.none);
    assert(ch('d').cmd == DiagramCommand.panRight);
    assert(ch(',').cmd == DiagramCommand.settingsOpen);
}

@("diagram.keymap.theGuideListsThePaneNotTheBoardWhileItIsOpen")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // A terminal, hiding scope means the guide advertises exactly what the
    // resolver would answer — so the panel cannot offer a board key that no
    // longer works (`FOC4`, and `SET2`'s point).
    SmallBuffer!(Binding, 96) rows;
    bindingsAt(rows, DiagramContext(settingsOpen: true));
    assert(rows.length > 0);
    bool sawPaneRow;
    foreach (ref r; rows[])
    {
        assert(r.cmd != DiagramCommand.panRight, "no board key while modal");
        assert(r.cmd != DiagramCommand.quit);
        sawPaneRow |= r.cmd == DiagramCommand.settingsSave;
    }
    assert(sawPaneRow);
}

@("diagram.keymap.arrowsAndWasdAreTheSameCommands")
@safe pure nothrow @nogc
unittest
{
    assert(ch('w').cmd == nk(Key.up).cmd);
    assert(ch('s').cmd == nk(Key.down).cmd);
    assert(ch('a').cmd == nk(Key.left).cmd);
    assert(ch('d').cmd == nk(Key.right).cmd);
    assert(ch('w').cmd == DiagramCommand.panUp);
}

@("diagram.keymap.bindingsAtEnumeratesWhatIsReachable")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // What the guide would list on a bare board: the board's keys, and none
    // of the modal scopes'.
    SmallBuffer!(Binding, 64) rows;
    bindingsAt(rows, DiagramContext.init);
    bool sawTool, sawEditKey;
    foreach (ref r; rows[])
    {
        sawTool |= r.cmd == DiagramCommand.toolSelect;
        sawEditKey |= r.cmd == DiagramCommand.editCommit;
    }
    assert(sawTool);
    assert(!sawEditKey, "an unreachable scope is not advertised");

    // While editing, the modal scope hides everything below it — listing the
    // board's keys there would be a lie the panel tells (`FOC4`).
    SmallBuffer!(Binding, 64) editRows;
    bindingsAt(editRows, DiagramContext(isEditing: true));
    foreach (ref r; editRows[])
        assert(r.cmd != DiagramCommand.toolSelect);
}

@("diagram.keymap.everyCommandIsBound")
@safe pure nothrow @nogc
unittest
{
    // A command the table never produces is dead policy — the enum and the
    // table drift apart exactly the way the chain and the status row did.
    static foreach (name; __traits(allMembers, DiagramCommand))
    {{
        enum cmd = __traits(getMember, DiagramCommand, name);
        static if (cmd != DiagramCommand.none)
        {
            bool bound;
            foreach (ref b; diagramBindings)
                bound |= b.cmd == cmd;
            assert(bound, "unbound command: " ~ name);
        }
    }}
}
