/**
The Themes page: all thirty-six built-ins, and a scene that repaints in the one
you pick.

This is the page the component's `theme` member exists for. Every slot in the
whole gallery — the header band, the sidebar, this list — resolves against the
selected theme, so choosing one is not a preview inside a box: the application
changes colour around you. A theme resolved once at startup could not do that,
which is why the shell declares its own rather than taking the run's.
*/
module pages.themes_page;

import std.conv : text;

import sparkles.base.term_color : Color, RgbColor;
import sparkles.ui.geometry : Insets, SizeSpec;
import sparkles.ui.style : ColorScheme, schemeForBackground, Slot, TextStyle;
import sparkles.ui.themes : builtinThemes;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;

import kit;
import state : GalleryState, hitTheme, themeNames;

@safe:

/// ditto
static immutable string[] keys = ["[ ] cycle", "click a name"];

/// How many names the list shows at once before it starts following the
/// selection. Thirty-six rows would push everything else off the page.
private enum int listRows = 12;

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const t = s.theme;

    uint[] body_;
    body_ ~= heading(b, "Themes · thirty-six built-ins");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A theme is one runtime-swappable value with four channels: syntax "
        ~ "rules, the slot palette, scalar metrics, and glyphs. Press ] and "
        ~ "watch the whole window follow — nothing here is a preview pane.", w);
    body_ ~= spacer(b);

    body_ ~= row(b, [
        label(b, "selected", Slot.muted),
        label(b, t.name, Slot.chromeAccent, TextStyle(bold: true)),
        label(b, text("(", s.themeIndex + 1, " of ", themeNames.length, ")"),
            Slot.muted),
        label(b, schemeForBackground(bgOf(t.defaultBg)) == ColorScheme.dark
            ? "dark" : "light", Slot.info),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "the catalog", [nameList(b, s)]);
    body_ ~= spacer(b);
    body_ ~= section(b, "a scene, in this theme", [scene(b)]);
    body_ ~= spacer(b);
    body_ ~= section(b, "channels", [
        kv(b, "syntax rules", text(t.rules.length, " selectors"), 16, Slot.code),
        kv(b, "palette", t.hasPalette
            ? "authored by the theme"
            : "derived from the background", 16, Slot.code),
        kv(b, "unicode glyphs", t.glyphs.unicode ? "yes" : "no", 16, Slot.code),
        kv(b, "page fg / bg", text(hex(bgOf(t.defaultFg)), "  ",
            hex(bgOf(t.defaultBg))), 16, Slot.code),
    ]);

    return column(b, body_);
}

/// The visible window of the name list, following the selection.
private uint nameList(ref Builder b, in GalleryState s)
{
    const first = windowStart(s.themeIndex, themeNames.length, listRows);
    auto rows = new uint[](listRows);
    foreach (i; 0 .. listRows)
    {
        const at = first + i;
        const selected = at == s.themeIndex;
        const id = hitTheme + at;
        const hot = s.pointerAffordances && s.hover.isHot(id);
        const marker = label(b, selected ? "▸ " : "  ",
            selected ? Slot.chromeAccent : Slot.muted);
        const name = label(b, themeNames[at],
            selected ? Slot.chromeAccent : (hot ? Slot.code : Slot.muted),
            TextStyle(bold: selected));
        rows[i] = b.add(Widget(
            kind: WidgetKind.row,
            children: [marker, name],
            width: SizeSpec.grow(),
            hitId: id,
            slot: selected ? Slot.selection : Slot.inherit,
            paintBackground: selected,
        ));
    }
    return b.add(Widget(kind: WidgetKind.column, children: rows,
        width: SizeSpec.grow()));
}

/**
The first row a `rows`-tall window shows when `selected` must be inside it.

Clamped at both ends, so the list does not scroll past its own start or leave a
gap under its last entry — the two off-by-ones every hand-rolled window has.
*/
size_t windowStart(size_t selected, size_t count, int rows) pure nothrow @nogc
{
    if (count <= rows)
        return 0;
    const half = rows / 2;
    if (selected < half)
        return 0;
    const last = count - rows;
    const want = selected - half;
    return want > last ? last : want;
}

