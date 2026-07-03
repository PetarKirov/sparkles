# Grounding ledger — `rust-winnow.md`

Verification of `docs/research/parsing/rust-winnow.md` against the **local** pinned tree
`$REPOS/rust/winnow` `cbeda8e0` (2026-06-16). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                         | Type  | Source (local + locator)                       | Status |
| --- | ----------------------------------------------------------------------------------------------------------------------------- | ----- | ---------------------------------------------- | ------ |
| 1   | winnow is the actively-maintained **fork of nom**; "thanks to Geal for the original nom crate."                               | QUOTE | `README.md:21`                                 | ✓      |
| 2   | Parsers advance input by mutating `&mut I` (`Fn(&mut I) -> Result<O, E>`) — the central fork vs nom's tuple-return            | fact  | `src/lib.rs`/`src/parser.rs` (`parse_next`)    | ✓      |
| 3   | Unified **`Stream`** trait generalizing nom's many input traits                                                               | fact  | `src/stream/` (`Stream` trait)                 | ✓      |
| 4   | `ErrMode` modal errors — `Backtrack` (recoverable) vs `Cut` (commit) vs `Incomplete`                                          | fact  | `src/error.rs:6,42` (`ErrMode`)                | ✓      |
| 5   | Hand-written-vs-generator-vs-combinator trade-off list (Fast parse / compile-time / binary size / error quality / fewer deps) | QUOTE | `src/_topic/why.rs`                            | ✓      |
| 6   | Cites the matklad Pratt-parser quote in `why.rs`                                                                              | QUOTE | `src/_topic/why.rs`                            | ✓      |
| 7   | nom-migration guide + fork rationale                                                                                          | fact  | `src/_topic/nom.rs`                            | ✓      |
| 8   | License MIT                                                                                                                   | fact  | `Cargo.toml` `license = "MIT"`                 | ✓      |
| 9   | Error posture: fail-fast; opt-in commit (`cut_err`) + opt-in multi-error recovery (`unstable-recover`)                        | fact  | `src/` (`cut_err`, `unstable-recover` feature) | ✓      |
| 10  | Zero-copy over slices (scannerless RD); `dispatch!`/`alt`; performance topic doc                                              | fact  | `src/combinator/`; `src/_topic/performance.rs` | ≈      |
| 11  | Strengths / Weaknesses / trade-off tables (center nom↔winnow deltas)                                                          | synth | derived                                        | ◯      |

## Discrepancies

None. README fork/credit quote verbatim (`:21`); the `&mut I` model, `Stream` trait, `ErrMode`
variants, and the `_topic/why.rs`/`nom.rs` docs all confirmed in-tree; MIT license exact.

## Web-fallback / not-locally-groundable

- **Download/adoption stats**, if any, are not from the tree (the page relies on in-repo docs; no
  crates.io numbers asserted as fact).

## Opinion (◯)

- The nom-vs-winnow design-delta framing; the Sparkles `@nogc`-fit note; Strengths/Weaknesses tables.

**Net:** 0 discrepancies. The whole page is grounded in winnow's unusually rich in-tree docs
(`README`, `src/_topic/{why,nom,performance}.rs`, `src/{stream,error}.rs`); the `&mut`-stream fork,
`ErrMode`, and MIT license are all exact.
