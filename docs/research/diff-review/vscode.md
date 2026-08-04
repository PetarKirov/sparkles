# VS Code diff editor (TypeScript)

The diff subsystem inside the Monaco/VS Code editor: a heuristics-heavy two-phase diff engine (`defaultLinesDiffComputer`) computed in a web worker, rendered by composing two full code-editor instances with view-zone alignment, unchanged-region folding, moved-code arrows, and a virtualized multi-file diff editor used for SCM/PR review.

| Field             | Value                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------ |
| Language          | TypeScript                                                                                                   |
| License           | MIT                                                                                                          |
| Repository        | [microsoft/vscode][vscode-repo]                                                                              |
| Documentation     | <https://code.visualstudio.com/docs/editing/codebasics#_compare-files>                                       |
| Category          | editor-diff                                                                                                  |
| First release     | 2015-11-18 (VS Code 0.10.1 public release); the "advanced" diff computer shipped in VS Code 1.78, 2023-05-04 |
| Latest release    | continuous (monthly); surveyed tree is current `main`                                                        |
| Surveyed revision | `106a3a45eec09d92d4a23da89337f25521d73ccd` (2026-08-04)                                                      |

> [!NOTE]
> Scope: this survey covers `src/vs/editor/common/diff/` (the diff computers), `src/vs/editor/browser/widget/diffEditor/` (the two-pane widget), and `src/vs/editor/browser/widget/multiDiffEditor/` plus its workbench glue. The merge editor (`src/vs/workbench/contrib/mergeEditor/`), notebook diff, and inline-chat diff decorations reuse the same computers but are out of scope.

## Overview

### What it solves

VS Code needs one diff engine serving many surfaces: the two-pane compare editor, the inline (unified) view, SCM quick-diff gutters, the multi-file "view changes" review surface, notebook diffs, and inline-suggestion previews. The engine must produce _editor-quality_ diffs — character-precise inner ranges that survive live editing on either side, align across two independently-scrolling editors, and stay responsive on large files — rather than a one-shot textual patch. The 2023 rewrite (`DefaultLinesDiffComputer`, selected by the default option `diffAlgorithm: 'advanced'` in `src/vs/editor/common/config/diffEditor.ts`) explicitly optimizes diff _quality_ — minimizing visually confusing splinter diffs — over raw minimality of the edit script, and adds moved-code detection.

### Design philosophy

Three ideas dominate the code:

1. **Algorithms are interchangeable behind tiny interfaces.** Both the line pass and the character pass run the same two `IDiffAlgorithm` implementations over an abstract `ISequence` (`src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/diffAlgorithm.ts`); quality then comes from a pipeline of post-pass heuristics, not from the core algorithm. The Myers implementation describes itself plainly: "An O(ND) diff algorithm that has a quadratic space worst-case complexity." (`algorithms/myersDiffAlgorithm.ts`).
2. **Heuristics are empirical, tuned against a golden-fixture corpus.** `heuristicSequenceOptimizations.ts` contains hand-fitted score formulas with comments like "Sometimes, calling this function twice improves the result. Uncomment the second invocation and run the tests to see the difference." and, next to a power-law join criterion, "TODO: Maybe a neural net can be used to derive the result from these numbers".
3. **The widget is derived state, not imperative UI.** Rendering is expressed as observables (`derived`/`autorun`/`transaction` from `src/vs/base/common/observable.ts`); e.g. the pane-alignment component documents itself: "Ensures both editors have the same height by aligning unchanged lines. In inline view mode, inserts viewzones to show deleted code from the original text model in the modified code editor. Synchronizes scrolling." (`src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones/diffEditorViewZones.ts`).

## How it works

### 1. Diff computation & data model

