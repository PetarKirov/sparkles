/**
The Components page: the application chrome, live.

`sparkles.ui.components.chrome` is the set every backend used to hand-roll —
a header band, a segmented bar, a tab strip, a gutter, a scrollbar. The reason
they belong to the toolkit is not that any one of them is hard to draw: it is
that a hand-rolled one computes its geometry $(B twice), once to paint and once
to hit-test, and the two drift. Here the segments are laid out once and the hit
rects come from those same frames, which the page demonstrates by printing what
is under the pointer.
*/
module pages.components_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.chrome : actionBar, gutter, headerBar, scrollbar,
    ScrollbarGlyphs, scrollView, tabStrip;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.state : ScrollState;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState, hitActions, hitTabs;

@safe:

/// ditto
static immutable string[] keys = ["← → tab", "1-4 action", "click anything"];

/// The tab strip's labels — deliberately of different widths, and one with a
/// multi-byte character, so `fitLabels` is measured in cells and not bytes.
private static immutable string[] tabLabels = ["config.js", "config.ts", "π.md"];

/// The action bar's segments.
private static immutable string[] actionLabels =
    ["◀ prev", "next ▶", "reload", "close"];

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] body_;
    body_ ~= heading(b, "Components · application chrome");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Every one of these is a pure view: it appends a subtree and returns "
        ~ "its root. Behaviour lives in the state machines beside them, so the "
        ~ "same component serves a terminal and a window with no second copy.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "headerBar — leading · centre · trailing", [
        headerBar(b,
            [label(b, "hue", Slot.chromeAccent, TextStyle(bold: true))],
            [label(b, "file.d", Slot.chrome)],
            [label(b, "q quit", Slot.chrome)]),
        spacer(b),
        headerBar(b,
            [label(b, "focused pane", Slot.chromeAccent, TextStyle(bold: true))],
            null, null, focused: true),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The groups are separated by grow spacers — the spelling the layout "
        ~ "engine prescribes for distribution, since there is no margin and no "
        ~ "space-between.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "tabStrip — one active, the rest idle", [
        tabStrip(b, tabLabels, s.componentsTab, hitTabs, s.press),
        spacer(b),
        label(b, "fitLabels: false — each tab takes an equal share instead",
            Slot.muted),
        tabStrip(b, tabLabels, s.componentsTab, hitTabs + 100, s.press,
            fitLabels: false),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Active and armed are different states, because they mean different "
        ~ "things: this one is showing, this one is being pressed. Conflating "
        ~ "them is why a hand-rolled strip flickers the wrong tab mid-drag.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "actionBar — equal segments, each a target", [
        actionBar(b, actionLabels, hitActions, s.press),
        spacer(b),
        row(b, [
            label(b, "last activated", Slot.muted),
            label(b, s.componentsAction < actionLabels.length
                ? actionLabels[s.componentsAction] : "—", Slot.chromeAccent),
        ]),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "gutter — right-aligned line numbers", [
        row(b, [
            gutter(b, 98, 5, 4),
            b.add(Widget(
                kind: WidgetKind.column,
                children: [
                    label(b, "void main()", Slot.code),
                    label(b, "{", Slot.code),
                    label(b, "    writeln(\"hi\");", Slot.code),
                    label(b, "}", Slot.code),
                    label(b, "", Slot.code),
                ],
            )),
        ]),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "scrollbar — the one thumb formula", [
        row(b, [
            scrollbar(b, 100, 6, 0, 6),
            label(b, "offset 0", Slot.muted),
            scrollbar(b, 100, 6, 47, 6),
            label(b, "offset 47", Slot.muted),
            scrollbar(b, 100, 6, 94, 6),
            label(b, "offset 94 (flush)", Slot.muted),
        ]),
        spacer(b),
        label(b, "ASCII glyphs, for a target with no block characters:",
            Slot.muted),
        row(b, [
            scrollbar(b, 100, 6, 47, 6, ScrollbarGlyphs(thumb: '#', track: '|')),
        ]),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "scrollView — a clipped, offset viewport", [
        scrollView(b, longColumn(b), 4, ScrollState(2)),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A scroll view is the layout engine's viewport primitive with the "
        ~ "scroll machine plugged in: a clipping container plus a child offset. "
        ~ "Rows above the viewport get negative frames and the display list "
        ~ "culls them.", w);

    return column(b, body_);
}

private uint longColumn(ref Builder b)
{
    uint[] rows;
    foreach (i; 0 .. 10)
        rows ~= label(b, text("row ", i), i % 2 == 0 ? Slot.code : Slot.muted);
    return b.add(Widget(kind: WidgetKind.column, children: rows));
}

/// ditto
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    if (k.key == Key.left)
    {
        s.componentsTab = s.componentsTab == 0
            ? tabLabels.length - 1 : s.componentsTab - 1;
        return true;
    }
    if (k.key == Key.right)
    {
        s.componentsTab = (s.componentsTab + 1) % tabLabels.length;
        return true;
    }
    if (k.ch >= '1' && k.ch <= '4')
    {
        s.componentsAction = k.ch - '1';
        return true;
    }
    return false;
}

