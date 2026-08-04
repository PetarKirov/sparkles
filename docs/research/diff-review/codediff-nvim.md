# codediff.nvim (Lua + C / Neovim)

A Neovim diff plugin that replaces the editor's builtin diff mode with a byte-for-byte C port
of VSCode's `defaultLinesDiffComputer`, rendered entirely through extmarks — two-tier
line/char highlighting, virtual filler lines, an inline layout with tree-sitter-colored
virtual deleted lines, git explorer/history panels, hunk staging, and a 3-way merge view.

| Field             | Value                                                                                     |
| ----------------- | ----------------------------------------------------------------------------------------- |
| Language          | Lua (plugin, ~30 kLoC incl. tests) + C11 (`libvscode-diff` diff core, via LuaJIT FFI)     |
| License           | MIT (`LICENSE`; diff algorithm derived from Microsoft VSCode, MIT — see `ATTRIBUTION.md`) |
| Repository        | <https://github.com/esmuellert/codediff.nvim>                                             |
| Documentation     | `README.md`, `doc/codediff.txt`, `docs/` (user docs) + `docs/development/` (devlogs)      |
| Category          | editor-diff                                                                               |
| First release     | Repository history begins 2025-10-22; devlogs date the project start to October 2024      |
| Latest release    | `VERSION` = 2.66.0 at the surveyed revision (tags up to `v2.9.4` in the local clone)      |
| Surveyed revision | `31510a9b34c032b6fe98fc158d4066702f68cff2` (2026-08-02)                                   |

## Overview

### What it solves

Neovim's builtin `diffthis` machinery is limited in three ways this plugin targets: the
diff quality (xdiff hunks with, at best, `linematch` refinement — no word-boundary
heuristics, no per-hunk character refinement), the rendering (whole-line `DiffChange`
plus `DiffText`, no syntax highlighting on removed lines, filler lines only at hunk
granularity), and the surrounding workflow (no file explorer, no staging, no 3-way merge
UI). codediff.nvim replaces all three layers at once: it computes diffs with an exact C
port of VSCode's diff engine, renders them with extmarks/`virt_lines` (never touching
buffer text), and wraps them in explorer, history, conflict, and staging workflows —
essentially a `diffview.nvim`-class tool whose differentiator is the diff engine itself.

### Design philosophy

The project's core bet is _parity with VSCode rather than a new algorithm_. From
`README.md`:

> **Same implementation as VSCode's diff engine**, providing identical visual
> highlighting for most scenarios

The C core is explicit about this; `libvscode-diff/src/myers.c` opens with:

> Algorithm selection matches VSCode exactly:
>
> - Lines: DP if total < 1700, otherwise Myers O(ND)
> - Chars: DP if total < 500, otherwise Myers O(ND)

and `libvscode-diff/default_lines_diff_computer.c` declares "C port of VSCode's
`DefaultLinesDiffComputer` class with 100% parity". The `docs/development/` tree is a
rare artifact: a chronological devlog of chasing that parity (`02-c-diff-algorithm/parity-evaluation-journey.md`),
including a tool that extracts VSCode's own diff as a test oracle
(`03-build-and-platform/vscode-extraction-tool.md`). A second principle is _never mutate
buffers_: all rendering — including alignment filler rows — is extmark-based, so the
diffed buffers remain real, editable, LSP-attached files.

## How it works

### 1. Diff computation & data model

The diff is computed **in-process** by `libvscode-diff`, a dependency-free C library
(vendoring only `utf8proc`) loaded through LuaJIT FFI (`lua/codediff/core/diff.lua`
declares the structs in `ffi.cdef` and marshals Lua line arrays to `const char**`).
Nothing is parsed from `git diff` output; git only supplies file _contents_ (§5), and the
two sides are always the literal buffer/blob lines.

The pipeline mirrors VSCode stage by stage:

- **Line level** (`src/line_level.c`): lines are interned into integers via a perfect
  hash of their _trimmed_ content (`string_hash_map.c`), then diffed with a size-selected
  algorithm — an O(MN) dynamic-programming LCS when `origLines + modLines < 1700`, else
  Myers O(ND) (`src/myers.c`). The DP variant uses VSCode's equality scoring
  (`1 + log(1 + len)` for a match, `0.1` for empty-line matches) so it prefers aligning
  on long distinctive lines over blank lines.