The diff is **computed in-process, in the editor web worker**: `WorkerBasedDocumentDiffProvider` (`src/vs/editor/browser/widget/diffEditor/diffProviderFactoryService.ts`) calls `IEditorWorkerService.computeDiff`, which syncs both text models to the worker and runs `$computeDiff` in `src/vs/editor/common/services/editorWebWorker.ts`. Four computers are registered in `src/vs/editor/common/diff/linesDiffComputers.ts`: `legacy` (the pre-2023 `legacyLinesDiffComputer.ts`), `advanced` (default, `DefaultLinesDiffComputer`), and `advanced-external` / `advanced-wasm`, which dynamically import the out-of-tree `@vscode/diff` npm module (`externalLinesDiffComputer.ts`) — an extraction of the same algorithm, optionally as WebAssembly. A `IDocumentDiffProvider` seam (`src/vs/editor/common/diff/documentDiffProvider.ts`) means the widget never assumes where diffs come from.

`DefaultLinesDiffComputer.computeDiff` (`defaultLinesDiffComputer/defaultLinesDiffComputer.ts`) is **two-phase**:

- **Line phase.** Every line is mapped to a _perfect hash_ of its `trim()`-ed content (a `Map<string, number>` handing out sequential ids), so line equality is integer equality and trailing/leading whitespace is ignored at this level. If `seq1.length + seq2.length < 1700`, it runs `DynamicProgrammingDiffing` — a weighted-LCS O(MN) DP ("A O(MN) diffing algorithm that supports a score function", `algorithms/dynamicProgrammingDiffing.ts`) whose score function rewards long identical lines (`1 + Math.log(1 + line.length)`), scores trim-only-equal lines `0.99`, empty lines `0.1`, and adds a bonus for consecutive diagonals — otherwise the O(ND) Myers algorithm (with growable `Int32Array` V-arrays supporting negative diagonals and a `SnakePath` linked list for backtracking).
- **Refinement phase.** Each line-level change is re-diffed at **character granularity**: the changed line ranges are flattened into a `LinesSliceCharSequence` (char codes plus `\n` separators, with per-line trimmed-whitespace bookkeeping so offsets translate back to exact positions), and again DP is used below 500 chars, Myers above.

Both phases honor an `ITimeout` (`DateTimeout`, default `maxComputationTime: 5000` ms); on expiry the algorithm returns a trivial "everything changed" result and the widget shows a _"timed out"_ state with an override action. The result model is `LinesDiff { changes: DetailedLineRangeMapping[]; moves: MovedText[]; hitTimeout }` (`linesDiffComputer.ts`): each `DetailedLineRangeMapping` pairs an original/modified `LineRange` and carries `innerChanges: RangeMapping[]` (character-precise `Range` pairs); `MovedText` pairs a `LineRangeMapping` with its own nested diff between the moved blocks (`rangeMapping.ts`). A debug-only `assertFn` validates every emitted range against both documents.

### 2. Rendering & layout

`DiffEditorWidget` (`browser/widget/diffEditor/diffEditorWidget.ts`) composes **two complete `CodeEditorWidget` instances** (`components/diffEditorEditors.ts`) with a draggable sash (`components/diffEditorSash.ts`). Because the panes are real editors, syntax highlighting, word wrap (`diffWordWrap`), folding, inline hints, and editing (the modified side is editable; `originalEditable: false` by default) all come for free.

- **Side-by-side vs inline:** `renderSideBySide: true` is the default; with `useInlineViewWhenSpaceIsLimited: true` the widget auto-degrades to the inline (unified) view below `renderSideBySideInlineBreakpoint: 900` px (`src/vs/editor/common/config/diffEditor.ts`). There is additionally an experimental "true inline" single-editor view (`experimental.useTrueInlineView`).
- **Cross-pane row alignment** is the job of `DiffEditorViewZones` (`components/diffEditorViewZones/diffEditorViewZones.ts`): `computeRangeAlignment` walks the mappings (splitting at wrapped lines and existing view zones) and inserts spacer _view zones_ — Monaco's mechanism for injecting non-model vertical space — into whichever pane is shorter, so unchanged lines sit at identical heights and one scrollbar drives both panes. In inline mode the deleted original text is itself rendered into view zones inside the modified editor by `renderLines.ts`, reusing the original model's tokenization for syntax colors.
- **Decorations** (`components/diffEditorDecorations.ts` + `registrations.contribution.ts`): whole-line add/remove backgrounds, char-precise inner-change boxes, `+`/`-` margin indicators (`renderIndicators`), and empty-change markers (`showEmptyDecorations`) are ordinary editor decorations; the overview ruler shows the diff map (`features/overviewRulerFeature.ts`).

