# Coming from Photon

Photon makes concurrent D code look synchronous through fibers and intercepted
I/O calls. Event Horizon also offers direct-style fibers, but its examples use
explicit I/O capabilities and scopes instead of ambient syscall interception.

This guide uses [Photon][photon] at
`4cb737aa38bcde87ca400d1df3b092ad38655ad5`. Its README explains the distinction
between blocking, asynchronous, and pseudo-blocking I/O and demonstrates
`initPhoton`, `go`, and `runScheduler` as the entry point.

<!-- verified-comparisons -->

> [!NOTE]
> Each source tab imports a complete single-file DUB program. Run it with
> `dub run --single <file> -b checked`; assertions stay enabled. Each labelled
> output belongs to the immediately preceding implementation and is independently
> checked by `ci --verify`. See [Running the examples](./running-examples.md)
> for prerequisites, dependency versions and the validation command.

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

<<< @/libs/event-horizon/tutorial/snippets/photon_timers.d [photon]

```ansi [photon output]
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

<<< @/libs/event-horizon/tutorial/snippets/photon_concurrency.d [photon]

```ansi [photon output]
joined: 12
```

<<< @/libs/event-horizon/tutorial/snippets/eh_concurrency.d [event-horizon]

```ansi [event-horizon output]
joined: 12
```

:::

## Cancellation, deadlines and cleanup

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

<<< @/libs/event-horizon/tutorial/snippets/photon_deadline.d [photon]

```ansi [photon output]
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

<<< @/libs/event-horizon/tutorial/snippets/photon_tcp_echo.d [photon]

```ansi [photon output]
echoed: hello
```

<<< @/libs/event-horizon/tutorial/snippets/eh_tcp_echo.d [event-horizon]

```ansi [event-horizon output]
echoed: hello
```

:::

## Queues, channels and backpressure

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

<<< @/libs/event-horizon/tutorial/snippets/photon_channel.d [photon]

```ansi [photon output]
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

<<< @/libs/event-horizon/tutorial/snippets/photon_file_read.d [photon]

```ansi [photon output]
read 18 bytes: hello from a file

```

<<< @/libs/event-horizon/tutorial/snippets/eh_file_read.d [event-horizon]

```ansi [event-horizon output]
read 18 bytes: hello from a file

```

:::

## Streaming and termination

Streaming adds a state machine: accumulate bytes into lines, observe the root,
request termination, finish drains, and reap. A pipe read can split a line or
contain several lines, so splitting each chunk independently is insufficient.
The two source tabs expose the cleanup machinery instead of hiding it behind
a printed success message.

The foreign program's manual root termination is not process-tree containment.
Event Horizon reports supervision outcome and reap provenance, but its process
group/cgroup tiers are not an inescapable sandbox either: descendants can race
the post-spawn cgroup migration. EOF may be forced at the drain limit. See
[the supervision caveats](./running-examples.md#capture-versus-streaming-supervision).

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/photon_spawn.d [photon]

```ansi [photon output]
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

## POSIX signals and loop notifications

The foreign tab uses `sigwait` in an ordinary worker and then delivers completion
through its runtime bridge. Unlike calling an event method from a signal handler,
this does not assume the event method is async-signal-safe. The signal is
thread-directed for an isolated, reproducible fixture.

Install the signal receiver before sending `SIGUSR1` to this process and assert
that the expected signal was observed. Linux signal masks and handler installation
are process/thread integration decisions; they are not interchangeable with an
ordinary callback queue. Keep signal-handler work async-signal-safe.

`SignalFd` receives masked POSIX signals through the event-horizon loop. A foreign
notification primitive may only wake an owner loop from another thread. In
particular, libasync's `AsyncSignal` is not a POSIX signal subscription; an OS
signal bridge must supply that integration explicitly. These programs are Linux
fixtures, not Windows signal portability examples.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/photon_signal.d [photon]

```ansi [photon output]
got signal SIGUSR1
```

<<< @/libs/event-horizon/tutorial/snippets/eh_signal.d [event-horizon]

```ansi [event-horizon output]
got signal SIGUSR1
```

:::

## Capturing both child streams

Photon's `offload` supplies the worker boundary; Phobos supplies process and
pipe management. The adapter drains stderr on a second thread while reading
stdout, joins that drain, waits for the root and asserts both streams and exit
code 3. This is application integration, not a Photon process-supervisor API.
Event Horizon's `capture` owns this coordination. Real applications should
add output bounds and cancellation policies rather than assuming a child
will produce only this small fixture.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/photon_exec.d [photon]

```ansi [photon output]
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

## Retries and finite policy

The first two attempts represent transient failure; the third succeeds. The
foreign timer adapter uses a fixed interval (Photon uses explicit exponential
delays), whereas event-horizon composes `exponential` with `recurs`. Assert the
attempt budget and final value rather than exact elapsed time. In production,
retry only selected transient errors, propagate cancellation and permanent
failures, and ensure repeated side effects are safe. A timer callback becoming
ready is not itself permission to retry a non-idempotent operation.

::: code-group

<<< @/libs/event-horizon/tutorial/snippets/photon_retry.d [photon]

```ansi [photon output]
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

[photon]: https://github.com/DmitryOlshansky/photon/blob/4cb737aa38bcde87ca400d1df3b092ad38655ad5/README.md
