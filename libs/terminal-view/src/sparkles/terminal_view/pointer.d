/**
The terminal's mouse, from `sparkles:input` events in pane pixels: the
overlay scrollbar, local selection with click counting and edge autoscroll,
OSC 8 and URL hover with the Ctrl+click opener, and mouse reporting to a
program that tracks the mouse — what the per-frame raylib poll did, one event
at a time.

Events carry what a poll read from the device: where the pointer is
(`PointerEvent.pos`, in pixels from the pane's top-left corner), which button
changed, and the modifiers held. What a poll did every frame whatever the
input — easing the bar, scrolling a selection held past the pane's edge —
happens in $(LREF pointerFrame), which the component calls once per frame.
*/
module sparkles.terminal_view.pointer;

import core.time : MonoTime;

import sparkles.ghostty.c;
import sparkles.input : mousePointer, PointerAction, PointerButton, PointerEvent, WheelEvent;
import sparkles.terminal_view.core : CoreState;
import sparkles.terminal_view.event_map : ghosttyButtonOf, ghosttyModsOf;
import sparkles.terminal_view.input : detectLink, mouse_encode_and_write;
import sparkles.terminal_view.selection : Granularity, moveEnd, selectAt, selectCells,
    SelectionEnd;
import sparkles.ui.components.scroll_view : scrollLayout, ScrollArea, ScrollAreaAxis;
import sparkles.ui.geometry : Point, Rect;

/// What the pointer did last: the buttons held and where it is, which the
/// encoder and the per-frame autoscroll need between events.
struct PointerTrack
{
    bool left, middle, right, back, forward; /// held
    Point pos;           /// in pane pixels
    bool known;          /// `pos` has been reported

    /// Whether any of the three main buttons is held.
    bool anyPressed() const @safe pure nothrow @nogc => left || middle || right;

    private void note(in PointerEvent p) @safe pure nothrow @nogc
    {
        const down = p.action == PointerAction.press;
        if (p.action == PointerAction.press || p.action == PointerAction.release)
            final switch (p.button)
            {
                case PointerButton.left: left = down; break;
                case PointerButton.middle: middle = down; break;
                case PointerButton.right: right = down; break;
                case PointerButton.back: back = down; break;
                case PointerButton.forward: forward = down; break;
                case PointerButton.none: break;
            }
        pos = p.pos;
        known = true;
    }
}

/// The pane a pointer event lands in: its pixel size, and whether the
/// terminal draws its own overlay bar there (`TVW9`).
struct PaneGeometry
{
    int width, height; /// in pixels
    bool ownBar = true;
}

/**
One pointer event, pane-relative pixels. A `leave` forgets the position and
nothing else.
*/
void pointerEvent(ref CoreState s, ref PointerTrack t, in PointerEvent p, in PaneGeometry pane)
    @system nothrow @nogc
{
    if (p.action == PointerAction.leave)
    {
        t.known = false;
        return;
    }
    const moved = !t.known || p.pos != t.pos;
    t.note(p);
    syncEncoder(s, t, pane);
    ghostty_mouse_event_set_mods(s.mouse_event, ghosttyModsOf(p.mods));
    GhosttyMousePosition gpos = { x: p.pos.x, y: p.pos.y };
    ghostty_mouse_event_set_position(s.mouse_event, gpos);

    // The overlay bar first: a press on it, or a drag it holds, is its own.
    if (pane.ownBar && stepBar(s, t, p, pane))
        return;

    bool tracking = false;
    ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, cast(void*) &tracking);
    if (!tracking || p.mods.shift)
        localSelection(s, t, p, pane, moved);
    else
        report(s, t, p, moved);
}

/**
The wheel: one pair of scroll-button reports to a program that tracks the
mouse, else rows for the scrollback to walk, added to `wheelRows` (`SCV12`).
*/
void wheelEvent(ref CoreState s, in WheelEvent w, ref float wheelRows) @system nothrow @nogc
{
    const rows = w.exactY;
    if (rows == 0)
        return;
    bool tracking = false;
    ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, cast(void*) &tracking);
    if (tracking)
    {
        // Where the wheel turned and what was held, as a press would report.
        ghostty_mouse_event_set_mods(s.mouse_event, ghosttyModsOf(w.mods));
        GhosttyMousePosition gpos = { x: w.pos.x, y: w.pos.y };
        ghostty_mouse_event_set_position(s.mouse_event, gpos);
        ghostty_mouse_event_set_button(s.mouse_event,
            rows < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE);
        ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_PRESS);
        mouse_encode_and_write(s.pty_fd, s.mouse_encoder, s.mouse_event);
        ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_RELEASE);
        mouse_encode_and_write(s.pty_fd, s.mouse_encoder, s.mouse_event);
    }
    else
        wheelRows += rows;
}

