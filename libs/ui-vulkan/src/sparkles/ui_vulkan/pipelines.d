/**
The canvas's GPU objects that outlive any one frame: its descriptor-set
layout, its pipeline layout, its two samplers, its shader modules, and a
pipeline per target format — with a render pass, where the device has no
dynamic rendering (`UVK2`, `UVX10`).

Everything here is made once per device and survives a lost surface; only
framebuffers, which name a target's views or extent, belong to a target
(`UVK26`), and the canvas keeps those.
*/
module sparkles.ui_vulkan.pipelines;

import expected : err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.shaders.layout : layoutOf, Rule;
import sparkles.ui_vulkan.shading : Binding, canvasVertex, CanvasView, Instance;
import sparkles.vulkan;

/// What the canvas needs to know of its device, so a fake device can stand
/// in for a real one in tests.
struct DeviceFacts
{
    uint apiVersion;           /// the version the device was created at
    bool dynamicRendering;     /// dynamic rendering is enabled
    bool imagelessFramebuffer; /// imageless framebuffers are enabled
    uint maxImageExtent;       /// `maxImageDimension2D`
    VkPipelineCache pipelineCache; /// where pipelines are compiled through, if any

    /// The facts of a `sparkles:vulkan-wsi` device (or anything shaped like one).
    static DeviceFacts of(D)(ref const D device)
        => DeviceFacts(device.apiVersion, device.dynamicRendering, device.imagelessFramebuffer,
            device.properties.limits.maxImageDimension2D, cast(VkPipelineCache) device.pipelineCache);

    /// Whether the device takes SPIR-V 1.6: Vulkan 1.3 or later.
    bool spirv16() const @safe pure nothrow @nogc
        => apiVersionMajor(apiVersion) > 1
            || (apiVersionMajor(apiVersion) == 1 && apiVersionMinor(apiVersion) >= 3);
}

/// The entry points' names: the vertex function's, and the device-only
/// fragment function's, which the host cannot name by symbol.
enum string vertexEntry = __traits(identifier, canvasVertex);
/// ditto
enum string fragmentEntry = "canvasFragment";

/// The push-constant block's size, as its range declares it.
enum uint canvasViewBytes = cast(uint) layoutOf!(CanvasView, Rule.std430).size;

/// The stages that read the push constants.
enum VkShaderStageFlags canvasViewStages = VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT
    | VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT;

/// Whether `format` stores colour in the sRGB encoding (`UVK7`).
bool isSrgb(VkFormat format) @safe pure nothrow @nogc
{
    with (VkFormat) switch (format)
    {
        case VK_FORMAT_R8G8B8A8_SRGB:
        case VK_FORMAT_B8G8R8A8_SRGB:
        case VK_FORMAT_A8B8G8R8_SRGB_PACK32:
        case VK_FORMAT_R8G8B8_SRGB:
        case VK_FORMAT_B8G8R8_SRGB:
            return true;
        default:
            return false;
    }
}

/// The canvas's pipeline for one target format, and the render pass it was
/// made for (`null` with dynamic rendering).
struct FormatPipeline
{
    VkFormat format;         ///
    VkPipeline pipeline;     ///
    VkRenderPass renderPass; ///
}

/**
The canvas's device-scoped objects. Not copyable; `destroy` releases them,
the device commands having to outlive it.
*/
struct Pipelines
{
    VkDescriptorSetLayout setLayout; ///
    VkPipelineLayout layout;         ///
    VkSampler nearest;               /// for atlas pages (`UVK21`)
    VkSampler linear;                /// for images (`UVK24`)
    private VkShaderModule vertex_, fragment_;
    private UniqueBuffer!FormatPipeline formats_;
    private DeviceFacts facts_;

    @disable this(this);

    /**
    The layouts, samplers and shader modules: `vertexCode` and `fragmentCode`
    are the SPIR-V of `canvasVertex` and `canvasFragment` for the device's
    profile. On failure nothing is left created.
    */
    static VkExpected!() create(out Pipelines p, ref DeviceCommands device, DeviceFacts facts,
        immutable(uint)[] vertexCode, immutable(uint)[] fragmentCode) @system
    {
        p.facts_ = facts;
        auto made = p.createAll(device, vertexCode, fragmentCode);
        if (made.hasError)
            p.destroy(device);
        return made;
    }

