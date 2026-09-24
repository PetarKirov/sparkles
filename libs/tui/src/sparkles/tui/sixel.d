/++
DEC sixel: an image as pixels in the terminal's cell layer (`IMG5`).

Where the kitty protocol places a picture $(I over) the cells, sixel writes it
$(I into) them — pixel rows, six at a time, at the cursor — so the terminal
keeps it only until something rewrites those cells. $(LREF SixelImages) owns
the consequences, beside the $(REF Screen, sparkles,tui,render):

$(UL
    $(LI Before the cell diff, $(LREF SixelImages.prepare) marks the cells an
        image left (it moved, or went away) as damaged, so the diff paints
        them clean.)
    $(LI After it, $(LREF SixelImages.emit) draws each image that is new, has
        moved, has new pixels, or had any of its cells rewritten this frame.)
)

$(LREF writeSixel) encodes one placement at the terminal's real cell size:
the picture scaled to `cols`×`rows` cells, shifted and cropped the way the
kitty placement is, so both protocols draw the same thing in the same place.
Colours come from a fixed 6×7×6 palette (252 entries) — deterministic, and
enough for a picture in a terminal — and runs are length-coded.
+/
module sparkles.tui.sixel;

import std.range.primitives : put;

import sparkles.base.term_control : writeCursorTo;
import sparkles.base.text.writers : writeInteger;
import sparkles.tui.images : ImagePlacement;

/// The device size of one terminal cell, in pixels.
struct CellPixels
{
    ushort width;  /// pixels across
    ushort height; /// pixels down
}

