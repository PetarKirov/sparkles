# F15 — Popup with grab

Context menus are the acid test of a platform's secondary-surface model: positioned relative
to a parent, grabbing input, dismissed by clicking _outside_ — which requires events the
popup doesn't naturally receive.

## Requirements

1. Right-click opens a menu-like popup (solid panel, 3 fake items, hover highlight) at the
   pointer; clicking an item logs it; clicking **outside** dismisses; Esc dismisses.
   - Wayland: `xdg_popup` with an `xdg_positioner` (anchor rect at the click, gravity
     bottom-right, `constraint_adjustment` slide+flip) + `xdg_popup.grab` with the click
     serial; handle `popup_done`.
   - X11: an override-redirect window + `XGrabPointer`/`XGrabKeyboard`; outside-click
     detection via the grab; document the focus model mess (no WM involvement).
   - Win32: a `WS_POPUP` window + `SetCapture` (or the `TrackPopupMenu`-style internal loop —
     implement the capture variant; note `TrackPopupMenu` as the system escape hatch and its
     modal-loop implications for F03).
   - macOS: a borderless `NSWindow` (`NSWindowStyleMaskBorderless`) + a local+global event
     monitor for outside clicks (do this variant; note `NSMenu` as the escape hatch and what
     it does for free).
2. Edge correctness: open the popup near the bottom-right screen/output edge and log the
   final placement — who repositioned it (compositor via positioner vs app math)?
3. Nested popup (submenu) one level deep — Wayland requires the parent-popup chain; others
   re-parent or stack; log the stacking order events.
4. Log dismissal cause (`popup_done`, grab-break, capture-loss, monitor event) — the
   asymmetry of _who decides_ dismissal is the finding.

## Instrumentation

`popup_open anchor=… gravity=…`, `popup_placed rect=…`, `popup_dismiss cause=…`,
`grab state=…`.

## Findings to record

- Placement ownership: declarative constraints (Wayland) vs app-computed geometry (others) —
  what a framework positioner API must express.
- Grab semantics per platform and what breaks them (focus loss, another popup, screen edge).
- Whether the popup may exceed output bounds (Wayland: no; others: measured).
- The escape hatches (`NSMenu`, `TrackPopupMenu`) and what using them costs in control.

## Verification

Wayland: Tier A under headless weston (positioner math + grab handshake visible in the
trace; synthetic pointer via weston test input where available). X11: Tier A under Xvfb +
`xdotool` clicks. Win32 `A[wine]`, macOS `A[ssh]` for open/place/dismiss-by-Esc; real
outside-click feel and multi-monitor edges: Tier C.
