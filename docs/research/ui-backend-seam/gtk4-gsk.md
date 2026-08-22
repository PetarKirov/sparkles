# GTK4 / GSK — the seam is the scene, and the renderer interface is four methods

**Category:** retained render tree. **Last reviewed:** August 23, 2026.
Pinned at [`817caae3`][rev].

GSK ("the GTK Scene Kit") is the survey's clearest case of a **reified,
semantic, self-describing scene** consumed by four independent renderers. It is
the subject that most directly contradicts the current synthesis: where
[`comparison.md`][comparison]'s **F7** concluded that extent belongs to the
surface rather than the scene, GSK puts a `bounds` rectangle on the base class
of every node and builds three separate fallback paths on top of it.

| Field                | Value                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------- |
| **Language**         | C (GObject)                                                                               |
| **License**          | `LGPL-2.1-or-later` ([`meson.build`][meson-root] `license:`)                              |
| **Repository**       | [`GNOME/gtk`][repo] (GitHub mirror of `gitlab.gnome.org/GNOME/gtk`)                       |
| **Documentation**    | [`docs/reference/gsk/`][docs-gsk] in-tree; the API reference is generated from it         |
| **Category**         | retained render tree                                                                      |
| **Pinned revision**  | `817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671` (`version: '4.23.1'`, development toward 4.24) |
| **Target range**     | desktop GPU (Vulkan, OpenGL), desktop CPU (Cairo), and a **remote browser** (Broadway)    |
| **Backends shipped** | `cairo`, `gl`, `vulkan`, `broadway` — all four run the same golden suite                  |
| **Node kinds**       | **37** (`GskRenderNodeType`, [`gskenums.h`][enums] L160–L196)                             |

## Overview

### What it solves

GTK widgets never draw. They _describe_: a widget's `snapshot` vmethod appends
nodes to a `GtkSnapshot` builder, and what leaves the widget layer is an
immutable tree of `GskRenderNode` values. A `GskRenderer` then consumes that
tree. The seam between them is not a painter interface — it is a **data
structure**, and the renderer interface proper is four methods with no drawing
primitives in it at all.

### Design philosophy

The scene is transient, immutable, and refcounted — stated verbatim in the
class documentation ([`gskrendernode.c`][rendernode-c] L22–L34):

```c
 * The basic block in a scene graph to be rendered using [class@Gsk.Renderer].
 *
 * Each node has a parent, except the top-level node; each node may have
 * children nodes.
 *
 * Each node has an associated drawing surface, which has the size of
 * the rectangle set when creating it.
 *
 * Render nodes are meant to be transient; once they have been associated
 * to a [class@Gsk.Renderer] it's safe to release any reference you have on
 * them. All [class@Gsk.RenderNode]s are immutable, you can only specify their
 * properties during construction.
```

"Each node has an associated drawing surface, which has the size of the
rectangle set when creating it" is the load-bearing sentence for **Q8**. Every
node knows its own extent, at construction, by construction.

## How it works

`GskRenderNode` is a GObject-style type hierarchy, not a tagged struct. The base
instance carries only what _every_ node has — a `gatomicrefcount`, a
`graphene_rect_t bounds`, and eight bitfield flags
(`preferred_depth`, `copy_mode`, `fully_opaque`, `is_hdr`, `clears_background`,
`contains_subsurface_node`, `contains_paste_node`, `needs_blending`)
([`gskrendernodeprivate.h`][rn-priv] L32–L48). Each kind embeds that base and
adds exactly its own fields — a sum type expressed by subtyping, allocated at
the registered `instance_size` by `gsk_render_node_alloc (GType)`. A
`GskColorNode` is a base plus `GdkColor color; GskRectSnap snap;`; a
`GskBorderNode` adds an outline, four widths, four colours and two snap words.
Nothing pays for a field belonging to another kind.

The **defining declaration of the seam** is the node class vtable, not a painter
interface ([`gskrendernodeprivate.h`][rn-priv] L71–L97, abridged):

