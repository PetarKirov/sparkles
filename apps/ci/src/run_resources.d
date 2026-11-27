/**
A run's memory and disks (ci task-DAG CIC23, task-DAG PLAN M7 items 4 to 7):
the predicted peak of every action, the memory budget the executor admits
them under (TDM18), the gate that holds or cancels admission on memory
pressure and on a file system running out of room (TDM19), the limit each
process runs under (TDM20), and the free space a run reports.

Each decision is a pure function of what it reads, tested with what a host
would answer; the reads themselves (`statvfs`, PSI, `/proc`) are thin.
*/
module run_resources;

import core.time : MonoTime, msecs, seconds;
import std.conv : to;

import sparkles.build_graph.execute : MemoryPeak, RunResources, RunStats, memoryIdentity;
import sparkles.build_primitives.task.executor : AdmissionGate;
import sparkles.build_primitives.task.model : TaskNode;

enum ulong mib = 1UL << 20; ///
enum ulong gib = 1UL << 30; ///

/// The memory peaks recorded for each action identity (CIC23).
struct MemoryPeaks
{
    MemoryPeak[string] peaks; ///

    /**
    Parses `text`: one `<bytes> <identity>` per line, ` killed` after it when
    the bytes are the limit the action was killed at. A line that is not one,
    or records zero bytes, is skipped.
    */
    static MemoryPeaks parse(string text) @safe pure
    {
        import std.algorithm.iteration : splitter;
        import std.array : array;
        import std.string : lineSplitter;

        MemoryPeaks p;
        foreach (line; text.lineSplitter)
        {
            const fields = line.splitter(' ').array;
            if (fields.length < 2 || fields.length > 3 || fields.length == 3 && fields[2] != "killed")
                continue;
            ulong bytes;
            try
                bytes = fields[0].to!ulong;
            catch (Exception)
                continue;
            if (bytes)
                p.peaks[fields[1].idup] = MemoryPeak(bytes, fields.length == 3);
        }
        return p;
    }

    /// The text `parse` reads, sorted by identity.
    string text() const @safe pure
    {
        import std.algorithm.sorting : sort;
        import std.array : appender;

        auto keys = peaks.keys;
        keys.sort();
        auto s = appender!string;
        foreach (k; keys)
            s ~= peaks[k].bytes.to!string ~ " " ~ k ~ (peaks[k].killed ? " killed\n" : "\n");
        return s[];
    }

    /**
    Records a run's peaks: the larger of the old and the new for each, a kill
    recording the limit it was killed at, so the next limit is twice that,
    up to the run's ceiling (TDM20). Whether anything changed.
    */
    bool merge(const MemoryPeak[string] run) @safe pure
    {
        bool changed;
        foreach (k, v; run)
        {
            const old = k in peaks;
            const next = MemoryPeak(old && old.bytes > v.bytes ? old.bytes : v.bytes, v.killed);
            if (!old || *old != next)
            {
                peaks[k] = next;
                changed = true;
            }
        }
        return changed;
    }

    /// The prediction for the action `taskId`: its recorded peak, else its
    /// kind's default (CIC23).
    ulong predict(string taskId) const @safe pure
    {
        import std.algorithm.searching : canFind, startsWith;

        if (auto known = memoryIdentity(taskId) in peaks)
            return known.bytes;
        // Measured cold on pc2-local: a test root's compile peaks at 4.5–9.2 GB.
        if (taskId.startsWith("compile:") && taskId.canFind(":test-root:"))
            return 8 * gib;
        if (taskId.startsWith("compile:") || taskId.startsWith("link:"))
            return 2 * gib;
        // A test leg's workers together, a parallel leg's several.
        if (taskId.startsWith("test:"))
            return 4 * gib;
        return 512 * mib;
    }
}

