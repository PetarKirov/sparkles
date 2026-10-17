# Circle C++ shaders (C++ / Circle)

A mode of Sean Baxter's Circle C++ compiler that lowers ordinary C++ functions and attributed namespace-scope declarations to SPIR-V (and offline to DXIL), embedding the module in the host object file so host and shaders share one translation unit, one AST and one metaprogram.

| Field          | Value                                                                                                                                               |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | C++ (C++20 plus Circle extensions: `@meta`, reflection keywords, user attributes, `if codegen`)                                                     |
| License        | Compiler: binary-only download from [circle-lang.org][circle-site]; neither public repository carries a `LICENSE` file or compiler source           |
| Repository     | Samples and docs: [seanbaxter/shaders][shaders-repo] (pinned `185c6e81`); language docs: [seanbaxter/circle][circle-repo] (pinned `b81c37d2`)       |
| Documentation  | [`README.md` (4,369 lines)][readme]; [`abstract.md`][abstract]; implicit declarations [`implicit/spirv.cxx`][spirv-cxx]                             |
| Key author     | Sean Baxter (sole author)                                                                                                                           |
| Category       | Single-source peer: an existing systems language extended with shader stages, interface attributes and GLSL built-ins                               |
| Latest version | No versioned release in either repository; the shaders repository's last commit is 2022-03-09 (first 2020-10-30, 115 commits)                       |
| Targets        | SPIR-V for OpenGL 4.6 and Vulkan (single-source); DXIL for D3D12 (offline only, six stages); the same AST also lowers to x86-64 LLVM and NVIDIA PTX |
| Stages         | 14 entry kinds: `vert`, `tesc`, `tese`, `geom`, `frag`, `comp`, `task`, `mesh`, `rgen`, `rint`, `rahit`, `rchit`, `rmiss`, `rcall`                  |

> [!NOTE]
> The compiler is not in either repository: [seanbaxter/circle][circle-repo] holds
> language notes and examples, [seanbaxter/shaders][shaders-repo] holds the shader
> documentation, samples and the implicit-declarations header. Everything below about
> the compiler's internals is taken from the author's own documentation; none of it can
> be checked against compiler source. That the compiler is _closed-source_ is inferred
> from the absence of source and license, not from a statement in either repository.

---

## Overview

### What it solves

GLSL and HLSL force each stage into its own file with an entry called `main`, describe
resources in a separate qualifier language, and give the host no type-level link to the
shader's interface: binding indices, push-constant layouts and specialization-constant
IDs are duplicated by hand on both sides. Circle removes the second language. A shader
is a C++ function with a stage attribute, an interface variable is a namespace-scope
declaration with a storage-class attribute, and the host obtains the compiled module
and the entry-point name from the compiler itself (`__spirv_data`, `__spirv_size`,
`@spirv(f)`). Because the whole program is one C++ translation unit, the host code that
binds a uniform block can reflect on the very struct type the shader reads.

### Design philosophy

The abstract states the goal ([`abstract.md`][abstract]):

> _"The Circle C++ Shaders extension aims to bring the entire capability of the OpenGL
> Shading Language (GLSL) into C++ as a first-class embedded language. Write graphics
> code using Standard C++ and mark interface variables and shader functions with C++
> attributes to indicate their role in the raster, ray-tracing or compute pipelines."_

The second pillar is that the restricted device subset is fed by an unrestricted
compile-time metaprogram ([`README.md` § Approaching Circle shaders from
Circle][readme-from-circle]):

> _"I've already conceded that it can't use virtual and indirect calls, exceptions,
> dynamic memory, file or network i/o, and many other features that C++ programmers
> consider essential. But those features may still be used in shader definitions **at
> compile time**."_

And the compilation model is one AST lowered per target, with no host/device tags
([`cuda/README.md`][circle-cuda]):

> _"Circle is a single-pass compiler. The frontend processes the source code and
> constructs an abstract syntax tree (AST) just once. The AST is then lowered to LLVM or
> SPIR-V IR for each target. … Tags like `__device__` and `__host__` are not needed, and
> macros like `__CUDA_ARCH__` cannot be used."_

This makes Circle the closest **language-shaped** analogue to a D design: templates,
compile-time execution, reflection and user attributes standing in for a separate
shading language. Architecturally it differs from LDC: Circle emits SPIR-V from its own
AST, not through LLVM IR (compare [Vcc/Shady][vcc-shady] and the [LLVM SPIR-V
backend][llvm-spirv]).

