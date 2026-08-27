# PISA (C++)

A research platform for **query-processing performance** rather than a search
product. Surveyed for one thing: it is where the early-exit and posting-encoding
techniques are measured honestly, which is the part of the ranked-retrieval world
this catalog does carry forward.

| Field             | Value                                      |
| ----------------- | ------------------------------------------ |
| Language          | C++                                        |
| License           | Apache-2.0                                 |
| Repository        | [pisa-engine/pisa][repo]                   |
| Surveyed revision | `e88b09fedba2da15e3afa2345648b4407cb105f1` |
| Category          | Inverted-index query processing (research) |

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **short page**. PISA's subject — how fast can a ranked disjunctive query be
> processed over an inverted index — is outside this catalog's
> [scope][index]. It is included because its _methodology_ is the field's best,
> and because two of its techniques generalise beyond ranking.

---

## What it contributes

**Posting-list compression as a measured design space.** PISA implements many
encodings — variable-byte, Simple, PForDelta, Elias-Fano, partitioned Elias-Fano
— behind one interface, so they can be compared on the same corpus with the same
queries. That is a rare thing: most systems ship one encoding and assert it is
good.

**Query processing as a measured design space.** Likewise for the traversal
strategies: exhaustive OR, WAND, Block-Max WAND, MaxScore, and the block-max
variants, all comparable.

**A reproducibility discipline** — standard collections, published parameters,
and separated index-build and query phases — which is the same separation the
[measurement protocol][measurement] here demands, arrived at for the same reason.

## The two ideas that generalise

**Score upper bounds enable skipping.** Keep, per term, a bound on the best score
any remaining posting can contribute; once the bound cannot displace the current
`k`-th result, skip. The idea does not depend on BM25 — it depends only on having
a _monotone bound_, which a composite ranking like hue's
(frecency + git status + definition-ness) also has. Recorded in
[`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md) as the one piece of
the ranked-retrieval apparatus worth keeping.

**Elias-Fano for monotone sequences.** A near-optimal encoding for a sorted list
of integers with `O(1)` random access — which is what a posting list is, and also
what a **sorted line-offset table** is. If Sparkles ever stores per-file line
indexes on disk, this is the encoding, and it is a self-contained bit-twiddling
routine rather than a framework.

## What this catalog concluded

Not adopted; the subject is ranked document retrieval, which
[`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md) concludes is the
wrong frame for code. Two techniques carried forward — monotone score bounds for
early exit, and Elias-Fano for monotone integer sequences — both of which are
usable without adopting any of the surrounding model.

## Sources

Read at `e88b09fedba2da15e3afa2345648b4407cb105f1` for positioning
`[source-verified]`; technique claims are `[literature]` from the PISA papers and
the Block-Max WAND literature cited in
[`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md).

<!-- References -->

[repo]: https://github.com/pisa-engine/pisa
[index]: ./index.md
[measurement]: ./measurement.md
