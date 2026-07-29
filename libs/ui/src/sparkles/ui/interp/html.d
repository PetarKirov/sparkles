/**
The SSG / HTML interpreter for $(MREF sparkles,ui): $(LREF renderWidgetHtml) walks
a $(REF WidgetTree, sparkles,ui,widget) and emits $(B semantic, nested HTML) —
one `<div>`/`<span>` per node — with each node's resolved
$(REF Visual, sparkles,ui,style) written as inline CSS (border / radius / shadow /
font / color). Unlike the pixel backends it walks the tree (not the flat display
list), so containers nest and the browser lays them out.

This is the $(B ground-truth oracle) of the two-direction parity harness: a widget
tree rendered here and screenshotted by a browser is the reference the raylib GUI
and terminal TUI rasters are compared against ("are the widget settings rendered
correctly?"). It is also the seed of the eventual `render_html` replacement — the
same view + palette that drive every other backend, emitted as HTML.

Self-contained: styles are inlined (no external stylesheet needed), so a page is
directly browser- or Artifact-renderable. `@safe`, `Writer`-generic (any output
range of `char`).
*/
module sparkles.ui.interp.html;

import sparkles.ui.geometry : Insets;
import sparkles.ui.style :
    BorderStyle, FontRole, Palette, resolveVisual, Slot, Visual;
import sparkles.ui.widget : Alignment, Visibility, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;
import sparkles.base.term_color : RgbColor;

import std.range.primitives : isOutputRange, put;

@safe:

/**
Renders `tree` as a semantic HTML fragment (a single root element, nested) with
inline styles resolved from `pal` against the page fore/background. The caller
wraps the fragment in a page ($(LREF writeWidgetHtmlPage) does the common case).
*/
void renderWidgetHtml(Writer)(ref Writer w, in WidgetTree tree, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg)
if (isOutputRange!(Writer, char))
{
    emitNode(w, tree, tree.root, pal, pageFg, pageBg);
}

/**
Wraps $(LREF renderWidgetHtml)'s fragment in a complete, self-contained HTML
document whose body is filled with `pageBg` and centred, ready to screenshot as
the parity ground truth. `title` names the page.
*/
void writeWidgetHtmlPage(Writer)(ref Writer w, in WidgetTree tree, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg, scope const(char)[] title = "widgets")
if (isOutputRange!(Writer, char))
{
    put(w, "<!doctype html><html><head><meta charset=\"utf-8\"><title>");
    escape(w, title);
    put(w, "</title></head><body style=\"margin:0;padding:24px;background:");
    rgba(w, pageBg, 0xFF);
    put(w, ";color:");
    rgba(w, pageFg, 0xFF);
    put(w, ";font-family:ui-monospace,monospace;font-size:16px;line-height:1.4\">");
    renderWidgetHtml(w, tree, pal, pageFg, pageBg);
    put(w, "</body></html>");
}

// ---------------------------------------------------------------------------

