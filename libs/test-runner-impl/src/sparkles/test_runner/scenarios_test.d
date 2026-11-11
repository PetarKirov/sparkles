/**
 * The process model's scenarios end to end (docs/specs/test-runner/
 * process-model.md §11): this package's runner executable, built from the
 * working tree, driving `tests/fixture/` as worker processes, and the
 * fixture's own fallback and launcher. Each scenario starts real processes;
 * the oracle is their exit status and output.
 */
module sparkles.test_runner.scenarios_test;

version (unittest):

import std.algorithm.searching : canFind, countUntil;
import std.array : replace;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.process : execute;

/// This package's directory.
private string here()
{
    import std.path : absolutePath;

    return __FILE_FULL_PATH__.dirName.absolutePath
        .buildNormalizedPath("..", "..", "..");
}

/// The runner executable and the fixture's test binary, built once per
/// worker process; a lock file keeps the workers' dub builds of the same
/// trees from racing each other.
private struct Built
{
    string runner;
    string fixture;
}

private Built built()
{
    import std.concurrency : initOnce;

    static Built build()
    {
        import std.file : mkdirRecurse;
        import std.stdio : File;

        here.buildPath("build").mkdirRecurse;
        auto lock = File(here.buildPath("build", ".scenarios.lock"), "w");
        lock.lock();
        scope (exit)
            lock.unlock();
        const root = here.buildNormalizedPath("..", "..");
        version (Windows)
            enum exe = ".exe";
        else
            enum exe = "";
        const runner = here.buildPath("build", "sparkles-test-runner" ~ exe);
        // Windows cannot replace an executable that is running, and the
        // Windows leg runs this suite through the runner this build relinks:
        // the unittest build rebuilt its dependencies' libraries in `build/`,
        // so the target is stale. A running executable can still be renamed,
        // so it steps aside and keeps serving the run.
        version (Windows)
        {
            import std.file : exists, remove, rename;

            const aside = runner ~ ".old";
            if (aside.exists)
                try
                    remove(aside);
                catch (Exception)
                {
                }
            if (runner.exists && !aside.exists)
                rename(runner, aside);
        }
        // `checked`, the build the Windows leg runs the suite with.
        auto r = execute(["dub", "build", "-q", "--root=" ~ root, ":test-runner-impl",
            "--config=application", "--build=checked"]);
        assert(r.status == 0, r.output);
        const fixtureDir = here.buildPath("tests", "fixture");
        r = execute(["dub", "build", "-q", "--root=" ~ fixtureDir, "--config=unittest",
            "--build=unittest"]);
        assert(r.status == 0, r.output);
        return Built(
            runner: runner,
            fixture: buildPath(fixtureDir, "build", "runner-fixture-test-unittest" ~ exe));
    }

    static shared Built paths;
    return initOnce!paths(build());
}

/// Runs `args` with `env` added and `SPARKLES_TEST_RUNNER` removed unless
/// `env` sets it.
private auto run(string[] args, string[string] env = null)
{
    import std.process : Config;

    return execute(args, scenarioEnvironment(env), Config.newEnv);
}

/// This process's environment with `env` added, and `SPARKLES_TEST_RUNNER`
/// removed unless `env` sets it.
private string[string] scenarioEnvironment(string[string] env)
{
    import std.process : environment;

    auto full = environment.toAA;
    full.remove("SPARKLES_TEST_RUNNER");
    foreach (k, v; env)
        full[k] = v;
    return full;
}

/// How a run that may hang ended.
private struct Bounded
{
    int status;
    string output;
    /// Whether it outlived its limit and was killed.
    bool timedOut;
    imported!"core.time".Duration took;
}

/// Runs `args` like $(LREF run), killing it once `limit` has passed: a
/// scenario whose defect is a hang fails instead of hanging the suite.
private Bounded runWithin(string[] args, string[string] env,
    imported!"core.time".Duration limit)
{
    import core.atomic : atomicOp;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.conv : text;
    import std.file : readText, remove, tempDir;
    import std.process : Config, kill, spawnProcess, thisProcessID, tryWait, wait;
    import std.stdio : File;

    static shared size_t serial;
    const log = buildPath(tempDir, text("sparkles-scenario-", thisProcessID, "-",
        atomicOp!"+="(serial, 1), ".log"));
    scope (exit)
        remove(log);
    Bounded outcome;
    {
        auto output = File(log, "w");
        version (Windows)
            auto input = File("NUL", "r");
        else
            auto input = File("/dev/null", "r");
        const started = MonoTime.currTime;
        auto pid = spawnProcess(args, input, output, output, scenarioEnvironment(env),
            Config.newEnv);
        for (;;)
        {
            const r = tryWait(pid);
            if (r.terminated)
            {
                outcome.status = r.status;
                break;
            }
            if (MonoTime.currTime - started > limit)
            {
                outcome.timedOut = true;
                kill(pid);
                outcome.status = wait(pid);
                break;
            }
            Thread.sleep(20.msecs);
        }
        outcome.took = MonoTime.currTime - started;
    }
    outcome.output = readText(log);
    return outcome;
}

