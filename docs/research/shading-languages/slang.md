# Slang (Khronos / NVIDIA)

An HLSL-compatible shading language and IR-based compiler that adds checked generics, interfaces with associated types, modules with link-time specialization, automatic differentiation and a capability type system, and emits SPIR-V, DXIL, HLSL, GLSL, Metal, WGSL, CUDA and CPU code from one source.

| Field          | Value                                                                                                                                    |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Slang (HLSL superset); compiler in C++                                                                                                   |
| License        | Apache-2.0 WITH LLVM-exception ([`LICENSE`][license])                                                                                    |
| Repository     | [shader-slang/slang][repo] (pinned at `60a7c8c88c8d`, `v2026.20-1-g60a7c8c88`, 2026-10-17)                                               |
| Documentation  | [User guide][ug-web] · in-tree [`docs/user-guide/`][ug-intro]                                                                            |
| Category       | Shading language + multi-target compiler                                                                                                 |
| Latest version | `v2026.20` (tag created 2026-10-16; tagged commit `d9ede2dd5836` dated 2026-10-17 UTC), verified with `git for-each-ref` on the clone    |
| Targets        | SPIR-V (direct), DXIL (via DXC), DXBC (via fxc), HLSL, GLSL, Metal, WGSL, CUDA/PTX, OptiX, C/C++, LLVM IR/object code, Slang VM bytecode |
| Language eds.  | `legacy` (2018, default), `2025`, `2026` (= `latest`), `202c` (in development)                                                           |
| Stdlib size    | [`hlsl.meta.slang`][hlsl-meta] is 36,350 lines, with 1,114 `__target_switch` and 761 `spirv_asm` occurrences                             |

> [!NOTE]
> Facts below are read from the clone at `60a7c8c88c8dd503087ad9fa6c3a5620ec28d223`. Release notes for
> versions before `v2026.20` were not re-read; per-release feature dates (for example "SER on SPIR-V in
> 2026.18") come from the starting notes and are **not verified against a pinned source**.

---

## Overview

### What it solves

HLSL and GLSL specialise shaders with the preprocessor: one `#define` per variant, one full front-end
pass per variant, no type checking of the code between `#ifdef`s, and no way for the application to
inspect what the shader expects. Slang keeps HLSL source compatibility and replaces each of those
mechanisms with a language feature: interfaces and generics for variant selection, a module system
with precompiled IR for separate compilation, link-time constants and types for late specialization,
`ParameterBlock<T>` for descriptor-set grouping, and a reflection API that reports binding and layout
per target. It also carries features that came out of research on differentiable rendering, chiefly
forward- and reverse-mode automatic differentiation of shader code.

### Design philosophy

The user guide's introduction ([`00-introduction.md`][ug-intro]) states the ordering of goals:

> _"**Performance**: Real-time graphics demands high performance, which motivates the use of GPUs.
> Whenever possible, the benefits of using Slang must not come at the cost of performance. When a
> choice involves a performance trade-off the *user* of the system should be able to make that choice."_

and, on portability, rejects the lowest-common-denominator approach:

> _"We aspire to keep our "min spec" as low as is practical (e.g., supporting Direct3D 11 and not just
> Direct3D 12), while also allowing each target to expose its distinguishing capabilities."_

Two consequences shape the language. First, generics are **checked once, not duck-typed**: the
interfaces chapter ([`06-interfaces-generics.md`][ug-generics]) calls this _"a major difference of
Slang's generics compared to templates in C++"_. Second, every target's distinguishing features are
exposed, and a capability system ([`05-capabilities.md`][ug-caps]) makes the type checker responsible
for proving that code only uses what a chosen target offers. Slang is a sibling of [HLSL][hlsl] (whose
syntax it inherits), compiles DXIL through [DXC][dxc], and occupies the space that the single-source
peers in [the umbrella][index] approach from general-purpose host languages.

---

## How it works

