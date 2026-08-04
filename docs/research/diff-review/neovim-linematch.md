# Neovim linematch (C, Neovim core)

A ~400-line post-processing pass that takes an already-computed xdiff block and re-derives
an optimal line-to-line pairing across 2–8 buffers by maximizing character-LCS similarity —
turning vimdiff's positional "N lines vs M lines" blobs into aligned sub-blocks with filler
lines in between.

| Field             | Value                                                                                                                                                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C (C99; `src/nvim/linematch.c` is 404 lines at the surveyed master revision, 377 as merged)                                                                                                                                                        |
| License           | Apache-2.0 (`LICENSE.txt`; `linematch.c` is Neovim-original, not Vim-licensed)                                                                                                                                                                     |
| Repository        | <https://github.com/neovim/neovim> — PR <https://github.com/neovim/neovim/pull/14537>                                                                                                                                                              |
| Documentation     | `runtime/doc/options.txt` (`'diffopt'` → `linematch:{n}`), `runtime/doc/lua.txt` (`vim.diff()` `linematch` field). Absent from `runtime/doc/diff.txt` — zero occurrences                                                                           |
| Category          | editor diff — alignment/pairing algorithm                                                                                                                                                                                                          |
| First appeared    | PR #14537 opened May 2021 (earliest author date on the branch: 2021-05-20); squash-merged 2022-11-04 as `04fbb1de4488852c3ba332898b17180500f8984e`; shipped in Neovim 0.9.0 (2023-04-07); on by default (`linematch:40`) since 0.11.0 (2025-03-26) |
| Surveyed revision | PR head `d7425b27fc4bb0281e923460fc82dab254284e9d` (authored 2021-05-20, committed 2022-11-01) and `origin/master` `387bd0fbe78756b030884805e61754cee1be4bb4` (2026-08-04)                                                                         |

## Overview

### What it solves

Vanilla `xdiff` reports a change as a pair of line _ranges_ — "lines 5–8 here, lines 5–6
there" — and vimdiff renders exactly that: the ranges stack up positionally, the shorter side
gets filler rows appended at its bottom, and every line is painted `DiffChange`. When a hunk
mixes a genuine modification with an insertion, the modified line no longer sits opposite its
counterpart and the reader must re-pair by eye. The `'diffopt'` entry states the goal in one
sentence (`runtime/doc/options.txt`):

> linematch:{n} Align and mark changes between the most
> similar lines between the buffers.

The canonical demonstration is the comment-prefix case in
`test/functional/ui/linematch_spec.lua`: a file whose lines are `// abc d`, `// d`, `// d`
against one that begins with a blank line and continues `abc d`, `d`. Without linematch the
whole thing is one undifferentiated blob; with it, `abc d` pairs with `// abc d`, `d` pairs
with `// d`, the leading blank and the trailing `// d` become add/delete rows opposite filler
lines, and `DiffText` marks only the `// ` prefixes.

The second motivation is three-way merge display. `linematch` generalizes to `ndiffs`
buffers, and the spec's flagship fixture is a conflict-marker file (`<<<<<<< HEAD` … `=======`
… `>>>>>>> branch1`) diffed against the two sides it was produced from — the `AAA` and `BBB`
runs align with their originating buffers instead of smearing across the whole conflict.

### Design philosophy

The algorithm is presented in the source as a geometry problem rather than a heuristic
pipeline. From the block comment above `linematch_nbuffers` in `src/nvim/linematch.c`:

> The algorithm constructs a 3d tensor to compare a diff between 3 buffers. […] A path is
> constructed by moving from one edge of the cube/3d tensor to the opposite edge. Motions
> from one cell of the cube to the next represent decisions. […] The optimal path has the
> highest score. The score is calculated as the summation of the total characters matching
> between all of the lines which were compared.

Three commitments follow. **Optimality over heuristics**: no sliding, no boundary scoring, no
"skip short lines" rule — the DP maximizes one global objective, and the price of that
guarantee is a hard line-count cap. **Generality over the 2-file case**: `ndiffs` is a runtime
parameter up to `LN_MAX_BUFS` (8, matching `DB_COUNT` in `src/nvim/buffer_defs.h`) and each
cell's decision is an arbitrary bitmask over buffers, not the three moves of a 2-D edit graph.
**Post-processing, not replacement**: linematch never computes a diff, it only re-partitions
xdiff's block boundaries, so every other `'diffopt'` knob keeps working unchanged.

## How it works

### 1. Diff computation & data model

