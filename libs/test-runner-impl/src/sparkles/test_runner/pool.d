/**
 * The runner's worker pool (process-model §5): worker processes running one
 * test at a time, restarted after a crash, ended one at a time with the
 * coverage-merge rule.
 */
module sparkles.test_runner.pool;

import core.thread : Thread;

import sparkles.test_runner.client : StrayHandler, Worker;
import sparkles.test_runner.model : Test, TestResult;

/// How to start workers of the binary under test.
struct WorkerLaunch
{
    string binary;
    string[] druntimeOptions;
    StrayHandler onStray;
}

private __gshared WorkerLaunch launch;
private __gshared Worker spare;
private __gshared Test[] firstListing;
private __gshared bool anyExited;
private __gshared bool callerMerges;
private __gshared Object exitLock;
private __gshared Object spareLock;

/// Starts the first worker, which says what the binary holds; later workers
/// must list the same tests (TRP14).
Worker startFirstWorker(WorkerLaunch how)
{
    import std.algorithm.searching : canFind;

    launch = how;
    exitLock = new Object;
    spareLock = new Object;
    callerMerges = how.druntimeOptions.canFind!(o => o.canFind("merge:1"));
    spare = new Worker(how.binary, how.druntimeOptions, how.onStray);
    firstListing = spare.listing;
    return spare;
}

/// A worker: the first one while it is unused, else a new one.
Worker takeWorker()
{
    synchronized (spareLock)
        if (spare !is null)
        {
            auto w = spare;
            spare = null;
            return w;
        }
    auto w = new Worker(launch.binary, launch.druntimeOptions, launch.onStray);
    if (w.listing != firstListing)
    {
        w.exit(coverageMerge: true);
        throw new Exception("the test binary listed different tests in two workers"
            ~ " (process-model TRP14): discovery is not deterministic");
    }
    return w;
}

/// Ends `w`, one worker at a time; every exit after the first merges its
/// coverage into what the earlier ones wrote (TRS4, TRS5). A worker that
/// already died is only waited for: its readers finish before the runner's
/// druntime terminates (see `Worker.joinReaders`).
void retire(Worker w)
{
    if (w is null)
        return;
    if (w.dead)
        return w.joinReaders();
    synchronized (exitLock)
    {
        w.exit(coverageMerge: anyExited || callerMerges);
        anyExited = true;
    }
}

/// Ends the unused first worker, if nobody took it.
void retireSpare()
{
    Worker w;
    synchronized (spareLock)
    {
        w = spare;
        spare = null;
    }
    retire(w);
}

/**
Runs `tests` on up to `nThreads` workers, calling `onResult` once per test,
from the thread that ran it. With `nThreads <= 1` and `onCaller`, the one
worker runs each test on its main thread (TRP17). Join the returned threads
with $(LREF joinTestWorkers). When one thread throws, the others take no
further test, so every thread finishes and $(LREF testWorkersFinished) says
so although some tests have no result.
*/
Thread[] startTestWorkers(Test[] tests, size_t nThreads,
    void delegate(TestResult) onResult, bool onCaller = true)
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;

    if (!tests.length)
        return null;
    if (nThreads < 1)
        nThreads = 1;
    const mainThread = nThreads == 1 && onCaller;
    if (nThreads > tests.length)
        nThreads = tests.length;

    shared size_t next;
    shared bool aborted;
    auto threads = new Thread[](nThreads);
    foreach (ref thread; threads)
    {
        thread = new Thread({
            Worker w;
            scope (exit)
                retire(w);
            try
                for (;;)
                {
                    if (atomicLoad(aborted))
                        break;
                    const i = atomicOp!"+="(next, 1) - 1;
                    if (i >= tests.length)
                        break;
                    if (w is null || w.dead)
                    {
                        retire(w); // a crashed one's readers, before it is dropped
                        w = takeWorker();
                    }
                    onResult(w.run(tests[i].id, mainThread));
                }
            catch (Throwable t)
            {
                atomicStore(aborted, true);
                throw t; // `joinTestWorkers` rethrows it
            }
        });
        thread.start();
    }
    return threads;
}

/// Whether every thread from $(LREF startTestWorkers) has finished, by
/// running out of tests or by a throw that stopped them all. A caller that
/// counts results to know when the run is over must also ask this: a throw
/// leaves tests without one.
bool testWorkersFinished(Thread[] threads)
{
    foreach (thread; threads)
        if (thread.isRunning)
            return false;
    return true;
}

/// Blocks until every thread from $(LREF startTestWorkers) has finished,
/// rethrowing what one of them threw.
void joinTestWorkers(Thread[] threads)
{
    foreach (thread; threads)
        thread.join();
}
