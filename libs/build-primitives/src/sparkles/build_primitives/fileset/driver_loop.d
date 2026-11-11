/**
The `sparkles:event-horizon` executor of the fileset driver (FSD1, FSS6).

`LoopExecutor` runs each batch's requests on fibers of the calling
scheduler, every one admitted by one shared `Admission` budget of in-flight
operations, and returns when the whole batch is answered. A batch is shared
by as many workers as can run at once, so a batch larger than the budget or
the scheduler's free fibers still proceeds at the budget. Over `RingVfs`
each request's blocking call moves to the blocking pool and parks only its
own fiber, so a directory's stats, or its subdirectories' listings, proceed
together while the loop keeps running. The machine stays deterministic:
answers carry their request's index, and nothing is consumed until the batch
is complete.

A scheme's own work goes through the same budget: `spawn` runs it on a fiber
of its own once the budget admits it, so a scheme reading a large file holds
back the walk instead of racing it (FSS6), and `join` waits for all of it
(FSS7).

Run it from a fiber of `exec`. The budget may be shared with other work; a
budget of one makes the resolution sequential.
*/
module sparkles.build_primitives.fileset.driver_loop;

import sparkles.event_horizon.admission : Admission;
import sparkles.event_horizon.capability : SpawnOptions, isFiberExecutor;
import sparkles.event_horizon.cause : FiberContext;

import sparkles.build_primitives.fileset.machine : Request;

/// Runs a batch's requests, and a scheme's work, concurrently on fibers of
/// `X`, admitted by a shared budget.
struct LoopExecutor(X)
if (isFiberExecutor!X)
{
    X* exec;            /// the scheduler whose fiber runs `resolve`
    Admission* budget;  /// in-flight operations, shared (FSS6)
    uint peak;          /// the most operations in flight at once, for tests
    private uint running;
    private uint outstanding;    // spawned work not yet finished
    private FiberContext* joiner; // the fiber parked in `join`

    /// Calls `perform(i)` for each request `i` of `batch`, at most `budget`
    /// at once, and returns when all are done. The requests are shared by
    /// as many workers, each a fiber, as can run at once: no more than the
    /// batch holds, the budget admits, or the scheduler has fibers free.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        const n = batch.length;
        if (n == 0)
            return;
        // The fibers outlive no frame of this call: it waits for them all,
        // and an interrupt does not end the wait, since they use `perform`
        // and the resolution behind it until they finish.
        auto work = (() @trusted => cast(Perform*) &perform)();
        size_t next; // the first request no worker has taken
        // Fibers switch only where one parks, so taking `next` needs no lock.
        void drain()
        {
            while (next < n)
            {
                const i = next++;
                admitted(() { (*work)(i); });
            }
        }
        const workers = workersFor(n);
        size_t left; // workers started and not yet finished
        FiberContext* waiter;
        // Annotated: inference does not reach it through the workers' closure.
        void finishOne() @safe
        {
            if (--left == 0 && waiter !is null)
            {
                auto w = waiter;
                waiter = null;
                exec.wake(w);
            }
        }
        // However this frame ends, even by a `perform` throwing on this
        // fiber, it waits for the workers started, which still use it.
        scope (exit)
            while (left)
            {
                waiter = exec.currentContext();
                exec.park();
            }
        foreach (_; 0 .. workers)
        {
            ++left;
            const spawned = exec.spawnFiber(null, SpawnOptions.init, () {
                scope (exit) finishOne();
                drain();
            });
            if (spawned is null)
            {
                // No fiber after all: this one works, still within the budget.
                scope (exit) finishOne();
                drain();
            }
        }
    }

    /// Whether the budget refused work: an `acquire` failed, because the
    /// fiber asking was interrupted or the budget closed, so a request went
    /// unanswered or spawned work never ran. A resolution then fails with
    /// `ResolutionErrorCode.notAdmitted` (FSS6).
    bool refused() const @safe pure nothrow @nogc => refusal != 0;

    /// The error code of the first refusal, `0` for none.
    int refusal;

    // The workers a batch of `n` requests gets. More than the budget admits
    // would only wait for it, and a fiber the scheduler has no room for
    // would not start; at least one, which may be the calling fiber.
    private size_t workersFor(size_t n) const
    {
        size_t w = n;
        if (budget.capacity < w)
            w = budget.capacity;
        static if (__traits(compiles, exec.maxFibers - exec.liveFibers))
        {
            const free = exec.maxFibers - exec.liveFibers;
            if (free < w)
                w = free;
        }
        return w ? w : 1;
    }

    /// Runs `work` on a fiber of its own once the budget admits it; `join`
    /// waits for it (FSS7).
    void spawn(void delegate() work)
    {
        // `work` runs after its creator returns, so its context must live on
        // the heap. Capturing it in a closure is no escape to dip1000's
        // inference, which would make the parameter `scope` and let a caller
        // pass a closure allocated on its own stack; storing it is one.
        auto held = new void delegate()[1];
        held[0] = work;
        ++outstanding;
        const spawned = exec.spawnFiber(null, SpawnOptions.init, () {
            scope (exit) finished();
            admitted(held[0]);
        });
        if (spawned is null)
        {
            scope (exit) finished();
            admitted(work);
        }
    }

    /// Returns once all spawned work has run.
    void join()
    {
        while (outstanding)
        {
            joiner = exec.currentContext();
            exec.park();
        }
    }

    // A template, so a `@safe` caller's work keeps it `@safe`.
    private void admitted(Work)(scope Work work)
    {
        if (refusal)
            return; // the resolution fails anyway: start nothing more
        auto got = budget.acquire(*exec);
        if (got.hasError)
        {
            refusal = got.error.code;
            return;
        }
        if (++running > peak)
            peak = running;
        scope (exit)
        {
            --running;
            budget.release();
        }
        work();
    }

    private void finished()
    {
        if (--outstanding == 0 && joiner !is null)
        {
            auto j = joiner;
            joiner = null;
            exec.wake(j);
        }
    }
}
