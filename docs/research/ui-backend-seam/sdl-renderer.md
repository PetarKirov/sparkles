# SDL_Renderer — a six-function floor, and a hint for what the abstraction cannot decide

**Category:** minimal device abstraction. **Last reviewed:** August 23, 2026.
Pinned at [`b53f1b06`][rev].

The smallest honest version of "one drawing API, many devices" in this survey:
fourteen backends behind a vtable whose mandatory core is six queue functions,
one of which (`QueueGeometry`) can stand in for three of the others. It is the
floor case — read for _how little_ a seam can declare and still work, and for
what it declines to abstract at all.

| Field                 | Value                                                                                                                                          |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | C99                                                                                                                                            |
| License               | zlib ([`LICENSE.txt`][license])                                                                                                                |
| Repository            | [`libsdl-org/SDL`][rev]                                                                                                                        |
| Documentation         | [SDL3 wiki, `CategoryRender`][wiki]                                                                                                            |
| Category              | minimal device abstraction                                                                                                                     |
| Pinned revision       | `b53f1b06447cfe699e2649afc52a1a54e5f19f71` (2026-06-07)                                                                                        |
| Public seam header    | [`include/SDL3/SDL_render.h`][render_h] · backend seam [`SDL_sysrender.h`][sysrender] · framework [`SDL_render.c`][render_c]                   |
| Version at revision   | SDL 3.5.0 (development)                                                                                                                        |
| Backends shipped      | 14 drivers: `d3d11`, `d3d12`, `d3d`, `metal`, `ngage`, `opengl`, `opengles2`, `opengles`, `ps2`, `psp`, `vitagxm`, `vulkan`, `gpu`, `software` |
| Public draw calls     | 19 drawing entry points (24 `SDL_Render*` functions in all)                                                                                    |
| Mandatory driver core | 6 queue functions + `RunCommandQueue`                                                                                                          |
| Text support          | none, except an explicitly-disclaimed 8×8 debug bitmap font                                                                                    |

## Overview

### What it solves

Fill rectangles, blit textures and draw triangles onto _whatever_ the platform
provides — Direct3D 12, Metal, a PlayStation 2, or a scanline software
rasterizer when nothing else is there. The software driver
([`SDL_render_sw.c`][sw]) is a first-class member of the driver table rather
than a degraded mode, which is what makes SDL relevant here: like
`sparkles:ui`, it has a backend that genuinely cannot do what the others can.

### Design philosophy

The header states its own ceiling and points elsewhere when you exceed it —
[`SDL_render.h`][render_h]:

```c
 * This API supports the following features:
 *
 * - single pixel points   - single pixel lines   - filled rectangles
 * - texture images        - 2D polygons
 * ...
 * This API is designed to accelerate simple 2D operations. You may want more
 * functionality such as 3D polygons and particle effects, and in that case
 * you should use SDL's OpenGL/Direct3D support, the SDL3 GPU API, or one of
 * the many good 3D engines.
```

Five primitives, a named exit. There is no path object, no gradient, no stroke
width, no antialiasing control, no font — a case-insensitive search of
[`SDL_render.h`][render_h] for `linewidth`, `antialias`, `gradient` or `stroke`
returns zero hits. The abstraction's scope is a decision, published, in the
first paragraph a backend author reads.

## How it works

Drawing is **two-phase**. A public `SDL_Render*` call lowers to one or more
`SDL_RenderCommand` values appended to a per-frame linked list; the driver's
`RunCommandQueue` walks that list once at flush. The command is a **tag plus a
union** ([`SDL_sysrender.h`][sysrender]):

```c
typedef enum
{
    SDL_RENDERCMD_NO_OP,      SDL_RENDERCMD_SETVIEWPORT, SDL_RENDERCMD_SETCLIPRECT,
    SDL_RENDERCMD_SETDRAWCOLOR, SDL_RENDERCMD_CLEAR,     SDL_RENDERCMD_DRAW_POINTS,
    SDL_RENDERCMD_DRAW_LINES, SDL_RENDERCMD_FILL_RECTS,  SDL_RENDERCMD_COPY,
    SDL_RENDERCMD_COPY_EX,    SDL_RENDERCMD_GEOMETRY
} SDL_RenderCommandType;                       // reformatted here; one per line upstream

typedef struct SDL_RenderCommand
{
    SDL_RenderCommandType command;
    union
    {
        struct { size_t first; SDL_Rect rect; } viewport;
        struct { bool enabled; SDL_Rect rect; } cliprect;
        struct { size_t first; size_t count; float color_scale; SDL_FColor color;
                 SDL_BlendMode blend; SDL_Texture *texture; /* … */ } draw;
        struct { size_t first; float color_scale; SDL_FColor color; } color;
    } data;
    struct SDL_RenderCommand *next;
} SDL_RenderCommand;
```

