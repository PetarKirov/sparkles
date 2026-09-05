# Coming from eventcore

If you use `eventDriver`, typed descriptor handles, and completion callbacks,
you already know the lower-level responsibilities of an event loop. Event Horizon
offers a callback layer too, but these examples use its fiber layer to keep the
continuation in ordinary sequential code.

The [eventcore baseline][eventcore] is
`ced22593f38dd9b4514aff58a390ce313e62d283`. Its driver matrix includes epoll,
kqueue, WinAPI, and an experimental io_uring driver. It is a callback-based
abstraction, not simply “readiness pretending to be completion.” Supported
operations vary by backend in both libraries.

## Map ownership before syntax

| eventcore concept                | Event Horizon counterpart                     | What changes                                                     |
| -------------------------------- | --------------------------------------------- | ---------------------------------------------------------------- |
| `eventDriver.core.processEvents` | `LoopGroup.run`                               | The group owns dispatch while the root scope runs.               |
| Typed handles and callbacks      | `Stream`, `FileHandle`, direct-style verbs    | A waiting fiber carries the continuation and local state.        |
| `eventDriver.timers`             | `env.clock.sleep`, `Ticker`                   | Check a returned result instead of updating state in a callback. |
| Handle reference management      | Explicit handle cleanup and owned I/O buffers | Moving a buffer does not make TCP message-oriented.              |
| Operation-specific result enums  | `IoResult!T`                                  | Failure includes errno, operation, and stage.                    |
| A higher-level task abstraction  | `withScope`, `fork`, `join`                   | Child lifetime and cancellation belong to an explicit scope.     |

Do not mix a handle created by one driver with another runtime's I/O verbs.
Move ownership of a complete connection or subsystem, including its shutdown path.

## Replace timer continuations

This program parks the calling fiber between ticks. Use `Ticker` instead when
you need an absolute cadence with missed ticks coalesced rather than a delay
after each iteration.

<<< @/libs/event-horizon/tutorial/snippets/eh_timers.d [event-horizon]

```ansi
tick 1
tick 2
tick 3
```

## Keep the file alive through completion

The file example creates an isolated temporary fixture, reads it to EOF, and
closes it before removing the fixture. Inspect the completion result before
reading the returned buffer's bytes.

<<< @/libs/event-horizon/tutorial/snippets/eh_file_read.d [event-horizon]

```ansi
read 18 bytes: hello from a file

```

Event Horizon's Linux io_uring path submits operations to the kernel. Its kqueue
backend adapts readiness to the completion interface; kqueue is not an SQ/CQ
ring. Neither a completion API nor moving a buffer implies zero-copy I/O.

See [Running the examples](./running-examples.md) for platform limits and
[the specification](../../../specs/event-horizon/SPEC.md) for exact contracts.

<!-- References -->

[eventcore]: https://github.com/vibe-d/eventcore/blob/ced22593f38dd9b4514aff58a390ce313e62d283/README.md
