/**
The condition variable (primitives.md §6).

`Condition` is one pointer: null, or the address of the lock its waiters use
(SYC1). A notification with the lock held moves the selected waiters onto the
lock's queue instead of waking them — wait morphing — so a broadcast costs
one wake per release rather than a herd (SYC5, SYC6, DS4). A waiter moved
onto the lock continues as that lock's waiter: handed the lock, it returns
holding it; designated, it acquires as the designated waker (SYC2).

The condition knows its lock only by address. Each waiter's park token is a
descriptor of that lock — its word's size, whether it grants by handoff, and
its bits — so a notification, under both buckets' locks, can mark the lock
parked or acquire it for the waiter it wakes, for `Mutex`, `LockBits` and
`InterruptibleMutex` alike (SYC9).
*/
module sparkles.base.sync.condition;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex;
import sparkles.base.sync.mutex;
import sparkles.base.sync.parker : observesCancellation, pins;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

public import sparkles.base.sync.interruptible_mutex : WaitStatus;

// ---------------------------------------------------------------------------
// Lock descriptors.

private enum size_t handoffFlag = 1 << 2;

/// Encodes a lock word's shape as a park token.
private size_t describe(size_t size, bool handoff, ulong L, ulong PK) @safe pure nothrow @nogc
{
    import core.bitop : bsf;

    const sizeLog = size == 1 ? 0 : size == 2 ? 1 : size == 4 ? 2 : 3;
    return sizeLog | (handoff ? handoffFlag : 0) | (bsf(L) << 8) | (bsf(PK) << 16);
}

private bool grantsByHandoff(size_t desc) @safe pure nothrow @nogc => (desc & handoffFlag) != 0;

/// Runs `op!T(word, L, PK)` on the lock word `key` describes.
private auto onWord(P, alias op)(size_t desc, size_t key) @trusted
{
    const L = 1UL << ((desc >> 8) & 63), PK = 1UL << ((desc >> 16) & 63);
    switch (desc & 3)
    {
    case 0: return op!ubyte(*cast(P.Atomic!ubyte*) key, cast(ubyte) L, cast(ubyte) PK);
    case 1: return op!ushort(*cast(P.Atomic!ushort*) key, cast(ushort) L, cast(ushort) PK);
    case 2: return op!uint(*cast(P.Atomic!uint*) key, cast(uint) L, cast(uint) PK);
    default: return op!ulong(*cast(P.Atomic!ulong*) key, cast(ulong) L, cast(ulong) PK);
    }
}

private template ops(P)
{
    /// If held, mark parked; whether it was held (SYC5).
    bool markParkedIfHeld(T)(ref P.Atomic!T word, T L, T PK)
    {
        T cur = P.load!(Order.relaxed)(word);
        while (cur & L)
            if (P.cas!(Order.relaxed, Order.relaxed)(word, cur, cast(T)(cur | PK)))
                return true;
        return false;
    }

    bool markParked(T)(ref P.Atomic!T word, T L, T PK)
    {
        T cur = P.load!(Order.relaxed)(word);
        while (!P.cas!(Order.relaxed, Order.relaxed)(word, cur, cast(T)(cur | PK))) {}
        return true;
    }

    /// Acquires a free lock for the waiter a notification wakes (SYC6).
    bool acquireFor(T)(ref P.Atomic!T word, T L, T PK)
    {
        T cur = P.load!(Order.relaxed)(word);
        while (!(cur & L))
            if (P.cas!(Order.acquire, Order.relaxed)(word, cur, cast(T)(cur | L)))
                return true;
        return false;
    }
}

// ---------------------------------------------------------------------------
// The locks a condition accepts, as a wait sees them.

/// A `Mutex` or `LockBits` word: pins, barges, designates.
private struct BitsLock(P, alias Impl, T, T L, T PK)
{
    shared(P.Atomic!T)* word;
    enum uint pinCount = 1;

