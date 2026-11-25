/**
The top-down (Clay-style) builder the `markup` DSL drives.

`ui.column(site, gap: 1)` opens an element and returns an `Opened` whose
destructor closes it: the element's fit size is computed at close from its
children (Clay's fusion), and `env` pops with it. Leaves are added in one
call. Nothing here lays out or paints; the tables record what the frame
built, so the demo can dump it and dispatch messages.

Identity is the call site: every element is opened with a `Site`, a
compile-time constant the markup generator derives from the element's
position in the source (file, line, column). An element's id mixes its site
into the id of the enclosing scope, so `if` cannot shift a sibling's id, a
component placed twice gets two ids (its placement site differs), and a
keyed `foreach` mixes in the key.

Messages are checked at compile time: every builder call that records a
message names the type its scope expects (`on!(Expected)`), which the
markup generator fills in from the static `mapMsg` nesting.
*/
module ui_sketch;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.lifetime : emplace;
import std.algorithm.searching : all;
import std.experimental.allocator.building_blocks.region : InSituRegion;
import std.meta : Filter;
import std.traits : Parameters, ReturnType;

import sparkles.base.buffer : BoundedSink, HeapBuffer, InlineBuffer, Storage, UniqueBuffer;
import sparkles.base.pool.text_pool : TextPool;
import sparkles.base.text.enums : enumMemberName;
import sparkles.base.text.writers : writeIntegerPadded, writeText;

public import markup : markup, fragment;
import markup : fnv;

// ── forced named arguments (docs/guidelines/idioms/forced-named-arguments) ──

private struct NamedOnly {}

// ── ids, env, text, messages ───────────────────────────────────────────────

/// A call site: a compile-time constant from the markup generator.
struct Site { ulong value; }

/// A handle to a node this frame built.
struct Node
{
    uint index = uint.max;
    bool isSet() const @safe pure nothrow @nogc => index != uint.max;
}

enum Slot : ubyte { code, heading, dim }
enum Density : ubyte { comfortable, compact }
enum Layout : ubyte { wide, touch }

/// Context that changes *what gets built*. Pushed on open, popped on close.
struct Env
{
    Layout layout;
    Density density;

    EnvOverride withDensity(Density d) const @safe pure nothrow @nogc
        => EnvOverride(active: true, env: Env(layout: layout, density: d));
}

/// An env a container sets for its subtree.
struct EnvOverride
{
    bool active;
    Env env;
}

private struct FrameText {}
private alias FrameTextPool = TextPool!(FrameText, 512, 4096);
alias TextId = FrameTextPool.Id;

struct MsgRef
{
    uint index = uint.max;
    bool isSet() const @safe pure nothrow @nogc => index != uint.max;
}

/// A type's identity for the runtime message walk, computed at compile time.
enum ulong typeKey(T) = fnv(T.mangleof);

// ── message scopes, at compile time ────────────────────────────────────────

/// `@emits!M` on a component: the message type its markup sends.
struct emits(M) { alias Msg = M; }

/// The scope of a component without `@emits`: it sends nothing itself, and
/// fragments it receives keep the message type of the place they were written.
struct Transparent {}

private enum isEmits(alias A) = is(A == emits!M, M);

/// The message type `fn` declares with `@emits!M`, or `Transparent`.
template EmitsOf(alias fn)
{
    alias found = Filter!(isEmits, __traits(getAttributes, fn));
    static if (found.length)
        alias EmitsOf = found[0].Msg;
    else
        alias EmitsOf = Transparent;
}

/// The function a markup's anchor sits in, skipping the delegate literals
/// that fragments are generated as.
template EnclosingComponent(alias sym)
{
    alias up = __traits(parent, sym);
    static if (__traits(identifier, up).length > 2 && __traits(identifier, up)[0 .. 2] == "__")
        alias EnclosingComponent = EnclosingComponent!up;
    else
        alias EnclosingComponent = up;
}

/// Whether a component sending `EmitsOf!fn` may be placed where `Scope` is expected.
enum bool placeable(alias fn, Scope) = is(EmitsOf!fn == Transparent)
    || (!is(Scope == Transparent) && is(EmitsOf!fn == Scope));

/// A fragment's static tag: the message type of the scope it was written in.
struct MsgTag(M) { alias Msg = M; }

