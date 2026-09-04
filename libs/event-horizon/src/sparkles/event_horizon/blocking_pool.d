/**
The scheduler-integrated pool for blocking host calls (SPEC §13.8, PLAN M19
item 4): the one place a fiber may run something the completion backend
cannot express — a `waitpid` fallback, a cgroup walk, a `ppoll` on a cgroup
event fd — without ever blocking the scheduler thread.

Submission parks the calling fiber; a persistent worker thread performs the
call; completion re-enters the owning scheduler through its own
blocking-completion inbox plus `Waker` (`sched.d`), and the drain wakes the
caller. The job lives on the caller's parked frame for its whole life, so a
pending job implies a parked (live) fiber — the ordinary lifetime proof.

Two lanes:

$(UL
    $(LI the $(B public lane) (`run`): bounded by `queueCapacity`; saturation
        returns `EAGAIN` immediately — a caller never parks on admission;)
    $(LI the $(B termination-critical lane) (`runMandatory`, package-only):
        reap and teardown work that must never be refused. An intrusive
        frame-resident list, so admission needs no queue slot; serviced by one
        $(B reserved worker) that takes nothing else, with ordinary workers
        helping only while the public queue is empty (accepted public jobs
        cannot be starved by replenished cleanup work). The guarantee is
        eventual FIFO service under finite, terminating jobs — no numeric
        bound; the aggregate size is the sum of the live fiber slabs of every
        bound scheduler.)
)

Cancellation: the entry checkpoint is the $(B only) cancellation point. Once
a job is accepted the caller waits under `protect` until the worker's
completion is delivered — a started blocking call cannot be cancelled, and a
latched interrupt is delivered at the caller's next checkpoint afterwards.

Shutdown refuses new jobs (`EPIPE`), lets workers finish and $(B post) every
accepted job exactly once, then joins them. Delivery to the parked callers
still requires their schedulers to tick — which a scheduler with a parked
`run` caller necessarily does.
*/
module sparkles.event_horizon.blocking_pool;

// The shared pool's bootstrap guard is a statically initialized OS mutex;
// only the POSIX form exists today — a Windows port needs SRWLOCK_INIT.
version (Posix)
{
}
else
    static assert(false, "blocking_pool: no static OS mutex for this platform yet");

version (Posix)  :

import core.atomic : atomicLoad;
import core.stdc.errno : EAGAIN, ECANCELED, EINVAL, EPIPE;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread.osthread : Thread;
import core.thread.types : ThreadID;

import sparkles.base.hw_caps : hwParallelism;
import sparkles.event_horizon.cause : interruptRequested;
import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.sched : BlockingJob, Sched, postBlockingCompletion;
import sparkles.event_horizon.scope_ : protect;

public import sparkles.event_horizon.sched : BlockingCall;

/// A running pool. Non-copyable; owns its worker threads.
struct BlockingPool
{
    @disable this(this);

    /**
    Starts `workers` ordinary workers (0 = `min(4, max(2, hwParallelism/8))`)
    plus the one reserved termination-critical worker, and a public queue
    of `queueCapacity` entries. All-or-nothing: if a thread cannot be
    started, the already-started ones are stopped and joined and the error
    is returned, so a later attempt can retry cleanly.
    */
    static IoResult!void create(out BlockingPool pool, uint workers = 0,
        uint queueCapacity = 64, bool daemon = false) @trusted
    {
        if (queueCapacity == 0)
            return ioErr!void(EINVAL, OpKind.none, IoErrorStage.setup,
                "queueCapacity must be positive");
        if (workers == 0)
        {
            const hw = hwParallelism() / 8;
            workers = hw < 2 ? 2 : (hw > 4 ? 4 : hw);
        }
        pool._mutex = new Mutex;
        pool._publicCond = new Condition(pool._mutex);
        pool._mandatoryCond = new Condition(pool._mutex);
        pool._public = new BlockingJob*[](queueCapacity);

        // Worker 0 is the reserved lane-only worker.
        foreach (id; 0 .. workers + 1)
        {
            Thread t;
            try
            {
                t = new Thread(id == 0 ? &pool.reservedWorker : &pool.ordinaryWorker);
                t.isDaemon = daemon;
                t.start();
            }
            catch (Throwable)
            {
                pool.stopAndJoin();
                return ioErr!void(EAGAIN, OpKind.none, IoErrorStage.setup,
                    "blocking pool worker thread could not be started");
            }
            pool._threads ~= t;
        }
        return ioOk();
    }

