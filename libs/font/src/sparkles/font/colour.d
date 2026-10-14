/**
Colour capability (`docs/specs/font/variation-metrics.md` FTI10; `SPEC.md`
FTI4).

`colourCapability` reports, for each colour format, whether the face has it,
independent of which formats the library renders: `COLR` version 0 layers,
`COLR` version 1 paint, `CPAL` palettes, `CBDT` bitmaps (with their `CBLC`
locations), `sbix` strikes and `SVG ` documents. Each is read in O(1) from
its table's header, and a header that cannot be verified is reported with
its error rather than as support: a `COLR` version above 1 is
`unsupportedVersion`, and a `CBDT` without `CBLC` is `missingTable` naming
`CBLC`. Nothing here allocates or asserts on font data.
*/
module sparkles.font.colour;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.tables : locate, Located;

@safe pure nothrow @nogc:

/**
One colour capability: whether its table is in the face, and whether the
face has the capability — `false` when the table is absent or holds no data
for it, the table's error when its header cannot be verified.
*/
struct ColourSupport
{
    @safe pure nothrow @nogc:

    /// Whether the face has a record for the capability's table.
    bool present;
    private bool has_, failed_;
    private FontError error_;

    /// Whether the face has the capability, or why its table cannot say.
    FontResult!bool has() const scope => failed_ ? fontErr!bool(error_) : fontOk!bool(has_);

    /// Whether `has` is `true`.
    bool usable() const scope => !failed_ && has_;

    private static ColourSupport absent() => ColourSupport.init;
    private static ColourSupport found(bool has) => ColourSupport(true, has);
    private static ColourSupport failed(FontError e) => ColourSupport(true, false, true, e);
}

/// What a face holds of each colour format (FTI4, FTI10).
struct ColourCapability
{
    /// `COLR` base glyph records (version 0 data, also in version 1).
    ColourSupport colrLayers;
    /// `COLR` version 1 BaseGlyphList paint records.
    ColourSupport colrPaint;
    /// `CPAL` palettes.
    ColourSupport cpal;
    /// `CBDT` bitmaps, located through `CBLC`.
    ColourSupport cbdt;
    /// `sbix` strikes.
    ColourSupport sbix;
    /// `SVG ` documents.
    ColourSupport svg;
}

private enum colrTag = Tag("COLR"), cpalTag = Tag("CPAL"), cbdtTag = Tag("CBDT"), cblcTag = Tag("CBLC"),
    sbixTag = Tag("sbix"), svgTag = Tag("SVG ");

/// The table `tag`: absent, its error, or its bytes.
private struct Table
{
    bool present, failed;
    FontError error;
    Located at;
}

private Table table(return scope const Face face, Tag tag)
{
    if (!face.has(tag))
        return Table.init;
    const at = locate(face, tag);
    if (at.hasError)
        return Table(true, true, at.error);
    return Table(true, false, FontError.init, at.value);
}

/// Whether `count` records of `size` bytes at the 32-bit offset in field `fieldAt` fit (none always do).
private FontResult!bool arrayFits(in Located t, Tag tag, ulong fieldAt, ulong count, ulong size)
{
    if (count == 0)
        return fontOk(true);
    const offset = be32(t.data, cast(size_t) fieldAt);
    if (offset >= t.data.length)
        return fontErr!bool(tableError(FontErrorKind.badOffset, tag, t.start, fieldAt));
    if (!fits(t.data.length, offset, count * size))
        return fontErr!bool(tableError(FontErrorKind.truncated, tag, t.start, offset));
    return fontOk(true);
}

private ColourSupport fromResult(in FontResult!bool r, bool has)
    => r.hasError ? ColourSupport.failed(r.error) : ColourSupport.found(has);

private ColourSupport truncated(Tag tag, in Located t, ulong needed)
    => ColourSupport.failed(tableError(FontErrorKind.truncated, tag, t.start,
        t.data.length < needed ? t.data.length : needed));

