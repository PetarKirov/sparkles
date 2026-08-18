/**
Keyboard policy as $(B data) — the toolkit's binding-table vocabulary and its
resolution machinery (`KEY1`–`KEY11`).

An application's keyboard policy used to be an `if`/`else` chain in a frame
loop: untestable by construction, unreadable by the guide, and impossible to
overlay with configuration. This module turns it into a table the app declares
once and reads two ways — $(LREF resolve) answers "what does this key do
here", $(LREF bindingsAt) answers "which keys are available here", and the
guide ($(MREF sparkles,ui,lantern)) renders the second so it can never
disagree with the first.

$(B What the framework owns, and what the app does.) The vocabulary
($(LREF Chord), $(LREF ShiftReq), $(LREF maxPathLength)), the normalisation
(`KEY7`), the matching rules (`KEY9`/`KEY10`), and the resolution algorithm
(`KEY2`/`KEY3`) live here. The $(I payloads) are the application's: its
command enum, its scope enum, its context type, and its table. They plug in
as type parameters — a $(LREF Binding) is `Binding!(Command, Scope)` — and
the resolution entry points take the table as an argument, so one process can
host several tables (an app map, a modal surface's map, a loaded overlay).

$(B The scope enum is the precedence, and its annotations are the
semantics.) Declaration order is resolution order, exactly as an `if` chain's
statement order was. Two marker UDAs carry what the chain expressed by
`return`ing:

$(UL
    $(LI $(LREF terminalScope) — an active scope that ends resolution whether
    or not it matched (a line editor's letters are text, a Ctrl'd letter
    resolves as a chord or not at all);)
    $(LI $(LREF hidesLaterScopes) — an active scope that hides every later
    scope from $(LREF bindingsAt) (while a line editor owns the keyboard,
    nothing below it is reachable and listing it would be a lie).)
)

$(B The context type is the policy hooks.) The framework discovers, by
introspection with safe defaults, four optional members on the app's context
type:

$(UL
    $(LI `bool reachable(Scope s)` — whether a scope applies at all here
    (default: every scope, always);)
    $(LI `bool scopeActive(Scope s, in KeyEvent k)` — the same question when
    the key itself gates a scope, e.g. a Ctrl-chord scope (default:
    `reachable`);)
    $(LI `ubyte bits()` — the context's facts as bits for a row's
    `require`/`forbid` gates (default: none);)
    $(LI `bool editing()` — whether a line editor owns the keyboard, for
    $(LREF ModeReq) (default: `false`).)
)

$(B Conventions a command enum must follow.) `Cmd.init` must mean "not
bound" — resolution returns it when nothing matched, so an app's dispatch
needs no catch-all. The first-declared scope is the $(I always) scope:
$(LREF resolveAlways) reads only it, which is what lets the guide keep
fullscreen and the platform dismiss key working mid-sequence (`LTN10`).
*/
module sparkles.ui.keymap;

import sparkles.input.events : Key, KeyEvent;

// ---------------------------------------------------------------------------
// The vocabulary.
// ---------------------------------------------------------------------------

/**
Whether a binding cares about Shift.

Three states rather than a `bool`, because real tables genuinely want all
three and conflating them loses a distinction an `if` chain expressed by
$(I where) it tested `mods.shift`. `j` scrolls down whether or not Shift is
held ($(LREF ignore)); `r` refreshes only unshifted and `R` re-roots only
shifted ($(LREF no)/$(LREF yes)). A two-state encoding would need the shifted
row to be checked first and would silently break if the table were reordered —
this one does not depend on order at all.
*/
enum ShiftReq : ubyte
{
    ignore, /// Shift is not part of the binding
    no,     /// binds only when Shift is $(I not) held
    yes,    /// binds only when Shift $(I is) held
}

/**
One key in a binding's path.

`chEnd` makes a contiguous code-point range one row: `z1`–`z9` is a single
binding whose $(LREF KeyCommand.arg) is derived from which key landed, so a
whole family stays one table row and one guide item.
*/
struct Chord
{
    Key key = Key.none;
    dchar ch = 0;    /// the code point, when `key == Key.char_`
    dchar chEnd = 0; /// inclusive range end; `0` for a single code point
    ShiftReq shift;
    bool ctrl;
    bool alt;
}

