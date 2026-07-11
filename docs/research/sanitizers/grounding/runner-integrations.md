# Grounding ledger — `runner-integrations.md`

Claim-by-claim verification of `docs/research/sanitizers/runner-integrations.md`
against the pinned trees `go@0153438`, `rust@3bf5c6d9`, `cargo@71b70c0`,
`cargo-nextest@ae298c47`, `zig@1bcd8d9f`, `swift-pm@c84a21b4`, `cmake@5bdf88ea`,
`googletest@8240fa7d`, `pytest-valgrind@98ae3524`, and the cross-check trees
`llvm-project@73802c2e` (the compiler-rt `EXPECT_DEATH` exhibit) and Bazel's
`rules_cc`/`envoy` `main` (fetched 2026-07-11, unpinned). The one hardware battery
(E1) was recorded on **Linux 6.18.26** (NixOS 25.11), **AMD Ryzen 9 7940HX** (Zen
4), **go1.25.9** via `nix shell nixpkgs#go`. `$REPOS = /home/petar/code/repos`;
the Go repo is `$REPOS/go/go` (register R9). Experiment transcripts live in
`…/scratchpad/w5/`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                                                                                                                             | Type             | Source (local + locator)                                                                                                 | Status                |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------- |
| L1  | `-race` is a build flag, so a `-race` binary gets its own test-cache slot; the cache key is `"test binary %s args %q execcmd %q"` (`tryCacheWithID`)                                                                                              | fact             | `src/cmd/go/internal/test/test.go:1908`; Experiment E1                                                                   | ✓ (hw)                |
| L2  | Only passing package results are cached ("caches successful package test results"); `saveOutput` is called only in the `ok` branch, so a race re-executes                                                                                         | fact             | `test.go:120-125`, `:1742`; E1                                                                                           | ✓ (hw)                |
| L3  | `-count` is not in the cacheable-flag set; `-count=1` is the documented cache bypass ("The idiomatic way to disable test caching explicitly is to use -count=1")                                                                                  | quote            | `test.go:127-137`; E1 (`-count=1` re-ran a cached pass)                                                                  | ✓ (hw)                |
| L4  | **`GORACE` is invisible to the test cache** — `computeTestInputsID` special-cases only `GODEBUG`; a changed `GORACE` after a cached `-race` pass is silently not applied                                                                          | quote / behavior | `test.go:2020` (verbatim GODEBUG comment); `grep GORACE src/cmd/go/ -r` = ∅; E1                                          | ✓ (hw)                |
| L5  | Race UX: `WARNING: DATA RACE` + `--- FAIL` + `race detected during execution of test` + exit 1; `cmd/go` treats any nonzero exit as package fail and prints the trailing `FAIL`                                                                   | behavior         | `test.go:1748`, `:1767-1774`, `testing.go:1617`; E1                                                                      | ✓ (hw)                |
| L6  | Go's open hole: exit-status-0-without-result — `TODO(golang.org/issue/29062): tests that exit with status 0 without printing a final result should fail.`                                                                                         | quote            | `test.go:1772-1773` (verbatim)                                                                                           | ✓                     |
| L7  | `GORACE` options (`log_path`, `exitcode`=66, `halt_on_error`=0, `atexit_sleep_ms`=1000); custom `exitcode` still renders as plain `FAIL`; `atexit_sleep_ms` default visible (1.010 s vs 0.002 s)                                                  | fact / figure    | `go-race-detector-article.html` (saved); E1                                                                              | ✓ (hw)                |
| L8  | Parallelism is process-per-_package_ (`-p`), `-parallel` only within one binary; no report suppression — the `race` build tag excludes code, `GORACE` has no `suppressions=`                                                                      | fact             | `test.go:308-311`; race article § Excluding Tests                                                                        | ✓                     |
| L9  | Rust sanitizers are nightly `-Zsanitizer=…`; `-Zbuild-std` std-recompile requirement quoted ("strictly necessary for the correct operation of the tool")                                                                                          | quote            | `src/doc/unstable-book/src/compiler-flags/sanitizer.md`                                                                  | ✓                     |
| L10 | libtest runs tests as in-process threads (= `available_parallelism`), each named after the test; process-per-test only under `panic=abort`; attribution is incidental thread-name = test name                                                     | fact             | `library/test/src/lib.rs:383,395-399,695`; `tsan_report.cpp:55`                                                          | ✓                     |
| L11 | Toggling sanitizers thrashes cargo's cache: `RUSTFLAGS` is part of the unit fingerprint (mismatch → dirty)                                                                                                                                        | fact             | `cargo` `src/cargo/core/compiler/fingerprint/mod.rs:661,1097`                                                            | ✓                     |
| L12 | cargo-nextest is process-per-test ("now, and will always be, process-per-test", verbatim); the runner appends `["--exact", name, "--nocapture"]`                                                                                                  | quote            | `site/src/docs/design/why-process-per-test.md`; `nextest-runner/src/list/test_list.rs:1675`                              | ✓                     |
| L13 | nextest failure = per-test exit-code contract: `ExecutionResult` Pass/Leak/Fail/ExecFail/Timeout; any nonzero exit or signal = that one test, siblings unaffected; "Leak" = leaked handles                                                        | fact             | `nextest-runner/src/reporter/events.rs:1864-1896`; `features/leaky-tests.md`                                             | ✓                     |
| L14 | nextest carries zero sanitizer-specific config (`grep -rli sanitizer site/src/docs/` = ∅); generic hooks are target runners + experimental wrapper scripts                                                                                        | fact             | `configuration/wrapper-scripts.md`, `features/target-runners.md`                                                         | ✓                     |
| L15 | SwiftPM kinds `address/thread/undefined/scudo`; `-sanitize=` (swift) / `-fsanitize=` (clang) at compile+link; recompiles the package graph only, no stdlib rebuild                                                                                | fact             | `Sources/PackageModel/Sanitizers.swift:14-30`; `Swift/ClangModuleBuildDescription.swift`                                 | ✓                     |
| L16 | SwiftPM does no validation — `// FIXME: We need to throw from here if given sanitizers can't be enabled…`; UBSan-for-Swift is left to `swiftc`                                                                                                    | quote            | `Sanitizers.swift:39-42`                                                                                                 | ✓ (◯ swiftc behavior) |
| L17 | Process model: default serial one-process; `--parallel` = `ParallelTestRunner`, process-per-test-_case_ (`numJobs` = `activeProcessorCount`); XCTest-only                                                                                         | fact             | `Sources/Commands/SwiftTestCommand.swift:1590-1604`, `:403`, `:1602`                                                     | ✓                     |
| L18 | macOS wrap trick: `env["DYLD_INSERT_LIBRARIES"] = runtimes.joined(…)` injects `libclang_rt.<n>_osx_dynamic.dylib` into the `xctest` harness; env passthrough from `Environment.current`                                                           | fact             | `Utilities/TestingSupport.swift:353-368`, `:269`; `UserToolchain.swift:132-146`                                          | ✓                     |
| L19 | `std.valgrind` is a stdlib module with the client-request rotate-sequence asm per arch; larger surface than druntime's seven wrappers; no helgrind/DRD                                                                                            | fact             | `lib/std/valgrind.zig:5-138,317-319`                                                                                     | ✓                     |
| L20 | Valgrind support default-ON in Debug (`valgrind = optimize_mode == .Debug`); the compiler emits requests — safety `undefined` stores fill `0xaa` then `valgrindMarkUndef`                                                                         | fact / behavior  | `src/Package/Module.zig:132-142`; `src/codegen/llvm/FuncGen.zig:4742-4748,6429-6460`                                     | ✓                     |
| L21 | `-fsanitize-c` per-module default `.full` (Debug) / `.trap` (ReleaseSafe); minimal-runtime rationale quoted; Zig ships its own UBSan RT + builds TSan from source                                                                                 | quote            | `src/Package/Module.zig:252-264` (verbatim `:257-260`); `lib/ubsan_rt.zig`; `src/main.zig:1468`                          | ✓                     |
| L22 | `zig test` = in-process sequential, per-test fresh `DebugAllocator` → per-test leak count on `deinit()`; `.test_started` protocol + `active_test_index` → crash attribution                                                                       | behavior         | `lib/compiler/test_runner.zig:275-287,156-171`; `lib/compiler/Maker/Step/Run.zig:494-497,529`                            | ✓                     |
| L23 | Wrapper hooks are first-class CLI: `--test-cmd`/`--test-cmd-bin` wrap, `--test-runner` swaps, `--test-no-exec` splits build from run                                                                                                              | fact             | `src/main.zig:690-694`                                                                                                   | ✓                     |
| L24 | googletest's documented sanitizer integration = weak-callback `FAIL()` window; quote ("if a particular test triggers a sanitizer error, GoogleTest will report that it failed"); gtest ships no built-in hooks, only self-protect attrs           | quote            | `docs/advanced.md:2455-2483` (verbatim `:2481-2482`); `gtest-port.h:886-912`                                             | ✓                     |
| L25 | Death tests double as sanitizer-report capturers in compiler-rt: `EXPECT_DEATH(…, "AddressSanitizer:.*heap-use-after-free")` (77 uses) under `death_test_style="threadsafe"`                                                                      | fact             | `compiler-rt/lib/asan/tests/asan_test.cpp:195-199`; `asan_test_main.cpp:37`; `advanced.md:566-590`                       | ✓                     |
| L26 | Premature-exit-file: `ScopedPrematureExitFile` writes `"0"` at `RUN_ALL_TESTS` start, removes on normal completion; path from `TEST_PREMATURE_EXIT_FILE`                                                                                          | fact             | `googletest/src/gtest.cc:5164-5199`, `:5573`                                                                             | ✓                     |
| L27 | CTest MemCheck wraps each test with `cmake -E env *SAN_OPTIONS=log_path='…/MemoryChecker.<index>.log'` (test index); regex-per-tool parse → `DefectCount`                                                                                         | fact             | `Source/CTest/cmCTestMemCheckHandler.cxx:316-331,710-752,813-866`                                                        | ✓                     |
| L28 | `CTEST_MEMORYCHECK_SUPPRESSIONS_FILE` appended as `:suppressions=<file>` — the only surveyed runner with a first-class suppression setting; doc `log_path` warning quoted; `CMAKE_TEST_LAUNCHER` is the generic wrapper                           | quote            | `cmCTestMemCheckHandler.cxx:725-729`; `Help/variable/CTEST_MEMORYCHECK_SANITIZER_OPTIONS.rst`; `CMAKE_TEST_LAUNCHER.rst` | ✓                     |
| L29 | CTest doesn't trust exit codes — a log parsing to defects is a defect regardless of exit status; results feed `DynamicAnalysis` XML with `Checker="…"`                                                                                            | behavior         | `cmCTestMemCheckHandler.cxx:813-866,316-331`                                                                             | ✓                     |
| L30 | Bazel exit-code contract quoted ("writing any of the strings PASS or FAIL to stdout has no significance"); any nonzero exit = failure; `test.xml` wraps the log                                                                                   | quote            | `bazel-test-encyclopedia.html` (saved, fetched 2026-07-11)                                                               | ✓ 🌐                  |
| L31 | rules_cc `asan`/`lsan`/`tsan`/`ubsan` features hard-wire `-fno-omit-frame-pointer` **and `-fno-sanitize-recover=all`** on top of `-fsanitize=`                                                                                                    | fact             | `rules-cc-unix-toolchain-config.bzl:226-246,1745-1784` (saved, unpinned `main`)                                          | ≈                     |
| L32 | `--config=asan` is a `.bazelrc` convention, not a Bazel feature; Envoy exhibit (`--test_env=ASAN/UBSAN_OPTIONS`, `-no_san` tag filters, `signal_trace=disabled` quote)                                                                            | exposition       | `envoy-bazelrc.txt:258-353` (saved, unpinned `main`)                                                                     | ≈                     |
| L33 | Bazel env is hermetic; `--test_env` is the only door (verbatim); suppression files travel as runfiles-relative repo paths; `--run_under=<prefix>` is the wrapper hook                                                                             | quote            | `bazel-user-manual.html` (saved, fetched 2026-07-11)                                                                     | ✓ 🌐                  |
| L34 | pytest-valgrind windows per test: `error = get_valgrind_num_errs() - self.prev_errors > 0` + per-test `DO_LEAK_CHECK`/`COUNT_LEAKS` delta; 20× `gc.collect()` settle loop                                                                         | behavior         | `pytest_valgrind/plugin.py:241,243-253,232-237`; `pytest_valgrind/valgrind.c:19,26-33`                                   | ✓                     |
| L35 | Log segmentation uses `VALGRIND_PRINTF` markers writing the test nodeid between separator lines; the log is re-read incrementally to attach error text                                                                                            | fact             | `pytest_valgrind/valgrind.c:71`; `plugin.py:219-223,323-329`                                                             | ✓                     |
| L36 | Outcome replacement: dirty → `[VALGRIND ERROR]`/`[LEAK]`; failed-but-clean → **xfail** ("Error, but valgrind clean, using xfail"); per-test markers `valgrind_known_error/leak`; needs `PYTHONMALLOC=malloc`, one process                         | quote / behavior | `plugin.py:293,261-315`; `README.md`                                                                                     | ✓                     |
| E1  | Go `-race` UX battery: alternating `-race`/non-race caches independently; failing run not cached; `-count=1` bypass; **`GORACE` change did not invalidate a cached pass**; custom `exitcode` = plain `FAIL`; `atexit_sleep_ms` 1.010 s vs 0.002 s | figure           | Experiment E1 (`scratchpad/w5/`, go1.25.9, `nix shell nixpkgs#go`)                                                       | ✓ (hw)                |

