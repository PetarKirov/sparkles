/**
M6 colour glyphs (FTR5, FTR7, FTR6) on hand-built faces: `COLR` version 0
layer order, palette and foreground colours worked out by hand; `CBDT`
index and image formats, strike choice and scaling; `sbix` records and
`dupe` chains; the errors of each; and every glyph of the bundled emoji
font at three sizes.
*/
module sparkles.font.colour_glyphs_test;

import sparkles.font;
import sparkles.font.corpus : bundled, fontsPath;
import sparkles.font.fixtures;
import sparkles.test_runner.skip : skipTest;

import sparkles.base.text.layout_units : I128, Rational, U128;

import std.conv : text;

/// Ample storage for one colour glyph.
private struct Storage
{
    OutlineSegment[256] segments;
    OutlinePoint[256] points;
    bool[256] onCurve;
    ushort[64] ends;
    float[65_536] accumulation;
    ubyte[65_536] supersample;
    ubyte[65_536] coverage;
    ubyte[1 << 18] inflated, image;
    ubyte[pngZlibScratch] zlib;
    ubyte[1 << 18] pixels;

    ColourWorkspace workspace() return @safe pure nothrow @nogc
        => ColourWorkspace(RasterWorkspace(segments[], points[], onCurve[], ends[], accumulation[], supersample[]),
            coverage[], inflated[], image[], zlib[]);
}

private Ppem px(long ppem) @safe pure nothrow @nogc => Ppem.fromInteger(ppem).value;

/// A face of `glyphs` (upem 2048, advance 500, lsb 0) plus `extra` tables.
private const(ubyte)[] faceOf(const(ubyte)[][] glyphs, const(TableData)[] extra) @safe pure nothrow
{
    auto tables = minimalTables(cast(uint) glyphs.length);
    uint[2][] metrics;
    foreach (_; glyphs)
        metrics ~= [500, 0];
    tables ~= TableData("hhea", hhea(cast(uint) glyphs.length));
    tables ~= TableData("hmtx", hmtx(metrics));
    tables ~= TableData("loca", locaTable(glyphs));
    tables ~= TableData("glyf", glyfTable(glyphs));
    return sfnt(tables ~ extra);
}

private Instance instanceOf(const(ubyte)[] bytes, long ppem = 10) @safe pure nothrow
    => openFace(bytes).value.instance(InstanceSize.pixels(px(ppem)), null).value;

/// Renders glyph `gid` in colour, asserting success; the pixels are `s.pixels[0 .. 4 · width · height]`.
private ColourGlyph render(Storage* s, in Instance inst, uint gid, long ppem = 10, uint palette = 0,
    Colour foreground = Colour(0, 0, 0, 255))
{
    auto ws = s.workspace;
    const m = colourMeasure(inst, gid, px(ppem), ws);
    assert(m.hasValue, m.hasError ? m.error.text : "");
    auto region = ColourRegion(s.pixels[], 4 * m.value.width, m.value.width, m.value.height);
    const r = rasterizeColourGlyph(inst, gid, px(ppem), palette, foreground, region, ws);
    assert(r.hasValue, r.hasError ? r.error.text : "");
    assert(r.value == m.value);
    return r.value;
}

// ---------------------------------------------------------------------------
// COLR version 0 (FTR5)
// ---------------------------------------------------------------------------

/// Glyph 1: a 1024-unit square (5 px at 10 ppem). Glyph 2: a 2048 × 1024 rectangle.
private const(ubyte)[][] layerGlyphs() @safe pure nothrow
    => [null, simpleGlyph([[0, 0, 1], [1024, 0, 1], [1024, 1024, 1], [0, 1024, 1]]),
        simpleGlyph([[0, 0, 1], [2048, 0, 1], [2048, 1024, 1], [0, 1024, 1]]), null, null];

/// Glyph 3: the square in entry 0, under the rectangle in the foreground. Glyph 4: the square in entry 5.
private const(ubyte)[] layeredFace(bool withCpal = true) @safe pure nothrow
{
    const colr = colrV0([[3, 0, 2], [4, 2, 1]], [[1, 0], [2, 0xFFFF], [1, 5]]);
    const ubyte[4][][] palettes = [[[255, 0, 0, 255]], [[0, 255, 0, 255]]];
    return faceOf(layerGlyphs, [TableData("COLR", colr)] ~ (withCpal ? [TableData("CPAL", cpalColours(palettes))] : null));
}

