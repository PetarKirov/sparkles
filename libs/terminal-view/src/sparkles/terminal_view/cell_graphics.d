/**
Font-independent terminal pixel graphics. Integer partitions share endpoints,
including at odd cell sizes; every emitted rectangle covers disjoint pixels.
The private geometry visitor is shared by the atlas renderer and pixel-oracle
unittests, and never allocates. Smooth mosaics use pixel-centre scan conversion
rather than a second texture, preserving the glyph atlas batch.
*/
module sparkles.terminal_view.cell_graphics;

import std.algorithm : min, max;
import std.math : ceil, fabs;

import raylib : Color;

import sparkles.raylib_text.draw : drawSolid;
import sparkles.raylib_text.font : LoadedFont;

/**
Draw a supported block, mosaic, braille, octant or legacy-computing graphic.
Returns false without drawing for other codepoints. Like drawBox, the cell
origin is snapped to integer pixels. Needs an active GL context and uses the
same white atlas texel as drawSolid, with no per-cell storage allocation.
*/
bool drawCellGraphics(ref LoadedFont white, uint cp, float x, float y,
    int width, int height, Color tint) @system nothrow @nogc
{
    return visitCellGraphics(cp, width, height,
        (int rx, int ry, int rw, int rh, ubyte coverage) @system nothrow @nogc
        {
            if (rw <= 0 || rh <= 0)
                return;
            auto color = tint;
            color.a = cast(ubyte)((cast(uint) tint.a * coverage + 127) / 255);
            drawSolid(white, cast(int) x + rx, cast(int) y + ry, rw, rh, color);
        });
}

// All tables describe Unicode character semantics, not font outlines.
// Sources checked against the local notcurses include/notcurses/ncseqs.h
// (NCOCTBLOCKS, NCANGLES*, NCEIGHTHS*, NCSEGDIGITS), src/lib/blit.c
// (sextrans/octtrans), and Ghostty src/font/sprite/draw/
// symbols_for_legacy_computing.zig (draw1FB3C_1FB67, draw1FB68_1FB6F,
// draw1FBA0_1FBAE). Ghostty is the repository's pinned flake input.
// Unicode reference: https://www.unicode.org/charts/PDF/U1FB00.pdf
// Octants: https://www.unicode.org/charts/PDF/U1CC00.pdf
// The 44 smooth-mosaic patterns below are boundary vertices, in four rows
// of three points, not a bitmap. '#' selects a vertex on the cell perimeter.
private immutable string[44] mosaicPatterns = [
    "..." ~ "..." ~ "#.." ~ "##.", // 1FB3C
    "..." ~ "..." ~ "#.." ~ "###",
    "..." ~ "#.." ~ "#.." ~ "##.",
    "..." ~ "#.." ~ "##." ~ "###",
    "#.." ~ "#.." ~ "##." ~ "##.",
    ".##" ~ "###" ~ "###" ~ "###",
    "..#" ~ "###" ~ "###" ~ "###",
    ".##" ~ ".##" ~ "###" ~ "###",
    "..#" ~ ".##" ~ "###" ~ "###",
    ".##" ~ ".##" ~ ".##" ~ "###",
    "..." ~ "..#" ~ "###" ~ "###",
    "..." ~ "..." ~ "..#" ~ ".##", // 1FB47
    "..." ~ "..." ~ "..#" ~ "###",
    "..." ~ "..#" ~ "..#" ~ ".##",
    "..." ~ "..#" ~ ".##" ~ "###",
    "..#" ~ "..#" ~ ".##" ~ ".##",
    "##." ~ "###" ~ "###" ~ "###",
    "#.." ~ "###" ~ "###" ~ "###",
    "##." ~ "##." ~ "###" ~ "###",
    "#.." ~ "##." ~ "###" ~ "###",
    "##." ~ "##." ~ "##." ~ "###",
    "..." ~ "#.." ~ "###" ~ "###",
    "###" ~ "###" ~ "###" ~ ".##", // 1FB52
    "###" ~ "###" ~ "###" ~ "..#",
    "###" ~ "###" ~ ".##" ~ ".##",
    "###" ~ "###" ~ ".##" ~ "..#",
    "###" ~ ".##" ~ ".##" ~ ".##",
    "##." ~ "#.." ~ "..." ~ "...",
    "###" ~ "#.." ~ "..." ~ "...",
    "##." ~ "#.." ~ "#.." ~ "...",
    "###" ~ "##." ~ "#.." ~ "...",
    "##." ~ "##." ~ "#.." ~ "#..",
    "###" ~ "###" ~ "#.." ~ "...",
    "###" ~ "###" ~ "###" ~ "##.", // 1FB5D
    "###" ~ "###" ~ "###" ~ "#..",
    "###" ~ "###" ~ "##." ~ "##.",
    "###" ~ "###" ~ "##." ~ "#..",
    "###" ~ "##." ~ "##." ~ "##.",
    ".##" ~ "..#" ~ "..." ~ "...",
    "###" ~ "..#" ~ "..." ~ "...",
    ".##" ~ "..#" ~ "..#" ~ "...",
    "###" ~ ".##" ~ "..#" ~ "...",
    ".##" ~ ".##" ~ "..#" ~ "..#",
    "###" ~ "###" ~ "..#" ~ "...", // 1FB67
];

