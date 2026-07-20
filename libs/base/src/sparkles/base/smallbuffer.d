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

import std.algorithm.comparison : max;
import std.array : overlap;
import std.range.primitives : ElementType, hasLength, hasSlicing, isInputRange;
import std.experimental.allocator : makeArray, expandArray, dispose;
import std.experimental.allocator.building_blocks.affix_allocator : AffixAllocator;
import std.experimental.allocator.mallocator : Mallocator;

version (unittest) import std.range : iota;

/**
 * A @nogc container with Small Buffer Optimization and copy-on-write.
 *
 * Elements are stored inline up to `N` elements, then automatically
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
 * via `const` (e.g. through `borrow`) never clones. Mutating accessors on a
 * shared mutable copy clone first, so a mutable slice/reference taken from a
 * shared buffer and held across a later mutation may be invalidated (the usual
 * copy-on-write caveat) — read through `const` to share without that risk.
 *
 * Note: storage location is tied to length (data is inline whenever
 * `length <= N`), so `reserve` pre-grows only once on the heap,
 * and `clear`/`popBack` that drop the length back to `<= N` revert
 * to inline storage.
 *
 * Params:
 *   T = Element type
 *   N = Number of elements stored inline. The default fills the slice-sized
 *       union exactly (`max(1, (T[]).sizeof / T.sizeof)`), so the struct stays
 *       three words (`3 * size_t.sizeof`) regardless of `T` — e.g. 16 for
 *       `char`, 4 for `int`, 2 for `long`.
 */
struct SmallBuffer(T, size_t N = max(size_t(1), (T[]).sizeof / T.sizeof))
{
pure nothrow @nogc:

    static assert(N > 0, "N must be greater than 0");

