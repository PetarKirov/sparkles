/**
 * User-defined attributes recognized by the `sparkles:test-runner` unittest
 * runner.
 *
 * Attach these to `unittest` blocks to opt into special handling:
 * ---
 * import sparkles.test_runner.attributes : benchmark, betterC, ctfe;
 *
 * @("SmallBuffer.append")
 * @betterC @safe pure nothrow @nogc
 * unittest { /+ also compiled & run with -betterC via `--better-c` +/ }
 *
 * @("levenshtein.ctfe")
 * @ctfe @safe pure nothrow
 * unittest { /+ evaluated during compilation, not at runtime +/ }
 *
 * @("SmallBuffer.append.bench")
 * @benchmark @safe
 * unittest { /+ timed with auto-scaling iterations via `--bench` +/ }
 * ---
 *
 * All attributes are plain marker types — the runner discovers them with
 * `hasUDA` — so annotated tests remain ordinary `unittest` blocks for any
 * other runner.
 */
module sparkles.test_runner.attributes;

/// Marks a `unittest` as compatible with `-betterC` (no druntime, no GC, no
/// exceptions). Such tests run normally in regular test builds, and are
/// additionally extracted, compiled with `-betterC`, and executed without
/// druntime when the runner is invoked with `--better-c`.
struct betterC
{
}

/// Marks a `unittest` for compile-time execution: the runner forces the test
/// through CTFE with `static assert` during the test build, so a failure is a
/// compile error pointing into the test body. The test is $(I not) executed
/// again at runtime; the run report lists it as verified at compile time.
///
/// The test body must be CTFE-able (no I/O, no `@system` tricks, no
/// runtime-only intrinsics). Named after — and forward-compatible with — the
/// `@__ctfe` function attribute introduced in DMD 2.113.
struct ctfe
{
}

/// Marks a `unittest` as WebAssembly-compatible. Such tests run normally in
/// regular test builds, and are additionally cross-compiled to `wasm32` and
/// executed with an available WebAssembly runtime (`wasmtime`, `node`,
/// `deno`, or `bun`) when the runner is invoked with `--wasm`.
struct wasm
{
}

/// Marks a `unittest` as a benchmark. Benchmarks are skipped in normal test
/// runs and executed by `--bench`, which times the test body with an
/// auto-scaling iteration count (libtest-style) and reports ns/iter
/// statistics. Use $(REF benchIter, sparkles,test_runner,bench) inside the
/// test to time only a part of the body, and
/// $(REF blackBox, sparkles,test_runner,bench) to keep results alive.
struct benchmark
{
    /// Fixed iteration count per sample; `0` (the default) auto-scales the
    /// count until one sample takes long enough to time reliably.
    uint iterations = 0;
}
