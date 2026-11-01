#!/usr/bin/env dub
/+ dub.sdl:
    name "android_test_pattern"
    dependency "sparkles:vulkan-wsi" path="../../.."
    dependency "sparkles:vulkan" path="../../.."
    dependency "sparkles:wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    targetPath "build"
    platforms "android"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
A Vulkan test pattern on the native `sparkles:wsi` Android backend, and the
reference for what lives how long in an Android Vulkan app (§10.1 of the
window-system-integration specification).

The activity's `ANativeWindow` becomes a `VkSurfaceKHR` through
`VK_KHR_android_surface`, and the shared swapchain and frame synchronization
present the diagnostic pattern of `sparkles.vulkan_wsi.test_pattern` on it:
the safe area and the caution hatch around it, corner crosshairs, liveness
marks, and an orientation-specific layout. The swapchain is pre-rotated: its
images keep the panel's orientation and the shader turns the pattern, so the
compositor never rotates or scales it.

What each scope owns:

- the process: the WSI's one window and this thread, which outlive every
    activity; the `VulkanDevice`, made from the display handle before any
    surface, with its pipeline cache saved under the app's `internalDataPath`;
    and what is built on the device alone, the pipeline and the command pool;
- a surface: a `WindowSurface`, its swapchain, render target and frame
    synchronization, released inside the drain that reports the surface's loss
    (the platform destroys the `ANativeWindow` once that drain returns).

So a return from the background or a relaunch costs a surface and a swapchain,
and a launch after the process was killed finds its pipeline in the cache. The
device is kept while the app is in the background and released on memory
pressure, or with the surface when `releaseDeviceWithSurface` is set, for an
app that prefers the least background memory to the fastest return.

Frames are paced by the display: the app draws on each `FrameReadyEvent` and
asks for the next (`requestFrame`, `AChoreographer`), so nothing runs while it
has no surface, and the loop sleeps between frames.

BACK finishes the activity. Each state a frame draws for is logged under the
tag `sparkles-wsi` as a `pattern:` line (display size, safe insets, swapchain
extent and pre-transform); each surface's start as a `launch:` line with what
it cost and how many devices and pipelines the process has built.
`libs/wsi/scripts/verify-android-emulator.sh` captures the screen after each
and checks the pattern with `libs/vulkan-wsi/scripts/check-test-pattern.d`.
Its recipe says `platforms "android"`, so it builds as an APK
(`legacyPackages.androidExamples.vulkan-wsi.android-test-pattern`).
*/
module android_test_pattern;

version (Android):

import core.time : Duration, MonoTime, seconds;
import std.conv : text;
import std.string : toStringz;

import sparkles.base.expected : Expected, err, ok;

import sparkles.android.activity : internalDataPath;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.input.events : KeyAction;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.test_pattern;
import sparkles.vulkan_wsi.presenter : Presenter, presentFrame;
import sparkles.vulkan_wsi.triangle : Pipeline, record;
import sparkles.wsi;
import sparkles.wsi.platform.android : AndroidWsi, AndroidWsiMain;

private extern (C) int __android_log_write(int priority, const(char)* tag,
    const(char)* message) nothrow @nogc;

mixin AndroidWsiMain!run;

private enum uint keycodeBack = 4; // `AKEYCODE_BACK`

/// Release the device with each surface instead of keeping it in the
/// background: less memory there, a slower return.
private enum releaseDeviceWithSurface = false;

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

private static long ms(Duration d) => d.total!"msecs";

/// The process-scoped objects: the device and what is built on it alone.
private struct DeviceScope
{
    VulkanDevice device;
    Pipeline pipeline;
    VkFormat pipelineFormat;
    CommandPool commands;
    bool cacheDirty; // a pipeline was built since the cache was saved

    @disable this(this);

    bool live() const => device.device.device !is null;

    static string cachePath() => internalDataPath ~ "/pipeline-cache";

    void saveCache()
    {
        if (!cacheDirty)
            return;
        cacheDirty = false;
        if (device.savePipelineCache(cachePath).hasError)
            say("pipeline cache: not saved");
    }

    void release() @system
    {
        if (!live)
            return;
        device.device.deviceWaitIdle(device.device.device);
        saveCache();
        pipeline.destroy(device);
        commands.destroy(device);
        device.destroy();
        pipeline = Pipeline.init;
        commands = CommandPool.init;
    }
}

/// The surface-scoped objects, on a `DeviceScope`'s device.
private struct SurfaceScope
{
    WindowSurface vk;
    Presenter presenter; // the swapchain, its views and frame synchronization

    @disable this(this);

    bool live() const => vk.surface !is null;

    void release() @system
    {
        if (!live)
            return;
        vk.device.deviceWaitIdle(vk.device.device);
        presenter.destroy(vk); // back to its initial state: the next surface builds it afresh
        vk.destroy();
    }
}

private Expected!(void, string) drive() @system
{
    const processStarted = MonoTime.currTime;
    DefaultLoop loop;
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
        return err!void("Event Horizon did not open");
    AndroidWsi wsi;
    if (AndroidWsi.open(wsi).hasError || wsi.attach(loop).hasError)
        return err!void("the Android backend did not open");
    const window = wsi.createWindow(WindowConfig()).value;

    DeviceScope d;
    SurfaceScope s;
    scope (exit)
    {
        s.release();
        d.release();
    }
    uint devicesBuilt, pipelinesBuilt, surfacesBuilt, swapchainsBuilt, frames;

    // The device, from the display handle: made before the first surface
    // and kept across surfaces and activities.
    Expected!(void, string) bringUpDevice()
    {
        if (d.live)
            return ok!string();
        const started = MonoTime.currTime;
        auto display = wsi.displayHandle();
        if (display.hasError)
            return err!void("no display handle");
        auto made = VulkanDevice.create(d.device, display.value,
            ContextRequest(applicationName: "sparkles-android-test-pattern",
                apiVersion: apiVersion13));
        if (made.hasError)
            return err!void(text("Vulkan did not come up: ", made.error.diagnostic[],
                " (", describeResult(made.error.vkResult), ")"));
        if (d.device.loadPipelineCache(DeviceScope.cachePath).hasError)
            say("pipeline cache: not loaded");
        ++devicesBuilt;
        say(text("device: ", d.device.deviceName, " in ", ms(MonoTime.currTime - started), " ms"));
        return ok!string();
    }
    {
        auto up = bringUpDevice();
        if (up.hasError)
            return up;
    }

    SurfaceMetrics metrics;
    bool changed, destroyed, leave, frameDue, pressure;
    // Where the current surface's first frame spent its time.
    MonoTime surfaceArrived;
    Duration deviceTime, surfaceTime, swapchainTime, pipelineTime;
    bool firstFrameLogged = true;
    // What the current surface presented: frames from its first, over time.
    MonoTime firstFrameAt;
    uint framesBefore;
    bool pipelineBuiltNow;

    void loseSurface()
    {
        // Inside the drain that reported the loss: the platform destroys the
        // `ANativeWindow` once it returns.
        if (s.live && firstFrameLogged)
        {
            const shown = MonoTime.currTime - firstFrameAt;
            const presented = frames - framesBefore;
            say(text("surface: lost after ", presented, " frames in ", ms(shown), " ms (",
                shown > Duration.zero ? presented * 1000 / ms(shown) : 0, " fps)"));
        }
        s.release();
        frameDue = false;
        static if (releaseDeviceWithSurface)
            d.release();
        else if (d.live)
            d.saveCache(); // the process may be killed in the background
    }

    void pump(Duration timeout)
    {
        wsi.runIntegratedOnce(loop, timeout).value;
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in ReadyEvent e) { metrics = e.metrics; changed = true; },
                (in SurfaceMetricsChangedEvent e) {
                    metrics = e.metrics;
                    changed = true;
                    // Vulkan teardown is `@system`; the drain wants a `@safe` sink.
                    if (metrics.suspended)
                        () @trusted { loseSurface(); }();
                },
                (in FrameReadyEvent _) { frameDue = true; },
                (in MemoryPressureEvent _) { pressure = true; },
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

    // A new swapchain (or a first one, on a new surface) for the metrics.
    Expected!(void, string) rebuild(bool force)
    {
        if (!s.live)
        {
            auto handles = wsi.nativeHandles(window);
            if (handles.hasError)
                return ok!string(); // no surface yet
            surfaceArrived = MonoTime.currTime;
            firstFrameLogged = false;
            deviceTime = surfaceTime = swapchainTime = pipelineTime = Duration.zero;
            pipelineBuiltNow = false;
            const deviceStarted = MonoTime.currTime;
            {
                auto up = bringUpDevice();
                if (up.hasError)
                    return up;
            }
            deviceTime = MonoTime.currTime - deviceStarted;
            const surfaceStarted = MonoTime.currTime;
            auto made = WindowSurface.create(s.vk, d.device, handles.value);
            surfaceTime = MonoTime.currTime - surfaceStarted;
            if (made.hasError)
                return err!void(text("no Vulkan surface: ", made.error.diagnostic[]));
            ++surfacesBuilt;
        }
        // FIFO: one frame per display refresh, not as many as the GPU can.
        auto updated = s.presenter.rebuild(s.vk, metrics.physicalSize, force, PhysicalSize.init,
            VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR);
        swapchainTime += s.presenter.timing.create;
        if (updated.hasError)
            return err!void(updated.error);
        if (updated.value != SwapchainResize.rebuilt)
            return ok!string();
        ++swapchainsBuilt;
        // The pipeline outlives the surface: it is rebuilt only for a device
        // it was not made on, or a format it was not made for.
        if (d.pipeline.handle !is null && d.pipelineFormat != s.presenter.swapchain.format)
        {
            d.device.device.deviceWaitIdle(d.device.device.device);
            d.pipeline.destroy(d.device);
            d.pipeline = Pipeline.init;
        }
        if (d.pipeline.handle is null)
        {
            const pipelineStarted = MonoTime.currTime;
            scope (exit) pipelineTime += MonoTime.currTime - pipelineStarted;
            if (createTestPattern(d.pipeline, s.vk, s.presenter.swapchain, s.presenter.target.renderPass).hasError)
                return err!void("the pipeline failed");
            d.pipelineFormat = s.presenter.swapchain.format;
            d.cacheDirty = !d.pipeline.fromCache;
            ++pipelinesBuilt;
            pipelineBuiltNow = true;
        }
        if (d.commands.buffers.length == 0
            && CommandPool.create(d.commands, d.device, s.presenter.sync.framesInFlight).hasError)
            return err!void("the command pool failed");
        return ok!string();
    }

    string logged; // the last `pattern:` line
    Expected!(void, string) present()
    {
        // The display's own size and insets; the whole (panel-oriented) image
        // is drawn, and the shader turns the pattern upright.
        const shown = displayExtent(s.presenter.swapchain);
        const insets = metrics.safeInsets;
        FrameContext context;
        context.resolution = [shown.width, shown.height];
        context.safeInsets = [insets.left, insets.top, insets.right, insets.bottom];
        context.preTransform = cast(uint) s.presenter.swapchain.transform;
        context.frameCount = frames;
        // What this frame draws for, logged whenever it changes: a rebuild
        // and the metrics that settle a turn arrive separately, and the lane
        // checks a capture against the latest line.
        const state = text("pattern: display ", shown.width, "x", shown.height,
            " insets ", insets.left, ",", insets.top, ",", insets.right, ",", insets.bottom,
            " swapchain ", s.presenter.swapchain.extent.width, "x", s.presenter.swapchain.extent.height,
            " transform ", cast(uint) s.presenter.swapchain.transform,
            " format ", cast(uint) s.presenter.swapchain.format,
            s.presenter.target.dynamicRendering ? " dynamic-rendering" : " render-pass",
            " device ", d.device.deviceName);
        if (state != logged)
        {
            logged = state;
            say(state);
        }
        auto drawn = s.presenter.presentFrame!((uint image) => record(s.vk, d.commands, d.pipeline,
            s.presenter.target, s.presenter.swapchain, s.presenter.sync.frame, image,
            s.presenter.swapchain.extent, (cast(const(void)*) &context)[0 .. context.sizeof]))(
            s.vk, d.commands);
        if (drawn.hasError)
            return err!void(drawn.error);
        if (!drawn.value.presented)
            return drawn.value.stale ? rebuild(true) : ok!string();
        ++frames;
        if (!firstFrameLogged)
        {
            firstFrameLogged = true;
            firstFrameAt = MonoTime.currTime;
            framesBefore = frames - 1;
            const pipeline = !pipelineBuiltNow ? "pipeline kept"
                : text("pipeline ", ms(pipelineTime), " ms (", !d.pipeline.creationFeedback
                    ? "the driver does not say if cached"
                    : d.pipeline.fromCache ? "from the cache" : "compiled", ")");
            say(text("launch: ", surfacesBuilt == 1 ? "first surface" : "next surface",
                " first frame ", ms(MonoTime.currTime - surfaceArrived), " ms after it (",
                surfacesBuilt == 1 ? text(ms(MonoTime.currTime - processStarted), " ms after start, ") : "",
                "device ", ms(deviceTime), " ms, surface ", ms(surfaceTime),
                " ms, swapchain ", ms(swapchainTime), " ms, ", pipeline,
                "); built so far: ", devicesBuilt, " devices, ", pipelinesBuilt,
                " pipelines, ", surfacesBuilt, " surfaces, ", swapchainsBuilt,
                " swapchains; ", frames, " frames presented"));
            say(text("ok: Android test pattern presenting (", d.device.deviceName, ")"));
        }
        if (drawn.value.stale)
            return rebuild(true);
        return ok!string();
    }

    while (!destroyed)
    {
        if (leave)
        {
            leave = false;
            assert(!wsi.finishActivity().hasError);
        }
        // Asleep until an event: a frame opportunity, input, a new surface.
        pump(frameDue ? Duration.zero : 10.seconds);
        if (pressure)
        {
            pressure = false;
            // In the foreground the device is in use; in the background it
            // is what the system wants back.
            if (!s.live && d.live)
            {
                d.release();
                say("pressure: released the device");
            }
        }
        if (metrics.suspended)
            continue;
        // A turn arrives as a new window size and a new surface transform,
        // separately: ask the surface before every frame, not only on an event.
        if (changed || (s.live && frameDue && s.presenter.swapchain.outdated(s.vk, metrics.physicalSize)))
        {
            changed = false;
            auto rebuilt = rebuild(false);
            if (rebuilt.hasError)
                return rebuilt;
        }
        if (!frameDue)
            continue;
        frameDue = false;
        if (!s.live || s.presenter.swapchain.handle is null)
            continue;
        auto presented = present();
        if (presented.hasError)
            return presented;
        // The pattern animates, so it asks for the next frame after each.
        assert(!wsi.requestFrame(window).hasError);
        if (s.presenter.hasRetired)
            s.presenter.reap(s.vk);
    }
    say(text("ok: Android test pattern ended (", frames, " frames, ", swapchainsBuilt, " swapchains)"));
    return ok!string();
}
