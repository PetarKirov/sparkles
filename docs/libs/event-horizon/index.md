# `sparkles:event-horizon`

`sparkles:event-horizon` is a completion-first event loop for D: `io_uring` on
Linux, `kqueue` on macOS and the BSDs, IOCP on Windows (in progress), driven
in three tiers — a callback loop, direct-style fibers with structured
concurrency, and an `Effect!T` veneer — with process supervision, channels,
retry schedules and a bounded pool for the few host calls a completion
backend cannot express.

Use it when a program has to wait on many things at once — sockets, files,
timers, child processes, signals — and you want that waiting to read as
ordinary sequential code, with cancellation, timeouts and cleanup that
cannot be forgotten.

```d
import sparkles.event_horizon;
import core.time : msecs;

LoopGroup group;
if (LoopGroup.start(group).hasError)
    assert(false, "no completion backend");
scope (exit) group.shutdown();

auto outcome = group.run((ref RootScope sc, ref Env env) {
    cast(void) env.clock.sleep(10.msecs); // parks the fiber, not the thread
    return 42;
});
assert(outcome.value == 42);
```

## How this documentation is organised

These docs follow the [Diátaxis](https://diataxis.fr/) framework.

### Tutorial

_Learning-oriented._

- [Coming from Node.js](./tutorial/coming-from-nodejs.md) — the event loop
  you already know, mapped concept by concept onto fibers, scopes, channels
  and supervised processes, with runnable programs for each.
- [Coming from eventcore](./tutorial/coming-from-eventcore.md) — proactor
  drivers, callbacks, and handle ownership mapped to scoped fibers and I/O results.
- [Coming from vibe-core](./tutorial/coming-from-vibe-core.md) — direct-style
  fibers and task handles mapped to explicit scope ownership and cancellation.
- [Coming from libasync](./tutorial/coming-from-libasync.md) — comparing
  callback I/O, file workers, and cross-thread notifications with scoped I/O.
- [Coming from Photon](./tutorial/coming-from-photon.md) — comparing
  Photon's syscall interception and fibers with explicit capabilities and scopes.
- [Coming from collie](./tutorial/coming-from-collie.md) — Netty/Finagle-style
  channel pipelines and readiness loops compared with completion-first fibers,
  move-only buffers, and structured concurrency.
- [Coming from hunt-net](./tutorial/coming-from-hunt-net.md) — Java/Netty/Vert.x-inspired
  asynchronous networking, codecs, and connection handlers mapped to stream primitives.
- [Coming from EVE](./tutorial/coming-from-eve.md) — layered backends and runtime
  facilities mapped to scoped fibers, outcomes, and bounded channels.
- [Running the examples](./tutorial/running-examples.md) — Linux prerequisites,
  executable shared examples, partial I/O, error handling, and support boundaries.

### Reference

_Information-oriented._ The normative surface lives in the specification for
now: [SPEC.md](../../specs/event-horizon/SPEC.md) (public API in §16) and the
delivery status in [PLAN.md](../../specs/event-horizon/PLAN.md).

### Explanation

_Understanding-oriented._ The research behind the design:
[Async I/O & Event Loops](../../research/async-io/index.md) and
[Process Supervision](../../research/async-io/process-supervision.md).
