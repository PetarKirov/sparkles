#!/usr/bin/env dub
/+ dub.sdl:
    name "vulkan_triangle"
    dependency "sparkles:ui-sdl3" path="../../.."
    dependency "sparkles:vulkan" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
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
 * `--resize-stress` rebuilds the swapchain every frame, which is the path
 * that used to `vkDeviceWaitIdle` and destroy objects a present still held:
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

    Expected!(void, string) run()
    {
        Window window;
        auto opened = Window.open(window, WindowRequest(
            title: "sparkles — vulkan triangle",
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

        auto drawn = draw(vk, window, frames, resizeStress);
        if (drawn.hasError)
            return err!void(drawn.error);

        auto opt = PrettyPrintOptions!void(colored: !noColor, softMaxWidth: 100);
        writeln(prettyPrint(drawn.value, opt));
        return ok();
    }
}

import std.stdio : writeln;

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
    uint framesPresented;
    uint swapchainsBuilt;
    string rendering;
    string exitedBecause;
}

// -----------------------------------------------------------------------------
// The frame loop
// -----------------------------------------------------------------------------

Expected!(RunReport, string) draw(ref VulkanContext vk, ref Window window,
    int frameBudget, bool resizeStress = false) @system
{
    RunReport report = { device: vk.deviceName };

    Swapchain sc;
    RenderTarget target;
    FrameSync sync;
    CommandPool pool;
    Pipeline pipeline;
    // Quiet frames since the last swapchain build. Retired present
    // semaphores are reaped once this passes framesInFlight, so the wait
    // is already satisfied and a drag never serialises on vsync.
    uint framesSinceRebuild;

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
        auto px = window.pixelSize;
        if (px.hasError)
            return err!void(px.error);

        // Minimised: keep the old swapchain and stop drawing. Creating a
        // zero-area swapchain is invalid; destroying the old one would make
        // the restore more expensive than it needs to be.
        if (px.value.width <= 0 || px.value.height <= 0)
            return ok!string();

        // Same size, or a shrink into a padded swapchain: viewport-only.
        if (!force && sc.handle !is null
            && cast(uint) px.value.width <= sc.extent.width
            && cast(uint) px.value.height <= sc.extent.height)
            return ok!string();

        auto waited = sync.waitAll(vk);
        if (waited.hasError)
            return err!void("vkWaitForFences: " ~ describeResult(waited.error));

        // Pad to the display on a surface-defined (Wayland) resize so
        // subsequent shrinks stay inside the allocation. First create
        // stays exact so a --frames N run at 960×540 still reports that.
        PixelSize minAlloc;
        if (sc.handle !is null)
        {
            auto display = window.displayPixelSize;
            if (!display.hasError)
                minAlloc = display.value;
        }

        auto updated = Swapchain.recreate(sc, vk, px.value, force, minAlloc);
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

    report.format = format("%s", sc.format);
    report.presentMode = presentModeName(sc.presentMode);
    report.imageCount = cast(uint) sc.images.length;
    report.framesInFlight = sync.framesInFlight;
    report.rendering = vk.dynamicRendering ? "dynamic" : "render-pass";
    report.exitedBecause = "frame budget reached";

    while (frameBudget == 0 || report.framesPresented < frameBudget)
    {
        if (resizeStress)
        {
            const i = report.framesPresented;
            SDL_SetWindowSize(window.handle,
                480 + cast(int)(i % 50) * 8,
                270 + cast(int)(i % 40) * 6);
        }

        SDL_Event ev;
        bool quit;
        // One flag for the whole drain: a drag produces many PIXEL_SIZE_CHANGED
        // events per pump, and only the last size SDL reports is worth building.
        bool sizeChanged;
        while (SDL_PollEvent(&ev))
        {
            if (ev.type == SDL_EventType.SDL_EVENT_QUIT
                || ev.type == SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED)
                quit = true;
            else if (ev.type == SDL_EventType.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED)
                sizeChanged = true;
        }
        if (quit)
        {
            report.exitedBecause = "window closed";
            break;
        }

        // Rebuild before acquire so this frame is already at the new size —
        // waiting for OUT_OF_DATE keeps presenting a stretched old swapchain
        // for the rest of the drag.
        if (sizeChanged)
        {
            auto again = rebuild();
            if (again.hasError)
                return err!RunReport(again.error);
        }

        // No surface to draw into (still starting, or minimised). A
        // padded swapchain can outlive a 0×0 window — we still must not
        // present into it until the window is a real size again.
        auto pxNow = window.pixelSize;
        if (sc.handle is null || sc.extent.width == 0 || sc.extent.height == 0
            || (!pxNow.hasError && (pxNow.value.width <= 0 || pxNow.value.height <= 0)))
            continue;

        auto waited = sync.waitForFrame(vk);
        if (waited.hasError)
            return err!RunReport("vkWaitForFences: " ~ describeResult(waited.error));

        uint index;
        const acquired = vk.device.acquireNextImageKHR(vk.device.device, sc.handle,
            ulong.max, sync.imageAvailable, null, &index);
        const decision = decideAcquire(acquired);

        if (decision.failed)
            return err!RunReport("vkAcquireNextImageKHR: " ~ describeResult(acquired));

        // Not `else if`: a suboptimal acquire is both, and the frame is drawn
        // first — see `sparkles.ui_sdl3.frame.decideAcquire`.
        if (!decision.proceed)
        {
            if (decision.recreate)
            {
                auto again = rebuild(true);
                if (again.hasError)
                    return err!RunReport(again.error);
            }
            continue;
        }

        auto held = sync.waitForImage(vk, index);
        if (held.hasError)
            return err!RunReport("vkWaitForFences (image): " ~ describeResult(held.error));

        auto begun = sync.beginFrame(vk, index);
        if (begun.hasError)
            return err!RunReport("vkResetFences: " ~ describeResult(begun.error));

        auto recorded = record(vk, pool, pipeline, target, sc, sync.frame, index);
        if (recorded.hasError)
            return err!RunReport(recorded.error);

        auto submitted = sync.submit(vk, pool.buffers[sync.frame], index);
        if (submitted.hasError)
            return err!RunReport("vkQueueSubmit: " ~ describeResult(submitted.error));

        const presented = sc.present(vk, index, sync.renderFinished(index));
        sync.advance();
        report.framesPresented++;
        framesSinceRebuild++;

        // Old presents have had a couple of vsyncs to finish; queueWaitIdle
        // is then a no-op rather than a stall on the drag.
        if ((sync.hasRetired || sc.hasRetired)
            && framesSinceRebuild == sync.framesInFlight + 1)
        {
            cast(void) vk.device.queueWaitIdle(vk.queue);
            sync.reap(vk);
            sc.reap(vk);
        }

        // Skip a second rebuild when PIXEL_SIZE_CHANGED already did this
        // tick: present is often SUBOPTIMAL for the same size, and waiting
        // the fence we just submitted would stall on a vsync for nothing.
        if (!sizeChanged && (presented.hasError
            || Swapchain.needsRecreation(presented.value) || decision.recreate))
        {
            if (presented.hasError && !Swapchain.needsRecreation(presented.error))
                return err!RunReport("vkQueuePresentKHR: " ~ describeResult(presented.error));

            auto again = rebuild(true);
            if (again.hasError)
                return err!RunReport(again.error);
        }
        else if (presented.hasError && !Swapchain.needsRecreation(presented.error))
            return err!RunReport("vkQueuePresentKHR: " ~ describeResult(presented.error));
    }

    report.extent = format("%dx%d", sc.extent.width, sc.extent.height);
    return ok!string(report);
}

