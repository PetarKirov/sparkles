/**
A thin D face for Clay (`clay_impl.c`, compiled by ImportC), for the build
benchmark: the calls Clay's C macros expand to, wrapped so a view reads like
the other builders' views — and nothing more between the view and Clay.

    CLAY_AUTO_ID({ .layout = { .layoutDirection = CLAY_TOP_TO_BOTTOM, .childGap = 1 } }) { … }

becomes

    with (ui.column(gap: 1)) { … }

which is `Clay__OpenElement(); Clay__ConfigureOpenElement(decl);` at the
`with` and `Clay__CloseElement()` when it ends (the macro's `for` latch). A
keyed element is `Clay__OpenElementWithId(Clay__HashString(key,
Clay_GetOpenElementId()))`, i.e. `CLAY(CLAY_SID_LOCAL(key), …)`.

Leaves are Clay elements with FIXED sizing (the width computed here, as the
other builders compute it) and a background colour, so each leaf emits one
render command at `Clay_EndLayout`. Clay text elements cannot reproduce the
other builders' leaf sizes without a different tree (see README.md).

`Side` = `true` adds the per-leaf side work the sketches' builders do and Clay
does not: every text interned into a `BumpTextPool` (a copy) and every
`ui.on(msg)` copied into an argument arena and a message table, as
`lazystack.Ui.on` does.
*/
module clayui;

import core.interpolation : InterpolationFooter, InterpolationHeader;
import std.experimental.allocator.building_blocks.region : InSituRegion;

import sparkles.base.buffer : BoundedSink, InlineBuffer;
import sparkles.base.text.writers : writeText;

import benchtext : BumpTextPool, FrameBuf;
import treehash : treeHash;

public import clay_impl;

/// What each element is, for the tree checksum; kept in the declaration's
/// `userData` (Clay copies it into the element, at no extra cost). Names as
/// in the other builders' `Kind`.
enum Kind : ubyte { column, row, label, toggle, numberField, keyValue }

private immutable string[6] kindName = ["column", "row", "label", "toggle", "numberField", "keyValue"];

/// `Density`, as the other builders' `Env` carries it.
enum Density : ubyte { compact, comfortable }

private extern (C) void countError(Clay_ErrorData e) nothrow @nogc
{
    auto counts = cast(uint*) e.userData;
    counts[e.errorType == CLAY_ERROR_TYPE_DUPLICATE_ID ? 1 : 0]++;
}

/// One message, as `lazystack.MsgRec`: its type key and its bytes in the arena.
private struct MsgRec { ulong typeKey; const(void)[] value; }

private ulong fnv(scope const(char)[] s) @safe pure nothrow @nogc
{
    ulong h = 0xcbf29ce484222325;
    foreach (c; s)
        h = (h ^ c) * 0x100000001b3;
    return h;
}

/// A handle to a message, as the other builders' `MsgRef`.
struct MsgRef { uint index = uint.max; }

/**
One Clay context, sized for `maxElements` elements, owned (malloc'd) by this
struct. Clay's context is a global (`Clay__currentContext`): `begin` makes
this one current.
*/
struct ClayUi(bool Side = false)
{
    private void* memory;
    private Clay_Context* ctx;
    private uint[2] errors; // [other, duplicate id]
    Density density = Density.comfortable;
    private InlineBuffer!(char, 1024) scratch;
    static if (Side)
    {
        private BumpTextPool texts;
        private FrameBuf!MsgRec msgs;
        private InSituRegion!(8 << 20) argArena;
    }

    @disable this(this);

    /// Allocates and initialises the context. The layout root is huge so that
    /// nothing is shrunk to fit or culled.
    void setup(int maxElements) @trusted nothrow @nogc
    {
        import core.stdc.stdlib : malloc;

        Clay_SetCurrentContext(null); // the defaults below apply to a new context only
        Clay_SetMaxElementCount(maxElements);
        const size = Clay_MinMemorySize();
        memory = malloc(size);
        assert(memory !is null, "out of memory");
        auto arena = Clay_CreateArenaWithCapacityAndMemory(size, memory);
        ctx = Clay_Initialize(arena, Clay_Dimensions(1e9, 1e9),
            Clay_ErrorHandler(&countError, &errors[0]));
        assert(ctx !is null, "Clay_Initialize failed");
        Clay_SetMeasureTextFunction(&measureCells, null);
    }

