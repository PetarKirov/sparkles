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
/**
Wayland driver for the shared native-surface conformance probe
(`sparkles.vulkan_wsi.conformance`): typed Wayland handles to a
present-capable Vulkan device on the live ICD. The backend exposes the
native-I/O borrow, so the probe brackets every Mesa call with it
automatically. Run through `scripts/verify-wayland-surface-weston.sh`.
*/
module native_surface_smoke;

version (linux):

import core.time : Duration, MonoTime, seconds;
import std.stdio : writeln;

import sparkles.event_horizon : DefaultLoop, LoopConfig, RunStatus;
import sparkles.vulkan_wsi;
import sparkles.wsi;

private struct WaylandHooks
{
    WaylandWsi* wsi;
    DefaultLoop* loop;

    void step(Duration timeout)
    {
        wsi.runIntegratedOnce(*loop, timeout).value;
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

    const deadline = MonoTime.currTime + 2.seconds;
    while (!wsi.bootstrapComplete)
    {
        assert(wsi.runIntegratedOnce(loop, 2.seconds).value
            == RunStatus.dispatched);
        assert(MonoTime.currTime < deadline);
    }

    auto hooks = WaylandHooks(&wsi, &loop);
    auto probed = checkSurfaceConformance(wsi, loop, hooks,
        "sparkles:vulkan-wsi Wayland surface smoke");
    assert(!probed.hasError);

    writeln("ok: Wayland native handles -> Vulkan surface -> present device");
    return 0;
}
