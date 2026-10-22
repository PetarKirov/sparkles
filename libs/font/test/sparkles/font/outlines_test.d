/**
M3 outline tests (FTO1–FTO5, FTI6) over fixture fonts: simple and
composite `glyf` glyphs, `gvar` phantom points, cycles, overlap flags
and `CFF` charstrings with a local subroutine.
*/
module sparkles.font.outlines_test;

import sparkles.font;
import sparkles.font.fixtures;

private Instance instanceOf(const(ubyte)[] bytes, int wght = 0) @safe pure nothrow
{
    auto face = openFace(bytes).value;
    UserCoordinate[1] coords = [UserCoordinate(Tag("wght"), wght << 16)];
    return face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value),
        wght ? coords[] : null).value;
}

private OutlineWorkspace workspace(OutlinePoint[] points, bool[] onCurve, ushort[] ends)
    @safe pure nothrow @nogc
{
    OutlineWorkspace ws;
    ws.points = points;
    ws.onCurve = onCurve;
    ws.contourEnds = ends;
    return ws;
}

/// The font of `glyphs` (glyf/loca/hmtx around the minimal tables).
private const(ubyte)[] glyfFont(const(ubyte[])[] glyphs, const(TableData)[] extra = null)
    @safe pure nothrow
{
    uint[2][] metrics;
    foreach (_; glyphs)
        metrics ~= [500u, 0u];
    auto tables = minimalTables(cast(uint) glyphs.length);
    tables ~= TableData("hhea", hhea(cast(uint) glyphs.length));
    tables ~= TableData("hmtx", hmtx(metrics));
    tables ~= TableData("loca", locaTable(glyphs));
    tables ~= TableData("glyf", glyfTable(glyphs));
    tables ~= extra;
    return sfnt(tables);
}

private OutlineSegment[64] segmentsOf(const(ubyte)[] bytes, uint gid, int wght = 0)
    @safe pure nothrow
{
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const r = glyphOutline(instanceOf(bytes, wght), gid, segments[], ws);
    assert(r.hasValue);
    return segments;
}

private size_t segmentCount(const(ubyte)[] bytes, uint gid, int wght = 0) @safe pure nothrow
{
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const r = glyphOutline(instanceOf(bytes, wght), gid, segments[], ws);
    assert(r.hasValue);
    return r.value.segmentCount;
}

@("outlines.glyf.simpleSegments")
@safe pure nothrow
unittest
{
    // A triangle and a quadratic contour, in font units (raw = units << 16).
    const glyphs = [
        simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]),
        simpleGlyph([[0, 0, 1], [50, 100, 0], [100, 0, 1]]),
    ];
    const bytes = glyfFont(glyphs);
    const tri = segmentsOf(bytes, 0);
    assert(tri[0].kind == SegmentKind.moveTo && tri[0].end == OutlinePoint.fromUnits(0, 0));
    assert(tri[1].kind == SegmentKind.lineTo && tri[1].end == OutlinePoint.fromUnits(100, 0));
    assert(tri[2].kind == SegmentKind.lineTo && tri[2].end == OutlinePoint.fromUnits(100, 100));
    assert(tri[3].kind == SegmentKind.lineTo && tri[3].end == OutlinePoint.fromUnits(0, 0));
    assert(tri[4].kind == SegmentKind.close);
    const quad = segmentsOf(bytes, 1);
    assert(quad[0].kind == SegmentKind.moveTo);
    assert(quad[1].kind == SegmentKind.quadTo
        && quad[1].control1 == OutlinePoint.fromUnits(50, 100)
        && quad[1].end == OutlinePoint.fromUnits(100, 0));
    assert(quad[2].kind == SegmentKind.lineTo && quad[2].end == OutlinePoint.fromUnits(0, 0));
    assert(quad[3].kind == SegmentKind.close);
}

@("outlines.glyf.impliedMidpoints")
@safe pure nothrow
unittest
{
    // Two off-curve points: the start is their implied midpoint.
    const bytes = glyfFont([simpleGlyph([[0, 0, 0], [100, 100, 0]])]);
    const segs = segmentsOf(bytes, 0);
    assert(segs[0].kind == SegmentKind.moveTo && segs[0].end == OutlinePoint.fromUnits(50, 50));
    assert(segs[1].kind == SegmentKind.quadTo && segs[1].control1 == OutlinePoint.fromUnits(0, 0));
    assert(segs[2].kind == SegmentKind.quadTo
        && segs[2].control1 == OutlinePoint.fromUnits(100, 100));
    assert(segs[3].kind == SegmentKind.close);
}

@("outlines.glyf.compositeTransform")
@safe pure nothrow
unittest
{
    const base = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    // Scaled by 1/2 (F2Dot14 8192) and shifted by (10, 20).
    const composite = compositeGlyph([CompositePart(1, 0x000B, 10, 20, [8192])]);
    const bytes = glyfFont([simpleGlyph([[0, 0, 1]]), base, composite]);
    const segs = segmentsOf(bytes, 2);
    assert(segs[0].end == OutlinePoint.fromUnits(10, 20));
    assert(segs[1].end == OutlinePoint.fromUnits(60, 20));
    assert(segs[2].end == OutlinePoint.fromUnits(60, 70));
}

@("outlines.glyf.cycle")
@safe pure nothrow
unittest
{
    const cyclic = compositeGlyph([CompositePart(1, 0x0003, 0, 0)]);
    const bytes = glyfFont([simpleGlyph([[0, 0, 1]]), cyclic]);
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const r = glyphOutline(instanceOf(bytes), 1, segments[], ws);
    assert(r.hasError && r.error.kind == FontErrorKind.cycle);
}

@("outlines.glyf.callerStorage")
@safe pure nothrow
unittest
{
    const bytes = glyfFont([simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]])]);
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[2] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const r = glyphOutline(instanceOf(bytes), 0, segments[], ws);
    assert(r.hasError && r.error.kind == FontErrorKind.limitExceeded
        && r.error.limit == FontLimit.callerStorage && r.error.needed == 5);
}

@("outlines.glyf.overlapFlags")
@safe pure nothrow
unittest
{
    const plain = simpleGlyph([[0, 0, 1], [10, 0, 1]]);
    const flagged = simpleGlyph([[0, 0, 1], [10, 0, 1]], true);
    // OVERLAP_COMPOUND is 0x0400; 0x0800 is SCALED_COMPONENT_OFFSET.
    const compound = compositeGlyph([CompositePart(0, 0x0403, 0, 0)]);
    const scaledOffset = compositeGlyph([CompositePart(0, 0x0803, 0, 0)]);
    const bytes = glyfFont([plain, flagged, compound, scaledOffset]);
    const face = openFace(bytes).value;
    assert(!glyphOverlaps(face, 0).value);
    assert(glyphOverlaps(face, 1).value);
    assert(glyphOverlaps(face, 2).value);
    assert(!glyphOverlaps(face, 3).value);

    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    assert(glyphOutline(instanceOf(bytes), 2, segments[], ws).value.overlap);
    assert(!glyphOutline(instanceOf(bytes), 3, segments[], ws).value.overlap);
}

/// SCALED_COMPONENT_OFFSET passes the offset through the component's matrix.
@("outlines.glyf.scaledComponentOffset")
@safe pure nothrow
unittest
{
    const square = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    // Scale 0.5 (WE_HAVE_A_SCALE), offset (100, 0).
    const unscaled = compositeGlyph([CompositePart(0, 0x000B, 100, 0, [8192])]);
    const scaled = compositeGlyph([CompositePart(0, 0x080B, 100, 0, [8192])]);
    const bytes = glyfFont([square, unscaled, scaled]);
    assert(segmentsOf(bytes, 1)[0].end == OutlinePoint.fromUnits(100, 0));
    assert(segmentsOf(bytes, 2)[0].end == OutlinePoint.fromUnits(50, 0));
}

