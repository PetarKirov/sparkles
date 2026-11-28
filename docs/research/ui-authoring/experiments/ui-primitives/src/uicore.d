/**
The builder core both prototypes share: the lazy-variadic, children-stack
builder of the lazy demo (`ui-api-demo-lazy/bench/src/lazystack.d`), grown
into something a widget library can stand on:

- **element types**: `box` (one element with Clay-style sub-config structs —
    `Lay` layout, `Scroll`, `Floating`, `border`, background, `Sem` semantics,
    `CustomLayout`, per-child `LayoutData`) and `text` (the one leaf that is
    measured and wraps), plus the `image` and `custom` (paint-only) escape
    hatches. The *hybrid* primitives (`Kind.toggle`, `textInput`,
    `scrollView`, `virtualList`) are core kinds too: every place the core
    dispatches on them is marked `HYBRID`.
- **a layout pass** after the build: fit sizes flow up at close (Clay's
    `CloseElement`), then `layout` runs top-down with the available size,
    resolving `fit`/`grow`/`fixed`/`percent`, height-for-width for text and
    custom layouts, scroll offsets, floating and anchored children, and calls a
    custom layout's `arrange` with its children's measured sizes.
- **after the frame**: paint (a draw list), hit testing, press routing,
    semantics, focus order, `find` by role and label, and an identity-keyed
    element store (scroll offsets, caret, last frame's bounds).

Views stay `@safe pure nothrow @nogc`; a layout or painter is a struct with
`static` functions, erased to `function` pointers over POD params copied into
the frame's arena.
*/
module uicore;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import core.lifetime : emplace;
import std.traits : FunctionAttribute, functionAttributes, Parameters, ReturnType;

import sparkles.base.buffer : BoundedSink, InlineBuffer, UniqueBuffer;
import sparkles.base.text.enums : enumMemberName;
import sparkles.base.text.writers : writeText;

import rawbuf : RawBuffer, TextStore;

// ── forced named arguments ──────────────────────────────────────────────────

/// The sentinel in front of every attribute list, and again in front of
/// `children`, so a positional argument cannot fill `children` silently.
struct NamedOnly {}

// ── nodes, context, messages ────────────────────────────────────────────────

/// A handle to a node this frame built.
struct Node
{
    uint index = uint.max;

    /// An empty child: its argument position still counts.
    enum Node none = Node(uint.max - 1);

    bool isNone() const @safe pure nothrow @nogc => index == none.index;
    bool isSet() const @safe pure nothrow @nogc => index < none.index;
}

/// A child slot: a lazy subtree builder, `scope` so it allocates no closure.
alias ChildFn = Node delegate() @safe pure nothrow @nogc;

/// Semantic colour roles (the palette resolves them; never a colour here).
enum Slot : ubyte
{
    none, body, heading, dim, code, accent, controlOn, sunken, knob, border,
    surface, event, grid, caret, track, thumb
}

enum Density : ubyte { comfortable, compact }

/// Context pushed by an element and read by everything built inside it.
struct Env
{
    Density density;
    bool disabled;
    /// The theme's control height in cells (1 on a terminal, 2 on touch).
    ubyte controlRows = 1;

    EnvOverride withDensity(Density d) const @safe pure nothrow @nogc
        => EnvOverride(active: true, env: Env(density: d, disabled: disabled, controlRows: controlRows));
}

/// ditto
struct EnvOverride
{
    bool active;
    Env env;
}

/// An erased message: an index into the frame's message table.
struct MsgRef
{
    uint index = uint.max;
    bool isSet() const @safe pure nothrow @nogc => index != uint.max;
}

alias TextId = TextStore.Id;

package ulong fnv(scope const(char)[] s, ulong h = 0xcbf29ce484222325) @safe pure nothrow @nogc
{
    foreach (c; s)
    {
        h ^= c;
        h *= 0x100000001b3;
    }
    return h;
}

package ulong mix(ulong a, ulong b) @safe pure nothrow @nogc
{
    ulong h = a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2));
    h ^= h >> 31;
    h *= 0xbf58476d1ce4e5b9;
    return h ^ (h >> 29);
}

/// A type's identity for the message check.
enum ulong typeKey(T) = fnv(T.mangleof);

package enum uint none = uint.max;

// ── element vocabulary ──────────────────────────────────────────────────────

enum Kind : ubyte
{
    box, text, image, custom, mapMsg, memo,
    // HYBRID: primitives kept for hot or semantically special widgets
    toggle, textInput, scrollView, virtualList,
}

/// How a box lays out its children.
enum Dir : ubyte
{
    column, /// top to bottom, `gap` between
    row,    /// left to right
    stack,  /// overlaid at the origin, aligned
    anchor, /// mechanism (d): each child at a fraction of the box (`anchorAt`)
}

enum SizeMode : ubyte { fit, grow, fixed, percent }

/// One axis' sizing (LAY6's vocabulary, without min/max).
struct Sizing
{
    SizeMode mode;
    int value; // cells (fixed), percent, or grow weight

    static Sizing fit() @safe pure nothrow @nogc => Sizing(SizeMode.fit);
    static Sizing grow(int weight = 1) @safe pure nothrow @nogc => Sizing(SizeMode.grow, weight);
    static Sizing fixed(int cells) @safe pure nothrow @nogc => Sizing(SizeMode.fixed, cells);
    static Sizing percent(int p) @safe pure nothrow @nogc => Sizing(SizeMode.percent, p);
}

enum Align : ubyte { start, center, end }

struct Pad
{
    ubyte l, t, r, b;
    static Pad all(ubyte n) @safe pure nothrow @nogc => Pad(n, n, n, n);
    static Pad xy(ubyte x, ubyte y) @safe pure nothrow @nogc => Pad(x, y, x, y);
}

/// A box's layout config (Clay's `Clay_LayoutConfig`).
struct Lay
{
    Dir dir;
    ushort gap;
    Pad pad;
    Sizing w, h;
    Align alignX, alignY;
}

/// Clip and scroll per axis; the offset comes from the element store.
struct Scroll
{
    bool x, y;
}

enum FloatTo : ubyte { parent, root }

/// Out of flow, at an offset from the parent's (or root's) origin.
struct Floating
{
    bool active;
    short x, y;
    short z;
    FloatTo to;
    /// Which edge of the parent `x` counts from (Clay's attach points, x only).
    Align attachX;
}

enum Role : ubyte
{
    none, group, text, heading, button, switch_, spinButton, textField,
    list, listItem, scrollArea, image, clock, timeline, calendar, event
}

enum Checked : ubyte { none, off, on }

/// What assistive technology and tests see (`label` given here or merged).
struct Sem
{
    Role role;
    Checked checked;
    bool focusable;
    /// Take the label from the first text descendant (Flutter's
    /// `MergeSemantics`): a composite need not repeat its caption.
    bool merge;
    bool hasValue;
    int value;
}

/// Per-child data a parent's custom (or anchored) layout reads: Flutter's
/// `ParentData`/`LayoutId`, Compose's `parentData`, SwiftUI's `LayoutValueKey`.
struct LayoutData
{
    int a, b, c, d;
}

/// Anchored placement (mechanism d): the child's pivot (fractions of its own
/// size, ×10 000) at a fraction (×10 000) of the box's content.
LayoutData anchorAt(int fx, int fy, int pivotX = 5000, int pivotY = 5000) @safe pure nothrow @nogc
    => LayoutData(fx, fy, pivotX, pivotY);

// ── custom layouts and painters (mechanisms a and c) ────────────────────────

struct Size
{
    int w, h;
}

