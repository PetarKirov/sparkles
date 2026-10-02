/**
The terminal's keyboard policy as data (`TKM1`, docs/specs/terminal/keymap.md):
one table over the terminal's command and scope enums, resolved through
`sparkles.ui.keymap` and listed by the same machinery, so the key guide cannot
disagree with what a key does.

$(B The keyboard belongs to the program.) In a pane, only the chords below and
the leader are the terminal's; every other key — Escape included — reaches the
program through the key encoder (`TKM2`). The direct chords are the ones kitty
and Ghostty use; everything else sits under the leader, where the guide makes
it discoverable rather than memorised.

$(B The leader is a setting) (`lantern.leader`, `TKM5`). Rows spell it with a
placeholder code point, $(LREF leaderMark), which $(LREF terminalBindings)
replaces with the configured chord once the user's `keys` overlay (`TKM8`) has
been merged — so an overlay may say `leader t` too.

$(B Scopes, in resolution order) (`TKM4`): `always` (empty, the framework's
mid-sequence scope), `overlay` (a page or menu over the panes: it owns every
key it is shown with, the leader aside), and `pane`.
*/
module keymap;

import sparkles.input.events : Key, KeyEvent;
import ui_keymap = sparkles.ui.keymap;
public import sparkles.ui.keymap : Chord, chord, chordRange, hidesLaterScopes,
    ResolveKind, ShiftReq, terminalScope;
import sparkles.ui.keymap_config : KeysConfigOf;

/// The terminal's binding row.
alias Binding = ui_keymap.Binding!(TermCommand, TermScope);
/// ditto
alias KeyCommand = ui_keymap.KeyCommand!TermCommand;

/**
What a key asks the terminal to do; `none` is "not bound here". Names
describe the effect, not the key.
*/
enum TermCommand : ubyte
{
    none,

    copy,            /// the selection to the clipboard
    paste,           /// the clipboard to the program, through the paste guard
    fontLarger,
    fontSmaller,
    fontReset,
    showGuide,       /// `?` in an overlay, `leader ?` in a pane: every key here
    toggleExtraKeys, /// show or hide the extra-keys row (`TCF7`)
    dismiss,         /// close the innermost overlay (`KBD1`)
    confirm,         /// the innermost overlay's primary action (`KBD1`: Enter)
    showCredits,     /// the credits page, in the document viewer (`TPG15`)

    // Tabs and splits (`TSS8`).
    tabTree,         /// the tree of tabs and panes, with search (`TSS12`)
    newTab,
    closeTab,
    nextTab,
    prevTab,
    goToTab,         /// `1`–`9`: the ranged row carries which
    splitRight,
    splitDown,
    focusLeft,
    focusRight,
    focusUp,
    focusDown,
    resizeLeft,      /// move the focused pane's border (`TSS8`)
    resizeRight,
    resizeUp,
    resizeDown,
    zoomPane,
    closePane,

    // The pages (`TPG`).
    openAbout,         /// the build, and the way to the source and the credits
    openLogs,          /// the application's log
    openNotifications, /// the notification log

    // The exit prompt (`TSS2`).
    promptRerun,     /// Enter: the same command again
    promptShell,     /// Esc: the user's shell in the last directory
    promptClose,     /// Ctrl+C: close the pane
}

/// Which surface a binding belongs to; declaration order is precedence.
enum TermScope : ubyte
{
    /// resolves in every context, even mid-sequence; empty today
    always,
    /// a page, menu or prompt over the panes: modal (`TKM4`)
    @terminalScope @hidesLaterScopes overlay,
    /// the focused pane's exit prompt (`TSS2`): Enter, Esc and Ctrl+C are
    /// its own; the pane's chords and the leader still work beneath it
    prompt,
    /// the focused pane: the few chords the terminal claims (`TKM2`)
    pane,
}

