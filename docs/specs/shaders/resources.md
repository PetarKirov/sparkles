---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
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
for entry-point parameters, and the compiler **must** accept each only where
the active profile grants its capability ([`SHC2`](./profiles.md)):

| Kind                | Declared as                  | Capability      | Holds                                                     |
| ------------------- | ---------------------------- | --------------- | --------------------------------------------------------- |
| Uniform             | `@uniform T name`            | `uniforms`      | one value of a uniform type ([`SHF5`](./entry-points.md)) |
| Uniform block       | `UniformBlock!T name`        | `uniformBlocks` | a struct `T` of uniform types                             |
| Push-constant block | `PushConstants!T name`       | `pushConstants` | a struct `T` of uniform types                             |
| Sampled 2-D image   | `Sampler2D name`             | `sampledImages` | an image read through the shared sampler (`SHF4`)         |
| Interface struct    | a struct marked `@resources` | —               | fields of the kinds above, flattened (`SHR2`)             |

Every kind **must** also be callable from host code with a host value — a
`UniformBlock!T` wraps a `T`, a `Sampler2D` a host image — so an entry point
remains an ordinary D function the CPU can call ([Executor](./executor.md)).

**SHR2: Interface structs.** A parameter whose type is a struct marked
`@resources` **must** be treated as if each of its fields, in field order,
were a parameter of the entry point in its place, named after the field; a
field that is itself an interface struct is flattened the same way. A field
of any kind but `SHR1`'s **must** fail the compilation, naming the field. Two
resources of one entry point **must not** share a name after flattening.

_Rationale:_ A shader with many resources, or a set shared by several entry
points, groups them once; one with two resources keeps them as parameters.
Flattening makes the two forms one interface, so the rest of this page
speaks of parameters.

## Lowering per profile

**SHR3: Uniforms.** A `@uniform T name` parameter **must** be lowered as:

- under a profile granting `uniforms` (`gl330`, `gles100`): a uniform named
  `name` outside any block, of `T`, as today;
- under a profile granting only `uniformBlocks` (`vulkan1.3`): a field named
  `name` of the entry point's **default uniform block**, a uniform block
  named `Uniforms` holding the entry point's `@uniform` parameters in
  parameter order, laid out as `SHR6` specifies.

A shader written with `@uniform` parameters therefore builds for both kinds
of profile unchanged. The library **must** provide `UniformsOf!entry`, a
struct whose fields are the entry point's `@uniform` parameters, named and
typed as they are and in parameter order, so a Vulkan host fills the default
uniform block with `writeLayout` (`SHR6`) from the entry point's own
signature.

**SHR4: Push constants.** A `PushConstants!T name` parameter **must** be
lowered under `vulkan1.3` to one block of `T` in the `PushConstant` storage
class, laid out as `SHR6` specifies; under a profile without
`pushConstants`, to one uniform per field of `T`, named after the field, as
`SHR3` lowers a `@uniform`. An entry point **must** declare at most one
push-constant block, whose size **must not** exceed 128 bytes, the minimum
every Vulkan implementation offers; either violation **must** fail the
compilation, naming the parameter.

**SHR5: Uniform blocks.** A `UniformBlock!T name` parameter **must** be
lowered under `vulkan1.3` to a block of `T` in the `Uniform` storage class,
named `name`, laid out as `SHR6` specifies, at the binding `SHR7` assigns;
under a profile without `uniformBlocks`, to one uniform per field of `T`,
named after the field.

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

**SHR7: Bindings.** Under `vulkan1.3`, every resource that has a binding
**must** be in descriptor set 0, with the shared sampler at binding 0
([`SHF2`](./entry-points.md)), and the uniform blocks, the default uniform
block and the images of an entry point at bindings 1, 2, 3, … in parameter
order after flattening (the default uniform block at the position of the
first `@uniform`). A `@binding(b)` attribute on a parameter or field
**may** fix its binding; two resources of one entry point at one binding
**must** fail the compilation, naming both. A push-constant block has no
binding.

**SHR8: Names.** Every resource and every field of a block **must** reach
the generated GLSL under its D name, by the rules of
[`SHF2`](./entry-points.md); a block's type is named after `T`.

## Not in this slice

Storage buffers, storage images, separate images and samplers, arrays of
resources, bindless indexing, specialization constants and buffer device
addresses are specified by the milestones that bring them
([`PLAN.md`](./PLAN.md)), with the capabilities their profiles grant. The
scalar block layout, which matches D's own except for vectors, comes with the
first profile that grants it.
