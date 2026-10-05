---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-05
---

# `sparkles:shaders` — Decisions

The consequential choices behind [`SPEC.md`](./SPEC.md), with the evidence and
trade-offs of each, and the open questions that block named requirements. A
decision is `proposed` until the specification is accepted.

## Exclusions and entry conditions

Each capability below is outside the specification. An entry condition says
what evidence would bring it back; without one, the item is not planned.

| Excluded                                     | Why                                                                                                              | Entry condition                                                                     |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Vertex, geometry and tessellation stages     | Every consumer draws textured quads; the fragment stage carries all the effect logic.                            | A consumer whose effect needs per-vertex work it cannot express on a quad.          |
| Compute kernels                              | dcompute already compiles them; this library adds nothing a kernel needs.                                        | None in this library.                                                               |
| Matrices, integer and double vectors         | No effect uses them; each multiplies the vocabulary's surface and its CPU/GPU agreement tests.                   | A consumer effect that needs one, with its agreement oracle.                        |
| Vulkan and SPIR-V consumers                  | Consumers draw through OpenGL; a Vulkan consumer needs descriptor sets and push-constant blocks (`D7`).          | A Vulkan renderer in a consumer; then a target flag selects Vulkan-shaped uniforms. |
| Runtime shader compilation and hot reload    | The device compiler is a build-time tool far too large to ship in a program.                                     | None; a consumer may reload GLSL the build regenerated.                             |
| Drawing: registries, passes, texture binding | A consumer's renderer owns them; the library hands it complete shaders.                                          | None in this library.                                                               |
| Editor diagnostics                           | Owned by the analysis library ([`sparkles:dmd-lsp`](../dmd-lsp/targets.md)), which reads the same configuration. | None in this library.                                                               |

## Decisions

### D1: The vocabulary is GLSL's, spelled in D

**Question.** Should effects be written against D's numeric idioms, with a
translation to GLSL, or against GLSL's own names and definitions?

**Choice.** GLSL's: `vec3`, `mix`, `smoothstep` and `mod` with GLSL's
definitions, as free functions and UFCS in D.

**Trade-offs.** An effect reads like the shader it becomes, and GLSL
documentation applies to it directly. The cost is D code that looks foreign
to a D reader, and constructors (`v3(…)`) that differ from GLSL's (`vec3(…)`)
because a type alias cannot be called.

**Revisit if.** A D-idiomatic numeric library gains a SPIR-V lowering that
gives the same guarantees.

### D2: A fragment stage in the compiler, not a library wrapper

**Question.** Can the shader interface be built in D, around an ordinary
dcompute kernel, or must the compiler synthesise it?

