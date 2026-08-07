# Comparison — fuzzy matching & picker architecture

The cross-subject synthesis: what converged, where the designs genuinely
split, which published numbers survive scrutiny, and the delta table bridging
into the `sparkles:fuzzy` specification.

**Last reviewed:** August 7, 2026

## At a glance

|                                | [fzf] V2                                                     | [nucleo]                                                    | [frizbee] / [fff]                                   | [fzy]                                           | [snacks-picker]                       |
| ------------------------------ | ------------------------------------------------------------ | ----------------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------- | ------------------------------------- |
| Algorithm class                | SW variant, no substitution, **single matrix** (approximate) | SW, no substitution, **two matrices** (optimal)             | SW **with substitution** (true local alignment)     | Gotoh affine, **two matrices** (optimal)        | greedy multi-start scan               |
| Complexity                     | O(nm) match / O(n) miss; V1 on slab overflow                 | O(nm) **capped at 102,400 cells**; greedy fallback          | O(m·⌈n/L⌉·log₂L) vector ops; greedy above n = 1024  | O(nm), no trimming, no fallback                 | O(occurrences·m)                      |
| Score type                     | `int16`                                                      | `u16` saturating                                            | `u8`/`u16`, chosen per needle                       | **`double`**                                    | Lua number                            |
| Match / gap open / extend      | 16 / −3 / −1                                                 | 16 / −3 / −1                                                | 12 / −5 / −1 (+ mismatch −6)                        | 1.0 consec / −0.005 lead·trail / −0.01 inner    | 16 / −3 / −1                          |
| Boundary / camel / consecutive | 8 (white 10, delim 9) / 7 / 4                                | 8 (white 10, delim 9) / **5** / 4                           | delim 4 / capital 4 / **none (emergent)**           | slash 0.9, word 0.8, dot 0.6 / 0.7 / 1.0        | 8 (white 10, delim 9) / 7 / 4         |
| Typo tolerance                 | none                                                         | none                                                        | **yes** — substitution in DP + budgeted prefilter   | none                                            | none                                  |
| Prefilter                      | full subsequence test + window trim                          | `memchr2(c, c−32)` subsequence + `memrchr` end              | SIMD greedy subsequence, multi-path per typo budget | `strpbrk` loop only                             | entropy-ordered atom evaluation       |
| Memory                         | bump slab, never zeroed                                      | one 133 KiB slab/matcher; 1-row score-only; 2-bit backtrack | two fixed-stride matrices, never zeroed             | 1024-wide `double` rows; `malloc` per candidate | 1000-cap min-heap, evicted-slot reuse |
| SIMD                           | prefilter only                                               | prefilter only (`memchr`/`memmem`)                          | **full kernel** — row-wise, log-shift prefix-max    | none                                            | none                                  |
| Unicode                        | runes + transliteration map                                  | **pre-segmented grapheme proxy**; fold table                | **UTF-8 bytes direct**; no normalization            | ASCII only                                      | bytes                                 |
| Incremental rematch            | none (rethroughput)                                          | `Update`/`Rescore` on append                                | none (library)                                      | none                                            | subset skip + 3-phase order           |
| Query syntax                   | `'` `^` `$` `!` `\|` (defined it)                            | full fzf minus negated-fuzzy                                | none (library); fff adds constraints + location     | none                                            | fzf-style + `field:`                  |

([telescope-fzf-native] is [fzf]'s column verbatim, ASCII-only.)

## The consensus, and the splits

**The scoring function converged; the engineering did not.** Four of five
matchers use the same affine-gap alignment family with word-boundary/
camelCase bonuses, and three carry [fzf]'s exact constants — calibrated so
the boundary bonus cancels at a gap of ~8 characters. The constants encode a
decade of tuning; every port in this survey reuses rather than re-derives
them. The genuine splits:

1. **Optimality.** fzf's single-matrix DP is provably non-optimal under its
   own function (`foo` vs `xf foo`: fzf picks `xf_oo`, the optimum is
   `x__foo`); its consecutive-chunk bonus makes cell scores path-dependent.
   [fzy] had the correct two-matrix formulation in 2014; [nucleo] re-derived
   it and had to retune camel 7→5 to keep camel/snake/consecutive balanced.
2. **Substitution.** Only [frizbee] has a substitution transition — the
   precondition for typo tolerance. Its split (typos _scoreable_ in the DP,
   _bounded_ by a multi-path prefilter, so `maxTypos = 0` costs nothing) is
   the architecture; the trap is the unverified budget on the score-only
   tier.
3. **Unicode model.** Transcode-at-inject with grapheme-proxy indices
   ([nucleo]) vs bytes-direct with no normalization ([frizbee]). frizbee's
   20–46× CJK/Arabic wins over nucleo are mostly this architecture choice,
   not SIMD.
4. **Where ranking policy lives.** In the matcher's config ([nucleo], and
   its host [helix-integration] cannot re-rank) vs a separate re-ranking
   layer over a stock base score ([fff] — frecency, filename ladder, git,
   distance, combo). The layered design iterates on "feel" without touching
   the kernel and yields an inspectable per-result breakdown.

