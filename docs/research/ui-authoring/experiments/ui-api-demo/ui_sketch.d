/**
A compile-only sketch of the `sparkles:ui` authoring API agreed in UI-Q1–Q6.

Nothing here lays out or paints. The builder records nodes, text and messages
in the frame's tables so the demo can show *what the API means*: which order
things are built in, which `env` a deferred composite sees, and how a message
finds its way to `update`. Every name is a proposal.

The tables are `sparkles:base` building blocks, each picked by what its spec
says it is for; `struct Ui` says why each one fits.
*/
module ui_sketch;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.lifetime : emplace;
import std.algorithm.searching : all;
import std.experimental.allocator.building_blocks.region : InSituRegion;
import std.traits : Parameters, ReturnType;

import sparkles.base.buffer : BoundedSink, HeapBuffer, InlineBuffer, Storage, UniqueBuffer;
import sparkles.base.pool.text_pool : TextPool;
import sparkles.base.text.enums : enumMemberName;
import sparkles.base.text.writers : writeText;

// ── forced named arguments (docs/guidelines/idioms/forced-named-arguments) ──

private struct NamedOnly {}

// ── nodes, text, messages ──────────────────────────────────────────────────

/// A handle to a node this frame built (UI-Q2: children are erased handles).
struct Node
{
    uint index = uint.max;

    /// An empty child. It keeps its slot, so the siblings after it keep their
    /// identity whether or not it is shown (UI-Q2 identity rule 1).
    enum Node none = Node(uint.max - 1);

    bool isNone() const @safe pure nothrow @nogc => index == none.index;
}

enum Slot : ubyte { code, heading, dim }
enum Density : ubyte { comfortable, compact }
enum Layout : ubyte { wide, touch }

/// Context that changes *what gets built* (UI-Q6). Appearance context
/// (`disabled`, `scheme`, …) is an inherited node property instead.
struct Env
{
    Layout layout;
    Density density;

    /// This env with `density` replaced, as an override for a subtree.
    EnvOverride withDensity(Density d) const @safe pure nothrow @nogc
        => EnvOverride(active: true, env: Env(layout: layout, density: d));
}

/// An env a node sets for the deferred composites below it.
struct EnvOverride
{
    bool active;
    Env env;
}

/// The tag that keeps frame-text ids apart from every other `Handle` (POOL2).
private struct FrameText {}

/// The frame's text: at most 512 live texts sharing 4 KiB.
private alias FrameTextPool = TextPool!(FrameText, 512, 4096);

/// Text interned into the frame: a generational id into its `TextPool`.
/// `TextId.init` is no text, and never resolves (POOL1).
alias TextId = FrameTextPool.Id;

/// An erased message (UI-Q4): an index into the frame's message table.
struct MsgRef
{
    uint index = uint.max;
    bool isSet() const @safe pure nothrow @nogc => index != uint.max;
}

private ulong fnv(string s) @safe pure nothrow @nogc
{
    ulong h = 0xcbf29ce484222325;
    foreach (c; s)
    {
        h ^= c;
        h *= 0x100000001b3;
    }
    return h;
}

/// A type's identity for the message check, computed at compile time.
enum ulong typeKey(T) = fnv(T.mangleof);

private enum Kind : ubyte
{
    column, row, label, toggle, numberField, keyValue, fragment, deferred, mapMsg
}

private alias DeferredThunk = Node function(ref Ui, scope const(void)[] args) @safe pure nothrow @nogc;
private alias ApplyThunk = void function(scope const(void)* from, scope void* to) @system;

private struct MapRec
{
    ulong from, to;
    ApplyThunk apply;
}

private struct NodeRec
{
    Kind kind;
    uint parent = uint.max;
    uint childStart, childCount;
    TextId text, text2;
    MsgRef msg;
    Slot slot;
    int gap, value;
    bool on, disabled;
    ulong key;
    EnvOverride env;
    DeferredThunk thunk; // `deferred`: builds the subtree from the stored arguments
    const(void)[] args;  // `deferred`: the composite's bytes in the argument arena
    MapRec map; // `mapMsg`
    Density builtWith; // `deferred`: the env it was built under (for the demo's dump)
}

