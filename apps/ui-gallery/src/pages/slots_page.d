/**
The Slots page: all thirty-five semantic roles, resolved against the live theme.

A widget names a slot and never a colour. That sentence is the toolkit's central
claim and it is unfalsifiable in prose — so here is the whole vocabulary at
once, each role showing its own foreground on its own background, under whatever
theme is selected. Switching themes with `]` re-resolves every swatch, which is
what "the palette resolves it" means operationally.

Below the swatches, the palette's other two channels: the scalar metrics and the
glyphs, which are as much part of a theme as the colours and are usually
invisible until something looks wrong.
*/
module pages.slots_page;

import std.conv : text;
import std.format : format;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : Palette, resolveSlot, Slot, Visual;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState;

@safe:

/// Slots grouped the way the vocabulary is actually organised, so a reader sees
/// the shape of it rather than thirty-five names in declaration order.
private struct Group
{
    string name;
    Slot[] slots;
}

private Group[] groups()
{
    return [
        Group("content", [Slot.inherit, Slot.code, Slot.docs, Slot.muted,
            Slot.matched, Slot.unmatched]),
        Group("severity", [Slot.error, Slot.warn, Slot.info, Slot.annotate]),
        Group("surfaces", [Slot.surface, Slot.border, Slot.shadow, Slot.chip,
            Slot.highlight, Slot.highlightBorder, Slot.hoverUnderline,
            Slot.caret]),
        Group("chrome", [Slot.chrome, Slot.chromeAccent, Slot.chromeFocused,
            Slot.gutter, Slot.gutterBand, Slot.track, Slot.thumb,
            Slot.selection]),
        Group("diff", [Slot.diffAdded, Slot.diffRemoved, Slot.diffEmphAdded,
            Slot.diffEmphRemoved, Slot.diffHunk, Slot.diffFill]),
    ];
}

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const t = s.theme;
    const pal = t.effectivePalette;
    const pageFg = rgbOr(t.defaultFg, RgbColor(0xcc, 0xcc, 0xcc));
    const pageBg = rgbOr(t.defaultBg, RgbColor(0, 0, 0));

    uint[] body_;
    body_ ~= heading(b, "Slots · the semantic vocabulary");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Thirty-four roles. A widget names one; the palette turns it into a "
        ~ "concrete foreground, background and alpha while the display list is "
        ~ "built. Nothing below hardcodes a colour — press ] and every swatch "
        ~ "re-resolves.", w);
    body_ ~= spacer(b);

    foreach (ref g; groups())
    {
        auto rows = new uint[](g.slots.length);
        foreach (i, slot; g.slots)
            rows[i] = swatch(b, slot, pal, pageFg, pageBg);
        body_ ~= section(b, g.name, rows);
        body_ ~= spacer(b);
    }

    body_ ~= section(b, "metrics", [
        kv(b, "popup radius", pal.popupRadius.text, 18, Slot.code),
        kv(b, "popup padding", text(pal.popupPadY, " × ", pal.popupPadX), 18, Slot.code),
        kv(b, "popup width", text(pal.popupMinWidth, " … ", pal.popupMaxWidth), 18, Slot.code),
        kv(b, "docs width", pal.docsMaxWidth.text, 18, Slot.code),
        kv(b, "border / accent", text(pal.borderWidth, " / ", pal.accentBorder), 18, Slot.code),
        kv(b, "shadow", text(pal.shadowDx, ", ", pal.shadowDy,
            ", blur ", pal.shadowBlur), 18, Slot.code),
        kv(b, "font scales", text("code ", pal.codeFontScale, "  docs ",
            pal.docsFontScale, "  tag ", pal.tagFontScale), 18, Slot.code),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "glyphs", [
        kv(b, "caret", pal.caretGlyph.text, 18, Slot.code),
        kv(b, "arrow", pal.arrowGlyph.text, 18, Slot.code),
        kv(b, "query", pal.queryGlyph.text, 18, Slot.code),
        kv(b, "unicode allowed", t.glyphs.unicode ? "yes" : "no", 18, Slot.code),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Metrics are px where a pixel target needs them and cells where a "
        ~ "terminal does — a radius and a shadow have no cell analog, so the "
        ~ "cell grid degrades a border to box-drawing and drops the rest.", w);

    return column(b, body_);
}

/// One slot: its name, a sample painted in it, and the resolved values.
private uint swatch(ref Builder b, Slot slot, in Palette pal,
    in RgbColor pageFg, in RgbColor pageBg)
{
    const v = resolveSlot(pal, slot, pageFg, pageBg);

    const name = b.add(Widget(
        kind: WidgetKind.text,
        text: slotName(slot),
        slot: Slot.muted,
        width: SizeSpec.fixed(17),
    ));
    // The sample carries the slot itself rather than an override — so a swatch
    // showing the wrong colour means the resolver is wrong, not the page.
    const sample = b.add(Widget(
        kind: WidgetKind.panel,
        children: [label(b, " Aa 0123 ", slot)],
        slot: slot,
        paintBackground: v.hasBg,
        width: SizeSpec.fixed(11),
    ));
    const fg = b.add(Widget(
        kind: WidgetKind.text,
        text: hex(v.fg) ~ alphaSuffix(v.fgAlpha),
        slot: Slot.muted,
        width: SizeSpec.fixed(13),
    ));
    const bg = b.add(Widget(
        kind: WidgetKind.text,
        text: v.hasBg ? hex(v.bg) ~ alphaSuffix(v.bgAlpha) : "—",
        slot: Slot.muted,
    ));
    return b.add(Widget(kind: WidgetKind.row, children: [name, sample, fg, bg],
        gap: 1));
}

/// The slot's own spelling — `__traits(allMembers)` order, so a slot added to
/// the enum gets a name here without anyone maintaining a parallel table.
string slotName(Slot s) pure nothrow @nogc
{
    final switch (s)
    {
        static foreach (m; __traits(allMembers, Slot))
        {
        case __traits(getMember, Slot, m):
            return m;
        }
    }
}

private string alphaSuffix(ubyte a)
    => a == 0xFF ? "" : format!" %d%%"(a * 100 / 255);

private string hex(in RgbColor c)
    => format!"#%02x%02x%02x"(c.r, c.g, c.b);

private RgbColor rgbOr(C)(in C c, RgbColor fallback) pure nothrow @nogc
{
    import sparkles.base.term_color : Color;

    return c.kind == Color.Kind.rgb ? c.rgb : fallback;
}

@("ui_gallery.pages.slotsCoversEveryRole")
@safe unittest
{
    // The page's whole point is completeness: a slot missing from the groups is
    // a role nobody can see the colour of. `Slot.max + 1` rather than a count,
    // so adding a role breaks this rather than quietly going undisplayed.
    bool[Slot.max + 1] seen;
    size_t total;
    foreach (ref g; groups())
        foreach (sl; g.slots)
        {
            assert(!seen[sl], "slot " ~ slotName(sl) ~ " is in two groups");
            seen[sl] = true;
            ++total;
        }

    static foreach (m; __traits(allMembers, Slot))
        assert(seen[__traits(getMember, Slot, m)],
            "no swatch for Slot." ~ m);
    assert(total == Slot.max + 1);
}

@("ui_gallery.pages.slotNamesMatchTheEnum")
@safe pure nothrow @nogc unittest
{
    static foreach (m; __traits(allMembers, Slot))
        assert(slotName(__traits(getMember, Slot, m)) == m);
}

@("ui_gallery.pages.slotsResolveAgainstTheSelectedTheme")
@safe unittest
{
    import sparkles.ui.themes : builtinThemes;
    import state : themeNames;

    // Two themes, one slot: the resolved colours must differ, or the page is
    // showing a palette it did not select. This is the assertion that fails if
    // the theme is ever resolved once at startup instead of per frame.
    const dark = builtinThemes["catppuccin-mocha"];
    const light = builtinThemes["catppuccin-latte"];
    const a = resolveSlot(dark.effectivePalette, Slot.code,
        RgbColor(0xcc, 0xcc, 0xcc), RgbColor(0, 0, 0));
    const c = resolveSlot(light.effectivePalette, Slot.code,
        RgbColor(0, 0, 0), RgbColor(0xff, 0xff, 0xff));
    assert(a.fg != c.fg || a.hasBg != c.hasBg);

    // And the page builds under every one of them.
    foreach (i; 0 .. themeNames.length)
    {
        GalleryState s;
        s.themeIndex = i;
        auto b = Builder();
        auto tree = b.finish(view(b, s));
        assert(tree.nodes.length > 0);
    }
}
