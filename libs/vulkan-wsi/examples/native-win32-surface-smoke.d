/**
Native Win32 handle to present-capable Vulkan device smoke test.

Cross-compile and run through `scripts/verify-win32-surface-wine.sh`. Creates
a real HWND through `sparkles:wsi`, hands its typed handles to
`sparkles:vulkan-wsi`, and proves the loader, `VK_KHR_win32_surface`, and
present-device selection work against the runtime's live ICD (winevulkan under
Wine). Skips honestly when no Vulkan runtime or device is reachable — the
verify script decides whether a skip fails the lane.
*/
module native_win32_surface_smoke;

version (Windows):

import core.time : MonoTime, msecs, seconds;
import std.stdio : stderr, writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion;
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
    if (openedLoop.hasError)
    {
        writeln("SKIP: IOCP unavailable");
        return 0;
    }
    scope (exit) loop.destroy();

    Win32Wsi wsi;
    auto openedWsi = Win32Wsi.open(wsi);
    assert(!openedWsi.hasError);
    scope (exit) cast(void) wsi.close();

    WindowConfig config;
    assert(config.title.assign("sparkles:vulkan-wsi Win32 surface smoke"));
    config.logicalSize = LogicalSize(480, 320);
    const created = wsi.createWindow(config);
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
        ContextRequest(applicationName: "sparkles:vulkan-wsi Win32 smoke",
            apiVersion: apiVersion11));
    if (broughtUp.hasError
        && (broughtUp.error.kind == VulkanWsiErrorKind.loaderUnavailable
            || broughtUp.error.kind == VulkanWsiErrorKind.noPresentDevice))
    {
        writeln(broughtUp.error.kind == VulkanWsiErrorKind.loaderUnavailable
            ? "SKIP: no Vulkan runtime" : "SKIP: no present-capable device");
        return 0;
    }
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

    // Prove the hosted User32/IOCP wait still makes progress after the ICD
    // ran on this thread: pump queued messages, then drive an IOCP timer
    // through the same MsgWaitForMultipleObjectsEx wait.
    assert(wsi.pumpMessages().hasValue);
    bool timerFired;
    auto timer = loop.submitAfter(25.msecs, &timerComplete, &timerFired);
    assert(timer.hasValue);
    const deadline = MonoTime.currTime + 2.seconds;
    while (!timerFired)
    {
        auto step = loop.runHostedOnce(wsi, 5.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
        assert(MonoTime.currTime < deadline);
    }

    writeln("ok: Win32 native handles -> Vulkan surface -> present device");
    return 0;
}
