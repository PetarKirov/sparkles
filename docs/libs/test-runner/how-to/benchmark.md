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

## Defeating the optimizer: `blackBox`

`blackBox` is an identity function the optimizer cannot see through (an
empty asm barrier under LDC, a volatile store elsewhere) — the analogue of
Rust's `black_box`. Route both the **inputs** and the **result** of the
measured computation through it, or a pure computation over constants gets
folded away and you measure an empty loop.
