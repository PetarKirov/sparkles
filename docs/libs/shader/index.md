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

Outside a dcompute build (no `-mdcompute-targets`, so no `LDC_DCompute`), the
attributes — `@compute` on a module, `@fragment` on a function,
`@input`/`@uniform` on its parameters, `Sampler2D` — are inert stand-ins: an
ordinary `dub build` sees plain D on any compiler. In one they are LDC's
`ldc.dcompute` symbols, every `@compute` module is subject to LDC's device
rules (no string literals, among others — which is why this library's tests
live in a separate, host-only module) and is emitted to SPIR-V. Only a device
configuration passes the flag.

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

## Editor support

hue's live types (and anything else on `sparkles:dmd-lsp`) analyze a shader
module the way the device build compiles it, so `texture0.sample(uv)` is not an
error and a string literal in device code is:

- A `@compute(CompileFor.deviceOnly)` module is analyzed only as device code:
  the dcompute LDC's druntime (`$SPARKLES_LDC_IMPORT_PATH`, which the devshell
  exports on Linux), `LDC_DCompute`, and LDC's rules for
  device code, with LDC's own messages.
- A `@compute(CompileFor.hostAndDevice)` module is analyzed both ways. An error
  both sides report shows as it is; one only a single side reports carries a
  `[host]` or `[device]` tag.

The device side's settings come from the package's **device configuration**:
a dub configuration whose dflags name a dcompute target (`shaders` by
convention). Its `@compute` modules — the package's and its dependencies' —
are the unit `shader-compile` compiles, so a new shader module needs no
registration anywhere: mark it `@compute` and both the build and the editor
follow. See
[Target profiles & device code](../../specs/dmd-lsp/targets.md).

## How the GLSL is built

Nothing generated is committed. `sparkles:ui`'s default configuration carries
the tier-0 transforms only and needs no shader compiler, so `sparkles:core-cli`
and every terminal-only consumer build with a stock D compiler. Its
`gpu-effects` configuration — which `sparkles:ui-raylib` selects, so every GUI
build gets it — adds the GPU halves, and runs `shader-compile --if-stale` as a
pre-generate step into the git-ignored `libs/ui/generated/shaders/`. A stamp
there records the SHA-256 of every input, so a build whose shaders are current
pays a hash check, and one whose inputs changed regenerates them.

That step needs the dcompute-enabled LDC as `ldc2-vulkan` on `PATH` —
dlang.nix's `ldc-vulkan` (dcompute's Vulkan target and the `@fragment` stage,
built against LLVM main with the SPIR-V backend) — plus spirv-tools,
spirv-cross and glslang; the dev shell carries all of them. Nix builds the
shaders once (`nix build .#ui-shaders`) and copies them into each app's tree.
To run the tool by hand:

```bash
nix run .#shader-compile -- --package=libs/ui --out=libs/ui/generated/shaders
```