struct Rect
{
    int x, y, w, h;
    bool contains(int px, int py) const @safe pure nothrow @nogc
        => px >= x && py >= y && px < x + w && py < y + h;
}

/// The available size; `int.max` is unbounded.
struct Constraints
{
    int maxW = int.max, maxH = int.max;
    bool boundedW() const @safe pure nothrow @nogc => maxW != int.max;
}

/// One child as a custom layout sees it: measured (`fitW`/`fitH`, its
/// `data`) on the way in; `x`/`y` (relative to the content box) and `w`/`h`
/// (defaulting to the fit size) on the way out.
struct Child
{
    int fitW, fitH;
    LayoutData data;
    int x, y, w, h;
}

alias MeasureFn = Size function(scope const(void)[] params, Constraints c,
    scope const(Child)[] kids) @safe pure nothrow @nogc;
alias ArrangeFn = void function(scope const(void)[] params, Size inner,
    scope Child[] kids, scope ref LayoutCtx ctx) @safe pure nothrow @nogc;
alias PaintFn = void function(scope const(void)[] params, Rect rect,
    ref DrawList list) @safe pure nothrow @nogc;
alias BuildFn = Node function(ref Ui ui, scope const(void)[] params, Size avail)
    @safe pure nothrow @nogc;

/// A box's custom layout: erased functions plus its params in the arena.
struct CustomLayout
{
    MeasureFn measure;
    ArrangeFn arrange;
    uint params = none, paramsLen;
    bool active() const @safe pure nothrow @nogc => arrange !is null;
}

/// A paint-only leaf's painter.
struct Painter
{
    PaintFn paint;
    uint params = none, paramsLen;
}

/// What `arrange` may ask the core while it runs.
struct LayoutCtx
{
    private Ui* ui;
    private const(uint)[] kidNodes;

    /// The height child `i` needs at width `w` (height-for-width, LAY4).
    int heightFor(size_t i, int w) scope @safe pure nothrow @nogc => ui.heightFor(kidNodes[i], w);

    /// Scratch ints, valid until `arrange` returns. One call per `arrange`.
    int[] ints(size_t n) return scope @safe pure nothrow @nogc => ui.scratchInts(n);
}

private const(T)* viewAs(T)(return scope const(void)[] bytes) @trusted
{
    assert(bytes.length == T.sizeof, "params of another type");
    return cast(const(T)*) bytes.ptr;
}

private Size measureThunk(L)(scope const(void)[] p, Constraints c, scope const(Child)[] kids)
    => L.measure(*viewAs!L(p), c, kids);

private void arrangeThunk(L)(scope const(void)[] p, Size inner, scope Child[] kids, scope ref LayoutCtx ctx)
    => L.arrange(*viewAs!L(p), inner, kids, ctx);

private void paintThunk(P)(scope const(void)[] p, Rect r, ref DrawList list)
    => P.paint(*viewAs!P(p), r, list);

private Node buildThunk(alias fn, P)(ref Ui ui, scope const(void)[] p, Size avail)
    => fn(ui, *viewAs!P(p), avail);

/**
A layout is a POD struct with `static void arrange(in L, Size inner, scope
Child[] kids, ref LayoutCtx)` and, optionally, `static Size measure(in L,
Constraints, scope const(Child)[] kids)` (design by introspection: without
it the box fills what it is given, Flutter's `getSize => constraints.biggest`).
*/
CustomLayout layout(L)(ref Ui ui, in L params)
{
    static assert(__traits(isPOD, L), "a layout's params are plain data: they are copied as bytes");
    CustomLayout c;
    static if (__traits(hasMember, L, "measure"))
        c.measure = &measureThunk!L;
    c.arrange = &arrangeThunk!L;
    c.params = ui.keep(params);
    c.paramsLen = L.sizeof;
    return c;
}

/// A painter is a POD struct with `static void paint(in P, Rect, ref DrawList)`.
Painter painter(P)(ref Ui ui, in P params)
{
    static assert(__traits(isPOD, P), "a painter's params are plain data");
    return Painter(&paintThunk!P, ui.keep(params), P.sizeof);
}

// ── paint output ────────────────────────────────────────────────────────────

enum OpKind : ubyte { rect, frame, text, line, image, clipPush, clipPop, caret }

struct DrawOp
{
    OpKind kind;
    Slot slot;
    int x, y, w, h;   // rect; a line's start is (x, y), its end (w, h)
    TextId text;
    uint node = none;
    string lit;       // a painter's static text (mechanism c has no text store)
}

/// The frame's draw commands (a display list), in paint order.
struct DrawList
{
    RawBuffer!DrawOp ops;
    @disable this(this);

    void rect(Rect r, Slot s, uint node = none) @safe pure nothrow @nogc
        { ops ~= DrawOp(OpKind.rect, s, r.x, r.y, r.w, r.h, node: node); }
    void frame(Rect r, Slot s, uint node = none) @safe pure nothrow @nogc
        { ops ~= DrawOp(OpKind.frame, s, r.x, r.y, r.w, r.h, node: node); }
    void line(int x0, int y0, int x1, int y1, Slot s) @safe pure nothrow @nogc
        { ops ~= DrawOp(OpKind.line, s, x0, y0, x1, y1); }
    void clear() @safe pure nothrow @nogc { ops.clear(); }
    size_t length() const @safe pure nothrow @nogc => ops.length;
}

// ── the element store (host-owned interaction state, by identity) ───────────

/// Per-element state that outlives a frame (WGT5): what the view reads while
/// building, and what the host writes back after layout.
struct ElemState
{
    int scrollX, scrollY;
    int caret = -1;
    bool focused;
    int lastW, lastH;      // last frame's laid-out size
    int contentW, contentH; // last frame's scrolled content extent
}

/// An open-addressing map id → `ElemState`; a stub of the real store.
struct ElementStore
{
    private static struct Entry { ulong id; ElemState state; }
    private RawBuffer!Entry entries;
    private size_t used;
    @disable this(this);

    ElemState get(ulong id) const @safe pure nothrow @nogc
    {
        if (entries.length == 0)
            return ElemState.init;
        const mask = entries.length - 1;
        for (size_t i = id & mask;; i = (i + 1) & mask)
        {
            if (entries[i].id == id)
                return entries[i].state;
            if (entries[i].id == 0)
                return ElemState.init;
        }
    }

    ref ElemState put(ulong id) return @safe pure nothrow @nogc
    {
        assert(id != 0, "id 0 is the empty slot");
        if ((used + 1) * 2 > entries.length)
            rehash(entries.length ? entries.length * 2 : 64);
        const mask = entries.length - 1;
        size_t i = id & mask;
        for (; entries[i].id != 0 && entries[i].id != id; i = (i + 1) & mask) {}
        if (entries[i].id == 0)
        {
            entries[i].id = id;
            used++;
        }
        return entries[i].state;
    }

    private void rehash(size_t n) @safe pure nothrow @nogc
    {
        RawBuffer!Entry old;
        foreach (ref e; entries[])
            old ~= e;
        entries.clear();
        cast(void) entries.extend(n);
        used = 0;
        foreach (ref e; old[])
            if (e.id != 0)
                put(e.id) = e.state;
    }
}

// ── records ─────────────────────────────────────────────────────────────────

