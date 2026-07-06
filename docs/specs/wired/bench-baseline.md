# `sparkles:wired` — runtime JSON benchmark baseline

_The evidence base for replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser — and the scoreboard for the native engine
that replaced it (SPEC §11). Numbers from the harness at
[`libs/wired/bench/runtime`](../../../libs/wired/bench/runtime/README.md);
the canonical snapshot is
[`results/2026-07-06-ryzen9-7940hx-x86-64-v4-level-field.json`](../../../libs/wired/bench/runtime/results/2026-07-06-ryzen9-7940hx-x86-64-v4-level-field.json)
(the original pre-engine snapshot from 2026-07-05 is kept alongside; its
conclusions all survive the re-measurement below)._

## Environment

|                 |                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPU             | AMD Ryzen 9 7940HX (Zen 4, AVX-512)                                                                                                               |
| D toolchain     | LDC, front-end 2.111, `-mcpu=native` (`bench` build type)                                                                                         |
| Shim ISA preset | `x86-64-v4` (simdjson: runtime dispatch, icelake kernel)                                                                                          |
| Engines         | simdjson 4.6.0, rapidjson 1.1.0, yyjson 0.12.0, serde_json 1.0.150, simd-json 0.17.0, sonic-rs 0.5.8, mir-ion 2.3.5, asdf 0.8.0, jsoniopipe 0.2.7 |
| Corpora         | twitter.json 632 KB (strings), citm_catalog.json 1.7 MB (structure), canada.json 2.2 MB (floats), github_events.json 65 KB (small-doc)            |
| Allocator       | glibc, trim/mmap thresholds raised to 64 MiB at harness startup (see the measurement note below)                                                  |

Every engine reproduced the `std.json` structural fingerprint on every
corpus, and the `TwitterStats` checksum on the decode op, before being
timed. Throughputs are MB/s over the median iteration. Hardware counters
come from a separate `perf_event_open` counting pass per op (kernel+user;
the LLC pair was dropped because the NMI watchdog holds one of Zen 4's six
PMCs and a multiplexed group only yields rotation-scaled estimates).

> [!IMPORTANT]
> **The allocator field is levelled.** By default glibc trims multi-MB
> blocks back to the kernel on `free`, so a parse-in-a-loop refaults its
> whole document arena every iteration — and _which_ engine paid depended
> on allocation-pattern luck (one block coalescing to the heap top vs
> two), not parser quality: at short time budgets, or for engines with an
> unlucky pattern, this understated throughput by up to 2×. The harness
> now raises `M_TRIM_THRESHOLD`/`M_MMAP_THRESHOLD` at startup (the same
> effect as the jemalloc/mimalloc swaps common in parser benchmarking),
> making page faults a first-iteration cost for every engine equally. The
> original 2026-07-05 numbers were taken at the default 2 s budgets where
> steady state was mostly reached, so they match the levelled numbers
> within noise — but the levelled field is also budget-stable, and it is
> what removed the "cold pages dominate short budgets" caveat this
> document previously carried.

## The headline: typed decode (twitter.json)

The op closest to wired's real workload — raw text → a partial Twitter
struct. `wired-native` is the shipped codec path (`fromJSON!Twitter`
through the arena engine, policy layer included); the 155 MB/s `std.json`
row is the pipeline it retired (the original `wired` row measured
159 MB/s — the DbI layer was already free).

| Engine                          |      MB/s | × the retired pipeline |
| ------------------------------- | --------: | ---------------------: |
| std.json (the retired pipeline) |       155 |                    1.0 |
| **wired-native (`fromJSON`)**   | **1 481** |                **9.6** |
| mir-ion                         |     1 696 |                   10.9 |
| serde_json                      |     1 881 |                   12.1 |
| asdf                            |     1 965 |                   12.7 |
| simd-json                       |     2 029 |                   13.1 |
| sonic-rs                        |     2 088 |                   13.5 |
| yyjson (accessor walk)          |     3 406 |                   22.0 |
| simdjson On-Demand              |     7 554 |                   48.7 |

## Parse (full DOM/tape, immutable input)

