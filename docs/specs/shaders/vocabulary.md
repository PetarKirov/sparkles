---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — The vocabulary

What a shader is written against: vector types, their constructors and
component access, arithmetic, and the built-in functions. It is ordinary D on
the host and becomes SPIR-V types and instructions on the device. The
requirements `SHV1`–`SHV8` are the accepted contract of 2026-10-16, with the
type names of [`D20`](./decisions.md#d20-generic-types-hlsl-shaped-aliases-glsl-math-names);
`SHV9` and `SHV10` are new. This page is part of the
[specification](./SPEC.md).

## Types

**SHV1: Vector types.** The library **must** provide `float2`, `float3` and
`float4`, vectors of two, three and four `float` components, with
component-wise `+`, `-`, `*` and `/` between two vectors of the same length
and between a vector and a `float` on either side, unary `-`, and `.array`
for the components as a static array. `vec2`, `vec3` and `vec4` **must**
remain the same types under their GLSL names. Equality of two vectors **must**
be `allEqual(a, b)`, one `bool` that is true when every component is equal,
GLSL's `all(equal(a, b))`; `==` on two vectors is outside the vocabulary.

_Rationale:_ D's `==` on a `__vector` is a mask, one lane per component, and
on a struct a `bool`, so the same expression would mean different things
under LDC and DMD. GLSL's `==` on vectors is the single `bool`.

**SHV2: Representation.** Under LDC, `float2` and `float4` **must** be the
compiler's `__vector` types. In a device compilation `float3` **must** be
`__vector(float[3])`. Elsewhere, and on the host under every compiler,
`float3` **must** be a struct of three `float`s with the same operations;
`float2` and `float4` **may** be such structs under a compiler without the
corresponding `__vector`. Whatever the representation, each type **must**
have the device's size and alignment: 8 bytes for `float2`, 16 for `float3`
and `float4`. The vocabulary **must** also provide packed variants
(`Vec2Packed`, `Vec3Packed`, `Vec4Packed`), whose components are back to
back, and conversions between the two.

_Rationale:_ The device needs native vectors, because a struct is an
aggregate the SPIR-V backend would have to keep in memory. A released host
LDC sizes a three-element `__vector` at 12 bytes while LLVM allocates 16,
which breaks a struct that contains one, and DMD has no such vector; a
struct avoids both. Aligning it like the device's vector means a value, a
struct field or an array element occupies the same bytes on both sides. A
block a host shares with the device takes its layout from
[`SHR6`](./resources.md), not from these bytes.

**SHV9: Integer vectors.** The library **must** provide `int2`, `int3` and
`int4`, vectors of `int`, with the representation rules of `SHV2` for `int`
and the operations of `SHV1` except `/`, which on integers is outside the
vocabulary of this slice.

**SHV10: One vector type (planned).** `float2`–`float4` and `int2`–`int4`
**must** become aliases of `sparkles.math`'s `Vector!(T, N)`, the project's
one vector type, once it meets `SHV1`, `SHV2` and `SHV4` on host and device;
`Matrix!(T, R, C)` and its aliases (`float4x4`, …) come with it. Until then
they are this library's own types.

**SHV3: Constructors.** `v2(x, y)`, `v3(x, y, z)` and `v4(x, y, z, w)`
**must** construct vectors from components, `v2(s)`, `v3(s)` and `v4(s)`
**must** broadcast one `float`, and `v4(rgb, a)` **must** extend a `float3`
with a fourth component.

_Rationale:_ A `__vector` type alias cannot be called, and device code may
not spell the array literal D uses to build one.

**SHV4: Component access.** `x`, `y`, `z` and `w` **must** read one
component, `xy` the first two, and `xyz` (with the alias `rgb`) the first
three of a `float4`. They are free functions reached by D's uniform function
call syntax, so `c.xyz` works on both representations.

## Built-in functions

**SHV5: Built-in functions.** The library **must** provide `floor`, `abs`,
`min`, `max`, `sqrt`, `sin`, `cos`, `exp`, `pow`, `mod`, `fract`, `clamp`,
`mix`, `step`, `smoothstep`, `dot` and `length` with the names and meanings
of the
[GLSL 4.60 specification §8](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html#built-in-functions),
for `float` and, where GLSL defines them per component, for each vector type,
including GLSL's forms that widen a `float` argument to every component:
`min`, `max` and `mod` with a `float` second argument, `clamp` with `float`
bounds, `step` and `smoothstep` with `float` edges, and `mix` with a vector
or a `float` weight. It **must** also provide `luma(float3)`, the Rec. 601
luma `dot(c, v3(0.299, 0.587, 0.114))`. Operations on a resource or a stage
(sampling, subgroups, derivatives) are methods of their handle types or
belong to the stage, not free functions ([`D20`](./decisions.md#d20-generic-types-hlsl-shaped-aliases-glsl-math-names)).

**SHV6: Compound definitions.** `mod(a, b)` **must** equal
`a - b * floor(a / b)`, so its result has the sign of `b`; `fract(v)` **must**
equal `v - floor(v)`; `clamp(v, lo, hi)` **must** equal
`min(max(v, lo), hi)`; `mix(a, b, t)` **must** equal `a * (1 - t) + b * t`;
`step(e, v)` **must** be 0 for `v < e` and 1 otherwise; and
`smoothstep(e0, e1, v)` **must** be `t * t * (3 - 2t)` for
`t = clamp((v - e0) / (e1 - e0), 0, 1)`. Each is written once in terms of
the primitive built-ins, so host and device evaluate the same formula.

_Rationale:_ D's `%` takes the sign of the dividend, unlike GLSL's `mod`. An
effect that wraps a coordinate would differ between the sides wherever the
coordinate is negative, which is exactly where nobody looks.

**SHV7: Agreement.** For every operation in `SHV1`–`SHV6` and every finite
input on which GLSL defines the result, the host and device results **must**
agree within the bound [`D12`](./decisions.md#d12-agreement-is-judged-by-the-vulkan-precision-table)
sets for that operation, inside the argument ranges it gives; outside them,
and where `mod`'s quotient lies within rounding of an integer (one rounding
moves `floor` by a whole step), no bound is required. Construction and
component access are exact; vector `+`, `-` and `*` are correctly rounded per
operation, with a multiply and an add allowed to fuse into one rounding on
either side, and `/` is within 2.5 ULP for divisors in [2⁻¹²⁶, 2¹²⁶]; any
operation may flush a denormal operand or result to zero. The GLSL ES 1.00
output, which qualifies every variable `highp` (`D15`), is held to the same
bounds. GLSL leaves the result undefined for `sqrt` of a negative number,
`pow` with a negative base or with a zero base and a non-positive exponent,
`mod` by zero, `smoothstep` with `e0 >= e1`, and `clamp` with `lo > hi`; on
those inputs nothing is required.

**SHV8: Inert stand-ins.** Outside a device compilation, the shader
attributes (`@compute`, the stages of `SHF1`, the parameter markers of `SHF2`,
`@profiles`, `@requires`, `@resources`, `@binding`) and the resource handles
of [`SHR1`](./resources.md) **must** exist with the same names as plain D
declarations, so a host-and-device module compiles as ordinary D under any
compiler. A device-only module is never compiled for the host, and need not
compile there: it samples textures, which only the device compilation can do.

## Not in this slice

Further scalar types (`uint`, `bool` vectors, `half`, `double`), matrices,
the rest of GLSL's built-in families, texture operations beyond `sample`,
derivatives, subgroup operations and atomics are added by the milestones of
[`PLAN.md`](./PLAN.md), each with its agreement oracle and the capabilities
it requires ([`SHC7`](./profiles.md)).
