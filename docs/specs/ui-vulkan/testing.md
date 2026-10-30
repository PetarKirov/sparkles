---
status: draft
owner: sparkles:ui-vulkan
reviewed: 2026-10-19
---

# `sparkles:ui-vulkan` — Testing

This page names the oracle behind every requirement, the tolerances they are
judged by, and the scenarios that must fail on a broken implementation. Text
scenarios are refined before V3 starts; everything else here gates V1 and V2.

## Oracles

| Oracle                    | Independent of the implementation because                                                                            | Checks                                             |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| A fake device             | It records the allocation calls a model test expects, with injected failures; it shares no code with a driver        | `VKM1`–`VKM13`                                     |
| Readback on lavapipe      | Mesa's software rasterizer is a separate Vulkan implementation; the test reads the target's bytes back               | every `UVK` pixel claim                            |
| Exact pixel sets          | Integer rectangles and the shared geometry functions name which pixels change; the test computes the set on the host | `UVK9`, `UVK10`, `UVK13`, `UVK14`                  |
| Supersampled coverage     | A host function integrates each pixel's exact area coverage at 16×16 samples, error at most 1/256                    | `UVK11`                                            |
| Recorded commands         | Spies wrap the real driver's commands and log what the canvas called, with its arguments, before forwarding them     | `UVK2`, `UVK4`, `UVK26`, `UVK30`, `UVK31`, `UVK34` |
| The glyph cache's bitmaps | The font library's own rasterization, before the canvas touches it                                                   | `UVK18`, `UVK21`                                   |
| The raylib canvas         | A different renderer drawing the same operation list; a differential, so it can share an upstream defect             | gallery pages, terminal screenshots                |
| Quality text renderers    | ghostty, kitty and Chromium (FreeType with light hinting) draw the same text with the same faces at the same size    | text quality, by eye: `text-lab` beside them       |

The raylib differential is never the only oracle for a requirement: it shows
that two renderers agree, not that either is right.

## Tolerances

These are fixed before V2's implementation starts and are not adjusted to
make a run pass.

- **Rounded-box coverage** (`UVK11`): at every pixel, the rendered coverage
  differs from the supersampled coverage by at most 16/255, and by at most
  2/255 on average over the box's edge pixels.