The compiler is a classical front end over a custom SSA IR
([`docs/design/overview.md`][design-overview]): lexing and preprocessing, a recursive-descent parser
whose keywords are ordinary declarations bound in the core module, semantic checking that
_"is \*not\* allowed to depend on the compilation target(s)"_, lowering to Slang IR, then IR passes and a
per-target emitter. Generic specialization ([`slang-ir-specialize.cpp`][ir-specialize]), dynamic
dispatch lowering ([`slang-ir-lower-dynamic-dispatch-insts.cpp`][ir-dyn]), autodiff
([`slang-ir-autodiff-rev.cpp`][ir-ad-rev] and siblings) and uniformity analysis
([`slang-ir-uniformity.cpp`][ir-uniformity]) are all IR passes. SPIR-V is emitted directly
([`slang-emit-spirv.cpp`][emit-spirv]; `-emit-spirv-directly` is the default per
[`a2-01-spirv-target-specific.md`][ug-spirv]); textual targets are emitted as source and handed to a
"downstream" compiler (DXC, fxc, glslang, NVRTC, Metal, Tint, Clang/LLVM) from
[`source/compiler-core/`][compiler-core].

The standard library is written in Slang itself. A typical intrinsic is one generic function whose body
is a `__target_switch` over targets, using text templates for source targets and inline SPIR-V for the
binary one ([`hlsl.meta.slang`][hlsl-meta]):

```cpp
// source/slang/hlsl.meta.slang — fwidth_fine
__generic<T : __BuiltinFloatingPointType>
[__readNone]
[require(glsl_hlsl_spirv, fragmentprocessing_derivativecontrol)]
T fwidth_fine(T p)
{
    __requireComputeDerivative();
    __target_switch
    {
    case hlsl:
        __intrinsic_asm "abs(ddx_fine($0)) + abs(ddy_fine($0))";
    case glsl:
        __intrinsic_asm "fwidthFine($0)";
    case spirv:
        return spirv_asm
        {
            OpCapability DerivativeControl;
            OpFwidthFine $$T result $p;
        };
    }
}
```

The `[require(...)]` line is the function's capability contract; the cases are its per-target
implementations; the capability checker verifies the two agree. This is the single pattern that the
entire 36k-line library repeats.

### Automatic differentiation

A function marked `[Differentiable]` can be passed to the higher-order operators `fwd_diff`
(Jacobian-vector product) and `bwd_diff` (vector-Jacobian product); differentiable values travel as
`DifferentialPair<T>` (`.p` primal, `.d` derivative), and `bwd_diff` takes the output derivative as an
extra last argument ([`07-autodiff.md`][ug-autodiff]):

```cpp
// docs/user-guide/07-autodiff.md
[Differentiable]
float2 foo(float a, float b) { return float2(a * b * b, a * a); }

DifferentialPair<float> dp_a = diffPair(1.0);   // derivative part starts at 0
DifferentialPair<float> dp_b = diffPair(2.4);
bwd_diff(foo)(dp_a, dp_b, float2(1.0, 0.0));     // writes dL/da into dp_a.d, dL/db into dp_b.d
```

Types opt in through `IDifferentiable` (associated type `Differential`, conformance synthesised for
structs) or the experimental `IDifferentiablePtrType`; parameters, return values and fields opt out
with `no_diff`. Users override generated derivatives with `[ForwardDerivative(f)]` /
`[BackwardDerivative(f)]`, or attach them from another module with `[ForwardDerivativeOf(g)]` /
`[BackwardDerivativeOf(g)]` and `[PrimalSubstituteOf(g)]`. Forward mode nests
(`fwd_diff(fwd_diff(sin))`); a single `bwd_diff` may wrap `fwd_diff`. The transform is a pipeline of
IR passes — CFG normalisation, forward, unzip, transpose, primal hoisting (checkpoint vs. recompute),
loop analysis — in `slang-ir-autodiff-*.cpp` ([`slang-ir-autodiff-rev.cpp`][ir-ad-rev] is the
reverse-mode driver), operating after generics and interfaces have been checked.

---

## Execution model and stages

Slang supports the three pipelines described in [`09-targets.md`][ug-targets]: rasterization
(`vertex`, `hull`, `domain`, `geometry`, `fragment`, plus `mesh`/`amplification`), `compute`, and ray
tracing (`raygeneration`, `intersection`, `anyhit`, `closesthit`, `miss`, `callable`). Entry points use
HLSL's `[shader("compute")]` and `[numthreads(...)]` attributes and HLSL semantics; generic value
parameters may appear in attributes, so `[numthreads(blockSize, blockSize, 1)]` on
`computeMain<int blockSize>()` lets the host choose the workgroup size by specialization instead of a
macro ([`06-interfaces-generics.md`][ug-generics]).

Stage is a capability atom (the capdef's `abstract stage;` "keyhole",
[`slang-capabilities.capdef`][capdef]). Stage-specific operations are therefore type errors outside
their stage: the capabilities chapter's example is that `discard`, or any function calling one, is a
type-check error in a vertex shader ([`05-capabilities.md`][ug-caps]).

