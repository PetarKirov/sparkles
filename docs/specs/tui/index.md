# Spec: `sparkles:tui` — a full-screen interactive TUI library

**Status:** living inventory · **Date:** 2026-07-12 · **Scope:** a new
`sparkles:tui` sub-package (`libs/tui/`) layered on `sparkles:core-cli` and
`sparkles:base`.

This is the single source of truth for the interactive-TUI feature set: what the
existing sparkles stack already provides, what a full-screen interactive library
additionally needs, per-item status, and the design questions still open. It is
the forward-looking companion to the shipped
[`core-cli` TUI component suite](../core-cli/tui-components/index.md), whose §F
deliberately scoped out exactly this layer — "full-screen TUI loop (alt screen,
general `Event`/`Backend` framework, an app-owned event loop)" and "a cell-grid
diff compositor." Those deferrals are now the subject of this spec.

The motivating consumer is a full-screen, interactive terminal application — a
live multi-pane operations dashboard: a header with status pills, a scrollable
streaming log pane, a data table with a moving selection, an expand/collapse
tree, animated spinners and per-item progress, mouse interaction, and live
resize handling.

The evidence base is the in-repo
[TUI-libraries survey](../../research/tui-libraries/index.md) — the
[comparison synthesis](../../research/tui-libraries/comparison.md) (written
explicitly as a design brief for a D TUI library), the
[tree-view](../../research/tui-libraries/tree-view-case-study.md) and
[table-span](../../research/tui-libraries/table-span-case-study.md) case studies,
and the per-library deep dives cited inline below. Every feature and design
option in this spec is grounded in a surveyed library or in existing sparkles
code; no external application is treated as the specification.

> [!IMPORTANT]
> **The core rendering architecture is deliberately undecided in this spec.**
> The two leading candidates (line-diff vs 2-D cell-grid — §3.1) are separated by
> a factor that only measurement resolves, so the choice is delegated to the
> [render-cost benchmark](./PLAN.md#deliverable-2) (D proofs-of-concept plus
> cross-language calibration under `sparkles:test-runner --bench --perf`). This
> spec inventories the requirements that are invariant to that choice, and marks
> the ones that depend on it.

## Decision ledger

| Area             | Decision                                                                                                                                                                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Package          | New `sparkles:tui` (`libs/tui/`), depending on `core-cli` + `base`. Keeps `core-cli`'s pure static-producer character intact and its dependency graph loop-free                                                                                         |
| Rendering core   | **Open, leaning 2-D cell-grid** — the render benchmark ([baseline](./render-bench-baseline.md), M1–M2) favours the cell-grid on CPU + bytes; cross-language calibration (M3) confirms before it's final. The rest of the design survives either outcome |
| Loop ownership   | **Open** — a Ratatui-style library core (app owns the loop) with an optional MVU overlay, vs a Bubble-Tea-style framework-owned loop (§3.2)                                                                                                             |
| Terminal control | Reuse `sparkles.base.term_control` (hardcoded sequences, **no terminfo** — the survey's consensus); grow it with the alt-screen + mouse-mode lifecycle it lacks                                                                                         |
| Color            | Extend beyond today's 16-color `Style` to truecolor + 256 + degradation (§2, Color row) — a prerequisite for every surveyed mid-level library's styling                                                                                                 |
| Text substrate   | Reuse `sparkles.base.text` (grapheme/width/wrap/align) unchanged — it is the single source of truth for cell widths and is stronger than most surveyed libraries'                                                                                       |
| Images           | **In scope as a requirement**, not a non-goal (§2, Graphics row) — grounded in Notcurses and libvaxis                                                                                                                                                   |

## 1. Substrate that already exists

The interactive layer does not start from zero. The following are shipped,
tested, and reused as-is (see the [component suite spec](../core-cli/tui-components/index.md)
for detail):

| Layer                     | Module(s)                                                            | What it gives the TUI library                                                                                                                      |
| ------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Grapheme/width/wrap/align | `base.text.{grapheme,width,wrap,ansi}`                               | Kitty-TSP cell widths, style-safe wrapping, `Align`/`alignField`/`truncateField`, SGR tokenization — the cell-width authority every renderer needs |
| Control sequences         | `base.term_control`                                                  | `CtlSeq` (erase/cursor/alt-screen/sync-output), `writeCursor*`, `DecMode` set/reset — hardcoded, no terminfo                                       |
| SGR styling               | `base.term_style`, `theme` (`core-cli.ui.theme`)                     | `Style` (16-color SGR), border presets, `StatusGlyphs`, `Semantic`, `makeTheme(TermCaps)`                                                          |
| Capability detection      | `core-cli.term_caps`                                                 | `terminalSize()`, `isTerminal`, `TermCaps`, `detectTermCaps`, SIGWINCH handler                                                                     |
| Static producers          | `core-cli.ui.{box,table,tree,meter,header,tasklist,osc_link,layout}` | Span-capable table, tree, meter/bar, boxes, OSC-8 links, `hjoin`/`kvList` — candidate widget bodies / renderers                                    |
| In-place repaint          | `core-cli.ui.live` (`LiveRegion`)                                    | Log-update repaint (cursor-up + erase, DEC-2026 framing) — a **full-repaint baseline** and the current status quo the new renderer replaces        |
| Minimal raw input         | `core-cli.key_input`                                                 | cbreak-mode enter/restore + a 4-key (`up`/`down`/`enter`/`cancel`) decoder — the seed the full input parser extends                                |

The survey's own assessment: this substrate (grapheme-correct widths, style-safe
wrapping, SGR-state tracking) is _stronger_ than what most surveyed libraries sit
on, so the gaps below are in the **interactive/runtime** layer, not the text
engine.