**The picker-architecture invariants** (independently converged on by
[nucleo]/[helix-integration] and [snacks-picker]):

- Producer and matcher are decoupled; items stream; "still producing" is a
  first-class UI state fed by two independent signals.
- Work is budgeted per frame — **~10 ms in both stacks** — and rendering is
  decoupled at a slower cadence (33 ms / 10–30 ms deferrals).
- Cancellation is a monotonic generation counter the _worker_ checks;
  stale producers unwind themselves; no locks on the match fast path.
- Appending to the query is the common case and optimized explicitly
  (`is_append` reparse; subset skip) — invalid after a trailing negative
  atom, in both codebases.
- Only the visible window is fully realized; **match positions are derived
  at render time, never stored per item** — both stacks, independently.
- Rematch order is a correctness feature: visible top-K first, then previous
  matches, then the rest.

## Benchmarks — what survives scrutiny

Most published numbers in this space are confounded. The failure modes, each
with a documented instance:

| Claim                                       | Confound                                                                   | Correction                                                                                                                                                     |
| ------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| frizbee "7× faster than fzf" (early README) | library match time vs whole-process wall time                              | [junegunn's issue #63][frizbee-63]: fzf search-only is 24.10 ms multi-thread / 178.57 ms single-thread on the same corpus; author conceded, rebuilt benchmarks |
| nucleo's fzf screencasts (~30× implied)     | whole-TUI incl. rendering + Helix's single-threaded symlink-following walk | both sides' numbers confounded; see [fzf discussion #3491][fzf-3491]                                                                                           |
| skim's frizbee rows (early harness)         | `Matcher` re-instantiated per call; indices API timed as score API         | [skim PR #1105][skim-1105]: the number moved **5–10× purely from API tier**                                                                                    |
| "fzf slower" whole-binary runs              | ingestion/print-bound, not matcher-bound                                   | skim PR #974: over 10 M piped items fzf _wins_                                                                                                                 |

What this survey treats as reference points:

- **fzf single-threaded matcher baseline** (reproducible via shipped flags
  `--filter linux --bench 10s --threads 1`, 1,406,940 paths, 12.79 %
  selectivity): **139 ms** (72 iterations) — junegunn's own measurement in
  [frizbee #63][frizbee-63].
- **Best independent library-level comparison** ([noib3/fuzzy-benches][fuzzy-benches],
  95,655 haystacks, needle `emacs`, single-threaded, sorting excluded):
  nucleo-matcher 7.43 ms vs telescope-fzf-native 9.10 ms — **nucleo beats
  fzf's algorithm by 1.22×** on a realistic needle, widening to 2.2× on a
  single-character needle (the low-selectivity regime where the prefilter
  does the work). Not the ~30× of the screencasts.
- **frizbee's own matrix** (Chromium corpus, needle `linux`, 8 % match
  rate): sequential 22.36 ms vs nucleo 90.53 ms (**4.05×**); at 3 typos
  frizbee is **slower** than scalar nucleo (142 ms vs 90 ms); the fzf rows
  there are hardcoded sleeps pasted from external runs.

**Methodology rules for `sparkles:fuzzy`'s own benchmarks**, derived from
the above: state the API tier (score-only vs positions; matcher reused vs
re-instantiated); fix the corpus and report selectivity as a percentage; use
`fzf --filter <q> --bench 10s --threads 1` for the fzf baseline rather than
timing the process; use [telescope-fzf-native] as the in-process fzf-algo
proxy (ASCII corpora only — its non-ASCII scores diverge); and compare
engines within one snapshot, anchoring cross-snapshot claims on retired
instructions (the [wired bench-baseline][wired-baseline] discipline).

## Ranked leverage

Descending order of measured impact, for an implementation that wants
state-of-the-art wall-clock:

1. **Prefiltering** — most candidates never match; the complete-subsequence
   window-trimming prefilter is the difference between nucleo and fzf's
   algorithm, and it needs only `memchr`-class primitives.
2. **Allocation discipline** — one reusable never-zeroed slab per matcher;
   worth 5–10× (the skim harness lesson), more than SIMD on most workloads.
3. **Matrix trimming** — width `n−m+1`, per-row start offsets, single score
   row when positions aren't wanted, 2-bit backtrack cells.
4. **SIMD** — real (4–5× on ASCII) but narrower than advertised;
   intra-sequence row-wise with the log-shift prefix-max is the proven
   shape; inter-sequence length-bucketing was tried and removed.
5. **The harness** — `tick(budget)` + injector + generation counter +
   incremental reparse is what makes a picker _feel_ instant independent of
   matcher throughput.

## Delta: where `sparkles` stands, what the spec takes

| Capability (best-in-field)                                                                      | sparkles today                                                                     | The spec's position                                                                                             |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Affine-gap scoring w/ calibrated constants ([fzf] family)                                       | none                                                                               | port [fff]/[frizbee]'s constants + smart-case (the proven file-picking stack)                                   |
| Typo tolerance ([frizbee])                                                                      | none                                                                               | substitution DP + budgeted prefilter; **verify the budget once on the score path** (fixing the tier divergence) |
| Subsequence prefilter + window trim ([nucleo]/[frizbee])                                        | none                                                                               | greedy case-pair scan, multi-path typo variants                                                                 |
| Never-zeroed reusable matrices ([nucleo]/[frizbee])                                             | `SmallBuffer` exists (`libs/base`)                                                 | fixed-stride matrices in `SmallBuffer`, allocated at matcher construction                                       |
| Grapheme-stable positions ([nucleo])                                                            | `sparkles:base` owns grapheme segmentation; `sparkles:ui` renders cells            | grapheme-proxy pre-segmentation fits the existing stack                                                         |
| Constraint query language ([fff])                                                               | `sparkles.versions.parsing`-style hand parsers; `ParseExpected` in `sparkles:base` | shape-based dispatch grammar, hand-rolled on `readers.d` (fixing the recorded `type:`/`status:` bugs)           |
| Composite re-ranking + breakdown ([fff])                                                        | none                                                                               | ported formula, `Score` breakdown by value                                                                      |
| Frecency + combo boost ([fff])                                                                  | none                                                                               | fff's curves in-memory `@nogc`; persistence via hue's config layer                                              |
| Budgeted, cancellable, incremental host contract ([nucleo]/[helix-integration]/[snacks-picker]) | `sparkles:ui` frame loops (hue)                                                    | library provides pure kernels + refinement probe + budget/cursor entry point; the loop lives in the app         |
| SIMD kernel ([frizbee])                                                                         | none                                                                               | scalar first behind a parity-tested backend seam; layout SIMD-ready from day one                                |

## Sources

Each deep-dive carries its own pinned primary sources; the cross-cutting
artifacts behind this synthesis:

- [frizbee issue #63][frizbee-63], [skim PR #1105][skim-1105],
  [fzf discussion #3491][fzf-3491] — the benchmark-methodology record.
- [noib3/fuzzy-benches][fuzzy-benches] — the independent library-level
  comparison.
- [wired bench-baseline][wired-baseline] — the in-repo measurement
  discipline this survey's rules extend.

<!-- References -->

[fzf]: ./fzf.md
[fzy]: ./fzy.md
[nucleo]: ./nucleo.md
[frizbee]: ./frizbee.md
[fff]: ./fff.md
[telescope-fzf-native]: ./telescope-fzf-native.md
[snacks-picker]: ./snacks-picker.md
[helix-integration]: ./helix-integration.md
[frizbee-63]: https://github.com/Saghen/frizbee/issues/63
[skim-1105]: https://github.com/skim-rs/skim/pull/1105
[fzf-3491]: https://github.com/junegunn/fzf/discussions/3491
[fuzzy-benches]: https://github.com/noib3/fuzzy-benches
[wired-baseline]: ../../specs/wired/bench-baseline.md