/// The message type a fragment `F` was written under (`void` if `F` is not one).
template FragMsg(F)
{
    static if (is(F == delegate) && Parameters!F.length >= 2 && is(Parameters!F[1] == MsgTag!M, M))
        alias FragMsg = M;
    else
        alias FragMsg = void;
}

enum bool isFragment(F) = !is(FragMsg!F == void);

/// A value passed to a component fits `Scope` (non-fragments always do).
enum bool fragmentFits(F, Scope) = !isFragment!F || is(Scope == Transparent) || is(FragMsg!F == Scope);

/// A fragment type with no arguments, for declarations outside markup.
alias Fragment(M) = void delegate(ref Ui, MsgTag!M) @safe pure nothrow @nogc;

alias MapFrom(alias fn) = Parameters!fn[0];
alias MapTo(alias fn) = ReturnType!fn;

// ── the tables ─────────────────────────────────────────────────────────────

private enum Kind : ubyte { column, row, label, toggle, numberField, keyValue, mapMsg, memo }

private alias ApplyThunk = void function(scope const(void)* from, scope void* to) @system;

private struct MapRec { ulong from, to; ApplyThunk apply; }

private struct NodeRec
{
    Kind kind;
    uint parent = uint.max, firstChild = uint.max, lastChild = uint.max, next = uint.max;
    ulong id;
    TextId text, text2;
    MsgRef msg;
    Slot slot;
    int gap, value;
    bool on, disabled, keyed;
    EnvOverride env;
    MapRec map;
    Density builtWith;
    uint w, h;            // the fit size, final once the node closes
    uint accW, accH, n;   // children so far
}

private struct MsgRec
{
    ulong typeKey;
    const(void)[] value;
    ApplyThunk payload;
    ulong payloadKey;
}

/// An open scope: an element (`node` set) or an identity scope (`enter`/`keyed`).
private struct Frame
{
    uint node = uint.max;
    ulong idScope;
    Env savedEnv;
    bool keyScope;
}

/**
The frame's builder. `env` is read-only to components; open and close are
the only writers. Tables are the `sparkles:base` blocks the inside-out
sketch chose (see its `struct Ui`), plus the open-element stack.
*/
struct Ui
{
    private HeapBuffer!(NodeRec, Storage.unique) nodes;
    private HeapBuffer!(MsgRec, Storage.unique) msgs;
    private UniqueBuffer!(Frame, 32) stack;
    private FrameTextPool texts;
    private InlineBuffer!(char, 1024) scratch;
    private InSituRegion!4096 argArena;
    private Env currentEnv;
    private ulong appMsgKey;

    @disable this(this);

    /// Structural context, as resolved from the open ancestors.
    Env env() const @safe pure nothrow @nogc => currentEnv;

    /// Formats an IES into the frame's scratch.
    const(char)[] text(Args...)(InterpolationHeader header, Args args,
        InterpolationFooter footer) return
    {
        const start = scratch.length;
        const fits = scratch.tryWrite((scope ref BoundedSink!char w) {
            w.writeText(header, args, footer);
        });
        assert(fits, "the frame's text scratch is full");
        return scratch[start .. scratch.length];
    }

    // ── the frame ──────────────────────────────────────────────────────────

    /**
    Runs one frame: `view(ui, args)` under `env`, expecting `Msg` at the root.
    `view`'s `@emits` must be `Msg` — checked here, at compile time.
    */
    Node frame(Msg, alias view, Args...)(Env env, auto ref Args args)
    {
        static assert(placeable!(view, Msg), "the root view sends " ~ EmitsOf!view.stringof
            ~ ", but the app's Msg is " ~ Msg.stringof);
        appMsgKey = typeKey!Msg;
        currentEnv = env;
        stack ~= Frame(idScope: fnv("root"));
        const first = cast(uint) nodes.length;
        view(this, args);
        stack.popBack();
        assert(stack.length == 0, "an element was left open");
        return Node(first);
    }

    /// The runtime walk of the inside-out sketch, kept as a cross-check: the
    /// compile-time check already refused any mismatch this would find.
    bool messagesTypeCheck(Node root) const @safe pure nothrow @nogc
        => checkUnder(root.index, appMsgKey);

