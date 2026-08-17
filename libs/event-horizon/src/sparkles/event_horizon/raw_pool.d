/**
Persistent fixed-capacity CPU jobs for interactive hosts.

Unlike the batch-scoped `WorkStealingPool`, this pool stays alive across
generations and accepts closure-free function-pointer jobs over caller-owned
contexts. All allocation and thread creation happens in `start`; submission,
execution, completion polling, and shutdown use fixed rings.
*/
module sparkles.event_horizon.raw_pool;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import std.parallelism : totalCPUs;

/// Work callback. The context remains caller-owned and address-stable.
alias RawJobFn = void function(void*) @safe nothrow @nogc;

/// Completion callback dispatched by the polling thread.
alias RawCompletionFn = void function(void*, bool cancelled)
    @safe nothrow @nogc;

/// One closure-free job. A non-null completion reserves one completion slot.
struct RawJob
{
    RawJobFn run;
    RawCompletionFn complete;
    void* context;
    ulong generation;
}

/// One completed or shutdown-cancelled raw job.
struct RawCompletion
{
    RawCompletionFn complete;
    void* context;
    ulong generation;
    bool cancelled;

    /// Invoke the optional callback on the polling thread.
    void dispatch() @safe nothrow @nogc
    {
        if (complete !is null)
            complete(context, cancelled);
    }
}

/// Result of a raw-pool lifecycle or queue operation.
enum RawPoolResult : ubyte
{
    accepted,
    noCompletion,
    notStarted,
    alreadyStarted,
    queueFull,
    completionFull,
    shuttingDown,
    invalidJob,
    startFailed,
}

private enum RawPoolState : ubyte
{
    stopped,
    running,
    draining,
    cancelling,
}

/**
A persistent bounded CPU pool.

The object is non-copyable and must remain at the address passed to `start`
until `shutdown` returns. `QueueCapacity` and `CompletionCapacity` are hard
bounds; neither queue grows.
*/
struct RawCpuPool(size_t QueueCapacity = 256,
    size_t CompletionCapacity = QueueCapacity)
