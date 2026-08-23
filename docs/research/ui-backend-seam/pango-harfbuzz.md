# Pango and HarfBuzz — measurement is a layer, and it is device-parameterised

**Category:** measurement as a separate layer. **Last reviewed:** August 23, 2026.
Pinned at [`0b96e86e`][pango-rev] (Pango) and [`29c1b91d`][hb-rev] (HarfBuzz).

The text stack GTK actually measures with, read on its own so that
[`gtk4-gsk.md`][gtk] can stay about `GskRenderNode`. It is the survey's most
mature witness for **F1** — a measurement layer with its own units, its own
pluggable backends and a hard boundary against drawing — and it is the subject
that prices **F2**'s device-parameterisation decision most sharply, because
Pango's answers are **not** device-independent by default. They are
device-_parameterised_: hinting and resolution are declared inputs to
measurement, carried on `PangoContext`, and the font map is keyed by them.

| Field                | Value                                                                                                                                             |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | C (GObject) for Pango; C++ with a C ABI for HarfBuzz                                                                                              |
| **License**          | Pango `LGPLv2.1+` ([`meson.build`][pango-meson] L3); HarfBuzz the "Old MIT" license ([`COPYING`][hb-copying] L1)                                  |
| **Repository**       | [`GNOME/pango`][pango-repo] (GitHub mirror of `gitlab.gnome.org/GNOME/pango`), [`harfbuzz/harfbuzz`][hb-repo]                                     |
| **Documentation**    | in-tree [`docs/pango_rendering.md`][pipeline]; HarfBuzz's [`docs/usermanual-*.xml`][hb-doc]                                                       |
| **Category**         | measurement as a separate layer                                                                                                                   |
| **Pinned revision**  | Pango `0b96e86efec3706601d7dc02b21c9bf19817c9de` (`version: '1.58.2'`); HarfBuzz `29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000` (`version: '14.3.1'`) |
| **Measurement unit** | Pango units — `PANGO_SCALE` = 1024 per **device unit** ([`pango-types.h`][types] L96)                                                             |
| **Font backends**    | FreeType/Fontconfig, Win32/DirectWrite, CoreText — each a `PangoFontMap` subclass                                                                 |
| **Render backends**  | Cairo, Xft, FreeType-to-buffer, Win32 — each a `PangoRenderer` subclass, none in `libpango` itself                                                |

## Overview

### What it solves

Pango turns a Unicode string plus attributes into positioned glyphs; HarfBuzz
turns one uniform run into positioned glyphs. Neither draws. The in-tree
pipeline document names the stages and puts drawing last, as one stage among
five ([`docs/pango_rendering.md`][pipeline] L16–L40):

> Rendering
> : takes a string of positioned glyphs, and renders them onto a surface.
> This is accomplished by a [class@Pango.Renderer] object.

HarfBuzz states the same boundary as a scope refusal
([`usermanual-what-is-harfbuzz.xml`][hb-doc] L341–L348):

> HarfBuzz will take a Unicode string, shape it, and give you the information
> required to lay it out correctly on a single horizontal (or vertical) line
> using the font provided. That is the extent of HarfBuzz's responsibility.

The same section then disclaims bidi, mixed fonts, line breaking, hyphenation
and justification — every one of which Pango supplies above it. The two
libraries are a worked example of the layering `sparkles:ui` does not have.

### Design philosophy

Two commitments matter here.

**The unit is the caller's, and the library is agnostic about what it means.**
HarfBuzz's `hb_font_set_scale` documentation is unusually blunt
([`hb-font.cc`][hb-font-c] L2712–L2743):

> even what font size 20 means is up to you. It might be 20 pixels, or 20
> points, or 20 millimeters. HarfBuzz does not care about that. […] The choice
> of scale is yours but needs to be consistent between what you set here, and
> what you expect out of `hb_position_t`.

Pango exercises exactly that freedom: `PANGO_SCALE` is documented as "The scale
between dimensions used for Pango distances and device units" whose device unit
"will typically be pixels for a screen, and points for a printer"
([`pango-types.h`][types] L58–L68), and the FreeType font backend sets the
HarfBuzz scale to `pixel_size * PANGO_SCALE * x_scale`
([`pangofc-font.c`][fcfont] L999–L1001) so that `hb_position_t` values drop
straight into `PangoGlyphGeometry.width` without conversion
([`shape.c`][shape] L548).

