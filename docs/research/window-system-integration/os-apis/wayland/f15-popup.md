# Wayland F15 — Popup with grab

Who places a context menu, and who closes it? On Wayland the client never
computes the final position and never sees the outside click — it submits a
declarative `xdg_positioner` recipe and receives a compositor _decision_ in
`xdg_popup.configure`, and dismissal arrives as a bare `xdg_popup.popup_done`.
The demo, [`./examples/f15-popup/app.d`](./examples/f15-popup/app.d), extends
the [scaffold](./scaffold.md) to the [F15 spec][f15] with four scenarios: a
right-click 3-item menu with `xdg_popup.grab`, hover highlight, an explicit
v3 `reposition` probe and a nested submenu chain (`menu`); the same menu at
the output's bottom-right corner where the compositor must constrain
(`edge`, dismissed by Esc on the grab's `wl_keyboard`); a grab with a serial
that never came from any input event (`stale`); and a grab-less baseline for
seat-less headless weston (`noinput`). Verified Tier A under headless
weston 15 (socket `wsi-w8a`) and headless sway 1.11; all runs exit `0`.
Input is injected by the binary's own `inject` mode — **one**
`zwlr_virtual_pointer_v1` device held across a whole scenario (see
[Pointer-capability flap](#the-pointer-capability-flap-does-not-dismiss-the-grab)
for why), plus a `wtype` virtual keyboard for Esc.

**Last reviewed:** June 11, 2026

## Placement is a compositor decision, not an echo

The client's request is a constraint _recipe_: a 1×1 anchor rect at the click
position, `anchor=bottom_right`, `gravity=bottom_right`,
`constraint_adjustment=15` (`slide_x|slide_y|flip_x|flip_y`). The
`xdg_popup.configure` that answers is the compositor's solution, in
coordinates "relative to the upper left corner of the window geometry of the
parent surface" ([xdg-shell][p-xdg], `xdg_popup.configure`). Unconstrained
(click at surface (180,180)), sway and weston both answer the identity
solution:

```text
2802154 f15_wayland popup_open idx=popup1 parent=main anchor_rect=180,180 1x1 anchor=8 gravity=8 adjustment=15 size=160x96 note=context-menu
2802160 f15_wayland grab idx=popup1 serial=10 state=requested
2802446 f15_wayland popup_placed idx=popup1 x=181 y=181 size=160x96
```

The `edge` scenario forces a real decision: the parent window floats at
(632,232) on the 1280×720 output, the click is at surface (600,450) — the
160×96 popup cannot fit down-right (it would span global (1233,683)–(1393,779),
113 px past the right edge, 59 px past the bottom). With all four adjustment
bits offered, **sway picks flip on both axes**, not slide:

```text
2802409 f15_wayland button surface=main serial=32 button=0x111 state=1
2802484 f15_wayland popup_open idx=popup1 parent=main anchor_rect=600,450 1x1 anchor=8 gravity=8 adjustment=15 size=160x96 note=context-menu
2802662 f15_wayland popup_placed idx=popup1 x=440 y=354 size=160x96
```

`x=440 = 600−160`, `y=354 = 450−96`: the popup is mirrored about the anchor
point on both axes (the menu opens up-left of the cursor), exactly the
[xdg_positioner][p-xdg] `flip_x`/`flip_y` definition — "invert the anchor and
gravity on the x/y axis if the surface is constrained". A slide solution
would instead have been `x=488` (pinned to the output's right edge). The
popup never exceeds the output: the placement question of the
[F15 spec][f15] requirement 2 is answered entirely compositor-side, with the
client's first knowledge of it being the configure. The full
`WAYLAND_DEBUG=1` exchange around it:

```text
[2345724.630]  -> xdg_surface#15.get_popup(new id xdg_popup#16, xdg_surface#8, xdg_positioner#13)
[2345724.659]  -> xdg_popup#16.grab(wl_seat#7, 32)
[2345724.684]  -> wl_surface#14.commit()
[2345724.767] xdg_popup#16.configure(440, 354, 160, 96)
[2345724.789] xdg_surface#15.configure(33)
```

(The popup obeys the same no-buffer-first-commit / configure / ack contract
as a toplevel — the buffer is only attached after `ack_configure`.)

## Explicit reposition (xdg_popup v3), round-tripped

Both compositors honour the v3 `reposition` request (`xdg_wm_base` is
advertised at v5+ by weston 15 and sway 1.11). 350 ms after the menu maps,
the demo submits a fresh positioner with the same recipe plus
`set_offset(24,16)` and `reposition(token=7)`; the answer is the documented
three-part sequence — `repositioned`, `xdg_popup.configure`,
`xdg_surface.configure`:

```text
[2337057.041]  -> xdg_popup#16.reposition(xdg_positioner#13, 7)
[2337057.131] xdg_popup#16.repositioned(7)
3182602 f15_wayland popup_placed idx=popup1 x=205 y=197 size=160x96
3182606 f15_wayland configure idx=popup1 serial=13 size=160x96
```

`(205,197) = (181,181) + (24,16)` — and the injector's subsequent hover
coordinates target the _repositioned_ items and land exactly
(`pointer_enter surface=popup1 pos=70.0,19.0` = item 0's interior), which
geometrically confirms the move happened on screen, not just in the log.
The positioners also carry `set_reactive` (v3), opting in to spontaneous
compositor-initiated reconfigures on environment changes.

## The nested chain and topmost-first dismissal

The protocol _requires_ the parent chain for a second grabbing popup —
[xdg_popup.grab][p-xdg], verbatim from the XML:

> The parent of a grabbing popup must either be an xdg_toplevel surface or
> another xdg_popup with an explicit grab. If the parent is another
> xdg_popup it means that the popups are nested, with this popup now being
> the topmost popup.
>
> Nested popups must be destroyed in the reverse order they were created
> in, e.g. the only popup you are allowed to destroy at all times is the
> topmost one.
>
> When compositors choose to dismiss a popup, they may dismiss every nested
> grabbing popup as well. When a compositor dismisses popups, it will
> follow the same dismissing order as required from the client.

The demo's submenu is therefore `get_popup(parent=popup1's xdg_surface)` with
its own `grab` carrying the item-click serial. A left click at (150,650) —
on the desktop background, outside every surface of the client — then
produces compositor-side dismissal in exactly the promised order, topmost
first, with **no button event ever reaching the client**:

```text
5382500 f15_wayland popup_open idx=popup2 parent=popup1 anchor_rect=4,62 152x26 anchor=7 gravity=8 adjustment=6 size=140x64 note=submenu
[2339257.025]  -> xdg_popup#21.grab(wl_seat#7, 16)
5382576 f15_wayland popup_placed idx=popup2 x=156 y=62 size=140x64
...                                  (outside click — nothing delivered)
[2340437.119] xdg_popup#21.popup_done()
6562636 f15_wayland popup_dismiss idx=popup2 cause=popup_done order=1
[2340437.227] xdg_popup#16.popup_done()
6562712 f15_wayland popup_dismiss idx=popup1 cause=popup_done order=2
```

This is the [F15 spec][f15]'s requirement-4 asymmetry in one trace: on
Wayland the _compositor_ decides dismissal and merely notifies
(`popup_done` — "the client should destroy the xdg_popup object at this
point"); the outside click is fundamentally uncapturable by the client,
where X11/Win32/macOS clients must capture it themselves.

## Esc rides the grab's keyboard — mostly

Per the grab contract, "the top most grabbing popup will always have
keyboard focus" ([xdg_popup.grab][p-xdg]). The `edge` scenario delivers Esc
through a `wtype`-plugged virtual keyboard while the grab is held; the demo
decodes the keymap fd with `libxkbcommon` (the virtual keyboard ships a
generated keymap — raw keycodes are meaningless, only the keysym lookup
identifies `XKB_KEY_Escape`):

```text
5505224 f15_wayland seat_capabilities caps=3
5505315 f15_wayland keymap format=1 size=23833
5505593 f15_wayland keyboard_enter surface=main serial=36 keys_down=0
5505614 f15_wayland key key=1 keysym=0xff1b state=1
5505631 f15_wayland popup_dismiss idx=popup1 cause=esc-grab-keyboard
```

Two measured nuances:

- **sway sends the `wl_keyboard.enter` for the parent toplevel, not the
  popup**, even though a grab is active — the keys still reach the client
  (same connection), so Esc works, but the spec's "topmost popup … keyboard
  focus" wording is not literally observable in the enter's surface argument
  when the keyboard capability appears mid-grab.
- The Esc press can arrive **inside the enter's `keys` array** instead of as
  a `key` event (a freshly plugged keyboard with the key already down) —
  client code that only watches `key` events misses it; the demo handles
  both paths.

Esc handling itself is purely client-side: the compositor does not interpret
Esc; the client destroys the popup (allowed — client-initiated destroy is
the other half of the dismissal contract).

## A stale grab serial: silently granted, not denied

The spec threatens immediate dismissal — [xdg_popup.grab][p-xdg]:

> If the compositor denies the grab, the popup will be immediately
> dismissed.
>
> This request must be used in response to some sort of user action like a
> button press, key press, or touch down event.

The `stale` scenario grabs with `serial=1` on a connection where **no input
event has ever been delivered** (the headless seat has `capabilities=0` the
whole run). Measured outcome on sway 1.11 — neither a protocol error nor a
`popup_done`:

```text
303334 f15_wayland grab idx=popup1 serial=1 state=requested
303403 f15_wayland popup_placed idx=popup1 x=181 y=181 size=160x96
...
1806328 f15_wayland stale_grab_result configure_received=1 popup_done_received=0 connection_alive=1
```

The popup maps and stays mapped; the invalid serial is silently ignored (no
deny path is taken, wlroots simply fails to find a matching grab serial and
proceeds without one). For a framework this means a bad serial does **not**
fail loudly — the menu appears but lacks grab semantics, a class of bug that
only behavioral testing catches.

## The pointer-capability flap does not dismiss the grab

The injector holds one virtual-pointer device per scenario because the seat's
pointer capability flaps with the device (the [F10](./f10-pointer-capture.md)
/ [F12](./f12-cursors.md) lesson). The `edge` run measures the interaction
with an open grab directly: the device unplugs while the popup is still
mapped, and nothing is dismissed —

```text
6882632 f15_wayland seat_capabilities caps=0
6882658 f15_wayland pointer_dropped popup1_open=1 popup2_open=0
9035275 f15_wayland summary scenario=edge ... popup_done_events=0
```

— the grab survives the disappearance of the very capability that created
its serial. (In the `menu` run the unplug happens after both `popup_done`s,
so the same line shows `popup1_open=0`.)

## Seat-less weston: positioner math without a grab

Headless weston advertises no `wl_seat` ([scaffold finding](./scaffold.md#what-surprised-us)),
so there is no serial and `grab` is impossible — but popups are not:
`xdg_popup` without a grab is the protocol's tooltip case. The `noinput`
scenario opens the same menu + submenu + reposition probe grab-free and gets
byte-identical placement answers from weston (`popup_placed x=181 y=181`,
reposition to `(205,197)`, submenu at `(156,62)`) — positioner solving and
the grab are fully orthogonal features.

## Reproducing

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f15-popup

d=docs/research/window-system-integration/os-apis/wayland/examples/f15-popup
nix develop -c $d/run.sh weston                                  # noinput: positioner-only baseline
nix develop -c sh -c "nix shell nixpkgs#sway nixpkgs#wtype -c $d/run.sh sway"  # menu + edge + stale
```

The sway mode starts `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR`; gestures come from the demo binary's own `inject` mode
(`zwlr_virtual_pointer_v1`, [`./examples/f15-popup/inject.d`](./examples/f15-popup/inject.d)),
Esc from `wtype`. `WSI_DEMO_DEBUG=1` adds the `WAYLAND_DEBUG=1` wire trace
quoted above. Without a compositor every mode prints `SKIP:` and exits `0`.

## Sources

- **[F15 spec][f15]** — the menu/edge/nested/dismissal-cause requirements
  and the placement-ownership finding this page answers for Wayland.
- **[xdg-shell][p-xdg]** — `xdg_positioner` (anchor/gravity/
  `constraint_adjustment`/`set_reactive`/`set_offset`), `xdg_popup`
  (`grab`, `reposition`, `configure`, `popup_done`, `repositioned`), all
  passages quoted verbatim above (XML at
  `wayland-protocols/stable/xdg-shell/xdg-shell.xml`, interface version 7).
- **[F10 — pointer capture](./f10-pointer-capture.md)** /
  **[F12 — cursors](./f12-cursors.md)** — the capability-flap injection
  lessons the single-device-session injector design follows.
- Demo sources: [`app.d`](./examples/f15-popup/app.d),
  [`inject.d`](./examples/f15-popup/inject.d),
  [`instrument.d`](./examples/f15-popup/instrument.d), the `c.c` shim
  (positioner/popup quartet + `libxkbcommon` + virtual-pointer tables),
  `generate.sh` and the `run.sh` driver alongside it.

<!-- References -->

[f15]: ../features/f15-popup.md
[p-xdg]: https://wayland.app/protocols/xdg-shell