Eleven tags, **four** union arms: the `draw` arm serves six of them. Variable
payload — the vertices — is not in the command at all. It lives in a per-frame
arena on the renderer, grown by `SDL_AllocateRenderVertices` and referenced by
the `size_t first` offset; `FlushRenderCommands` hands the driver
`(renderer->vertex_data, renderer->vertex_data_used)` alongside the command
list and then resets `vertex_data_used = 0` ([`SDL_render.c`][render_c]).

The backend seam is `struct SDL_Renderer` itself — a plain struct whose first
~30 members are function pointers, immediately followed by the renderer's own
state; there is no separate vtable type and no capability struct. Its
**mandatory core is stated as an assertion**, with a comment doing the work an
interface declaration would:

```c
static SDL_INLINE void VerifyDrawQueueFunctions(const SDL_Renderer *renderer)
{
    /* all of these functions are required to be implemented, even as no-ops, so we don't
        have to check that they aren't NULL over and over. */
    SDL_assert(renderer->QueueSetViewport != NULL);
    SDL_assert(renderer->QueueSetDrawColor != NULL);
    SDL_assert(renderer->QueueDrawPoints != NULL);
    SDL_assert(renderer->QueueDrawLines != NULL || renderer->QueueGeometry != NULL);
    SDL_assert(renderer->QueueFillRects != NULL || renderer->QueueGeometry != NULL);
    SDL_assert(renderer->QueueCopy != NULL || renderer->QueueGeometry != NULL);
    SDL_assert(renderer->RunCommandQueue != NULL);
}
```

Three of the six are `|| QueueGeometry` — **triangles are the declared
universal lowering target**, so a new backend can implement points, geometry
and a command-queue walk and get lines, rects and blits for free. "Required to
be implemented, even as no-ops" is the software driver's literal practice
(`QueueSetViewport` and `QueueSetDrawColor` are both `SW_QueueNoOp`,
[`SDL_render_sw.c`][sw]). Everything else — `GetOutputSize`,
`SupportsBlendMode`, `SetRenderTarget`, `GetMetalLayer` — is
optional-by-`NULL`, checked at each use.

## Q1 — measurement units, and who answers

**Answered by omission, and the omission is the design.** `SDL_Renderer` has
no text primitive and no measurement call. It has exactly one text-shaped
function, and [`SDL_render.h`][render_h] spends a paragraph disowning it:

```c
 * this is a convenience function for debugging, with severe limitations, and
 * not intended to be used for production apps and games.
 * ...
 * - It accepts UTF-8 strings, but will only renders ASCII characters.
 * - It has a single, tiny size (8x8 pixels). ...
 * - It uses a simple, hardcoded bitmap font. ...
 * For serious text rendering, there are several good options, such as
 * SDL_ttf, stb_truetype, or other external libraries.
```

Advance is a compile-time constant. `SDL_RenderDebugText` steps the pen with
`curx += SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE;`, where that macro is `8`
([`SDL_render.c`][render_c], [`SDL_render.h`][render_h]). Measurement, had SDL
offered it, would be `strlen(s) * 8` — structurally the same fiction as
`SkiaCanvas.measure` returning `cellsOf(text)` under
[friction §1][friction].

The difference is that SDL names it a fiction in the header, refuses to build
on it, and keeps it out of the driver seam entirely — no driver ever sees a
string. That is [F1][comparison] pushed to its limit, with a caveat
`sparkles:ui` must take seriously: SDL can refuse text because its consumer is
an application that will link SDL*ttf. A \_toolkit* cannot refuse; it must own
the seam between measurement and drawing, because that seam is where its layout
lives.

