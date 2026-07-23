# `hue` tab view — Feature Requirements (interactive component)

_**Status:** planned · **Date:** 2026-07-23 · **Scope:** a reusable **tab view**
component — a tab bar + a single visible panel, with an active-tab state machine —
a [`sparkles:ui`](./ui-architecture.md) widget on GUI / TUI / HTML. Initial use
cases: **open files as tabs** and **code groups** (the VitePress markdown
extension)._

> [!NOTE]
> Forward-looking — every row is `not started`. It reuses the same widget/state
> pattern as the [tree/DAG view](./tree-view.md). Status legend and IDs: see the
> [overview](./index.md).

## Design & rationale

The tab view is a **level-3 widget** in the UI component library
([`ui-architecture.md`](./ui-architecture.md) `WGT`): one `view(state) → Widget`
across all three targets, with its parts on the library's levels — an
**active-tab state machine** (level 1, [`STM`](./ui-architecture.md)), a tab-bar +
panel **layout** (level 2, [`LAY`](./ui-architecture.md)), and per-backend
**rendering**. It is the shared component behind two features that would otherwise
hand-roll tabs: the viewer's **open-file tabs** and inline **code groups** in the
markdown preview (see `TBU`).

Its HTML rendering is **pure CSS** (radio inputs + `:checked`, no JS) — which is
exactly how VitePress's own code-group renders, and matches hue's established no-JS
doctrine ([folding](./folding.md) `FLD10`, notifier, twoslash HTML).

## Tab view component (`TAB`)

| ID   | Requirement                                                                                                                                                                              | Status      | Traces to                                      |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------- |
| TAB1 | A tab view must render a **tab bar** (each tab a label + optional icon and close affordance) plus a single visible **content panel**; the active tab selects the panel.                  | not started | proposed `sparkles:ui` tab widget              |
| TAB2 | The **active-tab** selection must be a presentation-free state machine (the [`ui-architecture` `STM`](./ui-architecture.md) level), consumed identically by GUI/TUI/HTML.                | not started | `STM`                                          |
| TAB3 | **Interaction** — click a tab to activate (GUI/TUI SGR mouse); keyboard next/prev + direct select (`[`/`]`, Ctrl-Tab, number keys); a **close** affordance where the adapter enables it. | not started | `gui.d`/`previewer.d` input; [`TIN`](./tui.md) |
| TAB4 | **Overflow** — when tabs exceed the available width, the bar must scroll or provide an overflow affordance (not wrap chaotically); the active tab stays visible.                         | not started | proposed tab-bar overflow                      |
| TAB5 | **Per-tab decorations** must be data-driven — label, icon, modified/close badge — supplied by the use-case adapter (`TBU`), not hardcoded.                                               | not started | adapter-supplied tab view                      |
| TAB6 | Degradation — an empty tab set renders nothing; a single tab may render its panel without a bar (an adapter choice); never a crash.                                                      | not started | totality                                       |

## Per-backend rendering (`TBB`)

| ID   | Requirement                                                                                                                            | Status      | Traces to                    |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------- |
| TBB1 | **GUI** — the tab bar draws on the canvas (labels + active underline/fill), panels swap; mouse hit-test + keys.                        | not started | [gui.md](./gui.md); `TGT1`   |
| TBB2 | **TUI** — the tab bar in cells (labels + separators + active highlight, box-drawing), SGR-mouse click + keys.                          | not started | [tui.md](./tui.md); `TGT2`   |
| TBB3 | **HTML** — **pure-CSS** tabs (radio inputs + `:checked` sibling selectors, no JS — the VitePress code-group idiom), default first tab. | not started | `app.d` HTML branch; `FLD10` |

## Use cases (`TBU`)

Each use case is a thin **adapter** supplying the tabs (labels + panels + which
have a close button) and consuming the shared component.

| ID   | Use case                   | Adapter                                                                                                                                                                                                                                                                                                              | Status      | Traces to                                                                   |
| ---- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------- |
| TBU1 | **Open files as tabs**     | one tab per open file, active = the current file, a **close** button per tab (`TAB3`), overflow-scrolled (`TAB4`); opening a file via [navigation](./navigation.md) `LNK3` adds/activates a tab, closing removes it. Implies a **multi-document** session (the viewer currently opens one file).                     | not started | [navigation.md](./navigation.md) `LNK3`; multi-doc session                  |
| TBU2 | **Code group** (VitePress) | the `::: code-group` container of labeled fences (` ```js [label] `) becomes an **inline tabbed code block** in the preview — a block reserving rows (like a [media block](./media.md) `MDB1` / code block) with a tab bar; first tab default. Requires the markdown model to parse the container + fence `[label]`. | not started | `sparkles:syntax` `md/model.d` (code-group parse); [gui.md](./gui.md) `COD` |

## Milestones

| Milestone | Scope                                                                               | Status      | Requirements            |
| --------- | ----------------------------------------------------------------------------------- | ----------- | ----------------------- |
| B0        | Tab component (bar + active-tab state + panel swap) — GUI + TUI                     | not started | `TAB1`–`TAB3`, `TBB1/2` |
| B1        | Open-files tabs: multi-document session + navigation integration + close + overflow | not started | `TBU1`, `TAB4`–`TAB6`   |
| B2        | Code-group markdown parsing + inline tabbed code block                              | not started | `TBU2`                  |
| B3        | HTML pure-CSS tabs                                                                  | not started | `TBB3`                  |

## Relationship to existing specs

| Piece                                                        | Role                                                        |
| ------------------------------------------------------------ | ----------------------------------------------------------- |
| [ui-architecture.md](./ui-architecture.md) `WGT`/`STM`/`LAY` | the widget/state/layout levels this component instantiates  |
| [tree-view.md](./tree-view.md)                               | sibling `sparkles:ui` widget (same pattern)                 |
| [navigation.md](./navigation.md) `LNK3`                      | opening files feeds the open-files tabs (`TBU1`)            |
| [gui.md](./gui.md) `COD`; `sparkles:syntax` `MdDoc`          | code-block rendering + the code-group parse (`TBU2`)        |
| [media.md](./media.md) `MDB1`                                | the "block reserving rows in the preview" analog for `TBU2` |

→ [UI architecture](./ui-architecture.md) · [Tree / DAG view](./tree-view.md) · [Navigation](./navigation.md) · [Overview](./index.md)
