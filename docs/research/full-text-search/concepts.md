# Concepts and vocabulary

The terms this catalog uses, defined once. Deep-dives assume these and do not
redefine them; where a subject uses a word differently, its page says so
explicitly.

> **Last reviewed:** August 28, 2026.

---

## The six layers

Full-text search is routinely discussed as one problem ("search is fast now") and
is really six, each with its own literature and its own failure modes. Every
deep-dive in this tree is placed against these:

1. **Pattern semantics** — what language the query _denotes_: literal, glob,
   POSIX BRE/ERE, PCRE, a multi-pattern set, approximate (edit-distance
   bounded), structural, or a ranked bag of terms.
2. **Match engine** — the automaton or algorithm that decides membership.
3. **Acceleration** — the prefilter that avoids running the engine at all.
4. **Corpus access** — how bytes reach the engine.
5. **Precomputation** — what an index buys, and what it costs.
6. **Result presentation** — ordering, ranking, caps, context, streaming,
   cancellation, and the latency budget an interactive UI imposes.

A claim that one tool is faster than another is nearly always a claim about
layers 3 and 4 wearing layer 2's name. That is **thesis T1**.

## Pattern semantics

**Literal** — the pattern is bytes; matching is substring search.

**Anchored vs unanchored** — an anchored match must begin at a fixed position;
an unanchored search asks "does this occur _anywhere_ in the haystack". Nearly
every grep is unanchored, and nearly every glob matcher is anchored. Converting
one into the other is not free: an anchored engine made unanchored needs either a
restart-per-position loop or a prefix construct, plus somewhere to record where
the match began.

**Leftmost-first vs leftmost-longest** — when several matches start at the same
position, POSIX takes the longest; Perl-family engines take the one the
alternation lists first. The distinction decides what a highlight covers, and it
is cheaper to implement leftmost-first.

**Captures / submatches** — recording _where_ each parenthesised group matched.
Requires per-thread slot storage in an NFA simulation, and is the single largest
cost a grep does not need: highlighting a hit needs the overall span only.

**Backreferences and lookaround** — `\1`, `(?=…)`, `(?<!…)`. These take the
pattern language outside the regular languages, which is precisely why engines
that guarantee linear time refuse them. The refusal is a design feature, not a
limitation.

**Smart case** — an ad-hoc convention, not a formalism: a pattern containing an
uppercase character is matched case-sensitively; otherwise case-insensitively.
Ubiquitous in interactive tools and defined slightly differently by each one.

## Engine classes

The `@nogc`-viable column is this repository's own question — whether the class
can be implemented in D with no allocation, no exception and no closure, so that
it may run inside a `RawCpuPool` job (see [the baseline][baseline]).

| Class                                      | Worst case                              | Memory                          | `@nogc`-viable?                                                   | Representatives                                                                          |
| ------------------------------------------ | --------------------------------------- | ------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **Backtracking**                           | Exponential                             | Recursion depth, unbounded      | ✗ — depth is input-dependent                                      | PCRE2 interpreter, Oniguruma, `std.regex` backtracking engine                            |
| **Bounded backtracker**                    | Linear-ish, bounded by a visited bitset | Fixed `pattern × haystack` bits | ✓ with a haystack cap                                             | `regex-automata`'s `nfa/thompson/backtrack`                                              |
| **Thompson NFA / Pike VM**                 | `O(m · n)`                              | Two thread lists                | ✓ — the natural fit                                               | RE2, `regex-automata` `pikevm`, `std.regex` `thompson.d`, `sparkles:fuzzy`'s glob engine |
| **One-pass NFA**                           | `O(n)`                                  | Fixed, captures included        | ✓ when the pattern qualifies                                      | `regex-automata` `dfa/onepass`                                                           |
| **Lazy / hybrid DFA**                      | `O(n)` amortised                        | A _cache_ with eviction         | ~ — needs a bounded caller-owned arena and a clear-on-full policy | GNU grep, RE2, `regex-automata` `hybrid`                                                 |
| **Fully compiled DFA**                     | `O(n)`                                  | Exponential in pattern          | ✗ for user input                                                  | `ugrep`'s RE/flex compiler                                                               |
| **Bit-parallel (bitap / shift-or, Myers)** | `O(n · ⌈m/w⌉)`                          | A word or few                   | ✓ — trivially                                                     | `std.regex` `kickstart.d`, agrep, `ugrep -Z`                                             |
| **Glushkov + SIMD**                        | `O(n)` streaming                        | Fixed per compiled block        | ✗ in practice — an ISA-specific compiler                          | Hyperscan / Vectorscan                                                                   |
| **Derivative-based**                       | `O(n)` after construction               | Memoised state set              | ~                                                                 | .NET's non-backtracking engine                                                           |
| **Aho-Corasick**                           | `O(n)` for a whole literal set          | Goto/fail/output tables         | ✓                                                                 | multi-literal alternation everywhere                                                     |
| **Plain literal search**                   | Sublinear in practice                   | None                            | ✓                                                                 | Two-Way, Boyer-Moore, `memmem`                                                           |