/// A `char_` chord.
Chord chord(dchar ch, ShiftReq shift = ShiftReq.ignore) @safe pure nothrow @nogc
    => Chord(key: Key.char_, ch: ch, shift: shift);

/// A named-key chord.
Chord chord(Key key, ShiftReq shift = ShiftReq.ignore) @safe pure nothrow @nogc
    => Chord(key: key, shift: shift);

/// A `char_` chord spanning `lo`..`hi` inclusive.
Chord chordRange(dchar lo, dchar hi) @safe pure nothrow @nogc
    => Chord(key: Key.char_, ch: lo, chEnd: hi);

/// Marks a scope enum member whose activation ends resolution whether or not
/// a row matched — the scopes an `if` chain `return`ed from.
struct terminalScope
{
}

/// Marks a scope enum member that, while reachable, hides every later scope
/// from $(LREF bindingsAt). Narrower than $(LREF terminalScope): a Ctrl-chord
/// scope is terminal during resolution but swallows only its own chords, so
/// the scopes below it stay listable.
struct hidesLaterScopes
{
}

/// Which input mode a binding applies in. Only keys that mean different
/// things while typing than at rest need this (Escape, the platform Back).
enum ModeReq : ubyte
{
    any,
    normal,  /// only outside a line-editing mode
    editing, /// only inside one
}

/// The longest binding path a table may hold — enough for a three-level
/// leader tree. Inline, so a $(LREF Binding) carries no indirection.
enum maxPathLength = 3;

/**
One row of an application's table: a key path, what it does, and where it
applies.

`desc` and `group` exist for $(LREF bindingsAt)'s readers — the guide renders
them, and a non-empty `group` marks the row as a prefix node rather than a
command. They are `string` literals, so a row costs no allocation to read.
`reveal` marks the row that opens the guide's panel outright
($(MREF sparkles,ui,lantern) consumes it instead of executing `cmd`).
*/
struct Binding(Cmd, Scope)
if (is(Cmd == enum) && is(Scope == enum))
{
    Chord[maxPathLength] path;
    ubyte depth = 1; /// how many of `path` are used
    Scope scope_;
    Cmd cmd;
    ubyte arg;       /// for a ranged chord, the value the range's first key maps to
    ubyte require;   /// context bits that must all be set
    ubyte forbid;    /// context bits that must all be clear
    ModeReq mode;
    bool reveal;     /// executing this row shows the guide panel instead
    string desc;     /// what it does, for the guide
    /// Non-empty ⇒ a prefix node (`"fold"`), not a command. Stored bare: the
    /// panel adds the `+` marker, and a name carrying one renders `++fold`.
    string group;
}

/// Builds a one-chord row. Optional arguments are named at call sites, so a
/// table reads as a table rather than as positional noise.
Binding!(Cmd, Scope) bind(Scope, Cmd)(Scope scope_, Chord a, Cmd cmd,
    string desc, ubyte require = 0, ubyte forbid = 0,
    ModeReq mode = ModeReq.any, ubyte arg = 0, bool reveal = false)
if (is(Cmd == enum) && is(Scope == enum))
{
    Binding!(Cmd, Scope) b;
    b.path[0] = a;
    b.depth = 1;
    b.scope_ = scope_;
    b.cmd = cmd;
    b.desc = desc;
    b.require = require;
    b.forbid = forbid;
    b.mode = mode;
    b.arg = arg;
    b.reveal = reveal;
    return b;
}

/// ditto, for a two-chord path (`z c`, `<leader> e`).
Binding!(Cmd, Scope) bind(Scope, Cmd)(Scope scope_, Chord a, Chord b_, Cmd cmd,
    string desc, ubyte require = 0, ubyte forbid = 0, ubyte arg = 0,
    bool reveal = false)
if (is(Cmd == enum) && is(Scope == enum))
{
    auto b = bind(scope_, a, cmd, desc, require, forbid, ModeReq.any, arg,
        reveal);
    b.path[1] = b_;
    b.depth = 2;
    return b;
}

