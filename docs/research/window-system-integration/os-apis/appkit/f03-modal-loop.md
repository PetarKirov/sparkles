# AppKit F03 — modal-loop survival

How an animation survives macOS's version of the modal loop, per the
[F03 feature spec][f03]: a full-window **~2 Hz color cycle** driven by an `NSTimer`
scheduled in **`NSRunLoopCommonModes`**, raced against an identical control timer left
in the default run-loop mode, through two nested non-default run-loop phases —
[`NSEventTrackingRunLoopMode`][nseventtrackingrunloopmode] (the very mode AppKit's
live-resize and menu tracking run in) and
[`NSModalPanelRunLoopMode`][nsmodalpanelrunloopmode]. The program is
[`./examples/f03-modal-loop/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe.

**Last reviewed:** June 10, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** (windows
register with the WindowServer but are not composited — the scaffold's
[sidecar evidence][sidecar]). Mode starvation is run-loop-internal and fully
measurable in this state; only the _interactive_ live-resize drag needs eyes
(Tier C, [below](#the-interactive-half-is-tier-c)).

| Measurement                                      | Value                                                               |
| ------------------------------------------------ | ------------------------------------------------------------------- |
| Default-mode timer fires during `tracking` phase | **0** (of ~20 expected; starved for the whole 2 s)                  |
| Default-mode timer fires during `panel` phase    | **0** — same starvation in `NSModalPanelRunLoopMode`                |
| Default-mode timer gap across each nested phase  | **2026.4 ms** / **2013.9 ms** (vs the 100 ms interval)              |
| Common-modes timer max gap, any phase            | **109.5 ms** — ticked straight through both nested modes            |
| Color-cycle draws during nested phases           | continued at full cadence (`drawRect:` runs in common modes too)    |
| `modal_enter`/`modal_exit` (live-resize bracket) | instrumented; **0** fired — interactive-only, queued Tier C         |
| Exit                                             | clean `0` (`loop_exit ticks_default=82 ticks_common=120 draws=120`) |

---

## Run-loop modes are macOS's modal loop

On Win32, grabbing a window border traps the thread in `DefWindowProc`'s
`WM_ENTERSIZEMOVE` modal loop and the application's own message pump simply stops
running — the headline problem of the [F03 spec][f03-win32]. macOS has no foreign
modal loop: AppKit keeps running _your_ `NSRunLoop`, but switches it to a different
**mode**. During an interactive resize/move or menu tracking that mode is
[`NSEventTrackingRunLoopMode`][nseventtrackingrunloopmode] —

> The mode set when tracking events modally, such as a mouse-dragging loop.

— and during modal panels it is [`NSModalPanelRunLoopMode`][nsmodalpanelrunloopmode].
A run-loop **mode** is a filter: only input sources and timers registered _in the
running mode_ are serviced. A timer created with
[`scheduledTimerWithTimeInterval:…`][nstimer] lands in the default mode only, so the
moment AppKit enters a tracking loop it stops firing — the animation freezes. That is
the same _symptom_ as the Win32 modal loop with a different _mechanism_: the thread
is not captured by someone else's pump; your sources are filtered out of your own.

The cure is the pseudo-mode [`NSRunLoopCommonModes`][nsrunloopcommonmodes]: objects
added under it are registered in every mode declared "common", and AppKit declares
its default, event-tracking, and modal-panel modes common. A timer added with
[`addTimer:forMode:NSRunLoopCommonModes`][nsrunloop] keeps firing through all of
them — the [F03 spec's macOS deliverable][f03].

`viewWillStartLiveResize`/[`viewDidEndLiveResize`][viewwillstartliveresize] bracket
the live-resize tracking loop (the demo logs them as `modal_enter`/`modal_exit`,
the AppKit analog of `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`), and
[`inLiveResize`][inliveresize] is queryable per draw — every `drawRect:` here logs it.

---

## What the demo does

The scaffold's window + a D-defined `ColorView` subclass whose `drawRect:` fills the
window with a solid color stepped through a coarse hue wheel (5 × 100 ms steps ≈ a
2 Hz full cycle — a frozen color is a starved timer, visible at a glance):

- **`timer=default`** — `scheduledTimerWithTimeInterval:` (100 ms, repeating): the
  naive animation timer, default mode only. The control.
- **`timer=common`** — `timerWithTimeInterval:` + `addTimer:forMode:` with
  `NSRunLoopCommonModes` (100 ms, repeating): drives `setNeedsDisplay:` and the hue
  step. The fix.
- Both log `tick timer=… n=… gap_ms=… phase=…` per fire; per-timer/per-phase fire
  counts and max gaps are summarized at exit.
- **Two nested phases** (`WSI_AUTO_EXIT=1`): at ~3 s the run loop is run nested in
  `NSEventTrackingRunLoopMode` for ~2 s via [`runMode:beforeDate:`][runmode]; at
  ~7 s the same in `NSModalPanelRunLoopMode`; stop at ~12 s. Each nested loop is
  exactly the structure AppKit's own tracking loops have — the run loop re-entered
  in a non-default mode somewhere on the stack — just with a synthetic trigger, so
  the starvation is measurable headless over SSH where nobody can drag a border.
- `viewWillStartLiveResize`/`viewDidEndLiveResize` → `modal_enter`/`modal_exit`,
  `drawRect:` logs `live_resize=0|1` — armed for the interactive Tier-C run
  (no env var → no synthetic phases, window waits for a human drag).

> [!IMPORTANT]
> The nested phases are deliberately entered from **their own one-shot timers**, not
> from the animation timer's callback. The first version of this demo entered the
> nested loop from inside `tickCommon:` itself and measured the common-modes timer
> starving too (`fires=0` in the nested phase, a 2100 ms resume gap): **a repeating
> `NSTimer` never fires re-entrantly while its own callout is on the stack**, in any
> mode. That measured dead end is itself an F03 finding — a framework must never run
> a nested event loop (or a synchronous modal anything) from inside its tick
> callback, or its frame clock starves _regardless of run-loop modes_.

---

## Annotated sequences `A[ssh]`

### Entering `NSEventTrackingRunLoopMode` — the default-mode timer stops dead

```text
3089221 APPKIT_F03 tick timer=default n=30 gap_ms=94.1 phase=default
3089301 APPKIT_F03 tick timer=common n=30 gap_ms=94.1 phase=default
3089402 APPKIT_F03 phase_enter name=tracking mode=NSEventTrackingRunLoopMode dur_ms=2000
3188912 APPKIT_F03 tick timer=common n=31 gap_ms=99.6 phase=tracking   <- common keeps its 100 ms cadence
3296777 APPKIT_F03 tick timer=common n=32 gap_ms=107.9 phase=tracking
3389848 APPKIT_F03 tick timer=common n=33 gap_ms=93.1 phase=tracking
...                                                                    <- 20 common ticks, ZERO default ticks
5087410 APPKIT_F03 tick timer=common n=50 gap_ms=95.8 phase=tracking
5115555 APPKIT_F03 phase_exit name=tracking
5115657 APPKIT_F03 tick timer=default n=31 gap_ms=2026.4 phase=resumed <- starved 2026 ms; fires 102 µs after exit
5196153 APPKIT_F03 tick timer=default n=32 gap_ms=80.5 phase=resumed   <- and falls back into cadence
```

The default-mode timer's `n=30 → n=31` gap spans the entire tracking phase: **one
fire lost per 100 ms for 2 s, all delivered as silence** — `NSTimer` does not queue
missed fires; the first post-starvation fire comes immediately on mode exit and the
cadence resumes as if nothing happened. The common-modes timer never deviated from
~100 ms (max 108.8 ms during the phase). This is precisely what a live-resize drag
does to a default-mode animation timer, minus the mouse.

### `NSModalPanelRunLoopMode` — identical shape

```text
7088630 APPKIT_F03 tick timer=common n=70 gap_ms=100.2 phase=resumed
7088740 APPKIT_F03 phase_enter name=panel mode=NSModalPanelRunLoopMode dur_ms=2000
7196787 APPKIT_F03 tick timer=common n=71 gap_ms=108.2 phase=panel
...                                                                    <- again 20 common, 0 default
9088693 APPKIT_F03 tick timer=common n=90 gap_ms=101.5 phase=panel
9102365 APPKIT_F03 phase_exit name=panel
9102468 APPKIT_F03 tick timer=default n=52 gap_ms=2013.9 phase=resumed
```

### The exit summary, verbatim

```text
12089587 APPKIT_F03 gap_summary timer=default phase=default fires=30 max_gap_ms=106.5
12089613 APPKIT_F03 gap_summary timer=default phase=tracking fires=0 max_gap_ms=0.0
12089633 APPKIT_F03 gap_summary timer=default phase=panel fires=0 max_gap_ms=0.0
12089651 APPKIT_F03 gap_summary timer=default phase=resumed fires=52 max_gap_ms=2026.4
12089669 APPKIT_F03 gap_summary timer=common phase=default fires=30 max_gap_ms=106.5
12089688 APPKIT_F03 gap_summary timer=common phase=tracking fires=20 max_gap_ms=108.8
12089705 APPKIT_F03 gap_summary timer=common phase=panel fires=20 max_gap_ms=108.2
12089722 APPKIT_F03 gap_summary timer=common phase=resumed fires=50 max_gap_ms=109.5
12089739 APPKIT_F03 step name=NSApp_stop
12090118 APPKIT_F03 loop_exit ticks_default=82 ticks_common=120 draws=120
```

The spec's "max inter-frame gap during the interaction": **109.5 ms** for the
common-modes animation (its normal jitter ceiling — bounded throughout), vs an
unbounded **starvation gap equal to the interaction length** (here 2 s ≈ 20 dropped
frames) for the default-mode control.

### Drawing keeps working inside the nested modes

`drawRect:` continued at full cadence during both nested phases (`draws=120` ==
`ticks_common=120`):

```text
3093892 APPKIT_F03 draw n=31 hue_step=30 live_resize=0 phase=tracking
3193505 APPKIT_F03 draw n=32 hue_step=31 live_resize=0 phase=tracking
```

AppKit's window-update pass (the run-loop observer that turns `setNeedsDisplay:`
dirty marks into `drawRect:`) is itself registered in the common modes — so a
common-modes timer is _sufficient_ for live animation during tracking: tick, mark
dirty, and the nested tracking loop's own drawing pass paints. No extra
`displayIfNeeded` forcing was required.

---

## Findings summary (for `event-sequences.md`)

- **macOS has no foreign modal loop — it has mode filtering.** The thread stays in
  the app's own run loop during resize/menu/modal interactions, but in
  `NSEventTrackingRunLoopMode`/`NSModalPanelRunLoopMode`, which service only
  sources/timers registered in those modes. Loop _ownership_ is preserved
  (unlike Win32, where `DefWindowProc` pumps); loop _configuration_ is what bites.
- **The fix is registration, not architecture:** the same timer object added via
  `addTimer:forMode:NSRunLoopCommonModes` survives every phase with its jitter
  ceiling unchanged (≤ 109.5 ms here); the default-mode twin loses every fire for
  the duration of the interaction and never catches up (no fire coalescing/queueing
  — just silence, then resume).
- **Starved timers resume instantly and cleanly**: first fire 102 µs after mode
  exit, cadence re-established by the next fire. A framework that brackets
  interactions with `modal_enter`/`modal_exit` (via
  `viewWillStartLiveResize`/`…End`) can therefore also _re-arm_ default-mode
  machinery on exit without compensation logic.
- **Never run a nested loop from the tick callback** — `NSTimer`'s no-re-entrant-fire
  rule starves the frame clock in any mode (measured, see the note above). AppKit's
  own pattern (tracking loops are entered from _event_ dispatch, not timer callouts)
  avoids this by construction.
- **For frameworks:** on macOS, `requestAnimationTick`-style machinery must be in
  common modes (timer or `CADisplayLink` added with `forMode:NSRunLoopCommonModes`
  — see [F04][f04-doc]); on Win32 the equivalent demo needs an actual modal-loop
  defeat ([spec § Win32][f03-win32]); on Wayland/X11 the problem does not exist.

---

## The interactive half is Tier C

Mode starvation is proven headless above, but requirement 2 of the [spec][f03] —
animation continuing during a _real_ border-drag and title-bar drag, confirmed by
eyes on a composited screen — cannot be performed over locked-console SSH (and a
programmatic `setFrame:` never enters live-resize, per the [scaffold][scaffold] and
[F02][f02-doc] findings). Queued in the [manual-run queue][queue]: run `./demo`
with no env vars in an unlocked GUI session, drag the border and the title bar.
Expected: the color cycle never freezes (common-modes timer), `modal_enter`/
`modal_exit` bracket the drag, `tick timer=default` lines vanish for the duration
of the drag and the post-drag `gap_ms` equals the drag length.

---

## Sources

- **This demo** — [`./examples/f03-modal-loop/app.d`][demo-app],
  [`./examples/f03-modal-loop/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, build command, `stop:` event-post
  gotcha) and the [AppKit survey][survey].
