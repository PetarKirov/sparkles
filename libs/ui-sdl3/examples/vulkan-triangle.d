#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_triangle"
    dependency "sparkles:ui-sdl3" path="../../.."
    dependency "sparkles:vulkan" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "expected" version="~>0.4.1"
    stringImportPaths "shaders"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
 * A triangle, drawn through the whole stack with no toolkit and no Skia.
 *
 * This is the milestone the rest of `sparkles:ui-skia` is built on top of. It
 * proves the parts that are ours rather than Skia's — the SDL3 window, the
 * Vulkan instance and device chosen for its surface, the swapchain, and the
 * frame synchronisation — and it keeps proving them afterwards: when something
 * in the GPU stack breaks, this is the bisect point that answers "is it Skia
 * or is it us?" without Skia in the build at all.
 *
 * Nothing here is on `sparkles:ui-skia`'s path. Skia records its own render
 * passes and builds its own pipelines from a `VkImage` we hand it, so the
 * render pass, framebuffers and pipeline below stay in the example. If a
 * second direct-draw consumer ever appears they get promoted into the library,
 * the way `queryVkList` was promoted out of `vulkaninfo.d` once `ui-sdl3`
 * needed it — not before.
 *
 * What the library owns instead is everything that was genuinely hard:
 * `FrameSync` (per-image `renderFinished`, the suboptimal-finishes-its-frame
 * rule, the fence reset that must not happen early) and `CommandPool`.
 *
 * Native Wayland (no SDL / no libdecor) is the next WSI step. The session
 * that measured SDL+Mutter vs X11 and decided that is
 * `docs/specs/ui-sdl3/native-wayland-resize-handoff.md`.
 *
 * Running it headless, with no GPU, which is how the frame loop is checked:
 *
 * ---
 * Xvfb :80 -screen 0 1024x768x24 &
 * env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 DISPLAY=:80 ./build/vulkan_triangle --frames 0
 * ---
 *
 * $(B `-u WAYLAND_DISPLAY` and `SDL_VIDEODRIVER=x11` are both load-bearing.)
 * SDL3 prefers Wayland whenever `WAYLAND_DISPLAY` is set and ignores `DISPLAY`
 * entirely, so on a Wayland desktop a run wrapped in `xvfb-run` quietly opens
 * a window on the real session instead — it succeeds, it presents, and it
 * proves nothing about the headless path. The X server it was supposed to use
 * ends up with no children at all, which is the symptom to look for.
 *
 * With those set, Mesa falls back to `llvmpipe` and the whole loop runs in
 * software. The output is exact enough to assert on: at 960x540 the triangle
 * covers `0.5 * 576 * 324` = 93,312 pixels, its corners read back as the
 * shader's three vertex colours, and its centroid is their mean.
 *
 * Under validation, add the synchronization-validation feature — it is what
 * catches the semaphore-reuse class of bug this design exists to avoid.
 * `--resize-stress` changes the window size every frame through a band that
 * both shrinks and grows, which is the path that used to `vkDeviceWaitIdle`
 * and destroy objects a present still held. `--trace-ms N` logs any frame
 * whose wall time is at least N milliseconds:
 *
 * ---
 * VK_LAYER_VALIDATE_SYNC=1 ./build/vulkan_triangle --frames 300 --validation --resize-stress
 * ---
 *
 * (The older spelling is a `VK_LAYER_ENABLES` naming
 * `VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT`. The layer
 * still honours it and warns that it is deprecated, but — the part that
 * bites — deprecated settings take precedence and suppress the new ones
 * entirely, so the two must not be mixed.)
 */
module vulkan_triangle_example;

import std.format : format;

import expected : Expected, err, ok;

import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;
import sparkles.core_cli.args;
import sparkles.ui_sdl3;
import sparkles.vulkan;
import sparkles.wired;

/**
CLI / report spelling of a present mode, including `auto`.

`@WireCase` kebab-cases the identifiers (`fifoRelaxed` → `fifo-relaxed`);
the trailing underscore on `auto_` is a word separator, so the wire name
is `auto`. Values match `VkPresentModeKHR` so a non-`auto` choice is a
cast, not a table. Same shape as `VendorId` in `vulkaninfo.d`.
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

/**
Wayland client-side decorations.

GNOME's default libdecor plugin is GTK, and `libdecor-gtk` calls
`g_main_context_iteration` and `wl_display_roundtrip` from dispatch —
both can block for a compositor timeout (hundreds of ms to >1s) while
Mutter waits for a configure ack that Vulkan-WSI stole the frame
callback for. `cairo` loads only the cairo plugin. `none` asks SDL not
to use libdecor at all.
*/
@WireCase(CaseStyle.kebabCase)
enum Decor
{
    auto_,
    cairo,
    none,
}

@WireCase(CaseStyle.kebabCase)
enum VideoDriver
{
    auto_,
    wayland,
    x11,
}

int main(string[] args) => runCli!VulkanTriangle(args);

@(Command("vulkan-triangle",
    shortDescription: "Draw a triangle in an SDL3 window through Vulkan",
))
struct VulkanTriangle
{
    @(Option(`W|width`, description: "Window width in logical units"))
    int width = 960;

    @(Option(`H|height`, description: "Window height in logical units"))
    int height = 540;

    @(Option(`f|frames`,
        description: "Present N frames then exit (0 = run until the window closes)"))
    int frames = 120;

    @(Option("validation", description: "Enable VK_LAYER_KHRONOS_validation if installed"))
    bool validation;

    @(Option("no-color", description: "Disable colored output"))
    bool noColor;

    @(Option("resize-stress",
        description: "Change the window size every frame (exercises swapchain rebuild)"))
    bool resizeStress;

    @(Option("present-mode",
        description: "Swapchain present mode (auto = mailbox if offered, else fifo)"))
    PresentMode presentMode = PresentMode.auto_;

    @(Option("trace-ms",
        description: "Log frames whose wall time is at least N milliseconds"))
    uint traceMs;

    @(Option("decor",
        description: "Wayland decorations (auto / cairo / none). none skips libdecor's per-configure roundtrip"))
    Decor decor = Decor.none;

    @(Option("video-driver",
        description: "SDL video driver (auto / wayland / x11). x11 uses XWayland and avoids Mutter's sync configure"))
    VideoDriver videoDriver = VideoDriver.auto_;

