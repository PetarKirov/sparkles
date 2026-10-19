---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — Specification

> [!IMPORTANT]
> This is a revision under Stage 0 review, widening the library from
> fragment shaders for OpenGL to a single-source replacement for the shading
> languages. Until it is accepted, the shipped behaviour is governed by the
> [accepted specification of 2026-10-16](https://github.com/PetarKirov/sparkles/blob/d4f64961ca9b40f0d72d77aa8155048c1e88ab3a/docs/specs/shaders/SPEC.md);
> requirements carried over unchanged keep their identifiers and wording, and
> each revised one is marked.

## Abstract

`sparkles:shaders` lets a D program write its GPU shaders in D, once, and run
their logic in two places: on the GPU, as the shader stages of a graphics
pipeline, and on the CPU, where any D compiler calls the same functions. It
provides the types and built-in functions shaders are written against, entry
points for the pipeline's stages, the resources a shader reads, and a build
step that compiles a package's shaders for each target it declares — SPIR-V
for Vulkan, GLSL for OpenGL and OpenGL ES — checking at compile time that each
uses only what its target offers. Its GPU half needs LDC, the LLVM-based D
compiler, extended with graphics stages. Only a build that generates shaders
needs that compiler.

## 1. Introduction

Programs that draw the same interface on very different surfaces need effects
and rendering that behave the same on each. A colour transform may run as a
fragment shader in a GPU window, as a function called once per character cell
in a terminal, and as a function applied to a few known inputs in a test. A
renderer that draws through Vulkan on one platform and OpenGL ES on another
needs the same shader for both. The usual answer is several implementations —
a GLSL file, an HLSL file, a fallback in the host language — that drift apart,
and resource layouts kept in sync with host structs by hand.

The shading languages do not close that gap. Each serves its own API: GLSL for
OpenGL and Vulkan, HLSL for Direct3D, MSL for Metal, WGSL for the web, Slang
across several of them. None shares code with the program that drives it, and
none runs on the CPU with its GPU semantics. Host languages that compile their
own code for the GPU (Rust, C++, Zig, Julia, C#) show that one source is
possible, but each leaves a part undone: memory layouts left to the user,
GPU-only operations that do nothing on the CPU, or a back end that cannot
structure ordinary control flow ([research catalog](../../research/shading-languages/index.md)).

This library writes shaders as [single-source
shaders](../../glossary.md#single-source-shader): D modules marked as device
code, over a [vocabulary](../../glossary.md#shader-vocabulary) of vector types
and built-ins that compute the same results on both sides. An entry point is
an ordinary D function marked with its stage; its parameters are its inputs,
its resources and its built-in variables, and its result is its outputs. The
device compilation goes through LDC's dcompute and its Vulkan target, extended
by a fork with graphics stages, to SPIR-V, which the build step validates,
translates where a target needs source (GLSL for OpenGL), and validates again.
Each output is a [profile](./profiles.md): a target and the capabilities it
grants. A shader declares its profiles beside its entry points; the build step
compiles it once per profile, with the profile a compile-time constant that D
code branches on; and the compiler and the build step reject any use of a
capability the profile lacks, at the D source line. Resources are declared
once in D and lowered per profile — a block with a binding for Vulkan, named
uniforms for OpenGL — with the byte layout the host writes computed from the
same declaration. The generated shaders are build products, never committed;
a developer's build regenerates them behind a [freshness
stamp](../../glossary.md#freshness-stamp), and a packager (here, the Nix
build) builds them once and hands them to every build, which then needs no
custom compiler.

The scope of this revision is the vertex and fragment stages, for Vulkan,
OpenGL 3.3 and OpenGL ES 2.0, with uniforms, uniform blocks, push constants
and sampled images; its first consumer is the triangle of
`sparkles:vulkan-wsi`. The library's goal is wider — every stage and feature
of the shading languages, further targets (GLSL 4.60, GLSL ES 3.x, HLSL, MSL,
WGSL, and DXIL later), a CPU executor that runs subgroup, quad and derivative
semantics — and the [delivery plan](./PLAN.md) orders it; each later contract
is refined before it is implemented. Outside the library altogether is
anything that draws: pipelines, descriptor writes, render passes and texture
binding belong to the consumer's renderer, which this library hands complete
shaders, their bindings and their layouts. Runtime compilation is outside it,
because the device compiler is a build-time tool. The compiler is a pinned
dependency: this specification states what it requires of the compiler, not
how the compiler implements it. Editor diagnostics for shader code are
specified by `sparkles:dmd-lsp` ([target profiles](../dmd-lsp/targets.md)).
[`decisions.md`](./decisions.md) records each exclusion with what would bring
it in.

Section 2 lists the terms, section 3 states the contract at a glance, and
section 4 maps the topic pages that hold the requirements.
[`testing.md`](./testing.md) names the oracle and scenarios for each
requirement and holds the evidence ledger, [`PLAN.md`](./PLAN.md) orders
delivery and tracks progress, and [`decisions.md`](./decisions.md) records the
consequential choices and open questions.

## 2. Terminology

The terms this specification coins, or uses in a narrower sense than usual,
are defined once in the [glossary](../../glossary.md) and listed here:

<GlossaryList owner="sparkles:shaders" />

[Profiles](./profiles.md#terms) defines _capability_, _profile_, _active
profile_ and _requirement_. GPU terms follow their standards and the
[research catalog's concepts](../../research/shading-languages/concepts.md):
[SPIR-V](https://registry.khronos.org/SPIR-V/) is the Khronos intermediate
language for shaders; GLSL is the OpenGL Shading Language, at version 3.30
for OpenGL 3.3 and [ES
1.00](https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf)
for OpenGL ES 2.0. dcompute's terms keep their meaning: the _host_ is the CPU
side of a program, the _device_ the GPU side.

## 3. The contract at a glance

1. **One source.** A shader's logic is D. Its CPU behaviour and its GPU
   shaders derive from the same functions; none is written separately.
2. **One meaning.** Every vocabulary operation computes the same result on
   the host and the device, within the bounds of `SHV7`.
3. **Device code is opt-in by target.** Without a GPU compilation target the
   vocabulary is plain D: no device rules apply and no special compiler is
   needed.
4. **One unit per package, one compilation per profile.** A package's shader
   modules, with those of its dependencies, compile together, once for each
   profile its entry points declare.
5. **What a target lacks is a compile-time error.** A use of a capability the
   active profile does not grant fails the build at the D source line that
   reaches it.
6. **Declared once, lowered per target.** A resource is declared once, in D;
   each profile gets the form it can express, and the host's byte layout comes
   from the same declaration.
7. **Generated, never committed.** Generated shaders are build products. The
   build that ships them is a Nix derivation, which regenerates them exactly
   when an input changed, the toolchain included.
8. **No compiler unless asked.** A consumer that does not opt in needs only
   its ordinary D compiler.
9. **Complete, validated output.** Every generated file is a whole shader that
   its target's reference validator accepts.

## 4. Requirements

| Page                                  | Holds                                                                          | IDs                           |
| ------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------- |
| [Vocabulary](./vocabulary.md)         | vector types, constructors, component access, built-in functions, agreement    | `SHV1`–`SHV10`                |
| [Device modules](./device-modules.md) | which modules are shader code; the device compilation's rules                  | `SHM1`–`SHM5`                 |
| [Entry points](./entry-points.md)     | stages, parameters, built-in variables, outputs, linking stages, handles       | `SHF1`–`SHF9`                 |
| [Resources](./resources.md)           | uniforms, blocks, push constants, images, interface structs, layout, bindings  | `SHR1`–`SHR8`                 |
| [Profiles](./profiles.md)             | capabilities, profiles, `@profiles`, the manifest, the three capability checks | `SHC1`–`SHC10`                |
| [Build step](./build.md)              | the build step, its outputs and outcomes; the stamp and build integration      | `SHP1`–`SHP10`, `SHB1`–`SHB7` |
| [Toolchain](./toolchain.md)           | the pinned compiler and tools, reproducibility, platforms                      | `SHT1`–`SHT4`                 |
| [CPU executor](./executor.md)         | the outline of the executor that runs GPU semantics on the CPU                 | `SHX1`–`SHX3`                 |

Identifiers are stable: a requirement keeps its identifier when it moves
between pages, and a retired one is not reused.
