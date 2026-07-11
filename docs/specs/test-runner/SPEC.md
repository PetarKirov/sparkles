# `sparkles:test-runner` — Measurement-layer specification

_Audience: developers and coding agents building against the runner. This
document is normative at the contract level — it states what the layer
provides (and, for marked sections, what it is specified to provide once its
milestone lands), not why. For the delivery plan, see [PLAN.md](./PLAN.md);
for unresolved behavioral questions, see [open-issues.md](./open-issues.md);
for tutorial/how-to exposition, see the
[library docs](../../libs/test-runner/index.md). The design evidence base is
the [CPU-PMU research catalog](../../research/cpu-pmu/index.md) — in
particular the [audit baseline](../../research/cpu-pmu/sparkles-baseline.md)
and the [backend proposal](../../research/cpu-pmu/backend-proposal.md)._

Sections describing behavior that is not yet implemented carry an explicit
**(target — Bn/Mn)** marker naming the [PLAN.md](./PLAN.md) milestone that
makes them true. Unmarked statements describe shipped behavior.

## 1. Overview

`sparkles:test-runner` is a general-purpose `unittest` runner (parallel
runtime tests plus `@ctfe`, `@betterC`, and `@wasm` modes) with a
benchmark-measurement layer under `--bench`. This specification covers the
whole surface at contract level and the measurement layer in depth.

The measurement layer has **two measurement models**:

- **`@benchmark`** — per-iteration statistics: the timed body runs many times;
  the runner reports median / median-absolute-deviation / min / max
  nanoseconds per iteration, plus per-iteration counter averages.
- **`@workload`** _(target — M4)_ — window statistics: the body runs once (or
  a few reps); the runner reports counter **deltas and integrals across the
  window**, including a wall-clock decomposition into on-CPU and attributable
  off-CPU time.

Three invariants shape everything:

1. **Counting is separated from timing.** The timing pass runs with no
   counters enabled; counters bracket a separate pass. No repaint, GC, or
   counter I/O ever runs concurrently with a timed body.
2. **Every metric is classed** `quantitative` (near-zero perturbation — the
   only class a reported or gated number may read) or `diagnostic` (perturbs;
   explains a result; rendered separately, never blended into a headline).
3. **Capability is a runtime probe result.** Every acquisition source opens
   through a probe handshake and **degrades to reported absence, never
   fails the run and never fabricates numbers** — absences are enumerated
   per capability with a reason (§6.2), not just per-tier status strings.

## 2. Package and module layout

The runner is two dub packages:

- **`sparkles:test-runner`** (`libs/test-runner`) — a thin `sourceLibrary`
  shim (compile-time discovery + registration) compiled into each test
  binary.
- **`sparkles:test-runner-impl`** (`libs/test-runner-impl`) — the prebuilt
  implementation library, linked across an `extern(C)` seam.

Measurement modules (all under
`libs/test-runner-impl/src/sparkles/test_runner/`):

| Module           | Role                                                                   |
| ---------------- | ---------------------------------------------------------------------- |
| `bench.d`        | protocol driver, `benchIter`/`benchCase`/`blackBox`, `BenchStats`      |
| `perf.d`         | hardware-counter tier (`perf_event` group)                             |
| `perf_group.d`   | shared counting bracket + multiplex-delta scaling                      |
| `tier0.d`        | no-privilege tier (`getrusage` + `/proc/self/io`)                      |
| `syscalls.d`     | syscall-tracepoint tier                                                |
| `metrics.d`      | the metric catalog seam (§5)                                           |
| `capability.d`   | the capability seam: flags, reports, backend trait, host probes (§6.2) |
| `raw.d`          | raw hardware-event tier (`raw:r<hex>` selectors)                       |
| `event_naming.d` | symbolic event names via soft libpfm4 (`pfm:<name>`)                   |
| `rdpmc.d`        | user-space counter reads (the `selfMonitoring` primitive)              |
| `bench_json.d`   | the `--bench-json` emitter (§8.3)                                      |
| `reporting.d`    | tables, live displays, progress                                        |
| `skip.d`         | `skipTest`                                                             |

Planned modules _(targets)_: `workload.d`/`psi.d` (M4/M5),
`cache_regime.d`/`provenance.d`/`cgroup.d` (M6–M8), `histogram.d` (B5),
`sampling.d`/`symbolize.d` (B6), `offcpu.d` (M9), `loadgen.d` (M10), plus
per-OS backend variants inside the existing modules (B3/B4).

