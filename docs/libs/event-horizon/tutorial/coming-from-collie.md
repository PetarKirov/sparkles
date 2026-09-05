# Coming from collie

Collie presents networking through a Netty-style channel and pipeline framework.
Event Horizon supplies lower-level I/O verbs and scoped fibers; it does not
replace a codec or handler pipeline automatically.

The [Collie baseline][collie] is
`f1e58e38a2c36366766e4778d3ea655ebac6962c`. Its support matrix lists epoll,
kqueue, IOCP, and select. IOCP is a completion interface, so calling every Collie
backend a readiness reactor would erase an important platform distinction.

## Move one connection at a time

| Collie concept             | Event Horizon building block       | Work still owned by the application                           |
| -------------------------- | ---------------------------------- | ------------------------------------------------------------- |
| Event-loop-managed channel | `Listener`, `Stream`, owning scope | Decide connection lifetime and shutdown policy.               |
| Inbound handler pipeline   | A fiber's receive/decode loop      | Preserve protocol state and codec boundaries.                 |
| Outbound writes            | `send(move(buf))`                  | Handle partial writes; a completion need not send everything. |
| Timer callback             | `env.clock.sleep`, `Ticker`        | Choose relative delay or absolute cadence.                    |
| Handler error path         | `IoResult!T` and scope outcome     | Distinguish I/O failure, cancellation, and defects.           |

Do not infer that moving buffers eliminates application-level copying or all
aliasing. It expresses ownership through an operation; protocol framing remains
a separate responsibility.

## Start with a timer

The loop runs the root fiber; sleep parks that fiber and returns a result.

<<< @/libs/event-horizon/tutorial/snippets/eh_timers.d [event-horizon]

```ansi
tick 1
tick 2
tick 3
```

## Replace a minimal echo pipeline

This loopback example binds an ephemeral port, handles partial stream I/O, and
closes both ends. It deliberately does not pretend that one `recv` equals one
protocol message. A real pipeline port needs an incremental decoder.

<<< @/libs/event-horizon/tutorial/snippets/eh_tcp_echo.d [event-horizon]

```ansi
echoed: hello
```

## Compatibility is a separate check

The transferred draft's Collie `0.10.16` timer program failed to build with the
review toolchain (LDC 1.42.0): the dependency's `channel/pipeline.d` uses a
conditional-expression form rejected by that compiler. Accordingly this page
does not label foreign programs as CI-verified. The comparison is grounded in
source; the runnable programs here exercise Event Horizon only.

See [Running the examples](./running-examples.md) for commands and platform
limits, and [the specification](../../../specs/event-horizon/SPEC.md) for the
buffer and cancellation contracts.

<!-- References -->

[collie]: https://github.com/huntlabs/collie/blob/f1e58e38a2c36366766e4778d3ea655ebac6962c/README.md
