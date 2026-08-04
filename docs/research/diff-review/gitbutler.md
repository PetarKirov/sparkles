# GitButler (Rust + Svelte/TypeScript)

A Tauri desktop Git client (plus the `but` CLI sharing the same Rust engine) whose signature move is
partitioning a **single worktree diff across multiple "virtual" branches** — hunk assignment, line-level
dependency locks, and per-branch stacked PRs — rather than innovating in diff rendering itself.

| Field             | Value                                                                              |
| ----------------- | ---------------------------------------------------------------------------------- |
| Language          | Rust (engine, ~60 crates), Svelte 5 + TypeScript (desktop UI), ratatui (CLI TUI)   |
| License           | FSL-1.1-MIT (Fair Source; each release becomes MIT after two years) — `LICENSE.md` |
| Repository        | <https://github.com/gitbutlerapp/gitbutler>                                        |
| Documentation     | <https://docs.gitbutler.com>                                                       |
| Category          | GUI Git client / virtual-branch & stacked-PR tool                                  |
| First release     | First commit 2023-01-31; earliest tag `v0.0.24` (2023)                             |
| Latest release    | Rolling `nightly/0.5.x` tags (surveyed tree at `nightly/0.5.2140` era)             |
| Surveyed revision | `db336ed1e7e110f03e8a7dd5dc5e2ee8b3110545` (2026-08-04)                            |

## Overview

### What it solves

GitButler lets one worktree hold the changes of several branches at once. Uncommitted hunks are
_assigned_ to lanes (stacks of branches), committed independently per lane, and pushed as separate
(optionally stacked) pull requests — without ever switching branches. The workspace is materialized as
a real Git commit: an octopus merge of every lane tip under the ref `gitbutler/workspace`
(`crates/but-workspace/src/lib.rs`: "_A GitButler concept of the combination of one or more branches
into one worktree. This allows multiple branches to be perceived in one worktree, by merging multiple
branches together._"). Around this core it layers easy commit surgery (amend/move/squash by
drag-and-drop or CLI), an operations log for unlimited undo (`but-oplog`), first-class conflicted
commits, and forge integration (GitHub/GitLab/Bitbucket/Gerrit) including native GitHub stacked-PR
registration.

### Design philosophy

The engine is mid-rewrite from the legacy `gitbutler-*` crates to the `but-*` family, and the internal
model is deliberately drifting from product-level abstractions toward plain Git graph concepts.
`crates/WORKSPACE_MODEL.md` states it directly:

> "GitButler is moving away from **stacks** as a primary internal abstraction. Stacks are useful for
> users and UI, but Git itself has commits, refs, parent edges, and reachable subgraphs. New logic
> should generally model behavior in terms of Git-representable concepts and graph relationships."

The same document prescribes layering: `but_graph::Graph` for topology questions, the graph editor
(`but_rebase::graph_rebase::Editor`) for history mutations, and the workspace projection
(`but_workspace::RefInfo`) strictly as a lossy presentation view. `README.md` positions the product as
"a friendlier and more powerful drop-in Git user interface replacement — for you and your agents";
the AI-agent surface (MCP server, `but-tools`, `but-comments`) is a first-class consumer of the same
engine as the GUI.

## How it works

### 1. Diff computation & data model

All diffs are computed **in-process via gitoxide** (`gix`, pinned to a git revision of
`GitoxideLabs/gitoxide` in the workspace `Cargo.toml`; `git2` survives only behind the `but-oxidize`
transition shim). The central entry point is `UnifiedPatch::compute` in
`crates/but-core/src/unified_diff.rs`: both blob states pass through gix's diff pipeline (`git`
clean/smudge filters, `.gitattributes`, binary-to-text conversion —
`Mode::ToGitUnlessBinaryToTextIsPresent`), then
`gix::diff::blob::diff_with_slider_heuristics(algorithm, &input)` runs **imara-diff** with git's
slider/indent heuristic; the `algorithm` comes from the prepared platform, i.e. the repository's
`diff.algorithm` config (Myers by default, histogram if configured). Line granularity only; the result
is re-serialized by `gix::diff::blob::UnifiedDiff` into per-hunk **unified-diff text**.

