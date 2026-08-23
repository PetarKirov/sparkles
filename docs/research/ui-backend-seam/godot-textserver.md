# Godot TextServer / RenderingServer — measurement is a server, drawing is not

**Category:** measurement as a service. **Last reviewed:** August 23, 2026.
Pinned at [`944a3c6c`][rev].

Godot ships two independent server abstractions where most toolkits ship one.
[`TextServer`][ts-h] is an abstract class with three in-tree implementations, a
manager that swaps them at runtime, a declared capability bitmask and a project
setting — and it does **no** scene drawing. [`RendererCanvasRender`][rcr-h] is
the 2-D drawing seam, and it has **no** text primitive at all. That split is the
strongest statement of [`comparison.md`][cmp]'s F1 anywhere in this survey, and
it comes with a more awkward second finding: the capability-declaration
machinery F5 asks for lives on the **measurement** seam, while the same
mechanism on the rendering seam is deprecated and hardwired to `false`.

| Field            | Value                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Language         | C++17                                                                                                                    |
| License          | MIT ([`LICENSE.txt`][license])                                                                                           |
| Repository       | [`godotengine/godot`][repo]                                                                                              |
| Documentation    | [`doc/classes/TextServer.xml`][ts-xml] (source of the published class reference)                                         |
| Version at pin   | 4.8 `dev` ([`version.py`][version])                                                                                      |
| Pinned revision  | `944a3c6cbbbb88284feebcb0603464cb175fa18e`                                                                               |
| Measurement seam | `TextServer` — `TextServerAdvanced`, `TextServerFallback`, `TextServerDummy`, `TextServerExtension`                      |
| Drawing seam     | `RendererCanvasRender` — `RendererCanvasRenderRD` (Vulkan/D3D12/Metal), `RasterizerCanvasGLES3`, `RasterizerCanvasDummy` |
| Target range     | desktop GPU, mobile GLES3, web; no cell target                                                                           |

## Overview

### What it solves

A game engine cannot make text shaping mandatory: HarfBuzz plus ICU plus
break-iterator data is multi-megabyte weight a 2-D platformer does not want and
an RTL editor cannot do without. Godot makes the _entire_ text stack — fonts,
glyph caches, shaping, line breaking, justification, caret and selection
geometry, grapheme navigation, case conversion, confusable checks — one
swappable interface, then ships two implementations of genuinely different
capability. `TextServerAdvanced` names itself
`"ICU / HarfBuzz / Graphite (Built-in)"` ([`text_server_adv.cpp`][adv-cpp]).
`TextServerFallback` is per-codepoint layout, and its shaping loop says so:

```cpp
	// "Shape" string.
	for (int i = 0; i < sd->spans.size(); i++) {
```

— [`text_server_fb.cpp`][fb-cpp], which then sets
`gl.index = (int32_t)sd->text[j - sd->start]; // Use codepoint.` and takes the
advance from `_font_get_glyph_advance` with no kerning, ligatures or reordering.
**Two implementations of one measurement interface deliberately return different
widths for the same string, and the framework is built to survive that.**

### Design philosophy

The class reference states the layering and the degradation contract in the same
breath — capability is declared, and a missing one silently ignores the argument
rather than failing:

> `[TextServer]` is the API backend for managing fonts and rendering text.
> **Note:** This is a low-level API, consider using `[TextLine]`,
> `[TextParagraph]`, and `[Font]` classes instead.
>
> **Note:** Direction is ignored if server does not support
> `[constant FEATURE_BIDI_LAYOUT]` feature (supported by `[TextServerAdvanced]`).

— [`doc/classes/TextServer.xml`][ts-xml] (two separate notes, on the class and
on `shaped_text_set_direction`)

## How it works

**Text draws itself into the canvas; the canvas never learns about text.**
`TextServerAdvanced::_font_draw_glyph` ends in one of three textured-rect calls
on the canvas-item `RID` it was handed:

`draw_msdf_rect_region`, `draw_lcd_rect_region` or `draw_rect_region`, each
passed `Rect2(cpos, csize)`, the glyph's `fgl.uv_rect` and a `modulate` colour
([`text_server_adv.cpp`][adv-cpp]). Those reach `canvas_item_add_texture_rect_region`,
`canvas_item_add_msdf_texture_rect_region` and
`canvas_item_add_lcd_texture_rect_region` ([`rendering_server.h`][rs-h]). There
is no `canvas_item_add_text`. The drawing seam's only text-awareness is two bits
of `CanvasRectFlags` — `CANVAS_RECT_MSDF = 128`, `CANVAS_RECT_LCD = 256`
([`renderer_canvas_render.h`][rcr-h]) — which select a shader, not a layout.

