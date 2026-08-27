# .NET's non-backtracking engine (C#)

The one mainstream engine built on **symbolic derivatives** rather than Thompson
construction, and the one that solves a problem the others sidestep: how to run
an automaton over a 1.1-million-code-point alphabet without a
1.1-million-entry transition table.

| Field             | Value                                                                 |
| ----------------- | --------------------------------------------------------------------- |
| Language          | C#                                                                    |
| License           | MIT                                                                   |
| Repository        | [dotnet/runtime][repo] — `System.Text.RegularExpressions/…/Symbolic/` |
| Surveyed revision | `22d4a3b8329dca505095f2b09da0763f52678d8d`                            |
| Category          | Regex engine (standard library)                                       |
| Engine class      | Symbolic derivatives, lazily determinized, DFA→NFA fallback           |
| Guarantee         | Linear time; `RegexOptions.NonBacktracking`                           |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

`RegexOptions.NonBacktracking` gives .NET users a linear-time guarantee opt-in,
without changing the pattern language they already write. Architecturally, it
answers the same question as [RE2][re2] and
[`regex-automata`][rust-regex] — and answers it a different way.

> _"Represents a regex matching engine that performs regex matching using
> symbolic derivatives."_ — [`SymbolicRegexMatcher.cs`][matcher] `[source-verified]`

## How it works — the two ideas worth taking

### Minterms: compressing the alphabet

The transferable idea, stated in its own words:

> _"Minterms are a mechanism for compressing the input character space, or
> 'alphabet', by creating an equivalence class for all characters treated the
> same. For example, in the expression `[0-9]*`, the 10 digits 0 through 9 are
> all treated the same as each other, and every other of the 65,526 characters
> are treated the same as each other, so there are two minterms, one for the
> digits, and one for everything else. Minterms are computed in such a way that
> every character maps to one and only one minterm."_
> — [`MintermClassifier.cs`][minterm] `[source-verified]`

This is the answer to a problem every Unicode-aware automaton has and most
solve by brute force: a DFA transition table indexed by code point is
unaffordable, so index it by **equivalence class** instead. The pattern
determines how many classes exist — usually a handful — and a `MintermClassifier`
maps a character to its class in one lookup.

**For a bounded D engine this is directly applicable.** `sparkles:fuzzy`'s glob
engine stores `charClass` ranges and tests them per instruction; a minterm
classifier would replace that with one table lookup per input unit and a dense
small-integer transition, which is both faster and _more_ bounded — the class
count is known at compile time, from the pattern.

### Derivatives, and laziness

The engine computes a **derivative** of the regex with respect to each input
symbol — the residual pattern still to be matched — rather than pre-building
states. Equal derivatives are the same state, so determinization happens lazily
and only where the input actually goes. `BDD.cs`, `CharSetSolver.cs` and
`BitVectorSolver.cs` implement the set algebra this needs; `ISolver<TSet>` makes
the character-set representation a type parameter, so the same matcher runs over
BDDs or bit vectors.

The engine also **falls back from DFA to NFA mode** when state growth exceeds a
threshold, rather than failing — the same escalation ladder the other engines
have, expressed as one engine with two modes.

### The ten dimensions, briefly

**Pattern language**: .NET syntax minus the constructs that need backtracking
(backreferences, lookaround) — the familiar refusal.
**Engine**: symbolic derivatives with lazy determinization, DFA↔NFA.
**Prefilter**: start-set computation from the pattern.
**Corpus access / concurrency / index**: none — a library.
**Result model**: `SymbolicMatch`, with `DerivativeEffect` carrying capture
updates so captures survive a derivative-based engine at all.
**Unicode**: full, and the minterm machinery is _how_.
**Interactive**: none.
**Measured evidence**: none quoted; the engine's published evaluation is
`[literature]`.

## Strengths

- **Minterms** — alphabet compression that makes Unicode-aware DFAs affordable.
- **A set-solver type parameter**, so the character-set representation is
  swappable.
- **Lazy determinization from derivatives** with a graceful NFA fallback.
- **Captures under a derivative engine** via explicit effects, which is not
  obvious and is why most derivative engines omit them.
- **Opt-in on an existing pattern language**, so users get a guarantee without
  rewriting patterns.

## Weaknesses

- **A managed implementation**, so nothing is portable to D by copying — only
  the design transfers.
- **Set algebra machinery is substantial** (BDDs, solvers, minterm generation)
  relative to a Pike VM.
- **Slower than the backtracking engine on ordinary patterns**, which is why it
  is opt-in rather than the default.

## Key design decisions and trade-offs

| Decision                               | Rationale                                            | Trade-off                                                       |
| -------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------- |
| Symbolic derivatives                   | States arise from the pattern, not from construction | Requires a set algebra the other approaches do not need         |
| Minterms                               | A Unicode alphabet becomes a handful of classes      | A classifier table, and a compile step to compute the partition |
| Set representation as a type parameter | BDD or bit vector, per pattern size                  | Generic code paths, and two representations to validate         |
| Lazy DFA with NFA fallback             | Bounded state growth without failing                 | Two modes with different performance profiles                   |
| Opt-in via `RegexOptions`              | No behaviour change for existing users               | The guarantee is off by default, so most users never get it     |

## What transfers to Sparkles

**One thing, strongly: minterms.** A bounded engine over
[`glob.d`'s opcode set][baseline] currently tests character-class ranges per
instruction. Computing a minterm partition at compile time and storing a
256-entry (ASCII) or classifier-backed (Unicode) map turns that into a single
indexed lookup, with a class count fixed by the pattern — better on both axes
this repository cares about, speed and boundedness.

Derivatives themselves are _not_ recommended: the set algebra is a larger
investment than a Pike VM over a compiled program, and
[`std.regex`][std-regex] already demonstrates the latter in D.

## Sources

Read at `22d4a3b8329dca505095f2b09da0763f52678d8d` `[source-verified]`:

- [`Symbolic/SymbolicRegexMatcher.cs`][matcher] — the engine's own description
- [`Symbolic/MintermClassifier.cs`][minterm] — alphabet compression, with the worked example
- `Symbolic/{BDD,CharSetSolver,BitVectorSolver,ISolver}.cs` — the set algebra
- `Symbolic/{DerivativeEffect,SymbolicMatch,MatchingState}.cs` — captures and state

<!-- References -->

[repo]: https://github.com/dotnet/runtime
[matcher]: https://github.com/dotnet/runtime/blob/22d4a3b8329dca505095f2b09da0763f52678d8d/src/libraries/System.Text.RegularExpressions/src/System/Text/RegularExpressions/Symbolic/SymbolicRegexMatcher.cs
[minterm]: https://github.com/dotnet/runtime/blob/22d4a3b8329dca505095f2b09da0763f52678d8d/src/libraries/System.Text.RegularExpressions/src/System/Text/RegularExpressions/Symbolic/MintermClassifier.cs
[re2]: ./re2.md
[rust-regex]: ./rust-regex.md
[std-regex]: ./std-regex.md
[baseline]: ./sparkles-baseline.md
