# Target profiles & device code (`TGT`)

_**Status:** implemented · **Date:** 2026-09-25 · **Scope:** analyzing code
as a compiler other than DMD sees it — LDC, and the dcompute LDC's device
compile of `@compute` shader modules; overview in the [index](./index.md)._

The analysis core is DMD's frontend, so until now every file was analyzed as
DMD compiles it for the host. That is wrong for one class of code the
repository ships: single-source shaders ([`EFX20`](../ui/effects.md)). A
`@compute(CompileFor.deviceOnly)` module such as `libs/ui/shaders/effects.d`
is only ever compiled by the dcompute LDC, for a GPU, with
`-mdcompute-targets=vulkan-130` (so `LDC_DCompute`) and LDC's own druntime — and analyzed as
DMD host code, every one of its `texture0.sample(uv)` calls was an error. A
`@compute(CompileFor.hostAndDevice)` module is compiled both ways, and an
error can exist on either side alone.

## What the frontend is told (`TGT1`-`TGT4`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                          | Status | Traces to                                                                               |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ | --------------------------------------------------------------------------------------- |
| TGT1 | An `AnalyzerConfig` names a **target profile** — `dmd` (the default: nothing changes), `ldc`, or `ldcDevice` — and a `-mdcompute-targets=` dflag selects `ldcDevice` on its own, so a flag list copied from a real device build means what it says.                                                                                  | full   | `TargetProfile`; `effectiveProfile`; test `options.effectiveProfile`                    |
| TGT2 | An LDC profile predefines `LDC` (not `DigitalMars`; `ldcDevice` adds `LDC_DCompute`) and accepts the vector shapes an LLVM backend lowers — `__vector(float[2])`, `__vector(float[3])` and operations on them — sized as LLVM sizes them. The `dmd` profile still rejects them.                                                      | full   | fork `unrestrictedVectors`, `initDMD(vendorVersion)`; tests `testing.profile.*`         |
| TGT3 | An LDC profile reads `object`, `ldc.*` and Phobos from **LDC's runtime sources**, `$SPARKLES_LDC_IMPORT_PATH` — the dcompute LDC's own tree (`nix/packages/ldc-import-paths.nix`, a fetch of `ldc-vulkan`'s source that builds nothing). Unset (any non-Linux host), LDC-profile tests skip and the analysis reports which variable. | full   | `runtimeImportVariable`; `runtimeSourcesProblem`; devshell + `twoslash-extract` wrapper |
| TGT4 | An LDC profile predefines the `LDC_LLVM_<major>` identifier `ldc.intrinsics` requires, read off the runtime it analyzes against (the newest major `ldc/intrinsics.di` accepts).                                                                                                                                                      | full   | `ldcLlvmVersionIdent`; test `init_.ldcLlvmVersionIdent`                                 |

`-betterC` also reaches the frontend before it derives its predefined set
now, so `D_BetterC` is predefined and `D_ModuleInfo` is not — the fork's
`initDMD(configureParams)` hook, which the profiles needed anyway.

## Which side, and how it is compiled (`TGT5`-`TGT6`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                       | Status | Traces to                                                                                                     |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------- |
| TGT5 | A module's side is read from its declaration: `@compute` / `@compute(CompileFor.deviceOnly)` is device code, `@compute(CompileFor.hostAndDevice)` both, anything else host code. The read is lexical (the attributes before `module`), so it needs no frontend and costs a scan of the file's head.                                                               | full   | `computeModeOf`; test `device.computeModeOf`                                                                  |
| TGT6 | The device side is analyzed as **the device build compiles it**, not as dub builds the package: the repository's `shader-units.json` names each unit's sources, import roots, device versions, flags and dcompute target, and `apps/shader-compile` reads the same file. A `@compute` module in no unit gets its dub project's settings retargeted to the device. | full   | `deviceConfigFor`; `loadShaderManifest`; tests `device.deviceConfigFor`, `shader-compile.manifest.repository` |

## The device build's rules (`TGT7`-`TGT8`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                            | Status | Traces to                                                             |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ | --------------------------------------------------------------------- |
| TGT7 | Under `ldcDevice`, after a clean semantic pass, a `@compute` module gets **LDC's own device-code pass** (`gen/semantic-dcompute.cpp`, ported): no classes, globals, associative arrays, `new`, `~`, `~=`, `.length =`, array literals, `typeid`, string literals, asm, exceptions, string `switch`, function pointers, `synchronized`, or calls into host modules — with LDC's messages word for word. | full   | `sparkles.dmd_lsp.dcompute`; tests `testing.dcompute.*`               |
| TGT8 | A `@fragment` entry point's parameters are each `@input`, `@uniform` or a `Sampler2D` — the fork's `addShaderEntry` check, reported where the parameter is declared. Checks that need the LLVM ABI are out of reach of a frontend-only analysis and are not made.                                                                                                                                      | full   | `checkFragmentParameters`; test `testing.dcompute.fragmentParameters` |

## Both sides at once (`TGT9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                            | Status | Traces to                                                               |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------------- |
| TGT9 | A `hostAndDevice` module is analyzed on both sides and **one payload carries both**: the host analysis is the one hovers resolve against, and the device side (a child process — one analysis per process, `EXT2`) contributes its errors. An error both sides report stays as it is; one only a single side reports is tagged `[host]` or `[device]`. `twoslash-extract --side=host\|device` analyzes one side alone. | full   | `mergeSideDiagnostics`; `twoslash-extract` `sidePlan`/`mergeDeviceSide` |

## Verified

- `twoslash-extract --dub libs/ui/shaders/effects.d`: 9 errors analyzed as
  DMD host code (`--side=host`), 0 under the default.
- Every module of the `effects` unit analyzes clean under both sides.
- A string literal seeded into a `hostAndDevice` module is reported as
  `[device] string literals not allowed in \`@compute\` code`on the same line
where`ldc-vulkan`reports`string literals not allowed in \`@compute\`
  code`.
- `nix run .#shader-compile -- --verify` is byte-identical with the unit
  table moved into `shader-units.json`.

→ [Overview](./index.md) · [Feature requirements](./feature-requirements.md) ·
[Effects spec](../ui/effects.md)
