module sparkles.core_cli.process_utils;

import core.time : Duration, MonoTime, msecs;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.readers :
    readInteger, readUntil, skipSpaces, tryConsume;

void enforceExitStatus(int status, string command)
{
    import std.format : format;
    import std.exception : enforce;
    enforce(status == 0,
        "Command `%s` failed with exit code %s.".format(command, status)
    );
}

string executeShell(in string command)
{
    import std.process : executeShell;
    const result = command.executeShell;
    enforceExitStatus(result.status, command);
    return result.output;
}

// ---------------------------------------------------------------------------
// PATH lookup and captured execution
// ---------------------------------------------------------------------------

/**
The path `$PATH` resolves `name` to, or `null` when nothing runnable is found.

Mirrors a shell's command lookup: each `$PATH` entry is joined with `name` and
the candidate must exist, be a regular file, and (on POSIX) be executable by the
current user.

The regular-file test is the load-bearing one. A directory carries the execute
bit too — it means "searchable" — so a lookup that only tests for executability
matches a same-named *directory* and hands `execve` something it can only fail
on, with `EACCES`. This repo has `nix/`, `ci/`, `apps/` and `docs/` at its root
and the dev shells put `.` on `$PATH`, so the mistake is reachable by simply
running a tool from the repo root.
*/
string resolveInPath(string name) @safe
{
    import std.process : environment;

    return resolveInPathList(name, environment.get("PATH", ""));
}

/**
As $(LREF resolveInPath), but searching an explicitly supplied `$PATH` value
rather than the process environment.

Separated out so the search can be exercised against a crafted `$PATH` without
mutating the environment — which, with a parallel test runner, every other test
in the process would see.
*/
string resolveInPathList(string name, string pathVar) @safe
{
    import std.algorithm.iteration : splitter;
    import std.file : exists, isFile;
    import std.path : buildPath, pathSeparator;

    static bool runnable(scope const(char)[] candidate) @safe
        => candidate.exists && candidate.isFile && isExecutable(candidate);

    foreach (dir; pathVar.splitter(pathSeparator))
    {
        if (dir.length == 0)
            continue;
        const candidate = dir.buildPath(name);
        if (runnable(candidate))
            return candidate.idup;
        version (Windows)
        {
            // On Windows the runnable file is usually `name.exe`/`.cmd`/…, not
            // the bare `name`; try each PATHEXT extension in turn.
            import std.process : environment;

            const pathExt = environment.get("PATHEXT", ".COM;.EXE;.BAT;.CMD");
            foreach (ext; pathExt.splitter(';'))
            {
                if (!ext.length)
                    continue;
                const withExt = dir.buildPath(name ~ ext);
                if (runnable(withExt))
                    return withExt.idup;
            }
        }
    }
    return null;
}

/// True when $(LREF resolveInPath) finds an executable named `name`.
bool isInPath(string name) @safe => resolveInPath(name) !is null;

/**
`args` with a bare command name replaced by the path `$PATH` resolves it to.

Every spawn in this module goes through here rather than leaving the lookup to
`std.process`, whose candidate test accepts anything with the execute bit — a
same-named directory included. See $(LREF resolveInPath).

A name that already carries a directory separator is used as given, and an
unresolvable one is passed through unchanged so the failure stays
`spawnProcess`' to report.
*/
private T[] resolvedArgv(T)(scope T[] args) @safe
if (is(T : const(char)[]))
{
    import std.algorithm.searching : canFind;
    import std.path : dirSeparator;

    auto argv = args.dup;
    if (argv.length == 0 || argv[0].canFind(dirSeparator))
        return argv;

    const resolved = resolveInPath(argv[0].idup);
    if (resolved !is null)
        argv[0] = resolved;
    return argv;
}

/// `access(path, X_OK)` wrapped so the single unsafe call is the only trusted
/// surface. Non-POSIX targets fall back to existence (checked by the caller).
private bool isExecutable(scope const(char)[] path) @trusted
{
    version (Posix)
    {
        import std.string : toStringz;
        import core.sys.posix.unistd : access, X_OK;

        return access(path.toStringz, X_OK) == 0;
    }
    else
        return true;
}

/// The outcome of $(LREF runCaptured): the child's exit status and its stdout
/// and stderr captured as *separate* strings (unlike `std.process.execute` and
/// $(LREF executeMonitored), which combine the two).
struct CapturedResult
{
    int status;     /// child exit code (`127` when the process could not be spawned)
    string stdout;  /// everything the child wrote to stdout
    string stderr;  /// everything the child wrote to stderr
    ResourceUsage usage; /// wall time of the wait; CPU/RSS when a sampler ran

    /// True when the child exited successfully.
    bool succeeded() const @safe pure nothrow @nogc => status == 0;
}

/**
Runs `args` (an argv array — no shell, so no quoting hazards) to completion and
captures its stdout and stderr separately, optionally feeding `stdinText` to the
child's standard input and running it in `workDir` (the current directory when
`null`).

Unlike $(LREF executeShell) this **never throws**: a non-zero exit is reported
through `CapturedResult.status`, and a failure to even spawn the process (e.g. a
missing binary) yields `status == 127` with the error text in `stderr`. Output
is drained through temp files rather than pipes, so a chatty child cannot
deadlock against an undrained pipe.
*/
CapturedResult runCaptured(
    const(string)[] args,
    string stdinText = null,
    string workDir = null,
) @safe
{
    import std.conv : text;
    import std.file : tempDir, read, remove, write;
    import std.path : buildPath;
    import std.process : spawnProcess, wait, thisProcessID, Config;
    import std.stdio : File, stdin;
    import core.atomic : atomicOp;

    static shared size_t counter;
    const id = atomicOp!"+="(counter, 1);
    const base = buildPath(tempDir,
        text("sparkles-run-", thisProcessID, "-", id));
    const outPath = base ~ ".out";
    const errPath = base ~ ".err";
    const inPath = base ~ ".in";
    const haveStdin = stdinText !is null;

    auto argv = resolvedArgv(args);

    CapturedResult result;
    try
    {
        if (haveStdin)
            write(inPath, stdinText);

        auto outFile = File(outPath, "w");
        auto errFile = File(errPath, "w");

        // The only unsafe surface is the `stdin` global and `spawnProcess`/
        // `wait`; wrap just those, leaving the file/string bookkeeping `@safe`.
        result.status = () @trusted {
            auto inFile = haveStdin ? File(inPath, "r") : stdin;
            auto pid = spawnProcess(
                argv, inFile, outFile, errFile, null, Config.none, workDir);
            return wait(pid);
        }();

        outFile.close();
        errFile.close();

        // Read raw bytes — not `readText`, whose UTF-8 validation would throw on
        // non-UTF-8 child output (e.g. a Latin-1 git author name) and be
        // misreported below as a spawn failure. `runCaptured` must never throw,
        // so it forwards whatever bytes the child produced. Reinterpreting the
        // fresh, uniquely-owned buffer as an immutable string is sound; the cast
        // is the only unsafe op, so it alone is trusted.
        result.stdout = (() @trusted => cast(string) read(outPath))();
        result.stderr = (() @trusted => cast(string) read(errPath))();
    }
    catch (Exception e)
    {
        result.status = 127;
        result.stderr = e.msg;
    }

    foreach (p; [outPath, errPath, inPath])
        try
            remove(p);
        catch (Exception)
        {
        }                                // best-effort cleanup
    return result;
}

