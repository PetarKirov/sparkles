/**
Admission: a counted budget of units (in-flight operations, slots, bytes,
descriptors) that work acquires before it starts and releases when it ends
(SPEC §14.2).

One primitive for what event-horizon used to count three times by hand: the
loop's op-slot budget with its held-back share, the fork server's request
slots, and a bounded channel's capacity. A caller that may not wait asks with
`tryAcquire`; a fiber that may wait parks in `acquire` until enough units are
released, through the executor seam and the one-shot cancel discipline that
`Channel` uses (§8.4). The fileset driver and the schemes it serves share one
of these as their admission budget (filesets SPEC FSS6).

$(UL
    $(LI $(B Reserved units.) `reserve(n)` holds `n` units back: an ordinary
        acquisition never takes them, and a `reserved` one takes only them,
        so a holder of the reserve never finds the budget exhausted by
        others. The loop's held op slots are this.)
    $(LI $(B Starting in use.) `Admission(capacity, inUse)` may start with
        units already taken: a channel's item count starts full-of-nothing,
        with every unit in use until a put releases one.)
    $(LI $(B Closing.) `close` wakes every parked fiber. An acquisition that
        finds units available still succeeds, so items buffered before a
        close drain; one that would have to wait fails with `EPIPE`.)
)

Single-executor, like `Channel`: every fiber that parks here belongs to one
executor, and nothing here is thread-safe.
*/
module sparkles.event_horizon.admission;

import core.stdc.errno : ECANCELED, EPIPE;

import sparkles.event_horizon.capability : isFiberExecutor;
import sparkles.event_horizon.cause : FiberContext, Interrupt, interruptRequested;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/// A counted budget of units, with an optional reserved share.
struct Admission
{
    @disable this(this); // parked waiters hold its address

    /// A budget of `capacity` units, `inUse` of them already taken.
    this(uint capacity, uint inUse = 0) @safe pure nothrow @nogc
    in (inUse <= capacity)
    {
        _capacity = capacity;
        _inUse = inUse;
    }

    /// Every unit, reserved ones included.
    uint capacity() const @safe pure nothrow @nogc => _capacity;

    /// Units taken, reserved ones included.
    uint inUse() const @safe pure nothrow @nogc => _inUse + _reservedInUse;

    /// Units held back for reserved acquisitions, and how many are taken.
    uint reserved() const @safe pure nothrow @nogc => _reserved;
    /// ditto
    uint reservedInUse() const @safe pure nothrow @nogc => _reservedInUse;

    /// Units an ordinary acquisition may still take.
    uint available() const @safe pure nothrow @nogc
        => _capacity - _reserved - _inUse;

    /// Whether `close` ran.
    bool closed() const @safe pure nothrow @nogc => _closed;

    /// Fibers parked in `acquire`, for tests and diagnostics.
    uint parked() const @safe pure nothrow @nogc => _parked;

    /// Holds `n` units back for reserved acquisitions. Only while no
    /// reserved unit is taken, and only from units nobody holds. Units a
    /// smaller reserve gives back go to the parked fibers they satisfy, as
    /// a release's do.
    void reserve(uint n) @safe nothrow @nogc
    in (_reservedInUse == 0, "reserve while reserved units are taken")
    in (n <= _capacity - _inUse, "reserve more than the free units")
    {
        const shrinks = n < _reserved;
        _reserved = n;
        if (shrinks)
            wakeFitting();
    }

    /// Takes `n` units if they are free; never waits. A `reserved`
    /// acquisition takes reserved units only.
    bool tryAcquire(uint n = 1, bool reserved = false) @safe pure nothrow @nogc
    {
        if (reserved)
        {
            if (_reserved - _reservedInUse < n)
                return false;
            _reservedInUse += n;
            return true;
        }
        if (available < n)
            return false;
        _inUse += n;
        return true;
    }

