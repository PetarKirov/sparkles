# fzf (Go)

The reference design of interactive fuzzy finding — the matcher whose scoring
constants, extended-search syntax, and slab memory model every other subject in
this survey either forked, ported, or defined itself against.

|                   |                                                                      |
| ----------------- | -------------------------------------------------------------------- |
| Language          | Go                                                                   |
| License           | MIT                                                                  |
| Repository        | [junegunn/fzf][fzf-repo]                                             |
| Surveyed revision | [`0579bb0e`][fzf-algo] (all file/line citations pin this commit)     |
| Category          | Interactive finder (matcher + TUI + shell integration)               |
| Algorithm class   | Smith-Waterman variant, no substitution, single matrix (approximate) |
| First release     | 2013                                                                 |

## Overview

### What it solves

One binary that turns any line stream into an interactively filtered list:
type a few characters of anything you remember about the line, in order, and
the best candidates float to the top. The matcher ranks by a gapped-subsequence
alignment; the product wraps it in a TUI, `--preview`, key bindings, and shell
integration — which is a large part of why its _algorithm_ became the field's
baseline (see [fzy] for the counter-example).

### Design philosophy

The 1258-line [`src/algo/algo.go`][fzf-algo] opens with the field's best
self-documentation. On the V1/V2 split:

> Naive algorithm first finds the first occurrence of the pattern characters,
> then it tries to find the shortest substring — so it is not guaranteed to
> find the optimal match.

and on the calibration of the constants (verbatim, from the constant block):

> We prefer matches at the beginning of a word, but the bonus should not be
> too great to prevent the longer acronym matches from always winning over
> shorter fuzzy matches. The bonus point here was specifically chosen that
> the bonus is cancelled when the gap between the acronyms grows over
> 8 characters, which is approximately the average length of the words found
> in web2 dictionary and my file system.

The constants are not arbitrary: they encode a decade of taste-tuning against
real file systems, which is why [nucleo], [telescope-fzf-native] and (with
retunes) [frizbee] all reuse them.

## How it works

Two matchers. **`FuzzyMatchV1`** is a greedy two-pass scan — forward to find
where the pattern completes, backward from that end to tighten the start —
O(n) but only ever sees the _first_ occurrence chain. **`FuzzyMatchV2`** (the
default) is a modified Smith-Waterman in which "omission or mismatch of a
character in the pattern is not allowed" — a gapped-subsequence alignment
rather than true local alignment. O(nm) on a match, O(n) on a miss.

V2 degrades to V1 in exactly one place, and the trigger is slab capacity, not
a length heuristic:

```go
if slab != nil && int64(N)*int64(M) > int64(cap(slab.I16)) || M > 1000 {
    return FuzzyMatchV1(caseSensitive, normalize, forward, input, pattern, withPos, slab)
}
```

with `slab16Size = 100 * 1024` and `slab32Size = 2048`
([`src/constants.go:44`][fzf-constants]); the `M > 1000` guard keeps the
`int16` score matrix from overflowing.

## Algorithm & scoring model

The constant table ([`algo.go`][fzf-algo]), the de-facto standard of the field:

```go
scoreMatch        = 16
scoreGapStart     = -3
scoreGapExtension = -1
bonusBoundary     = scoreMatch / 2                        // 8
bonusNonWord      = scoreMatch / 2                        // 8
bonusCamel123     = bonusBoundary + scoreGapExtension     // 7
bonusConsecutive  = -(scoreGapStart + scoreGapExtension)  // 4
bonusFirstCharMultiplier = 2

bonusBoundaryWhite     int16 = bonusBoundary + 2  // 10
bonusBoundaryDelimiter int16 = bonusBoundary + 1  // 9

delimiterChars = "/,:;|"
whiteChars     = " \t\n\v\f\r\x85\xA0"
```

Gaps are affine. `Init(scheme)` retunes two values at runtime — cheap and
materially better for paths:

| scheme    | `bonusBoundaryWhite` | `bonusBoundaryDelimiter` | `delimiterChars` | `initialCharClass` |
| --------- | -------------------- | ------------------------ | ---------------- | ------------------ |
| `default` | 10                   | 9                        | `/,:;\|`         | `charWhite`        |
| `path`    | 8                    | 9                        | `/` (or OS sep)  | `charDelimiter`    |
| `history` | 8                    | 8                        | `/,:;\|`         | `charWhite`        |

Seven character classes whose _ordering_ is load-bearing (`class >=
charNonWord` means "entering a word character"): `charWhite`, `charNonWord`,
`charDelimiter`, `charLower`, `charUpper`, `charLetter`, `charNumber`. Two
lookup tables are precomputed, with the measured payoff written into the
source:

```go
// A minor optimization that can give 15%+ performance boost
asciiCharClasses [unicode.MaxASCII + 1]charClass
// A minor optimization that can give yet another 5% performance boost
bonusMatrix [charNumber + 1][charNumber + 1]int16
```

so the per-character bonus is one `bonusMatrix[prevClass][class]` load, and
index 0 reads as a word boundary (`bonusBoundaryWhite`).

V2 proper runs in four phases:

1. **`asciiFuzzyIndex` prefilter** — a _complete_ subsequence test (walks the
   whole pattern with `bytes.IndexByte` over a shrinking suffix;
   case-insensitivity is free via `IndexByteTwo(b, b-32)`), returning a
   window `[firstIdx, lastIdx)` that the DP is then confined to.
2. **Bonus + row 0** — one pass computing per-offset bonus `B`, row-0 score
   `H0`/consecutive `C0`, lowercasing in place, and `F[pidx]` = first
   occurrence of each pattern char; bails if the pattern didn't complete.
3. **The DP** — matrix width `lastIdx - F[0] + 1`, each row starting at
   `F[pidx]`. The consecutive-chunk logic is the design's known flaw:

   ```go
   consecutive = Cdiag[off] + 1
   if consecutive > 1 {
       fb := B[col-int(consecutive)+1]
       if b >= bonusBoundary && b > fb { consecutive = 1 }
       else { b = max(b, bonusConsecutive, fb) }
   }
   ```

   A cell's score depends on the bonus of the character that _started_ the
   current run — scores are not independent of the path taken, violating the
   optimal-substructure assumption the DP rests on. [nucleo]'s author found
   via fuzzing that it "leads to a non-optimal match being reported" and
   removed it (see the [nucleo deep-dive][nucleo] for the concrete
   counter-example).

4. **Optional backtrace** for match positions, only when `withPos`.

Two fast paths bypass the matrix entirely: `fuzzyMatchV2Single` (1-char ASCII
pattern; hops occurrences, early-exits at `bonus >= bonusBoundary`) and
`fuzzyMatchV2Two` (2-char ASCII pattern; DP rows 0 and 1 fused into scalar
running state). Test hooks `disableSingle`/`disableTwo` force the general path
to assert equivalence — a discipline worth copying.

## Prefiltering

`asciiFuzzyIndex` (phase 1 above) is where most candidates die. It is more
than a first-char probe: a full in-order subsequence test over the byte
representation, plus window trimming — `firstIdx` steps back one character to
capture the boundary bonus, and the end is `LastIndexByte` of the pattern's
last character, the rightmost point an optimal match could end.

## Memory strategy

Bump allocation into a per-partition `Slab { I16 []int16; I32 []int32 }`, no
free, GC fallback when the slab is exhausted:

```go
func alloc16(offset int, slab *util.Slab, size int) (int, []int16) {
    if slab != nil && cap(slab.I16) > offset+size {
        return offset + size, slab.I16[offset : offset+size]
    }
    return offset, make([]int16, size)
}
```

Cells are never zeroed between matches — the algorithm overwrites what it
reads, and the backtrace comments explicitly warn against reading "stale slab
data" left of `F[row]`.

## SIMD & parallelism

No SIMD in the DP; the prefilter's `IndexByte` is Go's (SIMD-backed) `memchr`
equivalent. Concurrency is chunked partitions with a slab per partition, plus
one extra slab for the terminal's own position queries. The shipped
benchmarking flags (`--filter <q> --bench 10s --threads 1`) make the matcher
measurable in isolation — the methodology anchor of this survey's
[comparison].

## Unicode & case handling

`normalizeRune` is a **Latin→ASCII transliteration table**, not Unicode
normalization: a `map[rune]rune` of ~557 entries covering `0x00C0..0xFF61`
(`á ă ǎ â ä …` → `a`). Matching is on runes with no grapheme awareness;
`util.Chars` keeps a `[]byte` fast path and materializes runes only when
needed. Smart-case is per term: case-sensitive iff the term contains an
uppercase character.

## Incremental & streaming architecture

fzf is a whole-process pipeline (read lines → match → render); within a
session it re-runs the matcher over the full item set per keystroke, relying
on raw throughput and chunked parallelism rather than incremental rematch.
The incremental refinements ([nucleo]'s `Update` status, [snacks-picker]'s
`subset` skip) came later, from its descendants.

## Extended search syntax

[`src/pattern.go`][fzf-pattern] `parseTerms`: whitespace-split terms form
`[]termSet` — **within** a set, terms are OR'd (`|`); **across** sets, AND'd.

