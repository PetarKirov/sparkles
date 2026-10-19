---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders`: Adversarial review of the Stage 0 revision (first slice)

This is the adversarial review that the [revision's Stage 0 gate](./PLAN.md#stage-0-revision-the-full-language-scope)
requires. It covers the first slice's contracts at `29a5735af` (branch
`docs/specs/shaders-stage0-revision`):

- profiles and capabilities (`SHC1`–`SHC10`)
- entry points (`SHF1`–`SHF9`)
- resources (`SHR1`–`SHR8`)
- the revised build step (`SHP3`–`SHP8`, `SHP10`)
- their scenarios in `testing.md`, the M6 gate in `PLAN.md`, and decisions `D16`–`D24`

They are read against the code the slice builds on: `libs/shaders`, `apps/shader-compile`, the
first consumer `libs/vulkan-wsi`, the LDC fork at [`PetarKirov/ldc@64104a9a`](https://github.com/PetarKirov/ldc/tree/64104a9a6da522730d6b661b85adfdfd2e7e25e7)
and LLVM at
`dc9927e397`. The standard is the one in
[Writing Specification Docs](../../guidelines/spec-docs.md): _what could two
reasonable readers implement differently, and what would detect it?_

**Outcome:** 32 findings: 4 blockers, 18 majors and 10 minors.

The blockers:

- The capability gate in `SHR1` contradicts the per-profile lowering in `SHR3`–`SHR5`.
- `SHR3`'s default uniform block cannot coexist with the unit-wide one-variable-per-name rule in `SHF2`. Under `vulkan1.3`, any unit with two entry points that take different `@uniform` sets breaks it, and so would `sparkles:ui`'s effects.
- The first consumer's natural table lookup emits `OpCapability Int64`, and no part of the spec says whether `vulkan1.3` grants it.
- No contract says how the active profile reaches the compiler. `SHC3`'s "fail before semantic analysis" cannot be met while the table is D data.

The dispositions below were made by the revision itself; acceptance is the owner's.

## Method

The dev shell's toolchain was used through `nix develop`: `ldc2-vulkan` (LDC
1.43.0 on LLVM 24.0.0git), SPIR-V Tools and SPIRV-Cross 1.4.357.0, and glslang
16.4.0. The probes ran in a scratch directory outside the repository. Their
sources are in [the appendix](#appendix-probes). Two full builds of
`sparkles:ui`'s unit (`dub run :shader-compile -- --package=libs/ui --out=… --keep`)
gave the capability set of the existing effects and showed that output is deterministic.
Nothing in the repository was modified.

## Worked traces

Each step names the requirement that governs it, what the text says, and
whether it fixes **one** outcome. "No" means two careful readers can diverge.

### Trace A: two profiles, one Vulkan-only entry point that reaches `pushConstants`

The unit is a device module declared `@profiles(gl330, gles100) module m;`. It holds
fragment entry `fx(...)` and fragment entry `@profiles(vulkan13) vk(PushConstants!P pc, ...)`,
whose helper `h(pc)` calls a built-in that would declare `@requires(Cap.pushConstants)`.

| Step                                                        | Governs                | Text                                                                                                                                                                              | Single outcome?                                                                                                                                                                                                                                                                       |
| ----------------------------------------------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Resolve each entry's profiles                            | `SHC4`                 | The entry's own `@profiles` replaces the module default                                                                                                                           | Yes: `fx`→{gl330, gles100}, `vk`→{vulkan1.3}. `SHC4` names identifiers (`vulkan13`) and `SHC2` names profiles (`vulkan1.3`). Which one is the "name" is open (R4).                                                                                                                    |
| 2. Produce the manifest                                     | `SHC5`, `SHP10`.5      | `-mdcompute-manifest=<file>`, "without generating code"                                                                                                                           | **No.** The format is not defined, and neither is the active profile, so `getTargetInfo("shaderProfile")` has no defined value during the manifest compile. Module-scope `static if (activeProfile…)` that declares entries or chooses `@profiles` makes the manifest circular (R12). |
| 3. Union of profiles                                        | `SHC5`                 | Union of the entries' profiles                                                                                                                                                    | Yes: {gl330, gles100, vulkan1.3}. The order in which the profiles are compiled and failures reported is undefined (R12).                                                                                                                                                              |
| 4. Compile for `gl330`: how the compiler learns the profile | `SHC3`, `SHC1`, `D16`  | `getTargetInfo` "must evaluate to the active profile's name"; `D16`: lowering choices "are passed to the compiler by the build step"                                              | **No.** No flag or other mechanism is specified. `SHC3`'s "fail before semantic analysis … naming the profile" cannot check membership in a D table that only semantic analysis can read (R4).                                                                                        |
| 5. Analyse `vk` under `gl330`                               | `SHC6`, `SHR1`         | `SHC6`: not emitted, and what only it reaches "must not be checked against P"; `SHR1`: "the compiler must accept each [kind] only where the active profile grants its capability" | **No.** `PushConstants!P` is a resource kind that `gl330` does not grant. `SHR1` rejects it at analysis and `SHC6` forbids that. The text does not say whether "accept" happens at analysis or at emission (R1, R13).                                                                 |
| 6. The helper's `pushConstants` requirement                 | `SHC7`, `SHC8` (M7)    | "until then the audit (`SHC9`) and the manifest's per-profile compilation are the checks"                                                                                         | Yes for M6: nothing checks it. M6 delivers no `@requires` and no `unsupported`, yet `SHV8` (an M6 obligation) lists `@requires` as a stand-in. The trace's capability error is undetectable in M6 (R13).                                                                              |
| 7. Interface unity under `gl330`                            | `SHF2`                 | "every entry point of that stage that names it"                                                                                                                                   | **No.** The text does not say whether the unemitted `vk` participates. The fork records uses as it builds entries (`targetVulkan.cpp:329–369`), so an unemitted entry would not participate (R13).                                                                                    |
| 8. Emit and validate `gl330`                                | `SHP4`                 | `spirv-val` universal 1.6, then audit, then `spirv-opt -O`                                                                                                                        | Yes.                                                                                                                                                                                                                                                                                  |
| 9. Audit                                                    | `SHC9`                 | Every `OpCapability`/`OpExtension` maps through the table                                                                                                                         | Partly. `SHC1` does not make the SPIR-V-name mapping part of the table's contract. The diagnostic lists "the entry points whose module declares it", which is every entry, because capabilities are module-wide (R25).                                                                |
| 10. Compile `vulkan1.3`                                     | `SHR4`, `SHR6`, `SHP4` | Push block in `PushConstant` storage, std430, `spirv-val --target-env vulkan1.3`                                                                                                  | Contract yes. Feasibility unproven: the backend derives push-constant offsets from the SPIR-V data layout (vec3 at offset 8 in `vk-pushconstant-layout-natural.ll`), not std430, and `spirv-val vulkan1.3` accepts that (relaxed block layout). R10.                                  |
| 11. Outputs                                                 | `SHC2`, `SHC6`, `SHP5` | `fx.frag`, `fx.es.frag`, `vk.frag.spv`; nothing else                                                                                                                              | Yes.                                                                                                                                                                                                                                                                                  |
| 12. One profile fails late                                  | `SHP6`, `SHP8`         | Each file is validated "before it is written"; stamp last                                                                                                                         | **No.** If `vulkan1.3` fails after the GL files are written, the GL files are new, the old stamp remains, and reverting the source makes `--if-stale` vouch for output from the failed edit (R14).                                                                                    |

### Trace B: push-constant size

- **`T` is 132 bytes by every measure** (`float4[8] m; float s;`, std430 size 144, D size 144, end of last member 132). `SHR4` rejects it, naming the parameter. That outcome is single.
- **`T` = `float4[7] m; float3 v; float s;`.** The D layout puts `v` at 112 with 16 bytes (`SHV2`), `s` at 128, `T.sizeof == 144`. std430 puts `v` at 112 with 12 bytes and `s` at 124, size 128. `SHR4` says "whose size must not exceed 128 bytes" and does not say whose size. One reader measures `T.sizeof` and rejects; another measures `layoutOf!(T, std430).size` and accepts. A consumer that pushes `T.sizeof` bytes (the obvious call) violates `VUID-vkCmdPushConstants-size-00369` even when the compiler accepted. Nothing in the spec tells the host to push `layoutOf` bytes written by `writeLayout` (R9).
- **The reverse case.** std430 never exceeds D's layout for `SHF5`'s uniform types (no `bool`, scalar arrays stride 4 in both), so only the D-larger case arises for push constants. std140 (uniform blocks) is larger than D for arrays of scalars (stride 16 against 4). That matters for R10.
- **Cross-stage sharing.** A vertex `PushConstants!A` and a fragment `PushConstants!B` both start at offset 0 and alias the same bytes. Nothing checks that `A` and `B` agree, and `stagesLink` does not look at push constants (R9).

### Trace C: interface structs and names

- **`@resources struct R { Sampler2D tex; }` and `f(@input float2 tex, R r)`.** `SHR2` forbids only "two resources … share a name". `tex` the input is not a resource, so nothing forbids it. GLSL then declares `in vec2 tex` and `uniform sampler2D tex`. Either glslang rejects the redeclaration (exit 1 with no D diagnostic) or spirv-cross renames one, silently. Two outcomes, neither specified (R8).
- **`f(UniformBlock!U u, @uniform float scale)` where `U` has a field `scale`.** `SHR2` does not apply, because blocks are lowered, not flattened. Under `vulkan1.3` the two are distinct members of two blocks. Under `gl330` both become `uniform … scale`. The result differs by profile, and no requirement covers it (R8).
- **Nested: `@resources struct Pair { Sampler2D tex; }`, `@resources struct Outer { Pair a; Pair b; }`.** Flattening names each field after its leaf ("named after the field"), so `a.tex` and `b.tex` both become `tex` and clash. The rule determines the outcome, but it means a struct cannot be nested twice in one entry. The clash diagnostic's content is unspecified, and the test ("naming what `SHR1`–`SHR7` say") has nothing to compare against (R8).
- **Shared struct across entry points (`D18`'s motivation).** `a(Sampler2D extra, R r)` puts `tex` at binding 2 and `b(R r)` puts it at binding 1 (`SHR7`, positional). `SHF2` then requires a compile error ("the same location or binding"). The sharing `D18` promises works only when every entry places the struct at the same ordinal position (R7).

### Trace D: `vulkan1.3` module declaring `Int64`

The probe is `t[idx]` on a local `vec4[3]` with `@uniform int idx` (probe P1).

1. **Compile.** D converts the `int` index to `size_t`. The module holds `%38 = OpSConvert %long %26` and `OpCapability Int64`, both of which survive `spirv-opt -O`. The fork's 32-bit access-chain patch does not remove the conversion.
2. **Validate (`SHP4`).** Under universal 1.6 the module is valid. Under `vulkan1.3` the probe fails only on the pre-revision loose `int` uniform (`VUID-StandaloneSpirv-UniformConstant-04655`). `Int64` itself is legal to the validator, which does not check device features.
3. **Audit (`SHC9`).** The result hinges on whether `vulkan1.3` grants `int64`. `SHC2` lists what `vulkan1.3` grants (push constants, uniform blocks) and denies (loose uniforms), and says nothing on `int64`. **The outcome is undetermined.**
   - If it grants `int64`, the file passes, but `vulkan-wsi` creates its device with no features (`grep shaderInt64` finds nothing in `libs/vulkan*`). The pipeline is then invalid under `VUID-VkShaderModuleCreateInfo-pCode-08740`. lavapipe runs it anyway, and the validation layers that would object are in `devPackages`, not the CI tier (`nix/shells/default.nix:307–316`).
   - If it denies `int64`, the first consumer's natural `positions[vertexIndex]` fails the audit (R3).
4. **Diagnostic.** The diagnostic names "the entry points whose module declares it": every entry of the profile, not the one that indexed (R25).
5. **Variants with `size_t` arithmetic.** These never reach the audit. `cast(size_t) idx * 3 + 1` then `% 3` produces `OpUMod %long`, and `spirv-val` rejects it ("Expected unsigned int scalar … UMod"), because the fork's `spirv.signed-integers` flag makes every integer type signed. `cast(size_t) idx + 1` as an index crashes the compiler with an assertion in `SPIRVEmitIntrinsics.cpp:859`. The first exits 1 with a validator message that names no D line. The second exits 1 (the minimal probe compiles) with a stack dump (R22).

### Trace E: the `vulkan-wsi` triangle, ported

| Step                 | Governs                          | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Module mode          | `SHM1`, `SHV8`, testing          | Comparing with "the host evaluation of its vertex function" needs a host-and-device module. A device-only module "need not compile" on the host (`SHV8`). The spec does not say which mode the module takes. `SHV8`'s stand-in list omits `@builtin`/`Builtin` (R17).                                                                                                                                                                                                                                                                                                |
| Constant tables      | `SHM3`, M10                      | Array literals and global variables are forbidden, and "module-scope constant tables" arrive only in M10 (`PLAN.md`, M10). Two forms remain: a local `float2[3] p; p[0] = …;` with a dynamic index, which compiles and validates (probe P1) but emits `Int64` (Trace D), or a `switch` on the index. The spec states neither (R17).                                                                                                                                                                                                                                  |
| `vertexIndex`        | `SHF8`                           | `int`, `VertexIndex`. The GLSL column (`gl_VertexIndex`) is the Vulkan dialect. GLSL 3.30 has `gl_VertexID` (R23).                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Result struct        | `SHF3`                           | `{ @builtin(Builtin.position) float4 pos; float3 fragColor; }` gives `fragColor` at location 0. Determinate.                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Linking              | `SHF9`, `SHF2`                   | `stagesLink` needs the vertex output and fragment input both named `fragColor`. In one `vulkan1.3` module they are two LLVM globals with one name. The fork's `buildInterfaceVariable` (`targetVulkan.cpp:287–293`) fails when address spaces differ: "declared with two types". `SHF2` allows only "a vertex input and a fragment input" to share a name, and says nothing about an output and an input (R5).                                                                                                                                                       |
| Aspect push constant | `SHR4`, `SHR6`                   | `PushConstants!Aspect`, std430 4 bytes. The consumer hard-codes `VK_SHADER_STAGE_FRAGMENT_BIT` for push ranges (`triangle.d:126`, `:532`) and must change it to the vertex stage. The library hands the layout through `layoutOf`, but nothing states which stage uses which block (R16).                                                                                                                                                                                                                                                                            |
| Files produced       | `SHC2`, `SHP5`                   | `<vertEntry>.vert.spv`, `<fragEntry>.frag.spv`. `SHF1` requires the names to differ across stages. Determinate.                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Loading              | `SHB5`, `SHP8`                   | The consumer string-imports the files and must set `pName` to the D entry names, not `"main"` (`triangle.d:458`, `:462`). `vulkan-wsi` is a `sourceLibrary` whose **default** configuration string-imports the SPIR-V (`dub.sdl`). `SHB5` requires the default configuration to build without the device compiler, and M6 removes the committed SPIR-V. Neither the spec nor PLAN says where the default build gets the shaders (R16). Pointing the output at the existing `src/shaders` would let the `SHP8` sweep delete the committed `test_pattern.*.spv` (R16). |
| Validation / oracle  | `SHP4`, `SHP6`, testing, M6 gate | "Within one rasterisation rule" is not defined. Pixels "at the three vertices" lie on edges, where the top-left rule decides coverage. No tolerance is stated for interpolated colour. CI runs no validation layers, so `VUID` violations such as `shaderInt64` and a push-range stage mismatch are invisible (R18).                                                                                                                                                                                                                                                 |

### Trace F: existing effects after the revision

1. **Profiles.** `effects.d` has no `@profiles`, so every entry builds for `gl330` and `gles100` (`SHC4` default). That gives two compilations where there used to be one (`SHC6`).
2. **Capabilities.** The unit's module declares only `OpCapability Shader` (`--keep` build). The audit passes if the table maps `Shader` to a capability both GL profiles grant. `SHC1` does not require that mapping (R25).
3. **Bindings.** `SHR7` applies only under `vulkan1.3`. For the GL profiles, the revision states no binding rule at all.
   - The old `SHF2`'s images "at binding 1, 2, 3 … in the order the `Sampler2D` parameters appear" and "one sampler at binding 0" were removed.
   - `SHR7` still cites "the shared sampler at binding 0 ([`SHF2`])", which no longer says it.
   - The testing scenario still asserts the old rule (`testing.md:72–76`).
   - GLSL 3.30 output carries no `binding` qualifier (`bloomComposite.frag`), so the bytes do not change. But `SHF2`'s cross-entry "same … binding" check has nothing defined to compare under GL (R6).
4. **Vulkan numbering.** `SHR7` numbers blocks, the default block and images in one parameter-order sequence. For an existing effect, images precede `@uniform`s (`effects.d:38–206`), so the textures keep 1, 2. An entry whose `@uniform` precedes a `Sampler2D` shifts the image's binding relative to the old `SHF2`, so the two rules disagree (R6).
5. **Byte identity (M6 gate, `D19`).** Byte identity depends on SPIR-V ID numbering across the whole unit, because spirv-cross names temporaries `_<id>`.
   - With identical stamp inputs (all seven hashes match), the dev shell's current toolchain produces GLSL whose every temporary differs from `libs/ui/generated/shaders/` (dated 2026-10-16), for example `_594` against `_550` in `bloomComposite.frag`. Two runs with one toolchain are identical, so the cause is the toolchain, not nondeterminism.
   - M6 changes the compiler (vertex stage, blocks, profile-aware emission), so "byte-identical to before the slice" is a gate that a semantically neutral compiler change fails.
   - `D19` says "byte-identical", while `PLAN.md:252–254` and `testing.md:103–104` add "apart from the provenance comment", which `SHP7` did not change for GLSL (R15).

## Feasibility checks

| Question                                            | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Does LDC run semantic analysis once per invocation? | Yes. The host and every `-mdcompute-targets` target share one front-end pass (`driver/main.cpp:1004–1021` predefines the versions globally). One profile per invocation is therefore necessary, as `D16` says. The host object of a device invocation is compiled under the device profile, which is harmless because the step discards it.                                                                                                                                     |
| Can `getTargetInfo` return per-profile values?      | Only with a new key and a new driver option. `Target::getTargetInfo` (`gen/target.cpp:352–420`) knows `dcomputeTargets` and `dcomputeFilePrefix` only. On DMD, stock LDC and the fork, `__traits(getTargetInfo, "shaderProfile")` is a compile **error** ("not supported by this implementation", probe P5), not a value. The host half of `SHC3` is infeasible as written (R11).                                                                                               |
| SPIR-V version per profile                          | The fork fixes the triple at `spirv1.6-unknown-vulkan1.3-compute` regardless of `vulkan-100`…`vulkan-140` (`targetVulkan.cpp:56`). `SHP1`'s version list is cosmetic, and a `vulkan1.1` profile (`Q3`) needs a compiler change, contrary to `SHC1` (R32).                                                                                                                                                                                                                       |
| Push constants, `Block`, `Offset`                   | The backend supports `addrspace(13)` → `PushConstant` with `Block` (`SPIRVGlobalRegistry.cpp:1681–1702`, `SPIRVPushConstantAccess.cpp`). Offsets come from the data layout (`addStructOffsetDecorations`, `:2450–2457`), and the lit test shows vec3 at offset 8 (`vk-pushconstant-layout-natural.ll`): not std430. Explicit offsets exist through `target("spirv.Layout", …)` (`:1705–1722`), which lit tests cover only inside `spirv.VulkanBuffer` (`spirv.layout.type.ll`). |
| std140 for uniform blocks                           | `spirv.VulkanBuffer` with storage class 2 plus `spirv.Layout` gives a `Uniform` block with explicit offsets. Array strides are always the data-layout allocation size (`addArrayStrideDecorations`, `:2470–2475`), so a std140 `float[N]` (stride 16) needs Clang's peeled array of `{T, spirv.Padding}`. That form declares an `OpTypeInt 8` member (`cbuffer-peeled-array.ll:7–8`): it changes the declared type and needs `Int8` plus 8-bit storage (R10).                   |
| `OpModuleProcessed` through `spirv-opt -O`          | Survives, and validates under `vulkan1.3` (probe P3). Not a finding. The step must insert it itself, by disassembly and reassembly, since the compiler cannot know the package.                                                                                                                                                                                                                                                                                                 |
| Per-entry SPIR-V module                             | No pinned tool extracts one entry point. The step must edit `OpEntryPoint`s and then run DCE. Feasible, but unspecified and untested (R31).                                                                                                                                                                                                                                                                                                                                     |

## Findings

Severity follows the [previous review](./adversarial-review.md#findings):

- A **blocker** must be resolved in the specification before Stage 0 is accepted.
- A **major** finding is one of: a contract the code or the pinned compiler breaks without a diagnostic, a missing failure contract, an outcome two readers would implement differently with consequences in M6, or evidence that claims more than exists.
- A **minor** finding is an ambiguity or a narrow divergence.

### Blockers

**R1 (blocker): `SHR1` gating contradicts `SHR3`–`SHR5` lowering.** Affects `SHR1`, `SHR3`, `SHR4`, `SHR5`, `SHC2`.

- **Discrepancy:**
  - `SHR1` says the compiler "must accept each [kind] only where the active profile grants its capability". Its table gates Uniform on `uniforms`, Uniform block on `uniformBlocks` and Push-constant block on `pushConstants`.
  - `SHC2`: "`vulkan1.3` … denies loose uniforms". Yet `SHR3` lowers `@uniform` under `vulkan1.3` into the default block, and `SHR4` lowers `PushConstants!T` under "a profile without `pushConstants`" into uniforms.
  - `SHC2` never says whether `gl330` grants `uniformBlocks`. GL 3.3 has UBOs, so a faithful table grants it. `SHR5` would then emit a GLSL uniform **block** for `gl330`, contradicting `D19` ("one named uniform per field under the OpenGL profiles") and raylib's binding model.
- **Evidence:** `resources.md:21–31`, `:51–58`, `:67–80`; `profiles.md:51–55`; `decisions.md:` `D19`.
- **Impact:** One implementer rejects `@uniform` under `vulkan1.3`, which breaks "builds for both kinds of profile unchanged". Another lowers it. `UniformBlock` under `gl330` becomes either a block or loose uniforms.
- **Correction:** Split the two concepts: the capability a _declaration form_ needs (none, since every form is lowerable) and the capability a _lowering_ uses. State the lowering per profile as a table (`gl330`: block → per-field uniforms, regardless of UBO support; `vulkan1.3`: `@uniform` → default block). State `gl330`'s and `gles100`'s grants explicitly. Drop "accept only where granted" from `SHR1`, or restrict it to kinds with no lowering (none in this slice).

**R2 (blocker): the default uniform block collides with the unit-wide name rule.** Affects `SHR3`, `SHF2`, `SHR7`, `SHR8`, `D19`.

- **Discrepancy:**
  - `SHR3` gives each entry point "a uniform block named `Uniforms` holding the entry point's `@uniform` parameters".
  - `SHF2`: "An interface name must denote one variable across the unit's entry points of one stage … the same kind, the same type and the same location or binding, or the compilation must fail".
  - The fork implements that rule by keying globals on their names (`buildUniform`, `targetVulkan.cpp:303–318`: "shader uniform `%s` declared with two types"). Two fragment entries with different `@uniform` lists produce two `Uniforms` of different types. `SHR7` also puts it at "the position of the first `@uniform`", which differs per entry.
  - The rule therefore requires `sparkles:ui`'s ten effects to fail under `vulkan1.3`, contradicting `SHR3`'s "builds for both kinds of profile unchanged".
- **Evidence:** `resources.md:55–65`, `:104–109`; `entry-points.md:67–77`; `targetVulkan.cpp:287–318`, `:329–369`.
- **Impact:** Either every multi-entry Vulkan unit with `@uniform`s fails, or an implementer silently exempts the default block, and with it the guarantee `SHF2` exists for.
- **Correction:** Pick one:
  - Make the default block per entry by name (`<entry>_Uniforms`, or a variable named after the entry) and exempt it from `SHF2` explicitly, since the per-entry `.spv` (`SHP5`) holds only one.
  - Define a unit-wide default block holding the union of all `@uniform`s, with `UniformsOf!unit`.

  Either way, add the two-entry `vulkan1.3` case to the resource scenarios.

**R3 (blocker): `vulkan1.3`'s `int64` is undecided, and the first consumer depends on it.** Affects `SHC2`, `SHC9`, `SHF8`, M6 consumer, `SHR` scenarios.

- **Discrepancy:**
  - `SHC2` does not say whether `vulkan1.3` grants `int64`.
  - Indexing a local array with an `int`, which the triangle must do with `vertexIndex` because `SHM3` forbids literal tables (Trace E), emits `OpSConvert %long` and `OpCapability Int64`, and both survive `spirv-opt -O` (probe P1).
  - `vulkan-wsi` enables no device features, so a module declaring `Int64` violates `VUID-VkShaderModuleCreateInfo-pCode-08740` unless `shaderInt64` is enabled.
  - `testing.md`'s audit scenario ("under a profile that denies it") names no profile.
- **Evidence:** Probe P1; `profiles.md:42–55`; `libs/vulkan-wsi/src/sparkles/vulkan_wsi/triangle.d` (no `pEnabledFeatures`); `nix/shells/default.nix:307–316` (validation layers not in CI).
- **Impact:** Trace D has two outcomes. The M6 gate either fails on the consumer, or passes on lavapipe with an invalid pipeline that no CI check sees.
- **Correction:**
  - Decide that `vulkan1.3` does not grant `int64`. Add a compiler obligation that an index of 32-bit type lowers to a 32-bit access-chain index with no 64-bit conversion, and give it a lit test on the `t[idx]` shape.
  - Or: grant `int64` and specify that the build step reports, per output, the device features its capabilities require (`shaderInt64`). The consumer must enable them.
  - In both cases, run the readback with the validation layers in the CI tier.

**R4 (blocker): no contract says how the active profile reaches the compiler, and `SHC3`'s failure is infeasible.** Affects `SHC1`, `SHC3`, `SHC5`, `SHC6`, `D16`, `SHP3`.

- **Discrepancy:**
  - `SHC3` requires `getTargetInfo("shaderProfile")` to be the active profile, but nothing names the driver option that sets it. `SHP3` and `SHC6` say "once for each profile … with that profile active", without a flag.
  - `SHC3` requires that a compilation "whose profile is not in the table must fail before semantic analysis", yet `SHC1` makes the table D data in `sparkles.shaders.capabilities`, which only semantic analysis can read.
  - `SHC1` says adding a profile "must not require a change to the compiler". But the compiler must choose lowerings by capability (`SHR3`–`SHR5`). `D16` says the build step passes "a profile's lowering choices", and no requirement specifies how.
  - `SHC4` names `vulkan13` and `SHC2` names `vulkan1.3`, so which string `getTargetInfo` returns is open.
- **Evidence:** `profiles.md:32–36`, `:57–63`, `:71–77`, `:85–90`; `decisions.md` `D16` trade-offs; `gen/target.cpp:352–420`.
- **Impact:** The compiler/build-step seam, the core of M6, is unspecified. Two implementers would build incompatible flag sets: the compiler computing CTFE over a sparkles module (a fork that hard-codes a library's module path), or the build step passing capability flags.
- **Correction:** Specify the option, for example `-mdcompute-profile=<name>`, with the exact name string, plus what the compiler receives: either the profile name only, with lowering read by CTFE from a named symbol, or explicit lowering and capability flags derived by the step from the table. Move "not in the table" to a check the build step makes against the table before invoking, or to the first semantic use of `activeProfile`. Use one spelling for profile names.

### Majors

**R5: a vertex output and a fragment input cannot share a name in one module.** Affects `SHF2`, `SHF3`, `SHF9`.

- **Discrepancy:** `SHF9` requires the fragment `@input` and the vertex output field to have "the same name". `SHF2` only says "a vertex input and a fragment input may share a name". The fork creates interface globals by name and errors when an existing global has another address space (`targetVulkan.cpp:287–293`). The triangle's `fragColor` would hit it.
- **Evidence:** `entry-points.md:67–77`, `:107–111`.
- **Impact:** The first consumer cannot build without an unspecified compiler change. Two readers differ on whether outputs of one stage and inputs of another are one variable.
- **Correction:** State that each (stage, direction, name) triple is its own variable. Restrict `SHF2`'s rule to same-stage, same-direction uses. Add the triangle shape to the entry-point scenarios.

**R6: the shared sampler and the GL bindings were dropped.** Affects `SHF2`, `SHR1`, `SHR7`, `D7`, testing.

- **Discrepancy:**
  - The old `SHF2` defined images "at binding 1, 2, 3 … in the order the `Sampler2D` parameters appear" and "one sampler at binding 0". The revised `SHF2` drops both.
  - `SHR7` (Vulkan only) cites "the shared sampler at binding 0 ([`SHF2`])". `SHR1` cites `SHF4` for "the shared sampler", which `SHF4` does not define. `D7` says "The shared sampler stands".
  - No requirement gives GL bindings, so `SHF2`'s "same … binding" check is undefined under GL.
  - `SHR7`'s combined sequence differs from the old rule whenever a block or `@uniform` precedes an image.
  - `testing.md:72–76` still asserts the old rule.
- **Evidence:** `git show origin/main:docs/specs/shaders/SPEC.md` lines 330–345; `resources.md:104–112`; `entry-points.md:42–53`; `decisions.md:139–147`.
- **Impact:** This undefined term sits on the path of every existing effect. The GL unity check can go either way.
- **Correction:** Restore the sampler as a requirement (owner: `SHR7`). Define binding assignment for every profile, either the same sequence everywhere or the old image-only sequence under GL, and state that GL GLSL carries no binding qualifier. Update the scenario.

**R7: positional bindings plus the unity rule defeat shared interface structs, and `@binding` is underspecified.** Affects `SHR2`, `SHR7`, `SHF2`, `D18`.

- **Discrepancy:**
  - The same `@resources` struct at different parameter positions in two entries gets different bindings (`SHR7`), which `SHF2` must reject. That is exactly `D18`'s "a set several entry points share".
  - `@binding(b)` "may fix its binding" without saying whether automatic numbering skips `b` or collides with it, whether `@binding(0)` collides with the sampler, or what `@binding` means under GL.
- **Evidence:** `resources.md:37–47`, `:104–112`; `decisions.md` `D18`.
- **Impact:** Two implementations number differently, and the rejection is unexpected.
- **Correction:** Number automatic bindings by skipping fixed ones. State that the sampler counts as binding 0 for clashes. Recommend `@binding` on shared structs, or number an interface struct's members from a base that is fixed per struct. Add scenarios.

**R8: name clashes outside `SHR2` have no rule, and the clash diagnostic has no content.** Affects `SHR2`, `SHR4`, `SHR5`, `SHR8`, `SHF2`.

- **Discrepancy:** Trace C. A flattened resource and an `@input` with the same name, or a GL-lowered block field and another uniform, are not covered. GLSL either fails in glslang or spirv-cross renames silently.
- **Evidence:** `resources.md:37–42`, `:76–80`, `:114–116`.
- **Impact:** The behaviour depends on the profile, and the host may bind a renamed uniform. A D parameter name was always unique, so this hazard is new with the revision.
- **Correction:** Require names unique across the entry's whole lowered interface, per profile, including block fields lowered to uniforms and inputs. Fail naming both D declarations. Specify the leaf-name rule for nested structs and its consequence.

**R9: push-constant size measure and cross-stage aliasing.** Affects `SHR4`, `SHR6`, `SHF9`.

- **Discrepancy:** "whose size must not exceed 128 bytes" does not say whose size (Trace B: 144 against 128). Nothing tells the host to push `layoutOf!(T, std430).size` bytes from `writeLayout`. Vertex and fragment blocks both start at offset 0, with no compatibility check.
- **Evidence:** `resources.md:67–74`.
- **Impact:** The two readers disagree on accept or reject. A host that pushes `T.sizeof` triggers a VUID error.
- **Correction:** "its std430 size, `layoutOf!(T, Rule.std430).size`". Add a boundary scenario at exactly 128 bytes where D's size is larger. Either require that the blocks of two stages in one pipeline be the same `T`, checked by `stagesLink`, or specify stage-disjoint offsets.

**R10: the layouts in `SHR6` lack feasibility evidence.** Affects `SHR4`, `SHR5`, `SHR6`, `SHR8`, Stage 0 gate.

- **Discrepancy:**
  - The backend's push-constant offsets are data-layout offsets (vec3 at 8 in `vk-pushconstant-layout-natural.ll`), not std430.
  - Explicit offsets (`spirv.Layout`) are tested only inside `spirv.VulkanBuffer`.
  - `ArrayStride` is always the data-layout allocation size (`SPIRVGlobalRegistry.cpp:2470–2475`), so std140 scalar arrays need Clang's peeled-array encoding. That encoding declares an 8-bit padding member (`cbuffer-peeled-array.ll:7–24`), changing the block's declared type (against `SHR8`/`SHF5` fidelity) and needing `Int8` plus 8-bit storage, which the audit would then have to grant.
  - `spirv-val --target-env vulkan1.3` accepts relaxed block layout, so it is not an oracle for `SHR6`.
- **Evidence:** See the [Feasibility checks](#feasibility-checks).
- **Impact:** This is a blocker-class risk hidden behind a confident contract. The Stage 0 gate requires feasibility evidence for blockers.
- **Correction:** Add a spike before acceptance: emit a push block and a uniform block with `{float3; float}` and `float[4]` from LDC IR, validate them, and read the offsets and strides. Record the result. If padding types are needed, state their capability cost and how `SHR8` names survive. Note in `testing.md` that `spirv-val` does not check `SHR6`.

**R11: the host half of `SHC3` cannot be implemented.** Affects `SHC3`, `SHT4`.

- **Discrepancy:** "in a host compilation it must evaluate to `"cpu"`". DMD, stock LDC and the fork reject the key with a compile error (probe P5). `SHT4` requires every D compiler to work.
- **Evidence:** Probe P5.
- **Impact:** A literal implementation breaks every host build.
- **Correction:** Specify `activeProfile` as `version (LDC_DCompute)`-guarded: the trait under a device target, `cpu` otherwise. Bind the trait only for device compilations of the fork.

**R12: the manifest is underspecified.** Affects `SHC5`, `SHP10`, testing.

- **Discrepancy:**
  - No format is given (entries, stages, profiles, order, encoding).
  - The active profile during the manifest compile is undefined.
  - A `static if (activeProfile…)` that declares entries or chooses `@profiles` is circular.
  - The union's order, which fixes compilation and failure-reporting order (`SHP10`.6–7), is undefined.
  - An empty union is not classified.
- **Evidence:** `profiles.md:79–83`; `build.md:120–126`.
- **Impact:** The test "check the manifest names each entry point" has no oracle. Two compilers and steps may not interoperate.
- **Correction:**
  - Define the format, and the profile under which the manifest compile runs (say `manifest`, with `activeProfile` unusable there).
  - Forbid profile-dependent entry declarations and `@profiles`, or diagnose them.
  - Order profiles by table order.
  - Make an empty union exit 2 ("no entry points").

**R13: unemitted entries, and capability denials M6 cannot enforce.** Affects `SHC2`, `SHC6`, `SHC7`, `SHR1`, `SHV8`.

- **Discrepancy:**
  - `SHC6` exempts unemitted entries from checks, while `SHR1` gates kinds at "accept". Whether unemitted entries take part in `SHF2`'s unity rule is unstated.
  - M6 has no `@requires` checks (M7), so Trace A's capability goes unchecked.
  - `gles100` "denies integer bit operations and dynamic loop bounds", but neither has a SPIR-V capability for `SHC9` to audit, and glslang does not enforce ES 1.00's Appendix A loop restrictions. The denial is unfalsifiable in M6.
- **Evidence:** `profiles.md:51–55`, `:85–93`, `:154–163`.
- **Impact:** The claims cannot be tested, and Trace A has no single outcome.
- **Correction:**
  - State that `SHR1` and `SHF2` apply to emitted entries only.
  - Mark `gles100`'s two denials as checked from M7, or remove them from M6's table.
  - Name Trace A's expected M6 outcome ("not detected until M7") in `testing.md`.

**R14: output can be partial across profiles.** Affects `SHP6`, `SHP8`, `SHB1`, `SHB2`.

- **Discrepancy:** Each file is validated "before it is written", and the stamp is written last, but nothing requires every profile to finish before any profile writes. The pre-revision implementation wrote nothing until everything passed (test `aFailedValidationWritesNothing`), but the text never required it.
- **Evidence:** `build.md:77–98`.
- **Impact:** Trace A step 12: after a late profile fails, the old stamp vouches for mixed output.
- **Correction:** Either require that no output-directory write happen until every profile has compiled, validated, passed the audit and been translated, or require deleting the stamp before the first write. Add a scenario where `vulkan1.3` fails after the GL profiles succeed.

**R15: the byte-identity gate is fragile, and its wording is inconsistent.** Affects the M6 gate, `D19`, testing "Unchanged output".

- **Discrepancy:** Trace F step 5. Temporaries are unit-wide SPIR-V IDs, and a toolchain change with identical inputs renumbered every one. `D19` says "byte-identical", while PLAN and testing say "apart from the provenance comment", which `SHP7` did not change.
- **Evidence:** A diff of the current-toolchain output against `libs/ui/generated/shaders/` (same `.stamp` inputs); two current runs identical.
- **Impact:** The gate fails for reasons unrelated to semantics, and invites blessing the new output.
- **Correction:** Define the baseline as the pre-slice source and recipe built with the M6 compiler, and compare byte for byte. Alternatively compare modulo `_<n>` renaming plus the SPIR-V disassembly of the GL modules. Make `D19`, PLAN and testing say the same thing.

**R16: the consumer integration is unspecified.** Affects `SHB5`, `SHB6`, `SHP8`, M6 consumer.

- **Discrepancy:**
  - `vulkan-wsi`'s **default** configuration string-imports the triangle's SPIR-V (`dub.sdl`; `triangle.d:406–407`). Removing the committed SPIR-V means the default build needs the device compiler, against `SHB5`. CI jobs that build the triangle examples without `ldc2-vulkan` break.
  - No output directory, opt-in configuration or prebuilt path is named.
  - The existing `src/shaders` holds the committed `test_pattern.*.spv`, which `SHP8` would delete.
  - `pName: "main"` and fragment-only push ranges need changes that the spec's "hands … their bindings and their layouts" does not cover. No reflection output exists.
- **Evidence:** `libs/vulkan-wsi/dub.sdl`; `triangle.d:126`, `:406`, `:458–462`, `:532`.
- **Correction:** Specify the consumer's configuration (`gpu-shaders` with `--if-stale`, its output directory `generated/shaders`, the `prebuilt` Nix path for CI) and the examples' selection (`SHB6`). Use the entry names as `pName`, for example through `__traits(identifier, …)`. Specify a `stagesOf!(entry)` or the equivalent push-constant stage information. Keep the test pattern out of the swept directory.

**R17: the triangle's module mode and tables are unspecified.** Affects `SHM1`, `SHM3`, `SHV8`, `SHF8`, testing.

- **Discrepancy:**
  - The host oracle and `stagesLink` on the host need a host-and-device module. `SHV8`'s stand-ins omit `@builtin` and `Builtin`.
  - The tables cannot be literals or globals (`SHM3`; constant tables arrive in M10), and the spec does not show the allowed form.
- **Evidence:** Probe P1 (the element-wise local array compiles); `vocabulary.md:121–127`; `PLAN.md` M10.
- **Correction:** State that the triangle module is `hostAndDevice`. Add `@builtin`, `Builtin` and `stagesLink` to `SHV8`. Name the table idiom and its capability consequence (R3).

**R18: the readback oracle is undefined.** Affects the M6 gate, testing "first consumer", `SHF8`.

- **Discrepancy:** "within one rasterisation rule" is not defined. Pixels "at the three vertices" lie on the triangle's edges, where coverage depends on the top-left rule. The colour comparison has no tolerance. Validation layers are not in the CI tier.
- **Evidence:** `PLAN.md:252–259`; `testing.md:127–131`; `nix/shells/default.nix:307–316`.
- **Correction:** Sample pixel centres inset from each vertex by a stated margin, with expected colour from host barycentrics at those centres, and a tolerance of 1 in 8-bit units (or `D12`'s bound). Assert coverage only away from edges. Run with `VK_LAYER_KHRONOS_validation` and fail on any message. Put the layers in `ciPackages` for that job.

**R19: `fragCoord` and `frontFacing` mean different things per profile.** Affects `SHF8`, contract item 2.

- **Discrepancy:** `vulkan1.3` requires `OriginUpperLeft`. spirv-cross drops the execution mode for GLSL 3.30 and ES 1.00 (probe P4), so `gl_FragCoord.y` is flipped relative to Vulkan, and front-facing winding flips with it. `SHF8` is silent.
- **Evidence:** Probe P4.
- **Correction:** Specify the convention for each profile, either as a documented difference or by having the compiler or step compensate (for example `y' = height − y` under GL, which needs the height). Add a scenario per profile.

