/**
 * Consumer-side registration shim for `sparkles:test-runner`.
 *
 * This is the only runner code compiled into each test binary (with
 * `-unittest`): it registers the druntime hook, reflects over the tested
 * package's modules to discover unittests, and hands the resulting `Test[]` to
 * the prebuilt implementation library across a thin `extern(C)` seam. The heavy
 * machinery (CLI, execution, reporting, drivers) lives in the prebuilt library,
 * so consumers never *parse* it — that is what keeps `dub test` near-vanilla.
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

import std.traits : fullyQualifiedName;

import sparkles.test_runner.discovery : discoverTests, moduleOf;
import sparkles.test_runner.model : Test;

/// The prebuilt implementation library's entry point. Declared here as an
/// `extern(C)` prototype so the shim links against it without importing (and
/// thus parsing) the library's heavy modules.
extern (C) void sparkles_test_runner_run(
    Test* tests, size_t count, bool hostIsRunner, uint* executed, uint* passed);

// `@standalone` breaks the ctor-ordering cycle with the generated
// `dub_test_root` module; this ctor only assigns a druntime global.
@standalone
shared static this() @system
{
    Runtime.extendedModuleUnitTester = &runnerHook;
}

private UnitTestResult runnerHook()
{
    auto tests = discoverTests!(dub_test_root.allModules)();
    uint executed, passed;
    sparkles_test_runner_run(tests.ptr, tests.length, hostIsRunner, &executed, &passed);
    return UnitTestResult(executed, passed, false, false);
}

private template isRunnerModule(alias m)
{
    import std.algorithm.searching : startsWith;

    enum isRunnerModule =
        fullyQualifiedName!(moduleOf!m).startsWith("sparkles.test_runner");
}

/// Whether every module in the test build belongs to the runner — the
/// compile-time half of "the tested package is the runner itself". Computed
/// here (needs `dub_test_root`) and passed to the library, which combines it
/// with a runtime test-binary-name check.
private enum bool hostIsRunner =
    imported!"std.meta".allSatisfy!(isRunnerModule, dub_test_root.allModules);

private template imported(string moduleName)
{
    mixin("import imported = ", moduleName, ";");
}
