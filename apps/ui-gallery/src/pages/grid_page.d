/**
The Grid page: the Cartesian backdrop component (`GRD11`).

Three named fixtures (default lines, stripe bands, dotted graph paper) plus a
live preview whose preset cycles with `p`, so the catalog shows the component
without the diagram world.
*/
module pages.grid_page;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.grid_backdrop : buildGridPreview, GridConfig,
    gridPreset, GridPreset;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import keymap : GalleryCommand;
import state : GalleryState;

@safe:

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const previewW = w > 48 ? 40 : (w > 16 ? w - 8 : 16);
    enum previewH = 10;

    uint[] body_;
    body_ ~= heading(b, "Grid · a Cartesian backdrop");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Major and minor lattice layers, stripe bands, and a mark kind that is "
        ~ "either continuous lines or dots at intersections. The same config "
        ~ "paints the diagram board and this page — a widget preview here, "
        ~ "DrawOps on the infinite canvas.", w);
    body_ ~= spacer(b);

    static immutable string[3] titles = [
        "Default (RND4)",
        "Stripe bands",
        "Dot paper",
    ];
    static immutable GridPreset[3] presets = [
        GridPreset.defaultLines,
        GridPreset.stripeBands,
        GridPreset.dotPaper,
    ];
    foreach (i, title; titles)
        body_ ~= specimenOf(b, title, gridPreset(presets[i]), previewW, previewH);

    body_ ~= spacer(b);
    const live = gridPreset(s.gridDemo.preset);
    body_ ~= section(b, "live  (p cycles)", [
        buildGridPreview(b, live, previewW, previewH),
        label(b, presetName(s.gridDemo.preset), Slot.code),
    ], 1);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Visibility is none / x / y / xy per layer. Intervals are world cells. "
        ~ "Brushes are theme slots (or transparent). Press p to cycle the live "
        ~ "preview through the three fixtures.", w);

    return column(b, body_);
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.gridPreset:
            const n = cast(ubyte) GridPreset.max + 1;
            s.gridDemo.preset = cast(GridPreset) ((cast(ubyte) s.gridDemo.preset + 1) % n);
            return true;
        default: return false;
    }
}

private uint specimenOf(ref Builder b, string title, in GridConfig cfg,
    int width, int height)
{
    const preview = buildGridPreview(b, cfg, width, height);
    const framed = b.add(Widget(
        kind: WidgetKind.panel,
        children: [preview],
        slot: Slot.surface,
        padding: Insets.all(1),
        decoration: Decoration(
            borderWidth: Insets.all(1),
            borderStyle: BorderStyle.solid,
            borderSlot: Slot.border,
        ),
    ));
    return section(b, title, [framed]);
}

private string presetName(GridPreset p) @safe pure nothrow @nogc
{
    final switch (p)
    {
        case GridPreset.defaultLines: return "defaultLines";
        case GridPreset.stripeBands: return "stripeBands";
        case GridPreset.dotPaper: return "dotPaper";
    }
}

version (unittest)
{
    import keymap : commandFor, GalleryContext, GalleryScope;

    // Tests drive the page exactly as the shell does: the key resolves in
    // the page's scope and the command dispatches above.
    private bool handleKey(ref GalleryState s, in KeyEvent k) @safe
    {
        const r = commandFor(k, GalleryContext(
            pageScope: GalleryScope.pageGrid, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }
}

@("ui_gallery.pages.gridShowsEveryFixture")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    GalleryState s;
    auto b = Builder();
    auto tree = b.finish(view(b, s));
    assert(tree.nodes.length > 8, "three fixtures plus live preview");

    assert(handleKey(s, KeyEvent(Key.char_, 'p')));
    assert(s.gridDemo.preset == GridPreset.stripeBands);
    assert(handleKey(s, KeyEvent(Key.char_, 'p')));
    assert(s.gridDemo.preset == GridPreset.dotPaper);
    assert(handleKey(s, KeyEvent(Key.char_, 'p')));
    assert(s.gridDemo.preset == GridPreset.defaultLines);
}
