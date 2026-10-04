---
status: accepted
owner: sparkles:tui
reviewed: 2026-07-12
---

# Spec: `sparkles:tui` — a full-screen interactive TUI library

## Abstract

`sparkles:tui` is the terminal layer beneath Sparkles' full-screen interactive
applications. It holds each frame as a two-dimensional grid of styled
character cells, compares the grid with the previous frame, and writes only
the cells that changed. An application can therefore repaint its whole
interface on every event without flicker or wasted output. Around that core
the library owns the terminal's lifecycle, restoring raw mode, the alternate
screen and mouse reporting on exit. It also decodes keys, mouse reports and
resizes into a shared input vocabulary, runs an application-driven event loop,
and places inline images. Its rendering architecture was chosen by benchmark
rather than by preference.

## Introduction

A full-screen terminal application, such as a live operations dashboard with a
streaming log, a selectable table, an expandable tree, spinners, mouse
interaction and resizing, redraws parts of the screen many times a second. The
terminal offers it only a byte stream. Escape sequences move the cursor, set
colors and switch modes, and input arrives the same way: keys, mouse reports
and resizes are further sequences that must be decoded. Sparkles' text
engine already measures grapheme widths and wraps styled text correctly, but
it produces text once; nothing in it owns a screen that changes.

The interactive layer must decide what a frame is and how the difference
between two frames becomes bytes. The surveyed libraries split into two
families. Line-diff renderers, such as Bubble Tea, re-emit every changed line
of styled text; cell-grid renderers, such as Ratatui, libvaxis and Notcurses,
compare individual cells. The choice fixes output volume and CPU cost per
frame, and decides whether overlapping or absolutely placed content is
possible at all. It is hard to undo once widgets are written against it. The
terminal adds hazards of its own: a crash must not leave it in raw mode on the
alternate screen, and decoding input must never stall rendering.