```c
struct _GskRenderNodeClass
{
  GTypeClass parent_class;
  GskRenderNodeType node_type;

  void          (* finalize)      (GskRenderNode *node);
  void          (* draw)          (GskRenderNode *node, cairo_t *cr, GskCairoData *data);
  gboolean      (* can_diff)      (const GskRenderNode *node1, const GskRenderNode *node2);
  void          (* diff)          (GskRenderNode *node1, GskRenderNode *node2, GskDiffData *data);
  GskRenderNode**(* get_children) (GskRenderNode *node, gsize *n_children);
  GskRenderNode*(* replay)        (GskRenderNode *node, GskRenderReplay *replay);
  void          (* render_opacity)(GskRenderNode *node, GskOpacityData *data);

  /* GPU renderer */
  GskGpuRenderPass * (* occlusion)(GskRenderNode *node, GskGpuOcclusion *occlusion);
};
```

`draw` is the decisive entry: **every node kind ships its own CPU rasterization
against Cairo**. That one fact pays for the Cairo renderer (228 lines total,
[`gskcairorenderer.c`][cairo-renderer], whose whole render step is
`gsk_render_node_draw_with_color_state (root, cr, …)`) _and_ for every other
renderer's fallback path.

The renderer interface itself is startlingly small
([`gskrendererprivate.h`][renderer-priv] L36–L54):

```c
struct _GskRendererClass
{
  GObjectClass parent_class;

  gboolean supports_offload;

  gboolean     (* realize)        (GskRenderer *renderer, GdkDisplay *display,
                                   GdkSurface *surface, gboolean attach, GError **error);
  void         (* unrealize)      (GskRenderer *renderer);
  GdkTexture * (* render_texture) (GskRenderer *renderer, GskRenderNode *root,
                                   const graphene_rect_t *viewport);
  void         (* render)         (GskRenderer *renderer, GskRenderNode *root,
                                   const cairo_region_t *invalid);
};
```

Two lifecycle hooks, two submit hooks, one boolean. There is no `fillRect`, no
`drawText`, no capability enum. Everything a backend must understand is in the
tree it is handed.

## Q1 — measurement units, and who answers

**Nobody measures at the seam, because text has already been shaped before a
node exists.** `gsk_text_node_new` takes a `PangoFont` and a
`PangoGlyphString` ([`gsktextnode.h`][textnode-h] L36–L39) — positioned glyph
IDs, not a string. GSK never sees the characters.

The node's extent is then computed once, from Pango, at construction
([`gsktextnode.c`][textnode-c] L240, L280–L284):

```c
  gsk_get_glyph_string_extents (glyphs, font, &ink_rect);
  /* … */
  gsk_rect_init (&node->bounds,
                 offset->x + pango_units_to_float (ink_rect.x),
                 offset->y + pango_units_to_float (ink_rect.y),
                 pango_units_to_float (ink_rect.width),
                 pango_units_to_float (ink_rect.height));
```

The detail worth stealing is _how_ it measures. `gsk_get_glyph_string_extents`
([`gskprivate.c`][gskprivate] L123–L149) is documented as "like
[method@Pango.GlyphString.extents], but it **ignores hinting of the font**",
and implements that by reloading the font with `CAIRO_HINT_STYLE_NONE` before
asking. The measurement is deliberately de-hinted so that **all four renderers
agree on a node's bounds** regardless of how any of them will rasterize it.

That is a sharper statement of **F1** than any prior subject supplies. It is not
merely that measurement lives above the painter; it is that a scene shared by
disagreeing rasterizers requires a measurement _no rasterizer influences_. Our
`isCanvas.measure` fails on both counts: it is on the painter, and its answer
(`cellsOf(text)`) is a property of one target's grid.

The unit is device-independent logical pixels, arrived at from Pango units
(`PANGO_SCALE` = 1024 per pixel) via `pango_units_to_float`. Sub-pixel advance
survives into the node; device pixels appear only inside a renderer.

## Q2 — is the contract stated in one place?

Stated in one place, but that place is an **enum of node kinds**, not a
capability list. `GskRenderNodeType` ([`gskenums.h`][enums] L159–L197) is the
whole vocabulary: 37 kinds, publicly documented, versioned with `Since:`
annotations, and — crucially — the same enum a backend switches over. Compare
our `OpKind`'s eight members plus three primitives discovered by
`__traits(compiles)` at scattered call sites ([friction §2][friction]).

**There is no capability query.** `GskRendererClass` carries exactly one
capability boolean, `supports_offload`, and it is about Wayland subsurfaces, not
drawing. What replaces `QPaintEngine::hasFeature` is a **three-layer fallback
ladder**, and the layering is the interesting part:

