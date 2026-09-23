/++
Theme layer: one border-charset selector shared by every framed component
(`drawBox` / `drawHeader` / `drawTable`), the status-glyph vocabulary with ASCII
fallbacks, semantic styles, and a $(LREF Theme) snapshot derived from
$(REF TermCaps, sparkles,core_cli,term_caps).

Components stay pure producers — the theme only *selects* glyphs/styles once at
the edge (typically `makeTheme(detectTermCaps())` at app startup); callers thread
the resulting values through the existing `BoxProps`/`TableProps`/`colored`
parameters.
+/
module sparkles.ui.components.theme;

import sparkles.ui.glyphs : Mark, markTable;
import sparkles.base.term_style : Style, stylize;
import sparkles.base.term_caps : OutputCapabilities;
import sparkles.ui.components.box : BoxProps;
import sparkles.ui.components.table : presetGlyphs, TableGlyphs;

@safe:

/// A border charset, selectable consistently across box, header, and table.
/// `ascii` is the degradation target for non-UTF-8 terminals.
enum BorderStyle { rounded, square, ascii, double_, heavy }

/// The preset name for `style` — the key `drawTable`'s `presetGlyphs` /
/// `stylePresets` registry uses.
string borderPresetName(BorderStyle style) pure nothrow @nogc
{
    final switch (style)
    {
        case BorderStyle.rounded: return "rounded";
        case BorderStyle.square:  return "square";
        case BorderStyle.ascii:   return "ascii";
        case BorderStyle.double_: return "double";
        case BorderStyle.heavy:   return "heavy";
    }
}

/// `TableGlyphs` for `style` — the table's own presets, via the shared selector.
TableGlyphs tableGlyphs(BorderStyle style) pure nothrow
    => presetGlyphs(borderPresetName(style));

/// `BoxProps` with the frame charset for `style`; every other field keeps its
/// default (combine with named arguments: `boxGlyphs(s).withFields` is just
/// `BoxProps(footer: …, …, topLeft: boxGlyphs(s).topLeft, …)` — or start from
/// this and assign).
BoxProps boxGlyphs(BorderStyle style) pure nothrow @nogc
{
    final switch (style)
    {
        case BorderStyle.rounded:
            return BoxProps.init;
        case BorderStyle.square:
            return BoxProps(
                topLeft: '┌', topRight: '┐', bottomLeft: '└', bottomRight: '┘');
        case BorderStyle.ascii:
            return BoxProps(
                topLeft: '+', topRight: '+', bottomLeft: '+', bottomRight: '+',
                horizontalLine: '-', verticalLine: '|',
                titlePrefix: '[', titleSuffix: ']',
                titleConnectLeft: '+', titleConnectRight: '+');
        case BorderStyle.double_:
            return BoxProps(
                topLeft: '╔', topRight: '╗', bottomLeft: '╚', bottomRight: '╝',
                horizontalLine: '═', verticalLine: '║',
                titlePrefix: '╡', titleSuffix: '╞',
                titleConnectLeft: '╣', titleConnectRight: '╠');
        case BorderStyle.heavy:
            return BoxProps(
                topLeft: '┏', topRight: '┓', bottomLeft: '┗', bottomRight: '┛',
                horizontalLine: '━', verticalLine: '┃',
                titlePrefix: '┫', titleSuffix: '┣',
                titleConnectLeft: '┫', titleConnectRight: '┣');
    }
}

/// `drawHeader` divider line char for `style`.
dchar headerLineChar(BorderStyle style) pure nothrow @nogc
{
    final switch (style)
    {
        case BorderStyle.rounded:
        case BorderStyle.square:  return '─';
        case BorderStyle.ascii:   return '-';
        case BorderStyle.double_: return '═';
        case BorderStyle.heavy:   return '━';
    }
}

/// `drawHeader` banner line char for `style`.
dchar bannerLineChar(BorderStyle style) pure nothrow @nogc
    => style == BorderStyle.ascii ? '=' : '═';

/// The status-glyph vocabulary shared by checklists, result lines, and summaries.
/// Defaults are the Unicode set; `statusGlyphs(unicode: false)` selects the ASCII
/// fallbacks. The marks are the design system's (`sparkles.ui.glyphs.Mark`,
/// `GLY3`), read from its table rather than spelled a second time here.
struct StatusGlyphs
{
    string ok       = markText(Mark.ok, true);
    string fail     = markText(Mark.fail, true);
    string warn     = markText(Mark.warn, true);
    string info     = markText(Mark.info, true);
    string pending  = markText(Mark.pending, true);
    string running  = markText(Mark.running, true); /// Static form; animated contexts use `spinnerFrame`.
    string skipped  = markText(Mark.skipped, true);
    string ellipsis = "…";
}

// One mark as text, in its Unicode or ASCII form — evaluated at compile time
// for the initializers above and the ASCII set below.
//
// Built by concatenation onto a literal rather than `std.conv.to`: the
// compiler keeps such a CTFE `string` as a literal, whereas `to!string`'s
// buffer surfaces as an array literal that `@nogc` `statusGlyphs` would have
// to allocate.
private string markText(Mark m, bool unicode) pure nothrow
{
    import sparkles.base.text.utf : encodeUtf8;

    char[4] buf;
    const n = encodeUtf8(unicode ? markTable[m].unicode : markTable[m].ascii, buf);
    string s = "";
    foreach (c; buf[0 .. n])
        s ~= c;
    return s;
}