/// Point-matched placement numbers the composite's own points, from its first.
@("outlines.glyf.pointMatchingNested")
@safe pure nothrow
unittest
{
    const s = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    const t = simpleGlyph([[500, 500, 1], [600, 500, 1], [600, 600, 1]]);
    // C: S, then S again with its point 0 moved onto C's point 1.
    const c = compositeGlyph([CompositePart(0, 0x0003, 0, 0), CompositePart(0, 0x0001, 1, 0)]);
    const p = compositeGlyph([CompositePart(1, 0x0003, 0, 0), CompositePart(2, 0x0003, 0, 0)]);
    const bytes = glyfFont([s, t, c, p]);
    assert(segmentsOf(bytes, 2)[5].end == OutlinePoint.fromUnits(100, 0));
    // Nested after T, C's second S still lands on C's own point 1.
    assert(segmentsOf(bytes, 3)[10].end == OutlinePoint.fromUnits(100, 0));
}

/// Point numbers are unsigned: a byte argument of 200 is point 200, not −56.
@("outlines.glyf.unsignedPointNumbers")
@safe pure nothrow
unittest
{
    GlyphPoint[] zigzag;
    foreach (i; 0 .. 201)
        zigzag ~= [i, (i % 2) * 10, 1];
    const s = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    const bytes = glyfFont([simpleGlyph(zigzag), s,
        compositeGlyph([CompositePart(0, 0x0003, 0, 0), CompositePart(1, 0x0000, 200, 0)])]);
    auto points = new OutlinePoint[256];
    auto onCurve = new bool[256];
    auto ends = new ushort[4];
    auto segments = new OutlineSegment[256];
    const r = glyphOutline(instanceOf(bytes), 2, segments, workspace(points, onCurve, ends));
    assert(r.hasValue);
    // Zigzag point 200 is (200, 0).
    assert(segments[r.value.segmentCount - 5].end == OutlinePoint.fromUnits(200, 0));
}

/// Composite point numbers are 16-bit: a glyph past 65,535 points is malformed.
@("outlines.glyf.pointCountOverflow")
@safe pure nothrow
unittest
{
    GlyphPoint[] many;
    foreach (i; 0 .. 200)
        many ~= [i, (i % 2) * 10, 1];
    CompositePart[] parts;
    foreach (_; 0 .. 400)
        parts ~= CompositePart(0, 0x0003, 0, 0);
    const bytes = glyfFont([simpleGlyph(many), compositeGlyph(parts)]);
    auto points = new OutlinePoint[100_000];
    auto onCurve = new bool[100_000];
    auto ends = new ushort[1_000];
    auto segments = new OutlineSegment[200_000];
    const r = glyphOutline(instanceOf(bytes), 1, segments, workspace(points, onCurve, ends));
    assert(r.hasError && r.error.kind == FontErrorKind.badValue);
}

/// FTB3: composite depth 8 and 512 components succeed; one more is `limitExceeded`.
@("outlines.glyf.compositeLimits")
@safe pure nothrow
unittest
{
    const s = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    const(ubyte)[][] chain = [s];
    foreach (i; 0 .. 9)
        chain ~= compositeGlyph([CompositePart(cast(uint) i, 0x0003, 0, 0)]);
    const deep = glyfFont(chain);
    auto points = new OutlinePoint[2_048];
    auto onCurve = new bool[2_048];
    auto ends = new ushort[1_024];
    auto segments = new OutlineSegment[4_096];
    auto ws = workspace(points, onCurve, ends);
    assert(glyphOutline(instanceOf(deep), 8, segments, ws).hasValue);
    const tooDeep = glyphOutline(instanceOf(deep), 9, segments, ws);
    assert(tooDeep.hasError && tooDeep.error.kind == FontErrorKind.limitExceeded
        && tooDeep.error.limit == FontLimit.compositeDepth);

    CompositePart[] parts;
    foreach (_; 0 .. 512)
        parts ~= CompositePart(0, 0x0003, 0, 0);
    const wide = glyfFont([s, compositeGlyph(parts),
        compositeGlyph(parts ~ CompositePart(0, 0x0003, 0, 0))]);
    assert(glyphOutline(instanceOf(wide), 1, segments, ws).hasValue);
    const tooWide = glyphOutline(instanceOf(wide), 2, segments, ws);
    assert(tooWide.hasError && tooWide.error.kind == FontErrorKind.limitExceeded
        && tooWide.error.limit == FontLimit.compositeComponents);
}

/// FTB5: a two-glyph composite cycle is `cycle`, like a self-reference.
@("outlines.glyf.twoGlyphCycle")
@safe pure nothrow
unittest
{
    const a = compositeGlyph([CompositePart(1, 0x0003, 0, 0)]);
    const b = compositeGlyph([CompositePart(0, 0x0003, 0, 0)]);
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const r = glyphOutline(instanceOf(glyfFont([a, b])), 0, segments[], ws);
    assert(r.hasError && r.error.kind == FontErrorKind.cycle);
}

/// The vertical phantom points come from `vmtx`: the top at yMax + tsb, the bottom one advance height below.
@("outlines.glyf.verticalPhantom")
@safe pure nothrow
unittest
{
    const glyph = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    OutlinePoint[4] phantomOf(const(ubyte)[] bytes)
    {
        OutlinePoint[64] points;
        bool[64] onCurve;
        ushort[16] ends;
        OutlineSegment[64] segments;
        const r = glyphOutline(instanceOf(bytes), 0, segments[], workspace(points[], onCurve[], ends[]));
        assert(r.hasValue && r.value.hasPhantom);
        return r.value.phantom;
    }
    const withVmtx = phantomOf(glyfFont([glyph], [TableData("vhea", vheaTable(1)),
        TableData("vmtx", vmtxTable([[1200, 50]]))]));
    assert(withVmtx[2].y == 150L << 16 && withVmtx[3].y == -1050L << 16);
    // Without vmtx: tsb 0 and an advance of unitsPerEm (2048), as HarfBuzz defaults.
    const without = phantomOf(glyfFont([glyph]));
    assert(without[2].y == 100L << 16 && without[3].y == -1948L << 16);
}

@("outlines.gvar.pointsAndPhantom")
@safe pure nothrow
unittest
{
    const glyph = simpleGlyph([[0, 0, 1], [100, 0, 1]]);
    // Points 0–1 move +10 in x; phantom point 1 (index 3) moves +40.
    const data = glyphVarData([16_384], [10, 10, 0, 40, 0, 0],
        [0, 0, 0, 0, 0, 0]);
    auto tables = minimalTables(1);
    tables ~= TableData("hhea", hhea(1));
    tables ~= TableData("hmtx", hmtx([[500, 0]]));
    tables ~= TableData("loca", locaTable([glyph]));
    tables ~= TableData("glyf", glyfTable([glyph]));
    tables ~= TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)]));
    tables ~= TableData("gvar", gvarTable(1, data));
    const bytes = sfnt(tables);

    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const inst = instanceOf(bytes, 1);
    const r = glyphOutline(inst, 0, segments[], ws);
    assert(r.hasValue && r.value.hasPhantom);
    assert(segments[0].end == OutlinePoint.fromUnits(10, 0));
    assert(segments[1].end == OutlinePoint.fromUnits(110, 0));
    // The varied advance is the phantom span: 500 + 40.
    const phantom = r.value.phantom;
    assert(phantom[1].x - phantom[0].x == 540L << 16);
    const point = glyphPoint(inst, 0, 1);
    assert(point.hasValue && point.value == OutlinePoint.fromUnits(110, 0));
    // FTO5 through metrics: the no-HVAR advance is the phantom span.
    assert(inst.advance(0).value.design.raw == 540L << 16);
    // FTO4: the segment kinds at the extreme equal the default's.
    assert(segmentCount(bytes, 0, 1) == segmentCount(bytes, 0, 0));
    const kindsDefault = segmentsOf(bytes, 0);
    assert(kindsDefault[0].kind == segments[0].kind && kindsDefault[1].kind == segments[1].kind);
}

// ---------------------------------------------------------------------------
// CFF
// ---------------------------------------------------------------------------

