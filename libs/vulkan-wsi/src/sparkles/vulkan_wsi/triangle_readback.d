/**
The triangle, read back from a Vulkan driver against its host evaluation
(`sparkles:shaders` M6).

`shader-compile` compiles the triangle's D shaders (`triangle_shader.d`) to
SPIR-V exactly as the `gpu-shaders` configuration does, and the test draws
them offscreen, on a headless device, at three drawable aspects. The host
calls the same vertex function for the corners and the colours, and at each
point it checks the pixel must agree: the colour within 2 in 8-bit units of
the barycentric blend of the corners' colours, at pixel centres two pixels in
from each corner toward the centroid and at the centroid; the clear colour at
pixels two or more pixels outside an edge. The Khronos validation layer is
loaded, and the run fails on any message it reports.

Test-only, and opt-in (`SPARKLES_VULKAN_READBACK=1`): it needs a Vulkan
driver (lavapipe in CI), the validation layer and the device toolchain. Opted
in, it fails rather than skips when it cannot run.
*/
module sparkles.vulkan_wsi.triangle_readback;

version (unittest):

import std.file : exists, read, rmdirRecurse, tempDir;
import std.format : format;
import std.math : abs, lround, sqrt;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.process : environment, execute, thisProcessID;

import sparkles.shaders : PushConstants;
import sparkles.test_runner.skip : skipTest;
import sparkles.vulkan;
import sparkles.vulkan_wsi.commands : CommandPool;
import sparkles.vulkan_wsi.device : ContextRequest, VulkanDevice;
import sparkles.vulkan_wsi.triangle : beginRendering, endRendering, Pipeline, spirvWords,
    transition, triangleView, triangleViewBytes, triangleViewStages;
import sparkles.vulkan_wsi.triangle_shader : triangleFragment, triangleVertex, TriangleView;

private enum repoRoot = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");

/// The drawable sizes: square, wide and tall.
private immutable uint[2][3] extents = [[256, 256], [384, 192], [160, 320]];

/// The largest difference allowed per 8-bit channel.
private enum int tolerance = 2;

/// What the validation layer reported: how many messages, and the start of
/// the first.
private struct Messages
{
    uint count;
    char[512] first = 0;
    size_t firstLength;
}

private extern (C) VkBool32 onMessage(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT types, VkDebugUtilsMessengerCallbackDataEXT* data,
    void* user) nothrow @nogc
{
    auto messages = cast(Messages*) user;
    if (messages.count++ == 0 && data !is null && data.pMessage !is null)
        for (auto p = data.pMessage; *p && messages.firstLength < messages.first.length; ++p)
            messages.first[messages.firstLength++] = *p;
    return VK_FALSE;
}

/// The triangle's corners in pixels and their colours, from the host's
/// evaluation of the vertex function for a `width`×`height` drawable.
private struct Corners
{
    double[2][3] at;
    double[3][3] colour;
}

private Corners hostCorners(uint width, uint height)
{
    Corners c;
    const view = PushConstants!TriangleView(TriangleView(aspect: cast(float) width / height));
    foreach (i; 0 .. 3)
    {
        const v = triangleVertex(cast(int) i, view);
        // Vulkan's viewport transform: clip x and y from -1..1 onto 0..extent,
        // y down.
        c.at[i] = [(v.position.array[0] + 1.0) / 2.0 * width,
            (v.position.array[1] + 1.0) / 2.0 * height];
        c.colour[i] = [v.colour.array[0], v.colour.array[1], v.colour.array[2]];
    }
    return c;
}

/// The barycentric coordinates of `p` in the triangle `c`.
private double[3] barycentric(in Corners c, double[2] p)
{
    double edge(size_t a, size_t b, double[2] q) => (c.at[b][0] - c.at[a][0]) * (q[1] - c.at[a][1])
        - (c.at[b][1] - c.at[a][1]) * (q[0] - c.at[a][0]);
    const area = edge(0, 1, c.at[2]);
    return [edge(1, 2, p) / area, edge(2, 0, p) / area, edge(0, 1, p) / area];
}

/// How far `p` lies inside the triangle: the least distance to an edge's
/// line, negative outside.
private double insideBy(in Corners c, double[2] p)
{
    double least = double.infinity;
    const l = barycentric(c, p);
    foreach (i; 0 .. 3)
    {
        // The distance to the edge opposite corner i is its barycentric
        // coordinate times the corner's distance from that edge.
        const a = c.at[(i + 1) % 3], b = c.at[(i + 2) % 3];
        const len = sqrt((b[0] - a[0]) ^^ 2 + (b[1] - a[1]) ^^ 2);
        const height = abs((b[0] - a[0]) * (c.at[i][1] - a[1]) - (b[1] - a[1]) * (c.at[i][0] - a[0]))
            / len;
        const d = l[i] * height;
        if (d < least)
            least = d;
    }
    return least;
}