/// What changes what a key means.
struct TermContext
{
    bool overlayOpen; /// a page or menu has the keyboard
    bool promptOpen;  /// the focused pane shows its exit prompt

@safe pure nothrow @nogc const:

    bool reachable(TermScope s)
    {
        final switch (s) with (TermScope)
        {
            case always: return true;
            case overlay: return overlayOpen;
            case prompt: return !overlayOpen && promptOpen;
            case pane: return !overlayOpen;
        }
    }
}

/// The placeholder the rows spell the leader with: a private-use code point
/// no keyboard produces. $(LREF terminalBindings) substitutes the real chord.
enum dchar leaderMark = '';

/// The default leader (`TKM5`, `lantern.leader`).
enum defaultLeader = "ctrl+shift+space";

/// The `keys` overlay's wire form (`TKM8`).
alias KeysConfig = KeysConfigOf!(TermCommand, TermScope, leaderMark);

private alias bind = ui_keymap.bind;
/// A prefix node with the terminal's types pinned.
private Binding group(TermScope s, Chord a, string name) @safe pure nothrow @nogc
    => ui_keymap.group!(TermCommand, TermScope)(s, a, name);
/// ditto
private Binding group(TermScope s, Chord a, Chord b, string name) @safe pure nothrow @nogc
    => ui_keymap.group!(TermCommand, TermScope)(s, a, b, name);

/// A Ctrl+Shift chord on a letter or key.
private Chord ctrlShift(dchar c) @safe pure nothrow @nogc
    => Chord(key: Key.char_, ch: c, ctrl: true, shift: ShiftReq.yes);

/// ditto
private Chord ctrlShiftKey(Key k) @safe pure nothrow @nogc
    => Chord(key: k, ctrl: true, shift: ShiftReq.yes);

/// ditto
private Chord ctrlKey(dchar c) @safe pure nothrow @nogc
    => Chord(key: Key.char_, ch: c, ctrl: true);

