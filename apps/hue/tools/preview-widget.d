#!/usr/bin/env dub
/+ dub.sdl:
    name "preview_widget"
    dependency "sparkles:syntax" path="../../.."
+/
// Renders a markdown file through the WIDGET path (viewMarkdown → layout →
// CellGrid → ANSI) — the visual parity probe for the M10 preview swap: run it
// beside `hue <file.md> | cat` and compare. Not wired into hue itself yet.
module preview_widget;
// CellGrid → ANSI) — the parity probe for the M10 preview swap.
import std.file : readText;
import std.stdio : write;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : RgbColor, toRgb;
import sparkles.syntax;
import sparkles.syntax.md.render_widgets;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Constraints;
import sparkles.ui.interp.cells : CellGrid;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui.layout : layout;
import sparkles.ui.style : defaultTwoslashPalette;

void main(string[] args)
{
    const src = readText(args.length > 1 ? args[1] : "README.md");
    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes["catppuccin-mocha"], labels);
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);

    auto doc = extractMarkdown(registry, src);
    const pageFg = toRgb(theme.defaults.fg, RgbColor(0xcc, 0xcc, 0xcc));
    const pageBg = toRgb(theme.defaults.bg, RgbColor(0x1e, 0x1e, 0x1e));
    const vt = MdViewTheme.derive(theme, pageFg, pageBg);

    MdViewOptions opt = {
        theme: vt,
        fenceRenderer: highlightedFenceRenderer(&cache, &theme, pageFg),
    };
    auto tree = viewMarkdown(doc, opt);
    auto frames = layout(tree, Constraints(maxW: 100));
    const r = frames[tree.root].rect;

    auto grid = CellGrid(r.width, r.height, pageFg, pageBg);
    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(), pageFg, pageBg);
    paint(grid, ops);
    SmallBuffer!char outBuf;
    grid.writeAnsi(outBuf);
    write(outBuf[]);
}
