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

import core.memory : pureMalloc, pureFree;
import core.stdc.string : memcpy;

/**
 * A @nogc container with Small Buffer Optimization and copy-on-write.
 *
 * Elements are stored inline up to `smallBufferSize`, then automatically
 * allocated on the heap via `pureMalloc` when capacity is exceeded.
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
 *   smallBufferSize = Number of elements for inline storage (default: 16)
 */
struct SmallBuffer(T, size_t smallBufferSize = 16)
{
    static assert(smallBufferSize > 0, "smallBufferSize must be greater than 0");

    /**
     * Heap allocation header: a reference count and the element capacity,
     * immediately followed by the element data (aligned to `T.alignof`).
     * Present only while the buffer is `onHeap`; copies of a heap buffer share
     * one `ControlBlock` and clone it copy-on-write on the first mutation.
     */
    private static struct ControlBlock
    {
        size_t refCount;
        size_t capacity;
    }

    // Byte offset of the element data after the control-block header.
    private enum size_t dataOffset =
        (ControlBlock.sizeof + T.alignof - 1) / T.alignof * T.alignof;

    private
    {
        // Discriminant: `_length <= smallBufferSize` <=> data lives inline.
        size_t _length = 0;
        union
        {
            T[smallBufferSize] _inline = void;   // live iff !onHeap
            ControlBlock* _heap;                  // live iff onHeap
        }
    }

pure nothrow @nogc:

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
        // `this` is under construction; write through a mutable view of it.
        auto self = cast(SmallBuffer*) &this;
        self._length = rhs._length;
        if (rhs._length > smallBufferSize)
        {
            self._heap = cast(ControlBlock*) rhs._heap;
            ++self._heap.refCount;
        }
        else
            memcpy(self._inline.ptr, cast(const void*) rhs._inline.ptr,
                rhs._length * T.sizeof);
    }

    /// Build a mutable working copy from a `const` (e.g. frozen) buffer.
    this(ref const SmallBuffer rhs) @trusted
    {
        _length = rhs._length;
        if (rhs._length > smallBufferSize)
        {
            _heap = cast(ControlBlock*) rhs._heap;
            ++_heap.refCount;
        }
        else
            memcpy(_inline.ptr, cast(const void*) rhs._inline.ptr,
                rhs._length * T.sizeof);
    }

    /// Copy assignment: release current storage, then share/copy from `rhs`.
    ref SmallBuffer opAssign(ref SmallBuffer rhs) return @trusted
    {
        if (&this is &rhs)
            return this;
        if (rhs._length > smallBufferSize)
        {
            auto cb = rhs._heap;
            ++cb.refCount;          // acquire rhs before releasing self
            releaseHeap();
            _heap = cb;
            _length = rhs._length;
        }
        else
        {
            releaseHeap();
            _length = rhs._length;
            memcpy(_inline.ptr, rhs._inline.ptr, rhs._length * T.sizeof);
        }
        return this;
    }

    /// Destructor: drop this owner's reference; free heap memory at zero.
    ~this() @trusted
    {
        if (_length > smallBufferSize)
        {
            auto cb = cast(ControlBlock*) _heap;
            if (--cb.refCount == 0)
                pureFree(cb);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // properties
    // ─────────────────────────────────────────────────────────────────────────

    @property @safe
    {
        /// Returns the number of elements in the buffer.
        size_t length() const => _length;

        /// Returns true if the buffer contains no elements.
        bool empty() const => _length == 0;

        /// Returns true if the buffer is using heap-allocated storage.
        bool onHeap() const => _length > smallBufferSize;
    }

    /// Returns the total capacity of the buffer.
    @property size_t capacity() const @trusted =>
        _length > smallBufferSize ? _heap.capacity : smallBufferSize;

    /// Test-facing: shared reference count (0 while inline).
    private @property size_t refCount() const @trusted =>
        _length > smallBufferSize ? _heap.refCount : 0;

    /// Supports `$` operator in slices.
    alias opDollar = length;

    // ─────────────────────────────────────────────────────────────────────────
    // element access — const path shares; mutable path clones if shared
    // ─────────────────────────────────────────────────────────────────────────

    // Current element slice; element constness follows `this`.
    private inout(T)[] view() inout @trusted
    {
        return _length > smallBufferSize
            ? (cast(inout(T)*)(cast(void*) _heap + dataOffset))[0 .. _length]
            : _inline.ptr[0 .. _length];
    }

    /// Returns a read-only slice of all elements (shares storage).
    const(T)[] opSlice() const @safe => view();
    /// Returns a mutable slice of all elements (clones if shared).
    T[] opSlice() @safe { ensureUnique(); return view(); }

    /// Returns a read-only sub-slice from `start` to `end`.
    const(T)[] opSlice(size_t start, size_t end) const @safe
    in (start <= end, "Invalid slice bounds: start > end")
    in (end <= _length, "Slice end out of bounds")
        => view()[start .. end];
    /// Returns a mutable sub-slice from `start` to `end` (clones if shared).
    T[] opSlice(size_t start, size_t end) @safe
    in (start <= end, "Invalid slice bounds: start > end")
    in (end <= _length, "Slice end out of bounds")
    { ensureUnique(); return view()[start .. end]; }

    /// Returns a read-only slice of the underlying data.
    const(T)[] data() const @safe => view();
    /// Returns a mutable slice of the underlying data (clones if shared).
    T[] data() @safe { ensureUnique(); return view(); }

    /// Returns a read-only reference to the element at the given index.
    ref const(T) opIndex(size_t index) const @safe
    in (index < _length, "Index out of bounds")
    { return view()[index]; }
    /// Returns a mutable reference to the element at the given index.
    ref T opIndex(size_t index) @safe
    in (index < _length, "Index out of bounds")
    { ensureUnique(); return view()[index]; }

    /// Returns a read-only reference to the first element.
    ref const(T) front() const @safe
    in (_length > 0, "Cannot access front of empty buffer")
    { return view()[0]; }
    /// Returns a mutable reference to the first element.
    ref T front() @safe
    in (_length > 0, "Cannot access front of empty buffer")
    { ensureUnique(); return view()[0]; }

    /// Returns a read-only reference to the last element.
    ref const(T) back() const @safe
    in (_length > 0, "Cannot access back of empty buffer")
    { return view()[_length - 1]; }
    /// Returns a mutable reference to the last element.
    ref T back() @safe
    in (_length > 0, "Cannot access back of empty buffer")
    { ensureUnique(); return view()[_length - 1]; }

    // ─────────────────────────────────────────────────────────────────────────
    // mutation
    // ─────────────────────────────────────────────────────────────────────────

    /// Output range interface: appends a single element.
    void put()(auto ref T element) { appendOne(element); }

    /// Output range interface: appends elements from a slice.
    void put()(scope const(T)[] elements) { appendSlice(elements); }

    /// Appends a single element using `~=` operator.
    void opOpAssign(string op : "~")(auto ref T element) { appendOne(element); }

    /// Appends elements from a slice using `~=` operator.
    void opOpAssign(string op : "~")(scope const(T)[] elements) { appendSlice(elements); }

    /// Removes the last element.
    void popBack() @trusted
    in (_length > 0, "Cannot pop from empty buffer")
    {
        if (_length == smallBufferSize + 1)
        {
            // Crossing N+1 -> N: data must move back inline to keep the
            // invariant `length <= N  <=>  inline`. Copy survivors out first.
            auto cb = _heap;
            T[smallBufferSize] tmp = void;
            memcpy(tmp.ptr, blockData(cb), smallBufferSize * T.sizeof);
            if (--cb.refCount == 0)
                pureFree(cb);
            memcpy(_inline.ptr, tmp.ptr, smallBufferSize * T.sizeof);
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
        if (newCapacity > _heap.capacity)
            growHeap(newCapacity);
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
            _inline.ptr[_length] = element;
            ++_length;
            return;
        }
        if (_length == smallBufferSize)
        {
            // inline -> heap: copy inline elements out before overwriting the
            // union with the heap pointer (they alias).
            auto cb = allocBlock(grownCapacity(smallBufferSize, smallBufferSize + 1));
            T* dst = blockData(cb);
            memcpy(dst, _inline.ptr, smallBufferSize * T.sizeof);
            dst[smallBufferSize] = element;
            _heap = cb;
            _length = smallBufferSize + 1;
            return;
        }
        if (_length == _heap.capacity)
            growHeap(_length + 1);
        blockData(_heap)[_length] = element;
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
            foreach (i; 0 .. xs.length)
                _inline.ptr[_length + i] = xs[i];
            _length = newLen;
            return;
        }
        if (_length <= smallBufferSize)
        {
            // inline -> heap transition
            auto cb = allocBlock(grownCapacity(smallBufferSize, newLen));
            T* dst = blockData(cb);
            memcpy(dst, _inline.ptr, _length * T.sizeof);
            foreach (i; 0 .. xs.length)
                dst[_length + i] = xs[i];
            _heap = cb;
            _length = newLen;
            return;
        }
        if (newLen > _heap.capacity)
            growHeap(newLen);
        T* dst = blockData(_heap);
        foreach (i; 0 .. xs.length)
            dst[_length + i] = xs[i];
        _length = newLen;
    }

    // Clone the shared heap block so this instance solely owns it (CoW trigger).
    private void ensureUnique() @trusted
    {
        if (_length <= smallBufferSize || _heap.refCount <= 1)
            return;
        auto cb = allocBlock(_heap.capacity);
        memcpy(blockData(cb), blockData(_heap), _length * T.sizeof);
        --_heap.refCount;
        _heap = cb;
    }

    // Grow the uniquely-owned heap block to hold at least `needed` elements.
    private void growHeap(size_t needed) @trusted
    in (_length > smallBufferSize)
    {
        auto cb = allocBlock(grownCapacity(_heap.capacity, needed));
        memcpy(blockData(cb), blockData(_heap), _length * T.sizeof);
        pureFree(_heap);
        _heap = cb;
    }

    // Drop this owner's heap reference (freeing at zero); leaves `_heap` stale.
    private void releaseHeap() @trusted
    {
        if (_length > smallBufferSize)
        {
            if (--_heap.refCount == 0)
                pureFree(_heap);
        }
    }

    private static ControlBlock* allocBlock(size_t capacity) @trusted
    {
        void* p = pureMalloc(dataOffset + capacity * T.sizeof);
        if (p is null)
            assert(false, "SmallBuffer: allocation failed");
        auto cb = cast(ControlBlock*) p;
        cb.refCount = 1;
        cb.capacity = capacity;
        return cb;
    }

    private static T* blockData(ControlBlock* cb) @trusted =>
        cast(T*)(cast(void*) cb + dataOffset);

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
    SmallBuffer!(int, 4) buf;
    assert(buf.length == 0);
    assert(buf.empty);
    assert(buf.capacity == 4);
    assert(!buf.onHeap);
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

@("SmallBuffer.put.singleElement")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf.put(42);
    assert(buf.length == 1);
    assert(buf[0] == 42);
    assert(!buf.onHeap);
}

