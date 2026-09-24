/**
The image ladder on a cell target (design-system
[`GLY9`](../../../../../docs/specs/design-system/glyphs.md)): an image renders
by $(B protocol → block raster → braille → alt text), and whichever rung a
target reaches, the image keeps the cells layout gave it.

A target that composites pixels itself, or speaks an image protocol, reaches
the top rung and never comes here. Below it, the picture is drawn $(I in
cells): each cell is split into a grid of sub-cells — 1×2 for half blocks,
2×2 for quadrants, 2×3 for sextants, 2×4 for braille — each sub-cell samples
the image by area, and the cell becomes one glyph whose pattern separates its
sub-cells into two colours, the glyph's foreground and the cell's background.
That is two colours per cell, which is what a terminal cell holds.

$(LREF paintImageRaster) draws through any canvas's `fillRect` and `glyph`,
the way `paintImagePlaceholder` draws the alt rung, so the terminal and a
window previewing a narrower target share one routine and cannot drift.

Octants (2×4, Unicode 16) are not a rung yet: their code points are not a
formula over the pattern, and the table is not in the tree. A target with the
octant tier rasters in sextants.
*/
module sparkles.ui.image_raster;

import sparkles.base.term_caps : BlockTier, ImageProtocol;
import sparkles.base.term_color : RgbColor;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.image : fitRect, ImageData, ImageFit;
import sparkles.ui.style : Visual;
import sparkles.ui.tokens : TargetCapabilities;

/// The rungs of `GLY9`'s ladder, weakest first.
enum ImageRung : ubyte
{
    alt,        /// the `IMG4` placeholder: a box with `[alt text]`
    braille,    /// 2×4 dots per cell
    halfBlocks, /// `▀ ▄`: 1×2 per cell
    quadrants,  /// `▘ ▚ ▙ …`: 2×2 per cell
    sextants,   /// the Legacy Computing sextants: 2×3 per cell
    native,     /// pixels, or a terminal image protocol: not drawn in cells
}

/**
The highest rung `caps` reaches: `native` with any image protocol (or a
window's own pixels), else the finest block raster its `blocks` tier holds,
else braille, else the alt text. Every cell rung needs `unicode`.
*/
ImageRung imageRungOf(in TargetCapabilities caps) @safe pure nothrow @nogc
{
    if (caps.images != ImageProtocol.none)
        return ImageRung.native;
    if (!caps.unicode)
        return ImageRung.alt;
    if (caps.blocks >= BlockTier.sextant)
        return ImageRung.sextants;
    if (caps.blocks == BlockTier.quadrant)
        return ImageRung.quadrants;
    if (caps.blocks == BlockTier.half)
        return ImageRung.halfBlocks;
    return caps.braille ? ImageRung.braille : ImageRung.alt;
}

/// The sub-cell grid a cell rung splits each cell into.
Size subCells(ImageRung rung) @safe pure nothrow @nogc
{
    final switch (rung)
    {
        case ImageRung.alt, ImageRung.native: return Size(1, 1);
        case ImageRung.halfBlocks: return Size(1, 2);
        case ImageRung.quadrants:  return Size(2, 2);
        case ImageRung.sextants:   return Size(2, 3);
        case ImageRung.braille:    return Size(2, 4);
    }
}

/**
The glyph that draws sub-cell `pattern` in foreground on a rung — bit `i` is
sub-cell `i` in row-major order (left to right, top to bottom). A clear
pattern is a space: the cell is all background.
*/
dchar patternGlyph(ImageRung rung, uint pattern) @safe pure nothrow @nogc
in (pattern < (1u << (subCells(rung).width * subCells(rung).height)))
{
    final switch (rung)
    {
        case ImageRung.alt, ImageRung.native:
            return ' ';
        case ImageRung.halfBlocks:
            static immutable dchar[4] half = [' ', '▀', '▄', '█'];
            return half[pattern];
        case ImageRung.quadrants:
            // Bits: upper left, upper right, lower left, lower right.
            static immutable dchar[16] quad = [
                ' ', '▘', '▝', '▀', '▖', '▌', '▞', '▛',
                '▗', '▚', '▐', '▜', '▄', '▙', '▟', '█',
            ];
            return quad[pattern];
        case ImageRung.sextants:
            // U+1FB00 BLOCK SEXTANT-1 onward numbers the patterns in order,
            // skipping the four that already exist as characters: none, the
            // left and right halves, and the full block.
            if (pattern == 0)  return ' ';
            if (pattern == 21) return '▌';
            if (pattern == 42) return '▐';
            if (pattern == 63) return '█';
            return cast(dchar)(0x1FB00 + pattern - 1 - (pattern > 21) - (pattern > 42));
        case ImageRung.braille:
            // Braille numbers its dots down the left column first (1-2-3),
            // then the right (4-5-6), and the bottom row last (7, 8).
            static immutable ubyte[8] dot = [0x01, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80];
            uint bits;
            foreach (i; 0 .. 8)
                if (pattern & (1u << i))
                    bits |= dot[i];
            return bits == 0 ? ' ' : cast(dchar)(0x2800 + bits);
    }
}

