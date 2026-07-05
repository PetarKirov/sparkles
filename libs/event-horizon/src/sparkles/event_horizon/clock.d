/**
The clock capability (SPEC §10.3): the `isClock` concept and `TestClock`,
the canonical handler-swap witness — any function generic over its clock
runs unmodified under virtual time. The live ring-backed clock joins the
loop-side `live` module in M9.

$(B Effects-side module): no ring imports; fibers park through the
`isWaker` seam.
*/
module sparkles.event_horizon.clock;

import core.time : Duration, MonoTime, msecs;

import sparkles.event_horizon.capability : isCapability, isWaker;
import sparkles.event_horizon.errors : IoResult, ioOk;

/// The clock capability concept — the exact expressions callers write.
enum bool isClock(C) = isCapability!C && C.capName == "clock"
    && __traits(compiles, (ref C c) {
        MonoTime t = c.now();
        IoResult!void r = c.sleep(1.msecs);
    });

/**
Virtual, deterministic time. `sleep` parks the calling task through the
waker seam; `advance` wakes due sleepers in deadline order (FIFO among
equals). The determinism contract (ZIO's TestClock lesson): let running
fibers reach quiescence — parked on `sleep` — before advancing, or the wake
set is racy; `testing.advanceAndSettle` packages that discipline.

(A test double: GC-backed waiter storage is fine here.)
*/
struct TestClock(W)
if (isWaker!W)
{
    enum string capName = "clock";

    /// Constructs over the executor's park/wake view.
    this(W waker) @safe nothrow @nogc
    {
        _waker = waker;
    }

    /// Current virtual time (starts at `MonoTime.zero`).
    MonoTime now() const @safe pure nothrow @nogc => _now;

    /// Parks the calling task until virtual time reaches `now + d`.
    IoResult!void sleep(Duration d) scope @trusted nothrow
    {
        if (d <= Duration.zero)
            return ioOk();
        auto h = _waker.prepare();
        insertSleeper(Sleeper(_now + d, h));
        _waker.park(h);
        return ioOk();
    }

    /// Advances virtual time by `d`, waking sleepers whose deadline is due,
    /// in deadline order.
    void advance(Duration d) scope @trusted nothrow
    {
        _now += d;
        while (_sleepers.length > 0 && _sleepers[0].deadline <= _now)
        {
            auto h = _sleepers[0].handle;
            _sleepers = _sleepers[1 .. $];
            _waker.wake(h);
        }
    }

    /// Advances exactly to the next pending deadline; `false` if none.
    bool advanceToNext() scope @trusted nothrow
    {
        if (_sleepers.length == 0)
            return false;
        advance(_sleepers[0].deadline - _now);
        return true;
    }

    /// Parked sleepers (a quiescence probe for test drivers).
    size_t pendingSleepers() const @safe pure nothrow @nogc
        => _sleepers.length;

private:
    static struct Sleeper
    {
        MonoTime deadline;
        W.Handle handle;
    }

    void insertSleeper(Sleeper s) scope @trusted nothrow
    {
        // Insertion sort: deadline order, FIFO among equals.
        size_t i = _sleepers.length;
        while (i > 0 && _sleepers[i - 1].deadline > s.deadline)
            --i;
        _sleepers = _sleepers[0 .. i] ~ s ~ _sleepers[i .. $];
    }

    MonoTime _now = MonoTime.zero;
    W _waker;
    Sleeper[] _sleepers;
}
