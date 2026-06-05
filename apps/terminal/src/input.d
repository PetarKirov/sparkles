module input;

import core.sys.posix.unistd : write;

import raylib;

import sparkles.ghostty.c;

/// Best-effort write of all `len` bytes to the (non-blocking) pty master.
///
/// Because the fd is non-blocking, `write` may return short or fail with
/// `EAGAIN`. We retry on `EINTR`, advance past partial writes, and silently
/// drop the remainder if the kernel buffer is full — which is what terminal
/// emulators do under back-pressure (mirrors ghostling's `pty_write`).
void pty_write(int fd, scope const(void)* data, size_t len) @system @nogc nothrow
{
    import core.stdc.errno : errno, EINTR;

    auto buf = cast(const(ubyte)*) data;
    while (len > 0)
    {
        const n = write(fd, buf, len);
        if (n > 0)
        {
            buf += n;
            len -= cast(size_t) n;
        }
        else if (n < 0)
        {
            if (errno == EINTR) continue;
            break; // EAGAIN or a real error — drop the remainder.
        }
        else
        {
            break; // n == 0: nothing written, avoid spinning.
        }
    }
}

GhosttyKey raylib_key_to_ghostty(int rl_key) @safe pure nothrow @nogc
{
    if (rl_key >= KeyboardKey.KEY_A && rl_key <= KeyboardKey.KEY_Z)
        return cast(GhosttyKey)(GHOSTTY_KEY_A + (rl_key - KeyboardKey.KEY_A));
    if (rl_key >= KeyboardKey.KEY_ZERO && rl_key <= KeyboardKey.KEY_NINE)
        return cast(GhosttyKey)(GHOSTTY_KEY_DIGIT_0 + (rl_key - KeyboardKey.KEY_ZERO));
    if (rl_key >= KeyboardKey.KEY_F1 && rl_key <= KeyboardKey.KEY_F12)
        return cast(GhosttyKey)(GHOSTTY_KEY_F1 + (rl_key - KeyboardKey.KEY_F1));

    switch (cast(KeyboardKey)rl_key) {
    case KeyboardKey.KEY_SPACE:       return GHOSTTY_KEY_SPACE;
    case KeyboardKey.KEY_ENTER:       return GHOSTTY_KEY_ENTER;
    case KeyboardKey.KEY_TAB:         return GHOSTTY_KEY_TAB;
    case KeyboardKey.KEY_BACKSPACE:   return GHOSTTY_KEY_BACKSPACE;
    case KeyboardKey.KEY_DELETE:      return GHOSTTY_KEY_DELETE;
    case KeyboardKey.KEY_ESCAPE:      return GHOSTTY_KEY_ESCAPE;
    case KeyboardKey.KEY_UP:          return GHOSTTY_KEY_ARROW_UP;
    case KeyboardKey.KEY_DOWN:        return GHOSTTY_KEY_ARROW_DOWN;
    case KeyboardKey.KEY_LEFT:        return GHOSTTY_KEY_ARROW_LEFT;
    case KeyboardKey.KEY_RIGHT:       return GHOSTTY_KEY_ARROW_RIGHT;
    case KeyboardKey.KEY_HOME:        return GHOSTTY_KEY_HOME;
    case KeyboardKey.KEY_END:         return GHOSTTY_KEY_END;
    case KeyboardKey.KEY_PAGE_UP:     return GHOSTTY_KEY_PAGE_UP;
    case KeyboardKey.KEY_PAGE_DOWN:   return GHOSTTY_KEY_PAGE_DOWN;
    case KeyboardKey.KEY_INSERT:      return GHOSTTY_KEY_INSERT;
    case KeyboardKey.KEY_MINUS:       return GHOSTTY_KEY_MINUS;
    case KeyboardKey.KEY_EQUAL:       return GHOSTTY_KEY_EQUAL;
    case KeyboardKey.KEY_LEFT_BRACKET:  return GHOSTTY_KEY_BRACKET_LEFT;
    case KeyboardKey.KEY_RIGHT_BRACKET: return GHOSTTY_KEY_BRACKET_RIGHT;
    case KeyboardKey.KEY_BACKSLASH:   return GHOSTTY_KEY_BACKSLASH;
    case KeyboardKey.KEY_SEMICOLON:   return GHOSTTY_KEY_SEMICOLON;
    case KeyboardKey.KEY_APOSTROPHE:  return GHOSTTY_KEY_QUOTE;
    case KeyboardKey.KEY_COMMA:       return GHOSTTY_KEY_COMMA;
    case KeyboardKey.KEY_PERIOD:      return GHOSTTY_KEY_PERIOD;
    case KeyboardKey.KEY_SLASH:       return GHOSTTY_KEY_SLASH;
    case KeyboardKey.KEY_GRAVE:       return GHOSTTY_KEY_BACKQUOTE;
    default:                          return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

@("input.raylib_key_to_ghostty")
@safe pure nothrow @nogc
unittest
{
    // Contiguous ranges are mapped by offset from their first element.
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_A) == GHOSTTY_KEY_A);
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_Z) == GHOSTTY_KEY_Z);
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_ZERO) == GHOSTTY_KEY_DIGIT_0);
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_F1) == GHOSTTY_KEY_F1);
    // Named keys come from the switch.
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_SPACE) == GHOSTTY_KEY_SPACE);
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_ENTER) == GHOSTTY_KEY_ENTER);
    // Unmapped keys (e.g. modifiers) fall through to UNIDENTIFIED.
    assert(raylib_key_to_ghostty(KeyboardKey.KEY_LEFT_SHIFT) == GHOSTTY_KEY_UNIDENTIFIED);
}

