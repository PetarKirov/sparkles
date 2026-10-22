/** Darwin's bounded, identity-validated transactional process-tree sampler. */
module sparkles.event_horizon.sampling_darwin;

version (OSX):

import core.stdc.errno : ESRCH, errno;
import core.time : Duration, MonoTime, nsecs;

import sparkles.event_horizon.proc : MetricQuality, MetricSource,
    ProcessResourceUsage, SampleSource;
import sparkles.event_horizon.sampling : CpuLedger, ProcessCpu, ProcessIdentity, SamplerBudget;

// ABI of RUSAGE_INFO_V4. Only the leading fields we consume are named; the
// remaining V1–V4 counters are still reserved in full, never undersized.
private struct RusageV4
{
    ubyte[16] uuid;
    ulong userTime, systemTime, packageWakeups, interruptWakeups, pageins;
    ulong wiredSize, residentSize, footprint, startTime, exitTime;
    ulong[25] remaining;
}
static assert(RusageV4.sizeof == 296);

private extern (C) nothrow @nogc
{
    int proc_pid_rusage(int pid, int flavor, void* buffer);
    int proc_listchildpids(int pid, void* buffer, int bytes);
    int mach_timebase_info(Timebase* info);
    ulong clock_gettime_nsec_np(uint clock);
}

/// The sampling thread's own CPU clock, as on Linux: a budget on work done,
/// which preemption under load cannot spend on the sampler's behalf.
private Duration threadCpuNow() @trusted nothrow @nogc
{
    enum uint CLOCK_THREAD_CPUTIME_ID = 16; // <time.h>
    return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID).nsecs;
}

private struct Timebase
{
    uint numer;
    uint denom;
}

// libproc CPU counters are Mach absolute ticks. Divide first so a long-lived
// process cannot overflow the multiply before the saturating Duration bound.
private Duration cpuDuration(ulong ticks, in Timebase timebase) @safe pure nothrow @nogc
in (timebase.numer != 0 && timebase.denom != 0)
{
    const whole = ticks / timebase.denom;
    if (whole > cast(ulong) long.max / timebase.numer)
        return long.max.nsecs;
    const remainder = (ticks % timebase.denom) * timebase.numer / timebase.denom;
    const base = whole * timebase.numer;
    return (base > cast(ulong) long.max - remainder
        ? long.max : cast(long)(base + remainder)).nsecs;
}

