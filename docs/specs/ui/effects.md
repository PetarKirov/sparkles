# `sparkles:ui` effects & images — Feature Requirements (`EFX`, `IMG`)

_**Status:** gates 1-3 delivered (images; the bracket and tier 0; tier 1 on the
GPU, the registry and theme rebinding). Gate 4 partial — the CRT's migration
is scoped below · **Date:** 2026-09-18 · **Scope:** raster content (images)
in the widget tree, and subtree effects — the `pushEffect`/`popEffect` bracket,
the tier model that decides what survives to a cell grid, the effect registry,
and the re-expression of hue's CRT as an effect on the root node. Out of scope:
raw pipeline access (see [Non-goals](#non-goals)) and shader authoring in D (see
[`EFX20`](#the-dcompute-horizon-efx20))._

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

| ID   | Requirement                                                                                                                                                                                                                            | Status  | Traces to                                                                                                                                                               |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IMG1 | The op vocabulary must carry an **image** op addressing a decoded image by opaque handle, with a destination `Rect` in cells and a declared fit (fill, contain, cover). The op must not grow `DrawOp` past its current 64-byte budget. | full    | `canvas.d` `ImageDraw`/`OpKind.image`/`imageOp`; `CmdBufferT.image`; `static assert(DrawOp.sizeof <= 64)`; `ui.canvas.image.addressesByHandleAndCarriesItsAlt`          |
| IMG2 | An `Image` widget must participate in layout as an ordinary box: an intrinsic cell size derived from pixel size and the canvas's cell metrics, subject to the same constraints as any other widget.                                    | full    | `WidgetKind.image`; `Widget.imagePixels`; `layout.d`'s `image` arms; `image.d` `imageCells`/`cellPixelsOf`; `ui.displayList.image.laysOutAsABoxAndEmitsOneOp`           |
| IMG3 | Image data must be owned by a **registry outside the widget tree**, keyed by handle, so the flat arena stays flat and a relayout never re-decodes.                                                                                     | full    | `image.d` `ImageRegistry`/`ImageHandle`/`ImageData`; `ui.image.registry.handlesAreStableAndNeverReused`                                                                 |
| IMG4 | A canvas that cannot draw raster content must degrade **visibly and declaredly** — a placeholder box carrying the image's alt text — never silently skip the op.                                                                       | full    | `interp/immediate.d` `paintImagePlaceholder`; the `image` arms of `interp/html.d` and `interp/html_semantic.d`; `ui.interp.immediate.imageFallsBackToTheAltPlaceholder` |
| IMG5 | `ui-tui` must draw images through a terminal image protocol where one is detected, and fall back to `IMG4` otherwise. Protocol detection is the terminal's, not the toolkit's.                                                         | partial | `grid_canvas.d`'s `image` arm (the fallback half, through `IMG4`'s shared routine). The protocol half is **not built** — see below.                                     |

`IMG5` is deliberately half-delivered, and the half that is missing is the one
that needs something this slice does not own:

- **There is no detection to consult.** `term_caps` probes size, tty, colours
  and unicode; no kitty/sixel probe exists anywhere in the tree. `IMG5` says
  detection is the terminal's answer, so it belongs in `term_caps`, not here.
- **`sparkles:tui` has no passthrough channel.** A kitty or sixel image is an
  escape sequence placed at a cursor position; the `Screen` compositor diffs a
  grid of cells and has no way to carry one. Adding that channel is a change to
  the terminal substrate's contract, not to the toolkit's op vocabulary.

Until both exist, every image in a terminal takes `IMG4`'s placeholder — which
is a declared degradation rather than a gap, and is drawn through the _shared_
routine so the terminal cannot drift from the window.

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

| ID    | Requirement                                                                                                                                                                                                         | Status | Traces to                                                                                                                                                             |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFX7  | Every effect must declare its tier. The tier is the contract: it says what the effect may read, and therefore which canvases can honour it.                                                                         | full   | `EffectTier`; `EffectRecord.tier`                                                                                                                                     |
| EFX8  | A **tier-0** effect is a pure colour transform: `(Point, RgbColor) -> RgbColor`, over the resolved `Ink` of each cell. It must be expressible with no texture and no neighbour reads.                               | full   | `Tier0Fn`/`Tier0Input` (a struct, so the input can grow without resigning every effect); `GridCanvas.applyTier0`                                                      |
| EFX9  | `ui-tui` must honour tier-0 effects by applying the transform per cell as it composites, and must ignore tiers 1 and 2 per `EFX3`.                                                                                  | full   | `GridCanvas.pushEffect`/`popEffect`/`applyTier0`; `EffectContext`; `ui_tui.grid_canvas.tier0EffectLandsInTheTerminal`                                                 |
| EFX10 | A tier-0 transform must be `@safe pure nothrow @nogc`. It runs per cell, and the constraint is also what keeps `EFX20` reachable.                                                                                   | full   | `Tier0Fn`'s declared attributes — a transform that allocates does not compile                                                                                         |
| EFX11 | Tier-1 and tier-2 effects require rendering the bracketed subtree to a texture. A GPU backend must scope that texture to the bracket, and nested brackets must not require more than one texture per nesting level. | full   | `ui_raylib.effect_gpu` `EffectGpu.open`/`close`; the (depth, size) texture pool; `scissorBoxOf`; `RaylibCanvas.pushEffect`/`popEffect`                                |
| EFX12 | Every registered effect must name the behaviour it degrades to on a canvas that cannot honour its tier — including "unaffected", stated rather than assumed.                                                        | full   | `Degradation`/`EffectRecord.degradation`; read by `ui-gallery`'s Effects page (`degradationNote`) and asserted by `ui_gallery.pages.effectsBracketsEveryTier0Builtin` |

## The registry (`EFX13`–`EFX19`)

Effects are registered at **runtime**, uniformly across all tiers: one mechanism,
one lookup, one place a hot-reloaded shader can be swapped while it is being
tuned by eye. The alternative — compile-time effect values, capability-checked
per backend — was considered and rejected; the decision and what it costs are
recorded in [Decisions](#decisions).

| ID    | Requirement                                                                                                                                                                                                                | Status  | Traces to                                                                                                                                                                                                                                   |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFX13 | One runtime registry maps `EffectId` to a record carrying the tier, the tier-0 transform where present, per-backend implementations, and the `EFX12` degradation.                                                          | full    | `EffectImpl`/`glslBackend`/`EffectRecord.implFor`; `EffectParam`/`EffectRegistry.setParams`; `ui.effect.builtins.eachCarriesBothHalvesOfItsTwin`                                                                                            |
| EFX14 | Ids must be stable for the life of a run. A registry that reuses an id after removal would silently repaint a subtree with someone else's effect.                                                                          | full    | `EffectRegistry.remove` keeps the slot; `ui.effect.registry.resolvesAndNeverReusesAnId`                                                                                                                                                     |
| EFX15 | The toolkit must pre-register a small **built-in set**, whose ids are constants an app can name without registering anything.                                                                                              | partial | `builtinEffects`/`BuiltinEffects` — scanlines, phosphor, dim, spectrum, curvature. The ids are **returned values, not constants**: they cannot be compile-time constants while `EFX19` requires them to come from the one registration path |
| EFX16 | A `Theme` must be able to rebind a built-in id — including to nothing — so a design language can turn an effect off without the view changing. App-registered ids are not themeable; they have no semantic name to rebind. | full    | `ThemeEffects`/`EffectBinding` on `Theme`; `applyThemeEffects`; `ui.effect.theme.rebindsABuiltinWithoutTheViewChanging`; demo `UIG_EFFECTS=off`                                                                                             |
| EFX17 | An unregistered id must paint the subtree unaffected, never abort. An effect is decoration; a missing one must not be able to take the frame down.                                                                         | full    | `EffectRegistry.lookup` returns null for a null/stale/out-of-range id; `GridCanvas.pushEffect` still occupies a stack slot so the pair cannot desynchronise                                                                                 |
| EFX18 | Re-registering an id must be safe **between** frames and must not be observable mid-frame, so a shader can be hot-reloaded while the settings pane is open.                                                                | full    | `EffectRegistry.replace`; a bracket resolves once at `pushEffect`, so a swap lands whole or not at all                                                                                                                                      |
| EFX19 | Registration must be the only mechanism. There is no second, compile-time path: `EFX20` is served by registering artifacts that were _generated_ at compile time, not by a parallel API.                                   | full    | `builtinEffects` registers rather than special-cases; there is no `final switch` over ids anywhere                                                                                                                                          |

### The dcompute horizon (`EFX20`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                   | Status  | Traces to |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | --------- |
| EFX20 | A tier-0 transform must remain expressible as **one D function serving both targets**: called per cell by `ui-tui`, and — on a backend that can dispatch it — compiled to SPIR-V from that same source. The registry stores both artifacts; it must never be the case that the GPU and terminal paths are two hand-written implementations that can disagree. | planned | —         |

Two facts bound this, and neither is a blocker:

- **dcompute's Vulkan SPIR-V work is compute-kernel only**, not graphics — its
  tests are `@kernel()` / `@CompileFor.deviceOnly`. That is sufficient: a tier-0
  transform is per-pixel with no neighbour reads, which is a compute dispatch
  over the texture and never needs to be a fragment shader.
- **The dispatch lands on a Vulkan backend, not the raylib one.** `sparkles:vulkan`
  and `sparkles:vulkan-wsi` exist; an `isCanvas` implementation over them does
  not. Until it does, a tier-0 effect's GPU path on `ui-raylib` is a hand-written
  GLSL twin, and `EFX20` is the reason that is a temporary state and not the
  design.

## The CRT, re-expressed (`EFX21`–`EFX24`)

| ID    | Requirement                                                                                                                                                                                                                                                                 | Status  | Traces to                                                                                                                                                                                                                                  |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| EFX21 | The CRT must be expressible as an effect bracketed on the **root node**, not as a frame-level pass outside the pipeline.                                                                                                                                                    | partial | The mechanism is proven: a tier-1 effect (`curvature`) on a bracket, with the `EffectParam` channel a CRT needs — see `ui-gallery`'s Effects page under `--gui`. **Hue's CRT is not migrated**; what it still needs is below               |
| EFX22 | `sparkles:ui-app` must not grow a separate post-process bracket. `EFX21` is that feature; two mechanisms for one thing is what this spec exists to avoid.                                                                                                                   | full    | grep-checkable — searching `libs/ui-app/src` for `postprocess` or `postpass`, case-insensitively, finds nothing, and `EFX21`'s bracket is the mechanism that would otherwise have justified one                                            |
| EFX23 | Once `EFX21` holds, `CrtUiContext` must be **harvested from the display list** — the rects the frame actually emitted, per `Slot` — never re-derived by an application. The present hand-derivation in `hue` is the debt this retires.                                      | partial | The double relayout is gone: hue's modal paint sites record the rect they painted and the halo reads it (`gui.d` `paintedFocus`). Harvesting **per `Slot` from one display list** awaits hue's GUI emitting a single op stream — see below |
| EFX24 | The CRT's curvature and lens are tier-1; its scanlines, phosphor mask and vignette are tier-0 and must therefore survive to `ui-tui`. A terminal showing scanlines and a phosphor tint is the proof that the tier split is real and not a GPU feature wearing a tier label. | full    | Tier 0 in a terminal: `ui-gallery --render --page effects` shows scanlines, phosphor, dim and spectrum; `ui_tui.grid_canvas.tier0EffectLandsInTheTerminal`. Tier 1 in a window: the same page under `--gui`                                |

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

### What the CRT's migration still needs

`EFX21` is `partial` because the mechanism works and the migration does not
fit through it yet. Two things are missing, and neither is a surprise:

- **Multi-pass.** The CRT's bloom is three passes over two ping-pong targets
  (bright-pass extract, blur H, blur V). An effect bracket is one pass: one
  texture in, one shader, one composite. Expressing bloom needs either a
  multi-pass `EffectImpl` or a tier-2 effect that owns its own intermediates.
  This is the real work, and it is what `EFX11`'s "no more than one texture
  per nesting level" will have to be revisited against.
- **A frame clock.** Four CRT terms read `GetTime()`, and `DBG1` needs them
  pinned for a reproducible capture. `EffectParam` can carry the clock, so
  this is wiring rather than design — but it must be wired, not assumed.

`EFX23` is `partial` for a different reason. The requirement asks for the
rects **harvested from the display list, per `Slot`**, and hue's GUI does not
emit one display list: it paints through several canvases at several origins
(the tree, the document, each modal). The half that could be fixed without
that restructuring has been: the modal paint sites now record the rect they
actually painted and the halo reads it, so the second `buildView` + `layout`
per frame is gone along with the duplicated centring that first put the halo
off the picker. The remaining half is a hue refactor, not an effects one.

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
  - It does **not** foreclose `EFX20`. dcompute compiles a `@kernel` function to
    SPIR-V at build time; the registry then stores that artifact alongside the
    CPU function pointer, both derived from one source. Registration is of
    _results_, and results can be generated at compile time.
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
   (`EFX16`)~~ — **delivered**. Tier 2 (`layer`) has no built-in yet; the
   mechanism is the same texture, so it is an effect to write, not a gate.
4. **The CRT re-expressed** (`EFX21`–`EFX23`) — **partial**. The mechanism is
   proven and the double relayout is gone; what remains is stated below.

`EFX20` gates on a Vulkan `isCanvas` backend and is not part of this delivery.
