/**
The Decoration page: box chrome and text chrome, and what each target can
actually express.

`Decoration` and `TextStyle` are authored in CSS terms — px widths, a radius, a
blur — because that is where they came from and a reviewer can read them against
the stylesheet. A cell grid has no sub-cell edge, so it degrades: any non-zero
border becomes box-drawing, a rounded one picks the rounded corners, and radius
and shadow are simply not expressible. That degradation is the interesting part
of the page, and it is stated beside each specimen rather than left to be
noticed later.
*/
module pages.decoration_page;

import sparkles.base.term_style : UnderlineStyle;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState;

@safe:

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] boxes;
    boxes ~= specimen(b, "solid", box(b, Decoration(
        borderWidth: Insets.all(1),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
    )), 14);
    boxes ~= specimen(b, "rounded", box(b, Decoration(
        borderWidth: Insets.all(1),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
        borderRadius: 4,
    )), 14);
    boxes ~= specimen(b, "dotted", box(b, Decoration(
        borderWidth: Insets.all(1),
        borderStyle: BorderStyle.dotted,
        borderSlot: Slot.hoverUnderline,
    )), 14);
    boxes ~= specimen(b, "dashed", box(b, Decoration(
        borderWidth: Insets.all(1),
        borderStyle: BorderStyle.dashed,
        borderSlot: Slot.muted,
    )), 14);
    boxes ~= specimen(b, "bottom only", box(b, Decoration(
        borderWidth: Insets(0, 0, 1, 0),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
    )), 14);
    boxes ~= specimen(b, "left accent", box(b, Decoration(
        borderWidth: Insets(0, 0, 0, 3),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.error,
    )), 14);
    boxes ~= specimen(b, "with shadow", box(b, Decoration(
        borderWidth: Insets.all(1),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
        borderRadius: 4,
        shadow: true,
    )), 14);
    // A one-row box with a solid bottom border is a special case, not a
    // smaller version of the one above it: the cell grid renders it as a rule
    // of `─` rather than as an underline, because that is how a thematic break
    // is spelled. Shown as its own specimen, since the first draft of this
    // page reached the case by accident — it gave the bottom-only box no
    // vertical padding, and its content came out struck through by its own
    // border.
    boxes ~= specimen(b, "rule (1 row)", b.add(Widget(
        kind: WidgetKind.box,
        slot: Slot.border,
        width: SizeSpec.fixed(13),
        height: SizeSpec.fixed(1),
        decoration: Decoration(
            borderWidth: Insets(0, 0, 1, 0),
            borderStyle: BorderStyle.solid,
            borderSlot: Slot.border,
        ),
    )), 14);

    uint[] runs;
    runs ~= specimen(b, "plain", label(b, "The quick brown fox", Slot.code), 14);
    runs ~= specimen(b, "bold", label(b, "The quick brown fox", Slot.code,
        TextStyle(bold: true)), 14);
    runs ~= specimen(b, "italic", label(b, "The quick brown fox", Slot.code,
        TextStyle(italic: true)), 14);
    runs ~= specimen(b, "bold italic", label(b, "The quick brown fox", Slot.code,
        TextStyle(bold: true, italic: true)), 14);
    runs ~= specimen(b, "strikethrough", label(b, "The quick brown fox", Slot.code,
        TextStyle(strikethrough: true)), 14);
    runs ~= specimen(b, "underline", label(b, "The quick brown fox", Slot.code,
        TextStyle(underline: UnderlineStyle.single)), 14);
    runs ~= specimen(b, "double", label(b, "The quick brown fox", Slot.code,
        TextStyle(underline: UnderlineStyle.double_)), 14);
    runs ~= specimen(b, "curly", label(b, "The quick brown fox", Slot.error,
        TextStyle(underline: UnderlineStyle.curly)), 14);
    runs ~= specimen(b, "dotted", label(b, "The quick brown fox", Slot.code,
        TextStyle(underline: UnderlineStyle.dotted)), 14);
    runs ~= specimen(b, "dashed", label(b, "The quick brown fox", Slot.code,
        TextStyle(underline: UnderlineStyle.dashed)), 14);

    uint[] body_;
    body_ ~= heading(b, "Decoration · box and text chrome");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A decoration is slot-referencing and presentation-free: it names which "
        ~ "slot the border colour comes from, and the palette resolves it with "
        ~ "everything else.", w);
    body_ ~= spacer(b);
    body_ ~= section(b, "borders", boxes, gap: 1);
    body_ ~= spacer(b);
    body_ ~= section(b, "text style", runs);
    body_ ~= spacer(b);
    body_ ~= section(b, "what a cell grid can express", [
        kv(b, "border sides", "box-drawing glyphs on the perimeter", 15, Slot.docs),
        kv(b, "solid/dashed/dotted", "─ ╌ ┈ and │ ╎ ┊ — all three differ", 15, Slot.docs),
        kv(b, "corners", "always solid; rounded when a radius is set", 15, Slot.docs),
        kv(b, "left accent", "the quote bar — │, heavy ┃ at 2+ wide", 15, Slot.docs),
        kv(b, "right accent", "an eighth-block, weighted by the px width", 15, Slot.docs),
        kv(b, "bottom only", "an underline; a rule on a one-row box", 15, Slot.docs),
        kv(b, "underline", "SGR 4:x, including the curly variant", 15, Slot.docs),
        kv(b, "bold/italic", "SGR 1 / 3, or a real styled face in a window", 15, Slot.docs),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "what it cannot", [
        kv(b, "radius value", "only its presence survives, as round corners", 15, Slot.docs),
        kv(b, "shadow", "no cell analog — dropped, so the box above looks "
            ~ "exactly like the rounded one here", 15, Slot.docs),
        kv(b, "top only", "a cell has an underline attribute and no overline", 15, Slot.docs),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Two of those lines used to be four. Dashed and dotted borders drew "
        ~ "with the solid glyphs, and a single-side accent dropped entirely — "
        ~ "both of which this page made obvious by putting the specimens side "
        ~ "by side, and neither of which the cell grid actually needed to give "
        ~ "up. Box-drawing carries dash runs in both axes; a left accent is "
        ~ "the quote bar the markdown goldens pin, and the eighth-blocks "
        ~ "weight a right one.", w);

    return column(b, body_);
}

/// A small labelled box carrying `d`.
///
/// Every specimen is the same three rows, whatever sides its border has. The
/// first draft varied the vertical padding with the border, which made the
/// bottom-only box one row tall — and a one-row box with a solid bottom border
/// is a $(I thematic break) to the cell grid, so the specimen came out as a
/// rule drawn straight through the word "content". One shape for all of them
/// keeps the comparison about the border and nothing else.
private uint box(ref Builder b, Decoration d)
    => b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(
            kind: WidgetKind.column,
            children: [label(b, "content", Slot.code)],
        ))],
        slot: Slot.surface,
        padding: Insets.symmetric(1, 2),
        width: SizeSpec.fixed(13),
        decoration: d,
    ));