> [!WARNING]
> [`09-targets.md`][ug-targets] still says _"The Slang system does not currently support mesh shaders"_,
> while the stdlib implements `SetMeshOutputCounts` for HLSL, GLSL, Metal and SPIR-V (the SPIR-V case
> emits `OpCapability MeshShadingEXT` / `SPV_EXT_mesh_shader`) and the capdef defines
> `alias meshshading`. The prose is stale; the stdlib and capdef are authoritative.

## Type system and generic programming

**Interfaces** declare methods, properties, `static` methods and constants, `__init` initializers,
`__subscript`s, generic methods, the `This` type, and default implementations that a conformer
overrides with an explicit `override`. A `struct` declares conformance with `: IFoo`; a missing member
is a compile error at the conformance, not at a later use ([`06-interfaces-generics.md`][ug-generics]).

**Generics** take type parameters constrained by `where` clauses or the inline `<T : IFoo>` form, and
value parameters of `int`, `uint`, `bool` or enum type (`<let N : int>`). The body is type-checked
against the constraint before any instantiation:

```cpp
// docs/user-guide/06-interfaces-generics.md
interface IFloatContainer
{
    associatedtype Iterator : IIterator;   // implementation-chosen type
    Iterator begin();
    Iterator end();
    float getElementAt(Iterator iter);
};

float sum<T : IFloatContainer>(T container)  // checked once, against IFloatContainer
{
    float result = 0.0f;
    for (T.Iterator it = container.begin(); it != container.end(); it = it.next())
        result += container.getElementAt(it);
    return result;
}
```

The rest of the generic toolkit, all in the same chapter: **associated types** (Swift `associatedtype`,
Rust trait `type`), **type-equality constraints** (`where T.A == int`), **optional conformances**
(`where optional T : IFoo` plus `if (T is IFoo)`), **generic interfaces** (`IEnumerable<T>`),
**variadic generics** (`each T` / `expand`), and **extensions**:

- `extension MyObject : IBar { … }` adds a conformance retroactively.
- `extension<T : IFoo> MyType<T> : IBar` is a generic extension.
- `extension<T : IFoo> T { int bar(); }` extends every conformer of an interface, _"similar to
  extension traits in Rust"_; a type's own conformance wins over a blanket one.

**Interface-typed values** (existentials). A parameter of type `ITransform` is sugar for a generic, and
compiles to the same code. When the concrete type cannot be determined statically — an interface-typed
return value or `out` parameter whose type depends on runtime data — the compiler _"will generate code
that performs a dynamic dispatch based on the concrete type of the value at runtime"_. Restrictions: no
opaque (resource) fields in a dynamically dispatched type, no reassignment of a mutable interface
variable to a different concrete type, and `is` / `as` (returning `Optional<T>`) for downcasts. At the
IR level the value is packed into a fixed-size `AnyValue` slot plus a type tag
([`slang-ir-lower-dynamic-dispatch-insts.cpp`][ir-dyn]); interfaces may cap the slot with
`[anyValueSize(N)]` ([`stdlib-intrinsics.md`][design-stdlib]).

**`dyn` (language 2026).** Version 2026 requires an explicit opt-in: _"Users must explicitly opt in to
enable dynamic dispatch with the `dyn` keyword"_ ([`11-language-version.md`][ug-langver]). The checker's
characterization test ([`dyn-interface-conformance-restrictions.slang`][dyn-test]) pins the rules: a
conformer of a `dyn interface` may not hold an opaque member (E33080) or an unsized array (E33079), may
not be generic (E33082), and may not gain the conformance through an `extension` (E33078) — the dynamic
representation is _"a copyable, fixed-size box"_.

Conventional additions ([`03-convenience-features.md`][ug-conv]): `let`/`var`, properties, operator
overloading including `operator()`, tuples, `Optional<T>` with `if (let x = …)`, `Conditional<T, bool>`
(a field compiled away when false), `reinterpret<T>`, limited pointers, non-capturing lambdas coercible
to `IFunc`/`functype`. Struct inheritance is removed in language 2026 in favour of composition.

## Resources, interfaces and memory layout

Slang inherits HLSL's resource types (`Texture2D`, `RWStructuredBuffer<T>`, `ByteAddressBuffer`,
`ConstantBuffer<T>`, `SamplerState`, …) and adds three abstractions.

