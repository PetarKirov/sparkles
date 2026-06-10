# Wayland F12 — Cursors

Who owns the mouse cursor on Wayland, and what does it cost the client? The
demo, [`./examples/f12-cursors/app.d`](./examples/f12-cursors/app.d), extends
the [scaffold](./scaffold.md) to the [F12 spec][f12] with **both** cursor
mechanisms in one binary, runtime-selected by the advertised globals:
[`wp_cursor_shape_device_v1.set_shape`][p-shape] (the compositor owns the
pixels; the client sends one enum) and classic
[`wl_pointer.set_cursor`][p-wayland] with a `wl_surface` the client renders
itself from the Xcursor theme via `libwayland-cursor`. A 3×3 hover-zone grid
maps the 8 border zones to the 8 resize-edge cursors; re-entering the center
cycles default → text → pointer → **bullseye** (the custom 24×24 ARGB pixmap,
hotspot 12,12) → wait. Every change logs `cursor_set name=… path=…`. Verified
Tier A under headless weston 15 (registry + theme probe — no seat, see below)
and headless sway 1.11, where `swaymsg seat seat0 cursor set` warps the
pointer across the zones and a `wlrctl` virtual pointer supplies the seat
capability; all runs exit `0`. The driver script `run.sh` next to the demo
reproduces all three choreographies (`weston`, `sway`, `sway-theme`).

**Last reviewed:** June 11, 2026

## Is `cursor-shape-v1` offered? The per-compositor answer

The demo logs `cursor_shape_v1 offered=… version=…` from the registry before
anything else runs, and selects the path (`WSI_FORCE_PATH=shape|theme`
overrides for A/B runs):

| Capability                   | weston 15.0 headless | sway 1.11 headless                 |
| ---------------------------- | -------------------- | ---------------------------------- |
| `wp_cursor_shape_manager_v1` | **no**               | yes (v1)                           |
| `wl_seat`                    | **none at all**      | yes (capabilities follow devices)  |
| `wl_pointer` obtainable      | no                   | only after a pointer device exists |
| Path the demo selects        | `theme` (probe only) | `shape`                            |

