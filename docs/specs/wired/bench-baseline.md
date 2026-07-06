# `sparkles:wired` — runtime JSON benchmark baseline

_The evidence base for replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser. Numbers from the harness at
[`libs/wired/bench/runtime`](../../../libs/wired/bench/runtime/README.md);
the raw snapshot is
[`results/2026-07-05-ryzen9-7940hx-x86-64-v4.json`](../../../libs/wired/bench/runtime/results/2026-07-05-ryzen9-7940hx-x86-64-v4.json)._

## Environment

|                 |                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPU             | AMD Ryzen 9 7940HX (Zen 4, AVX-512)                                                                                                               |
| D toolchain     | LDC, front-end 2.111, `-mcpu=native` (`bench` build type)                                                                                         |
| Shim ISA preset | `x86-64-v4` (simdjson: runtime dispatch, icelake kernel)                                                                                          |
| Engines         | simdjson 4.6.0, rapidjson 1.1.0, yyjson 0.12.0, serde_json 1.0.150, simd-json 0.17.0, sonic-rs 0.5.8, mir-ion 2.3.5, asdf 0.8.0, jsoniopipe 0.2.7 |
| Corpora         | twitter.json 632 KB (strings), citm_catalog.json 1.7 MB (structure), canada.json 2.2 MB (floats), github_events.json 65 KB (small-doc)            |

Every engine reproduced the `std.json` structural fingerprint on every
corpus, and the `TwitterStats` checksum on the decode op, before being
timed. Throughputs are MB/s over the median iteration. Hardware counters
come from a separate `perf_event_open` counting pass per op (kernel+user;
the LLC pair was dropped because the NMI watchdog holds one of Zen 4's six
PMCs and a multiplexed group only yields rotation-scaled estimates).

## The headline: typed decode (twitter.json)

The op closest to wired's real workload — raw text → a partial Twitter
struct:

| Engine                           |    MB/s | × wired today |
| -------------------------------- | ------: | ------------: |
| **wired (parseJSON + fromJSON)** | **159** |       **1.0** |
| std.json manual extraction       |     157 |           1.0 |
| mir-ion                          |   1 740 |          10.9 |
| serde_json                       |   1 896 |          11.9 |
| asdf                             |   1 994 |          12.5 |
| sonic-rs                         |   2 069 |          13.0 |
| simd-json                        |   2 101 |          13.2 |
| yyjson (accessor walk)           |   3 518 |          22.1 |
| simdjson On-Demand               |   7 590 |      **47.7** |

## Parse (full DOM/tape, immutable input)

| Engine                         | twitter | citm_catalog | canada | github_events |
| ------------------------------ | ------: | -----------: | -----: | ------------: |
| std.json                       |     163 |          143 |     78 |           174 |
| jsoniopipe                     |     320 |          297 |    106 |           387 |
| serde_json                     |     425 |          779 |    496 |           540 |
| mir-ion                        |     498 |          441 |    185 |           505 |
| rapidjson (full precision)     |     909 |        1 588 |    365 |           883 |
| simd-json                      |   1 102 |        1 021 |    457 |         1 431 |
| sonic-rs                       |   2 044 |        1 935 |  1 283 |         2 421 |
| asdf ¹                         |   2 724 |        2 428 |  1 045 |         3 208 |
| yyjson                         |   4 022 |        3 966 |  1 360 |         4 257 |
| simdjson DOM                   |   5 320 |        5 575 |  1 449 |         5 815 |
| simdjson On-Demand (full walk) |   4 230 |        4 386 |  1 146 |         4 897 |

¹ asdf's tape keeps numbers textual (decoded on access), which flatters its
parse column — most visible on float-heavy canada, where engines that
materialize doubles pay for exact parsing.

## Hardware counters (twitter.json)

The "why" behind the tables above — per input byte, over the counting pass:

| Engine             | op     |  IPC | cyc/B | ins/B | br-miss% | faults/iter |
| ------------------ | ------ | ---: | ----: | ----: | -------: | ----------: |
| std.json           | parse  | 2.43 | 37.97 | 92.42 |     0.67 |       171.8 |
| wired              | decode | 2.33 | 40.17 | 93.70 |     0.79 |       211.2 |
| mir-ion            | decode | 3.10 |  2.89 |  8.93 |     0.20 |           0 |
| serde_json         | decode | 3.29 |  3.63 | 11.94 |     0.27 |           0 |
| sonic-rs           | decode | 4.00 |  2.35 |  9.39 |     0.09 |           0 |
| asdf               | parse  | 1.67 |  2.84 |  4.74 |     1.22 |           0 |
| yyjson             | parse  | 3.68 |  1.26 |  4.64 |     0.13 |           0 |
| simdjson DOM       | parse  | 3.44 |  0.96 |  3.29 |     0.15 |           0 |
| simdjson On-Demand | decode | 3.49 |  0.68 |  2.38 |     0.12 |           0 |

What the counters add to the findings:

- **The 48× decode gap is an instruction-budget gap, not an IPC gap.**
  wired burns 93.7 instructions per byte where simdjson On-Demand spends
  2.38 (≈ 39×), while IPC differs only 2.3 vs 3.5 (≈ 1.5×). The
  replacement parser must _do less work per byte_ — fewer instructions —
  not merely schedule the same work better.
- **Branch discipline is visible and worth ~0.5–1 IPC.** The fast engines
  (yyjson, sonic-rs, simdjson) all sit at ~0.1% branch misses; std.json
  and wired sit at 0.7–0.8%, serde_json's eager parse at 1.6%. yyjson's
  documented branch-layout work shows up exactly as advertised.
- **asdf's ceiling is its tape walk**: the lowest IPC in the field (1.67)
  and the highest miss rate among the fast engines (1.2%) — a
  dependent-chained, branchy traversal — caps an otherwise tiny
  instruction budget (4.7 ins/B).
- **Page faults are the GC signature.** GC-backed engines (std.json,
  wired, asdf's tape buffers) fault 100–300×/iteration in whichever
  counting pass catches the GC heap growing (the exact rows vary run to
  run); every native engine sits at 0 after warmup, always. An arena- or
  reuse-oriented document representation eliminates this class of cost
  outright.

Other ops in brief (twitter): **validate** — simdjson-OD structural skip
6 798, serde_json `IgnoredAny` 2 731, simd-json `to_tape` 2 571, sonic-rs
2 211, rapidjson SAX 1 051, jsoniopipe drain 678. **serialize** — yyjson
5 026, sonic-rs 2 445, simdjson-DOM 2 078, serde_json 1 630, std.json 179.

## Findings

1. **wired is parser-bound, not mapping-bound.** The `fromJSON` DbI layer
   costs nothing measurable (159 vs 157 MB/s for hand-written extraction);
   `std.json.parseJSON` is the whole bottleneck. Replacing the parser lifts
   wired directly.
2. **The state of the art is 10–48× away.** Every serious engine decodes
   typed structs at 1.7–2.1 GB/s; going through a compact DOM first
   (yyjson, 3.5 GB/s) or lazy extraction (simdjson On-Demand, 7.6 GB/s)
   goes further. A wired parser at 1.5 GB/s twitter-decode (~10×) is a
   realistic v1 bar; the lazy design points at 3+ GB/s.
3. **SIMD is one road, not the only one.** yyjson — deliberately scalar
   C — parses at 4 GB/s on structure/string corpora and 1.36 GB/s on
   floats, beating every SIMD engine except simdjson. Careful scalar D
   (branch layout, arena document, deferred number decode) gets most of the
   way; a vectorized structural scan (simdjson/sonic style) buys the rest.
4. **Laziness is the biggest single lever for typed decode.** simdjson
   On-Demand extracts the twitter subset at 7.6 GB/s because untouched
   fields are skipped, not parsed — and its skip-only "validate" runs at
   6.8–8.0 GB/s. wired's decode always knows the target struct, so an
   on-demand cursor (rather than a DOM) fits wired's shape exactly.
5. **Float parsing is its own battleground.** canada.json compresses every
   ranking: exact double parsing (Eisel–Lemire in simdjson/serde/yyjson;
   rapidjson needs `kParseFullPrecisionFlag` to even qualify) costs ~3× the
   throughput of the string-heavy corpora. A replacement parser needs a
   first-class fast-float path from day one.
6. **The D ecosystem today doesn't reach the bar.** mir-ion (0.2–0.5 GB/s
   parse; 1.7 GB/s decode) and asdf (fast tape, but lazy numbers and a
   dated codebase) are solid but 2–4× behind the C/C++/Rust frontier on
   comparable work; jsoniopipe's typed deserialize additionally leaves
   string escapes undecoded (caught by the checksum verification, excluded
   from the decode op).
