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
import std.path : baseName, buildNormalizedPath, buildPath, dirName;
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

/// Compiles the unit of the package at `packageDir` (from the repository's
/// root) with `shader-compile`, into a fresh directory named after `test`.
/// The readbacks run concurrently; one at a time builds and runs the tool,
/// whose temporary build is shared.
private string compileUnit(string packageDir, string test)
{
    const out_ = tempDir.buildPath(format("sparkles-vulkan-readback-%s-%s", thisProcessID, test));
    typeof(execute([""])) r;
    synchronized r = execute(["dub", "run", "-q", "--temp-build",
        "--root=" ~ repoRoot.buildPath("apps", "shader-compile"), "--",
        "--package=" ~ repoRoot.buildPath(packageDir), "--out=" ~ out_, "--quiet"]);
    assert(r.status == 0, "SPARKLES_VULKAN_READBACK=1, but " ~ packageDir ~ " did not compile:\n"
        ~ r.output);
    return out_;
}

/// The SPIR-V words of `entry`'s module in `dir`, as `shader-compile` names it.
private immutable(uint)[] moduleOf(string dir, string entry, string stage)
    => spirvWords(cast(string) read(dir.buildPath(entry ~ "." ~ stage ~ ".spv")));

/// A headless device with the validation layer, and a messenger counting the
/// layer's messages. `close` tears the device down while the messenger
/// listens, so an object left alive is reported too, and fails the test on
/// any message.
private struct Session
{
    VulkanDevice d;
    Messages messages;
    VkDebugUtilsMessengerEXT messenger;

    @disable this(this);

    void open() @system
    {
        auto made = VulkanDevice.createHeadless(d, ContextRequest(
            applicationName: "vulkan-readback", apiVersion: apiVersion13, validation: true));
        assert(!made.hasError, "SPARKLES_VULKAN_READBACK=1, but no headless Vulkan device: "
            ~ made.error.diagnostic[].idup);
        assert(d.validationEnabled && d.debugUtils,
            "SPARKLES_VULKAN_READBACK=1, but the validation layer did not load (VK_LAYER_PATH?)");
        assert(d.dynamicRendering, "the device has no dynamic rendering");
        // Made after createHeadless: the layer's messages about creating the
        // instance and the device are on the console, not counted.
        auto info = vkInfo(VkDebugUtilsMessengerCreateInfoEXT(
            messageSeverity: VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                | VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            messageType: VkDebugUtilsMessageTypeFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            pfnUserCallback: &onMessage,
            pUserData: &messages,
        ));
        succeeded(d.instance.createDebugUtilsMessengerEXT(d.instance.instance, &info, null,
            &messenger));
    }

    void close() @system
    {
        d.releaseDevice();
        d.instance.destroyDebugUtilsMessengerEXT(d.instance.instance, messenger, null);
        assert(messages.count == 0, format("the validation layer reported %s message(s), the first: %s",
            messages.count, messages.first[0 .. messages.firstLength]));
    }
}

/// A buffer of `size` bytes for `usage`, in host-visible, coherent memory.
private void hostBuffer(ref VulkanDevice d, size_t size, VkBufferUsageFlags usage,
    out VkBuffer buffer, out VkDeviceMemory memory) @system
{
    auto dev = d.device.device;
    auto info = vkInfo(VkBufferCreateInfo(size: size, usage: usage,
        sharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE));
    succeeded(d.device.createBuffer(dev, &info, null, &buffer));
    VkMemoryRequirements needs;
    d.device.getBufferMemoryRequirements(dev, buffer, &needs);
    auto alloc = vkInfo(VkMemoryAllocateInfo(allocationSize: needs.size,
        memoryTypeIndex: memoryType(d, needs.memoryTypeBits,
            VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
            | VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)));
    succeeded(d.device.allocateMemory(dev, &alloc, null, &memory));
    succeeded(d.device.bindBufferMemory(dev, buffer, memory, 0));
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
private ubyte[] draw(ref VulkanDevice d, ref Pipeline pipeline, uint width, uint height,
    VkDescriptorSet set = null) @system
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
    if (pipeline.pushConstantStages)
    {
        const push = triangleView(extent);
        d.device.cmdPushConstants(cmd, pipeline.layout, pipeline.pushConstantStages, 0,
            cast(uint) push.length, push.ptr);
    }
    if (set !is null)
        d.device.cmdBindDescriptorSets(cmd, VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipeline.layout, 0, 1, &set, 0, null);
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

    const out_ = compileUnit("libs/vulkan-wsi", "triangle");
    scope (exit) out_.rmdirRecurse;
    const vert = moduleOf(out_, __traits(identifier, triangleVertex), "vert");
    const frag = moduleOf(out_, __traits(identifier, triangleFragment), "frag");

    Session session;
    session.open();
    ref VulkanDevice d() @system => session.d;

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

    pipeline.destroy(d);
    session.close();
}

