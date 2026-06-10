# Win32 — F05: loop wakeup & external handles

Findings from [`./examples/f05-loop-wakeup/app.d`][f05-app], the Win32 implementation of the
[F05 spec][f05-spec]: a worker thread ([`CreateThread`][createthread]) wakes the UI loop
10×/second for 30 seconds through **two mechanisms at once** — [`PostMessageW`][postmessage]
(`WM_APP+1`, to the window) and [`PostThreadMessageW`][postthreadmessage] (`WM_APP+2`, to the
thread id, no `HWND`) — each event carrying a [`QueryPerformanceCounter`][qpc] timestamp
through a per-sequence shared slot. The pump itself is not [`GetMessage`][getmessage] but
[`MsgWaitForMultipleObjectsEx`][msgwait] over a 7 Hz [`CreateWaitableTimerW`][createwaitabletimer]
handle — Win32's "add an arbitrary fd" story — plus a start-up probe that demonstrates the
**63-handle ceiling** of that story. Latency stats (min/median/p99/max) per mechanism print
at exit.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`, null
> display driver, headless) with the exe cross-compiled by LDC 1.41.0
> (`-mtriple=x86_64-pc-windows-msvc`). Wine is a **reimplementation, not Windows**: latency
> numbers are wineserver round-trips, not Windows kernel queue costs, and waitable-timer
> behavior is wineserver-timeout-based rather than quantized by the Windows timer
> resolution. The latency table and the timer-jitter row are queued for re-measurement on
> real Windows ([manual-run queue][manual-queue]).

---

## The demo

One bounded run (`WSI_AUTO_EXIT=1`, ~30.1 s wall): 300 posts per mechanism, 211 timer
ticks, every wakeup logged, clean exit `0`:

```text
389      qpc_freq hz=10000000
13299    window_created
19302    handle_limit_probe n=64 result=0xffffffff err=87
19721    handle_limit_probe n=63 result=0x0000003f err=0
20643    step name=SetWaitableTimer period_ms=142
21075    step name=CreateThread rate_hz=10 duration_s=30
121684   wakeup latency_us=63 mech=postmessage seq=0
122185   wakeup latency_us=536 mech=threadmessage seq=0
162945   fd_tick t=162945 n=1
221827   wakeup latency_us=59 mech=postmessage seq=1
222229   wakeup latency_us=430 mech=threadmessage seq=1
305034   fd_tick t=305034 n=2
...
30071534 worker_done posts=300
30072923 latency_stats mech=postmessage n=300 min_us=30 median_us=60 p99_us=131 max_us=781
30073482 latency_stats mech=threadmessage n=300 min_us=368 median_us=506 p99_us=711 max_us=1344
30074025 latency_stats mech=handle_tick_interval n=210 min_us=141031 median_us=142103 p99_us=142734 max_us=142852
30074629 tick_total n=211 nominal_period_ms=142
30074956 exit code=0
```

The wakeup events and the `fd_tick` events interleave freely in one loop — the spec's core
requirement — with no second wait primitive and no polling.

---

## Latency per mechanism — `A[wine]`

| Mechanism                                     | n   | min (µs) | median (µs) | p99 (µs) | max (µs) |
| --------------------------------------------- | --- | -------- | ----------- | -------- | -------- |
| [`PostMessageW`][postmessage] (`WM_APP+1`)    | 300 | 30       | **60**      | 131      | 781      |
| [`PostThreadMessageW`][postthreadmessage]     | 300 | 368      | **506**     | 711      | 1,344    |
| waitable-timer tick interval (nominal 142 ms) | 210 | 141,031  | 142,103     | 142,734  | 142,852  |

Two honesty notes on reading this table:

- **The `threadmessage` column is not a mechanism cost.** The worker posts the
  `PostMessageW` event first and the `PostThreadMessageW` event ~1 µs later, into the
  **same FIFO queue**; the pump therefore always handles the thread message _behind_ the
  window message of the same sequence, and its measured latency includes the window
  message's entire handling (two instrumented `fprintf`+`fflush` lines ≈ 400 µs — compare
  the inter-line gaps in the excerpt above). The mechanisms are queue-equivalent; what the
  delta actually measures is **queue position plus the cost of whatever runs before you**.
  A framework should read this as: posted wakeups are cheap (~60 µs median under Wine,
  `A[wine]`), and latency is dominated by what else the loop is doing.
- The timer interval distribution is **tight** under Wine (median 142.10 ms against a
  142 ms programmed period, worst case +0.85 ms / −0.97 ms over 210 ticks). On real
  Windows, [`SetWaitableTimer`][setwaitabletimer] expirations quantize to the system timer
  resolution (default 15.6 ms) unless a high-resolution timer is requested — this row is
  exactly the kind of number Wine cannot stand in for ([manual queue][manual-queue]).

---

## The pump: one wait for queue + handles

The classic `GetMessage` loop blocks on **exactly one** source — the message queue. The
demo's replacement ([`app.d`][f05-app]):

```d
const r = MsgWaitForMultipleObjectsEx(1, &g.timer, INFINITE,
    QS_ALLINPUT, MWMO_INPUTAVAILABLE);
