# Grounding ledger — `ocaml-angstrom.md`

Verification of `docs/research/parsing/ocaml-angstrom.md` against the **local** pinned tree
`$REPOS/ocaml/angstrom` `76c5ef5` (2024-09-11). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                                                                                                                                          | Type  | Source (local + locator)                           | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------------------- | ------ |
| 1   | "a parser-combinator library that makes it easy to write efficient, expressive, and reusable parsers suitable for high-performance applications."                                                                                              | QUOTE | `README.md`                                        | ✓      |
| 2   | "It exposes monadic and applicative interfaces … supports incremental input through buffered and unbuffered interfaces … the unbuffered interface enabling zero-copy IO. Parsers are backtracking by default and support unbounded lookahead." | QUOTE | `README.md:5-9` (esp. `:8`)                        | ✓      |
| 3   | `Buffered` vs `Unbuffered` incremental interfaces                                                                                                                                                                                              | fact  | `lib/angstrom.mli` (module signatures)             | ✓      |
| 4   | Zero-copy via `bigstringaf` / `parse_bigstring`                                                                                                                                                                                                | fact  | `lib/angstrom.mli`; `bigstringaf` dep              | ✓      |
| 5   | `commit` bounds backtracking + releases consumed input (streaming)                                                                                                                                                                             | fact  | `lib/angstrom.mli` (`commit`)                      | ✓      |
| 6   | CPS (continuation-passing) implementation for speed                                                                                                                                                                                            | fact  | `lib/` internals (CPS parser)                      | ≈      |
| 7   | Monadic (`>>=`) + applicative (`<*>`) combinators                                                                                                                                                                                              | fact  | `lib/angstrom.mli`                                 | ✓      |
| 8   | License BSD-3-Clause; © 2016 Inhabited Type LLC                                                                                                                                                                                                | fact  | `LICENSE` "Copyright (c) 2016, Inhabited Type LLC" | ✓      |
| 9   | OCaml counterpart to Haskell's attoparsec; real-world use (httpaf/RWO)                                                                                                                                                                         | fact  | 🌐 ecosystem (adoption is external)                | 🌐     |
| 10  | Strengths / Weaknesses / trade-off tables                                                                                                                                                                                                      | synth | derived                                            | ◯      |

## Discrepancies

None. The README design paragraph (incl. "unbuffered interface enabling zero-copy IO … backtracking by
default … unbounded lookahead" at `:5-9`) is verbatim; buffered/unbuffered + `commit` + bigstring confirmed
in `angstrom.mli`; BSD © 2016 Inhabited Type LLC exact from `LICENSE`.

## Web-fallback / not-locally-groundable

- **Adoption** (httpaf, Real World OCaml) — external context, not asserted from the pinned tree (row 9).

## Opinion (◯)

- The "OCaml's attoparsec" positioning and the incremental+zero-copy-is-unusual framing;
  Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. The whole page rests on the verbatim README design paragraph + the
`angstrom.mli` interface + the BSD/© line; only real-world adoption is external.
