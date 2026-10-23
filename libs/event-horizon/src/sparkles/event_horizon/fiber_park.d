/**
The fiber parker ([fiber-parker.md](../../../../../docs/specs/event-horizon/fiber-parker.md)):
a scheduler's implementation of `sparkles.base.sync`'s parker seam, so that a
fiber waiting on a `Mutex`, `Condition`, `Semaphore` or any other base.sync
primitive suspends instead of blocking its loop's thread.

This is the inbox path (EFP12–EFP15), which every backend has. A sleep
suspends the fiber in its scheduler; a wake from the fiber's own worker
enqueues it, and a wake from any other thread pushes it onto the owner's
wake inbox and calls the owner's `Waker`. A deadline is a scheduler alarm and
a cancellation the fiber's one-shot cancel function, each a resumption of the
sleep's generation.

$(B The park word.) Each task's 32-bit park word holds a generation (the
upper 29 bits) and a state: sleeping, or the reason the sleep resumed.
`prepare` begins a generation, sleeping (EFP3). Every resumption — a
delivered wake, the deadline, a cancellation — is one compare-and-swap from
sleeping in that generation to its reason; only the winner makes the fiber
runnable, so a delivery that names an old generation has no effect.

The parking lot, not the parker, decides a park's outcome (base.sync SYP4,
SYP5): the reason a sleep returns is tentative. A waiter whose own deadline
or cancellation won its sleep may find its record already dequeued by an
unparker. If that wake is committed, the park ends unparked and the fiber
runs on; if not, the lot sleeps the waiter again, without a new `prepare`,
until the delivery. The delivery cannot tell the two apart, so it never
assumes either: on a word its waiter resolved itself, it records `woken` and
makes nothing runnable — the fiber is already running. A sleep entered again
returns at once on `woken`, and otherwise puts the word back to sleeping in
the same generation, which the delivery then resolves like any other.
*/
module sparkles.event_horizon.fiber_park;

version (Posix) version = EhFiberPark;
version (Windows) version = EhFiberPark;
version (EhFiberPark)  :

import core.atomic : atomicLoad, atomicOp, atomicStore, cas, MemoryOrder;
import core.stdc.errno : EAGAIN, ETIME;
import core.time : convClockFreq, MonoTime, nsecs;

import sparkles.base.sync.parker : Parker, ParkerVtbl, SleepResult, WaitRecord, WakeHandle;
import sparkles.base.sync.platform : NativePlatform;
import sparkles.base.sync.seam : Deadline, WakeCount;

import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.cause : Interrupt, interruptRequested;
import sparkles.event_horizon.errors : IoErrorStage, ioError, OpKind;
import sparkles.event_horizon.op : Completion, FutexDeadline, KernelTimespec, OpFutexWait,
    OpFutexWake;
import sparkles.event_horizon.sched : Alarm, FiberTask, Sched;

private alias P = NativePlatform;

/// The park word's state, in its low bits; the generation is above them.
private enum ParkState : uint
{
    idle = 0,      /// never parked
    sleeping = 1,  /// asleep in the word's generation
    woken = 2,     /// a delivered wake resumed it
    timedOut = 3,  /// its deadline resumed it
    cancelled = 4, /// its cancellation resumed it
}

private enum uint stateBits = 3;
private enum uint stateMask = (1u << stateBits) - 1;

private uint wordOf(uint generation, ParkState st) @safe pure nothrow @nogc
    => (generation << stateBits) | st;

private uint generationOf(uint word) @safe pure nothrow @nogc => word >> stateBits;

private ParkState stateOf(uint word) @safe pure nothrow @nogc
    => cast(ParkState)(word & stateMask);

