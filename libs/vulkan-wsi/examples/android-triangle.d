/**
A Vulkan triangle on the native `sparkles:wsi` Android backend.

The activity's `ANativeWindow` becomes a `VkSurfaceKHR` through
`VK_KHR_android_surface`, and the same swapchain, frame synchronization and
renderer the desktop triangles use present on it. Midway the lane turns the
display twice, so the swapchain is rebuilt for each new extent. The verdict
goes to logcat under the tag `sparkles-wsi`; `libs/wsi/scripts/verify-android-emulator.sh`
runs it (`legacyPackages.vulkan-wsi-android-triangle-apk`).
*/
module android_triangle;

version (Android):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.string : toStringz;

import expected : Expected, err, ok;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.triangle;
import sparkles.wsi;
import sparkles.wsi.platform.android : AndroidWsi, AndroidWsiMain;

private extern (C) int __android_log_write(int priority, const(char)* tag,
    const(char)* message) nothrow @nogc;

mixin AndroidWsiMain!run;

private void say(string line) @trusted
{
    __android_log_write(4, "sparkles-wsi", line.toStringz);
}

/// Asks the lane script to turn the display (see the WSI smoke's `request`).
private void request(string what)
{
    __gshared uint serial;
    say(text("inject: ", what, " ", ++serial));
}

private enum uint frameBudget = 240;

private void run()
{
    const outcome = drive();
    if (outcome.hasError)
        assert(false, outcome.error);
}

