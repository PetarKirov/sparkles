# `sparkles:terminal-view` — the terminal core as an embeddable component

_**Status:** shipped (TVW7 in progress) · **Date:** 2026-08-07 · **Scope:** the planned
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

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Traces to                                   |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| TVW1 | The core is a **sibling library**, `libs/terminal-view`, depending on `sparkles:ghostty`, `sparkles:raylib-text`, `sparkles:ui`, `sparkles:input` and `sparkles:base` — never on an `apps/` tree. `apps/terminal` becomes a thin shell (CLI parse → `runApp`), and its excluded-surface number falls to the [phase-2 target](./PLAN.md#excluded-surface-targets-tst4).                                                                                               | full — sparkles:terminal-view (sourceLibrary, per the ImportC pkg-config rule); apps/terminal is a 114-line shell with the tested cli.d defaults guard                                                                                                                                                                                                                                                                                                                                                                      | `libs/terminal-view/dub.sdl`                |
| TVW2 | The core is a **component** ([`HST10`](./feature-requirements.md#the-host-contract-hst)): `view` emits a **keyed** pane widget so layout sizes and positions it like any other node, and `handle` consumes `sparkles:input` events. The per-cell renderer is untouched — it paints into the laid-out rect through the host's canvas (`HST3`), never through the display list ([UIAPP-O5](./open-issues.md#uiapp-o5)).                                                | full — `TerminalView` (component.d): lazy `open` against the session fonts, `frame`/`view`, oracle-driven `handle`, `paint`/`paintPane` (mouse still polled by design)                                                                                                                                                                                                                                                                                                                                                      | `terminal_view.d`                           |
| TVW3 | The host grows a **post-layout paint phase**: an optional hook that runs inside the arm's frame bracket (after the display list paints, before the frame ends), receiving the canvas and the laid-out keyed rects. Detected by introspection on the component (a `paint` member), wired as an `alias` with a no-op default — a component without one costs nothing. This is the only host change the extraction needs; the widget vocabulary stays closed (`PRN12`). | full — [`HST13`](./feature-requirements.md#the-host-contract-hst): `paint(ref host, in WidgetTree, in Frame[])`; both live hosts expose `canvas`                                                                                                                                                                                                                                                                                                                                                                            | `run_app.d`; `gui_loop.d`                   |
| TVW4 | **Byte parity is the oracle, not a review claim.** The `KeyStroke` seam and its fixture tests pin what each keystroke writes to the pty; the migration's `sparkles:input` → `KeyStroke` mapping (`KeyEvent.action`/`unshifted`/`text`/`mods` exist for exactly this) is tested against the **same fixtures**, so the swap of input source cannot silently change an encoding. Mouse encoding gets the same seam treatment when its source swaps.                     | full — event_map.d: encodeKeyEvent through the same encodeKeyStroke path, fixtures re-drive the oracle bytes as events (incl. Ctrl+letter, releases, kitty CSI-u); mouse waits for its conversion                                                                                                                                                                                                                                                                                                                           | `input.d` `encodeKeyStroke`; `event_map.d`  |
| TVW5 | Every behavior of today's loop survives, expressed through the host contract: dirty-frame skipping becomes `skipFrame` (`HST6` was specified **from** this behavior), font-resize hotkeys re-request cell metrics, focus reporting (DECSET 1004), exit behavior, selection/hover/scrollbar overlays, kitty images, and the OSC color-query replies all remain in the component.                                                                                      | full — dirty-skip as `skipFrame`, drain-before-encode via the lazy per-frame drain, exit policies, DECSET 1004, kitty, OSC replies, bench + screenshot hooks all in the component                                                                                                                                                                                                                                                                                                                                           | `terminal_view.d`                           |
| TVW6 | **The pty stays a per-frame non-blocking drain** in the first migration: read-until-`EAGAIN` before input handling, exactly today's ordering, so the perf gate measures the extraction alone. Moving pty reads onto event-horizon fibers is a separate, separately-measured step afterwards — never folded into the migration commit.                                                                                                                                | full — per-frame read-until-EAGAIN preserved; gate run 2026-08-08: idle 99.7→0.3%, render 109.5→32.2%, churn 99.9→98.0% (no regression; ring parking replaces busy-wait pacing)                                                                                                                                                                                                                                                                                                                                             | `terminal_view.d`                           |
| TVW7 | **Embedding is proven by a second consumer**: a demo (or hue pane) that lays the terminal component out inside its own widget tree — sized by layout, painted through the hook, receiving events routed by the embedding app. Until that exists, "embeddable" is a claim, not a property.                                                                                                                                                                            | full — `apps/ui-gallery`'s Terminal page: VSCode-style tabs over heap-pinned instances, keyed pane sized by layout, painted in the draw phase (`paintPane` on the GPU arm; `cell_paint.d` through `isCanvas` on the terminal arm — terminal-in-terminal), keys routed by a capture mode whose only reserved binding is the release chord. The host-free surface it drove out: `pump`/`decideRedraw`/`sendKey`/`notifyFocus`/`resize`/`openCore` + title capture. Embedded mouse routing waits on the mouse-event conversion | `apps/ui-gallery/src/pages/terminal_page.d` |

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
5. ~~The benchmark comparison + the embedding proof (`TVW7`)~~ — **done**
   (the gate numbers in `TVW6`'s row; the proof is the gallery's Terminal
   page, on both arms).

## Non-goals

| Not this package's job                          | Where it belongs                                                                                                                                                                                                                   |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A **whole-surface** TUI terminal application    | still nowhere — but the _embedded_ cell path exists: `cell_paint.d` renders the VT screen through any `isCanvas` target (no fonts, no kitty, base codepoint per cell), which is how the gallery shows a terminal inside a terminal |
| Event-loop restructuring (pty on fibers)        | a later step, measured on its own (`TVW6`)                                                                                                                                                                                         |
| Backend choice, window/font CLI, the frame loop | `sparkles:ui-app`                                                                                                                                                                                                                  |
| VT interpretation, escape encoding              | `sparkles:ghostty` (libghostty-vt)                                                                                                                                                                                                 |
