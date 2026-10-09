/**
The $(B first-class) HTML mode of $(MREF sparkles,ui) (`TGT4`): semantic class
names + an external stylesheet, instead of per-node inline styles — so a page
of widgets is themable by swapping one `<style>`, diffs read as structure
rather than color soup, and tier-0 interactivity (hover-reveal, disclosure) is
$(B pure CSS) with no script.

Three functions, one contract (design-system `WEB4`):

$(LIST
    * $(LREF writeSlotRules) — the structural base classes, the tier-0
        interaction rules, and one rule per $(REF Slot, sparkles,ui,style)
        named by its token path (`.spk-text-muted`) that reads the slot's
        design-system properties (`var(--spk-text-muted-fg)`). It names no
        color, so it is the same for every theme.
    * $(LREF writeSlotStylesheet) — a theme's properties
        ($(REF writeThemeProperties, sparkles,ui,css)) and those rules: what a
        page with no other stylesheet links. A page that already carries the
        properties, as the docs site does, needs the rules alone.
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
import sparkles.ui.css : writeThemeProperties;
import sparkles.ui.style : InteractionState, Slot;
import sparkles.ui.theme : Theme;
import sparkles.ui.widget : Alignment, Visibility, Widget, WidgetKind, WidgetTree;
import sparkles.ui.tokens : ColorChannel, TargetCapabilities, tokenPath, writeCssName;
import sparkles.ui.wrap : TextWrap;

@safe:

/**
What the semantic HTML target declares (`CAP1`): narrower than the inline
writer's $(REF htmlCapabilities, sparkles,ui,interp,html), because the slot
stylesheet carries only colors — with their alpha — and one monospace face.
Box chrome, text sizing and link targets arrive with the design system's
generated stylesheet (`WEB1`–`WEB6`), which widens this declaration as it
lands.
*/
enum TargetCapabilities semanticHtmlCapabilities = () {
    import sparkles.base.term_color : ColorDepth;
    import sparkles.input.capability : staticPointer;

    TargetCapabilities c;
    c.colorDepth = ColorDepth.trueColor;
    c.unicode = true;
    c.graphemeClusters = true;
    c.subCellScroll = true;
    c.alpha = true;
    c.input = staticPointer;
    return c;
}();

