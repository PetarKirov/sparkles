/**
 * The harness's entry point, called from a test binary's registration hook
 * with the tests discovery found.
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

/// The arguments the program sees, without the program name and without
/// druntime's `--DRT-` options.
string[] programArguments()
{
    import core.runtime : Runtime;
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : startsWith;
    import std.array : array;

    auto all = Runtime.args;
    return all.length ? all[1 .. $].filter!(a => !a.startsWith("--DRT-")).array : null;
}

/// Runs `tests` and returns the process's exit status.
int harnessMain(Test[] tests)
{
    import sparkles.test_runner.fallback : runFallback;

    installHarnessHandlers();
    return runFallback(tests, programArguments());
}
