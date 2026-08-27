# Suffix structures — arrays, automata, and what they cost

A short page: the theory is in
[`theory/succinct-indexes.md`](./theory/succinct-indexes.md) and the only
production consumer surveyed here is [livegrep](./livegrep.md). This page records
the family's boundary and why it stops there.

> **Last reviewed:** August 28, 2026.

---

## The family

| Structure               | Space                         | Query                      | Built by                                                |
| ----------------------- | ----------------------------- | -------------------------- | ------------------------------------------------------- |
| **Suffix array**        | 4–8× text                     | `O(m log n)` binary search | [livegrep](./livegrep.md)                               |
| Suffix array + LCP      | 5–9× text                     | `O(m + log n)`             | —                                                       |
| Suffix automaton / DAWG | `O(n)` states, large constant | `O(m)`                     | —                                                       |
| Suffix tree             | 10–20× text                   | `O(m)`                     | nobody, at this scale                                   |
| **FM-index**            | ≤ text (compressed)           | `O(m)` backward search     | [compressed-self-indexes](./compressed-self-indexes.md) |

## Why the middle of the table is empty

Suffix trees and automata give the best asymptotic query time and are absent from
every production code-search system surveyed. The reason is uniform: **constant
factors and pointer chasing**. A suffix tree's `O(m)` lookup touches `m` nodes
scattered across a structure ten to twenty times the corpus; a suffix array's
`O(m log n)` binary search touches `log n` cache lines over a flat array that
memory-maps cleanly. On real hardware the "slower" structure wins, and it wins by
enough that nobody ships the faster one.

That is a recurring lesson in this catalog — see also
[classical skip tables losing to a two-byte frequency probe][prefilters] — and it
is why the [measurement protocol][measurement] insists on real corpora rather than
complexity classes.

## The one property that matters for a decision

**No false positives.** A suffix structure locates actual occurrences, so there is
no verification scan — unlike the n-gram family, where a candidate is only a
maybe. That is what livegrep buys with its 3–5× multiple, and it is what makes
the family viable for patterns from which no literal can be extracted.

## Feasibility in D, briefly

Construction (SA-IS) is a batch job that need not be `@nogc`. **Querying a
prebuilt array is two binary searches over a memory-mapped slice** — trivially
`@safe pure nothrow @nogc`, needing no allocator and no workspace. So if Sparkles
ever wanted this, the constrained half of the problem is the easy half. The
barrier is space and rebuild cost, not the matching contract.

## What this catalog concluded

Out of scope for a working tree, for the reasons
[`livegrep`](./livegrep.md) makes concrete. Recorded so the boundary is a
decision rather than an omission, and so that a future history-search
requirement — where the corpus is static and repetitive — finds the family
already scoped.

<!-- References -->

[prefilters]: ./literal-prefilters.md
[measurement]: ./measurement.md