**R20: `SHR1`'s host-callable `Sampler2D` contradicts `SHF1` and `SHV8`.** Affects `SHR1`, `SHF1`, `SHV8`, `SHX3`.

- **Discrepancy:** "Every kind must also be callable from host code with a host value — … a `Sampler2D` a host image" (M6). `SHF1` and `SHV8` say an entry that samples compiles only for the device. Host sampling is `SHX3` (M11).
- **Evidence:** `resources.md:33–35`; `entry-points.md:23–26`; `vocabulary.md:126–127`.
- **Correction:** Scope `SHR1`'s host clause to blocks and push constants in M6, with `Sampler2D` from M11.

**R21: the ledger and gate rest on stale evidence, and revisions are unmarked.** Affects `SHF2`, `SHF5`, `SHF6`, `SHV8`, the M6 gate, the SPEC banner.

- **Discrepancy:**
  - The revised `SHF2` (per-stage unity, resources), `SHF5` (vertex types), `SHF6` (interface-struct flattening) and `SHV8` (new stand-ins) keep `verified` rows from pre-revision tests (`testing.md:188–191`, `:182`). "Every M6 row of the ledger `verified`" therefore holds for them already.
  - `SHF6` and `SHF4` are not M6 obligations, though `SHF6` gained new behaviour.
  - SPEC's banner promises "each revised one is marked", yet `entry-points.md` marks none, and `SHF7` was rewritten entirely.
