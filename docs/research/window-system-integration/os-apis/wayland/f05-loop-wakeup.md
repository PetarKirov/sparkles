# Wayland F05 — loop wakeup & external fds

Findings from [`./examples/f05-loop-wakeup/app.d`](./examples/f05-loop-wakeup/app.d), the
[F05 spec][f05]'s Wayland demo. The question is whether a second thread can wake the native
event loop and whether arbitrary file descriptors can join it — and on Wayland the answer is
structural: the `wl_display` connection **is** a file descriptor, and libwayland's documented
thread-safe pump ([`wl_display_prepare_read`][api-prep] → `poll(2)` →
`wl_display_read_events` → `wl_display_dispatch_pending`) is _designed_ around the
application owning the `poll`. Integrating an `eventfd(2)` and a `timerfd_create(2)` fd is
therefore not a workaround but the intended shape — that loop is this demo's deliverable.
What Wayland does **not** have is a protocol-level user event: no `XSendEvent`, no
`PostMessage` analogue — a client cannot route a message to itself through the compositor,
so cross-thread wakeup must be a client-owned fd. The absence is the finding. Verified
Tier A: `weston --backend=headless` (weston 15.0, libwayland 1.24), 300/300 wakeups
consumed, exit `0`.

**Last reviewed:** June 11, 2026

| Measurement                        | Value                                                                                        |
| ---------------------------------- | -------------------------------------------------------------------------------------------- |
| Wakeup latency (`eventfd`, n=300)  | **min 6 µs, median 11 µs, p99 238 µs, max 406 µs** (post → consumption, same MonoTime clock) |
| Coalesced posts                    | 0 of 300 — at 10 Hz against a ~60 Hz-busy loop, every post was consumed before the next      |
| `timerfd` probe                    | 210 ticks in 30 s at 7 Hz — exactly nominal; no missed expirations (`expirations=1` always)  |
| Run shape                          | 30 s: 300 eventfd posts + 210 timer ticks + 1801 frame callbacks + 1802 commits, exit `0`    |
| Integration cost of an external fd | one `pollfd` entry + one drain branch — zero protocol involvement                            |

## The canonical multiplexing loop (the deliverable)

The scaffold's `wl_display_dispatch` blocks inside libwayland, where no other fd can join.
The official escape hatch is the prepare-read pattern; the [Client API documentation for
`wl_display_prepare_read`][api-prep] specifies the contract:

> Calling `wl_display_prepare_read_queue()` announces the calling thread's intention to read
> and ensures that until the thread is ready to read and calls `wl_display_read_events()`,
> no other thread will read from the file descriptor.
>
> — libwayland [Client API, Appendix B][api-prep]

It succeeds only against an **empty** queue (otherwise −1/`EAGAIN` — dispatch first), and a
successful call _must_ be balanced by exactly one of `wl_display_read_events()` or
`wl_display_cancel_read()` — leaking the read intention deadlocks other reader threads. The
demo's `pumpOnce` is the documented usage sample with two extra `pollfd` entries:

```d
bool pumpOnce(int timeoutMs) nothrow @nogc
{
    // 1. Dispatch what is already queued; acquire the read intent.
    while (wl_display_prepare_read(g_display) != 0)
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    // 2. Flush outgoing requests before sleeping.
    wl_display_flush(g_display);

    // 3. ONE poll over all event sources — the whole point of the pattern.
    pollfd[3] pfds;
    pfds[0].fd = wl_display_get_fd(g_display);
    pfds[1].fd = g_eventfd;   // cross-thread wakeup channel
    pfds[2].fd = g_timerfd;   // arbitrary-fd probe (7 Hz)
    // … all three POLLIN; poll(pfds.ptr, 3, timeoutMs) …

    // 4. Exactly one of read_events / cancel_read, per the contract.
    if (pfds[0].revents & POLLIN)
    {
        if (wl_display_read_events(g_display) < 0)
            return false;
        if (wl_display_dispatch_pending(g_display) < 0)
            return false;
    }
    else
        wl_display_cancel_read(g_display);

    // 5. The external fds, on the same wakeup.
    if (pfds[1].revents & POLLIN) drainEventfd();
    if (pfds[2].revents & POLLIN) drainTimerfd();
    return true;
}
```