    ~this() @trusted nothrow @nogc
    {
        import core.stdc.stdlib : free;

        if (Clay_GetCurrentContext() is ctx)
            Clay_SetCurrentContext(null);
        free(memory);
    }

    /// Bytes Clay asked for.
    size_t memorySize() const @trusted nothrow @nogc => ctx.internalArena.capacity;

    /// `Clay_BeginLayout` on this context.
    void begin() @trusted nothrow @nogc
    {
        Clay_SetCurrentContext(ctx);
        Clay_BeginLayout();
    }

    /// `Clay_EndLayout`: the remaining layout passes and the render commands.
    Clay_RenderCommandArray end() @trusted nothrow @nogc => Clay_EndLayout(0);

    /// Errors Clay reported, other than duplicate ids (which it resolves).
    uint errorCount() const @safe nothrow @nogc => errors[0];
    /// Duplicate-id reports (auto ids are 32-bit hashes; see README.md).
    uint duplicateIds() const @safe nothrow @nogc => errors[1];

    /// Drops the frame's side tables, keeping the storage.
    void reset() @trusted nothrow @nogc
    {
        scratch.clear();
        static if (Side)
        {
            texts.clearAll();
            msgs.clear(releaseStorage: false);
            argArena.deallocateAll();
        }
    }

    /// Formats an IES into the frame's scratch, as `lazystack.Ui.text`.
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

    /// A message handle. Without `Side`, nothing is stored (Clay has no
    /// message table; an app would check `Clay_PointerOver(id)` instead).
    MsgRef on(M)(M value)
    {
        static if (Side)
        {
            static assert(__traits(isPOD, M), "a message is plain data: it is copied as bytes");
            const block = () @trusted {
                auto b = argArena.allocate(M.sizeof);
                if (b !is null)
                    b[] = (cast(const(void)*) &value)[0 .. M.sizeof];
                return b;
            }();
            assert(block !is null, "the frame's argument arena is full");
            const self = MsgRef(cast(uint) msgs.length);
            msgs ~= MsgRec(fnv(M.mangleof), block);
            return self;
        }
        else
            return MsgRef.init;
    }

    pragma(inline, true)
    private void keep(scope const(char)[] s) @safe pure nothrow @nogc
    {
        static if (Side)
            if (s.length)
                cast(void) texts.intern(s);
    }

    // ── the tree, read back from Clay's own element storage ────────────────

    /// The view's root: the first element opened after Clay's root container.
    enum int viewRoot = 1;

    /// Elements Clay holds this frame (its root container included).
    size_t elementCount() const @trusted nothrow @nogc => ctx.layoutElements.length;

    /// Pre-order checksum of the subtree under element `i`, read from
    /// `layoutElements[i]`: `dimensions` (the fit size `Clay__CloseElement`
    /// computed), `children.elements[0 .. children.length]`, and the kind in
    /// `config.userData`.
    void checksum(int i, ref ulong h, ref size_t count) const @trusted nothrow @nogc
    {
        const e = &ctx.layoutElements.internalArray[i];
        assert(!e.isTextElement, "this bench declares no text elements");
        const kind = cast(size_t) e.config.userData - 1;
        h = treeHash(h, kindName[kind], cast(uint) e.dimensions.width,
            cast(uint) e.dimensions.height, e.children.length);
        count++;
        foreach (c; e.children.elements[0 .. e.children.length])
            checksum(c, h, count);
    }
}

/// `Clay_String` over a D slice; `isStaticallyAllocated` as the macros set it
/// for literals (the bench's strings outlive every frame).
pragma(inline, true)
Clay_String clayString(const(char)[] s) @trusted pure nothrow @nogc
    => Clay_String(true, cast(int) s.length, s.ptr);

private extern (C) Clay_Dimensions measureCells(Clay_StringSlice text,
    Clay_TextElementConfig* config, void* userData) nothrow @nogc
    => Clay_Dimensions(cells(text.chars[0 .. text.length]), 1);

