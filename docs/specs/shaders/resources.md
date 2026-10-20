---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders` — Resources and layout

The values a shader reads that its host supplies: uniforms, uniform blocks,
push constants and images. A shader declares them once, in D, as parameters
of its entry point or as fields of an interface struct; the compiler lowers
each to what the active [profile](./profiles.md) can express — a block with a
binding for Vulkan, named uniforms for OpenGL — and the byte layout the host
writes is computed from the same D declaration. This page is part of the
[specification](./SPEC.md); the decisions behind it are
[`D18`](./decisions.md#d18-resources-are-parameters-or-interface-structs) and
[`D19`](./decisions.md#d19-blocks-in-d-lowered-per-profile).

## Kinds

**SHR1: Resource kinds.** The library **must** provide these resource kinds
for entry-point parameters. Every kind is a form of declaration, accepted
under every profile of this slice; what a profile's capabilities decide is
how the kind is lowered (`SHR3`–`SHR5`):

| Kind                | Declared as                  | Holds                                                     |
| ------------------- | ---------------------------- | --------------------------------------------------------- |
| Uniform             | `@uniform T name`            | one value of a uniform type ([`SHF5`](./entry-points.md)) |
| Uniform block       | `UniformBlock!T name`        | a struct `T` of uniform types                             |
| Push-constant block | `PushConstants!T name`       | a struct `T` of uniform types                             |
| Sampled 2-D image   | `Sampler2D name`             | an image, read through a sampler (`SHR7`)                 |
| Sampler             | `SamplerState name`          | a sampler of the entry point's own (`SHR7`)               |
| Interface struct    | a struct marked `@resources` | fields of the kinds above, flattened (`SHR2`)             |

The lowering of each kind under each profile of the slice is:

| Kind                | `gl330`, `gles100`                                                  | `vulkan1.3`                                   |
| ------------------- | ------------------------------------------------------------------- | --------------------------------------------- |
| Uniform             | a uniform outside any block                                         | a field of the default uniform block (`SHR3`) |
| Uniform block       | one uniform per field (`SHR5`)                                      | a block in `Uniform` storage (`SHR5`)         |
| Push-constant block | one uniform per field (`SHR4`)                                      | a block in `PushConstant` storage (`SHR4`)    |
| Sampled 2-D image   | a sampler uniform                                                   | a sampled image (`SHR7`)                      |
| Sampler             | none: it names the sampler uniforms of the images it reads (`SHR8`) | a sampler (`SHR7`)                            |

A kind a later profile cannot lower **must** fail the compilation for that
profile, naming the parameter and the capability its lowering needs.

A uniform block and a push-constant block **must** also be callable from host
code with a host value — a `UniformBlock!T` and a `PushConstants!T` wrap a `T`
— so an entry point that takes no image remains an ordinary D function the CPU
can call. A `Sampler2D` becomes host-callable with the
[executor](./executor.md)'s images (`SHX3`); until then an entry point that
samples compiles only for the device ([`SHF1`](./entry-points.md)).

_Rationale:_ OpenGL 3.3 has uniform blocks, but `gl330` does not grant
`uniformBlocks` and lowers a block to loose uniforms: its
consumers bind uniforms by name and cannot bind a block
([`D19`](./decisions.md#d19-blocks-in-d-lowered-per-profile)). Keeping the
kind apart from its lowering keeps one D declaration valid for both kinds of
profile.

**SHR2: Interface structs.** A parameter whose type is a struct marked
`@resources` **must** be treated as if each of its fields, in field order,
were a parameter of the entry point in its place, named after the field; a
field that is itself an interface struct is flattened the same way, so the
name of a nested field is its own name, not a path. A field of any kind but
`SHR1`'s **must** fail the compilation, naming the field. Names after
flattening are subject to `SHF2`'s rule that every interface name of an entry
point is distinct.

_Rationale:_ A shader with many resources, or a set shared by several entry
points, groups them once; one with two resources keeps them as parameters.
Flattening makes the two forms one interface, so the rest of this page
speaks of parameters.

## Lowering per profile

**SHR3: Uniforms.** A `@uniform T name` parameter **must** be lowered as:

- under `gl330` and `gles100`, which grant `looseUniforms`: a uniform named
  `name` outside any block, of `T`, as before this revision;
- under `vulkan1.3`, which does not: a field named `name` of the entry
  point's **default uniform block**, a uniform block whose variable is named
  `<entry>Uniforms` after the entry point and whose type is
  `UniformsOf!entry`, holding the entry point's `@uniform` parameters in
  parameter order, laid out as `SHR6` specifies.

An entry point with no `@uniform` parameter has no default uniform block.
Each entry point's block is its own variable, so `SHF2`'s rule that a name is
one variable across the unit's entry points holds for it. A shader written
with `@uniform` parameters therefore builds for both kinds of profile
unchanged. The library **must** provide `UniformsOf!entry`, a struct whose
fields are the entry point's `@uniform` parameters, named and typed as they
are and in parameter order, so a Vulkan host fills the default uniform block
with `writeLayout` (`SHR6`) from the entry point's own signature.

**SHR4: Push constants.** A `PushConstants!T name` parameter **must** be
lowered under `vulkan1.3` to one block of `T` in the `PushConstant` storage
class, laid out as `SHR6` specifies; under `gl330` and `gles100`, to one
uniform per field of `T`, named after the field, as `SHR3` lowers a
`@uniform`. An entry point **must** declare at most one push-constant block,
whose `std430` size, `layoutOf!(T, Rule.std430).size`, **must not** exceed 128
bytes, the minimum every Vulkan implementation offers; either violation
**must** fail the compilation, naming the parameter. A host **must** push
that many bytes, written by `writeLayout!(T, Rule.std430)`. Two stages of one
pipeline that both declare a push-constant block share its range from offset
0, so their blocks **must** have the same `T`, which `stagesLink` checks
([`SHF9`](./entry-points.md)).

**SHR5: Uniform blocks.** A `UniformBlock!T name` parameter **must** be
lowered under `vulkan1.3` to a block whose type is `T` itself, decorated
`Block` with no struct around it
([`D25`](./decisions.md#d25-a-vulkan-uniform-block-is-its-struct)), in the
`Uniform` storage class, named `name`, laid out as `SHR6` specifies, at the binding `SHR7` assigns;
under `gl330` and `gles100`, to one uniform per field of `T`, named after the
field.

_Rationale (`SHR3`–`SHR5`):_ Vulkan rejects a value outside a block, and
raylib's OpenGL path binds a uniform by name and cannot bind a block. One
D declaration lowered per profile serves both; a host binds by field name on
OpenGL and by binding and offset on Vulkan.

## Layout and bindings

**SHR6: Layout.** The library **must** provide `layoutOf!(T, Rule)`, the
offset of each field of `T`, its size and the struct's size and alignment, at
compile time, for `Rule.std140` and `Rule.std430` as the OpenGL 4.6
specification §7.6.2.2 defines them. A uniform block **must** be laid out by
`std140` and a push-constant block by `std430`. The compiler **must** decorate
each field of the emitted block with the offset `layoutOf` gives it and each
array with its stride. The library **must** also provide `writeLayout!(T,
Rule)(value, buffer)`, which writes a host `T` into a byte buffer at those
offsets, so a host fills a block without a hand-written mirror struct.

_Rationale:_ D's struct layout is neither `std140` nor `std430`: a `float3`
followed by a `float` sits at 16 in D (`SHV2`) and at 12 in `std140`. The
host and the device must agree on every byte, and only one function may say
where each byte goes.

**SHR7: Bindings.** _(Revised.)_ An image **must** be read through the shared
sampler, `image.sample(uv)`, or through a sampler of the entry point's own, a
`SamplerState` parameter or field, `image.sample(sampler, uv)`; an entry point
whose images want different filtering or addressing takes one sampler per
kind. Under `gl330` and `gles100`, the shared sampler is at binding 0 and the
images are at bindings 1, 2, 3, … in the order the `Sampler2D` parameters
appear after flattening, as before this revision; the generated GLSL carries
no binding qualifier, and a host binds each image's texture unit by its order.
Under `vulkan1.3`, every resource that has a binding **must** be in descriptor
set 0. Binding 0 is reserved for the shared sampler, which is declared only by
an entry point that reads an image through it; the uniform blocks, the default
uniform block, the images and the samplers of an entry point at the next free
bindings, in parameter order after flattening, the default uniform block at
the position of the first `@uniform`. A push-constant block has no binding.

A `@binding(b)` attribute on a parameter or a field **must** fix that
resource's binding under `vulkan1.3` and is ignored under the OpenGL
profiles; `@binding(0)` **must** fail the compilation, naming the reserved
binding. Automatic numbering **must** start at 1 and skip every binding fixed
in the entry point. Two resources of one entry point at one binding **must**
fail the compilation, naming both.

_Rationale:_ Bindings follow parameter position, so a `@resources` struct
that two entry points take at different positions gets different bindings,
and `SHF2`'s unit-wide rule rejects it. A struct shared that way fixes its
fields' bindings with `@binding`, once, on the struct.

**SHR8: Names.** Every resource and every field of a block **must** reach
the generated GLSL under its D name, and the written SPIR-V as its `OpName`
or `OpMemberName`, by the rules of
[`SHF2`](./entry-points.md). A block's type is named after `T`, and the
default uniform block's after `UniformsOf!entry`, whose identifier
**must** be `<entry>UniformsBlock`, distinct from the variable's name. In the
GLSL, an image read through one sampler is one sampler uniform named after
the image; one read through several samplers is a sampler uniform per
sampler, named `<image>_<sampler>`, the shared sampler's name being
`sampler`.

## Not in this slice

Storage buffers, storage images, images other than 2-D ones, arrays of
resources, bindless indexing, specialization constants and buffer device
addresses are specified by the milestones that bring them
([`PLAN.md`](./PLAN.md)), with the capabilities their profiles grant. The
scalar block layout, which matches D's own except for vectors, comes with the
first profile that grants it.