## 2. The delta — features a full interactive TUI needs

Status legend: **landed** · **partial** (exists but incomplete or in the wrong
layer) · **open** (net-new) · **deferred**.

| #   | Area         | Feature                                                                                                                                     | Status  | Grounding (surveyed libraries)                                                                                                                                                                                                                                                       |
| --- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R1  | Render core  | Frame buffer + diff — **line-diff vs cell-grid (OPEN, §3.1)**                                                                               | open    | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (line); [Ratatui](../../research/tui-libraries/ratatui.md)/[libvaxis](../../research/tui-libraries/libvaxis.md)/[FTXUI](../../research/tui-libraries/ftxui.md)/[Notcurses](../../research/tui-libraries/notcurses.md) (cell) |
| R2  | Render core  | Double-buffering + synchronized-output (DEC 2026) frame framing; minimal-write emission                                                     | partial | [Mosaic](../../research/tui-libraries/mosaic.md), [libvaxis](../../research/tui-libraries/libvaxis.md), [Notcurses](../../research/tui-libraries/notcurses.md) (`CtlSeq.sync*` exists in `base`)                                                                                     |
| B1  | Backend      | Terminal-lifecycle owner: raw mode, alt-screen enter/exit, mouse-mode enable/disable, cursor hide/show, **panic/scope restore guard**       | open    | [libvaxis](../../research/tui-libraries/libvaxis.md) (panic handler), [Ratatui](../../research/tui-libraries/ratatui.md) `Backend` trait, [Notcurses](../../research/tui-libraries/notcurses.md)                                                                                     |
| B2  | Backend      | Swappable backend seam incl. an in-memory/test backend for deterministic rendering tests                                                    | open    | [Ratatui](../../research/tui-libraries/ratatui.md) (`TestBackend`), [Cursive](../../research/tui-libraries/cursive.md) (`DummyBackend`)                                                                                                                                              |
| I1  | Input        | Full key decoder: arrows/home/end/pgup·pgdn/insert/delete/F1–F12 + ctrl/alt/shift modifiers, into a structured `Event` sum type             | partial | [libvaxis](../../research/tui-libraries/libvaxis.md), [Bubble Tea](../../research/tui-libraries/bubbletea.md) (`key_input` decodes 4 keys today)                                                                                                                                     |
| I2  | Input        | Mouse events (X10 + SGR-1006), wheel, drag; positional hit-testing "zones"                                                                  | open    | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (bubblezone), [libvaxis](../../research/tui-libraries/libvaxis.md), [tview](../../research/tui-libraries/tview.md)                                                                                                           |
| I3  | Input        | Resize-as-event; bracketed paste; input read decoupled from the render loop                                                                 | partial | [libvaxis](../../research/tui-libraries/libvaxis.md), [Textual](../../research/tui-libraries/textual.md) (SIGWINCH handler exists in `term_caps`)                                                                                                                                    |
| E1  | Runtime      | Event loop + command/async-effect model; optional MVU overlay (`Model`/`update`/`view` + `Cmd`/`Msg`) or app-owned loop (§3.2)              | open    | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (MVU), [Ratatui](../../research/tui-libraries/ratatui.md) (app owns loop), [Brick](../../research/tui-libraries/brick.md)                                                                                                    |
| E2  | Runtime      | Frame scheduler / tick source for animation (spinner/gradient/progress cadence), coalesced to a max frame rate                              | open    | [Bubble Tea](../../research/tui-libraries/bubbletea.md) (`Tick`), [Mosaic](../../research/tui-libraries/mosaic.md), [Textual](../../research/tui-libraries/textual.md)                                                                                                               |
| C1  | Color        | Truecolor (24-bit) + 256-color + adaptive degradation to the terminal's real depth (today: 16-color only)                                   | open    | [libvaxis](../../research/tui-libraries/libvaxis.md), [Notcurses](../../research/tui-libraries/notcurses.md) (RGBA channels), Lip Gloss (via [Bubble Tea](../../research/tui-libraries/bubbletea.md))                                                                                |
| C2  | Color        | Color-depth probing in `TermCaps` (today `colors` is a bool); gradient/blend helpers                                                        | partial | [Notcurses](../../research/tui-libraries/notcurses.md), [libvaxis](../../research/tui-libraries/libvaxis.md)                                                                                                                                                                         |
| S1  | Style        | Structured cell-style value (fg/bg/modifiers) for the cell path, plus copy-on-write block styling (padding/margin/border/align/width)       | partial | Lip Gloss (via [Bubble Tea](../../research/tui-libraries/bubbletea.md)), [FTXUI](../../research/tui-libraries/ftxui.md) decorators, [Brick](../../research/tui-libraries/brick.md) `AttrMap` (`term_style`/`theme` exist)                                                            |
| L1  | Layout       | `vjoin` + `place` (positional alignment) — `hjoin` landed                                                                                   | partial | Lip Gloss `Join*`/`Place`, [FTXUI](../../research/tui-libraries/ftxui.md) (`hjoin` landed in `ui.layout`)                                                                                                                                                                            |
| L2  | Layout       | A layout engine: constraint splits and/or flexbox and/or combinators (`hBox`/`vBox`/`hLimit`/`pad`/`center`)                                | open    | [Ratatui](../../research/tui-libraries/ratatui.md) (constraints/Cassowary), [FTXUI](../../research/tui-libraries/ftxui.md)/[Ink](../../research/tui-libraries/ink.md) (flexbox), [Brick](../../research/tui-libraries/brick.md) (combinators)                                        |
| W1  | Widget model | `isWidget`/`isStatefulWidget` DbI render contract; a focus model (tab order, focused-path event routing)                                    | open    | [Ratatui](../../research/tui-libraries/ratatui.md) (`(Stateful)Widget`), [libvaxis](../../research/tui-libraries/libvaxis.md) vxfw, [Cursive](../../research/tui-libraries/cursive.md)/[tview](../../research/tui-libraries/tview.md)                                                |
| W2  | Widgets      | Scrollable viewport + scrollbar (page/half-page/goto, wheel)                                                                                | open    | [Ratatui](../../research/tui-libraries/ratatui.md), Bubbles (via [Bubble Tea](../../research/tui-libraries/bubbletea.md)), [Textual](../../research/tui-libraries/textual.md)                                                                                                        |
| W3  | Widgets      | Interactive (selectable/navigable) table + tree — static renderers exist in `ui.table`/`ui.tree`                                            | partial | [Ratatui](../../research/tui-libraries/ratatui.md) (`Table`/`List` + `State`), [tview](../../research/tui-libraries/tview.md); [tree-view case study](../../research/tui-libraries/tree-view-case-study.md)                                                                          |
| W4  | Widgets      | Stateful spinner + spinner catalog; toast/notification (timed, fading); key-map help bar                                                    | partial | Bubbles/[Bubble Tea](../../research/tui-libraries/bubbletea.md), [Textual](../../research/tui-libraries/textual.md) (`spinnerFrame`/`ProgressLine` exist as pure producers)                                                                                                          |
| W5  | Widgets      | Single-line input + multi-line text area; tabs; dialog/modal stack                                                                          | open    | [Cursive](../../research/tui-libraries/cursive.md), [tview](../../research/tui-libraries/tview.md), [Textual](../../research/tui-libraries/textual.md), Bubbles                                                                                                                      |
| G1  | Graphics     | Inline images — Kitty graphics / Sixel / iTerm protocols, cell-anchored, placement- and scroll-aware, capability-gated with a text fallback | open    | [Notcurses](../../research/tui-libraries/notcurses.md) (Sixel/Kitty/iTerm pixel graphics + video), [libvaxis](../../research/tui-libraries/libvaxis.md) (per-cell image)                                                                                                             |

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
  lineage). Reuses today's string producers almost directly; damage tracking at
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
cross-language reference implementations from the surveyed libraries as external
calibration. The deciding axes are output bytes per frame, instructions per
frame, and — likely dominant for a GC'd library — allocations and whether a
zero-allocation steady state is achievable. `core-cli`'s `LiveRegion` provides a
naive full-repaint baseline.

