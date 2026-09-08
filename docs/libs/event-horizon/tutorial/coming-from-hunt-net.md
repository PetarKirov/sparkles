# Coming from hunt-net

Hunt-net's [README examples][hunt] configure a server or client, install a
`TextLineCodec`, and handle decoded messages through
`AbstractNetConnectionHandler.messageReceived`. Event Horizon exposes the stream
and scope primitives below that framework level.

This comparison uses revision `81fd38deebe6a5ec093ef9e86770cd0dce22b355`.
It is a source-based migration guide, not a claim of feature or performance parity.

<!-- verified-comparisons -->

> [!NOTE]
> Each source tab imports a complete single-file DUB program. Run it with
> `dub run --single <file> -b checked`; assertions stay enabled. Each labelled
> output belongs to the immediately preceding implementation and is independently
> checked by `ci --verify`. See [Running the examples](./running-examples.md)
> for prerequisites, dependency versions and the validation command.

## Keep the codec boundary explicit

| hunt-net idiom                          | Event Horizon approach                     | Important difference                                          |
| --------------------------------------- | ------------------------------------------ | ------------------------------------------------------------- |
| `NetUtil.createNetServer` and `.listen` | `env.net.listen`, then `accept`            | Give each accepted connection an owning scope or child fiber. |
| `TextLineCodec`                         | An incremental decoder over received bytes | TCP can split or combine application messages.                |
| `messageReceived`                       | Resume the waiting receive fiber           | Local variables can hold per-connection parser state.         |
| `connection.write`                      | `send(move(buf))`                          | Loop over partial sends; do not reuse an in-flight buffer.    |
| Server/client lifecycle callbacks       | Scope lifetime and explicit close          | Cancellation and cleanup need a deliberate policy.            |

The process supervisor's `LineFramer` contract does not make every socket a line
stream. Decide whether to reuse a compatible framing primitive or retain your
existing protocol codec when porting a service.

```mermaid
flowchart LR
  start[Start operation] --> pending[Retain state and buffers]
  pending --> result[Observe result]
  result --> cleanup[Close resources and join work]
  cleanup --> return_[Return to caller]
```

The lifecycle is common; the mechanism is not. Callback registrations need an
explicit owner and terminal path. Fibers make sequential control flow possible,
but still need cancellation and lifetime rules. A lexical scope is useful when
it actually owns the work being started.

## Timers and cadence

The contract is three timer deliveries in order, followed by termination of the
loop or task. The assertions check the count; they do not claim exact timing.
The event-horizon program uses relative sleeps, not `Ticker`: work between
sleeps shifts the next deadline. For absolute cadence, maintain an absolute
next deadline and define how missed ticks are skipped. Cancelling a timer
registration and interrupting the fiber waiting on it are different operations.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_timers.d [hunt-net]

```ansi [hunt-net output]
tick 1
tick 2
tick 3
```

<<< @/libs/event-horizon/tutorial/snippets/eh_timers.d [event-horizon]

```ansi [event-horizon output]
tick 1
tick 2
tick 3
```

:::

## Concurrency and joined lifetime

Hunt's tab wraps an explicit Phobos worker arrangement in a Hunt `Task`, checks
its final state and joins the OS thread. This is an application adapter; it
does not turn `Task.stop()` into preemptive interruption or structured joining.

Start independent work, combine the two results as `1 * 10 + 2`, and do not
return until the work is complete. Event Horizon's ready/release handshake
proves both children have started before either can finish. This is concurrency,
not proof of CPU parallelism.

On the foreign side, keep callback state or task handles alive through completion.
A lexical D block alone does not join asynchronous work. On the event-horizon
side, the nested scope owns that lifetime and the join handles carry outcomes.
Decide separately what failure of one child should do to its siblings; successful
joining alone does not establish fail-fast cancellation semantics.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_concurrency.d [hunt-net]

```ansi [hunt-net output]
joined: 12
```

<<< @/libs/event-horizon/tutorial/snippets/eh_concurrency.d [event-horizon]

```ansi [event-horizon output]
joined: 12
```

:::

## Cancellation, deadlines and cleanup

The Hunt tab demonstrates a condition-variable timeout inside an explicitly
joined Hunt Task. The condition returns false: no kernel operation returns
`ECANCELED`, and no child task has been interrupted. The printed adapter status
is deliberately different from event-horizon's cancellation result.

The examples distinguish timeout detection from successful completion and
assert that cleanup ran. Read the foreign operation's interruption mechanism
carefully: cancelling a registration, signalling a flag and interrupting a
fiber are not interchangeable. A timeout on a wait does not necessarily stop
the operation being waited for.

