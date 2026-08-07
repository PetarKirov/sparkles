# `sparkles:ui-app` — Overview

_**Status:** phase 1 shipped, phase 2 (app migration) in progress · **Date:**
2026-08-07 · **Scope:** the `libs/ui-app` package: the **application host** that
owns backend selection, the shared window/font CLI, and the frame/event loop, so
an application never names a canvas._

`sparkles:ui` is backend-free by construction ([`PKG1`](../ui/feature-requirements.md),
[`TGT6`](../ui/backends.md)), and the concrete canvases live in sibling packages.
Nothing owns the layer **above** them: opening the right backend, resolving fonts,
sizing a window, draining input, and driving a frame. Today `apps/hue` and
`apps/terminal` each implement that layer privately, in mutually incompatible ways.

`sparkles:ui-app` is that layer, as one more sibling package — not a change to the
toolkit.

## Why

Three concrete duplications, each currently a source of drift:

| Today                                                                                           | Consequence                                                                                           |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| hue and terminal each declare `--font`, `--font-size`, `--window-width/height`, `--font-dir`, … | different spellings, different defaults (13 pt vs 14 pt), different resolution order for the same job |
| hue owns the backend decision (`--gui`/`--no-gui`, `$DISPLAY`, tty, Android); terminal has none | the Android "the surface **is** the app" rule lives in one app's private comment                      |
| Each app hand-writes a frame loop against `Window`/`RaylibEvents` or `TerminalSession`          | two loops with divergent resize, quit, pointer-shape and repaint policy; neither is unit-testable     |

The last row is the expensive one. `apps/hue/src/gui.d` (2536 lines),
`apps/hue/src/app.d` (934) and `apps/terminal/src/app.d` (1340) are all excluded
from their unittest builds, so **4810 lines** of application behavior is verified
only by manual passes and the screenshot oracle — not because the logic is
untestable, but because it sits next to a window.

## What it owns