**The measurement seam's defining declaration** is four virtuals at the top of a
class declaring 249 of them, 216 pure:

```cpp
	virtual bool has_feature(Feature p_feature) const = 0;
	virtual String get_name() const = 0;
	virtual String get_short_name() const = 0;
	virtual int64_t get_features() const = 0;
```

— [`servers/text/text_server.h`][ts-h]

`Feature` is a 15-member bitmask in the same header, spanning layout capability
(`FEATURE_SIMPLE_LAYOUT`, `FEATURE_BIDI_LAYOUT`, `FEATURE_VERTICAL_LAYOUT`,
`FEATURE_SHAPING`, `FEATURE_KASHIDA_JUSTIFICATION`, `FEATURE_BREAK_ITERATORS`),
font capability (`FEATURE_FONT_BITMAP`, `_DYNAMIC`, `_MSDF`, `_SYSTEM`,
`_VARIABLE`) and Unicode services (`FEATURE_UNICODE_IDENTIFIERS`,
`FEATURE_UNICODE_SECURITY`, …). Each backend answers with a hand-written
`switch` whose cases are themselves `#ifdef`-gated on `MODULE_FREETYPE_ENABLED`
and `MODULE_MSDFGEN_ENABLED`, so capability varies per backend _and_ per build
([`text_server_fb.cpp`][fb-cpp], [`text_server_adv.cpp`][adv-cpp]).

**`TextServerManager` makes it a service.** It holds
`Vector<Ref<TextServer>> interfaces` and a `primary_interface`, exposes
`add_interface` / `find_interface` / `set_primary_interface`, and the engine
reaches it through one macro,
`#define TS TextServerManager::get_singleton()->get_primary_interface()`
([`text_server.h`][ts-h]). Swapping the primary interface fires
`MainLoop::NOTIFICATION_TEXT_SERVER_CHANGED` across the tree
([`text_server.cpp`][ts-cpp]) — every cached measurement has just become wrong.

**The drawing seam's defining declaration** is a per-item chain of
heterogeneous commands and one entry point that consumes the whole list:

```cpp
		struct Command {
			enum Type {
				TYPE_RECT, TYPE_NINEPATCH, TYPE_POLYGON, TYPE_PRIMITIVE,
				TYPE_MESH, TYPE_MULTIMESH, TYPE_PARTICLES,
				TYPE_TRANSFORM, TYPE_CLIP_IGNORE, TYPE_ANIMATION_SLICE,
			};
			Command *next = nullptr;
			Type type;
			virtual ~Command() {}
		};

	virtual void canvas_render_items(RID p_to_render_target, Item *p_item_list, ...) = 0;
```

— [`renderer_canvas_render.h`][rcr-h]

## Q1 — measurement units, and who answers

Measurement is a **peer server**, not a method on the painter — the same
conclusion as Slint, Qt, Notcurses and egui, reached with more machinery than
any of them. The unit is `double` / `Vector2` in canvas-space pixels throughout:
`shaped_text_get_size`, `shaped_text_get_width`, `shaped_text_get_ascent`,
`font_get_glyph_advance`, and per-glyph `float advance` on the flat `Glyph` POD
([`text_server.h`][ts-h]).

The unit is fixed; _the answer is explicitly backend-dependent_, and that is the
part our seam has no room for. `SkiaCanvas.measure` must return `cellsOf(text)`
because layout already committed to a grid ([friction §1][friction]); Godot's
layout never commits, so `Advanced` and `Fallback` may disagree and nothing
breaks — the framework re-measures on `NOTIFICATION_TEXT_SERVER_CHANGED`.

The service is also far wider than "how wide is this string": line breaking
(`shaped_text_get_line_breaks`), justification (`shaped_text_fit_to_width`),
overrun and ellipsis (`shaped_text_overrun_trim_to_width`), caret and selection
geometry (`shaped_text_get_carets` → `CaretInfo`), hit testing
(`shaped_text_hit_test_position`) and grapheme navigation
(`shaped_text_next_grapheme_pos`) — every one a question a text widget must ask
and a painter cannot answer.

## Q2 — is the contract stated in one place?

**Yes on the measurement seam, and the statement is machine-readable** — F1 and
F5 in one API. It is used three ways:

1. **Backend selection**, by population count of the feature bitmask:

   ```cpp
   /* Use one with the most features available. */
   int max_features = 0;
   for (int i = 0; i < TextServerManager::get_singleton()->get_interface_count(); i++) {
   	uint32_t features = TextServerManager::get_singleton()->get_interface(i)->get_features();
   	int feature_number = 0;
   	while (features) { feature_number += features & 1; features >>= 1; }
   	if (feature_number >= max_features) { max_features = feature_number; text_driver_idx = i; }
   }
   ```

   — [`main/main.cpp`][main-cpp], overridable by the
   `internationalization/rendering/text_driver` project setting in the same file.

2. **Conditional data loading**, immediately after:
   `if (ts->has_feature(TextServer::FEATURE_USE_SUPPORT_DATA)) { ts->load_support_data(...); }`.

3. **Product-level degradation.** `_get_skipped_locales()` — commented
   _"Skip locales if Text server lack required features."_ — removes `ar`, `fa`
   and `ur` when either `FEATURE_BIDI_LAYOUT` or `FEATURE_SHAPING` is missing,
   `he` on missing bidi, and `bn`/`hi`/`ml`/`si`/`ta`/`te` on missing shaping, so
   the editor never offers a language it would render wrongly
   ([`editor_settings.cpp`][ed-settings]).

**No on the drawing seam.** `RenderingServer` also declares
`virtual bool has_feature(RSE::Features p_feature) const = 0`
([`rendering_server.h`][rs-h]), but the enum behind it is dead:

```cpp
#ifndef DISABLE_DEPRECATED
// Never actually used, should be removed when we can break compatibility.
enum Features {
	FEATURE_SHADERS,
	FEATURE_MULTITHREADED,
};
#endif
```

— [`rendering_server_enums.h`][rs-enums]

and its only implementation is
`bool RenderingServerDefault::has_feature(RSE::Features p_feature) const { return false; }`
([`rendering_server_default.cpp`][rsd-cpp]). The drawing seam is **total**
instead: every backend handles all ten command types — `RendererCanvasRenderRD`
and `RasterizerCanvasGLES3` both switch exhaustively over
`Item::Command::TYPE_*`, and `RasterizerCanvasDummy` conforms with empty
bodies and default returns ([`rasterizer_canvas_dummy.h`][dummy-h]). A backend either
draws a command or draws nothing; it never says which.

> [!IMPORTANT]
> One engine, two seams, opposite answers — and the **measurement** seam is the
> one that kept the capability query. That is an in-tree falsification of the
> intuition that declared capabilities are a renderer concern.

## Q3 — semantic operations or primitives?

**Primitives, aggressively, with degradation done once in the framework.**
`RenderingServer`'s public API is much richer than the ten command types
(`canvas_item_add_line`, `add_polyline`, `add_multiline`, `add_rect`,
`add_ellipse`, `add_circle`, `add_nine_patch`, `add_triangle_array`, …
[`rendering_server.h`][rs-h]); `RendererCanvasCull` lowers it. A line becomes a
quad, antialiasing included, before any backend sees it:

`canvas_item_add_line` allocates an `Item::CommandPrimitive`, offsets the two
endpoints by `dir * p_width * 0.5` into a four-point quad, and — when
`p_antialiased` — appends further feathered primitives sized by a `FEATHER_SIZE`
constant, after widening via `canvas_item_get_compensated_antialiasing_width`
([`renderer_canvas_cull.cpp`][rcc-cpp]). No backend ever sees "a line".

Widget chrome goes further: `StyleBoxFlat` — rounded corners, per-side border
widths, drop shadow, antialiasing, i.e. what a focus ring or a panel background
actually _is_ — is tessellated in the `scene/` layer and submitted as one
`canvas_item_add_triangle_array` ([`style_box_flat.cpp`][sbf-cpp]).

The one command that keeps semantics is `CommandNinePatch`, carrying
`float margin[4]`, `draw_center` and `RSE::NinePatchAxisMode axis_x/axis_y` — a
_stretch policy_ the backend interprets. It survives because resolving it needs
the texture's runtime size, which lives on the backend's side of the seam.

That puts Godot on F4's framework rung — the lowering lives one level above the
backend, in Qt's camp and opposite Slint. Note the split follows the same line as
everything else: **drawing degrades in the framework; text degrades in the
caller** (`editor_settings.cpp` above), because only the caller knows whether
Arabic is worth offering at all.

## Q4 — command shape