@("process_utils.isInPath")
@safe unittest
{
    // A POSIX system always has a shell on PATH; the bogus name never resolves.
    assert(isInPath("sh"));
    assert(!isInPath("sparkles-nonexistent-binary-xyzzy-123"));

    // `resolveInPath` answers the same question with the path it found.
    assert(resolveInPath("sh") !is null);
    assert(resolveInPath("sparkles-nonexistent-binary-xyzzy-123") is null);
}

// A directory has the execute bit too — it means "searchable" — so a `$PATH`
// lookup that tests only for executability matches one and hands `execve`
// something that can only fail, with EACCES. The dev shells put `.` on `$PATH`
// and this repo has `nix/`, `ci/` and `docs/` at its root, so the shadowing is
// reachable by running a tool from the repo root.
@("process_utils.resolveInPath.directoryDoesNotShadow")
@safe unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath, pathSeparator;
    import std.process : environment, thisProcessID;

    const sandbox = buildPath(tempDir, text("sparkles-path-shadow-", thisProcessID));
    // A *directory* named after a real command, ahead of the real one.
    mkdirRecurse(buildPath(sandbox, "sh"));
    scope (exit) rmdirRecurse(sandbox);

    const realPath = environment.get("PATH", "");
    const shadowed = sandbox ~ pathSeparator ~ realPath;

    const resolved = resolveInPathList("sh", shadowed);
    assert(resolved !is null, "the real `sh` should still be found");
    assert(resolved != buildPath(sandbox, "sh"), "a directory must not resolve");

    // A sandbox holding nothing runnable resolves nothing.
    assert(resolveInPathList("sh", sandbox) is null);
}

@("process_utils.runCaptured.exitCodes")
@safe unittest
{
    assert(runCaptured(["true"]).succeeded);
    assert(!runCaptured(["false"]).succeeded);
    // A missing binary is reported, not thrown.
    assert(runCaptured(["sparkles-nonexistent-binary-xyzzy-123"]).status == 127);
}

@("process_utils.runCaptured.separateStreams")
@safe unittest
{
    auto r = runCaptured(["sh", "-c", "printf out; printf err 1>&2"]);
    assert(r.succeeded);
    assert(r.stdout == "out");
    assert(r.stderr == "err");
}

@("process_utils.runCaptured.stdin")
@safe unittest
{
    auto r = runCaptured(["cat"], "hello stdin");
    assert(r.succeeded);
    assert(r.stdout == "hello stdin");
}

// ---------------------------------------------------------------------------
// Resource-monitored execution
// ---------------------------------------------------------------------------

/**
Peak resource use of a spawned process and its descendants, sampled while it
runs.

`peakRssBytes` is the largest summed resident-set size observed across the
whole process tree (a `dub` build, say, plus the `ldc2` child it spawns —
which is usually where the memory lives). `peakProcs` is the largest number
of live processes in that tree (root included) — how many instances were
actually running in parallel at the peak. `userTime` / `systemTime` are
best-effort tree-summed user and kernel CPU (a child's CPU is lost from the
live sum once it exits, so treat them as a lower bound). `cpuTime` is their
sum, kept so existing callers do not have to add. `wallTime` is the
elapsed clock time of the wait, always filled.

`sampled` is `false` when no per-tree sampler is available (currently
everything but Linux and Darwin): $(LREF executeMonitored) still runs the
process and returns its output, and `wallTime` is still set.
*/
struct ResourceUsage
{
    size_t peakRssBytes;   /// max summed RSS over the process tree
    size_t peakProcs;      /// max live process count in the tree (root included)
    Duration wallTime;     /// elapsed wall clock of the wait (always set)
    Duration userTime;     /// best-effort tree-summed user CPU (lower bound)
    Duration systemTime;   /// best-effort tree-summed kernel CPU (lower bound)
    Duration cpuTime;      /// `userTime + systemTime` (compat alias)
    size_t sampleCount;    /// number of samples taken
    bool sampled;          /// false when no sampler is available
}

/// The outcome of $(LREF executeMonitored): the child's exit status, its
/// combined stdout+stderr (matching `std.process.execute`'s contract), and the
/// $(LREF ResourceUsage) gathered while it ran.
struct MonitoredResult
{
    int status;
    string output;
    ResourceUsage usage;

    /// Set when the child was killed for exceeding its timeout rather than
    /// exiting on its own. Distinguishes "wedged" from "failed", which a bare
    /// exit status cannot: a program is free to exit 124 by itself.
    bool timedOut;
}

/// Exit status reported for a child killed by its timeout. Matches GNU
/// `timeout(1)`, so a wrapper script and this library agree.
enum int timedOutStatus = 124;

/**
What a spawned child sees on its standard input.

The distinction matters for any child that probes `isatty(0)` to decide
whether it may prompt: CI runners disagree about this. A CircleCI `run` step
allocates a TTY, a GitHub Actions step does not — so a program that is
interactive on a terminal renders a prompt on one and not the other, then
blocks on input that never arrives.
*/
enum ChildStdin
{
    /// The parent's standard input, as `std.process.execute` does.
    inherit,

    /**
    A stream already at end-of-file (`/dev/null`; `NUL` on Windows). The child
    sees `isatty(0) == false` and any read returns EOF immediately, so a
    batch runner gets the same behaviour on every host.
    */
    empty,
}

