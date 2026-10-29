/**
What a test needs to draw with the Vulkan canvas on a real driver: a $(LREF Rig)
— a headless device with the validation layer, the sub-allocator, a canvas, an
offscreen target and a frame loop — and spies that wrap the driver's commands
and log what the canvas called.

For this library's own readbacks and for an application's: the gallery draws
its pages through it. Such tests are opt-in (`SPARKLES_VULKAN_READBACK=1`,
`readbackEnabled`), since they need a driver and the layer.
*/
module sparkles.ui_vulkan.testing;

import std.format : text = format;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.image : ImageRegistry;
import sparkles.ui_vulkan.canvas;
import sparkles.ui_vulkan.painter : FrameMetrics, FrameReport;
import sparkles.ui_vulkan.pipelines : DeviceFacts;
import sparkles.ui_vulkan.resources : GpuBuffer, GpuImage;
import sparkles.vulkan;
import sparkles.vulkan_wsi.testing : HeadlessSession, succeeded;
public import sparkles.vulkan_wsi.testing : readbackEnabled, readbackSkipReason;

alias Canvas = VulkanCanvas!DeviceMemoryBackend;

/// How a rig is opened.
struct RigOptions
{
    VkFormat format = VkFormat.VK_FORMAT_R8G8B8A8_UNORM; /// the target's
    uint apiVersion = apiVersion13; /// the version the device is requested at
    CanvasConfig config;           ///
    bool spy;                      /// the canvas sees the device through the spies
    void delegate(ref DeviceFacts) adjust; /// changes the facts the canvas sees
}

/**
Everything a readback needs, on a headless device: the allocator, the canvas,
an offscreen target, and a command buffer and fence per frame slot. Frames are
synchronous — each is waited for before it is read back — so a slot's fence
has always signalled by the time it is begun again.
*/
struct Rig
{
    HeadlessSession session;
    DeviceMemory!DeviceMemoryBackend memory;
    Canvas canvas;
    GpuImage target;
    GpuBuffer readback;
    VkFormat format;
    VkExtent2D extent;
    VkCommandPool pool;
    VkCommandBuffer[2] commands;
    VkFence[2] fences;
    uint frame;
    ImageRegistry images;
    DeviceCommands spied;
    DeviceFacts facts;
    /// Quarter turns the target is drawn pre-rotated by (`CanvasTarget.turn`).
    uint turn;

    @disable this(this);

    /// Opens a device and a canvas drawing into a `width`×`height` image,
    /// as `options` says.
    void open(string name, uint width, uint height, RigOptions options = RigOptions.init)
        @system
    {
        session.open(name, options.apiVersion);
        auto device = &session.device;
        // The canvas and its allocator see the device through the spies,
        // when asked to; the rig itself does not.
        spied = device.device;
        if (options.spy)
            installSpies(spied);
        memory = DeviceMemory!DeviceMemoryBackend(
            DeviceMemoryBackend(device.instance, device.physicalDevice, spied));
        facts = DeviceFacts.of(*device);
        if (options.adjust !is null)
            options.adjust(facts);
        const made = Canvas.create(canvas, spied, memory, facts, options.config, &images);
        const format = options.format;
        assert(!made.hasError, text("the canvas was not created: %s", made.error));
        this.format = format;
        resize(width, height);

        auto poolInfo = vkInfo(VkCommandPoolCreateInfo(
            flags: VkCommandPoolCreateFlagBits.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            queueFamilyIndex: device.queueFamily));
        succeeded(device.device.createCommandPool(device.device.device, &poolInfo, null, &pool));
        auto allocInfo = vkInfo(VkCommandBufferAllocateInfo(commandPool: pool,
            level: VkCommandBufferLevel.VK_COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount: 2));
        succeeded(device.device.allocateCommandBuffers(device.device.device, &allocInfo,
            commands.ptr));
        foreach (ref f; fences)
        {
            auto fenceInfo = vkInfo(VkFenceCreateInfo(
                flags: VkFenceCreateFlagBits.VK_FENCE_CREATE_SIGNALED_BIT));
            succeeded(device.device.createFence(device.device.device, &fenceInfo, null, &f));
        }
    }

    /// A new target of `width`×`height`: the old one, and its readback
    /// buffer, are destroyed.
    void resize(uint width, uint height) @system
    {
        auto dev = &session.device.device;
        if (target.handle !is null)
        {
            succeeded(dev.deviceWaitIdle(dev.device));
            target.destroy(*dev, memory);
            readback.destroy(*dev, memory);
        }
        extent = VkExtent2D(width, height);
        assert(!GpuImage.create(target, *dev, memory, format, extent,
            VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT).hasError);
        assert(!GpuBuffer.create(readback, *dev, memory, width * height * 4,
            VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
            | VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT).hasError);
    }

