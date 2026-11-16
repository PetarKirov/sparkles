# Dplug graphics (D)

The image layer of the Dplug audio-plugin framework: a `@nogc nothrow` fork of `ae.utils.graphics` (strided `ImageRef` views, manually owned `OwnedImage` buffers with borders and alignment, `Mipmap` pyramids) feeding a tiled, multi-threaded CPU compositor that lights widgets from depth, material and diffuse maps every frame.

| Field         | Value                                                                                                                                                                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | D (DMD and LDC; SIMD through `intel-intrinsics`)                                                                                                                                                                                                     |
| License       | Per file: MPL 2.0 for the `ae` ports (`image.d`, `color.d`, `draw.d`), Boost 1.0 for Piolat's own modules (`mipmap.d`, `compositor.d`, `legacypbr.d`); the package header says "A mix of Boost 1.0, MPL 2.0, and public domain" ([`package.d`][pkg]) |
| Repository    | [AuburnSounds/Dplug][repo], sub-packages `dplug:graphics` ([`graphics/`][tree-graphics]) and `dplug:gui` ([`gui/`][tree-gui])                                                                                                                        |
| Revision read | `f4a6d71ae358798858fe3683bfcb9f21daad55ef` (July 2, 2026)                                                                                                                                                                                            |
| Documentation | In-source DDoc; [`ARCHITECTURE.md`][arch]; the [Dplug wiki][wiki]; the PBR article linked from the [README][readme-pbr]                                                                                                                              |
| Category      | D landscape: real-time CPU image pipeline                                                                                                                                                                                                            |
| Tier          | B                                                                                                                                                                                                                                                    |
| Last reviewed | November 15, 2026                                                                                                                                                                                                                                    |

> [!NOTE]
> Quotes and citations were rechecked at the pinned revision. Claims marked **verified** were independently rerun on November 15, 2026 in `/tmp/dplug-verifier-M5oK4H`, using pinned `color.d`, `dplug:core` and an extract of `image.d` (lines 25-66 and 235-642, with a minimal `box2i` stand-in). DMD 2.112.1 and LDC 1.43.0 were invoked through `nix develop /home/petar/code/repos/mine/sparkles-images -c`. LDC required the two local `intel-intrinsics` fallback substitutions described in section 7; the tested blend itself was unchanged. The allocation-overflow probe evaluates the size expression without allocating the large image. These are isolated arithmetic and layout checks, not a full plugin build or frame benchmark.

## Overview

### What it solves

An audio plugin's interface runs inside a host process (a DAW) beside a real-time audio thread. Dplug supports Windows, macOS and Linux ([README][readme-platforms]) and renders its interface in software into a window framebuffer. `dplug:graphics` supplies the pixel containers and low-level drawing; `dplug:gui` supplies the widget tree and the compositor that turns per-widget maps into lit pixels. The architecture notes describe both layers:

> In Dplug, that UI system is Physically Based Rendered through the use of two layers: the "Raw" and "PBR layer". The PBR layer is slow to update but support more complex rendering. The Raw layer is quick to update and is always on top. ([`ARCHITECTURE.md`][arch-gui])

### Design philosophy

The graphics package is openly a legacy fork in the middle of a migration:

> `dplug:graphics` defines drawing surfaces and a lot of low-level rendering routines. They are considered a legacy way to draw on screen. This is based on a fork of `ae:graphics`, a stripped-down generic library for working with images. This is being replaced slowly by `gamut` and `colors`. ([`ARCHITECTURE.md`][arch-gfx])

What survives from [`ae.utils.graphics`][ae] is the compile-time view concept; what Dplug adds is a runtime discipline. `image.d` has module-level `nothrow @nogc:` ([`image.d`][img-views] line 23); `Mipmap` and the compositor classes apply those attributes within their classes. The runtime blend functions annotate them individually ([`color.d`][col-blend]); `color.d` also contains a helper that builds a dynamic array ([`color.d`][col-helper]), so the attributes do not cover every function in every module. Image objects are created with `mallocNew` and released with `destroyFree` from `dplug.core.nogc` ([`nogc.d`][nogc]). No explicit `@safe` or `@trusted` annotations occur in `graphics/dplug/graphics` at this revision. The runtime rendering APIs aim to avoid D GC allocation and exceptions while coexisting with a host and a real-time thread.