/**
A task's fiber-parker state (EFP2): its parking-lot record, its park word,
its wake-inbox link, and the alarm that carries a sleep's deadline. It lives
in the task, in the scheduler's slab, and needs no allocation.
*/
package struct FiberParkState
{
    WaitRecord!P record;
    shared uint word;
    /// Wake-inbox link; only the winning resumption pushes the task, so it is
    /// in the inbox at most once (EFP13).
    shared(FiberTask) nextWake;
    /// The deadline of the current sleep (EFP14).
    Alarm deadline;
    /// The generation the armed deadline names.
    uint deadlineGeneration;

    /// The ring path's sleep (EFP7, EFP8): queued for the submission point
    /// while `ringPending`, linked through `ringPrev` and `ringNext`.
    FiberTask ringPrev, ringNext;
    /// ditto
    bool ringPending;
    /// The sleep's wait is written: only its terminal completion resumes
    /// the fiber, and a winning resumption wakes the park word instead (EFP9).
    shared bool waitWritten;
    /// The queued or written sleep's deadline, interruptibility and
    /// generation.
    Deadline ringDeadline;
    /// ditto
    bool ringInterruptible;
    /// ditto
    uint ringGeneration;
}

/// The parker to install while `t` runs (EFP1).
package Parker!P fiberParker(FiberTask t) @trusted nothrow @nogc
    => Parker!P(&fiberParkerVtbl, cast(void*) t);

/// The fiber parker's operations.
private static immutable ParkerVtbl!P fiberParkerVtbl = ParkerVtbl!P(
    &fpRecord, &fpPrepare, &fpSleep, &fpCommitWake, &fpBucketWait, &fpRelax,
    &fpSettle, &fpProtected,
    // `woken` means a delivery won, not that the record was committed: the
    // lot rechecks under the bucket lock.
    exactWake: false,
    // Delivery touches the scheduler's slab and inbox, never the record.
    deliveryTouchesRecord: false,
);

private FiberTask taskOf(void* ctx) @trusted nothrow @nogc => cast(FiberTask) ctx;

/// Resolves generation `generation`'s sleep with `reason`; whether this
/// resumption won (EFP3).
private bool resolve(FiberTask t, uint generation, ParkState reason) @trusted nothrow @nogc
{
    return cas(&t.park.word, wordOf(generation, ParkState.sleeping), wordOf(generation, reason));
}

private WaitRecord!P* fpRecord(void* ctx) @trusted nothrow @nogc => &taskOf(ctx).park.record;

private void fpPrepare(void* ctx, WaitRecord!P* rec) @trusted nothrow @nogc
{
    auto t = taskOf(ctx);
    const generation = generationOf(atomicLoad!(MemoryOrder.raw)(t.park.word)) + 1;
    atomicStore!(MemoryOrder.rel)(t.park.word, wordOf(generation, ParkState.sleeping));
}