// NCOCTBLOCKS enumerates occupied bits in row-major order. These 26 masks
// already have characters elsewhere; the remaining masks, ascending, are
// exactly U+1CD00..U+1CDE5. CTFE constructs the direct O(1) lookup.
private enum ubyte[26] existingOctants = [
    0, 1, 2, 3, 5, 10, 15, 20, 40, 63, 64, 80, 85,
    90, 95, 128, 160, 165, 170, 175, 192, 240, 245, 250, 252, 255,
];
private immutable ubyte[230] octantMasks = makeOctantMasks();

private ubyte[230] makeOctantMasks() @safe pure nothrow @nogc
{
    ubyte[230] result;
    size_t outIndex, skip;
    foreach (mask; 0 .. 256)
    {
        if (skip < existingOctants.length && mask == existingOctants[skip])
            ++skip;
        else
            result[outIndex++] = cast(ubyte) mask;
    }
    assert(outIndex == result.length && skip == existingOctants.length);
    return result;
}

private int edge(int extent, int index, int count) @safe pure nothrow @nogc
    => cast(int)((cast(long) extent * index) / count);

// Emit receives integer x/y/width/height and foreground coverage. Templates
// infer purity/safety: a test sink is pure while the production sink calls GL.
private void grid(Emit)(uint mask, int cols, int rows, int w, int h, scope Emit emit)
{
    const rowBits = (1u << cols) - 1;
    int row;
    while (row < rows)
    {
        const startRow = row;
        const rowMask = (mask >> (row * cols)) & rowBits;
        while (++row < rows && ((mask >> (row * cols)) & rowBits) == rowMask)
        {
        }
        const y0 = edge(h, startRow, rows), y1 = edge(h, row, rows);
        int col;
        while (col < cols)
        {
            if (!(rowMask & (1u << col)))
            {
                ++col;
                continue;
            }
            const start = col++;
            while (col < cols && (rowMask & (1u << col)))
                ++col;
            const x0 = edge(w, start, cols), x1 = edge(w, col, cols);
            if (x0 < x1 && y0 < y1)
                emit(x0, y0, x1 - x0, y1 - y0, cast(ubyte) 255);
        }
    }
}

private struct Point
{
    double x, y;
}

// Convex perimeter polygon. Half-open pixel-centre sampling gives complementary
// mosaics exactly one owner for diagonal pixels as well as axis-aligned edges.
private void polygon(Emit)(scope const(Point)[] points, int w, int h,
    bool inverse, scope Emit emit)
{
    foreach (y; 0 .. h)
    {
        double left = w, right = 0;
        const scan = y + 0.5;
        foreach (i, a; points)
        {
            const b = points[(i + 1) % points.length];
            if ((a.y <= scan && scan < b.y) || (b.y <= scan && scan < a.y))
            {
                const x = a.x + (scan - a.y) * (b.x - a.x) / (b.y - a.y);
                left = min(left, x);
                right = max(right, x);
            }
        }
        const x0 = max(0, min(w, cast(int) ceil(left - 0.5)));
        const x1 = max(x0, min(w, cast(int) ceil(right - 0.5)));
        if (inverse)
        {
            if (x0 > 0)
                emit(0, y, x0, 1, cast(ubyte) 255);
            if (x1 < w)
                emit(x1, y, w - x1, 1, cast(ubyte) 255);
        }
        else if (x0 < x1)
            emit(x0, y, x1 - x0, 1, cast(ubyte) 255);
    }
}

