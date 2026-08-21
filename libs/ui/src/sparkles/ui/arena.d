/**
Frame-scoped storage with $(B stable addresses) — the bytes a
$(REF DrawOp, sparkles,ui,canvas) points at instead of carrying.

A display-list operation used to own its text: a fixed `char[512]` inline on
the op, which truncated a long run mid-UTF-8 and cost every op — a `fillRect`
that has no text at all — 512 bytes to copy. The alternative it replaced was
worse: a borrowed slice that outlived nothing. This module is the third answer.
The op keeps a slice (or a pointer), the bytes live here, and the lifetime is
stated once: $(B an operation is valid while the arena that built it is alive
and unreset.)

$(B Why chunks, and not one growable buffer.) This is the load-bearing detail.
A single $(REF SmallBuffer, sparkles,base,smallbuffer) would reallocate as it
grew, and every slice already handed to an earlier op in the same frame would
dangle — a bug that shows up as garbled text only once a frame crosses the
initial capacity, which is to say in the field. Chunks are `pureMalloc` blocks
that are never resized and never moved; only the $(I list) of them grows.

$(B Arena memory is not scanned.) $(LREF FrameArena.store) therefore refuses a
type carrying indirections: a pointer written here would be invisible to the
collector. Text is bytes and box chrome is plain data, which is the whole
requirement.

Two arenas implement the same three primitives, so the display-list path is
generic over which one it uses ($(LREF isArena)):

$(UL
    $(LI $(LREF FrameArena) — malloc-backed, `@nogc`, reset once per frame.
    The frame loop's arena.)
    $(LI $(LREF GcArena) — `intern` is `idup`. The convenience path
    ($(REF buildDisplayList, sparkles,ui,display_list) returning a plain
    `DrawOp[]`) keeps working with no lifetime rule at all, because the
    collector is the lifetime rule.)
)
*/
module sparkles.ui.arena;

import std.traits : hasIndirections;

import sparkles.base.smallbuffer : SmallBuffer;

/// Bytes in a fresh chunk. One chunk holds a few hundred typical runs; a
/// bigger request gets a chunk of its own rather than being split.
enum size_t defaultChunkBytes = 4096;

/**
Whether `A` supplies the arena primitives — `intern`, `store` and `reset`.

A concept rather than an interface, for the reason
$(REF isCanvas, sparkles,ui,canvas) is: the display-list walk's `@safe`/`@nogc`
attributes are inferred from the concrete arena, so the `@nogc` frame path and
the GC convenience path are one body of code.
*/
enum bool isArena(A) = __traits(compiles, (ref A a) {
    const(char)[] t = a.intern("x");
    int v = 1;
    const(int)* p = a.store(v);
    a.reset();
});

/**
A bump allocator over never-moving `pureMalloc` chunks.

Move-only: the arena owns its blocks, so a copy would free them twice — and,
worse, would silently hand out two sets of live pointers into one set of bytes.
Reset per frame; the chunks are kept and reused, so a steady-state frame
allocates nothing at all.
*/
struct FrameArena(size_t chunkBytes = defaultChunkBytes)
{
    /*
    One block, as a plain-data record.

    Two deliberate choices. It is a `struct` rather than a bare `ubyte[]`
    because a `SmallBuffer` whose element type is itself a slice cannot tell
    `~= oneElement` from `~= manyElements`. And it holds the block's
    $(I address) rather than a pointer, for two reasons that point the same
    way: a `const(Chunk)` holding a `ubyte*` will not copy into a mutable one
    (the pointee's `const` would be stripped), and an integer keeps `Chunk`
    free of indirections — so the chunk list needs no collector root, which is
    honest, because malloc'd bytes are not the collector's to trace.
    */
    private static struct Chunk
    {
        size_t addr;
        size_t length;

        ubyte[] bytes() const @trusted pure nothrow @nogc
            => (cast(ubyte*) addr)[0 .. length];
    }

    private
    {
        // The blocks, in allocation order. Their addresses are the promise
        // this type makes; only this list may move.
        SmallBuffer!(Chunk, 4) _chunks;
        size_t _at;   // index of the chunk being filled
        size_t _used; // bytes taken from `_chunks[_at]`
    }

    @disable this(ref const FrameArena);

    ~this() @trusted { releaseChunks(); }

@safe pure nothrow @nogc:

    /**
    Copies `s` into the arena and returns the copy.

    The result is stable for the arena's lifetime — until $(LREF reset), which
    is what makes "valid for this frame" a statement about the arena rather
    than about every caller.
    */
    const(char)[] intern(scope const(char)[] s) @trusted
    {
        if (s.length == 0)
            return null;
        auto block = take(s.length, 1);
        block[] = cast(const(ubyte)[]) s[];
        return cast(const(char)[]) block;
    }

    /**
    Copies one plain value into the arena and returns a pointer to it — the
    escape hatch for a payload too bulky to sit on every operation (a box's
    border/shadow chrome, which only a decorated fill has).

    Refuses a type with indirections: arena memory is invisible to the
    collector, so a reference stored here would not keep its target alive.
    */
    const(T)* store(T)(in T value) @trusted
    if (!hasIndirections!T)
    {
        auto block = take(T.sizeof, T.alignof);
        auto p = cast(T*) block.ptr;
        *p = value;
        return p;
    }

    /// Forgets everything, keeping the chunks for the next frame.
    void reset()
    {
        _at = 0;
        _used = 0;
    }

