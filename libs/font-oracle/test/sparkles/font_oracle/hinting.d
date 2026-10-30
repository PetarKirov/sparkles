/**
The light-hinting differential (FTR9): Latin letters
and digits of DejaVu Sans Mono and Fira Code at terminal sizes, rasterized by
`sparkles.font` unhinted and light-hinted, each compared with FreeType's
auto-hinter in its light mode (`FT_LOAD_FORCE_AUTOHINT | FT_LOAD_TARGET_LIGHT`)
— the vertical-only grid fitting most Linux desktops and browsers draw with.

Two measures, over every glyph and size:

$(UL
    $(LI the mean per-pixel coverage difference over the union of both
    boxes, aligned on pen and baseline; hinting must bring it at least
    twice as close to FreeType's;)
    $(LI where the x-height and the baseline land: the first and last rows
    of a lowercase letter with ink over half the row's peak. Hinted, these
    must match FreeType's for nineteen in twenty letters.)
)

At the time of writing: 6.9 hinted against 21.6 unhinted, and 614 of 624
edge rows matched (543 unhinted); Fira Code at 11 px is the one size where
hinting does not help.
*/
module sparkles.font_oracle.hinting;

import std.file : read;
import std.path : baseName;

import sparkles.base.unique : makeUnique;
import sparkles.font;
import sparkles.font_oracle.corpus : corpus, fontsDir;
import sparkles.font_oracle.freetype_c;
import sparkles.test_runner.skip : skipTest;

// `FT_LOAD_TARGET_LIGHT` is a function-like macro ImportC does not expand:
// `FT_LOAD_TARGET_(FT_RENDER_MODE_LIGHT)`.
private enum int ftLoadTargetLight = 1 << 16;

private struct Bitmap
{
    int left, top, width, height;
    ubyte[] pixels;

    int at(int x, int t) const // `t` a row's top in pixels above the baseline
    {
        const ox = x - left, oy = top - t;
        return ox >= 0 && ox < width && oy >= 0 && oy < height ? pixels[oy * width + ox] : 0;
    }

    // The rows (tops, above the baseline) whose ink is over half the
    // glyph's fullest row: where its horizontal edges were drawn crisply.
    void inkRows(out int highest, out int lowest) const
    {
        int peak;
        foreach (oy; 0 .. height)
        {
            int sum;
            foreach (ox; 0 .. width)
                sum += pixels[oy * width + ox];
            peak = sum > peak ? sum : peak;
        }
        highest = int.min;
        lowest = int.max;
        foreach (oy; 0 .. height)
        {
            int sum;
            foreach (ox; 0 .. width)
                sum += pixels[oy * width + ox];
            if (sum * 2 > peak)
            {
                const t = top - oy;
                highest = t > highest ? t : highest;
                lowest = t < lowest ? t : lowest;
            }
        }
    }
}

private double meanDifference(in Bitmap a, in Bitmap b)
{
    import std.algorithm : max, min;

    const top = max(a.top, b.top), bottom = min(a.top - a.height, b.top - b.height);
    const left = min(a.left, b.left), right = max(a.left + a.width, b.left + b.width);
    double sum = 0;
    size_t n;
    for (int t = top; t > bottom; --t)
        foreach (x; left .. right)
        {
            const p = a.at(x, t), q = b.at(x, t);
            if (p == 0 && q == 0)
                continue;
            sum += p > q ? p - q : q - p;
            ++n;
        }
    return n ? sum / n : 0;
}

