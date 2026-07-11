# The sparkles test runner: the baseline

Today's [`sparkles:test-runner`][design-doc] as it meets a sanitizer, described
as **observed behavior** with its current limits. This page is the _system under
audit_: the [comparison][comparison] page's delta table maps each capability the
survey found onto where the runner stands, and the
[integration proposal][proposal] is the plan that closes the gaps. The runner
has **no sanitizer support today** — no `--sanitize`, no `--valgrind`, no
capability seam — so this page is mostly a map of the seams a design must join
and the one behavior (a mid-run crash) that a design must fix.

**Last reviewed:** July 11, 2026

> [!IMPORTANT]
> Per the survey's ground rules, this page records what the code _does_, not
> what it was assumed to do — the sparkles source is **not** a source of truth
> for any other page in this tree. Where the survey's findings and this runner's
> behavior diverge (the recon note "no signal handling anywhere" is refined
> below), the divergence is recorded here and in the [delta table][comparison],
> never silently reconciled. `file:line` locators are to the tree at the survey
> date (branch `research/sanitizers`, `379e4c7a`).

| Field           | Value                                                                                                                                                                                                                                                           |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shim modules    | [`register.d`][src-register] · [`discovery.d`][src-discovery] (`sourceLibrary`, compiled into each test binary)                                                                                                                                                 |
| Impl modules    | [`runner_impl.d`][src-runner] · [`execution.d`][src-execution] · [`extract.d`][src-extract] · [`driver.d`][src-driver] · [`model.d`][src-model] · [`attributes.d`][src-attributes] · [`skip.d`][src-skip] · [`reporting.d`][src-reporting] (prebuilt `library`) |
| Seam            | one `extern(C)` function, [`sparkles_test_runner_run`][src-register]                                                                                                                                                                                            |
| Execution model | in-process [`std.parallelism.TaskPool`][taskpool]; the caller thread participates; tests share the runner's address space                                                                                                                                       |
| Failure model   | `Throwable`-only catch ([`executeTest`][src-execution]); **no signal handling in the runner**; a crash takes the whole process down                                                                                                                             |
| Sanitizer today | none — no mode, no [capability seam][c-weak-hook], no [external-finding field][src-model], no [suppression][c-suppression] management                                                                                                                           |
| User docs       | [`test-runner`][design-doc] explanation + [`--bench` how-to][bench-howto]                                                                                                                                                                                       |
| Verification    | private-clone experiments, x86_64-linux (Ryzen 9 7940HX, kernel 6.18.26), LDC 1.41.0 / DMD 2.112.1 / dub 1.42.0-beta.1                                                                                                                                          |

---

## Overview

The runner is two dub packages joined by one `extern(C)` call. A **shim**
(`sparkles:test-runner`, a `sourceLibrary`) compiles into each consumer's test
binary; it does compile-time unittest [discovery][src-discovery] and registers a
druntime hook. A **prebuilt implementation library**
(`sparkles:test-runner-impl`, an ordinary static `library`) holds the CLI,
execution, reporting, and the extract-and-recompile drivers. The shim calls the
library across a single `extern(C)` prototype it declares locally, so a
consumer's `dub test` never _parses_ the heavy modules and stays close to a
vanilla build. The [design doc][design-doc] states it verbatim:

> The seam between them is one `extern(C)` function: … `register` discovers the
> tests, then _calls_ this — a direct call forces the linker to pull in the impl
> (so its `shared static this` runs) while the local `extern(C)` prototype means
> the consumer never _imports_, and so never parses, the heavy modules.

Two properties of this shape decide the whole sanitizer design space. First,
**tests run in-process, in the runner's own address space, on a thread pool** —
so a sanitizer's process-global runtime (its shadow, interceptors, allocator,
exit protocol) is shared by the runner and every test at once, and any
[report-windowing][c-report-windowing] must happen _inside_ that one process.
Second, **the runner catches `Throwable` and nothing else** — it has no signal
handler, no subprocess isolation, no [process-per-test][c-process-isolation]
path — so a hard crash (a `SIGSEGV`, an `abort()`, a default-fatal sanitizer
report) is not a failed test but a dead run. The crash experiment below is the
single most load-bearing observation on this page.

---

## How the runner works today

### The two-package model and the `extern(C)` seam

The shim declares the entry point without importing any impl module
([`register.d:36-37`][src-register]):

