/**
 * A @nogc container with Small Buffer Optimization (SBO).
 *
 * Provides an append-only buffer that stores small amounts of data inline
 * (avoiding heap allocation) and automatically switches to heap storage
 * when capacity is exceeded.
 *
 * Primary use case: appending elements in a temporary scope where GC
 * allocation is not desired.
 */
module sparkles.base.smallbuffer;

import std.experimental.allocator : makeArray, expandArray, dispose;
import std.experimental.allocator.building_blocks.affix_allocator : AffixAllocator;
import std.experimental.allocator.mallocator : Mallocator;

/**
 * A @nogc container with Small Buffer Optimization and copy-on-write.
 *
 * Elements are stored inline up to `smallBufferSize`, then automatically
 * allocated on the heap (via `AffixAllocator!(Mallocator, ControlBlock)`, which
 * keeps the reference count in an allocation prefix; the element capacity is the
 * heap slice length) when capacity is exceeded. Heap blocks are managed with the
 * `std.experimental.allocator` `makeArray`/`expandArray`/`dispose` helpers.
 *
 * The buffer is copyable. Copying an inline buffer duplicates its elements
 * (independent copies). Copying a heap buffer shares the allocation and bumps a
 * reference count; the shared block is cloned copy-on-write the first time a
 * mutable copy is written. This suits the common pattern of one producer
 * building a buffer mutably, then handing out many `const` reader copies — read
 * via `const` (e.g. through `freeze`) never clones. Mutating accessors on a
 * shared mutable copy clone first, so a mutable slice/reference taken from a
 * shared buffer and held across a later mutation may be invalidated (the usual
 * copy-on-write caveat) — read through `const` to share without that risk.
 *
 * Note: storage location is tied to length (data is inline whenever
 * `length <= smallBufferSize`), so `reserve` pre-grows only once on the heap,
 * and `clear`/`popBack` that drop the length back to `<= smallBufferSize` revert
 * to inline storage.
 *
 * Params:
 *   T = Element type
 *   smallBufferSize = Number of elements for inline storage (default: the
 *                     native slice size in bytes)
 */
struct SmallBuffer(T, size_t smallBufferSize = (ubyte[]).sizeof)
{
pure nothrow @nogc:

    static assert(smallBufferSize > 0, "smallBufferSize must be greater than 0");

    private
    {
        // Discriminant: `_length <= smallBufferSize` <=> data lives inline.
        size_t _length = 0;
        union
        {
            T[smallBufferSize] _inline = void;   // live iff !onHeap
            T[] _block;                           // capacity slots (ControlBlock prefix precedes them)
        }

        // Allocator blocks carry a `ControlBlock` prefix ahead of the element data.
        struct ControlBlock { size_t refCount; }
        alias Allocator = AffixAllocator!(Mallocator, ControlBlock);

        // The shared control block (logically-mutable metadata; valid iff onHeap).
        ref ControlBlock ctrl() const => Allocator.instance.prefix(cast(ubyte[]) _block);
    }

