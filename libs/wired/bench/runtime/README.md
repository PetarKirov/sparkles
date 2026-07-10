# `runtime-bench` — runtime JSON benchmark for `sparkles:wired`

Step 1 of replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser: measure the field. The benchmark is a set of
`@benchmark` unittests driven by `sparkles:test-runner`'s `benchCase` —
engines × datasets × ops, one row per case.

| Ecosystem | Engines                                                | Integration      |
| --------- | ------------------------------------------------------ | ---------------- |
| D         | `std.json` (baseline), `mir-ion`, `asdf`, `jsoniopipe` | dub dependencies |
| D (SUT)   | `wired` (typed `decode` only today)                    | in-tree          |

The old bespoke executable harness also drove C/C++/Rust engines (yyjson,
simdjson, rapidjson, serde_json, simd-json, sonic-rs) through nix-built
shims; those adapters are **not wired up** on the runner port yet — the
historical numbers live in `results/` and
[`docs/specs/wired/bench-baseline.md`](../../../../docs/specs/wired/bench-baseline.md).

## Running

From the devshell (which provides the corpora as `$WIRED_BENCH_DATA`):

```sh
cd libs/wired/bench/runtime

# Canonical run: release codegen tuned to the host CPU (-mcpu=native).
dub test -b bench -- --bench --perf --group-by=dataset,operation

# Useful subsets while iterating:
dub test -b bench -- --bench -i 'wired\.serialize'      # one op
WIRED_BENCH_ENGINES=asdf,std.json \
WIRED_BENCH_DATASETS=twitter \
dub test -b bench -- --bench                            # engine/dataset subset

# Machine-readable dump (see Recorded results below):
dub test -b bench -- --bench --perf --bench-min-time=2000 \
    --bench-json=results/$(date -I)-<host>-$WIRED_BENCH_ISA.json
```

Each op is its own `@benchmark` test (`wired.parse`, `wired.validate`,
`wired.serialize`, `wired.decode`), so the runner's `-i`/`-e` select ops;
engines and datasets subset via the `$WIRED_BENCH_ENGINES` /
`$WIRED_BENCH_DATASETS` comma lists (empty = all).

Numbers from non-release builds are meaningless; the runner prints a loud
warning under `--bench` when built with asserts enabled. `dub test` without
`-b bench` is a debug build — use it for correctness only.

## Op semantics

Engines advertise capabilities through design-by-introspection traits
(`src/sparkles/wired_bench/traits.d`); each engine gets only the rows its
adapter supports.

| Op             | Contract                                                                                                                                                                                                                 |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `parse`        | immutable input → the engine's document. Any copy or padding the engine requires happens **inside** the timed region — the honest immutable-input service contract. The document is released untimed between iterations. |
| `parse-insitu` | destructive in-place variants; the engine's scratch copy of the input is made inside the timed region. (No D engine reaches it today.)                                                                                   |
| `serialize`    | a pre-parsed document (untimed `setup`) → minified JSON string, timed. Throughput is normalized over the engine's own output bytes.                                                                                      |
| `validate`     | raw bytes → well-formedness verdict, materializing nothing. Only engines with a genuinely cheaper-than-parse path get a row (jsoniopipe's tokenizer drain today) — for the rest it would equal `parse`.                  |
| `decode`       | raw bytes → a shared partial Twitter struct — the typed-deserialization pipeline (`twitter.json` only). This is the op closest to wired's real workload.                                                                 |

## Hardware counters

Pass the runner's `--perf` for a per-row hardware-counter view (IPC,
instructions/iter, branch/cache miss rates): the runner opens one
`perf_event` group, gives every case a dedicated counting pass bracketed by
`ENABLE`/`DISABLE` ioctls (so the ns/iter medians are never perturbed),
scales by the pass's own multiplex ratio, and drops the LLC pair when
calibration shows the group would multiplex. `--syscalls` and the tier-0
`/proc` counters (`--metrics=syscr,cache-hit,…`) work too — see the
[test-runner docs](../../../../docs/libs/test-runner/how-to/benchmark.md).

## Verification

Every op verifies itself once, in its untimed `after`, against the
`std.json` reference for its dataset:

- `parse` / `parse-insitu` — the parsed document must reproduce the
  reference **fingerprint** (counts of every value kind, array/object sizes,
  decoded string/key bytes, and the sum of all numbers at 1e-9 relative
  tolerance);
- `serialize` — the engine's own output is re-fingerprinted through the
  reference parser (structural, format-independent), so wrong _or invalid_
  output is caught (this gate currently flags jsoniopipe: its serialized
  twitter/github_events output is rejected by `std.json` — an isolated error
  row, not a competitive B/s figure);
- `validate` — a bool-returning validate must accept the (valid) corpus; a
  void one signals rejection by throwing, which error-rows on its own;
- `decode` — the decoded Twitter stats must match the reference extraction.

A mismatch turns that one case into an error row (the matrix continues) and
fails the run's exit status — an engine that parses _differently_ must never
look _faster_. A registration-time crash (engine constructor, sizing probe)
is likewise isolated into a per-case error row.

## ISA policy

The bench is built by dub outside the nix sandbox and uses `-mcpu=native`
(the `bench` build type: `unittests releaseMode optimize inline` + `-O3
-allinst`). Note vs the old executable harness: `-enable-cross-module-inlining`
is off (mir-ion's `-unittest` + release build culls template symbols under
it), a known ~15% delta on wired's number-heavy hot loops — compare new
numbers only against baselines regenerated under this build type. The
devshell still exports `$WIRED_BENCH_ISA` (the foreign-engine preset name)
for results-file naming.

## Recorded results

Baseline snapshots live under `results/`, named `<date>-<host>-<isa>.json`.
New snapshots come from the runner's `--bench-json` (see Running above);
`--bench-min-time=2000` restores the old harness's 2 s per-case budget —
short budgets under-report allocation-heavy paths. Old → new field mapping:
`engine` → `name`; `dataset`/`op` → `labels.*`; `iters` → `samples`;
`mbPerSec` → `metrics["B/s"] / 1e6`; raw perf totals → per-iteration catalog
cells (`ipc`, `instr`, …). The findings note that reads the recorded
snapshots is
[`docs/specs/wired/bench-baseline.md`](../../../../docs/specs/wired/bench-baseline.md).

## Datasets

Pinned by `nix/packages/wired-bench-data.nix` (never committed):
`twitter.json` (632 KB, string-heavy), `citm_catalog.json` (1.7 MB,
structure-heavy), `canada.json` (2.2 MB, float-heavy) from
nativejson-benchmark, and `github_events.json` (65 KB, small-document
regime) from simdjson. Export `$WIRED_BENCH_DATA` to point elsewhere;
`$WIRED_BENCH_DATASETS` subsets the list per run.
