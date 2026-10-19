---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — Testing and evidence

Oracles, acceptance scenarios and the evidence ledger for the requirements in
[`SPEC.md`](./SPEC.md) and its topic pages. The library spans three implementations — the
vocabulary, the compiler's graphics stages and the build step — so each
requirement says which of them it checks and which oracle backs it.

## Oracles

| Oracle                                  | Independent because                                                                                                               | Checks                                                                                                                  |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **Hand-derived values**                 | Worked from the GLSL specification's definitions, not from this library's code                                                    | every built-in at ordinary, boundary and sign-changing inputs (`SHV5`, `SHV6`)                                          |
| **Two host compilers**                  | DMD and LDC compile the vocabulary with different representations (`SHV2`) and different math libraries                           | host behaviour that must not depend on the compiler (`SHV1`–`SHV6`)                                                     |
| **`spirv-val`**                         | The Khronos reference validator, a separate implementation of the SPIR-V rules                                                    | the compiler's device module (`SHP4`)                                                                                   |
| **`glslangValidator`**                  | The Khronos reference GLSL front end                                                                                              | every generated file is a valid, complete shader (`SHP6`)                                                               |
| **SPIR-V disassembly**                  | `spirv-dis` output read as text, independent of the compiler's code generator                                                     | interface variables, locations, bindings, names and handle storage (`SHF1`–`SHF3`, `SHF5`, `SHF6`)                      |
| **GPU readback**                        | A GL driver (the software rasterizer in CI) executes the generated GLSL; the host executes the D function                         | host/device agreement within the `D12` bounds (`SHV7`, `SHF4`)                                                          |
| **Recorded dub behaviour**              | Scratch dub packages whose configurations are resolved by dub itself and inspected with `dub describe`                            | configuration selection and leakage (`SHB5`, `SHB6`)                                                                    |
| **A build without the device compiler** | A Nix sandbox or CI leg whose toolchain lacks `ldc2-vulkan`: an opt-in that leaks cannot build there                              | default configurations need no device compiler (`SHB5`, `SHB6`, `SHT4`)                                                 |
| **Vulkan readback**                     | A Vulkan driver (lavapipe, the software rasterizer, in CI) executes the generated SPIR-V; the host executes the D vertex function | stage interface, built-ins, push constants and bindings as a pipeline sees them (`SHF1`–`SHF3`, `SHF8`, `SHR4`, `SHR7`) |
| **The OpenGL 4.6 layout rules**         | Offsets worked by hand from §7.6.2.2 for a table of structs, not computed by `layoutOf`                                           | `std140` and `std430` offsets, strides and sizes (`SHR6`)                                                               |
| **`spirv-val` per environment**         | The reference validator under Vulkan 1.3's rules for `vulkan1.3`, universal rules for the GL profiles                             | each profile's module (`SHP4`, `SHP6`)                                                                                  |

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
  display on the software rasterizer). Both dialects are read back: the GLSL ES
  1.00 output through the driver's GLSL ES front end, linked with a GLSL ES
  vertex stage, in the same desktop context; the software rasterizer computes
  in single precision whatever the qualifiers, so `highp` itself is `D15`'s.
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

### Entry points (`SHF1`–`SHF9`) {#scenarios-entry-points}

- Compile fragment entry points with zero, one and several parameters of each
  kind, in interleaved orders, and check in the disassembly that each `@input`
  has the next location in parameter order, each `Sampler2D` the next binding
  from 1, the sampler binding 0, each uniform the parameter's name, and the
  output `finalColor` at location 0.
- Compile a vertex entry point whose result struct has a position field and
  two outputs, and check in the disassembly the `Position` built-in and the
  outputs at locations 0 and 1 named after the fields; compile one without a
  position field, a built-in in the wrong stage or with the wrong type, and a
  stage the profile does not grant, and expect a diagnostic for each.
- Assert `stagesLink!(V, F)` for the triangle's pair, and its negation for
  pairs whose names, types or locations differ in one field each.
- Compile a parameter with no marker, a parameter the calling convention
  rewrites, and a stage attribute with an unknown value, and expect a
  diagnostic for each.
- Check in the disassembly that no image or sampler type appears as a member
  of a composite or as the pointee of a Function-storage variable, including
  for a `Sampler2D` reached through an interface struct.

### Resources (`SHR1`–`SHR8`)

- **Layout.** Compare `layoutOf!(T, Rule)` with hand-worked offsets for a
  table of structs that exercise every rule of §7.6.2.2 that differs between
  the two layouts and from D's: a `float3` followed by a `float`, arrays of
  scalars and of vectors, nested structs, a trailing scalar after an array.
  `writeLayout` of a value, read back by those offsets, gives the value.