/// OpenType gvar header: glyphCount precedes flags; offsets are relative to the data array.
private ubyte[] variationTable(const(ubyte[])[] glyphData, bool longOffsets = false,
    ushort axes = 1) @safe pure nothrow
{
    const dataAt = cast(uint)(20 + (longOffsets ? 4 : 2) * (glyphData.length + 1));
    auto bytes = u16(1) ~ u16(0) ~ u16(axes) ~ u16(0) ~ u32(dataAt)
        ~ u16(cast(uint) glyphData.length) ~ u16(longOffsets ? 1 : 0) ~ u32(dataAt);
    ubyte[] body;
    foreach (data; glyphData)
    {
        bytes ~= longOffsets ? u32(cast(uint) body.length) : u16(cast(uint)(body.length / 2));
        body ~= data;
        if (body.length % 2)
            body ~= 0;
    }
    bytes ~= longOffsets ? u32(cast(uint) body.length) : u16(cast(uint)(body.length / 2));
    return bytes ~ body;
}

/// One embedded-peak `gvar` tuple over every point: its serialized x and y series, then `padding` bytes.
private struct GvarTuple
{
    short peak;
    const(ubyte)[] series;
    size_t padding;
}

/// One glyph's `gvar` data of `tuples`, `reserved` or-ed into the tuple count.
private ubyte[] gvarGlyphData(const(GvarTuple)[] tuples, uint reserved = 0) @safe pure nothrow
{
    ubyte[] headers = u16(cast(uint) tuples.length | reserved) ~ u16(cast(uint)(4 + 6 * tuples.length));
    ubyte[] data;
    foreach (tuple; tuples)
    {
        headers ~= u16(cast(uint)(tuple.series.length + tuple.padding)) ~ u16(0x8000) ~ u16(cast(ushort) tuple.peak);
        data ~= tuple.series;
        data.length += tuple.padding;
    }
    return headers ~ data;
}

/// A two-point glyph (six with the phantoms) varied by `glyphData` along wght.
private const(ubyte)[] gvarFont(const(ubyte)[] glyphData) @safe pure nothrow
{
    const glyph = simpleGlyph([[0, 0, 1], [100, 0, 1]]);
    return glyfFont([glyph], [TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", gvarTable(1, glyphData))]);
}

/// The `gvar` tuple walk: reserved count bits, `variationDataSize`, any tuple count, 32-bit deltas, bad runs.
@("outlines.gvar.tupleData")
@safe pure nothrow
unittest
{
    // Six byte deltas moving both outline points by dx, then six zero y deltas.
    ubyte[] series(byte dx) => u8(0x05) ~ u8(cast(ubyte) dx) ~ u8(cast(ubyte) dx) ~ u8(0) ~ u8(0) ~ u8(0) ~ u8(0)
        ~ u8(0x85);
    enum short one = 16_384;
    long movedX(const(ubyte)[] bytes) => segmentsOf(bytes, 0, 1)[0].end.x >> 16;

    // Bits 0x7000 of the tuple count are reserved, not part of it.
    assert(movedX(gvarFont(gvarGlyphData([GvarTuple(one, series(10))], 0x7000))) == 10);
    // The next tuple's data starts after variationDataSize bytes, padding included.
    assert(movedX(gvarFont(gvarGlyphData([GvarTuple(one, series(10), 3), GvarTuple(one, series(5))]))) == 15);
    // More tuples than any fixed table holds.
    GvarTuple[] many;
    foreach (_; 0 .. 70)
        many ~= GvarTuple(one, series(1));
    assert(movedX(gvarFont(gvarGlyphData(many))) == 70);
    // 0xC0 runs carry 32-bit deltas.
    const longs = u8(0xC1) ~ u32(70_000) ~ u32(70_000) ~ u8(0x83) ~ u8(0x85);
    assert(movedX(gvarFont(gvarGlyphData([GvarTuple(one, longs)]))) == 70_000);

    // A run past the point count, and a tuple whose data passes the glyph's, are errors.
    const overshoot = u8(0x07) ~ new ubyte[8] ~ u8(0x85);
    assert(outlineError(gvarFont(gvarGlyphData([GvarTuple(one, overshoot)])), 0, 1).kind == FontErrorKind.badValue);
    auto tooLong = gvarGlyphData([GvarTuple(one, series(10))]);
    tooLong[4 .. 6] = u16(200);
    assert(outlineError(gvarFont(tooLong), 0, 1).kind == FontErrorKind.truncated);
}

/// Both legal offset widths produce the same varied outline and phantom advance.
@("outlines.gvar.specificationHeader")
@safe pure nothrow
unittest
{
    const glyph = simpleGlyph([[0, 0, 1], [100, 0, 1]]);
    // Six points, including the phantoms: 13 bytes per packed delta series.
    const data = u16(1) ~ u16(10) ~ u16(26) ~ u16(0x8000) ~ u16(16_384)
        ~ gvarDeltaSeries([10, 10, 0, 40, 0, 0]) ~ gvarDeltaSeries([0, 0, 0, 0, 0, 0]);
    foreach (longOffsets; [false, true])
    {
        const bytes = glyfFont([glyph], [
            TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
            TableData("gvar", variationTable([data], longOffsets)),
        ]);
        const segs = segmentsOf(bytes, 0, 1);
        assert(segs[0].end == OutlinePoint.fromUnits(10, 0));
        assert(instanceOf(bytes, 1).advance(0).value.design.raw == 540L << 16);
    }
}

/// An inconsistent axis count is a table error, never a fixed-array bounds failure.
@("outlines.gvar.rejectAxisCount")
@safe pure nothrow
unittest
{
    foreach (axes; [65, 2])
    {
        ubyte[] peaks;
        foreach (_; 0 .. axes)
            peaks ~= u16(16_384);
        const data = u16(1) ~ u16(cast(uint)(8 + peaks.length)) ~ u16(26)
            ~ u16(0x8000) ~ peaks ~ gvarDeltaSeries([10, 10, 0, 0, 0, 0])
            ~ gvarDeltaSeries([0, 0, 0, 0, 0, 0]);
        const bytes = glyfFont([simpleGlyph([[0, 0, 1], [100, 0, 1]])], [
            TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
            TableData("gvar", variationTable([data], false, cast(ushort) axes)),
        ]);
        OutlinePoint[64] points;
        bool[64] on;
        ushort[16] ends;
        OutlineSegment[64] segments;
        const r = glyphOutline(instanceOf(bytes, 1), 0, segments[],
            workspace(points[], on[], ends[]));
        assert(r.hasError && r.error.kind == FontErrorKind.badValue
            && r.error.tag == Tag("gvar"));
    }
}

/// Shared points belong to the serialized data, after all tuple headers.
@("outlines.gvar.sharedSerializedPoints")
@safe pure nothrow
unittest
{
    const zeros = gvarDeltaSeries([0, 0, 0, 0, 0, 0]);
    const data = u16(0x8002) ~ u16(16)
        ~ u16(26) ~ u16(0x8000) ~ u16(16_384)
        ~ u16(26) ~ u16(0x8000) ~ u16(16_384)
        ~ [cast(ubyte) 0] // shared list: every point
        ~ gvarDeltaSeries([10, 10, 0, 0, 0, 0]) ~ zeros
        ~ gvarDeltaSeries([20, 20, 0, 0, 0, 0]) ~ zeros;
    const bytes = glyfFont([simpleGlyph([[0, 0, 1], [100, 0, 1]])], [
        TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", variationTable([data])),
    ]);
    const segs = segmentsOf(bytes, 0, 1);
    assert(segs[0].end == OutlinePoint.fromUnits(30, 0));
    assert(segs[1].end == OutlinePoint.fromUnits(130, 0));
}

/// Sparse tuples infer omitted points from original coordinates, independently per tuple.
@("outlines.gvar.sparseInterpolation")
@safe pure nothrow
unittest
{
    const glyph = simpleGlyph([[0, 0, 1], [50, 100, 1], [100, 0, 1], [200, -100, 1]]);
    // Private packed list: two points, one byte run, point numbers 0 and 2.
    const list = [cast(ubyte) 2, cast(ubyte) 1, cast(ubyte) 0, cast(ubyte) 2];
    const tuple1 = list ~ gvarDeltaSeries([10, 30]) ~ gvarDeltaSeries([20, 40]);
    const tuple2 = list ~ gvarDeltaSeries([30, 10]) ~ gvarDeltaSeries([-20, -40]);
    const data = u16(2) ~ u16(16)
        ~ u16(cast(uint) tuple1.length) ~ u16(0xA000) ~ u16(16_384)
        ~ u16(cast(uint) tuple2.length) ~ u16(0xA000) ~ u16(16_384) ~ tuple1 ~ tuple2;
    const bytes = glyfFont([glyph], [
        TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", variationTable([data])),
    ]);
    const segs = segmentsOf(bytes, 0, 1);
    assert(segs[0].end == OutlinePoint.fromUnits(40, 0));
    assert(segs[1].end == OutlinePoint.fromUnits(90, 100));
    assert(segs[2].end == OutlinePoint.fromUnits(140, 0));
    assert(segs[3].end == OutlinePoint.fromUnits(240, -100));
    assert(instanceOf(bytes, 1).advance(0).value.design.raw == 500L << 16);
}

/// One touched point moves its whole contour, not untouched contours or phantom points.
@("outlines.gvar.sparseContoursAndPhantom")
@safe pure nothrow
unittest
{
    const glyph = contourGlyph([
        [[0, 0, 1], [50, 50, 1], [100, 100, 1]],
        [[0, 200, 1], [50, 250, 1]],
    ]);
    // Point 1 and phantom points 0, 1 (indices 5, 6).
    const list = cast(ubyte[])[3, 2, 1, 4, 1];
    const serialized = list ~ gvarDeltaSeries([10, 0, 40]) ~ gvarDeltaSeries([20, 0, 0]);
    const data = u16(1) ~ u16(10) ~ u16(cast(uint) serialized.length)
        ~ u16(0xA000) ~ u16(16_384) ~ serialized;
    const bytes = glyfFont([glyph], [
        TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", variationTable([data])),
    ]);
    const inst = instanceOf(bytes, 1);
    const expected = [OutlinePoint.fromUnits(10, 20), OutlinePoint.fromUnits(60, 70),
        OutlinePoint.fromUnits(110, 120), OutlinePoint.fromUnits(0, 200), OutlinePoint.fromUnits(50, 250)];
    foreach (i, point; expected)
        assert(glyphPoint(inst, 0, cast(uint) i).value == point);
    assert(inst.advance(0).value.design.raw == 540L << 16);
}

/// Composite tuples move components; child tuples run before scaling and nested placement.
@("outlines.gvar.compositeInstances")
@safe pure nothrow
unittest
{
    const base = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    const composite = compositeGlyph([
        CompositePart(0, 0x0023, 0, 0),
        CompositePart(0, 0x000B, 200, 0, [8192]),
    ]);
    const nested = compositeGlyph([CompositePart(1, 0x0003, 50, 0)]);
    const childData = u16(1) ~ u16(10) ~ u16(30) ~ u16(0x8000) ~ u16(16_384)
        ~ gvarDeltaSeries([4, 8, 12, 0, 0, 0, 0]) ~ gvarDeltaSeries([0, 0, 0, 0, 0, 0, 0]);
    const parentData = u16(1) ~ u16(10) ~ u16(26) ~ u16(0x8000) ~ u16(16_384)
        ~ gvarDeltaSeries([10, 20, 0, 40, 0, 0]) ~ gvarDeltaSeries([0, 30, 0, 0, 0, 0]);
    const bytes = glyfFont([base, composite, nested], [
        TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", variationTable([childData, parentData, null])),
    ]);
    const inst = instanceOf(bytes, 1);
    const expected = [OutlinePoint.fromUnits(14, 0), OutlinePoint.fromUnits(118, 0),
        OutlinePoint.fromUnits(122, 100), OutlinePoint.fromUnits(222, 30),
        OutlinePoint.fromUnits(274, 30), OutlinePoint.fromUnits(276, 80)];
    foreach (i, point; expected)
    {
        assert(glyphPoint(inst, 1, i).value == point);
        assert(glyphPoint(inst, 2, i).value == OutlinePoint(point.x + (50L << 16), point.y));
    }
    assert(inst.advance(1).value.design.raw == 540L << 16);
    assert(inst.advance(2).value.design.raw == 500L << 16);
    const bounds = glyphBounds(inst, 1).value;
    assert(bounds.xMin == 14L << 16 && bounds.xMax == 276L << 16 && bounds.yMax == 100L << 16);
}

/// USE_MY_METRICS selects the child's varied phantoms, not the parent's phantom deltas.
@("outlines.gvar.compositeMetrics")
@safe pure nothrow
unittest
{
    const base = simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]);
    const composite = compositeGlyph([CompositePart(0, 0x0203, 0, 0)]);
    const childData = u16(1) ~ u16(10) ~ u16(30) ~ u16(0x8000) ~ u16(16_384)
        ~ gvarDeltaSeries([0, 0, 0, 0, 40, 0, 0]) ~ gvarDeltaSeries([0, 0, 0, 0, 0, 0, 0]);
    const parentData = u16(1) ~ u16(10) ~ u16(22) ~ u16(0x8000) ~ u16(16_384)
        ~ gvarDeltaSeries([0, 0, 90, 0, 0]) ~ gvarDeltaSeries([0, 0, 0, 0, 0]);
    const bytes = glyfFont([base, composite], [
        TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", variationTable([childData, parentData])),
    ]);
    assert(instanceOf(bytes, 1).advance(1).value.design.raw == 540L << 16);
}

