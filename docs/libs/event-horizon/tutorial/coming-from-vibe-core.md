# Coming from vibe-core

The direct-style part should feel familiar: vibe-core already uses fibers so
network and file waits can read like sequential code. The migration is primarily
about task ownership, explicit results, and buffer lifetime.

This guide uses [vibe-core][vibe] at
`f0e8795495affd0d517b335e70c6f7139a6a9f5b`, whose facilities include fiber-based
tasks, I/O, timers, and synchronization. Its [task implementation][task] includes
joining; describing all vibe-core tasks as necessarily detached would be misleading.

## Map the lifetime boundary

| vibe-core idiom                      | Event Horizon idiom                  | What to review                                               |
| ------------------------------------ | ------------------------------------ | ------------------------------------------------------------ |
| Launch a task and retain its handle  | `sc.fork(handle, body)`              | Choose the lexical scope that owns the child.                |
| Join a task                          | `handle.join(s)`                     | Inspect the typed outcome before accessing its value.        |
| Fiber-aware sleep                    | `env.clock.sleep`                    | Handle cancellation as an I/O result.                        |
| Task interruption or timeout         | `withDeadline`, `Scope.cancel`       | A deadline joins children; it cannot preempt CPU-bound code. |
| Synchronization and message passing  | Scoped children and bounded channels | Event Horizon channels stay on their owning scheduler.       |
| Streams and exception-based failures | Owned buffer verbs and `IoResult!T`  | Ordinary I/O errors are values; defects still exist.         |

`LoopGroup` defaults to one loop on the calling thread. A multi-worker topology
is a separate choice, not an automatic effect of using a group.

## Join concurrent work

Both child operations start before either join. A child returns `IoResult!int`;
the join and enclosing scope return outcomes that also account for scope failure.

<<< @/libs/event-horizon/tutorial/snippets/eh_concurrency.d [event-horizon]

```ansi
joined: 12
```

## Put a deadline around a lifetime

The interrupted sleep and the enclosing deadline have different result types.
`protect` shields a small cleanup section, not the whole application.

<<< @/libs/event-horizon/tutorial/snippets/eh_deadline.d [event-horizon]

```ansi
sleep returned: ECANCELED
timed out: true
cleaned up: true
```

Keep a connection, its buffers, and its cleanup within one runtime while porting.
Do not call blocking third-party work on the loop thread just because the caller
is a fiber. Nor should every mutex become a channel mechanically: first decide
whether the state can remain local to one scheduler.

The [example guide](./running-examples.md) covers backpressure, process
supervision, signals, and Linux validation. The [specification][spec] defines
scope contracts; changing runtimes does not remove every allocation or race.

<!-- References -->

[vibe]: https://github.com/vibe-d/vibe-core/blob/f0e8795495affd0d517b335e70c6f7139a6a9f5b/README.md
[task]: https://github.com/vibe-d/vibe-core/blob/f0e8795495affd0d517b335e70c6f7139a6a9f5b/source/vibe/core/task.d
[spec]: ../../../specs/event-horizon/SPEC.md
