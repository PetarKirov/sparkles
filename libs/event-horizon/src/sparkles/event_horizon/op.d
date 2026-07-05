/**
Portable operation vocabulary: typed op descriptors, the `user_data` token
discipline, the op-slot slab with its lifetime state machine, and the
completion shape (SPEC §4). This module is portable — it imports no backend
and never sees an SQE; backend-specific lowering lives in
`sparkles.event_horizon.backend.*`.
*/
module sparkles.event_horizon.op;

import core.lifetime : move;

import sparkles.event_horizon.buffer : Buf;
import sparkles.event_horizon.errors : IoResult, OpKind, fromRes;

/// What kind of slot a completion routes to (packed into the token's top
/// byte). Internal classes let the loop consume its own completions (timers,
/// waker, cancel bookkeeping) without heap contexts.
enum OpClass : ubyte
{
    user,     /// a user-submitted op (dispatches the slot's callback)
    timer,    /// a user-visible timer (dispatches the slot's callback)
    wake,     /// loop-internal waker op (consumed silently)
    internal, /// loop-internal bookkeeping, e.g. cancel CQEs (consumed silently)
}

/**
ABA-safe packed `user_data`: `| class:8 | generation:24 | index:32 |`.

`raw == 0` is reserved invalid — a default `OpToken` never matches a live
slot (generations start at 1 and skip 0 on wrap).
*/
struct OpToken
{
    ulong raw;

    @safe pure nothrow @nogc const:

    /// Slot index within the op slab.
    uint index() => cast(uint) raw;

    /// Generation counter; must match the slot's to resolve.
    uint generation() => cast(uint) ((raw >> 32) & 0xFF_FFFF);

    /// Which completion route this token takes.
    OpClass cls() => cast(OpClass) (raw >> 56);

    /// `false` for the reserved invalid token.
    bool opCast(T : bool)() => raw != 0;

    /// Packs the three fields; the generation is masked to its 24 bits.
    static OpToken pack(uint index, uint generation, OpClass cls) @safe pure nothrow @nogc
        => OpToken((ulong(cls) << 56) | (ulong(generation & 0xFF_FFFF) << 32) | index);
}

/// Public, copyable reference to an in-flight op — the target of
/// cancellation and detach (SPEC §4.2, §5.1).
struct OpHandle
{
    package OpToken token;

    /// `false` for a default (never-submitted) handle.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => cast(bool) token;
}

/// `__kernel_timespec` mirror — library-owned so peer backends satisfy the
/// concept without importing `during` (SPEC §4.1).
struct KernelTimespec
{
    long tv_sec;  /// seconds
    long tv_nsec; /// nanoseconds
}

/// A `sockaddr_storage`-sized POD plus its length — library-owned (SPEC
/// §4.1). Address construction helpers (`ipv4`, …) live in `net` (M6);
/// tier-A callers may fill `storage` with any raw `sockaddr`.
struct SockAddr
{
    ubyte[128] storage; /// raw sockaddr bytes
    uint len;           /// valid length of `storage`
}

// ── descriptors (SPEC §4.1) ─────────────────────────────────────────────────
// A descriptor may contain (a) values copied into the SQE, (b) an owned Buf
// (moved into the op slot and pinned until the terminal completion), and
// (c) values needing kernel-stable storage (SockAddr) — copied into the
// slot's operand store at submit, so the descriptor itself may die
// immediately.

/// The no-op descriptor: a pure submit/complete round-trip.
struct OpNop
{
    /// The portable kind every descriptor names.
    enum kind = OpKind.nop;
}

/// Positioned read into an owned buffer (the buffer's full capacity).
struct OpRead
{
    enum kind = OpKind.read;
    int fd;       /// file descriptor
    Buf buf;      /// destination; comes back via `Completion.buf`
    ulong offset; /// file offset (`ulong.max` = current position)
}

/// Positioned write of the buffer's valid bytes (`buf.length`).
struct OpWrite
{
    enum kind = OpKind.write;
    int fd;
    Buf buf;
    ulong offset;
}

/// Socket receive into the buffer's full capacity.
struct OpRecv
{
    enum kind = OpKind.recv;
    int fd;
    Buf buf;
}

/// Socket send of the buffer's valid bytes.
struct OpSend
{
    enum kind = OpKind.send;
    int fd;
    Buf buf;
}

