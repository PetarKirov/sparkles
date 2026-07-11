# Grounding ledger — `macos-windows.md`

Claim-by-claim verification of `docs/research/sanitizers/macos-windows.md` against
the pinned trees LDC [`ldc@v1.41.0`] (driver/CMake/tests read via `git show v1.41.0:`
on the local `feat/wasm` checkout `f4d2f831`), compiler-rt
[`llvm-project@73802c2e`], valgrind [`valgrind@218cee2f`] (tag `VALGRIND_3_26_0`),
and Dr. Memory [`drmemory@3d2b5f9`] (2025-12-12), plus MS Learn's MSVC sanitizer
docs (`ms.date` 2026-05-28, retrieved 2026-07-11) and official LDC 1.41.0 release
artifacts (downloaded, listed, deleted 2026-07-11). The **single** hardware datum is
the recon Apple-clang ASan smoke test on `mac-bsn` (Apple **M4 Max**, macOS
**26.3.1**, SIP on, uid 501). `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy (flagged in page) · ◯ not locally groundable / open · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

## Claim ledger

Row IDs mirror the W6 sub-report's claim IDs (`C*` = a survey claim, `A*`/`B*` =
macOS/Windows part). `[source-verified]` rows cite the pinned local trees;
`[literature]` rows cite retrieved-and-saved web docs (🌐); the one `[hw-verified:
aarch64-darwin]` row is the recon smoke test.

| #    | Claim (short)                                                                                                                                                  | Type       | Source (local + locator)                                                                                                                                                                       | Status |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| C3   | LDC on Darwin links sanitizers **dylib-only** + two `-rpath`, else appends `-fsanitize=` to `cc`                                                               | quote      | `ldc@v1.41.0:driver/linker-gcc.cpp:331-371,495-521` (_"On Darwin, the only option is to use the shared library."_)                                                                             | ✓      |
| C4   | Official LDC osx package ships `libldc_rt.{asan,lsan,tsan}.dylib` (renamed); nixpkgs LDC ships none                                                            | fact       | `CMakeLists.txt:820-935` (`copy_compilerrt_lib`); `tar -tf ldc2-1.41.0-osx-universal.tar.xz` (lib-arm64/ + lib-x86_64/)                                                                        | ✓      |
| C4b  | nix darwin LDC = only `ldc_rt.dso.o`; `ldc2.conf` compiler-rt dir **dangles**; darwin compiler-rt 21.1.7 ships full osx set → cc-fallback provenance           | fact       | `nix store ls/cat --store https://cache.nixos.org` (E-M3b: `ldc.outPath` lib + `ldc2.conf`; `llvmPackages.compiler-rt.outPath` = `libclang_rt.{asan,lsan,tsan,ubsan,rtsan}_osx_dynamic.dylib`) | ✓      |
| C5   | Darwin ASan default `abort_on_error=1` → `SIGABRT`/exit 134; TSan feature-ON for Darwin, OFF for Windows                                                       | quote      | `ldc@v1.41.0:tests/sanitizers/lit.local.cfg` (_"On Darwin, ASan defaults to `abort_on_error=1`…"_; _"there's no Windows TSan (yet?)"_)                                                         | ✓      |
| C6   | `MallocNanoZone=0` is compiler-rt's own recommended Darwin sanitizer env                                                                                       | quote      | `llvm-project@73802c2e:compiler-rt/unittests/lit.common.unit.cfg.py:45-53` (_"Disable libmalloc nano allocator … rdar://80086125"_)                                                            | ✓      |
| C22  | Upstream `CAN_SANITIZE_LEAKS 1` on `SANITIZER_APPLE && __aarch64__`; Apple-clang enablement **untested**                                                       | fact       | `compiler-rt/lib/lsan/lsan_common.h:36-57`; Apple-clang side = open hw question (E-M1 BLOCKED)                                                                                                 | ✓ / ◯  |
| C1   | Valgrind dead > macOS 10.13: `configure.ac` hard-error; platforms page caps AMD64/Darwin 11.0, no arm64                                                        | quote      | `valgrind@218cee2f:configure.ac` (darwin case); `valgrind.org/info/platforms.html` (_"X86/Darwin (10.5 to 10.13)…"_)                                                                           | ✓ 🌐   |
| C2   | Only Apple-Silicon Valgrind = out-of-tree `LouisBrunner/valgrind-macos` fork (one maintainer)                                                                  | fact       | `papers/sanitizers/valgrind-macos-fork-readme.md` (retrieved 2026-07-11)                                                                                                                       | ✓ 🌐   |
| C7   | Eleven batch-1 probes Linux-locked at 3 layers (`platforms "linux"`, `version (linux)`, `core.sys.linux.dlfcn`)                                                | fact       | probe sources at repo HEAD `379e4c7a` (grep transcript)                                                                                                                                        | ✓      |
| C23  | Apple clang 21.0.0 ASan on M4 Max catches heap-UAF, `file:line` symbolization, exit **134** (`Abort trap: 6`)                                                  | behavior   | recon smoke test 2026-07-11 ~11:05 (`recon-environment.md §7`; E-M4)                                                                                                                           | ✓ (hw) |
| C8   | MSVC `/fsanitize` = `address` + `kernel-address` + `fuzzer` **only**; x86/x64, Win10+                                                                          | quote      | MS Learn asan / `/build/reference/fsanitize` (_"Support is limited to x86 and x64…"_; the future-sanitizers solicitation)                                                                      | ✓ 🌐   |
| C9   | MSVC ASan = compiler-rt lineage: `clang_rt.asan_dynamic-{i386,x86_64}.lib/.dll`; LLVM symbolizer; `==PID==ERROR:` shape                                        | fact       | MS Learn asan / asan-building (saved `msvc-asan.html`, `msvc-asan-building.html`)                                                                                                              | ✓ 🌐   |
| C10  | Interception = runtime **hotpatch**, can fail on short prologue → `debugbreak`/halt; x64 shadow offset **runtime-assigned**                                    | quote      | MS Learn asan-runtime (_"…many hotpatching techniques… too short for a jmp… debugbreak and halts."_); asan-shadow-bytes                                                                        | ✓ 🌐   |
| C11  | Recover analog = `ASAN_OPTIONS=continue_on_error` (1/2, `COE_LOG_FILE`); no compile flag; dedup by stack; cancels on uncatchable AV                            | quote      | MS Learn asan-continue-on-error (_"CONTINUE CANCELLED - Deadly Signal. Shutting down."_)                                                                                                       | ✓ 🌐   |
| C12  | LDC Windows ships `ldc_rt.asan.lib` + thunks + fuzzer; `// TODO: remaining sanitizers`; artifact: lib32/lib64 asan libs, **libarm64/ = `ldc_rt.dso.obj` only** | quote      | `driver/linker-msvc.cpp:76-98`; `CMakeLists.txt:903-918`; `7z l ldc2-1.41.0-windows-multilib.7z`                                                                                               | ✓      |
| C13  | LSan not available from LDC on Windows                                                                                                                         | quote      | `ldc@v1.41.0:CHANGELOG.md` (_"New LeakSanitizer support via `-fsanitize=leak` (not (yet?) supported on Windows). (#4005)"_)                                                                    | ✓      |
| C14  | ldc #3760 "Windows: `-fsanitize=address` doesn't work with exceptions" — open since 2021-06-12                                                                 | behavior   | github.com/ldc-developers/ldc/issues/3760 (fetched 2026-07-11); context #3742                                                                                                                  | ✓ 🌐   |
| C15  | Dr. Memory = DynamoRIO DBI; defect classes incl. uninit reads + Windows handle leaks / GDI                                                                     | quote      | `drmemory@3d2b5f9:README:29-40` (defect-class enumeration verbatim)                                                                                                                            | ✓      |
| C16  | Dr. Memory surface: `results.txt`, `-results_to_stderr` default-true, `-batch`, `-exit_code_if_errors` default **0**; block suppressions                       | fact       | `drmemory/optionsx.h:150-176`; `docs/using.dox` §sec_results; `docs/reports.dox` §page_suppress                                                                                                | ✓      |
| C17  | Dr. Memory maintenance: last official 2.6.0 (2022) + weekly cronbuilds; repo alive (HEAD 2025-12-12)                                                           | fact       | clone HEAD date `3d2b5f9`; DynamoRIO/drmemory releases page (fetched 2026-07-11)                                                                                                               | ✓      |
| C18  | Dr. Memory on D binaries (reasoning): GC `VirtualAlloc` blind spot; no D demangler; CodeView/PDB callstacks                                                    | exposition | README + `using.dox`/`reports.dox` reasoning; **no Windows hardware**                                                                                                                          | ≈      |
| C19  | GDC/MinGW = no `libsanitizer` (link error); llvm-mingw ships ASan but doesn't help D                                                                           | fact       | msys2/MINGW-packages #3163; mingw-w64 thread; llvm.org D51885                                                                                                                                  | ✓ 🌐   |
| C20  | WinDbg TTD = record/replay **companion**, not a sanitizer; no validity checking; ~10–20× record overhead                                                       | fact       | MS Learn TTD overview (saved `windbg-ttd-overview.html`)                                                                                                                                       | ✓ 🌐   |
| C21  | LLVM 20 eliminated static Windows asan runtime (dynamic-DLL-only + per-CRT thunks); why LDC grew `>= 2000` branch                                              | fact       | llvm/llvm-project PR #93770 (lists.llvm.org 2024-05); `linker-msvc.cpp` `LDC_LLVM_VER >= 2000` guard                                                                                           | ✓ 🌐   |
| C21b | MSVC ASan incompatibilities: `/RTC*`, incremental link, E&C, OpenMP, managed, UWP; **coroutines exempt**; no ignorelist                                        | quote      | MS Learn asan-known-issues (_"Coroutines are incompatible with AddressSanitizer…"_; _"Special case list files are unsupported"_)                                                               | ✓ 🌐   |
| V1   | Verdict: all 11 probes keep `platforms "linux"`; darwin = port not toggle; per-probe table + darwin-probe sketch                                               | exposition | W6 §E-V (structural facts (i)–(v)); `ci` enforces `platforms` (`app.d:1070-1085`)                                                                                                              | ✓      |
| MW1  | The one-liner: sanitizer columns end at the Linux border **except AddressSanitizer**                                                                           | opinion    | synthesis of C1–C23 (ASan crosses to macOS dylib + Windows DLL; rest Linux/dead/absent)                                                                                                        | ◯      |

