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
/**
X11 driver for the shared native-surface conformance probe
(`sparkles.vulkan_wsi.conformance`): typed XCB handles to a
present-capable Vulkan device on the live ICD — under Xvfb the hardware
ICDs decline presentation (no DRI3) and device selection must fall through
to lavapipe, which is exactly the decision path being exercised. Run
through `scripts/verify-x11-surface-xvfb.sh`.
*/
module native_x11_surface_smoke;

version (linux):

import core.time : Duration;
import std.stdio : writeln;

import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.vulkan_wsi;
import sparkles.wsi;

private struct X11Hooks
{
    X11Wsi* wsi;
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
    auto probed = checkSurfaceConformance(wsi, loop, hooks,
        "sparkles:vulkan-wsi X11 surface smoke");
    assert(!probed.hasError);

    writeln("ok: X11 native handles -> Vulkan surface -> present device");
    return 0;
}
