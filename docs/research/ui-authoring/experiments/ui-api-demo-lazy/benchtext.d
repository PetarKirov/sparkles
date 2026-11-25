/**
The benchmark's frame text store, used by all three builders under
`version (Bench)`: a bump arena with `TextPool`'s `intern`/`withText`/`release`
surface. `TextPool` cannot be sized for a 100 000-row frame on a test worker's
512 KiB stack: its `compact` keeps a `uint[slots]` on the stack (2 MiB at 2^19
slots), and the frame is reserved on every `intern` that may compact.
*/
module benchtext;

import sparkles.base.buffer : HeapBuffer, Storage;

/**
The frame tables' buffer in the benchmark. By default the `sparkles:base`
`HeapBuffer!(T, Storage.unique)` the prototypes use; under `version (RawBuf)` a
bare malloc'd array. The mutable `Buffer.opIndex`/`opSlice` call
`ensureUniqueStorage` (not inlined, computing `roundedCapacity`) on every
access even for `Storage.unique`, and the top-down builders index their node
table far more than the inside-out one does; `RawBuf` takes that cost out of
all three, leaving the builders' own work.
*/
version (RawBuf)
    alias FrameBuf(T) = RawBuffer!T;
else
    alias FrameBuf(T) = HeapBuffer!(T, Storage.unique);

/// ditto
struct RawBuffer(T)
{
    import core.memory : pureFree, pureRealloc;

    private T* ptr;
    private size_t len, cap;

    @disable this(this);
    ~this() @trusted pure nothrow @nogc { pureFree(ptr); }

    size_t length() const @safe pure nothrow @nogc => len;

    /// Shrinks only (the children stack pops a run).
    void length(size_t n) @safe pure nothrow @nogc
    {
        assert(n <= len, "RawBuffer only shrinks");
        len = n;
    }
    alias opDollar = length;

    ref inout(T) opIndex(size_t i) inout return @trusted pure nothrow @nogc
    {
        assert(i < len, "index out of bounds");
        return ptr[i];
    }

    inout(T)[] opSlice() inout return @trusted pure nothrow @nogc => ptr[0 .. len];

    inout(T)[] opSlice(size_t a, size_t b) inout return @trusted pure nothrow @nogc
    {
        assert(a <= b && b <= len, "slice out of bounds");
        return ptr[a .. b];
    }

    void opOpAssign(string op : "~")(T e) @trusted
    {
        grow(len + 1);
        ptr[len++] = e;
    }

    void opOpAssign(string op : "~")(scope const(T)[] es) @trusted
    {
        grow(len + es.length);
        foreach (i, ref e; es)
            ptr[len + i] = cast(T) e;
        len += es.length;
    }

    void clear(bool releaseStorage = true) @safe pure nothrow @nogc { len = 0; }

    private void grow(size_t n) @trusted pure nothrow @nogc
    {
        if (n <= cap)
            return;
        cap = n > 2 * cap ? (n < 16 ? 16 : n) : 2 * cap;
        ptr = cast(T*) pureRealloc(ptr, cap * T.sizeof);
        assert(ptr !is null, "out of memory");
    }
}

struct BumpTextPool
{
    private FrameBuf!char bytes;

    @disable this(this);

    static struct Id
    {
        uint start = uint.max;
        uint length;
    }

    static struct Result { Id value; }

    Result intern(scope const(char)[] s) @safe pure nothrow @nogc
    {
        const id = Id(cast(uint) bytes.length, cast(uint) s.length);
        bytes ~= s;
        return Result(id);
    }

    bool withText(Fn)(in Id id, scope Fn fn)
    {
        if (id.start == uint.max)
            return false;
        fn(bytes[id.start .. id.start + id.length]);
        return true;
    }

    bool release(in Id) @safe pure nothrow @nogc => true;

    void clearAll() @safe pure nothrow @nogc { bytes.clear(releaseStorage: false); }
}