**Drawing is a bridge, not a dependency.** `libpangocairo` is a _separate_
library, built only `if cairo_dep.found()` ([`pango/meson.build`][pango-lib]
L476), from a source list that `libpango` does not contain; cairo is a meson
`feature` option ([`meson.options`][pango-opts] L48–L51). `PangoCairoRenderer`
is an ordinary `PangoRenderer` subclass ([`pangocairo-render.c`][cairo-render]
L56, L1032–L1041).

## How it works

The seam is a pair of abstract classes plus a plain-data glyph array.

**Measuring.** `PangoFontMap` supplies fonts; the vtable is six operations, all
of them about _finding_ a font, none about drawing one
([`pango-fontmap.h`][fontmap] L72–L99):

```c
struct _PangoFontMapClass
{
  GObjectClass parent_class;
  PangoFont *   (*load_font)     (PangoFontMap *, PangoContext *, const PangoFontDescription *);
  void          (*list_families) (PangoFontMap *, PangoFontFamily ***, int *);
  PangoFontset *(*load_fontset)  (PangoFontMap *, PangoContext *, const PangoFontDescription *, PangoLanguage *);
  const char     *shape_engine_type;
  guint         (*get_serial)    (PangoFontMap *);
  /* … changed, get_family, get_face … */
};
```

`PangoFontClass` is the metrics oracle, and its last two members are the seam
down to HarfBuzz ([`pango-font.h`][font-h] L671–L693):

```c
  void                  (*get_glyph_extents)  (PangoFont *, PangoGlyph,
                                               PangoRectangle *ink_rect,
                                               PangoRectangle *logical_rect);
  PangoFontMetrics *    (*get_metrics)        (PangoFont *, PangoLanguage *);
  void                  (*get_features)       (PangoFont *, hb_feature_t *, guint, guint *);
  hb_font_t *           (*create_hb_font)     (PangoFont *);
```

**Shaping.** `hb_shape` is the whole of HarfBuzz's shaping API
([`hb-shape.h`][hb-shape-h] L43–L47):

```c
HB_EXTERN void
hb_shape (hb_font_t           *font,
	  hb_buffer_t         *buffer,
	  const hb_feature_t  *features,
	  unsigned int         num_features);
```

Pango's call site is one line ([`shape.c`][shape] L512), sandwiched between
buffer setup and a loop that copies `hb_glyph_info_t.codepoint` and
`hb_glyph_position_t.{x_advance,x_offset,y_offset}` into a `PangoGlyphString`
(L525–L555). The result element is three small fields with no dead ones
([`pango-glyph.h`][glyph] L120–L125):

```c
struct _PangoGlyphInfo
{
  PangoGlyph         glyph;
  PangoGlyphGeometry geometry;  /* width, x_offset, y_offset — PangoGlyphUnit */
  PangoGlyphVisAttr  attr;      /* two bits: is_cluster_start, is_color */
};
```

**Drawing.** `PangoRendererClass` is the painter seam, and it is the only place
in Pango that a device appears ([`pango-renderer.h`][renderer-h] L137–L201):
`draw_glyphs`, `draw_rectangle`, `draw_error_underline`, `draw_shape`,
`draw_trapezoid`, `draw_glyph`, `draw_glyph_item`, plus `part_changed`,
`begin`, `end`, `prepare_run`. Every geometric parameter is in Pango units,
not device units.

## Q1 — measurement units, and who answers

**A separate layer, its own unit, and — the finding — the device is a declared
parameter of it.**

