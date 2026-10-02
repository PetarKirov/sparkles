# Pango (C / GLib ecosystem)

Pango is the GNOME text-layout engine; below layout it is a thin, GObject-shaped
font-management and shaping facade that owns _no_ font bytes and _no_ shaper of
its own — it resolves a description to a prioritized `PangoFontset`, hands each
run to HarfBuzz, and delegates discovery to fontconfig, CoreText or Win32.

| Field            | Value                                                                               |
| ---------------- | ----------------------------------------------------------------------------------- |
| Language         | C (gnu11), GObject                                                                  |
| License          | LGPL-2.1-or-later ([`COPYING`][copying])                                            |
| Repository       | [GNOME/pango][repo] (GitLab)                                                        |
| Documentation    | [`docs/`][docs] (gi-docgen; `docs/pango_cairo.md` for units), [`README.md`][readme] |
| Category         | layout engine                                                                       |
| Layer(s) covered | match/fallback · shape · layout (the layout half is out of scope here)              |
| Version at pin   | 1.58.2 ([`meson.build`][meson])                                                     |
| Pinned revision  | `8e74c27c113c98664b77272d16b14bbce542c184` (2026-09-11)                             |

## Overview

### What it solves

A toolkit needs "give me the fonts for this description, in this language, and
shape this run with them" without caring whether the fonts come from fontconfig,
CoreText or GDI. Pango's contribution below layout is exactly that boundary: a
_description_ (`PangoFontDescription`), a _resolved set_ (`PangoFontset`), a
_scaled font_ (`PangoFont`) and a _factory_ (`PangoFontMap`) — each an abstract
GObject with one subclass per platform ([`README.md`][readme] lists the three
backends: FreeType+FontConfig, Win32, CoreText).

### Design philosophy

The fontset is the key abstraction, and the header says what it is for:

```c
/**
 * PangoFontset:
 *
 * A `PangoFontset` represents a set of `PangoFont` to use when rendering text.
 *
 * A `PangoFontset` is the result of resolving a `PangoFontDescription`
 * against a particular `PangoContext`. It has operations for finding the
 * component font for a particular Unicode character, and for finding a
 * composite set of metrics for the entire fontset.
 */
```

— [`pango/pango-fontset.h`][fontset-h]

Resolution happens once per description; per-character font choice is a query
on the result. That split is what lets fallback be a property of the font
system rather than of the layout.

## How it works

`PangoFontMapClass` has three load-bearing virtuals — `load_font`,
`list_families`, `load_fontset` — plus `get_serial`/`changed` for cache
invalidation and `get_family`/`get_face` for enumeration
([`pango-fontmap.h`][fontmap-h]). `PangoFontsetClass` has `get_font (fontset, wc)`,
`get_metrics`, `get_language` and `foreach` ([`pango-fontset.h`][fontset-h]).
`PangoFontClass` has `describe`, `get_coverage`, `get_glyph_extents`,
`get_metrics`, `get_features` and — since 1.44 — `create_hb_font`
([`pango-font.h`][font-h]). Every platform backend is a triple of subclasses
implementing those vtables; everything above them is platform-neutral.

Shaping is one function, `pango_hb_shape` in [`shape.c`][shape-c]: it takes
`pango_font_get_hb_font`, creates a _sub-font_ with four overridden font funcs
(`nominal_glyph`, `h_advance`, `v_advance`, `glyph_extents`) so that invisible
characters and `PANGO_SHOW_*` flags can be substituted without touching the
real `hb_font_t`, fills an `hb_buffer_t` with direction, ISO 15924 script,
language, `HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS` and the paragraph as
pre-/post-context, calls `hb_shape`, and copies `hb_glyph_position_t` into
`PangoGlyphInfo.geometry` — swapping axes for vertical gravity.

## Analysis spine

### 1. Layering and ownership

Four GObject layers: `PangoFontMap` (process/display singleton, owns every
cache) → `PangoFontset` (resolved description, refcounted, MRU-cached by the
map) → `PangoFont` (one face at one size/matrix/variation, refcounted, cached
in `font_hash`) → `hb_font_t` (created lazily by `create_hb_font`, then
`hb_font_make_immutable`, owned by the `PangoFont` for life — [`fonts.c`][fonts-c]).
Font bytes are owned one level lower still: the fontconfig map keeps one
`hb_face_t` per (file, index) in `font_face_data_hash`, created with
`hb_blob_create_from_file` ([`pangofc-fontmap.c`][fc-fontmap-c]), so a
thousand sizes of one file share one mapping. The 50-line comment at the top of
that file is candid — "All programming is a practice in caching data" — and
enumerates five caches. Thread-safety is per-object mutexes around fontconfig
calls (`fc_init_mutex`, `patterns->mutex`) rather than a documented contract;
fontconfig initialization runs on a background thread. Errors are GLib
`g_return_if_fail` plus `NULL` returns — no error type.