- **`ParameterBlock<T>`** — a struct of uniforms and resources bound as one unit. On SPIR-V it
  _"introduces a new descriptor set ID for resource/sampler handles defined in the element type `T`"_;
  without nested blocks it maps to one descriptor set with bindings from 0, and ordinary data fields are
  grouped into a uniform buffer at binding 0 of that set ([`a2-01-spirv-target-specific.md`][ug-spirv]).
  The same declaration becomes a D3D12 descriptor table, a Metal argument buffer, or a WebGPU bind group.
- **Per-buffer layout as a type argument** — `ConstantBuffer<T, Std430DataLayout>`,
  `StructuredBuffer<T, ScalarDataLayout>`, `CDataLayout`; global equivalents `-fvk-use-scalar-layout`,
  `-fvk-use-dx-layout`, `-fvk-use-c-layout`. Push constants default to std430; entry-point `uniform`
  parameters of ordinary type become push constants (same file).
- **`DescriptorHandle<T>`** — a portable bindless handle (`Texture2D.Handle`), a `uint2` index into the
  descriptor heap on HLSL/GLSL/SPIR-V and the native handle where resources are not opaque (Metal, CUDA)
  ([`03-convenience-features.md`][ug-conv]). `ResourceDescriptorHeap[i]` is accepted for SM 6.6
  compatibility.

**Pointers** (`T*`, `Ptr<T, Access, AddressSpace>`) exist on SPIR-V, C++ and CUDA only. On SPIR-V they
become `PhysicalStorageBuffer` pointers, and any module using one switches to the
`PhysicalStorageBuffer64` addressing model; modules without pointers stay `Logical`. Pointers to locals
and to opaque handles are rejected ([`a2-01-spirv-target-specific.md`][ug-spirv],
[`03-convenience-features.md`][ug-conv]).

**Legalization.** Slang lets a struct hold resources and lets functions return them (when statically
resolvable); for SPIR-V it hoists those fields to globals, wraps scalar buffer elements in a block
struct, and converts array returns to `out` parameters (same SPIR-V chapter).

**Matrices.** A Slang `float3x4` becomes `OpTypeMatrix` of three `float4` — rows become SPIR-V columns —
and `mul(a, b)` is emitted as `transpose(mul(transpose(b), transpose(a)))`, matching DXC's convention.
Slang's default memory layout is row-major, DXC's column-major ([`a2-01-spirv-target-specific.md`][ug-spirv]).

**Reflection.** `slang::ProgramLayout`, obtained from any `IComponentType` via `getLayout(targetIndex)`,
separates _types_ from _layouts_ because _"the same type may be laid out differently, depending on how
it is used"_ ([`09-reflection.md`][ug-reflection]). Reflection is available only through the API, not
from `slangc`.

## Built-in library and intrinsics

The stdlib ([`hlsl.meta.slang`][hlsl-meta], [`core.meta.slang`][core-meta],
[`glsl.meta.slang`][glsl-meta] for GLSL source compatibility, [`diff.meta.slang`][diff-meta] for
autodiff) covers HLSL's intrinsic set through SM 6.x — wave and quad ops, derivatives, sampling,
atomics, ray tracing incl. `HitObject` (SER), mesh output, cooperative vectors/matrices — each
implemented per target behind `__target_switch`. Three escape hatches back it, all documented in
[`a1-04-interop.md`][ug-interop] and all declared _"internal compiler features"_ without comprehensive
checks:

- `__intrinsic_asm "…$0…"` — a text template for source targets.
- `__require_prelude` — inject text into the generated source.
- `spirv_asm { … }` — inline SPIR-V. `$x` anti-quotes a Slang value, `$$T` a Slang type, `&x` passes an
  l-value as a pointer, and the block's value is the final `result:` instruction:

```cpp
// docs/user-guide/a1-04-interop.md
float modf(float x, out float ip)
{
    return spirv_asm
    {
        result:$$float = OpExtInst glsl450 Modf $x &ip
    };
}
```

Built-ins also carry their target cost. `WaveGetLaneIndex` is declared
`[require(cuda_glsl_hlsl_metal_spirv_wgsl, subgroup_basic)]` and its SPIR-V case loads
`builtin(SubgroupLocalInvocationId:uint)` under `OpCapability GroupNonUniform` — `cpp` is absent from the
requirement, so calling it from code compiled for the CPU is a capability error, not a silent stub.

## Control flow, memory model and restrictions

