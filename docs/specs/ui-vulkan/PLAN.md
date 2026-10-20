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
| [V2 The canvas](#v2-the-canvas)                                   | not started |
| [V3 Glyphs](#v3-glyphs)                                           | not started |
| [V4 The native host](#v4-the-native-host)                         | not started |
| [V5 The terminal's seams](#v5-the-terminal-s-seams)               | not started |
| [V6 The terminal on Vulkan](#v6-the-terminal-on-vulkan)           | not started |
| [V7 The phone terminal](#v7-the-phone-terminal)                   | not started |

## Dependencies

Three slices wait on work other plans own: V2, V3 and V7. The rest can
start at once.

| Slice | Waits on                                                                                                                                            |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| V1    | nothing                                                                                                                                             |
| V2    | more than one sampler per entry point in `sparkles:shaders` ([UVQ4](./decisions.md#open-questions)); the shaders plan's M6 it also needs has landed |
| V3    | `sparkles:font` MS S1–S3 in memory; the serialized parts of S4 wait on `sparkles:wired`'s flat format and BLAKE3                                    |
| V4    | nothing; it presents a cleared target until V2                                                                                                      |
| V5    | nothing; the raylib terminal keeps drawing through the new seams                                                                                    |
| V6    | V2–V5                                                                                                                                               |
| V7    | V6; a Vulkan 1.1 shader profile ([UVQ3](./decisions.md#open-questions))                                                                             |

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
`sparkles:shaders` ([UVQ4](./decisions.md#open-questions)).

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

## V3: Glyphs

**Obligations.** `UVK18`–`UVK21`; `UVK22` once its policy is decided.

**Prerequisites.** V2; `sparkles:font` MS S1–S3 in memory, with colour
glyphs from S3's interim FreeType rasterizer or from the font library's own
colour-glyph milestone. Shaping is not a prerequisite: until the font library
shapes, clusters that need it count as `unshapedCluster` (`UVK19`).

**Deliverable.** The canvas implements the glyph cache's upload callback:
coverage and colour atlas pages, regions uploaded before the frame's pass,
glyph instances placed by `UVK21`.

**Gate.** Canvas scenario 21; glyph scenarios against the font library's own rasterization (the
cache's bitmaps, read back after the round trip through the atlas); the
gallery's text pages within the glyph tolerance of the raylib canvas.

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

## V5: The terminal's seams

**Deliverable.** `sparkles:terminal-view` draws its cell grid, cursor,
decorations and inline images through a pixel-space painter interface it
owns, with a raylib implementation; its mouse handling — drag selection with
autoscroll, click counting, link hover, the scrollbar — runs from
`sparkles:input` pointer events instead of polling raylib.

**Gate.** The raylib terminal's screenshots are unchanged; the event-driven
mouse passes scripted selection and scrollbar scenarios through the
recording host; `terminal-view`'s tests build without raylib.

## V6: The terminal on Vulkan

**Deliverable.** The painter interface on the Vulkan canvas; the terminal
application's own raylib calls replaced by host and canvas calls; a
`gui-vulkan` build of the terminal.

**Gate.** The terminal runs on Wayland and X11 through the native host;
screenshots match the raylib terminal within the tolerances of
[testing.md](./testing.md#tolerances), apart from clusters counted as
`unshapedCluster`, which are listed until the font library shapes them; the
input conformance suite passes; an idle terminal draws no frame.

## V7: The phone terminal

**Deliverable.** The terminal APK on the native Android backend, closing the
window-system plan's MA slice 4.

**Gate.** The emulator and phone lanes run the terminal; first-frame time is
recorded against the raylib APK.
