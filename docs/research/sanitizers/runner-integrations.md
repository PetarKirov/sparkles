# Runner integrations (Go, Rust, Swift, Zig, CTest, Bazel, pytest-valgrind)

How the field's test runners surface a sanitizer finding **per test** — the
`cmd/go`/`cargo`/`swift test`/`zig test`/`ctest`/`bazel test`/`pytest` layer that
sits _above_ the tool and turns "the process reported a race" into "this test
failed."

| Field               | Value                                                                                                                                                                                                                                         |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ecosystems surveyed | Go (`go test -race`), Rust (`cargo test` + `cargo-nextest`), Swift (SwiftPM), Zig (`zig test`), googletest, CTest MemCheck, Bazel, pytest-valgrind                                                                                            |
| Role                | The per-test **attribution layer** (concern 6, [test-runner integration](#reading-the-table-through-the-seven-concerns)) and the [recompile-vs-wrap](#reading-the-table-through-the-seven-concerns) seam (concern 2) — not the tool internals |
| Three designs       | [In-process report windowing](#in-process-report-windowing) · [process-per-test isolation](#process-per-test-isolation) · [wrapper-and-parse](#wrapper-and-parse)                                                                             |
| Pinned sources      | `go@0153438`, `rust@3bf5c6d9`, `cargo@71b70c0`, `cargo-nextest@ae298c47`, `zig@1bcd8d9f`, `swift-pm@c84a21b4`, `cmake@5bdf88ea`, `googletest@8240fa7d`, `pytest-valgrind@98ae3524`, `rules_cc`/`envoy` `main` (fetched 2026-07-11)            |
| Verification        | `[source-verified]` dominant; one Go UX battery `[hw-verified: x86_64-linux]` (the `GORACE`-cache finding)                                                                                                                                    |

> [!NOTE]
> This page surveys **other ecosystems'** runners, so two of the survey's seven
> concerns live elsewhere: concern 1 (defect classes) belongs to the tool pages
> ([asan.md][asan], [tsan.md][tsan], [valgrind.md][valgrind]), and concern 3
> (the D/druntime interaction) belongs to [sparkles-baseline.md][baseline] and
> [integration-proposal.md][proposal]. The Go runtime seam (`race.Errors`,
> `checkRaces`) is [tsan.md][tsan]'s; here Go means the `cmd/go` UX layer.
> The one hardware battery — the `GORACE`/cache experiment — was recorded on
> **Linux 6.18.26**, an **AMD Ryzen 9 7940HX** (Zen 4), **go1.25.9** via
> `nix shell nixpkgs#go`.

---

## Overview

### What it surveys

A sanitizer or Valgrind emits a finding against a _process_: a `WARNING: DATA
RACE` on stderr, a nonzero exit, maybe a `log_path` file. A test runner's job is
to pin that finding to the _test_ that caused it, decide whether the run should
halt or continue, and present the verdict to CI without laundering it. Every
ecosystem surveyed here solves that problem, and — remarkably — they land on only
**three** designs between them. This page catalogs each ecosystem's choice, then
distills the three designs and the transferable lessons (the centerpiece is the
[integration-semantics table](#the-integration-semantics-table), reused by
[comparison.md][comparison]).

### Design philosophy: three ways to pin a finding to a test

The three designs differ in _where_ the attribution boundary lives — inside the
process, at the process edge, or in a parsed side-channel:

- **[In-process report windowing](#in-process-report-windowing)** keeps one
  process and one build, and polls a runtime error counter (or receives a weak
  callback) around each test body.
- **[Process-per-test isolation](#process-per-test-isolation)** spends a process
  per test and lets the OS boundary do the attribution and crash containment for
  free.
- **[Wrapper-and-parse](#wrapper-and-parse)** needs no cooperation from the
  payload: wrap each test, route the tool's output to a per-test sink, parse it.

The load-bearing survey finding is that **all three were already reproduced from
D by this survey** — Go's windowing seam from [tsan.md][tsan]'s Experiment E8,
Valgrind's marker attribution from [valgrind.md][valgrind], and process isolation
via the runner's existing extract-and-recompile drivers ([d-toolchain.md][d-toolchain]).
None of them is exotic; the question for sparkles is which to adopt, not whether
any is reachable.

---

## The three attribution designs

### In-process report windowing

The cheapest design: [report windowing][windowing] polls a runtime error counter
immediately before and after each test's body and attributes the count _delta_ to
the currently-running test. It keeps one process and one build, needs
[continue-semantics](#reading-the-table-through-the-seven-concerns) (TSan by
default, ASan via recover, Valgrind always), and mis-attributes background
activity that races while no test "owns" the window. Three surveyed runners use
it, and all three were reproduced from D:

- **Go's `go test -race`** is the gold standard — its core does count-delta
  windowing natively, failing the _test_ rather than the process ([tsan.md][tsan]).
- **googletest's documented sanitizer integration** hands the user a
  [weak-callback][weak-hooks] recipe: override `__tsan_on_report`/`__asan_on_error`
  to call `FAIL()`, and the report attaches to whatever test is running.
- **pytest-valgrind** takes `VALGRIND_COUNT_ERRORS` deltas per test via
  [client requests][client-request].

Go's core does it with zero user code; gtest needs a user-supplied override;
pytest-valgrind is a plugin — but the mechanism is identical. `[source-verified]`

### Process-per-test isolation

Run each test in its own process and attribution plus crash containment fall out
of the OS boundary: any nonzero exit — TSan's 66, an ASan `SIGABRT`, a segfault —
is _that one test's_ failure and cannot cancel its siblings ([process-per-test
isolation][process-per-test]). It costs a process spawn (cheap on Linux) and
forbids shared in-memory state. Its defining property is that it **dissolves the
integration problem**: the runners in this camp carry _no_ sanitizer-specific code
at all.

- **cargo-nextest** is process-per-test "now, and will always be" — sanitizers
  arrive purely as build flags.
- **SwiftPM's `--parallel`** spawns a fresh process per XCTest _case_.
- **Bazel** isolates at test-target/shard granularity, with a strict exit-code
  contract on top.

### Wrapper-and-parse

The design that needs no cooperation from the payload: wrap each test invocation,
route the tool's output to a per-test sink — `log_path=MemoryChecker.<index>.log`,
[`VALGRIND_PRINTF`][client-request] markers, or `--xml` — then parse the sink into
a defect count and attribution ([wrapper-and-parse][wrap-and-parse]). It composes
with either of the other two designs.

- **CTest's MemCheck mode** is the industrial version: per-test `log_path` files,
  regex-per-tool parsing, and a first-class checked-in
  [suppression][suppression]-file setting.
- **pytest-valgrind's log side** is the same idea over `VALGRIND_PRINTF` markers.

---

## The ecosystems, one by one

### Go: `go test -race`

Go's `cmd/go` layer is the most mature per-test sanitizer UX in the field, and
its caching behavior carries the single most transferable lesson of the survey.
The runtime seam (`race.Errors`, `resetRaces`, `checkRaces`) is
[tsan.md][tsan]'s; this section owns the `go test` UX.

**`-race` gets its own cache slot.** Because `-race` is a build flag, a `-race`
binary has a distinct build/link action ID, so race and non-race results cache
independently — the cache key is `"test binary %s args %q execcmd %q"`
(`tryCacheWithID`, `test.go:1908`). Only _passing_ package results are cached
("go test caches successful package test results", `test.go:120-125`; `saveOutput`
is called only in the `ok` branch, `test.go:1742`), so a detected race — which
fails the test — is always re-executed. `[hw-verified: x86_64-linux]`

**`GORACE` is invisible to the test cache — the headline.** `computeTestInputsID`
hashes only environment variables the test binary reads via `os.Getenv` (the
testlog protocol), and special-cases exactly one runtime variable:

> `// The runtime always looks at GODEBUG, without telling us in the testlog.`
> — `src/cmd/go/internal/test/test.go:2020` ([`go@0153438`][go-src])

`GORACE` is read by the TSan runtime via libc `GetEnv` ([tsan.md][tsan]), never
enters the testlog, and gets no such special case (`grep GORACE src/cmd/go/ -r`
matches nothing). Confirmed on hardware: after a cached `-race` pass,
`GORACE="halt_on_error=1 exitcode=42" go test -race -run TestClean` prints
`ok raceux (cached)` — the changed race-runtime options are silently _not
applied_. `[hw-verified: x86_64-linux]` The lesson for any runner that caches
test results: **sanitizer runtime options must be part of the cache key.** Go,
the field's gold standard, does not do this, and replays stale passes across
`GORACE` changes.

**`-count=1` is the documented cache bypass.** The cacheable-flag set is exactly
`-benchtime, -coverprofile, -cpu, -failfast, -fullpath, -list, -outputdir,
-parallel, -run, -short, -skip, -timeout, -v`; `-count` is deliberately absent, so
"the idiomatic way to disable test caching explicitly is to use `-count=1`"
(`test.go:127-137`). `[source-verified]`

**What the user sees, and the exit protocol.** A race renders as a
`WARNING: DATA RACE` block, then `--- FAIL: TestRacy`, then
`testing.go:1617: race detected during execution of test`, package `FAIL`, and
`go test` exit 1. `cmd/go` treats _any_ nonzero test-binary exit as package
failure (`base.SetExitStatus(1)`, `test.go:1748`) and prints the trailing `FAIL`
line itself, because "test2json reports that a test passes unless 'FAIL' is
printed at the beginning of a line" (`test.go:1767-1774`). `[hw-verified:
x86_64-linux]` Go's own protocol still carries an open hole — the same class as
dub's false green ([sparkles-baseline.md][baseline]):

> `// TODO(golang.org/issue/29062): tests that exit with status 0 without printing
a final result should fail.` — `test.go:1772-1773` ([`go@0153438`][go-src])

`[source-verified]`

**`GORACE` options (concern 4, [runtime control][halt]).** The knobs, from the
race-detector manual: `log_path` (default stderr), `exitcode` (default 66),
`strip_path_prefix`, `history_size`, `halt_on_error` (default 0), and
`atexit_sleep_ms` (default 1000). Two matter for a runner. First, `halt_on_error=1
exitcode=42` on a racy test still renders as plain `FAIL` — any nonzero exit is
just failure; the custom code is not surfaced specially. Second, the
`atexit_sleep_ms=1000` default is visible in wall time: a `-race` pass measured
1.010 s versus 0.002 s uninstrumented — which is why Go's own harness pins
`atexit_sleep_ms=0`, prior art for a runner doing the same. `[hw-verified:
x86_64-linux]` `[literature]`

**Parallelism and suppression.** `-parallel` applies only within one test binary;
`go test` may run different _packages_ in parallel per the `-p` flag
(`test.go:308-311`) — process-per-package, not per-test. There is no report
suppression: Go's only exclusion mechanism is the `race` build tag on files/tests
(code exclusion, not silencing); `GORACE` has no `suppressions=` option.
`[source-verified]` `[literature]`

### Rust: `-Zsanitizer`, libtest, and cargo-nextest

Rust splits cleanly into a stock path (`cargo test` + libtest) with weak
attribution and a best-in-class isolation runner (`cargo-nextest`) that dissolves
the problem.

**Sanitizers are nightly `-Zsanitizer=…`** (address, cfi, dataflow, hwaddress,
kcfi, leak, memory, memtag, realtime, safestack, shadow-call-stack, thread), and
the std-recompile requirement is explicit — the same
[instrumented-world][instrumented-world] shape D hits with druntime, except Rust
ships the rebuild flag:

> The `-Zbuild-std` flag rebuilds and instruments the standard library, and is
> strictly necessary for the correct operation of the tool.
> — `src/doc/unstable-book/src/compiler-flags/sanitizer.md` ([`rust@3bf5c6d9`][rust-src])

`[source-verified]`

**libtest runs tests as in-process threads**: concurrency defaults to
`available_parallelism` (`library/test/src/lib.rs:383`), and each test runs on a
thread _named after the test_ (`thread::Builder::new().name(name…)`, `lib.rs:695`).
Process-per-test exists only under `panic=abort` (`RunStrategy::SpawnPrimary`,
`lib.rs:395-399`). The attribution consequence: a sanitizer halt kills the whole
binary mid-run, and the only in-report attribution is _incidental_ — sanitizer
reports print thread names (TSan's `thread_name`, `tsan_report.cpp:55`), which
here happen to carry the test name. `[source-verified]` Toggling sanitizers also
thrashes cargo's cache: `RUSTFLAGS` is part of the unit fingerprint
(`fingerprint/mod.rs:661`; mismatch → dirty at `:1097`), so one target dir holds
one flag-set — unlike Go's side-by-side slots. `[source-verified]`

**cargo-nextest is the process-per-test answer.** It carries _zero_
sanitizer-specific configuration (`grep -rli sanitizer site/src/docs/` is empty) —
sanitizers arrive as a pure build concern, and isolation handles the rest:

> With nextest, the default execution model is now, and will always be,
> process-per-test.
> — `site/src/docs/design/why-process-per-test.md` ([`cargo-nextest@ae298c47`][nextest-src])

The runner appends `["--exact", self.name, "--nocapture"]` to spawn each test as
its own process (`nextest-runner/src/list/test_list.rs:1675`), after a
`cargo test --no-run` build + per-binary list phase. Failure is a per-test
exit-code contract: `ExecutionResult` is Pass / Leak / `Fail { failure_status }` /
ExecFail / Timeout (`reporter/events.rs:1864-1896`), so a TSan deferred exit 66 or
an ASan `SIGABRT` is attributed to exactly the offending test and cannot cancel
siblings. ("Leak" here means leaked _file handles/subprocesses_, not memory.) The
generic wrapper hooks — _target runners_ (`target.<triple>.runner`) and
experimental _wrapper scripts_ — are the valgrind/qemu seam. `[source-verified]`

### Swift: `swift test --sanitize=`

**Kinds and plumbing.** SwiftPM accepts `address`, `thread`, `undefined`, `scudo`
(`Sources/PackageModel/Sanitizers.swift:14-30`): C-family targets get
`-fsanitize=<kind>`, Swift targets get `-sanitize=<kind>` at compile _and_ link
(`SwiftModuleBuildDescription.swift:527`). It recompiles the package graph only —
there is no stdlib-rebuild story (contrast Rust's `-Zbuild-std`), and SwiftPM
validates nothing: `EnabledSanitizers.init` carries `// FIXME: We need to throw
from here if given sanitizers can't be enabled…` (`Sanitizers.swift:39-42`), so
whether `undefined` reaches Swift code is left to `swiftc` — the same
"UBSan is a C-family concern" shape D hits ([ubsan.md][ubsan]). `[source-verified]`

**Attribution is a `--parallel` side effect.** By default the whole XCTest bundle
runs serially in one process, so there is no per-test attribution at all.
`--parallel` switches to `ParallelTestRunner`: worker threads each dequeue one
test case and spawn a fresh process for exactly that specifier
(`SwiftTestCommand.swift:1590-1604`) — process-per-test-_case_, XCTest-only
("swift-testing does not use ParallelTestRunner", `:1602`). So a sanitizer finding
is cleanly attributed only when `--parallel` is on. `[source-verified]`

**The macOS harness-injection trick.** Because tests load into Apple's
uninstrumented `xctest` harness binary, SwiftPM injects the sanitizer runtime into
the harness process — `env["DYLD_INSERT_LIBRARIES"] = runtimes.joined(…)` with
`libclang_rt.<shortName>_osx_dynamic.dylib` resolved out of the toolchain
(`TestingSupport.swift:353-368`) — a wrap-the-harness trick hiding inside a
recompile-based toolchain (and a SIP interaction waiting to happen). Report
options are pass-through only: the test env starts from `Environment.current`, so
`ASAN_OPTIONS` etc. flow in with nothing first-class. See [macos-windows.md][macos-windows].
`[source-verified]`

### Zig: the language-level dissolution

Zig is the contrast case: the "sanitizer" dissolves into the language and the
compiler, and the runner does per-test _allocator_ windowing of its own.

**`std.valgrind` is a stdlib module** with the [client-request][client-request]
rotate-sequence assembly per architecture (`lib/std/valgrind.zig`) — a far larger
surface than druntime's seven `memcheck` wrappers ([valgrind.md][valgrind]):
`countErrors`, the full mempool family, `stackRegister`, `disable/enableErrorReporting`,
plus `memcheck`/`callgrind`/`cachegrind` submodules (no helgrind/DRD, the same gap
as D). Valgrind support is **ON by default in Debug** (`valgrind = optimize_mode ==
.Debug`, `src/Package/Module.zig:132`), and the compiler itself _emits_ requests:
safety-mode `undefined` stores fill `0xaa` and then `valgrindMarkUndef` the range
(`FuncGen.zig:4742-4748`). D's contrast is opt-in `-debug=VALGRIND -i=etc.valgrind`
with zero compiler emission. `[source-verified]`

**`-fsanitize-c` defaults on.** `SanitizeC` is `off|trap|full`; per-module default
is `.full` in Debug, `.trap` in ReleaseSafe (`src/Package/Module.zig:252-264`) —
the famous "`zig cc` turns UBSan on by default" story, with Zig shipping its own
UBSan runtime written in Zig and building the TSan runtime from source on demand.
The in-source rationale for the ReleaseSafe downgrade:

> `// It's recommended to use the minimal runtime in production environments due to
the security implications of the full runtime. The minimal runtime doesn't
provide much benefit over simply trapping, however, so we do that instead.`
> — `src/Package/Module.zig:257-260` ([`zig@1bcd8d9f`][zig-src])

`[source-verified]`

**`zig test` = in-process, sequential, per-test allocator windowing.** Each test
gets a _fresh_ `std.testing.allocator_instance` (a `DebugAllocator` with canary +
`check_write_after_free`), and its `deinit()` after the test returns the leak count
attributed to _that_ test (`lib/compiler/test_runner.zig:275-287`). Crash
attribution is protocol-based: the runner sends `.test_started` before each test,
the build-runner tracks `active_test_index`, and renders per-test leak errors as
`'{s}' leaked {d} allocations` (`Maker/Step/Run.zig:494-497`) — a crashed binary
is attributed to the test that had started. Wrapper hooks are first-class CLI:
`--test-cmd`/`--test-cmd-bin` wrap execution (the valgrind/qemu seam),
`--test-runner` swaps the runner, `--test-no-exec` splits build from run
(`src/main.zig:690-694`). `[source-verified]`

### googletest: the documented weak-callback window

**The official integration is byte-identical to the D reproduction.** googletest's
"Sanitizer Integration" section instructs users to define
`__ubsan_on_report`/`__asan_on_error`/`__tsan_on_report` calling `FAIL() << …`:

> After compiling your project with one of the sanitizers enabled, if a particular
> test triggers a sanitizer error, GoogleTest will report that it failed.
> — `docs/advanced.md:2481-2482` ([`googletest@8240fa7d`][gtest-src])

Attribution is [report windowing][windowing]: the report attaches to whatever test
is running. gtest itself ships **no** built-in hooks — only self-protection
attributes (`GTEST_ATTRIBUTE_NO_SANITIZE_*`, `gtest-port.h:886-912`) — so the user
supplies the override. This is the _documented industry pattern_, and it is exactly
the [weak-hook][weak-hooks] seam [tsan.md][tsan]'s Experiment E8 drove from D: the
D reproduction is not a hack. The caveats carry over: ASan's default halt still
kills the process after `FAIL()` (needs recover mode to continue), while TSan's
default report-and-continue fits perfectly. `[source-verified]`

**Death tests double as sanitizer-report capturers — in compiler-rt itself.**
ASan's own gtest suite asserts reports with
`EXPECT_DEATH(uaf_test<U1>(1, 0), "AddressSanitizer:.*heap-use-after-free")` — 77
`EXPECT_DEATH` uses in `compiler-rt/lib/asan/tests/asan_test.cpp` alone
([`llvm-project@73802c2e`][llvm-src]) — running with `death_test_style =
"threadsafe"` (`asan_test_main.cpp:37`). The machinery (fork/exec a child, match
its stderr against a regex, require abnormal exit) is a ready-made "expect this
sanitizer report" harness. The "fast" (fork) versus "threadsafe" (fork+exec) styles
exist because of "well-known problems with forking in the presence of threads"
(`advanced.md:566-590`) — directly relevant under the TSan/ASan runtimes.
`[source-verified]`

**Premature-exit-file** covers the lying-exit-status case: `ScopedPrematureExitFile`
writes a `"0"` file when `RUN_ALL_TESTS` starts and removes it on normal
completion (`gtest.cc:5164-5199`), path from `TEST_PREMATURE_EXIT_FILE`, so an
external runner detects "the process ended without finishing the suite" even when
the exit code looks clean. `[source-verified]`

### CTest MemCheck: the wrapper-and-parse industrial design

`CTEST_MEMORYCHECK_TYPE` spans Valgrind, Purify, BoundsChecker, DrMemory,
CudaSanitizer, and the five sanitizers (Thread/Address/Leak/Memory/UndefinedBehavior)
(`Source/CTest/cmCTestMemCheckHandler.cxx:316-331`). For the sanitizer types it
wraps every test command with `cmake -E env` setting the appropriate
`*SAN_OPTIONS` to `log_path='<BinaryDir>/Testing/Temporary/MemoryChecker.<index>.log'`,
where `<index>` is the **test index** (`cmCTestMemCheckHandler.cxx:710-752`) — the
same `log_path` per-process mechanism [asan.md][asan] and [valgrind.md][valgrind]
establish, here keyed per test. Output parsing is regex-per-tool
(`"ERROR: AddressSanitizer: (.*) on.*"`, `"WARNING: ThreadSanitizer: (.*) \(pid=.*\)"`,
`"(Direct|Indirect) leak of .*"`, `ProcessMemCheckSanitizerOutput`, `:813-866`),
accumulating a `DefectCount` exposed to scripts as `ctest_memcheck(DEFECT_COUNT
var)`. Exit codes are _not trusted_: a test whose log parses to defects is a
defect regardless of its exit status (`:813`), and results feed the
`DynamicAnalysis` dashboard XML with `Checker="AddressSanitizer"` etc. `[source-verified]`

**CTest is the only surveyed runner with a first-class checked-in
[suppression][suppression]-file setting**: `CTEST_MEMORYCHECK_SUPPRESSIONS_FILE`
is appended as `:suppressions=<file>` into the `*SAN_OPTIONS` env
(`cmCTestMemCheckHandler.cxx:725-729`) — spanning Valgrind _and_ the sanitizers.
The doc warns against colliding with its own `log_path`:

> CTest prepends correct sanitizer options `*_OPTIONS` environment variable to
> executed command. CTests adds its own `log_path` to sanitizer options, don't
> provide your own `log_path`.
> — `Help/variable/CTEST_MEMORYCHECK_SANITIZER_OPTIONS.rst` ([`cmake@5bdf88ea`][cmake-src])

Generic per-test wrapping exists separately as the `TEST_LAUNCHER` target property
/ `CMAKE_TEST_LAUNCHER` (CMake 3.29). The recompile side is community modules —
KDE ECM's `ECMEnableSanitizers` and arsenm/sanitizers-cmake are the common
`-fsanitize` injectors. `[source-verified]` `[literature]`

### Bazel: the exit-code contract

Bazel refuses the attribution problem at the runner layer with a total exit-code
contract:

> If a test process runs to completion and terminates normally with an exit code
> of zero, the test has passed. Any other result is considered a test failure. In
> particular, writing any of the strings PASS or FAIL to stdout has no significance
> to the test runner.
> — Bazel Test Encyclopedia ([bazel.build][bazel-docs], retrieved 2026-07-11)

So TSan's deferred exit 66 or a custom `exitcode` is automatically a test failure;
the dub-swallow ([sparkles-baseline.md][baseline]) cannot happen. Attribution
granularity is the test _target_ (or shard) process; `test.xml` (from
`XML_OUTPUT_FILE`, or a Bazel-generated wrapper of the log) is where sanitizer
stderr lands. `[source-verified]`

**The toolchain declines recovery.** rules_cc ships first-class
`asan`/`lsan`/`tsan`/`ubsan` toolchain features, each built by `_sanitizer_feature`,
which hard-wires `-fno-omit-frame-pointer` **and `-fno-sanitize-recover=all`** on
top of the `-fsanitize=` flags (`cc/private/toolchain/unix_cc_toolchain_config.bzl:226-246`,
fetched 2026-07-11). Canonical Bazel is halt-on-error, recovery declined at the
toolchain layer — the exact opposite of the gtest/Go in-process bet, and equally
self-consistent (neither camp swallows exit codes). Enable per target
(`features = ["asan"]`) or globally (`--features=asan`). `[source-verified]`

**`--config=asan` is a `.bazelrc` convention, not a Bazel feature.** The exhibit is
Envoy's `.bazelrc`: `build:asan-common` sets `--copt/--linkopt -fsanitize=address,undefined`,
`--test_env=ASAN_OPTIONS=…:detect_odr_violation=1`, `--test_env=UBSAN_OPTIONS=halt_on_error=true`,
tag filters `-no_san` for opt-outs, and `--define signal_trace=disabled` ("disable
ours so the stacktrace will be printed by ASAN"). The env is hermetic — "`--test_env`…
specifies additional variables that must be injected into the test environment for
each test" is the only door — so suppression files travel as repo files referenced
by runfiles-relative paths, and `--run_under=<command-prefix>` is the wrapper hook
(the valgrind seam). `[literature]`

### pytest-valgrind: the low road, done honestly

pytest-valgrind is Go's windowing pattern under Valgrind, in-process, and it
independently converged on _both_ mechanisms [valgrind.md][valgrind] built its
recipe on. A pytest hookwrapper around each test does count-delta windowing with
the same [client requests][client-request]:
`error = get_valgrind_num_errs() - self.prev_errors > 0` (`plugin.py:241`), plus a
per-test `VALGRIND_DO_LEAK_CHECK`/`VALGRIND_COUNT_LEAKS` delta — the exact
per-test recoverable-leak-check recipe [asan.md][asan]'s LSan section proposes.
Before every check it forces Python GC to settle (`for i in range(20): if
gc.collect() == 0: break`, `plugin.py:232-237`) — the same GC-noise discipline
D needs (the [GC memory blind spot][gc-blind-spot]). Log segmentation uses
`VALGRIND_PRINTF` markers (`valgrind.c:71`) writing the test nodeid between
separator lines, then re-reads the file incrementally to attach error text to the
failing test — independently confirming [valgrind.md][valgrind]'s
clientmsg-marker attribution. `[source-verified]`

Outcomes mean only "valgrind status": dirty tests are force-failed with
`[VALGRIND ERROR]`/`[VALGRIND LEAK]`; a test that failed normally but is
valgrind-clean becomes **xfail** ("Error, but valgrind clean, using xfail",
`plugin.py:293`). Per-test suppression is a pytest marker
(`@pytest.mark.valgrind_known_error`/`valgrind_known_leak` → xfail) — arguably the
nicest per-test suppression UX surveyed. It requires `PYTHONMALLOC=malloc`, runs
one process sequentially, and never mentions pytest-xdist (whose per-worker model
would need one valgrind per worker). `[source-verified]`

---

## The integration-semantics table

The centerpiece, reused by [comparison.md][comparison]. Every cell is
locator-backed in the survey's grounding ledger; page cross-links point at the
tool pages that own the runtime detail. Columns: recompile-vs-wrap, per-test
attribution, halt-vs-continue, parallelism, suppression management, CI ergonomics.

| Ecosystem              | Recompile vs wrap                                                                                                                                                    | Per-test attribution                                                                                                                                             | Halt vs continue                                                                                                             | Parallelism                                                                               | Suppression management                                                              | CI ergonomics                                                                                                 |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Go `go test -race`** | Recompile via build flag `-race`; runtime is a prebuilt TSan `.syso` ([tsan.md][tsan])                                                                               | In-process count-delta window per test (`checkRaces`, [tsan.md][tsan]); paused-test misattribution documented                                                    | Continue; each race fails the _test_; `__tsan_fini` exit 66 only on clean exit; `halt_on_error=1` opt-in                     | In-process goroutines + `t.Parallel`; process-per-package via `-p` (`test.go:308`)        | None — `race` build tag excludes code; no `GORACE suppressions=`                    | `FAIL` + exit 1 out of the box; cached per build flags; **`GORACE` invisible to the cache** (`test.go:2020`)  |
| **Rust `cargo test`**  | Recompile: nightly `-Zsanitizer` + `-Zbuild-std` for std (`sanitizer.md`)                                                                                            | None structural; incidental thread-name = test name (`lib.rs:695`; `tsan_report.cpp:55`)                                                                         | Sanitizer default (ASan halts, TSan continues + 66); a halt kills the whole binary, cancels siblings                         | In-process threads (= nproc), `--test-threads`; process-per-test only under `panic=abort` | None; env passthrough only                                                          | Fingerprint thrash on flag toggle (`fingerprint/mod.rs:661`); exit propagates, attribution lost               |
| **cargo-nextest**      | Same builds as `cargo`; no sanitizer config of its own (`grep -rli sanitizer` empty)                                                                                 | **Process-per-test** (`--exact <name> --nocapture`, `test_list.rs:1675`); per-test output + JUnit                                                                | Irrelevant by construction: any nonzero exit/signal = that one test fails, siblings unaffected (`events.rs:1864`)            | Parallel across processes (= nproc); test-groups / threads-required knobs                 | None first-class; generic wrapper scripts + target runners (valgrind seam)          | Retries mark tests flaky; JUnit per test; crash isolation; leaked-handle detection                            |
| **Swift `swift test`** | Recompile package graph (`-sanitize=` swiftc / `-fsanitize=` clang); no stdlib rebuild                                                                               | Default none (serial, one process); `--parallel` → process-per-test-_case_ (`SwiftTestCommand.swift:1590`)                                                       | Sanitizer defaults; runner does nothing; SwiftPM validates nothing (`Sanitizers.swift:39`)                                   | Serial in-process, or `--parallel` process-per-case (XCTest only)                         | None; env passthrough (`Environment.current`)                                       | macOS: auto `DYLD_INSERT_LIBRARIES` of `clang_rt` dylib into `xctest` ([macos-windows.md][macos-windows])     |
| **Zig `zig test`**     | Language-level: safety checks + `-fsanitize-c` (`.full` in Debug); TSan from source; valgrind requests default-ON (`Module.zig:132,252`)                             | In-process sequential; per-test fresh `DebugAllocator` → per-test leak counts; `.test_started` protocol → crash attribution (`test_runner.zig:275`)              | Safety violations trap/panic → runner reports that test, continues where recoverable; crashed binary attributed via protocol | Sequential within a binary; build graph parallelizes across test binaries                 | None (`@setRuntimeSafety` scopes checks off)                                        | `--test-cmd`/`--test-cmd-bin` wrap hooks; `--test-runner` swap; leak counts in build output                   |
| **googletest + CTest** | gtest: user recompiles `-fsanitize` (ECM/community modules); CTest wraps instrumented or not alike                                                                   | gtest: weak-callback `FAIL()` window (`advanced.md:2455`); CTest: per-test `log_path=MemoryChecker.<index>.log` + regex parse (`cmCTestMemCheckHandler.cxx:710`) | gtest needs continue-mode (TSan default / ASan recover); CTest counts defects regardless of exit code (`:813`)               | gtest in-process, one process/binary; `ctest -j N` = process-per-test-command             | **First-class**: `CTEST_MEMORYCHECK_SUPPRESSIONS_FILE` → `:suppressions=` (`:725`)  | `ctest -T MemCheck` dashboards (`DynamicAnalysis.xml`); `DEFECT_COUNT`; premature-exit-file (`gtest.cc:5164`) |
| **Bazel**              | Recompile via toolchain features (`--features=asan`; rules_cc `-fno-sanitize-recover=all`, `unix_cc_toolchain_config.bzl:226`) or `--config=asan` bazelrc convention | Test-target / shard process; `test.xml` wraps the whole log                                                                                                      | Halt-on-error at the toolchain layer (no recover); failure = nonzero exit of the target process                              | Parallel across targets + sharding (runner once per shard); hermetic, remote-executable   | Convention: checked-in files + `--test_env` paths; tag filters (`-no_san`) opt-outs | Pure exit-code contract; caching / remote-exec flag-aware; `--run_under` wrapper (valgrind)                   |
| **pytest-valgrind**    | Wrap: unmodified CPython under valgrind (`PYTHONMALLOC=malloc`); C extension optionally rebuilt                                                                      | In-process client-request count-deltas + `VALGRIND_PRINTF` markers per test (`plugin.py:241`, `valgrind.c:71`)                                                   | Continue; plugin converts deltas → per-test FAIL; normal failures rewritten to xfail (`plugin.py:293`)                       | One process, sequential (xdist unaddressed)                                               | Per-test pytest markers `valgrind_known_error/leak` → xfail (`plugin.py:261`)       | Single valgrind run over the whole suite; slow; log read back in by hand ([valgrind.md][valgrind])            |

---

## Reading the table through the seven concerns

The survey's [seven concerns][concepts] are per-tool; this page's subjects are
_runners_, so the spine maps onto the table's columns rather than getting seven
sections. The mapping, once:

- **Concern 1 (defect classes) — not applicable.** Which bug classes a tool
  catches is [asan.md][asan]/[tsan.md][tsan]/[valgrind.md][valgrind]'s, and the
  shadow-memory internals underneath are [concepts.md][concepts]'s; a runner is
  agnostic to them. It surfaces here only as _what the finding is_, never _how it
  was found_.
- **Concern 2 (instrumentation model) — the "recompile vs wrap" column.** Every
  ecosystem recompiles (`-race`, `-Zsanitizer`, `-sanitize=`, `-fsanitize-c`,
  toolchain features) except pytest-valgrind, which wraps an unmodified interpreter;
  the [runtime-selection][selection] detail is the tool pages'.
- **Concern 3 (D/druntime interaction) — not applicable.** These are other
  languages' runtimes; the D consequences of adopting each design are
  [sparkles-baseline.md][baseline]'s and [integration-proposal.md][proposal]'s,
  gathered in [patterns for sparkles](#patterns-for-sparkles) below.
- **Concern 4 (runtime control and report capture) — the "halt vs continue"
  column.** This is where [halt-vs-recover][halt] policy lives: Go's exit-66
  backstop, ASan's recover-mode exit 0, Bazel's `-fno-sanitize-recover=all`, CTest
  distrusting exit codes entirely.
- **Concern 5 (suppressions) — the "suppression management" column.**
  [Symbolization][concepts] is the tool's; suppression _management_ is the
  runner's, and only CTest makes it first-class.
- **Concern 6 (test-runner integration) — the "per-test attribution" and
  "parallelism" columns, and the entire page.** This is the whole reason the page
  exists; "Test-runner integration" is the sibling pages' name for it.
- **Concern 7 (platform and toolchain coverage) — partly "CI ergonomics", else
  not applicable.** The runners are cross-platform by construction; the one
  platform-specific wrinkle (SwiftPM's `DYLD_INSERT_LIBRARIES` into `xctest`) is
  [macos-windows.md][macos-windows]'s, and there is no per-ecosystem D toolchain
  matrix to draw.

---

## Key design decisions and trade-offs

The three designs, as a runner-author would weigh them:

| Decision                                             | Rationale                                                                                            | Trade-off                                                                                                                             |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [In-process windowing](#in-process-report-windowing) | One process, one build, cheapest; the current test "owns" the report count-delta                     | Needs [continue-semantics][halt]; mis-attributes cross-test background activity; process-global callback state blurs parallel workers |
| [Process-per-test](#process-per-test-isolation)      | Attribution + crash containment fall out of the OS boundary; zero sanitizer-specific code            | Process-spawn cost; forbids shared in-memory state; needs a two-phase build/list/run                                                  |
| [Wrapper-and-parse](#wrapper-and-parse)              | No cooperation from the payload; suppression files as checked-in config; composes with the other two | Parser must track tool output format; per-test `log_path`/marker plumbing; slowest when it wraps the whole suite                      |
| Fail the _test_, never launder the exit code         | Go/nextest/Bazel/CTest each keep "found a bug" distinguishable from "test crashed"                   | Requires the runner to own the exit protocol (Go bypasses `__tsan_fini`; nextest reads per-process exit; CTest parses)                |
| Fold sanitizer options into the result-cache key     | The `GORACE`-cache hole proves a stale pass replays across runtime-option changes                    | One more input to hash; Go itself does _not_ do this (only `GODEBUG` is special-cased)                                                |

---

## Patterns for sparkles

The survey's three designs map onto machinery sparkles _already has_, and the
mapping — not a new design — is what [integration-proposal.md][proposal] builds
on (this page does not design the proposal).

**[In-process windowing](#in-process-report-windowing) → the `TaskPool` runner.**
sparkles' runner is already an in-process, `TaskPool`-parallel harness, which is
exactly where the windowing camp sits. [tsan.md][tsan]'s Experiment E8 proved the
[weak-hook][weak-hooks] seam works from D today: overriding `__tsan_on_report` to
count into a `shared uint`, snapshotting it around each test's window, and defining
`__tsan_on_finalize` to own the exit reproduced Go's `checkRaces` pattern against
GCC `libtsan`. The attribution blur the windowing design accepts — background
activity racing while no test owns the window (Go documents it) — is bounded the
same way Go bounds it: `-t 1`, or per-worker windows keyed by `TaskPool` worker.
googletest's _documented_ `FAIL()`-in-callback recipe and pytest-valgrind's
count-delta plugin are independent confirmations that this is the industry pattern,
not a D-specific hack.

**[Process-per-test](#process-per-test-isolation) → extract-and-recompile.** The
runner's `--better-c`/`--wasm` drivers already extract a single `unittest` body
into a standalone program ([d-toolchain.md][d-toolchain]); running each extracted
test under a sanitizer with exit-code-as-verdict is precisely the cargo-nextest
model, and it is what closes the runner's current "a `SEGV` kills the whole run"
gap ([sparkles-baseline.md][baseline]). The cost is nextest's cost — a process
spawn per test and a two-phase build/list/run — and the payoff is nextest's payoff:
attribution and crash containment for free, with _zero_ sanitizer-specific runner
code. The [wrapper-and-parse](#wrapper-and-parse) design composes on top via
CTest's `log_path='file.<index>.log'` trick, which [valgrind.md][valgrind]'s
`--valgrind` proposal already improves on with the XML protocol.

**Cache and policy discipline.** Two lessons transfer wholesale. First, if
sparkles ever caches test _results_, the `GORACE`-cache hole is the cautionary
tale: `*SAN_OPTIONS`/`GORACE`-style runtime options must enter the cache key, which
even Go does not do. Second, Bazel's `-fno-sanitize-recover=all` and Envoy's
`--test_env` conventions argue for the _runner_, not the user, pinning runtime
options (`detect_leaks=0`, `atexit_sleep_ms=0`, the `halt_on_error` choice, the
`-t 1` policy under TSan) — the direction the tool pages already commit to
([asan.md][asan]'s LSan policy, [tsan.md][tsan]'s `-t 1` default). The synthesis of
these into a milestoned plan is [integration-proposal.md][proposal]'s.

---

## Sources

- **Go** — `cmd/go` test caching and UX, read at [`go@0153438`][go-src]:
  `src/cmd/go/internal/test/test.go` (caching `:120-141`, the `GODEBUG` testlog
  special case `:2020`, the exit protocol `:1742-1774`, `issue/29062` TODO); the
  `go.dev` race-detector manual (`GORACE` options); Experiment E1 (the hardware
  battery)
- **Rust** — read at [`rust@3bf5c6d9`][rust-src] / [`cargo@71b70c0`][cargo-src] /
  [`cargo-nextest@ae298c47`][nextest-src]: `unstable-book/…/sanitizer.md`
  (`-Zbuild-std`), `library/test/src/lib.rs` (libtest threads),
  `fingerprint/mod.rs:661` (cache thrash),
  `why-process-per-test.md` / `test_list.rs:1675` / `reporter/events.rs:1864`
  (nextest)
- **Swift** — read at [`swift-pm@c84a21b4`][swiftpm-src]:
  `PackageModel/Sanitizers.swift`, `Build/BuildDescription/{Clang,Swift}ModuleBuildDescription.swift`,
  `Commands/SwiftTestCommand.swift:1590` (`ParallelTestRunner`),
  `Utilities/TestingSupport.swift:353` (`DYLD_INSERT_LIBRARIES`)
- **Zig** — read at [`zig@1bcd8d9f`][zig-src]: `lib/std/valgrind.zig`,
  `src/Package/Module.zig:132,252-264` (valgrind + `-fsanitize-c` defaults),
  `src/codegen/llvm/FuncGen.zig:4742` (compiler-emitted requests),
  `lib/compiler/test_runner.zig:275` (per-test allocator), `src/main.zig:690`
  (`--test-cmd`)
- **googletest / CTest** — read at [`googletest@8240fa7d`][gtest-src] /
  [`cmake@5bdf88ea`][cmake-src]: `docs/advanced.md:2455-2483` (the sanitizer
  recipe), `gtest.cc:5164` (premature-exit-file),
  `cmCTestMemCheckHandler.cxx:710-866` (log_path + regex),
  `CTEST_MEMORYCHECK_SANITIZER_OPTIONS.rst`; the compiler-rt `EXPECT_DEATH`
  exhibit in `asan_test.cpp` ([`llvm-project@73802c2e`][llvm-src])
- **Bazel** — [Test Encyclopedia + user manual][bazel-docs] (exit-code contract,
  `--test_env`, `--run_under`), fetched 2026-07-11; rules_cc
  `unix_cc_toolchain_config.bzl:226` (`-fno-sanitize-recover=all`) and Envoy's
  `.bazelrc` (the `--config=asan` convention exhibit), `main` fetched 2026-07-11
- **pytest-valgrind** — read at [`pytest-valgrind@98ae3524`][pytest-valgrind-src]:
  `pytest_valgrind/plugin.py` (windowing, xfail rewrite, markers),
  `pytest_valgrind/valgrind.c` (client requests)
- Related pages: [tsan.md][tsan] (the Go runtime seam), [valgrind.md][valgrind]
  (the client-request mechanism), [d-toolchain.md][d-toolchain]
  (extract-and-recompile), [comparison.md][comparison] (which reuses the table),
  [sparkles-baseline.md][baseline] and [integration-proposal.md][proposal]
- Shared vocabulary: [concepts.md][concepts] ([report windowing][windowing],
  [process-per-test isolation][process-per-test], [wrapper-and-parse][wrap-and-parse],
  [halt vs recover][halt], [weak-hook control surface][weak-hooks],
  [suppression][suppression], [client request][client-request],
  [runtime selection][selection])

<!-- References -->

[concepts]: ./concepts.md
[windowing]: ./concepts.md#report-windowing
[process-per-test]: ./concepts.md#process-per-test-isolation
[wrap-and-parse]: ./concepts.md#wrapper-and-parse
[halt]: ./concepts.md#halt-vs-recover
[weak-hooks]: ./concepts.md#weak-hook-control-surface
[suppression]: ./concepts.md#suppression
[client-request]: ./concepts.md#client-request
[selection]: ./concepts.md#sanitizer-runtime-selection
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[instrumented-world]: ./concepts.md#instrumented-world-requirement
[asan]: ./asan.md
[tsan]: ./tsan.md
[ubsan]: ./ubsan.md
[valgrind]: ./valgrind.md
[d-toolchain]: ./d-toolchain.md
[macos-windows]: ./macos-windows.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./integration-proposal.md
[go-src]: https://github.com/golang/go/tree/015343854b5d9e2829481df30dbcae2ca6682d25
[rust-src]: https://github.com/rust-lang/rust/tree/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21
[cargo-src]: https://github.com/rust-lang/cargo/tree/71b70c095bb15e278ab9f0f808397c8033079888
[nextest-src]: https://github.com/nextest-rs/nextest/tree/ae298c470dab1f3eb2f6a811434cb137572f04d8
[zig-src]: https://github.com/ziglang/zig/tree/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa
[swiftpm-src]: https://github.com/swiftlang/swift-package-manager/tree/c84a21b421df97d6d293e3f36b3af693c7c0bf4b
[cmake-src]: https://github.com/Kitware/CMake/tree/5bdf88eaa1a605b108d3b89dfb2fdf3d073990f5
[gtest-src]: https://github.com/google/googletest/tree/8240fa7d62f73e01c7af27d61ed965d6d66698fa
[pytest-valgrind-src]: https://github.com/seberg/pytest-valgrind/tree/98ae3524bf9b1d28cadffa34bad66c16a6001494
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[bazel-docs]: https://bazel.build/reference/test-encyclopedia