@("SmallBuffer.put.multipleElements")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf.put(1);
    buf.put(2);
    buf.put(3);
    assert(buf.length == 3);
    assert(buf[] == [1, 2, 3]);
}

@("SmallBuffer.appendOperator")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    assert(buf.length == 2);
    assert(buf[0] == 1);
    assert(buf[1] == 2);
}

@("SmallBuffer.growthToHeap")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) buf;
    buf ~= 1;
    buf ~= 2;
    assert(!buf.onHeap);

    // This should trigger heap allocation
    buf ~= 3;
    assert(buf.onHeap);

    buf ~= 4;
    buf ~= 5;
    assert(buf.length == 5);
    assert(buf[] == [1, 2, 3, 4, 5]);
}

@("SmallBuffer.opSlice.full")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    auto slice = buf[];
    assert(slice.length == 3);
    assert(slice == [1, 2, 3]);
}

@("SmallBuffer.opSlice.partial")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    buf ~= 4;
    assert(buf[1 .. 3] == [2, 3]);
    assert(buf[0 .. $] == [1, 2, 3, 4]);
    assert(buf[$ - 2 .. $] == [3, 4]);
}

@("SmallBuffer.opIndex")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 10;
    buf ~= 20;
    buf ~= 30;
    assert(buf[0] == 10);
    assert(buf[1] == 20);
    assert(buf[2] == 30);

    // Modify through index
    buf[1] = 25;
    assert(buf[1] == 25);
}

