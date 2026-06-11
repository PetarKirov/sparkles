# Wayland F10 — Pointer: relative motion, lock & confine

Mouselook on Wayland is assembled from two unstable protocols: a constraint
([`zwp_pointer_constraints_v1`][p-constraints] — `lock_pointer` pins the
cursor, `confine_pointer` cages it in a `wl_region`) and a delta stream
([`zwp_relative_pointer_v1`][p-relative] — `dx/dy` plus unaccelerated
twins, flowing whether or not a lock is active). The demo,
[`./examples/f10-pointer-capture/app.d`](./examples/f10-pointer-capture/app.d),
extends the [scaffold](./scaffold.md) to the [F10 spec][f10] as a
choreographed phase machine — `pre → lock-oneshot → relock-oneshot →
lock-persistent → confine` — that exercises **both constraint lifetimes**,
the `set_cursor_position_hint` unlock warp, and boundary clamping at a
confine region edge, all Tier A under headless sway 1.11 (`./run.sh sway`,
exit `0`). Headless weston 15 is the SKIP path: it _offers_ both globals but
has **no seat**, so the run is a registry probe only. Input is injected by
the demo binary's own `inject` mode (a hand-marshalled
[`zwlr_virtual_pointer_v1`][p-vptr] client, [`inject.d`](./examples/f10-pointer-capture/inject.d))
— `wlrctl` turned out to be structurally unable to drive this demo (below).

**Last reviewed:** June 11, 2026

| Capability                        | weston 15.0 headless | sway 1.11 headless        |
| --------------------------------- | -------------------- | ------------------------- |
| `zwp_pointer_constraints_v1`      | offered (v1)         | offered (v1)              |
| `zwp_relative_pointer_manager_v1` | offered (v1)         | offered (v1)              |
| `wl_seat`                         | **none at all**      | yes (caps follow devices) |
| Exercisable                       | registry probe only  | full phase machine        |

## The async-failable contract: `locked` waits for entry

[`lock_pointer`][p-constraints] "may not take effect immediately … the
protocol provides no guarantee that the constraints are ever satisfied" — a
framework lock API must therefore be async-failable. The demo proves the
async half: the window **floats** at (320,120) sized 640×480 (sway config in
the `run.sh` driver next to the demo) so the cursor can genuinely be outside
it; every lock is requested immediately after the `wl_pointer` is created on
a capability gain, before any `enter`. The
`WAYLAND_DEBUG=1` wire trace of the first oneshot lock (lifetime arg `1`):

```text
[1263091.015] {Default Queue} wl_seat#9.capabilities(1)
[1263091.052] {Default Queue}  -> wl_seat#9.get_pointer(new id wl_pointer#16)
[1263091.058] {Default Queue}  -> zwp_relative_pointer_manager_v1#7.get_relative_pointer(new id zwp_relative_pointer_v1#17, wl_pointer#16)
[1263091.070] {Default Queue}  -> zwp_pointer_constraints_v1#8.lock_pointer(new id zwp_locked_pointer_v1#18, wl_surface#3, wl_pointer#16, nil, 1)
2949337 f10_wayland lock_request lifetime=oneshot object=1 focus=0 note=first-oneshot
[1263091.143] {Default Queue} wl_pointer#16.enter(34, wl_surface#3, 320.00000000, 240.00000000)
[1263091.177] {Default Queue} zwp_locked_pointer_v1#18.locked()
2949429 f10_wayland locked phase=lock-oneshot object=1 activation=1
```

`run.sh` had warped the cursor to global (100,100) — outside the window —
and the injector then streamed (60,45) deltas; `locked` fired only once the
path crossed the window edge, honouring the spec's "whenever the lock is
activated, it is guaranteed that the locked surface will already have
received pointer focus". (On re-locks the order flips — `locked` arrives
_before_ the `enter` in the same batch — so a client must not assume either
ordering.)

## Both lifetimes, both lifecycles

The [`lifetime` enum][p-constraints] is the heart of F10's API question.
Observed end-to-end (instrument log, one run):