@("colr.layers.listAndPalette")
@safe pure nothrow
unittest
{
    const face = openFace(layeredFace).value;
    ColrLayer[4] layers;
    auto n = colrLayers(face, 3, layers[]);
    assert(n.hasValue && n.value == 2);
    assert(layers[0] == ColrLayer(1, 0) && layers[1] == ColrLayer(2, foregroundPaletteEntry));
    assert(colrLayers(face, 1, layers[]).value == 0, "a glyph without a base record has no layers");
    n = colrLayers(face, 3, layers[0 .. 1]);
    assert(n.hasError && n.error.limit == FontLimit.callerStorage && n.error.needed == 2);

    assert(paletteCount(face).value == 2);
    assert(paletteColour(face, 0, 0).value == Colour(255, 0, 0, 255));
    assert(paletteColour(face, 1, 0).value == Colour(0, 255, 0, 255));
    assert(paletteColour(face, 2, 0).error.kind == FontErrorKind.indexOutOfRange);
    assert(paletteColour(face, 0, 1).error.kind == FontErrorKind.indexOutOfRange);
    assert(paletteCount(openFace(layeredFace(false)).value).error.kind == FontErrorKind.missingTable);
}

@("colr.render.layerOrderAndForeground")
@system
unittest
{
    // At 10 ppem the square is 5 × 5 px and the rectangle 10 × 5, both from the pen up from the baseline.
    const inst = instanceOf(layeredFace);
    auto s = new Storage;
    const g = render(s, inst, 3, 10, 0, Colour(0, 0, 255, 128));
    assert(g.source == ColourSource.layers && g.layerCount == 2);
    assert(g.width == 10 && g.height == 5 && g.bearingX == 0 && g.bearingY == 5);
    assert(g.coverageNeeded == 50);
    // Left half: blue at alpha 128 over opaque red. The foreground premultiplies to
    // b = round(255 · 128 / 255) = 128 and covers 128, keeping 127 of the red:
    // r = round(255 · 127 / 255) = 127, b = 128, a = 128 + 127 = 255. Right half: the foreground alone.
    foreach (y; 0 .. 5)
        foreach (x; 0 .. 10)
        {
            const p = s.pixels[4 * (10 * y + x) .. 4 * (10 * y + x) + 4];
            assert(p == (x < 5 ? [127, 0, 128, 255] : [0, 0, 128, 128]), text(x, ",", y, ": ", p));
        }

    // Palette 1 colours the square green instead.
    render(s, inst, 3, 10, 1, Colour(0, 0, 255, 128));
    assert(s.pixels[0 .. 4] == [0, 127, 128, 255]);

    // Equal keys, byte-identical output (FTR6).
    auto again = new Storage;
    render(again, inst, 3, 10, 1, Colour(0, 0, 255, 128));
    assert(again.pixels[0 .. 200] == s.pixels[0 .. 200]);
}

