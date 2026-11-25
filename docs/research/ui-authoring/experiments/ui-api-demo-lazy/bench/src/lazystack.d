/**
A compile-and-run sketch of `sparkles:ui` authoring, built **top-down** from
**expressions**: children are D lazy variadic arguments,

    Node column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, …,
        NamedOnly _children = NamedOnly.init, scope ChildFn[] children...)

so `ui.column(gap: 1, children: a, b, c)` reads like the inside-out form, but
the compiler wraps each of `a`, `b`, `c` in a delegate literal. `column` opens
its element (appended, pushed on the open stack, its env pushed), calls each
child delegate in order, then closes: the fit size is computed from the
children right there (Clay's `CloseElement`) and the env pops.

A child's identity is its parent's id mixed with its *argument position*: a
ternary with `Node.none` keeps every later sibling's position, so an `if`
never shifts identity. `mapKeyed` splices a keyed run of rows into the one
argument position it occupies; each row's id mixes in its key.

The `scope` lazy variadic must not allocate a closure in the caller. Stock
DMD 2.115 / LDC 1.43 do allocate one ("allocates closure … with the GC"), so
`@nogc` views need the frontend fix for it (dlang/dmd#22885; see README.md).

Nothing here lays out or paints. Every name is a proposal.
*/
module lazystack;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.lifetime : emplace;
import std.experimental.allocator.building_blocks.region : InSituRegion;
import std.traits : FunctionAttribute, functionAttributes, Parameters, ReturnType;

import sparkles.base.buffer : BoundedSink, HeapBuffer, InlineBuffer, Storage, UniqueBuffer;
import sparkles.base.pool.text_pool : TextPool;
import sparkles.base.text.enums : enumMemberName;
import sparkles.base.text.writers : writeText;

version (Bench)
    import benchtext : FrameBuf;
else
    private alias FrameBuf(T) = HeapBuffer!(T, Storage.unique);

// ── forced named arguments (docs/guidelines/idioms/forced-named-arguments) ──

/// The sentinel in front of every attribute list, and again in front of
/// `children`: a positional argument after the last named attribute would
/// otherwise fill `children` silently. With it, `children:` is required.
private struct NamedOnly {}

// ── nodes, context, text, messages ─────────────────────────────────────────

/// A handle to a node this frame built. Children return it so a parent can
/// tell a child built *in* its slot from one built earlier (see `evalChild`).
struct Node
{
    uint index = uint.max;

    /// An empty child: its argument position still counts, so the siblings
    /// after it keep their identity whether or not it is shown.
    enum Node none = Node(uint.max - 1);

    bool isNone() const @safe pure nothrow @nogc => index == none.index;
}

/// What a child slot holds: a lazy, non-capturing-by-GC subtree builder.
/// `scope` at every use site is what keeps it off the GC (with the patch).
alias ChildFn = Node delegate() @safe pure nothrow @nogc;

enum Slot : ubyte { code, heading, dim }
enum Density : ubyte { comfortable, compact }
enum Layout : ubyte { wide, touch }

/// Context pushed by an element on open and popped on close. A child is
/// evaluated after its parent opens, so it reads the context directly.
struct Env
{
    Layout layout;
    Density density;
    bool disabled;

    /// An override replacing `density` for a subtree.
    EnvOverride withDensity(Density d) const @safe pure nothrow @nogc
        => EnvOverride(active: true, env: Env(layout: layout, density: d, disabled: disabled));
}

/// ditto
struct EnvOverride
{
    bool active;
    Env env;
}

// Capacities: the demo's frame is tiny; the benchmark builds 100 000-row frames
// into a heap-owned `Ui`.
version (Bench)
{
    private enum argBytes = 8 << 20, maxDepth = 64;
}
else
{
    private enum textSlots = 512, textBytes = 4096, argBytes = 4096, maxDepth = 64;
}

private struct FrameText {}
version (Bench)
{
    import benchtext : BumpTextPool;
    // `TextPool` keeps a `uint[slots]` on the stack in `compact`: see `benchtext.d`.
    private alias FrameTextPool = BumpTextPool;
}
else
    private alias FrameTextPool = TextPool!(FrameText, textSlots, textBytes);
