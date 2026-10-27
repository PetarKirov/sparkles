/**
The fiber parker's benchmarks FB1–FB7
([fiber-parker.md](../../../../../../../docs/specs/event-horizon/fiber-parker.md)
§7): each workload runs once with `fiberPark` forced to the ring path and once
to the inbox path, as two rows of one group (`--group-by=bench`).

Every case stands up its own schedulers inside the timed closure and does
enough handoffs there for the setup to amortize (as `loop.d` explains,
`benchCase` defers its closures). The wake-latency and fan-out workloads time
their own interval as well, and print its median and 99th percentile once the
case's measurement ends; `--syscalls=futex,io_uring_enter` adds the system
calls per iteration.
*/
module sparkles.event_horizon_bench.fiber_park;

version (linux)  :

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread.osthread : Thread;
import core.time : Duration, MonoTime, msecs, seconds, usecs;
import std.typecons : No;

import sparkles.base.sync : ManualResetEvent, Mutex, NativePlatform, Semaphore, WaitStatus;
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, Metric, Unit;
import sparkles.test_runner.skip : skipTest;

import sparkles.event_horizon.group : LoopGroup, LoopGroupConfig, RootScope, Topology;
import sparkles.event_horizon.sched : currentScheduler, FiberPark, Sched, SchedOptions;
import sparkles.event_horizon.scope_ : withScope;

private:

/// The two paths, as the rows of every group.
immutable FiberPark[2] paths = [FiberPark.ring, FiberPark.inbox];

string nameOf(FiberPark p) => p == FiberPark.ring ? "ring" : "inbox";

/// Handoffs per measured iteration.
enum uint handoffs = 10_000;

/// Skips unless a scheduler forced to the ring path waits in the kernel.
void requireRing()
{
    Sched probe;
    if (Sched.create(probe, SchedOptions(fiberPark: FiberPark.ring)).hasError)
        skipTest("io_uring unavailable");
    const ring = probe.ringPark;
    probe.destroy();
    if (!ring)
        skipTest("the kernel lacks the io_uring futex operations (Linux 6.7)");
}

/// A deadline for one wait: none (FB1, FB2) or 100 µs that never expires (FB7).
MonoTime deadlineFor(bool timed) => timed ? MonoTime.currTime + 100.usecs : MonoTime.max;

/// Acquires `s`, retrying a timed wait that expired, and counts the expiries.
void take(ref Semaphore s, bool timed, ref uint expired)
{
    while (s.acquireUntil(deadlineFor(timed)) != WaitStatus.ok)
        ++expired;
}

/// Durations a case's iterations measured themselves, summarized at its end.
final class Samples
{
    string label;
    Duration[] all;

    this(string label) { this.label = label; }

    void report()
    {
        import std.algorithm : sort;
        import std.stdio : stderr;

        if (all.length == 0)
            return;
        all.sort();
        const median = all[all.length / 2];
        const p99 = all[(all.length * 99) / 100 >= all.length ? $ - 1 : (all.length * 99) / 100];
        stderr.writefln("%s: n=%d median=%s p99=%s", label, all.length, median, p99);
    }
}

LoopGroupConfig groupConfig(FiberPark path, uint workers)
{
    LoopGroupConfig cfg;
    cfg.topology = Topology.threadPerCore;
    cfg.workers = workers;
    cfg.pinToCpu = No.pinToCpu;
    cfg.fiberPark = path;
    cfg.maxFibers = 1100;
    return cfg;
}

// ── FB1, FB7: the same-worker handoff ───────────────────────────────────────

void sameWorker(FiberPark path, bool timed)
{
    Sched s;
    if (Sched.create(s, SchedOptions(fiberPark: path)).hasError)
        return;
    scope (exit) s.destroy();
    Semaphore ping, pong;
    uint expired;
    cast(void) s.run(() {
        cast(void) s.spawn(() {
            foreach (_; 0 .. handoffs)
            {
                ping.release();
                take(pong, timed, expired);
            }
        });
        cast(void) s.spawn(() {
            foreach (_; 0 .. handoffs)
            {
                take(ping, timed, expired);
                pong.release();
            }
        });
    });
    assert(expired == 0, "a 100 µs deadline expired in a same-worker handoff");
}