Event Horizon's deadline latches cooperative cancellation. The parked sleep
returns `ECANCELED`; `protect` lets cleanup cross checkpoints even with that
latch set. Keep cleanup bounded. The foreign tab documents its own status
representation rather than pretending its errors are event-horizon values.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_deadline.d [hunt-net]

```ansi [hunt-net output]
sleep returned: stopped by adapter
timed out: true
cleaned up: true
```

<<< @/libs/event-horizon/tutorial/snippets/eh_deadline.d [event-horizon]

```ansi [event-horizon output]
sleep returned: ECANCELED
timed out: true
cleaned up: true
```

:::

## TCP and buffer ownership

In the pinned 0.7.1 implementation, `NetServer.actualPort()` returns the configured
port, not the kernel-assigned port when configured with zero. This fixture uses
a Phobos server bound to port zero and exercises the real Hunt-net client and
its ByteBuffer callback. The fixture server is not presented as Hunt-net code.
The client owns an initially stopped event loop, so connection initialization
runs on the loop's thread. The main thread waits for the close notification,
not just the last data callback, before tearing down that loop.
This pinned dependency graph also starts a DateTime daemon before `main` but
does not join it at shutdown. Each standalone Hunt fixture explicitly stops and
joins the sole startup daemon before starting application threads. Its assertion
fails if that startup ownership changes; this process-wide workaround is not a
recipe for shutting down someone else's threads in an embedded application.

The fixture sends the five-byte message `hello` and asserts the echoed bytes.
TCP is a byte stream: neither one write nor one readiness/completion notification
is a message boundary. Accumulate partial receives and retain unsent suffixes,
or use an API's documented all-bytes operation. Binding loopback port zero lets
the OS reserve a port for this run without a port-selection race.

The foreign callbacks borrow buffers according to their library's contract. Copy
data that must outlive a callback, or retain the documented owner. Event Horizon
moves an owned buffer into the operation and returns ownership on completion.
That lifetime discipline is not a promise of kernel or network zero-copy. A real
protocol also needs framing, maximum message sizes and per-connection deadlines.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_tcp_echo.d [hunt-net]

```ansi [hunt-net output]
echoed: hello
```

<<< @/libs/event-horizon/tutorial/snippets/eh_tcp_echo.d [event-horizon]

```ansi [event-horizon output]
echoed: hello
```

:::

## Queues, channels and backpressure

Hunt's `SimpleQueue` has no capacity bound. Its example intentionally lets the
producer finish before the consumer starts: this proves the absence of a
capacity-two backpressure guarantee. Add a bounded application adapter before
using this design for an unbounded event source.

The shared payload contract is the ordered sequence 1 through 5, with sum 15.
The flow-control contracts can differ. The event-horizon program fills capacity
two, proves the third put is pending, frees one slot, and proves exactly one
additional put progresses before draining the remaining values and checking
the closed-channel result. No short sleep is used as the backpressure proof.

Read the foreign implementation before translating `put`: an unbounded queue
does not acquire a capacity bound merely because the consumer is slow. A
callback adapter must stop producing and arrange a wakeup when space returns;
blocking an event-loop thread on an OS semaphore can stop unrelated connections.
Event Horizon's `Channel!(T, capacity)` belongs to one scheduler and is not a
drop-in cross-thread notification or broadcast mechanism.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_channel.d [hunt-net]

```ansi [hunt-net output]
consumed: 15
```

<<< @/libs/event-horizon/tutorial/snippets/eh_channel.d [event-horizon]

```ansi [event-horizon output]
consumed: 15
```

:::

## Files and operation lifetime

The fixture owns a fresh temporary directory and a file containing exactly
`hello from a file\n`. Assertions check the byte count and contents. Keep file
and buffer ownership until all pending operations finish; then close the file
before removing the fixture. Never classify an arbitrary read failure as EOF.

The event-horizon example reads until EOF using offsets and an owned buffer.
Its Linux io_uring implementation submits file operations to the kernel. This
does not establish the same behavior for every backend: kqueue synthesizes
completions over readiness and its regular-file worker-pool refinement is
separate. Where the foreign example uses a worker adapter, it is explicitly
application code, not evidence of a native filesystem capability.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_file_read.d [hunt-net]

```ansi [hunt-net output]
read 18 bytes: hello from a file
```

<<< @/libs/event-horizon/tutorial/snippets/eh_file_read.d [event-horizon]

```ansi [event-horizon output]
read 18 bytes: hello from a file
```

:::

## Capturing a child process