private SleepResult fpSleep(void* ctx, WaitRecord!P* rec, Deadline d, bool interruptible)
    @trusted nothrow @nogc
{
    auto t = taskOf(ctx);
    auto s = t.owner;
    assert(Sched.tryCurrent() is t, "a fiber parker sleeps only its own fiber");

    uint word = atomicLoad!(MemoryOrder.acq)(t.park.word);
    const generation = generationOf(word);
    // A sleep again after its own deadline or cancellation won: the lot is
    // waiting for a wake already dequeued. Its delivery may have come, and
    // left `woken`; if not, the generation sleeps on for it.
    while (stateOf(word) == ParkState.timedOut || stateOf(word) == ParkState.cancelled)
    {
        if (cas(&t.park.word, word, wordOf(generation, ParkState.sleeping)))
            word = wordOf(generation, ParkState.sleeping);
        else
            word = atomicLoad!(MemoryOrder.acq)(t.park.word);
    }
    if (stateOf(word) == ParkState.woken)
        return SleepResult.woken;

    if (stateOf(word) == ParkState.sleeping)
    {
        // Sticky cancellation (EFP16): a latched interrupt ends every
        // interruptible sleep at once, and the latch stays.
        if (interruptible && interruptRequested(t.ectx)
            && resolve(t, generation, ParkState.cancelled))
            return SleepResult.cancelled;
        if (d.passed(P.now()) && resolve(t, generation, ParkState.timedOut))
            return SleepResult.timedOut;

        if (s.ringPark)
        {
            t.park.ringDeadline = d;
            t.park.ringInterruptible = interruptible;
        }
        else if (!d.isNever)
        {
            t.park.deadlineGeneration = generation;
            s.armCallbackAlarm(t.park.deadline, monoTimeOf(d), &onDeadline, ctx);
        }
        if (interruptible)
        {
            t.ectx.cancelFn = &onCancel;
            t.ectx.cancelCtx = ctx;
        }
    }
    // On the ring path every sleep goes through the submission point, even
    // one another thread has already resolved: that thread saw no written
    // wait, so the submission point is what resumes the fiber (EFP8).
    if (s.ringPark)
    {
        t.park.ringGeneration = generation;
        s.queueRingSleep(t);
    }
    // Asleep, or already resumed by another thread whose push the drain
    // will deliver: either way exactly one enqueue resumes this fiber.
    s.noteLotSleep(true);
    s.park();
    s.noteLotSleep(false);
    // A winner on this thread resumes a sleep the submission point has not
    // written yet.
    s.unqueueRingSleep(t);

    // Neither the deadline nor the cancellation may act after the sleep
    // returns (EFP5).
    s.disarmAlarm(t.park.deadline);
    t.park.deadline.reset();
    if (t.ectx.cancelFn is &onCancel)
    {
        t.ectx.cancelFn = null;
        t.ectx.cancelCtx = null;
    }

    final switch (stateOf(atomicLoad!(MemoryOrder.acq)(t.park.word)))
    {
    case ParkState.woken:
        return SleepResult.woken;
    case ParkState.timedOut:
        return SleepResult.timedOut;
    case ParkState.cancelled:
        return SleepResult.cancelled;
    case ParkState.idle, ParkState.sleeping:
        assert(0, "a fiber parker sleep resumed without a winning resumption");
    }
}

/// `d` as the alarm's `MonoTime`.
private MonoTime monoTimeOf(Deadline d) @safe nothrow @nogc
{
    const now = MonoTime.currTime;
    const remaining = d.ticks - now.ticks;
    if (remaining <= 0)
        return now;
    return now + nsecs(convClockFreq(remaining, MonoTime.ticksPerSecond, 1_000_000_000L));
}

/// The sleep's deadline expired: a timeout resumption of its generation.
private void onDeadline(void* ctx) nothrow @nogc
{
    auto t = taskOf(ctx);
    if (resolve(t, t.park.deadlineGeneration, ParkState.timedOut))
        t.owner.resumeParked(t);
}

/// The fiber was interrupted during an interruptible sleep (EFP14): a
/// cancellation resumption. `interruptFiber` has latched the interrupt.
private void onCancel(void* ctx, Interrupt) nothrow @nogc
{
    auto t = taskOf(ctx);
    const word = atomicLoad!(MemoryOrder.acq)(t.park.word);
    if (!resolve(t, generationOf(word), ParkState.cancelled))
        return;
    // A written ring wait ends only through its completion (EFP10's direct
    // interruption); otherwise this thread resumes the fiber.
    if (t.owner.ringPark && atomicLoad(t.park.waitWritten))
        cast(void) wakeParkWord(t.owner, t, counted: false);
    else
        t.owner.resumeParkedOnce(t);
}

private WakeHandle fpCommitWake(void* ctx, WaitRecord!P* rec) @trusted nothrow @nogc
{
    auto t = taskOf(ctx);
    // The word stays as it is: whether the waiter sleeps again for this
    // wake is decided later, under its own relock (see the module comment).
    const generation = generationOf(atomicLoad!(MemoryOrder.acq)(t.park.word));
    atomicOp!"+="(t.owner._pendingDeliveries, 1);
    return WakeHandle(&deliver, cast(size_t) t.owner,
        (cast(size_t) t.slabIndex << 32) | generation);
}

