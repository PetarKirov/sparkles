# `hue` content folding — Feature Requirements (all interactive backends)

_**Status:** planned · **Date:** 2026-07-23 · **Scope:** expand/collapse of
foldable regions — code structures (functions, classes, namespaces, comments,
blocks, …), markdown sections and lists, and **any node in the tree-sitter CST**.
A cross-backend viewer capability (GUI, TUI, HTML) built on a fold-range model
from [`sparkles:syntax`](../syntax/index.md) and a presentation-free fold-state
machine._

> [!NOTE]
> Forward-looking — every row is `not started`. The **substrate** exists: the
> precise tree-sitter CST and the markdown structural model (`MdDoc`) that feed
> the fold-range providers are shipped in `sparkles:syntax`; folding adds the
> range extraction, the fold state, and the collapsed rendering. Status legend
> and IDs: see the [overview](./index.md).

## Design & rationale

Folding decomposes into three concerns, each landing on an existing seam:

1. **Fold ranges** (`FSR`) — _what_ is foldable — come from `sparkles:syntax`:
   the **tree-sitter CST** (any named node spanning multiple lines) and the
   **markdown model** (heading sections, lists, fences). Backend-agnostic, byte
   spans into the source.
2. **Fold state** (`FLD2`) — _what is collapsed_ — is a **presentation-independent
   state machine** (the [`ui-architecture` `STM`](./ui-architecture.md) level 1):
   a set of collapsed regions, consumed identically by every backend.
3. **Rendering** — _how a collapse looks_ — elides the folded region's interior
   from the wrapped `PreviewLine[]` ([`gui.md` `RND2`](./gui.md)) and draws a
   placeholder + gutter marker, per backend.

It shares the parse tree with the [tree-sitter inspector overlay](./overlays.md)
(`TSI`) and reuses the same source-span discipline as
[selection](./gui.md) (`srcStart`).

## Fold model & interaction (`FLD`)

| ID   | Requirement                                                                                                                                                                                                                                                    | Status      | Traces to                                         |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------- |
| FLD1 | hue must support **content folding** — collapsing/expanding foldable regions in the interactive views; a collapsed region's interior is elided from the visible content and shown as a placeholder.                                                            | not started | proposed fold layer                               |
| FLD2 | Fold **state** must be a **presentation-independent state machine** — the set of collapsed regions keyed by source byte span — the [`ui-architecture` `STM`](./ui-architecture.md) level, consumed identically by GUI/TUI/HTML.                                | not started | [ui-architecture.md](./ui-architecture.md) `STM*` |
| FLD3 | Collapsing a region must **remove its interior visual lines** from the wrapped `PreviewLine[]` ([`RND2`](./gui.md)) and reflow/repaint; line numbers ([`NUM`](./gui.md)) keep reflecting **physical source lines** (folded lines are skipped, not renumbered). | not started | `PreviewLine[]` elision; `NUM` gutter             |
| FLD4 | A collapsed region must render a **placeholder** — its first line kept, a trailing marker (`⋯` / `{ … }` / `▸ N lines`) — plus a **gutter fold marker** (`▸` collapsed / `▾` expanded) on foldable lines.                                                      | not started | proposed placeholder + gutter marker              |
| FLD5 | **Interaction:** a gutter fold-marker click (GUI/TUI mouse) and keybindings must toggle a fold; **fold-all / unfold-all** and **fold-to-level** must be available (a documented vim-like set, e.g. `za`/`zc`/`zo`/`zR`/`zM`).                                  | not started | `gui.d`/`previewer.d` input; `TIN3`               |
| FLD6 | Folding must **compose with search & goto** — a [search](./gui.md) match or a [goto-line](./gui.md) target inside a collapsed region must auto-expand the enclosing folds so the target is visible.                                                            | not started | `FND`/`NAV2` integration                          |
| FLD7 | Folding must **degrade**: with no fold ranges (no grammar, plain text) it is a no-op, never a crash (the totality law).                                                                                                                                        | not started | `FSR` empty → no-op                               |

## Fold-range sources (`FSR`)

