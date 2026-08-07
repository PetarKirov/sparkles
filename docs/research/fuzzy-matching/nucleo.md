# nucleo (Rust)

[fzf]'s algorithm, corrected and library-shaped: the two-matrix optimal DP
with fzf's constants (one deliberate retune), the sharpest prefilter in the
scalar field, and — arguably more valuable than the matcher — the concurrent
picker harness (`Injector` / `tick()` / incremental reparse) that Helix
consumes.

|                   |                                                                     |
| ----------------- | ------------------------------------------------------------------- |
| Language          | Rust (two crates: `nucleo-matcher` 0.3.1, `nucleo` 0.5.0)           |
| License           | MPL-2.0                                                             |
| Repository        | [helix-editor/nucleo][nucleo-repo]                                  |
| Surveyed revision | [`8c16d47c`][nucleo-tree] (all file/line citations pin this commit) |
| Category          | Matcher library + concurrent picker harness                         |
| Algorithm class   | Smith-Waterman, no substitution, two matrices (optimal)             |
| First release     | 2023                                                                |

## Overview

### What it solves

A matcher Helix can embed: same ranking family as [fzf], but optimal under
its own scoring function, allocation-free per match, grapheme-aware in its
outputs, and wrapped in a harness that keeps a UI responsive while millions
of items stream in and rematch across keystrokes.

### Design philosophy

Correct the algorithm, keep the calibration. The README's "exact same scoring
system as fzf" is not literally true, and the deviation is documented in the
source — on why `BONUS_CAMEL123` had to change after removing fzf's
consecutive-chunk bonus:

> Their value should be `BONUS_BOUNDARY - PENALTY_GAP_EXTENSION = 7`.
> However, this priporitzes camel case over non-camel case. … we don't do
> that (because its incorrect) so to avoids prioritizing camel we use a lower
> bonus. … This also has the nice sideeffect of perfectly balancing out camel
> case, snake case and the consecutive version of the word

Also documented as intent: nucleo is "a substring matching tool … with no
penalty assigned to matches that start later" — **no leading-gap penalty and
no candidate-length penalty in the score**; length is a _sort tie-breaker_ in
the worker, never a score term.

## Algorithm & scoring model

Constants are `u16`, **unsigned** — penalties are magnitudes applied with
`saturating_sub`, giving Smith-Waterman's floor-at-zero for free:

```rust
pub(crate) const SCORE_MATCH: u16 = 16;
pub(crate) const PENALTY_GAP_START: u16 = 3;
pub(crate) const PENALTY_GAP_EXTENSION: u16 = 1;
pub(crate) const BONUS_BOUNDARY: u16 = SCORE_MATCH / 2;                     // 8
pub(crate) const BONUS_CAMEL123: u16 = BONUS_BOUNDARY - PENALTY_GAP_START; // 5  ← diverges from fzf's 7
pub(crate) const BONUS_NON_WORD: u16 = BONUS_BOUNDARY;                      // 8
pub(crate) const BONUS_CONSECUTIVE: u16 = PENALTY_GAP_START + PENALTY_GAP_EXTENSION; // 4
pub(crate) const BONUS_FIRST_CHAR_MULTIPLIER: u16 = 2;
pub(crate) const PREFIX_BONUS_SCALE: u16 = 2;
pub(crate) const MAX_PREFIX_BONUS: u16 = BONUS_BOUNDARY;
```

(`bonus_boundary_white = 10` and `bonus_boundary_delimiter = 9` are `Config`
fields.) What it actually fixed over [fzf]:

1. **Two matrices instead of one.** fzf's single-matrix affine approximation
   returns matches non-optimal under fzf's own function — the README's
   reproducible example: matching `foo` against `xf foo`, nucleo picks
   `x__foo`, fzf picks `xf_oo`, at any word length.
2. **Space.** fzf allocates the full `m×n` matrix even when only ranking;
   nucleo keeps **one score row** when indices aren't requested.
3. **Matrix width `n − m + 1`, not `n`** — "the `p` char requires `p-1` chars
   before it and `m-p` chars after it, so there are always `m+1` chars that
   can never match the current char."

Two smaller divergences a port should know: `bonus_for` returns `0` for a
trailing `Delimiter` where fzf returns `bonusNonWord`; and the opt-in
`prefer_prefix` decays at different rates on the DP path
(`PENALTY_GAP_EXTENSION`) vs the greedy/exact path (`PENALTY_GAP_START`) — an
inconsistency in the surveyed release.

**Dispatch is budget-triggered, not length-triggered.** `fuzzy_match_optimal`
always tries the DP; greedy fires only when the slab refuses the allocation:

```rust
let Some(mut matrix) = self.slab.alloc(&haystack[start..end], needle.len()) else {
    return self.fuzzy_match_greedy_::<INDICES, H, N>(haystack, needle, start, greedy_end, indices);
};
// const MAX_MATRIX_SIZE: usize = 100 * 1024;   (fzf's slab16Size, verbatim)
// const MAX_HAYSTACK_LEN / MAX_NEEDLE_LEN: usize = 2048;
```