1. **Backend selection is itself a ladder terminating in Cairo.**
   `renderer_possibilities[]` ([`gskrenderer.c`][renderer-c] L707–L719) tries
   display override → `GSK_RENDERER` env var → per-backend preference → Vulkan
   → GL → Vulkan-as-fallback → GL-as-fallback → `get_renderer_fallback`, which
   unconditionally returns `GSK_TYPE_CAIRO_RENDERER`. Something always realizes.

2. **Within the GPU renderer, an unimplemented node kind falls through to
   Cairo.** The GPU renderer dispatches through a sparse table indexed by node
   type ([`gskgpunodeprocessor.c`][gpu-processor] L3655–L3819), with a `NULL`
   entry meaning "not implemented here" (L3837–L3847):

   ```c
   if (nodes_vtable[node_type].process_node)
     {
       nodes_vtable[node_type].process_node (self, node);
     }
   else
     {
       g_warning_once ("Unimplemented node '%s'",
                       g_type_name_from_instance ((GTypeInstance *) node));
       /* Maybe it's implemented in the Cairo renderer? */
       gsk_gpu_node_processor_add_cairo_node (self, node);
     }
   ```

   `gsk_gpu_node_processor_add_cairo_node` (L718–L740) rasterizes the node
   through `gsk_render_node_draw_fallback`, uploads the result, and composites
   it as an image. The degradation is _universal_ — it works for any node kind,
   present and future — because the node type owns its own CPU renderer.

3. **A backend may decline a kind wholesale.** Broadway, which speaks a protocol
   to a browser, emits a native protocol op for roughly fifteen of the 37 kinds
   and lets every other kind hit a single `default:` that rasterizes with
   `gsk_render_node_draw` into an image sized from `node->bounds`
   ([`gskbroadwayrenderer.c`][broadway] L905–L957). Its own source labels the
   group "Fallbacks (=> leaf for now" (L299).

> [!IMPORTANT]
> This is a genuinely different answer from the two **F4** identified. Qt
> emulates in the _framework_ and hands the engine an image; Slint degrades in
> the _backend_. GSK degrades in the **node kind** — a third location, and the
> only one where adding a node kind cannot break an existing backend, because
> the fallback ships with the kind rather than with either the framework or the
> renderer.

What GSK does _not_ offer is **refusal**. There is no `NODEGRADE` flag. Instead
it offers **observability**: `gsk_render_node_draw_fallback`
([`gskrendernode.c`][rendernode-c] L480–L529) is `gsk_render_node_draw` plus, under
`GSK_DEBUG=cairo`, a pink-and-black 2×2 checkerboard painted over the result at
60% alpha, with a distinct colour for a genuine `GskCairoNode`. Its docstring
states the purpose: "1. It allows detecting fallbacks in GPU renderers / 2. Application code can use it to detect where it is using Cairo drawing".

## Q3 — semantic operations, and where the semantics stop

GSK's vocabulary is **semantic, but at exactly one layer**: the CSS box model.
`GskBorderNode` carries an outline, four widths and four colours
([`gskbordernode.h`][bordernode]); `GskInsetShadowNode` carries an outline,
colour, `dx`, `dy`, `spread` and `blur_radius`
([`gskinsetshadownode.h`][insetshadow]). A renderer is told "this is a border",
never "fill these four rects".

But there is **no scrollbar node**, and no widget-level node of any kind. GTK
resolves widget semantics into CSS boxes _above_ the seam:
`gtk_css_style_snapshot_border` ([`gtkrenderborder.c`][renderborder] L656–L745)
turns a resolved CSS style into `gtk_snapshot_add_border` calls. The layering is
explicit and one-directional — widget → CSS style → render node → renderer.

This is the useful correction to **F3**. Slint proved that semantic operations
are legitimate; GSK adds _where to stop_. The test GSK applies is not "is this
meaningful to a user" but **"do the backends disagree about how to draw it?"** A
border is a node because a GPU can do it in one shader pass and Cairo cannot; a
scrollbar is not a node because every backend would draw one identically once the
CSS is resolved.

