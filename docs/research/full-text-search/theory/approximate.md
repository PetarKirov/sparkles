# Approximate matching — edit distance, Levenshtein automata, `k`-mismatch

Bounded-error content search. Distinct from the affine-gap subsequence scoring in
[`fuzzy-matching/`][fuzzy] — a different problem with a similar name, and the
seam this catalog states in its [umbrella][index].

> **Last reviewed:** August 28, 2026.

---

## The two problems, and why they get confused

**Subsequence scoring** asks: do the query's characters appear _in order_ in the
candidate, and how good is that arrangement? Gaps are free-ish and ranked. This is
what fzf, fzy, nucleo and `sparkles:fuzzy` do, and it suits **paths**, where the
query is an abbreviation.

**Edit-distance matching** asks: can the candidate be turned into the query with
at most `k` insertions, deletions and substitutions? Gaps are _errors_. This suits
**content**, where the query is a misspelling rather than an abbreviation.

The distinction is not academic. `usr/lcl/bin` should match `usr/local/bin` as a
subsequence; `recieve` should match `receive` within one substitution. Applying
either model to the other's problem produces results users describe as "wrong but
I can't say why".

## Levenshtein automata

For a fixed needle and a fixed `k`, the set of strings within edit distance `k` is
a **regular language**, so it has a DFA. The automaton has `O(k · m)` states
arranged as `k + 1` rows, where row `i` means "i errors used so far": a match
consumes a byte and stays in the row, an error moves down one.

Two consequences:

1. **Approximate matching reduces to automaton simulation**, so an engine that
   already runs a Pike VM can do fuzzy matching by compiling a different program.
   This is a strong argument for one engine serving both of hue's consumers.
2. **The row structure is exactly what `sparkles:fuzzy` already has**: its
   matcher workspace is `TraceCell[(maxCandidateUnits + 1) * (maxTypos + 1)]` —
   `k + 1` rows over the candidate. The shapes coincide.

## Myers' bit-vector algorithm

Computes edit distance in `O(n · ⌈m/w⌉)` by representing the DP column's
_differences_ as bit vectors — see [`bit-parallel`](./bit-parallel.md). For a
needle within a machine word this is a handful of operations per input byte, with
no matrix at all.

**This is the right primitive for a fuzzy grep mode over lines**, and it is much
cheaper than the affine-gap Smith-Waterman `sparkles:fuzzy` runs for paths.

## What the field ships

[ugrep][ugrep]'s `-Z` is the only mainstream grep with built-in approximate
matching, and it does something none of the others do: **it lets the user choose
which edit operations are permitted**, combining a maximum distance cost with
`INS`, `DEL` and `SUB` flags. "Substitutions but not insertions, distance ≤ 2" is
expressible.

[fff][fff-grep]'s fuzzy grep takes a different position: a single typo budget
`(len/3).min(2)`, where a "typo" is a _needle-side deletion_, backed by four
post-match quality filters — minimum score, maximum span, a density floor, and a
gap ceiling — each documented with the concrete false positive it prevents.

The contrast is instructive. ugrep exposes the model; fff hides it behind a budget
and then repairs the results with heuristics. fff's filters exist because a pure
edit budget over a 512-byte line admits far too much — the same reason this
catalog's implementation guidance sets `maxTypos = 0` for grep admission.

## `k`-mismatch versus `k`-difference

**`k`-mismatch** (Hamming) allows substitutions only — no length change, and
therefore no alignment problem. **`k`-difference** (Levenshtein) allows all three.
Mismatch-only is dramatically cheaper and is often what a code-search user means:
a typo is usually a wrong key, not a dropped one.

## What this catalog concluded

A fuzzy content mode should be **`k`-difference via Myers over the stored line
window**, with `k` derived from needle length and capped low, plus fff-style
quality filters. It should not reuse the affine-gap path-scoring matcher: that
solves the neighbouring problem and its filename-bonus arithmetic is wrong for
line candidates anyway — a point the [baseline][baseline] records as a hard
constraint.

## Sources

[ugrep][ugrep] and [fff-grep][fff-grep] carry the `[source-verified]` citations;
[`fuzzy-matching/`][fuzzy] owns the subsequence side. Historical: Myers
(JACM 1999), Ukkonen (1985), Schulz & Mihov (Levenshtein automata, 2002)
`[literature]`.

<!-- References -->

[fuzzy]: ../../fuzzy-matching/index.md
[index]: ../index.md
[ugrep]: ../ugrep.md
[fff-grep]: ../fff-grep.md
[baseline]: ../sparkles-baseline.md