/**
Runs `args` to completion like `std.process.execute` — returning the exit
status and the combined stdout+stderr — but spawns it non-blocking and samples
the resident-set size and CPU of the whole process tree every `sampleInterval`
while it runs, so a memory blow-up can be attributed to a specific process.

`onSample`, if given, is invoked after each sample with the running
$(LREF ResourceUsage) (its `peakRssBytes` updated, `userTime`/`systemTime`
carrying the latest tree totals), letting the caller log a live trace.
Sampling walks the live process tree on Linux (`/proc`) and Darwin
(`proc_pid_rusage` + `proc_listchildpids`); elsewhere the process still
runs and its output is returned, `wallTime` is set, but `usage.sampled`
is `false`.

Output is redirected to a temp file (not a pipe) so a chatty child cannot
deadlock against an undrained pipe while we sample.
*/
MonitoredResult executeMonitored(
    const(string)[] args,
    Duration sampleInterval = 250.msecs,
    scope void delegate(in ResourceUsage sample) @safe onSample = null,
    ChildStdin childStdin = ChildStdin.inherit,
    Duration timeout = Duration.zero,
    const string[string] env = null,
)
{
    import std.process : kill, spawnProcess, tryWait, wait;
    import std.stdio : File, stdin;
    import std.file : tempDir, readText, remove;
    import std.path : buildPath;
    import std.conv : text;
    import std.process : thisProcessID;
    import core.atomic : atomicOp;
    import core.thread : Thread;

    static shared size_t counter;
    const id = atomicOp!"+="(counter, 1);
    const logPath = buildPath(tempDir,
        text("sparkles-mon-", thisProcessID, "-", id, ".log"));

    MonitoredResult result;

    version (Windows)
        enum nullDevice = "NUL";
    else
        enum nullDevice = "/dev/null";

    auto sink = File(logPath, "w");
    auto childIn = childStdin == ChildStdin.empty ? File(nullDevice, "r") : stdin;
    // `env` adds to the inherited environment; only `Config.newEnv` would
    // replace it, and a caller setting one variable does not mean to drop the
    // rest (see `runStreaming`).
    auto pid = spawnProcess(resolvedArgv(args), childIn, sink, sink, env);
    const childPid = pid.processID;

    version (linux)
        result.usage.sampled = true;
    else version (OSX)
        result.usage.sampled = true;

    // Poll tightly at first and back off towards `sampleInterval`, because the
    // sleep happens *after* the terminated check: a fixed interval therefore
    // puts a floor under every child's wall time, however fast it really is.
    // At a 5s interval that floor cost ~9 minutes across a 108-example run.
    // Backing off keeps short children cheap while a long build still settles
    // into the caller's requested sampling density.
    Duration pollDelay = 1.msecs;

    // Deadline measured against the clock, not by summing the sleeps. On Linux
    // each iteration also walks /proc for the whole tree, which costs real time
    // the sleeps do not account for — summing them overshot a 20s deadline by
    // 60%.
    const started = MonoTime.currTime;

    for (;;)
    {
        // Sample *before* reaping so a just-exited child is still a zombie
        // with /proc (or a Darwin `proc_pid_rusage` target) intact.
        version (linux)
            sampleLinuxTree(childPid, result.usage, onSample);
        else version (OSX)
            sampleDarwinTree(childPid, result.usage, onSample);

        const w = tryWait(pid);

        if (w.terminated)
        {
            result.status = w.status;
            break;
        }
        // A child that wedges must not take the whole job with it. Without
        // this, one stuck example burned a 20-minute CI step producing no
        // output at all, so the log said nothing about which one it was.
        if (timeout > Duration.zero && MonoTime.currTime - started >= timeout)
        {
            kill(pid);
            wait(pid);
            result.status = timedOutStatus;
            result.timedOut = true;
            break;
        }

        Thread.sleep(pollDelay);
        if (pollDelay < sampleInterval)
        {
            pollDelay *= 2;
            if (pollDelay > sampleInterval)
                pollDelay = sampleInterval;
        }
    }

    result.usage.wallTime = MonoTime.currTime - started;
    result.usage.cpuTime = result.usage.userTime + result.usage.systemTime;

    sink.close();
    result.output = readText(logPath);
    try
        remove(logPath);
    catch (Exception)
    {
    }                                    // best-effort cleanup
    return result;
}

/**
Fold one live sample of `rootPid`'s process tree into `usage` (peak RSS, peak
process count, CPU lower bound). No-op on hosts without a tree sampler; those
leave `sampled` false.
*/
void sampleProcessTree(int rootPid, ref ResourceUsage usage) @trusted
{
    version (linux)
    {
        usage.sampled = true;
        sampleLinuxTree(rootPid, usage, null);
    }
    else version (OSX)
    {
        usage.sampled = true;
        sampleDarwinTree(rootPid, usage, null);
    }
}

/// $(LREF sampleProcessTree) for this process — the whole group a parent like
/// `ci --test` cares about (`ci` plus every live descendant).
void sampleThisProcessTree(ref ResourceUsage usage) @trusted
{
    import std.process : thisProcessID;

    sampleProcessTree(thisProcessID, usage);
}

/// Input range of a child's combined stdout+stderr lines, sampled like
/// $(LREF executeMonitored) while it runs.
///
/// Spawn is lazy: the process starts on the first `empty`/`front` pull, so a
/// streaming box can paint its title before the command begins. Copies share
/// the same child (a class payload). After the range is exhausted,
/// $(LREF result) holds the exit status, the full combined output, and the
/// tree $(LREF ResourceUsage). Dropping the range mid-stream kills the child.
struct MonitoredLineRange
{
    /// The finished child's outcome. Valid after `empty` is true.
    @property ref MonitoredResult result() return
    in (_s !is null)
        => _s.result;

    /// Range primitives (input range of lines, terminators stripped).
    @property bool empty()
    {
        if (_s is null)
            return true;
        if (_s.haveFront)
            return false;
        return !_s.pullLine();
    }

    /// ditto
    @property string front()
    in (_s !is null && _s.haveFront)
        => _s.front;

    /// ditto
    void popFront()
    in (_s !is null && _s.haveFront)
    {
        _s.haveFront = false;
        _s.front = null;
    }

    private MonitoredLineState _s;
}

/// Like $(LREF executeMonitored), but as a lazy line range for live display.
///
/// stdout and stderr are merged (same contract as `execute`); each complete
/// line is yielded as soon as it hits the capture file. Sampling still walks
/// the live process tree on Linux and Darwin. `onSample`, if given, runs after
/// each sample. `ChildStdin.empty` is the default — batch work must not
/// inherit a TTY.
MonitoredLineRange executeMonitoredLines(
    const(string)[] args,
    Duration sampleInterval = 250.msecs,
    void delegate(in ResourceUsage sample) @safe onSample = null,
    ChildStdin childStdin = ChildStdin.empty,
    Duration timeout = Duration.zero,
    const string[string] env = null,
)
{
    auto state = new MonitoredLineState(
        args, sampleInterval, onSample, childStdin, timeout, env);
    MonitoredLineRange range;
    range._s = state;
    return range;
}

/// Payload of $(LREF MonitoredLineRange). Do not construct this directly.
private final class MonitoredLineState
{
    this(
        const(string)[] args,
        Duration sampleInterval,
        void delegate(in ResourceUsage sample) @safe onSample,
        ChildStdin childStdin,
        Duration timeout,
        const string[string] env,
    )
    {
        this.args = args;
        this.sampleInterval = sampleInterval;
        this.onSample = onSample;
        this.childStdin = childStdin;
        this.timeout = timeout;
        this.env = env;
        this.pollDelay = 1.msecs;
    }

    ~this()
    {
        try
            abandon();
        catch (Exception)
        {
        }
    }

    bool pullLine()
    {
        ensureSpawned();
        if (failedToSpawn)
        {
            if (spawnError.length)
            {
                const msg = spawnError;
                spawnError = null;
                return emit(msg);
            }
            return false;
        }

        for (;;)
        {
            if (takeLine())
                return true;
            ingest();
            if (takeLine())
                return true;

            if (!reaped)
            {
                sampleTree();
                import std.process : kill, tryWait, wait;

                const w = tryWait(pid);
                if (w.terminated)
                {
                    reaped = true;
                    result.status = w.status;
                    if (sink.isOpen)
                        sink.close();
                    ingest();
                    continue;
                }
                if (timeout > Duration.zero
                    && MonoTime.currTime - origin >= timeout)
                {
                    kill(pid);
                    wait(pid);
                    reaped = true;
                    result.status = timedOutStatus;
                    result.timedOut = true;
                    if (sink.isOpen)
                        sink.close();
                    ingest();
                    continue;
                }
                import core.thread : Thread;

                Thread.sleep(pollDelay);
                if (pollDelay < sampleInterval)
                {
                    pollDelay *= 2;
                    if (pollDelay > sampleInterval)
                        pollDelay = sampleInterval;
                }
                continue;
            }

            if (leftover.length)
            {
                const last = sanitizeLine(leftover);
                leftover = null;
                return emit(last);
            }
            finalizeRun();
            return false;
        }
    }

