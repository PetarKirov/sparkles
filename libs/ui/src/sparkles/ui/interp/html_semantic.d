/**
The $(B first-class) HTML mode of $(MREF sparkles,ui) (`TGT4`): semantic class
names + an external stylesheet, instead of per-node inline styles — so a page
of widgets is themable by swapping one `<style>`, diffs read as structure
rather than color soup, and tier-0 interactivity (hover-reveal, disclosure) is
$(B pure CSS) with no script.

Two functions, one contract:

$(LIST
    * $(LREF writeSlotStylesheet) — the palette as CSS: one `.spk-<slot>` rule
        per $(REF Slot, sparkles,ui,style) plus the structural base classes and
        the tier-0 interaction rules.
    * $(LREF renderWidgetHtmlClasses) — the tree as markup that references
        those classes; only per-node $(I geometry) (sizes, padding, gap,
        scroll offset) stays inline, because it is structure, not theme.
)

The inline-style emitter ($(MREF sparkles,ui,interp,html)) stays the parity
oracle — it needs no stylesheet and screenshots stand alone; this mode is what
a real page (the gallery, the explorer) serves.
*/
module sparkles.ui.interp.html_semantic;

import std.conv : to;
import std.range.primitives : isOutputRange, put;

import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Palette, resolveSlot, Slot, Visual;
import sparkles.ui.widget : Alignment, Visibility, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;
import sparkles.base.term_color : RgbColor;

@safe:

/**
Writes the stylesheet: the structural base classes (`.spk`, `.spk-row`, …),
the tier-0 interaction rules (`.spk-hit:hover > .spk-reveal`, `<details>`
disclosure), and one `.spk-<slot>` rule per palette slot resolved against the
page colors. Swap the palette, re-emit this one block, and every page themed
by it follows.
*/
void writeSlotStylesheet(Writer)(ref Writer w, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg)
if (isOutputRange!(Writer, char))
{
    // Structural base classes: one per widget kind, plus clip/visibility.
    put(w, ".spk{box-sizing:border-box}"
        ~ ".spk-text,.spk-rich,.spk-glyph{white-space:pre;font-family:ui-monospace,monospace}"
        ~ ".spk-row{display:flex;flex-direction:row;align-items:flex-start}"
        ~ ".spk-column{display:flex;flex-direction:column}"
        ~ ".spk-stack,.spk-panel,.spk-popup{position:relative;display:flex;flex-direction:column}"
        ~ ".spk-clip-x{overflow-x:hidden}.spk-clip-y{overflow-y:hidden}"
        ~ ".spk-hidden{visibility:hidden}.spk-collapsed{display:none}"
        // Tier-0 interactivity (INP tier 0), no script:
        // hover-reveal (the hover popup) and native disclosure (folding).
        ~ ".spk-reveal{display:none;position:absolute;z-index:1}"
        ~ ".spk-hit:hover>.spk-reveal{display:block}"
        ~ "details.spk-disclosure>summary{cursor:pointer;list-style:none}");

    // One rule per slot, colors resolved against the page.
    foreach (slot; Slot.min .. Slot.max + 1)
    {
        const s = cast(Slot) slot;
        if (s == Slot.inherit)
            continue;
        const vis = resolveSlot(pal, s, pageFg, pageBg);
        put(w, ".spk-");
        put(w, s.to!string);
        put(w, "{color:");
        rgba(w, vis.fg, vis.fgAlpha);
        if (vis.hasBg)
        {
            put(w, ";background:");
            rgba(w, vis.bg, vis.bgAlpha);
        }
        put(w, "}");
    }
}

/**
Renders `tree` as semantic markup over $(LREF writeSlotStylesheet)'s classes.
No palette in sight: colors come from the slot classes, so the same markup
re-themes by stylesheet alone. Geometry that is structure rather than theme —
fixed extents, padding, gap, the scroll offset — is emitted inline.
*/
void renderWidgetHtmlClasses(Writer)(ref Writer w, in WidgetTree tree)
if (isOutputRange!(Writer, char))
{
    emitNode(w, tree, tree.root);
}

private void emitNode(Writer)(ref Writer w, in WidgetTree tree, uint idx)
{
    const node = tree.nodes[idx];
    const tag = node.kind == WidgetKind.text || node.kind == WidgetKind.rich
        || node.kind == WidgetKind.glyph ? "span" : "div";

    put(w, "<");
    put(w, tag);
    put(w, " class=\"spk spk-");
    put(w, node.kind.to!string);
    if (node.slot != Slot.inherit)
    {
        put(w, " spk-");
        put(w, node.slot.to!string);
    }
    if (node.clipX)
        put(w, " spk-clip-x");
    if (node.clipY)
        put(w, " spk-clip-y");
    if (node.visibility == Visibility.hidden)
        put(w, " spk-hidden");
    else if (node.visibility == Visibility.collapsed)
        put(w, " spk-collapsed");
    if (node.hitId != 0)
        put(w, " spk-hit");
    put(w, "\"");

    // Structure-not-theme geometry, inline.
    structuralStyle(w, node);
    put(w, ">");

    final switch (node.kind) with (WidgetKind)
    {
        case text:
            escape(w, node.text);
            break;
        case rich:
            foreach (ref span; node.spans)
            {
                put(w, "<span");
                if (span.slot != Slot.inherit)
                {
                    put(w, " class=\"spk-");
                    put(w, span.slot.to!string);
                    put(w, "\"");
                }
                put(w, ">");
                escape(w, span.text);
                put(w, "</span>");
            }
            break;
        case glyph:
            char[4] enc;
            import std.utf : encode;

            const n = encode(enc, node.glyph);
            escape(w, enc[0 .. n]);
            break;
        case line, scrollbar, box:
            break;
        case row, column, stack, panel, popup:
            foreach (child; node.children)
                emitNode(w, tree, child);
            break;
    }

    put(w, "</");
    put(w, tag);
    put(w, ">");
}