    /// Gives back `n` units and hands them to the parked fibers they
    /// satisfy, in the order they parked.
    void release(uint n = 1, bool reserved = false) @safe nothrow @nogc
    in (reserved ? n <= _reservedInUse : n <= _inUse, "release of units never taken")
    {
        if (reserved)
            _reservedInUse -= n;
        else
            _inUse -= n;
        wakeFitting();
    }

    /**
    Takes `n` units, parking the calling fiber until they are free. A
    cancellation checkpoint: `ECANCELED` when the fiber is interrupted, and
    `EPIPE` when the budget is closed with too few units free. Ordinary
    units only; reserved ones are for callers that cannot wait.

    First come, first served: a request parks behind those already parked,
    even when the units it asks for are free, and a parked fiber is handed
    its units when it is woken, so nothing taken in between can leave it
    short.
    */
    IoResult!void acquire(X)(ref X exec, uint n = 1)
    if (isFiberExecutor!X)
    in (n <= _capacity - _reserved, "a request no release can ever satisfy")
    {
        if (interruptRequested(*exec.currentContext()))
            return interrupted();
        if (_waiters is null && tryAcquire(n))
            return ioOk();
        if (_closed)
            return ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit, "admission closed");
        return parkOn(exec, n);
    }

    /// Closes the budget (idempotent) and wakes every parked fiber.
    void close() @safe nothrow @nogc
    {
        if (_closed)
            return;
        _closed = true;
        while (_waiters !is null)
            wakeHead();
    }

private:
    /// One parked fiber; lives on the parked verb's stack frame.
    static struct Waiter
    {
        FiberContext* fiber;
        void function(void* execPtr, FiberContext* f) nothrow @nogc wakeFn;
        void* execPtr;
        uint units;
        Waiter* next;
        bool queued;
        bool granted; // popped with its units charged to it
    }

    IoResult!void interrupted() @safe pure nothrow @nogc
        => ioErr!void(ECANCELED, OpKind.none, IoErrorStage.submit, "admission interrupted");

    // Parks the calling fiber at the tail until it is handed its `n` units,
    // the budget is closed, or it is interrupted.
    IoResult!void parkOn(X)(ref X exec, uint n)
    {
        Waiter w;
        w.fiber = exec.currentContext();
        w.wakeFn = function(void* p, FiberContext* f) nothrow @nogc {
            (() @trusted => (cast(X*) p).wake(f))();
        };
        w.execPtr = (() @trusted => cast(void*) &exec)();
        w.units = n;
        w.queued = true;

        // FIFO append.
        auto tail = (() @trusted => &_waiters)();
        while (*tail !is null)
            tail = (() @trusted => &(*tail).next)();
        *tail = (() @trusted => &w)();
        ++_parked;

        // The one-shot cancel hook (§8.4, non-I/O park): the interrupt is
        // already latched; this only wakes the fiber to observe it.
        auto ctx = w.fiber;
        ctx.cancelFn = function(void* p, Interrupt) nothrow @nogc {
            auto self = (() @trusted => cast(Waiter*) p)();
            self.wakeFn(self.execPtr, self.fiber);
        };
        ctx.cancelCtx = (() @trusted => cast(void*) &w)();

        // Only a hand-over, `close` or the interrupt ends the park; any
        // other wake-up leaves the fiber queued where it was.
        do
            exec.park();
        while (w.queued && !interruptRequested(*ctx));

        ctx.cancelFn = null;
        ctx.cancelCtx = null;
        const wasHead = _waiters is (() @trusted => &w)();
        unlink(w);
        if (interruptRequested(*ctx))
        {
            // The interrupt comes first. Units handed over are given back,
            // and a head that leaves may unblock those behind it: either
            // way the wake-up passes on.
            if (w.granted)
                release(n);
            else if (wasHead)
                wakeFitting();
            return interrupted();
        }
        if (w.granted)
            return ioOk();
        // Woken by `close`: units already free are still taken.
        return tryAcquire(n) ? ioOk()
            : ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit, "admission closed");
    }

    // Removes a waiter still queued (a cancel-woken one); a woken one was
    // already popped.
    void unlink(ref Waiter w) @trusted nothrow @nogc
    {
        if (!w.queued)
            return;
        for (auto p = &_waiters; *p !is null; p = &(*p).next)
            if (*p is &w)
            {
                *p = w.next;
                break;
            }
        w.queued = false;
        --_parked;
    }

    void wakeHead() @trusted nothrow @nogc
    {
        auto w = _waiters;
        _waiters = w.next;
        w.queued = false;
        --_parked;
        w.wakeFn(w.execPtr, w.fiber);
    }

    // Hands the free units to waiters from the head while they cover them,
    // charging each its units before it is woken, so neither a `tryAcquire`
    // nor a fresh `acquire` can take them before it runs.
    void wakeFitting() @trusted nothrow @nogc
    {
        while (_waiters !is null && _waiters.units <= available)
        {
            _inUse += _waiters.units;
            _waiters.granted = true;
            wakeHead();
        }
    }

    uint _capacity;
    uint _inUse;
    uint _reserved;
    uint _reservedInUse;
    uint _parked;
    bool _closed;
    Waiter* _waiters;
}

