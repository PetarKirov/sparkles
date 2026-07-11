# Sanitizer capability comparison

The survey's capstone: the **capability matrix** — the seven
[analysis concerns][spine] against every sanitizer family surveyed — the field's
consensus on how a test runner pins a finding to a test, the architectural
trade-offs behind the differences, the measured overheads, and the **delta
table** mapping each capability onto where [`sparkles:test-runner`][baseline]
stands today. It ends with the questions the survey could not close from this
hardware.

**Last reviewed:** July 11, 2026

Verification tags, abbreviated for the wide tables: `[hw]` =
`[hw-verified: x86_64-linux]` (AMD Ryzen 9 7940HX, kernel 6.18.26, LDC 1.41.0 /
DMD 2.112.1, GCC 15.2 runtimes) · `[hw·mac]` = `[hw-verified: aarch64-darwin]`
(Apple M4 Max, macOS 26.3.1 — **one** datum landed, the rest blocked) · `[src]`
= `[source-verified]` (pinned repos, see the deep-dives' Sources) · `[lit]` =
`[literature]`. There is **no** `aarch64-linux`, Windows, or MTE-silicon bed —
those cells carry `[src]`/`[lit]` by construction.

---

## The capability matrix

One row per [concern][spine], one column per tool family; each cell is a terse
verdict plus a D-reachability qualifier (toolchain/OS) and its strongest
verification tag. **Absent** cells are explicit — an absence is a finding, not a
blank. The matrix is split by column group so neither table scrolls: the
**compiler-instrumented** tools first, then the **no-recompile, hardware, and
sampling** tools.

### Compiler-instrumented tools (LLVM IR pass / clang CodeGen)

| Concern                                       | ASan + LSan                                                                                                                                                      | TSan                                                                                                                                  | MSan                                                                                                                                          | UBSan                                                                                                                                   |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| **Defect classes and blind spots**            | heap/stack/global OOB, UAF, stack-use-after-return; leaks (LSan). Blind: [GC-pool UAF][c-gc]; LSan false-positives GC-referenced `malloc` `[hw]`                 | data races (`core.atomic` modeled); thread leaks, mutex misuse. Blind: fence-only lock-free, GC memory; deadlock detector dead `[hw]` | uninitialized-value reads ([definedness][c-def]). Blind: fresh GC `mmap` reads _defined_ → false negatives `[hw]`                             | 40 UB checks, but D covers most (defined wrap, `RangeError`, `@safe`); residue: out-of-range shifts, `int.min/-1`, misalignment `[src]` |
| **Instrumentation model and recompile scope** | [LLVM IR pass][c-locus]; user-code-only rebuild (no [instrumented world][c-iworld]). LDC via gcc-rt fallback; not DMD `[hw]`                                     | LLVM IR pass; rebuild checked modules only. LDC-only among D compilers `[hw]`                                                         | LLVM IR pass **+ [instrumented-world requirement][c-iworld]**; nixpkgs LDC link-fails (gcc has no MSan), links via `-conf=` `clang_rt` `[hw]` | **clang CodeGen only, no IR pass** → unreachable from LDC, GDC (check-empty), DMD `[src]`                                               |
| **D and druntime interaction**                | clean GC baseline; `defaultTraceHandler` leaks force `detect_leaks=0`; fake-stack GC-scan hazard (unproven) `[hw]`                                               | 2 druntime noise classes (2-line supp); **GC-heavy multithreaded [livelock][c-stw]** (watchdog); fibers sound `[hw]`                  | GC memory reads _defined_ (false negatives); uninstrumented callee → false positive `[hw]`                                                    | N/A — no instrumentation exists to interact `[src]`                                                                                     |
| **Runtime control and report capture**        | [halts][c-halt] by default; recover needs `-fsanitize-recover=address` + `halt_on_error=0`, then **exits 0** (count reports); report callback, `log_path` `[hw]` | report-and-continue; exit **66** at finalize; `__tsan_on_report`/`_on_finalize`/`_default_options` (need `--export-dynamic`) `[hw]`   | `-fsanitize-recover=memory` supported; shared `*SAN_OPTIONS` surface `[src]`                                                                  | N/A — `libubsan` is installed but nothing feeds it `[hw]`                                                                               |
| **Symbolization and suppressions**            | GCC rt self-symbolizes `file:line`; **no D demangle** → mangled globs; `-fsanitize-blacklist` / `@noSanitize` `[hw]`                                             | GCC rt self-symbolizes; mangled globs; `race:`/`signal:` [types][c-supp] `[hw]`                                                       | compiler-rt symbolization (`llvm-symbolizer`); no D demangle `[src]`                                                                          | N/A `[src]`                                                                                                                             |
| **Test-runner integration semantics**         | three [attribution designs][ri-table] reproduced from D; `log_path` per-process file `[hw]`                                                                      | Go count-delta [windowing][c-window] reproduced from D; **dub launders 66 → 2** `[hw]`                                                | no per-test story — unusable by default (a finding-with-locator, not a TODO) `[hw]`                                                           | N/A — no D finding to attribute `[src]`                                                                                                 |
| **Platform, toolchain, and overhead**         | LDC-only; Linux `[hw]`; darwin exit **134** (dylib) `[hw·mac]`; Windows DLL but exceptions broken (#3760); ~2× `[lit]`                                           | LDC-only; ~5× time, 2× memory; darwin TSan exists (unrun); **no Windows link path** `[hw]`/`[src]`                                    | LDC via `-conf=`/tarball only; unusable without an instrumented world; no default, no Windows `[hw]`                                          | unreachable on every compiler and platform `[src]`                                                                                      |

### No-recompile, hardware, and sampling tools

| Concern                                       | Valgrind `memcheck`                                                                                                                                                               | `helgrind` / `DRD`                                                                                                                                     | HWASan / Arm MTE                                                                                                                                         | GWP-ASan                                                                                           |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Defect classes and blind spots**            | addressability **+ [definedness][c-def]** (`UninitValue`/`UninitCondition`, the class ASan lacks); leaks. Blind: no [redzones][c-redzone] (small in-block overrun), GC-UAF `[hw]` | data races + lock-order (helgrind) / lock contention (DRD) + API misuse. Blind: `core.atomic`/`SpinLock` invisible; miss short serialized races `[hw]` | ASan classes by [tag mismatch][c-tag] (probabilistic); MTE = hardware spatial+temporal heap safety. No definedness/UB; GC-UAF still blind `[hw]`/`[src]` | heap OOB + UAF on **[sampled][c-sample]** allocations only; probabilistic; no stack/global `[hw]`  |
| **Instrumentation model and recompile scope** | [DBI][c-locus] (VEX JIT), **no recompile**, every compiler incl. DMD; `-g` adds `file:line` `[hw]`                                                                                | DBI, no recompile, every compiler `[hw]`                                                                                                               | HWASan = IR pass + tagging `malloc`; MTE = hardware, only stack tagging rebuilt. **Not in LDC's `-fsanitize=` set** `[src]`                              | sampling allocator, no recompile; `-fsanitize=scudo` (no `gwp-asan` flag) `[hw]`                   |
| **D and druntime interaction**                | `etc.valgrind` [client requests][c-creq]; GC noise tiny (3-entry supp); **breaks under DMD shared Phobos**; `gc.d:3907` dead code `[hw]`                                          | clean at `-t 1`, drown at `-t>1` (GC `SpinLock`); nixpkgs `default.supp` over-blankets libc `[hw]`                                                     | **GC scan through an untagged pointer faults** (hw-proven); druntime must untag; fiber tag-boundary open `[hw]`                                          | **C-heap only** — never GC memory (`mmap` pools) `[src]`                                           |
| **Runtime control and report capture**        | CLI-only, report-and-continue always; `--error-exitcode` opt-in; client requests `[hw]`                                                                                           | CLI; report-and-continue; `--error-exitcode` `[hw]`                                                                                                    | `HWASAN_OPTIONS` mirror ASan, exit **99**; MTE has no `*SAN_OPTIONS` (kernel `prctl`; ASYNC `si_addr=0`) `[hw]`/`[src]`                                  | `SCUDO_OPTIONS=GWP_ASAN_*`; `SIGSEGV` exit **139**; `Recoverable` mode `[hw]`                      |
| **Symbolization and suppressions**            | **built-in DWARF reader + D demangler** (categorical win); protocol-4 XML; mangled suppressions `[hw]`                                                                            | built-in demangle; XML `Race` kind; mangled suppressions `[hw]`                                                                                        | tag dump around the fault; compiler-rt symbolize, no D demangle; MTE SYNC precise / ASYNC unattributable `[hw]`/`[src]`                                  | alloc/free/access stacks as raw addresses; external symbolizer; no D demangle `[hw]`               |
| **Test-runner integration semantics**         | [wrapper-and-parse][c-wrap] over XML; `VALGRIND_PRINTF` marker windows; forces `-t 1` + `--fair-sched=yes` `[hw]`                                                                 | `-t 1` forced; helgrind default + DRD second opinion; **not a TSan replacement** for short races `[hw]`                                                | report shape = ASan's; x86 aliasing **fork-unsafe** (no [process-per-test][c-ppt]); MTE = deployment, N/A `[src]`                                        | **not a unit-test mode** — sampling ≠ deterministic; production/soak only `[src]`                  |
| **Platform, toolchain, and overhead**         | compiler-independent; **DMD's only path**; Linux `[hw]`; **dead on macOS > 10.13**; ~4.4× marginal `[hw]`                                                                         | compiler-independent; helgrind 2.1× / DRD ~2.2×; Linux; dead on macOS `[hw]`                                                                           | HWASan: aarch64 native / x86 LAM (AMD fatal) / x86 aliasing (runs here); MTE silicon = Pixel 8 / AmpereOne, **not M4** `[hw]`/`[lit]`                    | reachable via `-fsanitize=scudo` (C heap); Linux `[hw]`; production (Android/Chrome/Apple) `[lit]` |

> [!NOTE]
> Three findings recur down every column and are the matrix's real spine.
> **First:** the sanitizer set ends at the Linux border **except
> AddressSanitizer** — ASan crosses to macOS (dylib) and Windows (DLL, though
> D exceptions break under it); everything else is Linux-only, dead (Valgrind on
> macOS), or absent (arm64 runtimes). **Second:** UBSan (and TySan) are
> unreachable from _every_ D compiler because their checks live in clang
> CodeGen with no IR pass to borrow — an architectural wall, not a packaging
> gap ([ubsan.md][ubsan]). **Third:** D's GC pools come from `mmap`, so a
> use-after-free _inside_ GC memory is invisible to every
> [allocator-interception][c-alloc] tool — ASan, `memcheck`, HWASan, GWP-ASan
> alike — and only `memcheck`'s [`etc.valgrind`][c-creq] path narrows it
> ([the GC memory blind spot][c-gc]).

---

## The integration consensus: three attribution designs

The field's runners ([runner-integrations.md][ri]) converge on exactly **three**
ways to pin a finding to the test that caused it, and — the load-bearing survey
result — all three were already reproduced from D. This is the condensed view;
the full per-ecosystem breakdown is
[runner-integrations.md's integration-semantics table][ri-table], which this page
does not duplicate.

| Design                                  | Who uses it (surveyed)                                        | The one lesson for sparkles                                                                                                                                                                        |
| --------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [In-process report windowing][c-window] | Go `go test -race`, googletest weak-callback, pytest-valgrind | Maps onto sparkles' existing `TaskPool` runner; needs continue-semantics; `-t 1` (or per-worker windows) bounds the cross-test blur — the seam Experiment E8 drove from D                          |
| [Process-per-test isolation][c-ppt]     | cargo-nextest, SwiftPM `--parallel`, Bazel                    | Its own machinery (`extract`/`driver`) is ≈90% of it; it is what fixes the runner's SEGV-kills-the-run gap, with _zero_ sanitizer-specific code                                                    |
| [Wrapper-and-parse][c-wrap]             | CTest MemCheck, pytest-valgrind's log side                    | The `--valgrind` mode, over XML protocol 4 instead of regex-over-log; suppression files become checked-in config (CTest's `CTEST_MEMORYCHECK_SUPPRESSIONS_FILE` is the only first-class precedent) |

The single hardest consensus to swallow: **"nonzero exit = failed test" survives
no contact with the tools.** ASan halts and a _recovered_ run exits 0; TSan
reports-and-continues and exits 66 only at finalize; HWASan exits 99, RTSan 43,
GWP-ASan `SIGSEGV`s to 139, TySan continues to 0, darwin ASan aborts to 134, and
Valgrind passes the child's own code through unless `--error-exitcode` is set.
The full table is [concepts § halt vs recover][c-halt]; the runner consequence is
that a `--sanitize` mode must **count reports, not read exit codes**.

---

## Architectural trade-offs

The axes that explain the matrix's differences, and where each tool family lands.

| Axis                             | Poles                                                              | Where each lands                                                                                                                                                                                                                           |
| -------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [Instrumentation locus][c-locus] | compile-time IR pass ↔ clang CodeGen ↔ DBI ↔ hardware/sampling     | ASan/TSan/MSan/HWASan: LLVM IR passes LDC inherits · UBSan/TySan: clang CodeGen, **unreachable from D** · `memcheck`/`helgrind`/`DRD`: DBI, no recompile, **DMD's only path** · MTE: hardware · GWP-ASan: sampling allocator               |
| Recompile scope                  | user code only ↔ [instrumented world][c-iworld] ↔ none             | ASan/TSan: user modules suffice (uninstrumented druntime is a _coverage_ gap, not a false positive) · MSan: **all** code incl. libc or false positives · Valgrind/GWP-ASan/MTE: nothing recompiled                                         |
| Halt policy                      | halt-on-first ↔ report-and-continue                                | ASan/HWASan/RTSan halt (recover flags to survive) · TSan/`memcheck`/TySan continue by default · exit codes irreconcilable (1 / 66 / 99 / 43 / 0 / 139 / 134), so [count reports][c-halt]                                                   |
| Attribution boundary             | in-process window ↔ process edge ↔ parsed side-channel             | windowing (Go/gtest → sparkles' `TaskPool`) · [process-per-test][c-ppt] (nextest/Swift/Bazel → `extract`/`driver`) · [wrapper-and-parse][c-wrap] (CTest, the `--valgrind` XML mode)                                                        |
| Symbolization provenance         | runtime self-symbolizes ↔ external symbolizer ↔ built-in demangler | GCC libsanitizer self-symbolizes via `libbacktrace` but **never demangles D** · `clang_rt` needs `llvm-symbolizer` (demangles only `D main`) · Valgrind ships its own DWARF reader **and** D demangler                                     |
| GC-memory visibility             | allocator-intercepted ↔ `mmap`-blind                               | every allocator-interception tool is blind to GC pools ([the blind spot][c-gc]); only `memcheck` closes it (source-into-app `-debug=VALGRIND`); TSan still _races-checks_ GC memory because it instruments the accesses, not the allocator |

---

## Measured overhead

All figures `[hw]` on the `x86_64-linux` bed, taken as recorded on the tool
pages ([asan.md][asan], [tsan.md][tsan], [valgrind.md][valgrind]); no darwin or
Windows timings were measured (hardware blocked).

| Tool / mode | Marginal slowdown (hot code)                 | Fixed startup | Notes                                                                                |
| ----------- | -------------------------------------------- | ------------- | ------------------------------------------------------------------------------------ |
| ASan        | ~2×                                          | —             | the docs' figure; makes it a test-time, not production, tool `[lit]`                 |
| LSan        | ≈0 until the exit-time scan                  | —             | folds into ASan or runs standalone `[lit]`                                           |
| TSan        | ≈5× (`:versions` 49 ms vs 8.8 ms), 2× memory | —             | low end of the documented 5–15× because the tests are tiny `[hw]`                    |
| `memcheck`  | 4.4× (6.4× with `--track-origins`)           | ~0.25 s       | headline "10–50×" is the whole-program figure; hot-loop marginal is far lower `[hw]` |
| `helgrind`  | 2.1×                                         | ~0.21 s       | terse dedup; adds a lock-order class `[hw]`                                          |
| `DRD`       | ~2.2×                                        | —             | quieter on druntime primitives, floods per-access on a real race `[hw]`              |

The number that dominates the `--valgrind` design is not a slowdown factor but a
**scheduler pathology**: sparkles' in-process `TaskPool` under Valgrind's default
unfair scheduler turns a 4 ms `:base` suite into a **156.5 s** `memcheck` run at
`-t auto` (spread 12.5–180 s), versus **1.16 s** at `-t 1` and **1.27 s** at
`-t auto --fair-sched=yes`. This is why the `--valgrind` mode forces `-t 1` and
passes `--fair-sched=yes` ([valgrind.md § runner integration][valgrind-runner]).

---

## The delta table: the survey vs. the sparkles baseline

Each survey capability against [today's runner][baseline], with the
[proposal][proposal] milestone that closes the gap. The runner has **no**
sanitizer support today, so every "sparkles today" cell but one is an absence —
which is the audit's whole point ([baseline § what the audit will
check][baseline-gaps]).

| Capability (best practice found)                                                           | sparkles today                                                                               | Gap                                                                      | Closes in                 |
| ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------- |
| Whole-closure instrumented rebuild ([custom buildType proven][dtool-runner], not `DFLAGS`) | ❌ no `--sanitize` mode; only channel (`DFLAGS`) is a [false green][baseline-dub]            | no way to build-and-run a package under instrumentation                  | [M1][p-m1]                |
| Per-test [attribution][ri-table] (3 designs, 2 hw-proven from D)                           | ❌ none; a finding lands on stderr unattributed, and a crash [kills the run][baseline-crash] | can't say _which_ test raced/leaked/faulted                              | [M2][p-m2] (+ [M4][p-m4]) |
| Halt-vs-recover policy (a [per-tool table][c-halt])                                        | ❌ none — no notion of a tool's exit/halt semantics                                          | "nonzero exit = failed" assumption would misread every tool              | [M1][p-m1] / [M2][p-m2]   |
| Suppression management (2-line TSan + 3-entry `memcheck` sets [authored][tsan-supp])       | ❌ none in-tree                                                                              | druntime noise floor unhandled; no user-suppression composition          | [M2][p-m2] / [M3][p-m3]   |
| Capability advertisement (a [`CapabilityReport`][proposal] sketch)                         | ⚠️ `skipTest` exists ([the degradation shape][baseline-attrs]), but no sanitizer seam        | absences aren't enumerated ("DMD has no `-fsanitize`; use `--valgrind`") | [capability seam][p-seam] |
| Crash isolation (process-per-test ≈90% built via [`extract`][baseline-crash] machinery)    | ❌ in-process only; a SIGSEGV loses the summary and cancels siblings                         | one bad test dooms the whole run                                         | [M4][p-m4]                |
| Report rendering (`TestResult` needs a `findings` field)                                   | ❌ `Thrown[]` only ([no field to land in][baseline-model])                                   | a sanitizer report has nowhere to render per test                        | [M1][p-m1]                |
| Parallelism policy (`-t 1` / `--fair-sched` [findings][tsan-runner])                       | ❌ `totalCPUs` default, no per-tool policy                                                   | TSan livelocks and `memcheck` goes pathological at default parallelism   | [M2][p-m2] / [M3][p-m3]   |

---

## Open questions & gaps

What stayed `[src]`/`[lit]` for lack of hardware, plus the known-open hazards the
runner must carry forward. Each is one honest line.

1. **MSan needs an instrumented world sparkles does not build.** MSan is a
   finding-with-a-locator, not a feature: usable only against an instrumented
   druntime+Phobos (buildable in ~3 min via `ldc-build-runtime`) plus real
   compiler-rt; on the default nixpkgs path it does not even link
   ([d-toolchain § MSan][dtool-msan]).
2. **No MTE silicon is in reach.** The project's only aarch64 box is an Apple M4,
   which has no MTE (MIE/EMTE is A19-only); every MTE claim is kernel-doc `[src]`
   or `[lit]`, and the direct `sysctl` probe was itself blocked
   ([hardware-assisted § silicon reality][hw-silicon]).
3. **Windows has no hardware bed at all.** The whole Windows column is MS Learn
   docs plus LDC/Dr. Memory source — never `[hw-verified]`
   ([macos-windows § Windows][mw-windows]).
4. **The darwin transcripts are blocked, not written.** The `mac-bsn` D-on-darwin
   sanitizer runs (TSan, LSan `detect_leaks`, fiber UAR, the `MallocNanoZone`
   warning text) were blocked by an ssh-key/gpg-agent pinentry wall; only the
   Apple-clang C ASan smoke test landed. A zero-thought rerun kit is staged
   ([macos-windows][macos-windows]).
5. **The event-horizon TSan run is unexplained.** The repo's 2026-07-10 history
   claims "51 tests ASan-clean" from a `DFLAGS=… dub test` recipe that, on
   today's dub, compiles **zero** tests — either dub semantics changed or the
   recipe never ran as written; undecidable from this box
   ([baseline § the historical seed][baseline-seed]).
6. **`-allinst`'s necessity under sanitizers is unconfirmed.** No
   sanitizer-specific `-allinst` failure was reproducible for `:versions`/`:base`;
   the event-horizon "`-allinst` fix" applies to a seed package that lives only
   on `feat/event-horizon` ([d-toolchain § instrumentation model][dtool-instr]).
7. **The fake-stack GC-root hazard is real but unreproduced.**
   `scanStackForASanFakeStack` exists precisely because unscanned UAR fake frames
   drop GC roots, yet four attempts did not trigger a premature collection (LLVM
   declined to fake-stack the test frames) ([d-toolchain § SupportSanitizers][dtool-support]).
8. **`__lsan_register_root_region` over GC pools is untested.** The API (present
   in both GCC and `clang_rt` runtimes) would turn the GC-referenced-`malloc` LSan
   false positive into a true negative, but was never exercised as a druntime hook
   ([asan § LeakSanitizer and the D GC][asan-lsan]).
9. **The `helgrind`/`DRD` `-t>1` suppression set was not authored.** Both tools
   are clean at `-t 1` and drown at `-t>1` (the GC `SpinLock` is invisible to
   pthread-modeling detectors); a parallel-mode suppression file was not written —
   the mode should force `-t 1` instead ([valgrind § runner integration][valgrind-runner]).
10. **UBSan's residual slice has no D tool.** Out-of-range shifts, `int.min / -1`,
    and misaligned access are genuinely uncovered in D and out of every surveyed
    tool's reach; closing them means an LDC `gen/` emitter or targeted language
    checks, not a sanitizer port ([ubsan § if UBSan-for-D mattered][ubsan-what]).
11. **RTSan is adoptable but blocked on an LLVM bump.** It is a real IR pass an
    LDC port could reach, but needs LLVM ≥ 20 and LDC 1.41 ships LLVM 18
    ([hardware-assisted § RTSan][hw-rtsan]).

---

## Sources

Aggregated from the deep-dives; every cell's locator lives in its page's Sources
section (repos pinned by SHA there). The primary reads behind the matrix are
LLVM `compiler-rt`/clang at [`73802c2e`][llvm-src], Valgrind at `218cee2f` (tag
`VALGRIND_3_26_0`), LDC `v1.41.0`, DMD `e6baf474`, and dub `5efed360`; the
runner-integration columns add Go, Rust/cargo-nextest, SwiftPM, Zig, googletest,
CMake, and pytest-valgrind at the SHAs [runner-integrations.md][ri] pins.
Direct experiment evidence: the eleven runnable [example probes][examples] and
the one `mac-bsn` Apple-clang smoke test quoted in [macos-windows.md][macos-windows].

<!-- References -->

[spine]: ./#the-seven-concerns
[baseline]: ./sparkles-baseline.md
[baseline-gaps]: ./sparkles-baseline.md#what-the-audit-will-check
[baseline-crash]: ./sparkles-baseline.md#what-a-crash-looks-like-today
[baseline-dub]: ./sparkles-baseline.md#the-dub-build-path
[baseline-model]: ./sparkles-baseline.md#the-data-model-and-reporting-seams-no-place-for-a-finding
[baseline-attrs]: ./sparkles-baseline.md#marker-udas-and-skiptest-the-sanitize-precedent
[baseline-seed]: ./sparkles-baseline.md#the-historical-event-horizon-seed-and-its-invalidated-recipe
[proposal]: ./integration-proposal.md
[p-seam]: ./integration-proposal.md#_2-capability-seam-first-sanitizercapabilityreport
[p-m1]: ./integration-proposal.md#_3-m1-sanitize-kind-the-recompile-mode
[p-m2]: ./integration-proposal.md#_4-m2-per-test-attribution-and-halt-vs-continue-policy
[p-m3]: ./integration-proposal.md#_5-m3-valgrind-the-wrapper-mode-dmd-compatible
[p-m4]: ./integration-proposal.md#_6-m4-isolate-process-per-test
[asan]: ./asan.md
[asan-lsan]: ./asan.md#leaksanitizer-and-the-d-gc
[tsan]: ./tsan.md
[tsan-supp]: ./tsan.md#symbolization-and-suppressions
[tsan-runner]: ./tsan.md#test-runner-integration-semantics
[ubsan]: ./ubsan.md
[ubsan-what]: ./ubsan.md#if-ubsan-for-d-mattered-what-it-would-take
[d-toolchain]: ./d-toolchain.md
[dtool-runner]: ./d-toolchain.md#test-runner-integration-semantics
[dtool-instr]: ./d-toolchain.md#instrumentation-model-what-must-be-recompiled-and-how
[dtool-msan]: ./d-toolchain.md#msan-the-instrumented-world-requirement
[dtool-support]: ./d-toolchain.md#d-and-druntime-interaction
[valgrind]: ./valgrind.md
[valgrind-runner]: ./valgrind.md#runner-integration-semantics
[ri]: ./runner-integrations.md
[ri-table]: ./runner-integrations.md#the-integration-semantics-table
[macos-windows]: ./macos-windows.md
[mw-windows]: ./macos-windows.md#windows-msvc-ldc-dr-memory
[hardware-assisted]: ./hardware-assisted.md
[hw-silicon]: ./hardware-assisted.md#silicon-reality-where-mte-actually-exists
[hw-rtsan]: ./hardware-assisted.md#rtsan-the-realtimesanitizer
[examples]: ./examples/asan-heap-uaf.d
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[c-locus]: ./concepts.md#instrumentation-locus
[c-iworld]: ./concepts.md#instrumented-world-requirement
[c-gc]: ./concepts.md#the-gc-memory-blind-spot
[c-def]: ./concepts.md#definedness-vs-addressability
[c-redzone]: ./concepts.md#redzone
[c-tag]: ./concepts.md#memory-tagging
[c-sample]: ./concepts.md#sampling-allocator
[c-alloc]: ./concepts.md#allocator-interception
[c-stw]: ./concepts.md#stop-the-world-root-scanning
[c-halt]: ./concepts.md#halt-vs-recover
[c-supp]: ./concepts.md#suppression
[c-creq]: ./concepts.md#client-request
[c-window]: ./concepts.md#report-windowing
[c-ppt]: ./concepts.md#process-per-test-isolation
[c-wrap]: ./concepts.md#wrapper-and-parse
