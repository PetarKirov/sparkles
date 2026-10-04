/**
The keys every Sparkles application shares (design-system `KBD1`, `KBD3`,
`KBD6`): the universal rows, the reserved keys, and the listing of a table.

$(B The universal rows are meanings, not commands.) Every application has its
own command enum, and one universal meaning maps onto several of them —
"close the innermost thing" is a dismiss over an overlay, a pane close, and
a quit at the top. So an application marks each command with the
$(LREF UniversalCommand) it implements — a $(LREF means) UDA, read by
$(LREF meaningOf) — and everything here compares meanings:
$(LREF firstRebound) finds a row that binds a fixed universal key to
something else, and $(LREF universalMeanings) answers "what does each
universal key mean here" — the value three applications' tables must agree
on (M8's gate), and how the focus rows (`Space`, `Enter`) are checked.

$(B Reserved keys) belong to the terminal and the host, never to a table:
$(LREF firstReserved) finds the row that binds one.

$(B The listing) ($(LREF writeKeyTable)) prints a table — the merged one,
overlay included — one row per line, in the overlay's own chord spelling, so
`--list-keys`, the guide and the docs cannot disagree.
*/
module sparkles.ui.keymap_universal;

import sparkles.input.events : Key, KeyEvent, Mods;
import sparkles.ui.keymap : Binding, Chord, chord, commandFor, ModeReq, ShiftReq;
import sparkles.ui.keymap_config : unparseChordPathAs;
import sparkles.wired.policy : AnyFormat, CaseStyle, resolveCaseStyle, WireCase,
    wireNames;

/// What a universal key means (`KBD1`). `none` is "not a universal meaning".
@WireCase(CaseStyle.kebabCase)
enum UniversalCommand : ubyte
{
    none,      ///
    close,     /// `q` / `Esc` (and the platform Back): close the innermost thing
    guide,     /// `?`: open the key guide
    focusNext, /// `Tab`
    focusPrev, /// `Shift-Tab`
    activate,  /// `Enter`
    toggle,    /// `Space`
    search,    /// `/`: start a search, where one exists
}

/**
Marks a member of an application's command enum with the universal meaning it
implements — `@means(UniversalCommand.close) dismiss,` — so the meaning is
data on the command, read by $(LREF meaningOf). A command with none means
`none`.
*/
struct means
{
    UniversalCommand cmd; ///
}

/// The universal meaning `c` implements, from its $(LREF means) UDA.
UniversalCommand meaningOf(Cmd)(Cmd c) @safe pure nothrow @nogc
if (is(Cmd == enum))
{
    import std.traits : EnumMembers, getUDAs;

    static foreach (m; EnumMembers!Cmd)
        static if (getUDAs!(m, means).length)
            if (c == m)
                return getUDAs!(m, means)[0].cmd;
    return UniversalCommand.none;
}

/// The kebab-case names the listing and the docs spell meanings with.
alias universalCommandNames = wireNames!(AnyFormat, UniversalCommand,
    resolveCaseStyle!(AnyFormat, UniversalCommand));

/// One universal key: the chord, and what it means everywhere.
struct UniversalKey
{
    Chord chord;          ///
    UniversalCommand cmd; ///
    KeyEvent event;       /// a key event that produces `chord`, for resolution
    /// A focus row: it acts on the focused control (`Space` toggles it,
    /// `Enter` activates it), and where the focus has no such action the
    /// application may bind the key itself — hue's leader, diagram's
    /// hold-to-pan. A fixed row means the same wherever it is bound.
    bool focus;
}

/// The universal rows (`KBD1`), in the spec's order.
static immutable UniversalKey[] universalKeys = [
    UniversalKey(chord('q'), UniversalCommand.close, KeyEvent(Key.char_, 'q')),
    UniversalKey(chord(Key.escape), UniversalCommand.close, KeyEvent(Key.escape, 0)),
    UniversalKey(chord(Key.back), UniversalCommand.close, KeyEvent(Key.back, 0)),
    UniversalKey(chord('?'), UniversalCommand.guide, KeyEvent(Key.char_, '?')),
    UniversalKey(chord(Key.tab, ShiftReq.no), UniversalCommand.focusNext,
        KeyEvent(Key.tab, 0)),
    UniversalKey(chord(Key.tab, ShiftReq.yes), UniversalCommand.focusPrev,
        KeyEvent(Key.tab, 0, Mods(shift: true))),
    UniversalKey(chord(Key.enter), UniversalCommand.activate, KeyEvent(Key.enter, 0),
        focus: true),
    UniversalKey(chord(' '), UniversalCommand.toggle, KeyEvent(Key.char_, ' '),
        focus: true),
    UniversalKey(chord('/'), UniversalCommand.search, KeyEvent(Key.char_, '/')),
];