GhosttyMods get_ghostty_mods()
{
    GhosttyMods mods = 0;
    if (IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT) || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT))
        mods |= GHOSTTY_MODS_SHIFT;
    if (IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL) || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL))
        mods |= GHOSTTY_MODS_CTRL;
    if (IsKeyDown(KeyboardKey.KEY_LEFT_ALT) || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT))
        mods |= GHOSTTY_MODS_ALT;
    if (IsKeyDown(KeyboardKey.KEY_LEFT_SUPER) || IsKeyDown(KeyboardKey.KEY_RIGHT_SUPER))
        mods |= GHOSTTY_MODS_SUPER;
    return mods;
}

uint raylib_key_unshifted_codepoint(int rl_key) @safe pure nothrow @nogc
{
    if (rl_key >= KeyboardKey.KEY_A && rl_key <= KeyboardKey.KEY_Z)
        return 'a' + cast(uint)(rl_key - KeyboardKey.KEY_A);
    if (rl_key >= KeyboardKey.KEY_ZERO && rl_key <= KeyboardKey.KEY_NINE)
        return '0' + cast(uint)(rl_key - KeyboardKey.KEY_ZERO);

    switch (cast(KeyboardKey)rl_key) {
    case KeyboardKey.KEY_SPACE:          return ' ';
    case KeyboardKey.KEY_MINUS:          return '-';
    case KeyboardKey.KEY_EQUAL:          return '=';
    case KeyboardKey.KEY_LEFT_BRACKET:   return '[';
    case KeyboardKey.KEY_RIGHT_BRACKET:  return ']';
    case KeyboardKey.KEY_BACKSLASH:      return '\\';
    case KeyboardKey.KEY_SEMICOLON:      return ';';
    case KeyboardKey.KEY_APOSTROPHE:     return '\'';
    case KeyboardKey.KEY_COMMA:          return ',';
    case KeyboardKey.KEY_PERIOD:         return '.';
    case KeyboardKey.KEY_SLASH:          return '/';
    case KeyboardKey.KEY_GRAVE:          return '`';
    default:                             return 0;
    }
}

@("input.raylib_key_unshifted_codepoint")
@safe pure nothrow @nogc
unittest
{
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_A) == 'a');
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_Z) == 'z');
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_ZERO) == '0');
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_NINE) == '9');
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_SPACE) == ' ');
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_SLASH) == '/');
    // Keys without an unshifted printable codepoint return 0.
    assert(raylib_key_unshifted_codepoint(KeyboardKey.KEY_LEFT_SHIFT) == 0);
}

