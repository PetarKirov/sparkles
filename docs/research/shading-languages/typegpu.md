# TypeGPU (TypeScript → WGSL)

A WebGPU toolkit from Software Mansion in which buffer layouts, bind groups and
shader functions are TypeScript values: schemas derive the WGSL memory layout
and the byte-level serializers, and a function marked `'use gpu'` is both a
plain JavaScript function and the source of generated WGSL.

| Field          | Value                                                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | TypeScript / JavaScript (host and shader), WGSL (generated, or hand-written in template strings)                                                               |
| License        | MIT (`license` field of [`packages/typegpu/package.json`][pkg])                                                                                                |
| Repository     | [software-mansion/TypeGPU][repo]                                                                                                                               |
| Documentation  | [docs.swmansion.com/TypeGPU][docs]                                                                                                                             |
| Category       | Single-source peer: embedded DSL with a build-time AST capture and a runtime code generator                                                                    |
| Latest version | `typegpu` 0.12.8, tag `v0.12.8` = pinned commit `3e1efd44`, 2026-10-16 ([`package.json`][pkg]); 0.12 announced 2026-08-12 ([release post][blog012])            |
| Targets        | WGSL for WebGPU (browsers, Dawn/wgpu-backed runtimes, React Native); GLSL ES 3.00 for WebGL 2 through the experimental `@typegpu/gl` package ([docs][gl-docs]) |
| Build plugin   | [`unplugin-typegpu`][unplugin] (Vite, webpack, Rollup, Rolldown, esbuild, Rspack, Farm, Bun, Babel)                                                            |
| Pinned source  | `software-mansion/TypeGPU` at `3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf`                                                                                       |

## Overview

### What it solves

WebGPU programs share data with WGSL through raw bytes, and every struct must
be padded to WGSL's alignment rules on both sides. TypeGPU's answer is to make
the _schema_ the single source of truth. The data-schema guide states the
problem directly ([`apis/data-schemas.mdx`][doc-schemas]):

> "Any misalignments or misinterpretations of data can lead to faulty code
> that is difficult to debug. This is precisely what TypeGPU data schemas,
> like `d.u32` or `d.vec3f`, help with."

The same schema object types a buffer (`root.createBuffer(Schema)`), types a
bind-group entry (`{ uniform: Schema }`), constructs host values
(`Schema({ … })`), and resolves to a WGSL `struct`. On top of that, shader
functions are written in TypeScript and can be called on the CPU, emitted as
WGSL, or dispatched on the GPU from the same definition.

### Design philosophy

Three commitments recur through the source and docs:

1. **Mirror WGSL, do not abstract over it.** The README says _"The low-level
   nature of TypeGPU and it's mirroring of WGSL (WebGPU Shading Language)
   syntax in TypeScript means that learning TypeGPU helps to learn WebGPU
   itself"_, and that one can _"granularly eject into vanilla WebGPU at any
   point"_ ([`README.md`][readme]). Every abstraction has a WGSL escape hatch.
2. **Shaders written in JavaScript, not arbitrary JavaScript on the GPU.** The
   functions guide: _"Our aim with TypeGPU functions is not to allow arbitrary
   JavaScript to be supported in the context of shaders, **rather to allow for
   shaders to be written in JavaScript**"_ ([`apis/functions/index.mdx`][doc-fn]).
3. **CPU/GPU behavioural parity is a goal of the standard library.** _"Our goal
   is for all functions to have matching behavior on the CPU and GPU, which
   unlocks many possibilities (shader unit testing, shared business logic, and
   more...)"_ ([`apis/functions/index.mdx`][doc-fn]).

TypeScript types take no part in code generation: _"TypeScript's types take no
part in WGSL generation. TypeGPU works just as well in plain JavaScript"_
([`advanced/explaining-the-magic.mdx`][doc-magic]). WGSL types are inferred by
the generator from the runtime values and schemas at each call site.

## How it works

The pipeline has two halves, split between build time and run time.

**Build time — `unplugin-typegpu`.** The plugin walks each bundled file and
rewrites three things ([`explaining-the-magic.mdx`][doc-magic]):

