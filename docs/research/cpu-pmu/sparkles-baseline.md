# The sparkles counter layer: the baseline

Today's CPU-PMU acquisition layer in the sparkles benchmarking harness —
`sparkles:test-runner --bench` plus the [`wired` runtime bench][wired-bench] —
described as **observed behavior**, with its current limits. This page is the
_system under audit_: the [comparison][comparison] page's delta table maps each
capability the survey found onto where this layer stands, and the
[backend proposal][proposal] is the plan that closes the gaps.

**Last reviewed:** July 11, 2026

> [!IMPORTANT]
> Per the survey's ground rules, this page records what the code _does_, not
> what it was assumed to do — the sparkles source is **not** a source of truth
> for any other page in this tree. Where the survey's findings and this layer's
> behavior diverge, the divergence is recorded here and in the
> [delta table][comparison-delta], never silently reconciled.

| Field           | Value                                                                                                                                                            |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Modules         | [`perf.d`][src-perf] · [`perf_group.d`][src-group] · [`tier0.d`][src-tier0] · [`syscalls.d`][src-syscalls] · [`metrics.d`][src-metrics] · [`bench.d`][src-bench] |
| Location        | `libs/test-runner-impl/src/sparkles/test_runner/`                                                                                                                |
| Acquisition API | `perf_event_open(2)` via druntime `core.sys.linux.perf_event` (pure D, no C shim)                                                                                |
| Modes           | [Counting][c-counting] only — no sampling of any kind                                                                                                            |
| OS coverage     | Linux; identical-surface stubs (`available == false`) everywhere else                                                                                            |
| User docs       | [`--bench` how-to][bench-docs]                                                                                                                                   |
| Consumer        | [`libs/wired/bench/runtime`][wired-bench] (11 JSON engines × 5 ops × 4 datasets)                                                                                 |

---

## Overview

The layer is a set of **counting tiers** feeding one **metric-catalog seam**.
Each tier is an independent acquisition source that opens once per bench run,
brackets the timed body of every benchmark case, and projects per-iteration
averages; the catalog ([`metrics.d`][src-metrics]) renders whatever tiers are
present into table columns and JSON fields, tagging every column
`quantitative` (near-zero perturbation, safe to headline) or `diagnostic`
(perturbs; explains a result). The tiers:

- **Hardware counters** ([`perf.d`][src-perf]) — one process-wide
  [event group][c-group] of 7 events; `diagnostic`.
- **Tier 0** ([`tier0.d`][src-tier0]) — `getrusage(2)` + `/proc/self/io`;
  always available, no privilege; `quantitative`.
- **Syscall tracepoints** ([`syscalls.d`][src-syscalls]) — an in-process
  `strace -c` built from tracepoint events; `quantitative`.
- **Client metrics** — user-supplied `Metric` values (e.g. the wired bench's
  bytes-per-second rate), computed against the timed median.

Two properties define the design. First, **counting is separated from
timing**: the timing pass (median ns/iter over 32 samples) runs with no
counters enabled, then a second pass re-runs the body under counters — so
`ioctl`/`read` bracketing never pollutes the reported ns/iter. Second, **every
tier degrades to absence**: a failed `perf_event_open` (raised
[`perf_event_paranoid`][c-privilege], seccomp, no PMU, non-Linux) or unreadable
tracefs yields `available == false` and _omitted columns_, never an error and
never silently-wrong numbers.

---

## How the layer works today

### The measurement protocol ([`bench.d`][src-bench])

The timing protocol is the Rust-libtest `Bencher` shape: double the per-sample
iteration count until one sample takes ≥ `--bench-min-time` (default 5 ms),
then take 32 samples and report median / MAD / min / max ns per iteration,
timed with raw `MonoTime` ticks (`bench.d:294-331`). `blackBox` defeats
constant-folding via empty inline asm under LDC (`bench.d:48-66`).

