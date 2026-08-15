# Grounding ledger — index.md (the umbrella)

The umbrella aggregates; nearly every row traces to a deep-dive ledger. Recorded here: the claims
that originate on the umbrella itself.

| #   | Claim                                                                                                            | Status | Note                                                                                                                                                                                   |
| --- | ---------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | The `[!IMPORTANT]` gap statement and the comment word-counts                                                     | ✓      | Verified in [`theory-index`](./theory-index.md) row 3 and [`theory-layout-preserving`](./theory-layout-preserving.md) row 37                                                           |
| 2   | "prettier's printer is 578 lines and its JavaScript comment placement is 1,255; rustfmt's `comment.rs` is 2,149" | ✓      | Measured; see [`prettier`](./prettier.md), [`rustfmt`](./rustfmt.md)                                                                                                                   |
| 3   | **The master catalog** (16 rows × 6 columns)                                                                     | ◯      | Each cell traces to a deep-dive. Rows for scalafmt (2016 thesis only) and sdfmt inherit those pages' caveats                                                                           |
| 4   | **The four taxonomies**                                                                                          | ◯      | The survey's cuts. The paradigm taxonomy is the load-bearing one and is defended in [`theory/`](../theory/index.md)                                                                    |
| 5   | "**twenty papers** (1980–2023) and **thirteen production formatters**"                                           | ✓      | 17 held + 3 paywalled = 20; 13 deep-dive rows (counting the Rust wave as one and the long tail as one)                                                                                 |
| 6   | The milestones timeline                                                                                          | ⚠      | Two rows flagged `*` as unsourceable — see [`theory-index`](./theory-index.md) D-TI3                                                                                                   |
| 7   | The reading paths                                                                                                | ◯      | Editorial                                                                                                                                                                              |
| 8   | "Eighteen source trees pinned by SHA"                                                                            | ✓      | [`_sources.md`](./_sources.md) lists 21 rows, of which 18 are formatter/compiler trees plus rust/rust-analyzer/ocaml as supporting. **The figure in the doc is imprecise** — see D-PI1 |

## Discrepancies

- **D-PI1 (row 8).** The umbrella says "eighteen source trees"; `_sources.md` tabulates 21
  (including `rust/rust`, `rust-analyzer`, `ocaml/ocaml` as supporting reads, plus the DMD fork and
  this repo separately). Harmless, but the two numbers should agree. Prefer the table.
