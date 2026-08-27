# Ranked retrieval — TF-IDF, BM25, WAND

Turning a Boolean match into an ordering, and the machinery for retrieving the
top _k_ without scoring everything. Included because an inverted index is one of
the answers to precomputation — and excluded from the recommendation only after
asking whether ranking suits code search at all.

> **Last reviewed:** August 28, 2026.

---

## The model

A document is a bag of terms; a query is a bag of terms; relevance is a sum of
per-term weights. **TF-IDF** weights a term by how often it occurs in the document
(term frequency) against how rare it is across the collection (inverse document
frequency).

**BM25** is TF-IDF with two corrections that matter in practice: term frequency
**saturates** (the tenth occurrence adds much less than the second, controlled by
`k₁`), and the score is normalised by document length against the collection
average (controlled by `b`). Those two parameters are the whole tuning surface,
and the defaults have proven robust for decades.

## Retrieving the top _k_ without scoring everything

Scoring every posting for a common term is wasteful when only ten results are
shown. Two families avoid it:

**WAND** and **Block-Max WAND** keep, per term, an upper bound on the score any
remaining posting can contribute. Once the accumulated bound cannot beat the
current _k_-th best, whole blocks of postings are skipped. Block-Max refines this
with per-block maxima rather than one global maximum per term.

**Impact-ordered postings** sort each posting list by contribution rather than by
document id, so reading a prefix of the list yields the highest-scoring documents
first and the tail can be abandoned.

Both are **early-exit strategies** over a bounded top-_k_ heap — structurally the
same shape as `sparkles:fuzzy`'s `TopK`, which already maintains a heap and
already knows its own `retainedCapacity`.

## Why ranking may be the wrong frame for code

This is the honest half of question 10, and the catalog's position is that
**relevance ranking answers a question code search rarely asks.**

- **The user usually wants a specific line, not a relevant document.** "Where is
  `parseQuery` defined" has one right answer; BM25 offers a ranked list of
  documents that mention it a lot.
- **Term frequency is an anti-signal in code.** A file that mentions `buffer`
  forty times is likely to be _less_ interesting than the one that defines it
  once.
- **IDF is distorted by generated and vendored files.** A minified bundle
  containing every identifier flattens the collection statistics for all of them.
- **Length normalisation punishes exactly the files people want.** A short,
  focused module is the answer more often than a long one, and BM25's `b` is
  fighting the opposite battle.

What code search actually ranks by — and what [fff][fff-grep] and hue's picker
both implement — is **frecency, path proximity, git status and structural
role** (is this a definition or a mention), which are all _document-level metadata_
rather than term statistics.

[Zoekt](../trigram-indexes/zoekt.md) is the interesting middle: it ranks, but its strongest signal
is a **ctags-derived symbol index** — a structural fact, not a term statistic.

## Where the machinery still applies

Two pieces transfer even if BM25 does not:

1. **The bounded top-_k_ heap with early exit.** Already how hue's picker works.
2. **Score upper bounds for skipping.** If a grep source ever ranks by a composite
   with per-term bounds, WAND's argument — stop when the best possible remaining
   score cannot enter the heap — applies unchanged, and is exactly the
   optimisation `sparkles:fuzzy`'s `TopK.offer` could exploit.

## What this catalog concluded

**Do not adopt BM25 for content search in hue.** Adopt the retrieval _mechanics_ —
bounded top-_k_, early exit on score bounds — and keep the ranking signals
document-structural: definition-versus-mention, frecency, git status, path
distance. Recorded so the decision is a conclusion rather than an omission.

## Sources

[Lucene](../lucene.md), [tantivy](../tantivy.md), [PISA](../pisa.md) and
[Zoekt](../trigram-indexes/zoekt.md) carry the implementation citations; [fff-grep][fff-grep] and
`docs/specs/hue/picker.md` carry the composite-ranking alternative. Historical:
Robertson & Sparck Jones (BM25), Broder et al. (WAND, 2003), Ding & Suel
(Block-Max WAND, 2011) `[literature]`.

<!-- References -->

[fff-grep]: ../fff-grep.md