if (r == WAIT_OBJECT_0)
    /* the timer handle fired: log fd_tick */;
// r == WAIT_OBJECT_0 + 1: the queue — drain it fully with PeekMessageW
```

- The handle array comes **first**; index `nCount` (here `WAIT_OBJECT_0 + 1`) means "the
  queue has input matching the `QS_*` mask". A signaled handle wins ties — queue input is
  reported only at index `nCount`.
- **`MWMO_INPUTAVAILABLE` is load-bearing.** Without it the wait ignores input that was
  already in the queue before the call — "[t]he function returns if input exists for the
  queue, even if the input has been seen (but not removed) using a call to another
  function, such as `PeekMessage`" ([`MsgWaitForMultipleObjectsEx`][msgwait]). A drain-then-wait
  loop that forgets this flag stalls on any message that arrives between the last
  [`PeekMessageW`][peekmessage] returning `FALSE` and the wait re-entering — a classic
  lost-wakeup race.
- After any return, the queue is drained with `PeekMessageW(..., PM_REMOVE)` until empty —
  a timer wake may coincide with pending messages, and `MsgWaitForMultipleObjectsEx`
  reports state, not counts.

The external source itself is an auto-reset [`CreateWaitableTimerW`][createwaitabletimer] +
[`SetWaitableTimer`][setwaitabletimer] at a 142 ms period — auto-reset, so a satisfied wait
consumes the signal with no manual reset step. Anything that is a kernel handle (events,
processes, pipes via `OVERLAPPED` events, sockets via `WSAEventSelect`) joins the loop the
same way. What does **not** join: raw sockets/fds directly (they must be converted to an
event first) — handle-readiness, not fd-readiness, is the native currency. Cross-link: the
readiness-vs-completion discussion in [concepts][concepts-rvc].

## The 63-handle ceiling — demonstrated

> The maximum number of object handles is `MAXIMUM_WAIT_OBJECTS` minus one.
>
> — [`MsgWaitForMultipleObjectsEx`][msgwait], Microsoft Learn

`MAXIMUM_WAIT_OBJECTS` is 64; the message queue occupies the implicit last slot, so user
handles cap at **63**. The demo proves the edge at start-up with 64 freshly created events
(`A[wine]`, matching the documented contract):

```text
19302  handle_limit_probe n=64 result=0xffffffff err=87
19721  handle_limit_probe n=63 result=0x0000003f err=0
```

`0xffffffff` = `WAIT_FAILED` with `GetLastError() == 87` (`ERROR_INVALID_PARAMETER`);
with 63 handles the same call succeeds (`0x3f` = `WAIT_OBJECT_0 + 63`: queue input was
pending). This is the structural difference from the `poll`-based platforms in the
[F05 spec][f05-spec]: Wayland/X11 loops scale to thousands of fds in one `poll` set, while
the Win32 windowing loop takes an **array of at most 63 handles**. Past that, the standard
workarounds all cost a thread or a port: nest `WaitForMultipleObjects` waits in worker
threads (the documented pattern — "[t]o wait on more than `MAXIMUM_WAIT_OBJECTS` handles
… [c]reate a thread to wait on `MAXIMUM_WAIT_OBJECTS` handles, then wait on that thread
plus the other handles" — [`WaitForMultipleObjects`][waitformultipleobjects]), funnel completions
into an I/O completion port serviced off-thread, or collapse everything to one event +
`PostMessageW` to the UI loop — which is mechanism A again.

## Thread messages: the `hwnd`-less pitfall — demonstrated

`PostThreadMessageW` events arrive with `msg.hwnd == null`, so they never reach a `WndProc`:
[`DispatchMessageW`][getmessage] has nowhere to route them, and the pump must recognize them
**before** dispatching. The demo handles them inline in the drain loop; mid-run it also
probes how filtering behaves while a thread message is known to be queued:

```text
15144306 thread_msg_filter_probe hwnd_filtered=0 null_filtered=1
```

A `PeekMessageW` with an `HWND` filter **cannot retrieve** a queued thread message
(`hwnd_filtered=0`); the same peek with a `null` filter sees it. That is precisely why the
documentation warns they are lost in modal loops — any nested pump that filters by window,
or that simply doesn't know about the app's thread messages
([`DialogBox`/`MessageBox`/the F03 move-size loop][f03]), pumps right past them:

> If the recipient thread is in a modal loop (as used by `MessageBox` or `DialogBox`), the
> messages will be lost. To intercept thread messages while in a modal loop, use a
> thread-specific hook.
>
> — [`PostThreadMessageW`][postthreadmessage], Microsoft Learn

Thread-safety rules, per the documentation: both posts may be called from **any thread**;
the target of `PostThreadMessageW` "must have created a message queue, or else the call …
fails" (first user32 call creates it — a race at thread start-up the demo sidesteps by
creating the window before the worker). Neither carries a payload beyond
`WPARAM`/`LPARAM` — hence the demo's shared timestamp-slot array, which any real
framework reproduces as a ring buffer the integer `wParam` indexes into.

**Verdict for a framework:** `PostMessageW` to a known window is the only injection that
survives nested/modal pumps and reaches a `WndProc` unaided — make it the wakeup
primitive; treat `PostThreadMessageW` as a trap unless you own every pump on the thread.

---

## Surprises

- **The two post mechanisms are queue-equivalent; ordering is the whole observable
  difference** (`A[wine]`). The naive reading of the stats table ("thread messages are 8×
  slower") is wrong — see the honesty note above. Measurement methodology matters more
  than mechanism here.
- **`MsgWaitForMultipleObjectsEx` with 64 handles fails outright** rather than waiting on
  a truncated set — a hard `ERROR_INVALID_PARAMETER`, easy to hit when a framework grows
  its handle array dynamically (`A[wine]`, per-spec behavior).
- **Wine's waitable timer is _more_ regular than Windows'** is expected to be: ±1 ms
  around the 142 ms period with no timer-resolution quantization visible. A jitter budget
  tuned under Wine would mislead for real Windows — flagged for the
  [manual queue][manual-queue].
- **An auto-reset timer can only be consumed by the wait that catches it** — during long
  drains (many queued messages), timer signals do not accumulate: 211 ticks were delivered
  where a 30.1 s run at 142 ms could have produced ~212. At most one tick is pending no
  matter how late the loop returns to the wait — coalescing a framework must expect.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f05-loop-wakeup/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f05-loop-wakeup.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f05-loop-wakeup.exe
```