    /**
    Prepares scheduler `s` for completion delivery: arms its Sched-owned
    inbox waker (consuming one op slot the first time). Idempotent per
    scheduler; the pool keeps no scheduler pointer outside an accepted job.
    Supervision calls this $(B before) spawning a child so that a later slab
    saturation cannot block a mandatory reap.
    */
    package IoResult!void prepare(ref Sched s) @trusted
        => s.ensureBlockingInboxWaker();

    /// Runs `call(context)` on a worker; parks the caller until it completes.
    /// `EAGAIN` when the public queue is full, `EPIPE` after `shutdown`,
    /// `ECANCELED` when the caller was already interrupted (entry only).
    IoResult!void run(ref Sched s, BlockingCall call, void* context) @trusted
        => submit(s, call, context, false);

    /// The termination-critical lane: never `EAGAIN` (intrusive, frame-
    /// resident admission), reserved-worker serviced. Reap/teardown only.
    package IoResult!void runMandatory(ref Sched s, BlockingCall call,
        void* context) @trusted
        => submit(s, call, context, true);

    /// Refuses new jobs, finishes and posts every accepted one, joins the
    /// workers. Bound schedulers must keep ticking to deliver those posts.
    IoResult!void shutdown() @trusted
    {
        stopAndJoin();
        return ioOk();
    }

    /// `true` once `shutdown` ran.
    bool closed() const @safe pure nothrow @nogc => _closing;

private:
    IoResult!void submit(ref Sched s, BlockingCall call, void* context,
        bool mandatory) @trusted
    {
        auto waiter = s.currentContext();
        // The entry checkpoint: the ONLY cancellation point (SPEC §13.8).
        if (interruptRequested(*waiter))
            return ioErr!void(ECANCELED, OpKind.none, IoErrorStage.submit,
                "blocking call not started: caller interrupted");
        auto prepared = prepare(s);
        if (prepared.hasError)
            return prepared;

        BlockingJob job;
        job.call = call;
        job.context = context;
        job.owner = &s;
        job.waiter = waiter;
        job.waker = s.blockingWaker;

        {
            _mutex.lock_nothrow();
            scope (exit) _mutex.unlock_nothrow();
            if (_closing)
                return ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit,
                    "blocking pool shut down");
            if (mandatory)
            {
                job.next = null;
                if (_mandatoryTail is null)
                    _mandatoryHead = &job;
                else
                    _mandatoryTail.next = &job;
                _mandatoryTail = &job;
                ++_mandatoryCount;
                // The reserved worker first; an idle ordinary worker helps
                // only while the public queue is empty (checked on wake).
                _mandatoryCond.notify();
                if (_idleOrdinary > 0)
                    _publicCond.notify();
            }
            else
            {
                if (_publicCount == _public.length)
                    return ioErr!void(EAGAIN, OpKind.none, IoErrorStage.submit,
                        "blocking pool queue full");
                _public[(_publicHead + _publicCount) % _public.length] = &job;
                ++_publicCount;
                if (_idleOrdinary > 0)
                    _publicCond.notify();
            }
        }

