/**
A compile-and-run sketch of `sparkles:ui` authoring, built **top-down** the way
Clay builds: `with (ui.column(gap: 1)) { … }` opens an element, the block
builds its children, and the handle's destructor closes it — computing the
element's fit size from its children right there and popping the context it
pushed.

Nothing here lays out or paints. The builder records nodes, text and messages
so the demo can show what the API means: which env a subtree is built under,
which identity a node gets, which message type each `ui.on` is checked
against, and how a message finds its way to `update`. Every name is a
proposal.

Two typing decisions carry the design:

$(UL
    $(LI `Ui!Msg` is the builder *as seen by a component that sends `Msg`*.
        Every `Ui!M` has one field, the same `UiState`, so a `mapMsg` scope
        hands its body the *same* builder retyped as `Ui!From`. `ui.on(x)`
        then checks `x` against `Msg` at compile time.)
    $(LI Handles (`Opened`, `MapScope`) are non-copyable and close in
        `~this() scope`, so `if`, `foreach` and early `return` inside a block
        still close every element they opened.)
)
*/
module ui_sketch;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.attribute : mustuse;
import core.lifetime : emplace;
import std.experimental.allocator.building_blocks.region : InSituRegion;
import std.traits : FunctionAttribute, functionAttributes, isCallable, Parameters, ReturnType;

import sparkles.base.buffer : BoundedSink, HeapBuffer, InlineBuffer, Storage, UniqueBuffer;
import sparkles.base.pool.text_pool : TextPool;
import sparkles.base.text.enums : enumMemberName;
import sparkles.base.text.writers : writeText;

// ── forced named arguments (docs/guidelines/idioms/forced-named-arguments) ──

private struct NamedOnly {}

// ── context, text, messages ────────────────────────────────────────────────

enum Slot : ubyte { code, heading, dim }
enum Density : ubyte { comfortable, compact }
enum Layout : ubyte { wide, touch }

/// Context pushed by an element on open and popped on close. Top-down, a
/// child is built after its parent opens, so it sees the context directly:
/// no deferred phase is needed for it.
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

private struct FrameText {}
private alias FrameTextPool = TextPool!(FrameText, 512, 4096);
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

/// A type's identity for the runtime half of the message check.
enum ulong typeKey(T) = fnv(T.mangleof);

private enum uint none = uint.max;

private enum Kind : ubyte
{
    root, column, row, label, toggle, numberField, keyValue, mapMsg, memo, fragment
}

private alias ApplyThunk = void function(scope const(void)* from, scope void* to) @system;

private struct MapRec
{
    ulong from, to;
    ApplyThunk apply;
    string fromName, toName;
}

/// One element. Children are linked, not stored in a list: an element is
/// appended when it opens, before any of its children exist.
private struct NodeRec
{
    Kind kind;
    uint parent = none, firstChild = none, lastChild = none, nextSibling = none;
    uint childCount;
    // identity: id = mix(parent id, site, disambiguator)
    ulong site;          // hash of the call site (file, line)
    string file;         // for diagnostics
    uint line;
    bool keyed;
    ulong disamb;        // the key's hash, or the occurrence count of `site`
    ulong id;
    // content
    TextId text, text2;
    MsgRef msg;
    Slot slot;
    int gap, value;
    bool on;
    Env env;             // the env this element's children see
    MapRec map;          // `mapMsg`
    ulong memoKey;       // `memo`: hash of the arguments and the env
    // intrinsic (fit) size, computed at close
    uint w, h;
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
    /// A call site repeats under one parent with no `key:` (a `foreach`): its
    /// identity falls back to the occurrence count, which shifts on insert.
    repeatWithoutKey,
    /// Two siblings from one call site share a key.
    duplicateKey,
    /// `ui.on` ran while a `mapMsg` scope expecting another type was open
    /// (an outer `Ui!M` used inside the scope).
    messageUnderWrongMapMsg,
    /// A recorded subtree was attached under another env than it was built in.
    attachedUnderOtherEnv,
    /// A recorded subtree was attached twice, or never.
    subtreeAttachedTwice, subtreeNeverAttached,
}

private struct Diag
{
    DiagKind kind;
    uint node;
    string got;   // `messageUnderWrongMapMsg`: the type sent
    string file;  // where it happened, when that is not `node`'s own site
    size_t line;
}

