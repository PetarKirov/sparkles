# X11 F10 — pointer capture — findings

What X11 gives a "mouselook + confine" implementation, measured per the
[F10 feature contract][f10]. The demo,
[`./examples/f10-pointer-capture/app.d`](./examples/f10-pointer-capture/app.d),
extends the [scaffold](./scaffold.md) with [XInput2][xi2proto] raw motion
(`XI_RawMotion` on the root window), a mouselook lock assembled from
[`XIGrabDevice`][xigrabdevice] + [`XFixesHideCursor`][xfixes-man] +
warp-to-center, and confine-to-region implemented **both** ways — a modal
[`XGrabPointer`][xgrabpointer] with `confine_to`, and ambient
[XFixes 5 pointer barriers][fixesproto] — so the two mechanisms can be
compared on the same region. Numbers are from Tier-A runs under `xvfb-run`
(exit 0): a built-in pass driven by `XWarpPointer` probes, and an
`examples/f10-pointer-capture/run.sh` pass driven by `xdotool` (XTest device
motion), which is the half warps cannot prove.

**Last reviewed:** June 11, 2026

## One event, both flavors: raw vs accelerated deltas

[XI2proto][xi2proto] specifies that a raw event carries the device deltas
twice:

> A RawEvent provides the information provided by the driver to the client.
> RawEvent provides both the raw data as supplied by the driver and
> transformed data as used in the server. Transformations include, but are
> not limited to, axis clipping and acceleration. Transformed valuator data
> may be equivalent to raw data. In this case, both raw and transformed
> valuator data is provided.

So unlike Wayland (where unaccelerated deltas need the separate
`zwp_relative_pointer_v1` protocol) or Win32 (`WM_INPUT` vs `WM_MOUSEMOVE`),
X11 hands both flavors to the same handler: `XIRawEvent.raw_values` (driver
units) next to `XIRawEvent.valuators.values` (post-acceleration). The demo
logs them side by side. Under Xvfb, XTest-synthesized motion is never
accelerated, so the two are equal — the honest Tier-A answer, with the
`accel_equal=0` case left for real hardware (Tier C):

```text
1425966 x11_f10 raw_motion raw_dx=17.00 raw_dy=9.00 accel_dx=17.00 accel_dy=9.00 accel_equal=1 device=2
```

Raw events are a root-window-only selection — "RawEvents are sent
exclusively to all root windows" ([XI2proto][xi2proto]) — which is why the
demo selects `XI_RawMotion` on the root and `XI_Motion` (`pointer abs`) on
its own window.

## Mouselook: lock is assembled, not atomic

X11 has no "lock the pointer" primitive. The demo assembles one from three
independent calls — grab (`XIGrabDevice` on the master pointer), hide
(`XFixesHideCursor`), pin (`XWarpPointer` to the window center after every
motion event) — and reads deltas from the raw stream. Unlock reverses all
three and **warps the cursor back to the saved position**, exactly:

```text
422139 x11_f10 lock state=on grab=XIGrabDevice status=GrabSuccess saved=461,301
844079 x11_f10 lock state=off restored=461,301 wanted=461,301 match=1
```

X11 _can_ warp — `XWarpPointer` places the cursor anywhere — whereas a
Wayland client can only _suggest_ an unlock position via
`zwp_locked_pointer_v1.set_cursor_position_hint` and the compositor decides.

Two measured properties make the recipe sound, and one breaks it subtly:

- **Warps generate no raw events.** The built-in pass issued 6 jitter warps
  and 6 re-center warps while locked and saw **zero** `XI_RawMotion`
  (`lock_stats raw_events=0 jitter_warps=6 recenter_warps=6`). The
  re-centering therefore never pollutes the raw delta stream — the classic
  warp-echo double-count of the core-protocol-only fallback (deltas from
  `MotionNotify`) simply does not exist on the raw path.
- **`accel_equal=1` deltas are usable directly** (above) — no untangling of
  pointer acceleration on this server.
- **Raw events double up while you hold the grab.** The `xdotool` pass sent
  6 relative moves during lock and the demo counted 12 raw events — every
  physical motion arrived twice, once via the grab and once via the
  root-window selection:

```text
2350653 x11_f10 pointer rel dx=23.00 dy=-11.00 raw=1 ... yaw=23.0 pitch=-11.0
2350699 x11_f10 pointer rel dx=23.00 dy=-11.00 raw=1 ... yaw=46.0 pitch=-22.0
...
4018053 x11_f10 lock_stats raw_events=12 jitter_warps=0 recenter_warps=6 yaw=276.0 pitch=-132.0
```

