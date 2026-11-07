/**
The Vulkan canvas's effect backend: an effect record's SPIR-V passes run over
a bracket of the frame (`UVK15`, `EFX11`, `EFX21`).

The canvas renders a bracket's draws into a scratch image the size of its
target. The chain then copies the bracket's rectangle out of it into the
chain's first image (image 0, the bracket), turned upside down: the passes
were written against OpenGL's images, whose first row is the bottom one, and
every image of a chain is kept that way so a pass samples any of them at the
same `fragTexCoord` (`EffectView`). Each pass but the last renders into an
image of its own, at the bracket's size over its `downscale`; the last one
draws onto the target at the bracket's rectangle, blended over what is
there, the picture upright again.

A pass's fragment stage is the record's artifact for this device's Vulkan
version (`vulkan13Backend`, `vulkan11Backend`), read only for its interface
(`spirv_interface`); its vertex stage is `effectVertex`. Its uniform block is
filled by name: `uResolution`, `uExtentCells`, `uTime` and `colDiffuse` from
what the chain supplies, as raylib's backend does, and every other member
from the record's parameter of that name.

Pipelines are made per artifact, target format and role, on first use, and
kept; images are kept per role and remade when the size changes, the old
one retired through the canvas so no frame in flight loses it. Descriptor
sets live in per-slot pools, reset when the slot is begun again. Only the
dynamic-rendering path runs effects; the canvas degrades without it.
*/
module sparkles.ui_vulkan.effect_chain;

import sparkles.base.expected : err, ok;

import sparkles.base.text.cstring : toTempStringz;
import sparkles.shaders.layout : layoutOf, Rule, writeLayout;
import sparkles.ui.effect : EffectImpl, EffectParam, EffectPass, EffectRecord,
    previousImage, vulkan11Backend, vulkan13Backend;
import sparkles.ui.geometry : Size;
import sparkles.ui.pixel_geometry : ScissorBox;
import sparkles.ui_vulkan.frame_buffers : BufferSlice, FrameBuffers;
import sparkles.ui_vulkan.pipelines : DeviceFacts;
import sparkles.ui_vulkan.resources : GpuImage;
import sparkles.ui_vulkan.shading : EffectView;
import sparkles.ui_vulkan.spirv_interface : DescriptorKind, FragmentInterface,
    readFragmentInterface;
import sparkles.ui_vulkan.upload : transition;
import sparkles.vulkan;

/// The effect passes' vertex stage, `effectVertex`, for each SPIR-V version.
private static immutable uint[] effectVertex13 = spirvWords(import("effectVertex.vert.spv"));
/// ditto
private static immutable uint[] effectVertex11 = spirvWords(import("effectVertex.vk11.vert.spv"));
static assert(effectVertex13[0] == spirvMagic && effectVertex11[0] == spirvMagic,
    "the effect vertex stage is not little-endian SPIR-V — regenerate it");

/// The push-constant range of the effect passes' vertex stage.
private enum uint effectViewBytes = cast(uint) layoutOf!(EffectView, Rule.std430).size;

/// What the chain supplies to a pass beside the record's parameters.
struct Supplied
{
    float[2] resolution; /// the size of the image the pass writes, in pixels
    float[2] extentCells; /// the bracket's size in cells
    float time;           /// the effect clock, in seconds
}

