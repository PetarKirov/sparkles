# Succinct indexes — suffix arrays, BWT, FM-index, `r`-index

Structures that answer "where does this substring occur" **without** literal
extraction, in space proportional to the text or better. The counterweight to the
n-gram family in [`trigram-indexes`](../trigram-indexes/index.md).

> **Last reviewed:** August 28, 2026.

---

## Suffix arrays

The sorted array of all suffix start positions. Because suffixes are sorted,
every occurrence of a pattern occupies a **contiguous range**, found by two binary
searches in `O(m log n)` — or `O(m + log n)` with an LCP array.

Properties that matter here:

- **Any substring, no extraction needed.** Unlike an n-gram index, a suffix array
  answers patterns from which no literal can be extracted.
- **Space is the problem.** `n` integers — 4–8 bytes per text byte, so a 1 GB
  corpus costs 4–8 GB. [livegrep](../livegrep.md) pays exactly this.
- **Construction is `O(n)`** with SA-IS, but with a large constant and a
  non-trivial implementation.

## The Burrows-Wheeler transform

A reversible permutation of the text that clusters equal characters. Its
usefulness here is **LF-mapping**: from a position in the BWT, the position of the
preceding character is computable in `O(1)` from a rank query. Iterating LF walks
the text backwards.

## FM-index — backward search

BWT plus rank structures gives **backward search**: process the pattern
right-to-left, maintaining the suffix-array range that matches the suffix seen so
far. Each step is two rank queries. The result is substring location in space
**proportional to the compressed text** — the "self-index" property: the structure
replaces the text rather than accompanying it.

The cost is that reporting _where_ the occurrences are needs a sampled suffix
array, so there is a space/locate-time dial rather than a single answer.

## The `r`-index and move structures

For **highly repetitive** collections — versioned history, many near-identical
files — the BWT has few _runs_, and the `r`-index family bounds space by `O(r)`,
the number of runs, rather than by `n`. Move structures (Move-r, Movi, b-move)
make LF-mapping `O(1)` on run-length-compressed data.

This is where the family's fit is decided, and it is the substance of
**thesis T3**:

| Corpus                        | Runs `r` relative to `n` | Fit                              |
| ----------------------------- | ------------------------ | -------------------------------- |
| A heterogeneous source tree   | `r` close to `n`         | Poor — no compression to exploit |
| Versioned history of one tree | `r` ≪ `n`                | Excellent — the design target    |

A working tree is the _adversarial_ case for an `r`-index and the natural case for
a scanner. Git history is the reverse. That is a genuinely useful split, and it
suggests that if Sparkles ever indexes anything, history is the corpus where a
compressed self-index earns its keep — not `libs/`.

## Comparison with n-gram indexes

|                                   | n-gram postings              | Suffix array             | FM / `r`-index               |
| --------------------------------- | ---------------------------- | ------------------------ | ---------------------------- |
| Answers patterns without literals | ✗ — degenerates to full scan | ✓                        | ✓                            |
| Space                             | small (a fraction of text)   | 4–8× text                | ≤ text, `O(r)` if repetitive |
| False positives                   | yes — verification required  | none                     | none                         |
| Incremental update                | per-document, easy           | rebuild or complex merge | hard                         |
| Implementation cost               | low                          | medium                   | high                         |

**They answer different questions**, which is the point of T3. An n-gram index is
a _candidate narrower_ that delegates verification to a scanner; a self-index is a
_complete oracle_ that needs no scanner at all.

## Feasibility in a `@nogc` D implementation

- **Suffix array construction** is allocation-heavy but a one-time batch job that
  need not be `@nogc`; _querying_ a prebuilt array is two binary searches over a
  memory-mapped slice, which is trivially `@nogc`.
- **FM-index querying** needs rank structures — wavelet trees or RRR — which are
  read-only bit-vector operations, also `@nogc`-friendly once built.
- **The barrier is construction and maintenance**, not query. That is the opposite
  of the regex-engine barrier, where matching was the constrained part.

## What this catalog concluded

Not for a working tree. The space cost of a suffix array and the update cost of a
self-index are both wrong for a corpus edited every few seconds — [thesis T2][index].
Recorded here so that if history search ever becomes a requirement, the family and
its fit are already understood rather than re-derived.

## Sources

The index deep-dives carry the citations: [livegrep](../livegrep.md),
[compressed-self-indexes](../compressed-self-indexes.md). Historical: Manber &
Myers (1990), Burrows & Wheeler (1994), Ferragina & Manzini (FOCS 2000), Gagie,
Navarro & Prezza (`r`-index, 2018) `[literature]`.

<!-- References -->

[index]: ../index.md