private struct MsgRec
{
    ulong typeKey;         // the message's type, or the payload lambda's result type
    const(void)[] value;   // its bytes in the argument arena (a constant message)
    ApplyThunk payload;    // `on!fn`: turns a component's payload into the message
    ulong payloadKey;
}

/**
The frame's builder: write-only while building, except `env` (UI-Q2, UI-Q6).

Each table is the `sparkles:base` building block its lifetime calls for:

$(UL
    $(LI Nodes, child lists and messages are appended in build order and die
        together when the frame does, so they are buffers, not pools. They are
        `HeapBuffer!(T, Storage.unique)`: an inline array of records would make
        `Ui` too large to live on its owner's stack, `reserve` and
        `clear(releaseStorage: false)` keep one block across frames
        (`BUF11`, `BUF15`), and `unique` matches `Ui`'s own move-only identity,
        which keeps the refcount off the grow path (`BUF7`).)
    $(LI A message is not a pool handle. A `Handle` earns its generation when
        single occupants are removed while ids to them are outstanding
        (POOL3); a `MsgRef` is never held apart from the node that carries it,
        and the whole table is dropped at once. What does outlive a frame is
        the hit id an event lands on, and that is the node's key (UI-Q2), not
        a slot in this table.)
    $(LI Text is a `TextPool` (POOL12–POOL18): components keep ids, never
        offsets, so the arena can reset and compact under them, and a read is
        a borrow (POOL14) — see `textIs` and `dump`.)
    $(LI `ui.text` formats into an `InlineBuffer`: a hard bound whose overflow
        is reported, written only through `tryWrite` (`WRT1`, `WRT3`). Its
        slices live for the frame, which is what the IES form promises.)
    $(LI Arguments and constant messages are bump-allocated from an
        `InSituRegion`, the allocator guide's per-frame arena whose storage
        is the struct itself (allocators §5, §11): one pointer bump each,
        freed all at once by `deallocateAll`.)
)
*/
struct Ui
{
    private HeapBuffer!(NodeRec, Storage.unique) nodes;
    private HeapBuffer!(Node, Storage.unique) kids;
    private HeapBuffer!(MsgRec, Storage.unique) msgs;
    private FrameTextPool texts;
    private InlineBuffer!(char, 1024) scratch;
    private InSituRegion!4096 argArena;
    private Env currentEnv;
    private ulong appMsgKey;

    @disable this(this);

    /// Structural context, as resolved from this node's ancestors.
    Env env() const @safe pure nothrow @nogc => currentEnv;

    /// The app's message type (`runApp!(view, update, Msg)` in the real host).
    void expectMsg(Msg)() { appMsgKey = typeKey!Msg; }

    /**
    Formats an IES into the frame and returns a slice that lives for the
    frame (UI-Q2.1: a scratch buffer reset each frame; components intern it).
    */
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

    /// Builds `root` and every composite placed below it, top-down.
    Node frame(C)(C root, Env env)
    {
        const r = this.place(root);
        expand(r.index, env);
        return r;
    }

    /**
    Checks every message against the type expected where it sits: the app's
    `Msg` at the root, changed by each `mapMsg` on the way down. `on` cannot
    check this itself, because a subtree is built before the `mapMsg` that
    wraps it, so only a walk from the root knows what a message is expected
    to be.
    */
    bool messagesTypeCheck(Node root) const @safe pure nothrow @nogc
        => checkUnder(root.index, appMsgKey);

    /**
    Delivers the message `target` sends, as the app's `Msg`: decoded from the
    table (with `payload` for `on!fn` messages), then mapped by every `mapMsg`
    between `target` and the root. The real host does this against the last
    frame's table, when an event lands on `target`'s hit id.
    */
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