## How it works

### Views, `ImageRef` and `OwnedImage`

The view concept is `ae`'s, unchanged in shape ([`image.d`][img-views]):

```d
/// A view is any type which provides a width, height,
/// and can be indexed to get the color at a specific
/// coordinate.
enum isView(T) =
    is(typeof(T.init.w) : size_t) && // width
    is(typeof(T.init.h) : size_t) && // height
    is(typeof(T.init[0, 0])     );   // color information
```

`isWritableView` adds assignment and `isDirectView` adds `scanline(y)` returning `COLOR[]`; the `DirectView` mixin derives `opIndex` from `scanline`. Unlike `ae`, Dplug keeps almost none of the lazy combinators: the code that runs per frame uses two concrete types.

`ImageRef!COLOR` ([`image.d`][img-ref]) is a borrowed strided view: `int w, h`, `size_t pitch` ("In bytes, not COLORs") and `COLOR* pixels`. `cropImageRef` returns another `ImageRef` "instead of a Voldemort type" ([`image.d`][img-crop]), keeping cropped views compatible with the concrete pass and widget signatures. `blitTo` itself remains generic.

`OwnedImage!COLOR` ([`image.d`][img-owned]) is a `final class` that owns a buffer and exposes the meaningful area plus a layout contract. Its constructor and `size` take four layout parameters beyond width and height:

```d
this(int w, int h, int border = 0, int rowAlignment = 1,
     int xMultiplicity = 1, int trailingSamples = 0) nothrow @nogc
```

`border` pixels surround the image on all sides and are filled by `replicateBorders` or `replicateBordersTouching(box2i)` with the nearest edge pixel ([`image.d`][img-borders]); `rowAlignment` aligns the first meaningful pixel of each row; `xMultiplicity` requests right-border padding to a sample multiple. The DDoc describes `trailingSamples` as allowing "you can read 1 + `trailingSamples` neightbours" from a meaningful position, with values "NOT guaranteed in any way" ([`image.d`][img-owned]). These parameters are intended to let SIMD kernels over-read without a scalar tail and neighbourhood filters read outside the meaningful area without an edge branch; section 1 records sizing defects. `GUIGraphics` uses them directly: the base depth level gets `border_1` and `trailingSamples_2`, and the rendered buffer gets `rowAlign_16` and `trailingSamples_3` ([`graphics.d`][gg-sizes]).

### Pixel types

Colours are `DefColor` structs generated from a channel list, ported from `ae` ([`color.d`][col-def]). Representative aliases ([`color.d`][col-alias]):

```d
alias DefColor!(ubyte  , "r", "g", "b", "a") RGBA   ;
alias DefColor!(ushort , "r", "g", "b", "a") RGBA16 ;
alias DefColor!(ubyte  , "l"               ) L8     ;
alias DefColor!(ushort , "l"               ) L16    ;
alias DefColor!(float ,  "l"               ) L32f   ;
alias DefColor!(float  , "r", "g", "b", "a") RGBAf  ;
```

Channel names carry meaning only by convention, and the PBR pipeline reuses them freely: a widget's diffuse map is `RGBA` whose fourth channel is emissive, not alpha, and its material map is `RGBA` holding roughness, metalness and specular ([`element.d`][el-pbr]). `Mipmap` is restricted by constraint to `RGBA`, `L16` and `RGBA16` ([`mipmap.d`][mip-class]).

### Mipmaps