/**
Delivers a committed wake from any thread (EFP4, EFP12). On a sleeping word
of the named generation it resolves the sleep as woken and, if that won,
makes the task runnable on its owner — directly from a fiber of the owner,
through the wake inbox from anywhere else, calling the owner's `Waker` only
when the push found the inbox empty. On a word the waiter's own deadline or
cancellation resolved, it records the wake and makes nothing runnable (see
the module comment). The delivery is complete once it no longer touches the
owner's storage.
*/
private void deliver(size_t a, size_t b) @trusted nothrow @nogc
{
    auto s = cast(Sched*) a;
    auto t = s.taskAt(b >> 32);
    if (recordWake(t, cast(uint) b))
    {
        auto current = Sched.tryCurrent();
        if (s.ringPark)
        {
            // The ring path (EFP9): a written wait is woken in the kernel; an
            // unwritten one is resumed here on the owner, and anywhere else
            // by the owner's submission point.
            if (atomicLoad(t.park.waitWritten))
            {
                if (wakeParkWord(s, t, counted: true))
                    return; // its completion finishes the delivery
            }
            else if (current !is null && current.owner is s)
                s.resumeParkedOnce(t);
        }
        else if (current !is null && current.owner is s)
            s.resumeParked(t);
        else if (wakeInboxPush(s, t))
            s.waker.wake();
    }
    atomicOp!"-="(s._pendingDeliveries, 1);
}

/// Records a committed wake for generation `generation`; whether it resumed
/// a sleeping fiber, which the caller must then make runnable.
private bool recordWake(FiberTask t, uint generation) @trusted nothrow @nogc
{
    for (uint word = atomicLoad!(MemoryOrder.acq)(t.park.word);;)
    {
        if (generationOf(word) != generation)
            return false;
        final switch (stateOf(word))
        {
        case ParkState.sleeping:
            if (cas(&t.park.word, word, wordOf(generation, ParkState.woken)))
                return true;
            break;
        case ParkState.timedOut, ParkState.cancelled:
            // Resolved by the waiter itself, which is running: keep the
            // wake for a sleep entered again, enqueue nothing.
            if (cas(&t.park.word, word, wordOf(generation, ParkState.woken)))
                return false;
            break;
        case ParkState.idle, ParkState.woken:
            return false;
        }
        word = atomicLoad!(MemoryOrder.acq)(t.park.word);
    }
}

/// Pushes `t` onto `s`'s wake inbox from any thread; whether the inbox was
/// empty, so that only the first push of a drain interval wakes the owner.
package bool wakeInboxPush(Sched* s, FiberTask t) @trusted nothrow @nogc
{
    for (;;)
    {
        auto old = atomicLoad(s._wakeInbox);
        t.park.nextWake = old;
        if (cas(&s._wakeInbox, old, cast(shared(FiberTask)) t))
            return old is null;
    }
}

/// A contended bucket: yield to the tail of the ready queue and retry; not
/// a cancellation checkpoint (EFP15). The bucket's holder runs only queue
/// edits, so the yields last only while it is preempted.
private void fpBucketWait(void* ctx, ref P.Atomic!uint word, uint expected) @trusted nothrow @nogc
{
    auto t = taskOf(ctx);
    static if (ringOps)
        if (t.owner.ringPark)
            return ringBucketWait(t, word, expected);
    t.owner.yieldNow();
}

/// One step of a spin (EFP19): pauses for the first steps, then a yield.
private void fpRelax(void* ctx, uint step) @trusted nothrow @nogc
{
    if (step < 3)
    {
        foreach (_; 0 .. 2u << step)
            P.pause();
    }
    else
        taskOf(ctx).owner.yieldNow();
}