- **Heuristic optimization** (`src/optimize.c`): `join_sequence_diffs_by_shifting`,
  `shift_sequence_diffs` (boundary-score-driven shifting of hunk edges toward natural
  boundaries), and `remove_very_short_matching_lines_between_diffs` (merges hunks
  separated by trivially short matches).
- **Character refinement** (`src/char_level.c`): each changed region is re-diffed at
  character granularity over a `LinesSliceCharSequence`, then post-processed with
  `extend_diffs_to_entire_word_if_appropriate` and
  `remove_very_short_matching_text_between_long_diffs`; an `extend_to_subwords` option
  (exposed in the FFI struct, camelCase-boundary-aware) exists but is not surfaced in the
  plugin config.
- **Moved-code detection** (`src/compute_moved_lines.c`): a full port of VSCode's
  `computeMovedLines.ts` ("All thresholds and logic match VSCode exactly"), opt-in via
  `compute_moves` to match VSCode's `experimental.showMoves`.

The result type is VSCode's shape verbatim: `LinesDiff { changes:
DetailedLineRangeMapping[], moves: MovedText[], hit_timeout }`, where each mapping holds
1-based end-exclusive `LineRange`s for both sides plus `inner_changes: RangeMapping[]`
with **UTF-16 code-unit columns** (a deliberate parity decision, documented in
`docs/development/02-c-diff-algorithm/utf8-and-vscode-parity.md`; the Lua layer converts
to bytes at render time). Granularity is therefore line + char; there is no AST-level
structural diffing.

Two throughput mechanisms: a `max_computation_time_ms` budget (default 5000 ms, VSCode's
default) checked inside each Myers run — on expiry the affected region degrades to a
whole-region change while cheap regions keep full char detail (`docs/performance.md`
frames this as "useful character diffs are naturally fast") — and OpenMP
parallelization of the per-region character refinement
(`#pragma omp parallel for schedule(dynamic, 1)` over changed regions in
`default_lines_diff_computer.c`, capped at 4 threads unless `OMP_NUM_THREADS` is set).

### 2. Rendering & layout

Both **side-by-side** (default) and **inline/unified** layouts exist, toggleable at
runtime with `t` (`ui/view/toggle.lua`), including under the explorer and conflict modes.

Side-by-side (`ui/view/side_by_side.lua` + `ui/core.lua`) opens a new tab with two real
windows. Rendering is a three-step extmark pass (`docs/rendering-quick-reference.md`):

1. **Line tier**: one _ranged_ extmark per changed line range with `hl_eol = true`
   (`CodeDiffLineDelete`/`CodeDiffLineInsert`) — deliberately a single extmark per range,
   not per line, to keep extmark counts low on large hunks.
2. **Char tier**: extmarks at priority 200 for each non-empty `inner_changes` range
   (`CodeDiffCharDelete`/`CodeDiffCharInsert`), after UTF-16→byte conversion via
   `vim.str_byteindex`. Colors are auto-derived from the colorscheme's `DiffAdd`/
   `DiffDelete`: char-tier backgrounds are the line-tier color brightened 1.4× on dark
   themes / darkened 0.92× on light themes (`ui/highlights.lua`), so the two tiers read
   as one system in any theme.
3. **Fillers**: alignment rows are `virt_lines` extmarks (`ui/filler.lua`) filled with a
   repeated `filler_text` pattern (`╱` by default, blank if `""`). Crucially, filler
   _placement_ ports VSCode's `computeRangeAlignment` from `diffEditorViewZones.ts`
   (`calculate_fillers` in `ui/core.lua`, documented exhaustively in
   `docs/filler-line-algorithm.md`): alignment points are derived from `inner_changes`
   boundaries, so panes align _inside_ a hunk at corresponding sub-edits, not merely at
   hunk ends — visibly better than vimdiff on hunks that mix modification and insertion.

Because filler heights can exceed a window, native `scrollbind` oscillates
(`w_topfill` clamping makes its display-line accounting discontinuous). The plugin ships
its own scroll sync (`scrollsync.lua`) that maps each window into a shared **virtual-row
coordinate** — real line index plus a binary-searched cumulative count of `virt_lines`
from _all_ namespaces — mirroring the structural principle of Neovim's internal
`diff_set_topline`, and sets partner windows to the same virtual row with zero flicker.