    /// Delivers the message `target` sends, mapped by every `mapMsg` above it.
    void dispatch(Msg)(Node target, scope void delegate(Msg) @safe deliver, int payload = 0)
    {
        align(16) ubyte[256] a, b;
        const m = msgs[nodes[target.index].msg.index];
        ulong key = m.typeKey;
        if (m.payload !is null)
        {
            assert(m.payloadKey == typeKey!int, "the payload is not an `int`");
            (() @trusted => m.payload(&payload, &a[0]))();
        }
        else
            a[0 .. m.value.length] = cast(const(ubyte)[]) m.value;
        for (uint n = nodes[target.index].parent; n != uint.max; n = nodes[n].parent)
            if (nodes[n].kind == Kind.mapMsg)
            {
                assert(nodes[n].map.from == key, "a message reached a mapMsg of another type");
                (() @trusted => nodes[n].map.apply(&a[0], &b[0]))();
                a = b;
                key = nodes[n].map.to;
            }
        assert(key == typeKey!Msg, "the message is not the app's Msg");
        deliver((() @trusted => *cast(Msg*) &a[0])());
    }

    /// The first node of `kind` whose text is `text` (the demo's hit test).
    Node find(string kind, scope const(char)[] text, uint from = 0) @safe pure nothrow @nogc
    {
        foreach (i; from .. cast(uint) nodes.length)
            if (nodes[i].kind.enumMemberName == kind && textIs(Node(i), text))
                return Node(i);
        return Node.init;
    }

    /// The node's identity (what hit-testing and per-node state key on).
    ulong idOf(Node n) const @safe pure nothrow @nogc => nodes[n.index].id;

