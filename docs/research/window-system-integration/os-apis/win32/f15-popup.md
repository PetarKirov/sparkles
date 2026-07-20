# Win32 F15 — popup with grab

How a context menu actually works on Win32 when you build it yourself: a
`WS_POPUP` window plus [`SetCapture`][setcapture] — and how fragile that
"grab" is. The demo, [`./examples/f15-popup/app.d`](./examples/f15-popup/app.d),
extends the [scaffold](./scaffold.md) per the [F15 spec][f15]: right-click
opens a 3-item menu at the pointer (hover highlight via capture-routed
motion), item click activates, outside click and Esc dismiss; placement is
app-computed with flip-at-the-edge; a one-level submenu measures the
capture-is-single-window problem; a deliberate capture theft shows the
fragility headline; and [`TrackPopupMenu`][trackpopupmenu] — the system
escape hatch — is probed for its modal loop. Everything is driven by real
injected input (`SetCursorPos` + [`SendInput`][sendinput]), run under **both**
Wine display drivers (winewayland on headless weston, winex11 on bare Xvfb);
both exit `0` with near-identical logs.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything below is `A[wine]`** (Wine 10/11 `wine64`, LDC 1.41.0
> cross-compile; winewayland against `weston --backend=headless`, winex11 on
> bare Xvfb). Capture routing is implemented in Wine's win32u/wineserver, not
> by the backing display server, which is why — unlike [F03][f03-doc]/[F14][f14-doc] —
> the two drivers agree here almost line-for-line. Real-Windows confirmation
> (and real-desktop capture theft by other processes) is the Tier C run.

---

## Capture is the grab — and it is one slot, loosely held

> Only one window at a time can capture the mouse.
>
> — [`SetCapture`][setcapture], Microsoft Learn

The popup must see clicks on windows it does not own. Win32's answer: after
showing the `WS_POPUP` menu, `SetCapture(menu)` routes **all mouse input** to
it, in its own client coordinates (negative / out-of-bounds when the pointer
is elsewhere):

```text
2575484 button state=down screen=72,78 routed_to=0 hit=outside
2575795 popup_dismiss cause=outside_click open=1
```

