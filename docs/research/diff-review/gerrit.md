# Gerrit (Java server / TypeScript+Lit web UI)

Gerrit is a self-hosted, change-based git code-review system whose diff pipeline is split in two:
the server computes line, intraline, and rebase-aware diffs with JGit and ships them as a compact
chunk-stream JSON entity, and the `gr-diff` web component — deliberately embeddable outside
Gerrit — renders that JSON as side-by-side or unified HTML with a layered annotation architecture.

| Field             | Value                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------ |
| Language          | Java (server, JGit-based); TypeScript + Lit web components (UI)                            |
| License           | Apache-2.0                                                                                 |
| Repository        | <https://gerrit.googlesource.com/gerrit> (mirrored to GitHub as `GerritCodeReview/gerrit`) |
| Documentation     | <https://gerrit-review.googlesource.com/Documentation/>                                    |
| Category          | web-review                                                                                 |
| First release     | 2008 (Gerrit 2.0 lineage, successor of Google's Mondrian/Rietveld review tools)            |
| Latest release    | 3.x line, actively developed (surveyed at `master`)                                        |
| Surveyed revision | `d5d1594f79cb17c77338bedee567d86104238aa3` (2026-08-04)                                    |

> [!NOTE]
> Scope: this survey covers the web diff UI under `polygerrit-ui/app/embed/diff/` and the
> server-side diff/intraline machinery under `java/com/google/gerrit/server/patch/` (plus the
> `DiffInfo` serializer in `java/com/google/gerrit/server/diff/`). Gerrit's ACLs, submit rules,
> plugins, and CI integration are out of scope.

## Overview

### What it solves

Gerrit reviews _commits_, not branches: each commit (tracked by a `Change-Id` trailer) is a review
unit that iterates through _patch sets_, and dependent commits form relation chains — the
archetypal stacked-review model. Its diff subsystem answers a harder question than "diff two
blobs": it must diff any pair of patch sets of a change (whose parents may differ after a rebase),
attribute which edits came from the rebase rather than the author, anchor immutable comment
threads to character ranges across those revisions, and serve all of this to a browser cheaply
enough for multi-thousand-line files. The answer is a heavily cached server-side diff pipeline
plus a JSON wire model (`DiffInfo`) that the client renders without ever re-diffing.

### Design philosophy

The UI half is explicitly built for reuse. `polygerrit-ui/app/embed/README.md` states:

> "This folder contains shared components that can be used independently of Gerrit."

The intraline engine is unapologetically heuristic. From `IntraLineLoader.java`:

> "Apply some simple rules to fix up some of the edits. Our logic above, along with our
> per-character difference tends to produce some crazy stuff."

And the client-side processor documents the vocabulary that drives context folding, in
`gr-diff-processor.ts`:

> "'key location': A line number and side of the diff that should not be collapsed e.g. because a
> comment is attached to it, or because it was provided in the URL and thus should be visible"

## How it works

### 1. Diff computation & data model

All diffing is server-side, in-process, via JGit. `gitfilediff/GitFileDiffCacheImpl.java` selects
the algorithm: `HistogramDiff`, optionally with Myers fallback (`DiffAlgorithm` enum
`HISTOGRAM_WITH_FALLBACK_MYERS` / `HISTOGRAM_NO_FALLBACK`); the default in
`DiffOperationsImpl.java` is `HISTOGRAM_WITH_FALLBACK_MYERS`, with rename detection at
`RENAME_SCORE = 60`. Whitespace modes map onto JGit comparators
(`RawTextComparator.WS_IGNORE_ALL` / `WS_IGNORE_TRAILING` / `WS_IGNORE_CHANGE` / `DEFAULT`).
A guard timeout exists specifically "because of a bug in Myers diff in JGit"
(`GitFileDiffCacheImpl.java`).

Results flow through a stack of persisted Guice-installed caches
(`GitModifiedFilesCacheImpl` → `ModifiedFilesCacheImpl` → `GitFileDiffCacheImpl` →
`FileDiffCacheImpl`), keyed by tree/blob ids plus algorithm and whitespace mode, so a diff is
computed once per (trees, options) tuple, ever.

Intraline refinement is a second, separately cached and separately timed-out pass
(`IntraLineLoader.java`, default 5 s on a dedicated `@DiffExecutor` pool; timeout is reported to
the client as `intraline_status: TIMEOUT` rather than failing the diff). For each line-level
`REPLACE` edit it runs a **character-level Myers diff** (`MyersDiff.INSTANCE.diff` over
`CharText`/`CharTextComparator`), then post-processes (see §3), producing `ReplaceEdit` —
a line edit carrying a list of internal character edits.

The wire model (`DiffInfo` REST entity, mirrored in `polygerrit-ui/app/api/diff.ts`) is a flat
chunk stream, `content: DiffContent[]`, where each chunk is one of:

| Chunk shape                 | Meaning                                                                          |
| --------------------------- | -------------------------------------------------------------------------------- |
| `ab: string[]`              | Common lines (both sides)                                                        |
| `a: string[]`/`b: string[]` | Deleted/added lines; both present = a replace                                    |
| `edit_a`/`edit_b`           | Intraline edits as `[skipLength, markLength]` pairs relative to the chunk's text |
| `common: true` + `a`,`b`    | Equal under the requested whitespace mode, but textually different               |
| `skip: n`                   | `n` common lines elided server-side (large files / context limit)                |
| `due_to_rebase: true`       | Chunk introduced by a rebase, not by the author                                  |
| `move_details`              | Chunk is a moved block; `range` points at the counterpart lines                  |

The `[skip, mark]` intraline encoding is produced in `DiffInfoCreator.java` by walking
`ReplaceEdit.getInternalEdits()` and emitting run-length deltas; the implied `\n` counts one
character, so marks may span lines. Content is _sparse_: `DiffContentCalculator.java` packs only
edited lines plus requested context via `SparseFileContent`, and `DiffInfoCreator.ContentCollector`
emits `skip` entries for the gaps — the client never receives the full file unless asked.
The client performs **no diffing at all**.

### 2. Rendering & layout

`gr-diff` (in `polygerrit-ui/app/embed/diff/`) is a Lit web-component tree with an RxJS model:
`gr-diff-model/gr-diff-model.ts` holds `DiffState` (diff, prefs, comments, layers, groups) as
observables; `processDiff()` reruns `GrDiffProcessor` whenever diff/context/focus inputs change.
The processor converts chunks into `GrDiffGroup`s (`BOTH` / `DELTA` / `CONTEXT_CONTROL`), each
group knowing its 1-based `lineRange` per side. Rendering then decomposes as
`gr-diff-element` → one `gr-diff-section` (a `<tbody>`) per group → one `gr-diff-row` (a `<tr>`)
per line pair → `gr-diff-text` per cell.

Both view modes render into a **single HTML table**; `ColumnsToShow` in `gr-diff-model.ts`
computes the column set (blame, left number, left sign, left content, right number, right sign,
right content). Side-by-side pairing is deliberately naive: `GrDiffGroup.getSideBySidePairs()`
zips `removes[i]` with `adds[i]` and pads the shorter side with `BLANK_LINE` — no
similarity-based row anchoring across panes. Unified mode (`getUnifiedPairs()`) interleaves and
drops the left copy of whitespace-only lines.

Text rendering (`gr-diff-builder/gr-diff-text.ts`) splits each line into tabs, surrogate pairs,
and plain segments; tabs get a column-aware `tab-size` style, and lines soft-wrap at the
configured `line_length` under responsive modes (`FULL_RESPONSIVE` / `SHRINK_ONLY` / `NONE`).

Syntax highlighting is a **layer**, not part of the renderer: `gr-syntax-layer-worker.ts` asks
`HighlightService` (`services/highlight/highlight-service.ts`), which runs highlight.js in a pool
of 3 web workers (guards: 20 000 lines / 500 000 chars max), maps MIME types to hljs languages,
converts hljs output into per-line class ranges filtered through a `CLASS_SAFELIST`, and applies
them by mutating the already-rendered DOM. All decorations share one seam: the `DiffLayer`
interface (`api/diff.ts`) — `annotate(textElement, lineNumberElement, line, side)` — with
implementations for syntax, intraline highlights, ranged comments, hovered-token highlighting,
test coverage, focus, and blame. `gr-diff-highlight/gr-annotation.ts` does the DOM surgery,
splitting text nodes at code-point (not UTF-16) offsets.

### 3. Intra-line & noise handling

The character-level Myers output is aggressively post-processed in `IntraLineLoader.compute`:

- **Coalescing**: word edits whose gap is ≤ 5 characters (and contains no newline) are merged —
  "we tend to get better results by joining them together and taking the whole span".
- **Adjacent-edit repair**: an `INSERT`/`DELETE` butting a `REPLACE` is folded in, avoiding
  results "like `"es"` → `"es = Addresses"`".
- **Shrinking and sliding**: identical edges are trimmed; edits whose leading and trailing text
  match are slid toward the line tail; if a whole line changed except its `\n`, the `\n` is
  absorbed ("easier to read").
- **Validation with fallback**: `isValidTransformation` replays the refined edits and, if they do
  not reproduce side B, falls back to one whole-span `ReplaceEdit` — heuristics may never corrupt
  the diff.

One level up, `combineLineEdits` merges _line_ edits separated by a single line of formatting
noise: a "pointless line" matching `BLANK_LINE_RE` (`^[ \t]*(|[{}]|/\*\*?|\*)[ \t]*$` — blank,
brace-only, or comment-decoration lines) or a control-block opener (`[{:][ \t]*$`). The stated
motivation: "These are mostly block reindents to add or remove control flow operators" — an
explicit, regex-encoded formatting-noise classifier baked into the diff engine.

Whitespace noise is handled by _classification, not deletion_: with an ignore-whitespace mode
active, lines equal under the comparator but textually different are emitted as `common: true`
chunks carrying **both** texts (`DiffContentCalculator.packContent`,
`DiffInfoCreator.ContentCollector`). The UI marks the group `ignoredWhitespaceOnly` and renders
the real text without add/remove styling — the change is visible on inspection but does not shout.

Rebase noise gets provenance tagging: when two patch sets have different parents,
`filediff/EditTransformer.java` + `GitPositionTransformer.java` map edits through the
parent-to-parent transformation and tag chunks `due_to_rebase`; the UI renders these sections
with a distinct `dueToRebase` style, and `IntraLineLoader.combineLineEdits` refuses to merge
across them so the attribution survives. Moved-code display exists end-to-end in the UI
(`move_details`, `moveControls` header rows with `movedIn`/`movedOut` and a link to the
counterpart range in `gr-diff-section.ts`) — but no producer of `move_details` exists anywhere in
this tree (see §6). Finally, `token-highlight-layer.ts` highlights all occurrences of a hovered
`[\w]+` token (limits: 500-char lines, 100-char tokens, 10 000 tokens).

### 4. Navigation, folding & scale

Context folding is _key-location driven_. `computeKeyLocations` (`gr-diff-utils.ts`) collects the
URL's line-of-interest and every comment anchor; `GrDiffProcessor.splitCommonChunksWithKeyLocations`
then splits common chunks so each key location becomes its own one-line chunk, and
`hideInContextControl` (`gr-diff-group.ts`) wraps everything beyond the user's context preference
into `CONTEXT_CONTROL` groups — unless fewer than 4 lines would be hidden, "because then that row
would consume as much space as the collapsed code". Expanding replaces the control group in the
model (`DiffModel.replaceGroup`), a pure state operation.

`gr-context-controls.ts` offers: expand-all, `+10` above/below (`PARTIAL_CONTEXT_AMOUNT`), and
**syntax-aware block expansion** — "expand until end of block" buttons that walk
`meta_b.syntax_tree` (`findBlockTreePathForLine`) and tooltip a breadcrumb like
`myNamespace > MyClass > myMethod1`. `skip` chunks keep huge files off the wire entirely; a
`content-load-needed` event lets the host fetch more. A hard guard
(`LARGE_DIFF_THRESHOLD_LINES = 10000` in `gr-diff-element.ts`) makes full-context rendering of
huge diffs opt-in per click. `gr-diff-cursor.ts` provides keyboard chunk/comment navigation
(`moveToNextChunk`, `moveToNextCommentThread`, …) across multiple registered diffs, and
`DiffRangesToFocus` collapses chunks outside caller-supplied focus ranges. One curiosity: the
processor's `asyncThreshold` option (wired from `num_lines_rendered_at_once`) is accepted but no
longer read — a vestige of the pre-Lit incremental renderer.

### 5. VCS & review integration

The server talks to git exclusively through JGit against bare repos (`GitRepositoryManager`);
`AutoMerger.java` materializes auto-merge trees so merge commits can be diffed against a merge of
their parents (`ComparisonType`). Comments are first-class review data (stored in NoteDb) anchored
to `(side, line, CommentRange{start_line, start_character, end_line, end_column})`; ported
comments that lose their anchor across patch sets attach to a synthetic `LOST` line rendered above
the `FILE` row. The `gr-diff` embed keeps comment _content_ out of scope via slots: the host
application drops comment-thread elements into `<gr-diff>` as light-DOM children, a
`MutationObserver` extracts their `line-num`/`side`/`range` attributes
(`getDataFromCommentThreadEl`), and each `gr-diff-row` renders `<slot name="${side}-${line}">`
(`gr-diff-row.ts`) — the diff knows anchor geometry, never comment semantics. Ranges become
key locations (never collapsed) and a `GrRangedCommentLayer` paints per-line segment highlights.

Stacked review is native: every commit is a change, series are relation chains, and patch-set
versus patch-set comparison — with `due_to_rebase` classification (§3) — is the primary review
loop rather than an afterthought. There is no client-side staging/hunk-selection; Gerrit reviews
pushed commits. Blame integrates as an optional per-row column (`BlameInfo`, `findBlame`).

### 6. Architecture & reuse

Process model: a Java monolith (Guice) computing and caching diffs; a browser UI consuming JSON.
The clean seams, in order of portability:

- **The wire model** (`api/diff.ts` / REST `DiffInfo`): chunk stream + `[skip, mark]` intraline
  runs + `common`/`due_to_rebase`/`skip`/`move_details` classification flags is a renderer-neutral
  diff description, independently implementable by any producer.
- **The `DiffLayer` seam**: all decoration (syntax, intraline, comments, coverage, token
  highlight, blame) composes over one `annotate()` interface; Gerrit plugins inject coverage
  layers through it.
- **The embed**: `gr-diff` is shipped as a standalone element (`embed/README.md`) themed by CSS
  custom properties.

Monolith-bound: the cache stack, NoteDb comment storage, and rebase attribution
(`EditTransformer`) all assume Gerrit's server. Notably, two API features have UI support but no
open-source producer at this revision: `meta_b.syntax_tree` (block expansion) and
`move_details` (moved-block headers) appear only as consumed types — `grep` finds no Java code
populating either — evidence they are fed by Google-internal analysis backends.

## Strengths

- Single-source-of-truth diffing: computed once server-side, cached persistently, rendered
  identically everywhere; clients stay thin and consistent.
- The intraline pipeline's _validate-then-fallback_ discipline: heuristics can only improve
  presentation, never corrupt correctness.
- Noise is classified, not hidden — whitespace-only (`common: true`) and rebase-induced
  (`due_to_rebase`) chunks remain visible but visually demoted, preserving trust.
- Key-location-driven folding guarantees comments and deep-linked lines are never collapsed,
  with syntax-tree block expansion far beyond the usual "+10 lines".
- The `DiffLayer` annotation seam cleanly decouples five-plus decoration concerns from the
  renderer, and doubles as the plugin API.
- Explicit scale guards at every tier: intraline timeout, hljs worker line/char caps,
  token-highlight limits, 10 000-line full-context confirmation, server-side `skip` elision.

## Weaknesses

- Side-by-side row alignment is naive index-zipping of removes/adds — no similarity anchoring, so
  a large replace pairs unrelated lines across panes.
- No open-source producer for `syntax_tree` or `move_details`: upstream deployments silently lack
  block expansion and moved-code detection the UI was built for.
- Formatting-noise heuristics (`BLANK_LINE_RE`, control-block regexes, ≤5-char coalescing) are
  hard-coded and C-family-biased; not configurable per language.
- Intraline is character-level Myers with cleanup, not token/word-level — results depend on
  heuristic repair rather than a linguistically meaningful granularity.
- DOM-mutating layers applied after Lit rendering force a two-pass re-render dance
  (`layersApplied` in `gr-diff-row.ts`) and make the render path harder to reason about.
- The client cannot diff locally at all — offline or ad-hoc use requires a Gerrit server.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                | Trade-off                                                                       |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Compute all diffs server-side; ship JSON chunks                    | One cached computation serves all clients; thin, consistent UI           | No offline/client diffing; wire format must anticipate every UI need            |
| Histogram diff with optional Myers fallback                        | Histogram is fast and readable; fallback preserves old behavior          | Known JGit Myers bug requires a defensive timeout                               |
| Char-level Myers + heuristic cleanup for intraline                 | Fine granularity; cleanup rules encode readability judgments             | "Produces some crazy stuff" — needs validation pass and whole-span fallback     |
| `[skip, mark]` run-length intraline encoding                       | Compact; independent of rendering; spans newlines naturally              | Client must replay run-lengths carefully (code-point vs UTF-16 pitfalls)        |
| Whitespace-only chunks sent as `common: true` with both texts      | Change stays inspectable while visually demoted                          | Larger payloads; renderer must special-case a third chunk kind                  |
| `due_to_rebase` provenance tagging via position transformation     | Distinguishes author intent from rebase churn in patch-set comparison    | Complex `EditTransformer` machinery; conflicting edits are silently omitted     |
| Key-location-driven context folding                                | Comments/deep links never collapse; folding stays a pure model transform | Requires splitting chunks pre-render; processor complexity                      |
| Decorations as DOM-annotating `DiffLayer`s                         | Independent, composable, pluginable concerns over one renderer           | Post-render DOM mutation fights the declarative Lit model (two-pass re-renders) |
| Syntax highlighting in a web-worker pool with hard caps            | Keeps main thread responsive on big files                                | Highlighting is asynchronous/best-effort; capped at 20 000 lines                |
| UI supports `syntax_tree`/`move_details` without upstream producer | Shared component serves Google-internal backends too                     | Open-source users get dormant features; capability mismatch is invisible        |

## Sources

- Local tree at the surveyed revision (primary): `polygerrit-ui/app/embed/diff/` (`gr-diff-model/gr-diff-model.ts`, `gr-diff-processor/gr-diff-processor.ts`, `gr-diff/gr-diff-group.ts`, `gr-diff/gr-diff-utils.ts`, `gr-diff-builder/gr-diff-section.ts`, `gr-diff-builder/gr-diff-row.ts`, `gr-diff-builder/gr-diff-text.ts`, `gr-diff-builder/token-highlight-layer.ts`, `gr-syntax-layer/gr-syntax-layer-worker.ts`, `gr-diff-highlight/gr-annotation.ts`, `gr-ranged-comment-layer/gr-ranged-comment-layer.ts`, `gr-context-controls/gr-context-controls.ts`, `gr-diff/gr-diff-element.ts`, `gr-diff/gr-diff.ts`)
- `polygerrit-ui/app/api/diff.ts` — the typed `gr-diff` API surface (`DiffInfo`, `DiffContent`, `DiffIntralineInfo`, `DiffLayer`, `GrDiffCursor`)
- `java/com/google/gerrit/server/patch/` — `IntraLineLoader.java`, `DiffContentCalculator.java`, `DiffOperationsImpl.java`, `PatchScriptBuilder.java`, `filediff/EditTransformer.java`, `gitfilediff/GitFileDiffCacheImpl.java`
- `java/com/google/gerrit/server/diff/DiffInfoCreator.java` — `PatchScript` → `DiffInfo` JSON serialization
- `polygerrit-ui/app/embed/README.md` — reuse statement for the `gr-diff` embed
- [Gerrit REST API: diff entities][rest-diff] — official documentation of `DiffInfo`/`DiffContent`/`DiffIntralineInfo`
- [Gerrit homepage][gerrit-home]

<!-- References -->

[rest-diff]: https://gerrit-review.googlesource.com/Documentation/rest-api-changes.html#diff-info
[gerrit-home]: https://www.gerritcodereview.com/