///
@("run_resources.MemoryPeaks")
@safe pure unittest
{
    auto p = MemoryPeaks.parse("1048576 compile:sparkles.base:library:ldc\nnot a line\n7 link:sparkles.ci:test-root:ldc\n"
        ~ "0 compile:sparkles.zero:library:ldc\n9 a b c\n");
    assert(p.predict("compile:sparkles.base:library:ldc:0a7009e2bb3a") == mib, "a recorded peak, any digest");
    assert(p.predict("compile:sparkles.zero:library:ldc:abc") == 2 * gib, "a zero record is none");
    assert(p.predict("compile:sparkles.ui:test-root:ldc:abc") == 8 * gib, "a test root's compile");
    assert(p.predict("compile:sparkles.ui:library:ldc:abc") == 2 * gib);
    assert(p.predict("link:sparkles.ui:test-root:ldc:abc") == 2 * gib);
    assert(p.predict("test:sparkles.ui:test-root:ldc:8ef20d4bcc5f:parallel") == 4 * gib);
    assert(p.predict("archive:sparkles.ui:library:ldc:abc") == 512 * mib);
    assert(p.predict("generate:sparkles.ui:test-root:abc") == 512 * mib);
    assert(p.merge(["compile:sparkles.base:library:ldc": MemoryPeak(2 * mib), "link:sparkles.ci:test-root:ldc": MemoryPeak(3)]));
    assert(p.peaks["compile:sparkles.base:library:ldc"].bytes == 2 * mib && p.peaks["link:sparkles.ci:test-root:ldc"].bytes == 7,
        "the largest is kept");
    assert(!p.merge(["link:sparkles.ci:test-root:ldc": MemoryPeak(3)]), "nothing larger, nothing changed");
    // Killed at 1 GiB: the next prediction is that limit, so the next limit 2 GiB.
    assert(p.merge(["archive:x": MemoryPeak(gib, true)]) && p.predict("archive:x") == gib);
    assert(MemoryPeaks.parse(p.text).peaks == p.peaks);
}

/**
The memory budget (CIC23): `limit` (the memory limit of the cgroup that bounds
the run, or, unconfined, the memory available at the start) less `ci`'s
reserve, the larger of its resident set at the start and 2 GiB — what it grows
to over a run of every package — never more than half of `limit`. Zero
without a limit.
*/
ulong memoryBudget(ulong limit, ulong ciResident) @safe pure nothrow @nogc
{
    if (!limit)
        return 0;
    ulong reserve = ciResident > 2 * gib ? ciResident : 2 * gib;
    if (reserve > limit / 2)
        reserve = limit / 2;
    return limit - reserve;
}

///
@("run_resources.memoryBudget")
@safe pure nothrow @nogc unittest
{
    assert(memoryBudget(20 * gib, 3 * gib) == 17 * gib);
    assert(memoryBudget(20 * gib, 100 * mib) == 18 * gib, "at least 2 GiB for ci");
    assert(memoryBudget(2 * gib, 3 * gib) == gib, "never more than half");
    assert(memoryBudget(0, gib) == 0, "no limit, no budget");
}

/// One file system a run writes, as `statvfs` saw it.
struct DiskState
{
    string name;    /// a path on it, for the message
    ulong size;     /// bytes
    ulong free;     /// bytes available to this user
    bool hasStore;  /// the store is on it, so evicting frees room here
}

/// A file system's reserve and floor (CIC23): the smaller of 5 GiB and
/// 10 % of its size, and half that.
ulong diskReserve(ulong size) @safe pure nothrow @nogc => size / 10 < 5 * gib ? size / 10 : 5 * gib;

/// ditto
ulong diskFloor(ulong size) @safe pure nothrow @nogc => diskReserve(size) / 2;

/// `bytes` for a message: MiB below 1 GiB, else GiB with one decimal.
string sizeText(ulong bytes) @safe pure
{
    import std.format : format;

    return bytes < gib ? format!"%s MiB"(bytes / mib) : format!"%.1f GiB"(double(bytes) / gib);
}

///
@("run_resources.sizeText")
@safe pure unittest
{
    assert(sizeText(512 * mib) == "512 MiB", "a small tmpfs is not 0 GiB");
    assert(sizeText(3 * gib + gib / 2) == "3.5 GiB");
}