@("SmallBuffer.opDollar")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    assert(buf[$ - 1] == 3);
    assert(buf.opDollar() == 3);
}

@("SmallBuffer.clear")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf.clear();
    assert(buf.length == 0);
    assert(buf.empty);
    // Capacity should be preserved
    assert(buf.capacity >= 4);
}

@("SmallBuffer.reserve.inlineNoOp")
@safe pure nothrow @nogc
unittest
{
    // Storage location is tied to length, so reserve cannot pre-grow heap while
    // the buffer is still inline: it is a documented no-op there.
    SmallBuffer!(int, 4) buf;
    buf.reserve(100);
    assert(buf.capacity == 4);
    assert(!buf.onHeap);
    assert(buf.length == 0);
}

@("SmallBuffer.reserve.growsOnHeap")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    foreach (i; 0 .. 5)
        buf ~= cast(int) i;          // now on the heap
    assert(buf.onHeap);
    buf.reserve(100);
    assert(buf.capacity >= 100);
    assert(buf.length == 5);
    assert(buf[] == [0, 1, 2, 3, 4]);
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
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;
    buf.popBack();
    assert(buf.length == 2);
    assert(buf.back == 2);
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

@("SmallBuffer.emptySlice")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    auto slice = buf[];
    assert(slice.length == 0);
    assert(buf[0 .. 0].length == 0);
}

