# gitui (Rust)

A keyboard-driven ratatui terminal git client whose diff view is a unified, hunk-oriented staging surface fed by an async, hash-deduplicated `libgit2` pipeline — fast and fluid on giant repositories, but deliberately line-granular and review-platform-free.

| Field             | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| Language          | Rust (edition 2021, `rust-version = "1.88"`)                           |
| License           | MIT                                                                    |
| Repository        | [github.com/gitui-org/gitui][gitui-repo]                               |
| Documentation     | `README.md`, `KEY_CONFIG.md`, `THEMES.md`, `FAQ.md` in-tree            |
| Category          | TUI git client (working-copy/commit diff viewer + interactive staging) |
| First release     | `v0.1` lineage, 2020-05-10 (`0.2.2` per `CHANGELOG.md`)                |
| Latest release    | `0.28.1`, 2026-03-21 (per `CHANGELOG.md` and root `Cargo.toml`)        |
| Surveyed revision | `2fa693cb6ed431b21ebc300dd02e83c2476699ce` (2026-07-31)                |

## Overview

### What it solves

`gitui` replaces the index/commit/diff/stash/blame/log use-cases people reach for a GUI git client for, without leaving the terminal. Its founding complaint is scale: per `README.md`,

> "Unfortunately popular git GUIs all fail on giant repositories or become unresponsive and unusable."

The README benchmarks parsing the entire Linux kernel repository (900k+ commits): `gitui` 24 s / 0.17 GB versus `lazygit` 57 s / 2.6 GB and `tig` 4 m 20 s / 1.3 GB, with no freezes. The diff viewer is not a read-only pager — it is the primary surface for staging, unstaging, discarding, and resetting at file, hunk, and single-line granularity.

### Design philosophy

Two principles dominate. First, responsiveness through asynchrony: the feature list in `README.md` promises an

> "Async git API for fluid control"

which is realized as a dedicated crate, `asyncgit`, described in its `Cargo.toml` as "allow using git2 in a asynchronous context". Every potentially slow git operation (status, diff, blame, log walk, fetch/push) runs on a `rayon` pool or dedicated thread and reports back over `crossbeam` channels; the UI thread never blocks on `libgit2`. Second, discoverability over memorization — "Context based help (**no need to memorize** tons of hot-keys)" (`README.md`): every component enumerates its currently applicable commands (`CommandInfo` in `src/components/command.rs`), rendered live in a bottom command bar (`src/cmdbar.rs`).

## How it works

### 1. Diff computation & data model