    /// Whether every node's id differs from every other's.
    bool idsUnique() const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. nodes.length)
            foreach (j; i + 1 .. nodes.length)
                if (nodes[i].id == nodes[j].id)
                    return false;
        return true;
    }

    /// Writes the tree from `n` (and its following siblings at depth 0), indented.
    void dump(W)(Node n, scope W write, uint depth = 0)
    {
        for (uint i = n.index; i != uint.max; i = nodes[i].next)
        {
            const r = nodes[i];
            UniqueBuffer!(char, 160) line;
            line.writeText(i"$(r.kind.enumMemberName)");
            texts.withText(r.text, (scope const(char)[] text) {
                line.writeText(i` "$(text)"`);
            });
            line.writeText(i" $(r.w)×$(r.h)");
            if (r.kind == Kind.column || r.kind == Kind.row)
                line.writeText(i" (built under density $(r.builtWith.enumMemberName))");
            if (r.disabled)
                line.writeText(i" disabled");
            if (r.env.active)
                line.writeText(i" env:$(r.env.env.density.enumMemberName)");
            if (r.msg.isSet)
                line.writeText(i" [msg]");
            if (r.keyed)
                line.writeText(i" key");
            line.writeText(i"  #");
            line.writeIntegerPadded!16(cast(ushort) (r.id ^ (r.id >> 16) ^ (r.id >> 32) ^ (r.id >> 48)), 4);
            write(depth, line[].idup);
            if (r.firstChild != uint.max)
                dump(Node(r.firstChild), write, depth + 1);
            if (depth == 0)
                break;
        }
    }

    // ── open / close ───────────────────────────────────────────────────────

    private TextId intern(scope const(char)[] s) @safe pure nothrow @nogc
        => s.length ? texts.intern(s).value : TextId.init;

    private const(void)[] keep(T)(scope ref const T value)
    {
        const block = () @trusted {
            auto b = argArena.allocate(T.sizeof);
            if (b !is null)
                b[] = (cast(const(void)*) &value)[0 .. T.sizeof];
            return b;
        }();
        assert(block !is null, "the frame's argument arena is full");
        return block;
    }

    private MsgRef addMsg(MsgRec rec) @safe pure nothrow @nogc
    {
        const self = MsgRef(cast(uint) msgs.length);
        msgs ~= rec;
        return self;
    }

    /// The nearest open element (the parent of whatever is built now).
    private uint openParent() const @safe pure nothrow @nogc
    {
        foreach_reverse (ref f; stack[])
            if (f.node != uint.max)
                return f.node;
        return uint.max;
    }

    /// Appends `rec` under the open parent, with its id from `site`.
    private uint link(NodeRec rec, Site site) @safe pure nothrow @nogc
    {
        const self = cast(uint) nodes.length;
        const top = stack[stack.length - 1];
        rec.id = mix(top.idScope, site.value);
        foreach_reverse (ref f; stack[])
        {
            if (f.node != uint.max)
                break;
            rec.keyed |= f.keyScope; // the first element inside a keyed row
        }
        rec.parent = openParent();
        rec.builtWith = currentEnv.density;
        nodes ~= rec;
        if (rec.parent != uint.max)
        {
            ref p = nodes[rec.parent];
            if (p.lastChild == uint.max)
                p.firstChild = self;
            else
                nodes[p.lastChild].next = self;
            p.lastChild = self;
        }
        return self;
    }

    /// Adds `w × h` to the open parent's running fit size.
    private void grow(uint parent, uint w, uint h) @safe pure nothrow @nogc
    {
        if (parent == uint.max)
            return;
        ref p = nodes[parent];
        const g = p.n ? p.gap : 0;
        if (p.kind == Kind.row)
        {
            p.accW += g + w;
            p.accH = h > p.accH ? h : p.accH;
        }
        else
        {
            p.accH += g + h;
            p.accW = w > p.accW ? w : p.accW;
        }
        p.n++;
    }

    private void leaf(NodeRec rec, Site site, uint w) @safe pure nothrow @nogc
    {
        rec.w = w;
        rec.h = 1;
        const self = link(rec, site);
        grow(nodes[self].parent, w, 1);
    }

    private Opened open(NodeRec rec, Site site) return @safe pure nothrow @nogc
    {
        const saved = currentEnv;
        if (rec.env.active)
            currentEnv = rec.env.env;
        const self = link(rec, site);
        stack ~= Frame(node: self, idScope: nodes[self].id, savedEnv: saved);
        return Opened(&this);
    }

    private Opened scopeOnly(ulong id, bool keyScope) return @safe pure nothrow @nogc
    {
        stack ~= Frame(idScope: id, savedEnv: currentEnv, keyScope: keyScope);
        return Opened(&this);
    }

    /// Closes the innermost scope: the fit size is final, `env` pops.
    package void close() @safe pure nothrow @nogc
    {
        const f = stack[stack.length - 1];
        stack.popBack();
        currentEnv = f.savedEnv;
        if (f.node == uint.max)
            return;
        ref r = nodes[f.node];
        r.w = r.accW;
        r.h = r.accH;
        grow(r.parent, r.w, r.h);
    }

    /// An identity scope for a component placed at `site`.
    Opened enter(Site site) return @safe pure nothrow @nogc
        => scopeOnly(mix(stack[stack.length - 1].idScope, site.value), false);

    /// An identity scope for one keyed row.
    Opened keyed(K)(Site site, in K key) return
        => scopeOnly(mix(mix(stack[stack.length - 1].idScope, site.value), hashOf(key)), true);

    private bool textIs(Node n, scope const(char)[] text) @safe pure nothrow @nogc
    {
        bool same = text.length == 0;
        texts.withText(nodes[n.index].text, (scope const(char)[] held) {
            same = held == text;
        });
        return same;
    }

    private bool checkUnder(uint n, ulong expected) const @safe pure nothrow @nogc
    {
        for (; n != uint.max; n = nodes[n].next)
        {
            ref rec = nodes[n];
            ulong inner = expected;
            if (rec.kind == Kind.mapMsg)
            {
                if (rec.map.to != expected)
                    return false;
                inner = rec.map.from;
            }
            if (rec.msg.isSet && msgs[rec.msg.index].typeKey != expected)
                return false;
            if (!checkUnder(rec.firstChild, inner))
                return false;
        }
        return true;
    }
}

private ulong mix(ulong a, ulong b) @safe pure nothrow @nogc
{
    ulong h = (a ^ 0x9e3779b97f4a7c15) * 0x100000001b3;
    h ^= b + 0x9e3779b97f4a7c15 + (h << 6) + (h >> 2);
    return h * 0xff51afd7ed558ccd;
}

/// Code points, the trivial size model's width.
private uint width(scope const(char)[] s) @safe pure nothrow @nogc
{
    uint n;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}

private uint digits(int v) @safe pure nothrow @nogc
{
    uint n = v <= 0 ? 1 : 0;
    for (; v; v /= 10)
        n++;
    return n;
}

/// An open element (or identity scope); closes it when it goes out of scope.
struct Opened
{
    private Ui* owner;
    @disable this(this);
    ~this() scope @safe pure nothrow @nogc
    {
        if (owner !is null)
            owner.close();
    }
}

// ── primitives: a `Site`, then named-only attributes ───────────────────────

