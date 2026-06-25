# X11 F15 — popup with grab

How a context menu actually works on X11: an [override-redirect][or-attr]
window the WM never touches, plus a **pointer grab** that funnels the whole
session's input to one client — including the outside click that dismisses
the menu. The demo, [`./examples/f15-popup/app.d`](./examples/f15-popup/app.d),
extends the [scaffold](./scaffold.md) per the [F15 spec][f15]: right-click
opens a 3-item menu at the pointer (hover highlight via grab-routed motion),
item click activates, outside click and Esc dismiss; a one-level submenu
opens on hovering the last item; the popup self-clamps at the screen edge;
and an independent second client (own `Display*` connection, own window)
measures who gets events while the grab is held. Runs are Tier A under
`xvfb-run`, each scenario on bare Xvfb (no WM) **and** under `icewm` —
which, uniquely in this demo series, changes almost nothing. All passes:
**0 X errors, exit 0**.

**Last reviewed:** June 11, 2026

## The grab IS the popup model

A popup must see clicks on windows it does not own. X11's answer is
[`XGrabPointer`][xgrabpointer] on the popup with `owner_events=False`:

> If `owner_events` is `False`, all generated pointer events are reported
> with respect to `grab_window` and are reported only if selected by
> `event_mask`.

```text
1512740 f15_x11 grab state=acquired pointer=GrabSuccess keyboard=GrabSuccess owner_events=0
...
4842558 f15_x11 button state=press n=1 window=0x200002 pos=369,-131 root=570,70 grabbed=1
4842574 f15_x11 popup_dismiss cause=outside_click
```

That click landed over the _second client's_ window at root (570,70) — yet
it arrives at the grabbing client, reported relative to the popup
(`pos=369,-131`, outside its 160×72 bounds). The demo therefore hit-tests in
**root coordinates** against the app-known popup-chain rects. Dismissal
causes observed: `item_activated`, `outside_click`, `esc`,
`submenu_parent_hover` (submenu only). On X11 _the app_ decides dismissal in
every case — there is no `popup_done`-style event where the server/WM decides
(the Wayland asymmetry the [F15 spec][f15] asks about).

Two correctness details the logs forced:

- **The opening click's release must be swallowed** — it would otherwise
  instantly "activate" the item under the pointer
  (`button state=release swallowed=open_click`).
- **That release can outrun the grab**: the physical release may reach the
  server before the `XGrabPointer` issued in response to the press, in which
  case it is delivered by the window's normal event masks — the main window
  must select `ButtonReleaseMask` too, or the release vanishes (measured: the
  swallow flag then ate the _next_ legitimate click).

## Placement: the app is the positioner

Opening near the bottom-right corner of the 640×480 screen:

```text
1305830 f15_x11 popup_open menu=0 anchor=630,470 gravity=bottom-right cause=auto_edge
1305868 f15_x11 popup_placed menu=0 rect=160x72+478+406 repositioned=1 clamp=anchor+size>screen(640x480)
```