    private
    {
        // Discriminant: `_length <= N` <=> data lives inline.
        size_t _length = 0;
        union
        {
            T[N] _inline = void;   // live iff !onHeap
            T[] _block;                           // capacity slots (ControlBlock prefix precedes them)
        }

        // Allocator blocks carry a `ControlBlock` prefix ahead of the element data.
        struct ControlBlock { size_t refCount; }
        alias Allocator = AffixAllocator!(Mallocator, ControlBlock);

        // The shared control block (logically-mutable metadata; valid iff onHeap).
        ref ControlBlock ctrl() const @system
            => Allocator.instance.prefix(cast(ubyte[]) _block);
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
        bool onHeap() => _length > N;

    @trusted:
        /// Returns the total capacity of the buffer.
        size_t capacity() =>
            onHeap ? _block.length : N;

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
     * copy is first written (see `ensureUniqueStorage`). Reaching a copy through
     * `const` (e.g. via `borrow`) is therefore a zero-clone read-only handle.
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

    /// Build a mutable working copy from a `const` (e.g. borrowed) buffer.
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
    /// Accepts a `const` (e.g. borrowed) source — a heap source is shared (refcount
    /// bumped), an inline source is copied — mirroring the copy constructors.
    ref SmallBuffer opAssign(ref const SmallBuffer rhs) return @trusted
    {
        if (&this is &rhs)
            return this;

        if (rhs.onHeap)
            ++rhs.ctrl().refCount; // acquire rhs before releasing self

        releaseStorage();
        _length = rhs._length;

        if (rhs.onHeap)
            _block = cast(T[]) rhs._block;
        else
            _inline[0 .. rhs._length] = cast(T[]) rhs._inline[0 .. rhs._length];

        return this;
    }

    /// Move assignment from an rvalue: release current storage, then steal
    /// `rhs`'s storage (no refcount change — ownership transfers). `rhs` is
    /// neutralized so its destructor frees nothing.
    ref SmallBuffer opAssign(SmallBuffer rhs) return @trusted
    {
        releaseStorage();
        _length = rhs._length;
        if (rhs.onHeap)
            _block = rhs._block;
        else
            _inline[0 .. rhs._length] = rhs._inline[0 .. rhs._length];
        rhs._length = 0; // rhs no longer owns the (possibly heap) block
        return this;
    }

    /// Destructor: drop this owner's reference; dispose heap memory at zero.
    ~this() @safe { clear(); }

    // ─────────────────────────────────────────────────────────────────────────
    // element access — const path shares; mutable path clones if shared
    //
    // The mutable `opSlice`/`opIndex`/`front`/`back` overloads call
    // `ensureUniqueStorage()`, so on a shared (heap, refcount > 1) buffer they trigger a
    // copy-on-write clone *even when you only read* the returned reference —
    // overload resolution cannot tell read from write. To share a heap buffer
    // without cloning, read through `const`/`borrow` (which select the const
    // overloads).
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
            ensureUniqueStorage();
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
    void put(in T element) @safe
    {
        T tmp = element;
        T[] tail = ensureUniqueStorage(extraLen: 1);
        tail[0] = tmp;
        ++_length;
    }

    /// Output range interface: appends elements from a slice.
    void put(in T[] elements) @trusted
    {
        if (elements.length == 0)
            return;

        const oldLen = _length;
        const newLen = oldLen + elements.length;

        // If the source aliases inline storage, preserve it before the union is
        // overwritten by the inline->heap transition.
        const overlapsInline = () @trusted {
            return !onHeap &&
                elements.overlap(_inline[0 .. oldLen]).length;
        }();
        if (newLen > N && overlapsInline)
        {
            T[N] tmp = void;
            tmp[0 .. elements.length] = elements[];
            T[] tail = ensureUniqueStorage(extraLen: elements.length);
            tail[] = tmp[0 .. elements.length];
            _length = newLen;
            return;
        }

        // If a unique heap block must grow while the source aliases it, keep the
        // old block alive until after the tail copy. `ensureUniqueStorage` then
        // takes the shared-clone path instead of reallocating underneath us.
        T[] retainedBlock;
        if (oldLen > N && newLen > _block.length
            && ctrl().refCount == 1
            && elements.overlap(cast(const(T)[]) _block).length)
        {
            retainedBlock = _block;
            ++ctrl().refCount;
        }

        T[] tail = ensureUniqueStorage(extraLen: elements.length);
        tail[] = elements[];
        _length = newLen;

        if (retainedBlock !is null)
        {
            if (--Allocator.instance.prefix(retainedBlock).refCount == 0)
                dispose(Allocator.instance, retainedBlock);
        }
    }

    /// Appends a single element using `~=` operator.
    void opOpAssign(string op : "~")(in T element) @safe
    {
        put(element);
    }

    /// Appends elements from a slice using `~=` operator.
    void opOpAssign(string op : "~")(in T[] elements) @safe
    {
        put(elements);
    }

    /// Output range interface: appends every element of an input range whose
    /// elements are convertible to `T` (a `T[]` uses the bulk slice overload).
    /// Specializes on range capability: a contiguous (sliceable-to-`T[]`) range
    /// becomes one bulk copy, a known-length range pre-sizes to a single
    /// allocation, and any other input range falls back to amortized appends.
    void put(R)(R elements)
    if (isInputRange!R && is(ElementType!R : T) && !is(immutable R == immutable(T)[]))
    {
        static if (hasSlicing!R && is(typeof(elements[]) : const(T)[]))
            put(elements[]);
        else static if (hasLength!R)
        {
            const n = elements.length;
            if (n == 0)
                return;
            const oldLen = _length;
            const newLen = oldLen + n;

            if (oldLen <= N && newLen > N)
            {
                // inline -> heap transition: to prevent range elements that alias
                // our inline storage from reading corrupted data, we must allocate
                // the new block, fill it with the inline elements and range elements,
                // and only then overwrite the union by assigning _block.
                size_t capacity = newLen;
                import std.math.algebraic : truncPow2;
                if (capacity > 0)
                {
                    const t = truncPow2(capacity);
                    if (t != capacity)
                    {
                        const rounded = t << 1;
                        if (rounded != 0)
                            capacity = rounded;
                    }
                }

                T[] nb = allocateBlock(capacity);
                nb[0 .. oldLen] = _inline[0 .. oldLen];
                size_t i = oldLen;
                foreach (e; elements)
                    nb[i++] = e;

                () @trusted {
                    _block = nb;
                    _length = newLen;
                }();
            }
            else
            {
                T[] tail = ensureUniqueStorage(extraLen: n);
                size_t i;
                foreach (e; elements)
                    tail[i++] = e;
                _length = oldLen + n;
            }
        }
        else
            foreach (e; elements)
                put(e);
    }

    /// Appends every element of an input range using the `~=` operator.
    void opOpAssign(string op : "~", R)(R elements)
    if (isInputRange!R && is(ElementType!R : T) && !is(immutable R == immutable(T)[]))
    {
        put(elements);
    }

    /// Removes the last element.
    void popBack() @trusted
    in (_length > 0, "Cannot pop from empty buffer")
    {
        if (_length == N + 1)
        {
            // Crossing N+1 -> N: data must move back inline to keep the
            // invariant `length <= N  <=>  inline`. Copy survivors out first.
            T[] b = _block;
            T[N] tmp = void;
            tmp[] = b[0 .. N];
            releaseStorage();
            _inline[0 .. N] = tmp[];
            _length = N;
            return;
        }
        --_length;
    }

    /// Removes all elements; releases heap storage and reverts to inline.
    void clear() @safe
    {
        releaseStorage();
        _length = 0;
    }

    /**
     * Ensures the buffer has at least `newCapacity` slots.
     *
     * $(B Limitation:) storage location is tied to length here — data is inline
     * whenever `length <= N` — so `reserve` can only pre-grow a buffer that is
     * $(I already) on the heap; on an inline (including empty) buffer it is a
     * no-op, and the next inline→heap transition reallocates from scratch. This
     * is a consequence of deriving `onHeap` from `length`; decoupling the storage
     * discriminant (so an empty buffer can hold a reserved heap block) is a
     * planned policy knob.
     */
    void reserve(size_t newCapacity) @safe
    {
        if (!onHeap)
            return;
        if (newCapacity <= capacity)
            return; // already large enough — don't clone a shared block needlessly
        ensureUniqueStorage(minCapacity: newCapacity);
    }

    /**
     * Returns a `const`, storage-sharing handle to this buffer — the
     * producer-builds-then-many-readers handoff. Reading through the result (or
     * its copies) never clones, since nothing can mutate through `const`.
     *
     * Like Rust's `Borrow`, this is the read side of the copy-on-write type — but
     * unlike a Rust borrow it is an $(I owner): it bumps the reference count and
     * keeps the heap block alive independently of the source (closer to
     * `Rc::clone` than a lifetime-bound `&`). `const x = buf;` is equivalent;
     * `borrow` simply names the handoff and works in expression position.
     *
     * See_Also: $(LREF SmallBuffer.toOwned) for the inverse (an independent,
     * uniquely-owned mutable copy).
     */
    const(SmallBuffer) borrow() const @safe => this;

    /**
     * Returns an independent, uniquely-owned mutable copy, eagerly detached from
     * any shared block (Rust's `ToOwned`/`Cow::into_owned`). The result shares
     * with no one — its reference count is 1 — so later mutations never pay a
     * copy-on-write clone, and it is unaffected by writes to the source.
     *
     * Plain copy construction (`auto b = a;`) is the lazy counterpart: it shares
     * a heap block and clones only on the first write. `toOwned` forces that
     * clone up front.
     */
    SmallBuffer toOwned() const @safe
    {
        SmallBuffer copy = this; // shares (heap) or copies (inline)
        copy.ensureUniqueStorage();     // force a private block if shared
        return copy;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // private helpers
    // ─────────────────────────────────────────────────────────────────────────

    // Allocate a heap block for `blockCapacity` elements (refCount 1).
    private static T[] allocateBlock(size_t blockCapacity) @trusted
    {
        T[] b = makeArray!T(Allocator.instance, blockCapacity);
        assert(b !is null, "SmallBuffer: allocation failed");
        Allocator.instance.prefix(b).refCount = 1;
        return b;
    }

    // Ensure this buffer has unique mutable storage with room for `extraLen`
    // additional elements (and at least `minCapacity` total slots). `_length`
    // is deliberately unchanged; callers fill the returned tail and then commit.
    private T[] ensureUniqueStorage(size_t extraLen = 0, size_t minCapacity = 0) @safe
    {
        import std.math.algebraic : truncPow2;

        const oldLen = _length;
        const newLen = oldLen + extraLen;

        if (newLen <= N)
            return (() @trusted => _inline[oldLen .. newLen])();

        const needed = max(newLen, minCapacity);

        size_t capacity = needed;
        if (capacity > 0)
        {
            const t = truncPow2(capacity);
            if (t != capacity)
            {
                const rounded = t << 1;
                if (rounded != 0)
                    capacity = rounded;
            }
        }

        const rc = this.refCount;
        if (rc == 1)
        {
            if (needed > this.capacity)
            {
                const ok = (() @trusted =>
                    Allocator.instance.expandArray(
                        _block, capacity - _block.length
                    )
                )();
                if (!ok)
                    assert(false, "SmallBuffer: reallocation failed");
            }
            return (() @trusted => _block[oldLen .. newLen])();
        }

        T[] oldBlock = this.view;
        T[] newBlock = allocateBlock(max(this.capacity, capacity));
        newBlock[0 .. oldLen] = oldBlock[];
        () @trusted {
            if (rc > 1) --ctrl().refCount;
            _block = newBlock;
        }();
        return newBlock[oldLen .. newLen];
    }

    // Drop this owner's heap reference. If refCount hits 0, destroy and free the
    // block. Nulls `_block` so no dangling/aliased pointer survives in the union
    // (callers reset `_length` and/or reassign `_block` afterwards).
    private void releaseStorage() @trusted
    {
        if (!onHeap)
            return;
        if (--ctrl().refCount == 0)
            dispose(Allocator.instance, _block);
        _block = null;
    }
}

///
@("SmallBuffer.tour")
@safe pure nothrow @nogc
unittest
{
    // A `SmallBuffer` starts empty and inline — no heap allocation yet.
    SmallBuffer!(int, 4) buf;
    assert(buf.empty && !buf.onHeap && buf.capacity == 4);

    // Append single elements or slices; it is also an output range (`put`).
    buf ~= 1;
    buf ~= [2, 3];
    buf.put(4);
    assert(buf[] == [1, 2, 3, 4] && !buf.onHeap);

    // Overflowing the inline capacity transparently moves to the heap.
    buf ~= 5;
    assert(buf.onHeap && buf.capacity >= 5);

    // Index, sub-slice, front/back, and `$`.
    assert(buf[0] == 1 && buf[$ - 1] == 5);
    assert(buf[1 .. 3] == [2, 3]);
    assert(buf.front == 1 && buf.back == 5);

    // popBack/clear shrink it; dropping back to <= N reverts to inline storage.
    buf.popBack();
    assert(buf[] == [1, 2, 3, 4] && !buf.onHeap);
    buf.clear();
    assert(buf.empty);

    // ── Copy-on-write ────────────────────────────────────────────────────────
    SmallBuffer!(int, 2) a;
    a ~= iota(5);            // [0, 1, 2, 3, 4], now on the heap
    assert(a.refCount == 1);         // sole owner

    // `borrow()` hands out a const, storage-sharing reader: no element copy,
    // just a bumped reference count. Reading through `const` never clones.
    const reader = a.borrow;
    assert(a.refCount == 2);         // `a` and `reader` share one block
    assert(reader[] == [0, 1, 2, 3, 4] && a.refCount == 2);

    // A *mutable* copy shares too — the clone is deferred to the first write.
    auto b = a;
    assert(a.refCount == 3);         // a, reader, b
    b ~= 5;                          // copy-on-write: b detaches here
    assert(b[] == [0, 1, 2, 3, 4, 5]);          // b is independent
    assert(reader[] == [0, 1, 2, 3, 4]);        // original intact (const read)
    assert(a.refCount == 2);         // a and reader still share it

    // Nuance: the *mutable* accessors clone even when you only read — overload
    // resolution cannot tell a read from a write. A mutable read of the shared
    // `a` detaches it from `reader`; reach through `const`/`borrow` to avoid it.
    auto s = a[];                    // mutable opSlice → clones, just from a read
    assert(s == [0, 1, 2, 3, 4] && a.refCount == 1);   // `a` now owns its block

    // `toOwned()` eagerly detaches: an independent, uniquely-owned copy sharing
    // with nobody, so its later writes never pay a copy-on-write clone.
    auto owned = reader.toOwned();
    assert(owned.refCount == 1);     // detached up front
    owned ~= 9;                      // already unique → no clone
    assert(owned[] == [0, 1, 2, 3, 4, 9]);
    assert(reader[] == [0, 1, 2, 3, 4]);        // reader untouched
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
void checkToString(T, size_t outputBufferSize = 1024, size_t errorBufferSize = 1024)(
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
void checkWriter(alias render, size_t outputBufferSize = 1024,
    size_t errorBufferSize = 1024)(
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
    // By default, N fills the slice-sized union exactly, so the struct stays
    // three words wide for any T (16 chars / 4 ints / 2 longs inline).
    {
        static assert(SmallBuffer!char.sizeof == 3 * size_t.sizeof);
        static assert(SmallBuffer!int.sizeof == 3 * size_t.sizeof);
        static assert(SmallBuffer!long.sizeof == 3 * size_t.sizeof);
        SmallBuffer!int buf;
        assert(buf.length == 0);
        assert(buf.empty);
        assert(buf.capacity == (ubyte[]).sizeof / int.sizeof); // 4 on x86_64
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

@("SmallBuffer.clear.noDanglingReuse")
@safe pure nothrow @nogc
unittest
{
    // After clearing a heap buffer, `_block` must not survive as a dangling
    // pointer: re-growing back onto the heap must allocate cleanly.
    SmallBuffer!(int, 2) buf;
    buf ~= iota(6);          // heap
    assert(buf.onHeap);

    buf.clear();
    assert(buf.length == 0 && !buf.onHeap);

    buf ~= iota(10, 16);             // re-grow onto a fresh heap block
    assert(buf.onHeap);
    assert(buf[] == [10, 11, 12, 13, 14, 15]);
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
        buf.reserve(4); // Less than N
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
        buf ~= iota(5);          // heap
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
    buf ~= iota(5); // length 5 > 4 -> heap
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
    buf ~= iota(100);

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

@("SmallBuffer.appendInputRange")
@safe pure nothrow @nogc
unittest
{
    import std.algorithm.iteration : filter, map;

    // Any input range of convertible elements appends, via `put` or `~=`.
    SmallBuffer!(int, 2) buf;
    buf.put(iota(3));                 // [0, 1, 2], spills to heap
    buf ~= iota(3, 6);               // [0, 1, 2, 3, 4, 5]
    assert(buf[] == [0, 1, 2, 3, 4, 5]);

    // Lazy pipelines work too — no intermediate allocation.
    SmallBuffer!(int, 8) evens;
    evens ~= iota(10).filter!(x => x % 2 == 0);
    assert(evens[] == [0, 2, 4, 6, 8]);

    // Element type need only be convertible to T.
    SmallBuffer!(long, 2) longs;
    longs ~= iota(4).map!(x => cast(long) x);
    assert(longs[] == [0L, 1, 2, 3]);
}

@("SmallBuffer.appendInputRange.specialization")
@safe pure nothrow @nogc
unittest
{
    // hasLength path: a large known-length range goes inline -> heap in a single
    // fill (no per-element reallocation).
    SmallBuffer!(int, 4) big;
    big ~= iota(50);
    assert(big.length == 50);
    foreach (i; 0 .. 50)
        assert(big[i] == i);

    // Contiguous path: a range that is hasSlicing and slices to a T[] is bulk
    // copied through the slice put overload rather than appended element by element.
    static struct Contig
    {
        int[] d;
        @property bool empty() const => d.length == 0;
        @property int front() const => d[0];
        void popFront() { d = d[1 .. $]; }
        Contig save() => Contig(d);          // forward range (hasSlicing needs this)
        @property size_t length() const => d.length;
        alias opDollar = length;
        const(int)[] opSlice() const => d;                  // r[] → bulk-copy slice
        Contig opSlice(size_t a, size_t b) => Contig(d[a .. b]); // r[a..b] → subrange
    }
    static assert(hasSlicing!Contig && is(typeof(Contig.init[]) : const(int)[]));

    SmallBuffer!(int, 2) c;
    int[4] backing = [7, 8, 9, 10];
    c ~= Contig(backing[]);
    assert(c[] == [7, 8, 9, 10]);
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

@("SmallBuffer.capacity.powerOfTwoGrowth")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) buf;
    buf ~= [0, 1];
    assert(buf.capacity == 2);

    buf ~= 2;
    assert(buf.onHeap && buf.capacity == 4);

    buf ~= 3;
    assert(buf.capacity == 4);

    buf ~= 4;
    assert(buf.capacity == 8);

    SmallBuffer!(int, 2) bulk;
    bulk ~= iota(9);
    assert(bulk.capacity == 16);
}

@("SmallBuffer.selfAppend.inlineToHeap")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    buf ~= [0, 1, 2];

    buf ~= buf[];
    assert(buf.onHeap);
    assert(buf[] == [0, 1, 2, 0, 1, 2]);
}

@("SmallBuffer.selfAppend.heapGrow")
@safe pure nothrow @nogc
unittest
{
    // Appending a buffer's own slice to itself must survive the reallocation
    // that the append triggers (the source aliases the block being grown).
    SmallBuffer!(int, 2) buf;
    buf ~= iota(5);          // heap: [0, 1, 2, 3, 4]
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
    a ~= iota(5);        // heap: [0, 1, 2, 3, 4]
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
    a ~= iota(5);        // heap
    const ro = a.borrow();       // const read-only handle, shares storage
    const r2 = ro;               // another reader, shares too
    assert(a.refCount == 3);
    assert(ro[] == [0, 1, 2, 3, 4]);
    assert(r2[] == [0, 1, 2, 3, 4]);

    a ~= 99;                     // producer mutates -> CoW
    assert(ro[] == [0, 1, 2, 3, 4]);         // borrowed readers keep old value
    assert(a[] == [0, 1, 2, 3, 4, 99]);
    assert(ro.refCount == 2);
}

@("SmallBuffer.cow.copyAssignment")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a, b;
    a ~= iota(5);        // heap
    b ~= 100;                    // b inline

    b = a;                       // copy-assign: b releases its own, shares a's
    assert(a.refCount == 2);
    assert((cast(const) b)[] == [0, 1, 2, 3, 4]);   // const read: no clone

    b ~= 5;                      // CoW
    assert(a.refCount == 1);
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(b[] == [0, 1, 2, 3, 4, 5]);
}

@("SmallBuffer.cow.constOpAssign")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    a ~= iota(5);        // heap

    // Assigning a const/borrowed source must compile and share storage.
    const borrowed = a.borrow();
    SmallBuffer!(int, 2) work;
    work ~= 100;                 // work inline, owns nothing on the heap
    work = borrowed;               // const copy-assign: shares a's block
    assert(a.refCount == 3);     // a, borrowed, work all share
    assert((cast(const) work)[] == [0, 1, 2, 3, 4]);   // const read: no clone

    work ~= 5;                   // CoW: clone away from the shared block
    assert(a.refCount == 2);     // a, borrowed still share
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(work[] == [0, 1, 2, 3, 4, 5]);

    // Rvalue/move assignment must also compile.
    SmallBuffer!(int, 2) mv;
    mv = makeHeapBuffer();
    assert(mv[] == [0, 1, 2, 3, 4]);
}

// Helper: returns a heap SmallBuffer by value (rvalue source for opAssign).
version (unittest)
private SmallBuffer!(int, 2) makeHeapBuffer() @safe pure nothrow @nogc
{
    SmallBuffer!(int, 2) r;
    r ~= iota(5);
    return r;
}

@("SmallBuffer.cow.refCountLifetime")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    a ~= iota(5);
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
    a ~= iota(5);
    const borrowed = a.borrow();
    SmallBuffer!(int, 2) work = borrowed;      // const -> mutable copy ctor
    assert((cast(const) work)[] == [0, 1, 2, 3, 4]);

    work ~= 7;                   // CoW; borrowed untouched
    assert(borrowed[] == [0, 1, 2, 3, 4]);
    assert(work[] == [0, 1, 2, 3, 4, 7]);
}

@("SmallBuffer.cow.toOwned")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    a ~= iota(5);            // heap
    const reader = a.borrow();       // a + reader share, refCount 2

    // toOwned detaches an independent copy without disturbing the source.
    auto owned = a.toOwned();
    assert(owned.refCount == 1);     // uniquely owns its block
    assert(a.refCount == 2);         // a and reader still share, untouched
    assert(owned[] == [0, 1, 2, 3, 4]);

    owned ~= 9;                      // already unique → no CoW clone
    assert(owned[] == [0, 1, 2, 3, 4, 9]);
    assert(reader[] == [0, 1, 2, 3, 4]);   // source unaffected

    // An inline buffer is already independent; toOwned just copies it.
    SmallBuffer!(int, 4) sm;
    sm ~= [1, 2];
    auto c = sm.toOwned();
    assert(!c.onHeap && c[] == [1, 2]);
}

@("SmallBuffer.cow.sharedGrowAppend")
@safe pure nothrow @nogc
unittest
{
    // Growing a *shared* buffer folds the CoW clone and the grow into one
    // allocation; the shared original must stay intact and detach cleanly.

    // Single-element put on a shared, full heap buffer.
    SmallBuffer!(int, 2) a;
    a ~= [0, 1, 2, 3];               // heap, capacity 4 (full)
    const reader = a.borrow;         // share, refCount 2
    assert(a.refCount == 2 && a.capacity == 4);

    a ~= 4;                          // shared + full → clone straight into grown block
    assert(reader[] == [0, 1, 2, 3]);            // original block intact
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(a.refCount == 1 && reader.refCount == 1);
    assert(a.capacity >= 5);

    // Slice put on a shared, growing heap buffer.
    SmallBuffer!(int, 2) b;
    b ~= [0, 1, 2, 3];               // heap
    const rb = b.borrow;
    assert(b.refCount == 2);
    b ~= [10, 11, 12];               // shared + grow
    assert(rb[] == [0, 1, 2, 3]);                // original intact
    assert(b[] == [0, 1, 2, 3, 10, 11, 12]);
    assert(b.refCount == 1);
}

@("SmallBuffer.selfAppend.sharedAlias")
@safe pure nothrow @nogc
unittest
{
    // Self-append through a const (shared) slice: the source aliases the old
    // block, which the clone keeps alive (via the borrow) while copying.
    SmallBuffer!(int, 2) a;
    a ~= [0, 1, 2, 3];               // heap
    const reader = a.borrow;         // share, refCount 2
    a ~= a.borrow[];                 // xs aliases the shared block
    assert(reader[] == [0, 1, 2, 3]);            // original intact
    assert(a[] == [0, 1, 2, 3, 0, 1, 2, 3]);
}

@("SmallBuffer.reserve.sharedGrowsOnce")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    a ~= [0, 1, 2, 3, 4];            // heap
    const reader = a.borrow;         // share
    assert(a.refCount == 2);