## Q2 — is the contract stated in one place?

**Partially, and in four different registers** — which is more structure than
`isCanvas` has, and less than Qt's.

1. **A mandatory floor, asserted.** `VerifyDrawQueueFunctions` above. It is not
   a type-level declaration and it only fires in a debug build, but it is
   written down in one place and names the substitution rule.
2. **A per-domain negotiable set with a refusable answer.** Blend modes are
   split into a required floor and a queried remainder
   ([`SDL_render.c`][render_c]):

   ```c
   switch (blendMode) {
   // These are required to be supported by all renderers
   case SDL_BLENDMODE_NONE: case SDL_BLENDMODE_BLEND:
   case SDL_BLENDMODE_BLEND_PREMULTIPLIED: case SDL_BLENDMODE_ADD:
   case SDL_BLENDMODE_ADD_PREMULTIPLIED: case SDL_BLENDMODE_MOD:
   case SDL_BLENDMODE_MUL:
       return true;
   default:
       return renderer->SupportsBlendMode && renderer->SupportsBlendMode(renderer, blendMode);
   }
   ```

   Seven modes are guaranteed; anything from `SDL_ComposeCustomBlendMode`
   ([`SDL_blendmode.h`][blendmode]) is negotiated, and `SDL_SetRenderDrawBlendMode`
   returns `SDL_Unsupported()` rather than silently approximating. A driver that
   leaves the hook `NULL` refuses everything above the floor — the software,
   `ps2` and `psp` drivers do exactly that, while the other eleven implement it.
   Texture formats work the same way, declared per driver via
   `SDL_AddSupportedTextureFormat` and exposed as
   `SDL_PROP_RENDERER_TEXTURE_FORMATS_POINTER`.

3. **A property bag, `SDL_GetRendererProperties`** — nominally the capability
   channel; read against the source, mostly not one. Of the thirty-odd
   `SDL_PROP_RENDERER_*` keys in [`SDL_render.h`][render_h], only
   `MAX_TEXTURE_SIZE_NUMBER`, `TEXTURE_FORMATS_POINTER`,
   `TEXTURE_WRAPPING_BOOLEAN` and the three HDR keys describe what the renderer
   _can do_. The rest are identity and escape hatches
   (`D3D12_DEVICE_POINTER`, `VULKAN_PHYSICAL_DEVICE_POINTER`,
   `GPU_DEVICE_POINTER`) — stringly typed, driver-specific, and dominantly used
   to hand the application the native device so it can leave the abstraction.

4. **A hint, for what the abstraction could not decide** — the honest one.
   Because the platforms disagree about line rasterization, SDL does not pick;
   it exposes the choice as an environment variable
   ([`SDL_hints.h`][hints]):

   ```c
    * - "0": Use the default line drawing method (Bresenham's line algorithm)
    * - "1": Use the driver point API using Bresenham's line algorithm (correct,
    *   draws many points)
    * - "2": Use the driver line API (occasionally misses line endpoints based on
    *   hardware driver quirks
    * - "3": Use the driver geometry API (correct, draws thicker diagonal lines)
   ```

   `SDL_RenderLines` then dispatches on `renderer->line_method` between
   triangle emission, `RenderLinesWithRectsF`, and the driver's native
   `QueueDrawLines` ([`SDL_render.c`][render_c]). Software renderers are pinned
   to `SDL_RENDERLINEMETHOD_LINES` "for speed" regardless of the hint.

> [!IMPORTANT]
> Point 4 is the finding. A device abstraction over genuinely disagreeing
> devices has residue that no capability enum can express — SDL's residue is
> "which of three visually different, all-defensible lines do you want?" — and
> SDL's answer is to make it a **named, documented, user-settable policy**
> rather than to hide it. `sparkles:ui` has the same residue at every
> `RuleEdge` and has no name for it.

## Q3 — semantic operations, and where degradation lives

The **public API is semantic-ish; the seam is not**, and the gap between them
is where all lowering happens. `SDL_RenderTexture9Grid` is a nine-patch — a
frame/border widget concept — and it reaches no driver: it is nine
`SDL_RenderTexture` calls in [`SDL_render.c`][render_c]. `SDL_RenderRect` (an
outline) becomes `SDL_RenderLines` over five points. `SDL_RenderTextureTiled`,
`SDL_RenderTextureRotated`, `SDL_RenderDebugText` — all framework-side.
Nineteen public drawing calls collapse into six queue functions, and a driver
can never learn that a nine-grid was intended.