@("SmallBuffer.outputRangeCompatibility")
unittest
{
    import std.range : isOutputRange;
    static assert(isOutputRange!(SmallBuffer!(int, 4), int));
    static assert(isOutputRange!(SmallBuffer!(char, 16), char));
}

@("SmallBuffer.constAccess")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;

    void checkConst(ref const SmallBuffer!(int, 4) cbuf)
    {
        assert(cbuf[0] == 1);
        assert(cbuf.length == 2);
        assert(cbuf[] == [1, 2]);
    }

    checkConst(buf);
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

@("SmallBuffer.dataProperty")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    assert(buf.data.length == 0);

    buf ~= 1;
    buf ~= 2;
    assert(buf.data == [1, 2]);
}

@("SmallBuffer.modifyThroughSlice")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;

    buf[][1] = 20;
    assert(buf[1] == 20);
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

@("SmallBuffer.reserveNoGrowth")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 8) buf;
    buf.reserve(4); // Less than smallBufferSize
    assert(buf.capacity == 8);
    assert(!buf.onHeap);
}

@("SmallBuffer.reserveInlineKeepsData")
@safe pure nothrow @nogc
unittest
{
    // reserve() beyond the inline size while still inline is a no-op and must
    // not disturb existing elements or flip the buffer onto the heap.
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf.reserve(8);
    assert(!buf.onHeap);
    assert(buf.capacity == 4);
    assert(buf[] == [1, 2]);
}

@("SmallBuffer.multiplePopBack")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf ~= 3;

    buf.popBack();
    buf.popBack();
    assert(buf.length == 1);
    assert(buf[0] == 1);
}

@("SmallBuffer.reuseAfterClear")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= 1;
    buf ~= 2;
    buf.clear();

    buf ~= 10;
    buf ~= 20;
    assert(buf.length == 2);
    assert(buf[] == [10, 20]);
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

@("SmallBuffer.invariant.popBackMigratesToInline")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) a;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;        // length 5 > 4 -> heap
    assert(a.onHeap);
    a.popBack();                 // 5 -> 4: must revert to inline
    assert(!a.onHeap);
    assert(a.length == 4);
    assert(a[] == [0, 1, 2, 3]);
}

@("SmallBuffer.invariant.clearRevertsToInline")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    foreach (i; 0 .. 5)
        a ~= cast(int) i;        // heap
    assert(a.onHeap);
    a.clear();
    assert(!a.onHeap);
    assert(a.empty);
    a ~= 7;                      // reuse after clear
    assert(a[] == [7]);
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