The wire type `DiffHunk` (`old_start/old_lines/new_start/new_lines` + a `BString` holding the literal
`@@ …` hunk text) is what crosses every boundary — Tauri IPC to Svelte, the CLI TUI, the SDK schema
(`export-schema` feature). Hunk bytes are run through `chardetng` encoding detection and converted to
UTF-8 before serialization. `UnifiedPatch` is a sum type `Patch | Binary | TooLarge { size_in_bytes }`,
with `TooLarge` triggered by git's `core.bigFileThreshold`. Worktree status comes from gix's status
machinery (`crates/but-core/src/diff/worktree.rs`): a tree↔index plus index↔worktree walk with
rename tracking (`TrackRenames`), boiled down into `TreeChange` values — deliberately "a `git status`
… boiled down into all the changes that one would have to add into `HEAD^{tree}`".

Notably, the **frontend re-parses the unified-diff text**: `parseHunk` in
`packages/ui/src/lib/utils/diffParsing.ts` regex-parses the `@@` header and walks `+`/`-`/context
prefixes into `ContentSection`s. The diff is computed once in Rust, but its structure is recovered
twice (TS UI and the ratatui viewer in `crates/but/src/tui/diff_viewer.rs` do their own parsing).

### 2. Rendering & layout

**Unified view only — there is no side-by-side mode anywhere in the tree.** Each hunk renders as its
own bordered card (`packages/ui/src/lib/components/hunkDiff/HunkDiff.svelte`), a table with two line-number
gutter columns (old/new), an optional per-row staging checkbox column, a lock-indicator column, and
the code cell (`HunkDiffRow.svelte`). Wrapping is a CSS toggle (`white-space: var(--pre-wrap)`), tab
width a CSS variable.

Syntax highlighting is **shiki** (`shiki ^4`, `packages/ui/src/lib/utils/shikiHighlighter.ts`),
applied **line by line**: `toTokens` tokenizes a single line and emits prebuilt HTML
`<span style="color:…">` strings, memoized in per-language LRU caches (2000 lines). Because shiki
grammars are stateful, single-file-component languages (Svelte/Vue) mis-highlight script bodies; the
workaround in `diffParsing.ts` tokenizes the line with _both_ the SFC grammar and TypeScript and keeps
whichever produces **more distinct colors** (`countDistinctColors`). Highlighting is asynchronous:
rows render plain first and re-render when the highlighter loads or the theme changes
(`onHighlighterChange` clears all caches).

Row alignment across "panes" does not arise (no split view); word-diff pairing (below) substitutes for it.

### 3. Intra-line & noise handling

Word/char refinement is done **in the frontend, per hunk**, with `diff-match-patch`
(`charDiff` = `diff_main` + `diff_cleanupSemantic` in `diffParsing.ts`). The pairing heuristic in
`generateRows` is strict: an intra-line diff is computed only when a removed section is immediately
followed by an added section **with the same number of lines**, pairing line _i_ with line _i_.
Guards: skipped when the previous section is context, when the first line is effectively empty, and
when any involved line exceeds **300 characters**. Two render modes: side-tinted rows with
`token-inserted`/`token-deleted` spans, or `inlineUnifiedDiffs` which collapses each pair into a
single row with strikethrough deleted fragments (`computeBaseInlineWordDiff`).

There is **no whitespace-ignore mode, no formatting-noise suppression, and no moved-code detection**
in either backend or frontend — the only noise-adjacent machinery is imara-diff's slider heuristic
(better hunk placement) and `diff_cleanupSemantic` (nicer word boundaries). The `--fix-formatting`
flag on `but reword` (`crates/but/src/args/mod.rs`) re-wraps _commit messages_ to 72 columns, not diffs.

### 4. Navigation, folding & scale

Navigation is file-centric: file lists per lane/commit open a `UnifiedDiffView`
(`apps/desktop/src/components/diff/UnifiedDiffView.svelte`); there is no in-diff hunk jump list and
**no context expansion** — context is a fixed global `context_lines` in `AppSettings`
(`crates/but-settings/src/lib.rs`), so unchanged regions between hunks are simply absent.