    /// The first node of `kind` whose text is `text` (the demo's stand-in for
    /// hit testing), searching from `from` on. Not `const` only because
    /// reading text opens a borrow (`TextPool.withText` is not `const`).
    Node find(string kind, scope const(char)[] text, uint from = 0) @safe pure nothrow @nogc
    {
        foreach (i; from .. cast(uint) nodes.length)
            if (nodes[i].kind.enumMemberName == kind && textIs(Node(i), text))
                return Node(i);
        return Node.init;
    }

    /// Writes the tree, indented, with each deferred node's build env.
    void dump(W)(Node n, scope W write, uint depth = 0)
    {
        if (n.isNone)
            return write(depth, "none");

        const r = nodes[n.index];
        UniqueBuffer!(char, 128) line;
        line.writeText(i"$(r.kind.enumMemberName)");
        texts.withText(r.text, (scope const(char)[] text) {
            line.writeText(i` "$(text)"`);
        });
        if (r.kind == Kind.deferred)
            line.writeText(i" (built under density $(r.builtWith.enumMemberName))");
        if (r.disabled)
            line.writeText(i" disabled");
        if (r.env.active)
            line.writeText(i" env:$(r.env.env.density.enumMemberName)");
        if (r.msg.isSet)
            line.writeText(i" [msg]");
        if (r.key)
            line.writeText(i" key");
        write(depth, line[].idup);
        foreach (c; childrenOf(r))
            dump(c, write, depth + 1);
    }

    // ── building, for the primitives and combinators in this module ────────

    /// `s` interned into the frame's text pool, or `TextId.init` for no text.
    private TextId intern(scope const(char)[] s) @safe pure nothrow @nogc
        => s.length ? texts.intern(s).value : TextId.init;

    /**
    Copies `value`'s bytes into the frame's argument arena, where they live
    until the frame ends. The copy is the one operation `@safe` cannot check:
    the bytes escape `value`'s scope (see `place` for why that is sound).
    Phobos' `InSituRegion.allocate` also infers `@system` (its lazy
    `BorrowedRegion` constructor reads `store.ptr`), so it sits inside the
    same block.
    */
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

    private Node add(NodeRec rec, scope const(Node)[] children) @safe pure nothrow @nogc
    {
        const self = Node(cast(uint) nodes.length);
        rec.childStart = cast(uint) kids.length;
        rec.childCount = cast(uint) children.length;
        kids ~= children;
        foreach (c; children)
            if (!c.isNone)
                nodes[c.index].parent = self.index;
        nodes ~= rec;
        return self;
    }

    private MsgRef addMsg(MsgRec rec) @safe pure nothrow @nogc
    {
        const self = MsgRef(cast(uint) msgs.length);
        msgs ~= rec;
        return self;
    }

    /// Records the key a `mapKeyed` row is identified by (UI-Q2).
    private void setKey(Node n, ulong key) @safe pure nothrow @nogc { nodes[n.index].key = key; }

    // ── walking ────────────────────────────────────────────────────────────

    /// `rec`'s children. Only for walks that build nothing: a build appends
    /// to `kids`, which may move the block under this slice.
    private const(Node)[] childrenOf(in NodeRec rec) const return @safe pure nothrow @nogc
        => kids[rec.childStart .. rec.childStart + rec.childCount];

    /// Whether `n` holds `text`, compared inside a borrow: the pool lends its
    /// bytes only to a callback (POOL14). A node with no text holds "".
    private bool textIs(Node n, scope const(char)[] text) @safe pure nothrow @nogc
    {
        bool same = text.length == 0;
        texts.withText(nodes[n.index].text, (scope const(char)[] held) {
            same = held == text;
        });
        return same;
    }

    private void expand(uint n, Env env) @safe pure nothrow @nogc
    {
        if (n >= Node.none.index)
            return;
        if (nodes[n].env.active)
            env = nodes[n].env.env;
        if (nodes[n].kind == Kind.deferred && nodes[n].childCount == 0)
        {
            currentEnv = env;
            const built = nodes[n].thunk(this, nodes[n].args);
            ref rec = nodes[n]; // taken after the thunk, which may move the table
            rec.builtWith = env.density;
            rec.childStart = cast(uint) kids.length;
            rec.childCount = 1;
            kids ~= built;
            nodes[built.index].parent = n;
        }
        // By index, not `childrenOf`: a thunk below appends to `kids`.
        foreach (i; 0 .. nodes[n].childCount)
            expand(kids[nodes[n].childStart + i].index, env);
    }

