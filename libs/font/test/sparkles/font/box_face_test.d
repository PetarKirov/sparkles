/**
The generated box-drawing face (FTD35–FTD38): it opens, maps exactly its
coverage, decodes, verifies its checksums and round-trips its cell; and it
rasterizes, at 8×16 and 9×19 (16 ppem) and 14×28 (24 ppem, a 2-pixel light
stroke), to the pixel coverage worked out by hand from FTD37 below.
*/
module sparkles.font.box_face_test;

import sparkles.base.unique : makeUnique;
import sparkles.font;

import std.conv : text;

/// A cell; a nonzero `thickness` gives it an underline that thick.
private CellMetrics cellOf(uint ppem, long width, long height, long baseline, long thickness = 0)
    @safe pure nothrow @nogc
{
    CellMetrics c;
    c.ppem = ppem;
    c.width = width;
    c.height = height;
    c.baseline = baseline;
    if (thickness)
    {
        c.hasUnderline = true;
        c.underlinePosition = baseline + 1;
        c.underlineThickness = thickness;
    }
    return c;
}

private ubyte[] build(in CellMetrics cell) @safe pure
{
    const layout = boxFaceMeasure(cell);
    assert(layout.hasValue, layout.hasError ? text(layout.error) : "");
    auto storage = new ubyte[layout.value.length];
    return buildBoxFace(cell, storage).value;
}

private Instance at(const(ubyte)[] bytes, uint ppem) @safe pure
    => openFace(bytes).value.instance(InstanceSize.pixels(Ppem.fromInteger(ppem).value), null).value;

private RasterWorkspace workspace() @safe pure
    => RasterWorkspace(new OutlineSegment[1 << 15], new OutlinePoint[1 << 15], new bool[1 << 15],
        new ushort[1 << 13], new float[1 << 20], new ubyte[1 << 16]);

/// The coverage of `cp` laid over its `w × h` cell, row by row from the top; no ink may fall outside.
private ubyte[] cellCoverage(const(ubyte)[] bytes, in CellMetrics cell, dchar cp, out bool overlap)
    @safe pure
{
    const w = cast(int) cell.width, h = cast(int) cell.height;
    auto inst = at(bytes, cell.ppem);
    const gid = inst.face.charMap.value.glyph(cp);
    assert(gid != 0, text("U+", cast(uint) cp, " is unmapped"));
    const ppem = Ppem.fromInteger(cell.ppem).value;
    auto ws = workspace();
    const size = rasterMeasure(inst, gid, ppem, ws);
    assert(size.hasValue);
    overlap = size.value.overlap;
    auto pixels = new ubyte[size.value.width * size.value.height];
    auto region = RasterRegion(pixels, size.value.width, size.value.width, size.value.height);
    assert(rasterizeGlyph(inst, gid, ppem, region, ws).hasValue);
    auto result = new ubyte[w * h];
    foreach (row; 0 .. size.value.height)
        foreach (col; 0 .. size.value.width)
        {
            const x = size.value.bearingX + col, y = cast(int) cell.baseline - size.value.bearingY + row;
            const p = pixels[row * size.value.width + col];
            if (x >= 0 && x < w && y >= 0 && y < h)
                result[y * w + x] = p;
            else
                assert(p == 0, text("U+", cast(uint) cp, " inks (", x, ", ", y, ") outside the cell"));
        }
    return result;
}

/// A pixel rectangle `[x0, x1) × [y0, y1)`, y down from the cell's top.
private alias R = int[4];

/// Asserts that `cp` covers exactly the union of `rects`: 255 inside, 0 outside.
private void expectRects(const(ubyte)[] bytes, in CellMetrics cell, dchar cp, scope const(R)[] rects,
    bool overlap) @safe pure
{
    bool flagged;
    const got = cellCoverage(bytes, cell, cp, flagged);
    assert(flagged == overlap, text("U+", cast(uint) cp, " overlap flag ", flagged));
    const w = cast(int) cell.width, h = cast(int) cell.height;
    foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            bool inside;
            foreach (r; rects)
                inside |= x >= r[0] && x < r[2] && y >= r[1] && y < r[3];
            assert(got[y * w + x] == (inside ? 255 : 0), text("U+", cast(uint) cp, " at ", cell.width, "×",
                cell.height, " pixel (", x, ", ", y, ") is ", got[y * w + x]));
        }
}