private void emitNode(Writer)(ref Writer w, in WidgetTree tree, uint idx,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg)
{
    const node = tree.nodes[idx];
    const vis = resolveVisual(pal, node.slot, node.decoration, node.textStyle, pageFg, pageBg);

    final switch (node.kind) with (WidgetKind)
    {
        case text:
            put(w, "<span style=\"");
            textStyle(w, vis);
            // A wrapping run lets the browser break lines (the cell backends
            // break through `layout`; here the layout engine *is* the browser).
            if (node.wrap != TextWrap.none)
                put(w, ";white-space:pre-wrap");
            visibilityCss(w, node);
            // A text widget can be a chip/pill (`paintBackground` + radius, e.g. the
            // JSDoc `@tag` name) — carry its background, radius, and pill padding.
            if (node.paintBackground && vis.hasBg)
            {
                put(w, ";background:");
                rgba(w, vis.bg, vis.bgAlpha);
                put(w, ";padding:0.05em 0.4em");
            }
            if (vis.borderRadius > 0)
            {
                put(w, ";border-radius:");
                num(w, vis.borderRadius);
                put(w, "px");
            }
            put(w, "\">");
            escape(w, node.text);
            put(w, "</span>");
            break;

        case rich:
            // One <span> per styled span; each resolves its own slot/chrome
            // against the node's as fallback (the browser concatenates them
            // inline, matching the cell backends' advance). A wrapping run
            // lets the browser break lines; a `paintBackground` span is an
            // inline pill (background + the node's radius + pill padding).
            import sparkles.ui.style : TextStyle;

            foreach (ref span; node.spans)
            {
                const slot = span.slot == Slot.inherit ? node.slot : span.slot;
                const style = span.textStyle == TextStyle.init
                    ? node.textStyle : span.textStyle;
                auto sv = resolveVisual(pal, slot, node.decoration, style,
                    pageFg, pageBg);
                if (span.hasFg) // the syntax channel: a resolved color
                    sv.fg = span.fg;
                put(w, "<span style=\"");
                textStyle(w, sv);
                if (node.wrap != TextWrap.none)
                    put(w, ";white-space:pre-wrap");
                if (span.paintBackground && sv.hasBg)
                {
                    put(w, ";background:");
                    rgba(w, sv.bg, sv.bgAlpha);
                    put(w, ";padding:0.05em 0.4em");
                    if (sv.borderRadius > 0)
                    {
                        put(w, ";border-radius:");
                        num(w, sv.borderRadius);
                        put(w, "px");
                    }
                }
                visibilityCss(w, node);
                put(w, "\">");
                escape(w, span.text);
                put(w, "</span>");
            }
            break;

        case glyph:
            put(w, "<span style=\"");
            textStyle(w, vis);
            visibilityCss(w, node);
            put(w, "\">");
            char[4] enc;
            import std.utf : encode;

            const n = encode(enc, node.glyph);
            escape(w, enc[0 .. n]);
            put(w, "</span>");
            break;

        case line:
            // A stroked connector → a thin element with a bottom border.
            put(w, "<div style=\"height:1px;border-bottom:1px solid ");
            rgba(w, vis.fg, vis.fgAlpha);
            visibilityCss(w, node);
            put(w, "\"></div>");
            break;

        case box:
            put(w, "<div style=\"");
            boxStyle(w, node, vis);
            put(w, "\"></div>");
            break;

        case row, column, stack, panel, popup:
            put(w, "<div style=\"");
            boxStyle(w, node, vis);
            // Flow direction for the flex containers, with the container's
            // per-axis alignment (LAY8). A row centers its items vertically
            // only when the tree says so — the cell backends are the parity
            // reference, and they top-align by default.
            if (node.kind == row)
            {
                put(w, ";display:flex;flex-direction:row;align-items:");
                put(w, flexAlign(node.alignY));
                if (node.alignX != Alignment.start)
                {
                    put(w, ";justify-content:");
                    put(w, flexAlign(node.alignX));
                }
            }
            else
            {
                if (node.kind != column)
                    put(w, ";position:relative");
                put(w, ";display:flex;flex-direction:column");
                if (node.alignX != Alignment.start)
                {
                    put(w, ";align-items:");
                    put(w, flexAlign(node.alignX));
                }
                if (node.alignY != Alignment.start)
                {
                    put(w, ";justify-content:");
                    put(w, flexAlign(node.alignY));
                }
            }
            if (node.gap != 0)
            {
                put(w, ";gap:");
                num(w, node.gap);
                put(w, "ch");
            }
            // A clipping container is CSS overflow; the browser does the rest.
            if (node.clipX && node.clipY)
                put(w, ";overflow:hidden");
            else if (node.clipX)
                put(w, ";overflow-x:hidden");
            else if (node.clipY)
                put(w, ";overflow-y:hidden");
            put(w, "\">");
            // A popup arrow renders as a rotated bordered square, as in the CSS.
            if (vis.arrow)
                emitArrow(w, vis, node.decoration.arrowOffset);
            // A scroll offset translates the children inside the clipped box
            // (`lh` = one text row, the cell-grid row analog).
            const scrolled = node.childOffset.x != 0 || node.childOffset.y != 0;
            if (scrolled)
            {
                put(w, "<div style=\"transform:translate(");
                num(w, -node.childOffset.x);
                put(w, "ch,");
                num(w, -node.childOffset.y);
                put(w, "lh)\">");
            }
            foreach (child; node.children)
                emitNode(w, tree, child, pal, pageFg, pageBg);
            if (scrolled)
                put(w, "</div>");
            put(w, "</div>");
            break;
    }
}

/// The `.twoslash-popup-arrow` analog: a small square with top+right borders,
/// rotated -45°, in the surface color, poking up out of the box's top edge.
private void emitArrow(Writer)(ref Writer w, in Visual vis, int arrowOffset)
{
    put(w, "<div style=\"position:absolute;top:-4px;left:");
    num(w, arrowOffset + 1);
    put(w, "ch;width:6px;height:6px;transform:rotate(-45deg);background:");
    rgba(w, vis.bg, vis.bgAlpha);
    if (vis.border.any)
    {
        put(w, ";border-top:1px solid ");
        rgba(w, vis.border.color, vis.border.alpha);
        put(w, ";border-right:1px solid ");
        rgba(w, vis.border.color, vis.border.alpha);
    }
    put(w, "\"></div>");
}

