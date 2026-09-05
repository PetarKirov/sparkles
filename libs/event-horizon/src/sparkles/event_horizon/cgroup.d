/**
cgroup v2 containment for supervised runs (SPEC §13.7): the tier probe and
the per-run lifecycle — create, migrate, kill, observe, clean up — with
every operation assigned to the lane its blocking cost belongs on.

A run owns one directory beneath the process's own (delegated) cgroup:
`<own>/eh-run-<pid>-<id>`. What that directory can do decides the tier:

$(TABLE
    $(TR $(TH tier) $(TH means) $(TH kill) $(TH observe))
    $(TR $(TD `none`) $(TD no owned directory (cgroup v1, no delegation, a
        read-only cgroupfs)) $(TD pgid only) $(TD `/proc` scan))
    $(TR $(TD `owned`) $(TD a directory with `cgroup.kill`, `cgroup.events`
        and `cgroup.procs`) $(TD pgid + `cgroup.kill`) $(TD members +
        `cpu.stat`, peaks from `/proc`))
    $(TR $(TD `accounted`) $(TD `owned`, and the memory and pids controllers
        are enabled for it) $(TD as `owned`) $(TD `memory.peak`, `pids.peak`
        exact for the run cgroup))
)

The probe is what exists, not what was asked for: `cgroup.subtree_control`
cannot be written on a cgroup that has processes (the no-internal-process
rule), so a library that finds itself in a populated cgroup — the ordinary
case — gets `owned`, and `accounted` only where the host prepared the
controllers for the delegated subtree.

Ownership is transactional: `dirCreated` is published the moment `mkdir`
succeeds, and whoever observes it owns the bottom-up cleanup, whatever
later failure lowered the tier. The `cgroup.kill` capability is a property
of the created directory, retained until cleanup — never inferred from a
membership snapshot. The `cgroup.events` `populated` bit is the only
recursive evidence (1 iff the cgroup or any descendant has a live process);
`cgroup.procs` lists direct members only and is accounting.

Lane assignment (§13.8): create and migrate run on the public lane and
degrade the run when refused; kill and cleanup run on the termination-
critical lane. The small reads over pre-opened descriptors are plain
`pread`s a caller performs where it sees fit.
*/
module sparkles.event_horizon.cgroup;

version (linux)  :

import core.stdc.errno : EAGAIN, EINVAL, ENOENT, errno;
import core.stdc.stdio : snprintf;
import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY, O_PATH, O_RDONLY, O_RDWR,
    O_WRONLY, open, openat;
import core.sys.posix.unistd : close, getpid, pread, write;
import core.time : Duration, MonoTime, msecs;

import sparkles.base.buffer : SharedBuffer;
import sparkles.event_horizon.blocking_pool : BlockingPool;
import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.sched : Sched;

extern (C) int mkdirat(int dirfd, const(char)* path, uint mode) nothrow @nogc;

/// What the run directory can do (see the module table).
enum CgroupTier : ubyte
{
    none,      /// no owned cgroup: pgid containment, `/proc` sampling
    owned,     /// kill / events / procs; counters from `/proc`
    accounted, /// plus controller-backed `memory.peak` / `pids.peak`
}

/// The `populated` evidence of the OWNED cgroup only (SPEC §13.7): it
/// drives `wait`, telemetry, and cleanup — never whether a kill is issued.
enum TreeEvidence : ubyte
{
    empty,     /// `populated 0` was read: no live process in the subtree
    populated, /// `populated 1`
    unknown,   /// the read failed — never treated as empty
}

/// One run's cgroup: descriptors, identity, and the ownership bits.
/// Non-copyable: the descriptors are owned.
struct CgroupRun
{
    @disable this(this);

    CgroupTier tier;
    bool dirCreated;  /// the run directory exists and cleanup is ours
    IoError degradedBy; /// the first failure that lowered the tier

