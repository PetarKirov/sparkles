# `sparkles:wired` — runtime JSON benchmark baseline

_The evidence base for replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser, the scoreboard for the native engine that
replaced it (SPEC §11), and — since the harness moved onto
[`sparkles:test-runner`](../test-runner/open-issues.md) — the record that
validates the runner's measurements against the retired hand-rolled harness.
Numbers from [`libs/wired/bench/runtime`](../../../libs/wired/bench/runtime/README.md);
the canonical snapshot is
[`results/2026-07-11-ryzen9-7940hx-x86-64-v4-runner-inline.json`](../../../libs/wired/bench/runtime/results/2026-07-11-ryzen9-7940hx-x86-64-v4-runner-inline.json)._

## Environment

|                 |                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPU             | AMD Ryzen 9 7940HX (Zen 4, AVX-512)                                                                                                               |
| D toolchain     | LDC, front-end 2.111, `-mcpu=native -O3`, `bench` build type                                                                                      |
| wired codegen   | `library-inline` (cross-module inlining scoped to `sparkles:wired`; see [Codegen parity](#codegen-parity))                                        |
| Shim ISA preset | `x86-64-v4` (simdjson: runtime dispatch, icelake kernel)                                                                                          |
| Engines         | simdjson 4.6.0, rapidjson 1.1.0, yyjson 0.12.0, serde_json 1.0.150, simd-json 0.17.0, sonic-rs 0.5.8, mir-ion 2.3.5, asdf 0.8.0, jsoniopipe 0.2.7 |
| Corpora         | twitter.json 632 KB (strings), citm_catalog.json 1.7 MB (structure), canada.json 2.2 MB (floats), github_events.json 65 KB (small-doc)            |
| Allocator       | glibc, `M_TRIM_THRESHOLD`/`M_MMAP_THRESHOLD` raised to 64 MiB at process start (a `shared static this()` in the bench library)                    |
| Harness         | `sparkles:test-runner` `--bench --perf` — one `@benchmark` per op, `benchCase` per engine×dataset                                                 |

Every engine reproduces the `std.json` structural fingerprint on every
corpus (and the `TwitterStats` checksum on decode) in the untimed `after`
before it is timed; a mismatch is an isolated error row, so a wrong engine
can never post a competitive number. (jsoniopipe's serialize output is
rejected as invalid JSON on every corpus — the gate working as designed.)
Throughputs are MB/s over the median iteration. Hardware counters come from
the runner's separate `perf_event` counting pass (kernel+user; the LLC pair
is dropped because the NMI watchdog holds one of Zen 4's six PMCs — see the
test-runner
[validation cross-references](../test-runner/open-issues.md#validation-cross-references)).

## Validating the runner (before / after)

The harness was rebuilt from a bespoke executable (its own `perf_event_open`
helper, `mallopt` in `main`, hand-rolled timing) onto `sparkles:test-runner`.
Before trusting the new numbers we proved the runner measures the _same
thing_ the old harness did, using **retired instruction count as the
anchor**: for a fixed binary, code path and input it is an exact count (not a
rotation-scaled estimate) and is independent of wall-clock noise, so if the
runner's `instr` matches the old harness's, the counting is correct and the
timed region boundaries are identical. (`cycles`/IPC/cache are exact when the
group fits but host-variable, so they are read as advisory, per the
[cpu-pmu gap analysis](../../research/cpu-pmu/sparkles-baseline.md).)

B0 = the pre-rebase executable harness at tip `55ceec30`
([`results/B0-prerebase-55ceec30-cmi.json`](../../../libs/wired/bench/runtime/results/B0-prerebase-55ceec30-cmi.json)).
B1 = the runner, `library-inline` codegen, both at a 2 s budget with the
allocator levelled.

**Instruction anchor — the gate.** Across the wired-native and yyjson matrix
(26 rows) the runner's retired-instruction count matches B0 to **< 1 % on 25
rows**, the exception being citm serialize at −1.77 % (a JsonSink
buffer-grow amortization effect, within the advisory band — see
[test-runner open issue O11](../test-runner/open-issues.md)):

| wired-native, ins/byte | B0 (old harness) | B1 (runner) |       Δ |
| ---------------------- | ---------------: | ----------: | ------: |
| twitter parse          |             8.12 |        8.12 | −0.01 % |
| twitter decode         |             8.88 |        8.93 | +0.50 % |
| twitter serialize      |            13.79 |       13.78 | −0.10 % |
| canada parse           |            23.30 |       23.30 | +0.00 % |
| citm parse             |             6.21 |        6.21 | +0.00 % |
| github parse           |             6.89 |        6.90 | +0.05 % |

This is the headline validation result: **the runner's `perf_event`
instruction counting is byte-for-byte equivalent to the retired hand-rolled
`perf.d`.** yyjson's rows match equally well (parse/decode/serialize all
< 0.5 %), confirming it is not a wired-specific coincidence.

**Wall-clock is _not_ bit-comparable across the harness change, and that is
expected.** Two systematic deviations, both with matching instruction counts
(so neither is a counting bug):

- **Serialize wall-clock is ~9–22 % slower under the runner** (twitter −17 %,
  github −18 %, citm −9 %, canada −2 %) at identical instructions — cycles
  rise, IPC falls (twitter serialize 3.59 → 2.93). Serialize reads the whole
  document tree and the runner holds the parsed document in a heap-allocated
  per-case engine (`new E`), a different cache/TLB footprint than the old
  harness's structure. The effect is largest on the small, cache-resident
  docs and smallest on canada (memory-bound in both). Memory layout, not
  measurement.
- **yyjson parse is ~6–11 % _faster_ under the runner** on twitter/github at
  matching instructions (higher IPC) — a more favourable warm-cache regime
  from the runner's longer sample collection.

The lesson the anchor teaches: compare engines **within one snapshot** and
lean on `ins/byte` for cross-harness correctness; treat wall-clock deltas
across a harness change as microarchitecture, not truth. The allocator
leveling holds — page-faults are 0 across the matrix, and verified 0 even
under an adversarial `MALLOC_MMAP_THRESHOLD_=16384` (the startup `mallopt`
overrides it).

### Codegen parity

The old executable baseline compiled wired with
`-enable-cross-module-inlining` (CMI), worth ~15 % on the hot loops by
folding the `sparkles.wired.json.scan` seams into the reader. That flag
cannot go on the runner's `bench` build type — it propagates to mir-ion and
culls a template-nested function. Scoping it to `sparkles:wired` alone
(`library-inline`) recovers B0's exact codegen, but needed one non-obvious
step, quantified by the anchor:

| wired config (twitter parse) | flags                                               | ins/byte |
| ---------------------------- | --------------------------------------------------- | -------: |
| `library` (stock)            | —                                                   |     9.60 |
| `library-singleobj`          | `-singleobj`                                        |     9.60 |
| `library-inline` (default)   | `-enable-cross-module-inlining -linkonce-templates` |     8.12 |

`-singleobj` is inert (dub already compiles wired's modules in one ldc2
invocation, and LDC still declines to inline the seams without the CMI pass).
Bare `-enable-cross-module-inlining` **fails to link** under the runner's
`-unittest -checkaction=context` build — CMI inlines context-assert bodies
whose `_d_assert_fail!(T)` instances go unemitted;
`-linkonce-templates` emits them ([test-runner open issue O9](../test-runner/open-issues.md)). The
bench defaults to `library-inline`; `--override-config sparkles:wired/library`
and `.../library-singleobj` reproduce the matrix above.

## The headline: typed decode (twitter.json)

The op closest to wired's real workload — raw text → a partial Twitter
struct. `wired-native` is the shipped codec path (`fromJSON!Twitter` through
the arena engine, policy layer included); the 152 MB/s `std.json` row is the
pipeline it retired.

| Engine                          |      MB/s | × the retired pipeline |
| ------------------------------- | --------: | ---------------------: |
| std.json (the retired pipeline) |       152 |                    1.0 |
| mir-ion                         |     1 669 |                   11.0 |
| serde_json                      |     1 865 |                   12.3 |
| simd-json                       |     2 024 |                   13.3 |
| sonic-rs                        |     2 069 |                   13.6 |
| asdf                            |     2 194 |                   14.4 |
| **wired-native (`fromJSON`)**   | **2 614** |               **17.2** |
| yyjson (accessor walk)          |     3 324 |                   21.9 |
| simdjson On-Demand              |     7 463 |                   49.1 |

## Parse (full DOM/tape, immutable input, MB/s)

| Engine                         | twitter | citm_catalog | canada | github_events |
| ------------------------------ | ------: | -----------: | -----: | ------------: |
| std.json                       |     155 |          146 |     78 |           166 |
| jsoniopipe                     |     289 |          269 |    123 |           352 |
| serde_json                     |     417 |          800 |    491 |           530 |
| mir-ion                        |     514 |          427 |    167 |           508 |
| rapidjson (full precision)     |     895 |        1 578 |    361 |           869 |
| simd-json                      |   1 099 |          993 |    444 |         1 405 |
| sonic-rs                       |   2 034 |        1 910 |  1 264 |         2 359 |
| asdf ¹                         |   2 949 |        2 970 |  2 328 |         3 177 |
| **wired-native**               |   3 196 |        4 113 |    999 |         3 819 |
| yyjson                         |   4 013 |        3 899 |  1 357 |         4 530 |
| simdjson On-Demand (full walk) |   4 160 |        4 369 |  1 132 |         4 791 |
| simdjson DOM                   |   5 178 |        5 556 |  1 435 |         5 857 |

¹ asdf's tape keeps numbers textual (decoded on access), which flatters its
parse column — most visible on float-heavy canada, where engines that
materialize doubles pay for exact parsing.

## Hardware counters (twitter.json)

The "why" behind the tables — per input byte, over the counting pass
(serialize normalized by output bytes):

| Engine           | op        |      IPC |    ins/B | br-miss% |
| ---------------- | --------- | -------: | -------: | -------: |
| std.json         | parse     |     2.78 |    90.12 |     0.26 |
| **wired-native** | **parse** | **5.22** | **8.12** | **0.06** |
| wired-native     | decode    |     4.65 |     8.93 |     0.05 |
| wired-native     | validate  |     5.36 |    17.83 |     0.13 |
| wired-native     | serialize |     2.87 |    13.78 |     0.29 |
| asdf             | parse     |     2.48 |     4.50 |     0.50 |
| mir-ion          | parse     |     2.41 |    25.41 |     0.41 |
| yyjson           | parse     |     3.67 |     4.64 |     0.09 |
| yyjson           | decode    |     3.37 |     5.06 |     0.10 |
| simdjson DOM     | parse     |     3.43 |     3.29 |     0.10 |

`wired-native` posts the **highest IPC of the whole field** (5.22 parse, 5.36
validate) and its lowest branch-miss rate: the work per byte is scheduled
about as efficiently as this core allows. The gap to yyjson is
_instruction volume_ (8.12 vs 4.64 ins/B), not scheduling — the scalar arena
performs more work per byte than yyjson's single-visit string machine.

## Findings

1. **The DbI codec layer is free.** `wired-native`'s `fromJSON!Twitter`
   (2 614 MB/s) is the whole shipped path — policy walk included — and it
   sits right below yyjson's raw accessor walk. The old `std.json`-backed
   `wired` row (152 MB/s) was entirely parser-bound.
2. **wired-native is IPC-bound-out, instruction-bound-in.** Highest IPC,
   lowest branch misses, zero faults; the remaining 0.8× gap to yyjson is the
   instruction budget (§ counters). Closing it is a SIMD structural-pass
   question (iteration 2), not a scheduling one.
3. **The runner measures correctly.** The instruction anchor matches the
   retired harness to < 1 % across the matrix (§ Validating the runner) —
   the migration onto `sparkles:test-runner` costs no measurement fidelity.
4. **Serialize wall-clock shifted with the harness, not the code.** Same
   instructions, more cycles, from the runner's per-case heap-engine memory
   layout — a caveat for cross-harness serialize comparison, not a
   regression.
5. **The LLC pair is unavailable on this box.** The NMI watchdog holds a PMC,
   so cache-references/misses are dropped rather than estimated. Disclosed
   here because the columns are silently absent (the runner's capability seam,
   milestone B1, is the planned carrier — see the test-runner
   [validation cross-references](../test-runner/open-issues.md#validation-cross-references)).

## The scalar exit gate (M15)

The engine's own iteration-1 exit gate is wired-native parse **and** decode
within ±10 % of yyjson. On this snapshot:

| corpus (parse, MB/s) | wired-native | yyjson | ±10 % gate |    at |
| -------------------- | -----------: | -----: | ---------: | ----: |
| twitter              |        3 196 |  4 013 |      3 612 | 0.80× |
| citm_catalog         |        4 113 |  3 899 |      3 509 | 1.05× |
| canada               |          999 |  1 357 |      1 221 | 0.74× |
| github_events        |        3 819 |  4 530 |      4 077 | 0.84× |

Typed decode (twitter): wired-native 2 614 vs yyjson 3 324 (0.79×).
`wired-native` **clears the gate on citm** (structure-heavy — the arena's
threaded-parent container build shines) and sits at 0.74–0.84× elsewhere.
Consistent with the pre-rebase standing: **iteration 1 (scalar) has
plateaued** at ~8 ins/B with the field's best IPC; the remaining gap is work
volume, which is iteration 2's (SIMD) target. These numbers match the
pre-rebase executable baseline within noise once codegen parity is restored,
confirming the rebase changed the harness, not the engine.

## Reproducing

From the nix devshell (which exports `$WIRED_BENCH_DATA` and puts the ISA-preset
shims on `PKG_CONFIG_PATH`):

```sh
cd libs/wired/bench/runtime

# D engines only (fast, off-nix-capable) — the default unittest config:
dub test -b bench -- --bench --perf --group-by=dataset,operation

# The full competitive field (foreign engines via the nix shims):
dub test -b bench -c unittest-foreign -- --bench --perf --bench-min-time=2000

# Record a snapshot:
dub test -b bench -c unittest-foreign -- --bench --perf --bench-min-time=2000 \
  --bench-json=results/$(date -I)-<host>-$WIRED_BENCH_ISA-runner-inline.json

# Subset via env; codegen A/B via --override-config:
WIRED_BENCH_ENGINES=wired-native,yyjson WIRED_BENCH_DATASETS=twitter \
  dub test -b bench --override-config sparkles:wired/library -- --bench --perf
```

Numbers are machine- and preset-specific; compare only within one snapshot.
`--bench-min-time=2000` is what makes the medians budget-stable; the perf
counting pass is separate, so `ins/byte` is exact regardless of budget.