    Expected!(void, string) run()
    {
        if (videoDriver != VideoDriver.auto_)
        {
            const name = videoDriver == VideoDriver.x11 ? "x11" : "wayland";
            setenv("SDL_VIDEODRIVER".toStringz, name.toStringz, 1);
        }
        applyWaylandDecor(decor);

        Window window;
        auto opened = Window.open(window, WindowRequest(
            title: "sparkles - vulkan triangle",
            width: width,
            height: height,
        ));
        // No display is a degraded environment, not a failure: CI runs this
        // with --help, and a developer on a tty should get a clear skip.
        if (opened.hasError)
            return skip("cannot open a window", opened.error);

        VulkanContext vk;
        auto brought = VulkanContext.create(vk, window, ContextRequest(
            applicationName: "sparkles-vulkan-triangle",
            apiVersion: apiVersion13,
            validation: validation,
        ));
        if (brought.hasError)
            return skip("cannot bring up Vulkan", brought.error);

        const preferred = presentMode == PresentMode.auto_
            ? anyPresentMode
            : cast(VkPresentModeKHR) presentMode;

        auto drawn = draw(vk, window, frames, resizeStress, preferred, traceMs, decor);
        if (drawn.hasError)
            return err!void(drawn.error);

        auto opt = PrettyPrintOptions!void(colored: !noColor, softMaxWidth: 100);
        writeln(prettyPrint(drawn.value, opt));
        return ok();
    }
}

import core.sys.posix.dlfcn : RTLD_NOLOAD, RTLD_NOW, dladdr, dlopen, dlsym, Dl_info;
import core.sys.posix.stdlib : setenv;
import core.time : MonoTime, msecs;

import std.file : exists, mkdirRecurse, remove, symlink;
import std.path : buildPath, dirName;
import std.stdio : stderr, writefln, writeln;
import std.string : fromStringz, toStringz;

/// Apply Wayland decoration policy before `SDL_Init`.
void applyWaylandDecor(Decor decor) @system
{
    final switch (decor)
    {
    case Decor.auto_:
        return;

    case Decor.none:
        setenv("SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR".toStringz, "0".toStringz, 1);
        return;

    case Decor.cairo:
        forceLibdecorCairo();
        return;
    }
}

/// Point libdecor at a directory that contains only the cairo plugin.
void forceLibdecorCairo() @system
{
    auto handle = dlopen("libdecor-0.so.0", RTLD_NOW | RTLD_NOLOAD);
    if (handle is null)
        handle = dlopen("libdecor-0.so.0", RTLD_NOW);
    if (handle is null)
        return;

    auto sym = dlsym(handle, "libdecor_new");
    Dl_info info;
    if (sym is null || dladdr(sym, &info) == 0 || info.dli_fname is null)
        return;

    const cairo = buildPath(dirName(info.dli_fname.fromStringz.idup),
        "libdecor", "plugins-1", "libdecor-cairo.so");
    if (!exists(cairo))
        return;

    const dir = "/tmp/sparkles-libdecor-cairo";
    mkdirRecurse(dir);
    const dest = buildPath(dir, "libdecor-cairo.so");
    if (exists(dest))
        remove(dest);
    symlink(cairo, dest);
    setenv("LIBDECOR_PLUGIN_DIR".toStringz, dir.toStringz, 1);
}

/**
Present one frame from inside `SDL_PumpEvents`.

libdecor commits a configure with `wl_display_roundtrip` after posting
`PIXEL_SIZE_CHANGED` and before the event loop can present. Mutter then
waits for a buffer. A *cheap* present here (no swapchain create) gives
it that buffer so the roundtrip returns. Creating a swapchain from this
watch is what turned a smooth drag into a multi-second pump.
*/
struct LiveResizeHook
{
    Expected!(void, string) delegate() present;
    string error;
    bool busy;
    bool didThisPump;
    uint presented;
}

private void invokeLiveResizePresent(LiveResizeHook* hook) @system
{
    // One present per PumpEvents. A configure burst otherwise plays back
    // every intermediate size inside the same pump — smooth, but a second
    // behind the cursor. The main loop presents the latest size after.
    if (hook.busy || hook.present is null || hook.didThisPump)
        return;
    hook.busy = true;
    auto r = hook.present();
    hook.busy = false;
    if (r.hasError)
        hook.error = r.error;
    else
    {
        hook.presented++;
        hook.didThisPump = true;
    }
}

extern (C) bool liveResizeWatch(void* userdata, SDL_Event* event) nothrow @nogc
{
    if (event is null)
        return true;
    const t = event.type;
    if (t != SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
        && t != SDL_EventType.SDL_EVENT_WINDOW_EXPOSED)
        return true;

    auto call = cast(void function(LiveResizeHook*) nothrow @nogc)&invokeLiveResizePresent;
    call(cast(LiveResizeHook*) userdata);
    return true;
}

/// A skip is a success: the environment lacks a display or a driver.
Expected!(void, string) skip(string what, string detail)
{
    writeln("SKIP: ", what, " — ", detail);
    return ok();
}

/// What the run actually did, so a headless invocation is verifiable.
struct RunReport
{
    string device;
    string format;
    string presentMode;
    uint imageCount;
    uint framesInFlight;
    string extent;
    string surfaceExtent;
    string decor;
    string videoDriver;
    uint framesPresented;
    uint swapchainsBuilt;
    uint rebuildsForced;
    uint acquireSuboptimal;
    uint acquireOutOfDate;
    uint presentSuboptimal;
    uint presentOutOfDate;
    uint reaps;
    uint watchPresents;
    uint pixelSizeEvents;
    uint maxPixelSizeEvents;
    uint eventsDrained;
    uint maxEventsDrained;
    uint framesOver50ms;
    uint framesOver100ms;
    double maxFrameMs = 0;
    double maxPollMs = 0;
    double maxPumpMs = 0;
    double maxPeepMs = 0;
    double maxWaitFrameMs = 0;
    double maxWaitAllMs = 0;
    double maxCreateMs = 0;
    double maxAcquireMs = 0;
    double maxPresentMs = 0;
    double maxReapMs = 0;
    string rendering;
    string exitedBecause;
}