/// One rastered cell: a glyph, its colour, and the cell's.
struct RasterCell
{
    dchar glyph = ' '; /// the pattern's glyph; a space for a uniform cell
    RgbColor fg;       /// the sub-cells the glyph covers
    RgbColor bg;       /// the rest
}

/**
Rasters the cell whose device-pixel region is `cell`, for an image drawn at
`placed` (device pixels, as $(REF fitRect, sparkles,ui,image) placed it).

Each sub-cell is the area average of what lies under it: the image pixels
where it overlaps the picture, composited over `backdrop`, and the backdrop
for the rest — a letterbox, or a picture thinner than a sub-cell, is mixed in
by the fraction it covers rather than kept or lost whole. The sub-cells then
split in two along the colour channel with the
widest range, at its midpoint: the brighter side is the glyph, the other the
cell's background, each its side's mean. A cell with no range is one colour
and draws as a space.
*/
RasterCell rasterCell(in ImageData img, in Rect placed, in Rect cell, ImageRung rung,
    in RgbColor backdrop) @safe pure nothrow @nogc
in (rung != ImageRung.alt && rung != ImageRung.native)
{
    const sub = subCells(rung);
    const n = sub.width * sub.height;
    RgbColor[8] samples;
    foreach (sy; 0 .. sub.height)
        foreach (sx; 0 .. sub.width)
        {
            // This sub-cell's device-pixel span, as fractions of the cell.
            const x0 = cell.x + cell.width * sx / double(sub.width);
            const x1 = cell.x + cell.width * (sx + 1) / double(sub.width);
            const y0 = cell.y + cell.height * sy / double(sub.height);
            const y1 = cell.y + cell.height * (sy + 1) / double(sub.height);
            samples[sy * sub.width + sx] = sampleArea(img, placed, x0, y0, x1, y1, backdrop);
        }
    return split(samples[0 .. n], rung);
}

// The mean of `img`'s pixels under the device-pixel box, over `backdrop`.
private RgbColor sampleArea(in ImageData img, in Rect placed,
    double x0, double y0, double x1, double y1, in RgbColor backdrop)
    @safe pure nothrow @nogc
{
    const w = img.size.width, h = img.size.height;
    if (placed.width <= 0 || placed.height <= 0 || w <= 0 || h <= 0
        || img.rgba.length < cast(size_t) w * h * 4)
        return backdrop;

    // The part of the box the picture covers, and how much of it that is.
    const ix0 = x0 > placed.x ? x0 : placed.x;
    const iy0 = y0 > placed.y ? y0 : placed.y;
    const ix1 = x1 < placed.x + placed.width ? x1 : placed.x + placed.width;
    const iy1 = y1 < placed.y + placed.height ? y1 : placed.y + placed.height;
    if (ix1 <= ix0 || iy1 <= iy0)
        return backdrop;
    const coverage = (ix1 - ix0) * (iy1 - iy0) / ((x1 - x0) * (y1 - y0));

    // That part, in image pixels: every pixel it touches.
    const sx = double(w) / placed.width, sy = double(h) / placed.height;
    int i0 = clampTo(cast(int)((ix0 - placed.x) * sx), w - 1);
    int j0 = clampTo(cast(int)((iy0 - placed.y) * sy), h - 1);
    int i1 = clampTo(cast(int)((ix1 - placed.x) * sx + 0.999), w);
    int j1 = clampTo(cast(int)((iy1 - placed.y) * sy + 0.999), h);
    if (i1 <= i0) i1 = i0 + 1;
    if (j1 <= j0) j1 = j0 + 1;

    ulong r, g, b, count;
    foreach (j; j0 .. j1)
        foreach (i; i0 .. i1)
        {
            const p = (cast(size_t) j * w + i) * 4;
            const a = img.rgba[p + 3];
            r += (img.rgba[p] * a + backdrop.r * (255 - a)) / 255;
            g += (img.rgba[p + 1] * a + backdrop.g * (255 - a)) / 255;
            b += (img.rgba[p + 2] * a + backdrop.b * (255 - a)) / 255;
            ++count;
        }
    static ubyte mix(ulong sum, ulong count, ubyte under, double coverage)
        => cast(ubyte)(sum / double(count) * coverage + under * (1 - coverage) + 0.5);
    return RgbColor(mix(r, count, backdrop.r, coverage), mix(g, count, backdrop.g, coverage),
        mix(b, count, backdrop.b, coverage));
}

