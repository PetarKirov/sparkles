# Multi-pattern search — Aho-Corasick, Commentz-Walter, Teddy

Finding any of _N_ literals in one pass. The primitive under `-F` with many
patterns, under alternation-of-literals, and — the reason it matters here —
under every index's verification step.

| Field             | Value                                                   |
| ----------------- | ------------------------------------------------------- |
| Primary source    | [BurntSushi/aho-corasick][repo]                         |
| Surveyed revision | `6c0abf5681bfc30bb9d8f7f52b68a350b436fffa` (`1.1.5-2`)  |
| Category          | Acceleration primitive                                  |
| Algorithms        | Aho-Corasick (NFA/DFA) · Teddy (SIMD) · Commentz-Walter |

> **Last reviewed:** August 28, 2026.

---

## Why a search catalog needs it

Three separate places in this survey reduce to "find any of these strings":

- **Alternation of literals.** `foo|bar|baz` is a multi-pattern problem, and
  [fff][fff-grep] dispatches exactly this case to Aho-Corasick.
- **[GNU grep][gnu-grep]'s `kwset`**, built from the literals a pattern must
  contain — the Commentz-Walter lineage, which is Aho-Corasick with
  Boyer-Moore-style skipping grafted on.
- **Index verification.** A trigram index answers with candidate _files_; the
  survivors must then be scanned for the actual literals, which is the same
  problem again.

## Aho-Corasick

A trie of the patterns plus **failure links**, giving one state transition per
input byte regardless of how many patterns are being searched — the property that
makes it scale where running _N_ substring searches does not.

The crate makes an unusual contribution beyond the classical algorithm:

> _"Finally, unlike most other Aho-Corasick implementations, this one supports
> enabling leftmost-first or leftmost-longest match semantics, using a
> (seemingly) novel alternative construction algorithm."_ — [`src/lib.rs`][ac-lib]
> `[source-verified]`

That matters more than it sounds. Classical Aho-Corasick reports matches in the
order the automaton finds them, which is neither of the semantics a regex user
expects. Getting leftmost-first out of it is what allows a literal alternation to
be _substituted_ for the regex engine rather than merely used as a prefilter.

**Space** is the cost: a trie with a transition table per state. The crate offers
NFA (compact, indirect) and DFA (dense, fast) representations — the same
space/time dial a D implementation would face, with the DFA form being
`states × 256` and therefore the one that needs a capacity bound.

## Teddy

A SIMD prefilter for **small sets of short literals**, using `pshufb`-style
nibble-indexed mask lookups to test many positions at once. `aho-corasick` ships
it under `src/packed/`, and notes it is used automatically:

> _"callers shouldn't need to interface with this module directly, as the primary
> `AhoCorasick` searcher will use these routines automatically as a prefilter
> when applicable."_ `[source-verified]`

Teddy's constraints are the finding: it caps at a small number of patterns and
short prefixes. That is not a limitation to be engineered away — it is why Teddy
is a _prefilter_ and Aho-Corasick is the _verifier_. The internals are surveyed
in [`parsing/hyperscan.md`][hs], where Teddy originates.

## Commentz-Walter

Aho-Corasick's trie with Boyer-Moore's skipping: instead of consuming every byte,
skip ahead by the shortest pattern's length when the current window cannot match.
Faster than Aho-Corasick on small pattern sets with long patterns, worse as the
set grows (the minimum pattern length shrinks and so does the skip). GNU grep's
`kwset` is this lineage.

## Choosing for a `@nogc` D implementation

| Algorithm                   | Preprocessing          | Space                          | Scales with _N_?    | Verdict                                |
| --------------------------- | ---------------------- | ------------------------------ | ------------------- | -------------------------------------- |
| _N_ × substring search      | none                   | none                           | ✗ — linear in _N_   | Fine for _N_ ≤ 2–3                     |
| **Aho-Corasick (NFA form)** | trie + failure links   | states × transitions, indirect | ✓                   | The general answer; needs a state cap  |
| Aho-Corasick (DFA form)     | dense transition table | states × 256                   | ✓                   | Fast, memory-hungry; cap it or refuse  |
| Commentz-Walter             | trie + skip tables     | trie + 256                     | partly              | Wins on few long patterns              |
| Teddy                       | mask tables            | small, fixed                   | ✗ — small sets only | A prefilter, not a matcher; needs SIMD |

For hue's grep the honest scope note is that **multi-pattern is not on the
critical path for `PKS2`**: plain mode has one needle, fuzzy mode has one, and
regex-with-alternation is the regex engine's problem. It becomes relevant only if
a bigram or trigram index lands (`PKM6`), where verification is exactly this
problem — which is why the page exists now and the implementation does not.

## Sources

Read at `6c0abf5681bfc30bb9d8f7f52b68a350b436fffa` `[source-verified]`:

- [`src/lib.rs`][ac-lib] — the automaton, and leftmost-first/leftmost-longest construction
- [`src/packed/mod.rs`][packed] — Teddy as an automatic prefilter
- `src/packed/teddy/` — the SIMD searcher

Deferred: Teddy internals to [`parsing/hyperscan.md`][hs]; `kwset` to
[GNU grep][gnu-grep] (its source is in gnulib and was not read).

<!-- References -->

[repo]: https://github.com/BurntSushi/aho-corasick
[ac-lib]: https://github.com/BurntSushi/aho-corasick/blob/6c0abf5681bfc30bb9d8f7f52b68a350b436fffa/src/lib.rs
[packed]: https://github.com/BurntSushi/aho-corasick/blob/6c0abf5681bfc30bb9d8f7f52b68a350b436fffa/src/packed/mod.rs
[hs]: ../parsing/hyperscan.md
[gnu-grep]: ./gnu-grep.md
[fff-grep]: ./fff-grep.md
