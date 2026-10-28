---
status: draft
owner: sparkles:ui-vulkan
reviewed: 2026-10-19
---

# `sparkles:ui-vulkan` — Specification

## Abstract

`sparkles:ui-vulkan` draws Sparkles user interfaces with Vulkan, on windows
from Sparkles' own window system: the drawing half of running applications
such as the terminal without raylib on Linux, Windows and Android. It implements the toolkit's
drawing contract — filled and rounded boxes, borders, rules, scrollbars,
clipping, images and text — by recording commands into a target image its
host supplies each frame. Its GPU objects live as long as the process: when a
window loses and regains its surface, it rebuilds only the few objects tied
to the target image's format and size. Its glyph bitmaps come from Sparkles'
own font library, so a given font, size and text produce the same glyph
bitmaps on every platform.

## Introduction

A Sparkles application describes each frame as an ordered list of drawing
operations. Their geometry is in _cells_: the integer grid that the current
monospace font's cell width and height define, with whole-pixel shifts for
smooth scrolling. A [canvas](../ui/backends.md#the-canvas-seam-tgt1–tgt2)
turns the list into pixels. The canvas that ships on the desktop and on
Android is built on raylib, which also owns the window, the input and the
frame loop. An application that uses it therefore cannot use Sparkles' own
window system, [`sparkles:wsi`](../window-system-integration/SPEC.md), with
its event-driven frame pacing, native clipboards and Android lifecycle. The
terminal, the toolkit's most demanding consumer, goes further: beside the
canvas, it paints its cell grid, cursor and inline images with raylib calls
of its own.

Replacing the canvas is not a matter of translating calls. The raylib canvas
leans on facilities a Vulkan program must supply itself: memory for buffers
and images, uploads, blending, scissoring and glyph atlases. A renderer that
re-created them for every window surface, or waited for the GPU to go idle
every frame, would spend on each frame the work that event-driven pacing
exists to save. The [window system's lifetime rules](../window-system-integration/SPEC.md#_10-1-lifetimes)
require the opposite: a device and its pipelines live for the process, and
only a surface's swapchain is rebuilt when the surface comes and goes.

This library draws the operation list as instanced quads. Each operation
becomes a fixed-size record per quad it needs — one for a fill, one per glyph
of a text run, one per segment of a dashed border — written to a buffer
that belongs to one of the frames in flight and is reused only once the GPU
has finished that frame. One vertex function expands a record into a
quad, and one fragment function shades it by kind: a solid fill, a rounded
box with its border, a glyph from an atlas page, or an image. Operations are
drawn in list order. A run of records drawn with one call ends only where a
bound image — an atlas page or a picture — or the scissor changes. Device memory comes from a sub-allocator
whose bookkeeping stays in CPU memory, over a few large device allocations.
Glyph pixels come from [`sparkles:font`](../font/SPEC.md)'s
renderer-independent glyph cache, which hands this library the pixels to
upload. The shaders are written in D and compiled by
[`sparkles:shaders`](../shaders/SPEC.md).

The library draws; it does not present, and it does not decide when to draw.
Its host — the native arm of `sparkles:ui-app`, which runs the toolkit on
`sparkles:wsi` — owns the window, the swapchain, the command buffers and the
frame pacing: each frame it hands this library a target image and a command
buffer to record into, then submits and presents them. Window events, their
translation into `sparkles:input` and the swapchain belong to that host and
to [`sparkles:vulkan-wsi`](../window-system-integration/SPEC.md#_10-1-lifetimes),
whose contract the window-system specification owns. Font discovery, shaping
and rasterization belong to `sparkles:font`. Device memory sub-allocation is
owned by `sparkles:vulkan` and specified in [memory.md](../vulkan/memory.md).
Moving the terminal's own raylib painting behind an interface this canvas can
implement belongs to `sparkles:terminal-view`; the [delivery plan](./PLAN.md)
sequences that work with this library, and only together do they run the
terminal without raylib. Out of scope here are macOS, where Vulkan runs only
through a translation layer and applications keep the raylib canvas until
Skia Graphite draws with Metal; multi-pass visual effects such as bloom and
the CRT tube; and Skia Graphite itself, the general-purpose renderer the
window-system plan schedules after this library.
Open questions [UVQ1 and UVQ2](./decisions.md#open-questions) track the last
two.

Section 1 states the invariants, §2 the frame and its ownership, §3 the
drawing operations, §4 text, §5 images, §6 resources and lifetimes, and §7
failure. Delivery order lives in [PLAN.md](./PLAN.md), the oracles and
acceptance scenarios in [testing.md](./testing.md), and the reasons for each
choice in [decisions.md](./decisions.md).

## 1. The contract at a glance

1. **The canvas never presents.** It records into a command buffer and a
   target image the host supplies; acquiring, submitting and presenting are
   the host's.
2. **Recording happens at the end.** Operations are collected while the
   frame is interpreted and recorded at `endFrame`: uploads first, then one
   rendering pass.
3. **Order is the operation list's order.** A later operation is never drawn
   under an earlier one, whatever batching does.
4. **Integer geometry is exact.** A plain fill covers exactly the pixels its
   rectangle names; border, rule, line and scrollbar pixels come from shared
   geometry functions both canvases call.
5. **One device, many surfaces.** Everything except per-target objects lives
   on the process-scoped device and survives a lost and regained surface.
6. **Nothing is freed under the GPU.** A resource a frame in flight may still
   read is destroyed only after that frame's fence has signalled.
7. **Degrade visibly.** What the canvas cannot draw it counts in the frame's
   degradation report instead of approximating it.
8. **No foreign renderer.** The library imports neither raylib, SDL nor
   Skia, and nothing it exposes names them.

Three terms recur below. A box's _chrome_ is the `BoxChrome` of `sparkles:ui`:
its border, corner radius, shadow, popup arrow and explicit drawn size. A
_frame slot_ is one of the host's frames in flight, each guarded by a fence
the host signals when the GPU finishes it. The _degradation report_ is a
per-frame count, by cause, of operations drawn differently from their
specification (`UVK16`).

## 2. The frame

**UVK1: Canvas conformance.** The canvas **must** satisfy `isCanvas` and
provide the optional methods `textRunIn`, `rule`, `scrollbar`, `image`,
`pushClip`/`popClip`, `pushShift`/`popShift` and `pushEffect`/`popEffect`,
so the immediate interpreter hands it every operation.

**UVK2: Devices.** A canvas **must** be creatable on any device that has a
graphics queue and a shader profile of `sparkles:shaders` for its Vulkan
version. It **must** render with dynamic rendering where the device offers
it, through Vulkan 1.3 or `VK_KHR_dynamic_rendering`, and otherwise through a
render pass it owns per target format, with framebuffers per target view or,
where the device offers them, imageless framebuffers. Creation on any other device **must** fail with
`unsupported`.

**UVK3: Frame bracket.** `beginFrame(target, commands, slot, metrics,
ground)` **must** receive:

- the target: its image, a colour view of it, its format, extent and usage, the
  layout it is in, and the layout it must be left in;
- a command buffer in the recording state;
- the frame slot;
- the metrics: integer cell width and height, the pixel origin of cell
  `(0, 0)`, and the density, device pixels per CSS pixel;
- the ground colour the target is cleared to.

`endFrame()` **must** record the frame into the command buffer and return
the frame's degradation report. Drawing outside a bracket is a programmer
error.

**UVK4: What `endFrame` records.** In order: every upload the frame needs and
its barriers (`UVK30`); a transition of the target from its incoming layout
to the colour-attachment layout, with its source stage the colour-attachment
output stage; one rendering pass that clears to the ground colour and draws
every operation; a transition to the layout the host named. The host
**must** make its submission wait on the image's acquire semaphore at the
colour-attachment output stage and signal the slot's fence.

**UVK5: Painter's order.** For any two operations A before B in one frame,
every pixel both cover **must** show B composited over A.

_Rationale:_ Batching by bound image or kind would reorder overlapping
operations; reordering is what makes renderers disagree with the reference
canvas on popups and tooltips.

**UVK6: Blending.** A canvas **must** be created with a blend space. In the
`gamma` space, every operation **must** composite as premultiplied source
over destination, `out = src + dst·(1 − α_src)`, in the target's stored
encoding: the shaders premultiply straight colours and image texels, and
colour glyphs arrive premultiplied. Creating a canvas with any other blend
space **must** fail with `unsupported`.

_Rationale:_ The toolkit's colours are authored for, and compared against,
gamma-space blending; a host chooses the space so that linear light can be
added without changing the interface ([UVX6](./decisions.md#uvx6-a-blend-space-the-host-chooses-gamma-first)).

**UVK7: sRGB targets.** On an `sRGB` target, the canvas **must** decode its
colours to linear before output, so an opaque pixel stores the same value as
on a `UNORM` target, and **must** count the frame as `srgbBlending`: partial
coverage then blends in linear light.

**UVK8: Cell geometry.** A cell `(x, y)` **must** map to the pixel
`(origin.x + x·cellW, origin.y + y·cellH)`. Lengths the toolkit gives in CSS
pixels — radii, border widths, shadow offsets — **must** be multiplied by
the density, with the rounding the shared geometry functions (`UVK10`)
define.

## 3. Drawing operations

**UVK9: Plain fills.** A `FillRect` that has a background and whose chrome
is absent, or has only a zero radius and a solid border of zero width,
**must** composite its colour over every pixel of its rectangle and **must
not** change any other pixel.

**UVK10: Shared pixel geometry.** The pixels of borders (solid, dashed,
dotted, double), rules, lines (solid and wavy), scrollbar rails, shadows,
popup arrows and boxes with an explicit drawn size **must** come from pure
functions of `sparkles:ui` that return integer pixel rectangles, or for an
arrow its triangle's vertices, and state their rounding. Every canvas
**must** call them, and **must** change exactly the pixels they return, for
everything but rounded corners and arrow edges.

_Rationale:_ Two canvases that each decide where a dash or a thumb falls
disagree by a pixel within a release; one definition makes their outputs
comparable ([UVX7](./decisions.md#uvx7-one-pixel-geometry)).

**UVK11: Rounded boxes.** A box with a radius **must** render its fill,
border and corners from a signed distance, with coverage within the
[tolerance](./testing.md#tolerances) of the box's exact area coverage at
every pixel. Arrow edges follow the same tolerance.

**UVK12: Shadows.** A shadow **must** draw the rectangle `shadowRect` returns —
the box's, offset by the shadow's offset, widened by its blur and lengthened
downward by half of it — at the shadow's colour and alpha, with the box's
radius, and without a blur kernel.

_Rationale:_ This is the reference canvas's shadow; a real Gaussian is a
separate, visible change both canvases would make together.

**UVK13: Clipping.** Between `pushClip(r)` and its `popClip()`, no pixel
outside the intersection of `r` with every enclosing clip **may** change.
Clips nest without limit, are axis-aligned, and move with an enclosing
shift, as `PushShift` defines.

**UVK14: Shift.** `pushShift(dx, dy)` **must** move every later operation by
`dx·cellW` and `dy·cellH` pixels, each rounded half away from zero, until its
`popShift()`. Nested shifts add their rounded offsets.

**UVK15: Effects.** An effect bracket **must** draw its contents unaffected
and count once as `effect`.

**UVK16: Degradation report.** `endFrame` **must** return, per frame, a count
for each of `effect`, `missingFace`, `glyphMiss`, `unshapedCluster`,
`imageDeferred`, `imageTooLarge` and `srgbBlending`, and whether the frame
asks for another frame to complete what it skipped.

## 4. Text

**UVK17: Faces.** A text operation whose font role has no face **must** draw
in the cell font and count as `missingFace`, as the reference canvas does.

**UVK18: Glyph source.** Glyph pixels **must** come from `sparkles:font`'s
glyph cache: coverage glyphs as single-channel atlas pages, colour glyphs as
premultiplied RGBA pages. The canvas uploads the regions the cache reports
written and owns no rasterizer. Until the font library's cache exists, the canvas's
interim atlas holds them, rasterized by `sparkles:font` (decision [`UVX12`](./decisions.md)).

**UVK19: Clusters.** In a cell text run, each grapheme cluster **must**
occupy the cells its display width gives. A cluster that one glyph of the
font's character map represents **must** draw that glyph. A cluster that
needs shaping — a multi-codepoint emoji sequence, a flag, a keycap, or a
combining mark — **must** be shaped by the font library's engine, in the
first face that maps all of its visible codepoints, where the engine is
linked and the text rendering asks for it; otherwise it **must** draw the
glyph of its first codepoint and count as `unshapedCluster`. A variation
selector needs no shaping, and only picks the face. A cluster
that presents as an emoji **must** be drawn from a colour emoji face first. A
codepoint neither the cell font's faces nor its fallback faces map **must**
draw nothing and count as `noGlyph`.

**UVK20: Proportional text.** `textRunIn` **must** place glyphs by the
face's advances, aligned within its rectangle as the operation's alignment
says. `measure` **must** return cell widths, as the reference canvas does.

**UVK21: Placement.** A glyph **must** be drawn with its bitmap's origin at
the pen position plus its bearing, rounded to whole pixels, sampled one
texel per pixel through a nearest-filtering sampler. A colour glyph larger
than the cells its cluster takes **must** be drawn at the size that fits them,
centred in their height.

**UVK22: Misses.** _Status: planned._ The policy for a glyph the cache cannot
supply in time is decided with the font library's first-frame budget. Until
it is, such a glyph **must** be skipped, counted as `glyphMiss`, and the
frame **must** ask for another.

## 5. Images

**UVK23: Residency.** An image **must** be uploaded once per residency of
its `(registry, handle, generation)`: once when first drawn, and again only
after its upload was released (`UVK32`) or the device was rebuilt. An image
its registry no longer holds at that generation, removed or replaced,
**must** be released as the next frame begins, so the cache holds only
images that can still be drawn, however many a run shows.

**UVK24: Placement.** An image **must** be placed by `fitRect`, clipped to
its rectangle for `cover`, sampled through a linear-filtering sampler, and
its texels multiplied by the operation's foreground alpha.

**UVK25: Limits.** An image larger than the device's maximum 2-D image
extent **must** draw the reference canvas's placeholder and count as
`imageTooLarge`. An image whose upload would exceed the frame's upload budget
**must** draw the placeholder, count as `imageDeferred`, ask for another frame,
and upload in a later one; the frame's first upload is exempt, so an image
larger than the whole budget still arrives.

## 6. Resources and lifetimes

**UVK26: Scopes.** Pipelines, the samplers, atlas pages and cached images
**must** live on the process-scoped device and survive the loss of a surface.
Only objects tied to a target's format, extent or view **may** be rebuilt
when the target changes. A host that destroys the views it handed in **must**
tell the canvas (`releaseTargets`), which releases what it made for them under
`UVK31`.

**UVK27: Memory.** Device memory **must** come from the `sparkles:vulkan`
sub-allocator ([memory.md](../vulkan/memory.md)); the canvas makes no
`vkAllocateMemory` call of its own.

**UVK28: Frame data.** Instances and staged uploads **must** live in the
frame arena of the frame's slot (`VKM10`), reused only after that slot's
fence has signalled.

**UVK29: Upload budget.** A frame's uploads **must** fit a budget fixed at
canvas creation; `UVK25` defers what does not fit.

**UVK30: Upload ordering.** Uploads **must** be recorded before the frame's
rendering pass, followed by a barrier from the transfer write to the
fragment shader's read. An atlas page **must** be append-only while any
frame in flight samples it: written regions are never rewritten until every
slot that referenced the page has signalled.

**UVK31: Deferred destruction.** A released resource — an evicted page, a
replaced image, a cache dropped on memory pressure — **must** be destroyed
only after every slot that referenced it has signalled.

**UVK32: Releasing caches.** `releaseCaches()` **must** release every cached
image and atlas page that no frame being recorded references, under
`UVK31`, for the host to call on memory pressure.

## 7. Failure

**UVK33: Device loss.** On `VK_ERROR_DEVICE_LOST`, every operation **must**
fail with that cause and leave the canvas destroyable. A canvas built on a
new device afterwards **must** draw the same frame identically.

**UVK34: Exhaustion.** When device memory is exhausted while recording a
frame, `endFrame` **must** abandon the frame, report `outOfDeviceMemory`,
and release caches (`UVK32`); the host does not submit the abandoned frame,
and the next frame starts from the released state.

## 8. Pixel space

**UVK35: Pixel operations.** Beside the cell operations, the canvas **must**
draw a solid rectangle, a one-pixel outline, a clip, an offset, and an image
quad from a source sub-rectangle, all in device pixels and through the same
instance batcher. A pixel coordinate is not scaled by the cell size. A clip
replaces the current pixel clip and is not moved by a later offset; offsets
nest and move what is drawn after them. An image quad's texture coordinates
are that source rectangle within the image. Text is not part of this
requirement.