## Discrepancies & surprises (all surfaced in the page)

- **D1 — MSVC UAR is a compile-time opt-in, the inverse of `clang_rt`.**
  Stack-use-after-return "requires an extra compiler option
  (`/fsanitize-address-use-after-return`)" and "isn't available by only setting
  `ASAN_OPTIONS`", while clang always emits the fake-stack instrumentation and gates
  it at run time. The page's Windows runtime-control section keys the feature matrix
  on compile flags, not env vars. `[literature]` (MS Learn asan, "Differences with
  Clang 12.0"). ⚠→surfaced.
- **D2 — Windows interception can fail at run time and halts.** The hotpatch
  `debugbreak` is a "sanitizer-infrastructure" halt class with no ELF equivalent,
  called out in the page's instrumentation-model section. `[literature]`. ⚠→surfaced.
- **D3 — Dr. Memory preserves the app's exit code by default** (`-exit_code_if_errors`
  default `0`), the opposite footgun family from ASan's always-fail; surfaced in the
  Windows test-runner-integration section. `[source-verified]`.
- **D4 — LDC ships working Windows ASan libs, yet D exceptions break under them**
  (#3760, open since 2021): "ships ≠ works for idiomatic D." Surfaced as the page's
  `> [!WARNING]`. `[literature]`.
- **D5 — Official LDC ships `libldc_rt.lsan.dylib` for arm64 macOS** even though
  Apple-clang LSan is historically absent (C22) — the official-LDC leak story on Apple
  Silicon may beat Apple's own; surfaced in the macOS defect-classes section as the
  open LSan question. `[source-verified]`.
- **D6 — Windows-on-ARM64 LDC packages ship zero sanitizer runtimes** (`libarm64/` =
  `ldc_rt.dso.obj` only) — the Windows sanitizer column is silently x86/x64-only for D
  too; surfaced in the Windows platform/toolchain section. `[source-verified]`.

## Verification note — blocked hardware

**The macOS column is mechanism-verified, not run-verified**, and the page says so in
its opening `> [!IMPORTANT]` scope box and its closing `> [!NOTE]`. The planned
`mac-bsn` hardware experiments (E-M1 Apple-clang C fixtures; E-M2 the exact
`MallocNanoZone` warning text; E-M3 nix-LDC link mechanism + D fixture catches, LSan
`detect_leaks`, fiber UAR) were **BLOCKED** for the whole session: the only usable ssh
key sat locked in `gpg-agent` and every signing attempt spawned a `pinentry` with no
surface to render on (`journalctl --user -u gpg-agent`: repeated
`ssh sign request failed: Timeout <Pinentry>`). Consequently:

- **Only one macOS row is `[hw-verified: aarch64-darwin]`** — C23, the recon
  Apple-clang ASan heap-UAF smoke test that landed before the key locked.
- **Every other macOS run claim is `[source-verified]` or `[literature]`**, and the
  page marks each as _pending hardware verification_. No claim was upgraded past its
  verification level.
- **The rerun kit is staged** (`scratchpad/w6/fixtures/`: `uaf.c`/`race.c`/`ub.c`/
  `leak.c` + `run-clang.sh`; `heap_uaf.d`/`stack_uar.d`/… + `run-ldc.sh`; one-shot
  `drive-mac.sh`). The open item is registered as a **Q-row** in the survey's
  grounding register; a zero-thought re-run (once `ssh mac-bsn true` unlocks the key)
  splices the transcripts in.
- **The Windows column has no hardware at all** — every Windows row is `[literature]`
  (MS Learn / issues / PRs, 🌐) or `[source-verified]` (LDC source, Dr. Memory clone,
  release-artifact listings). Nothing Windows-tagged is `[hw-verified]`.

## Claims weakened / not made

- **C18 (Dr. Memory on D)** is `[source-verified reasoning]`, not a run — tagged `≈`
  and phrased as expectation, since there is no Windows hardware. The GC-blind-spot and
  no-D-demangler consequences follow from the README/docs + the survey's Linux GC
  findings, not from a Windows execution.
- **C24–C30** from the sub-report (TSan/UBSan darwin transcripts, `MallocNanoZone`
  warning text, nix-LDC D-fixture catches, LSan `detect_leaks`, fiber UAR) were
  **not claimed** — they are the BLOCKED experiment set and appear only as _pending
  hardware verification_ prose, never as ledger ✓ rows.
- **Overhead** — no darwin sanitizer timings and no Windows hardware, so the
  "Platform, toolchain, and overhead" concern's _overhead_ half is explicitly
  unanswered in both columns rather than estimated.

**Net:** 0 fabrications. The macOS link mechanism, packaging, and defaults are
`[source-verified]` against LDC v1.41.0 / compiler-rt `73802c2e` / release artifacts /
`cache.nixos.org` NAR listings; the Windows surface is `[literature]` (MS Learn,
issues, PRs) + `[source-verified]` (LDC source, Dr. Memory `3d2b5f9`, artifact
listings). **Exactly one hardware datum** (C23) carries `[hw-verified: aarch64-darwin]`
— the recon Apple-clang ASan smoke test; all richer darwin behavior is _pending
hardware verification_ (rerun kit staged, open Q-row). Six discrepancies/surprises
(D1–D6), all surfaced in the page; no unresolved contradiction.

<!-- References -->

[`ldc@v1.41.0`]: https://github.com/ldc-developers/ldc/tree/v1.41.0
[`llvm-project@73802c2e`]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[`valgrind@218cee2f`]: https://sourceware.org/git/?p=valgrind.git;a=tree
[`drmemory@3d2b5f9`]: https://github.com/DynamoRIO/drmemory
