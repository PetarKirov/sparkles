/**
User-configurable keybindings (`CFG6`): the wire form, the chord codec, and
the overlay merge.

The config file's `keys` section is `context → chord-path → command-or-null`,
where contexts are exactly the `Scope_` member names, commands are `Command`
member names (so an unknown one is a $(I located decode error), never a
silent no-op), and a chord path is a human-writable string (`"ctrl+c"`,
`"shift+r"`, `"z 1-9"`, `"leader u s"`) parsed through a type-level
`@WireConvert` into the keymap's own `Chord[]` vocabulary.

The user table is a $(B row-by-row overlay) on `hueBindings`, never a
replacement: rebinding `j` leaves every other row alone, `null` unbinds, and
a path claims its whole subtree (`"z": null` removes the fold family). The
merged table is what `installBindings` publishes, so resolution, the lantern
guide, and `bindingsAt` cannot disagree about what a key does (`KEY12`).

Chord grammar:
---
path      := chord (" " chord)*                 (1..3 chords)
chord     := (mod "+")* keytoken
mod       := "ctrl" | "alt" | "shift" | "super"
keytoken  := keyname | range | printable
keyname   := "space" | "leader" | "up" | ... | "f12"   (see keyNames)
range     := printable "-" printable            ("1-9", one ranged row)
---
`cmd`/`command`/`⌘` parse as `super`; `opt`/`option`/`meta`/`⌥` parse as
`alt`. Canonical unparse is `super+` / `alt+`.
A bare printable binds Shift-agnostically (`ShiftReq.ignore`); `shift+r` or
an uppercase letter binds the shifted form (`ShiftReq.yes`), folded exactly
as `normalise` folds events. `ShiftReq.no` has no v1 spelling — rebinding
`"r"` therefore replaces both the `r` and `Shift-R` rows, and restoring the
shifted one is one more line; `unshift+` is reserved for later.
*/
module keymap_config;

import sparkles.input.events : Key,
    InputChordPath = ChordPath,
    parseInputChordPath = parseChordPath,
    unparseInputChordPath = unparseChordPath;
import sparkles.wired.policy : WireConvert;
import ui_keymap = sparkles.ui.keymap;
import sparkles.ui.keymap : Chord, chordRange, maxPathLength, ModeReq, ShiftReq;

import keymap : Binding, Command, leader, Scope_;

// ─────────────────────────────────────────────────────────────────────────────
// The wire form.
// ─────────────────────────────────────────────────────────────────────────────

/// The `keys` section: an overlay entry per (context, chord path). `null`
/// unbinds. The whole map is one layer-scalar in the CFG2 merge (a higher
/// layer's `keys` replaces a lower's; row-level layering can come later).
alias KeysConfig = CommandRef[ChordPath][Scope_];

/// `Command`-or-null without dragging `Nullable` into an AA value (wired maps
/// its empty state to JSON `null` natively).
import std.typecons : Nullable;

/// ditto
alias CommandRef = Nullable!Command;

/// A binding path in its typed form; the wire form is the chord string.
@WireConvert!(unparseChordPath, parseChordPath)
struct ChordPath
{
    Chord[maxPathLength] path;
    ubyte depth = 1;
}

/// A chord-parse failure, Expected-shaped for wired's converter seam (§8).
struct ChordError
{
    string msg;
}

/// ditto
struct ChordParsed
{
    ChordPath value;
    ChordError error;
    bool bad;
    bool hasValue() const @safe pure nothrow @nogc => !bad;
    bool hasError() const @safe pure nothrow @nogc => bad;
}

private ChordParsed chordFail(string msg) @safe pure nothrow
    => ChordParsed(ChordPath.init, ChordError(msg), true);

/**
Parses one path. Total over its grammar; every rejection carries a reason
wired renders as a located decode error at the offending key.
*/
ChordParsed parseChordPath(string text) @safe pure
{
    InputChordPath p;
    string err;
    if (!parseInputChordPath(text, p, err, leader))
        return chordFail(err);
    ChordPath res;
    res.path = p.path;
    res.depth = p.depth;
    return ChordParsed(res);
}

/// The canonical spelling: mods in `ctrl+alt+shift+super` order, named keys
/// by their table above, `' '` as `space`, chords joined by single spaces.
/// Aliases (`cmd`, `opt`, `meta`, …) and symbols (`⌘`, `⌥`) parse in and
/// unparse as `super+` / `alt+`. `parseChordPath ∘ unparseChordPath` is the
/// identity on canonical spellings (pinned by test).
string unparseChordPath(ChordPath p) @safe pure
{
    InputChordPath ip;
    ip.path = p.path;
    ip.depth = p.depth;
    return unparseInputChordPath(ip, leader);
}

