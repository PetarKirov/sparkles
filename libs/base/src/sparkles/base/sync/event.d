/**
Manual-reset and auto-reset events (primitives.md §10).

Each is one byte: a set bit and a parked bit (SYE1). A manual-reset event
stays set until `reset` and releases every waiter (SYE2); an auto-reset
event hands its signal to one waiter, or keeps it for the next `wait`
(SYE3). An auto-reset waiter that `set` selected owns the signal even if its
deadline passes or a cancellation arrives before it returns (SYE4).
*/
module sparkles.base.sync.event;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

private enum ubyte signalled = 1, parked = 2;

/// Whether an event, once set, releases everyone or one waiter.
enum EventKind : ubyte
{
    manualReset,
    autoReset,
}

/// An event of kind `kind` for platform `P`.
struct EventT(P, EventKind kind)
{
    package(sparkles.base.sync) P.Atomic!ubyte state;

    @disable this(this);

    /**
    Sets the event (SYE2, SYE3): a manual-reset event wakes every waiter and
    stays set; an auto-reset event wakes one waiter, or with none parked
    stays set for the next `wait`. Setting a set event does nothing more.
    */
    void set() shared @safe nothrow @nogc
    {
        static if (kind == EventKind.manualReset)
        {
            // The release half of §13's edge; waiters acquire the set bit.
            ubyte cur = P.load!(Order.relaxed)(state);
            while (true)
            {
                if (cur & signalled)
                    return;
                if (cur & parked)
                    break;
                if (releaseCas(cur, cast(ubyte)(cur | signalled)))
                    return;
            }
            // With waiters parked, the bit is set under the bucket lock that
            // wakes them: a waiter that parks after a `reset` is then never
            // released by a `set` begun before it (SYE2).
            unparkAll!P(keyOf(), Protocol.event,
                (ref const LockedKey!P lk, UnparkResult res) {
                    ubyte s = P.load!(Order.relaxed)(state);
                    while (!releaseCas(s, cast(ubyte)((s | signalled) & ~parked))) {}
                    return UnparkDecision(0);
                });
        }
        else
        {
            ubyte cur = P.load!(Order.relaxed)(state);
            while (true)
            {
                if (cur & signalled)
                    return;
                if (cur & parked)
                    break;
                if (releaseCas(cur, cast(ubyte)(cur | signalled)))
                    return;
            }
            unparkOne!P(keyOf(), Protocol.event,
                (ref const LockedKey!P lk, UnparkResult res) {
                    if (res.unparked)
                    {
                        // The signal goes to the woken waiter: the event
                        // stays unset, and the park's return is the edge.
                        if (!res.haveMore)
                            clear(parked);
                        return UnparkDecision(tokenHandoff);
                    }
                    // A stale parked bit (SYP15): keep the signal instead.
                    ubyte s = P.load!(Order.relaxed)(state);
                    while (!releaseCas(s, cast(ubyte)((s | signalled) & ~parked))) {}
                    return UnparkDecision(0);
                });
        }
    }

    /// Clears a set event. An auto-reset event's signal is discarded.
    void reset() shared @safe nothrow @nogc
    {
        ubyte cur = P.load!(Order.relaxed)(state);
        while ((cur & signalled) && !P.cas!(Order.relaxed, Order.relaxed)(state, cur, cast(ubyte)(cur & ~signalled))) {}
    }

    /// Whether the event is set now: a snapshot.
    bool isSet() const shared @safe nothrow @nogc => (P.load!(Order.acquire)(state) & signalled) != 0;

    /// Waits until the event is set (SYE2, SYE3); an auto-reset wait consumes it.
    void wait() shared @safe nothrow @nogc
    {
        if (!tryWait())
            cast(void) waitSlow(Deadline.never, false);
    }

    /**
    As `wait`, by `deadline` or interruptibly: `ok`, or `timedOut` or
    `cancelled` having consumed nothing (SYE4).
    */
    WaitStatus waitUntil(MonoTime deadline, bool interruptible = false) shared @safe nothrow @nogc
        => tryWait() ? WaitStatus.ok
            : waitSlow(deadline == MonoTime.max ? Deadline.never : Deadline.at(deadline), interruptible);