This answers [F3][comparison]'s "who degrades" axis as **framework**, by
construction, and more cleanly than Qt — `QPainter` emulates only when the
engine _declines_, whereas SDL lowers unconditionally. The price inverts
[friction §3][friction]: no backend can render a nine-patch natively even where
the hardware would do it better, because the seam has no word for it.

## Q4 — command shape

**A tagged union, coarsely arm-grouped.** Eleven tags share four payload
shapes, because the arms are grouped by _payload shape_ rather than by tag:
`DRAW_POINTS`, `DRAW_LINES`, `FILL_RECTS`, `COPY`, `COPY_EX` and `GEOMETRY` all
carry `{first, count, color, blend, texture, …}` and differ only in how
`RunCommandQueue` interprets the vertex range.

That is a useful refinement of [F2][comparison], which recommends re-encoding
`DrawOp` as a sum type. SDL shows the encoding does not need one arm per kind —
`fillRect`, `textRun`, `glyph` and `line` in `sparkles:ui` share nearly all
their fields and could share an arm, leaving `scrollbar`'s eight fields as the
one arm that genuinely differs. It also shows the discipline that makes a
shared arm safe: `SDL_RENDERCMD_NO_OP` exists as a first-class tag, and a
partially-built command is **retracted by retagging** it rather than by unwinding
the queue (`cmd->command = SDL_RENDERCMD_NO_OP;` when a driver's `Queue*` hook
fails).

## Q5 — sub-unit placement, and the coarse-unit toolkit

SDL is the only surveyed subject that has our problem _and_ answers it with a
first-class API rather than by having float coordinates and moving on. It has
both. Coordinates are `float` throughout (`SDL_FRect`, `SDL_FPoint`), so
sub-pixel placement is expressible; but an application that wants a **coarse
fixed unit** declares one, once, with
`SDL_SetRenderLogicalPresentation(renderer, w, h, mode)`, choosing how it maps
to the device — `STRETCH`, `LETTERBOX`, `OVERSCAN` or `INTEGER_SCALE`
([`SDL_render.h`][render_h]). Every subsequent draw call is in logical units;
`SDL_RenderViewState` carries `logical_scale`, `logical_offset` and a
precomputed `current_scale`, applied before queueing. The mapping is invertible
and the inverse is public — `SDL_RenderCoordinatesFromWindow` and
`SDL_ConvertEventToRenderCoordinates` rewrite input events into logical space,
a service `sparkles:ui` needs and does not name.

And the escape from the coarse unit is per-frame, not per-application:

```c
 * You can disable logical coordinates by setting the mode to
 * SDL_LOGICAL_PRESENTATION_DISABLED, and in that case you get the full pixel
 * resolution of the render target; it is safe to toggle logical presentation
 * during the rendering of a frame: perhaps most of the rendering is done to
 * specific dimensions but to make fonts look sharp, the app turns off logical
 * presentation while drawing text, for example.
```

> [!IMPORTANT]
> That sentence is the closest thing in the survey to a direct answer for a
> cell-space toolkit on a pixel backend. **Draw the chrome in the coarse unit;
> turn the coarse unit off for the text.** It complicates [F5][comparison],
> which concluded that continuous coordinates dissolve friction §5: SDL has
> continuous coordinates _and_ keeps a declared coarse unit, because the coarse
> unit is what the content was authored against. The two are orthogonal, and
> `sparkles:ui` currently conflates them.

Note also what SDL never does: enumerate positions. There is no `RuleEdge`,
because a hairline is `SDL_RenderLine` at whatever float coordinates the caller
computed after asking the view for its scale.

## Q6 — resolved or semantic styling

**Fully resolved, and — the interesting part — carried as _stream state_, not
as op payload.** Colour reaches the driver as its own command,
`SDL_RENDERCMD_SETDRAWCOLOR`, and `QueueCmdSetDrawColor` emits one only when
the value actually changed, comparing against `renderer->last_queued_color`
([`SDL_render.c`][render_c]). The clip rect is deduplicated the same way
against `last_queued_cliprect`. A run of a thousand same-coloured rects queues
one colour command.

