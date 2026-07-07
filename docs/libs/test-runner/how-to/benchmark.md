# Benchmark with `@benchmark`

`@benchmark` tests are skipped by normal `dub test` runs and measured by
`--bench`:

```bash
dub test :base -- --bench
```

```console
╭────────────────┬─────────┬─────────────┬────────┬────────┬────────╮
│ benchmark      │ iters   │ median/iter │ ±dev   │ min    │ max    │
│ medianOf.bench │ 2097152 │ 1.86ns      │ 0.02ns │ 1.84ns │ 1.97ns │
╰────────────────┴─────────┴─────────────┴────────┴────────┴────────╯
```

## Measurement protocol

The protocol follows Rust libtest's `Bencher`: the per-sample iteration
count doubles until one sample takes at least 5 ms (so fast operations are
timed over millions of iterations), then 32 samples are collected and
summarized as median, median-absolute-deviation, min, and max
nanoseconds-per-iteration. `@benchmark(iterations: 1000)` pins the count
instead of auto-scaling.

Benchmarks run serially (never in the test thread pool), and the whole test
body is the measured unit by default.

## Excluding setup: `benchIter`

To time only part of the body, call `benchIter` — the runner invokes the
test once, and `benchIter` runs the measurement loop over just the closure:

```d
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchIter, blackBox;

@("sort.bench")
@benchmark @safe
unittest
{
    auto data = makeInput(10_000);              // setup — not measured
    benchIter({ blackBox(sortCopy(blackBox(data))); }); // measured
}
```

Outside `--bench` (e.g. when another runner executes the test), `benchIter`
invokes the closure exactly once, so the test still works as a plain test.

## Many rows from one test: `benchCase`

`benchIter` measures one thing. To benchmark a **matrix** — several
implementations across several inputs — call `benchCase` repeatedly; each call
emits its own row, so ordinary D loops (and a `static foreach` over a
compile-time list) build the table:

```d
import sparkles.test_runner.bench : benchCase, Metric, Unit;

@("json.parse") @benchmark
unittest
{
    static foreach (Engine; Engines)
        foreach (ds; datasets)
        {
            Engine e;
            benchCase(
                name:    Engine.name ~ "/" ~ ds.name,
                timed:   () => e.parse(ds.text),   // measured; its result flows to `after`
                after:   (ref doc) { enforce(doc.matches(reference), "mismatch"); e.free(doc); },
                metrics: [Metric(Unit("B"), ds.text.length, Metric.Mode.rate)],  // a B/s column
            );
        }
}
```

- **`timed`** returns a result that flows to **`after`**, which runs _untimed_
  after each iteration to verify and release it. `after` may **throw** (the whole
  benchmark test fails) or return an
  [`Expected`](../../../guidelines/idioms/expected/index.md) error (only this
  case becomes an error row; the matrix continues). A case with nothing to
  release/verify passes a no-op `after` (`() {}` for a `void` body).
- **`metrics`** add throughput columns: `Metric(unit, amount, mode)` with `mode`
  `rate` (`amount ÷ iteration-time` → `<unit>/s`) or `level` (as-is). Units are
  open-basis names (`"B"`, `"req"`, `"tweet"`, …), vocabulary aligned to the
  forthcoming `sparkles:quantities` library.

`benchCase` times each call individually so the result can be released between
iterations — suited to µs-and-up work; keep `benchIter` for the finest
micro-benchmarks.

## Defeating the optimizer: `blackBox`

`blackBox` is an identity function the optimizer cannot see through (an
empty asm barrier under LDC, a volatile store elsewhere) — the analogue of
Rust's `black_box`. Route both the **inputs** and the **result** of the
measured computation through it, or a pure computation over constants gets
folded away and you measure an empty loop.

## Hardware counters: `--perf`

Add `--perf` to `--bench` for hardware performance counters (Linux
`perf_event`): a separate counting pass brackets each benchmark's timed body —
so the counter ioctls never perturb the ns/iter numbers — and the table grows
IPC, instructions/iter, and branch/cache miss-rate columns.

```bash
dub test :base -- --bench --perf
```

A counter that can't be opened — a paranoid kernel (`perf_event_paranoid`), or
the last-level-cache pair dropped to avoid PMU multiplexing — shows as `—`; off
Linux the flag is inert.

## Choosing columns: the metric catalog

Every measured column — client `metrics`, the perf counters, and the counters
below — is a named entry in a _catalog_. `--list-metrics` (or `--metrics=?`)
prints it, with each metric's **class** (`quantitative` = safe to report vs
`diagnostic` = explains only) and source:

```bash
dub test :base -- --bench --list-metrics
```

`--metrics=LIST` then picks the columns: a comma-separated list, a `*`-suffixed
glob, or `all`.

```bash
dub test :base -- --bench --perf --metrics=ipc,cache-miss   # just these two
dub test :base -- --bench --perf --metrics=all              # every available column
```

With no `--metrics`, the standard columns show (identical to before this feature).

## I/O-bound signals: Tier-0 counters and `--syscalls`

For code that touches the kernel, two cheap sources answer "where is the time
going off-CPU":

- **Tier-0 counters** (no privilege): `getrusage` + `/proc/self/io` — syscall
  counts (`syscr`, `syscw`), page faults (`minflt`, `majflt`), context switches
  (`vol-cs` = blocked on I/O, `invol-cs` = preempted), bytes through the syscall
  layer vs the block device (`rchar`/`wchar` vs `rd-bytes`/`wr-bytes`), and the
  derived page-cache-hit rate (`cache-hit`). They are opt-in columns — select any
  and one extra `/proc`-snapshot pass runs, so plain runs pay nothing:

  ```bash
  dub test :base -- --bench --metrics=syscr,majflt,cache-hit
  ```

- **`--syscalls`** — the `strace -c` view, in-process (Linux perf tracepoints).
  Bare adds a `syscalls` total column; `--syscalls=futex,sched_yield` adds one
  `sc:<name>` column per named syscall:

  ```bash
  dub test :base -- --bench --syscalls=futex,sched_yield
  ```

  This reads tracepoint ids from `tracefs`, which is **root-only on most
  systems**, and needs `perf_event_paranoid ≤ 1`; where either is missing the
  counters degrade to unavailable (a stderr note, columns omitted) and the run
  still passes.

On CPU-bound, in-memory benchmarks these read ≈0 — they earn their keep on
I/O-bound code.
