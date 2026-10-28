/**
Font files parsed in D (`docs/specs/font`).

Milestone M1: faces and collections over borrowed bytes, the table
directory, typed views of the fixed tables, character maps, `name` records
and glyph names. Every operation reads only inside the caller's buffer,
reports malformed data as a `FontError` rather than asserting, and does not
allocate.

Milestone M2: instances of variable faces and their normalized coordinates;
variation deltas; exact design values with one rounding into physical
`LayoutUnit` and explicit pixel conversion; line, decoration, cell and
vertical metrics; `BASE` baselines and extents; `MATH` data; the scripts,
features, feature variations and substitutions of `GSUB` and `GPOS`; and which
colour formats a face holds. A value the font does not supply is reported as
absent, never invented.

Milestone M3: glyph outlines (FTO1–FTO5). Milestone M4: shaping lives in
the `engine` configuration only — `sparkles.font.shaping` is public
there (its HarfBuzz declarations in `sparkles.font.harfbuzz` are
imported explicitly) and both are absent from the pure-D `library`
configuration (FTA7). Milestone M5: grayscale rasterization. Milestone M6:
colour glyphs, `COLR` version 0 layers coloured from `CPAL` and the PNGs of
`CBDT` and `sbix` strikes, into premultiplied RGBA.

$(UL
    $(LI `sparkles.font.face` — `openFace`, `openCollection`, `Face`, table lookup and inspection.)
    $(LI `sparkles.font.tables` — `head`, `hhea`, `maxp`, `OS/2`, `post`, `hmtx`, `fvar`, `avar`, `STAT`, spacing.)
    $(LI `sparkles.font.cmap` — `charMap`, lookups, coverage ranges and variation sequences.)
    $(LI `sparkles.font.names` — `name` records and their text.)
    $(LI `sparkles.font.glyph_names` — glyph names from `post` and `CFF`.)
    $(LI `sparkles.font.units` — design values, `Ppem`, and their physical and pixel conversions.)
    $(LI `sparkles.font.variations` — item variation stores, delta-set index maps, Device and VariationIndex deltas.)
    $(LI `sparkles.font.instance` — axes, named instances, and `Instance`: normalized coordinates with `avar` 1 and 2.)
    $(LI `sparkles.font.metrics` — `Measurement`, `HVAR` and `MVAR`, vertical sets, line metrics, decorations, advances, runs and cell metrics.)
    $(LI `sparkles.font.vertical` — `vhea`, `vmtx`, `VORG` and `VVAR`; vertical line metrics, advances and origins.)
    $(LI `sparkles.font.baseline` — the `BASE` view, baseline tags, baselines and extents.)
    $(LI `sparkles.font.outlines` — glyph outlines as segments or to a sink: `glyf` composites and `gvar`, `CFF` charstrings, phantom points and overlap flags.)
    $(LI `sparkles.font.layout` — `GSUB` and `GPOS` scripts, language systems, features, feature variations, lookups and substitutions.)
    $(LI `sparkles.font.raster` — grayscale coverage of one glyph into a caller-owned region.)
    $(LI `sparkles.font.colour` — `colourCapability`: the colour formats a face holds.)
    $(LI `sparkles.font.colour_raster` — `colourMeasure` and `rasterizeColourGlyph`: a glyph's colour form into premultiplied RGBA.)
    $(LI `sparkles.font.colr` — `COLR` version 0 layers, `CPAL` palettes, and layered rendering.)
    $(LI `sparkles.font.bitmap` — `CBDT`/`CBLC` and `sbix` strikes: strike choice, lookup and scaled rendering.)
    $(LI `sparkles.font.png` — the PNG decoder of bitmap strikes.)
    $(LI `sparkles.font.coverage` — Coverage tables: binary-search lookup and covered-glyph iteration.)
    $(LI `sparkles.font.gdef` — the `GDEF` header and the item variation store `MATH` and `GPOS` resolve against.)
    $(LI `sparkles.font.corrections` — the correction registry: `Correction`, `CorrectionPolicy`, and what each entry follows and changes.)
    $(LI `sparkles.font.errors` — `FontError`, `FontResult` and `Tag`.)
)
*/
module sparkles.font;

public import sparkles.font.baseline;
public import sparkles.font.bitmap;
public import sparkles.font.cmap;
public import sparkles.font.carets;
public import sparkles.font.colour;
public import sparkles.font.colour_raster;
public import sparkles.font.colr;
public import sparkles.font.corrections;
public import sparkles.font.coverage;
public import sparkles.font.errors;
public import sparkles.font.face;
public import sparkles.font.gdef;
public import sparkles.font.glyph_names;
public import sparkles.font.instance;
public import sparkles.font.jstf;
public import sparkles.font.layout;
public import sparkles.font.math_table;
public import sparkles.font.metrics;
public import sparkles.font.names;
public import sparkles.font.outlines;
public import sparkles.font.png;
public import sparkles.font.raster;
public import sparkles.font.tables;
public import sparkles.font.units;
public import sparkles.font.variations;

version (SparklesFontEngine)
{
    public import sparkles.font.shaping;
}
public import sparkles.font.vertical;