Godot reifies the command stream and encodes it as **neither** a
tag-plus-dead-fields struct **nor** a sum type. `Item::Command` is a virtual base
carrying `Type type` and `Command *next`; each kind is a subclass carrying only
its own fields (`CommandRect` has
`Rect2 rect; Color modulate; Rect2 source; uint16_t flags; float outline; float px_range; RID texture;`;
`CommandTransform` has one `Transform2D`; `CommandClipIgnore` has one `bool`).
Storage is a bump allocator of 4 KiB blocks owned by the item:

```cpp
		struct CommandBlock { enum { MAX_SIZE = 4096 }; uint32_t usage; uint8_t *memory = nullptr; };

		template <typename T>
		T *alloc_command() {
			...
			void *memory = c->memory + c->usage;
			command = memnew_placement(memory, T);
			last_command->next = command;
			last_command = command;
			c->usage += sizeof(T);
			...
			rect_dirty = true;
			return command;
		}
```

— [`renderer_canvas_render.h`][rcr-h], whose comment gives the rationale:
_"commands are allocated in blocks of 4k to improve performance and cache
coherence. blocks always grow but never shrink."_ The first command of an item
is heap-allocated alone, "As the most common use case of canvas items is to use
only one command".

So a command is **variable-size and pays only for its own fields** — the axis
[friction §4][friction] names — without a discriminated union, at the cost of a
vtable pointer plus a redundant `type` tag. Consumers switch on the tag and
`static_cast`; the only virtual is the destructor.

F3 poses the encoding as a live trade between a closed sum and variable-stride
per-op records, and Godot sits between the poles rather than at either: the
stride varies as Flutter's and Chromium's do, but the discrimination is a
hand-maintained tag beside a vtable rather than a checked union, so no consumer
`switch` is exhaustiveness-checked. `sparkles:ui` takes the closed-sum pole —
`DrawOp` wraps a `SumType` over eight payloads, dispatches through `match!`, and
keeps every operation inside `static assert(DrawOp.sizeof <= 64)`, whose widest
arm is `TextRun`. Godot's arena is what the other pole costs to build by hand.

## Q5 — sub-unit placement

Coordinates are continuous `Vector2` / `Rect2` floats, so nothing in the drawing
seam ever spells a position as a compass direction — confirmation that
[`RuleEdge`][canvas] is a symptom of integer cell coordinates. What Godot does
not do is escape the sub-unit question: it relocates it, exactly as F6 says
continuous coordinates do, onto a named quantization ladder one seam over.

That ladder is **declared, and it lives on the measurement seam, not the drawing
one**:

```cpp
	enum SubpixelPositioning {
		SUBPIXEL_POSITIONING_DISABLED = 0,
		SUBPIXEL_POSITIONING_AUTO = 1,
		SUBPIXEL_POSITIONING_ONE_HALF = 2,
		SUBPIXEL_POSITIONING_ONE_QUARTER = 3,

		SUBPIXEL_POSITIONING_ONE_HALF_MAX_SIZE = 20,
		SUBPIXEL_POSITIONING_ONE_QUARTER_MAX_SIZE = 16,
	};
```

— [`text_server.h`][ts-h]

`AUTO` resolves against those size thresholds; the chosen shift is packed into
the glyph-cache key (`index = index | (xshift << 27)`) so quantized variants
cache separately, with `FontLCDSubpixelLayout` in bits 24–26 of the same key
([`text_server_adv.cpp`][adv-cpp]). The drawing seam's only equivalent is the
`bool p_snap_2d_vertices_to_pixel` parameter of `canvas_render_items`.

This is Notcurses' "name a fidelity, not a position" applied to text placement,
expressed as _font policy_ — F6's prescription, a named fidelity paired with a
queried device unit, in a shipping engine. It is also where a `sparkles:ui`
hairline fidelity would most plausibly want to live, given the toolkit's cell
grid: `RuleEdge` names six positions on that grid, and the thing a backend
actually needs told is how much of a cell a hairline may occupy.

## Q6 — resolved appearance, semantic role, or both?

**Resolved only.** Commands carry `Color modulate` / `Color color` and nothing
semantic; the item accumulates `Color final_modulate` and
`Transform2D final_transform` during culling ([`renderer_canvas_render.h`][rcr-h]).
`Theme`, `StyleBox` and theme type variations resolve entirely in `scene/` and
reach the server as triangles ([`style_box_flat.cpp`][sbf-cpp]). `Item::material`
is the escape hatch: a resolved handle to a shader, not a role name.

