/**
Win32 driver for the shared native-surface conformance probe
(`sparkles.vulkan_wsi.conformance`): a real HWND's typed handles to a
present-capable Vulkan device through winevulkan or the native runtime.
Skips honestly when the environment lacks a Vulkan runtime or a
present-capable device — the verify lane treats that skip as a failure,
because winevulkan reaching a device is the point being verified.
Cross-compile and run through `scripts/verify-win32-surface-wine.sh`.
*/
module native_win32_surface_smoke;

version (Windows):

import core.time : Duration;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.vulkan_wsi;
import sparkles.wsi;

private struct Win32Hooks
{
    Win32Wsi* wsi;
    DefaultLoop* loop;

    void step(Duration timeout)
    {
        loop.runHostedOnce(*wsi, timeout).value;
    }
}

int main()
{
    DefaultLoop loop;
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
    {
        writeln("SKIP: IOCP unavailable");
        return 0;
    }

    Win32Wsi wsi;
    assert(!Win32Wsi.open(wsi).hasError);

    auto hooks = Win32Hooks(&wsi, &loop);
    auto probed = checkSurfaceConformance(wsi, loop, hooks,
        "sparkles:vulkan-wsi Win32 surface smoke");
    if (probed.hasError
        && (probed.error.kind == VulkanWsiErrorKind.loaderUnavailable
            || probed.error.kind == VulkanWsiErrorKind.noPresentDevice))
    {
        writeln(probed.error.kind == VulkanWsiErrorKind.loaderUnavailable
            ? "SKIP: no Vulkan runtime" : "SKIP: no present-capable device");
        return 0;
    }
    assert(!probed.hasError);

    writeln("ok: Win32 native handles -> Vulkan surface -> present device");
    return 0;
}