---

## How it works

### Stage and interface attributes

Entry points carry a stage attribute from the `spirv` attribute namespace; interface
variables carry a storage-class attribute plus GLSL layout qualifiers. From
[`cube/cube.cxx`][cube]:

```cpp
[[spirv::in(0)]]  vec3 in_position_vs;
[[spirv::out(1)]] vec2 out_texcoord_vs;
[[spirv::out(0)]] vec4 out_color_fs;
[[spirv::uniform(0)]] sampler2D texture_sampler;

struct uniforms_t { mat4 view_proj; float seconds; };
[[spirv::uniform(0)]] uniforms_t uniforms;

[[spirv::vert]]
void vert_main() {
  vec4 position = make_rotateY(uniforms.seconds) * vec4(in_position_vs, 1);
  glvert_Output.Position = uniforms.view_proj * position;
  out_texcoord_vs = in_texcoord_vs;
}

[[spirv::frag]]
void frag_main() { out_color_fs = texture(texture_sampler, in_texcoord_fs); }
```

The interface "globals" have no host storage: _"On the host, the user can't write to or
read from any of these interface variables; you'd get an undefined symbol error"_
([README § The vertex and fragment stages][readme-vf]). They exist only to relate a type
with a storage class and layout qualifiers.

The attribute vocabulary ([README § Interface attributes][readme-iface]) is a near
one-to-one renaming of GLSL `layout` and storage qualifiers:

| Circle attribute                               | GLSL / SPIR-V equivalent                                     |
| ---------------------------------------------- | ------------------------------------------------------------ |
| `[[spirv::in(loc)]]`, `[[spirv::out(loc)]]`    | `layout(location=…) in/out`; `Input`/`Output`                |
| `[[spirv::uniform(binding [, set])]]`          | uniform block, image or sampler; `Uniform`/`UniformConstant` |
| `[[spirv::buffer(binding [, set])]]`           | `buffer` block; `StorageBuffer`                              |
| `[[spirv::shared]]`                            | `shared`; `Workgroup`                                        |
| `[[spirv::push]]`, `[[spirv::push(max)]]`      | `layout(push_constant)`; `PushConstant`                      |
| `[[spirv::constant(id)]]`                      | `layout(constant_id=…)`; `OpSpecConstant`                    |
| `[[spirv::flat]]`, `noperspective`, `centroid` | interpolation qualifiers                                     |
| `[[spirv::format(rgba8)]]`                     | storage-image format qualifier (`gl_format_t` enum)          |
| `[[dxil::semantic("COLOR", 3)]]`               | HLSL semantic `COLOR3` (DXIL only)                           |

Built-in variables are renamed per stage — `glvert_Output.Position`,
`glcomp_GlobalInvocationID`, `glfrag_FragCoord` — because _"shaders from all stages may
coexist in a single C++ translation unit"_ ([README][readme-vf]). In
[`implicit/spirv.cxx`][spirv-cxx] they are ordinary declarations carrying the SPIR-V
`BuiltIn` number, e.g. `[[spirv::builtin(42)]] int glvert_VertexIndex;`.

### Single-source embedding and `@spirv`

With `-shader`, every shader function **ODR-used** inside a `@spirv(f)` expression is
lowered into one multi-entry-point SPIR-V module per translation unit, embedded as the
symbol `__spirv_data` (length `__spirv_size`); `@spirv(f)` yields the entry point's
mangled name for `glSpecializeShader` or `VkPipelineShaderStageCreateInfo`
([README § Using the compiler][readme-using]). Shaders that are never named are never
lowered — the same inline-linkage rule as ordinary functions. Offline modes exist too:
`-emit-spirv -c`, `-emit-dxil -c`, `-emit-dxil -S`, with `-E` choosing the entry point.

### Templates and variable templates as the interface library

Stage functions may be templates, and so may interface variables — the README's main
device for taming the interface sprawl of many shaders in one file:

```cpp
template<typename type_t, int I>
[[using spirv: out(I)]]
type_t shader_out;

[[spirv::frag]]
void frag_main() { shader_out<vec4, 0> = vec4(0, 0, 1, 1); }
```

Attribute operands may be template-dependent, including HLSL semantic names passed as
string template parameters ([`dxil/semantic.cxx`][semantic]).

### Reflection-driven binding

