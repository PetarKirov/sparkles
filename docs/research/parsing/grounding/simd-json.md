# Grounding ledger — `simd-json.md`

Verification of `docs/research/parsing/simd-json.md` against the **local** pinned tree
`$REPOS/rust/simd-json` `0662a83` (2026-03-11). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                     | Type  | Source (local + locator)                                                                      | Status |
| --- | ----------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------------- | ------ |
| 1   | "Rust port of extremely fast simdjson JSON parser with Serde compatibility."              | QUOTE | `README.md` (tagline)                                                                         | ✓      |
| 2   | "follows most of the design closely with a few exceptions to make it better fit … Rust"   | QUOTE | `README.md`                                                                                   | ✓      |
| 3   | License Apache-2.0 OR MIT (dual)                                                          | fact  | `Cargo.toml` `license = "Apache-2.0 OR MIT"`                                                  | ✓      |
| 4   | Crate version `0.17.0`; MSRV `rust-version = "1.88"`                                      | fact  | `Cargo.toml`                                                                                  | ✓      |
| 5   | Two-stage pipeline: SIMD structural index (stage1) → tape build (stage2)                  | fact  | `src/` `Stage1Parse`, `to_tape`/`Node` tape enum                                              | ✓      |
| 6   | Mutable-buffer contract: parses `&mut [u8]` in situ (unlike simdjson's copy)              | fact  | `src/lib.rs` entry points take `&mut [u8]`                                                    | ✓      |
| 7   | AVX2/SSE4.2/NEON/SIMD128 kernels; runtime CPU dispatch via `AtomicPtr`                    | fact  | `src/` kernel modules + `AtomicPtr` dispatch                                                  | ✓      |
| 8   | Borrowed (zero-copy) vs owned DOM; serde integration; simdutf8-delegated UTF-8 validation | fact  | `src/value/{borrowed,owned}`, serde feature                                                   | ≈      |
| 9   | Tracks C++ simdjson 0.2.x era — **no On-Demand** API (always builds the tape)             | fact  | `README.md` ("work in progress"); `src/` (no OD)                                              | ≈      |
| 10  | Narrower kernel roster than C++ (no AVX-512/ppc64/LoongArch; adds wasm)                   | fact  | `src/` arch modules                                                                           | ≈      |
| 11  | No GB/s / throughput number asserted (page carries a WARNING)                             | fact  | repo has **no** benchmark figures at this SHA                                                 | ✓      |
| 12  | Eisel–Lemire fast-float number parsing                                                    | fact  | `numberparse/correct.rs` `MANTISSA_128`/`POW10` (no explicit "Lemire" comment — **inferred**) | ◯      |
| 13  | Strengths / Weaknesses / trade-off tables                                                 | synth | derived                                                                                       | ◯      |

## Discrepancies

None. simd-json's own quotes verbatim; the dual license + version + MSRV exact from `Cargo.toml`.

## Web-fallback / not-locally-groundable

- **No throughput numbers exist in-repo** at `0662a83`; the page makes no GB/s claim and says so (WARNING).
- **Release date** for `0.17.0` unverified (no CHANGELOG / git tags in the shallow clone); the page dates
  the pinned commit, not the release.
- **Eisel–Lemire attribution** (row 12) is inferred from the table structure, flagged in-page as such.

## Opinion (◯)

- The simd-json-vs-simdjson contrast framing; Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. Every quote + the license/version/MSRV facts are verbatim-grounded; the only
soft spots (benchmark absence, release date, Lemire attribution) are flagged honestly in the page.
