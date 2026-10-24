/**
Storage behind change sets and histories: an immutable reference-counted
array of plain data, a growable array used while building one, and a
copy-on-write vector for elements with copy constructors.

Counts are `shared` and atomic (TXB-OWN2), and memory comes from outside the
collector (TXB-OWN3). Only raw pointer arithmetic and the C allocator are
`@trusted`; copying and destroying elements infer their attributes from the
element type.
*/
module sparkles.text_buffer.storage;

import core.atomic : atomicLoad, atomicOp;

package:

private struct Header
{
    shared size_t refs = 1;
    size_t length;
    size_t capacity;
}

/// A header followed by room for `capacity` elements of `elementSize` bytes.
private Header* allocateBlock(size_t elementSize, size_t capacity) @trusted pure nothrow @nogc
{
    import core.exception : onOutOfMemoryError;
    import core.memory : pureMalloc;

    auto header = cast(Header*) pureMalloc(Header.sizeof + elementSize * capacity);
    if (header is null)
        onOutOfMemoryError();
    *header = Header(1, 0, capacity);
    return header;
}

/// Grow a block that nothing else refers to; its elements move bitwise, as
/// D moves are bitwise.
private Header* growBlock(Header* header, size_t elementSize, size_t capacity)
    @trusted pure nothrow @nogc
{
    import core.exception : onOutOfMemoryError;
    import core.memory : pureRealloc;

    auto grown = cast(Header*) pureRealloc(header, Header.sizeof + elementSize * capacity);
    if (grown is null)
        onOutOfMemoryError();
    grown.capacity = capacity;
    return grown;
}

private void freeBlock(Header* header) @trusted pure nothrow @nogc
{
    import core.memory : pureFree;

    pureFree(header);
}

/// The elements of a block, as `T`. The caller vouches that `T` is what the
/// block holds and that the slice dies before the block.
private T[] elementsOf(T)(const(Header)* header, size_t length)
{
    if (header is null)
        return null;
    return () @trusted { return (cast(T*)(cast(Header*) header + 1))[0 .. length]; }();
}

/// Take a counted reference to the block `header` names.
private Header* share(scope const(Header)* header) @trusted pure nothrow @nogc
{
    // The count, not the argument's lifetime, keeps the block alive; the
    // pointer leaves `scope` through an integer.
    auto h = cast(Header*) cast(size_t) header;
    if (h !is null)
        atomicOp!"+="(h.refs, 1);
    return h;
}

/// Drop a reference; `true` when it was the last.
private bool drop(Header* header) @safe pure nothrow @nogc
    => header !is null && atomicOp!"-="(header.refs, 1) == 0;

/// An immutable shared array of plain data. Copying adds a reference.
struct RcArray(T)
if (__traits(isPOD, T))
{
    private Header* header;

    this(ref scope const RcArray other) { header = share(other.header); }

    /// ditto
    this(ref scope const RcArray other) const { header = share(other.header); }

    ~this() scope
    {
        if (drop(header))
            freeBlock(header);
    }

    /// The elements, borrowed.
    const(T)[] opIndex() const return scope
        => elementsOf!(const T)(header, header ? header.length : 0);

    size_t length() const scope => header ? header.length : 0;

    bool opEquals(in RcArray other) const scope => header is other.header || this[] == other[];
}

/// A growable array of plain data that freezes into an `RcArray`.
struct Growable(T)
if (__traits(isPOD, T))
{
    private Header* header;

    @disable this(this);

    ~this() scope { freeBlock(header); }

    void put(T value) scope
    {
        if (header is null)
            header = allocateBlock(T.sizeof, 4);
        else if (header.length == header.capacity)
            header = growBlock(header, T.sizeof, 2 * header.capacity);
        elementsOf!T(header, header.length + 1)[$ - 1] = value;
        ++header.length;
    }

    T[] opIndex() return scope => elementsOf!T(header, length);

    size_t length() const scope => header ? header.length : 0;

    /// Hand the elements to an immutable array, leaving this one empty.
    RcArray!T freeze()
    {
        RcArray!T result;
        result.header = header;
        header = null;
        return result;
    }
}

/**
A copy-on-write vector. Copies share storage until one of them is changed;
changing a shared vector first copies its elements, running their copy
constructors.
*/
struct CowVector(T)
{
    import core.lifetime : emplace, moveEmplace;

    private Header* header;

    this(ref scope const CowVector other) { header = share(other.header); }

    ~this() scope { release(header); }

    private static void release(Header* block)
    {
        if (!drop(block))
            return;
        foreach (ref element; elementsOf!T(block, block.length))
            destroy!false(element);
        freeBlock(block);
    }

    size_t length() const scope => header ? header.length : 0;

    /// The elements, borrowed read-only.
    const(T)[] opIndex() const return scope
        => elementsOf!(const T)(header, length);

    /// The elements, writable; copies them first if they are shared.
    T[] mutable() return scope
    {
        unshare(length);
        return elementsOf!T(header, length);
    }

    /// Append `value`, moving it in.
    void put(T value)
    {
        unshare(length + 1);
        // A bitwise move into raw memory: no copy constructor or destructor
        // runs, so trusting it hides nothing about `T`.
        auto slot = &elementsOf!T(header, header.length + 1)[$ - 1];
        () @trusted { moveEmplace(value, *slot); }();
        ++header.length;
    }

    /// Make the storage unshared with room for `capacity` elements.
    private void unshare(size_t capacity)
    {
        const unique = header !is null && atomicLoad(header.refs) == 1;
        if (unique && header.capacity >= capacity)
            return;
        // Grow a unique block by doubling; size a copy from its length, so
        // repeated copy-on-write does not compound the capacity.
        size_t wanted = !header ? 4 : unique ? 2 * header.capacity : 2 * header.length;
        if (wanted < capacity)
            wanted = capacity;
        if (unique)
        {
            header = growBlock(header, T.sizeof, wanted);
            return;
        }
        auto copy = allocateBlock(T.sizeof, wanted);
        if (header !is null)
        {
            // Copy from a mutable view so a generated copy constructor
            // applies; copying never writes to its source.
            auto from = elementsOf!T(header, header.length);
            auto to = elementsOf!T(copy, header.length);
            foreach (i; 0 .. from.length)
                emplace(&to[i], from[i]);
            copy.length = header.length;
            release(header);
        }
        header = copy;
    }
}
