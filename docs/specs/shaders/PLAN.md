---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-16
---

# `sparkles:shaders` — Delivery plan

The order in which the requirements of [`SPEC.md`](./SPEC.md) are delivered,
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

**Deliverable.** The disassembly checks of section 6, a GPU readback harness
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
  returns among short-circuit masks. The tube avoids both.

## M5: Further device platforms

**Obligations.** `SHT4` extended to the platforms an accepted resolution of
[open question Q1](./decisions.md#open-questions) adds.

**Entry condition.** Q1 resolved: a consumer needs generated shaders on a
platform the device toolchain does not reach.
