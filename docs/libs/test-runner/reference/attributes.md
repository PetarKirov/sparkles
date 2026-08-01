# Attributes

All attributes live in `sparkles.test_runner.attributes` and are plain marker
types — a test annotated with them remains an ordinary `unittest` block for
any other runner. Import them **unconditionally** (not under
`version (unittest)`): unittest UDAs are resolved even in builds that do not
compile the unittest bodies.

## `@betterC`

The test is `-betterC`-compatible (no GC, exceptions, TypeInfo, druntime).

- Runs normally under `dub test`.
- `--better-c` extracts it into a standalone druntime-free program.
- The body may only use the module's public symbols. Its own module is
  compiled in by default, so ordinary functions work; other modules are
  opted in with `--include-import`.
- `@betterC(selfContained: true)` keeps the module out entirely, limiting
  the body to templates/CTFE-able code — which is what lets a module that
  cannot compile under `-betterC` still host such a test.

## `@ctfe`

The test runs at **compile time instead of runtime**.

- Evaluated through CTFE by a runner-generated probe compiled with
  `-o- -unittest` (semantic analysis only) after `-i`/`-e` filtering — so
  filters control which tests execute, and `--help`/`--list` work even when
  an `@ctfe` test would fail.
- Reported as `⚙ … (compile time)` on success, `✗ … (compile time)` plus the
  compiler's CTFE error trail on failure; never executed at runtime.
- The body must be CTFE-able; needs a D compiler on `PATH` (or `$DC` /
  `--compiler`) at run time.
- Named after (and forward-compatible with) DMD 2.113's `@__ctfe` function
  attribute.

## `@wasm`

The test is WebAssembly-compatible.

- Runs normally under `dub test`.
- `--wasm` cross-compiles it to `wasm32` with LDC and runs it under
  `node`/`deno`/`bun`/`wasmtime`.
- All `@betterC` constraints apply, and with a stock LDC the module's import
  chain must avoid druntime headers that do not support `wasm32`.

## `@benchmark` / `@benchmark(iterations: N)`

The test is a benchmark.

- Skipped by normal runs (counted in the summary); measured by `--bench`.
- `iterations` pins the count; `0` (default) auto-scales. Batched timing
  (`benchIter`/whole-body) pins the per-sample iteration count; a per-call
  `benchCase` runs exactly N timed calls, one sample each.
- The whole body is the measured unit by default. From
  `sparkles.test_runner.bench`: `benchIter` measures a sub-section, `benchCase`
  emits many rows from one test (a matrix, with `Metric` throughput columns),
  and `blackBox` is the optimizer barrier.
- `--perf` adds Linux `perf_event` hardware-counter columns (IPC,
  instructions/iter, cache/branch miss rates) to the `--bench` table.

## `@workload` / `@workload(reps: N)`

The test is a workload, measured under the **window model** — the counterpart
to `@benchmark`'s per-iteration statistics.

- Skipped by normal runs (counted in the summary); measured by `--bench` in a
  **single pass**: the body runs once (`reps` times for the measured window
  content; `0` is treated as `1`), and the runner reports each open counter
  source's **deltas across the window** plus a wall-clock decomposition
  (on-CPU user/kernel from rusage, runqueue wait from schedstat, and a
  clamped `other` residual — locks/sleeps are never attributed to a
  fabricated cause). The body is never re-run for counting, so expensive or
  non-idempotent workloads are safe.
- The whole body is the window by default. From
  `sparkles.test_runner.workload`, `workloadWindow(dg)` /
  `workloadWindow(name, dg)` measures only the closure (× reps); each call is
  one row in the `workloads` table. Outside `--bench` the closure runs
  exactly once, inertly.
- `--perf` / `--syscalls` / `--metrics` open the same sources for windows;
  the table shows a fixed summary column set per source (full totals in
  `--bench-json`'s `windows` array).
- On Linux the decomposition is thread-scoped (the driving thread); rusage's
  user/kernel split is tick-sampled, so windows should be **long** (tens of
  milliseconds up) for the split to be signal rather than quantization.

See [Measure workloads](../how-to/measure-workloads.md).

## Combining

Attributes compose freely — e.g. `@betterC @wasm` opts one test into both
extra environments; `@("name")` string UDAs keep naming the test. The one
exclusion: `@benchmark` and `@workload` are different measurement models for
the same body, and combining them is a discovery-time error.