/// Cancellation stays latched on the fiber (EFP16), so a cancelled park
/// consumes nothing.
private void fpSettle(void* ctx, WaitRecord!P* rec) @safe nothrow @nogc
{
}

/// Whether the fiber runs inside `protect` (EFP18); a shield does not mask.
private bool fpProtected(void* ctx) @trusted nothrow @nogc => taskOf(ctx).ectx.protectDepth > 0;

// ── the ring path (EFP7–EFP9, EFP11) ────────────────────────────────────────

/// Whether the default backend lowers the ring futex operations.
private enum bool ringOps = canSubmitOp!(DefaultBackend, OpFutexWait);

/**
The submission point's half of a ring sleep (EFP8): writes its wait, or,
when the sleep was resolved since it queued — or its fiber's interrupt is
latched, or its deadline has passed — resumes it without an operation.
Whether the fiber became runnable.

Writing first marks the wait written and then reads the word, both
sequentially consistent, against a delivery's swap and its read of the
mark: either the delivery sees the mark and wakes the word, which a wait the
kernel has not yet queued then finds changed, or this read sees the swap.
*/
package bool writeRingSleep(FiberTask t) @trusted nothrow @nogc
{
    static if (!ringOps)
        assert(0, "a ring sleep where the backend has no ring futex operations");
    else
    {
        auto s = t.owner;
        const g = t.park.ringGeneration;
        atomicStore(t.park.waitWritten, true);
        bool resumed = atomicLoad(t.park.word) != wordOf(g, ParkState.sleeping);
        if (!resumed && t.park.ringInterruptible && interruptRequested(t.ectx))
        {
            cast(void) resolve(t, g, ParkState.cancelled);
            resumed = true;
        }
        if (!resumed && t.park.ringDeadline.passed(P.now()))
        {
            cast(void) resolve(t, g, ParkState.timedOut);
            resumed = true;
        }
        if (resumed)
        {
            // Whichever resumption won, the word has left sleeping; a winner
            // on this thread may have enqueued the fiber already.
            atomicStore(t.park.waitWritten, false);
            s.resumeParkedOnce(t);
            return true;
        }
        submitRingWait(t);
        return false;
    }
}

static if (ringOps)
{
    /// Writes `t`'s wait on its park word, on its held op slot (EFP7, EFP22).
    private void submitRingWait(FiberTask t) @trusted nothrow @nogc
    {
        t.owner.noteRingWait(true);
        cast(void) t.owner.loop.submitHeld(OpFutexWait(cast(shared(uint)*) &t.park.word,
            wordOf(t.park.ringGeneration, ParkState.sleeping),
            deadline: futexDeadlineOf(t.park.ringDeadline)), &onRingWait, cast(void*) t);
    }

    /// A base.sync deadline as the linked timeout's: an instant on
    /// `CLOCK_MONOTONIC`, the clock `MonoTime` reads.
    private FutexDeadline futexDeadlineOf(Deadline d) @safe pure nothrow @nogc
    {
        if (d.isNever)
            return FutexDeadline.init;
        const ns = convClockFreq(d.ticks, MonoTime.ticksPerSecond, 1_000_000_000L);
        return FutexDeadline(KernelTimespec(ns / 1_000_000_000L, ns % 1_000_000_000L),
            absolute: true, armed: true);
    }

    /**
    A ring sleep's wait reached its terminal completion (EFP7). If a
    resumption has won, it resumes the fiber with that reason; otherwise the
    linked timeout's expiry is a timeout resumption, and anything else a
    stray wake — the kernel matches wakes by address, so a wake meant for an
    earlier generation can end this wait — after which the wait is written
    again.
    */
    private void onRingWait(void* ctx, ref Completion done) nothrow @nogc
    {
        auto t = taskOf(ctx);
        const g = t.park.ringGeneration;
        t.owner.noteRingWait(false);
        if (atomicLoad(t.park.word) == wordOf(g, ParkState.sleeping))
        {
            if (done.res == -ETIME)
                cast(void) resolve(t, g, ParkState.timedOut);
            else if (done.res >= 0 || done.res == -EAGAIN)
            {
                submitRingWait(t);
                return;
            }
            else
                t.owner.loop.fatal(ioError(-done.res, OpKind.futexWait,
                    IoErrorStage.completion, "a fiber parker's ring wait failed"));
        }
        atomicStore(t.park.waitWritten, false);
        t.owner.resumeParked(t);
    }

    /// A ring wake of another worker's park word completed: that delivery
    /// no longer touches its owner (EFP4).
    private void onRingWake(void* ctx, ref Completion) nothrow @nogc
    {
        atomicOp!"-="((cast(Sched*) ctx)._pendingDeliveries, 1);
    }

    /// A contended bucket on the ring path (EFP11): waits in the kernel on
    /// the bucket word, which base.sync's unlock wakes; not a cancellation
    /// checkpoint.
    private void ringBucketWait(FiberTask t, ref shared uint word, uint expected) @trusted nothrow @nogc
    {
        auto s = t.owner;
        s.noteRingWait(true);
        cast(void) s.loop.submitHeld(OpFutexWait(&word, expected), &onBucketWait, cast(void*) t);
        s.park();
    }

    private void onBucketWait(void* ctx, ref Completion) nothrow @nogc
    {
        auto t = taskOf(ctx);
        t.owner.noteRingWait(false);
        t.owner.resumeParked(t);
    }
}