`Mipmap!COLOR` owns a `Vec!(OwnedImage!COLOR)`; level `i+1` is `(w >> 1, h >> 1)` of level `i`, rounding odd extents down ([`mipmap.d`][mip-size]). The box filter omits an unmatched edge row or column; the cubic filter can still sample that edge. `generateNextLevel(quality, rect, level)` recomputes the affected part of the next level and returns that rectangle in the next level's coordinates, so a pyramid is updated incrementally. `Quality` is `box`, `cubic` or `boxAlphaCovIntoPremul`. Despite the enum comment's `[1 2 1]` description, the RGBA cubic downsampler implements a separable `[1 3 3 1]` kernel, normalized by 64 in two dimensions ([`mipmap.d`][mip-cubic]). The non-legacy `boxAlphaCovIntoPremul` path converts to an approximately linear, premultiplied space for bloom: its comment says "This is only approximate, does a pow2" ([`mipmap.d`][mip-premul]). `generateMipmaps` silently switches `box` to `cubic` from level 3 ("HACK: Force cubic filter past a level else it makes ugly looking mipmaps", [`mipmap.d`][mip-gen]). Sampling is `linearSample`, `linearMipmapSample` (fractional level) and `cubicSample` (Catmull-Rom), each clamped to the borders ([`mipmap.d`][mip-sample]).

### The frame pipeline and the compositor

`GUIGraphics.doDraw` is the per-frame pipeline, labelled A to H in its own comments ([`graphics.d`][gg-dodraw]): recompute draw lists; B. redraw dirty PBR widgets into the diffuse, depth and material maps; C. regenerate mipmaps for the dirty rectangles; D. composite; E. copy composited pixels to the rendered buffer; F. draw Raw widgets on top; G. reorder channels to the window's `WindowPixelFormat` (`RGBA8`, `BGRA8`, `ARGB8`) and force alpha to 255 ([`graphics.d`][gg-reorder]); H. copy into the window buffer.

Compositing goes through an interface ([`compositor.d`][comp-iface]):

```d
void compositeTile(ImageRef!RGBA wfb,
                   const(box2i)[] areas,
                   Mipmap!RGBA diffuseMap,
                   Mipmap!RGBA materialMap,
                   Mipmap!L16 depthMap,
                   IProfiler profiler);
```

`compositeGUI` first splits the disjoint dirty rectangles into tiles of at most `PBR_TILE_MAX_WIDTH` by `PBR_TILE_MAX_HEIGHT` (64 by 64) with `tileAreas` ([`graphics.d`][gg-composite], [`boxlist.d`][gg-tile]). `MultipassCompositor` runs every `CompositorPass` in order on each tile and spreads tiles over the thread pool with `parallelFor(numAreas, &compositeOneTile)` ([`compositor.d`][comp-multi]). A pass receives its tile, thread index and shared maps; restricting writes to its tile is a caller discipline, not an enforced view boundary. `resizeBuffers(width, height, areaMaxWidth, areaMaxHeight)` is the scratch-allocation hook ([`compositor.d`][comp-pass]). The default `PBRCompositor` registers eight passes, `PassComputeNormal` through `PassClampAndConvertTo8bit`, and keeps one `RGBf` normal, `RGBAf` accumulation and `L32f` variance buffer per thread, each the size of one tile ([`legacypbr.d`][pbr-buffers], [`legacypbr.d`][pbr-passes]). Normals come from the 16-bit depth map: `FACTOR_Z = 4655.0f` sets how many depth units equal one pixel of displacement, with the note "Bug: resizing should affect this factor" ([`legacypbr.d`][pbr-buffers]). `SimpleRawCompositor`, a single pass that copies diffuse RGB and forces alpha to 255, is the flat alternative ([`compositor.d`][comp-raw]).

### Codecs and resizing