Circle's reflection keywords (`@member_count`, `@member_type`, `@member_value`,
`@member_name`; see [`reflection/README.md`][circle-reflection]) run inside `@meta for`
compile-time loops. Two uses tie host binding to shader declarations:

1. **Specialization constants as a struct.** A `[[spirv::constant(0)]]` struct object
   (`frag_features` in [`viewer/viewer.cxx`][viewer]) breaks each `bool`/integer member into its own `OpSpecConstant` with
   ascending IDs, defaults taken from default member initializers. The host specializes
   generically ([`include/appglfw.hxx`][appglfw]):

   ```cpp
   template<typename type_t>
   void specialize_shader(GLuint shader, const char* name, const type_t& obj) {
     const int count = @member_count(type_t);
     GLuint indices[count];
     GLuint values[count] { };
     @meta for(int i = 0; i < count; ++i) {
       indices[i] = i;
       memcpy(values + i, &@member_value(obj, i), sizeof(@member_type(type_t, i)));
     }
     glSpecializeShader(shader, name, count, indices, values);
   }
   ```

   The README's stated aim: _"We want a design with a single constant specialization set
   definition to eliminate all the points of failure"_ ([README § Reflecting on
   specialization constants][readme-reflect-spec]).

2. **User attributes generating tooling.** Dot-prefixed user attributes
   (`[[.imgui::range_float {0, 1}]] float Speed = .15;`) are typed compile-time
   key/value data on a declaration, queried with `@attribute` and `@has_attribute`. In
   [`shadertoy/shadertoy.cxx`][shadertoy] a reflective `render_imgui` walks a shader
   function object's data members and builds a Dear ImGui panel; the same object is the
   uniform block the fragment shader reads. The attributes do not affect layout.

### Push-constant parameters and chevron launches

GLSL entry points take no parameters. `[[spirv::push]]` on an entry point packs its
function parameters into an implicit `PushConstant` block (128 bytes by default) and
copies them back into `Function`-storage locals, so they behave like real parameters
([`push/README.md`][push]). A user-overloadable `spirv_chevron_comp` (and one per stage)
gives CUDA's `f<<<grid, cmd>>>(args…)` syntax; the shader is passed as a non-type
template parameter, so the chevron function can get its name via `@spirv(F)` and pack
`args…` into a tuple whose layout matches the push block ([README § Chevron
launches][readme-chevron]). Combined with `PhysicalStorageBuffer` pointers and lambda
capture this gives a bindless, CUDA-style compute API on Vulkan.

---

## Execution model and stages

Circle exposes the full Vulkan stage set of 2021: five legacy raster stages, `task` and
`mesh` (NV mesh shaders), `comp`, and six ray-tracing stages, each selected by a
`[[spirv::…]]` attribute with GLSL execution-mode operands as typed enums
(`[[spirv::geom(triangles, triangle_strip, 3)]]`, `[[spirv::frag(upper_left)]]`,
`[[spirv::local_size(x, y, z)]]` required for `comp`/`task`/`mesh`)
([README § Shader attributes][readme-attrs]). Entry points return `void` and take no
parameters except under `[[spirv::push]]`. There is no implicit per-invocation `main`:
any number of stage functions, of any name, share one module.

The execution model is GLSL's, unchanged — invocations, workgroups,
`glcomp_barrier()`, shared memory. The single-source twist is that the **same function
body** may also be called on the CPU (below), so stage semantics apply only on the
device path.

## Type system and generic programming

Vectors and matrices are **compiler built-ins**, not library classes: GCC
`vector_size` vectors extended with GLSL swizzles (`xyzw`/`rgba`/`stpq`, no domain
mixing), lvalue swizzles that reject duplicate components (`v.xx = …` is an error) and
cannot have their address taken, and `matrix_size` column-major matrices
([README § Vectors and matrices][readme-vec]). The author's justification: swizzles
_"can't sanely be implemented within C++, so custom frontend treatment is a
requirement"_. Alignment follows GCC: _"`vec2` has alignment 8, `vec3` has alignment 4
and `vec4` has alignment 16"_ — a `vec3` here is 12 bytes, unlike std140's 16-aligned
`vec3`.

Two deliberate deviations from GLSL:

- Comparison and relational operators on vectors return **`int` mask vectors** (GCC
  SIMD semantics), convertible to `bvec`; `==` converted to `bool` means _all_ equal,
  `!=` means _any_ differ, and `<` is lexicographic.
