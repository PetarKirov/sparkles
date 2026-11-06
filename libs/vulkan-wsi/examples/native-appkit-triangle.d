#!/usr/bin/env dub
/+ dub.sdl:
    name "native_appkit_triangle"
    dependency "sparkles:vulkan-wsi" path="../../.."
    subConfiguration "sparkles:vulkan-wsi" "gpu-shaders"
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    targetPath "build"
    platforms "osx"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
A Vulkan triangle on native `sparkles:wsi` AppKit and Event Horizon, through
MoltenVK.

The window's view hosts a `CAMetalLayer`; the surface is made from it with
`VK_EXT_metal_surface`. Event Horizon's kqueue is folded into the main
CFRunLoop, so the hosted wait is the only one. Shares the presenter,
renderer and SPIR-V with `native-wayland-triangle.d`.
*/
module native_appkit_triangle;

version (OSX):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.stdio : writeln;

import sparkles.base.expected : Expected, err, ok;

import sparkles.base.logger : info, LogLevel, trace;
import sparkles.base.prettyprint : PrettyPrintOptions, prettyPrint;
import sparkles.core_cli.args;
import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.input.events : PointerButton;
import sparkles.profiling.frame : FrameClock, FrameRecord;
import sparkles.profiling.stats : FrameStats;
import sparkles.event_horizon.errors : IoError;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.presenter : Presenter, presentFrame;
import sparkles.vulkan_wsi.triangle;
import sparkles.wsi;

int main(string[] args) => runCli!NativeAppKitTriangle(args);

@(Command("native-appkit-triangle",
    shortDescription: "Draw a Vulkan triangle through native sparkles:wsi AppKit",
    description: "No SDL or GLFW is loaded. The NSWindow is owned by "
        ~ "sparkles:wsi, the surface is MoltenVK's, and Event Horizon performs the only wait.",
))
struct NativeAppKitTriangle
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
        description: "Resize the window every 30 frames (exercises swapchain rebuild)"))
    bool resizeStress;

    @(Option("present-mode",
        description: "Swapchain present mode (auto = mailbox if offered, else fifo)"))
    PresentMode presentMode = PresentMode.auto_;

    @(Option("trace-ms",
        description: "Log dispatches and frames of at least N milliseconds (--log-level trace shows the start-up stages)"))
    uint traceMs;

    @(Option("log-level", description: "Log level: trace | info | warning | error | critical | off"))
    LogLevel logLevel = LogLevel.info;

    RunExpected!void run() @system => drive(this);
}

/// What the run actually did, so a scripted invocation is verifiable.
struct RunReport
{
    string device;
    /// The present modes the surface offers, and the one in use.
    string presentModes;
    string presentMode;
    uint framesPresented;
    uint resizeEvents;
    uint swapchainsBuilt;
    uint outOfDate;
    uint reaps;
    FrameStats frames; /// active work per frame: the rebuild and the present
    /// What the GPU profiler got: `timestamps`, `calibrated`, `labels`, or
    /// `unsupported`.
    string gpuTiming;
    FrameStats gpuFrames; /// the device's time per frame, its "frame" scope
    double gpuTriangleMeanUs = 0; /// the draw's scope, on the device
    /// Calibrated only: how long before its collection a frame's GPU work
    /// began, on the CPU's clock — positive and a few frames at most.
    double gpuLagMinMs = 0, gpuLagMaxMs = 0;
    double maxDispatchMs = 0;
    string extent;
    string rendering;
    /// Presents tagged with ids and polled for completion
    /// (`VK_KHR_present_wait`), and the newest id seen complete.
    bool presentWait;
    ulong presentCompleted;
    string exitedBecause;
}

