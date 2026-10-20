---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
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
  imply others: `derivativeControl` implies `derivatives`.
- **Profile.** A named output: its kind (SPIR-V for an environment, or a
  shading language), its version, the file each stage's output is written to,
  and the set of capabilities it grants, closed under implication.
- **Active profile.** The one profile a device compilation is for.
- **Requirement.** The capabilities a function needs, declared on it or
  inferred from what it calls.

## Profiles

**SHC1: Profiles are data.** Capabilities, their implications, the
profiles, and the mapping from each SPIR-V capability and extension to the
capability it belongs to **must** be declared once, as D data, in the module
`sparkles.shaders.capabilities`, and **must** be readable at compile time by
ordinary D code and by the build step. The module **must** be a
host-and-device module of the vocabulary (`SHM1`), so it belongs to every unit
(`SHP3`) and is an input of every stamp (`SHB1`). Adding a profile whose
output the compiler and the build step already produce — a capability set
over a SPIR-V version the code generator emits and an existing translation —
**must not** require a change to either. The capability vocabulary is also the
compiler's, as `ldc.dcompute.Capability`: in a device compilation `Cap`
**must** be that enum, and elsewhere the library's copy of it, which a host
compilation by the device compiler **must** assert names the same
capabilities in the same order. Adding a capability changes both.

_Rationale:_ The table is what a reader consults to learn what a target
offers; as D data it is tested like any other code, and the vocabulary, the
build step and the shader author all read the same one. A profile with a new
SPIR-V version or a new translator is new output, and needs the code that
produces it.

**SHC2: The profiles of the first slice.** Each profile has a D identifier
(used in `@profiles`) and a name (used on the command line, in the manifest
and in diagnostics). The table **must** define at least:

| Identifier | Name        | Output                                       | Stages           | Files written per entry point          |
| ---------- | ----------- | -------------------------------------------- | ---------------- | -------------------------------------- |
| `gl330`    | `gl330`     | GLSL 3.30, translated by SPIRV-Cross         | fragment         | `<entry>.frag`                         |
| `gles100`  | `gles100`   | GLSL ES 1.00, translated by SPIRV-Cross      | fragment         | `<entry>.es.frag`                      |
| `vulkan13` | `vulkan1.3` | SPIR-V 1.6 for Vulkan 1.3, validated as such | vertex, fragment | `<entry>.vert.spv`, `<entry>.frag.spv` |
| `cpu`      | `cpu`       | the host compilation (no device output)      | —                | —                                      |

A profile's capabilities say what its output can declare, and so how each
resource kind is lowered for it ([`SHR3`–`SHR5`](./resources.md)): `gl330`
and `gles100` grant `looseUniforms` and neither `uniformBlocks` nor
`pushConstants`; `vulkan1.3` grants `uniformBlocks` and `pushConstants` and
not `looseUniforms`. The fragment stage's operations (`SHV11`) follow what
each output can say: `gl330` grants `derivatives` and not
`derivativeControl`, which needs OpenGL 4.5; `gles100` grants neither, as
OpenGL ES 2.0 offers derivatives only as an extension; `vulkan1.3` grants
both, `derivativeControl` implying `derivatives`, and `demote`, which no GL
profile can express. Each profile also states where its fragments' window
positions start (`SHF8`). Every device profile of the slice grants `vertexStage` or
`fragmentStage` as its stages column says, and `sampledImages`; `vulkan1.3`
also grants `intVertexInputs`. `cpu` grants `looseUniforms`, `uniformBlocks`,
`pushConstants` and `int64`, and no stage, no `sampledImages` and none of the fragment stage's
operations until the executor brings them (`SHX3`). `vulkan1.3`
denies `int64`: Vulkan grants 64-bit integers only with a device feature the
first consumer does not enable. A capability set **must** be a subset of what
the output can express and its validator accepts.

