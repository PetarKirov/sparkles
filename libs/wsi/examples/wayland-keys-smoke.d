/**
Native Wayland keyboard delivery smoke test.

Run through `scripts/verify-wayland-keys.sh`: Weston's X11 backend inside
Xvfb forwards an XTEST-injected chord as real `wl_keyboard` events, so the
whole seat path — capability discovery, keymap fd handling, enter focus,
modifier state, and evdev key translation — runs against a live compositor
with no window manager and no desktop session.
*/
module wayland_keys_smoke;

version (linux):

import core.time : MonoTime, seconds;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.input.events : KeyAction;
import sparkles.wsi;
import wayland_native : wl_display, wl_surface,
    wsi_wayland_test_attach_shm_buffer;

int main()
{
    DefaultLoop loop;
    auto openedLoop = DefaultLoop.create(loop, LoopConfig());
    assert(!openedLoop.hasError);

    WaylandWsi wsi;
    auto openedWsi = WaylandWsi.open(wsi, loop);
    if (openedWsi.hasError
        && openedWsi.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no Wayland compositor");
        return 0;
    }
    assert(!openedWsi.hasError);

    const bootstrapStart = MonoTime.currTime;
    while (!wsi.bootstrapComplete)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        assert(MonoTime.currTime - bootstrapStart < 2.seconds);
    }
    assert(wsi.canCreateWindows);

    WindowConfig config;
    assert(config.title.assign("sparkles:wsi Wayland keys smoke"));
    config.logicalSize = LogicalSize(480, 320);
    auto created = wsi.createWindow(config);
    assert(created.hasValue);
    auto id = created.value;

    bool ready;
    ulong lastSequence;
    const readyStart = MonoTime.currTime;
    while (!ready)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        auto drained = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            if (event.window == id)
                event.payload.match!(
                    (in ReadyEvent _) { ready = true; },
                    (_) {});
        });
        assert(drained.hasValue);
        assert(MonoTime.currTime - readyStart < 2.seconds);
    }

    // Keyboard focus only reaches mapped surfaces, so attach a throwaway
    // shm buffer the way a renderer would: under the native-I/O borrow.
    auto handles = wsi.nativeHandles(id);
    assert(handles.hasValue);
    auto display = handles.value.display.match!(
        (in WaylandDisplayHandle handle) => cast(wl_display*) handle.display,
        (_) => null);
    auto surface = handles.value.window.match!(
        (in WaylandWindowHandle handle) => cast(wl_surface*) handle.surface,
        (_) => null);
    assert(display !is null && surface !is null);
    assert(!wsi.beginNativeIo().hasError);
    assert(wsi_wayland_test_attach_shm_buffer(display, surface, 480, 320) == 0);
    assert(!wsi.endNativeIo().hasError);

    // evdev codes as the compositor forwards them (X keycode - 8).
    enum leftShift = 42;
    enum keyA = 30;
    bool focused;
    bool shiftLeft;
    bool chordedPress;
    bool releaseSeen;
    const deadline = MonoTime.currTime + 20.seconds;
    while (!(shiftLeft && chordedPress && releaseSeen))
    {
        // A quiet 2s window is fine — the injector chords repeatedly and the
        // compositor may still be granting focus; only the deadline fails.
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && (step.value == RunStatus.dispatched
            || step.value == RunStatus.timedOut));
        auto drained = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            if (event.window != id)
                return;
            event.payload.match!(
                (in FocusChangedEvent value) { focused |= value.focused; },
                (in KeyboardEvent value) {
                    if (value.physical.nativeCode == leftShift
                        && value.action == KeyAction.press)
                        shiftLeft = value.location == KeyLocation.left;
                    if (value.physical.nativeCode == keyA)
                    {
                        assert(value.location == KeyLocation.standard);
                        if (value.action == KeyAction.press)
                            chordedPress |= value.modifiers.shift;
                        else if (value.action == KeyAction.release)
                            releaseSeen = true;
                    }
                },
                (_) {});
        });
        assert(drained.hasValue);
        assert(MonoTime.currTime < deadline,
            "no keyboard chord arrived from the compositor");
    }
    assert(focused, "keyboard enter never granted focus");

    writeln("ok: Wayland keyboard chord delivered through the compositor");
    return 0;
}