package struct TreeSampler
{
    @disable this(this);

    SampleSource source = SampleSource.darwinTree;
    SamplerBudget budget;
    ProcessResourceUsage usage;
    CpuLedger ledger;

    private ProcessIdentity root;
    private bool bound;
    private Timebase timebase;

    // Test seams, declared in every build so the layout never depends on
    // `-unittest`.
    package void delegate() @safe nothrow testBetweenValidations;
    package void delegate(ulong[int] expectedStart) @safe nothrow testAfterLedgerScan;

    bool anchored() const @safe pure nothrow @nogc => bound;

    void anchor(int pid, void*) @safe nothrow @nogc
    {
        usage.source = source;
        RusageV4 info;
        const clockReady = (() @trusted => mach_timebase_info(&timebase) == 0)()
            && timebase.numer != 0 && timebase.denom != 0;
        bound = clockReady && readUsage(pid, info);
        if (bound)
            root = ProcessIdentity(pid, info.startTime);
        else
            usage.samplingDegraded = true;
    }

    ProcessIdentity rootIdentity() const @safe pure nothrow @nogc => root;
    void finish() @safe nothrow @nogc { bound = false; }
    bool sampleCgroupOnly() @safe pure nothrow @nogc => false;

    /** No CPU total, peak or ledger membership changes before every identity
    and roster validates; only the ledger's scan cursor advances, so a sample
    the budget cut short resumes where it stopped. A transient error, churn or
    exhausted budget discards scratch. */
    bool sample() @safe nothrow
    {
        if (!bound)
            return discard();
        const started = threadCpuNow();
        size_t bytes;
        uint entries;
        bool[int] visited;
        bool exhausted;
        // Count distinct pids probed, not repeated identity validations or
        // calls on the same member. Bytes account for every returned payload.
        bool visit(int pid) @safe nothrow
        {
            if (pid in visited)
                return true;
            if (entries >= budget.maxEntries)
            {
                exhausted = true;
                return false;
            }
            visited[pid] = true;
            ++entries;
            return true;
        }
        bool charge(size_t amount) @safe nothrow
        {
            if (amount > budget.maxBytes - bytes
                || threadCpuNow() - started >= budget.maxTime)
            {
                exhausted = true;
                return false;
            }
            bytes += amount;
            return true;
        }

        RusageV4 original;
        if (!visit(root.pid) || !charge(RusageV4.sizeof) || !readUsage(root.pid, original)
            || original.startTime != root.startTime)
            return discard(exhausted);

        Record[int] scratch;
        int[] pending = [root.pid];
        bool[int] queued = [root.pid: true];
        // The start time each pid was queued under. No roster vouches for a
        // reparented member, so this is what tells it from a process that
        // took its pid after it exited.
        ulong[int] expectedStart = [root.pid: root.startTime];
        // Known descendants remain owned observations even after reparenting.
        // Their CPU is retired only on ESRCH or a verified changed identity,
        // never merely because a roster omitted them.
        ProcessIdentity[] retired;
        bool probesOk = true;
        ledger.eachLiveFromCursor((ProcessIdentity id) @safe nothrow {
            RusageV4 info;
            if (!visit(id.pid) || !charge(RusageV4.sizeof))
                return false;
            if (!readUsage(id.pid, info))
            {
                if (errno == ESRCH)
                    retired ~= id;
                else
                    probesOk = false;
            }
            else if (info.startTime != id.startTime)
                retired ~= id;
            else if (id.pid !in queued)
            {
                queued[id.pid] = true;
                pending ~= id.pid;
                expectedStart[id.pid] = id.startTime;
            }
            return probesOk;
        });
        if (!probesOk || exhausted)
            return discard(exhausted);
        if (testAfterLedgerScan !is null)
            testAfterLedgerScan(expectedStart);

        for (size_t cursor; cursor < pending.length; ++cursor)
        {
            const pid = pending[cursor];
            if (pid in scratch)
                continue;
            if (!charge(RusageV4.sizeof))
                return discard(true);
            Record record;
            if (!readUsage(pid, record.usage))
                return discard();
            if (auto start = pid in expectedStart)
                if (*start != record.usage.startTime)
                    return discard(); // the member exited; its pid is reused
            // One extra entry detects a full/truncated roster; bounded stack
            // storage never silently certifies a partial child list.
            int[1025] children;
            if (!charge(0))
                return discard(true);
            errno = 0;
            const count = (() @trusted => proc_listchildpids(pid,
                children.ptr, cast(int) children.sizeof))();
            if (count < 0 || (count == 0 && errno != 0))
                return discard();
            if (count >= children.length)
                return discard(true);
            if (!charge(cast(size_t) count * int.sizeof))
                return discard(true);
            foreach (child; children[0 .. count])
            {
                if (child <= 0 || child == pid)
                    return discard();
                record.children ~= child;
                if (!visit(child))
                    return discard(true);
                if (child !in queued)
                {
                    queued[child] = true;
                    pending ~= child;
                }
            }
            scratch[pid] = record;
        }

        if (testBetweenValidations !is null)
            testBetweenValidations();

        // Validate every member and its child set again, then the root last.
        // An exec keeps startTime; a reused numeric pid does not.
        foreach (pid, ref record; scratch)
        {
            RusageV4 checked;
            int[1025] children;
            if (!charge(RusageV4.sizeof))
                return discard(true);
            if (!readUsage(pid, checked) || checked.startTime != record.usage.startTime)
                return discard();
            errno = 0;
            const count = (() @trusted => proc_listchildpids(pid,
                children.ptr, cast(int) children.sizeof))();
            if (count < 0 || (count == 0 && errno != 0) || count != record.children.length)
                return discard();
            if (!charge(cast(size_t) count * int.sizeof))
                return discard(true);
            foreach (child; children[0 .. count])
            {
                bool found;
                foreach (known; record.children)
                    found |= child == known;
                if (!found)
                    return discard();
            }
        }
        if (!charge(RusageV4.sizeof) || !readUsage(root.pid, original)
            || original.startTime != root.startTime)
            return discard(exhausted);

        foreach (id; retired)
            ledger.retire(id);
        ulong resident;
        foreach (pid, ref record; scratch)
        {
            const id = ProcessIdentity(pid, record.usage.startTime);
            const cpu = ProcessCpu(record.usage.userTime, record.usage.systemTime);
            if (ledger.isLive(id))
                ledger.update(id, cpu);
            else if (!ledger.admit(id, cpu))
                usage.accountingSaturated = true;
            resident = record.usage.residentSize > ulong.max - resident
                ? ulong.max : resident + record.usage.residentSize;
        }
        const cpu = ledger.total();
        usage.userTime = cpuDuration(cpu.userTicks, timebase);
        usage.systemTime = cpuDuration(cpu.systemTicks, timebase);
        if (resident > usage.peakRssBytes)
            usage.peakRssBytes = resident > size_t.max ? size_t.max : cast(size_t) resident;
        if (scratch.length > usage.peakProcesses)
            usage.peakProcesses = scratch.length;
        usage.cpuSource = usage.memorySource = usage.processSource = MetricSource.rusage;
        usage.cpuQuality = usage.memoryQuality = usage.processQuality = MetricQuality.lowerBound;
        ++usage.sampleCount;
        usage.sampled = true;
        return true;
    }

    private bool discard(bool saturated = false) @safe nothrow @nogc
    {
        usage.samplingDegraded = true;
        usage.accountingSaturated |= saturated;
        return false;
    }

    private struct Record
    {
        RusageV4 usage;
        int[] children;
    }
}