/// ditto
bool handleActivate(ref GalleryState s, size_t id)
{
    // Two strips share a base region but not a base: the `fitLabels: false`
    // copy is offset by 100, so pressing either selects the same tab and
    // neither can be mistaken for the other.
    if (id >= hitTabs && id < hitTabs + tabLabels.length)
    {
        s.componentsTab = id - hitTabs;
        return true;
    }
    if (id >= hitTabs + 100 && id < hitTabs + 100 + tabLabels.length)
    {
        s.componentsTab = id - hitTabs - 100;
        return true;
    }
    if (id >= hitActions && id < hitActions + actionLabels.length)
    {
        s.componentsAction = id - hitActions;
        return true;
    }
    return false;
}

@("ui_gallery.pages.componentsTabsHitWhereTheyPaint")
@safe unittest
{
    import sparkles.input : PointerAction, PointerEvent;
    import sparkles.ui.geometry : Constraints, Point;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hoverTargets, HoverState;

    // The `IXR27` invariant on a page's own chrome. `π.md` is 5 bytes and 4
    // cells; a strip measuring with `.length` would put every tab after it
    // ~25 % too far right, and this walks the painted rects to notice.
    GalleryState s;
    auto b = Builder();
    auto tree = b.finish(view(b, s));
    auto frames = layout(tree, Constraints(maxW: s.contentWidth));
    const targets = hoverTargets(tree, frames);

    HoverState hover;
    foreach (i; 0 .. tabLabels.length)
    {
        // Find the tab's own rect, then aim at its centre.
        bool found;
        foreach (t; targets)
            if (t.hitId == hitTabs + i)
            {
                hover.update(PointerEvent(action: PointerAction.move,
                    pos: Point(t.rect.x + t.rect.width / 2,
                        t.rect.y + t.rect.height / 2)), targets);
                assert(hover.hot == hitTabs + i, "tab " ~ tabLabels[i]);
                found = true;
                break;
            }
        assert(found, "tab " ~ tabLabels[i] ~ " is not hit-testable");
    }
}

@("ui_gallery.pages.componentsActivationMapsEveryIdBack")
@safe unittest
{
    // Every id the page mints maps back to something, and nothing else does —
    // an id that fell through would be a segment that paints and does nothing.
    GalleryState s;
    foreach (i; 0 .. tabLabels.length)
    {
        assert(handleActivate(s, hitTabs + i));
        assert(s.componentsTab == i);
        assert(handleActivate(s, hitTabs + 100 + i));
        assert(s.componentsTab == i, "both strips select the same tab");
    }
    foreach (i; 0 .. actionLabels.length)
    {
        assert(handleActivate(s, hitActions + i));
        assert(s.componentsAction == i);
    }

    assert(!handleActivate(s, 0), "nothing is not a target");
    assert(!handleActivate(s, 1), "the shell's own ids are not this page's");
}

@("ui_gallery.pages.componentsScrollbarThumbIsFlushAtTheEnd")
@safe unittest
{
    import sparkles.ui.state : scrollbarThumb;

    // The property the page shows three offsets of: at the maximum offset the
    // thumb ends flush with the track, which is the only way a reader can tell
    // they have reached the bottom.
    const top = scrollbarThumb(100, 6, 0, 6);
    const end = scrollbarThumb(100, 6, 94, 6);
    assert(top.start == 0);
    assert(end.start + end.extent == 6);
}