/// ditto, for a three-chord path (`<leader> v r`).
Binding!(Cmd, Scope) bind(Scope, Cmd)(Scope scope_, Chord a, Chord b_,
    Chord c_, Cmd cmd, string desc, ubyte require = 0, ubyte forbid = 0)
if (is(Cmd == enum) && is(Scope == enum))
{
    auto b = bind(scope_, a, b_, cmd, desc, require, forbid);
    b.path[2] = c_;
    b.depth = 3;
    return b;
}

/**
Builds a $(B prefix node) — a key that opens a group rather than running a
command.

A group row carries no `cmd`; it exists so the path is nameable and so the
guide has something to label the key with. Declare one before its children:
resolution does not require it (a deeper row makes its own prefix
descendable), but $(LREF bindingsAt) lists whichever row it meets first, and
the group's `+name` is the better label.

`Cmd` cannot be inferred (no command argument exists to infer it from), so a
caller names it — or wraps this in an app-local helper that does.
*/
Binding!(Cmd, Scope) group(Cmd, Scope)(Scope scope_, Chord a,
    string name, ubyte require = 0, ubyte forbid = 0)
if (is(Cmd == enum) && is(Scope == enum))
{
    auto b = bind(scope_, a, Cmd.init, name, require, forbid);
    b.group = name;
    return b;
}

/// ditto, for a nested group (`<leader> v`).
Binding!(Cmd, Scope) group(Cmd, Scope)(Scope scope_, Chord a,
    Chord b_, string name, ubyte require = 0, ubyte forbid = 0)
if (is(Cmd == enum) && is(Scope == enum))
{
    auto b = bind(scope_, a, b_, Cmd.init, name, require, forbid);
    b.group = name;
    return b;
}

// ---------------------------------------------------------------------------
// Matching.
// ---------------------------------------------------------------------------

/**
Whether `k` is the key `c` names, ignoring context.

$(B A modifier a chord does not name is ignored, not required to be absent)
(`KEY9`). `Ctrl-Up` scrolls because `Up` binds scrolling and says nothing
about Ctrl. Requiring equality instead would silently unbind every chorded
arrow and page key.

That is safe for letters precisely when the app's Ctrl-chord scope is
$(LREF terminalScope): a Ctrl'd letter resolves there or nowhere, so it can
never reach a plain-letter row that happens to ignore Ctrl.
*/
bool matches(in Chord c, in KeyEvent k) @safe pure nothrow @nogc
{
    if (c.ctrl && !k.mods.ctrl)
        return false;
    if (c.alt && !k.mods.alt)
        return false;
    final switch (c.shift)
    {
        case ShiftReq.ignore: break;
        case ShiftReq.no:  if (k.mods.shift) return false; break;
        case ShiftReq.yes: if (!k.mods.shift) return false; break;
    }
    if (c.key != k.key)
        return false;
    if (c.key != Key.char_)
        return true;
    return c.chEnd ? (k.ch >= c.ch && k.ch <= c.chEnd) : k.ch == c.ch;
}

/// Whether two chords name the same key — path comparison, no live event.
/// Exact, including `shift`: `g` and `Shift-G` are different bindings and must
/// both be listed, so the guide's de-duplication must not conflate them.
bool sameKey(in Chord a, in Chord b) @safe pure nothrow @nogc
    => a.key == b.key && a.ch == b.ch && a.chEnd == b.chEnd
    && a.shift == b.shift && a.ctrl == b.ctrl && a.alt == b.alt;

/**
Whether a table chord accepts a chord already typed — prefix comparison
(`KEY10`).

Deliberately $(I not) $(LREF sameKey). A pending chord records what the user
actually pressed (Shift held or not); a table row may be shift-agnostic
($(LREF ShiftReq.ignore)), in which case it accepts either. Comparing those
exactly would make every prefix under a shift-agnostic row unreachable.

The case that forced this: `g` opens a goto group while `Shift-G` jumps to
the bottom. The group row has to be `ShiftReq.no` so `G` is not swallowed by
it — and then a typed `g`, which records `ShiftReq.no`, has to still match it.
*/
bool acceptsTyped(in Chord table, in Chord typed) @safe pure nothrow @nogc
    => table.key == typed.key && table.ch == typed.ch
    && table.ctrl == typed.ctrl && table.alt == typed.alt
    && (table.shift == ShiftReq.ignore || table.shift == typed.shift);

