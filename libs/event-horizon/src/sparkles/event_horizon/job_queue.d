/**
A bounded queue of background jobs for an interactive host.

An application thread submits jobs, each a class instance it may keep
filling in, and polls between frames for the ones that finished. The queue
starts its `RawCpuPool` on first use, bounds how many jobs are outstanding,
gives each submission a ticket, roots every job until it is published, and
publishes finished jobs in submission order. On shutdown it either drains
the queued jobs or cancels them; a running job always finishes.

A job is any class with `void run() @safe nothrow`, called on a worker.
Optional members, found by introspection:

$(TABLE
$(TR $(TH Member) $(TH Called))
$(TR $(TD `void cancelled() @safe nothrow`) $(TD by `poll`, on the polling thread, for a job shutdown cancelled before it ran))
)

`run` and the polling thread share the job: the queue publishes a job only
after its `run` returned (or it was cancelled), so a field written in `run`
is visible to the poller without further synchronization.
*/
module sparkles.event_horizon.job_queue;

import sparkles.base.expected : Expected, err, ok;
import sparkles.event_horizon.raw_pool : CpuJob, RawCompletion, RawCpuPool, RawPoolResult;

/// One submission's identity: increasing, never zero.
struct JobTicket
{
    ulong value; ///
}

/// Why `submit` refused a job.
enum SubmitRefusal : ubyte
{
    stopped,     /// `shutdown` has run
    full,        /// `capacity` jobs are outstanding
    exhausted,   /// the ticket counter is spent
    startFailed, /// the worker threads could not start
    rejected,    /// the pool refused the job
}

/// What `shutdown` does with jobs that have not started.
enum Drain : bool
{
    cancel = false, /// publish them cancelled, without running them
    run = true,     /// run them before the workers stop
}

/// Whether `Job` can be queued: a class with `void run() @safe nothrow`.
enum isQueueJob(Job) = is(Job == class) && __traits(compiles, (Job j) @safe nothrow { j.run(); });

/**
Outstanding jobs of type `Job`, at most `capacity`, run by `workers` threads.
Owned by one thread, which submits, polls and shuts down; the caller keeps
the queue alive through `shutdown`.
*/
final class JobQueue(Job, size_t capacity = 8, uint workers = 1)
if (isQueueJob!Job && capacity > 0 && workers > 0)
{
    private alias Pool = RawCpuPool!(capacity, capacity, CpuJob);

    private static final class Entry
    {
        Job job;
        JobTicket ticket;
        bool done, cancelled;
    }

    private Pool pool;
    private Entry[] entries;
    private ulong lastTicket;
    private bool started_, stopped_;

    /// Starts the workers now rather than on the first `submit`. Idempotent;
    /// false once the start has failed or after `shutdown`.
    bool start() @safe nothrow
    {
        if (started_) return true;
        if (stopped_) return false;
        started_ = Pool.start(pool, workers) == RawPoolResult.accepted;
        return started_;
    }

    /// Queues `job` and returns its ticket.
    Expected!(JobTicket, SubmitRefusal) submit(Job job) @safe nothrow
    in (job !is null)
    {
        if (stopped_) return err!JobTicket(SubmitRefusal.stopped);
        if (entries.length == capacity) return err!JobTicket(SubmitRefusal.full);
        if (lastTicket == ulong.max) return err!JobTicket(SubmitRefusal.exhausted);
        if (!start()) return err!JobTicket(SubmitRefusal.startFailed);
        auto entry = new Entry;
        entry.job = job;
        entry.ticket = JobTicket(lastTicket + 1);
        // Rooted before the pool sees its address.
        entries ~= entry;
        const queued = pool.submit(CpuJob(&work, &completed,
            (() @trusted => cast(void*) entry)(), entry.ticket.value));
        if (queued != RawPoolResult.accepted)
        {
            entries.length -= 1;
            return err!JobTicket(SubmitRefusal.rejected);
        }
        lastTicket = entry.ticket.value;
        return ok!SubmitRefusal(entry.ticket);
    }

    /// Finished jobs, in submission order, each published once. A job
    /// cancelled by `shutdown` is among them, after its `cancelled` hook.
    Job[] poll() @safe nothrow
    {
        if (started_)
        {
            RawCompletion completion;
            while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        }
        Job[] finished;
        size_t kept;
        foreach (entry; entries)
        {
            if (!entry.done) { entries[kept++] = entry; continue; }
            static if (__traits(hasMember, Job, "cancelled"))
                if (entry.cancelled) entry.job.cancelled();
            finished ~= entry.job;
        }
        if (kept != entries.length)
        {
            entries[kept .. $] = null;
            entries.length = kept;
        }
        return finished;
    }

    /// The ticket of an outstanding job, or none.
    JobTicket ticketOf(scope const Job job) const @safe pure nothrow @nogc
    {
        foreach (entry; entries)
            if (entry.job is job) return entry.ticket;
        return JobTicket.init;
    }

    /// The ticket the next accepted `submit` returns, for a job that records
    /// its own before the worker can see it.
    JobTicket nextTicket() const @safe pure nothrow @nogc => JobTicket(lastTicket + 1);

    /// Jobs submitted and not yet published by `poll`.
    size_t outstanding() const @safe pure nothrow @nogc => entries.length;
    /// Whether any job is outstanding.
    bool busy() const @safe pure nothrow @nogc => entries.length != 0;
    /// Whether the workers have started.
    bool started() const @safe pure nothrow @nogc => started_;
    /// Whether `shutdown` has run.
    bool stopped() const @safe pure nothrow @nogc => stopped_;

    /**
    Refuses further submissions and stops the workers, running or cancelling
    the jobs not yet started, as `drain` says, and waiting for running ones.
    Idempotent. The finished and cancelled jobs stay outstanding until the
    next `poll` publishes them.
    */
    void shutdown(Drain drain) @safe nothrow
    {
        if (stopped_) return;
        stopped_ = true;
        if (!started_) return;
        (() @trusted => pool.shutdown(drain))();
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
    }

    private static void work(void* raw) @safe nothrow
    {
        auto entry = (() @trusted => cast(Entry) raw)();
        entry.job.run();
    }

    private static void completed(void* raw, bool cancelled) @safe nothrow @nogc
    {
        auto entry = (() @trusted => cast(Entry) raw)();
        entry.cancelled = cancelled;
        entry.done = true;
    }
}