/// A charstring number in the 1-byte range, else the 28-form.
private ubyte[] csNum(int v) @safe pure nothrow
{
    if (v >= -107 && v <= 107)
        return [cast(ubyte)(v + 139)];
    return [cast(ubyte) 28, cast(ubyte)(v >> 8), cast(ubyte) v];
}

private const(ubyte)[] cffFont() @safe pure nothrow
{
    // Glyph 1: call subr 0 (moveto 10,10), then line to (110, 10), endchar.
    const subr = csNum(10) ~ csNum(10) ~ [cast(ubyte) 21, cast(ubyte) 11];
    const glyph1 = csNum(-107) ~ [cast(ubyte) 10] ~ csNum(100) ~ csNum(0)
        ~ [cast(ubyte) 5, cast(ubyte) 14];
    const glyph0 = [cast(ubyte) 14];
    auto tables = minimalTables(2);
    tables ~= TableData("CFF ", cffOutlineTable([glyph0, glyph1],
        dictInt(4) ~ [cast(ubyte) 19], [subr]));
    return sfnt(tables, 0x4F54_544F);
}

/// CFF2 INDEX has a uint32 count, including the empty INDEX's four zero bytes.
private ubyte[] cff2Index(const(ubyte[])[] objects) @safe pure nothrow
{
    auto data = u32(cast(uint) objects.length);
    if (objects.length == 0)
        return data;
    data ~= 1; // offSize
    uint offset = 1;
    foreach (object; objects)
    {
        data ~= cast(ubyte) offset;
        offset += object.length;
    }
    data ~= cast(ubyte) offset;
    foreach (object; objects)
        data ~= object;
    return data;
}

/// A valid CFF2 face uses 32-bit counts for global, charstring and font-dict indexes.
@("outlines.cff2.indexWidths")
@safe pure nothrow
unittest
{
    foreach (withSubroutine; [false, true])
    {
        // CFF2 subroutines end at EOF, without CFF1's return operator.
        const move = csNum(10) ~ csNum(20) ~ [cast(ubyte) 21];
        const globals = cff2Index(withSubroutine ? [move] : null);
        const glyph = (withSubroutine ? csNum(-107) ~ [cast(ubyte) 29] : move)
            ~ csNum(100) ~ csNum(0) ~ [cast(ubyte) 5];
        const strings = cff2Index([null, glyph]);
        const charAt = cast(int)(5 + 9 + globals.length);
        const fdAt = cast(int)(charAt + strings.length);
        const top = dictInt(charAt) ~ [cast(ubyte) 17] ~ dictInt(fdAt)
            ~ [cast(ubyte) 12, cast(ubyte) 36];
        const cff = [cast(ubyte) 2, cast(ubyte) 0, cast(ubyte) 5] ~ u16(9)
            ~ top ~ globals ~ strings ~ cff2Index([csNum(0) ~ csNum(0) ~ [cast(ubyte) 18]]);
        auto tables = minimalTables(2);
        tables ~= TableData("CFF2", cff);
        const bytes = sfnt(tables, 0x4F54_544F);
        assert(segmentCount(bytes, 0) == 0);
        const segs = segmentsOf(bytes, 1);
        assert(segs[0].end == OutlinePoint.fromUnits(10, 20));
        assert(segs[1].end == OutlinePoint.fromUnits(110, 20));
        assert(segs[2].end == segs[0].end && segs[3].kind == SegmentKind.close);
    }
}

