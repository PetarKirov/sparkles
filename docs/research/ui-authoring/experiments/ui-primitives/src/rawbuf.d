/**
The frame tables' storage: a bare malloc'd array (`RawBuffer`, from the lazy
demo's `benchtext.d`) and a bump text store. `HeapBuffer`'s mutable index
pays an outlined `ensureUniqueStorage` per access (see the lazy demo's
README, "Hot layout fields"); a layout pass indexes the node table far more
than the build does, so both prototypes use the raw array.
*/
module rawbuf;

import core.memory : pureFree, pureRealloc;

/// A growable array that never copies on index; `@disable this(this)`.
struct RawBuffer(T)
{
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

    /// Appends `n` default elements and returns them.
    T[] extend(size_t n) return @trusted pure nothrow @nogc
    {
        grow(len + n);
        foreach (i; len .. len + n)
            ptr[i] = T.init;
        len += n;
        return ptr[len - n .. len];
    }

    void clear(bool releaseStorage = true) @safe pure nothrow @nogc { len = 0; }

    void reserve(size_t n) @safe pure nothrow @nogc { grow(n); }

    private void grow(size_t n) @trusted pure nothrow @nogc
    {
        if (n <= cap)
            return;
        cap = n > 2 * cap ? (n < 16 ? 16 : n) : 2 * cap;
        ptr = cast(T*) pureRealloc(ptr, cap * T.sizeof);
        assert(ptr !is null, "out of memory");
    }
}

/// The frame's text: bump-allocated, addressed by (start, length).
struct TextStore
{
    private RawBuffer!char bytes;

    @disable this(this);

    static struct Id
    {
        uint start = uint.max;
        uint length;
        bool isSet() const @safe pure nothrow @nogc => start != uint.max;
    }

    Id intern(scope const(char)[] s) @safe pure nothrow @nogc
    {
        if (s.length == 0)
            return Id.init;
        const id = Id(cast(uint) bytes.length, cast(uint) s.length);
        bytes ~= s;
        return id;
    }

    const(char)[] opIndex(in Id id) const return @safe pure nothrow @nogc
        => id.isSet ? bytes[id.start .. id.start + id.length] : null;

    void clear() @safe pure nothrow @nogc { bytes.clear(); }
}