`dplug:graphics` delegates decoding to `gamut`. `loadOwnedImage`, `loadOwnedImagePremul`, `loadImageSeparateAlpha` and `loadOwnedImageDepth` call `Image.loadFromMemory`, request or convert to a compatible pixel layout, and take over the resulting buffer with `disownData` ([`image.d`][img-load], [`image.d`][img-disown]). The transfer itself avoids a copy; format conversion can allocate a new image, as in the legacy RGB-to-depth path. `createViewFromImageRef` and `getImageRef` convert borrowed views in both directions without copying; the latter asserts that the pitch is nonnegative ([`image.d`][img-gamut]). The sub-package depends on `gamut` with `subConfigurations` `"audio-plugin"` ([`dub.json`][dub]); the README lists "`PNG`, `JPEG`, `QOI`, and specially designed `QOIX` codec" ([README][readme-feat]). `ImageResizer` wraps `stb_image_resize2` and, for 8-bit `RGBA`, passes `STBIR_TYPE_UINT8_SRGB` ([`resizer.d`][resizer]).

## Analysis

### 1. Pixel and memory model

The two main containers are a borrowed `ImageRef` (pointer, `size_t` byte [stride][stride], `int` extents) and an owning `OwnedImage` whose buffer extends past the logical extent in a documented way. Layout over-allocation is _part of the type's contract_: border, row alignment, x-multiplicity and trailing samples are requested by the consumer (a SIMD pass, a 3x3 filter). Correctly sized padding can let kernels avoid edge branches or scalar tails; the implementation defects below limit that guarantee. Borders are replicated incrementally for a dirty rectangle (`replicateBordersTouching`). These containers model 2-D, interleaved, one-plane images; there are no tiles in their storage, only tiles of work ([tiling][tiling]).

`OwnedImage` stores its extents and byte pitch as `int`; `ImageRef.pitch` is `size_t`. In `size`, `bytePitch` is an `int` and `allocationSize = bytePitch * actualHeightInSamples` multiplies two `int`s before widening to `size_t` ([`image.d`][img-size]). **Verified:** the same expression for a 32768 by 32768 `RGBA` image yields `0` instead of 4294967296. A second defect is in the same function: the right padding is computed from the _old_ width (`computeRightPadding(w, …)` before `this.w = width`). **Verified:** `size(3, 1, 0, 1, 4)` on a fresh `OwnedImage!RGBA` gives `borderRight` 0 and pitch 12 bytes; repeating the identical call gives `borderRight` 1 and pitch 16. The buffer-sizing calls in `GUIGraphics` use explicit or default x-multiplicity 1 ([`graphics.d`][gg-sizes]), avoiding this padding defect; that does not prevent allocation overflow at large dimensions.

### 2. Genericity mechanism

`isView`, `isWritableView` and `isDirectView` support the drawing templates in `draw.d` and `blitTo`, which picks a scanline copy when both sides are direct views ([`image.d`][img-blit]). `putPixel!(CHECKED)` chooses an explicit bounds check that discards out-of-range writes or direct indexing at compile time; direct indexing can still have D slice bounds checks ([`draw.d`][draw-put]). The pipeline interfaces are non-template and runtime-polymorphic: `ICompositor` takes concrete `ImageRef!RGBA` and `Mipmap` instantiations, `CompositorPass` takes a buffer struct, and `UIElement.onDrawPBR` takes concrete `ImageRef!RGBA` and `ImageRef!L16`. Pixel operations and mipmap kernels still use templates. Extension of the pass buffer set is by struct prefix and a cast ("First field must be `CompositorPassBuffers` for ABI compatibility", [`legacypbr.d`][pbr-buffers]). Compare the generic view route of [`ae.utils.graphics`][ae-view] and [Boost.GIL][gil].

### 3. Colour and metadata

The image containers carry no colour-space metadata. The 8-bit RGBA resizer requests sRGB treatment (`STBIR_TYPE_UINT8_SRGB`), while the non-legacy bloom conversion approximates gamma 2 (the `pow2` in `boxAlphaCovIntoPremul`). Alpha association is not encoded in the pixel type: `loadOwnedImage` requests straight alpha, `loadOwnedImagePremul` requests [premultiplied][premultiplied] alpha, `OwnedImage!RGBA.premultiply` uses `(c * a + 128) / 255` ([`image.d`][img-premultiply]), and `blendColorPremul` assumes premultiplied input, with a comment noting a "curious lack of rounding" ([`color.d`][col-premul]). Channel semantics are repurposed per map (emissive in the alpha slot), which channel names alone cannot catch. These container and loading APIs expose no ICC, CICP, HDR or EXIF metadata; this does not establish what `gamut` handles internally.

