---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — Profiles and capabilities

How a shader says which targets it is for, and how the toolchain proves it uses
only what each of them offers. A [profile](#terms) names one output — a shading
language or SPIR-V environment, its version, and the capabilities it grants —
and every device compilation is a compilation for exactly one profile. This page
is part of the [specification](./SPEC.md); the decisions behind it are
[`D16`](./decisions.md#d16-one-compilation-per-profile-capabilities-as-d-data)
and [`D17`](./decisions.md#d17-capabilities-are-checked-three-times).

## Terms

- **Capability.** One thing a target may or may not offer: a stage, a type
  width, an instruction family, a resource kind (`fragmentStage`,
  `derivatives`, `int64`, `pushConstants`, `subgroupBallot`, …). Capabilities
  imply others: `subgroupBallot` implies `subgroupBasic`.
- **Profile.** A named output: its kind (SPIR-V for an environment, or a
  shading language), its version, the file each stage's output is written to,
  and the set of capabilities it grants, closed under implication.
- **Active profile.** The one profile a device compilation is for.
- **Requirement.** The capabilities a function needs, declared on it or
  inferred from what it calls.

## Profiles

**SHC1: Profiles are data.** Capabilities, their implications and the
profiles **must** be declared once, as D data, in the module
`sparkles.shaders.capabilities`, and **must** be readable at compile time by
ordinary D code, by the build step and by the compiler's checks. Adding a
profile or a capability **must not** require a change to the compiler.

_Rationale:_ The table is what a reader consults to learn what a target
offers; as D data it is tested like any other code, and the vocabulary, the
build step and the shader author all read the same one.

**SHC2: The profiles of the first slice.** The table **must** define at least:

| Profile     | Output                                       | Stages           | Files written per entry point          |
| ----------- | -------------------------------------------- | ---------------- | -------------------------------------- |
| `gl330`     | GLSL 3.30, translated by SPIRV-Cross         | fragment         | `<entry>.frag`                         |
| `gles100`   | GLSL ES 1.00, translated by SPIRV-Cross      | fragment         | `<entry>.es.frag`                      |
| `vulkan1.3` | SPIR-V 1.6 for Vulkan 1.3, validated as such | vertex, fragment | `<entry>.vert.spv`, `<entry>.frag.spv` |
| `cpu`       | the host compilation (no device output)      | —                | —                                      |

The capabilities of each are recorded in the table itself. A profile's
capability set **must** be a subset of what its output can express and what
its validator accepts: `vulkan1.3` grants push constants and uniform blocks and
denies loose uniforms; `gl330` and `gles100` grant loose uniforms; `gles100`
denies integer bit operations and dynamic loop bounds.

**SHC3: The active profile is a compile-time fact.** In a device compilation,
`__traits(getTargetInfo, "shaderProfile")` **must** evaluate to the active
profile's name; in a host compilation it **must** evaluate to `"cpu"`. The
library **must** provide `activeProfile`, the profile of that name from the
table, so that `static if`, `static assert` and template constraints can
branch on it. A device compilation whose profile is not in the table **must**
fail before semantic analysis of the unit, naming the profile.

_Rationale:_ D's compile-time evaluation runs once per compilation, for host
and device alike; a profile can only be something code branches on if each
compilation has one.

## Declaring a shader's profiles

**SHC4: `@profiles`.** An entry point **may** carry `@profiles(p, …)`, naming
profiles by the table's identifiers (`vulkan13`, `gl330`, `gles100`); a device
module **may** carry it on its declaration, as the default for its entry
points. An entry point's own `@profiles` **replaces** its module's. An entry
point with neither builds for `gl330` and `gles100`, the outputs of the
specification before profiles existed. A name that is not in the table
**must** fail the compilation at the attribute.

**SHC5: The manifest.** Before compiling for any profile, the build step
**must** obtain, without generating code, every entry point of the unit with
its stage and its profiles, as the compiler resolves them under `SHC4`
(`-mdcompute-manifest=<file>`). The profiles the unit is compiled for are the
union of those.

**SHC6: One compilation per profile.** The build step **must** compile the
unit once for each profile of the manifest, with that profile active. In the
compilation for profile `P`, an entry point whose profiles do not include `P`
**must not** be emitted, and what only it reaches **must not** be checked
against `P` (`SHC8`); its body is still analysed as D, like every function of
the unit.
Each compilation's output is validated and translated (`SHP4`–`SHP6`) as the
profile prescribes, and every entry point **must** produce the files of
`SHC2` for each of its profiles and its stage, and no others.

_Rationale:_ An entry point written for one target uses what that target
offers; compiling it for another would reject correct code.

## Requirements and their checks

**SHC7: Declared requirements.** A function of the vocabulary that needs a
capability **must** declare it with `@requires(c, …)`. Where the active
profile lacks the capability, its body **must** compile to a call of
`unsupported!c`, a function the compiler recognises, rather than fail: the
body of a function no emitted entry point reaches is analysed in every
compilation of the unit (`SHC6`), and an error there would reject correct
code. Code outside the vocabulary **may** declare requirements the same way.

_Rationale:_ A `static assert` in the built-in would fire wherever the
built-in is instantiated, which includes the helpers of an entry point built
only for another profile. The error belongs where the requirement meets an
entry point that is actually emitted, which only the compiler sees.

**SHC8: Inferred requirements.** For each entry point it emits, the compiler
**must** compute the union of the declared requirements of every function the
entry point can reach, and **must** fail the compilation if the active profile
lacks one of them, or if the entry point reaches a call of `unsupported`, with
a diagnostic that names the entry point, the capability and the call chain
from the entry point to the function that requires it, each step at its D
source line. A requirement only unemitted entry points reach **must not**
fail the compilation.

_Rationale:_ The call graph is the one the compiler already walks to reject
recursion, and a chain of D source lines is what the author needs to act on
the error.

**SHC9: Capability audit.** After the compilation for any profile, every
`OpCapability` and `OpExtension` the module declares **must** map, through
the table, to a capability of the active profile; one that does not **must**
fail the build step (exit 1) with a diagnostic that names the SPIR-V
capability, the profile, and the entry points whose module declares it.

_Rationale:_ Some capabilities come from the compiler, not the source: a
64-bit index pulls in `Int64`. Only the emitted module shows them, and only a
check of the module catches a declaration `SHC7` and `SHC8` cannot see.

**SHC10: Selecting an implementation.** Code **may** select among
implementations with `static if` on `activeProfile` (`SHC3`); a branch not
taken **must not** be compiled for that profile, and so cannot fail it:

```d
float4 fwidthFine(float4 p) @requires(Cap.derivativeControl)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return abs(ddxFine(p)) + abs(ddyFine(p));
    else
        return unsupported!(Cap.derivativeControl)(p);
}
```

_Rationale:_ This is the D counterpart of a target switch: one function, a
body per target, chosen at compile time. The example is illustrative; the
names of the derivative built-ins belong to the vocabulary.

## Not in this slice

Further profiles — GLSL 4.60, GLSL ES 3.00 and 3.20, HLSL by shader model,
MSL by version, WGSL through Tint and through naga, DXIL — are added to the
table by the milestones that bring their outputs ([`PLAN.md`](./PLAN.md)).
Each brings its capability set from the translator's behaviour recorded in
the [research catalog](../../research/shading-languages/comparison.md#the-translation-ceiling).
`SHC7` and `SHC8` land with the first built-in whose requirement is narrower
than every profile it is used under; until then the audit (`SHC9`) and the
manifest's per-profile compilation are the checks.
