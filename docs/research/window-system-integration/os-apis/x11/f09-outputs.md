# X11 F09 — output enumeration & hotplug — findings

What a window can know about the displays it lives on, measured through both of
RandR's enumeration APIs, and which change events are actually deliverable on a
virtual server. The demo, [`./examples/f09-outputs/app.d`](./examples/f09-outputs/app.d),
is built on the [scaffold](./scaffold.md) (same ImportC binding style, same
`poll(2)` loop, same [`instrument.d`](./examples/f09-outputs/instrument.d) log)
and implements the [F09 feature spec][f09]. All numbers are from Tier-A runs:
the bare binary under `xvfb-run` (exit 0), plus the co-located
`examples/f09-outputs/run.sh` driver, which adds an `xrandr` choreography on
Xvfb and a nested-Xephyr phase for real size switches.

**Last reviewed:** June 11, 2026

## Two APIs, two information models — the distinction is the point

RandR exposes the same hardware twice, at different altitudes, and a toolkit
needs both. The demo enumerates both ways at startup and logs them side by side
(no window is needed for either — only the connection and the root window,
which answers the spec's "is enumeration global" question):

```text
419 f09_x11 output api=XRRGetMonitors id=screen geom=1280x1024+0+0 mm=339x271 primary=0 automatic=1 noutput=1 refresh=NOT_EXPOSED_HERE
469 f09_x11 resources api=XRRGetScreenResources noutput=1 ncrtc=1 nmode=1
521 f09_x11 output api=resources id=screen output=0x3c crtc=0x3b geom=1280x1024+0+0 mm=0x0 mode=1280x1024 refresh=dotClock/(hTotal*vTotal)=0/(0*0)=0.00Hz
```

- **`XRRGetMonitors` (RandR ≥ 1.5)** is the modern, _logical_ per-monitor view:
  the rectangles a desktop is tiled into — name (an `Atom`, one
  `XGetAtomName` round-trip away), geometry, `primary`/`automatic` flags,
  physical millimeters. This is the level `wl_output`/`EnumDisplayMonitors`
  peers live at. What it does **not** carry: modes, and therefore refresh.
- **`XRRGetScreenResources` + `XRRGetOutputInfo`/`XRRGetCrtcInfo` (RandR ≥
  1.2)** is the _wiring-level_ object model the [RandR protocol][randrproto]
  defines: **outputs** (physical connectors, which may be disconnected or
  connected-but-off, `crtc=none`) are driven by **crtcs** (scanout engines
  with a position, size and rotation) which run **modes** (timing blocks).
  Per the protocol spec, a crtc "defines a region of pixels visible on one or
  more outputs" while modes carry the full video timing — and that is where
  refresh lives.

### Refresh is computed, not stored

`XRRModeInfo` has no refresh field; the rate falls out of the timing block:
**`refresh = dotClock / (hTotal × vTotal)`** — pixels per second divided by
pixels per frame, the same arithmetic `xrandr --verbose` performs. The demo
logs the math term by term. On real hardware a 1920×1080 CEA timing gives
`148500000 / (2200 × 1125) = 60.00 Hz`; on the virtual servers the result is
honest in a different way:

- **Xvfb** publishes a single synthetic mode with an empty timing block —
  `dotClock=0, hTotal=0, vTotal=0` → `0.00 Hz`. There is no scanout timing to
  describe (the mode-level face of the [F04][f04] finding that core X11 — and
  Xvfb especially — offers no frame clock).
- **Xephyr** publishes 15 modes whose totals merely equal the pixel size
  (`0/(800*600)`), so the refresh is still `0.00 Hz` — fake timings, real
  mode _list_.

### The two views disagree about physical size

Same server, same instant, phase 1 above: `XRRGetMonitors` reports
`mm=339x271` while `XRRGetOutputInfo` reports `mm_width=0, mm_height=0`. The
monitor view _synthesizes_ millimeters at 96 DPI from the pixel size
(1280 px / 339 mm ≈ 96 DPI) when the output has none — so a DPI computed from
the monitor API on a virtual display is a fabrication, while the output API
admits ignorance. Code that mixes the two levels will compute two different
"physical" DPIs from one screen.

## Window ↔ output occupancy is derived geometry

X11 never tells a window which output(s) it is on — there is no equivalent of
Wayland's `wl_surface.enter`/`leave`, where the compositor tells the surface
directly. The demo derives it on every `ConfigureNotify`: translate the window
origin to root coordinates (`XTranslateCoordinates` — `ConfigureNotify.x/y`
are parent-relative and exclude the border) and intersect the window rect with
each monitor rect. The auto-exit `XMoveWindow` storm proves the derivation
against the single Xvfb monitor — half off, fully off, back on:

```text
956 f09_x11 surface_output enter id=screen overlap=320x240 of=320x240 derived=window_rect(41,41,320x240)_vs_monitor_rect
2003637 f09_x11 configure pos=-1000,40 size=320x240
2003692 f09_x11 surface_output leave id=screen
2003712 f09_x11 surface_output none window=(-999,41,320x240) outside all monitors (window keeps running; nothing tells it)
3005094 f09_x11 surface_output enter id=screen overlap=320x240 of=320x240 derived=window_rect(41,41,320x240)_vs_monitor_rect
```

The `none` line is the spec's "current output vanishes" case in miniature: a
window positioned outside every monitor rect keeps running normally — no
event, no error, no clamping. Nothing in core X11 or RandR considers that
state special; only the client's own derivation can notice it.

## Hotplug: what is reachable on a virtual server, measured

The demo selects every change event RandR offers —
`XRRSelectInput(RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask |
RROutputChangeNotifyMask | RROutputPropertyNotifyMask)` — and the `run.sh`
driver throws every available stimulus at it:

| Stimulus                                     | Server | Events observed                                                                                                   |
| -------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------- |
| `xrandr --dpi 144`                           | Xvfb   | `RRScreenChangeNotify` (mm-only; px unchanged)                                                                    |
| `xrandr --output screen --set non-desktop 1` | Xvfb   | `RRScreenChangeNotify` + `RRNotify_OutputChange` (`connection` flips to disconnected) + `RRNotify_OutputProperty` |
| `xrandr -s 1280x1024` (the only listed size) | Xvfb   | **nothing** — a same-size `-s` is a silent no-op                                                                  |
| `xrandr -s 1024x768` / `-s 640x480`          | Xephyr | a burst: 3× `RRScreenChangeNotify` + `RRNotify` CrtcChange + OutputChange (see below)                             |

Xvfb's _output set_ is static — one output `screen`, one mode, maximum screen
size pinned to the initial size (`xrandr --fb` larger fails with `BadValue`,
and `--newmode` succeeds but the mode never becomes addable). So
`output_added`/`output_removed` is not reachable there. Two findings stand in
for the unplug:

**The `non-desktop` soft-unplug.** Setting the standard `non-desktop` output
property is the nearest software-reachable analogue of pulling the cable: the
output's `connection` state flips to disconnected, and the demo's
re-enumeration diff catches it exactly as it would a real unplug:

```text
5509671 f09_x11 output_connection id=screen connected=0
5509711 f09_x11 randr_notify subtype=OutputChange output=0x3c crtc=0x3b mode=0x3a connection=1
5509885 f09_x11 randr_notify subtype=OutputProperty output=0x3c property=non-desktop state=0
```

**Real size switches on nested Xephyr.** Xephyr (itself RandR 1.6, not the
1.1 relic its `default` output name suggests) ships a 15-entry mode list, so
`xrandr -s` performs an actual pixel-size switch. One `-s 1024x768` produced
this burst — note the wiring-level shape of a mode switch, output detached
from its crtc (`crtc=0x0 mode=0x0`) then re-attached with the new mode:

```text
4507541 f09_x11 randr_notify subtype=OutputChange output=0x22b crtc=0x0 mode=0x0 connection=0
4507628 f09_x11 randr_screen_change px=1024x768 mm=271x203 size_index=65535 rotation=1
4507709 f09_x11 randr_screen_change px=1024x768 mm=271x203 size_index=5 rotation=1
4507865 f09_x11 randr_notify subtype=OutputChange output=0x22b crtc=0x22a mode=0x231 connection=0
```

One user-visible change arrived as **seven events** (3 screen-changes + 4
notifies in the full log) — a client that re-lays-out per event instead of
coalescing will thrash. After each `RRScreenChangeNotify` the demo calls
`XRRUpdateConfiguration`, without which Xlib's cached `XDisplayWidth/Height`
stay stale (the same connect-time-snapshot trap [F08][f08] measured for the
resource string).

> [!NOTE]
> **Tier C — real hotplug.** An actual connector plug/unplug (DP/HDMI on a
> live session, a `output_added` with a nonempty diff, and the WM's reaction
> when the window's output vanishes) is not reachable on Xvfb or Xephyr and
> remains queued for a physical-session pass, per the
> [verification tiers][f09].

## Surprises

- **The two RandR views fabricate differently.** `XRRGetMonitors` invents
  96-DPI millimeters for a 0 mm output; `XRRGetOutputInfo` reports the zeros.
  Pick a level and stay there.
- **`non-desktop` flips `connection`.** An output _property_ write changes
  the output's connection state on Xvfb — a soft-unplug a test harness can
  use where no real connector exists.
- **`xrandr -s` to the current size emits nothing.** No
  `RRScreenChangeNotify`, no `RRNotify` — idempotent requests are filtered
  server-side, so "poke RandR to re-assert the mode" is not a wake-up signal.
- **Xephyr announces a screen change immediately after `XRRSelectInput`**
  (a `RRScreenChangeNotify` at 696 µs, before any stimulus) — a timestamp
  catch-up delivery; clients must tolerate an unprovoked first event.
- **`size_index=65535` (`SZ_None`) for 1.2-originated changes.** Only the
  legacy `-s` path reports a real index into the 1.1 size list; mode-set
  changes deliver the sentinel.
- **One stimulus, many events.** Every Xephyr size switch delivered 3
  `RRScreenChangeNotify` + multiple `RRNotify` — coalescing is the client's
  job; the demo re-enumerates per event and the log shows the redundancy.

## Build and run

Tier A, from the repo root — the bare binary enumerates, runs its occupancy
move storm and exits 0 (no display → `SKIP: no X11 display`, exit 0):

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f09-outputs
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    docs/research/window-system-integration/os-apis/x11/examples/f09-outputs/build/f09_outputs_x11
```

The full choreography (Xvfb stimuli + the nested-Xephyr size switches) is the
co-located driver `examples/f09-outputs/run.sh` (run from the dev shell; it
pulls `xrandr` and `Xephyr` via `nix shell`). Link dependencies: `x11`,
`xrandr` (pkg-config names, both in the dev shell).

## Sources

- **[RandR protocol][randrproto]** — the output/crtc/mode object model, mode
  timing fields (`dotClock`, `hTotal`, `vTotal`), `RRScreenChangeNotify` /
  `RRNotify` event definitions, the `non-desktop` output property, and
  RandR 1.5 monitors.
- **[Xrandr man page][xrandr-man3]** — `XRRGetMonitors`,
  `XRRGetScreenResources`, `XRRGetOutputInfo`/`XRRGetCrtcInfo`,
  `XRRSelectInput`, `XRRUpdateConfiguration`.
- **[`xrandr` man page][xrandr-man]** — `-s`/`--fb`/`--dpi`/`--set` driver
  vocabulary used by `run.sh`.
- **This survey** — the [X11 deep-dive](./index.md), the [scaffold
  findings](./scaffold.md) (binding style, event-loop discipline), the
  [F08 DPI findings](./f08-dpi-scaling.md) (the `RRScreenChangeNotify`
  reachability this demo builds on), and the [F09 feature spec][f09]; the
  runnable sources [`./examples/f09-outputs/app.d`](./examples/f09-outputs/app.d)
  and [`./examples/f09-outputs/instrument.d`](./examples/f09-outputs/instrument.d)
  (plus the `c.c` ImportC shim and the `run.sh` driver alongside them).

<!-- References -->

[f04]: ./f04-frame-pacing.md
[f08]: ./f08-dpi-scaling.md
[f09]: ../features/f09-outputs.md
[randrproto]: https://gitlab.freedesktop.org/xorg/proto/randrproto/-/blob/master/randrproto.txt
[xrandr-man]: https://www.x.org/releases/current/doc/man/man1/xrandr.1.xhtml
[xrandr-man3]: https://www.x.org/releases/current/doc/man/man3/Xrandr.3.xhtml
