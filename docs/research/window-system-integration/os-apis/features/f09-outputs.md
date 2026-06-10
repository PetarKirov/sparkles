# F09 — Output enumeration & hotplug

What a window can know about the displays it lives on, and whether it finds out when that
changes at runtime.

## Requirements

1. At startup, enumerate all outputs and log per output: name/identifier, position, mode
   (resolution + refresh), scale, and physical size where available:
   - Wayland: `wl_output` (+ `xdg_output` for logical geometry where offered).
   - X11: RandR (`XRRGetMonitors`/`XRRGetScreenResources`).
   - Win32: `EnumDisplayMonitors` + `GetMonitorInfo` + `GetDpiForMonitor`.
   - macOS: `NSScreen.screens` (+ `CGDisplay` IDs).
2. Log which output(s) the window currently occupies and track changes:
   - Wayland: `wl_surface.enter`/`leave` (the only platform that tells the surface directly).
   - X11/Win32/macOS: derive from window geometry vs monitor rects; log the derivation.
3. Handle hotplug at runtime: an output appearing/disappearing while the window runs must be
   logged (`output_added`/`output_removed`) without crash or stale state — including the case
   where the window's current output vanishes.

## Instrumentation

`output id=… geom=… scale=… refresh=…` per enumeration; `output_added`/`output_removed`;
`surface_output enter|leave id=…`.

## Findings to record

- The information model per platform (what's logical vs physical, what's missing — e.g.
  exact refresh on Wayland before `wl_output.mode`).
- Hotplug event order, and what happens to a window whose output disappears.
- Whether enumeration requires a window/connection or is global.

## Verification

Wayland: Tier A — headless weston can be started with multiple outputs; output hot-add is
scriptable with the headless backend's `--output-count` is static, so use `weston` +
`wlr-randr`-equivalent where possible, else record hot-add as Tier C on a real session.
X11: Tier A for enumeration under Xvfb (single output; note the limitation), RandR
mode-change events scriptable via `xrandr` on Xephyr if available. Win32/macOS: enumeration
`A[wine]`/`A[ssh]`; physical hotplug Tier C.
