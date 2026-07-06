/**
The work-stealing task pool (SPEC §11, M9c): N workers, each owning its own
ring and scheduler, draining a shared injection queue of $(I never-started)
tasks — the only stealable unit (a started fiber is pinned to its worker for
life; migrating one is undefined under LDC's TLS-address caching, so only
queued task bodies migrate). Whichever worker pulls a task runs it as a local
fiber, pinned thereafter.

An idle worker waits on a short in-ring `TIMEOUT`, so its one
`io_uring_enter` wait covers both CQE arrivals and the re-check tick — a
robust, lost-wakeup-free "single wait point". Event-driven wakeup (an in-ring
`FUTEX_WAIT` on kernel ≥ 6.7, or an eventfd nudge) is the latency
optimization tracked in open-issues O2; targeted per-worker-deque stealing
over `MSG_RING` is the same refinement. Correctness first: the poll interval
bounds task pick-up latency but cannot lose a wakeup.
*/
module sparkles.event_horizon.pool;

version (linux)  :  // rides the linux Sched; generalizes with M10

import core.atomic : atomicLoad, atomicOp, atomicStore, MemoryOrder;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, usecs;

import std.parallelism : totalCPUs;

import sparkles.event_horizon.errors : IoResult, ioOk;
import sparkles.event_horizon.group : LoopGroupConfig, Topology;
import sparkles.event_horizon.loop : LoopConfig;
import sparkles.event_horizon.sched : Sched, SchedOptions;

/// The idle re-check interval (open-issues O2: event-driven wakeup replaces
/// this polling as a latency optimization).
private enum Duration pollInterval = 200.usecs;

/**
A running work-stealing pool. Non-copyable; owns its worker threads and the
shared injection queue.
*/
struct WorkStealingPool
{
    @disable this(this);

    /// Starts a pool of `cfg.workers` workers (0 = one per online CPU).
    /// `io_uring` probe happens per worker at `run` time (SPEC §3.4).
    static IoResult!void start(out WorkStealingPool pool,
        in LoopGroupConfig cfg = LoopGroupConfig(topology: Topology.workStealing))
    {
        pool._cfg = cfg;
        pool._workers = cfg.workers != 0 ? cfg.workers : totalCPUs;
        pool._mutex = new Mutex;
        pool._started = true;
        return ioOk();
    }

    /// Worker count.
    uint workerCount() const @safe pure nothrow @nogc => _workers;

    /// No-op for symmetry (workers live only inside `run`).
    void shutdown() @safe nothrow
    {
        _started = false;
    }

    ~this()
    {
        shutdown();
    }

    /**
    Runs the pool: starts the workers, invokes `seed` (which submits the
    initial task(s) via `submit`), and blocks until every submitted task —
    including tasks those tasks submit — has finished. Then it drains the
    workers and returns.
    */
    void run(scope void delegate(ref WorkStealingPool pool) seed) @trusted
    {
        import core.memory : GC;

        // Worker threads block in io_uring_enter; a GC stop-the-world cannot
        // suspend a thread parked in that syscall, so a collection triggered
        // by another worker's allocation would deadlock the group. Disable
        // the collector for the pool's lifetime (setup allocations only;
        // the hot path is @nogc). A GC-safe blocking wait — the proper fix —
        // is tracked in open-issues O22.
        GC.disable();
        scope (exit) GC.enable();

        atomicStore(_pending, 0L);
        atomicStore(_done, false);

        auto cfg = _cfg;

        void runWorker(uint id) @trusted
        {
            import sparkles.event_horizon.io : sleep;

            SchedOptions opts;
            opts.maxFibers = cfg.maxFibers;
            LoopConfig loopCfg;
            loopCfg.backend.sqEntries = cfg.sqEntries;
            Sched sched;
            if (Sched.create(sched, opts, loopCfg).hasError)
                return;
            scope (exit) sched.destroy();

            if (cfg.pinToCpu)
                pinToCpu(id);

            sched.run(() {
                // The worker's root fiber: drain the shared queue, spawn
                // pulled tasks locally (pinned), then wait on a short in-ring
                // timer and re-check — until shutdown. The timer means this
                // fiber's single ring wait covers both the task fibers' CQEs
                // and the re-check tick; a missed signal is impossible.
                for (;;)
                {
                    drainQueue(sched);
                    if (atomicLoad(_done))
                        break;
                    cast(void) sleep(sched, pollInterval);
                }
            });
        }

        Thread makeWorker(uint id)
        {
            return new Thread(() => runWorker(id));
        }

        Thread[] threads;
        foreach (uint id; 1 .. _workers)
        {
            auto t = makeWorker(id);
            t.start();
            threads ~= t;
        }

        // Seed the initial work, then this thread also runs worker 0.
        seed(this);
        runWorker(0);
        foreach (t; threads)
            t.join();
    }

