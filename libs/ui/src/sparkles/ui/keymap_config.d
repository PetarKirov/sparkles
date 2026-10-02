/**
User-configurable keybindings as data: the wire form of a binding overlay, the
chord-path codec it is written in, and the merge onto an application's
compiled table (`KEY12`).

An application's config file carries a `keys` section shaped
`context → chord-path → command-or-null`: contexts are the scope enum's member
names, commands the command enum's (so an unknown one is a $(I located decode
error), never a silent no-op), and a chord path is a human-writable string
(`"ctrl+c"`, `"shift+r"`, `"z 1-9"`, `"leader u s"`) converted through
`@WireConvert` into the keymap's own `Chord[]` vocabulary.

The overlay is $(B row by row), never a replacement: rebinding `j` leaves
every other row alone, `null` unbinds, and a path claims its whole subtree
(`"z": null` removes the fold family). The merged table is what the
application resolves and what its guide lists, so the two cannot disagree.

Everything here is generic over the application's command and scope enums and
over its $(B leader): the code point the token `leader` (and `space`) spells.
An application whose leader is not a plain key writes its rows with a
placeholder code point and substitutes the real chord after merging.

Chord grammar:
---
path      := chord (" " chord)*                 (1..3 chords)
chord     := (mod "+")* keytoken
mod       := "ctrl" | "alt" | "shift" | "super"
keytoken  := keyname | range | printable
keyname   := "space" | "leader" | "up" | ... | "f12"
range     := printable "-" printable            ("1-9", one ranged row)
---
*/
module sparkles.ui.keymap_config;

import std.typecons : Nullable;

import sparkles.input.events : Key,
    InputChordPath = ChordPath,
    parseInputChordPath = parseChordPath,
    unparseInputChordPath = unparseChordPath;
import sparkles.ui.keymap : Chord, maxPathLength, ShiftReq;
import sparkles.wired.policy : WireConvert;

// ─────────────────────────────────────────────────────────────────────────────
// The wire form.
// ─────────────────────────────────────────────────────────────────────────────

/// A chord-parse failure, Expected-shaped for wired's converter seam.
struct ChordError
{
    string msg;
}