```d
/// The prebuilt implementation library's entry point. Declared here as an
/// `extern(C)` prototype so the shim links against it without importing (and
/// thus parsing) the library's heavy modules.
extern (C) void sparkles_test_runner_run(
    Test* tests, size_t count, bool hostIsRunner, uint* executed, uint* passed);
```

It installs the druntime hook in a `@standalone` module constructor
([`register.d:41-52`][src-register]) — the only runner code that runs with
`-unittest`, guarded by a top-level `version (unittest):` ([`register.d:13`][src-register]):

```d
@standalone
shared static this() @system
{
    Runtime.extendedModuleUnitTester = &runnerHook;
}
```

The impl side ([`runner_impl.d:40-46`][src-runner]) unpacks the pointer/count
into `runnerMain`. That `version (unittest):` guard is why the
[`DFLAGS` false green](#the-dub-build-path) is silent: strip `-unittest` and the
shim compiles to an empty module, the hook never registers, and druntime reports
success with zero tests.

### In-process parallel execution

Default mode runs the runnable tests on a `std.parallelism.TaskPool`. Two paths
exist — an interactive live-region painter, and this plain one
([`runner_impl.d:562-579`][src-runner]):

```d
    if (!ranLive) with (new TaskPool(threads - 1))
    {
        foreach (test; parallel(runnable))
        {
            const result = executeTest(test);

            auto output = formatResultLine(result, colored, options.verbose, width) ~ "\n";
            foreach (thrown; result.thrown)
                output ~= formatThrown(thrown, colored, options.verbose);
            stdout.lockingTextWriter.put(output);
            …
        }
        finish(true);
    }
```

`TaskPool(threads - 1)` plus `parallel` means the calling thread also executes
work items, so effective parallelism equals `threads` (default `totalCPUs`).
Benchmarks are the exception — they run serially in the main thread. The runner's
own machinery — the pool, the `atomicOp` counters, the per-result GC string
concatenation, `stdout.lockingTextWriter` — is exactly the "druntime internals"
activity a data-race detector sees around every test (the runner itself
contributed zero TSan reports on a 167-test suite; see [tsan.md][tsan-runner]).

### What a failure is: `Throwable` only, no signal handling

[`executeTest`][src-execution] is the entire fault model. Its documentation is
worth quoting because it is the crash-model evidence
([`execution.d:9-43`][src-execution]):

```d
/// Runs one test, capturing anything it throws.
///
/// Almost everything a test throws — `Exception`s, `AssertError`s, and other
/// `Error`s such as `RangeError` (whose semantics are well-defined in D) — is
/// recorded (with its full chain and stack traces) as a failure, so one broken
/// test never aborts the rest of the parallel run. `TestSkipped` (from
/// `skipTest`) records the test as skipped, not failed. Only
/// `OutOfMemoryError` indicates a genuinely broken process state and is
/// re-thrown.
TestResult executeTest(Test test)
{
    …
    try { … test.ptr(); result.succeeded = true; }
    catch (TestSkipped s) { result.skipped = true; … }
    catch (Throwable t) { result.thrown = toThrown(t); } // re-throws OutOfMemoryError
    return result;
}
```

A `catch (Throwable)` isolates one _throwing_ test from the rest. It does
nothing for a fault that is not a `Throwable`: a `SIGSEGV`, a `SIGABRT` from
`abort()`, or a default-fatal sanitizer report all bypass the `try`. Grepping
both packages for `signal`, `SIGSEGV`, `sigaction`, `fork(`, or
`registerMemoryErrorHandler` finds nothing — there is **no signal handler and no
subprocess isolation in the runner**. The
[crash experiment](#what-a-crash-looks-like-today) refines the recon's blunt "no
signal handling anywhere": _druntime_ installs a `unittestSegvHandler`, but it
only prints a trace before the process dies, so the runner-facing consequence is
unchanged — a crash kills the run.

### Mode dispatch and the conflicting-modes hard-error

The runner already owns a small mode dispatcher, and a `--sanitize`/`--valgrind`
mode would join it. Modes are **mutually exclusive by a hard error**
([`runner_impl.d:280-291`][src-runner]) — the precedent a new mode must respect:

```d
    // The run modes are mutually exclusive; silently preferring one (the old
    // behavior) turned e.g. `--ctfe-trace f --bench` into a false green — the
    // requested trace was never written, yet the run exited 0. …
    const requestedModes = (options.bench ? 1 : 0)
        + (options.ctfeTrace.length ? 1 : 0)
        + (options.betterC || options.wasm ? 1 : 0);
    if (requestedModes > 1)
    {
        stderr.writeln("error: pick one mode — --bench, --ctfe-trace, or --better-c/--wasm");
        return UnitTestResult(1, 0, false, false);
    }
```

Routing then dispatches `--list`, `--bench`/`--list-metrics`, `--ctfe-trace`,
`--better-c`/`--wasm`, or the default mode ([`runner_impl.d:328-340`][src-runner]).
Two of those modes already re-drive an external compiler, which is the recompile
precedent.

### Extract-and-recompile: the recompile-mode precedent

The `--better-c` and `--wasm` modes [extract][src-extract] each annotated
unittest's body — sliced textually out of its source file, located via
`__traits(getLocation)` — into a generated program with a hand-rolled `main`,
then [compile and run it][src-driver] through a detected compiler
(`--compiler` → `$DC` → `ldc2`/`dmd`; a missing compiler becomes a
[`skipTest`][src-skip], not an error). This is 90% of a
[process-per-test][c-process-isolation] mode — process orchestration, exit-status
parsing, skip-on-missing-toolchain — but the extraction half has hard limits an
`--isolate` mode must design around ([`extract.d:5-17`][src-extract]):

- Extracted bodies `import` their module, so they see only its **public**
  symbols; a test that touches a `private`/`package` helper fails to compile.
- Without linking the module, only **template / CTFE-able** symbols are usable;
  a plain function call needs `--include-import=<pattern>`.
- Bodies are re-lexed textually; `__MODULE__`-sensitive code, mixins, or UDAs on
  locals referencing module-private symbols change meaning in the generated
  module.

The contrast is the `@ctfe` probe path, which does **no extraction**: it
`static import`s the home modules and forces evaluation under `-o- -unittest`, so
private symbols keep working. A `--sanitize` recompile mode more plausibly
follows the `@ctfe` philosophy — re-drive the whole `dub` build rather than slice
bodies — which is why the [proposal][proposal]'s M1 rebuilds via a dub buildType,
not extraction.

### Marker UDAs and `skipTest`: the `@sanitize` precedent

The special modes are gated by plain-struct marker UDAs in
[`attributes.d`][src-attributes] (`@betterC`, `@ctfe`, `@wasm`, `@benchmark`),
discovered with `hasUDA` and reflected into a `TestTraits` bool. Adding a
`@sanitize`/`@noSanitize` marker is a four-line change: a struct in
`attributes.d`, one `hasUDA` line in `testTraits`, one `TestTraits` field, one
filter in the dispatcher. LDC already honors a druntime `@noSanitize("<name>")`
UDA at the compiler level (see [d-toolchain.md][dtool-druntime]), so a per-test
opt-out has prior art on both sides.

Capability degradation has an equally exact precedent. [`skipTest`][src-skip]
throws a recycled (`@nogc`) `TestSkipped : Error` that the runner records as
skipped — neither passed nor failed — rendering a yellow `⊘` line plus an
`N skipped` summary segment:

```d
noreturn skipTest(string reason) @safe pure nothrow @nogc
{
    throw (() @trusted => recycledErrorInstance!TestSkipped(reason))();
}
```

This is exactly the shape a "sanitizer unavailable on this toolchain" gate needs
— "DMD has no `-fsanitize`; use `--valgrind`" degrades to a skip, not a red run.

### The data model and reporting seams: no place for a finding

[`TestResult`][src-model] is the whole per-test model
([`model.d:85-93`][src-model]):

```d
struct TestResult
{
    Test test;
    bool succeeded;
    bool skipped; /// the body called `skipTest` — neither passed nor failed
    string skipReason;
    Duration duration;
    immutable(Thrown)[] thrown;
}
```

**A sanitizer finding has no field to land in.** A per-test report either becomes
a synthetic `Thrown` or needs a new field — the model seam the [proposal][proposal]
targets in M2. Rendering, on the other hand, is ready: `formatThrown` already
emits an indented multi-line block (`type thrown from file:line`, message
continuation, `--- stack trace ---`), which is where a captured report would
render; the summary line ([`reporting.d`][src-reporting]) already grows optional
`, N skipped` / `, N compile-time` segments "only when non-zero, so existing
pinned outputs stay byte-identical" — the same discipline a `, N sanitizer
findings` segment would follow. The reporting layer also demonstrates the
capability-advertisement idiom a `SanitizerCapabilityReport` copies:
`private enum bool hasCoreCliUi = __traits(compiles, { import …; });`.

### The dub build path

Every unittest configuration in the monorepo carries the same flags (copied from
[`libs/versions/dub.sdl`][versions-dub]):

```sdl
configuration "unittest" {
    dependency "sparkles:test-runner" path="../.."
    …
    dflags "-checkaction=context" "-allinst"
    dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
    dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
    lflags "--export-dynamic" platform="linux-ldc"
}
```

Four of these interact with a sanitizer design directly:

- **`lflags "--export-dynamic"` (linux-ldc)** exports the executable's dynamic
  symbols. It is what makes the [weak-hook control surface][c-weak-hook] reachable
  from D — a program-defined `__tsan_on_finalize` / `__tsan_on_report` /
  `__asan_default_options` fires only if the binary exports it, and the runner's
  configs already pass it. The proposal's in-process attribution (M2) leans on
  this pre-existing, load-bearing coincidence (see [tsan.md][tsan-control]).
- **`--link-defaultlib-shared` + `--linker=gold` (linux-ldc)** link a shared
  druntime/Phobos; sanitizer runtimes coexist with this — a test binary happily
  links `libphobos2-ldc-shared.so` _and_ `libasan.so`/`libtsan.so`
  (see [d-toolchain.md][dtool-dub]).
- **`-defaultlib=libphobos2.so` (linux-dmd)** links a _shared_ Phobos whose
  dynamic symbol table omits the `_d_valgrind_*` exports, so the
  [`etc.valgrind` deep-fidelity path][val-druntime] fails to link in the current
  linux-dmd unittest config — a caveat the [proposal][proposal]'s M3 carries.
- **`-checkaction=context` + `-allinst`** coexist with `-fsanitize=` on every
  compile line (see [d-toolchain.md][dtool-dub]).

Three dub facts govern how a `--sanitize` mode injects flags (this page owns the
_runner-facing_ consequences; [d-toolchain.md][dtool-dub] owns the dub mechanics):

1. **`DFLAGS=… dub test` is a silent false green.** With `DFLAGS` set and no
   `-b`, dub selects the magic `$DFLAGS` build type, which contributes no options
   — dropping `-unittest`. The [`version (unittest):`][src-register] shim then
   compiles empty, zero tests run, and druntime prints "All unit tests have been
   run successfully" at exit 0. The historical event-horizon recipe
   `DFLAGS="-fsanitize=… -allinst" dub test` therefore validates nothing on
   today's dub. The proposal's M1 uses a **custom buildType** instead.
2. **A buildType propagates to the whole closure.** A
   `buildType "asan" { buildOptions "unittests" … dflags "-fsanitize=address" }`
   reaches every dependency package, applies `-unittest` to the root config only,
   and keys the dub cache on the buildType name (no `--force`). This is the clean
   whole-closure instrumentation channel.
3. **PR #3111 (dub ≥ 1.42.0-beta.1) makes `-fsanitize=` ABI-critical.** A
   `-fsanitize=` flag in any package's `dflags` now propagates both up and down
   the dependency graph, so **mixed instrumentation cannot arise through dub
   channels** on this toolchain — the prebuilt `test-runner-impl.a` is
   instrumented consistently with the consumer. On older dub, only the upward
   direction exists, leaving the prebuilt impl a silent coverage gap.

Finally, **dub launders the sanitizer exit code.** A test binary that TSan exits
`66`, or that a recovered ASan run exits nonzero, is reported by dub as
`Error Program exited with code 66` and dub itself exits `2` — a CI consumer of
`dub test`'s exit code cannot distinguish "tests failed" from "sanitizer
reported". Running the built binary directly preserves the tool's exit code
(the proposal has the runner own its own exit protocol). No surveyed ecosystem
launders exit codes this way ([runner-integrations.md][runner-integrations]).

---

## What a crash looks like today

The one experiment the survey required: a mid-run crash, reproduced in a private
clone with a throwaway package (four passing tests, a null-dereference test, a
data-race test, and a `malloc` heap-buffer-overflow test), driven three ways.
The results are the raw material for the proposal's M2/M4.

| Leg | Build                                | What the runner does today                                                                                                                                     | Exit             |
| --- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| E1  | plain, passing tests                 | prints each `✓`, then `Summary: 4 passed, 0 failed`                                                                                                            | 0                |
| E2  | plain, **null-deref (SIGSEGV)**      | druntime's `unittestSegvHandler` prints a raw module+offset backtrace to **stderr**; the process still dies; **no summary**; buffered `✓` lines lost           | 139 (dub: `-11`) |
| E3  | ASan buildType, heap-buffer-overflow | ASan self-symbolizes the report to the exact test line and the runner call chain, then **halts** ([halt default][c-halt-recover]); **no summary**              | 1 (dub: `2`)     |
| E4  | TSan buildType, data race, `-t 1`    | TSan reports the race to stderr; the run **completes**, `Summary: 5 passed` prints — the racy test is even marked `✓` (the finding never reaches `TestResult`) | 66 (dub: `2`)    |

The **plain SIGSEGV (E2)** is the gap. `core.runtime.runModuleUnitTests`
installs a `unittestSegvHandler` that catches the fault and prints an
_unsymbolized_ backtrace (module + hex offset) whose faulting frame is
`crashtest.demo.__unittest_L39` — the null-deref test — but the process then dies
by signal 11 anyway. The crashing test cancels **every sibling that had not yet
run**, the `Summary` line never prints, and — because the runner writes results
through `stdout.lockingTextWriter` while stdout is _block-buffered_ whenever it
is not a TTY (a pipe, a redirect, a CI log) — the buffered `✓` lines and the
summary are **lost with the unflushed buffer**; only the stderr backtrace
survives. Line-buffering stdout (`stdbuf -oL`) recovers the `✓` lines that
completed before the crash, but never the summary. dub relays the death as
`Error Program exited with code -11` (raw `139` = `128 + SIGSEGV`).

**ASan (E3)** and **TSan (E4)** bracket the two halt policies the proposal must
own. ASan halts on its first report — self-symbolized (GCC's runtime uses
`libbacktrace`) down to `demo.d:67` → [`executeTest`][src-execution]
(`execution.d:29`) → `runDefaultMode` (`runner_impl.d:566`) → the TaskPool worker
— so attribution is _visible in the report_, but the run still dies and there is
no runner-level `✗`. TSan is [report-and-continue][c-halt-recover]: the run
completes, the summary prints, and the race is caught (`demo.d:52`) — but it is
**invisible to the runner**, which marks the racy test `✓` because the finding
went to stderr out-of-band and nothing threw. (Even at runner `-t 1`, one
druntime `rt.monitor_` noise race appears alongside the real one — the lazy
`Object`-monitor init class; see [tsan.md][tsan-druntime].) These three legs are
the exact demonstration that the runner today has **no per-test attribution, no
crash isolation, and no finding channel** — which is what the audit checks.

---

## The historical event-horizon seed, and its invalidated recipe

The repo's own history records the known-good seed: on branch
`feat/event-horizon` (not on this branch), commit `c9537f96` caught a real fiber
stack-use-after-return with `-fsanitize=address` ("the big one,
AddressSanitizer-verified — storing scope delegates for deferred fiber start is
stack-use-after-return"), and `5284b217` added a TSan suppression file after
stress-running a lock-free deque. That work is genuine prior art (reproduced
standalone in [asan.md][asan] and [tsan.md][tsan-druntime]), with two honest
corrections: the recorded working recipe
`DFLAGS="-fsanitize=thread -allinst" dub test --force` is, on today's dub, the
**silent false green** above (no `-unittest`, zero tests), and its `--force` was
superfluous (dub already keys the cache on dflags). The survey therefore does not
recommend the `DFLAGS` channel it seeded from.

## What CI runs today

CI runs no sanitizers. The `ci.yml` matrix exercises the `DC` dimension
(`ldc2` / `dmd` on linux, `ldc2` on macOS) through the `ci` helper, which honors
`$DC` by appending `--compiler=$DC` to each `dub test :pkg`. There is no
sanitizer job, no suppression file in-tree on this branch, and no
`--fair-sched`/`-t 1` policy for a tool that needs one — everything the proposal's
M5 adds.

---

## What the audit will check

The observed gaps, which feed [comparison.md][comparison]'s delta table:

1. **No sanitizer mode at all.** No `--sanitize=<kind>`, no `--valgrind`; the
   only flag-injection channel a user has today (`DFLAGS`) is a false green, and
   the buildType channel is undocumented for this use. The field's baseline —
   Swift's `swift test --sanitize=`, Go's `go test -race` — is a first-class flag
   ([runner-integrations.md][runner-integrations]).
2. **No per-test attribution.** A finding lands on stderr, unattributed and, for
   the report-and-continue tools, invisible to `TestResult` (E4). Every surveyed
   ecosystem solves this with one of three designs
   ([report-windowing][c-report-windowing],
   [process-per-test][c-process-isolation], or
   [wrapper-and-parse][c-wrapper-parse]); the runner implements none.
3. **No crash isolation.** A SIGSEGV-class finding kills the whole run and loses
   the summary (E2). The extract-and-recompile machinery is most of the
   process-isolation fix.
4. **No capability seam.** Nothing advertises "this toolchain can/can't do
   `-fsanitize=thread`", so there is no honest degradation path (DMD, missing
   runtime, unavailable MSan world) — only the raw dub/link failure.
5. **No suppression management.** No shipped druntime suppression file, no
   user-suppression composition, and no `--fair-sched`/`-t 1` policy — although
   the survey found the noise is tiny and precisely suppressible
   ([asan.md][asan-leaknoise], [tsan.md][tsan-druntime], [valgrind.md][val-runner]).
6. **No finding channel or exit protocol.** `TestResult` has no finding field
   ([`model.d`][src-model]), and dub launders the sanitizer exit code to `2`.

---

## Sources

- Observed sources (this repo, at `379e4c7a`): [`register.d`][src-register],
  [`discovery.d`][src-discovery], [`runner_impl.d`][src-runner],
  [`execution.d`][src-execution], [`extract.d`][src-extract],
  [`driver.d`][src-driver], [`model.d`][src-model],
  [`attributes.d`][src-attributes], [`skip.d`][src-skip],
  [`reporting.d`][src-reporting]; [`libs/versions/dub.sdl`][versions-dub];
  [design doc][design-doc].
- Experiments: recorded in the survey's synthesis grounding ledger (E1–E4), run
  in a private clone; the dub-plumbing facts are cross-checked against
  [d-toolchain.md][dtool-dub] and [tsan.md][tsan-runner].
- The survey pages this baseline is audited against: [comparison][comparison],
  [asan][asan], [tsan][tsan], [d-toolchain][d-toolchain], [valgrind][valgrind],
  [runner-integrations][runner-integrations].

<!-- References -->

[src-register]: ../../../libs/test-runner/src/sparkles/test_runner/register.d
[src-discovery]: ../../../libs/test-runner/src/sparkles/test_runner/discovery.d
[src-runner]: ../../../libs/test-runner-impl/src/sparkles/test_runner/runner_impl.d
[src-execution]: ../../../libs/test-runner-impl/src/sparkles/test_runner/execution.d
[src-extract]: ../../../libs/test-runner-impl/src/sparkles/test_runner/extract.d
[src-driver]: ../../../libs/test-runner-impl/src/sparkles/test_runner/driver.d
[src-model]: ../../../libs/test-runner-impl/src/sparkles/test_runner/model.d
[src-attributes]: ../../../libs/test-runner-impl/src/sparkles/test_runner/attributes.d
[src-skip]: ../../../libs/test-runner-impl/src/sparkles/test_runner/skip.d
[src-reporting]: ../../../libs/test-runner-impl/src/sparkles/test_runner/reporting.d
[versions-dub]: ../../../libs/versions/dub.sdl
[design-doc]: ../../libs/test-runner/explanation/design.md
[bench-howto]: ../../libs/test-runner/how-to/benchmark.md
[taskpool]: https://dlang.org/phobos/std_parallelism.html#.TaskPool
[asan]: ./asan.md
[tsan]: ./tsan.md
[d-toolchain]: ./d-toolchain.md
[valgrind]: ./valgrind.md
[runner-integrations]: ./runner-integrations.md
[comparison]: ./comparison.md
[proposal]: ./integration-proposal.md
[tsan-runner]: ./tsan.md#test-runner-integration-semantics
[tsan-druntime]: ./tsan.md#d-and-druntime-interaction
[tsan-control]: ./tsan.md#runtime-control-and-report-capture
[asan-leaknoise]: ./asan.md#the-druntime-leak-noise-policy
[dtool-dub]: ./d-toolchain.md#test-runner-integration-semantics
[dtool-druntime]: ./d-toolchain.md#d-and-druntime-interaction
[val-runner]: ./valgrind.md#runner-integration-semantics
[val-druntime]: ./valgrind.md#the-d-and-druntime-interaction
[c-weak-hook]: ./concepts.md#weak-hook-control-surface
[c-report-windowing]: ./concepts.md#report-windowing
[c-process-isolation]: ./concepts.md#process-per-test-isolation
[c-wrapper-parse]: ./concepts.md#wrapper-and-parse
[c-halt-recover]: ./concepts.md#halt-vs-recover
[c-suppression]: ./concepts.md#suppression