// ── FB2, FB7: the cross-worker handoff ──────────────────────────────────────

void crossWorker(FiberPark path, bool timed)
{
    LoopGroup group;
    if (LoopGroup.start(group, groupConfig(path, 2)).hasError)
        return;
    auto ping = new Semaphore, pong = new Semaphore;
    shared uint expiredTotal;
    group.runEach((uint id, ref RootScope root, ref env) {
        uint expired;
        foreach (_; 0 .. handoffs)
        {
            if (id == 0)
            {
                ping.release();
                take(*pong, timed, expired);
            }
            else
            {
                take(*ping, timed, expired);
                pong.release();
            }
        }
        atomicOp!"+="(expiredTotal, expired);
    });
    cast(void) group.shutdown();
    // Recorded rather than asserted: a cross-worker wake can exceed 100 µs
    // under load, and FB7 reports how often.
    if (timed && atomicLoad(expiredTotal) > 0)
    {
        import std.stdio : stderr;

        stderr.writefln("FB7 %s cross-worker: %d of %d waits expired", nameOf(path),
            atomicLoad(expiredTotal), 2 * handoffs);
    }
}

void registerHandoff(string bench, FiberPark path, bool cross, bool timed)
{
    benchCase(
        name: nameOf(path),
        labels: ["bench": bench],
        timed: () {
            if (cross)
                crossWorker(path, timed);
            else
                sameWorker(path, timed);
        },
        after: () {},
        metrics: [Metric(Unit("handoff"), 2 * handoffs, Metric.Mode.rate)],
    );
}

@("fiberPark.FB1.sameWorkerHandoff")
@benchmark
@system
unittest
{
    requireRing();
    foreach (path; paths)
        registerHandoff("FB1", path, cross: false, timed: false);
}

@("fiberPark.FB2.crossWorkerHandoff")
@benchmark
@system
unittest
{
    requireRing();
    foreach (path; paths)
        registerHandoff("FB2", path, cross: true, timed: false);
}

@("fiberPark.FB7.timedHandoffs")
@benchmark
@system
unittest
{
    requireRing();
    foreach (path; paths)
    {
        registerHandoff("FB7 same-worker", path, cross: false, timed: true);
        registerHandoff("FB7 cross-worker", path, cross: true, timed: true);
    }
}

// ── FB3: a wake from an unregistered thread ─────────────────────────────────

/// Wakes per measured iteration of FB3.
enum uint foreignWakes = 500;

void foreignWake(FiberPark path, Samples samples)
{
    Sched s;
    if (Sched.create(s, SchedOptions(fiberPark: path)).hasError)
        return;
    scope (exit) s.destroy();
    auto sem = new Semaphore;
    shared bool waiting, stop;
    shared long releasedAt;
    // A thread no scheduler knows: it releases once the fiber is parked.
    auto t = new Thread(() {
        while (!atomicLoad(stop))
        {
            if (!atomicLoad(waiting))
            {
                Thread.yield();
                continue;
            }
            // Give the fiber time to be parked, not merely about to be.
            const until = MonoTime.currTime + 20.usecs;
            while (MonoTime.currTime < until) {}
            atomicStore(waiting, false);
            atomicStore(releasedAt, MonoTime.currTime.ticks);
            sem.release();
        }
    });
    t.start();
    scope (exit)
    {
        atomicStore(stop, true);
        t.join();
    }
    cast(void) s.run(() {
        foreach (_; 0 .. foreignWakes)
        {
            atomicStore(waiting, true);
            sem.acquire();
            const now = MonoTime.currTime.ticks;
            samples.all ~= ticksToDuration(now - atomicLoad(releasedAt));
        }
    });
}

/// A difference of `MonoTime` ticks, as a `Duration`.
Duration ticksToDuration(long ticks)
{
    import core.time : convClockFreq, nsecs;

    return convClockFreq(ticks, MonoTime.ticksPerSecond, 1_000_000_000).nsecs;
}

