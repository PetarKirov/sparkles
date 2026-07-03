# Grounding ledger — `rust-combine.md`

Verification of `docs/research/parsing/rust-combine.md` against the **local** pinned tree
`$REPOS/rust/combine` `203b76a` (2026-02-03). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                                                                                                              | Type  | Source (local + locator)                  | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- | ----------------------------------------- | ------ |
| 1   | "An implementation of parser combinators for Rust, inspired by the Haskell library Parsec. As in Parsec the parsers are LL(1) by default but they can opt-in to arbitrary lookahead using the attempt combinator." | QUOTE | `README.md:6`                             | ✓      |
| 2   | `attempt` = Parsec's `try` (opt-in arbitrary lookahead)                                                                                                                                                            | fact  | `README.md:6`; `src/parser/` (`attempt`)  | ✓      |
| 3   | Parses over any **`Stream`**/`RangeStream` — `&str`, `&[u8]`, iterators, **partial** input                                                                                                                         | fact  | `src/stream/` (`Stream`, `PartialStream`) | ✓      |
| 4   | Parsec-style **consumed/commit** error model (`Consumed`/`Commit`) — kept, unlike nom/flatparse                                                                                                                    | fact  | `src/error.rs` (`Consumed`/commit)        | ✓      |
| 5   | Zero-copy `range` parsers (`range::take`)                                                                                                                                                                          | fact  | `src/parser/range.rs`                     | ✓      |
| 6   | `EasyParser`/`easy::Errors` for readable errors                                                                                                                                                                    | fact  | `src/easy.rs`                             | ≈      |
| 7   | License MIT                                                                                                                                                                                                        | fact  | `Cargo.toml` `license = "MIT"`            | ✓      |
| 8   | Partial/streaming parsing support                                                                                                                                                                                  | fact  | `src/stream/` (`PartialStream`)           | ✓      |
| 9   | Strengths / Weaknesses / trade-off tables (center combine↔nom and combine↔Parsec deltas)                                                                                                                           | synth | derived                                   | ◯      |

## Discrepancies

None. The README's LL(1)+`attempt` sentence is verbatim (`:6`); the `Stream`/partial model, the
consumed/commit error tracking (combine's Parsec-inherited distinctive vs nom/winnow), and MIT license
are all confirmed in-tree.

## Web-fallback / not-locally-groundable

- **Version / download stats** — not asserted as fact from the tree beyond `Cargo.toml`.

## Opinion (◯)

- The "combine keeps Parsec's consumed-tracking that nom/winnow drop" framing; Strengths/Weaknesses tables.

**Net:** 0 discrepancies. The headline LL(1)+`attempt` quote is verbatim; the Parsec-lineage consumed/commit
model and the `Stream` abstraction are grounded in `src/`, MIT license exact.
