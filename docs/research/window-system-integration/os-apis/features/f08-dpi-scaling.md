# F08 — DPI / runtime rescale

Logical vs physical coordinates, and what happens when the scale changes under a live window.
The four platforms give four different answers — including X11's "no runtime answer at all",
which is a deliverable here, not a gap.

## Requirements

1. Continuously display (render into the frame) and log: logical size, physical (pixel) size,
   and the current scale factor; crisp 1-physical-px hairlines at the window edge make
   scaling artifacts visible.
2. Handle a runtime scale change and log the full event sequence:
   - **Wayland:** implement BOTH paths and switch on advertised globals:
     `wp_fractional_scale_v1` (preferred-scale in 1/120ths) + `wp_viewport` for buffer-size
     decoupling, AND the integer `wl_surface.set_buffer_scale` fallback driven by
     `wl_surface.preferred_buffer_scale`/`wl_output.scale`. Log which path is active.
   - **Win32:** Per-Monitor-v2 awareness (manifest or
     `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`); on
     `WM_DPICHANGED`, honor the suggested rect (`lParam`) and log old/new DPI + rect.
   - **macOS:** observe `backingScaleFactor` via
     `viewDidChangeBackingProperties`/`NSWindowDidChangeBackingPropertiesNotification`;
     log `convertRectToBacking:` round-trips.
   - **X11:** demonstrate that there is **no runtime mechanism**: read `Xft.dpi` from
     resources and `RANDR` physical dimensions at startup, change the system scale, show the
     running window receives nothing. That finding IS the deliverable.
3. Survive a monitor-to-monitor drag between different scales without blurriness or wrong-size
   buffers (Tier C where it needs real monitors; headless weston can be configured with two
   outputs at different scales — do that for Wayland).

## Instrumentation

`scale_changed scale=… path=…`, `dpi_changed old=… new=… suggested=WxH`, plus
`resize size=WxH scale=S` everywhere sizes change.

## Findings to record

- The native coordinate unit per platform and where the scale is first learnable (the
  "created at wrong scale then rescaled" problem — log whether it happens).
- The full event order for a scale change (feeds `event-sequences.md`).
- Fractional-scale buffer-size math on Wayland (rounding rules) and what `viewport` decouples.
- The X11 absence, documented with the startup-snapshot workaround frameworks use.

## Verification

Wayland: Tier A (headless weston with two outputs, scales 1 and 1.5/2). X11: Tier A (the
absence-proof). Win32: `A[wine]` for the `WM_DPICHANGED` plumbing (Wine emulates per-monitor
DPI imperfectly — label it), real mixed-DPI drag Tier C. macOS: scale observation `A[ssh]`,
monitor drag Tier C.
