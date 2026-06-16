/++
Section header rendering utilities.

Provides functions to draw styled section headers in terminal applications,
supporting divider and banner styles.
+/
module sparkles.core_cli.ui.header;

import std.algorithm : map, maxElement;
import std.array : appender;
import std.conv : to;
import std.range : repeat;
import std.string : lineSplitter;

import sparkles.base.text.grapheme : visibleWidth;

@safe:

/// Header display style.
enum HeaderStyle
{
    divider, // ── Title ──
    banner, // Full-width centered title with top/bottom lines
}

/// Configuration options for header rendering.
struct HeaderProps
{
    HeaderStyle style = HeaderStyle.divider;
    dchar lineChar = '─';
    dchar bannerLineChar = '═';

    /// Fixed header width in columns, or `0` for auto (size to the title).
    ///
    /// When `width > 0` it is a hard cap: a short title is padded out to it (so a
    /// banner fills the width), and a title wider than it is wrapped across lines
    /// so the header never exceeds `width`. Wrapping is column-aware (CJK/emoji)
    /// and keeps styles/links across the break, sharing `drawBox`'s primitive.
    size_t width = 0;
    size_t titlePadding = 1; // spaces around title in divider
}

/// Draw a section header.
///
/// Params:
///   title = The header title text
///   props = Rendering options
/// Returns:
///   Formatted header string
///
/// Examples:
/// ---
/// // Simple divider
/// "Section".drawHeader.writeln;
/// // Output: ── Section ──
///
/// // Banner style
/// "Main Title".drawHeader(HeaderProps(style: HeaderStyle.banner, width: 40)).writeln;
/// ---
string drawHeader(string title, HeaderProps props = HeaderProps.init)
{
    final switch (props.style)
    {
        case HeaderStyle.divider: return drawDivider(title, props);
        case HeaderStyle.banner: return drawBanner(title, props);
    }
}

/// Default divider style
@("header.drawHeader.defaultDivider")
unittest
{
    assert("Title".drawHeader == "── Title ──");
}

/// Custom line character
@("header.drawHeader.customLineChar")
unittest
{
    assert("Test".drawHeader(HeaderProps(lineChar: '═')) == "══ Test ══");
}

/// Banner style with fixed width
@("header.drawHeader.bannerStyle")
unittest
{
    const result = "Demo".drawHeader(HeaderProps(style: HeaderStyle.banner, width: 20));
    assert(result == "════════════════════\n        Demo        \n════════════════════");
}

/// Fixed width divider
@("header.drawHeader.fixedWidth")
unittest
{
    const result = "X".drawHeader(HeaderProps(width: 11));
    assert(result == "──── X ────");
}

/// A title wider than `width` is wrapped to fit (a single unbreakable token is
/// hard-broken), so a banner never exceeds `width`: every line is exactly that
/// wide. (This also guards the pad arithmetic, which would otherwise underflow
/// `size_t` and try to allocate a near-infinite line.)
@("header.drawBanner.titleWiderThanWidth")
unittest
{
    import std.string : splitLines;

    const title = "a-very-long-title-that-exceeds-the-requested-banner-width";
    const result = title.drawHeader(HeaderProps(style: HeaderStyle.banner, width: 20));
    const lines = result.splitLines;
    assert(lines.length >= 4); // top rule + >=2 wrapped title rows + bottom rule
    foreach (line; lines)
        assert(line.visibleWidth == 20);
}

/// The same hard cap for the divider style: every wrapped row is `width` wide.
@("header.drawDivider.titleWiderThanWidth")
unittest
{
    import std.string : splitLines;

    const title = "a-very-long-title-that-exceeds-the-requested-divider-width";
    const result = title.drawHeader(HeaderProps(width: 10));
    foreach (line; result.splitLines)
        assert(line.visibleWidth == 10);
}

/// `width` breaks a long banner title across lines instead of widening past it;
/// every line (rules and title rows) is exactly `width`, and the words survive.
@("header.drawBanner.wrap")
unittest
{
    import std.string : splitLines;
    import std.algorithm.searching : canFind;

    const title = "alpha beta gamma delta epsilon zeta";
    const result = title.drawHeader(HeaderProps(style: HeaderStyle.banner, width: 20));
    const lines = result.splitLines;
    assert(lines.length >= 4); // top rule + >=2 title rows + bottom rule
    foreach (line; lines)
        assert(line.visibleWidth == 20);
    assert(result.canFind("alpha") && result.canFind("zeta"));
}

/// The same for the divider style: each wrapped row is a full `width`-wide line.
@("header.drawDivider.wrap")
unittest
{
    import std.string : splitLines;

    const title = "alpha beta gamma delta epsilon zeta";
    const result = title.drawHeader(HeaderProps(width: 20));
    const lines = result.splitLines;
    assert(lines.length >= 2);
    foreach (line; lines)
        assert(line.visibleWidth == 20);
}

private string drawDivider(string title, HeaderProps props)
{
    const padding = ' '.repeat(props.titlePadding).to!string;
    // A line char each side plus the padding around the title.
    const overhead = 2 + props.titlePadding * 2;

    auto titleLines = props.width > overhead
        ? wrapTitle(title, props.width - overhead)
        : [title];

    size_t totalWidth = props.width;
    // Never narrower than the widest title line plus its overhead: a requested
    // width below that would underflow `remaining` (a `size_t`) and try to
    // allocate a near-infinite line. `width == 0` (auto) and any too-narrow
    // width both clamp to this minimum.
    const minWidth = overhead + titleLines.map!visibleWidth.maxElement;
    if (totalWidth < minWidth)
        totalWidth = (props.width == 0) ? minWidth + 2 : minWidth;

    auto sink = appender!string;
    foreach (i, line; titleLines)
    {
        if (i)
            sink ~= '\n';
        const remaining = totalWidth - line.visibleWidth - props.titlePadding * 2;
        const leftLen = remaining / 2;
        sink ~= props.lineChar.repeat(leftLen).to!string;
        sink ~= padding ~ line ~ padding;
        sink ~= props.lineChar.repeat(remaining - leftLen).to!string;
    }
    return sink[];
}

private string drawBanner(string title, HeaderProps props)
{
    auto titleLines = props.width > 0
        ? wrapTitle(title, props.width)
        : [title];

    const widest = titleLines.map!visibleWidth.maxElement;
    const requested = props.width > 0 ? props.width : widest + 20;
    // Never narrower than the widest title line, or the pad arithmetic below
    // underflows `size_t` and tries to allocate a near-infinite line.
    const totalWidth = requested > widest ? requested : widest;

    const rule = props.bannerLineChar.repeat(totalWidth).to!string;

    auto sink = appender!string;
    sink ~= rule;
    foreach (line; titleLines)
    {
        const leftPad = (totalWidth - line.visibleWidth) / 2;
        const rightPad = totalWidth - line.visibleWidth - leftPad;
        sink ~= '\n';
        sink ~= ' '.repeat(leftPad).to!string ~ line ~ ' '.repeat(rightPad).to!string;
    }
    sink ~= '\n';
    sink ~= rule;
    return sink[];
}

/// Column- and style-aware wrap of a header title to `width` cells, returning
/// one string per line. Shares `drawBox`'s wrapping primitive so headers and the
/// boxes beneath them break identically.
private string[] wrapTitle(string title, size_t width)
{
    import sparkles.base.text.wrap : wrapText, WrapOptions, WhitespaceMode;
    import std.array : array;

    return title
        .wrapText(WrapOptions(width: width, whitespace: WhitespaceMode.collapse))
        .lineSplitter
        .map!(to!string)
        .array;
}
