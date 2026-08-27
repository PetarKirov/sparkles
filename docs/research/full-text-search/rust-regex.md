# Rust `regex` and `regex-automata` (the RE2 lineage)

Five engines behind one API, chosen per search. The most thoroughly documented
meta-engine in the field, and the reference frame this catalog uses for _which
engine class answers which question_.

| Field             | Value                                                                    |
| ----------------- | ------------------------------------------------------------------------ |
| Language          | Rust                                                                     |
| License           | MIT / Apache-2.0                                                         |
| Repository        | [rust-lang/regex][repo]                                                  |
| Surveyed revision | `72d650cb0a880a01ab6dc2137c0888e8f89740f7` (`regex-automata-0.4.18-3`)   |
| Category          | Regex engine (library)                                                   |
| Engine class      | Meta: one-pass NFA · bounded backtracker · lazy DFA · full DFA · Pike VM |
| Guarantee         | Linear time in the haystack; no backtracking blowup                      |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Regular-expression matching with a **worst-case linear-time guarantee**, by
refusing the constructs that make the guarantee impossible and by picking, per
search, the cheapest engine that can answer the question actually being asked.

### Design philosophy

Three commitments, and each is directly relevant to whether a bounded engine is
writable in D.

**Refusal is a feature.** No backreferences, no lookaround. Those are exactly the
constructs that force backtracking; excluding them is what buys the time bound.
Any `@nogc` engine Sparkles writes inherits this reasoning wholesale — the
refusal is not a simplification of the Rust crate, it is the _source_ of its
guarantee.

**The engine is a runtime choice, not a build choice.** All five are constructed
up front and selected per input.

**Every unbounded thing gets a limit.** `nfa_size_limit`, `dfa_size_limit`,
`hybrid_cache_capacity`, `visited_capacity` — each turns "this pattern is too
big" into an error value or a fallback rather than an allocation spike.

## How it works

### The five engines

`meta::strategy::Core` holds them all:

```rust
struct Core {
    info: RegexInfo,
    pre: Option<Prefilter>,
    nfa: NFA,
    nfarev: Option<NFA>,
    pikevm: wrappers::PikeVM,
    backtrack: wrappers::BoundedBacktracker,
    onepass: wrappers::OnePass,
    hybrid: wrappers::Hybrid,
    dfa: wrappers::DFA,
}
```

`[source-verified]`

| Engine                  | When it runs                                    | Space                                                           | `@nogc`-viable?                        |
| ----------------------- | ----------------------------------------------- | --------------------------------------------------------------- | -------------------------------------- |
| **One-pass NFA**        | Pattern is one-pass **and** captures are wanted | Fixed, captures included                                        | ✓ — the ideal case                     |
| **Bounded backtracker** | Small haystack, captures wanted                 | A `visited` bitset, sized by `min_visited_capacity(nfa, input)` | ✓ with a haystack cap                  |
| **Full DFA**            | Built successfully within `dfa_size_limit`      | Exponential in the pattern                                      | ✗ for user input                       |
| **Lazy DFA (hybrid)**   | Only when the full DFA was _not_ built          | A cache with eviction                                           | ~ — needs a bounded caller-owned arena |
| **Pike VM**             | Always available; the fallback                  | Two thread lists                                                | ✓                                      |

Dispatch is a cascade — `onepass.get(input)`, else `backtrack.get(input)`, else
the DFA tier, else the Pike VM — gated by `is_capture_search_needed(slots.len())`,
because **an engine that cannot report capture positions is fine when nobody asked
for them**. `[source-verified]`

That gate is the finding for question 4. A grep needs the overall match span, not
groups. Dropping captures does not merely simplify a Pike VM implementation — it
changes which engines are eligible at all.

The construction code is also candid about its own costs:

> _"Currently, reverse NFAs don't support capturing groups, so we MUST disable
> them. But even if we didn't have to, we would, because nothing in this crate
> does anything useful with capturing groups in reverse."_ `[source-verified]`

and about waste it has not yet eliminated: building a reverse NFA that both DFAs
may then fail to use is flagged `FIXME … totally wasted work`.

### Literal extraction

`regex-syntax`'s `hir::literal` is the machinery every prefilter in this catalog
depends on, and its module docs state both the promise and the trap:

> _"The main idea is that substring searches can be an order of magnitude faster
> than a regex search. Therefore, if one can execute a substring search to find
> candidate match locations and only run the regex search at those locations,
> then it is possible for huge improvements in performance to be realized. With
> that said, literal optimizations are generally a black art because even though
> substring search is generally faster, if the number of candidates produced is
> high, then it can create a lot of overhead by ping-ponging between the
> substring search and the regex search."_ `[source-verified]`

An `Extractor` produces a `Seq` of `Literal`s — prefix, suffix, or inner — and
the heuristics decide whether a `Seq` is _worth_ using. **A prefilter must be
cheap enough to abandon**, and this crate encodes that as a first-class judgement
rather than an always-on optimisation.

