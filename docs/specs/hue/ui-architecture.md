# `hue` UI architecture — building on `sparkles:ui`

_**Status:** partial · **Date:** 2026-08-05 · **Scope:** how hue consumes the
canvas-first UI toolkit — which of hue's visuals are widgets, which are still
hand-written per backend, and the port that closes the gap._

> [!IMPORTANT]
> **The library-level architecture has moved.** This page originally proposed a
> reusable component library; that library now exists as
> [`sparkles:ui`](../ui/index.md) and is specified in its own tree. The
> requirement areas that used to live here are now:
>
> | Was here | Now specified in                                |
> | -------- | ----------------------------------------------- |
> | `STM*`   | [ui/state-machines.md](../ui/state-machines.md) |
> | `LAY*`   | [ui/layout.md](../ui/layout.md)                 |
> | `WGT*`   | [ui/widgets.md](../ui/widgets.md)               |
> | `TGT*`   | [ui/backends.md](../ui/backends.md)             |
>
> Area mnemonics and numbering are preserved, so existing cross-references read
> the same. **This page keeps only hue's own consumption requirements (`UIA`).**

## Design & rationale

hue needs the same interactive visuals — scrollbars, headers, gutters, popups,
selection, code-block chrome, trees — across the raylib [GUI](./gui.md), the
[TUI](./tui.md), and [HTML](./feature-requirements.md). It currently implements
about thirty distinct visual components, of which **six** go through the toolkit;
the rest are written once per backend, and have measurably diverged: two
scrollbars with different thumb formulas scroll the same document differently,
and the copy affordance confirms success two different ways.

The resolution is not more shared helpers but the toolkit's contract: **hue
builds a widget tree and owns no rendering.** What remains in hue is argument
parsing, document loading, the syntax pipeline, input handling, and its views.

Two decisions shape the port beyond a mechanical rewrite:

- **hue has no rendering modes.** One behavior, three backend _flavors_. Content
  kinds compose the way tree-sitter injections compose grammars — a markdown
  document may embed a richer code block, and that block's documentation popups
  render through the same markdown view. That requires views to be re-entrant,
  which a flat line list cannot be. See [Transformer pipeline](./pipeline.md) and
  [`WGT2`](../ui/widgets.md).
- **A directory opens the [file explorer](./tree-view.md)**, not a bespoke index
  view; the static gallery becomes its HTML flavor.

