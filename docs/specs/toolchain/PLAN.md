---
status: draft
owner: sparkles
reviewed: 2026-10-26
---

# The Sparkles toolchain — Delivery plan

This is the milestone tracker for the [toolchain specification](./SPEC.md),
[WASI](./wasi.md) and [WebAssembly modules](./wasm-modules.md) pages, and the
tracker of the WebAssembly tech-debt catalogue below. Requirements live in
those pages and evidence in [testing.md](./testing.md); a milestone names
them, it does not restate them.

Work spans three repositories. dlang.nix carries the toolchain packages, the
LDC and LLVM forks carry compiler changes as atomic commits (TC3), and
Sparkles carries its consumption of the toolchain, its WebAssembly modules
and this specification as one pull request of atomic commits.

## Milestones

| Milestone                      | Deliverable and obligations                                                                                                                                                                                                                                                                             | Prerequisites | Acceptance gate                                                                                                          | Exclusions                                              | State       |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- | ----------- |
| TC-M0 Specification            | These pages, the decision record, and the repaired pin in the shaders and test-runner specifications                                                                                                                                                                                                    | —             | Cold read of the opening; adversarial review of the requirements; sidebar, spec-evidence and glossary checks; site build | Implementation                                          | in progress |
| TC-M1 The dlang.nix branch     | dlang.nix's toolchain branch, which Sparkles pins, carries build status on every package and no obsolete WASI fork packages. Establishes TC1, TC2, TC3 and TC5                                                                                                                                          | TC-M0         | dlang.nix's CI matrix evaluates; Sparkles `ci --test` passes on the pinned revision                                      | Merging into dlang.nix `main` (TCD2); toolchain changes | done        |
| TC-M2 nixpkgs                  | Sparkles and dlang.nix on the latest nixos-unstable; dlang.nix's nixpkgs follows Sparkles' (TC4); the host-ELF compiler wrapper and DMD wrapper removed if the glibc split is gone                                                                                                                      | TC-M1         | Sparkles `ci --test`, docs build and Android packages pass on the bump alone, before any toolchain change                | LLVM configuration changes                              | done        |
| TC-M3 The LLVM rebuild         | One rebuild delivering TC6–TC14, TC16, TC17 and TC21–TC23: split outputs, shared LLVM library and trimmed tools, `clang-sparkles` and its stdenv, compiler-rt shipped with LDC, LDC built by its own clang, the assertions decision measured and applied, the closure table, Nix-run tests, warm caches | TC-M2         | TC22 tests pass on all hosts of TC21; closure table of TC16 recorded; caches warm (TC23)                                 | WASI from source; all-LLVM profile                      | in progress |
| TC-M4 All-LLVM runtime profile | libunwind and libc++ from the fork; the opt-in profile (TC18–TC19); static terminal, hue and font-explorer builds (TC20)                                                                                                                                                                                | TC-M3         | TC19 interop scenarios; the three applications' suites under the profile; size and start-up recorded                     | musl builds (open question Q2)                          | in progress |
| TC-M5 WASI from source         | TCW1–TCW11: sysroots for p1, p2 and experimental p3, LTO variants, drivers, components, reactors, D runtimes per preview, runtime test suites under wasmtime; the LDC fork fixes for TCW11 and `-ffile-prefix-map` (TC15)                                                                               | TC-M3         | druntime and Phobos test runners pass for p1 and p2 with listed known failures; p3 probe result recorded                 | Browser component-model hosting                         | in progress |
| TC-M6 WebAssembly modules      | TCM1–TCM9: dub-built reactor modules on the shared interface, one site loader, no committed binary, native-agreement check; the test runner's WASI execution mode                                                                                                                                       | TC-M5         | TCM9 check passes; site build from a clean tree; `ci --test-extracted` runs `@wasm` tests on WASI                        | —                                                       | planned     |

## WebAssembly tech-debt catalogue

Recovered from the audit of the first WebAssembly toolchain. A row closes
when its milestone's gate passes; rows closed by work that predates this plan
name the pull request that closed them, and closed rows stay for reference.

