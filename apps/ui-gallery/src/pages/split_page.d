/**
The Split page: a draggable divider, and the pointer shape that goes with it.

`SplitState` is four fields and a clamp, and the reason it belongs to the
toolkit rather than to each application is the grab: a drag resizes the pane by
the pointer's delta $(B since the grab), not by snapping the divider under the
pointer. Get that wrong and the divider jumps the moment you touch it, which is
the single most common defect in hand-rolled splitters.

The page also shows `wantedPointerShape`, because deciding which cursor to ask
for is the other half of a divider and is equally easy to spread across two
places that disagree.
*/
module pages.split_page;

import std.conv : text;

import sparkles.base.term_control : PointerShape;
import sparkles.input : Key, KeyEvent;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.state : SplitState, wantedPointerShape;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import keymap : GalleryCommand;
import state : GalleryState, hitSplit;

@safe:

/// ditto
// The page's keys are `galleryBindings` rows in `GalleryScope.pageSplit`.

/// The pane's bounds, in cells. Named because the clamp, the drag and the
/// display all need them and three copies would disagree.
enum int minPane = 10;
/// ditto
int maxPane(int available) pure nothrow @nogc
    => available - minPane > minPane ? available - minPane : minPane;

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const available = w - 1; // the divider column
    const size = s.split.clamped(minPane, maxPane(available)).size;

    uint[] body_;
    body_ ~= heading(b, "Split · a divider between two panes");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The pane resizes by the pointer's delta since the grab, so the "
        ~ "divider does not jump when you take hold of it away from its "
        ~ "centre. Units are the caller's — cells here, pixels in a window.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "the panes", [splitRow(b, s, size, available)]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the machine", [
        kv(b, "size", size.text, 16, Slot.chromeAccent),
        kv(b, "dragging", s.split.dragging ? "yes" : "no", 16),
        kv(b, "bounds", text(minPane, " … ", maxPane(available)), 16),
        kv(b, "pointer shape", shapeName(
            wantedPointerShape(s.split, s.hover.isHot(hitSplit))), 16),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The wanted shape is one decision, asked of the machine: hovering the "
        ~ "divider asks for a resize cursor, and a drag keeps asking for it "
        ~ "even after the pointer has left the divider — otherwise the cursor "
        ~ "flickers back to an arrow the instant you move.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "what a clamp is for", [
        kv(b, "window shrank", "clamped() pulls the pane back inside", 16, Slot.docs),
        kv(b, "drag past the end", "draggedTo clamps; the grab is unchanged", 16, Slot.docs),
        kv(b, "release", "the size stays, the drag ends", 16, Slot.docs),
    ]);

    return column(b, body_);
}

/// Two panes and the divider between them.
private uint splitRow(ref Builder b, in GalleryState s, int size, int available)
{
    const left = b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(
            kind: WidgetKind.column,
            children: [
                label(b, "leading", Slot.chromeAccent, TextStyle(bold: true)),
                label(b, text(size, " cells"), Slot.code),
                label(b, "a file tree, say", Slot.muted),
            ],
        ))],
        slot: Slot.chip,
        width: SizeSpec.fixed(size),
        height: SizeSpec.fixed(5),
        paintBackground: true,
        clipX: true,
    ));

    // The divider is one column wide and is the whole grab target. Drawn as
    // glyphs rather than a background fill, so it is visible on a target with
    // no colour at all — the same reason the sidebar's selection marker is a
    // character and not a tint.
    const hot = s.pointerAffordances && s.hover.isHot(hitSplit);
    const slot = hot || s.split.dragging ? Slot.chromeAccent : Slot.border;
    auto bars = new uint[](5);
    foreach (i; 0 .. 5)
        bars[i] = b.add(Widget(kind: WidgetKind.glyph, glyph: '│', slot: slot));
    const divider = b.add(Widget(
        kind: WidgetKind.column,
        children: bars,
        width: SizeSpec.fixed(1),
        height: SizeSpec.fixed(5),
        hitId: hitSplit,
    ));

    const right = b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(
            kind: WidgetKind.column,
            children: [
                label(b, "trailing", Slot.chromeAccent, TextStyle(bold: true)),
                label(b, text(available - size, " cells"), Slot.code),
                label(b, "…and the document beside it", Slot.muted),
            ],
        ))],
        slot: Slot.surface,
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(5),
        paintBackground: true,
        clipX: true,
    ));

    return b.add(Widget(
        kind: WidgetKind.row,
        children: [left, divider, right],
        width: SizeSpec.grow(),
    ));
}

private string shapeName(PointerShape p)
{
    import std.conv : to;

    return p.to!string;
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    // The keyboard route, so the page is usable on a target with no pointer at
    // all. It goes through the same clamp the drag does.
    const available = s.contentWidth - 1;
    switch (cmd)
    {
        case GalleryCommand.splitShrink:
            s.split = SplitState(s.split.size - 2).clamped(minPane, maxPane(available));
            return true;
        case GalleryCommand.splitGrow:
            s.split = SplitState(s.split.size + 2).clamped(minPane, maxPane(available));
            return true;
        default:
            return false;
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
            pageScope: GalleryScope.pageSplit, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }
}

@("ui_gallery.pages.splitDragIsRelativeToTheGrab")
@safe unittest
{
    // The defect the machine exists to prevent: grabbing the divider two cells
    // off its centre and having it jump those two cells before it moves.
    auto sp = SplitState(30).started(32); // grabbed two cells to the right
    assert(sp.size == 30, "taking hold moves nothing");

    sp = sp.draggedTo(36, minPane, 60);
    assert(sp.size == 34, "the pane follows the pointer's delta, not its position");

    sp = sp.released();
    assert(!sp.dragging && sp.size == 34);
}

@("ui_gallery.pages.splitKeyboardRouteUsesTheSameClamp")
@safe unittest
{
    // A target with no pointer must still reach every size, and must be held
    // by the same bounds — two clamps would let the keyboard walk past where a
    // drag can go.
    GalleryState s;
    const available = s.contentWidth - 1;

    foreach (_; 0 .. 200)
        handleKey(s, KeyEvent(Key.left));
    assert(s.split.size == minPane);

    foreach (_; 0 .. 200)
        handleKey(s, KeyEvent(Key.right));
    assert(s.split.size == maxPane(available));
}

@("ui_gallery.pages.splitBoundsSurviveATinyPane")
@safe unittest
{
    // A surface too small for two minimum panes still yields a legal size
    // rather than a negative maximum the clamp would then invert.
    foreach (available; [4, 12, 21, 40, 200])
    {
        const hi = maxPane(available);
        assert(hi >= minPane);
        assert(SplitState(0).clamped(minPane, hi).size == minPane);
        assert(SplitState(1000).clamped(minPane, hi).size == hi);
    }
}

@("ui_gallery.pages.splitPointerShapeSurvivesLeavingTheDivider")
@safe unittest
{
    // A drag keeps asking for the resize cursor after the pointer leaves the
    // divider — otherwise the shape flickers back the instant you move.
    const idle = SplitState(30);
    const dragging = idle.started(30);

    assert(wantedPointerShape(idle, false) == PointerShape.default_);
    assert(wantedPointerShape(idle, true) != PointerShape.default_);
    assert(wantedPointerShape(dragging, false) != PointerShape.default_,
        "the grab owns the cursor, not the hover");
}
