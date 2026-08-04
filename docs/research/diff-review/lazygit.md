# lazygit (Go)

A keyboard-driven terminal UI for git whose diff pipeline is built entirely on shelling out to `git`, but whose interactive staging and custom-patch building rest on a small, pure, in-process unified-diff model that re-emits transformed patches for `git apply`.

| Field             | Value                                                           |
| ----------------- | --------------------------------------------------------------- |
| Language          | Go                                                              |
| License           | MIT                                                             |
| Repository        | [github.com/jesseduffield/lazygit][repo]                        |
| Documentation     | `docs/` in-tree (Config, Custom_DiffRenderers, Range_Select, …) |
| Category          | TUI git client (diff viewing + staging + history rewriting)     |
| First release     | v0.1, August 2018                                               |
| Latest release    | v0.64.0 (2026-08-04)                                            |
| Surveyed revision | `aee0e40ec1235476e9328678f0f3e2462576b9ae` (2026-08-04)         |

> [!NOTE]
> This survey focuses on the diff/patch subsystems (`pkg/commands/patch`, `pkg/gui/patch_exploring`, the diff-renderer plumbing, and the context architecture). Rebase orchestration, bisect, worktrees, and the commit graph renderer (`pkg/gui/presentation/graph`) are only touched where they intersect diffing.

## Overview

### What it solves

lazygit compresses the interactive parts of a git workflow — staging individual lines, splitting and reordering commits, moving hunks between commits, resolving conflicts, diffing arbitrary refs — into a five-panel TUI where every entity (file, branch, commit, stash) shows its diff in a main view as you move the cursor. Its distinguishing diff features are the **staging panel** (line/hunk/range staging without `git add -p`'s question-answer loop) and the **custom patch builder** (select lines out of an _existing commit's_ diff, then delete them from the commit, move them to another commit, or pull them into the index — all mechanized via `git apply` plus interactive rebases).

### Design philosophy

`VISION.md` states it directly:

> "Lazygit's vision is to be the most enjoyable UI for git." — `VISION.md`

followed by seven explicit design principles: _Discoverability, Simplicity, Safety, Power, Speed, Conformity with git, Think of the codebase_. Two of them shape the diff subsystem decisively. _Conformity with git_ means lazygit never reimplements diffing: every diff on screen is `git diff`/`git show` output, and every mutation is a real git command (visible in a command log). _Speed_ drives the incremental output-streaming task system (`pkg/tasks/tasks.go`):

> "If we're flicking through the commits panel, we want to invoke a `git show` command for each commit, but we don't want to read the entire output at once (because that would slow things down); we just want to fill the panel and then read more as the user scrolls down." — `pkg/tasks/tasks.go`

## How it works

### 1. Diff computation & data model

lazygit computes **no diffs in-process**. All diff content is parsed from `git` subprocess output at line granularity:

- Read-only main-view diffs come from `git diff` / `git show` with `--color=always`, built by `DiffCmdObj` in `pkg/commands/git_commands/diff.go` via a fluent `GitCommandBuilder` (`pkg/commands/git_commands/git_command_builder.go`). `AddCommonDiffArgs` centralizes the shared knobs: `--unified=<n>` (runtime-adjustable context size), `--find-renames=<n>%` (rename similarity threshold, also runtime-adjustable), and optional `--ignore-all-space`.
- Interactive views (staging, patch building) request **plain** (`--no-color --no-ext-diff`) diffs and parse them with the in-tree parser `pkg/commands/patch/parse.go`: a single regex over `@@ -a,b +c,d @@` hunk headers producing a `Patch { header []string, hunks []*Hunk }`, where each `Hunk` holds `oldStart`/`newStart`/`headerContext` plus `bodyLines []*PatchLine`. A `PatchLine` is just `{ Kind, Content }` with kinds `PATCH_HEADER | HUNK_HEADER | ADDITION | DELETION | CONTEXT | NEWLINE_MESSAGE` (`pkg/commands/patch/patch_line.go`). The raw `+`/`-`/space prefix character is kept in `Content`.

