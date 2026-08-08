# frizbee (Rust)

The SIMD Smith-Waterman matcher — true local alignment with substitution, so
it is the only subject with native typo tolerance — and, via the `neo_frizbee`
fork, the actual matching kernel inside [fff]. Its history is as instructive
as its design: the inter-sequence SIMD everyone assumes it uses was tried and
**removed**.

|                   |                                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | Rust (stable intrinsics; formerly nightly `std::simd`)                                                                                     |
| License           | MIT                                                                                                                                        |
| Repository        | [saghen/frizbee][frizbee-repo]                                                                                                             |
| Surveyed revision | [`e5f0ee20`][frizbee-tree]; kernel details verified against the `neo_frizbee` 0.11.0 crate ([crates.io][neo-frizbee], the fork [fff] pins) |
| Category          | Matcher library (used by blink.cmp for completion; by fff for files)                                                                       |
| Algorithm class   | Smith-Waterman **with substitution** (true local alignment), SIMD                                                                          |

## Overview

### What it solves

Completion and file matching where the user's input may contain mistakes: a
transposed or wrong character should still rank, not eliminate. [fzf], [fzy]
and [nucleo] structurally cannot do this — their recurrences have no
substitution transition. frizbee adds it, keeps it affine, and vectorizes the
whole matrix computation.

### Design philosophy

Measure, then delete. From the README / `smith_waterman/mod.rs:49` on
abandoning its original design:

> Frizbee previously used inter-sequence parallelism (one needle, $LANES
> haystacks) but this performed only slightly better than sequential layout
> due to requiring interleaving the haystacks and bucketing based on haystack
> length, while performing worse in parallel due to the required bucketing.

The v0.6.0-era code had 17 length buckets (`FixedWidthBucket::<4, 8, …, 512>`)
each flushing at `LANES` items — do not build this; the author did, measured,
and removed it.

## How it works

**Intra-sequence, row-wise SIMD**: lanes are consecutive haystack _columns_
of one needle row, one needle × one haystack per call — not anti-diagonal,
not Farrar-striped. Diagonal and vertical dependencies are immediate; the
horizontal (left) dependency — what makes naive SW serial — is resolved
afterward by a `log2(LANES)`-stage shift-and-decay prefix max
(`propagate_horizontal_gaps`):

```rust
macro_rules! gap_step { ($shift:literal) => {
    shifted_row  = shift_right_padded::<$shift>(row, adjacent_row);
    shifted_mask = shift_right_padded::<$shift>(match_mask, adjacent_match_mask);
    gap_penalty  = gap_extend + (gap_open_extra & shifted_mask);
    row          = max(row, shifted_row.saturating_sub(gap_penalty));
    gap_extend   = gap_extend + gap_extend;   // doubles each stage: e, 2e, 4e, 8e…
}}
```

The `& shifted_mask` term keeps the gap affine — a gap opened right after a
match pays open+extend, otherwise extend only. The doubling of `gap_extend`
across stages is why the u8 score mode must bound
`64 * gap_extend + gap_open <= 255`.

## Algorithm & scoring model

Constants (`const.rs`, complete; all nine runtime-configurable via
`Config::scoring`):

```rust
pub const MATCH_SCORE: u16 = 12;
pub const MISMATCH_PENALTY: u16 = 6;
pub const GAP_OPEN_PENALTY: u16 = 5;
pub const GAP_EXTEND_PENALTY: u16 = 1;
pub const PREFIX_BONUS: u16 = 12;
pub const DELIMITER_BONUS: u16 = 4;
pub const CAPITALIZATION_BONUS: u16 = 4;
pub const MATCHING_CASE_BONUS: u16 = 4;
pub const EXACT_MATCH_BONUS: u16 = 8;
```

Structural differences from the [fzf] family: **no consecutive bonus**
(runs are rewarded emergently — a run pays no gap penalties while a scatter
pays `gap_open + n·gap_extend` per break), **no non-word bonus**, **no
first-char multiplier** (flat `PREFIX_BONUS` on haystack byte 0 only); it
adds a **matching-case bonus** and a post-hoc **exact-match bonus**
(suppressed whenever the prefilter trimmed the haystack). The delimiter
classification is _negative_: not a letter, not a digit, and ≤ 127.

The substitution transition is branch-free — the diagonal always pays the
mismatch penalty and gets it refunded (plus bonuses) on a match:

