/**
Ligature carets from `GDEF` (`docs/specs/font/SPEC.md` FTS10).

`ligatureCarets` resolves the caret records of one shaped glyph at an
instance: format 1 coordinates as stored, format 2 contour points
through the M3 outline decoder, and format 3 Device or VariationIndex
tables through the `GDEF` item variation store. Each caret keeps its
record order and its provenance. A glyph with no caret records is
reported as absent, an unknown caret format as `unsupportedVersion`,
malformed data as its table error; nothing is synthesized.
*/
module sparkles.font.carets;

import sparkles.font.bytes : be16, bes16, fits;
import sparkles.font.coverage : Coverage;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult,
    fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.gdef : gdefVariationStore;
import sparkles.font.instance : Instance, InstanceSize;
import sparkles.font.outlines : glyphPoint;
import sparkles.font.tables : locate;
import sparkles.font.units : DesignValue, Ppem;
import sparkles.font.variations : deviceDelta, DeviceDelta;

@safe pure nothrow @nogc:

private enum gdefTag = Tag("GDEF");

/// How a caret's coordinate was obtained (FTS10).
enum CaretProvenance : ubyte
{
    /// Format 1: the stored coordinate.
    coordinate,
    /// Format 2: a contour point of the glyph's outline.
    contourPoint,
    /// Format 3: a coordinate with a Device or VariationIndex table.
    deviceTable,
}

/// One ligature caret of a glyph, in glyph pen coordinates (FTS10).
struct LigatureCaret
{
    @safe pure nothrow @nogc:

    /// The caret position along the shaping direction, in design units.
    DesignValue coordinate;
    /// The glyph this caret belongs to.
    uint glyphId;
    /// The source cluster the glyph was shaped from.
    uint cluster;
    /// The caret's index in the glyph's record list.
    ushort recordIndex;
    CaretProvenance provenance;
    /// Format 3: the Device/VariationIndex resolution behind `coordinate`.
    DeviceDelta device;
    /// Whether a Device or VariationIndex table was attached (format 3).
    bool hasDevice;
}

/// The carets of one glyph: `present` false when the font has none.
struct LigatureCarets
{
    @safe pure nothrow @nogc:

    bool present;
    size_t count;
}

/**
The ligature carets of glyph `gid`, shaped from source cluster
`cluster`, at `inst` (FTS10), written to `out` in record order.
`horizontal` selects the pen axis a contour point resolves along.
Capacity exhaustion is `limitExceeded` naming `callerStorage`; on any
error nothing is written (FTS7's uncommitted-output rule), so every
caret is resolved once to check it and again to write it. Costs
O(log n + c) for `c` carets, each a contour point's outline decode at
most (`glyphPoint`).
*/
FontResult!LigatureCarets ligatureCarets(in Instance inst, uint gid, uint cluster,
    bool horizontal, scope LigatureCaret[] out_)
{
    const face = inst.face;
    auto at = locate(face, gdefTag);
    if (at.hasError)
    {
        if (at.error.kind == FontErrorKind.missingTable)
            return fontOk(LigatureCarets.init);
        return fontErr!LigatureCarets(at.error);
    }
    const d = at.value.data;
    const start = at.value.start;
    if (d.length < 12)
        return fontErr!LigatureCarets(tableError(FontErrorKind.truncated, gdefTag, start,
            d.length));
    const listAt = be16(d, 8);
    if (listAt == 0)
        return fontOk(LigatureCarets.init);
    if (!fits(d.length, listAt, 4))
        return fontErr!LigatureCarets(tableError(FontErrorKind.truncated, gdefTag, start, listAt));
    const coverageAt = listAt + be16(d, listAt);
    const coverage = Coverage.read(d, gdefTag, start, coverageAt);
    const index = coverage.index(gid);
    if (index.hasError)
        return fontErr!LigatureCarets(index.error);
    if (!index.value.covered)
        return fontOk(LigatureCarets.init);
    const glyphCount = be16(d, listAt + 2);
    if (index.value.index >= glyphCount)
        return fontErr!LigatureCarets(tableError(FontErrorKind.badValue, gdefTag, start,
            listAt + 2));
    if (!fits(d.length, listAt + 4, 2UL * glyphCount))
        return fontErr!LigatureCarets(tableError(FontErrorKind.truncated, gdefTag, start,
            listAt + 4));
    const glyphAt = listAt + be16(d, listAt + 4 + 2 * index.value.index);
    if (!fits(d.length, glyphAt, 2))
        return fontErr!LigatureCarets(tableError(FontErrorKind.truncated, gdefTag, start, glyphAt));
    const caretCount = be16(d, glyphAt);
    if (caretCount == 0)
        return fontOk(LigatureCarets.init);
    if (!fits(d.length, glyphAt + 2, 2UL * caretCount))
        return fontErr!LigatureCarets(tableError(FontErrorKind.truncated, gdefTag, start,
            glyphAt + 2));
    if (caretCount > out_.length)
        return fontErr!LigatureCarets(callerStorageError(caretCount, gdefTag, start, glyphAt));

    const store = gdefVariationStore(face, inst.axisCount);
    const ppem = inst.size.unit == InstanceSize.Unit.pixels ? inst.size.ppem : Ppem.init;
    foreach (pass; 0 .. 2)
    foreach (i; 0 .. caretCount)
    {
        const caretAt = glyphAt + be16(d, glyphAt + 2 + 2 * i);
        if (!fits(d.length, caretAt, 4))
            return fontErr!LigatureCarets(tableError(FontErrorKind.truncated, gdefTag, start,
                caretAt));
        const format = be16(d, caretAt);
        LigatureCaret caret;
        caret.glyphId = gid;
        caret.cluster = cluster;
        caret.recordIndex = cast(ushort) i;
        switch (format)
        {
            case 1:
                caret.coordinate = DesignValue.fromUnits(bes16(d, caretAt + 2),
                    inst.unitsPerEm);
                caret.provenance = CaretProvenance.coordinate;
                break;
            case 2:
            {
                const pointIndex = be16(d, caretAt + 2);
                const point = glyphPoint(inst, gid, pointIndex);
                if (point.hasError)
                    return fontErr!LigatureCarets(point.error);
                caret.coordinate = DesignValue(horizontal ? point.value.x : point.value.y,
                    inst.unitsPerEm);
                caret.provenance = CaretProvenance.contourPoint;
                break;
            }
            case 3:
            {
                if (!fits(d.length, caretAt, 6))
                    return fontErr!LigatureCarets(tableError(FontErrorKind.truncated,
                        gdefTag, start, caretAt));
                auto value = DesignValue.fromUnits(bes16(d, caretAt + 2), inst.unitsPerEm);
                const deviceOffset = be16(d, caretAt + 4);
                caret.provenance = CaretProvenance.deviceTable;
                if (deviceOffset != 0)
                {
                    const resolved = deviceDelta(d, gdefTag, start, caretAt + deviceOffset,
                        store, inst.coords, inst.unitsPerEm, ppem);
                    if (resolved.hasError)
                        return fontErr!LigatureCarets(resolved.error);
                    caret.hasDevice = true;
                    caret.device = resolved.value;
                    const raw = value.raw + resolved.value.variation.raw;
                    value = DesignValue(raw, inst.unitsPerEm);
                }
                caret.coordinate = value;
                break;
            }
            default:
                return fontErr!LigatureCarets(tableError(FontErrorKind.unsupportedVersion,
                    gdefTag, start, caretAt));
        }
        // The first pass only checks: an error must leave `out_` as it was.
        if (pass == 1)
            out_[i] = caret;
    }
    return fontOk(LigatureCarets(true, caretCount));
}