        // Accepted: uncancellable until the completion is delivered. The
        // drain sets `done` before waking, so a spurious wake re-parks.
        protect!(() {
            while (!atomicLoad(job.done))
                s.park();
            return 0;
        })(s);
        return ioOk();
    }

    /// Pops the oldest public job; null when empty. Caller holds the lock.
    BlockingJob* popPublic() @safe nothrow @nogc
    {
        if (_publicCount == 0)
            return null;
        auto job = _public[_publicHead];
        _public[_publicHead] = null;
        _publicHead = (_publicHead + 1) % _public.length;
        --_publicCount;
        return job;
    }

    /// Pops the oldest mandatory job; null when empty. Caller holds the lock.
    BlockingJob* popMandatory() @safe nothrow @nogc
    {
        auto job = _mandatoryHead;
        if (job is null)
            return null;
        _mandatoryHead = job.next;
        if (_mandatoryHead is null)
            _mandatoryTail = null;
        job.next = null;
        --_mandatoryCount;
        return job;
    }

    static void execute(BlockingJob* job) nothrow
    {
        job.call(job.context);
        postBlockingCompletion(job);
    }

    /// Ordinary worker: public lane first; mandatory only while the public
    /// queue is empty — the fairness rule.
    void ordinaryWorker()
    {
        for (;;)
        {
            BlockingJob* job;
            {
                _mutex.lock_nothrow();
                scope (exit) _mutex.unlock_nothrow();
                for (;;)
                {
                    job = popPublic();
                    if (job is null)
                        job = popMandatory();
                    if (job !is null)
                        break;
                    if (_closing)
                        return;
                    ++_idleOrdinary;
                    _publicCond.wait();
                    --_idleOrdinary;
                }
            }
            execute(job);
        }
    }

    /// The reserved worker: the termination-critical lane only, so a slow
    /// public job can never delay a reap behind it.
    void reservedWorker()
    {
        for (;;)
        {
            BlockingJob* job;
            {
                _mutex.lock_nothrow();
                scope (exit) _mutex.unlock_nothrow();
                for (;;)
                {
                    job = popMandatory();
                    if (job !is null)
                        break;
                    if (_closing)
                        return;
                    _mandatoryCond.wait();
                }
            }
            execute(job);
        }
    }

    void stopAndJoin() @trusted
    {
        {
            _mutex.lock_nothrow();
            scope (exit) _mutex.unlock_nothrow();
            _closing = true;
            _publicCond.notifyAll();
            _mandatoryCond.notifyAll();
        }
        foreach (t; _threads)
            if (t !is null)
                try
                    t.join();
                catch (Throwable)
                {
                }
        _threads = null;
    }

    Mutex _mutex;
    Condition _publicCond;
    Condition _mandatoryCond;
    BlockingJob*[] _public;
    uint _publicHead;
    uint _publicCount;
    BlockingJob* _mandatoryHead;
    BlockingJob* _mandatoryTail;
    uint _mandatoryCount;
    uint _idleOrdinary;
    bool _closing;
    Thread[] _threads;
}

// ── the process-wide shared pool ────────────────────────────────────────────

import core.sys.posix.pthread : PTHREAD_MUTEX_INITIALIZER, pthread_mutex_lock,
    pthread_mutex_t, pthread_mutex_unlock;

/// The bootstrap guard: a statically initialized OS mutex has no
/// construction race and no runtime destructor — the one thing a lazily
/// created singleton's guard must be. Every access takes it (no fast path).
private __gshared pthread_mutex_t gSharedGuard = PTHREAD_MUTEX_INITIALIZER;
private __gshared BlockingPool* gShared;