So the honest complexity claim is **O(mn) bounded by a hard ceiling of
102,400 cell updates per candidate** (on the prefilter-trimmed region), else
O(n) greedy, plus an O(n) prefilter. Short-circuits before the DP: needle
longer than haystack → `None`; equal lengths → `exact_match`; ASCII haystack
with Unicode needle → `None`; single-char needle → best-bonus occurrence
scan; and if the prefiltered region is exactly needle-length the match is
contiguous — straight to `calculate_score`, no matrix.

## Prefiltering

The ASCII path is a complete subsequence test returning a three-way window:

```rust
fn find_ascii_ignore_case(c: u8, haystack: &[u8]) -> Option<usize> {
    if c >= b'a' && c <= b'z' { memchr2(c, c - 32, haystack) } else { memchr(c, haystack) }
}
```

`start` = first occurrence of `needle[0]` within
`haystack[..len - needle.len() + 1]`; `greedy_end` = end of the leftmost
greedy match; `end` = last occurrence of the final needle char via `memrchr`.
`[start, end)` is the DP window. The needle is pre-lowercased at parse time,
so `memchr2(c, c-32)` gets case-insensitivity in one SIMD-backed pass with no
haystack folding. The Unicode prefilter is scalar and checks only first/last
needle chars — not exact, hence the ASCII path asserts a non-match "should
have been caught by the prefilter". Exact atoms use `memmem::find_iter`,
picking the highest-bonus occurrence with an early exit at
`bonus >= bonus_boundary_white`.

## Memory strategy

One eager `alloc_zeroed` per `Matcher` — 133,120 bytes, reused forever:

```rust
struct MatcherData {
    haystack: [char; MAX_HAYSTACK_LEN],            //   8 KiB
    bonus: [u8; MAX_HAYSTACK_LEN],                 //   2 KiB
    row_offs: [u16; MAX_NEEDLE_LEN],               //   4 KiB
    scratch_space: [ScoreCell; MAX_HAYSTACK_LEN],  //  16 KiB
    matrix: [u8; MAX_MATRIX_SIZE],                 // 100 KiB
}
```

Nothing allocated, freed, or zeroed per match. Cell types worth stealing:

```rust
#[repr(align(8))]
pub(crate) struct ScoreCell { pub score: u16, pub consecutive_bonus: u8, pub matched: bool }
#[repr(transparent)]
pub struct MatrixCell(pub(crate) u8);   // 2 bits used — the backtrack matrix
```

The backtracking matrix is **2 bits per cell**, written only when the
`INDICES` const-generic is true; per-row trimming (`row_offs[i]` = first
index where needle char _i_ can match) composes with the `n−m+1` width.

> [!WARNING]
> One real bug not to inherit: `fieds_from_ptr` sizes the matrix slice with
> `* self.haystack_len` where the layout reserved `* self.needle_len`,
> constructing a `&mut [MatrixCell]` far larger than the allocation. Only the
> used prefix is indexed so it doesn't misbehave, but forming the reference
> is already UB. Size by `needle_len`.

## SIMD & parallelism

No SIMD in the DP — the prefilter's `memchr`/`memmem` are the vectorized
parts. Parallelism lives in the `nucleo` crate: a rayon pool with one 133 KiB
`Matcher` per worker thread in `UnsafeCell` indexed by
`rayon::current_thread_index()` (thread-locality without TLS), and `par_sort`
— `sort_unstable`'s pdqsort copied and parallelized with `rayon_core::join`
plus cancellation. On why there is no fzf-style chunked lazy merge: sorting
is ≤5 % of match time, and "I think fzf does it because go doesn't have a
good parallel sort."

## Unicode & case handling

The strongest part of the design:

```rust
pub enum Utf32Str<'a> { Ascii(&'a [u8]), Unicode(&'a [char]) }
```

Strings are **pre-segmented once at injection**, amortized over the many
re-matches a live picker performs. The ASCII discriminant is
`string.is_ascii() && !contains("\r\n")` — because `\r\n` is a single
grapheme. It matches **graphemes by proxy**: length equals grapheme count,
each element is the _first codepoint_ of its grapheme, the rest discarded
(`Utf32String::from("u\u{0308}").to_string() == "u"` — not round-trip). The
payoff: emitted match indices are directly usable as grapheme indices for
highlighting — the README frames this as the concrete advantage over
fzf/skim, where "multi codepoint graphemes can have weird effects (match
multiple times, weirdly change the score)." Case folding is a generated
simple-fold table (Unicode 15.0.0, ~347 pairs, binary-searched; ASCII folds
arithmetically); normalization is fzf-style Latin→ASCII transliteration, but
as three dense directly-indexed arrays rather than a hash map.

## Incremental & streaming architecture