| ID   | Requirement                                                                                                                                                                                                                                                                                         | Status      | Traces to                                            |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------- |
| FSR1 | A **CST-based** provider must derive fold ranges from the tree-sitter parse tree — **any named node spanning more than one line** is foldable (functions, classes, namespaces/modules, structs/enums, blocks, arrays/objects), plus multi-line comments and import/using groups. Language-agnostic. | not started | `sparkles:syntax` / `sparkles:tree-sitter` CST       |
| FSR2 | Where the grammar bundle ships a **`folds.scm`** query (the tree-sitter fold convention — `@fold` captures, as nvim-treesitter uses) it must be preferred for precise, language-tuned ranges; absent it, fall back to the `FSR1` heuristic (totality).                                              | not started | `folds.scm` (ts-grammars bundle); `FSR1` fallback    |
| FSR3 | A **markdown** provider must fold structural regions from the `MdDoc` model — **heading sections** (heading + body up to the next same-or-higher heading), **list items** (item + nested children), **code fences**, block quotes/callouts, and tables.                                             | not started | `sparkles:syntax` `md/model.d` (`MdDoc`)             |
| FSR4 | Fold ranges must be **byte spans into the source** (like selection `srcStart`), so folding is consistent across the raw and preview views and survives wrapping.                                                                                                                                    | not started | source-span discipline (`SEL`/`PreviewRun.srcStart`) |

## Per-backend rendering (`FLD8`–`FLD10`)

| ID    | Requirement                                                                                                                                                                                                               | Status      | Traces to                               |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------- |
| FLD8  | **GUI** — gutter fold triangles + placeholder line, toggled by mouse click on the marker and by keybindings; reflow via `relayout`.                                                                                       | not started | [gui.md](./gui.md) (`RND`/`NUM`/`NAV`)  |
| FLD9  | **TUI** — the same, in cells: gutter markers + placeholder, SGR-mouse click on the marker ([`tui.md` `TIN`](./tui.md)) + keybindings; best-effort parity with `FLD8`.                                                     | not started | [tui.md](./tui.md) (`TSF`/`TIN`)        |
| FLD10 | **HTML** — static output folds via **pure CSS** (`<details>`/`:checked`, no JS — the twoslash/notifier HTML doctrine): each foldable region a `<details>` (default open) so a reader collapses/expands it in the browser. | not started | `app.d` HTML branch; `HTM3`-style no-JS |

## Milestones

| Milestone | Scope                                                                 | Status      | Requirements           |
| --------- | --------------------------------------------------------------------- | ----------- | ---------------------- |
| C0        | Fold-range providers — CST heuristic (`FSR1`) + markdown (`FSR3`)     | not started | `FSR1`, `FSR3`, `FSR4` |
| C1        | Fold state machine + line elision + gutter markers + GUI interaction  | not started | `FLD2`–`FLD5`, `FLD8`  |
| C2        | TUI parity                                                            | not started | `FLD9`                 |
| C3        | HTML `<details>` folding                                              | not started | `FLD10`                |
| C4        | `folds.scm` precise queries + fold-to-level + search/goto auto-expand | not started | `FSR2`, `FLD5`, `FLD6` |

## Relationship to existing specs

| Piece                                            | Role in folding                                       |
| ------------------------------------------------ | ----------------------------------------------------- |
| `sparkles:syntax` CST + `folds.scm`              | code fold ranges (`FSR1`/`FSR2`)                      |
| `sparkles:syntax` `md/model.d` (`MdDoc`)         | markdown fold ranges (`FSR3`)                         |
| [ui-architecture.md](./ui-architecture.md) `STM` | the fold state machine (`FLD2`)                       |
| [gui.md](./gui.md) `RND`/`NUM`/`NAV`/`FND`       | line elision, gutter, reflow, search/goto integration |
| [tui.md](./tui.md) `TSF`/`TIN`                   | terminal rendering + input (`FLD9`)                   |
| [overlays.md](./overlays.md) `TSI`               | shares the same CST (the tree-sitter inspector)       |

→ [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [UI architecture](./ui-architecture.md) · [Overview](./index.md)