/// The builder's storage. Every `Ui!M` is exactly this, so a `mapMsg` scope
/// can retype the builder without copying it.
private struct UiState
{
    HeapBuffer!(NodeRec, Storage.unique) nodes;
    HeapBuffer!(MsgRec, Storage.unique) msgs;
    HeapBuffer!(Diag, Storage.unique) diags;
    FrameTextPool texts;
    InlineBuffer!(char, 1024) scratch;
    InSituRegion!4096 argArena;
    uint[64] stack;       // the open elements, innermost last
    uint depth;
    Env env;              // what the next element sees
    ulong msgKey;         // the message type the innermost `mapMsg` expects

    @disable this(this);

    TextId intern(scope const(char)[] s) @safe pure nothrow @nogc
        => s.length ? texts.intern(s).value : TextId.init;

    uint top() const @safe pure nothrow @nogc => depth ? stack[depth - 1] : none;

    /// Appends `rec` under the innermost open element and gives it its id.
    uint open(NodeRec rec, string file, size_t line, bool keyed, ulong key, EnvOverride over,
        bool disabled) @safe pure nothrow @nogc
    {
        const self = cast(uint) nodes.length;
        rec.site = mix(fnv(file), line);
        rec.file = file;
        rec.line = cast(uint) line;
        rec.keyed = keyed;
        rec.disamb = key;
        rec.env = over.active ? over.env : env;
        rec.env.disabled = rec.env.disabled || env.disabled || disabled;
        nodes ~= rec;
        link(self, top);
        identify(self);
        assert(depth < stack.length, "elements nest too deep");
        stack[depth++] = self;
        env = nodes[self].env;
        return self;
    }

    /// Links `self` as the last child of `parent` (none: a detached root).
    void link(uint self, uint parent) @safe pure nothrow @nogc
    {
        nodes[self].parent = parent;
        if (parent == none)
            return;
        ref p = nodes[parent];
        if (p.lastChild == none)
            p.firstChild = self;
        else
            nodes[p.lastChild].nextSibling = self;
        p.lastChild = self;
        p.childCount++;
    }

    /**
    Call-site identity: `self`'s id mixes its parent's id, its call site and,
    to tell apart siblings from one call site, its key or else its occurrence
    count among those siblings. An `if` elsewhere never shifts it: only an
    earlier sibling *from the same call site* does, and that is a `foreach`,
    which a debug build asks to key.
    */
    void identify(uint self) @safe pure nothrow @nogc
    {
        ref rec = nodes[self];
        if (!rec.keyed)
            rec.disamb = 0;
        if (rec.parent != none)
            for (uint c = nodes[rec.parent].firstChild; c != self; c = nodes[c].nextSibling)
            {
                if (nodes[c].site != rec.site || nodes[c].keyed != rec.keyed)
                    continue;
                if (!rec.keyed)
                {
                    debug if (rec.disamb == 0)
                        diags ~= Diag(DiagKind.repeatWithoutKey, self);
                    rec.disamb++;
                }
                else if (nodes[c].disamb == rec.disamb)
                    debug diags ~= Diag(DiagKind.duplicateKey, self);
            }
        const parentId = rec.parent == none ? 0 : nodes[rec.parent].id;
        rec.id = mix(mix(parentId, rec.site), rec.disamb ^ (rec.keyed ? 1UL << 63 : 0));
    }

    /// Re-derives the ids under `n` after it moved (a recorded subtree).
    void reidentify(uint n) @safe pure nothrow @nogc
    {
        identify(n);
        for (uint c = nodes[n].firstChild; c != none; c = nodes[c].nextSibling)
            reidentify(c);
    }

    /// Closes the innermost element: fit size from its children (Clay's
    /// `CloseElement`), then the context it pushed pops.
    void close(Env saved) @safe pure nothrow @nogc
    {
        const self = stack[--depth];
        ref rec = nodes[self];
        if (rec.childCount)
        {
            const horizontal = rec.kind == Kind.row;
            uint along, across;
            for (uint c = rec.firstChild; c != none; c = nodes[c].nextSibling)
            {
                const cw = nodes[c].w, ch = nodes[c].h;
                along += horizontal ? cw : ch;
                const a = horizontal ? ch : cw;
                if (a > across)
                    across = a;
            }
            along += rec.gap * (rec.childCount - 1);
            rec.w = horizontal ? along : across;
            rec.h = horizontal ? across : along;
        }
        env = saved;
    }

