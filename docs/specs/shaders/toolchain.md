---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — Toolchain and platforms

The pinned compiler and tools, and where they run. The requirements are the
accepted contract of 2026-10-16, with `SHT1` naming the pins of #659. This page
is part of the [specification](./SPEC.md).

**SHT1: Pinned compiler.** The device compiler is LDC with dcompute's Vulkan
target ([ldc-developers/ldc#5132](https://github.com/ldc-developers/ldc/pull/5132))
and the fragment stage of section 6, at
[`PetarKirov/ldc@64104a9a`](https://github.com/PetarKirov/ldc/tree/64104a9a6da522730d6b661b85adfdfd2e7e25e7).
It is built against LLVM at
[`27ba4937`](https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3),
with the SPIR-V backend, the Vulkan fixes of
[llvm/llvm-project#216919](https://github.com/llvm/llvm-project/pull/216919),
and this project's patches (signed integers by module flag with struct
member names; 32-bit access-chain indices; buffer device addresses by module
flag, with the access chains, strides and alignment Vulkan requires; no
`Int8` for a resource's name; a terminating `discard`; and merge blocks for
nested conditions that share an exit), whose upstreaming is tracked in
[#647](https://github.com/PetarKirov/sparkles/issues/647).
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
