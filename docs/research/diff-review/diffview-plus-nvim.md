# diffview-plus.nvim (Lua / Neovim)

A community-maintained fork of `sindrets/diffview.nvim` — Neovim's single-tabpage diff/merge/file-history UI — that revives a repo dormant since May 2024 and extends it with a unified inline-diff layout (extmark-rendered, tree-sitter-highlighted deletions, hybrid word/char intra-line refinement), a Jujutsu adapter, out-of-VCS merge/diff-dir views, pinned-local history, multi-file selection, and session persistence.

| Field             | Value                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| Language          | Lua (LuaJIT, Neovim ≥ 0.10 plugin)                                                                 |
| License           | GPL-3.0-or-later (`LICENSE`)                                                                       |
| Repository        | <https://github.com/dlyongemallo/diffview-plus.nvim>                                               |
| Upstream          | <https://github.com/sindrets/diffview.nvim> (last upstream-author commit 2024-05-24)               |
| Documentation     | `README.md`, `USAGE.md`, `RECIPES.md`, `TIPS.md`, `doc/diffview.txt`, `doc/diffview_changelog.txt` |
| Category          | editor-diff                                                                                        |
| First release     | Upstream project started 2021-04-28; fork notice added 2026-02-04 (`bac5b73`)                      |
| Latest release    | Rolling; surveyed tip is 2026-07-20                                                                |
| Surveyed revision | `62dc5adf4e77489a2a6d3bf36ef6e4ac5738b634` (2026-07-20)                                            |

## Overview

### What it solves

`diffview.nvim` gives Neovim a review-oriented diff surface: one tabpage cycles through every changed file of any revision range, with a file panel, a file-history browser (per file, directory, or line range), a 3-/4-way merge tool, and staging by editing index buffers directly. The upstream repository stalled — its author's last commit is dated 2024-05-24 — leaving a queue of community PRs and structural gaps (no unified/inline layout, no Jujutsu support, no session persistence). `diffview-plus.nvim` forked it: the 2026-02-04 bootstrap re-committed roughly fifty pending upstream PRs with original authorship preserved (commits cite upstream PR numbers such as `#607`, `#570`, `#432`), then added ~293 fork-side commits by 2026-07-20 (90 `fix`, 69 `feat`, 18 `test` by conventional-commit type). Of the tree's 669 commits, 257 are by upstream author Sindre T. Strøm and 330 by fork maintainer David Yonge-Mallo.

The fork's headline additions, per `doc/diffview_changelog.txt`: the `diff1_inline` unified layout; VCS adapters for Jujutsu, Sapling (auto-detected through the Mercurial adapter), and experimental Perforce; the no-VCS commands `:DiffviewMergeFiles` and `:DiffviewDiffDirs` (closing upstream issue [286][upstream-286] and serving as jj's external merge tool / diff editor, upstream issue [562][upstream-562]); `:DiffviewFileHistory --pin-local`; persistent multi-file selection; and `:mksession` round-trip restoration.

### Design philosophy

The whole plugin is a veneer over the editor's native diff machinery rather than a diff engine of its own. `README.md` is explicit:

> "This plugin builds on nvim's built-in diff mode. Make sure you're familiar with jumping between hunks (`:h jumpto-diffs`) and applying diff changes (`:h copy-diffs`)." — `README.md`

The exception is the fork's inline renderer, which is a from-scratch subsystem; its header carefully separates borrowed and original work:

> "The hunk dispatch, style architecture, unified-diff rendering, hybrid word/char intraline tokenization, navigation, and caching are original to this implementation." — `lua/diffview/scene/inline_diff.lua`

## How it works

### 1. Diff computation & data model

Three distinct diff engines coexist, each scoped to what it is good at:

- **Side-by-side text diffs are not computed by the plugin at all.** The `diff2`/`diff3`/`diff4` layouts load both revisions into `diffview://`-schemed buffers (content fetched asynchronously via VCS plumbing — see §5) and set the `diff` window option; Neovim's built-in diff mode (embedded xdiff, governed by the user's `'diffopt'`: `algorithm:histogram`, `linematch:N`, etc.) computes hunks, filler lines, and `DiffText` sub-line highlights.
- **The fork's `diff1_inline` layout computes its own line diff** via `vim.diff` (the Lua binding to Neovim's xdiff) with `result_type = "indices"` in `lua/diffview/scene/inline_diff.lua`. It forwards `algorithm`, `linematch`, `indent_heuristic`, and the four `ignore_*` whitespace/blank-line flags from the effective `'diffopt'` only when explicitly set, so xdiff defaults otherwise apply. Both inputs get a forced trailing newline; the file comments document that without it xdiff misclassifies EOF additions/deletions as modifications of the adjacent line.
- **Intra-line refinement** (inline layout only) is a two-stage unit diff, also through `vim.diff` with `algorithm = "minimal"`, `ctxlen = 0`, `linematch = 0`. Units are joined with `"\n"` so each token maps to one xdiff "line" (`diff_units`) — reusing the line differ as a token differ. Stage one diffs _subword tokens_ produced by `tokenize`: maximal runs of one class among `lower`/`upper`/`digit`/`under`, with an acronym rule at upper→lower transitions (`XMLParser` splits `XML`|`Parser`; `Parser` stays whole), multi-byte UTF-8 bucketed as `lower`, and each non-word char its own token. A post-pass, `coalesce_hex_runs`, re-fuses subword splits that look like hashes/hex literals — ≥ 8 chars, single-case hex, digit↔letter transitions ≥ `ceil(len/4)`, max letter run ≤ 4 — so a changed commit SHA highlights as one unit instead of confetti, while `cafef00d`-style pseudo-words are rejected. Stage two: a 1:1 word-token replacement is further refined to per-character sub-hunks (`split_chars`), but only when `refinement_safe` passes — ≤ 3 sub-hunks (`INTRALINE_MAX_HUNKS`), and for 2–3 sub-hunks a shared prefix _or_ suffix of ≥ 2 chars (so `recieve`→`receive` highlights just the moved `i`, while `param`→`return` falls back to a whole-word replacement instead of rendering as `[pa]r[am]eturn`). The same `INTRALINE_MAX_HUNKS` cap acts as a line-similarity gate at the word level: dissimilar paired lines cascade into many word hunks and get no intra-line highlighting at all.
- **A pure-Lua Myers implementation** (`lua/diffview/diff.lua`, "Derived from: <https://github.com/Swatinem/diff>") diffs _file-entry lists_, not text: on `:DiffviewRefresh`, `lua/diffview/scene/views/diff/diff_view.lua` builds an edit script (`NOOP`/`DELETE`/`INSERT`/`REPLACE`) between the current and freshly-fetched entry lists with a custom equality function, mutating the panel model in place so open buffers, cursor, and fold state survive refreshes.

Panel change counts come from `git diff --numstat` paired with name-status parsing (`lua/diffview/vcs/adapters/git/init.lua`).

### 2. Rendering & layout

A small scene graph — `View → Layout → Window → FileEntry → vcs.File` (`lua/diffview/scene/`) — owns windows and buffers. Sixteen layout classes cover `diff1_plain`, `diff1_inline`, `diff1_raw`, `diff2` horizontal/vertical, `diff3` horizontal/vertical/mixed, `diff4_mixed`, plus a parallel `*_pinned` family (fork-added, §4). The merge tool cycles `diff3_horizontal → diff3_vertical → diff3_mixed → diff4_mixed → diff1_plain` (`lua/diffview/config.lua`). Per-window options are saved and restored around entry swaps (`Window:_save_winopts`/`_restore_winopts`, `lua/diffview/scene/window.lua`).

Side-by-side alignment (filler lines, `scrollbind`/`cursorbind`) is entirely Neovim diff mode; syntax highlighting in file buffers is whatever the user's normal highlighting is, with an `enhanced_diff_hl` option for stronger hunk colors. Panels (file panel, file-history panel, commit log) are drawn by an in-plugin hl-component renderer (`lua/diffview/renderer.lua`), with `nvim-web-devicons`/`mini.icons` integration and `tree`/`list` listing styles.