- **Evidence:** `PLAN.md:230–233`; `SPEC.md` banner.
- **Impact:** The evidence claims more than exists, and the guideline that "historical evidence remains historical … until revalidated" is breached.
- **Correction:** Mark revised requirements, split their ledger rows into a verified pre-revision part and a planned M6 part, and add `SHF6` to M6.

**R22: `size_t` arithmetic gives invalid SPIR-V or crashes the compiler.** Affects `SHP10`, `SHM3`, `SHT1`.

- **Discrepancy:** `% 3` on `size_t` produces `OpUMod %long`, which `spirv-val` rejects. `cast(size_t) idx + 1` used as an index trips `walkLogicalAccessChainConstant`'s assertion (probe P2). Neither reports a D source line.
- **Evidence:** Probe P1b, probe P2.
- **Impact:** Ordinary D code fails with no diagnostic. That is a contract the pinned compiler breaks.
- **Correction:** Record both as fork defects (the signed-integers flag must not apply to unsigned D operations; the access-chain walk must handle offset GEPs). Require a D-level diagnostic for any unsupported 64-bit construct, and add both shapes to the lit tests.

### Minors

**R23: `SHF8` and `SHF5` vocabulary.** The GLSL column uses Vulkan-dialect names (`gl_VertexIndex`, `gl_InstanceIndex`), where GL 3.30 has `gl_VertexID` and `gl_InstanceID`. "a profile that grants integer vertex inputs" names no capability. Stage capability names other than `fragmentStage` are not given. _Correction:_ name the capabilities, and mark the column as the Vulkan GLSL spelling.