alias TextId = FrameTextPool.Id;

/// An erased message: an index into the frame's message table.
struct MsgRef
{
    uint index = uint.max;
    bool isSet() const @safe pure nothrow @nogc => index != uint.max;
}

private ulong fnv(scope const(char)[] s, ulong h = 0xcbf29ce484222325) @safe pure nothrow @nogc
{
    foreach (c; s)
    {
        h ^= c;
        h *= 0x100000001b3;
    }
    return h;
}

private ulong mix(ulong a, ulong b) @safe pure nothrow @nogc
{
    ulong h = a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2));
    h ^= h >> 31;
    h *= 0xbf58476d1ce4e5b9;
    return h ^ (h >> 29);
}

/// A type's identity for the message check.
enum ulong typeKey(T) = fnv(T.mangleof);

private enum uint none = uint.max;

enum Kind : ubyte
{
    column, row, label, toggle, numberField, keyValue, mapMsg, memo
}

private alias ApplyThunk = void function(scope const(void)* from, scope void* to) @system;

private struct MapRec
{
    ulong from, to;
    ApplyThunk apply;
    string fromName, toName;
}

/// One element, written once when it opens (its size and children once more
/// when it closes). Children are listed, not linked: a closing element copies
/// its children's indices from the children stack into the `kids` table, as
/// Clay does, so no earlier record is ever updated.
struct NodeRec
{
    Kind kind;
    uint parent = none;
    uint kidStart, childCount; // `kids[kidStart .. kidStart + childCount]`
    // identity: id = mix(parent id, argument position [, key])
    uint position;
    bool keyed;
    ulong key;
    ulong id;
    // content
    TextId text, text2;
    MsgRef msg;
    Slot slot;
    int gap, value;
    bool on;
    Env env;      // the env this element's children see
    MapRec map;   // `mapMsg`
    ulong memoKey; // `memo`: hash of the arguments and the env
    // intrinsic (fit) size, computed at close
    uint w, h;
    // position, from `place`
    int x, y;
}

private struct MsgRec
{
    ulong typeKey;
    const(void)[] value;
    ApplyThunk payload;
    ulong payloadKey;
}

/// What a debug build reports instead of guessing.
enum DiagKind : ubyte
{
    /// A node opened while the slot it sits in already held one: something
    /// was built *outside* a children slot (`auto x = ui.label(…)` in a view
    /// body) and took the slot meant for this node.
    slotAlreadyTaken,
    /// A child slot returned a node built before the slot was evaluated: the
    /// node was built eagerly, under whatever was open then, not here.
    childBuiltOutsideSlot,
    /// `ui.on` sent a message of another type than the innermost `mapMsg`
    /// (or the app) expects.
    messageTypeMismatch,
    /// A `mapMsg` lifts into another type than its own scope expects.
    mapMsgTargetMismatch,
}

private struct Diag
{
    DiagKind kind;
    uint node;         // the node it is about
    uint other = none; // `slotAlreadyTaken`: the node that took the slot
    string got, expected;
    uint position;     // `childBuiltOutsideSlot`: the argument position
}

/// An open element: where its children start on the children stack, and its
/// id, kept here so a child's id never reads its parent's record.
private struct OpenRec
{
    uint node;
    uint pendingBase;
    ulong id;
}

/// A closed element waiting for its parent to close: its index and fit size,
/// kept together so the parent's fit reads one contiguous run.
private struct Pending
{
    uint node;
    uint w, h;
}

/**
The frame's builder, on its owner's stack (or heap-owned for big frames) and
passed `ref`. Storage as in the inside-out sketch: append-only `HeapBuffer`s
for nodes and messages, a `TextPool` for text, an `InlineBuffer` scratch for
`ui.text`, and an `InSituRegion` for constant messages' bytes.
*/
struct Ui
{
    private FrameBuf!NodeRec nodes;
    private FrameBuf!MsgRec msgs;
    private FrameBuf!Diag diags;
    private FrameTextPool texts;
    private InlineBuffer!(char, 1024) scratch;
    private InSituRegion!argBytes argArena;
    private OpenRec[maxDepth] stack; // the open elements, innermost last
    private uint depth;
    private FrameBuf!Pending pending; // closed children of the open elements, in order
    private FrameBuf!uint kids;       // every element's children, contiguous per parent
    private Env currentEnv;
    private ulong msgKey;         // the message type the innermost `mapMsg` expects
    private string msgName;
    private ulong appMsgKey;
    private string appMsgName;
    // what the slot being evaluated gives the node that opens in it
    private uint nextPos;
    private bool nextKeyed;
    private ulong nextKey;
    private bool armed;           // debug: the slot is still free
    private uint slotOwner = none; // debug: the node that took it

