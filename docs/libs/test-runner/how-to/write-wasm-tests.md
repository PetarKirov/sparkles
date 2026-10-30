# Write WebAssembly (`@wasm`) tests

`@wasm` marks a test that must also pass as WebAssembly. Such tests run
normally under `dub test`; `--wasm` additionally extracts them, compiles them
for `wasm32-unknown-wasip1` with the full druntime and Phobos of the
toolchain's [WASI runtime](../../../specs/toolchain/wasi.md), and runs the
program under `wasmtime`:

```console
$ dub test :base -- --wasm
 > grapheme.visibleWidth.plainAndStyled [libs/base/src/sparkles/base/text/grapheme.d:748]
 > grapheme.visibleWidth.unicode [libs/base/src/sparkles/base/text/grapheme.d:757]
 > grapheme.byGraphemeCluster.slicesAndKinds [libs/base/src/sparkles/base/text/grapheme.d:767]
 > grapheme.byGraphemeCluster.unclustered [libs/base/src/sparkles/base/text/grapheme.d:780]
4 @wasm tests passed
```

The program announces each test and runs it, catching what it throws, so a
failing test is reported with the file, line and message of its
`AssertError` (or exception) and the rest still run. Exceptions, module
constructors and the garbage collector all work: `sparkles:table-wasm`'s
`@wasm` tests render tables, which reads a table seeded by a module
constructor and allocates, and check the error codes of invalid input,
which `std.json` reports by throwing.

## Toolchain requirements

- **An LDC with the WASI runtime.** `--wasm` takes `--compiler`, then
  `$SPARKLES_WASI_LDC` (the dev shell and the `ci` package set it to
  dlang.nix's `ldc-sparkles`), then `$DC`. It links through the runtime's
  compiler driver, so no `wasm-ld` is needed on `PATH`.
- **`wasmtime`** on `PATH` (in the dev shell).

A compiler that cannot link a `wasm32-unknown-wasip1` program, or a missing
`wasmtime`, is reported as a skip naming the missing piece; with
`--require-toolchain` (as `ci --test-extracted` runs it) the skip fails the
run.

## Constraints

As with [`@betterC` extraction](./write-betterc-tests.md), the test body is
compiled outside its module, so it sees only public symbols — import what it
uses inside the test. Every module the tests import is compiled in (`-i`),
with the package's `-preview` switches as `dub describe` reports them;
`@wasm(selfContained: true)` keeps a test's owning module out, and
`--no-auto-include` compiles nothing in. What a module uses must exist on
WASI: no threads, fibers or processes.

## Bare `wasm32`: `--wasm-bare`

`--wasm-bare` is the earlier mode: the same tests compiled for bare
`wasm32-unknown-unknown` with `-betterC` (no druntime), linked by LDC's
internal linker, and run by a generated JavaScript shim under `node`, `deno`
or `bun`, or per test under `wasmtime --invoke run_test_<i>`. A failed
`assert` traps, which the host reports as that test's `RuntimeError`.
Everything from `@betterC` extraction applies, and the tested module's whole
import chain must compile for bare `wasm32`, whose druntime headers reject
most of `core.stdc`. `--wasm` and `--wasm-bare` are mutually exclusive.