    bool haveFront;
    string front;
    MonitoredResult result;

private:
    bool emit(string line)
    {
        front = line;
        haveFront = true;
        result.output ~= line;
        result.output ~= '\n';
        return true;
    }

    bool takeLine()
    {
        import core.stdc.string : memchr;

        if (leftover.length == 0)
            return false;
        auto ptr = memchr(leftover.ptr, '\n', leftover.length);
        if (ptr is null)
            return false;
        const nl = cast(size_t)(cast(const(ubyte)*) ptr - leftover.ptr);
        auto lineBytes = leftover[0 .. nl];
        if (lineBytes.length && lineBytes[$ - 1] == '\r')
            lineBytes = lineBytes[0 .. $ - 1];
        leftover = leftover[nl + 1 .. $];
        return emit(sanitizeLine(lineBytes));
    }

    static string sanitizeLine(const(ubyte)[] bytes)
    {
        import std.utf : validate, UTFException;

        auto s = cast(const(char)[]) bytes;
        try
        {
            validate(s);
            return s.idup;
        }
        catch (UTFException)
        {
            import std.array : appender;

            auto app = appender!string();
            app.reserve(bytes.length);
            size_t i = 0;
            while (i < bytes.length)
            {
                import std.utf : decode, UseReplacementDchar;
                size_t nextI = i;
                dchar d = decode!(UseReplacementDchar.yes)(s, nextI);
                import std.utf : encode;
                char[4] buf;
                const len = encode(buf, d);
                app.put(buf[0 .. len]);
                i = nextI;
            }
            return app.data;
        }
    }

    void ingest()
    {
        if (!reader.isOpen)
            return;
        // A FILE* that has already seen EOF stays there until the offset is
        // touched — `seek(0, SEEK_CUR)` is the portable clearerr, so bytes
        // the child appends after our last empty read become visible.
        import core.stdc.stdio : SEEK_CUR;

        try
            reader.seek(0, SEEK_CUR);
        catch (Exception)
            return;
        ubyte[4096] tmp = void;
        for (;;)
        {
            auto got = reader.rawRead(tmp[]);
            if (got.length == 0)
                break;
            leftover ~= got;
        }
    }

    void sampleTree()
    {
        version (linux)
            sampleLinuxTree(childPid, result.usage, onSample);
        else version (OSX)
            sampleDarwinTree(childPid, result.usage, onSample);
        else if (onSample !is null)
            onSample(result.usage);
    }

    void ensureSpawned()
    {
        if (spawned || failedToSpawn)
            return;
        spawned = true;
        origin = MonoTime.currTime;

        import core.atomic : atomicOp;
        import std.conv : text;
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : spawnProcess, thisProcessID;
        import std.stdio : File, stdin;

        static shared size_t counter;
        const id = atomicOp!"+="(counter, 1);
        logPath = buildPath(tempDir,
            text("sparkles-mon-lines-", thisProcessID, "-", id, ".log"));

        version (Windows)
            enum nullDevice = "NUL";
        else
            enum nullDevice = "/dev/null";

        try
        {
            sink = File(logPath, "w");
            auto childIn = childStdin == ChildStdin.empty
                ? File(nullDevice, "r") : stdin;
            pid = spawnProcess(resolvedArgv(args), childIn, sink, sink, env);
            childPid = pid.processID;
            reader = File(logPath, "rb");
            version (linux)
                result.usage.sampled = true;
            else version (OSX)
                result.usage.sampled = true;
        }
        catch (Exception e)
        {
            failedToSpawn = true;
            reaped = true;
            result.status = 127;
            spawnError = e.msg;
        }
    }

    void finalizeRun()
    {
        if (finalized)
            return;
        finalized = true;
        result.usage.wallTime = MonoTime.currTime - origin;
        result.usage.cpuTime = result.usage.userTime + result.usage.systemTime;
        closeAndRemove();
    }

    void abandon()
    {
        if (spawned && !reaped)
        {
            import std.process : kill, wait;

            try
            {
                kill(pid);
                wait(pid);
            }
            catch (Exception)
            {
            }
            reaped = true;
        }
        closeAndRemove();
    }

    void closeAndRemove()
    {
        if (sink.isOpen)
        {
            try
                sink.close();
            catch (Exception)
            {
            }
        }
        if (reader.isOpen)
        {
            try
                reader.close();
            catch (Exception)
            {
            }
        }
        if (logPath.length)
        {
            import std.file : exists, remove;

            try
            {
                if (logPath.exists)
                    remove(logPath);
            }
            catch (Exception)
            {
            }
            logPath = null;
        }
    }

    const(string)[] args;
    Duration sampleInterval;
    void delegate(in ResourceUsage sample) @safe onSample;
    ChildStdin childStdin;
    Duration timeout;
    const string[string] env;

    import std.process : Pid;
    import std.stdio : File;

    Pid pid;
    int childPid;
    File sink;
    File reader;
    string logPath;
    ubyte[] leftover;
    string spawnError;
    bool spawned;
    bool reaped;
    bool failedToSpawn;
    bool finalized;
    Duration pollDelay;
    MonoTime origin;
}

/// CPU time of this process's *waited-for* children (`getrusage(RUSAGE_CHILDREN)`).
///
/// A sequential runner snapshots this before and after one spawn; the
/// difference is that child's user/system time (including descendants the
/// child itself waited for). `sampled` is false off POSIX.
ResourceUsage childrenCpuUsage() @trusted
{
    ResourceUsage u;
    version (Posix)
    {
        import core.sys.posix.sys.resource : RUSAGE_CHILDREN, getrusage, rusage;

        rusage ru;
        if (getrusage(RUSAGE_CHILDREN, &ru) == 0)
        {
            u.userTime = timevalDuration(ru.ru_utime.tv_sec, ru.ru_utime.tv_usec);
            u.systemTime = timevalDuration(ru.ru_stime.tv_sec, ru.ru_stime.tv_usec);
            u.cpuTime = u.userTime + u.systemTime;
            u.sampled = true;
        }
    }
    return u;
}

/// User+system CPU of this process plus every waited-for child
/// (`RUSAGE_SELF` + `RUSAGE_CHILDREN`). Snapshot before and after a run; the
/// difference is the process group's CPU, including descendants that have
/// already been reaped (which a live tree walk would miss). `sampled` is false
/// off POSIX.
ResourceUsage selfAndChildrenCpuUsage() @trusted
{
    ResourceUsage u;
    version (Posix)
    {
        import core.sys.posix.sys.resource : RUSAGE_CHILDREN, RUSAGE_SELF,
            getrusage, rusage;

        rusage self, kids;
        if (getrusage(RUSAGE_SELF, &self) != 0
            || getrusage(RUSAGE_CHILDREN, &kids) != 0)
            return u;
        u.userTime = timevalDuration(self.ru_utime.tv_sec, self.ru_utime.tv_usec)
            + timevalDuration(kids.ru_utime.tv_sec, kids.ru_utime.tv_usec);
        u.systemTime = timevalDuration(self.ru_stime.tv_sec, self.ru_stime.tv_usec)
            + timevalDuration(kids.ru_stime.tv_sec, kids.ru_stime.tv_usec);
        u.cpuTime = u.userTime + u.systemTime;
        u.sampled = true;
    }
    return u;
}