// -----------------------------------------------------------------------------
// The frame loop
// -----------------------------------------------------------------------------

Expected!(RunReport, string) draw(ref VulkanContext vk, ref Window window,
    int frameBudget, bool resizeStress = false,
    VkPresentModeKHR preferredPresentMode = anyPresentMode,
    uint traceMs = 0, Decor decor = Decor.cairo) @system
{
    const driverName = SDL_GetCurrentVideoDriver();
    RunReport report = {
        device: vk.deviceName,
        decor: format("%s", decor),
        videoDriver: driverName is null ? "unknown" : driverName.fromStringz.idup,
    };

    Swapchain sc;
    RenderTarget target;
    FrameSync sync;
    CommandPool pool;
    Pipeline pipeline;
    // Quiet frames since the last swapchain build. Retired present
    // semaphores are reaped once this passes framesInFlight, so the wait
    // is already satisfied and a drag never serialises on vsync.
    uint framesSinceRebuild;
    long lastWaitAllUs, lastCreateUs;
    MonoTime lastSizeChange = MonoTime.currTime;

    double msOf(long us) @safe pure nothrow @nogc => us / 1_000.0;

    void noteMax(ref double slot, long us)
    {
        const ms = msOf(us);
        if (ms > slot)
            slot = ms;
    }

    // A resize is the swapchain and the views that name its images. Dynamic
    // rendering drops the framebuffers entirely; the render-pass fallback
    // keeps the pass and only rebuilds FBs when the swapchain actually
    // changes. Per-image renderFinished is replaced rather than reused — a
    // present may still be waiting on the old set — and reaped a few quiet
    // frames later. Waiting for in-flight fences (not vkDeviceWaitIdle) is
    // enough for the GPU work; oldSwapchain lets the presentation engine
    // keep scanning the old images out. A shrink into a display-padded
    // swapchain is a viewport/compositor scale, not a create.
    //
    // `force` is the acquire/present OUT_OF_DATE path: same pixel size still
    // rebuilds, because the driver has retired this handle. PIXEL_SIZE_CHANGED
    // leaves it false so a drag that reports the same size twice is a no-op.
    Expected!(void, string) rebuild(bool force = false)
    {
        lastWaitAllUs = 0;
        lastCreateUs = 0;

        auto px = window.pixelSize;
        if (px.hasError)
            return err!void(px.error);

        // Minimised: keep the old swapchain and stop drawing. Creating a
        // zero-area swapchain is invalid; destroying the old one would make
        // the restore more expensive than it needs to be.
        if (px.value.width <= 0 || px.value.height <= 0)
            return ok!string();

        // Grow-only. X11 presents 1:1: a shrink is a viewport into the
        // existing images; a grow must create or the triangle stays
        // small in a larger window. Slack / debounce made the numbers
        // prettier and the resize feel late — live tracking wins.
        if (!force && sc.handle !is null
            && cast(uint) px.value.width <= sc.extent.width
            && cast(uint) px.value.height <= sc.extent.height)
            return ok!string();

        if (force)
            report.rebuildsForced++;

        const waitStarted = MonoTime.currTime;
        auto waited = sync.waitAll(vk);
        lastWaitAllUs = (MonoTime.currTime - waitStarted).total!"usecs";
        noteMax(report.maxWaitAllMs, lastWaitAllUs);
        if (waited.hasError)
            return err!void("vkWaitForFences: " ~ describeResult(waited.error));

        const createStarted = MonoTime.currTime;
        auto updated = Swapchain.recreate(sc, vk, px.value, force);
        lastCreateUs = (MonoTime.currTime - createStarted).total!"usecs";
        noteMax(report.maxCreateMs, lastCreateUs);
        if (updated.hasError)
            return err!void(updated.error);
        if (updated.value != SwapchainResize.rebuilt)
            return ok!string();

        auto retargeted = target.views.length == 0
            ? RenderTarget.create(target, vk, sc)
            : target.rebind(vk, sc);
        if (retargeted.hasError)
            return retargeted;

        const images = cast(uint) sc.images.length;
        if (sync.imageCount == 0)
        {
            auto resynced = FrameSync.create(sync, vk, images);
            if (resynced.hasError)
                return resynced;
        }
        else
        {
            // New renderFinished, not a reuse: a present may still be
            // waiting on the old set. replaceImages retires them; they
            // are destroyed a few quiet frames later once the queue is idle.
            auto replaced = sync.replaceImages(vk, images);
            if (replaced.hasError)
                return replaced;
        }

        report.swapchainsBuilt++;
        framesSinceRebuild = 0;
        return ok!string();
    }

    auto started = rebuild();
    if (started.hasError)
        return err!RunReport(started.error);
    if (sc.handle is null)
        return err!RunReport("swapchain extent is zero (window minimised?)");

    {
        VkSurfaceCapabilitiesKHR caps;
        if (!vk.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
                vk.physicalDevice, vk.surface, &caps).check.hasError)
        {
            report.surfaceExtent = caps.currentExtent.width == uint.max
                ? "app-defined"
                : format("%dx%d", caps.currentExtent.width, caps.currentExtent.height);
        }
    }

    scope (exit)
    {
        cast(void) vk.device.deviceWaitIdle(vk.device.device);
        pipeline.destroy(vk);
        pool.destroy(vk);
        sync.destroy(vk);
        target.destroy(vk);
        sc.destroy(vk);
    }

    // The pipeline outlives a resize: viewport and scissor are dynamic state,
    // and the render pass is kept (format does not change with the window).
    auto built = Pipeline.create(pipeline, vk, sc.format, target.renderPass);
    if (built.hasError)
        return err!RunReport(built.error);

    auto pooled = CommandPool.create(pool, vk, sync.framesInFlight);
    if (pooled.hasError)
        return err!RunReport(pooled.error);

    long waitFrameUs, acquireUs, presentUs, reapUs;
    VkResult acquired = VkResult.VK_SUCCESS;
    VkResult presentedResult = VkResult.VK_SUCCESS;
    bool rebuiltThisFrame;

    Expected!(void, string) presentOnce(bool mayBlock)
    {
        auto px = window.pixelSize;
        if (px.hasError)
            return err!void(px.error);
        if (px.value.width <= 0 || px.value.height <= 0)
            return ok!string();

        if (sc.handle is null || sc.extent.width == 0 || sc.extent.height == 0)
            return ok!string();

        const waitFrameStarted = MonoTime.currTime;
        if (mayBlock)
        {
            auto waited = sync.waitForFrame(vk);
            waitFrameUs = (MonoTime.currTime - waitFrameStarted).total!"usecs";
            noteMax(report.maxWaitFrameMs, waitFrameUs);
            if (waited.hasError)
                return err!void("vkWaitForFences: " ~ describeResult(waited.error));
        }
        else
        {
            // Inside PumpEvents: never block. Skip if this slot is still busy.
            auto fence = sync.inFlight;
            const r = vk.device.waitForFences(
                vk.device.device, 1, &fence, VK_TRUE, 0);
            waitFrameUs = (MonoTime.currTime - waitFrameStarted).total!"usecs";
            noteMax(report.maxWaitFrameMs, waitFrameUs);
            if (r != VkResult.VK_SUCCESS)
                return ok!string();
        }

        uint index;
        const acquireStarted = MonoTime.currTime;
        acquired = vk.device.acquireNextImageKHR(vk.device.device, sc.handle,
            mayBlock ? ulong.max : 0, sync.imageAvailable, null, &index);
        acquireUs = (MonoTime.currTime - acquireStarted).total!"usecs";
        noteMax(report.maxAcquireMs, acquireUs);
        if (acquired == VkResult.VK_SUBOPTIMAL_KHR)
            report.acquireSuboptimal++;
        else if (acquired == VkResult.VK_ERROR_OUT_OF_DATE_KHR)
            report.acquireOutOfDate++;
        const decision = decideAcquire(acquired);

        if (decision.failed)
            return err!void("vkAcquireNextImageKHR: " ~ describeResult(acquired));

        if (!decision.proceed)
        {
            if (decision.recreate && mayBlock)
            {
                auto again = rebuild(true);
                if (again.hasError)
                    return again;
                rebuiltThisFrame = true;
            }
            return ok!string();
        }

        auto held = sync.waitForImage(vk, index);
        if (held.hasError)
            return err!void("vkWaitForFences (image): " ~ describeResult(held.error));

        auto begun = sync.beginFrame(vk, index);
        if (begun.hasError)
            return err!void("vkResetFences: " ~ describeResult(begun.error));

        auto recorded = record(vk, pool, pipeline, target, sc, sync.frame, index,
            drawableExtent(sc, px.value));
        if (recorded.hasError)
            return recorded;

        auto submitted = sync.submit(vk, pool.buffers[sync.frame], index);
        if (submitted.hasError)
            return err!void("vkQueueSubmit: " ~ describeResult(submitted.error));

        const presentStarted = MonoTime.currTime;
        const presented = sc.present(vk, index, sync.renderFinished(index));
        presentUs = (MonoTime.currTime - presentStarted).total!"usecs";
        noteMax(report.maxPresentMs, presentUs);
        presentedResult = presented.hasError ? presented.error : presented.value;
        if (presentedResult == VkResult.VK_SUBOPTIMAL_KHR)
            report.presentSuboptimal++;
        else if (presentedResult == VkResult.VK_ERROR_OUT_OF_DATE_KHR)
            report.presentOutOfDate++;
        sync.advance();
        report.framesPresented++;
        framesSinceRebuild++;

        if (presented.hasError && !Swapchain.needsRecreation(presented.error))
            return err!void("vkQueuePresentKHR: " ~ describeResult(presented.error));

        return ok!string();
    }

    LiveResizeHook hook;
    hook.present = () => presentOnce(false); // never block inside PumpEvents
    if (!SDL_AddEventWatch(&liveResizeWatch, &hook))
        return err!RunReport("SDL_AddEventWatch: " ~ sdlError());
    scope (exit)
        SDL_RemoveEventWatch(&liveResizeWatch, &hook);

    report.format = format("%s", sc.format);
    report.presentMode = presentModeName(sc.presentMode);
    report.imageCount = cast(uint) sc.images.length;
    report.framesInFlight = sync.framesInFlight;
    report.rendering = vk.dynamicRendering ? "dynamic" : "render-pass";
    report.exitedBecause = "frame budget reached";

    if (traceMs > 0)
    {
        stderr.writefln(
            "tracing frames ≥ %sms decor=%s driver=%s (resize, then close the window)",
            traceMs, report.decor, report.videoDriver);
        stderr.flush();
    }

    while (frameBudget == 0 || report.framesPresented < frameBudget)
    {
        if (resizeStress)
        {
            // Sweep a band that both shrinks and grows past the default
            // 960×540 window. The older 480–872 range never exceeded that,
            // so grow-only skipped every rebuild after the first create.
            const i = report.framesPresented;
            SDL_SetWindowSize(window.handle,
                400 + cast(int)(i % 80) * 16,
                240 + cast(int)(i % 60) * 12);
        }

        const frameStarted = MonoTime.currTime;
        long pollUs, pumpUs, peepUs;
        waitFrameUs = acquireUs = presentUs = reapUs = 0;
        acquired = VkResult.VK_SUCCESS;
        presentedResult = VkResult.VK_SUCCESS;
        rebuiltThisFrame = false;
        hook.didThisPump = false;
        uint sizeEvents, drained;
        char[128] evKindsBuf;
        uint evKindsLen;

        void noteEventKind(string name)
        {
            if (evKindsLen >= evKindsBuf.length)
                return;
            if (evKindsLen)
            {
                evKindsBuf[evKindsLen] = ',';
                evKindsLen++;
            }
            const room = cast(uint)(evKindsBuf.length - evKindsLen);
            const n = cast(uint)(name.length < room ? name.length : room);
            evKindsBuf[evKindsLen .. evKindsLen + n] = name[0 .. n];
            evKindsLen += n;
        }

        SDL_Event ev;
        bool quit;
        // One flag for the whole drain: a drag produces many PIXEL_SIZE_CHANGED
        // events per pump, and only the last size SDL reports is worth building.
        bool sizeChanged;
        const pollStarted = MonoTime.currTime;
        // Pump once, then take events off the queue. `SDL_PollEvent` in a
        // loop pumps on every event, and each pump can wait 4ms for a
        // Wayland socket that mailbox has filled — a fast drag then
        // costs `events × 4ms` inside what looks like one "poll".
        const pumpStarted = MonoTime.currTime;
        SDL_PumpEvents();
        pumpUs = (MonoTime.currTime - pumpStarted).total!"usecs";
        noteMax(report.maxPumpMs, pumpUs);
        const peepStarted = MonoTime.currTime;
        while (SDL_PeepEvents(&ev, 1, SDL_EventAction.SDL_GETEVENT, 0, uint.max) > 0)
        {
            drained++;
            if (ev.type == SDL_EventType.SDL_EVENT_QUIT
                || ev.type == SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED)
            {
                quit = true;
                noteEventKind("quit");
            }
            else if (ev.type == SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED)
            {
                sizeChanged = true;
                sizeEvents++;
                noteEventKind("pixel");
            }
            else if (ev.type == SDL_EventType.SDL_EVENT_WINDOW_RESIZED)
                noteEventKind("resized");
            else if (ev.type == SDL_EventType.SDL_EVENT_WINDOW_EXPOSED)
                noteEventKind("exposed");
            else if (ev.type == SDL_EventType.SDL_EVENT_WINDOW_RESTORED)
                noteEventKind("restored");
            else if (ev.type == SDL_EventType.SDL_EVENT_MOUSE_MOTION)
                noteEventKind("motion");
            else if (ev.type == SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN
                || ev.type == SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP)
                noteEventKind("button");
            else
                noteEventKind("other");
        }
        peepUs = (MonoTime.currTime - peepStarted).total!"usecs";
        noteMax(report.maxPeepMs, peepUs);
        pollUs = (MonoTime.currTime - pollStarted).total!"usecs";
        noteMax(report.maxPollMs, pollUs);
        report.eventsDrained += drained;
        if (drained > report.maxEventsDrained)
            report.maxEventsDrained = drained;
        report.pixelSizeEvents += sizeEvents;
        if (sizeEvents > report.maxPixelSizeEvents)
            report.maxPixelSizeEvents = sizeEvents;
        if (hook.error.length)
            return err!RunReport(hook.error);
        if (quit)
        {
            report.exitedBecause = "window closed";
            break;
        }

        auto pxNow = window.pixelSize;
        if (sc.handle is null || sc.extent.width == 0 || sc.extent.height == 0
            || (!pxNow.hasError && (pxNow.value.width <= 0 || pxNow.value.height <= 0)))
            continue;

        if (sizeChanged || hook.didThisPump)
            lastSizeChange = MonoTime.currTime;

        const builtBefore = report.swapchainsBuilt;
        auto grown = rebuild();
        if (grown.hasError)
            return err!RunReport(grown.error);
        if (report.swapchainsBuilt != builtBefore)
            rebuiltThisFrame = true;

        auto drawn = presentOnce(true);
        if (drawn.hasError)
            return err!RunReport(drawn.error);

        // 100ms of presenting the new chain is enough for the old
        // presents to finish. Do not queueWaitIdle — that blocked ~70ms
        // on a 5K swapchain — and destroy at most one swapchain (plus a
        // handful of semaphores) per frame so a batch of grows does not
        // hitch when the drag stops.
        if ((sync.hasRetired || sc.hasRetired)
            && MonoTime.currTime - lastSizeChange >= 100.msecs)
        {
            const reapStarted = MonoTime.currTime;
            sync.reap(vk, 8);
            sc.reap(vk, 1);
            reapUs = (MonoTime.currTime - reapStarted).total!"usecs";
            noteMax(report.maxReapMs, reapUs);
            report.reaps++;
        }

        const frameUs = (MonoTime.currTime - frameStarted).total!"usecs";
        noteMax(report.maxFrameMs, frameUs);
        if (frameUs >= 50_000)
            report.framesOver50ms++;
        if (frameUs >= 100_000)
            report.framesOver100ms++;
        if (traceMs > 0 && frameUs >= cast(long) traceMs * 1_000)
        {
            const win = pxNow.hasError ? PixelSize.init : pxNow.value;
            stderr.writefln(
                "trace frame=%s %.1fms win=%sx%s sc=%sx%s events=%s [%s] sizeEvents=%s " ~
                "rebuilt=%s watch=%s poll=%.1fms pump=%.1fms peep=%.1fms waitFrame=%.1fms " ~
                "acq=%s/%.1fms pres=%s/%.1fms waitAll=%.1fms create=%.1fms reap=%.1fms",
                report.framesPresented, msOf(frameUs),
                win.width, win.height, sc.extent.width, sc.extent.height,
                drained, evKindsBuf[0 .. evKindsLen], sizeEvents,
                rebuiltThisFrame, hook.didThisPump,
                msOf(pollUs), msOf(pumpUs), msOf(peepUs), msOf(waitFrameUs),
                resultName(acquired), msOf(acquireUs),
                resultName(presentedResult), msOf(presentUs),
                msOf(lastWaitAllUs), msOf(lastCreateUs), msOf(reapUs));
            stderr.flush();
        }

        // Mailbox does not wait for vsync, so an unpaced loop presents
        // thousands of times a second and fills the Wayland socket.
        // SDL's pump then waits 4ms per flush-EAGAIN; a drag that queued
        // hundreds of pointer events became a 1–2s stall. Cap well above
        // any display and well below that flood. FIFO already waits.
        // Don't sleep on a resize tick: the next configure may already
        // be waiting, and a 2ms nap is how a drag starts to trail the
        // cursor. Idle mailbox still needs the cap so we don't flood.
        if (!sizeChanged && !hook.didThisPump
            && sc.presentMode == VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR)
        {
            enum mailboxMinFrameNs = 2_000_000UL;
            const used = (MonoTime.currTime - frameStarted).total!"nsecs";
            if (used >= 0 && used < mailboxMinFrameNs)
                SDL_DelayNS(mailboxMinFrameNs - used);
        }
    }

    report.extent = format("%dx%d", sc.extent.width, sc.extent.height);
    report.watchPresents = hook.presented;
    return ok!string(report);
}