| ID    | Debt                                                                                             | Repayment                                                                    | Milestone | Status   |
| ----- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- | --------- | -------- |
| WTD1  | Three D compilers and three LLVMs in the closure                                                 | One fork of each (TC1, TC2), PetarKirov/sparkles#691                         | —         | closed   |
| WTD2  | An obsolete WASI fork of LDC duplicated upstream's WASI support                                  | Dropped; the unified fork carries upstream's support (#691)                  | —         | closed   |
| WTD3  | Driver patches read the sysroot from the environment and forced one link mode for every preview  | Link through the per-preview clang driver (TCW5)                             | TC-M5     | closed   |
| WTD4  | Phobos redirected to a fork that stubbed directory iteration                                     | Upstream Phobos (#691)                                                       | —         | closed   |
| WTD5  | The D runtime built for one preview, the modules compiled for another                            | One runtime per preview (TCW8)                                               | TC-M5     | closed   |
| WTD6  | The WASI runtime is not tested in Nix                                                            | TCW10                                                                        | TC-M5     | partial  |
| WTD7  | The component linker built from source with a workaround, builtins wired by absolute path        | Rebuilt as part of the WASI toolchain (TCW6, TCW1)                           | TC-M5     | closed   |
| WTD8  | The modules build only on x86_64 Linux                                                           | TCM2                                                                         | TC-M6     | planned  |
| WTD9  | Duplicated WebAssembly defaults in Sparkles' compiler configuration                              | LDC's own configuration (#691)                                               | —         | closed   |
| WTD10 | A shell wrapper parses `-mtriple` to keep host linker flags off cross links                      | Removed with the glibc split (TC4)                                           | TC-M2     | closed   |
| WTD11 | Every module's references are scrubbed because `__FILE__` names the toolchain                    | TC15                                                                         | TC-M5     | partial  |
| WTD12 | Sparkles pinned to a stacked feature branch of dlang.nix                                         | Accepted until upstreaming (TCD2); the stack is one linear branch            | TC-M1     | accepted |
| WTD13 | The modules are built by a hand-written compiler invocation that re-derives the dependency graph | TCM1                                                                         | TC-M6     | planned  |
| WTD14 | The modules' entry points are compiled by no test or per-commit build                            | TCM1, TCM2                                                                   | TC-M6     | planned  |
| WTD15 | The test runner's attribute module is on the modules' import path                                | Resolved by dub (TCM1)                                                       | TC-M6     | planned  |
| WTD16 | The modules duplicate their memory interface                                                     | TCM5                                                                         | TC-M6     | planned  |
| WTD17 | The table module avoids exceptions                                                               | TCW9, TCM6                                                                   | TC-M6     | planned  |
| WTD18 | Module constructors are assumed not to run                                                       | TCW7, TCM4                                                                   | TC-M6     | planned  |
| WTD19 | Command modules are used as reactors                                                             | TCM4                                                                         | TC-M6     | planned  |
| WTD20 | Each site component stubs the WASI imports itself                                                | TCM7                                                                         | TC-M6     | planned  |
| WTD21 | The text module's binary is committed and never rebuilt                                          | TCM3                                                                         | TC-M6     | planned  |
| WTD22 | Module size                                                                                      | TCW3, TCM8                                                                   | TC-M6     | partial  |
| WTD23 | Comments describe the obsolete WASI fork                                                         | Rewritten with the repayment                                                 | TC-M6     | partial  |
| WTD24 | The test runner's `--wasm` mode is `-betterC` on bare `wasm32`                                   | WASI execution mode in the test-runner specification                         | TC-M6     | planned  |
| WTD25 | The shipped modules have no tests                                                                | TCM9                                                                         | TC-M6     | planned  |
| WTD26 | The toolchain is pinned in the aggregate build and CI timeouts are inflated for cold builds      | TC23                                                                         | TC-M3     | planned  |
| WTD27 | `--wasm` needs `wasm-ld` on `PATH`                                                               | WASI links go through the WASI driver (TCW5); `--wasm-bare` links internally | TC-M6     | planned  |
| WTD28 | Compile-time `real` arithmetic folds with x87 precision for quadruple-precision targets          | TCW11                                                                        | TC-M5     | planned  |
| WTD31 | LLVM assertions cost about 10 % in optimized builds                                              | TC17                                                                         | TC-M3     | accepted |
| WTD32 | The Android LDC was a separate, stock compiler                                                   | Built on the fork (#686)                                                     | —         | closed   |
| WTD33 | The stock LDC's closure carried its bootstrap compiler and a second LLVM                         | The stock LDC left the toolchain (#691)                                      | —         | closed   |
| WTD35 | Compute-stage commits of the shader work are not on the fork's `sparkles/main`                   | Rebased onto it by their owner                                               | —         | planned  |
| WTD36 | Three LLVM fork commits reach the WASI sysroots as patches, and LLVM still installs unused tools | Taken in, with the ClangIR tools off, at the next LLVM rebuild (TCD11)       | TC-M3     | planned  |

WTD29, WTD30 and WTD34 were fork-internal fixes (LLVM 24's exception
personality, interpolated-expression precedence, the clang static analyzer
build) and are recorded in the forks' commit messages.

## Cache pins

[TC24](./SPEC.md#_8-platforms-tests-and-caches) makes `nix/pin-targets.nix`
the pin set. Until a tool applies it, the set is applied by hand from each
host. For every name in
`nix eval --json .#legacyPackages.<system>.pinTargets --apply builtins.attrNames`,
build `.#legacyPackages.<system>.pinTargets.<name>`, `cachix push` the result,
and `cachix pin sparkles <name>-<system> <path> --keep-revisions 1`. Then delete
every pin the set does not name. aarch64-linux is applied from a host with an
aarch64-linux builder.

The tool is the D pin launcher on Sparkles' `refactor/ci-toolchain-pin` branch
(`ci/toolchain-pin.d`, `apps/ci/src/derivation_pin*.d`). It predates TC24, and
before it lands it is rebased onto this plan's pull request with these changes:

1. **Read the set, keep no catalogue.** Its `toolchainCatalog`,
   `heavyLibCatalog` and `androidCatalog` are replaced by the attribute names
   of `legacyPackages.<system>.pinTargets` for x86_64-linux, aarch64-darwin and
   aarch64-linux, each pinned as `<name>-<system>` from installable
   `.#legacyPackages.<system>.pinTargets.<name>`. The `--toolchain`, `--libs`
   and `--android` selectors become filters on those names: the `toolchain-`
   prefix and the `-android` suffix. The catalogue tests become tests of that
   expansion.
2. **Drop its `pinTargets`.** The branch defines its own
   `legacyPackages.pinTargets` in `nix/shells/default.nix`, with a `nix-c-api`
   join over the `nix` flake input. That input is gone (TC-M2): the Nix C API
   libraries come from nixpkgs' `nixVersions.latest.libs`, which
   cache.nixos.org serves. The definition and `nixCApiLibs` are deleted.
3. **Remove the stale targets.** `toolchain-ldc-wasm` names a package removed
   in TC-M1. `toolchain-dub`, `toolchain-dtools`, `raylib`, `notcurses-core`
   and `tracy` are cheap to rebuild and are not in the set.
4. **One revision.** The `--revisions` default and `CI_PIN_REVISIONS` default
   become 1; the positive-integer check stays.
5. **Delete pins outside the set.** After pinning, the tool lists the cache's
   pins (`GET https://app.cachix.org/api/v1/cache/<cache>/pin`) and deletes
   each one that the expansion does not name
   (`DELETE …/pin/<name>`). A dry run lists the deletions without making them.
6. **Report against the cap.** The storage summary states the pinned closures'
   size beside the cache's 10 GiB.

Acceptance: a dry run on each host lists exactly the set and no deletion; a
real run leaves the cache's pin list equal to the set for all three hosts.