/**
The gate's answer (TDM19, CIC23) for the file systems `disks` and the memory
pressure `pressure` (PSI `some avg10`, in percent): a cancel under a floor, an
unbounded hold under a reserve, a bounded hold over 10 % pressure, else open.
*/
AdmissionGate decideGate(const DiskState[] disks, double pressure) @safe pure
{
    import std.conv : text;

    foreach (ref d; disks)
        if (d.free < diskFloor(d.size))
            return AdmissionGate(AdmissionGate.Kind.cancel, text(d.name, ": ", sizeText(d.free),
                " free, under its floor of ", sizeText(diskFloor(d.size))));
    foreach (ref d; disks)
        if (d.free < diskReserve(d.size))
            return AdmissionGate(AdmissionGate.Kind.holdUnbounded, text(d.name, ": ", sizeText(d.free),
                " free, under its reserve of ", sizeText(diskReserve(d.size))));
    if (pressure > 10)
        return AdmissionGate(AdmissionGate.Kind.holdBounded, text("memory pressure ", pressure, " %"));
    return AdmissionGate.init;
}

///
@("run_resources.decideGate")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    const roomy = DiskState("/home", 400 * gib, 100 * gib, true);
    assert(decideGate([roomy], 0).kind == AdmissionGate.Kind.open);
    assert(decideGate([roomy], 25).kind == AdmissionGate.Kind.holdBounded, "pressure holds, bounded");
    const tight = DiskState("/home", 400 * gib, 4 * gib, true);
    const g = decideGate([tight], 0);
    assert(g.kind == AdmissionGate.Kind.holdUnbounded && g.message.canFind("/home"), "under its reserve");
    const full = DiskState("/tmp", 400 * gib, 2 * gib, false);
    assert(decideGate([roomy, full], 0).kind == AdmissionGate.Kind.cancel, "under its floor, anywhere");
    assert(decideGate([full], 0).message.canFind("/tmp"), "the message names the file system");
    // A small tmpfs gets a small reserve: 1 GiB has 100 MiB.
    assert(diskReserve(gib) == gib / 10 && diskFloor(gib) == gib / 20);
    assert(decideGate([DiskState("/tmp", gib, 200 * mib)], 0).kind == AdmissionGate.Kind.open);
    assert(decideGate([DiskState("/tmp", gib, 40 * mib)], 0).message.canFind("40 MiB free"));
}

/// How far to evict the store's results to restore a reserve: the bytes to
/// free on a file system `free` short of `reserve`, none when it is not short.
ulong evictionDeficit(ulong free, ulong reserve) @safe pure nothrow @nogc
    => free >= reserve ? 0 : reserve - free;

/// The results' bound that frees `deficit` from `results` bytes of them: all
/// of them when they are fewer.
ulong evictionBound(ulong results, ulong deficit) @safe pure nothrow @nogc
    => results > deficit ? results - deficit : 0;

///
@("run_resources.evictionDeficit")
@safe pure nothrow @nogc unittest
{
    assert(evictionDeficit(3 * gib, 5 * gib) == 2 * gib);
    assert(evictionDeficit(6 * gib, 5 * gib) == 0, "not short");
    assert(evictionBound(10 * gib, 2 * gib) == 8 * gib);
    assert(evictionBound(gib, 2 * gib) == 0, "fewer results than the deficit: evict them all");
}

/// The results' bytes in `ci cache size`'s line, `<n> results, <bytes> bytes; …`;
/// zero when it is not one.
ulong resultBytesOf(string line) @safe pure
{
    import std.algorithm.searching : findSplitAfter, findSplitBefore;

    if (auto after = line.findSplitAfter(" results, "))
        if (auto bytes = after[1].findSplitBefore(" bytes"))
        {
            try
                return bytes[0].to!ulong;
            catch (Exception)
                return 0;
        }
    return 0;
}

///
@("run_resources.resultBytesOf")
@safe pure unittest
{
    assert(resultBytesOf("1378 results, 6119084032 bytes; records 965726711 bytes\n") == 6_119_084_032);
    assert(resultBytesOf("nothing") == 0);
}

