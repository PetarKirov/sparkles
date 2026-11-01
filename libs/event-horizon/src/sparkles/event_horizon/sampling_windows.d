/**
Windows tree sampling over the run's Job Object (SPEC §13.8, §13.9). The job
is the containment boundary every descendant joins from its first
instruction, and it keeps accounting for members that already exited, so one
`QueryInformationJobObject` pair is the whole tree — no roster walk and no
identity revalidation:

$(UL
    $(LI basic-and-I/O accounting (class 8): cumulative user/kernel CPU over
        every process the job ever held, and its active-process count;)
    $(LI extended limit information (class 9): the job's peak committed
        memory, which the kernel tracks itself.)
)

CPU is charged to a thread when it is running at a clock-interval tick, so
it is a `lowerBound`, never `exact`. The job's peak commit is the run
container's own memory peak and lands in `peakCgroupMemoryBytes` (source
`jobObject`); per-process resident sizes are not read, so `peakRssBytes`
stays unmeasured. A failed query is a skipped sample; with no job at all,
`sampled` stays false and only wall time is valid.
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

    void finish() @safe nothrow @nogc { _job = null; }

    /// The job outlives any root: there is no pid identity to lose.
    bool sampleCgroupOnly() @safe nothrow @nogc => sample();

    /// One transactional sample: both queries succeed or nothing is folded.
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
        usage.cpuSource = usage.processSource = usage.cgroupMemorySource
            = MetricSource.jobObject;
        usage.cpuQuality = MetricQuality.lowerBound;     // tick-sampled
        usage.processQuality = MetricQuality.lowerBound; // sampled peak
        usage.cgroupMemoryQuality = MetricQuality.exact; // the kernel's own peak
        ++usage.sampleCount;
        usage.sampled = true;
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

version (unittest)
private extern (Windows) int CloseHandle(void*) nothrow @nogc;
