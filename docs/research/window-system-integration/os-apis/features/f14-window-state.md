# F14 — Window state & vetoable close

Minimize/maximize/fullscreen, focus, and the close request — the lifecycle edges. The exact
**event sequences** for each transition are the deliverable; they feed `event-sequences.md`
directly.

## Requirements

1. Keyboard shortcuts trigger: maximize toggle, minimize, fullscreen toggle, restore. Log the
   request AND every resulting event until the state settles:
   - Wayland: `xdg_toplevel.set_maximized`/`set_fullscreen`/`set_minimized` and the resulting
     `configure` states array (note: minimized is fire-and-forget — no state echo; that
     asymmetry is a finding).
   - X11: `_NET_WM_STATE` ClientMessages + `WM_CHANGE_STATE`; track `_NET_WM_STATE` property
     notifies and `ConfigureNotify`.
   - Win32: `ShowWindow(SW_MAXIMIZE/SW_MINIMIZE)`, `WM_SIZE` wParams,
     `WM_WINDOWPOSCHANGING/CHANGED` order; fullscreen via the borderless-resize idiom
     (document it — Win32 has no fullscreen state).
   - macOS: `zoom:`, `miniaturize:`, `toggleFullScreen:` and the
     `NSWindowDelegate`/notification sequence (fullscreen is a Space transition — log its
     duration).
2. Log focus/activation events (`focus state=in|out reason=…`) including which surface object
   carries focus (Wayland: `wl_keyboard.enter` vs `xdg_toplevel` activated state).
3. **Vetoable close:** the demo has a "dirty" flag (toggled by a key). On close request
   (`xdg_toplevel.close` / `WM_DELETE_WINDOW` ClientMessage / `WM_CLOSE` /
   `windowShouldClose:`), if dirty: refuse once, log `close_requested veto=1`, clear the
   flag; second request closes. Record per platform whether veto is a first-class concept or
   an app-side convention (Wayland/X11: the request is purely advisory; Win32/macOS: explicit
   return-value contracts).
4. Programmatic self-close paths must tear down cleanly (no protocol error, exit 0).

## Instrumentation

`state_request kind=…`, `state_changed states=[…]`, `focus state=… `,
`close_requested veto=0|1`, plus configure/resize events.

## Findings to record

- One ordered sequence diagram (as a log excerpt) per transition per platform.
- Which transitions echo back a state and which are fire-and-forget.
- Who owns "fullscreen" (a real state vs a geometry idiom).
- The veto contract per platform.

## Verification

Wayland/X11: Tier A (headless weston honors state requests; Xvfb + a lightweight WM — run
one, e.g. via `nix shell nixpkgs#icewm` — since bare Xvfb has no WM to answer `_NET_WM_STATE`;
the no-WM behavior is itself worth one log). Win32: `A[wine]`. macOS: `A[ssh]` (fullscreen
Space animation timing needs a real session — Tier C note).
