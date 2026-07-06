/**
The work-stealing task pool (SPEC §11, M9c): N workers, each owning its own
ring and scheduler plus a private work-stealing deque of $(I never-started)
tasks — the only stealable unit (a started fiber is pinned to its worker for
life; migrating one is undefined under LDC's TLS-address caching, so only
queued task bodies migrate). A worker pushes/pops its own deque tail (LIFO,
for locality) and steals from a peer's head (FIFO) only when its own is empty,
so the common case is uncontended. `submit` runs a task as a local fiber
(it may park on I/O); `submitBlocking` runs a CPU-bound task inline (no fiber).

An idle worker sleeps with exponential backoff on a short in-ring `TIMEOUT`,
so its one `io_uring_enter` wait covers both CQE arrivals and the re-check
tick — a robust, lost-wakeup-free "single wait point" that also keeps an
over-provisioned pool from thrashing. Event-driven wakeup (in-ring
`FUTEX_WAIT` ≥ 6.7, or `MSG_RING`-targeted stealing) is the latency
optimization in open-issues O2.

For CPU-bound fan-out (no I/O parking), `LoopGroupConfig.cpuBound` drops the
per-worker ring + fibers entirely: workers become plain threads running
`submitBlocking` tasks inline (the rayon shape). This is what lets the pool
BEAT rust-rayon on the polyglot-walks benchmark (`benchmarks.md` §2) — the
per-worker io_uring setup that made the default a poor fit for a short batch
is simply not built.
*/
module sparkles.event_horizon.pool;

version (Posix)  :  // rides Sched; CPU pinning is linux-guarded internally

import core.atomic : atomicFence, atomicFetchAdd, atomicFetchSub, atomicLoad,
    atomicOp, atomicStore, cas, MemoryOrder;
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

/// Idle backoff cap: an idle worker sleeps up to pollInterval << this (200us
/// << 5 = 6.4 ms), then holds. Bounds both steal-scan thrash and the wake-up
/// latency for new work / shutdown.
private enum uint maxBackoffShift = 5;