The unit is `PangoGlyphUnit`, "1/PANGO_SCALE of a device unit"
([`pango-glyph.h`][glyph] L36–L52), converted at the boundary by
`pango_units_to_double` — literally `(double)i / PANGO_SCALE`
([`pango-utils.c`][utils] L1019–L1022). Extents come back as
`PangoRectangle`, an `int` quad ([`pango-types.h`][types] L169–L175), in two
flavours: **ink** ("the extents of the layout as drawn") and **logical**
("Logical extents are usually what you want for positioning things")
([`pango-layout.c`][layout-c] L3092–L3109). `pango_glyph_string_extents_range`
computes both in one pass and treats them differently on purpose
([`glyphstring.c`][glyphstring] L173–L180): the ink rect unions non-empty glyph
boxes, while the logical rect accumulates `logical_rect->width += geometry->width`
(L241) — advance, not ink. A zero-ink glyph still reserves width.

That two-channel answer is what our `Size measure(scope const(char)[] text)`
cannot express at all. It returns one `Size`, denominated in cells, and
[friction §1][friction] records `SkiaCanvas.measure` ignoring Skia entirely —
returning `cellsOf(text)`, the Unicode width — to produce it.

**Now the complication.** `PangoFont` is obtained from a `PangoFontMap` _given a
`PangoContext`_, and for the cairo font maps the context key **is** the merged
cairo font options — `pango_cairo_fc_font_map_context_key_get` returns
`_pango_cairo_context_get_merged_font_options (context)`
([`pangocairo-fcfontmap.c`][fcfontmap] L137–L141, installed as
`fcfontmap_class->context_key_get` at L194). Those options are merged from the
target surface's options and any explicitly set ones
([`pangocairo-context.c`][cairo-ctx] L105–L122). Hinting then changes the
numbers: `cf_priv->is_hinted` is set from
`cairo_font_options_get_hint_metrics (font_options) != CAIRO_HINT_METRICS_OFF`
([`pangocairo-font.c`][cairo-font] L1089), and where it is true the font extents
are rounded to whole device pixels with `PANGO_UNITS_FLOOR` / `PANGO_UNITS_CEIL`
(L1283–L1292). Glyph extents themselves are asked of a `cairo_scaled_font_t`
built from those same options ([`pangocairo-font.c`][cairo-font] L1315–L1337).

Pango is explicit that this is the axis that matters. The cairo context updater
comments ([`pangocairo-context.c`][cairo-ctx] L146–L150):

```c
  /* layout is matrix-independent if metrics-hinting is off.
   * also ignore matrix translation offsets */
  if ((cairo_font_options_get_hint_metrics (merged_options) != CAIRO_HINT_METRICS_OFF) &&
      (0 != memcmp (&pango_matrix, current_matrix, sizeof (PangoMatrix))))
    changed = TRUE;
```

> [!IMPORTANT]
> Measurement being off the painter does **not** make it device-independent.
> Pango's measurement is device-independent only when metrics hinting is off —
> which is precisely why GSK's `gsk_get_glyph_string_extents` reloads the font
> with `CAIRO_HINT_STYLE_NONE` before measuring, as [`gtk4-gsk.md`][gtk] records.
> GTK had to _opt out_ of Pango's default to make four renderers agree.

So the transferable rule reaches past F1's placement claim and into **F2**: a
measurement layer needs its device parameters (resolution, hinting, transform)
as an **explicit, comparable key**, because they change the answer and because a
multi-backend scene must be able to demand a setting where they do not. Device
parameterisation is one of F2's six decisions, and Pango is the subject that
shows what it costs to leave it implicit. Pango supplies both
halves — `pango_cairo_context_set_resolution` (a scale factor "between points
specified in a `PangoFontDescription` and Cairo units", default 96,
[`pangocairo-context.c`][cairo-ctx] L183–L200) and
`pango_cairo_context_set_font_options`, whose options "override any options
that [func@update_context] derives from the target surface" (L230–L242).

## Q2 — is the contract stated in one place?

**Three different answers in one stack, and one of them is new to this survey.**

- **Pango's painter contract** is the `PangoRendererClass` vtable and nothing
  else. There is no capability query and no feature bitmask. Four of the eleven
  methods carry framework defaults installed in `class_init`
  ([`pango-renderer.c`][renderer-c] L124–L128), so the true required surface is
  small: `draw_trapezoid` plus `draw_glyphs`/`draw_glyph` is enough, because
  the default `draw_rectangle` decomposes a rectangle under an arbitrary matrix
  into one to three trapezoids ([`pango-renderer.c`][renderer-c] L961–L1035).
  This is Qt's model from [F4][comparison] — the lowering lives in the
  framework, once — reached without a `hasFeature` enum.

