/**
The raylib mouse as `sparkles:input` events: a bridge for a window whose
host does not yet deliver pointer events in pixels to the pane under the
pointer. Each frame it reads what raylib polled — position, buttons, wheel,
modifiers — and emits what changed, in pane pixels, to the terminal's event
handlers (`sparkles.terminal_view.pointer`).
*/
module sparkles.terminal_view.raylib_input;

import raylib : GetMouseDelta, GetMousePosition, GetMouseWheelMove, IsKeyDown,
    IsMouseButtonDown, IsMouseButtonPressed, IsMouseButtonReleased, KeyboardKey, MouseButton;

import sparkles.input : Mods, Point, PointerAction, PointerButton, PointerEvent, WheelEvent;

/// The modifiers raylib reports held.
Mods polledMods() @system nothrow @nogc
    => Mods(
        ctrl: IsKeyDown(KeyboardKey.KEY_LEFT_CONTROL) || IsKeyDown(KeyboardKey.KEY_RIGHT_CONTROL),
        alt: IsKeyDown(KeyboardKey.KEY_LEFT_ALT) || IsKeyDown(KeyboardKey.KEY_RIGHT_ALT),
        shift: IsKeyDown(KeyboardKey.KEY_LEFT_SHIFT) || IsKeyDown(KeyboardKey.KEY_RIGHT_SHIFT),
        super_: IsKeyDown(KeyboardKey.KEY_LEFT_SUPER) || IsKeyDown(KeyboardKey.KEY_RIGHT_SUPER),
    );

/**
This frame's mouse, relative to a pane at `originX`, `originY`: motion
first (a `drag` while the left, right or middle button is held, else a
`move`), then each button pressed or released, then the wheel. The side
buttons are `back` (raylib's side and back) and `forward` (extra and
forward).
*/
void pollPointer(float originX, float originY, scope void delegate(in PointerEvent) onPointer,
    scope void delegate(in WheelEvent) onWheel) @system
{
    const mods = polledMods();
    const raw = GetMousePosition();
    const pos = Point(cast(int)(raw.x - originX), cast(int)(raw.y - originY));

    static immutable MouseButton[3] main = [MouseButton.MOUSE_BUTTON_LEFT,
        MouseButton.MOUSE_BUTTON_RIGHT, MouseButton.MOUSE_BUTTON_MIDDLE];
    static immutable PointerButton[3] mainAs = [PointerButton.left, PointerButton.right,
        PointerButton.middle];

    const delta = GetMouseDelta();
    if (delta.x != 0 || delta.y != 0)
    {
        auto motion = PointerEvent(action: PointerAction.move, pos: pos, mods: mods);
        foreach (i, b; main)
            if (IsMouseButtonDown(b))
            {
                motion = PointerEvent(action: PointerAction.drag, button: mainAs[i], pos: pos,
                    mods: mods);
                break;
            }
        onPointer(motion);
    }

    static immutable MouseButton[7] all = [MouseButton.MOUSE_BUTTON_LEFT,
        MouseButton.MOUSE_BUTTON_RIGHT, MouseButton.MOUSE_BUTTON_MIDDLE,
        MouseButton.MOUSE_BUTTON_SIDE, MouseButton.MOUSE_BUTTON_EXTRA,
        MouseButton.MOUSE_BUTTON_FORWARD, MouseButton.MOUSE_BUTTON_BACK];
    static immutable PointerButton[7] allAs = [PointerButton.left, PointerButton.right,
        PointerButton.middle, PointerButton.back, PointerButton.forward,
        PointerButton.forward, PointerButton.back];
    foreach (i, b; all)
    {
        if (IsMouseButtonPressed(b))
            onPointer(PointerEvent(action: PointerAction.press, button: allAs[i], pos: pos,
                mods: mods));
        else if (IsMouseButtonReleased(b))
            onPointer(PointerEvent(action: PointerAction.release, button: allAs[i], pos: pos,
                mods: mods));
    }

    // A notch up is three rows up (`linesPerNotch`), negative as on the web.
    const wheel = GetMouseWheelMove();
    if (wheel != 0)
        onWheel(WheelEvent(dy: wheel > 0 ? -3 : 3, pos: pos, mods: mods, fdy: -wheel * 3));
}