| Concern              | Module                     | Requirements                                               |
| -------------------- | -------------------------- | ---------------------------------------------------------- |
| Backend selection    | `backend.d`                | [`BKD`](./feature-requirements.md#backend-selection-bkd)   |
| Window/font CLI      | `gui_options.d`            | [`CLI`](./feature-requirements.md#window-and-font-cli-cli) |
| Window/font setup    | `gui_setup.d`              | [`CLI`](./feature-requirements.md#window-and-font-cli-cli) |
| Frame/event loop     | `run.d`, `host.d`          | [`HST`](./feature-requirements.md#the-host-contract-hst)   |
| Component entry      | `run_app.d`                | [`HST`](./feature-requirements.md#the-host-contract-hst)   |
| Backend arms         | `tui_loop.d`, `gui_loop.d` | [`APP`](./feature-requirements.md#architecture-app)        |
| Headless test target | `record.d`                 | [`TST`](./feature-requirements.md#testability-tst)         |

## Render targets

The host instantiates one `Host` per target. All three satisfy the same shape, so
an application's `present`/`handle` pair is written once:

| Target        | Canvas            | Input                | Notes                                                               |
| ------------- | ----------------- | -------------------- | ------------------------------------------------------------------- |
| **GUI**       | `RaylibCanvas`    | `RaylibEvents.poll`  | polls once per frame; `Host.skipFrame()` suppresses the buffer swap |
| **TUI**       | `GridCanvas`      | `TerminalSession`    | blocks on input unless a frame was requested or an idle tick is set |
| **recording** | `RecordingCanvas` | a scripted `Event[]` | no window, no tty — the seam that makes an app's loop testable      |

The recording target is the loop-level analogue of the toolkit's
`RecordingCanvas` ([`TGT10`](../ui/backends.md) asks that a widget tree be
renderable through every target in a test; this extends that to a whole session).

## The three render levels

An application defers as much of the pipeline as it wants, mirroring the toolkit's
own three levels ([`UIA2`](../ui/feature-requirements.md)):

| Level         | Call                      | The host does                                         | Consumer                        |
| ------------- | ------------------------- | ----------------------------------------------------- | ------------------------------- |
| widgets       | `host.paint(tree, theme)` | `layout` → `buildDisplayList` → `paint(canvas)`       | hue's chrome, diagram's menus   |
| display list  | `host.ops() ~= op`        | replays the host-owned buffer into the canvas         | diagram's board                 |
| direct canvas | `host.canvas`             | nothing — the app drives `isCanvas` primitives itself | terminal's per-cell VT renderer |

The third level is why `apps/terminal` can migrate at all: its renderer is a
per-cell `drawSolid`/`drawBox`/`drawGrapheme` walk over a libghostty screen, and
routing it through a `DrawOp` stream would be a rewrite of a benchmarked hot path.

## Package graph

```
sparkles:ui-app  → ui, input, core-cli        config "tui":  + ui-tui
                                              config "gui":  + ui-raylib, version UiAppGui
                                              config "full": + both
```

`sparkles:ui` gains no dependency and no knowledge of the host — the direction of
[`PKG1`](../ui/feature-requirements.md) is preserved.

## Documentation map

| Page                                              | What it covers                                                                                                                         |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | what the host is · why it exists · targets · render levels · the status/ID scheme                                                      |
| [Feature requirements](./feature-requirements.md) | the requirement tree: architecture (`APP`), backend selection (`BKD`), the CLI (`CLI`), the host contract (`HST`), testability (`TST`) |
| [Delivery plan](./PLAN.md)                        | execution: the four phases, their dependencies, the acceptance gates, and what each phase makes testable                               |
| [Open issues](./open-issues.md)                   | deferred decisions and the constraints behind them                                                                                     |

## Status scheme

Identical to the [`sparkles:ui` scheme](../ui/index.md#status-scheme) —
**not started** · **researched** · **partial** · **full (`<sha>`)** · **decided** —
so the trees cross-reference without translation. Phase 1's rows are **full**;
the remaining open rows (`TST3`, `TST4`) belong to the phase-2 migrations.

## ID scheme

`<AREA><n>`, unique within a document:

| Area  | Meaning                                                                  |
| ----- | ------------------------------------------------------------------------ |
| `APP` | architecture and package graph                                           |
| `BKD` | backend selection — the flags, probes and platform facts behind the pick |
| `CLI` | the shared window/font command-line vocabulary and setup order           |
| `HST` | the host contract — the loop, the frame, and the platform errands        |
| `TST` | testability: the recording target and the coverage obligations           |

## Traceability

Planned files, each owned by at least one requirement. The table is the code →
requirement direction; the "Traces to" column of each row is the reverse.

| Planned source file                              | Areas                  |
| ------------------------------------------------ | ---------------------- |
| `libs/ui-app/src/sparkles/ui_app/backend.d`      | `BKD1`–`BKD5`          |
| `libs/ui-app/src/sparkles/ui_app/gui_options.d`  | `CLI1`–`CLI3`          |
| `libs/ui-app/src/sparkles/ui_app/gui_setup.d`    | `CLI4`–`CLI6`          |
| `libs/ui-app/src/sparkles/ui_app/host.d`         | `HST1`–`HST8`          |
| `libs/ui-app/src/sparkles/ui_app/run.d`          | `HST1`, `HST9`, `BKD5` |
| `libs/ui-app/src/sparkles/ui_app/run_app.d`      | `HST10`–`HST12`        |
| `libs/ui-app/src/sparkles/ui_app/display.d`      | `BKD3`                 |
| `libs/ui-app/src/sparkles/ui_app/event_source.d` | `HST9`                 |
| `libs/ui-app/src/sparkles/ui_app/tui_loop.d`     | `APP4`, `HST6`, `HST7` |
| `libs/ui-app/src/sparkles/ui_app/gui_loop.d`     | `APP4`, `HST6`, `HST7` |
| `libs/ui-app/src/sparkles/ui_app/record.d`       | `TST1`–`TST3`          |
| `libs/ui-app/dub.sdl`                            | `APP2`–`APP4`          |

## Relationship to existing specs

| Spec                                               | Relationship                                                                                                         |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| [`sparkles:ui`](../ui/index.md)                    | the toolkit this hosts; `PKG1`/`TGT6` are the constraints that make the host a sibling rather than a layer inside it |
| [`sparkles:ui` backends](../ui/backends.md)        | the `isCanvas` targets the host instantiates; `TGT5` capability declaration is what the host forwards to the app     |
| [`sparkles:input`](../ui/input.md)                 | the event vocabulary the host drains; phase 0 extends it with key levels and the frame fold                          |
| [hue UI architecture](../hue/ui-architecture.md)   | `UIA7`/`UIA8` named the window and terminal seams; this spec is the layer above them                                 |
| [hue GUI](../hue/gui.md), [hue TUI](../hue/tui.md) | the two hosts being migrated onto this contract                                                                      |

→ [Feature requirements](./feature-requirements.md) · [Delivery plan](./PLAN.md) · [Open issues](./open-issues.md)