@("colr.render.errors")
@system
unittest
{
    const inst = instanceOf(layeredFace);
    auto s = new Storage;
    auto ws = s.workspace;
    auto region = ColourRegion(s.pixels[], 40, 10, 5);
    // Glyph 4's entry 5 is past CPAL's one entry; palette 2 is past its two palettes.
    assert(rasterizeColourGlyph(inst, 4, px(10), 0, Colour.init, region, ws).error.kind
        == FontErrorKind.indexOutOfRange);
    assert(rasterizeColourGlyph(inst, 3, px(10), 2, Colour.init, region, ws).error.kind
        == FontErrorKind.indexOutOfRange);
    // A region a pixel short.
    const short_ = rasterizeColourGlyph(inst, 3, px(10), 0, Colour.init, ColourRegion(s.pixels[0 .. 199], 40, 10, 5), ws);
    assert(short_.hasError && short_.error.limit == FontLimit.callerStorage && short_.error.needed == 200);
    ws.coverage = ws.coverage[0 .. 49];
    assert(rasterizeColourGlyph(inst, 3, px(10), 0, Colour.init, region, ws).error.needed == 50);

    // Without CPAL, a layer in a palette entry is missingTable; one in the foreground alone renders.
    const bare = instanceOf(layeredFace(false));
    ws = s.workspace;
    assert(rasterizeColourGlyph(bare, 3, px(10), 0, Colour.init, region, ws).error.kind
        == FontErrorKind.missingTable);
    const foregroundOnly = instanceOf(faceOf(layerGlyphs, [TableData("COLR", colrV0([[3, 0, 1]], [[1, 0xFFFF]]))]));
    render(s, foregroundOnly, 3, 10, 0, Colour(10, 20, 30, 255));
    assert(s.pixels[0 .. 4] == [10, 20, 30, 255]);

    // A glyph without layers or bitmaps has no colour form.
    const none = render(s, inst, 1);
    assert(none.source == ColourSource.none && none.empty);

    // More than 1,024 layers, and layers past the layer array.
    uint[2][] many;
    foreach (_; 0 .. 1025) many ~= [1, 0xFFFF];
    const huge = openFace(faceOf(layerGlyphs, [TableData("COLR", colrV0([[3, 0, 1025]], many))])).value;
    ColrLayer[2000] layers;
    const limited = colrLayers(huge, 3, layers[]);
    assert(limited.hasError && limited.error.limit == FontLimit.colrLayers);
    const past = openFace(faceOf(layerGlyphs, [TableData("COLR", colrV0([[3, 0, 3]], [[1, 0]]))])).value;
    assert(colrLayers(past, 3, layers[]).error.kind == FontErrorKind.badValue);
    // A version above 1.
    auto v2 = colrV0([[3, 0, 1]], [[1, 0]]);
    v2[1] = 2;
    assert(colrLayers(openFace(faceOf(layerGlyphs, [TableData("COLR", v2)])).value, 3, layers[]).error.kind
        == FontErrorKind.unsupportedVersion);
}

// ---------------------------------------------------------------------------
// CBDT/CBLC and sbix (FTR7)
// ---------------------------------------------------------------------------

/// A 4 × 2 RGBA PNG of distinct opaque pixels, row-major from `first`.
private const(ubyte)[] gradientPng(ubyte first) @safe pure nothrow
{
    const(ubyte)[][] rows;
    foreach (y; 0 .. 2)
    {
        ubyte[] row;
        foreach (x; 0 .. 4)
            row ~= [cast(ubyte)(first + 10 * (4 * y + x)), cast(ubyte)(5 * x), cast(ubyte)(40 * y), 255];
        rows ~= row;
    }
    return pngFile(PngSpec(4, 2, 8, 6, rows));
}

/// Five empty glyphs and `tables`.
private const(ubyte)[] bitmapFace(const(TableData)[] tables) @safe pure nothrow
    => faceOf([null, null, null, null, null], tables);

@("bitmap.cbdt.strikeChoice")
@safe pure nothrow
unittest
{
    const png = solidPng(2, 2, [1, 2, 3, 255]);
    const face = openFace(bitmapFace(cbdtTables([
        CbdtStrike(40, 1, 17, [GlyphBitmap(1, 0, 2, 2, 2, png)]),
        CbdtStrike(20, 1, 17, [GlyphBitmap(1, 0, 2, 2, 2, png)]),
    ]))).value;
    uint strikeFor(Ppem ppem) => bitmapGlyph(face, 1, ppem).value.strikePpem;
    // The smallest strike at least the request, else the largest.
    assert(strikeFor(px(10)) == 20 && strikeFor(px(20)) == 20 && strikeFor(px(21)) == 40);
    assert(strikeFor(px(40)) == 40 && strikeFor(px(80)) == 40);
    assert(strikeFor(Ppem.fromRational(Rational(I128(U128(41, 0)), U128(2, 0))).value) == 40, "20.5 ppem");
    const g = bitmapGlyph(face, 1, px(20)).value;
    assert(g.source == ColourSource.cbdt && g.png == png && g.table == Tag("CBDT"));
    assert(face.bytes[cast(size_t) g.pngOffset .. cast(size_t) g.pngOffset + png.length] == png);
    // Outside the strike's glyph range, and an invalid ppem.
    assert(bitmapGlyph(face, 2, px(20)).value.source == ColourSource.none);
    assert(bitmapGlyph(face, 1, Ppem.init).error.kind == FontErrorKind.badValue);
}