### 3. Intra-line & noise handling

This is the subsystem's densest area — `heuristicSequenceOptimizations.ts` is a five-stage cleanup pipeline applied after the raw algorithm at _both_ granularities:

- `joinSequenceDiffsByShifting` slides pure insertions/deletions left then right to merge with neighbors (fixes the classic `import { Baz, Bar[, Foo] }` split-diff).
- `shiftSequenceDiffs` / `shiftDiffToBetterPosition` slides an insertion/deletion within its equal neighborhood to the position with the best **boundary score**. At char level `LinesSliceCharSequence.getBoundaryScore` classifies chars into categories (word-lower/upper/number, separator, space, line break) with tuned weights — `Separator` (`,`/`;`) = 30, `Space` = 3, an after-`\n` position = 150 — so diffs snap to word/line boundaries; at line level `LineSequence.getBoundaryScore` prefers boundaries at low indentation (`1000 - indentation`), i.e. block edges.
- `extendDiffsToEntireWordIfAppropriate` grows char diffs to whole words when less than 2/3 of the touched word pair is unchanged, so "small edit inside a word" renders as a word replacement; with `extendToSubwords` it first tries camelCase subword boundaries (`findSubWordContaining`).
- `removeShortMatches` merges diffs separated by ≤ 2 equal chars; `removeVeryShortMatchingLinesBetweenDiffs` (line level) and `removeVeryShortMatchingTextBetweenLongDiffs` (char level) absorb tiny equal islands (≤ 4 non-whitespace chars, or a capped power-law criterion over surrounding diff sizes) between large diffs — trading edit-script minimality for visual coherence.

**Whitespace handling** is two-tier: `ignoreTrimWhitespace: true` (default) makes the line phase compare trimmed hashes and the char slices drop leading/trailing whitespace; a `scanForWhitespaceChanges` pass then re-diffs equal-modulo-whitespace lines only when whitespace is _not_ ignored, so indent-only rewraps produce zero decorations under the default settings. There is no deeper formatting-noise model (no "ignore all inner whitespace", no structural/AST equivalence) — alignment-noise inside a line (e.g. re-padded markdown table cells) is still reported, though the boundary-score shifting tends to snap it to column boundaries.

**Moved-code detection** (`computeMovedLines.ts`, opt-in via `experimental.showMoves`) runs two strategies: (a) pair each ≥ 3-line pure deletion with the most similar pure insertion, accepting similarity > 0.90 over histogram-based `LineRangeFragment`s; (b) index every 3-line window inside changed regions by concatenated line hashes, chain-extend matching windows, then greedily claim non-overlapping ranges (via `LineRangeSet` subtraction) and extend them up/down through _similar_ (not identical) lines — `areLinesSimilar` runs a per-line char Myers diff and requires > 60 % common non-space characters. Filters drop trivial moves (< 15 chars or < 2 substantial lines) and moves that stay within one diff. `features/movedBlocksLinesFeature.ts` renders each move as a curved connector in a strip between the panes, with a button that retargets the diff to compare the two moved blocks against each other.

### 4. Navigation, folding & scale