By that test, `sparkles:ui`'s `scrollbar` op is defensible only because a _cell_
backend genuinely draws a scrollbar differently — but its eight `DrawOp` fields
(`barContent`, `barViewport`, `barOffset`, `expandPercent`, `barTrackLit`,
`barTrackColor`, `barTrackGlyph`, `barThumbGlyph`) push widget policy
(`barThumbGlyph = '█'`) into the seam in a way GSK never does. GSK's semantic
nodes carry _geometry and colour_, never a fallback glyph.

One node exists purely to carry meaning with no rendering effect at all:
`GskDebugNode` wraps a child and a `char *message`
([`gskdebugnode.h`][debugnode] L36–L41), which renderers pass through and
tooling reads. A precedent for annotating a stream without teaching the painter
anything.

## Q4 — command shape

**Not a tag plus dead fields, and not a closed sum type either — a GType
hierarchy.** The base struct holds a refcount, a bounds rect and eight flag
bitfields; each kind's struct holds only its own fields;
`gsk_render_node_alloc` allocates the registered `instance_size`. A
`GskBorderNode` never pays for `blur_radius`; a `GskColorNode` carries only a
`GdkColor` and a `GskRectSnap` past its base.

This is the **third** distinct answer the survey has found to Q4: virtual
dispatch with no command values (Slint, Qt), a Rust `enum` sum type (egui), and
now an open, extensible, per-kind-sized class hierarchy that is nevertheless
inspectable as data (`gsk_render_node_get_node_type`,
`gsk_render_node_get_children`, per-kind accessors).

The extensibility matters: twelve of the 37 kinds carry a post-4.0 `Since:`
marker (4.10 through 4.22, [`gskenums.h`][enums] L61–L157), and each addition
cost existing backends nothing — the new kind arrives with its own `draw`, and
every GPU backend's `NULL` table entry degrades it automatically. A closed sum
type would have made every backend non-exhaustive on each addition. **This
complicates F2**: reifying the stream is right, but a `SumType` is only one of
the shapes that buys the properties we want, and it is the shape with the worst
extension story.

The reification is real enough to be a **file format**. `gsk_render_node_serialize`
/ `gsk_render_node_deserialize` ([`gskrendernode.h`][rendernode-h] L118, L124)
round-trip the tree through a CSS-syntax text format
([`node-format.md`][node-format]), whose stated purpose is the exact
justification `RecordingCanvas` was built on:

> GSK render nodes can be serialized and deserialized using APIs such as
> `gsk_render_node_serialize()` and `gsk_render_node_deserialize()`. The
> intended use for this is development - primarily the development of GTK - by
> allowing things such as creating testsuites and benchmarks, exchanging nodes
> in bug reports.

`testsuite/gsk/compare/` holds **279 `.node` files** with reference PNGs, and
[`testsuite/gsk/meson.build`][testsuite] L325–L338 runs them across every built
renderer (`cairo`, `gl`, `broadway`, `vulkan`) in nine variants (`plain`,
`flip`, `rotate`, `repeat`, `mask`, `replay`, `clip`, `colorflip`, `serialize`).
Per-renderer known failures are an explicit data table, `compare_xfails`
(L353–L385), and a test can opt a renderer out by _filename_ convention —
`exclude_term = '-no' + renderer_name` (L394), which is why
`rounded-clip-in-clip-nocairo.node` exists.

> [!NOTE]
> That xfail table is GSK's substitute for a declared capability set: capability
> is not queried at runtime, it is **asserted at test time**, per node kind, per
> renderer, with a bug number in a comment. It is a weaker contract than Qt's
> `hasFeature` and a considerably more honest one.

## Q5 — sub-unit placement

GSK's coordinates are continuous `float`s throughout (`graphene_rect_t`,
`GskRoundedRect`), which by **F5**'s reasoning should dissolve the problem. **It
does not.** A per-edge pixel-snapping policy was added to the seam, annotated
`Since: 4.24` (the pinned tree is `4.23.1`, so this is pre-release API)
([`gskrectsnap.h`][rectsnap], `GskSnapDirection` at [`gskenums.h`][enums]
L631–L651):

```c
typedef enum {
  GSK_SNAP_NONE,
  GSK_SNAP_FLOOR,
  GSK_SNAP_CEIL,
  GSK_SNAP_ROUND
} GskSnapDirection;
```

