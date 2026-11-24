/**
A widget tree as the lines of an inline terminal block: what a live region
(`sparkles.ui.components.live`) repaints beneath a scrolling transcript.

The tree is laid out at a width, its display list painted by the terminal's
own canvas ($(REF paintGrid, sparkles,ui_tui,grid_canvas)), and each row of
the grid serialized as styled text, its trailing blanks dropped — the same
cells a full-screen frame would hold, without cursor addressing.

$(B The colours are the terminal's.) An inline block sits among the user's
own lines, on a background nobody asked the terminal about. So the
$(LREF terminalPalette) resolves each slot to a token that stands for one of
the 16 colours the terminal's theme defines, and the page colours to tokens
for its default foreground and background; serializing turns the tokens back
into those colours. A run therefore reads the same on a light terminal and a
dark one, as `ls --color` does.
*/
module sparkles.ui_tui.inline_frame;

import sparkles.base.term_color : Color, ColorDepth, RgbColor;
import sparkles.ui.style : Palette, Slot;
import sparkles.ui.widget : WidgetTree;
import sparkles.ui.tokens : TargetCapabilities;
import sparkles.ui_tui.grid_canvas : gridCapabilities;

@safe:

/**
The slots an inline block colours, each as a token for one of the terminal's
16 colours: errors red, success green, warnings and the primary accent
yellow, information and links blue, the secondary accent cyan, and every
muted role (gutter, borders, secondary and disabled text) bright black.
Other slots keep the default foreground.
*/
Palette terminalPalette() pure nothrow @nogc
{
    Palette p;
    void set(Slot s, ubyte ansi) { p.fg[s] = Color.fromRgb(token(ansi)); }
    set(Slot.error, 1);
    set(Slot.success, 2);
    set(Slot.warn, 3);
    set(Slot.accentPrimary, 3);
    set(Slot.info, 4);
    set(Slot.link, 4);
    set(Slot.accentSecondary, 6);
    foreach (s; [Slot.muted, Slot.gutter, Slot.border, Slot.textSecondary, Slot.textDisabled, Slot.docs])
        set(s, 8);
    return p;
}

/**
`tree` laid out `width` columns wide and painted for a terminal of `caps` —
its glyph tier and block elements (`GLY1`, `GLY8`) — one string per row, in its
16 colours at most (no escape at all at `ColorDepth.none`), each ending in a
reset, trailing blanks dropped.
*/
string[] inlineFrame(in WidgetTree tree, int width, in TargetCapabilities caps = gridCapabilities)
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.tui.cell : CellStyle, Grid, writeStyle;
    import sparkles.tui.render : serializeRow;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui_tui.grid_canvas : paintGrid;

    if (width <= 0)
        return null;
    auto frames = layout(tree, Constraints(maxW: width));
    const height = frames[tree.root].rect.height;
    if (height <= 0)
        return null;
    const ops = buildDisplayList(tree, frames, terminalPalette(), pageFg, pageBg);
    Grid grid;
    grid.resize(cast(ushort) width, cast(ushort) height);
    paintGrid(grid, pageBg, ops, caps: caps);

    const emit = caps.colorDepth > ColorDepth.ansi16 ? ColorDepth.ansi16 : caps.colorDepth;
    string[] lines;
    foreach (ushort y; 0 .. grid.rows)
    {
        auto row = grid.row(y);
        foreach (ref cell; row)
        {
            cell.style.fg = fromToken(cell.style.fg);
            cell.style.bg = fromToken(cell.style.bg);
            cell.style.underlineColor = fromToken(cell.style.underlineColor);
        }
        size_t end = row.length;
        while (end > 0 && isBlank(row[end - 1]))
            --end;
        SharedBuffer!(char, 512) buf;
        if (emit == ColorDepth.none)
        {
            // No colour: the text alone, without even a reset.
            foreach (ref cell; row[0 .. end])
                if (cell.width != 0)
                    buf ~= cell.grapheme;
        }
        else
        {
            serializeRow(buf, row[0 .. end], emit);
            writeStyle(buf, CellStyle.init, emit);
        }
        lines ~= buf[].idup;
    }
    return lines;
}

private:

// The page colours, and the tokens for the 16 colours: values no theme
// paints, decoded after the grid is painted.
enum RgbColor pageFg = RgbColor(1, 1, 0);
enum RgbColor pageBg = RgbColor(1, 1, 1);

RgbColor token(ubyte ansi) pure nothrow @nogc => RgbColor(1, 0, ansi);

Color fromToken(Color c) pure nothrow @nogc
{
    if (c.kind != Color.Kind.rgb)
        return c;
    if (c.rgb == pageFg || c.rgb == pageBg)
        return Color.defaultColor;
    if (c.rgb.r == 1 && c.rgb.g == 0 && c.rgb.b < 16)
        return Color.fromPalette(c.rgb.b);
    return c;
}

bool isBlank(C)(ref const C cell)
{
    return cell.grapheme == " " && (cell.style.bg.kind == Color.Kind.unset
        || cell.style.bg.kind == Color.Kind.default_);
}

version (unittest)
{
    import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;

    WidgetTree sample()
    {
        Builder b;
        const a = b.add(Widget(kind: WidgetKind.rich,
            spans: [TextSpan("✖ ", Slot.error), TextSpan("compile", Slot.inherit)]));
        const c = b.add(Widget(kind: WidgetKind.text, text: "3 running", slot: Slot.muted));
        return b.finish(b.container(WidgetKind.column, [a, c]));
    }
}

/// Without colour a frame is its text, one line per row, blanks trimmed.
@("ui_tui.inline_frame.inlineFrame.plainText")
@system unittest
{
    auto plain = gridCapabilities;
    plain.output.colorDepth = ColorDepth.none;
    const lines = inlineFrame(sample(), 20, plain);
    assert(lines == ["✖ compile", "3 running"], lines[0]);
}

/// Slots come out as the terminal's own colours, the rest in its default.
@("ui_tui.inline_frame.inlineFrame.terminalColours")
@system unittest
{
    import std.algorithm.searching : canFind;

    const lines = inlineFrame(sample(), 20);
    assert(lines[0].canFind("\x1b[") && !lines[0].canFind("38;2"), "no 24-bit colour");
    assert(lines[0].canFind("31m✖"), "an error is the terminal's red");
    assert(lines[1].canFind("90m3 running"), "muted text is bright black");
}