**Choice.** The compiler. A fragment entry point needs interface variables
with locations, a uniform per parameter, images with bindings and an output
variable — SPIR-V module-level declarations a D library cannot emit. The
stage is a set of commits on top of the dcompute Vulkan target
([ldc#5132](https://github.com/ldc-developers/ldc/pull/5132)), pinned by
revision (`SHT1`).

**Trade-offs.** It needs a compiler fork, and the fork must be maintained
until upstream accepts the stage. In exchange, entry points are ordinary D
functions whose interface is checked at compile time.

**Revisit if.** Upstream LDC gains graphics stages; the pin then moves to it,
and any divergence from `SHF1`–`SHF7` is a contract change.

### D3: Generate GLSL, not SPIR-V, for consumers

**Choice.** The build step translates the SPIR-V to GLSL 3.30 and GLSL ES
1.00 and validates both.

**Why.** Consumers draw through OpenGL 3.3 and OpenGL ES 2.0, which load GLSL
source. Keeping the SPIR-V as the compiler's output, and GLSL as the
consumer's input, means one compiler serves both dialects.

**Revisit if.** A consumer loads SPIR-V directly (OpenGL 4.6 or Vulkan).

### D4: The device switch is LDC's own version identifier

**Choice.** `LDC_DCompute`, which LDC predefines under a dcompute target,
selects the device representation and the real attributes (`SHM2`).

**Why.** An earlier design used a private version identifier passed beside
the target flag. It restated the target, and the two could disagree: a build
could set one without the other.

### D5: The build recipe is the unit table

**Question.** Where does a package say which modules are shader code and how
they compile?

**Alternatives.** A separate manifest listing each unit's sources, import
paths and output; one dub configuration per unit; or one device configuration
per package, with the unit discovered.

**Choice.** One device configuration per package (`SHP1`), recognised by its
dcompute target flag rather than its name, and a unit discovered from the
modules' own `@compute` declarations (`SHP3`, `SHM5`).

**Trade-offs.** Nothing is restated: dub already knows the import paths, the
flags and the dependencies, and the modules already say they are shader code.
A hand-kept manifest drifted from both. The cost is that membership is known
only by reading the sources, which is why the stamp must record it
(`SHB4`, `D11`).

### D6: Generated at build time, never committed

**Alternatives.** Commit the generated GLSL and verify it in CI, or generate
it in every build that uses it.

**Choice.** Generate it in the build, behind a freshness stamp (`SHB1`–`SHB3`).

**Why.** Committed output is a second copy of the source that a reviewer must
regenerate by hand and that can be stale in any commit. A stamp makes the
build step nearly free when nothing changed, so generating in the build costs
nothing in the common case.

**Trade-offs.** Every build that uses the GPU half needs the device compiler.
`D8` confines that to the builds that ask for it, and a packager can supply
the output prebuilt (`SHB3`).

### D7: OpenGL-shaped uniforms and one shared sampler

**Choice.** A `@uniform` parameter is a plain uniform outside any block, and
every image is read through one sampler at binding 0 (`SHF2`).

**Why.** OpenGL consumers look uniforms up by name, so a plain named uniform
is exactly what they need after translation. SPIR-V for Vulkan cannot hold a
sampler beside an image in one handle (`SHF6`), and one shared sampler is the
simplest model of GLSL's combined `sampler2D`.

**Trade-offs.** The SPIR-V is valid only under the universal rules (`SHP4`);
a Vulkan consumer would need push constants and a sampler per image.

### D8: Opt-in per configuration, selected beside the dependency

**Choice.** Generated shaders live in a separate dub configuration (`SHB5`),
and a consumer selects it in each configuration that adds the dependency
needing it (`SHB6`).

**Evidence.** dub applies a dependency's top-level `subConfiguration`, and one
in its library configuration, even when the dependency is reachable only
through a parent configuration that the build does not select. In a scratch
graph (app → host with `tui` and `gui` configurations → backend → library),
a selection in the backend's top level or library configuration reached the
library through the unselected `gui`. A selection inside `gui` itself did not.

**Trade-offs.** Every configuration that adds the backend repeats one line,
and a forgotten one is caught only if the consumer asserts it at compile time.

### D9: `vec3` differs between host and device

**Choice.** A native three-element vector on the device, a three-`float`
struct on the host (`SHV2`), and no `vec3` at the shader interface (`SHF5`).

**Why.** The device needs a native vector: a struct `vec3` copied by memory
is a load the SPIR-V backend cannot legalise. On the host, the frontend of
the pinned LDC sizes the vector at 12 bytes and LLVM at 16, which is a
compiler error inside any struct; three floats avoid it.

**Revisit if.** The host LDC release carries the odd-width vector fix; then
both sides use the native vector.

### D10: The build step depends on Phobos alone

**Choice.** `shader-compile` uses only Phobos and the vocabulary package.

**Why.** It runs inside the build of the packages that use it. A dependency
on a package that itself uses generated shaders would make the tool a
prerequisite of its own build.

### D11: Unit membership is a fileset digest

**Question.** How does the stamp notice a device module that was not part of
the last build, without running dub?

**Alternatives.** A directory listing taken at generation and compared at
the next build; or a deterministic content digest of the unit's candidate
files, resolved as a fileset.

**Choice.** The digest (`SHB4`), once `sparkles:build-primitives` provides
filesets and a content-digest scheme.

**Why.** A bespoke listing would be a second, private file walker with its
own ignore and ordering rules, which the filesets library exists to replace.
A digest over paths and contents is also reproducible: it does not change
with timestamps, enumeration order or the checkout's location, so a stamp
made on one machine is valid on another.

**Trade-offs.** `SHB4` waits for two prerequisites that are not delivered;
until then a new device module is seen only when another input changes.

## Open questions

| ID  | Question                                                                                                                                                  | Affects        | Decision point             |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | -------------------------- |
| Q1  | Which further platforms get a device toolchain, and how? Windows needs LLVM and LDC cross-built for MSVC, or built natively, and published as an archive. | `SHT4`         | A consumer needing it (M5) |
| Q2  | Does the output variable keep the name `finalColor`, a convention of one OpenGL framework, when the fragment stage is proposed upstream?                  | `SHF3`         | Upstreaming the stage      |
| Q3  | What tolerance does the agreement oracle accept where GLSL leaves precision to the implementation, as for `sin` and `pow` at large arguments?             | `SHV7`, `SHF4` | Start of M3                |
| Q4  | Should the GLSL ES output request `highp` float where the device supports it, instead of `mediump`, so the ES bound matches the desktop one?              | `SHV7`, `SHP5` | Start of M3                |