## hue's consumption (`UIA`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Status                                                                                                                                                                                                                                                                                                                    | Traces to                                                                                        |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| UIA1  | hue's interactive UI must be built on the **canvas-first toolkit** [`sparkles:ui`](../ui/index.md), across the GUI, TUI and HTML targets.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | partial                                                                                                                                                                                                                                                                                                                   | `sparkles:ui`; twoslash overlay in `gui.d`/`twoslash_tui.d`                                      |
| UIA2  | hue must contain **no rendering code of its own** — no per-backend painters, no backend-specific chrome. Anything hue draws that the toolkit lacks is a missing widget, to be added there and consumed here.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | **partial** — the _views_ are toolkit trees (`28ff3dfe`) and the popup signature is resolved spans (no overpaint), but _chrome_ is not: hue still hand-paints 21 sites, 13 in the GUI and 8 in the TUI. They are ~6 chrome elements implemented **twice** — see the pairing below and [`HUE-O2`](./open-issues.md#hue-o2) | [ui/widgets.md](../ui/widgets.md) `WGT7`+                                                        |
| UIA3  | hue must not reach for native OS or HTML toolkit widgets on any target; every visual comes from toolkit primitives.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | full                                                                                                                                                                                                                                                                                                                      | canvas-first contract                                                                            |
| UIA4  | hue's existing **per-backend widgets must be ported** onto the toolkit — one definition, three targets — and their predecessors deleted in the same change, so no third copy is created.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | partial — see the inventory (each swap deleted its predecessor); the remaining app-owned paint is tracked by [`HUE-O2`](./open-issues.md#hue-o2)                                                                                                                                                                          | see the port inventory below                                                                     |
| UIA5  | hue's frame-loop state must be a **single owned view-state value** driving the toolkit's state machines, replacing peer locals and mutating closures.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | partial — `ViewerModel` owns the document pipeline, but the GUI still has peer state groups and captured transitions ([`HUE-O1`](./open-issues.md#hue-o1))                                                                                                                                                                | [ui/principles.md](../ui/principles.md) `PRN1`, `PRN7`                                           |
| UIA6  | hue's views must be **re-entrant**, so any content kind can embed another at any depth and the same view serves both the top-level document and a nested one.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | full (`bc3e1f17`) — `viewMarkdownInto` / `viewTwoslashDocument` / fence sub-views / popup JSDoc, all re-entrant with a depth budget                                                                                                                                                                                       | [ui/widgets.md](../ui/widgets.md) `WGT2`; [pipeline.md](./pipeline.md) `XFM3`                    |
| UIA7  | **No direct `import raylib` in `apps/hue`.** Every raylib call sits behind a `sparkles:ui-raylib` seam — input via `RaylibEvents`, painting via `RaylibCanvas`, window/lifecycle via a window seam. A grep for `import raylib` under `apps/hue/` is the test.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | partial — 1 file (`gui.d`), **full** — `grep -rn 'import raylib' apps/hue/src/` is empty; all four seams closed                                                                                                                                                                                                           | `sparkles:ui-raylib`; [ui/backends.md](../ui/backends.md) `TGT6`                                 |
| UIA8  | **No direct `sparkles:tui` use in `apps/hue`.** The cell backend is reached through `sparkles:ui-tui` and the shared `sparkles:input` vocabulary, not through `Grid`/`CellStyle`/`Terminal` directly — the same rule as `UIA7`, on the other target. **full** — `grep -rn 'import sparkles.tui' apps/hue/src/` is empty. The terminal, its input reader and its lifecycle are behind `ui_tui.TerminalSession`; the cell vocabulary (`Grid`/`Cell`/`CellStyle`/`Color`) is re-exported by `sparkles.ui_tui`, so an application never names `sparkles:tui` to describe a cell. What remains is _hand-painting_ rather than _naming_ — 8 production paint sites beside 16 `paintGrid` calls — which is [`UIA2`](#hues-consumption-uia), a separate requirement (most other `Grid` uses are reads: ~12 in unittests, plus one HTML serializer) | `sparkles:ui-tui`; `sparkles:input`                                                                                                                                                                                                                                                                                       |
| UIA9  | **The editor component.** The diff write wave ([`DST5`](./diff-view.md) inline editing, [`DCM3`](./diff-view.md) suggestion authoring, [`CFV4`](./diff-view.md) conflict resolution) requires a **multi-line editable-text widget** the toolkit does not have — hue's only text input today is the single-line search field. Needed: a cursor/insert/delete/undo **state machine** (level 1), edit-aware **layout** (level 2), and per-backend input — IME on desktop GUI, soft keyboard on Android, terminal input in the TUI. Specced: [docs/specs/ui/editor.md](../ui/editor.md) (`EDT`/`EDI`/`EDR`/`EDU`, milestones E0–E4), scheduled **before** diff-view `W1`/`W2` — the write wave's critical path.                                                                                                                                | not started                                                                                                                                                                                                                                                                                                               | proposed `sparkles:ui` editor component; [diff-view.md](./diff-view.md) `DST5`/`DCM3`/`CFV4`     |
| UIA10 | **hue must not own a frame loop.** Backend selection, the window/font command line and setup, the event loop and the platform errands (pointer shape, clipboard, out-of-band writes, title) come from [`sparkles:ui-app`](../ui-app/index.md). `UIA7`/`UIA8` removed the backend _names_ from hue; this removes the backend _lifecycle_, and is what makes hue's frame loop unit-testable through the host's recording target.                                                                                                                                                                                                                                                                                                                                                                                                             | not started                                                                                                                                                                                                                                                                                                               | [ui-app](../ui-app/feature-requirements.md) `HST`/`BKD`/`CLI`; [P2.B](../ui-app/PLAN.md#phase-2) |

## Backend encapsulation (`UIA7`/`UIA8`) — census and why now

[`docs/research/window-system-integration/`](../../research/window-system-integration/index.md)
is research-first design toward a replacement for raylib, at least for the
**event loop and input**. That makes encapsulation the load-bearing prerequisite:
a backend swap is cheap exactly to the degree that `apps/hue` cannot tell which
backend it has, and expensive in proportion to how many raylib calls it makes
directly.

So the immediate goal is not a new abstraction — it is **removing hue's ability
to name raylib at all**.

> [!IMPORTANT]
> This is also why a `sparkles:android` platform package is **deferred**. It
> would be built against the very window/input seam the redesign is about to
> replace, so it would be re-cut immediately. The Android-specific modules stay
> in `apps/hue` until the new seam exists — the cheaper order.

### Where raylib is reached today

One file imports it — `apps/hue/src/gui.d` — in ~94 calls across four distinct
seams, which is what makes this tractable rather than a rewrite:

| Seam                     |      Calls | Representative                                                                                                                                                                                                           | Target                                                                           |
| ------------------------ | ---------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| ~~**Input**~~            | ~~53~~ → 0 | ~~`IsKey*`, `IsMouse*`, `GetMouse*`, `GetTouch*`, `GetChar*`~~ — **DONE**: one `RaylibEvents.poll` per frame, folded by `frame_input.foldFrame`; hue's duplicate `GestureRecognizer` and the interim `drainKeys` deleted | `sparkles.ui_raylib.events`; `apps/hue/src/frame_input.d`                        |
| ~~**Painting**~~         | ~~17~~ → 0 | ~~`DrawRectangle` ×13~~ — **DONE**: every chrome fill goes through `RaylibCanvas.fillPixels`, verified **pixel-identical** against xvfb screenshots                                                                      | `RaylibCanvas`; widget-ising the chrome is still [`UIA2`](#hues-consumption-uia) |
| ~~**Window/lifecycle**~~ | ~~21~~ → 0 | ~~`InitWindow`, `SetWindow*`, `TakeScreenshot`, `GetScreen*`, `BeginDrawing`/`EndDrawing`/`ClearBackground`/`EndScissorMode`~~ — **DONE**: `ui_raylib.Window` (RAII) + `traceLogTo`; pixel-identical                     | `sparkles.ui_raylib.window`                                                      |
| ~~**Platform bits**~~    |  ~~9~~ → 0 | ~~`SetMouseCursor`, `SetClipboardText`, `GetFrameTime`~~ — **DONE**: `Window.pointerShape`/`clipboard`/`frameSeconds`                                                                                                    | `sparkles.ui_raylib.window`                                                      |

The **painting** row is the one worth naming, because it is `UIA2` restated as
a number: thirteen `DrawRectangle` calls are thirteen pieces of chrome the
toolkit should own. They are not a porting problem — the canvas already has
fills and a clip stack.

### The TUI side (`UIA8`)

**`UIA8` is met**: `grep -rn 'import sparkles.tui' apps/hue/src/` is empty.

The split predicted here held exactly, and all three parts are now resolved:

- **The rename** — `sparkles.tui.input` re-exports `sparkles:input`, so those
  four imports were the shared vocabulary reached by an indirect path. Now
  imported directly. Done.
- **The lifecycle** — `Terminal`, `TerminalOptions` and `PosixEvents` are behind
  `sparkles.ui_tui.TerminalSession`, the cell mirror of `ui_raylib.Window`: raw
  mode, surface size, input, present, and the out-of-band writes (OSC 52
  clipboard, OSC 22 pointer shape) that must bypass the cell diff. Two of the
  three files were importing these types **without using them** — dead since the
  workspace took ownership. Done.
- **The vocabulary** — `Grid`/`Cell`/`CellStyle`/`Color` are **re-exported by
  `sparkles.ui_tui`**, so an application describes a cell without naming
  `sparkles:tui`. Re-exported rather than wrapped: they are `sparkles:tui`'s
  types, and a wrapper would create a second spelling of one concept plus a
  conversion at every crossing. The adapter adopting the vocabulary it paints in
  is the same direction as `TGT6`.

  This replaced four separate comments in `apps/hue` that _explained_ why the
  direct import was tolerable. An apology at each site is the signature of a
  seam that should exist and doesn't: the fix is to move the export, not to
  justify the import. Only the leaf `sparkles.tui.cell` is re-exported — never
  the `sparkles.tui` package module, which would put the POSIX terminal back
  into every consumer's closure (the Android break described below).

- **What is left is painting, not naming** — hue still fills cells by hand, and
  this is `UIA2`, a different requirement. It is **smaller than a grep
  suggests**, and the distinction matters because the three kinds of use want
  three different answers:

  | Use                          |  Count | Disposition                                                               |
  | ---------------------------- | -----: | ------------------------------------------------------------------------- |
  | Production paint sites       |  **8** | `UIA2` — chrome that should be widgets; enumerated below                  |
  | Grid → HTML serializer       | 1 loop | a _reader_, not painting; belongs beside `sparkles.ui.interp.html`        |
  | `g[x, y]` reads in unittests |    ~12 | not a violation at all — a test that verifies painting must inspect cells |

  The eight, since a count alone is what let this be miscounted twice:

  | Site                                    | Call              | Paints                    |
  | --------------------------------------- | ----------------- | ------------------------- |
  | `tui.d:406`, `explorer.d:522`           | `fillRect`        | pane background           |
  | `workspace.d:138`, `twoslash_tui.d:232` | `clearTo`         | whole-surface page fill   |
  | `twoslash_tui.d:293`                    | `fill`            | status-bar row            |
  | `workspace.d:156`, `twoslash_tui.d:294` | `putText`         | pane divider, status text |
  | `tui.d:450`                             | `[x, y].style.bg` | selection tint            |

  So the eight paint sites are the same shape as the GUI's 13 `DrawRectangle`,
  and take the same fix. `TerminalSession` hands the grid out deliberately
  rather than by omission, and folding it in _is_ that change.

  What closing them costs — and the fact that the GUI hand-paints the _same_
  chrome — is in
  [The chrome that is still hand-painted](#the-chrome-that-is-still-hand-painted-uia2),
  since it is one problem with two backend halves rather than a TUI loose end.

### The chrome that is still hand-painted (`UIA2`)

`UIA2` was recorded as **full** because the _views_ became toolkit trees. The
_chrome_ did not, and the row is now corrected. What makes this worth its own
section is not the count but the shape: the 21 sites are roughly **six chrome
elements, each implemented twice** — once per backend.

| Chrome element         | GUI                  | TUI                                     |
| ---------------------- | -------------------- | --------------------------------------- |
| viewer pane background | `gui.d:1882`         | `tui.d:406`                             |
| tree pane background   | `gui.d:2137`         | `explorer.d:522`                        |
| pane divider           | `gui.d:2138` (1 px)  | `workspace.d:156` (`│`)                 |
| status / bottom bar    | `gui.d:2268`, `2279` | `twoslash_tui.d:293` + `294`            |
| selection fill         | `gui.d:1982`         | `tui.d:450` — **they disagree, below**  |
| page fill              | the window clear     | `workspace.d:138`, `twoslash_tui.d:232` |

GUI-only remainders: the gutter band (`1888`), the header bar and its hairline
(`2239`/`2240`), the toolbar separator (`2255`), the tree status bar (`2194`),
and the undercurl dashes (`2102`) — the last genuinely sub-cell, 2 px wide, so
it has no cell counterpart and stays a backend detail.

**This is exactly the divergence `UIA2` exists to prevent.** The rationale at the
top of this page cites two scrollbars whose thumb formulas scroll the same
document differently; a divider drawn as a 1 px rule on one backend and a `│`
column on the other is the same defect earlier in its life. The pairing is how
to sequence the work — one element at a time, deleting **both** predecessors in
the same change (`UIA4`).

#### Pairing the sites found two defects, not just duplication

The table above was first written by matching sites that _looked_ alike. Two of
those pairings were wrong, and correcting them is the most useful thing the
exercise produced — because what the divergence hides is not duplicated code but
**different behaviour**:

- **Selection renders at a different granularity on each backend.**
  `gui.d:1982` tints through `selectionRects`, which derives char-precise rects
  and whose own comment says the toolkit derives them "once for any backend".
  `tui.d:450` ignores that and tints **whole rows** —
  `foreach (x; 0 .. width - 1)` for every line in `[lo, hi]`. Select half a line
  and the GUI shows half a line; the TUI shows all of it. This is the scrollbar
  problem the rationale at the top of this page describes, except it is not
  hypothetical and it is shipping.

- **Search-match highlighting exists only in the GUI.** `gui.d:2022` paints
  `vm.matchRects` with two tints (the current match brighter). The TUI has no
  `matchRects` at all. It was mistaken for the selection pairing because both
  are "a tinted rect over text"; they are different features, and the TUI is
  simply missing one.

So `UIA2` here is not cosmetic tidying. Routing both through one widget is what
makes the backends agree, and the second finding means one of them gains a
feature rather than merely changing how it draws.

The remaining pairings are matched by role and are **approximate until each is
done** — the two corrections above are exactly what happens when a pairing is
assumed rather than read.

#### It is not six new widgets — it is a geometry decision

The toolkit already has the pieces: `WidgetKind.box` is a leaf rectangle with a
slot background, `line` is a stroked rule, and `chrome.d` already ships
`headerBar`, `actionBar`, `gutter`, `scrollbar` and `scrollView`. The display
list already carries `fillRect`/`line`/`textRun`, and both backends already
interpret them. So this is hue **consuming** what exists, not `sparkles:ui`
growing six components.

What blocks it is one property: **`Point` and `Size` are `int` — whole cells**
(`geometry.d`). hue's GUI chrome is deliberately _sub-cell_, and that is not an
accident of implementation but the reason `RaylibCanvas.fillPixels` takes pixels
at all. That splits the six cleanly:

| Cell-aligned — can be widget-ised today | Sub-cell — needs a toolkit decision first   |
| --------------------------------------- | ------------------------------------------- |
| viewer pane background                  | pane divider (1 px rule, `gui.d:2138`)      |
| tree pane background                    | header hairline (`cellH - 1`, `gui.d:2240`) |
| page fill                               | undercurl dashes (2 px, `gui.d:2102`)       |
| status / bottom bar                     | toolbar separator (`gui.d:2255`)            |
| selection fill                          |                                             |

For the right-hand column the choice is real and should be made once, not per
site: either the toolkit's geometry gains a sub-cell notion, or those elements
quantise to whole cells and the GUI's appearance changes — a 1 px divider
becoming a full column is visible. Neither is obviously right, which is exactly
why it is a decision rather than a refactor, and why the left-hand column should
not wait on it.

**Correction (2026-08-06): the left-hand column is smaller than it looks.**
Read site by site, the surface-covering fills — the two pane backgrounds, the
page fill, and the bottom-anchored bars — are **not** cell-aligned in general.
They are anchored to the window's edges (`screenH - cellH`) or must cover it
entirely, and a desktop window is resizable, so `screenH % cellH` is non-zero
the moment a user drags it. Expressed as cell rects they would leave an
unpainted sliver along the bottom and right, or move a bar off the edge. Those
fills are legitimately pixel-space: a background covers the **surface**, which
is not the same object as the grid. What did convert cleanly is the
content-anchored pair — the selection tint and the search-match rects — whose
origins are the gutter and the first document row, both whole-cell multiples by
construction.

**Decided (2026-08-06): the display list gains a sub-cell op.** `OpKind.rule`
names an **edge** of a rect (`RuleEdge`) rather than a pixel count, so the
toolkit keeps whole-cell geometry and no device units, while a pixel canvas
draws the thinnest rule its display has there. It is an _optional_ canvas
primitive: `RaylibCanvas.rule` honours it exactly, and a canvas without one
falls back to the cell-aligned line along the same edge — visible in the same
place at the coarsest honest resolution, never silence. That makes the
right-hand column expressible without changing how the GUI looks, and it is
the case where the cell backend **gains** the element rather than losing it.

#### What each side costs

Not symmetric, and worth knowing before starting:

- **TUI** — seven of the eight map straight onto `GridCanvas` primitives
  (`fillRect` absorbs `fillRect`/`clearTo`/`fill`; `textRun` absorbs `putText`).
- **The eighth needs a decision.** `tui.d:450` sets `.style.bg` on cells that
  already hold glyphs — a **tint** — where `GridCanvas.fillRect` is opaque by
  design, pinned by its own `opaqueFillHidesWhatItCovers` test. Either the canvas
  gains a background-only primitive, or selection paints _before_ text as the GUI
  already does. The second needs no new primitive and makes the two backends
  agree on paint order, which is the point of the exercise.
- **GUI** — `fillPixels` takes pixels deliberately (a 1 px divider, a
  `cellH - 1` hairline, 2 px undercurl dashes are not cell-aligned), so a widget
  replacing one must either express sub-cell geometry or accept being quantised.
  That constraint is why `fillPixels` exists and why its own docs say a growing
  caller count means a widget is missing.

### Order

**All four seams are closed.** Painting, window/lifecycle, the platform bits
and input — each verified pixel-identical against xvfb screenshots, which is
what made moving them safe without a running device.

Three symbols outlived the calls and are worth naming, because they are where
the last `import raylib` actually lived: `Color` (only to feed `drawText`, now
an additive `RgbColor` overload in `sparkles:raylib-text`), `Rectangle` (popup
geometry, now a local `PixelRect` — `ui.Rect` is integer cells and cannot
express a sub-cell edge), and `TraceLogLevel` (the log-level tag, now
`ui_raylib.traceLevelTag`, since the numbering is the backend's).

**Input is what remains**, and it is deliberately last here even though the
research replaces it first: it is entangled with the gesture recogniser
(`RaylibEvents` owns one, and hue owns another, so they must move together),
and it is the half with a tested oracle in `keymap.d`, so it is the one that
can afford to wait.

The window seam was kept **deliberately thin** — it renames rather than
abstracts. Its one piece of judgement is `Window.fullscreenSupported`, which
turns a known Android defect (the undecorate/reposition dance running where the
surface already _is_ the screen) into something the caller cannot do by
accident. When the research concludes, this seam is what gets re-cut, and
`apps/hue` should not notice.

## Port inventory

The components hue implements per backend today, and the toolkit widget each
becomes. "Copies" counts the independent implementations being collapsed.

| hue component                         | Copies | Becomes                                                            | Status                                                                                                                  |
| ------------------------------------- | ------ | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Popup / hover card / below-line block | 1      | shipped — the toolkit's popup and panel containers                 | full                                                                                                                    |
| Diagnostic squiggle, highlight tint   | 1      | shipped — stroked line, filled rect                                | full                                                                                                                    |
| Preview line painter                  | 3      | the document view over rich text                                   | full (`155ce512`) — the composable markdown view, all three sinks; the flattener deleted                                |
| Header / status bar                   | 6      | [`WGT17`](../ui/widgets.md)                                        | full — `headerBar` on every backend                                                                                     |
| Scrollbar                             | 2      | [`WGT10`](../ui/widgets.md) over [`STM2`](../ui/state-machines.md) | full — one `scrollbarThumb`/`draggedTo` formula                                                                         |
| Line-number gutter                    | 4      | [`WGT18`](../ui/widgets.md)                                        | partial — one derivation per view (`srcLineOf` over the identity channel in the GUI preview); the raw views keep theirs |
| Selection highlight                   | 3      | [`STM3`](../ui/state-machines.md)                                  | full (`23fab77e`) — `Selection`/`selectionRects` over the identity channel                                              |
| Table                                 | 1      | [`WGT11`](../ui/widgets.md) over the track sizer                   | full — the track sizer + source-anchored cell keys (2-D selection preserved)                                            |
| Code-block chrome ([`COD`](./gui.md)) | 1      | panel + gutter + button                                            | full — the fence panel + header band through the markdown view; in-panel line numbers are a recorded fidelity gap       |
| Copy button ([`COD3`](./gui.md))      | 2      | [`WGT15`](../ui/widgets.md) + [`STM6`](../ui/state-machines.md)    | full (`8b5949a8`) — the fence header band, source-anchored ids, one feedback behavior                                   |
| Text-input bar (search / goto)        | 2      | [`WGT14`](../ui/widgets.md)                                        | partial — TUI status-bar input is a widget bar; the GUI input line is still drawn directly                              |
| Toast                                 | 1      | [`WGT16`](../ui/widgets.md)                                        | partial — `Timeline`-driven, still painted directly in the GUI                                                          |
| Document index view                   | 2      | the [explorer](./tree-view.md) — [`WGT12`](../ui/widgets.md)       | partial (`d47a0d01`) — the TUI explorer; the GUI keeps its list                                                         |
| Theme picker list                     | 1      | [`WGT13`](../ui/widgets.md)                                        | full — live ←/→ theme cycling in both interactive backends (previewer.d deleted)                                        |
| Box / frame drawing                   | 3      | panel decoration, per-backend degradation                          | full — panel decorations through each canvas                                                                            |

> [!NOTE]
> The copy counts are the argument. A header bar written six times, twice within
> the same file, is not a styling problem — it is the absence of a shared
> definition, and every divergence between the copies is the interface reporting
> the same state two different ways.

## Milestones

| Milestone | Scope                                                                           | Status                      | Requirements                                            |
| --------- | ------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------- |
| U0        | Research grounding (UI-layout catalog; the `sparkles:tui` render-core decision) | done (research)             | [`LAY2`](../ui/layout.md), [`TGT2`](../ui/backends.md)  |
| U1        | Level 1 — presentation-free state machines                                      | partial                     | [`STM*`](../ui/state-machines.md)                       |
| U2        | Level 2 — the layout model, decided and implemented                             | partial                     | [`LAY*`](../ui/layout.md)                               |
| U3        | Level 3 — the widget model + immediate / retained / SSG interpreters            | partial                     | [`WGT*`](../ui/widgets.md), [`TGT*`](../ui/backends.md) |
| U4        | Port hue's GUI/TUI/HTML widgets onto the toolkit                                | partial — see the inventory | `UIA4`                                                  |
| U5        | Move both hosts' loops onto `sparkles:ui-app`                                   | not started                 | `UIA10`                                                 |

The partial statuses are honest about what shipped: the layout model is decided
and a subset implemented; all three interpreters exist; but only the twoslash
overlay is expressed as widgets, one state machine exists and has no consumers,
and hue's own chrome is untouched. `U4` is the work this page tracks.

## Relationship to existing specs

| Piece                                                       | Role                                                                 |
| ----------------------------------------------------------- | -------------------------------------------------------------------- |
| [`sparkles:ui` spec tree](../ui/index.md)                   | the toolkit's own requirements — `STM`/`LAY`/`WGT`/`TGT`/`THM`/`INP` |
| [ui/migration.md](../ui/migration.md) `MIG6`–`MIG10`        | the sequencing of hue's port                                         |
| [gui.md](./gui.md) · [tui.md](./tui.md)                     | the per-backend requirements the port consolidates                   |
| [tree-view.md](./tree-view.md) · [folding.md](./folding.md) | components whose first implementation is the ported one              |
| [pipeline.md](./pipeline.md) `XFM3`                         | the re-entrancy `UIA6` requires                                      |
| [ui-app spec tree](../ui-app/index.md)                      | the host `UIA10` moves hue's loop onto                               |

→ [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [`sparkles:ui`](../ui/index.md) · [Overview](./index.md)