/// The flex keyword for a per-axis $(REF Alignment, sparkles,ui,widget)
/// (`align-items` and `justify-content` share the vocabulary).
private string flexAlign(Alignment a)
    => a == Alignment.center ? "center"
        : a == Alignment.end ? "flex-end" : "flex-start";

/// The `LAY11` tri-state as CSS: `hidden` keeps its space, `collapsed`
/// leaves the flow entirely.
private void visibilityCss(Writer)(ref Writer w, in Widget node)
{
    if (node.visibility == Visibility.hidden)
        put(w, ";visibility:hidden");
    else if (node.visibility == Visibility.collapsed)
        put(w, ";display:none");
}

/// Writes the box CSS declarations (background / border / radius / shadow /
/// padding) for a container or `box` from its resolved `Visual`.
private void boxStyle(Writer)(ref Writer w, in Widget node, in Visual vis)
{
    put(w, "box-sizing:border-box");
    visibilityCss(w, node);
    if (vis.hasBg)
    {
        put(w, ";background:");
        rgba(w, vis.bg, vis.bgAlpha);
    }
    borderStyle(w, vis);
    if (vis.borderRadius > 0)
    {
        put(w, ";border-radius:");
        num(w, vis.borderRadius);
        put(w, "px");
    }
    if (vis.shadow.any)
    {
        put(w, ";box-shadow:");
        num(w, vis.shadow.dx);
        put(w, "px ");
        num(w, vis.shadow.dy);
        put(w, "px ");
        num(w, vis.shadow.blur);
        put(w, "px ");
        rgba(w, vis.shadow.color, vis.shadow.alpha);
    }
    padding(w, node.padding);
    // Text color / font also apply to a container's inherited text.
    if (vis.fg != RgbColor.init || vis.fgAlpha != 0xFF)
    {
        put(w, ";color:");
        rgba(w, vis.fg, vis.fgAlpha);
    }
}

/// Writes the per-side border declarations, honoring the dotted/dashed style.
private void borderStyle(Writer)(ref Writer w, in Visual vis)
{
    if (!vis.border.any)
        return;
    const b = vis.border;
    const style = b.style == BorderStyle.dotted ? "dotted"
        : b.style == BorderStyle.dashed ? "dashed" : "solid";
    void edge(string side, int px)
    {
        if (px <= 0)
            return;
        put(w, ";border-");
        put(w, side);
        put(w, ":");
        num(w, px);
        put(w, "px ");
        put(w, style);
        put(w, " ");
        rgba(w, b.color, b.alpha);
    }

    edge("top", b.width.top);
    edge("right", b.width.right);
    edge("bottom", b.width.bottom);
    edge("left", b.width.left);
}

/// Writes the text CSS (color / font-family / size / weight / italic / decoration)
/// for a text or glyph run.
private void textStyle(Writer)(ref Writer w, in Visual vis)
{
    // `pre` so a whitespace-only run (the inter-word space widget the cell backends
    // rely on) isn't collapsed by the browser's flex layout.
    put(w, "white-space:pre;color:");
    rgba(w, vis.fg, vis.fgAlpha);
    final switch (vis.fontRole) with (FontRole)
    {
        case inherit, code:
            put(w, ";font-family:ui-monospace,monospace");
            break;
        case docs:
            put(w, ";font-family:sans-serif");
            break;
    }
    if (vis.fontScale != 100)
    {
        put(w, ";font-size:");
        num(w, vis.fontScale);
        put(w, "%");
    }
    import sparkles.base.term_style : TextAttr, UnderlineStyle;

    if (vis.styleBits & TextAttr.bold.bits)
        put(w, ";font-weight:bold");
    if (vis.styleBits & TextAttr.italic.bits)
        put(w, ";font-style:italic");
    if (vis.styleBits & TextAttr.strikethrough.bits)
        put(w, ";text-decoration:line-through");
    else if (vis.underline != UnderlineStyle.none)
    {
        const u = vis.underline == UnderlineStyle.dotted ? "dotted"
            : vis.underline == UnderlineStyle.curly ? "wavy"
            : vis.underline == UnderlineStyle.dashed ? "dashed" : "solid";
        put(w, ";text-decoration:underline ");
        put(w, u);
    }
    if (vis.border.any)
        borderStyle(w, vis);
}

/// `;padding:<t>em <r>ch <b>em <l>ch` from the widget's cell insets (horizontal in
/// `ch`, vertical in `em`, so the monospace grid reads faithfully).
private void padding(Writer)(ref Writer w, in Insets p)
{
    if ((p.top | p.right | p.bottom | p.left) == 0)
        return;
    put(w, ";padding:");
    num(w, p.top);
    put(w, "em ");
    num(w, p.right);
    put(w, "ch ");
    num(w, p.bottom);
    put(w, "em ");
    num(w, p.left);
    put(w, "ch");
}