The `nucleo` crate is the part a picker actually needs:

- **`boxcar::Vec<T>`** — lock-free append-only vector whose elements never
  move: 27 fixed-size buckets of length `1 << (i + SKIP_BUCKET)`, index →
  location is pure bit math, growth CAS-installs a new bucket. Indices are
  handed out by `fetch_add` _before_ the slot is filled, so `get()` returns
  `Option` and the worker keeps an `in_flight` retry list. Each entry carries
  the item's match columns inline in a variable-length tail.
- **`Injector<T>`** — `Clone + Send`; `push` is documented lock-free and
  wait-free; `extend` reserves N indices in one `fetch_add`.
- **Incremental reparse** — the key optimization, a three-state lattice
  `Status: Unchanged < Update < Rescore`:

  ```rust
  if append && old_status != Status::Rescore
      && self.cols[column].0.atoms.last().map_or(true, |last| !last.negative)
  { self.cols[column].1 = Status::Update; } else { self.cols[column].1 = Status::Rescore; }
  ```

  `Update` = the caller promised the old query is a prefix of the new one, so
  the match set can only shrink — rescore survivors in place, never revisit
  rejected items. A trailing **negative atom** disqualifies this (appending
  to `!foo` can _grow_ the set). Non-matches are marked `idx = u32::MAX`,
  sorted to the end, dropped with one `truncate`.

- **`tick(timeout)`** — the whole UI contract: non-blocking beyond `timeout`
  (10 ms recommended, once per frame), `try_lock_arc_for` on the normal path
  so a busy worker never stalls the frame, returning
  `Status { changed, running }`.

Pattern syntax is fully [fzf]-compatible (`'` `^` `$` `!` `\` escapes,
`AtomKind::{Fuzzy, Substring, Prefix, Postfix, Exact}` + `negative`), with
one deliberate omission: no negated fuzzy ("too many false positives") —
`!foo` is forced to `Substring`, matching fzf. `CaseMatching` and
`Normalization` resolve **per atom at parse time** (needle pre-folded).

## Strengths

- Optimal DP with fzf's field-tested calibration (one justified retune).
- The best prefilter in the scalar field; the `memchr2(c, c−32)` trick.
- True zero-allocation steady state; 2-bit backtrack cells; single-row
  score-only mode.
- Grapheme-indexed output — match positions are directly usable by a
  cell-grid renderer.
- The harness contract (`Injector` + `tick` + `Update`/`Rescore`) is the
  survey's cleanest producer/matcher/UI seam (see [helix-integration]).

## Weaknesses

- UTF-32 transcode of every non-ASCII candidate at injection — the
  architecture bill [frizbee]'s byte-wise matching avoids (its 20–46×
  Unicode wins are mostly this difference).
- No typo tolerance (no substitution transition in the DP).
- The matrix-slice sizing bug above (latent UB).
- `prefer_prefix` decay inconsistency between paths.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                              | Trade-off                                                 |
| ----------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------- |
| Two-matrix DP, fzf constants, camel 7→5   | Optimality + preserve calibration balance              | Diverges from fzf's exact ranking in camel-adjacent cases |
| Slab-refusal (not length) greedy fallback | Hard 102,400-cell budget per candidate                 | Pathological inputs silently ranked by a weaker algorithm |
| Pre-segmented `Utf32Str` at injection     | Amortized over many rematches; grapheme-stable indices | Lossy (first codepoint per grapheme); transcode cost      |
| No leading-gap / length penalty in score  | "Substring matching tool" semantics                    | Needs a sort tie-breaker to prefer shorter candidates     |
| `Update` vs `Rescore` on append           | Interactive typing is the common case                  | Correctness depends on the trailing-negative-atom guard   |
| Per-worker `Matcher` via thread index     | Thread-locality without TLS                            | `UnsafeCell` discipline; workers pinned to pool size      |

## Sources

- [nucleo repository][nucleo-repo] at [`8c16d47c`][nucleo-tree] —
  `matcher/src/{lib,score,matrix,prefilter,exact,config}.rs`,
  `src/{lib,worker,boxcar,par_sort}.rs`, `src/pattern.rs` (constants, quotes,
  and mechanics above; verbatim file copies cached during this survey).
- README performance discussion + [fzf discussion #3491][fzf-3491] — both
  headline nucleo-vs-fzf claims were confounded (whole-TUI measurements);
  see the [comparison] for the numbers this survey trusts instead.

<!-- References -->

[nucleo-repo]: https://github.com/helix-editor/nucleo
[nucleo-tree]: https://github.com/helix-editor/nucleo/tree/8c16d47cdfa9607d3e44df5f81c635c6f43c65ee
[fzf-3491]: https://github.com/junegunn/fzf/discussions/3491
[fzf]: ./fzf.md
[frizbee]: ./frizbee.md
[helix-integration]: ./helix-integration.md
[comparison]: ./comparison.md