- **The device is queried at draw time, not declared.** The cairo renderer
  caches `cairo_surface_has_show_text_glyphs (cairo_get_target (cr))`
  ([`pangocairo-render.c`][cairo-render] L1096) and branches on it in
  `draw_glyph_item`: with the capability it emits glyphs plus text clusters (so
  a PDF is selectable), without it it drops the text and shows glyphs only
  (L689–L717). The probe is on the _surface_, mid-frame, and the fallback is
  local to the renderer.

- **HarfBuzz enumerates its implementations by name.**
  `hb_shape_list_shapers()` returns "the list of shapers supported by HarfBuzz"
  ([`hb-shape.cc`][hb-shape-c] L89–L102) and `hb_shape_full` takes a
  `shaper_list` to pin one. Since 11.0.0 the _metrics_ source is equally
  enumerable: `hb_font_list_funcs()` ([`hb-font.cc`][hb-font-c] L2693–L2706)
  and `hb_font_set_funcs_using (font, name)`, whose default "can be changed by
  setting the `HB_FONT_FUNCS` environment variable to the name of the desired
  font-functions" (L2608–L2625).

That third model is a genuine third option beside Qt's feature bits and Slint's
trait defaults: **named, enumerable, swappable implementations**, selectable at
runtime and overridable by environment. It answers "what is available" without
answering "what can this one do", and it makes an A/B comparison between two
implementations of the same seam a two-line change — which is exactly what our
op-stream parity harness wants, and [F12][comparison] is the reason it wants it:
the reified stream earns its keep as the cross-target oracle, not as a golden.

## Q3, Q6 — semantic operations, and where the role lives

Pango's painter seam is **semantic in the role and resolved in the value, and it
does not put both on the same object.**

`PangoRenderPart` is a five-member enum of roles — `FOREGROUND`, `BACKGROUND`,
`UNDERLINE`, `STRIKETHROUGH`, `OVERLINE` ([`pango-renderer.h`][renderer-h]
L53–L60) — and it is a _parameter of every drawing call_: `draw_rectangle
(renderer, part, x, y, w, h)`, `draw_trapezoid (renderer, part, …)`. The
resolved colour is not on the call. It lives in renderer state, set by
`pango_renderer_set_color (renderer, part, color)` and read back with
`pango_renderer_get_color` / `pango_renderer_get_alpha`
([`pango-renderer.h`][renderer-h] L267–L279), and the framework refreshes it per
run through the `prepare_run` vmethod.

> [!NOTE]
> This is a direct answer to [friction §6][friction] that no other surveyed
> subject supplies, and it is one of the cheaper encodings **F9** counts. Each
> `DrawOp` payload stores the resolved fields its primitive paints from, and six
> of the eight store a `Slot` beside them; the seam hedges rather than deciding.
> Pango takes the other route: put the **role on the operation** (one enum
> member, one byte) and the **resolved value in painter state** (set once per
> run). A re-resolving backend reads the part; a pixel backend reads its own
> state. The op pays for the role only, and nothing is duplicated — which is
> F9's asymmetry exactly: resolved appearance follows from a role plus a theme,
> and a role does not follow from resolved appearance.

There is one genuinely semantic operation, and it is ours:
`draw_error_underline` — "draws a squiggly line that approximately covers the
given rectangle in the style of an underline … to indicate a spelling error"
([`pango-renderer.h`][renderer-h] L97–L99). That is `LineStyle.wavy`, named as
an intent rather than as a geometry. Pango also ships the framework fallback:
the default implementation tiles the squiggle out of `draw_rectangle` calls
tagged `PANGO_RENDER_PART_UNDERLINE`, sized in whole `height / HEIGHT_SQUARES`
units ([`pango-renderer.c`][renderer-c] L1149–L1207). A backend that has a real
squiggle overrides; a backend that does not gets a correct one for free.

There is no `scrollbar`, and no widget concept of any kind — but the seam is
_text_, so this neither supports nor undercuts [friction §3][friction]. What it
does show is that eleven vtable methods, four of them defaulted, has been enough
for four render backends over two decades.