/// `ChildStdin.empty` makes the child see a non-terminal, already-EOF stdin.
@("process_utils.executeMonitored.emptyStdin")
@system
unittest
{
    version (Posix)
    {
        import std.string : strip;

        // Asserted via `test -t 0` rather than by reading, so a regression
        // fails the test instead of blocking it forever on a real terminal.
        // This is what keeps a batch runner's children from going
        // interactive on a host whose stdin happens to be a TTY.
        const r = executeMonitored(
            ["sh", "-c", "test -t 0 && echo tty || echo not-tty"],
            50.msecs, null, ChildStdin.empty);
        assert(r.status == 0);
        assert(r.output.strip == "not-tty");
    }
}

/// A coarse `sampleInterval` must not put a floor under a fast child: the
/// sleep follows the terminated check, so a naive fixed wait makes every
/// child cost at least one interval.
@("process_utils.executeMonitored.fastChildIsNotFloored")
@system
unittest
{
    version (Posix)
    {
        import core.time : seconds;
        import std.datetime.stopwatch : AutoStart, StopWatch;

        auto sw = StopWatch(AutoStart.yes);
        const r = executeMonitored(["true"], 5.seconds, null, ChildStdin.empty);
        sw.stop();

        assert(r.status == 0);
        // Deliberately loose — the assertion is "nowhere near the interval",
        // not a latency budget, so a loaded machine cannot make it flaky.
        assert(sw.peek < 2.seconds, "a coarse sampleInterval floored a fast child");
        assert(r.usage.wallTime >= Duration.zero);
        assert(r.usage.wallTime < 2.seconds);
        version (linux)
            assert(r.usage.sampled);
        else version (OSX)
            assert(r.usage.sampled);
    }
}

/// A wedged child is killed at its timeout and reported as such.
@("process_utils.executeMonitored.timeout")
@system
unittest
{
    version (Posix)
    {
        import core.time : seconds;
        import std.datetime.stopwatch : AutoStart, StopWatch;

        auto sw = StopWatch(AutoStart.yes);
        const r = executeMonitored(
            ["sleep", "60"], 50.msecs, null, ChildStdin.empty, 1.seconds);
        sw.stop();

        assert(r.timedOut);
        assert(r.status == timedOutStatus);
        // Tight-ish: the deadline is measured against the clock, so sampling
        // cost must not push the kill far past it. A summed-sleep deadline
        // overshot 20s by ~12s, which this would catch.
        assert(sw.peek < 5.seconds, "the timeout overshot its deadline badly");
    }
}

@("process_utils.executeMonitoredLines.streamsBeforeExit")
@system
unittest
{
    version (Posix)
    {
        import core.time : msecs;
        import std.conv : text;

        auto lines = executeMonitoredLines(
            ["sh", "-c", "echo one; sleep 0.25; echo two"],
            20.msecs, null, ChildStdin.empty);
        string[] seen;
        MonoTime t1, t2;
        while (!lines.empty)
        {
            seen ~= lines.front;
            if (lines.front == "one")
                t1 = MonoTime.currTime;
            else if (lines.front == "two")
                t2 = MonoTime.currTime;
            lines.popFront;
        }
        assert(seen == ["one", "two"], seen.text);
        assert(lines.result.status == 0);
        assert(lines.result.output == "one\ntwo\n");
        // The first line must have arrived while `sleep` was still running,
        // not as a pair at process exit (the whole point of the line range).
        assert(t1 != MonoTime.init && t2 != MonoTime.init);
        assert(t2 - t1 >= 100.msecs, "lines were buffered until exit");
        version (linux)
            assert(lines.result.usage.sampled && lines.result.usage.peakProcs >= 1);
        else version (OSX)
            assert(lines.result.usage.sampled && lines.result.usage.peakProcs >= 1);
    }
}

@("process_utils.executeMonitoredLines.spawnFailure")
@system
unittest
{
    auto lines = executeMonitoredLines(
        ["sparkles-nonexistent-binary-xyzzy-123"],
        50.msecs, null, ChildStdin.empty);
    string[] seen;
    while (!lines.empty)
    {
        seen ~= lines.front;
        lines.popFront;
    }
    assert(lines.result.status == 127);
    assert(seen.length <= 1);
}

@("process_utils.selfAndChildrenCpuUsage.sampledOnPosix")
@safe
unittest
{
    auto u = selfAndChildrenCpuUsage();
    version (Posix)
        assert(u.sampled);
    else
        assert(!u.sampled);
}

/// Current resident-set size of this process in bytes (`0` when unknown).
version (linux)
size_t selfRssBytes() @trusted
{
    import std.file : readText;

    try
    {
        const kb = parseVmRssKbFromStatus(readText("/proc/self/status"));
        return kb.hasValue ? kb.value * 1024 : 0;
    }
    catch (Exception)
        return 0;
}
else version (OSX)
size_t selfRssBytes() @trusted
{
    import core.sys.posix.unistd : getpid;

    DarwinRusageInfo info;
    if (proc_pid_rusage(getpid(), darwinRusageInfoV4, &info) == 0)
        return cast(size_t) info.ri_resident_size;
    return 0;
}
else
size_t selfRssBytes() @safe => 0;

// ---------------------------------------------------------------------------
// /proc parsers
// ---------------------------------------------------------------------------
//
// These are pure, `@nogc` slice walkers built on `base.text.readers`: the
// `/proc` files arrive as already-read `const(char)[]`, and a malformed line is
// surfaced as a `ParseExpected` error rather than a silent sentinel. The
// readers that fetch the files (below) allocate and so cannot be `@nogc`.

/// The slice after the last `)` in `s` (`null` if there is none). The `comm`
/// field of a `/proc/<pid>/stat` line is parenthesised and may itself contain
/// spaces and parens, so the fixed numeric fields begin only after the *last*
/// `)`.
private const(char)[] afterLastParen(return scope const(char)[] s)
    @safe pure nothrow @nogc
{
    ptrdiff_t close = -1;
    foreach (i, c; s)
        if (c == ')')
            close = i;
    return close < 0 ? null : s[close + 1 .. $];
}

/**
Parses the parent PID from a `/proc/<pid>/stat` line. After the last `)` the
tokens are `state ppid pgrp …`, so `ppid` is the second. Fails (with an
`unexpectedEnd`/`unexpectedCharacter` $(REF ParseError,
sparkles,core_cli,text,errors)) when there is no `)` or the `ppid` field is
missing or non-numeric.
*/
ParseExpected!int parsePpidFromStat(const(char)[] stat) @safe pure nothrow @nogc
{
    auto cur = afterLastParen(stat);
    if (cur.length == 0)
        return parseErr!int(ParseErrorCode.unexpectedEnd, 0);

    skipSpaces(cur);
    readUntil(cur, " ");        // skip the `state` token
    skipSpaces(cur);

    auto ppid = readInteger!uint(cur);
    if (!ppid.hasValue)
        return parseErr!int(ppid.error);
    return parseOk(cast(int) ppid.value);
}

