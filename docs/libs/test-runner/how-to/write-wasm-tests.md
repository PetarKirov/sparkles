# Write WebAssembly (`@wasm`) tests

`@wasm` marks a test for cross-compilation to `wasm32`. Such tests run
normally under `dub test`; `--wasm` additionally extracts them, compiles them
with LDC for `wasm32-unknown-unknown-wasm` (`-betterC`, no druntime), and
runs them with the first available WebAssembly-capable runtime:

```console
$ dub test :test-runner -- --wasm
 ✓ attributes.selfContained.wasm [libs/test-runner/src/sparkles/test_runner/attributes.d:71]
1 @wasm tests passed
```

Each test is exported individually (`run_test_<i>`); a failed `assert` traps
(bare `wasm32` has no libc to print with), which the host reports as a
per-test `RuntimeError`.

## Toolchain requirements

- **LDC** (`--compiler`/`$DC` must be an ldc; dmd has no wasm backend).
- **`wasm-ld`** on `PATH` (nixpkgs: the `lld` package) — nixpkgs LDC does
  not bundle an internal linker.
- A **runtime**: `node`, `deno`, or `bun` (a generated JS shim instantiates
  the module and reports per-test results), or `wasmtime`
  (`--invoke run_test_<i>` per test).

Missing pieces are reported as a skip, not a failure.

## Constraints

Everything from [`@betterC` extraction](./write-betterc-tests.md) applies
(public symbols only, templates/CTFE-able code by default,
`--include-import` opt-ins), plus one more with a stock LDC:

> [!WARNING]
> The tested module's whole import chain must be wasm-compatible. Bare
> `wasm32` druntime headers `static assert` for many `core.stdc.*` modules,
> so any module (transitively) importing e.g. `core.time` fails to compile.
> Keep `@wasm` tests in modules with wasm-clean imports — or point
> `--compiler` at a wasm-enabled LDC build with full druntime/Phobos ported
> (e.g. the `dlang.nix` `ldc-wasm` toolchain), which lifts the restriction.
