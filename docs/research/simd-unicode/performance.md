# Measured SIMD UTF and Unicode performance

Bounded SIMD fast paths make Sparkles competitive on long validation and lead this field on long ASCII validation and terminal width. They do **not** make it the fastest library across Unicode: simdutf8 still leads multilingual validation, simdutf leads conversion, and xutf leads non-ASCII width and segmentation.

**Measured:** September 30–October 1, 2026. See [UTF algorithms](./utf-algorithms.md), [Unicode algorithms](./unicode-algorithms.md), and the [survey inventory](./index.md#performance-oriented-inventory) for papers, locally inspected checkouts, versions and source licensing.

## Environment and contracts

| Property       | Measured configuration                                                                                                                                   |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host           | AMD Ryzen 9 7940HX, Linux x86-64; AVX2 and AVX-512 available                                                                                             |
| Native D       | LDC 1.42.0, D frontend 2.112; `-O3 -mcpu=native`, optimization/inlining, assertions retained                                                             |
| C++            | GCC 15.3.0; `-std=c++17 -O3 -DNDEBUG -fPIC`; simdutf runtime-selected `icelake` implementation                                                           |
| Rust           | nightly 1.101.0 (`5c543b0b8`, September 29, 2026); release opt-level 3, thin LTO, one codegen unit, `-C target-cpu=native`                               |
| Runner         | `sparkles:test-runner`; 20 ms minimum sample time for the UTF matrix; the implementation library's opt-in `benchmark` configuration                      |
| Cache/workload | Repeated deterministic inputs, preallocated caller buffers, verification outside timing; hot/reused-input results                                        |
| Small inputs   | Under 256 bytes: 64 operations per timed batch; B/s includes all batch input bytes                                                                       |
| Provenance     | simdutf `cf8715fad4d55c87aad3006a9a82531f740605b8`; simdutf8 `641d57f313df57354246d2b68d4778c092e076c3`; xutf `9bb347af041369a68a4effd1ca85c6d2f9b4e17b` |

The baseline was captured before attaching the new kernels. Both baseline and final UTF runs contain **4,419 rows, zero errors**, including malformed-input rows and an independent scalar D implementation. Only a representative subset is tabulated below. Compiler flags are deliberately disclosed, not asserted equivalent across languages. Native D can inline; separately compiled foreign calls cross a C ABI and retain their library's dispatch overhead. No overhead is subtracted.

These are separate contracts:

- **Offset:** first invalid UTF-8 sequence's **lead byte**, or the input length. Sparkles `indexOfInvalidUtf8`, simdutf diagnostic validation and simdutf8 `compat` agree on the tested fixtures.
- **Boolean:** validity only. Sparkles uses its offset primitive; simdutf and simdutf8 `basic` have separate Boolean implementations. Whole-input versus early-exit behavior matters on malformed inputs.
- **Conversion:** validating UTF-8 ↔ UTF-16, preserving embedded NUL. Sparkles accepts bounded destinations and guarantees fail-before-write on invalid input or insufficient capacity. The selected simdutf APIs require ample destination space and may write a prefix on failure. Their speed is not evidence that the stronger transaction contract costs nothing.
- **Display:** matched printable fixtures only. Sparkles also handles ANSI, controls, replacement and terminal policy, and computes cluster width metadata during segmentation. xutf's Unicode version and full policy differ. The fixtures do not establish equivalence across all Unicode or ANSI inputs.

The source, exact revisions, foreign build commands, batch semantics and correctness checks are in [`libs/base/bench/utf/README.md`](../../../libs/base/bench/utf/README.md). `analysis.d` normalization, folding, word boundaries and provenance are not disguised as width or segmentation benchmarks. Neither the normalization API nor generated Unicode tables changed.

## UTF-8 validation

Throughput is **decimal GB/s of input**, using valid 65,536-byte fixtures. Speedup compares Sparkles before/after; competitor columns are from the final run.

| Exact-offset corpus | Sparkles before | Sparkles after | Speedup | simdutf | simdutf8 compat |
| ------------------- | --------------: | -------------: | ------: | ------: | --------------: |
| ASCII               |          19.999 |        148.608 |   7.43× |  99.147 |         103.696 |
| Two-byte            |           1.663 |         23.273 |  14.00× |  19.123 |          29.336 |
| CJK                 |           3.109 |         23.199 |   7.46× |  19.464 |          28.947 |
| Supplementary       |           2.213 |         23.281 |  10.52× |  19.123 |          29.062 |
| Mixed scripts       |           1.504 |         23.199 |  15.43× |  19.349 |          29.062 |
| Embedded NUL        |           1.604 |         23.439 |  14.61× |  19.073 |          29.336 |

| Boolean corpus | Sparkles before | Sparkles after | Speedup | simdutf | simdutf8 basic |
| -------------- | --------------: | -------------: | ------: | ------: | -------------: |
| ASCII          |          20.005 |        152.056 |   7.60× | 103.696 |        103.861 |
| CJK            |           3.308 |         23.281 |   7.04× |  19.698 |         31.001 |
| Mixed scripts  |           1.662 |         23.273 |  14.00× |  19.823 |         31.001 |
| Supplementary  |           2.215 |         23.281 |  10.51× |  19.586 |         31.148 |

Sparkles leads these long ASCII rows and exceeds this simdutf backend on the tabulated multilingual validation rows. **simdutf8 remains faster on multilingual input.** A 64-byte ASCII offset call instead measured 4.86 ns for Sparkles, 5.02 ns for simdutf and 3.59 ns for simdutf8 compat; Boolean calls were 7.03, 4.38 and 2.03 ns respectively. Those values are per operation after dividing the 64-operation batch. Long-input leadership does not imply short-input leadership.

## UTF conversion

The corpus suffix names the original UTF-8 fixture size. `to16` throughput counts UTF-8 input bytes; `to8` counts **UTF-16 input bytes**, not the original UTF-8 byte count. All buffers are sized before timing.

| Direction      | Corpus        | Sparkles before GB/s | Sparkles after GB/s | Speedup | simdutf GB/s |
| -------------- | ------------- | -------------------: | ------------------: | ------: | -----------: |
| UTF-8 → UTF-16 | ASCII         |                0.454 |              18.903 |  41.61× |       44.796 |
| UTF-8 → UTF-16 | Two-byte      |                0.584 |               0.957 |   1.64× |        8.663 |
| UTF-8 → UTF-16 | CJK           |                0.736 |               1.305 |   1.77× |        7.615 |
| UTF-8 → UTF-16 | Supplementary |                0.798 |               1.472 |   1.85× |        5.031 |
| UTF-8 → UTF-16 | Mixed scripts |                0.573 |               1.010 |   1.76× |        4.234 |
| UTF-16 → UTF-8 | ASCII         |                0.955 |              29.395 |  30.77× |       85.500 |
| UTF-16 → UTF-8 | Two-byte      |                0.840 |               1.293 |   1.54× |       19.989 |
| UTF-16 → UTF-8 | CJK           |                0.746 |               1.378 |   1.85× |        9.588 |
| UTF-16 → UTF-8 | Supplementary |                1.093 |               1.737 |   1.59× |        5.758 |
| UTF-16 → UTF-8 | Mixed scripts |                0.944 |               1.592 |   1.69× |        7.240 |

ASCII widening/narrowing is vectorized, as is much of the sizing pass. Non-ASCII output emission remains scalar. **simdutf leads every conversion row in this table**, even after the substantial ASCII improvement. The researched shuffle-table and AVX-512 compaction algorithms explain a remaining algorithmic gap; they are not implemented by merely increasing the vector width.

## Terminal width and cluster boundaries

The fixtures are 65,536 UTF-8 bytes. Width scans can aggregate ASCII without materializing a cluster per character; boundary enumeration cannot skip those outputs.

| Visible-width corpus | Sparkles before GB/s | Sparkles after GB/s |   Speedup | xutf GB/s |
| -------------------- | -------------------: | ------------------: | --------: | --------: |
| ASCII                |                0.016 |             148.945 | 9,306.62× |   102.240 |
| Two-byte             |                0.026 |               0.053 |     2.05× |     0.920 |
| CJK                  |                0.035 |               0.067 |     1.92× |     1.198 |
| Supplementary        |                0.045 |               0.086 |     1.92× |     0.867 |
| Mixed scripts        |                0.034 |               0.077 |     2.30× |     1.004 |
| Combining/ZWJ/flags  |                0.052 |               0.108 |     2.06× |     0.893 |

The ASCII width median fell from **4,094,913 ns to 440 ns**, versus xutf's 641 ns. The large multiplier reflects removal of per-character cluster work from an operation whose ASCII answer is its byte length; it is not a claim of that multiplier on general Unicode. At 64 ASCII bytes, Sparkles measured 5.33 ns and xutf 2.97 ns.

| Cluster-boundary corpus | Sparkles before GB/s | Sparkles after GB/s | Speedup | xutf GB/s |
| ----------------------- | -------------------: | ------------------: | ------: | --------: |
| ASCII                   |                0.015 |               0.087 |   5.88× |     0.843 |
| CJK                     |                0.033 |               0.048 |   1.47× |     0.698 |
| Supplementary           |                0.041 |               0.062 |   1.51× |     0.677 |
| Mixed scripts           |                0.031 |               0.051 |   1.65× |     0.683 |
| Combining/ZWJ/flags     |                0.050 |               0.085 |   1.69× |     0.751 |

**xutf remains substantially faster on non-ASCII width and all tabulated boundary-enumeration rows.** Sparkles retains Phobos segmentation and the existing bounded 32-codepoint window rather than changing Unicode behavior to win the benchmark.

## Wired: measured consumer, not an inferred speedup

The same `wired-native` runtime field was measured before and after: **15 rows, seven datasets, zero row errors**. These runs preserve the existing wired `bench` build's assertion-disabled configuration in both measurements; the new UTF matrix uses the assertion-enabled optimized configuration described above. The two benchmark fields should not be conflated.

| Dataset / operation      | Before µs | After µs | Before GB/s | After GB/s |
| ------------------------ | --------: | -------: | ----------: | ---------: |
| canada / parse           |  1411.837 | 1392.280 |       1.594 |      1.617 |
| canada / validate        |  1477.114 | 1460.255 |       1.524 |      1.542 |
| citm_catalog / parse     |   406.491 |  401.823 |       4.249 |      4.298 |
| citm_catalog / validate  |   939.372 |  928.414 |       1.839 |      1.860 |
| github_events / parse    |    15.631 |   15.440 |       4.167 |      4.218 |
| github_events / validate |    42.233 |   41.120 |       1.542 |      1.584 |
| mesh / parse             |   420.698 |  425.189 |       1.720 |      1.702 |
| mesh / validate          |   560.731 |  570.962 |       1.290 |      1.267 |
| mesh_pretty / parse      |   809.390 |  794.598 |       1.949 |      1.985 |
| mesh_pretty / validate   |   960.018 |  985.135 |       1.643 |      1.601 |
| osm / parse              |  1943.662 | 1934.740 |       1.535 |      1.542 |
| osm / validate           |  2443.735 | 2410.478 |       1.221 |      1.238 |
| twitter / decode         |   197.414 |  192.465 |       3.199 |      3.281 |
| twitter / parse          |   168.989 |  163.238 |       3.737 |      3.869 |
| twitter / validate       |   422.231 |  426.922 |       1.496 |      1.479 |

Twitter parse time improved **3.5%** and decode **2.6%**. Retired instructions fell from 3.774 M to 3.645 M for parse and 4.098 M to 3.969 M for decode. Validation instructions were effectively unchanged at 11.258 M. Other datasets show small changes in both directions. **There is no broad wired speedup in this measurement.** Small timing changes without corresponding work reduction should not be presented as a statistically established win.

Counters covered kernel+user. The runner dropped LLC events because they would multiplex with the available counters; the absent cache-miss values are not zero cache misses. No CPU affinity/governor isolation is claimed.

## Implementation and invariants

- [`utf8_simd.d`](../../../libs/base/src/sparkles/base/text/utf8_simd.d) carries previous vector bytes across blocks. AVX2 uses nibble classification and continuation consistency from the researched lookup algorithm family; the classification tables are independently derived in D. SSE2 uses byte-class masks. An initial four-vector ASCII sweep avoids speculative four-vector probes on every multilingual block. Scalar refinement preserves first-invalid **sequence-lead** offsets, including a sequence crossing a block boundary.
- [`utf8.d`](../../../libs/base/src/sparkles/base/text/utf8.d) enters runtime SIMD on eligible inputs of at least 64 bytes. AVX2 admission uses CPU **and OS state** support through `core.cpuid`; SSE2 is the x86-64 fallback. DMD, other architectures and CTFE retain scalar behavior. Intrinsics use LDC's own vector/builtin surface; no foreign dependency was added to base.
- [`utf16_simd.d`](../../../libs/base/src/sparkles/base/text/utf16_simd.d) counts UTF-8 units and validates/sizes UTF-16 blocks, checks surrogate-pair masks, and defers a final high surrogate. ASCII conversion admits only complete bounded blocks. [`utf16.d`](../../../libs/base/src/sparkles/base/text/utf16.d) validates capacity and source before writing, avoids redundant decoder work after preflight, and emits non-ASCII output directly.
- [`grapheme.d`](../../../libs/base/src/sparkles/base/text/grapheme.d) replaces temporary shared buffers with bounded stack windows, avoids unused unclustered metadata for width-only scans, and aggregates printable ASCII using SSE2/AVX2. The last ASCII starter before non-ASCII stays on the cluster path for combining marks, variation selectors and keycaps. Boundary iteration still produces full metadata.
- [`scan.d`](../../../libs/wired/src/sparkles/wired/json/scan.d) uses the shared validator's string-body mode from its four UTF-8 run callsites. Quote, backslash and control bytes stop bulk scanning and re-enter the existing grammar path. Its padding contract remains unchanged; vector loads are bounded by the actual available pool.

All vector loads/stores are bounded; caller input/output does not acquire a padding requirement. Public signatures, `@safe pure nothrow @nogc` behavior, embedded-NUL policy, transactional conversion and Unicode tables remain unchanged.

## Correctness evidence and limits

Observed on the final kernels:

- Independent scalar UTF-8 differential smoke: **6,157,573 inputs**, covering every scalar value, truncations, corrupted bytes and 32 alignments; exact-offset parity.
- Guard-page smoke: **2,556 cases**, source/destination bounds through length 512, ordinary and NUL-terminated conversion, invalid tails and insufficient capacity; compile-time round-trip and transaction checks also passed.
- Direct LDC module unittests: UTF-8 SIMD, UTF-16 and grapheme modules passed, including forced SSE2/AVX2 boundary checks. The normal full LDC base unittest build encountered an existing negative-copy static assertion in `unique.d` under `-allinst`; this is not represented as a full LDC suite pass.
- Full DMD base suite: **609 passed**. Full LDC wired suite: **201 passed**.
- Real competitor correctness sweep: passed; final matrix **4,419 rows, zero errors**.
- Offline conformance layers 1 and 2: **1,112,064 scalar widths** and **3,655 RGI emoji cases** passed.

Layer 0 is **not all green**: on LDC 1.42, Unicode 15 `GraphemeBreakTest` passed 601/602 cases. `U+2701 U+200D U+2701` split as `[2, 1]` instead of `[3]`. A direct Phobos probe and the original shared-buffer window produce the same first stride of two. This predates the optimized window; neither expected results nor the divergence allowlist were changed to hide it. The [conformance documentation](../../specs/base/text/conformance-harness.md#the-two-unicode-versions) records the compiler-version observation.

These results do not cover cold-cache throughput, every processor, every Unicode policy, all normalization/search operations, or a complete independent segmentation replacement. No universal fastest-library claim follows from this matrix.

## Reproduce

Build the real C++ and Rust shims using the [benchmark README](../../../libs/base/bench/utf/README.md), with the pinned checkout revisions. Then run from the repository root:

```sh
dub test --root=libs/base/bench/utf --compiler=ldc2 -bbench \
  -cunittest-foreign -- -i 'utf\.correctness$'
libs/base/bench/utf/build/base-utf-bench-test-unittest-foreign \
  --bench -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-min-time=20 \
  --bench-json=/tmp/sparkles-base-utf-final.json --no-colors
```

The assertion-enabled warning is a runner heuristic, not evidence that this optimized `bench` build is a debug build. Do not disable assertions to silence it. See [runner configuration](../../libs/test-runner/how-to/benchmark.md).

Run wired from `libs/wired/bench/runtime`, preserving the same flags on both sides:

```sh
DC=ldc2 WIRED_BENCH_ENGINES=wired-native \
  dub test -bbench -f --override-config=sparkles:test-runner-impl/benchmark -- \
  --bench --perf -i 'wired\.(parse|decode|validate)$' \
  --bench-min-time=250 --bench-json=/tmp/wired-utf-after.json \
  --group-by=dataset,operation --no-colors
```

`WIRED_BENCH_DATA` pointed to the flake's `wired-bench-data` store output for the measured runs; use the [wired benchmark setup](../../../libs/wired/bench/runtime/README.md) for the dataset environment.

Session raw JSON artifacts are retained at `/tmp/sparkles-base-utf-before.json`, `/tmp/sparkles-base-utf-final.json`, `/tmp/wired-utf-before.json` and `/tmp/wired-utf-after.json`. They are local measurement artifacts, not files shipped with this catalog. The tables above preserve the representative observations; do not treat an absent local artifact as reproducible baseline evidence on another host.
