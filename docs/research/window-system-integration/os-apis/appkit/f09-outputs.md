# AppKit F09 — Output enumeration & hotplug

macOS answers the [F09 feature spec][f09] with **two object models for the same
display**: AppKit's [`NSScreen`][nsscreen-screens] (points, y-up global space,
per-screen scale, `localizedName`) and CoreGraphics' `CGDirectDisplayID` (pixels,
top-left-origin global space, modes, hardware identity) — bridged by the
`NSScreenNumber` key in [`deviceDescription`][devicedescription]. This demo enumerates
both sides, checks the bridge, reads [`-[NSWindow screen]`][nswindow-screen] (AppKit's
_own_ answer to "which output is the window on"), and registers every change signal a
hotplug would fire. The program is [`./examples/f09-outputs/app.d`][demo-app] (with the
shared [`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0, single built-in Retina display) over SSH with the console
session **locked**. For this feature the lock is not just a rendering caveat — it
visibly **changes one of the two enumeration APIs** (the
[empty-active-list finding](#the-locked-session-empties-the-active-list-a-ssh) below),
which is itself the headless-hotplug answer the spec asks for. A physical plug/unplug
is Tier C ([script](#tier-c-script-plugunplug)).

| Measurement                                   | Value                                                                                              |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Outputs (NSScreen / CG online / CG active)    | **1 / 1 / 0** — the locked session removes the display from the _active_ list only                 |
| Bridge `NSScreenNumber` ↔ `CGDirectDisplayID` | id **1** on both sides (`in_cg_online_list=1`); equals `CGMainDisplayID()`                         |
| CG enumeration prerequisites                  | **none** — ran before `NSApplication.sharedApplication()` existed                                  |
| `CGDisplayPixelsWide/High`                    | **1728×1117** — points-scaled, _not_ pixels; `CGDisplayModeGetPixelWidth` says 3456×2234           |
| Refresh                                       | CG mode `refresh=120.00`; `NSScreen.maximumFramesPerSecond=120` (ProMotion panel)                  |
| Physical size                                 | `CGDisplayScreenSize` → **344×223 mm**; AppKit offers no physical-size API                         |
| `frame` vs `visibleFrame`                     | 1728×1117 vs 1728×**1084** — 33 pt menubar inset at the top, Dock inset 0 while locked             |
| Window ↔ screen                               | `window.screen` answers at `initWithContentRect:` return, before ordering in                       |
| Hotplug signals fired headless                | **0** of 3 (NSNotification ×2 by self-test only; `CGDisplayRegisterReconfigurationCallback` never) |
| Exit                                          | clean `0` (`loop_exit ticks=45 reconfig_cb=0 screen_params=1 window_screen=1`)                     |

---

## Two object models, one display `A[ssh]`

The same panel, enumerated through both APIs (verbatim, one run):

```text
20128 APPKIT_F09 cg_displays when=startup online=1 active=0
24129 APPKIT_F09 output api=cg id=1 bounds=(0,0 1728x1117) px=1728x1117 mm=344x223 vendor=0x610 model=0xa05d serial=0xfd626d62 builtin=1 main=1 active=0 online=1 asleep=1 mirror=0
24173 APPKIT_F09 output_mode api=cg id=1 mode_pt=1728x1117 mode_px=3456x2234 refresh=120.00
47851 APPKIT_F09 output api=appkit idx=0 id=1 frame=(0,0 1728x1117) visible=(0,0 1728x1084) scale=2.0 max_fps=120 name="Built-in Retina Display"
47892 APPKIT_F09 output_device api=appkit id=1 device_size_pt=1728x1117 device_dpi=144x144
48062 APPKIT_F09 bridge nsscreen_idx=0 nsscreen_number=1 in_cg_online_list=1 in_cg_active_list=0 px_check=1728x1117
```

| Fact                | `NSScreen` (AppKit)                                                             | `CGDirectDisplayID` (CoreGraphics)                                                    |
| ------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Identity            | object per screen; `NSScreenNumber` in [`deviceDescription`][devicedescription] | the `uint32_t` display ID itself (`1` here), + vendor/model/serial                    |
| Geometry            | [`frame`][visibleframe] in **points**, y-up global space                        | [`CGDisplayBounds`][cgdisplaybounds] in the global display space, **top-left origin** |
| Usable area         | [`visibleFrame`][visibleframe] (menubar/Dock insets)                            | — (no concept)                                                                        |
| Scale               | `backingScaleFactor` (2.0)                                                      | implied by `mode_pt` vs `mode_px` (1728 vs 3456)                                      |
| Mode / refresh      | [`maximumFramesPerSecond`][maxfps] (cap only)                                   | [`CGDisplayCopyDisplayMode`][copymode] → size + [`refreshRate`][refreshrate]          |
| Physical size       | — (only `NSDeviceResolution` 144 dpi)                                           | [`CGDisplayScreenSize`][screensize] → 344×223 mm                                      |
| Human name          | [`localizedName`][localizedname] ("Built-in Retina Display", macOS 10.15+)      | — (numeric vendor/model/serial)                                                       |
| Power/session state | — (a locked/asleep screen still enumerates normally)                            | `CGDisplayIsActive/IsOnline/IsAsleep` flags                                           |
| Needs               | AppKit (`NSApplication` implicitly initialized)                                 | **nothing** — ran before `sharedApplication`                                          |

Notes from the probes:

- **Enumeration is global, both sides.** The CG pass ran _before_
  `NSApplication.sharedApplication()` existed — only the WindowServer connection
  (bootstrapped by the `CGMainDisplayID()` headless guard) is needed. No window, no
  app object, no event loop.
- **`CGDisplayPixelsWide/High` does not return pixels** on a Retina display: it
  reports **1728×1117** — the points-scaled size, identical to `CGDisplayBounds` — for
  a 3456×2234 panel. The truthful pixel count lives in
  `CGDisplayModeGetPixelWidth/Height` (`mode_px=3456x2234`). The function name
  predates HiDPI; treat it as "bounds units", never as buffer size.
- **Refresh agrees at 120** from both sides on this ProMotion panel —
  `CGDisplayModeGetRefreshRate` returns the mode's nominal rate and
  [`maximumFramesPerSecond`][maxfps] (the AppKit-side cap, macOS 12+) matches. Note
  the CG value is documented to read **0** for some displays ("Some displays may not
  use conventional video vertical and horizontal sweep in painting the screen;
  ... the return value is 0" per the [`refreshRate`][refreshrate] docs) — code must
  tolerate 0 there, which makes `maximumFramesPerSecond` the more dependable number.
- **`deviceDescription` extras**: `NSDeviceSize` repeats the frame in points and
  `NSDeviceResolution` reads **144×144 dpi** — which is just 72 dpi × the 2.0 scale,
  a _logical_ density, not the panel's true ~226 ppi. The only honest physical-size
  source is CG's 344×223 mm.
- **The `frame`/`visibleFrame` split**: 1117 − 1084 = **33 pt** shaved off the top —
  the menubar — even while locked; the Dock contributed **0 pt** in this session
  (`dock_pt=0`: the lock screen reserves no Dock strip). Maximizing into `frame`
  instead of `visibleFrame` is the classic menubar-overlap bug.

---

## The bridge: `NSScreenNumber` is the `CGDirectDisplayID` `A[ssh]`

[`deviceDescription`][devicedescription]`[@"NSScreenNumber"]` unboxes to `1`, which is
exactly `CGMainDisplayID()` and a member of the CG online list
(`bridge nsscreen_number=1 in_cg_online_list=1 px_check=1728x1117`). This is the
documented escape hatch — the [`deviceDescription`][devicedescription] docs say to
"specify the Objective-C string `NSScreenNumber` as the key" and that "the value
associated with this key is an `NSNumber` object containing the display ID value" —
and it is the _only_ way to get from an `NSScreen` (no mode, no physical size, no
hardware identity) to the CG facts. Every multi-monitor AppKit renderer ends up
holding both handles per output.

---

## Which screen is the window on? AppKit just tells you `A[ssh]`

```text
84137 APPKIT_F09 window_screen when=post_init id=1 name="Built-in Retina Display" window_frame=(120,120 480x348) api=window.screen derived=no
```

[`-[NSWindow screen]`][nswindow-screen] returns the screen object directly — already
at `initWithContentRect:` return, before the window is ever ordered in — and the
docs pin the tie-breaking rule for straddling windows: "the screen where most of
the window is on" (and `nil` when offscreen). The cross-platform contrast in one line each: Win32
gives the same answer but only on demand via `MonitorFromWindow(hwnd,
MONITOR_DEFAULTTONEAREST)`; X11 gives no answer at all — you intersect the window
geometry against RandR monitor rects yourself. And tracking is push, not poll:
[`NSWindowDidChangeScreenNotification`][didchangescreen] fires when the answer
changes (registration + a hand-posted self-test proven below; a real screen-to-screen
drag is Tier C — single display here).

---

## The locked session empties the _active_ list `A[ssh]`

The headless probe the spec asks for ("does locking/display sleep change the active
list?") has a sharp answer — **yes, the active list, and only the active list**:

```text
20128 APPKIT_F09 cg_displays when=startup online=1 active=0
24129 APPKIT_F09 output api=cg id=1 ... builtin=1 main=1 active=0 online=1 asleep=1 mirror=0
44884 APPKIT_F09 ns_screens when=startup count=1
```

- `CGGetActiveDisplayList` returns **zero** displays: the locked, slept panel
  (`asleep=1`) is not "active" — consistent with the
  [`CGGetActiveDisplayList`][activelist] docs, which provide "a list of displays
  that are active for drawing". Mirroring is _not_ the cause here (`mirror=0`);
  display sleep is.
- [`CGGetOnlineDisplayList`][onlinelist] still returns the display — _online_ covers
  displays "that are online (active, mirrored, or sleeping)".
- **`NSScreen.screens` is unaffected** (`count=1`, full geometry, scale, name), and
  `window.screen`, `CGDisplayBounds`, the mode query, and `CGMainDisplayID` all keep
  answering for the inactive display.

So the two models even disagree about _existence_: CG truthfully reports the power
state, AppKit preserves the desktop model regardless. An output enumerator that uses
`CGGetActiveDisplayList` as its source of truth sees **an empty world** in a locked
session — enumerate the online list (or `NSScreen.screens`) and treat `active`/
`asleep` as flags. The re-enumeration at tick 20 confirmed the state is static
headless (`hotplug_probe active_delta=0 online_delta=0 reconfig_cb_calls=0`).

---

## Hotplug: three signals registered, none fire headless `A[ssh]`

A real plug/unplug cannot happen over locked SSH, so the demo pins everything short
of it:

- **App level**: [`NSApplicationDidChangeScreenParametersNotification`][screenparamsnotif]
  ("the configuration of the displays attached to the computer is changed").
- **Window level**: [`NSWindowDidChangeScreenNotification`][didchangescreen] (this
  window's `screen` answer changed).
- **CG level**: [`CGDisplayRegisterReconfigurationCallback`][reconfigcb] (`err=0` on
  registration, also pre-AppKit) — fires per display with begin/add/remove/set-mode
  flags; the demo decodes `kCGDisplayAddFlag`/`kCGDisplayRemoveFlag`/
  `kCGDisplaySetModeFlag`.

The NSNotification wiring is proven by a hand-posted self-test — both handlers run
and re-enumerate (unchanged) state:

```text
615271 APPKIT_F09 step name=post_notifications note=selftest
615334 APPKIT_F09 screen_params_changed n=1
615614 APPKIT_F09 window_screen_changed n=1
852848 APPKIT_F09 loop_exit ticks=45 reconfig_cb=0 screen_params=1 window_screen=1
```

The CG callback cannot be hand-posted (it is driven by actual reconfiguration), so
its headless count is honestly **0**; with the active list already empty, even
locking/unlocking mid-run would be the obvious next probe — but the lock state cannot
be toggled from a non-GUI SSH session, so the event-order question (CG callback vs
NSNotification, begin/end pairing, stale `window.screen` during removal) is entirely
Tier C.

---

## Tier C script: plug/unplug

Run on `mac-bsn` in an **unlocked** GUI session with one external display
(results → this doc):

1. Build per the [scaffold][scaffold] (binary staged at `/tmp/wsi-m5/f09-outputs/demo`),
   run `./demo` with **no** env vars (interactive mode keeps the window up).
2. Plug the external display in. Record the order and timing of:
   `cg_reconfig` lines (expect a begin/end pair for the new id, `add=1`),
   `screen_params_changed`, and whether `ns_screens` then shows the new screen with
   a stable `NSScreenNumber`. Check the new id appears in _both_ CG lists.
3. Drag the window to the external display; expect `window_screen_changed` +
   `window_screen` with the new id at some crossing point (record whether it is the
   majority-area point, per the `screen` docs).
4. Unplug while the window is on the external display — the spec's "current output
   vanishes" case. Record: `cg_reconfig remove=1`, where the window reappears, what
   `window.screen` reports between the unplug and the reappearance, and that nothing
   crashes.
5. While there: toggle the lock screen and confirm `active=0/1` flips on
   `CGGetActiveDisplayList` (validating the headless finding), and whether the
   reconfiguration callback fires on lock/unlock alone.

---

## Findings summary (for `event-sequences.md`)

- **One display, two object models**: `NSScreen` (points, y-up, scale, usable-area
  insets, human name) vs `CGDirectDisplayID` (pixels, top-left origin, modes,
  refresh, physical mm, power state); the `NSScreenNumber` deviceDescription key is
  the bridge. A real renderer needs both per output.
- **Enumeration is global and app-free** — the CG side answered before
  `NSApplication` existed; `NSScreen.screens` needs only AppKit loaded, not a window.
- **`CGDisplayPixelsWide` returns points-scaled units on HiDPI** (1728 for a
  3456-pixel panel); only `CGDisplayModeGetPixelWidth/Height` is honest. Same trap
  family as `NSDeviceResolution`'s logical 144 dpi.
- **The window→output question is answered by AppKit directly** (`window.screen`,
  majority-area rule, valid from init) — no Win32-style on-demand call, no
  X11-style derive-it-yourself.
- **A locked session empties `CGGetActiveDisplayList`** while the online list and
  the whole NSScreen model stay intact — display sleep ≠ display gone, and an
  enumerator keyed on the active list sees zero outputs headless.
- **Hotplug is three independent signals** (app notification, window notification,
  CG callback with add/remove/mode flags) — registration and NSNotification wiring
  proven headless; ordering and the vanishing-output case are Tier C.

---

## Sources

- **This demo** — [`./examples/f09-outputs/app.d`][demo-app],
  [`./examples/f09-outputs/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, locked-session WindowServer evidence),
  the [F08 DPI findings][f08-doc] (the scale side of `NSScreen`), and the
  [AppKit survey][survey].
- **Feature specs** — [F09 outputs][f09]; the Tier-C entry in the
  [manual-run-queue][queue].
- **Apple Developer documentation** (Wayback-pinned where a verified snapshot exists;
  this host is bot-hostile): [`NSScreen.screens`][nsscreen-screens],
  [`deviceDescription`][devicedescription], [`visibleFrame`][visibleframe],
  [`maximumFramesPerSecond`][maxfps], [`localizedName`][localizedname],
  [`NSWindow.screen`][nswindow-screen],
  [`NSWindowDidChangeScreenNotification`][didchangescreen],
  [`NSApplicationDidChangeScreenParametersNotification`][screenparamsnotif],
  [`CGGetActiveDisplayList`][activelist], [`CGGetOnlineDisplayList`][onlinelist],
  [`CGDisplayBounds`][cgdisplaybounds], [`CGDisplayCopyDisplayMode`][copymode],
  [`CGDisplayMode.refreshRate`][refreshrate], [`CGDisplayScreenSize`][screensize],
  [`CGDisplayRegisterReconfigurationCallback`][reconfigcb].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[demo-app]: ./examples/f09-outputs/app.d
[instrument]: ./examples/f09-outputs/instrument.d
[f08-doc]: ./f08-dpi-scaling.md
[f09]: ../features/f09-outputs.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned where a verified snapshot exists) -->

