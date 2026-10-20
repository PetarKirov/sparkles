/**
Renderer-only half of the native/SDL Vulkan triangle examples.

The two hosts deliberately share this module: it owns only image views, the
render-pass fallback, the graphics pipeline, shader blobs, and command
recording. Window lifecycle, event draining, swapchain policy and frame
synchronisation remain in their owning packages.

The triangle's own shaders are D (`sparkles.vulkan_wsi.triangle_shader`),
compiled to SPIR-V by the `gpu-shaders` configuration, which also compiles
in $(LREF createTriangle) (`SparklesVulkanWsiTriangle`). Without it the
pipeline still builds from any SPIR-V a caller passes: the test pattern's.
*/
module sparkles.vulkan_wsi.triangle;

import expected : Expected, err, ok;

import sparkles.base.text.cstring : toTempStringz;
import sparkles.shaders.layout : layoutOf, Rule, writeLayout;
import sparkles.shaders.resources : PushConstantsOf;
import sparkles.vulkan;
import sparkles.vulkan_wsi.commands;
import sparkles.vulkan_wsi.swapchain;
import sparkles.vulkan_wsi.triangle_shader : triangleFragment, triangleVertex, TriangleView;

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
    uint frame, uint imageIndex, VkExtent2D drawExtent,
    scope const(void)[] pushConstants = null) @system
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
    if (pushConstants.length != 0)
        vk.device.cmdPushConstants(cmd, pipeline.layout, pipeline.pushConstantStages, 0,
            cast(uint) pushConstants.length, pushConstants.ptr);

    // Three vertices, no buffers: the shader indexes constants by its
    // vertex index. See `triangle_shader.d`.
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

package void beginRendering(Context)(ref Context vk, VkCommandBuffer cmd,
    ref VkRenderingInfo info) @system
{
    if (vk.device.cmdBeginRendering !is null)
        vk.device.cmdBeginRendering(cmd, &info);
    else
        vk.device.cmdBeginRenderingKHR(cmd, &info);
}

package void endRendering(Context)(ref Context vk, VkCommandBuffer cmd) @system
{
    if (vk.device.cmdEndRendering !is null)
        vk.device.cmdEndRendering(cmd);
    else
        vk.device.cmdEndRenderingKHR(cmd);
}