if (QueueCapacity > 0 && CompletionCapacity > 0)
{
    @disable this(this);

    /**
    Start `workers` persistent threads (`0` means the online CPU count).

    All setup failures are reported as `startFailed`; no worker survives a
    failed start.
    */
    static RawPoolResult start(ref RawCpuPool pool, uint workers = 0)
        @trusted nothrow
    {
        if (pool._state != RawPoolState.stopped || pool._threads.length)
            return RawPoolResult.alreadyStarted;
        size_t startedThreads;
        try
        {
            pool._mutex = new Mutex;
            pool._available = new Condition(pool._mutex);
            pool._workers = workers != 0 ? workers : cast(uint) totalCPUs;
            if (pool._workers == 0)
                pool._workers = 1;
            pool._threads = new Thread[pool._workers];
            pool._state = RawPoolState.running;

            auto owner = &pool;
            foreach (i; 0 .. pool._workers)
            {
                auto thread = new Thread(() => workerMain(owner));
                pool._threads[i] = thread;
                thread.start();
                ++startedThreads;
            }
            return RawPoolResult.accepted;
        }
        catch (Throwable)
        {
            if (pool._mutex !is null)
            {
                pool._mutex.lock_nothrow();
                pool._state = RawPoolState.cancelling;
                if (pool._available !is null)
                    notifyAllNoThrow(pool._available);
                pool._mutex.unlock_nothrow();
            }
            foreach (i; 0 .. startedThreads)
                joinNoThrow(pool._threads[i]);
            pool._threads = null;
            pool._workers = 0;
            pool._state = RawPoolState.stopped;
            return RawPoolResult.startFailed;
        }
    }

    /// Number of worker threads selected at start.
    uint workerCount() const @safe pure nothrow @nogc => _workers;

    /// Submit one job without blocking. A rejected job is not consumed.
    RawPoolResult submit(RawJob job) @trusted nothrow @nogc
    {
        if (job.run is null)
            return RawPoolResult.invalidJob;
        if (_mutex is null)
            return RawPoolResult.notStarted;

        _mutex.lock_nothrow();
        scope (exit) _mutex.unlock_nothrow();
        final switch (_state)
        {
        case RawPoolState.stopped:
            return RawPoolResult.notStarted;
        case RawPoolState.draining:
        case RawPoolState.cancelling:
            return RawPoolResult.shuttingDown;
        case RawPoolState.running:
            break;
        }
        if (_jobCount == QueueCapacity)
            return RawPoolResult.queueFull;
        if (job.complete !is null
            && _completionCount + _completionReserved == CompletionCapacity)
            return RawPoolResult.completionFull;

        _jobs[_jobTail] = job;
        _jobTail = (_jobTail + 1) % QueueCapacity;
        ++_jobCount;
        if (job.complete !is null)
            ++_completionReserved;
        notifyOneNoThrow(_available);
        return RawPoolResult.accepted;
    }

    /**
    Poll one completion. The returned value owns no memory; dispatch it before
    releasing or reusing its context.
    */
    RawPoolResult pollCompletion(out RawCompletion completion)
        @trusted nothrow @nogc
    {
        completion = RawCompletion.init;
        if (_mutex is null)
            return RawPoolResult.notStarted;
        _mutex.lock_nothrow();
        scope (exit) _mutex.unlock_nothrow();
        if (_completionCount == 0)
            return RawPoolResult.noCompletion;
        completion = _completions[_completionHead];
        _completionHead = (_completionHead + 1) % CompletionCapacity;
        --_completionCount;
        return RawPoolResult.accepted;
    }

    /**
    Stop and join the pool. Draining executes queued work; cancelling publishes
    cancelled completions for queued work. Running jobs always finish.

    Idempotent. Completion values remain pollable after shutdown, so contexts
    with completion callbacks remain alive through later dispatch.
    */
    RawPoolResult shutdown(bool drain = true) @trusted nothrow @nogc
    {
        if (_mutex is null)
            return RawPoolResult.accepted;
        _mutex.lock_nothrow();
        if (_state == RawPoolState.stopped)
        {
            _mutex.unlock_nothrow();
            return RawPoolResult.accepted;
        }
        _state = drain ? RawPoolState.draining : RawPoolState.cancelling;
        if (!drain)
        {
            while (_jobCount != 0)
            {
                auto job = popJobLocked();
                publishCompletionLocked(job, true);
            }
        }
        notifyAllNoThrow(_available);
        _mutex.unlock_nothrow();

        foreach (thread; _threads)
            joinNoThrow(thread);

        _mutex.lock_nothrow();
        _state = RawPoolState.stopped;
        _threads = null;
        _workers = 0;
        _mutex.unlock_nothrow();
        return RawPoolResult.accepted;
    }

    ~this() @trusted nothrow
    {
        // A destructor can run during GC finalization (a heap owner swept at
        // `gc_term`), where the pool's Mutex/Condition class instances may
        // already have been finalized — finalization order is unspecified —
        // and locking a dead mutex crashes. A pool the owner already stopped
        // has nothing left to do, so it must not touch its sync objects
        // again; `_state` is safely `stopped` here because `shutdown` joined
        // every worker before storing it.
        if (_state == RawPoolState.stopped || _mutex is null)
            return;
        cast(void) shutdown(true);
    }

private:
    static void workerMain(RawCpuPool* pool) @trusted nothrow
    {
        for (;;)
        {
            pool._mutex.lock_nothrow();
            while (pool._jobCount == 0
                && pool._state == RawPoolState.running)
                waitNoThrow(pool._available);
            if (pool._jobCount == 0
                && pool._state != RawPoolState.running)
            {
                pool._mutex.unlock_nothrow();
                return;
            }
            auto job = pool.popJobLocked();
            pool._mutex.unlock_nothrow();

            job.run(job.context);

            if (job.complete !is null)
            {
                pool._mutex.lock_nothrow();
                pool.publishCompletionLocked(job, false);
                pool._mutex.unlock_nothrow();
            }
        }
    }

    RawJob popJobLocked() @safe pure nothrow @nogc
    {
        auto job = _jobs[_jobHead];
        _jobHead = (_jobHead + 1) % QueueCapacity;
        --_jobCount;
        return job;
    }

    void publishCompletionLocked(RawJob job, bool cancelled)
        @safe pure nothrow @nogc
    {
        if (job.complete is null)
            return;
        _completions[_completionTail] = RawCompletion(
            job.complete, job.context, job.generation, cancelled);
        _completionTail = (_completionTail + 1) % CompletionCapacity;
        ++_completionCount;
        --_completionReserved;
    }

    Mutex _mutex;
    Condition _available;
    Thread[] _threads;
    uint _workers;
    RawPoolState _state;

    RawJob[QueueCapacity] _jobs = void;
    size_t _jobHead;
    size_t _jobTail;
    size_t _jobCount;

    RawCompletion[CompletionCapacity] _completions = void;
    size_t _completionHead;
    size_t _completionTail;
    size_t _completionCount;
    size_t _completionReserved;
}