/**
The frame's half of the mouse, `dt` seconds after the last: the bar's width
eases toward hovered or not, and a selection held at or past the pane's top
or bottom edge scrolls a row and follows it. True while it wants the next
frame without input (a held autoscroll).
*/
bool pointerFrame(ref CoreState s, ref PointerTrack t, in PaneGeometry pane, float dt)
    @system nothrow @nogc
{
    if (pane.ownBar)
        s.sbState.view.easeV(mousePointer, dt);
    if (!(s.selState.isSelecting && t.left && t.known) || pane.height <= 0)
        return false;
    int delta;
    if (t.pos.y <= 0)
        delta = -1;
    else if (t.pos.y >= pane.height - 1)
        delta = 1;
    if (delta == 0)
        return false;
    GhosttyTerminalScrollViewport scroll;
    scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
    scroll.value.delta = delta;
    ghostty_terminal_scroll_viewport(s.terminal, scroll);
    const c = cellOf(s, t.pos, pane);
    cast(void) moveEnd(s.terminal, s.selState, SelectionEnd.end, c.x, c.y);
    return true;
}

private:

void syncEncoder(ref CoreState s, in PointerTrack t, in PaneGeometry pane) @system nothrow @nogc
{
    ghostty_mouse_encoder_setopt_from_terminal(s.mouse_encoder, s.terminal);
    // The pane's own extent, not the window's: an embedded pane (`TSS9`).
    GhosttyMouseEncoderSize size = {
        size: GhosttyMouseEncoderSize.sizeof,
        screen_width: cast(uint) pane.width,
        screen_height: cast(uint) pane.height,
        cell_width: cast(uint) s.cellWidth,
        cell_height: cast(uint) s.cellHeight,
    };
    ghostty_mouse_encoder_setopt(s.mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
    bool any = t.anyPressed;
    ghostty_mouse_encoder_setopt(s.mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any);
    bool trackCell = true;
    ghostty_mouse_encoder_setopt(s.mouse_encoder,
        GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackCell);
}

// The overlay bar's machine (`TVW9`) sees the left button: its press, its
// release, a drag while it is down, and motion otherwise. True when the bar
// consumed the event.
bool stepBar(ref CoreState s, in PointerTrack t, in PointerEvent p, in PaneGeometry pane)
    @system nothrow @nogc
{
    GhosttyTerminalScrollbar sb;
    ghostty_terminal_get(s.terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, cast(void*) &sb);
    const frame = scrollLayout(ScrollArea(
        rect: Rect(0, 0, pane.width, pane.height),
        v: ScrollAreaAxis(content: sb.total, viewport: sb.len, gutter: 16, minExtent: 20),
    ));
    const isLeft = p.button == PointerButton.left;
    const action = isLeft && p.action == PointerAction.press ? PointerAction.press
        : isLeft && p.action == PointerAction.release ? PointerAction.release
        : t.left ? PointerAction.drag : PointerAction.move;
    const pe = PointerEvent(action: action, button: PointerButton.left, pos: p.pos);
    const wasDragging = s.sbState.view.v.dragging;
    const over = frame.vPointer(pe).over;
    s.sbState.capture = s.sbState.view.stepV(s.sbState.capture, 1, pe, sb.offset, frame);
    if (action == PointerAction.release)
        s.sbState.capture = s.sbState.capture.released();

    const target = s.sbState.view.v.offset;
    if (target != sb.offset)
    {
        GhosttyTerminalScrollViewport scroll = { tag: GHOSTTY_SCROLL_VIEWPORT_DELTA };
        scroll.value.delta = cast(int)(target - sb.offset);
        ghostty_terminal_scroll_viewport(s.terminal, scroll);
    }
    return wasDragging || s.sbState.view.v.dragging
        || (action == PointerAction.press && over);
}

Point cellOf(in CoreState s, Point pos, in PaneGeometry pane) @safe pure nothrow @nogc
{
    const maxCols = pane.width / s.cellWidth, maxRows = pane.height / s.cellHeight;
    int cx = pos.x / s.cellWidth, cy = pos.y / s.cellHeight;
    if (pos.x < 0) cx = 0;
    if (pos.y < 0) cy = 0;
    if (cx >= maxCols) cx = maxCols - 1;
    if (cy >= maxRows) cy = maxRows - 1;
    return Point(cx < 0 ? 0 : cx, cy < 0 ? 0 : cy);
}

// Selection and hover, when no program tracks the mouse or Shift overrides it.
void localSelection(ref CoreState s, ref PointerTrack t, in PointerEvent p, in PaneGeometry pane,
    bool moved) @system nothrow @nogc
{
    const maxCols = pane.width / s.cellWidth;
    const c = cellOf(s, p.pos, pane);

    // Hover re-scans only when the pointer moved or its cell changed.
    if (moved || c.x != s.hoverState.lastCellX || c.y != s.hoverState.lastCellY)
    {
        s.hoverState.lastCellX = c.x;
        s.hoverState.lastCellY = c.y;
        GhosttyPoint pt = {
            tag: GHOSTTY_POINT_TAG_VIEWPORT,
            value: { coordinate: { x: cast(ushort) c.x, y: cast(uint) c.y } }
        };
        detectLink(s.terminal, pt, maxCols, s.hoverState);
    }

    const left = p.button == PointerButton.left;
    if (left && p.action == PointerAction.press)
    {
        if (p.mods.ctrl && s.hoverState.isHoveringUrl && s.hoverState.url.length > 0)
        {
            // The component opens it, through the embedder's allow-list
            // (`TPR6`, `TPR7`).
            s.hoverState.openRequested = true;
            return;
        }
        // A second press on the same cell soon after selects its word, a
        // third its line (`TSE7`); the first starts a drag over the model.
        const now = (MonoTime.currTime - MonoTime.zero).total!"hnsecs" / 1e7;
        auto sel = &s.selState;
        const again = now - sel.lastPressTime < 0.4 && c.x == sel.lastPressX
            && c.y == sel.lastPressY;
        const clicks = again && sel.clicks < 3 ? sel.clicks + 1 : 1;
        sel.lastPressTime = now;
        sel.lastPressX = c.x;
        sel.lastPressY = c.y;
        sel.clicks = cast(ubyte) clicks;
        if (clicks > 1)
        {
            cast(void) selectAt(s.terminal, *sel, c.x, c.y, cast(ushort) maxCols,
                clicks == 2 ? Granularity.word : Granularity.line);
            return;
        }
        cast(void) selectCells(s.terminal, *sel, c.x, c.y, c.x, c.y, p.mods.alt);
        sel.isSelecting = true;
    }
    else if (s.selState.isSelecting && p.action == PointerAction.drag && t.left)
        cast(void) moveEnd(s.terminal, s.selState, SelectionEnd.end, c.x, c.y);
    else if (s.selState.isSelecting && left && p.action == PointerAction.release)
        s.selState.isSelecting = false;
}

// Reports to a program that tracks the mouse: presses and releases of any
// button, and motion with the first held of left, right, middle.
void report(ref CoreState s, in PointerTrack t, in PointerEvent p, bool moved)
    @system nothrow @nogc
{
    final switch (p.action)
    {
        case PointerAction.press:
        case PointerAction.release:
            const button = ghosttyButtonOf(p.button);
            if (button == GHOSTTY_MOUSE_BUTTON_UNKNOWN)
                return;
            ghostty_mouse_event_set_action(s.mouse_event, p.action == PointerAction.press
                ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE);
            ghostty_mouse_event_set_button(s.mouse_event, button);
            break;
        case PointerAction.move:
        case PointerAction.drag:
            if (!moved)
                return;
            ghostty_mouse_event_set_action(s.mouse_event, GHOSTTY_MOUSE_ACTION_MOTION);
            if (t.left)
                ghostty_mouse_event_set_button(s.mouse_event, GHOSTTY_MOUSE_BUTTON_LEFT);
            else if (t.right)
                ghostty_mouse_event_set_button(s.mouse_event, GHOSTTY_MOUSE_BUTTON_RIGHT);
            else if (t.middle)
                ghostty_mouse_event_set_button(s.mouse_event, GHOSTTY_MOUSE_BUTTON_MIDDLE);
            else
                ghostty_mouse_event_clear_button(s.mouse_event);
            break;
        case PointerAction.leave:
            return;
    }
    mouse_encode_and_write(s.pty_fd, s.mouse_encoder, s.mouse_event);
}