/// Datagram send to an address (lowered via `SENDMSG`; the address and the
/// msghdr/iovec live in the slot's operand store).
struct OpSendTo
{
    enum kind = OpKind.sendTo;
    int fd;
    Buf buf;
    SockAddr to;
}

/// Datagram receive with source address (lowered via `RECVMSG`; the address
/// is copied into the completion's `Completion.peer`).
struct OpRecvFrom
{
    enum kind = OpKind.recvFrom;
    int fd;
    Buf buf;
}

/// Accept one connection; the completion `res` is the new fd. The peer
/// address is fetched on demand (`getpeername`), not stored per slot.
struct OpAccept
{
    enum kind = OpKind.accept;
    int listenFd;
}

/// Outbound connect; the address is copied into the operand store.
struct OpConnect
{
    enum kind = OpKind.connect;
    int fd;
    SockAddr addr;
}

/// A relative timer (in-ring `TIMEOUT`); the timespec lives in the operand
/// store. Used by `EventLoop.submitAfter`/`submitAt`.
struct OpTimeout
{
    enum kind = OpKind.timeout;
    KernelTimespec rel; /// relative expiry
}

/// DbI trait: exactly what submission accepts — any struct naming its
/// portable `OpKind`.
enum bool isOpDesc(Op) = __traits(compiles, { enum OpKind k = Op.kind; });

static assert(isOpDesc!OpNop);
static assert(isOpDesc!OpRead);
static assert(!isOpDesc!int);

// ── completions (SPEC §4.4) ─────────────────────────────────────────────────

/// Portable projection of completion flags.
enum CompletionFlags : uint
{
    none           = 0,
    more           = 1 << 0, /// multishot: this completion is not the last
    bufferSelected = 1 << 1, /// buf carries a provided-ring lease (M8)
}

/**
What a tier-A callback receives. Passed by `ref`: the callback may
`move(done.buf)` to keep the buffer; otherwise the loop recycles it to its
origin after the callback returns.
*/
struct Completion
{
    OpToken token;         /// the completed op's token
    OpKind kind;           /// portable op kind
    int res;               /// raw result: `>= 0` payload or `-errno`
    CompletionFlags flags; /// portable completion flags
    Buf buf;               /// the buffer moving back out (may be empty)
    SockAddr peer;         /// datagram source (`recvFrom` only)

    /// The typed view of `res`.
    IoResult!uint result() @safe pure nothrow @nogc => fromRes(res, kind);

    /// `false` while a multishot op will post further completions.
    bool isFinal() const @safe pure nothrow @nogc
        => (flags & CompletionFlags.more) == 0;
}

/// Tier-A completion callback: a `@nogc nothrow` function pointer with an
/// explicit context — not a delegate (stored until an arbitrary future
/// completion; dip1000 cannot scope-check that capture, and the
/// function-pointer shape is the `-betterC`/C-ABI floor).
alias OpCallback = void function(void* ctx, ref Completion done) nothrow @nogc;

// ── the op-slot slab (SPEC §4.2–§4.3) ───────────────────────────────────────

/// Slot lifetime states.
///
/// ---
/// free ──submit──▶ armed ──terminal CQE──▶ (callback) ──▶ free
/// armed ──CQE with flags.more──▶ armed              (multishot fan-out)
/// armed ──cancel()──▶ cancelRequested ──terminal CQE──▶ (callback) ──▶ free
/// armed | cancelRequested ──detach()──▶ detached ──terminal CQE──▶ free
/// ---
enum OpState : ubyte
{
    free,            /// recyclable
    armed,           /// in flight
    cancelRequested, /// `ASYNC_CANCEL` submitted; terminal CQE still pending
    detached,        /// owner gone: callback never runs, resources recycle silently
}

/// Why a cancellation reached this op — disambiguates `-ECANCELED` at the
/// fiber tier (SPEC §8.5); recorded here so the slab layout is stable.
enum CancelProvenance : ubyte
{
    none,      /// not cancelled
    explicit_, /// `EventLoop.cancel` / scope interrupt
    deadline,  /// a linked timeout fired
}