The library settles the rendering question by measurement. A render-cost
benchmark implements both families in D and drives them through one dashboard
scene under sparse, churning, scrolling and resizing workloads. The cell grid
is best or tied on CPU at every change density and smallest in output bytes on
every profile. Built on a [packed cell](../../glossary.md#packed-cell), whose
code point and style fit in a few bytes, a D renderer matches a C one on the
common workload. A frame is therefore a grid of packed cells, and a retained
[cell-diff compositor](../../glossary.md#cell-diff-compositor) emits only the
runs of cells that changed and allocates nothing in steady state. Each frame
is bracketed by synchronized output, DEC private mode 2026, so a terminal that
supports it displays the frame at once rather than mid-draw.

The application owns the loop and repaints the whole grid on every event; the
diff, not the application, tracks damage. Terminal control uses fixed escape
sequences rather than terminfo.

This package owns the terminal substrate: the grid and compositor, the
terminal lifecycle with its restore-on-exit guard, input decoding into the
events of `sparkles:input`, the event loop, the folding of truecolor styles
down to the 256 or 16 colors a terminal supports, and inline images over the
kitty and sixel protocols. Layout, styling, focus and widgets belong to the
[`sparkles:ui`](../ui/index.md) toolkit, which paints into this grid through
the terminal backend adapter `sparkles:ui-tui`. The inventory in §2 also
lists those rows so that the whole feature set has one account. Three things
are non-goals: terminfo, screen-reader accessibility, and terminal queries,
such as keyboard-protocol handshakes, beyond what an in-scope feature forces.
Whether a framework-owned model–view–update loop is layered over the
application-owned one stays an open question.

The decision ledger below summarizes every settled choice. §1 lists the
substrate the library reuses, §2 inventories the features a full-screen
application needs with each item's status, §3 records the open architectural
questions and the rendering decision, §4 the non-goals, §5 the consumers, and
§6 where execution is tracked. The [delivery plan](./PLAN.md) orders the work,
and the [render-core benchmark baseline](./render-bench-baseline.md) holds the
measurements behind the decision. The evidence base is the
[TUI-libraries survey](../../research/tui-libraries/index.md), whose
[comparison](../../research/tui-libraries/comparison.md) is written as a
design brief for a D TUI library. The
[TUI component suite](../core-cli/tui-components/index.md) specifies the static
producers this layer builds on.

## Decision ledger

| Area             | Decision                                                                                                                                                                                                                                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Package          | New `sparkles:tui` (`libs/tui/`), depending on `base` + `input`, with `math` on `importPaths` only (its all-template `Vector` would otherwise close a dub cycle). Components and widgets live in `sparkles:ui`, which adapts to this library through `sparkles:ui-tui`                                                    |
| Rendering core   | **Decided: 2-D cell-grid with a compact packed cell** — the render benchmark ([baseline](./render-bench-baseline.md)) shows cell-grid best on CPU + bytes, and a packed-cell D renderer reaches C parity on the common workload (so the architecture is fast enough in D). Framework calibration (M3) is optional context |
| Loop ownership   | **App-owned** — a Ratatui-style library core: `runApp` drives the loop and hands each event to the application. Whether an optional MVU overlay is layered over it stays open (§3.2)                                                                                                                                      |
| Terminal control | Reuse `sparkles.base.term_control` (hardcoded sequences, **no terminfo** — the survey's consensus); the alt-screen + mouse-mode lifecycle is `Terminal`'s, written with those sequences                                                                                                                                   |
| Color            | Truecolor `Color` cells (`TermStyle`), folded to 256 or 16 colors at emission for the detected depth (§2, C1) — a prerequisite for every surveyed mid-level library's styling                                                                                                                                             |
| Text substrate   | Reuse `sparkles.base.text` (grapheme/width/wrap/align) unchanged — it is the single source of truth for cell widths and is stronger than most surveyed libraries'                                                                                                                                                         |
| Images           | **In scope as a requirement**, not a non-goal (§2, G1) — kitty graphics (`KittyImages`) and DEC sixel (`SixelImages`), grounded in Notcurses and libvaxis                                                                                                                                                                 |

## 1. Substrate that already exists

The interactive layer does not start from zero. The following are shipped and
tested, in `sparkles:base` and `sparkles:input` (which this package depends on)
and in `sparkles:ui` and `sparkles:core-cli` (which it does not); see the
[component suite spec](../core-cli/tui-components/index.md) for the static
producers:

| Layer                     | Module(s)                                                              | What it gives the TUI library                                                                                                                      |
| ------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Grapheme/width/wrap/align | `base.text.{grapheme,width,wrap,ansi}`                                 | Kitty-TSP cell widths, style-safe wrapping, `Align`/`alignField`/`truncateField`, SGR tokenization — the cell-width authority every renderer needs |
| Control sequences         | `base.term_control`                                                    | `CtlSeq` (erase/cursor/alt-screen/sync-output), `writeCursor*`, `DecMode` set/reset, `writeMouseTracking` — hardcoded, no terminfo                 |
| SGR styling               | `base.term_style`, `base.term_color`                                   | `TermStyle` (truecolor `Color` fg/bg, `TextAttr`, underline shape and color), `writeStyle`, `ColorDepth` and the depth fold                        |
| Capability detection      | `base.term_caps`                                                       | `terminalSize()`, `isTerminal`, `TermCaps`, `detectTermCaps`, SIGWINCH handler                                                                     |
| Input vocabulary          | `sparkles.input`                                                       | The `Event` sum type (keys, pointer, resize, paste) the decoder produces and the toolkit consumes                                                  |
| Theme                     | `ui.components.theme`                                                  | Border presets, `StatusGlyphs`, `Semantic`, `makeTheme(OutputCapabilities)`                                                                        |
| Static producers          | `ui.components.{box,table,tree,meter,header,tasklist,osc_link,layout}` | Span-capable table, tree, meter/bar, boxes, OSC-8 links, `hjoin`/`kvList` — line-oriented producers beside the cell grid                           |
| In-place repaint          | `ui.components.live` (`LiveRegion`)                                    | Log-update repaint (cursor-up + erase, DEC-2026 framing) — the **full-repaint baseline** the cell-diff renderer improves on                        |
| Minimal raw input         | `core-cli.key_input`                                                   | cbreak-mode enter/restore + a 4-key (`up`/`down`/`enter`/`cancel`) decoder for `select` — the minimal predecessor of `sparkles.tui.input`          |

The survey's own assessment: this substrate (grapheme-correct widths, style-safe
wrapping, SGR-state tracking) is _stronger_ than what most surveyed libraries sit
on, so the gaps below are in the **interactive/runtime** layer, not the text
engine.

## 2. The delta — features a full interactive TUI needs

Status legend: **landed** · **partial** (exists but incomplete or in the wrong
layer) · **open** (net-new) · **deferred**.

Rows B2, S1, L1–L2 and W1–W5 are layout, styling, widget and backend-seam work,
which belongs to [`sparkles:ui`](../ui/index.md). Each such row names the
toolkit requirements that deliver or track it, and its status is theirs.

| #   | Area         | Feature                                                                                                                                                                                                                                                                                                                                                                                        | Status  | Grounding (surveyed libraries)                                                                                                                                                                                                                                                                 |
| --- | ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1  | Render core  | Frame buffer + diff — **2-D cell-grid with a compact packed cell (§3.1, [baseline](./render-bench-baseline.md))**: `Grid` (`sparkles.tui.cell`) diffed by `Screen` (`sparkles.tui.render`), with DECSTBM scroll-region scrolling and `Grid.fillRect`/`Grid.scrollRect`                                                                                                                         | landed  | [Ratatui](../../research/tui-libraries/ratatui.md)/[libvaxis](../../research/tui-libraries/libvaxis.md)/[FTXUI](../../research/tui-libraries/ftxui.md)/[Notcurses](../../research/tui-libraries/notcurses.md) (cell); [Bubble Tea](../../research/tui-libraries/bubbletea.md) (line, rejected) |
| R2  | Render core  | Double-buffering + synchronized-output (DEC 2026) frame framing; minimal-write emission                                                                                                                                                                                                                                                                                                        | landed  | [Mosaic](../../research/tui-libraries/mosaic.md), [libvaxis](../../research/tui-libraries/libvaxis.md), [Notcurses](../../research/tui-libraries/notcurses.md) (`CtlSeq.sync*` in `base`)                                                                                                      |
| B1  | Backend      | Terminal-lifecycle owner: raw mode, alt-screen enter/exit, mouse-mode enable/disable, cursor hide/show, **panic/scope restore guard**                                                                                                                                                                                                                                                          | landed  | [libvaxis](../../research/tui-libraries/libvaxis.md) (panic handler), [Ratatui](../../research/tui-libraries/ratatui.md) `Backend` trait, [Notcurses](../../research/tui-libraries/notcurses.md)                                                                                               |
| B2  | Backend      | Swappable backend seam incl. an in-memory/test backend for deterministic rendering tests — in `sparkles:ui`: the canvas concept ([`TGT1`](../ui/backends.md)) with backends in sibling packages (`TGT6`) and `RecordingCanvas` as the in-memory target; rendering one tree through every target in a test is `TGT10`                                                                           | partial | [Ratatui](../../research/tui-libraries/ratatui.md) (`TestBackend`), [Cursive](../../research/tui-libraries/cursive.md) (`DummyBackend`)                                                                                                                                                        |
| I1  | Input        | Full key decoder: arrows/home/end/pgup·pgdn/insert/delete/F1–F12 + ctrl/alt/shift modifiers, into a structured `Event` sum type                                                                                                                                                                                                                                                                | landed  | [libvaxis](../../research/tui-libraries/libvaxis.md), [Bubble Tea](../../research/tui-libraries/bubbletea.md) (`core-cli`'s `key_input` decodes four keys)                                                                                                                                     |
| I2  | Input        | Mouse events (X10 + SGR-1006), wheel, drag; positional hit-testing "zones"                                                                                                                                                                                                                                                                                                                     | partial | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (bubblezone), [libvaxis](../../research/tui-libraries/libvaxis.md), [tview](../../research/tui-libraries/tview.md)                                                                                                                     |
| I3  | Input        | Resize-as-event; bracketed paste; input read decoupled from the render loop                                                                                                                                                                                                                                                                                                                    | partial | [libvaxis](../../research/tui-libraries/libvaxis.md), [Textual](../../research/tui-libraries/textual.md) (SIGWINCH handler in `term_caps`)                                                                                                                                                     |
| E1  | Runtime      | Event loop + command/async-effect model; optional MVU overlay (`Model`/`update`/`view` + `Cmd`/`Msg`) or app-owned loop (§3.2)                                                                                                                                                                                                                                                                 | partial | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (MVU), [Ratatui](../../research/tui-libraries/ratatui.md) (app owns loop), [Brick](../../research/tui-libraries/brick.md)                                                                                                              |
| E2  | Runtime      | Frame scheduler / tick source for animation (spinner/gradient/progress cadence), coalesced to a max frame rate                                                                                                                                                                                                                                                                                 | open    | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (`Tick`), [Mosaic](../../research/tui-libraries/mosaic.md), [Textual](../../research/tui-libraries/textual.md)                                                                                                                         |
| C1  | Color        | Truecolor (24-bit) + 256-color + adaptive degradation to the terminal's real depth                                                                                                                                                                                                                                                                                                             | landed  | [libvaxis](../../research/tui-libraries/libvaxis.md), [Notcurses](../../research/tui-libraries/notcurses.md) (RGBA channels), Lip Gloss (via [Bubble Tea](../../research/tui-libraries/bubbletea.md))                                                                                          |
| C2  | Color        | Color-depth probing in `TermCaps` (`colorDepth`, classified by `classifyColorDepth`); blend helper (`mix` in `sparkles.base.term_color`)                                                                                                                                                                                                                                                       | landed  | [Notcurses](../../research/tui-libraries/notcurses.md), [libvaxis](../../research/tui-libraries/libvaxis.md)                                                                                                                                                                                   |
| S1  | Style        | Structured cell-style value (fg/bg/modifiers) for the cell path — `CellStyle` (`sparkles.tui.cell`) — plus block styling (padding/margin/border/align/width) — in `sparkles:ui`: the theme's `Visual` ([`THM3`](../ui/theme.md)) and metrics (`THM4`)                                                                                                                                          | landed  | Lip Gloss (via [Bubble Tea](../../research/tui-libraries/bubbletea.md)), [FTXUI](../../research/tui-libraries/ftxui.md) decorators, [Brick](../../research/tui-libraries/brick.md) `AttrMap`                                                                                                   |
| L1  | Layout       | `vjoin` + `place` (positional alignment) — in `sparkles:ui`: column containers ([`WGT7`](../ui/widgets.md)) with per-axis alignment ([`LAY8`](../ui/layout.md)); the string producers `hjoin`/`kvList` live in `ui.components.layout`                                                                                                                                                          | landed  | Lip Gloss `Join*`/`Place`, [FTXUI](../../research/tui-libraries/ftxui.md)                                                                                                                                                                                                                      |
| L2  | Layout       | A layout engine: constraint splits and/or flexbox and/or combinators (`hBox`/`vBox`/`hLimit`/`pad`/`center`) — in `sparkles:ui`: the box-flow engine ([`LAY1`, `LAY2`, `LAY6`](../ui/layout.md))                                                                                                                                                                                               | landed  | [Ratatui](../../research/tui-libraries/ratatui.md) (constraints/Cassowary), [FTXUI](../../research/tui-libraries/ftxui.md)/[Ink](../../research/tui-libraries/ink.md) (flexbox), [Brick](../../research/tui-libraries/brick.md) (combinators)                                                  |
| W1  | Widget model | `isWidget`/`isStatefulWidget` DbI render contract; a focus model (tab order, focused-path event routing) — in `sparkles:ui`: the widget arena and sum-type payload ([`WGT1`, `WGT3`](../ui/widgets.md)) and focus ([`STM7`](../ui/state-machines.md))                                                                                                                                          | partial | [Ratatui](../../research/tui-libraries/ratatui.md) (`(Stateful)Widget`), [libvaxis](../../research/tui-libraries/libvaxis.md) vxfw, [Cursive](../../research/tui-libraries/cursive.md)/[tview](../../research/tui-libraries/tview.md)                                                          |
| W2  | Widgets      | Scrollable viewport + scrollbar (page/half-page/goto, wheel) — in `sparkles:ui`: [`WGT9`, `WGT10`](../ui/widgets.md)                                                                                                                                                                                                                                                                           | landed  | [Ratatui](../../research/tui-libraries/ratatui.md), Bubbles (via [Bubble Tea](../../research/tui-libraries/bubbletea.md)), [Textual](../../research/tui-libraries/textual.md)                                                                                                                  |
| W3  | Widgets      | Interactive (selectable/navigable) table + tree — in `sparkles:ui`: tree [`WGT12`](../ui/widgets.md), table `WGT11`, list `WGT13`                                                                                                                                                                                                                                                              | partial | [Ratatui](../../research/tui-libraries/ratatui.md) (`Table`/`List` + `State`), [tview](../../research/tui-libraries/tview.md); [tree-view case study](../../research/tui-libraries/tree-view-case-study.md)                                                                                    |
| W4  | Widgets      | Stateful spinner + spinner catalog; toast/notification (timed, fading); key-map help bar — in `sparkles:ui`: toast [`WGT16`](../ui/widgets.md) and meter/progress `WGT19`; `spinnerFrame` and `ProgressLine` are pure producers in `ui.components`                                                                                                                                             | partial | Bubbles/[Bubble Tea](../../research/tui-libraries/bubbletea.md), [Textual](../../research/tui-libraries/textual.md)                                                                                                                                                                            |
| W5  | Widgets      | Single-line input + multi-line text area; tabs; dialog/modal stack — in `sparkles:ui`: the line editor ([`STM13`](../ui/state-machines.md)), text input [`WGT14`](../ui/widgets.md), tabs `WGT23`, the editor ([`EDR1`](../ui/editor.md)) and overlay modality ([`MDL1`](../ui/popup.md))                                                                                                      | partial | [Cursive](../../research/tui-libraries/cursive.md), [tview](../../research/tui-libraries/tview.md), [Textual](../../research/tui-libraries/textual.md), Bubbles                                                                                                                                |
| G1  | Graphics     | Inline images — Kitty graphics / Sixel / iTerm protocols, cell-anchored, placement- and scroll-aware, capability-gated with a text fallback. Kitty (`KittyImages`, `sparkles.tui.images`) and sixel (`SixelImages`, `sparkles.tui.sixel`) are emitted, gated on `Terminal.imageProtocol`; `sparkles:ui-tui` falls back to cells ([`IMG5`](../ui/effects.md)). iTerm2 (OSC 1337) is not emitted | partial | [Notcurses](../../research/tui-libraries/notcurses.md) (Sixel/Kitty/iTerm pixel graphics + video), [libvaxis](../../research/tui-libraries/libvaxis.md) (per-cell image)                                                                                                                       |

The two hardest widgets already have accepted blueprints in the survey and should
follow them rather than be redesigned:

- **Tree (W3)** — the three-layer split (data / view-state / renderer), flat
  storage, `flatten()` as a pure free function, from the
  [tree-view case study](../../research/tui-libraries/tree-view-case-study.md).
- **Table (W3)** — span/selection over the HTML slot-grid model; the _static_
  span-capable core already landed per the
  [table-span case study](../../research/tui-libraries/table-span-case-study.md)
  and [`table.md`](../core-cli/table.md), so W3 is the interactivity overlay.

## 3. Open architectural questions

These are not deferrals — they are decisions that need evidence or a deliberate
API choice before the library's modules are written. Each names what resolves it.

### 3.1 Rendering core: line-diff vs 2-D cell-grid

The single load-bearing choice. The candidates and their tradeoffs, from the
survey's [frame-diffing comparison](../../research/tui-libraries/comparison.md#frame-diffing-strategies):

- **Line-diff** — a frame is a buffer of fully-styled ANSI _byte-lines_; the diff
  is `bytes-equal` per line; only changed lines are re-emitted with absolute
  cursor positioning ([Bubble Tea](../../research/tui-libraries/bubbletea.md)
  lineage). Reuses the existing string producers almost directly; damage tracking at
  whole-line resolution.
- **2-D cell-grid** — a frame is a flat `Cell[]` grid (grapheme + fg/bg/style per
  cell), double-buffered; the diff is per-cell; only changed cell runs are emitted
  ([Ratatui](../../research/tui-libraries/ratatui.md)/[libvaxis](../../research/tui-libraries/libvaxis.md)/[FTXUI](../../research/tui-libraries/ftxui.md)/[Notcurses](../../research/tui-libraries/notcurses.md)
  lineage). More powerful (overlap, z-order, absolute placement, sub-line
  precision); the string producers need cell-grid adapters. The
  [comparison](../../research/tui-libraries/comparison.md#recommended-architecture)
  recommends this as the best fit for D.

**Resolution:** the [render-cost benchmark](./PLAN.md#deliverable-2) — both
approaches implemented as D PoCs and benchmarked head-to-head across a suite of
workload profiles (sparse update / full-screen churn / scrolling / resize), with
a byte-identical C port of the cell-grid renderer as cross-language
calibration. The deciding axes are output bytes per frame, instructions per
frame, and allocations, including whether a zero-allocation steady state is
achievable. A full-repaint renderer (`reference_fullpaint`), the approach of
`sparkles:ui`'s `LiveRegion`, is the naive baseline.

**Decision** ([render-bench-baseline](./render-bench-baseline.md)):
the 2-D cell-grid is best-or-tied on CPU at every change density and dominates on
bytes on every profile; line-diff costs full-repaint CPU (it re-serializes every
row to diff it), and the fix (cell-compare rows) only helps sparse workloads.
Allocation is neutral — all approaches reach zero-alloc steady state. And the
cross-language calibration shows a packed-cell D renderer reaches C parity on the
common workload, so the architecture is fast enough in D. **Chosen: the 2-D
cell-grid, built on a compact packed cell** (packed codepoint + flat style, long
graphemes spilled out-of-line — the Notcurses/libvaxis inline-packing). A rough
absolute-frontier comparison against the actual frameworks remains optional context.

### 3.2 Loop ownership and API shape

Whether the library owns the event loop (framework-style MVU, as
[Bubble Tea](../../research/tui-libraries/bubbletea.md)) or is a rendering library
the application drives (as [Ratatui](../../research/tui-libraries/ratatui.md),
[libvaxis](../../research/tui-libraries/libvaxis.md)). The
[comparison's recommendation](../../research/tui-libraries/comparison.md#recommended-architecture)
is a library core (app owns the loop) with an **optional** MVU overlay built on
it — `update` enforced `pure`, messages as `SumType` with exhaustive `match!`.
This is an API decision (not a benchmark question); the render benchmark keeps it
open by measuring the renderer independently of any loop. The library core is
built: `runApp` is an app-owned loop. The MVU overlay is not.

### 3.3 Update strategy: immediate vs retained vs incremental

Immediate-mode (rebuild each frame) is the survey's recommended default for D
(`@nogc`-friendly, stack-allocated widgets), with retained-mode and
[Nottui](../../research/tui-libraries/nottui.md)-style incremental reactivity as
optional optimization paths — see
[comparison §8](../../research/tui-libraries/comparison.md#recommended-architecture).
Decided alongside 3.2; the render core it builds on is fixed (§3.1).

## 4. Non-goals

Grounded in the survey's consensus (see
[comparison](../../research/tui-libraries/comparison.md)):

- **terminfo** — the survey's no-terminfo, query-first consensus; hardcoded
  sequences via `base.term_control`, with C-interop terminfo fallback only if a
  legacy-terminal consumer ever demands it.
- **Accessibility / screen-reader** — no surveyed terminal library ships this;
  out of scope until a consumer needs it.
- **Terminal _queries_ beyond capability probing** (DA1/CPR/kitty-keyboard
  handshakes) — only as far as an in-scope interactive feature forces it.

Inline images are not a non-goal: they are a **requirement**, G1 above,
grounded in Notcurses and libvaxis.

## 5. Consumers / traceability

| Consumer                       | Items exercised                                                                                                                                |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `sparkles:ui-tui`              | R1–R2, B1, I1–I3, C1, G1 — `GridCanvas` paints the toolkit's display list into a `Grid`; `TerminalSession` drives `Terminal` and `PosixEvents` |
| `hue`, `ui-gallery`            | The same items, through `sparkles:ui-tui`; `ui-gallery`'s `--render` path serializes a `Grid` directly                                         |
| Live operations-dashboard demo | R1–R2, B1, I1–I3, E1–E2, W2–W4 — the full-screen driver, and the benchmark scene (§ PLAN)                                                      |
| `release`                      | Could adopt E1/W3/W4 for an interactive stage/preflight view (it renders through the line-based `LiveRegion`)                                  |
| `ci`                           | W2 (scrollback of example runs), I3 (resize)                                                                                                   |
| test runner                    | Consumes the pure producers in `ui.components`; an in-memory backend (B2) would make widget tests golden                                       |
| `docs`/`examples`              | Every landed widget ships a runnable example (`ci --verify`)                                                                                   |

## 6. Execution

Milestones, dependencies, and the benchmark that resolves §3.1 live in the
[delivery plan](./PLAN.md), which also records progress. The benchmark harness
is `libs/tui/bench/render/`. The library is `libs/tui/src/sparkles/tui/`:

- `cell.d` + `render.d` — the render core (R1–R2): the 2-D cell grid and its
  per-cell diff, with scroll-region hardware scrolling (DECSTBM + SU/SD,
  detected between frames), the compositing primitives `Grid.fillRect` and
  `Grid.scrollRect`, and color-depth folding (C1).
- `terminal.d` — the terminal backend (B1): raw mode, alternate screen, mouse,
  synchronized diff flush, restore, depth detection and capability probing.
- `input.d` — the input decoder (I1–I3): keys, mouse, paste and resize into
  `sparkles.input`'s `Event`.
- `app.d` — the app-owned event loop (E1), `runApp`, with a runnable demo in
  `libs/tui/examples/demo.d`.
- `images.d` + `sixel.d` — inline images over kitty and sixel (G1).
- `geometry.d` — the `TermPosition`/`TermSize` vocabulary.

Style, layout, the widget model and widgets (S1, L1–L2, W1–W5) are built in
`sparkles:ui`, as §2 records row by row.