The clamp (`x = screenW − w − border`, same for `y`) is plain app arithmetic;
nobody else will do it — under icewm the math and result are identical,
because override-redirect windows bypass the WM entirely (next section). The
window _may_ also be placed beyond screen bounds; nothing stops it (the same
"logical geometry is unclipped" behavior the [scaffold](./scaffold.md#surprises)
saw for resizes). Contrast Wayland in one line: an `xdg_positioner` ships the
anchor/gravity/`constraint_adjustment` _declaration_ to the compositor, which
slides/flips the popup and reports the final geometry back — on X11 that
entire mechanism is app-side `if` statements.

## Hover, submenu, activation (driven run, bare Xvfb)

```text
2121449 f15_x11 hover menu=0 item=0
2425669 f15_x11 hover menu=0 item=1
2730003 f15_x11 hover menu=0 item=2
2730028 f15_x11 popup_open menu=1 anchor=356,248 gravity=bottom-right cause=submenu_hover
2730033 f15_x11 popup_placed menu=1 rect=160x72+356+248 repositioned=0 ...
2730082 f15_x11 stacking probe=after_map_raised topmost=0x200003 expected=0x200003 on_top=1
3234478 f15_x11 hover menu=1 item=0
3638736 f15_x11 button state=press n=1 window=0x200002 pos=195,59 root=396,260 grabbed=1
3638772 f15_x11 popup_item_activated menu=1 item=0
3638785 f15_x11 popup_dismiss cause=item_activated
```

Hover highlight is just grab-routed `MotionNotify` + root-coordinate
hit-testing. **The submenu takes no grab of its own**: the demo keeps the
single pointer grab on the first popup and extends the hit-test to the chain
(submenu checked first — it is topmost). With `owner_events=False` every
event already names the grab window, so adding surfaces costs nothing. The
alternatives — `owner_events=True` (events route to whichever _of your own_
windows the pointer is in, the GTK approach) or re-grabbing on the submenu
(a grab-transfer race window between ungrab and grab) — buy nothing here;
the chain hit-test is the simplest correct model. Note the press event
itself: `window=0x200002` (the grab window, popup 1) even though the pointer
was over popup 2 — root coordinates are the only usable ones.

## Who gets events during the grab: everyone else starves

The second client (own connection `fd=4`, yellow 100×100 window) selects
`ButtonPressMask`. While the popup grab is held, a click dead-center on it:

```text
4849598 f15_x11 button state=press n=1 window=0x400002 pos=-239,-131 root=54,74 grabbed=1
4849652 f15_x11 popup_dismiss cause=outside_click
        (second client: nothing — not now, not later)
5454746 f15_x11 second_client event=button_press pos=50,50 during_grab=0
```

The grab-time click is consumed entirely by the grabbing client; the starved
click is **not queued and replayed** to the second client after the ungrab
(that replay machinery exists only for _synchronous_ grabs and
`AllowEvents`). The identical click after dismissal arrives normally. A
session-global popup grab thus silently eats other apps' input — which is
why misbehaving X11 menus freeze whole desktops, and why Wayland scopes
`xdg_popup.grab` to the requesting client's surfaces.

What if another grab already exists? [`XGrabPointer`][xgrabpointer] reports
it as a synchronous return code, not an event — "If the pointer is actively
grabbed by some other client, it fails and returns `AlreadyGrabbed`":

```text
2008201 f15_x11 probe name=second_client_grab result=GrabSuccess
2008257 f15_x11 probe name=our_grab_while_other_holds result=AlreadyGrabbed
2008305 f15_x11 probe name=our_grab_after_release result=GrabSuccess
```

So a popup implementation must handle "grab refused" at open time (fall back
to no-grab + dismiss-on-focus heuristics, or retry). The other documented
failure modes are return codes too (`GrabNotViewable` — the popup must be
mapped _before_ grabbing; `GrabInvalidTime`; `GrabFrozen`), and per the same
page an in-progress grab ends automatically "if the event window or
`confine_to` window becomes not viewable" — unmapping the popup without
`XUngrabPointer` would drop the grab mid-flight, another silent breaker.

## The focus model mess

The popup never has, wants, or receives window-manager focus —
`_NET_ACTIVE_WINDOW` keeps pointing at whatever was active. Keyboard input
arrives purely through [`XGrabKeyboard`][xgrabkeyboard], which by definition
"actively grabs control of the keyboard and generates `FocusIn` and
`FocusOut` events". Those grab-focus events are visible on the popup,
flagged by their mode:

```text
6052692 f15_x11 focus window=0x200002 state=out mode=NotifyGrab
6052695 f15_x11 focus window=0x200002 state=in mode=NotifyGrab
6657177 f15_x11 key sym=0xff1b via_grab=1
6657193 f15_x11 popup_dismiss cause=esc
6657204 f15_x11 focus window=0x200002 state=out mode=NotifyUngrab
```

Every `FocusIn` the popup ever sees is `mode=NotifyGrab`/`NotifyUngrab` —
server grab bookkeeping, never `NotifyNormal` (the summary's
`popup_focus_events` were grab-mode in every pass). Esc works because of the keyboard grab and _only_
because of it. The mess for a framework: "focused widget" (app concept),
"focused window" (WM concept) and "keyboard delivery target" (grab concept)
are three different things while a menu is open, on the same connection.

## What the WM changes: nothing (that's the point)

Per the [Xlib window-attributes definition][or-attr], "The override-redirect
flag specifies whether map and configure requests on this window should
override a `SubstructureRedirectMask` on the parent" — the map never becomes
a `MapRequest`, so icewm never decorates, repositions, focuses, or even
learns about the popup. Measured identical across bare Xvfb and icewm:
placement (same clamp result), grab return codes, starvation, focus-via-grab,
and stacking — `XMapRaised` put the popup above icewm's frames every time
(`XQueryTree` probe: `on_top=1` in all passes; nothing contests the raise,
though nothing _guarantees_ it against a WM that restacks later — EWMH
layering does not apply to unmanaged windows). The only icewm-visible
difference is indirect: the _main_ window is reparented/placed by the WM, so
the driven run re-derives click coordinates from the WM-assigned position
(`run.sh` does this with `xdotool getwindowgeometry`).

## Findings

- **Placement ownership is 100 % app-side.** Anchor, gravity, edge
  slide/flip, submenu offset — all hand arithmetic against
  `XDisplayWidth/Height`; the platform neither constrains nor assists. (A
  framework positioner API must _compute_ on X11 what it merely _declares_
  on Wayland.)
- **Dismissal ownership is 100 % app-side too** — outside-click detection
  exists only because the grab reroutes foreign events; there is no
  server/WM "popup done" signal. Esc requires the separate keyboard grab.
- **One grab serves the whole popup chain** (`owner_events=False` +
  root-coordinate hit-testing); submenus need no grab transfer.
- **Grabs are session-global and starve every other client** — eaten events
  are not replayed (async grab); refusal is a return code
  (`AlreadyGrabbed`) the opener must handle; unmapping the grab window
  drops the grab implicitly.
- **The popup is focus-invisible**: keyboard comes via the grab; all its
  focus events are `mode=NotifyGrab` bookkeeping. The WM's activation state
  never changes.
- **Two micro-contracts of click-to-open**: swallow the opening click's
  release, and select `ButtonReleaseMask` on the opener (the release can
  beat the grab to the server).
- The override-redirect + grab combo behaves **identically with and without
  a WM** — the only demo in this series so far where icewm changes nothing.

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f15-popup
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f15-popup
```

The self-driven run (also what CI does) needs no input tool: it probes
placement, edge clamping, stacking, and the grab return codes, then exits 0.
The full four-pass choreography — hover/submenu/activation, outside-click
starvation, and Esc, on bare Xvfb and under icewm — is scripted in
`examples/f15-popup/run.sh` (run from the dev shell; it pulls `xdotool` and
`icewm` via `nix shell`). Interactively: right-click opens the menu, `q`
quits. No reachable display prints `SKIP: no X11 display` and exits 0.

## Sources

- **[F15 spec][f15]** — requirements 1–4 (popup + grab, edge correctness,
  nested submenu, dismissal-cause logging).
- **Xlib reference (Tronche mirror)** — [`XGrabPointer`][xgrabpointer]
  (owner-events rule, return codes, auto-ungrab; verbatim quotes above),
  [`XGrabKeyboard`][xgrabkeyboard] (grab-generated focus events),
  [override-redirect][or-attr] (the WM-bypass contract).
- **[xdg-shell protocol][xdg-shell]** — `xdg_positioner`/`xdg_popup.grab`,
  the contrast model referenced above.
- **[X11 F14 findings](./f14-window-state.md)** — the focus mode/detail
  decode shared by both demos; **[scaffold](./scaffold.md)** — base loop and
  the unclipped-geometry surprise.
- Demo sources: [`app.d`](./examples/f15-popup/app.d),
  [`instrument.d`](./examples/f15-popup/instrument.d), the `c.c` ImportC
  shim, and `run.sh` alongside them.

<!-- References -->

[f15]: ../features/f15-popup.md
[xgrabpointer]: https://tronche.com/gui/x/xlib/input/XGrabPointer.html
[xgrabkeyboard]: https://tronche.com/gui/x/xlib/input/XGrabKeyboard.html
[or-attr]: https://tronche.com/gui/x/xlib/window/attributes/override-redirect.html
[xdg-shell]: https://wayland.app/protocols/xdg-shell