This is the [XI2proto][xi2proto] 2.0-vs-2.1 delivery rules compounding ("Clients
supporting XI 2.0 receive raw events … when the device is grabbed by the
client"; "Clients supporting XI 2.1 or later receive raw events at all
times, even when the device is grabbed by another client") — a client that
both grabs and listens on the root gets each event through both doors. A
framework must dedupe (e.g. by event serial/time) or its mouselook runs at
exactly 2× sensitivity while locked.

## Confine, modal flavor: `XGrabPointer` with `confine_to`

The [Xlib manual][xgrabpointer] promises a hard fence:

> If a `confine_to` window is specified, the pointer is restricted to stay
> contained in that window. … If the pointer is not initially in the
> `confine_to` window, it is warped automatically to the closest edge just
> before the grab activates.

and [`XWarpPointer`][xwarppointer] adds: "you cannot use `XWarpPointer()` to
move the pointer outside the `confine_to` window of an active pointer grab.
An attempt … will only move the pointer as far as the closest edge."

Measured under Xvfb, only the activation half of that promise holds. The
demo confines to an `InputOnly` child over the window's center half
(`rect=240x160+120+80`); at grab time the pointer (at window 440,280) was
pulled to the closest in-rect point:

```text
855553 x11_f10 confine mode=grab rect=240x160+120+80 confine_to=0x200002 status=GrabSuccess
860881 x11_f10 pointer abs x=359 y=239 root=380,260
```

— but **every subsequent reposition escaped**: `XWarpPointer` probes landed
on all four window corners (`confine_probe mode=grab target=8,8 actual=8,8
inside_rect=0`), an XTest absolute jump (`xdotool mousemove`) left the rect,
and XTest _relative_ motion walked straight through the edge
(root `261 → 201 → 141 → 81 → 21` in 60 px steps with the grab held). The
`WSI_CONFINE_IO=1` knob swaps the child for `InputOutput` — same result, so
it is not the window class. Xvfb (xorg-server 21.1) simply does not enforce
`confine_to` after activation; re-verifying on a real Xorg session is queued
as Tier C. A framework cannot treat `confine_to` as a guarantee on
virtual/headless servers.

The _modal_ part, by contrast, behaves exactly as specified: while the demo
holds the grab, a second client (the demo's second `Display` connection) is
locked out of both grab APIs:

```text
844616 x11_f10 grab_probe client=second XGrabPointer=AlreadyGrabbed XIGrabDevice=AlreadyGrabbed
```

and all pointer events are funneled to the grabbing client even with the
pointer outside its window — the demo keeps receiving `pointer abs` for
positions like `8,8` that would otherwise go to whatever is under the
cursor. One pointer, one owner: that is what "modal" costs the rest of the
session.

## Confine, ambient flavor: XFixes pointer barriers

[Pointer barriers][fixesproto] (XFixes 5) are screen-space line segments the
pointer cannot cross by relative motion; the demo builds four around the
same center rect, each transparent inward only ("Motion is allowed through
the barrier in the directions specified: setting the `BarrierPositiveX` bit
allows travel through the barrier in the positive X direction") and selects
the XI 2.3 `XI_BarrierHit`/`XI_BarrierLeave` events on the root. `xdotool`
relative sweeps then clamp pixel-exactly at the rect edges — left edge at
root x=141, right at 381, bottom at 261 — with each blocked step reported,
including how far the pointer _tried_ to go:

```text
6311598 x11_f10 barrier_hit barrier=2097155 root=141,181 blocked_dx=-80.0 blocked_dy=0.0
6933349 x11_f10 barrier_hit barrier=2097156 root=380,181 blocked_dx=80.0 blocked_dy=0.0
7307046 x11_f10 barrier_hit barrier=2097158 root=380,260 blocked_dx=0.0 blocked_dy=60.0
```

What barriers deliberately do **not** stop is spelled out in
[the spec][fixesproto] and confirmed by the logs:

> WarpPointer and similar requests do not obey pointer barriers. …
> Absolute positioning devices like touchscreens do not obey pointer
> barriers.

The built-in pass warped to all four corners with barriers up
(`confine_probe mode=barrier target=8,8 actual=8,8 inside_rect=0`), and an
absolute `xdotool mousemove` (XTest absolute positioning) jumped out
equally freely; only _relative_ device motion is clamped.

## Modal vs ambient — the comparison

The two mechanisms answer different questions, and the demo's
`barrier_plus_grab` phase shows they compose: with barriers up, the demo took
an ordinary `XGrabPointer` (`confine_to=None`) and relative sweeps **still**
clamped at the barrier edges (`barrier_hit … root=141,140` while
`barriers_active=1`) — barriers keep working under anyone's grab.

| Property                | `XGrabPointer confine_to` (modal)                                   | XFixes barriers (ambient)                                  |
| ----------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------- |
| Scope                   | whole pointer, one client owns all input while held                 | a screen-space line; event routing untouched               |
| Concurrency             | exclusive — second client gets `AlreadyGrabbed` (measured)          | any number of barriers from any number of clients          |
| Clamps relative motion  | promised; **not enforced post-activation under Xvfb** (measured)    | yes, pixel-exact (measured)                                |
| Clamps warps / absolute | promised for warps ([`XWarpPointer`][xwarppointer]); not under Xvfb | no, by design ([spec][fixesproto])                         |
| Feedback                | none (silence)                                                      | `XI_BarrierHit`/`Leave` with blocked `dx`/`dy` (XI ≥ 2.3)  |
| Lifetime                | until ungrab/close; pointer freed if client dies                    | until `XFixesDestroyPointerBarrier`; survives across grabs |
| Under someone's grab    | is the grab                                                         | still clamps (measured, `barrier_plus_grab`)               |

For a framework: barriers are the composable confine primitive (and what
desktop shells use for edge resistance); the grab is what you take when you
_also_ need exclusive input — i.e. mouselook — and its `confine_to` rider
should be treated as best-effort.

## Surprises

- **`XWarpPointer` is invisible to the raw stream.** No `XI_RawMotion` for
  any of the 12 warps in the locked phase — warp-to-center mouselook on the
  raw path needs no echo filtering (it does on the `MotionNotify` path,
  where the demo skips events already at center).
- **Raw events arrive twice while you hold a grab** (grab delivery + root
  selection): 6 physical moves → 12 `pointer rel` lines → `yaw=276` instead
  of 138. Dedupe or double-sensitivity.
- **`confine_to` enforcement stops at activation under Xvfb** — warps, XTest
  absolute _and_ XTest relative motion all escaped, with both `InputOnly`
  and `InputOutput` confine windows, despite the Xlib manual's "restricted
  to stay contained". Pointer barriers on the same rect clamped every
  relative step on the same server.
- **A grab does not suspend barriers** — `barrier_hit` keeps firing during
  an active `XGrabPointer`; modal and ambient confinement compose.
- **`XISelectEvents` on the root is the only way to raw events**, and
  `XI_BarrierHit` needs `XIQueryVersion` to have announced ≥ 2.3 — version
  negotiation changes which events exist.
- **ImportC gaps, again all macros**: the entire `<X11/extensions/XI2.h>`
  (event ids, `XIAllMasterDevices`, flags) and the XFixes barrier directions
  are `#define`s; `XISetMask` is a macro re-implemented as a D function —
  same discipline as the [scaffold](./scaffold.md).

## Build and run

| File                                        | Lines | Role                                            |
| ------------------------------------------- | ----- | ----------------------------------------------- |
| `examples/f10-pointer-capture/app.d`        | 589   | the demo                                        |
| `examples/f10-pointer-capture/instrument.d` | 50    | shared logger (copied from the scaffold)        |
| `examples/f10-pointer-capture/c.c`          | 16    | ImportC shim (Xlib + XInput2 + Xfixes + poll)   |
| `examples/f10-pointer-capture/run.sh`       | 87    | two-pass driver (built-in, then xdotool sweeps) |

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f10-pointer-capture
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f10-pointer-capture
```

The full choreography (both passes) is
`examples/f10-pointer-capture/run.sh` (run from the dev shell; it pulls
`xdotool` via `nix shell`). Knobs: `WSI_AUTO_EXIT=1` scripts the five phases
(unlocked → locked → confine_grab → confine_barrier → barrier_plus_grab);
`WSI_DRIVEN=1` stretches phases to 2 s and suppresses self-warps so xdotool
owns the pointer; `WSI_CONFINE_IO=1` makes the confine child `InputOutput`.
Interactive keys: `l` lock, `c` confine-grab, `b` barriers, `q` quit. No
reachable display or no `XInputExtension` prints `SKIP:` and exits 0.

## Sources

- **[X Input Extension 2.x protocol spec][xi2proto]** — raw event
  raw-vs-transformed payload, root-window-only delivery, the 2.0/2.1 grab
  delivery rules, `XI_BarrierHit`/`Leave` (all quotes above).
- **[XFixes protocol spec][fixesproto]** — pointer barriers: direction
  semantics, the warp and absolute-device exemptions, `CreatePointerBarrier`
  device targeting.
- **Xlib manual (Tronche mirror)** — [`XGrabPointer`][xgrabpointer]
  (`confine_to` semantics, `AlreadyGrabbed`), [`XWarpPointer`][xwarppointer]
  (the confine clamp promise), [`XSelectInput`][xselectinput].
- **[`XIGrabDevice` man page][xigrabdevice]**, **[`Xfixes` man page][xfixes-man]**
  (`XFixesHideCursor`/`ShowCursor`, version requirements).
- **[`xdotool`][xdotool]** — the XTest driver for the device-motion pass.
- **This survey** — the [X11 deep-dive](./index.md), the
  [scaffold findings](./scaffold.md) (binding style, ImportC gotchas), the
  [F10 feature contract][f10], and the runnable sources
  [`./examples/f10-pointer-capture/app.d`](./examples/f10-pointer-capture/app.d)
  (+ `c.c`, `instrument.d`, `run.sh` alongside it).

<!-- References -->

[f10]: ../features/f10-pointer-capture.md
[xi2proto]: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/specs/XI2proto.txt
[fixesproto]: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/fixesproto.txt
[xigrabdevice]: https://www.x.org/releases/current/doc/man/man3/XIGrabDevice.3.xhtml
[xgrabpointer]: https://tronche.com/gui/x/xlib/input/XGrabPointer.html
[xwarppointer]: https://tronche.com/gui/x/xlib/input/XWarpPointer.html
[xselectinput]: https://tronche.com/gui/x/xlib/event-handling/XSelectInput.html
[xfixes-man]: https://www.x.org/releases/current/doc/man/man3/Xfixes.3.xhtml
[xdotool]: https://github.com/jordansissel/xdotool