/**
The compiled defaults, the leader spelled $(LREF leaderMark). Within a scope
the keys are disjoint, so row order decides nothing.
*/
immutable Binding[] defaultBindings = [
    // ── an overlay owns the keyboard (`KBD1`) ────────────────────────────
    bind(TermScope.overlay, chord(Key.escape), TermCommand.dismiss, "close"),
    bind(TermScope.overlay, chord('q'), TermCommand.dismiss, "close"),
    bind(TermScope.overlay, chord(Key.back), TermCommand.dismiss, "close"),
    bind(TermScope.overlay, chord(Key.enter), TermCommand.confirm, "confirm"),
    bind(TermScope.overlay, chord('?'), TermCommand.showGuide, "key guide",
        reveal: true),
    group(TermScope.overlay, chord(leaderMark), "leader"),

    // ── the pane: the chords kitty and Ghostty use (`TKM2`) ──────────────
    bind(TermScope.pane, ctrlShift('c'), TermCommand.copy, "copy"),
    bind(TermScope.pane, ctrlShift('v'), TermCommand.paste, "paste"),
    bind(TermScope.pane, ctrlKey('='), TermCommand.fontLarger, "larger font"),
    bind(TermScope.pane, ctrlKey('+'), TermCommand.fontLarger, "larger font"),
    bind(TermScope.pane, ctrlKey('-'), TermCommand.fontSmaller, "smaller font"),
    bind(TermScope.pane, ctrlKey('0'), TermCommand.fontReset, "default font size"),
    // The leader is a prefix: the guide shows after `lantern.delayMs`, and a
    // path typed faster runs without it (`TKM5`).
    group(TermScope.pane, chord(leaderMark), "leader"),
    bind(TermScope.pane, chord(leaderMark), chord('?'), TermCommand.showGuide,
        "all keys", reveal: true),

    // Tabs, as kitty and Ghostty spell them (`TSS8`).
    bind(TermScope.pane, ctrlShift('t'), TermCommand.newTab, "new tab"),
    bind(TermScope.pane, ctrlShift('p'), TermCommand.tabTree, "tabs and panes"),
    bind(TermScope.pane, ctrlShift('w'), TermCommand.closePane, "close pane"),
    bind(TermScope.pane, ctrlShiftKey(Key.pageUp), TermCommand.prevTab, "previous tab"),
    bind(TermScope.pane, ctrlShiftKey(Key.pageDown), TermCommand.nextTab, "next tab"),

    // ── under the leader ─────────────────────────────────────────────────
    bind(TermScope.pane, chord(leaderMark), chord('k'), TermCommand.toggleExtraKeys,
        "toggle extra keys"),
    bind(TermScope.pane, chord(leaderMark), chord('a'), TermCommand.openAbout, "about"),
    bind(TermScope.pane, chord(leaderMark), chord('l'), TermCommand.openLogs, "logs"),
    bind(TermScope.pane, chord(leaderMark), chord('n'), TermCommand.openNotifications,
        "notifications"),
    bind(TermScope.pane, chord(leaderMark), chord('c'), TermCommand.showCredits,
        "credits"),
    group(TermScope.pane, chord(leaderMark), chord('t'), "tab"),
    bind(TermScope.pane, chord(leaderMark), chord('t'), chord('n'), TermCommand.newTab,
        "new tab"),
    bind(TermScope.pane, chord(leaderMark), chord('t'), chord('t'), TermCommand.tabTree,
        "tabs and panes"),
    bind(TermScope.pane, chord(leaderMark), chord('t'), chord('x'), TermCommand.closeTab,
        "close tab"),
    bind(TermScope.pane, chord(leaderMark), chord('t'), chordRange('1', '9'),
        TermCommand.goToTab, "go to tab"),
    group(TermScope.pane, chord(leaderMark), chord('p'), "pane"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('v'), TermCommand.splitRight,
        "split right"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('s'), TermCommand.splitDown,
        "split down"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('h', ShiftReq.no),
        TermCommand.focusLeft, "focus left"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('j', ShiftReq.no),
        TermCommand.focusDown, "focus down"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('k', ShiftReq.no),
        TermCommand.focusUp, "focus up"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('l', ShiftReq.no),
        TermCommand.focusRight, "focus right"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('h', ShiftReq.yes),
        TermCommand.resizeLeft, "resize left"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('j', ShiftReq.yes),
        TermCommand.resizeDown, "resize down"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('k', ShiftReq.yes),
        TermCommand.resizeUp, "resize up"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('l', ShiftReq.yes),
        TermCommand.resizeRight, "resize right"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('z'), TermCommand.zoomPane,
        "zoom"),
    bind(TermScope.pane, chord(leaderMark), chord('p'), chord('x'), TermCommand.closePane,
        "close pane"),

    // ── the exit prompt (`TSS2`): the program is gone, so Ctrl+C is free ──
    bind(TermScope.prompt, chord(Key.enter), TermCommand.promptRerun, "run again"),
    bind(TermScope.prompt, chord(Key.escape), TermCommand.promptShell, "shell here"),
    bind(TermScope.prompt, ctrlKey('c'), TermCommand.promptClose, "close pane"),
];

/**
The keys `KBD3` reserves for the terminal's own line discipline and job
control: no scope may bind them (`TKM3`).
*/
immutable Chord[] reservedChords = [
    ctrlKey('c'), ctrlKey('z'), ctrlKey('s'), ctrlKey('q'), ctrlKey('\\'),
];

/// Whether `c` is (or would shadow) a reserved chord.
bool isReserved(in Chord c) @safe pure nothrow @nogc
{
    foreach (r; reservedChords)
        if (c.key == r.key && c.ch == r.ch && c.ctrl && !c.alt && !c.super_
            && c.shift != ShiftReq.yes)
            return true;
    return false;
}