/**
Writes the rules (`WEB4`): the structural base classes (`.spk`, `.spk-row`,
…), the tier-0 interaction rules (`.spk-hit:hover > .spk-reveal`, `<details>`
disclosure), and per slot a class named by its token path whose colors are the
slot's design-system properties. A hit target's hover reads the slot's
`-hover-` property, falling back to the rest value (D60). Nothing here depends
on a theme: the properties carry the values.
*/
void writeSlotRules(Writer)(ref Writer w)
if (isOutputRange!(Writer, char))
{
    // Structural base classes: one per widget kind, plus clip/visibility.
    put(w, ".spk{box-sizing:border-box}"
        ~ ".spk-text,.spk-rich,.spk-glyph{white-space:pre;"
        ~ "font-family:var(--spk-font-code,ui-monospace,monospace)}"
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

    // One rule per slot, reading its properties. A channel the theme leaves
    // unset has no property, so the declaration falls back: the color
    // inherits and the background stays transparent, as in every other target.
    foreach (slot; Slot.min .. Slot.max + 1)
    {
        const s = cast(Slot) slot;
        if (s == Slot.inherit)
            continue;
        put(w, ".");
        writeSlotClass(w, s);
        put(w, "{color:var(");
        writeCssName(w, s, ColorChannel.foreground);
        put(w, ");background-color:var(");
        writeCssName(w, s, ColorChannel.background);
        put(w, ")}");

        put(w, ".spk-hit.");
        writeSlotClass(w, s);
        put(w, ":hover{color:var(");
        writeCssName(w, s, ColorChannel.foreground, InteractionState.hover);
        put(w, ",var(");
        writeCssName(w, s, ColorChannel.foreground);
        put(w, "));background-color:var(");
        writeCssName(w, s, ColorChannel.background, InteractionState.hover);
        put(w, ",var(");
        writeCssName(w, s, ColorChannel.background);
        put(w, "))}");
    }
}

/**
The whole stylesheet for a page that links nothing else: `theme`'s
design-system properties on `:root`, then $(LREF writeSlotRules). Swap the
theme, re-emit this one block, and every page themed by it follows.
*/
void writeSlotStylesheet(Writer)(ref Writer w, const Theme theme)
if (isOutputRange!(Writer, char))
{
    put(w, ":root{\n");
    writeThemeProperties(w, theme);
    put(w, "}\n");
    writeSlotRules(w);
}

/// The class of a slot (`WEB4`): `spk-` and its token path, `.` → `-`.
private void writeSlotClass(Writer)(ref Writer w, Slot s)
{
    put(w, "spk-");
    foreach (c; tokenPath(s))
        put(w, c == '.' ? '-' : c);
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
        put(w, " ");
        writeSlotClass(w, node.slot);
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
                    put(w, " class=\"");
                    writeSlotClass(w, span.slot);
                    put(w, "\"");
                }
                put(w, ">");
                escape(w, span.text);
                put(w, "</span>");
            }
            break;
        case glyph:
            char[4] enc;
            import sparkles.base.text.utf : encodeScalar, UtfStatus;

            const encoded = encodeScalar(node.glyph, enc[]);
            if (encoded.status != UtfStatus.ok)
                throw new Exception("Invalid Unicode widget glyph");
            const n = encoded.written;
            escape(w, enc[0 .. n]);
            break;
        case image:
            // The same `IMG4` placeholder every other target shows: this
            // module has no image encoder, so there is no `src` to emit and
            // an `<img>` without one is a broken image rather than a
            // degradation.
            if (node.text.length)
            {
                put(w, "[");
                escape(w, node.text);
                put(w, "]");
            }
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
    import sparkles.base.buffer : SharedBuffer;
    import std.array : appender;

    auto w = appender!string;
    writeSlotRules(w);
    const css = w[];

    // Every slot (except inherit) has a rule named by its token path that reads
    // its properties, and a hover that falls back to the rest value (D60).
    assert(css.canFind(".spk-text-muted{color:var(--spk-text-muted-fg);"
        ~ "background-color:var(--spk-text-muted-bg)}"), css);
    assert(css.canFind(".spk-hit.spk-scrollbar-thumb:hover{color:var("
        ~ "--spk-scrollbar-thumb-hover-fg,var(--spk-scrollbar-thumb-fg))"), css);
    foreach (slot; Slot.min + 1 .. Slot.max + 1)
    {
        auto c = appender!string;
        writeSlotClass(c, cast(Slot) slot);
        assert(css.canFind("." ~ c[] ~ "{color:var("), c[]);
    }
    assert(css.canFind(".spk-hit:hover>.spk-reveal{display:block}"));
    assert(css.canFind("details.spk-disclosure>summary"));
    // The rules name no color: every value is a property.
    assert(!css.canFind("#") && !css.canFind("rgb"), css);
}

@("ui.interp.html_semantic.stylesheetCarriesTheThemesProperties")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import sparkles.ui.themes : builtinThemes;

    auto w = appender!string;
    writeSlotStylesheet(w, builtinThemes["github-dark"]);
    assert(w[].canFind(":root{\n  --spk-"), w[]);
    assert(w[].canFind("--spk-text-muted-fg: #"), w[]);
    assert(w[].canFind(".spk-text-muted{color:var(--spk-text-muted-fg)"), w[]);
}

@("ui.interp.html_semantic.slotClassesNeverCollideWithKindClasses")
@safe unittest
{
    import std.array : appender;
    import std.traits : EnumMembers;

    // A one-segment slot path (link, gutter, selection) must not name a
    // widget kind's class, or a node's kind would paint its slot's colors.
    foreach (slot; Slot.min + 1 .. Slot.max + 1)
    {
        auto c = appender!string;
        writeSlotClass(c, cast(Slot) slot);
        static foreach (k; EnumMembers!WidgetKind)
            assert(c[] != "spk-" ~ k.to!string, c[]);
    }
}

@("ui.interp.html_semantic.markupIsClassesNotColors")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.ui.widget : Builder, TextSpan;

    auto b = Builder();
    Widget sig = Widget(kind: WidgetKind.rich, slot: Slot.code, hitId: 3,
        spans: [TextSpan("const", Slot.docs), TextSpan(" x")]);
    const t = b.add(sig);
    const popup = b.container(WidgetKind.popup, [t],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(popup);

    SharedBuffer!(char, 1024) w;
    renderWidgetHtmlClasses(w, tree);
    const html = w[];

    // Classes are token paths (`WEB4`): `surface.overlay` → `spk-surface-overlay`.
    assert(html.canFind(`<div class="spk spk-popup spk-surface-overlay"`));
    assert(html.canFind(`<span class="spk spk-rich spk-text-code spk-hit"`));
    assert(html.canFind(`<span class="spk-text-docs">const</span>`));
    assert(html.canFind("padding:1lh 1ch 1lh 1ch"));
    // The whole point: not one color in the markup.
    assert(!html.canFind("rgba(") && !html.canFind("color:"));
}
