# GPU retrieval — inverted indexes and learned sparse models on device

The other half of the accelerator question: not "match this pattern faster" but
"traverse these posting lists faster". Out of scope for the same reason
[ranked retrieval](./theory/ranked-retrieval.md) is, and recorded so the boundary
is explicit.

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **boundary page**, `[literature]` throughout. Nothing in this catalog's
> decision space depends on it.

---

## What the work is

Two related lines:

**Inverted-index traversal on GPU.** Posting-list intersection and top-`k`
selection map onto data-parallel hardware reasonably well — the lists are sorted
integer sequences and the reduction is a bounded heap. The literature reports
throughput gains for high-QPS serving.

**Learned sparse retrieval.** Models like SPLADE produce weighted term
expansions, turning one query into hundreds of weighted terms. That inflates
traversal cost enough that GPU execution becomes attractive, and it is where most
current attention sits.

## Why neither applies here

1. **The workload is queries-per-second, not latency-for-one.** These systems
   amortise device occupancy across concurrent queries. A single-user editor
   issues one query at a time; there is nothing to batch.
2. **It presupposes an inverted index**, which
   [`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md) concludes is the
   wrong model for code search, and [Lucene](./lucene.md) and
   [tantivy](./tantivy.md) elaborate.
3. **It presupposes ranking by term statistics**, and code relevance is
   structural — definition versus mention, frecency, git status, path distance.
4. **The [platform prerequisite][baseline] is missing** anyway.

## The one transferable idea

**Bounded top-`k` selection is the same problem regardless of hardware.** The GPU
literature's contribution — maintain a bounded heap, use score upper bounds to
skip whole blocks — is the CPU technique from
[PISA](./pisa.md) and the WAND family, and it applies to
`sparkles:fuzzy`'s existing `TopK` without any of the surrounding apparatus. That
is already recorded in [`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md);
this page adds only that GPU work has not changed the underlying idea.

## What this catalog concluded

Out of scope, with no open question left behind.

## Sources

`[literature]`: the GPU inverted-index and learned-sparse-retrieval literature.
The relevant CPU-side techniques are surveyed in [PISA](./pisa.md) and
[`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md).

<!-- References -->

[baseline]: ./sparkles-baseline.md