// Unicode box-drawing arm styles, checked against Ghostty box.zig's
// draw2500_257F. Four digits per codepoint: up/right/down/left, with
// 0 = absent, 1 = light, 2 = heavy, 3 = double. Zero entries are the
// dashed, rounded and diagonal forms handled separately below.
private enum boxArms =
    "0101" ~ "0202" ~ "1010" ~ "2020" ~ "0000" ~ "0000" ~ "0000" ~ "0000" ~
    "0000" ~ "0000" ~ "0000" ~ "0000" ~ "0110" ~ "0210" ~ "0120" ~ "0220" ~
    "0011" ~ "0012" ~ "0021" ~ "0022" ~ "1100" ~ "1200" ~ "2100" ~ "2200" ~
    "1001" ~ "1002" ~ "2001" ~ "2002" ~ "1110" ~ "1210" ~ "2110" ~ "1120" ~
    "2120" ~ "2210" ~ "1220" ~ "2220" ~ "1011" ~ "1012" ~ "2011" ~ "1021" ~
    "2021" ~ "2012" ~ "1022" ~ "2022" ~ "0111" ~ "0112" ~ "0211" ~ "0212" ~
    "0121" ~ "0122" ~ "0221" ~ "0222" ~ "1101" ~ "1102" ~ "1201" ~ "1202" ~
    "2101" ~ "2102" ~ "2201" ~ "2202" ~ "1111" ~ "1112" ~ "1211" ~ "1212" ~
    "2111" ~ "1121" ~ "2121" ~ "2112" ~ "2211" ~ "1122" ~ "1221" ~ "2212" ~
    "1222" ~ "2122" ~ "2221" ~ "2222" ~ "0000" ~ "0000" ~ "0000" ~ "0000" ~
    "0303" ~ "3030" ~ "0310" ~ "0130" ~ "0330" ~ "0013" ~ "0031" ~ "0033" ~
    "1300" ~ "3100" ~ "3300" ~ "1003" ~ "3001" ~ "3003" ~ "1310" ~ "3130" ~
    "3330" ~ "1013" ~ "3031" ~ "3033" ~ "0313" ~ "0131" ~ "0333" ~ "1303" ~
    "3101" ~ "3303" ~ "1313" ~ "3131" ~ "3333" ~ "0000" ~ "0000" ~ "0000" ~
    "0000" ~ "0000" ~ "0000" ~ "0000" ~ "0001" ~ "1000" ~ "0100" ~ "0010" ~
    "0002" ~ "2000" ~ "0200" ~ "0020" ~ "0201" ~ "1020" ~ "0102" ~ "2010";
static assert(boxArms.length == 128 * 4);

private struct CellRect
{
    int x0, y0, x1, y1;
}

private struct BoxRects
{
    CellRect[8] rects;
    size_t count;

    void add(int x0, int y0, int x1, int y1) @safe pure nothrow @nogc
    {
        if (x0 < x1 && y0 < y1)
            rects[count++] = CellRect(x0, y0, x1, y1);
    }
}

// Sweep only rectangle endpoints, not pixels. Normal box glyphs need at most
// eight arms/rails; their union avoids alpha overdraw at joins while emitting
// long rectangles rather than a draw call per scanline.
private void rectUnion(Emit)(ref BoxRects shape, scope Emit emit)
{
    int[16] ys;
    size_t ny;
    foreach (rect; shape.rects[0 .. shape.count])
    {
        foreach (value; [rect.y0, rect.y1])
        {
            size_t i;
            while (i < ny && ys[i] < value)
                ++i;
            if (i < ny && ys[i] == value)
                continue;
            for (size_t j = ny; j > i; --j)
                ys[j] = ys[j - 1];
            ys[i] = value;
            ++ny;
        }
    }
    foreach (i; 1 .. ny)
    {
        CellRect[8] spans;
        size_t ns;
        foreach (rect; shape.rects[0 .. shape.count])
        {
            if (rect.y0 > ys[i - 1] || rect.y1 < ys[i])
                continue;
            size_t j = ns;
            while (j > 0 && spans[j - 1].x0 > rect.x0)
            {
                spans[j] = spans[j - 1];
                --j;
            }
            spans[j] = rect;
            ++ns;
        }
        size_t j;
        while (j < ns)
        {
            const x0 = spans[j].x0;
            int x1 = spans[j++].x1;
            while (j < ns && spans[j].x0 <= x1)
                x1 = max(x1, spans[j++].x1);
            emit(x0, ys[i - 1], x1 - x0, ys[i] - ys[i - 1], cast(ubyte) 255);
        }
    }
}

private void box(Emit)(uint cp, int w, int h, scope Emit emit)
{
    const light = max(1, min(w, h) / 8);
    const heavy = min(min(w, h), 2 * light);
    const vl = (w - light) / 2, vr = vl + light;
    const ht = (h - light) / 2, hb = ht + light;
    const vhl = (w - heavy) / 2, vhr = vhl + heavy;
    const hht = (h - heavy) / 2, hhb = hht + heavy;
    const vdl = max(0, vl - light), vdr = min(w, vr + light);
    const hdt = max(0, ht - light), hdb = min(h, hb + light);
    if ((cp >= 0x2504 && cp <= 0x250b) || (cp >= 0x254c && cp <= 0x254f))
    {
        const count = cp >= 0x254c ? 2 : cp < 0x2508 ? 3 : 4;
        const vertical = (cp & 2) != 0;
        const thick = (cp & 1) ? heavy : light;
        foreach (i; 0 .. count)
        {
            const extent = vertical ? h : w;
            const a = edge(extent, 2 * i, 2 * count - 1);
            const b = edge(extent, 2 * i + 1, 2 * count - 1);
            if (a < b)
            {
                if (vertical)
                    emit((w - thick) / 2, a, thick, b - a, cast(ubyte) 255);
                else
                    emit(a, (h - thick) / 2, b - a, thick, cast(ubyte) 255);
            }
        }
        return;
    }
    if (cp >= 0x256d && cp <= 0x2573)
    {
        const rounded = cp <= 0x2570;
        const sx = cp == 0x256d || cp == 0x2570 ? 1 : -1;
        const sy = cp <= 0x256e ? 1 : -1;
        const cx = vl + light / 2.0, cy = ht + light / 2.0;
        const radius = min(w, h) / 3.0;
        const inner = max(0.0, radius - light / 2.0);
        const outer = radius + light / 2.0;
        // Distance-to-line in pixel space (squared), not a slope-scaled
        // thickness; both diagonals have the same apparent stroke weight.
        const tolerance = light * light * (cast(double) w * w + cast(double) h * h) / 4;
        foreach (y; 0 .. h)
        {
            int start = -1;
            foreach (x; 0 .. w + 1)
            {
                bool covered;
                if (x < w)
                {
                    if (rounded)
                    {
                        const dx = (x + 0.5 - cx) * sx, dy = (y + 0.5 - cy) * sy;
                        const distance = (dx - radius) * (dx - radius) + (dy - radius) * (dy - radius);
                        covered = (dx >= radius && fabs(dy) < light / 2.0) ||
                            (dy >= radius && fabs(dx) < light / 2.0) ||
                            (dx <= radius && dy <= radius && distance >= inner * inner && distance < outer * outer);
                    }
                    else
                    {
                        const rising = (x + 0.5) * h + (y + 0.5) * w - cast(double) w * h;
                        const falling = (x + 0.5) * h - (y + 0.5) * w;
                        covered = (cp != 0x2572 && rising * rising <= tolerance) ||
                            (cp != 0x2571 && falling * falling <= tolerance);
                    }
                }
                if (covered && start < 0)
                    start = x;
                else if (!covered && start >= 0)
                {
                    emit(start, y, x - start, 1, cast(ubyte) 255);
                    start = -1;
                }
            }
        }
        return;
    }
    const index = (cp - 0x2500) * 4;
    const up = boxArms[index] - '0', right = boxArms[index + 1] - '0';
    const down = boxArms[index + 2] - '0', left = boxArms[index + 3] - '0';
    // Join extents follow Ghostty linesChar: doubled corners turn each rail
    // independently, and tees leave the channel between parallel rails open.
    const ub = left == 2 || right == 2 ? hhb :
        left != right || down == up ? (left == 3 || right == 3 ? hdb : hb) :
        left == 0 && right == 0 ? hb : ht;
    const dt = left == 2 || right == 2 ? hht :
        left != right || up == down ? (left == 3 || right == 3 ? hdt : ht) :
        left == 0 && right == 0 ? ht : hb;
    const lr = up == 2 || down == 2 ? vhr :
        up != down || left == right ? (up == 3 || down == 3 ? vdr : vr) :
        up == 0 && down == 0 ? vr : vl;
    const rl = up == 2 || down == 2 ? vhl :
        up != down || right == left ? (up == 3 || down == 3 ? vdl : vl) :
        up == 0 && down == 0 ? vl : vr;
    BoxRects shape;
    if (up == 1) shape.add(vl, 0, vr, ub);
    if (up == 2) shape.add(vhl, 0, vhr, ub);
    if (up == 3)
    {
        shape.add(vdl, 0, vl, left == 3 ? ht : ub);
        shape.add(vr, 0, vdr, right == 3 ? ht : ub);
    }
    if (down == 1) shape.add(vl, dt, vr, h);
    if (down == 2) shape.add(vhl, dt, vhr, h);
    if (down == 3)
    {
        shape.add(vdl, left == 3 ? hb : dt, vl, h);
        shape.add(vr, right == 3 ? hb : dt, vdr, h);
    }
    if (left == 1) shape.add(0, ht, lr, hb);
    if (left == 2) shape.add(0, hht, lr, hhb);
    if (left == 3)
    {
        shape.add(0, hdt, up == 3 ? vl : lr, ht);
        shape.add(0, hb, down == 3 ? vl : lr, hdb);
    }
    if (right == 1) shape.add(rl, ht, w, hb);
    if (right == 2) shape.add(rl, hht, w, hhb);
    if (right == 3)
    {
        shape.add(up == 3 ? vr : rl, hdt, w, ht);
        shape.add(down == 3 ? vr : rl, hb, w, hdb);
    }
    rectUnion(shape, emit);
}

