/**
The reusable barrier (primitives.md §11, SYB1, SYB2).

One word holds the current generation and the arrivals counted in it. The
`n`-th arrival completes the generation: it starts the next one and wakes
the waiters whose park token is the completed generation, so a party of a
later generation is never released by an earlier one (SYB1). A waiter that
times out or is cancelled withdraws its arrival under the bucket lock,
unless its generation completed first: the park then reports the wait
satisfied, and the arrival succeeds with any cancellation left pending
(SYB2, SYI2).
*/
module sparkles.base.sync.barrier;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

private enum ulong arrivedMask = uint.max, oneGeneration = 1UL << 32;

private uint generationOf(ulong s) @safe pure nothrow @nogc => cast(uint)(s >> 32);
private uint arrivedOf(ulong s) @safe pure nothrow @nogc => cast(uint)(s & arrivedMask);

/// An arrival's result: how its wait ended, and whether it completed the generation.
struct Arrival
{
    WaitStatus status;
    /// The one arrival per generation that completed it (SYB1).
    bool leader;

    /// Whether the generation completed with this party counted in it.
    bool opCast(T : bool)() const @safe nothrow @nogc => status == WaitStatus.ok;
}

/// The barrier for platform `P`.
struct BarrierT(P)
{
    package(sparkles.base.sync) P.Atomic!ulong state;
    // Parties less one, so that `.init` is a barrier of one (SYA6).
    private uint partiesLess1;

    @disable this(this);

    /// A barrier of `parties` parties.
    this(uint parties) @safe nothrow @nogc
    {
        assert(parties > 0, "Barrier: a barrier needs at least one party");
        partiesLess1 = parties - 1;
    }

    /// The number of parties a generation needs.
    uint parties() const shared @safe nothrow @nogc => partiesLess1 + 1;

    /**
    Arrives and waits until the generation's `n`-th party arrives (SYB1);
    returns `true` to exactly one of them.
    */
    bool arriveAndWait() shared @safe nothrow @nogc => arrive(Deadline.never, false).leader;

    /**
    As `arriveAndWait`, by `deadline` or interruptibly: a timeout or a
    cancellation before the generation completes withdraws the arrival
    (SYB2).
    */
    Arrival arriveAndWaitUntil(MonoTime deadline, bool interruptible = false) shared @safe nothrow @nogc
        => arrive(deadline == MonoTime.max ? Deadline.never : Deadline.at(deadline), interruptible);

    // The same operations on an unshared barrier, such as a `__gshared` one.
    uint parties() const @safe nothrow @nogc => partiesLess1 + 1;
    bool arriveAndWait() @safe nothrow @nogc => sh.arriveAndWait();
    Arrival arriveAndWaitUntil(MonoTime deadline, bool interruptible = false) @safe nothrow @nogc
        => sh.arriveAndWaitUntil(deadline, interruptible);

    /// `arriveAndWaitUntil` with a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) Arrival arrive(Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        ulong cur = P.load!(Order.relaxed)(state);
        ulong next;
        bool completes;
        do
        {
            completes = arrivedOf(cur) == partiesLess1;
            next = completes ? (cur & ~arrivedMask) + oneGeneration : cur + 1;
        }
        // Arrivals release; the completing one also acquires every arrival
        // counted before it, continuing their release sequence (§13).
        while (!arriveCas(cur, next));
        const gen = generationOf(cur);
        if (completes)
        {
            if (partiesLess1 > 0)
                unparkFilter!P(keyOf(), Protocol.barrier,
                    (size_t parkToken) => parkToken == gen ? FilterOp.wake : FilterOp.skip,
                    (ref const LockedKey!P lk, UnparkResult res) => UnparkDecision(0));
            return Arrival(WaitStatus.ok, true);
        }
        return waitFor(gen, d, interruptible);
    }

    package(sparkles.base.sync) Arrival arrive(Deadline d, bool interruptible) @safe nothrow @nogc
        => sh.arrive(d, interruptible);

    private Arrival waitFor(uint gen, Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        const key = keyOf();
        while (true)
        {
            const r = park!P(key, ParkOptions(Protocol.barrier, parkToken: gen, deadline: d,
                    interruptible: observesCancellation!P(interruptible)),
                (ref const LockedKey!P lk) => generationOf(P.load!(Order.relaxed)(state)) == gen,
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    // Withdraw, unless the generation completed first (SYB2):
                    // the wait was then satisfied, and the park reports so
                    // under this lock, before any cancellation is settled (SYI2).
                    ulong cur = P.load!(Order.relaxed)(state);
                    while (true)
                    {
                        if (generationOf(cur) != gen)
                            return true;
                        if (P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur - 1))
                            return false;
                    }
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                // The validation's read was relaxed; this is the acquire (§13).
                if (generationOf(P.load!(Order.acquire)(state)) != gen)
                    return Arrival(WaitStatus.ok);
                continue;
            case ParkOutcome.unparked:
                // Woken by the completing arrival, or satisfied on removal
                // after it: this acquire continues the release sequence of
                // every arrival either way (§13).
                cast(void) P.load!(Order.acquire)(state);
                return Arrival(WaitStatus.ok);
            case ParkOutcome.timedOut:
            case ParkOutcome.cancelled:
                return Arrival(r.outcome == ParkOutcome.timedOut ? WaitStatus.timedOut : WaitStatus.cancelled);
            }
        }
    }

    /// An arrival's compare-and-swap; the model's seeded fault weakens it (oracle 1).
    private bool arriveCas(ref ulong expected, ulong desired) shared @safe nothrow @nogc
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.releaseRelaxed))
                return P.cas!(Order.relaxed, Order.relaxed)(state, expected, desired);
        return P.cas!(Order.acqRel, Order.relaxed)(state, expected, desired);
    }

    private size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    private ref shared(BarrierT) sh() return @trusted nothrow @nogc => *cast(shared(BarrierT)*) &this;
}

/// The barrier (primitives.md §11).
alias Barrier = BarrierT!NativePlatform;

static assert(!__traits(compiles, { Barrier a; Barrier b = a; }), "SYA4");