### 4. I/O and codec architecture

The loading helpers decode whole images from memory through `gamut`; their signatures do not restrict the bytes to embedded resources or loading to plugin start-up. A decode failure is `assert(false, "Decoding failed")` with the comment "FUTURE: could do something more sensible maybe", although the DDoc still advertises an `ImageIOException` ([`image.d`][img-load]). Ownership transfer from the decoder (`disownData`) avoids a pixel-buffer copy and requires allocator compatibility; the code warns that the allocation method "must be synced with the one in JPEG and PNG loading!" ([`image.d`][img-owned]).

### 5. Hostile input and safety

The graphics loading APIs accept arbitrary memory, without an enforced trusted-assets boundary. The implementation uses raw pointer arithmetic in `scanline`, assertions for size preconditions, and narrow arithmetic (section 1); it exposes no checked dimension limit. Decode failure has no recoverable error result: `assert(false)` is fatal, including in a D release build. Bounds checks occur in assertions, slice indexing and explicit helpers such as `safePut`. The `nothrow @nogc` discipline does not establish memory safety; the graphics APIs have no explicit `@safe` boundary.

### 6. Allocation and ownership

`OwnedImage` is a manually freed class (`mallocNew`/`destroyFree`); `ImageRef` owns nothing. `OwnedImage.size` calls `alignedReallocDiscard` with alignment 1, whose implementation delegates to C `realloc` on every call; retaining the address is not guaranteed, and the image API declares the contents undefined ([`vec.d`][vec-realloc]). `Mipmap.size` grows levels but asserts if asked to shrink their count ([`mipmap.d`][mip-size]). The compositor separates long-lived full-size maps (owned by `GUIGraphics`) from tile-sized per-thread scratch (owned by `PBRCompositor`, resized through `resizeBuffers`). This reduces scratch allocation during compositing, but does not prove allocation-free frames: `tileAreas` appends to a `Vec`, which can grow its allocation ([`boxlist.d`][gg-tile], [`vec.d`][vec-growth]). See [`ae.utils.graphics`][ae-allocation] for the GC-based origin.

### 7. CPU parallelism and SIMD

Parallelism is coarse and explicit: dirty rectangles become tiles of at most 64 by 64, and `parallelFor` over tiles runs all passes on one tile on one thread, reusing that thread's tile-sized scratch. The tile size is a documented latency trade-off ("having too large tiles also makes a visible delay", [`graphics.d`][gg-tiles]). Mipmapping is deliberately single-threaded; the source comment calls it "completely memory-bound" and says "it's not worth launching threads for" ([`graphics.d`][gg-mip]). This is the author's rationale, not a measurement reproduced here. Raw and PBR widgets are drawn in parallel in batches that respect overlap and draw-alone flags, one widget per task ([`graphics.d`][gg-widget-draw]).

SIMD is written with `intel-intrinsics`; Dplug advertises one codebase for x86, x86-64 and arm64 ([README][readme-feat]). The inspected blend and sampling kernels select implementations at compile time rather than through runtime CPU dispatch. Several kernels have two or three bodies: `blendColor` for `RGBA` uses `_mm_madd_epi16` and a multiply-by-32897, shift-by-23 division under `version(LDC)` and a scalar `/ ubyte.max` otherwise; `linearSample` adds an inline-assembly path under `version(AsmX86)` ([`color.d`][col-blend], [`mipmap.d`][mip-sample]). **Verified:** over all 2^24 combinations of foreground, background and alpha for one channel, both bodies of `RGBA` `blendColor` equal `floor((f*a + b*(255-a)) / 255)` (x86-64 LDC and DMD builds, zero mismatches; all four channel positions checked). The `L16` overload has no corresponding differential test in `color.d`: `ushort * ushort` promotes to `int` and can overflow. **Verified:** `blendColor(L16(65535), L16(0), 65535)` returns 65534 and `blendColor(L16(40000), L16(40000), 40000)` returns 39999 ([`color.d`][col-l16]). The box mipmap kernel keeps an AVX2 body commented out with "PERF: enable later" and runs a two-pixel SSE2 loop with a scalar tail ([`mipmap.d`][mip-box]); the premultiplying kernel stays scalar after "Hours lost trying to do that: 4" ([`mipmap.d`][mip-premul]).