[nsscreen-screens]: https://web.archive.org/web/20250609233211/https://developer.apple.com/documentation/appkit/nsscreen/screens
[devicedescription]: https://developer.apple.com/documentation/appkit/nsscreen/devicedescription
[visibleframe]: https://developer.apple.com/documentation/appkit/nsscreen/visibleframe
[maxfps]: https://web.archive.org/web/20250609072956/https://developer.apple.com/documentation/appkit/nsscreen/maximumframespersecond
[localizedname]: https://web.archive.org/web/20250609072955/https://developer.apple.com/documentation/appkit/nsscreen/localizedname
[nswindow-screen]: https://web.archive.org/web/20250609073609/https://developer.apple.com/documentation/appkit/nswindow/screen
[didchangescreen]: https://web.archive.org/web/20250609073551/https://developer.apple.com/documentation/appkit/nswindow/didchangescreennotification
[screenparamsnotif]: https://web.archive.org/web/20260308081550/https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification
[activelist]: https://web.archive.org/web/20250609085647/https://developer.apple.com/documentation/coregraphics/cggetactivedisplaylist(_:_:_:)
[onlinelist]: https://web.archive.org/web/20250609085647/https://developer.apple.com/documentation/coregraphics/cggetonlinedisplaylist(_:_:_:)
[cgdisplaybounds]: https://web.archive.org/web/20250609085613/https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:)
[copymode]: https://web.archive.org/web/20250609085614/https://developer.apple.com/documentation/coregraphics/cgdisplaycopydisplaymode(_:)
[refreshrate]: https://web.archive.org/web/20250609085617/https://developer.apple.com/documentation/coregraphics/cgdisplaymode/refreshrate
[screensize]: https://web.archive.org/web/20250824112138/https://developer.apple.com/documentation/coregraphics/cgdisplayscreensize(_:)
[reconfigcb]: https://web.archive.org/web/20250609085618/https://developer.apple.com/documentation/coregraphics/cgdisplayregisterreconfigurationcallback(_:_:)
