/**
The GPU rendering of the toolkit scrollbar (`B-1`/`IXB1`): the SAME
$(REF ScrollbarState, sparkles,ui,state) machine and STM2 geometry every
backend runs, drawn the way a pixel canvas should draw it — a thin idle
rail that hover-expands with easing, plus a faint track while hovered or
dragging. The cell backends render the identical state through the WGT10
`scrollbar` component; this module is its px twin, shared by every raylib
host instead of hand-rolled per pane.

Axis-aware: a vertical bar hugs `track`'s right edge, a horizontal one its
bottom edge. Colors come from the same palette `track`/`thumb` entries the
cell component resolves — one color authority.
*/
module sparkles.ui_raylib.scrollbar;

import raylib : Color, DrawRectangle, MouseCursor;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.ui.geometry : Rect;
import sparkles.ui.state : ScrollAxis, ScrollbarState;

@safe:

/// The hover-expand animation state now lives with the `ScrollView`
/// container (`SCV1`) — re-exported here so px hosts keep one import.
public import sparkles.ui.components.scroll_view : ScrollbarAnim;

/// The bar's drawable geometry for one frame, in px: the track rectangle
/// and the thumb rectangle inside it (both empty when the content fits).
struct ScrollbarLayout
{
    Rect track;
    Rect thumb;
    bool live; /// content overflows — the bar exists
}

/**
Computes one frame's px geometry from the machine + animation: `trackRect`
is the full-length strip the bar lives in (its right edge for a vertical
bar, bottom edge for a horizontal one, `anim.width` thick), and the thumb
comes from the one STM2 formula over `content`/`viewport` in the track's
px length, with a grabbable px minimum (`minExtent`, default 24 — the GUI
convention). Pure — the host hit-tests and draws with the result.
*/
ScrollbarLayout scrollbarLayout(in ScrollbarState st, in ScrollbarAnim anim,
    long content, long viewport, in Rect trackArea,
    int minExtent = 24) pure nothrow @nogc
{
    ScrollbarLayout l;
    if (content <= viewport)
        return l;
    l.live = true;
    const w = cast(int) anim.width;
    if (st.axis == ScrollAxis.vertical)
    {
        l.track = Rect(trackArea.x + trackArea.width - w, trackArea.y,
            w, trackArea.height);
        const g = st.thumb(content, viewport, trackArea.height, minExtent);
        l.thumb = Rect(l.track.x, trackArea.y + g.start, w, g.extent);
    }
    else
    {
        l.track = Rect(trackArea.x, trackArea.y + trackArea.height - w,
            trackArea.width, w);
        const g = st.thumb(content, viewport, trackArea.width, minExtent);
        l.thumb = Rect(trackArea.x + g.start, l.track.y, g.extent, w);
    }
    return l;
}

/// Draws the frame's geometry: the faint track only while hovered or
/// grabbed (the GUI look), the thumb always.
void drawScrollbar(in ScrollbarLayout l, in ScrollbarState st,
    in RgbColor trackColor, in RgbColor thumbColor) @trusted
{
    if (!l.live)
        return;
    static Color rl(in RgbColor c) => Color(c.r, c.g, c.b, 255);
    if (st.hovered || st.dragging)
        DrawRectangle(l.track.x, l.track.y, l.track.width, l.track.height,
            rl(trackColor));
    DrawRectangle(l.thumb.x, l.thumb.y, l.thumb.width, l.thumb.height,
        rl(thumbColor));
}

@("uiRaylib.scrollbar.layoutGeometry")
@safe pure nothrow @nogc
unittest
{
    // A vertical bar in a 100×400 px area, 8 px wide, 400 units of content
    // in a 100-unit viewport: thumb extent 400*100/400 = 100 px at offset 0.
    const st = ScrollbarState(ScrollAxis.vertical, 0);
    const anim = ScrollbarAnim(8.0f);
    const l = scrollbarLayout(st, anim, 400, 100, Rect(20, 10, 100, 400));
    assert(l.live);
    assert(l.track == Rect(112, 10, 8, 400));
    assert(l.thumb == Rect(112, 10, 8, 100));

    // Scrolled to the end, the thumb sits flush at the track's bottom.
    const e = scrollbarLayout(st.scrolledTo(300), anim, 400, 100,
        Rect(20, 10, 100, 400));
    assert(e.thumb.y + e.thumb.height == 410);

    // A horizontal bar hugs the bottom edge; fitting content is not live.
    const h = scrollbarLayout(ScrollbarState(ScrollAxis.horizontal, 0),
        anim, 200, 100, Rect(0, 0, 100, 50));
    assert(h.live && h.track == Rect(0, 42, 100, 8));
    assert(!scrollbarLayout(st, anim, 90, 100, Rect(0, 0, 100, 50)).live);
}

/// The raylib spelling of a toolkit $(REF PointerShape, sparkles,base,
/// term_control) — the GUI half of the pointer-shape seam (`IXB4`); the
/// TUI writes the same shapes as OSC 22.
MouseCursor toRaylibCursor(PointerShape shape) @safe pure nothrow @nogc
{
    final switch (shape) with (PointerShape)
    {
        case default_: return MouseCursor.MOUSE_CURSOR_DEFAULT;
        case text:     return MouseCursor.MOUSE_CURSOR_IBEAM;
        case pointer:  return MouseCursor.MOUSE_CURSOR_POINTING_HAND;
        case ewResize: return MouseCursor.MOUSE_CURSOR_RESIZE_EW;
        case nsResize: return MouseCursor.MOUSE_CURSOR_RESIZE_NS;
        case grab:     return MouseCursor.MOUSE_CURSOR_RESIZE_ALL;
        case grabbing: return MouseCursor.MOUSE_CURSOR_RESIZE_ALL;
    }
}