// DRuntime's synchronization methods conservatively expose throwing/GC
// signatures because they construct a SyncError on an impossible OS failure.
// The underlying successful calls neither throw nor allocate. These wrappers
// narrow the attributes at the one reviewed system seam; an actual primitive
// failure terminates rather than escaping a public `nothrow` operation.
private void notifyOneNoThrow(Condition condition) @trusted nothrow @nogc
{
    alias Notify = void function(Condition) nothrow @nogc;
    (cast(Notify) &notifyOne)(condition);
}

private void notifyAllNoThrow(Condition condition) @trusted nothrow @nogc
{
    alias Notify = void function(Condition) nothrow @nogc;
    (cast(Notify) &notifyAll)(condition);
}

private void waitNoThrow(Condition condition) @trusted nothrow
{
    alias Wait = void function(Condition) nothrow;
    (cast(Wait) &waitOne)(condition);
}

private void joinNoThrow(Thread thread) @trusted nothrow @nogc
{
    alias Join = Throwable function(Thread, bool) nothrow @nogc;
    cast(void)(cast(Join) &joinOne)(thread, false);
}

private void notifyOne(Condition condition) => condition.notify();
private void notifyAll(Condition condition) => condition.notifyAll();
private void waitOne(Condition condition) => condition.wait();
private Throwable joinOne(Thread thread, bool rethrow_) => thread.join(rethrow_);

@("rawPool.executesAndCompletesExactlyOnce")
@system
unittest
{
    import core.atomic : atomicLoad, atomicOp;

    static struct Context
    {
        shared uint ran;
        shared uint completed;
    }
    static void run(void* raw) @trusted nothrow @nogc
    {
        auto context = cast(Context*) raw;
        atomicOp!"+="(context.ran, 1);
    }
    static void complete(void* raw, bool cancelled) @trusted nothrow @nogc
    {
        assert(!cancelled);
        auto context = cast(Context*) raw;
        atomicOp!"+="(context.completed, 1);
    }

    RawCpuPool!(8, 8) pool;
    assert(RawCpuPool!(8, 8).start(pool, 2) == RawPoolResult.accepted);
    assert(RawCpuPool!(8, 8).start(pool, 1)
        == RawPoolResult.alreadyStarted);
    Context[4] contexts;
    foreach (i; 0 .. contexts.length)
    {
        assert(pool.submit(RawJob(&run, &complete, &contexts[i], i))
            == RawPoolResult.accepted);
    }
    assert(pool.shutdown(true) == RawPoolResult.accepted);

    uint completions;
    RawCompletion completion;
    while (pool.pollCompletion(completion) == RawPoolResult.accepted)
    {
        completion.dispatch();
        ++completions;
    }
    assert(completions == contexts.length);
    foreach (ref context; contexts)
    {
        assert(atomicLoad(context.ran) == 1);
        assert(atomicLoad(context.completed) == 1);
    }

    // A stopped instance can be started again without replacing its address.
    assert(RawCpuPool!(8, 8).start(pool, 1) == RawPoolResult.accepted);
    Context restarted;
    assert(pool.submit(RawJob(&run, &complete, &restarted, 5))
        == RawPoolResult.accepted);
    assert(pool.shutdown(true) == RawPoolResult.accepted);
    assert(pool.pollCompletion(completion) == RawPoolResult.accepted);
    completion.dispatch();
    assert(atomicLoad(restarted.ran) == 1);
    assert(atomicLoad(restarted.completed) == 1);
}

@("rawPool.completionCapacityIsReservedAtSubmission")
@system
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;

    static struct Context
    {
        shared bool entered;
        shared bool release;
    }
    static void block(void* raw) @trusted nothrow @nogc
    {
        auto context = cast(Context*) raw;
        atomicStore(context.entered, true);
        while (!atomicLoad(context.release))
            Thread.yield();
    }
    static void noop(void*) @safe nothrow @nogc {}
    static void complete(void*, bool) @safe nothrow @nogc {}

    RawCpuPool!(4, 1) pool;
    assert(RawCpuPool!(4, 1).start(pool, 1) == RawPoolResult.accepted);
    Context context;
    assert(pool.submit(RawJob(&block, &complete, &context, 1))
        == RawPoolResult.accepted);
    while (!atomicLoad(context.entered))
        Thread.yield();
    assert(pool.submit(RawJob(&noop, &complete, null, 2))
        == RawPoolResult.completionFull);
    assert(pool.submit(RawJob(&noop, null, null, 3))
        == RawPoolResult.accepted);
    atomicStore(context.release, true);
    assert(pool.shutdown(true) == RawPoolResult.accepted);
}