So the [F12 spec's][f12] both-mechanisms mandate is confirmed empirically:
weston 15 still ships no cursor-shape support on the headless backend, and
any client that only implements `set_shape` has no cursor there at all. The
classic theme path remains the portable floor in 2026; `cursor-shape-v1` is
the upgrade a client selects when offered (mutter/kwin status stays on the
manual Tier-C queue).

## The shape path: one request, compositor-rendered

With a real pointer focus, every zone change is a single `set_shape(serial,
enum)` — the compositor does theme lookup, scaling and animation. The
`WAYLAND_DEBUG=1` wire trace around one enter shows the whole contract — the
[core protocol][p-wayland] requires that "when a seat's focus enters a
surface, the pointer image is undefined and a client should respond to this
event by setting an appropriate pointer image with the set_cursor request",
and `set_shape` is serial-gated the same way:

```text
[2487011.679] {Default Queue}  -> wl_seat#8.get_pointer(new id wl_pointer#17)
[2487011.686] {Default Queue}  -> wp_cursor_shape_manager_v1#7.get_pointer(new id wp_cursor_shape_device_v1#13, wl_pointer#17)
[2487011.732] {Default Queue} wl_pointer#17.enter(10, wl_surface#9, 101.00000000, 101.00000000)
2003088 f12_wayland pointer_enter serial=10 pos=101,101
2003106 f12_wayland zone zone=0 cursor=nw-resize
[2487011.776] {Default Queue}  -> wp_cursor_shape_device_v1#13.set_shape(10, 21)
2003138 f12_wayland cursor_set name=nw-resize path=shape shape_enum=21 serial=10
```

The full walk delivered all eleven shapes with real enter serials —
`nw/n/ne/w/e/sw/s/se-resize` (enum values 21/19/20/25/18/24/22/23), `default`
(1), `text` (9), `pointer` (4) and `wait` (6). The [shape vocabulary][p-shape]
is the CSS cursor list: 36 named shapes at protocol v2 (`default` … `zoom_out`
in v1, `dnd_ask`/`all_resize` since v2) — far richer than the X11 cursor-font
set, and the names match the Xcursor theme names the classic path looks up,
so one table drives both paths in the demo.

## The theme path: the client does everything

Forced onto the classic path (`./run.sh sway-theme`, scale-2 output), each
change is: theme lookup → attach the frame's `wl_buffer` to a dedicated
cursor `wl_surface` → `damage` → `commit` → `set_cursor(serial, surface,
hotspot)`. The instrument log shows the HiDPI rule the client itself must
implement — reload the theme at base size × buffer scale when the scale
changes (here before the first frame even presented, via
`wl_surface.preferred_buffer_scale`):

```text
451  f12_wayland cursor_theme_load requested_size=24 base=24 scale=1 theme=(default) loaded=1
2680 f12_wayland preferred_buffer_scale factor=2
2857 f12_wayland cursor_theme_load requested_size=48 base=24 scale=2 theme=(default) loaded=1
…
2002055 f12_wayland cursor_set name=nw-resize path=theme resolved=nw-resize image=16x16 hotspot=1,1 frames=1 serial=10
```

Two findings ride in that log. First, the host theme (Adwaita, via the
default `XCURSOR_PATH` search) resolves the **modern CSS names** directly
(`resolved=nw-resize`, not the legacy `top_left_corner`) — the demo still
carries the legacy-name fallback per cursor because `libwayland-cursor`'s
own embedded fallback set only knows the X11 names. Second,
`wl_cursor_theme_load(NULL, 48, shm)` is a _request_, not a guarantee: the
theme delivered 16-px-class images for both the 24 and 48 requests (nearest
available size). The client must read `wl_cursor_image.width/height` back and
scale its hotspot accordingly (`hotspot / buffer_scale`, since the cursor
surface carries `set_buffer_scale(scale)`) — logging the _chosen_ size, not
the requested one, is the only honest instrumentation.

Animation is also the client's job on this path: `wl_cursor.image_count > 1`
means the client must run a timer (`wl_cursor_frame_and_duration` picks the
frame) and re-commit the cursor surface per frame. The demo rides its window
frame callback for this; on this host every probed cursor reported
`frames=1` (Adwaita ships no animated `wait`/`watch` here), so the timer code
path is present but unexercised — queued as Tier C on a theme with animated
cursors.

## The custom bullseye: classic path only

`cursor-shape-v1` has **no custom-image request** — an enum is all it can
say. The bullseye therefore goes through `wl_pointer.set_cursor` even when
the shape path is selected (mixing both on one `wl_pointer` is legal; the
latest request wins). The wire trace, from `wl_shm` pool to hotspot:

```text
[2495290.602] {Default Queue} wl_pointer#32.enter(120, wl_surface#9, 641.00000000, 361.00000000)
[2495290.685] {Default Queue}  -> wl_shm#4.create_pool(new id wl_shm_pool#34, fd 6, 2304)
[2495290.693] {Default Queue}  -> wl_shm_pool#34.create_buffer(new id wl_buffer#35, 0, 24, 24, 96, 0)
[2495290.706] {Default Queue}  -> wl_surface#10.set_buffer_scale(1)
[2495290.713] {Default Queue}  -> wl_surface#10.attach(wl_buffer#35, 0, 0)
[2495290.719] {Default Queue}  -> wl_surface#10.damage_buffer(0, 0, 24, 24)
[2495290.726] {Default Queue}  -> wl_surface#10.commit()
[2495290.732] {Default Queue}  -> wl_pointer#32.set_cursor(120, wl_surface#10, 12, 12)
10282087 f12_wayland cursor_set name=bullseye path=custom size=24x24 hotspot=12,12 serial=120
```

## Getting a pointer at all: the capability dance

The hardest part of this demo was not cursors but _obtaining a pointer on a
headless compositor_, and the failure modes are findings in their own right:

- **Headless weston has no `wl_seat`** (known since [the scaffold](./scaffold.md));
  the weston run is registry probe + theme dump only.
- **Headless sway has a seat with `capabilities=0`** (no input devices under
  `WLR_LIBINPUT_NO_DEVICES=1`). Calling `wl_seat.get_pointer` anyway is a
  fatal protocol error — wlroots kills the connection with:

  ```text
  wl_seat#8: error 0: wl_seat.get_pointer called when no pointer capability has existed
  ```

  A client must strictly wait for a `capabilities` event that includes
  `pointer` (the demo's first iteration bailed at startup instead of waiting —
  also wrong, since the capability can arrive _later_).

- **`wlrctl pointer move` plugs a `zwlr_virtual_pointer_v1` in**, sway adds
  the pointer capability, and the demo conformantly creates its `wl_pointer`.
  But each `wlrctl` invocation unplugs its device on exit, so the capability
  **flaps** — and per the [core protocol][p-wayland], "when the pointer
  capability is removed, a client should destroy the wl_pointer objects
  associated with the seat … No further pointer events will be received on
  these objects." The demo's first pointer went permanently silent until it
  implemented exactly that: destroy on capability loss, re-create on regain
  (`pointer_dropped` in the log). `run.sh` therefore pairs every
  `swaymsg seat seat0 cursor set <x> <y>` warp with a 1-px `wlrctl` move that
  delivers a fresh `enter` at the warped position.
- The device-plug → warp ordering is racy: across full 17-step walks, ~1–2
  enters were dropped (different steps each run); `run.sh` double-visits the
  flakiest zone. Every one of the 11 shapes + bullseye has real-serial
  evidence across the recorded runs.

## Findings

- **`cursor-shape-v1` availability (the F12 question)**: sway 1.11 **yes**
  (v1), weston 15 **no** — both mechanisms remain mandatory in a portable
  client in 2026; select per-connection from the registry. (mutter/kwin: Tier-C
  manual queue.)
- **Who composites**: on the shape path the compositor does (client cost: one
  request per change); on the theme path the client carries theme loading,
  per-scale reloads, a cursor surface with attach/damage/commit per change,
  and the animation timer. The shape path also fixes the "cursor wrong while
  app is busy" class of bugs — the compositor animates `wait` without the
  client's event loop.
- **The enter contract**: the pointer image is undefined on every
  `wl_pointer.enter`; both `set_cursor` and `set_shape` are gated on the
  enter serial (stale serial → request ignored). A toolkit must re-assert the
  cursor on every enter, not treat it as sticky state.
- **Custom pixmaps are classic-path-only** — `cursor-shape-v1` has no image
  request, so any app with a custom cursor keeps the `wl_shm` +
  `set_cursor` machinery even when it prefers shapes; mixing per-pointer is
  legal.
- **HiDPI**: theme path = client reloads at base × scale and divides the
  image hotspot by the surface's buffer scale; the requested size is
  best-effort (this host returned 16-px images for a 48-px request — log the
  actual `wl_cursor_image` dimensions). Shape path: scale handling is the
  compositor's, free.
- **Capability lifecycle**: `get_pointer` before the capability ever existed
  is fatal on wlroots; capability loss makes existing `wl_pointer` objects
  permanently silent — destroy and re-create them on each capabilities edge.
- **Name vocabularies**: the cursor-shape enum mirrors the CSS cursor names,
  and a current Adwaita resolves those same names as Xcursor lookups; the
  legacy X11 names (`left_ptr`, `xterm`, `hand1`, `top_left_corner`, …) are
  only needed for `libwayland-cursor`'s embedded fallback and old themes.
- **Tier split**: cursor _requests_ are fully Tier A (instrument +
  `WAYLAND_DEBUG` traces above); whether the pixels on screen actually look
  like an I-beam needs eyes — one Tier-C visual pass rides along with the
  other manual items, together with animated-frame playback (no animated
  theme available headless) and F10's lock-mode visibility interaction.

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f12-cursors

d=docs/research/window-system-integration/os-apis/wayland/examples/f12-cursors
nix develop -c $d/run.sh weston    # registry probe + theme dump (no seat)
nix develop -c sh -c "nix shell nixpkgs#sway nixpkgs#wlrctl -c $d/run.sh sway"        # shape path
nix develop -c sh -c "nix shell nixpkgs#sway nixpkgs#wlrctl -c $d/run.sh sway-theme"  # theme path, scale 2
```

The sway modes start `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR` (socket names `wsi-w5*` keep parallel runs apart), seed the
pointer capability via `wlrctl`, and walk the zones with `swaymsg seat seat0
cursor set` while the demo runs (`WSI_AUTO_EXIT=1 WSI_RUN_MS=12000`). Without
`wlrctl` the demo falls back to a **blind request tour** (all cursor requests
issued with serial 0) so the `WAYLAND_DEBUG` trace still carries the protocol
evidence; without a compositor it prints `SKIP:` and exits `0`.

## Sources

- **[F12 spec][f12]** — requirements 1–4 (hover zones + both-mechanism
  mandate, custom pixmap with non-trivial hotspot, HiDPI size selection, the
  lock-mode interaction deferred to F10) and the Tier-A/Tier-C split for
  cursor requests vs pixels.
- **[`cursor-shape-v1`][p-shape]** — the `shape` enum (the CSS-derived
  vocabulary and values quoted above) and `get_pointer`/`set_shape` semantics
  (protocol XML at
  `wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml`, v1.47; the
  generated glue also pulls in `tablet-v2` for the `zwp_tablet_tool_v2`
  interface symbol).
- **[Core protocol][p-wayland]** — `wl_pointer.set_cursor`/`enter` (the
  "pointer image is undefined" rule) and `wl_seat.capabilities` (the
  destroy-on-removal rule), both quoted verbatim above (XML at
  `wayland/share/wayland/wayland.xml`, wayland 1.24).
- **`libwayland-cursor`** — `wl_cursor_theme_load`, `wl_cursor_theme_get_cursor`,
  `wl_cursor_image_get_buffer`, `wl_cursor_frame_and_duration` per
  [`wayland-cursor.h`][book-seat] usage in the Wayland Book's seat chapter;
  these are real exported symbols, so ImportC calls them without `wsi_*`
  wrappers (unlike the scanner-generated `static inline` helpers — see
  [the scaffold](./scaffold.md)).
- Demo sources: [`app.d`](./examples/f12-cursors/app.d),
  [`instrument.d`](./examples/f12-cursors/instrument.d), the `c.c` shim,
  `generate.sh` (xdg-shell + tablet-v2 + cursor-shape glue) and the `run.sh`
  driver alongside it; the scale plumbing this demo's HiDPI handling reuses
  is [F08](./f08-dpi-scaling.md).

<!-- References -->

[f12]: ../features/f12-cursors.md
[p-shape]: https://wayland.app/protocols/cursor-shape-v1
[p-wayland]: https://wayland.app/protocols/wayland
[book-seat]: https://wayland-book.com/seat/pointer.html