    int dirFd = -1;        /// `O_PATH` handle of the run directory
    int killFd = -1;       /// `cgroup.kill`, write
    int eventsFd = -1;     /// `cgroup.events`, read
    int procsFd = -1;      /// `cgroup.procs`, read + write
    int cpuStatFd = -1;    /// `cpu.stat`, read (present on every v2 cgroup)
    int memoryPeakFd = -1; /// `memory.peak` (`accounted` only)
    int pidsPeakFd = -1;   /// `pids.peak` (`accounted` only)

    /// The run's path as `/proc/<pid>/cgroup` spells it — the membership
    /// boundary: a member's line equals it or continues with `/` right after.
    SharedBuffer!(char, 256) path;
    /// The absolute cgroupfs path of the run directory.
    SharedBuffer!(char, 320) sysPath;

    /// `true` while the run owns a directory with the kill capability.
    bool canKill() const @safe pure nothrow @nogc => killFd >= 0;

    /// Closes every descriptor; leaves `dirCreated` — the directory itself
    /// is only released by `cleanup`.
    void closeAll() @trusted nothrow @nogc
    {
        static void drop(ref int fd) nothrow @nogc
        {
            if (fd >= 0)
                close(fd);
            fd = -1;
        }

        drop(killFd);
        drop(eventsFd);
        drop(procsFd);
        drop(cpuStatFd);
        drop(memoryPeakFd);
        drop(pidsPeakFd);
        drop(dirFd);
    }
}

// ── the worker-side primitives (nothrow; run on a pool thread) ──────────────