/**
Writes a pass's uniform block into `block`, member by member at the offsets
`fi` reads: the values the chain supplies under their names
(`uResolution`, `uExtentCells`, `uTime`, `colDiffuse` — raylib's vertex
colour, white), every other member from the parameter of its name, and zero
for a member nothing names.
*/
void fillUniformBlock(in FragmentInterface fi, ubyte[] block, in EffectParam[] params,
    in Supplied supplied) @safe pure nothrow @nogc
{
    block[] = 0;
    foreach (ref m; fi.members)
    {
        float[4] v = 0;
        switch (m.name)
        {
            case "uResolution": v[0 .. 2] = supplied.resolution; break;
            case "uExtentCells": v[0 .. 2] = supplied.extentCells; break;
            case "uTime": v[0] = supplied.time; break;
            case "colDiffuse": v = 1; break;
            default:
                foreach (ref p; params)
                    if (p.name == m.name)
                    {
                        v = p.value;
                        break;
                    }
                break;
        }
        const n = m.size / 4 > 4 ? 4 : m.size / 4;
        if (m.offset + n * 4 > block.length)
            continue;
        foreach (i; 0 .. n)
        {
            const bits = (() @trusted => *cast(const(uint)*) &v[i])();
            foreach (b; 0 .. 4)
                block[m.offset + i * 4 + b] = cast(ubyte)(bits >> (8 * b));
        }
    }
}

/// The image pass `k` of `passes` reads as `texture0`, by `EffectPass.from`.
size_t sourceOf(in EffectPass pass, size_t k) @safe pure nothrow @nogc
    => pass.from == previousImage ? k : pass.from;

/// The passes `impl` runs: its own, or its one source as a single pass that
/// composites the bracket.
const(EffectPass)[] passesOf(const(EffectImpl)* impl) @safe pure nothrow
    => impl.passes.length ? impl.passes : [EffectPass(impl.source, from: 0)];

/// An effect backend for a Vulkan canvas. Not copyable.
struct EffectChain(B)
{
    private static struct Program
    {
        immutable(char)* key; // the artifact's bytes: its identity
        size_t length;
        VkFormat format;
        bool composite;       // draws onto the target, blended
        bool failed;          // the artifact cannot run here: never retried
        FragmentInterface fi;
        VkShaderModule fragment;
        VkDescriptorSetLayout setLayout;
        VkPipelineLayout layout;
        VkPipeline pipeline;
    }

    private static struct SlotPool
    {
        uint slot;
        VkDescriptorPool pool;
    }

    private DeviceCommands* device_;
    private DeviceMemory!B* memory_;
    private DeviceFacts facts_;
    private bool modern_;
    private VkShaderModule vertex_;
    private VkSampler linear_;
    private Program[] programs_;
    private GpuImage[] images_; // 0: the scratch target; 1: the bracket; 2 + k: pass k's output
    private SlotPool[] pools_;
    private void delegate(ref GpuImage) @system retire_;

    @disable this(this);

    /**
    A chain on `device`, which with `memory` must outlive it; `modern` picks
    SPIR-V 1.6 (a Vulkan 1.3 device) over 1.3. `retire` takes an image the
    chain no longer wants, for the canvas to destroy once no frame in flight
    reads it. On failure nothing is left created.
    */
    static VkExpected!() create(out EffectChain c, ref DeviceCommands device,
        ref DeviceMemory!B memory, DeviceFacts facts, bool modern,
        void delegate(ref GpuImage) @system retire) @system
    {
        c.device_ = &device;
        c.memory_ = &memory;
        c.facts_ = facts;
        c.modern_ = modern;
        c.retire_ = retire;
        const code = modern ? effectVertex13 : effectVertex11;
        auto moduleInfo = vkInfo(VkShaderModuleCreateInfo(codeSize: code.length * uint.sizeof,
            pCode: code.ptr));
        auto r = device.createShaderModule(device.device, &moduleInfo, null, &c.vertex_);
        if (r < 0)
        {
            c.destroy();
            return err!void(r);
        }
        auto samplerInfo = vkInfo(VkSamplerCreateInfo(
            magFilter: VkFilter.VK_FILTER_LINEAR,
            minFilter: VkFilter.VK_FILTER_LINEAR,
            mipmapMode: VkSamplerMipmapMode.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            maxLod: 0,
        ));
        r = device.createSampler(device.device, &samplerInfo, null, &c.linear_);
        if (r < 0)
        {
            c.destroy();
            return err!void(r);
        }
        return ok!VkResult();
    }