- Scalar functions are **not** implicitly mapped over vectors. Vector overloads are
  written explicitly with the `__vector_apply` intrinsic.

Generic programming is full C++: function templates, variable templates, class
templates composed into a single uniform block (the ray-marcher sample templates over a
tracer and a scene, compositing both parameter sets into one UBO), concepts, typed
enums, `@meta` loops for unrolling (`@meta for(int j = 0; j < NT; ++j)` in
[`nbody/nbody.cxx`][nbody]). Templates generate _variants_; specialization constants
generate _driver-time_ variants — the README presents the two as orthogonal axes.

## Resources, interfaces and memory layout

Resources are interface variables, never parameters (except push constants). Uniform
and storage blocks are ordinary structs and arrays: _"the Circle shader extension
internalizes their definition. You can now define uniform and storage buffers directly
with ordinary C++ structs and arrays"_, including runtime-length arrays queried with the
GLSL `.length` operator ([README § Approaching from GLSL][readme-from-glsl]).

Layout is the weakest part of the design. Blocks use the **host C++ ABI**: _"The shader
uses the layout of the type according to the Itanium C++ ABI. This is different from
the `std140` layout of GLSL"_ ([README][readme-vf]); every SPIR-V listing in the README carries
`OpExtension "GL_EXT_scalar_block_layout"` to make that legal. The promised
`[[spirv::layout(std140)]]`, `std430` and `scalar` attributes are listed under _Under
construction features_ ([README][readme-construction]). So host/device agreement holds
by construction (one struct, one ABI), but at the price of requiring
`VK_EXT_scalar_block_layout`/`GL_EXT_scalar_block_layout` and offering no route to
std140 consumers such as GLSL ES or WebGPU uniforms.

Descriptor-indexing safety is automated: Circle _"inserts the `NonUniform` SPIR-V
decoration implicitly and automatically"_ on resource-array subscripts, dropping it when
a uniformity heuristic proves the index uniform (constants, UBO/push-constant loads,
arithmetic on uniform terms) ([README § Nonuniform resource array
access][readme-nonuniform]). Opaque types (`sampler2D`, images, acceleration structures)
come from [`implicit/spirv.cxx`][spirv-cxx].

## Built-in library and intrinsics

The `-shader` switch injects [`implicit/spirv.cxx`][spirv-cxx] (3,013 lines) into the
translation unit: vector/matrix typedefs, built-in variables, and _"nearly the entire
slate of GLSL builtin functions"_. Each built-in is a real C++ function with a CPU body
**and** a SPIR-V mapping attribute:

```cpp
GLSL_PREFIX float [[spirv::GLSLstd450(13)]] sin(float a) noexcept { return __builtin_sinf(a); }
GLSL_PREFIX vec3  [[spirv::GLSLstd450(13)]] sin(vec3  a) noexcept { return __vector_apply(__builtin_sinf, a); }
```

On the SPIR-V path the call lowers to `GLSL.std.450` opcode 13 (`Sin`); on the LLVM path
the body runs. Bit casts such as `floatBitsToInt` are `[[spirv::builtin]]` with a
`reinterpret_cast` CPU body. This dual definition is precisely the shape a D vocabulary
needs — but note the CPU bodies inherit the **host libm's** precision and rounding, not
the GPU's; Circle states no agreement bound between the two. Extensions are enabled by
pragma (`#pragma spirv GL_EXT_shared_memory_block`), which also unlocks `__shared__
union` aliasing for workgroup memory.

## Control flow, memory model and restrictions

The device subset is stated plainly: _"Indirect and virtual function calls, exceptions,
dynamic memory, virtual inheritance and RTTI cannot be provided"_ ([README § Approaching
from C++][readme-from-cpp]). Pointers are the hard case, because graphics SPIR-V uses
the `Logical` addressing model. Circle runs _"special control-flow graph passes to
de-pointerize functions"_ — splitting base from offset, propagating the split, and
rewriting pointer accesses into direct indexing — with an honest caveat: _"pointers
aren't **guaranteed** to lower to SPIR-V, but with the help of these transforms,
pointers in the code you wrote likely will."_ Member functions on uniform objects work
because the backend **force-inlines** every function that returns a pointer or
reference, or takes one to a non-`Function` storage class (including `this`)
([README § Reflection and attributes for Shadertoy][readme-shadertoy]). Unions and
bit-fields are an _"implementation gray area"_.