private bool visitCellGraphics(Emit)(uint cp, int w, int h, scope Emit emit)
{
    if (w <= 0 || h <= 0)
        return false;
    if (cp >= 0x2500 && cp <= 0x257f)
    {
        box(cp, w, h, emit);
        return true;
    }
    if (cp >= 0x2580 && cp <= 0x259f)
    {
        if (cp == 0x2580)
            grid(1, 1, 2, w, h, emit);
        else if (cp <= 0x2588)
            grid(0xffu << (8 - (cp - 0x2580)), 1, 8, w, h, emit);
        else if (cp <= 0x258f)
            grid((1u << (0x2590 - cp)) - 1, 8, 1, w, h, emit);
        else if (cp == 0x2590)
            grid(2, 2, 1, w, h, emit);
        else if (cp <= 0x2593)
            emit(0, 0, w, h, cast(ubyte)((cp - 0x2590) * 64));
        else if (cp == 0x2594)
            grid(1, 1, 8, w, h, emit);
        else if (cp == 0x2595)
            grid(128, 8, 1, w, h, emit);
        else
        {
            enum ubyte[10] masks = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14];
            grid(masks[cp - 0x2596], 2, 2, w, h, emit);
        }
        return true;
    }
    if (cp >= 0x1fb00 && cp <= 0x1fb3b)
    {
        const index = cp - 0x1fb00;
        grid(index + index / 20 + 1, 2, 3, w, h, emit);
        return true;
    }
    if (cp >= 0x2800 && cp <= 0x28ff)
    {
        // Unicode dot numbers: 1 4 / 2 5 / 3 6 / 7 8, not row-major.
        enum ubyte[8] bits = [0, 3, 1, 4, 2, 5, 6, 7];
        foreach (i, bit; bits)
        {
            if (!((cp - 0x2800) & (1u << bit)))
                continue;
            const col = cast(int)(i % 2), row = cast(int)(i / 2);
            const x0 = edge(w, col, 2), x1 = edge(w, col + 1, 2);
            const y0 = edge(h, row, 4), y1 = edge(h, row + 1, 4);
            const mx = (x1 - x0) / 4, my = (y1 - y0) / 4;
            if (x0 < x1 && y0 < y1)
                emit(x0 + mx, y0 + my, x1 - x0 - 2 * mx,
                    y1 - y0 - 2 * my, cast(ubyte) 255);
        }
        return true;
    }
    if (cp >= 0x1cd00 && cp <= 0x1cde5)
    {
        grid(octantMasks[cp - 0x1cd00], 2, 4, w, h, emit);
        return true;
    }
    uint octant;
    switch (cp)
    {
    case 0x1cea8: octant = 1; break;
    case 0x1ceab: octant = 2; break;
    case 0x1cea3: octant = 64; break;
    case 0x1cea0: octant = 128; break;
    case 0x1fbe6: octant = 20; break;
    case 0x1fbe7: octant = 40; break;
    default: break;
    }
    if (octant)
    {
        grid(octant, 2, 4, w, h, emit);
        return true;
    }
    if (cp >= 0x1fb3c && cp <= 0x1fb67)
    {
        enum ubyte[10] perimeter = [0, 3, 6, 9, 10, 11, 8, 5, 2, 1];
        const pattern = mosaicPatterns[cp - 0x1fb3c];
        Point[10] vertices;
        size_t count;
        foreach (i; perimeter)
            if (pattern[i] == '#')
                vertices[count++] = Point((i % 3) * (w / 2.0), (i / 3) * (h / 3.0));
        polygon(vertices[0 .. count], w, h, false, emit);
        return true;
    }
    if (cp >= 0x1fb68 && cp <= 0x1fb6f)
    {
        Point[3] vertices;
        vertices[0] = Point(w / 2.0, h / 2.0);
        switch ((cp - 0x1fb68) % 4)
        {
        case 0: vertices[1] = Point(0, 0); vertices[2] = Point(0, h); break;
        case 1: vertices[1] = Point(0, 0); vertices[2] = Point(w, 0); break;
        case 2: vertices[1] = Point(w, 0); vertices[2] = Point(w, h); break;
        default: vertices[1] = Point(0, h); vertices[2] = Point(w, h); break;
        }
        polygon(vertices[], w, h, cp < 0x1fb6c, emit);
        return true;
    }
    if (cp >= 0x1fb70 && cp <= 0x1fb7b)
    {
        const vertical = cp <= 0x1fb75;
        const bit = cp - (vertical ? 0x1fb70 : 0x1fb76) + 1;
        grid(1u << bit, vertical ? 8 : 1, vertical ? 1 : 8, w, h, emit);
        return true;
    }
    if (cp >= 0x1fb7c && cp <= 0x1fb7f)
    {
        const left = cp < 0x1fb7e;
        const top = cp == 0x1fb7d || cp == 0x1fb7e;
        const x = edge(w, left ? 1 : 7, 8);
        const y = edge(h, top ? 1 : 7, 8);
        if (left && x > 0)
            emit(0, 0, x, h, cast(ubyte) 255);
        if (!left && x < w)
            emit(x, 0, w - x, h, cast(ubyte) 255);
        const bx = left ? x : 0, bw = left ? w - x : x;
        const by = top ? 0 : y, bh = top ? y : h - y;
        if (bw > 0 && bh > 0)
            emit(bx, by, bw, bh, cast(ubyte) 255);
        return true;
    }
    if (cp == 0x1fb80 || cp == 0x1fb81)
    {
        grid(cp == 0x1fb80 ? 0x81 : 0x95, 1, 8, w, h, emit);
        return true;
    }
    if (cp >= 0x1fb82 && cp <= 0x1fb8b)
    {
        enum ubyte[5] eighths = [2, 3, 5, 6, 7];
        const n = eighths[(cp - 0x1fb82) % 5];
        const vertical = cp >= 0x1fb87;
        const mask = vertical ? 0xffu << (8 - n) : (1u << n) - 1;
        grid(mask, vertical ? 8 : 1, vertical ? 1 : 8, w, h, emit);
        return true;
    }
    if (cp >= 0x1fba0 && cp <= 0x1fbae)
    {
        enum ubyte[15] masks = [1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15];
        const mask = masks[cp - 0x1fba0];
        // Union all strokes before emitting runs: intersections blend only once.
        const thickness = max(1.0, min(w, h) / 8.0);
        foreach (y; 0 .. h)
        {
            const upper = (y + 0.5) < h / 2.0;
            const dy = fabs((y + 0.5) / h - 0.5) * w;
            int start = -1;
            foreach (x; 0 .. w + 1)
            {
                const covered = x < w &&
                    (((mask & (upper ? 1 : 4)) && fabs(x + 0.5 - dy) < thickness / 2) ||
                        ((mask & (upper ? 2 : 8)) && fabs(x + 0.5 - (w - dy)) < thickness / 2));
                if (covered && start < 0)
                    start = x;
                else if (!covered && start >= 0)
                {
                    emit(start, y, x - start, 1, cast(ubyte) 255);
                    start = -1;
                }
            }
        }
        return true;
    }
    if (cp >= 0x1fbf0 && cp <= 0x1fbf9)
    {
        // Seven-segment digits: top, upper-right, lower-right, bottom,
        // lower-left, upper-left, middle (Unicode segmented digits).
        enum ubyte[10] masks = [0x3f, 0x06, 0x5b, 0x4f, 0x66, 0x6d, 0x7d, 0x07, 0x7f, 0x6f];
        const mask = masks[cp - 0x1fbf0];
        const thickness = max(1, min(w / 6, h / 10));
        const left = w / 8, right = w - w / 8;
        const top = h / 10, bottom = h - h / 10;
        const middle = (h - thickness) / 2;
        BoxRects segments;
        if (mask & 1) segments.add(left, top, right, min(bottom, top + thickness));
        if (mask & 2) segments.add(max(left, right - thickness), top, right, middle);
        if (mask & 4) segments.add(max(left, right - thickness), middle, right, bottom);
        if (mask & 8) segments.add(left, max(top, bottom - thickness), right, bottom);
        if (mask & 16) segments.add(left, middle, min(right, left + thickness), bottom);
        if (mask & 32) segments.add(left, top, min(right, left + thickness), middle);
        if (mask & 64) segments.add(left, middle, right, min(bottom, middle + thickness));
        rectUnion(segments, emit);
        return true;
    }
    return false;
}