/**
The first row of `table` that binds a fixed universal key to another meaning —
the index, or `size_t.max` when none does (`KBD1`: an application may leave a
universal row unbound, never rebind it). Focus rows (`Space`, `Enter`) mean
what they mean only where the focus has that action, so they are checked in
context, through $(LREF universalMeanings), not here.

Only single-chord rows are universal keys; a line editor's rows
(`ModeReq.editing`) are text, not the application's keyboard, and a prefix
node (`group`) runs nothing. `meaning` maps the application's command to the
universal meaning it implements.
*/
size_t firstRebound(alias meaning, B)(scope const(B)[] table)
{
    foreach (i, ref b; table)
    {
        if (b.depth != 1 || b.mode == ModeReq.editing || b.group.length)
            continue;
        foreach (ref u; universalKeys)
            if (!u.focus && overlaps(b.path[0], u.chord) && meaning(b.cmd) != u.cmd)
                return i;
    }
    return size_t.max;
}

// Whether two chords can be struck by one key press: the same key and
// modifiers, shift requirements compatible (`ignore` accepts either), and a
// ranged chord counting every code point it covers. Not `sameKey`, which is
// exact: a Shift-agnostic `Tab` row binds `Shift-Tab` too.
private bool overlaps(in Chord a, in Chord b) @safe pure nothrow @nogc
{
    if (a.key != b.key || a.ctrl != b.ctrl || a.alt != b.alt || a.super_ != b.super_)
        return false;
    if (a.shift != ShiftReq.ignore && b.shift != ShiftReq.ignore && a.shift != b.shift)
        return false;
    const aEnd = a.chEnd ? a.chEnd : a.ch, bEnd = b.chEnd ? b.chEnd : b.ch;
    return a.ch <= bEnd && b.ch <= aEnd;
}

/// The keys no Sparkles application binds (`KBD3`): interrupt (`Ctrl-C`),
/// suspend (`Ctrl-Z`), flow control (`Ctrl-S`, `Ctrl-Q`) and quit (`Ctrl-\`) —
/// the terminal's and the host's.
static immutable Chord[] reservedChords = [
    Chord(key: Key.char_, ch: 'c', ctrl: true),
    Chord(key: Key.char_, ch: 'z', ctrl: true),
    Chord(key: Key.char_, ch: 's', ctrl: true),
    Chord(key: Key.char_, ch: 'q', ctrl: true),
    Chord(key: Key.char_, ch: '\\', ctrl: true),
];

/// The first row of `table` whose path uses a reserved chord at any depth —
/// the index, or `size_t.max` (`KBD3`).
size_t firstReserved(B)(scope const(B)[] table)
{
    foreach (i, ref b; table)
        foreach (d; 0 .. b.depth)
            foreach (ref r; reservedChords)
                if (overlaps(b.path[d], r))
                    return i;
    return size_t.max;
}

/**
What each universal key means in `table` under `ctx`: index `i` answers for
`universalKeys[i]` — its command's universal meaning, or `none` where the key
is unbound there. Three applications that honour `KBD1` agree on every entry
they bind (M8's gate).
*/
UniversalCommand[universalKeys.length] universalMeanings(alias meaning, B, Ctx)(
    scope const(B)[] table, in Ctx ctx)
{
    typeof(return) r;
    foreach (i, ref u; universalKeys)
        r[i] = meaning(commandFor(table, u.event, ctx).cmd);
    return r;
}

/**
Writes `table` one row per line (`KBD6`): the scope, the chord path in the
overlay's spelling (`leader` spells as `space`), and the description — a
prefix node as `+group`. In table order, which is resolution order, so the
listing reads the way the keyboard behaves.
*/
void writeKeyTable(dchar leader, W, B)(ref W w, scope const(B)[] table)
{
    import std.range.primitives : put;
    import sparkles.ui.keymap_config : ChordPathOf;

    alias Scope = typeof(B.init.scope_);
    alias scopeNames = wireNames!(AnyFormat, Scope, resolveCaseStyle!(AnyFormat, Scope));

    size_t scopeWidth, pathWidth;
    foreach (ref b; table)
    {
        const s = scopeNames[b.scope_].length;
        const p = spell!leader(b).length;
        scopeWidth = s > scopeWidth ? s : scopeWidth;
        pathWidth = p > pathWidth ? p : pathWidth;
    }
    foreach (ref b; table)
    {
        const s = scopeNames[b.scope_];
        const p = spell!leader(b);
        put(w, s);
        foreach (_; s.length .. scopeWidth + 2)
            put(w, ' ');
        put(w, p);
        foreach (_; p.length .. pathWidth + 2)
            put(w, ' ');
        if (b.group.length)
        {
            put(w, '+');
            put(w, b.group);
        }
        else
            put(w, b.desc);
        put(w, '\n');
    }
}

private string spell(dchar leader, B)(in B b)
{
    import sparkles.ui.keymap_config : ChordPathOf;

    ChordPathOf!leader p;
    p.path = b.path;
    p.depth = b.depth;
    return unparseChordPathAs!leader(p);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.ui.keymap : bind, group;

    private enum TCmd : ubyte { none, quit, dismiss, help, find, nextPane, copy, fold }
    private enum TScope : ubyte { app }

    private UniversalCommand tMeaning(TCmd c) @safe pure nothrow @nogc
    {
        // The application's own mapping: two commands mean "close".
        switch (c)
        {
            case TCmd.quit, TCmd.dismiss: return UniversalCommand.close;
            case TCmd.help: return UniversalCommand.guide;
            case TCmd.find: return UniversalCommand.search;
            case TCmd.nextPane: return UniversalCommand.focusNext;
            default: return UniversalCommand.none;
        }
    }

    private struct NoContext {}
}