version (Posix)
{
    import core.sys.posix.sys.socket : msghdr;
    import core.sys.posix.sys.uio : iovec;

    /// msghdr + iovec storage for the `SENDMSG`/`RECVMSG` lowerings.
    struct MsgOperands
    {
        msghdr hdr;
        iovec iov;
    }
}
else
{
    /// Placeholder until the IOCP backend defines its overlapped storage (M11).
    struct MsgOperands
    {
    }
}

/// Kernel-stable operand storage: anything the submission points at (rather
/// than copies) must live here until the terminal completion — the
/// async-offload rule (SPEC §4.1). One union per slot.
union OperandStore
{
    SockAddr addr;      /// connect / accept peer / datagram address
    KernelTimespec ts;  /// timeout
    MsgOperands msg;    /// sendTo / recvFrom (includes `msg.hdr.msg_name` → `addr`)
}

/// One in-flight operation's bookkeeping.
struct OpSlot
{
    OpCallback callback;      /// completion target (tier B stores its trampoline here)
    void* ctx;                /// callback context
    OpState state;            /// lifetime state
    OpKind kind;              /// portable op kind
    OpClass cls;              /// completion routing class
    CancelProvenance provenance; /// why `-ECANCELED`, when it arrives
    ubyte pendingCqes = 1;    /// CQEs before the slot may be released (linked pairs: 2)
    uint generation = 1;      /// bumped on release; token must match to resolve
    Buf pinned;               /// keep-alive across the in-flight window
    OperandStore operands;    /// kernel-stable operands
    uint nextFree;            /// intrusive free list
    SockAddr peerOut;         /// recvFrom: where the kernel-written address lands
}

/**
Fixed-capacity slot slab, allocated once (`pureMalloc`) at loop creation.
Resolution is one indexed load plus a generation compare; a stale token
(recycled slot) never resolves.
*/
struct OpSlab
{
    @disable this(this);

    /// Allocates `capacity` slots; all-or-nothing.
    IoResult!void initialize(uint capacity) @trusted nothrow @nogc
    in (_slots is null, "already initialized")
    in (capacity > 0)
    {
        import core.memory : pureMalloc;
        import sparkles.event_horizon.errors : IoErrorStage, ioErr, ioOk;

        auto mem = cast(OpSlot*) pureMalloc(capacity * OpSlot.sizeof);
        if (mem is null)
            return ioErr!void(12 /* ENOMEM */, OpKind.none, IoErrorStage.setup,
                "op slab allocation failed");
        _slots = mem;
        _capacity = capacity;
        _liveCount = 0;
        foreach (i; 0 .. capacity)
        {
            import core.lifetime : emplace;

            emplace(&_slots[i]);
            _slots[i].nextFree = i + 1 == capacity ? uint.max : i + 1;
        }
        _freeHead = 0;
        return ioOk();
    }

    /// Frees the slab; every slot must have been released.
    void terminate() @trusted nothrow @nogc
    in (_slots is null || _liveCount == 0, "op slots still in flight")
    {
        import core.memory : pureFree;

        if (_slots !is null)
            pureFree(_slots);
        _slots = null;
        _capacity = 0;
        _liveCount = 0;
        _freeHead = uint.max;
    }

    ~this() @safe nothrow @nogc
    {
        terminate();
    }

    /// Pops a free slot and arms it; the invalid token (`raw == 0`) when
    /// exhausted (the loop maps that to `ENOBUFS`).
    OpToken acquire(OpKind kind, OpClass cls, OpCallback cb, void* ctx)
        @trusted nothrow @nogc
    {
        if (_freeHead == uint.max)
            return OpToken.init;
        const idx = _freeHead;
        auto slot = &_slots[idx];
        _freeHead = slot.nextFree;
        ++_liveCount;

        slot.callback = cb;
        slot.ctx = ctx;
        slot.state = OpState.armed;
        slot.kind = kind;
        slot.cls = cls;
        slot.provenance = CancelProvenance.none;
        slot.pendingCqes = 1;
        return OpToken.pack(idx, slot.generation, cls);
    }

    /// Resolves a token to its live slot; `null` on stale generation or
    /// out-of-range index (a recycled slot's late completion).
    OpSlot* resolve(OpToken t) @trusted nothrow @nogc
    {
        const idx = t.index;
        if (idx >= _capacity)
            return null;
        auto slot = &_slots[idx];
        if ((slot.generation & 0xFF_FFFF) != t.generation
            || slot.state == OpState.free)
            return null;
        return slot;
    }

