# X11 F17 — threading probes

What actually happens when you break (and obey) Xlib's threading rules,
measured. The demo,
[`./examples/f17-threading/app.d`](./examples/f17-threading/app.d), extends
the [scaffold](./scaffold.md) per the [F17 spec][f17]: six `--probe=N` run
modes, each ending in a verdict line
(`probe n=… result=ok|error|crash|deadlock|silent detail=…`) that survives
_any_ outcome — `XSetErrorHandler` counts protocol errors,
`XSetIOErrorHandler` plus `SIGSEGV`/`SIGABRT`/`SIGBUS` handlers turn crashes
into a flushed verdict + `_exit(0)`, and a `SIGALRM` watchdog converts hangs
into `result=deadlock`. The no-argument run (what CI executes) forks every
probe **twice**, per the spec's nondeterminism rule;
`examples/f17-threading/run.sh` does the same with one Xvfb per run. All 12
runs: exit 0.

**Last reviewed:** June 11, 2026

## The contract being probed

The [Xlib manual][xlib] states the rule in two sentences:

> The `XInitThreads` function initializes Xlib support for concurrent
> threads. This function must be the first Xlib function a multi-threaded
> program calls, and it must complete before any other Xlib call is made.

One `Display*` is one socket, one output buffer, one event queue, and one
sequence counter — `XInitThreads` retrofits a per-`Display` lock
(`XLockDisplay`/`XUnlockDisplay` are its public face: "locks out all other
threads from using the specified display"). Folklore says violating the
must-be-first rule yields the classic `Xlib: unexpected async reply`
corruption, an XIO connection abort, or a crash.

## The headline finding: the violation no longer exists on Linux

Probes 1 (no `XInitThreads` at all) and 6 (called only _after_
`XOpenDisplay`) hammer one unlocked-by-the-program `Display` from two
threads — a worker creating a window then storming buffered requests
(`XStoreName`), round-trips (`XInternAtom`, `XGetGeometry`), and
self-addressed events, while the main thread pumps events and issues its own
buffered `XNoOp`s. ~240 000 requests per run, twice per probe:

```text
14466 f17_x11 step name=XOpenDisplay fd=3 xinitthreads=no
14561 f17_x11 thread=worker action=window_created xid=0x200001
1214781 f17_x11 thread=worker action=done roundtrips=239520
1214834 f17_x11 probe n=1 result=silent detail=no_corruption_observed_this_run events_on_main=1873 (nondeterministic)
```

Zero Xlib errors, zero async-reply complaints, every event intact — every
run. The reason is not luck: the linked library is `libX11 1.8.13`, and
since [libX11 1.8 (2022)][announce] the build system enables a **thread
safety constructor** by default. From [`configure.ac`][configureac]:

```text
AC_ARG_ENABLE(thread-safety-constructor,
              AS_HELP_STRING([--disable-thread-safety-constructor],
                             [Controls mandatory thread safety support]),
              [USE_THREAD_SAFETY_CONSTRUCTOR=$enableval],
              [USE_THREAD_SAFETY_CONSTRUCTOR="yes"])
```

and the implementation, verbatim from [`src/globals.c`][globalsc]:

```c
#ifdef USE_THREAD_SAFETY_CONSTRUCTOR
__attribute__((constructor)) static void
xlib_ctor(void)
{
    XInitThreads();
}
```

`XInitThreads` runs from an ELF constructor **before `main`**, so it is
always "the first Xlib function called" no matter what the program does, and
probe 6's deliberately-late call is a harmless no-op (it returns 1; the
locks already exist). On top of that, this libX11 is the XCB transport
(`_XReply`/event reads go through libxcb, which has its own internal
locking), so even the wire-level interleaving the old folklore describes has
no unlocked path left. **On a current Linux stack the probe-1 violation is
unobservable** — `result=silent` is the honest verdict, kept
`(nondeterministic)` because nothing was _proven_ safe, and because the same
binary against a `--disable-thread-safety-constructor` build (Nix would make
this easy) or a pre-1.8 distro libX11 is exactly where the classic crash
lives. A portable framework cannot rely on the constructor: macOS/BSD
ship other builds, and the flag is distro policy, not API.