    /// A leaf: open and close at once, with its own content size.
    void leaf(NodeRec rec, uint w, string file, size_t line, bool keyed, ulong key)
        @safe pure nothrow @nogc
    {
        const saved = env;
        rec.w = w;
        rec.h = 1;
        open(rec, file, line, keyed, key, EnvOverride.init, false);
        close(saved);
    }

    MsgRef addMsg(MsgRec rec) @safe pure nothrow @nogc
    {
        const self = MsgRef(cast(uint) msgs.length);
        msgs ~= rec;
        return self;
    }

    const(void)[] keep(T)(scope ref const T value)
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

    bool textIs(uint n, scope const(char)[] text) @safe pure nothrow @nogc
    {
        bool same = text.length == 0;
        texts.withText(nodes[n].text, (scope const(char)[] held) { same = held == text; });
        return same;
    }
}

/// Display width of UTF-8 text: one cell per code point (the trivial model).
private uint cells(scope const(char)[] s) @safe pure nothrow @nogc
{
    uint n;
    foreach (c; s)
        n += (c & 0xC0) != 0x80;
    return n;
}

private uint digits(int v) @safe pure nothrow @nogc
{
    uint n = v < 0 ? 2 : 1;
    for (v /= 10; v; v /= 10)
        n++;
    return n;
}

private bool keyedOf(K)() => !is(K == typeof(null));
private ulong keyOf(K)(scope const K k)
{
    static if (is(K == typeof(null)))
        return 0;
    else
        return hashOf(k);
}

// ── handles ────────────────────────────────────────────────────────────────

/**
An open element. `with (ui.column()) { … }` keeps it alive for the block; its
destructor closes the element. It is non-copyable, so it cannot outlive the
block by accident, and it names nothing a `with` body could pick up by mistake.
*/
@mustuse struct Opened
{
    private UiState* st;
    private Env savedEnv;
    private ulong savedMsgKey;

    @disable this(this);

    ~this() scope @safe pure nothrow @nogc
    {
        if (st is null)
            return;
        st.close(savedEnv);
        st.msgKey = savedMsgKey;
    }
}

/**
An open `mapMsg` scope. It *is* the builder retyped as `Ui!From` (`alias
this`), so `with (auto stats = ui.mapMsg!lift) statsPane(stats, …)` hands the
pane a `ref Ui!StatsMsg`, and the pane's `ui.on(StatsMsg(…))` type-checks at
compile time.
*/
@mustuse struct MapScope(From)
{
    private Opened opened;

    @disable this(this);

    /// The builder, as a component sending `From` sees it. Sound because every
    /// `Ui!M` is exactly one `UiState` (asserted in `Ui`).
    ref Ui!From inner() return scope @trusted pure nothrow @nogc => *cast(Ui!From*) opened.st;

    alias inner this;
}

/// A subtree recorded detached, to be attached later (build-then-attach).
/// Typed by the message its `on`s send, so it attaches only under a `Ui!Msg`.
struct Subtree(Msg)
{
    private uint root = none;
    private Env builtUnder;

    @disable this(this);

    bool pending() const @safe pure nothrow @nogc => root != none;
}

/// The default argument a primitive's `key:` takes when none is given.
private enum noKey = null;

// ── the builder ────────────────────────────────────────────────────────────

/**
The frame's builder, typed by the message its user sends. `Ui!Msg` lives on
its owner's stack and is passed `ref`; a `mapMsg` scope retypes the same one.
*/
struct Ui(Msg)
{
    private UiState st;

    @disable this(this);

    // Every `Ui!M` shares one layout: that is what lets `MapScope` retype it.
    static assert(Ui!Msg.sizeof == UiState.sizeof && Ui!Msg.st.offsetof == 0);

    /// The storage, for a handle to close against. The one `@trusted` step
    /// of opening: a handle may not outlive the `Ui` (`return`), and it is
    /// non-copyable, so it cannot leave the `with` that holds it either.
    private UiState* state() return @trusted pure nothrow @nogc => &st;

