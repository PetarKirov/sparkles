/**
X11 driver for the shared WSI conformance suite.

Every behavior assertion lives in `sparkles.wsi.conformance`; this driver
only supplies what X11 alone can: the integrated Event Horizon step, XCB
resize/close requests, and an XTEST-injected key chord (X keycodes are
evdev + 8). Run through `scripts/verify-x11-xvfb.sh`.
*/
module x11_hosted_smoke;

version (linux):

import core.time : Duration;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.wsi;
import xcb_native : xcb_connection_t;
import xcb_test_input : focusWindow, resizeWindow, sendClose, sendKey;

private struct X11Hooks
{
    X11Wsi* wsi;
    DefaultLoop* loop;
    xcb_connection_t* connection;
    uint window;

    enum uint chordShiftCode = 50; // X keycode: KEY_LEFTSHIFT + 8
    enum uint chordKeyCode = 38; // X keycode: KEY_A + 8
    enum bool expectFocusEvent = true;

    void step(Duration timeout)
    {
        wsi.runIntegratedOnce(*loop, timeout).value;
    }

    void onWindowReady(WindowId id)
    {
        auto handles = wsi.nativeHandles(id).value;
        connection = handles.display.match!(
            (in X11DisplayHandle handle)
                => cast(xcb_connection_t*) handle.connection,
            (_) => null);
        window = handles.window.match!(
            (in X11WindowHandle handle) => handle.window,
            (_) => 0u);
        assert(connection !is null && window != 0);
    }

    void checkHandles(in NativeHandles handles)
    {
        assert(handles.display.match!(
            (in X11DisplayHandle handle) => handle.connection !is null,
            (_) => false));
        assert(handles.window.match!(
            (in X11WindowHandle handle) => handle.window != 0,
            (_) => false));
    }

    void requestResize(uint width, uint height)
    {
        assert(resizeWindow(connection, window, width, height) == 0);
    }

    void requestClose()
    {
        assert(sendClose(connection, window) == 0);
    }

    void injectChord()
    {
        assert(focusWindow(connection, window) == 0);
        assert(sendKey(connection, chordShiftCode, true) == 0);
        assert(sendKey(connection, chordKeyCode, true) == 0);
        assert(sendKey(connection, chordKeyCode, false) == 0);
        assert(sendKey(connection, chordShiftCode, false) == 0);
    }
}

int main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    X11Wsi wsi;
    auto opened = X11Wsi.open(wsi);
    if (opened.hasError && opened.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no X11 display");
        return 0;
    }
    assert(!opened.hasError);
    assert(!wsi.attach(loop).hasError);

    auto hooks = X11Hooks(&wsi, &loop);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi X11 conformance");
    writeln("ok: X11 WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");
    return 0;
}
