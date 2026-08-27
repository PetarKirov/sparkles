# Compressed self-indexes — FM-index, `r`-index, move structures

Substring search **in space proportional to the compressed text**, with the
run-bounded variants that make highly repetitive corpora — versioned history —
the family's natural home.

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **literature page**. No production code-search system surveyed here ships a
> self-index, so there is no implementation to read at a pinned revision the way
> [Zoekt](./trigram-indexes/zoekt.md) or [livegrep](./livegrep.md) offer. Claims
> are `[literature]` unless attributed otherwise, and the mechanics are defined in
> [`theory/succinct-indexes.md`](./theory/succinct-indexes.md).

---

## The idea, and the word "self"

An FM-index stores the Burrows-Wheeler transform of the text plus rank
structures, and supports **backward search**: process the pattern right to left,
narrowing a suffix-array range with two rank queries per character. Because the
BWT is reversible, the index _replaces_ the text rather than accompanying it —
hence "self-index". That is the difference from a suffix array, which is 4–8×
the text **on top of** the text.

## The `r`-index and why repetition is the axis

For a text whose BWT has `r` runs, the `r`-index family bounds space by `O(r)`
rather than `O(n)`. Move structures (Move-r, Movi, b-move) then make LF-mapping
`O(1)` on that run-length-compressed representation, which is what turned the
theory into practical implementations.

The whole family's fit is decided by one ratio:

| Corpus                                                          | `r` relative to `n` | Fit                            |
| --------------------------------------------------------------- | ------------------- | ------------------------------ |
| A heterogeneous source tree                                     | close to `n`        | **Poor** — nothing to compress |
| Many near-identical files (vendored copies, generated variants) | `r` ≪ `n`           | Good                           |
| **Versioned history of one tree**                               | `r` ≪ `n`           | **The design target**          |

This is the substance of [thesis T3][index]: n-gram indexes and self-indexes are
not two implementations of one idea. An n-gram index narrows candidates and
delegates verification, works on any corpus, and degrades to a full scan when no
literal can be extracted. A self-index answers exactly, on any pattern, and its
space depends entirely on how repetitive the corpus is.

## Where the literature comes from, and the caveat

Most recent engineering on this family comes from **pangenomics** — indexing
thousands of near-identical genomes is the canonical `r` ≪ `n` case. That is why
Movi and b-move exist and why their published numbers are on DNA.

The catalog's [scope statement][index] admits this literature for its **index
engineering** and excludes it as an application, and the caveat matters: a
four-symbol alphabet with extreme repetition is not a source tree, and speedups
measured there are `[paper-claim]` about that corpus. Any figure carried into a
code-search argument needs its corpus named.

## Feasibility for Sparkles

- **Querying** — backward search over prebuilt rank structures is read-only bit
  manipulation over a mapped slice: `@safe pure nothrow @nogc` without effort.
- **Construction** — BWT construction plus rank-structure building is the
  expensive, allocation-heavy part, and is a batch job.
- **Update** — the family's real weakness. Insertion into a BWT is hard; the
  practical answer is rebuild or a merge of independently-built indexes.

As with [suffix structures](./suffix-structures.md), the constrained half of the
problem is the easy half. The barrier is construction and maintenance.

## What this catalog concluded

**Not for a working tree**, and the reason is structural rather than a matter of
effort: a source tree is not repetitive enough for `O(r)` to be a win, and it
changes continuously, which is the family's worst update case.

**Possibly for git history**, if history search ever becomes a requirement. There
the corpus is static, append-only, and extremely repetitive — the exact profile
the `r`-index was designed for. Recorded here so that decision starts from
evidence rather than from scratch.

## Sources

`[literature]`: Ferragina & Manzini (FM-index, FOCS 2000); Gagie, Navarro & Prezza
(`r`-index, SODA 2018 / JACM 2020); Nishimoto & Tabei (move structure, ICALP
2021); the Movi and b-move implementation papers. Mechanics in
[`theory/succinct-indexes.md`](./theory/succinct-indexes.md); the space
comparison against a plain suffix array in [livegrep](./livegrep.md).

<!-- References -->

[index]: ./index.md