@("bitmap.cbdt.indexAndImageFormats")
@safe
unittest
{
    const a = gradientPng(0), b = gradientPng(100);
    // Glyphs 1 and 3 have bitmaps; 2 has none (formats 1 and 3) or is absent (4 and 5).
    const consecutive = [GlyphBitmap(1, 1, 2, 4, 2, a), GlyphBitmap(2), GlyphBitmap(3, 1, 2, 4, 2, b)];
    const sparse = [GlyphBitmap(1, 1, 2, 4, 2, a), GlyphBitmap(3, 1, 2, 4, 2, b)];
    const uint[2][] forms = [[1, 17], [1, 18], [3, 17], [3, 18], [2, 17], [2, 19], [4, 17], [4, 18], [5, 18], [5, 19]];
    foreach (f; forms)
    {
        const fixedSize = f[0] == 2;
        // Format 2 is consecutive glyphs of one size: give glyph 2 a bitmap there.
        const glyphs = f[0] == 1 || f[0] == 3 ? consecutive
            : fixedSize ? [GlyphBitmap(1, 1, 2, 4, 2, a), GlyphBitmap(2, 1, 2, 4, 2, a), GlyphBitmap(3, 1, 2, 4, 2, b)]
            : sparse;
        const face = openFace(bitmapFace(cbdtTables([CbdtStrike(16, f[0], f[1], glyphs)]))).value;
        foreach (gid, png; [1: a, 3: b])
        {
            const g = bitmapGlyph(face, gid, px(16));
            assert(g.hasValue, text(f, " ", g.error));
            assert(g.value.source == ColourSource.cbdt && g.value.png == png, text(f));
            assert(g.value.bearingX == 1 && g.value.bearingY == 2 && g.value.width == 4 && g.value.height == 2,
                text(f));
        }
        if (!fixedSize)
            assert(bitmapGlyph(face, 2, px(16)).value.source == ColourSource.none, text(f));
    }
    // An image format outside 17-19, and CBDT without CBLC.
    auto mono = cbdtTables([CbdtStrike(16, 1, 1, [GlyphBitmap(1, 0, 0, 1, 1, a)])]);
    assert(bitmapGlyph(openFace(bitmapFace(mono)).value, 1, px(16)).error.kind == FontErrorKind.unsupportedVersion);
    const lone = bitmapFace([cbdtTables([CbdtStrike(16, 1, 17, sparse)])[0]]);
    assert(bitmapGlyph(openFace(lone).value, 1, px(16)).error.kind == FontErrorKind.missingTable);
}

@("bitmap.render.copyAndScale")
@system
unittest
{
    const png = gradientPng(0);
    const bytes = bitmapFace(cbdtTables([CbdtStrike(20, 1, 17, [GlyphBitmap(1, 2, 4, 4, 2, png)])]));
    auto s = new Storage;
    // At the strike's own size the box is the bearings and the pixels are the PNG's.
    auto g = render(s, instanceOf(bytes, 20), 1, 20);
    assert(g.source == ColourSource.cbdt && g.strikePpem == 20);
    assert(g.width == 4 && g.height == 2 && g.bearingX == 2 && g.bearingY == 4);
    foreach (i; 0 .. 8)
        assert(s.pixels[4 * i .. 4 * i + 4] == [cast(ubyte)(10 * i), cast(ubyte)(5 * (i % 4)), cast(ubyte)(40 * (i / 4)), 255]);

    // At half the size each output pixel is the mean of a 2 × 2 block: for the first,
    // red (0 + 10 + 40 + 50) / 4 = 25, green (0 + 5 + 0 + 5) / 4 = 2.5 rounds to 3, blue 80 / 4 = 20.
    g = render(s, instanceOf(bytes, 10), 1, 10);
    assert(g.width == 2 && g.height == 1 && g.bearingX == 1 && g.bearingY == 2);
    assert(s.pixels[0 .. 4] == [25, 3, 20, 255] && s.pixels[4 .. 8] == [45, 13, 20, 255]);

    // At twice the size each image pixel covers 2 × 2 output pixels.
    g = render(s, instanceOf(bytes, 40), 1, 40);
    assert(g.width == 8 && g.height == 4 && g.bearingX == 4 && g.bearingY == 8);
    assert(s.pixels[0 .. 8] == [0, 0, 0, 255, 0, 0, 0, 255] && s.pixels[4 * 8 .. 4 * 8 + 4] == [0, 0, 0, 255]);
    assert(s.pixels[4 * (8 * 3 + 7) .. 4 * (8 * 3 + 7) + 4] == [70, 15, 40, 255]);

    // A PNG cut short inside CBDT is located in CBDT.
    auto broken = cbdtTables([CbdtStrike(20, 1, 17, [GlyphBitmap(1, 2, 4, 4, 2, png[0 .. $ - 12])])]);
    auto ws = s.workspace;
    const r = rasterizeColourGlyph(instanceOf(bitmapFace(broken), 20), 1, px(20), 0, Colour.init,
        ColourRegion(s.pixels[], 16, 4, 2), ws);
    assert(r.hasError && r.error.kind == FontErrorKind.truncated && r.error.tag == Tag("CBDT"));
}

