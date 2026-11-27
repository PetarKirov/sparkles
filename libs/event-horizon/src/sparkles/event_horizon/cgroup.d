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

import core.lifetime : move;
import core.stdc.errno : EAGAIN, EINVAL, ENOENT, errno;
import core.stdc.stdio : snprintf;
import core.sys.posix.unistd : close, getpid, pread, write;
import core.time : Duration, MonoTime, msecs;

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.vfs : EntryKind, OpenMode, PosixMode, Rights, ambientAuthority,
    openRoot;
import sparkles.event_horizon.blocking_pool : BlockingPool;
import sparkles.event_horizon.errors : ioError, IoError, IoErrorStage, IoResult, OpKind,
    ioErr, ioOk;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.sys : BlockingVfs;

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

    int killFd = -1;       /// `cgroup.kill`, write
    int eventsFd = -1;     /// `cgroup.events`, read
    int procsFd = -1;      /// `cgroup.procs`, read + write
    int cpuStatFd = -1;    /// `cpu.stat`, read (present on every v2 cgroup)
    int memoryPeakFd = -1; /// `memory.peak` (`accounted` only)
    int pidsPeakFd = -1;   /// `pids.peak` (`accounted` only)
    int memoryEventsFd = -1;      /// `memory.events`, read, when a memory limit is set
    int memoryEventsLocalFd = -1; /// `memory.events.local`, read, ditto
    /// The run directory itself, for a child spawned into it (`CLONE_INTO_CGROUP`).
    int dirFd = -1;
    /// Whether the run's `memory.max` and `memory.oom.group` were set (§13.7).
    bool memoryLimitSet;

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
        drop(memoryEventsFd);
        drop(memoryEventsLocalFd);
        drop(dirFd);
    }
}

// ── the worker-side primitives (nothrow; run on a pool thread) ──────────────