Scale guards are layered:

- Backend: `UnifiedPatch::TooLarge` via `core.bigFileThreshold`; `Binary` short-circuit; image files
  get a dedicated `ImageDiff` component.
- Frontend: `LARGE_DIFF_THRESHOLD = 1000` changed lines hides the diff behind a `HiddenDiffNotice`
  "show anyway" click; hunk components mount progressively (`INITIAL_HUNKS = 5`, then
  `HUNKS_PER_FRAME = 10` per `requestAnimationFrame`) to keep the main thread responsive.
- Caching: `generateRows` splits the pipeline into expensive **base rows** (tokenization + word diff),
  LRU-cached under a djb2 content hash of the hunk (`hashSubsections`), and a cheap O(n) overlay pass
  (`applyRowState`) that stamps selection and lock state per render — so toggling line selection never
  re-tokenizes.

### 5. VCS & review integration

This is the subject's center of gravity.

- **Hunk assignment** (`crates/but-hunk-assignment`): every uncommitted hunk carries a
  `HunkAssignment { id: Uuid, hunk_header, path, branch_ref_bytes: Option<FullName>, … }` persisted in
  SQLite (`but-db`, rusqlite). On each worktree change, `reconcile.rs` matches fresh hunks against
  stored ones by **range intersection** (`intersects`: same path, old _and_ new ranges overlap; a
  headerless assignment means whole-file). One old hunk → adopt its identity; several → adopt from the
  hunk with most lines, and optionally reset to unassigned when the overlapping hunks pointed at
  _different_ branches (`MultipleOverlapping::SetNone`). Stable UUIDs survive editing; merged hunks
  inherit the larger side's id. Assignment targets are branch refs, with `stack_id` derived via
  workspace projection.
- **Hunk dependency / locking** (`crates/but-hunk-dependency`): computes, for every uncommitted hunk,
  which commits it _must_ land in. Each stack's commits are diffed parent-to-child bottom-up
  (`InputStack::commits_from_base_to_tip`) and folded into `WorkspaceRanges` — per-path lists of
  `HunkRange { target, commit_id, start, lines, line_shift }`. Incoming commit hunks _displace_ earlier
  ranges (`HunkRange::receive` in `ranges/hunk.rs` splits a range into above/below remnants and
  accumulates line shifts), so the final structure maps **current worktree line numbers → the commit
  that last touched them**. A worktree hunk intersecting such a range is **locked** to that commit's
  stack (`HunkLock { target, commit_id }`); the UI paints per-line lock icons
  (`getLineLocks` in `apps/desktop/src/lib/hunks/hunk.ts`) and blocks dragging the hunk to another lane.
  The crate's module docs candidly label the context-line-based approach a port awaiting a
  state-based/blame-shaped rewrite.
