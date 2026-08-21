/**
XTEST key-chord injector for compositor-forwarding tests.

Connects to `$DISPLAY`, parks the pointer over the target (PointerRoot focus
routes core key events to the window under it when no window manager runs),
and injects one left-shift-chorded `a` press/release. The Wayland conformance
driver observes the chord arriving back through the compositor as
`wl_keyboard` events.
*/
module x11_key_injector;

version (linux):

import xcb_native;
import xcb_test_input : sendKey, warpPointer;

int main()
{
    int screenIndex;
    auto connection = xcb_connect(null, &screenIndex);
    if (connection is null || xcb_connection_has_error(connection) != 0)
        return 2;
    scope (exit) xcb_disconnect(connection);

    auto screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
    foreach (_; 0 .. screenIndex)
    {
        if (screens.rem == 0)
            break;
        xcb_screen_next(&screens);
    }
    if (screens.rem == 0)
        return 2;
    if (warpPointer(connection, screens.data.root, 200, 200) != 0)
        return 3;

    // X keycodes are evdev + 8: 50 = KEY_LEFTSHIFT (42), 38 = KEY_A (30).
    static immutable ubyte[2][4] chord = [[50, 1], [38, 1], [38, 0], [50, 0]];
    foreach (step; chord)
        if (sendKey(connection, step[0], step[1] != 0) != 0)
            return 4;
    return 0;
}