// A palette index for an RGB colour: 6 levels of red and blue, 7 of green.
private ubyte paletteIndex(ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
    => cast(ubyte)(((r * 5 + 127) / 255) * 42 + ((g * 6 + 127) / 255) * 6
        + (b * 5 + 127) / 255);

// The palette entry's colour, as sixel's 0–100 percentages.
private void paletteRgb(ubyte index, out uint r, out uint g, out uint b)
    @safe pure nothrow @nogc
{
    r = (index / 42) * 100 / 5;
    g = ((index / 6) % 7) * 100 / 6;
    b = (index % 6) * 100 / 5;
}

private enum ubyte transparent = 255;

/**
Encodes `p` as one sixel sequence for cells of `cell` pixels. Pixels with
alpha below half, and the margin an offset leaves, are transparent: the
sequence asks the terminal to keep the cell background under them.
*/
void writeSixel(Writer)(ref Writer w, in ImagePlacement p, in CellPixels cell)
{
    const W = p.cols * cell.width, H = p.rows * cell.height;
    if (W <= 0 || H <= 0 || p.width == 0 || p.height == 0
        || p.rgba.length < cast(size_t) p.width * p.height * 4)
        return;

    // The source rectangle, and the scaled picture's extent inside the box.
    const cx = p.cropW && p.cropH ? p.cropX : 0, cy = p.cropW && p.cropH ? p.cropY : 0;
    const cw = p.cropW && p.cropH ? p.cropW : p.width, chh = p.cropW && p.cropH ? p.cropH : p.height;

    auto index = new ubyte[](cast(size_t) W * H);
    bool[252] used;
    foreach (y; 0 .. H)
        foreach (x; 0 .. W)
        {
            const u = x - p.offsetX, v = y - p.offsetY;
            ubyte idx = transparent;
            if (u >= 0 && v >= 0)
            {
                // The source pixels under this one: an area average.
                const s0 = cx + u * cw / W, s1 = cx + ((u + 1) * cw + W - 1) / W;
                const t0 = cy + v * chh / H, t1 = cy + ((v + 1) * chh + H - 1) / H;
                if (s0 < cx + cw && t0 < cy + chh)
                {
                    uint r, g, b, a, n;
                    foreach (t; t0 .. (t1 > t0 ? t1 : t0 + 1))
                        foreach (s; s0 .. (s1 > s0 ? s1 : s0 + 1))
                        {
                            if (s >= p.width || t >= p.height)
                                continue;
                            const k = (cast(size_t) t * p.width + s) * 4;
                            r += p.rgba[k];
                            g += p.rgba[k + 1];
                            b += p.rgba[k + 2];
                            a += p.rgba[k + 3];
                            ++n;
                        }
                    if (n && a / n >= 128)
                    {
                        idx = paletteIndex(cast(ubyte)(r / n), cast(ubyte)(g / n),
                            cast(ubyte)(b / n));
                        used[idx] = true;
                    }
                }
            }
            index[cast(size_t) y * W + x] = idx;
        }

    // DCS: aspect 1:1 (P1 0 with raster attributes), P2=1 keeps the
    // background under transparent pixels.
    put(w, "\x1bP0;1;0q\"1;1;");
    writeInteger(w, W);
    put(w, ';');
    writeInteger(w, H);
    foreach (i, u; used)
        if (u)
        {
            uint r, g, b;
            paletteRgb(cast(ubyte) i, r, g, b);
            put(w, '#');
            writeInteger(w, i);
            put(w, ";2;");
            writeInteger(w, r);
            put(w, ';');
            writeInteger(w, g);
            put(w, ';');
            writeInteger(w, b);
        }

    // Six pixel rows per band; within a band, one pass per colour in it,
    // each pass returning to the band's start with `$`.
    for (int band = 0; band < H; band += 6)
    {
        bool[252] inBand;
        foreach (y; band .. (band + 6 < H ? band + 6 : H))
            foreach (x; 0 .. W)
            {
                const idx = index[cast(size_t) y * W + x];
                if (idx != transparent)
                    inBand[idx] = true;
            }
        bool firstPass = true;
        foreach (c, present; inBand)
        {
            if (!present)
                continue;
            if (!firstPass)
                put(w, '$');
            firstPass = false;
            put(w, '#');
            writeInteger(w, c);
            char run;
            int runLength;
            void flush()
            {
                if (runLength == 0)
                    return;
                if (runLength > 3)
                {
                    put(w, '!');
                    writeInteger(w, runLength);
                    put(w, run);
                }
                else
                    foreach (_; 0 .. runLength)
                        put(w, run);
                runLength = 0;
            }
            foreach (x; 0 .. W)
            {
                uint bits;
                foreach (k; 0 .. 6)
                {
                    const y = band + k;
                    if (y < H && index[cast(size_t) y * W + x] == c)
                        bits |= 1u << k;
                }
                const ch = cast(char)(63 + bits);
                if (runLength && ch != run)
                    flush();
                run = ch;
                ++runLength;
            }
            // A pass's trailing blanks draw nothing: leave them off.
            if (run != '?')
                flush();
            runLength = 0;
        }
        put(w, '-');
    }
    put(w, "\x1b\\");
}

/**
The terminal's side of the sixel images: which ones it shows, and where. One
per output surface, beside the $(REF Screen, sparkles,tui,render).
*/
struct SixelImages
{
    private
    {
        static struct Shown
        {
            ImagePlacement where; // geometry and identity; pixels not retained
            bool drawn;
        }
        Shown[] _shown;
    }

    /**
    Before the cell diff: gives `damage` the rect of every image that is not
    in `frame` at the same place with the same pixels, so the diff repaints
    the cells it left behind. `damage` is `(x, y, cols, rows)`.
    */
    void prepare(Damage)(in ImagePlacement[] frame, scope Damage damage)
    {
        foreach (ref s; _shown)
        {
            bool kept;
            foreach (ref f; frame)
                kept |= same(s.where, f);
            if (!kept)
                damage(s.where.x, s.where.y, s.where.cols, s.where.rows);
        }
    }

    /**
    After the cell diff: draws every image in `frame` that the terminal does
    not show as it is — new, moved, new pixels, `repaint`, or any of its cells
    rewritten this frame (`rewritten[i]` for `frame[i]`, found before the diff
    ran, while the retained grid still held the last frame) — and remembers
    what is shown.
    */
    void emit(Writer)(ref Writer w, in ImagePlacement[] frame,
        in CellPixels cell, bool repaint, in bool[] rewritten)
    in (rewritten.length == frame.length)
    {
        Shown[] next;
        foreach (i, ref f; frame)
        {
            bool shown;
            foreach (ref s; _shown)
                shown |= s.drawn && same(s.where, f);
            if (!shown || repaint || rewritten[i])
            {
                writeCursorTo(w, cast(uint)(f.y + 1), cast(uint)(f.x + 1));
                writeSixel(w, f, cell);
            }
            next ~= Shown(f, true);
        }
        _shown = next;
    }

    private static bool same(in ImagePlacement a, in ImagePlacement b) @safe pure nothrow @nogc
        => a.image == b.image && a.generation == b.generation && a.x == b.x && a.y == b.y
            && a.cols == b.cols && a.rows == b.rows && a.offsetX == b.offsetX
            && a.offsetY == b.offsetY && a.cropX == b.cropX && a.cropY == b.cropY
            && a.cropW == b.cropW && a.cropH == b.cropH;
}

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.algorithm.searching : canFind, count;
    import sparkles.base.buffer : SharedBuffer;

    private string encode(in ImagePlacement p, CellPixels cell) @safe
    {
        SharedBuffer!(char, 256) w;
        writeSixel(w, p, cell);
        return w[].idup;
    }
}

