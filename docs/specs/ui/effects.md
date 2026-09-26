# `sparkles:ui` effects & images — Feature Requirements (`EFX`, `IMG`)

_**Status:** gates 1-3 and 5 delivered (images; the bracket and tier 0; tier 1
on the GPU, the registry and theme rebinding; single-source shaders). Gate 4
partial — the CRT's migration is scoped below · **Date:** 2026-09-19 ·
**Scope:** raster content (images) in the widget tree, and subtree effects —
the `pushEffect`/`popEffect` bracket, the tier model that decides what survives
to a cell grid, the effect registry, the re-expression of hue's CRT as an
effect on the root node, and the built-in effects as one D function each,
serving the terminal and the GPU (see
[`EFX20`](#one-source-two-targets-efx20)). Out of scope: raw pipeline access
(see [Non-goals](#non-goals))._

## Design & rationale

`sparkles:ui` is canvas-first and GL-free: a `view` produces a widget tree, the
tree produces a **display list of cell-space ops**, and each backend paints that
list. Today the op vocabulary is nine kinds (`canvas.d:89-99`) and can express
no raster content and no per-pixel treatment at all. The CRT effect that exists
(`sparkles:ui-raylib`'s `CrtEffect`) sits entirely **outside** that pipeline: it
brackets the whole frame, after the toolkit is done, and knows nothing about
widgets — which is why hue has to hand it a `CrtUiContext` of hand-derived
rectangles so it can pretend to know where the focused panel is.

This spec makes effects part of the pipeline instead of a post-pass bolted to
the end of it.

### An effect is shaped exactly like a clip

The display list already brackets subtrees: `pushClip`/`popClip` are two of the
nine ops, every canvas implements them, and `TGT12` settled how they nest.
`pushEffect`/`popEffect` is the same shape — bracket a subtree, let the backend
decide what that means — so it costs the op vocabulary two entries and the
canvas seam two optional primitives, and it reuses nesting rules that already
exist rather than inventing parallel ones.

The pay-off is that **the CRT becomes the degenerate case: an effect pushed on
the root node.** A post-process pass and a widget effect stop being two
mechanisms. This is why `sparkles:ui-app` does _not_ get a separate
post-process bracket: that would be this feature's root case, built twice.

### Tiers, because a cell grid is a real target

The toolkit's central claim is that one `view` serves the terminal and the
window. An effect system that only a GPU can honour would quietly turn that into
"one view, one of which is plainer". So effects are **tiered by what the effect
is allowed to read**, following SwiftUI's `colorEffect`/`distortionEffect`/
`layerEffect` split, because that is the axis along which a cell grid's ability
actually changes:

| Tier | Reads                                   | Cell grid | Example                   |
| ---- | --------------------------------------- | --------- | ------------------------- |
| 0    | its own position and colour             | **yes**   | tint, dim, desaturate     |
| 1    | position only, and rewrites it          | no        | barrel distortion, ripple |
| 2    | arbitrary samples of the rendered layer | no        | blur, glow, bloom         |

Tier 0 is a per-cell colour transform, which `ui-tui` can run directly. Tiers 1
and 2 need a texture and are GPU-only. Tiering makes degradation a property of
the tier — answerable once — instead of an argument re-litigated per effect.

### Non-goals

Raw pipeline access in the manner of **Flutter GPU** (`RenderPass`,
`CommandBuffer`, `DeviceBuffer`, `ShaderLibrary.fromAsset()`) is deliberately out
of scope. It is a different layer: Flutter ships it _alongside_
`FragmentProgram`/`ShaderMask` rather than instead of them, and it cannot be made
backend-neutral — a raw pass names a device API, which is the one thing the
`isCanvas` seam exists to prevent an application from doing. If it is ever
wanted it belongs behind a capability gate on a single backend, not in this
vocabulary.

## Images (`IMG`)

The first slice, and independent of every effect question: raster content needs
no tier system, and it is the one addition here with a genuine cell-grid answer
in principle — the kitty and sixel protocols.

$(B Correction.) This section originally claimed hue already carried protocol
detection. It does not: nothing under `apps/hue/` or `libs/tui/` mentions kitty
or sixel, and neither does `libs/base`'s `term_caps`, which is where such a
probe would belong. The research note that claim came from surveys other
terminals' detection, not ours. `IMG5` is scoped accordingly below.

| ID   | Requirement                                                                                                                                                                                                                            | Status | Traces to                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IMG1 | The op vocabulary must carry an **image** op addressing a decoded image by opaque handle, with a destination `Rect` in cells and a declared fit (fill, contain, cover). The op must not grow `DrawOp` past its current 64-byte budget. | full   | `canvas.d` `ImageDraw`/`OpKind.image`/`imageOp`; `CmdBufferT.image`; `static assert(DrawOp.sizeof <= 64)`; `ui.canvas.image.addressesByHandleAndCarriesItsAlt`                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| IMG2 | An `Image` widget must participate in layout as an ordinary box: an intrinsic cell size derived from pixel size and the canvas's cell metrics, subject to the same constraints as any other widget.                                    | full   | `WidgetKind.image`; `Widget.imagePixels`; `layout.d`'s `image` arms; `image.d` `imageCells`/`cellPixelsOf`; `ui.displayList.image.laysOutAsABoxAndEmitsOneOp`                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| IMG3 | Image data must be owned by a **registry outside the widget tree**, keyed by handle, so the flat arena stays flat and a relayout never re-decodes.                                                                                     | full   | `image.d` `ImageRegistry`/`ImageHandle`/`ImageData`; `ui.image.registry.handlesAreStableAndNeverReused`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| IMG4 | A canvas that cannot draw raster content must degrade **visibly and declaredly** — a placeholder box carrying the image's alt text — never silently skip the op.                                                                       | full   | `interp/immediate.d` `paintImagePlaceholder`; the `image` arms of `interp/html.d` and `interp/html_semantic.d`; `ui.interp.immediate.imageFallsBackToTheAltPlaceholder`                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| IMG5 | `ui-tui` must draw images through a terminal image protocol where one is detected, and fall back to `IMG4` otherwise. Protocol detection is the terminal's, not the toolkit's.                                                         | full   | `sparkles.tui.probe` (the kitty graphics query, `CSI 16 t`, fenced by DA1); kitty: `sparkles.tui.images` (`KittyImages`); sixel: `sparkles.tui.sixel` (`writeSixel`, `SixelImages`, with `Screen.damage`/`changedWithin`); `grid_canvas.d`'s `image` arm records placements where the image is wholly in view, outside an effect bracket, and — for sixel — off the last row. Tests `tui.images.*`, `tui.sixel.*`, `tui.probe.*`, `integration.pty.*`, `ui_tui.grid_canvas.kittyPlacement*`, `ui_tui.grid_canvas.sixelIsPlacedButNotOnTheLastRow`. Elsewhere the fallback is `GLY9`'s cell ladder, then `IMG4`. |

`IMG5` was first delivered half: the protocol needed two things the toolkit
does not own, and both now exist in `sparkles:tui`.

- **Detection.** `Terminal.probe` sends the query battery — the kitty graphics query among it — fenced
  by primary DA and waits for the fence or a short timeout (`CAP3`'s
  `images` row). It is opt-in (`RunConfig.probeTerminal`) because it puts
  bytes on the wire at startup. It skips Apple Terminal, which prints the
  query, and it does not believe DA1's sixel under a multiplexer. Keys typed
  meanwhile are replayed to the input decoder.
- **A channel beside the cells.** The images of a frame travel next to the grid
  as placements, and `KittyImages` diffs them the way `Screen` diffs cells,
  inside the same synchronized frame.

**Sixel** came second, and costs more than kitty. Its pixels live in the cell
layer, so `SixelImages` damages the cells an image left for the diff to
repaint, and draws an image again when any of its cells were rewritten. It
needs the cell's pixel size: the kernel's where the window reports one, else
the terminal's answer to `CSI 16 t`. An image on the last row is rastered,
because the cursor lands below a sixel picture and the screen would scroll.
A hardware scroll moves what the terminal drew, so after one every image, of
either protocol, is placed again. Below the protocol, an
image in a terminal is drawn in cells: the design system's `GLY9` ladder
rasters it in the finest block elements the target's `blocks` tier holds
(else braille), two colours per cell. A target with no cell rung, or a host
that bound no registry, gets `IMG4`'s placeholder. Both are declared
degradations (`image-rastered`, `image-as-alt`), drawn through _shared_
routines, so the terminal cannot drift from a window previewing the same
target.

## The effect bracket (`EFX1`–`EFX6`)

| ID   | Requirement                                                                                                                                                                                                           | Status | Traces to                                                                                                                                                    |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| EFX1 | The op vocabulary must carry `pushEffect`/`popEffect`, bracketing every op emitted for a subtree, carrying an `EffectId` and the subtree's `Rect`.                                                                    | full   | `canvas.d` `PushEffect`/`PopEffect`/`OpKind.pushEffect`/`pushEffectOp`; `CmdBufferT.pushEffect`; `DrawOp.effectId`                                           |
| EFX2 | Effects must nest, and a nested effect must compose with its ancestors rather than replace them — the same reading `TGT12` settled for clips, and stated in the same place.                                           | full   | `GridCanvas.popEffect` (the inner bracket pops first, the outer over its result); `ui_tui.grid_canvas.nestedEffectsComposeWithTheirAncestors`                |
| EFX3 | `pushEffect`/`popEffect` must be **optional canvas primitives**, discovered by presence. A canvas that does not implement them paints the bracketed subtree unaffected; this is a declared degradation, not an error. | full   | the `PushEffect`/`PopEffect` arms of `interp/immediate.d`; `ui.interp.immediate.effectBracketIsOptionalAndDegradesToUnaffected`                              |
| EFX4 | A widget must carry at most one effect id; the tree stores the id, never an implementation, and the id must be small enough to leave the widget arena flat.                                                           | full   | `Widget.effect`; `EffectId` (one `uint`)                                                                                                                     |
| EFX5 | Effect brackets must be emitted by `buildDisplayList` from the widget tree, so every consumer of the display list — including the headless `--render` target — sees the same structure.                               | full   | `display_list.d`'s `bracketed` push/pop; `ui.displayList.effect.bracketsTheSubtreeAndNeverMovesIt`; `ui-gallery`'s `--render` path passes an `EffectContext` |
| EFX6 | An effect must never change layout. The bracketed subtree's geometry is decided before the effect is known, so that turning an effect off cannot reflow the page.                                                     | full   | `layout.d` reads no effect field; `ui.displayList.effect.bracketsTheSubtreeAndNeverMovesIt` compares frames with and without                                 |

## Tiers and degradation (`EFX7`–`EFX12`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                            | Status | Traces to                                                                                                                                                                                                      |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFX7  | Every effect must declare its tier. The tier is the contract: it says what the effect may read, and therefore which canvases can honour it.                                                                                                                                                                                                                            | full   | `EffectTier`; `EffectRecord.tier`                                                                                                                                                                              |
| EFX8  | A **tier-0** effect is a pure colour transform: `(Point, RgbColor) -> RgbColor`, over the resolved `Ink` of each cell. It must be expressible with no texture and no neighbour reads.                                                                                                                                                                                  | full   | `Tier0Fn`/`Tier0Input` (a struct, so the input can grow without resigning every effect); `GridCanvas.applyTier0`                                                                                               |
| EFX9  | `ui-tui` must honour tier-0 effects by applying the transform per cell as it composites, and must ignore tiers 1 and 2 per `EFX3`.                                                                                                                                                                                                                                     | full   | `GridCanvas.pushEffect`/`popEffect`/`applyTier0`; `EffectContext`; `ui_tui.grid_canvas.tier0EffectLandsInTheTerminal`                                                                                          |
| EFX10 | A tier-0 transform must be `@safe pure nothrow @nogc`. It runs per cell, and the constraint is also what keeps `EFX20` reachable.                                                                                                                                                                                                                                      | full   | `Tier0Fn`'s declared attributes — a transform that allocates does not compile                                                                                                                                  |
| EFX11 | Tier-1 and tier-2 effects require rendering the bracketed subtree to a texture. A GPU backend must scope that texture to the bracket, and nested brackets must not require more than one texture per nesting level **beyond the intermediates a multi-pass effect declares** (`EffectPass`), which are pooled per (depth, stage, size) and never shared across depths. | full   | `ui_raylib.effect_gpu` `EffectGpu.open`/`close` and its pass runner; the (depth, stage, size) texture pool; `scissorBoxOf`; `RaylibCanvas.pushEffect`/`popEffect`; `Builtin.bloom` (`isAMultiPassTier2Effect`) |
| EFX12 | Every registered effect must name the behaviour it degrades to on a canvas that cannot honour its tier — including "unaffected", stated rather than assumed.                                                                                                                                                                                                           | full   | `Degradation`/`EffectRecord.degradation`; read by `ui-gallery`'s Effects page (`degradationNote`) and asserted by `ui_gallery.pages.effectsBracketsEveryTier0Builtin`                                          |

## The registry (`EFX13`–`EFX19`)

Effects are registered at **runtime**, uniformly across all tiers: one mechanism,
one lookup, one place a hot-reloaded shader can be swapped while it is being
tuned by eye. The alternative — compile-time effect values, capability-checked
per backend — was considered and rejected; the decision and what it costs are
recorded in [Decisions](#decisions).

| ID    | Requirement                                                                                                                                                                                                                | Status | Traces to                                                                                                                                                                                                                                                                                                                                                                 |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFX13 | One runtime registry maps `EffectId` to a record carrying the tier, the tier-0 transform where present, per-backend implementations, and the `EFX12` degradation.                                                          | full   | `EffectImpl`/`glslBackend`/`EffectRecord.implFor`; `EffectParam`/`EffectRegistry.setParams`; `ui.effect.builtins.eachCarriesBothHalvesOfItsTwin`                                                                                                                                                                                                                          |
| EFX14 | Ids must be stable for the life of a run. A registry that reuses an id after removal would silently repaint a subtree with someone else's effect.                                                                          | full   | `EffectRegistry.remove` keeps the slot; `ui.effect.registry.resolvesAndNeverReusesAnId`                                                                                                                                                                                                                                                                                   |
| EFX15 | The toolkit must pre-register a small **built-in set**, whose ids are constants an app can name without registering anything.                                                                                              | full   | `Builtin` — `scanlines`, `phosphor`, `dim`, `spectrum`, `curvature` as `EffectId` constants, resolved by every `EffectRegistry` from the moment it is declared (`areConstantsInEveryRegistry`). An untouched registry answers from `builtinRecords` evaluated at compile time; the first mutation seeds it through `register`, so the constants and `EFX19` hold together |
| EFX16 | A `Theme` must be able to rebind a built-in id — including to nothing — so a design language can turn an effect off without the view changing. App-registered ids are not themeable; they have no semantic name to rebind. | full   | `ThemeEffects`/`EffectBinding` on `Theme`; `applyThemeEffects`; `ui.effect.theme.rebindsABuiltinWithoutTheViewChanging`; demo `UIG_EFFECTS=off`                                                                                                                                                                                                                           |
| EFX17 | An unregistered id must paint the subtree unaffected, never abort. An effect is decoration; a missing one must not be able to take the frame down.                                                                         | full   | `EffectRegistry.lookup` returns null for a null/stale/out-of-range id; `GridCanvas.pushEffect` still occupies a stack slot so the pair cannot desynchronise                                                                                                                                                                                                               |
| EFX18 | Re-registering an id must be safe **between** frames and must not be observable mid-frame, so a shader can be hot-reloaded while the settings pane is open.                                                                | full   | `EffectRegistry.replace`; a bracket resolves once at `pushEffect`, so a swap lands whole or not at all                                                                                                                                                                                                                                                                    |
| EFX19 | Registration must be the only mechanism. There is no second, compile-time path: `EFX20` is served by registering artifacts that were _generated_ at compile time, not by a parallel API.                                   | full   | `EffectRegistry.seed` passes each of `builtinRecords` through the same append `register` uses; there is no `final switch` over ids anywhere                                                                                                                                                                                                                               |

### One source, two targets (`EFX20`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                    | Status | Traces to                                                                                                                                                                                                                                                                                                                        |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFX20 | A tier-0 transform must be **one D function serving both targets**: called per cell by `ui-tui`, and compiled to the GPU's shader from that same source. The registry stores both artifacts; it must never be the case that the GPU and terminal paths are two hand-written implementations that can disagree. | full   | `sparkles.ui.effect_shaders` — the four built-ins and the tier-1 warp, written once against `sparkles:shader`; `effect.d`'s `tier0Adapter` calls them per cell; `libs/ui/shaders/effects.d` wraps them in `@fragment` entry points; `shader-compile` derives `libs/ui/src/sparkles/ui/shaders/*.frag`; `shader-compile --verify` |
| EFX25 | The generated GPU artifact must be **reproducible and guarded**: regenerating from the D source must yield the committed GLSL byte for byte, and a build must not need the shader compiler — only the committed GLSL.                                                                                          | full   | `shader-compile --verify` diffs a fresh derivation against `generated/` and reports stale files; it skips with exit 0 when no dcompute-enabled LDC is present (what CI sees), so the committed GLSL is what `sparkles:ui` string-imports and nothing else                                                                        |
| EFX26 | The shader vocabulary must run on the CPU on every supported compiler, with GLSL's semantics: `mod` follows the divisor's sign, `clamp`/`mix`/`step`/`smoothstep` are the specification's formulas, and a `vec3` never crosses the shader interface (so its representation may differ per side).               | full   | `sparkles.shader.testing` under LDC and DMD; `vec2`/`vec4` are native vectors under LDC and a struct elsewhere, `vec3` a struct on every host and native only in the device build (`LDC_DCompute`)                                                                                                                               |
| EFX27 | The GPU artifact is a **complete** fragment shader against the backend's pipeline — inputs, sampler, uniforms and output all declared — so the backend loads it as-is and wraps nothing. The tier is what the shader does, not what a backend prepends.                                                        | full   | `ui_raylib.effect_gpu` has no prologue or epilogue any more; `ui.effect.builtins.eachCarriesBothHalvesOfItsTwin` checks `#version`, `main`, `texture0`, `fragTexCoord`; glslang validates every generated file in `shader-compile`                                                                                               |
| EFX28 | A shader module must be **diagnosable in the editor as the device build sees it**: analyzed with the dcompute LDC's runtime, versions and rules, a correct `@compute` module shows no errors, and one the device build would reject shows that build's error.                                                  | full   | `sparkles:dmd-lsp` target profiles — [`TGT1`–`TGT9`](../dmd-lsp/targets.md); the package's `shaders` dub configuration is shared by the build and the analysis                                                                                                                                                                   |

**How the one function reaches the GPU.** `libs/ui/shaders/effects.d` is a
`@compute(CompileFor.deviceOnly)` module holding one `@fragment` function per
effect — a thin wrapper that samples `texture0`, floors `fragTexCoord *
uExtentCells` to the cell (the very `at` the terminal hands the function) and
calls the transform. `shader-compile` compiles it, together with
`effect_shaders.d` and the vocabulary, through LDC's Vulkan dcompute target to
SPIR-V, validates that, optimises it, and cross-compiles each entry point with
spirv-cross to desktop GLSL 330 and GLSL ES 100 — the two dialects `ui-raylib`
speaks — proving each with glslang. `effect.d` string-imports the result. The compiler ships as dlang.nix's `ldc-vulkan`, and `nix run .#shader-compile` is the tool wrapped with it and the SPIR-V tools. The
compiler is LDC's `sparkles/vulkan-shaders` branch: upstream's Vulkan compute
target ([ldc#5132](https://github.com/ldc-developers/ldc/pull/5132) over
[llvm#216919](https://github.com/llvm/llvm-project/pull/216919)) plus
`@fragment`, `@input`/`@uniform` parameter markers, and `Sampler2D` — the
graphics stage upstream dcompute does not have, and what the thread that
started this work ([forum](https://forum.dlang.org/thread/qrfvwkubyceuamcvdeya@forum.dlang.org))
described as compute-only.

Three facts shaped the design, and each is a constraint the SPIR-V backend
imposes rather than a choice:

- **An opaque handle is a scalar.** Vulkan forbids an image or sampler inside
  a composite or in a Function-storage variable, and the backend cannot pass
  one as a function argument. So GLSL's combined `sampler2D` is modelled as
  the image handle alone, every image is read through one shared sampler at
  binding 0, and every helper in a Vulkan module is always-inline, so the
  handle and the sample that reads it end in one function.
- **Uniforms are GL's shape, not Vulkan's.** raylib looks uniforms up by name,
  so a `@uniform` parameter becomes a plain `UniformConstant` variable named
  after it — valid SPIR-V, invalid under Vulkan's rules, exactly right after
  spirv-cross. Validation runs under the universal rules; a Vulkan `isCanvas`
  backend, when it exists, wants these as a push-constant block, which is a
  target flag away.
- **Aggregates stay out of memory.** A struct `vec3` copied by `memcpy` is a
  load the backend cannot legalise, which is why the device build uses a
  native 12-byte vector for `vec3` while the host — where stock LDC sizes that
  vector at 12 bytes and LLVM at 16 — uses three floats.

## The CRT, re-expressed (`EFX21`–`EFX24`)

| ID    | Requirement                                                                                                                                                                                                                                                                 | Status | Traces to                                                                                                                                                                                                                                                                                                                                                        |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFX21 | The CRT must be expressible as an effect bracketed on the **root node**, not as a frame-level pass outside the pipeline.                                                                                                                                                    | full   | `CrtEffect.effectRecord` — a four-pass tier-2 record (`bloomPasses`' three, then the tube) — registered by hue and emitted as the first `pushEffect` of its frame (`gui.d` `crtEffect`); `CrtEffect.writeParams` updates its values in place each frame; `ui_raylib.crt.isATier2EffectOnTheRoot`. Checked byte-for-byte against the pass it replaced (see below) |
| EFX22 | `sparkles:ui-app` must not grow a separate post-process bracket. `EFX21` is that feature; two mechanisms for one thing is what this spec exists to avoid.                                                                                                                   | full   | grep-checkable — searching `libs/ui-app/src` for the words post-process or post-pass (spelled as one word, case-insensitively) finds nothing, and `EFX21`'s bracket is the mechanism that would otherwise have justified one                                                                                                                                     |
| EFX23 | Once `EFX21` holds, `CrtUiContext` must be **harvested from the display list** — the rects the frame actually emitted, per `Slot` — never re-derived by an application. The present hand-derivation in `hue` is the debt this retires.                                      | full   | `sparkles.ui.frame_list` (`FrameList`, `focusedExtent`, `firstOfSlot`, `textAt`, `scrollbarThumbOf`) and `crtUiContextOf` (`uiContextIsHarvestedFromTheFrame`); hue emits every whole-cell paint site into one `FrameList` and calls it — the per-site derivations, and the rects the modals used to stash for the halo, are gone                                |
| EFX24 | The CRT's curvature and lens are tier-1; its scanlines, phosphor mask and vignette are tier-0 and must therefore survive to `ui-tui`. A terminal showing scanlines and a phosphor tint is the proof that the tier split is real and not a GPU feature wearing a tier label. | full   | Tier 0 in a terminal: `ui-gallery --render --page effects` shows scanlines, phosphor, dim and spectrum; `ui_tui.grid_canvas.tier0EffectLandsInTheTerminal`. Tier 1 in a window: the same page under `--gui`                                                                                                                                                      |

### Why the registry landed in gate 2

The gate order put the registry third, and that turned out not to be
schedulable. Tier-0 cannot be shown working without resolving an `EffectId`,
and the obvious stopgap — a `final switch` over built-in ids, with the real
registry arriving later — is precisely the second, compile-time path `EFX19`
forbids. Building it would have meant writing the thing the spec rules out and
then deleting it.

So `EffectRegistry` landed with the bracket, the built-ins are registered
through it like anything else, and gate 3 keeps only what genuinely needs a
GPU: per-backend artifacts (`EFX13`), `EFX11`'s texture, and `EFX16`'s theme
rebinding.

### The degradation runs the other way

Until `EFX11` lands, an effect shows in the **terminal** and not in the
**window**. That reads backwards, and it is worth stating plainly rather than
letting it look like a bug: tier 0 is a per-cell colour transform, which a cell
grid runs directly and a GPU wants as a shader over a per-bracket texture it
does not yet have. It is also the clearest evidence so far that the tier axis
is the right one — the split fell along "what can read what", not along "which
backend is fancier".

### How the CRT became an effect

`EFX21` and `EFX23` were `partial` for two different reasons, and each needed
its own piece of machinery rather than a special case for the CRT.

- **Multi-pass, as data.** The CRT's bloom is three passes over two ping-pong
  targets, and a bracket was one pass. `EffectPass` declares a pass as data —
  a complete shader, an output downscale, the image it draws and the images
  it samples — and `EffectGpu.close` runs the chain over intermediates pooled
  per (depth, stage, size). `bloom` became the first tier-2 built-in, and the
  CRT is bloom's first three passes plus the tube's composite
  (`CrtEffect.effectRecord`). `EFX11`'s "one texture per nesting level" now
  reads "beyond the intermediates a multi-pass effect declares".
- **A clock.** Five of the CRT's terms read the time — the sync jitter, the
  roll bar, the phosphor flicker, the focus pulse and the aberration wobble
  (the old count of four missed the last). The backend supplies `uTime` to
  every pass from `EffectGpu.clock`, which the host sets per frame or pins for
  a capture (`pinEffectClock`), so `DBG1` holds for every effect.
- **One op stream.** hue painted through about ten canvases, one per origin,
  so there was no list to harvest from. Every paint site whose origin is a
  whole cell now emits into one `FrameList`, which translates, records and
  paints at once — the order against the pixel chrome that stays outside
  (the toast, the popup, sub-cell hairlines, anything anchored to the
  window's pixel edge) is unchanged — and `crtUiContextOf` reads the focus,
  selection, split, hover and thumb out of it by `Slot`.

The evidence is byte-level, with the clock pinned. The CRT-off frames — the
readme, the tree, a preview, a search, the inspector, the key guide, the
picker, the settings pane — are identical before and after both changes.
With the CRT on, the effect path is identical to the pass it replaced once
its intermediates are filtered the same way (nearest texel); as shipped they
filter bilinearly, which is what turns a half-size glow from a halftone into
a glow, and the frames differ in about 0.5% of pixels by at most 1/255. The
comparison also found a real bug — the bright pass weighted by alpha, which
antialiased text leaves just under 1 — and it was fixed rather than
tolerated.

## Decisions

- **Effects bracket like clips rather than becoming a widget kind.** A widget
  kind would need layout, hit-testing and a place in the arena; a bracket needs
  neither and reuses `TGT12`'s nesting rules. `EFX6` makes the consequence
  explicit: an effect cannot move anything.
- **Tiered by readable input, not by cost or by name.** The alternative — every
  effect declaring its own fallback with no taxonomy — puts the same argument in
  front of every author and makes "no fallback" the path of least resistance.
  Tiers answer it once, and `EFX24` keeps the tier-0 tier honest by requiring
  something real to land in the terminal.
- **One runtime registry for every tier, not a compile-time/runtime split by
  tier.** The split was proposed on the grounds that tier-0 runs per cell on the
  CPU and so wants inlining and compile-time capability checks, while tiers 1–2
  select a pipeline once per pass. That argument was **overstated on two of its
  three points** and is recorded here so it is not re-litigated from memory:
  - The per-cell indirect call is negligible. A terminal is on the order of
    10 000 cells; at 60 fps, and only for cells under an effect bracket, that is
    well under a millisecond per second of wall time. The `DrawOp` 656→64 byte
    precedent is about bandwidth over the whole op stream and does not transfer.
  - It does **not** foreclose `EFX20`, and `EFX20` proved it: LDC compiles a
    `@fragment` function to SPIR-V at build time; the registry then stores the
    GLSL derived from that alongside the CPU function pointer, both from one
    source. Registration is of _results_, and results are generated at build
    time.
  - What is genuinely lost is compile-time capability checking: `hasTier0!E`
    becomes a runtime lookup, so `EFX12` and `EFX17` carry a guarantee the type
    system would otherwise have carried. That is the accepted cost, and it buys
    `EFX18` — hot-reload while tuning, which the CRT's live settings pane shows
    is how these are actually developed.
- **No raw pipeline access.** See [Non-goals](#non-goals).

## Delivery gates

1. ~~**Images** (`IMG1`–`IMG5`)~~ — **delivered**, except `IMG5`'s protocol
   half (above). The op vocabulary grew by one entry and `DrawOp` is still 64
   bytes; the budget assert caught the first attempt, which carried a whole
   `Ink` and reached 72.
2. ~~**The bracket** (`EFX1`–`EFX6`) plus tier-0 in `ui-tui` (`EFX7`–`EFX10`),
   with at least one built-in effect visibly landing in a terminal
   (`EFX24`)~~ — **delivered**, and it pulled most of gate 3's registry
   forward with it (below).
3. ~~**Tier-1/2 on `ui-raylib`** (`EFX11`), plus the registry rows gate 2 left
   open: per-backend implementations (`EFX13`) and theme rebinding
   (`EFX16`)~~ — **delivered**. Tier 2 (`layer`) got its first built-in,
   `bloom`, later — and this line used to say that was "an effect to write,
   not a gate". It was not: a glow is several passes over intermediates, and
   a bracket was one pass. Multi-pass is now declared as data (`EffectPass`)
   and run by `EffectGpu.close`.
4. ~~**The CRT re-expressed** (`EFX21`–`EFX23`)~~ — **delivered**: the CRT
   is a tier-2 effect on the root of one op stream, and its UI context is
   harvested from it — see "How the CRT became an effect".

5. ~~**One source, two targets** (`EFX20`, `EFX25`–`EFX27`)~~ — **delivered**,
   without waiting for a Vulkan `isCanvas` backend: the GPU artifact is GLSL
   derived from SPIR-V, so the raylib backend consumes it today, and the same
   SPIR-V is what a Vulkan backend would load directly.
