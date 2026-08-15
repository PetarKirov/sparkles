# Grounding ledger — dart-style.md

Verification against `$REPOS/dart/dart_style` @ `3b1f30e3a0b568281f72320bcb248a2f0cd8ce79`
(**depth-1 clone** — no history, so release dates are unsourceable).

## Verified verbatim (✓)

| Claim                                                                                                                                 | Source                               |
| ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| The 3.0.0 rewrite quote ("almost completely rewritten … old 'short' style … new 'tall' style")                                        | `CHANGELOG.md:633-638`               |
| The **n-way constraint** quote ("replacing the previous binary constraints … bugs that the old solver couldn't express solutions to") | `CHANGELOG.md:1384-1386`             |
| Language-version gating ("3.6 or lower … 3.7 or later")                                                                               | `CHANGELOG.md:644-648`               |
| `abstract base class Piece` + the `additionalStates` doc comment                                                                      | `lib/src/piece/piece.dart:18-28`     |
| The **pinning** doc comment ("too hard to read nested conditionals all on one line")                                                  | `piece.dart:30-38`                   |
| `final class State` with `unsplit = State(0, cost: 0)`, `split = State(255)`, and `final int cost`                                    | `piece.dart:266-280`                 |
| The solver's **four techniques** doc comment, quoted in full                                                                          | `lib/src/back_end/solver.dart:19-43` |
| `const _maxAttempts = 10000;` with its doc comment                                                                                    | `solver.dart:12-17`                  |
| `back_end/` file list; the 22 `piece/` types                                                                                          | `ls`                                 |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                                             | Status      | Note                                                                                                                                                  |
| --- | ----------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "A `ListPiece` … can be unsplit, split-one-per-line, or split with the last argument hugging"                     | ⚠           | **Illustrative; `list.dart` was not read.** The _mechanism_ (n-way states) is verified; these specific states are the survey's plausible example      |
| 2   | "`solution_cache.dart` exists for exactly this [memoization]"                                                     | ⚠           | The file exists and the solver's doc comment describes memoization; **the file was not read**                                                         |
| 3   | "**No other system in the survey memoizes sub-solutions**"                                                        | ✓→**FALSE** | **Contradicted by this survey's own [d-landscape](./d-landscape.md)**: SDC's `sdfmt` memoizes via `pausedExpansions` keyed on `RuleValues`. See D-DS1 |
| 4   | "the best-documented one [incompleteness budget]"                                                                 | ◯           | Comparative editorial claim across the six budgets found                                                                                              |
| 5   | "Comments are lifted into `leading_comment.dart` pieces"                                                          | ⚠           | File exists; not read                                                                                                                                 |
| 6   | "the tall style deliberately prefers block indentation over alignment … which also makes the solver's job easier" | ◯           | The style claim is from the changelog's framing; **the causal link to hoisting is the survey's inference**                                            |
| 7   | "The test suite formats twice and requires stability"                                                             | 🌐          | Not verified                                                                                                                                          |
| 8   | "Behaviour on unparseable input: refuses"                                                                         | ⚠           | Inferred                                                                                                                                              |
| 9   | "marker comments, added in the same 3.0.0 release"                                                                | ⚠           | `CHANGELOG.md:671, 696` mention marker comments; the exact semantics were not read                                                                    |
| 10  | "Zero style options … `config_cache.dart` reads only the page width and language version"                         | ⚠           | Inferred from the file name and the changelog; not read                                                                                               |
| 11  | "the analogue of scalafmt's `dequeueOnNewStatements` — but **sound** rather than needing an exception"            | ◯           | The survey's comparison; defensible from the two doc comments but asserted by neither project                                                         |
| 12  | The three "What a D formatter should take" recommendations                                                        | ◯           | Editorial                                                                                                                                             |

## Discrepancies

- **D-DS1 (row 3) — an incorrect exclusivity claim.** `dart-style.md` says memoized sub-solutions
  are unique in the survey. `sdfmt` (`$REPOS/dlang/sdc/src/format/writer.d`) maintains
  `Continuation[RuleValues] pausedExpansions` for the same purpose, and this tree documents it in
  [`d-landscape.md`](../d-landscape.md). **Fix the sentence in `dart-style.md`** to "no other
  system in wave 1", or drop the exclusivity.

## Not verified here

- `solver.dart` beyond its header comment; `solution.dart`, `solution_cache.dart`,
  `code_writer.dart`; all 22 piece types; the whole `front_end/`.
- The 2024 date for 3.0.0 — unsourceable from a depth-1 clone.
