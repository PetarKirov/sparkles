/**
Capability seams (SPEC §10). $(B Effects-side module): imports only `cause`
— never ring, loop, or scheduler code.

M5 ships the executor seam that `scope_` drives; the full capability-row
machinery (`Ctx`, `hasCaps`, `isWaker`) lands with M6.
*/
module sparkles.event_horizon.capability;

import core.time : Duration;

import sparkles.event_horizon.cause : CancelContext, FiberContext;

/// Per-spawn options.
struct SpawnOptions
{
    bool daemon = false; /// daemons don't keep their scope alive (SPEC §8.1)
}

/**
The fiber-executor concept (SPEC §10.3) — the exact expressions `scope_`
drives; the live implementation is `Sched`, and a mock makes every scope
semantic unit-testable with no ring:

$(LIST
    $(ITEM `currentContext()` — the running fiber's context (asserts off-fiber))
    $(ITEM `spawnFiber(node, opts, dg)` — child bound to `node`; enqueued,
        not run inline; `null` = slab exhausted)
    $(ITEM `park()` — suspend the current fiber until exactly one `wake`)
    $(ITEM `wake(f)` — make a parked fiber runnable (same-worker))
)
*/
enum bool isFiberExecutor(X) = __traits(compiles, (ref X x, CancelContext* cc) {
    FiberContext* cur = x.currentContext();
    FiberContext* child = x.spawnFiber(cc, SpawnOptions.init, delegate void() {});
    x.park();
    x.wake(child);
});

/**
Optional deadline-timer primitive (gates `withDeadline`, SPEC §8.3): arms a
one-shot timer whose expiry cancels `node`'s subtree; the token disarms it.
On `Sched` this is an in-ring `TIMEOUT`.
*/
enum bool hasDeadlineTimer(X) = __traits(compiles, (ref X x, CancelContext* cc) {
    ulong t = x.armDeadline(cc, Duration.zero);
    x.disarmDeadline(t);
});
