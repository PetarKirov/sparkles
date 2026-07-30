# `hue` tree / DAG view — Feature Requirements (interactive component)

_**Status:** partial — the tree component + the TUI file explorer shipped (`d47a0d01`); DAG views planned · **Date:** 2026-07-30 · **Scope:** a reusable interactive
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

> [!IMPORTANT]
> The generic tree is a **toolkit** component, specified as
> [`WGT12`/`VMD1`–`VMD6`](../ui/widgets.md); this page specifies hue's _use_ of
> it. Two consequences worth stating up front:
>
> - **`TVU1` becomes the directory target.** A directory argument opens the file
>   explorer rather than the bespoke index view, and the static
>   [gallery](./gallery.md) becomes the explorer's HTML flavor.
> - The case study's verdict is **take snacks' features, ratatui's architecture**:
>   snacks' own tree is an incidental data structure (a mutable singleton with
>   parent back-references, and view state and decoration stored on data nodes),
>   so the feature set is the reference but the three-layer split — data /
>   interaction state / view, with a pure `flatten` between them — is the shape.
> - Expand/collapse state is the toolkit's shared disclosure machine
>   ([`STM5`](../ui/state-machines.md)), the same one [folding](./folding.md)
>   uses.

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

| ID   | Requirement                                                                                                                                                                                                                                  | Status                                                                                                                                                     | Traces to                                              |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| TRV1 | A **tree view** must render a hierarchical node model as indented rows: each node an icon + label + optional trailing decorations/badges, with **indent guides** and an expand/collapse marker on parent nodes.                              | full (`d47a0d01`) — `tree_widget.treeView`: guides, marker, DbI icon/label; badges open                                                                    | proposed `sparkles:ui` tree widget; `core-cli.ui.tree` |
| TRV2 | **Expand/collapse** must be a presentation-free state machine (shared with [folding](./folding.md) `FLD2` / [`STM`](./ui-architecture.md)); collapsing hides a subtree, expanding reveals it; expand-all / collapse-all / expand-to-level.   | full (`d47a0d01`) — the shared `DisclosureState` (`STM5`), also driving folding                                                                            | `STM`; `FLD2`                                          |
| TRV3 | **Navigation** — a cursor moves by visible row (↑/↓, `j`/`k`); ←/`h` collapses (or moves to parent), →/`l` expands (or enters first child); Home/End, page scroll; **mouse** click selects, click on the marker toggles (GUI/TUI SGR mouse). | partial (`d47a0d01`) — ↑↓/jk/Home/End/PgUp/PgDn, ←/→ collapse-or-parent / expand-or-pick, click selects (second click activates); marker-click toggle open | `gui.d`/`previewer.d` input; [`TIN`](./tui.md)         |
| TRV4 | **Lazy children** — a node's children may be produced on demand (for large or filesystem-backed trees), so expansion, not construction, drives cost.                                                                                         | full (`d47a0d01`) — the explorer loads children one level past `open` (honest markers), recursing only the visible+open chain                              | proposed node-provider callback                        |
| TRV5 | **Filtering / live search** — an incremental filter must narrow visible nodes (matching nodes + their ancestors kept), snacks-explorer style.                                                                                                | full (`d47a0d01`) — the explorer's `/` filter: rebuild per keystroke, matches + ancestors (broot mode)                                                     | reuse [`FND`](./gui.md) input model                    |
| TRV6 | **Per-node decorations** must be data-driven — icon (Nerd-Font, with the [`FNT8`](./gui.md) tofu caveat), label style, and trailing badges (e.g. git status, counts) — supplied by the use-case adapter (`TVU`), not hardcoded.              | partial (`d47a0d01`) — DbI `icon`/`label`/`slot` capabilities; trailing badges (git status) open                                                           | adapter-supplied node view                             |
| TRV7 | **Selection** must yield a stable node identity / payload to the caller (e.g. a file path, a CST node, a commit) so actions (open, reveal, jump) act on it.                                                                                  | full (`d47a0d01`) — the explorer returns the picked file path; the caller opens it                                                                         | node payload contract                                  |

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

| ID   | Use case                     | Model → adapter                                                                                                                                                                                                             | Status                                                                                                                                                              | Traces to                                                       |
| ---- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| TVU1 | **File explorer**            | filesystem tree (lazy dirs `TRV4`), file-type + git-status icons/badges (`TRV6`), open/reveal actions (`TRV7`) — the snacks-explorer use case; **entered by a directory CLI target** ([`SRC4`](./feature-requirements.md)). | partial (`d47a0d01`) — the TUI explorer ships as the interim full-screen loop; the split-pane workspace (`XPL2`), GUI/HTML flavors (`XPL1`) and git badges are open | proposed FS adapter; `sparkles:build-primitives` walker; `SRC4` |
| TVU2 | **Tree-sitter inspector**    | the CST as a tree (named/anonymous nodes, field names, S-expression); **renders the [`overlays.md` `TSI`](./overlays.md)** panel.                                                                                           | not started                                                                                                                                                         | `sparkles:tree-sitter` CST; `TSI`                               |
| TVU3 | **File outline**             | document symbols — code structure (functions/classes) from the CST, or headings from `MdDoc` — a jump-to-symbol outline.                                                                                                    | not started                                                                                                                                                         | `sparkles:syntax` CST / `md/model.d`; `FSR3`                    |
| TVU4 | **Git graph**                | the commit DAG, rail/lane rendered (`DAG2`); refs/branches as node badges.                                                                                                                                                  | not started                                                                                                                                                         | git adapter → `DAG2`                                            |
| TVU5 | **Dependency graph** (build) | a build-system / module DAG (targets → deps), layered or rail rendered (`DAG3`/`DAG2`).                                                                                                                                     | not started                                                                                                                                                         | build-graph adapter → `DAG3`                                    |

