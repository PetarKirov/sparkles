# The `sparkles:test-runner` guide

Everything you need to use `sparkles:test-runner` on one page: add it to a
package, write tests, run and filter them, and reach the four environments
plain `unittest` blocks cannot — compile time, `-betterC`, WebAssembly, and
benchmarks. For the reasoning behind the design, see
[Explanation → Design](./explanation/design.md); each section below links to
its deeper reference.

`sparkles:test-runner` is a drop-in successor to the [`silly`](https://gitlab.com/AntonMeep/silly)
runner: same `@("name")` UDAs, same `-i`/`-e`/`-v`/`-t`/`--no-colours` CLI,
same parallel execution. It adds opt-in attributes and keeps `dub test` close
to a vanilla build.

## Add it to your package

Add one dependency to your package's `unittest` configuration:

```sdl
configuration "unittest" {
    dependency "sparkles:test-runner" version="*"
}
```

That is all — the runner registers itself as druntime's unit tester, so
`dub test` discovers and runs your `unittest` blocks through it. A thin shim
compiles into your test binary and links a prebuilt implementation library, so
you pay almost none of the runner's own compile cost on each build.

> [!NOTE]
> Inside the sparkles monorepo the recipe differs slightly for `base`,
> `core-cli`, and `test-utils` (they source-include the runner to avoid a
> dependency cycle). See [Getting started](./tutorial/getting-started.md).

## Write and run a test

Name a test with a string UDA and always give it an explicit safety attribute:

```d
module geometry;

int area(int w, int h) @safe pure nothrow @nogc => w * h;

@("area.rectangle")
@safe pure nothrow @nogc
unittest
{
    assert(area(3, 4) == 12);
}
```

```console
$ dub test
 ✓ geometry area.rectangle

Summary: 1 passed, 0 failed in 0.2ms
```

A failing test prints the throwable, its `file:line`, and a stack trace
truncated at the runner's own frames; the process exits non-zero.

## Run and filter

All options go after `--`. See [Run and filter tests](./how-to/run-and-filter-tests.md).

```bash
dub test                        # everything, in parallel
dub test -- -i "area"           # only tests whose name matches a regex
dub test -- -e "slow"           # skip tests matching a regex
dub test -- -v                  # durations, [file:line] links, full traces
dub test -- -t 1                # single-threaded
dub test -- -l                  # list discovered tests, with attribute markers
```

`-i`/`-e` are regular expressions matched against
`<fully.qualified.symbol> <test name>`, so both `-i "geometry"` (module) and
`-i "area.rectangle"` (name) work. When both are given they combine: a test
must match `-i` and not match `-e`. Under a
terminal, `-v` locations become OSC 8 hyperlinks and long lines are truncated
to the terminal width (both require `sparkles:core-cli` in the closure).

## The opt-in attributes

Import the markers **unconditionally** (not under `version (unittest)`) — the
compiler resolves unittest UDAs even in builds that skip the bodies. All are
plain marker types, so annotated tests remain ordinary `unittest` blocks for
any other runner. Full details: [Attributes reference](./reference/attributes.md).

| Attribute    | Runs where                          | Trigger      |
| ------------ | ----------------------------------- | ------------ |
| _(none)_     | at runtime, in parallel             | `dub test`   |
| `@ctfe`      | at compile time (CTFE)              | `dub test`   |
| `@betterC`   | runtime **and** druntime-free       | `--better-c` |
| `@wasm`      | runtime **and** cross-compiled wasm | `--wasm`     |
| `@benchmark` | timed, skipped by normal runs       | `--bench`    |

### `@ctfe` — verify at compile time

The runner evaluates `@ctfe` tests through the CTFE interpreter instead of at
runtime. A failure is a compile error with the CTFE call stack; it never
executes (or exists) at runtime. Evaluation happens after `-i`/`-e` filtering
and needs a D compiler on `PATH`. See [Write `@ctfe` tests](./how-to/write-ctfe-tests.md).

```d
import sparkles.test_runner.attributes : ctfe;

@("caseFold.ascii")
@ctfe @safe pure nothrow @nogc
unittest
{
    assert(caseFold("MiXeD") == "mixed");   // pass → ⚙ … (compile time)
}
```

### `@betterC` — run without druntime

`@betterC` tests run normally under `dub test`; `--better-c` additionally
extracts them into a standalone `-betterC` program (no GC, exceptions, or
`TypeInfo`) and runs it. Extracted tests may reference the module's public
templates/CTFE-able code by default; opt non-template modules in with
`--include-import=<pattern>`. See [Write `@betterC` tests](./how-to/write-betterc-tests.md).

```d
import sparkles.test_runner.attributes : betterC;

@("text.readers.tryConsume")
@betterC @safe pure nothrow @nogc
unittest { /* ... */ }
```

### `@wasm` — run on WebAssembly

`@wasm` tests run normally under `dub test`; `--wasm` cross-compiles them to
`wasm32` with LDC and runs them under `node`/`deno`/`bun`/`wasmtime` (missing
toolchain is a skip, not a failure). All `@betterC` constraints apply, plus
the module's whole import chain must be wasm-compatible. See
[Write `@wasm` tests](./how-to/write-wasm-tests.md).

### `@benchmark` — measure

`@benchmark` tests are skipped by normal runs and measured by `--bench`, which
auto-scales the iteration count (Rust libtest's protocol) and reports
ns/iter statistics. Time only part of a body with `benchIter`, and route
inputs and results through `blackBox` so the optimizer can't fold the work
away. See [Benchmark with `@benchmark`](./how-to/benchmark.md).

```d
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchIter, blackBox;

@("sort.bench")
@benchmark @safe
unittest
{
    auto data = makeInput(10_000);                       // setup — not measured
    benchIter({ blackBox(sortCopy(blackBox(data))); });  // measured
}
```

```console
$ dub test -- --bench
╭────────────┬───────┬─────────────┬───────┬────────┬────────╮
│ benchmark  │ iters │ median/iter │  ±dev │    min │    max │
│ sort.bench │  2048 │      41.7µs │ 0.3µs │ 41.1µs │ 43.0µs │
╰────────────┴───────┴─────────────┴───────┴────────┴────────╯
```

Add `--perf` for hardware performance counters (Linux `perf_event`): a separate
counting pass brackets each benchmark's timed body — so the counter ioctls never
perturb the ns/iter numbers — and the table gains IPC, instructions/iter, and
branch/cache miss-rate columns. An individually dropped counter (the
last-level-cache pair under PMU multiplexing) shows as `—`; when the whole
group can't open (a paranoid kernel) the perf columns are omitted with a
stderr note. Off Linux the flag is inert.

```console
$ dub test -- --bench --perf
╭────────────┬───────┬─────────────┬─┬─────┬────────────┬─────────┬────────────╮
│ benchmark  │ iters │ median/iter │…│ IPC │ instr/iter │ br-miss │ cache-miss │
│ sort.bench │  2048 │      41.7µs │…│ 2.9 │     118.4k │   0.71% │      3.20% │
╰────────────┴───────┴─────────────┴─┴─────┴────────────┴─────────┴────────────╯
```

Every measured column — client throughput/level metrics and the perf counters —
is a named entry in a metric _catalog_. `--list-metrics` (or `--metrics=?`) prints
it: each metric's column label, its class (`quantitative` = safe to report, vs
`diagnostic` = explains only), and its source. `--metrics=LIST` then picks which
columns to show — a comma-separated list of names, a `*`-suffixed glob (e.g.
`--metrics=ipc,cache-miss`), or `all` for every available column (including opt-in
extras like `cycles`/`branches`/`page-faults`). With no `--metrics`, the standard
columns show.

For I/O-bound benchmarks, the catalog also carries cheap **Tier-0** counters that
need no `perf_event` and no privilege (`getrusage` + `/proc/self/io`, tagged
`quantitative`): syscall counts (`syscr`, `syscw`), page faults (`minflt`,
`majflt`), context switches (`vol-cs` = blocked on I/O, `invol-cs` = preempted),
bytes through the syscall layer vs the block device (`rchar`/`wchar` vs
`rd-bytes`/`wr-bytes`), and the derived page-cache-hit rate (`cache-hit`). They are
opt-in columns — selecting any (e.g. `--metrics=syscr,majflt,cache-hit`) runs one
extra `/proc`-snapshot counting pass, so plain runs pay nothing. On CPU-bound,
in-memory benchmarks these read ≈0; they earn their keep on code that touches the
kernel.

For a per-syscall breakdown — the `strace -c` view, in-process — add `--syscalls`:
bare adds a `syscalls` total column, and `--syscalls=futex,sched_yield` adds one
`sc:<name>` column per named syscall (a separate perf-tracepoint counting pass, so
timings stay clean). The named tracepoints are exact; the total also sees the
pass's own bookkeeping. This reads the tracepoint ids from `tracefs`, which is
**root-only on most systems**, and needs `perf_event_paranoid ≤ 1`; where either is
missing the counters degrade to unavailable (a stderr note, columns omitted) and
the run still passes.

#### `benchCase` — matrix benchmarks (many rows from one test)

`benchIter` measures one thing. To benchmark a **matrix** — several
implementations across several inputs — call `benchCase` repeatedly inside one
`@benchmark` body; each call emits its own row. The plain-D loop (and a
`static foreach` over a compile-time engine list) _is_ the matrix — the runner
never learns about "engines" or "ops":

```d
import sparkles.test_runner.bench : benchCase, Metric, Unit;

@("json.parse") @benchmark
unittest
{
    static foreach (Engine; Engines)
        foreach (ds; datasets)
            registerParse!Engine(ds);   // ds by value → each case captures its own copy
}

// One case per (Engine, ds), registered from its own frame so its closures
// capture their own engine and `ds` — never a shared loop variable.
void registerParse(Engine)(Dataset ds)
{
    auto e = new Engine;   // heap: this case owns it, kept alive until it runs
    benchCase(
        name:     Engine.name,              // the varying dimension (the implementation)
        labels:   ["dataset": ds.name, "operation": "parse"],  // group/filter dimensions
        setup:    () { e.setup(); },        // untimed, once before this case's samples
        timed:    () => e.parse(ds.text),   // measured; its result flows to `after`
        after:    (ref doc) { enforce(doc.matches(reference), "mismatch"); e.free(doc); },
        teardown: () { e.teardown(); },     // untimed, once after this case's samples
        metrics:  [Metric(Unit("B"), ds.text.length, Metric.Mode.rate)],  // → a B/s column
    );
}
```

`--group-by=dataset,operation` then prints one table per `(dataset, operation)`
group as it finishes — the group name spliced into the top border, each table
comparing the engines (the `name`s); `--group-by=list` lists the label keys the
run offers, and `--sort-by=KEY` orders rows by any metric column (default:
`median/iter`).

Tables are built to read at a glance: timing and metric columns align on the
decimal point (mixed units still compare), consecutive streamed tables share
their column geometry, and on an interactive terminal the current group's
table **ticks live** — rows land as cases complete beneath a dim
`⠹ name │ measuring…` row, then the finished table graduates into scrollback.
Piped output skips all animation and stays byte-stable.

> [!IMPORTANT]
> Under `--bench`, `benchCase` **registers** the case and the runner measures it
> later (grouped, so each table streams as its group finishes) — the closures run
> _after_ the body returns. So each case must be self-contained: register it from a
> helper that takes its varying state **by value** (a `foreach` loop variable is a
> single shared slot once execution is deferred), give it its own state, and put
> untimed per-case setup/release in **`setup`/`teardown`** (which bracket the case's
> measurement) — never in code around the `benchCase` call, whose scope has long
> exited by execution time. Outside `--bench` the case runs once immediately, for
> correctness.

- **`timed`** is the measured body; its return value flows to **`after`**, which
  runs _untimed_ after every iteration to **verify + release** the result.
- **`setup`/`teardown`** (optional) run untimed once around this case's whole
  measurement — for state built once and held across iterations (e.g. parse the
  document a serialize case serializes, and release it after).
- **`after` reports failure two ways**: `throw` on a mismatch → the case
  becomes an in-table error row with its trace printed, the matrix continues,
  and the run reports failure; return an
  [`Expected`](../../guidelines/idioms/expected/index.md)
  error → the same isolated error row, without a trace. A case with nothing to
  release/verify passes a no-op (`() {}` for a `void` body).
- **`metrics`** attach throughput columns: `Metric(unit, amount, mode)` with
  `mode` `rate` (`amount ÷ iteration-time` → `<unit>/s`) or `level` (as-is).
  Units are open-basis names — `"B"`, `"req"`, `"tweet"`, `"frame"` — vocabulary
  aligned to the forthcoming `sparkles:quantities` library.

`benchCase` times each call individually (so the result can be released between
iterations), which suits µs-and-up operations; keep `benchIter` for the finest
micro-benchmarks. One `@benchmark` can emit many rows, and `--perf` adds its
counter columns to each:

```console
$ dub test -- --bench --perf
╭──────────────────┬───────┬─────────────┬────────┬─────┬────────────┬─────────╮
│ benchmark        │ iters │ median/iter │    B/s │ IPC │ instr/iter │ br-miss │
│ simdjson/twitter │     1 │      41.7µs │ 15.14G │ 3.1 │     118.4k │   0.71% │
│ stdjson/twitter  │     1 │     611.0µs │  1.03G │ 1.8 │      2.44M │   2.90% │
╰──────────────────┴───────┴─────────────┴────────┴─────┴────────────┴─────────╯
```

Attributes compose: `@betterC @wasm` opts one test into both extra
environments.

## Command-line reference

Everything after `--` in `dub test -- <options>`. Full table:
[CLI reference](./reference/cli.md).

| Option                     | Description                                                                            |
| -------------------------- | -------------------------------------------------------------------------------------- |
| `-i`, `--include REGEX`    | Run only tests whose `fullName name` matches                                           |
| `-e`, `--exclude REGEX`    | Skip tests whose `fullName name` matches; combines with `-i` (match `-i` and not `-e`) |
| `-v`, `--verbose`          | Durations, `[file:line]` locations, full stack traces                                  |
| `-t`, `--threads N`        | Worker threads; `0` (default) auto-detects, `1` is single-thread                       |
| `-l`, `--list`             | List discovered tests with their attribute markers                                     |
| `--no-colours`             | Disable colour (also honours `$NO_COLOR` and non-tty stdout)                           |
| `--bench`                  | Measure `@benchmark` tests                                                             |
| `--perf`                   | With `--bench`: add hardware perf counters (Linux `perf_event`)                        |
| `--syscalls[=LIST]`        | With `--bench`: count syscalls/iter (perf tracepoints); bare = total, `=a,b` per-name  |
| `--metrics=LIST`           | With `--bench`: pick metric columns (glob, `all`, or `?`/`help` to list)               |
| `--list-metrics`           | List available metric columns (name, class, source) and exit; works without `--bench`  |
| `--sort-by=KEY`            | With `--bench`: sort rows by `name` or a metric column (default: `median/iter`)        |
| `--group-by=KEYS`          | With `--bench`: one table per group of these label keys (`=all`, `=list`)              |
| `--bench-json=FILE`        | With `--bench`: also dump the results as JSON (baseline snapshots)                     |
| `--bench-min-time=MS`      | With `--bench`: per-case measurement budget in ms (default 5)                          |
| `--better-c`               | Extract and run `@betterC` tests under `-betterC`                                      |
| `--wasm`                   | Cross-compile and run `@wasm` tests on `wasm32`                                        |
| `--ctfe-trace FILE`        | Evaluate `@ctfe` tests under LDC `-ftime-trace`; per-test cost                         |
| `--self-test`              | Also run the runner's own unittests                                                    |
| `--compiler DC`            | Compiler for `@ctfe`/`--better-c`/`--wasm` (`$DC`, then ldc2/dmd)                      |
| `-I`, `--import-path DIR`  | Extra import path for extraction/probe compiles (repeatable)                           |
| `--include-import PATTERN` | Compile matching modules into `--better-c`/`--wasm` (repeatable)                       |
| `--keep`                   | Keep generated program/probe files                                                     |
| `-h`, `--help`             | Option summary                                                                         |

**Exit status:** non-zero when any test fails, in every mode — safe for CI and
`git bisect run`. Skipped tests (below) never fail a run.

## Good to know

- **Skip, don't silently pass.** A test that needs an environment capability —
  perf counters, a root-only interface, a toolchain binary — should call
  `skipTest("reason")` from `sparkles.test_runner.skip` instead of returning
  early: it renders as a yellow `⊘` line plus an `N skipped` summary segment,
  keeping the gap visible without failing the run. See
  [Skip tests at runtime](./how-to/skip-tests.md).

- **Keep tests in feature modules, not `package.d`.** Like silly, discovery
  sees only the modules dub lists in `dub_test_root.allModules`, which excludes
  `package.d` — tests there run zero and silently "pass".
- **Give every test an explicit safety attribute** (`@safe`/`@system`), and add
  `pure nothrow @nogc` where the code allows; a test that must stay `@nogc` then
  fails to compile the moment it accidentally allocates.
- **Naming:** the first string UDA (`@("...")`) is the display name; without one
  the compiler-generated identifier is used.

Ready for more? Start with the [tutorial](./tutorial/getting-started.md), or
jump to any how-to guide linked above.
