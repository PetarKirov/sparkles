# dart_style (Dart)

The only production formatter that solved this survey's exact problem twice and **published the
postmortem**. `dart_style` 3.0.0 "was almost completely rewritten": the old greedy/search
formatter was retained only for legacy code, and the new "tall style" runs an explicit `Solver`
over a tree of `Piece`s with **n-way** (not binary) constraints. Its solver documentation is the
clearest description of how to make combinatorial layout search tractable that exists anywhere in
this survey — including the papers.

|                     |                                                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| **Language**        | Dart                                                                                            |
| **License**         | BSD-3-Clause                                                                                    |
| **Repository**      | [`dart-lang/dart_style`][repo] @ `3b1f30e3` (2026-08-13)                                        |
| **Engine**          | `lib/src/back_end/` — `solver.dart`, `solution.dart`, `solution_cache.dart`, `code_writer.dart` |
| **Model**           | `lib/src/piece/` — 22 piece types (`list`, `chain`, `infix`, `assign`, `control_flow`, …)       |
| **Category**        | AST → `Piece` tree · explicit constraint solver · **zero options**                              |
| **Layout paradigm** | [cost-minimizing search][cost-search], with memoized divide-and-conquer                         |

---

## Overview

### What it solves

Formatting Flutter code — deeply nested declarative widget trees, where a greedy formatter's early
commitment is catastrophic and where the old "short style" produced layouts users disliked. The
project's answer was not to tune; it was to rewrite:

> "This is a large change. Under the hood, the formatter was almost completely rewritten, with the
> codebase now containing both the old and new implementations. The old formatter exists to
> support the older 'short' style and the new code implements the new 'tall' style."
> — [`CHANGELOG.md`][changelog], 3.0.0

And the specific defect being repaired is stated in solver terms:

> "This version introduces a new **n-way constraint system replacing the previous binary
> constraints**. It's mostly an internal change, but allows us to fix a number of bugs that the
> old solver couldn't express solutions to." — [`CHANGELOG.md`][changelog]

That sentence is the whole argument of [the optimality page][optimality] restated by a shipping
project: two candidates per construct — the [`group = flatten x <|> x`][combinators] invariant —
is not enough, and the bugs it causes are not expressible as bugs in the search, only as bugs in
the _language_ the search is given.

### Migration by language version

Rather than break every user, the style is selected by the code's declared language version:

> "The formatter uses the language version of the formatted code to determine which style you get.
> If the language version is 3.6 or lower, the code is formatted with the old style. If 3.7 or
> later, you get the new tall style." — [`CHANGELOG.md`][changelog]

This is the most graceful formatter-migration mechanism in the survey and worth copying by any
project that must change its output.

---

## How it works

### `Piece` and `State`: n-way constraints

A `Piece` is a node in a layout tree, and its splitting options are an ordered list:

```dart
abstract base class Piece with FastHash {
  /// The ordered list of all possible ways this piece could split.
  ///
  /// Piece subclasses should override this if they support being split in
  /// multiple different ways.
  List<State> get additionalStates => const [];
```

with each state carrying its own price:

```dart
final class State implements Comparable<State> {
  static const unsplit = State(0, cost: 0);
  static const split = State(255);
  /// How much a solution is penalized when this state is chosen.
  final int cost;
```

— [`lib/src/piece/piece.dart`][piece]

So a `ListPiece` is not "flat or broken"; it can be unsplit, split-one-per-line, or split with the
last argument hugging, each with a distinct cost. That is [arbitrary choice][optimality] in the
APEP taxonomy, implemented in a shipping tool.

**Pinning** is the second mechanism, and it encodes context-sensitive style rules the cost model
alone cannot:

> "This is used when a piece which otherwise supports multiple ways of splitting should be eagerly
> constrained to a specific splitting choice because of the context where it appears. For example,
> if conditional expressions are nested, then all of them are forced to split because it's too
> hard to read nested conditionals all on one line."
> — [`piece.dart`][piece]

A rule like "nested ternaries always break" is a _readability_ judgement that no penalty could
express robustly. Pinning is how a search-based formatter keeps such rules without corrupting its
cost model — a technique neither clang-format nor dfmt has.

### The solver's four tractability techniques

`solver.dart`'s header comment is the best short treatment of the subject in this survey:

> "This problem is combinatorial over the number of pieces and each of their possible states, so
> it isn't feasible to brute force. There are a few techniques we use to avoid that:
>
> - The initial state for each piece has no line splits or only mandatory ones. Thus, it tries
>   solutions with a minimum number of line splits first.
> - Solutions are explored in priority order. We explore solutions with the lowest cost first.
>   This way, as soon as we find a solution with no overflow characters, we know it will be the
>   best solution and can stop.
> - When selecting states for pieces to expand solutions, we only look at pieces in **the first
>   line containing overflow characters or invalid newlines**.
> - If a subtree Piece is sufficiently isolated from surrounding content (usually this means it is
>   on its own line), then we **hoist that entire subtree out, format it with a separate Solver**,
>   and then insert the result into the Solution. We also **memoize** the result of doing this and
>   use it across different Solutions. This enables us to both divide and conquer the Piece tree
>   and solve portions separately, while also reusing work across different solutions."
>   — [`lib/src/back_end/solver.dart`][solver]

Techniques 1 and 2 are standard best-first search. **Techniques 3 and 4 are the contribution**:

- _Expand only the first overflowing line._ Pieces that already fit cannot be improved by
  splitting them, so the branching factor collapses to the pieces that actually matter. This is a
  domain-specific admissible pruning rule, and it is the analogue of
  [scalafmt's `dequeueOnNewStatements`][cost-search] — but sound rather than needing an exception.
- _Hoist and memoize isolated subtrees._ A `Piece` on its own line is independent of the
  surrounding layout, so it can be solved once by a sub-`Solver` and the result reused across
  every candidate solution. `solution_cache.dart` exists for exactly this. **No other system in
  wave 1 memoizes sub-solutions** — clang-format, dfmt and scalafmt all re-explore — and it turns
  one global search into many small independent ones. The one other system in this survey that does
  the same is [SDC's `sdfmt`][d-landscape], which keeps a `Continuation[RuleValues]` map of paused
  expansions; two independent arrivals, one of them in D.

### The budget, again

```dart
/// To ensure the solver doesn't go totally pathological on giant code, we cap
/// it at a fixed number of attempts.
///
/// If the optimal solution isn't found after this many tries, it just uses the
/// best it found so far.
const _maxAttempts = 10000;
```

— [`solver.dart`][solver]

A fifth independent instance of [the incompleteness budget][budget], and — notably — **the
best-documented one**. Where clang-format's `50'000` and dfmt's `10_00` are bare constants,
dart_style says in a doc comment what the cap is for and what happens when it bites. The
behaviour is still silent to the user, but it is not silent to the reader of the code.

---

## 1. Input model & fidelity

**Dart AST (`package:analyzer`) → a `Piece` tree**, built by `lib/src/front_end/`. Comments are
lifted into `leading_comment.dart` pieces and attached during piece construction, so dart_style
does pay [the attachment cost][attachment] — it is an AST-based reprinting formatter.

**Behaviour on unparseable input:** refuses.

**Round-trip:** the test suite formats twice and requires stability.

## 2. Layout IR & break decision

**The `Piece` tree _is_ the IR**, and it is the most sophisticated one here: n-way states with
per-state costs, plus pinning. Width is a hard `pageWidth` with overflow characters counted into
the objective — so, like [dfmt][dfmt] and [clang-format][clang-format], both a constraint and a
cost.

## 3. Alignment, indentation & vertical rhythm

Handled by `code_writer.dart` as pieces are realized. The tall style deliberately prefers block
indentation over alignment — a style decision that also happens to make the solver's job easier,
since alignment couples a subtree's layout to its column and defeats [hoisting][hoisting].

## 4. Comments, trivia & preservation

`comment_type.dart` plus `leading_comment.dart`; comments become pieces so they participate in
layout rather than being pasted in afterwards. Blank lines are preserved in `sequence.dart`.

Escape hatch: marker comments, added in the same 3.0.0 release for the tall style.

## 5. Configurability, opinionation & config discovery

**Zero style options**, like [gofmt][gofmt] and [zig fmt][zig-fmt]. `config_cache.dart` reads only
the page width and language version from the surrounding package. The project's position is that
the formatter's value is the absence of choice.

## 6. Integration surface & output contract

**Whole document.** `dart format` with `--output=none --set-exit-if-changed` for CI. No
`TextEdit[]`, no range formatting, no cursor — the weakest dimension, and the price of a global
solver.

---

## Strengths

- **N-way constraints**, with a shipped explanation of why binary was insufficient.
- **Pinning** cleanly separates hard readability rules from soft cost.
- **Memoized subtree hoisting** — the best tractability idea in the survey.
- **Sound pruning** (expand only the first overflowing line), unlike scalafmt's patched heuristic.
- **Language-version-gated migration**, a genuinely humane way to change a formatter's output.
- **Zero options.**
- **The design is documented in the source**, which is rare here.

## Weaknesses

- **Capped and silent** at 10,000 attempts, like everything else in [its family][cost-search].
- **No edit output, range formatting, or cursor** — poor LSP ergonomics.
- **Refuses unparseable input.**
- **Two formatters in one codebase** (short + tall) is a large maintenance burden, acknowledged in
  the changelog.
- **AST-based**, so it pays the comment-attachment cost that token-spine designs avoid.

---

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                           | Trade-off                                                                               |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **N-way `State` per `Piece`**, each with a cost          | Binary constraints "couldn't express solutions to" real bugs                        | Larger state space; the solver needs every technique below to stay tractable            |
| **Pinning** a piece to a state from context              | "too hard to read nested conditionals all on one line" — a rule no cost can express | Style rules leak into the model as hard constraints, outside the cost function          |
| **Expand only pieces on the first overflowing line**     | Pieces that fit cannot be improved by splitting                                     | Requires the notion of "first overflow", so the solution must be partially realized     |
| **Hoist isolated subtrees to a sub-solver, and memoize** | Divide and conquer; reuse work across candidate solutions                           | Only valid when a subtree is layout-independent — hence the preference for block indent |
| **Prefer block indent over alignment** (tall style)      | Readability for deeply nested Flutter code                                          | Also chosen because alignment would defeat hoisting — style and algorithm are coupled   |
| **Cap at 10,000 attempts**                               | "doesn't go totally pathological on giant code"                                     | Silently non-optimal output; the user is never told                                     |
| **Select style by language version**                     | Migration without breaking existing packages                                        | Both formatters must be maintained indefinitely                                         |
| **Zero options**                                         | The product is the absence of debate                                                | No adaptation to existing conventions                                                   |

---

## What a D formatter should take

**Take, if D ever adopts search (proposal M9): memoized subtree hoisting.** It is the technique
that makes a global solver affordable, it is not in clang-format or dfmt, and it composes with a
greedy engine too — a subtree that is alone on its line can always be solved independently.

**Take: pinning.** D has direct analogues of "nested conditionals always break" — chained
`static if`, nested template constraints, `version` blocks — and pinning is how to express them
without corrupting a cost model.

**Take: language-version-gated style selection.** If a D formatter ever changes its output, this
is how to ship it without a repo-wide diff on every user at once.

**Take as confirmation:** binary `group` is not enough for real code. dart_style is the empirical
evidence for what [Bernardy argued theoretically][optimality], and the two arrived independently.

---

## Sources

- [`dart-lang/dart_style`][repo] @ `3b1f30e3a0b568281f72320bcb248a2f0cd8ce79`:
  `lib/src/back_end/{solver,solution,solution_cache,code_writer,code}.dart` ·
  `lib/src/piece/{piece,list,chain,infix,assign,control_flow,sequence,leading_comment,…}.dart` (22 types) ·
  `lib/src/front_end/` · `lib/src/{dart_formatter,comment_type,config_cache}.dart`
- [`CHANGELOG.md`][changelog] — the 3.0.0 rewrite and the n-way constraint note

**Related deep-dives in this tree:**
[Cost & search][cost-search] · [Optimality][optimality] · [Combinators][combinators] ·
[Concepts][concepts] · [clang-format][clang-format] · [dfmt][dfmt] · [Comparison][comparison] ·
[The proposal][proposal]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/dart-lang/dart_style/tree/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79
[solver]: https://github.com/dart-lang/dart_style/blob/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79/lib/src/back_end/solver.dart
[piece]: https://github.com/dart-lang/dart_style/blob/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79/lib/src/piece/piece.dart
[changelog]: https://github.com/dart-lang/dart_style/blob/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79/CHANGELOG.md

<!-- Theory docs -->

[cost-search]: ./theory/cost-and-search.md
[budget]: ./theory/cost-and-search.md#the-incompleteness-budget
[optimality]: ./theory/optimality.md
[combinators]: ./theory/combinators.md

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[comparison]: ./comparison.md
[proposal]: ./dmd-fmt-proposal.md
[hoisting]: #the-solvers-four-tractability-techniques

<!-- System deep-dives -->

[clang-format]: ./clang-format.md
[d-landscape]: ./d-landscape.md
[dfmt]: ./dfmt.md
[gofmt]: ./gofmt.md
[zig-fmt]: ./zig-fmt.md