///
@("admission.tryAcquire.reserved")
@safe nothrow @nogc unittest
{
    auto a = Admission(4);
    a.reserve(1);
    assert(a.tryAcquire() && a.tryAcquire() && a.tryAcquire());
    assert(!a.tryAcquire(), "the reserved unit is not for ordinary acquisitions");
    assert(a.tryAcquire(1, reserved: true));
    assert(!a.tryAcquire(1, reserved: true));
    assert(a.inUse == 4 && a.reservedInUse == 1);
    a.release(1, reserved: true);
    a.release();
    assert(a.inUse == 2 && a.available == 1);
    assert(!a.tryAcquire(2));
}

@("admission.startsInUse")
@safe nothrow @nogc unittest
{
    auto items = Admission(3, inUse: 3);
    assert(!items.tryAcquire());
    items.release();
    assert(items.tryAcquire());
}

version (unittest)
{
    import sparkles.event_horizon.capability : SpawnOptions;
    import sparkles.event_horizon.cause : InterruptKind, interruptFiber;
    import sparkles.event_horizon.testing : TestSched;
}

@("admission.acquire.parksUntilRelease")
@safe unittest
{
    TestSched sched;
    auto a = Admission(2);
    auto gate = Admission(1, inUse: 1); // closed until the opener releases it
    uint holding, peak, done, beforeOpen;
    sched.run(() {
        foreach (i; 0 .. 6)
            cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
                assert(!a.acquire(sched).hasError);
                if (++holding > peak)
                    peak = holding;
                assert(!gate.acquire(sched).hasError); // hold the unit a while
                gate.release();
                --holding;
                a.release();
                ++done;
            });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            beforeOpen = holding;
            assert(a.parked == 4);
            gate.release();
        });
    });
    assert(beforeOpen == 2, "the budget admits two");
    assert(peak == 2 && done == 6, "never more than the budget at once");
    assert(a.inUse == 0 && a.parked == 0);
}

@("admission.acquire.multiUnitFifo")
@safe unittest
{
    TestSched sched;
    auto a = Admission(4, inUse: 4);
    uint[] order;
    uint parkedAfterFirst;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            assert(!a.acquire(sched, 3).hasError);
            order ~= 3;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            assert(!a.acquire(sched, 1).hasError);
            order ~= 1;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            a.release(2); // the head wants 3: nobody is woken past it
            parkedAfterFirst = a.parked;
            a.release(2); // now the head's 3 and the 1 behind it fit
        });
    });
    assert(parkedAfterFirst == 2, "a later small request does not overtake the head");
    assert(order == [3, 1]);
}

@("admission.close.wakesIntoEPIPE")
@safe unittest
{
    TestSched sched;
    auto a = Admission(1, inUse: 1);
    int code;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            code = a.acquire(sched).error.code;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () { a.close(); });
    });
    assert(code == EPIPE);
    a.release();
    assert(a.tryAcquire(), "a closed budget still hands out free units");
}

