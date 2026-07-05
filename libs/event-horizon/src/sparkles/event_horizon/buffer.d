/**
Owned-buffer currency for the completion window (SPEC §6).

`Buf` is a move-only handle over $(I pinned, stable) memory — a pool slab
slot, a registered-buffer slot, a provided-ring lease, or vouched-for foreign
memory. The kernel holds the pointer from submission to the terminal
completion, so the bytes must not move or be freed in that window; that is
why `SmallBuffer` (whose small-buffer optimization relocates the payload on
struct moves) is banned as the tier-A transfer currency.
*/
module sparkles.event_horizon.buffer;

import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/// Where a `Buf`'s memory came from — drives both lowering (registered slots
/// select the FIXED opcodes) and recycling on release.
enum BufOrigin : ubyte
{
    none,       /// empty handle
    pool,       /// a `BufferPool` slab slot
    registered, /// a registered-buffer slot (lowered to `READ_FIXED`/`WRITE_FIXED`)
    ringLease,  /// leased from a provided buffer ring; release replenishes the ring
    foreign,    /// caller-owned memory + deleter (`Buf.fromForeign`)
}

/// Provided-buffer-ring group id (`buf_group`); used from M8 on.
struct BufGroupId
{
    ushort value;
}

/// Deleter for foreign memory: called once when the handle is released.
alias BufDeleter = void function(ubyte* ptr, size_t capacity) nothrow @nogc;

/**
Move-only owned buffer handle — the thing that "moves in and comes back"
(SPEC §6.2). Exactly one owner at any time: the caller, or (while an op is
in flight) the loop's op slot.
*/
struct Buf
{
    @disable this(this); // move-only: the kernel may hold the pointer

    /// dip1000: views cannot outlive the handle.
    inout(ubyte)[] opSlice() inout return scope @trusted pure nothrow @nogc
        => _ptr[0 .. _len];

    /// ditto
    inout(ubyte)[] opSlice(size_t lo, size_t hi) inout return scope @trusted pure nothrow @nogc
    in (lo <= hi && hi <= _len, "slice out of bounds")
        => _ptr[lo .. hi];

    /// Full-capacity view for receive paths: the kernel fills it, and the
    /// caller sets `length` from the completion's byte count.
    inout(ubyte)[] space() inout return scope @trusted pure nothrow @nogc
        => _ptr[0 .. _cap];

    /// Valid bytes (set from the completion `res` on receive paths).
    uint length() const @safe pure nothrow @nogc => _len;

    /// Sets the valid-byte count (e.g. before a send); capped by `capacity`.
    void length(uint n) @safe pure nothrow @nogc
    in (n <= _cap, "length exceeds capacity")
    {
        _len = n;
    }

    /// Total usable bytes behind the handle.
    uint capacity() const @safe pure nothrow @nogc => _cap;

    /// Where the memory came from.
    BufOrigin origin() const @safe pure nothrow @nogc => _origin;

    /// `true` for an empty (released or default) handle.
    bool empty() const @safe pure nothrow @nogc => _origin == BufOrigin.none;

    /**
    Wraps caller-owned memory. `@system`: the caller vouches the memory is
    stable and unaliased until the handle (or the kernel) releases it —
    the deleter runs exactly once, on release.
    */
    static Buf fromForeign(ubyte[] mem, BufDeleter deleter) @system nothrow @nogc
    {
        Buf b;
        b._ptr = mem.ptr;
        b._len = 0;
        b._cap = cast(uint) mem.length;
        b._origin = BufOrigin.foreign;
        b._deleter = deleter;
        return b;
    }

    /// Returns the buffer to its origin (pool slot / ring tail / deleter)
    /// and empties the handle. The destructor calls this; explicit release
    /// enables early recycling. (`@trusted`: the owner pointer is written
    /// only by `BufferPool.acquire`, and foreign deleters enter via the
    /// `@system` `fromForeign`.)
    void release() @trusted nothrow @nogc
    {
        final switch (_origin)
        {
            case BufOrigin.none:
                break;
            case BufOrigin.pool:
            case BufOrigin.registered:
                if (_owner !is null)
                    (cast(BufferPool*) _owner).recycle(_slot);
                break;
            case BufOrigin.ringLease:
                // Ring replenishment lands with provided rings (M8).
                assert(0, "ring leases are not implemented until M8");
            case BufOrigin.foreign:
                if (_deleter !is null)
                    _deleter(_ptr, _cap);
                break;
        }
        // Reset field-by-field: `this = Buf.init` would move-assign, whose
        // destroy-the-target step re-enters this destructor path.
        _ptr = null;
        _len = 0;
        _cap = 0;
        _origin = BufOrigin.none;
        _slot = 0;
        _group = BufGroupId.init;
        _owner = null;
        _deleter = null;
    }

    ~this() @safe nothrow @nogc
    {
        release();
    }

package:
    ubyte* _ptr;
    uint _len;
    uint _cap;
    BufOrigin _origin;
    ushort _slot;         // pool slot index (pool/registered origins)
    BufGroupId _group;    // ring-lease group (M8)
    void* _owner;         // owning pool (release routing)
    BufDeleter _deleter;  // foreign origin only
}

/**
Fixed pool of same-size buffers carved out of one contiguous `pureMalloc`
slab (SPEC §6.3). When the backend supports registered buffers the slab is
registered once and every `Buf` carries its slot index; lowering then picks
the FIXED opcodes purely from `Buf.origin` — the user never spells "fixed".
(Registration wiring lands in M8; until then every pool `Buf` has
`BufOrigin.pool`.)
*/
struct BufferPool
{
    @disable this(this);

