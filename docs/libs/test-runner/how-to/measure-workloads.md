# Measure workloads with `@workload`

`@benchmark` answers "how long does one iteration take?" by running a body
many times. `@workload` answers a different question — "where did this run's
time and events go?" — by running the body **once** (or a few reps) and
reporting everything as **deltas across that one window**: counter totals
plus a wall-clock decomposition. Use it for bodies that are long, stateful,
I/O-bound, or too expensive to iterate: an ingest pass, a compile, a
large-file parse.

```d
import sparkles.test_runner.attributes : workload;

@("ingest.fullFile")
@workload @system
unittest
{
    processFile("testdata/big.json"); // the whole body is the window
}
```

```bash
dub test :yourpkg -- --bench --perf
```

```console
╭──╼ workloads ╾───┬──────┬────────┬─────────┬─────────┬────────┬─────────┬──────────┬─────────┬─────────┬──────┬────────╮
│ workload         │ reps │   wall │ cpu usr │ cpu krn │   runq │   other │ io-stall │   instr │  cycles │  ipc │ pg-flt │
┝━━━━━━━━━━━━━━━━━━┿━━━━━━┿━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━┿━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━┿━━━━━━┿━━━━━━━━┥
│ ingest.fullFile  │    1 │ 30.1ms │  29.8ms │ 126.0µs │ 24.5µs │ 171.0µs │    1.2ms │ 572.98M │ 142.75M │ 4.01 │      1 │
╰──────────────────┴──────┴────────┴─────────┴─────────┴────────┴─────────┴──────────┴─────────┴─────────┴──────┴────────╯
```

(Illustrative output. Workloads measure after the benchmark groups, in the
same `--bench` run, sharing the same source **selection**: `--perf`,
`--syscalls`, `--metrics=raw:…`/`pfm:…` open the same sources for windows —
reported as window **totals**, not per-iteration averages. The table shows a
fixed summary column set per open source; every collected total lands in
`--bench-json`, so a `--metrics` selector that names a column outside the
summary set is still measured — look in the JSON.)

