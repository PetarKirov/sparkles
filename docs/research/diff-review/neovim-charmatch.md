# Neovim charmatch/wordmatch — PR #23569 (C, Neovim)

The linematch author's never-merged follow-up, which re-parameterizes linematch's N-dimensional
alignment DP to run over characters or words instead of lines — producing cross-line, multi-region
intra-line diff highlighting in Neovim's builtin diff mode — closed in July 2025 after mainline
gained the same capability by an entirely different route (`diffopt+=inline:{char,word}`, ported
from Vim 9.1.1243).

| Field             | Value                                                                                                                                                                                                 |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C (874 insertions / 81 deletions across 7 files; ~425 net lines in `src/nvim/diff.c`)                                                                                                                 |
| License           | Apache-2.0 with Vim License parts (Neovim `LICENSE.txt`)                                                                                                                                              |
| Repository        | [github.com/neovim/neovim][nvim] — PR [#23569][pr]                                                                                                                                                    |
| Documentation     | None. The PR adds no `runtime/doc/` changes; `chardiff:{N}` / `worddiff:{N}` are documented only in the PR body and by the screen tests in `test/functional/ui/linematch_spec.lua`                    |
| Category          | editor-diff (core diff engine, intra-line refinement)                                                                                                                                                 |
| Status            | Unmerged. Opened 2023-05-10 by `jwhite510`; rebased/force-pushed through 2024; marked ready for review 2024-09-10; last push 2024-10-28; closed unmerged 2025-07-12                                   |
| Superseded by     | `diffopt+=inline:{simple,char,word}` — `vim-patch:9.1.1243`, Neovim commit `2331c52affe64070ad59c0ef63ddcc8f7ca41781` (2025-03-28), Vim patch by Yee Cheng Chin, ported by `zeertzjq`                 |
| Partly merged as  | The comparison grouping optimization, split into PR [#23611][pr-grouping] and merged as `0381f5af5bdc504f92be35dd89ac1328096eb8e6` (2023-06-07)                                                       |
| Surveyed revision | PR head `7cf9e3dea2791b865cbab3dc9288ebe66fcfb445` (2024-10-28); merge-base `3b58d93aaeaea363ff1066fc791f5d8af1946218` (2024-08-03); mainline `387bd0fbe78756b030884805e61754cee1be4bb4` (2026-08-04) |

## Overview

### What it solves

Neovim inherited Vim's `diff_find_change()`: for a changed line it scans inward from both ends,
finds the first and last differing byte, and highlights everything between them as `DiffText`. A
line with two small separated edits gets one wide highlight covering the unchanged middle; a change
spanning several lines gets a crude first..last range per line, computed against whichever line
happens to sit at the same offset in the other buffer. PR #23569 replaces that scalar range with a
per-byte highlight decision derived from a token-level alignment computed **over the whole diff
block at once**, so multiple disjoint regions can be highlighted on one line and a change that
migrates across a line boundary still resolves to precise columns. The author's stated
justification, from the PR discussion, is competitive parity: multiple highlighted regions per line
is "an important diff feature that many other text editors have (emacs, vs code, jetbrains)", and
the change must live in `diff.c` because the existing `diff_find_change` algorithm structurally
cannot express it ([#23569][pr], 2024-09-11).

### Design philosophy

The bet is _one algorithm, three granularities_. Neovim already shipped `linematch` — an
N-dimensional dynamic program that finds the optimal alignment of lines across up to 8 diffed
buffers, scoring each candidate pairing by matching character count. #23569's insight is that the
tensor DP is not really about lines: it aligns **sequences of opaque tokens**, and a token can just
as well be a UTF-8 character or an `iskeyword`-class run. So rather than adding a second diff
engine, the PR threads a `charmatch` flag plus two token-offset arrays through the same
`linematch_nbuffers()` entry point. From the head commit's own docstring in `src/nvim/diff.c`:

> Run the alignment algorithm for either line alignment (linematch) or character / word
> highlighting. This function generates the inputs which will be passed to the alignment
> algorithm, and also checks if the token count has been exceeded

The second principle is that whitespace handling belongs to the caller, not the inner loop. The PR
deletes `matching_chars_iwhite()` — which allocated two stripped copies of every line pair inside
the DP's innermost comparison — and hoists stripping into a pre-pass that also records an index map
for reconstructing byte columns afterwards, explicitly discharging a standing `TODO` in
`src/nvim/linematch.c`:

> `// TODO(lewis6991): handle whitespace ignoring higher up in the stack`

Mainline's eventual answer inverts both principles: a separate engine, and whitespace semantics
pushed back down into tokenization. The commit message of `2331c52aff` states the problem in terms
almost identical to the PR's:

> Diff mode's inline highlighting is lackluster. It only performs a line-by-line comparison, and
> calculates a single shortest range within a line that could encompass all the changes. In lines
> with multiple changes, or those that span multiple lines, this approach tends to end up
> highlighting much more than necessary.

## How it works

### 1. Diff computation & data model

`linematch_nbuffers(diff_blk, diff_len, ndiffs, &decisions, iwhite)` builds a tensor of
`prod(diff_len[i] + 1)` cells over `ndiffs ≤ 8` buffers. Each cell is relaxed from its predecessors
by `try_possible_paths()`, which enumerates the `2^ndiffs - 1` non-empty subsets of buffers that
could advance together; the score of a step is `count_n_matched_chars()`, the pairwise
longest-common-subsequence character count of the participating lines. The maximum-score path from
origin to the far corner is the alignment, emitted as an array of decision bitmasks.

#23569 changes the signature to
`linematch_nbuffers(diff_blk, diff_len, ndiffs, &decisions, bool charmatch, size_t **word_offset, size_t **word_offset_size)`.
When `charmatch` is set:

- `diff_len[i]` is no longer a line count but a **token** count, and `word_offset[i][t]` /
  `word_offset_size[i][t]` give each token's byte offset and length inside the block's flattened
  text. Advancing a buffer indexes the token table instead of calling `fastforward_buf_to_lnum()`.
- Scoring collapses from similarity to strict equality. A step scores `1` only if every
  participating buffer holds the byte-identical token (`compare(s1, l1, s2, l2)`); otherwise the
  path is pruned outright (`return; // not a possible path`). Only two moves are legal — skip one
  token, or advance all `ndiffs` together — enforced by `if (!(compared == ndiffs || compared == 1)) return;`.
  The DP therefore computes an N-way longest common subsequence over tokens rather than a fuzzy
  alignment.
- `'\n'` is itself a token and pairing across it is forbidden (`current_lines[i][0] == '\n'` prunes),
  but the token streams are **concatenated across every line of the block**, which is what makes the
  result cross-line: a word that moved from line 1 to line 3 still matches.

Tokenization happens in `generateAllignmentAlgorithmHelpers()` (spelling as in the source):
`WORDMATCH` opens a new token whenever `utf_class(c)` changes or at `'\n'`, `CHARMATCH` uses
`utfc_ptr2len()` so a multi-byte grapheme is one token. Under `iwhite`/`iwhiteall` the buffer is
compacted in place, whitespace is not a token at all, and `iwhite_index_offset[]` records the
displacement so results scatter back to original byte positions.

The result lands in two new fields on `diff_T` (`src/nvim/buffer_defs.h`):

```c
size_t n_charmatch;
int *charmatchp;  // values for charmatch
```

`charmatchp` is a flat `int` array with one slot per byte of the block's concatenated text across
**all** buffers, carrying `0` (unchanged), `1` (changed token), `2` (line has no counterpart —
render as added), `-1` (limit exceeded, not yet computed), `-2` (recomputation attempted and still
over limit). Indexing at draw time is by cumulative byte offset recomputed by `get_buffer_position()`,
which walks `ml_get_buf()` over every preceding line of every preceding buffer.

**Supersession — mainline `inline:char` / `inline:word`.** The design that shipped
(`diff_find_change_inline_diff()` in `src/nvim/diff.c` at `387bd0fbe7`) reuses the _file_ diff
machinery instead of the _line-alignment_ machinery. Per diff block, each buffer's lines are split
into char or word tokens and re-emitted as a synthetic newline-delimited memory file; the first
participating buffer's token file is then diffed against each other buffer's with
`diff_file_internal()` (xdiff), temporarily swapping out `curtab->tp_first_diff` and
`curtab->tp_diffbuf` so `diff_read()` can be reused verbatim at token granularity. A `linemap[]`
grow-array maps each synthetic token line back to `{lineoff, byte_start, num_bytes}`; hunks become
`diffline_change_T` records — genuine `[dc_start, dc_end)` byte ranges with per-buffer line offsets
— appended to `dp->df_changes` and read out through `diff_change_parse()`. Both designs are
per-block and cross-line; the differences are the engine (O(ND) xdiff versus a product-sized
tensor), the N-way property (mainline diffs each buffer against `file1_idx` pairwise, #23569 aligns
all `ndiffs` jointly), and the output shape (range list versus per-byte paint array).

### 2. Rendering & layout

No layout change whatsoever: same two `&diff` windows, same filler lines, same `DiffAdd`/`DiffChange`/
`DiffText` groups, no virtual text, no new highlight group. The entire rendering delta is a branch in
`win_line()` (`src/nvim/drawline.c`) that replaces the `change_start`/`change_end` span test with a
per-byte lookup:

```c
} else if ((size_t)(ptr - line) < diffchars_line_len
           && (hlresult[ptr - line] == 1 || hlresult[ptr - line] == -2)) {
  wlv.diff_hlf = HLF_TXD;
```

`hlresult[0] == 2` promotes the whole line to `HLF_ADD`; a `NULL` result means highlighting is
suspended (the block is mid-edit) and everything falls back to `HLF_CHD`. The identical branch is
duplicated into `f_diff_hlID()` in `src/nvim/eval/funcs.c` so the Vimscript `diff_hlID()` function
agrees with the screen. Mainline instead added a distinct highlight group `DiffTextAdd` (`HLF_TXA`,
`src/nvim/highlight_defs.h`) so colorschemes can distinguish text added within a line from text
modified in place — a user-visible capability #23569 has no equivalent for.

### 3. Intra-line & noise handling

This dimension is the whole PR. Three noise mechanisms are present:

1. **Multi-region output.** Because the alignment is a real LCS, unchanged islands between two edits
   on one line stay unhighlighted. The screen tests make this concrete: `abbcabbcdefghijklmnop`
   against three shorter lines highlights `{27:b}` … `{27:b}` … `{27:e}` … `{27:k}` as four separate
   spans (`test/functional/ui/linematch_spec.lua`), where the pre-existing algorithm would paint one
   run from the first difference to the last.
2. **Whitespace elision.** Under `chardiff` + `iwhiteall`, padding is not a token, so realignment
   churn vanishes from the alignment and the surviving highlights sit on real content — the test
   pair `ababcabcdabcde` / `abc abcd abcde abcdef` shifts from highlighting `{27:c }`/`{27:d }`
   (space included) to `{27:c}`/`{27:d}` alone.
3. **The comparison grouping optimization** — the fragmentation answer, and the part that actually
   merged. `try_possible_paths()` retains _every_ predecessor achieving the maximum score
   (`df_decision[]`, `df_choice[]`, `df_path_n`) rather than one, turning the DP result into a DAG of
   equally-optimal alignments. `test_charmatch_paths()` then walks that DAG with memoization and
   selects the path with the fewest _decision changes_ — the alignment with the fewest contiguous
   groups among all optimal ones. Fragmentation is thus resolved inside the optimization rather than
   patched afterwards.

Mainline's `inline:` reaches the same visual goal with post-hoc heuristics, and needed two rounds of
them. `diff_refine_inline_char_highlight()` merges adjacent token blocks separated by a gap of ≤ 3
tokens when `max_df_count >= gap * 4`, iterating up to 4 passes; its docstring is candid — "a naive
diff under existing algorithms tends to create a messy output with lots of small gaps … These are
done by heuristics and can be further tuned." Word mode needed its own pass a year later
(`a5b8cf145d…`, 2026-03-17, `vim-patch:9.2.0174`), merging word blocks separated by ≤
`diff_word_gap = 5` bytes of non-word characters when `total_change_bytes >= gap_size * 2`,
explicitly "to closely match GitHub's own diff display". Against that, mainline's tokenization
fidelity is clearly better: word class comes from the first buffer's `b_chartab` (real `iskeyword`,
class 2 only, so emoji and CJK are individual words), `DIFF_IWHITE` folds a whitespace run into a
single token instead of deleting it, `DIFF_IWHITEEOL` rewinds the token arrays to trim trailing
whitespace, and `DIFF_ICASE` is handled by manual `utf_fold()` because xdiff cannot ignore case.
#23569 supports only `iwhite`/`iwhiteall` and has no `icase` handling at all.

### 4. Navigation, folding & scale

Navigation and folding are untouched — `]c`/`[c`, `dp`/`do`, and diff folds behave exactly as before;
this is a highlighting change with no motion or structural surface. Scale is where the design
strains, and the PR is visibly organized around that fact.

The tensor's memory is `prod(diff_len[i] + 1)`. With lines as tokens and `linematch:40` capping the
block, that is bounded. With characters as tokens it becomes quadratic in block _bytes_ for two
buffers and higher-degree for three or four, so the PR introduces explicit budgets — `chardiff:{N}`
and `worddiff:{N}`, where `N` is a token count, not a line count — and a three-stage degradation
ladder in `get_charmatch_highlightresult()`: run over the whole block; if the token count exceeds
the budget, fill `charmatchp` with `-1` and, when a line is actually drawn, retry on a synthetic
single-line `diff_T`; if that also exceeds the budget, write `-2` and let `drawline.c` fall back to
the classic first..last span. The screen tests exercise all three rungs at `chardiff:100`,
`chardiff:30`, and `chardiff:10`. Cache invalidation is a byte-count comparison
(`dp->n_charmatch != charcount`) which returns `NULL` and suspends highlighting while a line is being
edited, until the diff is recomputed.

Mainline needs none of this: xdiff is O(ND) on the token stream, so `inline:char` carries no size
knob, and results are cached per block behind `dp->has_changes` with a linear scan over
`df_changes` at draw time (justified in-source because "there should usually be a limited number of
inline changes per diff block"). That performance asymmetry is the strongest structural argument
against #23569's approach, and it is the reason mainline could ship `inline:char` **on by default** —
the current `'diffopt'` default is `internal,filler,closeoff,indent-heuristic,inline:char,linematch:40`.

### 5. VCS & review integration

None, in either design. This is core diff-mode rendering; there is no git awareness, no hunk
staging, no review surface. The absence is a finding rather than an omission, because it is exactly
the ground on which the PR was declined — from the discussion, `lewis6991` (2024-09-10):

> The enhancements here cannot be leveraged by other systems and only benefits the built in diff
> viewer, which lowers the value proposition further

The PR does touch `src/nvim/lua/xdiff.c` (the `vim.diff()` linematch path), but only to hoist the
same `iwhite` stripping; the call site passes `0, NULL, NULL`, so charmatch is never reachable from
Lua. Mainline's design is no more exposed to Lua, but its `diffline_change_T` range list is at least
a shape an API could return, whereas a per-byte paint array indexed by a cumulative offset over all
buffers is not.

### 6. Architecture & reuse

`linematch.c` stays a self-contained module over `(const char **diff_blk, const int *diff_len, size_t ndiffs)`,
and #23569 preserves that shape — the genuinely reusable idea is that the module is parametric in
what a "token" is, so one N-way alignment kernel serves lines, words, and characters. Everything
downstream is tightly coupled: `charmatchp` is freed at four call sites (`diff_alloc_new`,
`diff_free`, `process_hunk`, `diff_clear`), indexing requires re-walking the buffer at draw time,
and `diff_find_change()` grows three out-parameters (`int **hlresult`, `bool *diffchars_lim_exceeded`,
`size_t *diffchars_line_len`) threaded into both `drawline.c` and `funcs.c` with the branch
duplicated in each. Mainline restructured that seam instead of widening it —
`diff_find_change(win_T *, linenr_T, diffline_T *)` returns one struct and consumers call
`diff_change_parse()` — which is what let `DiffTextAdd`, the word gap-merge pass, and `inline:none`
land cheaply afterwards. The reuse verdict is asymmetric: #23569's algorithmic core is more
reusable, its plumbing much less so.

## Strengths

- Genuine multi-region, cross-line, column-precise intra-line highlighting, arriving roughly two
  years before mainline had it — the PR predates `vim-patch:9.1.1243` by 22 months.
- One algorithm for line, word, and character alignment: no second diff engine, no second set of
  tuning constants, no divergence between how lines and tokens are scored.
- Native N-way alignment. The tensor jointly aligns up to 8 buffers, so a 3- or 4-way diff gets a
  single consistent token alignment rather than a fan of pairwise diffs against buffer 0.
- The grouping optimization is a principled fragmentation fix — minimize the number of contiguous
  groups _among the optimal alignments_ — rather than a post-hoc gap-merge with magic thresholds. It
  was strong enough to be split out and merged on its own ([#23611][pr-grouping]).
- Whitespace handling hoisted out of the DP's innermost loop, removing two `xmalloc`/`xfree` pairs
  per line comparison and closing a standing `TODO`; degradation (block → single line → classic
  span) is explicit and pinned by screen tests at each rung.

## Weaknesses

- Cost scales as the product of token counts. Character granularity turns a bounded line-count
  tensor into a byte-count tensor, forcing user-visible budgets (`chardiff:{N}`, `worddiff:{N}`)
  that no user can calibrate meaningfully and that make highlighting silently non-deterministic in
  detail as blocks grow.
- Strict token equality discards linematch's fuzzy scoring, so the character-level pass cannot
  express "these tokens are similar" — a `\n` boundary prunes rather than penalizes.
- The output contract is a per-byte paint array whose index must be recomputed by walking the buffer
  (`get_buffer_position()`), with state sentinels (`-1`/`-2`) mixed into the same `int` array as the
  highlight values; a range list would be smaller, cacheable, and API-shaped.
- Incomplete option coverage: `iwhite`/`iwhiteall` only — no `iwhiteeol`, no `icase`, no interaction
  with `indent-heuristic`; word class is `utf_class()` rather than the buffer's `iskeyword`.
- No documentation. Nothing in `runtime/doc/`, so `chardiff:`/`worddiff:` exist only in the PR body.
  There is also an unguarded fixed 256-byte token staging buffer in the DP's hot path.
- Reviewer-facing complexity: the diff adds 425 lines to `diff.c`, a file the maintainers were
  already reluctant to grow, and the added logic is inseparable from the drawing loop.

## Key design decisions and trade-offs

| Decision                                                                      | Rationale                                                                                               | Trade-off                                                                                                                         |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Re-parameterize linematch's tensor DP over tokens instead of adding an engine | One scoring notion for lines and characters; no new dependency; the N-way property comes free           | Product-sized memory in token counts; needs budgets and a degradation ladder that xdiff would not                                 |
| Strict token equality instead of `matching_chars` similarity                  | An LCS is the right object at character granularity; enables aggressive path pruning                    | Loses linematch's fuzzy scoring; `'\n'` is a hard barrier rather than a cost                                                      |
| Store results as a per-byte `int` array on `diff_T`                           | O(1) lookup from the innermost `win_line()` loop, no per-line search                                    | Memory proportional to block bytes × buffers; index recomputed by walking `ml_get_buf()`; not exposable as an API                 |
| Cross-line token stream over the whole block                                  | A change that migrates across a line boundary resolves to precise columns                               | Whole block must be re-run when any line's byte count changes; highlighting suspends mid-edit                                     |
| Grouping optimization = fewest decision changes among max-score paths         | Fragmentation solved inside the optimum, no tuned thresholds                                            | Requires retaining all optimal predecessors (a DAG plus a memoized second pass) instead of one back-pointer                       |
| Hoist `iwhite` stripping out of the DP inner loop                             | Removes two allocations per line comparison; discharges the in-source `TODO`                            | Callers must maintain an index-offset map to scatter results back to original byte columns                                        |
| Budget by token count (`chardiff:100`) with per-line retry                    | Bounds worst-case latency while keeping detail on small blocks                                          | The number is uninterpretable to users; the same file yields different detail at different block sizes                            |
| _(mainline)_ Re-run xdiff over a synthetic token mmfile per block             | O(ND); inherits `diffopt` algorithm, `icase`, all `iwhite` variants; reuses `diff_read()` unchanged     | Pairwise against buffer 0 only — no joint N-way alignment; needs post-hoc gap-merge heuristics for both char and word granularity |
| _(mainline)_ `diffline_change_T` range list + `diff_change_parse()`           | Compact, cacheable, one consumer-facing accessor; made `DiffTextAdd` and later refinements cheap to add | Linear scan per drawn line; a real refactor of the `diff_find_change()` seam rather than a local change                           |

The reason none of the left-hand column shipped is not primarily technical. From the PR discussion,
`lewis6991` (2024-09-10) declined stewardship — "I don't have enough time to review this PR, nor do I
really want to support it. Unlike the line match PR, I don't think the value proposition is strong
enough to offset the maintenance burden of the complexity added to the C code" — and suggested
routing future diff work into xdiff instead, which is precisely where `inline:` later landed.
`justinmk` gave conditional support on 2024-09-19 ("so far jwhite510 has been a reliable owner of
this code, and if that continues, then this is worth having") contingent on extracting inline blocks
into named functions and adding docstrings; the final six commits on the branch
(`0fab691e0a`…`4371fc4d28`, September 2024) are exactly that refactor. It was closed on 2025-07-12
once the Vim-derived `inline:` feature had been in mainline for three months, with justinmk noting
that upstream convergence lowered the risk. Note that the branch's commit dates (2024-08-03 onward)
reflect force-pushed rebases, not the authoring timeline, which begins 2023-05-10.

## Sources

- Local checkout of [neovim/neovim][nvim], branch `pr-23569` @ `7cf9e3dea2791b865cbab3dc9288ebe66fcfb445`,
  diffed against merge-base `3b58d93aaeaea363ff1066fc791f5d8af1946218` — primary; key files:
  `src/nvim/diff.c` (`run_alignment_algorithm`, `generateAllignmentAlgorithmHelpers`,
  `get_charmatch_highlightresult`, `get_buffer_position`), `src/nvim/linematch.c`
  (`try_possible_paths`, `compare`, `test_charmatch_paths`), `src/nvim/buffer_defs.h`,
  `src/nvim/drawline.c`, `src/nvim/eval/funcs.c`, `src/nvim/lua/xdiff.c`,
  `test/functional/ui/linematch_spec.lua`
- Mainline `387bd0fbe78756b030884805e61754cee1be4bb4` — `src/nvim/diff.c`
  (`diff_find_change_inline_diff`, `diff_refine_inline_char_highlight`,
  `diff_refine_inline_word_highlight`, `diff_change_parse`), `src/nvim/buffer_defs.h`
  (`diffline_change_T`, `diffline_T`), `src/nvim/options.lua` (`'diffopt'` default),
  `runtime/doc/options.txt` (`inline:{text}`), `runtime/doc/diff.txt` (`view-diffs`, `hl-DiffTextAdd`)
- [PR #23569 discussion][pr] — the only source for stewardship, review, and closure rationale; all
  quotes attributed above are from that thread. [PR #23611][pr-grouping] / commit
  [`0381f5af5b`][grouping] carry the merged grouping optimization
- Commit [`2331c52aff`][inline] (`vim-patch:9.1.1243`, [PR #33086][pr-inline]), porting Vim commit
  [`9943d4790e`][vim-inline] by Yee Cheng Chin; commit [`a5b8cf145d`][word-gap]
  (`vim-patch:9.2.0174`) adds the later `inline:word` gap-merge pass

<!-- References -->

[nvim]: https://github.com/neovim/neovim
[pr]: https://github.com/neovim/neovim/pull/23569
[pr-grouping]: https://github.com/neovim/neovim/pull/23611
[pr-inline]: https://github.com/neovim/neovim/pull/33086
[grouping]: https://github.com/neovim/neovim/commit/0381f5af5bdc504f92be35dd89ac1328096eb8e6
[inline]: https://github.com/neovim/neovim/commit/2331c52affe64070ad59c0ef63ddcc8f7ca41781
[word-gap]: https://github.com/neovim/neovim/commit/a5b8cf145d1f46428f2eaa5fec89d41f5c9f87f7
[vim-inline]: https://github.com/vim/vim/commit/9943d4790e42721a6777da9e12637aa595ba4965