/// A small scene exercising the slots a reader will actually judge a theme by.
private uint scene(ref Builder b)
{
    uint[] rows;
    rows ~= row(b, [
        label(b, "error", Slot.error),
        label(b, "warn", Slot.warn),
        label(b, "info", Slot.info),
        label(b, "muted", Slot.muted),
        label(b, "code", Slot.code),
        label(b, "docs", Slot.docs),
    ]);
    rows ~= b.add(Widget(
        kind: WidgetKind.row,
        children: [
            b.add(Widget(
                kind: WidgetKind.panel,
                children: [label(b, "chrome band", Slot.chromeAccent)],
                slot: Slot.chrome,
                padding: Insets.symmetric(0, 1),
                paintBackground: true,
            )),
            b.add(Widget(
                kind: WidgetKind.panel,
                children: [label(b, "focused", Slot.chromeAccent)],
                slot: Slot.chromeFocused,
                padding: Insets.symmetric(0, 1),
                paintBackground: true,
            )),
            b.add(Widget(
                kind: WidgetKind.panel,
                children: [label(b, "selection", Slot.code)],
                slot: Slot.selection,
                padding: Insets.symmetric(0, 1),
                paintBackground: true,
            )),
            b.add(Widget(
                kind: WidgetKind.panel,
                children: [label(b, "chip", Slot.muted)],
                slot: Slot.chip,
                padding: Insets.symmetric(0, 1),
                paintBackground: true,
            )),
        ],
        gap: 1,
    ));
    rows ~= row(b, [
        label(b, "+ added", Slot.diffAdded),
        label(b, "- removed", Slot.diffRemoved),
        label(b, "@@ hunk", Slot.diffHunk),
    ]);
    return b.add(Widget(kind: WidgetKind.column, children: rows, gap: 1,
        width: SizeSpec.grow(), alignX: Alignment.start));
}

/// What a press on `id` selects, or `size_t.max` when the id is not a theme row.
size_t themeAt(size_t id) pure nothrow @nogc
    => id >= hitTheme && id < hitTheme + themeNames.length
        ? id - hitTheme : size_t.max;

private RgbColor bgOf(in Color c) pure nothrow @nogc
    => c.kind == Color.Kind.rgb ? c.rgb : RgbColor(0, 0, 0);

private string hex(in RgbColor c)
{
    import std.format : format;

    return format!"#%02x%02x%02x"(c.r, c.g, c.b);
}

@("ui_gallery.pages.themesWindowKeepsTheSelectionVisible")
@safe pure nothrow @nogc unittest
{
    // The two off-by-ones: scrolling past the start, and leaving a gap under
    // the last entry. Checked at every position rather than at the ends only.
    enum rows = 12;
    const n = themeNames.length;
    foreach (sel; 0 .. n)
    {
        const first = windowStart(sel, n, rows);
        assert(sel >= first && sel < first + rows, "the selection is off-window");
        assert(first + rows <= n, "the window runs past the end");
    }

    // A list shorter than the window does not scroll at all.
    assert(windowStart(0, 4, rows) == 0);
    assert(windowStart(3, 4, rows) == 0);
}

@("ui_gallery.pages.themesRowIdsMapBackToThemes")
@safe pure nothrow @nogc unittest
{
    foreach (i; 0 .. themeNames.length)
        assert(themeAt(hitTheme + i) == i);

    // Anything else is not a theme row — including the shell's own ids, which
    // is the collision the hit-id bases exist to prevent.
    assert(themeAt(0) == size_t.max);
    assert(themeAt(hitTheme + themeNames.length) == size_t.max);
    assert(themeAt(1000) == size_t.max);
}

@("ui_gallery.pages.themesEveryBuiltinRendersItsOwnScene")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    // Thirty-six themes, one of which will be the first to carry a palette
    // shape nothing else does. Building and laying out the page under each is
    // cheap insurance against a resolver that only ever saw the default.
    foreach (i; 0 .. themeNames.length)
    {
        GalleryState s;
        s.themeIndex = i;
        auto b = Builder();
        auto tree = b.finish(view(b, s));
        auto frames = layout(tree, Constraints(maxW: s.contentWidth));
        assert(frames.length == tree.nodes.length);
    }
}