/// One element, appended once at open and finished at close (fit size,
/// children), then given its rectangle by `layout`.
struct NodeRec
{
    Kind kind;
    Dir dir;
    Align alignX, alignY;
    SizeMode wMode, hMode;
    Role role;
    Checked checked;
    Slot slot;
    bool paintBg, clipX, clipY, focusable, mergeSem, floating, keyed, hasValue;
    ubyte border;
    FloatTo floatTo;
    Align attachX;
    ushort gap;
    Pad pad;
    int wValue, hValue;
    uint parent = none;
    uint kidStart, childCount; // `kids[kidStart .. kidStart + childCount]`
    uint position;
    ulong key, id;
    TextId text, label;
    MsgRef msg;
    int value;          // semantics value; a toggle's state; a list's row count
    short floatX, floatY, z;
    uint ext = none;    // index into `exts`
    LayoutData data;    // read by the parent's layout
    int caret = -1;
    Env env;            // the env this element's children see
    uint fitW, fitH;    // intrinsic size, at close
    int x, y, w, h;     // from `layout`, absolute
    int scrollX, scrollY; // from the element store, at build
    int contentW, contentH; // from `layout`, scroll extent
}

private struct MapRec
{
    ulong from, to;
    ApplyThunk apply;
}

private alias ApplyThunk = void function(scope const(void)* from, scope void* to) @system;

/// A node's out-of-line extras: custom layout, painter, `mapMsg`, `memo`,
/// `layoutBuilder`.
private struct ExtRec
{
    CustomLayout custom;
    Painter painter;
    MapRec map;
    ulong memoKey;
    BuildFn build;
    uint buildParams = none, buildParamsLen;
}

private struct MsgRec
{
    ulong typeKey;
    uint value = none, valueLen;
    ApplyThunk payload;
    ulong payloadKey;
}

private struct OpenRec
{
    uint node;
    uint pendingBase;
    ulong id;
}

private struct Pending
{
    uint node;
    uint w, h;
    bool floating;
}

private enum maxDepth = 64;

/**
The frame's builder. Heap-own it (`new Ui`) for big frames: its tables are
malloc'd, but the struct is passed `ref` and never copied.
*/
struct Ui
{
    private RawBuffer!NodeRec nodes;
    private RawBuffer!ExtRec exts;
    private RawBuffer!MsgRec msgs;
    private RawBuffer!ubyte arena;     // POD params and constant messages, 16-aligned
    private TextStore texts;
    private InlineBuffer!(char, 1024) scratch;
    private OpenRec[maxDepth] stack;
    private uint depth;
    private RawBuffer!Pending pending;
    private RawBuffer!uint kids;
    private RawBuffer!Child childScratch;   // the running `arrange`'s children
    private RawBuffer!Child measureScratch; // one `measure` call's (never nested)
    private RawBuffer!int intScratch;
    private bool intsTaken;
    private Env currentEnv;
    private ulong msgKey, appMsgKey;
    private uint nextPos;
    private bool nextKeyed;
    private ulong nextKey;
    private bool building;
    /// Host-owned state, kept across `reset`.
    ElementStore store;

    @disable this(this);

    /// The context the elements open around the caller resolved.
    Env env() const @safe pure nothrow @nogc => currentEnv;

    /// The app's message type.
    void expectMsg(Msg)() { appMsgKey = typeKey!Msg; }