/// One colour-attachment layout transition. Dynamic rendering's substitute
/// for the render-pass `initialLayout` / `finalLayout` pair.
package void transition(Context)(ref Context vk, VkCommandBuffer cmd, VkImage image,
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
            return t.createViewsOrDestroy(vk, sc);


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

        return t.createViewsOrDestroy(vk, sc);
    }

    // At creation, a failure leaves nothing behind: the render pass goes
    // too.
    private Expected!(void, string) createViewsOrDestroy(Context)(ref Context vk,
        ref Swapchain sc) @system
    {
        auto made = createViews(vk, sc);
        if (made.hasError)
            destroy(vk);
        return made;
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
                destroyViews(vk);
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
                destroyViews(vk);
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

/// The bytes of the triangle's push-constant block, `std430`, as the
/// pipeline's range declares them.
enum size_t triangleViewBytes = layoutOf!(TriangleView, Rule.std430).size;

/// The stages whose entry points declare the triangle's push-constant block,
/// which its range is declared for.
enum VkShaderStageFlags triangleViewStages =
    (is(PushConstantsOf!triangleVertex == void) ? 0 : VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT)
    | (is(PushConstantsOf!triangleFragment == void) ? 0
        : VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT);

/// The push constants of a frame drawn into `extent`: its aspect ratio.
ubyte[triangleViewBytes] triangleView(VkExtent2D extent) @safe pure nothrow @nogc
{
    ubyte[triangleViewBytes] bytes;
    const view = TriangleView(aspect: extent.height == 0 ? 1.0f
        : cast(float) extent.width / extent.height);
    writeLayout!(TriangleView, Rule.std430)(view, bytes[]);
    return bytes;
}

@("vulkan_triangle.triangleViewIsTheAspectRatio")
@safe pure nothrow @nogc unittest
{
    const bytes = triangleView(VkExtent2D(800, 400));
    float aspect;
    (() @trusted => (cast(ubyte*) &aspect)[0 .. 4] = bytes[0 .. 4])();
    assert(aspect == 2.0f);
}

version (SparklesVulkanWsiTriangle)
{
    // Generated from `triangle_shader.d` into `generated/shaders/`, one entry
    // point per module, each file named after it.
    private static immutable uint[] triangleVert =
        spirvWords(import(__traits(identifier, triangleVertex) ~ ".vert.spv"));
    private static immutable uint[] triangleFrag =
        spirvWords(import(__traits(identifier, triangleFragment) ~ ".frag.spv"));
    static assert(triangleVert.length > 4 && triangleVert[0] == spirvMagic,
        "the triangle's vertex SPIR-V is not little-endian SPIR-V — regenerate it");
    static assert(triangleFrag.length > 4 && triangleFrag[0] == spirvMagic,
        "the triangle's fragment SPIR-V is not little-endian SPIR-V — regenerate it");

    /**
    Builds the triangle's pipeline for `colorFormat`: its two stages, each
    named after its D function, and the push-constant range of
    `TriangleView`, for the stages whose entry points declare it.
    */
    Expected!(void, string) createTriangle(Context)(out Pipeline p, ref Context vk,
        VkFormat colorFormat, VkRenderPass renderPass = null) @system
        => Pipeline.create(p, vk, colorFormat, renderPass, triangleVert, triangleFrag,
            cast(uint) triangleViewBytes, false, __traits(identifier, triangleVertex),
            __traits(identifier, triangleFragment), triangleViewStages);
}

/// The graphics pipeline and the objects it owns.
struct Pipeline
{
    VkPipeline handle;
    VkPipelineLayout layout;
    /// Whether the driver reported how it created the pipeline (Vulkan 1.3's
    /// creation feedback): if so, whether it took the pipeline whole from the
    /// context's pipeline cache, and how long creating it took.
    bool creationFeedback;
    bool fromCache; /// ditto
    ulong creationNanos; /// ditto
    /// The stages the push-constant range is declared for, and pushed to.
    VkShaderStageFlags pushConstantStages;

    @disable this(this);

    /**
    Builds the pipeline for `colorFormat` from a pair of SPIR-V modules,
    drawing three vertices with no buffers. The modules' entry points are
    `vertEntry` and `fragEntry`; they may declare `pushConstantBytes` of push
    constants, for `pushStages`, and the fragment stage a boolean
    specialization constant 0, set to `srgbTarget`. A `setLayout` is the
    layout of descriptor set 0, for shaders that bind resources.
    */
    static Expected!(void, string) create(Context)(out Pipeline p, ref Context vk,
        VkFormat colorFormat, VkRenderPass renderPass,
        immutable(uint)[] vertCode, immutable(uint)[] fragCode,
        uint pushConstantBytes = 0, bool srgbTarget = false,
        string vertEntry = "main", string fragEntry = "main",
        VkShaderStageFlags pushStages = VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
        VkDescriptorSetLayout setLayout = null) @system
    {
        p.pushConstantStages = pushStages;
        VkShaderModule vert, frag;
        auto vertMade = createModule(vk, vertCode, vert);
        if (vertMade.hasError)
            return vertMade;
        scope (exit)
            vk.device.destroyShaderModule(vk.device.device, vert, null);

        auto fragMade = createModule(vk, fragCode, frag);
        if (fragMade.hasError)
            return fragMade;
        scope (exit)
            vk.device.destroyShaderModule(vk.device.device, frag, null);

        auto vertName = vertEntry.toTempStringz;
        auto fragName = fragEntry.toTempStringz;
        // Element by element: an array literal of runtime pointers needs the
        // struct's `TypeInfo`, whose `RTInfo` DMD leaves undefined for an
        // ImportC struct in a unittest build.
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0] = vkInfo(VkPipelineShaderStageCreateInfo(
            stage: VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
            pName: vertName.ptr,
        ));
        stages[1] = vkInfo(VkPipelineShaderStageCreateInfo(
            stage: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
            pName: fragName.ptr,
        ));

        // The field is spelled `module`, which is a D keyword — ImportC keeps
        // C's name, so it is unreachable by both named-argument syntax and
        // ordinary member access. `__traits(getMember)` takes it as a string
        // and is the only way to write to it.
        __traits(getMember, stages[0], "module") = vert;
        __traits(getMember, stages[1], "module") = frag;

        // Constant 0 of the fragment stage; a shader that declares none
        // ignores it.
        VkBool32 srgb = srgbTarget ? VK_TRUE : VK_FALSE;
        auto entry = VkSpecializationMapEntry(constantID: 0, offset: 0,
            size: VkBool32.sizeof);
        auto specialization = VkSpecializationInfo(mapEntryCount: 1,
            pMapEntries: &entry, dataSize: VkBool32.sizeof, pData: &srgb);
        stages[1].pSpecializationInfo = &specialization;

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

        auto pushRange = VkPushConstantRange(
            stageFlags: pushStages, offset: 0, size: pushConstantBytes);
        auto layoutInfo = vkInfo(VkPipelineLayoutCreateInfo(
            setLayoutCount: setLayout is null ? 0 : 1,
            pSetLayouts: &setLayout,
            pushConstantRangeCount: pushConstantBytes == 0 ? 0 : 1,
            pPushConstantRanges: &pushRange,
        ));
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

        // Through the device's pipeline cache when it keeps one (§10.1),
        // so a pipeline compiled once is not compiled again.
        VkPipelineCache cache;
        static if (is(typeof(vk.pipelineCache) : VkPipelineCache))
            cache = vk.pipelineCache;
        // Whether the cache served it, from the driver itself (core in 1.3).
        VkPipelineCreationFeedback whole;
        auto feedback = vkInfo(VkPipelineCreationFeedbackCreateInfo(
            pPipelineCreationFeedback: &whole,
        ));
        const askFeedback = vk.device.has!vkVersion13;
        if (askFeedback)
        {
            feedback.pNext = info.pNext;
            info.pNext = &feedback;
        }
        auto made = vk.device.createGraphicsPipelines(
            vk.device.device, cache, 1, &info, null, &p.handle).check;
        if (made.hasError)
        {
            p.destroy(vk);
            return err!void("vkCreateGraphicsPipelines: " ~ describeResult(made.error));
        }
        with (VkPipelineCreationFeedbackFlagBits)
            if (askFeedback && (whole.flags & VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT))
            {
                p.creationFeedback = true;
                p.fromCache = (whole.flags
                    & VK_PIPELINE_CREATION_FEEDBACK_APPLICATION_PIPELINE_CACHE_HIT_BIT) != 0;
                p.creationNanos = whole.duration;
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

version (unittest)
{
    // A device whose image views cannot be made, and that counts the render
    // passes it destroys.
    private struct FailingViews
    {
        DeviceCommands device;
        bool dynamicRendering;
        static int renderPassesDestroyed;
    }

    private extern (C) VkResult failCreateImageView(VkDevice, const(VkImageViewCreateInfo)*,
        const(VkAllocationCallbacks)*, VkImageView*) nothrow @nogc
        => VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    private extern (C) void countDestroyRenderPass(VkDevice, VkRenderPass,
        const(VkAllocationCallbacks)*) nothrow @nogc
    {
        FailingViews.renderPassesDestroyed++;
    }
    private extern (C) void ignoreDestroyImageView(VkDevice, VkImageView,
        const(VkAllocationCallbacks)*) nothrow @nogc {}
    private extern (C) void ignoreDestroyFramebuffer(VkDevice, VkFramebuffer,
        const(VkAllocationCallbacks)*) nothrow @nogc {}
}

@("vulkan_triangle.aFailedRebindKeepsTheRenderPass")
@system unittest
{
    // `rebind` keeps the render pass it was built with, failure included, so
    // the next rebind can retry; a target that fails while being created
    // leaves nothing behind.
    FailingViews vk;
    vk.device.device = cast(VkDevice) cast(void*) 1;
    vk.device.createImageView = &failCreateImageView;
    vk.device.destroyRenderPass = &countDestroyRenderPass;
    vk.device.destroyImageView = &ignoreDestroyImageView;
    vk.device.destroyFramebuffer = &ignoreDestroyFramebuffer;

    Swapchain sc;
    sc.images = new VkImage[2];
    RenderTarget t;
    t.renderPass = cast(VkRenderPass) cast(void*) 2;
    FailingViews.renderPassesDestroyed = 0;
    assert(t.rebind(vk, sc).hasError);
    assert(t.renderPass !is null && FailingViews.renderPassesDestroyed == 0);

    RenderTarget fresh;
    vk.dynamicRendering = true;
    assert(RenderTarget.create(fresh, vk, sc).hasError);
    assert(fresh.views.length == 2 && fresh.views[0] is null);
}
