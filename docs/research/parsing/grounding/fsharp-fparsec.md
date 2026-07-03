# Grounding ledger — `fsharp-fparsec.md`

Verification of `docs/research/parsing/fsharp-fparsec.md` against the **local** pinned tree
`$REPOS/fsharp/fparsec` `156cbd7` (2022-12-04). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                         | Type  | Source (local + locator)                     | Status |
| --- | ------------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------------- | ------ |
| 1   | "FParsec is a parser combinator library for F#."; "recursive-descent text parsers for formal grammars."       | QUOTE | `readme.md:3-5`                              | ✓      |
| 2   | Features: "support for context-sensitive, infinite look-ahead grammars,"                                      | QUOTE | `readme.md`                                  | ✓      |
| 3   | "automatically generated, highly readable error messages,"                                                    | QUOTE | `readme.md:9`                                | ✓      |
| 4   | "an embeddable, runtime-configurable operator-precedence parser component," (Unicode-hyphen in source)        | QUOTE | `readme.md:12`                               | ✓      |
| 5   | "an implementation thoroughly optimized for performance,"; Unicode; "efficient support for very large files," | QUOTE | `readme.md`                                  | ✓      |
| 6   | `Parser<'a,'u>` type with user state `'u` (context-sensitive parsing)                                         | fact  | `src/FParsec/Primitives.fs`                  | ✓      |
| 7   | Mutable **`CharStream`** with explicit backtracking (`attempt`/`>>=?`)                                        | fact  | `src/FParsec/CharStream.fs`; `Primitives.fs` | ✓      |
| 8   | Rich `ErrorMessageList` drives the readable error messages                                                    | fact  | `src/FParsec/Error.fs`                       | ✓      |
| 9   | Built-in `OperatorPrecedenceParser` ([Pratt]-style)                                                           | fact  | `src/FParsec/OperatorPrecedenceParser.fs`    | ✓      |
| 10  | Two-package split: C# core `FParsecCS` (speed) + F# `FParsec`                                                 | fact  | repo layout `FParsecCS`/`FParsec`            | ≈      |
| 11  | License: code 2-clause BSD; docs CC BY-NC 3.0; bundled Unicode data under the Unicode license                 | fact  | `License.txt` + doc/Unicode notices          | ✓      |
| 12  | Strengths / Weaknesses / trade-off tables                                                                     | synth | derived                                      | ◯      |

## Discrepancies

None. The Feature quotes are verbatim (`readme.md:3-5,9,12`; note `:12` uses a Unicode hyphen "‐"
in "operator‐precedence", so an ASCII grep misses it — confirmed present). The `Parser<'a,'u>` user
state, mutable `CharStream`, `ErrorMessageList`, and `OperatorPrecedenceParser.fs` are all in `src/`.

## Web-fallback / not-locally-groundable

- **Adoption / "best-in-class error messages" reputation** — the "highly readable error messages" claim
  is FParsec's own (verbatim); the comparative "best-in-class" judgment is editorial.

## Opinion (◯)

- The error-message-quality contrast with Parsec/Megaparsec; the `OperatorPrecedenceParser`↔Pratt tie-in;
  Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. Every Feature quote is verbatim (incl. the Unicode-hyphen OPP line at `:12`);
the user-state `Parser<'a,'u>`, CharStream, ErrorMessageList, OPP component, and the precise multi-part
license are all grounded in the pinned tree.