## Probe outcomes (the design-constraints table)

Verdicts from `run.sh` (each probe twice, one Xvfb per run; both runs agreed
in every case — full lines quoted in the sections below):

| #   | Probe                                                           | Legality per [Xlib][xlib] | Verdict ×2 | Detail                                                                      |
| --- | --------------------------------------------------------------- | ------------------------- | ---------- | --------------------------------------------------------------------------- |
| 1   | Window created on worker, no `XInitThreads`, main pumps         | **violation**             | `silent`   | ~240 k unlocked requests, 0 errors — libX11 ≥ 1.8 self-arms (see above)     |
| 2   | Same, `XInitThreads` first                                      | legal                     | `ok`       | window created on worker; its `MapNotify`/`Expose` arrive on the main pump  |
| 3   | Two threads sharing one `Display`, both blocked in `XNextEvent` | legal                     | `ok`       | serialized AND starved: thread_a=100, thread_b=0 of 100 events              |
| 4   | `XShmPutImage` + `XFlush` from a render thread, main pumps      | legal                     | `ok`       | 60/60 completion events — delivered to the _pumping_ thread, not the issuer |
| 5   | One `Display` per thread, **no** `XInitThreads`                 | legal (nothing is shared) | `ok`       | 2/2 threads created/mapped/drew/closed independently                        |
| 6   | `XInitThreads` _after_ `XOpenDisplay`, then the probe-1 storm   | **violation**             | `silent`   | late call returns 1; harmless only because the constructor already ran      |

## Probe notes

### Probe 2 — window off-main is legal and event routing follows the pump

```text
2433433 f17_x11 step name=XInitThreads ret=1 order=first
3653113 f17_x11 probe n=2 result=ok detail=window_created_on_worker events_on_main=1904
```