GhosttyMouseButton raylib_mouse_to_ghostty(int rl_button) @safe pure nothrow @nogc
{
    switch (cast(MouseButton)rl_button) {
    case MouseButton.MOUSE_BUTTON_LEFT:    return GHOSTTY_MOUSE_BUTTON_LEFT;
    case MouseButton.MOUSE_BUTTON_RIGHT:   return GHOSTTY_MOUSE_BUTTON_RIGHT;
    case MouseButton.MOUSE_BUTTON_MIDDLE:  return GHOSTTY_MOUSE_BUTTON_MIDDLE;
    case MouseButton.MOUSE_BUTTON_SIDE:    return GHOSTTY_MOUSE_BUTTON_FOUR;
    case MouseButton.MOUSE_BUTTON_EXTRA:   return GHOSTTY_MOUSE_BUTTON_FIVE;
    case MouseButton.MOUSE_BUTTON_FORWARD: return GHOSTTY_MOUSE_BUTTON_SIX;
    case MouseButton.MOUSE_BUTTON_BACK:    return GHOSTTY_MOUSE_BUTTON_SEVEN;
    default:                               return GHOSTTY_MOUSE_BUTTON_UNKNOWN;
    }
}

@("input.raylib_mouse_to_ghostty")
@safe pure nothrow @nogc
unittest
{
    assert(raylib_mouse_to_ghostty(MouseButton.MOUSE_BUTTON_LEFT) == GHOSTTY_MOUSE_BUTTON_LEFT);
    assert(raylib_mouse_to_ghostty(MouseButton.MOUSE_BUTTON_RIGHT) == GHOSTTY_MOUSE_BUTTON_RIGHT);
    assert(raylib_mouse_to_ghostty(MouseButton.MOUSE_BUTTON_MIDDLE) == GHOSTTY_MOUSE_BUTTON_MIDDLE);
    // Out-of-range button codes map to UNKNOWN.
    assert(raylib_mouse_to_ghostty(99) == GHOSTTY_MOUSE_BUTTON_UNKNOWN);
}

struct SelectionState {
    bool isSelecting = false;
    bool isRectangular = false;
    GhosttyTrackedGridRef start = null;
    GhosttyTrackedGridRef end = null;

    void free() {
        if (start) { ghostty_tracked_grid_ref_free(start); start = null; }
        if (end) { ghostty_tracked_grid_ref_free(end); end = null; }
        isSelecting = false;
        isRectangular = false;
    }
}

struct ScrollbarState {
    bool isHovered = false;
    bool isDragging = false;
    float currentWidth = 4.0f;
    float targetWidth = 4.0f;
    float dragStartY = 0.0f;
    long dragStartOffset = 0;
}

struct HoverState {
    bool isHoveringUrl = false;
    string url = "";
    int start_x = -1;
    int end_x = -1;
    int y = -1;
}

void mouse_encode_and_write(int pty_fd, GhosttyMouseEncoder encoder, GhosttyMouseEvent event)
{
    char[128] buf;
    size_t written = 0;
    GhosttyResult res = ghostty_mouse_encoder_encode(encoder, event, buf.ptr, buf.sizeof, &written);
    if (res == GHOSTTY_SUCCESS && written > 0)
        pty_write(pty_fd, buf.ptr, written);
}

