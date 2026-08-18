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

import sparkles.input : Key, KeyEvent, PointerEvent;
import sparkles.ui.components.chrome : actionBar, gutter, headerBar,
    ScrollbarGlyphs, scrollView, tabStrip;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.components.scroll_view : ScrollExtents, ScrollView;
import sparkles.ui.state : ScrollState, scrollbarThumb;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import kit;
import scrollbars;
import keymap : GalleryCommand;
import state : GalleryState, hitActions, hitChromeBar, hitChromeSamples, hitTabs;

@safe:

/// ditto
// The page's keys are `galleryBindings` rows in `GalleryScope.pageComponents`.

/// The live scroll view's document and viewport.
private enum int chromeDocRows = 10;
/// ditto
private enum int chromeViewRows = 4;

/// What its bar scrolls over — stated once, read by the viewport, the clamp,
/// the thumb and the grab.
private enum BarGeometry chromeGeom = BarGeometry(
    content: chromeDocRows, viewport: chromeViewRows, track: chromeViewRows);

/// The three formula positions and ASCII specimen share these dimensions.
private enum BarGeometry specimenGeom = BarGeometry(
    content: 100, viewport: 6, track: 6);

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
            verticalBar(b, s.componentBars[0], specimenGeom,
                hitChromeSamples),
            label(b, text("offset ", s.componentBars[0].v.offset), Slot.muted),
            verticalBar(b, s.componentBars[1], specimenGeom,
                hitChromeSamples + 1),
            label(b, text("offset ", s.componentBars[1].v.offset), Slot.muted),
            verticalBar(b, s.componentBars[2], specimenGeom,
                hitChromeSamples + 2),
            label(b, text("offset ", s.componentBars[2].v.offset,
                " (end specimen)"), Slot.muted),
        ]),
        spacer(b),
        label(b, "ASCII glyphs, for a target with no block characters:",
            Slot.muted),
        row(b, [
            glyphScrollbar(b, s.componentBars[3], specimenGeom,
                ScrollbarGlyphs(thumb: '#', track: '|'),
                hitChromeSamples + 3),
        ]),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "scrollView — a clipped, offset viewport, live", [
        b.add(Widget(
            kind: WidgetKind.row,
            children: [
                scrollView(b, longColumn(b), chromeViewRows,
                    ScrollState(s.chromeView.v.offset)),
                // Grabbable, hover-expanding, eased — the page's own pointer
                // handler drives it by its painted rect, like every live bar
                // in the catalog.
                verticalBar(b, s.chromeView, chromeGeom, hitChromeBar),
            ],
        )),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A scroll view is the layout engine's viewport primitive with the "
        ~ "scroll machine plugged in: a clipping container plus a child offset. "
        ~ "Rows above the viewport get negative frames and the display list "
        ~ "culls them. Drive this one: n/p, or grab the bar.", w);

    return column(b, body_);
}

private uint longColumn(ref Builder b)
{
    uint[] rows;
    foreach (i; 0 .. chromeDocRows)
        rows ~= label(b, text("row ", i), i % 2 == 0 ? Slot.code : Slot.muted);
    return b.add(Widget(kind: WidgetKind.column, children: rows));
}

/**
A deliberately literal catalog specimen.

The application scrollbar remains one semantic node so a pixel backend can
draw sub-cell geometry. This one exists to show a caller-supplied character
set, so it stays a tiny glyph wrapper: the main column carries `|`/`#`, and
the optional second column contains only the thumb. Thus hover widens the
handle without painting a full-height rectangle or widening the ASCII track.
*/
private uint glyphScrollbar(ref Builder b, in ScrollView sv,
    in BarGeometry g, in ScrollbarGlyphs glyphs, size_t hitId)
{
    const thumb = scrollbarThumb(g.content, g.viewport, sv.v.offset, g.track);

    uint column(bool thumbOnly)
    {
        uint[] cells;
        foreach (at; 0 .. g.track)
        {
            const inThumb = at >= thumb.start && at < thumb.start + thumb.extent;
            cells ~= b.add(Widget(
                kind: WidgetKind.glyph,
                glyph: inThumb ? glyphs.thumb
                    : thumbOnly ? ' ' : glyphs.track,
                slot: inThumb ? Slot.thumb : Slot.track,
            ));
        }
        return b.add(Widget(kind: WidgetKind.column, children: cells));
    }

    uint[] columns;
    if (sv.vAnim.percent >= 50.0f)
        columns ~= column(true);
    columns ~= column(false);
    return b.add(Widget(
        kind: WidgetKind.row,
        children: columns,
        width: SizeSpec.fixed(gutterCells),
        alignX: Alignment.end,
        hitId: hitId,
    ));
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.compTabPrev:
            s.componentsTab = s.componentsTab == 0
                ? tabLabels.length - 1 : s.componentsTab - 1;
            return true;
        case GalleryCommand.compTabNext:
            s.componentsTab = (s.componentsTab + 1) % tabLabels.length;
            return true;
        case GalleryCommand.compAction:
            // The ranged row's arg is 1-based; the action index is not.
            s.componentsAction = arg - 1;
            return true;
        case GalleryCommand.compScrollDown:
        case GalleryCommand.compScrollUp:
            // Through the machine, so the printed thumb and the drawn one move
            // together — the same rule the Scrolling page states.
            s.chromeView.wheeledV(
                cmd == GalleryCommand.compScrollDown ? 1 : -1, ScrollExtents(
                    chromeGeom.content, chromeGeom.viewport, chromeGeom.track));
            return true;
        default: return false;
    }
}

