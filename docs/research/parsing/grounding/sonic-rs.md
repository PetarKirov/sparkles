# Grounding ledger — `sonic-rs.md`

Verification of `docs/research/parsing/sonic-rs.md` against the **local** pinned tree
`$REPOS/rust/sonic-rs` `03545a9` (2026-04-15). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                                    | Type   | Source (local + locator)                                                           | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------- | ------ |
| 1   | "A fast Rust JSON library based on SIMD. It has some references to … sonic_cpp, serde_json, sonic, simdjson…"                            | QUOTE  | `README.md`                                                                        | ✓      |
| 2   | Headline: "The main optimization in sonic-rs is the use of SIMD. However, we do not use the two-stage SIMD algorithms from `simd-json`." | QUOTE  | `README.md:60`                                                                     | ✓      |
| 3   | On-demand / lazy path: `get`/`get_from` by JSON-pointer → `LazyValue` without full parse                                                 | fact   | `src/lazyvalue/{get,value}.rs`; `src/parser.rs` `get_from_object`/`get_from_array` | ✓      |
| 4   | License **Apache-2.0 only** (not dual); `licenses/` vendors borrowed-source notices                                                      | fact   | `Cargo.toml` `license = "Apache-2.0"`; `licenses/`                                 | ✓      |
| 5   | Version `0.5.9`; repo `cloudwego/sonic-rs` (ByteDance/CloudWeGo)                                                                         | fact   | `Cargo.toml`; `README.md`                                                          | ✓      |
| 6   | SIMD backend selected at **compile time** (`cfg_if!` on `target_feature`), NOT runtime-dispatched                                        | fact   | `src/util/arch/`; runtime dispatch is an open `ROADMAP.md` item                    | ✓      |
| 7   | SIMD primitives: `prefix_xor` (clmul), `get_nonspace_bits` (pshufb)                                                                      | fact   | `src/util/arch/x86_64.rs`                                                          | ✓      |
| 8   | serde_json drop-in compatibility (type-map)                                                                                              | fact   | `docs/serdejson_compatibility.md`                                                  | ✓      |
| 9   | 4 GB input ceiling; checked-vs-unchecked skip in the get path                                                                            | fact   | `src/parser.rs`                                                                    | ≈      |
| 10  | Benchmark numbers (Xeon 8260, `-C target-cpu=native`)                                                                                    | figure | `README.md` benchmark table (quoted, not re-run)                                   | 🌐     |
| 11  | Strengths / Weaknesses / trade-off tables                                                                                                | synth  | derived                                                                            | ◯      |

## Discrepancies

None. The task brief's "Apache-2.0/MIT" guess was **corrected to Apache-2.0 only** (row 4). The
"we do not use the two-stage SIMD algorithms from simd-json" thesis is verbatim at `README.md:60`.

## Web-fallback / not-locally-groundable

- **Benchmark numbers** quoted from the README's own table (not independently run); machine/flags noted.

## Opinion (◯)

- The on-demand-vs-eager-tape positioning (sonic-rs lazy vs simd-json eager vs simdjson On-Demand);
  Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. The headline (no two-stage; on-demand), license (Apache-2.0 only), version, and
compile-time-dispatch contrast are all verbatim/exact-grounded; only the README benchmark figures are secondary.