**Capabilities.** A requirement is a disjunction of conjunctions of atoms (`spirv_1_5`, `_sm_6_7`,
`SPV_KHR_ray_tracing`, `fragment`, …), defined in [`slang-capabilities.capdef`][capdef] — 2,805 lines,
_"the single source of truth for all capabilities"_. Atoms imply others (`spvShaderClockKHR` implies
`SPV_KHR_shader_clock` implies `spirv_1_0`); `target` and `stage` are mutually exclusive "keyholes". Rules
([`05-capabilities.md`][ug-caps]):

- internal/private functions get requirements **inferred** from their bodies; a `__target_switch`
  contributes a disjunction of its cases;
- `public` and interface methods must **declare** requirements, and their bodies are verified against
  the declaration;
- a conformer's capabilities must be a subset of the interface's; an extension's must intersect its
  target type's (E36100);
- entry points are inferred unless annotated, and fail only when the inferred set is incompatible with
  the chosen target.

**Uniformity analysis** is opt-in (`-validate-uniformity`) and driven by a `dynamic_uniform` modifier on
parameters, fields and locals; it warns when a non-uniform value reaches one, and treats a struct as
non-uniform if any member is ([`a1-05-uniformity.md`][ug-uniformity]).

**Autodiff restrictions** ([`07-autodiff.md`][ug-autodiff]): global resources, shader parameters,
texture reads and atomics are non-differentiable; side effects in differentiable code may repeat an
unspecified number of times; loops must be bounded, statically or by `[MaxIters(n)]`
(undefined behaviour if exceeded) or removed with `[ForceUnroll]`; and a function that calls `bwd_diff`
cannot itself be differentiated.

**Other rules.** Dynamically dispatched types may not hold resources; pointers cannot address locals;
202c makes a missing `return` in a non-void function an error everywhere (it already is for SPIR-V,
GLSL and WGSL). The SPIR-V chapter's memory-model section governs coherence; it was not read in depth.

## Compilation pipeline and targets

Slang compiles in three steps ([`10-link-time-specialization.md`][ug-link]): **precompile** each module
to serialized IR (`.slang-module`), **link** modules and entry points into a composite
`IComponentType`, then **generate** target code. Specialization happens at link time:

```cpp
// docs/user-guide/10-link-time-specialization.md
// main.slang — compiled once, offline
extern static const int kSampleCount;            // value supplied at link time
extern struct Sampler : ISampler;                // type supplied at link time

// sampler.slang — one tiny module per variant
export struct Sampler : ISampler = FooSampler;
export static const int kSampleCount = 2;
```

`extern` declarations may carry defaults; `ISession::isBinaryModuleUpToDate` and
`UseUpToDateBinaryModule` reuse precompiled modules when sources and options match. The chapter's
rationale: preprocessor specialization redoes _"parsing, type checking, IR generation and optimization,
even when two specialized variants only differ in one constant value"_.

**Targets** ([`09-targets.md`][ug-targets], [`slang-capabilities.capdef`][capdef], whose `target`
keyhole lists `hlsl`, `glsl`, `c`, `cpp`, `cuda`, `metal`, `spirv`, `wgsl`, `slangvm`, `llvm`):

| Target         | Path                                                       | Stated status                                             |
| -------------- | ---------------------------------------------------------- | --------------------------------------------------------- |
| SPIR-V         | direct emitter; `-emit-spirv-via-glsl` routes via glslang  | primary                                                   |
| DXIL / DXBC    | HLSL source → DXC / fxc                                    | D3D12 / D3D11                                             |
| GLSL, HLSL     | source emitters                                            | GLSL source compatibility via `glsl.meta.slang`           |
| Metal          | MSL source → Metal compiler                                | _"a work in progress"_; ray tracing also WIP              |
| WGSL           | source emitter ([`slang-emit-wgsl.cpp`][emit-wgsl]) → Tint | WebGPU                                                    |
| CUDA / OptiX   | CUDA C++ → NVRTC / PTX                                     | compute + OptiX ray tracing; no rasterization             |
| C++ / CPU      | C++ source → Clang/GCC/MSVC or bundled `slang-llvm`        | _"preliminary support"_ ([`cpu-target.md`][cpu-target])   |
| LLVM IR/object | [`slang-emit-llvm.cpp`][emit-llvm]                         | _"highly experimental"_ ([`llvm-target.md`][llvm-target]) |

