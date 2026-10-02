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

import std.typecons : Nullable;

import sparkles.input.events : Key;
import ui_keymap = sparkles.ui.keymap;
import sparkles.ui.keymap : Chord, ShiftReq;
import sparkles.ui.keymap_config : ChordParsedOf, ChordPathOf, KeysConfigOf,
    parseChordPathAs, unparseChordPathAs;
public import sparkles.ui.keymap_config : ChordError;
static import sparkles.ui.keymap_config;

import keymap : Binding, Command, leader, Scope_;

// The codec and the merge are the toolkit's (`sparkles.ui.keymap_config`);
// hue pins them to its command, scope and leader.

/// A binding path in its typed form; the wire form is the chord string.
alias ChordPath = ChordPathOf!leader;
/// ditto
alias ChordParsed = ChordParsedOf!leader;
/// The `keys` section: an overlay entry per (context, chord path).
alias KeysConfig = KeysConfigOf!(Command, Scope_, leader);
/// `Command`-or-null.
alias CommandRef = Nullable!Command;

/// Parses one path (`leader` spells `space`).
ChordParsed parseChordPath(string text) @safe pure => parseChordPathAs!leader(text);

/// The canonical spelling (`leader` unparses as `space`).
string unparseChordPath(ChordPath p) @safe pure => unparseChordPathAs!leader(p);

/// Applies the user overlay onto the compiled table — see
/// `sparkles.ui.keymap_config.applyKeysOverlay`.
immutable(Binding)[] applyKeysOverlay(immutable(Binding)[] base,
    KeysConfig keys, scope void delegate(string) @safe warn) @safe
    => sparkles.ui.keymap_config.applyKeysOverlay!leader(base, keys, warn);

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