@("admission.acquire.cancelledWakeePassesUnitOn")
@safe unittest
{
    TestSched sched;
    auto a = Admission(1, inUse: 1);
    int firstCode = -1;
    bool secondAcquired;
    sched.run(() {
        auto first = sched.spawnFiber(null, SpawnOptions.init, () {
            firstCode = a.acquire(sched).error.code;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            secondAcquired = !a.acquire(sched).hasError;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            assert(a.parked == 2);
            a.release(); // wakes the first, which has not run yet
            (() @trusted => interruptFiber(first, Interrupt(InterruptKind.cancelled)))();
        });
    });
    assert(firstCode == ECANCELED, "the interrupt check comes first");
    assert(secondAcquired, "the unit the cancelled fiber left goes to the next waiter");
    assert(a.inUse == 1 && a.parked == 0);
}

/// A woken fiber is handed its units: a caller that does not queue cannot
/// take them before it runs, so it never parks again and strands the
/// waiters behind it.
@("admission.acquire.wokenWaiterKeepsItsUnits")
@safe unittest
{
    TestSched sched;
    auto a = Admission(4, inUse: 4);
    bool got3, got1, stolen = true;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            got3 = !a.acquire(sched, 3).hasError;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            got1 = !a.acquire(sched, 1).hasError;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            a.release(3); // the head's three units are now its own
            stolen = a.tryAcquire();
            a.release(); // and the last one is the second waiter's
        });
    });
    assert(!stolen, "units handed to a woken fiber are not free");
    assert(got3 && got1 && a.parked == 0 && a.inUse == 4);
}

/// SPEC §14.2 Order: a fresh `acquire` parks behind the fibers already
/// parked, even when its units are free, so a large request at the head is
/// not starved by small ones arriving later.
@("admission.acquire.freshRequestQueues")
@safe unittest
{
    TestSched sched;
    auto a = Admission(4, inUse: 4);
    string[] order;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            assert(!a.acquire(sched, 3).hasError);
            order ~= "big";
            a.release(3);
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            a.release(2); // the head wants 3
            cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
                assert(!a.acquire(sched, 1).hasError);
                order ~= "small";
            });
            cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
                assert(a.parked == 2, "the small request queued behind the head");
                a.release(); // now the head fits
            });
        });
    });
    assert(order == ["big", "small"], order[0]);
    assert(a.parked == 0 && a.inUse == 2);
}

/// SPEC §14.2 Order: a cancelled waiter leaves the queue without
/// reordering it; the others are served in the order they parked.
@("admission.acquire.cancelKeepsOrder")
@safe unittest
{
    TestSched sched;
    auto a = Admission(1, inUse: 1);
    uint[] order;
    FiberContext*[4] f;
    // Runs `dg` after `hops` fibers have run in turn.
    void later(uint hops, void delegate() @safe dg) @safe
    {
        if (hops == 0)
            return dg();
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () { later(hops - 1, dg); });
    }
    // A function per waiter, so each closure has an `id` of its own.
    void waiter(uint id) @safe
    {
        f[id] = sched.spawnFiber(null, SpawnOptions.init, () {
            if (!a.acquire(sched).hasError)
                order ~= id;
        });
    }
    sched.run(() {
        foreach (uint i; 0 .. 4)
            waiter(i);
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            (() @trusted => interruptFiber(f[1], Interrupt(InterruptKind.cancelled)))();
            a.release(); // the head's
            later(2, () {
                a.release();
                later(2, () { a.release(); });
            });
        });
    });
    assert(order == [0, 2, 3]);
    assert(a.parked == 0);
}

/// A reserve that shrinks gives its units to the fibers parked for them.
@("admission.reserve.shrinkWakes")
@safe unittest
{
    TestSched sched;
    auto a = Admission(3, inUse: 1);
    a.reserve(2); // nothing left for an ordinary acquisition
    bool acquired;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            acquired = !a.acquire(sched).hasError;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            assert(a.parked == 1);
            a.reserve(0);
        });
    });
    assert(acquired && a.parked == 0 && a.inUse == 2);
}