@("box_face.openFace.coverageOutlinesChecksums")
@system
unittest
{
    const cell = cellOf(16, 8, 16, 12);
    const bytes = build(cell);
    const face = openFace(bytes).value;
    assert(face.unitsPerEm == 1_024 && face.numGlyphs == boxFaceGlyphCount);

    // The character map holds exactly U+0020 and U+2500–U+259F, one glyph each.
    const map = face.charMap.value;
    assert(map.platform == 3 && map.encoding == 1 && map.format == 4);
    CodepointRange[] ranges;
    foreach (r; map.ranges)
        ranges ~= r;
    assert(ranges == boxFaceCoverage, text(ranges));
    assert(map.glyph(' ') == 1 && map.glyph('A') == 0 && map.glyph(0x24FF) == 0 && map.glyph(0x25A0) == 0);
    foreach (cp; 0x2500 .. 0x25A0)
        assert(map.glyph(cp) == cp - 0x2500 + 2);

    // Every glyph decodes; only .notdef and the space are empty.
    auto inst = at(bytes, 16);
    auto ws = workspace();
    foreach (gid; 0 .. boxFaceGlyphCount)
    {
        auto outlineWs = ws.outline;
        const o = glyphOutline(inst, gid, ws.segments, outlineWs);
        assert(o.hasValue, text("glyph ", gid, ": ", o.error));
        assert(o.value.empty == (gid < 2), text("glyph ", gid));
    }

    // FTP33: every table's checksum and the whole file's adjustment.
    const dir = face.directory;
    assert(dir.length == 10 && face.sortedDirectory && face.searchFields.matches);
    foreach (i; 0 .. dir.length)
        assert(face.computedChecksum(i) == dir[i].storedChecksum, text(dir[i].tag));
    assert(face.checksumAdjustment.applies && face.checksumAdjustment.matches);

    // The family name (FTD38).
    const names = face.name.value;
    bool family;
    foreach (i; 0 .. names.count)
    {
        const r = names.record(i).value;
        char[64] buffer;
        if (r.nameID == 1)
            family = r.decode(buffer[]).value == boxFaceFamily;
    }
    assert(family);
}

@("box_face.cellMetrics.roundTrip")
@system
unittest
{
    // The face's own cell metrics at its ppem are the cell it was built for (FTD36).
    auto ws = makeUnique!PointWorkspace();
    foreach (cell; [cellOf(16, 8, 16, 12), cellOf(16, 9, 19, 15), cellOf(24, 14, 28, 22, 2)])
    {
        const bytes = build(cell);
        auto inst = at(bytes, cell.ppem);
        const map = inst.face.charMap.value;
        const m = cellMetrics(inst, map, cell.ppem, *ws);
        assert(m.hasValue);
        assert(m.value.width == cell.width && m.value.height == cell.height
            && m.value.baseline == cell.baseline && m.value.lineGap == 0, text(m.value));
        assert(m.value.widthSource == CellMetrics.WidthSource.averageCharWidth);
        foreach (cp; [' ', '─', '█', '╳'])
            assert(advance(inst, map.glyph(cp), *ws).value.pixels.value == cell.width);
    }
}