    /// Formats an IES into the frame's scratch (valid until `reset`).
    const(char)[] fmt(Args...)(InterpolationHeader header, Args args,
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

    /// Builds the root view under `env`.
    Node frame(Env env, scope ChildFn[] root...) @safe pure nothrow @nogc
    {
        assert(root.length == 1, "a frame has one root view");
        currentEnv = env;
        msgKey = appMsgKey;
        building = true;
        const r = evalChild(0, root[0]);
        building = false;
        return r;
    }

    /// Drops the frame, keeping the storage and the element store.
    void reset() @safe pure nothrow @nogc
    {
        nodes.clear();
        exts.clear();
        msgs.clear();
        arena.clear();
        texts.clear();
        pending.clear();
        kids.clear();
        scratch.clear();
        depth = 0;
    }

    size_t nodeCount() const @safe pure nothrow @nogc => nodes.length;
    ref const(NodeRec) opIndex(Node n) const return @safe pure nothrow @nogc => nodes[n.index];
    const(uint)[] kidsOf(Node n) const return @safe pure nothrow @nogc
        => kids[nodes[n.index].kidStart .. nodes[n.index].kidStart + nodes[n.index].childCount];
    const(char)[] textOf(Node n) const return @safe pure nothrow @nogc => texts[nodes[n.index].text];
    Rect rectOf(Node n) const @safe pure nothrow @nogc
        => Rect(nodes[n.index].x, nodes[n.index].y, nodes[n.index].w, nodes[n.index].h);

    // ── building ───────────────────────────────────────────────────────────

    package TextId intern(scope const(char)[] s) @safe pure nothrow @nogc => texts.intern(s);

    /// The id the element about to open in the current slot will get: what
    /// a composite reads its element-store state by, before it opens.
    ulong peekId() const @safe pure nothrow @nogc
    {
        const parentId = depth ? stack[depth - 1].id : 0;
        return nextKeyed ? mix(mix(parentId, nextPos), nextKey | 1) : mix(parentId, nextPos);
    }

    /// The element-store state of the element about to open.
    ElemState peekState() const @safe pure nothrow @nogc => store.get(peekId);

    private Node evalChild(uint pos, scope ChildFn child) @safe pure nothrow @nogc
    {
        nextPos = pos;
        return child();
    }

    pragma(inline, true)
    private uint append(ref NodeRec rec, EnvOverride over, bool disabled, out ulong id) @safe pure nothrow @nogc
    {
        const self = cast(uint) nodes.length;
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
        id = rec.keyed ? mix(mix(parentId, rec.position), rec.key | 1) : mix(parentId, rec.position);
        rec.id = id;
        nodes ~= rec;
        return self;
    }

    pragma(inline, true)
    package uint open(NodeRec rec, EnvOverride over, bool disabled) @safe pure nothrow @nogc
    {
        ulong id;
        const self = append(rec, over, disabled, id);
        assert(depth < stack.length, "elements nest too deep");
        stack[depth++] = OpenRec(self, cast(uint) pending.length, id);
        currentEnv = nodes[self].env;
        nextKeyed = false;
        return self;
    }

    /// Closes the innermost element: fit size from its children's run on the
    /// children stack (floating children excluded), run copied into `kids`.
    package void close(Env saved) @safe pure nothrow @nogc
    {
        const o = stack[--depth];
        const run = pending[o.pendingBase .. pending.length];
        ref rec = nodes[o.node];
        uint along, across, flow;
        rec.kidStart = cast(uint) kids.length;
        rec.childCount = cast(uint) run.length;
        const horizontal = rec.dir == Dir.row;
        const overlay = rec.dir == Dir.stack || rec.dir == Dir.anchor;
        foreach (ref c; run)
        {
            kids ~= c.node;
            if (c.floating)
                continue;
            flow++;
            const a = horizontal ? c.w : c.h;
            const b = horizontal ? c.h : c.w;
            if (overlay)
            {
                if (a > along) along = a;
            }
            else
                along += a;
            if (b > across)
                across = b;
        }
        if (flow > 1 && !overlay)
            along += rec.gap * (flow - 1);
        uint w = horizontal ? along : across;
        uint h = horizontal ? across : along;
        if (rec.ext != none && exts[rec.ext].custom.active)
        {
            // A custom layout's intrinsic size, only when an axis fits.
            const c = exts[rec.ext].custom;
            if (c.measure !is null && (rec.wMode == SizeMode.fit || rec.hMode == SizeMode.fit))
            {
                fillChildren(measureScratch, o.node);
                const s = c.measure(params(c.params, c.paramsLen), Constraints.init, measureScratch[]);
                w = s.w;
                h = s.h;
            }
        }
        if (rec.kind == Kind.virtualList) // HYBRID: the list's extent is its rows'
            h = rec.value * rec.gap;
        rec.fitW = sizeOf(rec.wMode, rec.wValue, w + rec.pad.l + rec.pad.r + 2 * rec.border);
        rec.fitH = sizeOf(rec.hMode, rec.hValue, h + rec.pad.t + rec.pad.b + 2 * rec.border);
        pending.length = o.pendingBase;
        pending ~= Pending(o.node, rec.fitW, rec.fitH, rec.floating);
        currentEnv = saved;
    }

    private static uint sizeOf(SizeMode m, int v, uint fit) @safe pure nothrow @nogc
        => m == SizeMode.fixed ? v : m == SizeMode.fit ? fit : 0;

    /// A container: open, evaluate each child slot in order, close.
    package Node container(NodeRec rec, EnvOverride over, bool disabled,
        scope ChildFn[] children) @safe pure nothrow @nogc
    {
        const saved = currentEnv;
        const self = open(rec, over, disabled);
        foreach (i, child; children)
            cast(void) evalChild(cast(uint) i, child);
        close(saved);
        return Node(self);
    }

    /// A leaf with its own content size.
    pragma(inline, true)
    package Node leaf(NodeRec rec, uint w, uint h) @safe pure nothrow @nogc
    {
        rec.fitW = sizeOf(rec.wMode, rec.wValue, w);
        rec.fitH = sizeOf(rec.hMode, rec.hValue, h);
        ulong id;
        const self = append(rec, EnvOverride.init, false, id);
        nextKeyed = false;
        pending ~= Pending(self, rec.fitW, rec.fitH, rec.floating);
        return Node(self);
    }

    package uint addExt(ExtRec e) @safe pure nothrow @nogc
    {
        const self = cast(uint) exts.length;
        exts ~= e;
        return self;
    }

    package MsgRef addMsg(MsgRec rec) @safe pure nothrow @nogc
    {
        const self = MsgRef(cast(uint) msgs.length);
        msgs ~= rec;
        return self;
    }

    package void checkMsg(ulong got) @safe pure nothrow @nogc
    {
        assert(got == msgKey, "ui.on sends another message type than its mapMsg scope expects");
    }

    /// Copies POD `value` into the arena (16-aligned); returns its offset.
    package uint keep(T)(scope ref const T value)
    {
        const at = (arena.length + 15) & ~cast(size_t) 15;
        const padding = at - arena.length;
        auto block = arena.extend(padding + T.sizeof)[padding .. $];
        block[] = (() @trusted => (cast(const(ubyte)*) &value)[0 .. T.sizeof])();
        return cast(uint) at;
    }

    package const(void)[] params(uint at, uint len) const return @safe pure nothrow @nogc
        => at == none ? null : arena[at .. at + len];

    package int[] scratchInts(size_t n) return @safe pure nothrow @nogc
    {
        assert(!intsTaken, "LayoutCtx.ints: one request per arrange");
        intsTaken = true;
        intScratch.clear();
        return intScratch.extend(n);
    }

    private void fillChildren(ref RawBuffer!Child into, uint n) @safe pure nothrow @nogc
    {
        into.clear();
        const r = nodes[n];
        foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
        {
            ref k = nodes[c];
            into ~= Child(k.fitW, k.fitH, k.data, 0, 0, k.fitW, k.fitH);
        }
    }

    // ── layout: top-down, after the build ──────────────────────────────────

    /// Lays out the frame (root = node 0) in `avail` cells.
    void layOut(int availW, int availH) @safe pure nothrow @nogc
    {
        if (nodes.length == 0)
            return;
        ref r = nodes[0];
        r.x = 0;
        r.y = 0;
        r.w = resolve(r.wMode, r.wValue, r.fitW, availW);
        r.h = resolve(r.hMode, r.hValue, r.hMode == SizeMode.fit ? heightFor(0, r.w) : r.fitH, availH);
        arrangeNode(0);
    }

    private static int resolve(SizeMode m, int v, int fit, int avail) @safe pure nothrow @nogc
    {
        final switch (m)
        {
            case SizeMode.fit: return fit;
            case SizeMode.fixed: return v;
            case SizeMode.percent: return avail * v / 100;
            case SizeMode.grow: return avail;
        }
    }

    /// The height node `n` needs at width `w`: text wraps (one cell per code
    /// point, broken anywhere), a custom layout measures, a column sums.
    package int heightFor(uint n, int w) @safe pure nothrow @nogc
    {
        ref const r = nodes[n];
        if (r.hMode == SizeMode.fixed)
            return r.hValue;
        const custom = r.ext != none && exts[r.ext].custom.measure !is null;
        if (w >= cast(int) r.fitW && !custom)
            return r.fitH;
        if (r.kind == Kind.text)
            return w <= 0 ? r.fitH : cast(int) ((r.fitW + w - 1) / w);
        const innerW = w - r.pad.l - r.pad.r - 2 * r.border;
        const extra = r.pad.t + r.pad.b + 2 * r.border;
        if (custom)
        {
            fillChildren(measureScratch, n);
            const c = exts[r.ext].custom;
            return c.measure(params(c.params, c.paramsLen), Constraints(maxW: innerW), measureScratch[]).h + extra;
        }
        if (r.kind == Kind.box && r.dir == Dir.column)
        {
            int sum, flow;
            foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
            {
                if (nodes[c].floating)
                    continue;
                const kw = nodes[c].wMode == SizeMode.grow ? innerW
                    : nodes[c].fitW < innerW ? nodes[c].fitW : innerW;
                sum += heightFor(c, kw);
                flow++;
            }
            return sum + (flow > 1 ? r.gap * (flow - 1) : 0) + extra;
        }
        return r.fitH;
    }

    private void arrangeNode(uint n) @safe pure nothrow @nogc
    {
        const r = nodes[n];
        if (r.childCount == 0 && r.ext == none)
            return;
        const ox = r.x + r.pad.l + r.border, oy = r.y + r.pad.t + r.border;
        const innerW = r.w - r.pad.l - r.pad.r - 2 * r.border;
        const innerH = r.h - r.pad.t - r.pad.b - 2 * r.border;
        const ks = kids[r.kidStart .. r.kidStart + r.childCount];

        if (r.ext != none && exts[r.ext].build !is null)
            buildDeferred(n, Size(innerW, innerH)); // mechanism (b'): build during layout
        const ks2 = kids[nodes[n].kidStart .. nodes[n].kidStart + nodes[n].childCount];

        if (r.ext != none && exts[r.ext].custom.active)
            arrangeCustom(n, ox, oy, innerW, innerH);
        else if (r.kind == Kind.virtualList) // HYBRID
            arrangeVirtual(n, ox, oy, innerW);
        else if (r.dir == Dir.row || r.dir == Dir.column)
            arrangeFlow(n, ox, oy, innerW, innerH);
        else
            arrangeOverlay(n, ox, oy, innerW, innerH);

        // floating children: out of flow, from the parent's or root's origin
        foreach (c; ks2)
        {
            ref k = nodes[c];
            if (!k.floating)
                continue;
            k.w = resolve(k.wMode, k.wValue, k.fitW, innerW);
            k.h = resolve(k.hMode, k.hValue, k.fitH, innerH);
            const baseW = k.floatTo == FloatTo.root ? nodes[0].w : r.w;
            k.x = (k.floatTo == FloatTo.root ? 0 : r.x) + k.floatX
                + (k.attachX == Align.end ? baseW - k.w : k.attachX == Align.center ? (baseW - k.w) / 2 : 0);
            k.y = (k.floatTo == FloatTo.root ? 0 : r.y) + k.floatY;
        }
        foreach (c; ks2)
            arrangeNode(c);
        cast(void) ks;
    }

    private void arrangeFlow(uint n, int ox, int oy, int innerW, int innerH) @safe pure nothrow @nogc
    {
        const r = nodes[n];
        const row = r.dir == Dir.row;
        const ks = kids[r.kidStart .. r.kidStart + r.childCount];
        const main = row ? innerW : innerH;
        const cross = row ? innerH : innerW;
        const scrollMain = row ? r.clipX : r.clipY;
        // widths first (height may depend on width), main-axis sizes, grow weights
        int used, weight, flow;
        foreach (c; ks)
        {
            ref k = nodes[c];
            if (k.floating)
                continue;
            flow++;
            if (row)
            {
                if (k.wMode == SizeMode.grow)
                {
                    weight += k.wValue > 0 ? k.wValue : 1;
                    k.w = 0;
                }
                else
                    k.w = resolve(k.wMode, k.wValue, k.fitW, innerW);
                used += k.w;
            }
            else
            {
                k.w = resolve(k.wMode, k.wValue, k.fitW, innerW);
                if (k.wMode == SizeMode.fit && k.w > innerW && !r.clipX)
                    k.w = innerW;
                if (k.hMode == SizeMode.grow)
                {
                    weight += k.hValue > 0 ? k.hValue : 1;
                    k.h = 0;
                }
                else
                    k.h = k.hMode == SizeMode.fit ? heightFor(c, k.w)
                        : resolve(k.hMode, k.hValue, k.fitH, innerH);
                used += k.h;
            }
        }
        if (flow > 1)
            used += r.gap * (flow - 1);
        int leftover = main - used;
        if (leftover < 0)
            leftover = 0;
        // grow: integer-exact share (LAY6), the remainder to the first ones
        if (weight)
        {
            const q = leftover / weight;
            int rem = leftover % weight;
            foreach (c; ks)
            {
                ref k = nodes[c];
                if (k.floating)
                    continue;
                const m = row ? k.wMode : k.hMode;
                if (m != SizeMode.grow)
                    continue;
                const wt = (row ? k.wValue : k.hValue) > 0 ? (row ? k.wValue : k.hValue) : 1;
                int s = q * wt;
                if (rem)
                {
                    const extra = rem < wt ? rem : wt;
                    s += extra;
                    rem -= extra;
                }
                if (row)
                    k.w = s;
                else
                    k.h = s;
            }
            leftover = 0;
        }
        const mainAlign = row ? r.alignX : r.alignY;
        int at = mainAlign == Align.center ? leftover / 2 : mainAlign == Align.end ? leftover : 0;
        int extent;
        foreach (c; ks)
        {
            ref k = nodes[c];
            if (k.floating)
                continue;
            // cross axis
            if (row)
                k.h = k.hMode == SizeMode.fit ? heightFor(c, k.w) : resolve(k.hMode, k.hValue, k.fitH, innerH);
            const ksize = row ? k.h : k.w;
            const crossAlign = row ? r.alignY : r.alignX;
            const slack = cross - ksize;
            const off = slack <= 0 ? 0 : crossAlign == Align.center ? slack / 2
                : crossAlign == Align.end ? slack : 0;
            if (row)
            {
                k.x = ox + at - r.scrollX;
                k.y = oy + off;
                at += k.w + r.gap;
            }
            else
            {
                k.x = ox + off;
                k.y = oy + at - r.scrollY;
                at += k.h + r.gap;
            }
        }
        extent = flow ? at - r.gap : 0;
        if (scrollMain)
        {
            if (row)
                nodes[n].contentW = extent;
            else
                nodes[n].contentH = extent;
        }
    }

    /// `stack` (aligned overlay) and `anchor` (mechanism d) children.
    private void arrangeOverlay(uint n, int ox, int oy, int innerW, int innerH) @safe pure nothrow @nogc
    {
        const r = nodes[n];
        foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
        {
            ref k = nodes[c];
            if (k.floating)
                continue;
            k.w = resolve(k.wMode, k.wValue, k.fitW, innerW);
            k.h = k.hMode == SizeMode.fit ? heightFor(c, k.w) : resolve(k.hMode, k.hValue, k.fitH, innerH);
            if (r.dir == Dir.anchor)
            {
                k.x = ox + divRound(innerW * k.data.a, 10_000) - divRound(k.w * k.data.c, 10_000);
                k.y = oy + divRound(innerH * k.data.b, 10_000) - divRound(k.h * k.data.d, 10_000);
            }
            else
            {
                const sx = innerW - k.w, sy = innerH - k.h;
                k.x = ox + (r.alignX == Align.center ? sx / 2 : r.alignX == Align.end ? sx : 0);
                k.y = oy + (r.alignY == Align.center ? sy / 2 : r.alignY == Align.end ? sy : 0);
            }
        }
    }

    /// Mechanism (a): the layout's `arrange` places the children.
    private void arrangeCustom(uint n, int ox, int oy, int innerW, int innerH) @safe pure nothrow @nogc
    {
        const r = nodes[n];
        const c = exts[r.ext].custom;
        fillChildren(childScratch, n);
        auto ctx = LayoutCtx(&this, kids[r.kidStart .. r.kidStart + r.childCount]);
        intsTaken = false;
        c.arrange(params(c.params, c.paramsLen), Size(innerW, innerH), childScratch[], ctx);
        foreach (i, k; kids[r.kidStart .. r.kidStart + r.childCount])
        {
            const ch = childScratch[i];
            nodes[k].x = ox + ch.x - r.scrollX;
            nodes[k].y = oy + ch.y - r.scrollY;
            nodes[k].w = ch.w;
            nodes[k].h = ch.h;
        }
    }

    /// HYBRID: a virtual list's rows sit at `(first + i) × rowHeight`.
    private void arrangeVirtual(uint n, int ox, int oy, int innerW) @safe pure nothrow @nogc
    {
        const r = nodes[n];
        foreach (i, c; kids[r.kidStart .. r.kidStart + r.childCount])
        {
            ref k = nodes[c];
            k.w = k.wMode == SizeMode.fit ? (k.fitW < innerW ? k.fitW : innerW) : resolve(k.wMode, k.wValue, k.fitW, innerW);
            k.h = r.gap;
            k.x = ox;
            k.y = oy + (r.data.a + cast(int) i) * r.gap - r.scrollY;
        }
        nodes[n].contentH = r.value * r.gap;
    }

    /// Mechanism (b'): `layoutBuilder` builds its subtree once its size is
    /// known — during layout, appending nodes after the main build's.
    private void buildDeferred(uint n, Size avail) @safe pure nothrow @nogc
    {
        const e = exts[nodes[n].ext];
        // Re-open `n` (its id and env) and build into it.
        const saved = currentEnv;
        currentEnv = nodes[n].env;
        depth = 0;
        stack[depth++] = OpenRec(n, cast(uint) pending.length, nodes[n].id);
        building = true;
        nextPos = 0;
        cast(void) e.build(this, params(e.buildParams, e.buildParamsLen), avail);
        building = false;
        // close: only the kid list (the parent's size is already decided)
        const o = stack[--depth];
        const run = pending[o.pendingBase .. pending.length];
        nodes[n].kidStart = cast(uint) kids.length;
        nodes[n].childCount = cast(uint) run.length;
        foreach (ref p; run)
            kids ~= p.node;
        pending.length = o.pendingBase;
        currentEnv = saved;
    }

    // ── after layout: the element store ────────────────────────────────────

    /// What the host writes back after layout: every scrolling or tracked
    /// element's size and content extent, by id (Clay's element data).
    void commitStore() @safe pure nothrow @nogc
    {
        foreach (ref r; nodes[])
            if (r.clipX || r.clipY || r.kind == Kind.scrollView || r.kind == Kind.virtualList
                || r.kind == Kind.textInput || r.role == Role.clock)
            {
                ref s = store.put(r.id);
                s.lastW = r.w;
                s.lastH = r.h;
                s.contentW = r.contentW;
                s.contentH = r.contentH;
            }
    }

    // ── paint ──────────────────────────────────────────────────────────────

    void paint(ref DrawList list) @safe pure nothrow @nogc
    {
        if (nodes.length)
            paintNode(0, list);
    }

    private void paintNode(uint n, ref DrawList list) @safe pure nothrow @nogc
    {
        const r = nodes[n];
        const rect = Rect(r.x, r.y, r.w, r.h);
        if (r.paintBg)
            list.rect(rect, r.slot, n);
        if (r.border)
            list.frame(rect, Slot.border, n);
        final switch (r.kind)
        {
            case Kind.box, Kind.mapMsg, Kind.memo, Kind.scrollView, Kind.virtualList:
                break;
            case Kind.text:
                list.ops ~= DrawOp(OpKind.text, r.slot, r.x, r.y, r.w, r.h, r.text, n);
                if (r.caret >= 0)
                    list.ops ~= DrawOp(OpKind.caret, Slot.caret, r.x + r.caret, r.y, 1, 1, node: n);
                break;
            case Kind.image:
                list.ops ~= DrawOp(OpKind.image, r.slot, r.x, r.y, r.w, r.h, r.label, n);
                break;
            case Kind.custom:
                const p = exts[r.ext].painter;
                p.paint(params(p.params, p.paramsLen), rect, list);
                break;
            case Kind.toggle: // HYBRID: the backend draws the switch
                list.rect(Rect(r.x, r.y, 4, r.h), r.value ? Slot.controlOn : Slot.sunken, n);
                list.rect(Rect(r.x + (r.value ? 2 : 0), r.y, 2, r.h), Slot.knob, n);
                list.ops ~= DrawOp(OpKind.text, Slot.body, r.x + 5, r.y, r.w - 5, r.h, r.text, n);
                break;
            case Kind.textInput: // HYBRID
                list.frame(rect, Slot.border, n);
                list.ops ~= DrawOp(OpKind.text, Slot.body, r.x + 1, r.y, r.w - 2, 1, r.text, n);
                if (r.caret >= 0)
                    list.ops ~= DrawOp(OpKind.caret, Slot.caret, r.x + 1 + r.caret, r.y, 1, 1, node: n);
                break;
        }
        const clips = r.clipX || r.clipY || r.kind == Kind.scrollView || r.kind == Kind.virtualList;
        if (clips)
            list.ops ~= DrawOp(OpKind.clipPush, Slot.none, r.x, r.y, r.w, r.h, node: n);
        const ks = kids[r.kidStart .. r.kidStart + r.childCount];
        foreach (c; ks)
            if (!nodes[c].floating)
                paintNode(c, list);
        foreach (c; ks)
            if (nodes[c].floating)
                paintNode(c, list);
        if (clips)
            list.ops ~= DrawOp(OpKind.clipPop, node: n);
        if (r.kind == Kind.scrollView || r.kind == Kind.virtualList) // HYBRID: the bar
        {
            const content = r.contentH > r.h ? r.contentH : r.h;
            const thumbH = content ? r.h * r.h / content : r.h;
            list.rect(Rect(r.x + r.w - 1, r.y + (content ? r.scrollY * r.h / content : 0), 1,
                thumbH > 0 ? thumbH : 1), Slot.thumb, n);
        }
    }

    // ── hit testing, focus, routing ─────────────────────────────────────────

    /// The deepest node under `(px, py)` (later siblings and floating ones on
    /// top), honouring clips.
    Node hitTest(int px, int py) const @safe pure nothrow @nogc
        => nodes.length ? Node(hitFrom(0, px, py)) : Node.init;

    private uint hitFrom(uint n, int px, int py) const @safe pure nothrow @nogc
    {
        const r = nodes[n];
        const inside = Rect(r.x, r.y, r.w, r.h).contains(px, py);
        const clips = r.clipX || r.clipY || r.kind == Kind.scrollView || r.kind == Kind.virtualList;
        if (!inside && clips)
            return none;
        const ks = kids[r.kidStart .. r.kidStart + r.childCount];
        foreach_reverse (c; ks)
            if (nodes[c].floating)
            {
                const h = hitFrom(c, px, py);
                if (h != none)
                    return h;
            }
        foreach_reverse (c; ks)
            if (!nodes[c].floating)
            {
                const h = hitFrom(c, px, py);
                if (h != none)
                    return h;
            }
        return inside ? n : none;
    }

    /// Where a press at `(px, py)` goes: the hit node or its nearest ancestor
    /// with a message (a composite's inner boxes bubble to its outer one).
    Node pressTarget(int px, int py) const @safe pure nothrow @nogc
    {
        for (uint n = hitTest(px, py).index; n != none && n < nodes.length; n = nodes[n].parent)
            if (nodes[n].msg.isSet && !nodes[n].env.disabled)
                return Node(n);
        return Node.init;
    }

    /// The role a node exposes; hybrid kinds imply theirs.
    Role roleOf(Node n) const @safe pure nothrow @nogc
    {
        const r = nodes[n.index];
        if (r.role != Role.none)
            return r.role;
        switch (r.kind) // HYBRID
        {
            case Kind.toggle: return Role.switch_;
            case Kind.textInput: return Role.textField;
            case Kind.scrollView: return Role.scrollArea;
            case Kind.virtualList: return Role.list;
            default: return Role.none;
        }
    }

    /// Whether a node takes focus (in tree order).
    bool focusableAt(Node n) const @safe pure nothrow @nogc
    {
        const r = nodes[n.index];
        return (r.focusable || r.kind == Kind.toggle || r.kind == Kind.textInput) && !r.env.disabled; // HYBRID
    }

    /// The label a node exposes: its own, its text (hybrid kinds), or its
    /// first text descendant's when it merges.
    const(char)[] labelOf(Node n) const return @safe pure nothrow @nogc
    {
        const r = nodes[n.index];
        if (r.label.isSet)
            return texts[r.label];
        if (r.kind == Kind.toggle || r.kind == Kind.text) // HYBRID: toggle
            return texts[r.text];
        if (r.mergeSem)
            return firstText(n.index);
        return null;
    }

    private const(char)[] firstText(uint n) const return @safe pure nothrow @nogc
    {
        const r = nodes[n];
        foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
        {
            if (nodes[c].kind == Kind.text)
                return texts[nodes[c].text];
            if (const t = firstText(c))
                return t;
        }
        return null;
    }

    /// Checked state: semantics, or a hybrid toggle's value.
    Checked checkedOf(Node n) const @safe pure nothrow @nogc
    {
        const r = nodes[n.index];
        if (r.kind == Kind.toggle) // HYBRID
            return r.value ? Checked.on : Checked.off;
        return r.checked;
    }

    /// The first node with `role` whose label is `label` (how a test finds
    /// "the toggle labelled X" in either library).
    Node find(Role role, scope const(char)[] label) const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. cast(uint) nodes.length)
            if (roleOf(Node(i)) == role && labelOf(Node(i)) == label)
                return Node(i);
        return Node.init;
    }

    /// Focusable nodes in tree (pre-)order: the Tab order.
    void focusOrder(W)(scope W sink) const
    {
        if (nodes.length)
            focusFrom(0, sink);
    }

    private void focusFrom(W)(uint n, scope W sink) const
    {
        if (focusableAt(Node(n)))
            sink(Node(n));
        foreach (c; kids[nodes[n].kidStart .. nodes[n].kidStart + nodes[n].childCount])
            focusFrom(c, sink);
    }

    /// The semantics tree: nodes with a role, under their nearest ancestor
    /// with one; a merging node hides its descendants.
    void semantics(W)(scope W write) const
    {
        if (nodes.length)
            semFrom(0, 0, write);
    }

    private void semFrom(W)(uint n, uint depth, scope W write) const
    {
        const role = roleOf(Node(n));
        uint d = depth;
        if (role != Role.none)
        {
            UniqueBuffer!(char, 200) line;
            line.writeText(i"$(role.enumMemberName)");
            if (const l = labelOf(Node(n)))
                line.writeText(i` "$(l)"`);
            const ch = checkedOf(Node(n));
            if (ch != Checked.none)
                line.writeText(i" checked=$(ch.enumMemberName)");
            if (nodes[n].hasValue)
                line.writeText(i" value=$(nodes[n].value)");
            if (focusableAt(Node(n)))
                line.writeText(i" focusable");
            if (nodes[n].msg.isSet)
                line.writeText(i" [press]");
            line.writeText(i" @$(nodes[n].x),$(nodes[n].y) $(nodes[n].w)×$(nodes[n].h)");
            write(depth, line[]);
            d++;
            if (nodes[n].mergeSem || nodes[n].kind == Kind.toggle)
                return;
        }
        foreach (c; kids[nodes[n].kidStart .. nodes[n].kidStart + nodes[n].childCount])
            semFrom(c, d, write);
    }

    /// The tree, indented: kind, text, rect, `[msg]`.
    void dump(W)(scope W write) const
    {
        if (nodes.length)
            dumpFrom(0, 0, write);
    }

    private void dumpFrom(W)(uint n, uint depth, scope W write) const
    {
        const r = nodes[n];
        UniqueBuffer!(char, 200) line;
        line.writeText(i"$(r.kind.enumMemberName)");
        if (r.kind == Kind.box)
            line.writeText(i".$(r.dir.enumMemberName)");
        if (r.text.isSet)
            line.writeText(i` "$(texts[r.text])"`);
        line.writeText(i" @$(r.x),$(r.y) $(r.w)×$(r.h)");
        if (r.msg.isSet)
            line.writeText(i" [msg]");
        write(depth, line[]);
        foreach (c; kids[r.kidStart .. r.kidStart + r.childCount])
            dumpFrom(c, depth + 1, write);
    }

    /// Delivers the message `target` sends, as the app's `Msg`.
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
            a[0 .. m.valueLen] = arena[m.value .. m.value + m.valueLen];
        for (uint n = nodes[target.index].parent; n != none; n = nodes[n].parent)
            if (nodes[n].kind == Kind.mapMsg)
            {
                const mr = exts[nodes[n].ext].map;
                assert(mr.from == key, "a message reached a mapMsg of another type");
                (() @trusted => mr.apply(&a[0], &b[0]))();
                a = b;
                key = mr.to;
            }
        assert(key == typeKey!Msg, "the message is not the app's Msg");
        deliver((() @trusted => *cast(Msg*) &a[0])());
    }

    /// Checksum of every node's kind, rect and child count (cross-checks).
    ulong layoutHash() const @safe pure nothrow @nogc
    {
        ulong h = 1469598103934665603UL;
        foreach (ref r; nodes[])
            foreach (v; [cast(int) r.kind, r.x, r.y, r.w, r.h, cast(int) r.childCount])
                h = (h ^ cast(uint) v) * 1099511628211UL;
        return h;
    }
}