    /// Allocates `count × bufSize` bytes; all-or-nothing.
    static IoResult!void create(out BufferPool pool, uint count, uint bufSize)
        @trusted nothrow @nogc
    in (count > 0 && count <= ushort.max, "pool slot count must fit a ushort")
    in (bufSize > 0)
    {
        import core.memory : pureCalloc, pureMalloc;

        const slabBytes = cast(size_t) count * bufSize;
        auto slab = cast(ubyte*) pureMalloc(slabBytes);
        if (slab is null)
            return ioErr!void(12 /* ENOMEM */, OpKind.none, IoErrorStage.setup,
                "buffer pool slab allocation failed");
        auto free = cast(ushort*) pureMalloc(count * ushort.sizeof);
        if (free is null)
        {
            import core.memory : pureFree;

            pureFree(slab);
            return ioErr!void(12 /* ENOMEM */, OpKind.none, IoErrorStage.setup,
                "buffer pool free-list allocation failed");
        }

        pool._slab = slab;
        pool._bufSize = bufSize;
        pool._count = count;
        pool._freeList = free;
        pool._freeCount = count;
        foreach (i; 0 .. count)
            free[i] = cast(ushort) (count - 1 - i); // pop order: 0, 1, 2, …
        return ioOk();
    }

    /// Frees the slab. All buffers must have been released back.
    void destroy() @trusted nothrow @nogc
    in (_slab is null || _freeCount == _count, "buffers still checked out")
    {
        import core.memory : pureFree;

        if (_slab !is null)
        {
            pureFree(_slab);
            pureFree(_freeList);
        }
        // Field-by-field for the same reason as Buf.release.
        _slab = null;
        _freeList = null;
        _bufSize = 0;
        _count = 0;
        _freeCount = 0;
    }

    ~this() @safe nothrow @nogc
    {
        destroy();
    }

    /// Hands out one buffer; `ENOBUFS` when the pool is exhausted.
    IoResult!Buf acquire() @trusted nothrow @nogc
    {
        if (_freeCount == 0)
            return ioErr!Buf(105 /* ENOBUFS */, OpKind.none, IoErrorStage.submit,
                "buffer pool exhausted");
        import core.lifetime : move;

        const slot = _freeList[--_freeCount];
        Buf b;
        b._ptr = _slab + cast(size_t) slot * _bufSize;
        b._len = 0;
        b._cap = _bufSize;
        b._origin = BufOrigin.pool;
        b._slot = slot;
        b._owner = &this;
        return ioOk(move(b));
    }

    /// Buffers currently available.
    uint available() const @safe pure nothrow @nogc => _freeCount;

    /// Total buffers in the pool.
    uint count() const @safe pure nothrow @nogc => _count;

package:
    void recycle(ushort slot) @trusted nothrow @nogc
    in (_freeCount < _count, "double release")
    {
        _freeList[_freeCount++] = slot;
    }

private:
    ubyte* _slab;
    ushort* _freeList;
    uint _bufSize;
    uint _count;
    uint _freeCount;
}

/// Owned-buffer requirement for the tier-B generic verbs (SPEC §6.5): a
/// slice of memory that stays put while the buffer $(I value) is not moved.
enum bool isOwnedIoBuf(B) = __traits(compiles, (ref B b) {
    ubyte[] view = b[];
});

static assert(isOwnedIoBuf!Buf);

@("buffer.pool.acquireRelease")
@safe nothrow @nogc
unittest
{
    BufferPool pool;
    auto created = BufferPool.create(pool, 4, 512);
    assert(!created.hasError);
    assert(pool.available == 4);

    {
        auto a = pool.acquire();
        assert(a.hasValue);
        assert(pool.available == 3);
        assert(a.value.capacity == 512);
        assert(a.value.origin == BufOrigin.pool);

        // The view spans the valid bytes, not the capacity.
        assert(a.value.length == 0);
        a.value.length = 16;
        assert(a.value[].length == 16);
    } // Buf dtor releases here
    assert(pool.available == 4);
}

@("buffer.pool.exhaustion")
@safe nothrow @nogc
unittest
{
    import core.lifetime : move;

    BufferPool pool;
    assert(!BufferPool.create(pool, 1, 64).hasError);

    auto first = pool.acquire();
    assert(first.hasValue);
    auto held = move(first.value);

    auto second = pool.acquire();
    assert(second.hasError);
    assert(second.error.errnoValue == 105); // ENOBUFS

    held.release();
    assert(pool.available == 1);
    auto third = pool.acquire();
    assert(third.hasValue);
}

@("buffer.moveTransfersOwnership")
@safe nothrow @nogc
unittest
{
    import core.lifetime : move;

    BufferPool pool;
    assert(!BufferPool.create(pool, 2, 64).hasError);

    auto r = pool.acquire();
    auto a = move(r.value);
    assert(!a.empty);
    auto b = move(a);
    assert(a.empty, "moved-from handle must be empty");
    assert(!b.empty);
    b.release();
    assert(b.empty);
    assert(pool.available == 2);
}

@("buffer.foreign.deleterRunsOnce")
@system nothrow @nogc
unittest
{
    import core.lifetime : move;

    static __gshared int deletions;
    static void del(ubyte* p, size_t cap) nothrow @nogc
    {
        ++deletions;
    }

    static __gshared ubyte[32] mem;
    deletions = 0;
    {
        auto b = Buf.fromForeign(mem[], &del);
        auto c = move(b);
        // b is empty; only c's release may fire the deleter.
    }
    assert(deletions == 1);
}
