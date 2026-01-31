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
module sparkles.core_cli.smallbuffer;

import core.memory : pureMalloc, pureFree;

/**
 * A @nogc container with Small Buffer Optimization.
 *
 * Elements are stored inline up to `smallBufferSize`, then automatically
 * allocated on the heap via `pureMalloc` when capacity is exceeded.
 *
 * Params:
 *   T = Element type
 *   smallBufferSize = Number of elements for inline storage (default: 16)
 */
struct SmallBuffer(T, size_t smallBufferSize = 16)
{
    static assert(smallBufferSize > 0, "smallBufferSize must be greater than 0");

    private
    {
        T[smallBufferSize] _smallBuffer = void;
        T* _data = null;
        size_t _length = 0;
        size_t _capacity = smallBufferSize;
    }

    /// Disable copy to prevent double-free.
    @disable this(this);

pure nothrow @nogc:

    // ─────────────────────────────────────────────────────────────────────────
    // const @safe
    // ─────────────────────────────────────────────────────────────────────────

@safe:

    @property
    {
        /// Returns the number of elements in the buffer.
        size_t length() const => _length;

        /// Returns the total capacity of the buffer.
        size_t capacity() const => _capacity;

        /// Returns true if the buffer contains no elements.
        bool empty() const => _length == 0;

        /// Returns true if the buffer is using heap-allocated storage.
        bool onHeap() const => _capacity > smallBufferSize;
    }

    /// Supports `$` operator in slices.
    alias opDollar = length;

    // ─────────────────────────────────────────────────────────────────────────
    // inout @safe
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns a reference to the element at the given index.
    ref inout(T) opIndex(size_t index) inout
    in (index < _length, "Index out of bounds")
    {
        return data[index];
    }

    /// Returns a slice of all elements.
    inout(T)[] opSlice() inout => data[0 .. _length];

    /// Returns a slice of elements from `start` to `end`.
    inout(T)[] opSlice(size_t start, size_t end) inout
    in (start <= end, "Invalid slice bounds: start > end")
    in (end <= _length, "Slice end out of bounds")
    {
        return data[start .. end];
    }

    /// Returns a reference to the first element.
    ref inout(T) front() inout
    in (_length > 0, "Cannot access front of empty buffer")
    {
        return data[0];
    }

    /// Returns a reference to the last element.
    ref inout(T) back() inout
    in (_length > 0, "Cannot access back of empty buffer")
    {
        return data[_length - 1];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mutable @safe
    // ─────────────────────────────────────────────────────────────────────────

    /// Removes the last element.
    void popBack()
    in (_length > 0, "Cannot pop from empty buffer")
    {
        _length--;
    }

    /// Removes all elements but preserves capacity.
    void clear() { _length = 0; }

    // ─────────────────────────────────────────────────────────────────────────
    // inout @trusted
    // ─────────────────────────────────────────────────────────────────────────

@trusted:

    /// Returns a slice of the underlying data.
    inout(T)[] data() inout
    {
        if (_data is null)
            return _smallBuffer[0 .. 0];
        return _data[0 .. _length];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mutable @trusted
    // ─────────────────────────────────────────────────────────────────────────

    /// Output range interface: appends a single element.
    void put()(auto ref T element)
    {
        ensureCapacity(_length + 1);
        _data[_length] = element;
        _length++;
    }

    /// Output range interface: appends elements from a slice.
    void put()(scope const(T)[] elements)
    {
        if (elements.length == 0)
            return;

        ensureCapacity(_length + elements.length);
        _data[_length .. _length + elements.length] = elements[];
        _length += elements.length;
    }

    /// Appends a single element using `~=` operator.
    void opOpAssign(string op : "~")(auto ref T element)
    {
        put(element);
    }

    /// Appends elements from a slice using `~=` operator.
    void opOpAssign(string op : "~")(scope const(T)[] elements)
    {
        put(elements);
    }

    /// Ensures the buffer has at least `newCapacity` slots.
    void reserve(size_t newCapacity)
    {
        if (newCapacity > _capacity)
            ensureCapacity(newCapacity);
    }

    /// Destructor: frees heap memory if allocated.
    ~this()
    {
        if (onHeap && _data !is null)
            pureFree(_data);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // private @trusted
    // ─────────────────────────────────────────────────────────────────────────

private:

    void ensureCapacity(size_t needed)
    {
        // Initialize _data on first use
        if (_data is null)
            _data = _smallBuffer.ptr;

        if (needed <= _capacity)
            return;

        // Calculate new capacity (double strategy)
        size_t newCap = _capacity;
        while (newCap < needed)
            newCap *= 2;

        reallocate(newCap);
    }

    void reallocate(size_t newCapacity)
    {
        import core.stdc.string : memcpy;

        // Allocate new heap memory
        size_t size = newCapacity * T.sizeof;
        void* newData = pureMalloc(size);

        if (newData is null)
            assert(false, "SmallBuffer: allocation failed");

        // Copy existing data
        if (_length > 0)
            memcpy(newData, _data, _length * T.sizeof);

        // Free old heap memory (if any)
        if (onHeap)
            pureFree(_data);

        _data = cast(T*) newData;
        _capacity = newCapacity;
    }
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

@("SmallBuffer.reserve")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf.reserve(100);
    assert(buf.capacity >= 100);
    assert(buf.length == 0);
    assert(buf.onHeap);
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

@("SmallBuffer.reserveExact")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf.reserve(8);
    assert(buf.capacity >= 8);
    assert(buf.onHeap);
    assert(buf.length == 0);
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
