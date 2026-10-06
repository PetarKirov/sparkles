/**
What opens the tab and pane tree (`TSS13`, `ui.tabsOpener`, mockup E):

$(LIST
    * the $(B pill) — a band along the top with one pill naming the current
        tab, its position among the tabs and the unseen count; a tap opens
        the tree below it;
    * the $(B rail) — a narrow column down the left edge: the tree button,
        one button per tab (its icon; the current one marked with a bar as
        well as a colour), and a new-tab button.
)

Neither reacts to a swipe: the screen edges belong to the system's Back
gesture (D42).
*/
module opener;

import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : label, uiLabel;
import settings : TabsOpener;
import tab_tree : TreeTab;

/// The opener's targets.
enum OpenerHit : size_t
{
    none,
    tree = 0x0BE0_0000, /// open (or close) the tree
    newTab,
    guide, /// the touch key guide (`TSS16`)
    tab0 = 0x0BE0_0100, /// `tab0 + i` selects tab `i`
}

/// Which opener applies: the setting, with `auto` a pill on a phone in
/// portrait and a rail otherwise (`TCF12`).
bool usesPill(TabsOpener setting, bool phonePortrait) @safe pure nothrow @nogc
    => setting == TabsOpener.pill || (setting == TabsOpener.automatic && phonePortrait);

// `id` filling its parent and centred in it.
private uint centred_(ref Builder b, uint id) @safe
{
    b.nodes[id].alignX = Alignment.center;
    b.nodes[id].width = SizeSpec.grow();
    return id;
}

// `id` as tall as its row allows.
private uint tall(ref Builder b, uint id) @safe
{
    b.nodes[id].height = SizeSpec.grow();
    return id;
}

/**
The pill band, `rows` tall: `❯ title  2/4  ●1 ▾` centred on a phone, at the
start on the desktop with `hint` (the key that opens the tree) beside it. `guide`
adds the touch guide's `⋯` after the pill (`TSS16`).
*/
WidgetTree pillBand(in TreeTab[] tabs, int rows, bool centred, string hint,
    bool guide = false) @safe
{
    import std.conv : text;

    Builder b;
    size_t current, unread;
    foreach (i, ref t; tabs)
    {
        if (t.current)
            current = i;
        unread += t.unread;
    }
    // The icon and the count are data, the tab's name is words (D50). Each
    // part fills the band's rows, so the canvas centres its glyphs in them
    // in pixels rather than on a whole row.
    uint[] parts;
    if (tabs.length)
        parts ~= [tall(b, label(b, tabs[current].icon, Slot.textPrimary)),
            tall(b, uiLabel(b, tabs[current].title, Slot.textPrimary, bold: true))];
    parts ~= tall(b, label(b, text(current + 1, "/", tabs.length), Slot.muted));
    if (unread)
        parts ~= tall(b, label(b, text("●", unread), Slot.warn));
    parts ~= tall(b, label(b, "▾", Slot.muted));
    // The pill and ⋯ take the band's whole height — their targets — and draw
    // a compact box centred in it (`TOK11`).
    enum pillDp = 36;
    const pill = b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
        padding: Insets(0, 2, 0, 2), alignY: Alignment.center,
        height: SizeSpec.fixed(rows),
        slot: Slot.surfaceRaised, paintBackground: true,
        decoration: Decoration(borderRadius: pillDp / 2, drawHeight: pillDp),
        hitId: OpenerHit.tree));
    uint[] band = [pill];
    if (!centred && hint.length)
        band ~= tall(b, label(b, hint, Slot.muted));
    // On touch, the guide's button beside the pill (`TSS16`, D46): the way
    // to every command while a keyboard cover hides the extra keys.
    if (guide)
        band ~= b.add(Widget(kind: WidgetKind.row,
            children: [tall(b, centred_(b, label(b, "⋯", Slot.textPrimary)))],
            padding: Insets(0, 2, 0, 2), alignX: Alignment.center, alignY: Alignment.center,
            height: SizeSpec.fixed(rows),
            slot: Slot.surfaceRaised, paintBackground: true,
            decoration: Decoration(borderRadius: pillDp / 2, drawHeight: pillDp),
            hitId: OpenerHit.guide));
    // An opaque band, so the pill and ⋯ stand apart from the terminal output
    // below them (the E mockups' band). The host draws its rule, in pixels.
    return b.finish(b.add(Widget(kind: WidgetKind.row, children: band, gap: 2,
        padding: Insets(0, 1, 0, 1), width: SizeSpec.grow(), height: SizeSpec.fixed(rows),
        alignX: centred ? Alignment.center : Alignment.start, alignY: Alignment.center,
        slot: Slot.surfaceSunken, paintBackground: true)));
}

