---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-05
---

# `sparkles:shaders` — Specification

## Abstract

`sparkles:shaders` lets a D program write a per-pixel effect's computation
once, as an ordinary D function, and run it in two places: on the CPU, where
any D compiler calls it directly, and on the GPU, where the same source is
compiled into a fragment shader, behind a thin entry point that reads its
inputs and uniforms, samples its textures and calls it. It provides
GLSL-shaped vectors and built-in functions with GLSL's definitions on both
sides, and a build step that turns a package's shader code into validated GLSL
during the build. Its GPU half needs LDC, the LLVM-based D compiler, extended
with a fragment-shader entry point. Only a build that generates GLSL needs
that compiler: one that uses only the CPU half, or prebuilt GLSL, does not.

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

D has GPU compilation, but not for this. LDC's dcompute, its support for
compiling D to GPU code, compiles marked D modules for compute kernels:
functions launched over a grid that read and write buffers. Its Vulkan target
([ldc-developers/ldc#5132](https://github.com/ldc-developers/ldc/pull/5132))
emits SPIR-V. A fragment shader is a different shape. Its inputs are
interpolated values from the previous pipeline stage, sampled textures and
named uniforms, and its output is a colour; a graphics API links all of these
by name (GLSL ES 1.00 by name alone, so names must survive translation), and
in newer GLSL also by location. dcompute has no graphics stages. D's own
numeric semantics also differ from GLSL's in details that matter for effects,
and GPUs consume SPIR-V or GLSL, not D. Finally, a compiler that emits SPIR-V
is a custom LDC built against a development LLVM: far too heavy to impose on
every program that merely uses an effect on the CPU.

This library writes each effect as a [single-source
shader](../../glossary.md#single-source-shader): one D function over a small
[vocabulary](../../glossary.md#shader-vocabulary) of GLSL-shaped types and
built-ins, compiled twice. The vocabulary implements GLSL's definitions, so
the two compilations agree within the floating-point error the GPU's precision
permits (section 4 and decision `D12` give the bounds); both sides compute in
`float`, and the compound built-ins are the same D formula on both. A module
is shader code because its declaration carries dcompute's `@compute` attribute
(named for dcompute's kernels, and used here for fragment shaders too); this
document calls it a device module. A device module marked device-only is never
compiled for the host; one marked host-and-device is compiled for both. The
host compilation is ordinary D, so any compiler and any CPU caller can use the
shader's functions. The device compilation goes through dcompute, with the
Vulkan target of the pull request above and a fragment stage added by a fork
of LDC: a function marked as a [fragment entry
point](../../glossary.md#fragment-entry-point) has its parameters turned into
the shader's inputs, textures and uniforms, and its return value into the
colour output. The entry point itself runs only on the GPU: one that samples a
texture can only be compiled for the device, so it lives in a device-only
module (`SHF1`). It stays thin: it samples and forwards to host-and-device
functions, which the CPU calls with its own values, as a terminal does once
per cell with the cell's colour. A build step compiles a package's device
modules to SPIR-V, validates it (`spirv-val`), translates each entry point
with `spirv-cross` into GLSL for OpenGL 3.3 (GLSL 3.30) and OpenGL ES 2.0
(GLSL ES 1.00), and validates the result again (`glslangValidator`). It runs
as part of an ordinary build of a [dub](https://dub.pm/) package, D's package
manager and build tool, and the GLSL it writes is a build product that is
never committed. In a developer's build, a [freshness
stamp](../../glossary.md#freshness-stamp) recording the hashes of the device
modules and their recipes lets it skip all work while they are unchanged (the dependencies' device modules included); it does not
track a module they import without being device modules themselves, or the
toolchain, which changes only with a new development environment or another
`--ldc`, after which the developer runs the step once without its freshness
check (decision `D14`). A packager, which builds in a sandbox (here, the Nix
build), builds the GLSL once instead, tracking the compiler and tools as well,
and hands it to every build, which then needs no custom compiler. Consumers
opt in to the generated GLSL per dub configuration, so the custom compiler is
needed exactly where GLSL is generated; a build that opts in and must generate
GLSL (it has neither prebuilt nor fresh output) but has no compiler fails and
says how to obtain it.

The scope is the fragment stage. Vertex, geometry and compute shading,
matrices, integer and double-precision vector types in the vocabulary, and
runtime shader compilation are outside it (an integer may still cross the
interface as a uniform). So is anything that draws: registering effects,
binding textures and uniforms, and running passes belong to the consumer's
renderer, which this library hands complete GLSL source; its vertex stage
supplies the varyings under the D parameters' names. SPIR-V is an
intermediate the build step consumes, not an output. A Vulkan consumer, which
would need descriptor and push-constant layouts, is not served. The compiler
itself is a pinned dependency: this specification states what it requires of
the compiler, including the fragment stage, not how the compiler implements
it. Editor diagnostics for shader code are specified by the analysis library
that provides them, `sparkles:dmd-lsp` ([target
profiles](../dmd-lsp/targets.md)). [`decisions.md`](./decisions.md) records
each exclusion with what would bring it back.

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

GPU terms follow their standards.
[SPIR-V](https://registry.khronos.org/SPIR-V/) is the Khronos intermediate
language for shaders. GLSL is the OpenGL Shading Language: version 3.30 for
desktop OpenGL 3.3 and [ES
1.00](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)
for OpenGL ES 2.0. A _varying_ is an input a fragment shader receives,
interpolated from the previous stage; a _uniform_ is a value constant over one
draw. dcompute's own terms keep their meaning: the _host_ is the CPU side of a
program, the _device_ the GPU side.

## 3. The contract at a glance

1. **One source.** An effect is one D function. Its CPU behaviour and its
   GPU shader derive from that function; neither is written separately.
2. **One meaning.** Every vocabulary operation computes the same result on
   the host and the device, within the bounds of `SHV7`.
3. **Device code is opt-in by target.** Without a GPU compilation target the
   vocabulary is plain D: no device rules apply and no special compiler is
   needed.
4. **One unit per package.** A package's shader modules, with those of its
   dependencies, compile together into one self-contained device module.
5. **Declared once, discovered always.** A package declares how its shaders
   compile once; which modules are shader code is read from the modules
   themselves, never from a list.
6. **Generated, never committed.** Generated GLSL is a build product. The
   build that ships it is a Nix derivation, which regenerates it exactly when
   an input changed, the toolchain included; a developer's build regenerates
   it when one of the unit's modules or their recipes changes (and, once
   `SHB4` is delivered, when a module joins or leaves the unit).
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
and between a vector and a `float` on either side, unary `-`, and `.array`
for the components as a static array. Equality of two vectors **must** be
`allEqual(a, b)`, one `bool` that is true when every component is equal,
GLSL's `all(equal(a, b))`; `==` on two vectors is outside the vocabulary.

_Rationale:_ D's `==` on a `__vector` is a mask, one lane per component, and
on a struct a `bool`, so the same expression would mean different things
under LDC and DMD. GLSL's `==` on vectors is the single `bool`.

**SHV2: Representation.** Under LDC, `vec2` and `vec4` **must** be the
compiler's `__vector` types. In a device compilation `vec3` **must** be
`__vector(float[3])`. Elsewhere, and on the host under every compiler, `vec3`
**must** be a struct of three `float`s with the same operations; `vec2` and
`vec4` **may** be such structs under a compiler without the corresponding
`__vector`. Whatever the representation, each type **must** have the device's
size and alignment: 8 bytes for `vec2`, 16 for `vec3` and `vec4`. The
vocabulary **must** also provide packed variants (`Vec2Packed`, `Vec3Packed`,
`Vec4Packed`), whose components are back to back, and conversions between
the two.

_Rationale:_ The device needs native vectors, because a struct is an
aggregate the SPIR-V backend would have to keep in memory. A released host
LDC sizes a three-element `__vector` at 12 bytes while LLVM allocates 16,
which breaks a struct that contains one, and DMD has no such vector; a
struct avoids both. Aligning it like the device's vector means a value, a
struct field or an array element occupies the same bytes on both sides, in
the device compiler's memory layout. GLSL's `std140` is a different layout:
it places a scalar that follows a `vec3` at offset 12, in the padding, where
both sides here place it at 16. The packed variants keep dense host arrays at
three floats per element.

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
`min`, `max`, `sqrt`, `sin`, `cos`, `exp`, `pow`, `mod`, `fract`, `clamp`,
`mix`, `step`, `smoothstep`, `dot` and `length` with the names and meanings
of the
[GLSL 4.60 specification §8](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html#built-in-functions),
for `float` and, where GLSL defines them per component, for each vector type,
including GLSL's forms that widen a `float` argument to every component:
`min`, `max` and `mod` with a `float` second argument, `clamp` with `float`
bounds, `step` and `smoothstep` with `float` edges, and `mix` with a vector
or a `float` weight.
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
`mod` by zero, `smoothstep` with
`e0 >= e1`, and `clamp` with `lo > hi`; on those inputs nothing is required.

**SHV8: Inert stand-ins.** Outside a device compilation, the shader
attributes of `SHM1`, `SHF1` and `SHF2` and the `Sampler2D` handle **must** exist
with the same names as plain D declarations that have no effect, so a
host-and-device module compiles as ordinary D under any compiler. A
device-only module is never compiled for the host, and need not compile
there: it samples textures, which only the device compilation can do.

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
semantic analysis. `@compute` is recognised under any qualified name whose
last component is `compute`. Its argument, if any, **must** be
`CompileFor.deviceOnly` or `CompileFor.hostAndDevice`, optionally qualified;
any other spelling (a cast, arithmetic on the enum) is unsupported, and the
classification of a module that uses one is unspecified. `hostAndDevice`
counts only inside `@compute`'s own parentheses, and comments, string
literals and other attributes are skipped. A UTF-8 byte-order mark before the
declaration is skipped. A file without a module declaration is host code.

_Rationale:_ The build step (`SHP3`) and editors must classify modules
before, and without, compiling them.

## 6. Fragment entry points

dcompute compiles kernels; the fragment stage is what this library requires
of the compiler on top of it. The requirements in this section bind the
pinned compiler (`SHT1`) and are checked through its output.

**SHF1: Marking.** A function in a `@compute` module marked `@fragment`
**must** become a fragment-shader entry point, named after the D function, in
the device module. The D function itself remains callable from other device
code. An entry point that samples a texture compiles only for the device, so it
belongs in a device-only module: in a host-and-device module the host
compilation fails at the sample, since `SHV8`'s stand-in cannot sample. An
entry point's name
**must** be unique across the unit; a second
function of the same name **must** fail the compilation with a diagnostic
naming both definitions.

_Rationale:_ The build step names each generated file after its entry point
(`SHP5`), and a renamed duplicate (`tint.1`) is a name no D function has.

**SHF2: Parameters.** Each parameter of a `@fragment` function **must** be
exactly one of these — one marker, and none on a `Sampler2D` — or the
compilation **must** fail with a diagnostic that names the parameter:

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

Every interface name, and the field names of a uniform struct, **must** reach
the generated GLSL unchanged. A name the translation would rewrite **must**
fail the compilation with a diagnostic naming it: one GLSL reserves (by
spirv-cross's list), one with the `gl_` or `spv` prefix, one of the
translation's temporary names (`_` and digits, alone or followed by `_` and
anything; `_m` and digits, alone, for a struct field), one with a run of underscores, and one
with a character outside ASCII letters, digits and `_`. A host binds by these
names.

An interface name **must** denote one variable across the unit: every entry
point that names it **must** give it the same kind, the same type and the
same location or binding, or the compilation **must** fail with a diagnostic that names both
entry points.

_Rationale:_ The unit compiles to one module (`SHP3`), in which a name is one
variable with one decoration. Two entry points that put it at different
ordinals would otherwise share the first one's, and one of them would read
through a location or binding it did not ask for, with no validator able to
tell.

**SHF3: Output.** The return value **must** be stored to one output
interface variable named `finalColor`, at location 0, of the return type,
which **must** be `vec4`. A `void` `@fragment` function writes no output.

**SHF4: Sampling.** `sample(texture, uv)` on a `Sampler2D`, also callable as
`texture.sample(uv)`, **must** return the `vec4` that GLSL's
`texture(sampler, uv)` returns for the same image, sampler state and
coordinate.

**SHF5: Interface types.** Every input, uniform and output of an entry point
**must** have a type that both generated dialects (`SHP5`) can declare at that
end of the interface, with the same meaning:

- an input: `float`, `vec2`, `vec3` or `vec4`;
- the output: `vec4` (`SHF3`);
- a uniform: any of those, `int` or a vector of two to four `int`s (written
  `__vector(int[N])`; the vocabulary has no integer vector type), or a struct
  or static array of uniform types.

A uniform's declaration **must** carry its D type: an `int` is declared
`int`, and a struct's members are named after its fields. Any other type
**must** fail the compilation with a diagnostic that names the parameter and
the reason.

_Rationale:_ GLSL ES 1.00 has no unsigned or integer varyings, writes its one
colour output through a `vec4`, and has no `uint`. The host binds a uniform
by name and type, so a declaration that says `uint` for an `int`
(`glUniform1i` then fails) or `_m0` for a field breaks the binding without a
diagnostic. Every vector already occupies the same bytes on both sides
(`SHV2`).

**SHF6: Opaque handles.** A `Sampler2D` **must** stay a single scalar handle
in the generated code: never a member of an aggregate, never stored in
function-local memory, and never passed across a call that survives
optimisation. Device helpers the entry point calls **must** therefore be
inlined into it.

_Rationale:_ Vulkan-flavoured SPIR-V forbids an image or sampler inside a
composite or in Function storage, and the backend cannot pass one as an
argument. The constraint is the target's, and it is why `Sampler2D` models
GLSL's combined `sampler2D` as the image alone.

**SHF7: Other stages.** The compiler declares no shader stage but
`@fragment`. A stage attribute carrying any other value **must** be rejected
at compile time with a diagnostic that reports the value.

## 7. The build step

The build step, `shader-compile`, turns a package's device modules into GLSL.
It takes the package's directory, an output directory, and the name of the
device configuration (`--config`, `shaders` by default), and it learns
everything else from the package's build recipe. The configuration is chosen
by that name and must then be a device build (`SHP1`). `--ldc` names the
compiler (`SHP9`), `--if-stale` asks for the freshness check (`SHB2`), and
`--keep` and `--quiet` change only what it prints and leaves behind.

**SHP1: Device configuration.** A package declares its device compilation
once, as a [device configuration](../../glossary.md#device-configuration): a [dub](https://dub.pm/) configuration whose `dflags` contain
`-mdcompute-targets=<target>`, where the target is exactly one of
`vulkan-100`, `vulkan-110`, `vulkan-120`, `vulkan-130` and `vulkan-140`;
`shaders` is the conventional name. The build
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
consumer needs. What may cross the interface is the compiler's to enforce
(`SHF2`, `SHF5`, `D13`), not the validator's.

**SHP5: Translation.** For each fragment entry point of the optimised module,
the build step **must** produce `<entry>.frag` in GLSL 3.30 and
`<entry>.es.frag` in GLSL ES 1.00. In each, the combined image-sampler that
the translation introduces **must** carry the name of the `Sampler2D`
parameter it came from. Unused interface variables are removed.

_Rationale:_ A consumer binds textures by name, and the name it knows is the
one written in D.

**SHP6: Output validation.** Every generated file **must** pass the reference
GLSL validator, `glslangValidator`, before it is written to the output
directory.

**SHP7: Provenance.** Every generated file **must** begin with a comment that
names the package as its recipe names it, every device-only module of the
unit relative to the package directory, and the entry point, and that states
the file is generated. The generated GLSL's bytes **must not** depend on the
directory the step runs from (the stamp's paths may).

**SHP8: Atomic output.** Each output file and the stamp **must** be written
through a temporary file and a rename, the stamp last. Every `*.frag` file in
the output directory that no entry point produces **must** be removed, and so
must a temporary whose writer is no longer running: the directory belongs to
the build step. A temporary is named `<file>.tmp-<pid>`, and its writer is
judged running by its process id: concurrent runs are assumed to share one
host and process-id namespace, and a writer outside it looks gone. A file
that only resembles a temporary, or whose writer cannot be judged, stays.
Other files there, such as a `.gitignore`, are left alone.

_Rationale:_ Several builds that depend on the same package may run the step
at once. A reader then sees an old file or a new one, never half of one, and
never a stamp that vouches for output not yet written.

**SHP9: Compiler.** The device compiler **must** be the executable named by
`--ldc`, or else `ldc2-vulkan` on `PATH`. No environment variable selects it.

**SHP10: Outcomes.** The build step **must** exit 0 on success or when the
output is fresh (`SHB2`), 1 when compilation, validation or translation
fails, 2 for a usage or configuration error, and 3 when the toolchain cannot
do the work. It **must** decide them in this order, reporting the first that
applies:

1. the arguments are malformed: 2;
2. with `--if-stale`, the output is fresh: 0;
3. the device compiler, dub, or a SPIR-V or GLSL tool cannot be run: 3;
4. the device configuration cannot be described, describes no build target
   (it has no sources, or a target type that builds nothing), names no
   dcompute target, names anything but exactly one of the Vulkan targets of
   `SHP1`, or yields no device-only module: 2;
5. the unit fails to compile: 3 if the device compiler cannot compile a
   minimal `@fragment` shader for that target either, 1 otherwise;
6. the unit fails to validate or translate: 1.

Every non-zero exit **must** print the cause; exit 3 **must** say how to
obtain the toolchain.

_Rationale:_ Describing the configuration runs the compiler, so a missing
compiler comes before every configuration error. Whether a compiler has the
fragment stage is decided by what it can compile, not by matching its
messages about the unit, which name neither cause reliably; the minimal
shader is tried only once the unit has failed, so a successful run pays
nothing for it.

## 8. Build integration

A consumer runs the build step inside its own build, as a step dub performs
before compiling. The freshness stamp is what makes that cheap. It is a
shortcut for the edit loop, not a build system: it records what a developer
edits (the unit's modules and their recipes), not the compiler, the SPIR-V
and GLSL tools, or a module the unit imports without containing it. Output
that ships, or that a build machine caches, comes from a Nix derivation whose
inputs are all of those, placed with a `prebuilt` stamp (`SHB3`, `D14`).

**SHB1: The stamp.** After a successful run the output directory **must**
contain `.stamp`. Its first line names the stamp format version; then one
line per input with its SHA-256 and its path relative to the package
directory; then one line per output file. The inputs are the unit's modules
and the build recipe of each package that contributes one, and each hash is
taken as soon as the configuration is described, before the compiler reads
the file, so a file edited while the step runs leaves the stamp stale.

**SHB2: Freshness.** With `--if-stale`, the build step **must** exit 0
without running dub or the device compiler when the stamp's format version is
the current one, every recorded input exists with its recorded hash, and
every recorded output exists, and it records at least one input and one
output. A stamp with any other line, or a malformed one, is stale, except
the prebuilt stamp of `SHB3`. Lines of each kind may come in any order.
Otherwise it **must** regenerate.

**SHB3: Prebuilt output.** With `--if-stale`, a stamp whose only line is
`prebuilt`, trailing blank lines aside, **must** be treated as fresh. Without
`--if-stale` the step always regenerates.

_Rationale:_ A packager that builds the output once, elsewhere, can hand it
to every build without the device compiler. Builds that place it trust the
packager, not the stamp.

**SHB4: Unit membership.** Freshness **must** fail when a device module
enters or leaves the unit, even if no recorded input changed. To decide it
without dub or the compiler, the stamp **must** record a deterministic
digest of the device modules among the files the unit can be drawn from (the
source directories of the device configuration and of every dependency):
each one's relative path and `SHM5` mode, not its contents, and nothing about
the other files. The candidates are a
[fileset](../build-primitives/filesets/SPEC.md) resolution, and the digest
**must** depend only on those paths and modes, never on timestamps,
enumeration order, the host or the checkout's location.

_Rationale:_ A list of the files a unit was built from cannot notice a file
that was not on it. A digest of every file that could belong to the unit
does. Membership changes only when a device module appears, disappears or
changes mode, so a digest of contents, or of every file's path, would
regenerate the GLSL, and require the device compiler, on unrelated edits to
any dependency; the unit's own modules are already inputs (`SHB1`).

**SHB5: Opt-in configuration.** A package whose code uses generated shaders
**must** provide them in a dub configuration of its own, separate from its
default one. That configuration runs the build step with `--if-stale` as a
pre-generate command, adds the output directory to its string-import paths,
and defines a version identifier by which its code selects the shader-using
declarations. The default configuration **must** build with no device
compiler on the machine.

**SHB6: Selection beside the dependency.** The opt-in configuration **must**
be selected beside every dependency through which it is reached: each package
whose configuration adds such a dependency selects it in that configuration,
next to the `dependency` directive, and not in its top-level settings. An
application, which nothing depends on, **may** select it at top level. The
code that needs the generated shaders **should** fail to compile, with a
message naming the configuration, when it is built without it.

_Rationale:_ dub applies a dependency's top-level `subConfiguration`, and one
inside its library configuration, even when the dependency is reachable only
through a parent configuration that the build does not select. An opt-in
selected there leaks into builds that never asked for a GPU. The package that
needs the opt-in may itself be reachable only that way, as a backend is, so
the selection belongs to each package that adds the edge; an application's
top level leaks into nothing.

**SHB7: Concurrent builds.** Dependents building in parallel **must not**
race on the build of the step itself or on its output. The pre-generate
command builds and runs the step with `dub run --temp-build`, which builds in
a temporary directory rather than into the step's package, and the step's own
writes are atomic (`SHP8`).

## 9. Toolchain and platforms

**SHT1: Pinned compiler.** The device compiler is LDC with dcompute's Vulkan
target ([ldc-developers/ldc#5132](https://github.com/ldc-developers/ldc/pull/5132))
and the fragment stage of section 6, at
[`PetarKirov/ldc@8ba52d40`](https://github.com/PetarKirov/ldc/tree/8ba52d400779edc9512ddc6042d1c7fcdf56c25e).
It is built against LLVM at
[`27ba4937`](https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3),
with the SPIR-V backend, the Vulkan fixes of
[llvm/llvm-project#216919](https://github.com/llvm/llvm-project/pull/216919),
and two patches of this project's (signed integers by module flag with
struct member names, and 32-bit access-chain indices) whose upstreaming is
tracked in [#647](https://github.com/PetarKirov/sparkles/issues/647).
A change to either pin **must** pass the acceptance suite of
[`testing.md`](./testing.md) before it lands.

**SHT2: Pinned SPIR-V tools.** SPIR-V Tools, SPIRV-Cross and glslang **must**
be pinned. The pinned versions are 1.4.357.0, 1.4.357.0 and 16.4.0.

_Rationale:_ Their versions shape the output: a newer `spirv-opt` rewrote one
branch of a generated shader. The pin is part of the output's definition.

**SHT3: Reproducibility.** With the toolchain of `SHT1`–`SHT2`, the same
inputs **must** produce byte-identical GLSL on every supported platform and
in every directory. (The stamp records paths relative to the package, which
can differ.)

**SHT4: Platforms.** The device toolchain **must** be available on
x86_64 Linux, aarch64 Linux and aarch64 macOS. The host side, the vocabulary
and every default configuration, **must** build on every platform the D
compilers support, Windows included. Device toolchains for other platforms
are an open question ([`decisions.md`](./decisions.md#open-questions)).