**SHC3: The active profile is a compile-time fact.** A device compilation
**must** be given its profile by name, with `-mdcompute-profile=<name>`, and
`__traits(getTargetInfo, "shaderProfile")` **must** then evaluate to that
name; in a host compilation by the fork it **must** evaluate to `"cpu"`. The
library **must** provide `activeProfile`, the profile of that name from the
table, so that `static if`, `static assert` and template constraints can branch
on it; under a compiler that does not know the trait (DMD, a stock LDC),
`activeProfile` **must** be `cpu`. The compilation **must** also be given
what the profile grants, closed under the implications:
`-capabilities=shader:<capability>,…`, the names of `SHC1`'s vocabulary. The
compiler **must** fail a name its vocabulary does not hold, naming the valid
ones, and **must** derive from the grants what it enforces: how resources are
lowered ([`SHR3`–`SHR5`](./resources.md)), the stages an entry point may have
([`SHF7`](./entry-points.md)), the types a vertex input may have
([`SHF5`](./entry-points.md)), and what an entry point may reach (`SHC8`). Without a grant, it **must** check none of them
and lower resources as plain uniforms. A name that is not in the table **must**
fail: the build step **must** reject it before compiling, naming it, and
`activeProfile` **must** fail its compilation, naming it, if a compiler is
given it directly.

_Rationale:_ D's compile-time evaluation runs once per compilation, for host
and device alike; a profile can only be something code branches on if each
compilation has one. The compiler knows the name and the capabilities it is
granted, and enforces what each capability means; which profile grants what
is the table's ([`D26`](./decisions.md#d26-the-compiler-is-granted-capabilities-not-profiles)).

## Declaring a shader's profiles

**SHC4: `@profiles`.** An entry point **may** carry `@profiles(p, …)`, naming
profiles by their D identifiers (`vulkan13`, `gl330`, `gles100`); a device
module **may** carry it on its declaration, as the default for its entry
points. An entry point's own `@profiles` **replaces** its module's. An entry
point with neither builds for every profile among `gl330` and `gles100` that
grants its stage, the outputs of the specification before profiles existed; a
`@vertex` entry point with neither therefore has no profile, and **must** fail
the compilation, naming it, as must any entry point whose profiles do not
grant its stage (`SHF7`). An identifier that is not in the table is an
undefined symbol and fails the compilation at the attribute.

**SHC5: The manifest.** Before compiling for any profile, the build step
**must** obtain from the compiler (`-mdcompute-manifest=<file>`), without
generating code and with no profile active, a JSON document listing every
entry point of the unit, sorted by name, each with its stage, its module, and
the names of its profiles as `SHC4` resolves them, sorted. The profiles the
unit is compiled for are the union of those, in the table's order. A unit
whose manifest lists no entry point **must** fail the build step with exit 2
(`SHP10`).

The manifest compilation **must** analyse the unit's declarations and their
attributes, and not the bodies of its functions. In it, `activeProfile`
**must** fail the compilation, naming the manifest, so an entry point whose
existence or `@profiles` depends on the profile is an error rather than a
manifest that differs from the compilations it plans. A `static if` on
`activeProfile` inside a function body (`SHC10`) is unaffected.

**SHC6: One compilation per profile.** The build step **must** compile the
unit once for each profile of the manifest, with that profile active. In the
compilation for profile `P`, an entry point whose profiles do not include `P`
**must not** be emitted, and what only it reaches **must not** be checked
against `P` (`SHC8`, `SHC9`), and its interface **must not** take part in
`SHF2`'s rule that an interface name is one variable; its body is still analysed as D, like every
function of the unit, so it **must** compile as D under every profile of the
unit. Each compilation's output is validated and translated (`SHP4`–`SHP6`) as
the profile prescribes, and every entry point **must** produce the files of
`SHC2` for each of its profiles and its stage, and no others.

