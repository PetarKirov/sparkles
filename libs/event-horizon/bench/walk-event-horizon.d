#!/usr/bin/env dub
/+ dub.sdl:
    name "walk_event_horizon"
    dependency "sparkles:event-horizon" path="../../.."
    dependency "eh-bench-perf" path="perf"
    platforms "linux"
    targetPath "build"
    buildType "release"
+/
/**
 * The polyglot-walks benchmark walker on `sparkles:event-horizon` (PLAN M14).
 *
 * Recursively counts files and directories under a root, parallelized by the
 * work-stealing task pool: each directory is a task; a task reads its entries
 * (counting files, tallying its own dir), and submits each subdirectory as a
 * new task the pool distributes across workers — the same work-stealing shape
 * as the incumbent winner (Rust rayon's OS-thread work-stealing).
 *
 * Honest caveat (baked into the plan): `getdents` never got an io_uring
 * opcode, so the directory read is an ordinary syscall, not a ring op. This
 * walk therefore stresses the *scheduler* (task distribution + load balance)
 * and the syscall path, not the proactor — it measures event-horizon's
 * work-stealing engine against rayon's, which is exactly the interesting
 * comparison.
 *
 * Output contract (must match the other walkers exactly):
 *
 *     <N> file(s)
 *     <M> directories(s)
 *
 * Usage: `walk-event-horizon <root> [--perf] [--workers=N]`
 *
 * `--perf` opens a `perf_event_open` counter group with `inherit=1` (so the
 * pool's worker threads are counted too) around the whole walk and prints the
 * totals — instructions, cycles, IPC, and PAGE FAULTS — to stderr, keeping
 * stdout on the walker output contract. Comparing page faults across
 * `--workers` counts is the direct evidence for the per-worker-setup-weight
 * finding (`benchmarks.md` §2): each worker builds its own io_uring ring +
 * fiber stacks, so faults scale with the worker count.
 */
module walk_event_horizon;

import core.atomic : atomicFetchAdd, atomicLoad, MemoryOrder;
import core.stdc.string : strlen;
import core.sys.posix.dirent : closedir, DIR, dirent, DT_DIR, DT_UNKNOWN, opendir, readdir;
import core.sys.posix.sys.stat : lstat, S_IFDIR, S_IFMT, stat_t;

import std.stdio : writefln, stderr;
import std.string : toStringz;

import sparkles.event_horizon.group : LoopGroupConfig, Topology;
import sparkles.event_horizon.pool : WorkStealingPool;

shared long g_files;
shared long g_dirs;

version (unittest) {} else
int main(string[] argv)
{
    import std.algorithm : startsWith;
    import std.conv : to;

    string root;
    bool perf;
    uint workers;
    foreach (arg; argv[1 .. $])
    {
        if (arg == "--perf")
            perf = true;
        else if (arg.startsWith("--workers="))
            workers = arg["--workers=".length .. $].to!uint;
        else
            root = arg;
    }
    if (root.length == 0)
    {
        stderr.writefln("usage: %s <root> [--perf] [--workers=N]", argv[0]);
        return 2;
    }

    WorkStealingPool pool;
    LoopGroupConfig cfg;
    cfg.topology = Topology.workStealing;
    cfg.cpuBound = typeof(cfg.cpuBound).yes; // ring-less: the walk never parks on I/O
    cfg.workers = workers; // 0 = one per online CPU
    if (WorkStealingPool.start(pool, cfg).hasError)
    {
        stderr.writefln("SKIP: io_uring unavailable");
        return 0;
    }
    scope (exit) pool.shutdown();

    void walk()
    {
        pool.run((ref WorkStealingPool p) { submitDir(p, root); });
    }

    if (perf)
        walkUnderPerf(&walk, pool.workerCount);
    else
        walk();

    writefln("%d file(s)", atomicLoad(g_files));
    writefln("%d directories(s)", atomicLoad(g_dirs));
    return 0;
}

/// Runs `walk` once under a whole-process counter group (`inherit=1` folds in
/// the worker threads) and prints the totals to stderr.
version (unittest) {} else
void walkUnderPerf(scope void delegate() walk, uint workers)
{
    import perf : PerfGroup;

    auto pg = PerfGroup.tryOpen(true, /*inherit=*/true);
    if (!pg.available)
    {
        stderr.writefln("perf: %s", pg.status);
        walk();
        return;
    }
    scope (exit) pg.close();

    const s = pg.count(walk, () {}, 1); // one iteration: the whole walk
    stderr.writefln("perf (%s, %u workers, inherit): "
        ~ "%.0f instrs, %.0f cycles, IPC %.2f, %.0f page faults",
        pg.status, workers, s.instructions, s.cycles,
        s.cycles > 0 ? s.instructions / s.cycles : 0.0, s.pageFaults);
}

/// Submits one directory-walk task; captures `path` by value.
void submitDir(ref WorkStealingPool p, string path)
{
    auto pool = &p;
    pool.submitBlocking(() { walkDir(*pool, path); });
}

/// Walks one directory: count it, count its files, submit its subdirectories.
void walkDir(ref WorkStealingPool p, string path) @trusted
{
    atomicFetchAdd!(MemoryOrder.raw)(g_dirs, 1L);

    DIR* dir = opendir(path.toStringz);
    if (dir is null)
        return;
    scope (exit) closedir(dir);

    long localFiles;
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

        bool isDir;
        string full;
        const dtype = entry.d_type;
        if (dtype == DT_DIR)
            isDir = true;
        else if (dtype != DT_UNKNOWN)
            isDir = false;
        else
        {
            full = path ~ "/" ~ cast(string) entry.d_name[0 .. nameLen].idup;
            stat_t st;
            if (lstat(full.toStringz, &st) != 0)
                continue;
            isDir = (st.st_mode & S_IFMT) == S_IFDIR;
        }

        if (isDir)
        {
            if (full is null)
                full = path ~ "/" ~ cast(string) entry.d_name[0 .. nameLen].idup;
            submitDir(p, full); // a new task for the subtree
        }
        else
            ++localFiles;
    }
    atomicFetchAdd!(MemoryOrder.raw)(g_files, localFiles);
}

version (unittest)
private void cleanup(string path) @trusted nothrow
{
    import std.file : rmdirRecurse;

    try
        rmdirRecurse(path);
    catch (Exception)
    {
    }
}

@("walk.correctness.matchesFixture")
@system
unittest
{
    import core.atomic : atomicStore;
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.format : format;

    // A 10×10×10 fixture: 1000 files, 111 directories (root + 10 + 100).
    const base = "/tmp/sparkles-eh-walk-test";
    scope (exit)
        cleanup(base);
    foreach (i; 1 .. 11)
        foreach (j; 1 .. 11)
        {
            const d = format("%s/d%d/d%d", base, i, j);
            mkdirRecurse(d);
            foreach (k; 1 .. 11)
                write(format("%s/f%d", d, k), "");
        }

    WorkStealingPool pool;
    LoopGroupConfig cfg;
    cfg.topology = Topology.workStealing;
    cfg.workers = 4;
    if (WorkStealingPool.start(pool, cfg).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) pool.shutdown();

    atomicStore(g_files, 0L);
    atomicStore(g_dirs, 0L);
    pool.run((ref WorkStealingPool p) { submitDir(p, base); });

    assert(atomicLoad(g_files) == 1000, "file count");
    assert(atomicLoad(g_dirs) == 111, "directory count");
}
