/++
Section header rendering utilities.

Provides functions to draw styled section headers in terminal applications,
supporting divider and banner styles.
+/
module sparkles.core_cli.ui.header;

import std.conv : to;
import std.range : repeat;

import sparkles.core_cli.term_unstyle : unstyledLength;

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
    size_t width = 0; // 0 = auto
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

/// A title wider than the requested width must not underflow the pad
/// arithmetic (which previously tried to allocate a near-infinite line and
/// exhausted memory). The banner widens to fit the title instead.
@("header.drawBanner.titleWiderThanWidth")
unittest
{
    import std.string : split;

    const title = "a-very-long-title-that-exceeds-the-requested-banner-width";
    const result = title.drawHeader(HeaderProps(style: HeaderStyle.banner, width: 20));
    const lines = result.split('\n');
    assert(lines.length == 3);
    assert(lines[1] == title);                 // no padding, title verbatim
    assert(lines[0].unstyledLength == title.unstyledLength); // rule fits title
}

/// The same guard for the divider style.
@("header.drawDivider.titleWiderThanWidth")
unittest
{
    import std.algorithm.searching : canFind;

    const title = "a-very-long-title-that-exceeds-the-requested-divider-width";
    const result = title.drawHeader(HeaderProps(width: 10));
    // Must terminate and contain the title rather than allocate unboundedly.
    assert(result.canFind(title));
}

private string drawDivider(string title, HeaderProps props)
{
    const titleLen = title.unstyledLength;
    const padding = ' '.repeat(props.titlePadding).to!string;

    size_t totalWidth = props.width;
    // Never narrower than the title plus its padding (plus a line char each
    // side): a requested width below that would underflow `remaining` (a
    // `size_t`) and try to allocate a near-infinite line. `width == 0` (auto)
    // and any too-narrow width both clamp to this minimum.
    const minWidth = 2 + props.titlePadding * 2 + titleLen;
    if (totalWidth < minWidth)
        totalWidth = (props.width == 0) ? minWidth + 2 : minWidth;

    const remaining = totalWidth - titleLen - props.titlePadding * 2;
    const leftLen = remaining / 2;
    const rightLen = remaining - leftLen;

    return props.lineChar.repeat(leftLen).to!string
        ~ padding ~ title ~ padding
        ~ props.lineChar.repeat(rightLen).to!string;
}

private string drawBanner(string title, HeaderProps props)
{
    const titleLen = title.unstyledLength;
    const requested = props.width > 0 ? props.width : titleLen + 20;
    // Never narrower than the title itself, or the pad arithmetic below
    // underflows `size_t` and tries to allocate a near-infinite line.
    const totalWidth = requested > titleLen ? requested : titleLen;

    const line = props.bannerLineChar.repeat(totalWidth).to!string;
    const leftPad = (totalWidth - titleLen) / 2;
    const rightPad = totalWidth - titleLen - leftPad;
    const titleLine = ' '.repeat(leftPad).to!string ~ title ~ ' '.repeat(rightPad).to!string;

    return line ~ '\n' ~ titleLine ~ '\n' ~ line;
}