version (unittest)
{
    private struct Raster
    {
        enum stride = 31;
        ubyte[stride * stride] pixels;
        int width, height;

        void put(int x, int y, int w, int h, ubyte coverage) @safe pure nothrow @nogc
        {
            assert(w > 0 && h > 0);
            assert(x >= 0 && y >= 0 && x + w <= width && y + h <= height);
            foreach (row; y .. y + h)
                foreach (col; x .. x + w)
                {
                    assert(pixels[row * stride + col] == 0, "overlapping geometry");
                    pixels[row * stride + col] = coverage;
                }
        }

        bool draw(uint cp) @safe pure nothrow @nogc
            => visitCellGraphics(cp, width, height, &put);

        ubyte at(int x, int y) const @safe pure nothrow @nogc
            => pixels[y * stride + x];
    }
}

@("terminal_view.cell_graphics.partitioned blitters cover odd cells without gaps or overlap")
@safe pure nothrow @nogc unittest
{
    // Separate mask oracles exercise every sextant, not merely the mapping's
    // endpoints. Skipped left/right halves live in the original block range.
    uint cp = 0x1fb00;
    foreach (mask; 1u .. 63u)
    {
        const glyph = mask == 21 ? 0x258c : mask == 42 ? 0x2590 : cp++;
        Raster r;
        r.width = 13;
        r.height = 17;
        assert(r.draw(glyph));
        foreach (y; 0 .. r.height)
            foreach (x; 0 .. r.width)
            {
                const col = x < 6 ? 0 : 1;
                const row = y < 5 ? 0 : y < 11 ? 1 : 2;
                assert((r.at(x, y) != 0) == ((mask & (1u << (row * 2 + col))) != 0));
            }
    }
    foreach (width; 1 .. 16)
        foreach (height; 1 .. 20)
        {
            Raster r;
            r.width = width;
            r.height = height;
            assert(r.draw(0x2580));
            assert(r.draw(0x2584));
            foreach (y; 0 .. height)
                foreach (x; 0 .. width)
                    assert(r.at(x, y) == 255);
        }
}