/// Compiles the triangle with `shader-compile`, into a fresh directory.
private string compileTriangle()
{
    const out_ = tempDir.buildPath(format("sparkles-triangle-readback-%s", thisProcessID));
    const r = execute(["dub", "run", "-q", "--temp-build",
        "--root=" ~ repoRoot.buildPath("apps", "shader-compile"), "--",
        "--package=" ~ repoRoot.buildPath("libs", "vulkan-wsi"), "--out=" ~ out_, "--quiet"]);
    assert(r.status == 0, "SPARKLES_VULKAN_READBACK=1, but the triangle did not compile:\n"
        ~ r.output);
    return out_;
}

/// A memory type among `bits` with all of `flags`.
private uint memoryType(ref VulkanDevice d, uint bits, VkMemoryPropertyFlags flags) @system
{
    VkPhysicalDeviceMemoryProperties props;
    d.instance.getPhysicalDeviceMemoryProperties(d.physicalDevice, &props);
    foreach (i; 0 .. props.memoryTypeCount)
        if ((bits & (1u << i)) && (props.memoryTypes[i].propertyFlags & flags) == flags)
            return i;
    assert(false, "no memory type with the flags the readback needs");
}

/// Draws the triangle into a `width`×`height` RGBA8 image and returns its
/// pixels, row by row.
private ubyte[] draw(ref VulkanDevice d, ref Pipeline pipeline, uint width, uint height) @system
{
    enum format_ = VkFormat.VK_FORMAT_R8G8B8A8_UNORM;
    auto dev = d.device.device;

    // The image, in device memory.
    VkImage image;
    auto imageInfo = vkInfo(VkImageCreateInfo(
        imageType: VkImageType.VK_IMAGE_TYPE_2D,
        format: format_,
        extent: VkExtent3D(width, height, 1),
        mipLevels: 1,
        arrayLayers: 1,
        samples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
        tiling: VkImageTiling.VK_IMAGE_TILING_OPTIMAL,
        usage: VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        initialLayout: VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
    ));
    succeeded(d.device.createImage(dev, &imageInfo, null, &image));
    scope (exit) d.device.destroyImage(dev, image, null);
    VkMemoryRequirements imageNeeds;
    d.device.getImageMemoryRequirements(dev, image, &imageNeeds);
    VkDeviceMemory imageMemory;
    auto imageAlloc = vkInfo(VkMemoryAllocateInfo(allocationSize: imageNeeds.size,
        memoryTypeIndex: memoryType(d, imageNeeds.memoryTypeBits, 0)));
    succeeded(d.device.allocateMemory(dev, &imageAlloc, null, &imageMemory));
    scope (exit) d.device.freeMemory(dev, imageMemory, null);
    succeeded(d.device.bindImageMemory(dev, image, imageMemory, 0));

    VkImageView view;
    auto viewInfo = vkInfo(VkImageViewCreateInfo(
        image: image,
        viewType: VkImageViewType.VK_IMAGE_VIEW_TYPE_2D,
        format: format_,
        subresourceRange: VkImageSubresourceRange(
            aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
            levelCount: 1,
            layerCount: 1,
        ),
    ));
    succeeded(d.device.createImageView(dev, &viewInfo, null, &view));
    scope (exit) d.device.destroyImageView(dev, view, null);

    // The buffer the pixels are copied into, in host-visible memory.
    const bytes = width * height * 4;
    VkBuffer buffer;
    auto bufferInfo = vkInfo(VkBufferCreateInfo(
        size: bytes,
        usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        sharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
    ));
    succeeded(d.device.createBuffer(dev, &bufferInfo, null, &buffer));
    scope (exit) d.device.destroyBuffer(dev, buffer, null);
    VkMemoryRequirements bufferNeeds;
    d.device.getBufferMemoryRequirements(dev, buffer, &bufferNeeds);
    VkDeviceMemory bufferMemory;
    auto bufferAlloc = vkInfo(VkMemoryAllocateInfo(allocationSize: bufferNeeds.size,
        memoryTypeIndex: memoryType(d, bufferNeeds.memoryTypeBits,
            VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
            | VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)));
    succeeded(d.device.allocateMemory(dev, &bufferAlloc, null, &bufferMemory));
    scope (exit) d.device.freeMemory(dev, bufferMemory, null);
    succeeded(d.device.bindBufferMemory(dev, buffer, bufferMemory, 0));

    // Record: clear, draw, and copy the image out.
    CommandPool pool;
    const pooled = CommandPool.create(pool, d, 1);
    assert(!pooled.hasError, pooled.error);
    scope (exit) pool.destroy(d);
    auto begun = pool.begin(d, 0);
    assert(!begun.hasError);
    auto cmd = begun.value;

    transition(d, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
        VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, 0,
        VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
    VkClearValue clear;
    clear.color.float32 = [0.0f, 0.0f, 0.0f, 1.0f];
    const extent = VkExtent2D(width, height);
    auto colour = vkInfo(VkRenderingAttachmentInfo(
        imageView: view,
        imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        loadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE,
        clearValue: clear,
    ));
    auto rendering = vkInfo(VkRenderingInfo(
        renderArea: VkRect2D(VkOffset2D(0, 0), extent),
        layerCount: 1,
        colorAttachmentCount: 1,
        pColorAttachments: &colour,
    ));
    beginRendering(d, cmd, rendering);
    d.device.cmdBindPipeline(cmd, VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipeline.handle);
    auto viewport = VkViewport(x: 0, y: 0, width: width, height: height, minDepth: 0, maxDepth: 1);
    auto scissor = VkRect2D(VkOffset2D(0, 0), extent);
    d.device.cmdSetViewport(cmd, 0, 1, &viewport);
    d.device.cmdSetScissor(cmd, 0, 1, &scissor);
    const push = triangleView(extent);
    d.device.cmdPushConstants(cmd, pipeline.layout, pipeline.pushConstantStages, 0,
        cast(uint) push.length, push.ptr);
    d.device.cmdDraw(cmd, 3, 1, 0, 0);
    endRendering(d, cmd);

    transition(d, cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT);
    auto region = VkBufferImageCopy(
        imageSubresource: VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
            layerCount: 1,
        ),
        imageExtent: VkExtent3D(width, height, 1),
    );
    d.device.cmdCopyImageToBuffer(cmd, image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        buffer, 1, &region);
    auto toHost = vkInfo(VkBufferMemoryBarrier(
        srcAccessMask: VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
        dstAccessMask: VkAccessFlagBits.VK_ACCESS_HOST_READ_BIT,
        srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        buffer: buffer,
        size: VK_WHOLE_SIZE,
    ));
    d.device.cmdPipelineBarrier(cmd, VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &toHost, 0, null);
    const ended = pool.end(d, 0);
    assert(!ended.hasError);

    VkFence fence;
    auto fenceInfo = vkInfo(VkFenceCreateInfo());
    succeeded(d.device.createFence(dev, &fenceInfo, null, &fence));
    scope (exit) d.device.destroyFence(dev, fence, null);
    auto submit = vkInfo(VkSubmitInfo(commandBufferCount: 1, pCommandBuffers: &cmd));
    succeeded(d.device.queueSubmit(d.queue, 1, &submit, fence));
    succeeded(d.device.waitForFences(dev, 1, &fence, VK_TRUE, ulong.max));

    void* mapped;
    succeeded(d.device.mapMemory(dev, bufferMemory, 0, VK_WHOLE_SIZE, 0, &mapped));
    auto pixels = (cast(ubyte*) mapped)[0 .. bytes].dup;
    d.device.unmapMemory(dev, bufferMemory);
    return pixels;
}