```text
2949337 f10_wayland lock_request lifetime=oneshot object=1 focus=0 note=first-oneshot
2949429 f10_wayland locked phase=lock-oneshot object=1 activation=1
4213431 f10_wayland unlocked phase=lock-oneshot object=1 activations=1
4213483 f10_wayland lock_destroyed reason=oneshot-defunct
4619202 f10_wayland lock_request lifetime=oneshot object=2 focus=0 note=new-object-after-oneshot
4829410 f10_wayland locked phase=relock-oneshot object=2 activation=1
5883683 f10_wayland unlocked phase=relock-oneshot object=2 activations=1
6289534 f10_wayland lock_request lifetime=persistent object=3 focus=0 note=persistent
6499159 f10_wayland locked phase=lock-persistent object=3 activation=1
7553375 f10_wayland unlocked phase=lock-persistent object=3 activations=1
7553435 f10_wayland lock_kept note=persistent-object-retained-for-reactivation
8168852 f10_wayland locked phase=lock-persistent object=3 activation=2
```

- **oneshot**: after `unlocked` "this object is now defunct and should be
  destroyed" — re-locking takes a brand-new `lock_pointer` request (objects
  1 → 2 above).
- **persistent**: the same object 3 fires `locked` twice with no new request
  — the constraint "may again reactivate".

The hard-won part is what triggers `unlocked` at all: **sway deactivates a
constraint only on a window-focus change** — not on pointer-focus loss, not
on device unplug. In an earlier iteration of this demo a oneshot lock
stayed silently attached across four device plug/unplug cycles, eating every
warp and motion. `run.sh` therefore runs a second, passive instance of the
demo (`WSI_PASSIVE=1`, app id `wsi-f10-passive`, a plain window) purely as a
focus target and calls `swaymsg '[app_id=wsi-f10-passive] focus'` whenever a
phase needs its deactivation. Corollary: the constraint is keyed to
(surface, seat), not to the `wl_pointer` object — it survives the
destroy/re-create dance the capability flap forces on `wl_pointer`
(the [F12 lesson](./f12-cursors.md)) and even reactivates against a
_different_ `wl_pointer` than the one passed to `lock_pointer`.

## `wl_pointer.motion` stops; relative motion does not

The spec: "while a pointer is locked, the wl_pointer objects of the
corresponding seat will not emit any wl_pointer.motion events, but relative
motion events will still be emitted via wp_relative_pointer objects".
Measured: across all runs the demo counted `abs_while_locked=0` (any
`wl_pointer.motion` during an active lock logs a `CONTRACT-VIOLATION` line —
none ever fired) while the relative stream carried the mouselook:

```text
3019682 f10_wayland relative_motion dx=60.00 dy=45.00 dx_unaccel=60.00 dy_unaccel=45.00 locked=1 yaw=18.0 pitch=13.2
3089719 f10_wayland relative_motion dx=60.00 dy=45.00 dx_unaccel=60.00 dy_unaccel=45.00 locked=1 yaw=33.0 pitch=24.5
```

`dx`/`dy` and `dx_unaccel`/`dy_unaccel` were **identical for every event**
(`summary … unaccel_differed=0`): virtual-pointer input bypasses libinput's
acceleration, so the injected deltas are 1:1. That is honest Tier-A
instrumentation, not a finding about real mice — the [protocol][p-relative]
itself warns "non-accelerated deltas and accelerated deltas may have the
same value on some devices"; observing them _differ_ needs real hardware
(Tier C). Note also that relative motion flows while **unlocked** too
(`locked=0` lines above and in the pre phase) — a relative pointer is an
always-on second stream, not a lock-mode side effect.

## `set_cursor_position_hint`: sway does warp

On the persistent lock's second activation the demo sets a hint, commits
(the hint is double-buffered state), and destroys the lock — the
client-initiated unlock:

```text
[1268309.725] {Default Queue} zwp_locked_pointer_v1#20.locked()
[1268309.754] {Default Queue}  -> zwp_locked_pointer_v1#20.set_cursor_position_hint(400.00000000, 300.00000000)
[1268309.760] {Default Queue}  -> wl_surface#3.commit()
[1268309.789] {Default Queue}  -> zwp_locked_pointer_v1#20.destroy()
```

The cursor had been pinned at the lock position, far from (400,300). The
very next motion event answers the F10 restoration question:

```text
8238051 f10_wayland hint_verify hint=400,300 first_motion=460.00,345.00 note=expect-hint-plus-one-delta
```

460,345 = hint (400,300) + exactly one injected (60,45) delta — **sway 1.11
warps the cursor to the hint on unlock**, and per the spec that warp itself
"will not result in any relative motion events" (the relative stream showed
only the injected deltas). The hint is surface-local and double-buffered: a
client that forgets the `wl_surface.commit` gets no warp.

## Confine: clamping at the region edge

The confine phase cages the pointer in the center-half `wl_region`
(surface-local 160,120 320×240), built and destroyed around the request:

```text
[1268309.836] {Default Queue}  -> wl_compositor#5.create_region(new id wl_region#22)
[1268309.843] {Default Queue}  -> wl_region#22.add(160, 120, 320, 240)
[1268309.849] {Default Queue}  -> zwp_pointer_constraints_v1#8.confine_pointer(new id zwp_confined_pointer_v1#23, wl_surface#3, wl_pointer#17, wl_region#22, 2)
[1268309.861] {Default Queue}  -> wl_region#22.destroy()
[1268309.998] {Default Queue} zwp_confined_pointer_v1#23.confined()
```

`run.sh` then pushes the pointer at the boundary with (80,0) and (0,80)
bursts; the motion stream clamps exactly at the region edge and then goes
**silent** — a pinned cursor produces no `wl_pointer.motion` at all, only
relative motion keeps reporting the attempted deltas:

```text
8238999 f10_wayland motion x=460.00 y=345.00 phase=confine confined=1
8308994 f10_wayland motion x=479.00 y=359.00 phase=confine confined=1
9763853 f10_wayland pointer_enter serial=116 pos=479.00,359.00 phase=confine
…
24002920 f10_wayland confine_summary rect=160,120 320x240 min=0.00,170.00 max=479.00,359.00
```

The persistent confinement also deactivates/reactivates on focus, like the
lock: stealing focus produced `unconfined` (object retained), and
re-entering the window re-fired `confined` — with sway warping the pointer
back **into** the region on reactivation (the `enter` landed at the region's
interior, and one stray pre-warp motion leaked at the window-crossing point
`x=0.00 y=170.00`, the `min` in the summary above). A framework should treat
confine activation as "the compositor may move your cursor".

## Getting input at all: why the demo ships its own injector

The [F12 capability dance](./f12-cursors.md) (seat starts `capabilities=0`;
premature `get_pointer` is fatal on wlroots; destroy/re-create `wl_pointer`
on every capabilities edge) is necessary but not sufficient here:

- **`wlrctl pointer move` is one motion per device lifetime**, and that one
  motion is consumed establishing pointer focus — the client sees an `enter`
  at the moved-to position and _zero_ motion events. No motion stream, no
  relative motion, no way to cross into a constraint region. (Measured: a
  full wlrctl-driven run logged `abs_motions=0 rel_events=0`.)
- The demo's `inject` mode ([`inject.d`](./examples/f10-pointer-capture/inject.d))
  creates one [`zwlr_virtual_pointer_v1`][p-vptr] device, streams N motions
  at a fixed interval, holds the device, then unplugs — one plug/unplug
  cycle with a real motion stream inside. wlr-protocols is not in
  `wayland-protocols`, so the shim hand-writes the two `wl_interface` tables
  (9 requests, opcode order from `wlr-virtual-pointer-unstable-v1.xml`) and
  marshals with `wl_proxy_marshal_flags` — the minimal-example trick, scaled
  to exactly three requests.
- One D-side trap worth recording: druntime packs `main(string[] args)`
  into one contiguous buffer **without NUL terminators between arguments**,
  so `atoi(args[i].ptr)` silently parses the neighbouring arguments too
  (`"2" "6" "4" "50"` became 26450 injector steps). Parse the slice, not
  the pointer.

## Findings