/// `some avg10` of a PSI file's text, in percent; zero when absent.
double pressureOf(string text) @safe pure
{
    import std.algorithm.searching : findSplitAfter, startsWith;
    import std.string : lineSplitter, split;

    foreach (line; text.lineSplitter)
        if (line.startsWith("some "))
            foreach (field; line.split)
                if (auto kv = field.findSplitAfter("avg10="))
                {
                    try
                        return kv[1].to!double;
                    catch (Exception)
                        return 0;
                }
    return 0;
}

///
@("run_resources.pressureOf")
@safe pure unittest
{
    assert(pressureOf("some avg10=12.50 avg60=3.00 avg300=1.00 total=1\nfull avg10=2.00 avg60=0 avg300=0 total=1") == 12.5);
    assert(pressureOf("") == 0);
}

/// The resident set of a `/proc/<pid>/status` text, in bytes; zero when absent.
ulong residentOf(string status) @safe pure
{
    import core.checkedint : mulu;
    import std.string : lineSplitter, split, startsWith;

    foreach (line; status.lineSplitter)
        if (line.startsWith("VmRSS:"))
        {
            const fields = line.split;
            if (fields.length < 2)
                return 0;
            try
            {
                bool overflow;
                const bytes = mulu(fields[1].to!ulong, 1024UL, overflow);
                return overflow ? 0 : bytes;
            }
            catch (Exception)
                return 0;
        }
    return 0;
}

///
@("run_resources.residentOf")
@safe pure unittest
{
    assert(residentOf("Name:\tci\nVmRSS:\t  2048 kB\n") == 2 * mib);
    assert(residentOf("VmRSS:\n") == 0, "a short line is none, never a range error");
    assert(residentOf("") == 0);
}

/// The limit a cgroup's `memory.max` text sets; zero for `max` or none.
ulong limitOf(string text) @safe pure
{
    import std.string : strip;

    const t = text.strip;
    if (!t.length || t == "max")
        return 0;
    try
        return t.to!ulong;
    catch (Exception)
        return 0;
}

///
@("run_resources.limitOf")
@safe pure unittest
{
    assert(limitOf("25769803776\n") == 24 * gib);
    assert(limitOf("max\n") == 0 && limitOf("") == 0 && limitOf("lots") == 0);
}

version (linux):