The child writes different text to stdout and stderr, then exits with code 3.
Both streams and the nonzero status are asserted: a child command failing is
not necessarily failure to launch or observe it. Root reaping is part of the
operation's lifetime.

A general capture implementation must drain both pipes concurrently, even when
one is quiet. Reading all stdout before stderr can deadlock when the stderr
pipe fills. Tiny fixed fixtures do not prove a hand-written adapter safe for
unbounded output. `capture` supplies the drain/reap coordination; adapters need
their own output limits, cancellation and error handling.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_exec.d [hunt-net]

```ansi [hunt-net output]
stdout: out

stderr: err

exit code: 3
```

<<< @/libs/event-horizon/tutorial/snippets/eh_exec.d [event-horizon]

```ansi [event-horizon output]
stdout: out

stderr: err

exit code: 3
```

:::

## Streaming and root termination: an explicit adapter

This foreign program is an application-side process adapter, not a native
supervision API. It owns an OS worker, reads complete lines with Phobos, sends
TERM only after the second line establishes readiness, and asserts the root's
reaped status. `exec sleep` avoids leaving a shell child holding the output pipe.
The library-specific `runWorker` code makes completion delivery and joining
visible. EVE's adapter polls an atomic completion flag; Collie posts a task;
libasync triggers an owner-loop notifier; Hunt uses an explicitly joined Task.

The event-horizon program requests scope cancellation after the same readiness
point. It asserts the final `cancelled` result, root reap status and natural EOF.
Neither fixture demonstrates unescapable descendants. Timeouts and hard-kill
escalation are separate policies; see the deadline pair and containment notes.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_spawn.d [hunt-net]

```ansi [hunt-net output]
line: one
line: two
exited: SIGTERM
end: reaped
```

<<< @/libs/event-horizon/tutorial/snippets/eh_spawn.d [event-horizon]

```ansi [event-horizon output]
line: one
line: two
exited: cancelled, signaled by 15
end: cancelled, reap: reaped
```

:::

## POSIX signals through an explicit worker adapter

Hunt's Task state machine is not a POSIX signal subscription API. This adapter
blocks SIGUSR1 in its worker, sends a thread-directed signal, receives it with
`sigwait`, restores the previous mask and joins the worker. It asserts both
the signal identity and the Task's completed state. No mutex, allocation or
notification operation runs inside an asynchronous signal handler. Event
Horizon's counterpart instead consumes masked signals through `SignalFd`.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_signal.d [hunt-net]

```ansi [hunt-net output]
got signal SIGUSR1
```

<<< @/libs/event-horizon/tutorial/snippets/eh_signal.d [event-horizon]

```ansi [event-horizon output]
got signal SIGUSR1
```

:::

## Retries and finite policy

The first two attempts represent transient failure; the third succeeds. The
foreign timer adapter uses a fixed interval (Photon uses explicit exponential
delays), whereas event-horizon composes `exponential` with `recurs`. Assert the
attempt budget and final value rather than exact elapsed time. In production,
retry only selected transient errors, propagate cancellation and permanent
failures, and ensure repeated side effects are safe. A timer callback becoming
ready is not itself permission to retry a non-idempotent operation.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/hunt_retry.d [hunt-net]

```ansi [hunt-net output]
succeeded on attempt 3
```

<<< @/libs/event-horizon/tutorial/snippets/eh_retry.d [event-horizon]

```ansi [event-horizon output]
succeeded on attempt 3
```

:::

## Errors and migration decisions

| Boundary                   | Migration decision                                                                                                            |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Ordinary operation failure | Check the foreign status/exception and the event-horizon `IoResult`; do not silently treat failure as success or EOF.         |
| Task failure               | Decide who observes the error and who joins remaining work. Scope outcomes and defects are distinct from ordinary I/O errors. |
| Buffer lifetime            | Retain borrowed data until the foreign operation finishes; recover moved buffers from event-horizon completions.              |
| Cross-thread work          | Use a documented cross-thread bridge. Scheduler-local channels do not replace it.                                             |
| Missing native primitive   | Treat a Phobos/POSIX adapter as application integration, not as a feature supplied by the networking library.                 |

## Next steps

Start with one independently owned connection or operation. Preserve its framing,
error handling and shutdown behavior before changing scheduler topology. The
[Node.js comparison](./coming-from-nodejs.md) provides another fully executable
view of the same concerns, including explicit retries. The
[execution guide](./running-examples.md) records platform and containment limits.

<!-- References -->

[hunt]: https://github.com/huntlabs/hunt-net/blob/81fd38deebe6a5ec093ef9e86770cd0dce22b355/README.md
