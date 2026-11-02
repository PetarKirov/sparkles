/**
Windows tree sampling over the run's Job Object (SPEC §13.8, §13.9). The job
is the containment boundary every descendant joins from its first
instruction, and it keeps accounting for members that already exited:

$(UL
    $(LI basic-and-I/O accounting (class 8): cumulative user/kernel CPU over
        every process the job ever held, and its active-process count;)
    $(LI extended limit information (class 9): the job's peak committed
        memory (`PeakJobMemoryUsed`), which the kernel tracks itself;)
    $(LI the job's process-id list (class 3) and each member's
        `PROCESS_MEMORY_COUNTERS` (`K32GetProcessMemoryInfo`): current and
        peak working set.)
)

Two memory measures, kept apart:

$(UL
    $(LI `peakCgroupMemoryBytes` is $(B commit): the job's own peak of
        private committed memory, `exact` (source `jobObject`) — the
        container-level peak, like a cgroup's `memory.peak`;)
    $(LI `peakRssBytes` is $(B working set), the RSS-like measure, over the
        $(B whole tree): the peak over samples of the members' summed
        working sets, raised to the largest single member's kernel-kept
        `PeakWorkingSetSize` (the root's read through its own handle, valid
        after its exit). Both terms are lower bounds of the tree's true
        summed peak, so the quality is `lowerBound` (source `rusage`).)
)

CPU is charged to a thread when it is running at a clock-interval tick, so
it is a `lowerBound`, never `exact`. A member is opened by id and counted
only if `IsProcessInJob` confirms it, so a recycled id never is. A failed
query is a skipped sample; with no job at all, `sampled` stays false and only
wall time is valid.
*/
module sparkles.event_horizon.sampling_windows;

version (Windows):

import core.time : Duration, hnsecs;

import sparkles.event_horizon.live_windows : JobBasicAndIoAccounting, JobExtendedLimit,
    JobObjectBasicAndIoAccountingInformation, JobObjectExtendedLimitInformation,
    QueryInformationJobObject;
import sparkles.event_horizon.proc : MetricQuality, MetricSource,
    ProcessResourceUsage, SampleSource;
import sparkles.event_horizon.sampling : CpuLedger, SamplerBudget;