The model's central operation is functional: `Patch.Transform(TransformOpts) *Patch` (`pkg/commands/patch/transform.go`) returns a _new_ patch with a subset of changes selected (`IncludedLineIndices`), optionally reversed, with the header optionally rewritten (`FileNameOverride`), rename metadata stripped (`StripRename`), or new-file diffs converted to diffs-against-empty-file. Unselected old-file lines become context lines; unselected new-file lines are dropped; a `pendingContext` buffer reorders converted context after selected additions so the emitted hunk stays well-formed; `transformHunkHeader` recomputes `@@` counts and running offsets. The result round-trips through `FormatPlain()` into a byte stream `git apply` accepts. Line-number bookkeeping (`LineNumberOfLine`, `AdjustLineNumber`, `HunkContainingLine` in `pkg/commands/patch/patch.go`) supports cursor restoration and jump-to-editor.

There is no word/char/AST granularity anywhere in the model, and no diff algorithm choice — whatever `diff.algorithm` git config the user has applies.

### 2. Rendering & layout

Unified view only; lazygit has no native side-by-side mode (users get side-by-side by plugging in `delta -s` — see §6). Two distinct render paths:

- **Read-only diffs** are raw ANSI from git (or from a custom diff renderer), streamed verbatim into a `gocui` view. No gutters, no line numbers, no internal syntax highlighting — colors are git's own `--color=always` output. Line numbers/hyperlinks arrive only via external renderers (delta's `--hyperlinks-file-link-format="lazygit-edit://{path}:{line}"` is explicitly supported so clicking a line number opens the editor, per `docs/Custom_DiffRenderers.md`).
- **Interactive diffs** (staging / patch building) are re-rendered from the parsed `Patch` by `pkg/commands/patch/format.go`: additions `FgGreen`, deletions `FgRed`, hunk headers `FgCyan` + default-color trailing context, file headers bold. Lines already included in the custom patch get a `BgGreen` marker on the _first character only_ (the `+`/`-` column), so "included" state is a per-line gutter-of-one-cell rather than a full-row tint. Cursor/range highlight is applied by the view layer, orthogonal to inclusion marks.

Wrapping is handled by maintaining two index maps — `viewLineIndices` (patch line → first wrapped view line) and `patchLineIndices` (wrapped view line → patch line) — rebuilt on width change (`OnViewWidthChanged` in `pkg/gui/patch_exploring/state.go`), so selection state survives re-wrapping. There is no cross-pane row alignment problem since there is only one pane.

### 3. Intra-line & noise handling

Nothing in-house. There is no word- or character-level refinement, no formatting-noise classification, and no moved-code detection in lazygit's own code. Noise handling is delegated to git flags and external renderers:

- `git.ignoreWhitespaceInDiffView` config maps to `--ignore-all-space`, applied **only** to UI diffs (`forUI` flag in `AddCommonDiffArgs`), never to the plain diffs that feed patch application — so what you stage is always the real change even when the view hides whitespace churn.
- The `rawGit` diff-renderer type passes arbitrary extra args to `git diff`/`git show` (e.g. `--color-words`, `--word-diff`), and `stdinFilter` renderers like `delta` provide word-level emphasis; both affect display only, since the interactive staging model always parses an unfiltered plain diff.

Consequence: in the staging and patch-building views (where the internal renderer must own line indices) the user always sees plain line-level git output, with no intra-line emphasis at all.

### 4. Navigation, folding & scale