## 3. Attribute and in-body surface

Marker UDAs live in `sparkles.test_runner.attributes` and must be imported
unconditionally (not under `version (unittest)`).

- **`@benchmark`** — the test is skipped by normal runs and measured by
  `--bench`. **`@benchmark(iterations: N)`** pins the iteration count instead
  of auto-scaling: per sample for batched timing; a per-call `benchCase` runs
  exactly N timed calls, one sample each.
- **`benchIter(scope void delegate())`** — measure only the closure; the rest
  of the body is setup. Outside `--bench` the closure runs exactly once.
- **`benchCase(name:, labels:, timed:, after:, setup:, teardown:, metrics:)`**
  — register one row of a matrix benchmark. Under `--bench` the case is
  _registered_ and measured after the body returns (deferred execution:
  varying state must be captured by value); outside `--bench` it runs once
  immediately. `timed`'s result flows to `after`, which runs untimed to
  verify/release it; a throwing `after` or an `Expected` error isolates into
  a single in-table error row while the rest of the matrix measures. A soft
  error returned on the inert (non-`--bench`) path is re-raised as an
  exception. Label keys/values and `name` must not contain `\x1f` (the group
  separator) — violation is a registration-time error.
- **`blackBox(x)`** — identity the optimizer cannot see through; route
  measured inputs and results through it.
- **`skipTest(reason)`** (`sparkles.test_runner.skip`, `@safe pure nothrow
@nogc`) — skip the enclosing test at runtime: a yellow `⊘` line plus an
  `N skipped` summary segment; never fails the run. Under `--bench` a
  case-level skip renders as a yellow row.
- **Client metrics** — `Metric(Unit unit, double amount, Mode mode)`:
  `rate` reports `amount ÷ iteration-time` as `<unit>/s`; `level` reports the
  per-iteration amount as-is. `Unit` is an open-basis symbol (`"B"`, `"req"`,
  …); see §5.3.
- **`@workload`** _(target — M4)_ — window-model marker with a cache-regime
  request and rep count; in-body `workloadWindow`/`workloadFiles` primitives.

## 4. Measurement protocol

Normative for `@benchmark`:

1. **Auto-scaling** — the per-sample iteration count doubles until one sample
   takes at least `BenchConfig.minSampleTime` (default 5 ms;
   `--bench-min-time=MS` overrides), then `sampleCount` (32) samples are
   collected. Timing uses raw `MonoTime` ticks (no hectonanosecond
   quantization).
2. **Statistics** — median, median absolute deviation, min, max ns/iter. No
   mean is reported.
3. **Per-call vs batched** — `benchCase` times each call individually (one
   sample per call; `--bench-min-time` is the minimum _total_ measured time,
   samples accumulate past 32 until met); `benchIter`/whole-body timing is
   batched (`--bench-min-time` is the per-sample auto-scale target).
   `@benchmark(iterations: N)` pins both shapes and makes the budget inert.
4. **Counting passes** — after timing, each _available_ source re-runs the
   body under its counters, capped at `perfMaxIters` (100 000) iterations,
   with the untimed release/verify hook outside the enabled window. Counter
   values project to per-iteration doubles, unrounded.