// ─────────────────────────────────────────────────────────────────────────────
// The overlay merge.
// ─────────────────────────────────────────────────────────────────────────────

/**
Applies the user overlay onto the compiled table.

Each entry is matched against the $(B base) table only — never against other
entries — so entries commute and the result is independent of AA iteration
order. A match is same scope + the user path claiming the row: `row.depth >=
user.depth` with each user chord equal to the row's (a user `ignore` shift
matches any row shift; `yes` matches only `yes`; a single code point does
$(B not) match a range — unbind the whole range instead). `null` drops the
matched rows; a command drops them and prepends one unconditional row, whose
description is borrowed from the first base row carrying that command so the
guide still explains it. New rows sort by (scope, canonical spelling) and go
$(B before) the surviving base rows: within a scope, first row wins, so a
user row shadows what it did not delete; base survivors keep their relative
order (which is load-bearing once: the diff-session `[`/`]` rows).

The wire shape has no vocabulary for `require`/`forbid`/`ModeReq` gates, so
an assignment replaces the whole family a path meant, gates included — the
guide shows the honest result.
*/
immutable(Binding)[] applyKeysOverlay(immutable(Binding)[] base,
    KeysConfig keys, scope void delegate(string) @safe warn) @safe
{
    import std.algorithm.sorting : sort;

    if (!keys.length)
        return base;

    bool[] dropped = new bool[base.length];
    Binding[] added;

    foreach (scope_, chordMap; keys)
    {
        foreach (cpath, cmdRef; chordMap)
        {
            size_t matched;
            foreach (ri, ref row; base)
            {
                if (row.scope_ != scope_ || row.depth < cpath.depth)
                    continue;
                bool claims = true;
                foreach (i; 0 .. cpath.depth)
                    if (!overlayChordMatches(cpath.path[i], row.path[i]))
                    {
                        claims = false;
                        break;
                    }
                if (!claims)
                    continue;
                dropped[ri] = true;
                matched++;
            }

            if (cmdRef.isNull)
            {
                if (!matched && warn !is null)
                    warn("keys." ~ scopeName(scope_) ~ "[\""
                        ~ unparseChordPath(cpath)
                        ~ "\"]: null unbinds nothing (typo?)");
                continue;
            }
            const cmd = cmdRef.get;
            if (cmd == Command.none)
            {
                if (warn !is null)
                    warn("keys." ~ scopeName(scope_) ~ "[\""
                        ~ unparseChordPath(cpath)
                        ~ "\"]: 'none' does not unbind — use null");
                continue;
            }
            const last = cpath.path[cpath.depth - 1];
            if (last.ctrl && last.key == Key.char_ && scope_ != Scope_.ctrl
                && scope_ != Scope_.always && warn !is null)
                warn("keys." ~ scopeName(scope_) ~ "[\""
                    ~ unparseChordPath(cpath)
                    ~ "\"]: a ctrl+letter outside the 'ctrl' context can " ~
                    "never fire (the ctrl scope resolves it first)");

            Binding b;
            b.path = cpath.path;
            b.depth = cpath.depth;
            b.scope_ = scope_;
            b.cmd = cmd;
            b.arg = last.chEnd != 0 ? 1 : 0;
            b.desc = descFor(base, cmd);
            added ~= b;
        }
    }

    // Deterministic order under AA iteration — and correct precedence: a
    // shift-specific row sorts before a shift-agnostic one on the same key,
    // so restoring `shift+r` beside a rebound bare `r` actually wins when
    // Shift is held (first row per scope fires).
    static string shiftless(in Binding b) @safe pure
    {
        auto p = ChordPath(b.path, b.depth);
        foreach (i; 0 .. p.depth)
            p.path[i].shift = ShiftReq.ignore;
        return unparseChordPath(p);
    }

    static int agnostic(in Binding b) @safe pure nothrow @nogc
    {
        int n;
        foreach (i; 0 .. b.depth)
            if (b.path[i].shift == ShiftReq.ignore)
                n++;
        return n;
    }

    added.sort!((a, b) {
        if (a.scope_ != b.scope_)
            return a.scope_ < b.scope_;
        const at = shiftless(a), bt = shiftless(b);
        if (at != bt)
            return at < bt;
        return agnostic(a) < agnostic(b);
    });

    Binding[] merged;
    merged.reserve(added.length + base.length);
    merged ~= added;
    foreach (ri, ref row; base)
        if (!dropped[ri])
            merged ~= row;

    // Freshly built, no other mutable reference escapes — the one place the
    // immutability of the published table is asserted rather than inferred.
    import std.exception : assumeUnique;

    return (() @trusted => merged.assumeUnique)();
}