/**
The process-wide pool supervision uses (daemon workers; never shut down —
the holder is intentionally leaked, and a `__gshared` reference keeps it
rooted). Creation failure is returned to the caller and $(B not) memoized:
the next caller retries under the same guard, and only a completed holder
is ever published.
*/
package IoResult!(BlockingPool*) sharedBlockingPool() @trusted
{
    pthread_mutex_lock(&gSharedGuard);
    scope (exit) pthread_mutex_unlock(&gSharedGuard);
    if (gShared !is null)
        return ioOk(gShared);
    auto holder = new BlockingPool;
    auto created = BlockingPool.create(*holder, 0, 64, true);
    if (created.hasError)
        return ioErr!(BlockingPool*)(created.error);
    gShared = holder;
    return ioOk(holder);
}

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.time : msecs;

    import sparkles.event_horizon.sched : schedOrSkip;

    private struct SleepJob
    {
        int ms;
        int ran;
        shared bool started;
        ThreadID thread;
    }

    private void sleepCall(void* p) nothrow
    {
        import core.atomic : atomicStore;

        auto j = cast(SleepJob*) p;
        atomicStore(j.started, true);
        try
            Thread.sleep(j.ms.msecs);
        catch (Throwable)
        {
        }
        ++j.ran;
        try
            j.thread = Thread.getThis().id;
        catch (Throwable)
        {
        }
    }
}

version (unittest)
{
    /// Spawns a fiber that submits `job` on the public lane and records
    /// the outcome; a separate frame per call so each fiber owns its job.
    private void spawnPublicRunner(ref Sched s, BlockingPool* pool, SleepJob* job,
        int* errnoOut = null)
    {
        auto sp = &s;
        assert(!s.spawn(() {
            auto r = pool.run(*sp, &sleepCall, job);
            if (errnoOut !is null)
                *errnoOut = r.hasError ? r.error.errnoValue : 0;
        }).hasError);
    }

    /// Parks the calling fiber on in-ring sleeps until `flag` is set.
    private void waitUntil(ref Sched s, scope bool delegate() flag)
    {
        import sparkles.event_horizon.io : sleep;

        while (!flag())
            cast(void) sleep(s, 1.msecs);
    }
}

@("blockingPool.run.roundTripsThroughAWorker")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 1, 4).hasError);
    scope (exit) cast(void) pool.shutdown();

    auto r = s.run(() {
        SleepJob job = {ms: 1};
        assert(!pool.run(s, &sleepCall, &job).hasError);
        assert(job.ran == 1, "the call ran exactly once");
        assert(job.thread != Thread.getThis().id, "…on a worker, not the loop thread");
    });
    assert(!r.hasError);
}

@("blockingPool.saturation.publicEagainButMandatoryAdmits")
@system
unittest
{
    import core.atomic : atomicLoad;

    Sched s;
    schedOrSkip(s);
    // One ordinary worker, a one-entry public queue: `busy` occupies the
    // worker, `queued` fills the queue, so the third public job is refused
    // with EAGAIN — while the termination-critical lane still admits and
    // completes on the reserved worker.
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 1, 1).hasError);
    scope (exit) cast(void) pool.shutdown();

    int thirdErrno = -1;
    bool mandatoryDone;
    auto r = s.run(() {
        SleepJob busy = {ms: 80};
        SleepJob queued = {ms: 1};
        SleepJob third = {ms: 1};
        spawnPublicRunner(s, &pool, &busy);
        waitUntil(s, () => atomicLoad(busy.started));
        spawnPublicRunner(s, &pool, &queued);
        waitUntil(s, () => pool._publicCount == 1);
        spawnPublicRunner(s, &pool, &third, &thirdErrno);
        waitUntil(s, () => thirdErrno != -1);
        SleepJob reap = {ms: 1};
        assert(!pool.runMandatory(s, &sleepCall, &reap).hasError);
        mandatoryDone = reap.ran == 1;
    });
    assert(!r.hasError);
    assert(thirdErrno == EAGAIN, "a full public queue refuses immediately");
    assert(mandatoryDone, "the mandatory lane never refuses");
}

