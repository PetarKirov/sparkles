# AppKit F15 — Popup with grab

macOS has **no popup grab**: per the [F15 feature spec][f15], the context menu a
framework must synthesize from raw windows is a borderless `NSWindow`
(`NSWindowStyleMaskBorderless`) raised to [`NSPopUpMenuWindowLevel`][level], and
"dismiss on outside click" has to be assembled from events the popup never
receives. The program is [`./examples/f15-popup/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger, on the [scaffold][scaffold] recipe): a
3-item menu panel with [`NSTrackingArea`][nstrackingarea] hover, **both** dismissal
mechanisms — (a) [local][localmonitor]/[global][globalmonitor] `NSEvent` monitors
and (b) [`canBecomeKeyWindow`][canbecomekey] + `windowDidResignKey` — Esc via
`keyDown:` → [`interpretKeyEvents:`][interpretkeyevents] →
[`cancelOperation:`][canceloperation], app-computed edge clamping (with
[`constrainFrameRect:toScreen:`][constrainframerect] probed for borderless
auto-clamp), and a one-level submenu as a child window
([`addChildWindow:ordered:`][addchildwindow]).

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** (the demo
logs `session screen_locked=1` via `CGSessionCopyCurrentDictionary`). All input is
synthetic, per the [F06][f06-doc]/[F10][f10-doc] recipes (CGEvent-wrapped
right-click; plain `NSEvent` clicks/keys); the lock means **no window can become
key**, so mechanism (b) is honestly reported untestable here (Tier C), while
mechanism (a), Esc, placement, and child windows all proved out headless.

| Measurement                       | Value                                                                                          |
| --------------------------------- | ---------------------------------------------------------------------------------------------- |
| Window-level ladder (CG readback) | `normal=0 floating=3 popup_menu=101 screensaver=1000 maximum=2147483631`                       |
| Popup level used                  | `101` (`CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey)` = `NSPopUpMenuWindowLevel`)           |
| Off-screen frame accepted?        | **yes** — borderless window placed at `(1698,-44)` on a 1728-wide screen, readback unchanged   |
| `constrainFrameRect:toScreen:`    | called 2× per open (`screen_nil=1` at init, `=0` at order-front), **identity** — no auto-clamp |
| Placement owner                   | **the app** — slide/flip clamp math logged; `setFrameOrigin` readback exact                    |
| Local monitor                     | sees **queued** events (`postEvent:` route); events injected via `sendEvent:` bypass it        |
| Global monitor                    | installs fine (no permission prompt for mouse), saw **0** events (in-process + locked session) |
| Esc                               | `keyDown:` → `interpretKeyEvents:` → `cancelOperation:` — **works without key status**         |
| Key-window status                 | `is_key=0` even after `makeKeyAndOrderFront:` (locked session) → mechanism (b) Tier C          |
| Tracking-area hover               | synthetic `mouseMoved` via `sendEvent:` delivered **0** events — enter/exit are cursor-driven  |
| Submenu (child window)            | `addChildWindow:ordered:NSWindowAbove`; parent moved (+24,+24) → child followed exactly        |
| Dismissal causes observed         | `outside_click_local_monitor`, `esc_cancelOperation`, `shutdown` (resign-key: Tier C)          |
| Exit                              | clean `0` (`loop_exit steps=12 opens=3 local_seen=1 global_seen=0`)                            |

---

## Building the popup `A[ssh]`

A synthetic right-click (CGEvent-wrapped, `eventWithCGEvent:` — the wrapped event
carries `win=0`, so `[window sendEvent:]` dropped it and the demo fell back to the
direct `rightMouseDown:` call, the standing [F10][f10-doc] locked-session shape)
opens the popup below-right of the click:

```text
587398 APPKIT_F15 popup_open cause=right_click anchor=(480,400) gravity=bottom_right want=(480,316 160x84) …
602930 APPKIT_F15 constrain_frame_rect in=(480,316 160x84) out=(480,316 160x84) screen_nil=1
605555 APPKIT_F15 popup_placed rect=(480,316 160x84) level=101 is_key=0 can_become_key=1
```

- `NSWindowStyleMaskBorderless` is mask `0` — "borderless" is the _absence_ of
  every style bit, not a flag.
- The level ladder read back from `CGWindowLevelForKey`:
  `kCGNormalWindowLevel=0`, `kCGFloatingWindowLevel=3`, **`kCGPopUpMenuWindowLevel=101`**
  (what real menus use, and what the popup gets via [`setLevel:`][level]),
  `kCGScreenSaverWindowLevel=1000`, `kCGMaximumWindowLevel=2147483631`.
- The `canBecomeKeyWindow` override (pure-D subclass, per the [scaffold][scaffold]
  recipe) reads back `1` — by default a borderless window **refuses key status**
  ([`canBecomeKeyWindow`][canbecomekey] documents "`true` when the window has a
  title bar or a resize bar"), which would make both Esc-as-key-event and
  mechanism (b) impossible. The override is mandatory for a menu-like window.
- Yet `is_key=0` even immediately after `makeKeyAndOrderFront:` — the locked
  session grants key status to no window (same result as [F14][f14-doc]'s zero
  focus events). Everything below that _needs_ key status is Tier C.

## Placement ownership: the app, and only the app `A[ssh]`

The edge test opens the popup **unclamped** at an anchor 30 pt from the
bottom-right screen corner:

```text
1853220 APPKIT_F15 popup_open cause=edge_test_bottom_right anchor=(1698,40) … want=(1698,-44 160x84) placed=(1698,-44 160x84) app_clamp=0 screen=1728x1117
1859778 APPKIT_F15 constrain_frame_rect in=(1698,-44 160x84) out=(1698,-44 160x84) screen_nil=1
1861837 APPKIT_F15 popup_placed rect=(1698,-44 160x84) level=101 …
2103720 APPKIT_F15 edge_clamp offscreen_frame=(1698,-44) app_clamped_to=(1568,40) readback=(1568,40) owner=app
```

- **A borderless window may hang off the screen** — frame `(1698,-44 160x84)` on
  a 1728×1117 screen (130 pt past the right edge, 44 pt below the bottom) is
  accepted and read back verbatim. Nobody repositions it: not AppKit, not the
  WindowServer.
- [`constrainFrameRect:toScreen:`][constrainframerect] **is** called — twice per
  open (once during `initWithContentRect:` with `screen:nil`, once at
  order-front with a real screen) — but the `super` implementation returns the
  input **unchanged** for a borderless window. Its documented job is keeping
  _titled_ windows' title bars on screen; for menu-like surfaces it is a no-op
  hook, useful only as the place where an app could _install_ its own clamping.
- The app-side math (slide left off the right edge, flip above the anchor off the
  bottom — the same `constraint_adjustment` vocabulary Wayland's positioner
  declares declaratively) lands the popup at `(1568,40)`, and `setFrameOrigin`
  readback is exact. **Placement ownership on macOS is 100% app-computed
  geometry** — the platform expresses no anchor/gravity/constraint concept for
  plain windows.

## Dismissal — who decides, and what each mechanism sees `A[ssh]`

### (a) Event monitors

```text
1596498 APPKIT_F15 inject kind=left_click label=outside_click win=28411 loc=(50,50) route=postEvent
1597277 APPKIT_F15 monitor scope=local type=1 win=28411 outside_popup=1
1597304 APPKIT_F15 popup_dismiss cause=outside_click_local_monitor
```

- The [local monitor][localmonitor] fired for the outside click **because it was
  queued** (`postEvent:` → run-loop dispatch); the same demo's events injected
  via `[window sendEvent:]` (right-click, item click) **never hit the monitor** —
  local monitors hook the application's event _dispatch_ path, not arbitrary
  `sendEvent:` calls. A framework dismissing popups this way sees real user input
  (always queued) but not its own short-circuited synthetic events.
- The handler returns the event, so the click still reaches its target window —
  monitor-as-observer, dismissal as a side effect. Returning `nil` would swallow
  it ("eat the click" vs "click-through", the classic menu UX decision, is one
  `return` statement here).
- The [global monitor][globalmonitor] installed without any permission prompt
  (mouse events need no Accessibility grant; key monitoring does) but saw **0**
  events: it only observes _other applications'_ events, and an SSH-launched
  process under a locked console has none to observe. Its real-session role —
  dismissing when the user clicks a _different app_ — is Tier C.

### (b) Key-window resignation

`windowDidResignKey:` on the popup's delegate is the idiomatic dismissal (it is
what `NSPanel`-based pickers use), but it requires the popup to _have_ key status
to lose — and under the locked session `makeKeyAndOrderFront:` leaves
`is_key=0`, so the delegate never fires:

```text
2847212 APPKIT_F15 popup_focus action=makeKeyAndOrderFront_main popup_is_key=0
2847273 APPKIT_F15 popup_focus mechanism_b=untestable_headless note=no_window_gets_key_status_in_locked_session tier_c=resign_key_dismissal
```

The two mechanisms are not equivalent even in a real session: monitors see the
click _and_ let the popup decide; resign-key tells the popup only that focus went
_somewhere_, after the fact — but resign-key also covers Cmd-Tab and programmatic
focus steals, which no mouse-mask monitor reports. Real menus need both (or
`NSMenu`, below).

### Esc

```text
2346813 APPKIT_F15 inject kind=esc keycode=53 win=28414 is_key=0 route=sendEvent
2346997 APPKIT_F15 key event=keyDown keycode=53 routing=interpretKeyEvents
2349198 APPKIT_F15 key esc_route=cancelOperation
2349242 APPKIT_F15 popup_dismiss cause=esc_cancelOperation
```

`keyDown:` hands the event to [`interpretKeyEvents:`][interpretkeyevents] and the
text system maps Esc (keycode 53) to [`cancelOperation:`][canceloperation] — the
Cocoa-idiomatic cancel route (the demo's raw-keycode fallback never triggered).
Direct `sendEvent:` delivery works even without key status; with _real_ keyboard
input the window must be key for events to arrive at all — the
`canBecomeKeyWindow` override again.

## Hover and the submenu `A[ssh]`

- **Tracking areas are cursor-driven.** A synthetic `mouseMoved` through
  `sendEvent:` delivered nothing (`delivered_to_view=0 entered_fired=0`):
  `mouseEntered:`/`mouseExited:` are generated by the WindowServer from actual
  cursor geometry, not synthesized from move events in the app ([F12][f12-doc]
  hit the identical wall with `cursorUpdate:`). The demo drives the highlight
  directly; real hover is Tier C.
- **The child-window relationship does the submenu's bookkeeping:**

```text
1101873 APPKIT_F15 submenu_open rect=(636,344 160x56) parent_win=28412 child_win=28413 level_parent=101 level_child=101 ordered=NSWindowAbove
1353901 APPKIT_F15 child_move parent_moved=(+24,+24) child_before=(636,344) child_after=(660,368) parent_of_child=28412
```

[`addChildWindow:ordered:`][addchildwindow] with `NSWindowAbove` keeps the
submenu stacked over its parent, at the same level `101`, and **moves it with the
parent exactly** (+24,+24 in, +24,+24 out) — the platform maintains the
parent-relative offset, so a framework only positions the submenu once. There is
no Wayland-style requirement that the child chain be popups; any window can
parent any other. `parentWindow` reads back the link; `removeChildWindow:` on
dismissal is mandatory before ordering out, or the child follows the parent's
fate at unexpected times.

## The escape hatch: `NSMenu`

[`NSMenu`][nsmenu]'s `popUpMenuPositioningItem:atLocation:inView:` does all of the
above for free — WindowServer-side placement and edge flipping, hover, submenus,
key navigation, Esc, outside-click dismissal, screen-capture exclusion, and
accessibility — at the cost of control: menu tracking runs a **modal internal
loop in `NSEventTrackingRunLoopMode`**, the very mode [F03][f03-doc] measured
starving every default-mode timer for the duration (`0` ticks delivered during
tracking). The app's loop does not pump while the menu is up; anything that must
keep animating needs its timers added to the tracking mode explicitly. Custom
popup windows (this demo) keep the app's loop running and the menu's look/behavior
fully scriptable — which is why every non-native-look toolkit ends up writing
exactly this window-plus-monitors machinery.

## Surprises

1. **Nothing clamps a borderless window** — `constrainFrameRect:toScreen:` is
   invoked but is an identity for borderless windows; a menu may hang off-screen
   until the app does its own math (the opposite of Wayland, where the
   compositor enforces the positioner's constraints).
2. **Local monitors miss `sendEvent:`-injected events** — they observe the
   queue-dispatch path only; "monitor + postEvent" is the only headless way to
   exercise them.
3. **The global monitor needs no permission for mouse masks** — it installed
   silently; its blindness here is environmental (no other-app events exist),
   not a denial.
4. **Esc dismissal is two overrides away from impossible**: without
   `canBecomeKeyWindow=YES` a borderless popup can never receive real key
   events; without routing `keyDown:` into `interpretKeyEvents:` there is no
   `cancelOperation:`.
5. **Child windows really are "move with parent"** — pixel-exact offset
   preservation with zero app code, the one piece of popup bookkeeping AppKit
   does own.
6. **`kCGPopUpMenuWindowLevel=101`** sits far above floating (`3`) but far below
   the screen saver (`1000`) — the lock screen outranks menus, consistent with a
   popup opened during this locked-session run never compositing.

## Sources

- **This demo** — [`./examples/f15-popup/app.d`][demo-app],
  [`./examples/f15-popup/instrument.d`][instrument]; the [scaffold
  findings][scaffold]; the [F03 modal-loop][f03-doc], [F06 keyboard][f06-doc],
  [F10 pointer-capture][f10-doc], and [F12 cursors][f12-doc] findings.
- **Feature spec** — [F15 popup with grab][f15].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSWindow.level`][level], [`canBecomeKeyWindow`][canbecomekey],
  [`constrainFrameRect:toScreen:`][constrainframerect],
  [`addChildWindow:ordered:`][addchildwindow],
  [`addLocalMonitorForEventsMatchingMask:handler:`][localmonitor],
  [`addGlobalMonitorForEventsMatchingMask:handler:`][globalmonitor],
  [`NSTrackingArea`][nstrackingarea],
  [`interpretKeyEvents:`][interpretkeyevents],
  [`cancelOperation:`][canceloperation], [`NSMenu`][nsmenu],
  [`NSEventTrackingRunLoopMode`][nseventtrackingrunloopmode].

