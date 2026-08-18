/**
The Scrolling page: a viewport you can actually drive, beside the numbers.

Everything about a scrollbar is one formula — `scrollbarThumb` — and the reason
it is one is that a viewer with two copies of it scrolls the document one way
and paints the handle another. The page puts the formula's output next to the
handle it produced, at three offsets, so the two are checkable by eye.

The viewport below is independent of the shell's own scroll: the page you are
reading scrolls with `PgDn`, and this one with `n`/`p` or by grabbing its bar.
Two `ScrollView`s over two documents, from the same machine — and grabbing
either leaves the other where it was, which is the property a shared global
scroll offset cannot have.
*/
module pages.scrolling_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent, PointerEvent;
import sparkles.ui.components.chrome : scrollbar, scrollView;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.components.scroll_view : ScrollExtents, ScrollView;
import sparkles.ui.state : ScrollState, scrollbarThumb;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import kit;
import scrollbars;
import keymap : GalleryCommand;
import state : GalleryState, hitDemoBar;

@safe:

/// ditto
// The page's keys are `galleryBindings` rows in `GalleryScope.pageScrolling`.

/// The specimen document's length, and the viewport's.
private enum int docRows = 40;
/// ditto
private enum int viewRows = 8;

/// What the specimen's bar scrolls over. Stated once — the viewport, the
/// clamp, the thumb and the grab all read it.
private enum BarGeometry geom =
    BarGeometry(content: docRows, viewport: viewRows, track: viewRows);

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const offset = s.demoView.v.offset;
    const thumb = scrollbarThumb(docRows, viewRows, offset, viewRows);

    uint[] body_;
    body_ ~= heading(b, "Scrolling · one thumb formula");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A scroll view is a clipping container plus a child offset — the "
        ~ "layout engine's viewport primitive with the scroll machine plugged "
        ~ "in. Rows above the viewport get negative frames, and the display "
        ~ "list culls whatever falls fully outside.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "forty rows in an eight-row viewport", [
        b.add(Widget(
            kind: WidgetKind.row,
            children: [
                scrollView(b, document(b), viewRows, ScrollState(offset)),
                // The live bar: grabbable, hover-expanding, and carrying the
                // hit id the page's own pointer handler looks its rect up by.
                // No gap — the bar brings its own gutter, which is what keeps
                // the document's width the same whichever width the bar is.
                verticalBar(b, s.demoView, geom, hitDemoBar),
            ],
        )),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the machine", [
        kv(b, "offset", text(offset, " of ",
            ScrollState.maxOffset(docRows, viewRows)), 16, Slot.chromeAccent),
        kv(b, "thumb", text("start ", thumb.start, ", extent ", thumb.extent),
            16, Slot.code),
        kv(b, "track", text(viewRows, " cells"), 16, Slot.code),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the same formula at three offsets", [
        row(b, [
            scrollbar(b, docRows, viewRows, 0, viewRows),
            label(b, "top — the thumb starts flush", Slot.muted),
        ]),
        row(b, [
            scrollbar(b, docRows, viewRows, 16, viewRows),
            label(b, "middle", Slot.muted),
        ]),
        row(b, [
            scrollbar(b, docRows, viewRows,
                ScrollState.maxOffset(docRows, viewRows), viewRows),
            label(b, "bottom — the thumb ends flush", Slot.muted),
        ]),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Flush at both ends is the property that lets a reader tell they have "
        ~ "reached the end. A thumb whose extent was rounded independently of "
        ~ "its position leaves a cell of track showing at the bottom, and the "
        ~ "document looks like it has more to give.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "a grab is relative", [
        kv(b, "press on the thumb", "grabs in place; the offset does not move",
            18, Slot.docs),
        kv(b, "press on the track", "jumps the thumb's leading edge to you",
            18, Slot.docs),
        kv(b, "drag", "moves the thumb relative to where you grabbed it",
            18, Slot.docs),
        kv(b, "wheel", "already multiplied by the producer — never again here",
            18, Slot.docs),
    ]);

    return column(b, body_);
}

private uint document(ref Builder b)
{
    uint[] rows;
    foreach (i; 0 .. docRows)
        rows ~= label(b, text(i + 1 < 10 ? " " : "", i + 1, "  ",
            i % 5 == 0 ? "— a landmark row —" : "the quick brown fox"),
            i % 5 == 0 ? Slot.chromeAccent : Slot.code);
    return b.add(Widget(kind: WidgetKind.column, children: rows));
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.scrollNext: return scrollBy(s, 1);
        case GalleryCommand.scrollPrev: return scrollBy(s, -1);
        case GalleryCommand.scrollNextPage: return scrollBy(s, viewRows);
        case GalleryCommand.scrollPrevPage: return scrollBy(s, -viewRows);
        case GalleryCommand.scrollTop: return scrollBy(s, -docRows);
        case GalleryCommand.scrollBottom: return scrollBy(s, docRows);
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
            pageScope: GalleryScope.pageScrolling, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }
}

private bool scrollBy(ref GalleryState s, int delta)
{
    // Through the machine, so the thumb the page prints and the thumb it draws
    // move together. `scrolledBy` on a bare `ScrollState` beside a bar would
    // leave the two to drift.
    s.demoView.wheeledV(delta, ScrollExtents(geom.content, geom.viewport,
        geom.track));
    return true;
}

/**
The specimen bar's own pointer handling.

The shell cannot do this: the bar's grab zone is its $(B painted rect), and
only the page knows which node carries it. Handed the frames the painter used,
the page looks the rect up and the two cannot disagree.
*/
bool handlePointer(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
    in Frame[] frames)
    => driveVertical(s.demoView, s.capture, capDemoBar, p,
        rectOf(tree, frames, hitDemoBar), geom, s.guiCellH, s.guiPointerY);

/// Eases the specimen bar's width. Called by the shell, which owns the clock.
void step(ref GalleryState s, int dtMs)
{
    easeVertical(s.demoView, s.caps, dtMs / 1000.0f);
}

@("ui_gallery.pages.scrollingThumbIsFlushAtBothEnds")
@safe pure nothrow @nogc unittest
{
    // The property the page shows three offsets of, checked across every track
    // size the pane might give it rather than only the one it happens to use.
    foreach (track; [3, 6, 8, 20])
    {
        const limit = ScrollState.maxOffset(docRows, viewRows);
        const top = scrollbarThumb(docRows, viewRows, 0, track);
        const end = scrollbarThumb(docRows, viewRows, limit, track);
        assert(top.start == 0);
        assert(end.start + end.extent == track);
        assert(top.extent >= 1 && top.extent <= track);
    }
}

@("ui_gallery.pages.scrollingKeysReachBothEnds")
@safe unittest
{
    GalleryState s;
    handleKey(s, KeyEvent(Key.char_, 'G'));
    assert(s.demoView.v.offset == ScrollState.maxOffset(docRows, viewRows));

    handleKey(s, KeyEvent(Key.char_, 'g'));
    assert(s.demoView.v.offset == 0);

    // And a step past an end clamps rather than running off.
    handleKey(s, KeyEvent(Key.char_, 'p'));
    assert(s.demoView.v.offset == 0);
}

@("ui_gallery.pages.scrollingIsIndependentOfTheShell")
@safe unittest
{
    // Two documents, two offsets, one machine. If the page reached for the
    // shell's scroll state the reader would find the catalog scrolling under
    // them as they drove the specimen.
    GalleryState s;
    handleKey(s, KeyEvent(Key.char_, 'N'));
    assert(s.demoView.v.offset > 0);
}