int divRound(int a, int b) @safe pure nothrow @nogc
    => a >= 0 ? (a + b / 2) / b : -((-a + b / 2) / b);

/// Display width of UTF-8 text: one cell per code point.
uint cells(scope const(char)[] s) @safe pure nothrow @nogc
{
    uint n;
    foreach (c; s)
        n += (c & 0xC0) != 0x80;
    return n;
}

uint digits(int v) @safe pure nothrow @nogc
{
    uint n = v < 0 ? 2 : 1;
    for (v /= 10; v; v /= 10)
        n++;
    return n;
}

// ── the element types ───────────────────────────────────────────────────────

private NodeRec boxRec(ref Ui ui, Kind kind, in Lay layout, Slot bg, ubyte border, Scroll scroll,
    Floating floating, Sem sem, scope const(char)[] label, MsgRef onPress, LayoutData data) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = kind;
    r.dir = layout.dir;
    r.gap = layout.gap;
    r.pad = layout.pad;
    r.wMode = layout.w.mode;
    r.wValue = layout.w.value;
    r.hMode = layout.h.mode;
    r.hValue = layout.h.value;
    r.alignX = layout.alignX;
    r.alignY = layout.alignY;
    r.slot = bg;
    r.paintBg = bg != Slot.none;
    r.border = border;
    r.clipX = scroll.x;
    r.clipY = scroll.y;
    r.floating = floating.active;
    r.floatX = floating.x;
    r.floatY = floating.y;
    r.z = floating.z;
    r.floatTo = floating.to;
    r.attachX = floating.attachX;
    r.role = sem.role;
    r.checked = sem.checked;
    r.focusable = sem.focusable;
    r.mergeSem = sem.merge;
    r.hasValue = sem.hasValue;
    r.value = sem.value;
    r.label = ui.intern(label);
    r.msg = onPress;
    r.data = data;
    if (scroll.x || scroll.y)
    {
        const s = ui.peekState;
        r.scrollX = scroll.x ? s.scrollX : 0;
        r.scrollY = scroll.y ? s.scrollY : 0;
    }
    return r;
}

