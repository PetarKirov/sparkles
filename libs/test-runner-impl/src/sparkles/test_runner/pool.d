/**
 * The runner's worker pool (process-model §5): worker processes running one
 * test at a time, restarted after a crash, ended one at a time with the
 * coverage-merge rule.
 */
module sparkles.test_runner.pool;

import core.thread : Thread;
import core.time : Duration, msecs, seconds;

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

Workers start on demand (TRS1, TRD14): one at first, and another each
`rampInterval` as many more as the tests not yet taken justify, each worker
having at least `workerStartCost` of work at the pace kept so far, so a package whose
tests take milliseconds runs on one worker however large `nThreads` is. A
worker costs a process start and, in a coverage build, a coverage dump when
it ends. With more than one thread, the one thread returned is the
coordinator that starts and joins the workers.
*/
Thread[] startTestWorkers(Test[] tests, size_t nThreads,
    void delegate(TestResult) onResult, bool onCaller = true)
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;
    import core.time : MonoTime;

    if (!tests.length)
        return null;
    if (nThreads < 1)
        nThreads = 1;
    const mainThread = nThreads == 1 && onCaller;
    if (nThreads > tests.length)
        nThreads = tests.length;

    auto state = new PoolState;
    Thread worker()
    {
        return new Thread({
            Worker w;
            scope (exit)
                retire(w);
            try
                for (;;)
                {
                    if (atomicLoad(state.aborted))
                        break;
                    const i = atomicOp!"+="(state.next, 1) - 1;
                    if (i >= tests.length)
                        break;
                    if (w is null || w.dead)
                    {
                        retire(w); // a crashed one's readers, before it is dropped
                        w = takeWorker();
                    }
                    onResult(w.run(tests[i].id, mainThread));
                    atomicOp!"+="(state.done, 1);
                }
            catch (Throwable t)
            {
                atomicStore(state.aborted, true);
                throw t; // `joinTestWorkers` rethrows it
            }
        });
    }

    if (nThreads == 1)
    {
        auto only = worker();
        only.start();
        return [only];
    }

    auto coordinator = new Thread({
        Thread[] started = [worker()];
        started[0].start();
        const start = MonoTime.currTime;
        size_t lastDone;
        MonoTime lastProgress = start;
        while (started.length < nThreads)
        {
            Thread.sleep(rampInterval);
            if (atomicLoad(state.aborted))
                break;
            const taken = atomicLoad(state.next);
            if (taken >= tests.length)
                break;
            const done = atomicLoad(state.done);
            const now = MonoTime.currTime;
            if (done != lastDone)
            {
                lastDone = done;
                lastProgress = now;
            }
            const wanted = workersWanted(tests.length - taken, done, started.length, now - start,
                now - lastProgress, nThreads);
            while (started.length < wanted)
            {
                started ~= worker();
                started[$ - 1].start();
            }
        }
        // Join every worker before rethrowing the first one's throw.
        Throwable first;
        foreach (t; started)
        {
            try
                t.join();
            catch (Throwable e)
                if (first is null)
                    first = e;
        }
        if (first !is null)
            throw first;
    });
    coordinator.start();
    return [coordinator];
}

/// What the workers of one `startTestWorkers` call share.
private final class PoolState
{
    shared size_t next; /// Tests taken.
    shared size_t done; /// Tests finished.
    shared bool aborted;
}

/// How often the coordinator considers starting another worker.
enum rampInterval = 50.msecs;

/// What another worker costs to start and end: a process start, a hello,
/// and in a coverage build a dump of every module's listing.
enum workerStartCost = 250.msecs;

/**
How many workers the run wants now, at least `running` and at most `cap`:
enough that each has at least `workerStartCost` of the remaining work. The
remaining work is the `pending` tests at the pace so far, a test taking
`elapsed × running / done` on one worker. While no test has finished for
longer than that cost (`sinceProgress`, counted from the start before the
first result), the run is behind slow work, and doubles its workers each tick.
*/
size_t workersWanted(size_t pending, size_t done, size_t running, Duration elapsed,
    Duration sinceProgress, size_t cap) @safe pure nothrow @nogc
{
    if (pending == 0 || running >= cap)
        return running;
    // No test finished for longer than a worker costs, with tests waiting:
    // the run is behind slow work, which the pace so far does not show.
    if (done == 0 || sinceProgress > workerStartCost)
        return sinceProgress <= workerStartCost ? running : running * 2 > cap ? cap : running * 2;
    const perTest = elapsed * cast(long) running / cast(long) done;
    const work = perTest * cast(long) pending;
    const wanted = cast(size_t) (work / workerStartCost);
    return wanted < running ? running : wanted > cap ? cap : wanted;
}

@("pool.workersWanted.paceDecides")
@safe pure nothrow @nogc
unittest
{
    // `versions`: 167 tests in about 33 ms; after 50 ms on one worker, 160 done.
    assert(workersWanted(7, 160, 1, 50.msecs, 0.msecs, 25) == 1, "milliseconds of work left");
    // 20 of 790 done in 50 ms on one worker: about 2 s of work left, 7 workers.
    assert(workersWanted(770, 20, 1, 50.msecs, 0.msecs, 25) == 7);
    // Heavy tests: 3 of 400 done in 100 ms: far more work than workers.
    assert(workersWanted(397, 3, 1, 100.msecs, 0.msecs, 25) == 25, "capped at -t");
    // A first test still running past the start cost: twice the workers.
    assert(workersWanted(10, 0, 1, 100.msecs, 100.msecs, 8) == 1);
    assert(workersWanted(10, 0, 1, 300.msecs, 300.msecs, 8) == 2);
    assert(workersWanted(10, 0, 4, 400.msecs, 400.msecs, 6) == 6, "doubling stops at -t");
    // `ui`: 702 quick tests done, then one long test holds the only worker
    // while 87 wait; their pace says milliseconds, the stall says otherwise.
    assert(workersWanted(87, 702, 1, 500.msecs, 50.msecs, 25) == 1);
    assert(workersWanted(87, 702, 1, 800.msecs, 350.msecs, 25) == 2);
    assert(workersWanted(0, 5, 2, 1.seconds, 0.msecs, 8) == 2, "nothing left to take");
    assert(workersWanted(5, 100, 4, 1.seconds, 0.msecs, 25) == 4, "never fewer than are running");
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