    /// The backend key this device's passes are looked up under.
    string backend() const @safe pure nothrow @nogc => modern_ ? vulkan13Backend : vulkan11Backend;

    /**
    The implementation of `record` this chain can run on targets of `format`,
    its pipelines made; `null` if there is none — the record carries no
    artifact for this device, or one the chain cannot read or the driver
    refuses — and the bracket then paints unaffected (`EFX3`).
    */
    const(EffectImpl)* prepare(const(EffectRecord)* record, VkFormat format) @system
    {
        if (record is null || device_ is null)
            return null;
        const impl = record.implFor(backend);
        if (impl is null || (impl.source is null && !impl.passes.length))
            return null;
        const passes = passesOf(impl);
        foreach (k, ref pass; passes)
        {
            if (pass.source.length == 0 || sourceOf(pass, k) > k)
                return null;
            foreach (input; pass.inputs)
                if (input > k)
                    return null;
            if (programFor(pass.source, format, k + 1 == passes.length) is null)
                return null;
        }
        return impl;
    }

    /// Resets `slot`'s descriptor sets: its previous frame has completed.
    void beginFrame(uint slot) @system
    {
        foreach (ref p; pools_)
            if (p.slot == slot)
                device_.resetDescriptorPool(device_.device, p.pool, 0);
    }

    /**
    The image a bracket's draws are rendered into, at least `extent` and of
    `format`; remade, the old one retired, when either changes.
    */
    VkExpected!(GpuImage*) scratch(VkFormat format, VkExtent2D extent) @system
    {
        auto r = acquire(0, format, extent);
        if (r < 0)
            return err!(GpuImage*)(r);
        return ok!VkResult(&images_[0]);
    }

