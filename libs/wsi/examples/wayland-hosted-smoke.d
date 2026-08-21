/** Native Wayland lifecycle + Event Horizon prepare-read smoke test. */
module wayland_hosted_smoke;

version (linux):

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion;
import sparkles.wsi;

private __gshared WaylandWsi* wrongThreadWsi;
private __gshared WindowId wrongThreadId;
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
    assert(config.title.assign("sparkles:wsi Wayland smoke"));
    config.logicalSize = LogicalSize(480, 320);
    auto created = wsi.createWindow(config);
    assert(created.hasValue);
    auto id = created.value;

    bool ready;
    bool exposed;
    bool frameReady;
    SurfaceMetrics currentMetrics;
    ulong lastSequence;
    auto drain = () {
        auto result = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            event.payload.match!(
                (in ReadyEvent value) {
                    ready = true;
                    currentMetrics = value.metrics;
                },
                (in SurfaceMetricsChangedEvent value) {
                    currentMetrics = value.metrics;
                },
                (in ExposedEvent _) { exposed = true; },
                (in FrameReadyEvent _) { frameReady = true; },
                (_) {});
        });
        assert(result.hasValue);
    };

    const configureStart = MonoTime.currTime;
    while (!ready)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        drain();
        assert(MonoTime.currTime - configureStart < 2.seconds);
    }
    assert(currentMetrics == SurfaceMetrics(LogicalSize(480, 320),
        PhysicalSize(480, 320), ScaleFactor(1)));
    assert(exposed && frameReady);

    auto queried = wsi.nativeHandles(id);
    assert(queried.hasValue);
    const(void)* display = queried.value.display.match!(
        (in WaylandDisplayHandle handle) => handle.display,
        (_) => null);
    const(void)* surface = queried.value.window.match!(
        (in WaylandWindowHandle handle) => handle.surface,
        (_) => null);
    assert(display !is null && surface !is null);

    wrongThreadWsi = &wsi;
    wrongThreadId = id;
    auto wrongThread = new Thread({
        auto result = wrongThreadWsi.nativeHandles(wrongThreadId);
        if (result.hasError)
            wrongThreadKind = result.error.kind;
    });
    wrongThread.start();
    wrongThread.join();
    assert(wrongThreadKind == WsiErrorKind.wrongThread);
    wrongThreadWsi = null;

    bool timerFired;
    auto timer = loop.submitAfter(25.msecs, &timerComplete, &timerFired);
    assert(timer.hasValue);
    auto worker = new Thread({
        Thread.sleep(10.msecs);
        waker.wake();
    });
    worker.start();
    const externalStart = MonoTime.currTime;
    while (!timerFired)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        drain();
        assert(MonoTime.currTime - externalStart < 2.seconds);
    }
    worker.join();

    assert(!wsi.setMaximized(id, true).hasError);
    bool resized;
    const resizeStart = MonoTime.currTime;
    while (!resized)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        const before = currentMetrics;
        drain();
        resized = currentMetrics != before
            && currentMetrics.logicalSize != LogicalSize(480, 320);
        assert(MonoTime.currTime - resizeStart < 2.seconds);
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

    writeln("ok: Wayland configure/ack + timer/waker shared one fd loop");
    return 0;
}
