# Theory

The algorithms the scanners, engines and indexes in this catalog are built from,
written up once so the subject pages can name them without re-deriving them.

> **Last reviewed:** August 27, 2026.

> [!NOTE]
> These pages are written **backwards from what the surveys needed**, not forward
> from a textbook table of contents — a deliberate sequencing choice recorded in
> the execution plan. A theory page exists here because a scanner or engine
> deep-dive cited the algorithm and the citation needed somewhere to land. Pages
> arrive in Phase 3; the scope below is fixed now so the deep-dives written
> before them can point at stable names.

---

## Scope

Six areas, each of which at least one surveyed subject depends on:

**Automata** — Thompson's construction versus Glushkov's, subset construction and
why determinization blows up, the lazy DFA as a cache over that blow-up, and the
Pike VM as the linear-time simulation that avoids it. This is the page the
[regex-subset question](../concepts.md#engine-classes) resolves against.

**Bit-parallel matching** — shift-or / bitap, Myers' bit-vector edit distance,
BNDM, and the general trick of simulating an automaton in the bits of a machine
word. Cheap, bounded, allocation-free, and the natural first implementation for
any pattern that fits in a word.

**String matching** — Boyer-Moore and Horspool, Two-Way and its constant-space
guarantee, Commentz-Walter, and Aho-Corasick for the whole-literal-set case.
The substrate under every prefilter in the tree.

**Approximate matching** — Levenshtein automata, `k`-mismatch and `k`-difference
algorithms, and the bounded-edit-distance search that `ugrep -Z` and agrep
expose. Distinct from the affine-gap subsequence scoring in
[`fuzzy-matching/`](../../fuzzy-matching/index.md), which is a different problem
with a similar name — see the seam in the [umbrella](../index.md).

**Succinct indexes** — suffix arrays and automata, the Burrows-Wheeler transform,
LF-mapping and backward search, the FM-index, and the run-bounded `r`-index and
move-structure family that the repetitive-text literature produced.

**Ranked retrieval** — TF-IDF and BM25, WAND and Block-Max WAND, impact-ordered
postings. Included because an inverted index is one of the answers to layer 5,
and excluded from the recommendation frame only after the evidence says whether
ranking suits code search at all.

## Why theory is a sub-tree rather than a section

Two reasons, both practical. The algorithms are cited from _several_ subject
pages each — Aho-Corasick appears in a scanner, an engine and a multi-pattern
prefilter — so they need one address rather than three restatements. And they are
the pages that carry runnable examples: an algorithm is the kind of
claim a sixty-line D program can settle, and the examples belong beside the
definition rather than beside a tool that happens to use it.

## Relationship to `parsing/theory/`

[`parsing/theory/`](../../parsing/theory/index.md) owns formal languages,
derivatives and general parsing. **Regex-specific automata theory belongs here** —
Thompson versus Glushkov, determinization cost, lazy-DFA caching, bit-parallel
simulation — and cross-links to the derivatives page rather than duplicating it.
The rule of thumb: if a parser generator would care about it, it is over there;
if only a matcher would, it is here.
