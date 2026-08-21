/**
Renderer-only half of the native/SDL Vulkan triangle examples.

The two hosts deliberately share this module: it owns only image views, the
render-pass fallback, the graphics pipeline, shader blobs, and command
recording. Window lifecycle, event draining, swapchain policy and frame
synchronisation remain in their owning packages.
*/
module sparkles.vulkan_wsi.triangle;

import expected : Expected, err, ok;

import sparkles.vulkan;
import sparkles.vulkan_wsi.commands;
import sparkles.vulkan_wsi.swapchain;

version (unittest)
    import sparkles.wsi : PhysicalSize;

/// Window-sized top-left of a (possibly larger) swapchain.
///
/// X11 presents 1:1 and clips. After a shrink we keep the big images and
/// draw only this rect so the triangle tracks the window without a create.
VkExtent2D drawableExtent(Size)(in Swapchain sc, in Size windowPx)
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
    assert(drawableExtent(sc, PhysicalSize(800, 600)) == VkExtent2D(800, 600));
    assert(drawableExtent(sc, PhysicalSize(2560, 1440)) == VkExtent2D(2560, 1440));
    assert(drawableExtent(sc, PhysicalSize(3000, 2000)) == VkExtent2D(2560, 1440));
    assert(drawableExtent(sc, PhysicalSize(0, 600)) == sc.extent);
}

/// Record one frame: begin the pass, set the dynamic state, draw three vertices.
Expected!(void, string) record(Context)(ref Context vk, ref CommandPool pool,
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

private void beginRendering(Context)(ref Context vk, VkCommandBuffer cmd,
    ref VkRenderingInfo info) @system
{
    if (vk.device.cmdBeginRendering !is null)
        vk.device.cmdBeginRendering(cmd, &info);
    else
        vk.device.cmdBeginRenderingKHR(cmd, &info);
}

private void endRendering(Context)(ref Context vk, VkCommandBuffer cmd) @system
{
    if (vk.device.cmdEndRendering !is null)
        vk.device.cmdEndRendering(cmd);
    else
        vk.device.cmdEndRenderingKHR(cmd);
}

/// One colour-attachment layout transition. Dynamic rendering's substitute
/// for the render-pass `initialLayout` / `finalLayout` pair.
private void transition(Context)(ref Context vk, VkCommandBuffer cmd, VkImage image,
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

    static Expected!(void, string) create(Context)(out RenderTarget t, ref Context vk,
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
    Expected!(void, string) rebind(Context)(ref Context vk, ref Swapchain sc) @system
    {
        destroyViews(vk);
        return createViews(vk, sc);
    }

    private Expected!(void, string) createViews(Context)(ref Context vk, ref Swapchain sc)
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

    void destroy(Context)(ref Context vk) @system nothrow
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
    private void destroyViews(Context)(ref Context vk) @system nothrow
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

    static Expected!(void, string) create(Context)(out Pipeline p, ref Context vk,
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

    void destroy(Context)(ref Context vk) @system nothrow
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

private Expected!(void, string) createModule(Context)(ref Context vk,
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
