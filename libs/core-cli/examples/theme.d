#!/usr/bin/env dub
/+ dub.sdl:
    name "theme"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

// The theme layer (`sparkles.ui.components.theme`): one `BorderStyle` selector
// picks a consistent charset across box, header, and table; `StatusGlyphs`
// names the checklist vocabulary with ASCII fallbacks; `Semantic` maps roles to
// styles in one place. `makeTheme(detectTermCaps())` resolves all of it from
// the live terminal — this demo also shows the forced ASCII degradation a
// non-UTF-8 terminal would get.

module theme_example;

import std.stdio : writefln, writeln;

import sparkles.base.term_caps : detectTermCaps, TermCaps;
import sparkles.ui.components.box : drawBox;
import sparkles.ui.components.header : drawHeader, HeaderProps;
import sparkles.ui.components.table : drawTable, TableProps;
import sparkles.ui.components.theme;

void main()
{
    // Resolve a theme from the real terminal (colors/unicode/tty aware)…
    const live = makeTheme(detectTermCaps());
    writefln!"detected: colors=%s unicode=%s border=%s"(
        live.colors, live.unicode, live.border);

    // …or build one by hand. `paint`/`mark` degrade to plain text when colors
    // are off, so the demo output below is deterministic.
    const theme = Theme(colors: false, unicode: true);
    writeln(theme.mark(Semantic.success), " check passed");
    writeln(theme.mark(Semantic.failure), " check failed");
    writeln(theme.mark(Semantic.warning), " needs attention");
    writeln(theme.paint(Semantic.muted, "(muted detail)"));

    // The ASCII fallback vocabulary a non-UTF-8 terminal selects:
    const ascii = statusGlyphs(false);
    writefln!"ascii glyphs: ok=%s fail=%s pending=%s skipped=%s ellipsis=%s"(
        ascii.ok, ascii.fail, ascii.pending, ascii.skipped, ascii.ellipsis);

    // One BorderStyle, three components — same charset everywhere.
    foreach (style; [BorderStyle.rounded, BorderStyle.ascii, BorderStyle.heavy])
    {
        writeln();
        writeln(drawHeader("borders: " ~ borderPresetName(style),
            HeaderProps(lineChar: headerLineChar(style))));
        writeln(drawBox(["one line"], "box", boxGlyphs(style)));
        writeln(drawTable([["a", "b"]], TableProps(glyphs: tableGlyphs(style))));
    }
}
