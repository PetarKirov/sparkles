# `sparkles:shader`

One D function that runs per cell on the CPU and, compiled by LDC's Vulkan
target, per fragment on the GPU. This library is the vocabulary such a function
is written against; the effects that use it live in `sparkles:ui`
(`sparkles.ui.effect_shaders`), and the pipeline that turns them into GLSL is
`apps/shader-compile`. The design and its contracts are in the
[effects spec](../../specs/ui/effects.md#one-source-two-targets-efx20) (`EFX20`,
`EFX25`–`EFX27`).

## The vocabulary

```d
import sparkles.shader;

vec3 phosphor(in vec2 at, in vec2 extent, in vec3 color) @safe pure nothrow @nogc
{
    const l = luma(color);
    return v3(l * 0.30f, l, l * 0.45f);
}
```

- **Types** — `vec2`, `vec3`, `vec4`: component-wise `+ - * /` against a vector
  or a scalar, unary `-`, `.array` for the components. Under LDC the
  power-of-two sizes are the compiler's own `__vector`s; `vec3`, and every size
  under DMD, is a struct with the same surface.
- **Constructors** — `v2(x, y)`, `v3(x, y, z)`, `v4(x, y, z, w)`, `v4(rgb, a)`,
  and a broadcast from one scalar. A `__vector` alias cannot be called, and a
  device module may not spell an array literal, so these are functions.
- **Components** — `p.x`, `p.y`, `c.z`, `c.w`, `c.xy`, `c.xyz` (alias `rgb`),
  by UFCS, so they work on both representations.
- **Built-ins** — `floor`, `abs`, `min`, `max`, `sqrt`, `sin`, `cos`, `pow`,
  `mod`, `fract`, `clamp`, `mix`, `step`, `smoothstep`, `dot`, `length`, and
  `luma` (Rec. 601). GLSL's semantics on both sides: `mod` follows the divisor's
  sign, and the compound ones are the specification's formulas.

## Device compilation is opt-in

Without `-d-version=SparklesShaderDevice` the attributes — `@compute` on a
module, `@fragment` on a function, `@input`/`@uniform` on its parameters,
`Sampler2D` — are inert stand-ins: an ordinary `dub build` sees plain D on any
compiler. With it they are LDC's `ldc.dcompute` symbols, every `@compute`
module is subject to LDC's device rules (no string literals, among others —
which is why this library's tests live in a separate, host-only module) and is
emitted to SPIR-V. Only `shader-compile` passes the flag.

## Writing a fragment shader

```d
@compute(CompileFor.deviceOnly)
module effects;

import sparkles.shader;
static import sparkles.ui.effect_shaders;

@fragment vec4 phosphor(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
{
    const texel = texture0.sample(fragTexCoord) * fragColor;
    const at = floor(fragTexCoord * uExtentCells);
    return v4(sparkles.ui.effect_shaders.phosphor(at, uExtentCells, texel.xyz), texel.w);
}
```

The compiler synthesises the interface from the signature: each `@input` is a
varying named after the parameter (which is how GLSL links it to the vertex
stage), each `@uniform` a uniform of that name, each `Sampler2D` a sampled image
at the next binding, and the return value the colour output. Everything in the
function body is ordinary D over this vocabulary — the same D the CPU runs.