```rust
let match_score = splat(scoring.match_score.saturating_add(scoring.mismatch_penalty));
…
let diag = diag.add(match_mask.and(match_and_masked_bonuses));  // +18 on match
let diag = diag.subs(mismatch_penalty);                         // −6 always
```

A match nets +12, a mismatch −6, and the DP can walk _through_ a wrong
character. Only the **final needle row** feeds the score maximum, so a score
always means "whole needle consumed (modulo typos)".

**Typos are never scored — they are budgeted, before the DP.** The prefilter
contract: a candidate passes iff an ordered alignment exists after deleting
at most `max_typos` needle bytes (oracle, asserted by randomized tests:
`LCS(needle, haystack) + max_typos >= needle.len()`). Budgets 0/1/2 get
hand-written kernels; 3+ a generic multi-path variant; `max_typos: None`
disables the prefilter entirely. Keeping the budget out of the DP is what
makes `max_typos = 0` exactly as fast as the no-typo matchers.

> [!WARNING]
> On the score-only path (`match_list` — what [fff] uses) there is **no
> post-SW typo verification**: the prefilter is sound but incomplete, so
> items with more effective typos than the budget can survive with a low
> score. The indices path _does_ count typos during traceback and can
> reject — so `match_list` and `match_list_indices` do not return the same
> set. A port must decide this deliberately.

## Prefiltering