| Syntax  | `termType`          | Algo function        |
| ------- | ------------------- | -------------------- |
| `foo`   | `termFuzzy`         | `FuzzyMatchV1`/`V2`  |
| `'foo`  | `termExact`         | `ExactMatchNaive`    |
| `'foo'` | `termExactBoundary` | `ExactMatchBoundary` |
| `^foo`  | `termPrefix`        | `PrefixMatch`        |
| `foo$`  | `termSuffix`        | `SuffixMatch`        |
| `^foo$` | `termEqual`         | `EqualMatch`         |
| `!foo`  | `termExact` + `inv` | inverted             |

Details that matter for a port: `!` always forces `termExact` (never
inverse-fuzzy); with `--exact` the `'` prefix _flips_ to fuzzy; `\ ` escapes
a literal space. The non-fuzzy matchers are not trivial — `ExactMatchNaive`
"searches for the match with the highest bonus point, instead of stopping
immediately after finding the first match", and `EqualMatch` synthesizes a
comparable score so exact terms can compete against fuzzy ones inside an OR
set.

## Strengths

- The field's calibration baseline: constants tuned over a decade, with the
  reasoning documented in source comments.
- Complete prefilter + window trimming ahead of the DP.
- Slab reuse with a hard capacity trigger and a graceful V1 degradation.
- Scalar fast paths for 1- and 2-character patterns, with test hooks that
  prove them equivalent to the general path.
- The extended-search syntax became the de-facto query language
  ([nucleo], [snacks-picker] and telescope all implement it).
- Shipped, reproducible benchmark mode (`--bench`).

## Weaknesses

- The single-matrix DP is **not optimal under its own scoring function** —
  the consecutive-chunk bonus makes cell scores path-dependent (fixed by
  [fzy]'s/nucleo's two-matrix formulation).
- Full `m×n` matrix allocated even when only a rank (no positions) is needed.
- No typo tolerance — every pattern character must appear, in order.
- Rune-level matching mishandles multi-codepoint graphemes (they can match
  multiple times or perturb the score — the gap [nucleo] was built to close).
- Matcher not usable as a library (process-level only), which is why
  [telescope-fzf-native] exists.

## Key design decisions and trade-offs

| Decision                               | Rationale                                               | Trade-off                                                    |
| -------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------ |
| Single-matrix affine DP                | Half the memory traffic of two matrices                 | Provably non-optimal matches; path-dependent cell scores     |
| Slab-capacity (not length) V1 fallback | One knob; degrades only when memory would actually grow | Pathological inputs silently get a worse algorithm           |
| Boundary bonus ≈ gap-cancel at 8 chars | Acronym matches shouldn't always beat short fuzzy ones  | Constants encode English/file-system word length assumptions |
| Class/bonus lookup tables              | Measured +15 % and +5 %                                 | 7×7 matrix must be rebuilt when the scheme changes           |
| Rune matching + transliteration map    | Cheap, covers Latin accents                             | Not normalization; graphemes unhandled                       |
| `!` forces exact (never inverse-fuzzy) | Inverse-fuzzy produces too many false rejections        | Asymmetry between `foo` and `!foo` semantics                 |

## Sources

- [`src/algo/algo.go`][fzf-algo] — the matcher (header comment, constants,
  V1/V2, fast paths, slab).
- [`src/pattern.go`][fzf-pattern] — extended-search parsing.
- [`src/constants.go`][fzf-constants] — slab sizes.
- junegunn's benchmark decomposition in [frizbee issue #63][frizbee-63] —
  the reproducible single-threaded matcher baseline (see [comparison]).

<!-- References -->

[fzf-repo]: https://github.com/junegunn/fzf
[fzf-algo]: https://github.com/junegunn/fzf/blob/0579bb0e0defbd0b4233a8f2ecb7350504802a0a/src/algo/algo.go
[fzf-pattern]: https://github.com/junegunn/fzf/blob/0579bb0e0defbd0b4233a8f2ecb7350504802a0a/src/pattern.go
[fzf-constants]: https://github.com/junegunn/fzf/blob/0579bb0e0defbd0b4233a8f2ecb7350504802a0a/src/constants.go#L44
[frizbee-63]: https://github.com/Saghen/frizbee/issues/63
[fzy]: ./fzy.md
[nucleo]: ./nucleo.md
[frizbee]: ./frizbee.md
[telescope-fzf-native]: ./telescope-fzf-native.md
[snacks-picker]: ./snacks-picker.md
[comparison]: ./comparison.md