private Expected!(void, string) drive() @system
{
    DefaultLoop loop;
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
        return err!void("Event Horizon did not open");
    AndroidWsi wsi;
    if (AndroidWsi.open(wsi).hasError || wsi.attach(loop).hasError)
        return err!void("the Android backend did not open");
    const window = wsi.createWindow(WindowConfig()).value;

    SurfaceMetrics metrics;
    bool ready, resized;
    void pump(Duration timeout)
    {
        wsi.runIntegratedOnce(loop, timeout).value;
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in ReadyEvent e) { metrics = e.metrics; ready = true; },
                (in SurfaceMetricsChangedEvent e) {
                    resized |= e.metrics.physicalSize != metrics.physicalSize;
                    metrics = e.metrics;
                },
                (_) {});
        }).hasError);
    }
    const startup = MonoTime.currTime + 10.seconds;
    while (!ready || metrics.suspended)
    {
        if (MonoTime.currTime > startup)
            return err!void("the window never became ready");
        pump(100.msecs);
    }

    auto handles = wsi.nativeHandles(window);
    if (handles.hasError)
        return err!void("no native handles for the window");
    VulkanContext vk;
    auto broughtUp = VulkanContext.create(vk, handles.value,
        ContextRequest(applicationName: "sparkles-android-triangle",
            apiVersion: apiVersion13));
    if (broughtUp.hasError)
        return err!void(text("Vulkan did not come up: ", broughtUp.error.diagnostic[],
            " (", describeResult(broughtUp.error.vkResult), ")"));

    Swapchain swapchain;
    RenderTarget target;
    FrameSync sync;
    CommandPool commands;
    Pipeline pipeline;
    scope (exit)
    {
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
        pipeline.destroy(vk);
        commands.destroy(vk);
        sync.destroy(vk);
        target.destroy(vk);
        swapchain.destroy(vk);
    }

    uint swapchainsBuilt;
    Expected!(SwapchainResize, string) rebuild(bool force)
    {
        if (metrics.suspended)
            return ok!string(SwapchainResize.paused);
        auto waited = sync.waitAll(vk);
        if (waited.hasError)
            return err!SwapchainResize("vkWaitForFences: " ~ describeResult(waited.error));
        auto updated = Swapchain.recreate(swapchain, vk, metrics.physicalSize,
            force, PhysicalSize.init, anyPresentMode);
        if (updated.hasError || updated.value != SwapchainResize.rebuilt)
            return updated;
        auto retargeted = target.views.length == 0
            ? RenderTarget.create(target, vk, swapchain)
            : target.rebind(vk, swapchain);
        if (retargeted.hasError)
            return err!SwapchainResize(retargeted.error);
        const images = cast(uint) swapchain.images.length;
        auto synced = sync.imageCount == 0
            ? FrameSync.create(sync, vk, images) : sync.replaceImages(vk, images);
        if (synced.hasError)
            return err!SwapchainResize(synced.error);
        ++swapchainsBuilt;
        return updated;
    }

    auto initial = rebuild(false);
    if (initial.hasError)
        return err!void(initial.error);
    if (Pipeline.create(pipeline, vk, swapchain.format, target.renderPass).hasError
        || CommandPool.create(commands, vk, sync.framesInFlight).hasError)
        return err!void("the pipeline or the command pool failed");

    uint presented, outOfDate;
    const portrait = metrics.physicalSize;
    bool turned, turnedBack;
    const deadline = MonoTime.currTime + 60.seconds;
    // Done once the budget is spent and the surface is upright again, with a
    // swapchain built for that extent.
    while (presented < frameBudget || !turnedBack
        || metrics.physicalSize != portrait || swapchain.extent.width != portrait.width)
    {
        if (MonoTime.currTime > deadline)
            return err!void(text("the run stalled after ", presented, " frames"));
        // The display turns at a third of the budget and back at two thirds;
        // each turn is a new extent the swapchain must be rebuilt for.
        if (!turned && presented == frameBudget / 3)
        {
            turned = true;
            request("landscape");
        }
        if (turned && !turnedBack && presented >= 2 * frameBudget / 3
            && metrics.physicalSize != portrait)
        {
            turnedBack = true;
            request("portrait");
        }
        pump(Duration.zero);
        if (resized)
        {
            resized = false;
            auto updated = rebuild(false);
            if (updated.hasError)
                return err!void(updated.error);
        }
        if (metrics.suspended)
        {
            pump(50.msecs);
            continue;
        }

        if (sync.waitForFrame(vk).hasError)
            return err!void("vkWaitForFences failed");
        uint image;
        const acquired = vk.device.acquireNextImageKHR(vk.device.device,
            swapchain.handle, ulong.max, sync.imageAvailable, null, &image);
        const decision = decideAcquire(acquired);
        if (decision.failed)
            return err!void("vkAcquireNextImageKHR: " ~ describeResult(acquired));
        if (!decision.proceed)
        {
            ++outOfDate;
            auto updated = rebuild(true);
            if (updated.hasError)
                return err!void(updated.error);
            continue;
        }
        if (sync.waitForImage(vk, image).hasError || sync.beginFrame(vk, image).hasError)
            return err!void("frame synchronization failed");
        auto recorded = record(vk, commands, pipeline, target, swapchain,
            sync.frame, image, drawableExtent(swapchain, metrics.physicalSize));
        if (recorded.hasError)
            return recorded;
        if (sync.submit(vk, commands.buffers[sync.frame], image).hasError)
            return err!void("vkQueueSubmit failed");
        auto shown = swapchain.present(vk, image, sync.renderFinished(image));
        sync.advance();
        ++presented;
        const stale = shown.hasError ? Swapchain.needsRecreation(shown.error)
            : Swapchain.needsRecreation(shown.value);
        if (shown.hasError && !stale)
            return err!void("vkQueuePresentKHR: " ~ describeResult(shown.error));
        if (stale || decision.recreate)
        {
            ++outOfDate;
            auto updated = rebuild(true);
            if (updated.hasError)
                return err!void(updated.error);
        }
    }
    if (swapchainsBuilt < 3)
        return err!void(text("the display turned twice but only ", swapchainsBuilt,
            " swapchains were built"));

    say(text("ok: Android Vulkan triangle (", presented, " frames, ", swapchainsBuilt,
        " swapchains, ", outOfDate, " out of date, ", target.dynamicRendering ? "dynamic rendering" : "render pass",
        ", ", vk.deviceName, ")"));
    assert(!wsi.finishActivity().hasError);
    return ok!string();
}