    private bool checkUnder(uint n, ulong expected) const @safe pure nothrow @nogc
    {
        if (n >= Node.none.index)
            return true;
        ref rec = nodes[n];
        if (rec.kind == Kind.mapMsg)
        {
            if (rec.map.to != expected)
                return false;
            expected = rec.map.from;
        }
        if (rec.msg.isSet && msgs[rec.msg.index].typeKey != expected)
            return false;
        return childrenOf(rec).all!(c => checkUnder(c.index, expected));
    }
}

// ── primitives: eager, every attribute named (UI-Q2) ───────────────────────

/// A vertical stack. `disabled` is inherited by its subtree at layout time;
/// `env` reaches only the deferred composites placed below it (UI-Q6).
Node Column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool disabled = false,
    EnvOverride env = EnvOverride.init, scope const(Node)[] children = null)
    @safe pure nothrow @nogc
    => ui.add(NodeRec(kind: Kind.column, gap: gap, disabled: disabled, env: env), children);

/// A horizontal stack.
Node Row(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0,
    scope const(Node)[] children = null) @safe pure nothrow @nogc
    => ui.add(NodeRec(kind: Kind.row, gap: gap), children);

/// One run of text.
Node Label(ref Ui ui, NamedOnly _ = NamedOnly.init, Slot slot = Slot.code,
    scope const(char)[] text = null) @safe pure nothrow @nogc
    => ui.add(NodeRec(kind: Kind.label, slot: slot, text: ui.intern(text)), null);

