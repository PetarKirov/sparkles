---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders` — Delivery plan

The order in which the requirements of [`SPEC.md`](./SPEC.md) and its topic
pages are delivered,
the gate each milestone must pass, and progress. Scenarios, oracles and the
evidence ledger live in [`testing.md`](./testing.md).

## Progress

| Milestone                                                                   | State       |
| --------------------------------------------------------------------------- | ----------- |
| [Stage 0](#stage-0-specification)                                           | done        |
| [M0 Baseline](#m0-baseline)                                                 | done        |
| [M1 Rename](#m1-rename-to-sparkles-shaders)                                 | done        |
| [M2 Unit membership](#m2-unit-membership)                                   | deferred    |
| [M3 Interface and agreement evidence](#m3-interface-and-agreement-evidence) | done        |
| [M4 Multi-pass effects](#m4-multi-pass-effects-in-single-source-d)          | done        |
| [M5 Further platforms](#m5-further-device-platforms)                        | not started |
| [Stage 0 (revision)](#stage-0-revision-the-full-language-scope)             | done        |
| [M6 Profiles and the Vulkan triangle](#m6-profiles-and-the-vulkan-triangle) | in progress |
| [M7 Capability inference](#m7-capability-inference-and-stage-operations)    | not started |
| [M8 One vector type](#m8-one-vector-type)                                   | not started |
| [M9 Vocabulary breadth](#m9-vocabulary-breadth)                             | not started |
| [M10 Compute and storage](#m10-compute-and-storage)                         | not started |
| [M11 Reference CPU executor](#m11-reference-cpu-executor)                   | not started |
| [M12 Further targets](#m12-further-targets)                                 | not started |
| [M13 Subgroups and convergence](#m13-subgroups-and-convergence)             | not started |
| [M14 Further stages](#m14-further-stages)                                   | not started |
| [M15 DXIL](#m15-dxil)                                                       | not started |
| [M16 SPMD executor](#m16-spmd-executor)                                     | not started |

## Stage 0: specification

**Deliverable.** This specification tree accepted.

**Gate.** Per the [Stage 0 gate](../../guidelines/spec-docs.md#stage-0-gate):
scope, ownership and non-goals agreed; a cold read of the opening; an
adversarial review of sections 4–8 with worked traces — a successful build
of a two-entry unit, a stale stamp, a configuration without a target, a leaked
selection — and its findings dispositioned. Acceptance is recorded by the
project owner, not implied by merging.

**Progress.**

- The [adversarial review](./adversarial-review.md) found 28 findings, two of
  them blockers (`R1`, entries sharing interface variables; `R2`, stamp
  inputs missing what the compile reads). Every finding has a recorded
  disposition: 27 fixed, ten of them by amending the specification alone,
  and one deferred to M2 (`R17`).
- An independent review of the dispositions and the changed artifact found
  that `SHV7` cited the wrong bound, that `R5`, `R15` and `R20` were fixed
  only in part and `R22`'s rejection did not hold, that several ledger rows
  claimed more than their tests, that `SHB4` and stale text contradicted the
  contract, and that the build step no longer built on Windows. Each is
  repaired; the ledger now marks `SHP3`, `SHP9`/`SHP10`, `SHB7` and `SHT3`
  partial, with their gaps.
- Cold reads of the opening, by a reader given only the front matter, abstract
  and introduction: the first found the entry point's owner, the stamp's
  inputs, the prebuilt path, the fork's relation to the Vulkan target, the CPU
  side of textures, the device-module term and an exclusion that contradicted
  integer uniforms; the second restated scope and non-goals correctly and
  found how much of the effect the CPU runs, `@compute`'s name, when a missing
  compiler fails and the unnamed tools. The introduction answers each. A third
  and a fourth read, of the text after every substantive change, restated the
  problem, approach, scope and non-goals correctly; the wording points they
  raised are answered too, and only editorial changes followed.
- The owner accepted the specification, its scope, ownership and non-goals,
  and every disposition on 2026-10-16
  ([acceptance](./adversarial-review.md#acceptance)).

## M0: Baseline

The system this specification describes, as it exists: the vocabulary, the
compiler pin with the fragment stage, the build step with its stamp, and one
consumer (`sparkles:ui`'s built-in effects) on all three device platforms.
Its evidence and gaps are the ledger's `verified` and `partial` rows. M0
introduced nothing for this specification; it is the line later milestones
are measured from.

## M1: Rename to `sparkles:shaders`

**Obligations.** None new; every requirement keeps holding under the new
names.

**Deliverable.** The dub sub-package `sparkles:shader` becomes
`sparkles:shaders`, its modules move from `sparkles.shader.*` to
`sparkles.shaders.*`, the build step's package and documentation follow, and
every consumer, the editor analysis's device detection included, imports the
new names. The user documentation moves to `docs/libs/shaders/`.

**Gate.** All CI legs green; `dub test :shaders` runs the vocabulary tests
under DMD and LDC; a GUI build regenerates its GLSL from a clean output
directory, byte-identical to the GLSL before the rename apart from the
provenance comment; no `sparkles.shader.` import or `sparkles:shader`
dependency remains.

**Exclusions.** No compatibility alias for the old module names: the package
has no consumers outside this repository.

## M2: Unit membership

**Obligations.** `SHB4`.

**Deliverable.** The stamp records a digest of the device modules among the
unit's candidate fileset (each one's path and mode), and freshness recomputes
it with a fileset resolution, so a device module entering or leaving the
unit, or changing mode, makes the next build regenerate; an edit to any other
file does not.

**Entry condition.** Two prerequisites from `sparkles:build-primitives`: the
[filesets](../build-primitives/filesets/PLAN.md) resolution machine and a
driver, and a deterministic digest scheme on its scheme seam (the
content-addressing contract the filesets specification defers to). M2 does
not start, and does not build an interim directory listing, before both.

**Gate.** The `SHB4` scenario: a device module that no existing input
imports, added to a package, makes the next build regenerate, and removing
it makes the following one regenerate again. The same tree in two
directories, and on two platforms, yields the same digest. The stamp format
version changes, so every existing stamp goes stale once. The freshness check
still runs without dub and without the compiler.

## M3: Interface and agreement evidence

**Obligations.** `SHV7`, `SHF2`, `SHF3`, `SHF4`, `SHF5`, `SHF6`, `SHF7`,
`SHP8`, `SHP10`, and the open cases of `SHV2`, `SHV5` and `SHT3`.

**Deliverable.** The disassembly checks of the accepted specification's section 6, a GPU readback harness
under a software rasterizer, host assertions for `sin`, `cos` and `pow`, an
automated test of each exit code, a concurrent-run test of the build step,
and a comparison of generated output across platforms.

**Gate.** Every listed row of the ledger is `verified`, and each new test has
been shown to fail on a deliberately broken input: a swapped location, a
wrong uniform name, a tolerance violated on purpose.

**Progress.**

- The [evidence ledger](./testing.md#evidence-ledger) records each row's
  status; the rows this milestone moved are `SHV2`, `SHV5`, `SHF1`–`SHF7`,
  `SHP1`, `SHP4`, `SHP6`, `SHP8`–`SHP10`, `SHB7` and `SHT3`.
- The readback ran on the CI runner's software rasterizer and agreed
  (`SHV7`, `SHF4`), for the GLSL 3.30 output and, linked with a GLSL ES vertex
  stage in the same desktop context, for the GLSL ES 1.00 output.
- Each new test was shown to fail on a broken input: a disabled interface
  check, stale files kept, a wrong host function, bounds tightened to zero,
  and an unrecognised stock compiler. That last case was a real bug, and it
  is fixed.
- `SHF5` turned out to be unenforced by the compiler; the compiler now
  enforces it, with `SHF2`'s one variable per name, and types uniforms as the
  host binds them (`D13`). The tolerances are `D12`, which resolves open
  question Q3.
- `SHP6` has its negative case; the ES output's precision is `D15`.
- `SHP10` has a case for every check of its order, and `SHT3` compares all
  three platforms of `SHT4` and two directories. Testing the first turned up
  a false cause: a source-library configuration was reported as having no
  source files. Every row this milestone lists is `verified`, so the gate is
  met.

## M4: Multi-pass effects in single-source D

**Obligations.** None new for this library. M4 proves that its requirements
suffice for a multi-pass effect with several textures and uniforms.

**Deliverable.** `sparkles:ui`'s bloom and CRT effects, which are hand-written
GLSL, are rewritten as single-source shaders, one fragment entry point per
pass. The work is specified by the effects specification
([`EFX21`–`EFX24`](../ui/effects.md)) and tracked there.

**Gate.** Every pass is generated, none is committed, and the CPU path of
each effect calls the same D functions as its GPU passes.

**Entry condition.** M1, so the new code is written against the final names.

**Outcome.** The gate is met.

- Bloom's four passes and the CRT's tube are generated from D, and no
  hand-written shader is left in the effect pipeline.
- The CRT's bend and lens are `sparkles.ui.crt_shaders` functions, called by the
  tube and by `CrtProjection` on the CPU.
- Captured with the clock pinned, bloom is byte-identical to the hand-written
  passes. The CRT differs from the hand-written tube in one pixel in 720,000,
  by 1/255; control builds show the capture is sensitive to the shaders.
- The vocabulary gained `exp`, and `pow` now resolves `const` arguments under
  DMD.
- The tube exposed two constructs the pinned SPIR-V backend structures wrongly,
  both rejected by `spirv-val`: an `if … else if (a && b)` chain, and early
  returns among short-circuit masks. The tube avoids both. Both are fixed
  since: the compiler structures device code before the backend, which gives
  nested conditions sharing an exit merge blocks of their own.

## M5: Further device platforms

**Obligations.** `SHT4` extended to the platforms an accepted resolution of
[open question Q1](./decisions.md#open-questions) adds.

**Entry condition.** Q1 resolved: a consumer needs generated shaders on a
platform the device toolchain does not reach.

## Stage 0 (revision): the full-language scope

**Deliverable.** The revision of 2026-10-19 accepted: the umbrella
[`SPEC.md`](./SPEC.md), the topic pages it maps, decisions `D16`–`D24`, this
plan's M6–M16 and the scenarios of [`testing.md`](./testing.md) for M6.

**Gate.** The [Stage 0 gate](../../guidelines/spec-docs.md#stage-0-gate) for
the first slice: scope, ownership and non-goals agreed by the owner; cold
reads of the umbrella's opening; an adversarial review of the first slice's
contracts (profiles, entry points, resources, the revised build step) with
worked traces — a two-profile unit whose Vulkan-only entry point reaches a
capability the GL profiles lack, a push-constant block over 128 bytes, an
interface struct whose flattened names clash, a module whose emitted SPIR-V
declares a capability its profile denies — and every finding dispositioned.
Acceptance is recorded by the owner. Later milestones' contracts are refined,
reviewed and accepted before each starts.

**Progress.** The scope and the design choices behind `D16`–`D22` were set by
the owner in two grilling rounds (2026-10-17 to 2026-10-19), from the
[research catalog](../../research/shading-languages/index.md); `D17` refines
one of those choices. The
[adversarial review of the revision](./revision-review.md) found 32 findings,
four of them blockers; every one has a disposition. M6's two spikes were run
before acceptance. The owner accepted the revision on 2026-10-20, `D17`'s
refinement included, and settled the one point the spikes left open as
`D25` ([acceptance](./revision-review.md#acceptance)).

## M6: Profiles and the Vulkan triangle

**Obligations.** `SHC1`–`SHC6`, `SHC9`, `SHC10`; `SHF1`–`SHF3`, `SHF5`–`SHF9`;
`SHR1`–`SHR8`; `SHM6`; `SHV1`, `SHV2`, `SHV8`, `SHV9`; `SHP3`–`SHP8`,
`SHP10`; the SPIR-V 1.6 sentence of `SHP1`; the SPIR-V half of `SHT3`. For a revised requirement whose
pre-revision part is already verified, the obligation is the revised part.

**Spikes, before the compiler work.** Two probes of the pinned compiler
settle what the deliverable assumes; a spike that fails reopens the
requirements it names before anything is built on them.

- **S1, explicit layout.** A uniform block and a push-constant block whose
  `std140` and `std430` offsets differ from D's, decorated with `Offset` and
  `ArrayStride` through the backend's layout metadata, pass `spirv-val` for
  Vulkan 1.3 and declare no `Int8` (`SHR4`–`SHR6`, `SHR8`).
- **S2, the triangle's tables.** The triangle's corner and colour tables, as
  local static arrays filled element by element (`SHM3`) and indexed by
  `Builtin.vertexIndex`, compile to a module that declares no `Int64` once
  `SHM6` holds.

**Spike progress (2026-10-20).** Both spikes were run before acceptance, on
the local toolchain (LLVM's SPIR-V backend at its pinned base and the
fork's branch), with the backend's lit suite (1314 tests) and the fork's
codegen suite green.

- **S1 holds, with three backend fixes and one open point.**
  - An explicit-offset uniform block (`std140`) and push-constant block
    (`std430`) validate for Vulkan 1.3 with exactly the offsets `layoutOf`
    gives, and their member names survive as `OpMemberName`.
  - Reading a member of an explicitly laid-out uniform block asserted in the
    backend. That is fixed.
  - A `std140` array whose stride exceeds its element, such as `float[4]` at
    stride 16, used to lower to an array of padded structs declaring an 8-bit
    member. It now lowers to `T[N]` with the padded stride and no `Int8`, and
    is read by index or by byte offset.
  - A duplicate type name is removed.
  - The open point, that the uniform block was a one-member wrapper around
    `T`, is settled by
    [`D25`](./decisions.md#d25-a-vulkan-uniform-block-is-its-struct): the
    block is `T`, and the backend change is part of M6.
- **S2 holds, with two backend fixes and one compiler fix.**
  - An `int`-indexed local table declares no `Int64` at `-O0` or `-O2`. The
    backend now indexes with the 32-bit value a widened index came from, and
    with 32-bit constants.
  - The fork initialises a constant-length array by one store, or by a loop
    counted in 32 bits
    ([`PetarKirov/ldc@6c966756`](https://github.com/PetarKirov/ldc/commit/6c9667564375c8061ef5fdc06358f9d2e672200a)).
  - The backend lowers a `memset` of a whole local to a store. A zero-filled
    local array used to crash the compilation at `-O2`.
- **R22, along the way.** Two more backend fixes clear the review's two
  `size_t` shapes:
  - In signed-integer mode, `OpUDiv`, `OpUMod` and `OpConvertFToU` need an
    unsigned result type at every width, so a `uint` division in a shader was
    invalid. They now compute in the unsigned type, between bitcasts.
  - An index the optimiser splits into an element and a byte offset past it,
    `t[i + 1]`, crashed the backend. Its whole-element steps now fold into the
    index.

  Both shapes now produce a valid module. One that really computes in 64 bits
  still declares `Int64`, and the diagnostic at its D line that `SHM6`
  requires is M6's fork work.

- **The existing effects are unchanged.** The 20 GLSL files of `sparkles:ui`'s
  effects, generated by the pinned toolchain and by the patched one, are
  byte-identical.

The seven backend fixes are carried as patches for the toolchain bump that opens M6
and are proposed upstream; until then the pinned toolchain (`SHT1`) does not
include them.

**Deliverable.**

- **Library.** `sparkles.shaders.capabilities` with the four profiles of
  `SHC2` and `activeProfile`; `@profiles`, `@builtin`, `Builtin`, `@resources`,
  `@binding`, `UniformBlock`, `PushConstants`, `UniformsOf`, `layoutOf`,
  `writeLayout`, `stagesLink`; the `float*` and `int*` aliases; host stand-ins
  for `@builtin` and `Builtin` (`SHV8`).
- **Compiler** (the fork): the vertex stage; built-in variables; struct
  results; interface structs flattened; uniform blocks, push-constant blocks
  and the default uniform block, laid out by `SHR6` and lowered per profile;
  interface variables keyed by stage, direction and name (`SHF2`); a uniform
  block emitted as its struct, with the backend's buffer lowering changed to
  match (`D25`); 32-bit
  indexing and its diagnostics (`SHM6`), with the backend's unsigned
  division and remainder on signed-integer types fixed upstream, and the
  shapes that failed (a `size_t` remainder, a `size_t` offset index) in the
  fork's and the backend's lit tests;
  `getTargetInfo("shaderProfile")`; the manifest; per-profile emission.
- **Build step.** The manifest, one compilation per profile, Vulkan
  validation, the capability audit, SPIR-V output files and their provenance,
  no output until every profile has succeeded (`SHP8`).
- **Consumer.** The triangle of `sparkles:vulkan-wsi` as one host-and-device
  D module built for `vulkan1.3`, with an aspect-ratio push constant, its
  committed GLSL and SPIR-V removed. The package follows `sparkles:ui`'s
  pattern: an opt-in `gpu-shaders` configuration generates the triangle's
  SPIR-V into `generated/shaders/` (git-ignored) with `--if-stale` and
  compiles the triangle renderer under a version identifier; the default
  configuration builds without the renderer and needs no device compiler;
  the triangle examples select `gpu-shaders`; CI takes the output prebuilt
  from a Nix derivation (`SHB3`). The test pattern's committed SPIR-V moves out
  of the swept directory. The renderer names each stage's entry point by its
  D identifier, and takes the push-constant range from `layoutOf` and the
  stages that declare it.
- **Oracle.** A Vulkan readback harness on the software rasterizer (lavapipe)
  in CI, with the Khronos validation layer loaded.

**Gate.**

- Every M6 row of the ledger `verified`.
- The effects of `sparkles:ui`, built for `gl330` and `gles100` by the M6
  toolchain from the source and recipe before the slice and from those after
  it, generate byte-identical GLSL; and the GPU readback of every effect
  matches its readback before the slice.
- The triangle, read back from lavapipe at three window aspects, matches the
  host evaluation of its vertex function: at pixel centres inset two pixels
  from each vertex toward the centroid, and at the centroid, the colour is
  the host's barycentric blend at that centre within 2 in 8-bit units, and
  coverage is asserted only at those pixels and at pixels two or more pixels
  outside every edge. The validation layer reports no message.
- Each new check is shown to fail on a deliberately broken input: a push
  constant over the limit, a capability its profile denies in the emitted
  module, a vertex output renamed against its fragment input, a `size_t`
  remainder under `vulkan1.3`.

**Entry condition.** The revision's Stage 0 accepted.

**Progress (2026-10-20).** The deliverable is built: the library, the
compiler (with sixteen more backend fixes, each with its lit test), the
build step, the triangle as one host-and-device D module, and its readback
on lavapipe in CI. The [evidence ledger](./testing.md#evidence-ledger)
records each row.

- **The gate's checks hold.** The effects' GLSL is byte-identical before and
  after the slice, so their readback is the slice's too. The triangle agrees
  with its host evaluation at three aspects, with no validation message,
  teardown included. Each named broken input fails its check, as do a
  device-only change to the triangle, a pipeline missing its push-constant
  range and a leaked pipeline.
- **Rows not yet `verified`:**
  - `SHV8`: no host call through the block stand-ins.
  - `SHF5`: integer vertex inputs are not checked against `intVertexInputs`.
  - `SHF6`: no `Sampler2D` flattened out of a `@resources` struct.
  - `SHR6`: no device readback of a `std140` uniform block.
  - `SHT3`'s SPIR-V half: first compared by this milestone's CI run.
- **The specification's `SHP3` disagrees with this plan.** `SHP3` requires a
  device-only module, and the deliverable puts the triangle's entry points in
  a host-and-device module. The build step accepts a unit with an entry
  point in any device module, and its provenance names the device-only
  modules and the entry point's own. The sentences of `SHP3`, `SHP7` and
  `SHP10` await the owner.
- **The build step derives two compiler flags.** It passes the resources'
  lowering (`-mdcompute-resources`) from what each profile grants, and asks
  for the 64-bit report (`-mdcompute-report-int64`) when the audit finds
  `Int64`, since the compiler knows a profile only by its name (`SHC1`).

## M7: Capability inference and stage operations

**Obligations.** `SHC7`, `SHC8`; the vocabulary's first capability-narrow
built-ins: derivatives (coarse and fine), terminate and demote, and `discard`
defined as one of them per profile, as [Concepts](../../research/shading-languages/concepts.md#discard-demote-and-terminate)
separates them; the fragment built-ins `fragCoord` and `frontFacing`, with
their origin and winding stated per profile.

**Entry condition.** M6.

## M8: One vector type

**Obligations.** `SHV10`: `sparkles.math`'s `Vector!(T, N)` meets the
vocabulary's representation and layout rules on host and device, with
`Matrix!(T, R, C)`; the vocabulary's aliases point at it. Its contract is a
page of `sparkles:math`'s specification, owned there.

**Entry condition.** M6; a refined contract for `sparkles:math`.

## M9: Vocabulary breadth

**Obligations.** Further scalar and vector types (`uint`, `bool`, `half`,
`double`), matrices, and GLSL's built-in families, each with its agreement
oracle and its capabilities.

**Entry condition.** M8.

## M10: Compute and storage

**Obligations.** Compute entry points beside dcompute's kernels; storage
buffers, storage images, workgroup memory, barriers and atomics; module-scope
constant tables.

**Entry condition.** M6.

## M11: Reference CPU executor

**Obligations.** `SHX1`–`SHX3`, refined into testable contracts first.

**Entry condition.** M7 and M10, which bring the operations it must define.

## M12: Further targets

**Obligations.** Profiles for GLSL ES 3.00, GLSL 4.60, HLSL by shader model,
MSL by version and WGSL through Tint, each with the capability set the
[translation ceiling](../../research/shading-languages/comparison.md#the-translation-ceiling)
records; the GLSL ES 1.00 profile retired once the Android build of raylib
moves to OpenGL ES 3.

**Entry condition.** M6.

## M13: Subgroups and convergence

**Obligations.** Subgroup and quad operations; the compiler emitting
convergence information so reconvergence points survive optimisation.

**Entry condition.** M11, so the operations have a CPU semantics to agree
with.

## M14: Further stages

**Obligations.** Geometry, tessellation, mesh and task, and ray tracing, as
LLVM's SPIR-V backend gains their execution models.

**Entry condition.** Backend support, upstream or in this project's patches,
with lit tests.

## M15: DXIL

**Obligations.** A second dcompute target on LLVM's DirectX backend, and the
D3D-only features it brings.

**Entry condition.** M12's Vulkan tiers delivered.

## M16: SPMD executor

**Obligations.** `SHX1`'s SPMD executor, agreeing with the reference executor
on the corpus.

**Entry condition.** M11.