The inline layout (`ui/inline.lua`, `ui/view/inline_view.lua`) renders on the modified
buffer alone: deleted lines become `virt_lines` placed above the corresponding modified
position. Since virtual lines get no automatic syntax highlighting, the plugin runs a
tree-sitter **string parser** over the original content
(`vim.treesitter.get_string_parser`), collects capture ranges per line, and synthesizes
merged highlight groups (syntax fg/bold/italic + diff bg, cached per pair) per chunk
(`get_merged_hl`); a 300-space padding chunk fakes `hl_eol` for virtual lines. Real
(non-virtual) buffers keep their normal treesitter/LSP highlighting untouched, since
diff decoration is pure background extmarks; virtual git-revision buffers additionally
get LSP semantic tokens by attaching clients to `codediff://` buffers and processing
token responses with functions vendored from Neovim core (`ui/semantic_tokens.lua`).
Wrapping is disabled in diff windows (`wrap = false` — the scroll sync assumes one screen
row per real line). Line numbers are left to user config; there is no separate gutter —
signs are used only for moved-code and conflict markers.

### 3. Intra-line & noise handling

Word/char refinement is the engine's centerpiece (§1): per-hunk char diffs, extended to
word boundaries when appropriate, with short matching fragments between long diffs
absorbed — the same heuristics that make VSCode's intra-line highlights look "intentional"
rather than minimal-edit-script-shaped.

Whitespace handling has a subtle two-level structure inherited from VSCode: the
line-level hash always interns **trimmed** lines, so lines differing only in
leading/trailing whitespace _align_ as matches; when `ignore_trim_whitespace = false`
(default), a `scan_for_whitespace_changes` pass re-adds those whitespace-only
differences as char-level `inner_changes` (`default_lines_diff_computer.c`:
`consider_whitespace_changes = !options->ignore_trim_whitespace`). Setting the option
therefore suppresses trim-whitespace noise without ever disturbing line alignment.
Interior whitespace (e.g. re-padded table columns) is _not_ special-cased: it shows up as
ordinary char-level inner changes — precisely localized, but not classified as noise.

Moved-code detection (opt-in) renders moves with dedicated highlights, signs, and
annotation `virt_lines`, and a `gm` keymap temporarily inserts filler alignment so a
moved block lines up horizontally across panes (`ui/move.lua`). There is no
formatting-noise classification beyond whitespace and no structural equivalence checking.

### 4. Navigation, folding & scale

- **Hunks**: `]c`/`[c` with configurable wrap-around, `]f`/`[f` for files, and
  `cycle_hunks_across_files` to hop into the next file's first hunk at a boundary. A hunk
  **textobject** `ih` (`vih`, `yih`, …) is registered. `do`/`dp` work like vimdiff.
- **Compact mode** (`gc`, `ui/view/compact.lua`): folds unchanged regions via a
  `foldexpr` over a precomputed visible-line set (hunks ± `compact_context_lines`,
  default 3). Fold open/close is synced across panes by wrapping the `zo`/`zc`/`za`/…
  keymaps and translating the cursor line to the partner pane with
  `compute_corresponding_lnum` — a proportional line mapping explicitly modeled on the
  `diff_lnum_win` logic in Neovim's `src/nvim/fold.c`.
- **Explorer panel** (`ui/explorer/`): git status as list or tree (with single-child
  directory flattening, indent markers, Vim-style `z*` fold keys), grouped into
  staged/unstaged/conflicts with per-group visibility toggles, glob file filters,
  optional per-file `+12 -4` numstat line stats with folder/group aggregates, and a
  user-overridable row formatter protocol (segments + `truncate_priority`,
  display-cell-aware truncation).
- **History panel** (`ui/history/`): `git log` for a range/file, commits expandable into
  per-commit file trees; selecting a file diffs it against its parent.
- **Scale guards**: the diff timeout (§1); `explorer.untracked = "no"` for huge work
  trees; `auto_refresh = false` opt-out for large repos; async git everywhere; content
  caching for immutable revisions (`core/git.lua` caches `git show` output, skipping
  mutable `:0`–`:3` index revisions); single ranged extmarks for line tiers.

### 5. VCS & review integration