**Preliminary finding** ([render-bench-baseline](./render-bench-baseline.md), M1–M2):
the 2-D cell-grid is best-or-tied on CPU at every change density and dominates on
bytes on every profile; line-diff costs full-repaint CPU (it re-serializes every
row to diff it), and the fix (cell-compare rows) only helps sparse workloads.
Allocation is neutral — all approaches reach zero-alloc steady state. The evidence
favours the cell-grid core; cross-language calibration (M3) confirms the absolute
numbers before the decision is final.

### 3.2 Loop ownership and API shape

Whether the library owns the event loop (framework-style MVU, as
[Bubble Tea](../../research/tui-libraries/bubbletea.md)) or is a rendering library
the application drives (as [Ratatui](../../research/tui-libraries/ratatui.md),
[libvaxis](../../research/tui-libraries/libvaxis.md)). The
[comparison's recommendation](../../research/tui-libraries/comparison.md#recommended-architecture)
is a library core (app owns the loop) with an **optional** MVU overlay built on
it — `update` enforced `pure`, messages as `SumType` with exhaustive `match!`.
This is an API decision (not a benchmark question); the render benchmark keeps it
open by measuring the renderer independently of any loop.

### 3.3 Update strategy: immediate vs retained vs incremental

Immediate-mode (rebuild each frame) is the survey's recommended default for D
(`@nogc`-friendly, stack-allocated widgets), with retained-mode and
[Nottui](../../research/tui-libraries/nottui.md)-style incremental reactivity as
optional optimization paths — see
[comparison §8](../../research/tui-libraries/comparison.md#recommended-architecture).
Decided alongside 3.2 once the render core is fixed.

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

(Inline image support, previously a natural non-goal, is promoted to a
**requirement** — G1 above — grounded in Notcurses and libvaxis.)

## 5. Consumers / traceability

| Consumer                       | Items exercised                                                                               |
| ------------------------------ | --------------------------------------------------------------------------------------------- |
| Live operations-dashboard demo | R1–R2, B1, I1–I3, E1–E2, W2–W4 — the full-screen driver, and the benchmark scene (§ PLAN)     |
| `release`                      | Could adopt E1/W3/W4 for an interactive stage/preflight view (today: line-based `LiveRegion`) |
| `ci`                           | W2 (scrollback of example runs), I3 (resize)                                                  |
| test runner                    | Already consumes the pure producers; a `TestBackend` (B2) would make widget tests golden      |
| `docs`/`examples`              | Every landed widget ships a runnable example (`ci --verify`)                                  |

## 6. Execution

Milestones, dependencies, and the benchmark that resolves §3.1 live in the
[delivery plan](./PLAN.md). Nothing in the library's `libs/tui/src/` is built
ahead of the rendering-core decision; the benchmark harness under
`libs/tui/bench/` is the first thing to land.