/**
Wakes `t`'s written wait after a winning resumption (EFP9): from a fiber
whose scheduler has a ring, with an `IORING_OP_FUTEX_WAKE` on that ring;
otherwise, or when that ring has no slot, with one `futex` call. Whether
the wake went to a ring, whose completion then finishes the delivery (see
`onRingWake`); `counted` says the wake is a delivery's.
*/
private bool wakeParkWord(Sched* owner, FiberTask t, bool counted) @trusted nothrow @nogc
{
    static if (!ringOps)
        assert(0, "a ring wake where the backend has no ring futex operations");
    else
    {
        auto current = Sched.tryCurrent();
        if (counted && current !is null && current.owner.ringPark)
        {
            auto h = current.owner.loop.submit(OpFutexWake(cast(shared(uint)*) &t.park.word, 1),
                &onRingWake, cast(void*) owner);
            if (h.hasValue)
                return true;
        }
        P.seamWake(t.park.word, WakeCount.one);
        return false;
    }
}

// ── white-box tests of the park word's protocol ─────────────────────────────

version (unittest)
{
    /// Runs `body` on a fiber of a fresh scheduler, handing it the task.
    private void onTask(scope void delegate(ref Sched s, FiberTask t) @system body) @system
    {
        import sparkles.event_horizon.sched : FiberPark, SchedOptions, schedOrSkip;

        // The protocol is the same on both paths; each runs every scenario.
        foreach (path; [FiberPark.ring, FiberPark.inbox])
        {
            Sched s;
            schedOrSkip(s, SchedOptions(fiberPark: path));
            auto r = s.run(() { body(s, Sched.tryCurrent()); });
            assert(!r.hasError);
            s.destroy();
        }
    }

    /// Delivers `h` from a thread the scheduler does not know.
    private void deliverFromAnotherThread(WakeHandle h) @system
    {
        import core.thread.osthread : Thread;

        auto th = new Thread({ h.deliver(h.a, h.b); });
        th.start();
        th.join();
    }

    /// Takes the owner's wake inbox, so that a stray push fails the test's
    /// assertion instead of resuming a finished fiber; whether it held any.
    private bool takeWakeInbox(ref Sched s) @system
    {
        import core.atomic : atomicExchange;

        return atomicExchange(&s._wakeInbox, cast(shared(FiberTask)) null) !is null;
    }

    /// Begins a park of `t`, as the lot does under the bucket lock.
    private uint beginPark(FiberTask t) @system
    {
        fpPrepare(cast(void*) t, &t.park.record);
        return generationOf(atomicLoad(t.park.word));
    }
}