// Inline declarations for per-node geometry (never colors — those are theme).
private void structuralStyle(Writer)(ref Writer w, in Widget node)
{
    bool open;
    void decl(scope const(char)[] s)
    {
        put(w, open ? ";" : " style=\"");
        open = true;
        put(w, s);
    }
    void dim(scope const(char)[] prop, int v, scope const(char)[] unit)
    {
        decl(prop);
        num(w, v);
        put(w, unit);
    }

    if (node.width.kind == SizeSpec.Kind.fixed)
        dim("width:", node.width.value, "ch");
    else if (node.width.kind == SizeSpec.Kind.grow)
        decl("flex-grow:1");
    if (node.height.kind == SizeSpec.Kind.fixed)
        dim("height:", node.height.value, "lh");
    if (node.padding != Insets.init)
    {
        decl("padding:");
        num(w, node.padding.top);
        put(w, "lh ");
        num(w, node.padding.right);
        put(w, "ch ");
        num(w, node.padding.bottom);
        put(w, "lh ");
        num(w, node.padding.left);
        put(w, "ch");
    }
    if (node.gap != 0)
        dim("gap:", node.gap, "ch");
    if (node.wrap != TextWrap.none)
        decl("white-space:pre-wrap");
    if (node.alignX == Alignment.center)
        decl("justify-content:center");
    else if (node.alignX == Alignment.end)
        decl("justify-content:flex-end");
    if (node.childOffset.x != 0 || node.childOffset.y != 0)
    {
        decl("--spk-scroll:translate(");
        num(w, -node.childOffset.x);
        put(w, "ch,");
        num(w, -node.childOffset.y);
        put(w, "lh)");
    }
    if (open)
        put(w, "\"");
}

private void num(Writer)(ref Writer w, int v)
{
    import sparkles.base.text.writers : writeInteger;

    if (v < 0)
    {
        put(w, '-');
        v = -v;
    }
    writeInteger(w, cast(uint) v);
}

private void rgba(Writer)(ref Writer w, in RgbColor c, ubyte alpha)
{
    put(w, "rgba(");
    num(w, c.r);
    put(w, ",");
    num(w, c.g);
    put(w, ",");
    num(w, c.b);
    put(w, ",");
    if (alpha == 0xFF)
        put(w, "1");
    else
    {
        // two-decimal fraction of 255
        const centi = (alpha * 100 + 127) / 255;
        put(w, "0.");
        if (centi < 10)
            put(w, "0");
        num(w, centi);
    }
    put(w, ")");
}

private void escape(Writer)(ref Writer w, scope const(char)[] s)
{
    foreach (char c; s)
        switch (c)
        {
            case '<': put(w, "&lt;"); break;
            case '>': put(w, "&gt;"); break;
            case '&': put(w, "&amp;"); break;
            case '"': put(w, "&quot;"); break;
            default: put(w, c);
        }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui.interp.html_semantic.stylesheetCoversEverySlot")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : defaultTwoslashPalette;

    SmallBuffer!(char, 4096) w;
    writeSlotStylesheet(w, defaultTwoslashPalette(),
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));
    const css = w[];

    // Every slot (except inherit) has a rule; the tier-0 rules are present.
    foreach (slot; Slot.min + 1 .. Slot.max + 1)
        assert(css.canFind(".spk-" ~ (cast(Slot) slot).to!string ~ "{"));
    assert(css.canFind(".spk-hit:hover>.spk-reveal{display:block}"));
    assert(css.canFind("details.spk-disclosure>summary"));
}

@("ui.interp.html_semantic.markupIsClassesNotColors")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.widget : Builder, TextSpan;

    auto b = Builder();
    Widget sig = Widget(kind: WidgetKind.rich, slot: Slot.code, hitId: 3,
        spans: [TextSpan("const", Slot.docs), TextSpan(" x")]);
    const t = b.add(sig);
    const popup = b.container(WidgetKind.popup, [t],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(popup);

    SmallBuffer!(char, 1024) w;
    renderWidgetHtmlClasses(w, tree);
    const html = w[];

    assert(html.canFind(`<div class="spk spk-popup spk-surface"`));
    assert(html.canFind(`<span class="spk spk-rich spk-code spk-hit"`));
    assert(html.canFind(`<span class="spk-docs">const</span>`));
    assert(html.canFind("padding:1lh 1ch 1lh 1ch"));
    // The whole point: not one color in the markup.
    assert(!html.canFind("rgba(") && !html.canFind("color:"));
}
