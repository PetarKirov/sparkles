---
status: accepted
owner: sparkles:ui-app
reviewed: 2026-08-07
---

# `sparkles:ui-app` — Overview

## Abstract

`sparkles:ui-app` is the application host for the Sparkles user-interface
toolkit: the layer that turns an interface description into a running
interactive program. It decides whether the program runs in a terminal or a
desktop window, gives every application the same window and font
command-line options, and runs the loop that reads input and draws frames.
An application written against the host never names a backend, so one
program serves both targets. The same loop also runs headless over scripted
input, so an application's behavior is testable without a window or a
terminal.

## Introduction

The [`sparkles:ui`](../ui/index.md) toolkit describes an interface as data and
paints it through small backends. A backend is the code that serves one
target, such as a terminal or a GPU window, and by design the toolkit knows
nothing about which one is running. An interactive program still needs
someone to make that choice and act on it. Someone must pick the target for
this process, open a window and load its fonts, and read the user's window and
font options. Someone must drain input, decide when a frame is drawn, and
perform platform errands such as setting the pointer shape, the clipboard and
the window title. Every Sparkles application with an interface needs this
layer, from the hue code viewer to the terminal emulator and the diagram
board.

Written privately inside each application, the layer drifts. Two programs
that each declare font and window flags end up with different spellings,
defaults and resolution orders for the same job. A platform rule such as "on
Android the window is the whole application, so there is no terminal to
choose" lives in one program's comments, where the next program never sees
it. Each hand-written frame loop settles resize, quit and repaint its own
way. Worst, a loop that opens a real window or terminal cannot run in a unit
test, so the application logic written inside it is checked only by hand.
Yet folding input, routing the pointer and deciding whether to draw are pure
or nearly pure.

The host owns that layer once, as a sibling package of the toolkit rather
than a layer inside it, so the toolkit gains no dependency. An application
supplies a function that presents its state and one that handles each event;
the host does everything else. Choosing the backend is a pure decision over
an injected policy of command-line flags, terminal presence and display
presence, and reading the environment is a separate function, so every
combination is testable. The host, never the application, is specialized
per backend at compile time instead of being dispatched through an
interface, so the frame path has no indirection and inherits each backend's
guarantees. Besides the terminal and the window, the host offers a third
target: the [recording target](../../glossary.md#recording-target) takes a
scripted list of events and records the frames, draw operations and platform
calls they cause, so a whole session is assertable in an ordinary unit test.
On every target, an application hands over as much of drawing as it wants,
at one of three [render levels](../../glossary.md#render-level). It gives
the host a widget tree to lay out and paint, appends to a
[display list](../../glossary.md#display-list), or takes the concrete drawing
surface for a renderer of its own.

This specification covers backend selection, the shared window and font
options with the order in which a window is set up, the host's frame loop
and contract, the package's build configurations, and the testability
obligations the host places on the applications that use it. Widget
composition, layout and theming belong to the toolkit, and drawing
primitives, glyph atlases and cell grids to its backend packages. The event
vocabulary belongs to `sparkles:input`, and argument parsing to
`sparkles:core-cli`, to which the host contributes options but no parser.
Waiting, timers and background work belong to
[`sparkles:event-horizon`](../event-horizon/SPEC.md); the host's live loops
run on it, while the host keeps the frame policy. Native windowing belongs to
[`sparkles:wsi`](../window-system-integration/SPEC.md), and what to render is
always the application's decision. The backend vocabulary also names
non-interactive HTML and ANSI output, which the host reports rather than
runs; [`UIAPP-O3`](./open-issues.md#uiapp-o3) tracks whether it should own
those outputs too.

This page lists what the host owns, its [render targets](#render-targets),
the [three render levels](#the-three-render-levels) and the
[package graph](#package-graph), and defines the [status](#status-scheme),
[ID](#id-scheme) and [traceability](#traceability) schemes of every page in
the tree. [Feature requirements](./feature-requirements.md) holds the
requirements by area: architecture, backend selection, the options, the host
contract and testability. [Terminal view](./terminal-view.md) specifies
`sparkles:terminal-view`, the terminal emulator's core as a component any
application can embed. [Open issues](./open-issues.md) records deferred
decisions, and the [delivery plan](./PLAN.md) holds delivery order and
progress. [Relationship to existing specs](#relationship-to-existing-specs)
places the host among the specifications it depends on and serves.

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

### Native WSI and Graphite evolution

The graph above is the shipped phase-1 raylib host. The accepted next graph is
specified by [`sparkles:wsi`](../window-system-integration/SPEC.md): native Wayland,
X11, Win32, and AppKit windowing joins this host's existing Event Horizon loop, then
Skia Graphite supplies Vulkan rendering on Linux/Windows and Metal on macOS. SDL 3
and raylib remain explicit compatibility configurations; they are never silent
fallbacks behind the native selection. Applications still call the same `runApp`
contract and do not import a window system or renderer.

## Documentation map

| Page                                              | What it covers                                                                                                                         |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | what the host is · why it exists · targets · render levels · the status/ID scheme                                                      |
| [Feature requirements](./feature-requirements.md) | the requirement tree: architecture (`APP`), backend selection (`BKD`), the CLI (`CLI`), the host contract (`HST`), testability (`TST`) |
| [Delivery plan](./PLAN.md)                        | execution: the four phases, their dependencies, the acceptance gates, and what each phase makes testable                               |
| [Terminal view](./terminal-view.md)               | phase 2's `apps/terminal` extraction: the core as an embeddable `runApp` component (`TVW`), the paint hook, and the parity/perf gates  |
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

| Spec                                                   | Relationship                                                                                                                            |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| [`sparkles:ui`](../ui/index.md)                        | the toolkit this hosts; `PKG1`/`TGT6` are the constraints that make the host a sibling rather than a layer inside it                    |
| [`sparkles:ui` backends](../ui/backends.md)            | the `isCanvas` targets the host instantiates; `TGT5` capability declaration is what the host forwards to the app                        |
| [`sparkles:input`](../ui/input.md)                     | the event vocabulary the host drains; phase 0 extends it with key levels and the frame fold                                             |
| [`sparkles:wsi`](../window-system-integration/SPEC.md) | the future native GUI window/input source; its events are normalized here and its sources attach to this host's Event Horizon scheduler |
| [`sparkles:event-horizon`](../event-horizon/SPEC.md)   | the one scheduler, wait, timer, wake, and background-work loop shared by TUI and every GUI host                                         |
| [hue UI architecture](../hue/ui-architecture.md)       | `UIA7`/`UIA8` named the window and terminal seams; this spec is the layer above them                                                    |
| [hue GUI](../hue/gui.md), [hue TUI](../hue/tui.md)     | the two hosts being migrated onto this contract                                                                                         |

→ [Feature requirements](./feature-requirements.md) · [Delivery plan](./PLAN.md) · [Open issues](./open-issues.md)