    /// Structural context, as resolved by the elements open around the caller.
    Env env() const @safe pure nothrow @nogc => st.env;

    /// Starts the frame: the root element, open for the view's body.
    Opened frame(Env env) return
    {
        assert(st.nodes.length == 0, "one frame per `Ui` in this sketch");
        st.env = env;
        st.msgKey = typeKey!Msg;
        st.open(NodeRec(kind: Kind.root), __FILE__, __LINE__, false, 0, EnvOverride.init, false);
        return Opened(state, env, typeKey!Msg);
    }

    /// Formats an IES into the frame's scratch (UI-Q2.1).
    const(char)[] text(Args...)(InterpolationHeader header, Args args,
        InterpolationFooter footer) return
    {
        const start = st.scratch.length;
        const fits = st.scratch.tryWrite((scope ref BoundedSink!char w) {
            w.writeText(header, args, footer);
        });
        assert(fits, "the frame's text scratch is full");
        return st.scratch[start .. st.scratch.length];
    }

    private Opened openScope(NodeRec rec, string file, size_t line, bool keyed, ulong key,
        EnvOverride over, bool disabled) return
    {
        const saved = st.env;
        st.open(rec, file, line, keyed, key, over, disabled);
        return Opened(state, saved, st.msgKey);
    }

    // ── containers: `with (ui.column(…)) { … }` ────────────────────────────

    /// A vertical stack. `env` and `disabled` reach its whole subtree, which
    /// is built after it opens.
    Opened column(K = typeof(null))(NamedOnly _ = NamedOnly.init, int gap = 0,
        bool disabled = false, EnvOverride env = EnvOverride.init, K key = noKey,
        string file = __FILE__, size_t line = __LINE__) return
        => openScope(NodeRec(kind: Kind.column, gap: gap), file, line, keyedOf!K, keyOf(key),
            env, disabled);

    /// A horizontal stack.
    Opened row(K = typeof(null))(NamedOnly _ = NamedOnly.init, int gap = 0, K key = noKey,
        string file = __FILE__, size_t line = __LINE__) return
        => openScope(NodeRec(kind: Kind.row, gap: gap), file, line, keyedOf!K, keyOf(key),
            EnvOverride.init, false);

    // ── leaves: plain calls ────────────────────────────────────────────────

    /// One run of text.
    void label(K = typeof(null))(NamedOnly _ = NamedOnly.init, Slot slot = Slot.code,
        scope const(char)[] text = null, K key = noKey,
        string file = __FILE__, size_t line = __LINE__)
        => st.leaf(NodeRec(kind: Kind.label, slot: slot, text: st.intern(text)), text.cells,
            file, line, keyedOf!K, keyOf(key));

    /// A switch; `onPress` is whatever message the caller wants on a press.
    void toggle(K = typeof(null))(NamedOnly _ = NamedOnly.init, bool on = false,
        scope const(char)[] label = null, MsgRef onPress = MsgRef.init, K key = noKey,
        string file = __FILE__, size_t line = __LINE__)
        => st.leaf(NodeRec(kind: Kind.toggle, on: on, text: st.intern(label), msg: onPress),
            label.cells + 4, file, line, keyedOf!K, keyOf(key));

    /// A number field; `onChange` carries the new value as an `int` payload.
    void numberField(K = typeof(null))(NamedOnly _ = NamedOnly.init, int value = 0,
        scope const(char)[] unit = null, MsgRef onChange = MsgRef.init, K key = noKey,
        string file = __FILE__, size_t line = __LINE__)
        => st.leaf(NodeRec(kind: Kind.numberField, value: value, text: st.intern(unit),
            msg: onChange), value.digits + 1 + unit.cells, file, line, keyedOf!K, keyOf(key));

    /// A name and its value; pressing it sends `onPress`.
    void keyValue(K = typeof(null))(NamedOnly _ = NamedOnly.init,
        scope const(char)[] name = null, scope const(char)[] value = null,
        MsgRef onPress = MsgRef.init, K key = noKey,
        string file = __FILE__, size_t line = __LINE__)
        => st.leaf(NodeRec(kind: Kind.keyValue, text: st.intern(name), text2: st.intern(value),
            msg: onPress), name.cells + 1 + value.cells, file, line, keyedOf!K, keyOf(key));