- **Selection modes**: the patch-explorer state machine (`pkg/gui/patch_exploring/state.go`) has three modes — `LINE`, `RANGE`, `HUNK`. Range select comes in two idioms documented in `docs/Range_Select.md`: _sticky_ (`v` toggles, arrows extend, vim-style) and _non-sticky_ (`shift+arrows` extend, plain arrows collapse). Mouse drag also produces a range (`DragSelectLine`). Hunk mode can be user-toggled or on by default via config, with an escape-hatch heuristic: `IsSingleHunkForWholeFile()` suppresses default hunk mode for wholly-added/deleted files where hunk-select would be meaningless. "Hunk" navigation in hunk mode actually walks contiguous _blocks of change lines_ (`selectionRangeForCurrentBlockOfChanges`), not `@@` hunks.
- **Context expansion**: no folding/unfolding of unchanged regions; instead the whole diff is re-requested with a different `--unified=<n>` via `{`/`}` keys (`pkg/gui/controllers/context_lines_controller.go`). Cheap to implement, but O(diff) per keypress.
- **File navigation**: changed files render as a collapsible directory tree (`pkg/gui/filetree`, with path-compression of single-child directories), used for both worktree files and commit files.
- **Scale guards**: the `ViewBufferManager` (`pkg/tasks/tasks.go`) runs at most one render command per view, reads output incrementally — an initial `LinesToRead{Total, InitialRefreshAfter}` fills the view plus enough lines for a stable scrollbar (capped at 5000), then scrolling requests more via a channel — and terminates the previous command (SIGTERM) when the user moves on. A 30 ms throttle kicks in when process startup exceeds 10 ms, so flicking through commits doesn't spawn a process avalanche. Diff renderers run under a real PTY (`pkg/gui/pty.go`) so `GIT_PAGER` engages, with `TERM=dumb` plus terminal-identity env vars stripped so renderers don't probe capabilities, and `LAZYGIT_COLUMNS` exported for width-aware scripts.

### 5. VCS & review integration

Everything is subprocess git; lazygit is effectively a state machine over porcelain:

- **Staging** (`pkg/gui/controllers/staging_controller.go`): the selected view range is mapped to patch line indices, `Parse(diff).Transform({IncludedLineIndices, Reverse, FileNameOverride: path}).FormatPlain()` builds a minimal patch, written to a temp file and applied with `git apply --cached` (unstage: `--reverse`). `FileNameOverride` replaces the whole header with bare `--- a/<path>` / `+++ b/<path>` because "the original header … makes git confused e.g. when dealing with deleted/added files" (`pkg/commands/patch/transform.go`). Hunk-edit opens the transformed hunk in `$EDITOR` and applies the edited text.
- **Custom patch builder** (`pkg/commands/patch/patch_builder.go`): a session object keyed on a `From`/`To` ref pair holding per-file `{mode: UNSELECTED|WHOLE|PART, includedLineIndices}`; lazily loads each file's diff once. Consuming operations in `pkg/commands/git_commands/patch.go` (`DeletePatchesFromCommit`, `MovePatchToSelectedCommit`, `MovePatchIntoIndex`, `PullPatchIntoNewCommit[Before]`) combine `git apply --reverse --index --3way` of the aggregated patch with daemon-driven interactive rebases to rewrite history. Rename handling is notably careful: a partial selection from a renamed file strips the rename from the header (`StripRename`) so the rename itself stays in the commit while content moves.
- **Diffing arbitrary refs**: a global _diffing mode_ (`pkg/gui/modes/diffing/diffing.go`) — a menu (`W`) sets `Diffing.Ref` (+ `Reverse`); afterwards every panel's main view diffs its item against that ref, so "diff this branch against that tag" is a mode, not a dedicated screen. `git difftool` launch (`OpenDiffToolCmdObj`) covers external side-by-side needs.
- **Merge conflicts**: an in-house conflict-marker parser and renderer (`pkg/gui/mergeconflicts`) with per-hunk pick UI — the one place lazygit renders file content itself rather than a git diff.
- **Review platforms**: no in-app PR review. Integration is limited to (a) generating PR/commit URLs for GitHub/GitLab/Bitbucket/Azure/Gitea/… (`pkg/commands/hosting_service`), and (b) decorating branches with PR state fetched from the GitHub GraphQL API using the `gh` CLI's stored auth token (`pkg/commands/git_commands/github.go`). No comments, no revisions, no server-side diffs.
- **Stacked branches**: no stack engine of its own — `docs/Stacked_Branches.md` documents relying on git's `rebase.updateRefs`, with lazygit contributing visualization (cyan `*` on stacked branch heads in the commit list) and correct todo handling for `update-ref` entries during interactive rebases.

