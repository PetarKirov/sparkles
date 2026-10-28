/**
The discovery oracles of `discovery.md` § 9:

$(UL
    $(LI FTD16–FTD21: the catalog's record of every bundled face against
        fontconfig's (`fc-scan` over `$SPARKLES_FONTS_PATH`): family, weight,
        slant, width and coverage. fontconfig's weights are on its own scale,
        so ours are mapped onto it with fontconfig's own
        `FcWeightFromOpenTypeDouble` (from `$SPARKLES_FONTCONFIG_LIB`) before
        they are compared. Three divergences are known, counted and printed:
        fontconfig's slant reads "Oblique" from a style name over `OS/2`'s
        italic bit; its charset drops C0 controls whose glyph has no contour
        (checked with FreeType); and it describes a variable face whose axes
        are all fixed by its default instance alone. Everything else agrees.)
    $(LI FTD35–FTD38: the generated box-drawing face, for several cells at 16
        and 24 ppem, against FreeType (every glyph loads and renders, and the
        line, block and shade glyphs rasterize to exactly FreeType's pixels)
        and HarfBuzz (`hb_shape` maps every covered scalar to our glyph).)
)
*/
module sparkles.font_oracle.discovery;

import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

import std.algorithm : canFind, max, min, splitter;
import std.array : split;
import std.conv : text, to;
import std.file : read;
import std.math : abs;
import std.path : baseName, buildPath;
import std.process : environment, execute, ProcessException;
import std.stdio : stderr;
import std.string : lineSplitter, startsWith, toStringz;

import sparkles.base.unique : makeUnique;
import sparkles.base.vfs : ambientAuthority;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.font;
import sparkles.font_oracle;
import sparkles.font_oracle.corpus : fontsDir, Oracle;
import sparkles.font_oracle.freetype_c : FT_Done_Face, FT_Done_FreeType, FT_Face, FT_Get_Char_Index,
    FT_GLYPH_FORMAT_OUTLINE, FT_Init_FreeType, FT_Library, FT_LOAD_NO_BITMAP, FT_LOAD_NO_HINTING, FT_LOAD_NO_SCALE,
    FT_LOAD_RENDER, FT_Load_Glyph, FT_Long, FT_New_Memory_Face, FT_Set_Pixel_Sizes, FT_UInt;
import sparkles.test_runner.skip : skipTest;

// ---------------------------------------------------------------------------
// FTD16–FTD21: records against fontconfig
// ---------------------------------------------------------------------------

/// A closed interval: one value, or a variable face's range.
private struct Interval
{
    double lo, hi;

    bool near(Interval o, double tolerance = 1e-3) const @safe pure nothrow @nogc
        => abs(lo - o.lo) <= tolerance && abs(hi - o.hi) <= tolerance;

    string toString() const @safe => lo == hi ? text(lo) : text("[", lo, " ", hi, "]");
}

/// `80` or `[0 210]`, as fontconfig prints a value or a range.
private Interval interval(string s) @safe
{
    if (!s.startsWith("["))
        return Interval(s.to!double, s.to!double);
    const parts = s[1 .. $ - 1].split(' ');
    return Interval(parts[0].to!double, parts[1].to!double);
}

/// One `fc-scan` pattern of a face (index < 65,536): the static face, or a variable face's whole range.
private struct FcPattern
{
    string family;
    string style;
    Interval weight, slant, width;
    uint[2][] charset;
}

/// fontconfig's `charset`, `20-7e a0 …`, as inclusive ranges.
private uint[2][] charsetRanges(string s) @safe
{
    uint[2][] r;
    foreach (token; s.splitter(' '))
    {
        if (!token.length)
            continue;
        auto parts = token.split('-');
        const first = parts[0].to!uint(16);
        r ~= [first, parts.length > 1 ? parts[1].to!uint(16) : first];
    }
    return r;
}

/// FTD16–FTD21's oracle: `fc-scan` of `dir`, keyed by file name and face index; a variable face's key ends in `+v`.
private FcPattern[string] fcScan(string dir) @system
{
    const r = execute(["fc-scan", "--format",
        "%{file|basename}\t%{index}\t%{variable}\t%{family[0]}\t%{style[0]}\t%{weight}\t%{slant}\t%{width}\t%{charset}\n",
        dir]);
    assert(r.status == 0, r.output);
    FcPattern[string] patterns;
    foreach (line; r.output.lineSplitter)
    {
        const f = line.split('\t');
        assert(f.length == 9, line);
        const index = f[1].to!uint;
        if (index >= 65_536)
            continue; // a named instance
        const key = text(f[0], "#", index, f[2] == "True" ? "+v" : "");
        patterns[key] = FcPattern(f[3], f[4], interval(f[5]), interval(f[6]), interval(f[7]), charsetRanges(f[8]));
    }
    return patterns;
}

