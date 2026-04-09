#!/usr/bin/env dub

/+ dub.sdl:
name "header"
dependency "sparkles:core-cli" version="*"
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
}
