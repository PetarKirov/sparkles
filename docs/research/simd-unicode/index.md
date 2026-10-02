# SIMD UTF and Unicode

UTF well-formedness, transcoding, terminal-cell width, segmentation, and normalized search analysis are different performance contracts. This catalog separates the vectorized byte scans from the scalar Unicode state machines they feed.

**Last reviewed:** October 1, 2026.

## Read the catalog

- [UTF algorithms](./utf-algorithms.md): four primary papers, nibble lookup and range validation, shuffle-table and AVX-512 transcoding, Parabix history, bounded loads/stores, dispatch, and source licensing.
- [Unicode algorithms](./unicode-algorithms.md): Rust/C/C++ source inspection, Unicode versions, property tables, terminal width, grapheme segmentation, normalization, and semantic comparison boundaries.
- [Measured performance](./performance.md): before/after and real simdutf, simdutf8 and xutf results, bounded SIMD implementation, correctness evidence, wired integration and remaining leaders.

The runnable local matrix lives in [`libs/base/bench/utf`](https://github.com/PetarKirov/sparkles/blob/878ee7e3ce1b8586d3dbf08d0132cfe568016ac6/libs/base/bench/utf/README.md). It uses `sparkles:test-runner`, real separately compiled foreign implementations, independent scalar references, output guards, and distinct Boolean/exact-offset rows. The [wired runtime benchmark](../../../libs/wired/bench/runtime/README.md) measures the JSON consumer separately: its fused scanner does not automatically benefit from an isolated base validator improvement.

## Performance-oriented inventory

All paths are under `REPOS=/home/petar/code/repos`; the deep dives record inspected commits and pinned source citations. `rust/xutf` was already present. The other thirteen checkouts were cloned for this survey; papers were downloaded under `papers/simd-unicode/` and are not redistributed here.

| Library               | Local checkout               | Role                                                                                    |
| --------------------- | ---------------------------- | --------------------------------------------------------------------------------------- |
| simdutf               | `cpp/simdutf`                | Primary current SIMD validation and UTF conversion competitor                           |
| is_utf8               | `cpp/is_utf8`                | Standalone SIMD Boolean validation                                                      |
| utf8_range            | `c/utf8_range`               | Independent SIMD range-classification validator                                         |
| simdutf8              | `rust/simdutf8`              | SIMD Boolean and diagnostic UTF-8 validation                                            |
| xutf                  | `rust/xutf`                  | SIMD-assisted codecs, terminal width, segmentation and normalization                    |
| encoding_rs           | `rust/encoding_rs`           | SIMD-assisted encoding/transcoding; WHATWG error policy differs                         |
| simd-normalizer       | `rust/simd-normalizer`       | SIMD normalization quick checks with scalar exceptional processing                      |
| fastvalidate-utf-8    | `c/fastvalidate-utf-8`       | Historical SIMD validator; upstream calls it obsolete/demo                              |
| utf8lut               | `cpp/utf8lut`                | Historical table-driven SIMD transcoding, first-use allocation and padding requirements |
| unicode-segmentation  | `rust/unicode-segmentation`  | Scalar segmentation baseline, not a SIMD claim                                          |
| unicode-normalization | `rust/unicode-normalization` | Scalar normalization baseline, not a SIMD claim                                         |
| unicode-width         | `rust/unicode-width`         | Scalar terminal-width baseline, not a SIMD claim                                        |
| utf8proc              | `c/utf8proc`                 | Scalar normalization/folding/property baseline                                          |
| uni-algo              | `cpp/uni-algo`               | Scalar/SWAR Unicode baseline                                                            |

## Decisions for Sparkles

1. Preserve exact first-invalid **sequence-lead** offsets, scalar CTFE, bounded destinations and fail-before-write conversion. Foreign unbounded partial-write conversion is not an equivalent contract.
2. Measure printable-ASCII bulk scans and bounded block validation before adopting more elaborate conversion tables. Runtime dispatch must include OS support, not only CPU capability bits.
3. Preserve ANSI grammar, malformed replacement, the existing 32-codepoint grapheme cap and terminal-width policy. Keep the final ASCII starter before a non-ASCII continuation on the scalar cluster path.
4. Gate shared Unicode fixtures on actual output agreement. The surveyed checkouts do not all ship the same Unicode version.
5. Report measured corpora, compiler/backend, batch size and hot-cache behavior. No finite local matrix establishes a universal fastest-library claim.
