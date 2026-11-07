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

Run it from a fiber of `exec`. The budget may be shared with schemes and
other work (FSS6); a budget of one makes the resolution sequential.
*/
module sparkles.build_primitives.fileset.driver_loop;

import sparkles.event_horizon.admission : Admission;
import sparkles.event_horizon.capability : SpawnOptions, isFiberExecutor;

import sparkles.build_primitives.fileset.machine : Request;

/// Runs a batch's requests concurrently on fibers of `X`, admitted by a
/// shared budget.
struct LoopExecutor(X)
if (isFiberExecutor!X)
{
    X* exec;            /// the scheduler whose fiber runs `resolve`
    Admission* budget;  /// in-flight operations, shared (FSS6)
    uint peak;          /// the most requests in flight at once, for tests
    private uint running;

    /// Calls `perform(i)` for each request `i` of `batch` on a fiber of
    /// its own, at most `budget` at once, and returns when all are done.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        const n = batch.length;
        if (n == 0)
            return;
        auto done = new Admission(cast(uint) n, cast(uint) n);
        // The fibers outlive no frame of this call: it waits for them all.
        auto work = (() @trusted => cast(Perform*) &perform)();
        // One call per request, so each fiber's closure holds its own `i`.
        void spawnOne(size_t i)
        {
            const spawned = exec.spawnFiber(null, SpawnOptions.init, () {
                if (!budget.acquire(*exec).hasError)
                {
                    if (++running > peak)
                        peak = running;
                    (*work)(i);
                    --running;
                    budget.release();
                }
                done.release();
            });
            if (spawned is null)
            {
                // No fiber left: perform it here.
                (*work)(i);
                done.release();
            }
        }
        foreach (i; 0 .. n)
            spawnOne(i);
        cast(void) done.acquire(*exec, cast(uint) n);
    }
}
