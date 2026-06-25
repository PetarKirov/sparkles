# Wayland F01 — first pixel & init cost

Findings from [`./examples/f01-first-pixel/app.d`](./examples/f01-first-pixel/app.d), the
[F01 spec][f01]'s Wayland demo. It formalizes the measurement the
[scaffold](./scaffold.md) made possible: one `step name=…` instrumentation event per init
API call (round-trips marked `rt=1`), a `concept n=… name=…` event at the first touch of
each protocol object type, a compile-time-computed LOC figure, and a `summary` line +
stdout checklist. The demo presents exactly one confirmed frame, holds 10 more frame
callbacks to prove the loop is live, and exits `0`. Verified Tier A: `weston
--backend=headless` (weston 15.0, libwayland 1.24), exit `0`.

**Last reviewed:** June 10, 2026

| Measurement                            | Value                                                                                                                             |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Concepts to first pixel                | **11** protocol object types (see [the scaffold's first-touch list](./scaffold.md#concepts-to-pixel))                             |
| LOC                                    | **558** total / **413** code (computed at compile time from `import("app.d")`; `instrument.d` + `c.c` excluded per [F01 §5][f01]) |
| Init steps logged                      | **21** `step` events from `init_start` to `first_pixel_presented`                                                                 |
| Round-trips (`rt=1`)                   | **2**: `wl_display_roundtrip` (registry) + the `wl_display_dispatch` that waits for the first configure                           |
| `init_start` → `first_commit`          | ≈ 2.2 ms, of which ≈ 1.3 ms is painting the first 640×480 gradient                                                                |
| `init_start` → `first_pixel_presented` | **11.1–18.6 ms** across 7 runs — dominated by waiting for the compositor's next 60 Hz frame tick                                  |

## What the spec asked, and what Wayland can actually confirm

[F01][f01] requires a demo to log every init step, count round-trips, and stop the clock
at a _confirmed_ first pixel. On Wayland the confirmation is well-defined — better than
on X11, which has nothing comparable without the Present extension: the contract is the
first `done` event on a [`wl_surface.frame`][p-frame] callback that was requested
alongside the first buffer commit after [`xdg_surface.ack_configure`][p-ack]. Per the
core protocol, the callback fires "when it is a good time to start drawing a new frame"
— i.e. the committed frame has been taken up by the compositor's repaint cycle. There is
no per-pixel scanout proof (that would be the separate `wp_presentation` protocol, out of
scope here), but it is an explicit, ordered, server-driven signal that the commit was
consumed.

## The init step sequence

The full instrument stream of a Tier-A run (microseconds since `init_start`; format per
[F01 § Instrumentation][f01]). `concept` lines interleave at first touch; `rt=1` marks
the two compositor waits:

```text
0     f01-wayland init_start
45    f01-wayland concept n=1 name=wl_display
68    f01-wayland step name=wl_display_connect
94    f01-wayland concept n=2 name=wl_registry
110   f01-wayland step name=wl_display_get_registry
125   f01-wayland concept n=3 name=wl_callback
204   f01-wayland concept n=4 name=wl_compositor
220   f01-wayland step name=wl_registry_bind iface=wl_compositor version=5
307   f01-wayland concept n=5 name=wl_shm
323   f01-wayland step name=wl_registry_bind iface=wl_shm version=2
369   f01-wayland concept n=6 name=xdg_wm_base
385   f01-wayland step name=wl_registry_bind iface=xdg_wm_base version=5
410   f01-wayland step name=wl_display_roundtrip rt=1
430   f01-wayland concept n=7 name=wl_surface
446   f01-wayland step name=wl_compositor_create_surface
467   f01-wayland concept n=8 name=xdg_surface
482   f01-wayland step name=xdg_wm_base_get_xdg_surface
503   f01-wayland concept n=9 name=xdg_toplevel
518   f01-wayland step name=xdg_surface_get_toplevel
538   f01-wayland step name=xdg_toplevel_set_title
559   f01-wayland step name=xdg_toplevel_set_app_id
575   f01-wayland window_created
587   f01-wayland step name=wl_surface_commit(no-buffer)
655   f01-wayland xdg_toplevel_configure size=0x0
676   f01-wayland configure serial=20 size=640x480
696   f01-wayland step name=xdg_surface_ack_configure
711   f01-wayland first_configure
732   f01-wayland step name=memfd_create+mmap
754   f01-wayland concept n=10 name=wl_shm_pool
787   f01-wayland step name=wl_shm_create_pool
808   f01-wayland concept n=11 name=wl_buffer
827   f01-wayland step name=wl_shm_pool_create_buffer
848   f01-wayland buffer_alloc size=640x480 bytes=1228800
2170  f01-wayland step name=wl_surface_attach
2192  f01-wayland step name=wl_surface_damage_buffer
2213  f01-wayland step name=wl_surface_frame
2234  f01-wayland step name=wl_surface_commit(buffer)
2249  f01-wayland first_commit size=640x480
2265  f01-wayland step name=wl_display_dispatch(first_configure) rt=1
18535 f01-wayland frame_callback t=477151625
18561 f01-wayland first_pixel_presented
18573 f01-wayland summary concepts=11 loc=558 loc_code=413 steps=21 roundtrips=2 first_pixel_us=18561
```

…and the stdout checklist the demo prints after clean teardown:

```text
F01 checklist (wayland):
  [x] one frame presented, confirmed by wl_surface.frame callback
  [x] init steps logged: 21 (round-trips rt=1: 2)
  [x] concepts to first pixel: 11
  [x] loc: 558 total, 413 code (instrument.d and c.c excluded)
  [x] init_start -> first_pixel_presented: 18561 us
  [x] held 10 extra frames, clean teardown, exit 0
ok: presented 11 frames in 11 commits, final size 640x480
```

### Reading the deltas

- **Connect → `window_created` is ~0.6 ms total.** Every request in that span is a local
  buffered write; only `wl_display_roundtrip` actually waits (~300 µs on a local socket,
  including dispatching the registry's global burst — the `wl_registry_bind` steps at
  204–385 all run _inside_ it).
- **The configure answer to the no-buffer commit costs ~90 µs** (`wl_surface_commit` at
  587 → `configure serial=20` at 676). It is the second and last blocking wait before
  pixels.
- **Painting dominates client-side init**: `buffer_alloc` at 848 → `wl_surface_attach`
  at 2170 is ~1.3 ms of filling 307 200 gradient pixels — protocol work up to that point
  is ~0.9 ms in total.
- **The frame clock dominates everything.** `first_commit` at 2.25 ms;
  `first_pixel_presented` at 18.6 ms. The remaining ~16 ms is purely waiting for
  headless weston's next 60 Hz repaint tick. Across 7 runs the total ranged 11 149 µs to
  18 561 µs while the pre-commit portion stayed ≈ 2.2 ms — the variance is exactly the
  phase of the compositor's frame clock at connect time, nothing the client does.

## Round-trips: 2, by construction

The demo marks `rt=1` on the only two places it blocks on the compositor:

1. [`wl_display_roundtrip`][p-sync] after `wl_registry` creation — global discovery
   needs the server's answer (and internally costs the demo its first `wl_callback`,
   via `wl_display.sync`).
2. The `wl_display_dispatch` loop that waits for the first
   [`xdg_surface.configure`][p-configure] after the mandatory no-buffer commit — the
   [no-buffer-no-window][nbnw] handshake makes mapping a window inherently one
   round-trip: the client may not attach a buffer until the compositor has spoken.

Everything else — surface/role creation, title, buffer creation, attach/damage/commit —
is fire-and-forget on the client's send buffer. A Wayland window costs **two** waits,
then one frame-clock tick.

## Concepts and LOC

The 11 first-touch protocol object types match the
[scaffold's enumeration](./scaffold.md#concepts-to-pixel) exactly (`wl_display`,
`wl_registry`, `wl_callback`, `wl_compositor`, `wl_shm`, `xdg_wm_base`, `wl_surface`,
`xdg_surface`, `xdg_toplevel`, `wl_shm_pool`, `wl_buffer`) — F01 re-derives the count
mechanically (`concept n=…` events frozen at `first_pixel_presented`) instead of by
inspection. Headless weston advertises no `wl_seat`, so the seat-binding code is
unexercised and the Tier-A count stays 11. The two non-protocol OS objects
(`memfd_create(2)` fd, `mmap(2)` mapping) ride along as before.

LOC is **self-measuring**: the demo string-imports its own source
(`enum demoLoc = countLoc(import("app.d"))`, enabled by `stringImportPaths "."` in the
demo's `dub.sdl`) and CTFE-counts total and
non-blank-non-comment lines, so the number in the `summary` line can never drift from
the code. 558/413 is noticeably above the scaffold's 463/346 — the F01 instrumentation
(concept tracking, step counters, the checklist) costs ~70 code lines on top of the
windowing itself.

## What surprised us

- **"First pixel" is a frame-clock lottery.** The honest number is not a constant: the
  11–19 ms spread is the compositor's vsync phase, and _no_ init optimization can move
  it. The actionable metric for a library is the ≈ 2.2 ms of client-side work (≈ 0.9 ms
  excluding the gradient paint), not the wall-clock-to-photon figure.
- **The configure serial was 20 on a freshly mapped window.** Weston's configure serial
  counter is per-compositor, not per-surface — earlier demo runs against the same weston
  instance had consumed serials 1–19. A client must treat the serial as an opaque token
  to echo back, never as a sequence number to interpret (see
  [F02's serial logging](./f02-resize.md)).
- **Headless weston keeps a strict 60 Hz frame clock with no display attached** — the
  hold-phase `frame_callback` events tick at 16.6–16.7 ms intervals exactly. "Presented"
  on a headless backend therefore means "consumed by a repaint that renders to nothing":
  the confirmation semantics are identical to a real output; only the photons are
  missing.

## Open questions

- `wp_presentation` (presentation-time protocol) would upgrade "the compositor consumed
  the commit" to "the frame hit scanout at time T". Worth adding when F04 (frame pacing)
  lands; headless weston advertises it, so it stays Tier A.
- The first-touch order of `wl_callback` is an artifact of using
  `wl_display_roundtrip`; a client driving `wl_display.sync` manually or polling the fd
  (F05 territory) could map a window with 10 concepts. Is the bootstrap round-trip ever
  avoidable in practice (registry events race with binds)? `wl_display.sync` semantics
  say no — discovery requires one server echo.

## Sources

- **Protocol** — the [core Wayland protocol][p-wayland] ([`wl_surface.frame`][p-frame],
  [`wl_display.sync`][p-sync]) and [`xdg-shell`][p-xdgshell]
  ([`xdg_surface.configure`][p-configure], [`ack_configure`][p-ack]); glue generated
  from `wayland-protocols` 1.47 (`stable/xdg-shell/xdg-shell.xml`).
- **Spec implemented** — [F01 first pixel][f01]; conventions in
  [the features index](../features/index.md).
- **Baseline** — [the scaffold findings](./scaffold.md) (concept list, build gotchas);
  cross-platform grid in [the feature matrix](../feature-matrix.md).
- **Code** — [`./examples/f01-first-pixel/app.d`](./examples/f01-first-pixel/app.d),
  [`./examples/f01-first-pixel/instrument.d`](./examples/f01-first-pixel/instrument.d),
  [`./examples/f01-first-pixel/c.c`](./examples/f01-first-pixel/c.c).

<!-- References -->

[f01]: ../features/f01-first-pixel.md
[nbnw]: ../../concepts.md#no-buffer-no-window
[p-wayland]: https://wayland.app/protocols/wayland
[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[p-frame]: https://wayland.app/protocols/wayland#wl_surface:request:frame
[p-sync]: https://wayland.app/protocols/wayland#wl_display:request:sync
[p-configure]: https://wayland.app/protocols/xdg-shell#xdg_surface:event:configure
[p-ack]: https://wayland.app/protocols/xdg-shell#xdg_surface:request:ack_configure