## Discrepancies

Register cross-references are to the master register in
[`grounding/index.md`](./index.md) (`R9`, `R18`, `R25`, `R26`).

- **⚠ D-RI1 (register R18) — the D report-callback/marker seams are the documented
  industry pattern, not a bespoke hack.** googletest's _official_ "Sanitizer
  Integration" is exactly the `__tsan_on_report`/`__asan_on_error` → `FAIL()` seam
  the survey drove from D ([tsan.md][tsan] E8), and pytest-valgrind independently
  converged on `VALGRIND_PRINTF` markers + `COUNT_ERRORS`/`DO_LEAK_CHECK` deltas +
  the GC-settle loop — the same mechanisms [valgrind.md][valgrind] built its recipe
  on. The page states this in the [three-designs framing][designs] and the
  [patterns-for-sparkles][patterns] section (L24, L34-L36). `[source-verified]`
- **Note (register R9) — the Go repo path.** All Go locators are at `$REPOS/go/go`
  (`0153438`); `$REPOS/go` is an ecosystem directory, not the repo. Recorded so the
  L1-L8/E1 locators resolve.
- **⚠ D-RI2 (register R25) — recovered ASan errors leave exit code 0.** The runner
  half of this cross-page finding lives in the page's halt-vs-continue column and
  concern-4 mapping: a continue-mode runner must count reports (callback or log),
  not read exit codes. The tool-side mechanism is [asan.md][asan]'s; here it is one
  row of the design comparison (contrast Go's exit 66 and Valgrind's
  `--error-exitcode`). `[source-verified]`