private int clampTo(int v, int limit) @safe pure nothrow @nogc
    => v < 0 ? 0 : v > limit ? limit : v;

// Two colours for up to eight samples, and the pattern between them.
private RasterCell split(in RgbColor[] samples, ImageRung rung) @safe pure nothrow @nogc
{
    static int channel(in RgbColor c, int k) => k == 0 ? c.r : k == 1 ? c.g : c.b;

    int axis, lo, hi;
    int range = -1;
    foreach (k; 0 .. 3)
    {
        int mn = 255, mx = 0;
        foreach (ref s; samples)
        {
            const v = channel(s, k);
            if (v < mn) mn = v;
            if (v > mx) mx = v;
        }
        if (mx - mn > range)
        {
            range = mx - mn;
            axis = k;
            lo = mn;
            hi = mx;
        }
    }
    if (range == 0)
        return RasterCell(' ', samples[0], samples[0]);

    const mid = (lo + hi) / 2;
    uint pattern;
    uint[3] on, off;
    uint nOn, nOff;
    foreach (i, ref s; samples)
    {
        if (channel(s, axis) > mid)
        {
            pattern |= 1u << i;
            on[0] += s.r; on[1] += s.g; on[2] += s.b;
            ++nOn;
        }
        else
        {
            off[0] += s.r; off[1] += s.g; off[2] += s.b;
            ++nOff;
        }
    }
    return RasterCell(patternGlyph(rung, pattern),
        RgbColor(cast(ubyte)(on[0] / nOn), cast(ubyte)(on[1] / nOn), cast(ubyte)(on[2] / nOn)),
        RgbColor(cast(ubyte)(off[0] / nOff), cast(ubyte)(off[1] / nOff), cast(ubyte)(off[2] / nOff)));
}

/**
Draws `img` into the cells of `rect` on a cell rung, through `canvas`'s
`fillRect` and `glyph`: every cell is filled with its background, and a
patterned cell gets its glyph on top. `cellPixels` is the device size of one
cell, which fixes the sub-cells' shape and so the picture's aspect; `fit`
places the picture in the rect as it would be placed in pixels.
*/
void paintImageRaster(Canvas)(ref Canvas canvas, in Rect rect, in ImageData img,
    ImageFit fit, ImageRung rung, in Size cellPixels, in RgbColor backdrop)
in (rung != ImageRung.alt && rung != ImageRung.native)
{
    if (rect.width <= 0 || rect.height <= 0 || cellPixels.width <= 0 || cellPixels.height <= 0)
        return;

    const dest = Rect(0, 0, rect.width * cellPixels.width, rect.height * cellPixels.height);
    const placed = fitRect(dest, img.size, fit);
    foreach (cy; 0 .. rect.height)
        foreach (cx; 0 .. rect.width)
        {
            const px = Rect(cx * cellPixels.width, cy * cellPixels.height,
                cellPixels.width, cellPixels.height);
            const c = rasterCell(img, placed, px, rung, backdrop);
            const at = Point(rect.x + cx, rect.y + cy);
            Visual bg;
            bg.bg = c.bg;
            bg.hasBg = true;
            canvas.fillRect(Rect(at.x, at.y, 1, 1), bg);
            if (c.glyph != ' ')
            {
                Visual fg;
                fg.fg = c.fg;
                canvas.glyph(at, c.glyph, fg);
            }
        }
}

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.ui.glyphs : admits, needOf;
    import sparkles.ui.tokens : capabilitiesOf, Profile;

    // An image whose pixels are the given colours, row-major.
    private ImageData solid(int w, int h, in RgbColor[] px) @safe pure nothrow
    {
        auto rgba = new ubyte[](w * h * 4);
        foreach (i, c; px)
        {
            rgba[i * 4] = c.r;
            rgba[i * 4 + 1] = c.g;
            rgba[i * 4 + 2] = c.b;
            rgba[i * 4 + 3] = 0xFF;
        }
        return ImageData(rgba: rgba, size: Size(w, h));
    }

    private enum RgbColor black = RgbColor(0, 0, 0), white = RgbColor(255, 255, 255),
        red = RgbColor(200, 0, 0), blue = RgbColor(0, 0, 200);
}

@("ui.imageRaster.rungOfTheProfiles")
@safe pure nothrow @nogc
unittest
{
    // GLY9's ladder over the documented points: a pipe gets the alt text, an
    // ordinary emulator half blocks, and `full` its protocol.
    assert(imageRungOf(capabilitiesOf(Profile.baseline)) == ImageRung.alt);
    assert(imageRungOf(capabilitiesOf(Profile.enhanced)) == ImageRung.halfBlocks);
    assert(imageRungOf(capabilitiesOf(Profile.full)) == ImageRung.native);

    TargetCapabilities c = capabilitiesOf(Profile.full);
    c.images = ImageProtocol.none;
    assert(imageRungOf(c) == ImageRung.sextants, "octants raster as sextants");
    c.blocks = BlockTier.quadrant;
    assert(imageRungOf(c) == ImageRung.quadrants);
    c.blocks = BlockTier.none;
    assert(imageRungOf(c) == ImageRung.braille, "braille sits below every block tier");
    c.braille = false;
    assert(imageRungOf(c) == ImageRung.alt);
    c.blocks = BlockTier.octant;
    c.unicode = false;
    assert(imageRungOf(c) == ImageRung.alt, "no cell rung without Unicode");
}

@("ui.imageRaster.everyPatternGlyphIsOneTheTierAdmits")
@safe pure nothrow @nogc
unittest
{
    // O7: every pattern of every cell rung, exhaustively — the glyphs are
    // distinct (the pattern survives), and each is one the rung's own tier
    // admits, so the painter's glyph projection never folds a raster.
    static struct Tier { ImageRung rung; TargetCapabilities caps; }
    TargetCapabilities half = capabilitiesOf(Profile.enhanced);
    TargetCapabilities quad = half, sext = half, dots;
    quad.blocks = BlockTier.quadrant;
    sext.blocks = BlockTier.sextant;
    dots.unicode = true;
    dots.braille = true;
    const Tier[4] tiers = [Tier(ImageRung.halfBlocks, half), Tier(ImageRung.quadrants, quad),
        Tier(ImageRung.sextants, sext), Tier(ImageRung.braille, dots)];
    foreach (t; tiers)
    {
        const sub = subCells(t.rung);
        const count = 1u << (sub.width * sub.height);
        bool[0x30000] seen; // every glyph lands below U+30000
        foreach (p; 0 .. count)
        {
            const g = patternGlyph(t.rung, p);
            assert(!seen[g], "a pattern glyph is reused");
            seen[g] = true;
            assert(admits(t.caps, needOf(g)));
        }
    }
    // The sextant formula's two ends, against the code chart.
    assert(patternGlyph(ImageRung.sextants, 1) == '\U0001FB00');   // SEXTANT-1
    assert(patternGlyph(ImageRung.sextants, 62) == '\U0001FB3B');  // SEXTANT-23456
    assert(patternGlyph(ImageRung.sextants, 20) == '\U0001FB13');  // SEXTANT-35
    assert(patternGlyph(ImageRung.sextants, 22) == '\U0001FB14');  // SEXTANT-235
    // Braille's dot order: top-left is dot 1, top-right dot 4, the bottom
    // row dots 7 and 8.
    assert(patternGlyph(ImageRung.braille, 0b01) == '⠁');
    assert(patternGlyph(ImageRung.braille, 0b10) == '⠈');
    assert(patternGlyph(ImageRung.braille, 0b0100_0000) == '⡀');
    assert(patternGlyph(ImageRung.braille, 0xFF) == '⣿');
}