/// Reads the calling process's own cgroup v2 path (the `0::` line of
/// `/proc/self/cgroup`) into `into`; `false` on a v1-only or unreadable host.
private bool ownCgroupPath(ref SharedBuffer!(char, 256) into) @trusted nothrow
{
    char[4096] buf = void;
    const fd = open("/proc/self/cgroup", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    scope (exit) close(fd);
    auto n = pread(fd, buf.ptr, buf.length, 0);
    if (n <= 0)
        return false;
    const(char)[] text = buf[0 .. n];
    while (text.length)
    {
        size_t eol;
        while (eol < text.length && text[eol] != '\n')
            ++eol;
        const line = text[0 .. eol];
        text = eol < text.length ? text[eol + 1 .. $] : null;
        if (line.length >= 4 && line[0 .. 3] == "0::")
        {
            into.length = 0;
            into ~= line[3 .. $];
            return true;
        }
    }
    return false;
}

/// Opens `name` under `dirFd`; -1 with `errno` set on failure.
private int openUnder(int dirFd, const(char)* name, int flags) @trusted nothrow @nogc
    => openat(dirFd, name, flags | O_CLOEXEC);

/**
Creates the run cgroup and probes its tier (the pre-spawn job; public
lane). Every acquired resource is published independently — `dirCreated`
first — so any failure leaves a truthful partial state whose cleanup the
caller owns.
*/
package void createRun(ref CgroupRun run, uint runId,
    bool injectControlOpenFailure = false) @trusted nothrow
{
    static void degrade(ref CgroupRun run, int err, string why) nothrow @nogc
    {
        run.tier = CgroupTier.none;
        if (run.degradedBy.errnoValue == 0 && run.degradedBy.context is null)
            run.degradedBy = IoError(err, OpKind.none, IoErrorStage.setup, why);
    }

    SharedBuffer!(char, 256) own;
    if (!ownCgroupPath(own))
        return degrade(run, ENOENT, "cgroup: no v2 path for this process");

    run.sysPath.length = 0;
    run.sysPath ~= "/sys/fs/cgroup";
    run.sysPath ~= own[];
    run.sysPath ~= '\0';
    const parentFd = open(run.sysPath[].ptr, O_PATH | O_DIRECTORY | O_CLOEXEC);
    run.sysPath.length = run.sysPath.length - 1;
    if (parentFd < 0)
        return degrade(run, errno, "cgroup: cannot open the process's own cgroup");
    scope (exit) close(parentFd);

    char[64] name = void;
    const nameLen = snprintf(name.ptr, name.length, "eh-run-%d-%u",
        cast(int) getpid(), runId);
    if (nameLen <= 0 || nameLen >= name.length)
        return degrade(run, EINVAL, "cgroup: run name overflow");

    if (mkdirat(parentFd, name.ptr, 493 /* 0o755 */) != 0)
        return degrade(run, errno, "cgroup: mkdir of the run directory refused");
    // From here the directory exists and its cleanup is the caller's.
    run.dirCreated = true;
    run.path.length = 0;
    run.path ~= own[];
    run.path ~= '/';
    run.path ~= name[0 .. nameLen];
    run.sysPath ~= '/';
    run.sysPath ~= name[0 .. nameLen];

    run.dirFd = openUnder(parentFd, name.ptr, O_PATH | O_DIRECTORY);
    if (run.dirFd < 0)
        return degrade(run, errno, "cgroup: cannot open the run directory");

    // Fault injection (tests): the "dirCreated but degraded" state.
    if (injectControlOpenFailure)
        return degrade(run, 5 /* EIO */, "cgroup: injected control-open failure");
    run.killFd = openUnder(run.dirFd, "cgroup.kill", O_WRONLY);
    if (run.killFd < 0)
        return degrade(run, errno, "cgroup: cgroup.kill unavailable");
    run.eventsFd = openUnder(run.dirFd, "cgroup.events", O_RDONLY);
    if (run.eventsFd < 0)
    {
        const err = errno;
        run.closeAll();
        return degrade(run, err, "cgroup: cgroup.events unavailable");
    }
    run.procsFd = openUnder(run.dirFd, "cgroup.procs", O_RDWR);
    if (run.procsFd < 0)
    {
        const err = errno;
        run.closeAll();
        return degrade(run, err, "cgroup: cgroup.procs unavailable");
    }
    run.tier = CgroupTier.owned;

    run.cpuStatFd = openUnder(run.dirFd, "cpu.stat", O_RDONLY); // optional
    run.memoryPeakFd = openUnder(run.dirFd, "memory.peak", O_RDONLY);
    run.pidsPeakFd = openUnder(run.dirFd, "pids.peak", O_RDONLY);
    if (run.memoryPeakFd >= 0 && run.pidsPeakFd >= 0)
        run.tier = CgroupTier.accounted;
    else
    {
        // Half an accounted tier is no tier: keep both or neither.
        if (run.memoryPeakFd >= 0)
            close(run.memoryPeakFd);
        if (run.pidsPeakFd >= 0)
            close(run.pidsPeakFd);
        run.memoryPeakFd = run.pidsPeakFd = -1;
    }
}

/// Moves `pid` (all its threads) into the run cgroup; 0 or errno.
package int migrateInto(ref CgroupRun run, int pid) @trusted nothrow @nogc
{
    if (run.procsFd < 0)
        return EINVAL;
    char[24] buf = void;
    const n = snprintf(buf.ptr, buf.length, "%d\n", pid);
    return write(run.procsFd, buf.ptr, n) == n ? 0 : errno;
}

/// Writes `cgroup.kill`: SIGKILL to every process in the subtree, inside
/// one kernel write; an empty subtree is an idempotent success. 0 or errno.
package int killTree(ref CgroupRun run) @trusted nothrow @nogc
{
    if (run.killFd < 0)
        return EINVAL;
    return write(run.killFd, "1".ptr, 1) == 1 ? 0 : errno;
}

/// Parses `cgroup.events` text.
package TreeEvidence parsePopulated(scope const(char)[] text)
    @safe pure nothrow @nogc
{
    foreach (line; lines(text))
        if (line.length >= 11 && line[0 .. 10] == "populated ")
            return line[10] == '0' ? TreeEvidence.empty : TreeEvidence.populated;
    return TreeEvidence.unknown;
}

/// Reads the run's `populated` bit.
package TreeEvidence readPopulated(ref CgroupRun run) @trusted nothrow @nogc
{
    if (run.eventsFd < 0)
        return TreeEvidence.unknown;
    char[128] buf = void;
    const n = pread(run.eventsFd, buf.ptr, buf.length, 0);
    return n <= 0 ? TreeEvidence.unknown : parsePopulated(buf[0 .. n]);
}

/// The run cgroup's cumulative CPU (`cpu.stat`), in microseconds.
package struct CgroupCpu
{
    ulong userUsec;
    ulong systemUsec;
    bool ok;
}

/// Parses `cpu.stat` text.
package CgroupCpu parseCpuStat(scope const(char)[] text) @safe pure nothrow @nogc
{
    CgroupCpu cpu;
    bool user, system;
    foreach (line; lines(text))
    {
        if (line.length > 10 && line[0 .. 10] == "user_usec ")
            user = parseUlong(line[10 .. $], cpu.userUsec);
        else if (line.length > 12 && line[0 .. 12] == "system_usec ")
            system = parseUlong(line[12 .. $], cpu.systemUsec);
    }
    cpu.ok = user && system;
    return cpu;
}

/// Reads `cpu.stat`.
package CgroupCpu readCpuStat(ref CgroupRun run) @trusted nothrow @nogc
{
    if (run.cpuStatFd < 0)
        return CgroupCpu.init;
    char[512] buf = void;
    const n = pread(run.cpuStatFd, buf.ptr, buf.length, 0);
    return n <= 0 ? CgroupCpu.init : parseCpuStat(buf[0 .. n]);
}

/// Reads one unsigned counter file (`memory.peak`, `pids.peak`).
package bool readCounter(int fd, out ulong value) @trusted nothrow @nogc
{
    if (fd < 0)
        return false;
    char[64] buf = void;
    const n = pread(fd, buf.ptr, buf.length, 0);
    return n > 0 && parseUlong(buf[0 .. n], value);
}

/**
Lists the run cgroup's DIRECT members (accounting only — nested cgroups
hold theirs elsewhere; `populated` is the recursive truth). `sink` receives
each pid; `truncated` reports a listing the bounded read could not finish.
*/
package void listMembers(ref CgroupRun run, scope void delegate(int pid) nothrow sink,
    out bool truncated) @trusted nothrow
{
    truncated = false;
    if (run.procsFd < 0)
        return;
    // One pread of a bounded window: a roster that does not fit is reported
    // as truncated rather than walked without limit.
    char[16 * 1024] buf = void;
    const n = pread(run.procsFd, buf.ptr, buf.length, 0);
    if (n <= 0)
        return;
    truncated = n == buf.length;
    foreach (line; lines(buf[0 .. n]))
    {
        ulong pid;
        if (line.length && parseUlong(line, pid) && pid <= int.max)
            sink(cast(int) pid);
    }
}

/**
The cleanup job (termination-critical lane): waits — deadline-bounded, on
the `cgroup.events` descriptor, never by polling the scheduler — for the
subtree to read `populated 0`, then removes nested cgroups bottom-up and
the run directory itself. `leaked` reports a directory that remained;
every descriptor is closed either way. Finite by construction: the wait
has a deadline, the walk has depth and entry bounds.
*/
package void cleanupRun(ref CgroupRun run, Duration populatedDeadline,
    out bool leaked, out int failure) @trusted nothrow
{
    leaked = false;
    failure = 0;
    scope (exit) run.closeAll();
    if (!run.dirCreated)
        return;

    if (run.eventsFd >= 0)
        waitUnpopulated(run.eventsFd, populatedDeadline);

    run.sysPath ~= '\0';
    scope (exit) run.sysPath.length = run.sysPath.length - 1;
    failure = removeTree(run.sysPath[], 0);
    leaked = failure != 0;
    if (!leaked)
        run.dirCreated = false;
}

/// One bounded evidence wait (public lane): parks the worker on `POLLPRI`
/// of `cgroup.events` for at most `slice`, then reports what `populated`
/// reads — `empty` is authoritative at that instant only (SPEC §13.7).
package TreeEvidence waitEvidence(ref CgroupRun run, Duration slice) @trusted nothrow @nogc
{
    if (run.eventsFd < 0)
        return TreeEvidence.unknown;
    waitUnpopulated(run.eventsFd, slice);
    return readPopulated(run);
}

/// The evidence job's context and body.
package struct EvidenceJob
{
    CgroupRun* run;
    Duration slice;
    TreeEvidence evidence;
}

/// ditto
package void evidenceCall(void* p) nothrow
{
    auto job = cast(EvidenceJob*) p;
    job.evidence = waitEvidence(*job.run, job.slice);
}

/// Parks the worker on `POLLPRI` of `cgroup.events` until `populated 0`
/// or the deadline; a spurious wake re-reads and re-arms.
private void waitUnpopulated(int eventsFd, Duration deadline) @trusted nothrow @nogc
{
    import core.sys.posix.poll : POLLPRI, poll, pollfd;

    const until = MonoTime.currTime + deadline;
    for (;;)
    {
        char[128] buf = void;
        const n = pread(eventsFd, buf.ptr, buf.length, 0);
        if (n <= 0 || parsePopulated(buf[0 .. n]) != TreeEvidence.populated)
            return;
        const left = until - MonoTime.currTime;
        if (left <= Duration.zero)
            return;
        pollfd pfd = {fd: eventsFd, events: POLLPRI};
        const ms = left.total!"msecs";
        cast(void) poll(&pfd, 1, ms > int.max ? int.max : cast(int) ms);
    }
}

/// Removes `dirZ` (NUL-terminated) and its nested cgroups, deepest first;
/// 0 or the errno of the final `rmdir`. Bounded depth and fan-out.
private int removeTree(scope const(char)[] dirZ, uint depth) @trusted nothrow
{
    import core.stdc.string : strlen;
    import core.sys.posix.dirent : DT_DIR, closedir, dirent, opendir, readdir;
    import core.sys.posix.unistd : rmdir;

    enum maxDepth = 16;
    enum maxEntries = 1024;
    if (depth < maxDepth)
    {
        auto dir = opendir(dirZ.ptr);
        if (dir !is null)
        {
            scope (exit) closedir(dir);
            uint seen;
            for (dirent* ent = readdir(dir); ent !is null && seen < maxEntries;
                ent = readdir(dir))
            {
                ++seen;
                if (ent.d_type != DT_DIR)
                    continue;
                const name = ent.d_name.ptr[0 .. strlen(ent.d_name.ptr)];
                if (name == "." || name == "..")
                    continue;
                SharedBuffer!(char, 512) child;
                child ~= dirZ[0 .. $ - 1];
                child ~= '/';
                child ~= name;
                child ~= '\0';
                cast(void) removeTree(child[], depth + 1);
            }
        }
    }
    return rmdir(dirZ.ptr) == 0 ? 0 : errno;
}

// ── the lane-assigned fiber surface ─────────────────────────────────────────

private struct CreateJob
{
    CgroupRun* run;
    uint runId;
    bool injectControlOpenFailure;
}

private void createCall(void* p) nothrow
{
    auto job = cast(CreateJob*) p;
    createRun(*job.run, job.runId, job.injectControlOpenFailure);
}

private struct MigrateJob
{
    CgroupRun* run;
    int pid;
    int result;
}

private void migrateCall(void* p) nothrow
{
    auto job = cast(MigrateJob*) p;
    job.result = migrateInto(*job.run, job.pid);
}

private struct KillJob
{
    CgroupRun* run;
    int result;
}

private void killCall(void* p) nothrow
{
    auto job = cast(KillJob*) p;
    job.result = killTree(*job.run);
}

private struct CleanupJob
{
    CgroupRun* run;
    Duration populatedDeadline;
    bool leaked;
    int failure;
}

private void cleanupCall(void* p) nothrow
{
    auto job = cast(CleanupJob*) p;
    cleanupRun(*job.run, job.populatedDeadline, job.leaked, job.failure);
}

/**
Creates the run cgroup on the public lane. A refused submission (`EAGAIN`)
degrades the run to `none` before any child exists — it is not an error of
the supervision; only a pool that cannot be used at all (`EPIPE`, or a
caller already interrupted) is returned as one.
*/
package IoResult!void cgroupCreate(ref Sched s, BlockingPool* pool,
    ref CgroupRun run, uint runId, bool injectControlOpenFailure = false) @trusted
{
    CreateJob job = {run: &run, runId: runId,
        injectControlOpenFailure: injectControlOpenFailure};
    auto r = pool.run(s, &createCall, &job);
    if (r.hasError && r.error.errnoValue == EAGAIN)
    {
        run.tier = CgroupTier.none;
        run.degradedBy = r.error;
        return ioOk();
    }
    return r;
}

/// Migrates `pid` into the run cgroup on the public lane; failure — a
/// refused submission included — degrades that run's sampling tier only
/// (the pgid belt is already armed) and is returned for the caller to
/// record.
package IoResult!void cgroupMigrate(ref Sched s, BlockingPool* pool,
    ref CgroupRun run, int pid) @trusted
{
    MigrateJob job = {run: &run, pid: pid};
    auto r = pool.run(s, &migrateCall, &job);
    if (r.hasError)
        return r;
    if (job.result != 0)
        return ioErr!void(job.result, OpKind.none, IoErrorStage.submit,
            "cgroup: migration into the run cgroup failed");
    return ioOk();
}

/// Writes `cgroup.kill` on the termination-critical lane.
package IoResult!void cgroupKill(ref Sched s, BlockingPool* pool,
    ref CgroupRun run) @trusted
{
    KillJob job = {run: &run};
    auto r = pool.runMandatory(s, &killCall, &job);
    if (r.hasError)
        return r;
    if (job.result != 0)
        return ioErr!void(job.result, OpKind.none, IoErrorStage.submit,
            "cgroup: cgroup.kill failed");
    return ioOk();
}

/// Runs the cleanup job on the termination-critical lane; the value is
/// `leaked`. Completes before the caller reads its final fields.
package IoResult!bool cgroupCleanup(ref Sched s, BlockingPool* pool,
    ref CgroupRun run, Duration populatedDeadline = 2.seconds) @trusted
{
    CleanupJob job = {run: &run, populatedDeadline: populatedDeadline};
    auto r = pool.runMandatory(s, &cleanupCall, &job);
    if (r.hasError)
        return ioErr!bool(r.error);
    return ioOk(job.leaked);
}

// ── text helpers ────────────────────────────────────────────────────────────

import core.time : seconds;

/// A line range over borrowed text (no allocation; trailing newline
/// optional).
private struct Lines
{
    const(char)[] rest;
    const(char)[] front;
    bool empty = true;

    void popFront() scope @safe pure nothrow @nogc
    {
        if (rest.length == 0)
        {
            empty = true;
            return;
        }
        size_t eol;
        while (eol < rest.length && rest[eol] != '\n')
            ++eol;
        front = rest[0 .. eol];
        rest = eol < rest.length ? rest[eol + 1 .. $] : null;
        empty = false;
    }
}

/// ditto
private Lines lines(return scope const(char)[] text) @safe pure nothrow @nogc
{
    Lines l = {rest: text};
    l.popFront();
    return l;
}

/// Parses a decimal unsigned integer with optional surrounding whitespace.
private bool parseUlong(scope const(char)[] text, out ulong value)
    @safe pure nothrow @nogc
{
    size_t i;
    while (i < text.length && (text[i] == ' ' || text[i] == '\n'))
        ++i;
    size_t digits;
    ulong v;
    for (; i < text.length && text[i] >= '0' && text[i] <= '9'; ++i, ++digits)
    {
        if (v > (ulong.max - (text[i] - '0')) / 10)
            return false;
        v = v * 10 + (text[i] - '0');
    }
    while (i < text.length && (text[i] == ' ' || text[i] == '\n'))
        ++i;
    if (digits == 0 || i != text.length)
        return false;
    value = v;
    return true;
}

// ── tests ───────────────────────────────────────────────────────────────────

@("cgroup.parse.eventsCpuStatAndCounters")
@safe pure nothrow @nogc
unittest
{
    assert(parsePopulated("populated 1\nfrozen 0\n") == TreeEvidence.populated);
    assert(parsePopulated("populated 0\nfrozen 0") == TreeEvidence.empty);
    assert(parsePopulated("frozen 0\n") == TreeEvidence.unknown);
    assert(parsePopulated("") == TreeEvidence.unknown);

    const cpu = parseCpuStat(
        "usage_usec 30\nuser_usec 12\nsystem_usec 18\nnr_periods 0\n");
    assert(cpu.ok && cpu.userUsec == 12 && cpu.systemUsec == 18);
    assert(!parseCpuStat("usage_usec 30\n").ok);

    ulong v;
    assert(parseUlong("42\n", v) && v == 42);
    assert(parseUlong(" 7 ", v) && v == 7);
    assert(!parseUlong("", v));
    assert(!parseUlong("4x", v));
    assert(!parseUlong("18446744073709551616", v), "overflow is rejected");
}

version (unittest)
{
    import core.sys.posix.signal : SIGKILL;
    import core.sys.posix.sys.stat : stat, stat_t;

    import sparkles.event_horizon.blocking_pool : sharedBlockingPool;
    import sparkles.event_horizon.live : ChildProcess, spawnProcess, wait;
    import sparkles.event_horizon.sched : schedOrSkip;
    import sparkles.test_runner.skip : skipTest;

    /// Whether the run directory exists on cgroupfs.
    private bool runDirExists(ref CgroupRun run) @trusted
    {
        import std.string : toStringz;

        stat_t st;
        return stat(run.sysPath[].toStringz, &st) == 0;
    }

    /// Creates a run on the shared pool, skipping the test on a host with
    /// no owned tier.
    private BlockingPool* createOrSkip(ref Sched s, ref CgroupRun run, uint id)
    {
        auto pool = sharedBlockingPool();
        assert(!pool.hasError);
        assert(!cgroupCreate(s, pool.value, run, id).hasError);
        if (run.tier == CgroupTier.none)
        {
            // A refused mkdir leaves nothing; a degraded run still owns it.
            if (run.dirCreated)
                cast(void) cgroupCleanup(s, pool.value, run, 10.msecs);
            skipTest(run.degradedBy.context is null
                ? "no owned cgroup v2 directory on this host"
                : run.degradedBy.context);
        }
        return pool.value;
    }
}

@("cgroup.lifecycle.createProbesATierAndCleanupRemovesTheDirectory")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        CgroupRun run;
        auto pool = createOrSkip(s, run, 900_001);
        assert(run.dirCreated && run.dirFd >= 0 && run.canKill);
        assert(run.eventsFd >= 0 && run.procsFd >= 0);
        assert(runDirExists(run), "the run directory exists");
        assert(run.path[].length > 8 && run.sysPath[][0 .. 14] == "/sys/fs/cgroup");
        assert(readPopulated(run) == TreeEvidence.empty, "a fresh run is empty");
        assert(readCpuStat(run).ok, "cpu.stat exists on every v2 cgroup");

        auto cleaned = cgroupCleanup(s, pool, run, 100.msecs);
        assert(!cleaned.hasError && !cleaned.value, "an empty run is removed");
        assert(!run.dirCreated && run.dirFd < 0 && run.killFd < 0);
        assert(!runDirExists(run), "the directory is gone");
    });
    assert(!r.hasError);
}