**R24: the `SHC4` default rejects every unannotated `@vertex`.** The default (`gl330`, `gles100`) grants no vertex stage, so `SHF7` rejects every `@vertex` entry without `@profiles`. _Correction:_ state that, or default per stage.

**R25: audit attribution and mapping.**

- Capabilities are module-wide, so "the entry points whose module declares it" names every entry.
- The audit runs before `spirv-opt` and may reject a capability that optimisation would remove.
- `SHC1` does not make the SPIR-V capability and extension mapping (`Shader` included) part of the table.

_Correction:_ specify the mapping as a column of the table. Either attribute capabilities per entry, by re-auditing each per-entry output, or say plainly that the diagnostic lists the whole module.

**R26: `SHT3` covers GLSL only.** The new SPIR-V outputs are not in the reproducibility contract or the `shader-reproducibility` job. _Correction:_ extend both.

**R27: the capability table is not in the stamp.** Unless `sparkles.shaders.capabilities` is `@compute`, editing it (for example granting `int64`) changes which files exist and how the audit decides, while `--if-stale` reports fresh. That is consistent with `D14` but higher-impact. _Correction:_ make it a host-and-device module, or list it as a stamp input.

**R28: stale references.**

- "the fragment stage of section 6" (`toolchain.md:15`) and "the subject of section 6" (`testing.md:30`): SPEC has four sections.
- `D7` cites `SHF2` for the sampler.
- `D21` defines delivery as agreement "with the CPU executor", which cannot happen before M11, yet M6 is to be "delivered".