- **Lowering.** Build one entry point with `@uniform` parameters, a
  `UniformBlock!T` and a `PushConstants!T` for `vulkan1.3` and for `gl330`;
  check that the Vulkan module declares the blocks with the offsets of
  `layoutOf` and the bindings of `SHR7`, and that the GLSL declares one
  uniform per field under its D name.
- **Unchanged output.** Regenerate `sparkles:ui`'s effects and compare with
  the GLSL before the slice, apart from the provenance comment.
- **Rejections.** A push-constant block over 128 bytes, two push-constant
  blocks, two resources at one binding, an interface struct with a field of
  another kind, and two flattened resources sharing a name: each fails,
  naming what `SHR1`–`SHR7` say.

### Profiles (`SHC1`–`SHC10`)

- Unit-test the capability table: implications are closed, every profile's
  set is closed under them, and each profile denies what `SHC2` says it does.
- Compile a module with `@profiles(vulkan13)` on one entry point and the
  module default `gl330, gles100`; check the manifest names each entry point
  with its stage and profiles, that the Vulkan-only entry point is absent
  from the GL modules, and that each entry point produced exactly its files.
- A branch on `activeProfile` that only compiles under `vulkan1.3` builds the
  GL profiles; the same code without the branch fails them.
- **Audit.** A module made to declare `Int64` under a profile that denies it
  fails the build step with exit 1, naming the capability and the profile.
- An unknown profile name in `@profiles`, and an unknown active profile, each
  fail with the diagnostic `SHC3` and `SHC4` require.

### The first consumer

- The triangle of `sparkles:vulkan-wsi`, built for `vulkan1.3`, is rendered
  offscreen by lavapipe at three aspect ratios; pixels at the three vertices,
  at the centroid and outside the triangle are compared with the host
  evaluation of its vertex function and its interpolated colour. The window
  examples render it as before.

### The build step (`SHP1`–`SHP10`)

- Parse `dub describe` output with resolution chatter before it, repeated
  flags and several targets, and check the settings, the target and the
  sources taken from it.
- Point the step at an unknown configuration, one without
  `-mdcompute-targets`, one naming two targets and one without a device-only
  module, and expect exit 2 with the cause; with no `ldc2-vulkan` on `PATH`,
  and with that and an unknown configuration, expect exit 3 and instructions;
  at a stock LDC, expect exit 3 from the capability probe.
- Edit an input while the step compiles and expect the stamp to be stale.
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

