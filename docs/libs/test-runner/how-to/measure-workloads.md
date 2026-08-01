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
╭──╼ workloads ╾───┬──────┬────────┬─────────┬─────────┬────────┬─────────┬─────────┬─────────┬──────┬────────╮
│ workload         │ reps │   wall │ cpu usr │ cpu krn │   runq │   other │   instr │  cycles │  ipc │ pg-flt │
┝━━━━━━━━━━━━━━━━━━┿━━━━━━┿━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━┿━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━┿━━━━━━━━━┿━━━━━━┿━━━━━━━━┥
│ ingest.fullFile  │    1 │ 30.1ms │  29.8ms │ 126.0µs │ 24.5µs │ 171.0µs │ 572.98M │ 142.75M │ 4.01 │      1 │
╰──────────────────┴──────┴────────┴─────────┴─────────┴────────┴─────────┴─────────┴─────────┴──────┴────────╯
```

(Illustrative output. Workloads measure after the benchmark groups, in the
same `--bench` run, sharing the same source selection: `--perf`,
`--syscalls`, `--metrics=raw:…`/`pfm:…` columns all apply — as window
**totals**, not per-iteration averages.)

## The wall-clock decomposition

Every window's wall time is split into:

| Column    | Source                        | Meaning                                    |
| --------- | ----------------------------- | ------------------------------------------ |
| `cpu usr` | `getrusage` user time         | on-CPU, user space                         |
| `cpu krn` | `getrusage` system time       | on-CPU, kernel                             |
| `runq`    | `/proc/thread-self/schedstat` | runnable but waiting for a CPU             |
| `other`   | residual (clamped at 0)       | everything else off-CPU: locks, sleeps, IO |

The decomposition is deliberately honest: only runqueue wait (and, once the
PSI stall integral lands, disk stall) are true per-cause durations.
Everything else lands in `other` — the runner never fabricates a cause. A
component the host cannot attribute (schedstat unreadable, non-Linux) renders
an em dash, its time stays in `other`, and a note says so.

Two scoping facts worth knowing:

- On Linux the decomposition covers **the driving thread**
  (`RUSAGE_THREAD` + thread schedstat) — the only scoping under which
  `wall = onCpu + runq + other` adds up. CPU burned by other threads the
  body spawned is disclosed in the `note` column, not silently blended.
- rusage's user/kernel split is tick-sampled: on sub-millisecond windows it
  smears by up to a scheduler tick. Make windows **long** — tens of
  milliseconds and up — so the split is signal, not quantization.

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
