/**
 * Consumer-side registration shim for `sparkles:test-runner`.
 *
 * The only runner code compiled into each test root: it registers druntime's
 * unittest hook, discovers the tested package's tests over dub's generated
 * `dub_test_root`, and hands them to `sparkles:test-harness`, which runs them
 * as a worker, a launcher or the fallback (process-model §3).
 */
module sparkles.test_runner.register;

version (unittest):

deprecated
{
    static if (!__traits(compiles, () { static import dub_test_root; }))
    {
        static assert(false,
            "Couldn't find 'dub_test_root'. Make sure you are running tests with `dub test`.");
    }
    else
    {
        static import dub_test_root;
    }
}

import core.attribute : standalone;
import core.runtime : Runtime, UnitTestResult;

import sparkles.test_runner.discovery : discoverTests;
import sparkles.test_runner.entry : harnessMain;

// `@standalone` breaks the ctor-ordering cycle with the generated
// `dub_test_root` module; this ctor only assigns a druntime global.
@standalone
shared static this() @system
{
    Runtime.extendedModuleUnitTester = &runnerHook;
}

private UnitTestResult runnerHook()
{
    const status = harnessMain(discoverTests!(dub_test_root.allModules)());
    // druntime exits with 1 when `executed != passed`, and 0 otherwise.
    return status == 0 ? UnitTestResult(1, 1, false, false)
        : UnitTestResult(1, 0, false, false);
}