version (unittest)
{
    import keymap : commandFor, GalleryContext, GalleryScope;

    // Tests drive the page exactly as the shell does: the key resolves in
    // the page's scope and the command dispatches above.
    private bool handleKey(ref GalleryState s, in KeyEvent k) @safe
    {
        const r = commandFor(k, GalleryContext(
            pageScope: GalleryScope.pageComponents, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }
}

/// Every bar's pointer handling — each grab zone is its painted rect, which
/// only the page can look up in the frames the painter used.
bool handlePointer(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
    in Frame[] frames)
{
    bool consumed;
    foreach (i, ref bar; s.componentBars)
    {
        const handled = driveVertical(bar, s.capture, capChromeSamples + i, p,
            rectOf(tree, frames, hitChromeSamples + i), specimenGeom,
            i == 3 ? 0 : s.guiCellH, s.guiPointerY);
        consumed = handled || consumed;
    }
    const handled = driveVertical(s.chromeView, s.capture, capChromeBar, p,
        rectOf(tree, frames, hitChromeBar), chromeGeom, s.guiCellH,
        s.guiPointerY);
    return handled || consumed;
}

/// Eases every bar's width. The shell owns the clock.
void step(ref GalleryState s, int dtMs)
{
    foreach (ref bar; s.componentBars)
        easeVertical(bar, s.caps, dtMs / 1000.0f);
    easeVertical(s.chromeView, s.caps, dtMs / 1000.0f);
}

/// Whether one of this page's bars still needs animation frames.
bool animating(in GalleryState s)
{
    foreach (ref bar; s.componentBars)
        if (easing(bar, s.caps))
            return true;
    return easing(s.chromeView, s.caps);
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

@("ui_gallery.pages.componentsScrollbarsRespondToThePointer")
@safe unittest
{
    import sparkles.input : PointerAction, PointerButton;
    import sparkles.ui.geometry : Constraints, Point;
    import sparkles.ui.layout : layout;

    GalleryState s;
    auto b = Builder();
    auto tree = b.finish(view(b, s));
    auto frames = layout(tree, Constraints(maxW: s.contentWidth));

    foreach (i; 0 .. s.componentBars.length)
    {
        const r = rectOf(tree, frames, hitChromeSamples + i);
        assert(!r.empty, "every specimen has a painted hit rect");

        const before = s.componentBars[i].v.offset;
        const atTop = before > specimenGeom.content / 2;
        const pos = Point(r.x, atTop ? r.y : r.y + r.height - 1);
        assert(handlePointer(s, PointerEvent(action: PointerAction.press,
            button: PointerButton.left, pos: pos), tree, frames));
        assert(s.componentBars[i].v.dragging,
            "the specimen takes a real scrollbar grab");
        assert(s.componentBars[i].v.offset != before,
            "pressing the opposite end moves its independent offset");
        assert(handlePointer(s, PointerEvent(action: PointerAction.release,
            button: PointerButton.left, pos: pos), tree, frames));
        assert(!s.componentBars[i].v.dragging && s.capture.isFree);
    }
}

@("ui_gallery.pages.componentsAsciiScrollbarStaysGlyphBased")
@safe unittest
{
    // This catalog row demonstrates caller-supplied characters even in the
    // GUI. Sending it through the semantic pixel primitive turns both into a
    // generic rectangle, which is the regression this pins.
    GalleryState s;
    s.componentBars[3].vAnim.percent = 100;
    auto b = Builder();
    auto tree = b.finish(glyphScrollbar(b, s.componentBars[3], specimenGeom,
        ScrollbarGlyphs(thumb: '#', track: '|'), hitChromeSamples + 3));

    size_t thumbs, tracks, semanticBars;
    foreach (ref node; tree.nodes)
    {
        if (node.kind == WidgetKind.scrollbar)
            ++semanticBars;
        if (node.kind == WidgetKind.glyph && node.glyph == '#')
            ++thumbs;
        if (node.kind == WidgetKind.glyph && node.glyph == '|')
            ++tracks;
    }
    assert(semanticBars == 0, "the ASCII specimen must remain literal glyphs");
    assert(thumbs == 2, "hover adds only a second thumb glyph");
    assert(tracks == specimenGeom.track - 1,
        "the one-column ASCII track does not widen with the handle");
}
