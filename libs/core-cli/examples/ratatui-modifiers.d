#!/usr/bin/env dub
/+ dub.sdl:
    name "ratatui-modifiers"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

module ratatui_modifiers_example;

// A port of ratatui's `modifiers` example (examples/modifiers.rs) to
// sparkles:core-cli.
//
// Renders every combination of five foreground and five background colors with
// each text attribute applied, so you can see how your terminal handles each
// one. Attributes come from sparkles' `TextAttr` set plus `UnderlineStyle`;
// sparkles has no blink attribute, so ratatui's SlowBlink/RapidBlink are
// omitted (noted below).
//
// Lines are assembled in a reused `SmallBuffer` (via `alignField` rather than
// GC `format`), so no per-cell strings are allocated.
//
//   dub run --single ratatui-modifiers.d

import std.stdio : writeln;
import std.traits : EnumMembers;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : Color, ColorDepth;
import sparkles.base.term_style : TermStyle, TextAttr, UnderlineStyle, writeStyleTransition;
import sparkles.base.text.width : Align, alignField;
import sparkles.core_cli.term_caps : detectTermCaps;
import sparkles.core_cli.ui.header : drawHeader;

/// One assembled output line; inline, so reuse across rows never allocates.
alias Line = SmallBuffer!(char, 2048);

/// The text attributes this demo cycles through, in ratatui's order (minus the
/// two blink modes, which sparkles' `TextAttr` doesn't model).
enum Modifier { none, bold, dim, italic, underline, reversed, hidden, strike }

immutable string[8] modNames =
    ["Default", "Bold", "Dim", "Italic", "Underline", "Reverse", "Hidden", "Strike"];

/// (name, palette index) — the five colors used for both axes, matching
/// ratatui's Black / DarkGray / Gray / White / Red.
struct Swatch { string name; ubyte idx; }
immutable Swatch[5] palette = [
    Swatch("Black", 0), Swatch("DarkGray", 8), Swatch("Gray", 7),
    Swatch("White", 15), Swatch("Red", 1),
];

void main()
{
    const caps = detectTermCaps();
    const depth = caps.colorDepth;

    writeln("ratatui `modifiers` demo — every attribute across a 5×5 "
        ~ "foreground/background grid");

    Line line;
    line.clear();
    styledField(line, TermStyle(fg: Color.fromPalette(1), attrs: TextAttr.bold),
        "Note: not all terminals support every attribute (and none support blink here).",
        0, Align.left, depth);
    writeln(line[]);
    writeln();

    foreach (bg; palette)
    {
        writeln(("on " ~ bg.name ~ " background").drawHeader);
        foreach (fg; palette)
        {
            line.clear();
            alignField(line, fg.name, 9, Align.left);
            foreach (m; [EnumMembers!Modifier])
            {
                const style = styleFor(m, Color.fromPalette(fg.idx), Color.fromPalette(bg.idx));
                styledField(line, style, modNames[m], 9, Align.left, depth);
                line ~= ' ';
            }
            writeln(line[]);
        }
        writeln();
    }
}

/// A `TermStyle` with `fg`/`bg` plus the one attribute selected by `m`.
TermStyle styleFor(Modifier m, Color fg, Color bg)
{
    auto s = TermStyle(fg: fg, bg: bg);
    final switch (m)
    {
        case Modifier.none:      break;
        case Modifier.bold:      s.attrs = TextAttr.bold; break;
        case Modifier.dim:       s.attrs = TextAttr.dim; break;
        case Modifier.italic:    s.attrs = TextAttr.italic; break;
        case Modifier.underline: s.underline = UnderlineStyle.single; break;
        case Modifier.reversed:  s.attrs = TextAttr.inverse; break;
        case Modifier.hidden:    s.attrs = TextAttr.hidden; break;
        case Modifier.strike:    s.attrs = TextAttr.strikethrough; break;
    }
    return s;
}

/// Append `content` padded to `width` (0 = no padding) into `line`, wrapped in
/// `style`'s SGR when `depth` allows. No allocation — written straight into
/// `line`.
void styledField(ref Line line, in TermStyle style, scope const(char)[] content,
    size_t width, Align align_, ColorDepth depth)
{
    const w = width == 0 ? content.length : width;
    if (depth != ColorDepth.none)
        writeStyleTransition(line, TermStyle.init, style, depth);
    alignField(line, content, w, align_);
    if (depth != ColorDepth.none)
        writeStyleTransition(line, style, TermStyle.init, depth);
}