    @property const
    {
    @safe:
        /// Returns the number of elements in the buffer.
        size_t length() => _length;

        /// Supports `$` operator in slices.
        alias opDollar = length;

        /// Returns true if the buffer contains no elements.
        bool empty() => _length == 0;

        /// Returns true if the buffer is using heap-allocated storage.
        bool onHeap() => _length > smallBufferSize;

    @trusted:
        /// Returns the total capacity of the buffer.
        size_t capacity() =>
            onHeap ? _block.length : smallBufferSize;

        /// Test-facing: shared reference count (0 while inline).
        private size_t refCount() =>
            onHeap ? ctrl().refCount : 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // copy / assign / destroy
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Copy constructor (copy-on-write). An inline buffer copies its elements,
     * yielding an independent buffer. A heap buffer instead shares storage and
     * bumps the reference count; the shared block is cloned only when a mutable
     * copy is first written (see `ensureUnique`). Reaching a copy through
     * `const` (e.g. via `freeze`) is therefore a zero-clone read-only handle.
     */
    this(ref inout SmallBuffer rhs) inout @trusted
    {
        this._length = rhs._length;
        if (rhs.onHeap)
        {
            this._block = rhs._block;
            ++this.ctrl().refCount;
        }
        else
            this._inline[0 .. rhs._length] = rhs._inline[0 .. rhs._length];
    }

    /// Build a mutable working copy from a `const` (e.g. frozen) buffer.
    this(ref const SmallBuffer rhs) @trusted
    {
        _length = rhs._length;
        if (rhs.onHeap)
        {
            _block = cast(T[]) rhs._block;
            ++ctrl().refCount;
        }
        else
            _inline[0 .. rhs._length] = cast(T[]) rhs._inline[0 .. rhs._length];
    }

    /// Copy assignment: release current storage, then share/copy from `rhs`.
    ref SmallBuffer opAssign(ref SmallBuffer rhs) return @trusted
    {
        if (&this is &rhs)
            return this;

        if (rhs.onHeap)
            ++rhs.ctrl().refCount; // acquire rhs before releasing self

        releaseHeap();
        _length = rhs._length;

        if (rhs.onHeap)
            _block = rhs._block;
        else
            _inline[0 .. rhs._length] = rhs._inline[0 .. rhs._length];

        return this;
    }

    /// Destructor: drop this owner's reference; dispose heap memory at zero.
    ~this() @safe { clear(); }

    // ─────────────────────────────────────────────────────────────────────────
    // element access — const path shares; mutable path clones if shared
    // ─────────────────────────────────────────────────────────────────────────

    // Current element slice; element constness follows `this`.
    private inout(T)[] view() inout @trusted
        => onHeap ? _block[0 .. _length] : _inline[0 .. _length];

    @safe
    {
        /// Returns a read-only slice of all elements (shares storage).
        const(T)[] opSlice() const => view();

        /// Returns a mutable slice of all elements (clones if shared).
        T[] opSlice()
        {
            ensureUnique();
            return view();
        }

        /// Returns a read-only sub-slice from `start` to `end`.
        const(T)[] opSlice(size_t start, size_t end) const
        in (start <= end, "Invalid slice bounds: start > end")
        in (end <= _length, "Slice end out of bounds")
            => this[][start .. end];

        /// Returns a mutable sub-slice from `start` to `end` (clones if shared).
        T[] opSlice(size_t start, size_t end)
        in (start <= end, "Invalid slice bounds: start > end")
        in (end <= _length, "Slice end out of bounds")
            => this[][start .. end];

        /// Returns a read-only reference to the element at the given index.
        ref const(T) opIndex(size_t index) const
        in (index < _length, "Index out of bounds") => this[][index];

        /// Returns a mutable reference to the element at the given index.
        ref T opIndex(size_t index)
        in (index < _length, "Index out of bounds") => this[][index];

        /// Returns a read-only reference to the first element.
        ref const(T) front() const => this[0];

        /// Returns a mutable reference to the first element.
        ref T front() => this[0];

        /// Returns a read-only reference to the last element.
        ref const(T) back() const => this[$ - 1];

        /// Returns a mutable reference to the last element.
        ref T back() => this[$ - 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mutation
    // ─────────────────────────────────────────────────────────────────────────

    /// Output range interface: appends a single element.
    void put(in T element)
    {
        appendOne(element);
    }

    /// Output range interface: appends elements from a slice.
    void put(in T[] elements)
    {
        appendSlice(elements);
    }

    /// Appends a single element using `~=` operator.
    void opOpAssign(string op : "~")(in T element)
    {
        appendOne(element);
    }

    /// Appends elements from a slice using `~=` operator.
    void opOpAssign(string op : "~")(in T[] elements)
    {
        appendSlice(elements);
    }

    /// Removes the last element.
    void popBack() @trusted
    in (_length > 0, "Cannot pop from empty buffer")
    {
        if (_length == smallBufferSize + 1)
        {
            // Crossing N+1 -> N: data must move back inline to keep the
            // invariant `length <= N  <=>  inline`. Copy survivors out first.
            T[] b = _block;
            T[smallBufferSize] tmp = void;
            tmp[] = b[0 .. smallBufferSize];
            releaseHeap();
            _inline[0 .. smallBufferSize] = tmp[];
            _length = smallBufferSize;
            return;
        }
        --_length;
    }

    /// Removes all elements; releases heap storage and reverts to inline.
    void clear() @trusted
    {
        releaseHeap();
        _length = 0;
    }

    /**
     * Ensures the buffer has at least `newCapacity` slots.
     *
     * Storage location is tied to length here (inline whenever
     * `length <= smallBufferSize`), so `reserve` can pre-grow only once the
     * buffer is already on the heap; while inline it is a no-op.
     */
    void reserve(size_t newCapacity) @trusted
    {
        if (_length <= smallBufferSize)
            return;
        ensureUnique();
        if (newCapacity > _block.length)
            growBlock(newCapacity);
    }

    /**
     * Returns a `const` copy that shares this buffer's storage — the
     * producer-builds-then-many-readers-consume handoff. Copies of the result
     * share freely and never clone (they cannot mutate through `const`).
     */
    const(SmallBuffer) freeze() const @safe => this;

    // ─────────────────────────────────────────────────────────────────────────
    // private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private void appendOne(T element) @trusted
    {
        ensureUnique();
        if (_length < smallBufferSize)
        {
            _inline[_length++] = element;
            return;
        }
        if (_length == smallBufferSize)
        {
            // inline -> heap: copy inline elements out before overwriting the
            // union with the heap slice (they alias).
            T[] nb = newBlock(grownCapacity(smallBufferSize, smallBufferSize + 1));
            nb[0 .. smallBufferSize] = _inline[0 .. smallBufferSize];
            nb[smallBufferSize] = element;
            _block = nb;
            _length = smallBufferSize + 1;
            return;
        }
        if (_length == _block.length)
            growBlock(_length + 1);
        _block[_length] = element;
        ++_length;
    }

    private void appendSlice(scope const(T)[] xs) @trusted
    {
        if (xs.length == 0)
            return;
        ensureUnique();
        const newLen = _length + xs.length;
        if (newLen <= smallBufferSize)
        {
            _inline[_length .. newLen] = xs[];
            _length = newLen;
            return;
        }
        if (_length <= smallBufferSize)
        {
            // inline -> heap transition
            T[] nb = newBlock(grownCapacity(smallBufferSize, newLen));
            nb[0 .. _length] = _inline[0 .. _length];
            nb[_length .. newLen] = xs[];
            _block = nb;
            _length = newLen;
            return;
        }
        if (newLen > _block.length)
        {
            if (overlaps(xs, _block))
            {
                // Self-aliasing append (e.g. `buf ~= buf[]`): `growBlock` may
                // realloc-move `_block`, leaving `xs` dangling. Copy into a
                // fresh block (reading the old block via `xs` first), then
                // release the old block.
                T[] nb = newBlock(grownCapacity(_block.length, newLen));
                nb[0 .. _length] = _block[0 .. _length];
                nb[_length .. newLen] = xs[];
                releaseHeap();
                _block = nb;
                _length = newLen;
                return;
            }
            growBlock(newLen);
        }
        _block[_length .. newLen] = xs[];
        _length = newLen;
    }

    // True if slices `a` and `b` share any underlying element storage.
    private static bool overlaps(scope const(T)[] a, scope const(T)[] b) @trusted
        => a.ptr < b.ptr + b.length && b.ptr < a.ptr + a.length;

    // Clone the shared heap block so this instance solely owns it (CoW trigger).
    private void ensureUnique() @trusted
    {
        if (_length <= smallBufferSize || ctrl().refCount <= 1)
            return;
        T[] nb = newBlock(_block.length); // same capacity
        nb[0 .. _length] = _block[0 .. _length];
        --ctrl().refCount;
        _block = nb;
    }

    // Grow the uniquely-owned heap block to hold at least `needed` elements.
    private void growBlock(size_t needed) @trusted
    in (onHeap)
    {
        const ok = expandArray(Allocator.instance, _block,
            grownCapacity(_block.length, needed) - _block.length);
        if (!ok)
            assert(false, "SmallBuffer: reallocation failed");
    }

    // Drop this owner's heap reference. If refCount is 0, destroy and free the
    // block. Leaves `_block` stale.
    private void releaseHeap() @trusted
    {
        if (onHeap && --ctrl().refCount == 0)
            dispose(Allocator.instance, _block);
    }

    // Allocate a heap block for `capacity` elements (refCount 1).
    private static T[] newBlock(size_t capacity) @trusted
    {
        T[] b = makeArray!T(Allocator.instance, capacity);
        assert(b !is null, "SmallBuffer: allocation failed");
        Allocator.instance.prefix(b).refCount = 1;
        return b;
    }

    private static size_t grownCapacity(size_t currentCap, size_t needed) @safe
    {
        size_t c = currentCap;
        while (c < needed)
            c *= 2;
        return c;
    }
}

/**
Checks an output-range `toString` implementation against expected text.

This helper is intended for unit tests of types that expose
`void toString(Writer)(ref Writer w)`. It renders into a $(LREF SmallBuffer)
so passing tests can run without GC allocation.

Params:
    value    = Value whose `toString` overload is tested.
    expected = Expected rendered text.
    file     = Source file for assertion reporting.
    line     = Source line for assertion reporting.

Throws: `AssertError` if the rendered text does not match `expected`.
*/
void checkToString(T, size_t outputBufferSize = 16 * 1024, size_t errorBufferSize = 4 * 1024)(
    auto ref T value,
    const(char)[] expected,
    string file = __FILE__,
    size_t line = __LINE__,
)
{
    SmallBuffer!(char, outputBufferSize) buf;
    value.toString(buf);
    assertRendered!errorBufferSize("toString mismatch", buf[], expected, file, line);
}

/// Like $(LREF checkToString), but for a free writer expression rather than
/// a `toString` method. `render` is a callable taking
/// `ref SmallBuffer!(char, outputBufferSize)`; its output is compared to
/// `expected` with the same recycled-`AssertError` diff on mismatch (so the
/// caller stays `@safe pure nothrow @nogc`):
/// ---
/// checkWriter!((ref b) => writeIntegerPadded(b, 7, 3))("007");
/// ---
void checkWriter(alias render, size_t outputBufferSize = 16 * 1024,
    size_t errorBufferSize = 4 * 1024)(
    const(char)[] expected,
    string file = __FILE__,
    size_t line = __LINE__,
)
{
    SmallBuffer!(char, outputBufferSize) buf;
    render(buf);
    assertRendered!errorBufferSize("rendered output mismatch", buf[], expected, file, line);
}

/// Shared by $(LREF checkToString) and $(LREF checkWriter): compares the
/// rendered bytes and, on mismatch, throws a recycled `AssertError`
/// carrying an `<header>:\nExpected:\n…\nActual:\n…` diff.
private void assertRendered(size_t errorBufferSize)(
    const(char)[] header,
    const(char)[] actual,
    const(char)[] expected,
    string file,
    size_t line,
)
{
    import core.exception : AssertError;
    import sparkles.base.lifetime : recycledErrorInstance;

    if (actual == expected)
        return;

    SmallBuffer!(char, errorBufferSize) errBuf;
    errBuf.put(header);
    errBuf.put(":\nExpected:\n");
    errBuf.put(expected);
    errBuf.put("\nActual:\n");
    errBuf.put(actual);

    // @trusted only here: recycledErrorInstance is @system (it parks the
    // Error object in a static buffer).
    () @trusted {
        throw recycledErrorInstance!AssertError(errBuf[], file, line);
    }();
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

@("SmallBuffer.basic.creation")
@safe pure nothrow @nogc
unittest
{
    // By default, the inline element count matches the native slice size in
    // bytes, e.g. 16 elements on x86_64.
    {
        static assert(SmallBuffer!char.sizeof == 3 * size_t.sizeof);
        SmallBuffer!int buf;
        assert(buf.length == 0);
        assert(buf.empty);
        assert(buf.capacity == (ubyte[]).sizeof);
        assert(!buf.onHeap);
    }

    {
        SmallBuffer!(int, 4) buf;
        assert(buf.length == 0);
        assert(buf.empty);
        assert(buf.capacity == 4);
        assert(!buf.onHeap);
    }
}

@("checkToString.outputRangeToString")
@safe pure nothrow @nogc
unittest
{
    struct Example
    {
        int value;

        void toString(Writer)(ref Writer w) const
        {
            w.put("Example(");
            if (value == 42)
                w.put("42");
            else
                w.put("?");
            w.put(")");
        }
    }

    checkToString(Example(42), "Example(42)");
}

@("checkToString.mismatchMessage")
@system
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown, collectException;

    struct Example
    {
        void toString(Writer)(ref Writer w) const
        {
            w.put("actual");
        }
    }

    assertThrown!AssertError(checkToString(Example(), "expected"));

    auto error = collectException!AssertError(
        checkToString(Example(), "expected")
    );
    assert(error !is null);
    assert(error.msg == "toString mismatch:\nExpected:\nexpected\nActual:\nactual");
}

@("checkWriter.rendersLambda")
@safe pure nothrow @nogc
unittest
{
    checkWriter!((ref b) => b.put("hi"))("hi");
}

@("SmallBuffer.put.append")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;

    // Single element put
    buf.put(42);
    assert(buf.length == 1);
    assert(buf[0] == 42);
    assert(!buf.onHeap);

    // Multiple element put
    buf.put([1, 2]);
    assert(buf.length == 3);
    assert(buf[] == [42, 1, 2]);
    assert(!buf.onHeap);

    // Append operator
    buf ~= 100;
    assert(buf.length == 4);
    assert(buf.capacity == 4);
    assert(buf[] == [42, 1, 2, 100]);
    assert(!buf.onHeap);

    // This will trigger heap allocation
    buf ~= 200;
    assert(buf.length == 5);
    assert(buf[] == [42, 1, 2, 100, 200]);
    assert(buf.onHeap);

    buf ~= [300, 400];
    assert(buf.length == 7);
    assert(buf[] == [42, 1, 2, 100, 200, 300, 400]);
    assert(buf.onHeap);
}

@("SmallBuffer.indexingAndSlicing")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;

    // Empty slicing
    assert(buf[].length == 0);
    assert(buf[0 .. 0].length == 0);

    buf ~= [1, 2, 3, 4];

    // Full & partial slices
    assert(buf[] == [1, 2, 3, 4]);
    assert(buf[1 .. 3] == [2, 3]);
    assert(buf[0 .. $] == [1, 2, 3, 4]);
    assert(buf[$ - 2 .. $] == [3, 4]);

    // Index access & Dollar
    assert(buf[0] == 1);
    assert(buf[1] == 2);
    assert(buf[2] == 3);
    assert(buf[$ - 1] == 4);
    assert(buf.opDollar() == 4);

    // Modify through index
    buf[1] = 20;
    assert(buf[1] == 20);

    // Modify through slice
    buf[][2] = 30;
    assert(buf[2] == 30);
    assert(buf[] == [1, 20, 30, 4]);

    // Const access
    void checkConst(ref const SmallBuffer!(int, 4) cbuf)
    {
        assert(cbuf[0] == 1);
        assert(cbuf.length == 4);
        assert(cbuf[] == [1, 20, 30, 4]);
    }
    checkConst(buf);
}

@("SmallBuffer.clear")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;

