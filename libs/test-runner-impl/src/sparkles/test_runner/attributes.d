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
    /// When `false` (the default), the extracted program compiles the test's
    /// own module in (`-i=<module>`), so the test may call that module's
    /// ordinary functions and not just its templates.
    ///
    /// Set it to `true` for a test that must stand entirely on its own. That
    /// is what lets a module which is $(I not) itself `-betterC`-codegen-clean
    /// still host a `@betterC` test: nothing of the module is compiled in, so
    /// only templates and CTFE-able code are reachable — and the test is
    /// asserting exactly that self-containment. The runner's own dogfooding
    /// tests use it, since their modules import Phobos.
    bool selfContained = false;
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
    /// As for $(LREF betterC)`.selfContained`: when `false` (the default) the
    /// cross-compiled program compiles the test's own module in, so the test
    /// may call its ordinary functions; `true` keeps the module out entirely.
    ///
    /// Self-containment matters more here than for `--better-c`: with a stock
    /// LDC a `@wasm` test's whole import chain must avoid druntime headers
    /// that do not support `wasm32`, which compiling the module in makes far
    /// more likely to be violated.
    bool selfContained = false;
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

/// Marks a `unittest` as a workload. Workloads are skipped in normal test
/// runs and measured by `--bench` under the $(I window) model: the body runs
/// once (or `reps` times inside one measured window), and the runner reports
/// counter deltas across the window plus a wall-clock decomposition —
/// rather than the per-iteration statistics of $(LREF benchmark). The two
/// models are exclusive: a test cannot be both `@benchmark` and `@workload`.
/// Use $(REF workloadWindow, sparkles,test_runner,workload) inside the test
/// to measure only a part of the body.
struct workload
{
    /// Times the window content runs inside the single measured window;
    /// `0` is treated as `1`.
    uint reps = 1;
}

@("attributes.selfContained.wasm")
@wasm(selfContained: true) @betterC(selfContained: true) @safe pure nothrow @nogc
unittest
{
    // Dogfoods @wasm (and @betterC) end to end, and dogfoods `selfContained`
    // itself. It lives in this import-free module on purpose: with a stock
    // LDC, a `@wasm` test's module import chain must avoid druntime headers
    // that don't support wasm32 (a wasm-enabled LDC with full
    // druntime/Phobos lifts that restriction).
    int parity;
    foreach (c; "wasm")
        parity ^= c;
    assert(parity == ('w' ^ 'a' ^ 's' ^ 'm'));
}
