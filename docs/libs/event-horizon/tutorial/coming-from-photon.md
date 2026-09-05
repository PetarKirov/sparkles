# Coming from Photon

Photon makes concurrent D code look synchronous through fibers and intercepted
I/O calls. Event Horizon also offers direct-style fibers, but its examples use
explicit I/O capabilities and scopes instead of ambient syscall interception.

This guide uses [Photon][photon] at
`4cb737aa38bcde87ca400d1df3b092ad38655ad5`. Its README explains the distinction
between blocking, asynchronous, and pseudo-blocking I/O and demonstrates
`initPhoton`, `go`, and `runScheduler` as the entry point.

## Map scheduling and ownership separately

| Photon idiom                  | Event Horizon idiom                      | Migration decision                                               |
| ----------------------------- | ---------------------------------------- | ---------------------------------------------------------------- |
| `initPhoton` / `runScheduler` | `LoopGroup.start` / `group.run`          | Choose an explicit loop topology; default is single-threaded.    |
| `go`                          | `sc.spawn` or `sc.fork`                  | Give every child a scope that joins it.                          |
| Fiber-aware waiting           | `env.clock.sleep` and explicit I/O verbs | Ordinary blocking calls do not automatically become cooperative. |
| Task coordination             | `JoinHandle!T`, `Outcome!T`              | Keep typed results and inspect cancellation/failure.             |
| Channels                      | `Channel!(T, capacity)`                  | Event Horizon channels are scheduler-local, not M:N queues.      |
| Blocking integration          | An appropriate worker-pool boundary      | A fiber alone does not make a blocking call safe for the loop.   |

Do not carry over an assumption that `Thread.sleep` or an arbitrary C library
will yield your Event Horizon fiber. Use the clock capability for delays and
explicitly offload work that cannot run on the loop thread.

## Join two children

Both operations start before either join, but the scope cannot finish while a
child remains active. This makes ownership visible at the call site.

<<< @/libs/event-horizon/tutorial/snippets/eh_concurrency.d [event-horizon]

```ansi
joined: 12
```

## Compose retries without blocking the thread

Retry timing comes from the clock capability. The example uses `EAGAIN`, checks
its outcome, and succeeds on the third attempt; it does not sleep an OS worker
between attempts.

<<< @/libs/event-horizon/tutorial/snippets/eh_retry.d [event-horizon]

```ansi
succeeded on attempt 3
```

## What does not transfer automatically

Neither fibers nor io_uring imply zero-copy networking. Buffer moves express
operation ownership; TCP still permits partial sends and receives. Nor is a
scope a preemptive deadline: CPU-bound code needs cooperative checkpoints.

Use [Running the examples](./running-examples.md) for Linux prerequisites,
partial-I/O handling, and process supervision. These examples validate Event
Horizon behavior; this page is not a benchmark or a Photon compatibility suite.

<!-- References -->

[photon]: https://github.com/DmitryOlshansky/photon/blob/4cb737aa38bcde87ca400d1df3b092ad38655ad5/README.md
