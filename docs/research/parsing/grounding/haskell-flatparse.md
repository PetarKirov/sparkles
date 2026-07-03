# Grounding ledger — `haskell-flatparse.md`

Verification of `docs/research/parsing/haskell-flatparse.md` against the **local** pinned tree
`$REPOS/haskell/flatparse` `df7e978` (2025-10-08). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                                                                                                     | Type   | Source (local + locator)                         | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------ | ------ |
| 1   | "The 'flat' … refers to the ByteString parsing input … and … the library internals, which avoids indirections and heap allocations whenever possible."                                                    | QUOTE  | `README.md` intro                                | ✓      |
| 2   | "On microbenchmarks, `flatparse` is 2-10 times faster than `attoparsec` or `megaparsec`."                                                                                                                 | QUOTE  | `README.md:20`                                   | ✓      |
| 3   | "pure validators (parsers returning `()`) … not difficult to implement with zero heap allocation."                                                                                                        | QUOTE  | `README.md:20`                                   | ✓      |
| 4   | "No incremental parsing, and only strict ByteString is supported as input."                                                                                                                               | QUOTE  | `README.md:21`                                   | ✓      |
| 5   | Failure vs error split: "parser failure is distinguished from parsing error … used for control flow … we can backtrack … close to the nom library … does not track whether parsers have consumed inputs." | QUOTE  | `README.md`                                      | ✓      |
| 6   | Two flavors: `FlatParse.Basic` vs `FlatParse.Stateful` (`Int` state + reader env for indentation)                                                                                                         | fact   | `src/FlatParse/{Basic,Stateful}.hs`; `README.md` | ✓      |
| 7   | Unboxed-tuple result (`Res#`), GHC primops, `Addr#`/`ByteString` machinery                                                                                                                                | fact   | `src/FlatParse/Basic/` internals                 | ≈      |
| 8   | ST/IO/pure modes via a state-token type parameter                                                                                                                                                         | fact   | `src/FlatParse/` (mode token param)              | ≈      |
| 9   | Little-endian host only; `-fllvm` adds 20–40%                                                                                                                                                             | fact   | `README.md` (non-features + LLVM section)        | ✓      |
| 10  | License                                                                                                                                                                                                   | fact   | `flatparse.cabal` / `LICENSE`                    | ✓      |
| 11  | Sparkles relevance: zero-alloc validators = the `@nogc` target; failure/error ↔ `Expected!(T,E)`                                                                                                          | interp | synthesis                                        | ◯      |
| 12  | Strengths / Weaknesses / trade-off tables                                                                                                                                                                 | synth  | derived                                          | ◯      |

## Discrepancies

None. The four load-bearing quotes (`:20` ×2, `:21`, the failure/error paragraph) are verbatim; the
Basic/Stateful split and the non-features (no incremental, strict ByteString, little-endian) are exact.

## Web-fallback / not-locally-groundable

- **Benchmark multipliers** (2–10×) are quoted from the README's own claim, not independently measured.

## Opinion (◯)

- The "clearest zero-allocation combinator in the survey" framing and the Sparkles-fit mapping;
  Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. flatparse's own quote-rich README grounds the whole page verbatim; the
zero-alloc-validator property (the survey's key Sparkles takeaway) is stated in flatparse's own words.
