#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_wsi_native_surface_smoke"
    dependency "sparkles:vulkan-wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    targetPath "build"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/** Native Wayland handle to present-capable Vulkan device smoke test. */
module native_surface_smoke;

version (linux):

import core.time : MonoTime, seconds;
import std.stdio : stderr, writeln;

import sparkles.event_horizon : DefaultLoop, LoopConfig, RunStatus;
import sparkles.vulkan : apiVersion11;
import sparkles.vulkan_wsi;
import sparkles.wsi;

int main()
{
    DefaultLoop loop;
    auto openedLoop = DefaultLoop.create(loop, LoopConfig());
    assert(!openedLoop.hasError);
    scope (exit) loop.destroy();

    WaylandWsi wsi;
    auto openedWsi = WaylandWsi.open(wsi, loop);
    if (openedWsi.hasError
        && openedWsi.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no Wayland compositor");
        return 0;
    }
    assert(!openedWsi.hasError);
    scope (exit) cast(void) wsi.close();

    const deadline = MonoTime.currTime + 2.seconds;
    while (!wsi.bootstrapComplete)
    {
        assert(wsi.runIntegratedOnce(loop, 2.seconds).hasValue);
        assert(MonoTime.currTime < deadline);
    }

    WindowConfig config;
    assert(config.title.assign("sparkles:vulkan-wsi surface smoke"));
    config.logicalSize = LogicalSize(480, 320);
    auto created = wsi.createWindow(config);
    assert(created.hasValue);

    bool ready;
    while (!ready)
    {
        assert(wsi.runIntegratedOnce(loop, 2.seconds).hasValue);
        auto drained = wsi.drain((WindowEvent event) {
            if (event.window == created.value)
                event.payload.match!(
                    (in ReadyEvent _) { ready = true; },
                    (_) {});
        });
        assert(drained.hasValue);
        assert(MonoTime.currTime < deadline);
    }

    auto handles = wsi.nativeHandles(created.value);
    assert(handles.hasValue);

    // Mesa may round-trip the shared display while querying surface support.
    // Cancel Event Horizon's prepared read until all Vulkan WSI calls finish.
    assert(!wsi.beginNativeIo().hasError);
    stderr.writeln(">> creating Vulkan instance/surface/device");
    VulkanContext context;
    auto broughtUp = VulkanContext.create(context, handles.value,
        ContextRequest(applicationName: "sparkles:vulkan-wsi smoke",
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
    assert(!wsi.endNativeIo().hasError);

    // The poll is live again after the driver relinquishes the display.
    assert(!wsi.setMaximized(created.value, true).hasError);
    assert(wsi.runIntegratedOnce(loop, 2.seconds).hasValue);

    writeln("ok: Wayland native handles -> Vulkan surface -> present device");
    return 0;
}