/**
The one element type: a rectangle that lays out its children, with optional
sub-configs as named attributes (Clay's `CLAY({ .layout, .backgroundColor,
.border, .clip, .floating, .custom })`, plus semantics and a press message).
*/
Node box(ref Ui ui, NamedOnly _ = NamedOnly.init, Lay layout = Lay.init, Slot bg = Slot.none,
    ubyte border = 0, Scroll scroll = Scroll.init, Floating floating = Floating.init,
    Sem sem = Sem.init, scope const(char)[] label = null, MsgRef onPress = MsgRef.init,
    CustomLayout custom = CustomLayout.init, LayoutData data = LayoutData.init,
    EnvOverride env = EnvOverride.init, bool disabled = false,
    NamedOnly _children = NamedOnly.init, scope ChildFn[] children...) @safe pure nothrow @nogc
{
    auto r = boxRec(ui, Kind.box, layout, bg, border, scroll, floating, sem, label, onPress, data);
    if (custom.active)
    {
        ExtRec e;
        e.custom = custom;
        r.ext = ui.addExt(e);
    }
    return ui.container(r, env, disabled, children);
}

enum Wrap : ubyte { chars, none }

/// The one measured leaf: a run of text (wraps at any code point).
Node text(ref Ui ui, NamedOnly _ = NamedOnly.init, scope const(char)[] text = null,
    Slot slot = Slot.body, Wrap wrap = Wrap.chars, Sizing w = Sizing.fit, Sizing h = Sizing.fit,
    LayoutData data = LayoutData.init, Floating floating = Floating.init, int caret = -1,
    Role role = Role.none) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.text;
    r.slot = slot;
    r.text = ui.intern(text);
    r.wMode = w.mode;
    r.wValue = w.value;
    r.hMode = wrap == Wrap.none && h.mode == SizeMode.fit ? SizeMode.fixed : h.mode;
    r.hValue = wrap == Wrap.none && h.mode == SizeMode.fit ? 1 : h.value;
    r.data = data;
    r.floating = floating.active;
    r.floatX = floating.x;
    r.floatY = floating.y;
    r.floatTo = floating.to;
    r.attachX = floating.attachX;
    r.caret = caret;
    r.role = role;
    return ui.leaf(r, text.cells, 1);
}