@("outlines.cff.charstringWithSubr")
@safe pure nothrow
unittest
{
    const bytes = cffFont();
    const segs = segmentsOf(bytes, 1);
    assert(segs[0].kind == SegmentKind.moveTo && segs[0].end == OutlinePoint.fromUnits(10, 10));
    assert(segs[1].kind == SegmentKind.lineTo && segs[1].end == OutlinePoint.fromUnits(110, 10));
    assert(segs[2].kind == SegmentKind.lineTo && segs[2].end == OutlinePoint.fromUnits(10, 10));
    assert(segs[3].kind == SegmentKind.close);
}

/// Escaped operators use the Type 2 opcode numbers, not Type 1's or a compact list.
@("outlines.cff.arithmeticOpcodes")
@safe pure nothrow
unittest
{
    static struct Case
    {
        string name;
        int[] operands;
        ubyte opcode;
        long expected;
    }
    const cases = [
        Case("add", [10, 20], 10, 30L << 16),
        Case("sub", [10, 20], 11, -10L << 16),
        Case("div", [9, 2], 12, 294_912), // exactly 4.5
        Case("abs", [-10], 9, 10L << 16),
        Case("neg", [10], 14, -10L << 16),
        Case("sqrt", [9], 26, 3L << 16),
        Case("drop", [10, 20], 18, 10L << 16),
        Case("exch", [10, 20], 28, 10L << 16),
        Case("dup", [10], 27, 10L << 16),
        Case("and", [1, 2], 3, 1L << 16),
        Case("or", [0, 2], 4, 1L << 16),
        Case("not", [0], 5, 1L << 16),
        Case("eq", [2, 2], 15, 1L << 16),
        Case("mul", [3, 4], 24, 12L << 16),
        Case("ifelse", [1, 2, 3, 4], 22, 1L << 16),
        Case("index", [10, 20, 1], 29, 10L << 16),
        Case("index negative", [10, 20, -1], 29, 20L << 16),
        Case("roll", [10, 20, 30, 3, 1], 30, 20L << 16),
    ];
    foreach (c; cases)
    {
        ubyte[] glyph;
        foreach (operand; c.operands)
            glyph ~= csNum(operand);
        // The move is emitted with the first line.
        glyph ~= cs([], 12, c.opcode, hmoveto) ~ cs([0, 10], rlineto, endchar);
        auto tables = minimalTables(1);
        tables ~= TableData("CFF ", cffOutlineTable([glyph]));
        const segs = segmentsOf(sfnt(tables, 0x4F54_544F), 0);
        assert(segs[0].end.x == c.expected && segs[0].end.y == 0, c.name);
    }
}

/// The error decoding glyph `gid` returns.
private FontError outlineError(const(ubyte)[] bytes, uint gid, int wght = 0) @safe pure nothrow
{
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    OutlineSegment[64] segments;
    auto ws = workspace(points[], onCurve[], ends[]);
    const r = glyphOutline(instanceOf(bytes, wght), gid, segments[], ws);
    assert(r.hasError);
    return r.error;
}

/// The charstring bytes of `values`, then the operator bytes `op`.
private ubyte[] cs(const(int)[] values, const(ubyte)[] op...) @safe pure nothrow
{
    ubyte[] r;
    foreach (v; values)
        r ~= csNum(v);
    return r ~ op;
}

/// A `CFF ` face of `charstrings` with an optional Private DICT and local subroutines.
private const(ubyte)[] cff1Font(const(ubyte)[][] charstrings, const(ubyte)[] privateDict = null,
    const(ubyte)[][] subrs = null) @safe pure nothrow
{
    auto tables = minimalTables(cast(uint) charstrings.length);
    tables ~= TableData("CFF ", cffOutlineTable(charstrings, privateDict, subrs));
    return sfnt(tables, 0x4F54_544F);
}

private enum ubyte rlineto = 5, callsubr = 10, ret = 11, endchar = 14, hstemhm = 18,
    hintmask = 19, rmoveto = 21, hmoveto = 22, vstemhm = 23;

/// `vstemhm` declares stems, and a hint mask counts the vstems its operands imply.
@("outlines.cff.stemHints")
@safe pure nothrow
unittest
{
    // 1 hstem + 1 vstem: a one-byte mask.
    const explicit = cs([0, 10], hstemhm) ~ cs([0, 10], vstemhm, hintmask, 0xC0);
    // 4 hstems + 6 implied vstems: a two-byte mask.
    const implied = cs([0, 10, 20, 10, 40, 10, 60, 10], hstemhm)
        ~ cs([0, 10, 20, 10, 40, 10, 60, 10, 80, 10, 100, 10], hintmask, 0xFF, 0x00);
    foreach (hints; [explicit, implied])
    {
        const segs = segmentsOf(cff1Font([[endchar], hints ~ cs([10, 20], rmoveto)
            ~ cs([100, 0], rlineto, endchar)]), 1);
        assert(segs[0].kind == SegmentKind.moveTo && segs[0].end == OutlinePoint.fromUnits(10, 20));
        assert(segs[1].end == OutlinePoint.fromUnits(110, 20));
    }
}

/// `hflex`, `hflex1` and `flex1` place every control point as the Type 2 specification draws them.
@("outlines.cff.flexOperators")
@safe pure nothrow
unittest
{
    static struct Case
    {
        string name;
        int[] operands;
        ubyte opcode;
        int[2][6] points; // c1 c2 e1 c3 c4 e2
    }
    const cases = [
        Case("hflex", [10, 10, 20, 10, 10, 10, 10], 34,
            [[10, 0], [20, 20], [30, 20], [40, 20], [50, 0], [60, 0]]),
        Case("hflex1", [10, 5, 10, 5, 10, 10, 10, -5, 10], 36,
            [[10, 5], [20, 10], [30, 10], [40, 10], [50, 5], [60, 0]]),
        Case("flex1 vertical", [30, 0, 0, 0, 0, 10, 0, 10, -20, 0, 7], 37,
            [[30, 0], [30, 0], [30, 10], [30, 20], [10, 20], [0, 27]]),
        Case("flex1 horizontal", [10, 2, 10, 0, 10, 0, 10, 0, 10, -1, 7], 37,
            [[10, 2], [20, 2], [30, 2], [40, 2], [50, 1], [57, 0]]),
        Case("flex", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 50], 35,
            [[1, 2], [4, 6], [9, 12], [16, 20], [25, 30], [36, 42]]),
    ];
    foreach (c; cases)
    {
        const segs = segmentsOf(cff1Font([[endchar], cs([0, 0], rmoveto)
            ~ cs(c.operands, 12, c.opcode, endchar)]), 1);
        OutlinePoint at(size_t k) => OutlinePoint.fromUnits(c.points[k][0], c.points[k][1]);
        assert(segs[1].kind == SegmentKind.cubicTo && segs[2].kind == SegmentKind.cubicTo, c.name);
        assert(segs[1].control1 == at(0) && segs[1].control2 == at(1) && segs[1].end == at(2), c.name);
        assert(segs[2].control1 == at(3) && segs[2].control2 == at(4) && segs[2].end == at(5), c.name);
    }
    // The flex family takes an exact operand count.
    const extra = cff1Font([[endchar], cs([0, 0], rmoveto) ~ cs([1, 10, 10, 20, 10, 10, 10, 10], 12, 34)]);
    assert(outlineError(extra, 1).kind == FontErrorKind.badValue);
}