| Requirement                                         | Status   | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Gap                                                                                                       |
| --------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| SHV1, SHV3, SHV4                                    | verified | `shaders.types.constructAndRead`, `shaders.types.arithmeticIsComponentWiseAndBroadcasts`, `shaders.types.allEqualIsOneBool` (the same `bool` under DMD and LDC)                                                                                                                                                                                                                                                                                                                                                                | —                                                                                                         |
| SHV2                                                | verified | `shaders.types.oneLayoutOnBothSides` asserts every vector's size and alignment, a struct and an array holding `vec3`, and the packed variants, under DMD and LDC; every generated-shader build compiles the device `vec3`                                                                                                                                                                                                                                                                                                      | —                                                                                                         |
| SHV5, SHV6                                          | verified | `shaders.math.builtinsMatchGlslDefinitions` (hand-derived values); `shaders.math.vectorFormsArePerComponent` (each vector and widened-scalar form equals the scalar one per component); `ui_raylib.shader_readback.hostAndDeviceAgree` (`sin`, `cos`, `exp` and `pow`, and in `probeVectorForms` the vector forms, against the GPU's, within the `D12` bounds)                                                                                                                                                                 | —                                                                                                         |
| SHV7                                                | verified | `ui_raylib.shader_readback.hostAndDeviceAgree`: every built-in, read back from the GLSL 3.30 and the GLSL ES 1.00 output on the software rasterizer, within the `D12` bounds (CI x86_64 Linux); breaking the ES vertex stage fails it                                                                                                                                                                                                                                                                                          | —                                                                                                         |
| SHV8                                                | verified | `shaders.attributes.standInsCompileAsPlainD` (every stand-in, on a function a host calls); `ui.effect.builtins.areHonouredByACellGrid` (host-and-device shader code under DMD)                                                                                                                                                                                                                                                                                                                                                 | —                                                                                                         |
| SHM1, SHM2                                          | partial  | `shaderCompile.unitOf.repositoryUiAsDubDescribesIt`; `ui_raylib.effect_gpu.builtinsCarryTheirGpuHalf` passes only when the device build ran                                                                                                                                                                                                                                                                                                                                                                                    | no test compiles a `deviceOnly` module and checks it is absent from the host build                        |
| SHM3                                                | partial  | the pinned compiler's own pass; `dmd_lsp.testing.dcompute.rules` mirrors it                                                                                                                                                                                                                                                                                                                                                                                                                                                    | no seeded-violation test of the device build itself                                                       |
| SHM4                                                | partial  | a violating module fails the device build (SHM3)                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | nothing flags it before the device build does                                                             |
| SHM5                                                | verified | `shaders.compute_mode.computeModeOf` (qualified names by their last component, a byte-order mark, comments and other attributes skipped)                                                                                                                                                                                                                                                                                                                                                                                       | —                                                                                                         |
| SHF1, SHF3                                          | verified | `shaderCompile.fragment.interfaceFromTheSignature`: the generated GLSL of an entry interleaving every parameter kind and of a `void` one equals `apps/shader-compile/tests/golden/`; `shaderCompile.cli.interfaceContractIsEnforced` (a second `tint` rejected, naming both definitions)                                                                                                                                                                                                                                       | —                                                                                                         |
| SHF2                                                | verified | `shaderCompile.fragment.interfaceFromTheSignature` (names in the golden GLSL; input locations and bindings in the module); `shaderCompile.cli.interfaceContractIsEnforced` (an unmarked parameter, two markers, a marked `Sampler2D`, reserved names `smooth`, `gl_x`, `spvGain`, `a__b` and field `filter`, and two entries giving `fragColor` different locations or `scale` different types, each rejected naming it); the fork's lit tests (binding clashes, temporary and non-ASCII names, near misses that are accepted) | —                                                                                                         |
| SHF4                                                | verified | `ui_raylib.shader_readback.hostAndDeviceAgree` (`probeSample` returns each texel exactly, in both dialects)                                                                                                                                                                                                                                                                                                                                                                                                                    | —                                                                                                         |
| SHF5                                                | verified | `shaderCompile.cli.interfaceContractIsEnforced` (an `int` input, a `uint` uniform, an array input, a `vec3` return, a struct holding a `Sampler2D`: rejected with the reason); `shaderCompile.fragment.whatMayCrossIsDeclared` (a `vec3` input, an integer-vector uniform and an array uniform, declared in both dialects); `ui_raylib.shader_readback.hostAndDeviceAgree` (`probeUniforms`: an `int` and a struct of `float`, `int` and `vec3`, set by name and read back)                                                    | —                                                                                                         |
| SHF6                                                | verified | `shaderCompile.cli.interfaceContractIsEnforced` (a uniform struct holding a `Sampler2D` is rejected); the golden GLSL of `shaderCompile.fragment.interfaceFromTheSignature` holds no local sampler                                                                                                                                                                                                                                                                                                                             | —                                                                                                         |
| SHF7                                                | verified | `shaderCompile.cli.interfaceContractIsEnforced`: a stage attribute with the value 1 is rejected, reporting it                                                                                                                                                                                                                                                                                                                                                                                                                  | —                                                                                                         |
| SHP1                                                | verified | `shaderCompile.parseDescribe.rootSettingsAndEverySource`; `shaderCompile.cli.exitCodes` (exit 2 for a configuration without the target flag)                                                                                                                                                                                                                                                                                                                                                                                   | —                                                                                                         |
| SHP2                                                | verified | `shaderCompile.withoutHostFlags.dropsDflagsOnly`; CI test legs, whose `DFLAGS` carry `--threads=N`, generate successfully                                                                                                                                                                                                                                                                                                                                                                                                      | —                                                                                                         |
| SHP3                                                | partial  | `shaderCompile.unitOf.repositoryUiAsDubDescribesIt` (`sparkles:ui`'s unit through `dub describe`); `shaderCompile.unitOf.picksComputeModulesByTheirHead` (the filter, without a toolchain); `shaderCompile.cli.exitCodes` (no device-only module: exit 2)                                                                                                                                                                                                                                                                      | that the unit compiles in one invocation is read from `run`, not tested                                   |
| SHP4                                                | verified | `shaderCompile.cli.aFailedValidationWritesNothing` (exit 1, the earlier output and stamp untouched)                                                                                                                                                                                                                                                                                                                                                                                                                            | —                                                                                                         |
| SHP5                                                | verified | `shaderCompile.fragment.interfaceFromTheSignature` (both dialect files of one entry equal their golden GLSL, combined samplers named after the `Sampler2D` parameters); `shaderCompile.entryPoints.readsFragmentEntriesInOrder`                                                                                                                                                                                                                                                                                                | —                                                                                                         |
| SHP6                                                | verified | every generated-shader build runs `glslangValidator`; `shaderCompile.cli.aRejectedTranslationWritesNothing` (a validator that rejects: exit 1, the earlier output and stamp untouched)                                                                                                                                                                                                                                                                                                                                         | —                                                                                                         |
| SHP7                                                | verified | `shaderCompile.header.namesTheEntryModulesRelativeToTheirPackage`; the golden files of `shaderCompile.fragment.interfaceFromTheSignature`, generated from a scratch directory                                                                                                                                                                                                                                                                                                                                                  | —                                                                                                         |
| SHP8                                                | verified | `shaderCompile.cli.staleOutputGoesAndConcurrentRunsAgree` (a stale file and a dead run's temporary removed, a live run's temporary kept, four concurrent runs leave complete output and a fresh stamp)                                                                                                                                                                                                                                                                                                                         | —                                                                                                         |
| SHP9, SHP10                                         | verified | `shaderCompile.cli.exitCodes` (0 generated and fresh; 2 for a stray argument, an unknown configuration, one without the target flag, a source library (no build target), one naming two targets, an invalid Vulkan version, one without a device-only module; 3 without the compiler, also over a configuration error, and without `spirv-cross`, each named; 1 for a compile error); `shaderCompile.cli.stockCompilerIsAToolchainError` (3 by the capability probe)                                                           | —                                                                                                         |
| SHB1–SHB3                                           | verified | `shaderCompile.stamp.freshUntilAnInputChanges` (a module, the package's recipe and a dependency's recipe; an unknown or malformed line, a version line alone, no inputs or no outputs: stale; `prebuilt`, trailing blank lines aside: fresh); `shaderCompile.cli.exitCodes` (a stamp the step wrote is fresh, and needs no compiler); `shaderCompile.cli.anInputEditedDuringTheRunLeavesItStale`                                                                                                                               | —                                                                                                         |
| SHB4                                                | deferred | M2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | a new device module is unseen until another input changes                                                 |
| SHB5                                                | verified | `ui.effect.builtins.carryOnlyTheirCpuHalfWithoutGpuEffects`, `ui_raylib.effect_gpu.builtinsCarryTheirGpuHalf`                                                                                                                                                                                                                                                                                                                                                                                                                  | —                                                                                                         |
| SHB6                                                | verified | CI builds the tui-only examples in a sandbox without `ldc2-vulkan`; `ui_raylib.effect_gpu` asserts `hasGpuEffects`; the recipes that add the backend select the configuration beside it (Trace D)                                                                                                                                                                                                                                                                                                                              | —                                                                                                         |
| SHB7                                                | partial  | the consumer recipe uses `--temp-build`; `shaderCompile.cli.staleOutputGoesAndConcurrentRunsAgree` runs the built step in four processes at once on one output directory                                                                                                                                                                                                                                                                                                                                                       | concurrent `dub run --temp-build` builds of the step are not exercised                                    |
| SHT1, SHT2 (pinning)                                | verified | the flake pins every component (`flake.lock`, dlang.nix `pkgs/llvm-spirv`)                                                                                                                                                                                                                                                                                                                                                                                                                                                     | —                                                                                                         |
| SHT1 (pin-change gate)                              | verified | CI runs every device check on a pin change: the toolchain tests, the GPU readback of both dialects, and `shader-reproducibility`                                                                                                                                                                                                                                                                                                                                                                                               | —                                                                                                         |
| SHT3                                                | verified | `.github/workflows/ci.yml` `shader-reproducibility`: the content hashes of `ui-shaders` built on x86_64 Linux, aarch64 Linux and aarch64 macOS agree, and the job fails unless all three report; `shaderCompile.cli.outputIsTheSameInAnyDirectory` (the same package in two directories)                                                                                                                                                                                                                                       | —                                                                                                         |
| SHT4                                                | verified | CI test legs: generated-shader builds on x86_64 Linux, aarch64 Linux and aarch64 macOS; default configurations on Windows                                                                                                                                                                                                                                                                                                                                                                                                      | —                                                                                                         |
| SHV1, SHV2 (`float*` names), SHV9                   | planned  | M6                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | the `float*`/`int*` aliases and integer vectors                                                           |
| SHV10                                               | planned  | M8                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | the one vector type                                                                                       |
| SHF1, SHF3 (vertex), SHF7 (per profile), SHF8, SHF9 | planned  | M6                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | the vertex stage, built-ins, struct results and stage linking; the fragment stage's evidence above stands |
| SHR1–SHR8                                           | planned  | M6                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | resources, lowering per profile, layout and bindings                                                      |
| SHC1–SHC6, SHC9, SHC10                              | planned  | M6                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | profiles, the manifest, per-profile compilation and the audit                                             |
| SHC7, SHC8                                          | planned  | M7                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | declared and inferred requirements                                                                        |
| SHP3–SHP8, SHP10 (per profile)                      | planned  | M6                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | the revised, per-profile form; the evidence above is for the single-profile form of 2026-10-16            |
| SHX1–SHX3                                           | planned  | M11                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | the executor, once its contracts are refined                                                              |
