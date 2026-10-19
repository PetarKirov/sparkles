---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders` — Entry points and their interface

What a pipeline stage's entry point is in D, and how its parameters and its
result become the stage's interface. dcompute compiles kernels; the graphics
stages are what this library requires of the compiler on top of it. The
requirements here bind the pinned compiler ([`SHT1`](./toolchain.md)) and are
checked through its output. Resources an entry point takes — uniform blocks,
push constants, images — are specified in [Resources](./resources.md); the
profiles it is built for, in [Profiles](./profiles.md). This page is part of
the [specification](./SPEC.md).

## Stages

**SHF1: Marking.** _(Revised.)_ A function in a `@compute` module marked `@fragment` or
`@vertex` **must** become an entry point of that stage, named after the D
function, in the device module of each profile it is built for
([`SHC6`](./profiles.md)). The D function itself remains callable from other
device code. An entry point that samples a texture compiles only for the
device, so it belongs in a device-only module: in a host-and-device module the
host compilation fails at the sample, since `SHV8`'s stand-in cannot sample.
An entry point's name **must** be unique across the unit and its stages; a
second function of the same name **must** fail the compilation with a
diagnostic naming both definitions.

_Rationale:_ The build step names each generated file after its entry point
(`SHP5`), and a renamed duplicate (`tint.1`) is a name no D function has.

**SHF7: Other stages.** _(Revised.)_ The compiler supports the stages of `SHF1` and
dcompute's kernels. A stage attribute carrying any other value **must** be
rejected at compile time with a diagnostic that reports the value. A stage a
profile does not grant ([`SHC2`](./profiles.md)) **must** be rejected for that
profile with a diagnostic naming the entry point and the profile.

## Parameters

**SHF2: Parameters.** _(Revised.)_ Each parameter of an entry point **must** be exactly
one of these, or the compilation **must** fail with a diagnostic that names
the parameter:

- **`@input`**: an input interface variable named after the parameter, of the
  parameter's type, decorated with location 0, 1, 2, … in the order the
  `@input` parameters appear.
- **`@builtin(b)`**: the stage's built-in variable `b` (`SHF8`), of the type
  `SHF8` gives it.
- **A resource**: a uniform, a uniform block, a push-constant block, an
  image, or an interface struct of resources, as
  [Resources](./resources.md) specifies.

A parameter that the platform calling convention would rewrite **must** be
rejected with a diagnostic, not miscompiled. Images are read through one
shared sampler, and every resource's binding is the one
[`SHR7`](./resources.md) assigns under the active profile.

Within one entry point, every interface name — each `@input`, each output
field, and each resource after flattening and lowering
([`SHR2`–`SHR5`](./resources.md)), including the uniforms a block's fields
become under an OpenGL profile, and the default uniform block's names of
`SHR3` and `SHR8` — **must** be distinct; a clash **must** fail the
compilation, naming both declarations. The compiler **must** key an
interface variable by its stage, its direction and its name.

Every interface name, and the field names of a uniform struct, **must** reach
the generated GLSL unchanged. A name the translation would rewrite **must**
fail the compilation with a diagnostic naming it: one GLSL reserves (by
spirv-cross's list), one with the `gl_` or `spv` prefix, one of the
translation's temporary names (`_` and digits, alone or followed by `_` and
anything; `_m` and digits, alone, for a struct field), one with a run of
underscores, and one with a character outside ASCII letters, digits and `_`. A
host binds by these names.

An interface name **must** denote one variable across the unit's entry points
of one stage: every entry point of that stage that names it **must** give it
the same kind, the same type and the same location or binding, or the
compilation **must** fail with a diagnostic that names both entry points.

_Rationale:_ The unit compiles to one module per profile (`SHC6`), in which a
name is one variable with one decoration. Two entry points that put it at
different ordinals would otherwise share the first one's, and one of them
would read through a location or binding it did not ask for, with no
validator able to tell. Inputs and outputs are different variables, and so
are the interfaces of different stages, so a vertex output and the fragment
input it feeds share their name in one module, as `SHF9` requires. A field
of a default uniform block is not an interface name of its own: each entry
point's block is a separate variable (`SHR3`).

## Built-in variables

**SHF8: Built-in variables.** The library **must** provide `Builtin`, naming
the built-in variables of the first slice with their stage, direction and
type:

| `Builtin`       | Stage  | Direction | Type     | SPIR-V `BuiltIn` | Vulkan GLSL        |
| --------------- | ------ | --------- | -------- | ---------------- | ------------------ |
| `vertexIndex`   | vertex | in        | `int`    | `VertexIndex`    | `gl_VertexIndex`   |
| `instanceIndex` | vertex | in        | `int`    | `InstanceIndex`  | `gl_InstanceIndex` |
| `position`      | vertex | out       | `float4` | `Position`       | `gl_Position`      |

A built-in used in the wrong stage, in the wrong direction, or with another
type **must** fail the compilation with a diagnostic naming it. The fragment
stage's position and facing (`FragCoord`, `FrontFacing`) are not in this
slice: their origin and winding differ between Vulkan and the OpenGL outputs,
and they come with a convention stated for each profile (M7).

## Results

**SHF3: Output.** _(Revised.)_ A fragment entry point's return value **must** be stored to
one output interface variable named `finalColor`, at location 0, of the
return type, which **must** be `float4`. A vertex entry point **must** return
a struct: its field marked `@builtin(Builtin.position)` is the stage's
position, and each other field an output interface variable named after the
field, at location 0, 1, 2, … in field order. A vertex result without the
position field **must** fail the compilation. A `void` fragment entry point
writes no output.

**SHF9: Linking stages.** The library **must** provide `stagesLink!(V, F)`, a
compile-time predicate on a vertex entry point `V` and a fragment entry point
`F` that holds exactly when every `@input` of `F` is an output field of `V`'s
result with the same name, the same type and the same location, and, when
both declare a push-constant block, both blocks have the same type, and
every binding of descriptor set 0 that both stages use (`SHR7`) holds a
resource of the same kind and type in each. A consumer that pairs two entry
points in one pipeline **should** assert it.

_Rationale:_ The two stages are compiled as separate entry points, and a
mismatch is caught by no validator: the pipeline links and reads garbage. D
can check it where the pair is chosen, from the two signatures.

## Sampling and handles

**SHF4: Sampling.** `sample(texture, uv)` on a `Sampler2D`, also callable as
`texture.sample(uv)`, **must** return the `float4` that GLSL's
`texture(sampler, uv)` returns for the same image, sampler state and
coordinate.

**SHF5: Interface types.** _(Revised.)_ Every input, uniform and output of an entry point
**must** have a type that every profile the entry point is built for can
declare at that end of the interface, with the same meaning:

- a fragment input or a vertex output field: `float`, `float2`, `float3` or
  `float4`;
- a vertex input: those, or `int`, `int2`, `int3`, `int4` under a profile that
  grants `intVertexInputs`;
- the fragment output: `float4` (`SHF3`);
- a uniform: any of those, `int` or a vector of two to four `int`s, or a
  struct or static array of uniform types;
- a built-in: the type `SHF8` gives it.

A uniform's declaration **must** carry its D type: an `int` is declared `int`,
and a struct's members are named after its fields. Any other type **must**
fail the compilation with a diagnostic that names the parameter and the
reason.

_Rationale:_ GLSL ES 1.00 has no unsigned or integer varyings, writes its one
colour output through a `vec4`, and has no `uint`. The host binds a uniform by
name and type, so a declaration that says `uint` for an `int` (`glUniform1i`
then fails) or `_m0` for a field breaks the binding without a diagnostic.

**SHF6: Opaque handles.** _(Revised.)_ A `Sampler2D` **must** stay a single scalar handle in
the generated code: never a member of an aggregate in the emitted module,
never stored in function-local memory, and never passed across a call that
survives optimisation. Device helpers the entry point calls **must** therefore
be inlined into it. An interface struct that holds a handle
([`SHR2`](./resources.md)) is flattened into its fields before code is
generated, so the handle reaches the module as a parameter of its own.

_Rationale:_ Vulkan-flavoured SPIR-V forbids an image or sampler inside a
composite or in Function storage, and the backend cannot pass one as an
argument. The constraint is the target's.

## The first consumer

The vertex and fragment stages are proved by porting the triangle of
`sparkles:vulkan-wsi`, today two hand-written GLSL files compiled to committed
SPIR-V, to one D device module built for `vulkan1.3`, with an aspect-ratio
push constant ([`SHR4`](./resources.md)). Its scenario is in
[`testing.md`](./testing.md#scenarios-entry-points).
