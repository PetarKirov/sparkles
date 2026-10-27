---
status: draft
owner: sparkles
reviewed: 2026-10-26
---

# The Sparkles toolchain — Acceptance and evidence

Each requirement of the [specification](./SPEC.md), [WASI](./wasi.md) and
[WebAssembly modules](./wasm-modules.md) pages maps to a scenario, an oracle,
and evidence. Evidence states follow
[Writing Specification Docs](../../guidelines/spec-docs.md#keep-evidence-scoped-and-honest):
`verified` means the named check passed for the named configuration,
`partial` names what is missing, and `planned` rows name the design, not code
that exists. A skipped check is not a pass. Evidence in dlang.nix and the
forks is cited by link or by name, since it lies outside this tree.

## Oracles

- **Compiler behavior** — the forks' own test suites (LDC's lit and
  `dmd-testsuite`, LLVM's lit subsets for the changed backends), whose
  expectations are written independently of the change under test.
- **Runtime libraries** — the upstream druntime and Phobos unittests, run on
  each host and under wasmtime for each production WASI preview.
- **Sanitizer, profile and fuzzer runtimes** — programs with a planted
  defect (an out-of-bounds read, an unreachable branch never executed, a
  crash on a marked input) whose detection is the expected result.
- **Closure contents** — `nix path-info -r` and `nix why-depends` on the
  built derivation: an absent path is checked by asking for it.
- **WebAssembly modules** — a differential oracle: the same `sparkles:base`
  and `sparkles:core-cli` functions compiled natively, on a fixed corpus
  (TCM9). It detects differences between the builds, not defects the two
  builds share.

## Requirement evidence

| Requirement | Scenario                                                                                              | Oracle                                         | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status   |
| ----------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| TC1         | Every D compilation in the flake resolves to the fork's LDC                                           | Store paths of the compilers used              | `nix/d-toolchain.nix` and `nix/packages/build-d-wasm-module.nix` use dlang.nix's fork packages (#691). Missing: a check that enumerates every compiler use                                                                                                                                                                                                                                                                                                                          | partial  |
| TC2         | LDC, clang and runtimes report the same LLVM revision                                                 | `ldc2 --version`, `clang --version`            | `ldc2` reports LLVM `24.0.0git`, and so does `clang`: LDC is built against the development view of the `llvm-spirv-vulkan` build that `clang-sparkles` wraps, one LLVM build at `24d1ae35`                                                                                                                                                                                                                                                                                          | verified |
| TC3         | Each behavior change in the forks carries a regression test                                           | Review of the branches against upstream        | The forks' sparkles/main histories. Missing: a recorded review of every commit                                                                                                                                                                                                                                                                                                                                                                                                      | partial  |
| TC4         | One glibc and one GCC runtime across toolchain and programs                                           | `nix why-depends` on a second glibc            | dlang.nix's nixpkgs follows Sparkles' (TC-M2): `hue`, `terminal` and `ci` on x86_64-linux hold glibc 2.44 and the GCC 16 runtime only, where `hue` held glibc 2.40 and 2.42 and the GCC 11, 14 and 15 runtimes before                                                                                                                                                                                                                                                               | verified |
| TC5         | The lock evaluates with every Nix version CI uses                                                     | Content hash of the fetched inputs             | dlang.nix fetches the LLVM fork as a shallow Git checkout; CI run of #691 evaluated it with Nix 2.35. Missing: a check across Nix versions                                                                                                                                                                                                                                                                                                                                          | partial  |
| TC6–TC8     | C, C++ and Objective-C build with the wrapped clang; LDC built by it; no unwrapped driver on any PATH | `command -v` in each build environment         | dlang.nix check `toolchain-clang` builds and runs C, C++20 and Objective-C programs with `clang-sparkles`; `ldc-vulkan` builds in `clangStdenv-sparkles` against LLVM's development view, which holds no compiler driver. On x86_64-linux and aarch64-darwin; the macOS shell's `CC` is `clang-sparkles` (`dub test :base` passes there). Missing: aarch64-linux (TC21)                                                                                                             | partial  |
| TC9         | Tools share one LLVM library; only listed tools installed                                             | Installed file list against the list below     | The tools link the shared libLLVM and libclang-cpp; the install shrank from 4.3 GiB to 1.5 GiB. Missing: `bin/` still holds tools off the list (clang-cl, llc, opt, the ClangIR tools), dropped at the next rebuild (WTD36)                                                                                                                                                                                                                                                         | partial  |
| TC10–TC12   | Each runtime of the per-host list detects its planted defect                                          | Planted-defect programs                        | dlang.nix check `toolchain-runtimes` on x86_64-linux: AddressSanitizer (D and C), UndefinedBehaviorSanitizer, ThreadSanitizer and MemorySanitizer report their planted defects; the profile runtime writes a profile `llvm-profdata` merges; libFuzzer finds the crashing input; XRay writes its log. On aarch64-darwin the same check covers ASan (D and C), UBSan, profile and libFuzzer, and LDC's sanitizer lit tests cover TSan and LSan. Missing: aarch64-linux               | partial  |
| TC13        | No toolchain path in shipped programs' closures                                                       | `nix why-depends`                              | `hue`, `terminal`, `ui-gallery` and the examples (56 on x86_64-linux, 48 on aarch64-darwin) hold no toolchain path (closure table). `nix/packages/build-sparkles-app.nix` and `examples.nix` remove references after linking. Missing: TC15, so absence without removal                                                                                                                                                                                                             | partial  |
| TC14        | One glibc and one GCC runtime per shipped program                                                     | `nix path-info -r` on `hue`, `terminal`        | `hue` and `terminal` on x86_64-linux: glibc 2.44 and the GCC 16 runtime only (TC4)                                                                                                                                                                                                                                                                                                                                                                                                  | verified |
| TC15        | `__FILE__` and debug paths mapped, no reference removal                                               | `strings` on built programs                    | LDC fork `f8992633` adds `-fmacro-prefix-map` and `-ffile-prefix-map` (`__FILE__`, `__FILE_FULL_PATH__`, the file names of runtime errors, debug info), with lit test codegen/file_prefix_map.d. Missing: Sparkles' builds still remove references after linking instead of passing the map (WTD11)                                                                                                                                                                                 | partial  |
| TC16        | Sizes recorded with platform and revisions                                                            | `nix path-info -S`                             | Closure table below. Missing: aarch64 hosts, development shells, `ci`                                                                                                                                                                                                                                                                                                                                                                                                               | partial  |
| TC17        | Assertions on, or the release/checked pair with the checked variant absent from default closures      | `nix why-depends`; build timing                | One assertions-enabled LLVM ([TCD8](./decisions.md#tcd8-llvm-assertions)): `llvm-spirv-vulkan` sets LLVM_ENABLE_ASSERTIONS                                                                                                                                                                                                                                                                                                                                                          | verified |
| TC18–TC19   | LLVM's runtimes in place of the GCC runtime; exceptions across D and C++; no `libgcc_s` loaded        | Interop program; `readelf -d`; `LD_DEBUG=libs` | dlang.nix `ldc-vulkan-llvm-runtimes` and check `toolchain-llvm-runtimes` on x86_64-linux: a D exception crosses a C++ frame and a C++ exception crosses a D frame (its `scope (exit)` runs); the trace resolves D frames; neither libgcc_s nor libstdc++ is needed or loaded. Needed the fork's druntime to trace through _Unwind_Backtrace (`9642e7cc`, `b892093b`). Missing: aarch64-linux                                                                                        | partial  |
| TC20        | Static `terminal` and `hue` under the profile pass their suites; size and start-up recorded           | Test suites; `ldd`; timing                     | Not started: every C and C++ dependency needs a static build by the profile's clang against libc++, with glibc dynamic                                                                                                                                                                                                                                                                                                                                                              | planned  |
| TC21        | Toolchain builds and tests pass on each host                                                          | Nix builds on each host                        | The TC-M3 toolchain builds and passes TC22's checks on x86_64-linux and aarch64-darwin. Missing: aarch64-linux (Blockers)                                                                                                                                                                                                                                                                                                                                                           | partial  |
| TC22        | Each toolchain package exposes a Nix-run test                                                         | `nix flake check`                              | dlang.nix checks `toolchain-clang`, `toolchain-runtimes`, `toolchain-ldc` (LDC's lit suite and the host druntime and Phobos runners: 301 passed, 11 expected failures; 1892 of 1892 unittests), and per production preview `wasi-wasipN-runtime` and `wasi-wasipN-programs`, passing on x86_64-linux (lit: 305 passed, 11 expected failures) and aarch64-darwin (lit: 303 passed, 45 unsupported; ctest without druntime-test-exceptions, which needs atos). Missing: aarch64-linux | partial  |
| TC23        | Outputs cached for every host before the lock moves                                                   | Binary-cache `narinfo` lookups                 | #691: toolchain outputs for x86_64-linux and aarch64-linux pushed before its last CI run. Missing: an automated lookup gate                                                                                                                                                                                                                                                                                                                                                         | partial  |
| TC24        | The cache's pins are exactly the pin set, one revision each                                           | The cache's pin list against `pinTargets`      | `nix/pin-targets.nix`; applied by hand on 2026-10-27 for all three hosts (PLAN.md, Cache pins). Missing: the pinning tool's automated run                                                                                                                                                                                                                                                                                                                                           | partial  |
| TCW1–TCW8   | Sysroots, drivers, components and runtimes per preview                                                | `wasm-tools validate`; link tests              | dlang.nix `wasi-wasip1`, `wasi-wasip2`, `wasi-wasip3-experimental` and one D runtime per preview; `wasi-wasipN-programs` checks the LTO inlining of TCW3 and the absence of legacy `try`; preview 2 programs are components that validate. On preview 1, a reactor linked with LDC's `-mexec-model=reactor` (fork `b993e59a`) exports _initialize and no _start, and runs its module constructor before its export. Missing: TCW7 for preview 2 components                          | partial  |
| TCW9–TCW10  | Exceptions, module constructors and the GC work; runtime suites pass under wasmtime                   | druntime and Phobos unittests                  | `wasi-wasipN-programs` runs a D program that throws, runs a module constructor and allocates 100 000 elements, under wasmtime 49; `wasi-wasipN-runtime` runs druntime's release and debug runners with the known failures below. Missing: Phobos (see Blockers)                                                                                                                                                                                                                     | partial  |
| TCW11       | Compile-time quadruple-precision results agree across hosts                                           | Phobos `std.math` static assertions            | LDC fork                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | planned  |
| TCM1–TCM9   | Dub-built reactor modules; one loader; native agreement                                               | Native runs on a fixed corpus                  | Module packages and site loader                                                                                                                                                                                                                                                                                                                                                                                                                                                     | planned  |

## Installed tools

TC9's list, each with the step that uses it. A tool is added only with its
user.

| Tool                                    | Used by                                      | Status    |
| --------------------------------------- | -------------------------------------------- | --------- |
| `clang`, `clang++`                      | `clang-sparkles`, the WASI drivers           | installed |
| `lld` (`ld.lld`, `ld64.lld`, `wasm-ld`) | Host and WebAssembly links                   | installed |
| `llvm-config`                           | LDC's build                                  | installed |
| `llvm-ar`, `llvm-ranlib`, `llvm-nm`     | Runtime archives for cross targets           | installed |
| `llvm-profdata`, `llvm-cov`             | Profile data (TC12)                          | installed |
| `llvm-symbolizer`                       | Sanitizer reports                            | installed |
| `llvm-objdump`                          | Code inspection in fork and shader debugging | installed |
| `FileCheck`, `not`                      | LDC's lit tests (TC22)                       | installed |

## Runtimes per host

TC10's required set, from compiler-rt's build for each host. A runtime listed
here has a required test.

| Runtime                   | x86_64-linux                                       | aarch64-linux | aarch64-darwin                                    | Status  |
| ------------------------- | -------------------------------------------------- | ------------- | ------------------------------------------------- | ------- |
| builtins, profile, fuzzer | built and tested                                   | to record     | tested                                            | partial |
| sanitizers                | ASan, UBSan, TSan, MSan tested; LSan, HWASan built | to record     | ASan, UBSan tested; TSan, LSan by LDC's lit tests | partial |
| XRay                      | built and tested                                   | to record     | not tested                                        | partial |

## Known failures

TCW10's list. A row names one test, the toolchain revision, and the preview.

| Test                 | Preview            | Toolchain revision              | Cause                                                         | Requirement |
| -------------------- | ------------------ | ------------------------------- | ------------------------------------------------------------- | ----------- |
| druntime `core.math` | `wasip1`, `wasip2` | LDC `b892093b`, LLVM `24d1ae35` | Quadruple-precision folding on x86_64 and macOS hosts (TCW11) | TCW10       |

## Blockers

A blocker keeps a gate unmet; it is not a known failure.

- **Phobos unittests do not build for WASI on x86_64 hosts** (LDC
  `c8381c40`, LLVM `24d1ae35`): `std.math.operations` and
  `std.math.exponential` fail static assertions folded with x87 precision.
  Blocks TCW10 for Phobos until TCW11 is delivered.
- **aarch64-linux is not built.** The macOS host's Linux builder ran out of
  disk building LLVM. Blocks TC21, TC22 and TC23 for aarch64-linux.

## Preview 3

TCW2's record of the experimental sysroot, one row per toolchain revision.

| Toolchain revision              | Sysroot build | Probe (exceptions, constructors, GC)                                        | Notes                                                                                                                           |
| ------------------------------- | ------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| LDC `c8381c40`, LLVM `24d1ae35` | passes        | C and C++ throw and catch under wasmtime 49, as components; D does not link | druntime's `core.thread.osthread` relocates `__stack_high` as thread-local (`R_WASM_MEMORY_ADDR_TLS_SLEB`), and wasm-ld crashes |

## Closure measurements

Baseline before TC-M2, on x86_64-linux, with LDC `PetarKirov/ldc@edc4ad31`,
LLVM `PetarKirov/llvm-project@24d1ae35` and dlang.nix's nixpkgs of
2025-06-03. Sizes are `nix path-info -S` closure sizes unless noted.

| Package                            | Size          | Note                                                               |
| ---------------------------------- | ------------- | ------------------------------------------------------------------ |
| LLVM install (`llvm-spirv-vulkan`) | 4.3 GiB       | Static libraries; `bin/` 2.9 GB, each tool linking LLVM statically |
| `ldc-vulkan`                       | 577 MiB       | Includes GCC 14 (257 MB) through its default C compiler            |
| `wasi-sdk`                         | 505 MiB       | Copies `clang` and `lld` (361 MB)                                  |
| `clang-sparkles` (prototype)       | 4.6 GiB       | Wraps the whole LLVM install                                       |
| `hue`                              | 1.1 GiB       | Two GCC runtimes: GCC 14's `libgcc_s` and GCC 15's `libstdc++`     |
| `spk-text.wasm`                    | 488 KB (file) | After `wasm-opt -Oz`; the committed copy is 2.5 MB                 |
| `spk-table.wasm`                   | 967 KB (file) | After `wasm-opt -Oz`                                               |

After TC-M2 and the closure fixes (nixpkgs 3ec63636, LLVM and LDC as above),
with no toolchain path in any closure listed:

| Package      | x86_64-linux | aarch64-darwin | Note                                                                          |
| ------------ | ------------ | -------------- | ----------------------------------------------------------------------------- |
| `hue`        | 560.5 MiB    | 358.6 MiB      | macOS was 1.5 GiB: LDC, `dub` and, through raylib, nixpkgs' clang and cctools |
| `terminal`   | 439.0 MiB    | 237.2 MiB      |                                                                               |
| `ui-gallery` | 330.0 MiB    | 108.1 MiB      |                                                                               |

The toolchain after the LLVM rebuild of TC-M3 and the WASI sysroots of
TC-M5, on x86_64-linux (LDC `b892093b`, LLVM `24d1ae35`, nixpkgs 3ec63636):

| Package                                  | Own size       | Closure   | Note                                                                     |
| ---------------------------------------- | -------------- | --------- | ------------------------------------------------------------------------ |
| LLVM install (`llvm-spirv-vulkan`)       | 1.5 GiB        | 1.5 GiB   | Shared `libLLVM`; static libraries kept for LDC; a build input only      |
| `clang-sparkles-unwrapped` (view)        | 315.7 MiB      | 362.6 MiB | `clang`, `lld` and the resource headers, relinked against the view's lib |
| `compiler-rt-sparkles`                   | 35.3 MiB       | 82.3 MiB  |                                                                          |
| `llvm-runtimes-sparkles`                 | 19.6 MiB       | 66.6 MiB  | libunwind, libc++abi and libc++, shared and static (TC18)                |
| `clang-sparkles`                         | 64.2 KiB       | 738.9 MiB | The wrapper; GCC 16's `libstdc++` headers and start files                |
| `ldc-vulkan`                             | 298.1 MiB      | 1.0 GiB   | Holds compiler-rt's runtimes; links through `clang-sparkles`             |
| WASI libraries, both previews            | 92 MiB         | —         | wasi-libc, libc++ and their LTO builds, builtins                         |
| `ldc-sparkles-wasi-runtime-wasipN`       | 31 MiB         | 31 MiB    | Per preview, with LTO variants                                           |
| `ldc-sparkles` (`ldc-vulkan`, p1 and p2) | 242 KiB        | 1.2 GiB   |                                                                          |
| `spk-text.wasm`                          | 530 KB (file)  | —         | After `wasm-opt -Oz`; 488 KB before TC-M5. Not LTO-linked yet (TCM8)     |
| `spk-table.wasm`                         | 1029 KB (file) | —         | After `wasm-opt -Oz`; 967 KB before TC-M5. Not LTO-linked yet (TCM8)     |