/**
Normalises a key event so one table row covers every producer's spelling of it
(`KEY7`).

Producers disagree about how a shifted letter arrives. raylib's
`GetCharPressed` yields the SHIFTED character ('R') and separately reports
`shift`; a terminal may send 'R' with no modifier at all; a synthesised event
may send 'r' + shift. All three mean one keystroke, so normalise here — once —
rather than spelling both cases in every table row, or asking each producer to
normalise, which is how producers drift apart again.
*/
KeyEvent normalise(in KeyEvent raw) @safe pure nothrow @nogc
{
    KeyEvent k = raw;
    if (k.key == Key.char_ && k.ch >= 'A' && k.ch <= 'Z')
    {
        k.ch += 'a' - 'A';
        k.mods.shift = true;
    }
    return k;
}

/// What a key resolved to under a prefix.
enum ResolveKind : ubyte
{
    none,    /// not bound here
    group,   /// a prefix node — more keys are expected
    command, /// a command, ready to run
}

/// ditto
struct Resolution(Cmd)
if (is(Cmd == enum))
{
    ResolveKind kind;
    Cmd cmd;
    ubyte arg;
    bool reveal; /// the matched row asks for the guide panel, not execution
}

/// A resolved command plus its argument. A struct rather than one enum member
/// per argument value, so a ranged family stays one row in the table and one
/// case at the call site.
struct KeyCommand(Cmd)
if (is(Cmd == enum))
{
    Cmd cmd;
    ubyte arg;
}

// ---------------------------------------------------------------------------
// The context hooks (discovered on the app's context type, with defaults).
// ---------------------------------------------------------------------------

private bool reachableOf(Scope, Ctx)(Scope s, in Ctx ctx)
{
    static if (__traits(hasMember, Ctx, "reachable"))
        return ctx.reachable(s);
    else
        return true;
}

private bool scopeActiveOf(Scope, Ctx)(Scope s, in Ctx ctx, in KeyEvent k)
{
    static if (__traits(hasMember, Ctx, "scopeActive"))
        return ctx.scopeActive(s, k);
    else
        return reachableOf(s, ctx);
}

private ubyte bitsOf(Ctx)(in Ctx ctx)
{
    static if (__traits(hasMember, Ctx, "bits"))
        return ctx.bits;
    else
        return 0;
}

private bool editingOf(Ctx)(in Ctx ctx)
{
    static if (__traits(hasMember, Ctx, "editing"))
        return ctx.editing;
    else
        return false;
}

/// Whether the scope enum member named `member` carries `Marker`.
private template scopeMarked(Scope, string member, Marker)
{
    import std.meta : staticIndexOf;

    enum scopeMarked = staticIndexOf!(Marker,
        __traits(getAttributes, __traits(getMember, Scope, member))) != -1;
}

/// Whether `b`'s context gates are satisfied — the bit gates, plus the
/// input-mode requirement Escape and Back need.
private bool gated(B, Ctx)(in B b, in Ctx ctx)
{
    const bits = bitsOf(ctx);
    if ((bits & b.require) != b.require)
        return false;
    if (bits & b.forbid)
        return false;
    final switch (b.mode)
    {
        case ModeReq.any:     return true;
        case ModeReq.normal:  return !editingOf(ctx);
        case ModeReq.editing: return editingOf(ctx);
    }
}

private alias CmdOf(B) = typeof(B.init.cmd);
private alias ScopeOf(B) = typeof(B.init.scope_);

// ---------------------------------------------------------------------------
// Resolution.
// ---------------------------------------------------------------------------