    /**
    Records `impl`'s passes (`prepare` made its pipelines) over the bracket at
    `rect` of the scratch image, which the canvas has just rendered and left
    in the attachment layout; the last pass composites onto `target` (in the
    attachment layout, and left there) at the same rectangle. `cells` is the
    bracket's size in cells and `time` the effect clock.
    */
    VkResult record(VkCommandBuffer commands, uint slot, const(EffectRecord)* rec,
        const(EffectImpl)* impl, ref FrameBuffers!B buffers, ScissorBox rect, Size cells,
        VkImage targetImage, VkImageView target, VkFormat format, VkExtent2D drawn, float time)
        @system
    {
        with (VkPipelineStageFlagBits) with (VkAccessFlagBits) with (VkImageLayout)
        {
            const w = cast(uint) rect.w, h = cast(uint) rect.h;
            auto r = acquire(1, format, VkExtent2D(w, h));
            if (r < 0)
                return r;
            auto scratchImage = images_[0].handle;
            auto bracket = images_[1].handle;
            transition(*device_, commands, scratchImage, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_READ_BIT);
            transition(*device_, commands, bracket, VK_IMAGE_LAYOUT_UNDEFINED,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT);
            // Upside down: the bracket's top row becomes the image's last.
            const colour = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT, layerCount: 1);
            VkImageBlit flip = {
                srcSubresource: colour,
                srcOffsets: [VkOffset3D(rect.x, rect.y, 0),
                    VkOffset3D(rect.x + rect.w, rect.y + rect.h, 1)],
                dstSubresource: colour,
                dstOffsets: [VkOffset3D(0, rect.h, 0), VkOffset3D(rect.w, 0, 1)],
            };
            device_.cmdBlitImage(commands, scratchImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                bracket, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &flip, VkFilter.VK_FILTER_NEAREST);
            transition(*device_, commands, bracket, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                VK_ACCESS_SHADER_READ_BIT);

            const passes = passesOf(impl);
            VkImageView[16] views;
            if (passes.length + 1 > views.length)
                return VkResult.VK_ERROR_FEATURE_NOT_PRESENT;
            views[0] = images_[1].view;
            foreach (k, ref pass; passes)
            {
                const last = k + 1 == passes.length;
                auto program = programFor(pass.source, format, last);
                if (program is null)
                    return VkResult.VK_ERROR_FEATURE_NOT_PRESENT;
                VkImageView[8] sources;
                if (pass.inputs.length + 1 > sources.length)
                    return VkResult.VK_ERROR_FEATURE_NOT_PRESENT;
                sources[0] = views[sourceOf(pass, k)];
                foreach (j, input; pass.inputs)
                    sources[1 + j] = views[input];
                const sourceCount = 1 + pass.inputs.length;
                if (!last)
                {
                    const d = pass.downscale ? pass.downscale : 1;
                    const out_ = VkExtent2D(w / d ? w / d : 1, h / d ? h / d : 1);
                    r = acquire(2 + k, format, out_);
                    if (r < 0)
                        return r;
                    auto image = &images_[2 + k];
                    transition(*device_, commands, image.handle, VK_IMAGE_LAYOUT_UNDEFINED,
                        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                        0, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                        VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);
                    begin(commands, image.view, out_, clear: true);
                    const whole = VkRect2D(VkOffset2D(0, 0), out_);
                    r = draw(commands, slot, *program, sources[0 .. sourceCount], buffers,
                        rec.params, Supplied([float(out_.width), float(out_.height)],
                        [float(cells.width), float(cells.height)], time), whole, upright: false);
                    end(commands);
                    if (r < 0)
                        return r;
                    transition(*device_, commands, image.handle, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                        VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                        VK_ACCESS_SHADER_READ_BIT);
                    views[k + 1] = image.view;
                    continue;
                }
                // The last pass: onto the target, after the canvas's writes.
                transition(*device_, commands, targetImage, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);
                begin(commands, target, drawn, clear: false);
                const area = VkRect2D(VkOffset2D(rect.x, rect.y), VkExtent2D(w, h));
                r = draw(commands, slot, *program, sources[0 .. sourceCount], buffers, rec.params,
                    Supplied([float(w), float(h)], [float(cells.width), float(cells.height)], time),
                    area, upright: true);
                end(commands);
                if (r < 0)
                    return r;
            }
        }
        return VkResult.VK_SUCCESS;
    }

    /// Destroys everything the chain made; the device has finished with it.
    void destroy() @system
    {
        if (device_ is null)
            return;
        foreach (ref p; programs_)
            destroyProgram(p);
        programs_ = null;
        foreach (ref image; images_)
            image.destroy(*device_, *memory_);
        images_ = null;
        foreach (ref p; pools_)
            device_.destroyDescriptorPool(device_.device, p.pool, null);
        pools_ = null;
        if (linear_ !is null)
            device_.destroySampler(device_.device, linear_, null);
        if (vertex_ !is null)
            device_.destroyShaderModule(device_.device, vertex_, null);
        linear_ = null;
        vertex_ = null;
        device_ = null;
    }

    /// How many pass pipelines the chain has made.
    size_t programCount() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (ref p; programs_)
            n += !p.failed;
        return n;
    }

    // ── internals ──────────────────────────────────────────────────────────

    private VkResult acquire(size_t role, VkFormat format, VkExtent2D extent) @system
    {
        if (images_.length <= role)
            images_.length = role + 1;
        auto image = &images_[role];
        // The scratch target only has to be large enough; the others are
        // sampled whole, so they are exactly the size asked for.
        const fits = role == 0
            ? image.extent.width >= extent.width && image.extent.height >= extent.height
            : image.extent == extent;
        if (image.handle !is null && image.format == format && fits)
            return VkResult.VK_SUCCESS;
        if (image.handle !is null)
            retire_(*image);
        with (VkImageUsageFlagBits)
        {
            auto made = GpuImage.create(*image, *device_, *memory_, format, extent,
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT
                | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
            if (made.hasError)
                return made.error;
        }
        return VkResult.VK_SUCCESS;
    }

    private Program* programFor(string source, VkFormat format, bool composite) @system
    {
        foreach (ref p; programs_)
            if (p.key is source.ptr && p.length == source.length && p.format == format
                && p.composite == composite)
                return p.failed ? null : &p;
        programs_ ~= Program(source.ptr, source.length, format, composite);
        auto p = &programs_[$ - 1];
        p.failed = !makeProgram(*p, source);
        if (p.failed)
            destroyProgram(*p);
        return p.failed ? null : p;
    }

    private bool makeProgram(ref Program p, string source) @system
    {
        // An artifact is bytes the toolkit never looked into; its storage
        // is not promised to be word-aligned, so it is copied into words.
        if (source.length % 4 != 0)
            return false;
        const words = spirvWords(source);
        if (!readFragmentInterface(words, p.fi))
            return false;
        // The vertex stage writes the two varyings at 0 and 1; a module
        // reading anything else at those names is not one of these passes.
        const uvAt = p.fi.inputLocation("fragTexCoord"), colourAt = p.fi.inputLocation("fragColor");
        if ((uvAt != -1 && uvAt != 0) || (colourAt != -1 && colourAt != 1))
            return false;

        auto moduleInfo = vkInfo(VkShaderModuleCreateInfo(codeSize: words.length * uint.sizeof,
            pCode: words.ptr));
        if (device_.createShaderModule(device_.device, &moduleInfo, null, &p.fragment) < 0)
            return false;

        VkDescriptorSetLayoutBinding[16] bindings;
        if (p.fi.bindings.length > bindings.length)
            return false;
        foreach (i, ref b; p.fi.bindings)
            bindings[i] = VkDescriptorSetLayoutBinding(binding: b.binding,
                descriptorType: descriptorType(b.kind), descriptorCount: 1,
                stageFlags: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT);
        auto setInfo = vkInfo(VkDescriptorSetLayoutCreateInfo(
            bindingCount: cast(uint) p.fi.bindings.length, pBindings: bindings.ptr));
        if (device_.createDescriptorSetLayout(device_.device, &setInfo, null, &p.setLayout) < 0)
            return false;
        auto push = VkPushConstantRange(stageFlags: VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
            offset: 0, size: effectViewBytes);
        auto layoutInfo = vkInfo(VkPipelineLayoutCreateInfo(setLayoutCount: 1,
            pSetLayouts: &p.setLayout, pushConstantRangeCount: 1, pPushConstantRanges: &push));
        if (device_.createPipelineLayout(device_.device, &layoutInfo, null, &p.layout) < 0)
            return false;

        auto entry = p.fi.entry.toTempStringz;
        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0] = vkInfo(VkPipelineShaderStageCreateInfo(
            stage: VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT, pName: "effectVertex".ptr));
        stages[1] = vkInfo(VkPipelineShaderStageCreateInfo(
            stage: VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT, pName: entry.ptr));
        __traits(getMember, stages[0], "module") = vertex_;
        __traits(getMember, stages[1], "module") = p.fragment;
        auto vertexInput = vkInfo(VkPipelineVertexInputStateCreateInfo());
        auto assembly = vkInfo(VkPipelineInputAssemblyStateCreateInfo(
            topology: VkPrimitiveTopology.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP));
        auto viewportState = vkInfo(VkPipelineViewportStateCreateInfo(viewportCount: 1,
            scissorCount: 1));
        auto raster = vkInfo(VkPipelineRasterizationStateCreateInfo(
            polygonMode: VkPolygonMode.VK_POLYGON_MODE_FILL,
            cullMode: VkCullModeFlagBits.VK_CULL_MODE_NONE,
            frontFace: VkFrontFace.VK_FRONT_FACE_CLOCKWISE,
            lineWidth: 1.0f));
        auto multisample = vkInfo(VkPipelineMultisampleStateCreateInfo(
            rasterizationSamples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT));
        // A pass into an image of the chain replaces it; the last one blends
        // over the target as raylib's default blend does: straight alpha.
        auto blendAttachment = VkPipelineColorBlendAttachmentState(
            blendEnable: p.composite ? VK_TRUE : VK_FALSE,
            srcColorBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_SRC_ALPHA,
            dstColorBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            colorBlendOp: VkBlendOp.VK_BLEND_OP_ADD,
            srcAlphaBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE,
            dstAlphaBlendFactor: VkBlendFactor.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            alphaBlendOp: VkBlendOp.VK_BLEND_OP_ADD,
            colorWriteMask: VkColorComponentFlagBits.VK_COLOR_COMPONENT_R_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_G_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_B_BIT
                | VkColorComponentFlagBits.VK_COLOR_COMPONENT_A_BIT);
        auto blend = vkInfo(VkPipelineColorBlendStateCreateInfo(attachmentCount: 1,
            pAttachments: &blendAttachment));
        VkDynamicState[2] dynamicStates = [VkDynamicState.VK_DYNAMIC_STATE_VIEWPORT,
            VkDynamicState.VK_DYNAMIC_STATE_SCISSOR];
        auto dynamic = vkInfo(VkPipelineDynamicStateCreateInfo(
            dynamicStateCount: dynamicStates.length, pDynamicStates: dynamicStates.ptr));
        auto colourFormat = p.format;
        auto rendering = vkInfo(VkPipelineRenderingCreateInfo(colorAttachmentCount: 1,
            pColorAttachmentFormats: &colourFormat));
        auto info = vkInfo(VkGraphicsPipelineCreateInfo(
            pNext: &rendering,
            stageCount: stages.length,
            pStages: stages.ptr,
            pVertexInputState: &vertexInput,
            pInputAssemblyState: &assembly,
            pViewportState: &viewportState,
            pRasterizationState: &raster,
            pMultisampleState: &multisample,
            pColorBlendState: &blend,
            pDynamicState: &dynamic,
            layout: p.layout));
        return device_.createGraphicsPipelines(device_.device, facts_.pipelineCache, 1, &info,
            null, &p.pipeline) >= 0;
    }

    private void destroyProgram(ref Program p) @system
    {
        if (p.pipeline !is null)
            device_.destroyPipeline(device_.device, p.pipeline, null);
        if (p.layout !is null)
            device_.destroyPipelineLayout(device_.device, p.layout, null);
        if (p.setLayout !is null)
            device_.destroyDescriptorSetLayout(device_.device, p.setLayout, null);
        if (p.fragment !is null)
            device_.destroyShaderModule(device_.device, p.fragment, null);
        p.pipeline = null;
        p.layout = null;
        p.setLayout = null;
        p.fragment = null;
    }

    private static VkDescriptorType descriptorType(DescriptorKind kind) @safe pure nothrow @nogc
    {
        final switch (kind)
        {
            case DescriptorKind.sampler: return VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER;
            case DescriptorKind.sampledImage: return VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
            case DescriptorKind.uniformBlock: return VkDescriptorType.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        }
    }

    // A descriptor set of `p`'s layout from `slot`'s pools, a new pool
    // made when they are full.
    private VkResult allocateSet(uint slot, ref Program p, out VkDescriptorSet set) @system
    {
        foreach (attempt; 0 .. 2)
        {
            foreach_reverse (ref pool; pools_)
            {
                if (pool.slot != slot)
                    continue;
                auto info = vkInfo(VkDescriptorSetAllocateInfo(descriptorPool: pool.pool,
                    descriptorSetCount: 1, pSetLayouts: &p.setLayout));
                const r = device_.allocateDescriptorSets(device_.device, &info, &set);
                if (r >= 0)
                    return r;
                break; // the newest pool of the slot is full
            }
            enum uint sets = 32;
            VkDescriptorPoolSize[3] sizes = [
                VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER, sets),
                VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 4 * sets),
                VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, sets),
            ];
            auto poolInfo = vkInfo(VkDescriptorPoolCreateInfo(maxSets: sets,
                poolSizeCount: sizes.length, pPoolSizes: sizes.ptr));
            VkDescriptorPool made;
            const r = device_.createDescriptorPool(device_.device, &poolInfo, null, &made);
            if (r < 0)
                return r;
            pools_ ~= SlotPool(slot, made);
        }
        return VkResult.VK_ERROR_OUT_OF_POOL_MEMORY;
    }

    // One pass's draw, in a rendering already begun: its images, its block,
    // the pipeline, and the four corners of `area`.
    private VkResult draw(VkCommandBuffer commands, uint slot, ref Program p,
        scope VkImageView[] sources, ref FrameBuffers!B buffers, in EffectParam[] params,
        in Supplied supplied, VkRect2D area, bool upright) @system
    {
        VkDescriptorSet set;
        auto r = allocateSet(slot, p, set);
        if (r < 0)
            return r;
        BufferSlice block;
        if (p.fi.blockBinding != uint.max)
        {
            auto slice = buffers.allocate(slot, p.fi.blockSize, 256);
            if (slice.hasError)
                return slice.error;
            block = slice.value;
            fillUniformBlock(p.fi, block.host[0 .. p.fi.blockSize], params, supplied);
            auto flushed = memory_.flush(block.region);
            if (flushed.hasError)
                return flushed.error;
        }
        VkWriteDescriptorSet[16] writes;
        VkDescriptorImageInfo[16] images;
        VkDescriptorBufferInfo bufferInfo;
        foreach (i, ref b; p.fi.bindings)
        {
            writes[i] = vkInfo(VkWriteDescriptorSet(dstSet: set, dstBinding: b.binding,
                descriptorCount: 1, descriptorType: descriptorType(b.kind)));
            final switch (b.kind)
            {
                case DescriptorKind.sampler:
                    images[i] = VkDescriptorImageInfo(sampler: linear_);
                    writes[i].pImageInfo = &images[i];
                    break;
                case DescriptorKind.sampledImage:
                    images[i] = VkDescriptorImageInfo(imageView: sources[textureIndex(b.name, sources.length)],
                        imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
                    writes[i].pImageInfo = &images[i];
                    break;
                case DescriptorKind.uniformBlock:
                    bufferInfo = VkDescriptorBufferInfo(buffer: block.buffer, offset: block.offset,
                        range: p.fi.blockSize);
                    writes[i].pBufferInfo = &bufferInfo;
                    break;
            }
        }
        device_.updateDescriptorSets(device_.device, cast(uint) p.fi.bindings.length, writes.ptr, 0,
            null);

        device_.cmdBindPipeline(commands, VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            p.pipeline);
        device_.cmdBindDescriptorSets(commands, VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            p.layout, 0, 1, &set, 0, null);
        ubyte[effectViewBytes] push;
        writeLayout!(EffectView, Rule.std430)(EffectView(upright: upright ? 1 : 0), push[]);
        device_.cmdPushConstants(commands, p.layout, VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
            0, push.length, push.ptr);
        auto viewport = VkViewport(x: area.offset.x, y: area.offset.y, width: area.extent.width,
            height: area.extent.height, minDepth: 0, maxDepth: 1);
        device_.cmdSetViewport(commands, 0, 1, &viewport);
        device_.cmdSetScissor(commands, 0, 1, &area);
        device_.cmdDraw(commands, 4, 1, 0, 0);
        return VkResult.VK_SUCCESS;
    }

    private void begin(VkCommandBuffer commands, VkImageView view, VkExtent2D extent, bool clear)
        @system
    {
        VkClearValue transparent;
        auto colour = vkInfo(VkRenderingAttachmentInfo(
            imageView: view,
            imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            loadOp: clear ? VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR
                : VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_LOAD,
            storeOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE,
            clearValue: transparent));
        auto rendering = vkInfo(VkRenderingInfo(renderArea: VkRect2D(VkOffset2D(0, 0), extent),
            layerCount: 1, colorAttachmentCount: 1, pColorAttachments: &colour));
        if (device_.cmdBeginRendering !is null)
            device_.cmdBeginRendering(commands, &rendering);
        else
            device_.cmdBeginRenderingKHR(commands, &rendering);
    }

    private void end(VkCommandBuffer commands) @system
    {
        if (device_.cmdEndRendering !is null)
            device_.cmdEndRendering(commands);
        else
            device_.cmdEndRenderingKHR(commands);
    }
}

