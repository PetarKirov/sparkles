/**
The bounded, tiered, transactional tree sampler behind supervised runs'
resource accounting (SPEC §13.8). It replaces an unbounded `/proc` walk that
re-summed an ever-growing CPU map on every sample.

Three sources, chosen once per run from the containment tier (`cgroup.d`):
`cgroupFull` (owned cgroup with controller-backed peaks), `cgroupMembers`
(owned cgroup: the roster from `cgroup.procs`, `cpu.stat`, peaks from
procfs), and `procScan` (no cgroup: `/proc` scanned for the root's
descendants and the root's process group).

Every proc sample is a $(B transaction) with a $(B fail-closed root anchor):
the root's `/proc/<pid>` directory is held open from the moment the child
exists, and its identity (pid + start time, read through that handle) is
validated before and after each scan; a mismatch or disappearance discards
the whole sample — a replacement process and its fresh descendants would
otherwise satisfy every numeric test. Nothing is folded until the second
validation passes. Members hold no persistent descriptor: each is opened,
read and closed within one sample, so sequential churn cannot grow the
descriptor set.

CPU is accounted in a $(B bounded ledger): a live map with its own capacity,
a scalar of retired contributions, and a bounded retired-key set; the total
is `retired + Σ live`, so a sample costs O(live members), never
O(historical children). Every saturation path degrades to a lower bound,
never to an overcount, and a retired or tombstoned identity is never
re-admitted. Work is budgeted per sample (entries, bytes, time) and a budget
hit retains un-probed entries unchanged — omission is never proof of death.

Sampling on the loop thread is the supervisor's business (commit 11 moves
it onto the public lane); this module is a `nothrow` substrate a worker or
a fiber can call.
*/
module sparkles.event_horizon.sampling;

import core.time : Duration, msecs, seconds, usecs;

import sparkles.event_horizon.proc : MetricQuality, MetricSource,
    ProcessResourceUsage, SampleSource;

/// A process identity: a pid is reused; a pid plus its start time is not.
package struct ProcessIdentity
{
    int pid;
    ulong startTime;
}

/// Cumulative CPU ticks of one identity.
package struct ProcessCpu
{
    ulong userTicks;
    ulong systemTicks;
}

/// The per-sample work budget; a hit sets `accountingSaturated` and keeps
/// every quality at `lowerBound`.
package struct SamplerBudget
{
    uint maxEntries = 4096;        /// proc entries scanned or members probed
    size_t maxBytes = 4 << 20;     /// bytes read from proc/cgroup files
    /// The sampling thread's own CPU time per sample: a bound for
    /// pathological hosts (a full `/proc` scan over ~1300 pids costs
    /// ~25 ms), never a latency target.
    Duration maxTime = 200.msecs;
}

// ── the bounded CPU ledger ──────────────────────────────────────────────────

/// A live-map entry's state (SPEC §13.8 transition table).
package enum LedgerState : ubyte
{
    live,          /// summed
    deadTombstone, /// dead after the retired set filled: holds `cpu = 0`
}

package struct LedgerEntry
{
    LedgerState state;
    ProcessCpu cpu;
}

/**
The bounded cumulative CPU ledger. `liveCapacity` bounds the live map,
`retiredCapacity` the retired-key set; once the retired set is full the
ledger is $(B sealed): no identity is ever admitted again, and a live entry
that dies afterwards moves its last-known contribution into the scalar and
becomes a tombstone with `cpu = 0` — the slot stays consumed so the key
cannot be re-admitted, and the total does not jump.
*/
package struct CpuLedger
{
    enum liveCapacity = 1024;
    enum retiredCapacity = 4096;

    // Keys are passed by value, never `in`: DMD deprecates a const AA key
    // as an lvalue, and the SPEC's runnable example captures compiler output.
    private LedgerEntry[ProcessIdentity] _live;
    private bool[ProcessIdentity] _retired;
    private ulong _retiredUser, _retiredSystem;
    private bool _sealed;
    private ProcessIdentity[] _order; /// admission order, for the rotating cursor
    private size_t _cursor;

    /// The number of keys in the live map (tombstones included).
    size_t liveCount() const @safe pure nothrow @nogc => _live.length;
    /// `true` once the retired set is full: no admissions ever again.
    bool sealed() const @safe pure nothrow @nogc => _sealed;
    /// The scalar of retired contributions.
    ProcessCpu retired() const @safe pure nothrow @nogc
        => ProcessCpu(_retiredUser, _retiredSystem);

    /// Whether `id` is currently a summed live entry.
    bool isLive(ProcessIdentity id) const @safe nothrow
    {
        auto e = id in _live;
        return e !is null && e.state == LedgerState.live;
    }

    /// Admits a newly discovered identity; `false` (a rejection, which the
    /// caller records as saturation) when the live map is full, the ledger
    /// is sealed, or the key was ever seen before.
    bool admit(ProcessIdentity id, in ProcessCpu cpu) @safe nothrow
    {
        if (_sealed || (id in _live) !is null || (id in _retired) !is null)
            return false;
        if (_live.length >= liveCapacity)
            return false;
        _live[id] = LedgerEntry(LedgerState.live, cpu);
        _order ~= id;
        return true;
    }

    /// Updates a live entry's running maximum (a re-probed present member).
    void update(ProcessIdentity id, in ProcessCpu cpu) @safe nothrow
    {
        auto e = id in _live;
        if (e is null || e.state != LedgerState.live)
            return;
        if (cpu.userTicks > e.cpu.userTicks)
            e.cpu.userTicks = cpu.userTicks;
        if (cpu.systemTicks > e.cpu.systemTicks)
            e.cpu.systemTicks = cpu.systemTicks;
    }

    /// The identity is gone (disappeared, or its pid now carries another
    /// start time): its last-known contribution moves into the scalar; the
    /// key joins the retired set — or, when that set is full, the entry
    /// becomes a tombstone in place and the ledger seals.
    void retire(ProcessIdentity id) @safe nothrow
    {
        auto e = id in _live;
        if (e is null || e.state != LedgerState.live)
            return;
        _retiredUser = saturatingAdd(_retiredUser, e.cpu.userTicks);
        _retiredSystem = saturatingAdd(_retiredSystem, e.cpu.systemTicks);
        if (!_sealed && _retired.length < retiredCapacity)
        {
            _retired[id] = true;
            _live.remove(id);
            removeFromOrder(id);
            if (_retired.length >= retiredCapacity)
                _sealed = true;
            return;
        }
        _sealed = true;
        e.state = LedgerState.deadTombstone;
        e.cpu = ProcessCpu.init;
    }

    /// `retired + Σ live` — tombstones hold zero and are never summed.
    ProcessCpu total() const @safe nothrow
    {
        ProcessCpu t = retired();
        foreach (ref e; _live.byValue)
            if (e.state == LedgerState.live)
            {
                t.userTicks = saturatingAdd(t.userTicks, e.cpu.userTicks);
                t.systemTicks = saturatingAdd(t.systemTicks, e.cpu.systemTicks);
            }
        return t;
    }

    /// Visits the live (non-tombstone) identities starting at a rotating
    /// cursor, so a budget that ends early does not starve the same tail
    /// every sample. `visit` returns `false` to stop (budget exhausted).
    void eachLiveFromCursor(Visit)(scope Visit visit)
    if (is(typeof(visit(ProcessIdentity.init)) == bool))
    {
        const n = _order.length;
        if (n == 0)
            return;
        if (_cursor >= n)
            _cursor = 0;
        size_t visited;
        for (size_t i = _cursor; visited < n; ++visited, i = (i + 1) % n)
        {
            const id = _order[i];
            auto e = id in _live;
            if (e is null || e.state != LedgerState.live)
                continue;
            if (!visit(id))
            {
                _cursor = i;
                return;
            }
        }
        _cursor = 0;
    }

    private void removeFromOrder(ProcessIdentity id) @safe nothrow
    {
        foreach (i, ref o; _order)
            if (o == id)
            {
                _order[i] = _order[$ - 1];
                _order.length -= 1;
                if (_cursor > i)
                    --_cursor;
                return;
            }
    }
}