/// `utime`/`stime` clock-tick pair from a `/proc/<pid>/stat` line.
struct CpuTicks
{
    ulong utime;
    ulong stime;
    ulong total() const @safe pure nothrow @nogc => utime + stime;
}

/**
Parses `(utime, stime)` clock ticks from a `/proc/<pid>/stat` line. After the
last `)` they are the 12th and 13th tokens (the 11 before them — `state ppid
pgrp session tty tpgid flags minflt cminflt majflt cmajflt` — are skipped).
Fails when the line is truncated before those fields.
*/
ParseExpected!CpuTicks parseCpuTicksFromStat(const(char)[] stat)
    @safe pure nothrow @nogc
{
    auto cur = afterLastParen(stat);
    if (cur.length == 0)
        return parseErr!CpuTicks(ParseErrorCode.unexpectedEnd, 0);

    skipSpaces(cur);
    foreach (_; 0 .. 11)        // skip state … cmajflt
    {
        readUntil(cur, " ");
        skipSpaces(cur);
    }

    auto utime = readInteger!ulong(cur);
    if (!utime.hasValue)
        return parseErr!CpuTicks(utime.error);
    skipSpaces(cur);
    auto stime = readInteger!ulong(cur);
    if (!stime.hasValue)
        return parseErr!CpuTicks(stime.error);

    return parseOk(CpuTicks(utime.value, stime.value));
}

/**
Parses the `VmRSS:` value (kilobytes) from a `/proc/<pid>/status` file. The
line reads `VmRSS:\t   12345 kB`. Fails (`unexpectedEnd`) when no `VmRSS:` line
is present.
*/
ParseExpected!size_t parseVmRssKbFromStatus(const(char)[] status)
    @safe pure nothrow @nogc
{
    enum label = "VmRSS:";

    auto cur = status;
    while (cur.length)
    {
        auto line = readUntil(cur, "\n");
        tryConsume(cur, '\n');
        if (line.length < label.length || line[0 .. label.length] != label)
            continue;

        auto value = line[label.length .. $];
        skipSpaces(value);      // skip the leading tab/spaces before the digits
        return readInteger!size_t(value);
    }
    return parseErr!size_t(ParseErrorCode.unexpectedEnd, 0);
}

// ---------------------------------------------------------------------------
// /proc tree readers (Linux only)
// ---------------------------------------------------------------------------

version (linux)
{
    /// PIDs of `rootPid` and every transitive descendant, found by walking the
    /// `ppid` links in `/proc/[0-9]*/stat`. Best-effort: a process that exits
    /// mid-scan is simply skipped.
    private int[] collectTreePids(int rootPid) @trusted
    {
        import std.file : dirEntries, SpanMode, readText;
        import std.path : baseName;

        int[int] ppidOf;
        try
        {
            foreach (de; dirEntries("/proc", SpanMode.shallow))
            {
                const(char)[] name = de.name.baseName;
                auto pidR = readInteger!uint(name);
                if (!pidR.hasValue || name.length != 0)
                    continue;               // skip non-numeric /proc entries
                const pid = cast(int) pidR.value;
                string stat;
                try
                    stat = readText("/proc/" ~ de.name.baseName ~ "/stat");
                catch (Exception)
                    continue;               // vanished between listing and read
                const ppid = parsePpidFromStat(stat);
                if (ppid.hasValue)
                    ppidOf[pid] = ppid.value;
            }
        }
        catch (Exception)
        {
        }

        int[][int] children;
        foreach (pid, pp; ppidOf)
            children[pp] ~= pid;

        int[] tree = [rootPid];
        bool[int] seen = [rootPid: true];
        for (size_t i = 0; i < tree.length; i++)
            if (auto kids = tree[i] in children)
                foreach (k; *kids)
                    if (k !in seen)
                    {
                        seen[k] = true;
                        tree ~= k;
                    }
        return tree;
    }

    /// Summed resident-set size (bytes) of `rootPid`'s process tree.
    private size_t treeRssBytes(int rootPid) @trusted
    {
        import std.file : readText;
        import std.conv : text;

        size_t total;
        foreach (pid; collectTreePids(rootPid))
        {
            try
            {
                const kb = parseVmRssKbFromStatus(
                    readText(text("/proc/", pid, "/status")));
                if (kb.hasValue)
                    total += kb.value * 1024;
            }
            catch (Exception)
            {
            }
        }
        return total;
    }

    /// Summed user and kernel CPU of `rootPid`'s process tree.
    private TreeCpu treeCpuParts(int rootPid) @trusted
    {
        import std.file : readText;
        import std.conv : text;
        import core.sys.posix.unistd : sysconf, _SC_CLK_TCK;

        const clk = sysconf(_SC_CLK_TCK);
        if (clk <= 0)
            return TreeCpu.init;

        ulong userTicks, sysTicks;
        foreach (pid; collectTreePids(rootPid))
        {
            try
            {
                const c = parseCpuTicksFromStat(
                    readText(text("/proc/", pid, "/stat")));
                if (c.hasValue)
                {
                    userTicks += c.value.utime;
                    sysTicks += c.value.stime;
                }
            }
            catch (Exception)
            {
            }
        }
        TreeCpu cpu;
        cpu.user = msecs(cast(long)(userTicks * 1000 / clk));
        cpu.system = msecs(cast(long)(sysTicks * 1000 / clk));
        return cpu;
    }

    private void sampleLinuxTree(
        int rootPid,
        ref ResourceUsage usage,
        scope void delegate(in ResourceUsage sample) @safe onSample,
    )
    {
        const rss = treeRssBytes(rootPid);
        if (rss > usage.peakRssBytes)
            usage.peakRssBytes = rss;
        const n = collectTreePids(rootPid).length;
        if (n > usage.peakProcs)
            usage.peakProcs = n;
        const cpu = treeCpuParts(rootPid);
        if (cpu.user > usage.userTime)
            usage.userTime = cpu.user;
        if (cpu.system > usage.systemTime)
            usage.systemTime = cpu.system;
        usage.cpuTime = usage.userTime + usage.systemTime;
        usage.sampleCount++;
        if (onSample !is null)
            onSample(usage);
    }
}