- **Unchanged-region folding**: `UnchangedRegion.fromDiffs` (`diffEditorViewModel.ts`) inverts the mappings and turns every unchanged gap ≥ `minimumLineCount: 3` (keeping `contextLineCount: 3` visible on each side) into a collapsible region; `features/hideUnchangedRegionsFeature.ts` renders each as a placeholder view zone showing "N hidden lines" plus **breadcrumb items** (outline symbols in the hidden range, via a pluggable `IDiffEditorBreadcrumbsSource`), with drag-to-reveal, click-to-expand by `revealLineCount: 20`, and automatic reveal when a cursor or selection enters a hidden range (`ensureOriginalLineIsVisible`). Off by default (`hideUnchangedRegions.enabled: false`), enabled by review surfaces.
- **Navigation**: F7/Shift+F7 walk changes; the accessible diff viewer (`components/accessibleDiffViewer.ts`, 737 lines) is a full screen-reader-oriented sequential presentation of hunks with per-line insert/remove icons and spoken descriptions — a separate _model_ interface (`IAccessibleDiffViewerModel`), not a styling of the main view.
- **Scale guards**: the 5 s computation timeout; model sync to the worker refuses files flagged `isTooLargeForSyncing()` (`src/vs/editor/browser/services/editorWorkerService.ts`); a `maxFileSize: 50` (MB) option; a 10-entry diff result cache keyed by model versions in `diffProviderFactoryService.ts`; and full-document equality short-circuits.
- **Multi-file scale**: `multiDiffEditorWidgetImpl.ts` renders one scrollable document list where each file is a `VirtualizedViewItem` — off-screen diff editors are returned to an `ObjectPool` of `DiffEditorItemTemplate`s (at most 5 kept warm, `objectPool.ts`), so a 300-file PR does not instantiate 300 editors.

### 5. VCS & review integration

The diff editor itself is **VCS-agnostic** — it diffs any two `ITextModel`s; git never provides the diff, only the _contents_ (via content providers for `gitfile://`-style URIs). Integration happens in the workbench layer:

- **Hunk actions**: `features/gutterFeature.ts` renders a per-hunk gutter toolbar bound to `MenuId.DiffEditorHunkToolbar` and a selection toolbar (`MenuId.DiffEditorSelectionToolbar`); the git extension contributes _Stage/Revert/Unstage hunk_ and _Stage selection_ commands into those menus (`extensions/git/package.json`, `diffEditor/gutter/hunk`). Staging is thus a menu contribution, not a diff-editor primitive.
- **Revert arrows**: `features/revertButtonsFeature.ts` places glyph-margin widgets that copy the original range(s) over the modified side — per hunk, or for an exact selection of inner changes.
- **Multi-file review**: `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.ts` defines `IMultiDiffSourceResolver` → `MultiDiffEditorItem[]` (original/modified URI pairs); `scmMultiDiffSourceResolver.ts` maps an SCM resource group (scheme `scm-multi-diff-source`) into one, powering "View Changes"/commit views; the GitHub PR extension feeds the same surface through the `tab`-visible multi-diff API. Review _comments_ are not part of this subsystem — they arrive via the generic commenting service, anchored to editor lines.
- **Stacks & merges**: there is no stacked-PR model anywhere in the tree; three-way merge is a separate `mergeEditor` contribution that reuses the diff computers but none of this widget.

### 6. Architecture & reuse

The computation core (`src/vs/editor/common/diff/**`) is dependency-light TypeScript (only `base/common` utilities) designed to run in a **web worker**, Node, or the browser main thread unchanged; it ships to third parties inside the `monaco-editor` package, and its extraction as `@vscode/diff` (consumed by `externalLinesDiffComputer.ts`, optionally compiled to WASM) shows it is deliberately severable. The reusable ideas, in decreasing portability: the `ISequence`/`IDiffAlgorithm` abstraction that lets the _same_ Myers/DP implementations serve line and char granularity; the post-pass heuristic pipeline as separable pure functions over `SequenceDiff[]`; the boundary-score model; timeout-bounded diffing with graceful degradation; and `UnchangedRegion` computation as pure inversion of the mapping list. The widget layer, by contrast, is deeply bound to Monaco (view zones, decorations, observables, service injection) — the _patterns_ (spacer-based alignment, pooled virtualized per-file editors, menu-contributed hunk actions) travel, the code does not.

## Strengths

