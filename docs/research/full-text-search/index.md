# Full-Text Search

How a byte pattern is found in a corpus of text — from `grep`'s DFA over a single
file, through ripgrep's literal prefilters and Zoekt's positional trigram shards,
to compressed self-indexes, ranked inverted indexes and GPU automata engines —
and which of those techniques a D implementation inside Sparkles can actually
carry.

> **Last reviewed:** August 27, 2026.

> [!NOTE]
> **Status: in progress.** The tree is being built in the phases its execution
> plan sets out. Pages listed below without a link are planned, not written; the
> phase column says when each arrives. Nothing here is a findings page until it
> is linked.

---

## Why this survey exists

Sparkles can already answer _"which of these 500,000 **paths** did you mean"_ —
that is [`sparkles:fuzzy`](../../specs/fuzzy/SPEC.md) and hue's picker. It cannot
answer _"which of these 2 GB of file **contents** match this pattern"_. Nothing
in the tree opens a second file looking for a byte pattern, and the
[baseline](./sparkles-baseline.md) records exactly how far that gap runs.

There are **two** consumers waiting on the answer, and one engine has to serve
both. The first is cross-file: the grep source behind the picker's `<leader>/`,
which does not exist. The second already exists — twice. hue's in-document search
is implemented separately in each backend, and the two
[disagree on case](./sparkles-baseline.md#in-document-two-implementations-that-disagree):
one is case-sensitive and GC-allocating, the other ASCII-case-insensitive and
`@nogc`. Replacing that with a single backend-independent matcher built on
`sparkles:fuzzy` is an outcome of this survey, not a by-product — a third
divergent implementation would entrench the defect rather than close it.

Serving them means choosing an engine class, a prefilter strategy, an I/O strategy
and possibly an index — under constraints most of the field does not work under:
`@safe pure nothrow @nogc`, fixed-capacity caller-owned workspaces, and a
matching path that must run inside a closure-free job with no allocation and no
exceptions. The purpose of this catalog is to make those choices from evidence
rather than instinct.

## The six layers

The subject is routinely discussed as one problem and is really six. Every page
here is placed against them, and they are defined in
[concepts](./concepts.md#the-six-layers):

1. **Pattern semantics** — what the query denotes
2. **Match engine** — the automaton that decides membership
3. **Acceleration** — the prefilter that avoids running the engine
4. **Corpus access** — how bytes reach the engine
5. **Precomputation** — what an index buys and costs
6. **Result presentation** — ordering, caps, streaming, cancellation, latency

A claim that one tool is faster than another is nearly always a claim about
layers 3 and 4 wearing layer 2's name.

## This survey answers sixteen questions

**Semantics and engines**

1. What does each tool's pattern language actually denote, and where do POSIX
   BRE/ERE, PCRE, RE2-style regular languages and Hyperscan's PCRE subset diverge
   in ways a user can observe?
2. Which engine class does each tool use, and what worst case is it protecting
   against — catastrophic backtracking, DFA state explosion, or memory blow-up?
3. What precisely makes `std.regex` unusable inside a `@safe nothrow @nogc` job:
   the engine, the IR arena, the character-class tables, per-match thread
   allocation, the input-range machinery, or the exception surface? The answer
   decides whether a bounded engine here is a **rewrite or a re-hosting**.
4. Which of `std.regex`'s thirty IR opcodes does a code-search grep actually
   need, and what does each cost against the eight the
   [existing bounded NFA](./sparkles-baseline.md#the-bounded-nfa-that-already-ships)
   already has?

**Acceleration and cost**

5. Where does the wall-clock actually go in an unindexed scan, and how much of
   the observed spread between `grep`, `rg` and `ugrep` is engine versus
   prefilter versus I/O versus output formatting?
6. What is the minimum literal information extractable from a regex, and how do
   the field's prefilters — `memchr`, Two-Way, Teddy, Aho-Corasick, bitap —
   exploit it?
7. Which parts of this problem does specialized hardware genuinely win, and by
   how much under an honest end-to-end measurement including transfer?

**Indexes**

8. When does an index pay for itself? What are the crossover points in corpus
   size, query rate and mutation rate, and what does each index cost in build
   time, RAM, on-disk size and staleness?
9. How do trigram postings, suffix arrays and BWT-runs indexes differ in what
   queries they can answer **at all** — not merely how fast?
10. What does ranked retrieval add over Boolean matching, and when is ranking the
    wrong frame for code?

**The interactive surface**

11. What must a search backend expose so an interactive UI stays responsive:
    first-result latency, streaming, cancellation, backpressure, result caps,
    stable ordering?
12. How does a picker choose between plain, regex and fuzzy modes, and what
    happens on zero hits — is auto-detection a _mode_ decided once, or a _ladder_
    that tries, falls back and annotates?
13. Is a definition-line classifier a heuristic, a parser, or an index? The
    field's answers span two orders of magnitude in cost, and Sparkles has a
    third option — tree-sitter — that neither end of that range has.

**Method and outcome**

14. Which published benchmark numbers survive scrutiny, and what corpus and
    methodology protocol should this repository adopt? See
    [measurement](./measurement.md).
15. What is the smallest staged path from the [baseline](./sparkles-baseline.md)
    to a credible content search behind hue, and which techniques are realistic
    in D with LDC?
16. What must one engine expose so that **cross-file** and **in-document** search
    are the same matcher under two callers — incremental re-query as the user
    types, match positions for highlighting, a shared case rule, and bounded work
    — rather than the three divergent implementations the tree has today?

## Five theses to establish or refute

Each resolves in the comparison with evidence, or is recorded as unresolved.

- **T1 — the engine is rarely the bottleneck.** The dominant costs are candidate
  rejection, byte delivery and match _handling_; the regex engine runs on a small
  fraction of the corpus. If true, the ranked leverage is prefilter → I/O →
  formatting → engine, in that order.
- **T2 — indexing is a mutation-rate bet, not a size bet.** An index converts
  scan cost into build-plus-staleness cost. A working tree edited every few
  seconds is the adversarial case, and the field's answer is hybrid, not either/or.
- **T3 — compressed self-indexes and n-gram indexes answer different questions.**
  One locates arbitrary substrings in compressed space; the other narrows
  candidates and delegates verification. Their fit differs between a
  heterogeneous source tree and versioned history.
- **T4 — accelerator wins are real but arrive with a transfer tax and a compile
  tax.** The honest question is bytes/second end to end against a CPU baseline
  with an equally good prefilter.
- **T5 — interactive search is a latency-distribution problem, not a throughput
  problem.** First-result latency and cancellation determine perceived speed;
  total scan time is nearly irrelevant once the query has changed. The
  [fuzzy-matching](../fuzzy-matching/index.md) tree reached this from the other
  side, and the two syntheses should agree.

## Seams with existing catalogs

Three trees already touch this territory. The split is by **organ**, not by
project — one upstream can appear in two catalogs under two lenses, as
`parsing/helix.md` and `fuzzy-matching/helix-integration.md` already do.

| Tree                                              | What it owns                                                                                                 | Seam                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`fuzzy-matching/`](../fuzzy-matching/index.md)   | Ranked **subsequence** scoring over a candidate list: fzf, fzy, nucleo, frizbee, fff's matcher, picker hosts | That tree answers "given 500k paths and the query `usr`, which rank highest". This one answers "given 2 GB of content and a pattern, which bytes match". fzf appears here only as a live-grep _host_. **fff is the deliberate exception**: its fuzzy matcher belongs there, its `fff-core/src/grep/` engine belongs here — it is the stated design source for hue's grep budget, cursor and mode-fallback behaviour, and the two organs share almost nothing. |
| [`parsing/hyperscan.md`](../parsing/hyperscan.md) | Hyperscan as a scanning/lexing engine for the syntax pipeline                                                | Extend rather than move. Cited here for automata decomposition; this tree adds Vectorscan's portable fork, its licensing, and the streaming-mode contract that matters for search but not for lexing.                                                                                                                                                                                                                                                         |
| [`parsing/theory/`](../parsing/theory/index.md)   | Formal languages, derivatives, general parsing                                                               | Regex-specific automata theory — Thompson versus Glushkov, determinization blow-up, lazy-DFA caching, bit-parallel simulation — belongs in [`theory/`](./theory/index.md) here, cross-linked rather than duplicated.                                                                                                                                                                                                                                          |

A fourth seam is internal: **approximate matching**. Edit-distance-bounded search
over content is in scope; affine-gap subsequence scoring is not — that is the
fuzzy-matching tree's subject, and the similar name is the only thing the two
share.

## The catalog

| Page                                                                                                                                                                                                                                                                                                                                                                                           | Category                             | Phase             |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ | ----------------- |
| [Concepts & vocabulary](./concepts.md)                                                                                                                                                                                                                                                                                                                                                         | Framing                              | 0 ✅              |
| [Measurement protocol](./measurement.md)                                                                                                                                                                                                                                                                                                                                                       | Method                               | 0 ✅              |
| [Sparkles baseline](./sparkles-baseline.md)                                                                                                                                                                                                                                                                                                                                                    | System under improvement             | 0 ✅              |
| [Theory](./theory/index.md)                                                                                                                                                                                                                                                                                                                                                                    | Framing                              | 0 ✅ (pages in 3) |
| [gnu-grep](./gnu-grep.md) · [ripgrep](./ripgrep.md) · [ugrep](./ugrep.md) · [git-grep](./git-grep.md) · [silver-searcher](./silver-searcher.md) · [hypergrep](./hypergrep.md) · [grep-long-tail](./grep-long-tail.md)                                                                                                                                                                          | Scanners                             | 1 ✅              |
| [fff (grep engine)](./fff-grep.md)                                                                                                                                                                                                                                                                                                                                                             | Scanner — hue's stated design source | 1 ✅              |
| [rust-regex](./rust-regex.md) · [std-regex](./std-regex.md) · [re2](./re2.md) · [pcre2](./pcre2.md) · [vectorscan](./vectorscan.md) · [oniguruma](./oniguruma.md) · [dotnet-nonbacktracking](./dotnet-nonbacktracking.md) · [engine-comparison](./engine-comparison.md)                                                                                                                        | Engines                              | 2 ✅              |
| [literal-prefilters](./literal-prefilters.md) · [multi-pattern](./multi-pattern.md)                                                                                                                                                                                                                                                                                                            | Primitives                           | 2 ✅              |
| [automata](./theory/automata.md) · [bit-parallel](./theory/bit-parallel.md) · [string-matching](./theory/string-matching.md) · [approximate](./theory/approximate.md) · [succinct-indexes](./theory/succinct-indexes.md) · [ranked-retrieval](./theory/ranked-retrieval.md)                                                                                                                    | Theory                               | 3 ✅              |
| [trigram-indexes](./trigram-indexes/index.md) ([google-codesearch](./trigram-indexes/google-codesearch.md), [zoekt](./trigram-indexes/zoekt.md)) · [livegrep](./livegrep.md) · [suffix-structures](./suffix-structures.md) · [compressed-self-indexes](./compressed-self-indexes.md) · [lucene](./lucene.md) · [tantivy](./tantivy.md) · [pisa](./pisa.md) · [embedded-fts](./embedded-fts.md) | Indexes                              | 4 ✅              |
| `gpu-automata` · `gpu-retrieval` · `hardware-automata` · `wide-simd`                                                                                                                                                                                                                                                                                                                           | Acceleration                         | 5                 |
| `corpus-access` · `unicode-semantics` · `approximate-search` · `structural-search` · `interactive-contracts`                                                                                                                                                                                                                                                                                   | Systems & semantics                  | 6                 |
| `comparison` · `recommendations`                                                                                                                                                                                                                                                                                                                                                               | Synthesis                            | 7                 |

## Reading paths

**"I want to know whether we can write a bounded regex engine in D."**
[baseline](./sparkles-baseline.md#the-bounded-nfa-that-already-ships) →
[concepts § engine classes](./concepts.md#engine-classes) → [std-regex](./std-regex.md) →
[rust-regex](./rust-regex.md) → `recommendations`.

**"I want to know whether we should build an index."**
[concepts § precomputation](./concepts.md#precomputation) → [trigram-indexes](./trigram-indexes/index.md) →
[zoekt](./trigram-indexes/zoekt.md) → [compressed-self-indexes](./compressed-self-indexes.md) → theses T2 and T3 in `comparison`.

**"I am implementing hue's grep source."**
[baseline](./sparkles-baseline.md) → [fff-grep](./fff-grep.md) → [ripgrep](./ripgrep.md) →
`corpus-access` → `interactive-contracts` → `recommendations`.

**"I need to make a performance claim."**
[measurement](./measurement.md), first and in full.

## Scope

**In:** unindexed scanners; regex engine internals; literal and multi-pattern
acceleration; corpus-access mechanics; Unicode semantics and their measured cost;
index families and their operations; hardware acceleration; edit-distance-bounded
approximate search; structural search **as a boundary**, to establish what regex
cannot express; interactive-search contracts; benchmark methodology; and an audit
of this repository's own surface.

**Out:** subsequence/fuzzy-picker scoring (owned by
[`fuzzy-matching/`](../fuzzy-matching/index.md)); vector databases and ANN index
internals; bioinformatics read alignment and network intrusion detection **as
applications** — their literature is cited for index and automata engineering
only; database query planning beyond the FTS extension surface; web-scale
crawling and query understanding; LLM/RAG pipeline design; and writing search
code in `libs/` during the research phase.
