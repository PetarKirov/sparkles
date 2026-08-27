# tantivy (Rust)

Lucene's model in Rust, and the most plausible "just use a library" answer to
content search. This page records why it is still the wrong shape — and the two
components of it that are the right shape.

| Field             | Value                                      |
| ----------------- | ------------------------------------------ |
| Language          | Rust                                       |
| License           | MIT                                        |
| Repository        | [quickwit-oss/tantivy][repo]               |
| Surveyed revision | `7b0e97a0b6d311af92da8f1e187982201964c684` |
| Category          | Inverted index library                     |
| Ranking           | BM25                                       |

> **Last reviewed:** August 28, 2026.

---

## What it is

> _"Fast full-text search engine library written in Rust"_ — [`README.md`][readme]
> `[source-verified]`

A **library**, not a server — which is precisely why it deserves a page where
[Lucene](./lucene.md) gets a boundary note. If an inverted index were the right
model for hue, tantivy is what one would embed, and the objection would have to be
about fit rather than operational weight.

## Why it is still the wrong shape

The objection is the same as Lucene's and does not soften by being a library:
tantivy indexes **analyzed terms**, and code search is **substring** search over
**structurally** ranked results. An n-gram tokenizer can approximate substrings,
but it reinvents [the trigram index](./trigram-indexes/index.md) inside a term
dictionary, with worse constants and a BM25 scorer bolted to the front.

The segment-and-merge freshness cost is inherited too — see
[thesis T2][index].

## The two components that _are_ the right shape

**`fst`.** tantivy's term dictionary is a finite-state transducer
([BurntSushi/fst][fst], cloned at `5907b4739793b3d5d7061eaa3f85274e09769d6a`), and
an FST is a read-only automaton over a memory-mapped slice: prefix enumeration,
fuzzy term lookup via a Levenshtein automaton intersection, and a dictionary far
smaller than the sum of its keys. **This is `@nogc`-shaped by construction** —
querying an FST allocates nothing — and it is the one piece of the inverted-index
world that transfers cleanly.

Its fuzzy-term trick is worth noting against
[`theory/approximate.md`](./theory/approximate.md): intersecting an FST with a
Levenshtein automaton enumerates all dictionary terms within edit distance `k`,
which is the same automaton-intersection idea a bounded fuzzy matcher would use,
applied to a dictionary rather than a line.

**Bounded top-`k` collection with early exit.** tantivy's collectors implement the
WAND-family skipping described in
[`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md). The mechanics —
maintain a heap, track a score bound, stop when the bound cannot enter the heap —
are model-independent, and `sparkles:fuzzy`'s `TopK` is already the same shape
without the bound.

## What this catalog concluded

Not adopted. But two ideas are carried forward into the
recommendations: **FSTs as a read-only mapped automaton** if a dictionary is ever
needed, and **score-bound early exit** on the existing `TopK` if composite
ranking ever becomes expensive enough to matter.

## Sources

Read at `7b0e97a0b6d311af92da8f1e187982201964c684` `[source-verified]` for the
positioning statement; architecture claims are `[literature]` from the project's
documentation. FST mechanics: [BurntSushi/fst][fst].

<!-- References -->

[repo]: https://github.com/quickwit-oss/tantivy
[readme]: https://github.com/quickwit-oss/tantivy/blob/7b0e97a0b6d311af92da8f1e187982201964c684/README.md
[fst]: https://github.com/BurntSushi/fst
[index]: ./index.md