/// `COLR` layers and paint: versions 0 and 1; base glyph and layer arrays checked to fit.
private void colr(scope const Face face, ref ColourCapability c)
{
    const t = table(face, colrTag);
    if (!t.present)
        return;
    const header = colrHeader(t);
    if (header.failed_)
    {
        c.colrLayers = c.colrPaint = header;
        return;
    }
    const d = t.at.data;
    const version_ = be16(d, 0);
    const baseGlyphs = be16(d, 2);
    c.colrLayers = ColourSupport.found(false);
    if (baseGlyphs > 0)
    {
        auto r = arrayFits(t.at, colrTag, 4, baseGlyphs, 6);
        if (r.hasValue)
            r = arrayFits(t.at, colrTag, 8, be16(d, 12), 4);
        c.colrLayers = fromResult(r, true);
    }
    c.colrPaint = ColourSupport.found(false);
    const listAt = version_ == 1 ? be32(d, 14) : 0;
    if (listAt == 0)
        return;
    if (listAt >= d.length)
        c.colrPaint = ColourSupport.failed(tableError(FontErrorKind.badOffset, colrTag, t.at.start, 14));
    else if (!fits(d.length, listAt, 4))
        c.colrPaint = truncated(colrTag, t.at, ulong(listAt) + 4);
    else if (!fits(d.length, ulong(listAt) + 4, 6UL * be32(d, listAt)))
        c.colrPaint = ColourSupport.failed(tableError(FontErrorKind.truncated, colrTag, t.at.start, ulong(listAt) + 4));
    else
        c.colrPaint = ColourSupport.found(be32(d, listAt) > 0);
}

/// The `COLR` header's problem, shared by both entries: its error, a version above 1, or a short header.
private ColourSupport colrHeader(in Table t)
{
    if (t.failed)
        return ColourSupport.failed(t.error);
    const d = t.at.data;
    if (d.length < 2)
        return truncated(colrTag, t.at, 14);
    const version_ = be16(d, 0);
    if (version_ > 1)
        return ColourSupport.failed(tableError(FontErrorKind.unsupportedVersion, colrTag, t.at.start, 0));
    const headerLength = version_ == 1 ? 34 : 14;
    if (d.length < headerLength)
        return truncated(colrTag, t.at, headerLength);
    return ColourSupport.found(true);
}

/// `CPAL`: versions 0 and 1, palettes with their index array and colour records checked to fit.
private ColourSupport cpal(scope const Face face)
{
    const t = table(face, cpalTag);
    if (!t.present)
        return ColourSupport.absent;
    if (t.failed)
        return ColourSupport.failed(t.error);
    const d = t.at.data;
    if (d.length < 12)
        return truncated(cpalTag, t.at, 12);
    if (be16(d, 0) > 1)
        return ColourSupport.failed(tableError(FontErrorKind.unsupportedVersion, cpalTag, t.at.start, 0));
    const palettes = be16(d, 4);
    if (palettes == 0)
        return ColourSupport.found(false);
    if (!fits(d.length, 12, 2UL * palettes))
        return truncated(cpalTag, t.at, 12 + 2UL * palettes);
    return fromResult(arrayFits(t.at, cpalTag, 8, be16(d, 6), 4), true);
}

/// `CBDT` with `CBLC`: both of major version 2 or 3, and at least one bitmap size in `CBLC`.
private ColourSupport cbdt(scope const Face face)
{
    const data = table(face, cbdtTag);
    if (!data.present)
        return ColourSupport.absent;
    if (data.failed)
        return ColourSupport.failed(data.error);
    const locations = table(face, cblcTag);
    if (!locations.present)
        return ColourSupport.failed(FontError(FontErrorKind.missingTable, cblcTag));
    if (locations.failed)
        return ColourSupport.failed(locations.error);
    if (data.at.data.length < 4)
        return truncated(cbdtTag, data.at, 4);
    const dataMajor = be16(data.at.data, 0);
    if (dataMajor != 2 && dataMajor != 3)
        return ColourSupport.failed(tableError(FontErrorKind.unsupportedVersion, cbdtTag, data.at.start, 0));
    const d = locations.at.data;
    if (d.length < 8)
        return truncated(cblcTag, locations.at, 8);
    const major = be16(d, 0);
    if (major != 2 && major != 3)
        return ColourSupport.failed(tableError(FontErrorKind.unsupportedVersion, cblcTag, locations.at.start, 0));
    const sizes = be32(d, 4);
    if (!fits(d.length, 8, 48UL * sizes))
        return ColourSupport.failed(tableError(FontErrorKind.truncated, cblcTag, locations.at.start, 8));
    return ColourSupport.found(sizes > 0);
}