    /// Returns whether the event is set, consuming an auto-reset signal; never parks.
    bool tryWait() shared @safe nothrow @nogc
    {
        static if (kind == EventKind.manualReset)
            return (P.load!(Order.acquire)(state) & signalled) != 0;
        else
        {
            ubyte cur = P.load!(Order.relaxed)(state);
            while (cur & signalled)
                if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cast(ubyte)(cur & ~signalled)))
                    return true;
            return false;
        }
    }

    // The same operations on an unshared event, such as a `__gshared` one.
    void set() @safe nothrow @nogc => sh.set();
    void reset() @safe nothrow @nogc => sh.reset();
    bool isSet() const @trusted nothrow @nogc => (*cast(const shared(EventT)*) &this).isSet;
    void wait() @safe nothrow @nogc => sh.wait();
    WaitStatus waitUntil(MonoTime deadline, bool interruptible = false) @safe nothrow @nogc
        => sh.waitUntil(deadline, interruptible);
    bool tryWait() @safe nothrow @nogc => sh.tryWait();

    /// `waitUntil` with a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) WaitStatus waitTicks(Deadline d, bool interruptible) shared @safe nothrow @nogc
        => tryWait() ? WaitStatus.ok : waitSlow(d, interruptible);

    package(sparkles.base.sync) WaitStatus waitTicks(Deadline d, bool interruptible) @safe nothrow @nogc
        => sh.waitTicks(d, interruptible);

    private WaitStatus waitSlow(Deadline d, bool interruptible) shared @safe nothrow @nogc
    {
        const key = keyOf();
        while (true)
        {
            bool done;
            const r = park!P(key, ParkOptions(Protocol.event, deadline: d,
                    interruptible: observesCancellation!P(interruptible)),
                (ref const LockedKey!P lk) {
                    ubyte cur = P.load!(Order.relaxed)(state);
                    while (true)
                    {
                        if (cur & signalled)
                        {
                            static if (kind == EventKind.autoReset)
                                if (!P.cas!(Order.acquire, Order.relaxed)(state, cur, cast(ubyte)(cur & ~signalled)))
                                    continue;
                            done = true;
                            return false;
                        }
                        if ((cur & parked) || P.cas!(Order.relaxed, Order.relaxed)(state, cur,
                                cast(ubyte)(cur | parked)))
                            return true;
                    }
                },
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    if (!haveMore)
                        clear(parked);
                    return false;
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                if (done)
                {
                    // The validation read the set bit relaxed, under the
                    // bucket lock; this load is the acquire half (§13).
                    static if (kind == EventKind.manualReset)
                        cast(void) P.load!(Order.acquire)(state);
                    return WaitStatus.ok;
                }
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

    /// A release compare-and-swap; the model's seeded fault weakens it (oracle 1).
    private bool releaseCas(ref ubyte expected, ubyte desired) shared @safe nothrow @nogc
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.releaseRelaxed))
                return P.cas!(Order.relaxed, Order.relaxed)(state, expected, desired);
        return P.cas!(Order.release, Order.relaxed)(state, expected, desired);
    }

    private void clear(ubyte bits) shared @safe nothrow @nogc
    {
        ubyte cur = P.load!(Order.relaxed)(state);
        while (!P.cas!(Order.relaxed, Order.relaxed)(state, cur, cast(ubyte)(cur & ~bits))) {}
    }

    private size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    private ref shared(EventT) sh() return @trusted nothrow @nogc => *cast(shared(EventT)*) &this;
}

/// An event that stays set until `reset` (SYE2).
alias ManualResetEventT(P) = EventT!(P, EventKind.manualReset);
/// An event whose signal releases one waiter (SYE3).
alias AutoResetEventT(P) = EventT!(P, EventKind.autoReset);

/// A manual-reset event (primitives.md §10).
alias ManualResetEvent = ManualResetEventT!NativePlatform;
/// An auto-reset event (primitives.md §10).
alias AutoResetEvent = AutoResetEventT!NativePlatform;

static assert(ManualResetEvent.sizeof == 1 && AutoResetEvent.sizeof == 1, "SYE1");
static assert(!__traits(compiles, { ManualResetEvent a; ManualResetEvent b = a; }), "SYA4");
