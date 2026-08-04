# diffview.nvim (Lua / Neovim)

The reference Neovim diff and file-history UI: a single-tabpage orchestrator that never computes a display diff itself — it materializes any git rev as a buffer, arranges buffers into declarative 1/2/3/4-window layout objects, and lets Vim's built-in diff mode do the alignment, folding, and intra-line highlighting.

| Field             | Value                                                       |
| ----------------- | ----------------------------------------------------------- |
| Language          | Lua (LuaJIT, Neovim ≥ 0.7 plugin)                           |
| License           | GPL-3.0-or-later (`LICENSE`)                                |
| Repository        | <https://github.com/sindrets/diffview.nvim>                 |
| Documentation     | `README.md`, `USAGE.md`, `doc/diffview.txt` (vimdoc)        |
| Category          | editor-diff                                                 |
| First release     | No tagged releases; first commit 2021-04-28                 |
| Latest release    | Rolling `main`; last commit at surveyed revision 2024-06-13 |
| Surveyed revision | `4516612fe98ff56ae0415a259ff6361a89419b0a` (2024-06-13)     |

## Overview

### What it solves

Vim has had a competent side-by-side diff engine (`diff-mode`: xdiff in-process, filler-line alignment, `DiffText` intra-line ranges, diff folding) for decades, but it operates on _buffers you already opened_. Reviewing a whole rev means manually running `:Gdiffsplit` per file. diffview.nvim supplies the missing orchestration layer: "Vim's diff mode is pretty good, but there is no convenient way to quickly bring up all modified files in a diffsplit. This plugin aims to provide a simple, unified, single tabpage interface that lets you easily review all changed files for any git rev." (`README.md`). On top of that one idea it grows a file-history browser (`:DiffviewFileHistory`, including `-L` line tracing), a 3/4-way merge tool over git's index stages, and an editable-index staging workflow.

### Design philosophy

- **Delegate the diff, own the session.** The plugin computes no display diff; every pane is a real buffer with `diff`, `scrollbind`, `cursorbind`, and `foldmethod=diff` window options (`lua/diffview/vcs/file.lua`, `File:init` `winopts`). What the plugin owns is state: which revs, which files, which layout, which buffers already exist.
- **Morph, don't rebuild.** When the file list refreshes, the old and new `FileEntry` lists are themselves diffed with an in-tree Myers implementation: "We diff the old file list against the new file list in order to find the most efficient way to morph the current list into the new. This way we avoid having to discard and recreate buffers for files that exist in both lists." (`lua/diffview/scene/views/diff/diff_view.lua`, `DiffView.update_files`).
- **Everything is a class.** A hand-rolled OOP layer (`lua/diffview/oop.lua`) with abstract stubs, a lazy-module system (`lua/diffview/lazy.lua`), and a callback-to-coroutine async layer (`lua/diffview/async.lua`: `async.wrap`/`async.void`/`await`) give the codebase a shape closer to a desktop GUI app than a typical Vim plugin.

## How it works

### 1. Diff computation & data model

diffview.nvim contains a Myers diff (`lua/diffview/diff.lua`, "An implementation of Myers' diff algorithm / Derived from: <https://github.com/Swatinem/diff>" — linear-space bidirectional snake search producing a `NOOP/DELETE/INSERT/REPLACE` edit script) — but it is **never used on file contents**. Its only call site is `DiffView.update_files`, where it reconciles old vs. new `FileEntry` lists (equality: `path` + `oldpath`) so buffer objects survive refreshes. The visible line diff is computed by Neovim's built-in diff mode after the plugin sets the relevant buffers `diff`-active in adjacent windows; algorithm choice, `iwhite`, `linematch` etc. are whatever the user's global `'diffopt'` says — the plugin neither sets nor wraps them.

Everything else is parsed from git plumbing output:

- **File lists**: two parallel jobs, `git diff --ignore-submodules --name-status <args>` and `... --numstat <args>`, run under a `MultiJob` with `retry = 2` and a consistency `fail_cond` that rejects the pair when the line counts disagree ("Inbalance in diff data!") — a guard against racing a mutating repo (`lua/diffview/vcs/adapters/git/init.lua`, `GitAdapter.tracked_files`). Untracked files come from `git ls-files --others --exclude-standard`.
- **History**: a single streamed `git log` with a custom `--pretty` format terminated by NUL sentinels (`GitAdapter.COMMIT_PRETTY_FMT`), each NUL-delimited record structured into `GitAdapter.LogData` (hashes, author, time, ref names, namestat + numstat block) by `structure_fh_data`, soft-validated with `vim.validate`.
- **Patch text** is parsed only for `-L` line tracing: `vcs/utils.lua` has a full unified-diff parser (`parse_diff`, `parse_diff_hunk`) whose hunks drive custom fold computation (§4) and content reconstruction (`diff_build_hunk` rebuilds one version's text from common + version-specific hunk chunks).

The rev model is a small sum type: `RevType.LOCAL | COMMIT | STAGE | CUSTOM` with `commit: sha` or `stage: 0..3` payloads plus a `track_head` flag (`lua/diffview/vcs/rev.lua`). `STAGE 0` is the regular index; stages 1/2/3 are merge base/ours/theirs. A `FileEntry` binds a path + status + stats to a `RevMap { a, b, c, d }` and a layout; each layout window holds a `vcs.File` = (adapter, path, rev) that lazily materializes as a buffer named `diffview://<gitdir>/<context>/<path>` via `git show <rev>:<path>` (`File.create_buffer`, `GitAdapter:get_show_args`).

Rev-arg parsing (`GitAdapter:parse_revs`) resolves user input with `git rev-parse --revs-only`; symmetric ranges `A...B` become `merge-base A B` → left, `rev-parse B` → right (`symmetric_diff_revs`); range-ness of an arg is decided by a Lua-pattern battery (`is_rev_arg_range`: `..`, `...`, `^@`, `^!`, `^-n`). No arg yields `STAGE(0)..LOCAL` (unstaged), `--cached` yields `HEAD..STAGE(0)`. `--imply-local` swaps a side equal to `HEAD` for `LOCAL` so LSP/diagnostics work on the checked-out file (`imply_local`). The inverse mapping `rev_to_args` notes an asymmetry: `LOCAL..REV` is inexpressible in git syntax, so it runs as `REV` with additions/deletions swapped afterwards (`tracked_files`, comment at the swap site).

### 2. Rendering & layout

Two rendering regimes coexist:

- **Diff panes are plain windows.** Layouts are classes: abstract `Layout` (window list, validation, recovery, scroll sync) with concrete `Diff1`, `Diff2Hor`, `Diff2Ver`, `Diff3Hor`, `Diff3Ver`, `Diff3Mixed`, `Diff4Mixed` (`lua/diffview/scene/layouts/`). Each `create()` builds its window arrangement imperatively with `:sp`/`:vsp` around a "pivot" window (`Layout:find_pivot`), e.g. `Diff3Mixed` = two columns above one full-width bottom window. A config-name table maps `"diff2_horizontal"` etc. to classes (`lua/diffview/config.lua`, `M.name_to_layout`), and per-kind defaults are user-configurable (`view.default.layout`, `view.merge_tool.layout = "diff3_horizontal"`, `view.file_history.layout`). Cross-pane row alignment, filler lines, and changed-row pairing are entirely Vim diff mode; the plugin adds only `winhl` remaps (`DiffAdd:DiffviewDiffAdd`, …) so its highlight groups can restyle diff colors per-window, and a winbar per pane labelling the rev (`WORKING TREE`, `INDEX`, `OURS (Current changes) <sha>`, … — `File:init`, `FileEntry:update_merge_context`). Scroll lock is `scrollbind` plus a `sync_scroll` nudge that scrolls the tallest buffer one line down/up (`<c-e><c-y>`) because ":syncbind works less consistently" (`lua/diffview/scene/layout.lua`).
- **Panels are a retained component tree.** The file panel, history panel, and option panel render through `lua/diffview/renderer.lua`: a `RenderComponent` tree where each node accumulates `lines` + `hl` spans and, after a render pass, knows its own `lstart`/`lend` line range — so cursor position maps back to model objects (`FilePanel:get_item_at_cursor`) without per-line bookkeeping. Highlighting uses namespaced `nvim_buf_add_highlight` batches; devicons are optional.

Syntax highlighting in diff panes is ordinary Neovim highlighting: historical buffers get `:filetype detect` after content injection (`File.create_buffer`), so tree-sitter/regex highlighting and even LSP (for `LOCAL`/index buffers) work as in normal editing.

### 3. Intra-line & noise handling

Fully delegated, and therefore fully inherited: word/char-level refinement is Vim's `DiffText`/`linematch`, whitespace suppression is the user's `'diffopt'` (`iwhite`, `iwhiteall`, `icase`, `algorithm:histogram|patience`, `linematch:60`). The plugin ships **no** ignore-rules, no formatting-noise classification, no moved-code detection, and cannot vary diff options per view (Neovim's `'diffopt'` was global until 0.11's `diffopt+=inline:` era; nothing here touches it). The one place diffview.nvim parses content semantically is conflict markers: `vcs/utils.lua` `parse_conflicts` is a hand-written state machine over `<<<<<<<`/`|||||||`/`=======`/`>>>>>>>` (diff3-style base section included) yielding `ConflictRegion { ours, base, theirs, first, last }` plus cursor-relative current-conflict resolution — used by the merge tool (§5) and by a live conflict counter re-parsed on `TextChanged` with a 1000 ms trailing throttle (`DiffView:file_open_post`). The absence of noise handling is a direct consequence of the architecture: whoever owns the diff owns the noise policy, and here that is Vim.

### 4. Navigation, folding & scale

- **File panel**: `list` or `tree` listing style (`FilePanel`, `listing_style`), with a proper trie of `Node`s (`lua/diffview/ui/models/file_tree/`), directory collapsing (`flatten_dirs`), per-entry status letter, +/- stat counts, and conflict counts. Sections: conflicts / working / staged. `]f`-style cycling is `DiffView:next_file`/`prev_file`; selecting an entry calls `Layout.use_entry`, which swaps the four `Window`s' files and re-opens buffers in place — the tabpage layout persists, only buffers change.
- **Folding**: unchanged regions collapse via `foldmethod=diff` for free. In file-history `-L` line-trace mode, whole-file buffers are shown but folded down to the traced hunks: `FileEntry:update_patch_folds` converts parsed hunks into explicit fold ranges (merging adjacent folds), applied with `foldmethod=manual` + `zE` + `:fold` commands (`Window:apply_custom_folds`, `FileHistoryView` line ~105).
- **Scale guards**: the history log is _streamed_ — the log job pushes each NUL-record through an `AsyncListStream`; the panel consumes it incrementally, appending `LogEntry`s and re-rendering through a 15 ms throttle (`FileHistoryPanel.update_entries`, `debounce.throttle_render(15, …)`), with a `Signal`-based shutdown so closing the view kills the pipeline mid-stream. File-list refreshes are debounced 100 ms trailing and cancelled when the view's tabpage loses focus (`DiffView.update_files`). A `PerfTimer` instruments every update; `renderer.M.last_draw_time` tracks redraw cost. Buffer reuse via the Myers morphing (§1) avoids reloading unchanged blobs. There is no guard against a single enormous file — that is Vim's problem by construction.
- **Live updates**: a libuv `fs_poll` on `.git/index` (1000 ms) triggers refresh while the view is focused (`DiffView:post_open`, `watch_index`), so external `git add`/commit/stash reflect automatically.

### 5. VCS & review integration

Deepest of the surveyed dimensions — the plugin is effectively a porcelain:

- **Plumbing inventory** (all via spawned `git`, wrapped in `Job`/`MultiJob` with retries and logging): `rev-parse` (toplevel, git-dir, rev resolution, completion candidates), `merge-base`, `diff --name-status/--numstat`, `show` (blob content, commit metadata), `cat-file -e` (existence probe before restore), `ls-files --others/--stage`, `log` with `--follow`, `-L`, `--diff-merges`, pickaxe `-G/-S`, `--reflog`, `--all`, etc. (`prepare_fh_options` maps ~20 CLI flags 1:1 to log flags), `hash-object -w`, `update-index --index-info`, `checkout`, `add`, `reset`. A `file_history_dry_run` pre-flights the log options and reports "No git history for the target(s)" instead of an empty panel.
- **Staging without `git add`**: the `STAGE 0` buffer of a file is _editable_; a `BufWriteCmd` autocmd writes the buffer to a temp file, `git hash-object -w` creates the blob, and `git update-index --index-info` splices it into the index preserving the old mode (`GitAdapter:stage_index_file`). Blob hashes are tracked so an index changed behind an edited buffer produces a warning instead of silent clobbering (`FileEntry:validate_stage_buffers`). This gives partial staging with the full editor (not hunk-granularity toggles — arbitrary edit-then-write).
- **Merge tool**: during merge/rebase/revert/cherry-pick (detected by probing `.git/{MERGE_HEAD,REBASE_HEAD,REVERT_HEAD,CHERRY_PICK_HEAD}`, `get_merge_context`), conflicted files become `FileEntry`s with revs `a=STAGE(2) ours, b=LOCAL, c=STAGE(3) theirs, d=STAGE(1) base` in the configured merge layout (`tracked_files`). The center `b` pane is the real working-tree file with markers; `conflict_choose("ours"|"theirs"|"base"|"all"|"none")` rewrites the current `ConflictRegion` from parsed section contents, `conflict_choose_all` resolves every region in one pass with offset bookkeeping (`lua/diffview/actions.lua`, `resolve_all_conflicts`); `diffget`/`diffput` route Vim's native hunk-copy commands to the right buffer by layout symbol, including visual-range `diffget`. `]x`/`[x` jump between markers.
- **No forge layer**: no PR model, no comments, no revision stacks — out of scope by design. The extension seam is the **user API**: `lua/diffview/api/views/diff/diff_view.lua` exports `CDiffView`, a `DiffView` subclass where the file list (`fetch_files`) and per-side buffer content (`get_file_data(kind, path, "left"|"right")`) come from caller callbacks — this is how plugins like Neogit embed diffview for their own comparisons. Plus vimdoc-documented hooks (`view_opened`, `view_closed`, `diff_buf_read`, `diff_buf_win_enter`, … `doc/diffview.txt` §693–782) and an `EventEmitter` with propagation control (`lua/diffview/events.lua`).
- **Second VCS**: a Mercurial adapter (~1340 lines, `lua/diffview/vcs/adapters/hg/`) behind the same abstract `VCSAdapter` + `Rev` interface, proving the adapter seam is real (though hg lacks some features, e.g. staging).

### 6. Architecture & reuse

Single-process Lua inside Neovim; all VCS work in spawned child processes via libuv, surfaced through the in-tree async/await layer. Notable infrastructure, most of it dependency-free and conceptually portable:

- `oop.lua` — class system with `create_class`, `super`, `instanceof`, abstract stubs; `lazy.lua` — lazy module/attribute proxies that break the dependency cycles a scene graph of this shape inevitably has.
- `async.lua` + `control.lua` — coroutine async with `await`, `pawait`, schedulers, plus `Signal`/`WorkPool`/`Semaphore` coordination primitives; `stream.lua` — `AsyncListStream` for producer/consumer streaming with close signals.
- `debounce.lua` — debounce/throttle (trailing variants, `throttle_render`).
- The **scene graph** — `View → Layout → Window → File` with validation (`Layout:validate`), self-healing (`Layout:recover` rebuilds destroyed windows around a pivot), and layout hot-swapping (`cycle_layout`; `Diff3:to_diff4` etc. convert between layouts preserving file objects).
- The **panel renderer** — component tree with line-range back-mapping (§2), reused by all panels.

Monolith-bound: everything touching `vim.api` (that is, most of it). The reusable _ideas_ are the layout-as-class-with-recovery pattern, the rev sum type with index stages as first-class revs, the streamed log ingestion with throttled rendering, and list-morphing-by-diff for stateful UI updates.

## Strengths

- Maximum leverage from a tiny core: by reusing Vim diff mode it inherits histogram/patience algorithms, `linematch`, intra-line highlighting, diff folding, and hunk motions with zero diff code of its own.
- Diff panes are _real buffers_: full syntax highlighting, LSP on local/index sides, all editor motions/registers work; the editable-index buffer is a genuinely novel staging UX.
- The layout model (declarative window-symbol classes + `should_null` per rev/status, recovery, hot-swap between 1/2/3/4-way) is the cleanest treatment of "diff layout as data" among editor tools.
- Streaming, cancellable file-history pipeline with dry-run validation and throttled incremental rendering scales to large logs.
- Merge tool grounded in index stages (not temp files), with base pane, per-region choose ops, and live conflict counts.
- Clean VCS adapter + `CDiffView` API seams — other plugins embed it.

## Weaknesses

- No control over the diff itself: options are global `'diffopt'`; no per-view algorithm, no ignore-rules, no formatting-noise classification, no moved-code detection — the plugin can't do better than Vim's diff mode.
- No review layer: no comments, PR metadata, or multi-commit review state; history view is read-only archaeology.
- Alignment quality depends on the user's Neovim version/config (`linematch` off by default on older releases); the plugin cannot guarantee a rendering.
- Hand-rolled OOP + lazy-module indirection makes the code hard to trace (`lazy.access` strings defeat go-to-definition); no type checker beyond LuaLS annotations.
- `should_null` for `Diff3`/`Diff4` is a stub returning `false` (marked `FIXME`), so add/delete edge cases in merge layouts are not modelled.
- Imperative window building on `:sp`/`:vsp` with pivot recovery is fragile against user window meddling — hence the need for `Layout:validate`/`recover` machinery at all.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                  | Trade-off                                                                                     |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Drive Vim diff mode instead of computing/rendering diffs          | Inherits mature alignment, folding, intra-line refinement, and hunk ops for free           | Zero control over diff quality, options are global, no noise classification possible          |
| Layouts as classes over window symbols `a/b/c/d`                  | 2/3/4-way and mixed arrangements share lifecycle, validation, recovery, and keymap scoping | Imperative `:sp`-based construction needs self-healing; per-symbol semantics partly stubbed   |
| Revs as sum type with index stages as first-class revs            | Merge tool, staging, and history all reuse one `File(rev, path) → buffer` pipeline         | Some rev ranges (`LOCAL..REV`) inexpressible in git syntax need special-cased stat swapping   |
| Editable stage-0 buffers written via `hash-object`+`update-index` | Full-editor partial staging without patch-format round-trips                               | Requires blob-hash freshness tracking and warnings to avoid clobbering a moving index         |
| Myers-diff the _file list_ to morph UI state                      | Buffer/window reuse across refreshes; no flicker, preserved cursor/scroll                  | An entire diff implementation maintained for a bookkeeping task                               |
| Streamed NUL-delimited `git log` parsing with throttled render    | Large histories appear incrementally and remain cancellable                                | Custom pretty-format parser must soft-validate every record; ordering/kill logic is intricate |
| In-tree async/OOP/lazy frameworks, no external deps               | Works on stock Neovim 0.7; full control                                                    | ~1.5 kLoC of infrastructure to maintain; indirection obscures call graphs                     |

## Sources

- Local checkout at `/home/petar/code/repos/neovim/diffview.nvim`, revision `4516612fe98ff56ae0415a259ff6361a89419b0a` (2024-06-13) — primary; key files cited inline: `lua/diffview/scene/layout.lua`, `lua/diffview/scene/layouts/*.lua`, `lua/diffview/scene/views/diff/diff_view.lua`, `lua/diffview/scene/views/file_history/*.lua`, `lua/diffview/vcs/rev.lua`, `lua/diffview/vcs/file.lua`, `lua/diffview/vcs/utils.lua`, `lua/diffview/vcs/adapters/git/init.lua`, `lua/diffview/diff.lua`, `lua/diffview/actions.lua`, `lua/diffview/renderer.lua`, `lua/diffview/api/views/diff/diff_view.lua`
- `README.md`, `USAGE.md`, `doc/diffview.txt` in the same checkout
- Upstream repository: [diffview.nvim][repo]
- Myers-diff derivation source: [Swatinem/diff][swatinem-diff]

<!-- References -->

[repo]: https://github.com/sindrets/diffview.nvim/tree/4516612fe98ff56ae0415a259ff6361a89419b0a
[swatinem-diff]: https://github.com/Swatinem/diff