    /**
    Draws one frame — `paint` between `beginFrame` and `endFrame` — on
    `ground`, and returns the target's bytes. The frame's report is `report`;
    a frame `endFrame` refuses records nothing, and returns `null`.
    */
    ubyte[] draw(scope void delegate(ref Canvas) paint, in FrameMetrics metrics,
        RgbColor ground, out FrameReport report, out VkResult failure) @system
    {
        auto dev = &session.device.device;
        const slot = frame++ % 2;
        succeeded(dev.waitForFences(dev.device, 1, &fences[slot], VK_TRUE, ulong.max));
        succeeded(dev.resetFences(dev.device, 1, &fences[slot]));
        auto cmd = commands[slot];
        succeeded(dev.resetCommandBuffer(cmd, 0));
        auto begin = vkInfo(VkCommandBufferBeginInfo(
            flags: VkCommandBufferUsageFlagBits.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT));
        succeeded(dev.beginCommandBuffer(cmd, &begin));

        canvas.beginFrame(CanvasTarget(image: target.handle, view: target.view, format: format,
            extent: extent, usage: VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
                | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            finalLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, turn: turn), cmd, slot,
            metrics,
            ground);
        paint(canvas);
        auto ended = canvas.endFrame();
        if (ended.hasError)
        {
            // Abandoned: the frame is not submitted, and its fence is left
            // signalled for the slot's next frame.
            failure = ended.error;
            succeeded(dev.endCommandBuffer(cmd));
            auto signal = vkInfo(VkSubmitInfo());
            succeeded(dev.queueSubmit(session.device.queue, 1, &signal, fences[slot]));
            return null;
        }
        report = ended.value;

        VkBufferImageCopy copy;
        copy.imageSubresource = VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT, layerCount: 1);
        copy.imageExtent = VkExtent3D(extent.width, extent.height, 1);
        dev.cmdCopyImageToBuffer(cmd, target.handle,
            VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.handle, 1, &copy);
        succeeded(dev.endCommandBuffer(cmd));
        auto submit = vkInfo(VkSubmitInfo(commandBufferCount: 1, pCommandBuffers: &cmd));
        succeeded(dev.queueSubmit(session.device.queue, 1, &submit, fences[slot]));
        succeeded(dev.waitForFences(dev.device, 1, &fences[slot], VK_TRUE, ulong.max));
        return readback.region.host.dup;
    }

    /// ditto, for a frame that must succeed.
    ubyte[] draw(scope void delegate(ref Canvas) paint, in FrameMetrics metrics,
        RgbColor ground = RgbColor(0, 0, 0)) @system
    {
        FrameReport report;
        return draw(paint, metrics, ground, report);
    }

    /// ditto, with the frame's report.
    ubyte[] draw(scope void delegate(ref Canvas) paint, in FrameMetrics metrics,
        RgbColor ground, out FrameReport report) @system
    {
        VkResult failure;
        auto bytes = draw(paint, metrics, ground, report, failure);
        assert(bytes !is null, text("the frame failed: %s", failure));
        return bytes;
    }

    /// Releases everything, the device last, and fails on any message the
    /// validation layer reported.
    void close() @system
    {
        auto dev = &session.device.device;
        succeeded(dev.deviceWaitIdle(dev.device));
        canvas.destroy();
        foreach (f; fences)
            dev.destroyFence(dev.device, f, null);
        dev.destroyCommandPool(dev.device, pool, null);
        target.destroy(*dev, memory);
        readback.destroy(*dev, memory);
        memory.destroy();
        session.close();
    }
}


// ── the spies: the real driver, with the calls the scenarios observe logged ──

/// One image barrier a spy saw.
struct SeenBarrier
{
    VkPipelineStageFlags src, dst;
    VkImageLayout from, to;
}

/// What the spies saw, in order.
struct SpyLog
{
    string[1024] calls;
    uint count;
    SeenBarrier[256] barriers;
    uint barrierCount;
    uint pipelines, images, imagesDestroyed, framebuffers, imagelessFramebuffers;
    uint allocations, frees; /// `vkAllocateMemory` calls that succeeded, `vkFreeMemory` calls
    bool failAllocations; /// `vkAllocateMemory` fails with `VK_ERROR_OUT_OF_DEVICE_MEMORY`

    void note(string call) nothrow @nogc
    {
        if (count < calls.length)
            calls[count++] = call;
    }

    /// The position of the first call named `call` at or after `from`, or -1.
    ptrdiff_t find(string call, size_t from = 0) const nothrow @nogc
    {
        foreach (i; from .. count)
            if (calls[i] == call)
                return i;
        return -1;
    }
}

/// Thread-local: a test and the canvas it drives share a thread.
SpyLog spyLog;
private DeviceCommands spiedThrough;