/// Display width of UTF-8 text: one cell per code point (as `lazystack.cells`).
uint cells(scope const(char)[] s) @safe pure nothrow @nogc
{
    uint n;
    foreach (c; s)
        n += (c & 0xC0) != 0x80;
    return n;
}

/// Decimal digits of `v` (as `lazystack.digits`).
uint digits(int v) @safe pure nothrow @nogc
{
    uint n = v < 0 ? 2 : 1;
    for (v /= 10; v; v /= 10)
        n++;
    return n;
}

// ── containers: `with (ui.column(gap: 1)) { … }` ─────────────────────────

/// Closes the element it was returned for when the `with` scope ends.
struct Open
{
    private bool live;
    @disable this(this);
    pragma(inline, true)
    ~this() @trusted nothrow @nogc
    {
        if (live)
            Clay__CloseElement();
    }
}

pragma(inline, true)
private Open container(Kind kind, Clay_LayoutDirection dir, int gap) @trusted nothrow @nogc
{
    Clay__OpenElement();
    Clay_ElementDeclaration d; // all FIT, no padding: Clay's defaults
    d.layout.layoutDirection = dir;
    d.layout.childGap = cast(ushort) gap;
    d.userData = cast(void*) (kind + 1);
    Clay__ConfigureOpenElement(d);
    return Open(true);
}

/// A vertical stack: `CLAY_AUTO_ID({ .layout = { .layoutDirection = CLAY_TOP_TO_BOTTOM, .childGap = gap } })`.
pragma(inline, true)
Open column(U)(ref U ui, int gap = 0) => container(Kind.column, CLAY_TOP_TO_BOTTOM, gap);

/// A horizontal stack.
pragma(inline, true)
Open row(U)(ref U ui, int gap = 0) => container(Kind.row, CLAY_LEFT_TO_RIGHT, gap);

// ── leaves: fixed-size elements ────────────────────────────────────────────

pragma(inline, true)
private void configureLeaf(Kind kind, uint w) @trusted nothrow @nogc
{
    Clay_ElementDeclaration d;
    d.layout.sizing.width.size.minMax = Clay_SizingMinMax(w, w);
    d.layout.sizing.width.type = CLAY__SIZING_TYPE_FIXED;
    d.layout.sizing.height.size.minMax = Clay_SizingMinMax(1, 1);
    d.layout.sizing.height.type = CLAY__SIZING_TYPE_FIXED;
    d.backgroundColor = Clay_Color(40, 40, 48, 255);
    d.userData = cast(void*) (kind + 1);
    Clay__ConfigureOpenElement(d);
}

pragma(inline, true)
private void leaf(Kind kind, uint w) @trusted nothrow @nogc
{
    Clay__OpenElement();
    configureLeaf(kind, w);
    Clay__CloseElement();
}

/// One run of text.
pragma(inline, true)
void label(U)(ref U ui, scope const(char)[] text)
{
    ui.keep(text);
    leaf(Kind.label, text.cells);
}

/// A switch.
pragma(inline, true)
void toggle(U)(ref U ui, bool on, scope const(char)[] label, MsgRef onPress)
{
    ui.keep(label);
    leaf(Kind.toggle, label.cells + 4);
}

/// A number field.
pragma(inline, true)
void numberField(U)(ref U ui, int value, scope const(char)[] unit, MsgRef onChange)
{
    ui.keep(unit);
    leaf(Kind.numberField, value.digits + 1 + unit.cells);
}

/// A name and its value, keyed: its id is `CLAY_SID_LOCAL(key)`.
pragma(inline, true)
void keyValue(U)(ref U ui, scope const(char)[] key, scope const(char)[] name,
    scope const(char)[] value, MsgRef onPress)
{
    ui.keep(name);
    ui.keep(value);
    () @trusted {
        Clay__OpenElementWithId(Clay__HashString(clayString(key), Clay_GetOpenElementId()));
        configureLeaf(Kind.keyValue, name.cells + 1 + value.cells);
        Clay__CloseElement();
    }();
}
