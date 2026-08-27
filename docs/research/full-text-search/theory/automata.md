# Automata — Thompson, Glushkov, determinization, laziness

The machinery under every engine in this catalog, defined once. Written backwards
from what the [engine comparison][engine-comparison] needed.

> **Last reviewed:** August 28, 2026.

---

## Two constructions

**Thompson's construction** builds an ε-NFA compositionally: each regex operator
becomes a small gadget wired to its operands' gadgets with ε-transitions. Size is
linear in the pattern. The ε-transitions are the cost — a simulation must compute
the **ε-closure** of its state set at every step, which is why every Pike VM in
this catalog has a closure routine ([`glob.d`'s][baseline] is `epsilonClosure`).

**Glushkov's construction** builds an NFA with **no ε-transitions** by numbering
the pattern's positions and computing `first`, `last` and `follow` sets. The
result has exactly one state per input symbol occurrence, and every transition
consumes a byte. [Vectorscan][vectorscan] uses this, and it is why its automata
decompose cleanly into literal factors: without ε-edges, the reachability
structure is directly analysable.

The trade is construction cost against simulation cost. Thompson is trivial to
build and needs closure at run time; Glushkov is quadratic to build in the worst
case and needs none.

## Simulating an NFA — the Pike VM

Run **all** live states in lockstep, one input symbol at a time, merging
equivalent states. `std.regex`'s Thompson engine states the property in its own
header: _"looking at each character only once — merging of equivalent threads,
that gives matching process linear time complexity"_.

Cost is `O(m · n)` for a pattern of `m` instructions over `n` input units. The
constant factor is where implementations differ, and it turns on **how the live
set is represented**:

| Representation                   | Per-step cost               | Notes                                                            |
| -------------------------------- | --------------------------- | ---------------------------------------------------------------- |
| Dense bitset, cleared each step  | `O(capacity)`               | What [`glob.d`][baseline] does — cost is capacity, not occupancy |
| Intrusive linked list + freelist | `O(live)` + pointer chasing | What `std.regex` does                                            |
| **Sparse set** (Briggs-Torczon)  | `O(live)`, no clearing      | Two fixed arrays; membership in `O(1)`; never cleared            |

The sparse set is the standard answer and the one this catalog recommends: two
arrays of `capacity` elements, a `dense` list and a `sparse` index, with
membership tested by `sparse[i] < count && dense[sparse[i]] == i`. **No clearing
is needed between steps** — resetting `count = 0` invalidates every entry — which
is precisely the cost `glob.d` currently pays.

## Determinization and its blow-up

Subset construction turns an NFA into a DFA whose states are _sets_ of NFA
states: one transition per input byte, no live-set bookkeeping, and up to `2^m`
states. The exponential is not hypothetical — patterns like `.*a.{20}` reach it
easily.

Three responses appear in this catalog:

1. **Lazy determinization** — build DFA states on demand and cache them, with
   eviction when the cache fills. GNU grep, RE2 and `regex-automata`'s `hybrid`
   all do this. **A cache with eviction is the structure that resists
   fixed-capacity implementation**, which is why it is the hard tier for a `@nogc`
   engine.
2. **Bounded full determinization** — build it all, but fail if it exceeds a
   configured limit (`dfa_size_limit`). Turns the exponential into an error value.
3. **Don't** — Pike VM only, always correct, linear, no cache.

## Alphabet compression — minterms

A DFA transition table indexed by Unicode code point is unaffordable. The usual
answer is to work in bytes and compile UTF-8 into the automaton. The better answer
is [.NET's][dotnet]: partition the alphabet into **equivalence classes the pattern
actually distinguishes**, and index transitions by class.

For `[0-9]*` there are two classes. The class count is a property of the pattern,
known at compile time, which makes this _more_ bounded than range-testing per
instruction as well as faster.

## The superset automaton

[GNU grep][gnu-grep] runs `dfasuperset(dfa)` before the real DFA: a cheaper
automaton that **over-accepts**, used to reject positions without touching the
expensive one. Unlike literal extraction, it works on patterns from which no
literal can be extracted. No other engine surveyed does this, and it is the one
prefilter technique that needs nothing from the pattern's text.

## What this catalog concluded

A **Pike VM over a Thompson program with a sparse-set live list** is the floor:
always correct, linear, allocation-free, and the tier every multi-engine design
keeps as its fallback. Minterms make its per-step work a single lookup. A DFA tier
is an optimisation to be justified by measurement, not a prerequisite.

## Sources

Definitions drawn from the deep-dives that use them: [`std-regex`][std-regex],
[`rust-regex`][rust-regex], [`re2`][re2], [`vectorscan`][vectorscan],
[`dotnet-nonbacktracking`][dotnet], [`gnu-grep`][gnu-grep]. Historical:
Thompson (CACM 1968), Glushkov (1961), and Russ Cox's regexp series
`[literature]`.

<!-- References -->

[engine-comparison]: ../engine-comparison.md
[baseline]: ../sparkles-baseline.md
[std-regex]: ../std-regex.md
[rust-regex]: ../rust-regex.md
[re2]: ../re2.md
[vectorscan]: ../vectorscan.md
[dotnet]: ../dotnet-nonbacktracking.md
[gnu-grep]: ../gnu-grep.md