/// What a run reads to bound its memory and disks, and the gate over them.
final class RunWatch
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;

    private string[] paths;         // a path on each file system the run writes
    private string storePath;       // the store's
    private string[] pressureFiles; // the bounding cgroup's, then the host's
    private string cache;           // the store's cache directory, for eviction
    private MonoTime lastAsked, lastEvicted;
    private bool asked, evictedOnce;
    private AdmissionGate last;
    private shared bool evicting;
    private Thread evictor;

    /**
    Watches the file systems of `storeDir`, `runDir` and the temporary
    directory, the store beneath `cacheDir`, and the memory pressure of the
    cgroup `limitCgroup` that bounds the run (the host's when it is empty or
    its file cannot be read).
    */
    this(string cacheDir, string storeDir, string runDir, string limitCgroup) @safe
    {
        import std.file : tempDir;

        cache = cacheDir;
        storePath = storeDir;
        paths = [storeDir, runDir, tempDir];
        pressureFiles = limitCgroup.length ? ["/sys/fs/cgroup" ~ limitCgroup ~ "/memory.pressure",
            "/proc/pressure/memory"] : ["/proc/pressure/memory"];
    }

    /**
    The file systems now, one per device: each path's deepest existing
    directory, so a run directory not made yet is watched where it will be.
    */
    DiskState[] disks() @safe
    {
        import std.path : dirName;

        DiskState[] all;
        ulong[] devices;
        foreach (p; paths)
        {
            ulong device;
            DiskState d;
            for (string at = p; at.length; at = at.dirName)
            {
                if (statPath(at, device, d.size, d.free))
                    break;
                if (at == at.dirName)
                    break;
            }
            if (!device && !d.size)
                continue;
            d.name = p;
            d.hasStore = p == storePath;
            bool seen;
            foreach (i, dev; devices)
                if (dev == device)
                {
                    all[i].hasStore |= d.hasStore;
                    seen = true;
                }
            if (seen)
                continue;
            devices ~= device;
            all ~= d;
        }
        return all;
    }

    /**
    The gate (TDM19): asked at most every 200 ms. Under a reserve on the
    store's file system it starts evicting the store down to what fits, on a
    thread of its own, at most every 30 seconds, and holds meanwhile.
    */
    AdmissionGate gate() @safe
    {
        import std.file : readText;

        const now = MonoTime.currTime;
        if (asked && now - lastAsked < 200.msecs)
            return last;
        asked = true;
        lastAsked = now;
        auto ds = disks();
        foreach (ref d; ds)
            if (d.hasStore && d.free < diskReserve(d.size) && !atomicLoad(evicting)
                && (!evictedOnce || now - lastEvicted > 30.seconds))
            {
                evictedOnce = true;
                lastEvicted = now;
                startEviction(evictionDeficit(d.free, diskReserve(d.size)));
                break;
            }
        double pressure = 0;
        foreach (file; pressureFiles)
        {
            try
            {
                pressure = pressureOf((() @trusted => readText(file))());
                break;
            }
            catch (Exception)
                continue;
        }
        last = decideGate(ds, pressure);
        return last;
    }

    /// The free space of each file system, for the run's report.
    string report() @safe
    {
        import std.conv : text;

        string s;
        foreach (ref d; disks())
            s ~= text(s.length ? "; " : "", d.name, " ", sizeText(d.free), " free of ", sizeText(d.size));
        return s;
    }

    /// Waits for an eviction the gate started.
    void finish() @safe
    {
        if (evictor !is null)
            (() @trusted => cast(void) evictor.join(false))();
        evictor = null;
    }

    // Evicts the store's results by `bytes`, freeing them (build graph BGS5,
    // CIC23), off the scheduler: its walks would stall every fiber.
    private void startEviction(ulong bytes) @safe
    {
        import std.array : appender;
        import std.conv : text;
        import sparkles.build_graph.execute : storeOperation;

        finish();
        atomicStore(evicting, true);
        const dir = cache;
        // `@trusted`: the thread reads only its own copy of the directory and
        // the shared flag.
        evictor = (() @trusted => new Thread({
            scope (exit)
                atomicStore(evicting, false);
            try
            {
                auto size = appender!string;
                cast(void) storeOperation(dir, "size", size);
                auto discard = appender!string;
                cast(void) storeOperation(dir, text("reclaim=", evictionBound(resultBytesOf(size[]), bytes)), discard);
            }
            catch (Exception)
            {
            }
        }))();
        (() @trusted { evictor.isDaemon = true; evictor.start(); })();
    }
}

// `statvfs` and `stat` of `path`: its device, size and free bytes; false when
// it does not exist or cannot be read.
private bool statPath(string path, out ulong device, out ulong size, out ulong free) @trusted
{
    import core.checkedint : mulu;
    import core.sys.posix.sys.stat : stat, stat_t;
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    import std.string : toStringz;

    const z = path.toStringz;
    statvfs_t vs;
    stat_t st;
    if (statvfs(z, &vs) != 0 || stat(z, &st) != 0)
        return false;
    const block = cast(ulong) (vs.f_frsize ? vs.f_frsize : vs.f_bsize);
    bool o1, o2;
    size = mulu(cast(ulong) vs.f_blocks, block, o1);
    free = mulu(cast(ulong) vs.f_bavail, block, o2);
    if (o1)
        size = ulong.max;
    if (o2)
        free = ulong.max;
    device = cast(ulong) st.st_dev;
    return true;
}