## Explorer workspace integration (`XPL`)

The explorer is not a separate mode but hue's **workspace shell**: a
neovim-style split with the tree in a left pane and the open document in the
right pane, on every backend. The current full-screen tree → viewer → tree
loop is the interim shape it replaces.

| ID   | Requirement                                                                                                                                                                                                                                             | Status      | Traces to                                         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------- |
| XPL1 | The explorer must be available on **all three targets** — TUI, GUI, and HTML (the gallery's index becomes the tree's static flavor, per `TRB3`'s pure-CSS `<details>` doctrine) — one tree definition, per-backend canvases.                            | not started | `TRB1`–`TRB3`; [gallery.md](./gallery.md) `GAL5`  |
| XPL2 | **Split-pane layout** (neovim `snacks.explorer` style): the tree in a left sidebar, the currently open document in the right pane — one window/screen, two viewports; the sidebar is toggleable and the split ratio is configurable.                    | not started | `LAY7` viewports; [ui/layout.md](../ui/layout.md) |
| XPL3 | The **currently open document is highlighted** in the tree (a distinct row style from the cursor), and stays highlighted as the tree is scrolled, filtered, or re-expanded.                                                                             | not started | `TRV7` node identity; `Slot.selection`            |
| XPL4 | **Prev/next document navigation** (`[`/`]`, set navigation) must update the explorer too: the new document's node is selected and **revealed** (ancestor dirs auto-expanded, scrolled into view) — the tree and the viewer never disagree on "current". | not started | [navigation.md](./navigation.md) `GNV`; `TRV3`    |

## Explorer feature scope (`XPF`)

Scoped against a survey of `snacks.nvim`'s explorer (2026-07-30). In: the
pure filesystem/git features below. **Out, by decision:** file operations
(hue stays a $(B viewer) — add/rename/delete/move/copy/paste belong to the
shell/editor), filesystem watching (manual refresh is the contract instead),
LSP-coupled rename/buffer follow-through, and a separate deep-search mode
(the existing live filter already searches the whole tree).

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Status                                                                                          | Traces to                                               |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| XPF1 | **Git status integration**: one async `git status --porcelain -z --ignored=matching` per repo root with a TTL cache and a generation guard (a stale in-flight result must never clobber a newer one); per-file badges; **worst-status-wins ancestor propagation** (ignored deliberately $(B not) propagated); whole-ignored/untracked-dir status inherited by contents without listing them; git-ignored rows dimmed; `]g`/`[g` next/prev-change navigation over the ordered-walk primitive. | not started                                                                                     | snacks `git.lua` mechanisms; `TRV6`                     |
| XPF2 | **Filters & toggles**: a hidden-dotfile toggle and a git-ignored toggle (runtime keys, state shown in the chrome), plus glob include/exclude with snacks' precedence — `include` overrides hidden, ignored, and `exclude`.                                                                                                                                                                                                                                                                   | not started                                                                                     | `TRV5`; `build-primitives` gitignore; snacks precedence |
| XPF3 | **Re-rooting + close-all**: re-root to the selected item's directory, re-root to the parent, re-root outward when revealing a file outside the root (`XPL4`), and collapse-all.                                                                                                                                                                                                                                                                                                              | partial (`d47a0d01`) — ← closes/parents and the filter exist; re-rooting and close-all are open | snacks `explorer_focus`/`_up`; `TRV3`                   |
| XPF4 | **Manual refresh**: a refresh key re-reads the filesystem (invalidating loaded children and the git cache) while **preserving the open set** — the `open`/`expanded` split's payoff. This is the deliberate alternative to filesystem watching.                                                                                                                                                                                                                                              | not started                                                                                     | `VMD5`; snacks `Tree:refresh`                           |
| XPF5 | **Diagnostics badge seam** (future): a provider contract — any source of per-file severities (a compiler/linter channel) feeds worst-severity-wins propagation onto files and ancestors, rendered like the git badges. The propagation is trivial; only the source is missing, so this row waits on one.                                                                                                                                                                                     | researched                                                                                      | snacks `diagnostics.lua` (40-line propagation)          |

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
