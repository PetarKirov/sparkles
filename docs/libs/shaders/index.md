# `sparkles:shaders`

One D function that runs per cell on the CPU and, compiled by LDC's Vulkan
target, per fragment on the GPU. This library is the vocabulary such a function
is written against; the effects that use it live in `sparkles:ui`
(`sparkles.ui.effect_shaders`), and the pipeline that turns them into GLSL is
`apps/shader-compile`. The design and its contracts are in the
[`sparkles:shaders` specification](../../specs/shaders/SPEC.md); how
`sparkles:ui` uses it is in the [effects spec](../../specs/ui/effects.md#one-source-two-targets-efx20).

## The vocabulary

```d
import sparkles.shaders;

vec3 phosphor(in vec2 at, in vec2 extent, in vec3 color) @safe pure nothrow @nogc
{
    const l = luma(color);
    return v3(l * 0.30f, l, l * 0.45f);
}
```

- **Types** — `vec2`, `vec3`, `vec4`: component-wise `+ - * /` against a vector
  or a scalar, unary `-`, `.array` for the components, and `allEqual(a, b)`
  for equality (D's `==` on a `__vector` is a mask, so it is not used). Under LDC the
  power-of-two sizes are the compiler's own `__vector`s; `vec3`, and every size
  under DMD, is a struct with the same surface. Every representation has the
  GPU's size and alignment (`vec3` is 16 bytes, padding included), so a struct
  or an array of vectors means the same bytes on both sides. For dense host
  arrays, `Vec2Packed`/`Vec3Packed`/`Vec4Packed` hold the components back to
  back; `packed(v)` and `aligned(p)` convert.
- **Other names and integer vectors** — `float2`, `float3`, `float4` are the
  same types as `vec2`, `vec3`, `vec4`. `int2`, `int3`, `int4` hold `int`s,
  with `+ - *` against a vector or an `int`, unary `-` and `.array`, built by
  `i2`, `i3`, `i4`; integer `/` is not offered. They have the device's size
  and alignment too.
- **Constructors** — `v2(x, y)`, `v3(x, y, z)`, `v4(x, y, z, w)`, `v4(rgb, a)`,
  and a broadcast from one scalar. A `__vector` alias cannot be called, and a
  device module may not spell an array literal, so these are functions.
- **Components** — `p.x`, `p.y`, `c.z`, `c.w`, `c.xy`, `c.xyz` (alias `rgb`),
  by UFCS, so they work on both representations.
- **Built-ins** — `floor`, `abs`, `min`, `max`, `sqrt`, `sin`, `cos`, `exp`,
  `pow`, `mod`, `fract`, `clamp`, `mix`, `step`, `smoothstep`, `dot`, `length`,
  and `luma` (Rec. 601), per component on vectors, with GLSL's widening of a
  scalar argument (`clamp(v, 0.0f, 1.0f)`, `step(0.5f, v)`). GLSL's semantics on both sides: `mod` follows the divisor's
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

import sparkles.shaders;
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

An entry point may read several textures. Name the parameters `texture0`,
`texture1` and so on, in the order the renderer binds them.

What may cross the interface is what both generated dialects can declare
there:

- an `@input` is a `float`, `vec2`, `vec3` or `vec4`;
- the return value is a `vec4`;
- a `@uniform` may also be an `int`, a vector of `int`s, or a struct or
  static array of those. The GLSL says `int` for an `int`, and a struct keeps
  its field names, so the host sets `light.gain` by name.

Anything else is a compile error naming the parameter and the reason.

All the entry points of a package compile to one module, where a name is one
variable per stage. A name two entry points of one stage use must therefore be
the same kind of parameter at the same position among its kind (`fragColor`
the second `@input` in both, say), or the compiler rejects the second, naming
both.

### Control flow the device compiler cannot structure

SPIR-V requires structured control flow, and the pinned compiler's SPIR-V
backend gets two common shapes wrong. Each comes out as code `spirv-val`
rejects ("branches to the selection construct, but not to the selection
header"). It is a build failure, never a wrong picture (issue #618 tracks the
upstream report). The two shapes are:

- an `if … else if (a && b)` chain;
- early returns interleaved with long `&&`/`||` chains, such as a function
  that returns as soon as one of several shape tests matches.

Compute each condition as a `bool` and combine the conditions with `&` and
`|`, which do not branch. Then use one select (`?:`) or independent `if`s. The
CRT's cursor and divider in `libs/ui/shaders/effects.d` are written that way.

## Writing a vertex shader

A vertex shader is built for Vulkan, so it names its profile:

```d
@compute(CompileFor.deviceOnly)
module triangle;

import sparkles.shaders;

struct Varyings
{
    @builtin(Builtin.position) vec4 position;
    vec4 colour;
}

@profiles(vulkan13) @vertex Varyings tri(@builtin(Builtin.vertexIndex) int index)
{
    vec2[3] corner;
    corner[0] = v2(-0.5f, 0.5f);
    corner[1] = v2(0.5f, 0.5f);
    corner[2] = v2(0.0f, -0.5f);
    Varyings v;
    v.position = v4(corner[index][0], corner[index][1], 0.0f, 1.0f);
    v.colour = v4(1.0f, 0.0f, 0.0f, 1.0f);
    return v;
}

@profiles(vulkan13) @fragment vec4 shade(@input vec4 colour) => colour;

static assert(stagesLink!(tri, shade));
```

- **Inputs.** `@input` parameters are the vertex attributes, at locations in
  parameter order, and may be integers too. `@builtin(Builtin.vertexIndex)`
  and `@builtin(Builtin.instanceIndex)` read the built-in inputs, as `int`s.
- **Result.** A vertex entry point returns a struct. The field marked
  `@builtin(Builtin.position)` is the clip-space position. Every other field
  is an output named after it, at locations in field order, which a fragment
  entry point reads as the `@input` of that name.
- **Tables.** A table is a local static array filled element by element:
  device code allows no array literals. Index it with an `int`, so that the
  module declares no 64-bit integers.
- **Linking.** `stagesLink!(V, F)` holds when every `@input` of `F` is an
  output of `V` with the same name, type and location. No validator catches a
  mismatch at draw time, so assert it where the pair is chosen.

### Profiles

A profile is one output: `gl330` (GLSL 3.30), `gles100` (GLSL ES 1.00) or
`vulkan13` (SPIR-V 1.6 for Vulkan 1.3). Mark an entry point, or a whole module
(`@profiles(...) module m;`), with the profiles it is built for. An entry
point's own `@profiles` replaces its module's.

A fragment entry point with neither builds for the two OpenGL profiles. A
vertex entry point with neither is an error, since no OpenGL profile offers
the vertex stage.

`shader-compile` compiles the unit once per profile and writes:

- `<entry>.frag` and `<entry>.es.frag` for the OpenGL profiles;
- `<entry>.vert.spv` and `<entry>.frag.spv` for Vulkan, one entry point per
  module.

In each compilation the profile is a compile-time constant, `activeProfile`
(`cpu` on the host), so one function can have a body per target:

```d
static if (activeProfile.has(Cap.pushConstants))
    // …
```

The compiler is told the profile's name and what it grants:
`shader-compile` passes `-capabilities=shader:<capability>,…` from this
table. The compiler checks each name against its own vocabulary,
`ldc.dcompute.Capability`, which is `Cap` in a device compilation. It
enforces what it knows a capability to mean:

- an entry point's stage needs `vertexStage` or `fragmentStage`;
- an integer vertex input needs `intVertexInputs`;
- resources lower to blocks when `uniformBlocks` is granted without
  `looseUniforms`;
- whatever an entry point reaches needs what it `@requires`.

A violation is an error at the D line. Which profile grants what stays in
the table, so a new profile needs no compiler change.

### Fragment-stage operations

`sparkles.shaders.fragment` has the fragment stage's operations, named as in
WGSL:

| Operation                                  | What it does                                            | `gl330` | `gles100` | `vulkan13` |
| ------------------------------------------ | ------------------------------------------------------- | ------- | --------- | ---------- |
| `dpdx`, `dpdy`, `fwidth`                   | how fast a value changes per pixel, across the 2×2 quad | yes     | no        | yes        |
| `dpdxCoarse`, `dpdyCoarse`, `fwidthCoarse` | the same, possibly one value for the quad               | no      | no        | yes        |
| `dpdxFine`, `dpdyFine`, `fwidthFine`       | the same, per pixel                                     | no      | no        | yes        |
| `discard()`, `terminate()`                 | stop: write nothing, run nothing more                   | yes     | yes       | yes        |
| `demote()`                                 | write nothing, but keep the quad's derivatives defined  | no      | no        | yes        |

`discard` is `terminate` everywhere, as GLSL's is. After it, derivatives in
the quad are undefined; if a later sample or derivative needs them, use
`demote` and build for Vulkan.

The fragment's position and facing are built-in parameters:

```d
@fragment vec4 shade(@builtin(Builtin.fragCoord) vec4 position,
    @builtin(Builtin.frontFacing) bool front, @uniform float height)
{
    // y grows up on the OpenGL profiles and down on Vulkan: count rows from
    // the bottom on both.
    static if (activeProfile.fragCoordOrigin == Origin.upperLeft)
        const y = height - position.y;
    else
        const y = position.y;
    return v4(y / height, front ? 1 : 0, 0, 1);
}
```

A triangle whose clip-space corners run counter-clockwise (x right, y up) is
front-facing on every profile, under OpenGL's default front face and
`sparkles:vulkan-wsi`'s pipelines.

Each operation is marked `@requires(Cap.fragmentStage, …)`. The compiler
follows the calls from every entry point it emits. When one reaches an
operation its profile does not grant, it reports the entry point, the
capability, and the chain of calls, each at its line:

```text
fx.d(6): Error: entry point `soft` reaches `sparkles.shaders.fragment.fwidth!(__vector(float[2]))`, which requires `derivatives`; the profile `gles100` does not grant it
fx.d(8):        `fx.soft` calls `fx.edge`
fx.d(4):        `fx.edge` calls `sparkles.shaders.fragment.fwidth!(__vector(float[2]))`
```

Fix it by building the entry point for profiles that grant the capability
(`@profiles(gl330, vulkan13)`), or by selecting another body with
`static if (activeProfile.has(…))`. A vertex entry point that reaches a
fragment operation fails the same way, even on Vulkan, which grants both
stages.

Your own functions can require capabilities too. In the branch where the
profile lacks one, return `unsupported!c(…)`, so the function still compiles
for every profile of its unit:

```d
@requires(Cap.fragmentStage, Cap.derivativeControl)
vec2 sharpEdge(vec2 uv)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return fwidthFine(uv);
    else
        return unsupported!(Cap.derivativeControl)(uv);
}
```

On the host (`cpu`), these operations and `unsupported` stop the program
with a message naming the capability.

### Uniform blocks, push constants and interface structs

One declaration of a resource serves every profile; the compiler lowers it
for each:

| Parameter                 | `gl330`, `gles100`         | `vulkan1.3`                                                |
| ------------------------- | -------------------------- | ---------------------------------------------------------- |
| `@uniform T name`         | a uniform `name`           | a field of the entry point's default uniform block         |
| `UniformBlock!T name`     | one uniform per field of T | a uniform block whose type is `T`, laid out by `std140`    |
| `PushConstants!T name`    | one uniform per field of T | the push-constant block, laid out by `std430`, ≤ 128 bytes |
| `SamplerState name`       | nothing of its own (below) | a sampler                                                  |
| a `@resources` struct `s` | its fields, flattened      | its fields, flattened                                      |

The default uniform block of an entry point `e` is the variable `eUniforms`,
of type `eUniformsBlock`; `UniformsOf!e` is that struct in D. On Vulkan,
resources with a binding are in descriptor set 0. Binding 0 is the shared
sampler's, and the rest follow parameter order from 1. `@binding(b)` on a
parameter or a field fixes one; Vulkan only. An entry point declares at most
one push-constant block.

`image.sample(uv)` reads through the shared sampler. To read images with
different filtering or addressing, take a `SamplerState` per kind and name it
at the sample:

```d
@profiles(vulkan13) @fragment vec4 canvas(@input vec2 uv, Sampler2D atlas,
    Sampler2D photo, SamplerState nearest, SamplerState linear)
    => atlas.sample(nearest, uv) * photo.sample(linear, uv);
```

On Vulkan each sampler is a descriptor at its binding (here `atlas` 1, `photo`
2, `nearest` 3, `linear` 4; `descriptorBindingsOf!canvas` lists them), and the
host creates the samplers it binds there. On OpenGL a sampler is not a uniform
of its own: each image becomes one `sampler2D` named after it, or, when it is
read through several samplers, one per sampler, `<image>_<sampler>`; the host
sets the filtering on the texture it binds to each.

The host writes a block's bytes from the same D struct:

```d
enum layout = layoutOf!(Light, Rule.std140);   // offsets, sizes, strides
ubyte[layout.size] bytes;
writeLayout!(Light, Rule.std140)(light, bytes[]);
```

D lays `Light` out by its own rules, which differ from `std140` and `std430`
(a `float` after a `vec3` is at 16 in D, at 12 in both GLSL layouts), so never
copy the struct's bytes. `PushConstantsOf!e` is the `T` of an entry point's
push-constant block, or `void`: size the pipeline's range from it, for the
stages whose entry points declare one. Two stages of one pipeline share that
range, so `stagesLink` also requires their blocks to have one type.

A module that computes in 64 bits fails the `vulkan1.3` build, which grants
no `Int64`, and the failure names the D line of each such operation. A
`size_t` index or remainder is the usual source; compute in `int`.

### A consumer: the Vulkan triangle

`sparkles:vulkan-wsi`'s triangle is a host-and-device module,
`triangle_shader.d`: a vertex entry point that reads its corners from a table
by `vertexIndex`, scaled by an aspect-ratio push constant, and a fragment
entry point that returns the interpolated colour. The renderer names each
stage by its D function (`__traits(identifier, triangleVertex)`) and takes the
push-constant range from `PushConstantsOf` and `layoutOf`. The package's
opt-in `gpu-shaders` configuration generates the SPIR-V into
`generated/shaders/` and compiles the renderer in; the triangle examples
select it. Its readback test draws the triangle on lavapipe and compares the
pixels with the host's evaluation of the same vertex function:

```bash
SPARKLES_VULKAN_READBACK=1 dub test :vulkan-wsi -- -i triangle_readback
```

It needs a Vulkan driver (`VK_DRIVER_FILES`) and the validation layer
(`VK_LAYER_PATH`).

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
`gpu-effects` configuration — selected beside every `sparkles:ui-raylib`
dependency (ui-app's `gui` and `full`, hue), so every GUI build gets it — adds the GPU halves, and runs `shader-compile --if-stale` as a
pre-generate step into the git-ignored `libs/ui/generated/shaders/`. A stamp
there records the SHA-256 of the shader modules and their packages' recipes,
so a build whose shaders are current pays a hash check, and an edit to one of
them regenerates. It does not track the compiler or the tools: after a
toolchain change (a new dev shell), run the step once without `--if-stale`.
What ships is built by Nix, which does track them.

That step needs the dcompute-enabled LDC as `ldc2-vulkan` on `PATH` —
dlang.nix's `ldc-vulkan` (dcompute's Vulkan target with the vertex and fragment stages and shader profiles,
built against LLVM main with the SPIR-V backend) — plus spirv-tools,
spirv-cross and glslang; the dev shell carries all of them. Nix builds the
shaders once (`nix build .#ui-shaders`) and copies them into each app's tree.
To run the tool by hand:

```bash
nix run .#shader-compile -- --package=libs/ui --out=libs/ui/generated/shaders
```
