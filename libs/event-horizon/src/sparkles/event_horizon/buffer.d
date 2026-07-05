/**
Owned-buffer currency for the completion window (SPEC §6).

`Buf` is a move-only handle over $(I pinned, stable) memory — a pool slab
slot, a registered-buffer slot, a provided-ring lease, or vouched-for foreign
memory. The kernel holds the pointer from submission to the terminal
completion, so the bytes must not move or be freed in that window; that is
why `SmallBuffer` (whose small-buffer optimization relocates the payload on
struct moves) is banned as the tier-A transfer currency.

Memory management follows the
[composable-allocator guidelines](../../../../../docs/guidelines/allocators/index.md):
the pool is generic over an `Allocator` (the §4 recipe — `stateSize` embed,
`Mallocator` default, attributes inferred) and draws its backing slab through
`makeArray`/`dispose`. The slot-index structure stays bespoke: slot indices
are the `buf_index`/`bid` currency for `READ_FIXED` and provided rings, which
a plain `FreeList` cannot provide. Page-aligned parents
(`MmapAllocator`/`AscendingPageAllocator`) suit pools destined for buffer
registration.
*/
module sparkles.event_horizon.buffer;

import std.experimental.allocator : dispose, makeArray, stateSize;
import std.experimental.allocator.mallocator : Mallocator;

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

/// Type-erased pool-recycle hook: pools are generic over their allocator,
/// so the handle routes releases through a function pointer instead of a
/// concrete pool type.
alias BufRecycleFn = void function(void* owner, ushort slot) nothrow @nogc;

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

    /// `true` when this buffer is a registered-buffer slot — lowering then
    /// selects the `READ_FIXED`/`WRITE_FIXED` opcodes automatically.
    bool isRegistered() const @safe pure nothrow @nogc
        => _origin == BufOrigin.registered;

    /// The registered-buffer index (`buf_index`) for a registered `Buf`.
    ushort bufIndex() const @safe pure nothrow @nogc
    in (_origin == BufOrigin.registered, "not a registered buffer")
        => _slot;

    /// The provided-ring buffer id (`bid`) for a ring-leased `Buf`.
    ushort ringLeaseId() const @safe pure nothrow @nogc
    in (_origin == BufOrigin.ringLease, "not a ring lease")
        => _slot;

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
                if (_recycleFn !is null)
                    _recycleFn(_owner, _slot);
                break;
            case BufOrigin.ringLease:
                // Releasing a ring lease republishes the slot to the kernel
                // by advancing the ring's producer tail (no syscall).
                if (_recycleFn !is null)
                    _recycleFn(_owner, _slot);
                break;
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
        _recycleFn = null;
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
    ushort _slot;             // pool slot index (pool/registered origins)
    BufGroupId _group;        // ring-lease group (M8)
    void* _owner;             // owning pool (release routing)
    BufRecycleFn _recycleFn;  // type-erased recycle into the owner
    BufDeleter _deleter;      // foreign origin only
}

/**
Fixed pool of same-size buffers carved out of one contiguous slab drawn from
`Allocator` (SPEC §6.3) — the guideline-§4 generic-library shape: monostate
allocators cost zero bytes (`stateSize` idiom), stateful ones are passed to
`create` and embedded. When the backend supports registered buffers the slab
is registered once and every `Buf` carries its slot index; lowering then
picks the FIXED opcodes purely from `Buf.origin` — the user never spells
"fixed". (Registration wiring lands in M8; until then every pool `Buf` has
`BufOrigin.pool`.)
*/
struct BufferPool(Allocator = Mallocator)
{
    @disable this(this);

    // The standard state idiom: a monostate allocator costs zero bytes.
    static if (stateSize!Allocator)
        Allocator alloc;
    else
        alias alloc = Allocator.instance;

    /// Allocates `count × bufSize` bytes; all-or-nothing.
    static IoResult!void create(out BufferPool pool, uint count, uint bufSize)
    in (count > 0 && count <= ushort.max, "pool slot count must fit a ushort")
    in (bufSize > 0)
    {
        return pool.initialize(count, bufSize);
    }