/**
Parses `lantern.leader` (`TKM5`). An unparsable chord, a multi-key path or a
reserved one (`TKM3`) is refused with a warning, and the default leader holds.
*/
Chord leaderChord(string spelling, ref string[] warnings) @safe pure
{
    import sparkles.input.events : parseChord;

    Chord c;
    string err;
    if (!parseChord(spelling, c, err))
        warnings ~= "config: $.lantern.leader: \"" ~ spelling ~ "\": " ~ err
            ~ " — the default leader " ~ defaultLeader ~ " is used";
    else if (isReserved(c))
        warnings ~= "config: $.lantern.leader: \"" ~ spelling
            ~ "\" is reserved for the program (Ctrl-C, Ctrl-Z, Ctrl-S, Ctrl-Q, Ctrl-\\)"
            ~ " — the default leader " ~ defaultLeader ~ " is used";
    else
        return c;
    const ok = parseChord(defaultLeader, c, err);
    assert(ok, err);
    return c;
}

/**
The table in effect: the compiled defaults, the user's `keys` overlay merged
row by row (`TKM8`), then the leader placeholder replaced by `leader`. A row
the overlay binds to a reserved chord is dropped with a warning (`TKM3`).
*/
immutable(Binding)[] terminalBindings(Chord leader, KeysConfig keys,
    ref string[] warnings) @safe
{
    import sparkles.ui.keymap_config : applyKeysOverlay;

    auto merged = applyKeysOverlay!leaderMark(defaultBindings, keys,
        (string w) { warnings ~= "config: " ~ w; });
    Binding[] rows;
    rows.reserve(merged.length);
    foreach (row; merged)
    {
        Binding b = row;
        bool reserved;
        foreach (i; 0 .. b.depth)
        {
            if (b.path[i].key == Key.char_ && b.path[i].ch == leaderMark)
                b.path[i] = leader;
            // `TKM3`'s one exception: the exit prompt's Ctrl+C, when the pane
            // has no program to send it to.
            reserved |= b.scope_ != TermScope.prompt && isReserved(b.path[i]);
        }
        if (reserved)
        {
            warnings ~= "config: keys: a binding for " ~ commandName(b.cmd)
                ~ " uses a chord reserved for the program — it was ignored";
            continue;
        }
        rows ~= b;
    }
    import std.exception : assumeUnique;

    return (() @trusted => rows.assumeUnique)();
}

/// `sparkles.ui.keymap.bindingsAt` over a terminal table: what the guide lists.
void bindingsAt(Sink)(ref Sink sink, scope const(Binding)[] table, in TermContext ctx,
    scope const Chord[] prefix = null)
{
    ui_keymap.bindingsAt(sink, table, ctx, prefix);
}

/// A command's name, as the config spells it.
string commandName(TermCommand c) @safe pure nothrow @nogc
{
    final switch (c)
    {
        static foreach (m; __traits(allMembers, TermCommand))
        {
            case __traits(getMember, TermCommand, m):
                return m;
        }
    }
}