### 6. Architecture & reuse

- **Process model**: single UI thread (gocui event loop) + worker goroutines; all view mutation is marshalled onto the UI thread (`onUIThread` in `ViewBufferManager`). Render commands are child processes, optionally under a PTY.
- **UI substrate**: a heavily modified gocui fork, now vendored _in-tree_ at `pkg/gocui` (cell-grid views with internal buffers, redrawn per event). The layered GUI architecture is documented in `docs/dev/Codebase_Guide.md`: **views** (dumb buffers) ← **contexts** (~30 of them, per-view state + render logic, arranged in a `ContextTree` with a focus stack — `pkg/gui/context/context.go`) ← **helpers** (shared logic) ← **controllers** (keybindings→actions, attachable to multiple contexts, e.g. one `PatchExplorerController` serves both staging and patch-building contexts), with an explicitly documented one-way dependency direction. The main view is _contextual_: which context occupies it (`normal`, `staging`, `patchBuilding`, `mergeConflicts`) depends on what is focused, and secondary main views show the counterpart (e.g. staged vs unstaged).
- **Diff renderer plugin seam** (`pkg/config/diff_renderer_config_manager.go`, `docs/Custom_DiffRenderers.md`): three renderer types — `stdinFilter` (delta, diff-so-fancy, ydiff via `GIT_PAGER` under a PTY, with a `{{columnWidth}}` template for side-by-side widths), `extDiff` (difftastic via `diff.external` + `--ext-diff`, with `{{diffContext}}` templating), and `rawGit` (extra args like `--color-words`). Users configure an _array_ of renderers and cycle them at runtime with `|` — e.g. default delta, switch to difftastic for a structural view, switch to `--color-words` for prose.
- **Reusable ideas vs monolith**: the `pkg/commands/patch` package (parse → transform → format, zero UI dependencies) and the `patch_exploring.State` selection machine are cleanly extractable designs; the context/controller layering and task system are idiomatic but gocui-bound. Nothing is published as a library; the repo is a single module.

## Strengths

- The parse→`Transform`→format patch pipeline is a small (~600 line), pure, well-tested core that turns line-level staging and commit surgery into "emit a valid sub-patch, let `git apply --3way` do the semantics" — no index manipulation code at all.
- Interactive staging UX is best-in-class: three selection modes, two range-select idioms (modal and non-modal), mouse drag, hunk-mode heuristics, and cursor restoration onto the _next stageable change_ after each apply (including a subtle fix for addition/deletion reordering in `patch_exploring/state.go`).
- The diff-renderer array with runtime cycling composes with the entire pager ecosystem (delta, difftastic, ydiff, `--color-words`) instead of competing with it, including width templating and editor hyperlinks.
- The incremental `LinesToRead` streaming + process throttling + SIGTERM-on-navigate makes flicking through large histories responsive without ever materializing full diffs.
- Diff-vs-apply separation: display niceties (`--ignore-all-space`, custom renderers) never contaminate the plain diffs used for patch application.
- The everything-is-git-subprocess policy yields perfect fidelity with user git config (diff algorithm, renames, attributes) and a visible, auditable command log.

## Weaknesses