One apparatus cost to know about: the window edges are read **nested**
(perf innermost), so an outer source's window contains the inner sources'
edge reads. The floor is small and deterministic — with `--perf` open, a
zero-I/O workload reports about 2 `syscr` / 130 `rchar` in its tier-0
totals (the perf group's two edge reads), and a `--syscalls` total carries
roughly a dozen apparatus syscalls depending on which sources are open.
Negligible against a real workload's counts at window granularity, but it
is a floor, not zero — remember it when diffing near-zero baselines.

## The wall-clock decomposition

Every window's wall time is split into:

| Column    | Source                        | Meaning                                    |
| --------- | ----------------------------- | ------------------------------------------ |
| `cpu usr` | `getrusage` user time         | on-CPU, user space                         |
| `cpu krn` | `getrusage` system time       | on-CPU, kernel                             |
| `runq`    | `/proc/thread-self/schedstat` | runnable but waiting for a CPU             |
| `other`   | residual (clamped at 0)       | everything else off-CPU: locks, sleeps, IO |

The decomposition is deliberately honest: only runqueue wait is a true
per-cause duration today. Everything else — locks, sleeps, disk — lands in
`other`; the runner never fabricates a cause. A component the host cannot
attribute (schedstat unreadable, non-Linux) renders an em dash, its time
stays in `other`, and a note says so. Disk attribution arrives with the
cgroup milestone (M8), which scopes the pressure files to the workload.

## The `io-stall` column (PSI)

On kernels with pressure-stall information (`CONFIG_PSI`), each window also
reports the **system-wide** io stall integral that accumulated concurrently
with it — the window delta of `/proc/pressure/io`'s monotonic `some`
`total`. It renders as an `io-stall` column placed _after_ `other`: the
placement is the claim — this is **context, not a part of the
decomposition's sum**. The whole system's stalls are in it, including other
processes': a pure CPU spin on a busy box can show tens of milliseconds of
io-stall it never waited on. Use it to tell a noisy-neighbor residual from
your own blocking, not to assign blame. The full delta set (io/memory/cpu,
`some` and `full`) lands in `--bench-json`'s per-window
`psi: { scope: "system", … }` object; a PSI-less kernel omits the column
and the object, and `--list-metrics` reports the reasoned absence under
the `psi` backend.

Two scoping facts worth knowing:

- On Linux the decomposition covers **the driving thread**
  (`RUSAGE_THREAD` + thread schedstat) — the only scoping under which
  `wall = onCpu + runq + other` adds up. CPU burned by other threads the
  body spawned is disclosed in the `note` column, not silently blended.
- rusage's user/kernel split is tick-sampled: on sub-millisecond windows it
  smears by up to a scheduler tick. Make windows **long** — tens of
  milliseconds and up — so the split is signal, not quantization.

## Declared page-cache regimes: `workloadFiles`

An I/O workload's numbers depend on what the page cache already holds. A
`@workload` can declare — and the runner will **verify**, never assume —
the regime its files run under:

```d
import sparkles.test_runner.attributes : CacheRegime, workload;
import sparkles.test_runner.workload : workloadFiles, workloadWindow;

@("ingest.coldVsWarm")
@workload @system
unittest
{
    workloadFiles(CacheRegime.cold, "testdata/big.json"); // evict, verify
    workloadWindow("cold", () { processFile("testdata/big.json"); });

    workloadFiles(CacheRegime.warm, "testdata/big.json"); // preload, verify
    workloadWindow("warm", () { processFile("testdata/big.json"); });
}
```

`cold` is `fdatasync` + `posix_fadvise(DONTNEED)` per file; `warm` is an
explicit read-through preload; both are verified with `mmap` + `mincore`
residency and stamped on the NEXT measured window — consume-once: a second
window without its own `workloadFiles` call renders `—` rather than a
stale "cold" claim for a run the first window already warmed — the table
gains a `regime` column (`cold`, or `cold→steady` when the regime could
not be established, with the reason in the note), and `--bench-json`
windows carry the exact fractions in a `regime` object. The marker form
`@workload(regime: CacheRegime.cold)` sets the default for calls that
don't override it.

What the verification protects you from, honestly: on **tmpfs** the pages
ARE the file — cold is impossible and the stamp says so; on **ZFS**,
`mincore` sees neither ARC warmth nor ARC survival, so residency there is
disclosure, not evidence (noted, thresholds suppressed); a file another
process has mapped won't evict (downgraded, with the resident percentage);
and a `workloadFiles` call inside an open window or on a repetition after
the first is refused with a note — prep mid-measurement would sabotage the
window in flight. In a windowless body, each call restarts the whole-body
window (prep is setup) — a second call therefore discards the work before
it, disclosed in the note; use explicit windows for multi-regime bodies.
Outside `--bench` the call does nothing at all: no eviction, no probes.

## Measuring part of the body, and reps

`workloadWindow` scopes the window to a closure — everything outside it is
setup/teardown — and `@workload(reps: N)` runs the window content `N` times
inside the one window (use it to grow a too-short window):

```d
import sparkles.test_runner.attributes : workload;
import sparkles.test_runner.workload : workloadWindow;

@("ingest.phases")
@workload(reps: 4) @system
unittest
{
    auto doc = loadTestDocument();          // setup — not measured

    workloadWindow("parse", () {            // one row: 4 parses, one window
        parse(doc);
    });
    workloadWindow("index", () {            // a second row
        buildIndex(doc);
    });
}
```

Each `workloadWindow` call is one row; unnamed windows take the test's name
(then `#2`, `#3`). Outside `--bench` — a normal run, a foreign runner — the
closure runs exactly once, inertly.

The whole measurement is a **single pass**: sources are read cumulatively at
the window edges (no per-iteration counter brackets), and the body is never
re-run for counting. Expensive and non-idempotent workloads are safe by
construction.

Failure semantics match the bench tables: `skipTest` inside a window yields
a yellow row and the body continues; any other throw records a red error row
(earlier windows are kept) and fails the test.

## JSON

With `--bench-json=FILE`, workload results land in a `windows` sibling array
of the same document — the decomposition fields (`null` = unattributable)
plus one nested totals object per attached source:

```json
"windows": [
  { "name": "ingest.phases/parse", "reps": 4,
    "wallNs": 41235678, "scope": "thread",
    "onCpuUserNs": 31000000, "onCpuKernelNs": 4000000,
    "offCpuRunqueueNs": 1200000, "offCpuDiskNs": null, "offCpuOtherNs": 5035678,
    "perf": { "instructions": 2410000000, "cycles": 3100000000, "...": 0,
              "scale": 1, "userOnly": false },
    "error": "" }
]
```

Window values keep their own field names — they are totals, and reusing the
per-iteration `metrics` catalog keys would quietly change those keys'
meaning.

## When to reach for which model

| You want                             | Use                            |
| ------------------------------------ | ------------------------------ |
| ns/iter medians, regression gating   | `@benchmark`                   |
| a matrix of variants                 | `@benchmark` + `benchCase`     |
| where one long run's time went       | `@workload`                    |
| phase-by-phase accounting of one run | `@workload` + `workloadWindow` |

The models are exclusive per test — `@benchmark @workload` on one body is a
discovery-time error.