/// The rail, `cols` wide and `rows` tall, each button `buttonRows` tall;
/// `guide` adds the touch guide's `⋯` under `☰` (`TSS16`).
WidgetTree rail(in TreeTab[] tabs, int cols, int rows, int buttonRows, bool guide = false) @safe
{
    Builder b;

    uint button(string glyph, Slot slot, size_t hit, bool current = false, bool unread = false)
    {
        uint[] kids = [b.add(Widget(kind: WidgetKind.text, text: glyph, slot: slot,
            textStyle: TextStyle(bold: current)))];
        if (unread)
            kids ~= label(b, "●", Slot.warn);
        return b.add(Widget(kind: WidgetKind.row, children: kids,
            width: SizeSpec.fixed(cols), height: SizeSpec.fixed(buttonRows),
            alignX: Alignment.center, alignY: Alignment.center, hitId: hit,
            slot: current ? Slot.surfaceBase : Slot.chrome, paintBackground: current,
            // The current tab's bar: a mark that is not colour alone (`ACC3`).
            decoration: current ? Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets(0, 0, 0, 3),
                borderSlot: Slot.accentPrimary) : Decoration.init));
    }

    uint[] items = [button("☰", Slot.accentPrimary, OpenerHit.tree)];
    if (guide) // the touch guide, under the tree (`TSS16`)
        items ~= button("⋯", Slot.textPrimary, OpenerHit.guide);
    foreach (i, ref t; tabs)
    {
        if ((items.length + 2) * buttonRows > rows)
            break;
        items ~= button(t.icon.length ? t.icon : "❯", t.current ? Slot.accentPrimary : Slot.muted,
            OpenerHit.tab0 + i, t.current, t.unread != 0);
    }
    items ~= button("+", Slot.muted, OpenerHit.newTab);
    return b.finish(b.add(Widget(kind: WidgetKind.column, children: items,
        width: SizeSpec.fixed(cols), height: SizeSpec.fixed(rows),
        slot: Slot.chrome, paintBackground: true)));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private TreeTab[] two() @safe => [TreeTab("~/sparkles", "❯", 0, true),
        TreeTab("build", "▶", 2, false)];
}

@("opener.usesPill.autoIsAPillOnlyInPortrait")
@safe pure nothrow @nogc unittest
{
    assert(usesPill(TabsOpener.automatic, phonePortrait: true));
    assert(!usesPill(TabsOpener.automatic, phonePortrait: false));
    assert(usesPill(TabsOpener.pill, phonePortrait: false));
    assert(!usesPill(TabsOpener.rail, phonePortrait: true));
}

@("opener.pillBand.namesTheTabItsPlaceAndUnseen")
@safe unittest
{
    import std.algorithm.searching : canFind;

    import chrome : place, Place;

    const l = place(pillBand(two(), 2, true, null), 40, 2, 0, 0, 1, 1, Place.top);
    const(char)[][] texts;
    foreach (ref n; l.tree.nodes)
        texts ~= n.text;
    assert(texts.canFind("❯") && texts.canFind("~/sparkles") && texts.canFind("1/2") && texts.canFind("●2"));
    assert(l.hitAt(20, 0) == OpenerHit.tree, "the pill is the target");
}

@("opener.rail.treeTabsAndNewTab")
@safe unittest
{
    import chrome : place, Place;

    const l = place(rail(two(), 4, 20, 2), 4, 20, 0, 0, 1, 1, Place.top);
    assert(l.hitAt(1, 0) == OpenerHit.tree);
    assert(l.hitAt(1, 2) == OpenerHit.tab0);
    assert(l.hitAt(1, 4) == OpenerHit.tab0 + 1);
    assert(l.hitAt(1, 6) == OpenerHit.newTab);
}

@("opener.guide.onTouchOnly")
@safe unittest
{
    import chrome : place, Place;

    // `TSS16`: the rail's `⋯` under `☰`, the pill band's after the pill; neither
    // without `guide` (the desktop).
    const r = place(rail(two(), 4, 20, 2, guide: true), 4, 20, 0, 0, 1, 1, Place.top);
    assert(r.hitAt(1, 0) == OpenerHit.tree && r.hitAt(1, 2) == OpenerHit.guide);
    assert(r.hitAt(1, 4) == OpenerHit.tab0, "the tabs follow");
    const p = place(pillBand(two(), 2, true, null, guide: true), 40, 2, 0, 0, 1, 1, Place.top);
    bool sawGuide;
    foreach (ref t; p.hits)
        sawGuide |= t.hitId == OpenerHit.guide;
    assert(sawGuide);
    foreach (ref t; place(rail(two(), 4, 20, 2), 4, 20, 0, 0, 1, 1, Place.top).hits)
        assert(t.hitId != OpenerHit.guide);
}
