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
import sparkles.ui.effect : Builtin, EffectId;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.image : ImageFit;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState, swatchSize;

@safe:

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    alias fx = Builtin;

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

    // Raster content under a bracket. The effect does not know it is over an
    // image — `pushEffect` brackets a SUBTREE, and an image is an ordinary
    // leaf inside it — which is the whole reason the bracket was shaped like
    // a clip. In a window the tier-0 transform runs over the uploaded
    // texture's pixels; in a terminal it runs over `IMG4`'s placeholder,
    // because that is what the cells actually hold.
    body_ ~= section(b, "over raster content · an image is just a leaf", [
        picture(b, "none", EffectId.init, EffectId.init, s),
        picture(b, "phosphor", fx.phosphor, EffectId.init, s),
        picture(b, "spectrum", fx.spectrum, EffectId.init, s),
    ], gap: 1);
    body_ ~= spacer(b);

    // A CRT is not one effect. Curvature warps the tube's geometry and the
    // raster darkens alternate lines ON the warped result — so the two are
    // nested rather than merged, and the order is visible: scanlines bow
    // with the picture because they are inside the bracket that bows it.
    body_ ~= section(b, "a CRT · scanlines inside curvature (window only)", [
        picture(b, "crt", fx.curvature, fx.scanlines, s),
        para(b, degradationNote(s), w > 8 ? w - 6 : w),
    ]);
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

    // Tier 2 reads a NEIGHBOURHOOD of the layer — a blur, a glow — which
    // one cell's own colour cannot answer. Bloom is four passes declared as
    // data (`EffectPass`): extract the bright part at half size, blur it
    // both ways, add it back. The window runs all four; the terminal paints
    // the panel unaffected, which is what the effect declares.
    body_ ~= section(b, "tier 2 · reads the layer (window only)", [
        sample(b, "bloom", fx.bloom, w),
        para(b, layerNote(s), w > 8 ? w - 6 : w),
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
        ~ "is why four of the six built-ins are tier 0: naming one costs "
        ~ "an application nothing on a terminal. The other two are here so "
        ~ "the boundary is visible from both sides.", w);

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

/// ditto, for tier 2.
private string layerNote(in GalleryState s)
    => s.guiCellW > 0
        ? "Four passes: bright-pass at half size, blur across, blur down, add back."
        : "A cell cannot see its neighbours, so the panel above is painted "
        ~ "unaffected — the degradation bloom declares.";

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

/**
One raster specimen: the sample image under `outer`, and — when `inner` names
one — under a second bracket inside it.

The image is given an explicit cell box rather than its natural size: the
swatch is 64×32 pixels, which rounds to eight cells by two, and a distortion
is not legible across two rows. `contain` keeps its aspect inside that box,
so the warp is the only thing changing its shape.
*/
private uint picture(ref Builder b, string caption, EffectId outer,
    EffectId inner, in GalleryState s)
{
    const pic = b.add(Widget(
        kind: WidgetKind.image,
        image: s.sampleImage,
        imagePixels: swatchSize,
        imageFit: ImageFit.contain,
        text: "a colour swatch",
        slot: Slot.chip,
        width: SizeSpec.fixed(30),
        height: SizeSpec.fixed(7),
    ));

    // The inner bracket rides its own panel, so the outer effect sees the
    // inner one's RESULT — which is what makes the composition order
    // observable rather than a claim.
    const framed = inner.valid
        ? b.add(Widget(kind: WidgetKind.panel, children: [pic],
            slot: Slot.surface, paintBackground: true, effect: inner))
        : pic;

    const stack = column(b, [label(b, caption, Slot.chromeAccent), framed]);
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [stack],
        slot: Slot.surface,
        padding: Insets.symmetric(0, 1),
        width: SizeSpec.fixed(34),
        paintBackground: true,
        effect: outer,
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
    import sparkles.ui.effect : Builtin, Degradation, EffectRegistry,
        EffectTier;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import std.algorithm : count, filter;
    import std.array : array;

    EffectRegistry reg;
    GalleryState s;

    auto b = Builder();
    auto tree = b.finish(view(b, s));
    auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // Every bracket is paired — an unbalanced page would desynchronise the
    // canvas's effect stack for whatever painted next.
    const pushes = ops.count!(o => o.kind == OpKind.pushEffect);
    assert(pushes == ops.count!(o => o.kind == OpKind.popEffect));


    // Six single specimens (four tier 0, curvature, bloom), two effected
    // raster specimens, the CRT's two nested brackets, and the nesting
    // demonstration's two. The "none"
    // specimens must NOT emit one: a null id is the absence of an effect,
    // not an effect that does nothing.
    assert(pushes == 12, "every specimen that names an id, and only those");

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
    assert(cellHonoured == 9 && textureOnly == 3);
}
