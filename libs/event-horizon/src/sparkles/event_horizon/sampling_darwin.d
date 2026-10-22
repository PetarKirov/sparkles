/** Darwin's bounded, identity-validated transactional process-tree sampler. */
module sparkles.event_horizon.sampling_darwin;

version (OSX):

import core.stdc.errno : ESRCH, errno;
import core.time : MonoTime, nsecs;

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

    version (unittest)
        package void delegate() @safe nothrow testBetweenValidations;

    bool anchored() const @safe pure nothrow @nogc => bound;

    void anchor(int pid, void*) @safe nothrow @nogc
    {
        usage.source = source;
        RusageV4 info;
        bound = readUsage(pid, info);
        if (bound)
            root = ProcessIdentity(pid, info.startTime);
        else
            usage.samplingDegraded = true;
    }

    ProcessIdentity rootIdentity() const @safe pure nothrow @nogc => root;
    void finish() @safe nothrow @nogc { bound = false; }
    bool sampleCgroupOnly() @safe pure nothrow @nogc => false;

    /** No counter or ledger mutation occurs before every identity and roster
    validates. A transient error, churn or exhausted budget discards scratch. */
    bool sample() @safe nothrow
    {
        if (!bound)
            return discard();
        const started = MonoTime.currTime;
        size_t bytes;
        uint entries;
        bool exhausted;
        bool charge(size_t amount) @safe nothrow
        {
            if (entries >= budget.maxEntries || amount > budget.maxBytes - bytes
                || MonoTime.currTime - started >= budget.maxTime)
            {
                exhausted = true;
                return false;
            }
            ++entries;
            bytes += amount;
            return true;
        }

        RusageV4 original;
        if (!charge(RusageV4.sizeof) || !readUsage(root.pid, original)
            || original.startTime != root.startTime)
            return discard(exhausted);

        Record[int] scratch;
        int[] pending = [root.pid];
        // Known descendants remain owned observations even after reparenting.
        // Their CPU is retired only on ESRCH or a verified changed identity,
        // never merely because a roster omitted them.
        ProcessIdentity[] retired;
        bool probesOk = true;
        ledger.eachLiveFromCursor((ProcessIdentity id) @safe nothrow {
            RusageV4 info;
            if (!charge(RusageV4.sizeof))
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
            else
                pending ~= id.pid;
            return probesOk;
        });
        if (!probesOk || exhausted)
            return discard(exhausted);

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
            // One extra entry detects a full/truncated roster; bounded stack
            // storage never silently certifies a partial child list.
            int[1025] children;
            if (!charge(children.sizeof))
                return discard(true);
            errno = 0;
            const count = (() @trusted => proc_listchildpids(pid,
                children.ptr, cast(int) children.sizeof))();
            if (count < 0 || (count == 0 && errno != 0))
                return discard();
            if (count >= children.length)
                return discard(true);
            foreach (child; children[0 .. count])
            {
                if (child <= 0 || child == pid)
                    return discard();
                record.children ~= child;
                if (pending.length >= budget.maxEntries)
                    return discard(true);
                pending ~= child;
            }
            scratch[pid] = record;
        }

        version (unittest)
            if (testBetweenValidations !is null)
                testBetweenValidations();

        // Validate every member and its child set again, then the root last.
        // An exec keeps startTime; a reused numeric pid does not.
        foreach (pid, ref record; scratch)
        {
            RusageV4 checked;
            int[1025] children;
            if (!charge(RusageV4.sizeof + children.sizeof))
                return discard(true);
            if (!readUsage(pid, checked) || checked.startTime != record.usage.startTime)
                return discard();
            errno = 0;
            const count = (() @trusted => proc_listchildpids(pid,
                children.ptr, cast(int) children.sizeof))();
            if (count < 0 || (count == 0 && errno != 0) || count != record.children.length)
                return discard();
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
        usage.userTime = (cpu.userTicks > long.max ? long.max : cast(long) cpu.userTicks).nsecs;
        usage.systemTime = (cpu.systemTicks > long.max ? long.max : cast(long) cpu.systemTicks).nsecs;
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
