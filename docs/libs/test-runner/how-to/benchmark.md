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