Godot pays for one because it has no re-resolving backend — no HTML target. That
is the whole distance between its encoding and ours. `sparkles:ui` has such a
target, so the role cannot be spent above the seam the way `StyleBox` is: a
`Slot` rides across the seam on six of the eight payloads, in company with
whatever appearance that primitive was resolved to, and only `PushClip`/`PopClip`
— which no interpreter re-resolves — travel without one, `DrawOp.slot` answering
`Slot.inherit` in their place. The resolved half is split the other way: each payload
keeps the `Ink` or colour fields its own primitive reads, and `DrawOp.visual`
reconstructs a `Visual` through `visualOf`, documented lossy on purpose because
a payload keeps only what it paints from.

F9 is the count behind [friction §6][friction]: no surveyed subject carries a
resolved appearance and a semantic role on the same operation. Deriving one half
rather than storing it makes the hedge cheap — nothing on the operation pays for
`Visual` — but "the seam hedges rather than deciding" stands, because the role is
stored and the derivation is what lets both consumers be served at once. Godot
offers no way to carry both cheaply; it shows what it costs _not_ to need both.

## Q7 — payload ownership

**Nothing is borrowed, and the reason is structural: the seam is a thread
boundary.** `RenderingServerDefault` holds a `mutable CommandQueueMT command_queue`
and an optional dedicated `server_thread` with `_thread_loop`
([`rendering_server_default.h`][rsd-h]), so every `canvas_item_add_*` call is
marshalled by value to another thread. A borrowed slice cannot cross that — the
exact wall [friction §7][friction] predicts for a backend that records on one
thread and submits on another.

The scheme is uniform: commands own their memory (`Item::clear()` walks the chain
calling `c->~Command()` and zeroes block usage, keeping the blocks for reuse);
large payloads are `RID` handles into server-side owner tables, so lifetime is
the server's, not the display list's; derived GPU resources get RAII
(`Polygon::create()` calls `request_polygon`, `~Polygon()` calls `free_polygon`);
and text payloads do not exist here at all.

This reinforces F8 from a fourth direction and adds a motive our friction log
only anticipates: you stop borrowing the moment a queue might sit in the seam.
Godot reaches F8's stronger form by a different route — an `RID` is an index into
a server-side owner table, which makes a command trivially copyable and
thread-transferable for the same reason an offset pair would.

## Q8 — extent query

**Godot answers the scene-side half of F7, and answers it on the
derived-by-scan axis.** F7 separates surface extent from layout extent from ink
extent and asks, of each, whether it is maintained at construction or derived by
a walk. Godot derives ink extent per canvas item by walking that item's own
commands — _by design_, as a cached and producer-overridable property:

```cpp
const Rect2 &RendererCanvasRender::Item::get_rect() const {
	if (custom_rect || (!rect_dirty && !update_when_visible && skeleton == RID())) {
		return rect;
	}
	//must update rect
	...
	while (c) {
		Rect2 r;
		switch (c->type) {
			case Item::Command::TYPE_RECT: { r = static_cast<const Item::CommandRect *>(c)->rect; } break;
			case Item::Command::TYPE_POLYGON: { r = ...->polygon.rect_cache; } break;
			case Item::Command::TYPE_PRIMITIVE: { for (...) r.expand_to(primitive->points[j]); } break;
			case Item::Command::TYPE_TRANSFORM: { xf = transform->xform; found_xform = true; [[fallthrough]]; }
			default: { c = c->next; continue; }
		}
		if (found_xform) { r = xf.xform(r); }
		rect = first ? r : rect.merge(r);
		c = c->next;
	}
	rect_dirty = false;
```

— [`renderer_canvas_render.cpp`][rcr-cpp]

Three details make it a design rather than a workaround:

- **Cached, invalidated precisely.** `alloc_command` sets `rect_dirty = true`;
  `get_rect()` clears it. The scan is amortized to once per mutation.
- **The producer can declare it.** `canvas_item_set_custom_rect(RID, bool, Rect2)`
  sets `custom_rect` and short-circuits the scan
  ([`renderer_canvas_cull.cpp`][rcc-cpp]) — the answer for a producer that knows
  its bounds, or whose bounds a scan would get wrong.
- **Its consumer is culling, a per-frame hot path**, not an occasional offscreen
  allocation: `_cull_canvas_item` calls `ci->get_rect()`, merges any
  visibility-notifier area, transforms it and caches `global_rect_cache`.

`Polygon::create()` even pre-computes `rect_cache` by expanding over its points
at construction, so per-command extent is cached where it is expensive.