    size_t key() const @trusted => cast(size_t) word;
    size_t descriptor() const => describe(T.sizeof, false, L, PK);
    void release() @trusted => Impl.unlock(*word);
    void relock(size_t token) @trusted => Impl.relockAfterWake(*word, token);
}

/// An `InterruptibleMutex`: no pin, FIFO handoff.
private struct HandoffLock(P)
{
    shared(InterruptibleMutexT!P)* mutex;
    enum uint pinCount = 0;

    size_t key() const @trusted => (cast(shared(InterruptibleMutexT!P)*) mutex).keyOf();
    size_t descriptor() const => describe(1, true, 1, 2);
    void release() => mutex.release();

    void relock(size_t token)
    {
        // Reacquisition is never interruptible (SYC3, SYJ1).
        if (token != tokenHandoff)
            cast(void) mutex.acquireRaw(Deadline.never, false);
    }
}

private auto lockOf(P)(ref MutexGuard!P g) @trusted
    => BitsLock!(P, MutexT!P.Impl, ubyte, 1, 2)(&g.lock().word());

private auto lockOf(P)(ref InterruptibleGuard!P g)
{
    assert(g.holds, "a condition wait needs a guard that holds its mutex");
    return HandoffLock!P(g.lock());
}

/// A `LockBits` guard, which exposes its word's shape.
private auto lockOf(P, G)(ref G g) @trusted
    if (__traits(hasMember, G, "lockedBit"))
    => BitsLock!(NativePlatform, G.Impl, G.Word, G.lockedBit, G.parkedBit)(&g.lockWord());

/// A guarded payload's guard waits through the mutex guard it holds (SYG4).
private auto lockOf(P, G)(ref G g)
    if (__traits(hasMember, G, "mutexGuard"))
    => lockOf!P(g.mutexGuard);

// ---------------------------------------------------------------------------
// The condition.

/// The condition variable for platform `P`.
struct ConditionT(P)
{
    package(sparkles.base.sync) P.Atomic!size_t state;

    @disable this(this);

    /**
    Releases the guard's lock, waits for a notification, and returns with the
    lock held again (SYC2). Never returns spuriously.
    */
    void wait(G)(ref G guard) shared => cast(void) waitWith(lockOf!P(guard), Deadline.never, false);

    /// As `wait`, but also returns `false` when `deadline` passes first (SYC3).
    bool waitUntil(G)(ref G guard, MonoTime deadline) shared
        => waitWith(lockOf!P(guard), Deadline.at(deadline), false) == WaitStatus.ok;

    /// As `wait`, but also reports cancellation while waiting for a notification (SYC3).
    WaitStatus waitInterruptible(G)(ref G guard, MonoTime deadline = MonoTime.max) shared
        => waitWith(lockOf!P(guard), deadline == MonoTime.max ? Deadline.never
            : Deadline.at(deadline), true);

    void wait(G)(ref G guard) => sh.wait(guard);
    bool waitUntil(G)(ref G guard, MonoTime deadline) => sh.waitUntil(guard, deadline);
    WaitStatus waitInterruptible(G)(ref G guard, MonoTime deadline = MonoTime.max)
        => sh.waitInterruptible(guard, deadline);

    /// A wait with a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) WaitStatus waitTicks(G)(ref G guard, Deadline d, bool interruptible) shared
        => waitWith(lockOf!P(guard), d, interruptible);

    package(sparkles.base.sync) WaitStatus waitTicks(G)(ref G guard, Deadline d, bool interruptible)
        => sh.waitTicks(guard, d, interruptible);

