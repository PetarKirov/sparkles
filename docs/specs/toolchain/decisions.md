---
status: draft
owner: sparkles
reviewed: 2026-10-26
---

# The Sparkles toolchain — Decisions

Consequential choices behind the [specification](./SPEC.md), each with the
question it answers, the alternatives, the evidence, and the conditions for
revisiting it. Decision states are `proposed`, `accepted` or `superseded`;
they say nothing about implementation progress, which [PLAN.md](./PLAN.md)
tracks.

## TCD1: One fork for every target

_State: accepted._

**Question.** Should the shader compiler, the WebAssembly compiler and the
host compiler stay separate builds?

**Alternatives.** Keep a stock LDC for the host, a WASI fork of LDC on its own
LLVM, and a Vulkan fork on a patched LLVM; or one fork of each project
carrying every change.

**Evidence.** The separate builds put three LDCs and three LLVMs in one
development closure. The WASI fork's twelve commits were all superseded by
upstream LDC, and the remaining WASI gap was one missing test. The stock host
compiler's closure was 1.4 GiB, of which its bootstrap compiler and LLVM 18
libraries made up most.

**Choice.** One LDC fork and one LLVM fork, each rebased on upstream, for
every target (TC1, TC2).

**Revisit when** a target needs a compiler change that conflicts with another
target's.

## TCD2: Upstreaming after production use

_State: accepted._

**Question.** When should the fork commits be proposed upstream?

**Choice.** After the terminal, hue, font-explorer and the shaders packaged
for other projects ship on the toolchain, so the changes arrive with
real-world validation. Until then each change stays an atomic commit with a
regression test (TC3), ready to submit.

**Revisit when** an upstream release would make a fork commit redundant, or a
maintainer asks for one of the changes.

## TCD3: Sparkles' nixpkgs drives the toolchain

_State: accepted._

**Question.** dlang.nix pinned a nixpkgs fourteen months older than
Sparkles'. Which nixpkgs should the toolchain use?

**Alternatives.** Keep them separate; make dlang.nix pin Sparkles' revision;
or let Sparkles override dlang.nix's nixpkgs input.

**Evidence.** Separate pins put two glibc versions and two GCC runtimes into
applications (`hue` loads GCC 14's `libgcc_s` and GCC 15's `libstdc++`), and
the glibc split required a wrapper that parses `-mtriple` to keep host linker
flags off cross links.

**Choice.** Sparkles' flake makes dlang.nix's nixpkgs follow its own (TC4).
dlang.nix keeps an independent pin for its other users and is moved to the
same nixos-unstable revision when it updates. Both move to the latest
nixos-unstable ahead of the LLVM rebuild of TC-M3, for its newer GCC and its
native `wasm32-wasip1` platform.

**Trade-off.** Toolchain builds no longer match dlang.nix's own cache;
Sparkles' binary cache carries them (TC23).

## TCD4: The C compiler is the fork's clang

_State: accepted._

**Question.** Which C/C++ compiler should toolchain packages use?

**Evidence.** The LLVM fork already builds clang, for the WASI runtime. A
prototype wrapped it with nixpkgs' compiler wrapper without rebuilding LLVM;
C, C++20 (`<format>`) and, on macOS, Objective-C with Foundation and
`__builtin_available` compiled and ran on x86_64-linux and aarch64-darwin. The
unwrapped clang on LDC's search path broke LDC's macOS build because the
standard environment calls its compiler `clang++`.

**Choice.** `clang-sparkles`, a wrapper over the fork's clang, and a stdenv
built from it (TC6, TC8). The LLVM package exposes libraries and
`llvm-config` through an output with no compiler drivers (TC7).

## TCD5: Compiler-rt ships with the compiler

_State: accepted._

**Question.** Is building compiler-rt worth it when Linux programs use
`libgcc` for builtins?

**Evidence.** Without compiler-rt, LDC's `-fsanitize=address` on Linux falls
back to GCC's `libasan`, macOS has no sanitizer runtime, and
`-fprofile-instr-generate`, `-fsanitize=fuzzer` and `-fxray-instrument` do not
link. Profile data is versioned with LLVM, so only a matching runtime works
with the toolchain's `llvm-profdata` and `llvm-cov`.

**Choice.** Build compiler-rt from the fork and install it into LDC and
`clang-sparkles` (TC10–TC12). Builtins replace `libgcc` only in the profile of
TCD6.

## TCD6: An all-LLVM runtime profile

_State: accepted._

**Question.** Should D programs link compiler-rt, libunwind and libc++
instead of `libgcc`, `libgcc_s` and `libstdc++`?

**Evidence.** For the default build the gain is small: C++ libraries from
nixpkgs are built with GCC and load `libgcc_s` anyway, and glibc loads it for
thread cancellation, so mixing a second unwinder into one process risks
exceptions and backtraces that cross languages. Fully static builds, where
every dependency is compiled by the same clang against libc++, avoid the mix
and drop the GCC runtime from the closure.

**Choice.** Keep `libgcc` and `libstdc++` by default; provide an opt-in
profile with LLVM's runtimes and build the three applications statically
under it (TC18–TC20).

## TCD7: WASI previews 1, 2 and 3

_State: accepted._

**Choice.** Build every WASI library from source (TCW1); previews 1 and 2 are
production targets and preview 3 is experimental and allowed to fail
(TCW2), so that its progress in wasi-libc is followed rather than waited for.

**Evidence.** A prebuilt WASI SDK provides only the previews it was released
with, and its link-time-optimization libraries cannot be used with LLVM 24.

## TCD8: LLVM assertions

_State: proposed; decided in TC-M3._

**Question.** Should the toolchain's LLVM keep its internal assertions?

**Evidence.** Assertions cost about 10 % in optimized D builds (`:base` in the
checked build type, 17.2 s to 18.8 s) and turn SPIR-V backend defects into
reports.

**Alternatives.** One assertions-enabled toolchain for every use; or a
release variant for every default build step, shaders included, with an
assertions-enabled variant reachable only from an opt-in shell for
debugging the SPIR-V backend.

**Decision rule.** Adopt the pair only if the checked variant can be kept
out of every default closure and the two variants share no build step that
would pull both into one closure; otherwise keep one assertions-enabled
toolchain (TC17). TC-M3 records the measurement and the outcome here.

## TCD9: Target set

_State: accepted._

**Choice.** LLVM is built for `AArch64`, `X86`, `SPIRV` and `WebAssembly`
(TC2), not `host`: naming the targets gives every build host the same
compiler and covers Android devices, Android emulators and Windows cross
builds from each host. `ARM` and `NVPTX` are left out; nothing in Sparkles
targets 32-bit ARM Android or CUDA.

**Revisit when** 32-bit Android devices or dcompute's CUDA target become
targets.

## TCD10: Fork inputs fetched as Git checkouts

_State: accepted._

**Evidence.** llvm-project marks `clang/bindings/python/.git_archival.txt`
with `export-subst`, so GitHub rewrites it in every tarball, and Nix 2.32 and
2.35 computed different hashes for the same revision. A shallow Git checkout
hashes the commit's tree, with the same result on both.

**Choice.** TC5.

## Open questions

- **Q1: Runtimes in or out of the LLVM build.** Build compiler-rt, libunwind
  and libc++ inside the LLVM build or as separate derivations against it;
  decided by measured build time in TC-M3. Affects TC9–TC10, TC18.
- **Q2: musl.** Whether the static builds of TC20 also target musl, which
  needs a druntime build for musl and dependencies from nixpkgs' musl set.
  Decided after TC-M4.
- **Q3: Preview 3 readiness.** When wasi-libc and the component linker
  support preview 3 well enough to promote it to production (TCW2). Reviewed
  at each WASI toolchain update.
- **Q4: Browser components.** Whether the documentation site moves its
  modules from preview 1 to components, which browsers run only through a
  transpiler. Out of scope until a site component needs a preview 2 interface.
- **Q5: The native Windows test leg.** CI tests Sparkles on Windows outside
  Nix with a released LDC, which TC1 exempts. Whether Windows gets the fork,
  through a cross build or a native package, is undecided; until then
  Windows results do not count as evidence for this specification.
