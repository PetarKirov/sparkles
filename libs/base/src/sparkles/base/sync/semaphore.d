/**
The counting semaphore (primitives.md §9).

One word holds the permit count and a parked bit (SYS1). While waiters are
parked, `release` hands its permits to them in queue order, waking each with
the handoff token instead of raising the count (SYS3); a waiter that is
handed a permit keeps it even if its deadline passes or a cancellation
arrives before it returns (SYS4).
*/
module sparkles.base.sync.semaphore;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : initState, NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

private enum size_t parked = 1, onePermit = 2;

/// The counting semaphore for platform `P`.
struct SemaphoreT(P)
{
    package(sparkles.base.sync) P.Atomic!size_t state;

    /// The largest permit count.
    enum size_t maxPermits = size_t.max / onePermit;

    @disable this(this);

    /// A semaphore holding `permits` permits; `.init` holds none (SYA6).
    this(size_t permits) @safe nothrow @nogc
    {
        assert(permits <= maxPermits, "Semaphore: too many permits (SYS5)");
        initState(state, permits * onePermit);
    }

    /// Takes a permit, parking until one is available (SYS2).
    void acquire() shared @safe nothrow @nogc
    {
        if (!tryAcquire())
            cast(void) acquireSlow(Deadline.never, false);
    }

    /**
    Takes a permit by `deadline`, or interruptibly: `ok` holding it, or
    `timedOut` or `cancelled` with nothing taken (SYS2, SYS4).
    */
    WaitStatus acquireUntil(MonoTime deadline, bool interruptible = false) shared @safe nothrow @nogc
        => tryAcquire() ? WaitStatus.ok
            : acquireSlow(deadline == MonoTime.max ? Deadline.never : Deadline.at(deadline), interruptible);

    /// Takes a permit if one is available, without parking (SYS2).
    bool tryAcquire() shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (cur >= onePermit)
            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur - onePermit))
                return true;
        return false;
    }

    /**
    Adds `n` permits (SYS2). Parked waiters are handed them first, in queue
    order (SYS3); the rest raise the count.
    */
    void release(size_t n = 1) shared @safe nothrow @nogc
    {
        if (n == 0)
            return;
        size_t cur = P.load!(Order.relaxed)(state);
        while (!(cur & parked))
        {
            assert(n <= maxPermits - cur / onePermit, "Semaphore: the permit count overflows (SYS5)");
            if (releaseCas(cur, cur + n * onePermit))
                return;
        }
        releaseSlow(n);
    }

    /// The permits available now: a snapshot, for diagnostics.
    size_t available() const shared @safe nothrow @nogc => P.load!(Order.relaxed)(state) / onePermit;

    // The same operations on an unshared semaphore, such as a `__gshared` one.
    void acquire() @safe nothrow @nogc => sh.acquire();
    WaitStatus acquireUntil(MonoTime deadline, bool interruptible = false) @safe nothrow @nogc
        => sh.acquireUntil(deadline, interruptible);
    bool tryAcquire() @safe nothrow @nogc => sh.tryAcquire();
    void release(size_t n = 1) @safe nothrow @nogc => sh.release(n);
    size_t available() const @trusted nothrow @nogc => (*cast(const shared(SemaphoreT)*) &this).available;

    /// `acquireUntil` with a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) WaitStatus acquireTicks(Deadline d, bool interruptible) shared @safe nothrow @nogc
        => tryAcquire() ? WaitStatus.ok : acquireSlow(d, interruptible);

    package(sparkles.base.sync) WaitStatus acquireTicks(Deadline d, bool interruptible) @safe nothrow @nogc
        => sh.acquireTicks(d, interruptible);

    private WaitStatus acquireSlow(Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        const key = keyOf();
        while (true)
        {
            bool took;
            const r = park!P(key, ParkOptions(Protocol.semaphore, deadline: d,
                    interruptible: observesCancellation!P(interruptible)),
                (ref const LockedKey!P lk) {
                    size_t cur = P.load!(Order.relaxed)(state);
                    while (true)
                    {
                        if (cur >= onePermit)
                        {
                            // A permit is free: take it here, under the lock,
                            // rather than park behind nobody.
                            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur - onePermit))
                            {
                                took = true;
                                return false;
                            }
                            continue;
                        }
                        if ((cur & parked) || P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur | parked))
                            return true;
                    }
                },
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    if (!haveMore)
                        clearParked();
                    return false;
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                if (took)
                    return WaitStatus.ok;
                continue;
            case ParkOutcome.unparked:
                // Handed a permit (SYS3); a deadline or a cancellation that
                // lost to the handoff does not undo it (SYS4).
                assert(r.token == tokenHandoff, "a semaphore waiter woken with a foreign token");
                return WaitStatus.ok;
            case ParkOutcome.timedOut:
                return WaitStatus.timedOut;
            case ParkOutcome.cancelled:
                return WaitStatus.cancelled;
            }
        }
    }

    private void releaseSlow(size_t n) shared @safe nothrow @nogc
    {
        size_t handed;
        unparkFilter!P(keyOf(), Protocol.semaphore,
            (size_t) {
                if (handed == n)
                    return FilterOp.stop;
                ++handed;
                return FilterOp.wake;
            },
            (ref const LockedKey!P lk, UnparkResult res) {
                // The permits nobody was handed raise the count; the parked
                // bit follows the queue (SYP15). The handoffs' edge is the
                // parks' return (SYH1, SYH2); the count's is this release.
                const rest = n - res.unparked;
                size_t cur = P.load!(Order.relaxed)(state);
                while (true)
                {
                    assert(rest <= maxPermits - cur / onePermit, "Semaphore: the permit count overflows (SYS5)");
                    size_t next = cur + rest * onePermit;
                    next = res.haveMore ? next | parked : next & ~parked;
                    if (releaseCas(cur, next))
                        break;
                }
                return UnparkDecision(tokenHandoff);
            });
    }

    /// A release compare-and-swap; the model's seeded fault weakens it (oracle 1).
    private bool releaseCas(ref size_t expected, size_t desired) shared @safe nothrow @nogc
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.releaseRelaxed))
                return P.cas!(Order.relaxed, Order.relaxed)(state, expected, desired);
        return P.cas!(Order.release, Order.relaxed)(state, expected, desired);
    }

    private void clearParked() shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (!P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur & ~parked)) {}
    }

    private size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    private ref shared(SemaphoreT) sh() return @trusted nothrow @nogc => *cast(shared(SemaphoreT)*) &this;
}

/// The counting semaphore (primitives.md §9).
alias Semaphore = SemaphoreT!NativePlatform;

static assert(Semaphore.sizeof == size_t.sizeof, "SYS1");
static assert(!__traits(compiles, { Semaphore a; Semaphore b = a; }), "SYA4");
