# `sparkles:wired` — runtime JSON benchmark baseline

_The evidence base for replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser, the scoreboard for the native engine that
replaced it (SPEC §11), and — since the harness moved onto
[`sparkles:test-runner`](../test-runner/open-issues.md) — the record that
validates the runner's measurements against the retired hand-rolled harness.
Numbers from [`libs/wired/bench/runtime`](../../../libs/wired/bench/runtime/README.md);
the canonical snapshot is
[`results/2026-08-04-ryzen9-7940hx-x86-64-v4-scalar-round2.json`](../../../libs/wired/bench/runtime/results/2026-08-04-ryzen9-7940hx-x86-64-v4-scalar-round2.json),
taken after the second scalar optimization round; its predecessors
[`…-scalar-round1.json`](../../../libs/wired/bench/runtime/results/2026-08-04-ryzen9-7940hx-x86-64-v4-scalar-round1.json)
and
[`2026-08-03-…-rebaseline.json`](../../../libs/wired/bench/runtime/results/2026-08-03-ryzen9-7940hx-x86-64-v4-rebaseline.json)
are the "before"s they are measured against. The runner-validation sections below still cite
the [2026-07-11 snapshot](../../../libs/wired/bench/runtime/results/2026-07-11-ryzen9-7940hx-x86-64-v4-runner-inline.json)
and its B0 predecessor, which are the artifacts that comparison was made
against._

## Environment