/// CPU-mode idle tuning: spin (Thread.yield) this many rounds for low-latency
/// steal pickup before sleeping, then sleep cpuBackoffBase << shift.
private enum uint cpuSpinRounds = 64;
private enum Duration cpuBackoffBase = 20.usecs;

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
        // is tracked in open-issues O22. (Enabling it for cpuBound mode was
        // tried — the STW pauses cost more than the heap-growth mmaps saved.)
        GC.disable();
        scope (exit) GC.enable();

        atomicStore(_pending, 0L);
        atomicStore(_done, false);

        // One deque per worker (Chase-Lev-style split: the owner pushes/pops
        // its tail, thieves steal from the head). A worker touches its own
        // deque almost exclusively — the global-mutex contention that the
        // walker benchmark exposed (open-issues O2) is gone.
        _deques = new Deque[_workers];
        foreach (ref d; _deques)
            d = new Deque;

        auto cfg = _cfg;

        void runWorker(uint id) @trusted
        {
            import sparkles.event_horizon.io : sleep, yieldNow;

            t_workerId = id; // so submit() from a task lands on this worker
            t_rng = (id + 1) * 2_654_435_761u | 1u; // seed the steal RNG (non-zero)
            if (cfg.pinToCpu)
                pinToCpu(id);

            // CPU-bound mode: a plain thread + deque, no io_uring ring and no
            // fibers — the rayon shape. This is what beats a thread pool of
            // closures on a short CPU batch: none of the per-worker ring mmap
            // + fiber-stack page faults that dominate otherwise.
            if (cfg.cpuBound)
            {
                runWorkerCpu(id);
                return;
            }

            SchedOptions opts;
            opts.maxFibers = cfg.maxFibers;
            LoopConfig loopCfg;
            loopCfg.backend.sqEntries = cfg.sqEntries;
            Sched sched;
            if (Sched.create(sched, opts, loopCfg).hasError)
                return;
            scope (exit) sched.destroy();

            sched.run(() {
                // The worker's root fiber: run from its own deque (stealing
                // when empty), then either yield to run spawned fibers and
                // re-check immediately (had work) or sleep with EXPONENTIAL
                // BACKOFF (idle) — until shutdown. The backoff is what keeps an
                // over-provisioned pool (more workers than the workload needs)
                // from thrashing: idle workers quiet down instead of
                // steal-scanning every peer and hammering the shared counter
                // (the negative scaling the walker exposed).
                uint idle;
                for (;;)
                {
                    const didWork = workUntilIdle(sched, id);
                    if (atomicLoad(_done))
                        break;
                    if (didWork)
                    {
                        idle = 0;
                        cast(void) yieldNow(sched);
                    }
                    else
                    {
                        const shift = idle < maxBackoffShift ? idle : maxBackoffShift;
                        cast(void) sleep(sched, pollInterval * (1 << shift));
                        if (idle < maxBackoffShift)
                            ++idle;
                    }
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
    context is GC-heap so it survives crossing to another worker. Submitted
    onto the calling worker's own deque (locality); the seed thread is worker
    0.
    */
    void submit(void delegate() task) @trusted nothrow
    {
        enqueue(Job(task, false));
    }

    /**
    Submits a $(I CPU-bound) task that runs $(B inline) on the worker — no
    fiber, no ring round-trip. Use this for work that never parks on I/O (a
    parallel compute/traversal fan-out, like `std.parallelism.taskPool`): it
    skips the per-task fiber's 64 KiB stack + context switch, which for
    sub-microsecond tasks is the whole cost (see `benchmarks.md` §2). A task
    submitted this way must NOT call the tier-B I/O verbs (there is no fiber to
    suspend); use `submit` for those.
    */
    void submitBlocking(void delegate() task) @trusted nothrow
    {
        enqueue(Job(task, true));
    }

private:
    /// Enqueues a job onto the calling worker's own deque (locality); the
    /// seed thread is worker 0.
    void enqueue(Job job) @trusted nothrow
    {
        // Relaxed: the counter only needs atomicity, not ordering — the
        // _done store/load (seq_cst) provides the shutdown barrier.
        atomicFetchAdd!(MemoryOrder.raw)(_pending, 1);
        const w = (t_workerId >= 0 && t_workerId < _workers) ? t_workerId : 0;
        _deques[w].push(job);
    }

    /// Runs jobs — from this worker's own deque first, then stealing from
    /// peers when it is empty. `submitBlocking` jobs run inline (no fiber);
    /// `submit` jobs spawn a fiber (bounded by the slab, so one worker cannot
    /// overrun it). Returns whether it did anything. An async job that cannot
    /// be spawned (slab full) is pushed back onto the local deque, never
    /// dropped.
    bool workUntilIdle(ref Sched sched, uint id) @trusted
    {
        const budget = sched.maxFibers > sched.liveFibers + 8
            ? sched.maxFibers - sched.liveFibers - 8 : 0;
        uint did;
        for (;;)
        {
            Job job;
            if (!_deques[id].popTail(job) && !trySteal(id, job))
                break; // nothing anywhere right now
            if (job.inline_)
            {
                job.body_(); // CPU-bound: run synchronously on this worker
                if (atomicFetchSub!(MemoryOrder.raw)(_pending, 1) == 1)
                    broadcastShutdown();
            }
            else
            {
                if (did >= budget || !spawnWrapped(sched, job.body_))
                {
                    _deques[id].push(job); // slab full / budget hit: keep local
                    break;
                }
            }
            ++did;
        }
        return did > 0;
    }

    /// The CPU-bound worker loop (no `Sched`, no ring, no fibers): drain the
    /// local deque + steal, run each job inline, back off when idle. This is
    /// the rayon-shaped path.
    void runWorkerCpu(uint id) @trusted
    {
        import core.thread : Thread;

        uint idle;
        for (;;)
        {
            const didWork = drainCpu(id);
            if (atomicLoad(_done))
                break;
            if (didWork)
            {
                idle = 0;
                continue; // straight back to draining — nothing to yield to
            }
            // A brief SMT-friendly spin (cheap re-steal attempts, low pickup
            // latency, PAUSE yields the core to the busy sibling) then
            // exponential sleep so idle workers stop contending on peers.
            if (idle < cpuSpinRounds)
            {
                foreach (_; 0 .. 32)
                    cpuRelax();
            }
            else
            {
                const shift = idle - cpuSpinRounds < maxBackoffShift
                    ? idle - cpuSpinRounds : maxBackoffShift;
                Thread.sleep(cpuBackoffBase * (1 << shift));
            }
            ++idle;
        }
    }

    /// Runs every job currently reachable (own deque then steals) inline;
    /// returns whether it ran anything.
    bool drainCpu(uint id) @trusted
    {
        uint did;
        for (;;)
        {
            Job job;
            if (!_deques[id].popTail(job) && !trySteal(id, job))
                break;
            job.body_(); // inline — no fiber
            if (atomicFetchSub!(MemoryOrder.raw)(_pending, 1) == 1)
                broadcastShutdown();
            ++did;
        }
        return did > 0;
    }

    /// Steals one job from a peer's deque head (FIFO), scanning round-robin
    /// from the next worker so thieves spread out.
    bool trySteal(uint id, out Job job) @trusted
    {
        // Randomized scan start so thieves spread across victims instead of
        // all piling onto the lowest-numbered loaded deque.
        const start = nextRand() % _workers;
        foreach (i; 0 .. _workers)
        {
            const victim = (start + i) % _workers;
            if (victim == id)
                continue;
            // Cheap relaxed pre-filter: skip an obviously-empty peer without
            // paying stealHead's seq_cst fence + CAS.
            if (_deques[victim].maybeEmpty())
                continue;
            // Batch steal: take half of the victim onto our own deque, run one
            // now. `id` is always a valid worker here (thieves are workers).
            if (_deques[victim].stealBatch(job, _deques[id]))
                return true;
        }
        return false;
    }

    /// Spawns one wrapped async task; `body_` is by value so each spawned
    /// closure binds its own delegate (a by-reference capture of a loop
    /// variable would share one heap cell — the D loop-capture bug). Returns
    /// `false` when the fiber slab is exhausted.
    bool spawnWrapped(ref Sched sched, void delegate() body_) @trusted
    {
        return !sched.spawn(() {
            body_();
            if (atomicFetchSub!(MemoryOrder.raw)(_pending, 1) == 1)
                broadcastShutdown();
        }).hasError;
    }

    /// Sets the shutdown flag; workers observe it at their next re-check tick.
    void broadcastShutdown() @trusted nothrow
    {
        atomicStore(_done, true);
    }

    /// CPU pinning for a worker (best-effort; Linux only for now).
    static void pinToCpu(uint cpu) @trusted nothrow @nogc
    {
        version (linux)
        {
            import core.sys.linux.sched : CPU_SET, cpu_set_t, sched_setaffinity;

            cpu_set_t set;
            CPU_SET(cpu % totalCPUs, &set);
            cast(void) sched_setaffinity(0, cpu_set_t.sizeof, &set);
        }
        // Non-Linux: unpinned (platform pinning primitive is a follow-up).
    }

    LoopGroupConfig _cfg;
    uint _workers;
    Deque[] _deques;
    shared long _pending;
    shared bool _done;
    bool _started;
}

/// The set of the current thread's worker id (`-1` off a worker thread; the
/// seed thread defaults to worker 0). Thread-local so `submit` from inside a
/// task lands on that task's own worker.
private int t_workerId = -1;

/// Per-worker xorshift RNG state for randomized victim selection — thieves that
/// all scan in the same order pile CAS retries onto the same loaded deques,
/// which is what balloons the instruction count at high worker counts (the
/// wide-tree case in `benchmarks.md` §2). A random scan start spreads them.
private uint t_rng = 0;

private uint nextRand() @safe nothrow @nogc
{
    uint x = t_rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    t_rng = x;
    return x;
}

/// An SMT-friendly spin hint: the x86 `PAUSE` instruction tells the core this
/// is a spin-wait, so it yields pipeline/cache resources to the *sibling*
/// hyperthread — the opposite of `sched_yield`, which keeps this SMT lane hot
/// and starves the busy sibling. Decisive on this 16-core/32-thread part where
/// beating rayon means running 32 workers (both SMT lanes) without the idle
/// ones robbing the busy ones. No syscall.
private void cpuRelax() @trusted nothrow @nogc
{
    version (D_InlineAsm_X86_64)
        asm nothrow @nogc { rep; nop; } // F3 90 = PAUSE
    else version (D_InlineAsm_X86)
        asm nothrow @nogc { rep; nop; }
    else
    {
    } // other ISAs: a plain retry loop (no relax hint)
}

/// One unit of work: its body plus whether it runs inline (CPU-bound,
/// `submitBlocking`) or as a fiber (`submit`).
private struct Job
{
    void delegate() body_;
    bool inline_;
}

/// A per-worker **lock-free Chase-Lev work-stealing deque**: the owner
/// pushes/pops its tail (`bottom`, LIFO for locality), thieves steal from the
/// head (`top`, FIFO), and no path takes a lock. This is what lets the pool
/// scale to many workers without the mutex the previous version used — under
/// the old design an idle worker's steal-scan locked every peer's mutex, and
/// the instruction count ballooned with worker count (`benchmarks.md` §2, the
/// wide-tree case). Single owner, many thieves — the pool's invariant (only the
/// owning worker calls `push`/`popTail`; any worker may `stealHead`).
///
/// The backing buffer sits behind an atomic pointer so a grow (owner-only, on a
/// full push) is safe against concurrent steals: a thief reads whichever buffer
/// it loaded and both index element `i` at `i & mask`, so the read is correct
/// from either, and the old buffer stays GC-alive while a thief references it.
/// `Job` holds a GC delegate, so GC-backed buffers also keep closures alive.
private final class Deque
{
    private static final class Buf
    {
        Job[] items;
        size_t mask;
        this(size_t n) @safe nothrow
        {
            items = new Job[n];
            mask = n - 1;
        }
    }

    private shared long _top;     // steal end — thieves CAS to claim
    private shared long _bottom;  // owner end
    private shared(Buf) _buf;     // atomic pointer to the current backing buffer

    private enum size_t initialCap = 64;

    this() @trusted nothrow
    {
        atomicStore(_buf, cast(shared) new Buf(initialCap));
    }

    private static Buf loadBuf(ref shared(Buf) b) @trusted nothrow
        => cast(Buf) atomicLoad!(MemoryOrder.acq)(b);

    /// Owner: push onto the tail (growing the ring if it is full).
    void push(Job j) @trusted nothrow
    {
        const b = atomicLoad!(MemoryOrder.raw)(_bottom);
        const t = atomicLoad!(MemoryOrder.acq)(_top);
        auto buf = loadBuf(_buf);
        if (b - t >= cast(long) buf.items.length)
            buf = grow(buf, b, t);
        buf.items[b & buf.mask] = j;
        atomicFence(); // the slot write must precede the bottom publish
        atomicStore!(MemoryOrder.rel)(_bottom, b + 1);
    }

    // Owner-only: double the ring, copying the live range [t, b). Element i
    // keeps its `i & mask` position (with the new, wider mask), so a thief that
    // reads either buffer at `t & mask` still finds element t.
    private Buf grow(Buf old, long b, long t) @trusted nothrow
    {
        auto next = new Buf(old.items.length * 2);
        for (long i = t; i < b; ++i)
            next.items[i & next.mask] = old.items[i & old.mask];
        atomicStore!(MemoryOrder.rel)(_buf, cast(shared) next);
        return next;
    }

    /// Owner: pop from the tail (LIFO). `false` when empty.
    bool popTail(out Job j) @trusted nothrow
    {
        const b = atomicLoad!(MemoryOrder.raw)(_bottom) - 1;
        auto buf = loadBuf(_buf);
        atomicStore!(MemoryOrder.raw)(_bottom, b);
        atomicFence(); // seq_cst between the bottom store and the top load
        const t = atomicLoad!(MemoryOrder.raw)(_top);
        if (t <= b)
        {
            j = buf.items[b & buf.mask];
            if (t == b)
            {
                // Last element: race the thieves for it.
                if (!cas(&_top, t, t + 1))
                {
                    atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
                    return false;
                }
                atomicStore!(MemoryOrder.raw)(_bottom, b + 1);
            }
            return true;
        }
        atomicStore!(MemoryOrder.raw)(_bottom, b + 1); // was empty
        return false;
    }

    /// Thief: steal from the head (FIFO). `false` when empty or the race lost.
    bool stealHead(out Job j) @trusted nothrow
    {
        const t = atomicLoad!(MemoryOrder.acq)(_top);
        atomicFence(); // seq_cst so a concurrent owner pop is observed
        const b = atomicLoad!(MemoryOrder.acq)(_bottom);
        if (t < b)
        {
            auto buf = loadBuf(_buf);
            j = buf.items[t & buf.mask];
            return cas(&_top, t, t + 1); // false = another thief won
        }
        return false;
    }

    /// Thief: steal roughly HALF the victim's queue in one CAS — `out first` is
    /// returned to run now, the rest are pushed onto `mine` (the thief's own
    /// deque). Batch stealing spreads a burst of work in O(log n) steals
    /// instead of O(n), the difference between event-horizon's and rayon's
    /// parallel scaling on wide fan-out (`benchmarks.md` §2). `false` = empty or
    /// the CAS race lost.
    bool stealBatch(out Job first, Deque mine) @trusted nothrow
    {
        const t = atomicLoad!(MemoryOrder.acq)(_top);
        atomicFence();
        const b = atomicLoad!(MemoryOrder.acq)(_bottom);
        const n = b - t;
        if (n <= 0)
            return false;
        const k = n < 2 ? 1 : cast(long)((n + 1) / 2); // take half, at least one
        auto buf = loadBuf(_buf);
        // One CAS claims the whole range [t, t+k); losers retry via the scan.
        if (!cas(&_top, t, t + k))
            return false;
        first = buf.items[t & buf.mask];
        foreach (i; t + 1 .. t + k)
            mine.push(buf.items[i & buf.mask]);
        return true;
    }

    /// A relaxed, lock-free emptiness hint for the steal-scan pre-filter — lets
    /// an idle worker skip an obviously-empty peer without the seq_cst fence.
    bool maybeEmpty() @trusted nothrow
        => atomicLoad!(MemoryOrder.raw)(_bottom)
            - atomicLoad!(MemoryOrder.raw)(_top) <= 0;
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

@("pool.workStealing.cpuBoundInlineFanOut")
@system
unittest
{
    import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;

    // CPU-bound mode: ring-less workers running inline tasks (the rayon shape;
    // no io_uring, so it never SKIPs). A recursive binary fan-out exercises
    // submit-from-task, cross-worker stealing, and the relaxed pending
    // counter's termination — every task must run exactly once.
    WorkStealingPool pool;
    LoopGroupConfig cfg;
    cfg.topology = Topology.workStealing;
    cfg.workers = 4;
    cfg.cpuBound = typeof(cfg.cpuBound).yes;
    assert(!WorkStealingPool.start(pool, cfg).hasError);
    scope (exit) pool.shutdown();

    shared uint ran;

    void fan(ref WorkStealingPool p, uint depth)
    {
        atomicFetchAdd!(MemoryOrder.raw)(ran, 1);
        if (depth == 0)
            return;
        auto pp = &p;
        p.submitBlocking(() { fan(*pp, depth - 1); });
        p.submitBlocking(() { fan(*pp, depth - 1); });
    }

    enum depth = 12; // 2^13 - 1 = 8191 tasks
    pool.run((ref WorkStealingPool p) { fan(p, depth); });

    assert(atomicLoad(ran) == (1 << (depth + 1)) - 1, "every task ran exactly once");
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