@("cgroup.lifecycle.migrateKillAndCleanupContainTheChild")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        CgroupRun run;
        auto pool = createOrSkip(s, run, 900_002);

        auto spawned = spawnProcess(["sleep", "30"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(!cgroupMigrate(s, pool, run, child.pid).hasError);
        assert(readPopulated(run) == TreeEvidence.populated);
        bool seen, truncated;
        listMembers(run, (int pid) nothrow { seen |= pid == child.pid; }, truncated);
        assert(seen && !truncated, "the migrated child is a direct member");

        assert(!cgroupKill(s, pool, run).hasError);
        auto st = wait(s, child);
        assert(st.hasValue && st.value.signaled && st.value.code == SIGKILL,
            "cgroup.kill ended the child");

        auto cleaned = cgroupCleanup(s, pool, run, 2.seconds);
        assert(!cleaned.hasError && !cleaned.value, "the emptied run is removed");
        assert(!runDirExists(run));
    });
    assert(!r.hasError);
}

@("cgroup.cleanup.reportsALeakWhileStillPopulated")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        CgroupRun run;
        auto pool = createOrSkip(s, run, 900_003);
        auto spawned = spawnProcess(["sleep", "30"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(!cgroupMigrate(s, pool, run, child.pid).hasError);

        // A deadline-bounded wait that expires reports the truth: the
        // directory could not be removed and remains ours to account for.
        const started = MonoTime.currTime;
        auto cleaned = cgroupCleanup(s, pool, run, 50.msecs);
        assert(!cleaned.hasError && cleaned.value, "leaked while populated");
        assert(MonoTime.currTime - started < 5.seconds, "the wait is bounded");
        assert(run.dirCreated && runDirExists(run));

        // End the child by pgid-free means and finish the cleanup by hand:
        // the leftover directory must not outlive the test.
        assert(!child.kill(SIGKILL).hasError);
        assert(wait(s, child).hasValue);
        bool leaked;
        int failure;
        run.dirCreated = true;
        cleanupRun(run, 2.seconds, leaked, failure);
        assert(!leaked && !runDirExists(run));
    });
    assert(!r.hasError);
}

