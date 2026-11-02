# Design

## The seam: druntime's extended module unit tester

`dub test` generates a `dub_test_root` module whose `allModules` alias lists
the tested package's modules. The harness's `discovery`, instantiated by the shim
in unittest builds, walks that list with `__traits(getUnitTests)` — module level plus
aggregates — and `register` installs a `Runtime.extendedModuleUnitTester`, the
same seam silly used. That `shared static this` is `@standalone`: the
generated `dub_test_root` imports the shim's module back, and
without the attribute druntime rejects the module-constructor cycle.

Builds without dub write the same module themselves: the Android test builder
generates `dub_test_root` from the tested directories
([Run tests on Android](../how-to/run-tests-on-android.md)).

## Two processes: the test binary and the runner

The runner's reports use the `sparkles:ui` toolkit, which depends on
`sparkles:base`, whose own tests need the runner. Linked into a test binary,
the runner closes a dependency cycle for every package below the toolkit. So
it runs out of process, as cargo-nextest does for Rust
([process model](../../../specs/test-runner/process-model.md)):

- **The test binary** holds the tests and everything that must run beside a
  test body: discovery, execution on a budgeted thread, `skipTest`, and the
  benchmark and workload measurement layer. That code is
  `sparkles:test-harness`, with the marker attributes in
  `sparkles:test-attributes`; neither depends on another repository package,
  so every package can depend on them. The shim, `sparkles:test-runner`,
  compiles one module into each test root: the hook that hands the
  discovered tests to the harness.
- **The runner executable**, `sparkles-test-runner`
  (`sparkles:test-runner-impl`), holds the command line, scheduling, the
  reports, `--bench-json`, and the compile-time and extracted modes. It is
  built from the revision `nix/test-runner-pin.json` names, like a bootstrap
  compiler, so editing it changes no test binary.

A binary started by `dub test` finds the runner through
`$SPARKLES_TEST_RUNNER` (or `--runner=PATH`) and starts it on itself. The
runner then starts the binary again as **workers**, `T` of them for `-t T`,
and sends each one test at a time over its standard input. A worker answers
with line frames — `0x1E`, a JSON object, a line feed — on its original
standard output, and the test's own output goes to its standard error, a pipe
the runner reads up to a sentinel the worker writes after each test. So a
test's output is reported with that test, and a test that crashes its worker
fails alone: the runner reports its signal and output and starts a new
worker. Both ends announce the protocol versions they speak before anything
else, and a mismatch stops the run with both ranges named.

With no runner, or with `--no-runner`, the binary runs its tests itself, one
at a time, with one line per test. That is how a test gets debugged:
`gdb --args ./binary --no-runner -i name`.

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

Extracted tests import their module, and the driver compiles that module in
(`-i=<module>`) so its ordinary functions link — without it a test calling
any non-template function of the module it lives in fails at link time, which
made the marker decorative for most real tests. The opt-out is per test
(`@betterC(selfContained: true)`) because self-containment is a property of
the test, not the run: a module that cannot itself compile under `-betterC`
can still host a template-only test, and that is precisely what such a test
asserts. `--include-import` compiles further modules in; everything compiled
in must be betterC-codegen-clean. Import paths derive from the
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
multiplexing — degrade to `—` rather than failing. On macOS the same pass
runs on `proc_pid_rusage`'s free-running fixed counters (per-bracket
snapshot pairs with the bracket's own syscall cost calibrated out — not
ioctl-excluded like Linux); on other platforms it is skipped entirely.

## Worker stacks and the 384 KiB budget

`std.parallelism.TaskPool` uses the OS default pthread stack: ~8 MiB on
Linux, **512 KiB on macOS**. A 1 MiB stack local therefore passes Linux CI
and SIGSEGV/SIGBUS on a Mac worker, and because the old pool let the 8 MiB
main thread steal work, the crash was probabilistic.

The runner no longer uses `TaskPool` for the default suite:

- Workers are `core.thread.Thread`s constructed with a 512 KiB stack on
  every OS.
- A worker runs each test on a fresh thread of its own, so its main thread
  never runs a test body unless `-t 1` or `@serial(mainThread)` asks for it.
- Before each body the unused stack below a 384 KiB watermark is
  `mprotect`'d `PROT_NONE`. A fault there is a named
  `StackBudgetExceeded` failure, not a process abort. Nested
  `executeTest` calls (the runner's own tests) reuse the outer watermark.

`-t 1` runs each test on the worker's main thread, so a developer can debug without the
tight stack; `ci --test` always follows it with a `-t N` (`N ≥ 2`) leg.

Under AddressSanitizer (`LDC_AddressSanitizer`) the watermark is disabled:
ASan owns SIGSEGV for its shadow map, and its redzones inflate every frame,
so the 384 KiB budget is not measurable there anyway. Workers are sized at
4 MiB instead of 512 KiB so a body that fits the budget cannot reach a guard
page and abort the whole binary; the budget itself is only enforced by the
plain `ci --test` legs.

## Live progress: three displays, one policy

The runner has three redraw-in-place displays, all answering to one policy —
`progressEnabled`: an interactive terminal on the target stream and none of
`--no-colors`/`$NO_COLOR`/`TERM=dumb` — and all bracketing repaints in
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