/**
Resolves `raw` against `table`, given the chords already typed.

A lookup walking the scope enum in declaration order (`KEY2`). That order
mirrors an app's frame-loop precedence, which is load-bearing: a Ctrl chord
resolves before the plain letter, an open input mode claims
Enter/Escape/Backspace before anything else sees them, and a focused pane
claims `j` before the fallback pane does. An active $(LREF terminalScope)
ends the search whether or not it matched.

A key resolves to $(LREF ResolveKind.group) when the row it matched has more
chords after this one — so a prefix is descendable whether or not anyone
wrote an explicit $(LREF group) row for it. That is what keeps the table's
shape and its behaviour from being able to disagree.
*/
Resolution!(CmdOf!B) resolve(B, Ctx)(scope const(B)[] table,
    scope const Chord[] prefix, in KeyEvent raw, in Ctx ctx)
{
    alias Cmd = CmdOf!B;
    alias Scope = ScopeOf!B;
    const k = normalise(raw);
    const depth = prefix.length;

    static foreach (s; __traits(allMembers, Scope))
    {{
        enum sc = __traits(getMember, Scope, s);
        if (scopeActiveOf(sc, ctx, k))
        {
            foreach (ref b; table)
            {
                if (b.scope_ != sc || b.depth <= depth || !gated(b, ctx))
                    continue;
                bool under = true;
                foreach (i, ref p; prefix)
                    if (!acceptsTyped(b.path[i], p))
                    {
                        under = false;
                        break;
                    }
                if (!under || !matches(b.path[depth], k))
                    continue;
                if (b.depth > depth + 1)
                    return Resolution!Cmd(ResolveKind.group);
                if (b.group.length)
                    return Resolution!Cmd(ResolveKind.group);
                const arg = b.path[depth].chEnd
                    ? cast(ubyte)(b.arg + (k.ch - b.path[depth].ch))
                    : b.arg;
                return Resolution!Cmd(ResolveKind.command, b.cmd, arg,
                    b.reveal);
            }
            static if (scopeMarked!(Scope, s, terminalScope))
                return Resolution!Cmd(ResolveKind.none);
        }
    }}
    return Resolution!Cmd(ResolveKind.none);
}

/**
The keymap, for a caller with no pending prefix.

Returns `Cmd.init` both when `k` is unbound and when it opens a group — a
caller using this entry point has nowhere to put the pending chord, so a
prefix key is simply not a command to it. Drive
$(REF step, sparkles,ui,lantern) instead to reach anything behind a prefix.
*/
KeyCommand!(CmdOf!B) commandFor(B, Ctx)(scope const(B)[] table,
    in KeyEvent raw, in Ctx ctx)
{
    alias Cmd = CmdOf!B;
    const r = resolve(table, null, raw, ctx);
    return r.kind == ResolveKind.command
        ? KeyCommand!Cmd(r.cmd, r.arg) : KeyCommand!Cmd(Cmd.init);
}

/// Resolves only the first-declared scope's bindings — the always-available
/// ones that outrank a pending prefix, so Escape-level keys and fullscreen
/// keep working mid-sequence (`LTN10`).
Resolution!(CmdOf!B) resolveAlways(B, Ctx)(scope const(B)[] table,
    in KeyEvent raw, in Ctx ctx)
{
    alias Cmd = CmdOf!B;
    alias Scope = ScopeOf!B;
    enum firstScope = __traits(getMember, Scope, __traits(allMembers, Scope)[0]);
    const k = normalise(raw);
    foreach (ref b; table)
    {
        if (b.scope_ != firstScope || b.depth != 1 || !gated(b, ctx))
            continue;
        if (matches(b.path[0], k))
            return Resolution!Cmd(ResolveKind.command, b.cmd, b.arg, b.reveal);
    }
    return Resolution!Cmd(ResolveKind.none);
}