**Language editions** ([`11-language-version.md`][ug-langver]), selected by `#language slang 2026` or
`-std`: `legacy` (2018, all declarations public, no `module` required, the default); `2025`
(internal-by-default, mandatory `module`, `$for` deprecated); `2026` (`(a, b)` is a tuple, `dyn` required
for dynamic dispatch, `volatile` removed, no struct inheritance, no default-initialized interface
variables); `202c` in development (`(S)0` loses its meaning, `$for` removed, return-or-throw enforced,
a generic-parameter-count overload tie-breaker removed).

## Host integration and CPU execution

Slang's host story is a **compiler API**, not a host language: `ISession`, `IModule`,
`IComponentType`, `createCompositeComponentType`, `link`, `getEntryPointCode`, and the reflection
objects. The introduction scopes the project explicitly — _"It is not an engine, not a renderer, and not
a "framework."_ — so binding resources from the host is the application's job, guided by reflection.

CPU execution exists in two forms, both labelled immature by their own docs:

- **C++ target** ([`cpu-target.md`][cpu-target]): Slang is transpiled to C++ and compiled by a
  downstream C++ compiler or the bundled `slang-llvm` JIT (`host-callable`). Two styles, `host` and
  `shader`; shader-style entry points get an ABI struct of uniforms and resources. Limitations, verbatim:
  _"Barriers are not supported (making these work would require an ABI change)"_; user atomics are not
  supported; `float16_t` is not supported; entry points may not be named `main`.
- **LLVM target** ([`llvm-target.md`][llvm-target]): direct LLVM IR / object code for arbitrary triples.
  No `groupshared`, barriers, atomics or wave operations, because _"threads of a work group are
  currently run serially instead of actually being in parallel"_; no textures, samplers or acceleration
  structures; vectorization is _"the way typical CPU math libraries (e.g. GLM) vectorize"_, which the
  doc calls _"worse than how GPUs do it, where each work item / thread gets a SIMD lane"_. And: _"The
  emitted LLVM IR is not compatible with LLVMs SPIR-V target"_.

So Slang has no CPU simulator of the GPU execution model: cross-lane operations, barriers and derivatives
have no CPU semantics, and CPU and GPU code are produced by different emitters from the same IR.

---

## Lessons for sparkles:shaders

- **Adopt: one generic function per intrinsic, one case per target.** Slang's `__target_switch` +
  `spirv_asm` stdlib pattern maps onto D's `version (LDC_DCompute)` device switch (decision `D4` in
  [`decisions.md`][spec-decisions]) plus `static if` on a target enum: each vocabulary function in
  `libs/shaders/src/sparkles/shaders/math.d` should have one CPU body and one device body, and nothing
  else. Slang's 1,114 switches show the pattern scales to the full HLSL surface.
