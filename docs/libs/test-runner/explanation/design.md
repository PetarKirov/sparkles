# Design

## The seam: druntime's extended module unit tester

`dub test` generates a `dub_test_root` module whose `allModules` alias lists
the tested package's modules. The runner's `runner.d` (active only in
unittest builds) walks that list with `__traits(getUnitTests)` — module level
plus aggregates — and registers a `Runtime.extendedModuleUnitTester`, the
same seam silly used. Its `shared static this` is `@standalone`: under the
in-tree integration, `dub_test_root` imports the runner's modules back, and
without the attribute druntime rejects the module-constructor cycle.

## Why consumers use `sourcePaths`, not a dependency

The runner renders through `sparkles.base` (styled templates, `@nogc`
duration writers) and optionally `sparkles.core_cli` (tables, OSC 8 links) —
but `base` and `core-cli` also want the runner in their own
`configuration "unittest"`. dub rejects that package-level cycle (its cycle
detection unions dependencies across all configurations), so in-tree
consumers compile the runner in directly:

```sdl
importPaths "src" "../test-runner/src"   # attributes importable in all builds

configuration "unittest" {
    sourcePaths "../test-runner/src"      # runner compiled into test builds
}
```

Two consequences are handled explicitly:

- `core-cli` can never be in `base`'s test build, so all `core_cli` use is
  gated with `__traits(compiles, import …)` and degrades gracefully
  (space-aligned tables, plain `file:line`). This is ordinary Design by
  Introspection, applied to the build graph.
- The runner's modules land in every host's `allModules`, so its own tests
  are discoverable everywhere. They are hidden unless `--self-test` is given
  or the tested package _is_ the runner — decided from `allModules` module
  names plus the test-binary name, because a host whose only D modules are
  `package.d`s/ImportC shims (e.g. `ghostty`) has an `allModules` that looks
  identical to the runner's own.

The manifest still declares real `base`/`core-cli` dependencies: they serve
`dub test :test-runner` and external consumers, where no cycle exists.

## `@ctfe`: static assert as the executor

At module scope, `runner.d` expands

```d
static foreach (m; dub_test_root.allModules)
    static foreach (test; __traits(getUnitTests, moduleOf!m))
        static if (hasUDA!(test, ctfe))
            static assert(ctfePasses!test, …);
```

where `ctfePasses` is an immediately-invoked CTFE lambda calling the test.
Compilation _is_ the test run: a failure is a compile error with the CTFE
call stack, and reaching runtime proves every `@ctfe` test passed. Because
each forced evaluation shows up in LDC's `-ftime-trace` as a
`Ctfe: call __unittest_LN_CM` event carrying the test's `file:line`,
`--ctfe-trace` can attribute compile-time cost per test (the 100+ MB trace
is scanned linearly instead of parsed as JSON).

## `@betterC`/`@wasm`: reflection-driven extraction

`unittest` blocks cannot run under `-betterC` or on `wasm32` — druntime's
test driver does not exist there — so those tests are _extracted_ into a
generated program with a hand-rolled `main`, the approach of phobos'
`@betterC` suite. Where dlang's `tests_extractor` parses source with
libdparse, this runner already knows everything from reflection —
`__traits(getLocation)` (where), `__traits(getFunctionAttributes)` (what to
re-apply) — so extraction reduces to a comment/string-aware brace matcher
slicing the body text, re-emitted behind a `#line` directive so errors point
at the original file.

The generated `-betterC` program announces each test via `printf` before
calling it (an abort is attributable); the wasm module exports each test as
`run_test_<i>` with a trapping `__assert` (bare `wasm32` has no libc), and a
generated JS shim — or `wasmtime --invoke` — reports per-test outcomes from
the host side.

Extracted tests import their module but link none of its object code, hence
the templates-only default; `--include-import` compiles chosen modules in
(they must be betterC-codegen-clean). Import paths derive from the
discovered tests' module-name/file-path pairs (no dub metadata reaches the
test binary at runtime) plus a best-effort `dub describe`.

## `@benchmark`: libtest's protocol

`--bench` measures each benchmark with Rust libtest's approach: double the
per-sample iteration count until a sample is long enough to time (5 ms),
collect 32 samples, report median/MAD/min/max ns-per-iteration. `benchIter`
mirrors `Bencher::iter` — the runner calls the test once and the closure
passed to `benchIter` becomes the measured unit, excluding setup — via a
thread-local context, so the same test degrades to a single invocation under
any other runner. `blackBox` is the optimizer barrier (empty asm under LDC,
volatile store elsewhere).

## Inherited limitation

Like silly, discovery sees only `dub_test_root.allModules`, which excludes
`package.d` — tests there run zero and silently "pass". Keep tests in
feature modules.