That click landed over the main window's client area — delivered to the
captured menu anyway. Like [X11's one-grab model][x11-f15], one owner must
serve the whole popup chain, so the demo hit-tests in **screen coordinates**
against the app-known chain rects (`ClientToScreen` + rect list) — the same
one-owner-plus-hit-testing shape X11 forced; on Win32 it is the standard
solution for owner-drawn menus.

Two capture-specific correctness details the logs forced:

- **The opening right-click's release arrives capture-routed** and must be
  swallowed (`button state=release swallowed=open_click`) or it would
  instantly activate the item under the pointer — the same swallow rule as
  the X11 demo, arrived at independently.
- **Keyboard is NOT captured.** Capture redirects mouse input only; keys
  follow focus. The menus are created `WS_EX_NOACTIVATE` (+ `MA_NOACTIVATE`)
  precisely so focus never leaves the main window — Esc then arrives as the
  main window's `WM_KEYDOWN`:

```text
3215734 focus_probe focus=…20064 main=…20064 (keyboard goes to focus, not capture)
3216777 key vk=VK_ESCAPE routed_to=main_focus_window
3217053 popup_dismiss cause=esc open=1
```

If the popup had been allowed to activate, the main window would have lost
focus on open and the [`SetForegroundWindow` restrictions][setforegroundwindow]
("The system restricts which processes can set the foreground window") make
getting activation back unreliable — `WS_EX_NOACTIVATE`
("A top-level window created with this style does not become the foreground
window when the user clicks it" — [extended styles][ws-ex]) sidesteps the
whole problem. This focus juggling is invisible in the logs precisely because
it works: zero `WM_KILLFOCUS` on the main window across all seven popup opens
(the only focus-out in either log is the final `DestroyWindow` teardown).

## The fragility headline: WM_CAPTURECHANGED

> Sent to the window that is losing the mouse capture.
>
> — [`WM_CAPTURECHANGED`][wm-capturechanged], Microsoft Learn

Anyone, at any time, may call `SetCapture` — there is no denial, no
ownership negotiation; the previous owner just gets `WM_CAPTURECHANGED`
naming the thief. The demo measures the theft directly:

```text
5775791 capture_theft_probe api=SetCapture(main)
5776092 msg name=WM_CAPTURECHANGED menu=0 new_owner=…20064 chain_member=-1
5776490 popup_dismiss cause=capture_lost open=1
```

The popup's only correct response to an out-of-chain `WM_CAPTURECHANGED` is
self-dismissal — it can no longer see outside clicks, so staying open would
strand the menu. This is the Win32 popup fragility: the grab is a
**convention**, not a contract (compare X11, where another grab attempt
_fails_ with `AlreadyGrabbed` rather than silently stealing — see
[X11 F15][x11-f15]).

## Submenu: the single slot, measured

A second `WS_POPUP` opens on hovering the last item. Capture cannot cover
two windows, so the demo deliberately moves it to the submenu — and the
parent immediately receives the loss notification:

```text
4495710 popup_open menu=1 anchor=460,261 cause=submenu_hover
4497651 msg name=WM_CAPTURECHANGED menu=0 new_owner=…6007C chain_member=1
4498039 grab state=acquired menu=1 owner=…6007C prev=…7007E readback=…6007C
4814916 …hover menu=1 item=1 … routed_to=1
5136758 item_activated menu=1 item=1
```

`chain_member=1`: naive "lost capture ⇒ dismiss" code would close the whole
menu the moment its own submenu opens. **`WM_CAPTURECHANGED` must be
filtered through chain knowledge** — exactly the lesson X11's one-grab
finding teaches ([X11 F15][x11-f15]), reproduced here in the message that
fires rather than the grab that fails. With capture on the submenu, the
shared screen-coordinate hit-test keeps hover/click working across both
menus (`routed_to=1`, hits resolved against either rect); closing the
submenu hands capture back (`grab state=returned_to_parent`).

## Placement: the app is the positioner

No positioner object exists; the app computes everything against the monitor
work area ([`GetMonitorInfoW`][getmonitorinfo]) and logs the math. Anchor at
the work-area corner:

```text
3535567 popup_place anchor=1020,764 gravity=bottom-right size=160x72
        work=0,0-1024x768 final=860,692 adjust=flip-x,flip-y
3536964 popup_placed menu=0 rect=860,692-160x72
```

One-line contrast: Wayland's `xdg_positioner` makes these constraints
**declarative** (anchor + gravity + `constraint_adjustment`, compositor does
the math); on Win32 the identical flip/slide policy is app code — which is
what a framework positioner API must reduce to here.

And may the popup exceed the output? Measured: yes —

```text
3855555 offscreen_probe requested=944,732 readback=944,732-160x72 monitor_br=1024,768
```

a `SetWindowPos` placing the menu half off the bottom-right corner reads back
verbatim; nothing repositions it (`A[wine]`, both drivers). Win32 will happily
let an unclamped menu render into the void — clamping is purely the app's
job, where Wayland's positioner makes overflow inexpressible.

## TrackPopupMenu — the escape hatch, probed

The system menu API was called once with `TPM_RETURNCMD`
(it "[d]isplays a shortcut menu at the specified location and tracks the
selection of items on the menu" — [`TrackPopupMenu`][trackpopupmenu]):

```text
6096201 trackpopupmenu state=calling pos=300,213
6097145 msg name=WM_ENTERMENULOOP track=1 dt_us=945
6496969 timer id=menu inside_menu_loop dt_us=400769
6497509 msg name=WM_EXITMENULOOP track=1 dt_us=401309
6497797 trackpopupmenu state=returned cmd=0 blocked_us=401597 err=0
```

It works under Wine, and it **blocks**: `WM_ENTERMENULOOP` arrives ~1 ms in,
and the call does not return until something ends the menu — 401 ms here,
ended by [`EndMenu`][endmenu] called from a pre-armed `WM_TIMER` that the
menu's internal pump dispatched **re-entrantly inside the call** — the same
modal-loop anatomy as [F03's size/move loop][f03-doc]
([`WM_ENTERMENULOOP`][wm-entermenuloop]: "Sent to inform a window's procedure
that the window has entered the menu modal loop"). The cost of the escape
hatch is therefore exactly F03's pathology: the calling thread's loop body is
hostage for the menu's lifetime, with only queued-message dispatch surviving.
What it buys: free rendering, keyboard navigation, placement, and dismissal
policy. One Wine-measured divergence to re-check on Windows: in an earlier
revision the menu also dismissed when the tracking window was destroyed
mid-loop, returning `cmd=0 err=0` — i.e. cancellation is indistinguishable
from "no selection" without `TPM_RETURNCMD` discipline.

## Dismissal causes — who decides

All observed causes, with the decider in every case being **the app**:
`item_activated`, `outside_click` (capture-routed hit-test miss), `esc`
(focus-window keydown), `capture_lost` (the one case where the _system_
forces the app's hand — but even then the dismissal itself is app code).
There is no Win32 analogue of Wayland's `xdg_popup.popup_done`, where the
compositor closes the popup and merely informs the client. The full causes
asymmetry table lands in the cross-platform comparison.

## winewayland vs winex11

Same binary, same injected tour, both exit `0`. The only diff in event kinds
across the two logs: winex11 synthesizes an immediate `WM_MOUSEMOVE` to the
fresh capture owner at popup open (an instant `hover` line), winewayland
first delivers motion on the next real warp. Injection itself —
`SetCursorPos` warps and `SendInput` buttons/keys — routed correctly under
**both** drivers, winewayland included (Wine tracks its own cursor position
and does hardware-input routing in wineserver; the Wayland compositor never
sees the synthetic pointer).

## Tier C manual entry (Windows box)

Build `examples/f15-popup/` and run **without** `WSI_AUTO_EXIT`. Right-click
to open: hover all three items (highlight follows), hover `Gamma ▸` (submenu
opens; confirm the parent does NOT close — the `chain_member` filter), click
`Sub-2` (logs `item_activated menu=1 item=1`), reopen and click the desktop
(outside dismissal — also confirms capture sees clicks outside the process,
which headless Wine cannot prove), reopen and press Esc. Then open a menu
near the taskbar corner and check the `popup_place … adjust=` line matches
where the menu appears. Finally confirm a real foreign-app interaction
(click another app's window with the menu open) produces
`cause=outside_click` or `cause=capture_lost` and paste which.

## Build and run

From `docs/research/window-system-integration/os-apis/win32/examples/f15-popup/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f15-popup.exe

# winewayland (headless weston) and winex11 (bare Xvfb) — same recipe as F14:
weston --backend=headless --socket=wsi-f14 --width=1024 --height=768 &
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    WAYLAND_DISPLAY=wsi-f14 DISPLAY= \
    nix develop .#win32 -c wine64 ./build/f15-popup.exe

Xvfb :77 -screen 0 1024x768x24 &
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    XDG_RUNTIME_DIR=$(mktemp -d) DISPLAY=:77 \
    nix develop .#win32 -c wine64 ./build/f15-popup.exe
```

Both exit `0`. Without `WSI_AUTO_EXIT=1` the demo runs interactively
(right-click / hover / click / Esc).

## Sources

- **[F15 spec][f15]** — requirements 1–4 (grab popup, edge correctness,
  submenu, dismissal causes); sibling findings: [X11 F15][x11-f15] (the
  one-grab finding this doc re-derives), [F03][f03-doc] (modal-loop anatomy
  `TrackPopupMenu` shares), [F14][f14-doc] (driver-divergence baseline).
- **Microsoft Learn** (Wayback-pinned unless noted):
  [`SetCapture`][setcapture] (quoted),
  [`WM_CAPTURECHANGED`][wm-capturechanged] (quoted),
  [`TrackPopupMenu`][trackpopupmenu] (quoted), [`EndMenu`][endmenu],
  [`WM_ENTERMENULOOP`][wm-entermenuloop] (quoted; live link — no archive
  snapshot exists), [`SetForegroundWindow`][setforegroundwindow] (quoted),
  [extended window styles][ws-ex] (`WS_EX_NOACTIVATE`, quoted),
  [`SendInput`][sendinput], [`GetMonitorInfoW`][getmonitorinfo].
- Demo sources: [`app.d`](./examples/f15-popup/app.d),
  [`instrument.d`](./examples/f15-popup/instrument.d).

<!-- References -->

[f15]: ../features/f15-popup.md
[f03-doc]: ./f03-modal-loop.md
[f14-doc]: ./f14-window-state.md
[x11-f15]: ../x11/f15-popup.md
[setcapture]: https://web.archive.org/web/20240417130240/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcapture
[wm-capturechanged]: https://web.archive.org/web/20240222185832/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-capturechanged
[trackpopupmenu]: https://web.archive.org/web/20230405105337/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-trackpopupmenu
[endmenu]: https://web.archive.org/web/20250611230528/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-endmenu
[wm-entermenuloop]: https://learn.microsoft.com/en-us/windows/win32/menurc/wm-entermenuloop
[setforegroundwindow]: https://web.archive.org/web/20220928091915/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow
[ws-ex]: https://web.archive.org/web/20220928091907/https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles
[sendinput]: https://web.archive.org/web/20260518160717/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
[getmonitorinfo]: https://web.archive.org/web/20240121161421/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmonitorinfow
