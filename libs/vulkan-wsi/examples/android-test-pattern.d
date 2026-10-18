#!/usr/bin/env dub
/+ dub.sdl:
    name "android_test_pattern"
    dependency "sparkles:vulkan-wsi" path="../../.."
    dependency "sparkles:vulkan" path="../../.."
    dependency "sparkles:wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "expected" version="~>0.4.1"
    targetPath "build"
    platforms "android"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
A Vulkan test pattern on the native `sparkles:wsi` Android backend.

The activity's `ANativeWindow` becomes a `VkSurfaceKHR` through
`VK_KHR_android_surface`, and the shared swapchain and frame synchronization
present the diagnostic pattern of `sparkles.vulkan_wsi.test_pattern` on it:
the safe area and the caution hatch around it, corner crosshairs, liveness
marks, and an orientation-specific layout. The swapchain is pre-rotated: its
images keep the panel's orientation and the shader turns the pattern, so the
compositor never rotates or scales it.

It runs until the activity ends, which BACK asks for. When the window loses its surface (the app
goes to the background) everything Vulkan is released, and it comes back on
the next surface. Each swapchain it builds is logged under the tag
`sparkles-wsi` as a `pattern:` line naming the display size, the safe insets,
the swapchain extent and its pre-transform, whenever what a frame draws for
changes;
`libs/wsi/scripts/verify-android-emulator.sh` captures the screen after each
and checks the pattern with `libs/vulkan-wsi/scripts/check-test-pattern.d`.
Its recipe says `platforms "android"`, so it builds as an APK
(`legacyPackages.androidExamples.vulkan-wsi.android-test-pattern`).
*/
module android_test_pattern;

version (Android):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.string : toStringz;

import expected : Expected, err, ok;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.input.events : KeyAction;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.test_pattern;
import sparkles.vulkan_wsi.triangle : Pipeline, RenderTarget, record;
import sparkles.wsi;
import sparkles.wsi.platform.android : AndroidWsi, AndroidWsiMain;

private extern (C) int __android_log_write(int priority, const(char)* tag,
    const(char)* message) nothrow @nogc;

mixin AndroidWsiMain!run;

private enum uint keycodeBack = 4; // `AKEYCODE_BACK`

private void say(string line) @trusted
{
    __android_log_write(4, "sparkles-wsi", line.toStringz);
}

private void run()
{
    const outcome = drive();
    if (outcome.hasError)
        assert(false, outcome.error);
}

/// Everything Vulkan that lives on one `ANativeWindow`.
private struct Renderer
{
    VulkanContext vk;
    Swapchain swapchain;
    RenderTarget target;
    FrameSync sync;
    CommandPool commands;
    Pipeline pipeline;
    bool live;

    @disable this(this);

    void release() @system
    {
        if (!live)
            return;
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
        pipeline.destroy(vk);
        commands.destroy(vk);
        sync.destroy(vk);
        target.destroy(vk);
        swapchain.destroy(vk);
        vk.destroy();
        // Back to their initial state: the next surface builds every one
        // afresh, and an object that kept its old handles would be rebound
        // on a device that no longer exists.
        pipeline = Pipeline.init;
        commands = CommandPool.init;
        sync = FrameSync.init;
        target = RenderTarget.init;
        swapchain = Swapchain.init;
        live = false;
    }
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
    bool changed, destroyed, leave;
    void pump(Duration timeout)
    {
        wsi.runIntegratedOnce(loop, timeout).value;
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in ReadyEvent e) { metrics = e.metrics; changed = true; },
                (in SurfaceMetricsChangedEvent e) { metrics = e.metrics; changed = true; },
                (in DestroyedEvent _) { destroyed = true; },
                // The backend reports BACK as a key, so leaving is the app's
                // decision: this one finishes its activity on the release.
                (in KeyboardEvent e) {
                    leave |= e.logical.nativeCode == keycodeBack
                        && e.action == KeyAction.release;
                },
                (_) {});
        }).hasError);
    }

    Renderer r;
    scope (exit) r.release();
    uint frames, built;
    string logged; // the last `pattern:` line

    // A new swapchain (or a first one) for the current surface and metrics.
    Expected!(void, string) rebuild(bool force)
    {
        if (!r.live)
        {
            auto handles = wsi.nativeHandles(window);
            if (handles.hasError)
                return ok!string(); // no surface yet
            auto broughtUp = VulkanContext.create(r.vk, handles.value,
                ContextRequest(applicationName: "sparkles-android-test-pattern",
                    apiVersion: apiVersion13));
            if (broughtUp.hasError)
                return err!void(text("Vulkan did not come up: ",
                    broughtUp.error.diagnostic[], " (",
                    describeResult(broughtUp.error.vkResult), ")"));
            r.live = true;
        }
        auto waited = r.sync.waitAll(r.vk);
        if (waited.hasError)
            return err!void("vkWaitForFences: " ~ describeResult(waited.error));
        // FIFO: one frame per display refresh, not as many as the GPU can.
        auto updated = Swapchain.recreate(r.swapchain, r.vk, metrics.physicalSize,
            force, PhysicalSize.init, VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR);
        if (updated.hasError)
            return err!void(updated.error);
        if (updated.value != SwapchainResize.rebuilt)
            return ok!string();
        auto retargeted = r.target.views.length == 0
            ? RenderTarget.create(r.target, r.vk, r.swapchain)
            : r.target.rebind(r.vk, r.swapchain);
        if (retargeted.hasError)
            return err!void(retargeted.error);
        const images = cast(uint) r.swapchain.images.length;
        if (r.sync.imageCount == 0)
        {
            if (FrameSync.create(r.sync, r.vk, images).hasError)
                return err!void("frame synchronization failed");
        }
        else if (r.sync.replaceImages(r.vk, images).hasError)
            return err!void("frame synchronization failed");
        if (r.pipeline.handle is null)
        {
            if (createTestPattern(r.pipeline, r.vk, r.swapchain, r.target.renderPass).hasError
                || CommandPool.create(r.commands, r.vk, r.sync.framesInFlight).hasError)
                return err!void("the pipeline or the command pool failed");
        }
        ++built;
        return ok!string();
    }

    Expected!(void, string) present()
    {
        if (r.sync.waitForFrame(r.vk).hasError)
            return err!void("vkWaitForFences failed");
        uint image;
        const acquired = r.vk.device.acquireNextImageKHR(r.vk.device.device,
            r.swapchain.handle, ulong.max, r.sync.imageAvailable, null, &image);
        const decision = decideAcquire(acquired);
        if (decision.failed)
            return err!void("vkAcquireNextImageKHR: " ~ describeResult(acquired));
        if (!decision.proceed)
            return rebuild(true);
        if (r.sync.waitForImage(r.vk, image).hasError || r.sync.beginFrame(r.vk, image).hasError)
            return err!void("frame synchronization failed");

        // The display's own size and insets; the whole (panel-oriented) image
        // is drawn, and the shader turns the pattern upright.
        const shown = displayExtent(r.swapchain);
        const insets = metrics.safeInsets;
        FrameContext context;
        context.resolution = [shown.width, shown.height];
        context.safeInsets = [insets.left, insets.top, insets.right, insets.bottom];
        context.preTransform = cast(uint) r.swapchain.transform;
        context.frameCount = frames;
        // What this frame draws for, logged whenever it changes: a rebuild
        // and the metrics that settle a turn arrive separately, and the lane
        // checks a capture against the latest line.
        const state = text("pattern: display ", shown.width, "x", shown.height,
            " insets ", insets.left, ",", insets.top, ",", insets.right, ",", insets.bottom,
            " swapchain ", r.swapchain.extent.width, "x", r.swapchain.extent.height,
            " transform ", cast(uint) r.swapchain.transform,
            " format ", cast(uint) r.swapchain.format,
            r.target.dynamicRendering ? " dynamic-rendering" : " render-pass",
            " device ", r.vk.deviceName);
        if (state != logged)
        {
            logged = state;
            say(state);
        }
        auto recorded = record(r.vk, r.commands, r.pipeline, r.target, r.swapchain,
            r.sync.frame, image, r.swapchain.extent, (cast(const(void)*) &context)[0 .. context.sizeof]);
        if (recorded.hasError)
            return recorded;
        if (r.sync.submit(r.vk, r.commands.buffers[r.sync.frame], image).hasError)
            return err!void("vkQueueSubmit failed");
        auto shownResult = r.swapchain.present(r.vk, image, r.sync.renderFinished(image));
        r.sync.advance();
        ++frames;
        const stale = shownResult.hasError ? Swapchain.needsRecreation(shownResult.error)
            : Swapchain.needsRecreation(shownResult.value);
        if (shownResult.hasError && !stale)
            return err!void("vkQueuePresentKHR: " ~ describeResult(shownResult.error));
        if (stale || decision.recreate)
            return rebuild(true);
        return ok!string();
    }

    bool announced;
    while (!destroyed)
    {
        if (leave)
        {
            leave = false;
            r.release();
            assert(!wsi.finishActivity().hasError);
        }
        pump(r.live && !metrics.suspended ? Duration.zero : 250.msecs);
        if (metrics.suspended)
        {
            // The surface is going away: release everything on it before the
            // backend lets the platform destroy it.
            r.release();
            continue;
        }
        // A turn arrives as a new window size and a new surface transform,
        // separately: ask the surface before every frame, not only on an event.
        if (changed || (r.live && r.swapchain.outdated(r.vk, metrics.physicalSize)))
        {
            changed = false;
            auto rebuilt = rebuild(false);
            if (rebuilt.hasError)
                return rebuilt;
        }
        if (!r.live || r.swapchain.handle is null)
            continue;
        auto presented = present();
        if (presented.hasError)
            return presented;
        if (!announced && frames >= 60)
        {
            announced = true;
            say(text("ok: Android test pattern presenting (", r.vk.deviceName, ")"));
        }
        if (r.swapchain.hasRetired || r.sync.hasRetired)
        {
            r.sync.reap(r.vk, 8);
            r.swapchain.reap(r.vk, 1);
        }
    }
    say(text("ok: Android test pattern ended (", frames, " frames, ", built, " swapchains)"));
    return ok!string();
}