/// fontconfig's slant constants.
private enum : double
{
    fcRoman = 0,
    fcItalic = 100,
    fcOblique = 110,
}

/// Our record's slant on fontconfig's scale: italic 100, an oblique angle 110, else 0.
private Interval slantOf(in FaceRecord r) @safe pure nothrow @nogc
{
    double at(int italic, int oblique) => italic ? fcItalic : oblique ? fcOblique : fcRoman;
    const a = at(r.italicMin, r.obliqueMin), b = at(r.italicMax, r.obliqueMax);
    return Interval(min(a, b), max(a, b));
}

@("oracle.discovery.fontconfigRecords")
@system
unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    const fcLibrary = environment.get("SPARKLES_FONTCONFIG_LIB");
    if (fcLibrary is null)
        return skipTest("SPARKLES_FONTCONFIG_LIB is unset");
    // fontconfig's own weight map, from the library fc-scan links.
    auto handle = dlopen(fcLibrary.toStringz, RTLD_NOW);
    assert(handle !is null, fcLibrary);
    alias WeightMap = extern (C) double function(double) nothrow @nogc;
    const fcWeight = cast(WeightMap) dlsym(handle, "FcWeightFromOpenTypeDouble");
    assert(fcWeight !is null);

    auto vfs = new BlockingVfs;
    auto catalog = new Catalog, report = new BuildReport;
    const sources = [FontSource.bundle("bundle", fontsDir)];
    assert(!buildCatalog(vfs, sources, BuildOptions.init, ambientAuthority(), *catalog, *report).hasError);
    assert(report.failed == 0 && report.outcomes.length == 0);
    FcPattern[string] patterns;
    try
        patterns = fcScan(fontsDir);
    catch (ProcessException e)
        return skipTest("fc-scan is not on PATH: " ~ e.msg);

    // FreeType, to confirm that each C0 control fontconfig leaves out maps to a glyph without contours.
    FT_Library library;
    assert(FT_Init_FreeType(&library) == 0);
    scope (exit)
        FT_Done_FreeType(library);

    size_t records, slants, coverageFaces, controlsDropped, defaultOnly;
    string[] slantByStyleName, notes;
    auto ours = new bool[0x11_0000];
    foreach (ref r; catalog.records)
    {
        const file = catalog.text(r.identity).baseName;
        const variable = r.axes.count > 0;
        const key = text(file, "#", r.index, variable ? "+v" : "");
        auto p = key in patterns;
        if (p is null && variable)
        {
            // fontconfig describes a variable face by its default instance alone when no axis has a range.
            foreach (a; catalog.pools.axesOf(r))
                assert(a.minValue == a.maxValue, text(key, ": fontconfig has no variable pattern"));
            p = text(file, "#", r.index) in patterns;
            notes ~= text(key, ": no variable pattern, every axis being fixed");
            ++defaultOnly;
        }
        assert(p !is null, key ~ ": fc-scan has no such pattern");
        ++records;

        // Family: fontconfig's first is our family or one of our aliases.
        bool familyFound = catalog.text(r.family) == p.family;
        foreach (a; catalog.pools.aliasesOf(r))
            familyFound |= catalog.text(a) == p.family;
        assert(familyFound, text(key, ": fontconfig's family ", p.family, " is not among ours"));

        // Weight, mapped onto fontconfig's scale by fontconfig's own map.
        const weight = Interval(fcWeight(r.weightMin / 65_536.0), fcWeight(r.weightMax / 65_536.0));
        assert(weight.near(p.weight), text(key, ": weight ", weight, " vs fontconfig's ", p.weight));

        // Width: the same percentages, from usWidthClass or the wdth axis.
        const width = Interval(r.widthMin / 65_536.0, r.widthMax / 65_536.0);
        assert(width.near(p.width), text(key, ": width ", width, " vs fontconfig's ", p.width));

        // Slant. Known divergence: fontconfig reads "Oblique" from the style
        // name over OS/2's italic bit; this library reads OS/2 and the axes only.
        const slant = slantOf(r);
        if (slant.near(p.slant))
            ++slants;
        else
        {
            assert(slant.lo == fcItalic && p.slant.lo == fcOblique && p.style.canFind("Oblique"),
                text(key, ": slant ", slant, " vs fontconfig's ", p.slant, " (style ", p.style, ")"));
            slantByStyleName ~= text(key, " (", p.style, ")");
        }

        // Coverage: ours holds fontconfig's charset, and fontconfig leaves out
        // only C0 controls whose glyph has no contour, as FcFreeTypeCharSet does.
        const coverage = catalog.pools.coverageOf(r);
        foreach (c; coverage)
            ours[c.first .. c.last + 1] = true;
        foreach (range; p.charset)
            foreach (cp; range[0] .. range[1] + 1)
            {
                assert(ours[cp], text(key, ": fontconfig covers U+", cp.to!string(16), ", we do not"));
                ours[cp] = false;
            }
        FT_Face ft;
        const(ubyte)[] ftBytes; // FreeType borrows them while `ft` lives
        foreach (c; coverage)
            foreach (cp; c.first .. c.last + 1)
                if (ours[cp])
                {
                    ours[cp] = false;
                    assert(cp <= 0x1F, text(key, ": U+", cp.to!string(16), " is ours only"));
                    if (ft is null)
                    {
                        ftBytes = cast(const(ubyte)[]) read(buildPath(fontsDir, file));
                        assert(FT_New_Memory_Face(library, ftBytes.ptr, cast(FT_Long) ftBytes.length, r.index, &ft) == 0);
                    }
                    const gid = FT_Get_Char_Index(ft, cp);
                    const error = FT_Load_Glyph(ft, gid, cast(int)(FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING));
                    assert(error != 0 || ft.glyph.format == FT_GLYPH_FORMAT_OUTLINE && ft.glyph.outline.n_contours == 0,
                        text(key, ": U+", cp.to!string(16), " has contours, yet fontconfig leaves it out"));
                    ++controlsDropped;
                }
        if (ft !is null)
            FT_Done_Face(ft);
        ++coverageFaces;
    }
    foreach (n; notes)
        stderr.writeln("  ", n);
    stderr.writefln("oracle.discovery.fontconfigRecords: %s records agree with fc-scan in family, weight (on "
        ~ "fontconfig's scale), width and coverage, %s in slant; known divergences: %s slants fontconfig reads from "
        ~ "the style name (%-(%s, %)), %s contourless C0 controls fontconfig's charset drops, %s variable faces "
        ~ "with fixed axes it describes by their default instance", records, slants, slantByStyleName.length,
        slantByStyleName, controlsDropped, defaultOnly);
    assert(records >= 180 && coverageFaces == records);
}

