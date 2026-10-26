---
status: draft
owner: sparkles
reviewed: 2026-10-26
---

# The Sparkles toolchain — WASI

The [WebAssembly System Interface](https://wasi.dev/) is versioned in
_previews_: preview 1 (`wasip1`) is a set of imported functions, preview 2
(`wasip2`) defines programs as components of the
[component model](https://component-model.bytecodealliance.org/), and
preview 3 (`wasip3`) adds asynchronous component interfaces. A D program that
targets WASI needs a C library, a C++ library, compiler builtins, druntime
and Phobos for the preview it targets, and a linker that produces the module
or component that preview's hosts load. This page specifies that part of the
toolchain; it is part of the [specification](./SPEC.md) and shares its pins.

## 1. Contract at a glance

1. Every WASI library is built from source by the toolchain's clang; nothing
   is taken from a prebuilt SDK.
2. Preview 1 and preview 2 are production targets; preview 3 is experimental
   and allowed to fail.
3. Each preview has its own sysroot, D runtime and compiler driver; one
   preview's libraries never link into another's program.
4. Link-time optimization works across D, C and C++ for every preview.
5. The D runtimes' own test suites run under a WASI host in Nix.

## 2. Sysroots

**TCW1: Built from source.** For each preview of TCW2, the toolchain **must**
build the C library ([wasi-libc](https://github.com/WebAssembly/wasi-libc)),
libc++ and libc++abi, and compiler-rt's `wasm32` builtins with the clang of
[TC6](./SPEC.md#_3-compilers-and-wrappers), from pinned revisions. The
toolchain **must not** depend on a prebuilt WASI SDK archive.

_Rationale:_ Prebuilt link-time-optimization libraries are usable only with
the exact LLVM that built them, and a prebuilt SDK fixes the preview set and
the release cadence.

**TCW2: Previews.** The toolchain **must** provide sysroots for `wasm32-wasip1`
and `wasm32-wasip2`. It **must** also define a `wasm32-wasip3` sysroot, built
from wasi-libc's development branch, as an _experimental_ package: a
separate output that no aggregate build, cache requirement
([TC23](./SPEC.md#_8-platforms-tests-and-caches)) or default shell depends
on, whose build and test result for each toolchain revision is recorded in
[testing.md](./testing.md#preview-3) whether it passes or fails.

**TCW3: LTO variants.** Each sysroot **must** include link-time-optimization
builds of its C library and C++ library, usable by the toolchain's LLVM. In a
D program linked with `-flto=full`, a small C function from the sysroot
called from D **must** be inlined, observable as the absence of a call to it
in the module's text form (`wasm-tools print`).

**TCW4: Separate per preview.** A link for one preview **must** resolve the C
library, C++ library, builtins and D runtime of that preview only.

## 3. Drivers and linking

**TCW5: Compiler drivers.** For each preview `N` of TCW2 the toolchain
**must** provide `wasm32-wasipN-clang` and `wasm32-wasipN-clang++`, wrapped
versions of the TC6 clang configured with that preview's target, sysroot and
resource directory. LDC's configuration **must** select the matching driver
as its C compiler and as its linker driver for the preview's triple, and
every WASI link **must** go through that driver, which supplies the start
files, the sysroot and the component step. LDC's internal linker is used
only for bare `wasm32` without a runtime.

**TCW6: Components.** Links for `wasip2` and `wasip3` **must** produce
components, through
[`wasm-component-ld`](https://github.com/bytecodealliance/wasm-component-ld)
built from source, and the result **must** validate with `wasm-tools`.

**TCW7: Initialization.** For `wasip1`, a program **must** be linkable as a
_reactor_: a module without `_start`, whose host calls the exported
`_initialize` once before any other export, and whose `_initialize` runs
druntime's initialization and the program's module constructors. For
`wasip2` and `wasip3`, a component that exports functions **must** run
druntime's initialization and the module constructors exactly once, before
the first exported function runs; component hosts do not call
`_initialize`.

## 4. D runtimes

**TCW8: One runtime per preview.** druntime and Phobos **must** be built for
each preview of TCW2 from the LDC fork's sources, with link-time-optimization
variants, and installed so that LDC's configuration selects them by triple.

**TCW9: Exceptions and the garbage collector.** On each production preview, a
D program **must** be able to throw and catch exceptions, run module
constructors, and allocate with the garbage collector, with no workaround in
the program. Exceptions **must** use the standardized encoding of the
WebAssembly [exception-handling proposal](https://github.com/WebAssembly/exception-handling)
(`exnref`, `try_table`), which LLVM emits with `-wasm-use-legacy-eh=false`,
and never the legacy encoding. The hosts that run these programs are the
wasmtime of TCW10 and the browsers the documentation site supports; both
**must** implement that encoding, and [testing.md](./testing.md) records the
versions checked.

**TCW10: Runtime test suites.** The druntime and Phobos unittest runners
**must** build for each production preview and run under
[wasmtime](https://wasmtime.dev/), from Sparkles' nixpkgs, in Nix. A runner
that does not build fails the check. Known failures **must** be listed in
[testing.md](./testing.md#known-failures) by test name, with cause, toolchain
revision and preview; an unlisted failure fails the check, and so does a
listed failure that passes, so the list only shrinks.

**TCW11: Compile-time evaluation independent of the host.** Compile-time
evaluation of `real` arithmetic for a target whose `real` is IEEE quadruple
precision **must** give the same result on every host, whatever the host's
own `real` is: the x87 80-bit format on x86, or `double` on aarch64 macOS.

_Rationale:_ Phobos' unittests assert compile-time results; folded with x87
precision on an x86_64 host, they fail the build for WebAssembly.
