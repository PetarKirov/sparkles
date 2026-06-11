# AppKit F14 — Window state & vetoable close

Per the [F14 feature spec][f14], the deliverable is the **ordered delegate +
notification sequence** for every state transition — [`zoom:`][zoom],
[`miniaturize:`][miniaturize]/`deminiaturize:`, [`toggleFullScreen:`][togglefullscreen],
`orderOut:`/`orderFront:` — plus the close contract:
[`windowShouldClose:`][windowshouldclose] as the first-class veto, and the proof
that [`close`][close] skips the delegate ask while [`performClose:`][performclose]
honors it. The program is [`./examples/f14-window-state/app.d`][demo-app] (with the
shared [`instrument.d`][instrument] logger), built on the [scaffold][scaffold]
recipe: one pure-D `NSObject` subclass is simultaneously the
[`NSWindowDelegate`][nswindowdelegate] (every method logs `delegate m=…`) and a
**catch-all `NSNotificationCenter` observer** (`addObserver:selector:name:nil
object:window` logs `note name=…`) — interleaving the two by timestamp yields the
choreography. A `phase=` tag names the request being serviced;
`NSWindowDidUpdateNotification` (one per run-loop pass) is counted and suppressed.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** — the demo
reads the lock state itself via `CGSessionCopyCurrentDictionary` and logged
`session screen_locked=1 on_console=1`. The lock shapes two results honestly
reported below: **fullscreen fails** (`windowDidFailToEnterFullScreen`) and **no
window ever becomes key** (zero focus events in the entire run), so the
miniaturize-focus question and the real Space transition are Tier C.

| Measurement                       | Value                                                                                         |
| --------------------------------- | --------------------------------------------------------------------------------------------- |
| `zoom:` (programmatic maximize)   | **synchronous, animated** — blocks ~356 ms; bracketed by live-resize delegate calls           |
| `zoom:` ask order                 | `willUseStandardFrame` → (`willResize` on restore only) → `shouldZoom:toFrame:` → live-resize |
| `miniaturize:`                    | **asynchronous** — returns immediately; `Will→DidMiniaturize` gap **1.55 s** (locked session) |
| `deminiaturize:`                  | asynchronous, ~0.53 s; `isMiniaturized` readback still `1` right after the call               |
| `toggleFullScreen:`               | **fails under the locked session** — `DidFailToEnterFullScreen` 69 ms after `WillEnter`       |
| `collectionBehavior` prerequisite | default `0x0`; demo sets `FullScreenPrimary` (`1<<7`) before toggling                         |
| `orderOut:`/`orderFront:`         | synchronous `isVisible` flip; **notifications only, no delegate methods**                     |
| Veto contract                     | `windowShouldClose:` returning `NO` honored by `performClose:` (window stays, flag cleared)   |
| `close` vs `performClose:`        | `close` **never asks** — `windowWillClose` fired with no `windowShouldClose:` (proved on aux) |
| Focus events                      | **0** key/main transitions in the whole run — locked session grants no key status (Tier C)    |
| Exit                              | clean `0` (`loop_exit steps=14 suppressed_didUpdate_notes=8`)                                 |

---

## Zoom (maximize) — a synchronous, animated, delegate-mediated resize `A[ssh]`

The full enter choreography, verbatim (timestamps µs):

```text
497036 APPKIT_F14 state_request kind=zoom api=zoom: zoomed_before=0
497102 APPKIT_F14 delegate m=windowWillUseStandardFrame default=(0,0 1728x1084) phase=zoom_on
497161 APPKIT_F14 delegate m=windowShouldZoom toFrame=(0,0 1728x1084) phase=zoom_on answer=YES
497469 APPKIT_F14 delegate m=windowWillStartLiveResize phase=zoom_on
497508 APPKIT_F14 note name=NSWindowWillStartLiveResizeNotification phase=zoom_on
853249 APPKIT_F14 delegate m=windowDidResize frame=(0,0 1728x1084) phase=zoom_on
853333 APPKIT_F14 note name=NSWindowDidResizeNotification phase=zoom_on
853472 APPKIT_F14 delegate m=windowDidEndLiveResize phase=zoom_on
853522 APPKIT_F14 note name=NSWindowDidEndLiveResizeNotification phase=zoom_on
854132 APPKIT_F14 state_changed tag=after_zoom_on frame=(0,0 1728x1084) zoomed=1 …
```

