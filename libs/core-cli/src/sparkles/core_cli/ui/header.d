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

private string drawDivider(string title, HeaderProps props)
{
    const titleLen = title.unstyledLength;
    const padding = ' '.repeat(props.titlePadding).to!string;

    size_t totalWidth = props.width;
    if (totalWidth == 0)
        totalWidth = 4 + props.titlePadding * 2 + titleLen; // 2 chars each side minimum

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
    const totalWidth = props.width > 0 ? props.width : titleLen + 20;

    const line = props.bannerLineChar.repeat(totalWidth).to!string;
    const leftPad = (totalWidth - titleLen) / 2;
    const rightPad = totalWidth - titleLen - leftPad;
    const titleLine = ' '.repeat(leftPad).to!string ~ title ~ ' '.repeat(rightPad).to!string;

    return line ~ '\n' ~ titleLine ~ '\n' ~ line;
}
