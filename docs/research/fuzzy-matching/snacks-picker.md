# snacks.picker (Lua)

folke's pure-Lua picker inside snacks.nvim — the proof that picker
_architecture_ (entropy-ordered evaluation, budgeted coroutines, a bounded
top-K heap, ordered rematch) matters more than matcher micro-performance: it
stays interactive on large corpora with a greedy scorer and no native code.

|                   |                                                                        |
| ----------------- | ---------------------------------------------------------------------- |
| Language          | Lua (Neovim; libuv event loop)                                         |
| License           | Apache-2.0                                                             |
| Repository        | [folke/snacks.nvim][snacks-repo]                                       |
| Surveyed revision | [`fe7cfe98`][snacks-matcher] (all file/line citations pin this commit) |
| Category          | Picker framework (finder + matcher + list + preview + actions)         |
| Algorithm class   | Greedy multi-start forward scan, [fzf]-constant streaming scorer       |

## Overview

### What it solves

A batteries-included picker for Neovim with no binary dependency: the
matcher, finder, list, preview and action layers are all Lua, cooperating on
the editor's single thread via budgeted coroutines. Every architectural
problem a native picker has — streaming items, incremental rematch,
cancellation, bounded sorting — appears here in its clearest form.

### Design philosophy

Prioritize what the user is looking at. The rematch pass is deliberately
ordered ([`matcher.lua:159-206`][snacks-matcher]): (1) items currently in
the visible top-K, (2) items that matched last generation, (3) everything
else — so the visible list is correct within the first few milliseconds even
when the full pass takes a second. Ordering as a correctness feature, not an
optimization.

## Algorithm & scoring model

Scoring is an explicit port of [fzf]'s `algo.go` with the constants verbatim
([`score.lua:19-28`][snacks-score]): `SCORE_MATCH=16`, `SCORE_GAP_START=-3`,
`SCORE_GAP_EXTENSION=-1`, `BONUS_BOUNDARY=8`, `BONUS_NONWORD=8`,
`BONUS_CAMEL_123=7`, `BONUS_CONSECUTIVE=4`, `BONUS_FIRST_CHAR_MULTIPLIER=2`,
plus a snacks-specific `BONUS_NO_PATH_SEP=6`; boundary-white 10 and
boundary-delimiter 9 as in fzf (both collapse to 8 under `history_bonus`).
Char classes are a 256-entry byte table; the prev×curr bonus a precomputed
7×7 matrix; scoring is _streaming_ (`init(str, first)` then `update(pos)`
per matched position) so the matcher scores as it scans.

But it is **not** fzf's DP: `fuzzy_find` is a greedy left-to-right
`string.find` chain, re-run from every successive occurrence of the first
pattern char, keeping the best-scoring run
([`matcher.lua:566-606`][snacks-matcher]) — O(occurrences × m), no
optimality guarantee, zero allocation, no matrix. Post-match bonuses
([`matcher.lua:360-388`][snacks-matcher]): `DEFAULT_SCORE = 1000` for the
empty pattern, a flat 1000 for satisfied `!` atoms, frecency
`score += (1 − 1/(1+frecency)) · 8` — **saturating, so frecency can never
outweigh more than one boundary bonus** — and a flat +10 cwd bonus.
AND-atom scores are summed.

## Prefiltering

The one idea worth stealing outright: **entropy-ordered atoms**. Each parsed
atom gets an estimate of how unlikely it is to match
([`matcher.lua:307-339`][snacks-matcher]): +10 non-fuzzy, +10 quoted, +10
more for word-boundary, +20 prefix, +20 suffix, plus
`min(#pattern, 20) + 2 · rare_chars`, doubled if case-sensitive with
uppercase. AND-terms are then sorted **descending** by entropy (most
selective first, so rejection happens on the first atom) and
OR-alternatives **ascending** (most likely first, so acceptance happens on
the first alternative) ([`matcher.lua:250-259`][snacks-matcher]). A
single-atom pattern is cached for a branch-free fast path.

## Memory strategy

Bounded by construction: a min-heap of capacity **1000** whose comparator is
the picker's sort function ([`list.lua:97-100`][snacks-list],
[`minheap.lua`][snacks-minheap]). `list:add` appends to a flat array, then
offers the item to the heap; **when the heap evicts, the evicted item is
written back into the new item's array slot** — total memory stays flat and
no item is lost. The first 1000 rows are exactly sorted; everything beyond
is arrival order. The dirty flag forces a re-render only when the new item
would land above the last visible row. GC is stopped for the whole find and
restarted on done ([`finder.lua:150-178`][snacks-finder]).

## SIMD & parallelism

None, structurally — Lua on the editor thread. Its budget discipline is the
substitute: `Async.yielder(ms)` checks the clock every 100th call and yields
past budget ([`async.lua:338-353`][snacks-async]); the matcher and finder
each get 1 ms inner budgets, and a global `uv.new_check()` executor
round-robins all active coroutines under `M.BUDGET = 10` ms per libuv tick.
The absence is the finding: 10 ms of cooperative work per frame is enough
for interactivity if the ordering (above) is right.

