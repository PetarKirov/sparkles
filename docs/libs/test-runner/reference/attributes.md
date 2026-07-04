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
- The body may only use the module's public symbols; templates/CTFE-able
  code by default, plus modules opted in with `--include-import`.

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
- `iterations` pins the per-sample count; `0` (default) auto-scales it until
  a sample takes long enough to time reliably.
- Combine with `benchIter` (measure a sub-section) and `blackBox`
  (optimizer barrier) from `sparkles.test_runner.bench`.

## Combining

Attributes compose freely — e.g. `@betterC @wasm` opts one test into both
extra environments; `@("name")` string UDAs keep naming the test.