/// A `seac`-style `endchar` draws the StandardEncoding base glyph, then the accent offset by (adx, ady).
@("outlines.cff.seac")
@safe pure nothrow
unittest
{
    // ISOAdobe: code 0x41 'A' is SID/glyph 34, code 0xC2 'acute' SID/glyph 125.
    auto glyphs = new const(ubyte)[][](126);
    foreach (ref g; glyphs)
        g = [endchar];
    glyphs[34] = cs([0, 0], rmoveto) ~ cs([100, 0], rlineto, endchar);
    glyphs[125] = cs([5, 0], rmoveto) ~ cs([0, 10], rlineto, endchar);
    glyphs[1] = cs([500, 40, 300, 0x41, 0xC2], endchar); // width, adx, ady, bchar, achar
    const bytes = cff1Font(glyphs);
    const segs = segmentsOf(bytes, 1);
    assert(segs[0].kind == SegmentKind.moveTo && segs[0].end == OutlinePoint.fromUnits(0, 0));
    assert(segs[1].end == OutlinePoint.fromUnits(100, 0) && segs[3].kind == SegmentKind.close);
    assert(segs[4].kind == SegmentKind.moveTo && segs[4].end == OutlinePoint.fromUnits(45, 300));
    assert(segs[5].end == OutlinePoint.fromUnits(45, 310) && segs[7].kind == SegmentKind.close);
    assert(segmentCount(bytes, 1) == 8);

    // An unencoded code, and a seac inside a component, are errors.
    glyphs[2] = cs([0, 0, 0x41, 0x80], endchar);
    glyphs[34] = cs([0, 0, 0x41, 0xC2], endchar);
    const broken = cff1Font(glyphs);
    assert(outlineError(broken, 2).kind == FontErrorKind.badValue);
    assert(outlineError(broken, 1).kind == FontErrorKind.badValue);
}

/// A subroutine that calls itself is a cycle (FTB5); a deep chain is the depth limit; `endchar` in one ends the glyph.
@("outlines.cff.subroutines")
@safe pure nothrow
unittest
{
    const privateDict = dictInt(4) ~ u8(19); // Subrs right after the 4-byte Private DICT
    const self = cff1Font([[endchar], cs([-107], callsubr, endchar)], privateDict, [cs([-107], callsubr, ret)]);
    assert(outlineError(self, 1).kind == FontErrorKind.cycle);
    const mutual = cff1Font([[endchar], cs([-107], callsubr, endchar)], privateDict,
        [cs([-106], callsubr, ret), cs([-107], callsubr, ret)]);
    assert(outlineError(mutual, 1).kind == FontErrorKind.cycle);

    const(ubyte)[][] chain;
    foreach (k; 0 .. 11)
        chain ~= cs([k + 1 - 107], callsubr, ret);
    chain ~= [ret];
    const deep = outlineError(cff1Font([[endchar], cs([-107], callsubr, endchar)], privateDict, chain), 1);
    assert(deep.kind == FontErrorKind.limitExceeded && deep.limit == FontLimit.cffSubroutineDepth);

    // The caller's operators after the subroutine's endchar never run.
    const ends = cff1Font([[endchar], cs([-107], callsubr) ~ cs([0, 50], rlineto, endchar)], privateDict,
        [cs([10, 10], rmoveto) ~ cs([100, 0], rlineto, endchar)]);
    assert(segmentCount(ends, 1) == 4);
}

/// A charstring past 65,536 operations, through subroutines that each call the next four times, is the operation limit (FTB3).
@("outlines.cff.operationLimit")
@safe pure nothrow
unittest
{
    const privateDict = dictInt(4) ~ u8(19);
    const(ubyte)[][] fanOut;
    foreach (k; 0 .. 9)
    {
        ubyte[] body;
        foreach (_; 0 .. 4)
            body ~= cs([k + 1 - 107], callsubr);
        fanOut ~= body ~ [ret];
    }
    fanOut ~= [ret];
    const e = outlineError(cff1Font([[endchar], cs([-107], callsubr, endchar)], privateDict, fanOut), 1);
    assert(e.kind == FontErrorKind.limitExceeded && e.limit == FontLimit.cffOperations);
}

/// DICT real numbers parse exactly, and malformed ones are errors.
@("outlines.cff.dictReal")
@safe pure nothrow
unittest
{
    // A Subrs offset of 5 as reals: "0.5E1" and "50E-1", each a 5-byte Private DICT.
    foreach (real_; [x"1E 0A 5B 1F", x"1E 50 C1 FF"])
    {
        const bytes = cff1Font([[endchar], cs([-107], callsubr, endchar)], cast(const(ubyte)[]) real_ ~ u8(19),
            [cs([10, 10], rmoveto) ~ cs([100, 0], rlineto, ret)]);
        assert(segmentsOf(bytes, 1)[0].end == OutlinePoint.fromUnits(10, 10));
    }
    // Nibble 0xD is reserved; a real the DICT ends inside is truncated; "1E" has no exponent digits.
    const reserved = cff1Font([[endchar], cs([0, 0], rmoveto, endchar)], [cast(ubyte) 30, 0xD1, 0xFF, 10]);
    assert(outlineError(reserved, 1).kind == FontErrorKind.badValue);
    const open = cff1Font([[endchar], cs([0, 0], rmoveto, endchar)], [cast(ubyte) 30, 0x11]);
    assert(outlineError(open, 1).kind == FontErrorKind.truncated);
    const noExponent = cff1Font([[endchar], cs([0, 0], rmoveto, endchar)], [cast(ubyte) 30, 0x1B, 0xFF, 10]);
    assert(outlineError(noExponent, 1).kind == FontErrorKind.badValue);
}

/**
A `CFF2` face of `glyph` (glyph 1). FD 0's Private DICT is `privateDict`;
with `vstore`, the Top DICT names it and the face has a `wght` axis from -1
to 1.
*/
private const(ubyte)[] cff2Font(const(ubyte)[] glyph, const(ubyte)[] privateDict = null,
    const(ubyte)[] vstore = null) @safe pure nothrow
{
    const globals = cff2Index(null);
    const strings = cff2Index([null, glyph]);
    // 28-form operands keep the DICT sizes independent of the offsets.
    ubyte[] top(size_t charAt, size_t fdAt, size_t vstoreAt)
        => dictInt(cast(int) charAt) ~ [cast(ubyte) 17] ~ dictInt(cast(int) fdAt) ~ u8(12) ~ u8(36)
            ~ (vstore.length ? dictInt(cast(int) vstoreAt) ~ [cast(ubyte) 24] : null);
    ubyte[] fd(size_t privateAt)
        => dictInt(cast(int) privateDict.length) ~ dictInt(cast(int) privateAt) ~ [cast(ubyte) 18];
    const topLength = top(0, 0, 0).length;
    const charAt = 5 + topLength + globals.length;
    const fdAt = charAt + strings.length;
    const privateAt = fdAt + cff2Index([fd(0)]).length;
    const vstoreAt = privateAt + privateDict.length;
    const cff = u8(2) ~ u8(0) ~ u8(5) ~ u16(cast(uint) topLength) ~ top(charAt, fdAt, vstoreAt)
        ~ globals ~ strings ~ cff2Index([fd(privateAt)]) ~ privateDict
        ~ (vstore.length ? u16(cast(uint) vstore.length) ~ vstore : null);
    auto tables = minimalTables(2);
    tables ~= TableData("CFF2", cff);
    if (vstore.length)
        tables ~= TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)]));
    return sfnt(tables, 0x4F54_544F);
}