## Q4 — command shape

**Pango has no reified command stream; HarfBuzz reifies its input and output as
one mutable value.** `PangoRenderer` dispatches through GObject vmethods, so
there is no stream to encode at all — the same result as Slint and Qt, and it
leaves **F3**'s live trade unadjudicated.

The interesting artefact is one layer down. `PangoGlyphString` is the uniform
counterpart to our `DrawOp`: a `num_glyphs`/`glyphs`/`log_clusters` triple whose
element is three fields, all live for every element
([`pango-glyph.h`][glyph] L140–L148). `DrawOp` is a closed sum over eight
per-kind payloads, so no operation carries a field that belongs to another kind
— but every operation is as wide as the widest payload
([friction §4][friction]), so a `popClip` that carries nothing costs what a text
run costs. The text stack answers the same pressure the other way: the per-item
record is a fixed POD, and the _variation_ is carried by having several
different arrays — `PangoGlyphString`, `PangoGlyphItem`, `PangoLayoutLine`,
`PangoLayout` — each with its own extents call. Specialised containers rather
than one polymorphic record, which is F3's variable-stride camp reached from the
measurement side.

`hb_buffer_t` is the other half: it goes into `hb_shape` holding Unicode and
comes out holding glyphs, with `hb_buffer_get_content_type` distinguishing the
two states ([`hb-buffer.cc`][hb-buffer] L1879). One value, two phases,
caller-owned.

## Q5 — sub-unit placement

Pango's coordinates are continuous — 1/1024 of a device unit — which is the
setting in which one might expect the sub-unit problem to disappear. **It
arises anyway, and Pango's answer is a policy function, not a position.**

`pango_quantize_line_geometry (int *thickness, int *position)` "Quantizes the
thickness and position of a line to whole device pixels … The purpose of this
function is to avoid such lines looking blurry", and — the load-bearing
sentence — "Care is taken to make sure @thickness is at least one pixel when
this function returns" ([`pango-utils.c`][utils] L949–L985). The body rounds
thickness to whole pixels, clamps zero to one, and then recentres the line
differently for odd and even pixel thicknesses.

Two details make this the sharpest **F6** datum in the survey. First, the function
is _public API in the units layer_, `pango-utils.c`, not in a renderer: the
hairline-minimum policy is stated where the measurement is, so every backend
that opts in agrees. Second, it is not applied by default — the only in-tree
callers are in `pangocairo-win32font.c` (L148, L150), the backend whose platform
hints. The policy is available, named, and _elective per device_.

> [!WARNING]
> This is **F6** at its sharpest. Continuous coordinates do not dissolve the
> hairline problem for Pango any more than they do for GTK
> ([`gtk4-gsk.md`][gtk] records 4.24 adding a per-edge `GskSnapDirection`).
> Both subjects converge on the shape F6 names: **a named fidelity, applied per
> device against a queried device unit, with a guaranteed one-pixel floor.**
> That describes the destination for `RuleEdge` better than either "more
> enumerators" or "go continuous".

## Q7 — payload ownership

**Nobody borrows.** Three copies, at three levels:

- `pango_layout_set_text` `g_strndup`s the caller's bytes
  ([`pango-layout.c`][layout-c] L1242, L1249).
- `PangoGlyphString` is documented "The storage for the glyph information is
  owned by the structure which simplifies memory management"
  ([`pango-glyph.h`][glyph] L137).
- `hb_buffer_add_utf8` appends codepoints into the buffer's own storage; the
  caller's `text` is not retained ([`hb-buffer.cc`][hb-buffer] L1882–L1899).

Everything above that is refcounted GObject or HarfBuzz `hb_object_t`
(`hb_font_reference` / `hb_font_destroy`), and `hb_font_funcs_make_immutable` /
`hb_font_funcs_is_immutable` ([`hb-font.h`][hb-font-h] L86–L89) let a shared
vtable be frozen and then shared without locking.

**F8 is confirmed a third time**, and the dissenting case is ours:
`DrawOp.text` is a `const(char)[]` borrowed from a frame arena, valid while the
buffer that built it is alive and unreset ([friction §7][friction]). No subject
surveyed borrows across a frame, and the text stack — the layer with the most
performance pressure to do it — copies at every one of three boundaries.
`CmdBuffer.textRun` copies into the arena as well, which is what makes a `scope`
source safe; what F8's stronger form buys and an arena borrow does not is an
operation that can cross a thread.

## Q8 — extent query

**Answered, at four nested levels, all in the measurement layer.**
`pango_glyph_string_extents` (a run), `pango_layout_line_get_extents` (a line),
`pango_layout_get_extents` (the block), and the convenience
`pango_layout_get_size` ([`pango-layout.h`][layout-h] L475, L483;
[`pango-layout.c`][layout-c] L3111, L3159). Each returns both channels,
in Pango units; each has a `_pixel_` twin that rounds outward so "the rounded
rectangles fully contain the unrounded one"
([`pango-layout.c`][layout-c] L3126–L3134).

This is **F7**'s split answered from a fourth place. GSK maintains `bounds` on
the _scene node_ and thereby makes the display list self-describing; Pango
maintains extents on the _text object_, upstream of any display list. Neither
leaves the question to the surface, and both sit on the
maintained-at-construction side of the axis F7 names. Our `skia-canvas-render.d` derives an extent by
scanning every operation's rect ([friction §8][friction]) precisely because
nothing reports one: `CmdBuffer` exposes `length` and `measure`, and a caller
that wants painted bounds folds `op.rect` itself.

## Strengths

- **The unit is declared once, in one macro, with a documented meaning**
  (`PANGO_SCALE` = 1024 device units) and converted only at the boundary. Two
  channels — ink and logical — so "how wide" and "how much ink" never collapse
  into one number.
- **Device parameters are an explicit, comparable key.** `cairo_font_options_t`
  is the font map's context key, so two devices with different hinting get
  different `PangoFont` objects rather than one object silently answering
  differently.
- **Role on the op, value in painter state.** `PangoRenderPart` costs one enum
  member per call and removes the need for any op to carry a resolved colour.
- **Framework-level degradation with no capability enum.** Defaulted vmethods
  reduce the true required surface to a handful; `draw_rectangle`→trapezoids and
  the tiled error underline are the fallbacks written once.
- **Enumerable named implementations** (`hb_shape_list_shapers`,
  `hb_font_list_funcs`, `HB_FONT_FUNCS`) make swapping a metrics source a
  runtime decision.
- **Shaping is a pure-looking function** over `(font, buffer, features)` with no
  device, no surface and no allocation policy in the signature.

## Weaknesses

- **Device-parameterised measurement is a footgun for multi-backend scenes.**
  Nothing in Pango's API says "give me the answer no rasterizer can perturb";
  GTK had to build that itself.
- **`PangoRenderer` state is implicit and stateful** — colours, alpha, matrix,
  underline and strikethrough live on the renderer across calls, and
  `activate`/`deactivate` bracket a session. That is unrecordable as a stream of
  values without also capturing state transitions.
- **The hairline policy is opt-in and under-used.**
  `pango_quantize_line_geometry` is public and correct, and only one backend
  calls it — so the same underline is crisp on Win32 and blurry elsewhere.
- **Two-library layering costs a translation.** `shape.c` copies HarfBuzz output
  glyph-by-glyph into `PangoGlyphInfo` ([`shape.c`][shape] L525–L555), with a
  sign flip on `y_offset` and a rotation for vertical gravity — small, but a
  place where the two unit conventions must be kept in agreement by hand.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                 | Trade-off                                                                                                             |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Measurement in fixed-point `1/PANGO_SCALE` device units, not floats    | Integer positions are exactly comparable and hashable; matches HarfBuzz's `hb_position_t` | Every boundary needs an explicit `pango_units_to_double`; the scale is a documented constant a caller must not assume |