    // Clear inline
    buf ~= [1, 2];
    assert(buf.length == 2);
    buf.clear();
    assert(buf.length == 0);
    assert(buf.empty);
    assert(!buf.onHeap);
    assert(buf.capacity == 4);

    // Reuse after clear inline
    buf ~= [10, 20];
    assert(buf.length == 2);
    assert(buf[] == [10, 20]);

    // Transition to heap
    buf ~= [30, 40, 50];
    assert(buf.onHeap);

    // Clear reverts to inline (invariant check)
    buf.clear();
    assert(buf.length == 0);
    assert(buf.empty);
    assert(!buf.onHeap);

    // Reuse after clear heap
    buf ~= 7;
    assert(buf[] == [7]);
    assert(!buf.onHeap);
}

@("SmallBuffer.reserve")
@safe pure nothrow @nogc
unittest
{
    // Reserve is a no-op when inline (storage location tied to length)
    {
        SmallBuffer!(int, 4) buf;
        buf.reserve(100);
        assert(buf.capacity == 4);
        assert(!buf.onHeap);
        assert(buf.length == 0);
    }
    {
        SmallBuffer!(int, 8) buf;
        buf.reserve(4); // Less than smallBufferSize
        assert(buf.capacity == 8);
        assert(!buf.onHeap);
    }
    {
        SmallBuffer!(int, 4) buf;
        buf ~= [1, 2];
        buf.reserve(8);
        assert(!buf.onHeap);
        assert(buf.capacity == 4);
        assert(buf[] == [1, 2]);
    }

    // Reserve grows when already on heap
    {
        SmallBuffer!(int, 4) buf;
        foreach (i; 0 .. 5)
            buf ~= cast(int) i;          // heap
        assert(buf.onHeap);
        buf.reserve(100);
        assert(buf.capacity >= 100);
        assert(buf.length == 5);
        assert(buf[] == [0, 1, 2, 3, 4]);
    }
}

