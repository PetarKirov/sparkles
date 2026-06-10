# Wayland F09 — Output enumeration & hotplug

What can a Wayland window know about the displays it lives on, and what
exactly happens when one appears, changes, or vanishes under a live window?
The demo, [`./examples/f09-outputs/app.d`](./examples/f09-outputs/app.d),
extends the [scaffold](./scaffold.md) to the [F09 spec][f09]: it binds
**every** [`wl_output`][p-wayland] global at v4 (geometry/mode/scale +
name/description), attaches a [`zxdg_output_v1`][p-xdgout] to each for the
_logical_ geometry, tracks surface↔output occupancy via
`wl_surface.enter`/`leave`, and handles `wl_registry.global_remove` —
including for the output the window currently occupies. Verified Tier A under
headless weston 15 (static single output — the headless backend cannot
hotplug, recorded as the baseline) and headless sway 1.11 with a **live**
hotplug choreography (`swaymsg create_output`, reconfigure, cross-output
move, `swaymsg output … disable` on the occupied output); all runs exit `0`.
The driver script `run.sh` next to the demo reproduces both.

**Last reviewed:** June 11, 2026

## The information model: physical vs logical

The deliverable. One output is described twice, by two protocols with
different coordinate systems:

| Property      | `wl_output` (physical)                                                                 | `zxdg_output_v1` (logical)                                                     |
| ------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Position      | `geometry` x,y "within the global compositor space" — but in _output_ terms            | `logical_position` — where the output rectangle sits in the compositor space   |
| Size          | `mode` width×height — **buffer pixels** of the active mode                             | `logical_size` — the mode **divided by scale**, transform applied              |
| Scale         | `scale` (v2) — integer only                                                            | implied by `mode / logical_size` (can be fractional)                           |
| Refresh       | `mode` refresh in mHz                                                                  | —                                                                              |
| Identity      | `name` (v4), `description` (v4); the `wl_registry` global name is the hotplug identity | `name`/`description` (v2, deprecated since v3 — `wl_output` v4 took them over) |
| Physical size | `geometry` width/height in millimetres                                                 | —                                                                              |
| Atomicity     | event batch closed by `wl_output.done` (v2)                                            | v2: own `done`; **v3: latched to `wl_output.done`**                            |