There is no front-end marking of device-legal code: _"There's no annotation for
discriminating code that's intended to run in a shader versus code that is meant for
host execution. Including a `printf` … would pass the parser and break when lowering
for SPIR-V"_ ([README § if-codegen statements][readme-codegen]). Errors surface at
lowering. The escape hatch is `if codegen(__is_spirv_target) { … } else { … }`, a branch
resolved at code generation (after template instantiation), unlike `if constexpr`.

Structured control flow is derived by Circle's own backend from its AST, so source-level
`if`/`for` map to SPIR-V selection and loop merges directly; there is no LLVM
structurizer in the path. No memory-model or uniformity analysis beyond the
`NonUniform` heuristic is documented.

The author also reports driver fallout from the output's novelty: _"glslang doesn't
generate multi-shader SPIR-V modules. But Circle does, and this causes the graphics
drivers to segfault or error or render incorrectly in most of the samples, if run
without workarounds"_ ([README § Driver disclaimers][readme-drivers]).

## Compilation pipeline and targets

One parse and one AST; each ODR-used function is lowered per target: x86-64 LLVM for the
host, SPIR-V (from Circle's own SPIR-V emitter, not via LLVM) for OpenGL/Vulkan, NVIDIA
PTX for CUDA ([`cuda/README.md`][circle-cuda]), and DXIL. The generated SPIR-V uses
`OpMemoryModel Logical GLSL450`, `OpCapability Shader` and mangled entry names
(`_Z9vert_mainv`) unless `extern "C"` or an asm label fixes them.

DXIL is a second-class target: _"Circle doesn't yet support single-source compilation of
Windows targets, so offline compline needs be used for now"_, one entry point per module
(`@dxil` yields a `D3D12_SHADER_BYTECODE`), output signed with a bundled `dxil-signing`
tool, and only `vert`, `geom`, `tesc`, `tese`, `frag`, `comp` supported
([README § DXIL D3D12 compilation][readme-dxil];
[`dxil/shadertoy/build_shaders.bat`][build-bat]). The same `spirv`-namespace attributes
drive both backends; HLSL semantics are an additive `dxil::semantic` attribute. The
author's stated plan to rename the namespace to a neutral `shader` never shipped.

There is no GLSL, HLSL, MSL or WGSL source output, and no route to Metal or WebGPU.

## Host integration and CPU execution

Host integration is the design's centre: the module is a linked symbol, entry names come
from `@spirv`, specialization and push-constant layouts are derived by reflection from
the very types the shader declares, and chevron launches deduce template arguments from
call arguments.

CPU execution is real but partial. The Shadertoy sample has a "Render on CPU" mode with
thread pools, because _"If ODR-used from a SPIR-V entry point …, the AST is lowered to
SPIR-V IR. If ODR-used from x86-64 LLVM, the AST is lowered to x86-64 LLVM"_; clicking a
pixel can raise `SIGINT` to break in GDB inside the shader's `render` function
([README § Unified CPU and GPU rendering and CPU debugging][readme-cpu]). It works
because those shaders _"don't access textures or other features unavailable on the
CPU"_; a software library for interface variables (textures, built-ins) on the CPU is
listed as future work. The [`particles-cuda`][particles-cuda] sample runs one dynamics
definition on OpenGL compute and on CUDA in the same process, selected by `if constexpr`.

---

## Lessons for sparkles:shaders

- **Adopt: reflection-derived host binding.** Circle's `specialize_shader` and chevron
  functions prove the payoff: a D `struct` of `bool`/integer members marked
  `@specConstant(0)` should yield consecutive `OpSpecConstant` IDs and a host-side
  `VkSpecializationInfo` builder generated by `static foreach` over `.tupleof`, so the
  ID table cannot drift. The same applies to push-constant and uniform-block structs.
- **Adopt: function parameters as the interface.** Circle's `[[spirv::push]]`
  (parameters packed into an implicit push block) confirms the shape `sparkles:shaders`
  already chose for `@fragment` (`@input`/`@uniform` parameters, `SHF1`), and is the
  natural extension for compute: non-resource parameters of a `@compute` kernel become
  one push-constant block whose D layout is the host tuple's.
- **Match: every built-in has a CPU body and a SPIR-V mapping in one declaration.**
  `[[spirv::GLSLstd450(13)]] sin(float)` with a `__builtin_sinf` body is the pattern for
  `sparkles.shaders.math`; unlike Circle, pin the CPU body to the GPU's semantics and
  test it against the Vulkan precision table (`D12`), not the host libm.
- **Match: lvalue swizzles with GLSL's rules.** Circle needed compiler support; D's
  `opDispatch` can give rvalue and lvalue swizzles, and should reject duplicate
  components on write (`v.xx = …`) and mixed domains (`.rgxy`) at compile time, as
  Circle does.
- **Avoid: host-ABI block layout.** Circle's Itanium layout plus
  `GL_EXT_scalar_block_layout` keeps one struct in sync but locks out std140 consumers;
  derive std140/std430/scalar offsets at CTFE from one struct and `static assert` them
  per target, as `D9` already anticipates.
- **Avoid: discovering device-illegal code at lowering.** Circle's "passes the parser
  and breaks when lowering" is the failure mode a D design should prevent: diagnose
  `new`, classes, exceptions, recursion and unsupported pointers in a `@compute` module
  in the front end (as `D13` does for the interface), keeping `version (LDC_DCompute)`
  as the analogue of `if codegen`.
- **Adopt: automatic `NonUniform` with a uniformity heuristic** once descriptor arrays
  enter the vocabulary, rather than a GLSL-style `nonuniformEXT` the user must remember.
- **Test: multi-entry-point modules are driver-hostile.** Keep the build step emitting
  what glslang emits (one entry point per translated output) and treat SPIR-V-level
  validation as insufficient evidence of driver acceptance.

## Strengths

- One translation unit, one AST, one type system for host and every stage; no second
  language to keep in sync.
- Reflection and typed user attributes make interface metadata (spec-constant IDs,
  push layouts, editor UIs) generated, not duplicated.
- Full C++ generics in shaders, including variable templates for interface declarations
  and template-dependent attribute operands.
- Complete Vulkan-era stage coverage (raster, tessellation, geometry, mesh, ray tracing)
  from one attribute vocabulary, plus an offline DXIL path.
- Compile-time execution of arbitrary host libraries (a PNG decoder generating compute
  shaders) — the device subset is small, the metaprogram is not.
- Genuine CPU execution and GDB debugging of shader bodies that avoid device-only
  features.

## Weaknesses

- Single author, binary-only compiler, no license, no versioned releases; the shaders
  repository has been idle since 2022-03-09 and the author's subsequent work (New
  Circle) does not mention shaders.