/**
The default table as the Markdown rows of `docs/apps/terminal/reference/bindings.md`
(`TKM9`), so the reference and the binary cannot disagree: a test compares
the page with this. `terminal config keys` prints it.
*/
string bindingsMarkdown() @safe pure
{
    import sparkles.ui.keymap_config : unparseChordPathAs;
    import sparkles.ui.keymap_config : ChordPathOf;

    // `ctrl+shift+c` → `Ctrl+Shift+C`; the key may itself be `+`.
    static string keyName(string canonical)
    {
        import std.algorithm.searching : startsWith;
        import std.uni : toUpper;

        string s = canonical, out_;
        foreach (mod; ["ctrl+", "alt+", "shift+", "super+"])
            if (s.startsWith(mod) && s.length > mod.length)
            {
                out_ ~= mod[0 .. 1].toUpper ~ mod[1 .. $];
                s = s[mod.length .. $];
            }
        if (s.length == 1)
            return out_ ~ (out_.length ? s.toUpper : s);
        if (s == "pageup" || s == "pagedown")
            return out_ ~ "Page" ~ (s == "pageup" ? "Up" : "Down");
        return out_ ~ s[0 .. 1].toUpper ~ s[1 .. $];
    }

    string[3][] rows = [["Keys", "Action", "Where"]];
    foreach (ref b; defaultBindings)
    {
        if (b.group.length)
            continue;
        string keys;
        foreach (i; 0 .. b.depth)
        {
            ChordPathOf!leaderMark one;
            one.path[0] = b.path[i];
            const spelled = b.path[i].ch == leaderMark ? "Leader"
                : keyName(unparseChordPathAs!leaderMark(one));
            keys ~= (i ? " " : "") ~ spelled;
        }
        rows ~= ["`" ~ keys ~ "`", b.desc,
            b.scope_ == TermScope.overlay ? "a page or menu"
                : b.scope_ == TermScope.prompt ? "the exit prompt" : "a pane"];
    }

    // Aligned as prettier aligns a table, so the formatted page contains it.
    size_t[3] w;
    foreach (r; rows)
        foreach (i, cell; r)
            if (cell.length > w[i])
                w[i] = cell.length;
    string line(in string[3] r, char pad)
    {
        string s = "|";
        foreach (i, cell; r)
        {
            s ~= " " ~ cell;
            foreach (_; cell.length .. w[i])
                s ~= pad;
            s ~= " |";
        }
        return s ~ "\n";
    }
    string md = line(rows[0], ' ') ~ line(["", "", ""], '-');
    foreach (r; rows[1 .. $])
        md ~= line(r, ' ');
    return md;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;

    private immutable(Binding)[] defaults() @safe
    {
        string[] warnings;
        auto t = terminalBindings(leaderChord(defaultLeader, warnings), KeysConfig.init,
            warnings);
        assert(warnings.length == 0);
        return t;
    }

    private KeyCommand key(immutable(Binding)[] t, KeyEvent k,
        TermContext ctx = TermContext.init) @safe pure nothrow @nogc
        => ui_keymap.commandFor(t, k, ctx);
}

@("keymap.reservedChordsAreNeverBound")
@safe unittest
{
    // `TKM3`: a static test over the table — every row, every scope.
    foreach (ref row; defaults())
        if (row.scope_ != TermScope.prompt) // no program there to send them to
            foreach (i; 0 .. row.depth)
                assert(!isReserved(row.path[i]), commandName(row.cmd));
    foreach (r; reservedChords)
        assert(key(defaults(), KeyEvent(Key.char_, r.ch, Mods(ctrl: true))).cmd
            == TermCommand.none);
}

@("keymap.thePaneClaimsOnlyItsChords")
@safe unittest
{
    const t = defaults();
    // The table's own chords resolve…
    assert(key(t, KeyEvent(Key.char_, 'c', Mods(ctrl: true, shift: true))).cmd
        == TermCommand.copy);
    assert(key(t, KeyEvent(Key.char_, 'V', Mods(ctrl: true, shift: true))).cmd
        == TermCommand.paste);
    assert(key(t, KeyEvent(Key.char_, '=', Mods(ctrl: true))).cmd == TermCommand.fontLarger);
    // …and the program's keys do not (`TKM2`): Escape, plain letters, Ctrl
    // letters, arrows.
    assert(key(t, KeyEvent(Key.escape)).cmd == TermCommand.none);
    assert(key(t, KeyEvent(Key.char_, 'q')).cmd == TermCommand.none);
    assert(key(t, KeyEvent(Key.char_, 'v', Mods(ctrl: true))).cmd == TermCommand.none);
    assert(key(t, KeyEvent(Key.up)).cmd == TermCommand.none);
}

