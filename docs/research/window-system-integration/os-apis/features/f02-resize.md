# F02 — Resize correctness

Interactive resize is where windowing abstractions leak first: the platform either _notifies_
you of a new size (X11, Win32, macOS) or _negotiates_ one with you (Wayland's
configure/ack/commit). This demo proves a correct, artifact-free implementation per platform
and records the exact event sequences.

## Requirements

1. Draw a continuously refreshed gradient whose geometry visibly tracks the window size
   (e.g. corner-anchored diagonal), so stretching or stale buffers are visible.
2. Survive an aggressive resize storm with no tearing, no stretching, no protocol errors, and
   no buffer-size mismatch. For Tier-A runs, drive resizes programmatically where the platform
   allows (X11 `XResizeWindow` from a second connection; Wayland: log the configure storm the
   compositor produces; Win32 `SetWindowPos` loop; macOS `setFrame:display:`).
3. **Wayland:** prove correct semantics — every `xdg_surface.configure` is logged with its
   serial; `ack_configure` is sent with the right serial _before_ the next commit; the
   committed buffer matches the configured size. An intentional violation (commit a
   wrong-sized buffer once, behind a `--violate` flag) and the resulting compositor reaction
   is part of the findings.
4. Log every size-change event (`resize size=WxH scale=S`) and every buffer (re)allocation —
   allocation strategy (per-resize realloc vs pooling) is a finding.

## Instrumentation

Mandatory set, plus `configure serial=N size=WxH` (Wayland), `wm_size`/`wm_sizing` kinds
(Win32), `live_resize_start`/`end` (macOS), `configure_notify` (X11).

## Findings to record

- The full ordered event sequence for one interactive resize, per platform (this feeds
  `event-sequences.md`).
- Who picks the final size — app, server, or negotiation; where a size request can be denied.
- Buffer lifetime rules during resize (Wayland: when may a `wl_buffer` be reused?).
- What happens on the intentional Wayland violation.

## Verification

Wayland/X11: Tier A. Win32: `A[wine]` for the programmatic storm; interactive border-drag is
Tier C. macOS: programmatic `setFrame:` is `A[ssh]`; real live-resize (mouse) is Tier C.
