---
status: draft
owner: sparkles:ui-vulkan
reviewed: 2026-10-19
---

# `sparkles:ui-vulkan` — Decisions

Each entry records a question, the evidence, the choice and its trade-offs.
States are `proposed`, `accepted` or `superseded`.

## UVX1: A native Vulkan renderer before Skia Graphite

**State:** accepted 2026-10-19 (owner) · **Affects:** [PLAN](./PLAN.md), WSI
`INT3`, `INT4`

**Question.** The window-system plan put Skia Graphite next. The terminal is
the consumer that needs a renderer on `sparkles:wsi`, on the desktop and on
Android. Which renderer comes first?

**Evidence.**

- The Nix Skia build covers Linux and macOS only; a phone terminal through
  Graphite first needs a Skia build for Android.
- The Graphite work (`feat/ui-skia-graphite`, 17 commits) stopped two months
  and about 1,200 commits behind `main`.
- What the terminal draws is narrow: rectangles, glyphs from atlases,
  decorations and RGBA images.
- `sparkles:vulkan-wsi` already presents on every target platform.

**Choice.** A native Vulkan canvas first, built for what the toolkit and the
terminal draw. Graphite stays a later, second renderer behind the same canvas
seam.

**Trade-offs.** Rounded boxes, borders and shadows must be written here
instead of taken from Skia. Paths, gradients and general vector graphics stay
out of scope until a consumer needs them.

## UVX2: Glyphs from `sparkles:font`, not `raylib-text`

**State:** accepted 2026-10-19 (owner) · **Affects:** `UVK17`–`UVK22`

**Question.** Should the Vulkan canvas reuse `raylib-text`'s glyph pipeline,
rebased onto a renderer-neutral core, or take its glyphs from the font
library?

**Choice.** From `sparkles:font`'s startup slice ([MS](../font/PLAN.md#ms-startup-slice)):
the face catalog (S1), cell metrics without pixels (S2), and the
renderer-independent glyph cache and atlas (S3), whose upload callback this
canvas implements. `raylib-text` is left unchanged.

**Trade-offs.**

- An A/B comparison against the raylib terminal compares two rasterizers, so
  glyph pixels are compared within a tolerance, not exactly.
- The serialized catalog and precomputed atlases of S4 wait for the formats
  and hashing they need (`sparkles:wired`'s flat format and `sparkles:base`'s
  BLAKE3).

## UVX3: An allocator shaped by `std.experimental.allocator`

**State:** accepted 2026-10-19 (owner) · **Affects:** [memory.md](../vulkan/memory.md)

**Question.** Write a device-memory sub-allocator, or bind the Vulkan Memory
Allocator library?