    private VkExpected!() createAll(ref DeviceCommands device, immutable(uint)[] vertexCode,
        immutable(uint)[] fragmentCode) @system
    {
        // Binding numbers from `Binding`, which the fragment function's
        // `@binding`s name too, so the two cannot disagree.
        VkDescriptorSetLayoutBinding[5] bindings;
        foreach (i, b; [Binding.coverage, Binding.colour, Binding.image])
            bindings[i] = VkDescriptorSetLayoutBinding(binding: b,
                descriptorType: VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                descriptorCount: 1,
                stageFlags: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT);
        foreach (i, b; [Binding.nearest, Binding.linear])
            bindings[3 + i] = VkDescriptorSetLayoutBinding(binding: b,
                descriptorType: VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT);
        auto setInfo = vkInfo(VkDescriptorSetLayoutCreateInfo(bindingCount: bindings.length,
            pBindings: bindings.ptr));
        auto r = device.createDescriptorSetLayout(device.device, &setInfo, null, &setLayout);
        if (r < 0)
            return err!void(r);

        auto push = VkPushConstantRange(stageFlags: canvasViewStages, offset: 0,
            size: canvasViewBytes);
        auto layoutInfo = vkInfo(VkPipelineLayoutCreateInfo(setLayoutCount: 1,
            pSetLayouts: &setLayout, pushConstantRangeCount: 1, pPushConstantRanges: &push));
        r = device.createPipelineLayout(device.device, &layoutInfo, null, &layout);
        if (r < 0)
            return err!void(r);

        r = createSampler(device, VkFilter.VK_FILTER_NEAREST, nearest);
        if (r < 0)
            return err!void(r);
        r = createSampler(device, VkFilter.VK_FILTER_LINEAR, linear);
        if (r < 0)
            return err!void(r);

        r = createModule(device, vertexCode, vertex_);
        if (r < 0)
            return err!void(r);
        r = createModule(device, fragmentCode, fragment_);
        if (r < 0)
            return err!void(r);
        return ok!VkResult();
    }

    /// The pipeline for targets of `format`, made on first use.
    VkExpected!FormatPipeline forFormat(ref DeviceCommands device, VkFormat format) @system
    {
        foreach (ref f; formats_[])
            if (f.format == format)
                return ok!VkResult(f);
        FormatPipeline made = FormatPipeline(format: format);
        if (!facts_.dynamicRendering)
        {
            auto r = createRenderPass(device, format, made.renderPass);
            if (r < 0)
                return err!FormatPipeline(r);
        }
        auto r = createPipeline(device, format, made.renderPass, made.pipeline);
        if (r < 0)
        {
            if (made.renderPass !is null)
                device.destroyRenderPass(device.device, made.renderPass, null);
            return err!FormatPipeline(r);
        }
        formats_.put(made);
        return ok!VkResult(made);
    }

    /// How many target formats have a pipeline.
    size_t formatCount() const => formats_.length;

    /// Destroys everything; idempotent.
    void destroy(ref DeviceCommands device) @system
    {
        foreach (ref f; formats_[])
        {
            device.destroyPipeline(device.device, f.pipeline, null);
            if (f.renderPass !is null)
                device.destroyRenderPass(device.device, f.renderPass, null);
        }
        formats_.clear();
        if (vertex_ !is null)
            device.destroyShaderModule(device.device, vertex_, null);
        if (fragment_ !is null)
            device.destroyShaderModule(device.device, fragment_, null);
        if (nearest !is null)
            device.destroySampler(device.device, nearest, null);
        if (linear !is null)
            device.destroySampler(device.device, linear, null);
        if (layout !is null)
            device.destroyPipelineLayout(device.device, layout, null);
        if (setLayout !is null)
            device.destroyDescriptorSetLayout(device.device, setLayout, null);
        vertex_ = fragment_ = null;
        nearest = linear = null;
        layout = null;
        setLayout = null;
    }

