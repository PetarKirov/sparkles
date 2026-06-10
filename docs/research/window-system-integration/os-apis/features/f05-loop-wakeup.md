# F05 — Loop wakeup & external fds

A real application's event loop multiplexes more than window events: timers, sockets, IPC,
an async runtime. This demo measures cross-thread wakeup latency and probes whether arbitrary
file descriptors (or handles) can join the native loop — and where they cannot.

## Requirements

1. A second thread posts a user event 10×/second for 30 seconds; the main loop logs
   `wakeup latency_us=…` computed from a monotonic timestamp carried in the event:
   - Wayland: write to a self-pipe/`eventfd` polled alongside the `wl_display` fd (there is
     no protocol-level user event — that absence is the finding; show the canonical
     `prepare_read`/`poll`/`read_events` integration).
   - X11: `XSendEvent` with a `ClientMessage` to self, _and_ the fd alternative below —
     compare both.
   - Win32: `PostThreadMessage`/`PostMessage` with a `WM_APP+n` message.
   - macOS: `-[NSApplication postEvent:atStart:]` of an `NSEventTypeApplicationDefined`
     event, and a `CFRunLoopSource` variant — compare.
2. Add an arbitrary fd (Linux: `timerfd`; macOS: a `pipe` via `CFFileDescriptor`/
   `dispatch_source`; Win32: a waitable timer `HANDLE` via `MsgWaitForMultipleObjectsEx`)
   into the same loop and log its ticks interleaved with window events. Where the native loop
   cannot accept the primitive directly, document the standard workaround and its cost.
3. Report latency stats (min/median/p99/max) per mechanism at exit.

## Instrumentation

`wakeup latency_us=… mech=…`, `fd_tick t=…`, plus the mandatory set.

## Findings to record

- Latency distributions per mechanism per platform.
- The integration shape a framework must offer (fd-based readiness vs handle-array waits vs
  run-loop sources) — cross-link the readiness-vs-completion discussion in
  [concepts](../../concepts.md#readiness-vs-completion-windowing).
- Thread-safety rules for each injection mechanism (who may call it, from where).

## Verification

Wayland/X11: Tier A. Win32: `A[wine]` (timer-resolution caveats under Wine — note them).
macOS: `A[ssh]`. No genuinely interactive part — this row should be fully agent-verifiable.