private ulong saturatingAdd(ulong a, ulong b) @safe pure nothrow @nogc
    => a > ulong.max - b ? ulong.max : a + b;

// ── the Linux sampler ───────────────────────────────────────────────────────

version (linux)
{
    import core.stdc.errno : errno;
    import core.sys.posix.fcntl : O_CLOEXEC, O_DIRECTORY, O_PATH, O_RDONLY,
        open, openat;
    import core.sys.posix.unistd : close, pread;

    import sparkles.event_horizon.cgroup : CgroupRun, CgroupTier, listMembers,
        readCounter, readCpuStat;

    /// The fields of `/proc/<pid>/stat` a sample needs.
    package struct ProcStat
    {
        int ppid;
        int pgrp;
        ulong userTicks;
        ulong systemTicks;
        ulong startTime;
        ulong rssPages;
        bool zombie; /// state letter `Z`: exited, membership gone, reparenting done
    }

    /// Parses a `/proc/<pid>/stat` line. Fields are numbered as in proc(5);
    /// `comm` may contain spaces and parentheses, so parsing restarts after
    /// its last `)`. Fields this does not need may be the kernel's unsigned
    /// spelling of -1; only the six it reads must be non-negative.
    package bool parseProcStat(scope const(char)[] text, out ProcStat st)
        @safe pure nothrow @nogc
    {
        long close_ = -1;
        foreach (i, c; text)
            if (c == ')')
                close_ = i;
        if (close_ < 0)
            return false;
        auto rest = text[cast(size_t) close_ + 1 .. $];

        // Token 0 is the state letter (field 3); token k is field k + 3.
        uint field = 3;
        size_t got;
        size_t i;
        while (i < rest.length)
        {
            while (i < rest.length && rest[i] == ' ')
                ++i;
            const start = i;
            while (i < rest.length && rest[i] != ' ' && rest[i] != '\n')
                ++i;
            if (i == start)
                break;
            const tok = rest[start .. i];
            ulong v;
            switch (field)
            {
            case 3:
                st.zombie = tok == "Z";
                break;
            case 4:
                if (!parseUlong(tok, v) || v > int.max) return false;
                st.ppid = cast(int) v; ++got; break;
            case 5:
                if (!parseUlong(tok, v) || v > int.max) return false;
                st.pgrp = cast(int) v; ++got; break;
            case 14:
                if (!parseUlong(tok, v)) return false;
                st.userTicks = v; ++got; break;
            case 15:
                if (!parseUlong(tok, v)) return false;
                st.systemTicks = v; ++got; break;
            case 22:
                if (!parseUlong(tok, v)) return false;
                st.startTime = v; ++got; break;
            case 24:
                if (!parseUlong(tok, v)) return false;
                st.rssPages = v; ++got;
                return got == 6;
            default:
                break;
            }
            ++field;
        }
        return false;
    }

    private bool parseUlong(scope const(char)[] tok, out ulong v)
        @safe pure nothrow @nogc
    {
        if (tok.length == 0)
            return false;
        ulong acc;
        foreach (c; tok)
        {
            if (c < '0' || c > '9')
                return false;
            if (acc > (ulong.max - (c - '0')) / 10)
                return false;
            acc = acc * 10 + (c - '0');
        }
        v = acc;
        return true;
    }

    private __gshared size_t pageSizeCache;

    private size_t pageSize() @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : _SC_PAGESIZE, sysconf;

        if (pageSizeCache == 0)
            pageSizeCache = cast(size_t) sysconf(_SC_PAGESIZE);
        return pageSizeCache;
    }

    private __gshared long clockTicksCache;

    /// `_SC_CLK_TCK`, queried once: a process-lifetime constant.
    private long clockTicksPerSecond() @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : _SC_CLK_TCK, sysconf;

        if (clockTicksCache == 0)
            clockTicksCache = sysconf(_SC_CLK_TCK);
        return clockTicksCache;
    }

    /// Ticks → `Duration`, saturating rather than wrapping (monotonicity is
    /// promised).
    package Duration ticksToDuration(ulong ticks, long hz) @safe pure nothrow @nogc
    {
        if (hz <= 0)
            return Duration.zero;
        // ticks * 1e6 / hz without overflow: split into whole seconds.
        const secs = ticks / cast(ulong) hz;
        const rem = ticks % cast(ulong) hz;
        if (secs > cast(ulong) long.max / 1_000_000L)
            return Duration.max;
        return usecs(cast(long)(secs * 1_000_000L + rem * 1_000_000L / cast(ulong) hz));
    }

    /// The sampling thread's own CPU clock: a budget on work done, which
    /// preemption under load cannot spend on the sampler's behalf.
    private Duration threadCpuNow() @trusted nothrow @nogc
    {
        import core.sys.linux.time : CLOCK_THREAD_CPUTIME_ID;
        import core.sys.posix.time : clock_gettime, timespec;
        import core.time : dur;

        timespec ts;
        if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0)
            return Duration.zero;
        return dur!"seconds"(ts.tv_sec) + dur!"nsecs"(ts.tv_nsec);
    }

    /// The per-sample accounting of work done, charged against the budget.
    private struct Spent
    {
        uint entries;
        size_t bytes;
        Duration startedCpu;

        bool exhausted(in SamplerBudget b) const @safe nothrow @nogc
            => entries >= b.maxEntries || bytes >= b.maxBytes
                || threadCpuNow() - startedCpu >= b.maxTime;
    }

    /// Reads `/proc/<pid>/stat` through a per-sample `O_PATH` handle of the
    /// process directory; `false` when the process is gone or unreadable.
    private bool readStatUnder(int dirFd, out ProcStat st, ref Spent spent)
        @trusted nothrow
    {
        const fd = openat(dirFd, "stat", O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            return false;
        scope (exit) close(fd);
        char[1024] buf = void;
        const n = pread(fd, buf.ptr, buf.length, 0);
        if (n <= 0)
            return false;
        spent.bytes += n;
        return parseProcStat(buf[0 .. n], st);
    }

    /// Opens `/proc/<pid>` as an `O_PATH` directory handle; -1 when gone.
    private int openProcDir(int pid) @trusted nothrow @nogc
    {
        import core.stdc.stdio : snprintf;

        char[32] path = void;
        snprintf(path.ptr, path.length, "/proc/%d", pid);
        return open(path.ptr, O_PATH | O_DIRECTORY | O_CLOEXEC);
    }

    /// Whether `/proc/<pid>/cgroup` (read through `dirFd`) places the
    /// process inside `runPath`: equal, or continuing with `/` right after
    /// — never a prefix match (`eh-run-1-2-escaped` is outside `eh-run-1-2`).
    private bool insideCgroup(int dirFd, scope const(char)[] runPath,
        ref Spent spent) @trusted nothrow
    {
        const fd = openat(dirFd, "cgroup", O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            return false;
        scope (exit) close(fd);
        char[512] buf = void;
        const n = pread(fd, buf.ptr, buf.length, 0);
        if (n <= 0)
            return false;
        spent.bytes += n;
        const(char)[] text = buf[0 .. n];
        while (text.length)
        {
            size_t eol;
            while (eol < text.length && text[eol] != '\n')
                ++eol;
            const line = text[0 .. eol];
            text = eol < text.length ? text[eol + 1 .. $] : null;
            if (line.length < 3 || line[0 .. 3] != "0::")
                continue;
            const path = line[3 .. $];
            if (path.length < runPath.length || path[0 .. runPath.length] != runPath)
                return false;
            return path.length == runPath.length || path[runPath.length] == '/';
        }
        return false;
    }

    /**
    One run's sampler: the root anchor, the ledger, and the cumulative
    usage it maintains. Non-copyable: it owns the root handle.
    */
    package struct TreeSampler
    {
        @disable this(this);

        SampleSource source;
        SamplerBudget budget;
        ProcessResourceUsage usage;
        CpuLedger ledger;

        private CgroupRun* _cgroup;
        private int _rootPid = -1;
        private int _rootFd = -1;
        private ulong _rootStart;
        private bool _anchored;
        private bool _pidSamplingDisabled;
        private bool _cgroupCpuFailed, _cgroupMemFailed, _cgroupTasksFailed;
        private bool _rootZombie;

        version (unittest)
        {
            /// Test hook: runs between the two root validations of a sample.
            package void delegate() nothrow testBetweenValidations;
        }

        /// Whether pid-based sampling is possible for this run.
        bool anchored() const @safe pure nothrow @nogc => _anchored;

        /**
        Binds the sampler to the root — called at one named point,
        immediately after the child exists and before any worker runs.
        `cg` selects the cgroup sources (null, or a run without the
        capability, means `procScan`). Anchor failure disables pid-based
        sampling for the run: procfs metrics stay `unmeasured`, the run is
        `samplingDegraded`; cgroup counters are unaffected.
        */
        void anchor(int rootPid, CgroupRun* cg) @trusted nothrow
        {
            _rootPid = rootPid;
            _cgroup = cg !is null && cg.tier != CgroupTier.none ? cg : null;
            source = _cgroup is null ? SampleSource.procScan
                : (_cgroup.tier == CgroupTier.accounted
                    ? SampleSource.cgroupFull : SampleSource.cgroupMembers);
            usage.source = source;
            _rootFd = openProcDir(rootPid);
            Spent spent;
            ProcStat st;
            if (_rootFd < 0 || !readStatUnder(_rootFd, st, spent))
            {
                if (_rootFd >= 0)
                    close(_rootFd);
                _rootFd = -1;
                _pidSamplingDisabled = true;
                usage.samplingDegraded = true;
                return;
            }
            _rootStart = st.startTime;
            _anchored = true;
        }

        /// Releases the root handle; every path calls it exactly once.
        void finish() @trusted nothrow @nogc
        {
            if (_rootFd >= 0)
                close(_rootFd);
            _rootFd = -1;
            _anchored = false;
        }

        /// The root's identity as anchored (valid while `anchored`).
        ProcessIdentity rootIdentity() const @safe pure nothrow @nogc
            => ProcessIdentity(_rootPid, _rootStart);

        /**
        Takes one sample. Returns whether a fold was merged (the cumulative
        counters advanced); a discarded transaction returns `false` and
        marks the run degraded. Never throws; may allocate (ledger keys).
        */
        bool sample() @trusted nothrow
        {
            Spent spent;
            spent.startedCpu = threadCpuNow();
            // Cgroup counters are read on every sample whatever the proc
            // outcome: they do not depend on pid identity.
            const cgroupRead = readCgroupCounters();

            if (_pidSamplingDisabled || !_anchored)
            {
                usage.samplingDegraded = true;
                return commitCgroupOnly(cgroupRead);
            }

            // ① validate the original root through the held handle.
            if (!rootStillOriginal(spent))
                return discard();

            // ② collect into scratch; the ledger and usage are untouched.
            Scratch scratch;
            reprobeLedger(scratch, spent);
            if (!scratch.budgetHit)
            {
                final switch (source)
                {
                case SampleSource.procScan:
                    discoverByScan(scratch, spent);
                    break;
                case SampleSource.cgroupMembers:
                case SampleSource.cgroupFull:
                    // The roster misses a descendant forked before the
                    // post-spawn migration landed (SPEC §13.7); the ppid
                    // tree from the root still finds it while the root
                    // lives, and once the root is a zombie — reparenting
                    // done — only the process group can: a bounded scan.
                    discoverByRoster(scratch, spent);
                    if (_rootZombie)
                        discoverByScan(scratch, spent);
                    else
                        discoverByChildren(scratch, spent);
                    break;
                case SampleSource.none:
                    break;
                }
            }

            version (unittest)
                if (testBetweenValidations !is null)
                    testBetweenValidations();

            // ③ validate again — a contract-violating external reaper may
            // have replaced the root mid-scan.
            if (!rootStillOriginal(spent))
                return discard();

            // ④ merge atomically.
            merge(scratch, cgroupRead);
            return true;
        }

    private:
        struct Probe
        {
            ProcessIdentity id;
            ProcessCpu cpu;
            ulong rssPages;
            bool admit; /// new (not yet in the ledger)
        }

        struct Scratch
        {
            Probe[] present;          /// members seen this sample
            ProcessIdentity[] gone;   /// live entries proven gone
            bool budgetHit;
            bool rejected;            /// an admission would exceed capacity
        }

        struct CgroupRead
        {
            bool cpuOk;
            ulong userUsec, systemUsec;
            bool memOk;
            ulong memPeak;
            bool tasksOk;
            ulong tasksPeak;
        }

        bool rootStillOriginal(ref Spent spent) @trusted nothrow
        {
            ProcStat st;
            if (!readStatUnder(_rootFd, st, spent) || st.startTime != _rootStart)
                return false;
            _rootZombie = st.zombie;
            return true;
        }

        bool discard() @safe nothrow @nogc
        {
            usage.samplingDegraded = true;
            return false;
        }

        CgroupRead readCgroupCounters() @trusted nothrow
        {
            CgroupRead r;
            if (_cgroup is null)
                return r;
            const cpu = readCpuStat(*_cgroup);
            r.cpuOk = cpu.ok;
            r.userUsec = cpu.userUsec;
            r.systemUsec = cpu.systemUsec;
            if (!r.cpuOk && _cgroup.cpuStatFd >= 0)
                _cgroupCpuFailed = true;
            if (source == SampleSource.cgroupFull)
            {
                r.memOk = readCounter(_cgroup.memoryPeakFd, r.memPeak);
                r.tasksOk = readCounter(_cgroup.pidsPeakFd, r.tasksPeak);
                if (!r.memOk)
                    _cgroupMemFailed = true;
                if (!r.tasksOk)
                    _cgroupTasksFailed = true;
            }
            return r;
        }

        /// Re-probes every live ledger entry (rotating cursor), charging the
        /// budget; entries not reached are retained unchanged.
        void reprobeLedger(ref Scratch scratch, ref Spent spent) @trusted nothrow
        {
            ledger.eachLiveFromCursor((ProcessIdentity id) nothrow {
                if (spent.exhausted(budget))
                {
                    scratch.budgetHit = true;
                    return false;
                }
                ++spent.entries;
                const fd = openProcDir(id.pid);
                if (fd < 0)
                {
                    scratch.gone ~= id;
                    return true;
                }
                scope (exit) close(fd);
                ProcStat st;
                if (!readStatUnder(fd, st, spent) || st.startTime != id.startTime)
                {
                    scratch.gone ~= id; // disappeared, or an immediate pid reuse
                    return true;
                }
                scratch.present ~= Probe(id,
                    ProcessCpu(st.userTicks, st.systemTicks), st.rssPages, false);
                return true;
            });
        }

        bool alreadyProbed(in Scratch scratch, int pid) @safe pure nothrow @nogc
        {
            foreach (ref p; scratch.present)
                if (p.id.pid == pid)
                    return true;
            foreach (ref g; scratch.gone)
                if (g.pid == pid)
                    return true;
            return false;
        }

        /// Records a newly seen member: an admission when the ledger can
        /// take it, else a rejection (still counted toward the peaks).
        void noteDiscovered(ref Scratch scratch, ProcessIdentity id, in ProcStat st)
            @safe nothrow
        {
            const known = ledger.isLive(id);
            if (!known && (ledger.sealed || ledger.liveCount >= CpuLedger.liveCapacity))
                scratch.rejected = true;
            scratch.present ~= Probe(id, ProcessCpu(st.userTicks, st.systemTicks),
                st.rssPages, !known);
        }

        /// `procScan`: every numeric `/proc` entry, bounded; membership is
        /// descent from the root (ppid chain) or the root's process group.
        void discoverByScan(ref Scratch scratch, ref Spent spent) @trusted nothrow
        {
            import core.stdc.string : strlen;
            import core.sys.posix.dirent : closedir, dirent, opendir, readdir;

            struct Seen
            {
                ProcStat st;
                bool member;
            }

            Seen[int] seen;
            auto dir = opendir("/proc");
            if (dir is null)
                return;
            scope (exit) closedir(dir);
            for (dirent* ent = readdir(dir); ent !is null; ent = readdir(dir))
            {
                if (spent.exhausted(budget))
                {
                    scratch.budgetHit = true;
                    break;
                }
                const name = ent.d_name.ptr[0 .. strlen(ent.d_name.ptr)];
                ulong pidU;
                if (name.length == 0 || name.length > 7 || !parseUlong(name, pidU))
                    continue;
                const pid = cast(int) pidU;
                ++spent.entries;
                const fd = openProcDir(pid);
                if (fd < 0)
                    continue;
                scope (exit) close(fd);
                ProcStat st;
                if (!readStatUnder(fd, st, spent))
                    continue;
                seen[pid] = Seen(st, false);
            }

            // Membership over the snapshot: the ppid chain reaches the root,
            // or the process group is the root's.
            foreach (pid, ref s; seen)
            {
                int walker = pid;
                bool member;
                foreach (_; 0 .. 4096)
                {
                    if (walker == _rootPid)
                    {
                        member = true;
                        break;
                    }
                    auto next = walker in seen;
                    if (next is null || walker <= 1)
                        break;
                    walker = next.st.ppid;
                }
                s.member = member || s.st.pgrp == _rootPid;
            }
            foreach (pid, ref s; seen)
            {
                if (!s.member || alreadyProbed(scratch, pid))
                    continue;
                noteDiscovered(scratch, ProcessIdentity(pid, s.st.startTime), s.st);
            }
        }

        /// The root's descendants by the ppid tree: `/proc/<pid>/task/<tid>/
        /// children` per task, breadth-first, bounded by the budget. Cheap
        /// (no `/proc` walk) and independent of cgroup membership.
        void discoverByChildren(ref Scratch scratch, ref Spent spent) @trusted nothrow
        {
            import core.stdc.stdio : snprintf;
            import core.stdc.string : strlen;
            import core.sys.posix.dirent : closedir, dirent, opendir, readdir;

            int[] frontier = [_rootPid];
            uint visited;
            while (frontier.length)
            {
                const pid = frontier[0];
                frontier = frontier[1 .. $];
                if (++visited > budget.maxEntries || spent.exhausted(budget))
                {
                    scratch.budgetHit = true;
                    return;
                }
                // Every task of the process may have forked.
                char[64] taskDir = void;
                snprintf(taskDir.ptr, taskDir.length, "/proc/%d/task", pid);
                auto dir = opendir(taskDir.ptr);
                if (dir is null)
                    continue;
                scope (exit) closedir(dir);
                for (dirent* ent = readdir(dir); ent !is null; ent = readdir(dir))
                {
                    const name = ent.d_name.ptr[0 .. strlen(ent.d_name.ptr)];
                    ulong tid;
                    if (!parseUlong(name, tid))
                        continue;
                    char[96] path = void;
                    snprintf(path.ptr, path.length, "/proc/%d/task/%.*s/children",
                        pid, cast(int) name.length, name.ptr);
                    const fd = open(path.ptr, O_RDONLY | O_CLOEXEC);
                    if (fd < 0)
                        continue;
                    scope (exit) close(fd);
                    char[4096] buf = void;
                    const n = pread(fd, buf.ptr, buf.length, 0);
                    if (n <= 0)
                        continue;
                    spent.bytes += n;
                    // Space-separated pids.
                    size_t i;
                    while (i < cast(size_t) n)
                    {
                        while (i < n && buf[i] == ' ')
                            ++i;
                        const start = i;
                        while (i < n && buf[i] != ' ' && buf[i] != '\n')
                            ++i;
                        ulong childPid;
                        if (i > start && parseUlong(buf[start .. i], childPid)
                            && childPid <= int.max)
                            frontier ~= cast(int) childPid;
                    }
                }
                if (pid == _rootPid || alreadyProbed(scratch, pid))
                    continue;
                ++spent.entries;
                const fd = openProcDir(pid);
                if (fd < 0)
                    continue;
                scope (exit) close(fd);
                ProcStat st;
                if (!readStatUnder(fd, st, spent))
                    continue;
                noteDiscovered(scratch, ProcessIdentity(pid, st.startTime), st);
            }
        }

        /// `cgroupMembers`/`cgroupFull`: the run cgroup's roster, each member
        /// validated against the run path through its own per-sample handle.
        void discoverByRoster(ref Scratch scratch, ref Spent spent) @trusted nothrow
        {
            int[] roster;
            bool truncated;
            listMembers(*_cgroup, (int pid) nothrow { roster ~= pid; }, truncated);
            if (truncated)
                scratch.budgetHit = true;
            foreach (pid; roster)
            {
                if (spent.exhausted(budget))
                {
                    scratch.budgetHit = true;
                    break;
                }
                if (alreadyProbed(scratch, pid))
                    continue;
                ++spent.entries;
                const fd = openProcDir(pid);
                if (fd < 0)
                    continue;
                scope (exit) close(fd);
                // One pinned identity per sample: the cgroup line and the
                // stat come through the same handle.
                if (!insideCgroup(fd, _cgroup.path[], spent))
                    continue;
                ProcStat st;
                if (!readStatUnder(fd, st, spent))
                    continue;
                noteDiscovered(scratch, ProcessIdentity(pid, st.startTime), st);
            }
        }

        void merge(ref Scratch scratch, in CgroupRead cg) @safe nothrow
        {
            foreach (ref g; scratch.gone)
                ledger.retire(g);
            ulong rssPages;
            foreach (ref p; scratch.present)
            {
                if (p.admit)
                {
                    if (!ledger.admit(p.id, p.cpu))
                        scratch.rejected = true;
                }
                else
                    ledger.update(p.id, p.cpu);
                rssPages = saturatingAdd(rssPages, p.rssPages);
            }

            if (scratch.budgetHit || scratch.rejected)
                usage.accountingSaturated = true;
            const liveCount = scratch.present.length;
            if (liveCount == 0)
                return commitCgroupOnlyMerged(cg); // root unseen: keep prior peaks

            const rssBytes = rssPages > size_t.max / pageSize()
                ? size_t.max : cast(size_t)(rssPages * pageSize());
            if (rssBytes > usage.peakRssBytes)
                usage.peakRssBytes = rssBytes;
            if (liveCount > usage.peakProcesses)
                usage.peakProcesses = liveCount;
            usage.memorySource = MetricSource.procfs;
            usage.processSource = MetricSource.procfs;
            usage.memoryQuality = MetricQuality.lowerBound;
            usage.processQuality = MetricQuality.lowerBound;

            const total = ledger.total();
            const hz = clockTicksPerSecond();
            auto user = ticksToDuration(total.userTicks, hz);
            auto system = ticksToDuration(total.systemTicks, hz);
            usage.cpuSource = MetricSource.procfs;
            // Tree CPU = max(procfs accumulation, cgroup CPU): both are
            // lower bounds while containment is unenforced.
            if (cg.cpuOk)
            {
                const cu = usecs(cg.userUsec > long.max ? long.max : cast(long) cg.userUsec);
                const cs = usecs(cg.systemUsec > long.max ? long.max : cast(long) cg.systemUsec);
                if (cu + cs > user + system)
                {
                    user = cu;
                    system = cs;
                    usage.cpuSource = MetricSource.cgroup;
                }
            }
            if (user > usage.userTime)
                usage.userTime = user;
            if (system > usage.systemTime)
                usage.systemTime = system;
            usage.cpuQuality = MetricQuality.lowerBound;

            applyCgroup(cg);
            ++usage.sampleCount;
            usage.sampled = true;
        }

        /// A sample that saw no member (the root already gone from procfs)
        /// still records the cgroup counters and counts as a sample.
        void commitCgroupOnlyMerged(in CgroupRead cg) @safe nothrow @nogc
        {
            applyCgroup(cg);
            ++usage.sampleCount;
            usage.sampled = true;
        }

        bool commitCgroupOnly(in CgroupRead cg) @safe nothrow @nogc
        {
            if (_cgroup is null)
                return false;
            commitCgroupOnlyMerged(cg);
            return true;
        }

        void applyCgroup(in CgroupRead cg) @safe nothrow @nogc
        {
            if (_cgroup is null)
                return;
            if (cg.cpuOk)
            {
                usage.cgroupUserTime = usecs(cg.userUsec > long.max ? long.max : cast(long) cg.userUsec);
                usage.cgroupSystemTime = usecs(cg.systemUsec > long.max ? long.max : cast(long) cg.systemUsec);
                usage.cgroupCpuSource = MetricSource.cgroup;
                usage.cgroupCpuQuality = _cgroupCpuFailed
                    ? MetricQuality.lowerBound : MetricQuality.exact;
            }
            else if (usage.cgroupCpuSource == MetricSource.cgroup)
                usage.cgroupCpuQuality = MetricQuality.lowerBound;
            if (cg.memOk)
            {
                usage.peakCgroupMemoryBytes = cg.memPeak > size_t.max ? size_t.max : cast(size_t) cg.memPeak;
                usage.cgroupMemorySource = MetricSource.cgroup;
                usage.cgroupMemoryQuality = _cgroupMemFailed
                    ? MetricQuality.lowerBound : MetricQuality.exact;
            }
            else if (usage.cgroupMemorySource == MetricSource.cgroup)
                usage.cgroupMemoryQuality = MetricQuality.lowerBound;
            if (cg.tasksOk)
            {
                usage.peakTasks = cg.tasksPeak > size_t.max ? size_t.max : cast(size_t) cg.tasksPeak;
                usage.tasksSource = MetricSource.cgroup;
                usage.tasksQuality = _cgroupTasksFailed
                    ? MetricQuality.lowerBound : MetricQuality.exact;
            }
            else if (usage.tasksSource == MetricSource.cgroup)
                usage.tasksQuality = MetricQuality.lowerBound;
        }
    }
}
else
{
    /**
    Darwin stub: SPEC §13.8 names `proc_pid_rusage` + `proc_listchildpids`
    as the eventual source. Until that lands, sampling reports
    `sampled == false` rather than fabricated numbers.
    */
    package struct TreeSampler
    {
        @disable this(this);

        SampleSource source;
        SamplerBudget budget;
        ProcessResourceUsage usage;
        CpuLedger ledger;

        bool anchored() const @safe pure nothrow @nogc => false;
        void anchor(int, void*) @safe nothrow @nogc {}
        void finish() @safe nothrow @nogc {}
        bool sample() @safe nothrow @nogc => false;
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

@("sampling.ledger.boundedCardinalityTombstonesAndTotalInvariant")
@safe
unittest
{
    CpuLedger l;
    // Fill the live map; the next admission is a rejection, not growth.
    foreach (i; 0 .. CpuLedger.liveCapacity)
        assert(l.admit(ProcessIdentity(i + 10, 1), ProcessCpu(1, 1)));
    assert(!l.admit(ProcessIdentity(99_999, 1), ProcessCpu(1, 1)));
    assert(l.liveCount == CpuLedger.liveCapacity);
    assert(l.total() == ProcessCpu(CpuLedger.liveCapacity, CpuLedger.liveCapacity));

    // Retiring moves the last-known contribution into the scalar; the key
    // can never come back with the same identity.
    l.retire(ProcessIdentity(10, 1));
    assert(l.retired() == ProcessCpu(1, 1) && l.liveCount == CpuLedger.liveCapacity - 1);
    assert(!l.admit(ProcessIdentity(10, 1), ProcessCpu(5, 5)), "never re-admitted");
    assert(l.admit(ProcessIdentity(10, 2), ProcessCpu(2, 2)), "a new start time is a new identity");
    assert(l.total() == ProcessCpu(CpuLedger.liveCapacity + 2, CpuLedger.liveCapacity + 2));

    // Fill the retired set: the ledger seals; a later death becomes a
    // tombstone with cpu = 0 and the total does not jump.
    CpuLedger m;
    foreach (i; 0 .. CpuLedger.retiredCapacity)
    {
        assert(m.admit(ProcessIdentity(i + 1, 7), ProcessCpu(3, 0)));
        m.retire(ProcessIdentity(i + 1, 7));
    }
    assert(m.sealed && m.liveCount == 0);
    assert(m.retired().userTicks == 3 * CpuLedger.retiredCapacity);
    assert(!m.admit(ProcessIdentity(500_000, 1), ProcessCpu(1, 1)), "sealed: no admissions");
    // A live entry admitted before sealing, dying after it:
    CpuLedger n;
    assert(n.admit(ProcessIdentity(5, 1), ProcessCpu(40, 2)));
    foreach (i; 0 .. CpuLedger.retiredCapacity)
    {
        assert(n.admit(ProcessIdentity(i + 100, 7), ProcessCpu(1, 0)));
        n.retire(ProcessIdentity(i + 100, 7));
    }
    assert(n.sealed);
    const before = n.total();
    n.retire(ProcessIdentity(5, 1));
    assert(n.total() == before, "the tombstone transition moves cpu, never doubles it");
    assert(n.liveCount == 1, "the tombstone keeps its slot");
    assert(!n.isLive(ProcessIdentity(5, 1)));
    n.update(ProcessIdentity(5, 1), ProcessCpu(1000, 1000));
    assert(n.total() == before, "a tombstone is never summed or updated");
}

@("sampling.ledger.rotatingCursorDoesNotStarveTheTail")
@safe
unittest
{
    CpuLedger l;
    foreach (i; 0 .. 6)
        assert(l.admit(ProcessIdentity(i + 1, 1), ProcessCpu.init));
    int[] firstPass, secondPass;
    // A budget of three per pass (checked before the entry is processed,
    // as the sampler does): the second pass starts where the first stopped,
    // so every entry is visited across two passes.
    l.eachLiveFromCursor((ProcessIdentity id) nothrow {
        if (firstPass.length == 3)
            return false;
        firstPass ~= id.pid;
        return true;
    });
    l.eachLiveFromCursor((ProcessIdentity id) nothrow {
        if (secondPass.length == 3)
            return false;
        secondPass ~= id.pid;
        return true;
    });
    assert(firstPass.length == 3 && secondPass.length == 3);
    foreach (p; firstPass)
        foreach (q; secondPass)
            assert(p != q, "the second pass covers the un-probed tail");
}

version (linux)
{
    @("sampling.stat.parsesTheSixFieldsAroundACommWithSpaces")
    @safe pure nothrow @nogc
    unittest
    {
        // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt
        // majflt cmajflt utime stime cutime cstime priority nice threads
        // itrealvalue starttime vsize rss …
        ProcStat st;
        assert(parseProcStat(
            "1234 (a (b) c) S 100 1234 1 0 18446744073709551615 0 0 0 0 0 "
            ~ "77 33 0 0 20 0 1 0 987654 4096 55 18446744073709551615 0\n", st));
        assert(st.ppid == 100 && st.pgrp == 1234);
        assert(st.userTicks == 77 && st.systemTicks == 33);
        assert(st.startTime == 987_654 && st.rssPages == 55);
        assert(!parseProcStat("garbage", st));
        assert(!parseProcStat("1 (x) S 1 1", st), "too few fields");
        assert(ticksToDuration(100, 100) == 1_000_000.usecs);
        assert(ticksToDuration(ulong.max, 100) == Duration.max, "saturates");
    }

    version (unittest)
    {
        import core.sys.posix.signal : SIGKILL;
        import core.sys.posix.sys.wait : WNOHANG, waitpid;
        import core.thread : Thread;

        import sparkles.event_horizon.live : ChildProcess, spawnProcess;
        import sparkles.test_runner.skip : skipTest;

        /// A blocking reap for substrate tests (no scheduler involved).
        /// Guarded: `waitpid(-1)` would reap another test's child.
        private void reapBlocking(int pid) @trusted
        {
            if (pid <= 0)
                return;
            int raw;
            waitpid(pid, &raw, 0);
        }
    }

    @("sampling.procScan.foldsDescendantsRetiresTheDeadAndFailsClosedAfterReap")
    @system
    unittest
    {
        // Root + two children; the children exit first, then the root.
        auto spawned = spawnProcess(["sh", "-c",
            "sleep 0.3 & sleep 0.3 & sleep 0.8"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        scope (exit)
        {
            cast(void) child.kill(SIGKILL);
            reapBlocking(child.pid);
        }
        TreeSampler sampler;
        sampler.anchor(child.pid, null);
        assert(sampler.anchored && sampler.source == SampleSource.procScan);
        scope (exit) sampler.finish();

        Thread.sleep(80.msecs);
        assert(sampler.sample(), "a fold merged");
        assert(sampler.usage.sampled && sampler.usage.sampleCount == 1);
        assert(sampler.usage.peakProcesses >= 3, "root + two sleeps + shell forks");
        assert(sampler.usage.memoryQuality == MetricQuality.lowerBound);
        assert(sampler.usage.cpuSource == MetricSource.procfs);
        assert(!sampler.usage.samplingDegraded);
        const liveAfterFirst = sampler.ledger.liveCount;

        Thread.sleep(400.msecs);
        assert(sampler.sample());
        assert(sampler.ledger.liveCount < liveAfterFirst,
            "the exited children were retired, their CPU kept in the scalar");
        assert(sampler.usage.userTime + sampler.usage.systemTime >= Duration.zero);

        // After the root is reaped its /proc entry is gone: the anchor fails
        // closed and nothing is folded.
        cast(void) child.kill(SIGKILL);
        reapBlocking(child.pid);
        const countBefore = sampler.usage.sampleCount;
        assert(!sampler.sample(), "no fold without the original root");
        assert(sampler.usage.sampleCount == countBefore);
        assert(sampler.usage.samplingDegraded);
        child.pid = -1;
    }

    @("sampling.transaction.rootReplacedBetweenValidationsDiscardsTheScratch")
    @system
    unittest
    {
        auto spawned = spawnProcess(["sh", "-c", "sleep 0.5 & sleep 2"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        TreeSampler sampler;
        sampler.anchor(child.pid, null);
        assert(sampler.anchored);
        scope (exit) sampler.finish();
        Thread.sleep(50.msecs);
        assert(sampler.sample());
        const usageBefore = sampler.usage;
        const liveBefore = sampler.ledger.liveCount;

        // Between the two validations an external reaper takes the root:
        // the scan already ran, and none of it may be merged.
        auto childP = &child;
        sampler.testBetweenValidations = () nothrow {
            cast(void) childP.kill(SIGKILL);
            try
                reapBlocking(childP.pid);
            catch (Throwable)
            {
            }
        };
        assert(!sampler.sample(), "the second validation discards the sample");
        sampler.testBetweenValidations = null;
        assert(sampler.usage.sampleCount == usageBefore.sampleCount);
        assert(sampler.usage.peakProcesses == usageBefore.peakProcesses);
        assert(sampler.ledger.liveCount == liveBefore, "no half-applied retire/admit");
        assert(sampler.usage.samplingDegraded);
        child.pid = -1;
    }

    @("sampling.budget.exhaustionRetainsUnprobedEntriesAndReportsSaturation")
    @system
    unittest
    {
        auto spawned = spawnProcess(["sh", "-c", "sleep 0.5 & sleep 0.5 & sleep 1"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        scope (exit)
        {
            cast(void) child.kill(SIGKILL);
            reapBlocking(child.pid);
        }
        TreeSampler sampler;
        sampler.anchor(child.pid, null);
        scope (exit) sampler.finish();
        Thread.sleep(60.msecs);
        assert(sampler.sample());
        const live = sampler.ledger.liveCount;
        assert(live >= 3);

        // A budget of one entry: the re-probe stops after one member; the
        // others are retained (never proven dead), saturation is reported.
        sampler.budget.maxEntries = 1;
        assert(sampler.sample());
        assert(sampler.ledger.liveCount == live, "un-probed entries retained");
        assert(sampler.usage.accountingSaturated);
        assert(sampler.usage.cpuQuality == MetricQuality.lowerBound);
    }

    @("sampling.cgroupMembers.rosterValidatedAndCgroupCpuExact")
    @system
    unittest
    {
        import sparkles.event_horizon.cgroup : CgroupRun, createRun,
            migrateInto, cleanupRun, killTree;

        CgroupRun run;
        createRun(run, 900_077);
        if (run.tier == CgroupTier.none)
        {
            bool leaked;
            int failure;
            if (run.dirCreated)
                cleanupRun(run, 10.msecs, leaked, failure);
            skipTest("no owned cgroup v2 directory on this host");
        }
        // The fork waits for the migration: `cgroup.procs` moves one
        // process, so a child forked before the write stays outside the
        // cgroup (the pgid still covers it — SPEC §13.7).
        auto spawned = spawnProcess(["sh", "-c", "sleep 0.1; sleep 0.4 & sleep 1"]);
        assert(spawned.hasValue);
        auto child = spawned.value;
        assert(migrateInto(run, child.pid) == 0);

        TreeSampler sampler;
        sampler.anchor(child.pid, &run);
        assert(sampler.anchored);
        assert(sampler.source == (run.tier == CgroupTier.accounted
            ? SampleSource.cgroupFull : SampleSource.cgroupMembers));
        Thread.sleep(250.msecs);
        assert(sampler.sample());
        assert(sampler.usage.peakProcesses >= 2, "the roster saw the shell and a sleep");
        assert(sampler.usage.cgroupCpuSource == MetricSource.cgroup);
        assert(sampler.usage.cgroupCpuQuality == MetricQuality.exact,
            "the run cgroup's own counter is exact while every read succeeds");
        assert(sampler.usage.cpuQuality == MetricQuality.lowerBound,
            "tree CPU stays a lower bound under unenforced containment");
        if (run.tier == CgroupTier.accounted)
            assert(sampler.usage.tasksSource == MetricSource.cgroup
                && sampler.usage.peakTasks >= 2);
        sampler.finish();

        assert(killTree(run) == 0);
        reapBlocking(child.pid);
        child.pid = -1;
        bool leaked;
        int failure;
        cleanupRun(run, 2.seconds, leaked, failure);
        assert(!leaked);
    }
}