/**
The other direction: which of `table`'s bindings are reachable in `ctx`
(`KEY3`).

$(LREF commandFor) answers "what does this key do"; this answers "which keys
are available", which is what the guide renders and what a config dump would
list. Rows are written to `sink` in resolution order, so the first row for a
given key is the one that would actually fire — a shadowed duplicate (the
same key bound in two scopes) is dropped rather than listed twice.

`sink` must accept `~=` and be sliceable with `[]` — a
$(REF SmallBuffer, sparkles,base,smallbuffer) is the intended argument, and
the whole walk allocates nothing.
*/
void bindingsAt(Sink, B, Ctx)(ref Sink sink, scope const(B)[] table,
    in Ctx ctx, scope const Chord[] prefix = null)
{
    alias Scope = ScopeOf!B;
    static foreach (s; __traits(allMembers, Scope))
    {{
        enum sc = __traits(getMember, Scope, s);
        if (reachableOf(sc, ctx))
        {
            foreach (ref b; table)
            {
                if (b.scope_ != sc || b.depth <= prefix.length || !gated(b, ctx))
                    continue;
                bool underPrefix = true;
                foreach (i, ref p; prefix)
                    if (!acceptsTyped(b.path[i], p))
                    {
                        underPrefix = false;
                        break;
                    }
                if (!underPrefix)
                    continue;
                const next = b.path[prefix.length];
                bool shadowed;
                foreach (ref seen; sink[])
                    if (sameKey(seen.path[prefix.length], next))
                    {
                        shadowed = true;
                        break;
                    }
                if (!shadowed)
                    sink ~= b;
            }
            static if (scopeMarked!(Scope, s, hidesLaterScopes))
                return;
        }
    }}
}

// ---------------------------------------------------------------------------
// Tests — a miniature app exercising the machinery. Real policies (their
// tables and contexts) are tested where they are declared.
//
// `UiKeymapFixtures`, not `unittest`: these are module-scope declarations,
// so a downstream `-unittest` build analysing this import would instantiate
// `Binding!(TestCommand, TestScope)` and expect its symbols from this
// library — compiled without `-unittest`, which has none (a DMD link
// failure LDC's local emission hides). The version is set only by this
// package's own unittest configuration.
// ---------------------------------------------------------------------------