/// Escape hatch: a raster by handle, at a fixed size, with alt text.
Node image(ref Ui ui, NamedOnly _ = NamedOnly.init, uint handle = 0, int w = 1, int h = 1,
    scope const(char)[] alt = null, LayoutData data = LayoutData.init) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.image;
    r.value = handle;
    r.role = Role.image;
    r.label = ui.intern(alt);
    r.wMode = SizeMode.fixed;
    r.wValue = w;
    r.hMode = SizeMode.fixed;
    r.hValue = h;
    r.data = data;
    return ui.leaf(r, w, h);
}

/// Escape hatch (mechanism c): a paint-only leaf whose painter emits draw
/// commands into the rectangle layout gives it.
Node custom(ref Ui ui, NamedOnly _ = NamedOnly.init, Painter paint = Painter.init,
    Sizing w = Sizing.grow, Sizing h = Sizing.grow, LayoutData data = LayoutData.init,
    Sem sem = Sem.init, scope const(char)[] label = null) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.custom;
    r.wMode = w.mode;
    r.wValue = w.value;
    r.hMode = h.mode;
    r.hValue = h.value;
    r.data = data;
    r.role = sem.role;
    r.label = ui.intern(label);
    ExtRec e;
    e.painter = paint;
    r.ext = ui.addExt(e);
    return ui.leaf(r, 0, 0);
}