/// `rgb(...)`/`rgba(...)` for an RGB color with 0-255 alpha (alpha omitted opaque).
private void rgba(Writer)(ref Writer w, in RgbColor c, ubyte alpha)
{
    if (alpha == 0xFF)
    {
        put(w, "rgb(");
        num(w, c.r);
        put(w, ",");
        num(w, c.g);
        put(w, ",");
        num(w, c.b);
        put(w, ")");
    }
    else
    {
        put(w, "rgba(");
        num(w, c.r);
        put(w, ",");
        num(w, c.g);
        put(w, ",");
        num(w, c.b);
        put(w, ",");
        // alpha as a 0..1 decimal with three places (255ths).
        const milli = (alpha * 1000 + 127) / 255;
        num(w, milli / 1000);
        put(w, ".");
        num3(w, milli % 1000);
        put(w, ")");
    }
}

/// Writes a non-negative int in base 10.
private void num(Writer)(ref Writer w, int v)
{
    if (v < 0)
    {
        put(w, "-");
        v = -v;
    }
    char[11] tmp;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    put(w, tmp[i .. $]);
}

/// Writes `v` (0..999) zero-padded to three digits (the rgba fractional part).
private void num3(Writer)(ref Writer w, int v)
{
    char[3] d = [
        cast(char)('0' + v / 100 % 10),
        cast(char)('0' + v / 10 % 10),
        cast(char)('0' + v % 10),
    ];
    put(w, d[]);
}

/// Escapes `&`, `<`, `>`, `"` for HTML text/attribute content.
private void escape(Writer)(ref Writer w, scope const(char)[] s)
{
    foreach (char c; s)
        switch (c)
        {
            case '&': put(w, "&amp;"); break;
            case '<': put(w, "&lt;"); break;
            case '>': put(w, "&gt;"); break;
            case '"': put(w, "&quot;"); break;
            default: put(w, c); break;
        }
}

// ---------------------------------------------------------------------------

@("ui.interp.html.popupChromeInlineStyles")
@safe unittest
{
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette,
        FontRole, TextStyle;
    import sparkles.ui.widget : Builder;
    import std.array : appender;
    import std.algorithm.searching : canFind;

    // A popup surface (border + radius + shadow + arrow) over a docs run (sans, 0.8em).
    auto b = Builder();
    const docs = b.add(Widget(kind: WidgetKind.text, text: "Wraps <T>.", slot: Slot.docs,
        textStyle: TextStyle(fontRole: FontRole.docs, fontScale: 80)));
    const popup = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface,
        padding: Insets.all(1), paintBackground: true, children: [docs],
        decoration: Decoration(borderWidth: Insets.all(1), borderStyle: BorderStyle.solid,
            borderRadius: 4, shadow: true, arrow: true, arrowOffset: 1)));
    auto tree = b.finish(popup);

    auto w = appender!string;
    renderWidgetHtml(w, tree, defaultTwoslashPalette(),
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));
    const s = w[];

    // Chrome from the palette: 1px border, 4px radius, the box-shadow, the arrow.
    assert(s.canFind("border-radius:4px"));
    assert(s.canFind("box-shadow:0px 1px 4px"));
    assert(s.canFind("border-top:1px solid"));
    assert(s.canFind("transform:rotate(-45deg)")); // the arrow
    // The surface background is opaque #f8f8f8.
    assert(s.canFind("background:rgb(248,248,248)"));
    // Docs run: sans face at 0.8em, muted color, HTML-escaped `<T>`.
    assert(s.canFind("font-family:sans-serif"));
    assert(s.canFind("font-size:80%"));
    assert(s.canFind("Wraps &lt;T&gt;."));
}

@("ui.interp.html.dottedHoverUnderlineAndPage")
@safe unittest
{
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette;
    import sparkles.ui.widget : Builder;
    import std.array : appender;
    import std.algorithm.searching : canFind;

    // The `.twoslash-hover` token: a bottom-only dotted border → a dotted bottom edge.
    auto b = Builder();
    const tok = b.add(Widget(kind: WidgetKind.box, slot: Slot.code,
        decoration: Decoration(borderWidth: Insets(0, 0, 1, 0),
            borderStyle: BorderStyle.dotted, borderSlot: Slot.code)));
    auto tree = b.finish(tok);

    auto w = appender!string;
    writeWidgetHtmlPage(w, tree, defaultTwoslashPalette(),
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff), "hover");
    const s = w[];

    assert(s.canFind("<!doctype html>"));
    assert(s.canFind("border-bottom:1px dotted"));
    assert(s.canFind("<title>hover</title>"));
}