@("rawPool.saturationAndCancellationAreExplicit")
@system
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;

    static struct Context
    {
        shared bool entered;
        shared bool release;
    }
    static void block(void* raw) @trusted nothrow @nogc
    {
        auto context = cast(Context*) raw;
        atomicStore(context.entered, true);
        while (!atomicLoad(context.release))
            Thread.yield();
    }
    static void noop(void*) @safe nothrow @nogc {}
    static void complete(void*, bool) @safe nothrow @nogc {}

    RawCpuPool!(1, 2) pool;
    assert(RawCpuPool!(1, 2).start(pool, 1) == RawPoolResult.accepted);
    Context context;
    assert(pool.submit(RawJob(&block, &complete, &context, 1))
        == RawPoolResult.accepted);
    while (!atomicLoad(context.entered))
        Thread.yield();
    assert(pool.submit(RawJob(&noop, &complete, null, 2))
        == RawPoolResult.accepted);
    assert(pool.submit(RawJob(&noop, null, null, 3))
        == RawPoolResult.queueFull);
    atomicStore(context.release, true);
    assert(pool.shutdown(false) == RawPoolResult.accepted);

    RawCompletion completion;
    bool sawRun;
    bool sawCancelled;
    while (pool.pollCompletion(completion) == RawPoolResult.accepted)
    {
        sawRun |= completion.generation == 1 && !completion.cancelled;
        sawCancelled |= completion.generation == 2 && completion.cancelled;
    }
    assert(sawRun && sawCancelled);
}

@("rawPool.concurrentSubmitAndPollStress")
@system
unittest
{
    import core.atomic : atomicLoad, atomicOp;
    import core.thread : Thread;

    alias Pool = RawCpuPool!(64, 64);
    enum producerCount = 4;
    enum jobsPerProducer = 256;
    enum jobCount = producerCount * jobsPerProducer;

    static struct JobContext
    {
        shared uint ran;
        shared uint completed;
    }
    static void runJob(void* raw) @trusted nothrow @nogc
    {
        auto context = cast(JobContext*) raw;
        atomicOp!"+="(context.ran, 1);
    }
    static void complete(void* raw, bool cancelled) @trusted nothrow @nogc
    {
        assert(!cancelled);
        auto context = cast(JobContext*) raw;
        atomicOp!"+="(context.completed, 1);
    }
    static struct ProducerContext
    {
        Pool* pool;
        JobContext* jobs;
        size_t count;
        shared uint* submitted;
    }
    class Producer
    {
        ProducerContext* context;

        this(ProducerContext* context)
        {
            this.context = context;
        }

        void run()
        {
            foreach (i; 0 .. context.count)
            {
                auto job = RawJob(&runJob, &complete, context.jobs + i, i);
                for (;;)
                {
                    const result = context.pool.submit(job);
                    if (result == RawPoolResult.accepted)
                        break;
                    assert(result == RawPoolResult.queueFull
                        || result == RawPoolResult.completionFull);
                    Thread.yield();
                }
                atomicOp!"+="(*context.submitted, 1);
            }
        }
    }

    Pool pool;
    assert(Pool.start(pool, 4) == RawPoolResult.accepted);
    JobContext[jobCount] jobs;
    ProducerContext[producerCount] producerContexts;
    Producer[producerCount] producers;
    Thread[producerCount] threads;
    shared uint submitted;
    foreach (p; 0 .. producerCount)
    {
        producerContexts[p] = ProducerContext(&pool,
            jobs.ptr + p * jobsPerProducer, jobsPerProducer, &submitted);
        producers[p] = new Producer(&producerContexts[p]);
        threads[p] = new Thread(&producers[p].run);
        threads[p].start();
    }

    size_t completions;
    RawCompletion completion;
    while (atomicLoad(submitted) != jobCount)
    {
        if (pool.pollCompletion(completion) == RawPoolResult.accepted)
        {
            completion.dispatch();
            ++completions;
        }
        else
            Thread.yield();
    }
    foreach (thread; threads)
        thread.join();
    assert(pool.shutdown(true) == RawPoolResult.accepted);
    while (pool.pollCompletion(completion) == RawPoolResult.accepted)
    {
        completion.dispatch();
        ++completions;
    }
    assert(completions == jobCount);
    foreach (ref job; jobs)
    {
        assert(atomicLoad(job.ran) == 1);
        assert(atomicLoad(job.completed) == 1);
    }
}
