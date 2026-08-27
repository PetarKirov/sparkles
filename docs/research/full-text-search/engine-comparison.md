# Engine comparison — what each one prevents, and what it pays

The Phase 2 synthesis. Every engine surveyed is defined by a worst case it
refuses to have, and by what that refusal costs. This page puts the seven side by
side and answers research questions 2, 2a and 2b.

> **Last reviewed:** August 28, 2026.

---

## At a glance

| Engine                         | Class                                | Worst case prevented            | How                                        | Price                                |
| ------------------------------ | ------------------------------------ | ------------------------------- | ------------------------------------------ | ------------------------------------ |
| [PCRE2][pcre2]                 | Backtracking + JIT                   | **none**                        | Step/depth/heap limits stop a runaway      | No time bound; input-dependent stack |
| [Oniguruma][oniguruma]         | Backtracking                         | none                            | Structural caps on the pattern             | Same, plus encoding indirection      |
| [`std.regex`][std-regex]       | Pike VM **and** backtracking         | Partial — per pattern           | Engine chosen by `defaultFactory`          | Backreferences force the backtracker |
| [RE2][re2]                     | one-pass · bitstate · NFA · lazy DFA | Exponential time                | Backrefs and assertions removed            | Some patterns inexpressible          |
| [`regex-automata`][rust-regex] | + full DFA                           | Exponential time **and** memory | Same removals, plus size limits everywhere | Five engines; construction cost      |
| [Vectorscan][vectorscan]       | Glushkov + SIMD literals             | Exponential time                | PCRE subset; decompose to literals         | Slow compile; opt-in start-of-match  |
| [.NET symbolic][dotnet]        | Symbolic derivatives                 | Exponential time                | Same removals; lazy determinization        | Set algebra; slower on easy patterns |

**The pattern is uniform.** Every engine with a time guarantee bought it the same
way — by refusing backreferences and lookaround. No engine achieves the guarantee
while keeping them, and none of the surveyed authors treats this as an open
question.

## The consensus, and the splits

### Consensus: the refusal list

Backreferences and generalized assertions take a pattern outside the regular
languages, and with them goes any hope of a linear-time simulation. RE2 states it
in a header comment; `regex-automata` inherits it; Vectorscan and the .NET
symbolic engine make the same cut. **This is settled, and Sparkles should adopt
it without re-litigating it.**

### Split 1: how many engines

RE2 and `regex-automata` build several and choose per search. `std.regex` builds
two and chooses per _pattern_. Vectorscan builds one complicated one. .NET builds
one with two modes.

The dispatch gate in `regex-automata` is the sharpest finding: engine choice
turns primarily on **whether the caller asked for capture positions**. For a grep,
which never does, most of the ladder is unreachable — and the always-correct
fallback, the Pike VM, is also the simplest to implement.

### Split 2: lazy DFA, full DFA, or neither

RE2 stops at lazy. `regex-automata` prefers a full DFA when it fits under
`dfa_size_limit` and only then falls back to lazy — its debug line is literally
`skipping lazy DFA because we have a full DFA`. ugrep compiles a full DFA up
front. GNU grep runs a _superset_ DFA as a prefilter before the real one.

For a `@nogc` implementation this is the axis that matters most, because **a lazy
DFA is a cache with eviction**, and a cache is the one structure that resists
fixed-capacity implementation. The options are a bounded arena with clear-on-full,
a compile-time-bounded full DFA that errors on overflow, or no DFA tier at all.

### Split 3: what the alphabet is

Almost everyone indexes transitions by byte and handles Unicode by compiling
UTF-8 into the automaton. .NET instead computes **minterms** — equivalence classes
of characters the pattern treats identically — and indexes by class. For `[0-9]*`
that is two classes rather than 1.1 million code points.

This is the most under-adopted idea in the survey, and the one this catalog
recommends taking.

## Answering question 2a — rewrite or re-hosting?

The [`std.regex` deep-dive][std-regex] settles this by reading rather than
assuming, and the answer is **mostly re-hosting**:

- The Pike VM's per-match state is already carved from **one `enforceMalloc`
  block** sized from the compiled pattern, with threads served from a
  preallocated freelist and `GC.addRange` covering only the class header.
- What blocks `@safe nothrow @nogc` is the **compiler** (`parser.d`, GC arrays,
  Tries), a **process-global unsynchronised `matcherCache`**, `enforceMalloc`
  throwing on OOM, a **range-based input model**, and the `dip1000` `scope`
  refusal.

None of those is the matching loop. A bounded engine that compiles to a
fixed-capacity program, takes `const(char)[]`, replaces the freelist with a sparse
set and drops the global class cache is recognisably `thompson.d`.

## Answering question 2b — which opcodes

Framed against [`std.regex`'s thirty][std-regex] and [`glob.d`'s eight][baseline]:

| Needed for a code-search grep                    | Not needed                                        |
| ------------------------------------------------ | ------------------------------------------------- |
| `Char`, `Any`, `CodepointSet`/`Trie`, `OrChar`   | `Backref`                                         |
| `Bol`, `Eol`, `Bof`, `Eof`                       | `GroupStart`, `GroupEnd`                          |
| `Wordboundary`, `Notwordboundary`                | `Lookahead`/`Neglookahead` (Start/End)            |
| `OrStart`, `OrEnd`, `Option`, `GotoEndOr`        | `Lookbehind`/`Neglookbehind` (Start/End)          |
| `Infinite*`, `InfiniteQ*`, `Repeat*`, `RepeatQ*` | `InfiniteBloom*` (an optimisation, not semantics) |
| `Nop`, `End`                                     |                                                   |

Seventeen of thirty, and the thirteen dropped are exactly the capture,
backreference and lookaround set — the same cut every guaranteeing engine makes.

The sub-questions, answered:

- **Leftmost-first**, not leftmost-longest: cheaper, and what users of every
  Perl-family tool already expect.
- **No captures.** The single largest simplification, and what keeps the simplest
  engine eligible.
- **Unanchored search is required**, and `glob.d` is anchored-full-match only: it
  seeds position 0 once and tests `accept` at end of input. Cost is a match-start
  slot plus either a restart loop or a `.*?` prefix thread.
- **Backreferences and lookaround: refuse.** The refusal _is_ the bound.
- **`\b` is wanted** for code search, and needs a look-behind bit the current step
  function does not carry.
- **Counted repetition** by compile-time expansion against the instruction cap,
  erroring like `globTooComplex` — the `nfa_size_limit` pattern.
- **`\p{…}`: probably refuse**, following [fff][fff-grep]'s `.unicode(false)`;
  reconsider only with evidence from real queries.
- **Sparse set, not bitset.** `glob.d` clears `bool[MaxInstructions]` per input
  unit, so its constant factor is program _capacity_ rather than live threads.

## Ranked leverage for a Sparkles engine

1. **Sparse-set thread list** — removes the capacity-proportional per-unit cost,
   changes no semantics.
2. **Unanchored search with a match-start slot** — without it there is no grep.
3. **Minterm alphabet compression** — one lookup per unit instead of range tests.
4. **Literal extraction feeding a packed-pair prefilter** — the layer where
   [T1][index] says the time actually goes.
5. **Compile-time capacity limits with error values** — already the house style.
6. A DFA tier — _only_ with measurements showing the Pike VM is the bottleneck.

## Sources

The seven deep-dives this synthesises: [PCRE2][pcre2], [Oniguruma][oniguruma],
[`std.regex`][std-regex], [RE2][re2], [`regex-automata`][rust-regex],
[Vectorscan][vectorscan], [.NET symbolic][dotnet]. Every claim above is carried by
a `[source-verified]` citation on the corresponding page.

<!-- References -->

[pcre2]: ./pcre2.md
[oniguruma]: ./oniguruma.md
[std-regex]: ./std-regex.md
[re2]: ./re2.md
[rust-regex]: ./rust-regex.md
[vectorscan]: ./vectorscan.md
[dotnet]: ./dotnet-nonbacktracking.md
[baseline]: ./sparkles-baseline.md
[fff-grep]: ./fff-grep.md
[index]: ./index.md