X11 has no "window-owning thread" concept at all (contrast Win32's
thread-affine message queues and AppKit's main-thread assertion): the window
is a server-side resource on a _connection_, and events go to whichever
thread reads that connection. The platform constraint a framework inherits
here is per-`Display`, not per-thread.

### Probe 3 — two readers: serialized, and one starves completely

```text
5054254 f17_x11 probe n=3 result=ok detail=sent=100 received=100 thread_a=100 thread_b=0 sentinels_to_unblock=2 xlib_errors=0
```

With locking on, two threads blocked in `XNextEvent` on one `Display` are
**correct** — all 100 self-addressed `ClientMessage`s arrived exactly once,
no tearing, no double-delivery. But distribution is _not_ fair: in every run
one thread consumed all 100 events while the other never woke (which thread
wins is whichever re-acquires the display lock first; the loser parks in
Xlib's internal condition wait indefinitely). Both runs also needed exactly
2 sentinel events to unblock the two readers at shutdown — a thread stuck
in `XNextEvent` can only be released by _feeding it an event_ (or killing
the connection). Sharing one `Display` between event-consumer threads is
legal but useless as a work-distribution scheme — and a shutdown hazard.

### Probe 4 — render thread with `XShmPutImage`

```text
5433256 f17_x11 probe n=4 result=ok detail=puts_from_render_thread=60 completions_on_main=60 other_events_on_main=2 xlib_errors=0
```

The [MIT-SHM][shm-spec] completion contract from the [scaffold](./scaffold.md)
gets a threading wrinkle: the worker issues `XShmPutImage(send_event=True)`
and its own `XFlush` (each thread must flush its own requests — buffered
requests do not leave the process just because _some other_ thread later
makes a call), but the **completion events land on whichever thread pumps**,
here the main one. All 60 arrived. A render thread that wants to throttle on
completion therefore needs a channel back from the event-pumping thread —
the put/ack pair spans two threads. That cross-thread ack plumbing (or
`XFlush`-then-sleep pacing, as the probe does) is the "platform-specific
ceremony" of the F17 expected contract.

### Probe 5 — one `Display` per thread: the always-safe model

```text
5650402 f17_x11 probe n=5 result=ok detail=threads_completed=2/2 xlib_errors=0 no_xinitthreads=1
```

Each thread opens its own connection, creates/maps its own window, blocks in
`XNextEvent` on its own fd, draws, and tears down — **without**
`XInitThreads` (deliberately; nothing is shared, so per the manual "Xlib
thread initialization is not required" when access is otherwise exclusive).
This is the model that needs no global locks, no must-be-first init, and no
cross-thread ack plumbing; its costs are one socket + buffers per thread and
the fact that two connections share nothing (atoms and `XID`s are
server-global, but flushes are not — see the [F16 demo](./f16-clipboard-dnd.md)
for that cross-connection visibility trap, exploited there on purpose).

## Crash survival (the spec's requirement, even though nothing crashed)

Every probe installs, before touching Xlib: an `XSetErrorHandler` (logs and
counts protocol errors, returns — verdict becomes `error`), an
`XSetIOErrorHandler` (Xlib is about to `exit()`; the handler writes the
`crash` verdict with `write(2)` and `_exit(0)` — it must not return), fatal
signal handlers (`SIGSEGV`/`SIGBUS`/`SIGABRT` → `crash` verdict, async-
signal-safe `snprintf`+`write`, `_exit(0)`), and an 8-second `alarm` →
`deadlock` verdict. The no-argument mode additionally `fork`s each probe so
a corrupted child Xlib can never poison the next probe. This machinery is
what makes "run the violation twice and report whatever happens" a safe CI
step: **crash probes still exit 0 — crashing is their job.**

## What a framework can promise on X11

- **No main-thread requirement exists.** Create, pump, and render on any
  thread — the unit of affinity is the `Display` connection, not a thread.
- The portable safe contract is still **"one designated thread per
  `Display`, or `XInitThreads` before anything else"**. The libX11 1.8
  constructor makes the second half automatic on modern Linux, but it is a
  build-time distro choice, not part of the platform API — a framework
  should call `XInitThreads` first anyway (calling it when the constructor
  already ran is a no-op returning 1, as probe 6 shows).
- Don't share one `Display`'s event stream between threads (probe 3's
  starvation) and don't expect another thread's flush to send your requests
  (probe 4). Multi-window multi-thread designs are cleanest as
  display-per-thread (probe 5), which sidesteps every rule above.

## Build and run

Tier A, from the repo root — the no-argument run forks all six probes twice
(what CI executes):

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f17-threading
nix develop -c xvfb-run -a \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f17-threading
```

`examples/f17-threading/run.sh` runs each probe twice in its own Xvfb
instead (server-state isolation); `--probe=N` runs one probe once. No
reachable display prints `SKIP: no X11 display` and exits 0.

## Sources

- **[Xlib — C Language X Interface][xlib]** — `XInitThreads`
  (must-be-first contract, return value, "not required" exemption),
  `XLockDisplay`/`XUnlockDisplay` (all quotes above).
- **[libX11 `configure.ac`][configureac]** and **[`src/globals.c`][globalsc]**
  — the default-on `USE_THREAD_SAFETY_CONSTRUCTOR` and the
  `__attribute__((constructor))` that calls `XInitThreads` before `main`;
  shipped in [libX11 1.8][announce] (April 2022). The dev-shell library is
  `libx11-1.8.13`.
- **[The MIT Shared Memory Extension][shm-spec]** — the
  `XShmPutImage`/completion-event contract probe 4 stretches across threads.
- **This survey** — the [F17 feature spec][f17]; the
  [X11 scaffold](./scaffold.md) (poll loop, SHM backbuffer, instrument
  format); the runnable source
  [`./examples/f17-threading/app.d`](./examples/f17-threading/app.d)
  (plus the `c.c` ImportC shim, `instrument.d`, and `run.sh` alongside it).

<!-- References -->

[f17]: ../features/f17-threading.md
[xlib]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
[configureac]: https://gitlab.freedesktop.org/xorg/lib/libx11/-/blob/master/configure.ac
[globalsc]: https://gitlab.freedesktop.org/xorg/lib/libx11/-/blob/master/src/globals.c
[announce]: https://lists.x.org/archives/xorg-announce/2022-April/003162.html
[shm-spec]: https://www.x.org/releases/current/doc/xextproto/shm.html
