---
status: draft
owner: sparkles:ui-vulkan
reviewed: 2026-10-19
---

# `sparkles:ui-vulkan` — Delivery plan

This plan delivers the window-system plan's milestone M7: the toolkit and the
terminal drawn with Vulkan on `sparkles:wsi`, on the Linux desktop first and
on Android last ([UVX9](./decisions.md#uvx9-this-milestone-is-the-window-system-plan-s-m7)).
Requirement identifiers refer to [SPEC.md](./SPEC.md) (`UVK`) and
[memory.md](../vulkan/memory.md) (`VKM`); oracles and scenarios live in
[testing.md](./testing.md).

## Progress

| Slice                                                             | State       |
| ----------------------------------------------------------------- | ----------- |
| [V0 Specification](#v0-specification)                             | done        |
| [V1 Device memory and resources](#v1-device-memory-and-resources) | done        |
| [V2 The canvas](#v2-the-canvas)                                   | done        |
| [V3 Glyphs](#v3-glyphs)                                           | done        |
| [V4 The native host](#v4-the-native-host)                         | done        |
| [V5 The terminal's seams](#v5-the-terminal-s-seams)               | done        |
| [V6 The terminal on Vulkan](#v6-the-terminal-on-vulkan)           | done        |
| [V7 The phone terminal](#v7-the-phone-terminal)                   | not started |

## Dependencies

V3 waited on the font library's rasterizer, which landed; its interim atlas
(`UVX12`) stands in for the font library's glyph cache. The shader
capabilities V2 and V7 needed have landed.

| Slice | Waits on                                                                                                                    |
| ----- | --------------------------------------------------------------------------------------------------------------------------- |
| V1    | nothing                                                                                                                     |
| V2    | nothing: samplers of an entry point's own ([UVQ4](./decisions.md#resolved-questions)) and the shaders plan's M6 have landed |
| V3    | `sparkles:font` MS S1–S3 in memory; the serialized parts of S4 wait on `sparkles:wired`'s flat format and BLAKE3            |
| V4    | nothing; it presents a cleared target until V2                                                                              |
| V5    | nothing; the raylib terminal keeps drawing through the new seams                                                            |
| V6    | V2–V5                                                                                                                       |
| V7    | V6; the Vulkan 1.1 shader profile has landed ([UVQ3](./decisions.md#resolved-questions))                                    |

The work ships in three pull requests: V0–V2 (rendering), V3–V4 (text and
the host), V5–V7 (the terminal and the phone).

## V0: Specification

**Deliverable.** This tree, [memory.md](../vulkan/memory.md), and the
amendments it implies elsewhere: the window-system plan's M7 and `INT3`/`INT4`,
`sparkles:ui-app`'s P4, and a consumer note in the font plan's startup slice.

**Gate.** The owner accepts the decisions marked `proposed`; a cold read of
the specification's opening restates its problem and scope; an adversarial
review's findings are dispositioned; `ci --check-docs-sidebar`,
`ci --check-spec-evidence` and the docs build pass.

## V1: Device memory and resources

**Obligations.** `VKM1`–`VKM13`.

**Deliverable.**

- `sparkles.vulkan.memory`: the sub-allocator of [memory.md](../vulkan/memory.md),
  shaped by `std.experimental.allocator`'s protocol ([UVX3](./decisions.md#uvx3-an-allocator-shaped-by-std-experimental-allocator)).
- Dispatch for the buffer, image, image-view, sampler and copy commands the
  canvas needs, beside the descriptor-set commands `sparkles:vulkan` already
  dispatches.
- `sparkles:vulkan-wsi`'s device creation enabling `VK_KHR_dynamic_rendering`
  on a device below Vulkan 1.3 that offers it, whatever version was
  requested ([UVX10](./decisions.md#uvx10-dynamic-rendering-where-offered-a-render-pass-elsewhere)).
- Buffers and images bound through the allocator, a staging path that records
  copies before a frame's rendering, and a frame arena per frame slot.

**Gate.** Model tests over a fake device (`testing.md`) for every `VKM`
requirement, including growth, release, the allocation limit and an injected
`vkAllocateMemory` failure; a lavapipe test that uploads an image through the
staging path and reads it back byte-identical.

## V2: The canvas

**Obligations.** `UVK1`–`UVK17`, `UVK23`–`UVK34`.

**Prerequisites.** V1; more than one sampler per entry point in
`sparkles:shaders` ([UVQ4](./decisions.md#resolved-questions)), landed.

**Deliverable.**

- The pixel geometry as integer functions of `sparkles:ui` (`UVK10`), and
  the raylib canvas calling them.
- `libs/ui-vulkan`: the instance batcher, the shaders in D, the canvas for
  every operation but text, offscreen rendering for tests.
- Text operations draw nothing and count as `glyphMiss` until V3.

**Gate.** Canvas scenarios 1–17, 19 and 20 of [testing.md](./testing.md#canvas-scenarios)
pass on lavapipe, each shown to fail on its deliberately broken variant.
`sparkles:ui`'s test suite passes with the moved geometry, and the raylib
canvas renders the gallery pages byte-identical to before the move.

**Outcome.** The gate is met: the 19 scenarios pass on lavapipe under the
validation layer, each failing on a broken variant, and the 18 non-terminal
gallery pages render byte-identical. The pixel geometry's move found that
the error squiggle never waved and that `UVK12` misdescribed the reference
shadow. The rendering-path scenario found that a Vulkan 1.1 device enabling
`VK_KHR_dynamic_rendering` also needs `VK_KHR_depth_stencil_resolve` and
`VK_KHR_create_renderpass2`, which `sparkles:vulkan-wsi` now enables beside
it, with imageless framebuffers wherever a device has them. Scenario 18
waits for a whole gallery frame on the native host (V4), and scenario 21 for
glyphs (V3).

## V3: Glyphs

**Obligations.** `UVK18`–`UVK21`; `UVK22` once its policy is decided.

**Prerequisites.** V2; `sparkles:font` MS S1–S3 in memory, with colour
glyphs from S3's interim FreeType rasterizer or from the font library's own
colour-glyph milestone. Shaping is not a prerequisite: until the font library
shapes, clusters that need it count as `unshapedCluster` (`UVK19`).

**Deliverable.** The canvas implements the glyph cache's upload callback:
coverage and colour atlas pages, regions uploaded before the frame's pass,
glyph instances placed by `UVK21`.

**Gate.** Canvas scenario 21; glyph scenarios against the font library's
own rasterization (the cache's bitmaps, read back after the round trip
through the atlas); text measured against the quality oracles (decision
[`UVX13`](./decisions.md#uvx13-text-is-measured-against-quality-oracles)).

**Outcome.** The gate is met with the canvas's interim atlas (decision
`UVX12`): coverage pages, and premultiplied RGBA pages for colour glyphs —
`COLR` layers and `CBDT`/`sbix` bitmaps from the font library's colour
rasterizer. Text falls back from the cell font's four faces to the faces the
raylib arm falls back to (a monospace face, a Nerd Font, a colour emoji
face), found by `systemFallbackFacePaths`, which the two arms now share. The
first gate compared glyphs with the raylib canvas; set beside ghostty, kitty
and Chromium, both were as soft as stb_truetype, and the owner moved the bar
(`UVX13`). Meeting it took three techniques, each measured: compositing in
linear light with a contrast correction (`UVK36`), which matches
Chromium's weight both ways round; light, vertical-only hinting in the font
library (font `FTR9`, `FTX17`), 6.9 coverage steps from FreeType's light
auto-hinter against 21.6 unhinted; and HarfBuzz shaping of clusters
(`UVK19`), which composes combining marks and draws joiner sequences,
flags, keycaps and skin tones as their fonts mean them. `apps/text-lab`
shows all of it, switched live, through a loupe that magnifies the
composited pixels (`UVK38`). Shaping through the engine beside the Vulkan
binding found a compiler defect: the frontend can list a `ModuleInfo` for
an ImportC module, which never has one; the font library's narrow
`cluster_shaping` interface keeps the engine out of a renderer's build.

## V4: The native host

**Obligations.** WSI `INT5`; the `gui-vulkan` part of `INT4`, whose other
configurations the window-system plan's M8 completes.

**Deliverable.** `sparkles:ui-app`'s native arm: a host over `sparkles:wsi`
and `sparkles:vulkan-wsi` satisfying `isHost`, the translation of window
events into `sparkles:input`, frames drawn on `FrameReadyEvent` and on input,
the loop parked on events between them.

**Gate.** The UI gallery runs on the native arm under Weston and Xvfb; the
same scripted input produces the same operation lists as the recording host;
an idle window draws no frame for ten seconds; an interactive resize, a
density change and a device loss each redraw correctly; canvas scenario 18
passes over a gallery frame.

**Outcome.** The gate is met but for one item: a density change while
running was not shown, since neither headless compositor changes an output's
scale; a window opened on a scale-2 output starts at that scale. The cells
are measured by `sparkles:font`'s cell rule from a face that
`sparkles:raylib-text`'s resolver finds, an interim dependency the font
library's catalog replaces, at the em whose line matches the raylib arm's,
so both arms open the same grid. The parity check drives a component rather
than the gallery, whose test build links the raylib arm; it runs the native
loop's own input and frame steps (`replayNative`). Making the arm run under
headless Weston found that its pixman renderer loses every Vulkan surface;
the GL renderer does not. The credits check now follows a package's selected
configurations, which the new `ui-app` configurations needed.

## V5: The terminal's seams

**Deliverable.** `sparkles:terminal-view` draws its cell grid, cursor,
decorations and inline images through a pixel-space painter interface it
owns, with a raylib implementation; its mouse handling — drag selection with
autoscroll, click counting, link hover, the scrollbar — runs from
`sparkles:input` pointer events instead of polling raylib.

**Gate.** The raylib terminal's screenshots are unchanged; the event-driven
mouse passes scripted selection and scrollbar scenarios through the
recording host; `terminal-view`'s tests build without raylib.

**Outcome.** The gate is met. The painter (`isTerminalPainter`) takes solid
fills, the hollow cursor's outline, a grapheme cluster across a run of
cells, the exit banner's label, a pane's clip and offset, and kitty images
as textures it creates, updates, releases and draws; the image cache keeps
deciding what is resident. The raylib painter makes exactly the calls the
renderer made before: the standalone terminal (styles, decorations, block
graphics, two scaled kitty images, the scrollbar), its exit banner and the
gallery's Terminal page capture byte-identical. The mouse runs from events
in pane pixels; where a host does not deliver them yet, a bridge reads
raylib each frame and emits the same events, and an `xdotool`-driven run
(drag selection, wheel, a bar drag) captures byte-identical too. Six
scenarios pass through the recording host on a pty the test reads.
`terminal-view`'s `unittest` configuration builds its `core` sources, with
no raylib in the closure. On the way, raylib's side buttons stopped
reporting as the wheel's buttons. A selection the user anchors at screen
cell (0, 0) is kept: only a move of both ends to (0, 0), which is how
libghostty reports a cleared scrollback, reads as cleared (`TSE4`).

## V6: The terminal on Vulkan

**Deliverable.** The painter interface on the Vulkan canvas; the terminal
application's own raylib calls replaced by host and canvas calls; a
`gui-vulkan` build of the terminal.

**Obligations.** `UVK35`; the `UVX11` decision.

**Outcome.** The canvas draws in device pixels (`UVK35`). The terminal
painter maps kitty images onto a pane-owned `ImageRegistry` (`UVX11`);
clusters and labels draw from the canvas's glyph atlas (V3), each
cluster over its cell's background, which the painter interface now
carries for compositing in linear light. A native host opens a pane with
`openPixels` at its cell metrics and paints through that painter.
`apps/terminal` has a `vulkan` configuration: the native host, pixel
positions, and no raylib poll; it still links raylib, through the cell-font
resolver ui-app borrows from `sparkles:raylib-text` until the font
library's catalog replaces it. Both arms share the chrome's pointer
routine and fills. CI builds the native gallery and terminal
(`ui-gallery-vulkan`, `terminal-vulkan`) and runs the terminal's
`unittest-vulkan` tests. Under Xvfb on lavapipe the V5 test scene draws
its text, decorations, block graphics, scrollbar and kitty images, and
under headless Weston the same frame to within 1/255. Fills, decorations,
block graphics, the scrollbar and the images agree with the raylib
terminal — the images once the raylib arm stopped sampling them with
OpenGL's repeating wrap — and the text is measured against the quality
oracles instead (`UVX13`): combining accents are shaped, the rail's icon
and emoji come from fallback faces. Joiner sequences and flags still split
across cells, as libghostty reports them without grapheme-cluster width
(mode 2027). An idle terminal presents its first frames in 379 ms and none
in the next 15 s. A file open reports that this arm has no document
viewer. The raylib desktop
configuration takes its mouse from host events too, in pixels, through the
same routine (`WorkspaceHost.notePointer`): nothing in `apps/terminal`
polls raylib's mouse, and the panes' bridge is off. Its screenshot and
mouse run are byte-identical to before.

**Gate.** The terminal runs on Wayland and X11 through the native host;
screenshots match the raylib terminal within the tolerances of
[testing.md](./testing.md#tolerances) — its text against the quality
oracles (`UVX13`); the input conformance suite passes; an idle terminal
draws no frame. Met (testing.md's evidence ledger).

## V7: The phone terminal

**Deliverable.** The terminal APK on the native Android backend, closing the
window-system plan's MA slice 4.

**Gate.** The emulator and phone lanes run the terminal; first-frame time is
recorded against the raylib APK.
