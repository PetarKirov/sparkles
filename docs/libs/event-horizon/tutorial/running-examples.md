# Running the comparison examples

The migration guides share ten complete Event Horizon programs under
`docs/libs/event-horizon/tutorial/snippets/`. VitePress imports those source files
directly, and the repository's standalone-example CI gate builds and runs them.
The upstream comparisons are grounded in linked source revisions; they are not
claims that foreign example programs or every platform have been tested here.

## Prerequisites and commands

These fixtures target Linux with a usable io_uring backend. They use the current
repository through a relative DUB dependency, not a published package version.
The signal and process examples also require normal POSIX facilities and `sh`.
Run from a checkout with the project's D toolchain available:

```bash
dub run --single docs/libs/event-horizon/tutorial/snippets/eh_timers.d -b checked
dub run :ci -- --example-files --include-files 'docs/libs/event-horizon/tutorial/snippets/*.d'
```

`checked` keeps assertions enabled. The examples use assertions as executable
checks; an application should handle expected failures rather than assert that
they cannot occur. An unavailable backend is an explicit failure, not silently
reported as a successful demonstration.

The default `LoopGroup` topology is one scheduler on the calling thread. Fibers
can run concurrently without running simultaneously on multiple CPU cores.
Do not share scheduler-local channels or handles across worker threads.

## Completion interface, backend-specific implementation

Linux io_uring submits operations and reports their completion. Event Horizon's
kqueue backend synthesizes completions over readiness; it does not turn kqueue
into an io_uring-style ring. Backend support is not identical, and the Windows
supervision port remains deferred. Consult [PLAN.md][plan] before relying on an
operation outside the tested Linux path.

Moving a buffer transfers its ownership through an operation. It does not prove
zero-copy transport, eliminate every alias, or make the whole application
`@nogc`. Setup, callbacks, and integrations can allocate or throw. Blocking host
work needs an explicit worker boundary; a fiber does not make arbitrary blocking
calls cooperative.

## I/O results versus scope outcomes

| Result          | What to check                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------- |
| `IoResult!T`    | `hasError` before reading `value`; errors carry errno, operation, and stage.                  |
| `Outcome!T`     | Scope success, failure, interruption, or defect; do not discard the outer `group.run` result. |
| Process result  | Inspect both the I/O result and exit status; a nonzero child exit is normal result data.      |
| Channel receive | `EPIPE` means closed and drained; cancellation is not normal end-of-stream.                   |

Joining structured children does not preempt CPU-bound code. A deadline is
cooperative and can take longer than its requested duration while children and
protected cleanup finish. See [the scope and cancellation specification][spec].

## Deadlines and cleanup

The sleep is interrupted, but the small protected cleanup completes before the
deadline outcome is returned.

<<< @/libs/event-horizon/tutorial/snippets/eh_deadline.d [event-horizon]

```ansi
sleep returned: ECANCELED
timed out: true
cleaned up: true
```

## TCP is a byte stream

Neither a send nor a receive is guaranteed to transfer an entire application
message. The echo fixture uses an ephemeral loopback port and loops over partial
transfers. Its five-byte exchange is a fixture protocol, not a general decoder.

<<< @/libs/event-horizon/tutorial/snippets/eh_tcp_echo.d [event-horizon]

```ansi
echoed: hello
```

## Capture versus streaming supervision

Use `capture` to collect stdout/stderr and the root's exit status. Use `supervise`
for framed output callbacks, resource samples, and termination policy. Callback
line bytes are borrowed: copy them if they must outlive the callback.

<<< @/libs/event-horizon/tutorial/snippets/eh_spawn.d [event-horizon]

The sample prints two lines and a timed-out result. The exact terminating signal
is diagnostic: TERM is attempted first, with KILL after the requested grace if
needed. Do not use a signal number as a portable expected-output contract.

Tree containment is capability-dependent. Linux cgroups strengthen the boundary,
but post-spawn migration can race a child that forks immediately; process groups
do not contain a descendant that creates another session. Degradation and leaked
cgroup telemetry remain meaningful results, not guarantees to omit from a caller.

## POSIX signals are not cross-thread messages

Create `SignalFd` before starting other threads that should inherit the blocked
signal mask. This fixture sends `SIGUSR1` to itself, then consumes it through the
scheduler. It is distinct from a library's in-process notification object.

<<< @/libs/event-horizon/tutorial/snippets/eh_signal.d [event-horizon]

```ansi
got signal SIGUSR1
```

## Retry with a clock capability

This policy combines exponential delays with a finite recurrence limit. The
example uses portable `EAGAIN` rather than a Linux numeric literal.

<<< @/libs/event-horizon/tutorial/snippets/eh_retry.d [event-horizon]

```ansi
succeeded on attempt 3
```

Return to the [library overview](../index.md) to choose a source-library guide.

<!-- References -->

[plan]: ../../../specs/event-horizon/PLAN.md
[spec]: ../../../specs/event-horizon/SPEC.md