`sparkles:ui` sits on the same axis, one step further back: it has the walk and
none of the three things that make Godot's cheap. There is no `rect` field to
cache into, no `rect_dirty` to invalidate, and no producer override. `CmdBuffer`
answers `length` and a run's `measure`, and "how far does this stream paint" is
a question neither it, nor the display list, nor the arena will answer at all —
so a caller that needs painted bounds folds `op.rect` over the operations
itself, from scratch, and writes that fold out again at the next call site
([friction §8][friction]).

## Strengths

- **The clearest available demonstration that measurement is a service** — not
  "measurement is elsewhere" but a named, enumerable, swappable,
  capability-declaring server with a selection policy and a change notification.
- **Capability declaration on the seam where capability actually varies**, and
  it is load-bearing: it selects the backend, gates data loading and removes
  locales from the UI.
- **The drawing seam is total and tiny** — ten command types, one entry point,
  and a conforming null backend whose whole body is 27 lines; framework-side
  lowering keeps `FEATHER_SIZE` antialiasing in one place.
- **Per-command variable size without a union**, in a cache-coherent arena.
- **Extent is a solved, cached, producer-overridable property of the scene.**

## Weaknesses

- **The measurement interface is enormous** — 216 pure virtuals.
  `TextServerFallback` reimplements nearly all of them and `TextServerDummy`
  exists purely to stub them. Godot's answer to "who can implement this" is _we
  will_ (plus `TextServerExtension` for GDExtension), not a surface a third party
  casually conforms to.
- **Degradation is silent-ignore, with no refusal.** There is no analogue of
  Notcurses' `NCVISUAL_OPTION_NODEGRADE`; asking a fallback server for RTL yields
  LTR and no error. F5's refusable rung is missing, and Godot ships without it.
- **The capability mechanism rotted on the rendering seam** — the enum is marked
  _"Never actually used"_ while the virtual stays for compatibility. A capability
  query survives only where a caller has a decision to make with it.
- **`has_feature` and `get_features` are redundant** and hand-maintained per
  backend; `TextServerAdvanced` rebuilds its bitmask with a second set of
  `#ifdef`s that must match the `switch`. The type tag likewise duplicates the
  `Command` vtable, and no consumer `switch` is exhaustiveness-checked.
- **No cell target anywhere**, so nothing here is tested against the constraint
  this survey exists for.

## Key design decisions and trade-offs

| Decision                                                                      | Rationale                                                                                              | Trade-off                                                                                |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Text is a **separate server** from rendering                                  | ICU + HarfBuzz is optional weight; shaping quality is a deployment choice, not a renderer choice       | The two servers agree on a coordinate space by convention; nothing enforces it           |
| Text draws itself **into** the canvas as textured rects                       | The renderer never learns about fonts; MSDF/LCD reduce to two shader-selecting bits                    | No backend can batch or restyle a text _run_; it sees only rects                         |
| `has_feature` / `get_features` on the **measurement** interface               | Capability genuinely varies between `Advanced` and `Fallback`, and callers act on it                   | Two hand-maintained sources of truth per backend; drift is unchecked                     |
| Missing capability = **silently ignored argument**                            | Keeps call sites free of error handling in an engine where text must always render something           | No way to demand fidelity and be refused — exactly what a golden test wants              |
| Backend chosen by **feature-bitmask popcount**                                | Zero-configuration "use the best available"; a GDExtension server can win automatically                | Treats all features as equal weight; many cheap features outrank `FEATURE_SHAPING`       |
| Drawing seam is **total**, with a null backend rather than a capability query | Ten command types is small enough that everyone implements everything                                  | Degradation is all-or-nothing; no "I cannot do nine-patch, lower it for me"              |
| Rich public API **lowered in `RendererCanvasCull`**                           | One AA/tessellation implementation; backends stay simple                                               | A backend that could draw a real rounded rect never gets the chance                      |
| Commands are **polymorphic subclasses in a 4 KiB block arena**                | Each command pays only its own fields; cache-coherent; blocks reused across frames                     | A vtable pointer plus a redundant tag; no exhaustiveness checking                        |
| Per-item extent **derived by scan, cached, producer-overridable**             | Culling needs it every frame; most items have one command; `custom_rect` covers what a scan gets wrong | The scan must know every command type's bounds — `default:` silently contributes nothing |
| Everything crosses a `CommandQueueMT` to a render thread                      | 2-D submission and GPU work overlap                                                                    | Nothing may be borrowed; every payload is a value or an `RID`                            |

## Bearing on the proposal

1. **Promote `measure` from "not on the canvas" to "its own named service."**
   F1 says measurement leaves the painter; Godot says where it goes. A
   `sparkles:ui` metrics concept should be independently selectable and
   independently testable, and should own the questions a painter cannot answer
   — line breaking, ellipsis, caret rects, grapheme navigation — not just width.
   The direct fix for [friction §1][friction].