/// Runs `args` like $(LREF runWithin), with a pseudo-terminal for its
/// standard output and error, as a developer's run has: the runner then
/// draws its live progress line.
version (Posix)
private Bounded runOnTerminal(string[] args, string[string] env,
    imported!"core.time".Duration limit)
{
    import core.sys.posix.fcntl : O_NOCTTY, O_RDWR, open;
    import core.sys.posix.poll : poll, pollfd, POLLIN;
    import core.sys.posix.stdlib : grantpt, posix_openpt, ptsname, unlockpt;
    import core.sys.posix.unistd : close, read;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;
    import std.process : Config, kill, spawnProcess, tryWait, wait;
    import std.stdio : File;

    const master = posix_openpt(O_RDWR | O_NOCTTY);
    assert(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0, "no pseudo-terminal");
    scope (exit)
        close(master);
    Bounded outcome;
    const started = MonoTime.currTime;
    imported!"std.process".Pid pid;
    {
        File terminal;
        terminal.fdopen(open(ptsname(master), O_RDWR | O_NOCTTY), "r+");
        pid = spawnProcess(args, File("/dev/null", "r"), terminal, terminal,
            scenarioEnvironment(env), Config.newEnv);
    } // only the child holds the terminal now: its end reads as EIO here

    ubyte[4096] buffer;
    bool hungUp;
    // Takes what the terminal holds; `false` once nothing is waiting.
    bool take(int timeoutMs)
    {
        auto p = pollfd(master, POLLIN);
        if (hungUp || poll(&p, 1, timeoutMs) <= 0)
            return false;
        const n = read(master, buffer.ptr, buffer.length);
        if (n <= 0)
        {
            hungUp = true;
            return false;
        }
        outcome.output ~= cast(const(char)[]) buffer[0 .. n];
        return true;
    }

    for (;;)
    {
        // The terminal must be read as it fills, or the runner blocks on it.
        if (take(20))
            continue;
        const r = tryWait(pid);
        if (r.terminated)
        {
            outcome.status = r.status;
            while (take(0))
            {
            }
            break;
        }
        if (MonoTime.currTime - started > limit)
        {
            outcome.timedOut = true;
            kill(pid);
            outcome.status = wait(pid);
            break;
        }
        if (hungUp)
            Thread.sleep(20.msecs);
    }
    outcome.took = MonoTime.currTime - started;
    return outcome;
}

@("scenarios.versionMismatchExitsThree")
@system
unittest
{
    const r = run([built.fixture, "--sparkles-test-protocol=99-99"]);
    assert(r.status == 3, r.output);
    assert(r.output.canFind(`"version":null`), r.output);
    assert(!r.output.canFind("fixture.writes"), "no test runs: " ~ r.output);
}

@("scenarios.outputBeforeEachResult")
@system
unittest
{
    const r = run([built.runner, "--test-binary=" ~ built.fixture, "-t", "2", "--no-colors"]);
    assert(r.status == 0, r.output);
    // A Windows test's text-mode streams end its lines with CR LF.
    const output = r.output.replace("\r\n", "\n");
    const result = output.countUntil("fixture.writes");
    foreach (line; ["one", "two", "three"])
    {
        const at = output.countUntil(line ~ "\n");
        assert(at >= 0 && at < result, line ~ " precedes its result: " ~ output);
    }
}

@("scenarios.aCrashFailsOnlyItsTest")
@system
unittest
{
    const r = run([built.runner, "--test-binary=" ~ built.fixture, "-t", "1", "--no-colors"],
        ["FIXTURE_CRASH": "1"]);
    assert(r.status != 0, r.output);
    const crashed = r.output.countUntil("✗");
    assert(crashed >= 0 && r.output[crashed .. $].canFind("fixture.crashes"), r.output);
    const said = r.output.countUntil("about to abort");
    assert(said >= 0 && said < crashed, "the output before the crash is kept: " ~ r.output);
    assert(r.output.canFind("worker crashed"), r.output);
    version (Posix)
        assert(r.output.canFind("SIGABRT"), r.output);
    assert(r.output.canFind(" passed, 1 failed"), "the other tests still run: " ~ r.output);
}

