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
    /**
    The touch recogniser (`IXB8`). Inert where there is no touchscreen —
    `GetTouchPointCount()` is 0, so the arm below never feeds it — which is
    why this needs no `version (Android)`.

    Its config is public so a host can scale `slopPx`/`cellH` to the rendered
    text size; the recognition policy itself is `sparkles:input`'s.
    */
    GestureRecognizer gestures;

    /**
    What this window's input actually offers (`IXB10`/`TGT5`).

    A raylib window is a mouse target on the desktop and a touch target on a
    phone, and the difference is not observable until a contact arrives — so
    this is a $(B declaration the host sets), defaulting to the desktop case.
    An Android entry point assigns `touchPointer`.

    Declaring it beats branching on it: components ask the capability rather
    than the platform, so the knowledge lives in one assignment instead of
    spreading as `version (Android)` through everything hover-driven.
    */
    InputCapabilities capabilities = mousePointer;

    private float lastX = -1, lastY = -1;
    private bool wasFocused = true;
    private bool wasInside = true;
    // Fractional wheel deltas accumulate here until a whole step is due
    // (high-resolution wheels/trackpads report sub-step values raylib
    // would otherwise truncate to zero) — M14.
    private float wheelAccumX = 0, wheelAccumY = 0;
    private PointF lastTouch;

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

        // The explicit raylib→toolkit button map (never an index cast:
        // PointerButton's `none` sits mid-enum, and raylib's back/forward
        // ids are not contiguous with the first three) — M14.
        static immutable buttons = [
            [MouseButton.MOUSE_BUTTON_LEFT, PointerButton.left],
            [MouseButton.MOUSE_BUTTON_MIDDLE, PointerButton.middle],
            [MouseButton.MOUSE_BUTTON_RIGHT, PointerButton.right],
            [MouseButton.MOUSE_BUTTON_BACK, PointerButton.back],
            [MouseButton.MOUSE_BUTTON_FORWARD, PointerButton.forward],
        ];
        bool anyDown;
        foreach (pair; buttons)
        {
            const rb = cast(MouseButton) pair[0];
            const btn = cast(PointerButton) pair[1];
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
        // Fractional deltas accumulate to whole NOTCHES (M14) — a slow
        // trackpad scroll still moves, a fast flick loses nothing — and the
        // notch→cells multiplication happens here, because this is the
        // producer (`INP12`). Accumulating in notches rather than cells keeps
        // the emitted step identical to what the consumers used to compute
        // for themselves; scrolling by a fraction of a notch is a separate
        // question from who owns the multiplier.
        const wheel = GetMouseWheelMoveV();
        const dx = wheelSteps(wheelAccumX, -wheel.x) * linesPerNotch;
        const dy = wheelSteps(wheelAccumY, -wheel.y) * linesPerNotch;
        if (dx != 0 || dy != 0)
            sink(Event(WheelEvent(dx: dx, dy: dy, pos: pos, mods: mods)));

        // -- touch ---------------------------------------------------------
        // raylib maps the first contact onto the mouse, which is an adapter
        // idiom the app should never learn (IXR19). Feed the recogniser raw
        // device-space samples and drain whatever it resolves: taps arrive as
        // press/release, drags as wheel steps, long-press and pinch as
        // gestures — all in the shared vocabulary.
        {
            const contacts = GetTouchPointCount();
            if (contacts >= 2)
            {
                const p0 = GetTouchPosition(0);
                const p1 = GetTouchPosition(1);
                gestures.setContacts(cast(ubyte) contacts,
                    PointF(p0.x, p0.y), PointF(p1.x, p1.y));
            }
            else if (contacts == 1)
            {
                const p0 = GetTouchPosition(0);
                lastTouch = PointF(p0.x, p0.y);
                gestures.setContacts(1, lastTouch, PointF());
                gestures.pointer(0, true, lastTouch);
            }
            else
            {
                gestures.setContacts(0, PointF(), PointF());
                gestures.pointer(0, false, lastTouch);
            }

            gestures.tick(GetFrameTime() * 1000);

            // The recogniser works in device space (thresholds are physical);
            // the adapter owns the conversion to cells (GST4). Gesture and tap
            // positions carry the ANCHOR — a tap acts where it began.
            const anchor = gestures.anchor();
            const anchorCell = Point(
                (cast(int) anchor.x - originX) / (cellW > 0 ? cellW : 1),
                (cast(int) anchor.y - originY) / (cellH > 0 ? cellH : 1));
            for (auto e = gestures.next(); !isNoEvent(e); e = gestures.next())
                sink(withPosition(e, anchorCell, mods));
        }

        // -- keyboard ------------------------------------------------------
        for (int cp = GetCharPressed(); cp != 0; cp = GetCharPressed())
            sink(charEvent(cast(dchar) cp, mods));
        for (int k = GetKeyPressed(); k != 0; k = GetKeyPressed())
        {
            const key = namedKey(k);
            if (key != Key.none)
                sink(keyEvent(key, mods));
        }
        // Named-key auto-repeat (M14): raylib reports OS repeats only
        // through IsKeyPressedRepeat (chars repeat natively through
        // GetCharPressed), so held navigation/editing keys keep firing.
        static immutable int[] repeatable = [
            KeyboardKey.KEY_UP, KeyboardKey.KEY_DOWN, KeyboardKey.KEY_LEFT,
            KeyboardKey.KEY_RIGHT, KeyboardKey.KEY_PAGE_UP,
            KeyboardKey.KEY_PAGE_DOWN, KeyboardKey.KEY_HOME,
            KeyboardKey.KEY_END, KeyboardKey.KEY_BACKSPACE,
            KeyboardKey.KEY_DELETE, KeyboardKey.KEY_ENTER,
            KeyboardKey.KEY_TAB,
        ];
        foreach (rk; repeatable)
            if (IsKeyPressedRepeat(rk))
                sink(keyEvent(namedKey(rk), mods));
    }

    private static Mods currentMods() @system
        => Mods(
            ctrl: IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL),
            alt: IsKeyDown(KeyboardKey.KEY_LEFT_ALT)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT),
            shift: IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT)
                || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT));

    // The recogniser emits positions as a placeholder; the adapter stamps the
    // cell-space anchor and the live modifier state on the way out.
    private static Event withPosition(Event e, Point at, Mods m) @safe pure nothrow
        => e.match!(
            (PointerEvent p) => Event(PointerEvent(
                action: p.action, button: p.button, pos: at, mods: m)),
            (WheelEvent w) => Event(WheelEvent(
                dx: w.dx, dy: w.dy, pos: at, mods: m, precise: w.precise)),
            (GestureEvent g) => Event(GestureEvent(
                gesture: g.gesture, pos: at, scale: g.scale, mods: m)),
            (ref other) => Event(other),
        );

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

