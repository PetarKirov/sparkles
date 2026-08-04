# diffs.nvim (Lua / Neovim)

Treesitter-powered diff syntax highlighting for Neovim that grew into a full diff surface: it upgrades diff text wherever it already appears (fugitive, Neogit, `git commit --verbose`, email-quoted patches), and generates its own unified/stacked/split views, whole-repo review buffers, hunk staging, and conflict resolution — all painted with extmarks over plain text, never by mutating buffer content.

| Field             | Value                                                             |
| ----------------- | ----------------------------------------------------------------- |
| Language          | Lua (LuaJIT inside Neovim; ~12,900 lines under `lua/diffs/`)      |
| License           | MIT (`LICENSE`)                                                   |
| Repository        | [github.com/barrettruth/diffs.nvim][repo]                         |
| Documentation     | `doc/diffs.nvim.txt` (1,569 lines), `README.md`                   |
| Category          | editor-diff                                                       |
| First release     | `v0.1.0`, 2026-02-03 (first commit 2026-02-01)                    |
| Latest release    | `v0.4.0`, 2026-06-11 (382 commits total at the surveyed revision) |
| Surveyed revision | `70882fe6364dfe7f46463b712c6e0e0c0712b408` (2026-07-23)           |

## Overview

### What it solves

Stock Neovim colors diff buffers with two flat highlight groups (`diffAdded` / `diffRemoved`): no language syntax inside hunks, no word-level change emphasis, no way to tell a whitespace-only line from a real one. diffs.nvim replaces that with per-language treesitter highlighting _inside_ diff hunks, blended line backgrounds that keep syntax legible, and character-level intra-line refinement — and it applies the same treatment uniformly to third-party plugin buffers (fugitive/Neogit status views, gitsigns previews), to the built-in `diff` filetype, and to its own generated `:Diff` views. Later releases layered a scope on top that overlaps a slice of diffview.nvim: `:Diff review` (whole-repo review with quickfix navigation), a plugin-rendered side-by-side split, hunk staging/unstaging, and merge-conflict resolution.

### Design philosophy

The core stance is _decorate, don't own_: content stays plain text and every visual is an extmark, so the plugin composes with whatever produced the buffer. From `doc/diffs.nvim.txt`:

> "diffs.nvim adds language-aware syntax highlighting to unified diff content in Neovim buffers. It replaces flat `diffAdded`/`diffRemoved` coloring with treesitter syntax, blended line backgrounds, and character-level intra-line diffs."

Even the side-by-side view keeps this stance — the panes are not native `&diff` windows (`doc/diffs.nvim.txt`, "Paired-window behavior"):

> "The panes are not native `&diff` windows. They are plugin-rendered: the plugin aligns both sides row-for-row by inserting blank filler rows, then keeps the windows in lockstep with `scrollbind`/`cursorbind`. Because the panes hold real, contiguous file content, treesitter highlights them as the target language."

A second visible influence is [pierre-style diffs][pierre] — the `README.md` describes `:Diff` as "pierre-style unified, stacked, or split diffs against any revision", where _stacked_ is a single-column unified layout with one context-aware line-number rail rather than a stacked-PR model.

## How it works

### 1. Diff computation & data model

Diff data arrives through **four distinct channels**, unified into two hunk models:

- **Pre-existing diff text** — `parser.lua` (`parse_buffer`) re-parses whatever unified-diff text is already in a buffer: `diff --git` headers, Neogit's `modified <file>` headers, combined/`--cc` diffs, bare status lines (`M path`), and email-quoted patches (`> diff --git ...` — a `quote_prefix` is detected once and stripped per line). It tracks `@@ -a,b +c,d @@` counters (`old_remaining`/`new_remaining`) to survive blank lines inside hunks, resolves each file's filetype (`vim.filetype.match` by name, then by content sniffing the first 10 lines) and treesitter language, caching per `(repo_root, filename)`.
- **In-process `vim.diff`** (Neovim's bundled xdiff) — used to _generate_ unified text in `render.lua` (`unified_lines`, `result_type = 'unified'`, `ctxlen = 3`), honoring the user's `'diffopt'` algorithm (`myers`/`minimal`/`patience`/`histogram`) and `linematch` via `diffopt.lua`. The same engine drives intra-line refinement (§3).
- **`git diff` output** — `review.lua` shells out (`build_cmd`) for whole-repo reviews, forwarding `'diffopt'`-derived flags (`diffopt.git_flags()`) so ignore-whitespace settings apply to the generated review too.
- **External engines** — an optional **vscode-diff FFI library** (see §3) and **difftastic** (`difftastic.lua`): `difft --display json --color never --strip-cr off` with `DFT_UNSTABLE=yes`, parsed into per-line span maps and a whole-file `aligned_lines` structural alignment.

Two hunk models coexist: `diffs.Hunk` (`parser.lua`) is render-oriented (buffer line ranges, prefix/quote/rail widths, header context), while `diffs.DiffHunk` (`hunks.lua`) is semantic — kind-tagged lines (`context`/`add`/`delete`/`header`) carrying both `old_lnum` and `new_lnum`, plus a `diff_spec`. The `DiffSpec` type (`spec.lua`) is a small endpoint algebra: `{left, right, scope}` where an endpoint is `tree(rev)`, `index`, `worktree`, or `stage(n)` (merge stages `:1/:2/:3`), and constructors like `head_to_index`, `index_to_worktree`, `rev_to_rev` name the meaningful comparisons. Every generated buffer stores its `DiffSpec` in buffer variables, which is what makes `:edit`-reload, staging, and split-pane regeneration possible.

### 2. Rendering & layout

The signature mechanism is a **decoration provider** (`runtime/decorator.lua`): `nvim_set_decoration_provider(ns, {on_buf, on_win})`. `on_buf` ensures the hunk cache is parsed; `on_win` receives the viewport (`toprow`/`botrow`), binary-searches the visible hunk range (`cache_mod.find_visible_hunks`), and highlights **only visible, not-yet-highlighted hunks** — a fast pass (line backgrounds, prefixes, intra-line spans) runs synchronously inside the redraw, while treesitter and vim-syntax passes are pushed to a `vim.schedule` job guarded by a `(tick, changedtick, job_id)` triple so stale deferred renders are dropped.

Treesitter never parses the diff buffer itself. `highlight.lua` reconstructs the **new-side** and **old-side** code from each hunk's lines (context lines go to both sides), parses each side with `vim.treesitter.get_string_parser` — optionally prepending up to 25 real context lines fetched from the underlying file so hunks that start mid-scope parse better — and maps node ranges back to buffer lines via a `line_map` table, emitting extmarks with a strict priority ladder (`clear = 198 < syntax = 199 < line_bg = 200 < char_bg = 201`). Injected languages are handled via `parser:for_each_tree`. Files without a treesitter parser fall back to legacy vim syntax: a scratch buffer is populated, `synID()` is probed per cell, spans are coalesced (`coalesce_syntax_spans`) and memoized in a 128-entry LRU keyed by `(ft, hunk text)` — cold hunks paint one frame late (a documented limitation in `README.md`).

Backgrounds are alpha-blended (`runtime/highlight_groups.lua`, `blend_alpha = 0.6` against the theme background) so syntax colors stay legible on add/delete rows. The `+`/`-` prefix column can be concealed with an overlay `virt_text` space and replaced by a change bar `▏`.

Three generated layouts (`:Diff [++layout=...]`):

- **unified** — a `diffs://` buffer of unified diff text with two prepended line-number rails (old │ new, `rails.lua`), painted by the same decorator.
- **stacked** — same text, one _context-aware_ rail: `-` rows show old-side numbers, `+` and context rows show new-side numbers (`doc/diffs.nvim.txt`, `diffs.nvim-stacked-layout`), so a replacement pair shows the same number twice. Single-column, reads top-to-bottom like a Pierre/GitHub mobile diff.
- **split** — `split.lua` + `split_align.lua`: two scratch buffers holding _real file content_ per endpoint, aligned row-for-row by inserting empty filler rows (`align()` walks hunks, pairing delete/add runs with `math.max(#dels, #adds)` rows), locked with `scrollbind`/`cursorbind`. Per-side line numbers render in a **`statuscolumn` rail** (`M.statuscolumn()` formats a number segment plus change bar per row, blank on fillers) so the plugin never fights the user's global `number`/`statuscolumn` — originals are saved and restored on close. Because panes hold contiguous real content, ordinary buffer-attached treesitter highlights them natively.

### 3. Intra-line & noise handling

Intra-line refinement (`diff.lua`) runs per hunk with three cooperating pieces:

- **Change-group extraction** — `extract_change_groups` collects adjacent `-`-run/`+`-run pairs; groups with only one side are never refined (pure additions/deletions stay solid).
- **Line pairing** — a 1:1 group pairs directly; an m:n group is line-mapped by running `vim.diff` over the two blocks (`pair_group_lines`), pairing equal-count runs positionally so refinement compares the _right_ lines.
- **Character diff via byte-split** — `char_diff_pair` splits each line into one **byte per line** and runs `vim.diff` on that (`split_bytes` + join with `\n`), converting xdiff's line hunks into byte-column spans. It is a clever reuse of the only diff engine available in-process, at the cost of byte (not grapheme) granularity and O(line-length) temporary strings.

An optional higher-fidelity backend is the **vscode-diff algorithm** as a C-ABI shared library: `lib.lua` auto-downloads `libvscode_diff.{so,dylib,dll}` (version-pinned, from codediff.nvim's GitHub releases), FFI-defines `compute_diff(original_lines, ..., DiffsDiffOptions) -> DiffsLinesDiff` with `inner_changes` char ranges, `max_computation_time_ms = 1000`, and a `compute_moves` flag that diffs.nvim currently hardcodes to `false` — so moved-code detection exists in the engine but is not surfaced.

Whitespace noise is handled at two levels, both driven by the user's `'diffopt'` flags (`iwhiteall`/`iwhite`/`iwhiteeol`):

- **Span level** — `drop_whitespace_spans` filters intra-line spans whose covered text is pure whitespace ("The byte-level differ cannot express this itself, so it is filtered from the resulting spans" — `diff.lua`).
- **Line level** — `whitespace_only_lines` normalizes each _paired_ del/add line per the active flag (strip all ws / collapse runs / trim EOL) and flags pairs that become equal; flagged lines are **de-emphasized** (`DiffsDim` background instead of add/delete colors, no change bar, no intra spans) rather than hidden. Unpaired lines are never flagged.

The deepest noise tool is the **difftastic integration**: for split views (and `:Diff files`), `difftastic.align` runs `difft` on materialized temp files and consumes its JSON — `aligned_lines` (structural row alignment replacing the plugin's own filler algorithm) and per-line change spans (`chunks[].lhs/rhs.changes` byte ranges) painted as intra-line highlights. Rows with no structural spans render as plain context _even if their text differs_, and when the whole file has no structural change the user is told outright: `'difftastic: no structural changes (formatting only)'` (`split.lua`). A buffer rendered from difftastic output is marked (`diffs_difft_active`) so the decorator's own byte-level intra pass is suppressed — structural and textual refinement never mix.

### 4. Navigation, folding & scale

`]c`/`[c` jump between hunk **anchors** (first changed row of each hunk, precomputed in the alignment) with wraparound, moving both panes of a split in lockstep (`move_pair_to_row`). `<CR>` in any generated view opens the real source file at the mapped line — in a split pane it finds the nearest non-filler row to translate the cursor (`nearest_non_filler_row`). There is **no file-tree panel**: multi-file navigation is delegated to Neovim's quickfix/loclist (`lists.lua` — qflist gets one entry per file, loclist one per hunk, with titles like `review hunks: main...HEAD`), plus telescope/fzf-lua pickers. `:Diff review` structures its buffer into labeled sections (`# Branch:`, `# Staged:`, `# Unstaged:`, `# Untracked:`) with per-record line ranges powering the lists.

There is no folding/collapsing of unchanged regions: generated unified views carry only 3 context lines by construction, and split views intentionally show whole files. Scale guards are all _degradation thresholds_ rather than pagination: treesitter skipped above `max_lines = 500` changed lines per hunk (with a one-time warning), vim-syntax above 200, intra-line refinement above its own `max_lines`, a 5 s difftastic timeout, a 1 s vscode-diff budget — and the viewport-lazy decorator means a 50k-line review buffer only ever pays for hunks that scroll into view.

### 5. VCS & review integration

All git access is porcelain-free `vim.fn.systemlist` plumbing (`git.lua`): `rev-parse`, `show rev:path` / `show :0:path` (index), `ls-tree`/`ls-files --stage` (modes), `ls-files --unmerged`, `cat-file -e`, `merge-base`, `symbolic-ref refs/remotes/origin/HEAD` (default-branch detection). Content endpoints are read into memory; nothing uses libgit2.

- **Staging** — `actions.lua` synthesizes a minimal patch for the hunk (or a visual-mode _range within_ a hunk, with `--recount` header fixup) and applies it with `git apply --cached [--reverse]`, always running a `--check` dry-run first (`checked_apply`). This gives gitsigns-style hunk staging from inside a generated diff buffer.
- **Review** — `:Diff review [base[..|...target]]` compares against the detected default branch by default; `...` uses `merge-base` mode, `..` direct. A target-less review renders the **four-section current-state** buffer described above, each file record annotated with the exact `DiffSpec` needed to reopen it as a single-file diff or split.
- **Conflicts** — `conflict.lua` detects inline conflict markers (including diff3 `|||||||` bases) in any buffer, highlights and resolves per-region (`ours`/`theirs`/`both`/`none`); `merge.lua` matches diff hunks to conflict regions for a 3-way `git mergetool` workflow where Neovim opens `$MERGED`.
- **Not present** — no forge/PR-platform integration of any kind: no comments, no review submission, no revision comparison, no stacked-PR awareness ("stacked" is purely a visual layout). jujutsu support exists indirectly via the `neojj` integration (repo-root detection through `neojj`'s API).

### 6. Architecture & reuse

Single in-process Lua plugin; the only external processes are `git` and (optionally) `difft`, plus one optional downloaded C shared library. Layering is clean: `runtime/` (decoration provider, cache, attach, highlight groups) is the always-on engine; `parser`/`hunks`/`spec` are pure-ish model modules with `M._test` escape hatches and a 36-file busted spec suite; `commands.lua` (2,458 lines) is the monolithic orchestrator wiring `:Diff` subcommands, generated-buffer lifecycle (`diffs://` names + `BufReadCmd` reload from stored buffer-var sources), and integrations. Reusable _ideas_ rather than reusable code (it is all Neovim-API-bound):

- viewport-lazy, cache-invalidated decoration painting over immutable text;
- the `DiffSpec` endpoint algebra as the single currency between views, reload, and staging;
- hunk-isolated per-side treesitter parsing with real-file context prepend;
- consuming difftastic's JSON `aligned_lines` as a drop-in replacement for a textual alignment;
- statuscolumn-rendered per-side rails that never collide with user settings.

## Strengths

- Composability-first: it upgrades _other tools'_ buffers (fugitive, Neogit, gitcommit, gitsigns popups, email patches) instead of demanding its own UI, and degrades gracefully (treesitter → vim syntax → nothing) per file.
- The viewport-lazy decorator plus per-hunk caching makes huge review diffs cheap; every heavy pass has an explicit budget and a visible skip warning.
- Three-tier intra-line stack (byte-split xdiff → vscode-diff FFI → difftastic structural) with honest semantics boundaries — structural and byte-level refinement are never mixed in one buffer.
- Whitespace de-emphasis (dim, don't hide) driven by the user's existing `'diffopt'` — no parallel option vocabulary.
- `DiffSpec` + buffer-var sources make every view reloadable (`:edit`), stageable, and convertible (unified ↔ split ↔ stacked) without re-deriving state.
- The difftastic "no structural changes (formatting only)" verdict surfaces formatting-noise classification as a first-class user-facing signal.

## Weaknesses

- Native intra-line diffing is byte-granular, not grapheme/word-granular; word-accurate refinement requires downloading a prebuilt binary blob from another project's GitHub releases (supply-chain and offline concerns).
- Moved-code detection is compiled into the vscode-diff library but hardcoded off; difftastic's own move information is not consumed either.
- `render.file` rejects renames/copies, binary files, submodules, and mode-only changes outright — single-file generated views cover only the easy cases.
- No unchanged-region folding or context expansion; split views always materialize whole files.
- No forge layer: review is local-git only, with no comments, no PR revisions, no stacked-change model.
- Hunk-isolated treesitter parsing inherits error-recovery artifacts at hunk boundaries, and vim-syntax fallback paints a frame late (both self-documented in `README.md`).
- `commands.lua` concentrates a large share of behavior in one 2,458-line module; the clean model layer stops at the orchestrator.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                        | Trade-off                                                                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Paint via decoration provider + extmarks; never mutate text     | Composes with any buffer producer; viewport-lazy cost; trivially invalidated                     | First-paint flash on `FileType` hooks; vim-syntax spans land one frame late                                     |
| Re-parse hunk text with string parsers (per side, plus context) | Language highlighting inside diffs without opening real files                                    | Error recovery at hunk edges; per-language cold-start cost per session                                          |
| Byte-split `vim.diff` for intra-line spans                      | Zero new dependencies; honors `'diffopt'` algorithm settings                                     | Byte granularity; O(n) temp strings per line pair                                                               |
| Optional vscode-diff via downloaded C-ABI FFI library           | VS Code-quality word diffs without a build step for users                                        | Binary blob from a third-party release; version pinning burden; moves capability left unused                    |
| Difftastic as alignment _oracle_, not renderer                  | Structural alignment and formatting-only verdicts drop into the existing split/unified pipelines | Requires `difft` on PATH, `DFT_UNSTABLE` JSON, temp-file materialization, 5 s timeout                           |
| Split view = scratch buffers + filler rows + statuscolumn rails | Real file content ⇒ native treesitter; rails independent of user settings                        | Not `&diff`; must reimplement lockstep scrolling, hunk jumps, and pair lifecycle (a large share of `split.lua`) |
| Quickfix/loclist as the file navigator; no tree panel           | Reuses muscle memory and existing pickers; zero UI code                                          | No persistent file overview beside the diff; navigation state lives outside the view                            |
| `DiffSpec` endpoint algebra stored in buffer vars               | One currency for reload, staging, layout conversion, and review records                          | Serialized specs must stay version-compatible (`version = 1` fields, `generated/source.lua`)                    |
| Whitespace-only lines dimmed, not hidden                        | Keeps the diff truthful while removing visual weight                                             | Noise still occupies vertical space; no "hide entirely" option                                                  |

## Sources

- Local checkout at `/home/petar/code/repos/neovim/diffs.nvim` @ `70882fe6364dfe7f46463b712c6e0e0c0712b408` (2026-07-23) — primary; key files: `lua/diffs/diff.lua`, `lua/diffs/parser.lua`, `lua/diffs/highlight.lua`, `lua/diffs/runtime/decorator.lua`, `lua/diffs/split.lua`, `lua/diffs/split_align.lua`, `lua/diffs/difftastic.lua`, `lua/diffs/lib.lua`, `lua/diffs/review.lua`, `lua/diffs/actions.lua`, `lua/diffs/spec.lua`, `lua/diffs/git.lua`, `lua/diffs/rails.lua`, `doc/diffs.nvim.txt`, `README.md`
- [diffs.nvim repository][repo]
- [codediff.nvim][codediff] — origin of the `libvscode_diff` FFI backend
- [Difftastic][difftastic] — structural diff engine consumed via JSON
- [Pierre (diffs.com)][pierre] — the styling reference for the unified/stacked layouts

<!-- References -->

[repo]: https://github.com/barrettruth/diffs.nvim/tree/70882fe6364dfe7f46463b712c6e0e0c0712b408
[codediff]: https://github.com/esmuellert/codediff.nvim
[difftastic]: https://difftastic.wilfred.me.uk/
[pierre]: https://diffs.com
