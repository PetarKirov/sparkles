# X11 F08 — DPI / runtime rescale (the absence proof)

X11's answer to "what happens when the scale changes under a live window" is:
**nothing happens to the window**. That absence is the [F08 spec][f08]'s
deliverable for this platform, and the demo,
[`./examples/f08-dpi-scaling/app.d`](./examples/f08-dpi-scaling/app.d),
proves it by measurement: it snapshots every DPI-adjacent value a toolkit can
read at startup (`Xft.dpi` from the `RESOURCE_MANAGER` root property, the
core screen's pixel/millimeter sizes, RandR per-output physical + pixel
sizes), then keeps running — rendering a 1-px hairline border and a
DPI-length bar — while the co-located `examples/f08-dpi-scaling/run.sh`
driver changes everything changeable (`xrdb -merge` Xft.dpi 96→144→192,
`xrandr --dpi 144`). Tier A result: **zero scale-related events on the
window** across all three changes; the only live signal is a
`PropertyNotify` on the **root** window — which the demo receives solely
because it opted in with `PropertyChangeMask` on the root, a convention no
standard requires of anyone. Exit 0.

**Last reviewed:** June 11, 2026

## The verdict line

```text
8022286 f08_x11 summary root_property_notifies=2 randr_notifies=1 window_events_after_startup=2 final_xft_dpi=192.0
```

(The two window events are `Expose`s — one from the initial map, one
repaint fallout from the `xrandr` call — carrying no scale information
whatsoever.)

## The startup snapshot: everything a toolkit will ever be told

```text
292 f08_x11 xft_dpi source=startup_XResourceManagerString present=0 (no RESOURCE_MANAGER property)
294 f08_x11 core_screen px=640x480 mm=163x122 dpi=99.7x99.9
344 f08_x11 randr_output name=screen connected=1 px=640x480 mm=0x0 dpi=-1.0x-1.0
```

Three sources, none authoritative:

1. **`Xft.dpi`** out of the `RESOURCE_MANAGER` property via
   `XResourceManagerString` + `XrmGetResource` — the de-facto scale
   knob desktops set (`xrdb`), but a _font_ rendering convention from Xft,
   not a windowing-protocol value. Absent on a bare server (as here, until
   the driver merges one).
2. **The core screen** — `DisplayWidth`/`DisplayWidthMM` give one
   pixels+millimeters pair per screen, fixed at connection setup (Xvfb
   defaults to a synthetic ~100 DPI: 640×480 px / 163×122 mm).
3. **RandR per-output** — `XRRGetOutputInfo.mm_width/mm_height` against the
   CRTC's pixel size is the only _per-monitor_ physical-DPI source; Xvfb
   reports **0×0 mm** (and real EDID millimeters are famously lies), so the
   computed DPI is undefined — the guard `dpi=-1.0` is itself a finding: a
   toolkit must handle 0 mm outputs.

The numbers disagree with each other on a healthy desktop too (`Xft.dpi` is
logical intent; the other two are physical claims) — toolkits pick a chain
and guess, exactly as catalogued in [platform-gotchas § X11][gotchas-x11]
(GLFW/JUCE read `Xft.dpi`, Avalonia snaps a heuristic to 1/1.25/1.5/1.75/2,
Uno mixes XRandR + `Xft.dpi`).

## The live channel that exists: root-window `PropertyNotify`

`xrdb -merge` with `Xft.dpi: 144` while the demo runs:

```text
2002411 f08_x11 root_property_notify atom=RESOURCE_MANAGER state=NewValue
2002417 f08_x11 xft_dpi source=stale_XResourceManagerString present=0 (no RESOURCE_MANAGER property)
2011174 f08_x11 xft_dpi source=fresh_XGetWindowProperty present=1 value=144 scale_vs_96=1.50
3507164 f08_x11 root_property_notify atom=RESOURCE_MANAGER state=NewValue
3507465 f08_x11 xft_dpi source=fresh_XGetWindowProperty present=1 value=192 scale_vs_96=2.00
```

Three facts in one log:

- **Apps CAN watch the change** — `RESOURCE_MANAGER` lives on the root
  window, so selecting `PropertyChangeMask` on the root delivers a
  `PropertyNotify` the moment `xrdb` writes it. This is precisely how
  live-`Xft.dpi`-applying toolkits do it (GTK's XSettings/xrdb watching falls
  in this family). It is a **convention, not a protocol**: nothing defines
  `Xft.dpi` as a scale factor, nothing requires a client to watch the root,
  and the surveyed toolkits split on whether they do — the
  [gotchas table][gotchas-x11] records mixed-DPI X11 behavior differing
  across GTK/Qt/GLFW/Avalonia/Uno precisely because each invents its own
  policy.
