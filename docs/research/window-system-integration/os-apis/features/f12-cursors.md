# F12 — Cursors

System-themed cursors, custom cursors, and who composites them. Wayland made the client
responsible for its cursor (with a newer protocol to hand the job back); everywhere else it's
one call.

## Requirements

1. Hover zones that switch the cursor among: default arrow, text I-beam, hand/link, and all
   eight resize-edge cursors; log every `cursor_set name=…`.
   - Wayland: implement **both** mechanisms and select at runtime: `cursor-shape-v1`
     (`wp_cursor_shape_device_v1.set_shape`) when the compositor offers it, else classic
     `wl_pointer.set_cursor` with a `wl_surface` rendered from the cursor theme via
     `libwayland-cursor` (theme lookup, size × scale, animated frames). Log which path ran.
   - X11: `XCreateFontCursor`/`libXcursor` themed lookup (`XcursorLibraryLoadCursor`).
   - Win32: `LoadCursor`/`SetCursor` on `WM_SETCURSOR` (log the `WM_SETCURSOR` storm).
   - macOS: `NSCursor` standard cursors + `cursorUpdate:`/tracking areas.
2. One custom pixmap cursor (e.g. 24×24 bullseye) with a non-trivial hotspot, from raw ARGB:
   `wl_shm` surface / `XcursorImageLoadCursor` / `CreateIcon`+`SetCursor` /
   `NSCursor initWithImage:hotSpot:`.
3. Set the cursor _correctly under HiDPI_ (scale-aware size selection) — log chosen size.
4. Cursor visibility during F10's lock mode must not leak (no flicker on re-entry).

## Instrumentation

`cursor_set name=… path=shape|theme|font|… size=…`, `wm_setcursor` events (Win32),
`cursor_update` (macOS).

## Findings to record

- Who composites the cursor (server vs client) and what that costs the client on Wayland
  (theme loading, animation timers).
- The standard-shape vocabulary per platform and the gaps between them.
- HiDPI cursor-size selection rules.
- Whether `cursor-shape-v1` was offered by each tested compositor (headless weston, then
  mutter/kwin/sway via the manual queue).

## Verification

Wayland/X11: Tier A (cursor _requests_ are observable in the protocol trace; actual pixels
need eyes — note the split). Win32 `A[wine]`, macOS `A[ssh]`; a quick visual confirmation
pass rides along with other Tier C items.
