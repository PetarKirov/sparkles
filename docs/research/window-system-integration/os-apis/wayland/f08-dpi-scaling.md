# Wayland F08 — DPI / runtime rescale

What does a Wayland window know about its scale, when does it learn it, and
what exactly happens when the user changes it under a live window? The demo,
[`./examples/f08-dpi-scaling/app.d`](./examples/f08-dpi-scaling/app.d),
extends the [scaffold](./scaffold.md) to the [F08 spec][f08] with **both**
scale paths in one binary, runtime-selected by the advertised globals:
[`wp_fractional_scale_v1`][p-frac] + [`wp_viewport`][p-vp] (buffer at physical
size, destination at logical size), and the integer
[`wl_surface.set_buffer_scale`][p-wayland] fallback driven by
`wl_surface.preferred_buffer_scale` (v6) / `wl_output.scale` (pre-v6). The
frame is a physical-pixel checkerboard with 1-physical-px hairlines on all
four buffer edges, so any compositor resampling is visible in a screenshot.
Verified Tier A under headless weston 15 (integer path, `weston.ini`
`scale=2`) and headless sway 1.11 (fractional path, **live**
`swaymsg output … scale` changes 1 → 1.5 → 2 → 1 mid-run, plus a
"monitor drag" between two headless outputs at scales 1 and 2); all runs
exit `0`. The driver script `run.sh` next to the demo reproduces all three
choreographies.

**Last reviewed:** June 11, 2026

## Which path, on which compositor

The demo selects at startup and logs `path_selected` plus a full registry
dump; `WSI_FORCE_PATH=buffer_scale|fractional` overrides for A/B runs:

| Capability                                              | weston 15.0 headless | sway 1.11 headless |
| ------------------------------------------------------- | -------------------- | ------------------ |
| `wp_viewporter`                                         | yes (v1)             | yes (v1)           |
| `wp_fractional_scale_manager_v1`                        | **no**               | yes (v1)           |
| `wl_compositor` version (v6 = `preferred_buffer_scale`) | **5**                | 6                  |
| `wl_output.scale` fallback                              | yes (v4 output)      | yes (v4 output)    |
| Path the demo selects                                   | `buffer_scale`       | `fractional`       |
| Fractional scales possible                              | no (integer only)    | yes (120ths)       |

Weston 15 thus exercises the _legacy_ chain end-to-end: no fractional
protocol, and — `wl_compositor` still at v5 — not even
`preferred_buffer_scale`; the only scale signal a client gets is
`wl_output.scale` plus `wl_surface.enter` to learn _which_ output that is.
Sway provides the full modern stack and is the headline Tier-A path.

## The fractional buffer math (and the rounding rule)

[`fractional-scale-v1`][p-frac] keeps the surface in logical coordinates and
moves the scale into the buffer↔destination relation: "A client can submit
scaled content by utilizing wp_viewport… setting the destination rectangle to
the surface size before the scale factor is applied. … The wl_surface buffer
scale should remain set to 1." The preferred scale arrives as "the numerator
of a fraction with a denominator of 120" (`preferred_scale(180)` = 1.5×), and
the buffer size rule is, verbatim:

> "If a surface has a surface-local size of 100 px by 50 px and wishes to
> submit buffers with a scale of 1.5, then a buffer of 150px by 75 px should
> be used and the wp_viewport destination rectangle should be 100 px by 50 px.
> For toplevel surfaces, the size is rounded halfway away from zero."

For positive sizes "halfway away from zero" is round-half-up, i.e.
`physical = (logical * scale120 + 60) / 120` in integers. The demo asserts
this at compile time (`static assert(physSize(101, 180) == 152)` — 151.5
rounds _up_; `physSize(33, 150) == 41` — 41.25 rounds down) and at every
commit, and sway confirmed it live: logical `849x453` at scale120=180
produced buffer `1274x680` (849 × 1.5 = 1273.5 → 1274; 453 × 1.5 = 679.5 →
680). What `wp_viewport` decouples is exactly this: the committed buffer can
be _any_ physical size while `set_destination` pins the surface's logical
size — without it the fractional protocol is unusable, which is why the demo
only selects the fractional path when **both** globals are present.

## Live rescale on sway: the event sequence

The deliverable for `event-sequences.md`. `swaymsg output HEADLESS-1 scale 1.5`
against the running demo (fractional path; instrument log, µs):

```text
2599804 f08_wayland output_scale scale=2 (wl_output v2)
2599843 f08_wayland preferred_scale scale120=180 (wp_fractional_scale_v1)
2599872 f08_wayland scale_changed scale120=180 scale=1.500 path=fractional
2599892 f08_wayland commit_info reason=preferred_scale logical=1276x693 buffer=1914x1040 scale120=180
2599913 f08_wayland preferred_buffer_scale factor=2 (wl_surface v6)
2599930 f08_wayland output_geometry physical_mm=0x0
2599948 f08_wayland output_scale scale=2 (wl_output v2)
2599965 f08_wayland xdg_toplevel_configure size=849x453 (logical)
2599983 f08_wayland configure serial=156 size=849x453
2600005 f08_wayland resize size=849x453 scale120=180
2600031 f08_wayland commit_info reason=configure logical=849x453 buffer=1274x680 scale120=180
```

