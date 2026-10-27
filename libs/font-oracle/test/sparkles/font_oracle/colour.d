/**
Colour glyphs (FTR5, FTR7) checked against HarfBuzz over the bundle and
the test corpus: every glyph's `COLR` version 0 layers
(`hb_ot_color_glyph_get_layers`), every `CPAL` colour
(`hb_ot_color_palette_get_colors`), and, at a range of sizes, the strike
each bitmap glyph's PNG comes from (`hb_ot_color_glyph_reference_png` with
`hb_font_set_ppem`) and its extents (`hb_font_get_glyph_extents`).
*/
module sparkles.font_oracle.colour;

import std.conv : text;
import std.stdio : stderr;

import sparkles.font;
import sparkles.font_oracle;
import sparkles.font_oracle.corpus : eachCorpusFace, fontsDir, Oracle;
import sparkles.test_runner.skip : skipTest;

@("oracle.colour.layersAndPalettes")
@system
unittest
{
    if (fontsDir is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces, glyphs, layers, colours, unopened;
    ColrLayer[1024] ours;
    hb_ot_color_layer_t[1024] theirs;
    eachCorpusFace((name, face, ref hb) {
        if (!face.has(Tag("COLR")) && !face.has(Tag("CPAL")))
            return;
        ++faces;
        if (face.has(Tag("COLR")))
            foreach (gid; 0 .. face.numGlyphs)
            {
                const n = colrLayers(face, gid, ours[]);
                uint count = theirs.length;
                const total = hb_ot_color_glyph_get_layers(hb.face, gid, 0, &count, theirs.ptr);
                assert(n.hasValue, text(name, " glyph ", gid, ": ", n.error));
                assert(n.value == total && count == total, text(name, " glyph ", gid, ": ", n.value, " vs ", total));
                foreach (i; 0 .. count)
                {
                    assert(ours[i].glyph == theirs[i].glyph, text(name, " glyph ", gid, " layer ", i));
                    assert(ours[i].paletteEntry == theirs[i].color_index, text(name, " glyph ", gid, " layer ", i));
                }
                glyphs += count > 0;
                layers += count;
            }
        const palettes = hb_ot_color_palette_get_count(hb.face);
        const p = paletteCount(face);
        assert(p.hasValue ? p.value == palettes : palettes == 0, name);
        foreach (palette; 0 .. palettes)
        {
            hb_color_t[256] hbColours;
            uint count = hbColours.length;
            hb_ot_color_palette_get_colors(hb.face, palette, 0, &count, hbColours.ptr);
            foreach (entry; 0 .. count)
            {
                // hb_color_t packs blue, green, red and alpha from the high byte down.
                const c = hbColours[entry];
                const expected = Colour(cast(ubyte)(c >> 8), cast(ubyte)(c >> 16), cast(ubyte)(c >> 24), cast(ubyte) c);
                assert(paletteColour(face, palette, entry).value == expected, text(name, " ", palette, "/", entry));
                ++colours;
            }
        }
    }, unopened);
    stderr.writefln("oracle.colour.layersAndPalettes: %s faces with COLR or CPAL; %s layered glyphs (%s layers) "
        ~ "and %s palette colours agree with HarfBuzz; %s faces did not open", faces, glyphs, layers, colours,
        unopened);
    assert(layers > 0 && colours > 0);
}

@("oracle.colour.strikes")
@system
unittest
{
    if (fontsDir is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    size_t faces, lookups, pngs, extents, unopened;
    string[] skipped;
    eachCorpusFace((name, face, ref hb) {
        if (!face.has(Tag("CBDT")) && !face.has(Tag("sbix")))
            return;
        // HarfBuzz reads CBLC index formats 1 and 3 only, and follows sbix dupes further.
        ++faces;
        foreach (ppem; [1, 8, 15, 16, 20, 32, 64, 109, 128, 300])
        {
            hb_font_set_ppem(hb.font, ppem, ppem);
            foreach (gid; 0 .. face.numGlyphs)
            {
                const ours = bitmapGlyph(face, gid, Ppem.fromInteger(ppem).value);
                auto blob = hb_ot_color_glyph_reference_png(hb.font, gid);
                scope (exit) hb_blob_destroy(blob);
                uint length;
                const data = hb_blob_get_data(blob, &length);
                ++lookups;
                if (ours.hasError)
                {
                    assert(length == 0, text(name, " glyph ", gid, " at ", ppem, ": ", ours.error));
                    skipped ~= text(name, " glyph ", gid, ": ", ours.error.kind);
                    continue;
                }
                const g = ours.value;
                if (length == 0)
                {
                    assert(g.source == ColourSource.none || g.png.length == 0,
                        text(name, " glyph ", gid, " at ", ppem, ": ours has a PNG"));
                    continue;
                }
                assert(g.source != ColourSource.none, text(name, " glyph ", gid, " at ", ppem, ": HarfBuzz has a PNG"));
                const offset = cast(size_t)(cast(const(ubyte)*) data - face.bytes.ptr);
                assert(offset == g.pngOffset && length == g.png.length,
                    text(name, " glyph ", gid, " at ", ppem, ": ", offset, "+", length, " vs ", g.pngOffset, "+",
                        g.png.length));
                ++pngs;

                // HarfBuzz's extents, at a scale of one unit a unit, are the strike box in font units.
                hb_glyph_extents_t e;
                if (hb_font_get_glyph_extents(hb.font, gid, &e))
                {
                    const scale = cast(double) face.unitsPerEm / g.strikePpem;
                    long units(double v) => cast(long)(v * scale + (v < 0 ? -0.5 : 0.5));
                    assert(abs(e.x_bearing - units(g.bearingX)) <= 1 && abs(e.y_bearing - units(g.bearingY)) <= 1
                        && abs(e.width - units(g.width)) <= 1 && abs(e.height + units(g.height)) <= 1,
                        text(name, " glyph ", gid, " at ", ppem, ": ", e, " vs ", g));
                    ++extents;
                }
            }
        }
    }, unopened);
    stderr.writefln("oracle.colour.strikes: %s faces with CBDT or sbix, %s lookups; %s PNGs are the bytes "
        ~ "HarfBuzz picks, %s with its extents to a unit; %s lookups errors here and absent there: %s",
        faces, lookups, pngs, extents, skipped.length, skipped.length > 4 ? skipped[0 .. 4] : skipped);
    assert(pngs > 3_000 * 5);
}

private long abs(long v) => v < 0 ? -v : v;
