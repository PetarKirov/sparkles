#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_wsi_native_x11_surface_smoke"
    dependency "sparkles:vulkan-wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    targetPath "build"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/** Native XCB handle to present-capable Vulkan device smoke test. */
module native_x11_surface_smoke;

version (linux):

import core.time : MonoTime, msecs, seconds;
import std.stdio : stderr, writeln;

import sparkles.event_horizon : Completion, DefaultLoop, LoopConfig, RunStatus;
import sparkles.vulkan : apiVersion11;
import sparkles.vulkan_wsi;
import sparkles.wsi;

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
    scope (exit) loop.destroy();

    X11Wsi wsi;
    auto openedWsi = X11Wsi.open(wsi);
    if (openedWsi.hasError
        && openedWsi.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no X11 display");
        return 0;
    }
    assert(!openedWsi.hasError);
    scope (exit) cast(void) wsi.close();

    WindowConfig config;
    assert(config.title.assign("sparkles:vulkan-wsi X11 surface smoke"));
    config.logicalSize = LogicalSize(480, 320);
    auto created = wsi.createWindow(config);
    assert(created.hasValue);

    bool ready;
    auto drained = wsi.drain((WindowEvent event) {
        if (event.window == created.value)
            event.payload.match!(
                (in ReadyEvent _) { ready = true; },
                (_) {});
    });
    assert(drained.hasValue && ready);

    auto handles = wsi.nativeHandles(created.value);
    assert(handles.hasValue);

    stderr.writeln(">> creating Vulkan instance/surface/device");
    VulkanContext context;
    auto broughtUp = VulkanContext.create(context, handles.value,
        ContextRequest(applicationName: "sparkles:vulkan-wsi X11 smoke",
            apiVersion: apiVersion11));
    assert(!broughtUp.hasError);
    scope (exit) context.destroy();
    stderr.writeln(">> Vulkan context ready");

    assert(context.instance.instance !is null);
    assert(context.surface !is null);
    assert(context.physicalDevice !is null);
    assert(context.device.device !is null);
    assert(context.queue !is null);
    assert(context.queueFamily != uint.max);

    context.destroy();

    // Mesa's X11 WSI issues its own round trips on the shared connection;
    // XCB may queue events it reads past. Prove the backend still drains and
    // the integrated Event Horizon wait still makes progress afterwards.
    assert(wsi.pumpEvents().hasValue);
    assert(!wsi.attach(loop).hasError);
    bool timerFired;
    auto timer = loop.submitAfter(25.msecs, &timerComplete, &timerFired);
    assert(timer.hasValue);
    const deadline = MonoTime.currTime + 2.seconds;
    while (!timerFired)
    {
        auto step = wsi.runIntegratedOnce(loop, 2.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        assert(MonoTime.currTime < deadline);
    }

    writeln("ok: X11 native handles -> Vulkan surface -> present device");
    return 0;
}