@("ui.keymap_universal.reboundAndReserved")
@safe unittest
{
    alias B = Binding!(TCmd, TScope);
    static immutable B[] good = [
        bind(TScope.app, chord('q'), TCmd.quit, "quit"),
        bind(TScope.app, chord(Key.escape), TCmd.dismiss, "dismiss"),
        bind(TScope.app, chord('?'), TCmd.help, "guide"),
        bind(TScope.app, chord(Key.tab, ShiftReq.no), TCmd.nextPane, "next pane"),
        bind(TScope.app, chord('y'), TCmd.copy, "copy"),
        group!TCmd(TScope.app, chord('z'), "fold"),
        bind(TScope.app, chord('z'), chord('a'), TCmd.fold, "fold"),
    ];
    assert(firstRebound!tMeaning(good) == size_t.max);
    assert(firstReserved(good) == size_t.max);

    // Space and Enter are focus rows: a leader on Space and a command on
    // Enter are the application's where nothing focused takes them.
    static immutable B[] focusRows = [
        group!TCmd(TScope.app, chord(' '), "leader"),
        bind(TScope.app, chord(' '), chord('y'), TCmd.copy, "copy"),
        bind(TScope.app, chord(Key.enter), TCmd.fold, "fold"),
    ];
    assert(firstRebound!tMeaning(focusRows) == size_t.max);

    // Tab rebound to something that is not focus — hue's old `toggleView`.
    static immutable B[] rebound = [bind(TScope.app, chord(Key.tab), TCmd.copy, "view")];
    assert(firstRebound!tMeaning(rebound) == 0);
    // A line editor's Escape is text, not the application's keyboard.
    static immutable B[] editor = [bind(TScope.app, chord(Key.escape), TCmd.copy,
        "cancel", mode: ModeReq.editing)];
    assert(firstRebound!tMeaning(editor) == size_t.max);

    // Ctrl-C copy is reserved, at any depth of a path.
    static immutable B[] reserved = [
        bind(TScope.app, chord('y'), TCmd.copy, "copy"),
        bind(TScope.app, Chord(key: Key.char_, ch: 'c', ctrl: true), TCmd.copy, "copy"),
    ];
    assert(firstReserved(reserved) == 1);
    static immutable B[] deep = [bind(TScope.app, chord('g'),
        Chord(key: Key.char_, ch: 's', ctrl: true), TCmd.copy, "save")];
    assert(firstReserved(deep) == 0);
}

@("ui.keymap_universal.meaningsAreComparable")
@safe unittest
{
    alias B = Binding!(TCmd, TScope);
    static immutable B[] a = [
        bind(TScope.app, chord('q'), TCmd.quit, "quit"),
        bind(TScope.app, chord('/'), TCmd.find, "search"),
    ];
    static immutable B[] b = [
        bind(TScope.app, chord('q'), TCmd.dismiss, "close"),
        bind(TScope.app, chord('/'), TCmd.find, "find"),
        bind(TScope.app, chord('?'), TCmd.help, "keys"),
    ];
    const ma = universalMeanings!tMeaning(a, NoContext());
    const mb = universalMeanings!tMeaning(b, NoContext());
    // Different commands, the same meanings; an unbound key is `none`.
    foreach (i, ref u; universalKeys)
        assert(ma[i] == UniversalCommand.none || mb[i] == UniversalCommand.none
            || ma[i] == mb[i]);
    assert(ma[0] == UniversalCommand.close && mb[0] == UniversalCommand.close);
    assert(ma[3] == UniversalCommand.none && mb[3] == UniversalCommand.guide);
}

@("ui.keymap_universal.writeKeyTable")
@safe unittest
{
    import std.array : appender;

    alias B = Binding!(TCmd, TScope);
    static immutable B[] t = [
        bind(TScope.app, chord('q'), TCmd.quit, "quit"),
        group!TCmd(TScope.app, chord(' '), "leader"),
        bind(TScope.app, chord(' '), chord('y'), TCmd.copy, "copy"),
    ];
    auto w = appender!string;
    writeKeyTable!' '(w, t);
    assert(w[] == "app  q        quit\n"
        ~ "app  space    +leader\n"
        ~ "app  space y  copy\n", w[]);
}

@("ui.keymap_universal.meaningOf")
@safe pure nothrow @nogc
unittest
{
    enum C : ubyte
    {
        none,
        @means(UniversalCommand.close) quit,
        @means(UniversalCommand.close) dismiss,
        @means(UniversalCommand.guide) help,
        copy,
    }
    assert(meaningOf(C.quit) == UniversalCommand.close);
    assert(meaningOf(C.dismiss) == UniversalCommand.close);
    assert(meaningOf(C.help) == UniversalCommand.guide);
    assert(meaningOf(C.copy) == UniversalCommand.none);
    assert(meaningOf(C.none) == UniversalCommand.none);
}