@("fiberPark.FB3.unregisteredThreadWake")
@benchmark
@system
unittest
{
    requireRing();
    foreach (path; paths)
        registerForeign(path);
}

void registerForeign(FiberPark path)
{
    auto samples = new Samples("FB3 " ~ nameOf(path) ~ " wake-to-resume");
    benchCase(
        name: nameOf(path),
        labels: ["bench": "FB3"],
        timed: () => foreignWake(path, samples),
        after: () {},
        teardown: () => samples.report(),
        metrics: [Metric(Unit("wake"), foreignWakes, Metric.Mode.rate)],
    );
}

// ── FB4: one Event set wakes n fibers over all workers ──────────────────────

Duration fanOut(FiberPark path, uint n)
{
    LoopGroup group;
    if (LoopGroup.start(group, groupConfig(path, 2)).hasError)
        return Duration.zero;
    scope (exit) cast(void) group.shutdown();
    auto ev = new ManualResetEvent;
    shared uint parked, resumed;
    shared long setAt, lastAt;
    group.runEach((uint id, ref RootScope root, ref env) {
        auto s = &currentScheduler();
        const mine = id == 0 ? (n + 1) / 2 : n / 2;
        foreach (_; 0 .. mine)
            root.spawn(() {
                atomicOp!"+="(parked, 1);
                ev.wait();
                if (atomicOp!"+="(resumed, 1) == n)
                    atomicStore(lastAt, MonoTime.currTime.ticks);
            });
        if (id != 0)
            return;
        // Every fiber is parked, on both workers, before the set.
        while (atomicLoad(parked) < n || s.lotSleepers < mine)
            s.yieldNow();
        Thread.sleep(1.msecs);
        atomicStore(setAt, MonoTime.currTime.ticks);
        ev.set();
    });
    return ticksToDuration(atomicLoad(lastAt) - atomicLoad(setAt));
}

void registerFanOut(FiberPark path, uint n)
{
    import std.conv : to;

    auto samples = new Samples("FB4 " ~ nameOf(path) ~ " n=" ~ n.to!string ~ " set-to-last-resume");
    benchCase(
        name: nameOf(path),
        labels: ["bench": "FB4 n=" ~ n.to!string],
        timed: () => fanOut(path, n),
        after: (ref Duration d) { samples.all ~= d; },
        teardown: () => samples.report(),
    );
}

@("fiberPark.FB4.eventFanOut")
@benchmark
@system
unittest
{
    requireRing();
    foreach (n; [1u, 16, 256])
        foreach (path; paths)
            registerFanOut(path, n);
}

// ── FB5: cancelling a scope with n interruptible waits ──────────────────────

Duration cancelScope(FiberPark path, uint n)
{
    Sched s;
    SchedOptions opts;
    opts.fiberPark = path;
    opts.maxFibers = n + 8;
    if (Sched.create(s, opts).hasError)
        return Duration.zero;
    scope (exit) s.destroy();
    auto sem = new Semaphore;
    uint resumed;
    MonoTime cancelledAt, lastAt;
    cast(void) s.run(() {
        cast(void) withScope!((ref sc) {
            foreach (_; 0 .. n)
                sc.spawn(() {
                    cast(void) sem.acquireUntil(MonoTime.max, true);
                    if (++resumed == n)
                        lastAt = MonoTime.currTime;
                });
            while (s.lotSleepers < n)
                s.yieldNow();
            // On the ring path every wait is written before the
            // cancellation, so that it measures the cancel word's wake
            // (EFP10): a tick writes them at its submission point.
            while (s.ringPark && s.ringWaits < n)
                s.yieldNow();
            cancelledAt = MonoTime.currTime;
            sc.cancel();
        })(s);
    });
    return lastAt - cancelledAt;
}