/// `sbix`: version 1, with its strike offsets checked to fit.
private ColourSupport sbix(scope const Face face)
{
    const t = table(face, sbixTag);
    if (!t.present)
        return ColourSupport.absent;
    if (t.failed)
        return ColourSupport.failed(t.error);
    const d = t.at.data;
    if (d.length < 8)
        return truncated(sbixTag, t.at, 8);
    if (be16(d, 0) != 1)
        return ColourSupport.failed(tableError(FontErrorKind.unsupportedVersion, sbixTag, t.at.start, 0));
    const strikes = be32(d, 4);
    if (!fits(d.length, 8, 4UL * strikes))
        return ColourSupport.failed(tableError(FontErrorKind.truncated, sbixTag, t.at.start, 8));
    return ColourSupport.found(strikes > 0);
}

/// `SVG `: version 0, a document list whose records fit.
private ColourSupport svg(scope const Face face)
{
    const t = table(face, svgTag);
    if (!t.present)
        return ColourSupport.absent;
    if (t.failed)
        return ColourSupport.failed(t.error);
    const d = t.at.data;
    if (d.length < 10)
        return truncated(svgTag, t.at, 10);
    if (be16(d, 0) != 0)
        return ColourSupport.failed(tableError(FontErrorKind.unsupportedVersion, svgTag, t.at.start, 0));
    const listAt = be32(d, 2);
    if (listAt == 0 || listAt >= d.length)
        return ColourSupport.failed(tableError(FontErrorKind.badOffset, svgTag, t.at.start, 2));
    if (!fits(d.length, listAt, 2))
        return truncated(svgTag, t.at, ulong(listAt) + 2);
    const entries = be16(d, listAt);
    if (!fits(d.length, ulong(listAt) + 2, 12UL * entries))
        return ColourSupport.failed(tableError(FontErrorKind.truncated, svgTag, t.at.start, ulong(listAt) + 2));
    return ColourSupport.found(entries > 0);
}

/**
The colour formats `face` holds (FTI10), each read in O(1) from its table's
header:

$(UL
    $(LI `colrLayers`: `COLR` version 0 or 1 with base glyph records, whose
        base glyph and layer arrays fit.)
    $(LI `colrPaint`: `COLR` version 1 with a non-empty BaseGlyphList (its
        offset at byte 14) whose records fit.)
    $(LI `cpal`: `CPAL` version 0 or 1 with palettes, whose index array and
        colour records fit.)
    $(LI `cbdt`: `CBDT` with a `CBLC` of at least one bitmap size, both of
        major version 2 or 3; without `CBLC`, `missingTable` naming `CBLC`.)
    $(LI `sbix`: `sbix` version 1 with strikes.)
    $(LI `svg`: `SVG ` version 0 with a non-empty document list.)
)
A `COLR` above version 1 is `unsupportedVersion` for both `COLR` entries; a
header that is truncated, or an offset outside its table, is that entry's
error. `present` is set whenever the face has the table, and `has` is false
for a table that holds no data for the capability.
*/
ColourCapability colourCapability(scope const Face face)
{
    ColourCapability c;
    colr(face, c);
    c.cpal = cpal(face);
    c.cbdt = cbdt(face);
    c.sbix = sbix(face);
    c.svg = svg(face);
    return c;
}