/**
The codec for one leader: the typed path, its parse result and the two
conversions, declared together so the path's `@WireConvert` and the parse
result that contains the path resolve within one instance.
*/
template ChordCodec(dchar leader)
{
    /// A binding path in its typed form; the wire form is the chord string,
    /// with `leader` spelling the code point `leader`.
    @WireConvert!(unparse, parse)
    struct ChordPath
    {
        Chord[maxPathLength] path;
        ubyte depth = 1;
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

    /// Parses one path. Total over its grammar; every rejection carries a
    /// reason wired renders as a located decode error at the offending key.
    ChordParsed parse(string text) @safe pure
    {
        InputChordPath p;
        string err;
        if (!parseInputChordPath(text, p, err, leader))
            return ChordParsed(ChordPath.init, ChordError(err), true);
        ChordPath res;
        res.path = p.path;
        res.depth = p.depth;
        return ChordParsed(res);
    }

    /// The canonical spelling: mods in `ctrl+alt+shift+super` order, named
    /// keys by name, chords joined by single spaces. `parse ∘ unparse` is the
    /// identity on canonical spellings.
    string unparse(ChordPath p) @safe pure
    {
        InputChordPath ip;
        ip.path = p.path;
        ip.depth = p.depth;
        return unparseInputChordPath(ip, leader);
    }
}

/// The typed path for a leader.
alias ChordPathOf(dchar leader) = ChordCodec!leader.ChordPath;
/// ditto
alias ChordParsedOf(dchar leader) = ChordCodec!leader.ChordParsed;
/// ditto
alias parseChordPathAs(dchar leader) = ChordCodec!leader.parse;
/// ditto
alias unparseChordPathAs(dchar leader) = ChordCodec!leader.unparse;

/// The `keys` section: an overlay entry per (context, chord path); `null`
/// unbinds.
alias KeysConfigOf(Cmd, Scope, dchar leader) = Nullable!Cmd[ChordPathOf!leader][Scope];

// ─────────────────────────────────────────────────────────────────────────────
// The overlay merge.
// ─────────────────────────────────────────────────────────────────────────────

private alias CmdOf(B) = typeof(B.init.cmd);
private alias ScopeOf(B) = typeof(B.init.scope_);

/**
Applies the user overlay `keys` onto the compiled table `base`.

Each entry is matched against the $(B base) table only — never against other
entries — so entries commute and the result is independent of AA iteration
order. A match is same scope + the user path claiming the row: `row.depth >=
user.depth` with each user chord equal to the row's (a user `ignore` shift
matches any row shift; `yes` matches only `yes`; a single code point does
$(B not) match a range — unbind the whole range instead). `null` drops the
matched rows; a command drops them and prepends one unconditional row, whose
description is borrowed from the first base row carrying that command so the
guide still explains it. New rows sort by (scope, canonical spelling) and go
$(B before) the surviving base rows: within a scope, first row wins, so a user
row shadows what it did not delete; base survivors keep their relative order.

The wire shape has no vocabulary for `require`/`forbid`/`ModeReq` gates, so an
assignment replaces the whole family a path meant, gates included.

$(B Design by introspection.) A scope enum with both an `always` and a `ctrl`
member (a Ctrl-chord scope resolved first) gets one more warning: a
Ctrl+letter bound anywhere else can never fire.
*/
immutable(B)[] applyKeysOverlay(dchar leader, B, K)(immutable(B)[] base, K keys,
    scope void delegate(string) @safe warn) @safe
if (is(K == KeysConfigOf!(CmdOf!B, ScopeOf!B, leader)))
{
    import std.algorithm.sorting : sort;

    alias Cmd = CmdOf!B;
    alias Scope = ScopeOf!B;
    alias ChordPath = ChordPathOf!leader;
    alias spell = unparseChordPathAs!leader;

    if (!keys.length)
        return base;

    bool[] dropped = new bool[base.length];
    B[] added;

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

            const where = "keys." ~ enumName(scope_) ~ "[\"" ~ spell(cpath) ~ "\"]";
            if (cmdRef.isNull)
            {
                if (!matched && warn !is null)
                    warn(where ~ ": null unbinds nothing (typo?)");
                continue;
            }
            const cmd = cmdRef.get;
            if (cmd == Cmd.init)
            {
                if (warn !is null)
                    warn(where ~ ": '" ~ enumName(cmd) ~ "' does not unbind — use null");
                continue;
            }
            const last = cpath.path[cpath.depth - 1];
            static if (__traits(hasMember, Scope, "ctrl") && __traits(hasMember, Scope, "always"))
                if (last.ctrl && last.key == Key.char_ && scope_ != Scope.ctrl
                    && scope_ != Scope.always && warn !is null)
                    warn(where ~ ": a ctrl+letter outside the 'ctrl' context can "
                        ~ "never fire (the ctrl scope resolves it first)");

            B b;
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
    static string shiftless(in B b) @safe pure
    {
        auto p = ChordPath(b.path, b.depth);
        foreach (i; 0 .. p.depth)
            p.path[i].shift = ShiftReq.ignore;
        return spell(p);
    }

    static int agnostic(in B b) @safe pure nothrow @nogc
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

    B[] merged;
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

/// An enum member's spelling for a warning: its name, a keyword-dodging
/// trailing underscore dropped (`shared_` → `shared`).
private string enumName(E)(E e) @safe pure nothrow @nogc
{
    final switch (e)
    {
        static foreach (m; __traits(allMembers, E))
        {
            case __traits(getMember, E, m):
                return m[$ - 1] == '_' ? m[0 .. $ - 1] : m;
        }
    }
}

/// The first base row's description for `cmd`, else the member name — so a
/// rebound command still reads as itself in the guide.
private string descFor(B, Cmd)(immutable(B)[] base, Cmd cmd) @safe pure nothrow @nogc
{
    foreach (ref row; base)
        if (row.cmd == cmd && !row.group.length && row.desc.length)
            return row.desc;
    return enumName(cmd);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests (the full behaviour is pinned by hue's `keymap_config` over its own
// table; these pin the generic seams: a non-space leader, a scope enum
// without `ctrl`, and the wire round trip).
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.ui.keymap : Binding, bind, chord;

    private enum TCmd : ubyte { none, copy, paste, newTab }
    private enum TScope : ubyte { overlay, pane }
    private enum dchar tLeader = '';
    private alias TBinding = Binding!(TCmd, TScope);

    private immutable TBinding[] tTable = [
        bind(TScope.pane, chord(tLeader), chord('t'), TCmd.newTab, "new tab"),
        bind(TScope.pane, chord('c'), TCmd.copy, "copy"),
    ];
}

@("ui.keymap_config.aPlaceholderLeaderRoundTrips")
@safe pure unittest
{
    const r = parseChordPathAs!tLeader("leader t");
    assert(!r.bad, r.error.msg);
    assert(r.value.depth == 2 && r.value.path[0].ch == tLeader);
    assert(unparseChordPathAs!tLeader(r.value) == "space t",
        "the placeholder is spelled as the leader's canonical name");
    assert(parseChordPathAs!tLeader("ctlr+c").bad);
}

@("ui.keymap_config.applyKeysOverlay.genericOverTheTable")
@safe unittest
{
    KeysConfigOf!(TCmd, TScope, tLeader) keys;
    keys[TScope.pane][parseChordPathAs!tLeader("leader t").value] = Nullable!TCmd.init;
    keys[TScope.pane][parseChordPathAs!tLeader("v").value] = TCmd.paste;
    string[] warnings;
    const merged = applyKeysOverlay!tLeader(tTable, keys, (string w) { warnings ~= w; });
    assert(warnings.length == 0, warnings[0]);
    assert(merged.length == 2);
    assert(merged[0].cmd == TCmd.paste && merged[0].desc == "paste",
        "a command no base row carries is described by its name");
    assert(merged[1].cmd == TCmd.copy, "the unbound leader row is gone");
}

@("ui.keymap_config.keysConfig.wiredRoundTrip")
@system unittest
{
    import std.algorithm.searching : canFind;

    import sparkles.wired.json : fromJSON, toJSON;

    alias Keys = KeysConfigOf!(TCmd, TScope, tLeader);
    auto r = fromJSON!Keys(`{"pane":{"leader t":"newTab","ctrl+shift+c":null}}`);
    assert(!r.hasError, r.error.toString);
    assert(r.value[TScope.pane][parseChordPathAs!tLeader("leader t").value].get == TCmd.newTab);

    auto text = toJSON(r.value);
    assert(!text.hasError);
    assert(text.value[].canFind(`"space t":"newTab"`), text.value[].idup);

    auto bad = fromJSON!Keys(`{"pane":{"ctlr+c":"copy"}}`);
    assert(bad.hasError && bad.error.path[].canFind("ctlr+c"), bad.error.toString);
}