- **⚠ D-RI3 (register R26) — `dub` launders the TSan exit code.** A test binary
  exiting 66 makes `dub` print "Program exited with code 66" and itself exit 2 —
  which is why the page's Bazel section states the dub-swallow "cannot happen" under
  an exit-code contract, and the "fail the test, never launder the exit code"
  decision row credits Go/nextest/Bazel/CTest for keeping the verdict distinguishable.
  The full false-green story is [sparkles-baseline.md][baseline]'s. `[source-verified]`
- **Note — Bazel/rules_cc/Envoy are fetched from unpinned `main` (L30-L33).** The
  Test Encyclopedia and user manual are live docs saved as captures
  (`bazel-test-encyclopedia.html`, `bazel-user-manual.html`); rules_cc and Envoy's
  `.bazelrc` were fetched from `main`/`master` at raw URLs (unpinned) and saved to
  `papers/sanitizers/`. Marked `🌐` (docs) / `≈` (unpinned configs) accordingly; the
  quoted contract text and the `-fno-sanitize-recover=all` line were read verbatim
  from the saved files.
- **Note — Swift UBSan-for-Swift is `◯` (L16).** No Swift toolchain on the primary
  box, so whether `swiftc` accepts `-sanitize=undefined` for Swift code is
  unverified; the SwiftPM plumbing (flag pass-through + the `// FIXME` non-validation)
  is source-verified. Flagged for the macOS bed ([macos-windows.md][macos-windows]).

**Net:** 0 substantive discrepancies remaining. Every source locator is at the
pinned SHAs above; the verbatim quotes (nextest process-per-test, the `-Zbuild-std`
requirement, the `GODEBUG` testlog comment, Go's `issue/29062` TODO, the googletest
`FAIL()` close, Zig's minimal-runtime rationale, CTest's `log_path` warning, and
Bazel's exit-code contract) are quoted exactly. The three `⚠` items are the
brief-hypothesis correction (R18) and the two cross-page exit-code findings (R25,
R26) the page now states correctly; the headline hardware result (L4/E1 — `GORACE`
invisible to the cache) is reproduced on `x86_64-linux`.

<!-- References -->

[tsan]: ../tsan.md
[asan]: ../asan.md
[valgrind]: ../valgrind.md
[baseline]: ../sparkles-baseline.md
[macos-windows]: ../macos-windows.md
[designs]: ../runner-integrations.md#the-three-attribution-designs
[patterns]: ../runner-integrations.md#patterns-for-sparkles
