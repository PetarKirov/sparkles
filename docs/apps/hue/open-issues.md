# hue — open issues

Known issues and deferred work for [hue](./index.md), with pointers to the
research or design notes that cover them.

## GUI mouse-drag over the window decoration

**Status: open (not fixed).** The raylib [`--gui`](../../specs/hue/gui.md) window —
and, identically, `apps/terminal` — does **not hold a pointer grab** during a mouse
drag. On GNOME/Wayland the apps run through **XWayland**, and its compositor routes
pointer events that land on the window decoration (or fall outside the window) to
the _decoration_ / away from the app rather than to the app. Two symptoms follow
from that one cause:

1. **A drag released on a title-bar button triggers that button.** Start a text
   selection or scrollbar drag, move the cursor over the **close / minimize /
   maximize** button, release — and the window closes / minimizes / maximizes. The
   mouse-up is delivered to the decoration, so the WM button fires.
2. **A drag that leaves the content loses its mouse-up.** Release over the title
   bar or outside the window and the app never sees the button go up, so the
   selection keeps extending. Conversely, a scrollbar drag _should_ keep working
   while the button is held **outside** the window (standard behaviour) — but the
   app receives no motion events out there, so it can't.

### Why the obvious app-level fixes don't work

Two mitigations were tried and **reverted** (they didn't fix it and one regressed
real behaviour):

- **Veto the close** (`glfwSetWindowShouldClose(handle, false)` when a close fires
  mid-drag) — structurally can't help **minimize/maximize** (those aren't
  `WindowShouldClose` events), and is defeated by the self-heal below clearing the
  drag state before the release even arrives.
- **Self-heal on cursor-exit** (end the drag when `!IsCursorOnScreen()`) — breaks
  the legitimate "drag the scrollbar / extend the selection while the button is
  held outside the window" behaviour, and prevents resume on re-entry.
- **`GLFW_CURSOR_CAPTURED`** (confine the cursor to the content on mouse-down) — is
  **ignored** on this XWayland/mutter setup, so the cursor still reaches the
  decoration.

The decisive events (the WM-button activation, the swallowed mouse-up) happen in
the **window manager**, not in app code, so no app-level state check can reliably
reconstruct them.

### The correct fix (needs validation)

Hold a real **active pointer grab** for the duration of the drag, so every pointer
event — motion and button-release, including over a decoration or outside the
window — is delivered to the app, and the cursor is confined to the content (can't
reach the WM buttons):

- **X11 / XWayland:** `XGrabPointer(confine_to = content window, owner_events,
  ButtonReleaseMask | PointerMotionMask, …)` on mouse-down and `XUngrabPointer` on
  mouse-up, via GLFW's native handles (`glfwGetX11Display` / `glfwGetX11Window`).
  This is stronger than GLFW's passive `CURSOR_CAPTURED`.
- **Native Wayland (future):** a `zwp_pointer_constraints` locked/confined pointer
  plus the compositor's implicit grab.

This is unverified against the actual compositor, and this bug class evades
in-process tests entirely — so the fix should be developed against the end-to-end
harness described in
[**End-to-end testing the windowing layer**](../../research/window-system-integration/e2e-testing.md),
which reproduces the drag-over-decoration gesture under a real headless WM before
trusting any fix.