/// `CFF2` reads `hmoveto` and `vstemhm` as `CFF` does, and `vsindex` (15) and `blend` (16) through the variation store.
@("outlines.cff2.blend")
@safe pure nothrow
unittest
{
    enum ubyte vsindex = 15, blend = 16;
    enum f2one = 16_384;
    // Data 0 weighs the region peaking at wght 1; data 1 the one peaking at -1.
    const store = itemVariationStore(1, [[[0, f2one, f2one]], [[-f2one, -f2one, 0]]],
        [VarData([0], 0, false, null), VarData([1], 0, false, null)]);
    const lines = cs([100, 0], rlineto);

    const hmove = cff2Font(cs([10], hmoveto) ~ lines);
    assert(segmentsOf(hmove, 1)[0].end == OutlinePoint.fromUnits(10, 0));
    const stems = cff2Font(cs([0, 10], vstemhm) ~ cs([10, 20], rmoveto) ~ lines);
    assert(segmentsOf(stems, 1)[0].end == OutlinePoint.fromUnits(10, 20));

    // x = 10 + 6·scalar, y = 20 + 4·scalar.
    const blended = cff2Font(cs([10, 20, 6, 4, 2], blend, rmoveto) ~ lines, null, store);
    assert(segmentsOf(blended, 1)[0].end == OutlinePoint.fromUnits(10, 20));
    assert(segmentsOf(blended, 1, 1)[0].end == OutlinePoint.fromUnits(16, 24));
    assert(segmentsOf(blended, 1, -1)[0].end == OutlinePoint.fromUnits(10, 20));
    const second = cff2Font(cs([1], vsindex) ~ cs([10, 20, 6, 4, 2], blend, rmoveto) ~ lines, null, store);
    assert(segmentsOf(second, 1, 1)[0].end == OutlinePoint.fromUnits(10, 20));
    assert(segmentsOf(second, 1, -1)[0].end == OutlinePoint.fromUnits(16, 24));
    // FTO4: the segment kinds stay those of the default instance.
    assert(segmentCount(blended, 1, 1) == segmentCount(blended, 1));

    // The Private DICT's vsindex is the charstring's default; its blend keeps the defaults.
    const privateDict = dictInt(1) ~ [cast(ubyte) 22] ~ dictInt(5) ~ dictInt(3) ~ dictInt(1) ~ u8(23) ~ u8(10);
    const fromPrivate = cff2Font(cs([10, 20, 6, 4, 2], blend, rmoveto) ~ lines, privateDict, store);
    assert(segmentsOf(fromPrivate, 1, -1)[0].end == OutlinePoint.fromUnits(16, 24));

    // A blend without a store, a vsindex after a blend, and too few operands are errors.
    assert(outlineError(cff2Font(cs([10, 20, 6, 4, 2], blend, rmoveto)), 1).kind == FontErrorKind.badValue);
    const late = cff2Font(cs([10, 6, 1], blend) ~ cs([1], vsindex) ~ cs([0], rmoveto), null, store);
    assert(outlineError(late, 1).kind == FontErrorKind.badValue);
    assert(outlineError(cff2Font(cs([10, 6, 4, 2], blend), null, store), 1).kind == FontErrorKind.badValue);
}

/// FTO4: a contour whose end moves onto its start keeps its closing line, in `glyf` and in `CFF2`.
@("outlines.FTO4.closingLine")
@safe pure nothrow
unittest
{
    SegmentKind[8] kindsOf(const(ubyte)[] bytes, uint gid, int wght)
    {
        SegmentKind[8] kinds;
        foreach (i, s; segmentsOf(bytes, gid, wght)[0 .. 8])
            kinds[i] = s.kind;
        return kinds;
    }
    // The last point of each glyph lands on the first at wght 1.
    const glyphs = [
        simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]),
        simpleGlyph([[0, 0, 1], [50, 100, 0], [100, 0, 1]]),
    ];
    const gvar = variationTable([
        glyphVarData([16_384], [0, 0, -100, 0, 0, 0, 0], [0, 0, -100, 0, 0, 0, 0]),
        glyphVarData([16_384], [0, 0, -100, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]),
    ]);
    const glyf = glyfFont(glyphs, [TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", gvar)]);
    foreach (gid; 0 .. 2)
    {
        assert(segmentCount(glyf, gid, 1) == segmentCount(glyf, gid));
        assert(kindsOf(glyf, gid, 1) == kindsOf(glyf, gid, 0));
    }
    assert(segmentsOf(glyf, 0, 1)[3] == OutlineSegment(SegmentKind.lineTo, OutlinePoint.fromUnits(0, 0)));

    enum ubyte blend = 16;
    enum f2one = 16_384;
    const store = itemVariationStore(1, [[[0, f2one, f2one]]], [VarData([0], 0, false, null)]);
    const cff2 = cff2Font(cs([0, 0], rmoveto) ~ cs([100, 0], rlineto) ~ cs([-50, 100, -50, -100, 2], blend, rlineto),
        null, store);
    assert(segmentsOf(cff2, 1, 1)[2].end == OutlinePoint.fromUnits(0, 0));
    assert(segmentCount(cff2, 1, 1) == segmentCount(cff2, 1) && segmentCount(cff2, 1) == 5);
    assert(kindsOf(cff2, 1, 1) == kindsOf(cff2, 1, 0));
}

/// FTO1: a sink keeps its own attributes (this one allocates and may throw) and `begin` learns the contour count first.
@("outlines.drawGlyph.anySink")
@safe
unittest
{
    static struct Recorder
    {
        size_t contours = size_t.max;
        SegmentKind[] kinds;
        void begin(size_t contourCount) { contours = contourCount; }
        void moveTo(OutlinePoint) { kinds ~= SegmentKind.moveTo; }
        void lineTo(OutlinePoint) { kinds ~= SegmentKind.lineTo; }
        void quadTo(OutlinePoint, OutlinePoint) { kinds ~= SegmentKind.quadTo; }
        void cubicTo(OutlinePoint, OutlinePoint, OutlinePoint)
        {
            if (kinds.length > 1_000)
                throw new Exception("runaway outline");
            kinds ~= SegmentKind.cubicTo;
        }
        void close() { kinds ~= SegmentKind.close; }
    }
    with (SegmentKind)
    {
        // A triangle, a one-point contour (which draws nothing) and a quadratic contour.
        const glyf = glyfFont([
            simpleGlyph([[0, 0, 1], [100, 0, 1], [100, 100, 1]]),
            simpleGlyph([[5, 5, 1]]),
            simpleGlyph([[0, 0, 1], [50, 100, 0], [100, 0, 1]]),
            compositeGlyph([CompositePart(0, 0x0003, 0, 0), CompositePart(1, 0x0003, 0, 0),
                CompositePart(2, 0x0003, 0, 200)]),
        ]);
        OutlinePoint[64] points;
        bool[64] onCurve;
        ushort[16] ends;
        Recorder fromGlyf;
        const r1 = drawGlyph(instanceOf(glyf), 3, workspace(points[], onCurve[], ends[]), fromGlyf);
        assert(r1.hasValue && r1.value.contourCount == 3 && r1.value.segmentCount == 9);
        assert(fromGlyf.contours == 2);
        assert(fromGlyf.kinds == [moveTo, lineTo, lineTo, lineTo, close, moveTo, quadTo, lineTo, close]);

        // CFF: a move that draws nothing, a line contour and a curve contour.
        const cff = cff1Font([[endchar], cs([5, 5], rmoveto) ~ cs([0, 0], rmoveto) ~ cs([100, 0], rlineto)
            ~ cs([0, 0], rmoveto) ~ cs([10, 0, 10, 10, 0, 10], 8, endchar)]);
        Recorder fromCff;
        const r2 = drawGlyph(instanceOf(cff), 1, OutlineWorkspace.init, fromCff);
        assert(r2.hasValue && r2.value.contourCount == 2);
        assert(fromCff.contours == 2);
        assert(fromCff.kinds == [moveTo, lineTo, lineTo, close, moveTo, cubicTo, lineTo, close]);
    }
}

@("outlines.cff.sinkCubicFallback")
@safe pure nothrow
unittest
{
    // A cubic through a sink without cubicTo arrives as quadratics.
    const glyph1 = csNum(0) ~ csNum(0) ~ [cast(ubyte) 21]
        ~ csNum(10) ~ csNum(30) ~ csNum(40) ~ csNum(30) ~ csNum(50) ~ csNum(0)
        ~ [cast(ubyte) 8, cast(ubyte) 14];
    auto tables = minimalTables(2);
    tables ~= TableData("CFF ", cffOutlineTable([[cast(ubyte) 14], glyph1]));
    const bytes = sfnt(tables, 0x4F54_544F);

    static struct QuadSink
    {
        @safe pure nothrow @nogc:
        int moves, quads, closes;
        void moveTo(OutlinePoint) { ++moves; }
        void lineTo(OutlinePoint) {}
        void quadTo(OutlinePoint, OutlinePoint) { ++quads; }
        void close() { ++closes; }
    }
    static struct CubicSink
    {
        @safe pure nothrow @nogc:
        int cubics;
        void moveTo(OutlinePoint) {}
        void lineTo(OutlinePoint) {}
        void quadTo(OutlinePoint, OutlinePoint) {}
        void cubicTo(OutlinePoint, OutlinePoint, OutlinePoint) { ++cubics; }
        void close() {}
    }
    OutlinePoint[64] points;
    bool[64] onCurve;
    ushort[16] ends;
    auto ws = workspace(points[], onCurve[], ends[]);
    QuadSink quadSink;
    const r1 = drawGlyph(instanceOf(bytes), 1, ws, quadSink);
    assert(r1.hasValue && quadSink.moves == 1 && quadSink.quads >= 1 && quadSink.closes == 1);
    CubicSink cubicSink;
    const r2 = drawGlyph(instanceOf(bytes), 1, ws, cubicSink);
    assert(r2.hasValue && cubicSink.cubics == 1);
}

/// A midpoint on the chord does not make an S-shaped cubic a straight line.
@("outlines.cff.cubicFallbackAccuracy")
@safe pure nothrow
unittest
{
    const glyph = csNum(0) ~ csNum(0) ~ [cast(ubyte) 21]
        ~ csNum(0) ~ csNum(1000) ~ csNum(1000) ~ csNum(-2000) ~ csNum(0) ~ csNum(1000)
        ~ [cast(ubyte) 8, cast(ubyte) 14];
    auto tables = minimalTables(1);
    tables ~= TableData("CFF ", cffOutlineTable([glyph]));
    const bytes = sfnt(tables, 0x4F54_544F);
    static struct Sink
    {
        @safe pure nothrow @nogc:
        OutlinePoint[256] controls, ends;
        size_t count;
        void moveTo(OutlinePoint) {}
        void lineTo(OutlinePoint) {}
        void close() {}
        void quadTo(OutlinePoint control, OutlinePoint end)
        {
            assert(count < ends.length);
            controls[count] = control;
            ends[count++] = end;
        }
    }
    Sink sink;
    OutlineWorkspace ws;
    assert(drawGlyph(instanceOf(bytes), 0, ws, sink).hasValue);
    OutlinePoint from;
    foreach (i; 0 .. sink.count)
    {
        foreach (u; [0.0, 0.25, 0.5, 0.75, 1.0])
        {
            const t = (i + u) / sink.count;
            // The reference is the original cubic's Bernstein polynomial.
            const x = 3000 * (1 - t) * t * t + 1000 * t * t * t;
            const y = 3000 * (1 - t) * (1 - t) * t - 3000 * (1 - t) * t * t;
            const qx = (1 - u) * (1 - u) * from.xUnits
                + 2 * (1 - u) * u * sink.controls[i].xUnits + u * u * sink.ends[i].xUnits;
            const qy = (1 - u) * (1 - u) * from.yUnits
                + 2 * (1 - u) * u * sink.controls[i].yUnits + u * u * sink.ends[i].yUnits;
            import std.math : abs;
            assert(abs(x - qx) <= 0.0625 && abs(y - qy) <= 0.0625);
        }
        from = sink.ends[i];
    }
}

// ---------------------------------------------------------------------------
// Hostile data (FTB1, FTB2)
// ---------------------------------------------------------------------------

/// Decodes every glyph of `bytes` at the default and at wght 1 through every outline entry point.
private void exerciseOutlines(const(ubyte)[] bytes) @safe pure nothrow
{
    static struct CountingSink
    {
        @safe pure nothrow @nogc:
        size_t calls;
        void begin(size_t) { ++calls; }
        void moveTo(OutlinePoint) { ++calls; }
        void lineTo(OutlinePoint) { ++calls; }
        void quadTo(OutlinePoint, OutlinePoint) { ++calls; }
        void close() { ++calls; }
    }
    const opened = openFace(bytes);
    if (opened.hasError)
        return;
    const face = opened.value;
    OutlinePoint[256] points;
    bool[256] onCurve;
    ushort[64] ends;
    OutlineSegment[256] segments;
    UserCoordinate[1] heavy = [UserCoordinate(Tag("wght"), 1 << 16)];
    foreach (coords; [heavy[0 .. 0], heavy[]])
    {
        const made = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), coords);
        if (made.hasError)
            continue;
        const inst = made.value;
        foreach (gid; 0 .. face.numGlyphs + 1)
        {
            cast(void) glyphOutline(inst, gid, segments[], workspace(points[], onCurve[], ends[]));
            CountingSink sink;
            cast(void) drawGlyph(inst, gid, workspace(points[], onCurve[], ends[]), sink);
            cast(void) glyphBounds(inst, gid);
            cast(void) glyphPoint(inst, gid, 1);
            cast(void) glyphOverlaps(face, gid);
        }
    }
}