@("scenarios.fallbackFiltersAndRefusesRunnerOptions")
@system
unittest
{
    auto r = run([built.fixture, "--no-runner", "-i", "writes"]);
    assert(r.status == 0, r.output);
    assert(r.output.canFind("✓ fixture.writes") && !r.output.canFind("fixture.after"), r.output);

    r = run([built.fixture, "--no-runner", "--bench"]);
    assert(r.status != 0, r.output);
    assert(r.output.canFind("--bench: needs the test runner"), r.output);
    assert(!r.output.canFind("✓"), "no test runs: " ~ r.output);
}

@("scenarios.aBadRunnerPathIsRefused")
@system
unittest
{
    const r = run([built.fixture], ["SPARKLES_TEST_RUNNER": built.fixture ~ ".missing"]);
    assert(r.status != 0, r.output);
    assert(r.output.canFind("SPARKLES_TEST_RUNNER names"), r.output);
    assert(!r.output.canFind("✓"), "no test runs: " ~ r.output);
}

@("scenarios.launcherDelegates")
@system
unittest
{
    const r = run([built.fixture, "-i", "after", "--no-colors"],
        ["SPARKLES_TEST_RUNNER": built.runner]);
    assert(r.status == 0, r.output);
    assert(r.output.canFind("1 passed"), r.output);
}

@("scenarios.anAbortWhileExitingFailsTheRun")
@system
unittest
{
    // Every test passes; the worker's module destructor aborts once it is
    // asked to exit: at once, or six seconds later.
    foreach (how; ["1", "late"])
    {
        const r = run([built.runner, "--test-binary=" ~ built.fixture, "-t", "1", "--no-colors"],
            ["FIXTURE_ABORT_AT_EXIT": how]);
        assert(r.status != 0, how ~ ": " ~ r.output);
        assert(r.output.canFind("asked to exit"), how ~ ": " ~ r.output);
        version (Posix)
            assert(r.output.canFind("SIGABRT"), how ~ ": " ~ r.output);
    }
}

@("scenarios.aThrowInAWorkerThreadEndsALiveRun")
@system
unittest
{
    import core.time : seconds;

    // On a terminal the runner draws a progress line until every test has a
    // result. A protocol error thrown in a worker thread leaves tests with
    // none: the run must still end, and fail, as it does when piped.
    version (Posix)
    {
        const r = runOnTerminal([built.runner, "--test-binary=" ~ built.fixture, "-t", "2"],
            ["FIXTURE_BAD_FRAME": "1", "TERM": "xterm-256color", "NO_COLOR": ""], 60.seconds);
        assert(!r.timedOut, "the progress line spun on: " ~ r.output);
        assert(r.status == 2, r.output);
        assert(r.output.canFind("protocol error from"), r.output);
    }
}

@("scenarios.aCrashIsSeenWhileAChildHoldsThePipes")
@system
unittest
{
    import core.time : seconds;

    // A test forks a child that sleeps for 20 s holding every channel, then
    // aborts: the crash is reported when it happens, not when the child
    // lets go of the frames pipe (TRP28).
    version (Posix)
    {
        const r = runWithin([built.runner, "--test-binary=" ~ built.fixture, "-t", "1",
            "--no-colors"], ["FIXTURE_FORK_AND_CRASH": "1"], 60.seconds);
        assert(!r.timedOut, r.output);
        assert(r.took < 10.seconds, "the crash waited for the child: " ~ r.output);
        assert(r.status == 1, r.output);
        assert(r.output.canFind("fixture.forksAndCrashes") && r.output.canFind("SIGABRT"),
            r.output);
        assert(r.output.canFind(" passed, 1 failed"), "the other tests still run: " ~ r.output);
    }
}

@("scenarios.aMalformedFrameFailsTheRun")
@system
unittest
{
    import core.time : seconds;

    // A test writes a `result` frame with none of its members to the frames
    // channel: a protocol error that fails the run (TRP9), where the reader
    // used to die of the exception and leave the runner waiting forever.
    version (Posix)
    {
        const r = runWithin([built.runner, "--test-binary=" ~ built.fixture, "-t", "1",
            "--no-colors"], ["FIXTURE_BAD_FRAME": "1"], 60.seconds);
        assert(!r.timedOut, "the runner hung: " ~ r.output);
        assert(r.status == 2, r.output);
        assert(r.output.canFind("protocol error from") && r.output.canFind("a malformed frame"),
            r.output);
    }
}
