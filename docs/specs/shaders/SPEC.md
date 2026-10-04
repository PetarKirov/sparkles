---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-05
---

# `sparkles:shaders` — Specification

## Abstract

`sparkles:shaders` lets a D program write a per-pixel effect once, as an
ordinary D function, and run it in two places: on the CPU, where any D
compiler calls it directly, and on the GPU, where the same source is compiled
into a fragment shader. It provides GLSL-shaped vectors and built-in
functions with GLSL's definitions on both sides, a fragment-shader entry point
for the GPU compilation of LDC, the LLVM-based D compiler, and a build step
that turns a package's shader code into validated GLSL during the build,
regenerating it only when its inputs change. A program that never uses the
GPU half never needs the shader compiler.

## 1. Introduction

Programs that draw the same interface on very different surfaces need visual
effects that behave the same on each. A scanline overlay or a colour
transform may run in a GPU window as a fragment shader over every pixel, in a
terminal as a function called once per character cell with the cell standing
in for the pixel, and in a test as a function applied to a few known inputs.
The usual answer is two implementations: a shader in GLSL and a fallback in
the host language. They drift. Nothing in that arrangement checks that the
GLSL `mod` of a negative number matches the host's, that both sides clamp the
same way, or that a fix applied to one was applied to the other.

D has GPU compilation, but not for this. LDC's dcompute compiles marked D
modules to GPU code for compute kernels: functions launched over a grid that
read and write buffers. Its Vulkan target
([ldc-developers/ldc#5132](https://github.com/ldc-developers/ldc/pull/5132))
emits SPIR-V. A fragment shader is a different shape. Its inputs are
interpolated values from the previous pipeline stage, sampled textures and
named uniforms, and its output is a colour; a graphics API links all of these
by name and location. dcompute has no graphics stages. D's own numeric
semantics also differ from GLSL's in details that matter for effects, and
GPUs consume SPIR-V or GLSL, not D. Finally, a compiler that emits SPIR-V is
a custom LDC built against a development LLVM: far too heavy to impose on
every program that merely uses an effect on the CPU.

This library writes each effect as a
[single-source shader](../../glossary.md#single-source-shader): one D
function over a small [vocabulary](../../glossary.md#shader-vocabulary) of
GLSL-shaped types and built-ins, compiled twice. The vocabulary implements
GLSL's definitions, so the two compilations agree within the floating-point
error GLSL permits a GPU. The host compilation is ordinary D, so any compiler
and any CPU caller can use it. The device compilation goes through dcompute,
extended with a fragment stage that a fork of LDC adds: a function marked as
a [fragment entry point](../../glossary.md#fragment-entry-point) has its
parameters turned into the shader's inputs, textures and uniforms, and its
return value into the colour output. A build step compiles a package's
shader modules to SPIR-V, validates it, translates each entry point into GLSL
for OpenGL 3.3 and OpenGL ES 2.0, and validates the result again. It runs as
part of an ordinary build of a [dub](https://dub.pm/) package, D's package
manager and build tool, and the GLSL it writes is a build product that is
never committed. A [freshness stamp](../../glossary.md#freshness-stamp),
recording the hashes of its inputs, lets it skip all work while they are
unchanged. Consumers opt in per dub configuration, so the custom compiler is
needed exactly where a GPU half is; a build that opts in on a machine without
it fails and says how to obtain it.

The scope is the fragment stage. Vertex, geometry and compute shading,
matrices, integer and double-precision vectors, and runtime shader
compilation are outside it. So is anything that draws: registering effects,
binding textures and uniforms, and running passes belong to the consumer's
renderer, which this library hands complete GLSL source. SPIR-V is an
intermediate the build step consumes, not an output. A Vulkan consumer, which
would need descriptor and push-constant layouts, is not served. The compiler
itself is a pinned dependency: this specification states what it requires of
the compiler, including the fragment stage, not how the compiler implements
it. Editor diagnostics for shader code are specified by the analysis library
that provides them, `sparkles:dmd-lsp` ([target profiles](../dmd-lsp/targets.md)).
[`decisions.md`](./decisions.md) records each exclusion with what would bring
it back.

The package holds two things: the vocabulary, a library, and the build step,
a command-line tool. Section 2 lists the terms this document defines and
section 3 states the contract at a glance. Sections 4–9 give the
requirements: the vocabulary, device modules, fragment entry points, the
build step, build integration, and the toolchain.
[`testing.md`](./testing.md) names the oracle and scenarios for each
requirement and holds the evidence ledger, [`PLAN.md`](./PLAN.md) orders
delivery and tracks progress, and [`decisions.md`](./decisions.md) records the
consequential choices and open questions.

## 2. Terminology

The terms this specification coins, or uses in a narrower sense than usual,
are defined once in the [glossary](../../glossary.md) and listed here:

<GlossaryList owner="sparkles:shaders" />

GPU terms follow their standards. [SPIR-V](https://registry.khronos.org/SPIR-V/)
is the Khronos intermediate language for shaders. GLSL is the OpenGL Shading
Language: version 3.30 for desktop OpenGL 3.3 and
[ES 1.00](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)
for OpenGL ES 2.0. A _varying_ is an input a fragment shader receives,
interpolated from the previous stage; a _uniform_ is a value constant over one
draw. dcompute's own terms keep their meaning: the _host_ is the CPU side of a
program, the _device_ the GPU side.

## 3. The contract at a glance

1. **One source.** An effect is one D function. Its CPU behaviour and its
   GPU shader derive from that function; neither is written separately.
2. **One meaning.** Every vocabulary operation computes the same result on
   the host and the device, up to floating-point rounding.
3. **Device code is opt-in by target.** Without a GPU compilation target the
   vocabulary is plain D: no device rules apply and no special compiler is
   needed.
4. **One unit per package.** A package's shader modules, with those of its
   dependencies, compile together into one self-contained device module.
5. **Declared once, discovered always.** A package declares how its shaders
   compile once; which modules are shader code is read from the modules
   themselves, never from a list.
6. **Generated, never committed.** Generated GLSL is a build product. A build
   regenerates it exactly when an input changed.
7. **No compiler unless asked.** A consumer that does not opt in needs only
   its ordinary D compiler.
8. **Complete, validated output.** Every generated file is a whole shader
   that the reference GLSL validator accepts.

## 4. The vocabulary

The vocabulary is what an effect is written against: three vector types,
their constructors and component access, arithmetic, and the GLSL built-in
functions an effect needs. It is ordinary D on the host and becomes SPIR-V
types and instructions on the device.

**SHV1: Vector types.** The library **must** provide `vec2`, `vec3` and
`vec4`, vectors of two, three and four `float` components, with
component-wise `+`, `-`, `*` and `/` between two vectors of the same length
and between a vector and a `float` on either side, unary `-`, equality, and
`.array` for the components as a static array.

**SHV2: Representation.** Under LDC, `vec2` and `vec4` **must** be the
compiler's `__vector` types. In a device compilation `vec3` **must** be
`__vector(float[3])`. Elsewhere, and on the host under every compiler, `vec3`
**must** be a struct of three `float`s with the same operations; `vec2` and
`vec4` **may** be such structs under a compiler without the corresponding
`__vector`.

_Rationale:_ The device needs native vectors, because a struct is an
aggregate the SPIR-V backend would have to keep in memory. Host LDC sizes a
three-element `__vector` at 12 bytes while LLVM allocates 16, which breaks a
struct that contains one; three floats avoid that, at the cost of `vec3`
differing between the two sides. `SHF5` keeps that difference invisible.

**SHV3: Constructors.** `v2(x, y)`, `v3(x, y, z)` and `v4(x, y, z, w)`
**must** construct vectors from components, `v2(s)`, `v3(s)` and `v4(s)`
**must** broadcast one `float`, and `v4(rgb, a)` **must** extend a `vec3`
with a fourth component.

_Rationale:_ A `__vector` type alias cannot be called like GLSL's `vec3(…)`,
and device code may not spell the array literal D uses to build one.

**SHV4: Component access.** `x`, `y`, `z` and `w` **must** read one
component, `xy` the first two, and `xyz` (with the alias `rgb`) the first
three of a `vec4`. They are free functions reached by D's uniform function
call syntax, so `c.xyz` works on both representations.

**SHV5: Built-in functions.** The library **must** provide `floor`, `abs`,
`min`, `max`, `sqrt`, `sin`, `cos`, `pow`, `mod`, `fract`, `clamp`, `mix`,
`step`, `smoothstep`, `dot` and `length` with the names and meanings of the
[GLSL 4.60 specification §8](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html#built-in-functions),
for `float` and, where GLSL defines them per component, for each vector type.
It **must** also provide `luma(vec3)`, the Rec. 601 luma
`dot(c, v3(0.299, 0.587, 0.114))`.

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
input, the host and device results **must** agree within the error bounds
GLSL allows the device for that operation at the precision the generated
shader declares
([GLSL ES 3.00 §4.5.1](https://registry.khronos.org/OpenGL/specs/es/3.0/GLSL_ES_Specification_3.00.pdf)):
full single precision for GLSL 3.30, and `mediump` for the GLSL ES 1.00
output, which declares `precision mediump float`.

**SHV8: Inert stand-ins.** Outside a device compilation, the shader
attributes of `SHM1` and `SHF1` and the `Sampler2D` handle **must** exist
with the same names as plain D declarations that have no effect, so a shader
module compiles as ordinary D under any compiler.

## 5. Device modules

A module is shader code because its own declaration says so; the attribute is
dcompute's, and the rules a device compilation enforces are LDC's.

**SHM1: Module modes.** A module whose declaration carries
`@compute(CompileFor.deviceOnly)`, or `@compute` alone, **must** be compiled
only for the device. One carrying `@compute(CompileFor.hostAndDevice)`
**must** be compiled for both. A module without `@compute` is host code.

**SHM2: Device selection.** Device compilation **must** be selected by
compiling with a dcompute target (`-mdcompute-targets=…`), which predefines
the version identifier `LDC_DCompute`. The vocabulary **must** select its
device representation (`SHV2`) and its real attributes (`SHV8`) on that
identifier alone, never on a version of its own.

_Rationale:_ One switch cannot disagree with itself. A private version beside
the target flag was a second statement of the same fact, and the two could
be set inconsistently.

**SHM3: Device rules.** When a `@compute` module is compiled for the device,
the rules of LDC's device pass apply to it: no classes, interfaces, global
variables, associative arrays, array literals, string literals, `new`,
`delete`, concatenation, length assignment, run-time type information,
inline assembly, exceptions, string `switch`, function pointers, delegates or
`synchronized`, and calls only into other `@compute` modules or LDC's
intrinsics. The authority is LDC's
[`gen/semantic-dcompute.cpp`](https://github.com/PetarKirov/ldc/blob/6a57aafa2867b365619a052b84d3f3afa56490bc/gen/semantic-dcompute.cpp)
at the pinned compiler revision; this library adds none.

**SHM4: Host-only tests.** A `@compute` module **must not** contain unit
tests. Tests of its functions live in a module without `@compute`.

_Rationale:_ A test's name is a string literal, which `SHM3` forbids in
device code; the tests would break the device compilation they exist to
protect.

**SHM5: Lexical detection.** Whether a module is a device module **must** be
decidable from the attributes before its `module` keyword alone, without
semantic analysis. `@compute` is recognised under any qualified name ending
in `compute`. `hostAndDevice` counts only inside `@compute`'s own
parentheses, and comments, string literals and other attributes are skipped.
A file without a module declaration is host code.

_Rationale:_ The build step (`SHP3`) and editors must classify modules
before, and without, compiling them.

## 6. Fragment entry points

dcompute compiles kernels; the fragment stage is what this library requires
of the compiler on top of it. The requirements in this section bind the
pinned compiler (`SHT1`) and are checked through its output.

**SHF1: Marking.** A function in a `@compute` module marked `@fragment`
**must** become a fragment-shader entry point, named after the D function, in
the device module. The D function itself remains callable from other device
code.

**SHF2: Parameters.** Each parameter of a `@fragment` function **must** be
exactly one of these, or the compilation **must** fail with a diagnostic that
names the parameter:

- **`@input`**: an input interface variable named after the parameter, of
  the parameter's type, decorated with location 0, 1, 2, … in the order the
  `@input` parameters appear.
- **`@uniform`**: a uniform named after the parameter, of the parameter's
  type, outside any block.
- **`Sampler2D`**: a sampled 2-D image named after the parameter, bound at
  binding 1, 2, 3, … in the order the `Sampler2D` parameters appear, in
  descriptor set 0.

All images **must** be read through one sampler at binding 0 of descriptor
set 0. A parameter that the platform calling convention would rewrite **must**
be rejected with a diagnostic, not miscompiled.

**SHF3: Output.** The return value **must** be stored to one output
interface variable named `finalColor`, at location 0, of the return type. A
`void` `@fragment` function writes no output.

**SHF4: Sampling.** `sample(texture, uv)` on a `Sampler2D`, also callable as
`texture.sample(uv)`, **must** return the `vec4` that GLSL's
`texture(sampler, uv)` returns for the same image, sampler state and
coordinate.

**SHF5: Interface types.** Every input, uniform and output of an entry point
**must** have a type whose representation is the same on host and device: a
`float` or a `vec2` or `vec4`. A `vec3` **must not** cross the interface.

_Rationale:_ Nothing then depends on `vec3`'s differing layouts (`SHV2`), and
GLSL links varyings by name and type, so a type the two sides disagree on
would be a silent mismatch.

**SHF6: Opaque handles.** A `Sampler2D` **must** stay a single scalar handle
in the generated code: never a member of an aggregate, never stored in
function-local memory, and never passed across a call that survives
optimisation. Device helpers the entry point calls **must** therefore be
inlined into it.

_Rationale:_ Vulkan-flavoured SPIR-V forbids an image or sampler inside a
composite or in Function storage, and the backend cannot pass one as an
argument. The constraint is the target's, and it is why `Sampler2D` models
GLSL's combined `sampler2D` as the image alone.

**SHF7: Other stages.** A shader-stage attribute other than `@fragment`
**must** be rejected at compile time with a diagnostic naming the stage.

## 7. The build step

The build step, `shader-compile`, turns a package's shader modules into GLSL.
It takes the package's directory and an output directory, and it learns
everything else from the package's build recipe.

**SHP1: Device configuration.** A package declares its device compilation
once, as a [device configuration](../../glossary.md#device-configuration): a [dub](https://dub.pm/) configuration whose `dflags` contain
`-mdcompute-targets=<target>`; `shaders` is the conventional name. The build
step **must** use that configuration's import paths, version identifiers and
flags as `dub describe` reports them, and **must** treat a configuration
without the flag as a configuration error.

**SHP2: Host flags excluded.** The build step **must** describe the device
configuration with the `DFLAGS` environment variable removed.

_Rationale:_ dub folds `$DFLAGS` into the flags it reports, and a host build
sets it for its own compiler. A test harness's `--threads=N` or a sanitizer's
`-fsanitize=address` is meaningless to the device compiler, or fatal to it.

**SHP3: The unit.** The [shader unit](../../glossary.md#shader-unit) **must**
be every module, among the source files of the package and all its
dependencies, that `SHM5` classifies as a device module. It **must** contain
at least one device-only module, and the build step **must** compile it in a
single compiler invocation.

_Rationale:_ A SPIR-V module is self-contained; there is no linker to find a
function in another one. A device module in a dependency, such as this
library's own vocabulary, therefore belongs to the unit as much as the
package's own.

**SHP4: Validation.** The compiled SPIR-V **must** pass `spirv-val` under the
universal SPIR-V 1.4 rules before anything else reads it, and is then
optimised with `spirv-opt -O`.

_Rationale:_ Universal rules, not Vulkan's: uniforms outside a block
(`SHF2`) are valid SPIR-V that Vulkan rejects, and they are what an OpenGL
consumer needs.

**SHP5: Translation.** For each fragment entry point of the optimised module,
the build step **must** produce `<entry>.frag` in GLSL 3.30 and
`<entry>.es.frag` in GLSL ES 1.00. In each, the combined image-sampler that
the translation introduces **must** carry the name of the `Sampler2D`
parameter it came from. Unused variables are removed.

_Rationale:_ A consumer binds textures by name, and the name it knows is the
one written in D.

**SHP6: Output validation.** Every generated file **must** pass the reference
GLSL validator, `glslangValidator`, before it is written to the output
directory.

**SHP7: Provenance.** Every generated file **must** begin with a comment that
names the package, the device-only modules relative to the package
directory, and the entry point, and that states the file is generated. The
bytes **must not** depend on the directory the step runs from.

**SHP8: Atomic output.** Each output file and the stamp **must** be written
through a temporary file and a rename, the stamp last. Files in the output
directory that no entry point produces **must** be removed: the directory
belongs to the build step.

_Rationale:_ Several builds that depend on the same package may run the step
at once. A reader then sees an old file or a new one, never half of one, and
never a stamp that vouches for output not yet written.

**SHP9: Compiler.** The device compiler **must** be the executable named by
`--ldc`, or else `ldc2-vulkan` on `PATH`. No environment variable selects it.

**SHP10: Outcomes.** The build step **must** exit 0 on success or when the
output is fresh (`SHB2`), 1 when compilation, validation or translation
fails, 2 for a usage or configuration error, and 3 when the device compiler
is missing or lacks the dcompute Vulkan target or the fragment stage. Every
non-zero exit **must** print the cause; exit 3 **must** say how to obtain the
compiler.

## 8. Build integration

A consumer runs the build step inside its own build, as a step dub performs
before compiling. The freshness stamp is what makes that cheap.

**SHB1: The stamp.** After a successful run the output directory **must**
contain `.stamp`. Its first line names the stamp format version; then one
line per input with its SHA-256 and its path relative to the package
directory; then one line per output file. The inputs are the unit's modules
and the build recipe of each package that contributes one.

**SHB2: Freshness.** With `--if-stale`, the build step **must** exit 0
without running dub or the device compiler when the stamp's format version is
the current one, every recorded input exists with its recorded hash, and
every recorded output exists. Otherwise it **must** regenerate.

**SHB3: Prebuilt output.** A stamp whose only line is `prebuilt` **must** be
treated as fresh.

_Rationale:_ A packager that builds the output once, elsewhere, can hand it
to every build without the device compiler. Builds that place it trust the
packager, not the stamp.

**SHB4: Unit membership.** The stamp **must** record the set of device
modules the unit was built from, and freshness **must** fail when a device
module enters or leaves the unit, even if no recorded input changed.

**SHB5: Opt-in configuration.** A package whose code uses generated shaders
**must** provide them in a dub configuration of its own, separate from its
default one. That configuration runs the build step with `--if-stale` as a
pre-generate command, adds the output directory to its string-import paths,
and defines a version identifier by which its code selects the shader-using
declarations. The default configuration **must** build with no device
compiler on the machine.

**SHB6: Selection beside the dependency.** A package that needs the opt-in
configuration of a dependency **must** select it in each of its own
configurations that adds that dependency, next to the `dependency`
directive, and not in its top-level settings. The code that needs the
generated shaders **should** fail to compile, with a message naming the
configuration, when it is built without it. A package that cannot detect the
configuration at compile time is the exception, and **must** document the
selection instead.

_Rationale:_ dub applies a dependency's top-level `subConfiguration`, and one
inside its library configuration, even when the dependency is reachable only
through a parent configuration that the build does not select. An opt-in
selected there leaks into builds that never asked for a GPU.

**SHB7: Concurrent builds.** The pre-generate command **must** build and run
the step through dub's lock-protected build cache (`dub run --temp-build`),
so that dependents building in parallel do not race on the tool's own build.

## 9. Toolchain and platforms

**SHT1: Pinned compiler.** The device compiler is LDC with dcompute's Vulkan
target ([ldc-developers/ldc#5132](https://github.com/ldc-developers/ldc/pull/5132))
and the fragment stage of section 6, at
[`PetarKirov/ldc@6a57aafa`](https://github.com/PetarKirov/ldc/tree/6a57aafa2867b365619a052b84d3f3afa56490bc).
It is built against LLVM at
[`27ba4937`](https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3),
with the SPIR-V backend and the Vulkan fixes of
[llvm/llvm-project#216919](https://github.com/llvm/llvm-project/pull/216919).
A change to either pin **must** pass the acceptance suite of
[`testing.md`](./testing.md) before it lands.

**SHT2: Pinned SPIR-V tools.** SPIR-V Tools, SPIRV-Cross and glslang **must**
be pinned. The pinned versions are 1.4.357.0, 1.4.357.0 and 16.4.0.

_Rationale:_ Their versions shape the output: a newer `spirv-opt` rewrote one
branch of a generated shader. The pin is part of the output's definition.

**SHT3: Reproducibility.** With the toolchain of `SHT1`–`SHT2`, the same
inputs **must** produce byte-identical output on every supported platform and
in every directory.

**SHT4: Platforms.** The device toolchain **must** be available on
x86_64 Linux, aarch64 Linux and aarch64 macOS. The host side, the vocabulary
and every default configuration, **must** build on every platform the D
compilers support, Windows included. Device toolchains for other platforms
are an open question ([`decisions.md`](./decisions.md#open-questions)).