package struct TreeSampler
{
    @disable this(this);

    SampleSource source = SampleSource.jobObject;
    SamplerBudget budget;      /// unused: a job query is O(1)
    ProcessResourceUsage usage;
    CpuLedger ledger;          /// unused: the job accounts for exited members

    private void* _job;
    private void* _root;

    bool anchored() const @safe pure nothrow @nogc => _job !is null;

    /// Borrows the run's job handle; the child owns it until the reap,
    /// which follows the final sample.
    void anchor(int, void* job) @safe nothrow @nogc
    {
        usage.source = source;
        _job = job;
        if (_job is null)
            usage.samplingDegraded = true;
    }

    /// Borrows the root's process handle, whose counters outlive its exit
    /// until the reap closes it.
    void anchorRoot(void* process) @safe nothrow @nogc
    {
        _root = process;
    }

    void finish() @safe nothrow @nogc { _job = _root = null; }

    /// The job outlives any root: there is no pid identity to lose.
    bool sampleCgroupOnly() @safe nothrow @nogc => sample();

    /// One transactional sample: the job queries and the working-set walk
    /// all succeed or nothing is folded.
    bool sample() @safe nothrow @nogc
    {
        if (_job is null)
            return discard();
        JobBasicAndIoAccounting accounting;
        JobExtendedLimit limits;
        const ok = (() @trusted => QueryInformationJobObject(_job,
                JobObjectBasicAndIoAccountingInformation, &accounting,
                JobBasicAndIoAccounting.sizeof, null)
            && QueryInformationJobObject(_job, JobObjectExtendedLimitInformation,
                &limits, JobExtendedLimit.sizeof, null))();
        if (!ok)
            return discard();
        WorkingSets sets;
        if (!readWorkingSets(sets))
            return discard();
        const user = accounting.basic.TotalUserTime.hnsecs;
        const system = accounting.basic.TotalKernelTime.hnsecs;
        // Cumulative counters: never let a later sample report less.
        if (user > usage.userTime)
            usage.userTime = user;
        if (system > usage.systemTime)
            usage.systemTime = system;
        if (accounting.basic.ActiveProcesses > usage.peakProcesses)
            usage.peakProcesses = accounting.basic.ActiveProcesses;
        if (limits.PeakJobMemoryUsed > usage.peakCgroupMemoryBytes)
            usage.peakCgroupMemoryBytes = limits.PeakJobMemoryUsed;
        // The tree's summed working set at this instant, raised to any one
        // member's kernel-kept peak: both are lower bounds of the true peak.
        const rss = sets.sum > sets.peakOfOne ? sets.sum : sets.peakOfOne;
        if (rss > usage.peakRssBytes)
            usage.peakRssBytes = rss;
        usage.cpuSource = usage.processSource = usage.cgroupMemorySource
            = MetricSource.jobObject;
        usage.memorySource = MetricSource.rusage;
        usage.cpuQuality = MetricQuality.lowerBound;     // tick-sampled
        usage.processQuality = MetricQuality.lowerBound; // sampled peak
        usage.memoryQuality = MetricQuality.lowerBound;  // sampled sum
        usage.cgroupMemoryQuality = MetricQuality.exact; // the kernel's own peak
        usage.accountingSaturated |= sets.saturated;
        ++usage.sampleCount;
        usage.sampled = true;
        return true;
    }

    private static struct WorkingSets
    {
        size_t sum;       /// Σ current working set over the members read
        size_t peakOfOne; /// the largest member's `PeakWorkingSetSize`
        bool saturated;   /// the member list exceeded the per-sample budget
    }

    /**
    Reads the working set of the root (through its own handle, valid after
    its exit) and of every other process the job lists. A member is opened
    by id, so it is accepted only when `IsProcessInJob` confirms that the
    handle names a member of this job — a recycled id never counts. A member
    that exited between the listing and the open is skipped, never an error.
    */
    private bool readWorkingSets(out WorkingSets sets) @trusted nothrow @nogc
    {
        enum uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, maxListed = 256;
        static struct IdList
        {
            uint assigned, listed;
            size_t[maxListed] ids;
        }

        void fold(void* process)
        {
            ProcessMemoryCounters counters;
            counters.cb = ProcessMemoryCounters.sizeof;
            if (!K32GetProcessMemoryInfo(process, &counters, ProcessMemoryCounters.sizeof))
                return;
            sets.sum = counters.WorkingSetSize > size_t.max - sets.sum ? size_t.max
                : sets.sum + counters.WorkingSetSize;
            if (counters.PeakWorkingSetSize > sets.peakOfOne)
                sets.peakOfOne = counters.PeakWorkingSetSize;
        }

        uint rootId;
        if (_root !is null)
        {
            rootId = GetProcessId(_root);
            fold(_root);
        }
        IdList list;
        if (!QueryInformationJobObject(_job, JobObjectBasicProcessIdList, &list,
                IdList.sizeof, null) && GetLastError() != 234) // ERROR_MORE_DATA
            return false;
        const listed = list.listed < maxListed ? list.listed : maxListed;
        sets.saturated = list.assigned > listed || listed > budget.maxEntries;
        foreach (id; list.ids[0 .. listed > budget.maxEntries ? budget.maxEntries : listed])
        {
            if (id == rootId)
                continue;
            auto process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, cast(uint) id);
            if (process is null)
                continue; // already gone
            int member;
            if (IsProcessInJob(process, _job, &member) && member)
                fold(process);
            CloseHandle(process);
        }
        return true;
    }

    private bool discard() @safe nothrow @nogc
    {
        usage.samplingDegraded = true;
        return false;
    }
}

/// A job's accounting covers members that already exited, and a missing
/// job is an honest `sampled == false`.
@("sampling.windows.jobAccountingAndNoJob")
@system unittest
{
    import sparkles.event_horizon.live_windows : CreateJobObjectW;

    TreeSampler none;
    none.anchor(0, null);
    assert(!none.sample() && !none.usage.sampled && none.usage.samplingDegraded);

    auto job = CreateJobObjectW(null, null);
    assert(job !is null);
    scope (exit) CloseHandle(job);
    TreeSampler sampler;
    sampler.anchor(0, job);
    if (!sampler.sample())
    {
        import sparkles.event_horizon.sys.nt : runningUnderWine;
        import sparkles.test_runner.skip : skipTest;

        // Native Windows accounts an empty job; Wine may lack a class.
        assert(runningUnderWine(), "an empty job is still accountable");
        skipTest("Wine does not answer the job accounting classes");
    }
    assert(sampler.usage.sampled && sampler.usage.sampleCount == 1);
    assert(sampler.usage.peakProcesses == 0);
    assert(sampler.usage.cpuSource == MetricSource.jobObject);
    assert(sampler.usage.cpuQuality == MetricQuality.lowerBound);
}

private extern (Windows) int CloseHandle(void*) nothrow @nogc;

/// `PROCESS_MEMORY_COUNTERS`.
private struct ProcessMemoryCounters
{
    uint cb, PageFaultCount;
    size_t PeakWorkingSetSize, WorkingSetSize;
    size_t QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage;
    size_t QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage;
    size_t PagefileUsage, PeakPagefileUsage;
}

version (Win64)
    static assert(ProcessMemoryCounters.sizeof == 72);

private enum int JobObjectBasicProcessIdList = 3;

private extern (Windows) nothrow @nogc
{
    int K32GetProcessMemoryInfo(void* process, ProcessMemoryCounters* counters, uint size);
    void* OpenProcess(uint access, int inherit, uint id);
    int IsProcessInJob(void* process, void* job, int* result);
    uint GetProcessId(void* process);
    uint GetLastError();
}