**Choice.** A sub-allocator in `sparkles:vulkan` with the shape of
`std.experimental.allocator`'s protocol — the same operations, `Ternary`
answers and composition — handing out regions (a device allocation and an
offset) instead of pointers. It follows the design the
[allocator guide](../../guidelines/allocators/index.md#_6-showcase-sub-allocating-gpu-device-memory)
works through: a bitmap per device allocation, growth as `AllocatorList`
grows, a bump range per frame.

**Evidence.** Reusing `BitmappedBlock` itself over a reserved address range,
as the guide's example does, does not give offsets directly: the block
stores its bitmap at the start of the range it manages and starts its
payload after it, so offsets would have to be measured from a payload start
the type does not expose, and its alignment works on host addresses, not
device offsets.

**Trade-offs.** No C++ dependency to build for four platforms. VMA's breadth
(defragmentation, budgets, every memory-type quirk) is not reproduced; the
renderer's few long-lived allocations do not need it.

## UVX4: Shaders in D through `sparkles:shaders`

**State:** accepted 2026-10-19 (owner) · **Affects:** [PLAN](./PLAN.md) V2

**Question.** Write the renderer's shaders in GLSL now, or in D?

**Evidence.** A spike compiled a D fragment shader that samples an image with
`ldc2-vulkan` for `vulkan-130`; `spirv-val --target-env vulkan1.3` accepted
it. A `@uniform float` parameter failed validation
(`VUID-StandaloneSpirv-UniformConstant-04655`), and the compiler has no
vertex stage.

**Choice.** D. The canvas depends on the first Vulkan slice of the
[shaders plan](../shaders/PLAN.md)'s revision for the full-language scope:
the vertex stage, built-in variables, vertex inputs, push-constant and
uniform blocks, and Vulkan validation: its M6, delivered by pull requests
#666 and #668, with a lavapipe readback harness.

**Trade-offs.** Two further shader capabilities are requests of this
milestone: separate samplers for glyphs and images
([UVX8](#uvx8-a-sampler-per-kind-of-image)), and a profile for Vulkan 1.1
devices ([UVQ3](#resolved-questions)). Both landed, in pull requests #673 and
#675.

## UVX5: Instanced quads with vertex inputs

**State:** accepted 2026-10-20 (owner) · **Affects:** `UVK5`, `UVK28`

**Question.** How do operations reach the GPU?

**Choice.** Each operation becomes fixed-size records, one per quad, in the
frame slot's arena, read as instance-rate vertex inputs. One vertex function
expands a record into a quad; one fragment function shades it by kind. A
draw binds three images — a coverage atlas page, a colour atlas page and an
image — and a run of records drawn with one call ends where any of them, or
the scissor, changes.

**Evidence.** The shaders slice offers vertex inputs at locations, of
floating-point types only, interpolated (no `flat`), and sampled images at
numbered bindings without arrays.

**Trade-offs.** Every record field is a float: the kind and the packed
colour are carried as floats, and since all four vertices of a quad carry
the same values, interpolation leaves them exact. Storage-buffer vertex
pulling would wait for the shaders plan's storage milestone. Painter's order
costs a draw call where images alternate, which atlas pages keep rare.

## UVX6: A blend space the host chooses, gamma first

**State:** accepted 2026-10-20 (owner) · **Affects:** `UVK6`, `UVK7`

**Question.** Blend in linear light on an `sRGB` target, or in the stored
encoding on a `UNORM` one?

**Choice.** The blend space is a parameter the host passes when it creates
the canvas. One value is implemented: premultiplied source-over in the stored
(gamma) encoding of a `UNORM` target. Linear light is a later milestone's;
until then, asking for it fails with `unsupported`. An `sRGB` target is drawn
correctly for opaque pixels and reported, since a host may have no `UNORM`
format to choose.

**Trade-offs.** Gamma blending matches the reference canvas and every colour
the design system specifies, so A/B comparisons stay tight; linear light
would change antialiased edges and glyph weight. Making the space a
parameter from the start keeps adding linear light from changing the
canvas's interface.

## UVX7: One pixel geometry

**State:** accepted 2026-10-20 (owner) · **Affects:** `UVK10`

**Choice.** The pixel geometry of borders, dashes, rules, lines, scrollbar
rails, shadows, arrows and drawn sizes becomes pure functions of
`sparkles:ui` returning integer pixel rectangles, which both canvases call.
The reference canvas's public float helpers in `sparkles:ui-raylib` —
`borderEdges`, `doubleBorderEdges`, `scrollbarRail`, `scrollbarRailPx` — move
there with their rounding made explicit; the geometry it computes inline
(dashes, wavy lines, rule edges) is extracted into named functions.

## UVX8: A sampler per kind of image

**State:** accepted 2026-10-20 (owner) · **Affects:** `UVK21`, `UVK24`; [PLAN](./PLAN.md) V2

**Question.** The shaders slice reads every image through one shared sampler
(`SHR1`, `SHR7`). Glyphs want exact texels; scaled images want filtering.

**Alternatives.** One linear sampler, with glyphs placed on whole pixels so
every sample lands on a texel centre, works with the slice as it is but
makes glyph crispness depend on that placement never slipping.

**Choice.** Two samplers: nearest for atlas pages, linear for images.
`sparkles:shaders` was asked to let an entry point bind more than one sampler
([UVQ4](#resolved-questions)), and does: an entry point takes samplers of its
own (`SHR7`).

## UVX9: This milestone is the window-system plan's M7

**State:** accepted 2026-10-20 (owner) · **Affects:** WSI [PLAN](../window-system-integration/PLAN.md),
`INT3`, `INT4`; `sparkles:ui-app` P4

**Choice.** M7 of the window-system plan becomes this renderer and the
terminal on it. Graphite moves to a later milestone, MG, and `INT4` gains a
`gui-vulkan` configuration, the default GUI once the terminal runs on it.

## UVX10: Dynamic rendering where offered, a render pass elsewhere

**State:** accepted 2026-10-20 (owner) · **Affects:** `UVK2`, `UVK4`

**Question.** Require Vulkan 1.3 or dynamic rendering, or keep a render-pass
path?

**Evidence.** The reference phone (Xiaomi 2107113SG, Adreno 660, Android 14)
reports Vulkan 1.1.128 with driver 512.530 through `cmd gpu vkjson`. Of its
75 device extensions none is `VK_KHR_dynamic_rendering` or
`VK_KHR_synchronization2`; it has `VK_KHR_create_renderpass2`,
`VK_KHR_imageless_framebuffer` and `VK_KHR_separate_depth_stencil_layouts`.
The Vulkan hardware database's report of a Mi 11 on the same driver agrees.

**Choice.** Both paths. Dynamic rendering where the device has it, through
Vulkan 1.3 or `VK_KHR_dynamic_rendering`; elsewhere a render pass the canvas
owns per target format, with imageless framebuffers where offered so a new
swapchain image needs no new framebuffer. `sparkles:vulkan-wsi`'s device
creation enables `VK_KHR_dynamic_rendering` whenever the device lacks Vulkan
1.3 and has the extension, whatever version the application requested.

## UVX11: Kitty images live in the toolkit's image registry

**Status.** Accepted.

**Context.** A Vulkan terminal has to show kitty graphics. The raylib painter
keeps those textures in raylib's global table. A second GPU cache beside the
canvas would upload outside the canvas's budget and retire on a different
schedule.

**Choice.** All panes of one terminal share one `ImageRegistry`.
`TextureId.value` is the registry handle; the pane owns the RGBA bytes the
registry borrows. The canvas uploads and retires those entries with every
other image, and its cache is keyed by (registry, handle, generation):
a handle names an image only within its registry, so a terminal pane and
the embedding application may each bind their own registry to one canvas
without aliasing each other's first image. Glyphs and labels draw nothing
and count a miss until the font atlas exists. PNG images decode in
`sparkles.terminal_view.png_decoder` — no window, no raylib — installed
wherever a pane draws pixels. Adam7 interlacing is refused. The decoder
inflates into a buffer sized by the IHDR geometry, so a hostile PNG
cannot expand beyond the image it declares.

## Open questions

**UVQ1: Effects.** Multi-pass effects (bloom, the CRT tube) need offscreen targets, multi-pass
rendering and the shaders plan's Vulkan effect profile. Owner: this library,
after the terminal ships; entry condition: shaders M6 and a consumer needing
an effect on the native arm.

**UVQ2: Graphite.** When does Graphite join as a second canvas, and is the
`feat/ui-skia-graphite` work revived or redone? Owner: the window-system plan's
MG; decided after this milestone.

## Resolved questions

**UVQ3: A Vulkan 1.1 shader profile.** The shaders plan's only Vulkan
profile emitted SPIR-V 1.6 for Vulkan 1.3; the reference phone runs Vulkan
1.1, which accepts SPIR-V 1.3. _Resolved_ by `sparkles:shaders`' `vulkan1.1`
profile (pull request #675): the canvas builds both profiles and loads the one
its device's version takes.

**UVQ4: More than one sampler.** The shaders plan bound every image through
one shared sampler; the canvas needs nearest filtering for atlas pages and
linear for images ([UVX8](#uvx8-a-sampler-per-kind-of-image)). _Resolved_ by
samplers of an entry point's own (`SHR7`, pull request #673): the canvas's
fragment function takes two.