- **`zoom:` blocks for the animation** (~356 ms between `WillStartLiveResize` and
  `DidResize`): the `state_changed` readback runs in the same timer tick,
  immediately after the call returns, and already sees the final frame and
  `isZoomed=1`. [F02][f02] proved a plain `setFrame:display:` is one synchronous
  unanimated change; `zoom:` is the animated sibling — and unlike `setFrame:` it
  **does** run the live-resize bracket (`windowWillStartLiveResize` /
  `windowDidEndLiveResize`), which the scaffold had only ever seen reserved for
  interactive drags.
- **The ask order is delegate-first**: [`windowWillUseStandardFrame:defaultFrame:`][standardframe]
  (proposing the 1728×1084 visible frame) then
  [`windowShouldZoom:toFrame:`][windowshouldzoom] — a second veto point this demo
  answers `YES`. Only one `windowDidResize` arrives for the whole animation, at
  the end; per-frame resize callbacks do **not** fire.
- **Asymmetry**: zooming _off_ (restore) inserts a `windowWillResize:toSize:480x348`
  between `willUseStandardFrame` and `shouldZoom`; zooming _on_ never consulted
  `windowWillResize` at all.
- **`isZoomed` is not free**: every `isZoomed` readback re-invokes
  `windowWillUseStandardFrame:` (AppKit computes the standard frame to compare) —
  that is why stray `willUseStandardFrame` lines precede every `state_changed`
  probe in the log. A delegate that does work in that method pays it on every
  [`isZoomed`][iszoomed] query.
- Delegate method and matching notification are **back-to-back, delegate first**
  (`windowDidResize` at 853249, `NSWindowDidResizeNotification` at 853333) — the
  delegate _is_ a notification observer under the hood, registered first.

## Miniaturize / deminiaturize — fire-and-return, settle later `A[ssh]`

```text
1294836 APPKIT_F14 state_request kind=minimize api=miniaturize:
1295328 APPKIT_F14 state_changed tag=after_miniaturize frame=(120,120 480x348) zoomed=0 mini=0 visible=1 …
1298922 APPKIT_F14 delegate m=windowWillMiniaturize phase=miniaturize
1298973 APPKIT_F14 note name=NSWindowWillMiniaturizeNotification phase=miniaturize
1299007 APPKIT_F14 note name=NSWindowWillOrderOffScreenNotification phase=miniaturize
2850934 APPKIT_F14 delegate m=windowDidMiniaturize miniaturized=1 phase=miniaturize
2850988 APPKIT_F14 note name=NSWindowDidMiniaturizeNotification phase=miniaturize
2851084 APPKIT_F14 note name=NSWindowDidOrderOffScreenNotification phase=miniaturize
```

- **`miniaturize:` returns before anything happens**: the synchronous readback
  still says `mini=0 visible=1`. The transition then runs asynchronously —
  `WillMiniaturize` + `WillOrderOffScreen` ~4 ms later, then a **1.55 s** gap
  (the Dock genie animation grinding under a locked, non-composited session)
  before `DidMiniaturize` → `DidOrderOffScreen`. The same shape applies to
  `deminiaturize:` (readback right after the call: `mini=1 visible=0`; settled
  ~0.53 s later via `_NSWindowWillBecomeVisible` → `DidDeminiaturize` →
  `_NSWindowDidBecomeVisible`). Contrast with `zoom:`: **zoom is synchronous,
  miniaturize is not** — a framework cannot treat "state request" as one shape on
  this platform.