@("fiberPark.deliver.afterTheOwnDeadlineWonEnqueuesNothing")
@system
unittest
{
    // The deadline won the sleep, and the lot then found the record dequeued
    // and committed: the park ends unparked, and the fiber runs on. The
    // committed wake's delivery must not make the fiber runnable again —
    // it would resume at whatever it parks on next.
    onTask((ref s, t) {
        const g = beginPark(t);
        assert(resolve(t, g, ParkState.timedOut));
        deliverFromAnotherThread(fpCommitWake(cast(void*) t, &t.park.record));
        assert(!takeWakeInbox(s), "a resolved sleep was woken again");
        assert(atomicLoad(t.park.word) == wordOf(g, ParkState.woken));
        assert(atomicLoad(s._pendingDeliveries) == 0);
    });
}

@("fiberPark.sleep.againAfterTheDeliveryReturnsWoken")
@system
unittest
{
    // The cancellation won, the record was dequeued but not yet committed,
    // and the delivery landed before the lot slept the waiter again: that
    // sleep returns the wake without parking.
    onTask((ref s, t) {
        const g = beginPark(t);
        assert(resolve(t, g, ParkState.cancelled));
        deliverFromAnotherThread(fpCommitWake(cast(void*) t, &t.park.record));
        const r = fpSleep(cast(void*) t, &t.park.record, Deadline.never, false);
        assert(r == SleepResult.woken);
        assert(!takeWakeInbox(s));
    });
}

@("fiberPark.sleep.againBeforeTheDeliveryWaitsForIt")
@system
unittest
{
    import core.thread.osthread : Thread;
    import core.time : MonoTime, msecs, seconds;

    // The same race, with the delivery after the waiter slept again: the
    // sleep parks and the delivery resumes it, once.
    onTask((ref s, t) {
        const g = beginPark(t);
        assert(resolve(t, g, ParkState.timedOut));
        auto h = fpCommitWake(cast(void*) t, &t.park.record);
        auto th = new Thread({
            // Bounded: should the sleep never park, the delivery still
            // comes, and the assertions below fail instead of the join hanging.
            const until = MonoTime.currTime + 2.seconds;
            while (atomicLoad(t.park.word) != wordOf(g, ParkState.sleeping)
                && MonoTime.currTime < until)
                Thread.sleep(1.msecs);
            h.deliver(h.a, h.b);
        });
        th.start();
        // Bounded beyond the thread's wait: a lost delivery times out instead of hanging.
        const r = fpSleep(cast(void*) t, &t.park.record,
            Deadline.at(MonoTime.currTime + 5.seconds), false);
        th.join();
        assert(r == SleepResult.woken);
        assert(atomicLoad(t.park.word) == wordOf(g, ParkState.woken));
    });
}

@("fiberPark.deliver.staleGenerationIsIgnored")
@system
unittest
{
    // EFP3: a wake committed for one park and delivered after the next has
    // begun does not resume the next.
    onTask((ref s, t) {
        const g = beginPark(t);
        auto h = fpCommitWake(cast(void*) t, &t.park.record);
        assert(resolve(t, g, ParkState.timedOut));
        const next = beginPark(t);
        assert(next == g + 1);
        deliverFromAnotherThread(h);
        assert(atomicLoad(t.park.word) == wordOf(next, ParkState.sleeping));
        assert(!takeWakeInbox(s));
        assert(resolve(t, next, ParkState.timedOut));
    });
}

