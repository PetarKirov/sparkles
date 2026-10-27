/**
Layered colour glyphs: `COLR` version 0 and `CPAL` (`docs/specs/font/SPEC.md`
FTR5, FTB3).

`colrLayers` lists a glyph's layers, each a glyph and a palette entry,
bottom first; `paletteCount` and `paletteColour` read `CPAL`. A glyph's
layers render in order, each layer's outline rasterized in grayscale
(`sparkles.font.raster`) and its coverage composited source-over in its
colour into a premultiplied RGBA region. Palette entry `0xFFFF` takes the
foreground colour the caller supplies.

Only version 0 records are read. A version 1 table's base glyph records
are its version 0 data, read the same way; its paint graph is not
rendered, so a glyph that only the BaseGlyphList names has no layers here.
A glyph has at most 1,024 layers (FTB3); more is `limitExceeded` naming
`colrLayers`. Nothing allocates.
*/
module sparkles.font.colr;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.colour_raster : Colour, ColourGlyph, ColourRegion, ColourSource, ColourWorkspace,
    regionHolds;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontLimit, fontLimitValue,
    FontResult, fontErr, fontOk, limitError, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.instance : Instance;
import sparkles.font.raster : RasterGlyph, RasterRegion, RasterWorkspace, rasterizeGlyph, rasterMeasure;
import sparkles.font.tables : locate, Located;
import sparkles.font.units : Ppem;

@safe pure nothrow @nogc:

/// The palette entry that stands for the caller's foreground colour.
enum ushort foregroundPaletteEntry = 0xFFFF;

/// One layer of a `COLR` glyph: the glyph whose outline it fills, and its palette entry.
struct ColrLayer
{
    uint glyph;
    ushort paletteEntry;
}

private enum colrTag = Tag("COLR"), cpalTag = Tag("CPAL");

/// A glyph's layer records: where they start in `COLR` and how many there are.
private struct LayerRun
{
    @safe pure nothrow @nogc:

    Located colr;
    size_t first, count;
    ulong layersAt;

    ColrLayer layer(size_t i) const scope
    {
        const at = cast(size_t)(layersAt + 4 * (first + i));
        return ColrLayer(be16(colr.data, at), be16(colr.data, at + 2));
    }
}

/// The layer records of `gid`, a run of none when the face has no `COLR` or the glyph no record.
private FontResult!LayerRun layerRun(scope return const Face face, uint gid)
{
    if (!face.has(colrTag))
        return fontOk(LayerRun.init);
    const t = locate(face, colrTag);
    if (t.hasError)
        return fontErr!LayerRun(t.error);
    const d = t.value.data;
    FontError at(FontErrorKind kind, ulong relative) => tableError(kind, colrTag, t.value.start, relative);
    if (d.length < 14)
        return fontErr!LayerRun(at(FontErrorKind.truncated, d.length));
    if (be16(d, 0) > 1)
        return fontErr!LayerRun(at(FontErrorKind.unsupportedVersion, 0));
    const baseCount = be16(d, 2), baseAt = be32(d, 4), layersAt = be32(d, 8), layerCount = be16(d, 12);
    if (baseCount == 0)
        return fontOk(LayerRun.init);
    if (!fits(d.length, baseAt, 6UL * baseCount))
        return fontErr!LayerRun(at(baseAt >= d.length ? FontErrorKind.badOffset : FontErrorKind.truncated, 4));
    if (layerCount > 0 && !fits(d.length, layersAt, 4UL * layerCount))
        return fontErr!LayerRun(at(layersAt >= d.length ? FontErrorKind.badOffset : FontErrorKind.truncated, 8));
    // Base glyph records are sorted by glyph: binary search.
    size_t lo = 0, hi = baseCount;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        const record = baseAt + 6 * mid;
        const glyph = be16(d, record);
        if (glyph == gid)
        {
            const first = be16(d, record + 2), count = be16(d, record + 4);
            if (count > fontLimitValue[FontLimit.colrLayers])
                return fontErr!LayerRun(limitError(FontLimit.colrLayers, colrTag, t.value.start + record));
            if (ulong(first) + count > layerCount)
                return fontErr!LayerRun(at(FontErrorKind.badValue, record + 2));
            return fontOk(LayerRun(t.value, first, count, layersAt));
        }
        if (glyph < gid)
            lo = mid + 1;
        else
            hi = mid;
    }
    return fontOk(LayerRun.init);
}

/**
The `COLR` version 0 layers of glyph `gid`, bottom first, written to
`layers`; the count is returned, 0 for a glyph without layers or a face
without `COLR`. A `layers` shorter than the count is `limitExceeded`
naming `callerStorage`, whose `needed` is the count. A `COLR` above
version 1 is `unsupportedVersion`; arrays outside the table are `badOffset`
or `truncated`; a base record whose layers run past the layer array is
`badValue`. Cost: O(log base records + layers).
*/
FontResult!size_t colrLayers(scope const Face face, uint gid, scope ColrLayer[] layers)
{
    const run = layerRun(face, gid);
    if (run.hasError)
        return fontErr!size_t(run.error);
    const r = run.value;
    if (layers.length < r.count)
        return fontErr!size_t(callerStorageError(r.count, colrTag, r.colr.start, 0));
    foreach (i; 0 .. r.count)
        layers[i] = r.layer(i);
    return fontOk!size_t(r.count);
}