Diffs are computed **in-process by `libgit2`** via the `git2` crate (`git2 = "0.21"` in `asyncgit/Cargo.toml`); there is no shelling out to git and no server involvement. `asyncgit/src/sync/diff.rs::get_diff_raw` builds a `git2::Diff` from one of three sources selected by a `DiffType` enum (`asyncgit/src/diff.rs`): `WorkDir` (`diff_index_to_workdir`), `Stage` (`diff_tree_to_index` against `HEAD`'s tree), `Commit(id)`, or `Commits(OldNew<CommitId>)` for a two-commit compare. The algorithm is therefore whatever `libgit2`'s xdiff defaults to (**Myers**); `gitui` never sets `patience`/`minimal` flags. The only knobs exposed are the `DiffOptions` struct — `ignore_whitespace: bool`, `context: u32` (default 3), `interhunk_lines: u32` — which map 1:1 onto `git_diff_options`.

Granularity is **line-only**. `raw_diff_to_file_diff` walks `diff.print(DiffFormat::Patch, …)` callbacks and flattens them into an owned, render-agnostic model (`asyncgit/src/sync/diff.rs`):

- `FileDiff { hunks, lines, untracked, sizes: (u64, u64), size_delta }`
- `Hunk { header_hash: u64, lines: Vec<DiffLine> }` — the hunk's _identity_ is a hash of its `@@` header (`old_start/old_lines/new_start/new_lines`), not an index
- `DiffLine { content: Box<str>, line_type: None|Header|Add|Delete, position: { old_lineno, new_lineno } }`

Two details are notable. Untracked files (which `libgit2` reports as a bare delta with no hunks) get a **synthetic diff**: the file is read from disk and `Patch::from_buffers(&[], …, content, …)` fabricates an all-additions patch so new files render like any other diff. And every model type derives `Hash` — hashes are used pervasively as change/identity detectors (see §6).

### 2. Rendering & layout

**Unified only.** There is no side-by-side mode anywhere in the tree. `DiffComponent` (`src/components/diff.rs`, ~1060 lines) renders the `FileDiff` into a ratatui `Paragraph` inside a bordered `Block`. The left gutter is not line numbers — it is a **1-cell hunk bracket** drawn with box-drawing symbols: `┌` on the hunk header line, `│` on interior lines, `└` on the last line, styled brighter when that hunk is selected (`get_line_to_add`). Old/new line numbers are carried in the model (`DiffLinePosition`) but only used for line-staging bookkeeping, never displayed.

Each line is two spans: the bracket symbol and the content styled by `theme.diff_line(line_type, selected)` — plain add/delete/context coloring from `src/ui/style.rs` (`ron`-configurable themes). Tabs are normalized via `tabs_to_spaces`; an empty added/removed line renders as a configurable line-break glyph (`¶` by default, `theme.line_break()`). Selected lines are padded with spaces to full width so the selection bar spans the pane.

**No wrapping**: long lines are handled with a horizontal scroll (`HorizontalScroll`), with `longest_line` precomputed at diff-update time (max over all hunk lines after tab expansion, +1 for the bracket column) to bound the scroll range. **No syntax highlighting in diffs**: `gitui` bundles `syntect` (+`two-face` extended grammars), but only the _file viewer_ (Files tab / revision-file popup, `src/ui/syntax_text.rs`) uses it; the diff pane is colored purely by add/remove/context type. Alignment across panes does not apply (single pane).

### 3. Intra-line & noise handling

Largely **absent — a deliberate scope cut**. There is no word- or character-level refinement of changed lines, no changed-region highlighting inside a line, and no moved-code detection. The only noise control is `libgit2`'s `ignore_whitespace` flag plus the `context`/`interhunk_lines` counts, toggled at runtime in the options popup (`src/popups/options.rs`: "Ignore whitespaces", "Context lines", "Inter hunk lines") and persisted per-repository as `ron` (`src/options.rs`). Toggling any of them changes the `DiffParams` hash, which transparently invalidates the request cache and recomputes (§6). There is no formatting-noise classification and no structural/AST awareness of any kind.

### 4. Navigation, folding & scale

Selection is line-based with an optional anchor range: `enum Selection { Single(usize), Multiple(usize, usize) }` over the _flattened_ line index across all hunks; `shift_down`/`shift_up` grow the range, and `find_selected_hunk` re-derives the containing hunk after every move. Dedicated keys jump hunk-to-hunk (`diff_hunk_next`/`diff_hunk_prev`), and `diff_hunk_move_up_down` calls `vertical_scroll.move_area_to_visible(height, hunk_start, hunk_end)` — scrolling the _whole target hunk_ into view rather than just the cursor line. Home/End/PageUp/PageDown and horizontal arrows complete the model; mouse support exists app-wide but diff interaction is keyboard-first.

There is **no folding** of unchanged regions (context is globally shrunk/grown via the `context` option instead) and no file-tree-plus-diff single view: the Status tab shows staged/unstaged file lists (`src/components/changes.rs`, tree-shaped via the in-repo `filetreelist` crate) side-by-side with _one_ file's diff; selecting a different file re-requests its diff.

Scale guards are architectural rather than truncation-based: nothing caps diff size, but (a) the diff is computed off-thread per-file, never for the whole working copy at once; (b) rendering culls aggressively — `get_text(width, height)` iterates hunks, skips invisible ones wholesale via `hunk_visible(hunk_min, hunk_max, min, max)`, and materializes only the viewport's worth of ratatui `Line`s per frame; (c) binary/oversized-content cases degrade to a one-line size summary (`get_text_binary`: `size: 1.2 kB -> 3.4 kB (+2.2 kB)`); (d) file-viewer syntax highlighting streams progress (`AsyncProgressBuffer`, ≥200 ms between updates) and shows plain text (`Either::Right(String)`) until the highlighted version (`Either::Left(SyntaxText)`) arrives.

### 5. VCS & review integration

All git plumbing is `libgit2` via `asyncgit/src/sync/*` (~30 modules: status, branches, rebase, stash, submodules, hooks via the in-repo `git2-hooks` crate, gpg signing). The diff pane is the staging UI, with three mechanisms worth naming:

- **Hunk (un)stage/reset** (`asyncgit/src/sync/hunks.rs`): re-runs the diff fresh, then `repo.apply(&diff, ApplyLocation::Index, …)` with a `hunk_callback` that accepts only the hunk whose header hash equals the UI-remembered `header_hash`. The hunk survives as an identity across the UI→backend boundary without holding any `git2` object alive. Unstage applies the _reverse_ diff (`reverse: true`) to the index; reset applies the reverse to the workdir.
- **Line-level stage/discard** (`asyncgit/src/sync/staging/`): the selected `DiffLinePosition`s (old/new line numbers) drive `apply_selection`, which — as the comment says, "heavily inspired by the great work in nodegit" — _reconstructs the full post-operation file content_ from the old file lines plus/minus the selected hunk lines, then writes that blob into the index (or workdir for discard). Patch-file surgery is avoided entirely.
- **Refresh loop**: a debounced `notify` filesystem watcher (`src/watcher.rs`) plus optional polling ticker trigger re-status/re-diff, so external edits appear live.

Merge/rebase conflicts are handled at the workflow level (`asyncgit/src/sync/merge.rs`, `rebase.rs`: `mergehead_ids`, `abort_pending_state`, continue/abort rebase; conflicted files marked `!` in the status tree) — but the diff pane has **no 3-way conflict view**. There is **no PR/review-platform integration whatsoever**: no comments, no GitHub/GitLab API, no stacked-PR awareness; `gitui` is strictly a local-repository tool.

### 6. Architecture & reuse

Single process, two main crates plus four utility crates (`filetreelist`, `git2-hooks`, `scopetime` — a scope-timing profiler macro used throughout — and `invalidstring`). The split is the load-bearing decision: `asyncgit` wraps synchronous `git2` calls in async request objects, and the binary crate owns all ratatui rendering.

The event loop (`src/gitui.rs`) is a `crossbeam` `select_event` over **five channels**: terminal input, git notifications, app notifications (e.g. syntax-highlight progress), a polling ticker, and the filesystem watcher. Two dedup patterns keep it fluid:

- `AsyncDiff` (`asyncgit/src/diff.rs`) keys each request by `hash(DiffParams)`; a request matching the in-flight/current hash returns the cached `FileDiff` synchronously; otherwise it spawns on `rayon_core`, and a worker that finishes _after_ a newer request took over sends `AsyncGitNotification::FinishUnchanged`, which the event loop **discards without redrawing**.
- `AsyncSingleJob` (`asyncgit/src/asyncjob/mod.rs`) is a one-slot latest-wins queue ("keeps overwriting the next job until it is actually taken") used for syntax highlighting, blame, and tree loading — a stale-work eliminator in ~180 lines.
- On the UI side, `DiffComponent::update` hashes the incoming `FileDiff` and skips all state churn (selection reset, longest-line scan) when the hash is unchanged.

Reusable ideas: the hunk-header-hash identity scheme, the nodegit-style line-application algorithm, `AsyncSingleJob`, and the `CommandInfo` context-help protocol. The rendering itself is monolith-bound (components draw directly into ratatui frames, keyed to the app's `Queue`/`InternalEvent` bus), and `asyncgit` — though a published crate — is shaped by gitui's notification enums.

## Strengths

- Proven scale story: async-everything plus viewport culling keeps huge repositories responsive (the README's Linux-kernel benchmark: 24 s / 0.17 GB, no freezes).
- Best-in-class staging granularity in a TUI: file, hunk, and arbitrary multi-line selections, with the same selection driving stage, unstage, and discard.
- Robust hunk identity (header hash) decouples the UI model from live `git2` objects and survives recomputation between display and apply.
- Latest-wins job scheduling (`AsyncSingleJob`, hash-keyed `AsyncDiff`, `FinishUnchanged`) eliminates redundant work and redraws with very little code.
- Context-sensitive command bar makes a large keymap discoverable; keymap and themes are user-configurable `ron` files.
- Clean separation of a render-agnostic diff model (`FileDiff`/`Hunk`/`DiffLine`) from presentation.

## Weaknesses

- Line-granular only: no word/char intra-line refinement, so a one-token edit on a long line reads as full remove+add — exactly the failure mode that makes formatting noise expensive to review.
- No side-by-side view, no line numbers in the diff gutter, no wrapping (horizontal scroll only).
- No syntax highlighting in diffs despite shipping `syntect` for the file viewer.
- Noise handling limited to `libgit2`'s `ignore_whitespace`; no moved-code detection, no structural awareness, diff algorithm not selectable.
- No review-platform features: no PR model, comments, or multi-commit review flow beyond a two-commit compare popup.
- No 3-way merge/conflict editor; conflicts are only flagged in the status tree.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                       | Trade-off                                                                                    |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| In-process `libgit2` via a dedicated async wrapper crate        | No subprocess latency/parsing; UI thread never blocks; portable                 | Bound to `libgit2` semantics (Myers only as used; sparse-repo and LFS gaps tracked upstream) |
| Owned line-based `FileDiff` model, fully materialized per file  | Render-agnostic, hashable for cheap change detection, no `git2` lifetimes in UI | Whole-file diff held in memory; no streaming for pathological single-file diffs              |
| Hunk identity = hash of `@@` header                             | Apply-time re-diff can relocate the hunk without index bookkeeping              | Ambiguous if two hunks ever had identical headers; silently misses if options drift          |
| Line staging by reconstructing file content (nodegit approach)  | Avoids fragile patch editing; handles partial selections inside hunks naturally | Reads and rewrites the whole file/blob per operation                                         |
| Unified view, no intra-line refinement, no diff syntax coloring | Small, fast render path; selection/staging UX stays simple                      | Weak at _reading_ dense changes — it optimizes for acting on diffs, not reviewing them       |
| One-slot latest-wins async queues + hash dedup                  | Fluid typing/scrolling under load; stale results never repaint                  | Intermediate results discarded; no multi-request pipelining                                  |
| Keyboard-first with a live command bar                          | Discoverability without modal menus                                             | Command enumeration runs every frame for every visible component                             |

## Sources

- Local checkout at revision `2fa693cb6ed431b21ebc300dd02e83c2476699ce` (2026-07-31): `asyncgit/src/sync/diff.rs`, `asyncgit/src/diff.rs`, `asyncgit/src/sync/hunks.rs`, `asyncgit/src/sync/staging/mod.rs`, `asyncgit/src/asyncjob/mod.rs`, `src/components/diff.rs`, `src/ui/syntax_text.rs`, `src/components/syntax_text.rs`, `src/gitui.rs`, `src/watcher.rs`, `src/popups/options.rs`, `src/tabs/status.rs`, `README.md`, `CHANGELOG.md`
- [gitui repository][gitui-repo]
- [`README.md` at the surveyed revision][gitui-readme] (motivation, benchmarks, feature list)
- [nodegit][nodegit] (credited inspiration for the line-staging algorithm in `asyncgit/src/sync/staging/mod.rs`)

<!-- References -->

[gitui-repo]: https://github.com/gitui-org/gitui
[gitui-readme]: https://github.com/gitui-org/gitui/blob/2fa693cb6ed431b21ebc300dd02e83c2476699ce/README.md
[nodegit]: https://github.com/nodegit/nodegit