- **Capability matrix**: lock, confine and relative motion are three
  separate objects from two globals; both globals are offered by weston 15
  and sway 1.11 (v1 each). Lock+hide is atomic (a locked pointer's cursor is
  the compositor's business); lock+relative is _assembled_ — a client
  wanting mouselook needs both objects and they are not lifecycle-coupled.
- **Async-failable confirmed**: `locked` is granted on surface entry, never
  synchronously; nothing guarantees it ever fires ("it is thus possible to
  request a lock that will never activate"). A framework lock API must be a
  request + event pair, not a boolean call.
- **Lifetimes**: oneshot = single activation, object defunct after
  `unlocked`, re-lock requires a new object; persistent = same object
  reactivates on re-entry. Both captured on the wire above.
- **Deactivation is compositor policy**: sway 1.11 deactivates only on
  window-focus change — not on pointer leave, not on device removal. A
  toolkit cannot assume `unlocked` arrives when input vanishes; the lock can
  outlive the pointer object it was created with.
- **Restoration**: `set_cursor_position_hint` + commit + destroy warps the
  cursor to the hint on sway (verified to the pixel); the warp emits no
  relative motion. Without a hint the cursor stays where it was locked.
- **Confine clamping**: motion clamps to the region edge and then stops
  entirely (no events while pinned); reactivation may warp the cursor into
  the region. `wl_pointer.motion` silence is thus ambiguous between "user
  stopped" and "user is grinding the boundary" — relative motion
  disambiguates.
- **Accel state** ([F10 §3][f10]): virtual input is 1:1
  (`dx == dx_unaccel` throughout); accelerated-vs-raw divergence needs real
  hardware and stays on the Tier-C queue together with lock-mode cursor
  visibility (F12's deferred interaction).

## Build and run

```bash
d=docs/research/window-system-integration/os-apis/wayland/examples/f10-pointer-capture
nix develop -c dub build --compiler=ldc2 --root=$d
nix develop -c $d/run.sh weston                                  # registry probe (no seat)
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway"  # full phase machine
```

The sway mode starts `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR` (the weston socket is `wsi-w6a` to keep parallel runs
apart), runs the passive focus-target instance, and drives the phases with
`swaymsg seat seat0 cursor set` warps + `inject` bursts + focus steals while
the demo runs (`WSI_AUTO_EXIT=1 WSI_RUN_MS=24000`). Without a compositor the
demo prints `SKIP:` and exits `0`; `WSI_DEMO_DEBUG=1 ./run.sh sway` re-runs
with `WAYLAND_DEBUG=1` on the demo for the wire traces quoted above.

## Sources

- **[F10 spec][f10]** — requirements 1–3 (mouselook with raw deltas,
  confine-to-region, accel state) and the findings list this doc answers
  (deniable locks, restoration semantics, capability matrix).
- **[`pointer-constraints-unstable-v1`][p-constraints]** — `lock_pointer` /
  `confine_pointer`, the `lifetime` enum, `set_cursor_position_hint` and the
  `locked`/`unlocked`/`confined`/`unconfined` events; all spec quotes above
  are from the protocol XML (`wayland-protocols` 1.47,
  `unstable/pointer-constraints/pointer-constraints-unstable-v1.xml`).
- **[`relative-pointer-unstable-v1`][p-relative]** — `relative_motion`'s
  accelerated + unaccelerated payload and the "may have the same value on
  some devices" caveat (same tree, `unstable/relative-pointer/`).
- **[`wlr-virtual-pointer-unstable-v1`][p-vptr]** — the injector's device
  (hand-written interface tables in
  [`c.c`](./examples/f10-pointer-capture/c.c)).
- **[Core protocol][p-wayland]** — `wl_seat.capabilities` lifecycle and
  `wl_region`.
- Demo sources: [`app.d`](./examples/f10-pointer-capture/app.d),
  [`inject.d`](./examples/f10-pointer-capture/inject.d),
  [`instrument.d`](./examples/f10-pointer-capture/instrument.d), the `c.c`
  shim, `generate.sh` (xdg-shell + the two constraint protocols) and the
  `run.sh` driver alongside it; the seat lessons inherited from
  [F12](./f12-cursors.md) and the window plumbing from
  [the scaffold](./scaffold.md).

<!-- References -->

[f10]: ../features/f10-pointer-capture.md
[p-constraints]: https://wayland.app/protocols/pointer-constraints-unstable-v1
[p-relative]: https://wayland.app/protocols/relative-pointer-unstable-v1
[p-vptr]: https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1
[p-wayland]: https://wayland.app/protocols/wayland
