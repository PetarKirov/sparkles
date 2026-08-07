# `sparkles:terminal-view` — the terminal core as an embeddable component

_**Status:** proposed · **Date:** 2026-08-07 · **Scope:** the planned
`libs/terminal-view` package — `apps/terminal`'s core (libghostty screen,
per-cell renderer, input encoding, pty lifecycle) as a `runApp` component any
application can embed — and the one host extension it needs (the post-layout
paint hook). Executes [PLAN phase 2, P2.A](./PLAN.md#phase-2)._

## Why a library

"The core of `apps/terminal` should be a widget itself, embeddable in other
apps." A sub-package under `apps/` cannot be depended on, so embeddability
forces the split: the core moves to `libs/terminal-view` as
`sparkles:terminal-view`, and `apps/terminal` shrinks to a shell that parses
the CLI and calls `runApp` — the same extraction shape that produced
`sparkles:ui-tui`/`sparkles:ui-raylib` out of hue, and `sparkles:raylib-text`
out of this very app.

Two hard gates carry over from the plan, unchanged:

- **identical behavior** — every byte to the pty, every escape decoded, every
  overlay drawn as before;
- **no measured performance regression** — `apps/terminal-benchmark`'s
  `idle`/`render`/`churn` scenarios against a baseline captured from `main`
  **before** the migration branch exists.

## Requirements (`TVW`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status      | Traces to                                     |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------- |
| TVW1 | The core is a **sibling library**, `libs/terminal-view`, depending on `sparkles:ghostty`, `sparkles:raylib-text`, `sparkles:ui`, `sparkles:input` and `sparkles:base` — never on an `apps/` tree. `apps/terminal` becomes a thin shell (CLI parse → `runApp`), and its excluded-surface number falls to the [phase-2 target](./PLAN.md#excluded-surface-targets-tst4).                                                                                               | not started | `libs/terminal-view/dub.sdl`                  |
| TVW2 | The core is a **component** ([`HST10`](./feature-requirements.md#the-host-contract-hst)): `view` emits a **keyed** pane widget so layout sizes and positions it like any other node, and `handle` consumes `sparkles:input` events. The per-cell renderer is untouched — it paints into the laid-out rect through the host's canvas (`HST3`), never through the display list ([UIAPP-O5](./open-issues.md#uiapp-o5)).                                                | not started | `terminal_view.d`                             |
| TVW3 | The host grows a **post-layout paint phase**: an optional hook that runs inside the arm's frame bracket (after the display list paints, before the frame ends), receiving the canvas and the laid-out keyed rects. Detected by introspection on the component (a `paint` member), wired as an `alias` with a no-op default — a component without one costs nothing. This is the only host change the extraction needs; the widget vocabulary stays closed (`PRN12`). | not started | `run_app.d`; `gui_loop.d`                     |
| TVW4 | **Byte parity is the oracle, not a review claim.** The `KeyStroke` seam and its fixture tests pin what each keystroke writes to the pty; the migration's `sparkles:input` → `KeyStroke` mapping (`KeyEvent.action`/`unshifted`/`text`/`mods` exist for exactly this) is tested against the **same fixtures**, so the swap of input source cannot silently change an encoding. Mouse encoding gets the same seam treatment when its source swaps.                     | not started | `apps/terminal/src/input.d` `encodeKeyStroke` |
| TVW5 | Every behavior of today's loop survives, expressed through the host contract: dirty-frame skipping becomes `skipFrame` (`HST6` was specified **from** this behavior), font-resize hotkeys re-request cell metrics, focus reporting (DECSET 1004), exit behavior, selection/hover/scrollbar overlays, kitty images, and the OSC color-query replies all remain in the component.                                                                                      | not started | `terminal_view.d`                             |
| TVW6 | **The pty stays a per-frame non-blocking drain** in the first migration: read-until-`EAGAIN` before input handling, exactly today's ordering, so the perf gate measures the extraction alone. Moving pty reads onto event-horizon fibers is a separate, separately-measured step afterwards — never folded into the migration commit.                                                                                                                                | not started | `terminal_view.d`                             |
| TVW7 | **Embedding is proven by a second consumer**: a demo (or hue pane) that lays the terminal component out inside its own widget tree — sized by layout, painted through the hook, receiving events routed by the embedding app. Until that exists, "embeddable" is a claim, not a property.                                                                                                                                                                            | not started | `libs/terminal-view/examples/`                |

> [!IMPORTANT]
> `TVW3` exists because of the frame bracket: on the GPU arm, canvas draw calls
> are only valid between `beginFrame`/`endFrame`, which the **loop** owns — a
> component cannot paint cells from `view` (too early) and has nowhere later.
> The hook is the one honest place. Its exact signature (how the laid-out
> rects and the tree reach it, and their lifetimes) is decided in the
> implementing PR against the real consumer — the pieces exist
> (`Widget.key`, `keyedRects(tree, frames)`), the composition is the open part.

## Order of work

1. ~~The `KeyStroke` byte oracle~~ — **done** (behavior-preserving extraction
   in `apps/terminal/src/input.d`, four fixture suites).
2. The benchmark baseline from `main` — `dub run :terminal-benchmark` on a
   quiet machine, all scenarios, results recorded in the PR (`TVW6`'s
   comparison denominator). Interactive: the harness opens real GL windows.
3. The paint hook (`TVW3`) in `sparkles:ui-app`, with a recording-target test
   (the recorder's canvas captures what the hook painted).
4. The extraction (`TVW1`/`TVW2`/`TVW5`/`TVW6`): move the core, map the input
   events, keep the renderer byte-identical; `apps/terminal` becomes the shell.
5. The benchmark comparison + the embedding proof (`TVW7`).

## Non-goals

| Not this package's job                          | Where it belongs                              |
| ----------------------------------------------- | --------------------------------------------- |
| A TUI arm (terminal-in-terminal)                | nowhere yet — the renderer is raylib-specific |
| Event-loop restructuring (pty on fibers)        | a later step, measured on its own (`TVW6`)    |
| Backend choice, window/font CLI, the frame loop | `sparkles:ui-app`                             |
| VT interpretation, escape encoding              | `sparkles:ghostty` (libghostty-vt)            |
