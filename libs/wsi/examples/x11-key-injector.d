/**
XTEST key-chord injector for compositor-forwarding tests.

Connects to `$DISPLAY`, parks the pointer over the target (PointerRoot focus
routes core key events to the window under it when no window manager runs),
and injects one left-shift-chorded `a` press/release. The Wayland keys smoke
observes the chord arriving back through the compositor as `wl_keyboard`
events.
*/
module x11_key_injector;

version (linux):

import xcb_native : wsi_xcb_bootstrap, wsi_xcb_connect, wsi_xcb_disconnect,
    wsi_xcb_send_key, wsi_xcb_warp_pointer;

int main()
{
    wsi_xcb_bootstrap bootstrap;
    int nativeError;
    auto connection = wsi_xcb_connect(&bootstrap, &nativeError);
    if (connection is null)
        return 2;
    scope (exit) wsi_xcb_disconnect(connection);

    if (wsi_xcb_warp_pointer(connection, &bootstrap, 200, 200) != 0)
        return 3;

    // X keycodes are evdev + 8: 50 = KEY_LEFTSHIFT (42), 38 = KEY_A (30).
    static immutable ubyte[2][4] chord = [[50, 1], [38, 1], [38, 0], [50, 0]];
    foreach (step; chord)
        if (wsi_xcb_send_key(connection, step[0], step[1]) != 0)
            return 4;
    return 0;
}
