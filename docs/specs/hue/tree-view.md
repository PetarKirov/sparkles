# `hue` tree / DAG view — Feature Requirements (interactive component)

_**Status:** planned · **Date:** 2026-07-23 · **Scope:** a reusable interactive
**tree and DAG view** component — a [`sparkles:ui`](./ui-architecture.md) widget
rendered on GUI / TUI / HTML. TUI design reference:
[`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)'s **explorer**. Use
cases: file explorer, tree-sitter inspector, file outline, git graph, dependency
graph._

> [!NOTE]
> Forward-looking — every row is `not started`. Substrate: `sparkles:core-cli`
> already ships a **static** tree producer (`ui.tree`) and the
> [tree-view case study](../../research/tui-libraries/tree-view-case-study.md)
> grounds the interactive design; this component adds interaction (expand/collapse
> state, cursor, mouse, filtering) and **DAG** support. Status legend and IDs: see
> the [overview](./index.md).

## Design & rationale

The tree/DAG view is a **level-3 widget** in the UI component library
([`ui-architecture.md`](./ui-architecture.md) `WGT`): one `view(state) → Widget`
definition, rendered on all three targets. Its structure maps onto the library's
levels:

- **State machine** (level 1, [`STM`](./ui-architecture.md)) — expand/collapse of
  nodes (the same collapse model as [content folding](./folding.md) `FLD2`),
  cursor/selection, and viewport. Presentation-free.
- **Layout** (level 2, [`LAY`](./ui-architecture.md)) — indented rows for trees;
  **rail/lane** or **layered** placement for DAGs.
- **Rendering** — per-node icon + label + decorations, indent guides, edges;
  painted per backend (canvas / cells / HTML).

It is the shared component behind several hue features that today would each
hand-roll a tree: the [tree-sitter inspector overlay](./overlays.md) (`TSI`), a
file outline, and more (see `TVU`). The `core-cli` `ui.tree` static renderer is
the precedent to generalize.

## Tree view component (`TRV`)

Modeled on snacks.nvim's explorer for the TUI idiom.

| ID   | Requirement                                                                                                                                                                                                                                  | Status      | Traces to                                              |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------ |
| TRV1 | A **tree view** must render a hierarchical node model as indented rows: each node an icon + label + optional trailing decorations/badges, with **indent guides** and an expand/collapse marker on parent nodes.                              | not started | proposed `sparkles:ui` tree widget; `core-cli.ui.tree` |
| TRV2 | **Expand/collapse** must be a presentation-free state machine (shared with [folding](./folding.md) `FLD2` / [`STM`](./ui-architecture.md)); collapsing hides a subtree, expanding reveals it; expand-all / collapse-all / expand-to-level.   | not started | `STM`; `FLD2`                                          |
| TRV3 | **Navigation** — a cursor moves by visible row (↑/↓, `j`/`k`); ←/`h` collapses (or moves to parent), →/`l` expands (or enters first child); Home/End, page scroll; **mouse** click selects, click on the marker toggles (GUI/TUI SGR mouse). | not started | `gui.d`/`previewer.d` input; [`TIN`](./tui.md)         |
| TRV4 | **Lazy children** — a node's children may be produced on demand (for large or filesystem-backed trees), so expansion, not construction, drives cost.                                                                                         | not started | proposed node-provider callback                        |
| TRV5 | **Filtering / live search** — an incremental filter must narrow visible nodes (matching nodes + their ancestors kept), snacks-explorer style.                                                                                                | not started | reuse [`FND`](./gui.md) input model                    |
| TRV6 | **Per-node decorations** must be data-driven — icon (Nerd-Font, with the [`FNT8`](./gui.md) tofu caveat), label style, and trailing badges (e.g. git status, counts) — supplied by the use-case adapter (`TVU`), not hardcoded.              | not started | adapter-supplied node view                             |
| TRV7 | **Selection** must yield a stable node identity / payload to the caller (e.g. a file path, a CST node, a commit) so actions (open, reveal, jump) act on it.                                                                                  | not started | node payload contract                                  |

## DAG support (`DAG`)

Trees are the common case; several use cases are **directed acyclic graphs**
(shared children, multiple parents) that a strict tree can't express.

| ID   | Requirement                                                                                                                                                                                                                      | Status      | Traces to                         |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------- |
| DAG1 | The model must accept a **DAG** (a node reachable by multiple parents): the same node shown once with in/out edges, not duplicated per path; a cycle guard must degrade a mis-supplied cyclic graph safely.                      | not started | proposed graph model              |
| DAG2 | A **rail/lane** renderer must draw commit-graph-style edges — the `│ ├ ╯ ╰ ┬` lane glyphs of `git log --graph` — for linear-ish DAGs (git graph); reusing native box-drawing (no procedural `BOX` in the TUI).                   | not started | git-graph lane layout             |
| DAG3 | A **layered** (Sugiyama-style) node-link renderer must place a general DAG in ranks with routed edges — for dependency graphs; may be **GUI-first** (the canvas suits free node-link), with a rail/indented fallback on the TUI. | not started | layered graph layout (GUI canvas) |
| DAG4 | The renderer choice (indented-tree-with-backedges · rail/lane · layered node-link) must be **per use case**; the model is one, the presentation is selected by the adapter (`TVU`).                                              | not started | `TVU` adapter selects renderer    |

## Use cases (`TVU`)

Each use case is a thin **adapter** supplying the node model + per-node
decorations + renderer choice; the component is shared.

| ID   | Use case                     | Model → adapter                                                                                                                                | Status      | Traces to                                               |
| ---- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------- |
| TVU1 | **File explorer**            | filesystem tree (lazy dirs `TRV4`), file-type + git-status icons/badges (`TRV6`), open/reveal actions (`TRV7`) — the snacks-explorer use case. | not started | proposed FS adapter; `sparkles:build-primitives` walker |
| TVU2 | **Tree-sitter inspector**    | the CST as a tree (named/anonymous nodes, field names, S-expression); **renders the [`overlays.md` `TSI`](./overlays.md)** panel.              | not started | `sparkles:tree-sitter` CST; `TSI`                       |
| TVU3 | **File outline**             | document symbols — code structure (functions/classes) from the CST, or headings from `MdDoc` — a jump-to-symbol outline.                       | not started | `sparkles:syntax` CST / `md/model.d`; `FSR3`            |
| TVU4 | **Git graph**                | the commit DAG, rail/lane rendered (`DAG2`); refs/branches as node badges.                                                                     | not started | git adapter → `DAG2`                                    |
| TVU5 | **Dependency graph** (build) | a build-system / module DAG (targets → deps), layered or rail rendered (`DAG3`/`DAG2`).                                                        | not started | build-graph adapter → `DAG3`                            |

## Per-backend rendering (`TRB`)

| ID   | Requirement                                                                                                                                                              | Status      | Traces to                                    |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | -------------------------------------------- |
| TRB1 | **GUI** — canvas rows + indent guides + edges via `sparkles:raylib-text` primitives; mouse hit-test; the layered DAG renderer (`DAG3`) is GUI-first.                     | not started | [gui.md](./gui.md); `TGT1`                   |
| TRB2 | **TUI** — cell rows, box-drawing indent guides + git-rail glyphs (native), SGR-mouse + keys; snacks-explorer parity.                                                     | not started | [tui.md](./tui.md); `core-cli.ui.tree`       |
| TRB3 | **HTML** — a nested `<ul>`/`<details>` tree with **pure-CSS** expand/collapse (no JS — the folding/notifier doctrine); DAG as a rail SVG/CSS or indented-with-backedges. | not started | `app.d` HTML branch; [`FLD10`](./folding.md) |

## Milestones

| Milestone | Scope                                                                | Status      | Requirements            |
| --------- | -------------------------------------------------------------------- | ----------- | ----------------------- |
| V0        | Interactive tree (expand/collapse state, cursor, mouse) — GUI + TUI  | not started | `TRV1`–`TRV3`, `TRB1/2` |
| V1        | Lazy children + filtering + decorations; the file-explorer adapter   | not started | `TRV4`–`TRV7`, `TVU1`   |
| V2        | Tree-sitter inspector + file outline adapters                        | not started | `TVU2`, `TVU3`          |
| V3        | DAG model + git-rail renderer; the git-graph adapter                 | not started | `DAG1`, `DAG2`, `TVU4`  |
| V4        | Layered node-link renderer; the dependency-graph adapter (GUI-first) | not started | `DAG3`, `TVU5`          |
| V5        | HTML `<details>`/rail rendering                                      | not started | `TRB3`                  |

## Relationship to existing specs

| Piece                                                                        | Role                                                                                   |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| [ui-architecture.md](./ui-architecture.md) `WGT`/`STM`/`LAY`                 | the widget/state/layout levels this component instantiates                             |
| [folding.md](./folding.md) `FLD2`                                            | shares the expand/collapse state machine                                               |
| [overlays.md](./overlays.md) `TSI`                                           | the tree-sitter inspector — rendered by `TVU2`                                         |
| `sparkles:core-cli` `ui.tree` (static)                                       | the precedent renderer to generalize (`TRV1`)                                          |
| [tree-view case study](../../research/tui-libraries/tree-view-case-study.md) | interactive-tree design grounding                                                      |
| [docs/specs/tui](../tui/index.md)                                            | the `sparkles:tui` cell-grid substrate (an interactive tree is a named consumer there) |

→ [UI architecture](./ui-architecture.md) · [Overlays](./overlays.md) · [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [Overview](./index.md)
