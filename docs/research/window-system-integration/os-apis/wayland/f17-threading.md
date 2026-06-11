# Wayland F17 — threading probes

What actually happens when you exercise (and deliberately violate)
libwayland's threading model, measured. The demo,
[`./examples/f17-threading/app.d`](./examples/f17-threading/app.d), extends
the [scaffold](./scaffold.md) per the [F17 spec][f17]: six `--probe=N` run
modes, each ending in a verdict line
(`probe n=… result=ok|error|crash|deadlock|silent detail=…`) that survives
_any_ outcome — `wl_display_get_error` is checked after every probe,
`SIGSEGV`/`SIGABRT`/`SIGBUS` handlers turn crashes into a flushed verdict +
`_exit(0)`, and a `SIGALRM` watchdog converts hangs into `result=deadlock`.
The no-argument run (what CI executes) forks every probe **twice**, per the
spec's nondeterminism rule; `examples/f17-threading/run.sh` does the same
with one headless weston per run. Verified Tier A (weston 15.0 headless,
libwayland 1.24): 12/12 runs agreed on every verdict, exit 0 — including the
two runs whose verdict is a genuine, reproducible `deadlock`.

**Last reviewed:** June 11, 2026

## The contract being probed

Wayland is the one platform of the four whose client library _documents_
multi-threading as a designed-for case. The [`wl_display` API
documentation][api-core] (wayland-client-core.h doxygen, rendered in the
[Client API appendix][api-prep]) states the routing rule:

> A wl*display has at least one event queue, called the \_default queue*.
> Clients can create additional event queues with `wl_display_create_queue()`
> and assign `wl_proxy`'s to it. Events occurring in a particular proxy are
> always queued in its assigned queue. A client can ensure that a certain
> assumption, such as holding a lock or running from a given thread, is true
> when a proxy event handler is called by assigning that proxy to an event
> queue and making sure that this queue is only dispatched when the
> assumption holds.

and `wl_event_queue`'s one-line charter: "Event queues allows the events on
a display to be handled in a thread-safe manner." Requests need no ceremony
at all — any thread may marshal on any proxy (marshalling takes the display's
internal mutex). The only sharp edge is the socket read, serialized by the
read-intent protocol the [F05 demo](./f05-loop-wakeup.md) built its loop on:

> Calling `wl_display_prepare_read_queue()` announces the calling thread's
> intention to read and ensures that until the thread is ready to read and
> calls `wl_display_read_events()`, no other thread will read from the file
> descriptor.
>
> — libwayland [Client API, Appendix B][api-prep]