|                 |                                                                                                                                                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPU             | AMD Ryzen 9 7940HX (Zen 4, AVX-512)                                                                                                                                                                               |
| D toolchain     | LDC, front-end 2.111, `-mcpu=native -O3`, `bench` build type                                                                                                                                                      |
| wired codegen   | `library-inline` (cross-module inlining scoped to `sparkles:wired`; see [Codegen parity](#codegen-parity))                                                                                                        |
| Shim ISA preset | `x86-64-v4` (simdjson: runtime dispatch, icelake kernel)                                                                                                                                                          |
| Engines         | simdjson 4.6.0, rapidjson 1.1.0, yyjson 0.12.0, serde_json 1.0.150, simd-json 0.17.0, sonic-rs 0.5.8, mir-ion 2.3.5, asdf 0.8.0, jsoniopipe 0.2.7                                                                 |
| Corpora         | twitter.json 632 KB (strings), citm_catalog.json 1.7 MB (structure), canada.json 2.2 MB (floats), github_events.json 65 KB (small-doc), mesh.json 724 KB and mesh.pretty.json 1.58 MB (numeric arrays/whitespace) |
| Allocator       | glibc, `M_TRIM_THRESHOLD`/`M_MMAP_THRESHOLD` raised to 64 MiB at process start (a `shared static this()` in the bench library)                                                                                    |
| Harness         | `sparkles:test-runner` `--bench --perf` — one `@benchmark` per op, `benchCase` per engine×dataset                                                                                                                 |

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

Independently of the codegen matrix, the runtime benchmark configs no longer
force shared Phobos, Gold, or `--export-dynamic`; default libraries are static
unless a foreign shim brings a shared runtime dependency. That change is
instruction-neutral: the mesh snapshots recorded before it reproduce to within
0.01 % after it.

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

### Scalar round 2

The next block by size was `parseInto` itself (52–55 % of twitter/github, ~98
instructions per value token against yyjson's 107 for its _entire_ parse), and
its hottest region was the `objectKey` fast path.

Shipped:

- **The `objectKey` probe folded onto `scanStringBody`.** The key fast path
  was a hand-rolled two-word probe that recomputed the scanner's four SWAR
  stop masks with a 15-byte cap — so every longer key (twitter's snake*case
  vocabulary: `in_reply_to_status_id_str`, `profile_background_color`, …)
  paid the probe \_and* an out-of-line `scanString` rescan from the opening
  quote. `scanStringBody` gained a `resolveNonAscii = false` mode (a byte
  ≥ 0x80 stops the scan unresolved instead of pulling the UTF-8 machinery
  into the caller), and the key site now runs one inline pass of the shared
  scanner for keys of any length, punting to the general kernel only on
  escape / non-ASCII / control / end-of-input. Two details mattered: the
  stop-byte test and NUL store go through the pool _pointer_ — the `@safe`
  slice forms re-added a bounds check the old probe's `@trusted` lambda
  didn't pay (≈ 1 % on github) — and non-ASCII stays out of the inline path
  exactly as the probe left it.
  Retired instructions per parse: twitter **−5.1 %** (4.73 M → 4.49 M), citm
  −0.9 %, github +0.3 % (its keys all fit the old probe; neutral), canada
  unchanged. twitter wall −3.6 % (186.7 µs → 180.0 µs median);
  per-byte instruction ratio vs yyjson 1.61× → 1.53×.
- **The inline pragma repeated on the scanner's lambda.**
  `pragma(inline, true)` on `scanStringBody` does not reach the `@trusted`
  lambda holding its whole body, and LDC left the validating instantiation
  (the one carrying `skipUtf8Run`) as an out-of-line call _inside_
  `scanString` — a call within a call per value string, 17 % of twitter's
  parse samples on the lambda symbol. One repeated pragma folds it. github
  **−2.4 %**, twitter −1.3 % instructions; wall flat everywhere (twitter
  IPC 4.91 → 4.79 absorbed the cut) — kept as a free seam removal.
- **Cells written via `JsonCell.set`, killing a dead zero store.** Every
  hot site did `*cell = JsonCell(kind, size); cell.bits = payload;` — the
  construction zero-initializes `bits` and LLVM does not reliably
  eliminate the dead 8-byte store before the overwrite. In twitter's
  profile the `movq $0` was the **single hottest instruction** (14.7 % of
  `parseInto` samples, wedged between the tag store and the payload
  store). `JsonCell.set()()` (empty template parameter list, so it
  code-generates in the instantiating TU) writes both fields in one shot.
  citm **−1.9 %** instructions / **−2.4 % wall** (4.21 GB/s, clear of
  yyjson's 3.92), github −1.1 % / −2.3 %, twitter −1.6 % / −1.6 %, canada
  −0.6 %. The rare instruction cut that wall-clock paid out in full.

Rejected after measuring (round 2):

- **The member count in a register.** Replacing `afterValue`'s
  `cells[parent].tag += 1 << 8` (a load-modify-store per value) with a
  local counter, stashing the outer count in the container cell's size
  bits across an open and restoring it at close. Instructions went **up**
  on every lane (citm +4.5 %, twitter +1.8 %, github +1.4 %, canada
  +1.6 %) and wall followed: the grammar loop is already spilling — the
  "register" lives on the stack, so the swap dance costs more than the
  arena RMW it replaced, which hits a cache line the loop owns anyway.

Cumulative for the round (twitter): 4.73 M → 4.36 M instructions
(**−7.8 %**), 186.7 µs → 177.7 µs wall (**−4.8 %**). The remaining
`parseInto` profile is store-bound (the key cell's two arena stores) and
register-pressure-bound (the key scan's SWAR constants rematerialize per
iteration); the structural lever left for the string lanes is a SIMD scan
(simdjson's 32-byte probe shape), which belongs to the vectorization
phase, not this scalar round.

Within the round-2 canonical snapshot (2 000 ms budget):

| corpus / op         | wired MB/s | yyjson MB/s | ratio | round 1 |
| ------------------- | ---------: | ----------: | ----: | ------: |
| citm_catalog parse  |      4 188 |       3 926 | 1.07× |   1.10× |
| twitter parse       |      3 542 |       3 942 | 0.90× |   0.94× |
| github_events parse |      3 874 |       4 502 | 0.86× |   0.89× |
| twitter decode      |      2 756 |       3 315 | 0.83× |   0.85× |
| canada parse        |      1 043 |       1 340 | 0.78× |   0.78× |

wired's own throughput rose on every string lane vs round 1 (twitter
parse **+5.1 %**, twitter decode +2.7 %, github +2.4 %; canada flat) —
the twitter/github _ratios_ still moved the wrong way because yyjson
posted 8–10 % hotter walls in this snapshot than in round 1's (its
documented 10–15 % swing; ratios only compare within one snapshot).
Per-byte instructions, the deterministic axis: twitter 7.49 → **6.91**,
github 6.63 → 6.42, citm 6.21 → 6.03, twitter decode 8.30 → 7.73,
canada 21.17 → 21.07. At this snapshot's IPCs the cut still needed for
0.98× is ~10 % on twitter, ~11 % on github, ~22 % on canada — numbers
that moved little despite the instruction wins, because yyjson's IPC
also ran higher here; the gate arithmetic is hostage to yyjson's
run-to-run behaviour, which is itself an argument for judging progress
on wired's own per-byte instructions and wall.

### Canada anatomy: where yyjson's 14.25 ins/B actually go

A side-by-side of the two number pipelines — `perf annotate` region
attribution on canada for both engines (wired's `scanNumber` holds 81 % of
its samples; yyjson's ladder, fast-path-2, and IEEE-packing blocks are
recognizable inside `yyjson_read_opts`), normalized per number
(111 126 numbers, ~20 B each: 2–3 integer digits, ~15 fraction digits, no
exponent, 0 % whitespace):

| cost region                                      | wired | yyjson |
| ------------------------------------------------ | ----: | -----: |
| digit reading + significand accumulation         |  ~148 |   ~145 |
| decimal→binary conversion (EL vs yy fast-path-2) |   ~30 |    ~55 |
| kernel entry/exit + sign + sections + decision   |  ~170 |    ~37 |
| grammar-loop share (dispatch, arrays, append)    |   ~79 |    ~52 |
| **total ins/number** (= ins/B × bytes ÷ numbers) |  ~427 |   ~289 |

**The digit machinery is at parity and the conversion is a wired win** —
yyjson's fast path 1 (exact FP multiply) almost never fires on canada
(17 significant digits ⇒ `sig ≥ 2^53`), so it runs fast path 2, the same
Eisel-Lemire-class 128-bit multiply `tryFastDouble` implements more
cheaply. **The entire gap is glue (~130) and grammar (~27).** Four
structural choices produce yyjson's ~37-instruction glue
(yyjson.c `read_number`, ~3860 ff):

1. **One fused fully-unrolled 19-slot ladder across integer + dot +
   fraction** (`repeat_in_1_18` → `digi_sepr_i` → `digi_frac_i`): hitting
   `.` at slot _i_ jumps into the same unrolled sequence and keeps
   accumulating into the same `sig`. A 17-digit canada number is
   straight-line code, one never-taken branch per digit, no counters —
   the unroll bound _is_ the budget.
2. **Exponents by pointer subtraction, once, at the end**
   (`exp_sig = -(i64)((cur - dot_pos) - 1)`), against wired's live
   counters `taken`/`fracTaken`/`intExtra`/`padded`/`fracExtraNonzero` —
   the register pressure whose spills and `movabs` rematerialization the
   annotate shows.
3. **No call seam** — `read_number` is `static_inline` in the parse loop:
   no prologue/epilogue (wired: 6 pushes + 6 pops + argument setup
   ≈ 15 ins/number), no dispatch ladder in front (wired tests
   `"`/`{`/`[`/`t`/`f`/`n` before the number case; canada is 99 %
   numbers).
4. **Branchless sign, single-store finish**
   (`((u64)sign << 63) | bits`) — wired re-tests the sign character at
   the end (`cmp $0x2d` = 4.7 % of `scanNumber` samples) and negates
   through the FP domain, then walks the `truncated`/`decided` flag
   lattice that exists for the exact fallback even though 17-digit canada
   numbers never truncate.

Every rejected experiment attacked one slice and paid elsewhere: the
ladder won canada −4.3 % but lost citm +5.2 % (citm's nine-digit ids
want the gulp), inlining the kernel collapsed citm's IPC, the goto
machine and the register member count lost to the same spill pressure
that makes the counters expensive. **Consequence for the plan:** SIMD
digit parsing attacks the ~148 that is already at parity — on its own it
buys at most half the gap. Closing canada means removing glue: pointer-
derived bookkeeping, a straight-line dominant-shape fast path with the
current machinery as fallback, cheaper entry/exit — with SIMD as a
component of that redesign, not a substitute for it.

### Scalar round 3: probing the glue

Round 3 worked the canada-anatomy conclusion directly — eight targeted
attempts at the ~170 ins/number of kernel glue. Two shipped, six came
back flat or negative; together they establish the scalar floor
empirically.

Shipped:

- **Numbers dispatched before literals on one compare.** The value
  dispatch tested `t`/`f`/`n` before the number fall-through; digits and
  `'-'` (0x2D–0x39) sit below `'f'` (0x66), so one compare splits the
  classes with error codes/offsets unchanged. canada **−0.95 %**
  instructions, citm −0.6 %, others neutral; wall flat-to-better.
- **Dot-peek fast lane for short integer parts.** Float corpora put the
  dot 1–3 digits in (canada's 2–3 digit coordinates), where the 8-wide
  gulp probe always failed before the pair loop ran. Two peeks at the
  dot position route those shapes straight to the fraction. canada
  **−5.1 %** instructions (46.98 M → 44.57 M, 21.0 → 19.8 ins/B), wall
  **+4 %** (0.78× → 0.815× within-snapshot). citm pays +2.2 %
  instructions (≈ −2 % wall, still 1.04× ahead); peek-after-failed-probe
  ordering keeps citm clean but forfeits most of the canada win (−1.6 %)
  — measured both, took canada.

Rejected after measuring (round 3):

- **One-gulp shape for the integer lead** (the fraction's winning shape
  applied to the integer part): canada instructions −0.4 % but wall
  **−9 %** (1.07 → 0.97 GB/s, IPC 4.35 → 4.20). The
  `digitRun8 → shift → reduce` serial dependency chain in front of every
  number loses to the pair loop's short, overlapped, predicted branches
  on 2–3-digit runs — the same failure mode as the SWAR `skipWs`.
- **Counters → pointer bounds** (`taken` ⇒ `k − intStart` with hoisted
  budget positions, yyjson's pointer discipline): instructions **up
  +3.1 %** on canada _and_ citm. The counter compiled to an
  immediate-operand compare; the pointer form traded one live counter
  for two live 64-bit bounds plus reg-reg compares. yyjson's pointer
  discipline only works because its unrolled ladder has **no loop bounds
  at all** — the unroll is the budget.
- **Float-tail restructure** (early returns instead of the
  `decided`/`truncated` flags, sign as an OR into IEEE bit 63): flat on
  every lane, measured twice — once as the full restructure, once as the
  minimal sign-bit-only delta (identical instruction count; the
  annotate's hot `cmp $0x2d` was sampling skid, not a real sign
  re-test). LLVM already generates equivalent code for both forms.

**Where this leaves the scalar campaign: at its floor, now empirically.**
Every glue region the anatomy identified has been attacked directly:
restructures that add or move live values lose to the kernel's spill
pressure, SWAR consolidations on short runs lose to dependency-chain
latency, and the flag/sign tails are already optimal in LLVM's hands.
canada stands at **0.815×** within-snapshot (44.57 M instructions,
19.8 ins/B vs yyjson's 14.25); reaching 0.98× needs ~18 % more wall,
which is not reachable by ±2 % scalar deltas. The remaining path is the
fused redesign with SIMD digit/string scanning as a component
(§ "Canada anatomy", consequence paragraph).

### Scalar round 4: subtree kernels and grammar-boundary fusion

Round 3's conclusion was too local: the general number kernel had reached its
scalar floor, but a profitable design did not require entering that kernel for
every coordinate. Round 4 moved dominance out of the generic grammar instead.
The canonical result is
[the scalar-round-4 snapshot](../../../libs/wired/bench/runtime/results/2026-08-04-ryzen9-7940hx-x86-64-v4-scalar-round4.json)
(2 000 ms budget, immutable-input `parse`, `wired-native` and yyjson in one
run):

| corpus / op         | wired GB/s | yyjson GB/s |  ratio | wired instructions | yyjson instructions |
| ------------------- | ---------: | ----------: | -----: | -----------------: | ------------------: |
| canada parse        |      1.549 |       1.334 | 1.161× |            25.84 M |             32.08 M |
| citm_catalog parse  |      4.153 |       3.924 | 1.058× |             9.96 M |              8.86 M |
| github_events parse |      4.043 |       4.221 | 0.958× |           373.22 k |            289.23 k |
| twitter parse       |      3.747 |       3.856 | 0.972× |             3.92 M |              2.93 M |
| twitter decode      |      3.214 |       3.410 | 0.942× |             4.25 M |              3.20 M |

The four-corpus parse throughput geomean is **1.034× yyjson**. The two small
string-heavy rows remain within 4.3%; their wall ordering moves between runs
as yyjson's documented host swing changes (wired won both in separate
same-code measurements), so the snapshot above remains the comparison of
record. Canada changed category entirely: round 3 was 0.815× / 44.57 M
instructions; round 4 is **1.161× / 25.84 M**.

Shipped:

- **A nested numeric-array subtree kernel.** A minified `[[` lookahead routes
  GeoJSON coordinate matrices into one out-of-line scalar grammar loop. It
  keeps threaded-parent state local, inlines the dominant short-decimal lane,
  and amortizes its call frame over the whole subtree. Any other JSON shape or
  malformed token returns with the caller's arena cursor unchanged, so the
  general grammar reparses safely. Calling it for flat arrays or broader
  candidates lost on string corpora; the narrow `[[` gate is load-bearing.
- **A fused short-decimal lane.** One to three integer digits plus up to 16
  fraction digits and no exponent are accumulated by two scalar SWAR gulps and
  sent to the existing exact `tryFastDouble` conversion. Literal `-8`/`-16`
  exponent instantiations let LLVM specialize the conversion. It is available
  to the general number scanner, but the matrix kernel is what removes
  canada's per-number grammar/call glue.
- **Pointer arena state.** The append cursor and temporary threaded parent are
  `JsonCell*` values, possible because the arena is pre-sized and never moves.
  Closing a container is pointer subtraction, with its object/array bit cached
  in the grammar state. This removed repeated base-plus-index formation without
  adding live bounds.
- **Four scalar string words per iteration.** `scanStringBody` probes 32 bytes
  as four ordered 64-bit words. It remains scalar—no vector type or explicit
  SIMD intrinsic—and preserves the first-stop and UTF-8 semantics. Extending
  the same shape to eight words increased work on ordinary strings and lost.
- **Object grammar boundaries fused to their conventional spelling.** An
  immediate colon bypasses the whitespace scanner, exactly one post-colon
  space bypasses its eight-space probe, and `afterValue` keeps its first
  delimiter load live across the immediate comma/close path. All legal RFC
  whitespace spellings retain the original fallback. Together these changes
  moved twitter from about 4.12 M to **3.92 M** instructions and reduced citm
  too.
- **Typed field dispatch without libc `memcmp`.** Native struct decode switches
  first on key length, then emits fixed-size scalar word comparisons for the
  compile-time field names. Its recursive result now carries only failure
  status plus value; the full `JsonError` occupies one caller-owned slot and is
  populated only on failure. In the final decode profile, parser symbols still
  account for ~92% of retired instructions; codec work is no longer the main
  gap.

Rejected after measuring (round 4): widening the string probe to 64 bytes;
calling the numeric subtree kernel for flat arrays; deriving object state from
the parent tag or tagging it into the parent pointer; replacing the exact
whitespace kernel with 4-byte tails/newline loops; compact keys that require
`strlen` during decode; and combining arena/pool allocation. Several reduced
instructions but also reduced IPC enough to lose wall time. The accepted
grammar-boundary fast paths are deliberately local rather than changes to
`skipWs` itself.

### Scalar round 5: narrow clean strings and padded grammar sentinels

Round 5 targeted twitter and github-events without giving back the canada/citm
wins. The canonical result is
[the scalar-round-5 snapshot](../../../libs/wired/bench/runtime/results/2026-08-05-ryzen9-7940hx-x86-64-v4-scalar-round5.json)
(2 000 ms budget, immutable-input `parse`, `wired-native` and yyjson in one
run):

| corpus / op         | wired GB/s | yyjson GB/s |  ratio | wired instructions | yyjson instructions |
| ------------------- | ---------: | ----------: | -----: | -----------------: | ------------------: |
| canada parse        |      1.554 |       1.327 | 1.171× |            25.84 M |             32.08 M |
| citm_catalog parse  |      4.253 |       3.807 | 1.117× |             9.42 M |              8.86 M |
| github_events parse |      4.151 |       3.951 | 1.050× |           333.98 k |            289.24 k |
| twitter parse       |      3.706 |       3.597 | 1.031× |             3.64 M |              2.93 M |
| twitter decode      |      3.144 |       3.190 | 0.985× |             3.97 M |              3.20 M |

The four-corpus parse throughput geomean is **1.091× yyjson**, with wired
ahead on every parse row in the same run. The deterministic instruction delta
from round 4 is −10.5% on GitHub (373.22 k → 333.98 k), −7.1% on Twitter parse
(3.92 M → 3.64 M), −6.6% on Twitter decode (4.25 M → 3.97 M), and −5.4% on
citm (9.96 M → 9.42 M). Canada remains at 25.84 M.

Two changes account for the reduction:

- **A narrow clean-value string lane.** Corpus measurement found 752 GitHub
  value strings (mean raw length 50.6 bytes), only 0.66% escaped and 0.27%
  non-ASCII; Twitter has 4 754 value strings (mean 42.5 bytes), 6.56% escaped
  and 15.88% non-ASCII. Before entering the full Unicode/unescape kernel,
  values now probe ordered scalar words with non-ASCII left unresolved. A
  quote completes the cell immediately; every other stop retries through the
  authoritative general scanner, so validation/error semantics are unchanged.
  Two words is load-bearing: it stays small enough for LDC to inline without
  the four-word register expansion, while avoiding the loop frequency of one
  word. General strings and object keys retain four words.
- **The existing zero padding is also the grammar sentinel.** The parser
  already owns eight trailing zero bytes for safe scalar word loads. Value,
  empty-container, object-key, and whitespace-delimited post-value paths now
  read that sentinel instead of comparing `i` with `n` before the read. Cold
  failures still compare the offset, distinguishing true end-of-input from an
  embedded NUL and retaining the previous error code/offset.

Rejected after measuring (round 5): passing the first clean-scan stop into the
general fallback (+5 k GitHub, +40 k Twitter instructions); a second clean
UTF-8 lane before unescaping (+6 k/+80 k, because escaped strings paid three
scans); one-, three-, and four-word clean-value widths; and changing the key
probe to two words (instruction-neutral but GitHub wall regressed from 15.9 µs
to 16.9 µs through lower IPC).

### Scalar round 6: long numeric arrays and pretty whitespace

Adding simdjson's mesh pair made two blind spots measurable. Compact mesh has
73 013 numbers in long flat position/index/color buffers, while the existing
numeric subtree scanner accepted nested coordinate matrices only. Pretty mesh
is 52% whitespace and uses longer decimal spellings, so blindly reusing the
compact short-float speculation scans many tokens twice.

The canonical
[baseline](../../../libs/wired/bench/runtime/results/2026-08-05-ryzen9-7940hx-x86-64-v4-mesh-baseline.json)
and
[round-6 snapshot](../../../libs/wired/bench/runtime/results/2026-08-05-ryzen9-7940hx-x86-64-v4-mesh-round1.json)
use the same 2 000 ms budget and same-process wired/yyjson comparison:

| corpus      | wired baseline | wired round 6 |     yyjson | round-6 ratio | wired instructions baseline → round 6 |
| ----------- | -------------: | ------------: | ---------: | ------------: | ------------------------------------: |
| mesh        |     1.148 GB/s |    1.645 GB/s | 1.314 GB/s |        1.252× |                     15.12 M → 10.01 M |
| mesh_pretty |     1.664 GB/s |    1.899 GB/s | 1.791 GB/s |        1.061× |                     21.40 M → 17.35 M |

Four measured choices produce the result:

- A bounded profitability probe admits nested arrays immediately and flat
  arrays only after a nine-value numeric-looking prefix. Mixed/malformed
  candidates remain speculative and fall back to the authoritative grammar.
- A narrow in-array integer kernel handles one-to-nineteen-digit signed and
  unsigned values, preserving `-0`, `long.min`, the unsigned range, and the
  floating policy below `long.min`; fractions, exponents, and 20-digit values
  retain the full number scanner.
- Compact and pretty subtree loops are separate template instantiations. The
  compact loop keeps the short-float converter; the pretty loop avoids that
  failed speculation and skips complete eight-space words.
- Pretty acceleration is limited to shallow eight-space-indented numeric
  buffers. This excludes the measured losing shapes: Twitter's deep short
  index arrays and citm's deep nine-digit ID arrays. The general grammar's
  nine-digit SWAR lane remains faster for the latter.

Rejected while converging: accelerating all flat arrays before the integer
kernel (compact improved modestly but citm gained 3.3% instructions); sending
all pretty arrays through the compact subtree loop (pretty mesh rose from
21.40 M to 24.57 M instructions); sharing one runtime-branched compact/pretty
loop (compact IPC collapsed and Twitter/citm regressed); and accelerating all
deep pretty numeric arrays (reparsed short/mixed arrays erased the mesh win).

**What round 6 costs the other four corpora.** The mesh snapshots contain
mesh rows only, so no single snapshot shows the trade. Measured against the
round-5 snapshot in a
[same-host recheck](../../../libs/wired/bench/runtime/results/2026-08-05-ryzen9-7940hx-x86-64-v4-session-recheck.json)
of the whole field, the accepted flat-array probe adds:

| corpus              |  round 5 |      now |   delta |
| ------------------- | -------: | -------: | ------: |
| citm_catalog parse  |  9.424 M |  9.549 M | +1.33 % |
| canada parse        | 25.844 M | 25.951 M | +0.41 % |
| twitter parse       |  3.643 M |  3.656 M | +0.37 % |
| github_events parse | 333.98 k |  335.0 k | +0.31 % |
| twitter decode      |  3.974 M |  3.974 M |  0.00 % |

That is `shouldScanNumericArray`'s nine-value prefix probe running on arrays
that never reach the subtree loop; citm pays most because it is array-dense.
The trade is worth taking — mesh −33.8 % instructions against citm +1.33 %,
and citm still measures 1.102× — but it is a real cost and belongs in the
ledger next to the win. Note the distinction from the rejected variant above:
that one admitted flat arrays _before_ the integer kernel and cost citm 3.3 %;
the shipped probe costs 1.33 %.

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