A `GskRectSnap` packs four of those, one per side, into a `guint32`
(`GSK_RECT_SNAP_INIT (top, right, bottom, left)`), and it is stored **on the
node** — `GskColorNode.snap`, and _two_ on `GskBorderNode` (`snap` and
`border_snap`, exposed as `gsk_border_node_get_snap` /
`gsk_border_node_get_border_snap`, both `Since: 4.24`). Three named
compositions ship: `GSK_RECT_SNAP_GROW`, `GSK_RECT_SNAP_SHRINK`,
`GSK_RECT_SNAP_ROUND`, each documented by the artifact it avoids — grow "is
useful to avoid seams but can lead to overlap with adjacent content"; shrink
makes the rect "fit into the allocated area"; round is for rects "placed next to
each other at the same coordinate … without any seams".

This is the survey's most important amendment to **F5**. Continuous coordinates
do not remove the sub-device-unit problem; they _relocate_ it, from "where do I
put this hairline" to "which way does this edge round when the renderer lands it
on a device grid". And GSK's answer has exactly the shape F5 recommends for
`RuleEdge`: the scene **names an intent per edge**, and the renderer resolves it
at its own scale. `GSK_SNAP_GROW` and a `RuleEdge` are the same species of
declaration — a compass with a policy attached instead of a position.

> [!WARNING]
> The direct read-across is limited: our cells are _coarser_ than device pixels,
> GSK's logical pixels are _finer_. But `GskRectSnap` demonstrates that a
> per-edge enum in the display list is a shape a mature toolkit chose
> deliberately in 2025, not a symptom of integer coordinates.

## Q6 — resolved or semantic appearance

**Resolved only, with one twist.** Nodes carry `GdkColor` / `GdkRGBA` values,
never a style role — CSS has been fully resolved by `GtkSnapshot` time. GSK does
include `gtk/css/gtkcss.h` ([`gskrendernode.h`][rendernode-h] L27), but that is
the CSS _tokenizer_ the node file format parses with, not the style-resolution
machinery; no node has a selector, a class or a state.

The twist is `GdkColorState`. A `GdkColor` is a colour state plus values, and
`gsk_text_node_get_color`'s own documentation warns that "the value returned by
this function will not be correct if the render node was created for a non-sRGB
color" ([`gsktextnode.c`][textnode-c] L291–L305). So a renderer _does_ perform a
resolution step — colour-space conversion into its compositing space — but the
thing being resolved is a physical property, not a semantic one.

Broadway is the subject's re-resolving backend, and it is the direct analogue of
our HTML interpreter: it must express a node in a foreign vocabulary rather than
paint it. GSK gives it **no semantic help whatsoever**, and Broadway's answer is
to map the roughly fifteen kinds whose resolved form it can express
(`BROADWAY_NODE_COLOR`,
`_BORDER`, `_INSET_SHADOW`, `_LINEAR_GRADIENT`, `_ROUNDED_CLIP`, …) and
rasterize the rest.

That is evidence against carrying both `visual` and `slot` on every op
([friction §6][friction]): a real re-resolving backend was served adequately by
resolved values plus semantic _kinds_, without a parallel role field. Our `slot`
is doing work the _op kind_ could do, if the kinds were finer-grained.

## Q7 — payload ownership

**Owned, refcounted, immutable — never borrowed.** `GskRenderNode` carries a
`gatomicrefcount`; `gsk_render_node_ref` / `_unref` are public
([`gskrendernode.h`][rendernode-h] L95, L97); and the class docs state nodes are
"immutable, you can only specify their properties during construction".

Text is the sharpest contrast with `DrawOp.text`. `gsk_text_node_new2` does not
retain a caller slice: it `g_object_ref`s the `PangoFont` and its font map, and
`g_malloc_n`s a private `PangoGlyphInfo` array, copying the glyphs while
filtering `PANGO_GLYPH_EMPTY` ([`gsktextnode.c`][textnode-c] L251–L280). The
node is thereafter self-sufficient.

That ownership is what makes the GPU fallback path legal at all:
`gsk_gpu_node_processor_add_cairo_node` passes `gsk_render_node_ref (node)` into
an upload op with `gsk_render_node_unref` as its destroy-notify
([`gskgpunodeprocessor.c`][gpu-processor] L728–L732) — the node deliberately
**outlives the frame walk** so the rasterization can happen later. With a
borrowed `DrawOp.text`, that entire pattern is unavailable, which is precisely
the record-on-one-thread / submit-on-another problem [friction §7][friction]
anticipates.