_Rationale:_ An entry point written for one target uses what that target
offers; checking it against another would reject correct code. Analysing it as
D everywhere is what D's single semantic pass does, which is why the vocabulary
compiles a capability a profile lacks to `unsupported` rather than to an error
(`SHC7`).

## Requirements and their checks

**SHC7: Declared requirements.** A function of the vocabulary that needs a
capability **must** declare it with `@requires(c, …)`, the compiler's
`ldc.dcompute.requires` in a device compilation. Where the active profile
lacks the capability, its body **must** compile to a call of `unsupported!c`,
the compiler's `ldc.dcompute.unsupported`, which returns its first argument,
rather than fail: the body of a function no emitted entry point reaches is
analysed in every compilation of the unit (`SHC6`), and an error there would
reject correct code. A function that needs a stage **must** require that
stage's capability too (`fragmentStage`). Code outside the vocabulary
**may** declare requirements the same way. Outside a device compilation
`@requires` checks nothing, and a call of `unsupported!c` **must** stop the
program with a message naming `c` and the profile.

_Rationale:_ A `static assert` in the built-in would fire wherever the
built-in is instantiated, which includes the helpers of an entry point built
only for another profile. The error belongs where the requirement meets an
entry point that is actually emitted, which only the compiler sees.

**SHC8: Inferred requirements.** For each entry point it emits, the compiler
**must** compute the union of the declared requirements of every function the
entry point can reach through the calls in the bodies it reaches, and **must**
fail the compilation if the entry point is not granted one of them, or if it
reaches a call of `unsupported!c` for a capability it is not granted. An entry
point is granted the active profile's capabilities, and of the stages only
its own: a vertex entry point that reaches a function requiring
`fragmentStage` fails under `vulkan1.3`, which grants both stages. The
diagnostic **must** be at the entry point, name it, the capability, the
function and why it is not granted (the profile lacks it, or it is another
stage's), followed by the chain of calls from the entry point to that
function, shortest first, each step at its D source line; each capability is
reported once per entry point. A requirement only unemitted entry points
reach **must not** fail the compilation, and without a grant (`SHC3`) none
is checked.

_Rationale:_ The call graph is the one the compiler already walks to reject
recursion, and a chain of D source lines is what the author needs to act on
the error.

**SHC9: Capability audit.** For each profile, in the optimised module
(`SHP4`) and in every SPIR-V module written from it (`SHP5`), every
`OpCapability` and `OpExtension` the module declares **must** map, through the
table's mapping (`SHC1`), to a capability of the active profile; one that does
not, or one the mapping does not list, **must** fail the build step (exit 1)
with a diagnostic that names the SPIR-V capability, the profile and the entry
points the module holds — every entry point of the profile for the optimised
module, one for a written module.

_Rationale:_ Some capabilities come from the compiler, not the source: a
64-bit index pulls in `Int64`. Only the emitted module shows them, and only a
check of the module catches a declaration `SHC7` and `SHC8` cannot see.

**SHC10: Selecting an implementation.** Code **may** select among
implementations with `static if` on `activeProfile` (`SHC3`); a branch not
taken **must not** be compiled for that profile, and so cannot fail it:

```d
@requires(Cap.fragmentStage, Cap.derivativeControl)
float4 edgeWidth(float4 p)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return abs(dpdxFine(p)) + abs(dpdyFine(p));
    else
        return unsupported!(Cap.derivativeControl)(p);
}
```

_Rationale:_ This is the D counterpart of a target switch: one function, a
body per target, chosen at compile time.

## Not in this slice

Further profiles — GLSL 4.60, GLSL ES 3.00 and 3.20, HLSL by shader model,
MSL by version, WGSL through Tint and through naga, DXIL — are added to the
table by the milestones that bring their outputs ([`PLAN.md`](./PLAN.md)).
Each brings its capability set from the translator's behaviour recorded in
the [research catalog](../../research/shading-languages/comparison.md#the-translation-ceiling).