### 2. Face loading and table access

Pango never parses a font file. A face is reached only through the backend
(`FcPattern` → file + index → `hb_face_t`; `CTFontDescriptorRef`; `LOGFONTW`),
and raw tables are reachable only by escaping to `hb_font_get_face
(pango_font_get_hb_font (font))`. There is no path-or-bytes constructor on the
public API; `pango_font_map_load_font` takes a description, not a file. For
the inspector that means Pango is the wrong layer — it exposes families/faces
(`list_families`, `get_face`) and `pango_font_get_features` /
`pango_font_get_languages`, nothing table-level.

### 3. Shaping

Entirely delegated (see above). Features: the font's `get_features` fills up to
32 `hb_feature_t` from the fontconfig `FC_FONT_FEATURES` pattern value and the
`PangoAttrFontFeatures` attribute. Cluster mapping is HarfBuzz's monotone
clusters copied into `log_clusters` (byte offsets). Output units are
`PangoGlyphUnit` — "1024ths of a device unit" — because `hb_font_set_scale` is
called with `pixel_size * PANGO_SCALE` ([`pangofc-font.c`][fc-font-c]), so
HarfBuzz already produces Pango units and no conversion happens.
`PANGO_SHAPE_ROUND_POSITIONS` optionally rounds to whole device units via
`PANGO_UNITS_ROUND` ([`pango-glyph.h`][glyph-h], [`shape.c`][shape-c]).

### 4. Variation and instances

Variations ride on the description as a _string_
(`pango_font_description_set_variations`, CSS-like `"wght=700,wdth=80"`), are
part of the `PangoFcFontKey` hash so each setting is a distinct cached font,
and are resolved in `pango_fc_font_create_hb_font`: start from each axis's
default, set `opsz` to the point size, apply the named instance encoded in
`FC_INDEX >> 16`, then `FC_FONT_VARIATIONS` from the pattern, then the
description's string, and finally one `hb_font_set_var_coords_design`
([`pangofc-font.c`][fc-font-c]). The Win32 backend does the same from its own
string ([`pangowin32.c`][win32-c]). Design coordinates only; normalized
coordinates and `avar` are HarfBuzz's business. Rasterizers (cairo-ft) get the
same coordinates via `FC_FONT_VARIATIONS` in the render-prepared pattern — the
pattern is the carrier between shaper and rasterizer.

### 5. Rasterization and outlines

None. Pango shapes and positions; drawing is cairo's (or a renderer subclass's).
There is no outline API, no bitmap API and no atlas on this side of the seam;
`pango_font_get_glyph_extents` is the only glyph geometry exposed, in Pango
units. Color-font detection in `shape.c` uses `hb_ot_color_has_paint/layers/png/svg`
purely to decide whether to apply foreground colour. This absence is the
finding: a layout engine can be complete with zero knowledge of rendering.

### 6. Metrics and measurement

`PangoFontMetrics` (ascent, descent, height, approximate char/digit width,
underline/strikethrough position and thickness) comes from
`hb_font_get_extents_for_direction` and `hb_ot_metrics_get_position`
([`pangofc-font.c`][fc-font-c]) — so the hhea/OS/2 choice is HarfBuzz's — then
scaled by the fontconfig matrix. Fontset metrics are the _first_ font's
metrics ([`pango-context.c`][context-c] `get_first_metrics_foreach`), not a
union. Units: `PangoGlyphUnit`, `PANGO_SCALE = 1024`, `PANGO_PIXELS` to round.

### 7. Discovery, matching and fallback

Matching is delegated: the fontconfig map calls `FcFontSetSort (…, FcTrue, …)`
(trim on) and caches the result per pattern; `get_font (wc)` walks the sorted
list querying each font's `PangoCoverage` and stops at the first
`PANGO_COVERAGE_EXACT` ([`pangofc-fontmap.c`][fc-fontmap-c]). Itemization
calls `pango_fontset_foreach` per character with a small per-fontset
`FontCache`, and falls back to the base font when nothing covers the character
([`itemize.c`][itemize-c]). Fallback is therefore **per-codepoint, inside a
per-item language**, with scripts split beforehand. Weight/width/slant are
enumerated CSS-style (`PangoWeight` 100–1000, `PangoStretch`, `PangoStyle`) and
mapped to each backend's scale; CoreText uses `CTFontCollection` +
`kCTFontTraitsAttribute` ([`pangocoretext-fontmap.c`][ct-fontmap-c]). No
PANOSE or classification data is consumed.

