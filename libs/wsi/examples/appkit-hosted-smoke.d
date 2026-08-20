/**
AppKit lifecycle + Event Horizon hosted-wait smoke test.

Build and run on macOS through `scripts/verify-appkit-macos.sh`. The bounded
test creates a real NSWindow, observes first metrics/draw/resize/close, checks
the typed handles and main-thread rule, and drives a kqueue timer plus a
foreign-thread waker through AppKit's one CFRunLoop wait.
*/
module appkit_hosted_smoke;

version (OSX):

import core.attribute : selector;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion;
import sparkles.wsi;

private extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    void* objc_autoreleasePoolPush();
    void objc_autoreleasePoolPop(void* pool);
}

private extern (C) struct NSSize
{
    double width;
    double height;
}

extern (Objective-C):

private extern class NSObject
{
}

private extern class NSWindow : NSObject
{
    void setContentSize(NSSize size) @selector("setContentSize:");
    void performClose(NSObject sender) @selector("performClose:");
}

extern (D):

private __gshared AppKitWsi* wrongThreadWsi;
private __gshared WsiErrorKind wrongThreadKind;

private void timerComplete(void* context, ref Completion completion)
    nothrow @nogc
{
    *cast(bool*) context = completion.res == 0;
}

int main()
{
    if (CGMainDisplayID() == 0)
    {
        writeln("SKIP: no macOS WindowServer");
        return 0;
    }

    auto pool = objc_autoreleasePoolPush();
    scope (exit) objc_autoreleasePoolPop(pool);

    DefaultLoop loop;
    auto openedLoop = DefaultLoop.create(loop, LoopConfig());
    assert(!openedLoop.hasError);
    scope (exit) loop.destroy();

    auto armed = loop.waker();
    assert(armed.hasValue);
    auto waker = armed.value;

    AppKitWsi wsi;
    auto openedWsi = AppKitWsi.open(wsi);
    assert(!openedWsi.hasError);
    scope (exit) cast(void) wsi.close();

    WindowConfig config;
    assert(config.title.assign("sparkles:wsi AppKit smoke"));
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
                    ready = value.metrics.logicalSize.width == 480
                        && value.metrics.logicalSize.height == 320
                        && value.metrics.physicalSize.width > 0
                        && value.metrics.scale.valid;
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
    auto nativeWindow = queried.value.window.match!(
        (in AppKitWindowHandle handle) => cast(NSWindow) handle.window,
        (_) => cast(NSWindow) null);
    assert(nativeWindow !is null);

    nativeWindow.setContentSize(NSSize(640, 480));
    bool resized;
    auto resizeDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in SurfaceMetricsChangedEvent metrics) {
                resized |= metrics.metrics.logicalSize.width == 640
                    && metrics.metrics.logicalSize.height == 480
                    && metrics.metrics.physicalSize.width >= 640;
            },
            (_) {});
    });
    assert(resizeDrain.hasValue && resized);

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
        auto step = loop.runHostedOnce(wsi, 5.seconds);
        assert(step.hasValue);
        assert(step.value == RunStatus.dispatched);
        drain();
    }
    worker.join();
    assert(exposed && MonoTime.currTime - started < 2.seconds);

    nativeWindow.performClose(null);
    bool closeRequested;
    auto closeDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in CloseRequestedEvent _) { closeRequested = true; },
            (_) {});
    });
    assert(closeDrain.hasValue && closeRequested);

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

    writeln("ok: AppKit NSWindow + kqueue timer/waker shared one CFRunLoop wait");
    return 0;
}