@("oracle.hinting.lightAgainstFreeTypeAutohint")
@system unittest
{
    if (fontsDir is null)
        return skipTest("SPARKLES_FONTS_PATH is unset");
    import std.stdio : stderr;

    // Each face at each size has a ceiling of its own, a level above what
    // it measured on 2026-10-30, so a regression in one cannot hide behind
    // the others in the totals. At 11 px light hinting does not yet beat
    // unhinted outlines (DejaVu 8.8 against 9.3, Fira Code 12.4 against
    // 11.1): a ratchet, not a claim that 11 px is right.
    static immutable faces = ["DejaVuSansMono.ttf", "FiraCodeNerdFontMono-Regular.ttf"];
    static immutable double[6][2] ceilings = [
        [10.0, 7.5, 7.5, 7.0, 7.0, 7.0], // DejaVu Sans Mono, 11–16 px
        [13.5, 7.0, 7.5, 7.0, 7.5, 8.0], // Fira Code, 11–16 px
    ];
    double hintedTotal = 0, unhintedTotal = 0;
    size_t glyphs, edgesHinted, edgesUnhinted, letters;
    foreach (fi, name; faces)
    {
        string path;
        foreach (p; corpus)
            if (p.baseName == name)
                path = p;
        assert(path !is null, name);
        const bytes = cast(const(ubyte)[]) read(path);
        const face = openFace(bytes).value;
        const map = charMap(face).value;
        FT_Library library;
        FT_Face ft;
        FT_Init_FreeType(&library);
        assert(FT_New_Memory_Face(library, bytes.ptr, cast(FT_Long) bytes.length, 0, &ft) == 0);
        scope (exit)
        {
            FT_Done_Face(ft);
            FT_Done_FreeType(library);
        }

        auto pws = makeUnique!PointWorkspace();
        auto segments = new OutlineSegment[16_384];
        RasterWorkspace ws;
        ws.segments = segments;
        ws.points = new OutlinePoint[8192];
        ws.onCurve = new bool[8192];
        ws.contourEnds = new ushort[1024];
        ws.accumulation = new float[1 << 20];
        ws.supersample = new ubyte[1 << 18];
        ws.pointNumbers = pws.get.pointNumbers[];
        ws.deltaX = pws.get.deltaX[];
        ws.deltaY = pws.get.deltaY[];
        ws.referenced = pws.get.referenced[];

        foreach (px; 11 .. 17)
        {
            const ppem = Ppem.fromInteger(px).value;
            auto inst = face.instance(InstanceSize.pixels(ppem), null).value;
            const hints = lightHints(inst, map, ppem, new OutlineSegment[4096], ws.outline);
            FT_Set_Pixel_Sizes(ft, 0, cast(FT_UInt) px);
            double hintedSum = 0, unhintedSum = 0;
            size_t n;
            foreach (dchar c; "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            {
                const gid = map.glyph(c);
                assert(FT_Load_Glyph(ft, gid, cast(int)(FT_LOAD_FORCE_AUTOHINT | ftLoadTargetLight
                    | FT_LOAD_RENDER | FT_LOAD_NO_BITMAP)) == 0);
                const g = ft.glyph;
                Bitmap theirs = Bitmap(g.bitmap_left, g.bitmap_top, cast(int) g.bitmap.width,
                    cast(int) g.bitmap.rows);
                theirs.pixels = new ubyte[theirs.width * theirs.height];
                foreach (row; 0 .. theirs.height)
                    theirs.pixels[row * theirs.width .. (row + 1) * theirs.width] =
                        g.bitmap.buffer[row * g.bitmap.pitch .. row * g.bitmap.pitch + theirs.width];

                Bitmap ours(const(LightHints)* h)
                {
                    const m = rasterMeasure(inst, gid, ppem, ws, OverlapMode.perGlyphFlag, h).value;
                    Bitmap b = Bitmap(m.bearingX, m.bearingY, m.width, m.height);
                    b.pixels = new ubyte[m.width * m.height];
                    cast(void) rasterizeGlyph(inst, gid, ppem, RasterRegion(b.pixels, m.width, m.width,
                        m.height), ws, FlattenPolicy.standard, OverlapMode.perGlyphFlag, h);
                    return b;
                }

                const hinted = ours(&hints), unhinted = ours(null);
                hintedSum += meanDifference(hinted, theirs);
                unhintedSum += meanDifference(unhinted, theirs);
                ++n;
                if (c >= 'a' && c <= 'z')
                {
                    int th, tl, hh, hl, uh, ul;
                    theirs.inkRows(th, tl);
                    hinted.inkRows(hh, hl);
                    unhinted.inkRows(uh, ul);
                    edgesHinted += (hh == th) + (hl == tl);
                    edgesUnhinted += (uh == th) + (ul == tl);
                    letters += 2;
                }
            }
            stderr.writefln("hinting %s @%dpx: mean |diff| hinted %.1f, unhinted %.1f", name, px,
                hintedSum / n, unhintedSum / n);
            assert(hintedSum / n <= ceilings[fi][px - 11], "hinted " ~ name ~ " drifted from "
                ~ "FreeType's past its ceiling at one size");
            hintedTotal += hintedSum;
            unhintedTotal += unhintedSum;
            glyphs += n;
        }
    }
    stderr.writefln("hinting: mean |diff| hinted %.1f, unhinted %.1f; edge rows matched hinted %s/%s, unhinted %s/%s",
        hintedTotal / glyphs, unhintedTotal / glyphs, edgesHinted, letters, edgesUnhinted, letters);
    assert(hintedTotal * 2 <= unhintedTotal, "light hinting must come twice as close to FreeType's");
    assert(edgesHinted * 20 >= letters * 19, "x-height and baseline rows as FreeType's in 19 of 20 letters");
}
