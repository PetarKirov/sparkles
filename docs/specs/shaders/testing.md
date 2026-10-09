---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-05
---

# `sparkles:shaders` — Testing and evidence

Oracles, acceptance scenarios and the evidence ledger for the requirements in
[`SPEC.md`](./SPEC.md). The library spans three implementations — the
vocabulary, the compiler's fragment stage and the build step — so each
requirement says which of them it checks and which oracle backs it.

## Oracles

| Oracle                                  | Independent because                                                                                       | Checks                                                                                             |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Hand-derived values**                 | Worked from the GLSL specification's definitions, not from this library's code                            | every built-in at ordinary, boundary and sign-changing inputs (`SHV5`, `SHV6`)                     |
| **Two host compilers**                  | DMD and LDC compile the vocabulary with different representations (`SHV2`) and different math libraries   | host behaviour that must not depend on the compiler (`SHV1`–`SHV6`)                                |
| **`spirv-val`**                         | The Khronos reference validator, a separate implementation of the SPIR-V rules                            | the compiler's device module (`SHP4`)                                                              |
| **`glslangValidator`**                  | The Khronos reference GLSL front end                                                                      | every generated file is a valid, complete shader (`SHP6`)                                          |
| **SPIR-V disassembly**                  | `spirv-dis` output read as text, independent of the compiler's code generator                             | interface variables, locations, bindings, names and handle storage (`SHF1`–`SHF3`, `SHF5`, `SHF6`) |
| **GPU readback**                        | A GL driver (the software rasterizer in CI) executes the generated GLSL; the host executes the D function | host/device agreement within the `D12` bounds (`SHV7`, `SHF4`)                                     |
| **Recorded dub behaviour**              | Scratch dub packages whose configurations are resolved by dub itself and inspected with `dub describe`    | configuration selection and leakage (`SHB5`, `SHB6`)                                               |
| **A build without the device compiler** | A Nix sandbox or CI leg whose toolchain lacks `ldc2-vulkan`: an opt-in that leaks cannot build there      | default configurations need no device compiler (`SHB5`, `SHB6`, `SHT4`)                            |

The compiler is both the subject of section 6 and the tool that produces the
evidence for it, so its output is checked by readers that share no code with
it: the Khronos validators and the SPIR-V disassembly. Differential tests
against GLSL that a person writes by hand are not used; they would test the
person.

## Scenarios

### Vocabulary (`SHV1`–`SHV8`)

- Construct each vector type with each constructor, read every component and
  swizzle, and compare with hand-written expectations, under DMD and LDC.
- For each built-in, evaluate negative, zero, positive and non-integer
  inputs, and inputs on both sides of each discontinuity (`floor` at −0.5,
  `mod` with a negative dividend, `step` at its edge, `smoothstep` at both
  edges). Expectations come from GLSL's definitions.
- **Agreement.** A probe unit with one fragment entry point per group of
  built-ins is compiled by the build step; each probe reads its arguments
  from a float texture, one sample per texel, and writes four results to a
  float render target. The results are read back and compared with the same
  functions evaluated on the host, within the `D12` bound for each operation
  (`ui_raylib.shader_readback.hostAndDeviceAgree`, run in CI under a virtual
  display on the software rasterizer). The GLSL ES output is not read back.
- Compile a module that uses every vocabulary symbol and a `@compute`
  attribute with DMD, without a device target, and check that it builds and
  that no device rule fires.

### Device modules (`SHM1`–`SHM5`)

- Classify modules spelled with each mode, with `@compute` qualified,
  preceded by comments, `deprecated` and other attributes, and with
  `hostAndDevice` appearing outside `@compute`'s arguments or inside a
  string; expect the classification `SHM5` defines.
- Seed each device rule's violation into a device module and expect the
  device compilation to fail with LDC's message. The editor analysis checks
  the same rules separately ([`TGT7`](../dmd-lsp/targets.md)).

### Fragment entry points (`SHF1`–`SHF7`)

- Compile entry points with zero, one and several parameters of each kind, in
  interleaved orders, and check in the disassembly that each `@input` has the
  next location in parameter order, each `Sampler2D` the next binding from 1,
  the sampler binding 0, each uniform the parameter's name, and the output
  `finalColor` at location 0.
- Compile a parameter with no marker, a parameter the calling convention
  rewrites, and a stage other than `@fragment`, and expect a diagnostic for
  each.
- Check in the disassembly that no image or sampler type appears as a
  member of a composite or as the pointee of a Function-storage variable.
  `spirv-val` under the universal rules does not check this; the Vulkan
  environment would, but also rejects the uniforms of `SHF2`.