/// A switch; `onPress` is whatever message the caller wants on a press.
Node Toggle(ref Ui ui, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.add(NodeRec(kind: Kind.toggle, on: on, text: ui.intern(label), msg: onPress), null);

/// A number field; `onChange` carries the new value as an `int` payload.
Node NumberField(ref Ui ui, NamedOnly _ = NamedOnly.init, int value = 0,
    scope const(char)[] unit = null, MsgRef onChange = MsgRef.init) @safe pure nothrow @nogc
    => ui.add(NodeRec(kind: Kind.numberField, value: value, text: ui.intern(unit),
        msg: onChange), null);

/// A name and its value; pressing it sends `onPress`.
Node KeyValue(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] name = null,
    scope const(char)[] value = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.add(NodeRec(kind: Kind.keyValue, text: ui.intern(name), text2: ui.intern(value),
        msg: onPress), null);

// ── lists: keys are mandatory (UI-Q2) ──────────────────────────────────────

/// A range bound to the builder. It offers `mapKeyed` and `mapByIndex`, and no
/// plain `map`: it is not an input range, so Phobos' `map` does not apply.
struct UiRange(R)
{
    private R range;
    private Ui* ui;
}

/// ditto
auto toUi(R)(R r, return ref Ui ui) => UiRange!R(r, &ui);

/// One fragment node holding a keyed run of rows.
Node mapKeyed(alias key, alias row, R)(UiRange!R r)
{
    // The default buffer: rows stay inline up to 16, then spill to the heap.
    UniqueBuffer!(Node, 16) rows;
    foreach (ref e; r.range)
    {
        const node = row(e);
        r.ui.setKey(node, hashOf(key(e)));
        rows ~= node;
    }
    return r.ui.add(NodeRec(kind: Kind.fragment), rows[]);
}

/// ditto, opting into position as the key (static or append-only lists).
Node mapByIndex(alias row, R)(UiRange!R r)
{
    UniqueBuffer!(Node, 16) rows;
    foreach (ref e; r.range)
        rows ~= row(e);
    return r.ui.add(NodeRec(kind: Kind.fragment), rows[]);
}

// ── messages (UI-Q4) ───────────────────────────────────────────────────────

/// A constant message, copied into the frame's table.
MsgRef on(M)(ref Ui ui, M value)
{
    static assert(__traits(isPOD, M), "a message is plain data: it is copied as bytes");
    return ui.addMsg(MsgRec(typeKey: typeKey!M, value: ui.keep(value)));
}

/// A message built from a component's payload. `fn` may not capture: its
/// thunk is a function pointer, so a capturing lambda has no frame to reach.
MsgRef on(alias fn)(ref Ui ui)
    => ui.addMsg(MsgRec(typeKey: typeKey!(ReturnType!fn), payload: &applyErased!fn,
        payloadKey: typeKey!(Parameters!fn[0])));

/// Wraps every message `child`'s subtree sends with `fn` (UI-Q4.5).
Node mapMsg(alias fn)(ref Ui ui, Node child)
    => ui.add(NodeRec(kind: Kind.mapMsg, map: MapRec(from: typeKey!(Parameters!fn[0]),
        to: typeKey!(ReturnType!fn), apply: &applyErased!fn)), [child]);

/**
`fn`, erased: reads its argument at `from` and writes its result at `to`.
`to` is raw bytes, so the result is emplaced rather than assigned: a POD type
may still declare `opAssign` (`SumType` does), and `*dst = …` would run it
against whatever bytes are there.
*/
private void applyErased(alias fn)(scope const(void)* from, scope void* to) @system
{
    alias Src = const Parameters!fn[0];
    alias Dst = ReturnType!fn;
    Src* src = cast(Src*) from;
    Dst* dst = cast(Dst*) to;
    emplace(dst, fn(*src));
}

// ── deferred composites (UI-Q6, on the `valueForm` pattern) ────────────────

/// A composite's value form: its arguments, built when a parent places it.
struct Composite(alias fn, Args...)
{
    enum isComposite = true;
    Args args;
    Node build(ref Ui ui) const => fn(ui, args);
}

/**
Declares `name`'s value form beside the composite `Node name(ref Ui, …)`,
exactly as `valueForm` does for a writer: called without a `Ui`, `name(args)`
is a `Composite` holding `args`.
*/
enum string componentForm(string name) =
    "auto " ~ name ~ "(Args...)(Args args)\n"
    ~ "if (!(Args.length && is(Args[0] == imported!\"ui_sketch\".Ui)))\n"
    ~ "    => imported!\"ui_sketch\".Composite!(" ~ name ~ ", Args)(args);\n";

/// Seam for a later memo site (UI-Q3): it would compare `inner.args` and the
/// `env` fields read with last frame's. Here it only builds.
struct Memo(C)
{
    enum isComposite = true;
    C inner;
    Node build(ref Ui ui) const => inner.build(ui);
}

/// ditto
auto memo(C)(C c) if (__traits(hasMember, C, "isComposite")) => Memo!C(c);

/**
Places a value form: copies its arguments into the frame and returns a node
that the deferred phase builds top-down, after every ancestor, under the env
they resolve. The composite must be `@safe pure nothrow @nogc`: its thunk is
stored with those attributes.
*/
Node place(C)(ref Ui ui, scope C c) if (__traits(hasMember, C, "isComposite"))
{
    static assert(__traits(isPOD, C), "a composite's arguments are copied by value");
    // The arguments escape `c`'s scope into the frame arena. That is sound
    // only because `frame` runs every deferred thunk before it returns, while
    // the model the arguments point into is still alive: the frame structure,
    // not dip1000, carries the guarantee.
    return ui.add(NodeRec(kind: Kind.deferred, thunk: &buildFrom!C, args: ui.keep(c)), null);
}

/// `C`'s deferred thunk: the composite read back from its bytes, then built.
/// Its attributes are inferred from `C.build`, so an impure composite has no
/// thunk that converts to `DeferredThunk`, and `place` rejects it.
private Node buildFrom(C)(ref Ui ui, scope const(void)[] args)
    => (() @trusted => *cast(const(C)*) args.ptr)().build(ui);