So the documented model is: **no main thread, no global lock, no
init-before-use switch** (X11's `XInitThreads`), no thread-affine windows
(Win32) and no main-thread assert (AppKit). Queues route events; the intent
protocol guards the read. The probes measure each clause — including what
happens when the intent protocol is broken (probe 6, the one that found a
body).

## Probe outcomes (the design-constraints table)

Verdicts from `run.sh` (each probe twice, one headless weston per run; both
runs agreed in every case — full lines quoted in the sections below):

| #   | Probe                                                                       | Legality per [docs][api-core]  | Verdict ×2 | Detail                                                                    |
| --- | --------------------------------------------------------------------------- | ------------------------------ | ---------- | ------------------------------------------------------------------------- |
| 1   | Whole window (registry → toplevel → 30 frames) built on a worker thread     | legal                          | `ok`       | main connects, then only sleeps; worker does everything incl. teardown    |
| 2   | Two threads both in `wl_display_dispatch` on the **same default queue**     | legal                          | `ok`       | 120 frames, 0 errors; events split race-dependently (84/281 … 205/161)    |
| 3   | Worker-owned `wl_event_queue` via a display wrapper, dispatched in parallel | legal — **the designed model** | `ok`       | 50/50 worker sync round-trips overlapping 31 main-thread frames           |
| 4   | attach/damage/frame/commit on the shared `wl_surface` from a render thread  | legal                          | `ok`       | 100/100 commits presented, `wl_display_get_error` = 0, both runs          |
| 5   | One `wl_display` connection per thread                                      | legal (nothing is shared)      | `ok`       | 2/2 threads connected/mapped/rendered/closed independently                |
| 6   | `read_events` without `prepare_read` while another thread holds the intent  | **violation**                  | `deadlock` | silent intent theft → reader-count off-by-one → connection wedges forever |

## Probe notes

### Probe 1 — the window has no home thread

```text
75 f17_wayland step name=wl_display_connect thread=main
134 f17_wayland thread=worker action=setup_window_start
287 f17_wayland first_configure tag=main size=640x480
499274 f17_wayland thread=worker action=done ok=1 frames=30 commits=31
502763 f17_wayland probe n=1 result=ok detail=window_and_30_frames_entirely_on_worker=1 connect_thread=main protocol_error=0
```

The `wl_display` is connected on the main thread, which then **sleeps**; the
worker performs the registry roundtrip, all binds, the surface/xdg tree, the
initial commit, the configure/ack dance, 31 buffer commits, 30 dispatched
frame callbacks, and the full teardown — on a connection it did not create.
No registration call, no per-object affinity, no error. This is the contrast
anchor for the row: the same choreography is an assertion failure on AppKit
and silent corruption (historically) on un-initialized Xlib.

### Probe 2 — concurrent dispatch of one default queue is legal but unordered

```text
2001133 f17_wayland thread_done thread=dispatcher_a events=140 calls=47
2006181 f17_wayland thread_done thread=dispatcher_b events=225 calls=75
2011198 f17_wayland probe n=2 result=ok detail=events_a=140 events_b=225 frames=120 frames_handled_on_a=46 on_b=74 sync_wakes_to_unblock=2 protocol_error=0
```

Two threads loop `wl_display_dispatch(display)` on the default queue while
the main thread only sleeps; frame callbacks (≈60 Hz) keep events flowing.
This is safe _because_ `wl_display_dispatch` is built on the read-intent
protocol internally — the loser of the prepare race parks on a condition
variable instead of double-reading the socket. All 120 expected frames
arrived exactly once, `wl_display_get_error` stayed 0 in all four runs. Two
caveats are the finding:

- **The split is race-dependent.** Across four runs the event distribution
  ranged from 84/281 to 205/161 — handler invocations migrate between
  threads arbitrarily (frame-callback handlers ran 27–74 times on each).
  Sharing the default queue between threads is correct but useless for
  routing — and any handler state must already be thread-safe, since libwayland
  releases its mutex around each handler invocation.
- **A thread blocked in `wl_display_dispatch` can only be woken by an
  event.** Shutdown required feeding `wl_display.sync` doorbells until both
  dispatchers returned (`sync_wakes_to_unblock=2`) — the same
  release-by-feeding hazard as X11 probe 3's `XNextEvent`, just milder
  because Wayland clients _can_ cheaply self-generate an event (`sync`).

### Probe 3 — the headline: per-thread event queues, the designed answer

```text
1049 f17_wayland thread=worker action=queue_and_wrapper_created
506786 f17_wayland thread=worker action=done syncs=50
515627 f17_wayland probe n=3 result=ok detail=worker_syncs=50/50 main_frames=31 overlap=1 worker_window_us=1121..496719 protocol_error=0
```

The worker builds the documented pattern in three calls and ~10 lines:

```d
auto queue = wl_display_create_queue(display);
auto wrapper = cast(wl_display*) wl_proxy_create_wrapper(display);
wl_proxy_set_queue(cast(wl_proxy*) wrapper, queue);
// objects created via `wrapper` are BORN on the worker's queue:
auto cb = wsi_display_sync(wrapper);          // done event -> worker's queue
wl_display_dispatch_queue(display, queue);    // worker's own blocking pump
```

[`wl_proxy_create_wrapper`][api-core] exists precisely to make the queue
assignment race-free: setting the queue on a _wrapper_ before creating
objects through it guarantees the new proxy's events can never land on the
default queue first. The worker chained 50 `wl_display.sync` round-trips
through its private queue via `wl_display_dispatch_queue` **while** the main
thread sat in `wl_display_dispatch` rendering 31 frames on the default queue
— one connection, two concurrent blocking dispatchers, zero coordination
between them, and each handler ran exactly on the thread that owns its
queue. (The header's own worked example of this pattern is Mesa's
`eglSwapBuffers`, which blocks on a frame callback in a private queue so it
cannot re-enter application handlers.) This — not locks, not thread
confinement — is Wayland's threading story: **queues route events to the
thread that dispatches them**.

The demo syncs against a display wrapper rather than a second surface
because only the compositor decides when a surface's frame callback fires —
a role-less worker surface would never be presented; `sync` round-trips
exercise the identical queue machinery deterministically.

### Probe 4 — render thread on the shared surface: just works

```text
1003 f17_wayland thread=render action=start frames_target=100
1664714 f17_wayland thread=render action=done commits=100 frames_acked=100
1664792 f17_wayland probe n=4 result=ok detail=commits_from_render_thread=100/100 frame_callbacks=100 protocol_error=0
```

The worker paints the `wl_shm` buffer and issues
`attach`/`damage_buffer`/`frame`/`commit` on the **same `wl_surface` proxy**
the main thread created — no wrapper, no private queue — for 100 frames,
while main dispatches. Requests are thread-safe on any proxy, and surface
state is double-buffered server-side (latched atomically at `commit`), so
there is nothing to corrupt client-side: 100/100 commits presented, zero
protocol errors, both runs. Two pieces of mandatory ceremony, both mirroring
X11 probe 4:

- **Each thread flushes its own requests** (`wl_display_flush` after every
  worker commit). The main thread was already asleep inside its own `poll`
  when the worker marshalled — buffered requests do not leave the process
  because some _other_ thread once dispatched.
- **The acks come back on the dispatching thread.** The worker's frame
  callbacks and `wl_buffer.release` events are dispatched by _main_ (they
  live on the default queue); the worker throttles by watching counters main's
  handlers publish. A render thread that wants its acks delivered _to
  itself_ should put its callbacks on a private queue — i.e. combine probes
  3 and 4.

### Probe 5 — connection per thread: the trivially safe model

```text
153 f17_wayland thread_connect tag=t0 fd=3
157 f17_wayland thread_connect tag=t1 fd=4
331888 f17_wayland probe n=5 result=ok detail=threads_completed=2/2 model=connection_per_thread
```

Each thread runs `wl_display_connect` → full window → 20 frames → teardown →
`wl_display_disconnect`, sharing nothing. The X11 display-per-thread analog,
with the same trade: per-connection buffers and a compositor-side client
object each, and no cross-connection object sharing at all (a `wl_buffer`
from connection A cannot attach to a surface from connection B). On Wayland
this model buys nothing probe 3 doesn't already provide more cheaply — it
exists, it works, queues make it unnecessary.

### Probe 6 — the violation: stolen read intent wedges the connection forever

```text
127 f17_wayland thread=holder action=prepare_read_acquired
1182 f17_wayland thread=violator action=read_events_returned ret=0 took_us=3
600208 f17_wayland thread=holder action=cancel_read_returned
4604304 f17_wayland probe n=6 result=deadlock detail=health_roundtrip_hung_after_violation
```

Thread A acquires the read intent (`wl_display_prepare_read` returns 0) and
holds it; thread B then calls `wl_display_read_events` **without ever
preparing** — the 1:1 pairing the contract demands, broken. Nothing asserts.
B's call _succeeds in 3 µs_: in [`wayland-client.c`][src-client] both
`read_events` and `cancel_read` simply decrement `display->reader_count` and
perform the socket read when it reaches zero — so B silently consumed A's
registration and did A's read. When A later calls `wl_display_cancel_read`,
the count goes to **−1**, and the connection is permanently wedged: every
future reader's `prepare_read` brings the count to 0, its `read_events`
decrements back below zero, concludes "another reader will do the actual
read", and waits on a condition variable for a `read_serial` bump that no
thread will ever produce. The health-check `wl_display_roundtrip` hung until
the watchdog fired — both runs, deterministically. No error, no `EPROTO`,
no message: **the cost of violating the intent protocol is an undebuggable
silent freeze of the whole connection**, which is exactly why the contract
sentence "must be followed by either `wl_display_read_events` or
`wl_display_cancel_read`" — _by the same thread, exactly once_ — deserves
framework-level enforcement rather than convention.

## Crash survival (the spec's requirement, even though nothing crashed)

Every probe installs, before touching libwayland: fatal-signal handlers
(`SIGSEGV`/`SIGBUS`/`SIGABRT` → `crash` verdict via async-signal-safe
`snprintf`+`write(2)`, then `_exit(0)`) and a 12-second `alarm` → `deadlock`
verdict (re-armed at 4 s around probe 6's health roundtrip, which is where
it actually fired). Probes 2 and 6 additionally emit their verdict _before_
attempting to join threads that may be unjoinable, then `_exit(0)`. The
no-argument mode forks each probe so a wedged libwayland (probe 6 leaves
one behind by design) can never poison the next probe. **Deadlock probes
still exit 0 — deadlocking is their job.**

## What a framework can promise on Wayland

- **No main-thread rule, no global lock, no init ordering.** Connect on one
  thread, window on another, render on a third — all measured legal with
  zero ceremony beyond per-thread flushes (probes 1, 4).
- The designed routing primitive is the **per-thread `wl_event_queue` +
  proxy wrapper** (probe 3): a worker that wants events delivered on itself
  assigns its proxies to its own queue and dispatches that queue. This is
  strictly better than both sharing the default queue (probe 2's arbitrary
  handler migration) and connection-per-thread (probe 5's isolation tax).
- The one rule that **must** be kept is the read-intent pairing — prepare,
  then exactly one of read/cancel, on the same thread. Probe 6 shows the
  failure mode is a silent, permanent, connection-wide deadlock with no
  diagnostic whatsoever; a framework should own the prepare/read/cancel
  sequence inside its loop (the [F05](./f05-loop-wakeup.md) `pumpOnce`
  shape) and never expose it raw.
- Cross-platform: combined with [X11's conclusion](../x11/f17-threading.md)
  ("create and pump anywhere; the affinity unit is the `Display`"), Wayland
  narrows nothing — the portable contract is still dictated by AppKit/Win32:
  **create and pump on one designated thread per window; render from other
  threads with platform-specific ceremony** (Wayland's ceremony: flush your
  own requests, and take a private event queue if you want your acks
  delivered to you). Wayland is the platform where that designated thread is
  pure framework policy, not a platform demand.

## Build and run

Tier A, from the repo root — the no-argument run forks all six probes twice
(what CI executes; needs `WAYLAND_DISPLAY` pointing at any compositor):

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/wayland/examples/f17-threading
nix develop -c dub run --root=docs/research/window-system-integration/os-apis/wayland/examples/f17-threading
```

`examples/f17-threading/run.sh` runs each probe twice against its own
headless weston (socket `wsi-w9`, private `XDG_RUNTIME_DIR`) instead, so
probe 6's wedged connection can never contaminate a later probe;
`--probe=N` runs one probe once. No reachable compositor prints
`SKIP: no Wayland compositor` and exits 0. All probes are self-bounded;
`WSI_AUTO_EXIT=1` is accepted for uniformity but changes nothing.

## Sources

- **[libwayland Client API][api-prep]** (Appendix B; the same doxygen ships
  in `wayland-client-core.h` [@1.24][api-core]) — the `wl_display`
  queueing/dispatching model, `wl_event_queue` ("handled in a thread-safe
  manner"), `wl_display_create_queue`, `wl_proxy_set_queue`,
  `wl_proxy_create_wrapper` (race-free queue assignment),
  `wl_display_dispatch_queue`, and the `wl_display_prepare_read` /
  `read_events` / `cancel_read` intent contract (all quotes above).
- **[`src/wayland-client.c`][src-client]** — `reader_count` /
  `read_serial` / condition-variable mechanics behind probe 6's
  deterministic deadlock.
- **The [core Wayland protocol][p-wayland]** — `wl_display.sync` (probe 2's
  wake doorbell, probe 3's round-trip unit), `wl_surface` double-buffered
  state (probe 4's server-side safety net).
- **This survey** — the [F17 feature spec][f17]; the
  [Wayland scaffold](./scaffold.md) (window machinery, instrument format);
  the [F05 demo](./f05-loop-wakeup.md) (the single-reader prepare-read
  loop these probes generalize); the X11 counterpart
  [../x11/f17-threading.md](../x11/f17-threading.md); the runnable source
  [`./examples/f17-threading/app.d`](./examples/f17-threading/app.d) (plus
  the `c.c` ImportC shim, `instrument.d`, and `run.sh` alongside it).

<!-- References -->

[f17]: ../features/f17-threading.md
[api-prep]: https://wayland.freedesktop.org/docs/html/apb.html
[api-core]: https://gitlab.freedesktop.org/wayland/wayland/-/blob/main/src/wayland-client-core.h
[src-client]: https://gitlab.freedesktop.org/wayland/wayland/-/blob/main/src/wayland-client.c
[p-wayland]: https://wayland.app/protocols/wayland