- No native side-by-side, line numbers, syntax highlighting, or word-level emphasis; all of that is outsourced, and _none_ of it is available in the interactive staging/patch-building views, which are locked to the plain internal renderer.
- No formatting-noise or moved-code intelligence beyond forwarding git flags; a reformat-heavy diff is as noisy as `git diff` makes it.
- No folding of unchanged regions; context-size changes re-run and re-render the whole diff.
- Line-index-keyed selection state (`includedLineIndices` as raw ints into the parsed diff) is invalidated by any upstream change to the diff; the code carries nontrivial cursor-fixup logic to compensate.
- No review-platform depth: PR awareness stops at decoration and URL generation; stacked-branch support leans entirely on `rebase.updateRefs`.
- The gocui inheritance shows: views/contexts "share some responsibilities for historical reasons" (`docs/dev/Codebase_Guide.md`), and a legacy god-struct layer still coexists with the controller architecture.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                             | Trade-off                                                                                      |
| ------------------------------------------------------------------ | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| All diffs from `git` subprocesses; none computed in-process        | Perfect conformity with user git config; zero diff-engine maintenance | No structural/word-level model to build smarter rendering or noise suppression on              |
| Staging = emit transformed sub-patch + `git apply`                 | Tiny pure core; git owns index semantics, 3-way fallback for free     | Selection keyed by fragile line indices; header rewriting quirks (`FileNameOverride`)          |
| External diff renderers (`stdinFilter`/`extDiff`/`rawGit`) via PTY | Rides delta/difftastic ecosystems; users keep their pager investment  | Interactive views can't use them, so the prettiest rendering is exactly where you can't stage  |
| Unified-only internal renderer, ANSI streamed into cell-grid views | Simple; wrapping handled by one bidirectional index map               | No side-by-side alignment, gutters, or intra-line emphasis natively                            |
| Incremental line-streaming tasks with kill-on-navigate             | Instant panel flicking on huge repos                                  | Scrollbar accuracy requires a 5000-line prefix read heuristic; PTY resize handling is unsolved |
| Context/controller/helper layering over a gocui fork               | Keybinding reuse across ~30 contexts; testable controllers            | Fork now vendored in-tree; residual legacy god-struct code; view/context split blurry          |
| Mode-based ref diffing (`W`) instead of a dedicated compare screen | Every existing panel becomes a compare view against the chosen ref    | Global mode state; discoverability depends on menus rather than a visible compare UI           |

## Sources

- Surveyed tree at `aee0e40ec1235476e9328678f0f3e2462576b9ae` (2026-08-04): `pkg/commands/patch/` (`parse.go`, `patch.go`, `transform.go`, `format.go`, `patch_builder.go`), `pkg/gui/patch_exploring/state.go`, `pkg/gui/controllers/staging_controller.go`, `pkg/commands/git_commands/{diff.go,patch.go,git_command_builder.go,github.go}`, `pkg/config/diff_renderer_config_manager.go`, `pkg/gui/pty.go`, `pkg/tasks/tasks.go`, `pkg/gui/context/context.go`, `pkg/gui/mergeconflicts/`, `pkg/gui/filetree/`
- `VISION.md` — vision and the seven design principles
- `docs/dev/Codebase_Guide.md` — view/context/controller/helper architecture and event loop
- [`docs/Custom_DiffRenderers.md`][custom-renderers] — the three renderer types, delta/difftastic/ydiff recipes
- [`docs/Range_Select.md`][range-select] — sticky vs non-sticky range selection
- [`docs/Stacked_Branches.md`][stacked] — `rebase.updateRefs`-based stack support

<!-- References -->

[repo]: https://github.com/jesseduffield/lazygit
[custom-renderers]: https://github.com/jesseduffield/lazygit/blob/aee0e40ec1235476e9328678f0f3e2462576b9ae/docs/Custom_DiffRenderers.md
[range-select]: https://github.com/jesseduffield/lazygit/blob/aee0e40ec1235476e9328678f0f3e2462576b9ae/docs/Range_Select.md
[stacked]: https://github.com/jesseduffield/lazygit/blob/aee0e40ec1235476e9328678f0f3e2462576b9ae/docs/Stacked_Branches.md
