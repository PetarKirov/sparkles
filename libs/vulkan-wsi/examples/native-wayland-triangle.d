#!/usr/bin/env dub
/+ dub.sdl:
    name "native_wayland_triangle"
    dependency "sparkles:vulkan-wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "expected" version="~>0.4.1"
    targetPath "build"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
A Vulkan triangle on native `sparkles:wsi` Wayland and Event Horizon.

There is no SDL or libdecor in this process. The window's configure listener
acknowledges immediately, queues owned WSI events, and Event Horizon performs
the only application wait. This host and the SDL compatibility example share
the command pool, frame synchronization, swapchain, renderer, and SPIR-V.
*/
module native_wayland_triangle;

version (linux):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.stdio : writeln;

import expected : Expected, err, ok;

import sparkles.base.logger : LogLevel, initLogger, trace;
import sparkles.base.prettyprint : PrettyPrintOptions, prettyPrint;
import sparkles.core_cli.args;
import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.event_horizon.errors : IoError;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.triangle;
import sparkles.wired : CaseStyle, WireCase;
import sparkles.wsi;

/**
CLI / report spelling of a present mode, including `auto`.

`@WireCase` kebab-cases the identifiers (`fifoRelaxed` → `fifo-relaxed`);
the trailing underscore on `auto_` is a word separator, so the wire name
is `auto`. Values match `VkPresentModeKHR` so a non-`auto` choice is a
cast, not a table. Same shape as the SDL triangle's `PresentMode`.
*/
@WireCase(CaseStyle.kebabCase)
enum PresentMode : uint
{
    immediate   = VkPresentModeKHR.VK_PRESENT_MODE_IMMEDIATE_KHR,
    mailbox     = VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR,
    fifo        = VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
    fifoRelaxed = VkPresentModeKHR.VK_PRESENT_MODE_FIFO_RELAXED_KHR,
    auto_       = uint.max,
}

int main(string[] args) => runCli!NativeWaylandTriangle(args);

@(Command("native-wayland-triangle",
    shortDescription: "Draw a Vulkan triangle through native sparkles:wsi Wayland",
    description: "No SDL or libdecor is loaded. The Wayland connection is "
        ~ "owned by sparkles:wsi and Event Horizon performs the only wait.",
))
struct NativeWaylandTriangle
{
    @(Option(`W|width`, description: "Window width in logical units"))
    uint width = 960;

    @(Option(`H|height`, description: "Window height in logical units"))
    uint height = 540;

    @(Option(`f|frames`,
        description: "Present N frames then exit (0 = run until the window closes)"))
    uint frames = 120;

    @(Option("validation", description: "Enable VK_LAYER_KHRONOS_validation if installed"))
    bool validation;

    @(Option("no-color", description: "Disable colored output"))
    bool noColor;

    @(Option("resize-stress",
        description: "Toggle maximize every 30 frames (exercises swapchain rebuild)"))
    bool resizeStress;

    @(Option("present-mode",
        description: "Swapchain present mode (auto = mailbox if offered, else fifo)"))
    PresentMode presentMode = PresentMode.auto_;

    @(Option("trace-ms",
        description: "Trace lifecycle stages and frames of at least N milliseconds"))
    uint traceMs;

    Expected!(void, string) run() @system => drive(this);
}

/// What the run actually did, so a scripted invocation is verifiable.
struct RunReport
{
    string device;
    uint framesPresented;
    uint resizeEvents;
    uint swapchainsBuilt;
    uint outOfDate;
    uint framesOver50ms;
    uint framesOver100ms;
    uint reaps;
    double maxFrameMs = 0;
    double maxDispatchMs = 0;
    string extent;
    string rendering;
    string exitedBecause;
}

private Expected!(void, string) drive(in NativeWaylandTriangle options) @system
{
    initLogger(options.traceMs > 0 ? LogLevel.trace : LogLevel.info);

    if (options.width == 0 || options.height == 0)
        return err!void("width and height must be non-zero");

    const preferred = options.presentMode == PresentMode.auto_
        ? anyPresentMode
        : cast(VkPresentModeKHR) options.presentMode;

    DefaultLoop loop;
    auto loopOpened = DefaultLoop.create(loop, LoopConfig());
    if (loopOpened.hasError)
        return err!void("Event Horizon open failed: " ~ describe(loopOpened.error));
    scope (exit)
        loop.destroy();

    WaylandWsi wsi;
    auto wsiOpened = WaylandWsi.open(wsi, loop);
    if (wsiOpened.hasError)
    {
        if (wsiOpened.error.kind == WsiErrorKind.unavailable)
        {
            writeln("SKIP: no Wayland compositor");
            return ok!string();
        }
        return err!void(describe(wsiOpened.error));
    }
    scope (exit)
        cast(void) wsi.close();

    const startupDeadline = MonoTime.currTime + 5.seconds;
    while (!wsi.bootstrapComplete)
    {
        auto tick = wsi.runIntegratedOnce(loop, 1.seconds);
        if (tick.hasError)
            return err!void("Event Horizon/Wayland bootstrap failed: "
                ~ describe(tick.error));
        if (MonoTime.currTime >= startupDeadline)
            return err!void("Wayland registry bootstrap timed out");
    }
    if (!wsi.canCreateWindows)
        return err!void("Wayland compositor lacks required globals");
    trace(i"Wayland registry ready");

    WindowConfig config;
    if (!config.title.assign("sparkles - native Wayland Vulkan triangle"))
        return err!void("window title exceeds WSI capacity");
    config.logicalSize = LogicalSize(options.width, options.height);
    config.decorations = DecorationPreference.client;
    auto created = wsi.createWindow(config);
    if (created.hasError)
        return err!void(describe(created.error));
    const window = created.value;

    SurfaceMetrics metrics;
    bool ready;
    bool frameReady;
    bool closeRequested;
    bool sizeChanged;
    bool exposed;

    auto drainEvents = () {
        sizeChanged = false;
        exposed = false;
        return wsi.drain((WindowEvent event) {
            if (event.window != window)
                return;
            event.payload.match!(
                (in ReadyEvent value) {
                    metrics = value.metrics;
                    ready = true;
                },
                (in SurfaceMetricsChangedEvent value) {
                    metrics = value.metrics;
                    sizeChanged = true;
                },
                (in FrameReadyEvent _) { frameReady = true; },
                (in ExposedEvent _) { exposed = true; },
                (in CloseRequestedEvent _) { closeRequested = true; },
                (_) {});
        });
    };

    while (!ready)
    {
        auto tick = wsi.runIntegratedOnce(loop, 1.seconds);
        if (tick.hasError)
            return err!void("Event Horizon/Wayland configure failed: "
                ~ describe(tick.error));
        auto drained = drainEvents();
        if (drained.hasError)
            return err!void(describe(drained.error));
        if (MonoTime.currTime >= startupDeadline)
            return err!void("initial Wayland configure timed out");
    }
    trace(i"initial configure acknowledged");

    auto handles = wsi.nativeHandles(window);
    if (handles.hasError)
        return err!void(describe(handles.error));

    VulkanContext vk;
    auto borrowed = wsi.beginNativeIo();
    if (borrowed.hasError)
        return err!void(describe(borrowed.error));
    auto broughtUp = VulkanContext.create(vk, handles.value,
        ContextRequest(applicationName: "sparkles-native-wayland-triangle",
            apiVersion: apiVersion13,
            validation: options.validation));
    auto returned = wsi.endNativeIo();
    if (broughtUp.hasError)
        return skip("cannot bring up Vulkan", describe(broughtUp.error));
    if (returned.hasError)
        return err!void(describe(returned.error));
    trace(i"Vulkan context ready");
    scope (exit)
        vk.destroy();

    Swapchain swapchain;
    RenderTarget target;
    FrameSync sync;
    CommandPool commands;
    Pipeline pipeline;
    scope (exit)
    {
        if (vk.device.device !is null)
            cast(void) vk.device.deviceWaitIdle(vk.device.device);
        pipeline.destroy(vk);
        commands.destroy(vk);
        sync.destroy(vk);
        target.destroy(vk);
        swapchain.destroy(vk);
    }

    uint swapchainsBuilt;
    MonoTime lastResize = MonoTime.currTime;

    Expected!(SwapchainResize, string) rebuild(bool force = false)
    {
        if (metrics.suspended)
            return ok!string(SwapchainResize.paused);

        auto waited = sync.waitAll(vk);
        if (waited.hasError)
            return err!SwapchainResize("vkWaitForFences: "
                ~ describeResult(waited.error));

        auto paused = wsi.beginNativeIo();
        if (paused.hasError)
            return err!SwapchainResize(describe(paused.error));
        trace(i"creating/rebuilding swapchain");
        auto updated = Swapchain.recreate(swapchain, vk,
            metrics.physicalSize, force, PhysicalSize.init,
            preferred);
        auto resumed = wsi.endNativeIo();
        if (updated.hasError)
            return err!SwapchainResize(updated.error);
        if (resumed.hasError)
            return err!SwapchainResize(describe(resumed.error));
        if (updated.value != SwapchainResize.rebuilt)
            return updated;

        auto retargeted = target.views.length == 0
            ? RenderTarget.create(target, vk, swapchain)
            : target.rebind(vk, swapchain);
        if (retargeted.hasError)
            return err!SwapchainResize(retargeted.error);

        const imageCount = cast(uint) swapchain.images.length;
        if (sync.imageCount == 0)
        {
            auto createdSync = FrameSync.create(sync, vk, imageCount);
            if (createdSync.hasError)
                return err!SwapchainResize(createdSync.error);
        }
        else
        {
            auto replaced = sync.replaceImages(vk, imageCount);
            if (replaced.hasError)
                return err!SwapchainResize(replaced.error);
        }
        ++swapchainsBuilt;
        lastResize = MonoTime.currTime;
        trace(i"swapchain resources ready");
        return updated;
    }

    auto initial = rebuild();
    if (initial.hasError)
        return skip("cannot create a Wayland swapchain", initial.error);
    if (initial.value != SwapchainResize.rebuilt)
        return err!void("initial Wayland surface is suspended");

    auto built = Pipeline.create(pipeline, vk, swapchain.format,
        target.renderPass);
    if (built.hasError)
        return err!void(built.error);
    auto pooled = CommandPool.create(commands, vk, sync.framesInFlight);
    if (pooled.hasError)
        return err!void(pooled.error);
    trace(i"pipeline and command pool ready");

    uint framesPresented;
    uint resizeEvents;
    uint outOfDate;
    uint framesOver50ms;
    uint framesOver100ms;
    uint reaps;
    double maxFrameMs = 0;
    double maxDispatchMs = 0;
    string exitedBecause = "frame budget reached";
    bool maximized;
    uint lastStressFrame = uint.max;

    Expected!(void, string) presentOnce()
    {
        trace(i"waiting for frame slot");
        auto waited = sync.waitForFrame(vk);
        if (waited.hasError)
            return err!void("vkWaitForFences: " ~ describeResult(waited.error));

        uint imageIndex;
        trace(i"acquiring swapchain image");
        auto acquireBorrow = wsi.beginNativeIo();
        if (acquireBorrow.hasError)
            return err!void(describe(acquireBorrow.error));
        const acquired = vk.device.acquireNextImageKHR(vk.device.device,
            swapchain.handle, ulong.max, sync.imageAvailable, null, &imageIndex);
        auto acquireReturned = wsi.endNativeIo();
        if (acquireReturned.hasError)
            return err!void(describe(acquireReturned.error));
        const decision = decideAcquire(acquired);
        if (decision.failed)
            return err!void("vkAcquireNextImageKHR: " ~ describeResult(acquired));
        if (!decision.proceed)
        {
            if (decision.recreate)
            {
                ++outOfDate;
                auto updated = rebuild(true);
                if (updated.hasError)
                    return err!void(updated.error);
            }
            return ok!string();
        }

        auto imageWaited = sync.waitForImage(vk, imageIndex);
        if (imageWaited.hasError)
            return err!void("vkWaitForFences (image): "
                ~ describeResult(imageWaited.error));
        auto begun = sync.beginFrame(vk, imageIndex);
        if (begun.hasError)
            return err!void("vkResetFences: " ~ describeResult(begun.error));
        auto recorded = record(vk, commands, pipeline, target, swapchain,
            sync.frame, imageIndex,
            drawableExtent(swapchain, metrics.physicalSize));
        if (recorded.hasError)
            return recorded;
        auto submitted = sync.submit(vk, commands.buffers[sync.frame], imageIndex);
        if (submitted.hasError)
            return err!void("vkQueueSubmit: " ~ describeResult(submitted.error));

        trace(i"presenting swapchain image");
        auto presentBorrow = wsi.beginNativeIo();
        if (presentBorrow.hasError)
            return err!void(describe(presentBorrow.error));
        auto presented = swapchain.present(vk, imageIndex,
            sync.renderFinished(imageIndex));
        auto presentReturned = wsi.endNativeIo();
        if (presentReturned.hasError)
            return err!void(describe(presentReturned.error));
        sync.advance();
        ++framesPresented;
        if (presented.hasError
            && !Swapchain.needsRecreation(presented.error))
            return err!void("vkQueuePresentKHR: "
                ~ describeResult(presented.error));
        if ((presented.hasError
                && Swapchain.needsRecreation(presented.error))
            || (!presented.hasError
                && Swapchain.needsRecreation(presented.value))
            || decision.recreate)
        {
            ++outOfDate;
            auto updated = rebuild(true);
            if (updated.hasError)
                return err!void(updated.error);
        }
        return ok!string();
    }

    // The initial configure includes one immediate FrameReadyEvent. Thereafter
    // wl_surface.frame callbacks pace ordinary frames; resize/expose events are
    // also allowed to submit promptly after configure has already been acked.
    while (!closeRequested
        && (options.frames == 0 || framesPresented < options.frames))
    {
        if (!frameReady && !sizeChanged && !exposed)
        {
            // This wait spans compositor pacing, so a long dispatch while
            // dragging is a stall, but a long dispatch while idle is not.
            const dispatchStarted = MonoTime.currTime;
            auto tick = wsi.runIntegratedOnce(loop, 2.seconds);
            if (tick.hasError)
                return err!void("Event Horizon/Wayland dispatch failed: "
                    ~ describe(tick.error));
            auto drained = drainEvents();
            if (drained.hasError)
                return err!void(describe(drained.error));
            const dispatchMs =
                (MonoTime.currTime - dispatchStarted).total!"usecs" / 1_000.0;
            if (dispatchMs > maxDispatchMs)
                maxDispatchMs = dispatchMs;
            if (options.traceMs > 0 && dispatchMs >= options.traceMs)
                trace(i"dispatch {yellow $(dispatchMs)ms} events=$(
                    sizeChanged ? "resize" : frameReady ? "frame" : "other")");
        }

        if (closeRequested)
        {
            exitedBecause = "window closed";
            break;
        }
        const workStarted = MonoTime.currTime;
        if (sizeChanged)
        {
            ++resizeEvents;
            auto updated = rebuild();
            if (updated.hasError)
                return err!void(updated.error);
        }
        if (metrics.suspended)
        {
            frameReady = exposed = sizeChanged = false;
            continue;
        }

        const shouldPresent = frameReady || exposed || sizeChanged;
        frameReady = exposed = sizeChanged = false;
        if (!shouldPresent)
            continue;

        auto presented = presentOnce();
        if (presented.hasError)
            return presented;
        // Active work only: swapchain rebuild plus the present, never the
        // compositor-paced dispatch wait above.
        const frameMs = (MonoTime.currTime - workStarted).total!"usecs" / 1_000.0;
        if (frameMs > maxFrameMs)
            maxFrameMs = frameMs;
        if (frameMs >= 50)
            ++framesOver50ms;
        if (frameMs >= 100)
            ++framesOver100ms;
        if (options.traceMs > 0 && frameMs >= options.traceMs)
            trace(i"frame $(framesPresented) {yellow $(frameMs)ms} window=$(
                metrics.physicalSize.width)x$(metrics.physicalSize.height) swapchain=$(
                swapchain.extent.width)x$(swapchain.extent.height)");

        if ((sync.hasRetired || swapchain.hasRetired)
            && MonoTime.currTime - lastResize >= 100.msecs)
        {
            sync.reap(vk, 8);
            swapchain.reap(vk, 1);
            ++reaps;
        }

        if (options.resizeStress && framesPresented > 0
            && framesPresented % 30 == 0
            && framesPresented != lastStressFrame)
        {
            lastStressFrame = framesPresented;
            maximized = !maximized;
            auto resized = wsi.setMaximized(window, maximized);
            if (resized.hasError)
                return err!void(describe(resized.error));
        }
    }

    const report = RunReport(
        device: vk.deviceName,
        framesPresented: framesPresented,
        resizeEvents: resizeEvents,
        swapchainsBuilt: swapchainsBuilt,
        outOfDate: outOfDate,
        framesOver50ms: framesOver50ms,
        framesOver100ms: framesOver100ms,
        reaps: reaps,
        maxFrameMs: maxFrameMs,
        maxDispatchMs: maxDispatchMs,
        extent: text(swapchain.extent.width, "x", swapchain.extent.height),
        rendering: target.dynamicRendering ? "dynamic" : "render-pass",
        exitedBecause: exitedBecause,
    );
    auto opt = PrettyPrintOptions!void(colored: !options.noColor, softMaxWidth: 100);
    writeln(prettyPrint(report, opt));
    return ok!string();
}

/// A skip is a success: the environment lacks a compositor or a driver.
private Expected!(void, string) skip(string what, string detail)
{
    writeln("SKIP: ", what, " — ", detail);
    return ok!string();
}

private string describe(in WsiError error)
    => text("WSI ", error.operation, "/", error.kind, " (", error.backend,
        ", native=", error.nativeCode, "): ", error.diagnostic.value);

private string describe(in VulkanWsiError error)
    => text("Vulkan WSI ", error.operation, "/", error.kind, " (", error.backend,
        ", ", describeResult(error.vkResult), "): ", error.diagnostic.value);

private string describe(in IoError error)
    => text(error.op, "/", error.stage, " errno=", error.errnoValue,
        ": ", error.context);