/// A vertical stack. `disabled` is inherited by the subtree; `env` overrides
/// the context for every child built inside it.
Opened column(return ref Ui ui, Site site, NamedOnly _ = NamedOnly.init, int gap = 0,
    bool disabled = false, EnvOverride env = EnvOverride.init) @safe pure nothrow @nogc
    => ui.open(NodeRec(kind: Kind.column, gap: gap, disabled: disabled, env: env), site);

/// A horizontal stack.
Opened row(return ref Ui ui, Site site, NamedOnly _ = NamedOnly.init, int gap = 0)
    @safe pure nothrow @nogc
    => ui.open(NodeRec(kind: Kind.row, gap: gap), site);

/// One run of text.
void label(ref Ui ui, Site site, NamedOnly _ = NamedOnly.init, Slot slot = Slot.code,
    scope const(char)[] text = null) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.label, slot: slot, text: ui.intern(text)), site, width(text));

/// A switch; `onPress` is whatever message the caller wants on a press.
void toggle(ref Ui ui, Site site, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.toggle, on: on, text: ui.intern(label), msg: onPress), site,
        4 + width(label));

/// A number field; `onChange` carries the new value as an `int` payload.
void numberField(ref Ui ui, Site site, NamedOnly _ = NamedOnly.init, int value = 0,
    scope const(char)[] unit = null, MsgRef onChange = MsgRef.init) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.numberField, value: value, text: ui.intern(unit), msg: onChange),
        site, digits(value) + 1 + width(unit));

/// A name and its value; pressing it sends `onPress`.
void keyValue(ref Ui ui, Site site, NamedOnly _ = NamedOnly.init, scope const(char)[] name = null,
    scope const(char)[] value = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.keyValue, text: ui.intern(name), text2: ui.intern(value),
        msg: onPress), site, width(name) + 2 + width(value));

/// Seam for a memo site: it would compare `deps` with last frame's and skip
/// the subtree. Here it only builds.
Opened memo(D)(return ref Ui ui, Site site, in D deps)
    => ui.open(NodeRec(kind: Kind.memo, value: cast(int) hashOf(deps)), site);

/// Places a fragment (a subtree value) here, passing `args` to it.
void embed(Expected, F, Args...)(ref Ui ui, Site site, scope F frag, Args args)
{
    static assert(isFragment!F, "embed: `" ~ F.stringof ~ "` is not a markup fragment");
    static assert(fragmentFits!(F, Expected), "markup: this fragment was written under "
        ~ FragMsg!F.stringof ~ ", but is placed where " ~ Expected.stringof ~ " is expected");
    auto scoped = ui.enter(site);
    frag(ui, MsgTag!(FragMsg!F).init, args);
}

// ── messages ───────────────────────────────────────────────────────────────

/// A constant message. `Expected` is the scope's type, filled in by markup.
MsgRef on(Expected, M)(ref Ui ui, M value)
{
    static assert(!is(Expected == Transparent), "markup: this component sends " ~ M.stringof
        ~ ": declare it with @emits!(" ~ M.stringof ~ ")");
    static assert(is(M == Expected), "markup: this handler sends " ~ M.stringof
        ~ ", but its scope expects " ~ Expected.stringof ~ ": wrap it in mapMsg(…)");
    static assert(__traits(isPOD, M), "a message is plain data: it is copied as bytes");
    return ui.addMsg(MsgRec(typeKey: typeKey!M, value: ui.keep(value)));
}

/// A message built from a component's payload. `fn` may not capture.
MsgRef on(Expected, alias fn)(ref Ui ui)
{
    static assert(is(ReturnType!fn == Expected), "markup: this handler sends "
        ~ ReturnType!fn.stringof ~ ", but its scope expects " ~ Expected.stringof);
    return ui.addMsg(MsgRec(typeKey: typeKey!(ReturnType!fn), payload: &applyErased!fn,
        payloadKey: typeKey!(Parameters!fn[0])));
}

/// Opens a scope whose messages `fn` lifts to the parent's type.
Opened mapMsg(alias fn)(return ref Ui ui, Site site)
    => ui.open(NodeRec(kind: Kind.mapMsg, map: MapRec(from: typeKey!(Parameters!fn[0]),
        to: typeKey!(ReturnType!fn), apply: &applyErased!fn)), site);

private void applyErased(alias fn)(scope const(void)* from, scope void* to) @system
{
    alias Src = const Parameters!fn[0];
    alias Dst = ReturnType!fn;
    Src* src = cast(Src*) from;
    Dst* dst = cast(Dst*) to;
    emplace(dst, fn(*src));
}
