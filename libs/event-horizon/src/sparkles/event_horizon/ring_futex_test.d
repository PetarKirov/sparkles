/**
Tests of the ring futex operations (`OpFutexWait`, `OpFutexWake`,
`OpFutexWaitv`) and of the linked timeout a deadline adds (SPEC §5.6,
fiber-parker.md EFP7, EFP22). Only a backend that lowers them compiles the
scenarios, and a kernel without them (below Linux 6.7) skips.
*/
module sparkles.event_horizon.ring_futex_test;

version (unittest):
version (linux):

import core.stdc.errno : EAGAIN, ECANCELED, ETIME;
import core.time : Duration, msecs, seconds;

import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.errors : IoErrorStage, OpKind, skipReason;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.event_horizon.op;
import sparkles.test_runner.skip : skipTest;

static if (canSubmitOp!(DefaultBackend, OpFutexWait)):

/// What a test's callback saw.
private struct Seen
{
    int calls;
    int res;
}

private void record(void* ctx, ref Completion done) nothrow @nogc
{
    auto seen = cast(Seen*) ctx;
    ++seen.calls;
    seen.res = done.res;
}

/// Creates a loop whose kernel has the futex operations, or skips.
private void createOrSkip(ref DefaultLoop loop, LoopConfig cfg = LoopConfig()) @safe nothrow @nogc
{
    auto r = DefaultLoop.create(loop, cfg);
    if (r.hasError)
    {
        assert(r.error.stage == IoErrorStage.setup || r.error.stage == IoErrorStage.probe);
        skipTest(skipReason(r.error));
    }
    if (!loop.caps().futexOps)
        skipTest("the futex operations need Linux 6.7");
}

/// Drives `loop` until nothing is in flight, failing past `limit`.
private void drain(ref DefaultLoop loop, Duration limit = 5.seconds)
{
    const start = loop.now();
    while (loop.inFlight > 0)
    {
        assert(loop.now() - start < limit, "the ring did not drain");
        assert(!loop.runOnce(100.msecs).hasError);
    }
}

/// A deadline `d` from now, relative.
private FutexDeadline after(Duration d) @safe pure nothrow @nogc
{
    long secs, nsecs;
    d.split!("seconds", "nsecs")(secs, nsecs);
    return FutexDeadline(KernelTimespec(secs, nsecs), absolute: false, armed: true);
}

@("ringFutex.wait.aWordThatAlreadyDiffersFailsFast")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint word = 1;
    Seen seen;
    assert(!loop.submit(OpFutexWait(&word, 0), &record, &seen).hasError);
    drain(loop);
    assert(seen.calls == 1 && seen.res == -EAGAIN);
}

@("ringFutex.wake.anInRingWakeEndsAnInRingWait")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint word;
    Seen wait, wake;
    assert(!loop.submit(OpFutexWait(&word, 0), &record, &wait).hasError);
    // The ring issues its entries in order, so the wait is queued first.
    assert(!loop.submit(OpFutexWake(&word, 1), &record, &wake).hasError);
    drain(loop);
    assert(wait.calls == 1 && wait.res == 0);
    assert(wake.calls == 1 && wake.res == 1, "one waiter woken");
}

@("ringFutex.wait.aThreadsFutexCallEndsIt")
@system
unittest
{
    import core.atomic : atomicStore;
    import core.thread : Thread;
    import sparkles.base.sync.seam : wake, WakeCount;

    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint word;
    Seen seen;
    assert(!loop.submit(OpFutexWait(&word, 0), &record, &seen).hasError);
    assert(!loop.runOnce(Duration.zero).hasError); // the wait reaches the kernel

    auto t = new Thread({
        atomicStore(word, 1);
        wake(word, WakeCount.one); // a plain futex(FUTEX_WAKE_PRIVATE)
    });
    t.start();
    drain(loop);
    t.join();
    assert(seen.calls == 1 && seen.res == 0, "woken, not failed fast");
}

@("ringFutex.deadline.expiryTimesOut")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint word;
    Seen seen;
    const start = loop.now();
    assert(!loop.submit(OpFutexWait(&word, 0, deadline: after(20.msecs)), &record, &seen)
        .hasError);
    drain(loop);
    const elapsed = loop.now() - start;
    assert(seen.calls == 1 && seen.res == -ETIME, "the deadline, not a cancellation");
    assert(elapsed >= 20.msecs && elapsed < 2.seconds);
    assert(loop.inFlight == 0);
}