"Viable" here is about the _class_, not any given implementation: `std.regex`
implements two of these classes and none of its code is `@nogc`, which is a
separate question the `std-regex.md` (Phase 2) page takes up.

## Acceleration

**Prefilter** — a cheap test that rejects most of the corpus before the engine
runs. The field's consensus is that a prefilter must be cheap enough to _abandon_
when it stops paying, which means measuring its own selectivity at runtime.

**Literal extraction** — deriving, from a compiled pattern, a set of literal
strings at least one of which must appear in any match. Prefix, suffix and inner
sets each enable a different prefilter. This is the bridge between layers 2 and
3, and it is what makes an n-gram index possible at all.

**`memchr` / `memmem` / packed-pair** — single-byte search, substring search, and
the heuristic of picking the two _rarest_ bytes of the needle by a background
frequency table rather than using classical skip tables.

**Teddy** — a SIMD multi-literal prefilter that shuffles nibble-indexed masks;
capped at a small number of short patterns, which is why it is a prefilter and
not an engine.

**Candidate generation** — an index's answer to a prefilter: a _superset_ of
documents that might match, with false positives permitted and verification
delegated to a scanner.

## Corpus access

**`read` vs `mmap`** — the choice is not obvious and every mature tool documents
a heuristic rather than a rule: `mmap` wins on a few large files and loses on
many small ones, where page-table churn exceeds the copy it saves.

**Roll buffer** — the machinery that lets a line span two reads, without which a
line-oriented searcher cannot use a fixed read buffer.

**Binary detection** — deciding a file is not text. The two axes are _what_ is
inspected (a NUL byte, invalid UTF-8, a byte-frequency heuristic) and _when_
(at walk time, cached per file, versus mid-stream, which can stop a search that
has already emitted matches).

**Ignore semantics** — `.gitignore` and its relatives, including the precedence
question of whether an explicit include overrides an ignore.

## Precomputation

**n-gram / trigram index** — an inverted index whose keys are fixed-length byte
sequences. Answers "which documents plausibly contain this pattern" for patterns
from which literals can be extracted, and degenerates to a full scan for those
from which they cannot.

**Posting list** — the document set for one key, usually delta-encoded, and the
unit that intersection and union operate over.

**Suffix array / suffix automaton** — structures supporting arbitrary-substring
location without literal extraction, at a multiple of the corpus in space.

**FM-index, r-index, move structure** — compressed self-indexes: they support
substring location _in space proportional to the compressed text_, and the
`r`-family bounds that space by the number of BWT runs, which is why the
repetitive-text literature cares about them.

**Freshness** — the cost an index pays for a corpus that changes. This, rather
than corpus size, is the variable that decides whether indexing pays; see
**thesis T2**.

## Ranked retrieval

**TF-IDF and BM25** — term-weighting schemes that turn a Boolean match into an
ordering. **Impact ordering** and **Block-Max WAND** are the machinery for
retrieving the top _k_ without scoring every posting.

Whether ranking is even the right frame for code search is one of this tree's
open questions: a developer looking for a definition wants _the_ line, not the
statistically most relevant one.

## Result presentation

**Definition versus mention** — a code-search-specific classification: does this
hit _define_ the symbol, or merely use it. Three families of answer exist, and
they differ by an order of magnitude in both cost and accuracy: a **byte
heuristic** over the hit line, a **parse** (tree-sitter or a language server),
and a **symbol index** built at index time (ctags-driven, as Zoekt does). Which
one a tool picks constrains where the classification can run — a heuristic fits
inside a scan budget, a parse does not.

**Context lines**, **result caps**, **deduplication**, and **stable ordering**
are the rest of layer 6. Stability matters more than it sounds: a result list
that reorders as later matches arrive is unusable interactively even if every
individual answer is correct.

**First-result latency** — the time until the _first_ row can be shown. For an
interactive search this dominates perceived speed, and total scan time is nearly
irrelevant above a few hundred milliseconds because the query has already
changed. That is **thesis T5**.

## Sources

Definitions are drawn from the deep-dives that establish them; each term above is
used with a pinned citation at the point it is analysed. The engine-class
taxonomy follows the structure of `regex-automata`'s meta-engine, examined in
`rust-regex.md` (Phase 2), and is cross-checked against `std.regex`'s two
engines in `std-regex.md` (Phase 2).

<!-- References -->

[baseline]: ./sparkles-baseline.md