version (OSX)
{
    extern (C) private int proc_pid_rusage(int pid, int flavor, void* buffer)
        @nogc nothrow;
    extern (C) private int proc_listchildpids(int ppid, void* buffer, int buffersize)
        @nogc nothrow;

    private enum int darwinRusageInfoV4 = 4;

    /// xnu `struct rusage_info_v4` (16-byte uuid + 35 × uint64 = 296).
    /// Layout matches `sparkles.test_runner.perf` / the macOS SDK header.
    private struct DarwinRusageInfo
    {
        ubyte[16] ri_uuid;
        ulong ri_user_time;
        ulong ri_system_time;
        ulong ri_pkg_idle_wkups;
        ulong ri_interrupt_wkups;
        ulong ri_pageins;
        ulong ri_wired_size;
        ulong ri_resident_size;
        ulong ri_phys_footprint;
        ulong ri_proc_start_abstime;
        ulong ri_proc_exit_abstime;
        ulong ri_child_user_time;
        ulong ri_child_system_time;
        ulong ri_child_pkg_idle_wkups;
        ulong ri_child_interrupt_wkups;
        ulong ri_child_pageins;
        ulong ri_child_elapsed_abstime;
        ulong ri_diskio_bytesread;
        ulong ri_diskio_byteswritten;
        ulong ri_cpu_time_qos_default;
        ulong ri_cpu_time_qos_maintenance;
        ulong ri_cpu_time_qos_background;
        ulong ri_cpu_time_qos_utility;
        ulong ri_cpu_time_qos_legacy;
        ulong ri_cpu_time_qos_user_initiated;
        ulong ri_cpu_time_qos_user_interactive;
        ulong ri_billed_system_time;
        ulong ri_serviced_system_time;
        ulong ri_logical_writes;
        ulong ri_lifetime_max_phys_footprint;
        ulong ri_instructions;
        ulong ri_cycles;
        ulong ri_billed_energy;
        ulong ri_serviced_energy;
        ulong ri_interval_max_phys_footprint;
        ulong ri_runnable_time;
    }

    static assert(DarwinRusageInfo.sizeof == 296,
        "rusage_info_v4 must match xnu bsd/sys/resource.h");

    private void sampleDarwinTree(
        int rootPid,
        ref ResourceUsage usage,
        scope void delegate(in ResourceUsage sample) @safe onSample,
    )
    {
        import core.time : nsecs;

        ulong userNs, sysNs;
        size_t rss;
        int[64] pending = void;
        size_t nPending = 1;
        pending[0] = rootPid;
        int[128] seen = void;
        size_t nSeen;

        while (nPending)
        {
            const pid = pending[--nPending];
            bool already;
            foreach (s; seen[0 .. nSeen])
                if (s == pid)
                {
                    already = true;
                    break;
                }
            if (already)
                continue;
            if (nSeen < seen.length)
                seen[nSeen++] = pid;

            DarwinRusageInfo info;
            if (proc_pid_rusage(pid, darwinRusageInfoV4, &info) != 0)
                continue;

            // Own time plus waited descendants. Live children are walked
            // below and are *not* in `ri_child_*` yet, so they are not
            // double-counted.
            userNs += info.ri_user_time + info.ri_child_user_time;
            sysNs += info.ri_system_time + info.ri_child_system_time;
            rss += cast(size_t) info.ri_resident_size;

            int[64] kids = void;
            const bytes = proc_listchildpids(pid, kids.ptr, cast(int) kids.sizeof);
            if (bytes > 0)
            {
                const nk = bytes / cast(int) int.sizeof;
                foreach (k; kids[0 .. nk])
                    if (k > 0 && nPending < pending.length)
                        pending[nPending++] = k;
            }
        }

        const user = nsecs(userNs > long.max ? long.max : cast(long) userNs);
        const sys = nsecs(sysNs > long.max ? long.max : cast(long) sysNs);
        if (user > usage.userTime)
            usage.userTime = user;
        if (sys > usage.systemTime)
            usage.systemTime = sys;
        if (rss > usage.peakRssBytes)
            usage.peakRssBytes = rss;
        if (nSeen > usage.peakProcs)
            usage.peakProcs = nSeen;
        usage.cpuTime = usage.userTime + usage.systemTime;
        usage.sampleCount++;
        if (onSample !is null)
            onSample(usage);
    }
}

private struct TreeCpu
{
    Duration user;
    Duration system;
}

