/++
The impure half of the run records (`perf_record`): the facts a host can
supply, the producer's identity for the privacy scan, the run identifier, and
`RunRecorder`, which the test modes hand each package run to.

Every fact is read from a source that names no person (OBP3): the commit and
dirtiness from git, the OS, kernel, CPU and memory from the kernel's own
interfaces, the compiler's version from the compiler, and the provider from
its documented variables. A fact that cannot be read is left out (OBV8).
+/
module perf_run;

import core.time : MonoTime;
import std.algorithm.searching : canFind, startsWith;
import std.array : split;
import std.conv : to;
import std.datetime.systime : Clock, SysTime;
import std.path : baseName;
import std.process : environment;
import std.string : indexOf, lineSplitter, strip;

import sparkles.build_primitives.git_env : runGitStdout;
import sparkles.core_cli.process_utils : runCaptured;

import perf_record : Producer, RecordedTask, RunFacts, TaskOutcome, encodeRecord, githubRunId, isRunId,
    localRecordsRoot, writeRecord;

/// The facts of a run of `command` in `repoRoot` (OBR7, before the build graph).
RunFacts collectFacts(string repoRoot, string command, string[] options, string placement,
    string shard) @trusted
{
    RunFacts f;
    f.command = command;
    f.options = options;
    f.placement = placement;
    f.shard = shard;

    const head = runGitStdout(["rev-parse", "HEAD"], workDir: repoRoot);
    if (head.status == 0)
        f.commit = head.output.strip;
    const status = runGitStdout(["status", "--porcelain", "--untracked-files=no"], workDir: repoRoot);
    f.dirty = status.status == 0 && status.output.strip.length > 0;

    const dc = environment.get("DC", "ldc2");
    f.compiler = dc.baseName.canFind("dmd") ? "dmd" : dc.baseName.canFind("gdc") ? "gdc" : "ldc2";
    const version_ = runCaptured([dc, "--version"]);
    if (version_.succeeded)
        foreach (line; version_.stdout.lineSplitter)
            if (line.strip.length)
            {
                f.compilerVersion = line.strip;
                break;
            }

    version (linux)
        f.os = "linux";
    else version (OSX)
        f.os = "darwin";
    else version (Windows)
        f.os = "windows";
    else version (FreeBSD)
        f.os = "freebsd";

    const uname = runCaptured(["uname", "-r"]);
    if (uname.succeeded)
        f.kernel = uname.stdout.strip;

    version (linux)
    {
        import std.file : exists, readText;

        if (exists("/proc/cpuinfo"))
            foreach (line; readText("/proc/cpuinfo").lineSplitter)
            {
                const colon = line.indexOf(':');
                if (colon < 0)
                    continue;
                const key = line[0 .. colon].strip, value = line[colon + 1 .. $].strip;
                if (key == "model name" && f.cpuModel.length == 0)
                    f.cpuModel = value;
                else if (key == "vendor_id" && f.cpuVendor.length == 0)
                    f.cpuVendor = value;
                else if (key == "cpu family" && f.cpuFamily == 0)
                    f.cpuFamily = parseCount(value);
                else if (key == "model" && f.cpuModelNumber == 0)
                    f.cpuModelNumber = parseCount(value);
                else if (key == "CPU implementer" && f.cpuVendor.length == 0)
                    f.cpuVendor = value; // arm64
            }
        if (exists("/proc/meminfo"))
            foreach (line; readText("/proc/meminfo").lineSplitter)
                if (line.startsWith("MemTotal:"))
                {
                    const kib = parseCount(line["MemTotal:".length .. $].strip.split(" ")[0]);
                    f.memoryGiB = cast(uint) ((cast(ulong) kib + (1 << 19)) >> 20);
                }
    }
    else version (OSX)
    {
        const brand = runCaptured(["sysctl", "-n", "machdep.cpu.brand_string"]);
        if (brand.succeeded)
            f.cpuModel = brand.stdout.strip;
        const mem = runCaptured(["sysctl", "-n", "hw.memsize"]);
        if (mem.succeeded)
            f.memoryGiB = cast(uint) ((parseLong(mem.stdout.strip) + (1L << 29)) >> 30);
    }

    import graph_driver : logicalProcessors;

    f.logicalCores = logicalProcessors;

    if (environment.get("GITHUB_ACTIONS") == "true")
    {
        f.provider = "github";
        const event = environment.get("GITHUB_EVENT_NAME");
        const refName = environment.get("GITHUB_REF", "");
        if (event == "pull_request" && refName.startsWith("refs/pull/"))
            f.pullRequest = refName["refs/pull/".length .. $].split("/")[0];
        else
            f.branch = environment.get("GITHUB_REF_NAME");
    }
    else if (environment.get("CIRCLECI") == "true")
    {
        f.provider = "circleci";
        const pr = environment.get("CIRCLE_PR_NUMBER");
        if (pr.length)
            f.pullRequest = pr;
        else
            f.branch = environment.get("CIRCLE_BRANCH");
    }
    return f;
}

private uint parseCount(in char[] s) @safe pure nothrow
{
    uint n;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            break;
        n = n * 10 + (c - '0');
    }
    return n;
}

private long parseLong(in char[] s) @safe pure nothrow
{
    long n;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            break;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// The producer's names and git email, which the privacy scan rejects (OBP4).
Producer currentProducer(string repoRoot) @trusted
{
    import std.socket : Socket;

    Producer p;
    p.userName = environment.get("USER", environment.get("USERNAME", ""));
    p.homeLastSegment = environment.get("HOME", "").baseName;
    try
        p.hostName = Socket.hostName;
    catch (Exception)
    {
    }
    const email = runGitStdout(["config", "user.email"], workDir: repoRoot);
    if (email.status == 0)
        p.gitEmail = email.output.strip;
    return p;
}

/**
This invocation's run identifier (OBD1). On GitHub Actions the job's key and
`jobIdentity` (its placement and shard, which are its matrix values) name the
job, and a counter under `$RUNNER_TEMP` numbers the `ci` runs in it.
*/
string currentRunId(string jobIdentity) @trusted
{
    import std.file : exists, readText, write;
    import std.path : buildPath;
    import std.random : uniform;
    import std.format : format;

    if (environment.get("GITHUB_ACTIONS") == "true")
    {
        uint ordinal = 1;
        const temp = environment.get("RUNNER_TEMP", "");
        if (temp.length)
        {
            const counter = buildPath(temp, "sparkles-perf-invocations");
            try
            {
                if (exists(counter))
                    ordinal = readText(counter).strip.to!uint + 1;
                write(counter, ordinal.to!string);
            }
            catch (Exception)
            {
            }
        }
        const id = githubRunId(environment.get("GITHUB_RUN_ID", "0"), environment.get("GITHUB_RUN_ATTEMPT", "1"),
            environment.get("GITHUB_JOB", "") ~ "\0" ~ jobIdentity, ordinal);
        if (isRunId(id))
            return id;
    }
    string hex;
    foreach (_; 0 .. 32)
        hex ~= "0123456789abcdef"[uniform(0, 16)];
    return "local-" ~ hex;
}

/**
Collects one run's tasks and writes its record when the run ends. Each test
leg calls `begin` and `end`; `finish` writes the record and returns the run
degradation, if any, which the caller reports without changing its exit
status (OBD11).
*/
struct RunRecorder
{
    private string repoRoot;
    private RunFacts facts;
    private string runId;
    private string origin;
    private SysTime start;
    private MonoTime startClock;
    private RecordedTask[] tasks;
    private MonoTime taskStart;

    static RunRecorder open(string repoRoot, string command, string[] options, string placement,
        string shard) @trusted
    {
        RunRecorder r;
        r.repoRoot = repoRoot;
        r.facts = collectFacts(repoRoot, command, options, placement, shard);
        r.runId = currentRunId(placement ~ "\0" ~ shard);
        r.origin = r.facts.provider.length ? "ci" : "local";
        r.start = Clock.currTime.toUTC;
        r.startClock = MonoTime.currTime;
        return r;
    }

    /// The start of the task about to run.
    void begin() @safe nothrow
    {
        taskStart = MonoTime.currTime;
    }

    /// The end of the task `begin` started.
    void end(string taskId, bool passed) @safe nothrow
    {
        const now = MonoTime.currTime;
        tasks ~= RecordedTask(taskId, passed ? TaskOutcome.passed : TaskOutcome.failed,
            cast(ulong) (taskStart - startClock).total!"nsecs", cast(ulong) (now - startClock).total!"nsecs");
    }

    /// A task that ran from `began` to `ended`, measured by its runner: a
    /// test leg the build graph ran beside others.
    void add(string taskId, bool passed, MonoTime began, MonoTime ended) @safe nothrow
    {
        tasks ~= RecordedTask(taskId, passed ? TaskOutcome.passed : TaskOutcome.failed,
            began > startClock ? cast(ulong) (began - startClock).total!"nsecs" : 0,
            ended > startClock ? cast(ulong) (ended - startClock).total!"nsecs" : 0);
    }

    /// Write the record; the run degradation, or null.
    string finish() @trusted
    {
        import std.format : format;

        const startUtc = format("%04d-%02d-%02dT%02d:%02d:%02dZ", start.year, cast(int) start.month, start.day,
            start.hour, start.minute, start.second);
        const files = encodeRecord(runId, origin, startUtc, facts, tasks, null);
        return writeRecord(localRecordsRoot(), startUtc, runId, files, currentProducer(repoRoot));
    }

    /// The identifier the record is written under.
    string id() const @safe pure nothrow @nogc => runId;
}
