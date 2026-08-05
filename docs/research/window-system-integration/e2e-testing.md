# End-to-end testing the windowing layer

A design note on how to catch **input-behaviour** bugs in the raylib GUI apps
(`hue --gui`, `apps/terminal`) — the class of bug that only appears once a real
window manager and real pointer-event routing are in the loop, and is therefore
structurally invisible to in-process unit tests.

It is written against a concrete case study (mouse-drag-over-decoration bugs,
below), motivates why the usual test layers miss them, and specifies an automated
end-to-end harness that would catch them. Building the harness is **deferred** (see
[status](#status)). See also the windowing [concepts](./concepts.md) and the
[platform comparison](./comparison.md).

## Case study: drag bugs that escaped every test

On GNOME/Wayland the raylib apps run through **XWayland** (GLFW's X11 backend —
a GLFW window under mutter only gets a title bar + close/minimize/maximize buttons
via X11; native Wayland under GNOME is decorationless). The apps hold **no pointer
grab** during a drag, and XWayland/mutter routes a pointer event that lands on the
decoration (or off the window) to the _decoration_, not the app. That single cause
produces several symptoms:

1. **A drag released on a title-bar button triggers it** — releasing a text
   selection or scrollbar drag over **close / minimize / maximize** fires that WM
   button (the window closes / minimizes / maximizes).
2. **A drag that leaves the content loses its mouse-up** — the app never sees the
   release, so a selection keeps extending; and a scrollbar drag, which _should_
   keep working while the button is held **outside** the window, can't, because no
   motion events arrive out there.

## Why in-process tests can't catch this

The decisive events happen **outside** the application:

- A WM-button activation (close/minimize/maximize) is performed by the **window
  manager**, not app code. `WindowShouldClose()` (only for close) is observed
  _after the fact_; minimize/maximize aren't even visible as app events.
- The lost mouse-up is a compositor **routing** decision. No app-visible event is
  generated to assert on — and worse, GLFW's button state can stay stuck "down".

A pure logic test — inject a scripted `down → move → up` at the raylib-call seam,
assert the selection range / `shouldClose` — validates the _app-side contract_ but
**cannot** reproduce any of these: the bug lives in event delivery the mock
supplies by fiat. This was confirmed the hard way: app-level mitigations (veto a
mid-drag close; end the drag when the cursor leaves the content) both passed
review and built green, yet the first can't touch minimize/maximize and the second
broke legitimate outside-window scrollbar dragging — neither would have been caught
without a real WM in the loop. Catching this class requires a test with (a) a real
decorating window manager and (b) synthetic pointer events routed by that WM.

## The approach: real headless WM + synthetic input + observe

A layered strategy; only the outer layer catches this class.

### Layer 1 — input-logic seam (fast, in-process, deterministic)

Put an _input provider_ behind a small interface (`isMouseButtonPressed`,
`getMousePosition`, `isCursorOnScreen`, `windowShouldClose`, …): the real impl
calls raylib; the test impl replays a scripted event list. Unit-test the
frame-handler's state transitions and _intents_. `@nogc`-clean, matches the repo's
design-by-introspection style, locks the app-side contract — but does **not**
exercise WM routing.

### Layer 2 — windowing E2E (slow, real, gated) — the one that catches it

A D harness (per the repo "scripts in D" rule) that:

1. Stands up a **headless display with real decorations** — the load-bearing part:
   - **X11 / XWayland (the apps' actual path today):** `Xvfb :N` + a decorating WM
     (`metacity` / `openbox`), or a nested `mutter --x11` for mutter-faithful
     routing. Launch `hue --gui` / `apps/terminal` on `:N`.
   - **Native Wayland (future):** a headless compositor (`labwc` / `weston
--backend=headless` / `sway --headless`) plus the `wlr-virtual-pointer`
     protocol (or `ydotool` / `wtype` via `/dev/uinput`).
2. Reads the window's frame geometry (`xdotool` / `xwininfo`; `swaymsg -t
get_tree`) and locates each title-bar button.
3. Drives the exact failing gestures via **OS-level** input (`xdotool` XTEST on
   X11; `ydotool` / `wtype` on Wayland — no app hook needed): `mousedown` in
   content → `mousemove` onto the close/minimize/maximize button (and off the
   window entirely) → `mouseup` → `mousemove` back.
4. Asserts the observable outcome: the window is still open / not minimized /
   not maximized; the selection ended (or, for the scrollbar, _continued_ while
   the button was held outside — see [observability](#observability-the-app-must-expose-state)).
   Inverse guards: a _real_ click on each button still works; a normal in-content
   drag still selects.
5. `skipTest("no headless WM")` when the display / WM / input tool is absent
   (mirrors the repo's `skipTest` idiom).

## Observability: the app must expose state

"Window alive / minimized / maximized" is observable via the WM. "Did the selection
end / did the scrollbar keep dragging" is not, from outside. Add an env-gated debug
sink — e.g. `HUE_GUI_DEBUG_STATE=/path` — that dumps `selecting`, the selection
byte range, scroll offset, and window state each frame. That turns behavioural
assertions into file reads instead of pixel-diffing. The GUI already has golden
**screenshot** capture (`TakeScreenshot`) as a fallback for "does it _look_ right".

## Fidelity and CI

- **The bug is WM-specific.** `openbox` may honour the X11 implicit grab and _not_
  reproduce the mutter/XWayland leak. The harness must **first prove it reproduces
  the bug** before it is trusted as a regression gate; if a light WM does not, use
  nested `mutter`. "Confirm the test has teeth" is non-negotiable for this class.
- **Matrix on the routing layer.** X11 vs XWayland vs native-Wayland route pointer
  events differently; the same code passes on one and fails on another.
- **Isolation.** Run in a throwaway display, never the developer's live session —
  synthetic clicks and cursor warps are disruptive.
- **Packaging.** A dedicated nix flake check / CI job provides `Xvfb` + a WM +
  `xdotool` (all in nixpkgs), gated and separate from the fast tests.

## The essential principle

> To catch "a drag that ends on a decoration fires a WM button / loses the
> mouse-up", the test must contain a real window manager drawing decorations **and**
> synthetic pointer events routed by that WM. Everything short of that — mocked
> raylib, in-process state assertions — structurally cannot see it, because the
> decisive event is produced outside the application.

## Status

- **Harness: deferred.** This note is the design; no harness is built yet.
- **Fix: open.** The proper fix is a real **active pointer grab** for the duration
  of the drag (X11: `XGrabPointer(confine_to = content, owner_events,
ButtonRelease | PointerMotion)` via GLFW's native handles; native-Wayland:
  `zwp_pointer_constraints`), so every event reaches the app and the cursor can't
  reach the decorations. It is unverified against the actual compositor — exactly
  what the Layer-2 harness is for. Tracked in
  [`sparkles:ui` open issue `UI-O3`](../../specs/ui/open-issues.md#ui-o3).