This is the integration shape a framework must offer on Wayland: **fd-based readiness**
(cross-link: [readiness vs completion][rvc]). There is no "add a source to the toolkit's
loop" API to wrap — libwayland hands the application the fd and the read-intent protocol,
and the application owns the `poll`. Every Wayland toolkit loop (GLib's
`GWaylandSource`, Qt's, SDL's) is a wrapper around exactly this sequence.

## Cross-thread wakeup: `eventfd`, because there is nothing else

Wayland has **no protocol-level user event**. The core protocol's only client-initiated
objects are requests to the compositor; nothing loops back to the sender ([`wl_display`
offers `sync` and `get_registry`][p-display], not "post"). libwayland is thread-safe — any
thread may issue requests — but events another thread queues are only _seen_ when the
dispatching thread next wakes, so the wakeup itself must be a client-owned fd. The demo's
producer thread (raw `pthread_create`; the demo stays allocation-free) posts 10×/s for 30 s:

1. stamp `now` (µs, the shared MonoTime epoch),
2. publish the stamp in a lock-free ring (release-store of the write index),
3. `write(g_eventfd, &one, 8)` — the doorbell.

The timestamp travels through the **ring, not the eventfd value**: the eventfd counter is a
_sum_ of all posted values since the last read ([`eventfd(2)`][man-eventfd]), so two posts
coalescing before one read would add two timestamps into garbage. The counter's only safe
reading is "how many posts to pop". (At this cadence none coalesced — `coalesced=0` — but
the pattern must assume they can.)

The consumed-side log, interleaving all three sources (µs since `init_start`):

```text
100382 f05-wayland wakeup latency_us=29 mech=eventfd seq=0
143053 f05-wayland fd_tick t=143053 mech=timerfd expirations=1 n=1
200429 f05-wayland wakeup latency_us=10 mech=eventfd seq=1
285916 f05-wayland fd_tick t=285916 mech=timerfd expirations=1 n=2
300511 f05-wayland wakeup latency_us=22 mech=eventfd seq=2
400573 f05-wayland wakeup latency_us=16 mech=eventfd seq=3
428769 f05-wayland fd_tick t=428769 mech=timerfd expirations=1 n=3
494380 f05-wayland frame_callback t=478403772
```

And the exit stats (stdout):

```text
stats mech=eventfd n=300 min_us=6 median_us=11 p99_us=238 max_us=406 coalesced=0
stats mech=timerfd ticks=210 expected_hz=7
ok: 300 wakeups consumed, 210 fd_ticks, 1801 frame callbacks, 1802 commits
```

| Mechanism         | min  | median | p90   | p99    | max    |
| ----------------- | ---- | ------ | ----- | ------ | ------ |
| `eventfd` (10 Hz) | 6 µs | 11 µs  | 24 µs | 238 µs | 406 µs |

Distribution shape: 293 of 300 posts land under 100 µs; the 7 outliers (238–406 µs) are
posts that arrived while the loop was inside a dispatch/render pass and had to wait for it
to finish — wakeup latency on a single-threaded readiness loop is bounded below by the
longest callback, not by the kernel (the `poll` wake itself is the 6–24 µs bulk).

## The arbitrary-fd probe: `timerfd` at 7 Hz

The deliberately vsync-incommensurate 7 Hz `timerfd` ([`timerfd_create(2)`][man-timerfd],
`CLOCK_MONOTONIC`, non-blocking) ticked **210 times in 30 s — exactly nominal — with every
read returning `expirations=1`**: the loop never fell a full period behind even while also
servicing 60 Hz frame callbacks and the 10 Hz wakeups. Its `fd_tick` lines interleave with
`frame_callback` and `wakeup` lines throughout the trace (excerpt above). Cost of admission:
one `pollfd` entry and one 8-byte read. There is no "registration" with Wayland at all —
the compositor never learns the fd exists.

## Thread-safety rules observed

- **Any thread may `write(2)` the eventfd** — that is the entire injection API, and it is
  async-signal-safe, `nothrow @nogc`, and lock-free at the call site.
