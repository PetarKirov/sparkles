/**
Image uploads, staged in a frame's buffer space and recorded before the
frame's rendering (`UVK30`).

`stage` copies pixels into the frame slot's buffers and records nothing;
`record`, called first in the frame's command buffer, emits for each staged
copy a barrier into the transfer layout, the buffer-to-image copy, and a
barrier from the transfer write to the fragment shader's read, leaving the
image in the shader-read layout. Copies are recorded in the order they were
staged, so a later update of the same pixels wins.
*/
module sparkles.ui_vulkan.upload;

import expected : err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.ui_vulkan.frame_buffers : BufferSlice, FrameBuffers;
import sparkles.ui_vulkan.resources : colourRange;
import sparkles.vulkan;

/// Staged image copies, recorded together.
struct Uploads(B)
{
    private static struct Copy
    {
        VkImage image;
        VkImageLayout from;
        VkBuffer buffer;
        ulong offset;
        VkOffset2D at;
        VkExtent2D extent;
    }

    private FrameBuffers!B* buffers_;
    private DeviceMemory!B* memory_;
    private UniqueBuffer!Copy copies_;

    @disable this(this);

    /// Stages into `buffers`' space, flushing through `memory`; both must
    /// outlive this and not move.
    this(ref FrameBuffers!B buffers, ref DeviceMemory!B memory) @system
    {
        buffers_ = &buffers;
        memory_ = &memory;
    }

    /**
    Stages `pixels`, rows of `extent.width` texels of `texelBytes` each, for
    the region of `image` at `at`, which is in layout `from` when the copy is
    recorded.
    */
    VkExpected!() stage(uint slot, VkImage image, VkImageLayout from,
        scope const(ubyte)[] pixels, uint texelBytes, VkOffset2D at, VkExtent2D extent) @system
    in (pixels.length == ulong(extent.width) * extent.height * texelBytes,
        "the pixels must fill the extent exactly")
    {
        // A copy's buffer offset must be a multiple of the texel size and of 4.
        const alignment = texelBytes % 4 == 0 ? texelBytes : texelBytes * 4;
        auto slice = buffers_.allocate(slot, pixels.length, alignment);
        if (slice.hasError)
            return err!void(slice.error);
        slice.value.host[] = pixels[];
        auto flushed = memory_.flush(slice.value.region);
        if (flushed.hasError)
            return flushed;
        copies_.put(Copy(image, from, slice.value.buffer, slice.value.offset, at, extent));
        return ok!VkResult();
    }

    /// The copies staged and not yet recorded.
    size_t pending() const => copies_.length;

    /// Forgets every staged copy unrecorded: the frame it was staged for
    /// was abandoned.
    void discard()
    {
        copies_.clear();
    }

    /// Records every staged copy into `commands`, then forgets them.
    void record(ref DeviceCommands device, VkCommandBuffer commands) @system
    {
        foreach (ref c; copies_[])
        {
            transition(device, commands, c.image, c.from,
                VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                c.from == VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED
                    ? VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                    : VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                0,
                VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
                VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT);
            VkBufferImageCopy region;
            region.bufferOffset = c.offset;
            region.imageSubresource = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
                mipLevel: 0, baseArrayLayer: 0, layerCount: 1);
            region.imageOffset = VkOffset3D(c.at.x, c.at.y, 0);
            region.imageExtent = VkExtent3D(c.extent.width, c.extent.height, 1);
            device.cmdCopyBufferToImage(commands, c.buffer, c.image,
                VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            transition(device, commands, c.image,
                VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
                VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
                VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                VkAccessFlagBits.VK_ACCESS_SHADER_READ_BIT);
        }
        copies_.clear();
    }
}

/// One image layout transition with its stages and accesses.
void transition(ref DeviceCommands device, VkCommandBuffer commands, VkImage image,
    VkImageLayout from, VkImageLayout to, VkPipelineStageFlags srcStage,
    VkAccessFlags srcAccess, VkPipelineStageFlags dstStage, VkAccessFlags dstAccess)
    @system nothrow @nogc
{
    auto barrier = vkInfo(VkImageMemoryBarrier(
        srcAccessMask: srcAccess,
        dstAccessMask: dstAccess,
        oldLayout: from,
        newLayout: to,
        srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        image: image,
        subresourceRange: colourRange,
    ));
    device.cmdPipelineBarrier(commands, srcStage, dstStage, 0, 0, null, 0, null, 1, &barrier);
}

// ── the readback: an upload through the staging path, on a real driver ───────

version (unittest)
{
    import sparkles.test_runner.skip : skipTest;
    import sparkles.ui_vulkan.resources : GpuBuffer, GpuImage;
    import sparkles.vulkan_wsi.testing : HeadlessSession, readbackEnabled,
        readbackSkipReason, succeeded;
}

@("ui_vulkan.upload.anImageReadsBackAsUploaded")
@system unittest
{
    // V1's gate: an image uploaded through the staging path, a patch staged
    // over it in the same frame, and the image read back byte for byte, with
    // the validation layer listening.
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);

    enum uint width = 64, height = 48, patchW = 16, patchH = 8;
    enum VkOffset2D patchAt = VkOffset2D(5, 7);

    HeadlessSession session;
    session.open("ui-vulkan-upload");
    scope (success)
        session.close();
    auto device = &session.device;
    auto dev = &device.device;

    auto memory = DeviceMemory!DeviceMemoryBackend(
        DeviceMemoryBackend(device.instance, device.physicalDevice, *dev));
    FrameArena!DeviceMemoryBackend arena;
    succeeded(FrameArena!DeviceMemoryBackend.create(arena, memory, 2, 64 * 1024)
        .hasError ? VkResult.VK_ERROR_UNKNOWN : VkResult.VK_SUCCESS);
    FrameBuffers!DeviceMemoryBackend buffers;
    assert(!FrameBuffers!DeviceMemoryBackend.create(buffers, *dev, arena, 2,
        VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_SRC_BIT).hasError);
    auto uploads = Uploads!DeviceMemoryBackend(buffers, memory);

    GpuImage image;
    assert(!GpuImage.create(image, *dev, memory, VkFormat.VK_FORMAT_R8G8B8A8_UNORM,
        VkExtent2D(width, height),
        VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT).hasError);
    GpuBuffer readback;
    assert(!GpuBuffer.create(readback, *dev, memory, width * height * 4,
        VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
            | VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT).hasError);

    auto whole = new ubyte[width * height * 4];
    foreach (i, ref b; whole)
        b = cast(ubyte)(i * 7 + i / 251);
    auto patch = new ubyte[patchW * patchH * 4];
    foreach (i, ref b; patch)
        b = cast(ubyte)(255 - i);
    assert(!uploads.stage(0, image.handle, VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED, whole, 4,
        VkOffset2D(0, 0), VkExtent2D(width, height)).hasError);
    assert(!uploads.stage(0, image.handle, VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        patch, 4, patchAt, VkExtent2D(patchW, patchH)).hasError);
    assert(uploads.pending == 2);

    // Record: the uploads, then a copy of the image into the readback buffer.
    auto poolInfo = vkInfo(VkCommandPoolCreateInfo(queueFamilyIndex: device.queueFamily));
    VkCommandPool pool;
    succeeded(dev.createCommandPool(dev.device, &poolInfo, null, &pool));
    auto allocInfo = vkInfo(VkCommandBufferAllocateInfo(commandPool: pool,
        level: VkCommandBufferLevel.VK_COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount: 1));
    VkCommandBuffer commands;
    succeeded(dev.allocateCommandBuffers(dev.device, &allocInfo, &commands));
    auto begin = vkInfo(VkCommandBufferBeginInfo(
        flags: VkCommandBufferUsageFlagBits.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT));
    succeeded(dev.beginCommandBuffer(commands, &begin));
    uploads.record(*dev, commands);
    assert(uploads.pending == 0);
    transition(*dev, commands, image.handle,
        VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT);
    VkBufferImageCopy out_;
    out_.imageSubresource = VkImageSubresourceLayers(
        aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
        mipLevel: 0, baseArrayLayer: 0, layerCount: 1);
    out_.imageExtent = VkExtent3D(width, height, 1);
    dev.cmdCopyImageToBuffer(commands, image.handle,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.handle, 1, &out_);
    succeeded(dev.endCommandBuffer(commands));

    auto fenceInfo = vkInfo(VkFenceCreateInfo());
    VkFence fence;
    succeeded(dev.createFence(dev.device, &fenceInfo, null, &fence));
    auto submit = vkInfo(VkSubmitInfo(commandBufferCount: 1, pCommandBuffers: &commands));
    succeeded(dev.queueSubmit(device.queue, 1, &submit, fence));
    succeeded(dev.waitForFences(dev.device, 1, &fence, VK_TRUE, ulong.max));

    // The patch over the whole, byte for byte.
    auto expected = whole.dup;
    foreach (y; 0 .. patchH)
        foreach (x; 0 .. patchW)
        {
            const dst = ((patchAt.y + y) * width + patchAt.x + x) * 4;
            const src = (y * patchW + x) * 4;
            expected[dst .. dst + 4] = patch[src .. src + 4];
        }
    assert(readback.region.host == expected, "the image did not read back as uploaded");

    dev.destroyFence(dev.device, fence, null);
    dev.destroyCommandPool(dev.device, pool, null);
    readback.destroy(*dev, memory);
    image.destroy(*dev, memory);
    buffers.destroy();
    arena.destroy();
    memory.destroy();
}
