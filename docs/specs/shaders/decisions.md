---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders` — Decisions

The consequential choices behind [`SPEC.md`](./SPEC.md), with the evidence and
trade-offs of each, and the open questions that block named requirements.
`D1`–`D15` were accepted with the specification on 2026-10-16; `D16`–`D24`
are proposed with the revision that widens its scope, and are accepted with it.
A decision a later one supersedes says so, and keeps its text.

## Scope

The library's goal is to replace the shading languages — GLSL for OpenGL and
Vulkan, HLSL, Slang, WGSL and MSL — with single-source D: every stage and
feature they express, reached through SPIR-V where SPIR-V reaches it, and
through LLVM's DirectX backend later for what only DXIL expresses (`D23`). The
evidence base is the [research catalog](../../research/shading-languages/index.md).
Each capability below is outside the current milestones; an entry condition
says what brings it in.

| Not yet in scope                                          | Why                                                                                                             | Entry condition                                                             |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Geometry, tessellation, mesh, ray-tracing stages          | LLVM's SPIR-V backend has execution models for compute, vertex and fragment only                                | Backend support upstream, or in this project's LLVM patches, with lit tests |
| D3D-only features (work graphs, sampler feedback)         | No SPIR-V path reaches them                                                                                     | The DXIL target (`D23`)                                                     |
| Runtime shader compilation and hot reload                 | The device compiler is a build-time tool far too large to ship in a program                                     | None; a consumer may reload output the build regenerated                    |
| Drawing: registries, passes, pipelines, descriptor writes | A consumer's renderer owns them; the library hands it complete shaders, their layouts and their bindings        | None in this library                                                        |
| Editor diagnostics                                        | Owned by the analysis library ([`sparkles:dmd-lsp`](../dmd-lsp/targets.md)), which reads the same configuration | None in this library                                                        |
| Automatic differentiation                                 | Reverse mode needs a compiler transform (Enzyme on LLVM IR) the project has not evaluated                       | A consumer, and a feasibility spike                                         |

The exclusions of 2026-10-16 that this revision lifts — vertex stages, Vulkan
consumers, integer vectors — come back through the milestones of
[`PLAN.md`](./PLAN.md); matrices, further types and compute through later ones.

## Decisions

### D1: The vocabulary is GLSL's, spelled in D

> [!NOTE]
> Superseded in part by [`D20`](#d20-generic-types-hlsl-shaped-aliases-glsl-math-names): the math keeps GLSL's names and
> definitions; the types take HLSL-shaped names over generic types.

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

> [!NOTE]
> Amended by [`D16`](#d16-one-compilation-per-profile-capabilities-as-d-data): GLSL remains the output of the OpenGL
> profiles; a Vulkan profile hands consumers SPIR-V.

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

**Choice.** One device configuration per package (`SHP1`), selected by name
(`--config`, `shaders` by default) and accepted only if its dcompute target
flag names exactly one Vulkan target, and a unit discovered from the modules'
own `@compute` declarations (`SHP3`, `SHM5`).

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

> [!NOTE]
> Superseded for uniforms by [`D19`](#d19-blocks-in-d-lowered-per-profile): the OpenGL profiles keep these
> plain uniforms, and a Vulkan profile lowers the same declarations to blocks.
> The shared sampler stands.

**Choice.** A `@uniform` parameter is a plain uniform outside any block, and
every image is read through one sampler at binding 0 (`SHR7`).

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

### D9: `vec3` is a struct on the host, laid out like the device's vector

**Choice.** A native three-element vector on the device, a three-`float`
struct on the host aligned to 16 bytes, so both occupy 16 (`SHV2`), with a
packed 12-byte variant for host storage. A `vec3` may then cross the shader
interface like any other vector (`SHF5`).

**Why.** The device needs a native vector: a struct `vec3` copied by memory
is a load the SPIR-V backend cannot legalise. On the host, a released LDC
sizes the vector at 12 bytes and LLVM at 16, which is a compiler error inside
any struct, and DMD has no such vector; a struct avoids both. Giving it the
device's alignment, rather than a packed 12 bytes, keeps the bytes of a
struct or an array of vectors the same on both sides, in the device
compiler's memory layout, which is what memory the two share needs. It is
not `std140`, which packs a scalar into a `vec3`'s padding; a `std140`
uniform block, when one is needed, takes its own layout rules.

**Trade-offs.** An array of `vec3` on the host takes a third more memory
than three floats per element; code that stores many uses `Vec3Packed`.

**Revisit if.** Every host compiler the vocabulary supports has a native
16-byte three-element vector; then the host can use it too.

### D10: The build step depends on Phobos alone

**Choice.** `shader-compile` uses only Phobos and the vocabulary package.

**Why.** It runs inside the build of the packages that use it. A dependency
on a package that itself uses generated shaders would make the tool a
prerequisite of its own build.

### D11: Unit membership is a fileset digest

**Question.** How does the stamp notice a device module that was not part of
the last build, without running dub?

**Alternatives.** A directory listing taken at generation and compared at
the next build; or a deterministic digest of the device modules among the
unit's candidate files (their paths and modes), resolved as a fileset.

**Choice.** The digest (`SHB4`), once `sparkles:build-primitives` provides
filesets and a digest scheme.

**Why.** A bespoke listing would be a second, private file walker with its
own ignore and ordering rules, which the filesets library exists to replace.
A digest over the device modules' paths and modes changes exactly when
membership does, and is reproducible: it does not change
with timestamps, enumeration order or the checkout's location, so a stamp
made on one machine is valid on another.

**Trade-offs.** `SHB4` waits for two prerequisites that are not delivered;
until then a new device module is seen only when another input changes.

### D12: Agreement is judged by the Vulkan precision table

**Question.** What difference between a host result and a device result does
the agreement oracle accept (`SHV7`, `SHF4`), where GLSL leaves precision to
the implementation? This resolves open question Q3.

**Alternatives.** A single loose tolerance for everything; the GLSL 4.60
precision table, which leaves `sin` and `cos` unspecified; or the precision
the Vulkan specification requires of the SPIR-V `GLSL.std.450` instructions
the shaders are compiled to.

**Choice.** The Vulkan table, at full single precision, over argument ranges
where it states a bound:

| Operations                                                           | Bound                                                   |
| -------------------------------------------------------------------- | ------------------------------------------------------- |
| `floor`, `abs`, `min`, `max`, `clamp`, `step`, sampling              | exact                                                   |
| `fract`, `mod`, `mix`, `smoothstep`, `dot`, `length`, `luma`, `sqrt` | 8 ULP of the largest of the result, the arguments and 1 |
| `sin`, `cos`                                                         | absolute 2⁻¹¹, for arguments in [−π, π]                 |
| `exp`                                                                | (3 + 2·\|x\|) ULP                                       |
| `pow`                                                                | relative 2⁻¹⁷, for x in [0.5, 4] and y in [−2, 2]       |

Construction and component access are exact; vector `+`, `-` and `*` are
correctly rounded per operation, contraction allowed, and `/` is within 2.5
ULP for divisors in [2⁻¹²⁶, 2¹²⁶]; denormals may flush to zero. The compound bounds allow for the few correctly rounded operations each
is defined by, contracted or not. `mod` samples whose quotient lies within
rounding of an integer are excluded: there one rounding moves `floor` by a
whole step on either side.

**Why.** It is the one table that bounds every operation the vocabulary
offers on the code path the shaders actually take. The bounds are checked
both ways in `ui_raylib.shader_readback.boundsAcceptTheirLimitAndNoMore`.

**Trade-offs.** It is evidence on one driver at a time, the software
rasterizer in CI, and in a desktop context: the GLSL ES output runs through
the driver's GLSL ES front end there, at single precision, so `highp` is
`D15`'s assumption. Arguments outside the stated ranges are not tested,
because no bound exists there to test against.

### D13: The compiler enforces the interface contract

**Question.** Where are `SHF2`'s one-variable-per-name rule, `SHF5` (what
crosses the interface) and `SHF6` (handles stay scalar) enforced?

**Alternatives.** In the compiler's fragment stage, or in the build step,
from the disassembly of the module the compiler emitted.

**Choice.** The compiler's fragment stage, which builds the interface from
the signature and already rejects an unmarked parameter (`SHF2`) and another
stage (`SHF7`).

**Why.** The diagnostic points at the D parameter and names both entry
points of a clash, where a disassembly check can name only a SPIR-V
variable. The types the build step could only reject, the compiler can
declare correctly instead: a signed `int`, a struct with its member names.
A disassembly scanner in the build step was a parser of another tool's text
format, about a hundred lines with its own tests. `SHF6` holds by
construction: a `Sampler2D` is accepted only as a parameter, never inside a
uniform struct, and the fork keeps handles in SSA form.

**Trade-offs.** Each change to the contract is a compiler change, a pin
bump (`SHT1`) and a rebuild of the device toolchain on every platform.

### D14: Nix owns the output's freshness; the stamp is a shortcut

**Question.** What must the build step's stamp record for `--if-stale` to
be trusted (review `R2`)? The compilation also reads modules the unit imports
without containing them, the compiler and its runtime, and the step's own
pipeline, and the stamp records none of them.

**Alternatives.** Record every file the compiler reports reading, and the
identity of each tool, so the stamp is exact; or leave exactness to the
system that already has it.

**Choice.** Nix. The `ui-shaders` derivation's inputs are the source closure of
the consumer and the toolchain derivations, so every artifact built from it
(the apps, the APK, CI) is regenerated exactly when any of them changes, and
placed with a `prebuilt` stamp. The stamp itself covers what a developer edits:
the unit's modules and their recipes, hashed before compiling.

**Why.** Exact dependency tracking is a build system's job, and one is
already in charge of every output that ships. Re-implementing it in the step
would mean parsing the compiler's dependency output and fingerprinting
tools, for the edit loop alone.

**Trade-offs.** In a developer's checkout, a change to a module the unit
only imports (`sparkles.shaders.attributes`), or to the toolchain, leaves the
output fresh until a run without `--if-stale`. Entering a new dev shell after a
pin change is when that run is needed.

### D15: The GLSL ES output requests `highp`

**Question.** The ES output qualifies every variable `highp`, which a GLSL ES
1.00 fragment shader need only support where `GL_FRAGMENT_PRECISION_HIGH` is
defined (review `R8`, formerly Q4). Keep it, or drop to `mediump`?

**Choice.** Keep `highp`. The project's Android floor is the
`VP_ANDROID_baseline_2022` profile, which requires Vulkan 1.1.

**Why.** At `mediump` the CRT tube rendered visibly wrong on a phone whose
`mediump` is half precision (an Adreno GPU: rows that should be uniform
alternated, a one-pixel line moved), and the generated `highp` tube matched the
desktop. Every device at the floor has a GPU that computes fragment shaders
in single precision for Vulkan.

**Trade-offs.** That such a device's OpenGL ES driver exposes `highp` to a GLSL
ES 1.00 shader follows from its GPU, not from a clause of the profile or of
the Android compatibility definition that this specification has located;
it is an assumption, checked on the devices tested. Translating to GLSL ES
3.00, where fragment `highp` is mandatory, would make it a guarantee and needs
an OpenGL ES 3 context.

### D16: One compilation per profile; capabilities as D data

**Question.** How does a shader target several outputs — Vulkan SPIR-V, GLSL
for OpenGL and OpenGL ES, later HLSL, MSL, WGSL — when each grants different
features, and how does the source say which it is for?

**Alternatives.** A list of targets in the build recipe; consumer-chosen
outputs, with failures only when a consumer asks for one; one compilation for
every target, with per-target choices made at code generation (as dcompute's
`__dcompute_reflect` does); or one compilation per profile, with the profile a
compile-time constant.

**Choice.** One compilation per profile (`SHC6`), the profile reported by
`__traits(getTargetInfo, "shaderProfile")` (`SHC3`), the profiles an entry
point is for declared beside it with `@profiles` (`SHC4`) and gathered by the
compiler's manifest (`SHC5`), and the capability table written in D
(`SHC1`).

**Why.** D's compile-time evaluation runs once per compilation, shared by
host and every device target; only one profile per compilation lets `static
if`, templates and `static assert` branch on it, which is the D counterpart of
Slang's capability system and target switch, with the table readable and
testable as ordinary D rather than a compiler file. Declaring profiles beside
the entry point keeps the fact next to the code it constrains.

**Trade-offs.** N profiles cost N device compilations. A profile's lowering
choices (blocks or loose uniforms) are passed to the compiler by the build
step, which reads them from the same table.

**Revisit if.** Build time is dominated by repeated semantic analysis of the
unit.

### D17: Capabilities are checked three times

**Question.** Where is a use of a capability the active profile lacks
rejected?

**Alternatives.** Only in the vocabulary (a `static assert` in each built-in);
only in the compiler; or at three layers.

**Choice.** Three: the vocabulary declares requirements and selects
implementations per profile, compiling the gap to `unsupported` (`SHC7`); the
compiler infers each emitted entry point's requirements through the call graph
and reports the chain (`SHC8`); and the build step audits the emitted module's
capabilities (`SHC9`).

**Why.** A `static assert` in a built-in would fire in every compilation that
analyses a caller, including callers that belong to entry points built for
other profiles — every function of the unit is analysed in every
compilation. Only the compiler knows which entry points are emitted. The
audit catches what neither declares: capabilities the compiler introduces.

**Trade-offs.** `SHC8` is compiler work; until it lands, the audit and
per-profile compilation are the checks. This refines the owner's choice of a
static-assert-based check in the vocabulary, for the reason above; the owner
accepted the refinement with the revision on 2026-10-20.

### D18: Resources are parameters or interface structs

**Question.** How does a shader declare the resources it reads?

**Alternatives.** Module-scope declarations with bindings, as GLSL and HLSL
do; entry-point parameters; or a struct of resources the entry point takes.

**Choice.** Parameters and interface structs both, the struct flattened into
parameters (`SHR2`).

**Why.** A parameter keeps the entry point an ordinary D function the CPU
executor can call with host values; a struct groups a shader's resources, or
a set several entry points share, without repeating them. Module-scope
resources would lift the device pass's global-variable rule and give the
executor globals to bind.

**Trade-offs.** Two spellings of one thing; flattening makes them one
interface.

### D19: Blocks in D, lowered per profile

**Question.** Vulkan requires every uniform value in a block; raylib's OpenGL
path binds plain uniforms by name and cannot bind a block. How do the two
coexist?

**Alternatives.** Two declaration forms, one per target family; blocks on
every target, with OpenGL consumers binding uniform buffers; or one
declaration lowered per profile.

**Choice.** One declaration, lowered per profile (`SHR3`–`SHR5`): a uniform
block or push-constant block under `vulkan1.3`, one named uniform per field
under the OpenGL profiles. `@uniform` parameters stand for fields of a default
block, and their OpenGL output is unchanged.

**Why.** A shader builds for both kinds of consumer without edits, and the
OpenGL output of every existing effect is unchanged: built with one toolchain
from the source before the revision and after it, the GLSL is byte-identical.

**Trade-offs.** The two lowerings are different interfaces of one source, and
a host binds them differently: by name on OpenGL, by binding and offset on
Vulkan, with the offsets of `SHR6`.

### D20: Generic types, HLSL-shaped aliases, GLSL math names

**Question.** What do the vocabulary's names look like, now that it serves
every shading language rather than GLSL alone?

**Choice.** Types are generic — `sparkles.math`'s `Vector!(T, N)` and
`Matrix!(T, R, C)`, once unified (`SHV10`) — with HLSL-shaped aliases
(`float4`, `int2`, `float4x4`, `half4`); math functions keep the names GLSL,
WGSL and MSL share (`mix`, `fract`, `smoothstep`); operations on resources and
stages are methods of their types (`texture.sample(uv)`), in D's naming.
GLSL's `vec*` names remain as aliases. For the fragment stage's operations,
[`D27`](#d27-the-fragment-stages-operations-are-free-functions) supersedes
this: they are free functions.

**Why.** `float4` reads the same in HLSL, Slang, MSL and D, and avoids GLSL's
column-major `mat3x2` naming; the math names are the ones most languages
share; methods replace GLSL's free-function texture zoo with D's own idiom.

### D21: Evidence is a conformance corpus

**Question.** The exclusions of 2026-10-16 came back when a consumer needed
one. What drives and verifies features now that the goal is completeness?

**Choice.** A conformance corpus: permissively licensed samples as pinned
flake inputs (ported to D, the originals kept external), hand-written shaders
per feature, and the project's own effects. A feature is delivered when its
corpus shaders compile for every profile that grants it, validate, and agree
with the CPU executor under a GPU readback. Until the executor exists (M11),
agreement is with the host execution of the same D functions, as the
milestone's oracle defines it.

**Trade-offs.** Porting samples is work that a consumer would otherwise pay
for once; the first slice still has a real consumer (the triangle of
`sparkles:vulkan-wsi`).

### D22: A scalar reference executor, then SPMD on SIMD

**Choice.** The CPU executes GPU semantics — subgroups, quads, derivatives,
barriers — first in a scalar reference executor that pins the semantics, and
later in an SPMD executor that runs invocations as SIMD lanes, checked
against the reference (`SHX1`).

**Why.** The research found no system that runs fragment shaders on a CPU
with quads and derivatives, and two precedents that disagree on edge cases;
semantics first, speed second.

### D23: SPIR-V first; DXIL later

**Choice.** Every feature SPIR-V reaches goes through the LLVM SPIR-V path
and the translators; D3D-only features come with a second dcompute target on
LLVM's DirectX backend, after the SPIR-V side covers the Vulkan tiers.

**Why.** One device path covers Vulkan, OpenGL, OpenGL ES, Metal (through
SPIRV-Cross) and the web (through Tint and naga); the DirectX backend is the
one Clang HLSL builds, and Microsoft has announced SPIR-V for Direct3D 12 from
Shader Model 7.

### D24: LLVM stays the device path; MLIR is a contribution

**Choice.** Device code keeps going through LLVM IR and its SPIR-V backend,
structured before the backend (since #659); the project contributes its
control-flow cases to the LDC MLIR effort's lowering to MLIR's structured
form, and switches device code generation only if that path beats this one on
the corpus.

**Why.** MLIR's SPIR-V dialect keeps structure by construction but lacks
graphics operations (derivatives, demote, terminate), and a second code
generator in LDC is a large cost to take on speculatively.

### D25: A Vulkan uniform block is its struct

**Question.** The backend emits every Vulkan buffer as a new one-member
struct `{ T }` decorated `Block`, so a uniform block's type is unnamed and
its fields sit one level below it (spike S1; raised as `Q5`). Is a uniform
block `T` itself, or that wrapper?

**Alternatives.** Keep the wrapper and say so in `SHR5` and `SHR8`, named
or unnamed; have the fork declare uniform blocks itself, as plain globals
decorated through metadata, as it does push constants; or have the backend
decorate a buffer's single struct as the block.

**Choice.** The block is `T`: under `vulkan1.3`, the compiler **must** emit a
uniform block whose type is `T`, decorated `Block`, with no struct around
it, and the backend is changed so a buffer whose contents are one struct
makes that struct the block. Buffers whose contents are not one struct
(arrays, runtime arrays) keep their wrapper, which SPIR-V requires.

**Why.** It is the block `SHR5` and `SHR8` describe, so names reach
reflection and every translated output unchanged, and a later profile that
binds blocks by name (GLSL 4.60, ES 3.x) needs no special case. It is also
how the reference HLSL compiler (DXC) emits a `cbuffer`, which makes the
backend change a defensible upstream proposal.

**Trade-offs.** It changes how the shared backend lowers buffers, which
upstream may decline; until it lands, the toolchain carries it as a patch.
If it is declined, the fallback is the wrapper named after `T`, with `SHR5`
and `SHR8` amended. A `T` used both as a block and as a plain value needs
the two types kept apart, which the explicit-layout type already does.

### D26: The compiler is granted capabilities, not profiles

**Question.** The compiler knew a profile only by its name (`SHC1`), so
everything it had to decide from a profile's capabilities reached it as a
flag of its own: how resources lower (`-mdcompute-resources`), and, next,
whether an integer vertex input is allowed (`SHF5`) and which stages are
(`SHF7`). Each new capability check would add one. Where should the
compiler learn what a compilation may use?

**Alternatives.**

- Keep one derived flag per need.
- Move the whole table into the compiler's druntime (`ldc.dcompute`), read
  at compile time, so the compiler selects the profile itself.
- Keep the table in the library and grant each compilation its profile's
  capabilities as one list, checked against a vocabulary the compiler
  recognises.

**Choice.** The last. The build step passes the profile's name and its
grants, closed under the implications:
`-capabilities=shader:<capability>,…`. The compiler checks the names against
`ldc.dcompute.Capability`, which a device compilation asserts names the
same capabilities as `Cap`, and derives what it enforces: the resources'
lowering (`SHR3`–`SHR5`), the stages (`SHF7`), integer vertex inputs
(`SHF5`), and later the requirements of `SHC7` and `SHC8`. The option is
generic in its domain (`shader:`), so a CPU feature floor or an OS API
level can be granted the same way. `-mdcompute-report-int64` stays a mode
of its own: it is a diagnostic, not a capability.

**Why.** One option replaces a flag per check, and every check is made by
the compiler, at the D line. Which profile grants what stays policy the
library owns and can change without a compiler release, while M7–M12
change the table often. A small, policy-free interface is also what can be
proposed upstream.

**Trade-offs.** The vocabulary exists twice, the library's `Cap` and the
compiler's `Capability`, kept in step by an assertion; a new capability
changes both. A compiler invoked directly must be given the grants, or it
checks nothing. Code that runs above a compilation's floor behind a runtime
test (a CPU feature, an OS version) needs the compiler to know which test
grants what to the code it guards: a flow-sensitive check, recorded as
issue #667 and not part of this design.

### D27: The fragment stage's operations are free functions

**Question.** How are derivatives, ending and demoting an invocation, and the
fragment's position and facing spelled, what does `discard` mean when the
outputs disagree, and whose convention does the position follow?

**Alternatives.**

- Free functions, with HLSL's names (`ddx`, `ddxFine`) or WGSL's (`dpdx`,
  `dpdxFine`); or methods of a stage handle an entry point takes
  (`frag.dpdx(v)`), so the stage is a type and a vertex entry point cannot
  reach them.
- `discard` as terminate on every profile, or as demote where the profile
  grants it.
- The position in each output's own convention, stated per profile, or one
  convention for all, which `gles100` can only have by a hidden uniform holding
  the framebuffer's height.

**Choice.** Free functions with WGSL's names, each declaring the fragment
stage and its capability with `@requires`, checked through the call graph
(`SHC8`); the position and facing as `@builtin` parameters, like the vertex
stage's (`SHF8`). `discard` is terminate on every profile, and `demote` a
built-in of its own, which only `vulkan1.3` grants. The position follows each
output's convention, recorded as `Profile.fragCoordOrigin`. `gles100` grants
no derivatives, as OpenGL ES 2.0 has them only as an extension.

**Why.** Every source language spells these as free functions, and WGSL's
family is the most regular and mirrors SPIR-V's `OpDPdx`. The stage is
already checked where it matters, by the call graph, which a stage handle
would duplicate in the types and make every helper take. One meaning of
`discard` keeps a shader's outputs alike; a shader that needs its quad's
derivatives after discarding says so with `demote`. Each output's own
origin costs nothing and hides nothing.

**Trade-offs.** Derivatives after a `discard` in the quad are undefined, as in
GLSL. Code that needs one origin on every profile branches on it. A shader
that uses derivatives builds for `gl330` and `vulkan1.3` and not `gles100`,
until an ES 3.00 profile exists (M12).

### D28: Samplers are resources of their own

**Question.** Every image was read through one shared sampler, but a
consumer reads glyph atlases with nearest filtering and images with linear
filtering in one entry point (the Vulkan canvas's `UVQ4`). How does a shader
name the sampler an image is read through?

**Alternatives.**

- `SamplerState` parameters, each a descriptor at its binding, named at the
  sample: `atlas.sample(nearest, uv)`.
- A sampler description on the image, `@sampler(Filter.nearest) Sampler2D`,
  lowered to an immutable sampler or texture parameters the host applies.

**Choice.** `SamplerState` parameters and fields; `image.sample(uv)` keeps the
shared sampler at binding 0 (`SHR7`).

**Why.** It is SPIR-V's own model and HLSL's, WGSL's and Slang's: an image
and a sampler are separate objects, combined at the sample. An image may be
read through several samplers, and sampler state stays the host's, out of
the shader's ABI. Existing shaders read through the shared sampler
unchanged.

**Trade-offs.** OpenGL has no separate samplers: the translation gives each
(image, sampler) pair a sampler uniform, so an image read through two
samplers is two uniforms the host binds the texture to twice (`SHR8`).

### D29: The Android floor is Vulkan 1.1, as SPIR-V 1.3

**Question.** (Q3, and the phone terminal's `UVQ3`.) `VP_ANDROID_baseline_2022`
guarantees Vulkan 1.1, which consumes SPIR-V up to 1.3, and the only Vulkan
profile emitted SPIR-V 1.6. Which profile serves the Android floor?

**Alternatives.**

- `vulkan1.1`, emitting SPIR-V 1.3, which every Vulkan 1.1 device accepts.
- SPIR-V 1.4 through `VK_KHR_spirv_1_4`, which the reference phone offers but
  the baseline does not guarantee.

**Choice.** `vulkan1.1`: SPIR-V 1.3, validated for Vulkan 1.1, granting what
`vulkan1.3` grants but `demote`; its files carry the version
(`<entry>.vk11.frag.spv`), so one unit builds both. The compiler emits the SPIR-V
a Vulkan target consumes, and LLVM's logical SPIR-V target accepts the
Vulkan 1.0 and 1.1 triples (a patch, proposed upstream with the rest).

**Why.** The floor is what every device of the baseline accepts, not what one
phone offers. Terminate lowers to `OpKill` before 1.6, which means the same;
demote needs an extension at 1.3, so the profile does not grant it.

**Trade-offs.** A second Vulkan output per entry point, where a unit asks
for both. A 1.4 profile can follow if something needs what 1.4 adds.

## Open questions

| ID  | Question                                                                                                                                                  | Affects | Decision point             |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | -------------------------- |
| Q1  | Which further platforms get a device toolchain, and how? Windows needs LLVM and LDC cross-built for MSVC, or built natively, and published as an archive. | `SHT4`  | A consumer needing it (M5) |
| Q2  | Does the output variable keep the name `finalColor`, a convention of one OpenGL framework, when the fragment stage is proposed upstream?                  | `SHF3`  | Upstreaming the stage      |
