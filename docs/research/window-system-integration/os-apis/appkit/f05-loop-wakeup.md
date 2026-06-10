# AppKit F05 — loop wakeup & external fds

How a second thread (or an arbitrary file descriptor) wakes `[NSApp run]`, and what it
costs, per the [F05 feature spec][f05]. A worker thread drives three wakeup mechanisms
into the main run loop for 30 s and the demo reports per-mechanism latency: an
[`NSEventTypeApplicationDefined`][appdefined] event posted with
[`postEvent:atStart:`][postevent] (`mech=postevent`), a version-0
[`CFRunLoopSource`][cfrunloopsource] signalled cross-thread (`mech=cfrunloopsource`),
and a `pipe(2)` integrated through a [`CFFileDescriptor`][cffiledescriptor] run-loop
source (`fd_tick`). The program is [`./examples/f05-loop-wakeup/app.d`][demo-app] (with
the shared [`instrument.d`][instrument] logger), built on the [scaffold][scaffold]
recipe.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** (the window
registers with the WindowServer but is not composited — the scaffold's
[sidecar evidence][sidecar]). F05 has no interactive component, so the locked screen
does not distort the measurement: the run loop, the cross-thread injection, and the fd
integration all run identically whether or not pixels reach the glass. The one caveat is
the **cold-start tax** (below): the very first wakeup pays for warming up an
SSH-launched, non-frontmost app's loop, which an interactive session would partly hide.

| Measurement                        | Value                                                                       |
| ---------------------------------- | --------------------------------------------------------------------------- |
| Wakeup mechanisms compared         | **3** — `postevent`, `cfrunloopsource`, and an fd via `CFFileDescriptor`    |
| Samples (30 s run)                 | **300** each for `postevent`/`cfrunloopsource` (10 Hz), **210** `fd` (7 Hz) |
| Steady-state median latency        | `postevent` **319 µs**, `cfrunloopsource` **398 µs**, `fd` **72 µs**        |
| Steady-state p99 latency           | `postevent` **540 µs**, `cfrunloopsource` **639 µs**, `fd` **470 µs**       |
| Cold-start tax (first wakeup only) | **~75 ms** once per run — warming an SSH-launched, non-frontmost loop       |
| Raw fd in the loop                 | **Only via a CF/dispatch adapter** — never `poll()`-style directly          |
| Exit                               | clean `0` (`loop_exit wakes=600 fd_ticks=210`), worker joined, no leaks     |

---

## What the demo does

A single worker thread (D `core.thread`, which runs fine on darwin) drives every
mechanism from a shared monotonic clock, so the three are directly comparable:

- every **100 ms** it posts one `postevent` wakeup **and** signals the
  `cfrunloopsource`, each carrying the send-timestamp (`postevent` in the event's
  `data1`; `cfrunloopsource` via an SPSC ring, since a `CFRunLoopSource` coalesces
  multiple signals into one `perform`);
- every **~143 ms** (7 Hz) it writes an 8-byte send-timestamp into a `pipe`, whose read
  end is wrapped in a `CFFileDescriptor` run-loop source;
- the main thread's callbacks — an overridden [`-[NSApplication sendEvent:]`][nsapplication]
  for `postevent`, the source's `perform` for `cfrunloopsource`, and the descriptor's
  callout for `fd_tick` — each compute `now − send` and append the sample.

At 30 s the worker posts a `subtype=DONE` application-defined event; `sendEvent:` sees
it, calls [`stop:`][nsapp-stop] plus the synthetic-event post the scaffold documented,
`run` returns, the worker is joined, and per-mechanism min/median/p99/max is logged.

> [!NOTE]
> To intercept `postevent` wakeups the demo makes `NSApp` an instance of a D-defined
> `WakeApp : NSApplication` subclass — calling `+sharedApplication` **on the subclass**
> installs it as the shared instance (no `Info.plist` principal-class entry needed), so
> the overridden `sendEvent:` is live. `sharedApplication` is declared only on the leaf
> (returning `WakeApp`) to avoid the Objective-C covariant-return clash the
> [scaffold][scaffold] flagged.

---

## The two cross-thread event mechanisms `A[ssh]`

The cold start, verbatim — the worker and the run loop both begin at `~88 ms`, and the
first wakeup lands ~75 ms later:

```text
87826 APPKIT_F05 step name=NSApp_run
162981 APPKIT_F05 wakeup latency_us=75122.0 mech=cfrunloopsource n=1
164489 APPKIT_F05 fd_tick t=1 latency_us=76631.0
164597 APPKIT_F05 wakeup latency_us=76756.0 mech=postevent n=2
190449 APPKIT_F05 wakeup latency_us=158.0 mech=postevent n=3
190508 APPKIT_F05 wakeup latency_us=203.0 mech=cfrunloopsource n=4
```

That first ~75 ms is a **one-time tax**, not per-wakeup: it is the cost of an
SSH-launched, non-frontmost app finishing its first run-loop drawing/activation pass
before it services injected work. From the second cycle on, both mechanisms are
sub-millisecond and stay there for the whole 30 s:

```text
14589684 APPKIT_F05 wakeup latency_us=300.0 mech=postevent n=291
14589765 APPKIT_F05 wakeup latency_us=361.0 mech=cfrunloopsource n=292
14690155 APPKIT_F05 wakeup latency_us=307.0 mech=postevent n=293
14690243 APPKIT_F05 wakeup latency_us=384.0 mech=cfrunloopsource n=294
```

- **`postevent`** — `[NSApp postEvent:atStart:NO]` appends an
  [`NSEventTypeApplicationDefined`][appdefined] event (built with
  [`otherEventWithType:…`][nsevent], the timestamp packed into `data1`/`data2`) to the
  application event queue; `[NSApp run]` dequeues it and calls our `sendEvent:`
  override. It is the **lowest-median** cross-thread path (319 µs) because the event
  queue is exactly what `run` is already blocked on.
- **`cfrunloopsource`** — [`CFRunLoopSourceSignal`][cfrunloopsource] marks the source
  pending and [`CFRunLoopWakeUp`][cfrunloopsource] kicks the loop; the loop runs the
  source's `perform` on its next pass. It is consistently **~80 µs slower at the median**
  (398 µs) than `postevent` and has a slightly fatter p99 — the extra hop is the
  loop re-arming a source vs. delivering an already-queued event. Because signals
  **coalesce**, the demo carries timestamps in a side ring and the `perform` callback
  drains all pending ones (a single `perform` can answer several signals).

---

## Latency distributions `A[ssh]`

Per-mechanism, over the 30 s run (300 / 300 / 210 samples). `max` is the single
cold-start sample in every column; the steady-state shape is the `min`/`median`/`p99`:

| Mechanism                      | n   | min    | median | p99    | max (cold start) |
| ------------------------------ | --- | ------ | ------ | ------ | ---------------- |
| `postevent`                    | 300 | 131 µs | 319 µs | 540 µs | 76 756 µs        |
| `cfrunloopsource`              | 300 | 167 µs | 398 µs | 639 µs | 75 122 µs        |
| `fd` (`CFFileDescriptor` pipe) | 210 | 38 µs  | 72 µs  | 470 µs | 76 631 µs        |

The headline ordering is stable across runs: **`fd` ≪ `postevent` < `cfrunloopsource`**.
The fd path is **~4–5× faster at the median** than either event path because its callout
runs as a primitive run-loop source with no `NSEvent` allocation, queueing, or
`sendEvent:` dispatch in the way — it is the closest AppKit gets to a bare
`poll()`-readiness wakeup. The trade-off is that you reach it only through an adapter
(next section), and that the `CFFileDescriptor` **disarms itself after every fire**, so
the callout must re-`CFFileDescriptorEnableCallBacks` or it goes deaf after one tick.

---

## Arbitrary fds join the loop only through an adapter `A[ssh]`

The central F05 finding on macOS: **AppKit's run loop never waits on a raw file
descriptor the way an `epoll`/`poll` loop does.** `[NSApp run]` pumps a
`CFRunLoop`, whose only fd-shaped input primitives are CoreFoundation/libdispatch
objects. A bare `int fd` must be wrapped:

- **`CFFileDescriptor`** (this demo): `CFFileDescriptorCreate(fd) →
CFFileDescriptorCreateRunLoopSource → CFRunLoopAddSource`. The callout fires on the
  main loop when the fd is readable; the demo drains the pipe and logs each `fd_tick`.
  Verbatim, interleaved with the event wakeups:

  ```text
  232983 APPKIT_F05 fd_tick t=2 latency_us=49.0
  375829 APPKIT_F05 fd_tick t=3 latency_us=74.0
  ```

  Cost: a CF object per fd, manual callback re-arming after each fire, and a `perform`
  hop. There is no way to hand AppKit the fd itself.

- **`dispatch_source_t`** (the documented alternative — not run here): a
  [`dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue())`][dispatchsource]
  delivers an event handler on the main queue, which on a Cocoa app is drained by the
  same main run loop. It self-rearms (no `EnableCallBacks` dance) and integrates with
  GCD cancellation, at the cost of pulling in libdispatch semantics. For a windowing
  framework that already owns a thread pool, `dispatch_source` is usually the better
  adapter; for a single fd with no GCD elsewhere, `CFFileDescriptor` is lighter.

Either way the shape a framework must offer on macOS is a **run-loop-source adapter**,
not fd registration — the mirror image of Wayland/X11, where the window connection _is_
an fd you `poll()` directly. This is the platform split the
[readiness-vs-completion discussion][concepts] predicts: AppKit hides its readiness fds
behind run-loop sources, so a portable loop abstraction needs a per-platform "wake the
native loop" primitive rather than a single shared `poll` set.

---

## Thread-safety rules

Who may call each injector, and from where — all three are exercised from the worker
thread here and documented thread-safe by Apple:

| Primitive                                      | Safe off the main thread? | Notes                                                       |
| ---------------------------------------------- | ------------------------- | ----------------------------------------------------------- |
| `-[NSApplication postEvent:atStart:]`          | **Yes**                   | The canonical way to wake `run` from another thread         |
| `CFRunLoopSourceSignal` + `CFRunLoopWakeUp`    | **Yes**                   | Signal is atomic; `WakeUp` targets the captured main loop   |
| `write(2)` to the pipe                         | **Yes**                   | Plain POSIX; the CF source observes readability on the loop |
| The callbacks (`sendEvent:`/`perform`/callout) | **Main thread only**      | They run _on_ the run loop — append samples without locking |

Because every callback runs on the main thread, the sample buffers need no locking; the
only cross-thread datum is the `cfrunloopsource` timestamp ring (single-producer,
single-consumer, lock-free). A secondary D `core.thread` calling Cocoa wraps its work in
an `autoreleasepool` (objective-d's `autoreleasepool_push`/`_pop`); `[NSApp run]` drains
its own per-event pools.

---

## Findings summary (for `event-sequences.md`)

- **Three wakeup mechanisms, one ordering:** `fd` (median 72 µs) ≪ `postevent`
  (319 µs) < `cfrunloopsource` (398 µs). All sub-millisecond at p99 in steady state;
  all pay a single ~75 ms cold-start tax warming an SSH-launched, non-frontmost loop.
- **`postevent` beats `cfrunloopsource`** because the run loop is already blocked on the
  event queue, while a `CFRunLoopSource` adds a re-arm/`perform` hop. `postevent` is also
  the simplest to carry a payload (`data1`/`data2`); `cfrunloopsource` needs a side
  channel and must tolerate signal coalescing.
- **Raw fds never enter the loop directly** — `CFFileDescriptor` or `dispatch_source`
  is mandatory; the former needs manual re-arming after each fire. This is the inverse of
  the Wayland/X11 "the connection is a `poll`-able fd" model and the key integration
  constraint a cross-platform loop must abstract.
- **Thread-safety is asymmetric:** the injectors (`postEvent:`, `CFRunLoopSourceSignal`,
  `write`) are callable from any thread; the callbacks they trigger run only on the main
  run loop, which is what keeps the sample bookkeeping lock-free.
- Clean bounded exit: 600 wakeups + 210 fd ticks in 30 s, worker joined, `0`, no leaks.

---

## Sources

- **This demo** — [`./examples/f05-loop-wakeup/app.d`][demo-app],
  [`./examples/f05-loop-wakeup/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (subclass recipe, `stop:` + synthetic-post idiom)
  and the [AppKit survey][survey].
- **Feature specs** — [F05 loop wakeup][f05]; the
  [readiness-vs-completion concept][concepts]; the related [F03 modal loop][f03] (run-loop
  modes), [F04 frame pacing][f04].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSApplication`][nsapplication], [`postEvent:atStart:`][postevent],
  [`stop:`][nsapp-stop], [`NSEvent`][nsevent],
  [`NSEventTypeApplicationDefined`][appdefined], [`CFRunLoopSource`][cfrunloopsource],
  [`kCFRunLoopCommonModes`][commonmodes], [`CFFileDescriptor`][cffiledescriptor],
  [`dispatch_source_create`][dispatchsource].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[sidecar]: ./scaffold.md#windowserver-sidecar-evidence-assh
[demo-app]: ./examples/f05-loop-wakeup/app.d
[instrument]: ./examples/f05-loop-wakeup/instrument.d
[f05]: ../features/f05-loop-wakeup.md
[f03]: ../features/f03-modal-loop.md
[f04]: ../features/f04-frame-pacing.md
[concepts]: ../../concepts.md#readiness-vs-completion-windowing

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nsapplication]: https://web.archive.org/web/20260426230241/https://developer.apple.com/documentation/appkit/nsapplication
[postevent]: https://web.archive.org/web/20251216084635/https://developer.apple.com/documentation/appkit/nsapplication/postevent(_:atstart:)
[nsapp-stop]: https://web.archive.org/web/20250609072014/https://developer.apple.com/documentation/appkit/nsapplication/stop(_:)
[nsevent]: https://web.archive.org/web/20250609072450/https://developer.apple.com/documentation/appkit/nsevent?language=objc
[appdefined]: https://web.archive.org/web/20250624220333/https://developer.apple.com/documentation/appkit/nsevent/eventtype/applicationdefined
[cfrunloopsource]: https://web.archive.org/web/20260118080039/https://developer.apple.com/documentation/corefoundation/cfrunloopsource
[commonmodes]: https://web.archive.org/web/20250615234700/https://developer.apple.com/documentation/corefoundation/kcfrunloopcommonmodes
[cffiledescriptor]: https://web.archive.org/web/20190825230039/https://developer.apple.com/documentation/corefoundation/cffiledescriptorref?language=objc
[dispatchsource]: https://web.archive.org/web/20260317181115/https://developer.apple.com/documentation/dispatch/dispatch_source_create