void handle_mouse(
    int pty_fd,
    GhosttyMouseEncoder encoder,
    GhosttyMouseEvent event,
    GhosttyTerminal terminal,
    int cell_width,
    int cell_height,
    ref SelectionState selState,
    ref ScrollbarState sbState,
    ref HoverState hoverState)
{
    ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal);

    int scr_w = GetScreenWidth();
    int scr_h = GetScreenHeight();
    GhosttyMouseEncoderSize enc_size = {
        size: GhosttyMouseEncoderSize.sizeof,
        screen_width: cast(uint)scr_w,
        screen_height: cast(uint)scr_h,
        cell_width: cast(uint)cell_width,
        cell_height: cast(uint)cell_height,
        padding_top: 0,
        padding_bottom: 0,
        padding_left: 0,
        padding_right: 0,
    };
    ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &enc_size);

    bool any_pressed = IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT) ||
        IsMouseButtonDown(MouseButton.MOUSE_BUTTON_RIGHT) ||
        IsMouseButtonDown(MouseButton.MOUSE_BUTTON_MIDDLE);
    ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_pressed);

    bool track_cell = true;
    ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_cell);

    GhosttyMods mods = get_ghostty_mods();
    Vector2 pos = GetMousePosition();
    ghostty_mouse_event_set_mods(event, mods);

    GhosttyMousePosition gpos = { x: pos.x, y: pos.y };
    ghostty_mouse_event_set_position(event, gpos);

    // Process Scrollbar Overlay
    GhosttyTerminalScrollbar sb;
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, cast(void*)&sb);

    bool has_scrollbar = sb.total > sb.len;
    float track_height = cast(float)GetScreenHeight();
    float sb_max_width = 16.0f;

    if (has_scrollbar) {
        float thumb_height = track_height * (cast(float)sb.len / cast(float)sb.total);
        if (thumb_height < 20.0f) thumb_height = 20.0f;

        float movable_pixels = track_height - thumb_height;
        long total_movable_rows = sb.total - sb.len;

        float thumb_y = 0.0f;
        if (total_movable_rows > 0)
            thumb_y = movable_pixels * (cast(float)sb.offset / cast(float)total_movable_rows);

        bool hover_track = pos.x >= GetScreenWidth() - sb_max_width;
        bool hover_thumb = hover_track && pos.y >= thumb_y && pos.y <= thumb_y + thumb_height;

        sbState.isHovered = hover_track || sbState.isDragging;
        sbState.targetWidth = sbState.isHovered ? 12.0f : 4.0f;

        if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT)) {
            if (hover_track) {
                if (hover_thumb) {
                    sbState.isDragging = true;
                    sbState.dragStartY = pos.y;
                    sbState.dragStartOffset = sb.offset;
                } else {
                    float ratio = pos.y / track_height;
                    long target_offset = cast(long)(ratio * sb.total) - (sb.len / 2);
                    if (target_offset < 0) target_offset = 0;
                    if (target_offset > total_movable_rows) target_offset = total_movable_rows;

                    int scroll_delta = cast(int)(target_offset - sb.offset);
                    if (scroll_delta != 0) {
                        GhosttyTerminalScrollViewport scroll = { tag: GHOSTTY_SCROLL_VIEWPORT_DELTA };
                        scroll.value.delta = scroll_delta;
                        ghostty_terminal_scroll_viewport(terminal, scroll);
                    }
                }
                return; // consume click!
            }
        }

        if (sbState.isDragging) {
            if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT)) {
                sbState.isDragging = false;
            } else if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT)) {
                float delta_y = pos.y - sbState.dragStartY;
                if (movable_pixels > 0 && total_movable_rows > 0) {
                    long delta_rows = cast(long)(delta_y * total_movable_rows / movable_pixels);
                    long target_offset = sbState.dragStartOffset + delta_rows;
                    if (target_offset < 0) target_offset = 0;
                    if (target_offset > total_movable_rows) target_offset = total_movable_rows;

                    int scroll_delta = cast(int)(target_offset - sb.offset);
                    if (scroll_delta != 0) {
                        GhosttyTerminalScrollViewport scroll = { tag: GHOSTTY_SCROLL_VIEWPORT_DELTA };
                        scroll.value.delta = scroll_delta;
                        ghostty_terminal_scroll_viewport(terminal, scroll);

                        // Because the buffer scrolled but the mouse cursor is clamped,
                        // we need to adjust the drag anchor so smooth dragging continues perfectly!
                        // Actually, if we're doing absolute scrolling based on delta_y from dragStartY,
                        // and the mouse hits the top/bottom boundary and stops moving, the scroll will also stop.
                        // But wait! If the mouse is clamped, `pos.y` stops increasing.
                        // Thus `delta_y` stays the same, and `target_offset` stops changing.
                        // But if the mouse is clamped and the user is still trying to move it out of bounds,
                        // we should maybe auto-scroll the scrollbar too?
                        // The user can't move the mouse further because of clamping. They will have to drag the thumb.
                        // This is correct behavior for scrollbars.
                    }
                }
            }
            return; // consume all events while dragging
        }
    } else {
        sbState.isHovered = false;
        sbState.targetWidth = 4.0f;
    }

    float dt = GetFrameTime();
    float diff = sbState.targetWidth - sbState.currentWidth;
    if (diff != 0.0f) {
        sbState.currentWidth += diff * 15.0f * dt;
        if (sbState.currentWidth < 4.0f && sbState.targetWidth == 4.0f) sbState.currentWidth = 4.0f;
        if (sbState.currentWidth > 12.0f && sbState.targetWidth == 12.0f) sbState.currentWidth = 12.0f;
    }

    bool mouse_tracking = false;
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, cast(void*)&mouse_tracking);

    bool shift_held = IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT) || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT);
    bool local_selection = !mouse_tracking || shift_held;

    if (local_selection) {
        int max_cols = GetScreenWidth() / cell_width;
        int max_rows = GetScreenHeight() / cell_height;

        int cx = cast(int)(pos.x / cell_width);
        int cy = cast(int)(pos.y / cell_height);

        if (cx < 0) cx = 0;
        if (cx >= max_cols) cx = max_cols - 1;

        if (cy < 0) cy = 0;
        if (cy >= max_rows) cy = max_rows - 1;

        GhosttyPoint pt = {
            tag: GHOSTTY_POINT_TAG_VIEWPORT,
            value: { coordinate: { x: cast(ushort)cx, y: cast(uint)cy } }
        };

        hoverState.isHoveringUrl = false;
        hoverState.url = "";
        hoverState.start_x = -1;
        hoverState.end_x = -1;
        hoverState.y = -1;

        GhosttyGridRef hoverRef;
        if (ghostty_terminal_grid_ref(terminal, pt, &hoverRef) == GHOSTTY_SUCCESS) {
            size_t uri_len = 0;
            if (ghostty_grid_ref_hyperlink_uri(&hoverRef, null, 0, &uri_len) == GHOSTTY_OUT_OF_SPACE && uri_len > 0) {
                import core.memory : pureMalloc, pureFree;
                ubyte* buf = cast(ubyte*)pureMalloc(uri_len);
                if (buf) {
                    if (ghostty_grid_ref_hyperlink_uri(&hoverRef, buf, uri_len, &uri_len) == GHOSTTY_SUCCESS) {
                        hoverState.isHoveringUrl = true;
                        hoverState.url = cast(string)buf[0..uri_len].idup;
                        hoverState.y = pt.value.coordinate.y;

                        // Scan left to find start of link
                        int left_x = pt.value.coordinate.x;
                        while (left_x > 0) {
                            GhosttyPoint p = pt; p.value.coordinate.x = cast(ushort)(left_x - 1);
                            GhosttyGridRef r; ghostty_terminal_grid_ref(terminal, p, &r);
                            size_t l = 0; ghostty_grid_ref_hyperlink_uri(&r, null, 0, &l);
                            if (l != uri_len) break;
                            left_x--;
                        }

                        // Scan right to find end of link
                        int right_x = pt.value.coordinate.x;
                        while (right_x < max_cols - 1) {
                            GhosttyPoint p = pt; p.value.coordinate.x = cast(ushort)(right_x + 1);
                            GhosttyGridRef r; ghostty_terminal_grid_ref(terminal, p, &r);
                            size_t l = 0; ghostty_grid_ref_hyperlink_uri(&r, null, 0, &l);
                            if (l != uri_len) break;
                            right_x++;
                        }

                        hoverState.start_x = left_x;
                        hoverState.end_x = right_x;
                    }
                    pureFree(buf);
                }
            }
        }

        if (!hoverState.isHoveringUrl) {
            GhosttyPoint p1 = { tag: GHOSTTY_POINT_TAG_VIEWPORT, value: { coordinate: { x: 0, y: pt.value.coordinate.y } } };
            GhosttyPoint p2 = { tag: GHOSTTY_POINT_TAG_VIEWPORT, value: { coordinate: { x: cast(ushort)(max_cols - 1), y: pt.value.coordinate.y } } };
            GhosttyGridRef r1, r2;
            if (ghostty_terminal_grid_ref(terminal, p1, &r1) == GHOSTTY_SUCCESS &&
                ghostty_terminal_grid_ref(terminal, p2, &r2) == GHOSTTY_SUCCESS) {

                GhosttySelection sel = { start: r1, end: r2, rectangle: false };
                GhosttyFormatterTerminalOptions fmt_opts;
                fmt_opts.size = GhosttyFormatterTerminalOptions.sizeof;
                fmt_opts.selection = &sel;
                GhosttyFormatter fmt;
                if (ghostty_formatter_terminal_new(null, &fmt, terminal, fmt_opts) == GHOSTTY_SUCCESS) {
                    size_t len = 0;
                    if (ghostty_formatter_format_buf(fmt, null, 0, &len) == GHOSTTY_OUT_OF_SPACE && len > 0) {
                        import core.memory : pureMalloc, pureFree;
                        ubyte* buf = cast(ubyte*)pureMalloc(len);
                        if (buf) {
                            if (ghostty_formatter_format_buf(fmt, buf, len, &len) == GHOSTTY_SUCCESS) {
                                string line = cast(string)buf[0..len];
                                import std.regex : matchAll, regex;
                                auto m = matchAll(line, regex(r"https?://[^\s]+"));
                                foreach (c; m) {
                                    // Hacky column mapping: assumes ASCII (1 byte per cell)
                                    int start_col = cast(int)c.pre.length;
                                    int end_col = start_col + cast(int)c.hit.length - 1;
                                    if (pt.value.coordinate.x >= start_col && pt.value.coordinate.x <= end_col) {
                                        hoverState.isHoveringUrl = true;
                                        hoverState.url = c.hit.idup;
                                        hoverState.start_x = start_col;
                                        hoverState.end_x = end_col;
                                        hoverState.y = pt.value.coordinate.y;
                                        break;
                                    }
                                }
                            }
                            pureFree(buf);
                        }
                    }
                    ghostty_formatter_free(fmt);
                }
            }
        }

        if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT)) {
            if (IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL) || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL)) {
                if (hoverState.isHoveringUrl) {
                    import std.process : browse;
                    browse(hoverState.url);
                    return;
                }
            }
            selState.free();
            selState.isSelecting = true;
            selState.isRectangular = IsKeyDown(KeyboardKey.KEY_LEFT_ALT) || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT);
            ghostty_terminal_grid_ref_track(terminal, pt, &selState.start);
            ghostty_terminal_grid_ref_track(terminal, pt, &selState.end);
        } else if (selState.isSelecting && IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT)) {
            if (pos.y <= 0) {
                GhosttyTerminalScrollViewport scroll;
                scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
                scroll.value.delta = -1;
                ghostty_terminal_scroll_viewport(terminal, scroll);
            } else if (pos.y >= GetScreenHeight() - 1) {
                GhosttyTerminalScrollViewport scroll;
                scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
                scroll.value.delta = 1;
                ghostty_terminal_scroll_viewport(terminal, scroll);
            }
            if (selState.end) {
                ghostty_tracked_grid_ref_set(selState.end, terminal, pt);
            }
        } else if (selState.isSelecting && IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT)) {
            selState.isSelecting = false;
        }
    } else {
        static const int[] buttons = [
            MouseButton.MOUSE_BUTTON_LEFT, MouseButton.MOUSE_BUTTON_RIGHT, MouseButton.MOUSE_BUTTON_MIDDLE,
            MouseButton.MOUSE_BUTTON_SIDE, MouseButton.MOUSE_BUTTON_EXTRA, MouseButton.MOUSE_BUTTON_FORWARD,
            MouseButton.MOUSE_BUTTON_BACK,
        ];

        foreach (rl_btn; buttons) {
            GhosttyMouseButton gbtn = raylib_mouse_to_ghostty(rl_btn);
            if (gbtn == GHOSTTY_MOUSE_BUTTON_UNKNOWN) continue;

            if (IsMouseButtonPressed(cast(MouseButton)rl_btn)) {
                ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS);
                ghostty_mouse_event_set_button(event, gbtn);
                mouse_encode_and_write(pty_fd, encoder, event);
            } else if (IsMouseButtonReleased(cast(MouseButton)rl_btn)) {
                ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_RELEASE);
                ghostty_mouse_event_set_button(event, gbtn);
                mouse_encode_and_write(pty_fd, encoder, event);
            }
        }

        Vector2 delta = GetMouseDelta();
        if (delta.x != 0.0f || delta.y != 0.0f) {
            ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_MOTION);
            if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT))
                ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT);
            else if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_RIGHT))
                ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_RIGHT);
            else if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_MIDDLE))
                ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_MIDDLE);
            else
                ghostty_mouse_event_clear_button(event);
            mouse_encode_and_write(pty_fd, encoder, event);
        }
    }

    float wheel = GetMouseWheelMove();
    if (wheel != 0.0f) {
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, cast(void*)&mouse_tracking);

        if (mouse_tracking) {
            GhosttyMouseButton scroll_btn = (wheel > 0.0f) ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE;
            ghostty_mouse_event_set_button(event, scroll_btn);
            ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS);
            mouse_encode_and_write(pty_fd, encoder, event);
            ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_RELEASE);
            mouse_encode_and_write(pty_fd, encoder, event);
        } else {
            int scroll_delta = (wheel > 0.0f) ? -3 : 3;
            GhosttyTerminalScrollViewport sv;
            sv.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
            sv.value.delta = scroll_delta;
            ghostty_terminal_scroll_viewport(terminal, sv);
        }
    }
}