/// Points `d`'s observed commands at the spies, which log and forward to
/// what `d` held.
void installSpies(ref DeviceCommands d) @system
{
    spyLog = SpyLog.init;
    spiedThrough = d;
    d.createGraphicsPipelines = &sparklesUiVulkanSpyCreateGraphicsPipelines;
    d.createImage = &sparklesUiVulkanSpyCreateImage;
    d.destroyImage = &sparklesUiVulkanSpyDestroyImage;
    d.createFramebuffer = &sparklesUiVulkanSpyCreateFramebuffer;
    d.allocateMemory = &sparklesUiVulkanSpyAllocateMemory;
    d.freeMemory = &sparklesUiVulkanSpyFreeMemory;
    d.cmdPipelineBarrier = &sparklesUiVulkanSpyCmdPipelineBarrier;
    d.cmdCopyBufferToImage = &sparklesUiVulkanSpyCmdCopyBufferToImage;
    d.cmdBeginRenderPass = &sparklesUiVulkanSpyCmdBeginRenderPass;
    d.cmdEndRenderPass = &sparklesUiVulkanSpyCmdEndRenderPass;
    d.cmdDraw = &sparklesUiVulkanSpyCmdDraw;
    if (d.cmdBeginRendering !is null)
    {
        d.cmdBeginRendering = &sparklesUiVulkanSpyCmdBeginRendering;
        d.cmdEndRendering = &sparklesUiVulkanSpyCmdEndRendering;
    }
    if (d.cmdBeginRenderingKHR !is null)
    {
        d.cmdBeginRenderingKHR = &sparklesUiVulkanSpyCmdBeginRenderingKHR;
        d.cmdEndRenderingKHR = &sparklesUiVulkanSpyCmdEndRenderingKHR;
    }
}

// C linkage makes each spy's name global, so it is qualified.
// A spy of `vkName`, the dispatch field `field`: `before` runs on the
// arguments `a`, then the call is forwarded. Generated from the command's own
// `PFN_` type, whose pointer parameters ImportC leaves unqualified.
private enum string spy(string name, string field, string before) =
    "ReturnType!(PFN_vk" ~ name ~ ") sparklesUiVulkanSpy" ~ name ~ "(Parameters!(PFN_vk" ~ name ~ ") a) { "
    ~ before ~ " return spiedThrough." ~ field ~ "(a); }";

private extern (C) nothrow @nogc
{
    import std.traits : Parameters, ReturnType;

    mixin(spy!("CreateGraphicsPipelines", "createGraphicsPipelines", "spyLog.pipelines += a[2];"));
    mixin(spy!("CreateImage", "createImage", "++spyLog.images;"));
    mixin(spy!("DestroyImage", "destroyImage", "if (a[1] !is null) ++spyLog.imagesDestroyed;"));
    mixin(spy!("CreateFramebuffer", "createFramebuffer", "++spyLog.framebuffers;"
        ~ " if (a[1].flags & VkFramebufferCreateFlagBits.VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT)"
        ~ " ++spyLog.imagelessFramebuffers;"));
    ReturnType!PFN_vkAllocateMemory sparklesUiVulkanSpyAllocateMemory(Parameters!PFN_vkAllocateMemory a)
    {
        if (spyLog.failAllocations)
            return VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY;
        const r = spiedThrough.allocateMemory(a);
        if (r == VkResult.VK_SUCCESS)
            ++spyLog.allocations;
        return r;
    }
    mixin(spy!("FreeMemory", "freeMemory", "if (a[1] !is null) ++spyLog.frees;"));
    mixin(spy!("CmdPipelineBarrier", "cmdPipelineBarrier", `spyLog.note("barrier");`
        ~ " if (a[8] && spyLog.barrierCount < spyLog.barriers.length)"
        ~ " spyLog.barriers[spyLog.barrierCount++] = SeenBarrier(a[1], a[2], a[9][0].oldLayout,"
        ~ " a[9][0].newLayout);"));
    mixin(spy!("CmdCopyBufferToImage", "cmdCopyBufferToImage", `spyLog.note("copy");`));
    mixin(spy!("CmdBeginRenderPass", "cmdBeginRenderPass", `spyLog.note("beginRenderPass");`));
    mixin(spy!("CmdEndRenderPass", "cmdEndRenderPass", `spyLog.note("endRenderPass");`));
    mixin(spy!("CmdBeginRendering", "cmdBeginRendering", `spyLog.note("beginRendering");`));
    mixin(spy!("CmdEndRendering", "cmdEndRendering", `spyLog.note("endRendering");`));
    mixin(spy!("CmdBeginRenderingKHR", "cmdBeginRenderingKHR",
        `spyLog.note("beginRenderingKHR");`));
    mixin(spy!("CmdEndRenderingKHR", "cmdEndRenderingKHR", `spyLog.note("endRenderingKHR");`));
    mixin(spy!("CmdDraw", "cmdDraw", `spyLog.note("draw");`));
}