    /// Chunks currently held — a test's window onto the growth policy.
    size_t chunkCount() const => _chunks.length;

    private ubyte[] take(size_t n, size_t alignment) @trusted
    {
        while (_at < _chunks.length)
        {
            auto c = _chunks[_at].bytes;
            const off = alignUp(_used, alignment);
            if (off + n <= c.length)
            {
                _used = off + n;
                return c[off .. off + n];
            }
            // This chunk cannot hold the request; move on. `_used` restarts
            // because a chunk is filled front to back, once.
            ++_at;
            _used = 0;
        }
        auto fresh = allocateChunk(n > chunkBytes ? n : chunkBytes);
        _chunks ~= Chunk(cast(size_t) fresh.ptr, fresh.length);
        _at = _chunks.length - 1;
        _used = n;
        return fresh[0 .. n];
    }

    private void releaseChunks() @trusted
    {
        import core.memory : pureFree;

        foreach (ref c; _chunks[])
            pureFree(cast(void*) c.addr);
        _chunks.clear();
        _at = 0;
        _used = 0;
    }
}

private size_t alignUp(size_t n, size_t alignment) @safe pure nothrow @nogc
    => (n + alignment - 1) & ~(alignment - 1);

private ubyte[] allocateChunk(size_t bytes) @trusted pure nothrow @nogc
{
    import core.memory : pureMalloc;

    auto p = cast(ubyte*) pureMalloc(bytes);
    assert(p !is null, "FrameArena: allocation failed");
    return p[0 .. bytes];
}

/**
The collected heap as an arena: `intern` is `idup`, `store` is `new`, and
`reset` does nothing because nothing needs forgetting.

This is what keeps
$(REF buildDisplayList, sparkles,ui,display_list)'s returned `DrawOp[]`
self-sufficient — its operations outlive the call, and the collector, not a
frame boundary, decides when their text dies. The price is the allocation, so
a frame loop uses $(LREF FrameArena) instead; the code that walks a widget
tree is the same either way.
*/
struct GcArena
{
@safe pure nothrow:

    /// ditto
    const(char)[] intern(scope const(char)[] s) => s.idup;

    /// ditto
    const(T)* store(T)(in T value)
    {
        auto p = new T;
        *p = value;
        return p;
    }

    /// ditto — the collector is the reset.
    void reset() {}
}

static assert(isArena!(FrameArena!()));
static assert(isArena!GcArena);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui.arena.internCopiesAndOutlivesItsSource")
@safe pure nothrow @nogc
unittest
{
    FrameArena!() a;
    const(char)[] kept;
    {
        char[8] scratch = "ephemer!";
        kept = a.intern(scratch[]);
        scratch[] = '?'; // the source is gone as far as the arena is concerned
    }
    assert(kept == "ephemer!");
    assert(a.intern(null) is null, "an empty run needs no bytes");
}

@("ui.arena.earlierSlicesSurviveGrowth")
@safe pure nothrow @nogc
unittest
{
    // The invariant the whole design rests on: a chunk never moves, so a slice
    // handed out before the arena grew still reads correctly afterwards. A
    // single growable buffer would have reallocated here and left `first`
    // pointing into freed memory — the failure this type exists to prevent.
    FrameArena!(64) a;
    const first = a.intern("first");
    foreach (i; 0 .. 40)
        cast(void) a.intern("0123456789012345"); // 16 B each: many chunks
    assert(a.chunkCount > 1, "the test must actually cross a chunk boundary");
    assert(first == "first");
}

@("ui.arena.resetKeepsTheChunksItAlreadyPaidFor")
@safe pure nothrow @nogc
unittest
{
    FrameArena!(64) a;
    foreach (i; 0 .. 20)
        cast(void) a.intern("0123456789012345");
    const grown = a.chunkCount;
    assert(grown > 1);

    a.reset();
    assert(a.chunkCount == grown, "a frame boundary must not re-malloc");
    // …and the space is genuinely reusable, not merely retained.
    foreach (i; 0 .. 20)
        cast(void) a.intern("0123456789012345");
    assert(a.chunkCount == grown);
}

@("ui.arena.storeIsAlignedAndDistinct")
@safe pure nothrow @nogc
unittest
{
    static struct Chrome { int radius; double weight; ubyte flags; }

    FrameArena!() a;
    cast(void) a.intern("x"); // leave the bump cursor deliberately unaligned
    const p = a.store(Chrome(3, 1.5, 7));
    const q = a.store(Chrome(4, 2.5, 9));
    assert(cast(size_t) p % Chrome.alignof == 0);
    assert(p.radius == 3 && q.radius == 4, "two stores are two values");
    assert(p !is q);
}

@("ui.arena.oversizedRequestGetsItsOwnChunk")
@safe pure nothrow @nogc
unittest
{
    // A paragraph longer than a chunk is stored whole — the truncation the
    // old inline `char[512]` performed has no equivalent here.
    FrameArena!(64) a;
    char[200] big = 'x';
    const kept = a.intern(big[]);
    assert(kept.length == 200);
    foreach (c; kept)
        assert(c == 'x');
}

@("ui.arena.gcArenaSatisfiesTheSameConcept")
@safe pure nothrow
unittest
{
    GcArena g;
    const t = g.intern("borrowed");
    assert(t == "borrowed");
    const p = g.store(42);
    assert(*p == 42);
    g.reset(); // a no-op, but the concept requires it
    assert(t == "borrowed");
}
