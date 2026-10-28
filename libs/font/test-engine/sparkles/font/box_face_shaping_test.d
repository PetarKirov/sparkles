/**
HarfBuzz over the generated box-drawing face (FTD36): the face opens in the
engine like any other, and a run of box-drawing and block characters shapes
to their glyphs, one cell wide each, with no `.notdef`.
*/
module sparkles.font.box_face_shaping_test;

import sparkles.font;

import std.conv : text;

@("box_face.shaping.noNotdef")
@system
unittest
{
    CellMetrics cell;
    cell.ppem = 16;
    cell.width = 8;
    cell.height = 16;
    cell.baseline = 12;
    auto storage = new ubyte[boxFaceMeasure(cell).value.length];
    const bytes = buildBoxFace(cell, storage).value;
    auto face = openFace(bytes).value;
    auto inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
    const map = face.charMap.value;

    ShapedGlyph[8] glyphs;
    SourceSpan[8] spans;
    BoundarySafety[8] boundaries;
    char[16] language;
    const source = "│┼█ ";
    const info = shapeText(inst, source, glyphs[], spans[], boundaries[], language[]);
    assert(info.hasValue, info.hasError ? text(info.error) : "");
    assert(info.value.glyphCount == 4);
    foreach (i, dchar cp; ['│', '┼', '█', ' '])
    {
        assert(glyphs[i].glyphId != 0 && glyphs[i].glyphId == map.glyph(cp), text(i, ": ", glyphs[i]));
        // One cell wide: 8 px is 512 units of the 1,024-unit em.
        assert(glyphs[i].xAdvance == DesignValue.fromUnits(512, 1_024), text(glyphs[i]));
    }
}
