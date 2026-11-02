/**
 * The harness's entry point, called from a test binary's registration hook
 * with the tests discovery found. It picks the binary's mode
 * (process-model §3): a worker serving a runner, a launcher delegating to
 * one, or the fallback running the tests itself.
 */
module sparkles.test_runner.entry;

import sparkles.test_runner.model : Test;

/// Installs the in-binary handlers every mode needs (process-model TRP5).
void installHarnessHandlers()
{
    version (OSX)
    {
        // druntime resolves macOS stack traces by forking `atos -p <pid>`,
        // which intermittently stalls on sandboxed CI runners and hangs the
        // whole binary the moment a test throws. Swap in an in-process
        // handler that keeps the full backtrace but never spawns atos.
        import sparkles.test_runner.macos_trace : installInProcessTraceHandler;

        installInProcessTraceHandler();
    }
    import sparkles.test_runner.stack_budget : installStackBudgetHandler;

    installStackBudgetHandler();
}

/// The binary's original arguments, druntime's `--DRT-` options included,
/// without the program name.
private string[] originalArguments()
{
    import core.runtime : Runtime;
    import std.string : fromStringz;

    const c = Runtime.cArgs;
    string[] args;
    foreach (i; 1 .. c.argc)
        args ~= (() @trusted => c.argv[i].fromStringz.idup)();
    return args;
}

/// Whether `arg` is one of druntime's own options.
private bool isDruntimeOption(string arg) @safe pure nothrow @nogc
    => arg.length > 6 && arg[0 .. 6] == "--DRT-";

/**
Runs the binary in the mode its arguments and environment select, and returns
its exit status. A launcher never returns: it ends the process with the
runner's status (TRL3).
*/
int harnessMain(Test[] tests)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.stdio : stderr;
    import sparkles.test_runner.fallback : runFallback;
    import sparkles.test_runner.protocol : protocolFlag;
    import sparkles.test_runner.worker : serveWorker;

    installHarnessHandlers();
    auto args = originalArguments();
    auto program = args.filter!(a => !isDruntimeOption(a)).array;
    if (program.length && program[0].length > protocolFlag.length
        && program[0][0 .. protocolFlag.length] == protocolFlag)
    {
        // A worker that ends in error (no common version, a malformed
        // command) reports its status exactly (TRP9, TRP11).
        const status = serveWorker(tests, program[0][protocolFlag.length .. $]);
        if (status != 0)
            endProcess(status);
        return 0;
    }

    string runner;
    string origin;
    string[] rest;
    bool noRunner;
    foreach (arg; program)
    {
        enum runnerFlag = "--runner=";
        if (arg == "--no-runner")
            noRunner = true;
        else if (arg.length > runnerFlag.length && arg[0 .. runnerFlag.length] == runnerFlag)
        {
            runner = arg[runnerFlag.length .. $];
            origin = "--runner";
        }
        else
            rest ~= arg;
    }
    if (noRunner)
        return runFallback(tests, rest);
    if (!runner.length)
    {
        import std.process : environment;

        runner = environment.get("SPARKLES_TEST_RUNNER", null);
        origin = "SPARKLES_TEST_RUNNER";
    }
    if (!runner.length)
        return runFallback(tests, rest);
    if (!isExecutableFile(runner))
    {
        stderr.writeln("error: ", origin, " names '", runner,
            "', which is not an executable file");
        return 2;
    }
    endProcess(delegateTo(runner, args.filter!(a => isDruntimeOption(a)).array, rest));
}

/// Whether `path` names an executable file.
private bool isExecutableFile(string path)
{
    import std.file : exists, isFile;

    try
    {
        if (!path.exists || !path.isFile)
            return false;
        version (Posix)
        {
            import core.sys.posix.unistd : access, X_OK;
            import std.string : toStringz;

            return access(path.toStringz, X_OK) == 0;
        }
        else
            return true;
    }
    catch (Exception)
        return false;
}

/// Starts `runner` on this binary and waits for it (TRL3, TRW3).
private int delegateTo(string runner, string[] druntimeOptions, string[] rest)
{
    import std.file : thisExePath;
    import std.process : spawnProcess, wait;
    import std.stdio : stderr;

    try
        return wait(spawnProcess([runner, "--test-binary=" ~ thisExePath]
            ~ druntimeOptions ~ rest));
    catch (Exception e)
    {
        stderr.writeln("error: cannot start the test runner '", runner, "': ", e.msg);
        return 2;
    }
}

/// Ends the process with `status`, skipping druntime's termination, so the
/// launcher writes no coverage of its own over its workers' (TRL3).
private noreturn endProcess(int status)
{
    import core.stdc.stdio : fflush;
    import core.stdc.stdlib : _Exit;

    fflush(null);
    _Exit(status < 0 ? 128 - status : status);
}