Colourspace is resolved above the seam too — `SDL_RenderingLinearSpace` decides
from the render target and `SDL_ConvertToLinear` converts before queueing, with
`color_scale` (the HDR/SDR-white-point factor) riding on the command. Nothing
semantic — no slot, no role — reaches a driver.

This is a fifth answer to Q6 and the cheapest surveyed. `DrawOp` carries
`visual` _and_ `slot` on every op ([friction §6][friction]); SDL carries
neither on most ops, because appearance is a property of _stream position_. The
trade-off is real: a state-carrying stream is not order-independent, so ops
cannot be reordered, culled individually or compared pairwise — which is
exactly what `RecordingCanvas` and the op-stream parity harness do.

## Q7 — payload ownership

Two mechanisms, neither of which is reference counting.

**Bulk payload goes in a frame arena.** Vertices are copied into
`renderer->vertex_data` via `SDL_AllocateRenderVertices`; the command retains
only `size_t first` and `size_t count`. The arena is realloc-growable, so the
header warns that "Pointers returned here are only valid until the next call"
([`SDL_sysrender.h`][sysrender]) — offsets, not pointers, are the durable
handle. `FlushRenderCommands` resets `vertex_data_used` to zero and returns the
command list to `render_commands_pool` for reuse next frame.

**Borrowed references are protected by a generation counter.** A queued
`SDL_RENDERCMD_COPY` holds a raw `SDL_Texture *`. SDL stamps
`texture->last_command_generation` when a texture is queued and, before any
operation that would mutate it, checks:

```c
static bool FlushRenderCommandsIfTextureNeeded(SDL_Texture *texture)
{
    SDL_Renderer *renderer = texture->renderer;
    if (texture->last_command_generation == renderer->render_command_generation) {
        // the current command queue depends on this texture, flush the queue now before it changes
        return FlushRenderCommands(renderer);
    }
```

The same guard exists for palettes and GPU render states — a **write-barrier
answer to the borrowed-payload hazard**: the borrow stays a borrow, and
mutating a still-referenced payload forces the frame to be submitted first.

> [!NOTE]
> This complicates [F6][comparison] ("share it, do not borrow it"). SDL borrows,
> and stays correct, by making the borrow's invalidation observable. For
> [friction §7][friction] — `DrawOp.text` as a borrowed slice — the SDL-shaped
> fix is not interning and not reference counting but **copying variable-length
> payload into a frame arena and putting an offset in the op**, which
> simultaneously makes `DrawOp` trivially copyable, sendable across a thread,
> and free of the `dip1000` `@system` assignment.

## Q8 — extent query

**The device declares it, with a three-step fallback**
([`SDL_render.c`][render_c]): `SDL_GetRenderOutputSize` calls the driver's
optional `GetOutputSize` hook; failing that asks the window
(`SDL_GetWindowSizeInPixels`); failing that returns `true` with zero, commented
"this might be an offscreen-only renderer". `SDL_GetCurrentRenderOutputSize`
answers from the current target's `SDL_RenderViewState.pixel_w/pixel_h`, so a
texture target reports its own size. Nothing derives extent from the command
stream, and nothing could — the stream is flushed and its arena reset several
times per frame. This confirms [F7][comparison] from a fourth subject and adds
the offscreen case: SDL treats "no output size" as a legitimate state.

## Strengths

- **The floor is written down and machine-checked**, in one place, naming its
  substitution rule (`|| QueueGeometry`) — and triangles are the declared
  universal lowering target, decoupling seam width from backend cost.
- **Framework-side lowering keeps the seam narrower than the API**: nineteen
  drawing calls, six queue hooks; new convenience operations cost backends
  nothing.
- **Negotiation is per-domain and refusable** — a required floor plus a queried
  remainder, refusal being a real `false` + `SDL_Unsupported()`.
- **Payload lifetime is solved without ownership transfer** — a frame arena for
  bulk data, a generation counter for borrowed handles.
- **The coarse-unit problem has a named API**, invertible for input and
  toggleable mid-frame; and the residue nobody can abstract is exposed as
  documented policy rather than hidden.

