/**
The latch (primitives.md §11, SYB3): a count that opens once, when
`countDown` has been called that many times, and then stays open.

One word holds the count and a parked bit. Every `countDown` is a release,
and every wait that returns because the count reached zero acquires all of
them (§13).
*/
module sparkles.base.sync.latch;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : initState, NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

private enum size_t parked = 1, oneCount = 2;

/// The latch for platform `P`.
struct LatchT(P)
{
    package(sparkles.base.sync) P.Atomic!size_t state;

    /// The largest count.
    enum size_t maxCount = size_t.max / oneCount;

    @disable this(this);

    /// A latch that opens after `count` calls of `countDown`; `.init` is open (SYA6).
    this(size_t count) @safe nothrow @nogc
    {
        assert(count <= maxCount, "Latch: the count is too large");
        initState(state, count * oneCount);
    }

    /**
    Counts down by `n`; the call that reaches zero releases every waiter
    (SYB3). Counting below zero fails an assertion.
    */
    void countDown(size_t n = 1) shared @safe nothrow @nogc
    {
        if (n == 0)
            return;
        size_t cur = P.load!(Order.relaxed)(state);
        size_t next;
        do
        {
            assert(cur / oneCount >= n, "Latch: counted down below zero (SYB3)");
            next = cur - n * oneCount;
            if (next < oneCount)
                next &= ~parked;
        }
        // Each count-down releases; the last also acquires the earlier ones,
        // whose release sequence its read continues (§13).
        while (!countCas(cur, next));
        if (next < oneCount && (cur & parked))
            unparkAll!P(keyOf(), Protocol.latch,
                (ref const LockedKey!P lk, UnparkResult res) => UnparkDecision(0));
    }

    /// Whether the count has reached zero.
    bool isOpen() const shared @safe nothrow @nogc => P.load!(Order.acquire)(state) < oneCount;

    /// The count now: a snapshot, for diagnostics.
    size_t count() const shared @safe nothrow @nogc => P.load!(Order.relaxed)(state) / oneCount;

    /// Waits until the count reaches zero (SYB3).
    void wait() shared @safe nothrow @nogc
    {
        if (!isOpen())
            cast(void) waitSlow(Deadline.never, false);
    }

    /**
    As `wait`, by `deadline` or interruptibly; a timeout or a cancellation
    leaves the count unchanged (SYB3).
    */
    WaitStatus waitUntil(MonoTime deadline, bool interruptible = false) shared @safe nothrow @nogc
        => isOpen() ? WaitStatus.ok
            : waitSlow(deadline == MonoTime.max ? Deadline.never : Deadline.at(deadline), interruptible);

    // The same operations on an unshared latch, such as a `__gshared` one.
    void countDown(size_t n = 1) @safe nothrow @nogc => sh.countDown(n);
    bool isOpen() const @trusted nothrow @nogc => (*cast(const shared(LatchT)*) &this).isOpen;
    size_t count() const @trusted nothrow @nogc => (*cast(const shared(LatchT)*) &this).count;
    void wait() @safe nothrow @nogc => sh.wait();
    WaitStatus waitUntil(MonoTime deadline, bool interruptible = false) @safe nothrow @nogc
        => sh.waitUntil(deadline, interruptible);

    /// `waitUntil` with a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) WaitStatus waitTicks(Deadline d, bool interruptible) shared @safe nothrow @nogc
        => isOpen() ? WaitStatus.ok : waitSlow(d, interruptible);

    package(sparkles.base.sync) WaitStatus waitTicks(Deadline d, bool interruptible) @safe nothrow @nogc
        => sh.waitTicks(d, interruptible);

    private WaitStatus waitSlow(Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        const key = keyOf();
        while (true)
        {
            const r = park!P(key, ParkOptions(Protocol.latch, deadline: d,
                    interruptible: observesCancellation!P(interruptible)),
                (ref const LockedKey!P lk) {
                    size_t cur = P.load!(Order.relaxed)(state);
                    while (true)
                    {
                        if (cur < oneCount)
                            return false;
                        if ((cur & parked) || P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur | parked))
                            return true;
                    }
                },
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    if (!haveMore)
                    {
                        size_t cur = P.load!(Order.relaxed)(state);
                        while (!P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur & ~parked)) {}
                    }
                    return false;
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                // The validation's read was relaxed; this is the acquire (§13).
                if (isOpen())
                    return WaitStatus.ok;
                continue;
            case ParkOutcome.unparked:
                return WaitStatus.ok;
            case ParkOutcome.timedOut:
                return WaitStatus.timedOut;
            case ParkOutcome.cancelled:
                return WaitStatus.cancelled;
            }
        }
    }

    /// The count-down's compare-and-swap; the model's seeded fault weakens it (oracle 1).
    private bool countCas(ref size_t expected, size_t desired) shared @safe nothrow @nogc
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.releaseRelaxed))
                return P.cas!(Order.relaxed, Order.relaxed)(state, expected, desired);
        return P.cas!(Order.acqRel, Order.relaxed)(state, expected, desired);
    }

    private size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    private ref shared(LatchT) sh() return @trusted nothrow @nogc => *cast(shared(LatchT)*) &this;
}

/// The latch (primitives.md §11).
alias Latch = LatchT!NativePlatform;

static assert(Latch.sizeof == size_t.sizeof);
static assert(!__traits(compiles, { Latch a; Latch b = a; }), "SYA4");