private bool readUsage(int pid, out RusageV4 info) @safe nothrow @nogc
    => (() @trusted => proc_pid_rusage(pid, 4, &info) == 0)();

/// Real libproc accounting, and an aborted transaction that cannot alter the
/// last committed metrics or CPU ledger.
@("sampling.darwin.realUsageAndTransactionalBudget")
@system nothrow unittest
{
    import core.sys.posix.unistd : getpid;
    import core.time : Duration;

    TreeSampler sampler;
    sampler.anchor(getpid(), null);
    assert(sampler.anchored);
    assert(sampler.sample());
    assert(sampler.usage.sampled && sampler.usage.peakProcesses >= 1);
    assert(sampler.usage.peakRssBytes > 0);
    assert(sampler.usage.cpuSource == MetricSource.rusage);
    const before = sampler.usage;
    const cpu = sampler.ledger.total();
    const originalRoot = sampler.root;
    sampler.testBetweenValidations = () @safe nothrow {
        ++sampler.root.startTime;
    };
    assert(!sampler.sample(), "a changed root identity discards the transaction");
    assert(sampler.usage.sampleCount == before.sampleCount);
    assert(sampler.ledger.total() == cpu);
    sampler.root = originalRoot;
    sampler.testBetweenValidations = null;
    sampler.budget.maxEntries = 0;
    assert(!sampler.sample());
    assert(sampler.usage.accountingSaturated && sampler.usage.samplingDegraded);
    assert(sampler.usage.sampleCount == before.sampleCount);
    assert(sampler.usage.userTime == before.userTime);
    assert(sampler.ledger.total() == cpu);
    sampler.finish();
    assert(!sampler.sample());
}

/// A small byte budget covers real rusage records and empty child rosters,
/// not the capacity of the reused child-list stack buffer.
@("sampling.darwin.budgetChargesReturnedBytes")
@system unittest
{
    import core.sys.posix.signal : SIGKILL, kill;
    import core.sys.posix.sys.wait : waitpid;
    import core.time : seconds;
    import std.process : spawnProcess;

    // An owned leaf avoids sharing this test process's child roster with
    // concurrently running tests.
    auto child = spawnProcess(["/bin/sleep", "30"]);
    const pid = child.processID;
    scope (exit)
    {
        kill(pid, SIGKILL);
        int status;
        waitpid(pid, &status, 0);
    }

    TreeSampler sampler;
    sampler.anchor(pid, null);
    assert(sampler.sample());
    sampler.budget.maxTime = 2.seconds;
    sampler.budget.maxEntries = 1; // repeated probes of the same pid count once
    // Root validation (twice), known-member probe, discovery and revalidation.
    sampler.budget.maxBytes = 5 * RusageV4.sizeof;
    assert(sampler.sample(), "empty rosters consume zero payload bytes");
    const count = sampler.usage.sampleCount;
    const cpu = sampler.ledger.total();
    sampler.budget.maxBytes--;
    assert(!sampler.sample(), "one missing rusage byte exhausts the budget");
    assert(sampler.usage.sampleCount == count && sampler.ledger.total() == cpu);
}

/// A live child is discovered through libproc rather than just counting the
/// root. Reaping it retires its identity without losing cumulative CPU.
@("sampling.darwin.discoversAndRetiresChild")
@system unittest
{
    import core.sys.posix.signal : SIGKILL, kill;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : getpid;
    import std.process : spawnProcess;

    auto child = spawnProcess(["/bin/sleep", "30"]);
    const pid = child.processID;
    bool consumed;
    scope (exit)
    {
        if (!consumed)
        {
            kill(pid, SIGKILL);
            int status;
            waitpid(pid, &status, 0);
        }
    }
    TreeSampler sampler;
    sampler.anchor(getpid(), null);
    assert(sampler.sample());
    assert(sampler.usage.peakProcesses >= 2, "the child roster contains the live child");
    bool found;
    sampler.ledger.eachLiveFromCursor((ProcessIdentity id) {
        found |= id.pid == pid;
        return true;
    });
    assert(found);
    const before = sampler.ledger.total();
    assert(kill(pid, SIGKILL) == 0);
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    consumed = true;
    assert(sampler.sample());
    const after = sampler.ledger.total();
    assert(after.userTicks >= before.userTicks && after.systemTicks >= before.systemTicks);
    sampler.ledger.eachLiveFromCursor((ProcessIdentity id) {
        assert(id.pid != pid, "reaped children are retired, never silently re-admitted");
        return true;
    });
}