@("ringFutex.deadline.absoluteIsOnTheMonotonicClock")
@system
unittest
{
    import core.sys.linux.time : CLOCK_MONOTONIC, clock_gettime, timespec;

    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    auto at = KernelTimespec(now.tv_sec, now.tv_nsec + 20_000_000);
    if (at.tv_nsec >= 1_000_000_000)
    {
        ++at.tv_sec;
        at.tv_nsec -= 1_000_000_000;
    }

    shared uint word;
    Seen seen;
    const start = loop.now();
    assert(!loop.submit(OpFutexWait(&word, 0,
        deadline: FutexDeadline(at, absolute: true, armed: true)), &record, &seen).hasError);
    drain(loop);
    const elapsed = loop.now() - start;
    assert(seen.res == -ETIME);
    assert(elapsed >= 15.msecs && elapsed < 2.seconds, "an instant, not a 20 s delay");
}

@("ringFutex.deadline.aWakeBeforeExpiryWins")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint word;
    Seen wait, wake;
    const start = loop.now();
    assert(!loop.submit(OpFutexWait(&word, 0, deadline: after(5.seconds)), &record, &wait)
        .hasError);
    assert(!loop.submit(OpFutexWake(&word, 1), &record, &wake).hasError);
    drain(loop);
    assert(wait.calls == 1 && wait.res == 0, "woken once, its timeout cancelled silently");
    assert(loop.now() - start < 2.seconds);
}

@("ringFutex.cancel.anExplicitCancellationReportsCancelled")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint word;
    Seen seen;
    auto h = loop.submit(OpFutexWait(&word, 0, deadline: after(5.seconds)), &record, &seen);
    assert(h.hasValue);
    assert(!loop.runOnce(Duration.zero).hasError);
    assert(!loop.cancel(h.value).hasError);
    drain(loop);
    assert(seen.calls == 1 && seen.res == -ECANCELED,
        "the cancellation, though the linked timeout ended too");
}

@("ringFutex.waitv.reportsTheWokenWord")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint first, second;
    FutexWaitvEntry[2] entries = [
        FutexWaitvEntry(0, cast(ulong) &first, futexWaitvFlags),
        FutexWaitvEntry(0, cast(ulong) &second, futexWaitvFlags),
    ];
    Seen wait, wake;
    assert(!loop.submit(OpFutexWaitv(entries.ptr, 2), &record, &wait).hasError);
    assert(!loop.submit(OpFutexWake(&second, 1), &record, &wake).hasError);
    drain(loop);
    assert(wait.calls == 1 && wait.res == 1, "the second word's index");
    assert(wake.res == 1);
}

@("ringFutex.waitv.deadlineTimesOut")
@system
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);
    scope (exit) loop.destroy();

    shared uint first, second;
    FutexWaitvEntry[2] entries = [
        FutexWaitvEntry(0, cast(ulong) &first, futexWaitvFlags),
        FutexWaitvEntry(0, cast(ulong) &second, futexWaitvFlags),
    ];
    Seen seen;
    assert(!loop.submit(OpFutexWaitv(entries.ptr, 2, after(20.msecs)), &record, &seen)
        .hasError);
    drain(loop);
    assert(seen.calls == 1 && seen.res == -ETIME);
}

@("ringFutex.deadline.needsTwoEntriesAndTheyGoTogether")
@system
unittest
{
    // With one of two entries taken, a timed wait does not fit: the loop
    // flushes and queues the wait and its timeout as one link, never the
    // wait alone (EFP22).
    LoopConfig cfg;
    cfg.backend.sqEntries = 2;
    DefaultLoop loop;
    createOrSkip(loop, cfg);
    scope (exit) loop.destroy();

    Seen nop, seen;
    shared uint word;
    assert(!loop.submit(OpNop(), &record, &nop).hasError);
    assert(!loop.submit(OpFutexWait(&word, 0, deadline: after(20.msecs)), &record, &seen)
        .hasError);
    drain(loop);
    assert(nop.calls == 1);
    assert(seen.calls == 1 && seen.res == -ETIME, "the timeout was linked to the wait");
}

@("ringFutex.probe.hiddenOpsWithdrawTheKinds")
@system
unittest
{
    LoopConfig cfg;
    cfg.backend.hiddenOps = 1UL << OpKind.futexWaitv;
    DefaultLoop loop;
    createOrSkip(loop, cfg);
    scope (exit) loop.destroy();

    assert(!loop.caps().supports(OpKind.futexWaitv));
    assert(loop.caps().supports(OpKind.futexWake));
}