While building the demonstration on x86-64, `intel-intrinsics` at its catalog revision `2141185c6` did not compile under LDC 1.43.0: `_mm_mulhi_epi16` and `_mm_mulhi_epu16` call `__builtin_ia32_pmulhw128` and `__builtin_ia32_pmulhuw128`, which that compiler does not provide ([`emmintrin.d`][ii-mulhi]; **verified**). For the LDC rerun only, those two `LDC_with_SSE2` conditions were replaced with `false` in a scratch copy, selecting their existing fallback bodies. The results do not establish that the unmodified dependency builds with this compiler.

### 8. GPU offload and interop

Not applicable by design: the whole pipeline, including lighting, runs on the CPU, and the only hand-off is a CPU framebuffer in the window's channel order. The PBR passes are what a deferred-shading GPU renderer would do (G-buffer of diffuse, material and depth; normal reconstruction; light accumulation in float; clamp to 8 bits), expressed as tile loops.

### 9. Temporal, animation and containers

The image containers describe individual 2-D images and mip levels, without frame durations or multi-frame container metadata. UI animation is separate: `UIElement.onAnimate(double dt, double time)` is called periodically for widgets with `flagAnimated`; `setDirty()` requests redraw. Its DDoc says this clock is not synchronized to audio time ([`element.d`][el-animate]). This is widget animation, not animated-image decoding.

### 10. Testing and conformance

Unit tests are local: border replication against a hand-written 7 by 6 table, `computeRightPadding` arithmetic, life after `freeImageData` and `toRef` pitch in `image.d`, colour struct tests in `color.d`, drawing-template instantiation in `draw.d`, and mipmap sizing/lifecycle checks ([`image.d`][img-tests], [`mipmap.d`][mip-tests]). The border test passes `xMultiplicity` into the `rowAlignment` parameter position and `trailing` into `xMultiplicity` (`img.size(width, height, border, xMultiplicity, trailing)`). It does not compare identical resizes on a fresh and already-sized image, leaving the stale-width defect undetected. The CI workflow builds example plugins in several formats and has no explicit `dub test` step ([`ci.yml`][ci]). The inspected graphics tests contain no blend differential oracle or rendered-frame golden comparison; the border table itself is a small pixel oracle.

## Lessons for Sparkles

- **Q1** Layout requests as allocation parameters (border, row alignment, x-multiplicity, trailing over-read) can let SIMD and neighbourhood kernels skip edge handling. They could map onto a Sparkles image type as optional layout fields with a dense default; Dplug's `int` arithmetic and stale-width bug show that the size computation needs checked `size_t` arithmetic and its own tests.
- **Q1** `cropImageRef` preserves the concrete borrowed view type used by Dplug's non-template pass interfaces. Sparkles can keep a generic view concept and still give the hot path one concrete strided type, as the [`Slice` experiment][slice-experiment] weighs for mir.
- **Q2** Dplug combines `ae`'s introspective drawing traits and templated kernels with classes and fixed types at the pipeline boundary. This is a D precedent for generic pixel operations behind runtime compositor interfaces; the source does not establish a performance reason for that boundary.
- **Q3** Dirty rectangles, tiling and per-tile pass chains with per-thread scratch are a schedule written by hand. The [Halide][halide] comparison suggests separating the tile-and-fuse choice from the algorithm; Dplug supplies a concrete eight-pass example, without establishing its maintenance cost or an automatic translation to Halide.
- **Q3**, **Q7** Two or three bodies per kernel (LDC intrinsics, inline assembly, scalar) drift silently unless an exhaustive or differential test pins them together. The `RGBA` blend agrees on all inputs; the `L16` blend, with no SIMD twin to compare against, is off by one at full scale. Sparkles' SIMD kernels need such oracles from the start.
- **Q5** Reusing channel slots for non-colour data (emissive in alpha, material in RGB) is invisible to these pixel types. Distinct semantic types for Sparkles colour and material maps could reject accidental interchange; channel names `r g b a` alone would not.
- **Q8** `nothrow @nogc` and `assert(false)` on decode failure provide neither recoverable errors nor a memory-safety guarantee, even for trusted assets. A Sparkles decoder that reads files from users needs typed errors (`Expected`) and `@safe` boundaries, which these graphics loading APIs do not supply as a model.
- **Q9** Dplug separates codec implementations (`gamut`) from the GUI pipeline (`dplug:gui`), while `dplug:graphics` contains both pixel containers and decoder adapters and depends on `gamut`. It also identifies `dplug:canvas` as the preferred drawing API. This is a D precedent for separating implementations, but not for a codec-independent core package: the ownership hand-off (`disownData`) still couples the allocators.