    @disable this(this);

    /// Structural context, as resolved by the elements open around the caller.
    Env env() const @safe pure nothrow @nogc => currentEnv;

    /// The app's message type (`runApp!(view, update, Msg)` in the real host).
    void expectMsg(Msg)()
    {
        appMsgKey = typeKey!Msg;
        appMsgName = Msg.stringof;
    }

    /// Formats an IES into the frame's scratch (UI-Q2.1).
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

    /// Builds the root view under `env`: the view is a lazy child, so `env`
    /// and the app's message type are in place before it runs.
    Node frame(Env env, scope ChildFn[] root...) @safe pure nothrow @nogc
    {
        assert(root.length == 1, "a frame has one root view");
        currentEnv = env;
        msgKey = appMsgKey;
        msgName = appMsgName;
        return evalChild(0, root[0]);
    }

    /// Drops the frame's nodes, texts and messages, keeping the storage.
    void reset() @safe pure nothrow @nogc
    {
        foreach (ref r; nodes[])
        {
            if (r.text != TextId.init)
                cast(void) texts.release(r.text);
            if (r.text2 != TextId.init)
                cast(void) texts.release(r.text2);
        }
        static if (__traits(hasMember, texts, "clearAll"))
            texts.clearAll();
        nodes.clear(releaseStorage: false);
        msgs.clear(releaseStorage: false);
        diags.clear(releaseStorage: false);
        pending.clear(releaseStorage: false);
        kids.clear(releaseStorage: false);
        scratch.clear();
        () @trusted { argArena.deallocateAll(); }();
        depth = 0;
    }

    /// The number of nodes the frame built.
    size_t nodeCount() const @safe pure nothrow @nogc => nodes.length;

    // ── building ───────────────────────────────────────────────────────────

    private TextId intern(scope const(char)[] s) @safe pure nothrow @nogc
        => s.length ? texts.intern(s).value : TextId.init;

    private uint top() const @safe pure nothrow @nogc => depth ? stack[depth - 1].node : none;

    /// Evaluates one child slot: the node that opens in it gets argument
    /// position `pos`. A debug build checks the slot is used exactly as meant.
    private Node evalChild(uint pos, scope ChildFn child) @safe pure nothrow @nogc
    {
        const before = cast(uint) nodes.length;
        nextPos = pos;
        debug
        {
            armed = true;
            slotOwner = none;
        }
        const r = child();
        debug
        {
            armed = false;
            if (!r.isNone && r.index < before)
                diags ~= Diag(DiagKind.childBuiltOutsideSlot, r.index, top, position: pos);
        }
        return r;
    }

    /// Fills in what the slot and the open elements give `rec`, appends it
    /// and returns its index. No other record is touched.
    pragma(inline, true)
    private uint append(ref NodeRec rec, EnvOverride over, bool disabled, out ulong id) @safe pure nothrow @nogc
    {
        const self = cast(uint) nodes.length;
        debug
        {
            if (!armed)
                diags ~= Diag(DiagKind.slotAlreadyTaken, self, slotOwner);
            armed = false;
            slotOwner = self;
        }
        rec.position = nextPos;
        rec.keyed = nextKeyed;
        rec.key = nextKey;
        rec.env = over.active ? over.env : currentEnv;
        rec.env.disabled = rec.env.disabled || currentEnv.disabled || disabled;
        ulong parentId;
        if (depth)
        {
            rec.parent = stack[depth - 1].node;
            parentId = stack[depth - 1].id;
        }
        id = rec.keyed ? mix(mix(parentId, rec.position), rec.key | 1)
            : mix(parentId, rec.position);
        rec.id = id;
        nodes ~= rec;
        return self;
    }

