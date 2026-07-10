# Design

## The seam: druntime's extended module unit tester

`dub test` generates a `dub_test_root` module whose `allModules` alias lists
the tested package's modules. The shim's `discovery` (active only in unittest
builds) walks that list with `__traits(getUnitTests)` — module level plus
aggregates — and `register` installs a `Runtime.extendedModuleUnitTester`, the
same seam silly used. That `shared static this` is `@standalone`: under the
in-tree integration `dub_test_root` imports the shim's modules back, and
without the attribute druntime rejects the module-constructor cycle.

## Two packages: a thin shim and a prebuilt impl

The runner renders through `sparkles.base` (styled templates, `@nogc`
duration writers) and optionally `sparkles.core_cli` (tables, OSC 8 links), and
pulls in `std.regex` (filtering) and `std.parallelism` (the pool). Compiling
all of that into every consumer's test binary — the original source-inclusion
integration — cost ~2.8s on every `dub test`. So the runner is split:

- **`sparkles:test-runner`** — a `sourceLibrary` shim. Only `discovery` and
  `register` compile into each test binary; between them they import just the
  data-only `model`, `attributes`, and `std.traits`/`std.meta`. No `base`,
  `std.regex`, or `std.parallelism`.
- **`sparkles:test-runner-impl`** — a prebuilt `library` holding the CLI
  dispatch (`runner_impl`), `execution`, `reporting`, the `--better-c`/`--wasm`
  drivers, and benchmarking. Built once, linked by everyone.

The seam between them is one `extern(C)` function:

```d
extern (C) void sparkles_test_runner_run(
    Test* tests, size_t count, bool hostIsRunner, uint* executed, uint* passed);
```

`register` discovers the tests, then _calls_ this — a direct call forces the
linker to pull in the impl (so its `shared static this` runs) while the local
`extern(C)` prototype means the consumer never _imports_, and so never parses,
the heavy modules. That parse-avoidance is what drops a consumer's `dub test`
to ~0.8s, near a vanilla build. The library is built with `-allinst` so every
template instance it references (notably `std.uni`, via base's grapheme-aware
width) is emitted on its side of the link.

Most consumers — external and in-tree — just `dependency "sparkles:test-runner"`.
The exception is the impl's own dependency closure: `base`, `core-cli`, and
`test-utils` (dub's cycle detection unions across configs, and
impl → `core-cli` → `test-utils`) cannot depend on it, so they source-include
both packages:

```sdl
importPaths "src" "../test-runner/src" "../test-runner-impl/src"

configuration "unittest" {
    sourcePaths "../test-runner/src" "../test-runner-impl/src"
}
```

Three consequences are handled explicitly:

- `core-cli` can never be in `base`'s test build, so all `core_cli` use is
  gated with `__traits(compiles, import …)` and degrades gracefully
  (space-aligned tables, plain `file:line`). This is ordinary Design by
  Introspection, applied to the build graph.
- The shim's modules land in every host's `allModules`, so its own tests are
  discoverable everywhere. They are hidden unless `--self-test` is given or the
  tested package _is_ the runner — decided from `allModules` module names plus
  the test-binary name, because a host whose only D modules are
  `package.d`s/ImportC shims (e.g. `ghostty`) has an `allModules` that looks
  identical to the runner's own.
- The runner tests itself in two suites: `dub test :test-runner-impl`
  self-hosts (its `unittest` config source-includes the shim) to exercise the
  heavy modules, and `dub test :test-runner` runs the shim's own discovery
  tests through the linked impl.

## `@ctfe`: a probe compile as the executor

`@ctfe` tests are not run in the test binary. After `-i`/`-e` filtering, the
impl generates a probe program that imports the selected tests' modules, picks
them out by reflection, and forces each through CTFE with
`static assert(ctfePasses!test)` — where `ctfePasses` is an immediately-invoked
CTFE lambda calling the test. It compiles the probe with `$DC -o- -unittest`:
semantic analysis only, so CTFE runs but nothing is codegen'd or linked.
Compilation _is_ the test run — a failure is a compile error with the CTFE call
stack, naming the test. Doing this at run time rather than during the test
build is what lets `-i`/`-e` decide which tests evaluate while `--help`/`--list`
evaluate none, so a failing `@ctfe` test can never break the build. With
`--ctfe-trace` the probe adds LDC's `-ftime-trace`; each forced evaluation is a
`Ctfe: call __unittest_LN_CM` event carrying the test's `file:line`, so
compile-time cost is attributed per test (the 100+ MB trace is scanned linearly
instead of parsed as JSON).

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

`benchCase` extends this to a **matrix**: one `@benchmark` body calls it per
(engine, dataset, …) and each call becomes its own row, so the combinatorics
stay in plain-D loops rather than in the runner. It times each call individually
— the price of letting an untimed `after` release the timed body's result
before the next iteration — and a failing `after` (a `throw`, trace printed,
or an `Expected` error, silent) isolates into a single error row while the
rest of the matrix continues; the run still reports failure.
`Metric` columns report throughput as `amount ÷ time`, with a vocabulary (a
named `Unit`; rate = quantity ÷ time) aligned to the forthcoming
`sparkles:quantities` library.

`--perf` adds a **second pass** dedicated to hardware counters: a
`perf_event_open` group (pure D over `core.sys.linux.perf_event` — no ImportC)
brackets only the timed body with `ENABLE`/`DISABLE` ioctls, so the
per-iteration syscalls never pollute the wall-clock medians. Unavailable
counters — a paranoid kernel, or the last-level-cache pair dropped to avoid PMU
multiplexing — degrade to `—` rather than failing, and off Linux the pass is
skipped entirely.

## Live progress: three displays, one policy

The runner has three redraw-in-place displays, all answering to one policy —
`progressEnabled`: an interactive terminal on the target stream and none of
`--no-colours`/`$NO_COLOR`/`TERM=dumb` — and all bracketing repaints in
DEC-2026 synchronized output, so a repaint lands as one flicker-free frame.

- The **default parallel run** polls a `ProgressLine` beneath the streaming
  result lines through `core-cli`'s `LiveRegion` (stdout, gated
  `hasCoreCliLive`).
- **`--bench` on an interactive stdout** ticks the current group's whole
  results table in a `LiveRegion`: rows land as cases complete, a pseudo
  error row carries the in-flight case (error rows sort last, pinning it to
  the bottom; `\x01`-marked and rewritten into the dim spinner row), and the
  final frame graduates via `finish(keepFrame)`. Frames render only at case
  boundaries — deliberately no painter thread, because concurrent GC
  allocation and terminal writes would perturb the very numbers being
  measured. Geometry is pinned before the first frame (roster-name floors +
  the run's carried `TableGeometry`), so frames never resize.
- **`--bench` with stdout redirected** falls back to the one-line stderr
  spinner — `--bench > file` keeps results clean while progress stays on the
  terminal — through a raw-fd writer, because that tick seam is
  `@safe nothrow @nogc`.

The layering follows the build-graph gates above: what must always work comes
from `base` (`CtlSeq` control sequences, `truncateField` cell-safe
truncation), while `ProgressLine`, `LiveRegion`, `drawTableLines`, and the
`terminalSize`/`isTerminal` queries are `core-cli` and degrade to no display
at all.

## Inherited limitation

Like silly, discovery sees only `dub_test_root.allModules`, which excludes
`package.d` — tests there run zero and silently "pass". Keep tests in
feature modules.