/// `CPAL`'s palettes: their count, entries each, and where the records and their index array lie.
private struct Palettes
{
    Located cpal;
    uint palettes, entries, records;
    ulong recordsAt;
}

private FontResult!Palettes palettes(scope return const Face face)
{
    if (!face.has(cpalTag))
        return fontErr!Palettes(FontError(FontErrorKind.missingTable, cpalTag));
    const t = locate(face, cpalTag);
    if (t.hasError)
        return fontErr!Palettes(t.error);
    const d = t.value.data;
    FontError at(FontErrorKind kind, ulong relative) => tableError(kind, cpalTag, t.value.start, relative);
    if (d.length < 12)
        return fontErr!Palettes(at(FontErrorKind.truncated, d.length));
    if (be16(d, 0) > 1)
        return fontErr!Palettes(at(FontErrorKind.unsupportedVersion, 0));
    auto p = Palettes(t.value, be16(d, 4), be16(d, 2), be16(d, 6), be32(d, 8));
    if (!fits(d.length, 12, 2UL * p.palettes))
        return fontErr!Palettes(at(FontErrorKind.truncated, 12));
    if (p.records > 0 && !fits(d.length, p.recordsAt, 4UL * p.records))
        return fontErr!Palettes(at(p.recordsAt >= d.length ? FontErrorKind.badOffset : FontErrorKind.truncated, 8));
    return fontOk(p);
}

/// The number of `CPAL` palettes; a face without `CPAL` is `missingTable` naming it.
FontResult!uint paletteCount(scope const Face face)
{
    const p = palettes(face);
    return p.hasError ? fontErr!uint(p.error) : fontOk!uint(p.value.palettes);
}

private FontResult!Colour colourOf(in Palettes p, uint palette, uint entry)
{
    if (palette >= p.palettes)
        return fontErr!Colour(FontError(FontErrorKind.indexOutOfRange, cpalTag));
    if (entry >= p.entries)
        return fontErr!Colour(FontError(FontErrorKind.indexOutOfRange, cpalTag));
    const first = be16(p.cpal.data, 12 + 2 * palette);
    const index = ulong(first) + entry;
    if (index >= p.records)
        return fontErr!Colour(tableError(FontErrorKind.badValue, cpalTag, p.cpal.start, 12 + 2 * palette));
    const at = cast(size_t)(p.recordsAt + 4 * index);
    const d = p.cpal.data;
    // Records are stored blue, green, red, alpha.
    return fontOk(Colour(d[at + 2], d[at + 1], d[at], d[at + 3]));
}

/**
Entry `entry` of `CPAL` palette `palette`, as stored: straight sRGB with
alpha. A palette or entry past `CPAL`'s counts is `indexOutOfRange`; a
palette whose entries run past the colour records is `badValue`; a face
without `CPAL` is `missingTable`. O(1).
*/
FontResult!Colour paletteColour(scope const Face face, uint palette, uint entry)
{
    const p = palettes(face);
    return p.hasError ? fontErr!Colour(p.error) : colourOf(p.value, palette, entry);
}

/**
The box of glyph `gid`'s `COLR` layers at `ppem`, the union of its layers'
grayscale boxes, and the storage drawing them needs; `source` is `none`
for a glyph without layers. The errors are those of `colrLayers` and of
`rasterMeasure` for each layer. Cost: one outline decode per layer.
*/
FontResult!ColourGlyph colrMeasure(in Instance inst, uint gid, Ppem ppem, return scope RasterWorkspace ws)
{
    const run = layerRun(inst.face, gid);
    if (run.hasError)
        return fontErr!ColourGlyph(run.error);
    const r = run.value;
    ColourGlyph glyph;
    if (r.count == 0)
        return fontOk(glyph);
    glyph.source = ColourSource.layers;
    glyph.layerCount = r.count;
    int left = int.max, top = int.min, right = int.min, bottom = int.max;
    foreach (i; 0 .. r.count)
    {
        const m = rasterMeasure(inst, r.layer(i).glyph, ppem, ws);
        if (m.hasError)
            return fontErr!ColourGlyph(m.error);
        const box = m.value;
        if (box.empty || box.width == 0 || box.height == 0)
            continue;
        left = box.bearingX < left ? box.bearingX : left;
        top = box.bearingY > top ? box.bearingY : top;
        right = box.bearingX + box.width > right ? box.bearingX + box.width : right;
        bottom = box.bearingY - box.height < bottom ? box.bearingY - box.height : bottom;
        const area = cast(size_t) box.width * box.height;
        glyph.coverageNeeded = area > glyph.coverageNeeded ? area : glyph.coverageNeeded;
        if (box.accumulationNeeded > glyph.accumulationNeeded)
            glyph.accumulationNeeded = box.accumulationNeeded;
        if (box.supersampleNeeded > glyph.supersampleNeeded)
            glyph.supersampleNeeded = box.supersampleNeeded;
    }
    if (left == int.max)
        return fontOk(glyph);
    // Each layer box lies within maxRasterCoordinate of the pen, so the union's extent fits an int.
    glyph.bearingX = left;
    glyph.bearingY = top;
    glyph.width = right - left;
    glyph.height = top - bottom;
    return fontOk(glyph);
}