/// Whether the pixels of a `width`×`height` drawing agree with the host:
/// `null` if they do, else what disagreed.
private string compare(const(ubyte)[] pixels, uint width, uint height)
{
    const c = hostCorners(width, height);
    const(ubyte)[] at(size_t x, size_t y) => pixels[(y * width + x) * 4 .. (y * width + x) * 4 + 4];
    double[2] centre(size_t x, size_t y) => [x + 0.5, y + 0.5];

    // Inside: the pixel centre nearest each corner's point two pixels toward
    // the centroid, among those half a pixel or more inside every edge, and
    // the centroid's own pixel.
    const double[2] centroid = [(c.at[0][0] + c.at[1][0] + c.at[2][0]) / 3,
        (c.at[0][1] + c.at[1][1] + c.at[2][1]) / 3];
    double[2][] targets = [centroid];
    foreach (i; 0 .. 3)
    {
        const dx = centroid[0] - c.at[i][0], dy = centroid[1] - c.at[i][1];
        const len = sqrt(dx * dx + dy * dy);
        targets ~= [c.at[i][0] + 2 * dx / len, c.at[i][1] + 2 * dy / len];
    }
    foreach (target; targets)
    {
        size_t bx = size_t.max, by;
        double best = double.infinity;
        foreach (y; cast(long) target[1] - 3 .. cast(long) target[1] + 4)
            foreach (x; cast(long) target[0] - 3 .. cast(long) target[0] + 4)
            {
                if (x < 0 || y < 0 || x >= width || y >= height)
                    continue;
                const p = centre(x, y);
                const dist = (p[0] - target[0]) ^^ 2 + (p[1] - target[1]) ^^ 2;
                if (insideBy(c, p) >= 0.5 && dist < best)
                {
                    best = dist;
                    bx = x;
                    by = y;
                }
            }
        if (bx == size_t.max)
            return format("%sx%s: no pixel centre inside the triangle near (%.1f, %.1f)",
                width, height, target[0], target[1]);
        const l = barycentric(c, centre(bx, by));
        const got = at(bx, by);
        foreach (ch; 0 .. 3)
        {
            const expected = lround((l[0] * c.colour[0][ch] + l[1] * c.colour[1][ch]
                + l[2] * c.colour[2][ch]) * 255);
            if (abs(got[ch] - expected) > tolerance)
                return format("%sx%s: pixel (%s, %s) channel %s is %s, the host's blend %s",
                    width, height, bx, by, ch, got[ch], expected);
        }
        if (got[3] != 255)
            return format("%sx%s: pixel (%s, %s) is not opaque", width, height, bx, by);
    }

    // Outside: every pixel two or more pixels outside an edge is the clear
    // colour.
    size_t outside;
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            if (insideBy(c, centre(x, y)) <= -2)
            {
                outside++;
                const got = at(x, y);
                if (got[0] != 0 || got[1] != 0 || got[2] != 0)
                    return format("%sx%s: pixel (%s, %s), outside the triangle, is (%s, %s, %s)",
                        width, height, x, y, got[0], got[1], got[2]);
            }
    if (outside == 0)
        return format("%sx%s: no pixel lies outside the triangle", width, height);
    return null;
}