2. **Put the declared capability set on the measurement seam, not only on the
   canvas.** This complicates F5, which reads Qt's `PaintEngineFeature` as a
   _renderer_ pattern. In the one surveyed subject with both seams, the
   capability query is alive on the measurer and formally deprecated on the
   renderer. A cell metrics backend (`cellsOf`) and a shaped metrics backend
   differ in capability exactly as `Advanced` and `Fallback` do.
3. **Add the refusable degrade Godot lacks.** Silent-ignore is defensible for an
   engine that must always draw something; it is wrong for a toolkit with a
   golden-image suite. Keep F5's refusable rung; take only the declaration half.
4. **Do not adopt popcount selection.** It ranks `FEATURE_UNICODE_SECURITY`
   equal to `FEATURE_SHAPING`. If `sparkles:ui-app` ever auto-selects a metrics
   backend, rank by a stated preference order.
5. **An arena of variably-sized records avoids the widest-variant cost, and
   `DrawOp` pays that cost.** The claim is about the encoding as it stands:
   `DrawOp` is a closed sum over eight payloads, so a `PopClip` that carries no
   fields at all occupies what a `TextRun` occupies — the second half of
   [friction §4][friction], and Godot's standing position on the trade F3
   describes. Godot's mechanism is the alternative in working form:
   `alloc_command<T>` placement-news each command at its own size into 4 KiB
   `CommandBlock`s that "always grow but never shrink", and one `Type` tag beside
   the vtable is all a consumer needs to `static_cast`
   ([`renderer_canvas_render.h`][rcr-h]). `sparkles.ui.arena` already supplies
   the storage half of that shape, for text and for box chrome.

   The price is what settles it. `static assert(DrawOp.sizeof <= 64)` is a
   budget, not an equality, and the widest arm — `TextRun`, at four fields —
   fits inside it, so the waste variable stride would recover is bounded by the
   gap between two small records rather than by anything that grows with the
   vocabulary. Against that bounded gain: an operation addressed by an offset
   into a byte arena is not a value, and `DrawOp` is one, which is what lets
   `RecordingCanvas` collect operations and compare them pairwise — the item the
   friction log records as working rather than as friction. Every member
   accessor — `kind`, `rect`, `text`, `slot`, `visual`, `translate`, the eight
   scrollbar readers — is an eight-arm `match!` whose exhaustiveness the compiler
   checks, and `OpKind` is derived through one of them precisely so a stored tag
   cannot disagree with the payload; over a byte arena each accessor becomes a
   hand-written `switch` on a tag plus a cast, unchecked for completeness, which
   is Godot's own listed weakness relocated into our source tree. `visualOf`
   would reconstruct a `Visual` from bytes reached through a pointer rather than
   from a typed alternative, and every `final switch` a consumer writes over
   `op.kind` would lose its guarantee. Variable stride buys nothing once the
   widest payload fits the budget, and it costs comparable value semantics: the
   claim is **answered** on that ground, not withdrawn.

6. **Answer [friction §8][friction] with a cached extent and a producer
   override.** F7 splits extent into surface, layout and ink and asks, of each,
   whether it is maintained at construction or derived by a walk. Godot picks
   the walk for ink extent and then makes it cheap: `alloc_command` sets
   `rect_dirty`, `get_rect()` clears it, and `canvas_item_set_custom_rect` lets a
   producer that knows its own bounds skip the walk entirely — for culling, every
   frame. `CmdBuffer` is the only thing that appends to a stream, so the dirty
   bit has an obvious home, and the override has an obvious caller in a widget
   that already knows its rect. Making the display list self-describing is not
   exotic; it is what a shipping engine does, for one bit.
7. **`scrollbar` in the drawing seam: apply Godot's test.** Godot lowers
   everything widget-shaped to triangles in the framework and keeps exactly one
   policy-carrying command, `CommandNinePatch`, because resolving it needs
   information only the backend has. `scrollbarThumb` in `sparkles.ui.state` is
   the one formula every backend renders, and `canvas.d` re-exports
   `scrollbarCellCount` and `scrollbarCell` on top of it, so the rail geometry is
   settled above the seam — and by Godot's test the fourteen-field `Scrollbar`
   payload does not qualify. That sharpens F4's placement question: we pay Qt's
   price, lowering once in the framework, and then hand a semantic operation
   across the seam anyway, which is Slint's camp ([friction §3][friction]).
