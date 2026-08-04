# `sparkles:wired` — runtime JSON benchmark baseline

_The evidence base for replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser, the scoreboard for the native engine that
replaced it (SPEC §11), and — since the harness moved onto
[`sparkles:test-runner`](../test-runner/open-issues.md) — the record that
validates the runner's measurements against the retired hand-rolled harness.
Numbers from [`libs/wired/bench/runtime`](../../../libs/wired/bench/runtime/README.md);
the canonical snapshot is
[`results/2026-08-04-ryzen9-7940hx-x86-64-v4-scalar-round1.json`](../../../libs/wired/bench/runtime/results/2026-08-04-ryzen9-7940hx-x86-64-v4-scalar-round1.json),
taken after the first scalar optimization round; its predecessor
[`2026-08-03-…-rebaseline.json`](../../../libs/wired/bench/runtime/results/2026-08-03-ryzen9-7940hx-x86-64-v4-rebaseline.json)
is the "before" it is measured against. The runner-validation sections below still cite
the [2026-07-11 snapshot](../../../libs/wired/bench/runtime/results/2026-07-11-ryzen9-7940hx-x86-64-v4-runner-inline.json)
and its B0 predecessor, which are the artifacts that comparison was made
against._

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
within ±10 % of yyjson. After the first scalar round
(`results/2026-08-04-…-scalar-round1.json`, 2 000 ms budget, x86-64-v4):

| corpus (parse, MB/s) | wired-native | yyjson |    at | was (2026-08-03) |
| -------------------- | -----------: | -----: | ----: | ---------------: |
| citm_catalog         |        4 171 |  3 797 | 1.10× |            1.04× |
| twitter              |        3 371 |  3 571 | 0.94× |            0.86× |
| github_events        |        3 782 |  4 257 | 0.89× |            0.85× |
| canada               |        1 042 |  1 338 | 0.78× |            0.71× |

Typed decode (twitter): wired-native 2 684 vs yyjson 3 145 (0.85×, was 0.75×).
Every lane improved. `citm` clears the ±2 % gate outright, `twitter` clears
±10 %, `github_events` is a point outside it, and `canada` remains the
weakest lane by a wide margin.

> Read ratios **within one snapshot only.** yyjson's own wall-clock moves
> 10–15 % between runs on this host (twitter parse has been measured from
> 3.57 to 4.04 GB/s), so a ratio built from two different snapshots is
> mostly noise. Retired instructions are deterministic and are the right
> cross-snapshot anchor.
>
> A row whose `median` is far above its `min` is perturbed, not slow — the
> allocator-regime effect below. Check `median/min` before believing a
> regression.

### What closing the gap actually costs

Throughput is `IPC ÷ instructions-per-byte`, and wired already wins the IPC
term outright — so the deficit is entirely work volume:

| op / corpus         | ratio | wired IPC | yyjson IPC | IPC× | wired ins/B | yyjson ins/B | ins/B needed |  cut |
| ------------------- | ----: | --------: | ---------: | ---: | ----------: | -----------: | -----------: | ---: |
| parse/canada        | 0.78× |      4.49 |       3.85 | 1.17 |       21.17 |        14.25 |        17.00 | 20 % |
| parse/citm_catalog  | 1.10× |      5.14 |       3.82 | 1.35 |        6.21 |         5.13 |         7.06 |    — |
| parse/github_events | 0.89× |      4.53 |       3.43 | 1.32 |        6.63 |         4.45 |         6.00 |  9 % |
| parse/twitter       | 0.94× |      4.96 |       3.27 | 1.52 |        7.49 |         4.64 |         7.20 |  4 % |
| decode/twitter      | 0.85× |      4.41 |       3.02 | 1.46 |        8.30 |         5.06 |         7.54 |  9 % |

