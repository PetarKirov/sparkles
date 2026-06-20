#!/usr/bin/env dub
/+ dub.sdl:
name "text-cell-svg"
dependency "sparkles:base" path="../../.."
targetPath "build"
+/
// ci: build-only

// Generates an SVG "cell grid" diagram for the sparkles.base.text spec
// (docs/specs/base/text/). Each grapheme cluster is drawn as a box spanning the
// terminal cells it occupies (wide clusters span two), with its glyph and code
// points labelled. The cell layout comes from the real `byGraphemeCluster`
// segmentation, so the figure cannot drift from the algorithm. A pre-commit hook
// regenerates docs/public/text-cells.svg from this program.
//
//   dub run --single text-cell-svg.d                 # SVG to stdout
//   dub run --single text-cell-svg.d -- --out a.svg  # SVG to a file

module text_cell_svg_example;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.stdio : File, stdout, writeln;
import std.utf : byDchar;

import sparkles.base.text.grapheme : byGraphemeCluster;

/// The string the diagram visualizes: ASCII, a combining mark, CJK, a flag, a
/// Devanagari syllable, and an emoji + VS16 — one of each width/cluster shape.
enum demo = "aÁ世\U0001F1FA\U0001F1F8कि❤️";

// Layout constants (px).
enum cw = 64, ch = 56, padX = 16, rulerH = 22, labelH = 22, cpH = 20, cpLineH = 13;

void main(string[] args)
{
    string outPath;
    for (size_t i = 1; i < args.length; ++i)
        if (args[i] == "--out" && i + 1 < args.length)
            outPath = args[++i];

    const svg = renderSvg(demo);
    if (outPath.length)
        File(outPath, "w").write(svg);
    else
        stdout.rawWrite(svg);
}

/// One laid-out cluster.
private struct Cell
{
    string glyph;  // XML-escaped glyph
    string[] cps;  // one "U+XXXX" per code point (stacked vertically)
    size_t start;  // first terminal cell
    int width;     // 1 or 2
}

string renderSvg(string text)
{
    Cell[] cells;
    size_t col;
    size_t maxCps = 1;
    foreach (u; text.byGraphemeCluster)
    {
        if (u.isEscape)
            continue;
        string[] cps;
        foreach (cp; u.slice.byDchar)
            cps ~= format("U+%04X", cast(uint) cp);
        if (cps.length > maxCps)
            maxCps = cps.length;
        cells ~= Cell(xmlEscape(u.slice.idup), cps, col, u.width);
        col += u.width;
    }
    const totalCells = col;

    const gridTop = rulerH;
    const gridBot = gridTop + ch;
    const w = padX * 2 + cast(int) totalCells * cw;
    const h = gridBot + labelH + cpH + cast(int)(maxCps - 1) * cpLineH + 8;

    auto s = appender!string;
    s ~= format(
        `<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="0 0 %s %s"` ~
        ` font-family="ui-monospace, monospace" text-anchor="middle">` ~ "\n",
        w, h, w, h);
    s ~= `  <rect width="100%" height="100%" fill="#ffffff"/>` ~ "\n";

    // Cell-boundary gridlines and the column-index ruler (0..totalCells).
    foreach (c; 0 .. totalCells + 1)
    {
        const x = padX + cast(int) c * cw;
        s ~= format(`  <line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#d0d7de"/>` ~ "\n",
            x, gridTop, x, gridBot);
        if (c < totalCells)
            s ~= format(`  <text x="%s" y="%s" font-size="11" fill="#57606a">%s</text>` ~ "\n",
                x + cw / 2, rulerH - 7, c);
    }

    // Each cluster: a box over its cells, the glyph, its width, and its code points.
    foreach (cell; cells)
    {
        const x = padX + cast(int) cell.start * cw;
        const bw = cell.width * cw;
        const fill = cell.width == 2 ? "#ddf4ff" : "#f6f8fa";
        s ~= format(`  <rect x="%s" y="%s" width="%s" height="%s" fill="%s" stroke="#57606a"/>` ~ "\n",
            x, gridTop, bw, ch, fill);
        s ~= format(`  <text x="%s" y="%s" font-size="26">%s</text>` ~ "\n",
            x + bw / 2, gridTop + 36, cell.glyph);
        s ~= format(`  <text x="%s" y="%s" font-size="16" fill="#57606a">w=%s</text>` ~ "\n",
            x + bw / 2, gridBot + 15, cell.width);
        foreach (j, cp; cell.cps)
            s ~= format(`  <text x="%s" y="%s" font-size="12" fill="#0969da">%s</text>` ~ "\n",
                x + bw / 2, gridBot + labelH + 14 + cast(int) j * cpLineH, cp);
    }

    s ~= "</svg>\n";
    return s[];
}

/// Escape the five XML predefined entities so any glyph is safe in SVG text.
private string xmlEscape(string s)
{
    auto a = appender!string;
    foreach (char c; s)
        switch (c)
        {
        case '&': a ~= "&amp;"; break;
        case '<': a ~= "&lt;"; break;
        case '>': a ~= "&gt;"; break;
        case '"': a ~= "&quot;"; break;
        case '\'': a ~= "&#39;"; break;
        default: a ~= c; break;
        }
    return a[];
}