### The ten dimensions, briefly

**Pattern language**: leftmost-first (Perl-style alternation preference), Unicode
by default, no backreferences or lookaround. **Prefilters**: `memchr`,
`memmem`, Teddy, chosen from extracted literals. **Corpus access**: none — it is
a library over `&[u8]`. **Concurrency**: none internally; `Cache` objects are
per-thread. **Index**: none. **Result model**: match spans and optional capture
slots. **Unicode**: full, with `.unicode(false)` as an explicit opt-out that
shrinks automata substantially. **Interactive**: no budget or cancellation;
bounded work comes from the linear-time guarantee, not from a deadline.
**Measured evidence**: the crate's own benchmarks are extensive and are not
quoted here per the [measurement protocol][measurement].

## What transfers to a bounded D engine

1. **The refusal list is the design.** Backreferences and lookaround out ⇒ linear
   time in. Sparkles should adopt the same refusal for the same reason, and say so.
2. **Captures are the expensive axis, not alternation or classes.** A grep that
   needs only the match span can use the simplest engine unconditionally.
3. **The Pike VM is the floor, and it is always correct.** A bounded `@nogc`
   implementation that ships _only_ the Pike VM is a coherent product, not a
   degraded one — this crate keeps it precisely because everything else can fail
   to build.
4. **Limits turn blowup into an error value.** `nfa_size_limit` and friends are
   the prior art for the `globTooComplex`-shaped errors
   [`sparkles:fuzzy`][fuzzy-spec] already returns.
5. **A lazy DFA is a cache, and caches are the hard part** under `@nogc`. It is
   implementable as a fixed caller-owned arena with clear-on-full, but it is a
   second engine, and this crate only reaches for it when a full DFA was not built.

## Strengths

- **A guarantee, stated and kept**, with the refusals that make it possible.
- **Per-search engine selection**, with the capture question as the primary gate.
- **Literal extraction treated as a judgement**, including when _not_ to use it.
- **Every unbounded resource has a configured limit.**
- **Unusually honest internal documentation**, including `FIXME`s about wasted work.

## Weaknesses

- **Large**: five engines, a reverse NFA, and a prefilter tower.
- **Construction cost can dominate** for short searches — several engines are
  built before the first byte is examined.
- **The lazy DFA's cache is a runtime resource** with eviction behaviour that a
  fixed-capacity environment must reproduce or forgo.
- **No interactive contract**: linear time is not the same as a bounded deadline.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                              | Trade-off                                                           |
| ------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| Refuse backreferences and lookaround        | The linear-time guarantee depends on it                | Some real patterns cannot be expressed; PCRE2 exists for those      |
| Five engines chosen at search time          | Each answers a different question at a different price | Build cost, and five implementations to keep semantically identical |
| Capture need as the dispatch gate           | Most searches do not need groups                       | Two answers for one pattern depending on the caller's request       |
| Literal extraction with worth-it heuristics | A bad prefilter is worse than none                     | "A black art", by the module's own admission                        |
| Size limits everywhere                      | Blowup becomes an error, not an allocation spike       | Callers must decide the limits                                      |
| Full DFA preferred over lazy when it builds | No cache management at match time                      | Exponential worst case at build time, bounded only by the limit     |

## Sources

Read at `72d650cb0a880a01ab6dc2137c0888e8f89740f7` `[source-verified]`:

- [`regex-automata/src/meta/strategy.rs`][strategy] — `Core`, engine construction and dispatch
- [`regex-automata/src/meta/regex.rs`][meta-regex] — the configured limits
- [`regex-automata/src/nfa/thompson/backtrack.rs`][backtrack] — `min_visited_capacity`
- [`regex-syntax/src/hir/literal.rs`][literal] — the `Extractor`/`Seq` model and its caveats

Related: RE2 and its lineage in [`re2`](./re2.md); the D-side comparison in
[`std-regex`](./std-regex.md).

<!-- References -->

[repo]: https://github.com/rust-lang/regex
[strategy]: https://github.com/rust-lang/regex/blob/72d650cb0a880a01ab6dc2137c0888e8f89740f7/regex-automata/src/meta/strategy.rs
[meta-regex]: https://github.com/rust-lang/regex/blob/72d650cb0a880a01ab6dc2137c0888e8f89740f7/regex-automata/src/meta/regex.rs
[backtrack]: https://github.com/rust-lang/regex/blob/72d650cb0a880a01ab6dc2137c0888e8f89740f7/regex-automata/src/nfa/thompson/backtrack.rs
[literal]: https://github.com/rust-lang/regex/blob/72d650cb0a880a01ab6dc2137c0888e8f89740f7/regex-syntax/src/hir/literal.rs
[fuzzy-spec]: ../../specs/fuzzy/SPEC.md
[measurement]: ./measurement.md