- **Feature specs** — [F03 modal loop][f03] (incl. the [Win32 headline][f03-win32]);
  the related [F02 resize][f02-doc] and [F04 frame pacing][f04-doc] (this tree);
  the Tier-C entry in the [manual-run queue][queue].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSRunLoop`][nsrunloop], [`NSRunLoopCommonModes`][nsrunloopcommonmodes],
  [`NSEventTrackingRunLoopMode`][nseventtrackingrunloopmode] (quoted above),
  [`NSModalPanelRunLoopMode`][nsmodalpanelrunloopmode],
  [`runMode:beforeDate:`][runmode], [`NSTimer`][nstimer],
  [`viewWillStartLiveResize`][viewwillstartliveresize],
  [`inLiveResize`][inliveresize].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[sidecar]: ./scaffold.md#windowserver-sidecar-evidence-assh
[demo-app]: ./examples/f03-modal-loop/app.d
[instrument]: ./examples/f03-modal-loop/instrument.d
[f03]: ../features/f03-modal-loop.md
[f03-win32]: ../features/f03-modal-loop.md#requirements
[f02-doc]: ./f02-resize.md
[f04-doc]: ./f04-frame-pacing.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nsrunloop]: https://web.archive.org/web/20250213081300/https://developer.apple.com/documentation/foundation/nsrunloop
[nsrunloopcommonmodes]: https://web.archive.org/web/20220722221302/https://developer.apple.com/documentation/foundation/nsrunloopcommonmodes
[nseventtrackingrunloopmode]: https://web.archive.org/web/20260218184626/https://developer.apple.com/documentation/appkit/nseventtrackingrunloopmode
[nsmodalpanelrunloopmode]: https://web.archive.org/web/20260125094114/https://developer.apple.com/documentation/appkit/nsmodalpanelrunloopmode
[runmode]: https://web.archive.org/web/20250609104543/https://developer.apple.com/documentation/foundation/runloop/run(mode:before:)
[nstimer]: https://web.archive.org/web/20250318115719/https://developer.apple.com/documentation/foundation/nstimer
[viewwillstartliveresize]: https://web.archive.org/web/20250609073528/https://developer.apple.com/documentation/appkit/nsview/viewwillstartliveresize()
[inliveresize]: https://web.archive.org/web/20250609073511/https://developer.apple.com/documentation/appkit/nsview/inliveresize
