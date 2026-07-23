# `hue` UI architecture — component library (GUI / TUI / HTML)

_**Status:** architecture · researched · **Date:** 2026-07-23 · **Scope:** the
**canvas-first UI component library** hue's interactive widgets are built on —
three render targets (GUI, TUI, HTML), structured in three levels (abstract state
machines · layout containers · widgets). Likely materializes as a reusable
`sparkles:ui` sub-package; hue is the first consumer._

> [!NOTE]
> This is **forward-looking architecture** — every requirement is `researched`
> or `not started`. It names the shape hue's UI should take; where a capability
> already exists ad-hoc in the GUI (the scrollbar's `thumbGeometry`, the
> selection model), that is cited as **precedent to factor out**, not as a
> shipped instance of the library. Status legend and IDs: see the
> [overview](./index.md).

## Design & rationale

hue needs the **same interactive widgets** — scrollbar, notifier popup,
expandable list, buttons, panels, code-block chrome — across three backends: the
raylib [GUI](./gui.md), the [TUI](./tui.md), and [HTML](./feature-requirements.md).
Re-implementing each widget three times (as the GUI does today) does not scale.
The architecture factors them into a shared, **canvas-first** component library:

- **Canvas-first, no native UI components.** Every widget is drawn from
  primitives — rectangles, text, glyphs, lines on a canvas (GUI) or cell grid
  (TUI); markup + CSS on HTML. The library never reaches for an OS toolkit
  (GTK/Qt) or HTML form controls; the backends supply only **draw primitives +
  input events**, and the library owns everything above that. This is what makes
  one widget definition renderable on all three targets.
- **Three levels**, each lower one presentation-independent: abstract state
  machines → layout containers → widgets.
- **`sparkles:ui`.** The library is general; hue is its first consumer and
  migrates its per-backend widgets onto it. It layers on the existing substrate —
  `sparkles:raylib-text` (GUI primitives), `sparkles:tui` (TUI cell grid, see
  [docs/specs/tui](../tui/index.md)), and an HTML emitter.

## Architecture (`UIA`)

| ID   | Requirement                                                                                                                                                                                                                                                                                   | Status                 | Traces to                                                                                          |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------- |
| UIA1 | hue's interactive UI must be built on a **canvas-first component library** with three render targets — GUI (raylib canvas), TUI (cell grid), HTML (markup + CSS) — likely a reusable `sparkles:ui` sub-package.                                                                               | researched/not-started | proposed `sparkles:ui`; `sparkles:raylib-text`; `sparkles:tui`                                     |
| UIA2 | The library must be structured in **three levels** — abstract state machines (`STM`), layout containers (`LAY`), widgets (`WGT`) — each usable independently, each lower level free of presentation.                                                                                          | researched/not-started | `STM*`/`LAY*`/`WGT*` (this doc)                                                                    |
| UIA3 | **No native UI components:** the backends provide only draw primitives (rect / text / glyph / line for canvas & cells; markup + CSS for HTML) and input events; every widget is drawn from those, never an OS/HTML toolkit widget.                                                            | researched/not-started | canvas-first contract                                                                              |
| UIA4 | hue's existing per-backend widgets must be **refactored onto the library** as its first consumers — one definition, three targets: the GUI scrollbar (`SCB`) + TUI scrollbar (`TSB`), selection (`SEL`/`TSL`), the notifier popup (`NTF`), overlay panels (`OVL`), code-block chrome (`COD`). | researched/not-started | [gui.md](./gui.md); [tui.md](./tui.md); [notifier.md](./notifier.md); [overlays.md](./overlays.md) |

## Level 1 — abstract state machines (`STM`)

Presentation-free behavior: the logic of a widget with no idea how it is drawn.

| ID   | Requirement                                                                                                                                                                                                                                                                                            | Status                 | Traces to                                   |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- | ------------------------------------------- |
| STM1 | A state machine must be **fully presentation-independent**: pure logic over abstract input (pointer at an abstract position, wheel, key, resize, focus) → state + derived geometry in **abstract units**; no draw calls, no pixels/cells. It must be testable in isolation (`@safe`, ideally `@nogc`). | researched/not-started | proposed `sparkles:ui` state layer          |
| STM2 | The **scrollbar** is the canonical state machine — `(content, viewport, offset)` → thumb geometry + hover/drag state — generalizing today's GUI `thumbGeometry`/drag logic ([`SCB*`](./gui.md)) and the TUI [`TSB*`](./tui.md) into one presentation-free model.                                       | researched/not-started | precedent: `gui.d` `thumbGeometry` (`SCB*`) |
| STM3 | Other stateful behaviors must be modeled the same way — **selection** ([`SEL`](./gui.md)/[`TSL`](./tui.md)), **popup collapse/expand** ([`NTF2`/`NTF3`](./notifier.md)), **disclosure/list expand** ([`NTF4`](./notifier.md)), focus/hover — each a state machine every target consumes.               | researched/not-started | precedents across `gui.d`; notifier design  |