@("terminal_view.cell_graphics.braille dot numbers and blank are font independent")
@safe pure nothrow @nogc unittest
{
    enum int[8] columns = [0, 0, 0, 1, 1, 1, 0, 1];
    enum int[8] rows = [0, 1, 2, 0, 1, 2, 3, 3];
    foreach (bit; 0 .. 8)
    {
        Raster r;
        r.width = 12;
        r.height = 24;
        assert(r.draw(0x2800 | (1u << bit)));
        foreach (y; 0 .. 24)
            foreach (x; 0 .. 12)
            {
                const dx = x - columns[bit] * 6, dy = y - rows[bit] * 6;
                assert((r.at(x, y) != 0) == (dx >= 1 && dx < 5 && dy >= 1 && dy < 5));
            }
    }
    Raster blank;
    blank.width = 13;
    blank.height = 17;
    assert(blank.draw(0x2800));
    foreach (pixel; blank.pixels)
        assert(pixel == 0);
    assert(!blank.draw('A'));
    assert(!blank.draw(0x1fb93)); // Unassigned; do not swallow arbitrary glyphs.
}

@("terminal_view.cell_graphics.octant masks preserve Unicode gaps")
@safe pure nothrow @nogc unittest
{
    assert(octantMasks[0] == 4);
    assert(octantMasks[0xe5] == 254);
    foreach (i, mask; octantMasks)
    {
        Raster r;
        r.width = 13;
        r.height = 19;
        assert(r.draw(cast(uint)(0x1cd00 + i)));
        foreach (y; 0 .. 19)
            foreach (x; 0 .. 13)
            {
                const col = x < 6 ? 0 : 1;
                const row = y < 4 ? 0 : y < 9 ? 1 : y < 14 ? 2 : 3;
                assert((r.at(x, y) != 0) == ((mask & (1u << (row * 2 + col))) != 0));
            }
    }
}