    // ── messages ───────────────────────────────────────────────────────────

    /**
    A constant message. Its type is checked against `Msg` *at compile time*;
    a debug build also checks, at run time, that no `mapMsg` scope expecting
    another type is open (which only an outer `Ui!M` used inside one can
    cause).
    */
    MsgRef on(V)(V value)
    {
        static assert(is(V == Msg), "`ui.on` sends a `" ~ V.stringof ~ "` where this `Ui` sends `"
            ~ Msg.stringof ~ "`: build the composite under `ui.mapMsg!((" ~ V.stringof
            ~ " m) => " ~ Msg.stringof ~ "(m))`");
        static assert(__traits(isPOD, V), "a message is plain data: it is copied as bytes");
        checkScope();
        return st.addMsg(MsgRec(typeKey: typeKey!V, value: st.keep(value)));
    }

    /// A message built from a component's payload. `fn` may not capture.
    MsgRef on(alias fn)()
    {
        static assert(is(ReturnType!fn == Msg), "`ui.on!fn` builds a `"
            ~ ReturnType!fn.stringof ~ "` where this `Ui` sends `" ~ Msg.stringof ~ "`");
        checkScope();
        return st.addMsg(MsgRec(typeKey: typeKey!(ReturnType!fn), payload: &applyErased!fn,
            payloadKey: typeKey!(Parameters!fn[0])));
    }

    private void checkScope() @safe pure nothrow @nogc
    {
        debug if (st.msgKey != typeKey!Msg)
            st.diags ~= Diag(DiagKind.messageUnderWrongMapMsg, st.top, Msg.stringof);
    }

    /**
    Opens a scope whose body sends `Parameters!fn[0]`, lifted to `Msg` by
    `fn`. `fn`'s result must be `Msg` (compile time); the scope's builder is
    `Ui!From`.
    */
    MapScope!(Parameters!fn[0]) mapMsg(alias fn)(string file = __FILE__, size_t line = __LINE__)
        return
    {
        alias From = Parameters!fn[0];
        static assert(is(ReturnType!fn == Msg), "`mapMsg` lifts into `" ~ ReturnType!fn.stringof
            ~ "`, but this `Ui` sends `" ~ Msg.stringof ~ "`");
        auto rec = NodeRec(kind: Kind.mapMsg, map: MapRec(from: typeKey!From, to: typeKey!Msg,
            apply: &applyErased!fn, fromName: From.stringof, toName: Msg.stringof));
        auto o = openScope(rec, file, line, false, 0, EnvOverride.init, false);
        st.msgKey = typeKey!From;
        return MapScope!From(o.move);
    }

    // ── subtrees as values ─────────────────────────────────────────────────

    /**
    Places anything that builds a subtree, where the caller stands:
    a value form (`.build(ref Ui!Msg)`), a callable `(ref Ui!Msg)`, or a
    recorded `Subtree!Msg` (attached). This is the one slot type a composite
    such as `card(content:)` needs.
    */
    void place(P)(auto ref P part, string file = __FILE__, size_t line = __LINE__)
    {
        static if (is(P == Subtree!Msg))
            attach(part, file, line);
        else static if (__traits(hasMember, P, "build"))
            part.build(this);
        else static if (isCallable!P)
            part(this);
        else
            static assert(false, "`" ~ P.stringof ~ "` is not a subtree of a `Ui!" ~ Msg.stringof ~ "`");
    }

    /**
    Records a subtree detached: built now, under the current env, linked
    nowhere. `attach`/`place` links it under whatever element is open then
    and re-derives its ids there. The one form here that is built *before* it
    is placed, so a debug build reports an env mismatch at attach.
    */
    private uint beginRecord(string file, size_t line) @safe pure nothrow @nogc
    {
        const self = cast(uint) st.nodes.length;
        st.nodes ~= NodeRec(kind: Kind.fragment, env: st.env, site: mix(fnv(file), line),
            file: file, line: cast(uint) line);
        st.stack[st.depth++] = self; // open, but linked under nothing
        return self;
    }

    private Subtree!Msg endRecord(uint self) @safe pure nothrow @nogc
    {
        const saved = st.nodes[self].env;
        st.close(saved);
        Subtree!Msg t;
        t.root = self;
        t.builtUnder = saved;
        return t;
    }