_Correction:_ fix the references, and qualify `D21` for milestones before M11.

**R29: default block details.** The block's type name (`SHR8`: "named after `T`"; is `T` `UniformsOf!entry`?) is not given. Whether a default block is emitted for an entry with no `@uniform` is not stated. The lowering for a profile granting both `uniforms` and `uniformBlocks` is unstated. _Correction:_ state all three.

**R30: zero entry points.** A unit whose device-only module has no entries compiles nothing. Its stamp has zero outputs, which `SHB2` treats as stale, so the step reruns on every build. _Correction:_ exit 2, as in R12.

**R31: scenario gaps for M6 obligations.** There is no scenario for:

- `SHV9` (integer vectors, `/` excluded)
- `SHP5` (one `OpEntryPoint` per `.spv`, unused interface variables removed)
- `SHP7` (`OpModuleProcessed` text)
- `SHP8` (sweep of `*.vert` and `*.spv`)
- `SHR7` (`@binding` accepted and honoured)
- `SHR6` (`ArrayStride`)
- `SHR1` (host-callable kinds)
- `SHC3` (the trait's values under each profile)
- `SHP4` (a module valid under universal rules but rejected under `vulkan1.3`, failing only the Vulkan profile)

The oracle table credits Vulkan readback with `SHR7`, which the triangle (no descriptors) does not exercise. `SHC10`'s example uses `@requires` and `unsupported` (M7) though `SHC10` is M6. _Correction:_ add the scenarios, and qualify the oracle row and the example.

**R32: `SHP1` and `SHC1` overclaim.** The fork always emits SPIR-V 1.6 for Vulkan 1.3 whichever of `vulkan-100`…`vulkan-140` is named (`targetVulkan.cpp:56`). A future `vulkan1.1` profile (`Q3`) therefore needs a compiler change, contrary to `SHC1`. _Correction:_ say the target selects only the code generator, and qualify `SHC1` ("…unless the profile needs a SPIR-V version the code generator does not emit").

## Dispositions

Every finding has a disposition, made in the revision under review. The
column _Where_ names the requirement or plan entry that now carries it.
"Fixed" means the specification was amended; the code that satisfies it is
M6's, and its evidence is the ledger row the M6 gate requires.

| ID  | Disposition       | What was done                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Where                                                       |
| --- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| R1  | Fixed             | A resource kind is a form of declaration, accepted under every profile of the slice; a profile's capabilities decide its lowering, given as a table per profile. `gl330` and `gles100` grant `looseUniforms` and neither `uniformBlocks` nor `pushConstants`, so a block lowers to loose uniforms on OpenGL.                                                                                                                                                                                                           | `SHR1`, `SHC2`                                              |
| R2  | Fixed             | The default uniform block is per entry point: a variable named `<entry>Uniforms`, of type `UniformsOf!entry`, named `<entry>UniformsBlock`; an entry point without `@uniform` has none. Each block is its own variable, so `SHF2`'s rule holds.                                                                                                                                                                                                                                                                        | `SHR3`, `SHR8`; scenario "Default blocks"                   |
| R3  | Fixed             | `vulkan1.3` denies `int64`. The compiler indexes with 32-bit integers under such a profile and reports any 64-bit operation at its D line. The triangle's tables are spike S2, and the readback runs with the validation layer.                                                                                                                                                                                                                                                                                        | `SHC2`, `SHM6`; `PLAN.md` M6 (S2, oracle)                   |
| R4  | Fixed             | The profile reaches the compiler as `-mdcompute-profile=<name>`, its name only; the table gives the name its meaning. Each profile has a D identifier and a name. An unknown name is rejected by the build step before compiling, and by `activeProfile` when a compiler is given it directly.                                                                                                                                                                                                                         | `SHC2`, `SHC3`                                              |
| R5  | Fixed             | The compiler keys an interface variable by stage, direction and name, so a vertex output and the fragment input it feeds coexist in one module.                                                                                                                                                                                                                                                                                                                                                                        | `SHF2`; scenario in Entry points                            |
| R6  | Fixed             | The shared sampler and the OpenGL bindings are restored, owned by `SHR7` and cited by `SHF2` and `D7`; the generated GLSL carries no binding qualifier.                                                                                                                                                                                                                                                                                                                                                                | `SHR7`, `SHF2`, `D7`; scenario in Entry points              |
| R7  | Fixed             | `@binding(b)` takes `b` ≥ 1, applies under `vulkan1.3` and is ignored on OpenGL; automatic numbering skips fixed bindings, and the sampler counts for clashes. A struct shared at different positions fixes its bindings once, on the struct.                                                                                                                                                                                                                                                                          | `SHR7`; scenario "Bindings"                                 |
| R8  | Fixed             | Every interface name of an entry point, after flattening and lowering, is distinct, block fields lowered to uniforms included; a clash names both declarations. A nested interface struct's field keeps its own name.                                                                                                                                                                                                                                                                                                  | `SHF2`, `SHR2`; scenario in Entry points                    |
| R9  | Fixed             | The limit is the `std430` size, which the host pushes, written by `writeLayout`. `stagesLink` requires two stages' push-constant blocks to have one type.                                                                                                                                                                                                                                                                                                                                                              | `SHR4`, `SHF9`; scenario "Push-constant size"               |
| R10 | Fixed (spike run) | Spike S1 was run before acceptance (2026-10-20): explicit offsets and strides through the backend's layout metadata validate for Vulkan 1.3 with no `Int8`, after three backend fixes. The one point it left open, a uniform block wrapped in a one-member struct (`Q5`), is settled as `D25`: the block is `T`.                                                                                                                                                                                                       | `PLAN.md` M6 (S1)                                           |
| R11 | Fixed             | `activeProfile` is `cpu` under a compiler without the trait; the fork gives `"cpu"` in a host compilation.                                                                                                                                                                                                                                                                                                                                                                                                             | `SHC3`; scenario in Profiles                                |
| R12 | Fixed             | The manifest is JSON, sorted, built with no profile active from declarations and attributes alone, in which `activeProfile` is an error. Profiles are compiled in the table's order; an empty manifest exits 2.                                                                                                                                                                                                                                                                                                        | `SHC5`, `SHP10`                                             |
| R13 | Fixed             | Kinds are not gated (R1). An unemitted entry point takes no part in `SHF2`'s rule. `gles100`'s bit-operation and loop-bound denials, which no M6 check could falsify, are removed. A requirement only `SHC8` would catch is caught from M7.                                                                                                                                                                                                                                                                            | `SHR1`, `SHC2`, `SHC6`, `SHC7`                              |
| R14 | Fixed             | Nothing is written until every profile has compiled, validated, passed the audit and been translated.                                                                                                                                                                                                                                                                                                                                                                                                                  | `SHP8`; scenario in the build step                          |
| R15 | Fixed             | The gate compares GLSL built by one toolchain from the source before the slice and after it, byte for byte, and the GPU readback of every effect with its readback before. `D19`, the plan and the scenario say the same.                                                                                                                                                                                                                                                                                              | `PLAN.md` M6 gate, `D19`; scenario "Unchanged output"       |
| R16 | Fixed             | `sparkles:vulkan-wsi` follows `sparkles:ui`: an opt-in `gpu-shaders` configuration generating into `generated/shaders/`, a default configuration without the renderer, the examples selecting it, CI taking the output prebuilt; the test pattern's SPIR-V leaves the swept directory; entry names as `pName`.                                                                                                                                                                                                         | `PLAN.md` M6 (consumer)                                     |
| R17 | Fixed             | The triangle module is host-and-device. A local static array filled element by element is allowed and shown; the host stand-ins for `@builtin` and `Builtin` are an M6 deliverable.                                                                                                                                                                                                                                                                                                                                    | `SHM3`; `PLAN.md` M6 (consumer, library, S2)                |
| R18 | Fixed             | Pixel centres inset two pixels from each vertex and the centroid, colour within 2 in 8-bit units of the host's barycentric blend, coverage only away from edges, and no validation-layer message.                                                                                                                                                                                                                                                                                                                      | `PLAN.md` M6 gate; scenario "The first consumer"            |
| R19 | Fixed             | `fragCoord` and `frontFacing` leave the first slice; they return in M7 with a convention stated per profile.                                                                                                                                                                                                                                                                                                                                                                                                           | `SHF8`                                                      |
| R20 | Fixed             | The host clause covers uniform blocks and push constants; `Sampler2D` becomes host-callable with the executor's images.                                                                                                                                                                                                                                                                                                                                                                                                | `SHR1`, `SHX3`                                              |
| R21 | Fixed             | Revised requirements are marked _(Revised.)_. The pre-revision rows of `SHF2`, `SHF5`, `SHF6` and `SHV8` are `partial`, their revised parts planned for M6, which now lists `SHF6`.                                                                                                                                                                                                                                                                                                                                    | `SPEC.md` banner; the ledger; `PLAN.md` M6                  |
| R22 | Fixed             | `SHM6` requires a diagnostic at the D line for any 64-bit operation the profile cannot express, and forbids a crash or an invalid module. The backend's unsigned division and remainder on signed-integer types are fixed upstream in M6, and the failing shapes join the lit tests. The spikes found the defect wider: `OpUDiv`, `OpUMod` and `OpConvertFToU` were invalid in signed-integer mode at every width. Both shapes now produce a valid module after two backend fixes; the D-line diagnostic remains M6's. | `SHM6`; `PLAN.md` M6 (compiler); scenario in Device modules |
| R23 | Fixed             | The column is labelled Vulkan GLSL; the capabilities are named (`intVertexInputs`, `vertexStage`, `fragmentStage`).                                                                                                                                                                                                                                                                                                                                                                                                    | `SHF8`, `SHF5`, `SHC2`                                      |
| R24 | Fixed             | A `@vertex` entry point without `@profiles` has no default profile and fails, naming it.                                                                                                                                                                                                                                                                                                                                                                                                                               | `SHC4`                                                      |
| R25 | Fixed             | The mapping from SPIR-V capabilities and extensions is part of the table. The audit runs on each written or translated per-entry module, after optimisation, and names the entry point.                                                                                                                                                                                                                                                                                                                                | `SHC1`, `SHC9`                                              |
| R26 | Fixed             | `SHT3` covers SPIR-V; the reproducibility job is extended in M6.                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `SHT3`; ledger row `SHT3 (SPIR-V)`                          |
| R27 | Fixed             | `sparkles.shaders.capabilities` is a host-and-device module, so it is in every unit and every stamp.                                                                                                                                                                                                                                                                                                                                                                                                                   | `SHC1`                                                      |
| R28 | Fixed             | The section references name pages; `D7` cites `SHR7`; `D21` defines agreement before M11 as agreement with the host execution of the same D functions.                                                                                                                                                                                                                                                                                                                                                                 | `toolchain.md`, `testing.md`, `D7`, `D21`                   |
| R29 | Fixed             | The default block's type and its absence without `@uniform` are stated; lowering is given per profile, so a later profile states its own.                                                                                                                                                                                                                                                                                                                                                                              | `SHR1`, `SHR3`, `SHR8`                                      |
| R30 | Fixed             | A unit without entry points exits 2.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | `SHC5`, `SHP10`                                             |
| R31 | Fixed             | Scenarios added for each listed obligation; the Vulkan readback oracle no longer claims `SHR7`; `SHC10`'s example notes that `@requires` and `unsupported` arrive in M7.                                                                                                                                                                                                                                                                                                                                               | `testing.md`; `SHC10`                                       |
| R32 | Fixed             | The target selects the code generator, not the SPIR-V version; a profile that needs a version the generator does not emit needs compiler work.                                                                                                                                                                                                                                                                                                                                                                         | `SHP1`, `SHC1`                                              |

A second, independent read of the amended pages found the amendments
incomplete in places, and they were completed before this record:

- `SHP4` audits after optimisation, as `SHC9` says.
- `SHP10` processes the profiles one at a time, in table order, and reports
  the first failure. An unknown profile exits 2.
- Binding 0 is reserved for the sampler, which is declared only with an image,
  and `@binding(0)` is an error.
- `SHF9` checks the bindings two stages share.
- `SHF2` covers the default block's names and defers bindings to `SHR7`.
- `SHR8` names the SPIR-V `OpName`s.
- The `cpu` profile has an explicit capability set.
- `gl330`'s denial of `uniformBlocks` is stated without hedging.
- `SHP1`, `SHM3`, `SHT3` and `SHV8` are marked revised, and their ledger
  rows are split.
- S1 names the requirements it reopens.
- The lit tests for R22's shapes and M7's return of the fragment built-ins
  are planned.

## Acceptance

On 2026-10-20 the project owner accepted the revision, its scope, library
ownership and non-goals, and every disposition above as recorded, `D17`'s
refinement included. The owner then settled the question spike S1 raised
(`Q5`, whether a Vulkan uniform block is `T` or a wrapper around it) as
[`D25`](./decisions.md#d25-a-vulkan-uniform-block-is-its-struct): the block
is `T`.

## Not covered

- **Vocabulary:** `SHV3`–`SHV7` were read only where the slice touches them.
- **Device modules and toolchain:** `SHM1`–`SHM5`, `SHT1`, `SHT2` and `SHT4` were unchanged at the reviewed commit and were not re-reviewed.
- **Build integration:** `SHB1`–`SHB7` were read only for their interaction with per-profile output (R14, R27, R30).
- **The executor:** `SHX1`–`SHX3` are outline-only by design. The `D20`–`D24` rationales were checked only for claims the spec does not make (`D16`, `D19`, `D21`, `D18`, above).
- **Not run:** no Vulkan readback, no lavapipe run, and no validation-layer run. The VUIDs cited are from the Vulkan specification, not observed.
- **Unmeasured:** the cost of one more front-end pass per profile (`D16`'s "revisit if").

## Appendix: probes

Each probe was compiled with:

```text
ldc2-vulkan -O2 -c -m64 -mdcompute-targets=vulkan-130 -mdcompute-file-prefix=<p> -od=<dir> \
    -I libs/shaders/src <probe>.d libs/shaders/src/sparkles/shaders/{types,math}.d
```

**P1, table lookup by `int`:**

```d
@compute(CompileFor.deviceOnly) module probe;
import ldc.dcompute;
import sparkles.shaders.types;

@fragment vec4 tableLookup(@input vec2 uv, @uniform int idx)
{
    vec4[3] t;
    t[0] = v4(1.0f, 0.0f, 0.0f, 1.0f);
    t[1] = v4(0.0f, 1.0f, 0.0f, 1.0f);
    t[2] = v4(0.0f, 0.0f, 1.0f, 1.0f);
    return t[idx];
}
```

The disassembly holds `OpCapability Int64`, `%long = OpTypeInt 64 1` and `%38 = OpSConvert %long %26`, and all three remain after `spirv-opt -O`. `spirv-val --target-env spv1.6`: valid. `--target-env vulkan1.3`: rejected only for the loose `int` uniform (`VUID-StandaloneSpirv-UniformConstant-04655`), the pre-revision lowering.

**P1b, `size_t` modulo:** `size_t i = cast(size_t) idx * 3 + 1; … return t[i % 3];`. `spirv-val`: `Expected unsigned int scalar or vector type as Result Type: UMod  %65 = OpUMod %long %55 %long_3`.

**P2, `size_t` offset index:** `size_t i = cast(size_t) idx + 1; … return t[i];`. The compiler aborts: `SPIRVEmitIntrinsics.cpp:859: … walkLogicalAccessChainConstant …: Assertion 'Offset < VT->getNumElements() * EltTypeSize' failed.`

**P3, provenance in SPIR-V:** an `OpModuleProcessed "Generated by shader-compile from probe"` line was inserted before the first `OpDecorate` of P1's optimised disassembly, then reassembled with `spirv-as --target-env spv1.6`. It is still present after `spirv-opt -O`, and `spirv-val --target-env vulkan1.3` reports only P1's uniform error.

**P4, `FragCoord` origin:** a hand-assembled fragment shader with `OpExecutionMode %main OriginUpperLeft` that writes `FragCoord`. `spirv-cross --version 330` and `--version 100 --es` both emit plain `gl_FragCoord`, with no `origin_upper_left` and no diagnostic.

**P5, `getTargetInfo`:** `enum p = __traits(getTargetInfo, "shaderProfile");` with `dmd`, `ldc2` and `ldc2-vulkan` (no target) gives the same error on all three: ``Error: `getTargetInfo` key `"shaderProfile"` not supported by this implementation``.

**P6, toolchain sensitivity:**

1. `dub run :shader-compile -- --package=libs/ui --out=<a> --keep`, then again into `<b>`.
2. `diff -r <a> <b>`: identical.
3. `diff -r <a> libs/ui/generated/shaders` (written 2026-10-16, `.stamp` inputs byte-identical to the current files): every file differs, only in temporary IDs (for example `bloomComposite.frag`, `_594` against `_550`).

The kept scratch module declares only `OpCapability Shader`.