private static immutable StatusGlyphs asciiStatusGlyphs = StatusGlyphs(
    ok: markText(Mark.ok, false), fail: markText(Mark.fail, false),
    warn: markText(Mark.warn, false), info: markText(Mark.info, false),
    pending: markText(Mark.pending, false), running: markText(Mark.running, false),
    skipped: markText(Mark.skipped, false), ellipsis: "...");

/// The glyph set for a terminal's unicode capability (see `TermCaps.unicode`).
StatusGlyphs statusGlyphs(bool unicode) pure nothrow @nogc
    => unicode ? StatusGlyphs.init : asciiStatusGlyphs;

/// Semantic style roles, so call sites say what they mean and the palette can
/// change in one place.
enum Semantic { success, failure, warning, accent, muted }

/// The concrete `Style` for a semantic role.
Style semanticStyle(Semantic sem) pure nothrow @nogc
{
    final switch (sem)
    {
        case Semantic.success: return Style.green;
        case Semantic.failure: return Style.red;
        case Semantic.warning: return Style.yellow;
        case Semantic.accent:  return Style.cyan;
        case Semantic.muted:   return Style.dim;
    }
}

/// A resolved theme snapshot: the color/unicode decisions plus the selected
/// charsets. Build one with $(LREF makeTheme) and thread it (or its fields)
/// through the app.
struct Theme
{
    bool colors;
    bool unicode = true;
    BorderStyle border = BorderStyle.rounded;
    StatusGlyphs glyphs;

    /// `text` stylized for the semantic role when colors are on, verbatim
    /// otherwise.
    string paint(Semantic sem, string text) const pure nothrow
        => colors ? text.stylize(semanticStyle(sem)) : text;

    /// The status glyph for a semantic role, painted: `✔` green, `✖` red, `⚠`
    /// yellow, `•` cyan, `┄` dim (per $(LREF semanticStyle)).
    string mark(Semantic sem) const pure nothrow
    {
        final switch (sem)
        {
            case Semantic.success: return paint(sem, glyphs.ok);
            case Semantic.failure: return paint(sem, glyphs.fail);
            case Semantic.warning: return paint(sem, glyphs.warn);
            case Semantic.accent:  return paint(sem, glyphs.info);
            case Semantic.muted:   return paint(sem, glyphs.skipped);
        }
    }
}

/// The theme for a target's output affordances: ASCII borders + fallback
/// glyphs without Unicode, colors per the color tier. A `TermCaps` converts
/// implicitly (its `output` is `alias this`), so `makeTheme(detectTermCaps())`
/// reads as before; a GUI target passes its own declaration.
Theme makeTheme(in OutputCapabilities caps) pure nothrow @nogc
{
    return Theme(
        colors: caps.colors,
        unicode: caps.unicode,
        border: caps.unicode ? BorderStyle.rounded : BorderStyle.ascii,
        glyphs: statusGlyphs(caps.unicode),
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("theme.borderPresetName.matchesTableRegistry")
@safe pure nothrow
unittest
{
    import std.traits : EnumMembers;

    // Every BorderStyle resolves to a preset drawTable actually knows: an
    // unknown name would silently fall back to rounded, so pin that only
    // `rounded` maps to the default glyph set.
    foreach (style; EnumMembers!BorderStyle)
    {
        const glyphs = tableGlyphs(style);
        if (style == BorderStyle.rounded)
            assert(glyphs == TableGlyphs.init);
        else
            assert(glyphs != TableGlyphs.init);
    }
}

@("theme.boxGlyphs.asciiCharset")
@safe pure nothrow @nogc
unittest
{
    const p = boxGlyphs(BorderStyle.ascii);
    assert(p.topLeft == '+' && p.horizontalLine == '-' && p.verticalLine == '|');
    assert(p.titlePrefix == '[' && p.titleSuffix == ']');
    assert(boxGlyphs(BorderStyle.rounded) == BoxProps.init);
}

@("theme.statusGlyphs.fallback")
@safe pure nothrow @nogc
unittest
{
    assert(statusGlyphs(true).ok == "✔");
    assert(statusGlyphs(false).ok == "+");
    assert(statusGlyphs(false).ellipsis == "...");
}

@("theme.paintAndMark")
@safe pure nothrow
unittest
{
    import sparkles.base.term_style : stylize;

    const off = Theme(colors: false);
    assert(off.paint(Semantic.success, "ok") == "ok");
    assert(off.mark(Semantic.success) == "✔");

    const on = Theme(colors: true);
    assert(on.paint(Semantic.failure, "no") == "no".stylize(Style.red));
    assert(on.mark(Semantic.success) == "✔".stylize(Style.green));
}

@("theme.makeTheme.degradation")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.term_caps : OutputCapabilities, TermCaps;
    import sparkles.base.term_color : ColorDepth;

    const dumb = makeTheme(OutputCapabilities(colorDepth: ColorDepth.none, unicode: false));
    assert(dumb.border == BorderStyle.ascii);
    assert(dumb.glyphs.ok == "+");

    const nice = makeTheme(OutputCapabilities(colorDepth: ColorDepth.ansi16, unicode: true));
    assert(nice.border == BorderStyle.rounded);
    assert(nice.colors);

    // A whole terminal snapshot converts through its `alias this`.
    TermCaps term;
    term.colorDepth = ColorDepth.trueColor;
    term.unicode = true;
    assert(makeTheme(term) == nice);
}