7. **Allocation and copies dominate the tail.** The immutable-input
   contract makes engines pay their real ingestion cost: simd-json's
   required `&mut` copy halves its parse column, and rapidjson's in-situ
   variant beats its copying parse by 33% on twitter. A wired parser should
   parse from `const(char)[]` without requiring caller copies, and keep its
   own scratch reusable.

## Post-engine checkpoint (2026-07-06)

The native engine (SPEC §11, M7–M14) plus the first M15 optimization
rounds, measured on the same rig with the allocator field levelled (the
harness now raises glibc's trim/mmap thresholds at startup — by default
multi-MB document arenas are re-faulted every iteration, and who paid
depended on allocation-pattern luck; yyjson's twitter parse rose from
1.5 to 3.9 GB/s on the level field too). Snapshot:
`results/2026-07-06-ryzen9-7940hx-x86-64-v4-post-engine.json`.

| corpus (parse, MB/s) | std.json | wired-native | yyjson | ±10% gate |
| -------------------- | -------- | ------------ | ------ | --------- |
| twitter              | ~160     | 1755         | ~3930  | 3537      |
| citm_catalog         | ~290     | 2504         | ~3944  | 3550      |
| canada               | ~72      | 785          | ~1358  | 1222      |
| github_events        | ~170     | 2360         | ~4461  | 4015      |

Typed decode (twitter, the row this project exists for): **1518 MB/s
through the full wired codec** (`fromJSON!Twitter` — policy layer
included, measured faster than a hand-written view walk) vs 157 MB/s for
the retired std.json pipeline — a 9.7× end-to-end improvement — and
yyjson's accessor-walk decode at ~3450. Text-level validation
(`validateJson`, materializing nothing): twitter 1440, canada 1534 MB/s.

Instruction budget: twitter parse is at 12.4 ins/B against yyjson's 4.6
(from std.json's 92.6) with zero steady-state page faults on both — the
remaining ~2× to the scalar exit gate is pure instruction diet in the
string lane and the container machinery, the target of the continuing
M15 rounds. Findings that shaped these rounds: the four-multiply u128
decomposition never folds (now one LLVM `i128 mul`); a UTF-8 DFA loses
to well-predicted branches on uniform CJK; per-word validation fusing
loses to the two-pass scan; and glibc trim behavior can dominate — and
mislead — any parse-in-a-loop benchmark that doesn't control for it.

## Reproducing

```sh
cd libs/wired/bench/runtime
dub run -b bench -- --json=results/$(date -I)-<host>-$WIRED_BENCH_ISA.json
```

Two consecutive default-budget runs on the machine above agreed within ~5%
on every spot-checked row. Keep the default `--min-time-ms`: short budgets
under-report allocation-heavy paths (yyjson's copying parse measured
1.6 GB/s at a 300 ms budget vs 4.0 GB/s at the default 2 s — cold pages
dominate the first few thousand iterations). Numbers are machine- and
preset-specific; compare only within one snapshot.