@("box_face.limits.ppem")
@system
unittest
{
    // At 16,384 ppem one pixel is one unit; one more ppem is refused.
    const cell = cellOf(16_384, 8_192, 16_384, 12_288);
    const layout = boxFaceMeasure(cell).value;
    assert(layout.unitsPerEm == 16_384 && layout.unitsPerPixel == 1);
    const bytes = build(cell);
    const face = openFace(bytes).value;
    assert(face.unitsPerEm == 16_384 && face.checksumAdjustment.matches);
    assert(boxFaceMeasure(cellOf(16_385, 8, 16, 12)).error.kind == FontErrorKind.limitExceeded);
    // k halves as the ppem grows past each power of two.
    assert(boxFaceMeasure(cellOf(256, 128, 256, 200)).value.unitsPerPixel == 64);
    assert(boxFaceMeasure(cellOf(257, 128, 256, 200)).value.unitsPerPixel == 32);
    // A cell that does not hold its own baseline, or is empty.
    assert(boxFaceMeasure(cellOf(16, 8, 16, 17)).error.kind == FontErrorKind.badValue);
    assert(boxFaceMeasure(cellOf(16, 0, 16, 12)).error.kind == FontErrorKind.badValue);
}

/*
The hand derivation (FTD37), in pixels, y down. A stroke s wide sits at
⌊(extent − s) / 2⌋; a double's strokes at a, a + 2t (a = ⌊(extent − 3t) / 2⌋).

cell         light x  light y  heavy y  double x       double y
8×16,  t=1   [3,4)    [7,8)    [7,9)    [2,3),[4,5)    [6,7),[8,9)
9×19,  t=1   [4,5)    [9,10)   [8,10)   [3,4),[5,6)    [8,9),[10,11)
14×28, t=2   [6,8)    [13,15)  [12,16)  [4,6),[8,10)   [11,13),[15,17)

╔: the right half's top (outer) stroke runs to the double's far side, x = a;
its bottom (inner) stroke stops at the far side of the near stroke, a + 2t;
the down half likewise in y. Triple dashes: slots ⌊i · w / 3⌋, each short of
its end by t.
*/
private struct Expected
{
    CellMetrics cell;
    R horizontal, vertical, heavy;
    R[2] double_;
    R[4] corner;
    R upperHalf, lowerHalf, leftHalf;
    R[3] dashes;
}

private Expected[3] expectations() @safe pure nothrow @nogc => [
    Expected(cellOf(16, 8, 16, 12), [0, 7, 8, 8], [3, 0, 4, 16], [0, 7, 8, 9],
        [[0, 6, 8, 7], [0, 8, 8, 9]],
        [[2, 6, 8, 7], [4, 8, 8, 9], [2, 6, 3, 16], [4, 8, 5, 16]],
        [0, 0, 8, 8], [0, 8, 8, 16], [0, 0, 4, 16],
        [[0, 7, 1, 8], [2, 7, 4, 8], [5, 7, 7, 8]]),
    Expected(cellOf(16, 9, 19, 15), [0, 9, 9, 10], [4, 0, 5, 19], [0, 8, 9, 10],
        [[0, 8, 9, 9], [0, 10, 9, 11]],
        [[3, 8, 9, 9], [5, 10, 9, 11], [3, 8, 4, 19], [5, 10, 6, 19]],
        [0, 0, 9, 9], [0, 9, 9, 19], [0, 0, 4, 19],
        [[0, 9, 2, 10], [3, 9, 5, 10], [6, 9, 8, 10]]),
    Expected(cellOf(24, 14, 28, 22, 2), [0, 13, 14, 15], [6, 0, 8, 28], [0, 12, 14, 16],
        [[0, 11, 14, 13], [0, 15, 14, 17]],
        [[4, 11, 14, 13], [8, 15, 14, 17], [4, 11, 6, 28], [8, 15, 10, 28]],
        [0, 0, 14, 14], [0, 14, 14, 28], [0, 0, 7, 28],
        [[0, 13, 2, 15], [4, 13, 7, 15], [9, 13, 12, 15]]),
];