/**
The memory limit the run's budget starts from (CIC23): the `memory.max` of the
cgroup `limitCgroup` that bounds the run, else the memory available now.
*/
ulong memoryLimitOf(string limitCgroup) @safe
{
    import std.file : readText;
    import sparkles.base.hw_caps : hwAvailableMemoryBytes;

    if (limitCgroup.length)
        try
        {
            if (const limit = limitOf((() @trusted => readText("/sys/fs/cgroup" ~ limitCgroup ~ "/memory.max"))()))
                return limit;
        }
        catch (Exception)
        {
        }
    return (() @trusted => hwAvailableMemoryBytes())();
}

/// This process's resident set, in bytes.
ulong residentBytes() @safe
{
    import std.file : readText;

    try
        return residentOf((() @trusted => readText("/proc/self/status"))());
    catch (Exception)
        return 0;
}

/// The peaks file beneath the cache directory.
string peaksPath(string cacheDir) @safe pure => cacheDir ~ "/memory/peaks";

/// Reads the recorded peaks; none when the file is missing or unreadable.
MemoryPeaks loadPeaks(string cacheDir) @safe
{
    import std.file : readText;

    try
        return MemoryPeaks.parse((() @trusted => readText(peaksPath(cacheDir)))());
    catch (Exception)
        return MemoryPeaks.init;
}

/**
Records a run's peaks: the largest per identity, merged into what the file
holds under an exclusive lock on `peaks.lock`, so runs sharing the cache never
lose each other's, written to a temporary file of its own and renamed. Nothing
is written when the run measured nothing new.
*/
void savePeaks(string cacheDir, const RunStats[] stats) @safe
{
    import core.sys.posix.fcntl : F_SETLKW, F_WRLCK, O_CLOEXEC, O_CREAT, O_RDWR, fcntl, flock, open;
    import core.sys.posix.unistd : close;
    import std.file : exists, mkdirRecurse, remove, rename, write;
    import std.path : dirName;
    import std.process : thisProcessID;
    import std.random : uniform;
    import std.string : toStringz;

    bool any;
    foreach (ref st; stats)
        any |= st.memoryPeaks.length > 0;
    if (!any)
        return;
    const path = peaksPath(cacheDir);
    try
        mkdirRecurse(path.dirName);
    catch (Exception)
        return;
    const lockFd = (() @trusted => open((path ~ ".lock").toStringz, O_RDWR | O_CREAT | O_CLOEXEC, 420 /* 0o644 */))();
    if (lockFd < 0)
        return;
    scope (exit)
        (() @trusted => cast(void) close(lockFd))(); // releases the lock
    flock lock;
    lock.l_type = F_WRLCK;
    if ((() @trusted => fcntl(lockFd, F_SETLKW, &lock))() != 0)
        return;
    auto peaks = loadPeaks(cacheDir);
    bool changed;
    foreach (ref st; stats)
        changed |= peaks.merge(st.memoryPeaks);
    if (!changed)
        return;
    const tmp = path ~ "." ~ thisProcessID.to!string ~ "." ~ uniform!uint.to!string;
    try
    {
        scope (failure)
            if (exists(tmp))
                remove(tmp);
        write(tmp, peaks.text);
        rename(tmp, path);
    }
    catch (Exception)
    {
    }
}

/// Sets each node's prediction from `peaks` (CIC23).
void predict(TaskNode[] nodes, const ref MemoryPeaks peaks) @safe
{
    foreach (ref n; nodes)
    {
        n.resources.memoryBytes = peaks.predict(n.id.text);
        const known = memoryIdentity(n.id.text) in peaks.peaks;
        n.resources.memoryMeasured = known && known.bytes;
    }
}

/**
The resources of a run watched by `watch` (CIC23): its budget from the cgroup
that bounds it (`limitCgroup`, or the memory available), a gate over `watch`,
and, when its actions are accounted, limits at twice each prediction, never
above the budget.
*/
RunResources resourcesFor(RunWatch watch, string limitCgroup, bool accounted) @safe
{
    RunResources r;
    r.memoryBudget = memoryBudget(memoryLimitOf(limitCgroup), residentBytes());
    r.gate = &watch.gate;
    r.memoryLimitFactor = accounted ? 2 : 0;
    r.memoryLimitCeiling = r.memoryBudget;
    return r;
}