- Best-in-class _visual_ diff quality: the heuristic pipeline (boundary snapping, word/subword extension, splinter-diff absorption) is the most complete treatment of "minimal is not readable" surveyed, and it is regression-tested against a golden-fixture corpus (`src/vs/editor/test/node/diffing/fixtures/`, cases like `bracket-aligning` and `difficult-move`).
- Character-precise `innerChanges` in the data model itself — renderers never re-derive intra-line detail.
- Live: diffs recompute as either side is edited, with mapping-preserving heuristics for unchanged-region persistence across edits (`diffEditorViewModel.ts` transfers regions through decoration ids).
- Moved-code detection with per-move nested diffs and a dedicated compare-the-move affordance.
- Robust scale story: worker offload, 5 s timeout with explicit degraded state, result caching, virtualized multi-file rendering with editor pooling.
- Accessibility is a first-class parallel presentation, not an afterthought.

## Weaknesses

- Whitespace handling is trim-only; there is no general formatting-noise classification (no intra-line ignorable-whitespace mode, no structural equivalence), so formatter re-alignment inside lines still surfaces as changes.
- Purely textual: no AST/structural diffing anywhere; markdown tables, reordered keys, or wrapped prose are diffed as character soup (mitigated only by the boundary heuristics).
- The heuristic constants (1700-line and 500-char algorithm cutoffs, 2/3 word rule, 0.90 move similarity, power-law join) are hard-coded and undocumented outside the code; behavior is hard to predict or tune per language.
- The widget is monolithically coupled to Monaco's editor internals — reusing the rendering requires adopting the whole editor.
- Review integration stops at "show files + comments"; no interdiff between PR revisions, no stacked-change model.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                          | Trade-off                                                                                            |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Two-phase diff (hashed trimmed lines, then char refinement per hunk) | Line pass is fast and whitespace-tolerant; char pass is bounded to changed regions | Cross-line moves of partial lines invisible; refinement quality depends on line pass segmentation    |
| Same `IDiffAlgorithm` impls at both granularities via `ISequence`    | One tested Myers + one DP serve every level; heuristics stay algorithm-independent | Sequences must flatten to integer elements; no token/AST elements without new sequence types         |
| DP-with-score for small inputs, Myers for large                      | Weighted LCS gives better alignments (prefers long lines as anchors) but is O(MN)  | Two algorithms to maintain; a 1700-line threshold cliff in behavior                                  |
| Post-pass heuristic pipeline over raw edit script                    | Optimizes human readability, empirically tuned on fixtures                         | Non-minimal diffs; opaque hard-coded constants; results can shift between releases                   |
| Compute in web worker behind `IDocumentDiffProvider`                 | UI never blocks; provider seam allows external/WASM/server diffs                   | Model sync cost and size limits; async results need version-checking and caching                     |
| Alignment via spacer view zones in two real editors                  | Full editor features (tokens, wrap, editing) in both panes for free                | Heavy: two editor instances per file; alignment logic must chase wrapping and view-zone churn        |
| Unchanged-region folding computed from inverted mappings             | Pure function of the diff; persists across edits via decoration ids                | Off by default; breadcrumbs need a pluggable outline source, absent embedders show bare placeholders |
| Moved-code detection as opt-in post-pass with similarity thresholds  | Catches refactors Myers renders as delete+insert                                   | O(changes²)-ish pairing bounded by timeout; thresholds (0.90/0.6) occasionally misfire, hence opt-in |
| Hunk actions as workbench menu contributions, not widget primitives  | Diff editor stays VCS-agnostic; git/PR extensions compose on top                   | Core widget alone cannot stage; behavior scattered across extension points                           |

## Sources

- Local checkout at `/home/petar/code/repos/typescript/vscode`, revision `106a3a45eec09d92d4a23da89337f25521d73ccd` (2026-08-04) — primary; all relative paths above refer to it.
- `src/vs/editor/common/diff/defaultLinesDiffComputer/` — algorithms, heuristics, moved-line detection.
- `src/vs/editor/browser/widget/diffEditor/` — widget, features, components.
- `src/vs/editor/browser/widget/multiDiffEditor/` and `src/vs/workbench/contrib/multiDiffEditor/browser/` — multi-file review surface.
- [VS Code repository][vscode-repo] (pinned tree at the surveyed revision).

<!-- References -->

[vscode-repo]: https://github.com/microsoft/vscode/tree/106a3a45eec09d92d4a23da89337f25521d73ccd