    /// Opens an element: appended, pushed on the open stack.
    pragma(inline, true)
    private uint open(NodeRec rec, EnvOverride over, bool disabled) @safe pure nothrow @nogc
    {
        ulong id;
        const self = append(rec, over, disabled, id);
        assert(depth < stack.length, "elements nest too deep");
        stack[depth++] = OpenRec(self, cast(uint) pending.length, id);
        currentEnv = rec.env;
        return self;
    }

    /// Closes the innermost element: its fit size from its children's run on
    /// the children stack, which moves into `kids`; then it joins its own
    /// parent's run, and the context it pushed pops.
    pragma(inline, true)
    private void close(Env saved) @safe pure nothrow @nogc
    {
        const o = stack[--depth];
        const run = pending[o.pendingBase .. pending.length];
        ref rec = nodes[o.node];
        uint w, h;
        if (run.length)
        {
            const horizontal = rec.kind == Kind.row;
            uint along, across;
            const kidStart = cast(uint) kids.length;
            foreach (ref c; run)
            {
                along += horizontal ? c.w : c.h;
                const a = horizontal ? c.h : c.w;
                if (a > across)
                    across = a;
                kids ~= c.node;
            }
            along += rec.gap * cast(uint) (run.length - 1);
            w = horizontal ? along : across;
            h = horizontal ? across : along;
            rec.kidStart = kidStart;
            rec.childCount = cast(uint) run.length;
            rec.w = w;
            rec.h = h;
        }
        pending.length = o.pendingBase;
        pending ~= Pending(o.node, w, h);
        currentEnv = saved;
    }

    /// A container: open, evaluate each child slot in order, close.
    private Node container(NodeRec rec, EnvOverride over, bool disabled,
        scope ChildFn[] children) @safe pure nothrow @nogc
    {
        const saved = currentEnv;
        const self = open(rec, over, disabled);
        foreach (i, child; children)
            cast(void) evalChild(cast(uint) i, child);
        close(saved);
        return Node(self);
    }

    /// A leaf: open and close at once, with its own content size.
    pragma(inline, true)
    private Node leaf(NodeRec rec, uint w) @safe pure nothrow @nogc
    {
        const saved = currentEnv;
        rec.w = w;
        rec.h = 1;
        ulong id;
        const self = append(rec, EnvOverride.init, false, id);
        pending ~= Pending(self, w, 1);
        return Node(self);
    }

    private MsgRef addMsg(MsgRec rec) @safe pure nothrow @nogc
    {
        const self = MsgRef(cast(uint) msgs.length);
        msgs ~= rec;
        return self;
    }

    /// Checks, at `ui.on` time, that `got` is what the open `mapMsg` scope
    /// (or the app) expects. Run time only: the enclosing scope is a runtime
    /// fact of the call stack, not a type the `ui` carries.
    private void checkMsg(ulong got, string gotName) @safe pure nothrow @nogc
    {
        debug if (got != msgKey)
            diags ~= Diag(DiagKind.messageTypeMismatch, top, got: gotName, expected: msgName);
    }

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

    // ── after the frame: find, dump, diagnostics, dispatch ─────────────────

    private bool textIs(uint n, scope const(char)[] text) @safe pure nothrow @nogc
    {
        bool same = text.length == 0;
        texts.withText(nodes[n].text, (scope const(char)[] held) { same = held == text; });
        return same;
    }

    /// The first node of `kind` whose text is `text` (the demo's hit test).
    Node find(string kind, scope const(char)[] text, uint from = 0) @safe pure nothrow @nogc
    {
        foreach (i; from .. cast(uint) nodes.length)
            if (nodes[i].kind.enumMemberName == kind && textIs(i, text))
                return Node(i);
        return Node.init;
    }

    /// Writes every root (normally one) and its subtree, indented: kind,
    /// text, fit size, id prefix, `key`, the env children see, `[msg]`.
    void dump(W)(scope W write)
    {
        foreach (i; 0 .. cast(uint) nodes.length)
            if (nodes[i].parent == none)
                dumpFrom(write, i, 0);
    }