    /// The message type the innermost `mapMsg` above `n` expects.
    private string expectedAt(uint n) const @safe pure nothrow @nogc
    {
        for (; n != none; n = st.nodes[n].parent)
            if (st.nodes[n].kind == Kind.mapMsg)
                return st.nodes[n].map.fromName;
        return Msg.stringof;
    }

    /// ditto
    void attach(ref Subtree!Msg t, string file = __FILE__, size_t line = __LINE__)
        @safe pure nothrow @nogc
    {
        if (!t.pending)
        {
            debug st.diags ~= Diag(DiagKind.subtreeAttachedTwice, st.top, file: file, line: line);
            return;
        }
        debug if (t.builtUnder != st.env)
            st.diags ~= Diag(DiagKind.attachedUnderOtherEnv, t.root, file: file, line: line);
        st.nodes[t.root].site = mix(fnv(file), line); // identified where it is placed
        st.link(t.root, st.top);
        st.reidentify(t.root);
        t.root = none;
    }

    /**
    A memo site (UI-Q3's seam): a `memo` element keyed by `fn`'s arguments and
    the env, then `fn` built under it. A real host compares the key with last
    frame's element of the same id and, when equal, splices last frame's
    recorded subtree instead of calling `fn` (the `record`/`attach` mechanism).
    */
    void memo(alias fn, Args...)(auto ref const Args args, string file = __FILE__,
        size_t line = __LINE__)
    {
        static assert(functionAttributes!fn & FunctionAttribute.pure_,
            "a memoised composite must be `pure`");
        ulong key = hashOf(st.env);
        static foreach (i; 0 .. Args.length)
            key = mix(key, hashOf(args[i]));
        auto rec = NodeRec(kind: Kind.memo, memoKey: key);
        with (openScope(rec, file, line, false, 0, EnvOverride.init, false))
            fn(this, args);
    }

    // ── after the frame: dump, diagnostics, dispatch ───────────────────────

    /// The first node of `kind` whose text is `text`, from node `from` on
    /// (the demo's stand-in for hit testing).
    uint find(string kind, scope const(char)[] text, uint from = 0) @safe pure nothrow @nogc
    {
        foreach (i; from .. cast(uint) st.nodes.length)
            if (st.nodes[i].kind.enumMemberName == kind && st.textIs(i, text))
                return i;
        return none;
    }

    /// Writes the tree from the root, indented: kind, text, fit size, id.
    void dump(W)(scope W write, uint n = 0, uint depth = 0)
    {
        const r = st.nodes[n];
        UniqueBuffer!(char, 160) line;
        line.writeText(i"$(r.kind.enumMemberName)");
        st.texts.withText(r.text, (scope const(char)[] text) { line.writeText(i` "$(text)"`); });
        line.writeText(i"  $(r.w)×$(r.h)  #$(hex4(r.id))");
        if (r.keyed)
            line.writeText(i" key");
        else if (r.disamb)
            line.writeText(i" occ$(r.disamb)");
        if (r.kind != Kind.label && r.kind != Kind.keyValue && r.kind != Kind.toggle
            && r.kind != Kind.numberField)
            line.writeText(i" [$(r.env.density.enumMemberName)]");
        if (r.env.disabled)
            line.writeText(i" disabled");
        if (r.kind == Kind.memo)
            line.writeText(i" memoKey #$(hex4(r.memoKey))");
        if (r.msg.isSet)
            line.writeText(i" [msg]");
        write(depth, line[].idup);
        for (uint c = r.firstChild; c != none; c = st.nodes[c].nextSibling)
            dump(write, c, depth + 1);
    }

    /// The 16-bit id prefix `dump` shows, for comparing two frames.
    char[4] shortId(uint n) const @safe pure nothrow @nogc => hex4(st.nodes[n].id);