- **Committing** is tree surgery, not index staging: a `DiffSpec { previous_path, path, hunk_headers }`
  (`crates/but-core/src/diff_types.rs`) selects changes; partial line selection is encoded as
  sub-hunks with one side zero-length (`apps/desktop/src/lib/hunks/hunk.ts` expects "a whole side
  0'ed out"). `but-workspace/src/commit_engine` applies specs against a base commit
  (`Destination::NewCommit | AmendCommit`) and auto-rebases all descendants; conflicts don't abort —
  commits can be _marked conflicted_ and resolved later ("Rebases always succeed", `README.md`).
- **Undo**: `but-oplog` snapshots the entire project state (including uncommitted changes) around every
  operation; `but oplog restore <sha>` time-travels.
- **Forge / PRs** (`crates/but-forge` + `but-github`/`but-gitlab`/`but-bitbucket`/`but-gerrit`):
  review listing/creation/merge with per-forge backends, CI check status (`ci.rs`), review templates,
  auto-merge and draftiness toggles. **Stacked PRs**: one PR per branch in a stack, bases chained;
  `review.rs` (`restore_native_stacks`, `sync_reviews`) reconciles them against **GitHub's native
  stacked-PR API** (`but_github::stacks`: create/dissolve/`unstack_conflicting`/`finish`), retiring the
  older description-footer approach — footers are now stripped since "GitHub now renders the native
  stack" (`crates/but-forge/src/review.rs`). Gerrit support rides the same abstraction with
  `Change-Id` handling (`but-gerrit`).
- **Review comments** (`crates/but-comments`): ephemeral comments anchored to diff lines, shared
  between GUI and CLI agents. Anchors snapshot the line's content plus neighbours; `list_comments`
  re-locates each comment **by content** in the current diff (change-id-addressed for commits, so
  anchors survive amend/rebase) and auto-archives comments whose line vanished. Storage is a plain
  JSON file, "deliberately the lightest possible storage while the feature proves itself".

### 6. Architecture & reuse

Tauri 2 shell (`crates/gitbutler-tauri`) exposing the Rust engine to a Svelte 5 SPA over IPC;
`crates/but-api` defines the command surface, with generated TS types consumed via `@gitbutler/but-sdk`
(JSON-schema export macros throughout the crates). The **same engine** backs: the `but` CLI
(`crates/but`, clap + a ratatui TUI with an interactive diff viewer `src/tui/diff_viewer.rs`, pickers,
and `but diff --tui`), an MCP server and agent toolset (`but-mcp-app`, `but-tools`, `but-action`,
`but-claude`-style hooks), and a web/`lite` frontend. A filesystem watcher (`gitbutler-filemonitor`)
drives live re-diffing/reconciliation.

The crate graph is explicitly two-generation: legacy `gitbutler-*` crates are quarantined behind
`legacy` features and a "**Do not use!**" module in `but-workspace`, while the `but-*` rewrite follows
`WORKSPACE_MODEL.md`'s graph-first layering. Reusable ideas: the `but-core` diff layer (a thin,
well-factored gix wrapper), the `but-hunk-dependency` range-tracking algorithm, and the content-anchored
comment scheme are all conceptually portable; the UI diff components live in a separate `@gitbutler/ui`
package with Storybook but are Svelte-bound. The rendering path itself (unified-text → TS re-parse →
HTML-string tokens) is monolith-shaped and duplicated across GUI and TUI.

> [!NOTE]
> This survey covers the desktop app, `packages/ui`, and the `but-*` engine crates at the pinned
> revision; the `apps/web`/`apps/lite` frontends and the agent/MCP surfaces were only skimmed.

## Strengths

- The **only tool surveyed that partitions one worktree diff across branches**, with a worked-out
  identity model: UUID-stable hunk assignments reconciled by range intersection, surviving edits and merges.
- **Line-precise dependency locks**: `WorkspaceRanges` tracks every commit's hunks through subsequent
  displacement, so the UI can say _per line_ "this change can only go into commit X of lane Y" — the
  correctness backbone for amend/absorb across stacks.
- Clean in-process diff stack on gitoxide: filters/`.gitattributes` honored, encoding detection,
  binary/too-large classification, git-config-driven algorithm — no `git` subprocess parsing anywhere.
- Pragmatic frontend performance engineering: base-row/content-hash caching, per-language token LRUs,
  rAF-budgeted hunk mounting, large-diff interlock.
- Stacked-PR lifecycle automation against GitHub's **native** stack API, with graceful
  dissolve/recreate reconciliation and footer cleanup; multi-forge abstraction including Gerrit.
- Rebase-surviving, content-re-anchored diff comments shared by GUI and CLI agents.

## Weaknesses

- **No side-by-side view, no context expansion, no ignore-whitespace, no moved-code detection** — as a
  pure diff _viewer_ it is well below GitHub/delta/difftastic feature baselines.
- Word-level refinement only fires for equal-line-count removed/added section pairs with naive *i*↔*i*
  pairing — unbalanced rewrites get no intra-line highlighting at all.
- The diff crosses the IPC boundary as unified-diff _text_ and is re-parsed (regex) in TypeScript and
  again in the CLI TUI; hunk structure exists three times in three languages.