    /// ditto — with a stateful allocator instance.
    static if (stateSize!Allocator)
        static IoResult!void create(out BufferPool pool, Allocator alloc,
            uint count, uint bufSize)
        in (count > 0 && count <= ushort.max, "pool slot count must fit a ushort")
        in (bufSize > 0)
        {
            import core.lifetime : move;

            pool.alloc = move(alloc);
            return pool.initialize(count, bufSize);
        }

    private IoResult!void initialize(uint count, uint bufSize) @trusted
    {
        auto slab = alloc.makeArray!ubyte(cast(size_t) count * bufSize);
        if (slab is null)
            return ioErr!void(12 /* ENOMEM */, OpKind.none, IoErrorStage.setup,
                "buffer pool slab allocation failed");
        auto free = alloc.makeArray!ushort(count);
        if (free is null)
        {
            cast(void) alloc.dispose(slab);
            return ioErr!void(12 /* ENOMEM */, OpKind.none, IoErrorStage.setup,
                "buffer pool free-list allocation failed");
        }

        _slab = slab.ptr;
        _bufSize = bufSize;
        _count = count;
        _freeList = free.ptr;
        _freeCount = count;
        foreach (i; 0 .. count)
            free[i] = cast(ushort) (count - 1 - i); // pop order: 0, 1, 2, …
        return ioOk();
    }

    /// Frees the slab. All buffers must have been released back.
    void destroy() @trusted
    in (_slab is null || _freeCount == _count, "buffers still checked out")
    {
        if (_slab !is null)
        {
            cast(void) alloc.dispose(_slab[0 .. cast(size_t) _count * _bufSize]);
            cast(void) alloc.dispose(_freeList[0 .. _count]);
        }
        if (_registered.length)
        {
            cast(void) alloc.dispose(_registered);
            _registered = null;
        }
        // Field-by-field for the same reason as Buf.release.
        _slab = null;
        _freeList = null;
        _bufSize = 0;
        _count = 0;
        _freeCount = 0;
    }

    ~this() @safe
    {
        destroy();
    }

    /**
    Registers every slot as a kernel-pinned buffer (`REGISTER_BUFFERS`) on
    `backend` when it supports them, so acquired `Buf`s carry
    `BufOrigin.registered` and the read/write lowerings pick the FIXED
    opcodes automatically (SPEC §6.3). Idempotent-safe to skip: on a backend
    without the capability the pool stays a plain pool — same API, honest
    degradation (recorded in caps). Must run before any buffer is acquired.
    */
    IoResult!void register(Backend)(ref Backend backend) @trusted
    in (_registered.length == 0, "already registered")
    in (_freeCount == _count, "register before acquiring")
    {
        static if (__traits(hasMember, Backend, "caps")
            && __traits(hasMember, Backend, "registerBuffers"))
        {
            if (!backend.caps().registeredBuffers)
                return ioOk(); // capability absent: stay a plain pool

            auto iovecs = alloc.makeArray!(ubyte[])(_count);
            if (iovecs is null)
                return ioErr!void(12 /* ENOMEM */, OpKind.none,
                    IoErrorStage.registration, "iovec table allocation failed");
            foreach (i; 0 .. _count)
                iovecs[i] = _slab[cast(size_t) i * _bufSize
                    .. cast(size_t) (i + 1) * _bufSize];
            auto r = backend.registerBuffers(iovecs);
            if (r.hasError)
            {
                cast(void) alloc.dispose(iovecs);
                return r;
            }
            _registered = iovecs;
        }
        return ioOk();
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
        b._origin = _registered.length ? BufOrigin.registered : BufOrigin.pool;
        b._slot = slot;
        b._owner = &this;
        b._recycleFn = &recycleShim;
        return ioOk(move(b));
    }