- **Only the dispatching thread** runs `prepare_read`/`read_events`/`dispatch_pending` in
  this demo. Multiple reader threads are legal (that is what the intent-registration
  protocol is _for_), but each must then follow the same prepare/read-or-cancel dance.
- The producer never touches a `wl_*` object; libwayland request marshalling from a second
  thread is allowed but irrelevant here — posting work to the loop is the eventfd's job.

## What surprised us

- **The p99 is the app's own fault, by design.** All > 100 µs latencies coincide with the
  loop being busy in a dispatch/paint pass; the mechanism itself (poll wake on eventfd)
  costs ~6–25 µs. A framework that wants low wakeup latency must keep callbacks short — the
  multiplexing pattern adds no overhead of its own.
- **`prepare_read` failing is the normal path, not an error.** Every iteration that follows
  a dispatch with queued events takes the `!= 0` branch at least once; the loop-until-empty
  shape is mandatory, not defensive.
- **The eventfd counter is unusable as a payload channel.** Its sum semantics force the
  side-buffer pattern for anything carrying data — the 8-byte value is only safe as a
  semaphore count. (The demo's ring + release/acquire indices is the minimal correct form.)
- **Nothing about the run depended on the compositor.** Headless weston never saw the
  eventfd or timerfd; both Tier-A caveats of earlier demos (synthetic frame clock, no seat)
  are irrelevant to F05 — this row is fully agent-verifiable, as the spec predicted.

## Open questions

- **Multi-threaded readers.** The intent-registration protocol promises race-free reads
  from several threads (`wl_display_prepare_read_queue` per event queue); the demo
  exercises only the single-reader shape. A framework running listeners on a worker thread
  would need the per-queue variant — untested here.
- **`epoll` at scale.** Three fds make `poll` trivially sufficient; an async runtime would
  hold the wl fd in an `epoll`/io_uring set instead. Nothing in the contract prevents it
  (the fd is just an fd), but edge-triggered interaction with `prepare_read`'s
  queue-must-be-empty precondition deserves its own probe.

## Sources

- **Protocol** — the [core Wayland protocol][p-wayland]: [`wl_display`][p-display] (the
  connection object whose only client-facing requests are `sync` and `get_registry` — no
  user event exists to cite); `xdg-shell` glue as in [the scaffold](./scaffold.md).
- **Client API** — libwayland's [Client API appendix][api-prep]
  (`wl_display_prepare_read` semantics quoted above, including the canonical
  prepare/flush/poll/read-or-cancel usage sample this demo's `pumpOnce` reproduces).
- **Kernel primitives** — [`eventfd(2)`][man-eventfd] (counter-sum semantics),
  [`timerfd_create(2)`][man-timerfd] (expiration-count reads).
- **Spec implemented** — [F05 loop wakeup & external fds][f05]; conventions in
  [the features index](../features/index.md); the readiness-vs-completion frame in
  [concepts][rvc].
- **Code** — [`./examples/f05-loop-wakeup/app.d`](./examples/f05-loop-wakeup/app.d),
  [`./examples/f05-loop-wakeup/c.c`](./examples/f05-loop-wakeup/c.c) (scaffold shim +
  `<sys/eventfd.h>`/`<sys/timerfd.h>`/`<poll.h>`; note: glibc 2.42's `<pthread.h>` is not
  ImportC-able — `linux/types.h` `__int128` — so the thread API comes from druntime's
  `core.sys.posix.pthread`),
  [`./examples/f05-loop-wakeup/instrument.d`](./examples/f05-loop-wakeup/instrument.d).

<!-- References -->

[f05]: ../features/f05-loop-wakeup.md
[rvc]: ../../concepts.md#readiness-vs-completion-windowing
[p-wayland]: https://wayland.app/protocols/wayland
[p-display]: https://wayland.app/protocols/wayland#wl_display
[api-prep]: https://wayland.freedesktop.org/docs/html/apb.html
[man-eventfd]: https://man7.org/linux/man-pages/man2/eventfd.2.html
[man-timerfd]: https://man7.org/linux/man-pages/man2/timerfd_create.2.html
