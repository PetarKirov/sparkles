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
    import std.process : Config, environment;

    auto full = environment.toAA;
    full.remove("SPARKLES_TEST_RUNNER");
    foreach (k, v; env)
        full[k] = v;
    return execute(args, full, Config.newEnv);
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
    assert(r.output.canFind("2 passed, 1 failed"), "the other tests still run: " ~ r.output);
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