- **`XResourceManagerString` is a trap for live re-reads.** Per the
  [man page][xrms-man], it "returns the RESOURCE*MANAGER property from the
  server's root window of screen zero, **which was returned when the
  connection was opened** using XOpenDisplay" — the demo's
  `stale_XResourceManagerString` line still says \_absent* after the merge.
  The fresh value needs a real `XGetWindowProperty` on the root (or a new
  connection, which is what `xrdb -query` does).
- **Nothing arrives on the window itself.** Between the two notifies the
  window's event count did not move; there is no `WM_DPICHANGED`, no
  `preferred_buffer_scale`, no `viewDidChangeBackingProperties` analog. The
  demo's redraw of its DPI bar happens only because it chose to watch root.

## `xrandr --dpi` under Xvfb: RandR can signal, but says nothing about scale

```text
5118531 f08_x11 randr_screen_change px=640x480 mm=112x84 dpi=145.1x145.1
5118704 f08_x11 core_screen_after_update px=640x480 mm=112x84
```

`xrandr --dpi 144` rewrites the screen's reported physical size (the
[xrandr man page][xrandr-man]: it "sets the value reported as physical size
of the X screen as a whole"; 640 px / 145.1 DPI ⇒ 112 mm), and a client that
called `XRRSelectInput(…, RRScreenChangeNotifyMask)` gets an
**`RRScreenChangeNotify`** with the new millimeters. So RandR _can_ deliver
a runtime event — but it carries physical geometry, not logical scale, no
toolkit treats it as a rescale trigger, and two more caveats from the log:
Xlib's cached core values (`DisplayWidthMM`) only refresh after the client
itself calls `XRRUpdateConfiguration(&ev)`, and under Xvfb no mode/output
change beyond this millimeter rewrite is even possible (single 640×480 mode,
0-mm output). Mixed-DPI reality is worse: with several outputs, the
screen-level value "has no physical meaning" ([xrandr man][xrandr-man]).

## The deliverable table

What an X11 toolkit can know and when — contrasted per row with the
platforms that do have an answer (their mechanisms per the [F08 spec][f08]
and the [gotchas catalog][gotchas]):

| Question                          | At startup (X11)                                                       | At runtime (X11)                                                                                              | Never (X11)                               | Contrast                                                                                                                                           |
| --------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Global scale intent               | `Xft.dpi` via `XrmGetResource` (if the desktop set one)                | root `PropertyNotify` on `RESOURCE_MANAGER` — **opt-in convention**, fresh read via `XGetWindowProperty` only | —                                         | Wayland: `wl_output.scale`/`preferred_buffer_scale` events; Win32: system DPI + `WM_DPICHANGED`; macOS: `backingScaleFactor` + change notification |
| Per-monitor scale                 | nothing logical; RandR physical mm ⇒ a _guessed_ DPI (0 mm under Xvfb) | `RRScreenChangeNotify` (physical mm only, opt-in)                                                             | **per-monitor logical scale**             | Wayland: per-output `scale` + `wp_fractional_scale_v1` per-surface; Win32: per-monitor DPI (`GetDpiForMonitor`/PMv2); macOS: per-`NSScreen` factor |
| "Your window changed scale" event | —                                                                      | —                                                                                                             | **monitor-migration rescale events**      | Wayland: `wl_surface.enter/leave` + `preferred_scale`; Win32: `WM_DPICHANGED` with a suggested rect; macOS: `viewDidChangeBackingProperties`       |
| Buffer-size decoupling            | —                                                                      | —                                                                                                             | any logical/physical split — 1 px is 1 px | Wayland: `set_buffer_scale`/`wp_viewport`; Win32/macOS: DPI-virtualized coordinate spaces                                                          |

