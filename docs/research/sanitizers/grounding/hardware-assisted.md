# Grounding ledger — `hardware-assisted.md`

Claim-by-claim verification of `docs/research/sanitizers/hardware-assisted.md`
(HWASan, Arm MTE, GWP-ASan, RTSan, TySan) against the pinned trees
compiler-rt/clang/llvm [`llvm-project@73802c2e`], the kernel [`linux@e43ffb69e043`]
(v7.1-rc6), and LDC [`ldc@v1.41.0`] (source greps also against the checked-out
`v1.42.0-91-gf4d2f831c3`, feat/wasm). Hardware experiments recorded on **Linux
6.18.26**, **AMD Ryzen 9 7940HX** (Zen 4 — no Intel LAM), **clang 21.1.7**
(`nix shell nixpkgs#llvmPackages_latest.clang`), **gcc 15.2.0**, **LDC 1.41.0**.
`$REPOS = /home/petar/code/repos`; W7 scratch =
`…/76cecf08-0ea4-4457-897c-ec8969bf77bf/scratchpad/w7/`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

## Claim ledger

| #   | Claim                                                                                                                                        | Type       | Source (local + locator)                                                                                           | Status         |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------ | -------------- |
| H1  | HWASan: 1 tag byte per 16-byte granule (`kShadowScale = 4`, `kShadowAlignment = 1<<4`)                                                       | fact       | `compiler-rt/lib/hwasan/hwasan_mapping.h:37-38`                                                                    | ✓              |
| H2  | Tag placement per-arch: aarch64 TBI 8 bits @56; x86_64 LAM 6 @57; x86_64 aliasing 3 @39; riscv64 8 @56                                       | fact       | `hwasan.h:40-71` (incl. TBI / "Intel LAM" comments)                                                                | ✓              |
| H3  | Not aarch64-only: x86_64 (LAM+alias) + riscv64 compiled; else `#error Architecture not supported`                                            | fact       | `hwasan.h:56-71`                                                                                                   | ✓              |
| H4  | TBI design quote (_"AArch64 has Address Tagging … smaller memory overhead …"_)                                                               | quote      | `clang/docs/HardwareAssistedAddressSanitizerDesign.rst:22-27` (verbatim)                                           | ✓              |
| H5  | Heap tagged by `malloc`; `free` retags; stack tagged in prologue/epilogue; most globals tagged                                               | fact       | design doc `:128-159`                                                                                              | ✓              |
| H6  | aarch64 enables tagged-addr ABI via `prctl(PR_SET_TAGGED_ADDR_CTRL, PR_TAGGED_ADDR_ENABLE, …)`                                               | fact       | `hwasan_linux.cpp:187-197`; kernel `tagged-address-abi.rst:71-93`                                                  | ✓              |
| Q1  | `PR_SET_TAGGED_ADDR_CTRL` … `PR_TAGGED_ADDR_ENABLE` … "Default status is disabled" (verbatim)                                                | quote      | `linux/Documentation/arch/arm64/tagged-address-abi.rst:71-78`                                                      | ✓              |
| H7  | x86_64 probes LAM via `arch_prctl(ARCH_GET_MAX_TAG_BITS)`, enables `ARCH_ENABLE_TAGGED_ADDR`; else FATAL                                     | fact       | `hwasan_linux.cpp:140-226`; runtime string `:226`                                                                  | ✓ (hw, E1/E8)  |
| H8  | The compiler-rt "unsubmitted patch (August 2022)" comment is **stale** — constants are mainline                                              | ⚠ fact     | comment `hwasan_linux.cpp:145-149` vs `linux/arch/x86/include/uapi/asm/prctl.h:28-30` (`0x4001/2/3`)               | ⚠ (D-H1)       |
| H9  | Aliasing mode heap-only & fork-unsafe (_"only safe for applications that do not fork"_)                                                      | quote      | design doc `:281-285`; driver flag `clang/include/clang/Options/Options.td:2618`                                   | ✓              |
| H10 | Default error exit code 99 (`cf.exitcode = 99`)                                                                                              | fact       | `compiler-rt/lib/hwasan/hwasan.cpp:84`                                                                             | ✓ (hw, E1-E3)  |
| H11 | GC-scan hazard: untagged read of tagged memory faults; escape hatches `__hwasan_tag_memory/_pointer`                                         | behavior   | `include/sanitizer/hwasan_interface.h:40-44`; Experiment 3                                                         | ✓ (hw, E3)     |
| H12 | GC pools stay untagged (mmap'd, never through tagging malloc) → reverse direction benign                                                     | behavior   | `core/internal/gc/os.d:111-117` (batch-1 W3); consequence of H5                                                    | ≈              |
| H13 | LDC has no `hwaddress`: `-fsanitize=` = address\|fuzzer\|leak\|memory\|thread; pass exists in LLVM → driver work                             | fact       | `ldc@v1.41.0 driver/cl_options_sanitizers.cpp:182-188`                                                             | ✓              |
| H14 | Android production precedent since Android 10 (2019); overhead ~2× CPU, +40-50% code, +10-35% RAM                                            | lit        | `papers/sanitizers/android-hwasan-docs.html` (retrieved 2026-07-11)                                                | 🌐             |
| H15 | GCC 15 ships `-fsanitize=hwaddress` (`libhwasan.so.0`); GDC inherits the common-driver flag in principle                                     | fact       | Experiment 8; `-fsanitize=` is a GCC common-driver option                                                          | ✓ (hw, E8)     |
| H16 | GCC docs self-contradict on hwaddress targets (x86-64+`-mlam`+AArch64 vs "only AArch64")                                                     | ⚠ fact     | `papers/sanitizers/gcc-15.1-instrumentation-options.html` (both paragraphs)                                        | ⚠ (D-H2)       |
| M1  | MTE = 4-bit alloc tag / 16-byte granule in physical mem, checked in HW vs VA bits 59-56; built on TBI                                        | quote      | `linux/Documentation/arch/arm64/memory-tagging-extension.rst:16-24`                                                | ✓              |
| Q2  | MTE model quote (_"MTE is built on top of the ARMv8.0 … TBI … 4-bit allocation tag … bits 59-56 …"_)                                         | quote      | `memory-tagging-extension.rst:17-22` (verbatim)                                                                    | ✓              |
| M2  | Userspace surface: `PROT_MTE` on mmap/mprotect; per-thread TCF via `prctl` (`PR_MTE_TCF_{NONE,SYNC,ASYNC}`+asym)                             | fact       | `memory-tagging-extension.rst:33-90`                                                                               | ✓              |
| Q3  | SYNC = `SEGV_MTESERR`, `si_addr = <fault>`; ASYNC = `SEGV_MTEAERR`, `si_addr = 0` (faulting addr unknown)                                    | quote      | `memory-tagging-extension.rst:68-77` (verbatim)                                                                    | ✓              |
| M3  | HWASan is the software emulation of MTE (checks in code, 1B shadow); MTE checks in hardware                                                  | quote      | design doc `:292-294` (_"SPARC ADI and Arm MTE implement a similar tool mostly in hardware"_)                      | ✓              |
| M4  | Arm MTE whitepaper freely downloadable (no DDI-0487-style gate); + arXiv 1802.09517                                                          | lit        | `papers/sanitizers/arm-mte-whitepaper.pdf`, `memory-tagging-arxiv-1802.09517.pdf` (saved 2026-07-11)               | ✓ (local file) |
| M5  | Silicon: Pixel 8/Tensor G3 first handset (Nov 2023); AmpereOne first datacenter (2024); Neoverse N2/V2 IP                                    | lit        | Project Zero HTML (saved); arXiv 2511.17773 (saved); Arm product pages (pointer only)                              | 🌐             |
| M6  | Apple **M4 has no MTE**; MIE/EMTE debuts A19 / iPhone 17 (Sept 2025), no M-series                                                            | lit        | `papers/sanitizers/apple-memory-integrity-enforcement-blog.html` (2025-09-09)                                      | 🌐 / ⚠ (D-M1)  |
| G1  | GWP-ASan: sampled `1/SampleRate` allocs on guard pages; OOB→guard, UAF→unmapped; SEGV handler prints stacks                                  | fact       | `compiler-rt/lib/gwp_asan/guarded_pool_allocator.h:141-147`; arXiv 2311.09394 p.2                                  | ✓              |
| G2  | Defaults `Enabled=true`, `MaxSimultaneousAllocations=16`, `SampleRate=5000`; `Recoverable` mode exists                                       | fact       | `compiler-rt/lib/gwp_asan/options.inc:22-56`                                                                       | ✓              |
| Q4  | _"The probability (1 / SampleRate) that an allocation is selected … Default is 5000."_                                                       | quote      | `gwp_asan/options.inc:30-33` (verbatim)                                                                            | ✓              |
| Q5  | GWP-ASan abstract quote (_"…we added an 'if' statement to a 36-year-old idea and made it work at scale."_)                                   | quote      | arXiv 2311.09394v2 p.1 (saved PDF)                                                                                 | ✓              |
| G3  | No `-fsanitize=gwp-asan`; reached via `-fsanitize=scudo`; scudo compiles hooks under `GWP_ASAN_HOOKS`                                        | fact       | `clang/include/clang/Basic/Sanitizers.def:196`; `scudo/standalone/combined.h:33-246`                               | ✓              |
| G4  | Standalone pieces ship (`optional/backtrace_linux_libc/segv_handler_posix/options_parser`) but no turnkey flag                               | fact       | `compiler-rt/lib/gwp_asan/optional/` (dir listing)                                                                 | ✓              |
| G5  | D verdict: C-heap only — GC pools mmap'd, never via malloc; two integration shapes (scudo C-heap / druntime GC)                              | behavior   | `core/internal/gc/os.d:111-117` (batch-1 W3 claim 17); consequence                                                 | ≈              |
| G6  | Non-Recoverable default → report + SIGSEGV (exit 139); Recoverable reports once, continues                                                   | behavior   | `options.inc:22-56`; Experiment 6                                                                                  | ✓ (hw, E6)     |
| G7  | Production integrations: Android (scudo), Chrome, Apple ("mobile, desktop, and server")                                                      | lit        | arXiv 2311.09394 p.1                                                                                               | ✓ (paper)      |
| R1  | Model: `[[clang::nonblocking]]` fns are realtime; intercepted call → `unsafe-library-call`; blocking → `blocking-call`                       | quote      | `clang/docs/RealtimeSanitizer.rst:9-19`; `rtsan_interceptors_posix.cpp`; `rtsan_checks.inc:19-20`                  | ✓              |
| Q6  | RTSan model quote (_"RTSan considers any function marked with `[[clang::nonblocking]]` … it raises an error."_)                              | quote      | `RealtimeSanitizer.rst:12-16` (verbatim)                                                                           | ✓              |
| R2  | Introduced in LLVM/Clang 20                                                                                                                  | lit        | `papers/sanitizers/llvm-20.1.0-clang-release-notes.html` (clone depth-1, no git history)                           | 🌐             |
| R3  | **Real IR pass**, not CodeGen: clang maps effect→`sanitize_realtime` attr; pass inserts `__rtsan_realtime_enter/exit`                        | fact       | `clang/lib/CodeGen/CodeGenFunction.cpp:849-856`; `llvm/lib/Transforms/Instrumentation/RealtimeSanitizer.cpp:70-80` | ✓ (hw, E4)     |
| R4  | IR proof: `w7/rtsan.ll` shows `sanitize_realtime` on `process()`, enter/exit pair, `rtsan.module_ctor`                                       | figure     | Experiment 4 (`rtsan.ll`)                                                                                          | ✓ (hw, E4)     |
| R5  | LDC-adoptable: UDA→attr + schedule pass (LLVM≥20) + link `libclang_rt.rtsan`; contrast UBSan/TySan (CodeGen-only)                            | exposition | R3 + `ubsan.md` locus story                                                                                        | ≈              |
| R6  | LDC has zero rtsan plumbing; bundles LLVM 18.1.8; pass only in LLVM ≥ 20; build accepts LLVM 18→>21                                          | fact       | grep `gen/`,`driver/` (ldc @ f4d2f831c3); `CMakeLists.txt:32,407,565`                                              | ✓              |
| R7  | `RTSAN_OPTIONS`: `halt_on_error` default **true**, `print_stats_on_exit`, `suppressions`, `suppress_equal_stacks`; exit **43**               | fact       | `rtsan_flags.inc:19-24`; `rtsan_checks.inc:19-20`; `rtsan_flags.cpp:38` (`cf.exitcode = 43`)                       | ✓ (hw, E4)     |
| R8  | Suppression kinds `call-stack-contains:` / `function-name-matches:`                                                                          | fact       | `rtsan_suppressions.cpp`; `rtsan_checks.inc:19-20`                                                                 | ✓              |
| R9  | **-O1 DCE trap**: malloc/free pair DCE'd before instrumentation → no report (exit 0); `-O0` catches, exit 43                                 | ⚠ behavior | Experiment 4 (`rtsan-rerun1` vs `rtsan-rerun1-O0`; `rtsan.ll`)                                                     | ⚠ (D-R1, hw)   |
| R10 | `@nogc` is a compile-time cousin, not equivalent (static no-GC-alloc vs runtime no-syscall/heap/lock)                                        | exposition | `RealtimeSanitizer.rst:20-24` (FunctionEffectAnalysis)                                                             | ✓              |
| T1  | Model: 8 shadow bytes/byte (type-descriptor ptr); compares TBAA descriptor vs shadow                                                         | quote      | `clang/docs/TypeSanitizer.rst:22-58`                                                                               | ✓              |
| Q7  | _"The runtime uses 8 bytes of shadow memory … for every byte of accessed data …"_                                                            | quote      | `TypeSanitizer.rst:36-38` (verbatim)                                                                               | ✓              |
| T2  | Introduced **experimental** in LLVM/Clang 20                                                                                                 | lit        | llvm-20.1.0 release notes (saved)                                                                                  | 🌐             |
| T3  | `halt_on_error` default **false** → reports and continues, exit 0 (opposite of RTSan)                                                        | fact       | `compiler-rt/lib/tysan/tysan_flags.inc:21`; `tysan.cpp:276`                                                        | ✓ (hw, E5)     |
| T4  | **LDC emits no `!tbaa`**: `tbaa-test.ll` has zero TBAA nodes; only generic `-enable-tbaa`/`-struct-path-tbaa` cl-opts; no emission in `gen/` | fact       | Experiment 7 (`tbaa-test.ll`); `ldc driver/cl_options.cpp:910,1001`                                                | ✓ (hw, E7)     |
| T5  | D has no strict-aliasing rule (spec doesn't adopt C TBAA) → TySan N/A by construction; sibling of UBSan locus                                | exposition | D spec (no type-based aliasing); `ubsan.md` locus                                                                  | ≈              |
| X1  | All five runtimes realized in nixpkgs compiler-rt 21.1.7 (`hwasan,hwasan_aliases,gwp_asan,rtsan,tysan` + scudo)                              | fact       | dir listing `/nix/store/…-compiler-rt-libc-21.1.7/lib/x86_64-unknown-linux-gnu/`                                   | ✓ (hw)         |
| X2  | KASAN `HW_TAGS` = kernel MTE consumer ("only … arm64 … MTE"; in-kernel TBI; "only reports the first found bug")                              | quote      | `linux/Documentation/dev-tools/kasan.rst:28-30,395-399`                                                            | ✓              |
| X3  | KCSAN = compiler-instrumented data-race detector, unrelated to MTE; cachegrind/callgrind/massif → cpu-pmu                                    | exposition | `kasan.rst` (grep); cross-tree note                                                                                | ≈              |

## Experiments (exact commands)

Env for all local runs: bare PATH + `nix shell nixpkgs#llvmPackages_latest.clang`
(clang 21.1.7, x86_64-unknown-linux-gnu), glibc 2.40-224, kernel 6.18.26, AMD Ryzen 9
7940HX (Zen 4 — no Intel LAM), gcc 15.2.0, LDC 1.41.0. cwd = W7 scratch. `uaf.c` =
`malloc(4*int); p[0]=42; free(p); read p[0]`. "(1st)" = artifact from an interrupted
first attempt the same box/day, command reconstructed and/or re-run.

| #   | Command                                                                                                                        | Result                                                                                                                                                                                              | Artifact                                      | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ------ |
| E1  | `clang -fsanitize=hwaddress -Wl,--no-relax -g uaf.c -o hwasan-lam-rerun && ./hwasan-lam-rerun; echo $?`                        | `FATAL: HWAddressSanitizer requires a kernel with tagged address ABI.` exit **99** (AMD, no LAM). Without `--no-relax`: link error `failed to convert GOTPCREL relocation … relink with --no-relax` | `lam-rerun.out` (1st `lam-run.out`)           | ✓ (hw) |
| E2  | `clang -fsanitize=hwaddress -fsanitize-hwaddress-experimental-aliasing -g uaf.c -o hwasan-alias-rerun && ./hwasan-alias-rerun` | `HWAddressSanitizer: tag-mismatch … READ of size 4 … tags: 01/b4 (ptr/mem) … Cause: use-after-free`, exit **99**                                                                                    | `alias-rerun.out` (1st `alias-run.out`)       | ✓ (hw) |
| E3  | `gc-scan-hazard.c`: malloc, strip aliasing tag bits 39-41, read through untagged alias                                         | `tagged=0x590200000000 untagged=0x580200000000 tag=2` then `tag-mismatch … tags: 00/02(00) (ptr/mem)`, exit **99**                                                                                  | `gc-scan-hazard.c`, `.out`                    | ✓ (hw) |
| E4  | `clang -fsanitize=realtime -O1 rtsan-fixture.c` (and `-O0`); fixtures with escaping global `sink`                              | `-O1`: clean, exit **0** (DCE); `-O0`: `RealtimeSanitizer: unsafe-library-call / Intercepted call to real-time unsafe function \`malloc\` …`, exit **43**                                           | `rtsan2.out`, `rtsan-rerun1`(-O0), `rtsan.ll` | ✓ (hw) |
| E5  | `clang -fsanitize=type -O0 -g tysan-fixture.c && ./a` (and `-O1`)                                                              | `-O0`: `TypeSanitizer: type-aliasing-violation … WRITE of size 4 … type float accesses … type int`, continues, exit **0**; `-O1`: no report, exit **0**                                             | `tysan-rerun-O0.out`, `tysan-rerun-O1.out`    | ✓ (hw) |
| E6  | `clang -fsanitize=scudo -g uaf.c -o uaf-scudo-rerun`; `SCUDO_OPTIONS=GWP_ASAN_SampleRate=1 ./uaf-scudo-rerun`                  | `*** GWP-ASan detected a memory error *** / Use After Free at … 16-byte allocation …` + alloc/dealloc/access stacks, SIGSEGV exit **139**. Control (no env): `read after free: 42`, exit 0          | `scudo-rerun.out` (1st `scudo-gwp.out`)       | ✓ (hw) |
| E7  | `ldc2 --output-ll tbaa-test.d` (LDC 1.41.0; two-field struct, int/double loads)                                                | `tbaa-test.ll` has **zero** `!tbaa` nodes (only typeinfo/ident metadata)                                                                                                                            | `tbaa-test.d`, `tbaa-test.ll`                 | ✓ (hw) |
| E8  | `gcc -fsanitize=hwaddress uaf.c -o uaf-gcc-hwasan && ./uaf-gcc-hwasan` (gcc 15.2.0)                                            | compiles+links `libhwasan.so.0` on x86_64 **without** `-mlam`; runtime `FATAL … tagged address ABI.`, exit **99**                                                                                   | `gcc-hwasan-run.out`                          | ✓ (hw) |
| E9  | `ssh mac-bsn 'sysctl hw.optional.arm'` (M4 MTE probe)                                                                          | **blocked**: `sign_and_send_pubkey: signing failed … agent refused operation; Permission denied` — M4-no-MTE stays `[literature]` (M6)                                                              | `mac-sysctl.out` (empty)                      | ◯      |

## Discrepancies

- **⚠ D-H1 — the compiler-rt LAM comment is stale (register row).** `hwasan_linux.cpp:145-149`
  calls the x86_64 tag-bits `arch_prctl` API "a currently unsubmitted patch to the Linux
  kernel (as of August 2022)", but at the pinned kernel the constants are **mainline**
  (`arch/x86/include/uapi/asm/prctl.h:28-30`: `0x4001/0x4002/0x4003`). The blocker on this
  box is hardware (AMD has no LAM), not the kernel API. Stated in the page's `> [!NOTE]`.
  `[source-verified]`
- **⚠ D-R1 — RTSan violations can be optimized away (register row).** At `-O1` the fixture's
  `malloc(16); free(p)` pair is dead-code-eliminated **before** the IR pass runs, so RTSan
  reports nothing (exit 0); `-O0` catches it (exit 43). The docs do not warn about this. Any
  RTSan test/probe must build unoptimized or make the call escape. Stated in the page's
  RTSan `> [!WARNING]`. `[hw-verified: x86_64-linux]` (E4).
- **⚠ D-H2 — GCC's own docs self-contradict on hwaddress targets.** The `-fsanitize=address`
  paragraph says hwaddress works on "x86-64 (only with `-mlam=u48`/`-mlam=u57`) and AArch64";
  the `-fsanitize=hwaddress` paragraph says "currently only available on AArch64". Observed
  behavior (gcc 15.2.0 accepts x86-64 without `-mlam`, E8) matches neither paragraph cleanly.
  Documented in the page's concern 7. `[source-verified]` + `[hw-verified: x86_64-linux]`
- **⚠ D-M1 — the M4-no-MTE probe was blocked, finding stands on Apple's announcement.**
  The direct `sysctl` on `mac-bsn` failed (SSH key refused non-interactive signing, E9), so
  M4-no-MTE (M6) rests on the Apple MIE blog (names only A19 / iPhone 17), not a hardware
  probe. Trivially confirmable in an interactive macOS session later. Flagged, not resolved.
  `[literature]` ◯
- **Note — halt semantics are inverted between the two new sanitizers.** RTSan
  `halt_on_error=true` / exit 43; TySan `halt_on_error=false` / exit 0 on a violation. A
  `--sanitize` runner must not assume "nonzero exit = failed test" uniformly. Stated across
  the RTSan and TySan sections. `[hw-verified: x86_64-linux]`
- **Note — distinct default exit codes** (HWASan 99, RTSan 43, vs ASan 1 / TSan 66) are a
  crude which-sanitizer-fired signal for a runner. Stated in concern 6. `[hw-verified: x86_64-linux]`
- **Note — HWASan `-O0 -g` link needs `-Wl,--no-relax`** on this binutils (GOTPCREL vs hwasan
  globals instrumentation) — looks like a broken toolchain but is not. Footnoted in concern 7.
  `[hw-verified: x86_64-linux]` (E1).

## Web-fallback / not-locally-groundable

- **H14, M5, R2, T2 (🌐).** Android overhead numbers, the silicon roster (Pixel 8 / AmpereOne
  / Neoverse), and the LLVM-20 introduction dates are grounded in saved HTML captures
  (`papers/sanitizers/*.html`, retrieved 2026-07-11) — the llvm-project clone is depth-1, so
  release history is not re-derivable from git. Retrieval provenance in
  `papers/sanitizers/w7-retrieval-notes.md`.
- **M4, M6, Q5 (local file).** The Arm MTE whitepaper, GWP-ASan paper, and Apple MIE blog are
  saved PDFs/HTML; quotes transcribed from the local copies. (`file` mis-reports the GWP-ASan
  PDF as "2 page(s)" — a linearized-PDF quirk; `pdfinfo` says 9, and the bytes match a fresh
  arXiv fetch.)
- **H12, G5, T5, R5, X3 (≈).** Derived consequences / exposition (GC-pool untagging, C-heap-only
  reachability, D's absent strict-aliasing, LDC-adoptability, KCSAN unrelatedness) — no single
  line to point at; each rests on a cited source plus a stated inference.

**Net:** 0 fabrications. Two verbatim kernel-doc quotes (Q1 tagged-address ABI, Q2/Q3 MTE
model + SYNC/ASYNC), plus the HWASan design-doc TBI quote (H4), the RTSan doc quote (Q6),
the GWP-ASan `SampleRate`/abstract quotes (Q4/Q5), and the TySan shadow quote (Q7) are
transcribed from the pinned trees and saved papers. All hardware behaviors (E1-E8) were
reproduced on this x86_64 box; E9 (M4 MTE) is the one blocked probe, and M6 is honestly
`[literature]`. **Two register-row discrepancies** carried by the brief (D-H1 stale LAM
comment, D-R1 `-O1` DCE trap) plus the GCC-docs self-contradiction (D-H2) and the blocked M4
probe (D-M1) are all stated in the page. No probe ships (none of the five is D-reachable);
the experiment transcripts are the primary evidence.

<!-- References -->

[llvm-project@73802c2e]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[linux@e43ffb69e043]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/arch/arm64/memory-tagging-extension.rst
[ldc@v1.41.0]: https://github.com/ldc-developers/ldc/tree/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549