void handle_input(int pty_fd, GhosttyKeyEncoder encoder, GhosttyKeyEvent event, GhosttyTerminal terminal, ref SelectionState selState)
{
    import std.utf : encode;
    import std.typecons : Yes;
    ghostty_key_encoder_setopt_from_terminal(encoder, terminal);

    char[64] char_utf8;
    int char_utf8_len = 0;
    int ch;
    while ((ch = GetCharPressed()) != 0) {
        char[4] u8;
        // Substitute U+FFFD for an invalid codepoint instead of throwing — a
        // bad value from GetCharPressed must not crash input handling.
        int n = cast(int)encode!(Yes.useReplacementDchar)(u8, cast(dchar)ch);
        if (char_utf8_len + n < char_utf8.length) {
            char_utf8[char_utf8_len .. char_utf8_len + n] = u8[0 .. n];
            char_utf8_len += n;
        }
    }

    static const int[] special_keys = [
        KeyboardKey.KEY_SPACE, KeyboardKey.KEY_ENTER, KeyboardKey.KEY_TAB, KeyboardKey.KEY_BACKSPACE, KeyboardKey.KEY_DELETE,
        KeyboardKey.KEY_ESCAPE, KeyboardKey.KEY_UP, KeyboardKey.KEY_DOWN, KeyboardKey.KEY_LEFT, KeyboardKey.KEY_RIGHT,
        KeyboardKey.KEY_HOME, KeyboardKey.KEY_END, KeyboardKey.KEY_PAGE_UP, KeyboardKey.KEY_PAGE_DOWN, KeyboardKey.KEY_INSERT,
        KeyboardKey.KEY_MINUS, KeyboardKey.KEY_EQUAL, KeyboardKey.KEY_LEFT_BRACKET, KeyboardKey.KEY_RIGHT_BRACKET,
        KeyboardKey.KEY_BACKSLASH, KeyboardKey.KEY_SEMICOLON, KeyboardKey.KEY_APOSTROPHE, KeyboardKey.KEY_COMMA,
        KeyboardKey.KEY_PERIOD, KeyboardKey.KEY_SLASH, KeyboardKey.KEY_GRAVE,
        KeyboardKey.KEY_F1, KeyboardKey.KEY_F2, KeyboardKey.KEY_F3, KeyboardKey.KEY_F4, KeyboardKey.KEY_F5, KeyboardKey.KEY_F6,
        KeyboardKey.KEY_F7, KeyboardKey.KEY_F8, KeyboardKey.KEY_F9, KeyboardKey.KEY_F10, KeyboardKey.KEY_F11, KeyboardKey.KEY_F12,
    ];

    import std.array : appender;
    auto keys_to_check = appender!(int[]);
    for (int k = KeyboardKey.KEY_A; k <= KeyboardKey.KEY_Z; k++) keys_to_check.put(k);
    for (int k = KeyboardKey.KEY_ZERO; k <= KeyboardKey.KEY_NINE; k++) keys_to_check.put(k);
    foreach (k; special_keys) keys_to_check.put(k);

    GhosttyMods mods = get_ghostty_mods();

    // Check Ctrl+Shift+C (Copy) and Ctrl+Shift+V (Paste)
    if (mods == (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_SHIFT)) {
        if (IsKeyPressed(KeyboardKey.KEY_C) && selState.start && selState.end) {
            GhosttyGridRef ref_start;
            GhosttyGridRef start_snapshot;
            GhosttyGridRef end_snapshot;
            if (ghostty_tracked_grid_ref_snapshot(selState.start, &start_snapshot) == GHOSTTY_SUCCESS &&
                ghostty_tracked_grid_ref_snapshot(selState.end, &end_snapshot) == GHOSTTY_SUCCESS) {

                GhosttySelection sel;
                sel.start = start_snapshot;
                sel.end = end_snapshot;
                sel.rectangle = selState.isRectangular;

                GhosttyFormatterTerminalOptions fmt_opts;
                fmt_opts.size = GhosttyFormatterTerminalOptions.sizeof;
                fmt_opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
                fmt_opts.unwrap = true;
                fmt_opts.trim = true;
                fmt_opts.selection = &sel;

                GhosttyFormatter formatter;
                if (ghostty_formatter_terminal_new(null, &formatter, terminal, fmt_opts) == GHOSTTY_SUCCESS) {
                    ubyte* out_ptr;
                    size_t out_len;
                    if (ghostty_formatter_format_alloc(formatter, null, &out_ptr, &out_len) == GHOSTTY_SUCCESS) {
                        import std.string : fromStringz;
                        // The string might not be null terminated by ghostty, so we manually do it or copy it
                        char[] copiedText = new char[out_len + 1];
                        copiedText[0 .. out_len] = cast(char[])out_ptr[0 .. out_len];
                        copiedText[out_len] = '\0';

                        SetClipboardText(copiedText.ptr);

                        // we need to free the memory ghostty allocated
                        ghostty_free(null, out_ptr, out_len);
                    }
                    ghostty_formatter_free(formatter);
                }
            }
            return; // consume event
        }
        else if (IsKeyPressed(KeyboardKey.KEY_V)) {
            const(char)* clipboard = GetClipboardText();
            if (clipboard) {
                import core.stdc.string : strlen;
                pty_write(pty_fd, clipboard, strlen(clipboard));
            }
            return; // consume event
        }
    }

    foreach (rl_key; keys_to_check.data) {
        bool pressed  = IsKeyPressed(cast(KeyboardKey)rl_key);
        bool repeated = IsKeyPressedRepeat(cast(KeyboardKey)rl_key);
        bool released = IsKeyReleased(cast(KeyboardKey)rl_key);

        if (!pressed && !repeated && !released)
            continue;

        GhosttyKey gkey = raylib_key_to_ghostty(rl_key);
        if (gkey == GHOSTTY_KEY_UNIDENTIFIED)
            continue;

        GhosttyKeyAction action = released ? GHOSTTY_KEY_ACTION_RELEASE :
            pressed  ? GHOSTTY_KEY_ACTION_PRESS :
            GHOSTTY_KEY_ACTION_REPEAT;

        ghostty_key_event_set_key(event, gkey);
        ghostty_key_event_set_action(event, action);
        ghostty_key_event_set_mods(event, mods);

        uint ucp = raylib_key_unshifted_codepoint(rl_key);
        ghostty_key_event_set_unshifted_codepoint(event, ucp);

        GhosttyMods consumed = 0;
        if (ucp != 0 && (mods & GHOSTTY_MODS_SHIFT))
            consumed |= GHOSTTY_MODS_SHIFT;
        ghostty_key_event_set_consumed_mods(event, consumed);

        if (char_utf8_len > 0 && !released) {
            ghostty_key_event_set_utf8(event, char_utf8.ptr, char_utf8_len);
            char_utf8_len = 0;
        } else {
            ghostty_key_event_set_utf8(event, null, 0);
        }

        char[128] buf;
        size_t written = 0;
        GhosttyResult res = ghostty_key_encoder_encode(encoder, event, buf.ptr, buf.sizeof, &written);
        if (res == GHOSTTY_SUCCESS && written > 0) {
            pty_write(pty_fd, buf.ptr, written);
            char_utf8_len = 0;
        }
    }

    if (char_utf8_len > 0)
        pty_write(pty_fd, char_utf8.ptr, char_utf8_len);
}