- Block layout is the host ABI, with std140/std430 attributes never delivered.
- Device legality is decided at lowering, not parsing; pointer support is
  best-effort ("likely will").
- DXIL is offline-only, six stages, one entry per module; no MSL, WGSL or GLSL output.
- CPU execution covers only shaders that avoid textures and interface variables; CPU
  built-ins use host-libm semantics with no stated agreement bound.
- Multi-entry-point modules exposed driver bugs across vendors.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                               | Trade-off                                                                |
| ------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Interface as attributed namespace-scope declarations    | Mirrors GLSL globals; any stage function can read them                  | Global names pile up; variable templates needed to tame them             |
| Push-constant parameters only under `[[spirv::push]]`   | CUDA-like ergonomics without changing GLSL's entry model                | Two interface styles in one language                                     |
| One SPIR-V module per translation unit, many entries    | Single `vkCreateShaderModule`; ODR-use selects what is emitted          | Unusual output that triggered driver bugs                                |
| Vectors/matrices as compiler built-ins                  | Swizzle lvalues and GLSL initializers impossible in library C++         | Bespoke semantics (int-mask comparisons, no implicit vector mapping)     |
| Host C++ ABI layout plus scalar block layout            | Host and device structs agree by construction                           | Requires `scalar_block_layout`; no std140 targets                        |
| No host/device annotation; `if codegen` for divergence  | One AST, no `__device__` tags, every function callable on both sides    | Device-illegal code is diagnosed only when lowered                       |
| Own SPIR-V emitter from the AST, de-pointerizing passes | Structured control flow comes from source; logical addressing reachable | Pointers best-effort; a second backend to maintain beside LLVM           |
| Reflection and user attributes as first-class features  | Bindings, spec constants and tooling generated from one type            | Requires Circle's non-standard extensions; not portable C++              |
| DXIL from the same attributes, offline                  | Reuse the `spirv` vocabulary for D3D12                                  | No single-source on Windows (no MSVC ABI); one entry per module, signing |