## Level 2 — layout containers (`LAY`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                       | Status                 | Traces to                                                    |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------ |
| LAY1 | Layout must be provided by **renderer-agnostic containers** (row / column / stack / grid / flex) with a sizing vocabulary (fit / grow / fixed / percent + min / max), producing rectangles in **abstract units** mapped per target to px (GUI), cells (TUI), or CSS lengths (HTML).                               | researched/not-started | proposed `sparkles:ui` layout layer                          |
| LAY2 | The layout model/algorithm must be **chosen from the [UI-layout research catalog](../../research/ui-layout/index.md)** — the surveyed box-flow (Clay), flexbox (Yoga/Taffy), and constraints-down/sizes-up (Flutter) families — decided from that survey, the way the TUI render core was decided by measurement. | researched/not-started | [docs/research/ui-layout](../../research/ui-layout/index.md) |
| LAY3 | One layout pass must be **integer-cell-exact on the TUI** (no sub-cell positions), while allowing sub-pixel on the GUI and CSS lengths on HTML — per-target rounding, one geometry.                                                                                                                               | researched/not-started | `sparkles:tui` cell grid; `sparkles.base.text` widths        |

## Level 3 — widgets (`WGT`)

Flutter-like functional composition, with the door held open for three render
modes.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                          | Status                 | Traces to                                                          |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------ |
| WGT1 | Widgets must follow a **Flutter-like functional model** — a pure `view(state) -> Widget` builds a widget tree from application state; **props are named arguments** ([DIP1030](../../guidelines/code-style.md)); widgets compose layout containers (`LAY`) + state machines (`STM`) + draw primitives.                                                                                               | researched/not-started | proposed `sparkles:ui` widget layer                                |
| WGT2 | The widget tree must be **render-mode-agnostic**, interpretable by three modes: **SSG** (serialize to HTML + CSS, with a _tiny JS runtime only when_ a behavior can't be pure-CSS), **immediate mode** (walk + draw per frame — the GUI loop, Dear-ImGui/egui style), and **retained mode** (keep + diff the tree — the `sparkles:tui` 2-D cell-grid compositor, [docs/specs/tui](../tui/index.md)). | researched/not-started | [docs/specs/tui](../tui/index.md) (retained); GUI loop (immediate) |
| WGT3 | The **same widget definition must render on all three targets** unchanged; only the primitive backend and the mode interpreter differ (canvas draw · cell diff · HTML serialize).                                                                                                                                                                                                                    | researched/not-started | `TGT*`                                                             |
| WGT4 | Interactivity must degrade per target: HTML prefers **pure CSS** (`:hover` / `<details>` / `:checked` — hue's established no-JS doctrine for twoslash/notifier HTML) and adds JS only when unavoidable; GUI/TUI drive the `STM` state machines from input events.                                                                                                                                    | researched/not-started | notifier/twoslash HTML doctrine                                    |

## Render targets & modes (`TGT`)

| ID   | Requirement                                                                                                                                                                | Status                 | Traces to                                             |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ----------------------------------------------------- |
| TGT1 | **GUI target** — draws widgets to the raylib canvas via `sparkles:raylib-text` primitives (`drawText`/`drawSolid`/`drawBox`); no native OS widgets; immediate or retained. | researched/not-started | `sparkles:raylib-text`; [gui.md](./gui.md)            |
| TGT2 | **TUI target** — renders widgets to the `sparkles:tui` 2-D cell-grid compositor (retained/diff), with grapheme-correct cell widths from `sparkles.base.text`.              | researched/not-started | [docs/specs/tui](../tui/index.md); [tui.md](./tui.md) |
| TGT3 | **HTML / SSG target** — serializes the widget tree to HTML + CSS; interactivity is pure-CSS where possible, a tiny JS runtime only when a widget's behavior requires it.   | researched/not-started | `app.d` HTML branch; `WGT4`                           |

## Milestones

| Milestone | Scope                                                                             | Status          | Requirements   |
| --------- | --------------------------------------------------------------------------------- | --------------- | -------------- |
| U0        | Research grounding (UI-layout catalog; the `sparkles:tui` render-core decision)   | done (research) | `LAY2`, `TGT2` |
| U1        | Level 1 — factor the scrollbar (then selection, popup) into presentation-free SMs | not started     | `STM*`         |
| U2        | Level 2 — pick + implement the layout model from the UI-layout research           | not started     | `LAY*`         |
| U3        | Level 3 — the `view(state) -> Widget` model + immediate/retained/SSG interpreters | not started     | `WGT*`, `TGT*` |
| U4        | Port hue's GUI/TUI/HTML widgets onto `sparkles:ui`                                | not started     | `UIA4`         |

## Relationship to existing sparkles

| Piece                                                          | Role in the component library                                              |
| -------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `sparkles:raylib-text` (`drawText`/`drawSolid`/`drawBox`)      | GUI target draw primitives (`TGT1`)                                        |
| `sparkles:tui` ([docs/specs/tui](../tui/index.md))             | TUI cell-grid compositor + input; retained-mode substrate (`TGT2`, `WGT2`) |
| [`docs/research/ui-layout`](../../research/ui-layout/index.md) | grounds the Level-2 layout choice (`LAY2`)                                 |
| `sparkles:core-cli` `ui.{box,table,tree,meter,…}`              | shipped static producers — candidate widget bodies / renderers             |
| `sparkles.base.text` (grapheme/width/wrap)                     | cell-width authority for `LAY3`/`TGT2`                                     |
| **proposed `sparkles:ui`**                                     | the new library these compose into                                         |

→ [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [Notifier](./notifier.md) · [Overlays](./overlays.md) · [Overview](./index.md)