- **Adopt: capabilities as checked data, not comments.** Give every device intrinsic a capability UDA
  (`@requires(Cap.subgroupBasic, Cap.fragment)`) drawn from one table generated like
  [`slang-capabilities.capdef`][capdef], and `static assert` at each entry point that the transitive set
  fits the target profile. D lacks call-graph reflection, so check at the intrinsic wrapper (each wrapper
  asserts against the entry point's declared profile) rather than inferring bottom-up.
- **Match: declaration-site checking for generic shader code.** Slang's chief ergonomic win over HLSL is
  that `sum<T : IFloatContainer>` is checked once. D templates check at instantiation; provide a
  `conforms!(Interface, T)` trait (member-by-member signature diff by CTFE) and require it in every
  vocabulary template constraint, with a test per interface that a deliberately wrong type is rejected
  with a readable message.
- **Match: existentials as a closed, fixed-size tagged union.** Slang lowers dynamic dispatch to an
  `AnyValue` box plus a tag, and the 2026 `dyn` rules forbid opaque, unsized and generic conformers.
  A D `Existential!(I, Impls...)` over `SumType` with a CTFE-generated `final switch` is the same
  lowering, and should inherit the same three restrictions as compile errors.
- **Adopt: layout as a type argument.** `StructuredBuffer<T, Std430DataLayout>` makes the layout rule
  part of the type; a D `Buffer!(T, Layout.std430)` whose offsets are computed by CTFE and
  `static assert`ed on both host and device is strictly better than a global `-fvk-use-*` flag, and is
  the obvious generalization of decision `D9`'s host-laid-out `vec3`.
- **Avoid: a CPU target without GPU semantics.** Slang's C++ and LLVM targets run workgroup threads
  serially with no barriers, atomics or wave ops. sparkles' CPU simulator is a stated goal precisely
  because the D12 agreement contract needs CPU answers for cross-lane and derivative operations; test it
  against Slang's gap by making wave, barrier and `ddx` conformance cases mandatory in the corpus.
- **Avoid: specialization only through recompilation, where spec constants suffice.** Slang's link-time
  constants are its answer to variant explosion; the SPIR-V equivalent available to D is
  `OpSpecConstant` (`@specConstant(id)`), which keeps one SPIR-V module per shader rather than one per
  variant. Template parameters remain the tool for type-level variants.
- **Adopt: language editions with a written delta.** Slang's `#language` table lists each breaking change
  with an issue link; the sparkles vocabulary should version its semantics the same way (one document,
  one row per change) before it outgrows GLSL parity.

## Strengths

- Generics checked at declaration with associated types, extensions and variadics — the most complete
  generic system of any production shading language.
- Late specialization over precompiled IR modules removes front-end cost per variant.
- One stdlib source of truth for intrinsics across ten targets, with inline SPIR-V for the binary target.
- Capability system catches target/stage misuse at type-check time, with inference for internal code.
- Automatic differentiation (forward, reverse, custom derivatives, higher-order forward) built into the
  compiler as IR passes.
- `ParameterBlock<T>`, per-buffer layout types and `DescriptorHandle<T>` give one cross-API binding model.
- HLSL source compatibility gives incremental adoption.

## Weaknesses

- The CPU targets are preliminary/experimental, with no barriers, atomics, wave ops or textures — no
  usable CPU reference for GPU semantics.
- Dynamic dispatch is restricted (no resources, no generic or extension conformers under `dyn`) and its
  cost is easy to trigger accidentally, hence the 2026 opt-in.
- Rapid churn: four language editions, breaking syntax changes, and user-guide prose that lags the
  implementation (the mesh-shader note in `09-targets.md`).
- Escape hatches (`__intrinsic_asm`, `spirv_asm`) are unchecked internal features.
- Reflection requires the C++ API; a build pipeline cannot get it from `slangc`.
- Autodiff cannot differentiate through resources, side effects or unbounded loops without user help.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                              | Trade-off                                                                       |
| ----------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Checked generics instead of C++ templates             | Early, readable errors; reuse of checked IR across instantiations      | Every use must be expressed through an interface; no duck typing                |
| Interface-typed values with fallback dynamic dispatch | Concise code; runtime polymorphism where types are data-dependent      | Hidden dispatch cost; `AnyValue` size bounds; `dyn` opt-in added in 2026        |
| Own IR + direct SPIR-V emitter                        | Full control of SPIR-V; no dependency on LLVM or glslang for Vulkan    | A large compiler to maintain; LLVM's SPIR-V backend is not used                 |
| Textual targets via downstream compilers              | Reuse DXC, fxc, NVRTC, Metal, Tint for their signed/opaque formats     | Output quality bounded by source-level translation and each tool's quirks       |
| Capabilities as a lattice in one `.capdef` file       | Target/stage misuse is a type error; docs generated from the same file | 2,805 lines of atoms to maintain; public APIs must annotate                     |
| Precompile → link → codegen with `extern`/`export`    | Specialization after the front end; distributable binary modules       | Requires the Slang API at runtime or build time; version checking of IR modules |
| Autodiff as compiler IR transforms                    | Differentiates arbitrary control flow, generics and interfaces         | Non-differentiable resources; bounded loops; no double backward                 |
| Language editions (`#language`)                       | Breaking cleanups without breaking legacy HLSL code                    | Four dialects in flight; behaviour depends on a directive                       |

---

## Sources

- [shader-slang/slang at `60a7c8c88c8d`][repo]
- [`docs/user-guide/00-introduction.md` — goals and non-goals][ug-intro]
- [`docs/user-guide/03-convenience-features.md` — pointers, `DescriptorHandle`, tuples, `Optional`][ug-conv]
- [`docs/user-guide/05-capabilities.md` — capability atoms, inference, `__target_switch`][ug-caps]
- [`docs/user-guide/06-interfaces-generics.md` — interfaces, associated types, extensions, existentials][ug-generics]
- [`docs/user-guide/07-autodiff.md` — `fwd_diff`, `bwd_diff`, restrictions][ug-autodiff]
- [`docs/user-guide/09-reflection.md` — reflection API][ug-reflection]
- [`docs/user-guide/09-targets.md` — pipelines, stages, targets][ug-targets]
- [`docs/user-guide/10-link-time-specialization.md` — precompiled modules, `extern`/`export`][ug-link]
- [`docs/user-guide/11-language-version.md` — language editions][ug-langver]
- [`docs/user-guide/a1-04-interop.md` — `__intrinsic_asm`, `__target_switch`, `spirv_asm`][ug-interop]
- [`docs/user-guide/a1-05-uniformity.md` — uniformity analysis][ug-uniformity]
- [`docs/user-guide/a2-01-spirv-target-specific.md` — SPIR-V mapping, `ParameterBlock`, pointers, matrices][ug-spirv]
- [`docs/cpu-target.md`][cpu-target] · [`docs/llvm-target.md`][llvm-target] — CPU targets and their limits
- [`docs/design/overview.md` — compiler architecture][design-overview] · [`docs/design/stdlib-intrinsics.md`][design-stdlib]
- [`source/slang/slang-capabilities.capdef`][capdef] · [`source/slang/hlsl.meta.slang`][hlsl-meta] · [`core.meta.slang`][core-meta] · [`glsl.meta.slang`][glsl-meta] · [`diff.meta.slang`][diff-meta]
- [`slang-emit-spirv.cpp`][emit-spirv] · [`slang-emit-wgsl.cpp`][emit-wgsl] · [`slang-emit-llvm.cpp`][emit-llvm] · [`source/compiler-core/`][compiler-core]
- [`slang-ir-specialize.cpp`][ir-specialize] · [`slang-ir-lower-dynamic-dispatch-insts.cpp`][ir-dyn] · [`slang-ir-autodiff-rev.cpp`][ir-ad-rev] · [`slang-ir-uniformity.cpp`][ir-uniformity]
- [`dyn-interface-conformance-restrictions.slang` — `dyn` conformance diagnostics][dyn-test]
- [Slang user guide (web)][ug-web]
- Related: [HLSL][hlsl] · [DXC][dxc] · [GLSL][glsl] · [WGSL][wgsl] · [MSL][msl] · [SPIRV-Cross][spirv-cross] · [Concepts][concepts] · [Comparison][comparison] · [`sparkles:shaders` SPEC][spec] · [decisions][spec-decisions]

<!-- References -->

[repo]: https://github.com/shader-slang/slang/tree/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223
[license]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/LICENSE
[ug-web]: https://shader-slang.org/slang/user-guide/
[ug-intro]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/00-introduction.md
[ug-conv]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/03-convenience-features.md
[ug-caps]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/05-capabilities.md
[ug-generics]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/06-interfaces-generics.md
[ug-autodiff]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/07-autodiff.md
[ug-reflection]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/09-reflection.md
[ug-targets]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/09-targets.md
[ug-link]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/10-link-time-specialization.md
[ug-langver]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/11-language-version.md
[ug-interop]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/a1-04-interop.md
[ug-uniformity]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/a1-05-uniformity.md
[ug-spirv]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/user-guide/a2-01-spirv-target-specific.md
[cpu-target]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/cpu-target.md
[llvm-target]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/llvm-target.md
[design-overview]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/design/overview.md
[design-stdlib]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/design/stdlib-intrinsics.md
[capdef]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-capabilities.capdef
[hlsl-meta]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/hlsl.meta.slang
[core-meta]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/core.meta.slang
[glsl-meta]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/glsl.meta.slang
[diff-meta]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/diff.meta.slang
[emit-spirv]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-emit-spirv.cpp
[emit-wgsl]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-emit-wgsl.cpp
[emit-llvm]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-emit-llvm.cpp
[compiler-core]: https://github.com/shader-slang/slang/tree/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/compiler-core
[ir-specialize]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-ir-specialize.cpp
[ir-dyn]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-ir-lower-dynamic-dispatch-insts.cpp
[ir-ad-rev]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-ir-autodiff-rev.cpp
[ir-uniformity]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/source/slang/slang-ir-uniformity.cpp
[dyn-test]: https://github.com/shader-slang/slang/blob/60a7c8c88c8dd503087ad9fa6c3a5620ec28d223/docs/generated/tests/coverage/check-decl/dyn-interface-conformance-restrictions.slang
[hlsl]: ./hlsl.md
[dxc]: ./dxc.md
[glsl]: ./glsl.md
[wgsl]: ./wgsl.md
[msl]: ./msl.md
[spirv-cross]: ./spirv-cross.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[spec]: ../../specs/shaders/SPEC.md
[spec-decisions]: ../../specs/shaders/decisions.md