@("SmallBuffer.frontBack")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    assert(buf.front == 1);
    assert(buf.back == 3);
}

@("SmallBuffer.popBack")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= [1, 2, 3];

    // Single popBack
    buf.popBack();
    assert(buf.length == 2);
    assert(buf.back == 2);

    // Multiple popBack
    buf.popBack();
    assert(buf.length == 1);
    assert(buf[0] == 1);

    // Revert to inline from heap
    buf.clear();
    foreach (i; 0 .. 5)
        buf ~= cast(int) i; // length 5 > 4 -> heap
    assert(buf.onHeap);

    buf.popBack(); // 5 -> 4: must revert to inline
    assert(!buf.onHeap);
    assert(buf.length == 4);
    assert(buf[] == [0, 1, 2, 3]);
}

@("SmallBuffer.withStructType")
@safe pure nothrow @nogc
unittest
{
    struct Point { int x, y; }
    SmallBuffer!(Point, 2) buf;
    buf ~= Point(1, 2);
    buf ~= Point(3, 4);
    assert(buf[0].x == 1);
    assert(buf[1].y == 4);
}

@("SmallBuffer.exactCapacityBoundary")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    // Fill exactly to capacity
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    buf ~= 4;
    assert(buf.length == 4);
    assert(!buf.onHeap);

    // One more triggers growth
    buf ~= 5;
    assert(buf.length == 5);
    assert(buf.onHeap);
    assert(buf.capacity >= 8); // Doubled
}