A greedy in-order subsequence scan, not a char-presence bitmask: per loaded
chunk, `occ = movemask(cmpeq(orig, chunk) | cmpeq(flipped, chunk))` (needle
bytes pre-splatted as case pairs), then scalar bit-twiddling advances the
needle cursor _within_ the chunk by clearing consumed low bits
(`clear_through_lowest(m, hit) = m & !(hit ^ (hit - 1))`) — a 32-byte
haystack costs 2 loads regardless of needle length. Returns a conservative
window `(matched, start, end)`: start = first occurrence of `needle[0]`,
end = _last_ occurrence of the last needle char. Typo variants run
`max_typos + 1` parallel greedy cursors (path _i_ = "has skipped _i_ needle
chars") over one shared chunk mask.

> [!WARNING]
> The 0-typo _Unicode_ path has a real false-negative bug: it reloads
> `needle_char` without reloading the chunk masks, misaligning the compare
> for mixed-width needles (e.g. `aé`). The typo variants are immune because
> they call the char-mask primitive fresh per char — do it that way
> uniformly.

## Memory strategy

Two retained matrices (scores + match masks) of
`(needle_len + 1) × (MAX_HAYSTACK_LEN.div_ceil(LANES) + 1)` vectors,
`MAX_HAYSTACK_LEN = 1024`, allocated once in `Kernel::new` — zero per-call
allocation, never re-zeroed (row 0 and column 0 are structurally zero and
never written). ~36 KiB for an 8-byte needle in u16/AVX2. Haystacks over
1024 bytes fall to `match_greedy`, a linear non-optimal scan — and on the
score path a greedy _rejection_ still emits `score == 0` rather than
filtering. The u8-vs-u16 score width is chosen per needle
(`18 * needle_len + 12 <= 255` ⟹ needle ≤ 13 bytes picks u8), doubling lane
count for short needles. Tail loads use a page-safe over-read (full register
past the slice end when it cannot cross a 4 KiB boundary) — the README warns
that disabling it (`safe_read`) costs ~40 % without AVX-512.

## SIMD & parallelism

| Backend | u16 LANES | u8 LANES | Dispatch requirement                         |
| ------- | --------- | -------- | -------------------------------------------- |
| AVX-512 | 32        | 64       | `avx512f + avx512bw` (+ `avx512vbmi` for u8) |
| AVX2    | 16        | 32       | `avx2`                                       |
| SSE4.1  | 8         | 16       | `sse4.1`                                     |
| NEON    | 8         | 16       | aarch64                                      |
| Scalar  | 8         | 16       | always                                       |

Dispatch is resolved once per `(needle, config)` into a 10-variant enum;
`#[target_feature]` sits at the dispatch boundary with `#[inline(always)]`
kernels behind it. The scalar backends implement the same `Backend` trait
over plain arrays, so **the SW kernel is literally the same source** — and
the crate carries parity tests between backends. That seam (scalar first,
SIMD behind a trait, outputs asserted identical) is the port-relevant
architecture. Parallelism is `std::thread::scope` with a work-stealing
`AtomicUsize` chunk counter (chunk = 2048 items), one full `matcher.clone()`
per thread; the sorted path radix-sorts per thread (2-pass LSD over the u16
score) then k-way merges — bit-identical to sequential.

## Unicode & case handling

Matches **UTF-8 bytes directly** — no transcode. One matrix row per needle
_codepoint_; continuation bytes are "transport lanes" carrying score without
charging a gap step. Deviations this buys: an ASCII needle pays
`gap_open + 4·gap_extend` to skip an emoji, and `a` does not match `á`
(no normalization — [fzf] matches those). Case folding is precomputed per
needle byte as an `(orig, flipped)` pair; the `|0x20` trick was measured at
~2 % and rejected in favor of the pair compare.

## Incremental & streaming architecture

None — frizbee is a pure matcher library (`match_list` over a slice); the
caller owns streaming, cancellation, and rematch policy. [fff] wraps it for
files; blink.cmp for completion.

## Benchmarks — read with care

Its own `BENCHMARKS.md` (Ryzen 9950X3D): Chromium corpus, 1.4 M paths,
needle `linux` — sequential 22.36 ms vs nucleo 90.53 ms (4.05×); the fzf
rows there are `std::thread::sleep` of a constant pasted from external
`--bench` runs. The advantage _grows_ with haystack length until the
1024-byte greedy cliff; at 3 typos frizbee is **slower than scalar nucleo**
(142 ms vs 90 ms); the 20–46× Unicode wins are an _architecture_ difference
(bytes vs UTF-32 transcode), not a SIMD difference. junegunn's correction of
its original 7×-slower-fzf claim is the [comparison]'s methodology anchor.

## Strengths

- The only subject with typo tolerance, and the clean split that makes it
  zero-cost when disabled.
- Genuine 4–5× SIMD win on ASCII with a portable log-shift formulation.
- Scalar/SIMD backend seam with parity tests.
- Byte-wise Unicode avoids the transcode bill entirely.
- Never-zeroed fixed-stride matrices; per-needle u8/u16 width selection.

## Weaknesses

- Score/indices tier divergence (unverified typo budget on the score path).
- Silent quality cliff at 1024 bytes (greedy, and `score == 0` on rejection).
- No normalization (`a` ≠ `á`); emoji-skipping gap cost.
- The Unicode 0-typo prefilter bug.
- Typo mode is slower than scalar [nucleo] at budget ≥ 3.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                               | Trade-off                                                   |
| ------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------- |
| Substitution in the DP, budget in prefilter | Typos scoreable; `max_typos = 0` costs nothing          | Score path never verifies the budget (tier divergence)      |
| Intra-sequence row-wise SIMD                | No interleaving, no length bucketing                    | log₂(LANES) extra vector ops per row for the horizontal max |
| Removed inter-sequence bucketing            | Measured: bucketing destroyed parallel scaling          | —                                                           |
| UTF-8 bytes, no transcode                   | 20–46× on CJK/Arabic corpora vs transcoding designs     | No normalization; gap cost through multi-byte chars         |
| Fixed-stride never-zeroed matrices          | Zero steady-state allocation; structurally-zero borders | Memory sized for worst case regardless of input             |
| Page-safe over-read tail loads              | ~40 % faster without AVX-512                            | AddressSanitizer-hostile; needs a `safe_read` escape hatch  |

## Sources

- [saghen/frizbee][frizbee-repo] at [`e5f0ee20`][frizbee-tree] — README
  (inter-sequence quote), `src/const.rs`, `src/smith_waterman/*`,
  `src/prefilter/*`, `BENCHMARKS.md`.
- [`neo_frizbee` 0.11.0][neo-frizbee] — the fork [fff] pins (`repository`
  field points back at saghen/frizbee); kernel/prefilter/backend details in
  this deep-dive were verified against its extracted sources.
- [frizbee issue #63][frizbee-63] — junegunn's benchmark correction.
- [skim PR #1105][skim-1105] — the API-tier measurement lesson (see
  [comparison]).

<!-- References -->

[frizbee-repo]: https://github.com/saghen/frizbee
[frizbee-tree]: https://github.com/saghen/frizbee/tree/e5f0ee206bc146dc064c5a4ce6fc62d3dbec911c
[neo-frizbee]: https://crates.io/crates/neo_frizbee/0.11.0
[frizbee-63]: https://github.com/Saghen/frizbee/issues/63
[skim-1105]: https://github.com/skim-rs/skim/pull/1105
[fzf]: ./fzf.md
[fzy]: ./fzy.md
[nucleo]: ./nucleo.md
[fff]: ./fff.md
[comparison]: ./comparison.md