/// The source a pass binds as image `name` (`texture0`, `texture1`, …):
/// its number, or the bracket's for a name past the ones it reads.
size_t textureIndex(scope const(char)[] name, size_t count) @safe pure nothrow @nogc
{
    enum prefix = "texture";
    if (name.length <= prefix.length || name[0 .. prefix.length] != prefix)
        return 0;
    size_t n;
    foreach (c; name[prefix.length .. $])
    {
        if (c < '0' || c > '9')
            return 0;
        n = n * 10 + (c - '0');
    }
    return n < count ? n : 0;
}

@("ui_vulkan.effect_chain.textureIndex")
@safe pure nothrow @nogc unittest
{
    assert(textureIndex("texture0", 2) == 0 && textureIndex("texture1", 2) == 1);
    assert(textureIndex("texture2", 2) == 0, "not bound: the bracket");
    assert(textureIndex("sampler", 2) == 0 && textureIndex("textureX", 2) == 0);
}

@("ui_vulkan.effect_chain.fillsTheBlockByName")
@safe pure nothrow unittest
{
    import sparkles.ui.crt : CrtEffect;
    import sparkles.ui.effect : EffectRegistry, generatedEffect;

    // The CRT's tube: the chain's values under their names, the record's
    // parameters by theirs, in `std140` places.
    FragmentInterface fi;
    {
        assert(readFragmentInterface(spirvWords(generatedEffect!"crtTube"(vulkan13Backend)), fi));
    }
    EffectRegistry reg;
    const id = reg.register(CrtEffect.effectRecord());
    CrtEffect crt;
    crt.curvature = 0.25f;
    crt.writeParams(reg, id, 800, 600, 100, 50);
    auto block = new ubyte[fi.blockSize];
    fillUniformBlock(fi, block, reg.lookup(id).params, Supplied([800, 600], [80, 30], 1.5f));

    float at(string name, size_t component = 0)
    {
        foreach (ref m; fi.members)
            if (m.name == name)
            {
                uint bits;
                foreach (b; 0 .. 4)
                    bits |= block[m.offset + component * 4 + b] << (8 * b);
                return (() @trusted => *cast(float*) &bits)();
            }
        assert(false, name);
    }
    assert(at("colDiffuse", 0) == 1 && at("colDiffuse", 3) == 1, "raylib's white");
    assert(at("uResolution", 0) == 800 && at("uResolution", 1) == 600);
    assert(at("uTime") == 1.5f);
    assert(at("uCurvature") == 0.25f);
    assert(at("mouse", 0) == 100 && at("mouse", 1) == 550, "Y up, as the shader wants");
}

@("ui_vulkan.effect_chain.passesOfAOnePassEffect")
@safe pure nothrow unittest
{
    auto one = EffectImpl(vulkan13Backend, "spirv");
    const passes = passesOf(&one);
    assert(passes.length == 1 && passes[0].source == "spirv" && passes[0].from == 0);
    assert(sourceOf(EffectPass("x"), 2) == 2, "the previous pass's output");
    assert(sourceOf(EffectPass("x", from: 0), 2) == 0);
}