The fork's `diff1_inline` layout renders a _unified_ diff in one window using extmarks only: added lines get `line_hl_group` extmarks (priority 100); deleted lines become `virt_lines` blocks anchored above the corresponding row. Two styles (`view.inline.style`): `"unified"` echoes the full old side of a modification block as virt*lines above the new block; `"overleaf"` renders deletions as inline strikethrough `virt_text` on the paired rows (adapted, per the file header, from a sample in fork issue [#109][fork-109], itself derived from `inlinediff-nvim`). Deleted virt_lines are **tree-sitter highlighted**: the old content is parsed with `vim.treesitter.get_string_parser`, captures are collected per line (`compute_old_line_captures`), and each virt_line chunk carries the \_full capture stack* on top of the deletion background — the comments note that picking only the last capture would let decoration-only captures like `@spell` drop the `@comment` foreground. Capture results are memoized across renders keyed by filetype + old-content equality. Intra-line overlays and the row backdrop are layered by explicit priorities, with the backdrop laid _with gaps_ around overlay ranges (`lay_backdrop_with_gaps`) so a priority-99 background cannot overpaint a priority-200 overlay's background. A `full_width` deletion-highlight mode pads virt_lines to the widest displaying window (textoff-aware, capped at 500 cells); extmark namespaces are window-scoped (`nvim_win_add_ns` on 0.12, experimental `nvim__ns_set` on 0.11) so inline marks don't leak into other windows showing the same buffer.

### 3. Intra-line & noise handling