<!-- References -->

<!-- This tree -->

[demo-app]: ./examples/f15-popup/app.d
[instrument]: ./examples/f15-popup/instrument.d
[scaffold]: ./scaffold.md
[f03-doc]: ./f03-modal-loop.md
[f06-doc]: ./f06-keyboard.md
[f10-doc]: ./f10-pointer-capture.md
[f12-doc]: ./f12-cursors.md
[f14-doc]: ./f14-window-state.md
[f15]: ../features/f15-popup.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[level]: https://web.archive.org/web/20250609073602/https://developer.apple.com/documentation/appkit/nswindow/level-swift.property
[canbecomekey]: https://web.archive.org/web/20220721174816/https://developer.apple.com/documentation/appkit/nswindow/1419543-canbecomekeywindow
[constrainframerect]: https://web.archive.org/web/20250609073547/https://developer.apple.com/documentation/appkit/nswindow/constrainframerect(_:to:)
[addchildwindow]: https://web.archive.org/web/20250917235327/https://developer.apple.com/documentation/appkit/nswindow/addchildwindow(_:ordered:)
[localmonitor]: https://web.archive.org/web/20260112124149/https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
[globalmonitor]: https://web.archive.org/web/20260216143124/https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
[nstrackingarea]: https://web.archive.org/web/20260309133336/https://developer.apple.com/documentation/appkit/nstrackingarea
[interpretkeyevents]: https://web.archive.org/web/20240303093433/https://developer.apple.com/documentation/appkit/nsresponder/1531599-interpretkeyevents
[canceloperation]: https://web.archive.org/web/20260603234149/https://developer.apple.com/documentation/appkit/nsresponder
[nsmenu]: https://web.archive.org/web/20260211182724/https://developer.apple.com/documentation/appkit/nsmenu
[nseventtrackingrunloopmode]: https://web.archive.org/web/20260218184626/https://developer.apple.com/documentation/appkit/nseventtrackingrunloopmode
