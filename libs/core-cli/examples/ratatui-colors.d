#!/usr/bin/env dub
/+ dub.sdl:
    name "ratatui-colors"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

module ratatui_colors_example;

// A port of ratatui's `colors` example (examples/colors.rs) to sparkles:core-cli.
//
// Shows the 16 named terminal colors (as foregrounds, and legibility-tested
// across five backgrounds) and the full 256-color indexed palette, every swatch
// labelled with its index. Each cell is built with `TermStyle` +
// `writeStyleTransition`, passing the terminal's detected `ColorDepth`, so the
// colors fold automatically: 24-bit → 256 → nearest classic-16 → uncolored.
//
// Lines are assembled in a reused `@nogc` `SmallBuffer` (via `alignField` /
// `writeInteger` rather than GC `format`), so no per-cell strings are allocated.
//
//   dub run --single ratatui-colors.d

import std.stdio : writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : Color, ColorDepth, RgbColor;
import sparkles.base.term_style : TermStyle, writeStyleTransition;
import sparkles.base.text.width : Align, alignField;
import sparkles.base.text.writers : writeInteger;
import sparkles.core_cli.term_caps : detectTermCaps;
import sparkles.core_cli.ui.header : drawHeader;

/// One assembled output line; ample and inline, so `clear()` (and reuse across
/// rows) never touches the heap.
alias Line = SmallBuffer!(char, 4096);

void main()
{
    const caps = detectTermCaps();
    const depth = caps.colorDepth;

    writeln("ratatui `colors` demo — the 16 named colors and the 256-color "
        ~ "indexed palette\n");
    if (depth == ColorDepth.none)
        writeln("(color output is off — swatches render as plain labels)\n");

    renderNamed(depth);
    writeln();
    renderIndexed(depth);
}

/// The 16 ANSI-named colors, in palette-index order (matching ratatui's
/// `Color::Black`…`Color::White`).
immutable string[16] namedColors = [
    "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "Gray",
    "DarkGray", "LightRed", "LightGreen", "LightYellow", "LightBlue",
    "LightMagenta", "LightCyan", "White",
];

void renderNamed(ColorDepth depth)
{
    writeln("The 16 named colors".drawHeader);
    Line line;
    SmallBuffer!(char, 8) num;
    foreach (i; 0 .. 16)
    {
        const idx = cast(ubyte) i;
        const swatch = TermStyle(fg: labelColor(idx), bg: Color.fromPalette(idx));
        const asFg = TermStyle(fg: Color.fromPalette(idx));
        line.clear();
        num.clear();
        writeInteger(num, i);
        alignField(line, num[], 2, Align.right);
        line ~= "  ";
        styledField(line, swatch, namedColors[i], 15, Align.center, depth);
        line ~= "  ";
        styledField(line, asFg, namedColors[i], namedColors[i].length, Align.left, depth);
        writeln(line[]);
    }

    // ratatui's point: a foreground has to stay legible on different
    // backgrounds. Each row is a color; each column renders that color's *name*
    // as text (so you can actually read it — or not) on one of five backgrounds.
    writeln();
    writeln("Legibility — each name shown in its own color on five backgrounds:");
    static immutable int[] backgrounds = [-1, 0, 8, 7, 15]; // -1 = terminal default
    line.clear();
    alignField(line, "", 13, Align.left);
    foreach (bg; backgrounds)
        alignField(line, bg < 0 ? "Default" : namedColors[bg], 13, Align.left);
    writeln(line[]);
    foreach (i; 0 .. 16)
    {
        const fg = Color.fromPalette(cast(ubyte) i);
        line.clear();
        alignField(line, namedColors[i], 13, Align.left);
        foreach (bg; backgrounds)
        {
            auto style = TermStyle(fg: fg);
            if (bg >= 0)
                style.bg = Color.fromPalette(cast(ubyte) bg);
            styledField(line, style, namedColors[i], 12, Align.left, depth);
            line ~= ' ';
        }
        writeln(line[]);
    }
}

void renderIndexed(ColorDepth depth)
{
    writeln(("Indexed palette 0–255  "
        ~ "(0–15 system · 16–231 the 6×6×6 cube · 232–255 grayscale)").drawHeader);
    // A 16×16 grid: every index sits on its own swatch, labelled in a contrasting
    // color so even the darkest and lightest entries stay readable.
    Line line;
    SmallBuffer!(char, 8) num;
    foreach (row; 0 .. 16)
    {
        line.clear();
        foreach (col; 0 .. 16)
        {
            const i = cast(ubyte)(row * 16 + col);
            const cell = TermStyle(fg: labelColor(i), bg: Color.fromPalette(i));
            num.clear();
            writeInteger(num, i);
            styledField(line, cell, num[], 5, Align.center, depth);
        }
        writeln(line[]);
    }
}

/// Append `content` padded to `width` (per `align_`) into `line`, wrapped in
/// `style`'s SGR when `depth` allows — so the padding carries the background
/// too. No allocation: the padded text is written straight into `line`.
void styledField(ref Line line, in TermStyle style, scope const(char)[] content,
    size_t width, Align align_, ColorDepth depth)
{
    if (depth != ColorDepth.none)
        writeStyleTransition(line, TermStyle.init, style, depth);
    alignField(line, content, width, align_);
    if (depth != ColorDepth.none)
        writeStyleTransition(line, style, TermStyle.init, depth);
}

/// Black or white, whichever reads better on palette index `i` — chosen from the
/// xterm default RGB behind that index (the swatch itself still uses the
/// terminal's own palette via `Color.fromPalette`).
Color labelColor(ubyte i)
{
    const c = paletteRgb(i);
    const luma = (299 * c.r + 587 * c.g + 114 * c.b) / 1000;
    return luma > 140 ? Color.fromRgb(0, 0, 0) : Color.fromRgb(255, 255, 255);
}

/// The xterm default RGB for a palette index: the 16 base colors, the 6×6×6
/// color cube (16–231), then the 24-step grayscale ramp (232–255).
RgbColor paletteRgb(ubyte i)
{
    static immutable ubyte[3][16] base = [
        [0, 0, 0], [128, 0, 0], [0, 128, 0], [128, 128, 0],
        [0, 0, 128], [128, 0, 128], [0, 128, 128], [192, 192, 192],
        [128, 128, 128], [255, 0, 0], [0, 255, 0], [255, 255, 0],
        [0, 0, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255],
    ];
    if (i < 16)
        return RgbColor(base[i][0], base[i][1], base[i][2]);
    if (i < 232)
    {
        const c = i - 16;
        ubyte level(int x) => cast(ubyte)(x == 0 ? 0 : 55 + 40 * x);
        return RgbColor(level(c / 36), level((c / 6) % 6), level(c % 6));
    }
    const v = cast(ubyte)(8 + 10 * (i - 232));
    return RgbColor(v, v, v);
}