/**
Every prefix of the `tag` table of `bytes` (by its directory length) and
every byte of it set to 0x00 and to 0xFF, each decoded by `exerciseOutlines`.
*/
private void mutateTable(const(ubyte)[] bytes, Tag tag) @safe pure nothrow
{
    const face = openFace(bytes).value;
    const index = face.find(tag);
    const record = face.record(index);
    const lengthAt = 12 + 16 * index + 12;
    foreach (n; 0 .. record.length)
    {
        auto copy = bytes.dup;
        copy[lengthAt .. lengthAt + 4] = u32(n);
        exerciseOutlines(copy);
    }
    foreach (k; 0 .. record.length)
        foreach (ubyte v; [0x00, 0xFF])
        {
            auto copy = bytes.dup;
            copy[record.offset + k] = v;
            exerciseOutlines(copy);
        }
}

/// No truncation or byte mutation of a `CFF`, `CFF2`, `glyf` or `gvar` table crashes a decoder.
@("outlines.hostile.mutations")
@safe pure nothrow
unittest
{
    enum ubyte blend = 16;
    enum short one = 16_384;
    const privateDict = dictInt(4) ~ u8(19);
    const cff = cff1Font([[endchar],
        cs([-107], callsubr) ~ cs([0, 10, 20, 10], hstemhm) ~ cs([5, 5], hintmask, 0xF0)
            ~ cs([10, 10, 20, 10, 10, 10, 10], 12, 34) ~ cs([1, 2, 3], 12, 24, 12, 18, endchar)],
        privateDict, [cs([10, 10], rmoveto, ret)]);
    mutateTable(cff, Tag("CFF "));
    const store = itemVariationStore(1, [[[0, one, one]]], [VarData([0], 0, false, null)]);
    const cff2 = cff2Font(cs([10, 20, 6, 4, 2], blend, rmoveto) ~ cs([100, 0], rlineto)
        ~ cs([10, 5, 10, 5, 10, 10, 10, -5, 10], 12, 36), null, store);
    mutateTable(cff2, Tag("CFF2"));
    const sparse = [cast(ubyte) 2, cast(ubyte) 1, cast(ubyte) 0, cast(ubyte) 2] ~ gvarDeltaSeries([10, 30])
        ~ gvarDeltaSeries([20, 40]);
    const gvarData = u16(1) ~ u16(10) ~ u16(cast(uint) sparse.length) ~ u16(0xA000) ~ u16(one) ~ sparse;
    const triangle = simpleGlyph([[0, 0, 1], [50, 100, 0], [100, 0, 1], [200, -100, 1]]);
    const glyf = glyfFont([triangle, compositeGlyph([CompositePart(0, 0x0003, 0, 0),
        CompositePart(0, 0x0002, 1, 3)])], [TableData("fvar", fvarTable([FvarAxis("wght", -65_536, 0, 65_536)])),
        TableData("gvar", variationTable([gvarData, null]))]);
    // The unmutated fixtures decode, so the mutations start from working data.
    foreach (bytes; [cff, cff2, glyf])
        foreach (wght; [0, 1])
            assert(segmentCount(bytes, 1, wght) > 0);
    mutateTable(glyf, Tag("glyf"));
    mutateTable(glyf, Tag("gvar"));
}