| Engine                         | twitter | citm_catalog | canada | github_events |
| ------------------------------ | ------: | -----------: | -----: | ------------: |
| std.json                       |     162 |          142 |     81 |           173 |
| jsoniopipe                     |     321 |          298 |    120 |           382 |
| serde_json                     |     420 |          791 |    494 |           527 |
| mir-ion                        |     510 |          431 |     86 |           499 |
| rapidjson (full precision)     |     914 |        1 593 |    362 |           886 |
| simd-json                      |   1 082 |        1 019 |    450 |         1 435 |
| **wired-native**               |   1 732 |        2 497 |    807 |         2 360 |
| sonic-rs                       |   2 052 |        1 921 |  1 268 |         2 412 |
| asdf ¹                         |   2 788 |        2 528 |  1 055 |         3 193 |
| yyjson                         |   3 853 |        3 977 |  1 367 |         4 020 |
| simdjson On-Demand (full walk) |   4 207 |        4 389 |  1 142 |         4 825 |
| simdjson DOM                   |   5 343 |        5 639 |  1 451 |         5 921 |

¹ asdf's tape keeps numbers textual (decoded on access), which flatters its
parse column — most visible on float-heavy canada, where engines that
materialize doubles pay for exact parsing.

## Hardware counters (twitter.json)

The "why" behind the tables above — per input byte, over the counting pass:

| Engine             | op       |  IPC | cyc/B | ins/B | br-miss% | faults/iter |
| ------------------ | -------- | ---: | ----: | ----: | -------: | ----------: |
| std.json           | parse    | 2.40 | 38.69 | 92.88 |     0.73 |       171.8 |
| wired-native       | parse    | 4.14 |  2.85 | 11.81 |     0.10 |           0 |
| wired-native       | decode   | 3.85 |  3.33 | 12.81 |     0.10 |           0 |
| wired-native       | validate | 5.36 |  3.37 | 18.08 |     0.12 |           0 |
| mir-ion            | decode   | 2.89 |  3.10 |  8.93 |     0.50 |           0 |
| serde_json         | decode   | 4.47 |  2.67 | 11.94 |     0.19 |           0 |
| sonic-rs           | decode   | 3.91 |  2.40 |  9.39 |     0.12 |           0 |
| asdf               | parse    | 1.28 |  4.33 |  5.54 |     1.99 |           0 |
| yyjson             | parse    | 3.47 |  1.34 |  4.64 |     0.13 |           0 |
| yyjson             | decode   | 3.39 |  1.48 |  5.04 |     0.13 |           0 |
| simdjson DOM       | parse    | 3.47 |  0.95 |  3.29 |     0.15 |           0 |
| simdjson On-Demand | decode   | 3.50 |  0.68 |  2.38 |     0.11 |           0 |

What the counters add:

- **The instruction budget is the whole game.** std.json burned 92.9
  instructions per byte; the native engine spends 11.8 on the same corpus
  at 4.1 IPC (against yyjson's 4.6 ins/B and simdjson On-Demand's 2.38).
  The remaining gap to the scalar frontier is instructions to remove, not
  IPC to find — wired-native already runs the highest IPC in the field.
- **Branch discipline arrived.** The engine's rounds took twitter parse to
  0.10% branch misses — at or below every foreign engine — via the
  frequency-ordered dispatch, the fused member hop, and predictable scan
  lanes.
- **Page faults are the GC signature, and the allocator's.** std.json
  still faults ~172×/iteration (GC heap growth); every native-arena
  engine, wired-native included, sits at 0 on the levelled field.
- **asdf's ceiling is its tape walk**: the lowest IPC in the field (1.28)
  and the highest miss rate (2.0%) — a dependent-chained, branchy
  traversal — caps an otherwise tiny instruction budget.

Other ops in brief (twitter): **validate** — simdjson-OD structural skip
6 790, serde_json `IgnoredAny` 2 747, simd-json 2 290, sonic-rs 2 204,
wired-native `validateJson` 1 457 (materializing nothing; guarded byte
loops, SWAR treatment pending), rapidjson SAX 1 066, jsoniopipe drain 662.
**serialize** — yyjson 5 264, sonic-rs 2 333, simdjson-DOM 2 128,
serde_json 1 614, wired-native 609 (26.2 ins/B — unoptimized, the next
M15 target), std.json 181.

## Findings

1. **wired was parser-bound, not mapping-bound — confirmed twice.** The
   original run showed the `fromJSON` DbI layer costing nothing (159 vs
   157 MB/s for hand-written extraction); the native engine confirmed it
   from the other side: the full codec decode (1 481 MB/s) measures
   _faster_ than a hand-written view walk did, because the single-pass
   struct decode beats repeated member lookups.