@("cgroup.nested.killReachesANestedMemberAndCleanupIsBottomUp")
@system
unittest
{
    import std.string : toStringz;

    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        CgroupRun run;
        auto pool = createOrSkip(s, run, 900_004);
        // A descendant that made itself a nested cgroup: the run's own
        // procs file lists nothing, populated still says 1.
        assert(mkdirat(run.dirFd, "nested", 493) == 0);
        auto spawned = spawnProcess(["sleep", "30"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        {
            const nestedProcs = openat(run.dirFd, "nested/cgroup.procs", O_WRONLY | O_CLOEXEC);
            assert(nestedProcs >= 0);
            scope (exit) close(nestedProcs);
            char[24] buf = void;
            const n = snprintf(buf.ptr, buf.length, "%d\n", child.pid);
            assert(write(nestedProcs, buf.ptr, n) == n);
        }
        bool seen, truncated;
        listMembers(run, (int pid) nothrow { seen |= pid == child.pid; }, truncated);
        assert(!seen, "a nested member is not a direct member");
        assert(readPopulated(run) == TreeEvidence.populated,
            "populated is the recursive truth");

        assert(!cgroupKill(s, pool, run).hasError, "kill descends into nested cgroups");
        auto st = wait(s, child);
        assert(st.hasValue && st.value.signaled);

        auto cleaned = cgroupCleanup(s, pool, run, 2.seconds);
        assert(!cleaned.hasError && !cleaned.value,
            "the nested directory is removed first, then the run");
        assert(!runDirExists(run));
    });
    assert(!r.hasError);
}

@("cgroup.create.faultAfterMkdirKeepsOwnershipAndCleanupRemovesIt")
@system
unittest
{
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        auto pool = sharedBlockingPool();
        assert(!pool.hasError);
        CgroupRun run;
        assert(!cgroupCreate(s, pool.value, run, 900_005, true).hasError);
        if (!run.dirCreated)
            skipTest("no owned cgroup v2 directory on this host");
        assert(run.tier == CgroupTier.none && !run.canKill,
            "the failed control opens lowered the tier");
        assert(run.degradedBy.errnoValue == 5);
        assert(runDirExists(run), "…but the directory is ours");
        auto cleaned = cgroupCleanup(s, pool.value, run, 100.msecs);
        assert(!cleaned.hasError && !cleaned.value);
        assert(!runDirExists(run), "no run directory is ever leaked");
    });
    assert(!r.hasError);
}
