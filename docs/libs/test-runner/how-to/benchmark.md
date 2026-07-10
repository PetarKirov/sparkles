# Benchmark with `@benchmark`

`@benchmark` tests are skipped by normal `dub test` runs and measured by
`--bench`:

```bash
dub test :yourpkg -- --bench
```

```console
╭────────────────┬─────────┬─────────────┬────────┬────────┬────────╮
│ benchmark      │   iters │ median/iter │   ±dev │    min │    max │
│ medianOf.bench │ 2097152 │      1.86ns │ 0.02ns │ 1.84ns │ 1.97ns │
╰────────────────┴─────────┴─────────────┴────────┴────────┴────────╯
```

(Illustrative output. An assert-enabled build — dub's stock `unittest` build
type — prints a warning: real numbers need an optimized unittest buildType,
e.g. `buildOptions "unittests" "releaseMode" "optimize" "inline"` invoked as
`dub test -b <name>`.)

## Measurement protocol

The protocol follows Rust libtest's `Bencher`: the per-sample iteration
count doubles until one sample takes at least 5 ms (so fast operations are
timed over millions of iterations), then 32 samples are collected and
summarized as median, median-absolute-deviation, min, and max
nanoseconds-per-iteration. `@benchmark(iterations: 1000)` pins the count
instead of auto-scaling — per sample for batched (`benchIter`/whole-body)
timing; a per-call `benchCase` runs exactly N timed calls, one sample each.
`--bench-min-time=MS` overrides the 5 ms budget: for per-call cases it is
the minimum total measured time per case (samples keep accumulating past 32
until it is met), for batched ones the per-sample auto-scale target.

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
            registerParse!Engine(ds);   // ds by value → each case captures its own copy
}

void registerParse(Engine)(Dataset ds)
{
    auto e = new Engine;   // heap: this case owns it, kept alive until it runs
    benchCase(
        name:    Engine.name,              // the varying dimension (the implementation)
        labels:  ["dataset": ds.name, "operation": "parse"],  // group/filter dimensions
        timed:   () => e.parse(ds.text),   // measured; its result flows to `after`
        after:   (ref doc) { enforce(doc.matches(reference), "mismatch"); e.free(doc); },
        metrics: [Metric(Unit("B"), ds.text.length, Metric.Mode.rate)],  // a B/s column
    );
}
```

`--group-by=dataset,operation` splits the report into one streamed table per
`(dataset, operation)` group, each comparing the engines by `name`. `=all` groups
by every label key; `=list` prints the keys the run offers.

- Under `--bench`, `benchCase` **registers** the case; the runner measures it
  later (grouped, so each table streams as its group finishes). The closures run
  after the body returns, so register each case from a helper taking its varying
  state **by value** (a `foreach` variable is one shared slot under deferred
  execution), give it its own state, and put untimed per-case setup/release in the
  optional **`setup`/`teardown`** (which bracket the case's measurement) — not
  around the call. Outside `--bench` the case runs once immediately.
- **`timed`** returns a result that flows to **`after`**, which runs _untimed_
  after each iteration to verify and release it. `after` may **throw** — under
  `--bench` the case becomes an in-table error row with its trace printed, the
  matrix continues, and the run reports failure — or return an
  [`Expected`](../../../guidelines/idioms/expected/index.md) error (the same
  isolated error row, without a trace). A case with nothing to release/verify
  passes a no-op `after` (`() {}` for a `void` body). Error rows sort last in
  their table under every `--sort-by` order.
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

An individually dropped counter (the last-level-cache pair under PMU
multiplexing) or an explicitly `--metrics`-selected unavailable column shows
as `—`; when the whole group can't open (a paranoid kernel's
`perf_event_paranoid`, or a PMU too busy to ever schedule the group) the
default perf columns are omitted entirely and a stderr note says why. Off
Linux the flag is inert.

## Choosing columns: the metric catalog

Every measured column — client `metrics`, the perf counters, and the counters
below — is a named entry in a _catalog_. `--list-metrics` (or `--metrics=?`)
prints it, with each metric's **class** (`quantitative` = safe to report vs
`diagnostic` = explains only) and source. It works with or without `--bench`:

```bash
dub test :base -- --list-metrics
```

`--metrics=LIST` then picks the columns: a comma-separated list, a `*`-suffixed
glob, or `all`. Naming a perf metric (or `all`) opens the `--perf` pass on its
own, so you don't need to add `--perf` as well:

```bash
dub test :base -- --bench --metrics=ipc,cache-miss   # opens --perf for these two
dub test :base -- --bench --metrics=all              # every available column
```

With no `--metrics`, the standard columns show (identical to before this
feature). A selector that matches nothing warns on stderr, like `--sort-by`
and `--group-by`.

## Machine-readable results: `--bench-json`

`--bench-json=FILE` also writes the run as one JSON document — for committed
baseline snapshots that later runs are compared against:

```bash
dub test :yourpkg -- --bench --perf --bench-min-time=2000 --bench-json=results.json
```

The document is `{schema, meta, columns, rows}`: `meta` records the host,
compiler, CPU, and the run's effective measurement knobs (baselines are
self-describing); `columns` describe the available catalog metrics; each row
carries `name`, its sorted `labels` (the `--group-by` dimensions travel here —
the JSON itself keeps measurement order, unaffected by `--sort-by`/
`--group-by`), the timing summary in nanoseconds, and a `metrics` object keyed
by catalog names (`--list-metrics`). Error rows keep their `labels` and
`error` with `null` timing fields; unavailable counters are `null`. The
output is deterministic and float-safe for committing (integral values print
as integers, others to 6 significant digits).

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