/// The user-chord-claims-row comparison described on `applyKeysOverlay`.
private bool overlayChordMatches(Chord user, Chord row) @safe pure nothrow @nogc
{
    if (user.key != row.key || user.ch != row.ch || user.chEnd != row.chEnd
        || user.ctrl != row.ctrl || user.alt != row.alt || user.super_ != row.super_)
        return false;
    final switch (user.shift)
    {
        case ShiftReq.ignore: return true;
        case ShiftReq.yes:    return row.shift == ShiftReq.yes;
        case ShiftReq.no:     return row.shift == ShiftReq.no;
    }
}

/// The wire spelling of a scope, for warnings (`shared_` → `shared`).
private string scopeName(Scope_ s) @safe pure nothrow @nogc
{
    if (s == Scope_.shared_)
        return "shared";
    final switch (s)
    {
        static foreach (m; __traits(allMembers, Scope_))
        {
            case __traits(getMember, Scope_, m):
                return m;
        }
    }
}

/// The first base row's description for `cmd`, else the member name — so a
/// rebound command still reads as itself in the guide.
private string descFor(immutable(Binding)[] base, Command cmd)
    @safe pure nothrow @nogc
{
    foreach (ref row; base)
        if (row.cmd == cmd && !row.group.length && row.desc.length)
            return row.desc;
    final switch (cmd)
    {
        static foreach (m; __traits(allMembers, Command))
        {
            case __traits(getMember, Command, m):
                return m;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.input.events : KeyEvent, Mods;
    import keymap : hueBindings, KeyContext;

    private ChordPath cp(string s) @safe pure
    {
        const r = parseChordPath(s);
        assert(!r.bad, r.error.msg);
        return r.value;
    }

    // Explicit-table resolution over a merged table.
    private Command over(immutable(Binding)[] table, dchar c,
        KeyContext ctx = KeyContext.init, Mods m = Mods()) @safe pure nothrow @nogc
        => ui_keymap.commandFor(table, KeyEvent(Key.char_, c, m), ctx).cmd;
}

@("keymap_config.chordCodec.roundTrip")
@safe pure unittest
{
    // Canonical spellings survive parse ∘ unparse exactly.
    foreach (s; ["j", "shift+r", "ctrl+c", "super+c", "ctrl+alt+delete", "z 1-9",
        "space u s", "f11", "pageup", "escape", "+", "-", "ctrl+="])
        assert(unparseChordPath(cp(s)) == s, s);

    // Non-canonical inputs canonicalise: uppercase folds to shift+lower,
    // `leader` spells as `space`.
    assert(unparseChordPath(cp("R")) == "shift+r");
    assert(unparseChordPath(cp("leader u s")) == "space u s");

    // The typed form matches the table's own spelling rules.
    assert(cp("shift+r").path[0].shift == ShiftReq.yes);
    assert(cp("j").path[0].shift == ShiftReq.ignore);
    assert(cp("z 1-9").path[1].chEnd == '9');
    assert(cp("ctrl+c").path[0].ctrl);
    assert(cp("f11").path[0].key == Key.f11);
    assert(cp("space").path[0].ch == ' ');

    // Aliases and symbols parse to their canonical typed chords and unparse
    // as `super+` / `alt+`.
    assert(cp("meta+x").path[0].alt);
    assert(cp("opt+x").path[0].alt);
    assert(cp("option+x").path[0].alt);
    assert(cp("cmd+c").path[0].super_);
    assert(cp("⌘c").path[0].super_);
    assert(cp("⌥f").path[0].alt);
    assert(cp("⎋").path[0].key == Key.escape);
    assert(cp("⏎").path[0].key == Key.enter);
    assert(unparseChordPath(cp("cmd+c")) == "super+c");
    assert(unparseChordPath(cp("⌘c")) == "super+c");
    assert(unparseChordPath(cp("meta+x")) == "alt+x");
    assert(unparseChordPath(cp("opt+x")) == "alt+x");
    assert(unparseChordPath(cp("option+x")) == "alt+x");
    assert(unparseChordPath(cp("⌥x")) == "alt+x");

    // Rejections carry reasons.
    assert(parseChordPath("").bad);
    assert(parseChordPath("nosuchmod+x").bad);
    assert(parseChordPath("9-1").bad);
    assert(parseChordPath("a b c d").bad);
    assert(parseChordPath("nosuchkey").bad);
    assert(parseChordPath("a  b").bad); // double space = empty chord
}

@("keymap_config.keysConfig.wiredRoundTripAndLocatedErrors")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.wired.json : fromJSON, toJSON;

    import settings : HueConfig;
    import settings_overlay : Sparse;

    // The spec's wire shape: contexts by Scope_ name (`shared`, not
    // `shared_`), chords human-writable, commands by Command name, null
    // unbinds.
    const text = `{"keys":{` ~
        `"viewer":{"shift+r":"themePrev","q":null},` ~
        `"shared":{"z 1-9":"foldLevel"}}}`;
    auto r = fromJSON!(Sparse!HueConfig)(text);
    assert(!r.hasError, r.error.toString);
    const keys = r.value.keys.get;
    assert(keys[Scope_.viewer][cp("shift+r")].get == Command.themePrev);
    assert(keys[Scope_.viewer][cp("q")].isNull);
    assert(keys[Scope_.shared_][cp("z 1-9")].get == Command.foldLevel);

    // Round trip through the canonical chord spelling.
    HueConfig c;
    c.keys = cast(KeysConfig) keys;
    auto emitted = toJSON(c.keys);
    assert(!emitted.hasError);
    assert(emitted.value[].canFind(`"shared"`), emitted.value[].idup);
    assert(emitted.value[].canFind(`"shift+r":"themePrev"`));
    auto back = fromJSON!KeysConfig(emitted.value[]);
    assert(!back.hasError && back.value == c.keys);

    // Unknown command: located decode error naming the member set.
    auto badCmd = fromJSON!(Sparse!HueConfig)(
        `{"keys":{"viewer":{"j":"viewDwon"}}}`);
    assert(badCmd.hasError);
    assert(badCmd.error.path[].canFind("keys"), badCmd.error.toString);

    // Unknown context.
    assert(fromJSON!(Sparse!HueConfig)(
        `{"keys":{"nromal":{"j":"viewDown"}}}`).hasError);

    // Unparseable chord: the converter's reason, at the offending key.
    auto badChord = fromJSON!(Sparse!HueConfig)(
        `{"keys":{"viewer":{"ctlr+c":"copySelection"}}}`);
    assert(badChord.hasError);
    assert(badChord.error.path[].canFind("ctlr+c"), badChord.error.toString);
    assert(badChord.error.reason.canFind("unknown"), badChord.error.reason);
}

@("keymap_config.applyKeysOverlay.rowByRow")
@safe unittest
{
    string[] warnings;
    scope warn = (string w) @safe { warnings ~= w; };

    // Rebind one key; unbind another; leave everything else standing.
    KeysConfig keys;
    keys[Scope_.viewer][cp("j")] = CommandRef(Command.viewPageDown);
    keys[Scope_.tree][cp("q")] = CommandRef.init; // null: unbind

    auto merged = applyKeysOverlay(hueBindings, keys, warn);

    // The viewer's j now pages; the tree's own j is untouched.
    const viewer = KeyContext.init;
    const tree = KeyContext(treeFocused: true, treeVisible: true);
    assert(over(merged, 'j', viewer) == Command.viewPageDown);
    assert(over(merged, 'j', tree) == over(hueBindings, 'j', tree));
    // The tree scope has no q row, so the null entry is a no-op with a
    // warning; the shared quit row still resolves from the tree.
    assert(over(merged, 'q', tree) == over(hueBindings, 'q', tree));

    // Row count: j dropped one and added one; q touched nothing.
    assert(merged.length == hueBindings.length);
    import std.algorithm.searching : canFind;
    assert(warnings.length == 1 && warnings[0].canFind("unbinds nothing"),
        warnings.length ? warnings[0] : "no warning");
}

@("keymap_config.applyKeysOverlay.familiesAndShift")
@safe unittest
{
    string[] warnings;
    scope warn = (string w) @safe { warnings ~= w; };

    KeysConfig keys;
    // A path claims its subtree: unbinding `z` kills the whole fold family,
    // levels included.
    keys[Scope_.viewer][cp("z")] = CommandRef.init;
    // Rebinding bare `r` (shift-agnostic) in the tree replaces BOTH the
    // r/refresh and Shift-R/reroot rows...
    keys[Scope_.tree][cp("r")] = CommandRef(Command.treeRefresh);
    // ...and the shifted form is restorable with one more line.
    keys[Scope_.tree][cp("shift+r")] = CommandRef(Command.treeReroot);

    auto merged = applyKeysOverlay(hueBindings, keys, warn);

    const viewer = KeyContext.init;
    const tree = KeyContext(treeFocused: true, treeVisible: true);
    assert(over(merged, 'z', viewer) == Command.none);
    assert(ui_keymap.resolve(merged, null,
        KeyEvent(Key.char_, 'z'), viewer).kind == ui_keymap.ResolveKind.none);
    assert(over(merged, 'r', tree) == Command.treeRefresh);
    assert(over(merged, 'r', tree, Mods(shift: true)) == Command.treeReroot);

    // A rebound range keeps deriving its argument.
    KeysConfig ranged;
    ranged[Scope_.viewer][cp("x 1-9")] = CommandRef(Command.foldLevel);
    auto m2 = applyKeysOverlay(hueBindings, ranged, warn);
    const r = ui_keymap.resolve(m2,
        [Chord(key: Key.char_, ch: 'x')], KeyEvent(Key.char_, '3'), viewer);
    assert(r.cmd == Command.foldLevel && r.arg == 3);
}

@("keymap_config.applyKeysOverlay.warnings")
@safe unittest
{
    import std.algorithm.searching : canFind;

    string[] warnings;
    scope warn = (string w) @safe { warnings ~= w; };

    KeysConfig keys;
    keys[Scope_.viewer][cp("f9")] = CommandRef.init;            // unbinds nothing
    keys[Scope_.viewer][cp("f8")] = CommandRef(Command.none);   // 'none'
    keys[Scope_.tree][cp("ctrl+q")] = CommandRef(Command.treeRefresh); // unreachable

    auto merged = applyKeysOverlay(hueBindings, keys, warn);
    assert(warnings.length == 3);
    bool sawNoop, sawNone, sawCtrl;
    foreach (w; warnings)
    {
        if (w.canFind("unbinds nothing")) sawNoop = true;
        if (w.canFind("use null")) sawNone = true;
        if (w.canFind("can never fire")) sawCtrl = true;
    }
    assert(sawNoop && sawNone && sawCtrl);
    // The 'none' entry installed no row; the ctrl entry did (with a warning).
    assert(over(merged, 'f') == over(hueBindings, 'f'));
}

@("keymap_config.listedAgreesWithFiringOverAnOverlay")
@safe pure nothrow unittest
{
    // The keymap's load-bearing property, re-run over a merged table: what
    // the guide lists is exactly what would fire (KEY12 survives any
    // overlay). Built inline (no AA: pure) via the same row shapes the
    // overlay constructs.
    Binding extra;
    extra.path[0] = Chord(key: Key.char_, ch: 'j');
    extra.depth = 1;
    extra.scope_ = Scope_.viewer;
    extra.cmd = Command.viewPageDown;
    extra.desc = "page down";
    immutable(Binding)[] merged = [cast(immutable) extra] ~ hueBindings;

    static struct Listed
    {
        Binding[64] rows;
        size_t n;
        void opOpAssign(string op : "~")(in Binding b) @safe pure nothrow @nogc
        {
            if (n < rows.length)
                rows[n++] = b;
        }
        const(Binding)[] opSlice() const @safe pure nothrow @nogc return
            => rows[0 .. n];
    }

    const ctx = KeyContext.init;
    Listed listed;
    ui_keymap.bindingsAt(listed, merged, ctx);
    foreach (ref b; listed[])
    {
        const c = b.path[0];
        const ev = KeyEvent(c.key, c.ch, Mods(ctrl: c.ctrl, alt: c.alt,
            shift: c.shift == ShiftReq.yes, super_: c.super_));
        const r = ui_keymap.resolve(merged, null, ev, ctx);
        const isLeaf = b.depth == 1 && b.group.length == 0;
        if (isLeaf)
            assert(r.kind == ui_keymap.ResolveKind.command && r.cmd == b.cmd,
                "a listed command must be the one that fires");
        else
            assert(r.kind == ui_keymap.ResolveKind.group,
                "a listed prefix must actually descend");
    }
    // And the shadowed compiled row lost: j pages now.
    assert(ui_keymap.commandFor(merged, KeyEvent(Key.char_, 'j'), ctx).cmd
        == Command.viewPageDown);
}

@("keymap_config.installBindings.lanternDescribesTheOverlay")
@system unittest
{
    import keymap : commandFor, installBindings;

    // The one test that touches the global seam; restore before leaving.
    KeysConfig keys;
    keys[Scope_.viewer][cp("j")] = CommandRef(Command.viewPageDown);
    string[] warnings;
    installBindings(applyKeysOverlay(hueBindings, keys,
        (string w) @safe { warnings ~= w; }));
    scope (exit) installBindings(hueBindings);

    // The wrapper — resolution's door and the guide's — sees the rebinding.
    assert(commandFor(KeyEvent(Key.char_, 'j'), KeyContext.init).cmd
        == Command.viewPageDown);
}
