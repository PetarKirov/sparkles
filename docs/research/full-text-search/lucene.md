# Apache Lucene (Java)

The reference inverted index. Surveyed as the **boundary** of this catalog rather
than a candidate: it answers a question code search does not ask, and its
segment/merge machinery is the clearest statement of what an index costs to keep
fresh.

| Field      | Value                                |
| ---------- | ------------------------------------ |
| Language   | Java                                 |
| License    | Apache-2.0                           |
| Repository | [apache/lucene][repo]                |
| Category   | Inverted index with ranked retrieval |
| Ranking    | BM25 by default                      |
| Unit       | Analyzed **terms**, not byte n-grams |

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **boundary page**, written from documented architecture rather than a pinned
> source read: no decision in this catalog turns on Lucene's internals, and the
> [scope statement][index] excludes ranked document retrieval as a target. Claims
> are `[literature]`.

---

## Why it is not the answer here

Lucene indexes **terms produced by an analyzer** — tokenized, lowercased,
stemmed, stopworded. That is the right model for prose and the wrong one for
code, for three reasons this catalog has already met:

1. **A code query is often not a term.** `parseQuery(` , `->` , `\d{3}` and
   `foo_bar` are all things a developer searches for and none survives tokenization
   intact.
2. **Substring search is not term search.** Finding `Query` inside `parseQuery`
   requires either an n-gram analyzer — which reinvents the trigram index, worse —
   or a wildcard query, which Lucene handles by term enumeration.
3. **BM25 ranks the wrong thing**, for the reasons set out in
   [`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md): term frequency is
   an anti-signal in code, and length normalisation punishes the short focused
   files people actually want.

## The two ideas worth carrying

**Segments and merges.** A Lucene index is a set of immutable segments; a write
creates a new one, and background merges consolidate them. Deletions are
tombstones applied at read time. This is the field's most-refined answer to
"how does an index stay fresh", and its cost is visible: merge policy, merge
scheduling, and write amplification are all first-class operational concerns.

For [thesis T2][index] that is the point. **Freshness is not free, and the
machinery to buy it is substantial** — which is exactly why a per-file filter
(the [ugrep][ugrep] shape) is attractive for a working tree: one changed file,
one rewritten filter, no merge policy at all.

**Finite-state term dictionaries.** Lucene stores its term dictionary as an FST,
which makes prefix and wildcard enumeration cheap and the dictionary small. The
same structure appears in [tantivy](./tantivy.md) via the `fst` crate, and it is
the one Lucene component with an obvious analogue in a bounded implementation —
an FST is a read-only automaton over a mapped slice.

## What this catalog concluded

Out of scope, decisively. Recorded because "why not just use an inverted index"
is the first question anyone asks about content search, and the answer —
_because code queries are substrings, not terms, and code relevance is structural,
not statistical_ — deserves to be written down once rather than re-argued.

## Sources

`[literature]`: Lucene's published architecture documentation and the BM25
literature cited in [`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md).
The concrete alternatives this catalog prefers are in
[`trigram-indexes/`](./trigram-indexes/index.md).

<!-- References -->

[repo]: https://github.com/apache/lucene
[index]: ./index.md
[ugrep]: ./ugrep.md
