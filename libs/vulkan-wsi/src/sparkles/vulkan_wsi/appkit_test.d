/**
The native macOS path, on a real window: AppKit's `CAMetalLayer` to a
MoltenVK surface and a device that presents, then frames presented through
it. Part of `dub test :vulkan-wsi`, so every macOS CI leg runs it.

Each test says why it cannot run rather than failing: no window server (an
`ssh` session, a launchd daemon), no Vulkan loader or present-capable
device, or — for the frames — a GPU that cannot execute them. GitHub's
hosted macOS runners are the last kind: their paravirtual GPU makes the
surface and the device, then hangs on MoltenVK's first submission
(`kIOGPUCommandBufferCallbackErrorHang`, with and without Metal argument
buffers), so there only the surface test runs.

AppKit is main-thread-only, hence `@serial(threadAffinity: mainThread)`.
*/
module sparkles.vulkan_wsi.appkit_test;

version (OSX):
version (unittest):

import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.test_runner.attributes : serial, ThreadAffinity;
import sparkles.test_runner.skip : skipTest;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.commands : CommandPool;
import sparkles.vulkan_wsi.presenter : Presenter, presentFrame;
import sparkles.vulkan_wsi.test_pattern : createTestPattern, FrameContext;
import sparkles.vulkan_wsi.triangle : Pipeline, record;
import sparkles.wsi;

private extern (C) const(void)* CGSessionCopyCurrentDictionary() nothrow @nogc;
private extern (C) void CFRelease(const(void)* object) nothrow @nogc;

// Whether this process has a window server to open windows on.
private bool hasWindowServer() @system nothrow @nogc
{
    auto session = CGSessionCopyCurrentDictionary();
    if (session is null)
        return false;
    CFRelease(session);
    return true;
}

private struct Hooks
{
    AppKitWsi* wsi;
    DefaultLoop* loop;

    void step(Duration timeout)
    {
        loop.runHostedOnce(*wsi, timeout).value;
    }
}

// The AppKit backend on `loop`, or a skip naming why there is none.
private void openAppKit(ref DefaultLoop loop, ref AppKitWsi wsi) @system
{
    if (!hasWindowServer())
        skipTest("no window server: this session cannot open a window (ssh, a daemon)");
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
        skipTest("no event loop (kqueue) in this environment");
    auto opened = AppKitWsi.open(wsi);
    if (opened.hasError)
        skipTest("AppKit did not open: " ~ opened.error.diagnostic[].idup);
}

private bool environmental(in VulkanWsiError e) @safe pure nothrow @nogc
    => e.kind == VulkanWsiErrorKind.loaderUnavailable
        || e.kind == VulkanWsiErrorKind.noPresentDevice;

@("vulkan_wsi.appkit.surfaceConformance")
@serial(threadAffinity: ThreadAffinity.mainThread) @system
unittest
{
    DefaultLoop loop;
    AppKitWsi wsi;
    openAppKit(loop, wsi);
    auto hooks = Hooks(&wsi, &loop);
    auto probed = checkSurfaceConformance(wsi, loop, hooks, "sparkles:vulkan-wsi AppKit test");
    if (probed.hasError && environmental(probed.error))
        skipTest("no Vulkan runtime or present-capable device: " ~ probed.error.diagnostic[].idup);
    assert(!probed.hasError, probed.hasError ? probed.error.diagnostic[] : "");
}

@("vulkan_wsi.appkit.presentsFrames")
@serial(threadAffinity: ThreadAffinity.mainThread) @system
unittest
{
    enum frames = 60;
    DefaultLoop loop;
    AppKitWsi wsi;
    openAppKit(loop, wsi);

    WindowConfig config;
    assert(config.title.assign("sparkles:vulkan-wsi AppKit frames"));
    config.logicalSize = LogicalSize(320, 240);
    const window = wsi.createWindow(config).value;
    scope (exit)
        cast(void) wsi.destroyWindow(window);

    SurfaceMetrics metrics;
    bool ready;
    void drain()
    {
        cast(void) wsi.drain((WindowEvent e) {
            if (e.window == window)
                e.payload.match!(
                    (in ReadyEvent r) { metrics = r.metrics; ready = true; },
                    (in SurfaceMetricsChangedEvent m) { metrics = m.metrics; },
                    (in _) {});
        });
    }
    const readyBy = MonoTime.currTime + 5.seconds;
    for (drain(); !ready; drain())
    {
        assert(MonoTime.currTime < readyBy, "no ReadyEvent after createWindow");
        loop.runHostedOnce(wsi, 100.msecs).value;
    }

    VulkanContext vk;
    auto up = VulkanContext.create(vk, wsi.nativeHandles(window).value,
        ContextRequest(applicationName: "sparkles:vulkan-wsi AppKit frames",
            apiVersion: apiVersion13));
    if (up.hasError && environmental(up.error))
        skipTest("no Vulkan runtime or present-capable device: " ~ up.error.diagnostic[].idup);
    assert(!up.hasError, up.hasError ? up.error.diagnostic[] : "");
    // Named, so a real device that loses itself still fails.
    if (vk.deviceName.canFind("Paravirtual"))
        skipTest("a paravirtual GPU (" ~ vk.deviceName ~ ") hangs on MoltenVK's first "
            ~ "submission: GitHub's hosted macOS runners; the surface test still runs");

    Presenter presenter;
    CommandPool commands;
    Pipeline pipeline;
    scope (exit)
    {
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
        pipeline.destroy(vk);
        commands.destroy(vk);
        presenter.destroy(vk);
    }
    auto rebuild(bool force) => presenter.rebuild(vk, metrics.physicalSize, force);
    auto built = rebuild(false);
    assert(!built.hasError, built.hasError ? built.error : "");
    assert(!createTestPattern(pipeline, vk, presenter.swapchain, presenter.target.renderPass).hasError);
    assert(!CommandPool.create(commands, vk, presenter.sync.framesInFlight).hasError);

    uint presented;
    const doneBy = MonoTime.currTime + 10.seconds;
    while (presented < frames)
    {
        assert(MonoTime.currTime < doneBy, "the frames did not all present in 10 s");
        loop.runHostedOnce(wsi, Duration.zero).value;
        drain();
        const extent = presenter.swapchain.extent;
        auto context = FrameContext(resolution: [extent.width, extent.height], frameCount: presented);
        auto shown = presenter.presentFrame!((uint image) => record(vk, commands, pipeline,
            presenter.target, presenter.swapchain, presenter.sync.frame, image, extent,
            (cast(const(void)*) &context)[0 .. context.sizeof]))(vk, commands);
        assert(!shown.hasError, shown.hasError ? shown.error : "");
        if (shown.value.presented)
            ++presented;
        else if (shown.value.stale)
            assert(!rebuild(true).hasError);
    }
    assert(presenter.stats.framesPresented >= frames);
}