**F6** stands and is strengthened: refcounting, not interning, and the
refcount is atomic so deferred work is expressible.

## Q8 — extent query

**GSK answers Q8 affirmatively, at three levels, and this contradicts F7.**

`graphene_rect_t bounds` is a field of the _base_ node struct, populated at
construction by every kind, and publicly readable
([`gskrendernode.h`][rendernode-h] L102–L104) with the documented invariant
"The node will not draw outside of its boundaries."
([`gskrendernode.c`][rendernode-c] L370–L386). It is not derived by scanning
children at query time; it is computed once, bottom-up, when the node is built.

Three consumers depend on it:

1. **The offscreen-sizing case F7 called "narrow".**
   `gsk_renderer_render_texture`'s `viewport` parameter is documented
   "(nullable): the section to draw or `NULL` to use @root's bounds", and the
   implementation does exactly that ([`gskrenderer.c`][renderer-c] L377–L417):

   ```c
   if (viewport == NULL)
     {
       gsk_render_node_get_bounds (root, &real_viewport);
       viewport = &real_viewport;
     }
   ```

   This is `skia-canvas-render.d`'s problem, solved by the scene rather than by
   a scan.

2. **Every fallback rasterization.** Broadway sizes its Cairo image from
   `node->bounds` directly ([`gskbroadwayrenderer.c`][broadway] L937–L947), and
   the GPU processor clips and snaps `node->bounds` before uploading. A backend
   that cannot render a kind still needs its extent, and gets it for free.

3. **Culling.** `gsk_gpu_node_processor_add_node_untracked` opens with
   `if (!gsk_gpu_render_pass_in_clip_fast (self, &node->bounds)) return;`
   ([`gskgpunodeprocessor.c`][gpu-processor] L3827) — whole-subtree
   rejection before any dispatch.

F7 argued that "a backend allocating a surface generally knows the size because
it chose it." That is true for a window and false for everything else GSK does
with bounds. The correct generalisation is narrower and more useful: **a
self-describing extent is what makes partial backend support cheap.** Without
it, "rasterize this subtree I do not understand" has no surface to rasterize
into.

## Strengths

- **A backend cannot be incomplete in a way that breaks a program.** Because
  `draw` ships with the node kind, every kind has a working CPU renderer, so
  every partial backend has a correct-if-slow path for the rest.
- **The renderer interface does not grow.** Twelve node kinds were added since
  4.0 without a single new method on `GskRendererClass`.
- **The scene is data, so it is a file format, a test corpus, an editor
  (`gtk4-node-editor`) and a bug-report artifact** — one reification paying for
  four tools.
- **Extent is free and always right**, which makes offscreens, culling and
  fallbacks all fall out of the same field.
- **Per-kind allocation** means the vocabulary can be wide without every command
  paying for the widest one.
- **Fallbacks are observable** (`GSK_DEBUG=cairo` paints them pink) rather than
  silent.

## Weaknesses

- **No capability query and no refusal.** A caller cannot ask whether a hairline
  will be a hairline, and cannot demand failure instead of degradation. The
  substitute is a hand-maintained xfail table in the build system.
- **Fallback is a cliff, not a ladder.** The degradation for "I cannot do this"
  is always "rasterize on the CPU and upload" — correct, but the performance
  difference between a supported and an unsupported node is enormous and only
  visible through a debug env var.
- **37 kinds is a large surface for a new backend.** Broadway, the least
  capable, natively handles under half of them; a fifth renderer starts from a
  large table of `NULL`s.
- **Refcounted GObject nodes have real allocation cost** per frame per node,
  which the GPU renderer's node-level caching exists partly to amortize.
- **The tree must be rebuilt whole**; incrementality is recovered afterwards by
  `can_diff`/`diff` comparing two trees, not by mutating one.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                    | Trade-off                                                                        |