## Weaknesses

- **The capability channel is stringly typed and mostly not about
  capabilities**: not exhaustively matchable, not compile-time checkable,
  dominated by native-handle escape hatches.
- **The floor is asserts and a comment, not a type.** A release build of a
  broken driver crashes on a `NULL` call rather than failing to compile, and
  optional-by-`NULL` scales badly across ~30 ungrouped function pointers.
- **State-carrying commands are not order-independent**, so the stream cannot be
  reordered, diffed or replayed out of context.
- **Nothing semantic survives to the backend**, so a backend can never beat the
  framework's lowering — a nine-patch cannot become a native one; and clipping
  is a single mandatory rect, with no stack and no opt-out.
- **No text, by design** — coherent for a game library, unavailable to a UI
  toolkit.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                  | Trade-off                                                                               |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Six mandatory queue hooks, three satisfiable by `QueueGeometry`     | A new backend is cheap; the porting floor is one page                      | The floor is an `SDL_assert`, invisible to the type system and absent in release builds |
| Command as tag + 4-arm union, vertices in a side arena              | Fixed-size commands, pooled and reused; payload lifetime is the arena's    | The union arm does not determine validity — `RunCommandQueue` must trust the tag        |
| Semantic operations lowered in the framework (`RenderTexture9Grid`) | Backends stay six functions wide however rich the public API grows         | No backend can render a nine-patch, tiled fill or outline natively                      |
| Blend modes: a required floor plus `SupportsBlendMode`              | Callers can rely on seven modes unconditionally and negotiate the rest     | A driver that omits the hook refuses everything above the floor with no way to say why  |
| Line rasterization chosen by hint, not by capability                | The devices genuinely disagree and none of the three answers is wrong      | Rendering differs between machines by environment variable; goldens are not portable    |
| Coarse logical unit as a view transform, toggleable mid-frame       | Content authored to a fixed size scales to any output, and input maps back | Two coordinate systems live at once; the app must know which one it is in               |
| Borrowed handles guarded by a generation counter                    | No refcount traffic, no interning, and mutation-during-queue is impossible | Mutating a queued texture silently forces a flush — a latency cliff with no diagnostic  |
| No text at all                                                      | Shaping, fallback and hinting are a different library's problem            | Unavailable to a toolkit, whose layout _is_ the measurement seam                        |

## Bearing on the proposal

1. **Copy the arena-plus-offset payload encoding** for `DrawOp.text`
   ([friction §7][friction]) — the concrete alternative to interning and to
   reference counting that [F6][comparison] did not have. Copy the bytes into a
   frame-scoped arena at emit time and store `(first, length)` in the op: this
   makes `DrawOp` trivially copyable, removes the `dip1000` `@system`
   assignment, and makes the recorded stream sendable to another thread, which
   is what M7/T5 wants. `sparkles.ui.arena` already does this for chrome
   payloads.
2. **State the floor in one place, with substitution rules.**
   `VerifyDrawQueueFunctions` is what [friction §2][friction] is missing — not
   a capability enum, but one declaration saying which primitives are mandatory
   and which are satisfiable by another. `isCanvas` should name all eight
   `OpKind`s and mark `rule`, `scrollbar` and the clip pair optional _in the
   concept_, with each one's fallback. D can do this properly where C could
   only assert.
3. **Make degradation refusable per domain, not globally.**
   `IsSupportedBlendMode` confirms [F4][comparison] from a second subject and
   adds that the query belongs to the _feature domain_, not to one global
   "supported?" call: a golden test asking for a true hairline should be refused
   by the hairline domain, not by a capability bitmask.
4. **Adopt a declared coarse unit as a view transform, and let it be toggled.**
   `SDL_SetRenderLogicalPresentation` plus the mid-frame-toggle note is the
   least disruptive route out of [friction §1][friction] and §5 that keeps
   cell-space layout: the toolkit lays out in cells, the canvas owns the
   cell→device transform, and text (or a focus ring, or a two-pixel inset) opts
   out per op. This **complicates [F5][comparison]**, which read continuous
   coordinates as dissolving §5 — SDL has continuous coordinates _and_ keeps a
   coarse declared unit, because the unit encodes authorial intent rather than a
   rendering limitation.