### The build step (`SHP1`–`SHP10`)

- Parse `dub describe` output with resolution chatter before it, repeated
  flags and several targets, and check the settings, the target and the
  sources taken from it.
- Point the step at a configuration without `-mdcompute-targets` and expect
  exit 2; at a package with no device-only module and expect exit 1; with no
  `ldc2-vulkan` on `PATH` and expect exit 3 and instructions.
- Run with `DFLAGS` set to a host-only flag (`--threads=3`,
  `-fsanitize=address`) and expect identical output.
- Generate twice, from two directories, and expect byte-identical files and
  provenance comments.
- Run several instances of the step against one output directory at once and
  expect complete files and a stamp that vouches only for them.

### Build integration (`SHB1`–`SHB7`)

- Generate, then change each kind of input in turn — a device module, a
  dependency's device module, a contributing recipe — and expect the stamp to
  go stale after each; delete an output and expect the same.
- Write a `prebuilt` stamp and expect freshness with no compiler present.
- Add a device module that no existing input imports and expect the stamp to
  go stale, then remove it and expect the same (`SHB4`). Compute the stamp's
  digest for the same tree in two directories and on two platforms and
  expect it to be identical.
- Resolve, with dub, a consumer that selects the opt-in configuration in a
  parent configuration it does not use, and expect the dependency's default
  configuration.

## Evidence ledger

