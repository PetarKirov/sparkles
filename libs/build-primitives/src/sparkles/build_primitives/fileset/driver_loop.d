/**
The `sparkles:event-horizon` executor of the fileset driver (FSD1, FSS6).

`LoopExecutor` runs each batch's requests on fibers of the calling
scheduler, every one admitted by one shared `Admission` budget of in-flight
operations, and returns when the whole batch is answered. Over `RingVfs`
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

    /// Calls `perform(i)` for each request `i` of `batch` on a fiber of
    /// its own, at most `budget` at once, and returns when all are done.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        const n = batch.length;
        if (n == 0)
            return;
        // The fibers outlive no frame of this call: it waits for them all,
        // and an interrupt does not end the wait, since they use `perform`
        // and the resolution behind it until they finish.
        auto work = (() @trusted => cast(Perform*) &perform)();
        size_t left = n;
        FiberContext* waiter;
        // Annotated: inference does not reach it through `spawnOne`'s closure.
        void finishOne() @safe
        {
            if (--left == 0 && waiter !is null)
            {
                auto w = waiter;
                waiter = null;
                exec.wake(w);
            }
        }
        // One call per request, so each fiber's closure holds its own `i`.
        void spawnOne(size_t i)
        {
            const spawned = exec.spawnFiber(null, SpawnOptions.init, () {
                admitted(() { (*work)(i); });
                finishOne();
            });
            if (spawned is null)
            {
                // No fiber left: perform it here, still within the budget.
                admitted(() { (*work)(i); });
                finishOne();
            }
        }
        foreach (i; 0 .. n)
            spawnOne(i);
        while (left)
        {
            waiter = exec.currentContext();
            exec.park();
        }
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
            admitted(held[0]);
            finished();
        });
        if (spawned is null)
        {
            admitted(work);
            finished();
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
        if (budget.acquire(*exec).hasError)
            return;
        if (++running > peak)
            peak = running;
        work();
        --running;
        budget.release();
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
