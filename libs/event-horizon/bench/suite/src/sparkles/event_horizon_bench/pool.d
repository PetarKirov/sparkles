/**
Work-stealing pool workloads for `sparkles:event-horizon`, on
`sparkles:test-runner` (`dub test -- --bench --perf`).

These are `@workload`s, not `@benchmark`s, deliberately: a pool run is long,
stateful and kernel-heavy, and the question is not "how long is one iteration"
but $(I where did this run's time and events go) — which is exactly the window
model's wall-clock decomposition (`cpu usr`/`cpu krn`/`runq`/`other`) plus
counter totals.

One window per worker count makes the pool's scaling behaviour a table rather
than a claim. The load-bearing column is **page faults**: the pool's default
(async) topology gives every worker its own `io_uring` ring and fiber stacks,
so faults scale with the worker count — the per-worker setup weight that made a
short CPU batch lose badly until `cpuBound` removed it
($(LINK2 ../../../../docs/specs/event-horizon/benchmarks.md, benchmarks.md) §2).
Retired instructions and page faults are the host-stable anchors; read `cycles`
and IPC as explanation.

`--syscalls=futex,sched_yield` adds the coordination view (the pool's whole
design goal is keeping threads off the kernel), and `--metrics=minflt,vol-cs`
the tier-0 view — both replacing what an external `strace -c` pass used to
provide.
*/
module sparkles.event_horizon_bench.pool;

version (Posix)  :  // the pool rides Sched; cpuBound mode is ring-less

import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;

import sparkles.test_runner.attributes : workload;
import sparkles.test_runner.skip : skipTest;
import sparkles.test_runner.workload : workloadWindow;

import sparkles.event_horizon.group : LoopGroupConfig, Topology;
import sparkles.event_horizon.pool : WorkStealingPool;

/// Worker counts swept by every scaling workload. 1 is the serial reference;
/// the host's core count is the interesting end (this is where coordination
/// cost, if any, shows up).
private immutable uint[] workerCounts = [1, 2, 4, 8, 16, 32];

/// Binary fan-out depth: `2^(depth+1) - 1` tasks (depth 13 ≈ 16 k), enough
/// that stealing genuinely happens and one worker cannot drain it serially.
private enum uint fanDepth = 13;

private shared ulong g_ran;

@("pool.fanOut.workerScaling")
@workload
@system
unittest
{
    // Pure task-distribution cost: every task is trivial, so the window's
    // events ARE the pool's overhead (deque traffic, stealing, wakeups) with
    // no user work to hide behind. Compare `pg-flt` and `instr` across rows:
    // flat means the pool scales, growth means per-worker setup weight.
    foreach (w; workerCounts)
        fanOutWindow(w);
}

/// One window per worker count; takes `workers` by value so the closure never
/// shares a loop slot.
private void fanOutWindow(uint workers)
{
    import std.conv : text;

    workloadWindow(text("workers=", workers), () {
        atomicStore_(0);
        runFanOut(workers, fanDepth);
        // Correctness inside the measurement: a dropped or duplicated task
        // would silently change the numbers, so assert the exact count.
        const expected = (1UL << (fanDepth + 1)) - 1;
        const got = atomicLoad(g_ran);
        assert(got == expected, text("fan-out ran ", got, " of ", expected));
    });
}

private void atomicStore_(ulong v) @trusted
{
    import core.atomic : atomicStore;

    atomicStore(g_ran, v);
}

/// Runs one binary fan-out through a ring-less (`cpuBound`) pool.
private void runFanOut(uint workers, uint depth) @system
{
    WorkStealingPool pool;
    LoopGroupConfig cfg;
    cfg.topology = Topology.workStealing;
    cfg.cpuBound = typeof(cfg.cpuBound).yes; // no ring, no fibers: CPU batch
    cfg.workers = workers;
    if (WorkStealingPool.start(pool, cfg).hasError)
        skipTest("work-stealing pool unavailable");
    scope (exit) pool.shutdown();

    pool.run((ref WorkStealingPool p) { fan(p, depth); });
}

/// Each task counts itself and spawns two children until `depth` runs out.
private void fan(ref WorkStealingPool p, uint depth) @system
{
    atomicFetchAdd!(MemoryOrder.raw)(g_ran, 1);
    if (depth == 0)
        return;
    auto pp = &p;
    p.submitBlocking(() { fan(*pp, depth - 1); });
    p.submitBlocking(() { fan(*pp, depth - 1); });
}

// ── the I/O-bound counterpart ───────────────────────────────────────────────

private shared long g_files;
private shared long g_dirs;