/// Counter units are checked against getrusage on the native host, including
/// Apple Silicon where the Mach timebase is not one tick per nanosecond.
@("sampling.darwin.cpuCounterUnitsMatchRusage")
@system unittest
{
    import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
    import core.sys.posix.unistd : getpid;
    import core.time : msecs;

    RusageV4 before, after;
    rusage referenceBefore, referenceAfter;
    assert(readUsage(getpid(), before));
    assert(getrusage(RUSAGE_SELF, &referenceBefore) == 0);
    const until = MonoTime.currTime + 100.msecs;
    while (MonoTime.currTime < until) {}
    assert(getrusage(RUSAGE_SELF, &referenceAfter) == 0);
    assert(readUsage(getpid(), after));
    static long cpuNs(in rusage value) @safe pure nothrow @nogc
        => (value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1_000_000_000L
            + (value.ru_utime.tv_usec + value.ru_stime.tv_usec) * 1000L;
    const expected = cpuNs(referenceAfter) - cpuNs(referenceBefore);
    Timebase timebase;
    assert(mach_timebase_info(&timebase) == 0);
    const actual = cpuDuration(after.userTime + after.systemTime
        - before.userTime - before.systemTime, timebase).total!"nsecs";
    assert(expected > 0);
    assert(actual > expected / 2 && actual < expected * 2,
        "libproc CPU units must be converted to the getrusage time scale");
}

/// Non-unit Mach timebases and long-lived counter saturation are deterministic.
@("sampling.darwin.cpuDuration.nonUnitAndSaturation")
@safe pure nothrow @nogc unittest
{
    assert(cpuDuration(24_000_000, Timebase(125, 3)) == 1_000_000_000L.nsecs);
    assert(cpuDuration(1, Timebase(125, 3)) == 41.nsecs);
    assert(cpuDuration(ulong.max, Timebase(125, 3)) == long.max.nsecs);
    assert(cpuDuration(ulong.max, Timebase(1, uint.max))
        == (cast(long)(ulong.max / uint.max)).nsecs);
}

/// A tracked member that exits and whose pid a new process takes between the
/// ledger scan and the walk is caught by its start time: the sample is
/// discarded rather than admitting the stranger. The hook stands in for the
/// reuse by changing the start time the member was queued under.
@("sampling.darwin.reusedMemberPidDiscardsTheSample")
@system unittest
{
    import core.sys.posix.signal : SIGKILL, kill;
    import core.sys.posix.sys.wait : waitpid;
    import core.time : seconds;
    import std.process : spawnProcess;

    // `sh` stays the root while its `sleep` child is a non-root member.
    auto shell = spawnProcess(["/bin/sh", "-c", "/bin/sleep 30 & wait"]);
    const pid = shell.processID;
    TreeSampler sampler;
    scope (exit)
    {
        // The `sleep` is in the ledger; `sh` is no group leader to signal.
        sampler.ledger.eachLiveFromCursor((ProcessIdentity id) {
            kill(id.pid, SIGKILL);
            return true;
        });
        kill(pid, SIGKILL);
        int status;
        waitpid(pid, &status, 0);
    }

    sampler.anchor(pid, null);
    const deadline = MonoTime.currTime + 5.seconds;
    while (!(sampler.sample() && sampler.usage.peakProcesses >= 2))
        assert(MonoTime.currTime < deadline, "the sleep child never appeared");
    const count = sampler.usage.sampleCount;
    const cpu = sampler.ledger.total();

    bool reused;
    sampler.testAfterLedgerScan = (ulong[int] expectedStart) @safe nothrow {
        foreach (member, ref start; expectedStart)
            if (member != pid)
            {
                ++start;
                reused = true;
            }
    };
    assert(!sampler.sample(), "a member under a reused pid discards the sample");
    assert(reused, "the scan queued the non-root member");
    assert(sampler.usage.sampleCount == count && sampler.ledger.total() == cpu);
}