- **Whitespace/blank-line suppression** is delegated to `'diffopt'` `ignore_*` flags, forwarded to the outer line diff. Deliberately _not_ forwarded to the intra-line unit diff: a comment in `diff_units` argues those flags "only decide which lines are paired as modifications by the outer hunk diff; once a pair is formed, the intraline highlight reflects the actual character differences" — matching how `hl-DiffText` behaves in built-in diff mode. Pairing-noise suppression and within-pair truth are thus cleanly separated.
- **Fragmentation guards as noise policy.** The `INTRALINE_MAX_HUNKS = 3` similarity gate, the `refinement_safe` prefix/suffix anchor requirement, and the hex-run coalescer all exist to prevent the classic word-diff failure mode: technically-minimal but visually-garbage interleaved highlights. Each guard falls back to a coarser, more legible granularity rather than showing a fragmented one.
- **`linematch`** (Neovim's xdiff post-pass that re-pairs lines within a hunk by similarity) is honored when present in `'diffopt'`, improving which lines get intra-line treatment.
- **No formatting-noise classification** beyond whitespace flags: no "unimportant text" rules, no structural/AST equivalence, and no moved-code detection anywhere in the tree.

### 4. Navigation, folding & scale

- Hunk jumps in side-by-side layouts are native `[c`/`]c`; the inline layout keeps its own hunk table per buffer (`M.hunk_anchor_rows`, `M.next_hunk_row`/`M.prev_hunk_row` in `inline_diff.lua`) and scroll adjusters that keep BOF/EOF virt_lines reachable. Conflicts get `]x`/`[x` with a `[n/total]` echo (`lua/diffview/actions.lua`).
- The file panel preserves tree-collapse state across tab switches, shows file counts on collapsed folders and a loading indicator (both from the bootstrap PR batch), and supports fork-added multi-file selection (`w` toggle / `C` clear) whose marks persist across Neovim restarts in a JSON store keyed by `toplevel .. ":" .. rev_arg` (`lua/diffview/selection_store.lua`, atomic temp-file + rename writes).
- File history is fetched incrementally by async workers; the commit-log panel caps at `-n256` by default, `gL` filters the log by the file under the cursor, and a `FocusGained` auto-refresh is throttled with the log rebuild skipped (`perf(file-history)` commits) to avoid flicker.
- Scale guards in the inline renderer are explicit constants: tree-sitter parsing of the old side is skipped above `CAPTURE_SOURCE_MAX_LEN`; per-byte capture resolution is skipped for lines over `CAPTURED_CHUNKS_MAX_LEN = 5000` bytes ("mirrors the spirit of `'synmaxcol'`"); a UTF-8 iterator replaces the quadratic `strcharpart` loop; virt_line padding is capped at `DELETION_HL_WIDTH_CAP = 500`. A bootstrap fix limits custom fold creation to prevent UI freezes on huge diffs (upstream issue 552).
- Session restoration (`lua/diffview/session.lua`): open views survive `:mksession` + `:source` by writing a versioned `<session>.diffview.json` sidecar on `SessionWritePost`/`VimLeave` and replaying the recorded `:DiffviewOpen`/`:DiffviewFileHistory` invocations on `SessionLoadPost`, wiping the stale inert `diffview://` buffers a session brings back, then restoring per-file cursor/viewport via `winrestview`.

### 5. VCS & review integration

- **Adapter seam:** an abstract `VCSAdapter` class (`lua/diffview/vcs/adapter.lua`, `oop.abstract_stub()` methods) with five implementations under `lua/diffview/vcs/adapters/`: `git` (2825 lines), `hg` (also serving Sapling via `hg_cmd = { "sl" }`), `jj` (2002 lines, fork-new), `p4` (experimental, fork-new), and `null` (fork-new, backing the no-VCS `:DiffviewMergeFiles`/`:DiffviewDiffDirs` views). Colocated jj/git repos choose via `preferred_adapter`.
- **Git plumbing:** `rev-parse`, `merge-base` (for `A...B` symmetric ranges and `--merge-base`), `ls-files` (with `core.quotePath=false`), `cat-file -e`, `log`/`diff --numstat`. Staging is the standout: index buffers are _editable_, and a `BufWriteCmd` autocmd (`lua/diffview/vcs/file.lua`) turns `:w` into `git hash-object -w` + `git update-index --index-info` — hunk staging by editing text, no hunk-picker UI. A `watch_index` fs-watcher refreshes the panel when external tools (e.g. gitsigns) touch the index, with a fork fix breaking the watcher's self-refresh loop.
- **jj adapter:** revsets via `jj log -r` with a `\x01`-separated template, fileset-literal path escaping, `jj restore --from <commit>` for `file_restore` (suggesting `jj op undo` as the undo), working-copy conflicts routed to the merge-tool layout, and change-ids surfaced in the history panel. Staging actions are explicit one-warning no-ops — jj has no index.
- **Review model:** PR review is a documented _idiom_, not an integration — `USAGE.md` prescribes `:DiffviewOpen origin/main...HEAD` (optionally `--imply-local` so the right side is the editable working file, making LSP available during review) and per-commit walking via `:DiffviewFileHistory --range=origin/main...HEAD`. There is **no forge integration**: no comment threads, no review submission, no stacked-PR awareness.
- **Merge:** conflict regions are parsed from markers (`parse_conflicts` in `lua/diffview/vcs/utils.lua`); actions `conflict_choose` (`ours`/`theirs`/`base`/`all`/`none`, per-region or whole-file) plus the fork-added `conflict_choose_side` (replace the merged buffer wholesale with one side).

### 6. Architecture & reuse

Single-process Lua running inside Neovim. Infrastructure is all in-tree: a class system (`lua/diffview/oop.lua`), a lazy module loader (`lua/diffview/lazy.lua`), coroutine-based async futures (`lua/diffview/async.lua`, adapted from `lewis6991/async.nvim`), libuv job wrappers (`job.lua`, `multi_job.lua`), an event emitter, a debounce/throttle module, and perf timers. The fork added a functional test suite (`lua/diffview/tests/`, `Makefile` target) and conventional-commit CI — upstream had essentially none, which the fork's regression-heavy history (90 `fix` commits) suggests it needed.

Reusable _ideas_ rather than reusable code: the renderer is inseparable from Neovim's extmark/virt_lines API and the layouts from its windowing, but three seams are cleanly portable as designs — the `VCSAdapter` abstraction (five backends including a null adapter that turns the diff UI into a general file/directory comparator), the `inline_diff.lua` pipeline (a pure function of `(old_lines, new_lines, opts)` producing highlight spans plus deleted-block insertions), and the edit-script-driven panel refresh that preserves UI state across model updates.

## Strengths

- The intra-line pipeline is the most carefully-guarded word/char refinement surveyed in an editor plugin: subword tokenization with an acronym rule, hash-literal coalescing with four cheap rejection signals, and an explicit fragmentation gate with documented failure examples (`[pa]r[am]eturn`) — every heuristic has a comment stating what it rejects and why.
- Deleted code keeps real syntax highlighting (string-parser tree-sitter captures, full capture-stack forwarding, content-keyed caching) — rare even among GUI diff tools.
- Delegating side-by-side diffing and alignment to the editor's native diff mode keeps the plugin small and gives users one knob (`'diffopt'`) for algorithm, linematch, and whitespace policy everywhere.
- Clean multi-VCS adapter seam, proven by four real backends plus a null adapter that generalizes the UI to no-VCS comparisons and jj tool integration.
- Staging-by-editing-the-index-buffer composes with all of Vim rather than reinventing a hunk picker.
- The fork process itself: pending upstream PRs integrated with authorship preserved, a changelog documenting breaking changes with upstream issue links, tests and commit-lint added.

## Weaknesses

- No formatting-noise story beyond xdiff's whitespace flags: a formatter re-aligning a markdown table still produces full-width changed pairs; nothing classifies or demotes noise-only line pairs, and there is no moved-code detection.
- No review-platform integration — comments, approvals, revisions, and stacks are out of scope; "PR review" is a revision-range idiom documented in `USAGE.md`.
- Diff quality is bounded by line-based xdiff; no structural/AST awareness anywhere.
- Everything is monolith-bound to Neovim APIs (extmarks, virt_lines, diff mode, windows); nothing is a library.
- The inline renderer is 1991 lines of priority juggling, window-scoped-namespace fallbacks, and scroll adjusters — evidence that retrofitting a unified view onto an editor's overlay API costs more than owning the render loop.
- GPL-3.0 license limits code (not idea) reuse in permissively-licensed projects.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                         | Trade-off                                                                                                |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Build on Neovim's native diff mode instead of computing diffs          | Free alignment, filler lines, `'diffopt'` compatibility, `do`/`dp` hunk ops; tiny plugin surface  | Diff granularity/algorithm capped at xdiff; unified view impossible natively, forcing the extmark layout |
| Fork-side unified view as extmark overlays on the _new_ buffer         | Real, editable buffer keeps LSP/TS/user plugins working; no synthetic concatenated buffer         | 1991-line renderer managing priorities, namespace scoping, virt_line scrolling edge cases                |
| Reuse `vim.diff` (xdiff) as the token/char differ via join-with-`"\n"` | One well-tested diff engine for lines, words, and chars; no Lua diff implementation to maintain   | Encoding hack (trailing-newline correctness trap, documented twice); per-call FFI cost per line pair     |
| Gate char-level refinement (`refinement_safe`, `INTRALINE_MAX_HUNKS`)  | Fragmented minimal diffs read worse than coarser highlights; fall back to legibility              | Genuinely fine-grained changes on dissimilar lines get whole-word or no intra-line highlighting          |
| Forward `ignore_*` flags to line pairing but never to intra-line diffs | Pairing should be noise-tolerant; within a pair the reader must see the true character delta      | Whitespace-only changes inside paired lines still light up (by design)                                   |
| Stage hunks by editing index buffers (`BufWriteCmd` → `update-index`)  | Composes with every Vim editing feature; no bespoke hunk-selection UI to build                    | Concept is opaque to newcomers; needs careful index-watcher loop-breaking; meaningless on jj             |
| Multi-VCS via an abstract adapter class incl. a `null` adapter         | One UI amortized over git/hg/sl/jj/p4 and no-VCS file/dir comparison                              | Lowest-common-denominator pressure; per-VCS quirks (staging, revsets, filesets) leak into UI guards      |
| Fork bootstrap = integrate upstream's open PR queue first              | Immediate value capture; contributors' authorship preserved; divergence documented in a changelog | Inherited ~50 lightly-reviewed changes at once; 90 fix commits in the following six months               |

## Sources

- Local checkout at `/home/petar/code/repos/neovim/diffview-plus.nvim`, revision `62dc5adf4e77489a2a6d3bf36ef6e4ac5738b634` (2026-07-20) — primary; key files: `lua/diffview/scene/inline_diff.lua`, `lua/diffview/diff.lua`, `lua/diffview/vcs/adapter.lua`, `lua/diffview/vcs/adapters/{git,jj}/init.lua`, `lua/diffview/scene/layouts/`, `lua/diffview/session.lua`, `lua/diffview/selection_store.lua`, `lua/diffview/config.lua`, `doc/diffview_changelog.txt`, `README.md`, `USAGE.md`
- Fork repository: [dlyongemallo/diffview-plus.nvim][fork-repo] (surveyed tree: [pinned][fork-tree])
- Upstream repository: [sindrets/diffview.nvim][upstream-repo]
- Upstream issues motivating fork features: [#286][upstream-286] (directory diffing), [#562][upstream-562] (Jujutsu support)
- Fork issue [#109][fork-109] (origin of the overleaf strikethrough style)

<!-- References -->

[fork-repo]: https://github.com/dlyongemallo/diffview-plus.nvim
[fork-tree]: https://github.com/dlyongemallo/diffview-plus.nvim/tree/62dc5adf4e77489a2a6d3bf36ef6e4ac5738b634
[upstream-repo]: https://github.com/sindrets/diffview.nvim
[upstream-286]: https://github.com/sindrets/diffview.nvim/issues/286
[upstream-562]: https://github.com/sindrets/diffview.nvim/issues/562
[fork-109]: https://github.com/dlyongemallo/diffview-plus.nvim/issues/109