@("SmallBuffer.outputRangeCompatibility")
unittest
{
    import std.range : isOutputRange;
    static assert(isOutputRange!(SmallBuffer!(int, 4), int));
    static assert(isOutputRange!(SmallBuffer!(char, 16), char));
}



@("SmallBuffer.largeGrowth")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) buf;
    // Add many elements to trigger multiple reallocations
    foreach (i; 0 .. 100)
        buf ~= cast(int)i;

    assert(buf.length == 100);
    foreach (i; 0 .. 100)
        assert(buf[i] == i);
}

@("SmallBuffer.putSlice")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 8) buf;
    int[4] arr = [1, 2, 3, 4];
    buf.put(arr[]);
    assert(buf.length == 4);
    assert(buf[] == arr[]);
}

@("SmallBuffer.appendSlice")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 8) buf;
    buf ~= 0;
    int[3] arr = [1, 2, 3];
    buf ~= arr[];
    assert(buf.length == 4);
    assert(buf[] == [0, 1, 2, 3]);
}



@("SmallBuffer.charBuffer")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(char, 8) buf;
    buf ~= 'H';
    buf ~= 'i';
    assert(buf[] == "Hi");

    buf.put("!!");
    assert(buf[] == "Hi!!");
}

@("SmallBuffer.emptyPutSlice")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    int[] empty;
    buf.put(empty);
    assert(buf.length == 1);
    assert(buf[0] == 1);
}