    a.reserve(100);                  // shared + grow → one allocation
    assert(a.refCount == 1 && reader.refCount == 1);
    assert(a.capacity >= 100);
    assert(a[] == [0, 1, 2, 3, 4]);
    assert(reader[] == [0, 1, 2, 3, 4]);         // sharer keeps the old block
}

@("SmallBuffer.reserve.sharedDetachPreservesCapacity")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 2) a;
    a ~= [0, 1, 2, 3, 4];
    a.reserve(100);
    const reservedCapacity = a.capacity;

    auto b = a;
    b[0] = 99;                         // detach without growing

    assert(a.capacity == reservedCapacity);
    assert(b.capacity == reservedCapacity);
    assert(a[0] == 0);
    assert(b[0] == 99);
}

@("SmallBuffer.cow.attributesPreserved")
@safe pure nothrow @nogc
unittest
{
    // The whole copy/borrow/clone cycle must hold @safe pure nothrow @nogc.
    SmallBuffer!(char, 4) a;
    a ~= "hello world";          // heap
    auto b = a;                  // share
    const ro = a.borrow();       // borrow
    b ~= '!';                    // CoW clone
    assert((cast(const) a)[] == "hello world");
    assert(ro[] == "hello world");
    assert(b[] == "hello world!");
}

@("SmallBuffer.selfAppend.singleAliasTransition")
@safe pure nothrow @nogc
unittest
{
    struct LargePoint { long x, y, z, w; }
    SmallBuffer!(LargePoint, 2) buf;
    buf ~= LargePoint(1, 2, 3, 4);
    buf ~= LargePoint(5, 6, 7, 8);

    // This should append buf[0] to buf, triggering inline->heap transition
    // while checking that the element passed by ref is not corrupted.
    buf ~= buf[0];
    assert(buf.onHeap);
    assert(buf.length == 3);
    assert(buf[0] == LargePoint(1, 2, 3, 4));
    assert(buf[1] == LargePoint(5, 6, 7, 8));
    assert(buf[2] == LargePoint(1, 2, 3, 4));
}

@("SmallBuffer.selfAppend.rangeAliasTransition")
@safe pure nothrow @nogc
unittest
{
    import std.algorithm : map;
    SmallBuffer!(int, 4) buf;
    buf ~= [1, 2, 3];

    // Trigger inline->heap transition with map range aliasing buf
    buf ~= buf[].map!(x => x * 2);
    assert(buf.onHeap);
    assert(buf.length == 6);
    assert(buf[] == [1, 2, 3, 2, 4, 6]);
}