Git integration is shell-out plumbing, fully async (`vim.system` on 0.10+, `vim.loop.spawn`
fallback; `core/git.lua`): `status --porcelain`, `diff --numstat -z -M` (rename-aware
stats), `ls-files --others --exclude-standard`, `show <rev>:<path>`, `merge-base`,
`log` with custom format for the history panel. Revision-pinned file content lives in
**virtual buffers** with a `codediff:///<root>///<rev>/<path>` URL scheme materialized by
a `BufReadCmd` autocmd (`core/virtual_file.lua`) — which is also what lets LSP servers
attach to historical revisions for semantic tokens.

Staging is first-class: file-level stage/unstage/restore (explorer `-`, `S`, `U`, `X`),
plus **hunk-level** `stage_hunk`/`unstage_hunk`/`discard_hunk`. Hunk staging does not
parse or replay `git diff` output; it _constructs_ a minimal zero-context unified diff
from the in-memory mapping (header `@@ -a,b +c,d @@` plus bare `-`/`+` lines,
`build_hunk_patch` in `ui/view/actions/hunk.lua`) and pipes it to
`git apply --unidiff-zero [--cached] [--reverse]` (`git.apply_patch`). `gS` swaps a
file's staged/unstaged view.

Merge conflicts get a dedicated 3-way view: ours (`:2`) and theirs (`:3`) panes each
diffed against base (`:1`), aligned by a Lua port of VSCode's `lineAlignment.ts`
(`ui/merge_alignment.lua` — "Exact port") that computes joint filler sets and identifies
_conflict_ regions (both sides touching the same base range); only conflicting changes
are highlighted, matching VSCode's merge editor. A result pane (bottom or center-column
layout) supports per-conflict accept incoming/current/both/discard (`<leader>ct/co/cb/cx`),
whole-file variants, conflict navigation `]x`/`[x`, and `2do`/`3do` diffget.

There is **no review-platform integration**: no PR fetching, no comments, no revision
stacks — scope is the local repository (GitHub issue numbers in comments show the tool is
used for working-tree review, not forge review).

### 6. Architecture & reuse

The architecture is a clean two-layer split. `libvscode-diff` is an editor-agnostic C
library — `compute_diff(const char** a, int, const char** b, int, DiffOptions*)` →
`LinesDiff*` — with its own CMake/CI, unit tests (`libvscode-diff/tests/`), a CLI
(`diff_tool.c`), and no dependency on Neovim; the Lua plugin is one consumer over FFI
(results are deep-copied to Lua tables and freed immediately). Distribution sidesteps
compile-on-install: the plugin downloads a prebuilt versioned binary from GitHub releases
(`core/installer.lua`, keyed on the `VERSION` file), with `build.sh`/CMake fallbacks.

Plugin state is a per-tabpage session (`ui/lifecycle/`) holding buffers, windows, mode,
revisions, and the stored diff result; every keymap action receives a session context
rather than closing over buffers "so a mapping installed for one diff cannot act on a
stale buffer" (`ui/view/actions/hunk.lua`). A keymap registry (`keymap/registry.lua`)
resolves user/default key conflicts by letting user assignments steal keys and unmapping
the displaced default. A `lua/vscode-diff/` shim preserves the plugin's old name.

Reusable pieces for a from-scratch differ: the C library itself; the
inner-change-driven filler alignment algorithm (`docs/filler-line-algorithm.md` is a
standalone spec); the virtual-row scroll-sync model; the two-tier auto-derived highlight
scheme; the zero-context-patch staging trick. The rendering layer is Neovim-extmark-bound.

## Strengths

- Best-in-class diff _quality_ for an editor plugin: VSCode's full heuristic pipeline
  (boundary shifting, word extension, short-match removal) verified against VSCode's own
  output, not a re-derivation.
- Sub-hunk pane alignment (fillers at inner-change boundaries) — visibly tighter than
  vimdiff/`linematch` on mixed hunks.
- Decoration-only rendering: buffers stay real and editable; LSP, treesitter, and user
  options keep working; even deleted lines get syntax colors and semantic tokens.
- Predictable performance: per-region timeout degrades gracefully; OpenMP refinement;
  async git with content caching.
- Complete local-git workflow in one tool: explorer, history, file+hunk staging, 3-way
  merge with VSCode-style conflict-only highlighting.
