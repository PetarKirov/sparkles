/**
The Effects page: subtree effects, and the tier model that decides what survives
to a cell grid.

The claim this page exists to make checkable is `EFX24`'s. A terminal showing
scanlines and a phosphor tint is the proof that tiering by $(I readable input)
is real and not a GPU feature wearing a tier label — so every specimen here is
tier 0, and every one of them is painted by the cell grid you are reading it
on. Nothing below is a picture of an effect; it is the effect.

Both targets honour tier 0, by different routes: the cell grid runs the D
transform per resolved cell, and the window renders the bracket to a texture
and runs the GLSL twin over it (`EFX11`). The page is where that agreement is
checkable by eye — the same specimen, side by side, in a terminal and a
window.
*/
module pages.effects_page;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.effect : EffectId;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState;

@safe:

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const fx = s.effects;

    uint[] body_;
    body_ ~= heading(b, "Effects · a bracket, not a post-pass");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A widget carries an effect id; the display list brackets its subtree "
        ~ "in pushEffect/popEffect, exactly as a clipping container brackets "
        ~ "one in pushClip/popClip. A backend that cannot honour an effect "
        ~ "paints the subtree unaffected — a declared degradation, so a "
        ~ "missing effect can never take a frame down.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "tier 0 · a per-cell colour transform", [
        sample(b, "none", EffectId.init, w),
        sample(b, "scanlines", fx.scanlines, w),
        sample(b, "phosphor", fx.phosphor, w),
        sample(b, "dim", fx.dim, w),
        sample(b, "spectrum", fx.spectrum, w),
    ], gap: 1);
    body_ ~= spacer(b);

    body_ ~= para(b,
        "Each block above is the same widgets under a different id. The "
        ~ "transform runs over the resolved colour of every cell in the "
        ~ "bracket, so it reaches the panel's own background as well as its "
        ~ "text — and a nested effect composes with its ancestors rather than "
        ~ "replacing them.", w);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Note which axis each one varies along. scanlines darkens alternate "
        ~ "ROWS, so a four-row panel can only show it once or twice and it "
        ~ "reads as a smudge; spectrum sweeps the hue across the COLUMNS, "
        ~ "which every bracket has plenty of, and puts a distinct 24-bit "
        ~ "colour in each cell while keeping that cell's own luminance. "
        ~ "Position is two axes and a tier-0 transform reads both.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "nesting · dim inside dim", [
        nested(b, fx.dim, w),
    ]);
    body_ ~= spacer(b);

    // The tier boundary, in both directions. `curvature` rewrites POSITION,
    // which needs a texture — so a window warps this panel and a terminal
    // paints it untouched and says so. Seeing the same specimen differ
    // between the two targets is the whole point of tiering by readable
    // input; a page that only showed tier 0 would be showing the easy half.
    body_ ~= section(b, "tier 1 · rewrites position (window only)", [
        sample(b, "curvature", fx.curvature, w),
        para(b, degradationNote(s), w > 8 ? w - 6 : w),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the tiers", [
        kv(b, "0 · color", "position + its own colour → colour. Cell grid: yes."),
        kv(b, "1 · distortion", "rewrites position. Needs a texture."),
        kv(b, "2 · layer", "samples the layer. Blur, glow, bloom."),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Tier 0 is the part of the vocabulary every target can honour, which "
        ~ "is why four of the five built-ins are tier 0: naming one costs "
        ~ "an application nothing on a terminal. The fifth is here so the "
        ~ "boundary is visible from both sides.", w);

    return column(b, body_);
}

/// What this target does with a tier-1 effect, read off the registry rather
/// than assumed — which is what makes `EFX12`'s `degradation` field load
/// bearing instead of decorative.
private string degradationNote(in GalleryState s)
    => s.guiCellW > 0
        ? "This target renders the bracket to a texture, so the panel above is warped."
        : "This target has no texture, so the panel above is painted unaffected — "
        ~ "the degradation the effect declares, not a silent omission.";

/// One specimen: a labelled panel of ordinary widgets under `effect`.
private uint sample(ref Builder b, string caption, EffectId effect, int width)
{
    const title = label(b, caption, Slot.chromeAccent);
    const line1 = label(b, "The quick brown fox", Slot.code);
    const line2 = label(b, "jumps over the lazy dog", Slot.docs);
    const bar = b.add(Widget(kind: WidgetKind.box, slot: Slot.chip,
        width: SizeSpec.fixed(24), height: SizeSpec.fixed(1),
        paintBackground: true));

    // `panel` overlays its children (it is a decorated box, not a flow), so
    // the stack goes in a column inside it.
    const stack = column(b, [title, line1, line2, bar]);

    // The effect rides the PANEL, so it brackets the panel's fill and every
    // descendant — one id on one node, no per-child bookkeeping.
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [stack],
        slot: Slot.surface,
        padding: Insets.symmetric(0, 1),
        width: SizeSpec.fixed(width < 34 ? width : 34),
        paintBackground: true,
        effect: effect,
    ));
}

/// An effected panel inside an effected panel: the inner cells take both.
private uint nested(ref Builder b, EffectId effect, int width)
{
    const inner = b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, "inner: dimmed twice", Slot.code)],
        slot: Slot.chip,
        padding: Insets.symmetric(0, 1),
        paintBackground: true,
        effect: effect,
    ));
    const outerText = label(b, "outer: dimmed once", Slot.code);
    const stack = column(b, [outerText, inner]);
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [stack],
        slot: Slot.surface,
        padding: Insets.symmetric(0, 1),
        width: SizeSpec.fixed(width < 34 ? width : 34),
        paintBackground: true,
        effect: effect,
    ));
}

@("ui_gallery.pages.effectsBracketsEveryTier0Builtin")
@safe unittest
{
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.effect : builtinEffects, Degradation, EffectRegistry,
        EffectTier;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import std.algorithm : count, filter;
    import std.array : array;

    EffectRegistry reg;
    GalleryState s;
    s.effects = builtinEffects(reg);

    auto b = Builder();
    auto tree = b.finish(view(b, s));
    auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // Every bracket is paired — an unbalanced page would desynchronise the
    // canvas's effect stack for whatever painted next.
    const pushes = ops.count!(o => o.kind == OpKind.pushEffect);
    assert(pushes == ops.count!(o => o.kind == OpKind.popEffect));

    // Five built-ins as top-level specimens, plus the two of the nesting
    // demonstration. The "none" specimen must NOT emit one: a null id is the
    // absence of an effect, not an effect that does nothing.
    assert(pushes == 7, "five specimens plus the nested pair");

    const ids = ops.filter!(o => o.kind == OpKind.pushEffect).array;
    size_t cellHonoured, textureOnly;
    foreach (ref op; ids)
    {
        assert(op.effectId.valid);
        const rec = reg.lookup(op.effectId);
        if (rec.honouredByCells)
            ++cellHonoured;
        else
        {
            ++textureOnly;
            // `EFX12`: an effect a cell grid cannot honour must SAY what it
            // does instead. A page specimen with no stated degradation would
            // be the silent omission the requirement exists to prevent.
            assert(rec.tier != EffectTier.color);
            assert(rec.degradation == Degradation.unaffected);
        }
    }
    // Both sides of the tier boundary are on the page. A catalogue showing
    // only the tier a terminal can run would be showing the easy half.
    assert(cellHonoured == 6 && textureOnly == 1);
}