@("tui.sixel.oneRedBand")
@safe unittest
{
    // A 1×1 red picture in one 2×6 px cell: a 2×6 raster, one colour, one
    // band of two full columns (`~` is all six bits).
    static immutable ubyte[4] red = [255, 0, 0, 255];
    const s = encode(ImagePlacement(image: 1, rgba: red[], width: 1, height: 1,
        cols: 1, rows: 1), CellPixels(2, 6));
    assert(s == "\x1bP0;1;0q\"1;1;2;6#210;2;100;0;0#210~~-\x1b\\", s);
}

@("tui.sixel.runsAreLengthCoded")
@safe unittest
{
    // Ten columns of the same six pixels: one `!10~`, not ten `~`.
    static immutable ubyte[4] blue = [0, 0, 255, 255];
    const s = encode(ImagePlacement(image: 1, rgba: blue[], width: 1, height: 1,
        cols: 5, rows: 1), CellPixels(2, 6));
    assert(s.canFind("!10~") && !s.canFind("~~"));
}

@("tui.sixel.transparentPixelsAreLeftOut")
@safe unittest
{
    // A clear pixel is no colour at all: no palette entry, no pass.
    static immutable ubyte[8] halfClear = [0, 255, 0, 255, 0, 255, 0, 0];
    const s = encode(ImagePlacement(image: 1, rgba: halfClear[], width: 2, height: 1,
        cols: 1, rows: 1), CellPixels(2, 6));
    assert(s.count('#') == 2, "one palette entry and one pass");
    // The second column is clear: the pass stops after the first.
    assert(s.canFind("~-"));
}

@("tui.sixel.bandsAndPasses")
@safe unittest
{
    // A 12 px tall picture is two bands; a two-colour band is two passes
    // joined by `$`.
    static immutable ubyte[8] redOverBlue = [255, 0, 0, 255, 0, 0, 255, 255];
    const s = encode(ImagePlacement(image: 1, rgba: redOverBlue[], width: 1, height: 2,
        cols: 1, rows: 2), CellPixels(1, 6));
    assert(s.count('-') == 2);
    // 1 px wide, 12 tall, top half red: the first band red, the second blue.
    assert(s.canFind("#210~-#5~-"), s);
}

@("tui.sixel.imagesRedrawWhenTheirCellsAre")
@safe unittest
{
    static immutable ubyte[4] px = [1, 2, 3, 255];
    const a = ImagePlacement(image: 1, rgba: px[], width: 1, height: 1, x: 2, y: 1,
        cols: 2, rows: 1);
    SixelImages s;
    int[4][] damaged;
    bool rewrite;
    string frame(in ImagePlacement[] f, bool repaint = false)
    {
        damaged = null;
        s.prepare(f, (int x, int y, int c, int r) { damaged ~= [x, y, c, r]; });
        SharedBuffer!(char, 256) w;
        auto flags = new bool[](f.length);
        flags[] = rewrite;
        s.emit(w, f, CellPixels(2, 6), repaint, flags);
        return w[].idup;
    }

    // New: drawn at its cell.
    assert(frame([a]).canFind("\x1b[2;3H\x1bP"));
    // Steady: nothing — unless its cells were rewritten this frame.
    assert(frame([a]) == "");
    rewrite = true;
    assert(frame([a]).canFind("\x1bP"));
    rewrite = false;
    // Moved: the old cells are damaged for the diff to clean, and it is
    // drawn at the new place.
    ImagePlacement b = a;
    b.x = 4;
    assert(frame([b]).canFind("\x1b[2;5H\x1bP"));
    assert(damaged == [[2, 1, 2, 1]]);
    // Gone: its cells are damaged, and nothing is drawn.
    assert(frame([]) == "" && damaged == [[4, 1, 2, 1]]);
}