| --------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| The seam is a **data structure**, not a painter interface | Backends can reorder, cull, batch, cache and diff; the scene is inspectable  | Every frame allocates a tree; incrementality needs a separate diff pass          |
| **Node kinds as a GType hierarchy**, per-kind sized       | Kinds can be added without touching backends or paying for the widest kind   | No exhaustiveness checking; a backend's `NULL` entry is silent by default        |
| **`draw` (Cairo) on every node class**                    | One universal, always-correct fallback for any backend and any future kind   | Every node kind must be implementable on the CPU — constrains what may be a node |
| **`bounds` on the base class**, computed at construction  | Culling, offscreen sizing and fallback rasterization all become trivial      | Bounds must be conservative and correct at build time; a node cannot grow later  |
| **Semantics stop at the CSS box model**                   | Backends genuinely disagree about borders and shadows; not about scrollbars  | Widget-level intent is unavailable to a backend that might want it               |
| **No capability query; ordered renderer fallback**        | Something always realizes; applications need no backend knowledge            | Silent quality cliffs; capability is asserted in a test table, not the API       |
| **De-hinted text measurement** (`CAIRO_HINT_STYLE_NONE`)  | All renderers must agree on a node's bounds regardless of rasterization      | Bounds are slightly loose relative to what any one renderer actually inks        |
| **Per-edge `GskRectSnap` on nodes** (4.24)                | The scene states snapping _intent_; the renderer applies it at its own scale | Another enum in the seam, on a toolkit whose coordinates are already continuous  |

## Bearing on the proposal

1. **Q8 / [friction §8][friction]: put an extent on the op — F7 is wrong as
   stated.** GSK carries `bounds` on the base of every node and gets offscreen
   sizing, subtree culling and fallback rasterization from that one field.
   `gsk_renderer_render_texture (…, viewport: NULL)` is precisely
   `skia-canvas-render.d`'s scan, replaced by a lookup. Report this as a
   **contradiction of F7** in the synthesis, not a refinement.

2. **Q4 / [friction §4][friction]: the extension story should decide the
   encoding, not just the dead fields — F2 is incomplete.** GSK gets every
   property `RecordingCanvas` needs (values, comparable, serializable,
   replayable) from an _open_ hierarchy, and has added twelve kinds without
   breaking a backend. If `DrawOp` becomes a closed `SumType`, price the fact
   that each new kind then makes every backend non-exhaustive.

3. **Q2 / [friction §2][friction]: move the fallback onto the op kind.** GSK's
   third location for degradation — neither framework (Qt) nor backend (Slint)
   but **the kind itself** — is the one that makes optional support cheap.
   `ruleEndpoints` and `scrollbarCell` in [`canvas.d`][canvas] are already
   exactly this pattern: a kind-owned degradation a backend may call. Finish the
   job: make _every_ optional op carry its own fallback, and let the concept say
   so, instead of scattering `__traits(compiles)`.

4. **Q3 / [friction §3][friction]: keep semantic ops, but apply GSK's test.** A
   kind earns its place when **backends disagree about how to draw it**. By that
   test `scrollbar` survives (a cell backend really is different) but its
   `barTrackGlyph` / `barThumbGlyph` fields do not — those are widget policy,
   and GSK's semantic nodes carry only geometry and colour.

5. **Q1 / [friction §1][friction]: F1 confirmed, and sharpened.** Measurement
   must not merely live off the painter; in a multi-backend scene it must be
   _deliberately independent of any rasterizer_, which is why GSK measures with
   hinting off. A `sparkles:ui` font abstraction should return a unit no backend
   can perturb.

6. **Q5 / [friction §5][friction]: F5 needs amending.** Continuous coordinates
   did **not** dissolve the sub-unit problem for GTK; 4.24 added a per-edge
   `GskSnapDirection` to the node. The transferable form is "the scene names an
   intent per edge, the backend resolves it at its own scale" — which is what
   `RuleEdge` already does, and an argument for giving `RuleEdge` a _policy_
   (grow / shrink / round) rather than replacing it with more positions.

7. **Q7 / [friction §7][friction]: F6 confirmed at the strongest setting.**
   Nodes copy their payloads and hold an _atomic_ refcount, and that is exactly
   what lets the GPU renderer defer rasterization past the frame walk — the
   M7/T5 record-here-submit-there case.

8. **Adopt the golden corpus shape.** 279 serialized scenes × four renderers ×
   nine transformation variants, with per-renderer known failures as a data
   table. Our op-stream parity harness is the same idea one backend short; the
   `serialize` variant (round-trip the scene, re-render, compare) is a free test
   we do not yet run.

## Sources

