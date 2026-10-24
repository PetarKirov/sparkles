/**
The M5 raster differentials over testing.md's four raster faces — Fira
Code Nerd Font Mono, Noto Sans Arabic, Maple Mono NF CN (whose flagged
glyphs take the 4×4 union) and Noto Sans Anatolian Hieroglyphs (`CFF`).
FTR3: for every glyph, at 12, 16, 24 and 48 ppem, the
coverage of `sparkles.font.raster` under FreeType's flattening policy
is compared per pixel with FreeType's unhinted normal render.
Tolerances are those recorded in testing.md: every pixel within 32
steps (`glyf`) or 48 (CFF), and the 99th percentile within 8.
*/
module sparkles.font_oracle.raster;

import std.file : read;
import std.path : baseName;

import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font_oracle.corpus : corpus, fontsDir;
import sparkles.font_oracle.freetype_c;
import sparkles.test_runner.skip : skipTest;

private struct FtFace
{
    FT_Library library;
    FT_Face face;

    @disable this(this);

    this(const(ubyte)[] bytes) @trusted
    {
        FT_Init_FreeType(&library);
        const error = FT_New_Memory_Face(library, bytes.ptr, cast(FT_Long) bytes.length, 0, &face);
        assert(error == 0);
    }

    ~this() @trusted
    {
        FT_Done_Face(face);
        FT_Done_FreeType(library);
    }
}

@("oracle.raster.freeType")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    string[4] names = ["FiraCodeNerdFontMono-Regular.ttf", "NotoSansArabic.ttf",
        "MapleMono-NF-CN-Regular.ttf", "NotoSansAnatolianHieroglyphs-Regular.otf"];
    foreach (name; names)
    {
        string path;
        foreach (p; corpus)
            if (p.baseName == name)
                path = p;
        assert(path !is null, name);
        const bytes = cast(const(ubyte)[]) read(path);
        const isCff = openFace(bytes).value.outlines == OutlineFormat.cff;
        auto ft = FtFace(bytes);
        const face = openFace(bytes).value;

        auto points = new OutlinePoint[8192];
        auto pws = makeUnique!PointWorkspace();
        auto onCurve = new bool[8192];
        auto ends = new ushort[1024];
        auto segments = new OutlineSegment[16_384];
        auto accumulation = new float[4_194_304];
        auto supersample = new ubyte[1_048_576];
        auto pixels = new ubyte[262_144];

        foreach (ppemSize; [12, 16, 24, 48])
        {
            FT_Set_Pixel_Sizes(ft.face, 0, cast(FT_UInt) ppemSize);
            auto inst = face.instance(InstanceSize.pixels(
                Ppem.fromInteger(ppemSize).value), null).value;
            const maxDiff = isCff ? 48 : 32;
            ulong[256] histogram;
            int worstDiff;
            size_t worstGlyph;
            size_t glyphsCompared, pixelsCompared, flagged;
            foreach (gid; 0 .. face.numGlyphs)
            {
                const loadError = FT_Load_Glyph(ft.face, cast(FT_UInt) gid,
                    cast(int)(FT_LOAD_NO_HINTING | FT_LOAD_RENDER | FT_LOAD_NO_BITMAP));
                assert(loadError == 0, name);
                const glyph = ft.face.glyph;
                const bitmap = &glyph.bitmap;
                RasterWorkspace ws;
                ws.segments = segments;
                ws.points = points;
                ws.onCurve = onCurve;
                ws.contourEnds = ends;
                ws.accumulation = accumulation;
                ws.supersample = supersample;
                ws.pointNumbers = pws.get.pointNumbers[];
                ws.deltaX = pws.get.deltaX[];
                ws.deltaY = pws.get.deltaY[];
                ws.referenced = pws.get.referenced[];
                auto region = RasterRegion(pixels, 0, 0, 0);
                const size = rasterMeasure(inst, gid, Ppem.fromInteger(ppemSize).value,
                    ws, OverlapMode.perGlyphFlag);
                assert(size.hasValue, name);
                flagged += size.value.overlap;
                region.stride = size.value.width;
                region.width = size.value.width;
                region.height = size.value.height;
                pixels[] = 0;
                const ours = rasterizeGlyph(inst, gid, Ppem.fromInteger(ppemSize).value,
                    region, ws, FlattenPolicy.freeType, OverlapMode.perGlyphFlag);
                assert(ours.hasValue, name);
                ++glyphsCompared;

                // Compare on the union canvas of both boxes: `t` is a
                // row's top edge in pixels above the baseline, walking
                // down; `cx` a pixel column from the pen.
                const ftLeft = glyph.bitmap_left, ftTop = glyph.bitmap_top;
                const ourLeft = ours.value.bearingX, ourTop = ours.value.bearingY;
                import std.algorithm : max, min;

                const canvasTop = max(ftTop, ourTop);
                const canvasLeft = min(ftLeft, ourLeft);
                const canvasBottom = min(ftTop - cast(int) bitmap.rows,
                    ourTop - ours.value.height);
                const canvasRight = max(ftLeft + cast(int) bitmap.width,
                    ourLeft + ours.value.width);
                for (int t = canvasTop; t > canvasBottom; --t)
                {
                    foreach (cx; canvasLeft .. canvasRight)
                    {
                        int expected, actual;
                        const fx = cx - ftLeft, fy = ftTop - t;
                        if (fx >= 0 && fx < cast(int) bitmap.width
                            && fy >= 0 && fy < cast(int) bitmap.rows)
                            expected = bitmap.buffer[fy * bitmap.pitch + fx];
                        const ox = cx - ourLeft, oy = ourTop - t;
                        if (ox >= 0 && ox < ours.value.width
                            && oy >= 0 && oy < ours.value.height)
                            actual = pixels[oy * ours.value.width + ox];
                        if (expected == 0 && actual == 0)
                            continue;
                        const diff = expected > actual ? expected - actual
                            : actual - expected;
                        assert(diff <= maxDiff, name);
                        if (diff > worstDiff)
                        {
                            worstDiff = diff;
                            worstGlyph = gid;
                        }
                        ++histogram[diff];
                        ++pixelsCompared;
                    }
                }
            }
            // The 99th percentile of |diff| over inked pixels.
            size_t cumulative;
            int p99 = 255;
            foreach (d; 0 .. 256)
            {
                cumulative += histogram[d];
                if (pixelsCompared && cumulative * 100 >= pixelsCompared * 99)
                {
                    p99 = cast(int) d;
                    break;
                }
            }
            import std.stdio : stderr;

            stderr.writefln("raster %s @%dppem: %d glyphs (%d flagged), %d px, p99=%d worst=%d (gid %d)",
                name, ppemSize, glyphsCompared, flagged, pixelsCompared, p99, worstDiff,
                worstGlyph);
            assert(glyphsCompared > 100 && p99 <= 8, name);
            // The union path is exercised: Maple Mono flags most of its glyphs.
            assert(name != "MapleMono-NF-CN-Regular.ttf" || flagged > 20_000, name);
        }
    }
}

