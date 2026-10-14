/**
Font files parsed in D (`docs/specs/font`).

Milestone M1: faces and collections over borrowed bytes, the table
directory, typed views of the fixed tables, character maps, `name` records
and glyph names. Every operation reads only inside the caller's buffer,
reports malformed data as a `FontError` rather than asserting, and does not
allocate. Milestone M2 begins with design values and their exact physical and
pixel conversions, the variation deltas of item variation stores, delta-set
index maps and Device tables, instances with normalized coordinates, and the
metrics of an instance (line metrics, decorations, advances, cell metrics, and
vertical line metrics, advances and origins), its `BASE` baselines and
extents, and its `MATH` data: constants, glyph information, math kerns,
variants and assemblies; and layout inspection: the scripts, language systems,
features and lookups of `GSUB` and `GPOS`, feature variations at an instance,
and the substitution records of `GSUB` lookups.

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
    $(LI `sparkles.font.math_table` — `MATH` constants, italics corrections, top accents, extended shapes, math kerns, variants and assemblies.)
    $(LI `sparkles.font.layout` — `GSUB` and `GPOS` scripts, language systems, features, feature variations, lookups and substitutions.)
    $(LI `sparkles.font.coverage` — Coverage tables: binary-search lookup and covered-glyph iteration.)
    $(LI `sparkles.font.gdef` — the `GDEF` header and the item variation store `MATH` and `GPOS` resolve against.)
    $(LI `sparkles.font.errors` — `FontError`, `FontResult` and `Tag`.)
)
*/
module sparkles.font;

public import sparkles.font.baseline;
public import sparkles.font.cmap;
public import sparkles.font.coverage;
public import sparkles.font.errors;
public import sparkles.font.face;
public import sparkles.font.gdef;
public import sparkles.font.glyph_names;
public import sparkles.font.instance;
public import sparkles.font.layout;
public import sparkles.font.math_table;
public import sparkles.font.metrics;
public import sparkles.font.names;
public import sparkles.font.tables;
public import sparkles.font.units;
public import sparkles.font.variations;
public import sparkles.font.vertical;