    private static VkResult createSampler(ref DeviceCommands device, VkFilter filter,
        out VkSampler sampler) @system
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
        return device.createSampler(device.device, &info, null, &sampler);
    }

    private static VkResult createModule(ref DeviceCommands device, immutable(uint)[] words,
        out VkShaderModule mod) @system
    {
        auto info = vkInfo(VkShaderModuleCreateInfo(codeSize: words.length * uint.sizeof,
            pCode: words.ptr));
        return device.createShaderModule(device.device, &info, null, &mod);
    }

    // A pass of one colour attachment that clears it, for a target already
    // in the attachment layout and left there (`UVK4`).
    private static VkResult createRenderPass(ref DeviceCommands device, VkFormat format,
        out VkRenderPass pass) @system
    {
        auto attachment = VkAttachmentDescription(
            format: format,
            samples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
            loadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            finalLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        );
        auto colour = VkAttachmentReference(0,
            VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        auto subpass = VkSubpassDescription(
            pipelineBindPoint: VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments: &colour,
        );
        // The transition before the pass is a barrier of its own; this orders
        // the pass's clear after it.
        auto dependency = VkSubpassDependency(
            srcSubpass: VK_SUBPASS_EXTERNAL,
            dstSubpass: 0,
            srcStageMask: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            dstStageMask: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            srcAccessMask: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            dstAccessMask: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        );
        auto info = vkInfo(VkRenderPassCreateInfo(
            attachmentCount: 1,
            pAttachments: &attachment,
            subpassCount: 1,
            pSubpasses: &subpass,
            dependencyCount: 1,
            pDependencies: &dependency,
        ));
        return device.createRenderPass(device.device, &info, null, &pass);
    }

    private VkResult createPipeline(ref DeviceCommands device, VkFormat format,
        VkRenderPass renderPass, out VkPipeline pipeline) @system
    {
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0] = vkInfo(VkPipelineShaderStageCreateInfo(
            stage: VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
            pName: vertexEntry.ptr,
        ));
        stages[1] = vkInfo(VkPipelineShaderStageCreateInfo(
            stage: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
            pName: fragmentEntry.ptr,
        ));
        // `module` is a D keyword: reachable only by name.
        __traits(getMember, stages[0], "module") = vertex_;
        __traits(getMember, stages[1], "module") = fragment_;

        // One binding of quad records, read per instance (`UVX5`), each of
        // `Instance`'s fields one attribute at its location.
        auto binding = VkVertexInputBindingDescription(binding: 0, stride: Instance.sizeof,
            inputRate: VkVertexInputRate.VK_VERTEX_INPUT_RATE_INSTANCE);
        VkVertexInputAttributeDescription[5] attributes;
        static foreach (i, field; ["box", "fill", "edge", "shape", "texRect"])
            attributes[i] = VkVertexInputAttributeDescription(location: i, binding: 0,
                format: VkFormat.VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: __traits(getMember, Instance, field).offsetof);
        auto vertexInput = vkInfo(VkPipelineVertexInputStateCreateInfo(
            vertexBindingDescriptionCount: 1,
            pVertexBindingDescriptions: &binding,
            vertexAttributeDescriptionCount: attributes.length,
            pVertexAttributeDescriptions: attributes.ptr,
        ));
        auto assembly = vkInfo(VkPipelineInputAssemblyStateCreateInfo(
            topology: VkPrimitiveTopology.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        ));
        auto viewportState = vkInfo(VkPipelineViewportStateCreateInfo(viewportCount: 1,
            scissorCount: 1));
        auto raster = vkInfo(VkPipelineRasterizationStateCreateInfo(
            polygonMode: VkPolygonMode.VK_POLYGON_MODE_FILL,
            cullMode: VkCullModeFlagBits.VK_CULL_MODE_NONE,
            frontFace: VkFrontFace.VK_FRONT_FACE_CLOCKWISE,
            lineWidth: 1.0f,
        ));
        auto multisample = vkInfo(VkPipelineMultisampleStateCreateInfo(
            rasterizationSamples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
        ));
        // Premultiplied source over destination (`UVK6`).
        auto blendAttachment = VkPipelineColorBlendAttachmentState(
            blendEnable: VK_TRUE,
            srcColorBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE,
            dstColorBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            colorBlendOp: VkBlendOp.VK_BLEND_OP_ADD,
            srcAlphaBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE,
            dstAlphaBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            alphaBlendOp: VkBlendOp.VK_BLEND_OP_ADD,
            colorWriteMask: VkColorComponentFlagBits.VK_COLOR_COMPONENT_R_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_G_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_B_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_A_BIT,
        );
        auto blend = vkInfo(VkPipelineColorBlendStateCreateInfo(attachmentCount: 1,
            pAttachments: &blendAttachment));
        VkDynamicState[2] dynamicStates = [VkDynamicState.VK_DYNAMIC_STATE_VIEWPORT,
            VkDynamicState.VK_DYNAMIC_STATE_SCISSOR];
        auto dynamic = vkInfo(VkPipelineDynamicStateCreateInfo(
            dynamicStateCount: dynamicStates.length, pDynamicStates: dynamicStates.ptr));
        auto colourFormat = format;
        auto rendering = vkInfo(VkPipelineRenderingCreateInfo(colorAttachmentCount: 1,
            pColorAttachmentFormats: &colourFormat));
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
            layout: layout,
            renderPass: renderPass,
            subpass: 0,
        ));
        return device.createGraphicsPipelines(device.device, facts_.pipelineCache, 1, &info,
            null, &pipeline);
    }
}

@("ui_vulkan.pipelines.srgbFormats")
@safe pure nothrow @nogc
unittest
{
    assert(isSrgb(VkFormat.VK_FORMAT_B8G8R8A8_SRGB) && isSrgb(VkFormat.VK_FORMAT_R8G8B8A8_SRGB));
    assert(!isSrgb(VkFormat.VK_FORMAT_B8G8R8A8_UNORM) && !isSrgb(VkFormat.VK_FORMAT_R8G8B8A8_UNORM));
}

@("ui_vulkan.pipelines.spirv16FromVulkan13")
@safe pure nothrow @nogc
unittest
{
    assert(DeviceFacts(apiVersion: apiVersion13).spirv16);
    assert(!DeviceFacts(apiVersion: apiVersion11).spirv16);
    assert(!DeviceFacts(apiVersion: apiVersion12).spirv16);
}