Statuses follow [Writing Specification
Docs](../../guidelines/spec-docs.md#keep-evidence-scoped-and-honest):
`verified` means the named tests passed for the named configuration, `partial`
names the missing case, `unverified` has no evidence yet, `planned` is
scheduled in [`PLAN.md`](./PLAN.md), and `deferred` waits for a
prerequisite PLAN names. Host tests run under DMD and LDC on every
CI leg; device evidence comes from the builds that generate GLSL, on x86_64
Linux, aarch64 Linux and aarch64 macOS.

| Requirement      | Status   | Evidence                                                                                                                                                                                                                                                                       | Gap                                                                                |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| SHV1, SHV3, SHV4 | verified | `shaders.types.constructAndRead`, `shaders.types.arithmeticIsComponentWiseAndBroadcasts`                                                                                                                                                                                       | —                                                                                  |
| SHV2             | verified | `shaders.types.representationPerCompiler` asserts the host representation under DMD and LDC; every generated-shader build compiles the device `vec3`                                                                                                                           | —                                                                                  |
| SHV5, SHV6       | verified | `shaders.math.builtinsMatchGlslDefinitions`, `shaders.math.transcendentalsMatchTheirDefinitions` (hand-derived values, `sin`, `cos`, `pow` and `exp` included)                                                                                                                 | —                                                                                  |
| SHV7             | partial  | `ui_raylib.shader_readback.hostAndDeviceAgree`: every built-in, read back from the GLSL 3.30 output on the software rasterizer, within the `D12` bounds (CI x86_64 Linux)                                                                                                      | the GLSL ES output's `mediump` bound is not read back (Q4)                         |
| SHV8             | verified | `ui.effect.builtins.areHonouredByACellGrid` runs `hostAndDevice` shader code under DMD with no device target                                                                                                                                                                   | —                                                                                  |
| SHM1, SHM2       | partial  | `shaderCompile.unitOf.repositoryUi`; `ui_raylib.effect_gpu.builtinsCarryTheirGpuHalf` passes only when the device build ran                                                                                                                                                    | no test compiles a `deviceOnly` module and checks it is absent from the host build |
| SHM3             | partial  | the pinned compiler's own pass; `dmd_lsp.testing.dcompute.rules` mirrors it                                                                                                                                                                                                    | no seeded-violation test of the device build itself                                |
| SHM4             | partial  | a violating module fails the device build (SHM3)                                                                                                                                                                                                                               | nothing flags it before the device build does                                      |
| SHM5             | verified | `shaders.compute_mode.computeModeOf`                                                                                                                                                                                                                                           | —                                                                                  |
| SHF1, SHF3       | verified | `shaderCompile.fragment.interfaceFromTheSignature`: entry points named after the D functions, `finalColor` at location 0 stored by a value-returning entry and by no `void` one                                                                                                | —                                                                                  |
| SHF2             | verified | `shaderCompile.fragment.interfaceFromTheSignature` (locations, bindings, set, the shared sampler, plain uniforms, in parameter order); `shaderCompile.cli.interfaceContractIsEnforced` (an unmarked parameter, and struct and array parameters, rejected naming the parameter) | —                                                                                  |
| SHF4             | partial  | `ui_raylib.shader_readback.hostAndDeviceAgree` (`probeSample` returns each texel exactly, GLSL 3.30)                                                                                                                                                                           | not read back from the GLSL ES output                                              |
| SHF5             | verified | `shaderCompile.interfaceViolations.flagsWhatTheContractForbids`; `shaderCompile.cli.interfaceContractIsEnforced` (a `vec3` input or return, a struct, an array: exit 1 naming the parameter)                                                                                   | —                                                                                  |
| SHF6             | verified | `shaderCompile.interfaceViolations.flagsWhatTheContractForbids` (a handle in a struct or in function-local memory); `shaderCompile.fragment.interfaceFromTheSignature` finds neither in the compiler's module                                                                  | —                                                                                  |
| SHF7             | verified | `shaderCompile.cli.interfaceContractIsEnforced`: another stage is rejected, naming it                                                                                                                                                                                          | —                                                                                  |
| SHP1             | verified | `shaderCompile.parseDescribe.rootSettingsAndEverySource`; `shaderCompile.cli.exitCodes` (exit 2 for a configuration without the target flag)                                                                                                                                   | —                                                                                  |
| SHP2             | verified | `shaderCompile.withoutHostFlags.dropsDflagsOnly`; CI test legs, whose `DFLAGS` carry `--threads=N`, generate successfully                                                                                                                                                      | —                                                                                  |
| SHP3             | verified | `shaderCompile.unitOf.repositoryUi`                                                                                                                                                                                                                                            | —                                                                                  |
| SHP4             | verified | `shaderCompile.cli.aFailedValidationWritesNothing` (exit 1, the earlier output and stamp untouched); `shaderCompile.cli.interfaceContractIsEnforced`                                                                                                                           | —                                                                                  |
| SHP6             | partial  | every generated-shader build runs `glslangValidator`                                                                                                                                                                                                                           | no negative case shows a rejection stops the step                                  |
| SHP5             | verified | `shaderCompile.renameCombinedSamplers.givesTheImageItsNameBack`, `shaderCompile.entryPoints.readsFragmentEntriesInOrder`                                                                                                                                                       | —                                                                                  |
| SHP7             | verified | `shaderCompile.header.namesTheEntryModulesRelativeToTheirPackage`                                                                                                                                                                                                              | —                                                                                  |
| SHP8             | verified | `shaderCompile.cli.staleOutputGoesAndConcurrentRunsAgree` (a stale file removed, no temporaries left, four concurrent runs leave complete output and a fresh stamp)                                                                                                            | —                                                                                  |
| SHP9, SHP10      | verified | `shaderCompile.cli.exitCodes` (0 generated and fresh, 1, 2, 3 with instructions); `shaderCompile.cli.stockCompilerIsAToolchainError`                                                                                                                                           | —                                                                                  |
| SHB1–SHB3        | verified | `shaderCompile.stamp.freshUntilAnInputChanges`                                                                                                                                                                                                                                 | —                                                                                  |
| SHB4             | deferred | M2                                                                                                                                                                                                                                                                             | a new device module is unseen until another input changes                          |
| SHB5             | verified | `ui.effect.builtins.carryOnlyTheirCpuHalfWithoutGpuEffects`, `ui_raylib.effect_gpu.builtinsCarryTheirGpuHalf`                                                                                                                                                                  | —                                                                                  |
| SHB6             | verified | CI builds the tui-only examples in a sandbox without `ldc2-vulkan`; `ui_raylib.effect_gpu` asserts `hasGpuEffects`                                                                                                                                                             | the dub leak itself is recorded by hand, not by a test                             |
| SHB7             | verified | the consumer recipe uses `--temp-build`; `shaderCompile.cli.staleOutputGoesAndConcurrentRunsAgree` runs the step concurrently on one output directory                                                                                                                          | —                                                                                  |
| SHT1, SHT2       | verified | the flake pins every component                                                                                                                                                                                                                                                 | —                                                                                  |
| SHT3             | verified | `.github/workflows/ci.yml`: the content hash of `ui-shaders` built on x86_64 Linux and aarch64 macOS agreed (#620)                                                                                                                                                             | aarch64 Linux is not compared                                                      |
| SHT4             | verified | CI test legs: generated-shader builds on x86_64 Linux, aarch64 Linux and aarch64 macOS; default configurations on Windows                                                                                                                                                      | —                                                                                  |