## Sources

- [seanbaxter/shaders `README.md` — the Circle C++ shaders manual][readme]
- [seanbaxter/shaders `abstract.md`][abstract]
- [`implicit/spirv.cxx` — injected vectors, built-ins and GLSL functions][spirv-cxx]
- [`cube/cube.cxx`][cube] · [`nbody/nbody.cxx`][nbody] · [`viewer/viewer.cxx`][viewer] · [`shadertoy/shadertoy.cxx`][shadertoy]
- [`include/appglfw.hxx` — reflective `specialize_shader`][appglfw]
- [`push/README.md` — push-constant parameters with SPIR-V output][push]
- [`dxil/semantic.cxx`][semantic] · [`dxil/shadertoy/build_shaders.bat`][build-bat] · [`particles-cuda/particles-cuda.cxx`][particles-cuda] · [`attributes/attrib1.cxx`][attrib1]
- [seanbaxter/circle `README.md`][circle-readme] · [`cuda/README.md` — Circle as a heterogeneous compiler][circle-cuda] · [`reflection/README.md`][circle-reflection]
- [circle-lang.org — compiler downloads][circle-site]
- Related: [Rust-GPU][rust-gpu] · [Vcc/Shady][vcc-shady] · [Slang][slang] · [CUDA/HIP][cuda-hip] · [concepts][concepts] · [comparison][comparison] · [index][index]
- sparkles: [`sparkles:shaders` SPEC][spec] · [decisions][decisions]

<!-- References -->

[circle-site]: https://www.circle-lang.org/
[shaders-repo]: https://github.com/seanbaxter/shaders/tree/185c6e81bfaabd54fde80a0a2318636ae01bfab5
[circle-repo]: https://github.com/seanbaxter/circle/tree/b81c37d2bb227cdf6aa58a90dd00f12f62c8d3bc
[readme]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md
[readme-from-circle]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#approaching-circle-shaders-from-circle
[readme-from-cpp]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#approaching-circle-shaders-from-c
[readme-from-glsl]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#approaching-circle-shaders-from-glsl
[readme-vf]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#the-vertex-and-fragment-stages
[readme-iface]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#interface-attributes
[readme-attrs]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#shader-attributes
[readme-using]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#using-the-compiler
[readme-drivers]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#driver-disclaimers
[readme-reflect-spec]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#reflecting-on-specialization-constants
[readme-shadertoy]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#reflection-and-attributes-for-shadertoy-development
[readme-cpu]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#unified-cpu-and-gpu-rendering-and-cpu-debugging
[readme-codegen]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#if-codegen-statements
[readme-chevron]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#chevron-launches
[readme-nonuniform]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#nonuniform-resource-array-access
[readme-dxil]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#dxil-d3d12-compilation
[readme-vec]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#vectors-and-matrices
[readme-construction]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/README.md#under-construction-features
[abstract]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/abstract.md
[spirv-cxx]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/implicit/spirv.cxx
[cube]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/cube/cube.cxx
[nbody]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/nbody/nbody.cxx
[viewer]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/viewer/viewer.cxx
[shadertoy]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/shadertoy/shadertoy.cxx
[appglfw]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/include/appglfw.hxx
[push]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/push/README.md
[semantic]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/dxil/semantic.cxx
[build-bat]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/dxil/shadertoy/build_shaders.bat
[particles-cuda]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/particles-cuda/particles-cuda.cxx
[attrib1]: https://github.com/seanbaxter/shaders/blob/185c6e81bfaabd54fde80a0a2318636ae01bfab5/attributes/attrib1.cxx
[circle-readme]: https://github.com/seanbaxter/circle/blob/b81c37d2bb227cdf6aa58a90dd00f12f62c8d3bc/README.md
[circle-cuda]: https://github.com/seanbaxter/circle/blob/b81c37d2bb227cdf6aa58a90dd00f12f62c8d3bc/cuda/README.md
[circle-reflection]: https://github.com/seanbaxter/circle/blob/b81c37d2bb227cdf6aa58a90dd00f12f62c8d3bc/reflection/README.md
[rust-gpu]: ./rust-gpu.md
[vcc-shady]: ./vcc-shady.md
[slang]: ./slang.md
[cuda-hip]: ./cuda-hip.md
[llvm-spirv]: ./llvm-spirv-backend.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[decisions]: ../../specs/shaders/decisions.md
