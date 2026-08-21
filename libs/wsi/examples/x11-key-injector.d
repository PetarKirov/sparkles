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
import xcb_test_input : sendButton, sendKey, warpPointer;

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

    // Hold leg, gated on the driver's signal files: once the hold gate
    // exists (and the lifecycle has not already run), press the key, keep
    // it down until the release gate appears — the client observed its
    // synthesized repeats — then release. The whole lifecycle lives inside
    // one injector run so the outer re-injection loop's chord replays
    // (skipped while the key is held) can never cancel the repeat.
    {
        import core.stdc.stdlib : getenv;
        import core.thread : Thread;
        import core.time : msecs;
        import std.file : exists, write;
        import std.string : fromStringz;

        auto holdGate = getenv("WSI_HOLD_GO");
        auto releaseGate = getenv("WSI_HOLD_RELEASE_GO");
        if (holdGate !is null && releaseGate !is null
            && exists(holdGate.fromStringz))
        {
            auto done = holdGate.fromStringz.idup ~ ".done";
            if (!exists(done))
            {
                if (sendKey(connection, 38, true) != 0)
                    return 7;
                scope (exit) sendKey(connection, 38, false);
                foreach (_; 0 .. 600)
                {
                    if (exists(releaseGate.fromStringz))
                        break;
                    Thread.sleep(25.msecs);
                }
                write(done, "done");
                return 0;
            }
        }
    }

    // X keycodes are evdev + 8: 50 = KEY_LEFTSHIFT (42), 38 = KEY_A (30).
    static immutable ubyte[2][4] chord = [[50, 1], [38, 1], [38, 0], [50, 0]];
    foreach (step; chord)
        if (sendKey(connection, step[0], step[1] != 0) != 0)
            return 4;

    // Pointer leg, gated on the driver's signal file: Weston's
    // click-to-activate binding crashes on a click over the bare desktop,
    // so clicks start only once the conformance click property is running —
    // after the resize property maximized the client surface across the
    // output. Two warps force motion even when the position repeats.
    {
        import core.stdc.stdlib : getenv;
        import std.string : fromStringz;
        import std.file : exists;

        auto gate = getenv("WSI_POINTER_GO");
        if (gate is null || !exists(gate.fromStringz))
            return 0;
    }
    const root = screens.data.root;
    if (warpPointer(connection, root, 470, 290) != 0
        || warpPointer(connection, root, 480, 300) != 0)
        return 5;
    static immutable ubyte[2][4] clicks =
        [[1, 1], [1, 0], [5, 1], [5, 0]];
    foreach (step; clicks)
        if (sendButton(connection, step[0], step[1] != 0) != 0)
            return 6;
    return 0;
}