5. **Serial execution** — benchmarks never run in the test thread pool.
   Registered cases are scheduled grouped by their streaming key (the
   `--group-by` group, else the source test's qualified name).
6. **Assert-enabled builds warn** — `--bench` on a debug/assert build prints a
   stderr warning; real numbers require an optimized unittest build type.

Thread coverage is inherit-shaped: counters follow threads spawned after the
source opens; pre-existing threads and short-lived children are blind spots
(see [open-issues.md § O3](./open-issues.md)).

For `@workload` _(target — M4)_: the driver phase model is `setup →
regime-prep (M6) → snapshot-before all sources → body × reps →
snapshot-after → residency-verify (M6) → assemble deltas`. The wall-clock
decomposition reports `onCpuUser`/`onCpuKernel` (rusage), `offCpuRunqueue`
(schedstat), `offCpuDisk` (PSI, M5), and a clamped `offCpuOther` residual —
only runqueue and disk are true per-cause durations; lock/sleep time is never
fabricated.

## 5. The metric catalog

### 5.1 Types

Everything downstream renders through two types (`metrics.d`):

```d
enum MetricClass  { quantitative, diagnostic }
enum MetricFormat { ratio, count, percent }

struct MetricCell        // one rendered value
{
    string name;         // stable id: "ipc", "instr", "B/s", "syscalls:read"
    string header;       // column label
    double value = double.nan;  // nan renders as an em dash
    MetricFormat format;
    MetricClass cls;
}

struct MetricDescriptor  // one catalog entry
{
    string name;
    string header;
    MetricFormat format;
    MetricClass cls;
    string source;       // "client" | "perf" | "tier0" | "syscall" | …
    bool available;      // producible on this run
    bool isDefault;      // shown without a --metrics filter
}
```

### 5.2 Contract

- Each source contributes a projection pair — `XCells(in XStats)` for row
  cells and `XFamily(bool available)` for descriptors. **Adding a source is
  one `Nullable!XStats` field on `BenchStats` plus one line in each of
  `open`/`close`/`countInto`, plus the cells/family pair.** Table rendering,
  `--metrics` filtering, `--list-metrics`, and `--bench-json` then work
  unchanged.
- `--metrics=LIST` selects columns by exact name, comma list, `*`-glob,
  `all`, or `?`/`help` (print the catalog). Selection **transitively opens
  the sources it needs** (naming a perf metric opens the perf pass; naming
  `syscalls`/`syscalls:<name>` opens the tracepoint pass). A selector that
  matches nothing warns on stderr — selectors are never silently dropped.
- Client metric names that shadow built-ins get a `user.` prefix.
- With no filter, the default column set is stable across releases within a
  schema version (regression guard: `--perf` output is byte-compatible).

### 5.3 Units seam

`Unit.symbol` is a **label, not semantics** (the open-basis "mint-by-name"
identity); `Metric.Mode` is a two-valued stand-in for a time-exponent
dimension (`rate` = `unit·s⁻¹`). All unit/rate/format semantics live behind
one seam — the `scaled`/`fixed` formatters — so the future
`sparkles.quantities` binding is a localized swap (see
[open-issues.md § O6](./open-issues.md)).

## 6. The backend contract

### 6.1 The source shape (shipped)

Every acquisition source implements, on all platforms:

```
tryOpen(...)      // probe handshake; may calibrate (arity varies per tier)
available()       // bool: producible on this run
status()          // human reason when unavailable
capabilities()    // CapabilityReport: flags + reasoned absences
count(...)        // bracket a counting pass; fill the row's XStats
close()
```

with a `version (linux)` (or per-OS) real body and an identical-surface stub
elsewhere. Two source shapes exist: _bracketed_ (ioctl ENABLE → body →
DISABLE per iteration: perf, syscalls) and _snapshot/delta_ (pairs around the
pass: tier-0; window-friendly for M4+).

### 6.2 The capability model

Backends advertise what this host, this run, can measure (`capability.d`):

```d
enum Capability : uint
{
    none, counting, countingRaw, countingScaled, selfMonitoring,
    ipSampling, preciseMemory, symbolization, eventTracing,
    numaAttribution, eventNaming,   // one flag per survey concern
}

struct CapabilityAbsence { Capability capability; string reason; }

struct CapabilityReport
{
    Capability available;                // OR of the present flags
    const(CapabilityAbsence)[] absences; // reasoned, declaration order
}
```

`capabilities()` is a **const observer** read after the open handshake — a
deliberate deviation from the research sketch's "`tryOpen` returns a report":
the real `tryOpen`s have divergent arities and every call site depends on
them returning the group, so construction stays per-tier and the report is a
separate query. Absences are an ordered array of pairs, not a reason map —
deterministic render order, `nothrow`-friendly, and `static immutable`-
bindable for the strict stub attribute blocks.

The DbI `isCounterBackend` trait names the required instance surface
(`available`/`status`/`capabilities`/`close`/`count`); optional primitives
(`hasSnapshot`, `hasNamedColumns`; later: precise sampling, page
classification, name resolution) unlock optional capabilities by presence.
Each tier module compile-validates the trait against whichever body — real
or stub — the platform built.

A capability that hardware supports but no backend delivers yet stays
**absent**, with the host finding carried in the reason (e.g. `preciseMemory
— hardware present (ibs_op PMU) — data-source sampling lands in B5`).
Concerns no backend owns yet report harness-level, so the vocabulary is
complete from the start.

`--list-metrics` renders a per-backend capability block; the bench header
prints one line per absent-but-requested capability, re-derived from the
same reports. Workload-track sources (PSI, cgroup, cache regime) adopt the
same report when they land — one absence vocabulary program-wide.

### 6.3 Degradation rules (normative)

- **Absence is reported, never fatal.** An unavailable source yields omitted
  columns plus a reasoned capability entry (§6.2).
- **"Not counted" is not zero.** A counter group with `time_running == 0`
  (never scheduled) reports its cells unavailable (`nan` → em dash) — never
  `0`, never a scaled estimate.
- **Exact by intent; every estimate is labeled.** The default counting group
  is calibrated at open and shrunk (the LLC pair drops first) to avoid
  multiplexing; opt-in `--perf-scaled` keeps the full multiplexing group
  instead. In **either** mode the label keys off the truth of each pass:
  every cell whose pass was scaled (`running/enabled < 1` — including
  ambient PMU contention the open-time calibration could not foresee)
  renders with a `≈` prefix and is named in `--bench-json`'s per-row
  `estimatedMetrics`. A multiplexed pass with under a millisecond of PMU
  time renders unavailable, never as a number (a 0.58 ms slice measured a
  5.7× scale error).
- **Group-refused degrades at open.** A platform that refuses an unplaceable
  group outright (RISC-V SBI) fails `perf_event_open` and reports the
  standard open-failure absence — it is never multiplex-scaled.
- **Privilege gates are independent axes.** `perf_event_paranoid`, tracefs
  file permissions, and per-field gates (e.g. physical addresses) are probed
  separately; each degrades on its own.

## 7. CLI contract

The authoritative option list lives in the
[CLI reference](../../libs/test-runner/reference/cli.md); this section pins
the contracts.

- **Mode exclusivity** — `--bench`, `--ctfe-trace`, and `--better-c`/`--wasm`
  are mutually exclusive (hard error); `--better-c` with `--wasm` is one
  extraction family; `--list`/`--list-metrics` are queries that win over any
  mode.
- **Readable failures** — malformed options, unknown flags, and stray
  positionals produce one-line errors, never stack traces.
- **Warn, don't drop** — unknown `--metrics`, `--sort-by`, and `--syscalls`
  selectors warn on stderr; the run proceeds with the remainder.
- **Selector equivalences** — `sc:<name>` ≡ `syscalls:<name>` everywhere a
  metric name is accepted.
- **Sorting** — `--sort-by=KEY` orders ascending within each group; error
  rows always sort last under every order; default is `median/iter`.
- **Grouping** — `--group-by=KEYS` streams one table per label-key group;
  `=all` uses every label key; `=list` prints the keys and exits (reporting
  registration failures with a non-zero exit).
- **Exit status** — `0` iff everything passed or was skipped (`skipTest` or a
  toolchain-missing mode); non-zero otherwise. A `--bench-json` write failure
  fails the run.
- **Hardware-event selectors** — `--metrics` accepts raw selectors
  (`raw:r<hex>`, the `perf` tool's rNNNN notation) and, when event naming is
  available (soft libpfm4), symbolic names (`pfm:<name>` with umask and
  `:u`/`:k` modifier grammar); both become diagnostic columns riding their
  own counter group, so the default group's exactness is never perturbed. A
  failed name resolution warns and drops the column. `--perf-scaled` opts
  into labeled multiplex estimates (§6.3).
- _(target — B6)_ `--bench-profile` enables the sampling pass.

## 8. Output surfaces

### 8.1 Tables

- Timing and metric columns align on the **decimal point**; consecutive
  streamed tables share their column geometry (floors only widen during a
  run). Grouped tables carry `benchmark: <group>` in the top border over an
  `implementation` column.
- Unavailable cells render as an em dash. Multiplex-scaled estimates carry a
  `≈` prefix (§6.3). Error rows carry the first line of the error in-table
  (full traces print to the console) and sort last.
- Diagnostic-class output beyond columns (profiles, histograms — targets B5,
  B6, M9) renders as labeled blocks **below** the numeric table, never as
  throughput-lookalike columns.

### 8.2 Live displays

One suppression policy for all three live displays (runtime progress line,
bench table ticker on stdout, bench stderr spinner): suppressed when piped,
under `--no-colours`, `$NO_COLOR`, or `TERM=dumb`. Repaints are bracketed in
DEC-2026 synchronized output and happen only at case boundaries — no painter
thread. Piped output is byte-stable and prints each table once.

### 8.3 The `--bench-json` document

One deterministic JSON document, `{schema: 2, meta, columns, rows}`:

- `meta` — `{date, hostname, os, arch, compiler, cpu, minSampleTimeMs,
sampleCount}`: host/toolchain provenance plus the run's effective knobs
  (baselines are self-describing).
- `columns` — the available catalog descriptors `{name, header, format,
class, source}`; `metrics` keys in rows match `--list-metrics` names.
- `rows` — measurement order, unaffected by `--sort-by`/`--group-by` (group
  dimensions travel in each row's sorted `labels`): `{name, labels,
iterations, samples, medianNs, deviationNs, minNs, maxNs, metrics, error}`.
  Error rows keep `labels` and `error` with `null` timing fields; `nan`
  cells are `null`. A row whose counters were multiplex-scaled additionally
  carries `estimatedMetrics`, the array of `metrics` keys holding estimates
  (absent = every metric exact — the schema-2 addition).
- Number policy: `nan`/infinity → `null`; integral values below 2⁵³ print as
  integers; others to 6 significant digits. Output is byte-deterministic for
  committing.

Schema evolution (`@workload` windows) is tracked in
[open-issues.md](./open-issues.md) (O7).

## 9. Portability and privilege

Per-OS floors, with shipped-vs-target markers. The full evidence base is the
research [capability matrix](../../research/cpu-pmu/comparison.md).

| Platform              | Floor (unprivileged)                                                      | Beyond the floor                                                                                                                      | Status                                           |
| --------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| Linux x86_64          | tier-0 (`getrusage` + `/proc/self/io`); perf counting at `paranoid ≤ 2`\* | tracepoints (tracefs, usually root); precise memory (B5); sampling (B6)                                                               | shipped / targets                                |
| macOS (Apple Silicon) | `proc_pid_rusage` → true instructions/cycles/IPC, process-scope           | kpc: root-or-blessed-pid + kernel allowlist, single-owner `EBUSY`; sampling via xctrace only; **no DTrace cpc provider**              | target — B3                                      |
| Windows               | `CycleTime` via thread profiling (driver-free)                            | ETW PMC counting (admin + `SeSystemProfilePrivilege`, 3–4 PMC hard budget, no multiplex scaling); public precise sampling: **absent** | target — B4 (blocked: no hardware bed)           |
| ARM-Linux             | generic events port as-is (PMUv3)                                         | big.LITTLE: events must open on the pinned core's PMU (wrong cluster counts silent zero); SPE/BRBE gated                              | target — M11 (source-verified only)              |
| RISC-V                | counting always (SBI-mediated)                                            | sampling iff Sscofpmf; `exclude_*` iff Sscofpmf; precise/data-source: **permanently absent**; branch records: no kernel consumer      | target — M11 (capability subset by construction) |

\* All hardware verification to date ran at `perf_event_paranoid = −1`;
behavior at stricter levels is literature-derived until probed
([open-issues.md § O1](./open-issues.md)).

Normative portability rules:

- Never assume 4 KiB pages / 64 B cache lines (Apple Silicon: 16 KiB /
  128 B).
- Topology and storage provenance are re-probed per boot (BIOS NUMA modes
  re-scope nodes and uncore counters).
- The event-name vocabulary is **harness-owned**: no naming layer spans
  operating systems (libpfm4/LIKWID are Linux-only; kpep and ETW
  profile-sources are OS-local). Naming _data_ (kernel pmu-events, kpep
  plists, vendor JSON) is harvested offline, never a runtime dependency.
- C libraries are soft dependencies at most (libpfm4 for naming, libdw for
  symbolization): absence degrades to an advertised missing capability.
  `libnuma` is never linked — page→node classification uses the raw
  `get_mempolicy`/`move_pages` syscalls.
- Environment-dependent tests use `skipTest(reason)`, so a degraded host
  skips visibly and never fails.
