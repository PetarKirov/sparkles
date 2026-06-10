# F13 — CSD & decoration modes (Wayland only)

On X11, Win32, and macOS the system draws window decorations; on Wayland the **client** does,
unless the compositor volunteers server-side decorations. This is the single largest "the
platform made it the app's problem" divergence, and it is Wayland-only by design: the other
three platforms record "N/A — SSD" plus one line on their customization hooks
(`WM_NCCALCSIZE`/`DwmExtendFrameIntoClientArea`; `NSWindowStyleMask`/`titlebarAppearsTransparent`;
Motif hints/`_GTK_FRAME_EXTENTS`).

## Requirements

1. Negotiate `zxdg_decoration_manager_v1`: request server-side, log the compositor's
   `configure mode=…` answer; honor mode switches at runtime.
2. When SSD is denied (or the protocol is absent — log which), draw a **minimal CSD**:
   a title bar (solid rect + window title) that starts an interactive move via
   `xdg_toplevel.move` on pointer-down, and 8 edge/corner zones that start
   `xdg_toplevel.resize` with the right edge enum; close button sends nothing — it requests
   client shutdown (ties into F14's vetoable close).
3. Account for the geometry consequences: `xdg_surface.set_window_geometry` so the compositor
   knows frame vs content; shadows/margins may be omitted but note what real CSD adds
   (subsurfaces or margin drawing, input region beyond the visible frame).
4. Build a second variant linking **libdecor** (`libdecor_decorate`) for comparison — LOC,
   behavior under the same compositors, what it handles that the minimal CSD doesn't
   (themes, shadows, double-click-to-maximize, touch).

> [!NOTE]
> libdecor is an allowed exception to the no-helper-libraries rule for exactly this variant —
> measuring what the helper buys is the point.

## Instrumentation

`decoration mode=ssd|csd source=protocol|absent`, `csd_hit zone=…`, `move_start`,
`resize_start edge=…`.

## Findings to record

- Decoration-mode answers per compositor (headless weston, then mutter / kwin / sway via the
  manual queue — mutter famously refuses SSD).
- LOC: minimal CSD vs libdecor variant vs "free" SSD elsewhere.
- What minimal CSD cannot do (snap layouts, theme consistency, a11y) — the real cost ledger.
- The `set_window_geometry` contract and what breaks without it.

## Verification

Tier A under headless weston (protocol-level negotiation + programmatic move/resize won't
complete without a real pointer — capture the requests in the `WAYLAND_DEBUG` trace).
Interactive drag/resize behavior and per-compositor findings: Tier C (GNOME, KDE, sway
sessions).