// Only in this package's own unittest build, which compiles the probe module:
// a dependent's (`sparkles:ui-sdl3`'s) compiles this module without it.
version (VulkanWsiReadbackProbes)
@("vulkan_wsi.triangle_readback.aStd140BlockReadsAsWritten")
@system unittest
{
    import block_probe : Inner, Probe, probeFirst, probeSecond, probeThird, probeVertex;
    import sparkles.shaders : descriptorBindingsOf, layoutOf, Rule, v2, v3, writeLayout;

    if (environment.get("SPARKLES_VULKAN_READBACK", "") != "1")
        return skipTest("a Vulkan readback is opt-in: SPARKLES_VULKAN_READBACK=1, with a driver "
            ~ "(lavapipe) and the validation layer");

    // `SHR6` on the device: a block the host wrote with `writeLayout`, at the
    // offsets `layoutOf` gives, reads back field for field. Every value is
    // distinct and away from 0, so a field read at the wrong offset (padding,
    // or a neighbour) is caught.
    const out_ = compileUnit("libs/vulkan-wsi/tests/readback-probes", "block");
    scope (exit) out_.rmdirRecurse;
    Probe probe;
    probe.a = v3(0.10f, 0.15f, 0.20f);
    probe.b = 0.25f;
    probe.c = [0.30f, 0.35f, 0.40f];
    probe.inner = Inner(v2(0.45f, 0.50f), 0.55f);
    probe.d = 0.60f;
    enum size = layoutOf!(Probe, Rule.std140).size;
    ubyte[size] bytes;
    writeLayout!(Probe, Rule.std140)(probe, bytes[]);

    Session session;
    session.open();
    ref VulkanDevice d() @system => session.d;
    auto dev = d.device.device;

    // The block, in a uniform buffer.
    VkBuffer buffer;
    VkDeviceMemory memory;
    hostBuffer(d, size, VkBufferUsageFlagBits.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, buffer, memory);
    void* mapped;
    succeeded(d.device.mapMemory(dev, memory, 0, size, 0, &mapped));
    (cast(ubyte*) mapped)[0 .. size] = bytes[];
    d.device.unmapMemory(dev, memory);

    // Descriptor set 0 as the entry points number it (`SHR7`).
    enum bindings = descriptorBindingsOf!probeFirst;
    static assert(bindings.length == 1 && bindings[0].kind == "uniformBlock");
    static assert(descriptorBindingsOf!probeSecond == bindings && descriptorBindingsOf!probeThird == bindings);
    auto layoutBinding = VkDescriptorSetLayoutBinding(
        binding: bindings[0].binding,
        descriptorType: VkDescriptorType.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        descriptorCount: 1,
        stageFlags: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
    );
    auto layoutInfo = vkInfo(VkDescriptorSetLayoutCreateInfo(bindingCount: 1,
        pBindings: &layoutBinding));
    VkDescriptorSetLayout setLayout;
    succeeded(d.device.createDescriptorSetLayout(dev, &layoutInfo, null, &setLayout));
    auto poolSize = VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1);
    auto poolInfo = vkInfo(VkDescriptorPoolCreateInfo(maxSets: 1, poolSizeCount: 1,
        pPoolSizes: &poolSize));
    VkDescriptorPool pool;
    succeeded(d.device.createDescriptorPool(dev, &poolInfo, null, &pool));
    auto allocInfo = vkInfo(VkDescriptorSetAllocateInfo(descriptorPool: pool,
        descriptorSetCount: 1, pSetLayouts: &setLayout));
    VkDescriptorSet set;
    succeeded(d.device.allocateDescriptorSets(dev, &allocInfo, &set));
    auto bufferInfo = VkDescriptorBufferInfo(buffer: buffer, offset: 0, range: size);
    auto write = vkInfo(VkWriteDescriptorSet(dstSet: set, dstBinding: bindings[0].binding,
        descriptorCount: 1, descriptorType: VkDescriptorType.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        pBufferInfo: &bufferInfo));
    d.device.updateDescriptorSets(dev, 1, &write, 0, null);

    const vert = moduleOf(out_, __traits(identifier, probeVertex), "vert");
    static struct Expect
    {
        string entry;
        float[4] rgba;
    }
    const Expect[3] expects = [
        Expect(__traits(identifier, probeFirst), [0.10f, 0.15f, 0.20f, 0.25f]),
        Expect(__traits(identifier, probeSecond), [0.30f, 0.35f, 0.40f, 0.55f]),
        Expect(__traits(identifier, probeThird), [0.45f, 0.50f, 0.60f, 1.0f]),
    ];
    foreach (ref e; expects)
    {
        Pipeline pipeline;
        auto built = Pipeline.create(pipeline, d, VkFormat.VK_FORMAT_R8G8B8A8_UNORM, null, vert,
            moduleOf(out_, e.entry, "frag"), 0, false, __traits(identifier, probeVertex), e.entry,
            0, setLayout);
        assert(!built.hasError, built.error);
        const pixels = draw(d, pipeline, 2, 2, set);
        pipeline.destroy(d);
        foreach (ch; 0 .. 4)
        {
            const expected = lround(e.rgba[ch] * 255);
            assert(abs(pixels[ch] - expected) <= 1, format("%s: channel %s is %s, written %s",
                e.entry, ch, pixels[ch], expected));
        }
    }

    d.device.destroyDescriptorPool(dev, pool, null);
    d.device.destroyDescriptorSetLayout(dev, setLayout, null);
    d.device.destroyBuffer(dev, buffer, null);
    d.device.freeMemory(dev, memory, null);
    session.close();
}

// Only in this package's own unittest build, as above.
version (VulkanWsiReadbackProbes)
@("vulkan_wsi.triangle_readback.theFragmentStageAsVulkanDefinesIt")
@system unittest
{
    if (environment.get("SPARKLES_VULKAN_READBACK", "") != "1")
        return skipTest("a Vulkan readback is opt-in: SPARKLES_VULKAN_READBACK=1, with a driver "
            ~ "(lavapipe) and the validation layer");
    checkFragmentStage("", "fragment");
}

// Only in this package's own unittest build, as above.
version (VulkanWsiReadbackProbes)
@("vulkan_wsi.triangle_readback.theFragmentStageOnVulkan11")
@system unittest
{
    if (environment.get("SPARKLES_VULKAN_READBACK", "") != "1")
        return skipTest("a Vulkan readback is opt-in: SPARKLES_VULKAN_READBACK=1, with a driver "
            ~ "(lavapipe) and the validation layer");
    // `vulkan1.1`'s SPIR-V 1.3 modules (which the build step validated for
    // Vulkan 1.1) mean the same, but for `demote`, which the profile denies.
    // They run on the readback's 1.3 device, which consumes SPIR-V 1.3: the
    // readback draws with dynamic rendering, which a 1.1 device lacks.
    checkFragmentStage(".vk11", "fragment-vk11");
}