@("ui.imageRaster.halfBlocksCarryTwoPixelsExactly")
@safe pure nothrow
unittest
{
    // One cell, two pixels, top red over bottom blue: the upper half block
    // in red on blue — the half-block rung loses nothing.
    const img = solid(1, 2, [red, blue]);
    const c = rasterCell(img, Rect(0, 0, 1, 2), Rect(0, 0, 1, 2), ImageRung.halfBlocks, black);
    assert(c.glyph == '▀' && c.fg == red && c.bg == blue);
    // Swapped, the brighter side is still the glyph.
    const d = rasterCell(solid(1, 2, [blue, red]), Rect(0, 0, 1, 2), Rect(0, 0, 1, 2),
        ImageRung.halfBlocks, black);
    assert(d.glyph == '▄' && d.fg == red && d.bg == blue);
    // A uniform cell is a space in that colour.
    const u = rasterCell(solid(1, 2, [red, red]), Rect(0, 0, 1, 2), Rect(0, 0, 1, 2),
        ImageRung.halfBlocks, black);
    assert(u.glyph == ' ' && u.bg == red);
}

@("ui.imageRaster.quadrantsFollowThePicture")
@safe pure nothrow
unittest
{
    // A diagonal: white top-left and bottom-right on black.
    const img = solid(2, 2, [white, black, black, white]);
    const c = rasterCell(img, Rect(0, 0, 2, 2), Rect(0, 0, 2, 2), ImageRung.quadrants, black);
    assert(c.glyph == '▚' && c.fg == white && c.bg == black);
    // Braille, over a 2×4 picture with only its bottom row lit.
    const b = solid(2, 4, [black, black, black, black, black, black, white, white]);
    const d = rasterCell(b, Rect(0, 0, 2, 4), Rect(0, 0, 2, 4), ImageRung.braille, black);
    assert(d.glyph == '⣀');
}

@("ui.imageRaster.transparencyAndTheLetterboxAreTheBackdrop")
@safe pure nothrow
unittest
{
    // A clear pixel composites to the backdrop.
    ImageData img = solid(1, 2, [red, red]);
    auto rgba = img.rgba.dup;
    rgba[7] = 0; // the bottom pixel's alpha
    img.rgba = rgba;
    const c = rasterCell(img, Rect(0, 0, 1, 2), Rect(0, 0, 1, 2), ImageRung.halfBlocks, white);
    assert(c.glyph == '▀' && c.fg == white && c.bg == red || c.glyph == '▄' && c.fg == white);

    // A wide picture contained in a square: the rows above and below it are
    // the backdrop, so the aspect ratio survives the raster.
    static struct Cells
    {
        RgbColor[] bg;
        RgbColor[] fg;
        void fillRect(in Rect r, in Visual v) @safe pure nothrow { bg ~= v.bg; }
        void glyph(in Point, dchar, in Visual v) @safe pure nothrow { fg ~= v.fg; }
    }
    Cells cells;
    const wide = solid(4, 1, [red, red, red, red]);
    paintImageRaster(cells, Rect(0, 0, 2, 2), wide, ImageFit.contain, ImageRung.halfBlocks,
        Size(8, 16), blue);
    // 2×2 cells of 8×16 px: a 16×32 box, the 4:1 picture 16×4 through its
    // middle — thinner than one 8 px sub-cell, and straddling two of them.
    // The letterbox is every cell's background, and the strip is still
    // there: all four cells draw a half block tinted by the red it covers.
    assert(cells.bg == [blue, blue, blue, blue], "letterboxed above and below");
    assert(cells.fg.length == 4, "the strip is not lost between sample centres");
    foreach (tint; cells.fg)
        assert(tint.r > 0);
}
