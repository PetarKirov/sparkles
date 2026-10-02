# HarfBuzz (C / C++ core)

The reference OpenType shaper: a three-object ladder `hb_blob_t` → `hb_face_t` →
`hb_font_t` whose immutable layers are shared across threads, a reusable
`hb_buffer_t` that carries codepoints in and positioned glyphs out, and a
callback-sink model (`hb_font_funcs_t`, `hb_draw_funcs_t`, `hb_paint_funcs_t`)
for everything the shaper needs from, or hands back to, the font.

| Field            | Value                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------- |
| Language         | C++ (C ABI; `src/hb-*.h` public headers, `.cc`/`.hh` implementation)                              |
| License          | "Old MIT" ([`COPYING`][copying])                                                                  |
| Repository       | [`harfbuzz/harfbuzz`][repo]                                                                       |
| Documentation    | DocBook user manual under [`docs/`][manual-object-model]; gtk-doc comments in every public header |
| Version at pin   | 14.5.1 ([`src/hb-version.h`][version])                                                            |
| Category         | C core · shaper                                                                                   |
| Layer(s) covered | parse · shape · outline · (raster only via `hb-ft` / `hb_paint` sinks) · metrics                  |
| Pinned revision  | `f20f4c20bcb715eeb7974854b0689688975fdeee` (2026-10-01)                                           |

## Overview

### What it solves

HarfBuzz turns a run of Unicode codepoints plus a font into positioned glyph
ids. It owns the OpenType `GSUB`/`GPOS`/`GDEF` machinery, the script-specific
shapers (Arabic, Indic, USE, Hangul, …), and the normalization and cluster
bookkeeping around them. It does **not** rasterize, does not pick fonts, and
does not break lines. The main shaper is `ot`; the compiled-in list at the pin
also names `graphite2`, `uniscribe`, `directwrite`, `coretext`, `wasm`,
`harfrust`, `kbts` and a last-resort `fallback`
([`src/hb-shaper-list.hh`][shaper-list]).

### Design philosophy

Scale is the caller's convention, not the library's. The doc comment on the one
function that sets it is the clearest statement of HarfBuzz's unit model:

```c
 * The font scale is a number related to, but not the same as,
 * font size. Typically the client establishes a scale factor
 * to be used between the two. For example, 64, or 256, which
 * would be the fractional-precision part of the font scale.
 * This is necessary because #hb_position_t values are integer
 * types and you need to leave room for fractional values
 * in there.
 ...
 * The choice of scale is yours but needs to be consistent between
 * what you set here, and what you expect out of #hb_position_t
 * as well has draw / paint API output values.
 *
 * Fonts default to a scale equal to the UPEM value of their face.
 * A font with this setting is sometimes called an "unscaled" font.
```

— [`src/hb-font.cc`][font-cc], `hb_font_set_scale`

The object-model chapter adds the second principle: pass-by-value structs are
reserved for the few efficiency-critical records (`hb_glyph_info_t`,
`hb_glyph_position_t`) and padded with reserved members; everything else is an
opaque refcounted object with `create`/`reference`/`destroy`, and "many object
types can be marked as read-only or immutable, facilitating their use in
multi-threaded environments" ([`usermanual-object-model.xml`][manual-object-model]).

## How it works

The ladder has three rungs and one workspace.

- **`hb_blob_t`** wraps bytes with an `hb_memory_mode_t`
  (`HB_MEMORY_MODE_DUPLICATE`, `READONLY`, `WRITABLE`,
  `READONLY_MAY_MAKE_WRITABLE`) and a destroy callback, so a `malloc`ed buffer
  or an `mmap` is handed over once and freed when the last reference drops
  ([`src/hb-blob.h`][blob-h]). `hb_blob_create_sub_blob` borrows a range of a
  parent blob — the mechanism by which per-table blobs alias the file.
- **`hb_face_t`** is the unsized typeface. `hb_face_create (blob, index)`
  sanitizes the blob as an `OT::OpenTypeFontFile`, then builds the face via the
  general constructor `hb_face_create_for_tables (reference_table_func, …)`
  ([`src/hb-face.cc`][face-cc]) — i.e. a face is fundamentally _a function from
  tag to blob_, and a file-backed face is just one implementation of it. Tables
  are parsed lazily through `hb_ot_face_t table` ([`src/hb-face.hh`][face-hh]),
  one lazy loader per entry in [`src/hb-ot-face-table-list.hh`][table-list].
- **`hb_font_t`** is a face plus scale, ppem, ptem, synthetic bold/slant,
  variation coordinates and an `hb_font_funcs_t` vtable. Fonts form a parent
  chain (`hb_font_create_sub_font`) so a missing func falls through to the
  parent ([`src/hb-font.h`][font-h]).
- **`hb_buffer_t`** holds `hb_glyph_info_t { codepoint, mask, cluster, var1, var2 }`
  before and after shaping, and `hb_glyph_position_t { x_advance, y_advance,
x_offset, y_offset, var }` after ([`src/hb-buffer.h`][buffer-h]). The same
  `codepoint` field means Unicode before `hb_shape` and glyph id after;
  `hb_buffer_get_content_type` says which.

`hb_shape (font, buffer, features, num_features)` is the whole public entry;
`hb_shape_full` adds a shaper list, and `hb_shape_plan_t` exposes the cached
per-(face, props, features) plan that `hb_shape` builds internally
([`src/hb-shape.h`][shape-h], [`src/hb-shape-plan.h`][plan-h]).

## Analysis spine

### 1. Layering and ownership

| Layer        | Type              | Owns                                                                              | Mutability                                                                                |
| ------------ | ----------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| bytes        | `hb_blob_t`       | data pointer + destroy callback; mode decides copy-vs-borrow                      | `hb_blob_make_immutable`                                                                  |
| typeface     | `hb_face_t`       | a `reference_table` closure, `index`, `upem`, `glyph_count`, lazily parsed tables | `hb_face_make_immutable`; effectively immutable after setup                               |
| scaled font  | `hb_font_t`       | scale, ppem/ptem, slant/bold, var coords, `hb_font_funcs_t`, parent               | `hb_font_make_immutable`; `hb_font_get_serial` / `hb_font_changed` for cache invalidation |
| shaper state | `hb_shape_plan_t` | compiled lookups for one `(face, segment props, features)`                        | immutable, cached per face                                                                |
| workspace    | `hb_buffer_t`     | the glyph arrays; `hb_buffer_pre_allocate`                                        | mutable, single-owner, reusable via `hb_buffer_reset`/`clear_contents`                    |

Every object is refcounted; the manual states the thread model precisely:
"All of HarfBuzz's object-lifecycle-management APIs are thread-safe (unless you
compiled HarfBuzz from source with the `HB_NO_MT` configuration flag), even when
the object as a whole is not thread-safe", and the pattern is `create`, a few
`set_*`, then `make_immutable` and share
([`usermanual-object-model.xml`][manual-object-model]). The `hb-ft` header is
blunter about its exception: "Note: FreeType is not thread-safe. Hence, these
functions are not either." ([`src/hb-ft.h`][ft-h]), and `hb_ft_font_lock_face` /
`hb_ft_font_unlock_face` expose the mutex that guards the shared `FT_Face`
([`src/hb-ft.cc`][ft-cc]).

Error model: no error codes. Setters on an immutable object are silently
ignored (`if (hb_object_is_immutable (font)) return;` in
[`src/hb-font.cc`][font-cc]); allocation failure yields the singleton
`*_get_empty ()` object, which answers every query with nothing; newer entry
points carry an `_or_fail` suffix and return `NULL` (`hb_face_create_or_fail`,
`hb_blob_create_from_file_or_fail`, `hb_subset_or_fail`,
`hb_font_draw_glyph_or_fail`).

### 2. Face loading and table access

From bytes: `hb_blob_create` → `hb_face_create (blob, index)`. From a path:
`hb_face_create_from_file_or_fail (file_name, index)`. Collections:
`hb_face_count (blob)` reports the face count, `index` selects
([`src/hb-face.h`][face-h]). Loading is lazy at both levels: the blob is only
sanitized as a container at creation, and each table is parsed on first use.

Raw tables are a first-class citizen: `hb_face_reference_table (face, tag)`
returns a sub-blob of the file (or whatever the closure produces), and
`hb_face_get_table_tags` enumerates them. The inverse exists too:
`hb_face_builder_create` / `hb_face_builder_add_table` assemble a face from
blobs, which is how `hb_subset_or_fail` returns its result
([`src/hb-subset.h`][subset-h]). At the pin HarfBuzz also has pluggable face
_loaders_ (`hb_face_list_loaders`: `ot`, `ft`, `coretext`, `directwrite`) so a
format the native parser rejects can be opened through a platform stack
([`src/hb-face.cc`][face-cc]).

Coverage without shaping: `hb_face_collect_unicodes`,
`hb_face_collect_nominal_glyph_mapping`, `hb_face_collect_variation_selectors`
fill an `hb_set_t` / `hb_map_t` — exactly the "which codepoints does this font
cover" query a fallback engine or an inspector needs ([`src/hb-face.h`][face-h]).

What it refuses: a container that fails sanitization becomes an empty face,
with no diagnostic.

### 3. Shaping

Input is appended with `hb_buffer_add_utf8` / `_utf16` / `_utf32` /
`_codepoints` / `_latin1`, each taking `(text, text_length, item_offset,
item_length)` so that pre- and post-context stay visible to the shaper while
only the item is shaped; invalid UTF-8 becomes the buffer's replacement
codepoint ([`src/hb-buffer.cc`][buffer-cc]). Segment properties are
`hb_direction_t`, `hb_script_t`, `hb_language_t`, set explicitly or guessed by
`hb_buffer_guess_segment_properties` ([`src/hb-buffer.h`][buffer-h]).

Features are `hb_feature_t { tag, value, start, end }` — value `0` turns a
feature off, a range scopes it, and later entries win on overlap
([`src/hb-common.h`][common-h], [`src/hb-shape.cc`][shape-cc]).

Cluster→codepoint mapping is the `cluster` field, whose granularity is chosen
by `hb_buffer_set_cluster_level`: `MONOTONE_GRAPHEMES` (default),
`MONOTONE_CHARACTERS`, `CHARACTERS`, `GRAPHEMES`. The manual is explicit that
HarfBuzz tracks _clusters, not graphemes_
([`usermanual-clusters.xml`][manual-clusters]). Per-glyph flags
`HB_GLYPH_FLAG_UNSAFE_TO_BREAK`, `UNSAFE_TO_CONCAT`, `SAFE_TO_INSERT_TATWEEL`
tell a line breaker where re-shaping is required
([`src/hb-buffer.h`][buffer-h]).

Output units are `hb_position_t`, a plain `int32_t`
([`src/hb-common.h`][common-h]), in whatever scale the font was given — by
default font units (scale = upem).

### 4. Variation and instances

Axes live on the face: `hb_ot_var_get_axis_infos` fills
`hb_ot_var_axis_info_t { axis_index, tag, name_id, flags, min_value,
default_value, max_value }`; named instances via
`hb_ot_var_get_named_instance_count`, `_get_subfamily_name_id`,
`_get_postscript_name_id`, `_get_design_coords` ([`src/hb-ot-var.h`][var-h]).
Normalization is exposed standalone: `hb_ot_var_normalize_coords` produces
2.14 fixed-point values with `avar` applied
([`src/hb-ot-var.cc`][var-cc]).

Coordinates are set on the _font_, three ways: `hb_font_set_variations`
(tag/value pairs; missing axes default from `fvar`, or from the font's named
instance if `hb_font_set_var_named_instance` was called),
`hb_font_set_var_coords_design` (floats, by axis index) and
`hb_font_set_var_coords_normalized`. The implementation always keeps both the
design and normalized arrays ([`src/hb-font.cc`][font-cc]). From there they
reach shaping (`GSUB`/`GPOS` `FeatureVariations`, `HVAR`/`VVAR` advances,
`MVAR` metrics via `hb_ot_metrics_get_variation`) and the outline sinks
(`gvar`, `CFF2`) without any further plumbing. With `hb-ft`,
`hb_ft_hb_font_changed` pushes the same coordinates into the `FT_Face`
([`src/hb-ft.h`][ft-h]). Subsetting can pin or restrict axes
(`hb_subset_input_pin_axis_location`, `hb_subset_input_set_axis_range`).

### 5. Rasterization and outlines

HarfBuzz has no rasterizer. Outlines come out as callbacks:
`hb_font_draw_glyph_or_fail (font, glyph, dfuncs, draw_data)` drives
`move_to` / `line_to` / `quadratic_to` / `cubic_to` / `close_path` on an
`hb_draw_funcs_t`, with an `hb_draw_state_t { path_open, path_start_x/y,
current_x/y }` passed to each; quadratics are synthesized into cubics if the
sink does not set a quadratic func ([`src/hb-draw.h`][draw-h]). Coordinates
are floats in the font's scale (so, by default, font units). The sink can set a
_budget_ (`hb_draw_set_budget`) to bound pathological outlines.

Color is a second sink. `hb_font_paint_glyph (font, glyph, pfuncs, paint_data,
palette_index, foreground)` emits `push_transform`, `push_clip_glyph`,
`push_clip_rectangle`, `color`, `image`, `linear/radial/sweep_gradient`,
`push_group`/`pop_group` with a `hb_paint_composite_mode_t`
([`src/hb-paint.h`][paint-h]) — the full `COLRv1` paint graph, `COLRv0` layers,
`sbix`/`CBDT` via `image`, and `SVG` documents via `image` with the SVG tag.
Table-level queries (`hb_ot_color_has_paint`, `_has_layers`, `_has_svg`,
`_has_png`, palettes) sit in [`src/hb-ot-color.h`][color-h].

Native `hb-ot` font funcs (default) read `glyf`/`CFF`/`CFF2`/`COLR` directly;
`hb_ft_font_set_funcs` swaps in FreeType-backed, hinted advances and outlines
(`hb_ft_font_set_load_flags`) ([`src/hb-ot-font.h`][ot-font-h],
[`src/hb-ft.cc`][ft-cc]). No atlas, gamma or LCD: those belong to the consumer.

### 6. Metrics and measurement

`hb_font_get_h_extents` fills `hb_font_extents_t { ascender, descender,
line_gap }` in font scale ([`src/hb-font.h`][font-h]). Under `hb-ot` the
selection rule is: `OS/2` `sTypo*` when `fsSelection` bit 7
(`USE_TYPO_METRICS`) is set, else `hhea`; `usWinAscent`/`usWinDescent` are
separately reachable as `HB_OT_METRICS_TAG_HORIZONTAL_CLIPPING_ASCENT/DESCENT`
([`src/hb-ot-metrics.cc`][metrics-cc], [`src/hb-ot-metrics.h`][metrics-h]).
`hb_ot_metrics_get_position` also answers `x_height`, `cap_height`, sub/superscript,
strikeout, underline (from `OS/2`/`post`), and
`hb_ot_metrics_get_position_with_fallback` synthesizes missing ones.
Per-glyph: `hb_font_get_glyph_h_advance`, `_h_advances` (batched, stride-based),
`hb_font_get_glyph_extents` → `hb_glyph_extents_t { x_bearing, y_bearing,
width, height }` where height is negative for an upright glyph
([`src/hb-font.h`][font-h]). Baselines per script come from `BASE` via
`hb_ot_layout_get_baseline` ([`src/hb-ot-layout.h`][layout-h]).

### 7. Discovery, matching and fallback

**Absent, by design.** HarfBuzz enumerates nothing on the system and never
chooses a face; the caller must bring a `blob`. The only discovery-adjacent
surfaces are coverage (`hb_face_collect_unicodes`, §2) and the `name` table
(`hb_ot_name_list_names`, `hb_ot_name_get_utf8` in
[`src/hb-ot-name.h`][name-h]) so an outer layer can build its own index. The
inspector surface, by contrast, is rich: `hb_ot_layout_table_get_script_tags`,
`_script_get_language_tags`, `_table_get_feature_tags`,
`_language_get_feature_tags`, `hb_ot_layout_feature_get_name_ids` (for
`ss01`-style UI names and `cv01` characters), `hb_ot_layout_get_size_params`
(`size` feature) ([`src/hb-ot-layout.h`][layout-h]) — everything a font
explorer shows under "features", "scripts", "axes", "instances", "palettes".

## What it teaches `sparkles:font`

- **Make the face a `tag → bytes` function, not a struct of parsed tables.**
  `hb_face_create_for_tables` is the constructor; file-backed faces are one
  implementation. A D `Face` over a borrowed buffer plus a lazy per-table
  cache maps onto this directly, and makes subsetting/synthetic faces free.
- **Separate the unsized face from the sized font, and put variation coords
  on the font.** Shaper, metrics and outline sinks then read one place; the
  face stays shareable and immutable.
- **Integer positions with caller-chosen fixed point.** Default scale = upem
  means "unscaled" shaping is loss-free; a terminal can shape once at upem and
  scale per cell size. Draw/paint output must use the _same_ scale.
- **Callback sinks for outlines and paint, with a budget.** `hb_draw_funcs_t`
  with quadratic→cubic synthesis is the lowest-common-denominator outline API;
  the D equivalent is a DbI sink that declares which segment kinds it accepts.
- **Expose cluster level and the unsafe-to-break flags.** `hue` and a terminal
  both need them to re-shape only the damaged span.
- **Immutable-after-setup plus silent-ignore setters is a trap for D.** Prefer
  `const`-typed shared faces and `Expected` errors to `*_get_empty()` sentinels.

## Strengths

- One entry point (`hb_shape`) over a complete, continuously fuzzed OpenType
  implementation; script shapers are internal, not caller-visible.
- The face/font split and immutability give a sound sharing model: faces and
  immutable fonts across threads, one buffer per thread.
- Draw and paint sinks make HarfBuzz a complete outline + color source without
  FreeType, including `COLRv1` gradients and compositing.
- Exhaustive introspection API (`hb-ot-layout`, `hb-ot-var`, `hb-ot-color`,
  `hb-ot-name`, `hb-ot-metrics`) covers RQ5 almost alone.

## Weaknesses

- No diagnostics: a corrupt font is an empty face, a rejected setter is a
  no-op, a failed allocation is a singleton — nothing a caller can log.
- Scale is a convention; mixing a 26.6-scaled font with upem-scaled extents is
  an easy silent bug.
- No hinting path except through `hb-ft`, which imports FreeType's
  non-thread-safety and a lock/unlock protocol.
- No discovery or fallback at all; a terminal needs another library (or
  `sparkles:font` itself) for RQ4.
- The `hb_font_funcs_t` vtable has ~20 slots and two generations of names
  (`draw_glyph` vs `draw_glyph_or_fail`), a cost of two decades of ABI
  stability.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                  | Trade-off                                                           |