/// The fragment-stage probes, read from the modules whose names carry
/// `suffix` (`.vk11` for `vulkan1.1`), compiled into a directory named after
/// `test`. `demote` is checked where the profile has it.
version (VulkanWsiReadbackProbes)
private void checkFragmentStage(string suffix, string test) @system
{
    import fragment_probe : stageDemote, stageDerivatives, stageDiscard, stageFragCoord,
        stageSize, stageVertex, stageVertexReversed;

    // `SHF8`, M7, on `vulkan1.3` and `vulkan1.1`: the window position's origin is the upper
    // left (`Origin.upperLeft`), so it grows with the row Vulkan copies out first;
    // a triangle whose clip-space corners run counter-clockwise with y up faces
    // the viewer under the pipeline's front face, `VK_FRONT_FACE_CLOCKWISE` (Vulkan's
    // window y points down), and the reverse does not; `discard` writes nothing;
    // derivatives are one per pixel; and a demoted invocation writes nothing
    // but keeps its quad's derivatives defined.
    const out_ = compileUnit("libs/vulkan-wsi/tests/readback-probes", test);
    scope (exit) out_.rmdirRecurse;

    Session session;
    session.open();
    ref VulkanDevice d() @system => session.d;

    string[] failures;
    void check(string vertex, string fragment, int[] delegate(int x, int row) want)
    {
        Pipeline pipeline;
        auto built = Pipeline.create(pipeline, d, VkFormat.VK_FORMAT_R8G8B8A8_UNORM, null,
            moduleOf(out_, vertex ~ suffix, "vert"), moduleOf(out_, fragment ~ suffix, "frag"), 0,
            false, vertex, fragment, 0);
        assert(!built.hasError, built.error);
        const pixels = draw(d, pipeline, stageSize, stageSize);
        pipeline.destroy(d);
        foreach (row; 0 .. stageSize)
            foreach (x; 0 .. stageSize)
            {
                const at = (row * stageSize + x) * 4;
                const w = want(x, row);
                bool differs;
                foreach (c; 0 .. 4)
                    differs |= abs(pixels[at + c] - w[c]) > 1;
                if (differs && failures.length < 20)
                    failures ~= format("%s with %s: pixel (%s, row %s) is %s, not %s", fragment,
                        vertex, x, row, pixels[at .. at + 4], w);
            }
    }

    int unorm(double v) => cast(int) lround(v * 255);
    enum string forward = __traits(identifier, stageVertex);
    enum string reversed = __traits(identifier, stageVertexReversed);
    // The clear colour is opaque black.
    check(forward, __traits(identifier, stageFragCoord), (int x, int row) => [
        unorm((x + 0.5) / stageSize), unorm((row + 0.5) / stageSize), 255, 255]);
    check(reversed, __traits(identifier, stageFragCoord), (int x, int row) => [
        unorm((x + 0.5) / stageSize), unorm((row + 0.5) / stageSize), 0, 255]);
    check(forward, __traits(identifier, stageDiscard),
        (int x, int row) => x < stageSize / 2 ? [0, 0, 0, 255] : [255, 255, 255, 255]);
    check(forward, __traits(identifier, stageDerivatives),
        (int x, int row) => [unorm(0.5), unorm(0.25), unorm(0.1875), 255]);
    if (!suffix.length)
        check(forward, __traits(identifier, stageDemote),
            (int x, int row) => x % 2 ? [0, 0, 0, 255] : [unorm(0.5), 0, 0, 255]);
    session.close();
    assert(failures.length == 0, format("%-(%s\n%)", failures));
}

/// A `width`×`height` RGBA8 image holding `pixels`, ready to be sampled.
private struct SampledImage
{
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;

    void destroy(ref VulkanDevice d) @system
    {
        auto dev = d.device.device;
        d.device.destroyImageView(dev, view, null);
        d.device.destroyImage(dev, image, null);
        d.device.freeMemory(dev, memory, null);
    }
}

