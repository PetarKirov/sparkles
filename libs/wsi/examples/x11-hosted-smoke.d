/** Native XCB lifecycle + Event Horizon foreign-fd smoke test. */
module x11_hosted_smoke;

version (linux):

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion;
import sparkles.input.events : KeyAction;
import sparkles.wsi;
import xcb_native : wsi_xcb_focus_window, wsi_xcb_resize_window,
    wsi_xcb_send_close, wsi_xcb_send_key;

private __gshared X11Wsi* wrongThreadWsi;
private __gshared WsiErrorKind wrongThreadKind;

private void timerComplete(void* context, ref Completion completion)
    nothrow @nogc
{
    *cast(bool*) context = completion.res == 0;
}

int main()
{
    DefaultLoop loop;
    auto openedLoop = DefaultLoop.create(loop, LoopConfig());
    assert(!openedLoop.hasError);

    auto armed = loop.waker();
    assert(armed.hasValue);
    auto waker = armed.value;

    X11Wsi wsi;
    auto openedWsi = X11Wsi.open(wsi);
    if (openedWsi.hasError
        && openedWsi.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no X11 display");
        return 0;
    }
    assert(!openedWsi.hasError);

    WindowConfig config;
    assert(config.title.assign("sparkles:wsi X11 smoke"));
    config.logicalSize = LogicalSize(480, 320);
    auto created = wsi.createWindow(config);
    assert(created.hasValue);
    auto id = created.value;

    bool ready;
    bool exposed;
    bool frameReady;
    ulong lastSequence;
    auto drain = () {
        auto result = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            event.payload.match!(
                (in ReadyEvent value) {
                    ready = value.metrics.physicalSize == PhysicalSize(480, 320);
                },
                (in ExposedEvent _) { exposed = true; },
                (in FrameReadyEvent _) { frameReady = true; },
                (_) {});
        });
        assert(result.hasValue);
    };
    drain();
    assert(ready);

    wrongThreadWsi = &wsi;
    auto wrongThread = new Thread({
        auto result = wrongThreadWsi.pumpEvents();
        if (result.hasError)
            wrongThreadKind = result.error.kind;
    });
    wrongThread.start();
    wrongThread.join();
    assert(wrongThreadKind == WsiErrorKind.wrongThread);
    wrongThreadWsi = null;

    auto queried = wsi.nativeHandles(id);
    assert(queried.hasValue);
    void* connection = queried.value.display.match!(
        (in X11DisplayHandle handle) => cast(void*) handle.connection,
        (_) => null);
    uint window = queried.value.window.match!(
        (in X11WindowHandle handle) => handle.window,
        (_) => 0);
    assert(connection !is null && window != 0);

    assert(!wsi.attach(loop).hasError);
    assert(wsi_xcb_resize_window(connection, window, 640, 480) == 0);
    bool resized;
    const resizeStart = MonoTime.currTime;
    while (!resized)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        auto result = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            event.payload.match!(
                (in SurfaceMetricsChangedEvent metrics) {
                    resized |= metrics.metrics.physicalSize
                        == PhysicalSize(640, 480);
                },
                (in ExposedEvent _) { exposed = true; },
                (in FrameReadyEvent _) { frameReady = true; },
                (_) {});
        });
        assert(result.hasValue);
        assert(MonoTime.currTime - resizeStart < 2.seconds);
    }

    // A shift-chorded key press through the real server: XTEST delivers to
    // the focused window, the state mask is pre-event, and left/right
    // identity comes from the evdev keycode itself.
    assert(wsi_xcb_focus_window(connection, window) == 0);
    enum leftShift = 50;
    enum keyA = 38;
    assert(wsi_xcb_send_key(connection, leftShift, 1) == 0);
    assert(wsi_xcb_send_key(connection, keyA, 1) == 0);
    assert(wsi_xcb_send_key(connection, keyA, 0) == 0);
    assert(wsi_xcb_send_key(connection, leftShift, 0) == 0);
    uint keyEvents;
    bool shiftedPress;
    bool releaseSeen;
    bool shiftLeft;
    const keysStart = MonoTime.currTime;
    while (keyEvents < 4)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        auto result = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            event.payload.match!(
                (in KeyboardEvent value) {
                    ++keyEvents;
                    if (value.physical.nativeCode == leftShift
                        && value.action == KeyAction.press)
                        shiftLeft = value.location == KeyLocation.left;
                    if (value.physical.nativeCode == keyA)
                    {
                        assert(value.location == KeyLocation.standard);
                        if (value.action == KeyAction.press)
                            shiftedPress = value.modifiers.shift;
                        else if (value.action == KeyAction.release)
                            releaseSeen = true;
                    }
                },
                (_) {});
        });
        assert(result.hasValue);
        assert(MonoTime.currTime - keysStart < 2.seconds);
    }
    assert(shiftLeft && shiftedPress && releaseSeen);

    bool timerFired;
    auto timer = loop.submitAfter(25.msecs, &timerComplete, &timerFired);
    assert(timer.hasValue);
    auto worker = new Thread({
        Thread.sleep(10.msecs);
        waker.wake();
    });
    worker.start();
    const started = MonoTime.currTime;
    while (!timerFired || !frameReady)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        drain();
    }
    worker.join();
    assert(exposed && MonoTime.currTime - started < 2.seconds);

    assert(wsi_xcb_send_close(connection, window) == 0);
    bool closeRequested;
    while (!closeRequested)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        auto result = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            event.payload.match!(
                (in CloseRequestedEvent _) { closeRequested = true; },
                (_) {});
        });
        assert(result.hasValue);
    }

    assert(!wsi.destroyWindow(id).hasError);
    bool destroyed;
    auto destroyedDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in DestroyedEvent _) { destroyed = true; },
            (_) {});
    });
    assert(destroyedDrain.hasValue && destroyed);

    writeln("ok: XCB window + keys + Event Horizon timer/waker on one fd loop");
    return 0;
}