Counters hook in _after_ timing. `BenchStats` carries one `Nullable!XStats`
slot per tier (`bench.d:128-144`), and a `CounterGroups` bundle owns the three
tiers' lifecycles (`bench.d:377-419`). For each case, `measureCase` calls
`counters.countInto(row, runTimed, between, iterations, config)`, which runs
each _available_ tier's counting pass capped at `perfMaxIters = 100_000`
iterations (`bench.d:434-440`). The module documentation states the extension
contract: adding a source is _one field plus one line in each of
`open`/`close`/`countInto`_ — plus a cells/family pair in the
[catalog](#the-metric-catalog-seam).

### Hardware counters ([`perf.d`][src-perf])

One process-wide [group][c-group] opened at bench-mode start (`pid: 0`,
`cpu: -1` — this process, any CPU), leader-first (`perf.d:74-88, 199-201`):

| #   | Event                               | Type                |
| --- | ----------------------------------- | ------------------- |
| 0   | `PERF_COUNT_HW_CPU_CYCLES`          | hardware (leader)   |
| 1   | `PERF_COUNT_HW_INSTRUCTIONS`        | hardware            |
| 2   | `PERF_COUNT_HW_BRANCH_INSTRUCTIONS` | hardware            |
| 3   | `PERF_COUNT_HW_BRANCH_MISSES`       | hardware            |
| 4   | `PERF_COUNT_HW_CACHE_REFERENCES`    | hardware (LLC pair) |
| 5   | `PERF_COUNT_HW_CACHE_MISSES`        | hardware (LLC pair) |
| 6   | `PERF_COUNT_SW_PAGE_FAULTS`         | software            |

The leader carries `read_format = PERF_FORMAT_GROUP |
PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING`
(`perf.d:194-197`), so one blocking `read(2)` returns
`{nr, time_enabled, time_running, values…}`. There is **no `rdpmc`/mmap-page
[self-monitoring][c-rdpmc] path** — every read is a syscall.

Availability is a **calibration handshake**, not a static probe
(`perf.d:129-154`): `tryOpen` opens the full group, spins ~2 ms, and checks the
running/enabled ratio. Below 0.98 — i.e. the group was
[multiplexed][c-multiplex] — it _reopens without the LLC pair_
(`cacheDropped`), because a rotation-scaled estimate is an estimate, not a
count. If even the reduced group gets zero PMU time it gives up
(`available == false`). A permission fallback tries kernel+user first, then
user-only (`exclude_kernel = 1`, reported as `userOnly`) (`perf.d:158-168`).
On this survey's test box the LLC drop fires in practice: the NMI watchdog
pins one of Zen 4's six PMCs, so the full 7-event group cannot fit
([bench-baseline][wired-baseline] records it).

> [!NOTE]
> The dropped-LLC-pair heuristic is the layer's answer to
> [multiplex scaling][c-multiplex]: rather than report `enabled/running`-scaled
> estimates (the kernel-documented approach the survey's
> [counting probe][ex-counting] demonstrates), it shrinks the group until the
> counts are exact. The trade-off — fewer columns, but never estimated ones —
> is deliberate, and the [proposal][proposal] revisits it.

### Shared group mechanics ([`perf_group.d`][src-group])

Both `perf_event` tiers share one counting bracket (`perf_group.d:71-90`):
`RESET` once per pass, then per iteration `ENABLE → timed body → DISABLE`,
with the untimed `between` callback (result release, verification) outside the
enabled window. Reads scale by the pass's own `time_enabled`/`time_running`
deltas — taken against a per-pass baseline because `PERF_EVENT_IOC_RESET`
zeroes counter values but **not** the cumulative time fields
(`perf_group.d:61-121`). Values project to per-iteration doubles unrounded;
a short read or an enabled-but-never-scheduled group yields `nan` fields /
`scale = 0` rather than fabricated zeros.

### Tier 0 ([`tier0.d`][src-tier0])

The no-privilege tier: `getrusage(RUSAGE_SELF)` (minor/major faults,
voluntary/involuntary context switches) plus `/proc/self/io` (`syscr`, `syscw`,
`rchar`, `wchar`, `read_bytes`, `write_bytes`), read with raw
`open`/`read`/`close` because `std.file` reports `/proc` files as size 0
(`tier0.d:357-369`). Its instrumentation self-cost is measured at open (median
of 9 empty brackets) and subtracted clamped-at-zero, so a no-I/O body reads ≈0
(`tier0.d:218-248, 335-341`). Fields degrade individually — a kernel without
`CONFIG_TASK_IO_ACCOUNTING` yields `nan` for `read_bytes`/`write_bytes` while
`syscr`/`rchar` still count (`tier0.d:122-154`).

### Syscall tracepoints ([`syscalls.d`][src-syscalls])

An [event-space][c-eventspace] tier: a `perf_event` group with
`raw_syscalls:sys_enter` as leader (total syscall count) plus up to 62 named
`syscalls:sys_enter_<name>` siblings, tracepoint ids read from tracefs
(`syscalls.d:77-98, 125-158`). `inherit = 1` follows threads spawned after the
open — worker pools created in untimed setup aggregate in; threads that existed
_before_ the open do not (`syscalls.d:168`). The tier needs readable tracefs
`id` files — root-only (`0700`) on hardened hosts, including the survey's test
box — and `perf_event_paranoid ≤ 1`; otherwise the columns are omitted and
`status()` says why (`syscalls.d:116-119`).

### The metric catalog seam

Everything downstream renders through two small types (`metrics.d:29-63`):

```d
enum MetricClass { quantitative, diagnostic }
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
    string source;       // "client" | "perf" | "tier0" | "syscall"
    bool available;      // producible on this run
    bool isDefault;      // shown without a --metrics filter
}
```

Each tier contributes a projection pair — `XCells(in XStats)` producing row
cells and `XFamily(bool available)` producing descriptors — concatenated by
`rowCells`/`catalog` (`metrics.d:250-260, 514-539`). `--metrics` glob-selects
columns (`visibleMetrics`, `metrics.d:679-692`) and _transitively opens the
tiers it needs_ (`selectsSource`, `metrics.d:645-660`) — asking for `ipc`
opens the perf group without `--perf`. `--list-metrics` renders the catalog
with class and source. The `--bench-json` emitter serializes the same
descriptors as `columns` and the same cells as per-row `metrics`, `nan` →
`null` (`bench_json.d`).

This seam is the composition point the [backend proposal][proposal] targets:
table rendering, filtering, listing, and JSON are all source-agnostic over
`MetricCell`/`MetricDescriptor`.

### The wired bench consumer

The [`wired` runtime bench][wired-bench] measures 11 JSON engines × 5
operations × 4 datasets through ordinary `@benchmark` cases and **reuses this
layer wholesale** — its module header states hardware counters come from the
runner's `--perf`; there is no private perf backend. Each case registers one
client `B/s` metric; correctness verification (fingerprints, `TwitterStats`)
rides the untimed release hook. [`bench-baseline.md`][wired-baseline] then
derives per-byte figures (IPC, cycles/B, instructions/B) from the same
`PerfStats` cells — the numbers behind the "wired decode is
instruction-budget-bound, not IPC-bound" conclusion.

---

## The seven concerns, as covered today

The survey's [analysis spine][index-spine], applied to this layer. Absences
are the point — they are the audit's raw material.

| #   | Concern                            | Today                                                                                                                                                     |
| --- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | [Scalar counting][c-counting]      | ✅ 7-event fixed group; calibration LLC-drop; user-only fallback; **no [rdpmc][c-rdpmc]**, syscall `read(2)` per pass                                     |
| 2   | [Overflow/IP sampling][c-sampling] | ❌ Absent — the harness reports aggregates only; no ring buffer, no samples                                                                               |
| 3   | [Precise / data-source][c-datasrc] | ❌ Absent — no IBS/PEBS/SPE use, no data addresses, no latency distribution                                                                               |
| 4   | [Symbolization][c-symbolization]   | ❌ Absent — no address-space model, no debug-info decode (nothing to symbolize without samples)                                                           |
| 5   | [Event-space][c-eventspace]        | ⚠️ Partial — syscall tracepoint _counting_ (62 named max); root-gated tracefs; no other tracepoints, no gating/windowing                                  |
| 6   | [NUMA & topology][c-numa]          | ❌ Absent — no topology awareness, no node pinning, no page→node classification                                                                           |
| 7   | [Event naming][c-naming]           | ⚠️ Fixed generic names — the 7 `PERF_COUNT_*` events are hardcoded; `--metrics` selects _columns_, not _events_; no per-µarch tables, no raw-event access |

Cross-OS coverage is a stub: every tier compiles to an identical-surface
`available == false` shell off Linux. The survey found real per-OS floors the
layer does not reach — macOS offers unprivileged per-process
instructions/cycles via `proc_pid_rusage` (a natural tier-0 analog,
[macos.md][macos] `[hw-verified: aarch64-darwin]`), and Windows offers
`CycleTime` via thread profiling plus admin-gated ETW counting
([windows.md][windows]).

---

## Gap analysis: what the audit starts from

1. **The event set is closed.** Seven generic events, hardcoded. No
   [naming layer][c-naming], no raw `type:config` escape hatch, no
   per-microarchitecture tables — on the survey's Zen 4 box, nothing beyond
   the generic seven is reachable, and the LLC pair is dropped besides. The
   survey's [libpfm4 probe][ex-pfm4] shows what a name→encoding layer buys
   (and its own hazards: stale auto-detect on new silicon).
2. **Counting is syscall-priced.** A `read(2)` + two `ioctl(2)` per iteration
   bracket. The [rdpmc/mmap-page path][c-rdpmc] the kernel exposes for exactly
   this shape (self-monitoring a bracketed region) is unused — relevant per
   the [counting probe][ex-counting] once per-iteration bracketing of very
   short bodies is on the table.
3. **No mode beyond counting.** Concerns 2-4 are wholesale absent. The layer
   can say a regression _happened_ (IPC fell, cache misses rose) but never
   _where_ — no flat profile, no data-address attribution, no unwound stacks.
4. **Multiplexing is avoided, not modeled.** The calibration drop keeps counts
   exact but silently narrows coverage; the `enabled/running` scaling the
   kernel documents (and the [probe][ex-counting] validates to ~1% on a
   10-on-6 oversubscription) is never used, even where estimates would be
   acceptable and labeled.
5. **Thread coverage is inherit-shaped.** `pid:0, cpu:-1` + `inherit` on the
   tracepoint group covers threads spawned after open; pre-existing threads
   and short-lived children are blind spots the harness does not report.
6. **Off-Linux is absence, not a smaller backend.** The stubs are honest but
   empty; the per-OS floors ([macOS rusage tier][macos], [Windows
   HCP/ETW][windows]) are unimplemented, so cross-platform runs lose _all_
   counters instead of degrading to the local floor.
7. **Availability reporting is coarse.** `status()` strings say a tier is
   off; they do not enumerate _which capability_ (of the survey's seven
   concerns) is missing and why — the "capability unavailable, not silently
   degraded" contract the [proposal][proposal] formalizes.

---

## Sources

- Observed sources (this repo): [`perf.d`][src-perf], [`perf_group.d`][src-group],
  [`tier0.d`][src-tier0], [`syscalls.d`][src-syscalls], [`metrics.d`][src-metrics],
  [`bench.d`][src-bench], [`bench_json.d`][src-json]; user docs
  [`benchmark.md`][bench-docs]; consumer [`libs/wired/bench/runtime`][wired-bench]
  and [`bench-baseline.md`][wired-baseline]. Line references are to the tree at
  the survey date (July 2026).
- The survey pages this baseline is audited against: [comparison][comparison],
  [linux-perf-events][linux], [precise-sampling][precise],
  [event-naming][naming], [macos][macos], [windows][windows].

<!-- References -->

[src-perf]: ../../../libs/test-runner-impl/src/sparkles/test_runner/perf.d
[src-group]: ../../../libs/test-runner-impl/src/sparkles/test_runner/perf_group.d
[src-tier0]: ../../../libs/test-runner-impl/src/sparkles/test_runner/tier0.d
[src-syscalls]: ../../../libs/test-runner-impl/src/sparkles/test_runner/syscalls.d
[src-metrics]: ../../../libs/test-runner-impl/src/sparkles/test_runner/metrics.d
[src-bench]: ../../../libs/test-runner-impl/src/sparkles/test_runner/bench.d
[src-json]: ../../../libs/test-runner-impl/src/sparkles/test_runner/bench_json.d
[bench-docs]: ../../libs/test-runner/how-to/benchmark.md
[wired-bench]: ../../../libs/wired/bench/runtime/
[wired-baseline]: ../../specs/wired/bench-baseline.md
[comparison]: ./comparison.md
[comparison-delta]: ./comparison.md#the-delta-table-the-survey-vs-the-sparkles-baseline
[proposal]: ./backend-proposal.md
[index-spine]: ./#the-seven-concerns
[linux]: ./linux-perf-events.md
[precise]: ./precise-sampling.md
[naming]: ./event-naming.md
[macos]: ./macos.md
[windows]: ./windows.md
[ex-counting]: ./examples/counting-group.d
[ex-pfm4]: ./examples/pfm4-name-roundtrip.d
[c-counting]: ./concepts.md#counting
[c-sampling]: ./concepts.md#overflow-sampling
[c-datasrc]: ./concepts.md#data-source-attribution
[c-symbolization]: ./concepts.md#symbolization
[c-eventspace]: ./concepts.md#event-space-and-tracepoints
[c-numa]: ./concepts.md#numa-topology-and-page-node-oracles
[c-naming]: ./concepts.md#event-naming-and-encoding
[c-group]: ./concepts.md#event-group
[c-multiplex]: ./concepts.md#multiplexing-and-scaling
[c-rdpmc]: ./concepts.md#self-monitoring-and-user-space-counter-reads
[c-privilege]: ./concepts.md#privilege-gating
