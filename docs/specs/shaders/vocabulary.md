---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders` — The vocabulary

What a shader is written against: vector types, their constructors and
component access, arithmetic, and the built-in functions. It is ordinary D on
the host and becomes SPIR-V types and instructions on the device. The
requirements `SHV1`–`SHV8` are the accepted contract of 2026-10-16, with the
type names of [`D20`](./decisions.md#d20-generic-types-hlsl-shaped-aliases-glsl-math-names);
`SHV9`–`SHV11` are new. This page is part of the
[specification](./SPEC.md).

## Types

**SHV1: Vector types.** The library **must** provide `float2`, `float3` and
`float4` as `sparkles:math`'s `Vector!(float, N, Layout.device)`, so that they
have its operations: component-wise arithmetic against a vector of the same
length or a `float` on either side, unary `-`, and `.array` for the components
as a static array ([`MV4`](../math/SPEC.md), [`MV6`](../math/SPEC.md)). `vec2`, `vec3` and `vec4`
**must** remain the same types under their GLSL names. Equality of two
vectors **must** be one `bool`, true when every component is equal, GLSL's
`all(equal(a, b))`: `a == b` ([`MV7`](../math/SPEC.md)), and `allEqual(a, b)`, the
same.

_Rationale:_ One vector type across the project, so that a value crosses
from a UI's geometry to a shader's uniform without a conversion. `==` is one
`bool` because a vector is a struct whatever its storage; D's `==` on a bare
`__vector`, a mask, never reaches shader code.

**SHV2: Representation.** The vector types **must** have
`sparkles:math`'s device layout and storage ([`MV2`](../math/SPEC.md), [`MV3`](../math/SPEC.md)): 8
bytes for `float2`, 16 for `float3` and `float4`, under every compiler and on
both sides, and a `__vector` in a device build. The vocabulary **must** also
provide packed variants (`Vec2Packed`, `Vec3Packed`, `Vec4Packed`), the packed
`Vector!(float, N)`s, whose components are back to back, and conversions
between the two (`packed`, `aligned`).

_Rationale:_ The device needs native vectors, because a struct of an array
is an aggregate the SPIR-V backend would have to keep in memory; a vector
type that stores one is its vector at the interface ([`MV12`](../math/SPEC.md)). The same
bytes on both sides mean a value, a struct field or an array element holding
a vector occupies the same memory on the host as on the device. A block a
host shares with the device takes its layout from [`SHR6`](./resources.md),
not from these bytes.

**SHV9: Integer vectors.** The library **must** provide `int2`, `int3` and
`int4`, the device-layout `Vector!(int, N)`s, with the representation of `SHV2`
and the operations of `SHV1` except `/`, which on integers is outside the
vocabulary of this slice.

**SHV10: One vector type.** The vector types of `SHV1` and `SHV9` **must** be
`sparkles.math`'s `Vector`, and the library **must** provide matrices of
`float` as its `Matrix`: `floatRxC`, with `R` rows and `C` columns for `R` and `C`
from 2 to 4, as HLSL names them; `mat2`, `mat3` and `mat4`; and GLSL's
`matCxR`, with `C` columns and `R` rows, the same types (`mat2x3` is
`float3x2`). Their storage, indexing and products are `sparkles:math`'s
([`MM2`](../math/SPEC.md)–[`MM5`](../math/SPEC.md)): column-major, so a matrix in a block has the
bytes of a column-major matrix under `std140` and `std430`, which GLSL sees as
an array of its columns ([`MD6`](../math/SPEC.md#decisions)).

**SHV3: Constructors.** The vector types **must** be constructible as structs
([`MV5`](../math/SPEC.md)): `float3(1, 0, 0)`, `float4(0.5f)` broadcasting one `float`, and
`float4(rgb, a)` extending a `float3`. `v2(x, y)`, `v3(x, y, z)` and
`v4(x, y, z, w)`, their one-argument broadcasts, `v4(rgb, a)`, and `i2`, `i3`
and `i4` for the integer vectors, **must** remain the same constructors as
functions.

**SHV4: Component access.** A vector's components **must** be read and
written by name, `x`, `y`, `z` and `w`, and through swizzles ([`MV4`](../math/SPEC.md),
[`MV8`](../math/SPEC.md)): `c.xyz`, its spelling `c.rgb`, `c.a`, `uv.yx`, and
`c.xy = uv`.

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
luma `dot(c, v3(0.299, 0.587, 0.114))`. Operations on a resource (sampling)
are methods of its handle type, not free functions ([`D20`](./decisions.md#d20-generic-types-hlsl-shaped-aliases-glsl-math-names));
the fragment stage's are free functions (`SHV11`).

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

**SHV8: Inert stand-ins.** _(Revised.)_ Outside a device compilation, the shader
attributes (`@compute`, the stages of `SHF1`, the parameter markers of `SHF2`,
`@profiles`, `@requires`, `@resources`, `@binding`) and the resource handles
of [`SHR1`](./resources.md) **must** exist with the same names as plain D
declarations, so a host-and-device module compiles as ordinary D under any
compiler. A device-only module is never compiled for the host, and need not
compile there: it samples textures, which only the device compilation can do.

## The fragment stage's operations

**SHV11: Fragment-stage operations.** The library **must** provide, in
`sparkles.shaders.fragment`, these free functions, named as WGSL names them
([`D27`](./decisions.md#d27-the-fragment-stages-operations-are-free-functions)),
each over `float` and every float vector, and each declaring with
`@requires` the fragment stage and the capability given (`SHC7`):

| Function                                   | Meaning                                                                                                                    | Requires            | SPIR-V                         |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- | ------------------- | ------------------------------ |
| `dpdx(v)`, `dpdy(v)`                       | the rate of change of `v` in window x or y across the fragment's 2×2 quad                                                  | `derivatives`       | `OpDPdx`, `OpDPdy`             |
| `fwidth(v)`                                | `abs(dpdx(v)) + abs(dpdy(v))`                                                                                              | `derivatives`       | `OpFwidth`                     |
| `dpdxCoarse`, `dpdyCoarse`, `fwidthCoarse` | the same, possibly one value for the whole quad                                                                            | `derivativeControl` | `OpDPdxCoarse`, `OpDPdyCoarse` |
| `dpdxFine`, `dpdyFine`, `fwidthFine`       | the same, computed for this fragment                                                                                       | `derivativeControl` | `OpDPdxFine`, `OpDPdyFine`     |
| `terminate()`                              | ends the invocation: nothing after it runs and the fragment is not written                                                 | —                   | `OpTerminateInvocation`        |
| `discard()`                                | `terminate()`, on every profile                                                                                            | —                   | `OpTerminateInvocation`        |
| `demote()`                                 | the invocation becomes a helper: it keeps running, so its quad's derivatives stay defined, and the fragment is not written | `demote`            | `OpDemoteToHelperInvocation`   |

On every profile that grants what each needs, the readback of a fragment
entry point that uses it **must** show its meaning: a derivative of the window
position (`SHF8`) is 1 per pixel in each direction, a discarded or demoted
fragment leaves the target's clear value, and a fragment whose quad
neighbour was demoted still reads a fine derivative of 1.

_Rationale:_ `discard` is terminate, as GLSL's is, so one shader means one
thing in every output; demote cannot be expressed in GLSL 3.30 or ES 1.00
([Concepts](../../research/shading-languages/concepts.md#discard-demote-and-terminate)),
so a shader that needs its quad after discarding says `demote` and is built
where that exists.

## Not in this slice

Further scalar types (`uint`, `bool` vectors, `half`, `double`), matrices,
the rest of GLSL's built-in families, texture operations beyond `sample`,
subgroup operations and atomics are added by the milestones of
[`PLAN.md`](./PLAN.md), each with its agreement oracle and the capabilities
it requires ([`SHC7`](./profiles.md)).