So the order is: **(1)** `wl_output.scale` — reporting **2**, not 1.5: the
integer event can only carry ceil(1.5), a trap for legacy clients —
**(2)** `wp_fractional_scale_v1.preferred_scale(180)`, the actual value,
**(3)** `wl_surface.preferred_buffer_scale(2)`, again the integer ceiling,
**(4)** a fresh `xdg_toplevel.configure`/`xdg_surface.configure` with a **new
logical size** (sway retiled the window: fewer logical pixels fit a scaled
output). The same wire-level interlock, from `WAYLAND_DEBUG=1`:

```text
[ 998456.198] {Default Queue} wp_fractional_scale_v1#10.preferred_scale(180)
[ 998456.443] {Default Queue}  -> wl_shm_pool#18.create_buffer(new id wl_buffer#14, 0, 1914, 1040, 7656, 0)
[ 998465.159] {Default Queue}  -> wp_viewport#11.set_destination(1276, 693)
[ 998465.174] {Default Queue}  -> wl_surface#3.attach(wl_buffer#14, 0, 0)
[ 998465.195] {Default Queue}  -> wl_surface#3.commit()
[ 998465.287] {Default Queue} xdg_toplevel#13.configure(849, 453, array[8])
[ 998465.311] {Default Queue} xdg_surface#12.configure(174)
[ 998465.334] {Default Queue}  -> xdg_surface#12.ack_configure(174)
```

Two consequences for a framework:

- **A scale change is (often) also a resize.** The client re-rendered at the
  new scale immediately (1914×1040 for the old 1276×693 logical size — valid,
  the protocol allows it), but one event later the compositor handed it a new
  logical size anyway. Treat `preferred_scale` as "re-derive buffer geometry",
  not as a standalone repaint trigger, and coalesce with the configure that
  tends to follow.
- The transitions 1.5 → 2 (`preferred_scale(240)`, logical 636×333 → buffer
  1272×666) and 2 → 1 (`preferred_scale(120)`) followed the identical order;
  scale-down is not special.

The forced integer path on the same compositor
(`WSI_FORCE_PATH=buffer_scale`, `swaymsg … scale 2`) is the same dance with
`preferred_buffer_scale` as the driver and whole-number buffers
(`set_buffer_scale(2)`, logical 1276×693 → buffer 2552×1386 — committed
buffer dimensions must be divisible by the scale, which `logical × scale` is
by construction):

```text
2095030 f08_wayland output_scale scale=2 (wl_output v2)
2095066 f08_wayland preferred_buffer_scale factor=2 (wl_surface v6)
2095084 f08_wayland scale_changed scale120=240 scale=2.000 path=buffer_scale
2110599 f08_wayland xdg_toplevel_configure size=636x333 (logical)
```

## Created at the wrong scale? Yes — by design, on both compositors

[The core protocol][p-wayland] defines the baseline: "Before receiving this
event [`preferred_buffer_scale`] the preferred buffer scale for this surface
is 1." The demo logs `first_commit` with whatever it believed at that moment:

```text
# weston 15, weston.ini [output] scale=2 — integer path:
262  f08_wayland configure serial=1 size=640x480
1572 f08_wayland first_commit logical=640x480 buffer=640x480 scale120=120 path=buffer_scale
1636 f08_wayland surface_enter output_scale=2
1638 f08_wayland scale_changed scale120=240 scale=2.000 path=buffer_scale
1651 f08_wayland buffer_alloc size=1280x960 bytes=4915200

# sway 1.11, output already at scale 1 — fractional path:
2697 f08_wayland first_commit … scale120=120 path=fractional
2989 f08_wayland preferred_scale scale120=120 (wp_fractional_scale_v1)
```

The first buffer is **always committed at scale 1**: weston's `wl_output` had
announced `scale=2` during the registry roundtrip, but the client cannot know
it will land on that output until `wl_surface.enter` — which arrives only
_after_ the first commit maps the surface. Sway's initial `preferred_scale`
likewise arrives post-map (272 µs _after_ `first_commit`), even when it merely
confirms scale 1. So every Wayland window goes through a
created-at-scale-1-then-rescaled cycle unless the toolkit guesses from
`wl_output` globals (the common heuristic: max scale across outputs) — one
guaranteed re-allocation on HiDPI, visible here as the immediate 1280×960
`buffer_alloc`.

## Headless "monitor drag" between scales

Requirement 3 of [the spec][f08], without monitors: a second headless output
(`swaymsg create_output`, then `output HEADLESS-2 scale 2`) and an IPC move
(`swaymsg '[app_id="wsi-f08-dpi-scaling"]' move container to output HEADLESS-2`):

