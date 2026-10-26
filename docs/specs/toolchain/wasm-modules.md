---
status: draft
owner: sparkles
reviewed: 2026-10-26
---

# The Sparkles toolchain — WebAssembly modules

The documentation site runs Sparkles' own D code in the reader's browser:
the cell explorer on the [text specification](../base/text/index.md) measures
and segments text with `sparkles:base`, and the
[table playground](../../libs/core-cli/table.md) renders tables with
`sparkles:core-cli`. Each is a WASI preview 1 module built by the toolchain
of [wasi.md](./wasi.md) and loaded by a component of the site. This page is
the integration contract between those modules, the packages they compile,
and the site; each obligation names its owner. It is part of the
[specification](./SPEC.md).

## 1. Contract at a glance

1. Each module is a dub package built by dub, like every other Sparkles
   program.
2. Modules are reactors: the host calls `_initialize`, then the exports.
3. Both modules share one exported memory interface, specified below.
4. The site loads both through one WASI implementation that provides a real
   clock and output.
5. A check compares each module's results with the same code run natively.

## 2. Build

**TCM1: Dub packages.** _(Owners: `sparkles:base`, `sparkles:core-cli`.)_ Each
module **must** be a dub package whose configuration for `wasm32-unknown-wasip1`
states its sources, dependencies and flags, and Sparkles' Nix build **must**
build it with dub against the locked dependencies, so a dependency change in
any library it uses rebuilds or fails it like any other dub program.

**TCM2: Checked like other programs.** _(Owner: `sparkles:ci`.)_ The modules
**must** be built by `ci --build-each-commit` and by the flake's aggregate
build on every supported host of [TC21](./SPEC.md#_8-platforms-tests-and-caches).

**TCM3: Built, not committed.** _(Owner: `sparkles:docs`.)_ The site build
**must** build both modules from the tree it publishes; no module binary
**may** be committed to the repository.

## 3. Interface

**TCM4: Reactor modules.** _(Owners: `sparkles:base`,
`sparkles:core-cli`.)_ Each module **must** be a `wasip1` reactor of
[TCW7](./wasi.md#_3-drivers-and-linking) and export no `_start`.

**TCM5: Shared memory interface.** _(Owner: `sparkles:base`.)_ Both modules
**must** export the functions below, the first three defined once in a module
of `sparkles:base` that both link. All addresses are byte offsets into the
module's exported `memory`, and every integer is a 32-bit WebAssembly value.

| Export              | Parameters                                                      | Result                                                                                                                                                                                                                                            |
| ------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spk_buf_ptr`       | —                                                               | Address of a scratch buffer the host may write input to and read output from                                                                                                                                                                      |
| `spk_buf_cap`       | —                                                               | The buffer's size in bytes, at least 262 144                                                                                                                                                                                                      |
| `spk_segment`       | `ptr`, `len` (UTF-8 input); `outPtr`, `outCap` (triple slots)   | The number `n` of grapheme clusters and escape sequences in the input, with `(byteOffset, byteLength, cellWidth)` written as three unsigned 32-bit values per unit at `outPtr`; `-1`, with nothing defined written, if `n > outCap`               |
| `spk_visible_width` | `ptr`, `len` (UTF-8 input)                                      | The input's width in terminal cells (text module)                                                                                                                                                                                                 |
| `spk_table_render`  | `inPtr`, `inLen` (JSON table specification); `outPtr`, `outCap` | `n ≥ 0`: `n` bytes of UTF-8 rendering written at `outPtr`; `-1`: the rendering does not fit in `outCap`; `-(k + 1)`, `k ≥ 1`: the input is invalid and `k` bytes of a UTF-8 message are written at `outPtr`, truncated to `outCap` (table module) |

Input ranges and output ranges **must** lie within `memory`; a module
**must** treat overlapping input and output ranges as invalid input.

**TCM6: Errors are values.** _(Owner: `sparkles:core-cli`.)_ For input that
is not valid JSON, or JSON that is not a valid table specification,
`spk_table_render` **must** return an error code of TCM5 and **must not**
trap.

## 4. Host

**TCM7: One WASI host.** _(Owner: `sparkles:docs`.)_ The site **must** load
both modules through one shared loader that implements the WASI preview 1
imports with a real clock, forwards standard output and error to the
browser console, and calls `_initialize` once before any other export. A
component **must not** instantiate a module or stub WASI imports itself.

**TCM8: Size budget.** _(Owners: module packages.)_ Each module's size after
`wasm-opt -Oz`, with the binaryen of Sparkles' nixpkgs, **must** be recorded
in [testing.md](./testing.md#closure-measurements); an increase of more than
5 % **must** state its cause in the pull request, as
[TC16](./SPEC.md#_5-closure) requires of closures.

## 5. Verification

**TCM9: Native agreement.** _(Owner: `sparkles:ci`.)_ A check run by Nix
**must** instantiate each module through the loader of TCM7 and compare
its results with the same functions run natively: the visible width and
segmentation of a fixed corpus of strings, including combining sequences,
emoji modifiers and East Asian wide characters, and the rendering of a fixed
set of tables, including invalid JSON, an invalid specification, and an
output buffer too small for the rendering.

_Scope:_ the check detects differences between the WebAssembly and native
builds — miscompilation, a missing runtime feature, an interface mismatch.
The functions' own correctness is the subject of their packages' tests.
