#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_wsi_native_appkit_surface_smoke"
    dependency "sparkles:vulkan-wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    targetPath "build"
    platforms "osx"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
AppKit driver for the shared native-surface conformance probe
(`sparkles.vulkan_wsi.conformance`): a real `NSWindow`'s typed handles — its
view's `CAMetalLayer` — to a present-capable Vulkan device through MoltenVK
(`VK_EXT_metal_surface`, with `VK_KHR_portability_enumeration`). Skips when
the process has no Vulkan loader or no present-capable device.
*/
module native_appkit_surface_smoke;

version (OSX):

import core.time : Duration;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.vulkan_wsi;
import sparkles.wsi;

private struct AppKitHooks
{
    AppKitWsi* wsi;
    DefaultLoop* loop;

    void step(Duration timeout)
    {
        loop.runHostedOnce(*wsi, timeout).value;
    }
}

int main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    AppKitWsi wsi;
    assert(!AppKitWsi.open(wsi).hasError);

    auto hooks = AppKitHooks(&wsi, &loop);
    auto probed = checkSurfaceConformance(wsi, loop, hooks,
        "sparkles:vulkan-wsi AppKit surface smoke");
    if (probed.hasError
        && (probed.error.kind == VulkanWsiErrorKind.loaderUnavailable
            || probed.error.kind == VulkanWsiErrorKind.noPresentDevice))
    {
        writeln(probed.error.kind == VulkanWsiErrorKind.loaderUnavailable
            ? "SKIP: no Vulkan runtime" : "SKIP: no present-capable device");
        return 0;
    }
    assert(!probed.hasError, probed.hasError ? probed.error.diagnostic[] : "");

    writeln("ok: AppKit native handles -> CAMetalLayer -> Vulkan surface -> present device");
    return 0;
}