@("vulkan_wsi.triangle_readback.hostAndDeviceAgree")
@system unittest
{
    if (environment.get("SPARKLES_VULKAN_READBACK", "") != "1")
        return skipTest("a Vulkan readback is opt-in: SPARKLES_VULKAN_READBACK=1, with a driver "
            ~ "(lavapipe) and the validation layer");

    const out_ = compileTriangle();
    scope (exit) out_.rmdirRecurse;
    // The messenger is made with the instance's first use, after
    // createHeadless: the layer's messages about creating the instance and
    // the device are on the console, not counted.
    const vert = spirvWords(cast(string) read(out_.buildPath(__traits(identifier, triangleVertex)
        ~ ".vert.spv")));
    const frag = spirvWords(cast(string) read(out_.buildPath(__traits(identifier, triangleFragment)
        ~ ".frag.spv")));

    VulkanDevice d;
    auto made = VulkanDevice.createHeadless(d, ContextRequest(applicationName: "triangle-readback",
        apiVersion: apiVersion13, validation: true));
    assert(!made.hasError, "SPARKLES_VULKAN_READBACK=1, but no headless Vulkan device: "
        ~ made.error.diagnostic[].idup);
    assert(d.validationEnabled && d.debugUtils,
        "SPARKLES_VULKAN_READBACK=1, but the validation layer did not load (VK_LAYER_PATH?)");
    assert(d.dynamicRendering, "the device has no dynamic rendering");

    Messages messages;
    VkDebugUtilsMessengerEXT messenger;
    auto messengerInfo = vkInfo(VkDebugUtilsMessengerCreateInfoEXT(
        messageSeverity: VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
            | VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        messageType: VkDebugUtilsMessageTypeFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
        pfnUserCallback: &onMessage,
        pUserData: &messages,
    ));
    succeeded(d.instance.createDebugUtilsMessengerEXT(d.instance.instance, &messengerInfo, null,
        &messenger));
    scope (exit) d.instance.destroyDebugUtilsMessengerEXT(d.instance.instance, messenger, null);

    Pipeline pipeline;
    auto built = Pipeline.create(pipeline, d, VkFormat.VK_FORMAT_R8G8B8A8_UNORM, null, vert, frag,
        cast(uint) triangleViewBytes, false, __traits(identifier, triangleVertex),
        __traits(identifier, triangleFragment), triangleViewStages);
    assert(!built.hasError, built.error);

    foreach (e; extents)
    {
        const pixels = draw(d, pipeline, e[0], e[1]);
        if (const why = compare(pixels, e[0], e[1]))
            assert(false, why);
    }

    // Tear the device down while the messenger listens, so an object left
    // alive is reported too; the instance goes after the messenger.
    pipeline.destroy(d);
    d.releaseDevice();
    assert(messages.count == 0, format("the validation layer reported %s message(s), the first: %s",
        messages.count, messages.first[0 .. messages.firstLength]));
}

/// Fails the test unless `r` is `VK_SUCCESS`; the call stays outside any
/// `assert`, which a `-release` build would delete with it.
private void succeeded(VkResult r, string call = __FUNCTION__, size_t line = __LINE__)
{
    assert(r == VkResult.VK_SUCCESS, format("a Vulkan call at line %s failed: %s", line, r));
}