    /// Recycles a slot: releases any still-pinned buffer, bumps the
    /// generation (skipping 0 on wrap), and pushes it on the free list.
    void release(OpToken t) @trusted nothrow @nogc
    {
        auto slot = resolve(t);
        assert(slot !is null, "release of a stale token");
        slot.pinned.release();
        slot.callback = null;
        slot.ctx = null;
        slot.state = OpState.free;
        ++slot.generation;
        if ((slot.generation & 0xFF_FFFF) == 0)
            slot.generation = 1;
        slot.nextFree = _freeHead;
        _freeHead = t.index;
        --_liveCount;
    }

    /// Slots currently armed / cancel-pending / detached.
    uint liveCount() const @safe pure nothrow @nogc => _liveCount;

    /// Total slots.
    uint capacity() const @safe pure nothrow @nogc => _capacity;

private:
    OpSlot* _slots;
    uint _capacity;
    uint _liveCount;
    uint _freeHead = uint.max;
}

@("op.OpToken.packRoundTrip")
@safe pure nothrow @nogc
unittest
{
    const t = OpToken.pack(7, 0xABCDEF, OpClass.timer);
    assert(t.index == 7);
    assert(t.generation == 0xABCDEF);
    assert(t.cls == OpClass.timer);
    assert(t);
}

@("op.OpToken.generationMask")
@safe pure nothrow @nogc
unittest
{
    // Generations wrap at 24 bits; the class byte must survive untouched.
    const t = OpToken.pack(uint.max, 0x1FF_FFFF, OpClass.internal);
    assert(t.index == uint.max);
    assert(t.generation == 0xFF_FFFF);
    assert(t.cls == OpClass.internal);
}

@("op.OpToken.invalidDefault")
@safe pure nothrow @nogc
unittest
{
    OpToken zero;
    assert(!zero);

    OpHandle none;
    assert(!none);
}

@("op.OpSlab.acquireResolveRelease")
@safe nothrow @nogc
unittest
{
    OpSlab slab;
    assert(!slab.initialize(2).hasError);
    assert(slab.capacity == 2);
    assert(slab.liveCount == 0);

    const t = slab.acquire(OpKind.nop, OpClass.user, null, null);
    assert(t);
    assert(t.index == 0 && t.generation == 1 && t.cls == OpClass.user);
    assert(slab.liveCount == 1);

    auto slot = slab.resolve(t);
    assert(slot !is null);
    assert(slot.state == OpState.armed);
    assert(slot.kind == OpKind.nop);

    slab.release(t);
    assert(slab.liveCount == 0);
    assert(slab.resolve(t) is null, "stale token must not resolve");

    // The recycled slot hands out a new generation.
    const t2 = slab.acquire(OpKind.read, OpClass.user, null, null);
    assert(t2.index == 0 && t2.generation == 2);
    slab.release(t2);
}

@("op.OpSlab.exhaustion")
@safe nothrow @nogc
unittest
{
    OpSlab slab;
    assert(!slab.initialize(1).hasError);
    const a = slab.acquire(OpKind.nop, OpClass.user, null, null);
    assert(a);
    const b = slab.acquire(OpKind.nop, OpClass.user, null, null);
    assert(!b, "exhausted slab must hand out the invalid token");
    slab.release(a);
    const c = slab.acquire(OpKind.nop, OpClass.user, null, null);
    assert(c);
    slab.release(c);
}

@("op.OpSlab.pinnedBufferReleasedOnRelease")
@safe nothrow @nogc
unittest
{
    import sparkles.event_horizon.buffer : BufferPool;

    BufferPool pool;
    assert(!BufferPool.create(pool, 1, 64).hasError);

    OpSlab slab;
    assert(!slab.initialize(1).hasError);

    const t = slab.acquire(OpKind.read, OpClass.user, null, null);
    auto slot = slab.resolve(t);
    auto acquired = pool.acquire();
    slot.pinned = move(acquired.value);
    assert(pool.available == 0);

    // Releasing the slot returns the pinned buffer to its pool — the
    // keep-alive invariant's recycling half.
    slab.release(t);
    assert(pool.available == 1);
}