("ins/B needed" is the per-byte instruction budget that reaches 0.98 × yyjson
at today's IPC; "cut" is the reduction required from the current figure.)

wired retires **1.5–1.6× yyjson's instructions per byte** and claws most of it
back through IPC.

**Treat this table as a diagnostic, not a plan.** It holds IPC constant while
spending instructions, and scalar round 1 showed that assumption breaking in
both directions: wired's IPC advantage partly _is_ the extra work, so changes
that removed 6 % of instructions gave back more than 6 % of IPC and lost
throughput. Two of the round's four planned workstreams were rejected on that
basis after measuring clean instruction wins. Judge every change on MB/s from
the first measurement; use instructions only to find where to look.

### The inlining ceiling (`wired-inline`)

Before assuming the residue is algorithmic, it was worth pricing the cheap
explanation: wired's kernel is templates all the way down, so it is
code-generated in the package that _instantiates_ it — the benchmark, which
cannot enable `-enable-cross-module-inlining` (it propagates to mir-ion and
culls a template-nested symbol). `sparkles:wired`'s `library-inline` config
never reaches the instantiation that runs, and `scanNumber` disassembles to
thirteen calls into `sparkles:base`: 3× `tryFastDouble`, 1× `slowDouble`, 5×
`doubleToBits` — the last a single `movq`.

The `wired-inline` engine settles it by construction: the same parser built
from a single-translation-unit copy of its six modules (generated by
`libs/wired/bench/runtime/tools/gen-wired-inline.d`), where `scanNumber`
retains exactly one call — the cold `slowDouble` fallback. Retired
instructions per iteration, 2 000 ms budget, x86-64-v4, reproducible to the
instruction across three runs:

| corpus (parse) | wired-native | wired-inline |  delta |    B/s change |
| -------------- | -----------: | -----------: | -----: | ------------: |
| canada         |       51.37M |       48.71M | −5.2 % | 974M → 1 035M |
| citm_catalog   |       10.76M |       10.74M | −0.2 % |             — |
| twitter        |        5.13M |        5.13M |    0 % |             — |
| github_events  |      449.02k |      449.16k |    0 % |             — |

**Inlining is worth −5.2 % on the float lane and nothing anywhere else.** The
win is confined to `canada` because only the float path crosses the
`sparkles:base` boundary per token; the string and structure lanes were
already whole-program within `sparkles:wired`. Against yyjson's 32.08M on
`canada`, the copy moves the ratio from 1.60× to 1.52× — the remaining 33 %
is not something any inlining decision can recover.

**The −5.2 % has since been collected without the copy.** `doubleToBits`,
`bitsToDouble` and `tryFastDouble` (with `eiselLemire`, `mul64x64`,
`leadingZeros` and `pow2`, which have to follow or the entry point loses
_them_) were given empty template parameter lists, so they instantiate in
the caller's translation unit. `wired-native`'s `scanNumber` now retains the
same single `slowDouble` call the copy has, and the two engines report
**identical** instruction counts on all four corpora — 48.71M / 10.74M /
5.13M / 449.1k. Every consumer of `sparkles:base` gets it, with no
build-system change and no behaviour change. `wired-inline` remains as the
oracle that keeps the claim honest.

That completes the sweep of build-level levers, all of which are now
answered:

| lever                          | verdict                                                       |
| ------------------------------ | ------------------------------------------------------------- |
| `-singleobj`                   | no-op (dub already compiles wired in one invocation)          |
| cross-module inlining on wired | +18 % vs stock, but does not reach the bench's instantiation  |
| cross-module inlining on base  | no instruction change                                         |
| ThinLTO                        | net negative (canada +2.8 % instructions)                     |
| PGO / PGO + LTO                | unevaluable — LDC 1.41 is LLVM 20; only compiler-rt 21.x/22.x |
| single translation unit        | −5.2 % canada, 0 % elsewhere                                  |
| templating the float kernel    | the same −5.2 %, shipped — no flag, all consumers             |

Only the last one is a change anyone has to live with, and it is a source
change rather than a build-system one. The rest of the gap remains what the
disassembly said it was — yyjson resolves digit count at compile time through
a fully unrolled per-position ladder, against ~210 instructions per number of
runtime bookkeeping here around a ~35-instruction SWAR core.

Post-templating standing on `parse`, retired instructions per byte:

| corpus        | wired | yyjson | ratio |
| ------------- | ----: | -----: | ----: |
| canada        | 21.64 |  14.25 | 1.52× |
| citm_catalog  |  6.22 |   5.13 | 1.21× |
| twitter       |  8.12 |   4.64 | 1.75× |
| github_events |  6.90 |   4.44 | 1.55× |

`canada` has moved 23.30 → 22.48 (SWAR fraction tail) → **21.64**
(templating), a 7.1 % cut since the re-baseline, and is no longer the worst
lane by ratio — `twitter`'s string copy is.

### Scalar round 1

With the build-level levers exhausted, a `perf` profile of the current binary
retargeted the work. It found the residue was not one algorithmic deficit in
number parsing but four separable costs, and two of the four were pure
overhead:

| corpus  | `parseInto` | `scanString` | UTF-8 2nd pass | `scanNumber` |
| ------- | ----------: | -----------: | -------------: | -----------: |
| twitter |      52.3 % |       31.6 % |          9.9 % |        5.3 % |
| github  |      54.7 % |       36.9 % |          1.4 % |        5.3 % |
| canada  |      17.9 % |            — |              — |       80.4 % |

Shipped:

- **UTF-8 validation fused into the string scan.** The scanner recorded a
  seen-high flag and the reader then re-walked every string containing a byte
  ≥ 0x80 through `indexOfInvalidUtf8`. Bytes ≥ 0x80 now join the SWAR stop set
  and the run is validated in place. twitter **−7.8 %**, github −4.0 %.
- **One gulp shape for the fraction digits.** `digitRun8` subsumes
  `allDigits8`, so the aligned and padded reductions collapse into one loop
  with one `eightDigits` call site — the split had instantiated the reduction
  and its six SWAR constants twice. canada **−2.2 %**.

Rejected after measuring, and worth not repeating:

- **Inlining the token kernels into the grammar loop** (yyjson's shape).
  Retires 6–7 % fewer instructions and _loses_ throughput: citm −2.5 % MB/s,
  IPC 5.12 → 4.85. Tried as a whole-kernel inline and as a fast-lane /
  cold-tail split; both lose, and LLVM inlines the split fast lane on its own
  so `pragma(inline, false)` on the tail changes nothing.
- **An unrolled digit ladder for the integer part.** canada −4.3 %, citm
  **+5.2 %** — citm is 92 % nine-digit ids, exactly where the SWAR gulp is
  right and a ladder is worst, while canada is 2–3 digits and never reached
  the gulp at all. Dispatching between the shapes on `digitRun8` gives
  canada's win back to pay for the dispatch. The two populations want
  opposite code and the choice is not cheap enough to make.
- **`skipWs`.** No headroom: LDC already compiles its four-way compare into a
  `bt` bitmask test, the same 3–4 instructions yyjson's table lookup costs.

Where that leaves the ≤2 % target: `citm` clears it, `twitter` is 4 % of
per-byte work away, `github_events` 9 %, and **`canada` 20 %**. The float lane
is the open question, and the two most promising scalar restructurings for it
both came back negative above. Reaching ≤2 % there plausibly needs the number
lane vectorized.

> **The engine set perturbs the measurement.** `wired-inline` holds a second
> parsed document, and adding it to the matrix pushed `wired-native`'s twitter
> parse row bimodal — median 354 µs against a 181 µs minimum, while the clone
> running byte-identical code posted 187 µs. It is now behind
> `-version=BenchWiredInline`. This is the O11 engine-set-composition effect;
> when a row looks anomalous, compare its median to its own minimum first.

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