Nothing here computes a diff. `xdiff` produces Neovim's `diff_T` linked list, each node
holding parallel `df_lnum[DB_COUNT]`/`df_count[DB_COUNT]` arrays — one start line and count
per diffed buffer. `run_linematch_algorithm` (`src/nvim/diff.c`) serializes each buffer's
slice of one block into an `mmfile_t` via `diff_write_buffer`, collects the per-buffer line
counts into `diff_length[]`, and calls the single entry point:

```c
size_t linematch_nbuffers(const mmfile_t **diff_blk, const int *diff_len, const size_t ndiffs,
                          int **decisions, bool iwhite);
```

The DP tensor is a flat `xmalloc`'d array of `∏(diff_len[k] + 1)` `diffcmppath_T` cells,
addressed by `unwrap_indexes()` (row-major mixed-radix). `populate_tensor` recurses over the
`ndiffs` axes; at each cell, `try_possible_paths` enumerates every non-empty subset of the
axes with a nonzero coordinate — a bitmask `choice`, `2^ndiffs - 1` of them at most — and
scores each as "consume one line from exactly these buffers", i.e.
`score(cell − choice) + count_n_matched_chars(lines named by choice)`.

`count_n_matched_chars` sums `matching_chars` over all pairs in the subset, then normalizes —
`if (matched >= 2) { matched_chars *= 2; matched_chars /= matched; }` — to "prioritize a match
of 3 (or more lines) equally to a match of 2 lines", so a 3-buffer agreement is not
automatically worth 3× a 2-buffer one. `matching_chars` itself is a plain character-level LCS
length over a rolling two-row matrix, capped at `MATCH_CHAR_MAX_LEN` (800) characters per
line. Its docstring gives the semantics exactly:

> matching_chars("abcdefg", "gfedcba") -> 1 // all characters in common, but only at most 1
> in sequence

There is **no word or token boundary awareness** — the scoring alphabet is bytes — and no
length normalization: the score is a raw character count, so long lines both attract pairings
and dominate a block's total score.

Backtracking is where the shipped version diverges most from the merged PR. Equal-scoring
predecessors are all retained (`df_decision[]`/`df_choice[]`, up to `LN_DECISION_MAX` = 255
per cell), and `test_charmatch_paths` then walks that DAG choosing, among optimal paths, the
one with the fewest _changes of decision_ — memoized in `df_choice_mem[lastdecision]`. This
is the "grouping optimization" (`0381f5af5bdc504f92be35dd89ac1328096eb8e6`, 2023-06-07): the
same optimal score can be realized by an interleaved pairing or a contiguous one, and
contiguous produces fewer, larger visual blocks. Two `linematch_spec.lua` fixtures named
"a diff that would result in multiple groups before grouping optimization" pin the behaviour.

The output is the decision array, reversed into forward order: one bitmask per emitted
display row, where bit `k` means "buffer `k` advances by one line here". That array is the
whole contract — it is renderer-agnostic and carries no highlighting, no line numbers, and no
notion of add/change/delete.

### 2. Rendering & layout

linematch draws nothing. `apply_linematch_results` (`src/nvim/diff.c`) converts the decision
array back into the existing data structure: it walks the decisions and starts a **new
adjacent `diff_T` block** whenever `decisions[i - 1] != decisions[i]`, incrementing
`df_count[]` per set bit. One fat block becomes a chain of small blocks marked
`is_linematched`.

Everything visual then falls out of code that already existed:

- **Filler lines** are `get_max_diff_length(dp) - dp->df_count[idx]` per sub-block, summed
  across the chain of adjacent blocks in `diff_check_with_linestatus`. A sub-block whose
  decision omits buffer `k` has `df_count[k] == 0`, so buffer `k` gets one filler row there —
  alignment is a side effect of block splitting, not a separate mechanism.
- **CHANGED vs ADDED** classification is likewise unchanged: within a sub-block, if some
  other buffer has `df_count == 0` the line is inserted/deleted; if counts match and the text
  differs, it is changed (`linestatus = -1`).

The cost of that reuse is that "adjacent blocks" became a concept the rest of `diff.c` had to
learn: `find_top_diff_block` and `calculate_topfill_and_topline` walk a chain of touching
blocks when computing `scrollbind` toplines and topfill, and the master comment now
generalizes it — "'Adjacency' means a chain of diff blocks that are directly touching each
other, allowed by linematch and diff anchors."

Invocation is lazy and view-driven: `diff_check_with_linestatus` runs the algorithm the first
time a line's filler count is queried, and master additionally restricts that to on-screen
lines — "Don't run linematch when lnum is offscreen. Useful for scrollbind calculations which
need to count all the filler lines above the screen." The `is_linematched` flag memoizes per
block; `diff_alloc_new` clears it on newly created blocks.