private Duration timevalDuration(long sec, long usec) @safe pure nothrow @nogc
{
    import core.time : dur;

    return dur!"seconds"(sec) + dur!"usecs"(usec);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("process_utils.parsePpidFromStat.handlesCommWithSpacesAndParens")
@safe pure nothrow @nogc
unittest
{
    // comm = "(ldc2 stage)" — embedded space and parens; ppid is 4242.
    const a = parsePpidFromStat("1234 ((ldc2 stage)) R 4242 1234 1234 0 -1 4194560 100 0");
    assert(a.hasValue && a.value == 4242);

    // Simple comm.
    const b = parsePpidFromStat("17 (dub) S 9 17 17 0");
    assert(b.hasValue && b.value == 9);

    // Malformed (no `)`) → error, not a sentinel value.
    assert(!parsePpidFromStat("garbage").hasValue);
}

@("process_utils.parseCpuTicksFromStat.readsUtimeStime")
@safe pure nothrow @nogc
unittest
{
    // After the last ')': state ppid pgrp session tty tpgid flags
    //   minflt cminflt majflt cmajflt utime stime …
    //   (indices 0..)         7      8       9      10     11    12
    const c = parseCpuTicksFromStat("5 (prog) R 1 5 5 0 -1 0 10 0 20 0 314 159 0 0");
    assert(c.hasValue);
    assert(c.value.utime == 314);
    assert(c.value.stime == 159);
    assert(c.value.total == 473);

    assert(!parseCpuTicksFromStat("nope").hasValue);
}

@("process_utils.parseVmRssKbFromStatus.findsRss")
@safe pure nothrow @nogc
unittest
{
    const status =
        "Name:\tldc2\nVmPeak:\t  900000 kB\nVmRSS:\t  842156 kB\nThreads:\t8\n";
    const rss = parseVmRssKbFromStatus(status);
    assert(rss.hasValue && rss.value == 842_156);

    // Absent → error.
    assert(!parseVmRssKbFromStatus("Name:\tx\nThreads:\t1\n").hasValue);
}

/**
Runs `args` (an argv array — no shell) streaming its output line by line into
`sink` as the child produces it, for live progress displays (a task list's
subprocess tail). stdout and stderr are merged into one stream so lines arrive
in output order; the full combined output is also returned in
`CapturedResult.stdout` (`stderr` stays empty).

Like $(LREF runCaptured) this never throws: spawn failures yield `status == 127`
with the error text in `stderr`. The single merged pipe is drained continuously,
so a chatty child cannot deadlock. Attributes infer from `Sink` (a callable
taking `scope const(char)[]`).
*/
CapturedResult runStreaming(Sink)(
    const(string)[] args,
    scope Sink sink,
    string workDir = null,
    const string[string] env = null,
)
{
    import std.array : appender;
    import std.process : Config, pipeProcess, Redirect, wait;

    CapturedResult result;
    auto all = appender!string;
    const started = MonoTime.currTime;
    try
    {
        // `env` *adds to* the inherited environment rather than replacing it
        // (that would need `Config.newEnv`), so a caller sets one variable for
        // the child without having to reconstruct the rest.
        auto pipes = (() @trusted => pipeProcess(
            resolvedArgv(args), Redirect.stdout | Redirect.stderrToStdout,
            env, Config.none, workDir))();
        foreach (line; (() @trusted => pipes.stdout.byLine)())
        {
            sink(line);
            all ~= line;
            all ~= '\n';
        }
        result.status = (() @trusted => wait(pipes.pid))();
        result.stdout = all[];
    }
    catch (Exception e)
    {
        result.status = 127;
        result.stdout = all[];
        result.stderr = e.msg;
    }
    result.usage.wallTime = MonoTime.currTime - started;
    return result;
}

@("process_utils.runStreaming.linesArriveAndAggregate")
@system unittest
{
    string[] seen;
    auto r = runStreaming(
        ["sh", "-c", "echo one; echo two >&2; echo three"],
        (scope const(char)[] line) { seen ~= line.idup; });
    assert(r.succeeded);
    // stderr is merged into the stream in output order.
    assert(seen == ["one", "two", "three"]);
    assert(r.stdout == "one\ntwo\nthree\n");
    assert(r.stderr.length == 0);
}

@("process_utils.runStreaming.failuresNeverThrow")
@system unittest
{
    size_t calls;
    auto bad = runStreaming(
        ["sparkles-nonexistent-binary-xyzzy-123"],
        (scope const(char)[]) { calls++; });
    assert(bad.status == 127);
    assert(bad.stderr.length != 0);
    assert(calls == 0);

    auto failing = runStreaming(
        ["sh", "-c", "echo partial; exit 3"],
        (scope const(char)[]) { calls++; });
    assert(failing.status == 3);
    assert(calls == 1);
    assert(failing.stdout == "partial\n");
}

// -- resident children --------------------------------------------------------

version (Posix)
{
    /**
    A long-lived child process with line-oriented stdio — the seam an
    interactive viewer needs for a resident oracle (spawn once, exchange
    small JSON lines, never block the render loop).

    The child's stdout is switched to `O_NONBLOCK`, so `tryReadLine` returns
    immediately — with a complete line, or `null` when none has arrived —
    and a polling loop stays a polling loop. Writes go through `sendLine`
    (line-buffered flush). `alive` reaps non-blockingly; `terminate` sends
    SIGTERM and waits. The destructor terminates a still-running child so a
    dropped session cannot leak processes.
    */
    struct ResidentProcess
    {
        import std.process : Pid, ProcessPipes;

        private ProcessPipes _pipes;
        private bool _spawned;
        private bool _exited;
        private int _status;
        private char[] _pending;

        @disable this(this);

        /// Spawns `argv` with piped stdin/stdout (stderr passes through).
        static ResidentProcess spawn(scope const(char[])[] argv,
            string workDir = null) @trusted
        {
            import core.sys.posix.fcntl : F_GETFL, F_SETFL, fcntl, O_NONBLOCK;
            import std.process : Config, pipeProcess, Redirect;

            ResidentProcess p;
            p._pipes = pipeProcess(resolvedArgv(argv), Redirect.stdin | Redirect.stdout,
                null, Config.none, workDir);
            const fd = p._pipes.stdout.fileno;
            const flags = fcntl(fd, F_GETFL);
            if (flags >= 0)
                fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            p._spawned = true;
            return p;
        }

        ~this() @trusted
        {
            if (_spawned && !checkExited())
                terminate();
        }

        /// Whether the child is still running (reaps non-blockingly).
        bool alive() @trusted
            => _spawned && !checkExited();

        /// The exit status once `alive` turned false.
        int status() const @safe pure nothrow @nogc => _status;

        /// Writes one line to the child's stdin (appending the newline).
        void sendLine(scope const(char)[] line) @trusted
        {
            _pipes.stdin.writeln(line);
            _pipes.stdin.flush();
        }

        /// Closes the child's stdin (EOF — the conventional shutdown signal).
        void closeInput() @trusted
        {
            if (_pipes.stdin.isOpen)
                _pipes.stdin.close();
        }

        /// The read side's file descriptor (the child's stdout pipe), or -1
        /// before a spawn — the seam an event loop parks a readiness wait on
        /// (`waitReadable`) so `tryReadLine` polling becomes event-driven.
        int readFd() @trusted
            => _spawned ? _pipes.stdout.fileno : -1;

        /**
        One complete line from the child, without its terminator, or `null`
        when none is available yet. Non-blocking: partial lines accumulate
        internally until their newline arrives.
        */
        string tryReadLine() @trusted
        {
            import core.stdc.errno : EAGAIN, errno, EWOULDBLOCK;
            import core.sys.posix.unistd : read;

            // Drain whatever the pipe holds right now.
            for (;;)
            {
                char[4096] chunk = void;
                const n = read(_pipes.stdout.fileno, chunk.ptr, chunk.length);
                if (n > 0)
                {
                    _pending ~= chunk[0 .. n];
                    continue;
                }
                break; // EOF (0) or EAGAIN/other (<0): stop draining
            }

            foreach (i, c; _pending)
                if (c == '\n')
                {
                    auto line = _pending[0 .. i].idup;
                    _pending = _pending[i + 1 .. $];
                    return line;
                }
            return null;
        }

        /// SIGTERM + blocking wait.
        void terminate() @trusted
        {
            import core.sys.posix.signal : SIGTERM;
            import std.process : kill, wait;

            if (!_spawned || checkExited())
                return;
            try
            {
                kill(_pipes.pid, SIGTERM);
                _status = wait(_pipes.pid);
            }
            catch (Exception)
            {
            }
            _exited = true;
        }

        private bool checkExited() @trusted
        {
            import std.process : tryWait;

            if (_exited)
                return true;
            try
            {
                const r = tryWait(_pipes.pid);
                if (r.terminated)
                {
                    _status = r.status;
                    _exited = true;
                }
            }
            catch (Exception)
                _exited = true;
            return _exited;
        }
    }

    @("processUtils.ResidentProcess.echoRoundTrip")
    @system unittest
    {
        import core.thread : Thread;
        import core.time : msecs;

        auto p = ResidentProcess.spawn(["cat"]);
        assert(p.alive);

        p.sendLine("hello");
        p.sendLine("world");

        string[] got;
        foreach (_; 0 .. 200)
        {
            for (;;)
            {
                const line = p.tryReadLine();
                if (line is null)
                    break;
                got ~= line;
            }
            if (got.length >= 2)
                break;
            Thread.sleep(5.msecs);
        }
        assert(got == ["hello", "world"], got.length ? got[0] : "nothing");

        // EOF on stdin ends `cat`; the reap shows a clean exit.
        p.closeInput();
        foreach (_; 0 .. 200)
        {
            if (!p.alive)
                break;
            Thread.sleep(5.msecs);
        }
        assert(!p.alive);
        assert(p.status == 0);
    }

    @("processUtils.ResidentProcess.terminate")
    @system unittest
    {
        auto p = ResidentProcess.spawn(["cat"]);
        assert(p.alive);
        p.terminate();
        assert(!p.alive);
    }
}

@("process_utils.runStreaming.envAddsToTheInheritedEnvironment")
@system unittest
{
    import std.process : environment;

    // The child must see both the variable we set and the ones it inherited —
    // `std.process` replaces the environment only under `Config.newEnv`, and a
    // caller passing one variable does not mean to discard `PATH`.
    environment["CI_RUNSTREAMING_PARENT"] = "inherited";
    scope (exit)
        environment.remove("CI_RUNSTREAMING_PARENT");

    string[] seen;
    auto r = runStreaming(
        ["sh", "-c", `echo "$CI_RUNSTREAMING_CHILD/$CI_RUNSTREAMING_PARENT"`],
        (scope const(char)[] line) { seen ~= line.idup; },
        null,
        ["CI_RUNSTREAMING_CHILD": "added"]);

    assert(r.succeeded);
    assert(seen == ["added/inherited"]);
}