void registerCancel(FiberPark path, uint n)
{
    import std.conv : to;

    auto samples = new Samples("FB5 " ~ nameOf(path) ~ " n=" ~ n.to!string ~ " cancel-to-last-resume");
    benchCase(
        name: nameOf(path),
        labels: ["bench": "FB5 n=" ~ n.to!string],
        timed: () => cancelScope(path, n),
        after: (ref Duration d) { samples.all ~= d; },
        teardown: () => samples.report(),
    );
}

@("fiberPark.FB5.scopeCancellation")
@benchmark
@system
unittest
{
    requireRing();
    foreach (n; [1u, 64, 1024])
        foreach (path; paths)
            registerCancel(path, n);
}

// ── FB6: mutexes whose keys share a parking-lot bucket ──────────────────────

/// How long each FB6 iteration contends.
enum Duration contendFor = 50.msecs;

/// Mutexes, all of whose parking-lot keys hash to one bucket.
Mutex*[] sharedBucketMutexes(size_t count)
{
    Mutex*[] found;
    size_t bucket = size_t.max;
    while (found.length < count)
    {
        auto m = new Mutex;
        const b = NativePlatform.bucketOf(cast(size_t) m);
        if (bucket == size_t.max)
            bucket = b;
        if (b == bucket)
            found ~= m;
    }
    return found;
}

/// The per-thread CPU time of the calling thread.
Duration threadCpu() @trusted
{
    import core.sys.linux.time : clock_gettime, CLOCK_THREAD_CPUTIME_ID, timespec;
    import core.time : nsecs;

    timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return (ts.tv_sec * 1_000_000_000L + ts.tv_nsec).nsecs;
}

struct Contention
{
    Duration cpu;   /// the workers' CPU time
    ulong ticks;    /// turns of the fibers that contend for nothing
}

Contention contend(FiberPark path, Mutex*[] ms)
{
    LoopGroup group;
    if (LoopGroup.start(group, groupConfig(path, 8)).hasError)
        return Contention.init;
    scope (exit) cast(void) group.shutdown();
    shared long cpuNs;
    shared ulong ticks;
    group.runEach((uint id, ref RootScope root, ref env) {
        auto s = &currentScheduler();
        const start = threadCpu();
        const until = MonoTime.currTime + contendFor;
        // Two fibers per worker contend, so a waiter parks on the worker
        // while its other fibers still run.
        foreach (k; 0 .. 2)
            root.spawn(() {
                size_t i = id * 2 + k;
                while (MonoTime.currTime < until)
                {
                    auto m = ms[i++ % ms.length];
                    m.lock();
                    const hold = MonoTime.currTime + 2.usecs;
                    while (MonoTime.currTime < hold) {}
                    m.unlock();
                    s.yieldNow();
                }
            });
        ulong mine;
        while (MonoTime.currTime < until)
        {
            ++mine;
            s.yieldNow();
        }
        atomicOp!"+="(ticks, mine);
        // The root's turns end first; the contenders' end at `until` too.
        while (s.liveFibers > 1)
            s.yieldNow();
        atomicOp!"+="(cpuNs, (threadCpu() - start).total!"nsecs");
    });
    import core.time : nsecs;

    return Contention(atomicLoad(cpuNs).nsecs, atomicLoad(ticks));
}

void registerContention(FiberPark path)
{
    auto ms = sharedBucketMutexes(4);
    auto cpu = new Samples("FB6 " ~ nameOf(path) ~ " worker CPU per 50 ms window (8 workers)");
    auto others = new Samples("FB6 " ~ nameOf(path) ~ " other fibers' turns per 50 ms (as ns = turns)");
    benchCase(
        name: nameOf(path),
        labels: ["bench": "FB6"],
        timed: () => contend(path, ms),
        after: (ref Contention c) {
            import core.time : nsecs;

            cpu.all ~= c.cpu;
            others.all ~= (cast(long) c.ticks).nsecs;
        },
        teardown: () {
            cpu.report();
            others.report();
        },
    );
}

@("fiberPark.FB6.sharedBucketContention")
@benchmark
@system
unittest
{
    requireRing();
    foreach (path; paths)
        registerContention(path);
}