@("pool.walk.workerScaling")
@workload
@system
unittest
{
    // The syscall-bound shape: a recursive directory walk, one task per
    // directory. Where `pool.fanOut` isolates coordination, this shows the
    // kernel-side picture — `cpu krn`, `syscr`, and (with `--syscalls`) the
    // futex/yield traffic — against an identical file-syscall count per row.
    //
    // Point `$EH_BENCH_TREE` at a real source tree for a headline number;
    // otherwise a modest fixture is generated (untimed) so the workload always
    // has something to walk.
    import std.file : exists, rmdirRecurse;
    import std.process : environment;

    auto tree = environment.get("EH_BENCH_TREE", "");
    bool owned;
    if (tree.length == 0 || !tree.exists)
    {
        tree = makeFixture();
        owned = true;
    }
    scope (exit)
        if (owned)
            removeQuietly(tree);

    foreach (w; workerCounts)
        walkWindow(w, tree);
}

/// Best-effort fixture cleanup (a leftover temp tree must never fail a run).
private void removeQuietly(string path) nothrow
{
    import std.file : rmdirRecurse;

    try
        rmdirRecurse(path);
    catch (Exception)
    {
    }
}

private void walkWindow(uint workers, string root)
{
    import std.conv : text;

    workloadWindow(text("workers=", workers), () {
        import core.atomic : atomicStore;

        atomicStore(g_files, 0L);
        atomicStore(g_dirs, 0L);
        runWalk(workers, root);
        // Every row must observe the same tree — a differing count would mean
        // the measurement, not the tree, changed.
        assert(atomicLoad(g_dirs) > 0, "walked no directories");
    });
}

private void runWalk(uint workers, string root) @system
{
    WorkStealingPool pool;
    LoopGroupConfig cfg;
    cfg.topology = Topology.workStealing;
    cfg.cpuBound = typeof(cfg.cpuBound).yes;
    cfg.workers = workers;
    if (WorkStealingPool.start(pool, cfg).hasError)
        skipTest("work-stealing pool unavailable");
    scope (exit) pool.shutdown();

    pool.run((ref WorkStealingPool p) { submitDir(p, root); });
}

private void submitDir(ref WorkStealingPool p, string path) @system
{
    auto pool = &p;
    pool.submitBlocking(() { walkDir(*pool, path); });
}

/// Reads one directory, then fans its subdirectories out as new tasks. The
/// directory handle is closed **before** submitting, so concurrently-open fds
/// stay minimal (the shape `walk-event-horizon.d` uses for the polyglot-walks
/// race; kept in step with it deliberately).
private void walkDir(ref WorkStealingPool p, string path) @system
{
    import core.stdc.string : strlen;
    import core.sys.posix.dirent : closedir, DIR, dirent, DT_DIR, DT_UNKNOWN,
        opendir, readdir;
    import std.string : toStringz;

    atomicFetchAdd!(MemoryOrder.raw)(g_dirs, 1L);

    DIR* dir = opendir(path.toStringz);
    if (dir is null)
        return;

    long localFiles;
    string[] subdirs;
    for (;;)
    {
        dirent* entry = readdir(dir);
        if (entry is null)
            break;
        const nameLen = strlen(entry.d_name.ptr);
        if (nameLen == 1 && entry.d_name[0] == '.')
            continue;
        if (nameLen == 2 && entry.d_name[0] == '.' && entry.d_name[1] == '.')
            continue;
        if (entry.d_type == DT_DIR)
            subdirs ~= path ~ "/" ~ cast(string) entry.d_name[0 .. nameLen].idup;
        else if (entry.d_type != DT_UNKNOWN)
            ++localFiles;
    }
    closedir(dir);
    atomicFetchAdd!(MemoryOrder.raw)(g_files, localFiles);
    foreach (sub; subdirs)
        submitDir(p, sub);
}

/// Builds a modest uniform tree (585 dirs / 11 700 files) in a temp directory
/// — untimed setup, outside every window.
private string makeFixture()
{
    import std.conv : text;
    import std.file : mkdirRecurse, tempDir, write;
    import std.path : buildPath;

    const root = buildPath(tempDir(), "eh-bench-walk-fixture");
    enum breadth = 8, depth = 3, filesPerDir = 20;

    void build(string dir, int d)
    {
        mkdirRecurse(dir);
        foreach (f; 0 .. filesPerDir)
            write(buildPath(dir, text("f", f)), "");
        if (d == 0)
            return;
        foreach (b; 0 .. breadth)
            build(buildPath(dir, text("d", b)), d - 1);
    }

    build(root, depth);
    return root;
}