```text
4305754 f08_wayland surface_leave
4305769 f08_wayland preferred_scale scale120=240 (wp_fractional_scale_v1)
4305787 f08_wayland scale_changed scale120=240 scale=2.000 path=fractional
4305822 f08_wayland preferred_buffer_scale factor=2 (wl_surface v6)
…
6320896 f08_wayland surface_enter output_scale=1
6320929 f08_wayland preferred_scale scale120=120 (wp_fractional_scale_v1)
```

The cross-output move is just `leave`/`enter` bracketing the same
`preferred_scale` sequence as a live rescale — one mechanism, not two. The
buffers swapped 956×513 → 1912×1026 and back with the hairlines intact (the
fractional path never lets the compositor resample: the buffer is always
exactly right). Weston cannot run this variant headless: its headless backend
creates a single output (`--width/--height`), and with no pointer there is no
way to move the window anyway.

## Findings

- **Two disjoint mechanisms, both mandatory.** sway delivers fractional
  (`preferred_scale`, 120ths) and weston only legacy integer
  (`wl_output.scale` + `enter`, since it is still `wl_compositor` v5 — even
  `preferred_buffer_scale` cannot be relied on in 2026). The demo's
  capability-based path selection is the portable shape.
- **Scale event order (sway)**: `wl_output.scale` (integer-rounded!) →
  `preferred_scale(120ths)` → `preferred_buffer_scale` (integer) → configure
  with new logical size. The legacy integer events fire _alongside_ the
  fractional one and always round up — a client must ignore them once it
  binds fractional-scale, or it will double-handle every change.
- **Rounding**: buffer = logical × scale120 / 120, half away from zero, per
  edge-length; verified live (849 → 1274 at 1.5×) and enforced by the demo's
  per-commit assert. `wp_viewport.set_destination` is what makes non-integer
  ratios legal at all.
- **The first commit is always at scale 1** (the spec's documented default);
  the authoritative scale arrives post-map on both compositors. Plan for one
  guaranteed rescale/realloc right after mapping on any scaled output.
- **A scale change usually arrives glued to a resize** (retiling/re-layout),
  so "scale changed" handling must share the buffer-reallocation path with
  configure handling, not trigger its own.
- **Units audit**: `xdg_toplevel.configure`, `wl_surface` coordinates, input
  positions and F07's `set_cursor_rectangle` are logical; only the buffer
  (and `damage_buffer`) is physical. The single place the two meet is the
  attach/viewport/commit triple.
- `wl_output.scale` on a fractional output is a **lie by rounding** (reports
  2 for 1.5); never derive rendering decisions from it when fractional-scale
  is available.

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f08-dpi-scaling

d=docs/research/window-system-integration/os-apis/wayland/examples/f08-dpi-scaling
nix develop -c $d/run.sh weston           # integer path, static scale 1
nix develop -c $d/run.sh weston-scale2    # integer path, weston.ini scale=2
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway"  # fractional + live 1→1.5→2→1
```

The `sway` mode starts `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR` and issues the `swaymsg output … scale` storm itself while
the demo runs (`WSI_AUTO_EXIT=1 WSI_RUN_MS=9000`). Direct runs honor
`WSI_FORCE_PATH=fractional|buffer_scale` for A/B comparisons; without a
compositor the demo prints `SKIP:` and exits `0`.

## Sources

- **[F08 spec][f08]** — requirements 1–3 (continuous geometry logging,
  both-path mandate, the runtime change and cross-scale move) and the
  Tier-A-via-headless-outputs verification plan.
- **[`fractional-scale-v1`][p-frac]** — the verbatim 100×50-at-1.5 example
  and the "rounded halfway away from zero" rule; `preferred_scale` 120ths
  semantics (protocol XML at
  `wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml`, v1.47).
- **[`viewporter`][p-vp]** — `wp_viewport.set_destination` (the
  buffer↔surface decoupling the fractional path rides on).
- **[Core protocol][p-wayland]** — `wl_surface.set_buffer_scale`,
  `preferred_buffer_scale` (the "preferred buffer scale … is 1" default
  quoted above), `wl_output.scale`, `wl_surface.enter`/`leave`.
- **[Wayland scaffold findings](./scaffold.md)** — base implementation and
  the configure/ack/commit resize contract this demo re-runs at four scales.
- Demo sources: [`app.d`](./examples/f08-dpi-scaling/app.d),
  [`instrument.d`](./examples/f08-dpi-scaling/instrument.d), the `c.c` shim,
  `generate.sh` (xdg-shell + viewporter + fractional-scale glue) and the
  `run.sh` driver alongside it; the logical-units consumer on the input side
  is [F07](./f07-text-input.md).

<!-- References -->

[f08]: ../features/f08-dpi-scaling.md
[p-frac]: https://wayland.app/protocols/fractional-scale-v1
[p-vp]: https://wayland.app/protocols/viewporter
[p-wayland]: https://wayland.app/protocols/wayland