- Line-by-line shiki tokenization breaks stateful grammars (multi-line strings/comments); the
  "more-distinct-colors" fallback is a heuristic patch over a structural problem.
- Hunk-dependency tracking is context-line-based and acknowledged in its own docs as awaiting a
  state-based rewrite; `errors` fields ship partial results to the UI.
- Legacy/rewrite duality (`gitbutler-*` vs `but-*`, `legacy` features, `_Diff2`) makes the tree hard to
  navigate and doubles some code paths.

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                          | Trade-off                                                                                     |
| --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Workspace = real octopus merge commit (`gitbutler/workspace` ref)           | Multiple branches visible in one worktree; everything stays Git-representable      | Managed ref/mode complexity; tools outside GitButler see a strange HEAD                       |
| Hunk assignment as persisted DB state reconciled against live diffs         | Uncommitted work needs stable identity across edits; enables lanes without staging | Heuristic identity (overlap + biggest-hunk adoption) can mis-attribute after heavy edits      |
| Line-range dependency tracking from per-commit diffs                        | Precise "which commit owns this line" locks; safe amend/absorb targeting           | Context-line/pure-diff approach is approximate; self-documented as needing a blame-based redo |
| Ship hunks as unified-diff text, re-parse per frontend                      | One canonical, human-debuggable wire format; SDK-friendly                          | Triple parsing, no shared structured model between Rust/TS/TUI                                |
| Unified-only rendering, one card per hunk                                   | Matches drag-a-hunk-to-a-lane interaction; simpler than split alignment            | No side-by-side comparison; weak for reviewing large rewrites                                 |
| Frontend word diff (`diff-match-patch`) instead of backend refinement       | Zero backend changes; runs only on visible hunks                                   | Equal-line-count pairing constraint; duplicated diff logic and thresholds in TS               |
| Commit engine rewrites trees + auto-rebases descendants; conflicts are data | "Rebases always succeed"; commit surgery becomes cheap primitives                  | Conflicted-commit state is nonstandard; requires custom resolution UX everywhere              |
| Same engine for GUI, CLI, MCP/agents                                        | One behavior surface for humans and agents; CLI/TUI parity for free                | API layer (`but-api`/SDK schemas) must version every internal type                            |
| Graph-first rewrite direction (`WORKSPACE_MODEL.md`)                        | Stacks/lanes proved too lossy as source of truth for mutations                     | Long-lived legacy/new split; two vocabularies coexist in the tree                             |

## Sources

- Surveyed tree: local checkout at `db336ed1e7e110f03e8a7dd5dc5e2ee8b3110545` (2026-08-04) — key files:
  `crates/but-core/src/unified_diff.rs`, `crates/but-core/src/diff/worktree.rs`,
  `crates/but-core/src/diff_types.rs`, `crates/but-hunk-assignment/src/{lib,reconcile}.rs`,
  `crates/but-hunk-dependency/src/{lib,input}.rs`, `crates/but-hunk-dependency/src/ranges/{mod,hunk}.rs`,
  `crates/but-workspace/src/{lib.rs,commit_engine/mod.rs}`, `crates/WORKSPACE_MODEL.md`,
  `crates/but-forge/src/review.rs`, `crates/but-comments/src/lib.rs`,
  `crates/but/src/tui/diff_viewer.rs`, `packages/ui/src/lib/utils/diffParsing.ts`,
  `packages/ui/src/lib/components/hunkDiff/*.svelte`,
  `apps/desktop/src/components/diff/UnifiedDiffView.svelte`, `apps/desktop/src/lib/hunks/hunk.ts`,
  `apps/desktop/src/components/views/MultiStackView.svelte`
- [GitButler repository][gitbutler-repo]
- [GitButler end-user documentation][gitbutler-docs]
- [GitButler stacked-branches docs][gitbutler-stacked]

<!-- References -->

[gitbutler-repo]: https://github.com/gitbutlerapp/gitbutler
[gitbutler-docs]: https://docs.gitbutler.com
[gitbutler-stacked]: https://docs.gitbutler.com/features/branch-management/stacked-branches