### 3. Intra-line & noise handling

Scope is line pairing only, and that boundary held for two and a half years. Until Vim's
`inline:` feature was ported in (`2331c52affe64070ad59c0ef63ddcc8f7ca41781`, 2025-03-28,
vim-patch 9.1.1243), intra-line highlighting remained the crude
first-differing-char..last-differing-char span; the patch's own problem statement is blunt
about it — "It only performs a line-by-line comparison, and calculates a single shortest
range within a line that could encompass all the changes." `'diffopt'` now carries
`inline:none|simple|char|word` and defaults to `inline:char`, but that is a separate xdiff
pass over the block text, not part of linematch.

Whitespace is the one noise policy linematch itself implements, and only in the scorer:
`run_linematch_algorithm` folds `DIFF_IWHITE | DIFF_IWHITEALL` into a single `iwhite` bool,
and `matching_chars_iwhite` deletes every space and tab from both lines (into a stack buffer)
before running the LCS. `icase`, `iblank`, `iwhiteeol`, and `indent-heuristic` do **not**
reach the scorer — a source `TODO(lewis6991)` in `count_n_matched_chars` proposes to "handle
whitespace ignoring higher up in the stack". A dedicated `linematch_spec.lua` fixture pairs a
re-indented C loop with its commented-out counterpart under `iwhiteall`.

Indirectly, the raw-LCS score _is_ a noise-tolerance mechanism: a re-indented, comment-prefixed
or re-padded line retains most of its characters and still wins the pairing. But nothing is
ever _classified_ as noise — linematch decides only who lines up with whom, every paired line
still renders as a full `DiffChange` row, and there is no move detection, formatting-only hunk
suppression, or structural equivalence.

### 4. Navigation, folding & scale

No navigation surface at all: `]c`/`[c`, diff folding, and `do`/`dp` are unaware of linematch
except that `diffget`/`diffput` now operate on the finer sub-blocks it created — a large share
of `linematch_spec.lua` is exactly that.

Scale is handled by refusing to run. `diff_linematch()` sums `df_count[]` across all diffed
buffers and returns false above `linematch_lines` (`{n}` from `linematch:{n}`, default 40):

> When the total number of lines in the diff hunk exceeds {n}, the lines will not be aligned
> because for very large diff hunks there will be a noticeable lag. A reasonable setting is
> "linematch:60", as this will enable alignment for a 2 buffer diff hunk of 30 lines each, or
> a 3 buffer diff hunk of 20 lines each.

The cap is doing heavy lifting on two axes. Time: the tensor has `∏(len_k + 1)` cells, each
evaluating up to `2^ndiffs - 1` subsets, each subset running pairwise LCS at O(800²) worst
case. Memory: `diffcmppath_T` embeds `df_choice_mem[256]`, `df_choice[255]`, and
`df_decision[255]` pointers — roughly 4 KiB per cell regardless of `ndiffs` — so a 3-buffer
block of 13 lines each already allocates on the order of 10 MiB. That worst-case sizing is the
direct price of the grouping optimization, which also forced the removal of the merged PR's
`(k == 0) space optimization` that had kept only two rows of the first axis resident; the
surviving block comment claiming "only two slices (along k and j axis) are stored in memory"
is now **stale** with respect to the code.

