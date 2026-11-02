/**
 * `sparkles-test-runner`: the runner executable (process-model §2). A
 * launcher starts it as `sparkles-test-runner --test-binary=PATH [args]`,
 * and so does the build engine, directly (TRL3, TRL4).
 */
module sparkles.test_runner.app;

int main()
{
    import core.runtime : Runtime;
    import std.stdio : stderr;
    import std.string : fromStringz;
    import sparkles.test_runner.runner_impl : runnerMain;

    // druntime removes its `--DRT-` options from `main`'s arguments; the
    // workers need them (TRS5), so read the original vector.
    const c = Runtime.cArgs;
    string testBinary;
    string[] druntimeOptions, rest;
    enum flag = "--test-binary=";
    foreach (i; 1 .. c.argc)
    {
        const arg = (() @trusted => c.argv[i].fromStringz.idup)();
        if (arg.length > flag.length && arg[0 .. flag.length] == flag && !testBinary.length)
            testBinary = arg[flag.length .. $];
        else if (arg.length > 6 && arg[0 .. 6] == "--DRT-")
            druntimeOptions ~= arg;
        else
            rest ~= arg;
    }
    if (!testBinary.length)
    {
        stderr.writeln("usage: sparkles-test-runner --test-binary=PATH [options]\n",
            "A test binary built with sparkles:test-runner starts this program on",
            " itself when SPARKLES_TEST_RUNNER names it; see `--help` there.");
        return 2;
    }
    return runnerMain(testBinary, druntimeOptions, rest);
}