8. **Thread-crossing is what decides [friction §7][friction].** Godot's borrowing
   question never arises because a `CommandQueueMT` sits in the middle.
   `DrawOp.text` is a 16-byte slice borrowed from a frame arena; `CmdBuffer.textRun`
   copies into that arena, the buffer is move-only so a copy cannot hand out a
   second set of live pointers, and the rule — an operation is valid while the
   buffer that built it is alive and unreset — is stated on the type, which makes
   the borrow enforceable within a frame. It does not make it transferable.
   `sparkles:ui`'s M7/T5 wants Godot's shape, and that is exactly the
   retain-boundary question `UI-O4` holds open.

## Sources

All paths verified to exist at the pinned revision with `git cat-file -e`.

- **Measurement seam** — [`servers/text/text_server.h`][ts-h] (`TextServer`,
  `Feature`, `SubpixelPositioning`, `Glyph`, `CaretInfo`, `TextServerManager`,
  the `TS` macro), [`text_server.cpp`][ts-cpp] (`add_interface`,
  `set_primary_interface`, `NOTIFICATION_TEXT_SERVER_CHANGED`),
  [`text_server_dummy.h`][ts-dummy] (the zero-feature implementation).
- **Its two real implementations** — [`text_server_adv.cpp`][adv-cpp]
  (`_has_feature`, `_get_features`, `_font_draw_glyph`, the subpixel/LCD
  cache-key packing) and [`text_server_fb.cpp`][fb-cpp] (`_has_feature`, the
  `// "Shape" string.` loop).
- **Drawing seam** — [`renderer_canvas_render.h`][rcr-h] (`Item`,
  `Item::Command` and subclasses, `CommandBlock`, `alloc_command`,
  `canvas_render_items`, `CanvasRectFlags`),
  [`renderer_canvas_render.cpp`][rcr-cpp] (`Item::get_rect()`),
  [`renderer_canvas_cull.cpp`][rcc-cpp] (`canvas_item_add_line` lowering,
  `canvas_item_set_custom_rect`, culling), [`rendering_server.h`][rs-h] (the
  public `canvas_item_add_*` API and `RenderingServer::has_feature`),
  [`rendering_server_enums.h`][rs-enums] (the deprecated `RSE::Features`),
  [`rendering_server_default.h`][rsd-h] / [`.cpp`][rsd-cpp] (`CommandQueueMT`,
  the render thread, `has_feature` returning `false`).
- **Its backends** — [`renderer_canvas_render_rd.cpp`][rd-cpp] and
  [`rasterizer_canvas_gles3.cpp`][gles3-cpp] switching exhaustively over the same
  command types; [`rasterizer_canvas_dummy.h`][dummy-h], the null backend.
- **Above the seam** — [`style_box_flat.cpp`][sbf-cpp] (widget chrome
  tessellated in `scene/`), [`main/main.cpp`][main-cpp] (popcount backend
  selection, the `internationalization/rendering/text_driver` setting),
  [`editor_settings.cpp`][ed-settings] (locales skipped on missing features).
- **Official documentation** — [`doc/classes/TextServer.xml`][ts-xml], the
source of the published class reference and of the silent-ignore contract.
<!-- References -->

[rev]: https://github.com/godotengine/godot/tree/944a3c6cbbbb88284feebcb0603464cb175fa18e
[repo]: https://github.com/godotengine/godot
[license]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/LICENSE.txt
[version]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/version.py
[ts-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/text/text_server.h
[ts-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/text/text_server.cpp
[ts-dummy]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/text/text_server_dummy.h
[ts-xml]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/doc/classes/TextServer.xml
[adv-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/text_server_adv/text_server_adv.cpp
[fb-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/text_server_fb/text_server_fb.cpp
[rcr-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/renderer_canvas_render.h
[rcr-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/renderer_canvas_render.cpp
[rcc-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/renderer_canvas_cull.cpp
[rs-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/rendering_server.h
[rs-enums]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/rendering_server_enums.h
[rsd-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/rendering_server_default.h
[rsd-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/rendering_server_default.cpp
[dummy-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/dummy/rasterizer_canvas_dummy.h
[rd-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/servers/rendering/renderer_rd/renderer_canvas_render_rd.cpp
[gles3-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/drivers/gles3/rasterizer_canvas_gles3.cpp
[sbf-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/scene/resources/style_box_flat.cpp
[main-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/main/main.cpp
[ed-settings]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/settings/editor_settings.cpp
[cmp]: ./comparison.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