- **Where does focus go?** Unanswerable at `A[ssh]`: the run produced **zero**
  `didBecomeKey`/`didResignKey`/`didBecomeMain` events because a locked session
  never grants key status to begin with (`key=0` in every `state_changed` line,
  occlusion stuck at `0x2000` — note the `NSWindowOcclusionStateVisible` bit
  `0x2` is **never set**, matching the [scaffold's][scaffold] "registered but not
  composited" sidecar evidence). The `windowDidResignKey`-on-miniaturize question
  is Tier C.

## Fullscreen — the transition that needs a real session `A[ssh]`

`collectionBehavior` defaults to `0x0`; the demo sets
[`NSWindowCollectionBehaviorFullScreenPrimary`][collectionbehavior] (`1<<7`)
first. The locked-session result, verbatim:

```text
3690159 APPKIT_F14 state_request kind=fullscreen api=toggleFullScreen:
3691133 APPKIT_F14 note name=NSWindowWillSnapshotForFullScreenNotification phase=fullscreen_enter
3714678 APPKIT_F14 delegate m=windowWillEnterFullScreen phase=fullscreen_enter
3714802 APPKIT_F14 delegate m=windowWillStartLiveResize phase=fullscreen_enter
3722494 APPKIT_F14 delegate m=windowWillResize toSize=1728x1084 phase=fullscreen_enter
3723618 APPKIT_F14 delegate m=windowDidResize frame=(0,0 1728x1084) phase=fullscreen_enter
3726151 APPKIT_F14 delegate m=windowDidEndLiveResize phase=fullscreen_enter
3770834 APPKIT_F14 delegate m=windowWillStartLiveResize phase=fullscreen_enter
3772877 APPKIT_F14 delegate m=windowDidResize frame=(120,120 480x348) phase=fullscreen_enter
3783898 APPKIT_F14 note name=NSWindowDidFailToEnterFullScreenNotification phase=fullscreen_enter
3783918 APPKIT_F14 delegate m=windowDidFailToEnterFullScreen phase=fullscreen_enter
```

- The transition **starts** — snapshot notification, `WillEnterFullScreen`, a
  live-resize to the full 1728×1084 — then AppKit resizes the window **back** to
  480×348 and reports [`windowDidFailToEnterFullScreen:`][didfailfullscreen]
  (69 ms after `WillEnter`; ~94 ms request-to-fail). `windowDidEnterFullScreen`
  never fires; `styleMask` never gains `NSWindowStyleMaskFullScreen`; the demo's
  40-tick wait sees `entered=0 failed=1`. **A Space transition needs a logged-in
  console** — under SSH/locked, the failure path _is_ the finding, and the
  delegate gets a first-class callback for it (note the unusual order:
  the _notification_ preceded the delegate method here, the only place the demo
  observed that inversion).
- The exit toggle was then skipped (`skipped=not_fullscreen` — the demo checks
  `styleMask` rather than blindly toggling, which would have _entered_ fullscreen
  and failed again). Duration of a real enter/exit: Tier C.

## orderOut / orderFront — visibility is not a delegate affair `A[ssh]`

`orderOut:` flips `isVisible` synchronously (readback in the same tick:
`visible=0`) and emits **only notifications** — `NSWindowWillOrderOffScreenNotification`
→ `NSWindowDidOrderOffScreenNotification` (plus the private
`_NSDisplayLinkInfoProviderDidUpdate`); no public `NSWindowDelegate` method exists
for ordering. `makeKeyAndOrderFront:` mirrors it with the **private**
`_NSWindowWillBecomeVisible` / `_NSWindowDidBecomeVisible` pair — the catch-all
observer is the only way this demo could see the show transition at all. (And the
"makeKey" half did nothing: locked session, no key status.)

## The close contract — a first-class veto, with a trapdoor `A[ssh]`

```text
4295134 APPKIT_F14 close_probe api=close win=aux expect=no_windowShouldClose
4295338 APPKIT_F14 delegate m=windowWillClose win=aux phase=aux_close_direct
4493714 APPKIT_F14 close_probe api=performClose win=main dirty=1 expect=veto
4494857 APPKIT_F14 close_requested veto=1 win=main phase=veto_close_1 mechanism=windowShouldClose_NO
4601204 APPKIT_F14 close_probe after=performClose still_visible=1 dirty=0
4696897 APPKIT_F14 close_probe api=performClose win=main dirty=0 expect=close
4697343 APPKIT_F14 close_requested veto=0 win=main phase=veto_close_2
4697405 APPKIT_F14 delegate m=windowWillClose win=main phase=veto_close_2
4697500 APPKIT_F14 note name=NSWindowWillCloseNotification phase=veto_close_2
```

- **`windowShouldClose:` returning `NO` is the veto, and it sticks**: with the
  dirty flag set, `performClose:` produced `close_requested veto=1`, no
  `windowWillClose`, no notifications, `still_visible=1`. The once-veto cleared
  the flag; the second `performClose:` ran the full teardown
  (`windowShouldClose` → `windowWillClose` → `NSWindowWillCloseNotification` →
  order-off-screen → `NSWindowDidCloseNotification`). Same return-value shape as
  Win32's `WM_CLOSE` handler; the opposite of X11/Wayland, where the close
  request is purely advisory and "veto" is just ignoring it.
- **`close` skips the ask.** On the aux window, `close` fired `windowWillClose`
  _without ever calling_ `windowShouldClose:` — exactly as the
  [`performClose:`][performclose] docs imply (it is `performClose:` that asks the
  delegate "for approval"; [`close`][close] just closes). A framework exposing
  "request close" must route through `performClose:` (or ask the delegate
  itself); calling `close` silently bypasses every dirty-document guard.
- The demo set `setReleasedWhenClosed:NO` so post-close readbacks stay legal —
  with the default `YES`, a closed window is a dangling object.

## Surprises

1. **`zoom:` is a 356 ms blocking call** that runs the live-resize bracket —
   programmatic maximize animates even though programmatic `setFrame:` ([F02][f02])
   does not, and the app's thread is captive for the duration.
2. **`isZoomed` calls back into the delegate** (`windowWillUseStandardFrame:`)
   on every query.
3. **The three "state" verbs have three different temporal shapes**: zoom
   synchronous-animated, miniaturize fire-and-settle-later (1.55 s), fullscreen
   asynchronous with an explicit failure callback.
4. **Fullscreen fails cleanly under a locked session** — `windowDidFailToEnterFullScreen`
   exists precisely for "the environment said no", and it arrived _after_ AppKit
   had already resized the window full-size and back.
5. **Ordering (`orderOut:`/`orderFront:`) has no delegate API** — only
   notifications, two of them private (`_NSWindowWillBecomeVisible`).
6. **Delegate-before-notification** held everywhere except
   `DidFailToEnterFullScreen`, where the notification landed first.
7. **A locked session grants key status to no one**: `makeKeyAndOrderFront:`
   succeeded at ordering but the whole 4.7 s run contains zero focus events.

## Sources

- **This demo** — [`./examples/f14-window-state/app.d`][demo-app],
  [`./examples/f14-window-state/instrument.d`][instrument]; the
  [scaffold findings][scaffold] (subclassing recipe, `stop:` idiom, locked-session
  WindowServer evidence); the [F02 resize findings][f02-doc].
- **Feature spec** — [F14 window state][f14].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSWindowDelegate`][nswindowdelegate], [`zoom:`][zoom], [`isZoomed`][iszoomed],
  [`windowShouldZoom:toFrame:`][windowshouldzoom],
  [`windowWillUseStandardFrame:defaultFrame:`][standardframe],
  [`miniaturize:`][miniaturize], [`toggleFullScreen:`][togglefullscreen],
  [`collectionBehavior`][collectionbehavior],
  [`windowDidFailToEnterFullScreen:`][didfailfullscreen],
  [`windowShouldClose:`][windowshouldclose], [`performClose:`][performclose],
  [`close`][close], [`orderOut:`][orderout], [`occlusionState`][occlusionstate].

<!-- References -->

<!-- This tree -->

[demo-app]: ./examples/f14-window-state/app.d
[instrument]: ./examples/f14-window-state/instrument.d
[scaffold]: ./scaffold.md
[f02-doc]: ./f02-resize.md
[f02]: ../features/f02-resize.md
[f14]: ../features/f14-window-state.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nswindowdelegate]: https://web.archive.org/web/20260326191200/https://developer.apple.com/documentation/appkit/nswindowdelegate
[zoom]: https://web.archive.org/web/20250609073620/https://developer.apple.com/documentation/appkit/nswindow/zoom(_:)
[iszoomed]: https://web.archive.org/web/20251119075532/https://developer.apple.com/documentation/appkit/nswindow/iszoomed
[windowshouldzoom]: https://web.archive.org/web/20250609073627/https://developer.apple.com/documentation/appkit/nswindowdelegate/windowshouldzoom(_:toframe:)
[standardframe]: https://web.archive.org/web/20250609073628/https://developer.apple.com/documentation/appkit/nswindowdelegate/windowwillusestandardframe(_:defaultframe:)
[miniaturize]: https://web.archive.org/web/20250609073604/https://developer.apple.com/documentation/appkit/nswindow/miniaturize(_:)
[togglefullscreen]: https://web.archive.org/web/20260221041904/https://developer.apple.com/documentation/appkit/nswindow/togglefullscreen(_:)
[collectionbehavior]: https://web.archive.org/web/20250825025409/https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.property
[didfailfullscreen]: https://web.archive.org/web/20251122232455/https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidfailtoenterfullscreen(_:)
[windowshouldclose]: https://web.archive.org/web/20250609073627/https://developer.apple.com/documentation/appkit/nswindowdelegate/windowshouldclose(_:)
[performclose]: https://web.archive.org/web/20250609073607/https://developer.apple.com/documentation/appkit/nswindow/performclose(_:)
[close]: https://web.archive.org/web/20251025040930/https://developer.apple.com/documentation/appkit/nswindow/close()
[orderout]: https://web.archive.org/web/20250609073606/https://developer.apple.com/documentation/appkit/nswindow/orderout(_:)
[occlusionstate]: https://web.archive.org/web/20191017131348/https://developer.apple.com/documentation/appkit/nswindow/occlusionstate
