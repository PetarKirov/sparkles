# fzy (C)

The clearest formulation in the field — the two-matrix affine-gap scorer that
had the _correct_ dynamic program in 2014 (which [nucleo] later re-derived),
and the case study in why a better algorithm loses to better engineering.

|                   |                                                                   |
| ----------------- | ----------------------------------------------------------------- |
| Language          | C                                                                 |
| License           | MIT                                                               |
| Repository        | [jhawthorn/fzy][fzy-repo]                                         |
| Surveyed revision | [`34b88869`][fzy-match] (all file/line citations pin this commit) |
| Category          | Interactive finder (matcher + minimal TUI)                        |
| Algorithm class   | Gotoh affine-gap alignment, two matrices (optimal)                |
| First release     | 2014                                                              |

## Overview

### What it solves

A small, fast terminal fuzzy selector with a deliberately principled scoring
model. Its [`ALGORITHM.md`][fzy-alg] is the best-written document in this
space; its core decomposition —

> fzy attempts to present the best matches first. The following considerations
> are weighed when sorting: … It prefers consecutive characters: `file`
> matches `file` over `filter`.

— splits **matching** (which candidates are eligible) from **scoring** (how to
order them), which is the right spine for any specification in this area. It
also usefully classifies prior art by what they minimize ("length of first
match", "length of shortest match", "length of shortest first match").

### Design philosophy

Correctness of the ranking model first. The DP is stated crisply in
[`ALGORITHM.md`][fzy-alg]:

> fzy computes a second `D` (for diagonal) matrix in parallel with the score
> matrix. The `D` matrix computes the best score which _ends_ in a match.

That is the Gotoh two-matrix formulation — the fix for the path-dependence
flaw in [fzf]'s single-matrix DP, ten years early.

## How it works

One pass per candidate: a `has_match` eligibility check, then the full `n×m`
DP filling `D` (best score ending in a match at this cell) and `M` (best
score overall), from [`src/match.c`][fzy-match]:

```c
score_t prev_score = SCORE_MIN;
score_t gap_score = i == n - 1 ? SCORE_GAP_TRAILING : SCORE_GAP_INNER;

for (int j = 0; j < m; j++) {
    if (lower_needle[i] == lower_haystack[j]) {
        score_t score = SCORE_MIN;
        if (!i) {
            score = (j * SCORE_GAP_LEADING) + match_bonus[j];
        } else if (j) {
            score = max(prev_M + match_bonus[j],
                        /* consecutive match, doesn't stack with match_bonus */
                        prev_D + SCORE_MATCH_CONSECUTIVE);
        }
        curr_D[j] = score;
        curr_M[j] = prev_score = max(score, prev_score + gap_score);
    } else {
        curr_D[j] = SCORE_MIN;
        curr_M[j] = prev_score = prev_score + gap_score;
    }
}
```

## Algorithm & scoring model

Floating-point constants, small, with a three-way gap distinction no other
subject makes ([`src/config.def.h`][fzy-config]):

```c
#define SCORE_GAP_LEADING       -0.005
#define SCORE_GAP_TRAILING      -0.005
#define SCORE_GAP_INNER         -0.01
#define SCORE_MATCH_CONSECUTIVE  1.0
#define SCORE_MATCH_SLASH        0.9
#define SCORE_MATCH_WORD         0.8
#define SCORE_MATCH_CAPITAL      0.7
#define SCORE_MATCH_DOT          0.6
```

`typedef double score_t` with `SCORE_MAX/MIN = ±INFINITY`. **Leading** and
**trailing** gaps are penalized 2× less than **inner** gaps — a genuinely
different design choice from [fzf]'s uniform gap costs and [nucleo]'s
deliberate absence of any leading-gap penalty. Bonuses come from a two-level
table indexed by `(class of ch, previous ch)`:

```c
#define COMPUTE_BONUS(last_ch, ch) \
    (bonus_states[bonus_index[(unsigned char)(ch)]][(unsigned char)(last_ch)])
```

## Prefiltering

Only `has_match` — libc `strpbrk` in a loop. No `memchr`, no window trimming;
every surviving candidate pays the full `n×m` DP over the _whole_ string.
The absence is a finding: this is the single largest reason fzy's wall-clock
lost to fzf's despite the better DP (see the [comparison]).

## Memory strategy

`MATCH_MAX_LEN 1024` with fixed 1024-wide rows regardless of actual lengths;
`match_positions` does a `malloc`/`free` of `n × 1024` doubles **per
candidate**. Combined with 64-bit float cells (4× the memory traffic of
[fzf]'s `int16`), this is the second engineering loss.

## SIMD & parallelism

None in the matcher (the `double` cells preclude useful packing). Concurrency
is plain worker threads over a flat item list.

## Unicode & case handling

ASCII only: `char`, `tolower`, `strcasechr`. Matching is always
case-insensitive; there is no smart-case.

## Incremental & streaming architecture

None — full rematch per keystroke, batch reads. No extended-search syntax
either; the query is one fuzzy term.

## Why it lost

Not the scoring — mechanically it is _better_ than fzf V2's. The losses are
engineering: `double` cells, per-candidate position allocation, no prefilter,
ASCII-only, no query syntax, and no product around the matcher (no preview,
no shell integration). A telling detail: the README claims fzy "is faster
than other fuzzy finders" but publishes no number anywhere, and the
explanatory page it once linked (`jhawthorn.github.io/fzy-algorithm`) is now
a 404 — [`ALGORITHM.md`][fzy-alg] in-repo is the surviving artifact.

## Strengths

- The correct (optimal-substructure) two-matrix affine DP, first in the field.
- The clearest written algorithm documentation of any subject.
- The leading/inner/trailing gap distinction — a modeling idea worth keeping
  even where the implementation is not.

## Weaknesses

- `double` score cells; per-candidate `malloc` for positions.
- No prefilter beyond `strpbrk`; full-width DP always.
- ASCII-only; no smart-case; no query language.
- Fixed 1024-byte candidate cap with no graceful fallback.

## Key design decisions and trade-offs

| Decision                            | Rationale                                                                 | Trade-off                                            |
| ----------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------- |
| Two matrices (`M` + `D`)            | Optimal substructure; consecutive bonus doesn't stack with boundary bonus | 2× row storage vs [fzf]'s approximation              |
| `double` scores                     | No overflow analysis needed; ±∞ sentinels                                 | 4× memory traffic; no SIMD packing                   |
| Distinct leading/trailing gap costs | Substring-ish behavior without special cases                              | More constants to tune                               |
| No prefilter                        | Simplicity                                                                | Full DP on every eligible candidate — the fatal cost |
| Matcher-first, product-second       | Small and principled                                                      | Lost adoption to fzf's product surface               |

## Sources

- [`ALGORITHM.md`][fzy-alg] — the algorithm document (quoted above).
- [`src/match.c`][fzy-match] — the DP.
- [`src/config.def.h`][fzy-config] — the constants.

<!-- References -->

[fzy-repo]: https://github.com/jhawthorn/fzy
[fzy-alg]: https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/ALGORITHM.md
[fzy-match]: https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/src/match.c
[fzy-config]: https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/src/config.def.h
[fzf]: ./fzf.md
[nucleo]: ./nucleo.md
[comparison]: ./comparison.md