5. **Group the sum-type arms by payload shape, not by kind.** [F2][comparison]
   recommends a `SumType` for `DrawOp`; SDL's eleven-tags-four-arms encoding
   shows the arm count can sit far below the kind count.
   `fillRect`/`textRun`/`glyph`/`line` share a shape, and `scrollbar` is the
   outlier that earns its own arm — [friction §4][friction] and §3 resolved
   together.
6. **Treat "appearance as stream state" as a fork, not a recommendation**
   ([friction §6][friction]). SDL's `SETDRAWCOLOR` dedup is the cheapest Q6
   answer surveyed and is incompatible with treating each op as an
   independently comparable value — which is what `RecordingCanvas` and the
   parity harness rely on. Decide what the harness needs first.
7. **Name the residue.** `SDL_HINT_RENDER_LINE_METHOD` says that where backends
   legitimately disagree about fidelity, the seam should expose the choice under
   a name rather than pick silently per backend. `RuleEdge`'s real content is a
   fidelity policy ("one device pixel" vs "a whole cell") — the same instinct
   [F5][comparison] reached from Notcurses. Two subjects now converge on it.
8. **Do not copy the property bag.** Untyped, non-exhaustive, mostly escape
   hatch. The real capability declarations in SDL are the asserted floor, the
   per-domain queries, and the driver's texture-format list — not
   `SDL_GetRendererProperties`.

## Sources

All citations pinned to commit `b53f1b06447cfe699e2649afc52a1a54e5f19f71` of
[`libsdl-org/SDL`][rev] (local clone; revision from `git rev-parse HEAD`, every
path verified with `git cat-file -e`). SDL version at that revision: 3.5.0
development.

- [`include/SDL3/SDL_render.h`][render_h] — the public seam: the API scope
  statement, `SDL_RendererLogicalPresentation`, `SDL_GetRendererProperties` and
  the `SDL_PROP_RENDERER_*` keys, `SDL_RenderGeometryRaw`,
  `SDL_RenderTexture9Grid`, `SDL_RenderDebugText`.
- [`src/render/SDL_sysrender.h`][sysrender] — the backend seam:
  `struct SDL_Renderer`, `SDL_RenderCommandType`, `SDL_RenderCommand`,
  `SDL_RenderViewState`, `SDL_RenderDriver`, `SDL_AllocateRenderVertices`.
- [`src/render/SDL_render.c`][render_c] — the framework: `render_drivers[]`,
  `VerifyDrawQueueFunctions`, `IsSupportedBlendMode`, `SDL_GetRenderLineMethod`,
  `SDL_RenderLines`, `SDL_RenderTexture9Grid`, `QueueCmdSetDrawColor`,
  `QueueCmdSetClipRect`, `FlushRenderCommands`,
  `FlushRenderCommandsIfTextureNeeded`, `SDL_GetRenderOutputSize`.
- [`src/render/software/SDL_render_sw.c`][sw] — the fallback backend's vtable
  wiring (`SW_QueueNoOp`); [`include/SDL3/SDL_hints.h`][hints] —
  `SDL_HINT_RENDER_LINE_METHOD`; [`include/SDL3/SDL_blendmode.h`][blendmode] —
  `SDL_ComposeCustomBlendMode`; [`src/render/vulkan/SDL_render_vulkan.c`][vk]
  and [`src/render/gpu/SDL_render_gpu.c`][gpu] — two of the eleven drivers
  implementing `SupportsBlendMode`; [`LICENSE.txt`][license] — zlib.

<!-- References -->

[wiki]: https://wiki.libsdl.org/SDL3/CategoryRender
[rev]: https://github.com/libsdl-org/SDL/tree/b53f1b06447cfe699e2649afc52a1a54e5f19f71
[render_h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_render.h
[sysrender]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/render/SDL_sysrender.h
[render_c]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/render/SDL_render.c
[sw]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/render/software/SDL_render_sw.c
[hints]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_hints.h
[blendmode]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_blendmode.h
[vk]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/render/vulkan/SDL_render_vulkan.c
[gpu]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/render/gpu/SDL_render_gpu.c
[license]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/LICENSE.txt
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
