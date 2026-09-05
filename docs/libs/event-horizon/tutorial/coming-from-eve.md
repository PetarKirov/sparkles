# Coming from EVE

EVE separates OS backends, its callback loop, asynchronous I/O, and optional
runtime facilities such as fibers and futures. The useful migration question is
where execution and resource ownership move—not whether one library has “real
async” and the other does not.

This guide uses the [EVE source baseline][eve] at
`c72f75135de636987e91bcd8ec5a22d32d34a197`. Its README lists Linux
`io_uring`/`epoll`/`poll` and Windows IOCP/WSAPoll; it marks macOS/BSD kqueue
support as planned. EVE is not a readiness-only library with working kqueue support.

## Map the execution model

| In EVE                                   | In Event Horizon                                 | Migration decision                                                      |
| ---------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------- |
| Select a backend and runtime layer       | Start `LoopGroup`, receive `RootScope` and `Env` | Keep the owning loop explicit; the default topology is single-threaded. |
| Register timer callbacks                 | Call `env.clock.sleep` in a fiber                | Sequential code resumes after the wait; check its result.               |
| Launch runtime fibers or wait on futures | Fork scoped children and join `JoinHandle!T`     | A scope joins its children before returning.                            |
| Coordinate producers and consumers       | Use `Channel!(T, capacity)`                      | These channels are scheduler-local, not cross-thread queues.            |
| Cancel an operation or task              | Use a deadline or cancel the owning scope        | Cancellation is cooperative; protect only cleanup that must finish.     |

The baseline's [future implementation][future] supports several callback-delivery
policies. Do not replace a future wait with a thread-blocking wait inside an
Event Horizon fiber: that would stall the loop's other fibers too.

## Join two operations

The two children below run concurrently on one scheduler. Each returns `IoResult!int`;
joining yields an `Outcome!int`, which also represents scope cancellation and defects.

<<< @/libs/event-horizon/tutorial/snippets/eh_concurrency.d [event-horizon]

```ansi
joined: 12
```

## Add bounded communication

A full channel parks the producer fiber. Closing it lets buffered values drain
before reads return `EPIPE`. Other errors must not be mistaken for normal EOF.

<<< @/libs/event-horizon/tutorial/snippets/eh_channel.d [event-horizon]

```ansi
consumed: 15
```

These are Event Horizon programs, not programs that depend on EVE. See
[Running the examples](./running-examples.md) for Linux prerequisites, commands,
deadlines, and the difference between I/O errors and scope outcomes. This is a
source-based comparison, not a cross-platform benchmark.

<!-- References -->

[eve]: https://codeberg.org/ddn/eve/src/commit/c72f75135de636987e91bcd8ec5a22d32d34a197/README.md
[future]: https://codeberg.org/ddn/eve/src/commit/c72f75135de636987e91bcd8ec5a22d32d34a197/src/eve/rt/future.d
