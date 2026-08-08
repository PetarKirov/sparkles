# Fuzzy Matching & Picker Architecture

A primary-source survey of **interactive fuzzy finding** — the scoring
algorithms that rank `usr` against 500,000 file paths in milliseconds, the
prefilters and memory disciplines that make that wall-clock real, and the
picker architectures (streaming injection, budgeted rematch, generation-based
cancellation) that make it _feel_ instant. The evidence base for the
[`sparkles:fuzzy` specification][fuzzy-spec], which powers hue's
[picker][hue-picker] (`<leader>ff`, `<leader>/`).

This survey answers six questions:

1. **What is the scoring model the field converged on?** An affine-gap
   alignment with word-boundary/camelCase bonuses and [fzf]'s constant
   table — see [fzf] (where the constants come from), [fzy] (the correct
   two-matrix formulation), and [nucleo] (the reconciliation of both).
2. **How does typo tolerance work?** A substitution transition in the DP
   plus a budgeted multi-path prefilter — [frizbee] is the only subject
   that has it, and [fff] proves it end-to-end for file picking.
3. **Where does the wall-clock actually go?** Prefiltering, allocation
   discipline, and matrix trimming — ranked with measured evidence in the
   [comparison]'s "Ranked leverage".
4. **What does a resident file-search _engine_ add over a matcher?**
   Composite re-ranking, frecency, query history, a constraint query
   language, a deduplicated path arena — [fff].
5. **What must a picker host get right?** The `tick(budget)` / injector /
   generation-counter / incremental-reparse contract —
   [helix-integration] (the native version) and [snacks-picker] (the same
   invariants re-derived without threads).
6. **Which published benchmark numbers can be trusted?** Very few; the
   [comparison] documents the confounds (API tier, whole-process timing,
   hardcoded sleeps) and the reference points that survive.

**Last reviewed:** August 7, 2026

> [!NOTE]
> **Scope.** Eight subjects: the four matcher lineages ([fzf], [fzy],
> [nucleo], [frizbee]), one faithful port surveyed for its benchmark role
> ([telescope-fzf-native]), one engine ([fff] — whose matcher _is_ frizbee,
> via the `neo_frizbee` fork), and two picker hosts ([snacks-picker],
> [helix-integration]). All source citations pin a 40-character commit SHA.
> Deferred, noted not omitted: skim (Rust fzf clone — surveyed only through
> its benchmark threads), fzf-lua (a wrapper around the fzf binary, no
> matcher of its own), zf (Zig; filename-weighted ranking), and the
> completion-engine consumers (blink.cmp).

---

## Master catalog

| Subject                  | Ecosystem | Category                  | Algorithm class                                          | Typo tolerance     | Link                   |
| ------------------------ | --------- | ------------------------- | -------------------------------------------------------- | ------------------ | ---------------------- |
| **fzf**                  | Go        | Interactive finder        | SW variant, no substitution, single matrix (approximate) | none               | [fzf]                  |
| **fzy**                  | C         | Interactive finder        | Gotoh affine, two matrices (optimal)                     | none               | [fzy]                  |
| **nucleo**               | Rust      | Matcher library + harness | SW, no substitution, two matrices (optimal)              | none               | [nucleo]               |
| **frizbee**              | Rust      | Matcher library (SIMD)    | SW **with substitution** (true local alignment)          | **yes** (budgeted) | [frizbee]              |
| **telescope-fzf-native** | C         | Matcher library (port)    | fzf V2 verbatim                                          | none               | [telescope-fzf-native] |
| **fff**                  | Rust      | Resident search engine    | frizbee base + composite re-ranking                      | yes (via frizbee)  | [fff]                  |
| **snacks.picker**        | Lua       | Picker framework          | greedy multi-start, fzf-constant scorer                  | none               | [snacks-picker]        |
| **Helix × nucleo**       | Rust      | Picker host (consumer)    | delegates to nucleo                                      | none               | [helix-integration]    |

---

## Taxonomy

### By ranking-policy placement

| Placement                                | The idea                                                                                                          | Subjects                                          |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| **In the matcher's constants**           | One score; tuning means changing the kernel's config                                                              | [fzf], [fzy], [nucleo] (+ [telescope-fzf-native]) |
| **Layered re-ranking over a base score** | A stock matcher scores; a separate formula adds frecency/filename/git/distance/combo, with a per-result breakdown | [fff]                                             |
| **Post-match additive bonuses**          | Matcher score plus flat frecency/cwd add-ons                                                                      | [snacks-picker]                                   |

### By prefilter

| Prefilter                                   | Mechanism                                                                           | Subjects                                                                                                                  |
| ------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Complete subsequence test + window trim** | in-order scan of the whole needle; DP confined to `[first, last]` occurrence window | [fzf] (`IndexByte`), [nucleo] (`memchr2(c, c−32)` + `memrchr`), [frizbee]/[fff] (SIMD greedy, multi-path per typo budget) |
| **Eligibility check only**                  | any-order or first-hit presence check; full-width DP after                          | [fzy] (`strpbrk`)                                                                                                         |
| **Query planning**                          | atoms sorted by selectivity (entropy) so rejection is early                         | [snacks-picker]                                                                                                           |

### By memory discipline