## Strengths

- Runtime image and compositor APIs explicitly enforce `nothrow @nogc`; this permits manual heap allocation.
- The `OwnedImage` layout parameters support padded SIMD reads and neighbourhood filters, subject to the sizing defects above.
- Incremental work everywhere: dirty rectangles drive widget redraw, partial mipmap updates and partial border replication.
- A small, swappable compositor interface with per-tile passes and per-thread scratch; a flat alternative is one class.
- SIMD portability through `intel-intrinsics` is advertised for x86 and arm64; this verification ran on x86-64 only.
- Borrowed view conversion with `gamut` without copying, plus ownership transfer of compatible pixel buffers.

## Weaknesses

- `int` sizes and unchecked multiplication in `OwnedImage.size`; the right-padding computation reads the old width (both verified).
- The `L16` blend overflows `int` and is off by one at full scale (verified).
- No colour-space metadata in these containers; the non-legacy bloom conversion approximates gamma by squaring, and alpha association is not encoded in the pixel type.
- Decode errors terminate the process; the DDoc still promises an exception.
- No explicit `@safe` graphics API boundary; local tests omit blend differential checks and rendered-frame goldens, and the cited CI workflow has no explicit unit-test invocation.
- Documented as legacy and partly superseded by `gamut`, `colors` and `dplug:canvas`, so the package is in transition.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                                 | Trade-off                                                                     |
| ----------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Concrete cropped `ImageRef`                     | Keeps crops compatible with non-template widget and compositor interfaces | View lifetimes and write regions rely on caller discipline                    |
| Consumer-requested borders and padding          | Supports neighbourhood reads and SIMD over-read                           | Size arithmetic and resize history must preserve the layout contract          |
| Ordered passes per tile with per-thread scratch | Reuses intermediates within a bounded work area                           | Scheduling and dependencies are maintained manually                           |
| `gamut` ownership hand-off                      | Avoids copying the decoded pixel buffer                                   | Graphics depends on the codec package and compatible allocation/free routines |
| `nothrow @nogc` runtime APIs                    | Avoids exceptions and D GC allocation in rendering                        | Manual allocation remains possible; decode failures are fatal                 |

## Sources

- [AuburnSounds/Dplug][repo] at `f4a6d71ae358798858fe3683bfcb9f21daad55ef`: [`graphics/dplug/graphics/`][tree-graphics] (`image.d`, `color.d`, `draw.d`, `mipmap.d`, `resizer.d`, `package.d`), [`gui/dplug/gui/`][tree-gui] (`graphics.d`, `compositor.d`, `legacypbr.d`, `element.d`, `boxlist.d`), [`core/dplug/core/nogc.d`][nogc], [`ARCHITECTURE.md`][arch], [`README.md`][readme-pbr], [`dub.json`][dub], [`.github/workflows/ci.yml`][ci].
- `intel-intrinsics` at `2141185c60cb166c79970d624b22d61fc980a96d` (local clone), for the LDC 1.43.0 build check.
- Related pages: [`ae.utils.graphics`][ae], [concepts][concepts], [existing Sparkles image code][baseline].

