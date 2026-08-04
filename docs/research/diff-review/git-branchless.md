# git-branchless (Rust)

A suite of Git workflow tools — smartlog DAG visualization, Mercurial-style revsets, in-memory
rebases, and an event-sourced `git undo` — whose interactive hunk selector was deliberately
extracted as `scm-record`, a reusable ratatui change-selection widget that Jujutsu also embeds
as its builtin diff editor.

| Field             | Value                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------- |
| Language          | Rust (cargo workspace, 17 crates)                                                      |
| License           | MIT OR Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`; scm-record likewise)               |
| Repository        | [arxanas/git-branchless][repo]; companion widget [arxanas/scm-record][scm-record-repo] |
| Documentation     | [Project wiki][wiki], crate docs on docs.rs                                            |
| Category          | stacked-pr (workflow suite with an embedded TUI hunk-selection component)              |
| First release     | Repository history begins 2020-11-17                                                   |
| Latest release    | `v0.11.1` per `git-branchless/Cargo.toml` at the surveyed revision                     |
| Surveyed revision | `03d6ab8dc1a2ff8a2bc44709b93ea6a9038147eb` (2026-07-15)                                |

> [!NOTE]
> `scm-record` lives in a separate repository and is consumed as a crates.io dependency
> (`scm-record = "0.10.1"` in the workspace `Cargo.toml`). It was surveyed from a separate
> checkout at revision `0329360d5f4b90af1c23dcd95d96b9b061b1f969` (2026-06-21). Paths like
> `scm-record/src/ui.rs` below refer to that repository; all other paths are relative to the
> git-branchless tree.

## Overview

### What it solves

Git's porcelain assumes branch-centric workflows and offers no first-class model of "the commits
I am currently working on", no general undo, and no patch-stack ergonomics. git-branchless layers
a Mercurial/Sapling-style experience on top of a normal Git repository: `git sl` (smartlog) draws
only the commits you are actively working on; `git undo` time-travels the whole repository state;
`git move`/`git restack` rebase entire subtrees in memory without touching the working copy;
`git record -i` interactively selects hunks into commits; `git submit` pushes a commit stack to
GitHub or Phabricator. The suite is explicitly "100% compatible with branches" (`README.md`) —
it observes a vanilla repository through hooks rather than owning a parallel store.

### Design philosophy

Everything hangs off an event-sourcing model. From `git-branchless-lib/src/core/eventlog.rs`:

> We use Git hooks to record the actions that the user takes over time, and put them in
> persistent storage. Later, we play back the actions in order to determine what actions the
> user took on the repository, and which commits they're still working on.

The set of "visible" commits is thus _derived state_: replaying the log to any cursor yields the
smartlog, and inverting the events since a cursor yields `git undo`. The second philosophy is
component extraction: the hunk selector is not app code but a library. From the scm-record
`README.md`:

> `scm-record` is a Rust library for a UI component to interactively select changes to include
> in a commit. It's meant to be embedded in source control tooling.

## How it works

### 1. Diff computation & data model

git-branchless computes diffs in-process via libgit2 (`git2::Diff`), never by parsing `git diff`
output. `git-branchless-lib/src/git/diff.rs` is the bridge: `process_diff_for_record` walks the
libgit2 diff with the `foreach` callbacks (file/binary/hunk), collects per-file `GitHunk`
`{old_start, old_lines, new_start, new_lines}` records, then loads the _full_ old and new blob
contents and re-slices them into scm-record's model. The interesting move is that unchanged
context is reconstructed from the old blob between hunks ("If we're starting a new hunk, first
paste in any unchanged lines since the last hunk"), so the UI receives the entire file, not a
±3-line window — the widget owns abbreviation, not the differ.

The model itself (`scm-record/src/types.rs`) is a serde-serializable tree:
`RecordState { commits, files }` → `File { old_path, path, file_mode, sections }` →
`Section::{Unchanged{lines}, Changed{lines}, FileMode{is_checked, mode}, Binary{is_checked, …}}` →
`SectionChangedLine { is_checked, change_type: Added|Removed, line }`. Lines keep their trailing
newline; file-mode changes and binary blobs are modeled as checkable pseudo-sections rendered
inline. Selection state (`is_checked`) lives _inside_ the diff model, and
`File::get_selected_contents()` folds the tree into `(selected, unselected)` full file contents
— the split is a pure function of the annotated diff, which makes commit-splitting trivially
testable and makes the widget VCS-agnostic.

The standalone `scm-diff-editor` front-end computes its own diffs with the `diffy` crate (Myers)
in `scm-diff-editor/src/render.rs`, with `set_context_len(max_lines)` — context length set to
the whole file, same "UI owns abbreviation" principle. Granularity is strictly line-level
everywhere.

### 2. Rendering & layout

scm-record renders a unified, interleaved view: within a `Changed` section all `Removed` lines
precede all `Added` lines (that grouping is established at ingestion, above). Each changed line
carries a `[x]`/`[ ]`/`[~]` tristate toggle box, then a `+`/`-` marker, then the text
(green/red); unchanged lines render dimmed with a 5-column line number chosen so the text aligns
with the `+`/`-` column (`SectionLineView::draw` in `scm-record/src/ui.rs`). Control characters
are replaced with visible styled glyphs — `\t` → `→   `, `\n` → `⏎`, `\r` → `␍`, the C0 range →
`␀`…`␟` — in dark gray, so invisible-character diffs are legible (`replace_control_character`).

The rendering substrate (`scm-record/src/render.rs`) is a small retained-ish layer over ratatui:
a `Component` trait (`fn id() -> Id; fn draw(&self, viewport, x, y)`) draws onto a virtual
canvas addressed in `isize` coordinates; a `Viewport` clips against the terminal rect and a
`Mask` stack, and records a `DrawTrace` — the bounding `Rect` of every component by
`ComponentId`, with draw-order timestamps. Scrolling is simply drawing the tree at
`y = -scroll_offset_y`; the resulting `DrawnRects` map then serves double duty for mouse
hit-testing (`find_component_at`) and scroll-into-view math. A one-row sticky file header plus a
menu bar overlay the scrolled content. The smartlog renderer, by contrast, is not a TUI at all:
`render_graph` in `git-branchless-smartlog/src/lib.rs` produces a `Vec<StyledString>` (cursive
markup) via a recursive child walk with a glyph table (eight commit-cursor glyphs for the
`{main, obsolete, head}` cube, `line`, `line_with_offshoot`, `split`, `merge`,
`vertical_ellipsis`), then flushes them as ANSI text.

### 3. Intra-line & noise handling

None — and the absence is structural, not an oversight of degree. There is no word- or
character-level refinement anywhere in scm-record or the diff bridge, no ignore-whitespace
option, no moved-code detection; the selection model is defined over whole lines because a
per-line checkbox is the unit of user intent (you stage a line or you don't — staging half a
line is meaningless for `git add -p` semantics). This is a useful negative datapoint: a
hunk-_selection_ widget can justify line granularity, but a hunk-_review_ view cannot reuse this
model unchanged, since review reads benefit from intra-line emphasis that selection does not
need.

### 4. Navigation, folding & scale

Navigation is over an explicit selection hierarchy, `SelectionKey::{File, Section, Line}`
(`scm-record/src/ui.rs`): up/down move linearly across visible keys, `PageUp`/`PageDown` jump to
the previous/next item _of the same kind_, left/right (`FocusOuter`/`FocusInner`) move between
hierarchy levels — with the vi-flavored refinement that `h` on an expanded section folds it
instead of moving out. Files and sections have independent expand states in an
`expanded_items: HashSet<SelectionKey>`; a file's expand box shows a _tristate_ (partially
expanded if some sections are folded). Unchanged sections are abbreviated to
`NUM_CONTEXT_LINES = 3` on each side with an ellipsis row, and a context section is skipped
entirely unless an adjacent editable section is expanded (`FileView::draw`). Scroll-into-view
policy is explicit and worth copying: if the focused component fits the viewport, align its
bottom edge; if it is taller than the viewport or partially above, align its top
(`ensure_in_viewport`).

On the smartlog side, scale is handled by _omission_: the graph is built only from the revset's
commits plus merge-bases against main (`build_graph`), and gaps are rendered as "N omitted
commits" ellipsis nodes (`ancestor_info` distance, `num_omitted_descendants` for false heads)
rather than drawing every intermediate commit. Graph queries (ancestors, ranges, GCA, heads) run
on Sapling's segmented DAG (`eden_dag = sapling-dag` wrapper in
`git-branchless-lib/src/core/dag.rs`), which stays fast on repositories with hundreds of
thousands of commits.

### 5. VCS & review integration

This is the subject's densest dimension:

- **Event log.** Git hooks (`post-commit`, `post-rewrite`, `reference-transaction`, …) append
  typed rows to SQLite (`rusqlite`) in `.git/branchless/`: `RewriteEvent`, `RefUpdateEvent`,
  `CommitEvent`, `ObsoleteEvent`, `UnobsoleteEvent`, `WorkingCopySnapshot`
  (`git-branchless-lib/src/core/eventlog.rs`). Events are grouped by a best-effort
  `EventTransactionId` so one rebase reads as one undoable unit. `EventReplayer` folds the log
  to any `EventCursor`; `git undo` (`git-branchless-undo/src/lib.rs`) renders the smartlog _at a
  cursor_ inside a cursive TUI, lets the user step backward/forward by transaction, then applies
  `inverse_event` of everything since the chosen cursor — undo is itself just more events, so it
  is redoable.
- **Revsets.** A lalrpop grammar over a two-variant AST (`Name`, `FunctionCall` —
  `git-branchless-revset/src/ast.rs`) with ~35 builtins (`builtins.rs`): set algebra, `stack()`,
  `draft()`/`public()`, `message()`, `paths.changed()`, `author.date()`, down to
  `tests.passed()` backed by cached `git test` results. Text arguments accept `exact:`,
  `substring:`, `glob:`, `regex:`, `before:`/`after:` prefixes (`pattern.rs`). Every command
  that takes commits takes a revset, including the smartlog's default view — the visualization
  and the selection language are the same layer.
- **In-memory rebase.** `git move`/`restack` build a `RebasePlan` of
  `Pick`/`Merge`/`Replace`/`CreateLabel`/`Reset` commands
  (`git-branchless-lib/src/core/rewrite/plan.rs`) and execute it against the object database
  only: `rebase_in_memory` (`rewrite/execute.rs`) cherry-picks via libgit2 tree merges
  (`cherry_pick_fast`, with `reuse_parent_tree_if_possible`) and `create_commit`, never checking
  out files. Merge commits and conflicts bail out to an on-disk `git rebase` fallback with the
  same plan. Rewrites report `old_oid → new_oid` maps that feed the event log and branch moves.
- **Hunk selection / staging.** `git record -i` builds the scm-record model from the
  index-vs-worktree diff, runs the `Recorder`, then applies `get_selected_contents()` through an
  `update_index` script (`git-branchless-record/src/lib.rs`); `--insert` re-parents sibling
  commits on top of the new commit via the rebase machinery. Uncommitted changes are preserved
  across destructive operations as `WorkingCopySnapshot` commits summarized by
  `summarize_diff_for_temporary_commit` (`diff.rs`).
- **Stacked submission.** `git submit` (`git-branchless-submit/src/lib.rs`) abstracts a `Forge`
  trait — `query_status`, `create`, `update` over `CommitStatus` maps — with three
  implementations: `branch_forge` (plain branch pushes), `GithubForge` (one PR per commit,
  stack-aware; gated off by default as of 2024-04-06 for reliability), and `PhabricatorForge`
  (`arc diff` stacks). Commit↔review linkage rides on trailers/commit metadata
  (`DifferentialRevisionDescriptor` renders `D12345` IDs in the smartlog).
- **Difftool.** `git branchless difftool` is literally `scm_diff_editor::run(opts)`
  (`git-branchless/src/commands/mod.rs`): the same widget in read-only or directory-diff mode,
  usable as a `git difftool`/Mercurial `extdiff` backend. Three-way merges are modeled by
  parsing `diffy`'s diff3 conflict output back into checkable sections with
  dynamically-lengthened conflict markers (`create_merge`, `make_conflict_markers` in
  `scm-diff-editor/src/render.rs`).

### 6. Architecture & reuse

The workspace is aggressively multi-crate: one library crate (`git-branchless-lib` — git
wrappers, DAG, event log, rewrite engine) plus one crate per command family (`-smartlog`,
`-record`, `-undo`, `-revset`, `-submit`, `-move`, `-test`, …), tied together by
`git-branchless-invoke`'s `CommandContext`. Reusable pieces with a life outside the monolith:
`scm-record` (embedded by Jujutsu as `ui.diff-editor`; ships `serde` support so the whole
`RecordState` round-trips as JSON), `scm-diff-editor` (standalone binary), `scm-bisect`
(strategy-generic bisection), and the `sapling-dag`/`cursive`/`ratatui` choices themselves. A
notable wart: the suite carries _two_ TUI stacks — cursive for `git undo`'s dialog-driven
browser, ratatui for scm-record — reflecting the record widget's later extraction. Testing
leans on `TestingScreenshot` + a virtual-terminal backend (`TerminalKind::Testing`), asserting
full-screen text snapshots of the widget, and on the `Component`/`DrawnRects` layer being pure
enough to drive headlessly.

## Strengths

- The event-log/replay model turns "what am I working on", smartlog rendering, and undo into
  one derived-state mechanism — a genuinely different foundation from every snapshot-based tool
  in this catalog.
- scm-record's model-first design: selection state embedded in a serializable diff tree, with
  `(selected, unselected)` extraction as a pure fold — the cleanest hunk-selection data model
  surveyed, and proven reusable (Jujutsu).
- The `Component`/`Viewport`/`DrawnRects` layer gets mouse hit-testing, scroll-into-view, and
  screenshot testing from one bounding-box trace, with ~670 lines of infrastructure.
- In-memory rebases make stack manipulation near-instant and leave the working copy untouched;
  conflict cases degrade gracefully to real `git rebase`.
- Revsets unify querying, visualization scope, and command targets; pattern prefixes and
  test-result predicates (`tests.passed()`) go beyond Mercurial's baseline.
- Careful edge handling in the widget: control-character rendering, tristate boxes at every
  level, quit-confirmation with pending-change counts, empty-file/mode-change/binary sections.

## Weaknesses

- No intra-line refinement, whitespace controls, or syntax highlighting anywhere in the diff
  UI — plain line-level red/green only; review-oriented reading is not the target.
- Two parallel TUI stacks (cursive + ratatui) and two diff engines (libgit2 + diffy) coexist
  for historical reasons.
- The GitHub forge is explicitly flagged too buggy for default use at the surveyed revision;
  Phabricator (deprecated upstream) is the mature path, dating the review-platform story.
- Whole-file context reconstruction means the widget holds both full blobs per file in memory;
  fine for interactive commit sizes, unbounded for pathological files.
- The smartlog's recursive renderer draws simple stacks well but merge topology support is
  visibly patchy (commented-out glyph code paths in `get_child_output`).

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                          | Trade-off                                                                                   |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Event-source repo history via hooks + SQLite, derive all views | One mechanism yields smartlog scope, obsolescence, and general undo/redo           | Requires hook installation (`git branchless init`); history before init is invisible        |
| Selection state (`is_checked`) stored inside the diff model    | `(selected, unselected)` extraction is a pure fold; serde round-trip; easy testing | Model is selection-shaped: no room for word-level runs without a schema change              |
| Widget receives full file contents; UI abbreviates context     | Expand/collapse and correct global line numbers need no re-diffing                 | Memory scales with file size, not diff size                                                 |
| Line-level granularity, no intra-line refinement               | Lines are the unit of staging intent; keeps model and rendering simple             | Unsuitable as-is for review reading, where intra-line emphasis matters                      |
| Virtual canvas + per-component `DrawnRects` trace              | Hit-testing, scroll-into-view, and screenshot tests fall out of one abstraction    | Full redraw per frame to recover geometry; a retained tree would get this incrementally     |
| In-memory rebase via libgit2 tree merges                       | Instant restacks; working copy untouched; no detached-HEAD churn                   | Merge commits and conflicts must fall back to on-disk `git rebase`                          |
| Sapling's segmented DAG instead of walking libgit2             | Ancestry/range/GCA queries stay fast on huge repositories                          | A second commit-graph store to sync; async plumbing bleeds into `dag.rs`                    |
| `scm-record` extracted as a VCS-agnostic crate                 | Reuse (Jujutsu, scm-diff-editor); forces a clean data-model boundary               | Suite ends up with two TUI stacks; widget can't reach into repo state for e.g. highlighting |

## Sources

- Local checkout of [arxanas/git-branchless][repo] at `03d6ab8dc1a2ff8a2bc44709b93ea6a9038147eb`
  (2026-07-15): `git-branchless-lib/src/git/diff.rs`, `git-branchless-lib/src/core/eventlog.rs`,
  `git-branchless-lib/src/core/dag.rs`, `git-branchless-lib/src/core/rewrite/{plan,execute}.rs`,
  `git-branchless-smartlog/src/lib.rs`, `git-branchless-revset/src/{ast,parser,builtins,pattern}.rs`,
  `git-branchless-record/src/lib.rs`, `git-branchless-undo/src/lib.rs`,
  `git-branchless-submit/src/lib.rs`, `git-branchless/src/commands/mod.rs`, `README.md`
- Checkout of [arxanas/scm-record][scm-record-repo] at `0329360d5f4b90af1c23dcd95d96b9b061b1f969`
  (2026-06-21): [`scm-record/src/types.rs`][scm-record-types], [`scm-record/src/ui.rs`][scm-record-ui],
  [`scm-record/src/render.rs`][scm-record-render], [`scm-diff-editor/src/render.rs`][scm-diff-editor-render],
  [`README.md`][scm-record-readme]
- [git-branchless wiki][wiki] (command documentation)

<!-- References -->

[repo]: https://github.com/arxanas/git-branchless/tree/03d6ab8dc1a2ff8a2bc44709b93ea6a9038147eb
[scm-record-repo]: https://github.com/arxanas/scm-record/tree/0329360d5f4b90af1c23dcd95d96b9b061b1f969
[scm-record-types]: https://github.com/arxanas/scm-record/blob/0329360d5f4b90af1c23dcd95d96b9b061b1f969/scm-record/src/types.rs
[scm-record-ui]: https://github.com/arxanas/scm-record/blob/0329360d5f4b90af1c23dcd95d96b9b061b1f969/scm-record/src/ui.rs
[scm-record-render]: https://github.com/arxanas/scm-record/blob/0329360d5f4b90af1c23dcd95d96b9b061b1f969/scm-record/src/render.rs
[scm-diff-editor-render]: https://github.com/arxanas/scm-record/blob/0329360d5f4b90af1c23dcd95d96b9b061b1f969/scm-diff-editor/src/render.rs
[scm-record-readme]: https://github.com/arxanas/scm-record/blob/0329360d5f4b90af1c23dcd95d96b9b061b1f969/README.md
[wiki]: https://github.com/arxanas/git-branchless/wiki