| Discipline                                                                                  | Subjects                   |
| ------------------------------------------------------------------------------------------- | -------------------------- |
| Reusable slab/matrices, **never zeroed between candidates** (row 0/col 0 structurally zero) | [fzf], [nucleo], [frizbee] |
| Fixed-width rows + per-candidate allocation                                                 | [fzy]                      |
| Bounded top-K heap with evicted-slot reuse                                                  | [snacks-picker]            |
| Chunk-deduplicated path arena feeding the matcher zero-copy                                 | [fff]                      |

### By Unicode model

| Model                                                                                       | Cost profile                                                 | Subjects                                                    |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------- |
| Runes + Latin→ASCII transliteration                                                         | per-match rune materialization                               | [fzf]                                                       |
| **Pre-segmented grapheme proxy** (first codepoint per grapheme; indices = grapheme indices) | one transcode at inject, amortized over rematches            | [nucleo]                                                    |
| **UTF-8 bytes direct**, no normalization                                                    | zero transcode; `a` ≠ `á`; gap cost through multi-byte chars | [frizbee], [fff]                                            |
| ASCII only                                                                                  | —                                                            | [fzy], [telescope-fzf-native] (scores diverge on non-ASCII) |

### By host/incremental architecture

| Mechanism                                                                                                | Subjects                                                                |
| -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `tick(≈10 ms) → Status` polling + immutable snapshots                                                    | [nucleo], [helix-integration]                                           |
| Cooperative coroutines under a global ~10 ms budget                                                      | [snacks-picker]                                                         |
| Generation counter checked by the worker (producers self-terminate)                                      | [helix-integration] (version in `push`), [snacks-picker] (`match_tick`) |
| Append fast path (query extension can only shrink the match set; invalid after a trailing negative atom) | [nucleo] (`Update`), [snacks-picker] (`subset`)                         |
| Rethroughput (full rematch per keystroke, chunked parallel)                                              | [fzf], [fff]                                                            |

---

## Milestones

| Year    | Milestone                                                                                                                                                                              |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2013    | **fzf** ships; its product surface (preview, bindings, shell integration) makes its matcher the field's baseline                                                                       |
| 2014    | **fzy** — the correct two-matrix affine DP, plus [`ALGORITHM.md`][fzy]'s matching/scoring decomposition                                                                                |
| ~2015   | fzf **V2**: the single-matrix Smith-Waterman variant with the calibrated constant table                                                                                                |
| 2021    | **telescope-fzf-native** — fzf's matcher as an embeddable C library (constants byte-identical)                                                                                         |
| 2023    | **nucleo** — fzf's constants on the optimal formulation; the `Injector`/`tick`/`Update` harness; grapheme-proxy indices                                                                |
| 2024    | **frizbee** — SIMD SW with substitution (typo tolerance); later _removes_ inter-sequence bucketing after measurement                                                                   |
| 2024–25 | **snacks.picker** — the picker invariants re-derived in pure Lua                                                                                                                       |
| 2025    | **fff** — the resident engine: frizbee base + composite re-ranking + frecency/combo stores; junegunn's [benchmark correction][frizbee-63] establishes the field's methodology baseline |

---

## Quick navigation

- **"I want the scoring model."** [fzf] (constants + why) → [fzy] (the
  correct DP) → [nucleo] (both reconciled) → [frizbee] (substitution).
- **"I want the engineering that makes it fast."** [nucleo] (prefilter +
  memory) → [frizbee] (SIMD + typo budget) → the [comparison]'s "Ranked
  leverage".
- **"I want the picker host contract."** [helix-integration] →
  [snacks-picker] → the [comparison]'s architecture invariants.
- **"I want the whole-engine view."** [fff] (ranking, frecency, query
  language, arena) → [comparison].
- **"I'm designing `sparkles:fuzzy`."** [comparison] (consensus + delta
  table) → [fff] + [frizbee] (the porting sources) → the
  [`sparkles:fuzzy` spec][fuzzy-spec] and its [delivery plan][fuzzy-plan];
  UI-side requirements in [hue's picker spec][hue-picker].

### Synthesis

- **[Comparison][comparison]** — the head-to-head matrix, the consensus and
  splits, the benchmark-methodology record, ranked leverage, and the delta
  into the spec.

---

## Sources

Every deep-dive pins its citations to a 40-character commit SHA; the
revisions surveyed here are fzf `0579bb0e`, fzy `34b88869`, nucleo
`8c16d47c`, frizbee `e5f0ee20` (+ the `neo_frizbee` 0.11.0 crate), fff
`3a0ce85c`, telescope-fzf-native `b25b749b`, snacks.nvim `fe7cfe98`, helix
`14d6bc0f`. The benchmark-methodology record ([frizbee-63], skim threads,
[noib3/fuzzy-benches][fuzzy-benches]) is collected in the [comparison].

<!-- References -->

[fzf]: ./fzf.md
[fzy]: ./fzy.md
[nucleo]: ./nucleo.md
[frizbee]: ./frizbee.md
[fff]: ./fff.md
[telescope-fzf-native]: ./telescope-fzf-native.md
[snacks-picker]: ./snacks-picker.md
[helix-integration]: ./helix-integration.md
[comparison]: ./comparison.md
[frizbee-63]: https://github.com/Saghen/frizbee/issues/63
[fuzzy-benches]: https://github.com/noib3/fuzzy-benches
[fuzzy-spec]: ../../specs/fuzzy/SPEC.md
[fuzzy-plan]: ../../specs/fuzzy/PLAN.md
[hue-picker]: ../../specs/hue/picker.md