private RunExpected!void drive(in NativeAppKitTriangle options) @system
{
    if (options.width == 0 || options.height == 0)
        return failRun("width and height must be non-zero");

    const preferred = options.presentMode.toVk;

    DefaultLoop loop;
    auto loopOpened = DefaultLoop.create(loop, LoopConfig());
    if (loopOpened.hasError)
        return failRun("Event Horizon open failed: " ~ describe(loopOpened.error));
    AppKitWsi wsi;
    auto wsiOpened = AppKitWsi.open(wsi);
    if (wsiOpened.hasError)
    {
        if (wsiOpened.error.kind == WsiErrorKind.unavailable)
            return skipRun("no WindowServer");
        return failRun(describe(wsiOpened.error));
    }
    const startupDeadline = MonoTime.currTime + 5.seconds;
    auto step(Duration timeout) => loop.runHostedOnce(wsi, timeout);

    WindowConfig config;
    if (!config.title.assign("sparkles - native AppKit Vulkan triangle"))
        return failRun("window title exceeds WSI capacity");
    config.logicalSize = LogicalSize(options.width, options.height);
    auto created = wsi.createWindow(config);
    if (created.hasError)
        return failRun(describe(created.error));
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
        auto tick = step(1.seconds);
        if (tick.hasError)
            return failRun("Event Horizon/AppKit wait failed: "
                ~ describe(tick.error));
        auto drained = drainEvents();
        if (drained.hasError)
            return failRun(describe(drained.error));
        if (MonoTime.currTime >= startupDeadline)
            return failRun("the window was never ready");
    }
    trace(i"initial configure acknowledged");

    auto handles = wsi.nativeHandles(window);
    if (handles.hasError)
        return failRun(describe(handles.error));

    VulkanContext vk;
    auto broughtUp = VulkanContext.create(vk, handles.value,
        ContextRequest(applicationName: "sparkles-native-appkit-triangle",
            apiVersion: apiVersion13,
            validation: options.validation,
            debugLabels: true));
    if (broughtUp.hasError)
        return skipRun("cannot bring up Vulkan", describe(broughtUp.error));
    trace(i"Vulkan context ready");

    Presenter presenter;
    CommandPool commands;
    Pipeline pipeline;
    GpuProfiler gpu;
    scope (exit)
    {
        if (vk.device.device !is null)
            vk.device.deviceWaitIdle(vk.device.device);
        gpu.destroy(vk);
        pipeline.destroy(vk);
        commands.destroy(vk);
        presenter.destroy(vk);
    }

    MonoTime lastResize = MonoTime.currTime;

    Expected!(SwapchainResize, string) rebuild(bool force = false)
    {
        if (metrics.suspended)
            return ok!string(SwapchainResize.paused);
        trace(i"creating/rebuilding swapchain");
        auto updated = presenter.rebuild(vk, metrics.physicalSize, force, PhysicalSize.init,
            preferred, false);
        if (!updated.hasError && updated.value == SwapchainResize.rebuilt)
        {
            lastResize = MonoTime.currTime;
            trace(i"swapchain resources ready");
        }
        return updated;
    }

    auto initial = rebuild();
    if (initial.hasError)
        return skipRun("cannot create a MoltenVK swapchain", initial.error);
    if (initial.value != SwapchainResize.rebuilt)
        return failRun("initial surface is suspended");

    auto built = createTriangle(pipeline, vk, presenter.swapchain.format,
        presenter.target.renderPass);
    if (built.hasError)
        return failRun(built.error);
    auto pooled = CommandPool.create(commands, vk, presenter.sync.framesInFlight);
    if (pooled.hasError)
        return failRun(pooled.error);
    auto profiled = GpuProfiler.create(gpu, vk, presenter.sync.framesInFlight);
    if (profiled.hasError)
        return failRun(profiled.error);
    trace(i"pipeline and command pool ready");

    uint resizeEvents;
    uint outOfDate;
    FrameStats frames;
    const clock = FrameClock.monotonic();
    FrameStats gpuFrames;
    Duration gpuTriangle;
    uint gpuTriangles;
    double gpuLagMinMs = double.infinity, gpuLagMaxMs = 0;

    // What the slot measured the last time round, read once its fence was
    // waited — before the slot records again.
    void collectGpu(uint slot)
    {
        FrameRecord measured;
        if (!gpu.collect(vk, slot, measured, clock))
            return;
        gpuFrames.note(measured.gpu);
        const now = clock.now;
        foreach (s; measured.scopes)
        {
            if (gpu.names[s.name] == "triangle")
            {
                gpuTriangle += s.took;
                ++gpuTriangles;
            }
            if (s.calibrated && s.depth == 0)
            {
                const lagMs = (now - s.start).total!"usecs" / 1_000.0;
                gpuLagMinMs = lagMs < gpuLagMinMs ? lagMs : gpuLagMinMs;
                gpuLagMaxMs = lagMs > gpuLagMaxMs ? lagMs : gpuLagMaxMs;
            }
        }
    }
    double maxDispatchMs = 0;
    string exitedBecause = "frame budget reached";
    bool maximized;
    uint lastStressFrame = uint.max;

    RunExpected!void presentOnce()
    {
        const extent = drawableExtent(presenter.swapchain, metrics.physicalSize);
        const view = triangleView(extent);
        trace(i"drawing a frame");
        auto shown = presenter.presentFrame!((uint image) {
            collectGpu(presenter.sync.frame);
            return record(vk, commands, pipeline, presenter.target, presenter.swapchain,
                presenter.sync.frame, image, extent, view[], &gpu);
        })(vk, commands, true, null, presenter.stats.framesPresented);
        if (shown.hasError)
            return failRun(shown.error);
        if (shown.value.stale)
        {
            ++outOfDate;
            auto updated = rebuild(true);
            if (updated.hasError)
                return failRun(updated.error);
        }
        return ranOk();
    }

    // The window going on screen offers the first frame. AppKit offers no
    // frame callbacks to this host yet, so each frame after it is asked for
    // at once and FIFO's acquire paces it to the display.
    while (!closeRequested
        && (options.frames == 0 || presenter.stats.framesPresented < options.frames))
    {
        // A frame already wanted still reads the window system, without
        // waiting: input, a resize and a close must keep arriving.
        {
            const wanted = frameReady || sizeChanged || exposed;
            // This wait spans compositor pacing, so a long dispatch while
            // dragging is a stall, but a long dispatch while idle is not.
            const dispatchStarted = MonoTime.currTime;
            auto tick = step(wanted ? Duration.zero : 2.seconds);
            if (tick.hasError)
                return failRun("Event Horizon/AppKit dispatch failed: "
                    ~ describe(tick.error));
            const keepFrame = frameReady, keepExposed = exposed, keepSize = sizeChanged;
            auto drained = drainEvents();
            frameReady |= keepFrame;
            exposed |= keepExposed;
            sizeChanged |= keepSize;
            if (drained.hasError)
                return failRun(describe(drained.error));
                const dispatchMs =
                (MonoTime.currTime - dispatchStarted).total!"usecs" / 1_000.0;
            if (dispatchMs > maxDispatchMs)
                maxDispatchMs = dispatchMs;
            if (options.traceMs > 0 && dispatchMs >= options.traceMs)
                info(i"dispatch {yellow $(dispatchMs)ms} events=$(
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
                return failRun(updated.error);
        }
        if (metrics.suspended)
        {
            frameReady = exposed = sizeChanged = false;
            continue;
        }

        const shouldPresent = frameReady || exposed || sizeChanged;
        frameReady = exposed = sizeChanged = false;
        // Unpaced by the window system: the next frame is wanted at once.
        if (shouldPresent)
            frameReady = true;
        if (!shouldPresent)
            continue;

        auto presented = presentOnce();
        if (presented.hasError)
            return presented;
        // Active work only: swapchain rebuild plus the present, never the
        // compositor-paced dispatch wait above.
        const took = MonoTime.currTime - workStarted;
        frames.note(took);
        const frameMs = took.total!"usecs" / 1_000.0;
        if (options.traceMs > 0 && frameMs >= options.traceMs)
            info(i"frame $(presenter.stats.framesPresented) {yellow $(frameMs)ms} window=$(
                metrics.physicalSize.width)x$(metrics.physicalSize.height) swapchain=$(
                presenter.swapchain.extent.width)x$(presenter.swapchain.extent.height)");

        if (presenter.hasRetired && MonoTime.currTime - lastResize >= 100.msecs)
            presenter.reap(vk);

        if (options.resizeStress && presenter.stats.framesPresented > 0
            && presenter.stats.framesPresented % 30 == 0
            && presenter.stats.framesPresented != lastStressFrame)
        {
            lastStressFrame = presenter.stats.framesPresented;
            maximized = !maximized;
            auto resized = wsi.setLogicalSize(window, maximized
                ? LogicalSize(options.width * 3 / 2, options.height * 3 / 2)
                : LogicalSize(options.width, options.height));
            if (resized.hasError)
                return failRun(describe(resized.error));
        }
    }

    string offered;
    foreach (mode; queryVkList!VkPresentModeKHR(vk.instance.getPhysicalDeviceSurfacePresentModesKHR,
            vk.physicalDevice, vk.surface))
        offered ~= (offered.length ? ", " : "") ~ text(mode);
    const report = RunReport(
        device: vk.deviceName,
        presentModes: offered,
        presentMode: text(presenter.swapchain.presentMode),
        framesPresented: presenter.stats.framesPresented,
        resizeEvents: resizeEvents,
        swapchainsBuilt: presenter.stats.swapchainsBuilt,
        outOfDate: outOfDate,
        reaps: presenter.stats.reaps,
        frames: frames,
        gpuTiming: !gpu.supported ? "unsupported"
            : text("timestamps", gpu.calibrated ? ", calibrated" : "",
                gpu.labels ? ", labels" : ""),
        gpuFrames: gpuFrames,
        gpuTriangleMeanUs: gpuTriangles ? gpuTriangle.total!"nsecs" / 1_000.0 / gpuTriangles : 0,
        gpuLagMinMs: gpuLagMinMs == double.infinity ? 0 : gpuLagMinMs,
        gpuLagMaxMs: gpuLagMaxMs,
        maxDispatchMs: maxDispatchMs,
        extent: text(presenter.swapchain.extent.width, "x", presenter.swapchain.extent.height),
        rendering: presenter.target.dynamicRendering ? "dynamic" : "render-pass",
        presentWait: vk.presentWait,
        presentCompleted: presenter.presentWait.completed,
        exitedBecause: exitedBecause,
    );
    auto opt = PrettyPrintOptions!void(colored: !options.noColor, softMaxWidth: 100);
    writeln(prettyPrint(report, opt));
    return ranOk();
}

/// A skip is a success: the environment lacks a compositor or a driver.

private string describe(in WsiError error)
    => text("WSI ", error.operation, "/", error.kind, " (", error.backend,
        ", native=", error.nativeCode, "): ", error.diagnostic[]);

private string describe(in VulkanWsiError error)
    => text("Vulkan WSI ", error.operation, "/", error.kind, " (", error.backend,
        ", ", describeResult(error.vkResult), "): ", error.diagnostic[]);

private string describe(in IoError error)
    => text(error.op, "/", error.stage, " errno=", error.code,
        ": ", error.context);