@("box_face.raster.linesAndBlocks")
@safe pure
unittest
{
    foreach (e; expectations)
    {
        const bytes = build(e.cell);
        // Lines: the halves of ─ and ┼ overlap at the centre, so they carry the flag.
        expectRects(bytes, e.cell, '─', [e.horizontal], true);
        expectRects(bytes, e.cell, '│', [e.vertical], true);
        expectRects(bytes, e.cell, '┼', [e.horizontal, e.vertical], true);
        expectRects(bytes, e.cell, '━', [e.heavy], true);
        expectRects(bytes, e.cell, '═', e.double_[], true);
        expectRects(bytes, e.cell, '╔', e.corner[], true);
        expectRects(bytes, e.cell, '┄', e.dashes[], false);
        // Blocks: edges at ⌊i · w / 8⌋ and ⌊i · h / 8⌋.
        const R full = [0, 0, cast(int) e.cell.width, cast(int) e.cell.height];
        expectRects(bytes, e.cell, '█', [full], false);
        expectRects(bytes, e.cell, '▀', [e.upperHalf], false);
        expectRects(bytes, e.cell, '▄', [e.lowerHalf], false);
        expectRects(bytes, e.cell, '▌', [e.leftHalf], false);
    }
}

@("box_face.raster.shades")
@safe pure
unittest
{
    // u = ⌈max(w, h) / 64⌉ = 1 at these sizes: each pixel is one square of
    // the 2×2 pattern. Light fills (even, even), medium the checkerboard,
    // dark all but (odd, odd).
    foreach (e; expectations)
    {
        const bytes = build(e.cell);
        const w = cast(int) e.cell.width, h = cast(int) e.cell.height;
        foreach (cp; ['░', '▒', '▓'])
        {
            bool flagged;
            const got = cellCoverage(bytes, e.cell, cp, flagged);
            assert(!flagged);
            size_t covered;
            foreach (y; 0 .. h)
                foreach (x; 0 .. w)
                {
                    const quadrant = (x & 1) + 2 * (y & 1);
                    const filled = cp == '░' ? quadrant == 0 : cp == '▒' ? quadrant == 0 || quadrant == 3
                        : quadrant != 3;
                    assert(got[y * w + x] == (filled ? 255 : 0), text("U+", cast(uint) cp, " (", x, ", ", y, ")"));
                    covered += filled;
                }
            // The exact fraction: ⌈w/2⌉⌈h/2⌉, then ⌈w/2⌉⌈h/2⌉ + ⌊w/2⌋⌊h/2⌋, then w·h − ⌊w/2⌋⌊h/2⌋.
            const evens = ((w + 1) / 2) * ((h + 1) / 2), odds = (w / 2) * (h / 2);
            const expected = cp == '░' ? evens : cp == '▒' ? evens + odds : w * h - odds;
            assert(covered == expected);
        }
    }
}

@("box_face.raster.arcsAndDiagonals")
@safe pure
unittest
{
    // Arcs and diagonals stay inside their cell, cover their straight ends
    // fully, and ╳ is the only diagonal that overlaps itself.
    foreach (e; expectations)
    {
        const bytes = build(e.cell);
        const w = cast(int) e.cell.width, h = cast(int) e.cell.height;
        bool flagged;
        // ╭ reaches the bottom edge along the vertical stroke and inks the right edge along the
        // horizontal one (where the curve may end at the edge, tangent but not full).
        const arc = cellCoverage(bytes, e.cell, '╭', flagged);
        assert(!flagged);
        foreach (x; e.vertical[0] .. e.vertical[2])
            assert(arc[(h - 1) * w + x] == 255);
        foreach (y; e.horizontal[1] .. e.horizontal[3])
            assert(arc[y * w + w - 1] > 0);
        assert(arc[0] == 0 && arc[w - 1] == 0 && arc[(h - 1) * w] == 0);
        // ╲ inks the top-left and bottom-right corners, not the others.
        const diagonal = cellCoverage(bytes, e.cell, '╲', flagged);
        assert(!flagged);
        assert(diagonal[0] > 0 && diagonal[h * w - 1] > 0 && diagonal[w - 1] == 0 && diagonal[(h - 1) * w] == 0);
        cellCoverage(bytes, e.cell, '╳', flagged);
        assert(flagged);
    }
}