| Two extent channels, ink and logical                                   | Positioning needs advance; damage and selection need ink                                  | Every extents call has two out-parameters, and callers routinely pass the wrong one                                   |
| The device is a parameter of measurement (`PangoContext` font options) | Hinted metrics match hinted rasterization, so text does not shimmer at small sizes        | Two backends measuring the same string legitimately disagree; agreement must be engineered                            |
| `PangoRenderPart` on the call, resolved colour in renderer state       | The role survives to a backend that needs it, without every call carrying a colour        | The painter is stateful, so a call is not self-contained and a recorded stream must capture state                     |
| Defaulted vmethods instead of a capability enum                        | A minimal backend is `draw_trapezoid` + `draw_glyphs`; fallbacks are written once         | No way to _ask_ what a backend supports, and no way to refuse a degrade                                               |
| HarfBuzz is unit-agnostic; the caller sets the scale                   | One shaper serves pixels, points, millimetres and unscaled font units                     | The caller owns a consistency invariant the library cannot check                                                      |
| Named, enumerable shapers and font-funcs                               | Runtime A/B between implementations; env-var override for debugging                       | Names are a weaker contract than types; a missing name fails at runtime                                               |
| Copy at every payload boundary (text, glyphs, buffer)                  | Every object is self-sufficient and outlives its producer                                 | Three copies of the same string exist during one layout                                                               |

## Bearing on the proposal

1. **Split `measure` off `isCanvas`, and make the device parameters an explicit
   input to what replaces it** ([friction §1][friction], **F1**, **F2**).
   Pango's `PangoContext` is the model: resolution and hinting are set on a
   context, the font map is _keyed_ by them, and two devices therefore get two
   fonts rather than one font giving two answers. F1 settles the placement; F2
   names the five decisions placement leaves open, and this is the subject that
   prices device parameterisation: the parameters have to be a declared,
   comparable part of the query.

2. **Provide a way to demand rasterizer-independent metrics.** GTK had to reach
   past Pango's default to get four renderers to agree ([`gtk4-gsk.md`][gtk]);
   our `RecordingCanvas` parity harness has the same requirement, and **F12**
   says why it matters — the op stream is the cross-target parity oracle, which
   it cannot be if two backends legitimately measure the same string
   differently. A metrics API with an explicit "unhinted" mode costs one flag
   and removes a class of golden-test drift.

3. **Return two channels, not one.** Whatever replaces `Size measure(…)` should
   answer advance and ink separately, as `PangoRectangle` ink/logical does. The
   convention that a `TextRun`'s `rect.width` is its advance in cells is the
   one-channel answer, and [friction §8][friction] records `skia-canvas-render.d`
   relying on the coincidence that the advance happens to bound the ink too.
   That is F2's return-shape decision, taken by default rather than made.

4. **Move the resolved colour off the op and put the role on it**
   ([friction §6][friction], **F9**). `PangoRenderPart` +
   `pango_renderer_set_color(part, colour)` is one of the cheaper encodings F9
   counts: cheaper than storing an `Ink` on each of the four content payloads
   and a `Slot` on six of the eight, which is the arrangement that makes
   `DrawOp.visual` a reconstruction rather than a decision. The cost is a
   stateful painter, which our reified-stream requirement (**F3**, **F12**)
   makes non-free — so this is a trade to evaluate, not to adopt blindly.

5. **Replace `RuleEdge` with a named snapping policy that guarantees one device
   pixel** ([friction §5][friction], **F6**). Pango is a continuous coordinate
   system that still needs `pango_quantize_line_geometry`, whose contract is "at
   least one pixel".
   Together with GTK 4.24's `GskSnapDirection`, that is two independent subjects
   agreeing that continuity does not dissolve the hairline problem. Keep the
   per-edge intent; add the policy; state the floor.

6. **Settle the retain boundary for `DrawOp.text`** ([friction §7][friction],
   **F8 confirmed**). The copy is already there — `CmdBuffer.textRun` interns
   into the frame arena — so the open question is the retain: an operation valid
   only while its buffer is alive and unreset cannot cross a thread or outlive
   the frame, which is what `UI-O4` asks. Three separate boundaries in the most
   allocation-sensitive layer of the stack all copy, and each hands back a value
   that outlives its producer.

