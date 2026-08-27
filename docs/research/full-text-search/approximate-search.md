# Approximate content search — what ships, and what it should mean

The practice page for [`theory/approximate.md`](./theory/approximate.md): two
tools ship approximate content matching, they mean different things by it, and
`PKS2`'s fuzzy mode has to pick one.

> **Last reviewed:** August 28, 2026.

---

## The two shipped models

### ugrep `-Z`: edit distance, with the operations exposed

[ugrep][ugrep] combines a maximum distance cost with `INS`, `DEL` and `SUB` flags
mapped onto `reflex::FuzzyMatcher`. `[source-verified]` A user can say
"substitutions only, distance ≤ 2" — which is often what a code-search user
actually means, since a typo is usually a wrong key rather than a dropped one.

### fff: a needle-deletion budget, then quality filters

[fff][fff-grep] takes one number and repairs the results afterwards. The budget is
`(len/3).min(2)`, with the cap explained in its own comment: higher values _"let
the SIMD prefilter pass lines missing key characters entirely"_.

Then four post-match filters, each documented with the concrete failure it
prevents `[source-verified]`:

| Filter        | Threshold                         | Prevents                                                  |
| ------------- | --------------------------------- | --------------------------------------------------------- |
| Minimum score | 50% of a perfect contiguous match | Scattered near-misses                                     |
| Maximum span  | `3 × needle length`               | Matches spread across a whole line                        |
| Density floor | 45% perfect / 65% with typos      | Delimiter-inflated spans (`ff_flv_encode_picture_header`) |
| Gap ceiling   | `(needle/3).max(2)`               | Too many discontinuities                                  |

Plus a **distinct-character prefilter derived from the budget**: collect the
needle's unique bytes, require `unique_count − max_typos` of them to appear
anywhere in the file, else skip it. That one is elegant — it is not tuned, it
_follows_ from the budget — and it is nearly free.

## What the contrast says

fff's four filters exist because **a pure edit budget over a 512-byte line admits
far too much.** A short needle within distance 2 matches an enormous number of
lines in any real file; the budget is not a sufficient admission criterion at line
scale, and fff discovered that empirically.

ugrep avoids the problem differently, by letting the user constrain the operation
set rather than the distance alone.

Both are answers to the same underlying fact: **content is a much larger haystack
than a filename, so tolerance that is helpful for paths is noise for lines.**

## What this means for hue

`sparkles:fuzzy`'s matcher is an affine-gap Smith-Waterman subsequence scorer
tuned for **paths**. Applying it unchanged to line content is wrong twice over:

1. **Arithmetically.** A content line must be passed with `filenameOffset == 0`,
   which makes `allInFilename` unconditionally true and hands every admitted line
   the filename bonus. The ranking is not mistuned, it is incorrect — a
   [baseline][baseline] finding.
2. **Semantically.** Subsequence tolerance over 512 bytes admits nearly
   everything, which is the same wall fff hit.

So the guidance is: **use the existing matcher, with `maxTypos = 0` for
admission.** Exact subsequence over a line is already a useful fuzzy mode — it is
what "find `fzf` in `f*u*z*z*y`" means — and it sidesteps the tolerance problem
entirely. If real typo tolerance is wanted later, the right primitive is
[Myers' bit-vector edit distance](./theory/bit-parallel.md) over the stored
window, not a wider budget on the path scorer.

And the fallback ladder should follow fff's _visible degradation_ rather than its
silent one: a mode that changes should say so, the way its regex-compile fallback
returns the compiler's error for the UI to show.

## What this catalog concluded

1. **Fuzzy grep mode = exact subsequence admission** (`maxTypos = 0`) over a
   bounded line window, ranked by the existing scorer.
2. **Port fff's quality filters conceptually**, not its budget — span, density and
   gap ceilings are what make subsequence matching over a long line tolerable.
3. **Steal the distinct-character prefilter.** It is derived rather than tuned,
   costs a `memchr` per unique byte, and rejects most files.
4. **Do not reuse the path matcher's ranking** for line candidates.
5. **Real edit-distance tolerance is a later, separate decision**, with Myers as
   the primitive and ugrep's operation flags as the interface worth copying.

## Sources

`[source-verified]`: [ugrep][ugrep] (`-Z` flag composition),
[fff-grep][fff-grep] (`fuzzy_grep.rs` budget, prefilter and quality filters).
Theory in [`theory/approximate.md`](./theory/approximate.md); the ranking
arithmetic in the [baseline][baseline].

<!-- References -->

[ugrep]: ./ugrep.md
[fff-grep]: ./fff-grep.md
[baseline]: ./sparkles-baseline.md