## Unicode & case handling

Lua byte-level matching; smart-case (`ignorecase = pattern:lower() ==
pattern`). No normalization, no grapheme handling — positions are byte
offsets handed to Neovim's highlighter.

## Incremental & streaming architecture

- **Streaming**: the finder appends to a flat array and pokes the matcher
  coroutine per item; the matcher drains to the current end, suspends if the
  finder still runs, loops until both finish.
- **Generation cancellation**: `self.tick` increments per pattern change;
  each item carries `match_tick`. Stale work discovers itself; nothing is
  interrupted mid-item.
- **Append fast path**: when the new pattern literally extends the old one
  and contains no operator chars, last generation's _non_-matches are
  stamped as processed and skipped entirely
  ([`matcher.lua:182-189, 223`][snacks-matcher]) — the same insight as
  [nucleo]'s `Update` status, derived independently.
- **Pattern syntax**: fzf-flavored (`!` inverse, `'exact`, `'word'`,
  `^prefix`, `suffix$`, `|` OR, `field:pattern`, and a `file:line:col`
  rewrite that stashes a cursor position).
- **Frecency** ([`frecency.lua`][snacks-frecency]): half-life 30 days, but
  stored as a **deadline timestamp** `t = now + ln(score)/λ` rather than a
  score — entries decay correctly with no rewrite pass, and pruning is
  "delete the smallest deadlines" (store cap 10,000). Unknown paths seed
  from buffer `lastused` or file mtime; directory frecency is the sum over
  children.
- **Render throttling**: progress updates deferred 10 ms, backing off to
  30 ms once top-K is full; input paused 60 ms after a find; the list paused
  up to 2 s on a refind to prevent flicker.

## Strengths

- Entropy-ordered atom evaluation — query planning for free.
- The bounded top-K heap with evicted-slot reuse.
- The three-phase rematch order (visible → previous matches → rest).
- The deadline-timestamp frecency encoding.
- Demonstrates the whole architecture works without threads: the
  `tick`-shaped budget contract is implementable over coroutines.

## Weaknesses

- Greedy multi-start scoring: no optimality guarantee; worst case
  O(occurrences × m) per candidate.
- Frecency's saturating ≤ 8-point cap means history barely moves ranking
  (deliberate, but the opposite of [fff]'s percentage boosts).
- Byte-offset positions mis-highlight multi-byte text.
- Single-threaded ceiling: a million-item corpus takes seconds of budgeted
  slices even though the UI stays live.

## Key design decisions and trade-offs

| Decision                              | Rationale                                        | Trade-off                                                |
| ------------------------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| Greedy scan + fzf's streaming bonuses | No matrix, no allocation, good-enough ranking    | Non-optimal matches on adversarial candidates            |
| Entropy-ordered AND/OR evaluation     | Reject on the most selective atom first          | Entropy is a heuristic; mis-estimates change little      |
| 1000-cap min-heap, evicted-slot reuse | Flat memory; exact ordering where the user looks | Rows beyond 1000 are arrival-ordered                     |
| Deadline-timestamp frecency           | No decay rewrite pass; pruning is a min scan     | Single scalar per path — cannot feed a combo-style boost |
| Cooperative 10 ms budget, no threads  | Zero synchronization; editor-thread safety       | Total throughput bounded by one core's budget slices     |

## Sources

- [`lua/snacks/picker/core/matcher.lua`][snacks-matcher] — atoms, entropy,
  fuzzy scan, rematch ordering, subset skip.
- [`lua/snacks/picker/core/score.lua`][snacks-score] — the fzf-constant
  streaming scorer.
- [`lua/snacks/picker/core/list.lua`][snacks-list] +
  [`…/util/minheap.lua`][snacks-minheap] — the bounded top-K.
- [`lua/snacks/picker/core/finder.lua`][snacks-finder] — streaming + GC
  stop/restart.
- [`lua/snacks/picker/core/frecency.lua`][snacks-frecency] — the deadline
  encoding.
- [`lua/snacks/picker/util/async.lua`][snacks-async] — the budget executor.

<!-- References -->

[snacks-repo]: https://github.com/folke/snacks.nvim
[snacks-matcher]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/core/matcher.lua
[snacks-score]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/core/score.lua
[snacks-list]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/core/list.lua
[snacks-minheap]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/util/minheap.lua
[snacks-finder]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/core/finder.lua
[snacks-frecency]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/core/frecency.lua
[snacks-async]: https://github.com/folke/snacks.nvim/blob/fe7cfe9800a182274d0f868a74b7263b8c0c020b/lua/snacks/picker/util/async.lua
[fzf]: ./fzf.md
[nucleo]: ./nucleo.md
[fff]: ./fff.md