private SampledImage sampledImage(ref VulkanDevice d, uint width, uint height,
    in ubyte[] pixels) @system
{
    enum format_ = VkFormat.VK_FORMAT_R8G8B8A8_UNORM;
    auto dev = d.device.device;
    SampledImage r;
    auto imageInfo = vkInfo(VkImageCreateInfo(
        imageType: VkImageType.VK_IMAGE_TYPE_2D,
        format: format_,
        extent: VkExtent3D(width, height, 1),
        mipLevels: 1,
        arrayLayers: 1,
        samples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
        tiling: VkImageTiling.VK_IMAGE_TILING_OPTIMAL,
        usage: VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        initialLayout: VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
    ));
    succeeded(d.device.createImage(dev, &imageInfo, null, &r.image));
    VkMemoryRequirements needs;
    d.device.getImageMemoryRequirements(dev, r.image, &needs);
    auto alloc = vkInfo(VkMemoryAllocateInfo(allocationSize: needs.size,
        memoryTypeIndex: memoryType(d, needs.memoryTypeBits, 0)));
    succeeded(d.device.allocateMemory(dev, &alloc, null, &r.memory));
    succeeded(d.device.bindImageMemory(dev, r.image, r.memory, 0));
    auto viewInfo = vkInfo(VkImageViewCreateInfo(
        image: r.image,
        viewType: VkImageViewType.VK_IMAGE_VIEW_TYPE_2D,
        format: format_,
        subresourceRange: VkImageSubresourceRange(
            aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
            levelCount: 1,
            layerCount: 1,
        ),
    ));
    succeeded(d.device.createImageView(dev, &viewInfo, null, &r.view));

    // The pixels, through a staging buffer.
    VkBuffer staging;
    VkDeviceMemory stagingMemory;
    hostBuffer(d, pixels.length, VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, staging,
        stagingMemory);
    scope (exit)
    {
        d.device.destroyBuffer(dev, staging, null);
        d.device.freeMemory(dev, stagingMemory, null);
    }
    void* mapped;
    succeeded(d.device.mapMemory(dev, stagingMemory, 0, pixels.length, 0, &mapped));
    (cast(ubyte*) mapped)[0 .. pixels.length] = pixels[];
    d.device.unmapMemory(dev, stagingMemory);

    CommandPool pool;
    const pooled = CommandPool.create(pool, d, 1);
    assert(!pooled.hasError, pooled.error);
    scope (exit) pool.destroy(d);
    auto begun = pool.begin(d, 0);
    assert(!begun.hasError);
    auto cmd = begun.value;
    transition(d, cmd, r.image, VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT);
    auto region = VkBufferImageCopy(
        imageSubresource: VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
            layerCount: 1,
        ),
        imageExtent: VkExtent3D(width, height, 1),
    );
    d.device.cmdCopyBufferToImage(cmd, staging, r.image,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    transition(d, cmd, r.image, VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT, VkAccessFlagBits.VK_ACCESS_SHADER_READ_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    const ended = pool.end(d, 0);
    assert(!ended.hasError);
    VkFence fence;
    auto fenceInfo = vkInfo(VkFenceCreateInfo());
    succeeded(d.device.createFence(dev, &fenceInfo, null, &fence));
    scope (exit) d.device.destroyFence(dev, fence, null);
    auto submit = vkInfo(VkSubmitInfo(commandBufferCount: 1, pCommandBuffers: &cmd));
    succeeded(d.device.queueSubmit(d.queue, 1, &submit, fence));
    succeeded(d.device.waitForFences(dev, 1, &fence, VK_TRUE, ulong.max));
    return r;
}

// Only in this package's own unittest build, as above.
version (VulkanWsiReadbackProbes)
@("vulkan_wsi.triangle_readback.eachImageReadsThroughTheSamplerItNames")
@system unittest
{
    import fragment_probe : stageVertex;

    if (environment.get("SPARKLES_VULKAN_READBACK", "") != "1")
        return skipTest("a Vulkan readback is opt-in: SPARKLES_VULKAN_READBACK=1, with a driver "
            ~ "(lavapipe) and the validation layer");

    // `SHR7`: an entry point's `SamplerState` parameters are samplers of their
    // own, each at its binding. One 2×1 image, black then white, read through
    // a nearest and a linear sampler (both clamping to the edge) across 8
    // columns: nearest gives black on the left half and white on the right;
    // linear blends between the texel centres, at u = 1/4 and 3/4.
    const out_ = compileUnit("libs/vulkan-wsi/tests/readback-probes", "samplers");
    scope (exit) out_.rmdirRecurse;

    Session session;
    session.open();
    ref VulkanDevice d() @system => session.d;
    auto dev = d.device.device;

    immutable ubyte[8] ramp = [0, 0, 0, 255, 255, 255, 255, 255];
    auto image = sampledImage(d, 2, 1, ramp[]);
    VkSampler[2] samplers;
    foreach (i, filter; [VkFilter.VK_FILTER_NEAREST, VkFilter.VK_FILTER_LINEAR])
    {
        auto info = vkInfo(VkSamplerCreateInfo(
            magFilter: filter,
            minFilter: filter,
            mipmapMode: VkSamplerMipmapMode.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            maxLod: 0,
        ));
        succeeded(d.device.createSampler(dev, &info, null, &samplers[i]));
    }

    // The image at 1, `nearest` at 2, `linear` at 3 (`sampler_probe`). The
    // shared sampler's 0 is unused, so the layout leaves it out.
    // The arrays of Vulkan structs below are filled element by element: a
    // static array of them initialised from a literal leaves DMD's unittest
    // build an undefined `RTInfoImpl` (as `Pipeline.create`'s stages note).
    enum fragmentBit = VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutBinding[3] layoutBindings;
    foreach (i, type; [VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER, VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER])
        layoutBindings[i] = VkDescriptorSetLayoutBinding(binding: cast(uint) i + 1,
            descriptorType: type, descriptorCount: 1, stageFlags: fragmentBit);
    auto layoutInfo = vkInfo(VkDescriptorSetLayoutCreateInfo(bindingCount: 3,
        pBindings: layoutBindings.ptr));
    VkDescriptorSetLayout setLayout;
    succeeded(d.device.createDescriptorSetLayout(dev, &layoutInfo, null, &setLayout));
    VkDescriptorPoolSize[2] poolSizes;
    poolSizes[0] = VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1);
    poolSizes[1] = VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER, 2);
    auto poolInfo = vkInfo(VkDescriptorPoolCreateInfo(maxSets: 1, poolSizeCount: 2,
        pPoolSizes: poolSizes.ptr));
    VkDescriptorPool pool;
    succeeded(d.device.createDescriptorPool(dev, &poolInfo, null, &pool));
    auto allocInfo = vkInfo(VkDescriptorSetAllocateInfo(descriptorPool: pool,
        descriptorSetCount: 1, pSetLayouts: &setLayout));
    VkDescriptorSet set;
    succeeded(d.device.allocateDescriptorSets(dev, &allocInfo, &set));
    auto imageInfo = VkDescriptorImageInfo(imageView: image.view,
        imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    VkDescriptorImageInfo[2] samplerInfos;
    samplerInfos[0] = VkDescriptorImageInfo(sampler: samplers[0]);
    samplerInfos[1] = VkDescriptorImageInfo(sampler: samplers[1]);
    VkWriteDescriptorSet[3] writes;
    writes[0] = vkInfo(VkWriteDescriptorSet(dstSet: set, dstBinding: 1, descriptorCount: 1,
        descriptorType: VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, pImageInfo: &imageInfo));
    foreach (i; 0 .. 2)
        writes[i + 1] = vkInfo(VkWriteDescriptorSet(dstSet: set, dstBinding: cast(uint) i + 2,
            descriptorCount: 1, descriptorType: VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER,
            pImageInfo: &samplerInfos[i]));
    d.device.updateDescriptorSets(dev, 3, writes.ptr, 0, null);

    Pipeline pipeline;
    enum string vertex = __traits(identifier, stageVertex);
    auto built = Pipeline.create(pipeline, d, VkFormat.VK_FORMAT_R8G8B8A8_UNORM, null,
        moduleOf(out_, vertex, "vert"), moduleOf(out_, "stageSamplers", "frag"), 0, false, vertex,
        "stageSamplers", 0, setLayout);
    assert(!built.hasError, built.error);
    const pixels = draw(d, pipeline, 8, 1, set);
    pipeline.destroy(d);

    string[] failures;
    foreach (x; 0 .. 8)
    {
        const u = (x + 0.5) / 8;
        const nearest = u < 0.5 ? 0 : 255;
        double t = u * 2 - 0.5;
        t = t < 0 ? 0 : t > 1 ? 1 : t;
        const linear = cast(int) lround(t * 255);
        if (abs(pixels[x * 4] - nearest) > 1 || abs(pixels[x * 4 + 1] - linear) > 1)
            failures ~= format("column %s: nearest %s, linear %s; expected %s and %s", x,
                pixels[x * 4], pixels[x * 4 + 1], nearest, linear);
    }

    d.device.destroyDescriptorPool(dev, pool, null);
    d.device.destroyDescriptorSetLayout(dev, setLayout, null);
    foreach (s; samplers)
        d.device.destroySampler(dev, s, null);
    image.destroy(d);
    session.close();
    assert(failures.length == 0, format("%-(%s\n%)", failures));
}

/// Fails the test unless `r` is `VK_SUCCESS`; the call stays outside any
/// `assert`, which a `-release` build would delete with it.
private void succeeded(VkResult r, string call = __FUNCTION__, size_t line = __LINE__)
{
    assert(r == VkResult.VK_SUCCESS, format("a Vulkan call at line %s failed: %s", line, r));
}
