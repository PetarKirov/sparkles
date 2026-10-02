# Measured SIMD UTF and Unicode performance

Sparkles leads this field on long ASCII validation and terminal width. The October 2 non-ASCII pass also exceeds xutf on matched two-byte, CJK, supplementary and mixed-script width fixtures, and simdutf on mixed UTF-8→UTF-16 conversion. It is **not universally fastest**: simdutf8 leads multilingual validation, simdutf leads most conversion rows, and xutf leads complex-grapheme width and boundary enumeration.

**Measured:** September 30–October 2, 2026. The first three operation sections retain the initial SIMD pass; [the October 2 follow-up](#october-2-non-ascii-follow-up) records the subsequent optimization. See [UTF algorithms](./utf-algorithms.md), [Unicode algorithms](./unicode-algorithms.md), and the [survey inventory](./index.md#performance-oriented-inventory) for papers, locally inspected checkouts, versions and source licensing.

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

The initial scalar-to-SIMD baseline and result both contain **4,419 rows, zero errors**, including malformed-input rows and an independent scalar D implementation. Only a representative subset is tabulated below; the follow-up uses its own focused baseline. Compiler flags are deliberately disclosed, not asserted equivalent across languages. Native D can inline; separately compiled foreign calls cross a C ABI and retain their library's dispatch overhead. No overhead is subtracted.

These are separate contracts:

- **Offset:** first invalid UTF-8 sequence's **lead byte**, or the input length. Sparkles `indexOfInvalidUtf8`, simdutf diagnostic validation and simdutf8 `compat` agree on the tested fixtures.
- **Boolean:** validity only. Sparkles uses its offset primitive; simdutf and simdutf8 `basic` have separate Boolean implementations. Whole-input versus early-exit behavior matters on malformed inputs.
- **Conversion:** validating UTF-8 ↔ UTF-16, preserving embedded NUL. Sparkles accepts bounded destinations and guarantees fail-before-write on invalid input or insufficient capacity. The selected simdutf APIs require ample destination space and may write a prefix on failure. Their speed is not evidence that the stronger transaction contract costs nothing.
- **Display:** matched printable fixtures only. Sparkles also handles ANSI, controls, replacement and terminal policy, and computes cluster width metadata during segmentation. xutf's Unicode version and full policy differ. The fixtures do not establish equivalence across all Unicode or ANSI inputs.

The source, exact revisions, foreign build commands, batch semantics and correctness checks are in [`libs/base/bench/utf/README.md`](https://github.com/PetarKirov/sparkles/blob/878ee7e3ce1b8586d3dbf08d0132cfe568016ac6/libs/base/bench/utf/README.md). `analysis.d` normalization, folding, word boundaries and provenance are not disguised as width or segmentation benchmarks. Neither the normalization API nor generated Unicode tables changed.

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

In this initial pass, ASCII widening/narrowing and much of sizing were vectorized, but non-ASCII emission remained scalar. **simdutf led every conversion row in this table.** The October 2 pass below implements the compaction algorithm family rather than merely widening classification.

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

**In this initial pass, xutf led non-ASCII width and every tabulated boundary-enumeration row.** Sparkles retains Phobos segmentation and the 32-codepoint cluster cap rather than changing Unicode behavior to win the benchmark.

## October 2 non-ASCII follow-up

This section retains the pre-CI-repair measurements. The [post-CI workload
summary](#post-ci-workload-summary) below measures the corrected kernels anew.

Same host, toolchains, foreign revisions and assertion-enabled native flags;
**100 ms** minimum sample time per row. The focused baseline contains
**60 rows, zero errors**; the final expanded subset adds sparse Unicode and
ASCII checks for **166 rows, zero errors**. The baseline already includes the
initial SIMD validator, ASCII conversion and fixed-window segmentation; these
speedups measure the subsequent non-ASCII work, not the scalar-to-SIMD cutover.
Inputs are repeated 65,536-byte UTF-8 fixtures; conversion byte accounting is
unchanged from the earlier section.

| Visible-width corpus | Sparkles before GB/s | Sparkles after GB/s | Speedup | xutf GB/s |
| -------------------- | -------------------: | ------------------: | ------: | --------: |
| Two-byte             |                0.050 |               1.594 |  31.65× |     0.917 |
| CJK                  |                0.066 |               1.905 |  29.01× |     1.193 |
| Supplementary        |                0.085 |               2.121 |  24.82× |     0.866 |
| Mixed scripts        |                0.076 |               1.771 |  23.29× |     1.004 |
| Combining/ZWJ/flags  |                0.105 |               0.236 |   2.25× |     0.895 |

Ordinary singleton-run aggregation and bounded escape search exceed xutf by
**60–145%** on the four matched simple-Unicode fixtures. CJK width retires
**1.060 M instructions** instead of **20.397 M**. Complex clusters still use Phobos and remain about
four times slower than xutf; retaining the original segmentation policy is
not evidence that this gap has disappeared.

| Direction      | Corpus        | Sparkles before GB/s | Sparkles after GB/s | Speedup | simdutf GB/s |
| -------------- | ------------- | -------------------: | ------------------: | ------: | -----------: |
| UTF-8 → UTF-16 | Two-byte      |                0.943 |               5.130 |   5.44× |        8.721 |
| UTF-8 → UTF-16 | CJK           |                1.279 |               4.785 |   3.74× |        7.535 |
| UTF-8 → UTF-16 | Supplementary |                1.231 |               4.692 |   3.81× |        5.162 |
| UTF-8 → UTF-16 | Mixed scripts |                1.016 |               4.877 |   4.80× |        4.349 |
| UTF-16 → UTF-8 | Two-byte      |                1.272 |               3.745 |   2.94× |       20.151 |
| UTF-16 → UTF-8 | CJK           |                1.351 |               7.601 |   5.63× |        9.525 |
| UTF-16 → UTF-8 | Supplementary |                1.710 |               3.561 |   2.08× |        5.963 |
| UTF-16 → UTF-8 | Mixed scripts |                1.530 |               3.831 |   2.50× |        7.240 |

Register compaction, wide preflight and homogeneous-width emission improve
conversion **2.1–5.6×**. Mixed UTF-8→UTF-16 exceeds simdutf by **12%** while
retaining bounded destinations and fail-before-write. simdutf still leads
the other seven rows; the transactional contracts remain different.

Grouped AVX-512 validation reduces CJK offset-validation instructions from
**75.164 k to 30.906 k**, but throughput rises only from **23.027 to 25.255 GB/s**,
versus simdutf8 compat's **29.336 GB/s**. Wider vectors and fewer retired
instructions do not alone establish higher throughput on this Zen 4 host.
Other multilingual offset rows measure 25.158–25.352 GB/s; Boolean rows
measure 25.148–25.255 GB/s, below simdutf8 basic's 30.710–31.432 GB/s.

| Cluster-boundary corpus | Sparkles before GB/s | Sparkles after GB/s | Speedup | xutf GB/s |
| ----------------------- | -------------------: | ------------------: | ------: | --------: |
| Two-byte                |                0.033 |               0.124 |   3.76× |     0.519 |
| CJK                     |                0.048 |               0.168 |   3.49× |     0.698 |
| Supplementary           |                0.062 |               0.217 |   3.48× |     0.670 |
| Mixed scripts           |                0.053 |               0.161 |   3.02× |     0.669 |
| Combining/ZWJ/flags     |                0.078 |               0.189 |   2.43× |     0.748 |

Decoded-window reuse and fixed-width decoding improve boundary enumeration,
but xutf still leads every row. Sparkles' range computes full cluster metadata;
the Rust shim emits boundary offsets without that additional terminal policy.

### Sparse Unicode and ASCII resumption

A separate **14-row, zero-error** pre-correction field starts with `é漢😀`
and follows it with ASCII to total 65,536 bytes. Validation and conversion
must resume their ASCII paths; width must not discover escape-free runs with
a scalar byte loop. The final expanded subset exercises the same fixtures.

| Operation               | Before correction GB/s | Final GB/s | Speedup | Best peer | Peer GB/s |
| ----------------------- | ---------------------: | ---------: | ------: | --------- | --------: |
| Exact-offset validation |                 25.451 |    105.363 |   4.14× | simdutf8  |   102.240 |
| Boolean validation      |                 24.871 |    103.861 |   4.18× | simdutf8  |   107.260 |
| UTF-8 → UTF-16          |                  5.162 |     19.764 |   3.83× | simdutf   |    44.191 |
| UTF-16 → UTF-8          |                  3.753 |     10.847 |   2.89× | simdutf   |    89.037 |
| Visible width           |                  4.863 |     60.569 |  12.45× | xutf      |    99.147 |
| Cluster boundaries      |                  0.089 |      0.090 |   1.01× | xutf      |     0.840 |

The sparse exact-offset row narrowly leads this measurement; Boolean validation,
conversion, width and boundaries still have competitor leads.

The larger scanner also exposed a small-ASCII width initialization regression.
Returning printable ASCII before constructing the scanner removes it:

| ASCII bytes | Initial SIMD pass GB/s | Intermediate GB/s | Final GB/s |
| ----------- | ---------------------: | ----------------: | ---------: |
| 1           |                  0.291 |             0.069 |      0.400 |
| 64          |                 12.012 |             4.171 |     15.694 |
| 65,536      |                148.608 |           145.313 |    148.608 |

This is not a win for every small operation: one-byte boundary enumeration
measures 0.045 GB/s versus 0.068 GB/s in the initial pass. The larger metadata
queue still has per-iterator overhead; the width shortcut does not remove it.

These are **hot/reused-input** measurements, not DRAM bandwidth or cold-cache
results. The earlier ~149 GB/s ASCII row repeatedly scans a 64 KiB input;
no equivalent streaming-memory throughput is claimed. CPU affinity and
governor isolation are not claimed, and absent LLC counters are not zero misses.

## Post-CI workload summary

After the compile-memory and unoptimized vector-ABI corrections, a fresh
**555-row field passed with zero errors**, including the independent scalar D
reference. Same host, foreign revisions, assertion-enabled native flags and
100 ms minimum sample time. Units below are **input GB/s**, including both
bytes of each UTF-16 unit. `—` means no measured adapter row, not an unsupported
library API. Ranges span workload variants, not confidence intervals.

| Operation / workload                               |        Sparkles |    Scalar D |        simdutf |       simdutf8 |        xutf |
| -------------------------------------------------- | --------------: | ----------: | -------------: | -------------: | ----------: |
| Exact offset / ASCII 1 byte                        |           0.454 |       0.914 |          0.213 |          0.305 |           — |
| Exact offset / ASCII 64 bytes                      |          10.751 |       1.246 |         12.375 |         19.505 |           — |
| Exact offset / ASCII 64 KiB                        |         139.142 |       1.253 |         96.235 |        100.670 |           — |
| Exact offset / four dense Unicode scripts          |   23.448–24.318 | 1.369–1.884 |  18.687–19.241 |  28.188–28.807 |           — |
| Exact offset / sparse Unicode + ASCII              |          99.147 |       1.241 |         96.235 |         99.147 |           — |
| Exact offset / malformed UTF-8 at end, 17 variants | 130.816–136.264 | 1.228–1.259 |  88.447–92.055 | 96.239–100.525 |           — |
| Boolean / ASCII 1 byte                             |           0.266 |       0.914 |          0.267 |          0.427 |           — |
| Boolean / ASCII 64 bytes                           |           8.176 |       1.635 |         15.170 |         31.267 |           — |
| Boolean / ASCII 64 KiB                             |         136.249 |       1.654 |        100.670 |        100.670 |           — |
| Boolean / four dense Unicode scripts               |   23.532–24.050 | 1.551–1.786 |  19.073–19.464 |  29.721–30.710 |           — |
| Boolean / sparse Unicode + ASCII                   |          97.524 |       1.630 |         99.147 |        105.363 |           — |
| Boolean / malformed UTF-8 at end, 17 variants      | 128.252–136.264 | 1.196–1.425 | 97.525–100.680 | 96.094–100.525 |           — |
| UTF-8 → UTF-16 / ASCII 64 KiB                      |          17.537 |       0.272 |         42.473 |              — |           — |
| UTF-8 → UTF-16 / four dense Unicode scripts        |     4.440–4.816 | 0.392–0.571 |    3.839–8.249 |              — |           — |
| UTF-8 → UTF-16 / mixed scripts                     |           4.659 |       0.421 |          3.839 |              — |           — |
| UTF-8 → UTF-16 / sparse Unicode + ASCII            |          17.584 |       0.286 |         41.930 |              — |           — |
| UTF-8 → UTF-16 / embedded NUL                      |           4.593 |       0.427 |          4.245 |              — |           — |
| UTF-8 → UTF-16 / malformed UTF-8 at end            |   37.796–39.412 | 0.586–0.601 |  40.134–42.751 |              — |           — |
| UTF-16 → UTF-8 / ASCII 64 KiB                      |          25.014 |       1.267 |         83.859 |              — |           — |
| UTF-16 → UTF-8 / four dense Unicode scripts        |     3.437–7.117 | 0.598–0.926 |   5.634–19.166 |              — |           — |
| UTF-16 → UTF-8 / sparse Unicode + ASCII            |          10.008 |       1.255 |         84.940 |              — |           — |
| UTF-16 → UTF-8 / embedded NUL                      |           3.524 |       0.842 |          7.172 |              — |           — |
| UTF-16 → UTF-8 / lone surrogate at end             |   55.918–56.375 | 2.606–2.620 |  80.215–83.326 |              — |           — |
| Visible width / ASCII 1 byte                       |           0.376 |           — |              — |              — |       0.376 |
| Visible width / ASCII 64 bytes                     |          13.170 |           — |              — |              — |      20.480 |
| Visible width / ASCII 64 KiB                       |         139.142 |           — |              — |              — |     100.670 |
| Visible width / two-byte                           |           1.567 |           — |              — |              — |       0.899 |
| Visible width / CJK                                |           1.877 |           — |              — |              — |       1.158 |
| Visible width / supplementary                      |           2.094 |           — |              — |              — |       0.844 |
| Visible width / mixed scripts                      |           1.717 |           — |              — |              — |       0.969 |
| Visible width / sparse Unicode + ASCII             |          59.470 |           — |              — |              — |      94.842 |
| Visible width / combining, ZWJ, flags              |           0.193 |           — |              — |              — |       0.863 |
| Boundaries / ASCII 64 KiB                          |           0.086 |           — |              — |              — |       0.819 |
| Boundaries / four dense Unicode scripts            |     0.118–0.208 |           — |              — |              — | 0.509–0.677 |
| Boundaries / sparse Unicode + ASCII                |           0.086 |           — |              — |              — |       0.823 |
| Boundaries / combining, ZWJ, flags                 |           0.165 |           — |              — |              — |       0.735 |

Sparkles leads long ASCII validation/width, late malformed UTF-8 validation,
simple Unicode width (**62–148%** above xutf), and mixed/embedded-NUL UTF-8→UTF-16.
simdutf8 leads dense Unicode validation; simdutf leads most conversion cases;
xutf leads complex width and every boundary-enumeration case. Small inputs have
mixed winners, including the independent scalar reference.

The conversion failure rows are still different contracts: Sparkles validates
before any write; simdutf may have written a prefix. Boundary iteration retains
Sparkles' width metadata and 32-codepoint cap. Error rates above use late errors;
they must not be extrapolated to early-error whole-input throughput.

Only simdutf, simdutf8 and xutf have measured foreign adapters. The other eleven
libraries in the [fourteen-library inventory](./index.md#performance-oriented-inventory)
were surveyed, **not timed**: is_utf8, utf8_range, encoding_rs, simd-normalizer,
fastvalidate-utf-8, utf8lut, unicode-segmentation, unicode-normalization,
unicode-width, utf8proc and uni-algo. Normalization, folding, provenance-bearing
analysis, ANSI-policy edge cases and cold-cache performance have no competitive
measurement in this field. Capability coverage is not a performance ranking.

## Wired: measured consumer, not an inferred speedup

The same `wired-native` runtime field was measured before and after: **15 rows, seven datasets, zero row errors**. These runs preserve the existing wired `bench` build's assertion-disabled configuration in both measurements; the new UTF matrix uses the assertion-enabled optimized configuration described above. The two benchmark fields should not be conflated.

| Dataset / operation      | Before µs | After µs | Before GB/s | After GB/s |
| ------------------------ | --------: | -------: | ----------: | ---------: |
| canada / parse           |  1411.837 | 1357.391 |       1.594 |      1.658 |
| canada / validate        |  1477.114 | 1454.651 |       1.524 |      1.547 |
| citm_catalog / parse     |   406.491 |  406.666 |       4.249 |      4.247 |
| citm_catalog / validate  |   939.372 | 1007.085 |       1.839 |      1.715 |
| github_events / parse    |    15.631 |   15.410 |       4.167 |      4.227 |
| github_events / validate |    42.233 |   41.601 |       1.542 |      1.566 |
| mesh / parse             |   420.698 |  420.719 |       1.720 |      1.720 |
| mesh / validate          |   560.731 |  563.737 |       1.290 |      1.284 |
| mesh_pretty / parse      |   809.390 |  786.190 |       1.949 |      2.006 |
| mesh_pretty / validate   |   960.018 |  939.634 |       1.643 |      1.679 |
| osm / parse              |  1943.662 | 1897.152 |       1.535 |      1.573 |
| osm / validate           |  2443.735 | 2355.650 |       1.221 |      1.267 |
| twitter / decode         |   197.414 |  193.346 |       3.199 |      3.266 |
| twitter / parse          |   168.989 |  164.640 |       3.737 |      3.836 |
| twitter / validate       |   422.231 |  413.895 |       1.496 |      1.526 |

The final non-ASCII kernels were measured against the original consumer baseline. Twitter parse time improved **2.6%** and decode **2.1%**. Retired instructions fell from 3.774 M to 3.625 M for parse and 4.098 M to 3.950 M for decode. Validation instructions were effectively unchanged at 11.258 M. Other datasets show changes in both directions, including slower citm_catalog validation. **There is no broad wired speedup in this measurement.** Small timing changes without corresponding work reduction should not be presented as a statistically established win.

Counters covered kernel+user. The runner dropped LLC events because they would multiplex with the available counters; the absent cache-miss values are not zero cache misses. No CPU affinity/governor isolation is claimed.

## Implementation and invariants

- [`utf8_simd.d`](../../../libs/base/src/sparkles/base/text/utf8_simd.d) carries previous vector bytes across blocks. AVX2 and AVX-512BW use independently derived nibble classifications and continuation consistency from the researched lookup algorithm family; SSE2 uses byte-class masks. An initial four-vector ASCII sweep avoids speculative four-vector probes on every multilingual block. Four multilingual vectors share one error reduction. Scalar replay preserves first-invalid **sequence-lead** offsets, including a sequence crossing a group boundary.
- [`simd_caps.d`](../../../libs/base/src/sparkles/base/text/simd_caps.d) checks CPUID F/BW/VL and XCR0 before admitting wide paths; compaction also requires VBMI2. Function-local targets explicitly enable LLVM 18's `evex512` backend feature for ZMM/64-bit-mask lowering, while VL admits narrowed opmask operations. An Android core2-baseline build exposed both missing lowering requirements; the corrected minimal cross-compile and both real APK builds pass. [`utf8.d`](../../../libs/base/src/sparkles/base/text/utf8.d) dispatches eligible runtime inputs to the bounded validator and provides fixed-width decoding for already-validated prefixes. Malformed replacement still delegates to Phobos, preserving byte consumption. DMD, other architectures and CTFE retain scalar behavior; no foreign dependency was added to base.
- [`utf16_simd.d`](../../../libs/base/src/sparkles/base/text/utf16_simd.d) counts UTF-8 units and validates/sizes UTF-16 blocks, including AVX-512BW paths, surrogate-pair masks and a deferred final high surrogate. [`utf16.d`](../../../libs/base/src/sparkles/base/text/utf16.d) completes source/capacity preflight before any write. [`utf16_emit.d`](../../../libs/base/src/sparkles/base/text/utf16_emit.d) emits non-ASCII blocks using register compaction followed by exact masked stores; homogeneous two-byte and three-byte blocks avoid general conversion work. Memory-form compaction regressed on this Zen 4 host and was rejected.
- [`grapheme.d`](../../../libs/base/src/sparkles/base/text/grapheme.d) reuses a bounded 64-codepoint decoded queue while retaining the 32-codepoint cluster cap. [`width.d`](../../../libs/base/src/sparkles/base/text/width.d) packs width and singleton-boundary traits derived from public Phobos probes. `gen_grapheme_tables.d` runs those probes offline and emits compact runs in `grapheme_tables.d`, avoiding 262,144 grapheme probes in each consumer's CTFE heap. A runtime exhaustive parity test checks the supported frontend; other frontend versions retain the public engine. Width-only scans aggregate ordinary singleton runs, withholding their final starter until attachment is ruled out. Complex clusters retain Phobos; failed aggregation is retried after a promising queue refill rather than at every cluster. Boundary iteration still produces full metadata.
- Compaction intrinsics live in explicitly targeted functions rather than trusted callsite lambdas: lambdas do not inherit the parent's target UDA. This also allows nonoptimized, baseline-target LDC builds; an isolated debug emitter compile failed before that correction and passed afterward.
- [`simd_io.d`](../../../libs/base/src/sparkles/base/text/simd_io.d) keeps wide vector returns in target-matched functions, with trusted pointer loads assigning through a reference rather than returning a vector from a baseline lambda. The public unoptimized LDC suite exposed seven runtime failures before this ABI correction; all pass afterward. `preceding` also uses the matching target ABI.
- [`scan.d`](../../../libs/wired/src/sparkles/wired/json/scan.d) uses the shared validator's string-body mode from its four UTF-8 run callsites. Quote, backslash and control bytes stop bulk scanning and re-enter the existing grammar path. Its padding contract remains unchanged; vector loads are bounded by the actual available pool.

All vector loads/stores are bounded; caller input/output does not acquire a padding requirement. Public signatures, `@safe pure nothrow @nogc` behavior, embedded-NUL policy, transactional conversion and Unicode tables remain unchanged.

## Correctness evidence and limits

Observed across the initial and non-ASCII passes:

- Independent scalar UTF-8 differential smoke: **6,157,573 inputs**, covering every scalar value, truncations, corrupted bytes and 32 alignments; exact-offset parity.
- Guard-page smoke: **2,556 cases**, source/destination bounds through length 512, ordinary and NUL-terminated conversion, invalid tails and insufficient capacity; compile-time round-trip and transaction checks also passed.
- Full unoptimized LDC base suite after CI corrections: **620 passed**, including forced SSE2/AVX2/AVX-512 boundary checks, the permanent 1,026-case guard-page conversion test and exhaustive cached-boundary parity. The ownership negative-copy probe now checks an invoked body and keeps its source alive; the earlier `-allinst` test-build blocker is removed.
- Full DMD base suite after CI corrections: **619 passed**.
- Final full LDC wired consumer suite: **201 passed**.
- Real competitor correctness sweep: passed after the CI corrections. The intermediate complete field contains **4,419 rows, zero errors**; the pre-CI subset contains **166 rows, zero errors**; the post-CI representative field contains **555 rows, zero errors**, including scalar D and valid/invalid workload variants.
- Offline conformance layers 1 and 2: **1,112,064 scalar widths** and **3,655 RGI emoji cases** passed.
- Actual Nix `ci-minimal`, `text-wasm` and `table-wasm` builds passed. A checked native `dub build :ci` completed in 71.57 seconds; GNU time reported maximum RSS **2,721,536 KiB**. Earlier CI consumer builds were killed while compiling base; no CI guards, timeouts or assertions were weakened.
- Actual Nix `terminal-apk` and `hue-apk` builds passed for x86_64 and arm64-v8a after the explicit target-feature correction. The VitePress build passed with the CI Node heap settings after replacing nonexistent documentation-page URLs with pinned source URLs; the rendered benchmark link was checked in Chromium.

Layer 0 is **not all green**: on LDC 1.42, Unicode 15 `GraphemeBreakTest` passed 601/602 cases. `U+2701 U+200D U+2701` split as `[2, 1]` instead of `[3]`. A direct Phobos probe and the original shared-buffer window produce the same first stride of two. This predates the optimized window; neither expected results nor the divergence allowlist were changed to hide it. The [conformance documentation](../../specs/base/text/conformance-harness.md#the-two-unicode-versions) records the compiler-version observation.

These results do not cover cold-cache throughput, every processor, every Unicode policy, all normalization/search operations, or a complete independent segmentation replacement. No universal fastest-library claim follows from this matrix.

## Reproduce

Build the real C++ and Rust shims using the [benchmark README](https://github.com/PetarKirov/sparkles/blob/878ee7e3ce1b8586d3dbf08d0132cfe568016ac6/libs/base/bench/utf/README.md), with the pinned checkout revisions. Then run from the repository root:

```sh
dub test --root=libs/base/bench/utf --compiler=ldc2 -bbench \
  -cunittest-foreign -- -i 'utf\.correctness$'
libs/base/bench/utf/build/base-utf-bench-test-unittest-foreign \
  --bench -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-min-time=20 \
  --bench-json=/tmp/sparkles-base-utf-final.json --no-colors
```

For the pre-CI non-ASCII, sparse and ASCII subset, use the same built binary:

```sh
UTF_BENCH_CORPORA='two-byte/65536,cjk/65536,supplementary/65536,mixed/65536,grapheme/65536,sparse/65536,ascii/1,ascii/64,ascii/65536' \
UTF_BENCH_ENGINES=sparkles,simdutf,simdutf8,xutf \
  libs/base/bench/utf/build/base-utf-bench-test-unittest-foreign \
  --bench --perf -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-min-time=100 \
  --bench-json=/tmp/base-nonascii-final.json --no-colors
```

Corpus selectors are prefixes: `ascii/1` also selects 15, 16, 127, 128 and 129.

For the post-CI summary, include the scalar reference, every ASCII size and
the documented malformed families at the end of long ASCII prefixes:

```sh
UTF_BENCH_CORPORA='ascii/,two-byte/65536,cjk/65536,supplementary/65536,mixed/65536,grapheme/65536,sparse/65536,nul/65536,invalid8/0/65535,invalid8/1/65535,invalid8/2/65535,invalid8/3/65535,invalid8/4/65535,invalid8/5/65535,invalid8/6/65535,invalid8/7/65535,invalid8/8/65535,invalid8/9/65535,corrupt/3/65535,corrupt/4/65535,invalid16/65535' \
UTF_BENCH_ENGINES=scalar-d,sparkles,simdutf,simdutf8,xutf \
  libs/base/bench/utf/build/base-utf-bench-test-unittest-foreign \
  --bench --perf -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-min-time=100 \
  --bench-json=/tmp/base-ci-workloads.json --no-colors
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

Session raw JSON artifacts are retained at `/tmp/sparkles-base-utf-before.json`, `/tmp/sparkles-base-utf-final.json`, `/tmp/base-nonascii-before.json`, `/tmp/base-utf-oct2-final.json` (intermediate complete field), `/tmp/base-sparse-before.json`, `/tmp/base-nonascii-final.json` (pre-CI), `/tmp/base-ci-workloads.json` (post-CI), `/tmp/wired-utf-before.json`, `/tmp/wired-utf-after.json` (initial pass) and `/tmp/wired-utf-oct2.json` (non-ASCII pass). They are local measurement artifacts, not files shipped with this catalog. The tables above preserve the representative observations; do not treat an absent local artifact as reproducible baseline evidence on another host.