The startup-snapshot workaround the frameworks use follows directly: read
`Xft.dpi` once, size everything by it, and accept that a window dragged to a
differently-scaled monitor stays wrong — the canonical X11 failure mode
recorded in [the scale-factor concept][c-scale] and the
[X11 survey](./index.md#coordinates--scaling).

## Surprises

- **`XResourceManagerString` never updates** (man-page-documented, still
  surprising in the field): live re-reads must bypass Xlib's snapshot.
  Symmetrically, the core `DisplayWidthMM` is a snapshot until
  `XRRUpdateConfiguration`.
- **Properties die with the last client.** During driver development,
  `xrdb -merge` followed by `xrdb -query` from separate one-shot clients
  showed _nothing_ — a bare Xvfb resets (wiping all root properties) when
  its last client disconnects. Any long-lived client (here: the demo) keeps
  the server alive; `xrdb -retain` exists for exactly this.
- **`xrandr --dpi` did fire an `Expose`** on the demo window (the second
  `window_event type=12`) — repaint fallout, no scale payload; an app could
  not distinguish it from any other damage.
- **The absence is structural, not an Xvfb artifact:** the core protocol has
  no scale concept to signal; RandR signals physical geometry only;
  `Xft.dpi` is a root property whose change notification reaches only
  clients that watch the root. Nothing in the stack addresses a _window_.

## Findings

- **Native unit:** physical device pixels, everywhere — coordinates, sizes,
  `XNSpotLocation` ([F07](./f07-text-input.md)), `Expose` rectangles. The
  scale is first learnable only from the startup `Xft.dpi` read, and a
  window is never "created at the wrong scale then rescaled" because it is
  never rescaled at all.
- **Full event order for a scale change:** root `PropertyNotify
(RESOURCE_MANAGER)` → _(nothing else)_. For a physical-geometry change:
  `RRScreenChangeNotify` → client-side `XRRUpdateConfiguration` →
  _(nothing else)_. Feeds `event-sequences` with the shortest row of the
  four platforms.
- **The only live channel is opt-in and root-scoped** — a toolkit that wants
  live `Xft.dpi` must select `PropertyChangeMask` on the root, re-fetch the
  property itself, recompute every window's layout, and repaint — the
  entire "rescale" is application policy.
- **Per-monitor and migration scale are unanswerable** on core X11 + RandR;
  the [F08 spec][f08]'s requirement 3 (mixed-DPI drag) has no X11
  implementation, only the documented absence.

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f08-dpi-scaling
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    docs/research/window-system-integration/os-apis/x11/examples/f08-dpi-scaling/build/f08_dpi_scaling_x11
```

That CI-shaped run logs the startup snapshot against a static Xvfb and times
out, exit 0. The change choreography — two `xrdb -merge`s and the
`xrandr --dpi` — is the co-located driver `examples/f08-dpi-scaling/run.sh`
(run from the dev shell; it pulls `xrdb`/`xrandr` via `nix shell` and
re-execs itself under `xvfb-run`). No reachable display prints
`SKIP: no X11 display` and exits 0. Link dependencies: `x11`, `xrandr`
(pkg-config names, both in the dev shell).

## Sources

- **[F08 spec][f08]** — requirement 2's X11 clause ("demonstrate that there
  is no runtime mechanism … That finding IS the deliverable") and the
  startup-snapshot workaround note; the cross-platform mechanisms quoted in
  the table.
- **[`XResourceManagerString` man page][xrms-man]** — the
  connection-time-snapshot semantics (verbatim quote above).
- **[`xrandr` man page][xrandr-man]** — `--dpi` rewriting the reported
  physical screen size; the multi-monitor "no physical meaning" caveat.
- **[RandR protocol][randrproto]** — `RRScreenChangeNotify`,
  `RRSelectInput`, output physical-size fields.
- **[Concepts: the scale factor][c-scale]** and
  **[platform-gotchas § X11][gotchas-x11]** — how the surveyed toolkits
  scrape `Xft.dpi`/XSETTINGS/XRandR and where mixed-DPI breaks them.
- **[X11 survey](./index.md)** — the `Xft.dpi`/`RESOURCE_MANAGER`
  background and the "what X11 never answers" framing this demo grounds.
- Demo sources: [`app.d`](./examples/f08-dpi-scaling/app.d),
  [`instrument.d`](./examples/f08-dpi-scaling/instrument.d), the `c.c`
  ImportC shim, and the `run.sh` driver alongside them.

<!-- References -->

[f08]: ../features/f08-dpi-scaling.md
[c-scale]: ../../concepts.md#scale-factor
[gotchas]: ../../platform-gotchas.md
[gotchas-x11]: ../../platform-gotchas.md#x11
[xrms-man]: https://xorg.freedesktop.org/archive/X11R7.7/doc/man/man3/XResourceManagerString.3.xhtml
[xrandr-man]: https://www.x.org/releases/current/doc/man/man1/xrandr.1.xhtml
[randrproto]: https://gitlab.freedesktop.org/xorg/proto/randrproto/-/blob/master/randrproto.txt
