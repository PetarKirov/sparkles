/**
 * Registration for the harness's own tests (process-model TRP4). The
 * harness cannot depend on the shim, whose registration depends on the
 * harness, so its unittest configuration selects this module instead.
 */
module sparkles.test_runner.self_host;

version (SparklesTestHarnessSelfHost):
version (unittest):

static import dub_test_root;

import core.attribute : standalone;
import core.runtime : Runtime, UnitTestResult;

import sparkles.test_runner.discovery : discoverTests;
import sparkles.test_runner.entry : harnessMain;

@standalone
shared static this() @system
{
    Runtime.extendedModuleUnitTester = &hook;
}

private UnitTestResult hook()
{
    const status = harnessMain(discoverTests!(dub_test_root.allModules)());
    return status == 0 ? UnitTestResult(1, 1, false, false)
        : UnitTestResult(1, 0, false, false);
}