    /// Reports every diagnostic of the frame (debug builds only record them).
    void diagnostics(W)(scope W write)
    {
        foreach (i; 1 .. cast(uint) st.nodes.length)
            if (st.nodes[i].kind == Kind.fragment && st.nodes[i].parent == none)
                st.diags ~= Diag(DiagKind.subtreeNeverAttached, i);
        foreach (d; st.diags[])
        {
            const r = st.nodes[d.node];
            UniqueBuffer!(char, 200) line;
            if (d.file.length)
                line.writeText(i"$(d.kind.enumMemberName) at $(d.file):$(d.line)");
            else
                line.writeText(i"$(d.kind.enumMemberName) at $(r.file):$(r.line)");
            if (r.parent != none)
                line.writeText(i" under $(st.nodes[r.parent].kind.enumMemberName) at $(st.nodes[r.parent].file):$(st.nodes[r.parent].line)");
            if (d.kind == DiagKind.messageUnderWrongMapMsg)
                line.writeText(i" (scope expects $(expectedAt(d.node)), got $(d.got))");
            write(line[].idup);
        }
    }

    /**
    Delivers the message `target` sends, as the app's `Msg`: decoded, then
    mapped by every `mapMsg` between `target` and the root.
    */
    void dispatch(uint target, scope void delegate(Msg) @safe deliver, int payload = 0)
    {
        align(16) ubyte[256] a, b;
        const m = st.msgs[st.nodes[target].msg.index];
        ulong key = m.typeKey;
        if (m.payload !is null)
        {
            assert(m.payloadKey == typeKey!int, "the payload is not an `int`");
            (() @trusted => m.payload(&payload, &a[0]))();
        }
        else
            a[0 .. m.value.length] = cast(const(ubyte)[]) m.value;
        for (uint n = st.nodes[target].parent; n != none; n = st.nodes[n].parent)
            if (st.nodes[n].kind == Kind.mapMsg)
            {
                assert(st.nodes[n].map.from == key, "a message reached a mapMsg of another type");
                (() @trusted => st.nodes[n].map.apply(&a[0], &b[0]))();
                a = b;
                key = st.nodes[n].map.to;
            }
        assert(key == typeKey!Msg, "the message is not the app's Msg");
        deliver((() @trusted => *cast(Msg*) &a[0])());
    }
}

/// `fn`, erased: reads its argument at `from`, emplaces its result at `to`.
private void applyErased(alias fn)(scope const(void)* from, scope void* to) @system
{
    alias Src = const Parameters!fn[0];
    alias Dst = ReturnType!fn;
    emplace(cast(Dst*) to, fn(*cast(Src*) from));
}

private Opened move(ref Opened o) @safe pure nothrow @nogc
{
    auto r = Opened(o.st, o.savedEnv, o.savedMsgKey);
    o.st = null;
    return r;
}

// ── value forms ────────────────────────────────────────────────────────────

/// A composite's value form: its arguments, built where it is placed.
/// Top-down it is no longer *deferred* — `build` runs wherever the holder
/// calls `ui.place(part)` — it only lets a subtree be held as a value.
struct Part(alias fn, Args...)
{
    Args args;
    void build(M)(ref Ui!M ui) const => fn(ui, args);
}

/**
Declares `name`'s value form beside the composite `void name(ref Ui!M, …)`:
called without a `Ui`, `name(args)` is a `Part` holding `args`.
*/
enum string componentForm(string name) =
    "auto " ~ name ~ "(Args...)(Args args)\n"
    ~ "if (!(Args.length && imported!\"ui_sketch\".isUi!(Args[0])))\n"
    ~ "    => imported!\"ui_sketch\".Part!(" ~ name ~ ", Args)(args);\n";

/// Whether `T` is some `Ui!M`.
enum bool isUi(T) = is(T : Ui!M, M);

/**
Records a subtree detached: built now, under the current env, linked nowhere.
`attach`/`place` links it under whatever element is open then and re-derives
its ids there. The one form here that is built *before* it is placed, so a
debug build reports an env mismatch at attach.

A free function, not a method, only because a method template taking a local
lambda by alias needs a dual context (deprecated, and it allocates a closure:
see README.md).
*/
Subtree!M record(alias build, M)(ref Ui!M ui, string file = __FILE__, size_t line = __LINE__)
{
    const self = ui.beginRecord(file, line);
    build(ui);
    return ui.endRecord(self);
}

/// The top 16 bits of `v` as four hex digits (the dump's short id).
private char[4] hex4(ulong v) @safe pure nothrow @nogc
{
    char[4] r;
    foreach (i; 0 .. 4)
        r[i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xF];
    return r;
}