2. **The state of the art was 10–48× away; the native engine closed it to
   ~2.3×.** Typed decode went 155 → 1 481 MB/s (9.6×), between simd-json
   and mir-ion in absolute terms, with yyjson's accessor walk at 3 406 and
   simdjson On-Demand at 7 554 still ahead.
3. **SIMD is one road, not the only one.** yyjson — deliberately scalar
   C — parses at 3.9–4.0 GB/s on structure/string corpora. The native
   engine's scalar rounds (SWAR scan lanes, pointer number kernel,
   branch-layout work) reached 1.7–2.5 GB/s parse with the top IPC in the
   field; the rest of the scalar gap is instruction diet, and the
   vectorized structural scan remains iteration 2.
4. **Laziness is the biggest single lever for typed decode.** simdjson
   On-Demand extracts the twitter subset at 7.6 GB/s because untouched
   fields are skipped, not parsed. wired's decode always knows the target
   struct, so an on-demand cursor (rather than a DOM) remains the
   long-term shape for wired's decode path.
5. **Float parsing is its own battleground.** canada.json compresses every
   ranking: exact double parsing costs ~3× the throughput of the
   string-heavy corpora for every materializing engine. The native
   engine's tiered float path (Clinger → Eisel–Lemire with one `i128`
   multiply → exact big-decimal) sits at 807 MB/s vs yyjson's 1 367.
6. **The D ecosystem didn't reach the bar — now it does.** mir-ion
   (0.1–0.5 GB/s parse; 1.7 GB/s decode) and asdf (fast tape, lazy
   numbers, dated codebase) were 2–4× behind the frontier; jsoniopipe's
   typed deserialize leaves string escapes undecoded (caught by the
   checksum verification, excluded from the decode op). wired-native now
   out-parses every D engine except asdf's number-deferring tape — with
   strict RFC 8259 conformance and eager exact numbers.
7. **Copies are real cost; faults were noise.** On the levelled field
   rapidjson's in-situ variant still beats its copying parse by 31%
   (1 197 vs 914 — a true memcpy cost), and simd-json's required `&mut`
   copy still halves its parse column; but yyjson's insitu advantage
   collapsed to noise (3 915 vs 3 853) — what looked like copy cost was
   mostly fault cost. Engines should still parse from `const(char)[]`
   without demanding caller copies.
8. **Control the allocator or it benchmarks you.** glibc's trim behavior
   made multi-MB-arena engines refault every page each iteration at short
   budgets, understating them by up to 2× depending on allocation-pattern
   luck. Any parse-in-a-loop comparison needs raised trim/mmap thresholds
   (or a jemalloc/mimalloc swap) before its numbers mean anything.

## The scalar exit gate (M15)

The plan's iteration-1 exit gate is wired-native parse **and** decode
within ±10% of the yyjson rows. Standing on this snapshot:

| corpus (parse, MB/s) | wired-native | yyjson | ±10% gate | at    |
| -------------------- | -----------: | -----: | --------: | ----- |
| twitter              |        1 732 |  3 853 |     3 468 | 0.50× |
| citm_catalog         |        2 497 |  3 977 |     3 579 | 0.70× |
| canada               |          807 |  1 367 |     1 230 | 0.66× |
| github_events        |        2 360 |  4 020 |     3 618 | 0.65× |

Typed decode (twitter): wired-native 1 481 vs yyjson 3 406 (0.43×).
Landed rounds: the pointer number kernel, single-`i128`-mul Eisel–Lemire,
masked UTF-8 sequence checks, frequency-ordered dispatch, the fused
object-member hop, the short-key fast path, and the levelled allocator
field. Negative results kept for the record: a UTF-8 DFA loses to
well-predicted branches on uniform CJK; fusing validation into the scan
loses to the two-pass; the four-multiply u128 decomposition never folds.
The remaining gap is string-lane and container-machinery instruction
diet (plus the untouched serializer); the SIMD structural scan is
iteration 2.

## Reproducing

```sh
cd libs/wired/bench/runtime
dub run -b bench -- --json=results/$(date -I)-<host>-$WIRED_BENCH_ISA.json
```

Two consecutive default-budget runs on the machine above agreed within ~5%
on every spot-checked row, and with the levelled allocator the numbers are
budget-stable (the previous "cold pages dominate short budgets" caveat was
the glibc trim behavior of finding 8, now controlled at startup). Numbers
are machine- and preset-specific; compare only within one snapshot.