@("bitmap.sbix.recordsAndDupes")
@system
unittest
{
    const png = solidPng(2, 2, [200, 100, 50, 255]);
    SbixRecord[] glyphs(uint ppem) => [SbixRecord(), SbixRecord(1, -1, "png ", png), SbixRecord(0, 0, "dupe", u16(1)),
        SbixRecord(0, 0, "dupe", u16(2)), SbixRecord(0, 0, "jpg ", [1, 2, 3])];
    const bytes = bitmapFace([TableData("sbix", sbixStrikes([SbixStrike(16, glyphs(16)), SbixStrike(32, glyphs(32))]))]);
    const face = openFace(bytes).value;
    const g = bitmapGlyph(face, 1, px(20)).value;
    // The image's lower left corner sits at (1, -1) from the pen, so its top is 1 px up.
    assert(g.source == ColourSource.sbix && g.strikePpem == 32 && g.png == png);
    assert(g.bearingX == 1 && g.bearingY == 1 && g.width == 2 && g.height == 2);
    assert(bitmapGlyph(face, 2, px(16)).value.png == png, "a dupe is followed");
    assert(bitmapGlyph(face, 3, px(16)).error.kind == FontErrorKind.cycle, "a dupe of a dupe is not");
    assert(bitmapGlyph(face, 4, px(16)).error.kind == FontErrorKind.unsupportedVersion);
    assert(bitmapGlyph(face, 0, px(16)).value.source == ColourSource.none);

    auto s = new Storage;
    const r = render(s, instanceOf(bytes, 16), 1, 16);
    assert(r.source == ColourSource.sbix && r.width == 2 && r.height == 2);
    assert(s.pixels[0 .. 4] == [200, 100, 50, 255]);
}

@("bitmap.bundle.everyEmojiDecodes")
@system
unittest
{
    if (fontsPath() is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const bytes = bundled("NotoColorEmoji.ttf");
    const face = openFace(bytes).value;
    auto s = new Storage;
    size_t decoded;
    foreach (ppem; [16, 48, 109])
    {
        const inst = face.instance(InstanceSize.pixels(px(ppem)), null).value;
        foreach (gid; 0 .. face.numGlyphs)
        {
            auto ws = s.workspace;
            const m = colourMeasure(inst, gid, px(ppem), ws);
            assert(m.hasValue, text(gid, " ", m.error));
            if (m.value.source == ColourSource.none)
                continue;
            assert(m.value.source == ColourSource.cbdt && m.value.strikePpem == 109 && !m.value.empty);
            auto region = ColourRegion(s.pixels[], 4 * m.value.width, m.value.width, m.value.height);
            const r = rasterizeColourGlyph(inst, gid, px(ppem), 0, Colour.init, region, ws);
            assert(r.hasValue, text(gid, " at ", ppem, ": ", r.error));
            ubyte maxAlpha;
            foreach (i; 0 .. m.value.width * m.value.height)
                maxAlpha = s.pixels[4 * i + 3] > maxAlpha ? s.pixels[4 * i + 3] : maxAlpha;
            assert(maxAlpha > 0, text(gid, " inks at ", ppem));
            ++decoded;
        }
    }
    assert(decoded == 3 * 3985, text(decoded));
}