/**
Folds a (possibly fractional) wheel delta into `accum` and returns the whole
steps now due, keeping the remainder — pure, so testable without a window
(M14).

The unit is $(B notches), not cells: `poll` multiplies the result by
`linesPerNotch` before it reaches a `WheelEvent`, because the producer owns
that multiplication (`INP12`). Anything reading this directly is one step
short of a scroll distance.
*/
int wheelSteps(ref float accum, float delta) @safe pure nothrow @nogc
{
    accum += delta;
    const steps = cast(int) accum;
    accum -= steps;
    return steps;
}

@("ui_raylib.events.wheelStepsAccumulation")
@safe pure nothrow @nogc
unittest
{
    float a = 0;
    // Sub-step deltas accumulate; the whole step fires once, remainder kept.
    assert(wheelSteps(a, 0.4f) == 0);
    assert(wheelSteps(a, 0.4f) == 0);
    assert(wheelSteps(a, 0.4f) == 1);
    assert(a > 0.19f && a < 0.21f);
    // A fast flick delivers every whole step at once.
    assert(wheelSteps(a, 3.0f) == 3);
    // Opposite-direction deltas cancel the remainder first.
    float b = 0;
    assert(wheelSteps(b, -0.6f) == 0);
    assert(wheelSteps(b, -0.6f) == -1);

    // The unit is notches: one notch is `linesPerNotch` cells of scroll, and
    // `poll` applies that factor. Pinned because the two conventions merged
    // from opposite directions — M14 accumulates notches, INP12 moved the
    // multiplier to the producer — and a consumer that multiplied again (or
    // a producer that stopped) would silently scroll by the wrong distance.
    float c = 0;
    assert(wheelSteps(c, 1.0f) * linesPerNotch == linesPerNotch);
    static assert(linesPerNotch > 1);
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
        // Android's hardware/gesture keys. raylib records both and eats them
        // from the OS, so an app that maps them owns the back gesture.
        case KEY_BACK: return Key.back;
        case KEY_MENU: return Key.menu;
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
        // The Android hardware keys. `back` is what `isDismiss` equates with
        // Escape, so an app writes one dismiss binding for every target.
        assert(namedKey(KEY_BACK) == Key.back);
        assert(namedKey(KEY_MENU) == Key.menu);
        assert(isDismiss(KeyEvent(namedKey(KEY_BACK))));
        assert(isDismiss(KeyEvent(namedKey(KEY_ESCAPE))));
    }
}