/**
Draws glyph `gid`'s `COLR` layers at `ppem` into `region` (FTR5): the box
`colrMeasure` reports is cleared to transparent, then each layer's
coverage is composited source-over in its colour from palette `palette`,
or in `foreground` for entry `0xFFFF`. Colours are premultiplied before
compositing, every product rounded to the nearest byte, so equal inputs
give byte-identical output (FTR6).

The region and the workspace must be at least the sizes `colrMeasure`
reports; short storage is `limitExceeded` naming `callerStorage`. A
palette past `CPAL`'s count, or a layer's entry past its entries, is
`indexOutOfRange`; a face without `CPAL` whose layers name a palette entry
is `missingTable`. A glyph without layers draws nothing and reports
`source` `none`. The errors of `colrMeasure` and `rasterizeGlyph` apply.
Cost: two outline decodes per layer, then its coverage once.
*/
FontResult!ColourGlyph rasterizeColrGlyph(in Instance inst, uint gid, Ppem ppem, uint palette,
    Colour foreground, scope ColourRegion region, return scope ColourWorkspace ws)
{
    const measured = colrMeasure(inst, gid, ppem, ws.raster);
    if (measured.hasError || measured.value.source == ColourSource.none || measured.value.empty)
        return measured;
    ColourGlyph glyph = measured.value;
    ulong needed;
    if (!regionHolds(region, glyph.width, glyph.height, needed))
        return fontErr!ColourGlyph(callerStorageError(needed));
    if (ws.coverage.length < glyph.coverageNeeded)
        return fontErr!ColourGlyph(callerStorageError(glyph.coverageNeeded));

    const run = layerRun(inst.face, gid).value;
    // Resolve every colour before drawing, so a bad entry leaves the region untouched.
    bool needsPalette;
    foreach (i; 0 .. run.count)
        needsPalette |= run.layer(i).paletteEntry != foregroundPaletteEntry;
    const found = needsPalette ? palettes(inst.face) : fontOk(Palettes.init);
    if (found.hasError)
        return fontErr!ColourGlyph(found.error);
    const p = found.value;
    if (needsPalette)
    {
        foreach (i; 0 .. run.count)
        {
            const entry = run.layer(i).paletteEntry;
            if (entry != foregroundPaletteEntry)
            {
                const c = colourOf(p, palette, entry);
                if (c.hasError)
                    return fontErr!ColourGlyph(c.error);
            }
        }
    }

    foreach (y; 0 .. glyph.height)
        region.data[y * region.stride .. y * region.stride + 4 * glyph.width] = 0;
    foreach (i; 0 .. run.count)
    {
        const layer = run.layer(i);
        const colour = layer.paletteEntry == foregroundPaletteEntry
            ? foreground : colourOf(p, palette, layer.paletteEntry).value;
        const m = rasterMeasure(inst, layer.glyph, ppem, ws.raster);
        if (m.hasError)
            return fontErr!ColourGlyph(m.error);
        const box = m.value;
        if (box.empty || box.width == 0 || box.height == 0)
            continue;
        auto coverage = RasterRegion(ws.coverage, box.width, box.width, box.height);
        const drawn = rasterizeGlyph(inst, layer.glyph, ppem, coverage, ws.raster);
        if (drawn.hasError)
            return fontErr!ColourGlyph(drawn.error);
        composite(region, glyph, box, ws.coverage, colour);
    }
    return fontOk(glyph);
}

/// Composites `coverage` (`box`-sized) in `colour` source-over into `region` at `box`'s place in `glyph`.
private void composite(scope ColourRegion region, in ColourGlyph glyph, in RasterGlyph box,
    scope const(ubyte)[] coverage, Colour colour)
{
    uint mul(uint a, uint b) => (a * b + 127) / 255;
    const r = mul(colour.red, colour.alpha), g = mul(colour.green, colour.alpha),
        b = mul(colour.blue, colour.alpha);
    const dx = box.bearingX - glyph.bearingX, dy = glyph.bearingY - box.bearingY;
    foreach (y; 0 .. box.height)
    {
        auto row = region.data[(dy + y) * region.stride + 4 * dx .. (dy + y) * region.stride + 4 * (dx + box.width)];
        foreach (x; 0 .. box.width)
        {
            const cov = coverage[y * box.width + x];
            if (cov == 0)
                continue;
            const sa = mul(colour.alpha, cov), keep = 255 - sa;
            auto px = row[4 * x .. 4 * x + 4];
            px[0] = cast(ubyte)(mul(r, cov) + mul(px[0], keep));
            px[1] = cast(ubyte)(mul(g, cov) + mul(px[1], keep));
            px[2] = cast(ubyte)(mul(b, cov) + mul(px[2], keep));
            px[3] = cast(ubyte)(sa + mul(px[3], keep));
        }
    }
}