    /// The type-erased recycle hook `Buf.release` routes through.
    private static void recycleShim(void* owner, ushort slot) @trusted nothrow @nogc
    {
        (cast(BufferPool*) owner).recycle(slot);
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
    ubyte[][] _registered; // non-empty once the slab is kernel-registered
    uint _bufSize;
    uint _count;
    uint _freeCount;
}

/// A provided-buffer-ring slot — a library-owned mirror of the kernel's
/// `io_uring_buf` (16 bytes, ABI-exact) so `buffer.d` stays backend-agnostic.
struct UringBufSlot
{
    ulong addr;  /// buffer address
    uint len;    /// buffer length
    ushort bid;  /// buffer id
    ushort resv; /// reserved; slot 0's `resv` overlays the ring's producer tail
}

static assert(UringBufSlot.sizeof == 16);

/**
A provided buffer ring (SPEC §6.4): the kernel picks a buffer from this ring
only when data actually arrives — a `recvSelect` op commits no buffer while
idle, the completion carries the chosen buffer id, and releasing that
ring-leased `Buf` republishes the slot by advancing the ring's producer tail
(no syscall). This decouples buffer count from connection count — the C10K
enabler.

The ring itself is page-aligned (a kernel requirement); the backing store is
drawn from `Allocator` (page-aligned parents suit registration). `entries`
must be a power of two.
*/
struct BufRing(Allocator = Mallocator)
{
    @disable this(this);

    static if (stateSize!Allocator)
        Allocator alloc;
    else
        alias alloc = Allocator.instance;

    /// Allocates the page-aligned ring and its backing store; publishes all
    /// `entries` buffers. Register it with the loop separately (the backend
    /// call needs the ring address).
    static IoResult!void create(out BufRing ring, BufGroupId group,
        uint entries, uint bufSize)
    in ((entries & (entries - 1)) == 0, "entries must be a power of two")
    in (entries > 0 && entries <= ushort.max && bufSize > 0)
    {
        return ring.initialize(group, entries, bufSize);
    }

    /// ditto — with a stateful allocator instance.
    static if (stateSize!Allocator)
        static IoResult!void create(out BufRing ring, Allocator alloc,
            BufGroupId group, uint entries, uint bufSize)
        {
            import core.lifetime : move;

            ring.alloc = move(alloc);
            return ring.initialize(group, entries, bufSize);
        }

    private IoResult!void initialize(BufGroupId group, uint entries, uint bufSize)
        @trusted
    {
        import std.experimental.allocator.mallocator : AlignedMallocator;

        // The ring must be page-aligned (IORING_REGISTER_PBUF_RING).
        auto ringMem = AlignedMallocator.instance.alignedAllocate(
            UringBufSlot.sizeof * entries, 4096);
        if (ringMem is null)
            return ioErr!void(12 /* ENOMEM */, OpKind.none,
                IoErrorStage.registration, "buffer ring allocation failed");
        auto store = alloc.makeArray!ubyte(cast(size_t) entries * bufSize);
        if (store is null)
        {
            cast(void) AlignedMallocator.instance.deallocate(ringMem);
            return ioErr!void(12 /* ENOMEM */, OpKind.none,
                IoErrorStage.registration, "buffer ring store allocation failed");
        }

        _ring = cast(UringBufSlot*) ringMem.ptr;
        _store = store.ptr;
        _group = group;
        _entries = entries;
        _bufSize = bufSize;
        _mask = entries - 1;

        // Publish all buffers, then set the tail (slot 0's resv) last.
        foreach (ushort i; 0 .. cast(ushort) entries)
        {
            _ring[i].addr = cast(ulong) &_store[cast(size_t) i * bufSize];
            _ring[i].len = bufSize;
            _ring[i].bid = i;
        }
        publishTail(cast(ushort) entries);
        _tail = cast(ushort) entries;
        return ioOk();
    }

    /// Frees the ring and store. Unregister from the loop first.
    void destroy() @trusted
    {
        import std.experimental.allocator.mallocator : AlignedMallocator;

        if (_ring !is null)
        {
            cast(void) AlignedMallocator.instance.deallocate(
                _ring[0 .. _entries]);
            cast(void) alloc.dispose(_store[0 .. cast(size_t) _entries * _bufSize]);
        }
        _ring = null;
        _store = null;
        _entries = 0;
        _bufSize = 0;
    }