    /**
    Submits a task to the pool. Safe to call from any thread (including from
    inside a running task). The task body is a plain delegate; its closure
    context is GC-heap so it survives crossing to another worker.
    */
    void submit(void delegate() task) @trusted nothrow
    {
        atomicOp!"+="(_pending, 1);
        _mutex.lock_nothrow();
        _queue ~= task;
        _mutex.unlock_nothrow();
    }

private:
    /// Pulls queued tasks and spawns them onto `sched` (pinned locally),
    /// bounded so one worker cannot hog the queue or overrun its fiber slab.
    /// A task that cannot be spawned (slab full) is re-queued, never dropped
    /// — dropping was the deadlock: its `pending` count would never clear.
    void drainQueue(ref Sched sched) @trusted
    {
        // Leave headroom so the worker's own root fiber and in-flight ops
        // are never starved; the rest of the queue waits for the next tick
        // or another worker.
        const budget = sched.maxFibers > sched.liveFibers + 8
            ? sched.maxFibers - sched.liveFibers - 8 : 0;
        uint spawned;
        while (spawned < budget)
        {
            _mutex.lock_nothrow();
            void delegate() task;
            if (_queue.length > 0)
            {
                task = _queue[0];
                _queue = _queue[1 .. $];
            }
            _mutex.unlock_nothrow();
            if (task is null)
                return;

            if (!spawnWrapped(sched, task))
            {
                // Slab momentarily full: put it back and let the next tick
                // (or another worker) take it.
                requeueFront(task);
                return;
            }
            ++spawned;
        }
    }

    /// Spawns one wrapped task; `task` is a by-value parameter so each
    /// spawned closure binds its own delegate (a by-reference capture of a
    /// loop variable would share one heap cell — the D loop-capture bug).
    /// Returns `false` when the fiber slab is exhausted.
    bool spawnWrapped(ref Sched sched, void delegate() task) @trusted
    {
        return !sched.spawn(() {
            task();
            if (atomicOp!"-="(_pending, 1) == 0)
                broadcastShutdown();
        }).hasError;
    }

    /// Puts a task back at the front of the queue (re-queue on spawn failure).
    void requeueFront(void delegate() task) @trusted nothrow
    {
        _mutex.lock_nothrow();
        _queue = task ~ _queue;
        _mutex.unlock_nothrow();
    }

    /// Sets the shutdown flag; workers observe it at their next re-check tick
    /// (within `pollInterval`).
    void broadcastShutdown() @trusted nothrow
    {
        atomicStore(_done, true);
    }

    /// CPU pinning for a worker (best-effort).
    static void pinToCpu(uint cpu) @trusted nothrow @nogc
    {
        import core.sys.linux.sched : CPU_SET, cpu_set_t, sched_setaffinity;

        cpu_set_t set;
        CPU_SET(cpu % totalCPUs, &set);
        cast(void) sched_setaffinity(0, cpu_set_t.sizeof, &set);
    }

    LoopGroupConfig _cfg;
    uint _workers;
    Mutex _mutex;
    void delegate()[] _queue;
    shared long _pending;
    shared bool _done;
    bool _started;
}

@("pool.workStealing.distributesTasksAcrossWorkers")
@system
unittest
{
    import core.atomic : atomicOp;
    import core.time : msecs;

    import sparkles.event_horizon.io : sleep;
    import sparkles.event_horizon.sched : Sched;

    WorkStealingPool pool;
    LoopGroupConfig cfg;
    cfg.topology = Topology.workStealing;
    cfg.workers = 4;
    if (WorkStealingPool.start(pool, cfg).hasError)
        return; // SKIP
    scope (exit) pool.shutdown();

    enum tasks = 400;
    shared uint completed;
    shared uint worker0Tasks; // tasks run on the seeding thread's worker

    // Probe io_uring once so the whole test SKIPs cleanly on an unsupported
    // host rather than spinning up threads that all fail to create a ring.
    {
        Sched probe;
        if (Sched.create(probe, SchedOptions.init).hasError)
            return; // SKIP
        probe.destroy();
    }

    import core.thread : Thread;

    const seedThread = (() @trusted => cast(void*) Thread.getThis())();
    pool.run((ref WorkStealingPool p) {
        foreach (_; 0 .. tasks)
            p.submit(() {
                // Each task yields on the ring so work genuinely overlaps
                // across workers rather than one worker draining serially.
                cast(void) sleepCurrent(1.msecs);
                atomicOp!"+="(completed, 1);
                if ((() @trusted => cast(void*) Thread.getThis())() is seedThread)
                    atomicOp!"+="(worker0Tasks, 1);
            });
    });

    import core.atomic : atomicLoad;

    assert(atomicLoad(completed) == tasks, "every submitted task ran to completion");
    assert(atomicLoad(worker0Tasks) < tasks,
        "work distributed across workers, not all on the seeding thread");
}

version (unittest)
private IoResult!void sleepCurrent(Duration d)
{
    import sparkles.event_horizon.io : sleep;
    import sparkles.event_horizon.sched : Sched;

    // A task fiber's scheduler is the running one; reach it via the current
    // task's owner (the tier-B verbs do this internally).
    auto t = Sched.tryCurrent();
    assert(t !is null);
    return sleep(*t.owner, d);
}

import core.time : Duration;
