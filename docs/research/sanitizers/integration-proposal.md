# Sanitizers in the sparkles test runner: integration proposal

A milestoned plan for `--sanitize=<kind>`, `--valgrind`, and `--isolate` modes on
[`sparkles:test-runner`][design-doc], sketched in D against the runner's real
seams — the [`extern(C)` run entry][baseline-seam], the `extract`/`driver`
recompile machinery, [`TestResult`][baseline-model], the [`attributes`][baseline-attrs]
marker UDAs, and [`skipTest`][baseline-skip]. Each mode **advertises what this
toolchain and OS can actually do** and degrades honestly to a skip; the runner
reports _"sanitizer unavailable, here is why"_ rather than a raw link failure.
Every milestone cross-links the prior art it borrows and the survey evidence
behind it.

**Last reviewed:** July 11, 2026

> [!NOTE]
> The D below is **sketch**, not compiled code — it uses the runner's real types
> and names ([`Test`][baseline-model], `TestResult`, `RunnerOptions`, `skipTest`,
> the `sparkles_test_runner_run` seam) to stay compile-plausible and to show
> exactly where each change lands, but it is illustrative. Hardware-verified
> claims carry `[hw-verified: x86_64-linux]`; the tool exit-code and halt
> semantics are the [concepts halt-vs-recover table][c-halt-recover].

| Field            | Value                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------ |
| Target           | [`sparkles:test-runner`][design-doc] — a new `--sanitize` / `--valgrind` / `--isolate` mode                  |
| Composition seam | a `SanitizerCapabilityReport`, a new [`TestResult.findings`][baseline-model] field, the `extern(C)` run seam |
| Baseline audited | [sparkles-baseline.md][baseline] ([gap analysis][baseline-gaps])                                             |
| Evidence base    | [comparison.md][comparison] matrix + the tool deep-dives + the 11 CI [example probes][examples]              |
| Shape            | capability seam → M1 recompile → M2 attribution → M3 valgrind → M4 isolation → M5 CI → M6 darwin → M7 later  |

---

## 1. Abstract and problem statement

The [baseline][baseline] is an in-process `TaskPool` runner that catches
`Throwable` and nothing else: it has no sanitizer mode, no per-test finding
channel, and — the load-bearing gap — **a SIGSEGV-class finding kills the whole
run and loses the summary** ([baseline crash experiment][baseline-crash]). The
survey found three things that shape the fix:

- **The seams the runner needs already exist.** The unittest configs pass
  [`lflags "--export-dynamic"`][baseline-dub], which is exactly what makes the
  [weak-hook control surface][c-weak-hook] (`__tsan_on_report`,
  `__tsan_on_finalize`, `__asan_set_error_report_callback`) reachable from D — the
  Go/googletest [in-process windowing][c-report-windowing] pattern was reproduced
  from D on this box ([tsan.md][tsan-control], [asan.md][asan-control]). The
  `extract`/`driver` modes are 90% of a [process-per-test][c-process-isolation]
  path.
