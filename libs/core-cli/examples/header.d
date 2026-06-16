#!/usr/bin/env dub

/+ dub.sdl:
name "header"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

import sparkles.core_cli.ui.header;
import std.stdio : writeln;

void main()
{
    // Simple divider (default style)
    writeln("Default divider:");
    "Section Title".drawHeader.writeln;
    writeln();

    // Custom line character
    writeln("Double line divider:");
    "Important".drawHeader(HeaderProps(lineChar: '═')).writeln;
    writeln();

    // Fixed width divider
    writeln("Fixed width (40 chars):");
    "Centered".drawHeader(HeaderProps(width: 40)).writeln;
    writeln();

    // Banner style
    writeln("Banner style:");
    "Main Title".drawHeader(HeaderProps(style: HeaderStyle.banner, width: 30)).writeln;
    writeln();

    // Banner with auto width
    writeln("Banner (auto width):");
    "Auto Width Banner".drawHeader(HeaderProps(style: HeaderStyle.banner)).writeln;
    writeln();

    // A long title that exceeds the width is wrapped to fit, so the banner never
    // grows past `width` — every line is exactly 40 columns.
    const longTitle = "Verifying 3 example(s) from docs/libs/base/how-to/prettyprint-values.md";

    writeln("Banner with a long title (wraps to width):");
    longTitle.drawHeader(HeaderProps(style: HeaderStyle.banner, width: 40)).writeln;
    writeln();

    // Wrapping applies to dividers too.
    writeln("Divider with a long title (wraps to width):");
    longTitle.drawHeader(HeaderProps(width: 40)).writeln;
}