// ---------------------------------------------------------------------------
// FTD35–FTD38: the box-drawing face
// ---------------------------------------------------------------------------

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

/// Whether `cp` is drawn from curves or slanted edges, which no pixel grid holds exactly.
private bool curved(uint cp) @safe pure nothrow @nogc => cp >= 0x256D && cp <= 0x2573;

@("oracle.discovery.boxFace")
@system
unittest
{
    // The box_face_test cells, and the bundle's Fira Code cell at 16 and 24 ppem.
    CellMetrics[] cells = [cellOf(16, 8, 16, 12), cellOf(16, 9, 19, 15), cellOf(24, 14, 28, 22, 2)];
    if (fontsDir !is null)
    {
        const bytes = cast(const(ubyte)[]) read(buildPath(fontsDir, "FiraCodeNerdFontMono-Regular.ttf"));
        const face = openFace(bytes).value;
        const map = charMap(face).value;
        auto pws = makeUnique!PointWorkspace();
        foreach (ppem; [16, 24])
        {
            const inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(ppem).value), null).value;
            cells ~= cellMetrics(inst, map, ppem, *pws).value;
        }
    }

    FT_Library library;
    assert(FT_Init_FreeType(&library) == 0);
    scope (exit)
        FT_Done_FreeType(library);
    auto segments = new OutlineSegment[1 << 15], points = new OutlinePoint[1 << 15];
    auto onCurve = new bool[1 << 15], ends = new ushort[1 << 13];
    auto accumulation = new float[1 << 20], supersample = new ubyte[1 << 20], pixels = new ubyte[1 << 16];

    size_t faces, glyphs, exact, curves, pixelsCompared;
    int worstCurve;
    foreach (cell; cells)
    {
        const layout = boxFaceMeasure(cell).value;
        auto storage = new ubyte[layout.length];
        const bytes = buildBoxFace(cell, storage).value;
        const face = openFace(bytes).value;
        const map = charMap(face).value;
        const ppem = Ppem.fromInteger(cell.ppem).value;
        const inst = face.instance(InstanceSize.pixels(ppem), null).value;
        const label = text(cell.width, "x", cell.height, " @", cell.ppem, "ppem");

        FT_Face ft;
        assert(FT_New_Memory_Face(library, bytes.ptr, cast(FT_Long) bytes.length, 0, &ft) == 0, label);
        scope (exit)
            FT_Done_Face(ft);
        assert(FT_Set_Pixel_Sizes(ft, 0, cast(FT_UInt) cell.ppem) == 0, label);
        assert(ft.num_glyphs == boxFaceGlyphCount, label);

        // HarfBuzz shapes every covered scalar, in one run, to the glyph our cmap gives it.
        auto hb = Oracle(bytes, 0);
        dchar[] text_;
        foreach (r; boxFaceCoverage)
            foreach (cp; r.first .. r.last + 1)
                text_ ~= cast(dchar) cp;
        auto buffer = hb_buffer_create();
        scope (exit)
            hb_buffer_destroy(buffer);
        hb_buffer_add_utf32(buffer, cast(const(uint)*) text_.ptr, cast(int) text_.length, 0, cast(int) text_.length);
        hb_buffer_guess_segment_properties(buffer);
        hb_shape(hb.font, buffer, null, 0);
        uint shaped;
        const infos = hb_buffer_get_glyph_infos(buffer, &shaped);
        assert(shaped == text_.length, label);
        foreach (i; 0 .. shaped)
        {
            const g = infos[i].codepoint;
            assert(g != 0 && g == map.glyph(text_[infos[i].cluster]), text(label, " U+",
                (cast(uint) text_[infos[i].cluster]).to!string(16), ": HarfBuzz glyph ", g));
        }

        // Every glyph loads and renders in FreeType; every covered one matches our rasterizer.
        foreach (gid; 0 .. face.numGlyphs)
            assert(FT_Load_Glyph(ft, gid, cast(int)(FT_LOAD_NO_HINTING | FT_LOAD_RENDER | FT_LOAD_NO_BITMAP)) == 0,
                text(label, " glyph ", gid));
        foreach (cp; 0x2500 .. 0x25A0)
        {
            const gid = map.glyph(cast(dchar) cp);
            assert(gid != 0, label);
            assert(FT_Load_Glyph(ft, gid, cast(int)(FT_LOAD_NO_HINTING | FT_LOAD_RENDER | FT_LOAD_NO_BITMAP)) == 0);
            const glyph = ft.glyph;
            const bitmap = &glyph.bitmap;

            auto ws = RasterWorkspace(segments, points, onCurve, ends, accumulation, supersample);
            const size = rasterMeasure(inst, gid, ppem, ws).value;
            assert(size.width * size.height <= pixels.length, label);
            pixels[] = 0;
            auto region = RasterRegion(pixels, size.width, size.width, size.height);
            const ours = rasterizeGlyph(inst, gid, ppem, region, ws, FlattenPolicy.freeType).value;

            // Both bitmaps on the union of their boxes: `t` a row's top edge above the baseline, `x` from the pen.
            const canvasTop = max(glyph.bitmap_top, ours.bearingY);
            const canvasBottom = min(glyph.bitmap_top - cast(int) bitmap.rows, ours.bearingY - ours.height);
            const canvasLeft = min(glyph.bitmap_left, ours.bearingX);
            const canvasRight = max(glyph.bitmap_left + cast(int) bitmap.width, ours.bearingX + ours.width);
            int worst;
            for (int t = canvasTop; t > canvasBottom; --t)
                foreach (x; canvasLeft .. canvasRight)
                {
                    int expected, actual;
                    const fx = x - glyph.bitmap_left, fy = glyph.bitmap_top - t;
                    if (fx >= 0 && fx < cast(int) bitmap.width && fy >= 0 && fy < cast(int) bitmap.rows)
                        expected = bitmap.buffer[fy * bitmap.pitch + fx];
                    const ox = x - ours.bearingX, oy = ours.bearingY - t;
                    if (ox >= 0 && ox < ours.width && oy >= 0 && oy < ours.height)
                        actual = pixels[oy * ours.width + ox];
                    worst = max(worst, abs(expected - actual));
                    ++pixelsCompared;
                }
            const at = text(label, " U+", cp.to!string(16));
            if (curved(cp))
            {
                // testing.md's raster tolerance for glyf outlines.
                assert(worst <= 32, text(at, ": off by ", worst));
                worstCurve = max(worstCurve, worst);
                ++curves;
            }
            else
            {
                assert(worst == 0, text(at, ": a pixel-aligned glyph differs from FreeType's by ", worst));
                ++exact;
            }
            ++glyphs;
        }
        ++faces;
    }
    stderr.writefln("oracle.discovery.boxFace: %s cells; every glyph loads, renders and shapes; %s line, block "
        ~ "and shade glyphs equal FreeType's pixels exactly, %s arcs and diagonals within %s (%s pixels compared)",
        faces, exact, curves, worstCurve, pixelsCompared);
    assert(exact == faces * (0xA0 - 7));
}