- **The tools disagree irreconcilably, so the runner must own policy.** ASan
  [halts][c-halt-recover] on the first finding and a recovered run exits `0`
  (count reports, don't read exit codes); TSan reports-and-continues and exits
  `66` at finalize; Valgrind collects everything in one pass. No "nonzero exit =
  failed test" assumption survives contact with the matrix.
- **Toolchains differ, and the differences must be advertised, not assumed.**
  LDC accepts `address|fuzzer|leak|memory|thread` (no UBSan); DMD has no
  `-fsanitize` at all (Valgrind is its only path); MSan needs an
  [instrumented world][c-instrumented-world] sparkles does not build; UBSan is
  [unreachable on every D compiler][ubsan] ([d-toolchain.md][d-toolchain]).

The conclusion the proposal operationalizes: **the runner owns a small,
capability-typed sanitizer layer** — one that probes what the detected toolchain
can deliver, implements each mode at whatever depth the toolchain permits, routes
findings into `TestResult`, and names every absence. It is a new _mode_ beside
`--bench`/`--better-c`/`--wasm`, joining the same
[mutually-exclusive dispatcher][baseline-modes].

Non-goals: instrumenting druntime/Phobos (the permanent uninstrumented layer for
ASan/TSan; a hard blocker for MSan); a general leak-tracking UI; kernel or driver
work.

---

## 2. Capability seam first: `SanitizerCapabilityReport`

**Goal:** make "what can this host sanitize?" a first-class, reportable value,
probed at runtime against the _detected recompile compiler_ — never a
compile-time assumption about the impl library's own compiler.

Mirroring the cpu-pmu backend's [`CapabilityReport`][cpu-capreport] pattern: one
entry per sanitizer kind, each carrying either an advertised policy or a reason
for absence.

```d
// (sketch) libs/test-runner-impl/src/sparkles/test_runner/sanitize.d
enum SanitizerKind { address, leak, thread, memory, valgrindMemcheck, valgrindHelgrind }

/// Runner policy the survey pinned per kind (see M2/M3).
struct SanitizerPolicy
{
    bool haltOnFinding;   /// ASan default true; TSan/valgrind false
    bool countNotExit;    /// recovered ASan exits 0 → count reports, not exit code
    uint defaultThreads;  /// 0 = auto; 1 for thread tools (livelock / noise policy)
}

/// What the *detected* compiler + this OS can actually deliver, this run.
struct SanitizerCapabilityReport
{
    SanitizerKind[] available;
    SanitizerPolicy[SanitizerKind] policy;
    /// Why each absent kind is absent — rendered by --list-sanitizers and the
    /// mode header, verbatim, e.g. "DMD has no -fsanitize; use --valgrind".
    string[SanitizerKind] unavailableBecause;
}
```

Population is a runtime probe using the runner's existing
[`detectCompiler`][baseline-driver] + `run()` seam plus `dlsym` — the same
`version (LDC_AddressSanitizer)` + `dlsym` gate the [example probes][examples]
already use:

```d
// (sketch)
SanitizerCapabilityReport probeSanitizers(string compiler)
{
    SanitizerCapabilityReport r;
    const isLdc = compiler.canFind("ldc"), isDmd = compiler.canFind("dmd");

    if (isDmd)
    {
        foreach (k; [SanitizerKind.address, SanitizerKind.leak, SanitizerKind.thread, SanitizerKind.memory])
            r.unavailableBecause[k] = "DMD has no -fsanitize; use --valgrind";
    }
    else if (isLdc)
    {
        // LDC accepts address|fuzzer|leak|memory|thread — never `undefined`.
        r.available ~= [SanitizerKind.address, SanitizerKind.leak, SanitizerKind.thread];
        r.policy[SanitizerKind.address] = SanitizerPolicy(haltOnFinding: true,  countNotExit: true,  defaultThreads: 0);
        r.policy[SanitizerKind.thread]  = SanitizerPolicy(haltOnFinding: false, countNotExit: true,  defaultThreads: 1);
        // MSan links only against real compiler-rt (nixpkgs LDC → gcc fallback
        // has no MSan) AND needs an instrumented druntime+Phobos world.
        r.unavailableBecause[SanitizerKind.memory] =
            "MSan needs an instrumented druntime+Phobos world we do not build";
    }
    // UBSan: unreachable on every D compiler (clang-CodeGen-only; no IR pass).
    // Not even a SanitizerKind — documented absence, see ubsan.md.

    if (valgrindOnPath())   // wrapper mode is compiler-independent (M3)
        r.available ~= [SanitizerKind.valgrindMemcheck, SanitizerKind.valgrindHelgrind];
    return r;
}
```

`--list-sanitizers` renders the report; a requested-but-absent kind degrades to a
[`skipTest`][baseline-skip]-style yellow line carrying `unavailableBecause`, not a
red run — "DMD has no `-fsanitize`; use `--valgrind`" is a skip, not a failure.

**Borrows:** the cpu-pmu [capability-report discipline][cpu-capreport] ("absence
is a finding"); the runner's [`hasCoreCliUi` capability-by-`__traits(compiles)`
idiom][baseline]; the probe-detection pattern
(`version (LDC_*Sanitizer)` + `dlsym`) the [examples][examples] ship.

---

## 3. M1 `--sanitize=<kind>`: the recompile mode

**Goal:** run a package's tests under an instrumented build and surface findings
per test, for `address` / `leak` / `thread` on LDC (and GDC, with its
[`--param asan-globals=0`][d-toolchain] workaround).

**Mechanism — redrive dub with a generated buildType, not `DFLAGS`.** The
`DFLAGS` env var is a [silent false green][baseline-dub] (it drops `-unittest`,
runs zero tests, exits 0). The correct whole-closure channel is a **custom
buildType**, which propagates `-fsanitize=` to every dependency, applies
`-unittest` to the root only, and keys the dub cache on its name (no `--force`).
So `--sanitize` follows the `extract`/`driver` philosophy — the runner shells out
through the existing [`run()`][baseline-driver] seam rather than instrumenting
itself post-hoc (it is already running inside an _uninstrumented_ `dub test`):

```d
// (sketch) --sanitize handling, beside runDriverModes()
UnitTestResult runSanitizeMode(string pkg, SanitizerKind kind, in RunnerOptions o)
{
    auto caps = probeSanitizers(detectCompiler(o.compiler));
    if (!caps.available.canFind(kind))
        return skipRun(caps.unavailableBecause.get(kind, "unavailable")); // yellow, exit 0

    const runDir = makeWorkDir("sanitize");          // driver.d makeWorkDir
    const bt = synthBuildType(kind);                 // buildType "san-address" { … }
    const env = sanitizerEnv(kind, runDir);          // ASAN_OPTIONS etc. (below)
    // dub test -b san-<kind> :pkg -- <passthrough runner flags>
    const child = run(["dub", "test", "-b", bt, pkg, "--"] ~ passthrough(o), env, o.verbose);
    return interpret(kind, caps.policy[kind], runDir, child); // log_path files + exit code
}
```

**Runtime options the runner pins** (the survey's mandatory policy, not the
user's to forget):

- **ASan:** `detect_leaks=0` by default — plain ASan's exit-time LSan flags
  druntime's `defaultTraceHandler` trace-info mallocs as leaks and exits `1` on an
  otherwise-green suite ([asan.md][asan-leaknoise]) `[hw-verified: x86_64-linux]`.
  `log_path=<runDir>/asan` routes each process's report to a PID-suffixed file
  ([weak-hook surface][c-weak-hook]).
- **Report capture is per-tool, per the [halt-vs-recover table][c-halt-recover].**
  A recovered ASan run exits `0`, so the runner **counts reports** (log files or
  the callback), never reads the exit code; TSan exits `66` at finalize; Valgrind
  uses `--error-exitcode`. `interpret()` branches on
  `caps.policy[kind]`.

**The finding channel.** [`TestResult`][baseline-model] gains one field, and
`formatThrown`'s existing multi-line rendering ([`reporting.d`][baseline-reporting])
gains a tool banner:

```d
// (sketch) model.d
struct SanitizerFinding { string tool; string kind; string report; TestLocation at; }

struct TestResult
{
    Test test;
    bool succeeded;
    bool skipped;
    string skipReason;
    Duration duration;
    immutable(Thrown)[] thrown;
    immutable(SanitizerFinding)[] findings; // NEW: sanitizer reports for this test
}
```

A test with a finding renders `✗ pkg.mod case` followed by a
`AddressSanitizer: heap-use-after-free …` banner — the same `✗`-with-detail shape
the runner already prints for a `Thrown`, and the summary grows a
`, N sanitizer findings` segment (byte-identical when zero). M1 alone attributes
at **build/suite** granularity (like [Bazel][runner-integrations] and the
`--better-c` batch); per-test attribution is M2.

**Borrows:** the buildType channel and false-green correction
([d-toolchain.md][dtool-dub]); the `detect_leaks=0` and `log_path` policy
([asan.md][asan-control]); the `run()`/`makeWorkDir`/`detectCompiler`
orchestration the [`driver`][baseline-driver] modes already own.

---

## 4. M2: per-test attribution and halt-vs-continue policy

**Goal:** attribute each finding to the test that produced it, in-process,
without a second build — the [report-windowing][c-report-windowing] design, which
is where the runner's `TaskPool` model already sits.

**In-process windowing via the weak-hook surface.** All three seams were driven
from D on this box, working today because [`--export-dynamic`][baseline-dub] is
already passed `[hw-verified: x86_64-linux]`:

- **TSan:** a D `extern(C) void __tsan_on_report(...)` increments a
  `shared uint`; the runner snapshots the count immediately before and after each
  test body and attributes the _delta_ — the Go `checkRaces` pattern, reproduced
  from D ([tsan.md][tsan-control]). A `dlsym`-resolved
  `__tsan_on_finalize` returning `0` lets the runner own the exit protocol
  (flip `66` off once findings are reported per-test).
- **ASan:** `__asan_set_error_report_callback` hands the full report text to a D
  handler _before_ `Die()` — but `Die()` does not flush stdio, so the handler
  must write-and-close its own sink. To _continue_ past the finding (so the window
  closes and the next test runs) needs **both** `-fsanitize-recover=address`
  **and** `halt_on_error=0` ([asan.md][asan-control]).
- **LSan (per-test leaks):** the composable recipe is **not** `detect_leaks=0`
  (which disables the manual entry points too — a brief hypothesis the survey
  refuted); it is `leak_check_at_exit=0` + `__lsan_do_recoverable_leak_check()`
  per test (repeatable, non-fatal), then curating druntime's trace-malloc false
  positives via suppression ([asan.md][asan-lsan]).

```d
// (sketch) windowing around executeTest, in the TaskPool foreach
const before = __sanitizer_report_count();   // weak hook / dlsym per tool
auto result = executeTest(test);
result.findings = drainFindings(before, __sanitizer_report_count());
```

**Parallelism policy is per-tool.** ASan windows compose with the parallel
`TaskPool` (findings are process-global but the callback fires synchronously in
the reporting thread). **TSan must default to `-t 1`**: a GC-heavy multithreaded
suite [deterministically livelocks][c-stw-scan] under TSan — druntime's
signal-based stop-the-world versus TSan's async-signal deferral, a hang with no
report — so `--sanitize=thread` pins `defaultThreads: 1` and adds a **watchdog
timeout** to convert any residual hang into a reported failure rather than a stuck
CI job `[hw-verified: x86_64-linux]`. A test's _own_ threads are still fully
checked at runner `-t 1`, so real races are not lost ([tsan.md][tsan-druntime]).

**Suppression management.** Ship a curated druntime suppression file per tool
(the survey minimized TSan to two lines — `signal:thread_suspendHandler`,
`race:_D2rt8monitor*` — and memcheck to three), composed with a user-supplied
`--suppressions=<path>`, following [CTest's first-class
`CTEST_MEMORYCHECK_SUPPRESSIONS_FILE`][runner-integrations] precedent. The
load-bearing caveat: the runtimes self-symbolize but do **not demangle D**, so
every shipped and user pattern must target **mangled** names
([suppression][c-suppression]).

**Gating and degradation.** A `@sanitize` / `@noSanitize` marker UDA in
[`attributes.d`][baseline-attrs] selects/excludes tests per kind — the four-line
pattern the existing markers use, backed by LDC's own druntime
`@noSanitize("<name>")` at the compiler level. A kind absent from the
[capability report](#_2-capability-seam-first-sanitizercapabilityreport) degrades
the whole run to `skipTest`.

**Borrows:** the [Go / googletest windowing][runner-integrations] pattern (the
_documented_ industry seam, not a hack); the D reproductions in
[tsan.md][tsan-control] / [asan.md][asan-control]; the livelock finding
([tsan.md][tsan-druntime]); CTest's suppression-file discipline.

---

## 5. M3 `--valgrind`: the wrapper mode (DMD-compatible)

**Goal:** memory- and race-checking with **no recompile**, so DMD-built binaries
(which have no `-fsanitize` at all) and any LDC build get coverage — the
[wrapper-and-parse][c-wrapper-parse] design over Valgrind's XML.

**Mechanism.** Re-exec the already-built test binary under
`valgrind --xml=yes --xml-file=<runDir>/vg.%p`, with a `VALGRIND_PRINTF` client
request emitting a `<clientmsg>` marker before each test body. The markers
**interleave in stream order** with `<error>` records in XML protocol 4, so
marker-window segmentation gives per-test attribution — a stronger transport than
CTest's regex-over-text `[hw-verified: x86_64-linux]` ([valgrind.md][val-runner]).

```d
// (sketch) --valgrind: wrap, don't link
const cmd = ["valgrind", "--xml=yes", "--xml-file=" ~ runDir ~ "/vg.%p",
             "--fair-sched=yes", "--error-exitcode=99",
             "--suppressions=" ~ shippedGcSupp] ~ userSupps(o) ~ [testBinary, "-t", "1"];
```

**Pinned defaults** (survey-mandated): `--fair-sched=yes` **and `-t 1`** — the
in-process parallel runner under the default scheduler is pathological (a 4 ms
suite took 156 s at `-t auto`, rescued to 1.27 s by `--fair-sched=yes`), and
helgrind/DRD drown in GC-`SpinLock` false races above `-t 1` while being _clean_
at `-t 1`. Ship the **3-entry GC suppression** file (`Gcx.mark` `Cond`,
`defaultTraceHandler` leak, GC-init leak). `--error-exitcode=99` gives an explicit
contract (suppressed errors do _not_ trip it).

**The deep-fidelity option.** The [GC use-after-free blind spot][c-gc-blindspot]
is closable without a druntime rebuild by compiling the shipped `gc.d` +
`etc/valgrind/valgrind.d` into the build with `-debug=VALGRIND -i=etc.valgrind`
([valgrind.md][val-druntime]) — offered as an opt-in `--valgrind-gc` flag.
**Caveat the runner must advertise:** this path **fails to link under the
linux-dmd unittest config**, whose `-defaultlib=libphobos2.so` omits the
`_d_valgrind_*` exports — so `--valgrind-gc` degrades to a skip with reason on
that config, or requires static Phobos ([baseline dub path][baseline-dub]).

**Borrows:** [pytest-valgrind / CTest wrapper-and-parse][runner-integrations]; the
attribution, scheduler, and suppression findings ([valgrind.md][val-runner]); the
event-horizon `tsan-suppressions.txt` as the shipped-suppression precedent.

---

## 6. M4 `--isolate`: process-per-test

**Goal:** crash-proof attribution — the one thing in-process windowing cannot give
— by running each test in its own process, so a SIGSEGV, an ASan `SIGABRT`, or
TSan's `66` is _that one test's_ failure and cannot cancel its siblings.

The survey's finding is that sparkles' [`extract`/`driver`][baseline-driver]
machinery is **≈90% of a [process-per-test][c-process-isolation] runner**
([runner-integrations.md][runner-integrations]) — it already extracts a single
unittest body into a standalone program, compiles it, runs it, and maps the
child's exit status back. `--isolate` runs each extracted body under the M1
buildType (or M3 wrapper) and reads a `log_path=<dir>/san.<index>.%p` file plus
the exit code per child — the [CTest MemCheck][runner-integrations] shape. This
**directly fixes the [baseline crash gap][baseline-crash]**: the null-deref test
that today kills the whole run and loses the summary becomes one red `✗` with a
surviving summary.

The cost is the [extraction constraints][baseline] (public-symbols-only,
template/CTFE without `-i=`), so `--isolate` is opt-in for the SEGV-class findings
the in-process model cannot survive — not the default. It composes with M1
(recompile) and M3 (wrap) as the execution substrate.

**Borrows:** [cargo-nextest / SwiftPM `--parallel` process-per-test][runner-integrations]
("memory corruption in one test doesn't cause others to behave erratically"); the
runner's own `extract`/`driver` code; CTest's per-test `log_path` file naming.

---

## 7. M5: CI wiring and overhead-labeled reporting

**Goal:** a sanitizer job in `ci.yml` and honest overhead labels.

Add sanitizer rows to the CI matrix (LDC `--sanitize=address`, `--sanitize=thread`
at `-t 1`, and `--valgrind`), each degrading to a skip where the toolchain can't
(DMD → `--valgrind` only). Report overhead in the mode header from the survey's
figures: ASan ≈ 2× / TSan ≈ 5× / memcheck ≈ 4.4× marginal (`--track-origins`
6.4×), helgrind ≈ 2.1× ([comparison.md][comparison]). **Cache-key lesson from
[Go's GORACE hole][runner-integrations]:** if the runner ever caches results,
`*SAN_OPTIONS`/buildType must enter the key — Go silently replays cached passes
across `GORACE` changes, and dub already keys its _build_ cache on dflags, but a
_result_ cache would need the runtime options too.

## 8. M6: darwin verification

**Goal:** confirm the modes on Apple Silicon, currently `[literature]`/`[src]`
only ([macos-windows.md][macos-windows]). Darwin defaults `abort_on_error=1`
(ASan → shell exit `134`) and needs `MallocNanoZone=0`; the sanitizer runtimes are
dylib-only; Valgrind is effectively dead past macOS 10.13, so `--valgrind` is
advertised absent on darwin. Splice the pending `mac-bsn` transcripts (blocked on
a key unlock) into the capability report's darwin branch when available.

## 9. M7 (later tier): the hardware and realtime frontier

Gated on hardware and newer LLVM, per [hardware-assisted.md][hardware-assisted]'s
verdict table:

- **RTSan** (`-fsanitize=realtime`) is a real LLVM IR pass — **LDC-adoptable once
  LDC ships LLVM ≥ 20** (LDC 1.41 is LLVM 18); halts with exit `43`. A future
  `--sanitize=realtime` for `nothrow @nogc` real-time-annotated code.
- **GWP-ASan** (via `-fsanitize=scudo`) is a production [sampling
  allocator][c-sampling] — C-heap only for D (never GC memory), probabilistic, so
  the _wrong_ tool for deterministic unit tests; positioned as a fleet tool, not a
  runner mode.
- **HWASan / MTE** are hardware-gated: `x86_64` aliasing-mode HWASan runs on this
  box (exit `99`) but the GC-scan-through-untagged-pointer hazard is
  hardware-proven, and no MTE silicon is in reach (Apple M4 has none). Advertised
  absent with reason until druntime cooperates and hardware exists.

---

## 10. Milestone summary

| #   | Milestone            | Capabilities unlocked                                                                    | Depends on | Evidence base                                                                       |
| --- | -------------------- | ---------------------------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------- |
| —   | Capability seam      | reporting of absences (all modes), honest skip degradation                               | —          | [baseline][baseline], [comparison][comparison], [cpu-pmu][cpu-capreport]            |
| M1  | `--sanitize=<kind>`  | `address`/`leak`/`thread` recompile; suite-granular findings                             | seam       | [d-toolchain][dtool-dub], [asan][asan-control], [tsan][tsan-control]                |
| M2  | Per-test attribution | in-process windowing; halt/continue policy; `-t 1` + watchdog; suppressions; `@sanitize` | M1         | [tsan][tsan-control], [asan][asan-lsan], [runner-integrations][runner-integrations] |
| M3  | `--valgrind`         | no-recompile memcheck/helgrind (DMD too); XML attribution                                | seam       | [valgrind][val-runner]                                                              |
| M4  | `--isolate`          | process-per-test; crash-proof SEGV attribution (fixes the gap)                           | M1/M3      | [runner-integrations][runner-integrations], [baseline][baseline-crash]              |
| M5  | CI + overhead        | sanitizer CI rows; labeled slowdown; cache-key discipline                                | M1–M3      | [comparison][comparison], [runner-integrations][runner-integrations]                |
| M6  | darwin               | the modes on Apple Silicon                                                               | M1–M3      | [macos-windows][macos-windows]                                                      |
| M7  | later tier           | RTSan (LLVM ≥ 20), GWP-ASan positioning, HWASan/MTE gates                                | M1         | [hardware-assisted][hardware-assisted]                                              |

Sequencing rationale: the capability seam is pure reporting value and unblocks
honest degradation everywhere; M1 is the mode users ask for; M2 turns findings
into attributed test results using seams that already work; M3 is the only mode
that covers DMD and needs no build change; M4 is the crash fix and the substrate
M1/M3 run on; M5–M7 are hardening and reach. The permanent constraints carried
across milestones: druntime/Phobos stay uninstrumented (fine for ASan/TSan, fatal
for MSan), UBSan is unreachable on every D compiler, and the
[GC memory blind spot][c-gc-blindspot] is architectural — a `--sanitize=address`
mode cannot see a use-after-free _inside_ GC memory, only `--valgrind-gc` narrows
it.

## Sources

- [sparkles-baseline.md][baseline] — the audited runner and its gap analysis.
- [comparison.md][comparison] — the capability matrix this proposal's modes
  mirror, and the open questions its deferred items point at.
- Tool deep-dives: [asan][asan], [tsan][tsan], [valgrind][valgrind],
  [ubsan][ubsan], [d-toolchain][d-toolchain], [runner-integrations][runner-integrations],
  [macos-windows][macos-windows], [hardware-assisted][hardware-assisted].
- Runnable evidence: the 11 [example probes][examples] (ASan/LSan/TSan catch,
  GC blind spot, fiber, Valgrind attribution/client-requests/memcheck).
- Prior-art proposal shape: cpu-pmu [backend-proposal.md][cpu-proposal].

<!-- References -->

[baseline]: ./sparkles-baseline.md
[baseline-seam]: ./sparkles-baseline.md#the-two-package-model-and-the-extern-c-seam
[baseline-model]: ./sparkles-baseline.md#the-data-model-and-reporting-seams-no-place-for-a-finding
[baseline-attrs]: ./sparkles-baseline.md#marker-udas-and-skiptest-the-sanitize-precedent
[baseline-skip]: ./sparkles-baseline.md#marker-udas-and-skiptest-the-sanitize-precedent
[baseline-modes]: ./sparkles-baseline.md#mode-dispatch-and-the-conflicting-modes-hard-error
[baseline-driver]: ./sparkles-baseline.md#extract-and-recompile-the-recompile-mode-precedent
[baseline-dub]: ./sparkles-baseline.md#the-dub-build-path
[baseline-reporting]: ./sparkles-baseline.md#the-data-model-and-reporting-seams-no-place-for-a-finding
[baseline-crash]: ./sparkles-baseline.md#what-a-crash-looks-like-today
[baseline-gaps]: ./sparkles-baseline.md#what-the-audit-will-check
[asan]: ./asan.md
[asan-control]: ./asan.md#runtime-control-and-report-capture
[asan-lsan]: ./asan.md#the-composition-refutation-and-the-per-test-recipe
[asan-leaknoise]: ./asan.md#the-druntime-leak-noise-policy
[tsan]: ./tsan.md
[tsan-control]: ./tsan.md#runtime-control-and-report-capture
[tsan-druntime]: ./tsan.md#d-and-druntime-interaction
[ubsan]: ./ubsan.md
[d-toolchain]: ./d-toolchain.md
[dtool-dub]: ./d-toolchain.md#test-runner-integration-semantics
[valgrind]: ./valgrind.md
[val-runner]: ./valgrind.md#runner-integration-semantics
[val-druntime]: ./valgrind.md#the-d-and-druntime-interaction
[runner-integrations]: ./runner-integrations.md
[macos-windows]: ./macos-windows.md
[hardware-assisted]: ./hardware-assisted.md
[comparison]: ./comparison.md
[examples]: ./examples/asan-report-capture.d
[design-doc]: ../../libs/test-runner/explanation/design.md
[cpu-capreport]: ../cpu-pmu/backend-proposal.md#_2-1-the-capability-model
[cpu-proposal]: ../cpu-pmu/backend-proposal.md
[c-weak-hook]: ./concepts.md#weak-hook-control-surface
[c-report-windowing]: ./concepts.md#report-windowing
[c-process-isolation]: ./concepts.md#process-per-test-isolation
[c-wrapper-parse]: ./concepts.md#wrapper-and-parse
[c-halt-recover]: ./concepts.md#halt-vs-recover
[c-suppression]: ./concepts.md#suppression
[c-gc-blindspot]: ./concepts.md#the-gc-memory-blind-spot
[c-instrumented-world]: ./concepts.md#instrumented-world-requirement
[c-stw-scan]: ./concepts.md#stop-the-world-root-scanning
[c-sampling]: ./concepts.md#sampling-allocator
