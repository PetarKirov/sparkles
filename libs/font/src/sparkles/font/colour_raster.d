/**
Colour glyph rendering (`docs/specs/font/SPEC.md` FTR5, FTR7): the
vocabulary shared by layered `COLR` glyphs (`sparkles.font.colr`) and
bitmap strikes (`sparkles.font.bitmap`), and the dispatch between them.

A colour glyph renders into a caller-owned premultiplied RGBA region,
four bytes a pixel in red, green, blue, alpha order. Like the grayscale
rasterizer, it is measured first (`colourMeasure`), which reports the box
and the storage the render needs, and then drawn (`rasterizeColourGlyph`)
with nothing allocated.

A glyph with `COLR` version 0 layers renders from them, since they scale
exactly; otherwise one with a `CBDT` or `sbix` bitmap renders from its
strike. Any other glyph has no colour form: its `source` is `none`, and
the caller renders its outline in grayscale.
*/
module sparkles.font.colour_raster;

import sparkles.font.bitmap : bitmapMeasure, rasterizeBitmapGlyph;
import sparkles.font.colr : colrMeasure, rasterizeColrGlyph;
import sparkles.font.errors : FontResult;
import sparkles.font.instance : Instance;
import sparkles.font.raster : RasterWorkspace;
import sparkles.font.units : Ppem;

@safe pure nothrow @nogc:

/// A straight (not premultiplied) sRGB colour with alpha, as `CPAL` stores it.
struct Colour
{
    ubyte red, green, blue, alpha;
}

/// A caller-owned premultiplied RGBA region: `height` rows of `stride` bytes, four a pixel.
struct ColourRegion
{
    @safe pure nothrow @nogc:

    ubyte[] data;
    size_t stride;
    int width, height;
}

/// Where a colour glyph's pixels come from.
enum ColourSource : ubyte
{
    /// The glyph has no colour form at this size.
    none,
    /// `COLR` version 0 layers coloured from `CPAL` (FTR5).
    layers,
    /// A `CBDT` strike's PNG (FTR7).
    cbdt,
    /// An `sbix` strike's PNG (FTR7).
    sbix,
}

/**
A colour glyph's box, where it sits from the pen, and the storage drawing
it needs. The box is in output pixels: for a bitmap, after scaling the
strike to the requested size.
*/
struct ColourGlyph
{
    @safe pure nothrow @nogc:

    /// Where the pixels come from; `none` leaves everything else zero.
    ColourSource source;
    /// The region size in pixels; zero for an empty glyph.
    int width, height;
    /// Pixels from the pen to the box's left edge, and from the baseline up to its top.
    int bearingX, bearingY;
    /// Whether nothing is drawn: no colour form, or an empty box.
    bool empty() const scope => width == 0 || height == 0;

    /// For layers: the number of layers, and the largest layer's coverage bytes.
    size_t layerCount, coverageNeeded;
    /// For layers: the accumulation floats and supersample bytes of the most demanding layer.
    size_t accumulationNeeded, supersampleNeeded;
    /// For a bitmap: the strike's ppem and its PNG's size in pixels.
    uint strikePpem, imageWidth, imageHeight;
    /// For a bitmap: the PNG's filtered scanline bytes and decoded RGBA bytes.
    size_t inflatedNeeded, imageNeeded;
    /// For a bitmap: the zlib scratch bytes, `pngZlibScratch`.
    size_t zlibNeeded;
}

/// Caller-owned storage for colour glyph rendering (FTB4).
struct ColourWorkspace
{
    /// Storage for each layer's outline, as the grayscale rasterizer uses it.
    RasterWorkspace raster;
    /// One layer's coverage: `coverageNeeded` bytes.
    ubyte[] coverage;
    /// A bitmap's filtered scanlines, decoded image and zlib state.
    ubyte[] inflated, image, zlib;
}

/**
The colour form of glyph `gid` of `inst` at `ppem`: its `COLR` version 0
layers when it has them, else its bitmap in the strike FTR7 chooses, else
`ColourSource.none`. The errors are those of `colrMeasure` and
`bitmapMeasure`.
*/
FontResult!ColourGlyph colourMeasure(in Instance inst, uint gid, Ppem ppem, return scope ColourWorkspace ws)
{
    const layered = colrMeasure(inst, gid, ppem, ws.raster);
    if (layered.hasError || layered.value.source != ColourSource.none)
        return layered;
    return bitmapMeasure(inst.face, gid, ppem);
}

/**
Draws the colour form `colourMeasure` reports for glyph `gid` into
`region`, colouring layers from palette `palette` with `foreground` for
the foreground index (FTR5). The region and the workspace must be at
least the sizes `colourMeasure` reports; a shorter one is `limitExceeded`
naming `callerStorage`. Only the box is written, every pixel of it.
*/
FontResult!ColourGlyph rasterizeColourGlyph(in Instance inst, uint gid, Ppem ppem, uint palette,
    Colour foreground, scope ColourRegion region, return scope ColourWorkspace ws)
{
    const layered = rasterizeColrGlyph(inst, gid, ppem, palette, foreground, region, ws);
    if (layered.hasError || layered.value.source != ColourSource.none)
        return layered;
    return rasterizeBitmapGlyph(inst.face, gid, ppem, region, ws);
}

/// Whether `region` holds a `width` × `height` box; else the bytes it would need.
package bool regionHolds(in ColourRegion region, int width, int height, out ulong needed)
{
    import core.checkedint : addu, mulu;

    if (region.width >= width && region.height >= height && region.stride >= 4UL * width
        && (height == 0 || region.stride * (height - 1) + 4UL * width <= region.data.length))
        return true;
    const rowSpan = region.stride < 4UL * width ? 4UL * width : ulong(region.stride);
    bool overflow;
    needed = addu(mulu(rowSpan, ulong(height > 0 ? height - 1 : 0), overflow), 4UL * width, overflow);
    if (overflow)
        needed = ulong.max;
    return false;
}