@("oracle.raster.flatteningAccuracy")
@system
unittest
{
    // FTR8: the default (0.02 px) flattening against the same
    // rasterizer at 0.001 px: every pixel within 16 steps, the 99th
    // percentile within 8 (testing.md's raster oracle tolerances).
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    string[4] names = ["FiraCodeNerdFontMono-Regular.ttf", "NotoSansArabic.ttf",
        "MapleMono-NF-CN-Regular.ttf", "NotoSansAnatolianHieroglyphs-Regular.otf"];
    foreach (name; names)
    {
        string path;
        foreach (p; corpus)
            if (p.baseName == name)
                path = p;
        assert(path !is null, name);
        const bytes = cast(const(ubyte)[]) read(path);
        const face = openFace(bytes).value;
        auto points = new OutlinePoint[8192];
        auto pws = makeUnique!PointWorkspace();
        auto onCurve = new bool[8192];
        auto ends = new ushort[1024];
        auto segments = new OutlineSegment[16_384];
        auto accumulation = new float[4_194_304];
        auto supersample = new ubyte[1_048_576];
        auto standard = new ubyte[262_144];
        auto fine = new ubyte[262_144];
        foreach (ppemSize; [12, 16, 24, 48])
        {
            auto inst = face.instance(InstanceSize.pixels(
                Ppem.fromInteger(ppemSize).value), null).value;
            const ppem = Ppem.fromInteger(ppemSize).value;
            ulong[256] histogram;
            size_t pixelsCompared;
            int worst;
            foreach (gid; 0 .. face.numGlyphs)
            {
                RasterWorkspace ws;
                ws.segments = segments;
                ws.points = points;
                ws.onCurve = onCurve;
                ws.contourEnds = ends;
                ws.accumulation = accumulation;
                ws.supersample = supersample;
                ws.pointNumbers = pws.get.pointNumbers[];
                ws.deltaX = pws.get.deltaX[];
                ws.deltaY = pws.get.deltaY[];
                ws.referenced = pws.get.referenced[];
                const size = rasterMeasure(inst, gid, ppem, ws);
                assert(size.hasValue, name);
                auto region = RasterRegion(standard, size.value.width,
                    size.value.width, size.value.height);
                standard[] = 0;
                fine[] = 0;
                const a = rasterizeGlyph(inst, gid, ppem, region, ws,
                    FlattenPolicy.standard, OverlapMode.perGlyphFlag);
                assert(a.hasValue, name);
                region.data = fine;
                const b = rasterizeGlyph(inst, gid, ppem, region, ws,
                    FlattenPolicy.fine, OverlapMode.perGlyphFlag);
                assert(b.hasValue && b.value.width == a.value.width
                    && b.value.height == a.value.height, name);
                const area = cast(size_t) a.value.width * a.value.height;
                foreach (i; 0 .. area)
                {
                    const diff = standard[i] > fine[i] ? standard[i] - fine[i]
                        : fine[i] - standard[i];
                    if (standard[i] == 0 && fine[i] == 0)
                        continue;
                    assert(diff <= 16, name);
                    if (diff > worst)
                        worst = diff;
                    ++histogram[diff];
                    ++pixelsCompared;
                }
            }
            size_t cumulative;
            int p99 = 255;
            foreach (d; 0 .. 256)
            {
                cumulative += histogram[d];
                if (pixelsCompared && cumulative * 100 >= pixelsCompared * 99)
                {
                    p99 = cast(int) d;
                    break;
                }
            }
            import std.stdio : stderr;

            stderr.writefln("flattening %s @%dppem: %d px, p99=%d worst=%d",
                name, ppemSize, pixelsCompared, p99, worst);
            assert(pixelsCompared > 10_000 && p99 <= 8, name);
        }
    }
}