/**
Mechanism (b'): a box whose children are built *during layout*, once its
size is known (Flutter's `LayoutBuilder`, Compose's `BoxWithConstraints`).
`fn(ref Ui, in P params, Size avail)` must not capture: its data is `params`.
*/
Node layoutBuilder(alias fn, P)(ref Ui ui, NamedOnly _ = NamedOnly.init, in P params = P.init,
    Lay layout = Lay.init, Sem sem = Sem.init)
{
    auto r = boxRec(ui, Kind.box, layout, Slot.none, 0, Scroll.init, Floating.init, sem, null,
        MsgRef.init, LayoutData.init);
    ExtRec e;
    e.build = &buildThunk!(fn, P);
    e.buildParams = ui.keep(params);
    e.buildParamsLen = P.sizeof;
    r.ext = ui.addExt(e);
    return ui.container(r, EnvOverride.init, false, null);
}

// ── HYBRID primitives (the hybrid widget library's only extra surface) ──────

/// A switch as one leaf: track, knob and label drawn by the backend.
Node toggleLeaf(ref Ui ui, bool on, scope const(char)[] label, MsgRef onPress) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.toggle;
    r.value = on;
    r.text = ui.intern(label);
    r.msg = onPress;
    return ui.leaf(r, 5 + label.cells, ui.env.controlRows);
}

/// A single-line text field; the caret comes from the element store.
Node textInputLeaf(ref Ui ui, scope const(char)[] value, int width, MsgRef onEdit) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.textInput;
    r.text = ui.intern(value);
    r.hasValue = false;
    r.msg = onEdit;
    r.caret = ui.peekState.caret;
    r.wMode = SizeMode.fixed;
    r.wValue = width;
    return ui.leaf(r, width, 1);
}

/// A clipped, scrolled column with a bar; the offset from the element store.
Node scrollViewBox(ref Ui ui, Sizing h, scope ChildFn[] children) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.scrollView;
    r.dir = Dir.column;
    r.wMode = SizeMode.grow;
    r.hMode = h.mode;
    r.hValue = h.value;
    r.clipY = true;
    r.pad.r = 1; // the bar's gutter
    r.scrollY = ui.peekState.scrollY;
    return ui.container(r, EnvOverride.init, false, children);
}

/// A virtual list: only the rows `[first, last)` are built (by the caller).
Node virtualListOpen(ref Ui ui, int count, int rowHeight, int first, Sizing h,
    scope ChildFn[] rows...) @safe pure nothrow @nogc
{
    NodeRec r;
    r.kind = Kind.virtualList;
    r.dir = Dir.column;
    r.wMode = SizeMode.grow;
    r.hMode = h.mode;
    r.hValue = h.value;
    r.value = count;
    r.gap = cast(ushort) rowHeight;
    r.data.a = first;
    r.pad.r = 1;
    r.scrollY = ui.peekState.scrollY;
    return ui.container(r, EnvOverride.init, false, rows);
}

// ── lists: keys are mandatory ───────────────────────────────────────────────

/// A range bound to the builder; offers `mapKeyed`/`mapByIndex`, no `map`.
struct UiRange(R)
{
    R range;
    Ui* ui;
}

/// ditto
auto toUi(R)(R r, return ref Ui ui) => UiRange!R(r, &ui);

/// Splices one keyed row per element into the argument position it occupies.
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
    return Node.none;
}

/// ditto, position as the key (static or append-only lists).
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

// ── messages ────────────────────────────────────────────────────────────────

/// A constant message, copied into the frame's arena.
MsgRef on(M)(ref Ui ui, M value)
{
    static assert(__traits(isPOD, M), "a message is plain data: it is copied as bytes");
    ui.checkMsg(typeKey!M);
    return ui.addMsg(MsgRec(typeKey: typeKey!M, value: ui.keep(value), valueLen: M.sizeof));
}

/// A message built from a component's `int` payload. `fn` may not capture.
MsgRef on(alias fn)(ref Ui ui)
{
    ui.checkMsg(typeKey!(ReturnType!fn));
    return ui.addMsg(MsgRec(typeKey: typeKey!(ReturnType!fn), payload: &applyErased!fn,
        payloadKey: typeKey!(Parameters!fn[0])));
}

/// Lifts every message its child sends with `fn`.
Node mapMsg(alias fn)(ref Ui ui, scope ChildFn[] children...)
{
    alias From = Parameters!fn[0];
    alias To = ReturnType!fn;
    assert(typeKey!To == ui.msgKey, "mapMsg lifts into another type than its scope expects");
    const saved = ui.currentEnv;
    const savedKey = ui.msgKey;
    ExtRec e;
    e.map = MapRec(typeKey!From, typeKey!To, &applyErased!fn);
    NodeRec r;
    r.kind = Kind.mapMsg;
    r.ext = ui.addExt(e);
    const self = ui.open(r, EnvOverride.init, false);
    ui.msgKey = typeKey!From;
    foreach (i, child; children)
        cast(void) ui.evalChild(cast(uint) i, child);
    ui.msgKey = savedKey;
    ui.close(saved);
    return Node(self);
}

private void applyErased(alias fn)(scope const(void)* from, scope void* to) @system
{
    alias Src = const Parameters!fn[0];
    alias Dst = ReturnType!fn;
    emplace(cast(Dst*) to, fn(*cast(Src*) from));
}

/// A memo site keyed by `fn`'s arguments and the env (the seam a host uses
/// to splice last frame's subtree when the key is unchanged).
Node memo(alias fn, Args...)(ref Ui ui, auto ref const Args args)
{
    static assert(functionAttributes!fn & FunctionAttribute.pure_, "a memoised composite must be `pure`");
    ulong key = hashOf(ui.currentEnv);
    static foreach (i; 0 .. Args.length)
        key = mix(key, hashOf(args[i]));
    const saved = ui.currentEnv;
    ExtRec e;
    e.memoKey = key;
    NodeRec r;
    r.kind = Kind.memo;
    r.ext = ui.addExt(e);
    const self = ui.open(r, EnvOverride.init, false);
    cast(void) ui.evalChild(0, () => fn(ui, args));
    ui.close(saved);
    return Node(self);
}