- **Against the raylib canvas**:
  - pixels set by the shared geometry functions (`UVK10`) and plain fills
    (`UVK9`) must be identical;
  - a rounded corner's pixels may differ by up to 64/255 per channel, since
    the reference draws corners as eight-segment polygons;
  - glyph pixels are not compared: the reference rasterizes with
    stb_truetype, unhinted, and blends coverage as encoded, which is the
    quality the Vulkan canvas exists to exceed (decision
    [`UVX13`](./decisions.md#uvx13-text-is-measured-against-quality-oracles)).
    This bullet once allowed 48/255 per pixel and 8/255 per cell; it was
    withdrawn by the owner, not to make a run pass but because it measured
    the wrong thing.
- **Glyphs**: every glyph pixel the atlas holds is the font library's own
  raster, exactly (canvas scenario 21); the font library's rasters are held
  to FreeType — unhinted within font `FTR3`'s tolerance, light-hinted at
  least twice as close as unhinted to FreeType's light auto-hinter, with
  the x-height and baseline rows matching in nineteen of twenty letters
  (font `FTR9`); compositing is held to its arithmetic on the host
  (`UVK36`).

## Memory scenarios

1. **Placement.** Requests of 1000, 130 and 2000 KiB in an empty pool land at
   increasing offsets, each a multiple of its alignment; freeing the second
   and requesting 150 KiB reuses its offset. (`VKM1`, `VKM4`)
2. **Type choice.** Over a fake table of four memory types, a request
   requiring host-visible and preferring device-local picks the first type
   with both; one requiring a property no type has fails and changes
   nothing. (`VKM2`)
3. **Separation.** A buffer and an optimally tiled image never share a device
   allocation. (`VKM5`)
4. **Growth.** A request larger than the free space adds exactly one device
   allocation; a request larger than the allocation size gets one of its own
   size. (`VKM6`)
5. **Driver failure.** With `vkAllocateMemory` failing, a growing request
   returns the driver's result and every pool's statistics are unchanged.
   (`VKM6`, `VKM12`)
6. **Spare.** Emptying one of two device allocations keeps it; emptying the
   other frees one of the two. Allocating and freeing one region a thousand
   times at an allocation boundary calls the driver at most once. (`VKM7`)
7. **Dedicated.** A request whose requirements prefer a dedicated
   allocation, and one aligned beyond the block size, each get their own
   device allocation, freed with the region. (`VKM8`)
8. **Mapping.** A host-visible allocation is mapped once; on a fake
   non-coherent type, `flush` covers whole atoms and every region starts on
   one. (`VKM9`)
9. **Frame arena.** Overfilling a slot adds an extra range; `reset` of that
   slot reuses its first range and frees the extra one; other slots keep
   their regions. (`VKM10`)
10. **Limit.** At `maxMemoryAllocationCount` live allocations, the next growth
    returns `VK_ERROR_TOO_MANY_OBJECTS` and the fake records no driver call.
    (`VKM11`)
11. **Shutdown.** `destroy` frees every allocation; with a region still live,
    a debug build reports it. (`VKM13`)

`VKM3` is checked by construction: the fake device's memory is unmapped
address space, so any dereference faults. Every scenario is also run against
a deliberately broken allocator — an alignment ignored, an empty allocation
never freed, a failed growth that keeps its bookkeeping — and must fail.

## Canvas scenarios

On lavapipe, reading the target back, at two cell sizes and two densities.

1. **Plain fill.** A filled rectangle on a different ground: every pixel
   inside composited, every pixel outside unchanged; again at 50% alpha.
   (`UVK9`, `UVK6`)
2. **Rounded box.** Radii 0, 3 and 12 CSS pixels, with and without a border:
   coverage within tolerance; radius 0 reduces to scenario 1. (`UVK11`,
   `UVK8`)
3. **Shared geometry.** Dashed, dotted and double borders, a wavy line, a
   rule on each edge, a scrollbar, a shadow and a box with a drawn size each
   change exactly the pixels their functions return. (`UVK10`, `UVK12`)
4. **Clip nesting.** Three nested clips under a shift, with a fill larger
   than all of them: only the shifted intersection changes. (`UVK13`)
5. **Shift.** With an odd cell width, `pushShift(0.5, 0)` moves by the
   half-away-from-zero rounding of half a cell; two nested shifts add. (`UVK14`)
6. **Painter's order.** Image A, then a fill, then image A again, all
   overlapping: the second image covers the fill and the fill covers the
   first. A batcher that groups by bound image fails this. (`UVK5`)
7. **Blending.** A translucent fill, image and colour glyph over a known
   ground match the premultiplied-over formula per channel within 1/255.
   (`UVK6`)
8. **sRGB target.** An opaque fill stores the same value on an `sRGB` and a
   `UNORM` target; the frame reports `srgbBlending`. (`UVK7`)
9. **Frame recording.** Through the spies: uploads and their
   barrier, then the transition with its source stage, one pass, the final
   transition — in that order, for both the dynamic-rendering and the
   render-pass path. (`UVK2`, `UVK3`, `UVK4`, `UVK30`)
10. **Image residency.** One handle drawn in three frames uploads once;
    bumping its generation uploads once more; after `releaseCaches` it
    uploads again. (`UVK23`, `UVK32`)
11. **Image limits.** An image over the maximum extent draws the placeholder
    and counts `imageTooLarge`; three images over the upload budget upload
    across frames, each frame counting `imageDeferred`. (`UVK25`, `UVK29`)
12. **Image placement.** Each `ImageFit` against `fitRect`; `cover` clipped;
    a half foreground alpha halves the image's contribution. (`UVK24`)
13. **Deferred destruction.** An image released while the previous slot
    still samples it is destroyed only after that slot's fence signals,
    observed through the spies. (`UVK31`)
14. **Degradation.** An effect bracket around a fill draws the fill and
    counts `effect`; a missing face draws in the cell font and counts
    `missingFace`. (`UVK15`, `UVK16`, `UVK17`)
15. **Surface loss.** Drawing, dropping the target and drawing on a new
    target of another extent rebuilds only per-target objects; the spies
    see no new pipeline, page or image. (`UVK26`)
16. **Device loss.** A frame drawn, the device destroyed and rebuilt, the
    same frame drawn again: byte-identical targets. (`UVK33`)
17. **Exhaustion.** With `vkAllocateMemory` failing mid-frame, `endFrame` reports
    `outOfDeviceMemory`, releases caches, and the next frame draws. (`UVK34`)
18. **No allocation of its own.** Over a whole gallery frame, every
    `vkAllocateMemory` the spies see comes from the sub-allocator.
    (`UVK27`, `UVK28`)
19. **Blend space.** Creating a canvas in the `gamma` space succeeds; any
    other space fails with `unsupported`. (`UVK6`)
20. **Rendering path.** Through the spies: Vulkan 1.3 renders with dynamic
    rendering; a 1.1 device with `VK_KHR_dynamic_rendering` does too, through
    the extension, on the 1.1 shader profile; a device without it renders
    through the canvas's render pass, with imageless framebuffers when offered
    and per-view framebuffers otherwise; and every path draws the same pixels.
    `sparkles:vulkan-wsi` enables the extension even for a 1.3 request on a
    1.1 device, which its device-creation plan's own test shows. (`UVK2`)
21. **Samplers.** An atlas page is bound with the nearest sampler and an
    image with the linear one; a glyph drawn at a whole-pixel position reads
    back identical to its bitmap. (`UVK21`, `UVK24`)

## Evidence ledger

| Requirement                       | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Status                                                                                                                                                                                               |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VKM1`–`VKM13`                    | memory scenarios 1–11 in `sparkles.vulkan.memory` on the fake device, each failing on a broken allocator; on lavapipe, `ui_vulkan.upload.anImageReadsBackAsUploaded` allocates, binds, maps and flushes through it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | verified; dedicated allocations and the limit on the fake device only                                                                                                                                |
| `UVK1`                            | compile-time checks in `sparkles.ui_vulkan.painter` and `sparkles.ui_vulkan.canvas` that `Painter` and `VulkanCanvas` satisfy `isCanvas` and have every optional method                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | verified                                                                                                                                                                                             |
| V1's gate: the staging path       | `ui_vulkan.upload.anImageReadsBackAsUploaded` on lavapipe with the validation layer: a whole image and a patch staged in one frame read back byte for byte; it fails with the copies recorded in reverse                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | verified                                                                                                                                                                                             |
| `UVK2`–`UVK4`, `UVK30`            | canvas scenarios 9 and 20: `ui_vulkan.canvas.framesRecordInTheOrderTheSpecificationGives`, `ui_vulkan.canvas.everyRenderingPathDrawsTheSameFrame`; `vulkan_wsi.device.dynamicRenderingFollowsTheEffectiveVersion`, `vulkan_wsi.device.imagelessFollowsTheEffectiveVersion`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | verified; on lavapipe, a Vulkan 1.3 device: the 1.1 path by request, the render-pass paths by withholding dynamic rendering and imageless framebuffers from the canvas                               |
| `UVK5`–`UVK8`                     | canvas scenarios 1, 2, 6–8 and 19: `ui_vulkan.canvas.plainFillChangesExactlyItsPixels`, `ui_vulkan.canvas.roundedBoxesWithinTolerance`, `ui_vulkan.canvas.paintersOrderSurvivesBatching`, `ui_vulkan.canvas.blendsPremultipliedOver`, `ui_vulkan.canvas.srgbTargetsStoreWhatUnormTargetsStore`, `ui_vulkan.canvas.onlyTheGammaBlendSpaceIsImplemented`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | verified; colour glyphs' blending with glyphs, in V3                                                                                                                                                 |
| `UVK9`–`UVK14`                    | canvas scenarios 1–5: `ui_vulkan.canvas.plainFillChangesExactlyItsPixels`, `ui_vulkan.canvas.roundedBoxesWithinTolerance`, `ui_vulkan.canvas.sharedGeometryChangesExactlyItsPixels`, `ui_vulkan.canvas.nestedClipsUnderAShift`, `ui_vulkan.canvas.shiftsRoundHalfAwayFromZero`; the coverage functions against the same oracle on the host, `ui_vulkan.shading.roundedBoxCoverageWithinTolerance`, `ui_vulkan.shading.arrowEdgesWithinTolerance`; the shared geometry in `sparkles.ui.pixel_geometry`, which the raylib canvas renders the gallery with byte-identical to before                                                                                                                                                                                                                                                                               | verified                                                                                                                                                                                             |
| `UVK15`–`UVK17`                   | canvas scenario 14: `ui_vulkan.canvas.degradesEffectsAndFacesVisibly`; `ui_vulkan.painter.textAndEffectsDegradeVisibly`; `ui_vulkan.painter.anInterfaceRunSitsInTheMiddleOfItsRows`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | verified; until V3 every interface run counts `missingFace`                                                                                                                                          |
| `UVK18`, `UVK19`, `UVK21`         | canvas scenario 21: `ui_vulkan.canvas.aGlyphReadsBackAsTheFontRasterizesIt` (a light-hinted glyph through the atlas reads back as `sparkles:font` rasterizes it); `ui_vulkan.canvas.anEmojiReadsBackInItsOwnColours` (a colour glyph from a fallback face, as the font library draws it; fails with the colour page unbound); `ui_vulkan.canvas.textCountsWhatItCannotDraw` (`noGlyph`; a combining mark shaped, and counted `unshapedCluster` with shaping off); `ui_vulkan.painter.aRunPlacesEachClusterInItsCells`, `ui_vulkan.painter.anEmojiClusterDrawsInColour`; `ui_vulkan.glyph_atlas.anEmojiIsPlacedInColour`, `ui_vulkan.glyph_atlas.anOutlineFaceHasNoColourForm`                                                                                                                                                                                  | verified with the interim atlas (`UVX12`) and fallback faces from `systemFallbackFacePaths`                                                                                                          |
| `UVK20`                           | `ui_vulkan.painter.anInterfaceRunSitsInTheMiddleOfItsRows` and `ui_vulkan.canvas.degradesEffectsAndFacesVisibly`: an interface run is placed and aligned, in the cell font                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | partial: runs are placed by the cell font's advances; proportional faces wait on the font library                                                                                                    |
| V3's gate                         | glyphs exact against `sparkles:font` (above); the font library against FreeType (font `FTR3`, `FTR9`); text set beside ghostty, kitty and Chromium in `text-lab` at 13.7 px, dark and light: the composited, hinted text has their crisp rows and Chromium's weight                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | met against the quality oracles (`UVX13`); the raylib canvas is no longer the glyph reference                                                                                                        |
| `UVK36`                           | `ui_vulkan.shading.glyphColour.gammaIsCoverageAsAlpha`, `.linearBlendsInLinearLight` (half coverage is half the light, both ways round), `.correctedKeepsTheEncodedWeight` (the encoded weight; contrast moves coverage from mid-grey)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | verified on the host; the shading is the same D on the device                                                                                                                                        |
| `UVK37`                           | canvas scenario 21's oracle is the hinted raster; font `FTR9`'s oracle and `hinting_test`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | verified                                                                                                                                                                                             |
| `UVK38`                           | `ui_vulkan.canvas.aLoupeRedrawsItsSourceAsBlocks` (each source pixel a 3 × 3 block, the source untouched); `ui_vulkan.canvas.textCountsWhatItCannotDraw` switches shaping off between frames                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | verified                                                                                                                                                                                             |
| `UVK39`                           | `ui_vulkan.shading.aTurnedTargetKeepsTheDisplaysLayout`, `ui_vulkan.canvas.turnedBox`; `ui_vulkan.canvas.aTurnedTargetIsDrawnPreRotated` on lavapipe                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | verified                                                                                                                                                                                             |
| V6's gate                         | the terminal's V5 scene on the native host under Xvfb (X11) and headless Weston (Wayland, GL renderer): the two frames differ by at most 1/255 per channel; against the raylib terminal, fills, decorations, block graphics, the scrollbar and kitty images agree (images once the raylib arm clamped its sampling); an idle terminal (a shell running `sleep`) presents 3 frames in its first 379 ms and none in the next 15 s (`SPARKLES_NATIVE_TRACE_FRAMES`); input: `ui-app`'s native parity check (`replayNative`) and the terminal's `unittest-vulkan` scenarios                                                                                                                                                                                                                                                                                        | met; joiner sequences and flags split across cells as libghostty reports them without grapheme-cluster width (mode 2027)                                                                             |
| `UVK22`                           | planned with the font library's first-frame budget                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | not started                                                                                                                                                                                          |
| `UVK23`–`UVK25`, `UVK29`          | canvas scenarios 10–12: `ui_vulkan.canvas.anImageUploadsOncePerResidency`, `ui_vulkan.canvas.imagesOverTheLimitsDegrade`, `ui_vulkan.canvas.imagesPlaceByFitRect`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | verified; the linear sampler's filtering itself with scenario 21, in V3                                                                                                                              |
| `UVK26`–`UVK28`, `UVK31`, `UVK32` | canvas scenarios 10, 13, 15 and 18: `ui_vulkan.canvas.anImageUploadsOncePerResidency`, `ui_vulkan.canvas.aReleasedImageOutlivesTheFramesThatReadIt`, `ui_vulkan.canvas.aNewTargetRebuildsOnlyWhatIsTheTargets`, `ui_gallery.vulkan.everyPageAllocatesOnlyThroughTheSubAllocator`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | verified; scenario 18 over a recorded frame of every gallery page but the terminal's, which V6 draws                                                                                                 |
| `UVK33`, `UVK34`                  | canvas scenarios 16 and 17: `ui_vulkan.canvas.aRebuiltDeviceDrawsTheSameFrame`, `ui_vulkan.canvas.exhaustedMemoryAbandonsTheFrame`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | verified; a lost device simulated by destroying and rebuilding it                                                                                                                                    |
| `UVK23`: eviction                 | `ui_vulkan.canvas.aRemovedImageLeavesTheDevice`: 200 images registered, drawn and removed one per frame leave one cached; it fails with the eviction disabled (201 cached)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | verified                                                                                                                                                                                             |
| `UVK35`                           | `ui_vulkan.painter.pixelFillsDoNotScaleByCells`, `ui_vulkan.painter.pixelAndCellShiftsDoNotStealEachOther` on the recorded instances; `ui_vulkan.canvas.aPixelFillIsNotScaledByTheCell`, `ui_vulkan.canvas.aPixelCircleIsARoundedBox` on lavapipe                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | verified                                                                                                                                                                                             |
| V4's gate: the native host        | `ui_app.native_loop.sameScriptSameOperationsAsTheRecorder`: one script, as window-system events through the arm's own translation and as `sparkles:input` events through the recording host, gives the same operations every frame; it fails with the pointer units swapped. The gallery's `vulkan` build under Xvfb and under headless Weston (`--renderer=gl`): one frame, then none for twelve seconds; an `xdotool` resize redraws at the new size; a scale-2 output starts at scale 2; a device loss injected at frame 100 (`SPARKLES_NATIVE_LOSE_DEVICE_AT`) rebuilds and the final capture is byte-identical                                                                                                                                                                                                                                            | verified; a density change while running needs a compositor that changes an output's scale, and the gallery's own frames are compared through a component, since its test build links the raylib arm |
| V5's gate: the terminal's seams   | `terminal_view.core.paintFrame.throughARecordingPainter` paints a headless terminal through `RecordingPainter`; the six `terminal_view.pointer.*` scenarios (drag, double and triple click, Alt block, the bar taking a press and the scrollback, SGR reports with Shift taking the mouse back, the wheel) run through the recording host on a pty the test reads, and disabling the bar's claim or the reports fails them; `terminal-view`'s `unittest` configuration builds the `core` sources with no raylib in its closure. Under Xvfb, the raylib terminal (a scene of styles, decorations, block graphics, kitty images and the scrollbar), its exit banner and the gallery's Terminal page capture byte-identical to before, as does an `xdotool`-driven mouse run; disabling the painter's image draw or the drag's selection update changes a capture | verified                                                                                                                                                                                             |