@("keymap.anOverlayOwnsTheKeyboard")
@safe unittest
{
    const t = defaults();
    const open = TermContext(overlayOpen: true);
    assert(key(t, KeyEvent(Key.escape), open).cmd == TermCommand.dismiss);
    assert(key(t, KeyEvent(Key.char_, 'q'), open).cmd == TermCommand.dismiss);
    // A pane chord is not reachable under a modal overlay.
    assert(key(t, KeyEvent(Key.char_, 'c', Mods(ctrl: true, shift: true)), open).cmd
        == TermCommand.none);
}

@("keymap.theLeaderIsASetting")
@safe unittest
{
    import sparkles.ui.lantern : LanternState, step, StepKind;

    string[] warnings;
    auto t = terminalBindings(leaderChord("ctrl+a", warnings), KeysConfig.init, warnings);
    assert(warnings.length == 0);

    // The leader opens the guide; `k` then runs the command under it.
    LanternState s;
    auto r = step(s, t, KeyEvent(Key.char_, 'a', Mods(ctrl: true)), TermContext.init);
    assert(r.kind == StepKind.descend && s.active && !s.shown, "a pending prefix");
    r = step(s, t, KeyEvent(Key.char_, 'k'), TermContext.init);
    assert(r.kind == StepKind.execute && r.cmd.cmd == TermCommand.toggleExtraKeys);

    // A reserved or unparsable leader is refused; the default holds (`TKM5`).
    string[] w2;
    const fallback = leaderChord("ctrl+c", w2);
    assert(w2.length == 1 && fallback.ch == ' ' && fallback.ctrl);
    assert(leaderChord("ctlr+x", w2).ch == ' ' && w2.length == 2);
}

@("keymap.aUserOverlayRebindsByCommandName")
@safe unittest
{
    import std.typecons : Nullable;

    import sparkles.ui.keymap_config : parseChordPathAs;

    KeysConfig keys;
    keys[TermScope.pane][parseChordPathAs!leaderMark("leader e").value] =
        TermCommand.toggleExtraKeys;
    keys[TermScope.pane][parseChordPathAs!leaderMark("leader k").value] =
        Nullable!TermCommand.init;
    keys[TermScope.pane][parseChordPathAs!leaderMark("ctrl+z").value] = TermCommand.copy;
    string[] warnings;
    auto t = terminalBindings(leaderChord(defaultLeader, warnings), keys, warnings);
    assert(warnings.length == 1, "the reserved Ctrl-Z row is refused");

    import sparkles.ui.lantern : LanternState, step, StepKind;

    LanternState s;
    const lead = KeyEvent(Key.char_, ' ', Mods(ctrl: true, shift: true));
    cast(void) step(s, t, lead, TermContext.init);
    assert(step(s, t, KeyEvent(Key.char_, 'e'), TermContext.init).cmd.cmd
        == TermCommand.toggleExtraKeys);
    cast(void) step(s, t, lead, TermContext.init);
    assert(step(s, t, KeyEvent(Key.char_, 'k'), TermContext.init).kind != StepKind.execute);
}

@("keymap.everyCommandIsBound")
@safe unittest
{
    // `KEY` agreement: a command the table never produces is dead policy.
    static foreach (name; __traits(allMembers, TermCommand))
    {{
        enum cmd = __traits(getMember, TermCommand, name);
        static if (cmd != TermCommand.none)
        {
            bool bound;
            foreach (ref b; defaultBindings)
                bound |= b.cmd == cmd;
            assert(bound, "unbound command: " ~ name);
        }
    }}
}

@("keymap.bindingsMarkdown.matchesTheReference")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : readText;
    import std.path : buildPath, dirName;

    // `TKM9`: the reference page carries exactly the table the binary uses.
    // On a mismatch, paste the output of `terminal config keys` into it.
    const page = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "docs", "apps",
        "terminal", "reference", "bindings.md");
    assert(readText(page).canFind(bindingsMarkdown()),
        "docs/apps/terminal/reference/bindings.md is stale — regenerate its table "
        ~ "with `terminal config keys`:\n" ~ bindingsMarkdown());
}