The split was observed live: `swaymsg output HEADLESS-2 resolution 1024x768
position 1280 0 scale 2` produced `mode=1024x768` on the `wl_output` side and
`logical size=512x384` from xdg-output — exactly the [protocol XML's][p-xdgout]
worked example:

> "For example, for a wl_output mode 3840×2160 and a scale factor 2: A
> compositor scaling the monitor viewport with scale factor 2 will advertise a
> logical size of 1920×1080."

The protocol also warns who this is for: "Most regular Wayland clients should
not pay attention to the logical size and would rather rely on xdg_shell
interfaces." — the logical rectangle exists for the Xwayland/global-positioning
class of clients, and for answering "how big is this output in the units my
`configure` events use".

Gaps found on headless backends: sway's headless outputs report
`refresh_mhz=0` and `physical_mm=0x0` (no EDID, no refresh), while weston's
headless output reports a fixed `refresh_mhz=60000` and **fabricates**
`physical_mm=1024x640` — millimetres numerically equal to its pixel size. A
client must treat both fields as best-effort, not ground truth.

## Enumeration is connection-global, no window needed

The demo enumerates before creating any surface: bind the registry, bind each
`wl_output` (+ `get_xdg_output`), and two `wl_display_roundtrip`s later every
output has delivered its batch (first roundtrip: globals; second: the
per-output events, plus a pass to attach `xdg_output`s in case the manager
global arrived after the outputs). Weston baseline (instrument log, µs):

```text
98  f09_wayland xdg_output_manager version=2 (logical geometry available)
138 f09_wayland output_enumerated id=17 name=headless
141 f09_wayland output id=17 name=headless geom=1024x640+0+0 scale=1 refresh_mhz=60000 physical_mm=1024x640
144 f09_wayland output_logical id=17 pos=0,0 size=1024x640 (zxdg_output_v1 v2 done)
146 f09_wayland enumeration_done outputs=1 xdg_output_manager=1
```

One version split bit immediately: weston offers `zxdg_output_manager_v1`
**v2**, where logical updates are closed by `zxdg_output_v1.done`; sway offers
**v3**, where that event is deprecated and the batch is latched to
`wl_output.done` instead. A portable client must handle both completion
signals (the demo logs which one fired).

## Hotplug, live on sway

`./run.sh sway` drives the full choreography against the running demo. Hot-add
(`swaymsg create_output`):

```text
2009289 f09_wayland output_added id=52 name=HEADLESS-2
2009292 f09_wayland output id=52 name=HEADLESS-2 geom=1920x1080+0+0 scale=1 refresh_mhz=0 physical_mm=0x0
2009299 f09_wayland output_logical id=52 pos=1280,0 size=1920x1080 (zxdg_output_v1)
```

A new `wl_registry.global` arrives carrying the next registry name (52); the
new output auto-places at `logical pos=1280,0` — to the right of HEADLESS-1.
The reconfigure (`… resolution 1024x768 position 1280 0 scale 2`) then showed
two things worth knowing:

```text
3517126 f09_wayland surface_output leave id=51 name=HEADLESS-1
3517143 f09_wayland surface_output enter id=51 name=HEADLESS-1
3517149 f09_wayland output id=52 name=HEADLESS-2 geom=1024x768+0+0 scale=2 …
3517153 f09_wayland output_logical id=52 pos=1280,0 size=512x384 (zxdg_output_v1)
3517159 f09_wayland output id=51 name=HEADLESS-1 geom=1280x720+0+0 scale=1 …
3517163 f09_wayland output_logical id=51 pos=1792,0 size=1280x720 (zxdg_output_v1)
```

- **Reconfiguring output B updated output A too**: sway re-laid-out the global
  space (HEADLESS-1's logical position jumped to `1792,0` to make room), so
  one `swaymsg` produced update batches on _both_ outputs. Output state is a
  set, not independent records.
- **A spurious same-output `leave`/`enter` pair** fired on HEADLESS-1 during
  the re-layout. Occupancy handlers must be idempotent — treating `leave` as
  "tear down per-output state" without checking what follows would thrash.

The cross-output move (`swaymsg '[app_id="wsi-f09-outputs"]' move container to
output HEADLESS-2`) revealed the event order: the **configure arrives first**
(the window is retiled to the new output's `512x384` logical size), and the
`leave`/`enter` pair lands only ~200 ms later, after the client commits a
buffer at the new size — consistent with the [core protocol's][p-wayland]
definition that enter "is emitted whenever a surface's creation, movement, or
resizing results in some part of it being within the scanout region of an
output". Occupancy is derived from committed buffers, so it _trails_ the
resize; a client must not gate "which output am I on" decisions on
`enter` having arrived yet.

## The vanishing occupied output

The destroyed-global contract, end to end — `swaymsg output HEADLESS-2
disable` while the window sits on HEADLESS-2 (`WAYLAND_DEBUG=1` wire trace
interleaved with the instrument lines):

```text
[1034023.541] {Default Queue} wl_surface#3.leave(wl_output#16)
6528505 f09_wayland surface_output leave id=52 name=HEADLESS-2
[1034023.552] {Default Queue} wl_registry#2.global_remove(52)
6528515 f09_wayland output_removed id=52 name=HEADLESS-2 occupied=0
[1034023.556] {Default Queue}  -> zxdg_output_v1#12.destroy()
[1034023.557] {Default Queue}  -> wl_output#16.release()
[1034024.056] {Default Queue} wl_surface#3.enter(wl_output#8)
6529020 f09_wayland surface_output enter id=51 name=HEADLESS-1
[1034024.064] {Default Queue} wl_output#8.done()
[1034024.069] {Default Queue} xdg_toplevel#11.configure(1280, 720, array[4])
[1034024.073] {Default Queue} xdg_surface#10.configure(9)
[1034024.076] {Default Queue}  -> xdg_surface#10.ack_configure(9)
```

The sequence (feeds `event-sequences.md`): **(1)** `wl_surface.leave` for the
dying output — sway delivers it _before_ **(2)** `wl_registry.global_remove`,
so a client that drops per-output state on `leave` never holds a dangling
reference; **(3)** the client destroys its proxies (`zxdg_output_v1.destroy`,
then `wl_output.release` — the v3+ destructor request that tells the server
the client is done; plain `wl_proxy_destroy` would leak the server-side
resource); **(4)** `wl_surface.enter` on the surviving output; **(5)** a fresh
configure resizing the window to the new output. No crash, no stale state —
but only because the client treats the registry name (52) as the output's
identity and is prepared for events referencing an already-released proxy
(libwayland delivers such stragglers with a `NULL`/unknown object; the demo
logs them as `id=?` rather than dereferencing).

Note the ordering is a compositor courtesy, not a spec guarantee: the core
protocol only says the global "is gone" — a robust client must survive
`global_remove` arriving while it still believes the surface is on that
output (the demo clears occupancy itself in that case).

## Findings

- **Enumeration is global** — a connection plus two roundtrips, no window
  needed. The expensive part of "what monitors are there" is zero protocol
  round-trips after the registry; everything arrives as events.
- **The logical/physical split is two protocols**: `wl_output.mode` is buffer
  pixels, `zxdg_output_v1.logical_size` is mode ÷ scale (observed: 1024×768 @
  scale 2 → 512×384). Without xdg-output a client cannot place outputs in the
  coordinate space its own `configure` sizes use.
- **Completion is version-dependent**: `zxdg_output_v1.done` at manager v2
  (weston), `wl_output.done` at v3 (sway). Handle both.
- **Hotplug identity is the registry name** (`global`/`global_remove` carry
  it); `wl_output.name` ("HEADLESS-2") is the human label. Removal requires
  `wl_output.release` (v3+), not bare proxy destruction.
- **The vanishing-output order on sway** is leave → global_remove → enter(new)
  → configure(new size). The window is never "nowhere" for more than a frame,
  and the resize comes through the ordinary configure/ack path — no special
  hotplug handling beyond proxy cleanup.
- **One output change can update all outputs** (global-space re-layout), and
  spurious same-output leave/enter pairs occur — occupancy and output-state
  handlers must be idempotent and set-oriented.
- **`refresh`/`physical_mm` are unreliable**: 0 on sway headless, fabricated
  (mm = pixels) on weston headless. Real refresh needs `wl_output.mode` on
  real hardware — and even then F04's presentation feedback, not the mode
  field, is the truth for frame pacing.
- **Hotplug Tier A is sway-only**: weston's headless backend creates its
  output set at startup (no runtime add/remove), so it serves as the static
  baseline; the hot-add/hot-remove evidence above is wlroots'.

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f09-outputs

d=docs/research/window-system-integration/os-apis/wayland/examples/f09-outputs
nix develop -c $d/run.sh weston           # static single-output baseline
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway"  # live hotplug
```

The `sway` mode starts `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR` (socket names `wsi-w5*` keep parallel runs apart) and issues
the `swaymsg` storm itself while the demo runs (`WSI_AUTO_EXIT=1
WSI_RUN_MS=10000`). Without a compositor the demo prints `SKIP:` and exits `0`.

## Sources

- **[F09 spec][f09]** — requirements 1–3 (enumeration fields, occupancy
  tracking, hotplug without crash or stale state) and the Tier-A-via-headless
  verification plan.
- **[Core protocol][p-wayland]** — `wl_output` (geometry/mode/scale/name/
  description/done, the `release` destructor), `wl_registry.global_remove`,
  and `wl_surface.enter`/`leave` (the "scanout region" definition quoted
  above; protocol XML at `wayland/share/wayland/wayland.xml`, wayland 1.24).
- **[`xdg-output-unstable-v1`][p-xdgout]** — `logical_position`/`logical_size`
  (the scale-2 worked example and the "most regular Wayland clients should not
  pay attention" caveat quoted above; XML at
  `wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml`, v1.47).
- **[Wayland scaffold findings](./scaffold.md)** — base implementation and the
  build-system gotchas this demo inherits.
- Demo sources: [`app.d`](./examples/f09-outputs/app.d),
  [`instrument.d`](./examples/f09-outputs/instrument.d), the `c.c` shim,
  `generate.sh` (xdg-shell + xdg-output glue) and the `run.sh` driver
  alongside it; the cross-output _scale_ consequences live in
  [F08](./f08-dpi-scaling.md).

<!-- References -->

[f09]: ../features/f09-outputs.md
[p-wayland]: https://wayland.app/protocols/wayland
[p-xdgout]: https://wayland.app/protocols/xdg-output-unstable-v1