    ~this() @safe
    {
        destroy();
    }

    /// The group id (`bgid`).
    BufGroupId group() const @safe pure nothrow @nogc => _group;

    /// The ring's base address (for the backend's `registerBufRing`).
    void* ringAddr() @system nothrow @nogc => _ring;

    /// The number of ring entries.
    uint entries() const @safe pure nothrow @nogc => _entries;

    /// Builds the ring-leased `Buf` for a completion that selected buffer
    /// `bid`, carrying `len` valid bytes. Releasing it republishes the slot.
    Buf lease(ushort bid, uint len) @trusted nothrow @nogc
    in (bid < _entries)
    {
        Buf b;
        b._ptr = &_store[cast(size_t) bid * _bufSize];
        b._len = len <= _bufSize ? len : _bufSize;
        b._cap = _bufSize;
        b._origin = BufOrigin.ringLease;
        b._slot = bid;
        b._group = _group;
        b._owner = &this;
        b._recycleFn = &republishShim;
        return b;
    }

package:
    /// Republishes buffer `bid` at the producer tail, then advances it.
    void republish(ushort bid) @trusted nothrow @nogc
    {
        const pos = _tail & _mask;
        _ring[pos].addr = cast(ulong) &_store[cast(size_t) bid * _bufSize];
        _ring[pos].len = _bufSize;
        _ring[pos].bid = bid;
        ++_tail;
        publishTail(_tail); // release store — the kernel reads this last
    }

private:
    static void republishShim(void* owner, ushort bid) @trusted nothrow @nogc
    {
        (cast(BufRing*) owner).republish(bid);
    }

    void publishTail(ushort tail) @trusted nothrow @nogc
    {
        import core.atomic : MemoryOrder, atomicStore;

        // The tail overlays slot 0's `resv` field (offset 14).
        atomicStore!(MemoryOrder.rel)(_ring[0].resv, tail);
    }

    UringBufSlot* _ring; // page-aligned; slot 0's resv is the producer tail
    ubyte* _store;
    BufGroupId _group;
    uint _entries;
    uint _bufSize;
    ushort _tail;
    uint _mask;
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
    BufferPool!() pool;
    auto created = BufferPool!().create(pool, 4, 512);
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

    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 1, 64).hasError);

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

    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 2, 64).hasError);

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

@("buffer.bufRing.leaseRepublishBookkeeping")
@safe nothrow @nogc
unittest
{
    import core.lifetime : move;

    // Pure ring bookkeeping (no kernel): lease → republish advances the tail
    // and rewrites the slot, so the ring is a correct SPSC producer.
    BufRing!() ring;
    assert(!BufRing!().create(ring, BufGroupId(3), 4, 64).hasError);
    assert(ring.entries == 4);
    assert(ring.group.value == 3);

    auto a = ring.lease(2, 40);
    assert(a.origin == BufOrigin.ringLease);
    assert(a.ringLeaseId == 2);
    assert(a.length == 40 && a.capacity == 64);
    a.release(); // republishes slot 2 at the producer tail

    auto b = ring.lease(0, 64);
    assert(b.length == 64);
    b.release();
}

@("buffer.pool.gracefulDegradationWithoutCaps")
@safe nothrow @nogc
unittest
{
    import core.lifetime : move;

    // Caps fault injection (open-issues O5): a backend reporting
    // registeredBuffers = false must leave the pool a plain pool — the
    // graceful-degradation path, exercised on any kernel.
    static struct MockCaps
    {
        bool registeredBuffers;
    }

    static struct MockBackend
    {
        MockCaps _caps;
        ref const(MockCaps) caps() const return => _caps;
        IoResult!void registerBuffers(scope ubyte[][]) => ioOk();
    }

    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 2, 64).hasError);

    MockBackend noCaps; // registeredBuffers stays false
    assert(!pool.register(noCaps).hasError);

    auto b = pool.acquire();
    assert(b.hasValue);
    assert(b.value.origin == BufOrigin.pool, "no caps -> plain pool, not registered");
    assert(!b.value.isRegistered);
}
