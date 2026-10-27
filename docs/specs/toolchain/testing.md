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

| Requirement | Scenario                                                                                              | Oracle                                     | Evidence                                                                                                                                                                                                              | Status   |
| ----------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| TC1         | Every D compilation in the flake resolves to the fork's LDC                                           | Store paths of the compilers used          | `nix/d-toolchain.nix` and `nix/packages/build-d-wasm-module.nix` use dlang.nix's fork packages (#691). Missing: a check that enumerates every compiler use                                                            | partial  |
| TC2         | LDC, clang and runtimes report the same LLVM revision                                                 | `ldc2 --version`, `clang --version`        | dlang.nix `llvm-spirv-vulkan`, `clang-sparkles`                                                                                                                                                                       | planned  |
| TC3         | Each behavior change in the forks carries a regression test                                           | Review of the branches against upstream    | The forks' sparkles/main histories. Missing: a recorded review of every commit                                                                                                                                        | partial  |
| TC4         | One glibc and one GCC runtime across toolchain and programs                                           | `nix why-depends` on a second glibc        | dlang.nix's nixpkgs follows Sparkles' (TC-M2): `hue`, `terminal` and `ci` on x86_64-linux hold glibc 2.44 and the GCC 16 runtime only, where `hue` held glibc 2.40 and 2.42 and the GCC 11, 14 and 15 runtimes before | verified |
| TC5         | The lock evaluates with every Nix version CI uses                                                     | Content hash of the fetched inputs         | dlang.nix fetches the LLVM fork as a shallow Git checkout; CI run of #691 evaluated it with Nix 2.35. Missing: a check across Nix versions                                                                            | partial  |
| TC6–TC8     | C, C++ and Objective-C build with the wrapped clang; LDC built by it; no unwrapped driver on any PATH | `command -v` in each build environment     | dlang.nix `clang-sparkles` prototype                                                                                                                                                                                  | planned  |
| TC9         | Tools share one LLVM library; only listed tools installed                                             | Installed file list against the list below | LLVM build configuration                                                                                                                                                                                              | planned  |
| TC10–TC12   | Each runtime of the per-host list detects its planted defect                                          | Planted-defect programs                    | dlang.nix tests of compiler-rt                                                                                                                                                                                        | planned  |
| TC13        | No toolchain path in shipped programs' closures                                                       | `nix why-depends`                          | `nix/packages/build-sparkles-app.nix` removes references after linking. Missing: TC15, so absence without removal                                                                                                     | partial  |
| TC14        | One glibc and one GCC runtime per shipped program                                                     | `nix path-info -r` on `hue`, `terminal`    | Closure table below                                                                                                                                                                                                   | planned  |
| TC15        | `__FILE__` and debug paths mapped, no reference removal                                               | `strings` on built programs                | LDC fork `-ffile-prefix-map`                                                                                                                                                                                          | planned  |
| TC16        | Sizes recorded with platform and revisions                                                            | `nix path-info -S`                         | Closure table below. Missing: aarch64 hosts, development shells, `ci`                                                                                                                                                 | partial  |
| TC17        | Assertions on, or the release/checked pair with the checked variant absent from default closures      | `nix why-depends`; build timing            | Measurement in TC-M3                                                                                                                                                                                                  | planned  |
| TC18–TC20   | Self-contained builds; exceptions across D and C++; no `libgcc_s` loaded                              | Interop programs; `ldd`; test suites       | All-LLVM profile                                                                                                                                                                                                      | planned  |
| TC21        | Toolchain builds and tests pass on each host                                                          | Nix builds on each host                    | #691: builds on x86_64-linux, aarch64-linux and aarch64-darwin in CI. Missing: TC22's tests                                                                                                                           | partial  |
| TC22        | Each toolchain package exposes a Nix-run test                                                         | `nix flake check`                          | dlang.nix `passthru.tests`                                                                                                                                                                                            | planned  |
| TC23        | Outputs cached for every host before the lock moves                                                   | Binary-cache `narinfo` lookups             | #691: toolchain outputs for x86_64-linux and aarch64-linux pushed before its last CI run. Missing: an automated lookup gate                                                                                           | partial  |
| TCW1–TCW8   | Sysroots, drivers, components and runtimes per preview                                                | `wasm-tools validate`; link tests          | WASI toolchain packages                                                                                                                                                                                               | planned  |
| TCW9–TCW10  | Exceptions, module constructors and the GC work; runtime suites pass under wasmtime                   | druntime and Phobos unittests              | WASI runtime tests                                                                                                                                                                                                    | planned  |
| TCW11       | Compile-time quadruple-precision results agree across hosts                                           | Phobos `std.math` static assertions        | LDC fork                                                                                                                                                                                                              | planned  |
| TCM1–TCM9   | Dub-built reactor modules; one loader; native agreement                                               | Native runs on a fixed corpus              | Module packages and site loader                                                                                                                                                                                       | planned  |

## Installed tools

TC9's list, each with the step that uses it. To be completed in TC-M3;
a tool is added only with its user.

| Tool                                    | Used by                                      | Status  |
| --------------------------------------- | -------------------------------------------- | ------- |
| `clang`, `clang++`                      | `clang-sparkles`, the WASI drivers           | planned |
| `lld` (`ld.lld`, `ld64.lld`, `wasm-ld`) | Host and WebAssembly links                   | planned |
| `llvm-config`                           | LDC's build                                  | planned |
| `llvm-ar`, `llvm-ranlib`, `llvm-nm`     | Runtime archives for cross targets           | planned |
| `llvm-profdata`, `llvm-cov`             | Profile data (TC12)                          | planned |
| `llvm-symbolizer`                       | Sanitizer reports                            | planned |
| `llvm-objdump`                          | Code inspection in fork and shader debugging | planned |
| `FileCheck`, `not`                      | LDC's lit tests (TC22)                       | planned |

## Runtimes per host

TC10's required set, filled in from compiler-rt's build for each host in
TC-M3. A runtime listed here has a required test.

| Runtime                   | x86_64-linux | aarch64-linux | aarch64-darwin | Status  |
| ------------------------- | ------------ | ------------- | -------------- | ------- |
| builtins, profile, fuzzer | to record    | to record     | to record      | planned |
| sanitizers                | to record    | to record     | to record      | planned |
| XRay                      | to record    | to record     | to record      | planned |

## Known failures

TCW10's list. A row names one test, the toolchain revision, and the preview.

| Test                 | Preview  | Toolchain revision              | Cause                               | Requirement |
| -------------------- | -------- | ------------------------------- | ----------------------------------- | ----------- |
| druntime `core.math` | `wasip1` | LDC `edc4ad31`, LLVM `24d1ae35` | Quadruple-precision folding (TCW11) | TCW10       |

## Blockers

A blocker keeps a gate unmet; it is not a known failure.

- **Phobos unittests do not build for `wasip1` on x86_64 hosts** (LDC
  `edc4ad31`, LLVM `24d1ae35`): `std.math.operations`, `std.math.exponential`
  and `std.math.traits` fail static assertions folded with x87 precision.
  Blocks TCW10 for Phobos until TCW11 is delivered.

## Preview 3

TCW2's record of the experimental sysroot, one row per toolchain revision.

| Toolchain revision | Sysroot build | Probe (exceptions, constructors, GC) | Notes              |
| ------------------ | ------------- | ------------------------------------ | ------------------ |
| —                  | not started   | not started                          | Delivered in TC-M5 |

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
