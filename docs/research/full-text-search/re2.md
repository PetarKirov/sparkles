# RE2 (C++)

The origin of the modern guarantee: linear time by construction, with
backreferences and generalized assertions removed rather than optimised. Every
other engine in this catalog is positioned relative to this decision.

| Field             | Value                                                |
| ----------------- | ---------------------------------------------------- |
| Language          | C++                                                  |
| License           | BSD-3-Clause                                         |
| Repository        | [google/re2][repo]                                   |
| Surveyed revision | `972a15cedd008d846f1a39b2e88ce48d7f166cbd`           |
| Category          | Regex engine (library)                               |
| Engine class      | Four: one-pass · bitstate · NFA (Pike VM) · lazy DFA |
| Guarantee         | Linear time, bounded memory                          |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Regex matching that is safe to run on untrusted patterns over untrusted input, at
scale, inside a service. The header states the exclusion plainly:

> _"This module uses the re2 library and hence supports its syntax for regular
> expressions, which is similar to Perl's with some of the more complicated
> things thrown away. In particular, backreferences and generalized assertions
> are not available, nor is `\Z`."_ — [`re2/re2.h`][re2-h] `[source-verified]`

That sentence is the ancestor of [`regex-automata`][rust-regex]'s refusal list and
of the refusal any bounded Sparkles engine would adopt.

## How it works

The engine set is visible in the file layout: `onepass.cc`, `bitstate.cc`,
`nfa.cc`, `dfa.cc` — one-pass, a bounded bit-state backtracker, the Pike VM, and
the lazy DFA. `compile.cc` lowers a parsed `Regexp` to a `Prog`; `simplify.cc`
rewrites before compilation. `[source-verified]`

The correspondence with the Rust crate is close enough to be genealogical:
one-pass ↔ `dfa/onepass`, bitstate ↔ `nfa/thompson/backtrack`, nfa ↔ `pikevm`,
dfa ↔ `hybrid`. The Rust crate adds a _fully_ compiled DFA tier; RE2 stops at
lazy.

### The prefilter, as a published interface

RE2 does something none of the others do: it exposes literal extraction as a
**public API and refuses to implement the string search**.

> _"By design, it does not include a string matching engine. This is to allow the
> user of the class to use their favorite string matching engine. The overall
> flow is: Add all the regexps using `Add`, then `Compile` the `FilteredRE2`.
> `Compile` returns strings that need to be matched. […] Then call `FirstMatch`
> or `AllMatches` with a vector of indices of strings that were found in the
> text."_ — [`re2/filtered_re2.h`][filtered] `[source-verified]`

`prefilter.cc` and `prefilter_tree.cc` build the boolean AND/OR tree of required
strings that makes this possible. **This is the same construction a trigram index
needs**: decompose a regex into literal obligations, evaluate them cheaply,
verify survivors. Google Code Search's trigram query planner and fff's bigram
query tree are both this idea with a different substrate underneath, and RE2
states the separation as an explicit design boundary.

### The ten dimensions, briefly

**Pattern language**: Perl-like minus backreferences and generalized assertions.
**Engine**: four, escalating. **Prefilter**: `FilteredRE2`, caller-supplied
matcher. **Corpus access**: none — a library. **Concurrency**: thread-safe;
the DFA cache is the shared resource. **Index**: none, but `FilteredRE2` is the
interface an index plugs into. **Result model**: match plus submatches.
**Unicode**: full, with case-folding tables. **Interactive**: none.
**Measured evidence**: none quoted here.

## Strengths

- **The refusal is the guarantee**, stated as a design boundary in the header.
- **Prefiltering is a published interface** with the string engine deliberately
  left out — the cleanest statement in this catalog of where that seam belongs.
- **Four engines with a genuine escalation ladder**, and memory bounded at each.
- **`RE2::Set`** matches many patterns at once, which is what makes the
  filtered API practical.

## Weaknesses

- **No full-DFA tier**, so steady-state throughput trails engines that compile one.
- **The lazy DFA cache is the shared resource** under concurrency, with the same
  eviction question every cache has.
- **C++ with Abseil**, so re-hosting the code is not on the table for Sparkles —
  only re-deriving the design is.

## Key design decisions and trade-offs

| Decision                              | Rationale                                              | Trade-off                                                  |
| ------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------- |
| Remove backreferences and assertions  | Linear time and bounded memory become provable         | Some patterns are inexpressible; users reach for PCRE      |
| Four engines, escalating              | Cheapest sufficient engine per query                   | Four implementations to keep semantically identical        |
| `FilteredRE2` without a string engine | Callers already have Aho-Corasick, Hyperscan, an index | Two-phase API; the caller must hold the intermediate state |
| Lazy DFA only, no compiled DFA        | Bounded construction cost                              | Slower steady state than a fully compiled automaton        |

## Sources

Read at `972a15cedd008d846f1a39b2e88ce48d7f166cbd` `[source-verified]`:

- [`re2/re2.h`][re2-h] — the exclusion statement
- [`re2/filtered_re2.h`][filtered] — the prefilter contract
- `re2/{onepass,bitstate,nfa,dfa,compile,simplify,prefilter,prefilter_tree}.cc` — the engine set

<!-- References -->

[repo]: https://github.com/google/re2
[re2-h]: https://github.com/google/re2/blob/972a15cedd008d846f1a39b2e88ce48d7f166cbd/re2/re2.h
[filtered]: https://github.com/google/re2/blob/972a15cedd008d846f1a39b2e88ce48d7f166cbd/re2/filtered_re2.h
[rust-regex]: ./rust-regex.md