- Exceptional engineering documentation (`docs/development/` devlogs, algorithm specs,
  parity journey) — the project doubles as a readable explanation of VSCode's diff.

## Weaknesses

- Line + char granularity only: no structural/AST awareness, so formatter-induced
  interior-whitespace churn (e.g. realigned tables) is precisely highlighted but never
  _classified_ as noise; `ignore_trim_whitespace` covers leading/trailing only.
- No forge/review layer: no PR comments, review threads, or stacked-change model.
- Binary dependency: FFI + downloaded per-platform shared library (plus a bundled
  `libgomp` on some Linux systems) is a heavier install story than pure-Lua plugins, and
  LuaJIT FFI ties it to Neovim's LuaJIT builds.
- UTF-16 column convention leaks out of the C core; every renderer must convert to bytes
  (`utf16_col_to_byte_col` is duplicated in `ui/core.lua` and `ui/inline.lua`).
- Inline-layout virtual lines fake `hl_eol` with 300-space padding and re-parse the whole
  original file with a string parser per render — pragmatic, but O(file) work per redraw
  of a single-file diff and a hard-coded width assumption.
- Moved-code detection is opt-in and rendering-only (indicators + temporary `gm`
  alignment); moves still appear as delete+insert in the change list.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                         | Trade-off                                                                                                |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Port VSCode's diff to C verbatim instead of using xdiff/vim diff | Proven heuristics, testable against VSCode output ("100% parity"), reusable outside the editor    | Large C surface to maintain; inherits VSCode quirks (UTF-16 columns, JS-tuned thresholds)                |
| LuaJIT FFI to an auto-downloaded prebuilt shared library         | Native speed + OpenMP; "No compiler required!" install                                            | Platform binary matrix, release infrastructure, FFI marshalling cost, LuaJIT-only                        |
| Extmark/`virt_lines`-only rendering; never mutate buffers        | Buffers stay editable and LSP/treesitter-live; decorations are cheap to clear                     | Must re-implement filler alignment, scroll sync, and `hl_eol` semantics that builtin diff mode gets free |
| Custom virtual-row scroll sync replacing `scrollbind`            | Native scrollbind flickers when a filler block exceeds window height (`w_topfill` clamp)          | ~400 lines of window-coupling logic; assumes `nowrap`                                                    |
| Alignment fillers derived from `inner_changes` boundaries        | Sub-hunk visual alignment identical to VSCode's view zones                                        | Filler computation is coupled to the char-refinement output; more extmark churn per render               |
| Per-region diff timeout (`max_computation_time_ms`)              | Worst-case latency bound; cheap useful regions keep full detail                                   | Nondeterministic detail on huge diffs (`hit_timeout` surfaced but easy to miss)                          |
| Hunk staging via synthesized zero-context patch + `git apply`    | No `git diff` parsing; the in-memory mapping is the single source of truth                        | Bypasses git's own hunk splitting; `--unidiff-zero` patches are unforgiving of stale buffers             |
| Line hashing on trimmed content + whitespace rescan              | Whitespace-only edits never break line alignment; `ignore_trim_whitespace` becomes a cheap filter | Interior whitespace (column realignment) still reads as real change                                      |

## Sources

- Local checkout at the surveyed revision (primary): `lua/codediff/core/diff.lua`,
  `lua/codediff/ui/core.lua`, `lua/codediff/ui/inline.lua`, `lua/codediff/scrollsync.lua`,
  `lua/codediff/ui/view/compact.lua`, `lua/codediff/ui/view/actions/hunk.lua`,
  `lua/codediff/core/git.lua`, `lua/codediff/ui/merge_alignment.lua`,
  `libvscode-diff/default_lines_diff_computer.c`, `libvscode-diff/src/{myers,line_level,char_level,optimize,compute_moved_lines}.c`
- In-repo documentation: `README.md`, `docs/filler-line-algorithm.md`,
  `docs/performance.md`, `docs/rendering-quick-reference.md`, `docs/development/README.md`,
  `docs/development/02-c-diff-algorithm/utf8-and-vscode-parity.md`, `ATTRIBUTION.md`
- Upstream algorithm reference (as cited throughout the C sources):
  `src/vs/editor/common/diff/defaultLinesDiffComputer/` in [microsoft/vscode][vscode]

<!-- References -->

[vscode]: https://github.com/microsoft/vscode