    private void dumpFrom(W)(scope W write, uint n, uint depth)
    {
        const r = nodes[n];
        UniqueBuffer!(char, 160) line;
        line.writeText(i"$(r.kind.enumMemberName)");
        texts.withText(r.text, (scope const(char)[] text) { line.writeText(i` "$(text)"`); });
        line.writeText(i"  $(r.w)×$(r.h)  @$(r.position) #$(hex4(r.id))");
        if (r.keyed)
            line.writeText(i" key");
        if (r.kind == Kind.column || r.kind == Kind.row || r.kind == Kind.mapMsg || r.kind == Kind.memo)
            line.writeText(i" [$(r.env.density.enumMemberName)]");
        if (r.env.disabled)
            line.writeText(i" disabled");
        if (r.kind == Kind.memo)
            line.writeText(i" memoKey #$(hex4(r.memoKey))");
        if (r.msg.isSet)
            line.writeText(i" [msg]");
        write(depth, line[].idup);
        foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
            dumpFrom(write, c, depth + 1);
    }

    /// The 16-bit id prefix `dump` shows.
    char[4] shortId(Node n) const @safe pure nothrow @nogc => hex4(nodes[n.index].id);

    /// Whether the frame recorded no message-type diagnostic.
    bool messagesTypeCheck() const @safe pure nothrow @nogc
    {
        foreach (d; diags[])
            if (d.kind == DiagKind.messageTypeMismatch || d.kind == DiagKind.mapMsgTargetMismatch)
                return false;
        return true;
    }

    private void describe(ref UniqueBuffer!(char, 240) line, uint n)
    {
        const r = nodes[n];
        line.writeText(i"$(r.kind.enumMemberName)");
        texts.withText(r.text, (scope const(char)[] text) { line.writeText(i` "$(text)"`); });
        line.writeText(i" #$(hex4(r.id))");
    }

    /// Reports every diagnostic of the frame (debug builds only record them).
    void diagnostics(W)(scope W write)
    {
        foreach (d; diags[])
        {
            UniqueBuffer!(char, 240) line;
            line.writeText(i"$(d.kind.enumMemberName): ");
            describe(line, d.node);
            final switch (d.kind)
            {
            case DiagKind.slotAlreadyTaken:
                line.writeText(i" opened in a slot already taken by ");
                if (d.other == none)
                    line.writeText(i"a node");
                else
                    describe(line, d.other);
                line.writeText(i", built outside a children slot");
                break;
            case DiagKind.childBuiltOutsideSlot:
                line.writeText(i" was passed as child @$(d.position) of ");
                if (d.other == none)
                    line.writeText(i"the frame");
                else
                    describe(line, d.other);
                line.writeText(i" but built before it opened");
                break;
            case DiagKind.messageTypeMismatch:
            case DiagKind.mapMsgTargetMismatch:
                line.writeText(i" sends $(d.got) where $(d.expected) is expected");
                break;
            }
            write(line[].idup);
        }
    }