@("blockingPool.cancellation.entryCheckpointOnlyThenUncancellable")
@system
unittest
{
    import sparkles.event_horizon.cause : FiberContext, Interrupt, InterruptKind,
        interruptFiber;

    Sched s;
    schedOrSkip(s);
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 1, 4).hasError);
    scope (exit) cast(void) pool.shutdown();

    FiberContext* sleeper;
    bool refusedAtEntry, completedDespiteInterrupt, latchedAfter;
    auto r = s.run(() {
        assert(!s.spawn(() {
            sleeper = s.currentContext();
            SleepJob job = {ms: 30};
            // Accepted before the interrupt lands: runs to completion, and
            // the latch is delivered only afterwards.
            auto ran = pool.run(s, &sleepCall, &job);
            completedDespiteInterrupt = !ran.hasError && job.ran == 1;
            latchedAfter = interruptRequested(*s.currentContext());
            // Now interrupted: the next submission is refused at entry.
            SleepJob never = {ms: 1};
            auto refused = pool.run(s, &sleepCall, &never);
            refusedAtEntry = refused.hasError
                && refused.error.errnoValue == ECANCELED && never.ran == 0;
        }).hasError);
        assert(!s.spawn(() {
            s.yieldNow();
            interruptFiber(sleeper, Interrupt(InterruptKind.cancelled));
        }).hasError);
    });
    assert(!r.hasError);
    assert(completedDespiteInterrupt && latchedAfter && refusedAtEntry);
}

@("blockingPool.shutdown.postsEveryAcceptedJobExactlyOnceThenRefuses")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 2, 8).hasError);

    SleepJob[6] jobs;
    int[6] errnos = -1;
    bool refusedAfter;
    auto r = s.run(() {
        foreach (i, ref job; jobs)
        {
            job.ms = 5;
            spawnPublicRunner(s, &pool, &job, &errnos[i]);
        }
        assert(!s.spawn(() {
            // Every submitter parks right after its synchronous acceptance,
            // so once all six have started, all six are accepted.
            waitUntil(s, () {
                foreach (ref job; jobs)
                    if (!atomicLoad(job.started) && job.ran == 0)
                        return false;
                return true;
            });
            assert(!pool.shutdown().hasError);
            SleepJob late = {ms: 1};
            auto refused = pool.run(s, &sleepCall, &late);
            refusedAfter = refused.hasError && refused.error.errnoValue == EPIPE;
        }).hasError);
    });
    assert(!r.hasError);
    foreach (i, ref job; jobs)
        assert(errnos[i] == 0 && job.ran == 1,
            "accepted jobs complete exactly once across shutdown");
    assert(refusedAfter);
}

@("blockingPool.lifetime.poolsAndSchedulersInAnyCombination")
@system
unittest
{
    // Two pools bound to one scheduler, then eight short-lived pools in a
    // row: the scheduler owns its inbox, so nothing stale is left behind.
    Sched s;
    schedOrSkip(s);
    BlockingPool a, b;
    assert(!BlockingPool.create(a, 1, 4).hasError);
    assert(!BlockingPool.create(b, 1, 4).hasError);
    auto r = s.run(() {
        SleepJob ja = {ms: 1}, jb = {ms: 1};
        assert(!a.run(s, &sleepCall, &ja).hasError);
        assert(!b.run(s, &sleepCall, &jb).hasError);
        assert(ja.ran == 1 && jb.ran == 1);
        assert(!a.shutdown().hasError && !b.shutdown().hasError);
        foreach (_; 0 .. 8)
        {
            BlockingPool p;
            assert(!BlockingPool.create(p, 1, 2).hasError);
            SleepJob j = {ms: 1};
            assert(!p.run(s, &sleepCall, &j).hasError && j.ran == 1);
            assert(!p.shutdown().hasError);
        }
        SleepJob still = {ms: 1};
        BlockingPool last;
        assert(!BlockingPool.create(last, 1, 2).hasError);
        assert(!last.run(s, &sleepCall, &still).hasError && still.ran == 1);
        assert(!last.shutdown().hasError);
    });
    assert(!r.hasError);
}