7. **Answer extent where it is maintained, rather than scanning for it**
   ([friction §8][friction], **F7**). Pango answers extent at run, line and
   block level, all upstream of any painter and all maintained at construction;
   GSK's node `bounds` is the same answer taken one layer down. F7's three
   questions — surface, layout, ink — are exactly the ones a layout-side query
   can keep apart and a rect scan cannot.

8. **Consider named, enumerable backends for the metrics seam** (**F5**).
   HarfBuzz's `hb_font_list_funcs` / `HB_FONT_FUNCS` is a third capability model
   beside Qt's feature bits and Slint's trait defaults, and it is the one that
   most directly serves a parity harness: run the same op stream against two
   named metrics sources and diff.

## Sources

- **Pango**, pinned at [`0b96e86e`][pango-rev] (`version: '1.58.2'`,
  [`meson.build`][pango-meson] L2). Units and geometry:
  [`pango-types.h`][types], [`pango-glyph.h`][glyph], [`pango-utils.c`][utils].
  Measurement: [`glyphstring.c`][glyphstring], [`pango-layout.c`][layout-c],
  [`pango-layout.h`][layout-h]. Seams: [`pango-font.h`][font-h],
  [`pango-fontmap.h`][fontmap], [`pango-renderer.h`][renderer-h],
  [`pango-renderer.c`][renderer-c]. Shaping bridge: [`shape.c`][shape],
  [`pangofc-font.c`][fcfont]. Device parameterisation:
  [`pangocairo-context.c`][cairo-ctx], [`pangocairo-font.c`][cairo-font],
  [`pangocairo-fcfontmap.c`][fcfontmap], [`pangocairo-render.c`][cairo-render].
  Build layering: [`pango/meson.build`][pango-lib], [`meson.options`][pango-opts].
  Prose: [`docs/pango_rendering.md`][pipeline].
- **HarfBuzz**, pinned at [`29c1b91d`][hb-rev] (`version: '14.3.1'`,
  [`meson.build`][hb-meson] L3): [`hb-shape.h`][hb-shape-h],
  [`hb-shape.cc`][hb-shape-c], [`hb-font.h`][hb-font-h],
  [`hb-font.cc`][hb-font-c], [`hb-font.hh`][hb-font-hh],
  [`hb-buffer.cc`][hb-buffer], [`COPYING`][hb-copying],
  [`docs/usermanual-what-is-harfbuzz.xml`][hb-doc].
- **In-tree:** [`canvas.d`][canvas], [`canvas-seam-friction.md`][friction],
  [`comparison.md`][comparison], [`gtk4-gsk.md`][gtk], [`slint.md`][slint],
  [the umbrella][index].

<!-- References -->

[pango-rev]: https://github.com/GNOME/pango/tree/0b96e86efec3706601d7dc02b21c9bf19817c9de
[pango-repo]: https://github.com/GNOME/pango
[pango-meson]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/meson.build
[pango-opts]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/meson.options
[pango-lib]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/meson.build
[pipeline]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/docs/pango_rendering.md
[types]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-types.h
[glyph]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-glyph.h
[utils]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-utils.c
[glyphstring]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/glyphstring.c
[layout-c]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-layout.c
[layout-h]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-layout.h
[renderer-h]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-renderer.h
[renderer-c]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-renderer.c
[font-h]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-font.h
[fontmap]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-fontmap.h
[shape]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/shape.c
[fcfont]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pangofc-font.c
[cairo-ctx]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pangocairo-context.c
[cairo-font]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pangocairo-font.c
[fcfontmap]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pangocairo-fcfontmap.c
[cairo-render]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pangocairo-render.c
[hb-rev]: https://github.com/harfbuzz/harfbuzz/tree/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000
[hb-repo]: https://github.com/harfbuzz/harfbuzz
[hb-meson]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/meson.build
[hb-copying]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/COPYING
[hb-doc]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/docs/usermanual-what-is-harfbuzz.xml
[hb-shape-h]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-shape.h
[hb-shape-c]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-shape.cc
[hb-font-h]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-font.h
[hb-font-c]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-font.cc
[hb-font-hh]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-font.hh
[hb-buffer]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-buffer.cc
[index]: ./index.md
[comparison]: ./comparison.md
[gtk]: ./gtk4-gsk.md
[slint]: ./slint.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
