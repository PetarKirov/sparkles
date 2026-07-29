/**
Event synthesis for the GPU backend (`INP8`): raylib has no event queue — only
polled state — so this module derives the $(B edges) (press/release, motion,
wheel steps, typed characters, focus and resize changes) once per frame and
delivers them as shared `sparkles:input` events, in the toolkit's 0-based cell
coordinates.

The synthesizer is the one place raylib's polling idioms live; consumers see
only values. The pointer $(B grab) for drags that leave the window (`INP9`)
remains open — it needs a real windowing-system grab and is validated against
the end-to-end harness, not unit tests.
*/
module sparkles.ui_raylib.events;

import raylib;

import sparkles.input;

/**
Per-frame input synthesis. Construct once; call $(LREF RaylibEvents.poll) each
frame with the cells→pixels mapping (the same `cellW`/`cellH`/origin the canvas
paints with) and a sink receiving zero or more events.
*/
struct RaylibEvents
{
    private float lastX = -1, lastY = -1;
    private bool wasFocused = true;
    private bool wasInside = true;

    /**
    Synthesizes this frame's events into `sink`. Pointer positions are mapped
    from pixels to 0-based cells via `(px - originX) / cellW`; positions
    outside the window emit one `PointerAction.leave`.
    */
    void poll(Sink)(scope Sink sink, int cellW, int cellH,
        int originX = 0, int originY = 0) @system
    {
        // -- window state ------------------------------------------------
        if (IsWindowResized())
            sink(Event(ResizeEvent())); // zero size: the caller re-queries

        const focused = IsWindowFocused();
        if (focused != wasFocused)
        {
            wasFocused = focused;
            sink(Event(FocusEvent(focused: focused)));
        }

        // -- pointer -----------------------------------------------------
        const mp = GetMousePosition();
        const inside = mp.x >= 0 && mp.y >= 0
            && mp.x < GetScreenWidth() && mp.y < GetScreenHeight();
        const pos = Point(
            (cast(int) mp.x - originX) / (cellW > 0 ? cellW : 1),
            (cast(int) mp.y - originY) / (cellH > 0 ? cellH : 1));
        const mods = currentMods();

        if (!inside && wasInside)
            sink(Event(PointerEvent(action: PointerAction.leave, pos: pos)));
        wasInside = inside;

        static immutable buttons = [
            MouseButton.MOUSE_BUTTON_LEFT, MouseButton.MOUSE_BUTTON_MIDDLE,
            MouseButton.MOUSE_BUTTON_RIGHT,
        ];
        bool anyDown;
        foreach (i, rb; buttons)
        {
            const btn = cast(PointerButton) i;
            if (IsMouseButtonPressed(rb))
                sink(Event(PointerEvent(action: PointerAction.press,
                    button: btn, pos: pos, mods: mods)));
            if (IsMouseButtonReleased(rb))
                sink(Event(PointerEvent(action: PointerAction.release,
                    button: btn, pos: pos, mods: mods)));
            anyDown |= IsMouseButtonDown(rb);
        }

        if (inside && (mp.x != lastX || mp.y != lastY))
        {
            sink(Event(PointerEvent(
                action: anyDown ? PointerAction.drag : PointerAction.move,
                button: anyDown ? heldButton() : PointerButton.none,
                pos: pos, mods: mods)));
        }
        lastX = mp.x;
        lastY = mp.y;

        // -- wheel (web deltaY signs: up is negative) ----------------------
        const wheel = GetMouseWheelMoveV();
        if (wheel.y != 0 || wheel.x != 0)
            sink(Event(WheelEvent(
                dx: -cast(int) wheel.x, dy: -cast(int) wheel.y,
                pos: pos, mods: mods)));

        // -- keyboard ------------------------------------------------------
        for (int cp = GetCharPressed(); cp != 0; cp = GetCharPressed())
            sink(charEvent(cast(dchar) cp, mods));
        for (int k = GetKeyPressed(); k != 0; k = GetKeyPressed())
        {
            const key = namedKey(k);
            if (key != Key.none)
                sink(keyEvent(key, mods));
        }
    }

    private static Mods currentMods() @system
        => Mods(
            ctrl: IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL),
            alt: IsKeyDown(KeyboardKey.KEY_LEFT_ALT)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT),
            shift: IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT));

    private static PointerButton heldButton() @system
    {
        if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT))
            return PointerButton.left;
        if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_MIDDLE))
            return PointerButton.middle;
        if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_RIGHT))
            return PointerButton.right;
        return PointerButton.none;
    }
}

/// Maps raylib's named keys onto the shared `Key` vocabulary (printable input
/// arrives through `GetCharPressed` instead; unmapped keys are `Key.none`).
Key namedKey(int rk) @safe pure nothrow @nogc
{
    with (KeyboardKey) switch (rk)
    {
        case KEY_UP: return Key.up;
        case KEY_DOWN: return Key.down;
        case KEY_LEFT: return Key.left;
        case KEY_RIGHT: return Key.right;
        case KEY_HOME: return Key.home;
        case KEY_END: return Key.end;
        case KEY_PAGE_UP: return Key.pageUp;
        case KEY_PAGE_DOWN: return Key.pageDown;
        case KEY_INSERT: return Key.insert;
        case KEY_DELETE: return Key.delete_;
        case KEY_ENTER, KEY_KP_ENTER: return Key.enter;
        case KEY_TAB: return Key.tab;
        case KEY_BACKSPACE: return Key.backspace;
        case KEY_ESCAPE: return Key.escape;
        default:
            if (rk >= KEY_F1 && rk <= KEY_F12)
                return cast(Key)(Key.f1 + (rk - KEY_F1));
            return Key.none;
    }
}

@("ui_raylib.events.namedKeyMapping")
@safe pure nothrow @nogc
unittest
{
    with (KeyboardKey)
    {
        assert(namedKey(KEY_UP) == Key.up);
        assert(namedKey(KEY_ESCAPE) == Key.escape);
        assert(namedKey(KEY_F1) == Key.f1);
        assert(namedKey(KEY_F12) == Key.f12);
        assert(namedKey(KEY_A) == Key.none); // printable: GetCharPressed's job
    }
}