## What it teaches `sparkles:font`

- **A fontset is the unit of fallback**: resolve a description once to an
  ordered list, then ask it per codepoint with coverage; cache the answers.
- **Scale the shaper so its output _is_ your layout unit** — `hb_font_set_scale
(px * SCALE)` removes a conversion step and a rounding site.
- **Variation coordinates belong on the font key**; same face + different
  coordinates = different cached font object, immutable once built.
- **Keep the scaled font immutable and let it own its `hb_font_t`**; share the
  `hb_face_t` per (file, index) beneath it.
- **A sub-font with overridden funcs** is how to inject invisibles/transforms
  without mutating the shared font.
- A font-management API can be useful with no bytes, no tables and no raster —
  but then it cannot be the inspector's substrate.

## Strengths

- Clean four-vtable boundary; three platform backends prove the seam.
- Fallback and matching are properties of the fontset, not the layout.
- Variation plumbing is complete end-to-end with one design-coordinate call.
- Aggressive, documented caching at every layer.

## Weaknesses

- No raw face access, no outlines, no bytes-in constructor — unusable as an
  inspector or rasterizer substrate.
- Thread-safety is implementation detail, not contract.
- Fontset metrics are the first font's only.
- GObject refcounting and `g_return_if_fail` is the entire error model.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                        | Trade-off                                          |
| ------------------------------------------------ | ------------------------------------------------ | -------------------------------------------------- |
| Abstract `FontMap`/`Fontset`/`Font` GObjects     | One layout core over three platform font systems | Table/outline access only by escaping to HarfBuzz  |
| Shaper scale = `px * PANGO_SCALE`                | HarfBuzz output needs no conversion              | `PANGO_SCALE` is baked into every backend          |
| Variations as a string on the description + key  | Serializable, hashable, user-facing              | Parsed on every font creation                      |
| Per-codepoint fallback over an `FcFontSort` list | Correct for mixed scripts within one item        | Coverage objects per font; first-font metrics only |
| `hb_font_t` immutable, owned by `PangoFont`      | Safe sharing across layouts                      | Cannot tweak funcs after creation (hence sub-font) |

## Sources

- [`pango/pango-fontmap.h`][fontmap-h], [`pango/pango-fontset.h`][fontset-h],
  [`pango/pango-font.h`][font-h] — the three vtables.
- [`pango/pango-glyph.h`][glyph-h] — `PangoGlyphUnit`, `PANGO_SCALE`, `PangoShapeFlags`.
- [`pango/shape.c`][shape-c] — `pango_hb_shape`, sub-font funcs, position copy.
- [`pango/fonts.c`][fonts-c] — `pango_font_get_hb_font` and immutability.
- [`pango/pangofc-fontmap.c`][fc-fontmap-c], [`pango/pangofc-font.c`][fc-font-c] — caches, `FcFontSetSort`, `hb_face` sharing, variations, metrics.
- [`pango/itemize.c`][itemize-c], [`pango/pango-context.c`][context-c] — per-codepoint `get_font`, fontset metrics.
- [`pango/pangocoretext-fontmap.c`][ct-fontmap-c], [`pango/pangowin32.c`][win32-c], [`pango/pangocairo-fontmap.c`][cairo-fontmap-c] — platform backends.
- Siblings: [HarfBuzz](./harfbuzz.md), [fontconfig](./fontconfig.md), [FreeType](./freetype.md).
<!-- References -->

[repo]: https://gitlab.gnome.org/GNOME/pango
[docs]: https://gitlab.gnome.org/GNOME/pango/-/tree/8e74c27c113c98664b77272d16b14bbce542c184/docs
[readme]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/README.md
[copying]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/COPYING
[meson]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/meson.build
[fontmap-h]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pango-fontmap.h
[fontset-h]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pango-fontset.h
[font-h]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pango-font.h
[glyph-h]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pango-glyph.h
[shape-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/shape.c
[fonts-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/fonts.c
[fc-fontmap-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pangofc-fontmap.c
[fc-font-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pangofc-font.c
[itemize-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/itemize.c
[context-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pango-context.c
[ct-fontmap-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pangocoretext-fontmap.c
[win32-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pangowin32.c
[cairo-fontmap-c]: https://gitlab.gnome.org/GNOME/pango/-/blob/8e74c27c113c98664b77272d16b14bbce542c184/pango/pangocairo-fontmap.c