    private WaitStatus waitWith(L)(L lock, Deadline d, bool interruptible) shared @trusted
    {
        // The wait drops its own lock's pin before it sleeps; another lock's
        // pin is a programming error (SYK9).
        assert(pins!P == L.pinCount, "a condition wait while another lock pins the caller (SYK9)");
        const key = cast(size_t) &state;
        const lockKey = lock.key;
        const r = park!P(key, ParkOptions(Protocol.condition, parkToken: lock.descriptor, deadline: d,
                interruptible: observesCancellation!P(interruptible, L.pinCount), pinAdjust: L.pinCount),
            (ref const LockedKey!P lk) {
                const cur = P.load!(Order.relaxed)(state);
                if (cur == 0)
                    P.store!(Order.relaxed)(state, lockKey);
                else
                    assert(cur == lockKey, "a condition used with two locks at once (SYC4)");
                return true;
            },
            () { lock.release(); },
            (ref const LockedKey!P lk, bool haveMore) {
                if (!haveMore)
                    P.store!(Order.relaxed)(state, cast(size_t) 0);
            });
        final switch (r.outcome)
        {
        case ParkOutcome.unparked:
            // Selected: continue as the lock's waiter (SYC2), reporting the
            // notification whatever the deadline or cancellation did (SYC7).
            lock.relock(r.token);
            return WaitStatus.ok;
        case ParkOutcome.timedOut:
            lock.relock(tokenNotified);
            return WaitStatus.timedOut;
        case ParkOutcome.cancelled:
            lock.relock(tokenNotified);
            return WaitStatus.cancelled;
        case ParkOutcome.invalid:
            assert(0, "a condition wait always enqueues");
        }
    }

    /// Selects one waiter; whether there was one (SYC5). With none, one atomic load (SYC8).
    bool notifyOne() shared @safe nothrow @nogc => notify(false) != 0;

    /// Selects every waiter; how many (SYC6).
    uint notifyAll() shared @safe nothrow @nogc => notify(true);

    bool notifyOne() @safe nothrow @nogc => sh.notifyOne();
    uint notifyAll() @safe nothrow @nogc => sh.notifyAll();

    private uint notify(bool all) shared @trusted nothrow @nogc
    {
        const lockKey = P.load!(Order.relaxed)(state);
        if (lockKey == 0)
            return 0;
        const key = cast(size_t) &state;
        size_t token, desc;
        bool freeLock;
        ubyte toProtocol = Protocol.mutex;
        const r = unparkRequeue!P(key, Protocol.condition, lockKey, toProtocol,
            (ref const LockedKey!P from, ref const LockedKey!P to) {
                if (P.load!(Order.relaxed)(state) != lockKey)
                    return RequeueOp.abort;
                desc = from.headParkToken;
                if (desc == size_t.max)
                    return RequeueOp.abort;
                const handoff = grantsByHandoff(desc);
                toProtocol = handoff ? Protocol.interruptibleMutex : Protocol.mutex;
                // Held: move them onto its queue, marked parked in the same
                // read–modify–write that saw it held (SYC5, SYC6).
                if (onWord!(P, ops!P.markParkedIfHeld)(desc, lockKey))
                    return all ? RequeueOp.requeueAll : RequeueOp.requeueOne;
                freeLock = true;
                if (handoff)
                {
                    // A lock that grants only by handoff is acquired here for
                    // the waiter woken, so none is left queued on a free lock.
                    if (!onWord!(P, ops!P.acquireFor)(desc, lockKey))
                    {
                        cast(void) onWord!(P, ops!P.markParked)(desc, lockKey);
                        freeLock = false;
                        return all ? RequeueOp.requeueAll : RequeueOp.requeueOne;
                    }
                    token = tokenHandoff;
                }
                else
                    token = tokenNotified;
                return all ? RequeueOp.unparkOneRequeueRest : RequeueOp.unparkOne;
            },
            (ref const LockedKey!P from, ref const LockedKey!P to, UnparkResult res) {
                if (!res.haveMore)
                    P.store!(Order.relaxed)(state, cast(size_t) 0);
                if (freeLock && res.requeued)
                    cast(void) onWord!(P, ops!P.markParked)(desc, lockKey);
                return UnparkDecision(res.unparked ? token : 0);
            });
        return r.unparked + r.requeued;
    }

    private ref shared(ConditionT) sh() return @trusted nothrow @nogc => *cast(shared(ConditionT)*) &this;
}

/// The condition variable (primitives.md §6).
alias Condition = ConditionT!NativePlatform;

static assert(Condition.sizeof == size_t.sizeof, "SYC1");
