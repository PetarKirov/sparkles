# Rust GPU (Rust → SPIR-V)

A `rustc` codegen backend, `rustc_codegen_spirv`, that compiles ordinary `no_std` Rust crates to Vulkan-flavoured SPIR-V, paired with `spirv-std`, a GPU standard library built on the same `glam` vector crate the CPU side uses. It is the most mature single-source shading effort in a general-purpose systems language, and the closest analogue in _shape_ to `sparkles:shaders`.

| Field          | Value                                                                                                                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Rust (edition 2024), compiled by a pinned nightly `rustc` (`nightly-2026-08-15`, rustc 1.99.0) — [`rust-toolchain.toml`][toolchain]                                                       |
| License        | MIT OR Apache-2.0 (dual) — [`Cargo.toml`][cargo]                                                                                                                                          |
| Repository     | [Rust-GPU/rust-gpu][repo] (pinned at [`57d0794`][repo-pin], 2026-10-16)                                                                                                                   |
| Documentation  | [Rust-GPU dev guide][guide] · [API docs][api] · [`docs/src/`][docs-src] in-tree                                                                                                           |
| Category       | Single-source peer: a host language's compiler grows a GPU backend                                                                                                                        |
| Latest version | `0.11.0`, 2026-10-13 ([`CHANGELOG.md`][changelog])                                                                                                                                        |
| Targets        | SPIR-V: `spirv-unknown-spv1.x`, `-vulkan1.x`, `-opengl4.x` ([`target.rs`][target]); WGSL via an in-process `naga` pass (`spirv-unknown-naga-wgsl`, [`naga_transpile.rs`][naga-transpile]) |
| Stages         | Every SPIR-V `ExecutionModel` (vertex, fragment, compute, geometry, tessellation, mesh/task, ray tracing) named in snake_case — [`attributes.md`][attributes]                             |
| History        | First commit 2020-07-24 (Embark Studios); community-owned under the Rust-GPU organisation since 2024-08-12 ([transition post][transition])                                                |
| Sibling        | [Rust-CUDA][rust-cuda-blog]: `rustc` → NVVM IR → PTX, for NVIDIA compute only                                                                                                             |

> [!NOTE]
> The README's own status line, verbatim: _"This project is still heavily in development and is at an early stage. … while being technically usable, this project is not yet production-ready."_ ([`README.md`][readme]). The project makes _"no guarantees about backwards compatibility"_ and supports only `main`.

---

## Overview

### What it solves

Shader languages lag the host languages they sit beside: no package manager, weak generics, no shared types, no test tooling. Rust GPU's thesis is that a production systems language, not a new DSL, should be the shading language, so shader code is published on crates.io, shares structs and math with the CPU crate, and is unit-tested with `cargo test`. The README frames the gap directly ([`README.md`][readme]):

> _"Historically in games GPU programming has been done through writing either HLSL, or to a lesser extent GLSL and WGSL. These are simple programming languages that have evolved along with rendering APIs over the years. However, these languages have failed to provide mechanisms for dealing with large codebases, and have generally stayed behind the curve compared to other programming languages."_

The mechanism is a full `rustc` backend plugged in through `-Z codegen-backend` — _"the same mechanism that rustc_codegen_cranelift and rustc_codegen_gcc use"_ — so the front end (borrow checker, trait solver, monomorphiser, MIR optimiser) is stock `rustc`, and only codegen differs.

### Design philosophy

Three commitments shape everything:

1. **Reuse the host ecosystem, including its math library.** Vectors are `glam`'s `Vec2`/`Vec3`/`Vec4`, which the backend recognises and lowers to `OpTypeVector`; `glam` must be built with `default-features = false`, and `spirv-std` switches it to `libm` on the GPU and `std` on the CPU ([`structure.md`][structure]).
2. **Declarations live in the entry point's signature.** Inputs, outputs, built-ins, descriptors and push constants are _parameters_ carrying `#[spirv(..)]` attributes, never globals. The guide states the trade-off itself ([`shaders.md`][shaders]): _"Unlike most other shader languages, inputs and outputs can't just be declared anywhere within our code and includes. Instead, they are passed as parameters to your entry point function, centralizing where they can be declared."_ — and admits _"it makes it difficult to share these declarations across multiple shaders."_
3. **Don't fail on what is unreachable.** Anything the backend cannot represent (`u128`, function pointers, some `core` internals) becomes a _zombie_ and is reported only if it survives dead-code elimination — which is how a large part of `core` compiles at all ([`codegen_cx/mod.rs`][codegen-cx]):

   > _"If something unrepresentable is encountered, we don't want to fail the compilation. Instead, we emit something bogus … and then mark the resulting ID as a "zombie". We continue compiling the rest of the crate, then, at the very end, anything that transitively references a zombie value is stripped from the binary. Errors will only be emitted (by `linker::zombies`) for reachable zombies."_

Rust GPU is the canonical _host-language-backend_ data point in this catalog; compare it with [Vcc/Shady][vcc-shady] (C++ via Clang's LLVM IR), [Circle][circle] (C++ with reflection), [Zig's SPIR-V backend][zig-spirv], and with LDC's own [dcompute][dcompute], the substrate `sparkles:shaders` builds on.

---

## How it works

### The crate layout

A Rust GPU project is a Cargo workspace with (at least) a shader crate and a host crate ([`structure.md`][structure]):

| Crate                               | Role                                                                                                                   |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `mygraphics-shaders` (`#![no_std]`) | Shader source; depends on `spirv-std` and `glam`. Compiled **twice**: by `rustc_codegen_spirv` and by the host `rustc` |
| `mygraphics` (`build.rs`)           | Host binary; its build script drives `spirv-builder`, which invokes the backend on the shader crate                    |
| `spirv-std`                         | `#[spirv]` attribute macro, `Image!`, `Sampler`, intrinsics (`arch::*`), `TypedBuffer`, `RuntimeArray`                 |
| `rustc_codegen_spirv`               | The backend dylib; must match the `spirv-std` version _exactly_                                                        |
| `spirv-builder` / `cargo-gpu`       | Build-script API and CLI that install the pinned toolchain and build the backend                                       |

The build script resolves the backend version from the shader crate's `spirv-std` dependency, builds it, compiles the shader crate, and hands the `.spv` path to the host via an environment variable that `include_bytes!` embeds:

```rust
// docs/src/getting-started/structure.md (abridged)
let install = Install::from_shader_crate(crate_path.clone())
    .within_build_script()
    .run()?;
let mut builder = install.to_spirv_builder(crate_path, "spirv-unknown-vulkan1.3");
builder.build_script.defaults = true;
let compile_result = builder.build()?;
let spv_path = compile_result.module.unwrap_single();
println!("cargo::rustc-env=SHADER_SPV_PATH={}", spv_path.display());
```

### An entry point, and the function it forwards to

The `sky-shader` example is exactly the pattern `sparkles:shaders` mandates (`SHF1`): a thin entry point that unpacks the interface and forwards to an ordinary function the CPU can also call ([`sky-shader/src/lib.rs`][sky]):

```rust
pub fn fs(constants: &ShaderConstants, frag_coord: Vec2,
          sun_intensity_extra_spec_const_factor: u32) -> Vec4 { /* … */ }

#[spirv(fragment)]
pub fn main_fs(
    #[spirv(frag_coord)] in_frag_coord: Vec4,
    #[spirv(push_constant)] constants: &ShaderConstants,
    output: &mut Vec4,
    #[spirv(spec_constant(id = 0x5007, default = 100))] sun_intensity_extra_spec_const_factor: u32,
) {
    let frag_coord = vec2(in_frag_coord.x, in_frag_coord.y);
    *output = fs(constants, frag_coord, sun_intensity_extra_spec_const_factor);
}
```

The `#[spirv(..)]` macro itself is a `cfg_attr`: it expands to `#[cfg_attr(target_arch="spirv", rust_gpu::spirv(..))]` ([`macros/src/lib.rs`][macros]), so on the CPU the attributes vanish and `main_fs` is an ordinary function.

### The backend pipeline

`rustc` lowers MIR through `rustc_codegen_ssa` (a copy patched by `build.rs` into a "pqp" variant to keep typed `alloca`s, [`lib.rs`][lib]) into a SPIR-V module per codegen unit, emitted with `rspirv`. The real work happens in the **linker** ([`linker/mod.rs`][linker]), in this order:

1. **Link and deduplicate** the per-crate modules; check fragment-only instructions.
2. **`specialize_generic_storage_class`** — the storage-class inference pass (below).
3. **`mem2reg` before inlining** (possible because SPIR-T structurisation tolerates `OpPhi`).
4. **`inline`** — not an optimisation but _legalisation_ ([`inline.rs`][inline]): _"spir-v disallows things like a `StorageClass::Function` pointer to a `StorageClass::Input` pointer. Our frontend definitely allows it … So, we inline all functions that take these "illegal" pointers, then run mem2reg … to "unwrap" the Function pointer."_ It first calls `deny_recursion_in_module` — _"SPIR-V bans recursion"_.
5. **`mem2reg` again**, composite destructuring, DCE, zombie reporting.
6. **SPIR-V → SPIR-T → SPIR-V round trip**: `lower_from_spv_bytes`, `convert_custom_aborts_to_unstructured_returns_in_entry_points`, `spirt::passes::legalize::structurize_func_cfgs`, optional SPIR-T passes (`qptr`, …), `explicit_layout::erase_when_invalid`, `validate`, diagnostics, `lift_to_spv_module_emitter`.
7. `spirv-opt` (when optimising) and `spirv-val`, then optionally `naga` → WGSL.

[SPIR-T][spirt] is the project's own IR: _"as of `rust-gpu 0.8.0`, `SPIR-🇹` is always being used and cannot be disabled"_, and it _"replaces the existing structurizer with `SPIR-🇹` structurization (which is more robust and can e.g. handle `OpPhi`s)"_ ([`codegen-args.md`][codegen-args]). `--no-structurize` exists but _"Probably results in invalid modules."_

---

## Execution model and stages

Every SPIR-V execution model is reachable: the attribute is the `spirv_headers::ExecutionModel` enum name in snake*case (`#[spirv(vertex)]`, `#[spirv(fragment)]`, `#[spirv(compute(threads(32, 16)))]`, mesh/task since `PR#44`, ray-tracing stages via `spirv_std::ray_tracing`). Workgroup size is a literal in the attribute — trailing ones elide; it \_cannot* be a specialisation constant ([`compute.md`][compute]). `entry_point_name = "…"` overrides the `OpEntryPoint` name. Only functions so marked are exported; everything else is inlined or discarded.

Fragment-only operations are checked at link time, not by the type system: `check_fragment_insts` walks the call graph from every non-fragment entry point and rejects `OpDPdx`/`OpDPdy`/`OpFwidth` (and their `Fine`/`Coarse` forms), every implicit-LOD `OpImageSample*`, `OpImageQueryLod` and `OpKill` ([`simple_passes.rs`][simple-passes]) — so a `dfdx` reached from a compute entry point is a link error, not a type error. Helper-lane semantics and uniformity are not modelled at all.

## Type system and generic programming

Stock Rust: traits, generics, `const` generics, closures and iterators all work _because_ they monomorphise and inline away before SPIR-V sees them. What the backend rejects is what cannot be lowered to logical SPIR-V:

| Feature                        | Status                                                                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Generics, traits, `impl Trait` | Supported (monomorphised)                                                                                                       |
| `dyn Trait`, `fn` pointers     | Rejected: _"function pointer types are not allowed"_ ([`spirv_type.rs`][spirv-type], test [`issue-452`][t-452])                 |
| Recursion                      | Rejected at link: _"module has recursion, which is not allowed"_ ([`issue_764`][t-764])                                         |
| `alloc` (`Vec`, `String`, …)   | Unavailable (`no_std`, no allocator)                                                                                            |
| `u128`/`i128`                  | Constants only (`PR#595`), as a zombie escape so more crates compile                                                            |
| `f16`, `f64`, `i8`–`i64`       | Supported, subject to SPIR-V capabilities                                                                                       |
| Enums with data                | Supported in-shader; **UB across the CPU/GPU boundary** if a buffer holds an invalid discriminant ([every-GPU post][every-gpu]) |

**Vectors are recognised structurally.** A struct marked `#[rust_gpu::vector::v1]` (as `glam`'s scalar vector types are) becomes an `OpTypeVector` provided it has 2–4 members of one scalar type; _"The layout of your type is unaffected, the size, alignment and member offsets will follow standard rustc layout rules"_ ([`vector.rs`][vector]). `spirv_std::Vector` is the trait generic code bounds on. `glam`'s 16-byte-aligned SIMD `Vec3A` is now _disallowed_ in intrinsics and `asm!` (`PR#660`), so the device `vec3` is a 12-byte type.

**Swizzles are methods**: `glam` generates `v.xy()`, `v.zyx()`, `Vec2::xyxx()` as rvalues; there is no swizzle assignment (`v.xy = …`), and construction from parts is `Vec4::from((v3, 1.0))` or `.extend(1.0)`.

**Images** are one const-generic type, `spirv_std::image::Image`, whose parameters are _"incredibly tedious"_, hence the `Image!(2D, type=f32, sampled)` macro and aliases `Image2d`, `Cubemap`, … ([`images.md`][images]). A `spirv-std-nightly` variant (`PR#636`) uses `adt_const_params` for nicer image parameters.

## Resources, interfaces and memory layout

Interface kinds are told apart by parameter _shape_ plus attributes ([`attributes.md`][attributes], [`shaders.md`][shaders]):

| Parameter                                                                 | Meaning                              | GLSL equivalent                             |
| ------------------------------------------------------------------------- | ------------------------------------ | ------------------------------------------- |
| `vtx_color: Vec3` (by value)                                              | stage input                          | `in vec3 vtx_color;`                        |
| `output: &mut Vec4`                                                       | stage output                         | `out vec4 output;`                          |
| `#[spirv(position)] p: &mut Vec4`                                         | built-in                             | `gl_Position`                               |
| `#[spirv(flat)]`, `#[spirv(invariant)]`                                   | interpolation / invariance           | `flat`, `invariant`                         |
| `#[spirv(uniform, descriptor_set = 2, binding = 5)] u: &T`                | uniform block                        | `layout(set=2, binding=5) uniform …`        |
| `#[spirv(storage_buffer, descriptor_set = 0, binding = 2)] c: &mut [u32]` | SSBO (runtime-sized slice)           | `buffer { uint c[]; }`                      |
| `#[spirv(push_constant)] k: &T`                                           | push constants                       | `layout(push_constant)`                     |
| `#[spirv(workgroup)] s: &mut [f32; 4]`                                    | shared memory                        | `shared`                                    |
| `#[spirv(spec_constant(id = 9000, default = 123))] x: u32`                | specialisation constant (`u32` only) | `layout(constant_id=9000) const uint x=123` |
| `&RuntimeArray<TypedBuffer<[u32]>>`                                       | bindless array of buffers            | `buffer B { … } bufs[];`                    |

Locations for plain inputs and outputs are assigned by the backend; descriptor sets and bindings are **manual integers that must match the host** — the very thing [RFC 001][rfc-001] says it wants to avoid: _"One thing we'd like to avoid is having a set of names or numbers that manually need to match up between GPU and CPU."_ The RFC is unimplemented.

**Storage classes are inferred, not typed.** Rust references have no address space, so every pointer is emitted with a generic storage-class variable and the specializer _"monomorphizes"_ functions per distinct combination ([`specializer.rs`][specializer]): _"For now, this is only used for pointer type storage classes, because Rust's pointer/reference types don't have an "address space" distinction, and we also wouldn't want users to annotate every single type anyway."_ Storage-class attributes are _"only permitted on entry points"_. Pointers that are still illegal after specialisation (a `Function` pointer to an `Input` pointer) are removed by inlining.

> [!WARNING]
> `&mut` on a shared buffer is a lie: _"In Rust, mutable references don't just allow you to mutate the referenced memory, but also gives you exclusive access to it. Since this mutable references is shared between all the threads, it can't be exclusive. This is a mistake on rust-gpu's entry point API design"_ ([`compute.md`][compute]). The same holds for `#[spirv(workgroup)]` memory.

**Layout is rustc's, checked after the fact.** `Offset`/`ArrayStride` decorations come from rustc's `repr(C)` layout ([`spirv_type.rs`][spirv-type]); the backend does not compute std140/std430. Instead `spirv-val`'s block-layout check is configured with `--relax-block-layout` (default for Vulkan 1.1+), `--uniform-buffer-standard-layout`, `--scalar-block-layout`, or `--skip-block-layout` ([`codegen_cx/mod.rs`][codegen-cx]). Host and device share the struct definition, and `bytemuck::Pod` is the recommended guard for "no padding" — yet the guide warns _"rust-gpu does not verify that your declarations actually implement `Pod`"_ ([`shaders.md`][shaders]), and the project's own retrospective says _"Care must still be taken to ensure data is padded correctly. … for now you must do so manually"_ ([every-GPU post][every-gpu]). `explicit_layout::erase_when_invalid` strips decorations from storage classes where Vulkan forbids them. Matrices with a non-`OpTypeMatrix` shape (`Matrix4x3`) _"Cannot be used within buffers, push constants or anything that requires an "explicit layout"."_ ([`matrix.rs`][matrix]).

Buffer device address (physical pointers) is unsupported: the guide notes _"rust-gpu doesn't support Buffer Device Address (BDA) yet"_ ([`introduction.md`][introduction]).

## Built-in library and intrinsics

`spirv-std` provides the GPU-only surface ([`spirv-std/src/lib.rs`][std-lib]): `arch::{atomics, barrier, derivative, subgroup, mesh_shading, ray_tracing, demote_to_helper_invocation_ext, primitive}`, `image`, `Sampler`, `ByteAddressableBuffer`, `cooperative_matrix` (`KHR_cooperative_matrix`, `PR#589`), `debug_printf!`, `indirect_command`.

Three implementation techniques coexist:

- **libm interception.** `f32::sin` and friends route through `num_traits::Float` → `libm` names, which the backend recognises by symbol and maps to `GLSL.std.450` ops or custom expansions ([`libm_intrinsics.rs`][libm]): `("acosf", GLOp(Acos))`, `("ceilf", GLOp(Ceil))`, … with `Custom` lowering for `cbrt`, `erf`, `tgamma`, `fmod`, `hypot`, `copysign`, `sincos`. On the CPU the same calls run real `libm`/`std` — so **CPU and GPU precision differ by construction** and nothing states the bound.
- **Inline SPIR-V assembly.** `asm!` with SPIR-V mnemonics, `%id` names and `typeof*{x}` type inference is the escape hatch _and_ the implementation of most intrinsics ([`inline-asm.md`][inline-asm]); `dfdx` is `asm!("%result = OpDPdx typeof*{1} %input", …)` ([`derivative.rs`][derivative]).
- **`#[gpu_only]`.** Intrinsics with no CPU meaning compile on the CPU as `unimplemented!("`…` is only available on SPIR-V platforms.")` ([`macros/src/lib.rs`][macros]) — `spirv-std` says it _"deliberately provide[s] an unimplemented version of our API on CPU platforms so that code completion still works."_ Derivatives, image sampling, subgroup ops and barriers therefore **panic** in a CPU run rather than being simulated.

## Control flow, memory model and restrictions

- **Structured control flow is recovered**, not required: Rust's MIR CFG is lowered unstructured and SPIR-T's `structurize_func_cfgs` rebuilds selection/loop merges. Arbitrary Rust control flow (`loop`/`break 'label`/`?`/`match`) is accepted; there is no `goto` to worry about.
- **Panics** become a custom abort instruction, lowered to a `return` from the entry point (the invocation silently stops) by default, or with `--abort-strategy=debug-printf[+inputs][+backtrace]` to a `debugPrintf` message ([`controlflow.rs`][controlflow]); `spirv-std`'s `#[panic_handler]` is `loop {}`. Bounds checks on slices therefore cost a branch and, on failure, a quiet early exit.
- **No recursion, no function pointers, no allocation**, enforced by link-time errors or reachable-zombie errors rather than front-end diagnostics; error spans survive through `SrcLocDecoration`.
- **Memory model**: barriers are explicit intrinsics (`workgroup_memory_barrier_with_group_sync`); the Rust aliasing model is not reconciled with SPIR-V's — the `&mut` warning above is the visible symptom. `NonUniform` decorations are added to every image/buffer access when the capability is enabled (`PR#177`) rather than inferred per access.

## Compilation pipeline and targets

| Stage                    | Tool                                                          |
| ------------------------ | ------------------------------------------------------------- |
| Rust → MIR               | stock nightly `rustc`                                         |
| MIR → SPIR-V per CGU     | `rustc_codegen_spirv` (patched `rustc_codegen_ssa`, `rspirv`) |
| Link, specialise, inline | backend linker passes                                         |
| Structurise, legalise    | SPIR-T                                                        |
| Optimise, validate       | `spirv-opt`, `spirv-val` (via the `spirv-tools` crate)        |
| SPIR-V → WGSL (optional) | `naga` in-process (`spirv-unknown-naga-wgsl`)                 |
| SPIR-V → MSL/HLSL/GLSL   | **out of scope**; done at runtime by `wgpu`/`naga`            |

The toolchain is the dominant cost. `rustc_codegen_spirv` links `rustc_private` crates, so it _"can only be built using a very specific nightly version of the Rust toolchain"_ ([backend README][backend-readme]); every release bumps the pinned nightly (`nightly-2026-04-11` → `-07-03` → `-08-15` across 0.10.0-alpha.1 → 0.11.0, [`CHANGELOG.md`][changelog]), and `build.rs` carries a `REQUIRED_RUST_TOOLCHAIN` copy that must be kept in sync ([`build.rs`][build-rs]). `cargo-gpu` exists to install that toolchain on demand inside a build script, with file locks added because concurrent installs raced (`PR#622`, `PR#631`).

The README names the DXIL/WGSL future as speculative: _"Possible a future version could support DXIL … or WGSL"_. Today non-Vulkan APIs consume the SPIR-V through `naga` at runtime, and the Shadertoy port surfaced and fixed `naga` bugs in that path (_"Fixed a panic while processing SPIR-V"_, _"Fixed incorrect translation of certain shader literals when targeting Metal"_ — [Shadertoys post][shadertoys]).

**Testing** is layered ([`testing.md`][testing]): `cargo compiletest` (UI tests over SPIR-V output, blessed `.stderr`, run per `--target-env`), and **difftests** ([`tests/difftests/README.md`][difftests]) — _"Difftests verify correctness by running multiple implementations of the same logic and comparing their outputs. Instead of relying on fixed reference outputs, they detect discrepancies across implementations"_ — comparing Rust-GPU against hand-written WGSL, `ash` against `wgpu`, and CPU against GPU, with optional per-test epsilon metadata (`TestMetadata::f32(0.00001)`).

## Host integration and CPU execution

Because the shader crate is ordinary Rust, the host imports it as a normal dependency: `ShaderConstants` is defined once and written to a buffer with `bytemuck::bytes_of` ([`shaders.md`][shaders]). Bindings, though, are matched by hand-copied integers, and there is no generated reflection or descriptor-layout API.

**CPU execution is first-class but shallow.** The `cpu` runner ([`runners/cpu/src/main.rs`][cpu-runner]) calls the shader's `fs` function per pixel under `rayon`:

```rust
// examples/runners/cpu/src/main.rs
let buffer = (0..WIDTH * HEIGHT)
    .into_par_iter()
    .map(|i| {
        // …compute frag_coord…
        let color = shader_module::fs(&push_constants, frag_coord, 100);
        color_u32_from_vec4(color)
    })
    .collect::<Vec<_>>();
```

It calls `fs`, not `main_fs`: the CPU path works for the stage-independent function, and stops at anything `#[gpu_only]` (derivatives, sampling, subgroups, barriers). There is no CPU simulator of the execution model — no quads, no workgroups, no image sampling — and the `cpu` runner has a `FIXME` for even mouse input. The project's pitch is nonetheless built on it: _"GPU kernel code can be tested on the CPU using standard Rust testing tools … write the algorithm, test it thoroughly on CPU with familiar tools, then run it on GPU knowing the logic is likely correct."_ ([every-GPU post][every-gpu]).

**Rust-CUDA** is the sister project: _"Rust CUDA enables you to write and run CUDA kernels in Rust, executing directly on NVIDIA GPUs using NVVM IR"_ ([reboot post][rust-cuda-blog]). The 2025 "Rust on every GPU" demo selects between them with Cargo features (`--features wgpu` vs `--features cuda`), and concedes _"Rust GPU and Rust CUDA evolved independently and diverged in their APIs"_ — thread ids are annotated entry parameters in one and function calls in the other, so shared kernels need `cfg` shims ([every-GPU post][every-gpu]).

---

## Lessons for sparkles:shaders

- **Adopt the thin-entry-point split, and make the CPU path call the same function.** `sky-shader`'s `main_fs` → `fs` is `SHF1` verbatim, and the `cpu` runner proves the pattern carries a real effect. Unlike Rust GPU, make it the documented rule (it is, in [`SPEC.md`][sparkles-spec]) and test it: every `@fragment` entry's callee should have a host unittest.
- **Match the interface-as-parameters model, but derive bindings instead of hand-numbering them.** Rust GPU's by-value = input, `&mut` = output convention is clear and maps onto D's `in`/`out`/`ref`. Its weak point is manual `descriptor_set`/`binding` integers that RFC 001 wanted to remove; D's `__traits(getAttributes)` + CTFE can emit those numbers and the host-side layout table from one declaration.
- **Own the layout rule; don't inherit the host ABI and hope `spirv-val` catches it.** Rust GPU emits rustc's `repr(C)` offsets and relies on `spirv-val` flags plus an unenforced `Pod` derive; its maintainers call padding a manual chore. A `static assert`-checked `Std140!T`/`Std430!T`/`Scalar!T` layout computed by CTFE (extending `D9`/`SHV2`) removes that class of bug before the SPIR-V exists.
- **Model address spaces in types, then monomorphise.** Rust GPU had to build a whole specializer plus legalising inliner because references lack storage classes. D can carry the space in the type (`GlobalPointer!T`, `SharedPointer!T` from dcompute) or restrict device code to `ref`/value parameters, so LDC never emits a pointer the SPIR-V backend must guess about.
- **Diagnose in the front end, not at link.** Recursion, function pointers and unreachable-but-unrepresentable code are found by Rust GPU's linker (zombies). Zombies are a good idea for _library_ code (let `std.math` compile, error only if reached), but for user device modules a `@compute`-module check in the fork (`D13`) should reject `delegate`, `class`, `new`, recursion and `throw` with a D source span.
- **State the precision contract and simulate the GPU-only built-ins.** Rust GPU's CPU path runs host `libm` and `unimplemented!()`s derivatives and sampling. `sparkles:shaders` already judges agreement by the Vulkan precision table (`D12`); extend the CPU half with a quad-aware scalar simulator for `dFdx`/`fwidth` and a reference sampler instead of panicking stubs.
- **Copy difftests as the conformance strategy.** Rust GPU's harness runs N implementations of one computation and diffs bytes with an epsilon from metadata. The conformance corpus should do the same across D-on-CPU, D→SPIR-V→GLSL, and a hand-written GLSL/WGSL reference.
- **Avoid a pinned-nightly toolchain tax on consumers.** The `rustc_private` coupling forces a nightly bump every release and a toolchain installer inside build scripts. `sparkles:shaders` already confines the custom LDC to builds that generate GLSL (`D6`, `D14`); keep that boundary.

## Strengths

- Full host language on the device: traits, generics, iterators, closures, crates.io packages, `cargo test`.
- One vector library (`glam`) and one struct definition shared by CPU and GPU.
- Every SPIR-V stage, including mesh, ray tracing and cooperative matrix.
- Robust structuriser (SPIR-T) that accepts arbitrary Rust control flow.
- Zombie system lets large parts of `core` and third-party crates (`blake3`, `PR#634`) compile.
- Differential test harness that compares CPU, multiple GPU backends and hand-written WGSL.
- Inline SPIR-V `asm!` with type inference as a complete escape hatch.

## Weaknesses

- Pinned nightly `rustc` and a backend version that must exactly match `spirv-std`; no stability guarantees.
- Manual `descriptor_set`/`binding` numbers; no reflection or generated host bindings.
- Layout follows rustc's ABI; padding correctness is the user's job (`Pod` unchecked).
- `&mut` on shared buffers and workgroup memory violates Rust's own aliasing contract.
- No buffer device address, no `dyn`/function pointers/recursion; restrictions surface as link errors.
- CPU execution panics on derivatives, sampling, subgroups and barriers; no execution-model simulation; CPU/GPU precision unspecified.
- Single target (SPIR-V); other APIs depend on `naga` at runtime.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                       | Trade-off                                                                                 |
| ------------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| A `rustc` codegen backend, not a DSL              | Reuse the whole front end, type system and package ecosystem    | Coupled to `rustc_private`; pinned nightly; backend must be built per user                |
| Interface as attributed entry parameters          | All declarations in one place; types checked by Rust            | Hard to share declarations between shaders; `&mut` aliasing lie                           |
| `glam` as the vector type                         | Same math on CPU and GPU; existing ecosystem                    | Swizzles are rvalue methods; version pinning across `glam_0_30`…`glam_0_34` features      |
| Storage classes inferred by a specializer         | Rust references have no address space; users shouldn't annotate | Complex legalisation (specialise + inline + mem2reg); recursive pointer types unsupported |
| Layout = rustc `repr(C)`, verified by `spirv-val` | No second layout engine; host and device share the struct       | Padding mistakes found late or not at all; std140 is the user's problem                   |
| Zombies (deferred errors)                         | Let `core` and crates compile; error only if reached            | Errors appear at link time, far from the cause                                            |
| SPIR-T for structurisation                        | Robust against `OpPhi` and arbitrary MIR CFGs                   | A second IR to maintain; SPIR-V round trip on every build                                 |
| `#[gpu_only]` stubs on CPU                        | Code completion and CPU compilation of mixed code               | CPU runs panic on GPU-only built-ins instead of simulating them                           |
| SPIR-V only; `naga` for everything else           | One well-specified output                                       | Non-Vulkan correctness rests on a runtime translator's bugs                               |

## Sources

- [Rust-GPU/rust-gpu repository][repo], pinned at [`57d0794`][repo-pin]: [`README.md`][readme], [`CHANGELOG.md`][changelog], [`rust-toolchain.toml`][toolchain], [`Cargo.toml`][cargo]
- Dev guide: [`introduction.md`][introduction], [`attributes.md`][attributes], [`getting-started/shaders.md`][shaders], [`getting-started/compute.md`][compute], [`getting-started/structure.md`][structure], [`getting-started/images.md`][images], [`codegen-args.md`][codegen-args], [`inline-asm.md`][inline-asm], [`testing.md`][testing], [RFC 001 resource binding syntax][rfc-001]
- Backend: [`lib.rs`][lib], [`build.rs`][build-rs], [`linker/mod.rs`][linker], [`linker/inline.rs`][inline], [`linker/simple_passes.rs`][simple-passes], [`linker/specializer.rs`][specializer], [`linker/spirt_passes/controlflow.rs`][controlflow], [`linker/spirt_passes/explicit_layout.rs`][explicit-layout], [`codegen_cx/mod.rs`][codegen-cx], [`spirv_type.rs`][spirv-type], [`builder/libm_intrinsics.rs`][libm], [`naga_transpile.rs`][naga-transpile], [`target.rs`][target], [backend README][backend-readme]
- `spirv-std`: [`lib.rs`][std-lib], [`vector.rs`][vector], [`matrix.rs`][matrix], [`arch/derivative.rs`][derivative], [`typed_buffer.rs`][typed-buffer], [`runtime_array.rs`][runtime-array], [`macros/src/lib.rs`][macros]
- Examples and tests: [`sky-shader/src/lib.rs`][sky], [`runners/cpu/src/main.rs`][cpu-runner], [`tests/difftests/README.md`][difftests], [`issue-452.stderr`][t-452], [`issue_764.stderr`][t-764]
- Blog: [Transition announcement (2024-08-12)][transition], [Rust on every GPU (2025-07-25)][every-gpu], [Porting Shadertoys (2025-04-10)][shadertoys], [Rust CUDA reboot (2025-01-27)][rust-cuda-blog]
- [SPIR-T][spirt]
- Related: [Vcc/Shady][vcc-shady] · [Circle][circle] · [Zig SPIR-V][zig-spirv] · [dcompute][dcompute] · [naga][naga] · [Concepts][concepts] · [Comparison][comparison] · [Catalog][index]
- Sparkles: [`sparkles:shaders` SPEC][sparkles-spec] · [decisions][sparkles-decisions]

<!-- References -->

[repo]: https://github.com/Rust-GPU/rust-gpu
[repo-pin]: https://github.com/Rust-GPU/rust-gpu/tree/57d07949423593dd701a77d9a78acb4ff7ed943e
[guide]: https://rust-gpu.github.io/rust-gpu/book/
[api]: https://rust-gpu.github.io/rust-gpu/api/rustc_codegen_spirv
[docs-src]: https://github.com/Rust-GPU/rust-gpu/tree/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src
[readme]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/README.md
[changelog]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/CHANGELOG.md
[toolchain]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/rust-toolchain.toml
[cargo]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/Cargo.toml
[introduction]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/introduction.md
[attributes]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/attributes.md
[shaders]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/getting-started/shaders.md
[compute]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/getting-started/compute.md
[structure]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/getting-started/structure.md
[images]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/getting-started/images.md
[codegen-args]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/codegen-args.md
[inline-asm]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/inline-asm.md
[testing]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/testing.md
[rfc-001]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/docs/src/rfcs/001-resource-binding-syntax.md
[lib]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/lib.rs
[build-rs]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/build.rs
[linker]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/linker/mod.rs
[simple-passes]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/linker/simple_passes.rs
[inline]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/linker/inline.rs
[specializer]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/linker/specializer.rs
[controlflow]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/linker/spirt_passes/controlflow.rs
[explicit-layout]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/linker/spirt_passes/explicit_layout.rs
[codegen-cx]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/codegen_cx/mod.rs
[spirv-type]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/spirv_type.rs
[libm]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/builder/libm_intrinsics.rs
[naga-transpile]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/naga_transpile.rs
[target]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/src/target.rs
[backend-readme]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/rustc_codegen_spirv/README.md
[std-lib]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/src/lib.rs
[vector]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/src/vector.rs
[matrix]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/src/matrix.rs
[derivative]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/src/arch/derivative.rs
[typed-buffer]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/src/typed_buffer.rs
[runtime-array]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/src/runtime_array.rs
[macros]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/crates/spirv-std/macros/src/lib.rs
[sky]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/examples/shaders/sky-shader/src/lib.rs
[cpu-runner]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/examples/runners/cpu/src/main.rs
[difftests]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/tests/difftests/README.md
[t-452]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/tests/compiletests/ui/lang/issue-452.stderr
[t-764]: https://github.com/Rust-GPU/rust-gpu/blob/57d07949423593dd701a77d9a78acb4ff7ed943e/tests/compiletests/ui/lang/control_flow/issue_764.stderr
[transition]: https://rust-gpu.github.io/blog/transition-announcement/
[every-gpu]: https://rust-gpu.github.io/blog/2025/07/25/rust-on-every-gpu/
[shadertoys]: https://rust-gpu.github.io/blog/2025/04/10/shadertoys/
[rust-cuda-blog]: https://rust-gpu.github.io/blog/2025/01/27/rust-cuda-reboot/
[spirt]: https://github.com/rust-gpu/spirt
[vcc-shady]: ./vcc-shady.md
[circle]: ./circle.md
[zig-spirv]: ./zig-spirv.md
[dcompute]: ./dcompute.md
[naga]: ./naga.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[sparkles-spec]: ../../specs/shaders/SPEC.md
[sparkles-decisions]: ../../specs/shaders/decisions.md