@("fiberPark.deliver.anAliasedGenerationNeitherOwnsNorLoses")
@system
unittest
{
    import core.time : seconds;
    import sparkles.base.sync : Semaphore, WaitStatus;
    import sparkles.event_horizon.sched : schedOrSkip;

    // EFP3: once the generation wraps, a stale wake can name the current
    // sleep. It resumes the fiber, but the lot finds the record still queued
    // and parks it again: the stale wake takes no permit, and the real
    // release still reaches the fiber.
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

    Semaphore sem;
    FiberTask waiter;
    WaitStatus st = WaitStatus.cancelled;
    bool returned;
    auto r = s.run(() {
        assert(!s.spawn(() {
            waiter = Sched.tryCurrent();
            st = sem.acquireUntil(MonoTime.currTime + 2.seconds);
            returned = true;
        }).hasError);
        while (s.lotSleepers == 0)
            s.yieldNow();
        const g = generationOf(atomicLoad(waiter.park.word));
        atomicOp!"+="(s._pendingDeliveries, 1);
        deliverFromAnotherThread(WakeHandle(&deliver, cast(size_t) &s,
            (cast(size_t) waiter.slabIndex << 32) | g));
        // The wake resumes the waiter at the next drain; the lot then
        // prepares the next generation and parks it again.
        const giveUp = MonoTime.currTime + 1.seconds;
        while (generationOf(atomicLoad(waiter.park.word)) == g && MonoTime.currTime < giveUp)
            s.yieldNow();
        assert(generationOf(atomicLoad(waiter.park.word)) == g + 1, "the lot parked it again");
        assert(!returned, "a stale wake ended the park");
        assert(s.lotSleepers == 1);
        sem.release();
        while (!returned)
            s.yieldNow();
    });
    assert(!r.hasError);
    assert(st == WaitStatus.ok);
    assert(sem.available == 0);
}

@("fiberPark.relax.pausesThenYields")
@system
unittest
{
    import sparkles.event_horizon.sched : schedOrSkip;

    // EFP19: the first steps of a spin stay on the fiber; later ones yield
    // to the ready queue, where a sibling runs.
    Sched s;
    schedOrSkip(s);
    scope (exit) s.destroy();

    uint siblingTurns;
    bool done;
    uint[4] seen;
    auto r = s.run(() {
        assert(!s.spawn(() {
            while (!done)
            {
                ++siblingTurns;
                s.yieldNow();
            }
        }).hasError);
        s.yieldNow(); // let the sibling start
        auto ctx = cast(void*) Sched.tryCurrent();
        foreach (uint step; 0 .. 4)
        {
            const before = siblingTurns;
            fpRelax(ctx, step);
            seen[step] = siblingTurns - before;
        }
        done = true;
    });
    assert(!r.hasError);
    assert(seen[0 .. 3] == [0, 0, 0], "the first steps only pause");
    assert(seen[3] == 1, "a later step yields once");
}

@("fiberPark.deliver.outlivesTheFiberAndHoldsOffDestroy")
@system
unittest
{
    import core.thread.osthread : Thread;
    import core.time : msecs;
    import sparkles.event_horizon.sched : schedOrSkip;

    // EFP2, EFP4: a delivery committed while the fiber ran may land after
    // the fiber has returned. The scheduler's storage outlives it: destroy
    // waits for the delivery to complete.
    Sched s;
    schedOrSkip(s);

    WakeHandle h;
    auto r = s.run(() {
        auto t = Sched.tryCurrent();
        const g = beginPark(t);
        assert(resolve(t, g, ParkState.timedOut));
        h = fpCommitWake(cast(void*) t, &t.park.record);
    });
    assert(!r.hasError);

    shared long deliveredAt;
    auto th = new Thread({
        Thread.sleep(30.msecs);
        h.deliver(h.a, h.b);
        atomicStore(deliveredAt, MonoTime.currTime.ticks);
    });
    th.start();
    s.destroy();
    const destroyedAt = MonoTime.currTime.ticks;
    th.join();
    assert(atomicLoad(deliveredAt) != 0 && atomicLoad(deliveredAt) <= destroyedAt,
        "destroy returned before the delivery completed");
}