/// Jobs run on a worker and come back in submission order with their results.
@("jobQueue.submitPollInOrder")
@safe unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, seconds;

    static final class Square
    {
        int input, output;
        this(int input) @safe pure nothrow { this.input = input; }
        void run() @safe nothrow { output = input * input; }
    }

    auto queue = new JobQueue!(Square, 4);
    scope (exit) queue.shutdown(Drain.run);
    assert(!queue.started, "the workers start on first use");
    JobTicket[3] tickets;
    foreach (i; 0 .. 3)
        tickets[i] = queue.submit(new Square(i + 2)).value;
    assert(tickets[0].value == 1 && tickets[1].value == 2 && tickets[2].value == 3);
    assert(queue.nextTicket.value == 4);
    Square[] done;
    const deadline = MonoTime.currTime + 3.seconds;
    while (done.length < 3 && MonoTime.currTime < deadline)
    {
        done ~= queue.poll();
        (() @trusted => Thread.yield())();
    }
    assert(done.length == 3 && !queue.busy);
    assert(done[0].output == 4 && done[1].output == 9 && done[2].output == 16);
}

/// The bound counts jobs until they are polled, not until they run.
@("jobQueue.boundAndShutdown")
@safe unittest
{
    static final class Nothing
    {
        void run() @safe nothrow {}
    }

    auto queue = new JobQueue!(Nothing, 2);
    assert(queue.submit(new Nothing).hasValue && queue.submit(new Nothing).hasValue);
    assert(queue.submit(new Nothing).error == SubmitRefusal.full);
    queue.shutdown(Drain.run);
    assert(queue.submit(new Nothing).error == SubmitRefusal.stopped);
    assert(queue.poll().length == 2 && !queue.busy, "drained jobs are published after shutdown");
    assert(queue.poll().length == 0);
}

/// Cancelling shutdown publishes queued jobs through their `cancelled` hook;
/// the running job finishes.
@("jobQueue.cancelQueuedOnShutdown")
@system unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : msecs;

    static shared bool entered, release;
    static final class Step
    {
        bool blocks, ran, wasCancelled;
        this(bool blocks) @safe pure nothrow { this.blocks = blocks; }
        void run() @trusted nothrow
        {
            if (blocks)
            {
                atomicStore(entered, true);
                while (!atomicLoad(release)) Thread.yield();
            }
            ran = true;
        }
        void cancelled() @safe nothrow { wasCancelled = true; }
    }

    auto queue = new JobQueue!(Step, 4);
    auto first = new Step(true), second = new Step(false), third = new Step(false);
    assert(queue.submit(first).hasValue && queue.submit(second).hasValue && queue.submit(third).hasValue);
    while (!atomicLoad(entered)) Thread.yield();
    auto releaser = new Thread({ Thread.sleep(50.msecs); atomicStore(release, true); });
    releaser.start();
    queue.shutdown(Drain.cancel);
    releaser.join();
    auto published = queue.poll();
    assert(published.length == 3 && published[0] is first && published[2] is third);
    assert(first.ran && !first.wasCancelled);
    assert(!second.ran && second.wasCancelled && !third.ran && third.wasCancelled);
}
