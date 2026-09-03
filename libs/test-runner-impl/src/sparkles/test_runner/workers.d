/**
 * Test worker pool: every worker is a `core.thread.Thread` with a 512 KiB
 * stack, matching macOS's pthread default. The main thread never runs a
 * test body when more than one worker is requested — that is what made
 * `DqlEngine`-sized stack locals flake (they fit the 8 MiB main stack and
 * SIGSEGV on a worker). Under ASan the stack is 4 MiB — see
 * `stack_budget.workerStackBytes`.
 */
module sparkles.test_runner.workers;

import core.atomic : atomicOp;
import core.thread : Thread;

import sparkles.test_runner.execution : executeTest;
import sparkles.test_runner.model : Test, TestResult;
import sparkles.test_runner.stack_budget : prepareCurrentThreadForStackBudget,
    workerStackBytes;

/**
Starts workers that call `onResult` once per test.

`onResult` must be thread-safe and must outlive $(LREF joinTestWorkers).
When `nThreads <= 1` the calling thread runs every test (still under the
stack-budget watermark) and this returns an empty list. When `nThreads > 1`
exactly that many 512 KiB workers run the suite and the caller does not
participate — join them with $(LREF joinTestWorkers). Each body is still
subject to the 384 KiB stack watermark.
*/
Thread[] startTestWorkers(Test[] tests, size_t nThreads,
    void delegate(TestResult) onResult)
{
    if (tests.length == 0 || nThreads <= 1)
    {
        if (tests.length)
        {
            prepareCurrentThreadForStackBudget();
            foreach (test; tests)
                onResult(executeTest(test));
        }
        return null;
    }

    shared size_t next;
    auto workers = new Thread[](nThreads);
    foreach (ref worker; workers)
    {
        worker = new Thread({
            prepareCurrentThreadForStackBudget();
            for (;;)
            {
                const i = atomicOp!"+="(next, 1) - 1;
                if (i >= tests.length)
                    break;
                onResult(executeTest(tests[i]));
            }
        }, workerStackBytes);
        worker.start();
    }
    return workers;
}

/// Blocks until every worker started by $(LREF startTestWorkers) has exited.
void joinTestWorkers(Thread[] workers)
{
    foreach (worker; workers)
        if (worker !is null)
            worker.join();
}

/// $(LREF startTestWorkers) plus $(LREF joinTestWorkers).
void runTests(Test[] tests, size_t nThreads, scope void delegate(TestResult) onResult)
{
    joinTestWorkers(startTestWorkers(tests, nThreads, onResult));
}

@("workers.runTests.serialRunsOnCaller")
@system
unittest
{
    static void ok() {}
    Test[] tests = [
        Test(fullName: "w.a", name: "a", ptr: &ok),
        Test(fullName: "w.b", name: "b", ptr: &ok),
    ];
    size_t seen;
    runTests(tests, 1, (TestResult r) { if (r.succeeded) ++seen; });
    assert(seen == 2);
}

@("workers.runTests.parallelJoinsEveryResult")
@system
unittest
{
    static void ok() {}
    Test[] tests;
    foreach (i; 0 .. 8)
        tests ~= Test(fullName: "w.p", name: "p", ptr: &ok);
    import core.sync.mutex : Mutex;

    auto mutex = new Mutex;
    size_t seen;
    runTests(tests, 2, (TestResult r) {
        synchronized (mutex)
            if (r.succeeded)
                ++seen;
    });
    assert(seen == 8);
}