/// Reads the calling process's own cgroup v2 path (the `0::` line of
/// `/proc/self/cgroup`) into `into`; `false` on a v1-only or unreadable host.
private bool ownCgroupPath(ref SharedBuffer!(char, 256) into) @trusted nothrow
{
    BlockingVfs vfs;
    auto self = openRoot!(Rights.readOnly)(&vfs, "/proc/self", ambientAuthority());
    if (self.hasError)
        return false;
    auto file = self.value.openFile!(OpenMode.read)("cgroup");
    if (file.hasError)
        return false;
    char[4096] buf = void;
    auto n = file.value.read(cast(ubyte[]) buf[]);
    if (n.hasError || n.value == 0)
        return false;
    const(char)[] text = buf[0 .. n.value];
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

// The cgroup run cgroups are made beneath once $(LREF delegateRuns) moved this
// process into a leaf of it; empty: the process's own cgroup.
private __gshared SharedBuffer!(char, 256) runParent;

/// The leaf $(LREF delegateRuns) moves the supervising process into.
enum supervisorLeaf = "supervisor";

/**
Delegated containment (SPEC §13.7): run where this process's cgroup was
delegated to it, as a systemd scope with `Delegate=yes` is. A cgroup that holds
processes cannot give its children controllers (the no-internal-process
rule), so this moves the process, every thread, into a leaf of its own
(`<own>/supervisor`), enables the memory and pids controllers for the cgroup's
children, and makes every later run cgroup one of them: each run then
reaches the `accounted` tier, and a scope's memory limits bound its runs and
this process together.

Call it before any child is spawned, and once: a second call returns
`EALREADY` and changes nothing. Returns 0, or the errno of the step that
failed: before the move, nothing changed (a leaf it made is removed again);
after it, runs go beneath the scope with whatever controllers it could
enable, so a host that delegates no memory controller still gets `owned`
runs. `parent` names the cgroup the runs go beneath; which controllers its
children got is in its `cgroup.subtree_control`.
*/
int delegateRuns(ref SharedBuffer!(char, 256) parent) @trusted nothrow
{
    import core.stdc.errno : EALREADY;
    import core.sys.posix.fcntl : O_CLOEXEC, O_WRONLY, open;

    if (runParent.length)
    {
        parent.length = 0;
        parent ~= runParent[];
        return EALREADY;
    }
    SharedBuffer!(char, 256) own;
    if (!ownCgroupPath(own))
        return ENOENT;
    SharedBuffer!(char, 320) sys;
    sys ~= "/sys/fs/cgroup";
    sys ~= own[];
    BlockingVfs vfs;
    auto dir = openRoot!(Rights.all)(&vfs, sys[], ambientAuthority());
    if (dir.hasError)
        return dir.error.code;
    auto made = dir.value.mkdirAt(supervisorLeaf, PosixMode(493 /* 0o755 */));
    if (made.hasError && made.error.code != 17 /* EEXIST */)
        return made.error.code;
    const createdLeaf = !made.hasError;
    // "0" names the writing process: every thread of it moves (cgroup v2).
    static int writeAt(const(char)[] path, const(char)[] text) nothrow @nogc
    {
        char[4096] z = void; // PATH_MAX
        if (path.length >= z.length)
            return EINVAL;
        z[0 .. path.length] = path;
        z[path.length] = 0;
        const fd = open(z.ptr, O_WRONLY | O_CLOEXEC);
        if (fd < 0)
            return errno;
        scope (exit) close(fd);
        return write(fd, text.ptr, text.length) == cast(ptrdiff_t) text.length ? 0 : errno;
    }
    SharedBuffer!(char, 400) path;
    path ~= sys[];
    path ~= "/" ~ supervisorLeaf ~ "/cgroup.procs";
    if (const err = writeAt(path[], "0"))
    {
        if (createdLeaf)
            cast(void) dir.value.rmdirAt(supervisorLeaf);
        return err;
    }
    runParent.length = 0;
    runParent ~= own[];
    parent.length = 0;
    parent ~= own[];
    path.length = 0;
    path ~= sys[];
    path ~= "/cgroup.subtree_control";
    // Each controller alone: a host that delegates one but not the other
    // still enables the one it has.
    const memory = writeAt(path[], "+memory");
    const pids = writeAt(path[], "+pids");
    return memory ? memory : pids;
}

/**
Whether the cgroup was killed at its own memory limit (§13.7): its own
`memory.events.local` counts an `oom` — the limit that ran out was this
cgroup's — and the cgroup counts a kill, an `oom_kill` beneath it
(`memory.events`, hierarchical) or an `oom_group_kill` of its own. A limit
above it, such as its scope's, counts its `oom` in that ancestor alone,
while the victim's cgroup still counts the `oom_kill`: without the local
`oom` the kill is not the cgroup's own. False without a limit, and when
either file cannot be read, so an ambiguous kill stays a signal.
*/
package bool memoryLimitKilled(ref CgroupRun run) @trusted nothrow @nogc
    => run.memoryLimitSet && limitKilledAt(run.memoryEventsLocalFd, run.memoryEventsFd);

// The verdict of $(LREF memoryLimitKilled) over the two event files.
private bool limitKilledAt(int localFd, int allFd) @trusted nothrow @nogc
{
    char[512] local = void, all = void;
    const l = readControl(localFd, local[]);
    const a = readControl(allFd, all[]);
    return l.length && a.length && memoryEventsKilled(l, a);
}

// The text of a small control file, from its start, in `buf`; empty on failure.
private const(char)[] readControl(int fd, return scope char[] buf) @trusted nothrow @nogc
{
    if (fd < 0)
        return null;
    const n = pread(fd, buf.ptr, buf.length, 0);
    return n > 0 ? buf[0 .. n] : null;
}

/// The counter `key` of a `memory.events`-style text; zero when absent.
ulong eventCounter(scope const(char)[] text, scope const(char)[] key) @safe pure nothrow @nogc
{
    while (text.length)
    {
        size_t eol;
        while (eol < text.length && text[eol] != '\n')
            ++eol;
        const line = text[0 .. eol];
        text = eol < text.length ? text[eol + 1 .. $] : null;
        if (line.length > key.length && line[0 .. key.length] == key && line[key.length] == ' ')
        {
            ulong v;
            foreach (c; line[key.length + 1 .. $])
            {
                if (c < '0' || c > '9')
                    break;
                v = v * 10 + (c - '0');
            }
            return v;
        }
    }
    return 0;
}

/// Whether a cgroup's `memory.events.local` (`local`) and `memory.events`
/// (`all`) say it was killed at its own limit: see $(LREF memoryLimitKilled).
bool memoryEventsKilled(scope const(char)[] local, scope const(char)[] all) @safe pure nothrow @nogc
    => eventCounter(local, "oom") > 0
    && (eventCounter(all, "oom_kill") > 0 || eventCounter(local, "oom_group_kill") > 0);

///
@("cgroup.memoryEventsKilled")
@safe pure nothrow @nogc unittest
{
    enum quiet = "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n";
    // Its own limit: the local `oom`, and the kill.
    assert(memoryEventsKilled("low 0\nhigh 0\nmax 2\noom 1\noom_kill 1\noom_group_kill 1\n",
        "low 0\nhigh 0\nmax 2\noom 1\noom_kill 1\noom_group_kill 1\n"));
    // A group: its `oom`, a member's kill counted beneath it.
    assert(memoryEventsKilled("max 3\noom 1\noom_kill 0\noom_group_kill 1\n", "max 3\noom 1\noom_kill 2\n"));
    assert(!memoryEventsKilled("low 0\nhigh 3\nmax 5\noom 1\noom_kill 0\noom_group_kill 0\n",
        "low 0\nhigh 3\nmax 5\noom 1\noom_kill 0\noom_group_kill 0\n"), "a limit reached without a kill");
    // The scope's limit: the victim counts the kill, even a group kill, but
    // no `oom` of its own.
    assert(!memoryEventsKilled("max 0\noom 0\noom_kill 1\noom_group_kill 1\n", "max 0\noom 0\noom_kill 1\n"));
    assert(!memoryEventsKilled(quiet, quiet));
    assert(!memoryEventsKilled("", ""));
    assert(eventCounter("oom 12\noom_kill 3", "oom") == 12 && eventCounter("oom_kill 3", "oom") == 0);
}

// §13.7: sets `memoryMax` on the cgroup `dir`, killing it whole at it, with
// no swap past it, and opens its two event files for the kill's
// attribution. Everything that tells a kill apart is opened and written
// first; `memory.max` last, and put back to `max` if that fails, so a
// cgroup either has the whole limit or none. Whether it was set.
private bool setMemoryLimit(D)(ref D dir, ulong memoryMax, ref int localFd, ref int allFd) @trusted nothrow
{
    static bool put(ref D dir, string name, scope const(char)[] text) nothrow
    {
        int e;
        const fd = openControl!(OpenMode.write)(dir, name, e);
        if (fd < 0)
            return false;
        scope (exit) close(fd);
        return write(fd, text.ptr, text.length) == cast(ptrdiff_t) text.length;
    }

    static void drop(ref int fd) nothrow @nogc
    {
        if (fd >= 0)
            close(fd);
        fd = -1;
    }

    char[24] value = void;
    const n = snprintf(value.ptr, value.length, "%llu", cast(ulong) memoryMax);
    int e;
    localFd = openControl!(OpenMode.read)(dir, "memory.events.local", e);
    allFd = openControl!(OpenMode.read)(dir, "memory.events", e);
    if (n > 0 && localFd >= 0 && allFd >= 0 && put(dir, "memory.oom.group", "1"))
    {
        // No swap past the limit: a run swapping at its limit crawls instead
        // of failing. Absent where the host has no swap accounting.
        cast(void) put(dir, "memory.swap.max", "0");
        if (put(dir, "memory.max", value[0 .. n]))
            return true;
        cast(void) put(dir, "memory.max", "max");
    }
    drop(localFd);
    drop(allFd);
    return false;
}

/**
Several supervised runs under one memory limit (§13.7): a cgroup beneath the
run parent of $(LREF delegateRuns), with the memory and pids controllers for
its children, whose `memory.max` bounds every run made in it
(`SupervisedProcessConfig.runGroup`), killing them all at it. A test leg's
workers are one. Non-copyable: the descriptors are owned.
*/
struct RunGroup
{
    @disable this(this);

    /// The group's directory name beneath the run parent; empty until made.
    SharedBuffer!(char, 64) name;
    /// Whether its limit is set; the group exists without one.
    bool memoryLimitSet;
    private int peakFd = -1, localFd = -1, allFd = -1;
    private SharedBuffer!(char, 320) sysPath;

    /// The memory its runs peaked at together (`memory.peak`); zero unread.
    ulong peakBytes() @trusted nothrow @nogc
    {
        char[32] buf = void;
        ulong v;
        foreach (c; readControl(peakFd, buf[]))
        {
            if (c < '0' || c > '9')
                break;
            v = v * 10 + (c - '0');
        }
        return v;
    }

    /// Whether it was killed at its own limit, as $(LREF memoryLimitKilled).
    bool limitKilled() @trusted nothrow @nogc => memoryLimitSet && limitKilledAt(localFd, allFd);
}

/**
Makes `group` beneath the run parent, with `memoryMax` as its limit (zero:
none). Blocking, small: a `mkdir` and a few control writes. Needs
$(LREF delegateRuns) to have made a run parent whose children have the memory
and pids controllers; 0 or the errno of the step that failed, and then
nothing is left behind.
*/
int createRunGroup(ref RunGroup group, ulong memoryMax) @trusted nothrow
{
    import core.atomic : atomicOp;
    import core.stdc.errno : ENOTSUP;

    static shared uint groups;
    if (!runParent.length)
        return ENOTSUP;
    SharedBuffer!(char, 320) parentPath;
    parentPath ~= "/sys/fs/cgroup";
    parentPath ~= runParent[];
    BlockingVfs vfs;
    auto parent = openRoot!(Rights.all)(&vfs, parentPath[], ambientAuthority());
    if (parent.hasError)
        return parent.error.code;
    char[64] name = void;
    const len = snprintf(name.ptr, name.length, "eh-group-%d-%u", cast(int) getpid(), atomicOp!"+="(groups, 1));
    if (len <= 0 || len >= name.length)
        return EINVAL;
    auto made = parent.value.mkdirAt(name[0 .. len], PosixMode(493 /* 0o755 */));
    if (made.hasError)
        return made.error.code;
    int fail(int err)
    {
        group.closeAll();
        cast(void) parent.value.rmdirAt(name[0 .. len]);
        return err;
    }
    auto dir = parent.value.openDir(name[0 .. len]);
    if (dir.hasError)
        return fail(dir.error.code);
    int e;
    const control = openControl!(OpenMode.write)(dir.value, "cgroup.subtree_control", e);
    if (control < 0)
        return fail(e);
    const memory = write(control, "+memory".ptr, 7) == 7;
    const pids = write(control, "+pids".ptr, 5) == 5;
    const writeErr = errno;
    close(control);
    if (!memory || !pids)
        return fail(writeErr ? writeErr : EINVAL);
    group.peakFd = openControl!(OpenMode.read)(dir.value, "memory.peak", e);
    if (group.peakFd < 0)
        return fail(e);
    group.memoryLimitSet = memoryMax && setMemoryLimit(dir.value, memoryMax, group.localFd, group.allFd);
    group.name.length = 0;
    group.name ~= name[0 .. len];
    group.sysPath.length = 0;
    group.sysPath ~= parentPath[];
    return 0;
}

/// Removes `group` once its runs are gone; a group a run still holds is left
/// (`EBUSY`) for the scope's teardown. 0 or errno.
int removeRunGroup(ref RunGroup group) @trusted nothrow
{
    group.closeAll();
    if (!group.name.length)
        return 0;
    BlockingVfs vfs;
    auto parent = openRoot!(Rights.all)(&vfs, group.sysPath[], ambientAuthority());
    if (parent.hasError)
        return parent.error.code;
    auto removed = parent.value.rmdirAt(group.name[]);
    group.name.length = 0;
    return removed.hasError ? removed.error.code : 0;
}

private void closeAll(ref RunGroup group) @trusted nothrow @nogc
{
    foreach (fd; [&group.peakFd, &group.localFd, &group.allFd])
    {
        if (*fd >= 0)
            close(*fd);
        *fd = -1;
    }
}

/// Writes `value` to `/proc/<pid>/oom_score_adj` (SPEC §13.7): the adjustment the
/// kernel adds to a process's OOM badness, 1000 its largest. Raising a score
/// needs no privilege; lowering one below the process's minimum does.
/// 0 or errno.
int writeOomScoreAdj(int pid, int value) @trusted nothrow @nogc
{
    import core.sys.posix.fcntl : O_CLOEXEC, O_WRONLY, open;

    char[64] path = void;
    char[16] text = void;
    if (snprintf(path.ptr, path.length, "/proc/%d/oom_score_adj", pid) <= 0)
        return EINVAL;
    const n = snprintf(text.ptr, text.length, "%d", value);
    if (n <= 0)
        return EINVAL;
    const fd = open(path.ptr, O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return errno;
    scope (exit) close(fd);
    return write(fd, text.ptr, n) == n ? 0 : errno;
}

/// Opens the control file `name` in `dir` and keeps its descriptor for the
/// run's lifetime; -1 with `err` set on failure.
private int openControl(OpenMode mode, D)(ref D dir, string name, out int err)
{
    auto file = dir.openFile!mode(name);
    if (file.hasError)
    {
        err = file.error.code;
        return -1;
    }
    return file.value.intoOwnedFd().release();
}

/**
Creates the run cgroup and probes its tier (the pre-spawn job; public
lane). Every acquired resource is published independently — `dirCreated`
first — so any failure leaves a truthful partial state whose cleanup the
caller owns.
*/
package void createRun(ref CgroupRun run, uint runId,
    bool injectControlOpenFailure = false, ulong memoryMax = 0, scope const(char)[] group = null) @trusted nothrow
{
    static void degrade(ref CgroupRun run, int err, string why) nothrow @nogc
    {
        run.tier = CgroupTier.none;
        if (run.degradedBy.code == 0 && run.degradedBy.context is null)
            run.degradedBy = ioError(err, OpKind.none, IoErrorStage.setup, why);
    }

    SharedBuffer!(char, 256) own;
    if (runParent.length)
        own ~= runParent[];
    else if (!ownCgroupPath(own))
        return degrade(run, ENOENT, "cgroup: no v2 path for this process");
    if (group.length)
    {
        // A run group's member (§13.7): beneath the group, which only a
        // run parent can hold.
        if (!runParent.length || own.length + 1 + group.length > 200)
            return degrade(run, EINVAL, "cgroup: no run group here");
        own ~= '/';
        own ~= group;
    }

    run.sysPath.length = 0;
    run.sysPath ~= "/sys/fs/cgroup";
    run.sysPath ~= own[];
    BlockingVfs vfs;
    auto parent = openRoot!(Rights.all)(&vfs, run.sysPath[], ambientAuthority());
    if (parent.hasError)
        return degrade(run, parent.error.code, "cgroup: cannot open the process's own cgroup");

    char[64] name = void;
    const nameLen = snprintf(name.ptr, name.length, "eh-run-%d-%u",
        cast(int) getpid(), runId);
    if (nameLen <= 0 || nameLen >= name.length)
        return degrade(run, EINVAL, "cgroup: run name overflow");
    const runName = name[0 .. nameLen];

    auto made = parent.value.mkdirAt(runName, PosixMode(493 /* 0o755 */));
    if (made.hasError)
        return degrade(run, made.error.code, "cgroup: mkdir of the run directory refused");
    // From here the directory exists and its cleanup is the caller's.
    run.dirCreated = true;
    run.path.length = 0;
    run.path ~= own[];
    run.path ~= '/';
    run.path ~= runName;
    run.sysPath ~= '/';
    run.sysPath ~= runName;

    auto dir = parent.value.openDir(runName);
    if (dir.hasError)
        return degrade(run, dir.error.code, "cgroup: cannot open the run directory");
    {
        import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY, O_RDONLY, open;

        char[321] z = void;
        z[0 .. run.sysPath.length] = run.sysPath[];
        z[run.sysPath.length] = 0;
        run.dirFd = open(z.ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC); // optional
    }

    // Fault injection (tests): the "dirCreated but degraded" state.
    if (injectControlOpenFailure)
        return degrade(run, 5 /* EIO */, "cgroup: injected control-open failure");
    int err;
    run.killFd = openControl!(OpenMode.write)(dir.value, "cgroup.kill", err);
    if (run.killFd < 0)
        return degrade(run, err, "cgroup: cgroup.kill unavailable");
    run.eventsFd = openControl!(OpenMode.read)(dir.value, "cgroup.events", err);
    if (run.eventsFd < 0)
    {
        run.closeAll();
        return degrade(run, err, "cgroup: cgroup.events unavailable");
    }
    run.procsFd = openControl!(OpenMode.readWrite)(dir.value, "cgroup.procs", err);
    if (run.procsFd < 0)
    {
        run.closeAll();
        return degrade(run, err, "cgroup: cgroup.procs unavailable");
    }
    run.tier = CgroupTier.owned;

    run.cpuStatFd = openControl!(OpenMode.read)(dir.value, "cpu.stat", err); // optional
    run.memoryPeakFd = openControl!(OpenMode.read)(dir.value, "memory.peak", err);
    run.pidsPeakFd = openControl!(OpenMode.read)(dir.value, "pids.peak", err);
    if (run.memoryPeakFd >= 0 && run.pidsPeakFd >= 0)
    {
        run.tier = CgroupTier.accounted;
        // §13.7: a limit per run, in the accounted tier only, before the
        // child enters; `memory.oom.group` kills the whole run at it.
        if (memoryMax)
            run.memoryLimitSet = setMemoryLimit(dir.value, memoryMax, run.memoryEventsLocalFd,
                run.memoryEventsFd);
    }
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

    failure = removeRunDirectory(run.sysPath[]);
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

/// Removes the run directory at `sysPath` and its nested cgroups, deepest
/// first; 0 or the errno of the final `rmdir`. A cgroup's control files cannot
/// be unlinked, so only its child directories are removed, never `removeTree`'s
/// files.
private int removeRunDirectory(scope const(char)[] sysPath) @trusted nothrow
{
    size_t slash = sysPath.length;
    while (slash > 0 && sysPath[slash - 1] != '/')
        --slash;
    if (slash <= 1 || slash == sysPath.length)
        return EINVAL;
    BlockingVfs vfs;
    auto parent = openRoot!(Rights.all)(&vfs, sysPath[0 .. slash - 1], ambientAuthority());
    if (parent.hasError)
        return parent.error.code;
    return removeCgroupAt(parent.value, sysPath[slash .. $], 0);
}

/// ditto, for the child `name` of `parent`. Bounded depth and fan-out.
private int removeCgroupAt(D)(ref D parent, scope const(char)[] name, uint depth)
{
    enum maxDepth = 16;
    enum maxEntries = 1024;
    if (depth < maxDepth)
    {
        auto dir = parent.openDir(name);
        if (dir.hasValue)
        {
            auto listing = dir.value.list();
            for (uint seen; listing.hasValue && seen < maxEntries; ++seen)
            {
                auto more = listing.value.next();
                if (more.hasError || !more.value)
                    break;
                if (listing.value.front.kind == EntryKind.directory)
                    removeCgroupAt(dir.value, listing.value.front.name, depth + 1);
            }
        }
    }
    auto removed = parent.rmdirAt(name);
    return removed.hasError ? removed.error.code : 0;
}

// ── the lane-assigned fiber surface ─────────────────────────────────────────

private struct CreateJob
{
    CgroupRun* run;
    uint runId;
    bool injectControlOpenFailure;
    ulong memoryMax;
    const(char)[] group;
}

private void createCall(void* p) nothrow
{
    auto job = cast(CreateJob*) p;
    createRun(*job.run, job.runId, job.injectControlOpenFailure, job.memoryMax, job.group);
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
    ref CgroupRun run, uint runId, bool injectControlOpenFailure = false, ulong memoryMax = 0,
    const(char)[] group = null) @trusted
{
    CreateJob job = {run: &run, runId: runId,
        injectControlOpenFailure: injectControlOpenFailure, memoryMax: memoryMax, group: group};
    auto r = pool.run(s, &createCall, &job);
    if (r.hasError && r.error.code == EAGAIN)
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
        import sparkles.test_runner.skip : skipTest;
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
        assert(run.dirCreated && run.canKill);
        assert(run.eventsFd >= 0 && run.procsFd >= 0);
        assert(runDirExists(run), "the run directory exists");
        assert(run.path[].length > 8 && run.sysPath[][0 .. 14] == "/sys/fs/cgroup");
        assert(readPopulated(run) == TreeEvidence.empty, "a fresh run is empty");
        assert(readCpuStat(run).ok, "cpu.stat exists on every v2 cgroup");

        auto cleaned = cgroupCleanup(s, pool, run, 100.msecs);
        assert(!cleaned.hasError && !cleaned.value, "an empty run is removed");
        assert(!run.dirCreated && run.killFd < 0);
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
        auto child = move(spawned.value);
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
        auto child = move(spawned.value);
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
        BlockingVfs vfs;
        auto runDir = openRoot!(Rights.all)(&vfs, run.sysPath[], ambientAuthority());
        assert(!runDir.value.mkdirAt("nested", PosixMode(493)).hasError);
        auto spawned = spawnProcess(["sleep", "30"]);
        assert(spawned.hasValue);
        auto child = move(spawned.value);
        {
            auto nested = runDir.value.walk("nested");
            auto procs = nested.value.openFile!(OpenMode.write)("cgroup.procs");
            assert(procs.hasValue);
            char[24] buf = void;
            const n = snprintf(buf.ptr, buf.length, "%d\n", child.pid);
            assert(procs.value.write(cast(const(ubyte)[]) buf[0 .. n]).value == n);
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
    import sparkles.test_runner.skip : skipTest;
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
        assert(run.degradedBy.code == 5);
        assert(runDirExists(run), "…but the directory is ours");
        auto cleaned = cgroupCleanup(s, pool.value, run, 100.msecs);
        assert(!cleaned.hasError && !cleaned.value);
        assert(!runDirExists(run), "no run directory is ever leaked");
    });
    assert(!r.hasError);
}