@("ui_gallery.pages.decorationCoversEveryBorderAndUnderlineStyle")
@safe unittest
{
    // Both vocabularies, in full. A style added to either and not shown here is
    // one nobody can see — which is the only failure mode a catalog has.
    auto b = Builder();
    auto tree = b.finish(view(b, GalleryState.init));

    bool[BorderStyle.max + 1] borders;
    bool[UnderlineStyle.max + 1] underlines;
    foreach (ref n; tree.nodes)
    {
        if (n.decoration.borderStyle != BorderStyle.none
            || n.decoration.borderWidth.top != 0)
            borders[n.decoration.borderStyle] = true;
        if (n.kind == WidgetKind.text)
            underlines[n.textStyle.underline] = true;
    }
    // `none` is the default and appears on every undecorated node.
    borders[BorderStyle.none] = true;

    static foreach (m; __traits(allMembers, BorderStyle))
        assert(borders[__traits(getMember, BorderStyle, m)],
            "no specimen for BorderStyle." ~ m);
    static foreach (m; __traits(allMembers, UnderlineStyle))
        assert(underlines[__traits(getMember, UnderlineStyle, m)],
            "no specimen for UnderlineStyle." ~ m);
}

@("ui_gallery.pages.decorationCoversEveryTextFlag")
@safe unittest
{
    auto b = Builder();
    auto tree = b.finish(view(b, GalleryState.init));

    bool bold, italic, both, strike;
    foreach (ref n; tree.nodes)
    {
        const t = n.textStyle;
        bold |= t.bold && !t.italic;
        italic |= t.italic && !t.bold;
        both |= t.bold && t.italic;
        strike |= t.strikethrough;
    }
    assert(bold && italic && both && strike);
}