/// Window-sized top-left of a (possibly larger) swapchain.
///
/// X11 presents 1:1 and clips. After a shrink we keep the big images and
/// draw only this rect so the triangle tracks the window without a create.
VkExtent2D drawableExtent(in Swapchain sc, in PixelSize windowPx)
    @safe pure nothrow @nogc
{
    const w = cast(uint) windowPx.width;
    const h = cast(uint) windowPx.height;
    if (w == 0 || h == 0)
        return sc.extent;
    return VkExtent2D(
        width: w < sc.extent.width ? w : sc.extent.width,
        height: h < sc.extent.height ? h : sc.extent.height,
    );
}

@("vulkan_triangle.drawableExtentClampsToTheSwapchain")
@safe pure nothrow @nogc unittest
{
    Swapchain sc;
    sc.extent = VkExtent2D(2560, 1440);
    assert(drawableExtent(sc, PixelSize(800, 600)) == VkExtent2D(800, 600));
    assert(drawableExtent(sc, PixelSize(2560, 1440)) == VkExtent2D(2560, 1440));
    assert(drawableExtent(sc, PixelSize(3000, 2000)) == VkExtent2D(2560, 1440));
    assert(drawableExtent(sc, PixelSize(0, 600)) == sc.extent);
}

/// Record one frame: begin the pass, set the dynamic state, draw three vertices.
Expected!(void, string) record(ref VulkanContext vk, ref CommandPool pool,
    ref Pipeline pipeline, ref RenderTarget target, ref Swapchain sc,
    uint frame, uint imageIndex, VkExtent2D drawExtent) @system
{
    auto begun = pool.begin(vk, frame);
    if (begun.hasError)
        return err!void("vkBeginCommandBuffer: " ~ describeResult(begun.error));

    auto cmd = begun.value;

    VkClearValue clear;
    clear.color.float32 = [0.05f, 0.05f, 0.08f, 1.0f];

    if (target.dynamicRendering)
    {
        // Dynamic rendering does not do the render-pass layout dance, so
        // the acquire→colour and colour→present transitions are ours.
        // srcStage is COLOR_ATTACHMENT_OUTPUT to match the acquire
        // semaphore wait — TOP_OF_PIPE races the layout transition
        // against the presentation engine (SYNC-HAZARD-WRITE-AFTER-READ).
        //
        // dstAccess is READ|WRITE, not WRITE alone: we CLEAR (a write),
        // but an overlay layer (MangoHud) then BeginRenderPass-es with
        // LOAD to composite the HUD, and that is a color-attachment
        // *read* of the same view. Releasing only WRITE is
        // SYNC-HAZARD-READ-AFTER-WRITE on every frame the layer is on.
        transition(vk, cmd, sc.images[imageIndex],
            VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
            VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0,
            VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
                | VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);

        auto colour = vkInfo(VkRenderingAttachmentInfo(
            imageView: target.views[imageIndex],
            imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            loadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE,
            clearValue: clear,
        ));
        auto rendering = vkInfo(VkRenderingInfo(
            renderArea: VkRect2D(VkOffset2D(0, 0), drawExtent),
            layerCount: 1,
            colorAttachmentCount: 1,
            pColorAttachments: &colour,
        ));
        beginRendering(vk, cmd, rendering);
    }
    else
    {
        auto passInfo = vkInfo(VkRenderPassBeginInfo(
            renderPass: target.renderPass,
            framebuffer: target.framebuffers[imageIndex],
            renderArea: VkRect2D(VkOffset2D(0, 0), drawExtent),
            clearValueCount: 1,
            pClearValues: &clear,
        ));
        vk.device.cmdBeginRenderPass(cmd, &passInfo,
            VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);
    }

    vk.device.cmdBindPipeline(cmd,
        VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);

    auto viewport = VkViewport(
        x: 0, y: 0,
        width: drawExtent.width, height: drawExtent.height,
        minDepth: 0, maxDepth: 1,
    );
    auto scissor = VkRect2D(VkOffset2D(0, 0), drawExtent);
    vk.device.cmdSetViewport(cmd, 0, 1, &viewport);
    vk.device.cmdSetScissor(cmd, 0, 1, &scissor);

    // Three vertices, no buffers: the shader indexes constants by
    // `gl_VertexIndex`. See `shaders/triangle.vert`.
    vk.device.cmdDraw(cmd, 3, 1, 0, 0);

    if (target.dynamicRendering)
    {
        endRendering(vk, cmd);
        transition(vk, cmd, sc.images[imageIndex],
            VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VkAccessFlagBits.VK_ACCESS_MEMORY_READ_BIT,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    }
    else
        vk.device.cmdEndRenderPass(cmd);

    auto ended = pool.end(vk, frame);
    if (ended.hasError)
        return err!void("vkEndCommandBuffer: " ~ describeResult(ended.error));

    return ok!string();
}

private void beginRendering(ref VulkanContext vk, VkCommandBuffer cmd,
    ref VkRenderingInfo info) @system
{
    if (vk.device.cmdBeginRendering !is null)
        vk.device.cmdBeginRendering(cmd, &info);
    else
        vk.device.cmdBeginRenderingKHR(cmd, &info);
}

private void endRendering(ref VulkanContext vk, VkCommandBuffer cmd) @system
{
    if (vk.device.cmdEndRendering !is null)
        vk.device.cmdEndRendering(cmd);
    else
        vk.device.cmdEndRenderingKHR(cmd);
}

/// One colour-attachment layout transition. Dynamic rendering's substitute
/// for the render-pass `initialLayout` / `finalLayout` pair.
private void transition(ref VulkanContext vk, VkCommandBuffer cmd, VkImage image,
    VkImageLayout from, VkImageLayout to,
    VkAccessFlags srcAccess, VkAccessFlags dstAccess,
    VkPipelineStageFlags srcStage, VkPipelineStageFlags dstStage) @system
{
    auto barrier = vkInfo(VkImageMemoryBarrier(
        srcAccessMask: srcAccess,
        dstAccessMask: dstAccess,
        oldLayout: from,
        newLayout: to,
        srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        image: image,
        subresourceRange: VkImageSubresourceRange(
            aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
            levelCount: 1,
            layerCount: 1,
        ),
    ));
    vk.device.cmdPipelineBarrier(cmd, srcStage, dstStage, 0, 0, null, 0, null, 1, &barrier);
}

// -----------------------------------------------------------------------------
// Render target: views, and (only without dynamic rendering) a pass + FBs
// -----------------------------------------------------------------------------

/// Image views, plus a render pass and framebuffers when dynamic rendering
/// is not available.
struct RenderTarget
{
    bool dynamicRendering;
    VkRenderPass renderPass;
    VkImageView[] views;
    VkFramebuffer[] framebuffers;

    @disable this(this);

    static Expected!(void, string) create(out RenderTarget t, ref VulkanContext vk,
        ref Swapchain sc) @system
    {
        t.dynamicRendering = vk.dynamicRendering;
        if (t.dynamicRendering)
            return t.createViews(vk, sc);


        // One colour attachment, cleared each frame and left in PRESENT_SRC.
        // `initialLayout: UNDEFINED` says the previous contents may be
        // discarded, which is what makes the clear free on tiled hardware.
        auto colour = VkAttachmentDescription(
            format: sc.format,
            samples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
            loadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout: VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        );

        auto ref_ = VkAttachmentReference(
            attachment: 0,
            layout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        );

        auto subpass = VkSubpassDescription(
            pipelineBindPoint: VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments: &ref_,
        );

        // The half of the acquire→render ordering the semaphore does not
        // cover: the semaphore orders the queue operations, this orders the
        // attachment's layout transition against them. Without it the
        // transition may run before the image is actually available.
        auto dependency = VkSubpassDependency(
            srcSubpass: VK_SUBPASS_EXTERNAL,
            dstSubpass: 0,
            srcStageMask: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            dstStageMask: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            srcAccessMask: 0,
            // READ as well as WRITE: a LOAD (MangoHud's overlay pass)
            // is a color-attachment read of the same image.
            dstAccessMask: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
                | VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT,
        );

        auto passInfo = vkInfo(VkRenderPassCreateInfo(
            attachmentCount: 1,
            pAttachments: &colour,
            subpassCount: 1,
            pSubpasses: &subpass,
            dependencyCount: 1,
            pDependencies: &dependency,
        ));

        auto pass = vk.device.createRenderPass(
            vk.device.device, &passInfo, null, &t.renderPass).check;
        if (pass.hasError)
            return err!void("vkCreateRenderPass: " ~ describeResult(pass.error));

        return t.createViews(vk, sc);
    }

    /**
    Rebuild the views and framebuffers for a new swapchain.

    The render pass stays: it depends on the format, which a resize does not
    change, and the pipeline was built against this handle. Recreating it
    would be legal (compatible render passes) and a waste.
    */
    Expected!(void, string) rebind(ref VulkanContext vk, ref Swapchain sc) @system
    {
        destroyViews(vk);
        return createViews(vk, sc);
    }

    private Expected!(void, string) createViews(ref VulkanContext vk, ref Swapchain sc)
        @system
    {
        if (views.length != sc.images.length)
        {
            views = new VkImageView[sc.images.length];
            if (!dynamicRendering)
                framebuffers = new VkFramebuffer[sc.images.length];
        }

        foreach (i, image; sc.images)
        {
            auto viewInfo = vkInfo(VkImageViewCreateInfo(
                image: image,
                viewType: VkImageViewType.VK_IMAGE_VIEW_TYPE_2D,
                format: sc.format,
                subresourceRange: VkImageSubresourceRange(
                    aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
                    levelCount: 1,
                    layerCount: 1,
                ),
            ));

            auto view = vk.device.createImageView(
                vk.device.device, &viewInfo, null, &views[i]).check;
            if (view.hasError)
            {
                destroy(vk);
                return err!void("vkCreateImageView: " ~ describeResult(view.error));
            }

            if (dynamicRendering)
                continue;

            auto attachment = views[i];
            auto fbInfo = vkInfo(VkFramebufferCreateInfo(
                renderPass: renderPass,
                attachmentCount: 1,
                pAttachments: &attachment,
                width: sc.extent.width,
                height: sc.extent.height,
                layers: 1,
            ));

            auto fb = vk.device.createFramebuffer(
                vk.device.device, &fbInfo, null, &framebuffers[i]).check;
            if (fb.hasError)
            {
                destroy(vk);
                return err!void("vkCreateFramebuffer: " ~ describeResult(fb.error));
            }
        }

        return ok!string();
    }

    void destroy(ref VulkanContext vk) @system nothrow
    {
        if (vk.device.device is null)
            return;

        destroyViews(vk);
        if (renderPass !is null)
        {
            vk.device.destroyRenderPass(vk.device.device, renderPass, null);
            renderPass = null;
        }
    }

    /// Views and framebuffers only — the render pass outlives a resize.
    private void destroyViews(ref VulkanContext vk) @system nothrow
    {
        foreach (ref fb; framebuffers)
        {
            if (fb !is null)
            {
                vk.device.destroyFramebuffer(vk.device.device, fb, null);
                fb = null;
            }
        }
        foreach (ref v; views)
        {
            if (v !is null)
            {
                vk.device.destroyImageView(vk.device.device, v, null);
                v = null;
            }
        }
    }
}

// -----------------------------------------------------------------------------
// The pipeline, and the SPIR-V it is built from
// -----------------------------------------------------------------------------

/**
SPIR-V as 32-bit words, assembled at compile time.

`VkShaderModuleCreateInfo.pCode` is a `const uint32_t*`, and a string import is
bytes whose alignment D does not promise — casting the pointer would be
undefined behaviour that happens to work. Building the words in CTFE puts a
correctly aligned `uint[]` in `.rodata` instead, at no runtime cost.
*/
private immutable(uint)[] spirvWords(string bytes)
{
    assert(bytes.length % 4 == 0, "SPIR-V is a stream of 32-bit words");

    auto words = new uint[bytes.length / 4];
    foreach (i, ref w; words)
        w = (cast(uint) cast(ubyte) bytes[i * 4])
            | (cast(uint) cast(ubyte) bytes[i * 4 + 1]) << 8
            | (cast(uint) cast(ubyte) bytes[i * 4 + 2]) << 16
            | (cast(uint) cast(ubyte) bytes[i * 4 + 3]) << 24;
    return words.idup;
}

/// Committed next to their GLSL, which carries the regeneration command.
private static immutable uint[] triangleVert = spirvWords(import("triangle.vert.spv"));
private static immutable uint[] triangleFrag = spirvWords(import("triangle.frag.spv"));

/// A corrupt or truncated blob is a compile error rather than a driver crash.
private enum uint spirvMagic = 0x0723_0203;
static assert(triangleVert.length > 4 && triangleVert[0] == spirvMagic,
    "shaders/triangle.vert.spv is not little-endian SPIR-V — regenerate it");
static assert(triangleFrag.length > 4 && triangleFrag[0] == spirvMagic,
    "shaders/triangle.frag.spv is not little-endian SPIR-V — regenerate it");

/// The graphics pipeline and the objects it owns.
struct Pipeline
{
    VkPipeline handle;
    VkPipelineLayout layout;

    @disable this(this);

    static Expected!(void, string) create(out Pipeline p, ref VulkanContext vk,
        VkFormat colorFormat, VkRenderPass renderPass = null) @system
    {
        VkShaderModule vert, frag;
        auto vertMade = createModule(vk, triangleVert, vert);
        if (vertMade.hasError)
            return vertMade;
        scope (exit)
            vk.device.destroyShaderModule(vk.device.device, vert, null);

        auto fragMade = createModule(vk, triangleFrag, frag);
        if (fragMade.hasError)
            return fragMade;
        scope (exit)
            vk.device.destroyShaderModule(vk.device.device, frag, null);

        VkPipelineShaderStageCreateInfo[2] stages = [
            vkInfo(VkPipelineShaderStageCreateInfo(
                stage: VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
                pName: "main",
            )),
            vkInfo(VkPipelineShaderStageCreateInfo(
                stage: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
                pName: "main",
            )),
        ];

        // The field is spelled `module`, which is a D keyword — ImportC keeps
        // C's name, so it is unreachable by both named-argument syntax and
        // ordinary member access. `__traits(getMember)` takes it as a string
        // and is the only way to write to it.
        __traits(getMember, stages[0], "module") = vert;
        __traits(getMember, stages[1], "module") = frag;

        // No bindings and no attributes: the vertex shader reads constants.
        auto vertexInput = vkInfo(VkPipelineVertexInputStateCreateInfo());

        auto assembly = vkInfo(VkPipelineInputAssemblyStateCreateInfo(
            topology: VkPrimitiveTopology.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        ));

        // Counts without pointers: both are dynamic state below.
        auto viewportState = vkInfo(VkPipelineViewportStateCreateInfo(
            viewportCount: 1,
            scissorCount: 1,
        ));

        auto raster = vkInfo(VkPipelineRasterizationStateCreateInfo(
            polygonMode: VkPolygonMode.VK_POLYGON_MODE_FILL,
            cullMode: VkCullModeFlagBits.VK_CULL_MODE_NONE,
            frontFace: VkFrontFace.VK_FRONT_FACE_CLOCKWISE,
            // Not defaulted by Vulkan: zero here is a validation error.
            lineWidth: 1.0f,
        ));

        auto multisample = vkInfo(VkPipelineMultisampleStateCreateInfo(
            rasterizationSamples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
        ));

        // A zero write mask is legal and draws nothing, which is a long
        // afternoon: name all four channels.
        auto blendAttachment = VkPipelineColorBlendAttachmentState(
            blendEnable: VK_FALSE,
            colorWriteMask: VkColorComponentFlagBits.VK_COLOR_COMPONENT_R_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_G_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_B_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_A_BIT,
        );

        auto blend = vkInfo(VkPipelineColorBlendStateCreateInfo(
            attachmentCount: 1,
            pAttachments: &blendAttachment,
        ));

        VkDynamicState[2] dynamicStates = [
            VkDynamicState.VK_DYNAMIC_STATE_VIEWPORT,
            VkDynamicState.VK_DYNAMIC_STATE_SCISSOR,
        ];
        auto dynamic = vkInfo(VkPipelineDynamicStateCreateInfo(
            dynamicStateCount: dynamicStates.length,
            pDynamicStates: dynamicStates.ptr,
        ));

        auto layoutInfo = vkInfo(VkPipelineLayoutCreateInfo());
        auto layoutMade = vk.device.createPipelineLayout(
            vk.device.device, &layoutInfo, null, &p.layout).check;
        if (layoutMade.hasError)
            return err!void("vkCreatePipelineLayout: " ~ describeResult(layoutMade.error));

        auto format = colorFormat;
        auto rendering = vkInfo(VkPipelineRenderingCreateInfo(
            colorAttachmentCount: 1,
            pColorAttachmentFormats: &format,
        ));

        auto info = vkInfo(VkGraphicsPipelineCreateInfo(
            pNext: renderPass is null ? &rendering : null,
            stageCount: stages.length,
            pStages: stages.ptr,
            pVertexInputState: &vertexInput,
            pInputAssemblyState: &assembly,
            pViewportState: &viewportState,
            pRasterizationState: &raster,
            pMultisampleState: &multisample,
            pColorBlendState: &blend,
            pDynamicState: &dynamic,
            layout: p.layout,
            renderPass: renderPass,
            subpass: 0,
        ));

        auto made = vk.device.createGraphicsPipelines(
            vk.device.device, null, 1, &info, null, &p.handle).check;
        if (made.hasError)
        {
            p.destroy(vk);
            return err!void("vkCreateGraphicsPipelines: " ~ describeResult(made.error));
        }

        return ok!string();
    }

    void destroy(ref VulkanContext vk) @system nothrow
    {
        if (vk.device.device is null)
            return;

        if (handle !is null)
        {
            vk.device.destroyPipeline(vk.device.device, handle, null);
            handle = null;
        }
        if (layout !is null)
        {
            vk.device.destroyPipelineLayout(vk.device.device, layout, null);
            layout = null;
        }
    }
}

private Expected!(void, string) createModule(ref VulkanContext vk,
    immutable uint[] words, out VkShaderModule mod) @system
{
    auto info = vkInfo(VkShaderModuleCreateInfo(
        codeSize: words.length * uint.sizeof,
        pCode: words.ptr,
    ));

    auto made = vk.device.createShaderModule(
        vk.device.device, &info, null, &mod).check;
    return made.hasError
        ? err!void("vkCreateShaderModule: " ~ describeResult(made.error))
        : ok!string();
}
