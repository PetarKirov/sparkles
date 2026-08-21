/**
Wayland driver for the shared WSI conformance suite.

Every behavior assertion lives in `sparkles.wsi.conformance`; this driver
supplies what Wayland alone can: the integrated prepare-read step, a
maximize request as the compositor-driven resize (the compositor picks the
size, so the property checks change, not dimensions), and the keyboard
chord lane. Key injection is external — `scripts/verify-wayland-keys.sh`
chords through Xvfb into Weston's X11 backend — so the chord property is
gated on `$WSI_CONFORMANCE_KEYS`, and the driver then maps a throwaway shm
buffer under the native-I/O borrow, because compositors only grant keyboard
focus to mapped surfaces. `scripts/verify-wayland-weston.sh` runs the
chord-free lane against headless Weston.
*/
module wayland_hosted_smoke;

version (linux):

import core.stdc.stdlib : getenv;
import core.time : Duration, MonoTime, seconds;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.wsi;
import wayland_native : wl_display, wl_surface,
    wsi_wayland_test_attach_shm_buffer;

private struct WaylandHooks
{
    WaylandWsi* wsi;
    DefaultLoop* loop;
    WindowId id;
    bool chordEnabled;

    enum uint chordShiftCode = 42; // evdev KEY_LEFTSHIFT
    enum uint chordKeyCode = 30; // evdev KEY_A
    enum bool expectFocusEvent = true;
    enum bool resizeExact = false;
    enum chordDeadline = 20.seconds;

    void step(Duration timeout)
    {
        // timedOut is a legitimate quiet outcome while waiting on the
        // external injector; the conformance deadline is the failure.
        wsi.runIntegratedOnce(*loop, timeout).value;
    }

    void onWindowReady(WindowId ready)
    {
        id = ready;
        if (!chordEnabled)
            return;
        auto handles = wsi.nativeHandles(id).value;
        auto display = handles.display.match!(
            (in WaylandDisplayHandle handle) => cast(wl_display*) handle.display,
            (_) => null);
        auto surface = handles.window.match!(
            (in WaylandWindowHandle handle) => cast(wl_surface*) handle.surface,
            (_) => null);
        assert(display !is null && surface !is null);
        assert(!wsi.beginNativeIo().hasError);
        assert(wsi_wayland_test_attach_shm_buffer(display, surface,
            480, 320) == 0);
        assert(!wsi.endNativeIo().hasError);
    }

    void checkHandles(in NativeHandles handles)
    {
        assert(handles.display.match!(
            (in WaylandDisplayHandle handle) => handle.display !is null,
            (_) => false));
        assert(handles.window.match!(
            (in WaylandWindowHandle handle) => handle.surface !is null,
            (_) => false));
    }

    void requestResize(uint, uint)
    {
        assert(!wsi.setMaximized(id, true).hasError);
    }

    void injectChord()
    {
        // External: the verify script's XTEST injector chords repeatedly
        // through Weston until the property observes it.
    }
}

int main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    WaylandWsi wsi;
    auto opened = WaylandWsi.open(wsi, loop);
    if (opened.hasError && opened.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no Wayland compositor");
        return 0;
    }
    assert(!opened.hasError);

    const bootstrapStart = MonoTime.currTime;
    while (!wsi.bootstrapComplete)
    {
        assert(wsi.runIntegratedOnce(loop, 2.seconds).value
            == RunStatus.dispatched);
        assert(MonoTime.currTime - bootstrapStart < 2.seconds);
    }
    assert(wsi.canCreateWindows);

    auto hooks = WaylandHooks(&wsi, &loop,
        chordEnabled: getenv("WSI_CONFORMANCE_KEYS") !is null);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi Wayland conformance");
    writeln("ok: Wayland WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");
    return 0;
}