    /**
    Delivers the message `target` sends, as the app's `Msg`: decoded, then
    mapped by every `mapMsg` between `target` and the root.
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
        for (uint n = nodes[target.index].parent; n != none; n = nodes[n].parent)
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


    // ── a layout pass after the build: positions, top-down ─────────────────

    /// Positions every element from the fit sizes: a child sits at its
    /// parent's position plus the extent of its earlier siblings and gaps.
    /// One sweep in node order (parents precede their children).
    void place() @safe pure nothrow @nogc
    {
        if (nodes.length == 0)
            return;
        nodes[0].x = 0;
        nodes[0].y = 0;
        foreach (i; 0 .. cast(uint) nodes.length)
        {
            ref p = nodes[i];
            if (p.childCount == 0)
                continue;
            const horizontal = p.kind == Kind.row;
            int x = p.x, y = p.y;
            foreach (c; kids[p.kidStart .. p.kidStart + p.childCount])
            {
                ref k = nodes[c];
                k.x = x;
                k.y = y;
                if (horizontal)
                    x += k.w + p.gap;
                else
                    y += k.h + p.gap;
            }
        }
    }

    /// A checksum of every element's position.
    ulong positionsHash() const @safe pure nothrow @nogc
    {
        ulong h = 1469598103934665603UL;
        foreach (ref r; nodes[])
            h = (h ^ (cast(ulong) cast(uint) r.x << 32 | cast(uint) r.y)) * 1099511628211UL;
        return h;
    }

    // ── read-only access for the benchmark's tree checksum ─────────────────

    const(NodeRec)[] records() const return @safe pure nothrow @nogc => nodes[];

    /// Pre-order checksum of the tree under `n`.
    void checksum(Node n, ref ulong h, ref size_t count) const @safe pure nothrow @nogc
    {
        import treehash : treeHash;
        const r = nodes[n.index];
        h = treeHash(h, r.kind.enumMemberName, r.w, r.h, r.childCount);
        count++;
        foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
            checksum(Node(c), h, count);
    }
}

/// Display width of UTF-8 text: one cell per code point (the trivial model).
package uint cells(scope const(char)[] s) @safe pure nothrow @nogc
{
    uint n;
    foreach (c; s)
        n += (c & 0xC0) != 0x80;
    return n;
}

package uint digits(int v) @safe pure nothrow @nogc
{
    uint n = v < 0 ? 2 : 1;
    for (v /= 10; v; v /= 10)
        n++;
    return n;
}

private char[4] hex4(ulong v) @safe pure nothrow @nogc
{
    char[4] r;
    foreach (i; 0 .. 4)
        r[i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xF];
    return r;
}

// ── containers: `ui.column(gap: 1, children: a, b, c)` ─────────────────────

/// A vertical stack. `env` and `disabled` reach its whole subtree, which is
/// evaluated after it opens.
Node column(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0, bool disabled = false,
    EnvOverride env = EnvOverride.init, NamedOnly _children = NamedOnly.init,
    scope ChildFn[] children...) @safe pure nothrow @nogc
    => ui.container(NodeRec(kind: Kind.column, gap: gap), env, disabled, children);

/// A horizontal stack.
Node row(ref Ui ui, NamedOnly _ = NamedOnly.init, int gap = 0,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
    => ui.container(NodeRec(kind: Kind.row, gap: gap), EnvOverride.init, false, children);

// ── leaves ─────────────────────────────────────────────────────────────────

/// One run of text.
Node label(ref Ui ui, NamedOnly _ = NamedOnly.init, Slot slot = Slot.code,
    scope const(char)[] text = null) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.label, slot: slot, text: ui.intern(text)), text.cells);

/// A switch; `onPress` is whatever message the caller wants on a press.
Node toggle(ref Ui ui, NamedOnly _ = NamedOnly.init, bool on = false,
    scope const(char)[] label = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.toggle, on: on, text: ui.intern(label), msg: onPress),
        label.cells + 4);

/// A number field; `onChange` carries the new value as an `int` payload.
Node numberField(ref Ui ui, NamedOnly _ = NamedOnly.init, int value = 0,
    scope const(char)[] unit = null, MsgRef onChange = MsgRef.init) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.numberField, value: value, text: ui.intern(unit),
        msg: onChange), value.digits + 1 + unit.cells);

/// A name and its value; pressing it sends `onPress`.
Node keyValue(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] name = null,
    scope const(char)[] value = null, MsgRef onPress = MsgRef.init) @safe pure nothrow @nogc
    => ui.leaf(NodeRec(kind: Kind.keyValue, text: ui.intern(name), text2: ui.intern(value),
        msg: onPress), name.cells + 1 + value.cells);

// ── lists: keys are mandatory ──────────────────────────────────────────────

/// A range bound to the builder. It offers `mapKeyed` and `mapByIndex`, and no
/// plain `map`: it is not an input range, so Phobos' `map` does not apply.
struct UiRange(R)
{
    private R range;
    private Ui* ui;
}

/// ditto
auto toUi(R)(R r, return ref Ui ui) => UiRange!R(r, &ui);

/**
Splices one keyed row per element into the argument position it occupies:
no fragment node, so the rows are the parent's own children for layout (as
Clay's would be). It is itself a lazy child, so it runs while the parent is
open. A free function, not a `Ui` method: a method template taking a local
lambda by alias needs a dual context.
*/
Node mapKeyed(alias key, alias row, R)(UiRange!R r)
{
    auto ui = r.ui;
    const pos = ui.nextPos;
    foreach (ref e; r.range)
    {
        ui.nextKeyed = true;
        ui.nextKey = hashOf(key(e));
        cast(void) ui.evalChild(pos, () => row(e));
    }
    ui.nextKeyed = false;
    return Node.none; // the rows are linked already; the slot itself is empty
}

/// ditto, opting into position as the key (static or append-only lists).
Node mapByIndex(alias row, R)(UiRange!R r)
{
    auto ui = r.ui;
    const pos = ui.nextPos;
    ulong i;
    foreach (ref e; r.range)
    {
        ui.nextKeyed = true;
        ui.nextKey = i++;
        cast(void) ui.evalChild(pos, () => row(e));
    }
    ui.nextKeyed = false;
    return Node.none;
}

// ── messages ───────────────────────────────────────────────────────────────

/// A constant message, copied into the frame's table. Checked (debug, at run
/// time) against the open `mapMsg` scope: the child is evaluated inside it.
MsgRef on(M)(ref Ui ui, M value)
{
    static assert(__traits(isPOD, M), "a message is plain data: it is copied as bytes");
    ui.checkMsg(typeKey!M, M.stringof);
    return ui.addMsg(MsgRec(typeKey: typeKey!M, value: ui.keep(value)));
}

/// A message built from a component's payload. `fn` may not capture.
MsgRef on(alias fn)(ref Ui ui)
{
    ui.checkMsg(typeKey!(ReturnType!fn), ReturnType!fn.stringof);
    return ui.addMsg(MsgRec(typeKey: typeKey!(ReturnType!fn), payload: &applyErased!fn,
        payloadKey: typeKey!(Parameters!fn[0])));
}

/**
Lifts every message its child sends with `fn`. The child is lazy, so it is
evaluated *inside* the scope: each `ui.on` below sees `From` as the expected
type and checks against it right there.
*/
Node mapMsg(alias fn)(ref Ui ui, scope ChildFn[] children...)
{
    alias From = Parameters!fn[0];
    alias To = ReturnType!fn;
    debug if (typeKey!To != ui.msgKey)
        ui.diags ~= Diag(DiagKind.mapMsgTargetMismatch, ui.top, got: To.stringof,
            expected: ui.msgName);
    const saved = ui.currentEnv;
    const savedKey = ui.msgKey;
    const savedName = ui.msgName;
    const self = ui.open(NodeRec(kind: Kind.mapMsg, map: MapRec(from: typeKey!From,
        to: typeKey!To, apply: &applyErased!fn, fromName: From.stringof, toName: To.stringof)),
        EnvOverride.init, false);
    ui.msgKey = typeKey!From;
    ui.msgName = From.stringof;
    foreach (i, child; children)
        cast(void) ui.evalChild(cast(uint) i, child);
    ui.msgKey = savedKey;
    ui.msgName = savedName;
    ui.close(saved);
    return Node(self);
}

/// `fn`, erased: reads its argument at `from`, emplaces its result at `to`.
private void applyErased(alias fn)(scope const(void)* from, scope void* to) @system
{
    alias Src = const Parameters!fn[0];
    alias Dst = ReturnType!fn;
    emplace(cast(Dst*) to, fn(*cast(Src*) from));
}

// ── memo seam ──────────────────────────────────────────────────────────────

/**
A memo site (UI-Q3's seam): a `memo` element keyed by `fn`'s arguments and the
env, then `fn(ui, args)` built as its one child. A real host compares the key
with last frame's element of the same id and, when equal, splices last
frame's subtree instead of calling `fn`.
*/
Node memo(alias fn, Args...)(ref Ui ui, auto ref const Args args)
{
    static assert(functionAttributes!fn & FunctionAttribute.pure_,
        "a memoised composite must be `pure`");
    ulong key = hashOf(ui.currentEnv);
    static foreach (i; 0 .. Args.length)
        key = mix(key, hashOf(args[i]));
    const saved = ui.currentEnv;
    const self = ui.open(NodeRec(kind: Kind.memo, memoKey: key), EnvOverride.init, false);
    cast(void) ui.evalChild(0, () => fn(ui, args));
    ui.close(saved);
    return Node(self);
}

version (Bench) pragma(msg, __MODULE__, ": NodeRec.sizeof = ", NodeRec.sizeof);
