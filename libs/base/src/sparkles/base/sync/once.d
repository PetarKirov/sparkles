/**
The one-time initializer (primitives.md §8).

`Once` is one byte: a state — incomplete, running, complete or poisoned — and
a parked bit (SYO1). `call` on a complete `Once` is one acquire load (SYO3).
An `init` that throws an `Exception` returns the `Once` to incomplete, so
another caller retries; one that throws an `Error` poisons it (SYO4, SYO5,
DS18).
*/
module sparkles.base.sync.once;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

private enum ubyte incomplete = 0, running = 1, complete = 2, poisoned = 3, stateMask = 3,
    parked = 4;

/// The one-time initializer for platform `P`.
struct OnceT(P)
{
    package(sparkles.base.sync) P.Atomic!ubyte state;

    @disable this(this);

    /**
    Runs `init` unless some caller's `init` has completed, and returns only
    after one has (SYO2), parking while another caller runs it.
    */
    void call(F)(scope F init) shared
    {
        if ((P.load!(Order.acquire)(state) & stateMask) == complete)
            return;
        cast(void) callSlow(init, Deadline.never, false);
    }

    /**
    As `call`, but waiting for another caller's `init` only until `deadline`,
    or interruptibly; a timeout or cancellation leaves that `init` running
    (SYO6). A caller that runs `init` itself runs it to completion.
    */
    WaitStatus callUntil(F)(scope F init, MonoTime deadline, bool interruptible = false) shared
    {
        if ((P.load!(Order.acquire)(state) & stateMask) == complete)
            return WaitStatus.ok;
        return callSlow(init, deadline == MonoTime.max ? Deadline.never : Deadline.at(deadline),
            interruptible);
    }

    void call(F)(scope F init) => sh.call(init);

    WaitStatus callUntil(F)(scope F init, MonoTime deadline, bool interruptible = false)
        => sh.callUntil(init, deadline, interruptible);

    /// Whether some caller's `init` has completed.
    bool isComplete() const shared @safe nothrow @nogc
        => (P.load!(Order.acquire)(state) & stateMask) == complete;

    bool isComplete() const @trusted nothrow @nogc => (*cast(const shared(OnceT)*) &this).isComplete;

    /// `callUntil` with a deadline in platform ticks (the model's virtual clock).
    package(sparkles.base.sync) WaitStatus callTicks(F)(scope F init, Deadline d, bool interruptible) shared
        => (P.load!(Order.acquire)(state) & stateMask) == complete ? WaitStatus.ok
            : callSlow(init, d, interruptible);

    package(sparkles.base.sync) WaitStatus callTicks(F)(scope F init, Deadline d, bool interruptible)
        => sh.callTicks(init, d, interruptible);

    private WaitStatus callSlow(F)(scope F init, Deadline d, bool interruptible) shared
    {
        const key = keyOf();
        while (true)
        {
            ubyte s = P.load!(Order.acquire)(state);
            switch (s & stateMask)
            {
            case complete:
                return WaitStatus.ok;
            case poisoned:
                assert(0, "Once: an earlier init threw an Error (SYO5)");
            case incomplete:
                if (!P.cas!(Order.acquire, Order.acquire)(state, s, cast(ubyte)((s & parked) | running)))
                    continue;
                runInit(init);
                return WaitStatus.ok;
            default:
                // Running: wait for that caller's init.
                const r = park!P(key, ParkOptions(Protocol.once, deadline: d,
                        interruptible: observesCancellation!P(interruptible)),
                    (ref const LockedKey!P lk) {
                        ubyte cur = P.load!(Order.relaxed)(state);
                        while (true)
                        {
                            if ((cur & stateMask) != running)
                                return false;
                            if ((cur & parked) || P.cas!(Order.relaxed, Order.relaxed)(state, cur,
                                    cast(ubyte)(cur | parked)))
                                return true;
                        }
                    });
                if (r.outcome == ParkOutcome.timedOut)
                    return WaitStatus.timedOut;
                if (r.outcome == ParkOutcome.cancelled)
                    return WaitStatus.cancelled;
            }
        }
    }

    private void runInit(F)(scope F init) shared
    {
        bool done, isError = true;
        scope (exit)
        {
            // The end of each attempt happens before the start of the next,
            // and completion before every return that observes it (§13).
            const next = done ? complete : isError ? poisoned : incomplete;
            const old = P.exchange!(Order.acqRel)(state, next);
            if (old & parked)
                unparkAll!P(keyOf(), Protocol.once,
                    (ref const LockedKey!P lk, UnparkResult r) => UnparkDecision(0));
        }
        static if (__traits(compiles, () nothrow { init(); }))
            init();
        else
        {
            try
                init();
            catch (Exception e)
            {
                // An Exception is recoverable: another caller retries (SYO4).
                isError = false;
                throw e;
            }
        }
        done = true;
    }

    private size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    private ref shared(OnceT) sh() return @trusted nothrow @nogc => *cast(shared(OnceT)*) &this;
}

/// The one-time initializer (primitives.md §8).
alias Once = OnceT!NativePlatform;

static assert(Once.sizeof == 1, "SYO1");