@("SmallBuffer.selfAppend.heapGrow")
@safe pure nothrow @nogc
unittest
{
    // Appending a buffer's own slice to itself must survive the reallocation
    // that the append triggers (the source aliases the block being grown).
    SmallBuffer!(int, 2) buf;
    foreach (i; 0 .. 5)
        buf ~= cast(int) i;          // heap: [0, 1, 2, 3, 4]
    assert(buf.onHeap);

    buf ~= buf[];                    // self-append across a realloc-grow
    assert(buf.length == 10);
    assert(buf[] == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4]);
}









// ─────────────────────────────────────────────────────────────────────────────
// Copy-on-write
// ─────────────────────────────────────────────────────────────────────────────

@("SmallBuffer.cow.inlineCopyIndependent")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) a;
    a ~= 1;
    a ~= 2;
    auto b = a;                  // inline copy: independent
    assert(b[] == [1, 2]);
    a[0] = 99;                   // mutate original
    assert(b[0] == 1);           // copy unchanged
    assert(!a.onHeap && !b.onHeap);
}

@("SmallBuffer.cow.heapShareThenClone")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;        // heap: [0, 1, 2, 3, 4]
    assert(a.onHeap);

    auto b = a;                  // share the heap block
    assert(a.refCount == 2 && b.refCount == 2);

    b ~= 5;                      // mutate b -> copy-on-write clone
    assert(a.refCount == 1 && b.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);          // original intact
    assert(b[] == [0, 1, 2, 3, 4, 5]);
}