Other guards: `diff_linematch()` bails on a negative `df_count` ("for the rare case (bug?)…
this will try to allocate a negative amount of space and crash"); `diff_check_sanity` gates
the call (vim-patch 9.1.1027, `bd145a6c8398fb7a3fd037bc71c1bacaeba49584`); `MATCH_CHAR_MAX_LEN`
truncates long lines (regression test "doesn't crash with long lines"); and
`5a25dcc5a4c73f50902432e32335ab073950cceb` fixed filler computation for hunks past the limit.

### 5. VCS & review integration

None — linematch sits below any VCS layer and only ever sees two-to-eight in-memory buffers.
It reaches the outside world through one seam: `vim.diff()`'s `linematch` option
(`src/nvim/lua/xdiff.c`), documented as "Run linematch on the resulting hunks from xdiff.
When integer, only hunks upto this size in lines are run through linematch. Requires
`result_type = indices`, ignored otherwise." `get_linematch_results` calls the same
`linematch_nbuffers` and re-emits the decision array as a list of finer hunk tuples, so Lua
plugins (git signs, review UIs) get linematched hunk boundaries without touching diff mode.

The notable integration story is cross-project: **Vim adopted linematch from Neovim**, not the
reverse. Vim patch 9.1.1009 ("diff feature can be improved… include the linematch diff
alignment algorithm (Jonathon)", vim/vim#9661,
[`7c7a4e6d1ad50d5b25b42aa2d5a33a8d04a4cc8a`][vim-linematch]) landed in early 2025, and Neovim
then ported the follow-ups _back_ as vim-patches: option-value completion (9.1.1022), the
`{n} < 10` off-by-one (9.1.1072), the sanity check (9.1.1027), and the out-of-memory hardening
(9.1.1303, `d2d1b5e944b5888f3237d48e1a88aa6c8e156edc`) — of which only the `pow()` hoist out of
the initialization loop actually applied, since Neovim's `xmalloc` aborts rather than
returning `NULL`.

### 6. Architecture & reuse

`src/nvim/linematch.{c,h}` is close to a standalone module: its only includes are `xdiff.h`
(for `mmfile_t`), `nvim/memory.h` (`xmalloc`/`xfree`), `nvim/pos_defs.h` (`linenr_T`),
`nvim/macros_defs.h` (`MIN`), and the generated declarations header — no window, buffer,
option, or screen dependency. Two call sites consume it (`diff.c`, `lua/xdiff.c`), both
written against the same integer-bitmask output, which is the strongest evidence the
interface is genuinely renderer-neutral.

The merged-PR → master evolution is itself the reuse lesson. The PR represented lines as
NUL-terminated `const char *` navigated with `strchr`; that broke on buffers with embedded
NULs and was replaced wholesale by `mmfile_t` slices plus `memchr`
(`c65646c2474d22948c604168a68f6626a645d1d2`, "fix(diff): use mmfile_t in linematch", 2024-09-30),
which also removed the two `xmalloc`s per whitespace-insensitive comparison. The PR likewise
stored each cell's full decision path as a flat array copied on every improvement
(`update_path_flat`, an O(path) memcpy per relaxation); master keeps back-pointers and
reconstructs once at the end.

What transplants: the decision-bitmask output format; the mixed-radix flat tensor with
`unwrap_indexes`; the equal-score tie-break by minimum decision changes; the "cap the block
size, otherwise don't run" scale policy. What does not: the `xmalloc`-aborts memory
discipline, the generated-header build integration, and the ~4 KiB fixed-size cell.

## Strengths

- **Globally optimal pairing** within a block, with a stated objective function, rather than
  a stack of tuned heuristics — the result is explainable and testable, and
  `linematch_spec.lua` (1113 lines at master) pins it screen-by-screen.
- **N-buffer generality**: the same code path serves 2-way diffs and 3-way merge-conflict
  views, which is rare — most differs special-case the 2-file problem.
- **Zero rendering footprint**: by re-splitting `diff_T` blocks it inherits fillers,
  `DiffChange`/`DiffAdd` classification, `do`/`dp`, folding, and scrollbind for free, and it
  composes with the rest of `'diffopt'` (`algorithm:histogram`, `inline:char`) untouched.
- **Honest, lazy scale policy**: an explicit line cap with a documented rationale is
  deterministic where a timeout is not, and only blocks whose fillers are queried on screen
  pay the DP cost at all (memoized per block via `is_linematched`).
- **Proven portable**: adopted by Vim upstream (9.1.1009) and reachable from Lua through
  `vim.diff()`.

## Weaknesses

- **Byte-level scoring only, unnormalized.** No tokenization, no word boundaries, no
  identifier awareness — `matching_chars("abcdefg", "gfedcba") == 1` is documented behaviour,
  so reordered content scores like unrelated content — and a raw LCS count lets long lines
  both attract pairings and dominate a block's score.
- **Combinatorial cost forces a small cap.** The default `linematch:40` — counted as lines
  summed across _all_ buffers, so `linematch:60` means 30+30 or 20+20+20 — makes the
  improvement vanish exactly where diffs are hardest to read, with no windowed fallback.
- **~4 KiB per tensor cell.** `df_choice_mem[256]` + `df_choice[255]` + `df_decision[255]` is
  sized for 8 buffers unconditionally, so the 2-buffer common case over-allocates ~100×; the
  block comment still advertises the two-slice rolling tensor that grouping removed.
- **Alignment only, never classification.** Paired lines still render as fully changed; there
  is no "this hunk is formatting-only" verdict, no move detection, no structural pass.
- **Only `iwhite`/`iwhiteall` reach the scorer** — `icase` and `iblank` silently do not, an
  inconsistency the source's own `TODO` acknowledges.

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                                                                    | Trade-off                                                                                                             |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Post-process xdiff blocks instead of replacing the diff algorithm          | Keeps every existing `'diffopt'` knob, hunk boundary, and fold behaviour intact; the change is additive                      | Alignment quality is bounded by whatever block boundaries xdiff chose; a badly-sliced hunk cannot be re-cut           |
| Express the result as a per-row bitmask decision array                     | Renderer-neutral; both diff mode and `vim.diff()` consume it, and it maps mechanically to block splits                       | Loses the pairing's semantics — consumers must re-derive "changed vs added" from resulting counts                     |
| Generalize to `ndiffs` buffers via an N-dimensional tensor                 | One implementation serves 2-way diff and 3-way merge conflicts, the hardest alignment case                                   | Cell cost is `2^ndiffs` decisions and a fixed 255-slot cell; the 2-buffer case pays for the 8-buffer worst case       |
| Score by character LCS with no word/token model                            | Language-agnostic, dependency-free, and cheap enough to run `O(n·m)` times per block                                         | No word boundaries, no length normalization; near-identical short lines can lose to incidental long-line overlap      |
| Hard line-count cap (`linematch:{n}`, default 40) instead of a time budget | Deterministic, explainable, and cheap to check before allocating; "for very large diff hunks there will be a noticeable lag" | The feature silently disappears on the large hunks that need it most; no degraded/windowed mode                       |
| Run lazily from the filler-line query, on-screen lines only                | Pays the DP cost only for blocks the user actually looks at; scroll arithmetic doesn't trigger it                            | Alignment becomes a function of viewport state; requires an `is_linematched` memo flag and careful invalidation       |
| Break score ties by fewest decision changes (grouping optimization)        | Equal-scoring pairings differ hugely in readability; contiguous runs mean fewer, larger aligned blocks                       | Requires retaining every optimal predecessor and the whole tensor — killed the merged PR's two-row space optimization |
| Keep intra-line highlighting out of scope                                  | Line pairing is a separable problem with a clean interface; the crude span highlighter still worked                          | Users saw only half the readability win for ~2.5 years, until `inline:char`/`inline:word` (vim-patch 9.1.1243, 2025)  |

## Sources

- Neovim `origin/master` at `387bd0fbe78756b030884805e61754cee1be4bb4` (primary):
  `src/nvim/linematch.c`, `src/nvim/linematch.h`, `src/nvim/diff.c` (`diff_linematch`,
  `run_linematch_algorithm`, `apply_linematch_results`, `diff_check_with_linestatus`,
  `find_top_diff_block`, `calculate_topfill_and_topline`), `src/nvim/lua/xdiff.c`
  (`get_linematch_results`), `src/nvim/buffer_defs.h` (`DB_COUNT`)
- Neovim PR head at `d7425b27fc4bb0281e923460fc82dab254284e9d` (as reviewed):
  `src/nvim/linematch.c` (`update_path_flat`, `const char *` line navigation, the
  `(k == 0)` two-row space optimization), `src/nvim/diff.c` (`linematched_filler_lines`)
- Tests: `test/functional/ui/linematch_spec.lua` (3-buffer conflict fixtures, the `// `
  comment-prefix case, the `iwhiteall` re-indent case, the two grouping-optimization
  fixtures, the `regressions` block)
- Documentation: `runtime/doc/options.txt` (`'diffopt'` → `linematch:{n}`, `inline:{text}`),
  `runtime/doc/lua.txt` (`vim.diff()` `{linematch}`), `runtime/doc/news.txt`
- History: squash-merge [#14537][pr] `04fbb1de4488852c3ba332898b17180500f8984e` (2022-11-04);
  `0381f5af5bdc504f92be35dd89ac1328096eb8e6` grouping; `5a25dcc5a4c73f50902432e32335ab073950cceb`
  filler past the cap; `c65646c2474d22948c604168a68f6626a645d1d2` `mmfile_t` migration;
  `6db830e40e92dd61cd62d3e0bb5296e8b600cc18` default-on;
  `2331c52affe64070ad59c0ef63ddcc8f7ca41781` `inline:` highlighting; Vim's own adoption in
  patch 9.1.1009, [`7c7a4e6d1ad50d5b25b42aa2d5a33a8d04a4cc8a`][vim-linematch] (vim/vim#9661)

<!-- References -->

[pr]: https://github.com/neovim/neovim/pull/14537
[vim-linematch]: https://github.com/vim/vim/commit/7c7a4e6d1ad50d5b25b42aa2d5a33a8d04a4cc8a