| -------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Opaque refcounted objects, few value structs       | Indefinite ABI stability; reserved fields in the value structs             | Setter/getter boilerplate; `var1`/`var2` scratch exposed to callers |
| Face = `reference_table` closure                   | File, platform and synthetic faces share one type; subset output is a face | Every table read is an indirect call plus lazy-init check           |
| Scale on the font, `hb_position_t` is `int32_t`    | Deterministic integer shaping; caller picks the fixed point                | Unit mismatches are undetectable by the type system                 |
| Variation coords stored both design and normalized | Shaper needs normalized; API and inspectors need design                    | Two arrays per font, `avar` applied at set time                     |
| Outline and paint as callback sinks                | No path type to standardize; sink chooses segment kinds; budget protects   | Not iterable; the consumer must build its own path object           |
| Immutable-after-setup, silent-ignore setters       | Lock-free sharing of faces/fonts                                           | Programming errors vanish; no error channel                         |
| `hb-ot` native funcs default, `hb-ft` optional     | Thread-safe, dependency-free shaping                                       | Hinted advances only via FreeType                                   |
| No font discovery                                  | Scope discipline; fontconfig/CoreText/DirectWrite do it                    | Every consumer re-implements fallback glue                          |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Object ladder** — [`hb-blob.h`][blob-h], [`hb-face.h`][face-h],
  [`hb-face.cc`][face-cc], [`hb-face.hh`][face-hh],
  [`hb-ot-face-table-list.hh`][table-list], [`hb-font.h`][font-h],
  [`hb-font.cc`][font-cc].
- **Shaping** — [`hb-buffer.h`][buffer-h], [`hb-buffer.cc`][buffer-cc],
  [`hb-shape.h`][shape-h], [`hb-shape.cc`][shape-cc],
  [`hb-shape-plan.h`][plan-h], [`hb-shaper-list.hh`][shaper-list],
  [`hb-common.h`][common-h].
- **Introspection** — [`hb-ot-var.h`][var-h], [`hb-ot-var.cc`][var-cc],
  [`hb-ot-metrics.h`][metrics-h], [`hb-ot-metrics.cc`][metrics-cc],
  [`hb-ot-color.h`][color-h], [`hb-ot-layout.h`][layout-h],
  [`hb-ot-name.h`][name-h].
- **Sinks and backends** — [`hb-draw.h`][draw-h], [`hb-paint.h`][paint-h],
  [`hb-ot-font.h`][ot-font-h], [`hb-ft.h`][ft-h], [`hb-ft.cc`][ft-cc],
  [`hb-subset.h`][subset-h].
- **Manual** — [`usermanual-object-model.xml`][manual-object-model],
  [`usermanual-clusters.xml`][manual-clusters],
  [`usermanual-fonts-and-faces.xml`][manual-fonts].
- Siblings: [`./freetype.md`](./freetype.md), [`./fontconfig.md`](./fontconfig.md),
  [`./pango.md`](./pango.md).

<!-- References -->

[repo]: https://github.com/harfbuzz/harfbuzz
[copying]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/COPYING
[version]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-version.h
[blob-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-blob.h
[face-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-face.h
[face-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-face.cc
[face-hh]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-face.hh
[table-list]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-face-table-list.hh
[font-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-font.h
[font-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-font.cc
[buffer-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-buffer.h
[buffer-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-buffer.cc
[shape-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-shape.h
[shape-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-shape.cc
[plan-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-shape-plan.h
[shaper-list]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-shaper-list.hh
[common-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-common.h
[var-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-var.h
[var-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-var.cc
[metrics-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-metrics.h
[metrics-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-metrics.cc
[color-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-color.h
[layout-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-layout.h
[name-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-name.h
[draw-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-draw.h
[paint-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-paint.h
[ot-font-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ot-font.h
[ft-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ft.h
[ft-cc]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-ft.cc
[subset-h]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/src/hb-subset.h
[manual-object-model]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/docs/usermanual-object-model.xml
[manual-clusters]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/docs/usermanual-clusters.xml
[manual-fonts]: https://github.com/harfbuzz/harfbuzz/blob/f20f4c20bcb715eeb7974854b0689688975fdeee/docs/usermanual-fonts-and-faces.xml