<!-- References -->

[repo]: https://github.com/AuburnSounds/Dplug/tree/f4a6d71ae358798858fe3683bfcb9f21daad55ef
[tree-graphics]: https://github.com/AuburnSounds/Dplug/tree/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics
[tree-gui]: https://github.com/AuburnSounds/Dplug/tree/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui
[wiki]: https://github.com/AuburnSounds/Dplug/wiki
[pkg]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/package.d#L1-L7
[arch]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/ARCHITECTURE.md
[arch-gui]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/ARCHITECTURE.md#L34-L46
[arch-gfx]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/ARCHITECTURE.md#L51-L57
[readme-pbr]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/README.md#L24
[readme-feat]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/README.md#L81-L86
[readme-platforms]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/README.md#L10-L18
[dub]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/dub.json#L163-L176
[ci]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/.github/workflows/ci.yml
[nogc]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/core/dplug/core/nogc.d#L130-L159
[img-views]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L23-L66
[img-blit]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L68-L84
[img-ref]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L123-L161
[img-crop]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L215-L233
[img-owned]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L235-L315
[img-size]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L354-L407
[img-premultiply]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L461-L483
[img-borders]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L486-L596
[img-tests]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L644-L747
[img-load]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L749-L899
[img-gamut]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L901-L949
[img-disown]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/image.d#L952-L966
[col-def]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/color.d#L140-L194
[col-helper]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/color.d#L23-L37
[col-alias]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/color.d#L306-L321
[col-blend]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/color.d#L453-L493
[col-premul]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/color.d#L495-L510
[col-l16]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/color.d#L522-L526
[draw-put]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/draw.d#L34-L66
[mip-class]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L26-L48
[mip-size]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L80-L126
[mip-sample]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L146-L496
[mip-gen]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L516-L540
[mip-box]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L676-L762
[mip-premul]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L823-L900
[mip-cubic]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L902-L1040
[mip-tests]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/mipmap.d#L648-L660
[resizer]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/graphics/dplug/graphics/resizer.d#L22-L65
[comp-iface]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/compositor.d#L25-L69
[comp-multi]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/compositor.d#L79-L155
[comp-pass]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/compositor.d#L205-L255
[comp-raw]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/compositor.d#L258-L297
[pbr-buffers]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/legacypbr.d#L39-L63
[pbr-passes]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/legacypbr.d#L157-L260
[el-pbr]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/element.d#L1311-L1326
[el-animate]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/element.d#L1382-L1405
[gg-tiles]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L55-L60
[gg-dodraw]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L776-L871
[gg-sizes]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L1115-L1137
[gg-composite]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L1337-L1349
[gg-mip]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L1354-L1372
[gg-widget-draw]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L1153-L1335
[gg-reorder]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/graphics.d#L1425-L1452
[gg-tile]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/gui/dplug/gui/boxlist.d#L138-L167
[vec-realloc]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/core/dplug/core/vec.d#L78-L217
[vec-growth]: https://github.com/AuburnSounds/Dplug/blob/f4a6d71ae358798858fe3683bfcb9f21daad55ef/core/dplug/core/vec.d#L661-L699
[ii-mulhi]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/emmintrin.d#L3048-L3118
[halide]: ./halide.md
[ae]: ./ae-graphics.md
[tiling]: ./concepts.md#tiling
[slice-experiment]: ./mir-algorithm/slice-experiment.md
[concepts]: ./concepts.md
[stride]: ./concepts.md#stride
[ae-view]: ./ae-graphics.md#the-view-concept
[premultiplied]: ./concepts.md#straight-and-premultiplied-alpha
[ae-allocation]: ./ae-graphics.md#_6-allocation-and-ownership
[baseline]: ./baseline/existing-code.md
[gil]: ./boost-gil.md