/// Record one frame: begin the pass, set the dynamic state, draw three vertices.
Expected!(void, string) record(ref VulkanContext vk, ref CommandPool pool,
    ref Pipeline pipeline, ref RenderTarget target, ref Swapchain sc,
    uint frame, uint imageIndex) @system
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
        transition(vk, cmd, sc.images[imageIndex],
            VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
            VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            0, VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
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
            renderArea: VkRect2D(VkOffset2D(0, 0), sc.extent),
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
            renderArea: VkRect2D(VkOffset2D(0, 0), sc.extent),
            clearValueCount: 1,
            pClearValues: &clear,
        ));
        vk.device.cmdBeginRenderPass(cmd, &passInfo,
            VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);
    }

    vk.device.cmdBindPipeline(cmd,
        VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);

    // Always the swapchain extent: a padded allocation presents the whole
    // image and the compositor scales it to the window. A viewport smaller
    // than the image would draw the triangle into a corner of a large
    // present, which then scales down looking like a stamp.
    auto viewport = VkViewport(
        x: 0, y: 0,
        width: sc.extent.width, height: sc.extent.height,
        minDepth: 0, maxDepth: 1,
    );
    auto scissor = VkRect2D(VkOffset2D(0, 0), sc.extent);
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
            VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, 0,
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
            dstAccessMask: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
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
