# AppKit F17 — threading probes

What actually happens when you break (and obey) AppKit's threading rules,
measured. The demo,
[`./examples/f17-threading/app.d`](./examples/f17-threading/app.d), extends
the [scaffold](./scaffold.md) per the [F17 spec][f17]: five `--probe=N` run
modes, each ending in a verdict line
(`probe n=… result=ok|error|crash|deadlock|silent detail=…`) that survives
_any_ outcome — fatal-signal handlers (`SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGABRT`/
`SIGTRAP`) and an `NSUncaughtExceptionHandler` turn crashes into a flushed
verdict + `_exit(0)` (capturing AppKit's exact assert text on the way), and a
12 s `SIGALRM` watchdog converts hangs into `result=deadlock`. The no-argument
run (what CI executes) spawns every probe **twice** as a fresh **fork+exec'd**
child — plain fork-per-probe, the X11 demo's trick, is not available here:
using Objective-C between `fork` and `exec` is forbidden on macOS — so a
crashed probe can never poison the next and the parent always reports. All 10
runs: exit 0, verdicts identical across both runs of every probe.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn`
(aarch64-darwin, macOS 26.3.1, LDC 1.41.0) over SSH with the console session
**locked** (`session screen_locked=1` in every probe log) — exactly as the
[F17 spec][f17] anticipates, the assert-on-spawn outcomes need no visible
window. Workers are raw `pthread_create` threads (no `NSThread`, so Cocoa was
never formally "put into multithreaded mode" — the outcomes below were
deterministic regardless).

## The contract being probed — and where the docs are stale

Apple's [Thread Safety Summary][threadsafety] is the written contract:
`NSWindow` "and all of its descendants" are thread-unsafe, `NSView` and
`NSCell` descendants are **main thread only**, and the event path belongs to
the main thread. But its _Window Restrictions_ section — last updated 2014 —
still says, verbatim:

> You can create a window on a secondary thread. The Application Kit ensures
> that the data structures associated with a window are deallocated on the
> main thread to avoid race conditions.

**Modern AppKit rejects that sentence at runtime.** Probes 1 and 2 show the
2026 reality: window creation off-main is not undefined behavior, it is an
immediate, deterministic `NSInternalInconsistencyException`. The documented
escape hatches that _do_ still hold are also quoted there — and probes 3–5
verify each one:

> If you want to use a thread to draw to a view, bracket all drawing code
> between the `lockFocusIfCanDraw` and `unlockFocus` methods of `NSView`. …
> [A secondary thread] must not [redraw] using methods like `display`,
> `setNeedsDisplay:` … Instead, it should … call those methods using the
> `performSelectorOnMainThread:withObject:waitUntilDone:` method instead. …
> You can call the `postEvent:atStart:` method of `NSApplication` from a
> secondary thread to post an event to the main thread's event queue.

## The headline: the exact assert, captured twice per probe

Probe 1 (worker thread creates the `NSWindow`, main thread pumps) — the
exception text verbatim, the throw-site stack abridged to the relevant frames:

```text
6     APPKIT_F17 probe_start n=1 main_thread=1
34144 APPKIT_F17 step name=NSWindow_init thread=worker main_thread=0
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
reason: 'NSWindow should only be instantiated on the main thread!'
*** First throw call stack:
(
    3   AppKit    -[NSWindow _initContent:styleMask:backing:defer:contentView:] + 260
    4   AppKit    -[NSWindow initWithContentRect:styleMask:backing:defer:] + 48
    5   demo      _D3app12createWindowFPxaZv + 184
    6   demo      probe1Worker + 44
)
libc++abi: terminating due to uncaught exception of type NSException
35239 APPKIT_F17 probe n=1 result=crash detail=fatal_signal_6_abort(see_exception_log_above)
```

The check sits in `-[NSWindow _initContent:…]` itself — it fires **before any
window exists**, ~1 ms into the off-main call, with the run-loop state
irrelevant: probe 2 (window created on a worker spawned from a timer tick
_after_ `[NSApp run]` was already pumping on main) dies identically, 336 ms
in. Because the exception is thrown on a _secondary_ thread, the process-wide
`NSUncaughtExceptionHandler` never runs — the ObjC runtime prints the
exception and calls `abort()`, and only the demo's `SIGABRT` handler gets the
verdict out. **A framework's crash reporting must not rely on the uncaught-
exception handler for off-main AppKit violations.** No "create off-main, then
dispatch the rest" hybrid is possible: the constructor is the assert.

## Probe outcomes (the design-constraints table)

Verdicts from the forked no-argument run (each probe twice; both runs agreed
in every case):

| #   | Probe                                                                                              | Legality per [docs][threadsafety]                                                   | Verdict ×2 | Detail                                                                                                                     |
| --- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------- |
| 1   | `NSWindow` created on a worker, main pumps                                                         | docs _still say allowed_ (2014)                                                     | `crash`    | `NSInternalInconsistencyException: NSWindow should only be instantiated on the main thread!`                               |
| 2   | Worker creates the window **after** `[NSApp run]` starts                                           | docs _still say allowed_ (2014)                                                     | `crash`    | identical exception, identical throw site — run-loop state irrelevant                                                      |
| 3   | Worker computes; UI marshaled via `performSelectorOnMainThread:` and `dispatch_async` (main queue) | legal — **the sanctioned model**                                                    | `ok`       | both callbacks ran with `pthread_main_np()=1`                                                                              |
| 4   | Render from a worker: marshaled `setNeedsDisplay:` vs direct calls                                 | marshaled: legal; direct `setNeedsDisplay:`: forbidden; `lockFocusIfCanDraw`: legal | `silent`   | marshaled → `drawRect:` on main; direct dirty-mark → **silently ignored**; `lockFocusIfCanDraw`=1, draw runs on the worker |
| 5   | `NSPasteboard` write/read + `postEvent:atStart:` from a worker                                     | legal (`postEvent:` explicitly)                                                     | `ok`       | pasteboard round-trip ok off-main; posted event received by the **main** pump                                              |

## Probe notes

### Probe 3 — both marshaling routes land on main

```text
34726 APPKIT_F17 step name=worker_work_done sum=499999500000 main_thread=0
61698 APPKIT_F17 marshal route=performSelectorOnMainThread main_thread=1
80691 APPKIT_F17 marshal route=dispatch_async_main_queue main_thread=1
80697 APPKIT_F17 probe n=3 result=ok detail=performSelectorOnMainThread_on_main=1 dispatch_async_on_main=1
```

Both the Cocoa-era route (`performSelectorOnMainThread:withObject:waitUntilDone:`)
and the [libdispatch][dispatch] route (`dispatch_async_f` onto
`&_dispatch_main_q` — callable from D as a plain `extern (C)` global) deliver
on the main thread within ~30 ms, _requiring_ `[NSApp run]` (or any main-queue
run loop) to be pumping — the main queue is drained by the main run loop, so a
blocked main thread starves both routes.

### Probe 4 — render off-main: one supported lane, one silent failure

```text
71591   APPKIT_F17 render route=worker_buffer_fill fill=0.9 main_thread=0
103260  APPKIT_F17 render route=marshaled_setNeedsDisplay main_thread=1
108357  APPKIT_F17 draw_rect n=2 main_thread=1 fill=0.90
681623  APPKIT_F17 render route=direct_setNeedsDisplay_from_worker main_thread=0
1291762 APPKIT_F17 render route=direct_lockFocusIfCanDraw_from_worker main_thread=0
1291865 APPKIT_F17 render lockFocusIfCanDraw=1
1291895 APPKIT_F17 render direct_cgcontext_draw=done from_worker=1
1292169 APPKIT_F17 draw_rect n=3 main_thread=0 fill=0.50
```

Three distinct outcomes from one probe:

1. **Marshaled** (worker fills the CPU buffer, `dispatch_async` flips the
   dirty flag on main): `drawRect:` on the main thread ~5 ms later. This is
   the F17 "render anywhere with ceremony" lane — the _pixels_ are produced
   off-main, only the dirty-mark crosses threads.
2. **Direct cross-thread `setNeedsDisplay:`**: no crash, no warning, and
   **no redraw** — the dirty mark sat unserviced for 600 ms while the main
   run loop kept ticking (no `drawRect:` between 108 ms and 1292 ms). The
   documented prohibition manifests as the worst failure mode: a silent no-op.
3. **Direct `lockFocusIfCanDraw` + `CGContext` fill from the worker**:
   returned `1` (AppKit honored its documented drawing-bracket contract even
   in 2026), the Quartz calls executed without complaint — and as a side
   effect, the _pending_ dirty region from (2) was then serviced **on the
   worker** (`draw_rect n=3 main_thread=0`): the queued `drawRect:` runs on
   whichever thread next forces display, not on main. Two AppKit callbacks of
   the same view ran on two different threads in one run. (Per the docs, a
   secondary-thread drawer must also `flushGraphics` manually — without it,
   nothing composites; with the console locked, compositing is unobservable
   either way.)

### Probe 5 — pasteboard and event posting are genuinely thread-free

```text
36184 APPKIT_F17 step name=pasteboard_from_worker main_thread=0 change_count=1323 set_ok=1 readback=f17-worker-thread
36198 APPKIT_F17 step name=postEvent_from_worker main_thread=0
63461 APPKIT_F17 event kind=worker_posted_event_received main_thread=1 data1=42
```

`NSPasteboard` `clearContents`/`setString:forType:`/`stringForType:` all work
from a raw pthread (the pasteboard server connection has no thread affinity —
consistent with the [F16 findings](./f16-clipboard-dnd.md)), and
`postEvent:atStart:` from the worker is received by the **main** thread's
pump — the documented cross-thread wakeup, the same role
`wl_display`-wrapper wakeups and `PostMessage` play elsewhere (cf.
[F05 loop-wakeup](./f05-loop-wakeup.md)).

## The platform × probe table (the four-platform threading story)

Combining this row with the measured [X11](../x11/f17-threading.md),
[Wayland](../wayland/f17-threading.md), and [Win32](../win32/f17-threading.md)
F17 columns — this cell completes the four-platform story:

| Probe                       | macOS/AppKit (measured)                            | X11 (measured)                                                    | Wayland (measured)                      | Win32 (measured, `A[wine]`)                           |
| --------------------------- | -------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------- | ----------------------------------------------------- |
| Create window off-main      | **crash** — deterministic `NSException`            | `ok`/`silent` — no thread affinity at all                         | `ok` — designed for it                  | `ok` — creating thread owns its messages              |
| Pump events off the "owner" | events are main-thread-only (docs + probe 2)       | events go to whichever thread reads the socket                    | per-thread `wl_event_queue` — by design | impossible: queues are creator-affine (main saw 0/10) |
| Render from a second thread | marshaled dirty-mark, or `lockFocusIfCanDraw` lane | `XShmPutImage` from worker `ok` (acks land on the pumping thread) | `commit` from worker `ok`               | `BitBlt` from a non-owning thread, 100/100            |
| Cross-thread wakeup/data    | `postEvent:` + main-queue `dispatch_async` `ok`    | self-addressed events / `XInitThreads` locks                      | thread-safe core, per-queue dispatch    | `PostMessage` <1 ms (`SendMessage` can deadlock)      |

**The narrowest-contract line.** macOS is the strictest platform, confirmed:
it is the only one of the four where window creation and event dispatch are
pinned to _the_ main thread (`pthread_main_np() == 1`) — not "a designated
thread per window" (Win32's measured model: any thread may create, but the
creator is permanently the pumping thread), not "any thread with locking"
(X11), not "any thread, period" (Wayland). The [F17 spec][f17]'s expected framework contract — **"create and
pump on one designated thread; render anywhere with platform-specific
ceremony"** — must therefore be tightened on macOS to **"create and pump on
the process's first thread"**: a framework that lets the user pick the UI
thread (the [Win32 column](../win32/f17-threading.md)'s strictest shape) works
on the other three platforms and deterministically crashes here.
The "render anywhere" half _is_ verified on all four platforms —
macOS's ceremony being "marshal the dirty-mark; never touch view state
directly" (the supported lane), with `lockFocusIfCanDraw` as a still-honored
but legacy direct path. Probes 1/2's corollary: violations are at least
_fail-fast_ (an exception in the constructor), except the one that isn't —
the cross-thread `setNeedsDisplay:` silent no-op is the trap a framework must
guard with its own thread asserts, because AppKit won't say a word.

## Crash survival mechanics (what the spec requires)

Every probe installs, before touching AppKit: handlers for the five fatal
signals (async-signal-safe `snprintf` + `write(2)` of the verdict, then
`_exit(0)`), an `NSUncaughtExceptionHandler` (which probes 1/2 proved
_insufficient_ for secondary-thread throws — the `SIGABRT` handler is the one
that actually fires), and a 12 s `alarm` → `deadlock` verdict. The no-argument
parent never touches Objective-C itself; it `fork`+`execv`s its own binary
with `--probe=N` (macOS kills ObjC-after-fork without exec) and logs every
child's exit status:

```text
105262 APPKIT_F17 probe_run n=1 run=2 exit_normal=1 code=0 term_signal=0
…
8568124 APPKIT_F17 all_probes_done runs=10
```

**Crash probes still exit 0 — crashing is their job.**

## Build and run

`A[ssh]` on the Mac (dub is avoided on this host — it fork-ENOMEMs; invoke
`ldc2` directly, with [`objective-d`][objd]'s runtime modules on the command
line):

```bash
OBJD=$HOME/.dub/packages/objective-d/1.1.2/objective-d/source
ldc2 -I$OBJD app.d instrument.d $OBJD/objc/autorelease.d $OBJD/objc/rt.d \
    $OBJD/objc/block.d -L-framework -LCocoa -of=./demo
./demo               # all five probes, fork+exec'd, twice each (exit 0)
./demo --probe=1     # one probe, in-process (the crash log quoted above)
```

Headless (no WindowServer): prints `SKIP:` and exits 0.

## Sources

- **This demo** — [`./examples/f17-threading/app.d`](./examples/f17-threading/app.d),
  [`instrument.d`](./examples/f17-threading/instrument.d); the
  [AppKit scaffold](./scaffold.md) (toolchain recipe, `A[ssh]` methodology);
  the [F17 feature spec][f17].
- **Sibling F17 measurements** — [X11](../x11/f17-threading.md),
  [Wayland](../wayland/f17-threading.md) (the platform × probe table).
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [Threading Programming Guide — Thread Safety Summary][threadsafety] (all
  verbatim quotes above: the stale window-creation permission, the
  `lockFocusIfCanDraw` bracket, the `setNeedsDisplay:` prohibition +
  `performSelectorOnMainThread:` remedy, `postEvent:atStart:`, `flushGraphics`,
  POSIX-threads multithreaded mode), the guide's
  [introduction][threading-intro], [`NSWindow`][nswindow], and
  [Dispatch][dispatch] (the main queue's run-loop draining).
- **D ↔ Objective-C** — the [`objective-d`][objd] package; the subclassing
  recipe in the [scaffold](./scaffold.md#the-d-side-nsview-subclass-extern-objective-c-worked-no-fallback-needed).

<!-- References -->

[f17]: ../features/f17-threading.md
[objd]: https://github.com/KitsunebiGames/objective-d

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[threadsafety]: https://web.archive.org/web/20260522123345/https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html
[threading-intro]: https://web.archive.org/web/20260317160935/https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/Introduction/Introduction.html
[nswindow]: https://web.archive.org/web/20260503224546/https://developer.apple.com/documentation/appkit/nswindow
[dispatch]: https://web.archive.org/web/20260530071547/https://developer.apple.com/documentation/dispatch