- _auto-naming_: `const counter = root.createMutable(d.vec2u)` is wrapped in
  `globalThis.__TYPEGPU_AUTONAME__(…, "counter")`, so generated identifiers
  follow source names;
- _function metadata_: every function whose body starts with `'use gpu'` (or
  that is passed directly to a `tgpu.fn` shell) is parsed by
  [`tinyest-for-wgsl`][tinyest-wgsl] into a compact array-encoded AST, the
  [`tinyest`][tinyest-nodes] format, and attached to the function object in a
  `globalThis.__TYPEGPU_META__` `WeakMap` together with an `externals` record of
  thunks for every captured outer-scope name;
- _operator overloading_: `+`, `*`, … inside `'use gpu'` bodies become
  `__tsover_add`-style calls so that vector arithmetic also works when the
  function runs as JavaScript. The AST keeps the original operators.

The doc shows the injected shape:

```ts
// unplugin output (abridged), explaining-the-magic.mdx
(($.f = () => {
  'use gpu';
  counter.$ = __tsover_add(counter.$, incrementBy.allModifier.$);
}),
  {
    v: 2,
    ast: {
      params: [],
      body: [
        0,
        [[2, [7, 'counter', '$'], '+=', [7, 'incrementBy.allModifier', '$']]],
      ],
    },
    externals: {
      counter: () => counter,
      'incrementBy.allModifier': () => incrementBy.allModifier,
    },
  });
```

`tinyest` encodes nodes as tuples tagged by small integers from
`NodeTypeCatalog` (`block: 0`, `binaryExpr: 1`, … `forOf: 18`, `switch: 19`;
[`nodes.ts`][tinyest-nodes]). The externals are thunks, not values, because a
resource may be reassigned after the function is defined and because a
resource's `.$` getter returns a different object while resolving.

**Run time — resolution.** `tgpu.resolve([items])` is described as
_"essentially a dedicated TypeGPU linker"_ ([`apis/resolve.mdx`][doc-resolve]).
A `ResolutionCtxImpl` ([`resolutionCtx.ts`][resctx]) walks the item graph:
each resolvable object implements a `$resolve` symbol, functions are emitted by
the `WgslGenerator` ([`wgslGenerator.ts`][wgslgen]) walking the `tinyest` AST,
and every external the generator touches pulls its own definition (struct,
`@group/@binding` variable, helper `fn`) into the output exactly once. A
`Namespace` ([`namespace.ts`][namespace]) owns the global identifier set
(pre-seeded with WGSL keywords, builtins and template enumerants), memoizes
resolutions per slot-binding map, and offers `'strict'` or `'random'` naming.

## Execution model and stages

Entry points are built by dedicated shell constructors rather than attributes:
`tgpu.computeFn({ workgroupSize, in })`, `tgpu.vertexFn({ in, out })` and
`tgpu.fragmentFn({ in, out })` ([`tgpu.ts`][tgpu-barrel];
[`tgpuComputeFn.ts`][computefn], [`tgpuVertexFn.ts`][vertexfn],
[`tgpuFragmentFn.ts`][fragmentfn]). Stage I/O is an `IORecord` — a plain
object mapping names to schemas or to `d.builtin.*` markers — from which the
generator synthesizes the `…_Input`/`…_Output` structs, assigns `@location`
indices automatically (overridable with `d.location`) and, for shell-less
render pipelines, adds `@interpolate(flat)` to integer varyings. The builtin
set is WGSL's: compute IDs and subgroup IDs, `vertexIndex`/`instanceIndex`,
`position`, `frontFacing`, `sampleIndex`/`sampleMask`, `fragDepth`,
`clipDistances` ([`apis/functions/index.mdx`][doc-fn]).

The stage set is exactly WebGPU's: compute, vertex, fragment. There is no
geometry, tessellation, mesh or ray-tracing stage because WGSL has none.
`createGuardedComputePipeline(callback)` is a convenience that wraps a 0–3
argument callback in a compute entry with a fixed workgroup size and a bounds
check against a `vec3u` size uniform, so the user dispatches _threads_ rather
than workgroups ([`init.ts`][init]).

## Type system and generic programming

**Schemas are the type system.** `d.f32`, `d.i32`, `d.u32`, `d.f16`, `d.bool`,
`d.vec{2,3,4}{f,i,u,h,b}`, `d.mat2x2f`/`mat3x3f`/`mat4x4f`, `d.struct`,
`d.arrayOf`, `d.atomic`, pointer schemas and the texture/sampler schemas are
callable objects ([`data/`][data-dir]). Calling a scalar schema casts with WGSL
semantics on the CPU (`d.u32(-1)` is `4294967295`); calling a struct schema
builds a value; `d.Infer<typeof S>` yields the host TypeScript type. Matrices
are limited to the three square `f32` shapes, and `f16` matrices are not
supported ([`data-schemas.mdx`][doc-schemas]).

**Polymorphism by call-site specialization.** An unshelled `'use gpu'`
function is generic: the generator infers argument types at each call and
emits one WGSL function per distinct signature (`neighborhood`,
`neighborhood2`, …); return types that cannot be unified are an error
([`apis/functions/index.mdx`][doc-fn]; [`shellless.ts`][shellless]). A
`tgpu.fn([argSchemas], returnSchema)` _shell_ pins the signature instead.

**Numeric literal typing is a value heuristic.** Because JavaScript has one
`number`, integer-valued literals become `i32` and others `f32`
(`1.0` → `1i`); the docs ask users to wrap literals in schemas, and the
generator wraps every `/` in an `f32` cast so JS and GPU agree. The ESLint
plugin ships rules for exactly these hazards (`noIntegerDivision`, `noMath`,
`noUninitializedVariables`, [`eslint-plugin/src/rules/`][eslint-rules]).

**Compile-time generic programming is runtime JavaScript.** Four mechanisms
substitute for templates:

| Mechanism                           | What it is                                                                                                                                                       |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tgpu.slot<T>(default?)`            | A typed hole filled before shader compilation via `.with(slot, value)` on a function, root or pipeline; any JS value, even a function ([`slots.mdx`][doc-slots]) |
| `tgpu.accessor(schema)`             | A slot constrained to a schema, filled by any value _or resource_ of that type — buffer, variable, constant, function ([`accessors.mdx`][doc-accessors])         |
| `tgpu.lazy(() => …)`                | A value computed during resolution, memoized per slot-binding map; `derived` is its deprecated alias ([`lazy.ts`][lazy], [`tgpuUnstable.ts`][unstable])          |
| `tgpu.comptime(fn)` / `tgpu.unroll` | Run arbitrary JS at shader-generation time and inject the result; mark a `for…of` for unrolling ([`comptime.ts`][comptime], [`tgpuUnroll.ts`][unroll])           |

Captured outer-scope values are inlined as constants and constant-folded
(`std.mix(from, to, 0.5)` becomes `vec3f(0.5, 0.5, 0)`), and the docs warn
that such values _"are assumed to be constant"_: mutating them later does not
recompile the shader ([`apis/functions/index.mdx`][doc-fn]).

## Resources, interfaces and memory layout

**Layout derivation.** `alignmentOf` uses a fixed table for WGSL's built-in
types (`vec3f: 16`, `vec2h: 4`, `mat3x3f: 16`, `bool: 4`) and computes structs
as the maximum member alignment and arrays as the element alignment
([`alignmentOf.ts`][alignof]); `sizeOf`/`offsets` complete the picture, and
`d.align(n, T)` / `d.size(n, T)` mirror WGSL's `@align`/`@size` (padding
before, padding after). Structs are laid out once, by WGSL's storage rules.

**Uniform-buffer rules are warnings, not a second layout.** WGSL's uniform
address space adds 16-byte constraints on array strides and struct
alignment. TypeGPU checks them in `warnIfNotUniformAligned` and logs a
`uniform-schema-misaligned` warning that suggests the exact `d.align`/`d.size`
fix, citing the WGSL spec section ([`webgpuLimitations.ts`][limits]). It does
not silently re-layout the struct for uniforms.

**Packed vertex data.** `d.unstruct` and `d.disarray` describe _loose_ layouts
with no implicit padding — vertex formats such as `unorm8x4` — distinct from
WGSL-host-shareable structs ([`unstruct.ts`][unstruct]).

**Serialization.** `compiledIO.ts` JIT-compiles a per-schema writer
(`new Function(…)` over a `DataView`) and caches it in a `WeakMap`; where
`eval` is forbidden (`EVAL_ALLOWED_IN_ENV`), it falls back to an interpreted
writer with a one-time warning ([`compiledIO.ts`][compiledio]).

**Bindings.** `tgpu.bindGroupLayout({ name: { uniform: S } | { storage: S,
access } | { texture: d.texture2d(d.f32) } | { sampler } | … })` assigns
binding indices by property order; `root.createBindGroup(layout, {…})`
validates the resources against it ([`bind-groups.mdx`][doc-bind];
[`tgpuBindGroupLayout.ts`][bgl]). Alternatively, _fixed_ resources referenced
directly inside a shader (`root.createUniform`, `root.createMutable`,
`createReadonly`) are given automatic `@group/@binding` slots during
resolution, as the resolved pipelines in the docs show. `tgpu.privateVar` and
`tgpu.workgroupVar` declare module-scope `var<private>` / `var<workgroup>`
([`tgpuVariable.ts`][variable]).

## Built-in library and intrinsics

`typegpu/std` ([`std/`][std-dir]) covers WGSL's builtin functions: numeric
(`abs`, `mix`, `clamp`, `fma`, …), boolean and comparison (`eq`, `lt`, `all`,
`any`, `select`), matrix, packing, bitcast, texture (`textureSample`,
`textureStore`, …), derivatives, atomics and barriers, subgroups, `discard`,
and `range`/array helpers. Vector arithmetic is available as `std.add` etc.,
as fluent methods (`v.mul(w)`), or as operators via `tsover`.

Each builtin is a **dual implementation** built by `dualImpl`
([`dualImpl.ts`][dualimpl]): a `normalImpl` (JS, used on the CPU), a
`codegenImpl` (WGSL text), a `signature` that converts arguments, and a
`sideEffects` flag. When every argument is known at generation time, the
generator calls `normalImpl` and emits the constant — so the CPU twin _is_
the constant folder. A builtin whose `normalImpl` is a string throws
`MissingCpuImplError` on the CPU:

```ts
// std/derivative.ts
export const dpdx = dualImpl<DerivativeSignature>({
  name: 'dpdx',
  normalImpl: 'Derivative builtins are not allowed on the CPU',
  signature: derivativeSignature,
  codegenImpl: (ctx, [value]) => ctx.gen.emitCall('dpdx', [], [value]),
  sideEffects: false,
});
```

The same is true of `workgroupBarrier`, `storageBarrier`, all `atomic*`
operations ([`atomic.ts`][atomic]), every subgroup operation
([`subgroup.ts`][subgroup]) and `discard` ([`discard.ts`][discard]).
Everything that needs more than one invocation has no CPU semantics.

Shells also accept **WGSL bodies** as tagged templates, with dependencies
injected through `$uses`:

```ts
const getGradientColor = tgpu.fn([d.f32], d.vec4f)`(ratio) {
  return mix(purple, get_blue(), ratio);
}`.$uses({ purple, get_blue: getBlue });
```

Resolution renames `get_blue` to the callee's final identifier and inlines
`purple` as a literal ([`apis/functions/index.mdx`][doc-fn]). JS and WGSL
functions can call each other freely; `tgpu.resolve({ template, externals })`
extends an existing WGSL file the same way ([`resolve.mdx`][doc-resolve]).

## Control flow, memory model and restrictions

Supported syntax is what `tinyest` encodes: blocks, `if`, `for`, `while`,
`for…of` (over arrays, `std.range`, or `tgpu.unroll`), `switch`, `break`,
`continue`, `return`, `let`/`const`, the conditional operator, object and
array literals (lowered to struct and array constructors)
([`nodes.ts`][tinyest-nodes]). Calls are allowed only to `'use gpu'`
functions, `std`, most `Math.*` (mapped to `std`), schemas and `console.log`,
which is implemented by serializing arguments into a GPU buffer and decoding
them on the host ([`tgsl/consoleLog/`][consolelog]). WGSL's restrictions
(no recursion, no `undefined`/`null`, uniform-control-flow requirements for
barriers and derivatives) are inherited and checked by the WebGPU
implementation's WGSL compiler, not by TypeGPU; the data-schema guide warns
that relying on `undefined` from an out-of-range read is _"undefined behavior
in WGSL"_ ([`data-schemas.mdx`][doc-schemas]).

The memory model is WGSL's, unmodified: address spaces `function`, `private`,
`workgroup`, `uniform`, `storage`, `handle`; atomics on `i32`/`u32`; barriers
as above. TypeGPU models pointers in the generator
(`d.ptrFn`/`d.ptrPrivate`/`d.ptrWorkgroup`, [`ptr.ts`][ptr]; implicit-pointer
dereferencing in `dualImpl`), while JavaScript itself has value semantics for
numbers and reference semantics for objects. The ESLint rule
`noInvalidAssignment` ("Disallow assignments that will generate invalid
WGSL") rejects the two assignments whose JS meaning has no WGSL counterpart:
to an immutable WGSL parameter, and to a captured outer-scope JS variable
([`noInvalidAssignment.ts`][eslint-assign]).

## Compilation pipeline and targets

```text
TS source ──unplugin (build)──▶ JS + __TYPEGPU_META__ {tinyest AST, externals thunks}
                                   │
                       tgpu.resolve / pipeline creation (run time, in the app)
                                   ▼
             ResolutionCtx + WgslGenerator ──▶ WGSL text ──▶ GPUDevice.createShaderModule
                                   └── @typegpu/gl GlslGenerator ──▶ GLSL ES 3.00 (WebGL 2)
```

Code generation happens **in the application at run time**, lazily, the
first time a pipeline is created or drawn ([`resolve.mdx`][doc-resolve]). The
docs suggest combining `unplugin-macros` with `tgpu.resolve` to precompute
variants at build time. The generator sits behind a `ShaderGenerator`
interface ([`shaderGenerator.ts`][shadergen]) with `FunctionDefinitionOptions`,
`VariableDefinitionOptions` and statement-level control-flow facts
(`endsWithControlFlow`); `@typegpu/gl` implements it as `glslGenerator.ts`
([`typegpu-gl/src/`][gl-src]) for a vertex/fragment subset without compute,
storage buffers or bind groups ([`typegpu-gl` docs][gl-docs]). There is no
SPIR-V, DXIL or MSL output; the browser's WebGPU implementation (Tint in
Chromium, naga in Firefox) performs that translation. A minifier
([`minify.ts`][minify]) shortens production WGSL.

## Host integration and CPU execution

Host integration is the library's centre: `tgpu.init()` returns a root that
creates typed buffers (`write`/`read` serialize through the schema), textures,
samplers, bind groups and pipelines, and `root.unwrap(x)` exposes the raw
WebGPU object at any point ([`init.ts`][init]). Pipelines carry their slot
bindings (`root.with(slot, v).createComputePipeline(…)`).

**CPU execution has three levels, none of them a parallel simulator:**

1. **Direct calls.** A `'use gpu'` function is ordinary JavaScript; calling it
   runs the `tsover`-rewritten body with `std`'s `normalImpl`s. This is the
   basis of the "shader unit testing" claim.
2. **Generation-time evaluation.** `dualImpl`, `tgpu.comptime` and
   `tgpu.lazy` run JS during resolution to fold constants.
3. **`tgpu['~unstable'].simulate(callback)`.** Runs a callback with access to
   buffers, `privateVar`s and `workgroupVar`s _"as if it were running on the
   GPU"_, returning the final values without touching GPU state. The
   implementation allocates per-thread and per-workgroup variable maps over a
   3-D grid but is _"Statically locked to one "thread" for now"_
   (`workgroups = [1,1,1]`, `workgroupSize = [1,1,1]`)
   ([`tgpuSimulate.ts`][simulate]).

Because barriers, atomics, subgroup operations and derivatives all throw
`MissingCpuImplError` on the CPU, the CPU path validates only single-invocation
arithmetic. JavaScript's `number` is an `f64`, so `f32`/`f16` rounding is not
reproduced unless a schema cast is applied; the docs note that _"the type of
any number remains a number regardless of casts"_ ([`data-schemas.mdx`][doc-schemas]).

## Lessons for sparkles:shaders

- **Adopt: one layout description drives host serialization, the device
  struct and validation.** TypeGPU's schema computes `alignmentOf`/`sizeOf`
  once and reuses it for writers, WGSL structs and uniform-rule warnings.
  In D, the struct type _is_ the schema: a `static assert`-backed
  `layoutOf!(T, Std140)` / `layoutOf!(T, Std430)` / `layoutOf!(T, Scalar)` at
  compile time can generate the padded device struct and a host
  `writeTo(ref Buffer)` from the same declaration — at zero run-time cost,
  which TypeGPU pays for with `new Function` JIT.
- **Match: a WGSL-uniform-rules check that names the fix.** The
  `uniform-schema-misaligned` message ("wrap the property in `d.align(16, …)`")
  is the right diagnostic shape for sparkles' std140/WGSL-uniform targets; in
  D it should be a compile-time error per target dialect, not a log line.
- **Adopt: every built-in is a dual implementation with an explicit
  "no CPU semantics" state.** `dualImpl`'s `normalImpl`/`codegenImpl`/
  `sideEffects` triple maps directly onto sparkles' `SHV7` CPU twin
  requirement ([SPEC][spec]); make the "unavailable on the CPU" case a typed,
  compile-time-visible property of the intrinsic, not a thrown string.
- **Avoid: inferring numeric types from literal values.** `1.0 → i32` and the
  blanket `f32` cast on `/` are workarounds for JavaScript's single `number`.
  D has `float`, `int`, `uint`, `half`-as-a-type questions answered by the
  language; keep D's static types authoritative.
- **Take, but statically: slots, accessors, `lazy`, `comptime`.** These are
  TypeGPU's templates, CTFE and dependency injection, all resolved at shader
  generation. D's template parameters, alias parameters and CTFE do the same
  at compile time with type checking; the `accessor` idea — "any resource of
  this element type" — is worth keeping as a D concept constraint over
  uniform/storage/constant/push-constant sources.
- **Avoid: a CPU path that is single-invocation only.** `simulate` is pinned
  to one thread, and barriers/atomics/subgroups throw. sparkles' planned
  simulator should treat workgroups, barriers and subgroup operations as the
  core of the CPU model (see [ILGPU][ilgpu]), not an afterthought.
- **Match: an escape hatch to raw target code at function granularity.**
  TypeGPU's WGSL template bodies with `$uses` renaming are what lets it trail
  WGSL features without blocking users; sparkles needs the equivalent for
  SPIR-V intrinsics not yet in the vocabulary (`pragma(LDC_intrinsic, …)`
  today, see [dcompute][dcompute]).
- **Avoid: run-time code generation as the only mode.** TypeGPU resolves in
  the application; sparkles generates offline and validates with `spirv-val`
  in the build step, which is strictly stronger evidence. Keep it.

## Strengths

- One schema object types buffers, bind groups, host values and WGSL structs;
  layout bugs between host and shader are structurally excluded.
- Seamless mixing of TypeScript and WGSL at function granularity, with a
  linker (`tgpu.resolve`) that deduplicates and names dependencies.
- Expressive generation-time metaprogramming (slots, accessors, `lazy`,
  `comptime`, `unroll`) that libraries use for inversion of control.
- Constant folding reuses the CPU implementations, so the CPU twin is
  exercised on every resolution.
- Works in plain JavaScript; the build plugin covers nine bundlers.

## Weaknesses

- WGSL-only semantics: WebGPU's three stages and WGSL's feature set are the
  ceiling; the GLSL backend is an experimental subset.
- Type inference from runtime values: integer-vs-float literal heuristics,
  `f64` arithmetic on the CPU, and value/reference divergence between JS and
  WGSL need lint rules to contain.
- The CPU path cannot execute barriers, atomics, subgroup operations or
  derivatives, and `simulate` runs one invocation.
- Errors surface at run time (resolution or `createShaderModule`), not at
  build time; unfilled slots are a runtime error ([`slots.mdx`][doc-slots]).
- Depends on a build-time AST transform; without the plugin only WGSL
  template functions work.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                 | Trade-off                                                                                 |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Schemas as runtime values (Zod-style)                           | One object drives types, layout, serialization and WGSL                                   | Layout is computed and JIT-compiled at run time; `eval`-free environments get a slow path |
| Capture the AST at build time (`tinyest`), generate at run time | No JS parser shipped; externals captured precisely; values known at generation are folded | Requires a bundler plugin; shader errors appear when the app runs                         |
| Ignore TypeScript types; infer WGSL types per call              | Works in JS; generic functions specialize for free                                        | Literal-value type heuristics; types can differ between CPU run and GPU run               |
| `dualImpl` for every builtin                                    | CPU parity, constant folding and codegen from one definition                              | Multi-invocation builtins have no CPU meaning and throw                                   |
| Slots/accessors/`lazy` instead of language generics             | Dependency injection across packages; any JS value can parameterize a shader              | Unchecked until resolution; resolution is memoized per slot map to stay affordable        |
| WGSL template strings as a first-class body form                | Never blocked on unsupported features; easy migration from WGSL                           | Two languages per project; WGSL bodies have no CPU implementation                         |
| Uniform rules as warnings                                       | One layout for all address spaces, as in WGSL                                             | A misaligned uniform still ships unless the user reads the log                            |

## Sources

- [software-mansion/TypeGPU — repository][repo] · [documentation][docs] · [TypeGPU 0.12 release post (2026-08-12)][blog012]
- [`README.md` — positioning and the three ways to use a function][readme]
- [`packages/typegpu/package.json` — version 0.12.8, MIT][pkg]
- [`advanced/explaining-the-magic.mdx` — unplugin transform, metadata, externals][doc-magic]
- [`apis/functions/index.mdx` — `'use gpu'`, shells, polymorphism, entry functions, builtins][doc-fn]
- [`apis/data-schemas.mdx` — schemas, layout, `d.align`/`d.size`][doc-schemas]
- [`apis/resolve.mdx`][doc-resolve] · [`apis/slots.mdx`][doc-slots] · [`apis/accessors.mdx`][doc-accessors] · [`apis/bind-groups.mdx`][doc-bind]
- [`ecosystem/typegpu-gl/index.mdx` — experimental WebGL 2 / GLSL backend][gl-docs]
- [`packages/tinyest/src/nodes.ts` — the `tinyest` AST][tinyest-nodes] · [`packages/tinyest-for-wgsl`][tinyest-wgsl] · [`packages/unplugin-typegpu`][unplugin]
- [`src/tgpu.ts`][tgpu-barrel] · [`src/tgpuUnstable.ts`][unstable] · [`src/resolutionCtx.ts`][resctx] · [`src/core/resolve/namespace.ts`][namespace]
- [`src/tgsl/wgslGenerator.ts`][wgslgen] · [`src/tgsl/shaderGenerator.ts`][shadergen] · [`src/tgsl/shellless.ts`][shellless]
- [`src/core/function/dualImpl.ts`][dualimpl] · [`comptime.ts`][comptime] · [`tgpuComputeFn.ts`][computefn] · [`tgpuVertexFn.ts`][vertexfn] · [`tgpuFragmentFn.ts`][fragmentfn]
- [`src/core/slot/lazy.ts`][lazy] · [`src/core/unroll/tgpuUnroll.ts`][unroll] · [`src/core/variable/tgpuVariable.ts`][variable] · [`src/core/simulate/tgpuSimulate.ts`][simulate]
- [`src/data/alignmentOf.ts`][alignof] · [`src/data/compiledIO.ts`][compiledio] · [`src/data/unstruct.ts`][unstruct] · [`src/core/pipeline/webgpuLimitations.ts`][limits]
- [`src/std/derivative.ts`][derivative] · [`src/std/atomic.ts`][atomic] · [`src/std/subgroup.ts`][subgroup] · [`src/std/discard.ts`][discard]
- Related: [WGSL][wgsl] · [Tint][tint] · [naga][naga] · [ILGPU][ilgpu] · [ComputeSharp][computesharp] · [dcompute baseline][dcompute] · [Concepts][concepts] · [Comparison][comparison] · [Catalog index][index] · [`sparkles:shaders` SPEC][spec]

<!-- References -->

[repo]: https://github.com/software-mansion/TypeGPU
[docs]: https://docs.swmansion.com/TypeGPU/
[blog012]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/blog/typegpu-0.12/index.mdx
[readme]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/README.md
[pkg]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/package.json
[doc-magic]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/advanced/explaining-the-magic.mdx
[doc-fn]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/apis/functions/index.mdx
[doc-schemas]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/apis/data-schemas.mdx
[doc-resolve]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/apis/resolve.mdx
[doc-slots]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/apis/slots.mdx
[doc-accessors]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/apis/accessors.mdx
[doc-bind]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/apis/bind-groups.mdx
[gl-docs]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/apps/typegpu-docs/src/content/docs/ecosystem/typegpu-gl/index.mdx
[gl-src]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu-gl/src/glslGenerator.ts
[tinyest-nodes]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/tinyest/src/nodes.ts
[tinyest-wgsl]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/tinyest-for-wgsl/src/parsers.ts
[unplugin]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/unplugin-typegpu/README.md
[tgpu-barrel]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgpu.ts
[unstable]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgpuUnstable.ts
[resctx]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/resolutionCtx.ts
[namespace]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/resolve/namespace.ts
[wgslgen]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgsl/wgslGenerator.ts
[shadergen]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgsl/shaderGenerator.ts
[shellless]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgsl/shellless.ts
[consolelog]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgsl/consoleLog/logGenerator.ts
[minify]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/minify.ts
[dualimpl]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/function/dualImpl.ts
[comptime]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/function/comptime.ts
[computefn]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/function/tgpuComputeFn.ts
[vertexfn]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/function/tgpuVertexFn.ts
[fragmentfn]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/function/tgpuFragmentFn.ts
[init]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/root/init.ts
[lazy]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/slot/lazy.ts
[unroll]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/unroll/tgpuUnroll.ts
[variable]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/variable/tgpuVariable.ts
[simulate]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/simulate/tgpuSimulate.ts
[bgl]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/tgpuBindGroupLayout.ts
[data-dir]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/data/index.ts
[std-dir]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/std/index.ts
[alignof]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/data/alignmentOf.ts
[compiledio]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/data/compiledIO.ts
[unstruct]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/data/unstruct.ts
[limits]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/core/pipeline/webgpuLimitations.ts
[derivative]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/std/derivative.ts
[atomic]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/std/atomic.ts
[subgroup]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/std/subgroup.ts
[discard]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/std/discard.ts
[eslint-rules]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/eslint-plugin/src/rules/noIntegerDivision.ts
[wgsl]: ./wgsl.md
[tint]: ./tint.md
[naga]: ./naga.md
[ilgpu]: ./ilgpu.md
[computesharp]: ./computesharp.md
[dcompute]: ./dcompute.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[ptr]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/typegpu/src/data/ptr.ts
[eslint-assign]: https://github.com/software-mansion/TypeGPU/blob/3e1efd4437f55fb8ddac9c5bbc968a8eaa7fc8bf/packages/eslint-plugin/src/rules/noInvalidAssignment.ts