@("SmallBuffer.cow.constReadersShare")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;        // heap
    const ro = a.freeze();       // const read-only handle, shares storage
    const r2 = ro;               // another reader, shares too
    assert(a.refCount == 3);
    assert(ro[] == [0, 1, 2, 3, 4]);
    assert(r2[] == [0, 1, 2, 3, 4]);

    a ~= 99;                     // producer mutates -> CoW
    assert(ro[] == [0, 1, 2, 3, 4]);         // frozen readers keep old value
    assert(a[] == [0, 1, 2, 3, 4, 99]);
    assert(ro.refCount == 2);
}

@("SmallBuffer.cow.copyAssignment")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a, b;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;        // heap
    b ~= 100;                    // b inline

    b = a;                       // copy-assign: b releases its own, shares a's
    assert(a.refCount == 2);
    assert((cast(const) b)[] == [0, 1, 2, 3, 4]);   // const read: no clone

    b ~= 5;                      // CoW
    assert(a.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(b[] == [0, 1, 2, 3, 4, 5]);
}

@("SmallBuffer.cow.refCountLifetime")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;
    assert(a.refCount == 1);
    {
        auto b = a;
        assert(a.refCount == 2);
        {
            auto c = a;
            assert(a.refCount == 3);
        }                        // c released
        assert(a.refCount == 2);
    }                            // b released
    assert(a.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);          // survivor intact
}

@("SmallBuffer.cow.constToMutableWorkingCopy")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;
    const frozen = a.freeze();
    SmallBuffer!(int, 2) work = frozen;      // const -> mutable copy ctor
    assert((cast(const) work)[] == [0, 1, 2, 3, 4]);

    work ~= 7;                   // CoW; frozen untouched
    assert(frozen[] == [0, 1, 2, 3, 4]);
    assert(work[] == [0, 1, 2, 3, 4, 7]);
}





@("SmallBuffer.cow.attributesPreserved")
@safe pure nothrow @nogc
unittest
{
    // The whole copy/freeze/clone cycle must hold @safe pure nothrow @nogc.
    SmallBuffer!(char, 4) a;
    a ~= "hello world";          // heap
    auto b = a;                  // share
    const ro = a.freeze();       // freeze
    b ~= '!';                    // CoW clone
    assert((cast(const) a)[] == "hello world");
    assert(ro[] == "hello world");
    assert(b[] == "hello world!");
}