@("terminal_view.cell_graphics.legacy shapes stay inside their cells")
@safe pure nothrow @nogc unittest
{
    foreach (width; [1, 7, 13])
        foreach (height; [1, 11, 19])
            foreach (cp; 0x1fb3cu .. 0x1fb8cu)
            {
                Raster r;
                r.width = width;
                r.height = height;
                assert(r.draw(cp)); // Raster.put asserts bounds and single coverage.
            }
    // A 1FB3C triangle occupies the lower left third, with vertices
    // (0, 12), (0, 18), (6, 18) in this cell.
    Raster triangle;
    triangle.width = 12;
    triangle.height = 18;
    assert(triangle.draw(0x1fb3c));
    foreach (y; 0 .. 18)
        foreach (x; 0 .. 12)
            assert((triangle.at(x, y) != 0) == (y >= 12 && x < y - 12));
    foreach (edgeIndex; 0u .. 4u)
    {
        Raster r;
        r.width = 13;
        r.height = 19;
        assert(r.draw(0x1fb68 + edgeIndex));
        assert(r.draw(0x1fb6c + edgeIndex));
        foreach (y; 0 .. 19)
            foreach (x; 0 .. 13)
                assert(r.at(x, y) == 255);
    }
}

@("terminal_view.cell_graphics.box rails turn without closing their channels")
@safe pure nothrow @nogc unittest
{
    Raster corner;
    corner.width = 13;
    corner.height = 19;
    assert(corner.draw(0x2554)); // Double down-and-right corner.
    foreach (y; 0 .. 19)
        foreach (x; 0 .. 13)
        {
            const outer = (x == 5 && y >= 8) || (y == 8 && x >= 5);
            const inner = (x == 7 && y >= 10) || (y == 10 && x >= 7);
            assert((corner.at(x, y) != 0) == (outer || inner));
        }
    Raster mixed;
    mixed.width = 13;
    mixed.height = 19;
    assert(mixed.draw(0x2543)); // Heavy up/left, light right/down.
    assert(mixed.at(5, 0) && mixed.at(6, 0) && !mixed.at(7, 0));
    assert(mixed.at(0, 8) && mixed.at(0, 9) && !mixed.at(0, 10));
    assert(mixed.at(12, 9) && !mixed.at(12, 8));
    assert(mixed.at(6, 18) && !mixed.at(5, 18));
}

@("terminal_view.cell_graphics.rounded dashed and diagonal boxes retain their shapes")
@safe pure nothrow @nogc unittest
{
    Raster round;
    round.width = 15;
    round.height = 21;
    assert(round.draw(0x256d));
    assert(round.at(7, 20) && round.at(14, 10));
    assert(!round.at(7, 10)); // A rounded corner is not a square elbow.
    Raster dashed;
    dashed.width = 15;
    dashed.height = 21;
    assert(dashed.draw(0x2504));
    foreach (x; 0 .. 15)
        assert((dashed.at(x, 10) != 0) == (x < 3 || (x >= 6 && x < 9) || x >= 12));
    Raster diagonal;
    diagonal.width = 15;
    diagonal.height = 15;
    assert(diagonal.draw(0x2573));
    foreach (i; 0 .. 15)
    {
        assert(diagonal.at(i, i));
        assert(diagonal.at(14 - i, i));
    }
    foreach (width; [1, 7, 13])
        foreach (height; [1, 11, 19])
            foreach (cp; 0x2500u .. 0x2580u)
            {
                Raster r;
                r.width = width;
                r.height = height;
                assert(r.draw(cp));
            }
}

@("terminal_view.cell_graphics.eighth strips share exact odd-sized endpoints")
@safe pure nothrow @nogc unittest
{
    foreach (vertical; [false, true])
    {
        Raster r;
        r.width = 13;
        r.height = 19;
        assert(r.draw(vertical ? 0x258f : 0x2594));
        foreach (i; 0u .. 6u)
            assert(r.draw((vertical ? 0x1fb70 : 0x1fb76) + i));
        assert(r.draw(vertical ? 0x2595 : 0x2581));
        foreach (y; 0 .. 19)
            foreach (x; 0 .. 13)
                assert(r.at(x, y) == 255);
    }
    Raster quadrants;
    quadrants.width = 13;
    quadrants.height = 19;
    assert(quadrants.draw(0x259a)); // Upper left + lower right.
    foreach (y; 0 .. 19)
        foreach (x; 0 .. 13)
            assert((quadrants.at(x, y) != 0) == ((x < 6) == (y < 9)));
}