Bounded run: ~30.1 s (the spec's 10 Hz × 30 s), 600 `wakeup` events + 211 `fd_tick`
events, stats at exit, exit code `0`. Without `WSI_AUTO_EXIT=1` the window stays open
after the worker finishes; closing it produces the same stats block. The package's
`dub.sdl` (`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not
part of the pipeline, and the demo must not be run under `wine explorer /desktop=…` (it
swallows stdout and the exit code).

---

## Sources

- [`./examples/f05-loop-wakeup/app.d`][f05-app] — the demo (all log excerpts above)
- [F05 spec][f05-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold] — baseline pump and pipeline
- [Concepts § readiness vs completion][concepts-rvc] — where handle-array waits sit in the
  design space
- [`PostMessageW`][postmessage], [`PostThreadMessageW`][postthreadmessage],
  [`MsgWaitForMultipleObjectsEx`][msgwait], [`WaitForMultipleObjects`][waitformultipleobjects],
  [`CreateWaitableTimerW`][createwaitabletimer], [`SetWaitableTimer`][setwaitabletimer],
  [`QueryPerformanceCounter`][qpc], [`PeekMessageW`][peekmessage],
  [`CreateThread`][createthread], [`GetMessage`][getmessage] — Microsoft Learn
  (Wayback-pinned)

<!-- References -->

[f05-app]: ./examples/f05-loop-wakeup/app.d
[scaffold]: ./scaffold.md
[f05-spec]: ../features/f05-loop-wakeup.md
[f03]: ../features/f03-modal-loop.md
[manual-queue]: ../manual-run-queue.md
[concepts-rvc]: ../../concepts.md#readiness-vs-completion-windowing
[postmessage]: https://web.archive.org/web/20251115024504/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postmessagew
[postthreadmessage]: https://web.archive.org/web/20250819224328/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postthreadmessagew
[msgwait]: https://web.archive.org/web/20260518153124/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-msgwaitformultipleobjectsex
[waitformultipleobjects]: https://web.archive.org/web/20260527203029/https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjects
[createwaitabletimer]: https://web.archive.org/web/20260225203946/https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerw
[setwaitabletimer]: https://web.archive.org/web/20260313125448/https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimer
[qpc]: https://web.archive.org/web/20260430173900/https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancecounter
[peekmessage]: https://web.archive.org/web/20260412100310/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-peekmessagew
[createthread]: https://web.archive.org/web/20260516063237/https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createthread
[getmessage]: https://web.archive.org/web/20260420210137/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessage
