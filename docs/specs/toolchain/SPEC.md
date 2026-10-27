---
status: draft
owner: sparkles
reviewed: 2026-10-26
---

# The Sparkles toolchain — Specification

## Abstract

Sparkles builds everything it ships with a single D compiler: native
programs for Linux and macOS, Android libraries, WebAssembly modules for
browsers and WASI hosts, and the D side of its Vulkan shaders. That compiler is one LDC
built on one LLVM, and the C and C++ that the toolchain compiles use the clang
of that same LLVM. The toolchain ships the runtimes its compiler flags rely on —
sanitizers, profiling, fuzzing, and a WASI sysroot for each WASI preview —
and stays out of the programs it builds: a shipped program's runtime
dependencies include no compiler and no duplicate C or C++ runtime library.

## Introduction

A project that targets the desktop, phones, browsers and GPUs usually
assembles one toolchain per target: the distribution's compiler for the host,
a vendor SDK for Android, a separately released SDK for WebAssembly, and a
patched compiler for shaders. Each comes with its own LLVM, its own C
compiler, its own idea of which runtime libraries exist, and its own release
cadence. A fix in one does not reach the others, a flag that works on one
target silently fails on another, and every program's
[closure](https://nix.dev/manual/nix/stable/glossary#gloss-closure) — the
set of Nix store paths it needs at run time — drags along whichever of them
its build happened to touch.

Sparkles' D code depends on compiler work that upstream LDC and LLVM do not
carry, of the kinds a multi-target project accumulates: a GPU target
([dcompute](https://github.com/libmir/dcompute)'s Vulkan target) and the
SPIR-V backend fixes its shaders need, support for the newest LLVM, fixes to
WebAssembly exception handling and to the C importer, and thread-local
storage scanning on Android's C library, Bionic. Keeping that work on
several compilers would multiply both the maintenance and the ways the
targets can disagree. The toolchain therefore has one source of truth for
each layer: a fork of LDC and a fork of LLVM, each one branch of atomic
commits rebased on its upstream, packaged by
[dlang.nix](https://github.com/PetarKirov/dlang.nix), a Nix flake for D
toolchains, against the same nixpkgs as Sparkles itself.

Everything else is derived from those two forks rather than downloaded beside
them. The C/C++ compiler is the fork's clang behind nixpkgs' compiler
wrapper, which supplies the C library's headers, the C++ library, the macOS
SDK and the run-time library paths. Compiler-rt, libunwind and libc++ are
built from the fork's sources. A [WASI](https://wasi.dev/) system root —
libc, the C++ library, compiler builtins, and link-time-optimization builds
of each — is built by that clang for each WASI _preview_, the standard's
versioned interface sets. Only the wrapped tools are ever placed on a
build's search path, so no build can pick up the bare compiler, which lacks
all of that, by name.

This specification owns the toolchain's composition, its pinned revisions,
the runtimes it provides, the closure guarantees it gives the native and
Android programs Sparkles ships, and the tests each toolchain output must
pass before it is relied on. It does not own what the compiler does with D
code: the shader contract, including the SPIR-V tools that follow the
compiler, belongs to [`sparkles:shaders`](../shaders/toolchain.md), the
test runner's execution modes to
[`sparkles:test-runner`](../test-runner/SPEC.md), and each application's
packaging to its own specification. Proposing the fork commits upstream is
out of scope until Sparkles' production applications ship on them
([TCD2](./decisions.md#tcd2-upstreaming-after-production-use)). dlang.nix
remains a general-purpose flake; obligations here bind the packages Sparkles
consumes from it, not its other users.

After the contract at a glance (§1), sections 2–8 define the pins, the
compilers and their wrappers, the runtimes, the closure guarantees, whether
LLVM's internal assertions are enabled, an opt-in profile that links LLVM's
own runtime libraries in place of GCC's, and platform coverage.
[wasi.md](./wasi.md) specifies the WASI toolchain and
[wasm-modules.md](./wasm-modules.md) the WebAssembly modules the
documentation site embeds. [PLAN.md](./PLAN.md) orders delivery and tracks
the catalogue of known WebAssembly shortcuts being repaid,
[testing.md](./testing.md) owns acceptance scenarios and evidence, and
[decisions.md](./decisions.md) records the choices behind this contract.

## 1. Contract at a glance

1. One LDC, one LLVM, one clang, one nixpkgs: every Nix-built target and
   every C/C++ build step uses them.
2. Fork changes are atomic commits on branches kept rebased on upstream.
3. No unwrapped C/C++ compiler or host linker is reachable by name from a
   build or a development shell.
4. Every runtime a supported compiler flag requires ships with the compiler,
   built from the fork's sources.
5. Shipped programs reference no toolchain store path, and at most one C
   library and one C++ runtime.
6. Each toolchain output has a test that Nix runs; a build that is not tested
   is not supported.
7. The toolchain is built and cached for every supported host before Sparkles
   depends on a new revision of it, and the outputs costliest to rebuild stay
   pinned in that cache, one revision each.

Bold **must**, **must not**, **should** and **may** carry the meanings of
[BCP 14](https://www.rfc-editor.org/info/bcp14); **should** names its
exception policy where it is used.

## 2. Pins and provenance

**TC1: One compiler fork.** Every D compilation in Sparkles' Nix builds and
development shells — shipped programs, examples, shaders, Android libraries
and WebAssembly modules — **must** use an LDC built from the revision of the
`sparkles/main` branch of
[PetarKirov/ldc](https://github.com/PetarKirov/ldc)
that Sparkles' `flake.lock` pins through its `dlang-nix` input. No such build
**may** use a different LDC, including a released one. Two compilations are
outside this requirement: DMD, which builds and tests Sparkles as a second
compiler to keep the code portable across D compilers, and the native
Windows test leg, which runs outside Nix with a released LDC
([Q5](./decisions.md#open-questions)).

_Rationale:_ A second LDC doubles the surface on which a fix must land and
lets targets disagree about the language; DMD stays because it checks the
code, not the toolchain.

**TC2: One LLVM fork.** That LDC, the C/C++ compiler of §3, and every runtime
of §4 **must** be built from the revision of the `sparkles/main` branch of
[PetarKirov/llvm-project](https://github.com/PetarKirov/llvm-project)
that the same lock pins, built for the targets `AArch64`, `X86`, `SPIRV` and
`WebAssembly`.

**TC3: Atomic fork commits.** Each change carried by either fork **must** be
one commit on its branch whose message states the defect or capability, and
the branch **must** apply as a linear series on a named upstream revision.
A change to behavior **must** come with a regression test in the fork's own
test suite. A change that only keeps the fork building — a new upstream API,
a build option — is exempt when its message says so; the build is its test.

_Rationale:_ Atomic commits are what make a later upstream submission or
removal a per-change decision instead of an archaeology project.

**TC4: One nixpkgs.** The toolchain packages Sparkles consumes **must** be
evaluated against Sparkles' own nixpkgs revision (the flake input of
dlang.nix follows Sparkles'), so the toolchain and the applications share
one C library, one GCC runtime and one set of system libraries.

**TC5: Fetched by commit.** Flake inputs for the forks **must** be fetched in
a way whose content hash is independent of the Nix version and of GitHub's
archive generation. Inputs of repositories that use `export-subst`
attributes **must** be fetched as Git checkouts, not as GitHub tarballs.

_Rationale:_ GitHub expands `export-subst` placeholders when it builds a
tarball, and two Nix versions hashed the LLVM fork's tarball differently.

## 3. Compilers and wrappers

**TC6: One clang.** C, C++ and Objective-C compilation inside toolchain
packages and Sparkles' builds **must** use the clang built by TC2, wrapped by
nixpkgs' compiler wrapper (`clang-sparkles`), and a stdenv built from that
wrapper **must** be exported for packages that compile C or C++. Its default
C++ library is the platform's: GCC's `libstdc++` from the same nixpkgs on
Linux, and libc++ on macOS.

**TC7: No unwrapped compilers on PATH.** The build environment of a toolchain
package, of a Sparkles package, and every Sparkles development shell **must
not** resolve the names `clang`, `clang++`, `cc`, `c++`, `ld`, `ld.lld` or
`ld64.lld` to an unwrapped tool. Packages that need LLVM's libraries or
`llvm-config` **must** depend on an output that contains no compiler or
linker driver. `wasm-ld` is exempt: WebAssembly links have no host library
paths to supply, and the WASI drivers of [wasi.md](./wasi.md) supply the
sysroot.

_Rationale:_ The unwrapped compiler lacks the C library headers, the C++
library, the SDK and the rpaths that the wrapper adds; found first by name,
it fails builds in ways that look unrelated to the toolchain.

**TC8: LDC's own toolchain.** LDC's C++ sources and its runtime's C sources
**must** be compiled by `clang-sparkles`, and the C compiler LDC invokes to
link host programs by default **must** be `clang-sparkles`.

**TC9: Toolchain size.** The compiler, linker and C/C++ tools **must** share
one LLVM shared library rather than each linking LLVM statically, and the
installed toolchain **must** contain only the LLVM tools listed in
[testing.md](./testing.md#installed-tools), each with the Sparkles step that
uses it. LDC, which links LLVM into its own executable, **may** link it
statically.

## 4. Runtimes

**TC10: Compiler-rt with the compiler.** The LDC of TC1 and `clang-sparkles`
**must** ship the compiler-rt runtimes built from the LLVM fork of TC2 for
their host: builtins, the profile runtime, libFuzzer, and every sanitizer
runtime and XRay that compiler-rt's build supports on that host. The set
built for each host is recorded in
[testing.md](./testing.md#runtimes-per-host); a runtime in that set is
required, not optional.

**TC11: Flags link with their runtimes.** On each supported host, a D
program compiled by the LDC of TC1 with a flag whose runtime TC10 builds for
that host — `-fsanitize=address`, `-fsanitize=fuzzer`,
`-fprofile-instr-generate`, `-fxray-instrument` and the other sanitizers —
**must** link against that runtime, without falling back to another
compiler's runtime, and the program **must** run and detect the defect its
test plants.

**TC12: Profile data round trip.** Profile data written by a program built
with `-fprofile-instr-generate` **must** be accepted by the `llvm-profdata`
and `llvm-cov` of the same LLVM, and an LDC build with `-fprofile-instr-use`
**must** accept the merged profile.

## 5. Closure

A _shipped program_ is a program Sparkles publishes for end users: the
`terminal`, `hue`, `diagram` and `ui-gallery` applications, the standalone
examples, the Android packages, and the WebAssembly modules of
[wasm-modules.md](./wasm-modules.md). Developer tools that drive a compiler
at run time — `ci`, `shader-compile`, `twoslash-extract` and the development
shells — are not shipped programs.

**TC13: No toolchain in shipped programs.** The runtime closure of every
shipped program **must not** contain the LDC, LLVM, clang, compiler-rt,
WASI sysroot or dlang.nix bootstrap compiler store paths, in any form,
including strings embedded by assertions and `__FILE__`.

**TC14: One C library and one C++ runtime.** On Linux, the runtime closure of
a shipped program **must** contain at most one glibc and at most one GCC
runtime (`libgcc_s`, `libstdc++`), or, under the profile of §7, none of the
latter. On macOS, where the system provides the C library, it **must**
contain at most one libc++.

**TC15: Reproducible-path compilation.** The compiler **must** provide
`-ffile-prefix-map=OLD=NEW`, rewriting the prefix `OLD` to `NEW` in
`__FILE__`, `__FILE_FULL_PATH__` and debug information for every file it
reads, including druntime and Phobos sources reached through its own import
paths. Its configuration **must** map its own installation prefix to a fixed
store-independent name, and the toolchain's runtimes **must** be built with
that mapping, so that a shipped program satisfies TC13 with no removal of
references after linking.

**TC16: Measured sizes.** The closure sizes of the toolchain packages, the
development shells, `ci` and each shipped program **must** be recorded in
[testing.md](./testing.md) with the platform and revisions measured, and a
change that grows one of them by more than 5 % **must** state why in its
pull request.

## 6. Assertions

**TC17: Assertions policy.** The toolchain's LLVM **must** be built with its
internal assertions enabled, unless the release/checked pair of
[TCD8](./decisions.md#tcd8-llvm-assertions) is adopted. Under that pair, every
default build step — including the shader build that `gpu-effects` and
`shader-compile` run — **must** use the release variant, the checked variant
**must** be reachable only from an opt-in development shell, and neither
variant's closure **may** contain the other.

_Rationale:_ Assertions turn backend defects into reports instead of
miscompiles, at a measured cost of about 10 % in optimized D builds. A second
variant is worth carrying only if no default build pays for both.

## 7. The all-LLVM runtime profile

**TC18: Opt-in profile.** The toolchain **must** provide an opt-in link
profile in which D programs and their C/C++ dependencies use compiler-rt
builtins, LLVM's libunwind and libc++ in place of `libgcc`, `libgcc_s` and
`libstdc++`, built from TC2 by `clang-sparkles`.

**TC19: One unwinder per process.** A program linked under TC18 **must not**
load `libgcc_s` or a second unwinder. A D exception thrown through a C++
frame, and a C++ exception caught in D code that the language permits to
catch it, **must** propagate as in the default profile.

**TC20: Self-contained showcase builds.** `terminal` and `hue`, and
font-explorer once it is an application, **must** build under TC18 for
x86_64 and aarch64 Linux with every D, C and C++ dependency linked
statically, leaving dynamic only the C library and the libraries the
platform loads at run time (graphics drivers and their loaders, the window
system), and **must** pass their test suites. Their size and start-up time
**must** be recorded beside the default profile's.

## 8. Platforms, tests and caches

**TC21: Supported hosts.** The toolchain **must** build and pass its tests on
x86_64-linux, aarch64-linux and aarch64-darwin, and **must** cross-compile for
`aarch64` and `x86_64` Android, the WASI previews of [wasi.md](./wasi.md),
bare `wasm32` and the SPIR-V shader targets.

**TC22: Tested outputs.** Each toolchain package **must** expose a test that
Nix runs: LDC's driver and code-generation tests for the fork's targets and
its runtime test runners on each host; a compile-and-run check for
`clang-sparkles` in C, C++ and, on macOS, Objective-C; and the runtime checks
of TC11–TC12. A skipped test is not a pass.

**TC23: Cached before use.** Before Sparkles' lock file moves to a new
toolchain revision, the toolchain's outputs for every host of TC21 **must** be
available from Sparkles' binary cache, checked by querying the cache for each
output's store path. Experimental outputs (the preview 3 sysroot of
[TCW2](./wasi.md#_2-sysroots)) are excluded.

_Rationale:_ A cold toolchain build exceeds Sparkles' CI job limits, and a
cancelled build publishes nothing, so every retry starts cold.

**TC24: Pinned outputs.** The pin set **must** be the flake output
`legacyPackages.<system>.pinTargets` (`nix/pin-targets.nix`), an attribute
set from pin name to derivation: each entry the derivation Sparkles' builds
use, absent from cache.nixos.org, and expensive to rebuild. An entry is pinned
in Sparkles' Cachix cache as `<name>-<system>`, keeping exactly one revision.
The cache **must not** hold a pin outside the set. A package that can be
fetched or copied rather than compiled, such as a binary release or a copy of a
pinned output, **must not** be an entry.

_Rationale:_ The cache holds 10 GiB and evicts the paths accessed least
recently, so an unpinned output survives only while the cache has room. The
toolchain for three hosts and its heaviest dependents take a large share of
that, which leaves room for one revision of each and for CI's working set.
[TC23](#_8-platforms-tests-and-caches) needs the toolchain present when the lock
moves; TC24 keeps it present between moves.