version (UiKeymapFixtures)
{
    import sparkles.input.events : Mods;

    /// The shape any consumer mirrors: a command enum whose `.init` means
    /// "none", a scope enum in precedence order with the marker UDAs, and a
    /// context type carrying the four hooks.
    enum TestCommand : ubyte
    {
        none,
        leave, accept, copy,
        refresh, reroot, paneDown,
        foldClose, foldLevel,
        next, down, showAll,
    }

    /// ditto
    enum TestScope : ubyte
    {
        always,
        @terminalScope @hidesLaterScopes input,
        @terminalScope ctrl,
        pane,
        shared_,
    }

    /// ditto
    struct TestContext
    {
        bool typing;
        bool paneFocused;
        bool hasThing;

    @safe pure nothrow @nogc const:

        bool editing() => typing;
        ubyte bits() => hasThing ? 1 : 0;

        bool reachable(TestScope s)
        {
            final switch (s)
            {
                case TestScope.always:  return true;
                case TestScope.input:   return typing;
                case TestScope.ctrl:    return true;
                case TestScope.pane:    return paneFocused;
                case TestScope.shared_: return true;
            }
        }

        bool scopeActive(TestScope s, in KeyEvent k)
            => s == TestScope.ctrl
                ? (k.mods.ctrl && k.key == Key.char_)
                : reachable(s);
    }

    alias TestBinding = Binding!(TestCommand, TestScope);

    immutable TestBinding[] testBindings = [
        bind(TestScope.always, chord(Key.f11), TestCommand.leave, "leave"),
        bind(TestScope.input, chord(Key.enter), TestCommand.accept, "accept"),
        bind(TestScope.ctrl, Chord(key: Key.char_, ch: 'c', ctrl: true),
            TestCommand.copy, "copy"),
        bind(TestScope.pane, chord('r', ShiftReq.no), TestCommand.refresh,
            "refresh"),
        bind(TestScope.pane, chord('r', ShiftReq.yes), TestCommand.reroot,
            "re-root"),
        bind(TestScope.pane, chord('j'), TestCommand.paneDown, "pane down"),
        group!TestCommand(TestScope.shared_, chord('z'), "fold"),
        bind(TestScope.shared_, chord('z'), chord('c'), TestCommand.foldClose,
            "close fold"),
        bind(TestScope.shared_, chord('z'), chordRange('1', '9'),
            TestCommand.foldLevel, "fold level", arg: 1),
        bind(TestScope.shared_, chord('j'), TestCommand.down, "down"),
        bind(TestScope.shared_, chord('n'), TestCommand.next, "next thing",
            require: 1),
        bind(TestScope.shared_, chord('?'), TestCommand.showAll,
            "all bindings", reveal: true),
    ];

    KeyCommand!TestCommand tch(dchar c, TestContext ctx = TestContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => commandFor(testBindings, KeyEvent(Key.char_, c, m), ctx);
    KeyCommand!TestCommand tnk(Key k, TestContext ctx = TestContext.init,
        Mods m = Mods()) @safe pure nothrow @nogc
        => commandFor(testBindings, KeyEvent(k, 0, m), ctx);
}

@("ui.keymap.shiftedLettersNormaliseAcrossProducers")
@safe pure nothrow @nogc
unittest
{
    const pane = TestContext(paneFocused: true);

    // The three spellings a real producer may use for Shift-R, all resolving
    // to one command: synthesised lowercase+shift, raylib's shifted character
    // +shift, and a bare capital.
    assert(tch('r', pane, Mods(shift: true)).cmd == TestCommand.reroot);
    assert(tch('R', pane, Mods(shift: true)).cmd == TestCommand.reroot);
    assert(tch('R', pane).cmd == TestCommand.reroot);

    // …and the unshifted key still means the other thing; a shift-agnostic
    // row is not affected by normalisation inventing a shift.
    assert(tch('r', pane).cmd == TestCommand.refresh);
    assert(tch('j', pane).cmd == TestCommand.paneDown);
    assert(tch('J', pane).cmd == TestCommand.paneDown, "shift-j is still down");
}

@("ui.keymap.scopeOrderIsThePrecedence")
@safe pure nothrow @nogc
unittest
{
    // The same key resolves per focus: the pane scope is declared before the
    // fallback, so it wins while reachable, and vanishes when it is not.
    assert(tch('j', TestContext(paneFocused: true)).cmd == TestCommand.paneDown);
    assert(tch('j').cmd == TestCommand.down);
}

@("ui.keymap.terminalScopeEndsResolution")
@safe pure nothrow @nogc
unittest
{
    const ctrl = Mods(ctrl: true);
    // A Ctrl'd letter resolves in the Ctrl scope or nowhere — never falling
    // through to a plain-letter row that happens to ignore Ctrl.
    assert(tch('c', TestContext.init, ctrl).cmd == TestCommand.copy);
    assert(tch('j', TestContext.init, ctrl).cmd == TestCommand.none);

    // While typing, a letter is text: the input scope is terminal, so `j`
    // reaches no command, but the input scope's own rows still fire.
    const typing = TestContext(typing: true);
    assert(tch('j', typing).cmd == TestCommand.none);
    assert(tnk(Key.enter, typing).cmd == TestCommand.accept);
}

@("ui.keymap.groupsDescendAndRangesCarryTheArgument")
@safe pure nothrow @nogc
unittest
{
    // A prefix key is a group to `resolve` and not a command to `commandFor`.
    assert(resolve(testBindings, null, KeyEvent(Key.char_, 'z'),
        TestContext.init).kind == ResolveKind.group);
    assert(tch('z').cmd == TestCommand.none);

    // What the prefix leads to is resolvable directly, and a ranged row
    // derives its argument from which key landed.
    const Chord[1] z = [chord('z')];
    assert(resolve(testBindings, z, KeyEvent(Key.char_, 'c'), TestContext.init)
        == Resolution!TestCommand(ResolveKind.command, TestCommand.foldClose));
    assert(resolve(testBindings, z, KeyEvent(Key.char_, '3'), TestContext.init)
        == Resolution!TestCommand(ResolveKind.command, TestCommand.foldLevel, 3));
    assert(resolve(testBindings, z, KeyEvent(Key.char_, '0'),
        TestContext.init).kind == ResolveKind.none, "below the range");
}

@("ui.keymap.contextBitsGateRows")
@safe pure nothrow @nogc
unittest
{
    // A gated row is unbound rather than a no-op the caller must filter.
    assert(tch('n').cmd == TestCommand.none);
    assert(tch('n', TestContext(hasThing: true)).cmd == TestCommand.next);
}

@("ui.keymap.revealRidesTheResolution")
@safe pure nothrow @nogc
unittest
{
    const r = resolve(testBindings, null, KeyEvent(Key.char_, '?'),
        TestContext.init);
    assert(r.kind == ResolveKind.command && r.reveal,
        "a reveal row resolves as a command carrying the reveal flag");
    const plain = resolve(testBindings, null, KeyEvent(Key.char_, 'j'),
        TestContext.init);
    assert(!plain.reveal);
}

@("ui.keymap.resolveAlwaysReadsOnlyTheFirstScope")
@safe pure nothrow @nogc
unittest
{
    assert(resolveAlways(testBindings, KeyEvent(Key.f11), TestContext.init).cmd
        == TestCommand.leave);
    // A shared_-scope binding is not an always binding.
    assert(resolveAlways(testBindings, KeyEvent(Key.char_, 'j'),
        TestContext.init).kind == ResolveKind.none);
}

@("ui.keymap.bindingsAtEnumeratesWhatWouldFire")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // The property that makes the table worth having: whatever `bindingsAt`
    // lists, `resolve` actually does — checked at every level, over every
    // context the fixture can express.
    static void checkLevel(scope const Chord[] prefix, in TestContext ctx,
        int depthLeft)
    {
        SmallBuffer!(TestBinding, 32) listed;
        bindingsAt(listed, testBindings, ctx, prefix);

        foreach (ref b; listed[])
        {
            const c = b.path[prefix.length];
            const ev = KeyEvent(c.key, c.ch, Mods(ctrl: c.ctrl, alt: c.alt,
                shift: c.shift == ShiftReq.yes));
            const r = resolve(testBindings, prefix, ev, ctx);

            const isLeaf = b.depth == prefix.length + 1 && b.group.length == 0;
            if (isLeaf)
                assert(r.kind == ResolveKind.command && r.cmd == b.cmd,
                    "a listed command must be the one that fires");
            else
            {
                assert(r.kind == ResolveKind.group,
                    "a listed prefix must actually descend");
                if (depthLeft > 0)
                {
                    Chord[maxPathLength] next;
                    next[0 .. prefix.length] = prefix[];
                    next[prefix.length] = c;
                    checkLevel(next[0 .. prefix.length + 1], ctx, depthLeft - 1);
                }
            }
        }

        // …and nothing is listed twice: a key bound in two scopes appears
        // once, as the row that would win.
        foreach (i, ref a; listed[])
            foreach (j, ref b; listed[])
                assert(i == j
                    || !sameKey(a.path[prefix.length], b.path[prefix.length]),
                    "a shadowed duplicate must not be listed");
    }

    foreach (ubyte bits; 0 .. 8)
    {
        const ctx = TestContext(
            typing:      (bits & 1) != 0,
            paneFocused: (bits & 2) != 0,
            hasThing:    (bits & 4) != 0,
        );
        checkLevel(null, ctx, maxPathLength);
    }
}

@("ui.keymap.hidingScopeCutsTheListing")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // While a line editor owns the keyboard, nothing below the input scope
    // is reachable, so nothing below it may be listed.
    SmallBuffer!(TestBinding, 32) listed;
    bindingsAt(listed, testBindings, TestContext(typing: true));
    foreach (ref b; listed[])
        assert(b.scope_ == TestScope.always || b.scope_ == TestScope.input,
            "a hidden scope must not be listed while the editor types");
}

@("ui.keymap.hooksAreOptional")
@safe pure nothrow @nogc
unittest
{
    // A context type with no hooks at all gets the defaults: every scope
    // reachable, no bit gates, not editing. The machinery must not require
    // the full protocol just to resolve a flat table.
    static struct BareContext
    {
    }

    enum BareScope : ubyte
    {
        only,
    }

    static immutable Binding!(TestCommand, BareScope)[] flat = [
        bind(BareScope.only, chord('x'), TestCommand.leave, "leave"),
    ];
    assert(commandFor(flat, KeyEvent(Key.char_, 'x'), BareContext()).cmd
        == TestCommand.leave);
    assert(commandFor(flat, KeyEvent(Key.char_, 'y'), BareContext()).cmd
        == TestCommand.none);
}
