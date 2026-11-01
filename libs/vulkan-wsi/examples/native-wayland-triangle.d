#!/usr/bin/env dub
/+ dub.sdl:
    name "native_wayland_triangle"
    dependency "sparkles:vulkan-wsi" path="../../.."
    subConfiguration "sparkles:vulkan-wsi" "gpu-shaders"
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
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

import sparkles.base.expected : Expected, err, ok;

import sparkles.base.logger : info, LogLevel, trace;
import sparkles.base.prettyprint : PrettyPrintOptions, prettyPrint;
import sparkles.core_cli.args;
import sparkles.event_horizon : DefaultLoop, LoopConfig;
import sparkles.input.events : PointerButton;
import sparkles.event_horizon.errors : IoError;
import sparkles.vulkan;
import sparkles.vulkan_wsi;
import sparkles.vulkan_wsi.presenter : Presenter, presentFrame;
import sparkles.vulkan_wsi.triangle;
import sparkles.wsi;

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
    uint framesPresented;
    uint resizeEvents;
    uint swapchainsBuilt;
    uint outOfDate;
    uint reaps;
    FrameStats frames; /// active work per frame: the rebuild and the present
    double maxDispatchMs = 0;
    string extent;
    string rendering;
    string exitedBecause;
}

private RunExpected!void drive(in NativeWaylandTriangle options) @system
{
    if (options.width == 0 || options.height == 0)
        return failRun("width and height must be non-zero");

    const preferred = options.presentMode.toVk;

    DefaultLoop loop;
    auto loopOpened = DefaultLoop.create(loop, LoopConfig());
    if (loopOpened.hasError)
        return failRun("Event Horizon open failed: " ~ describe(loopOpened.error));
    WaylandWsi wsi;
    auto wsiOpened = WaylandWsi.open(wsi, loop);
    if (wsiOpened.hasError)
    {
        if (wsiOpened.error.kind == WsiErrorKind.unavailable)
            return skipRun("no Wayland compositor");
        return failRun(describe(wsiOpened.error));
    }
    const startupDeadline = MonoTime.currTime + 5.seconds;
    while (!wsi.bootstrapComplete)
    {
        auto tick = wsi.runIntegratedOnce(loop, 1.seconds);
        if (tick.hasError)
            return failRun("Event Horizon/Wayland bootstrap failed: "
                ~ describe(tick.error));
        if (MonoTime.currTime >= startupDeadline)
            return failRun("Wayland registry bootstrap timed out");
    }
    if (!wsi.canCreateWindows)
        return failRun("Wayland compositor lacks required globals");
    trace(i"Wayland registry ready");

    WindowConfig config;
    if (!config.title.assign("sparkles - native Wayland Vulkan triangle"))
        return failRun("window title exceeds WSI capacity");
    config.logicalSize = LogicalSize(options.width, options.height);
    config.decorations = DecorationPreference.client;
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

    bool wantMove;
    ResizeEdge wantResize;

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
                (in PointerEvent value) {
                    // GNOME draws no server decorations, so a bare toplevel
                    // has nothing to grab: a press near a border hands the
                    // drag to the compositor as an interactive resize, and
                    // an alt-press anywhere as a move. Recorded here, sent
                    // after the drain — the sink stays platform-call-free.
                    if (value.phase != PointerPhase.pressed
                        || value.button != PointerButton.left)
                        return;
                    if (value.modifiers.alt)
                        wantMove = true;
                    else
                        wantResize = resizeEdgeAt(metrics,
                            value.logicalPosition.x,
                            value.logicalPosition.y);
                },
                (_) {});
        });
    };

    void applyPointerRequests()
    {
        if (wantMove)
        {
            wantMove = false;
            wsi.startInteractiveMove(window);
        }
        if (wantResize != ResizeEdge.none)
        {
            const edge = wantResize;
            wantResize = ResizeEdge.none;
            wsi.startInteractiveResize(window, edge);
        }
    }

    while (!ready)
    {
        auto tick = wsi.runIntegratedOnce(loop, 1.seconds);
        if (tick.hasError)
            return failRun("Event Horizon/Wayland configure failed: "
                ~ describe(tick.error));
        auto drained = drainEvents();
        if (drained.hasError)
            return failRun(describe(drained.error));
        applyPointerRequests();
        if (MonoTime.currTime >= startupDeadline)
            return failRun("initial Wayland configure timed out");
    }
    trace(i"initial configure acknowledged");

    auto handles = wsi.nativeHandles(window);
    if (handles.hasError)
        return failRun(describe(handles.error));

    VulkanContext vk;
    auto borrowed = wsi.beginNativeIo();
    if (borrowed.hasError)
        return failRun(describe(borrowed.error));
    auto broughtUp = VulkanContext.create(vk, handles.value,
        ContextRequest(applicationName: "sparkles-native-wayland-triangle",
            apiVersion: apiVersion13,
            validation: options.validation));
    auto returned = wsi.endNativeIo();
    if (broughtUp.hasError)
        return skipRun("cannot bring up Vulkan", describe(broughtUp.error));
    if (returned.hasError)
        return failRun(describe(returned.error));
    trace(i"Vulkan context ready");

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

    MonoTime lastResize = MonoTime.currTime;

    // The swapchain's own calls borrow the Wayland connection from the WSI.
    Expected!(SwapchainResize, string) rebuild(bool force = false)
    {
        if (metrics.suspended)
            return ok!string(SwapchainResize.paused);
        trace(i"creating/rebuilding swapchain");
        auto updated = presenter.rebuild(vk, metrics.physicalSize, force, PhysicalSize.init,
            preferred, false, &wsi);
        if (!updated.hasError && updated.value == SwapchainResize.rebuilt)
        {
            lastResize = MonoTime.currTime;
            trace(i"swapchain resources ready");
        }
        return updated;
    }

    auto initial = rebuild();
    if (initial.hasError)
        return skipRun("cannot create a Wayland swapchain", initial.error);
    if (initial.value != SwapchainResize.rebuilt)
        return failRun("initial Wayland surface is suspended");

    auto built = createTriangle(pipeline, vk, presenter.swapchain.format,
        presenter.target.renderPass);
    if (built.hasError)
        return failRun(built.error);
    auto pooled = CommandPool.create(commands, vk, presenter.sync.framesInFlight);
    if (pooled.hasError)
        return failRun(pooled.error);
    trace(i"pipeline and command pool ready");

    uint resizeEvents;
    uint outOfDate;
    FrameStats frames;
    double maxDispatchMs = 0;
    string exitedBecause = "frame budget reached";
    bool maximized;
    uint lastStressFrame = uint.max;

    RunExpected!void presentOnce()
    {
        const extent = drawableExtent(presenter.swapchain, metrics.physicalSize);
        const view = triangleView(extent);
        trace(i"drawing a frame");
        auto shown = presenter.presentFrame!((uint image) => record(vk, commands, pipeline,
            presenter.target, presenter.swapchain, presenter.sync.frame, image, extent, view[]))(
            vk, commands, true, &wsi);
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

    // The initial configure includes one immediate FrameReadyEvent. Thereafter
    // wl_surface.frame callbacks pace ordinary frames; resize/expose events are
    // also allowed to submit promptly after configure has already been acked.
    while (!closeRequested
        && (options.frames == 0 || presenter.stats.framesPresented < options.frames))
    {
        if (!frameReady && !sizeChanged && !exposed)
        {
            // This wait spans compositor pacing, so a long dispatch while
            // dragging is a stall, but a long dispatch while idle is not.
            const dispatchStarted = MonoTime.currTime;
            auto tick = wsi.runIntegratedOnce(loop, 2.seconds);
            if (tick.hasError)
                return failRun("Event Horizon/Wayland dispatch failed: "
                    ~ describe(tick.error));
            auto drained = drainEvents();
            if (drained.hasError)
                return failRun(describe(drained.error));
            applyPointerRequests();
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
            auto resized = wsi.setMaximized(window, maximized);
            if (resized.hasError)
                return failRun(describe(resized.error));
        }
    }

    const report = RunReport(
        device: vk.deviceName,
        framesPresented: presenter.stats.framesPresented,
        resizeEvents: resizeEvents,
        swapchainsBuilt: presenter.stats.swapchainsBuilt,
        outOfDate: outOfDate,
        reaps: presenter.stats.reaps,
        frames: frames,
        maxDispatchMs: maxDispatchMs,
        extent: text(presenter.swapchain.extent.width, "x", presenter.swapchain.extent.height),
        rendering: presenter.target.dynamicRendering ? "dynamic" : "render-pass",
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
