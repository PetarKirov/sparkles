/**
Golden fixture tests for the markdown widget view: every markdown feature the
preview renders, exercised individually and composed, each fixture rendered
through the production pipeline (`extractMarkdown` → $(REF viewMarkdown,
sparkles,syntax,md,render_widgets) → `layout` → `CellGrid`) at a fixed width
and compared as a plain glyph grid.

Fixtures and goldens live side by side under `libs/syntax/test/data/md/goldens/`
(`<name>.md` + `<name>.txt`). The glyph grid ignores color on purpose: it is the
$(B layout) oracle — indentation, borders, wrapping, panel geometry — and reads
well in a diff; color/style assertions stay with the `RecordingCanvas` tests in
$(MREF sparkles,syntax,md,render_widgets).

To regenerate after an intended rendering change:

```
SPARKLES_UPDATE_GOLDENS=1 dub test :syntax -- -i md.goldens
git diff libs/syntax/test/data   # review the visual delta
```
*/
module sparkles.syntax.md.goldens;

version (unittest):

import std.file : exists, readText, write;
import std.path : buildNormalizedPath, dirName;
import std.process : environment;

import sparkles.base.term_color : RgbColor, toRgb;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.md.model : extractMarkdown;
import sparkles.syntax.md.render_widgets : MdViewOptions, MdViewTheme,
    viewMarkdown;
import sparkles.syntax.theme : resolveTheme;
import sparkles.syntax.themes : builtinThemes;
import sparkles.syntax.ts.registry : GrammarRegistry;
import sparkles.test_runner.skip : skipTest;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Constraints;
import sparkles.ui.interp.cells : CellGrid;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui.layout : layout;
import sparkles.ui.style : defaultTwoslashPalette;

/// The fixture corpus: individual features first, then the composition.
private static immutable fixtureNames = [
    "headings", "inline", "lists", "tables", "code", "callouts", "misc",
    "kitchen-sink",
];

private enum goldenWidth = 80;

private string goldenDir()
    => __FILE_FULL_PATH__.dirName
        .buildNormalizedPath("../../../../test/data/md/goldens");

/// Renders `source` exactly as the fixture tests see it: themed, line-numbered
/// fences, width-bounded — no fence renderer (highlighting changes only
/// colors, which the glyph grid does not record). `interactive` arms the copy
/// hit bases the way hue's viewer does, so the fence header's copy glyph and
/// the table's top-border cutout render.
private string renderGridText(ref GrammarRegistry registry,
    const(char)[] source, bool interactive = false)
{
    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes["catppuccin-mocha"], labels);
    const pageFg = toRgb(theme.defaults.fg, RgbColor(0xcc, 0xcc, 0xcc));
    const pageBg = toRgb(theme.defaults.bg, RgbColor(0x1e, 0x1e, 0x1e));

    auto doc = extractMarkdown(registry, source);
    MdViewOptions opt = {
        theme: MdViewTheme.derive(theme, pageFg, pageBg),
        codeLineNumbers: true,
        fenceHitBase: interactive ? size_t.max / 2 + 1 : 0,
        tableCopyHitBase: interactive ? size_t.max / 8 + 1 : 0,
    };
    auto tree = viewMarkdown(doc, opt);
    auto frames = layout(tree, Constraints(maxW: goldenWidth));
    const r = frames[tree.root].rect;

    auto grid = CellGrid(r.width, r.height, pageFg, pageBg);
    paint(grid, buildDisplayList(tree, frames, defaultTwoslashPalette(),
        pageFg, pageBg));

    // Plain glyph dump, trailing blanks trimmed per row (stable, diff-friendly).
    import std.utf : encode;

    string text;
    foreach (y; 0 .. grid.height)
    {
        size_t lineEnd = text.length;
        foreach (x; 0 .. grid.width)
        {
            char[4] buf;
            const n = encode(buf, grid.cells[y * grid.width + x].glyph);
            text ~= buf[0 .. n];
            if (grid.cells[y * grid.width + x].glyph != ' ')
                lineEnd = text.length;
        }
        text = text[0 .. lineEnd];
        text ~= '\n';
    }
    return text;
}

private void checkFixtures(in string[] names, string suffix, bool interactive)
{
    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto registry = GrammarRegistry.fromEnvironment();
    const update = environment.get("SPARKLES_UPDATE_GOLDENS", "").length != 0;
    const dir = goldenDir();

    foreach (name; names)
    {
        const mdPath = dir.buildNormalizedPath(name ~ ".md");
        const txtPath = dir.buildNormalizedPath(name ~ suffix);
        const rendered = renderGridText(registry, readText(mdPath),
            interactive);

        if (update)
        {
            write(txtPath, rendered);
            continue;
        }
        assert(txtPath.exists, name ~ suffix ~ " is missing — regenerate "
            ~ "with SPARKLES_UPDATE_GOLDENS=1 dub test :syntax -- -i md.goldens");
        const expected = readText(txtPath);
        assert(rendered == expected, name ~ ": rendered grid differs from "
            ~ name ~ suffix ~ " (first divergence at line "
            ~ firstDivergingLine(expected, rendered) ~ ") — if intended, "
            ~ "regenerate with SPARKLES_UPDATE_GOLDENS=1 and review the diff");
    }
}

@("md.goldens.fixtures")
@system unittest
{
    checkFixtures(fixtureNames, ".txt", interactive: false);
}

/// The copy affordances the viewer arms: the fence header's right-edge copy
/// glyph and the whole-table cutout in the top border (`COD3`/`TBL6`).
@("md.goldens.interactiveChrome")
@system unittest
{
    checkFixtures(["code", "tables"], ".interactive.txt", interactive: true);
}

/// 1-based line number of the first differing line, as text for the message.
private string firstDivergingLine(const(char)[] a, const(char)[] b)
{
    import std.algorithm.iteration : splitter;
    import std.conv : text;
    import std.range : zip;

    size_t line = 1;
    foreach (pair; zip(a.splitter('\n'), b.splitter('\n')))
    {
        if (pair[0] != pair[1])
            return text(line);
        ++line;
    }
    return text(line);
}