Every path below was read in a local clone of [`GNOME/gtk`][repo] at
`817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671` and verified to exist at that
revision with `git cat-file -e`. GTK's canonical home is
`gitlab.gnome.org/GNOME/gtk`; the GitHub repository is an official mirror
carrying the same commit hashes, and is cited here because it pins by
40-character SHA.

- **The seam** — [`gsk/gskrendernodeprivate.h`][rn-priv] (`struct _GskRenderNode`
  L32–L48, `struct _GskRenderNodeClass` L71–L97);
  [`gsk/gskrendererprivate.h`][renderer-priv] (the four-method renderer class);
  [`gsk/gskrendernode.h`][rendernode-h] and [`gsk/gskrendernode.c`][rendernode-c]
  (class docs L22–L34, `get_bounds` L370–L386, `draw_fallback` L480–L529);
  [`gsk/gskenums.h`][enums] (`GskRenderNodeType` L159–L197, `GskSnapDirection`
  L631–L651).
- **The backends** — [`gsk/gskcairorenderer.c`][cairo-renderer] (228 lines);
  [`gsk/gpu/gskgpunodeprocessor.c`][gpu-processor] (`nodes_vtable[]` L3655–L3819,
  the Cairo fallback L3837–L3847, `add_cairo_node` L718–L740);
  [`gsk/broadway/gskbroadwayrenderer.c`][broadway] (the rasterizing `default:`
  L905–L957); [`gsk/gskrenderer.c`][renderer-c] (`NULL` viewport L377–L417,
  `renderer_possibilities[]` L707–L719).
- **Text and geometry** — [`gsk/gsktextnode.h`][textnode-h],
  [`gsk/gsktextnode.c`][textnode-c], [`gsk/gskprivate.c`][gskprivate]
  (de-hinted extents L123–L149), [`gsk/gskrectsnap.h`][rectsnap].
- **Semantic kinds** — [`gsk/gskbordernode.h`][bordernode],
  [`gsk/gskinsetshadownode.h`][insetshadow], [`gsk/gskdebugnode.h`][debugnode].
- **Above the seam** — [`gtk/gtksnapshot.h`][snapshot-h],
  [`gtk/gtksnapshot.c`][snapshot-c] (`append_cairo` L2925–L2960),
  [`gtk/gtkrenderborder.c`][renderborder] (CSS → border nodes L656–L745).
- **Verification harness** — [`testsuite/gsk/meson.build`][testsuite] (renderer
  matrix L325–L338, `compare_xfails` L353–L385, the `-no<renderer>` convention
  L394); [`docs/reference/gsk/node-format.md`][node-format].
- **Survey context** — the [umbrella][index], the [synthesis][comparison],
  [Slint][slint], [Qt][qt], [egui][egui], [Notcurses][notcurses],
  [`canvas-seam-friction.md`][friction] and
  [`libs/ui/src/sparkles/ui/canvas.d`][canvas].

<!-- References -->

[rev]: https://github.com/GNOME/gtk/tree/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671
[repo]: https://github.com/GNOME/gtk
[meson-root]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/meson.build
[docs-gsk]: https://github.com/GNOME/gtk/tree/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/docs/reference/gsk
[node-format]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/docs/reference/gsk/node-format.md
[rendernode-h]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrendernode.h
[rendernode-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrendernode.c
[rn-priv]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrendernodeprivate.h
[enums]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskenums.h
[renderer-priv]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrendererprivate.h
[renderer-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrenderer.c
[cairo-renderer]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskcairorenderer.c
[gpu-processor]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gpu/gskgpunodeprocessor.c
[broadway]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/broadway/gskbroadwayrenderer.c
[textnode-h]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gsktextnode.h
[textnode-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gsktextnode.c
[gskprivate]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskprivate.c
[bordernode]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskbordernode.h
[insetshadow]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskinsetshadownode.h
[debugnode]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskdebugnode.h
[rectsnap]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrectsnap.h
[snapshot-h]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtksnapshot.h
[snapshot-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtksnapshot.c
[renderborder]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkrenderborder.c
[testsuite]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/testsuite/gsk/meson.build
[index]: ./index.md
[comparison]: ./comparison.md
[slint]: ./slint.md
[qt]: ./qt-qpaintengine.md
[egui]: ./egui.md
[notcurses]: ./notcurses.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