@("blockingPool.lifetime.onePoolManySchedulerThreads")
@system
unittest
{
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 2, 8).hasError);
    scope (exit) cast(void) pool.shutdown();

    static void driver(BlockingPool* pool, int* ran)
    {
        Sched s;
        if (Sched.create(s).hasError)
            return;
        auto r = s.run(() {
            SleepJob j = {ms: 2};
            if (!pool.run(s, &sleepCall, &j).hasError)
                *ran = j.ran;
        });
        assert(!r.hasError);
    }

    static Thread startDriver(BlockingPool* pool, int* ran)
        => new Thread({ driver(pool, ran); }).start();

    int[3] ran;
    Thread[3] ts;
    foreach (i; 0 .. 3)
        ts[i] = startDriver(&pool, &ran[i]);
    foreach (t; ts)
        t.join();
    foreach (n; ran)
        assert(n == 1, "each scheduler thread got its own completion back");
}

@("blockingPool.fairness.bothLanesProgressUnderReplenishment")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    // One ordinary worker plus the reserved one. Producers stop at a fixed
    // barrier (a finite observation protocol), and both counters must have
    // advanced while both queues were nonempty.
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 1, 4).hasError);
    scope (exit) cast(void) pool.shutdown();

    int publicDone, mandatoryDone;
    auto r = s.run(() {
        foreach (i; 0 .. 6)
        {
            assert(!s.spawn(() {
                SleepJob j = {ms: 8};
                if (!pool.run(s, &sleepCall, &j).hasError)
                    ++publicDone;
            }).hasError);
            assert(!s.spawn(() {
                SleepJob j = {ms: 8};
                assert(!pool.runMandatory(s, &sleepCall, &j).hasError);
                ++mandatoryDone;
            }).hasError);
        }
    });
    assert(!r.hasError);
    assert(publicDone >= 4, "public jobs progress (a full queue may refuse some)");
    assert(mandatoryDone == 6, "every mandatory job completes");
}

@("blockingPool.shared.concurrentFirstAccessYieldsOneInstance")
@system
unittest
{
    import core.atomic : atomicOp;

    // Many threads race the very first access through the static guard:
    // every success sees the same holder and exactly one worker set exists.
    static shared int started;
    started = 0;
    static Thread startCaller(BlockingPool** slot)
        => new Thread({
            atomicOp!"+="(started, 1);
            while (atomicLoad(started) < 8)
                Thread.yield();
            auto got = sharedBlockingPool();
            if (!got.hasError)
                *slot = got.value;
        }).start();

    BlockingPool*[8] seen;
    Thread[8] ts;
    foreach (i; 0 .. 8)
        ts[i] = startCaller(&seen[i]);
    foreach (t; ts)
        t.join();
    foreach (p; seen)
        assert(p !is null && p is seen[0], "one process-wide holder");
    assert(seen[0]._threads.length >= 3, "one worker set: ordinary workers + reserved");
}

@("blockingPool.prepare.armsTheWakerBeforeTheSlabCanFill")
@system
unittest
{
    import sparkles.event_horizon.loop : LoopConfig;
    import sparkles.event_horizon.io : sleep;
    import sparkles.event_horizon.sched : SchedOptions;

    // A four-slot loop: prepared up front, the pool keeps working after
    // every ordinary slot is pinned by long sleeps — which is exactly the
    // state a mandatory reap meets at the end of a saturated run.
    Sched s;
    LoopConfig loopCfg;
    loopCfg.opSlots = 4;
    schedOrSkip(s, SchedOptions(), loopCfg);
    BlockingPool pool;
    assert(!BlockingPool.create(pool, 1, 4).hasError);
    scope (exit) cast(void) pool.shutdown();

    auto r = s.run(() {
        assert(!pool.prepare(s).hasError);
        assert(!pool.prepare(s).hasError, "idempotent");
        // Pin the remaining user slots (the waker took one).
        foreach (_; 0 .. 3)
            assert(!s.spawn(() { cast(void) sleep(s, 200.msecs); }).hasError);
        s.yieldNow();
        SleepJob reap = {ms: 1};
        assert(!pool.runMandatory(s, &sleepCall, &reap).hasError && reap.ran == 1,
            "no op slot is needed once the waker is armed");
    });
    assert(!r.hasError);
}
