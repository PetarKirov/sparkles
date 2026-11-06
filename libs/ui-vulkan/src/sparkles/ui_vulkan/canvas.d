/**
The Vulkan canvas: the toolkit's drawing operations recorded into a command
buffer and a target image its host supplies (`UVK1`–`UVK4`).

$(LREF VulkanCanvas.beginFrame) opens a frame on a target; every canvas method
appends quad records through the batcher of `painter.d`; and
$(LREF VulkanCanvas.endFrame) records the frame: the uploads it needs and
their barriers, the target's transition into the attachment layout, one
rendering pass that clears to the ground colour and draws every record in
order, and the transition to the layout the host named. The host submits the
command buffer, waiting on the image's acquire semaphore at the
colour-attachment output stage and signalling the slot's fence, and presents.

What lives how long (`UVK26`): the pipelines, samplers and cached images live
on the device for as long as the canvas; framebuffers belong to a target and
are rebuilt when its format or extent changes, or when the host says its views
are gone. Instances and staged uploads live in the frame slot's arena
(`UVK28`), reused once the host begins that slot again — the host only does so
after the slot's fence has signalled. A resource released while a frame in
flight may still read it is destroyed once every such frame has completed
(`UVK31`).
*/
module sparkles.ui_vulkan.canvas;

import sparkles.base.expected : err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.profiling.zones : cpuZone;
import sparkles.shaders : v2, v4, vec4;
import sparkles.shaders.layout : Rule, writeLayout;
import sparkles.ui.canvas : isCanvas;
import sparkles.ui.geometry : Size;
import sparkles.ui.image : ImageHandle, ImageRegistry;
import sparkles.ui.style : TypeStep;
import sparkles.ui_vulkan.frame_buffers : BufferSlice, FrameBuffers;
import sparkles.ui_vulkan.glyph_atlas : AtlasGlyph, AtlasOutcome, coverageKey, DirtyRegion, GlyphAtlas,
    GlyphKey, hasColourGlyphs;
import sparkles.ui_vulkan.raster_batch : RasterTile;
import sparkles.ui_vulkan.coverage_geometry : CoverageMode, CoverageWork;
import sparkles.ui_vulkan.painter;
import sparkles.ui_vulkan.prepared_runs : PreparedRuns;
import sparkles.ui_vulkan.pipelines;
import sparkles.ui_vulkan.resources : GpuImage;
import sparkles.ui.pixel_geometry : ScissorBox;
import sparkles.ui_vulkan.shading : Binding, CanvasView, Instance, srgbToLinear;
import sparkles.ui_vulkan.text_rendering : Hinting, Loupe, TextRendering;
import sparkles.ui_vulkan.upload : transition, Uploads;
import sparkles.font : axes, Colour, Face, Ppem, Tag, UserCoordinate;
import sparkles.font.cluster_shaping : ClusterDirection;
import sparkles.vulkan;

/// The space a canvas composites in (`UVK6`, `UVX6`).
enum BlendSpace : ubyte
{
    gamma,  /// premultiplied over, in the target's stored encoding
    linear, /// in linear light: not implemented, so creating a canvas with it fails
}

/// What a canvas is created with.
struct CanvasConfig
{
    BlendSpace blendSpace;           ///
    uint frameSlots = 2;             /// the host's frames in flight
    ulong frameArenaBytes = 1 << 20; /// each slot's first arena range
    ulong uploadBudget = 16 << 20;   /// bytes of image uploads per frame (`UVK29`)
    bool baselineShaders;           /// diagnostic: Vulkan 1.1 shaders on newer devices
    bool forceRenderPass;           /// diagnostic: use the render-pass path
    bool suppressPipelineFeedback;  /// diagnostic: omit creation-feedback structures
}

/// The image a frame is drawn into, as its host hands it over (`UVK3`).
struct CanvasTarget
{
    VkImage image;         ///
    VkImageView view;      /// a colour view of it
    VkFormat format;       ///
    VkExtent2D extent;     ///
    /// How the image was created: an imageless framebuffer names it.
    VkImageUsageFlags usage = VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    /// The layout it is in; `UNDEFINED` discards what it held.
    VkImageLayout initialLayout = VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED;
    /// The layout to leave it in.
    VkImageLayout finalLayout = VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    /**
    Quarter turns clockwise the presentation engine gives the image on its
    way to the display, 0–3: a swapchain created with a rotated
    `preTransform` (a turned Android panel) keeps the panel's orientation
    and is drawn into pre-rotated (`UVK39`). Everything is still placed in
    display pixels; `extent` stays the image's.
    */
    uint turn;
    /**
    The image's alpha reaches the compositor (a swapchain composited
    premultiplied): the frame starts transparent rather than at the ground,
    and what is not drawn shows what lies behind the window (`UVK42`). The
    ground is still the background text is composited against.
    */
    bool transparent;
    /**
    The part of the image the frame fills, from its top-left corner, in
    image pixels; empty for all of it. An image larger than the window
    (a swapchain kept through a resize, its rest cropped away by the
    compositor) is drawn only where it shows (`UVK43`).
    */
    VkExtent2D drawn;
}

/// The part of `target` a frame fills: `drawn`, or the whole image.
VkExtent2D drawnExtent(in CanvasTarget target) @safe pure nothrow @nogc
    => target.drawn.width && target.drawn.height ? target.drawn : target.extent;

/// The display's size for `target`: its drawn extent, sides swapped by a
/// quarter or three-quarter turn (`UVK39`).
VkExtent2D displayExtent(in CanvasTarget target) @safe pure nothrow @nogc
{
    const e = drawnExtent(target);
    return target.turn % 2 ? VkExtent2D(e.height, e.width) : e;
}

/// Display rectangle `r` on a target turned `turn` quarter turns from a
/// display `w`×`h` pixels (`UVK39`).
ScissorBox turnedBox(in ScissorBox r, int w, int h, uint turn) @safe pure nothrow @nogc
{
    switch (turn % 4)
    {
        case 1: return ScissorBox(h - r.y - r.h, r.x, r.h, r.w);
        case 2: return ScissorBox(w - r.x - r.w, h - r.y - r.h, r.w, r.h);
        case 3: return ScissorBox(r.y, w - r.x - r.w, r.h, r.w);
        default: return r;
    }
}

///
@("ui_vulkan.canvas.turnedBox")
@safe pure nothrow @nogc unittest
{
    // A 10×4 box at (2, 3) on an 80×40 display, on the target of each turn.
    const r = ScissorBox(2, 3, 10, 4);
    assert(turnedBox(r, 80, 40, 0) == r);
    assert(turnedBox(r, 80, 40, 1) == ScissorBox(33, 2, 4, 10));
    assert(turnedBox(r, 80, 40, 2) == ScissorBox(68, 33, 10, 4));
    assert(turnedBox(r, 80, 40, 3) == ScissorBox(3, 68, 4, 10));
}

// The canvas's SPIR-V, generated by `shader-compile` before the build: SPIR-V
// 1.6 for a Vulkan 1.3 device, 1.3 for a 1.1 or 1.2 one.
private static immutable uint[] vertex13 = spirvWords(import(vertexEntry ~ ".vert.spv"));
private static immutable uint[] fragment13 = spirvWords(import(fragmentEntry ~ ".frag.spv"));
private static immutable uint[] vertex11 = spirvWords(import(vertexEntry ~ ".vk11.vert.spv"));
private static immutable uint[] fragment11 = spirvWords(import(fragmentEntry ~ ".vk11.frag.spv"));
private static immutable uint[] coverage13 = spirvWords(import("coverageFragment.frag.spv"));
private static immutable uint[] coverage11 = spirvWords(import("coverageFragment.vk11.frag.spv"));
private enum uint directCoverageFlag = 0x8000_0000;
static assert(vertex13[0] == spirvMagic && fragment13[0] == spirvMagic
    && vertex11[0] == spirvMagic && fragment11[0] == spirvMagic
    && coverage13[0] == spirvMagic && coverage11[0] == spirvMagic,
    "the canvas's SPIR-V is not little-endian SPIR-V — regenerate it");

/// How a canvas resolves the images its painter draws: through the canvas,
/// by a delegate, so the painter's type does not depend on the canvas's.
struct CanvasImages
{
    private ImageOutcome delegate(ImageHandle, out uint, out Size) @system resolve_;
    private GlyphOutcome delegate(in GlyphRequest, out GlyphQuad) @system glyph_;
    private const(TextMetrics)* metrics_;
    private GlyphOutcome delegate(in ClusterRequest, scope GlyphQuad[], out size_t) @system cluster_;
    private InterfaceStep delegate(int) @system step_;
    private bool delegate(int, bool, dchar) @system maps_;

    /// See `isImageSource`.
    ImageOutcome resolve(ImageHandle handle, out uint slot, out Size size) @system
        => resolve_(handle, slot, size);

    /// See `isGlyphSource`.
    GlyphOutcome resolveGlyph(in GlyphRequest r, out GlyphQuad quad) @system
        => glyph_ is null ? GlyphOutcome.noGlyph : glyph_(r, quad);

    /// ditto
    TextMetrics textMetrics() const @system => metrics_ is null ? TextMetrics.init : *metrics_;

    /// See `shapesClusters`.
    GlyphOutcome resolveCluster(in ClusterRequest r, scope GlyphQuad[] quads, out size_t count) @system
        => cluster_ is null ? GlyphOutcome.noGlyph : cluster_(r, quads, count);

    /// See `hasInterfaceFace`.
    InterfaceStep interfaceStep(int step) @system => step_ is null ? InterfaceStep.init : step_(step);

    /// ditto
    bool interfaceMaps(int step, bool bold, dchar cp) @system => maps_ !is null && maps_(step, bold, cp);
}

static assert(isGlyphSource!CanvasImages);
static assert(shapesClusters!CanvasImages);
static assert(hasInterfaceFace!CanvasImages);

// Whether the font library's shaping engine (HarfBuzz, its `engine`
// configuration) is linked: clusters are shaped where it is.
private enum bool canShape = __traits(compiles, { import sparkles.font.cluster_shaping : ClusterShaper; });

/// A face text falls back to where the cell font has no glyph, at its own size
/// (`UVX12`): its bytes, which outlive the canvas or the next `cellFont`.
struct FallbackFace
{
    const(ubyte)[] bytes; ///
    Ppem ppem;            ///
    uint faceIndex;       /// collection member, rather than always member zero
    ulong contentHash;    /// optional precomputed identity
}

/**
The canvas. Create it with $(LREF create); it is address-pinned and not
copyable from then on. `B` is the device-memory backend, real or fake.
*/
struct VulkanCanvas(B)
{
    private static struct CachedImage
    {
        ImageHandle handle; // `ImageHandle.init`: a free entry
        uint generation;
        const(ImageRegistry)* registry;
        GpuImage image;
    }

    private static struct Retired
    {
        GpuImage image;
        VkFramebuffer framebuffer;
        ulong needed; // every frame up to this serial must have completed
    }

    private static struct TargetFramebuffer
    {
        VkImageView view; // null for an imageless one
        VkFormat format;
        VkExtent2D extent;
        VkFramebuffer framebuffer;
    }

    private static struct SlotPool
    {
        uint slot;
        VkDescriptorPool pool;
        uint used;
    }

    private static struct FrameSet
    {
        BoundImages images;
        VkDescriptorSet set;
    }

    private enum uint setsPerPool = 64;

    private DeviceCommands* device_;
    private DeviceMemory!B* memory_;
    private DeviceFacts facts_;
    private CanvasConfig config_;
    private const(ImageRegistry)* registry_;
    private Pipelines pipelines_;
    private FrameArena!B arena_;
    private FrameBuffers!B buffers_;
    private Uploads!B uploads_;
    private GpuImage placeholder_;
    private bool placeholderReady_, placeholderStaged_;
    private UniqueBuffer!CachedImage images_;
    private UniqueBuffer!Retired retired_;
    private UniqueBuffer!TargetFramebuffer framebuffers_;
    private UniqueBuffer!SlotPool pools_;
    private UniqueBuffer!FrameSet frameSets_;
    private UniqueBuffer!ulong inFlight_; // per slot: the serial in flight there, or 0
    private ulong serial_ = 1;
    private Painter!CanvasImages painter_;

    // How text is rendered, and the loupe drawn over the frame.
    private TextRendering textRendering_;
    private TextRendering specimenRendering_;
    private Loupe loupe_;

    // The cell font text draws in, and its glyphs (`UVK18`; interim, `UVX12`).
    private GlyphAtlas atlas_;
    private CellFace[FaceStyle.max + 1] faces_; // by `FaceStyle`; a missing style draws regular
    private CellFace[] fallbacks_; // tried in order where the styled face has no glyph
    private TextMetrics textMetrics_;
    private uint faceSerial_;
    private CellFace[FaceStyle.max + 1] specimenFaces_;
    private CellFace[] specimenFallbacks_;
    private TextMetrics specimenMetrics_;
    private FrameMetrics savedGrid_;
    private bool specimenActive_;
    private uint specimenFallbackGlyphs_;
    private uint specimenGridFallbacks_;
    // The interface face (`UVK20`): its regular and bold faces at each type
    // step, and each step's box and baseline.
    private CellFace[2][TypeStep.max + 1] interfaceFaces_;
    private InterfaceStep[TypeStep.max + 1] interfaceSteps_;
    private UniqueBuffer!GpuImage[2] atlasImages_; // the coverage sheet's pages, the colour sheet's
    private UniqueBuffer!ulong[2] atlasGenerations_;
    private Pipelines coveragePipelines_;
    private bool coveragePipelinesReady_;
    private struct DirectGlyph
    {
        AtlasGlyph glyph;
        vec4 metadata;
    }
    private uint[GlyphKey] directGlyphs_;
    private UniqueBuffer!DirectGlyph directGlyphRecords_;
    private UniqueBuffer!vec4 geometryEdges_;
    private UniqueBuffer!GpuImage geometryImages_;
    // Shapers by face serial, made on demand (`ShaperSlot`).
    static if (canShape)
    {
        private ShaperSlot[16] shapers_;
        // Sized to hold a screenful of distinct clusters: text-lab's two
        // specimen panels overflow 256, and then shape every cluster again
        // each frame (`shape` zone on 117 of 120 frames; 31 M instructions a
        // frame against 27 M at 512). An entry is ~3 KB, its glyphs inline.
        private PreparedRuns!512 preparedRuns_;
        // Interface runs, apart: a screen of labels must not evict the cell
        // font's shaped clusters, nor they its labels.
        private PreparedRuns!256 interfaceRuns_;
        private bool preparingGlyphs_;
        private uint rasterWorkers_ = 2;
        private CoverageMode coverageMode_;
        private bool profileCoverage_;
    }

    private bool inFrame_, lost_;
    // A hinting change asked for mid-frame: the atlas starts over at the
    // next frame, not under the quads this one already recorded.
    private bool atlasStale_;
    // The frame's origin in the target: where pixel coordinates, the
    // loupe's among them, start.
    private int originX_, originY_;
    private CanvasTarget target_;
    private VkCommandBuffer commands_;
    private uint slot_;
    private RgbColor ground_;
    private ulong uploaded_;
    private ulong imageUploads_;
    private VkResult frameError_ = VkResult.VK_SUCCESS;

    @disable this(this);

    /**
    A canvas on `device`, its memory from `memory` (`UVK27`), both of which,
    with `registry`, must outlive it. Fails with `VK_ERROR_FEATURE_NOT_PRESENT`
    for a blend space other than `gamma` (`UVK6`) or a device below Vulkan 1.1,
    for which there is no shader profile (`UVK2`); otherwise with the driver's
    result, leaving nothing created.
    */
    static VkExpected!() create(out VulkanCanvas c, ref DeviceCommands device,
        ref DeviceMemory!B memory, DeviceFacts facts, in CanvasConfig config = CanvasConfig.init,
        const(ImageRegistry)* registry = null) @system
    {
        if (config.blendSpace != BlendSpace.gamma || config.frameSlots == 0
            || facts.apiVersion < apiVersion11)
            return err!void(VkResult.VK_ERROR_FEATURE_NOT_PRESENT);
        c.device_ = &device;
        c.memory_ = &memory;
        c.facts_ = facts;
        if (config.forceRenderPass) c.facts_.dynamicRendering = false;
        c.facts_.suppressFeedback = config.suppressPipelineFeedback;
        c.config_ = config;
        c.registry_ = registry;
        c.painter_.images = CanvasImages(&c.resolveImage, &c.resolveGlyph, &c.textMetrics_, &c.resolveCluster,
            &c.interfaceStep, &c.interfaceMaps);
        foreach (_; 0 .. config.frameSlots)
            c.inFlight_.put(0);
        auto made = c.createAll();
        if (made.hasError)
            c.destroy();
        return made;
    }

    private VkExpected!() createAll() @system
    {
        auto made = Pipelines.create(pipelines_, *device_, facts_,
            modernShaders ? vertex13 : vertex11, modernShaders ? fragment13 : fragment11);
        if (made.hasError)
            return made;
        enum usage = VkBufferUsageFlagBits.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
            | VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        // What a buffer over the arena's ranges needs of their memory — the
        // types it can live in, its alignment, its rounded size — asked of
        // one such buffer before any memory is chosen: Adreno's refuse the
        // host-visible memory a desktop driver accepts (`UVK28`).
        VkMemoryRequirements needs;
        {
            auto info = vkInfo(VkBufferCreateInfo(size: config_.frameArenaBytes, usage: usage,
                sharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE));
            VkBuffer probe;
            auto r = device_.createBuffer(device_.device, &info, null, &probe);
            if (r < 0)
                return err!void(r);
            device_.getBufferMemoryRequirements(device_.device, probe, &needs);
            device_.destroyBuffer(device_.device, probe, null);
        }
        made = FrameArena!B.create(arena_, *memory_, config_.frameSlots, needs.size,
            typeBits: needs.memoryTypeBits, alignment: needs.alignment);
        if (made.hasError)
            return made;
        made = FrameBuffers!B.create(buffers_, *device_, arena_, config_.frameSlots, usage);
        if (made.hasError)
            return made;
        uploads_ = Uploads!B(buffers_, *memory_);
        // What an unbound image reads: one transparent texel.
        return GpuImage.create(placeholder_, *device_, *memory_, VkFormat.VK_FORMAT_R8G8B8A8_UNORM,
            VkExtent2D(1, 1), VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    }

    /**
    Opens a frame (`UVK3`): `commands` is recording, `slot`'s previous frame
    has completed, and the frame is drawn into `target`, cleared to `ground`,
    with cells mapped to pixels by `metrics`.
    */
    void beginFrame(CanvasTarget target, VkCommandBuffer commands, uint slot,
        in FrameMetrics metrics, RgbColor ground) @system
    in (!inFrame_, "a frame is already open")
    in (slot < config_.frameSlots, "no such frame slot")
    {
        inFrame_ = true;
        frameError_ = VkResult.VK_SUCCESS;
        uploaded_ = 0;
        target_ = target;
        commands_ = commands;
        slot_ = slot;
        ground_ = ground;
        originX_ = metrics.originX;
        originY_ = metrics.originY;
        specimenFallbackGlyphs_ = specimenGridFallbacks_ = 0;
        directGlyphs_ = null;
        directGlyphRecords_.clear(false);
        geometryEdges_.clear(false);

        // The host reuses a slot only after its fence has signalled.
        inFlight_[][slot] = 0;
        destroyRetired();
        evictGone();
        // A full atlas, or one a hinting change made stale, starts over:
        // what this frame draws rasterizes again.
        if (atlas_.overflowed || atlasStale_)
            atlas_.reset();
        atlas_.beginFrame();
        atlasStale_ = false;
        buffers_.reset(slot);
        foreach (ref p; pools_[])
            if (p.slot == slot)
            {
                device_.resetDescriptorPool(device_.device, p.pool, 0);
                p.used = 0;
            }
        frameSets_.clear();
        retireFramebuffersNotFor(target);

        if (!placeholderReady_ && !lost_)
        {
            static immutable ubyte[4] transparent = 0;
            auto staged = uploads_.stage(slot, placeholder_.handle,
                VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED, transparent[], 4, VkOffset2D(0, 0),
                VkExtent2D(1, 1));
            if (staged.hasError)
                frameError_ = staged.error;
            placeholderStaged_ = !staged.hasError;
        }

        painter_.textRendering = textRendering_;
        const display = displayExtent(target);
        painter_.begin(Size(display.width, display.height), metrics);
        if (isSrgb(target.format))
            painter_.report.count(Degradation.srgbBlending);
    }

    /**
    Records the frame into the command buffer (`UVK4`) and returns its
    degradation report (`UVK16`). On exhausted device memory the frame is
    abandoned — nothing it recorded may be submitted — the caches are released
    (`UVK34`), and the error is `VK_ERROR_OUT_OF_DEVICE_MEMORY`. After a lost
    device every frame fails with `VK_ERROR_DEVICE_LOST` (`UVK33`).
    */
    VkExpected!FrameReport endFrame() @system
    in (inFrame_, "no frame is open")
    {
        inFrame_ = false;
        if (lost_)
            return err!FrameReport(VkResult.VK_ERROR_DEVICE_LOST);
        if (frameError_ != VkResult.VK_SUCCESS)
            return fail!FrameReport(frameError_);

        // Everything that can fail, before anything is recorded.
        auto format = pipelines_.forFormat(*device_, target_.format);
        if (format.hasError)
            return fail!FrameReport(format.error);
        VkFramebuffer framebuffer;
        if (!facts_.dynamicRendering)
        {
            const r = framebufferFor(format.value.renderPass, framebuffer);
            if (r < 0)
                return fail!FrameReport(r);
        }
        const instances = painter_.instances;
        BufferSlice vertices;
        if (instances.length)
        {
            const bytes = instances.length * Instance.sizeof;
            auto slice = buffers_.allocate(slot_, bytes, 16);
            if (slice.hasError)
                return fail!FrameReport(slice.error);
            vertices = slice.value;
            vertices.host[0 .. bytes] = (cast(const(ubyte)*) instances.ptr)[0 .. bytes];
            auto flushed = memory_.flush(vertices.region);
            if (flushed.hasError)
                return fail!FrameReport(flushed.error);
        }
        // The atlas's pages on the device, and what was rasterized into them
        // this frame, staged before the draws that read it.
        {
            auto zone = cpuZone!"atlas-upload"; // `PRF22`
            const r = stageAtlas();
            if (r < 0)
                return fail!FrameReport(r);
        }
        UniqueBuffer!VkDescriptorSet sets;
        {
            const r = stageGeometry();
            if (r < 0) return fail!FrameReport(r);
        }
        foreach (ref run; painter_.runs)
        {
            VkDescriptorSet set;
            const r = setFor(run.images, set);
            if (r < 0)
                return fail!FrameReport(r);
            sets.put(set);
        }

        // The uploads and their barriers, then the target into the
        // attachment layout, after whatever wrote it last (`UVK4`, `UVK30`).
        uploads_.record(*device_, commands_);
        transition(*device_, commands_, target_.image, target_.initialLayout,
            VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
            VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);

        beginPass(format.value.renderPass, framebuffer);
        device_.cmdBindPipeline(commands_, VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            format.value.pipeline);
        const drawn = drawnExtent(target_);
        auto viewport = VkViewport(x: 0, y: 0, width: drawn.width, height: drawn.height,
            minDepth: 0, maxDepth: 1);
        device_.cmdSetViewport(commands_, 0, 1, &viewport);
        ubyte[canvasViewBytes] push;
        const display = displayExtent(target_);
        writeLayout!(CanvasView, Rule.std430)(CanvasView(
            extent: v2(display.width, display.height),
            srgb: isSrgb(target_.format) ? 1 : 0, turn: target_.turn % 4), push[]);
        device_.cmdPushConstants(commands_, pipelines_.layout, canvasViewStages, 0, push.length,
            push.ptr);
        if (instances.length)
        {
            auto buffer = vertices.buffer;
            auto offset = vertices.offset;
            device_.cmdBindVertexBuffers(commands_, 0, 1, &buffer, &offset);
        }
        // The source is weighed by the blend constants: one paints, as
        // premultiplied source over destination (`UVK6`); zero erases
        // (`UVK41`). Set only where a run changes it.
        bool erasing = true;
        bool directBound;
        foreach (i, ref run; painter_.runs)
        {
            const direct = (run.images.coveragePage & directCoverageFlag) != 0;
            if (direct != directBound)
            {
                auto pipeline = direct ? coveragePipelines_.forFormat(*device_, target_.format).value.pipeline
                    : format.value.pipeline;
                device_.cmdBindPipeline(commands_, VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
                if (direct)
                    device_.cmdPushConstants(commands_, coveragePipelines_.layout, canvasViewStages,
                        0, push.length, push.ptr);
                directBound = direct;
            }
            if (i == 0 || run.erase != erasing)
            {
                erasing = run.erase;
                const float[4] weights = erasing ? [0.0f, 0, 0, 0] : [1.0f, 1, 1, 1];
                device_.cmdSetBlendConstants(commands_, weights.ptr);
            }
            const box = turnedBox(run.scissor, int(display.width), int(display.height), target_.turn);
            auto scissor = VkRect2D(VkOffset2D(box.x, box.y), VkExtent2D(box.w, box.h));
            device_.cmdSetScissor(commands_, 0, 1, &scissor);
            auto set = sets[][i];
            device_.cmdBindDescriptorSets(commands_,
                VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
                direct ? coveragePipelines_.layout : pipelines_.layout, 0, 1,
                &set, 0, null);
            device_.cmdDraw(commands_, 4, run.count, 0, run.first);
        }
        endPass();

        auto layout = VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkPipelineStageFlags written = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkAccessFlags writes = VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        recordLoupe(layout, written, writes);
        if (target_.finalLayout != layout)
        {
            VkPipelineStageFlags stage;
            VkAccessFlags access;
            readersOf(target_.finalLayout, stage, access);
            transition(*device_, commands_, target_.image, layout, target_.finalLayout, written, writes,
                stage, access);
        }

        if (placeholderStaged_)
            placeholderReady_ = true;
        inFlight_[][slot_] = serial_++;
        return ok!VkResult(painter_.report);
    }

    /**
    Releases every cached image no frame being recorded references, each
    destroyed once the frames in flight that read it have completed
    (`UVK31`, `UVK32`). For the host to call on memory pressure.
    */
    void releaseCaches() @system
    {
        static if (canShape)
        {
            preparedRuns_.clear();
            interfaceRuns_.clear();
        }
        foreach (i, ref e; images_[])
        {
            if (!e.handle.valid)
                continue;
            if (inFrame_ && boundThisFrame(cast(uint) i + 1))
                continue;
            retire(e.image);
            e = CachedImage.init;
        }
        // The glyph atlas too, between frames: its glyphs rasterize again as
        // they are drawn.
        if (!inFrame_)
        {
            foreach (ref image; geometryImages_[]) retire(image);
            geometryImages_.clear();
            foreach (ref sheet; atlasImages_)
            {
                foreach (ref page; sheet[])
                    retire(page);
                sheet.clear();
            }
            foreach (ref generations; atlasGenerations_) generations.clear();
            atlas_.reset();
        }
    }

    /**
    Binds the cell font text draws in (`UVK18`; interim, `UVX12`): its faces
    by `FaceStyle` — the regular one required, a missing style drawing in it —
    each `faces[s]`'s bytes outliving the canvas or the next call, at `ppem`
    pixels per em, placed in a cell by `metrics`. `fallbacks` are tried in order
    for a codepoint the styled face lacks, each at its own size; one with
    colour glyphs is tried first for a cluster that presents as an emoji. False,
    with text drawing nothing, when the regular face cannot be opened.
    */
    bool cellFont(const(ubyte)[][FaceStyle.max + 1] faces, Ppem ppem, in TextMetrics metrics,
        in FallbackFace[] fallbacks = null, uint faceIndex = 0,
        scope const(UserCoordinate)[] coordinates = null, scope const(uint)[] styleIndices = null) @system
    {
        textMetrics_ = TextMetrics.init;
        // Prune before returning, while replaced bytes still live. Shapers
        // whose exact borrowed storage remains bound retain their workspace.
        scope (exit) pruneShapers();
        // A face's glyphs keep their atlas entries across a size change;
        // other bytes are another face. Identity is the bytes' content,
        // not their address: the caller's bytes may die at the next call
        // and a different face be allocated where they lay, which a
        // pointer would call the same face.
        uint serialOf(in CellFace face, in CellFace was)
            => face.contentHash == was.contentHash && face.bytes.length == was.bytes.length
                && face.face.index == was.face.index
                ? was.serial : ++faceSerial_;
        CellFace[] opened;
        foreach (fb; fallbacks)
        {
            CellFace* previous;
            foreach (ref old; fallbacks_)
                if (old.bytes.ptr == fb.bytes.ptr && old.bytes.length == fb.bytes.length)
                {
                    previous = &old;
                    break;
                }
            auto face = CellFace.open(fb.bytes, fb.ppem, fb.faceIndex, null, previous, fb.contentHash);
            if (!face.bytes.length)
                continue;
            CellFace was;
            foreach (ref old; fallbacks_)
                if (old.contentHash == face.contentHash && old.bytes.length == fb.bytes.length)
                    was = old;
            face.serial = serialOf(face, was);
            opened ~= face;
        }
        fallbacks_ = opened;
        foreach (style, bytes; faces)
        {
            const index = style == FaceStyle.regular ? faceIndex
                : style - 1 < styleIndices.length ? styleIndices[style - 1] : 0;
            auto bound = CellFace.open(bytes, ppem, index,
                coordinates, &faces_[style]);
            if (!bound.bytes.length && style == FaceStyle.regular)
            {
                faces_[] = CellFace.init;
                return false;
            }
            bound.serial = serialOf(bound, faces_[style]);
            faces_[style] = bound;
        }
        textMetrics_ = metrics;
        textMetrics_.present = true;
        return true;
    }

    /// ditto, the regular face alone at a whole number of pixels per em
    bool cellFont(const(ubyte)[] regular, uint ppem, in TextMetrics metrics) @system
    {
        const(ubyte)[][FaceStyle.max + 1] faces;
        faces[FaceStyle.regular] = regular;
        const em = Ppem.fromInteger(ppem);
        return em.hasValue && cellFont(faces, em.value, metrics);
    }

    /**
    Binds the interface face (`UVK20`, design-system `GLY10`): `regular` and,
    where the family has one, `bold`, each's bytes outliving the canvas or the
    next call, drawn at each type step `stepPx[step]` pixels from ascender to
    descender — the rule the cell font's size names its line by. Interface
    runs (`FontRole.ui`, `FontRole.docs`) then draw in it, by its advances,
    shaped by the font library's engine. An empty `regular` unbinds it. False,
    with interface runs back in the cell font, when the regular face cannot be
    opened or no engine is linked to shape it.

    Without a `bold` file a variable `regular` with a weight axis draws bold
    runs at its `wght` 700 instance (or the axis's heaviest, if lighter) —
    shaped and advanced at that weight, its glyphs their own atlas entries —
    as the desktop's variable faces (Adwaita Sans, Android's Roboto) ship
    one file for every weight. A static face without a bold file draws bold
    as a doubled stroke.
    */
    bool interfaceFont(const(ubyte)[] regular, const(ubyte)[] bold,
        in int[TypeStep.max + 1] stepPx) @system
    {
        import sparkles.font : hhea, openFace;

        // Prune before returning, while replaced bytes still live.
        scope (exit) pruneShapers();
        CellFace[2][TypeStep.max + 1] opened;
        InterfaceStep[TypeStep.max + 1] steps;
        scope (exit)
        {
            interfaceFaces_ = opened;
            interfaceSteps_ = steps;
        }
        static if (!canShape)
            return false;
        else
        {
            const(ubyte)[][2] files = [regular, bold];
            // Bold on the regular face's weight axis, where it has no file.
            UserCoordinate[1] weight;
            const(UserCoordinate)[] styleCoordinates(size_t style)
                => style == 1 && !bold.length && regular.length ? weight[] : null;
            if (!bold.length && regular.length)
            {
                auto variable = openFace(regular);
                if (variable.hasValue && boldOnWeightAxis(variable.value, weight[0]))
                    files[1] = regular;
            }
            foreach (style, bytes; files)
            {
                auto parsed = bytes.length ? openFace(bytes) : typeof(openFace(bytes)).init;
                if (!bytes.length || parsed.hasError)
                {
                    if (style == 0)
                        return false;
                    continue;
                }
                const hh = hhea(parsed.value);
                const span = hh.hasValue ? long(hh.value.ascender) - hh.value.descender : 0;
                if (span <= 0)
                {
                    if (style == 0)
                        return false;
                    continue;
                }
                foreach (step, px; stepPx)
                {
                    const size = px < 1 ? 1 : px;
                    // The em whose ascender-to-descender span is `size` pixels.
                    const em = scaledPpem(Ppem.fromInteger(size).value, parsed.value.unitsPerEm,
                        cast(ulong) span);
                    // The first step parses the face; the others share it.
                    auto previous = step == 0 ? &interfaceFaces_[0][style] : &opened[0][style];
                    auto face = em.hasValue ? CellFace.open(bytes, em.value, 0,
                        styleCoordinates(style), previous) : CellFace.init;
                    if (!face.bytes.length)
                    {
                        if (style == 0)
                        {
                            opened = typeof(opened).init;
                            steps = typeof(steps).init;
                            return false;
                        }
                        // A bold face is all steps' or none's.
                        foreach (ref o; opened)
                            o[1] = CellFace.init;
                        break;
                    }
                    // A face's glyphs keep their atlas entries across a
                    // rebinding at another size; other content is another face.
                    const was = interfaceFaces_[0][style];
                    face.serial = step > 0 ? opened[0][style].serial
                        : was.bytes.length && was.contentHash == face.contentHash
                            && was.bytes.length == face.bytes.length ? was.serial : ++faceSerial_;
                    opened[step][style] = face;
                    if (style == 0)
                        steps[step] = InterfaceStep(true, size,
                            cast(int)((long(hh.value.ascender) * size + span / 2) / span));
                }
            }
            foreach (step, ref s; steps)
                s.bold = opened[step][1].bytes.length != 0;
            return true;
        }
    }

    /// The interface face at type step `step` (`UVK20`); not `present` where
    /// none is bound.
    InterfaceStep interfaceStep(int step) const @safe pure nothrow @nogc
        => step >= 0 && step < interfaceSteps_.length ? interfaceSteps_[step] : InterfaceStep.init;

    /// Whether the interface face at `step` — its bold face, for a bold run,
    /// where there is one — has a glyph for `cp`.
    bool interfaceMaps(int step, bool bold, dchar cp) @system
    {
        auto face = interfaceFace(step, bold);
        return face !is null && face.map.glyph(cp) != 0;
    }

    /**
    The width `text` takes in the interface face at `step`, in pixels, as
    `textRunIn` places it: what a host's measurer lays interface runs out by
    (`GLY10`). Negative where no interface face is drawn at that step.
    Measures without drawing, so it may be called outside a frame.
    */
    double interfaceWidthPx(scope const(char)[] text, int step, bool bold) @system
        => painter_.interfaceWidthPx(text, step, bold);

    /// Whether interface runs draw in the interface face (on by default):
    /// off, as for a target narrowed to no `proportionalText`, they draw in
    /// the cell font.
    void interfaceFaces(bool on) @safe pure nothrow @nogc
    {
        painter_.interfaceFaces = on;
    }

    // The face an interface run at `step` draws in, or null.
    private CellFace* interfaceFace(int step, bool bold) @safe pure nothrow @nogc return
    {
        if (step < 0 || step >= interfaceSteps_.length || !interfaceSteps_[step].present)
            return null;
        return bold && interfaceFaces_[step][1].bytes.length ? &interfaceFaces_[step][1]
            : &interfaceFaces_[step][0];
    }

    /**
    Prepares an exact specimen face independently of the interface font.
    Borrowed bytes must live until the next specimen binding. Updating only
    size or coordinates reuses the parsed face, content hash and hint scratch.
    */
    bool specimenFont(const(ubyte)[] bytes, uint index, Ppem size,
        scope const(UserCoordinate)[] coordinates, in TextMetrics metrics, ulong contentHash = 0,
        int lineHeight = 0, scope const(ubyte[][]) styles = null,
        scope const(uint)[] styleIndices = null, scope const(ulong)[] styleHashes = null,
        scope const(FallbackFace)[] extras = null) @system
    {
        assert(!specimenActive_);
        scope (exit) pruneShapers();
        auto bound = CellFace.open(bytes, size, index, coordinates, &specimenFaces_[0], contentHash);
        if (!bound.bytes.length)
            return false;
        const old = specimenFaces_[0];
        bound.serial = old.bytes.length && old.contentHash == bound.contentHash
            && old.face.index == bound.face.index ? old.serial : ++faceSerial_;
        specimenFaces_[0] = bound;
        foreach (i; 1 .. specimenFaces_.length)
        {
            auto previous = specimenFaces_[i];
            auto sibling = i - 1 < styles.length
                ? CellFace.open(styles[i - 1], size,
                    i - 1 < styleIndices.length ? styleIndices[i - 1] : 0,
                    coordinates, &previous, i - 1 < styleHashes.length ? styleHashes[i - 1] : 0)
                : CellFace.init;
            if (sibling.bytes.length)
                sibling.serial = previous.bytes.length && sibling.contentHash == previous.contentHash
                    && sibling.face.index == previous.face.index ? previous.serial : ++faceSerial_;
            specimenFaces_[i] = sibling;
        }
        // Fallbacks stay at their own defaults, sized to this specimen's line,
        // rather than the UI's independently sized line.
        import sparkles.font : hhea;
        const fallbackCount = extras.length + fallbacks_.length;
        if (specimenFallbacks_.length != fallbackCount)
            specimenFallbacks_.length = fallbackCount;
        foreach (i; 0 .. fallbackCount)
        {
            const explicitFace = i < extras.length;
            if (explicitFace)
            {
                auto fb = CellFace.open(extras[i].bytes, extras[i].ppem, extras[i].faceIndex,
                    null, &specimenFallbacks_[i], extras[i].contentHash);
                if (!fb.bytes.length) return false;
                const previousFallback = specimenFallbacks_[i];
                fb.serial = previousFallback.bytes.length && previousFallback.contentHash == fb.contentHash
                    && previousFallback.face.index == fb.face.index ? previousFallback.serial : ++faceSerial_;
                specimenFallbacks_[i] = fb;
                continue;
            }
            ref fallback = fallbacks_[i - extras.length];
            const hh = hhea(fallback.face);
            const span = hh.hasValue ? long(hh.value.ascender) - hh.value.descender : 0;
            auto em = size;
            if (lineHeight > 0 && span > 0)
            {
                const scaled = scaledPpem(Ppem.fromInteger(lineHeight).value,
                    fallback.face.unitsPerEm, cast(ulong) span);
                if (scaled.hasValue)
                    em = scaled.value;
            }
            auto fb = CellFace.open(fallback.bytes, em, fallback.face.index, null,
                &specimenFallbacks_[i], fallback.contentHash);
            fb.serial = fallback.serial;
            specimenFallbacks_[i] = fb;
        }
        specimenMetrics_ = metrics;
        specimenMetrics_.present = true;
        return true;
    }

    /// Selects the specimen for draws in this scope, preserving previous draws.
    bool beginSpecimen(int cellW, int cellH) @system
    {
        if (specimenActive_ || !specimenMetrics_.present)
            return false;
        import std.algorithm.mutation : swap;
        swap(faces_, specimenFaces_);
        swap(fallbacks_, specimenFallbacks_);
        swap(textMetrics_, specimenMetrics_);
        swap(textRendering_, specimenRendering_);
        painter_.textRendering = textRendering_;
        savedGrid_ = painter_.metrics;
        auto grid = savedGrid_;
        grid.cellW = cellW > 0 ? cellW : 1;
        grid.cellH = cellH > 0 ? cellH : 1;
        painter_.fontMetrics(grid);
        specimenActive_ = true;
        return true;
    }

    /// Restores the interface font and grid; harmless after a failed begin.
    void endSpecimen() @system
    {
        if (!specimenActive_)
            return;
        import std.algorithm.mutation : swap;
        swap(faces_, specimenFaces_);
        swap(fallbacks_, specimenFallbacks_);
        swap(textMetrics_, specimenMetrics_);
        swap(textRendering_, specimenRendering_);
        painter_.textRendering = textRendering_;
        painter_.fontMetrics(savedGrid_);
        specimenActive_ = false;
    }

    /// Glyphs drawn from fallback faces in specimen scopes this frame.
    uint specimenFallbackGlyphs() const @safe pure nothrow @nogc => specimenFallbackGlyphs_;
    /// Natural runs that needed the grid fallback in specimen scopes this frame.
    uint specimenGridFallbacks() const @safe pure nothrow @nogc => specimenGridFallbacks_;

    /// Settings used only inside specimen scopes. Atlas keys already separate
    /// hinted pixels; changing this does not invalidate interface glyphs.
    void specimenTextRendering(in TextRendering settings) @safe pure nothrow @nogc
    {
        if (specimenActive_)
        {
            textRendering_ = settings;
            painter_.textRendering = settings;
        }
        else
            specimenRendering_ = settings;
    }

    // The faces a cluster is looked up in, in order: the cell font's face of
    // the run's style, then the fallbacks — a colour face first when the
    // cluster presents as an emoji.
    private CellFace* orderedFace(in GlyphRequest r, size_t position) @system
    {
        auto styled = &faces_[faces_[r.style].bytes.length ? r.style : FaceStyle.regular];
        if (!r.emoji)
        {
            if (position == 0) return styled;
            --position;
        }
        foreach (colour; [r.emoji, !r.emoji])
        {
            foreach (ref f; fallbacks_)
                if (f.colour == colour)
                {
                    if (position == 0) return &f;
                    --position;
                }
            if (colour && r.emoji)
            {
                if (position == 0) return styled;
                --position;
            }
        }
        assert(false, "face position must be within the bound fallback list");
    }

    // Glyph `gid` of `face` from the atlas: in colour where the face has a
    // colour form for it — refitted at the exact smaller size when it is
    // larger than the cells `r` names — else its outline, hinted as the text
    // rendering asks.
    private GlyphOutcome glyphFrom(CellFace* face, uint gid, in GlyphRequest r, out GlyphQuad quad) @system
    {
        AtlasGlyph g;
        auto outcome = AtlasOutcome.noColour;
        vec4 geometry;
        bool directGlyph;
        if (directGlyphs_.length)
        if (auto direct = coverageKey(face.inst, face.serial, gid, face.ppem,
                textRendering_.hinting == Hinting.light) in directGlyphs_)
        {
            g = directGlyphRecords_[][*direct].glyph;
            geometry = directGlyphRecords_[][*direct].metadata;
            directGlyph = true;
            outcome = AtlasOutcome.placed;
        }
        if (face.colour)
        {
            const fg = foregroundOf(r.colour);
            outcome = atlas_.getColour(face.inst, face.serial, gid, face.ppem, fg, g);
            ulong a = 1, b = 1;
            const right = g.bearingX + g.width;
            if (r.fitWidth > 0 && right > r.fitWidth)
            {
                a = r.fitWidth;
                b = right;
            }
            if (r.fitHeight > 0 && ulong(g.height) * a > ulong(r.fitHeight) * b)
            {
                a = r.fitHeight;
                b = g.height;
            }
            if (outcome == AtlasOutcome.placed && a != b)
            {
                const smaller = scaledPpem(face.ppem, a, b);
                AtlasGlyph fitted;
                if (smaller.hasValue && atlas_.getColour(face.inst, face.serial, gid, smaller.value, fg,
                        fitted) == AtlasOutcome.placed)
                    g = fitted;
            }
        }
        if (outcome == AtlasOutcome.noColour)
            outcome = atlas_.get(face.inst, face.serial, gid, face.ppem, g,
                textRendering_.hinting == Hinting.light ? &face.hints : null);
        final switch (outcome)
        {
            case AtlasOutcome.placed:
                if (specimenActive_)
                    foreach (ref fallback; fallbacks_)
                        if (face is &fallback)
                            ++specimenFallbackGlyphs_;
                enum float side = GlyphAtlas.pageSize;
                quad = GlyphQuad(g.page + 1, g.colour, v4(g.x / side, g.y / side,
                    (g.x + g.width) / side, (g.y + g.height) / side),
                    g.width, g.height, g.bearingX, g.bearingY);
                if (directGlyph) quad.texRect = geometry;
                return GlyphOutcome.drawn;
            case AtlasOutcome.blank:
            case AtlasOutcome.noColour:
                return GlyphOutcome.blank;
            case AtlasOutcome.refused:
                return GlyphOutcome.refused;
            case AtlasOutcome.full:
                return GlyphOutcome.full;
        }
    }

    // A codepoint's glyph (`isGlyphSource`), from the first face in
    // `faceOrder` that maps it.
    private GlyphOutcome resolveGlyph(in GlyphRequest r, out GlyphQuad quad) @system
    {
        if (!textMetrics_.present)
            return GlyphOutcome.noGlyph;
        foreach (position; 0 .. fallbacks_.length + 1)
        {
            auto face = orderedFace(r, position);
            const gid = face.map.glyph(r.cp);
            if (gid != 0)
                return glyphFrom(face, gid, r, quad);
        }
        if (r.cp == ' ') return GlyphOutcome.blank;
        // A preview must show the selected face's missing-glyph form rather
        // than silently hiding characters no selected or fallback face maps.
        if (specimenActive_)
            return glyphFrom(&faces_[FaceStyle.regular], 0, r, quad);
        return GlyphOutcome.noGlyph;
    }

    /// Collect coverage misses while measuring natural runs, then join them
    /// before drawing. Font bindings must remain valid until finish returns.
    void beginGlyphPreparation(uint workers = 2, CoverageMode coverageMode = CoverageMode.cpu,
        bool profile = false) @safe nothrow
    {
        static if (canShape)
        {
            atlas_.beginPreparation();
            preparingGlyphs_ = true;
            rasterWorkers_ = workers;
            coverageMode_ = coverageMode;
            profileCoverage_ = profile;
        }
    }

    /// Completes CPU tiles; atlas placement and subsequent uploads stay here.
    CoverageWork finishGlyphPreparation() @system
    {
        CoverageWork work;
        static if (canShape)
        {
            import core.time : MonoTime;
            const start = profileCoverage_ ? MonoTime.currTime : MonoTime.init;
            const previousGlyphs = directGlyphRecords_.length;
            preparingGlyphs_ = false;
            if (coverageMode_ != CoverageMode.cpu && prepareCoveragePipeline())
                work = atlas_.finishGeometry(rasterWorkers_, coverageMode_, profileCoverage_, (in GlyphKey key, in RasterTile tile) {
                    if (!tile.geometry.length) return;
                    const first = geometryEdges_.length;
                    const end = first + tile.geometry.length;
                    const padded = (end + 511) & ~size_t(511);
                    const previousBytes = ((first + 511) & ~size_t(511)) * vec4.sizeof;
                    const addedBytes = padded * vec4.sizeof - previousBytes;
                    if (end > 512 * 256 || uploaded_ + addedBytes > config_.uploadBudget) return;
                    uploaded_ += addedBytes;
                    geometryEdges_ ~= tile.geometry[];
                    const m = tile.metrics;
                    const id = cast(uint)directGlyphRecords_.length;
                    directGlyphRecords_ ~= DirectGlyph(AtlasGlyph(directCoverageFlag,
                        false, 0, 0, m.width, m.height, m.bearingX, m.bearingY),
                        v4(cast(float)first, cast(float)tile.layout.stride,
                            tile.unionCoverage ? 1 : 0, cast(float)tile.layout.bandHeight));
                    directGlyphs_[key] = id;
                });
            else work = atlas_.finishPreparation(rasterWorkers_, profileCoverage_);
            work.publishedGlyphs = directGlyphRecords_.length - previousGlyphs;
            if (profileCoverage_) work.batchNs = (MonoTime.currTime - start).total!"nsecs";
        }
        return work;
    }

    // Shape using the first face covering the entire run, then resolve its
    // glyphs. Unsupported runs remain available to the painter's grid fallback.
    private GlyphOutcome resolveCluster(in ClusterRequest r, scope GlyphQuad[] quads, out size_t count) @system
    {
        static if (!canShape)
            return GlyphOutcome.noGlyph;
        else
        {
            import sparkles.base.text.utf : convertPrefix, UtfMode;
            import sparkles.font.cluster_shaping : ClusterGlyph, maxClusterGlyphs, shapeCluster;

            static assert(maxClusterGlyphs == maxClusterQuads,
                "the painter's quads and the font seam's glyphs are one cap");

            // Interface runs are always shaped: their advances are their
            // placement (`UVK20`), not a refinement of a cell grid's.
            if (!textMetrics_.present || !r.cps.length
                    || (!textRendering_.shaping && r.first.interfaceStep < 0))
                return GlyphOutcome.noGlyph;
            auto face = clusterFace(r);
            if (face is null)
                return GlyphOutcome.noGlyph;
            const glyphs = clusterGlyphs(face, r);
            if (!glyphs.length)
                return GlyphOutcome.noGlyph;
            const before = atlas_.framePins();
            foreach (attempt; 0 .. 2)
            {
                count = 0;
                bool pressure;
                double pen = 0;
                static int nearest(double v) => cast(int)(v >= 0 ? v + 0.5 : v - 0.5);
                foreach (g; glyphs)
                {
                    if (g.glyph == 0)
                    {
                        atlas_.restorePins(before);
                        return GlyphOutcome.noGlyph;
                    }
                    if (r.measureOnly)
                    {
                        if (preparingGlyphs_ && !face.colour && (!directGlyphs_.length
                            || (coverageKey(face.inst, face.serial, g.glyph,
                                face.ppem, textRendering_.hinting == Hinting.light) in directGlyphs_) is null))
                            atlas_.prepare(face.inst, face.serial, g.glyph, face.ppem,
                                textRendering_.hinting == Hinting.light ? &face.hints : null);
                        pen += g.advance;
                        continue;
                    }
                    GlyphQuad q;
                    const outcome = glyphFrom(face, g.glyph, r.first, q);
                    if (outcome == GlyphOutcome.drawn)
                    {
                        q.dx = nearest(pen + g.xOffset);
                        q.dy = nearest(g.yOffset);
                        if (count < quads.length)
                            quads[count++] = q;
                    }
                    else if (outcome == GlyphOutcome.full) { pressure = true; break; }
                    else if (outcome != GlyphOutcome.blank)
                    {
                        atlas_.restorePins(before);
                        return outcome;
                    }
                    pen += g.advance;
                }

                if (pressure)
                {
                    atlas_.restorePins(before);
                    if (attempt == 0 && atlas_.reclaimColdPages()) continue;
                    return GlyphOutcome.full;
                }
                if (r.advance !is null)
                {
                    // The request borrows a mutable output slot for this call;
                    // `in` freezes the request, not the caller-owned result.
                    () @trusted { *cast(double*) r.advance = pen; }();
                }
                return GlyphOutcome.drawn;
            }
            assert(false, "a run returns or retries exactly once");
        }
    }

    static if (canShape)
    {
        private CellFace* clusterFace(in ClusterRequest r) @system
        {
            static bool covers(CellFace* face, in ClusterRequest r)
            {
                bool all = true;
                foreach (cp; r.cps) all &= !shownCodepoint(cp) || face.map.glyph(cast(dchar) cp) != 0;
                return all;
            }
            // An interface run is the interface face's whole, or not shaped.
            if (r.first.interfaceStep >= 0)
            {
                auto face = interfaceFace(r.first.interfaceStep, r.first.style == FaceStyle.bold);
                return face !is null && covers(face, r) ? face : null;
            }
            foreach (position; 0 .. fallbacks_.length + 1)
            {
                auto face = orderedFace(r.first, position);
                if (covers(face, r)) return face;
            }
            return null;
        }

        private const(imported!"sparkles.font.cluster_shaping".ClusterGlyph)[]
            clusterGlyphs(CellFace* face, in ClusterRequest r) @system
        {
            import sparkles.base.text.utf : convertPrefix, UtfMode;
            import sparkles.font.cluster_shaping : ClusterGlyph, shapeCluster;
            size_t shape(scope ClusterGlyph[] output)
            {
                auto shaper = shaperFor(face);
                if (shaper is null) return size_t(0);
                char[maxClusterQuads * 4] text;
                const encoded = convertPrefix(cast(const(dchar)[]) r.cps, text[], UtfMode.replacement);
                return shapeCluster(shaper, text[0 .. encoded.written],
                    face.ppem.numerator, face.ppem.denominator, output, r.direction);
            }
            // The two caches differ in size, so not in type.
            return r.first.interfaceStep >= 0
                ? interfaceRuns_.prepare(face.serial, face.ppem, face.inst.coords, r.cps, &shape, r.direction)
                : preparedRuns_.prepare(face.serial, face.ppem, face.inst.coords, r.cps, &shape, r.direction);
        }

        // Keep only exact file storage still borrowed by a bound context.
        // Content identity alone cannot keep an old allocation alive.
        private void pruneShapers() @system
        {
            foreach (ref slot; shapers_)
            {
                if (!slot.tried) continue;
                bool bound;
                void check(in CellFace face) {
                    const old = slot.instance.face;
                    bound |= face.bytes.length && face.bytes.ptr == old.bytes.ptr
                        && face.bytes.length == old.bytes.length && face.face.index == old.index;
                }
                foreach (ref face; faces_) check(face);
                foreach (ref face; specimenFaces_) check(face);
                foreach (ref face; fallbacks_) check(face);
                foreach (ref face; specimenFallbacks_) check(face);
                foreach (ref step; interfaceFaces_)
                    foreach (ref face; step) check(face);
                if (!bound) slot.release();
            }
        }

        // A retained face's coordinates/size change without reallocating its
        // HarfBuzz objects and multi-megabyte phantom-point workspace.
        private imported!"sparkles.font.cluster_shaping".ClusterShaper* shaperFor(CellFace* face) @system
        {
            foreach (ref slot; shapers_)
                if (slot.tried && slot.serial == face.serial)
                {
                    slot.update(face.inst);
                    return slot.handle;
                }
            // The first free slot, else the oldest face's (the table is small,
            // and a face no longer bound is not shaped with again).
            size_t pick;
            foreach (i, ref slot; shapers_)
                if (!slot.tried || slot.serial < shapers_[pick].serial)
                {
                    pick = i;
                    if (!slot.tried)
                        break;
                }
            shapers_[pick].release();
            shapers_[pick].make(face.serial, face.inst);
            return shapers_[pick].handle;
        }
    }
    else private void pruneShapers() @safe pure nothrow @nogc {}

    // The atlas's pages made on the device — one byte a texel for coverage,
    // premultiplied RGBA for colour — and the regions drawn since the last
    // frame staged into them.
    private VkResult stageAtlas() @system
    {
        enum side = GlyphAtlas.pageSize;
        static immutable VkFormat[2] formats = [VkFormat.VK_FORMAT_R8_UNORM, VkFormat.VK_FORMAT_R8G8B8A8_UNORM];
        foreach (colour; [false, true])
            while (atlasImages_[colour].length < atlas_.pageCount(colour))
            {
                atlasImages_[colour].put(GpuImage.init);
                atlasGenerations_[colour].put(0);
            }
        VkResult result = VkResult.VK_SUCCESS;
        ubyte[] rows;
        atlas_.takeDirty((in DirtyRegion d) {
            if (result < 0)
                return false;
            ref image = atlasImages_[d.colour][][d.page];
            ref generation = atlasGenerations_[d.colour][][d.page];
            const required = atlas_.pageGeneration(d.page, d.colour);
            if (image.handle is null || generation != required)
            {
                GpuImage replacement;
                const made = GpuImage.create(replacement, *device_, *memory_, formats[d.colour],
                    VkExtent2D(side, side), VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT
                    | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
                if (made.hasError) { result = made.error; return false; }
                if (image.handle !is null) retire(image);
                image = replacement;
                generation = required;
            }
            const texel = d.colour ? 4 : 1;
            const pixels = atlas_.page(d.page, d.colour);
            const(ubyte)[] data = pixels;
            if (!d.whole)
            {
                const span = size_t(d.width) * texel;
                rows.length = span * d.height;
                foreach (y; 0 .. d.height)
                {
                    const from = (size_t(d.y + y) * side + d.x) * texel;
                    rows[y * span .. (y + 1) * span] = pixels[from .. from + span];
                }
                data = rows;
            }
            auto staged = uploads_.stage(slot_, atlasImages_[d.colour][][d.page].handle,
                d.whole ? VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED
                    : VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                data, texel, VkOffset2D(d.x, d.y), VkExtent2D(d.width, d.height));
            if (staged.hasError)
                result = staged.error;
            return !staged.hasError;
        });
        return result;
    }

    /// How text is rendered from here on. A change that alters glyph pixels
    /// (hinting) starts the glyph atlas over — at the next frame when one is
    /// open, whose recorded quads still point into it. Hinted and unhinted
    /// glyphs are cached apart, so a frame may hold both.
    void textRendering(in TextRendering settings) @system
    {
        if (settings.hinting != textRendering_.hinting)
        {
            if (inFrame_)
                atlasStale_ = true;
            else
                atlas_.reset();
        }
        textRendering_ = settings;
    }

    /// ditto
    TextRendering textRendering() const @safe pure nothrow @nogc => textRendering_;

    /// The loupe drawn over every frame from the next on, or none. It needs a
    /// target that allows transfers both ways; on another it is not drawn.
    void loupe(in Loupe l) @safe pure nothrow @nogc
    {
        loupe_ = l;
    }

    // The loupe, after the pass: the target to the general layout, its
    // `source` blitted `scale` times larger with nearest filtering — each
    // pixel a block, exactly as composited — unless the two overlap.
    private void recordLoupe(ref VkImageLayout layout, ref VkPipelineStageFlags stage,
        ref VkAccessFlags access) @system
    {
        with (VkImageUsageFlagBits)
            if (!loupe_.shown || loupe_.scale < 1
                || !(target_.usage & VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
                || !(target_.usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
                return;
        // Laid out in display pixels; the blit's rectangles turned onto the
        // target (`UVK39`).
        const display = displayExtent(target_);
        const w = int(display.width), h = int(display.height);
        static int clampTo(int v, int hi) => v < 0 ? 0 : v > hi ? hi : v;
        // From the frame's origin, as every pixel coordinate is.
        const sx = loupe_.sourceX + originX_, sy = loupe_.sourceY + originY_;
        const lx = loupe_.x + originX_, ly = loupe_.y + originY_;
        const sx0 = clampTo(sx, w), sy0 = clampTo(sy, h);
        const sx1 = clampTo(sx + loupe_.sourceWidth, w);
        const sy1 = clampTo(sy + loupe_.sourceHeight, h);
        const dx0 = clampTo(lx, w), dy0 = clampTo(ly, h);
        // Whole source pixels only, so every block is `scale` square.
        const cols = (clampTo(lx + (sx1 - sx0) * loupe_.scale, w) - dx0) / loupe_.scale;
        const rows = (clampTo(ly + (sy1 - sy0) * loupe_.scale, h) - dy0) / loupe_.scale;
        const dx1 = dx0 + cols * loupe_.scale, dy1 = dy0 + rows * loupe_.scale;
        const overlaps = sx0 < dx1 && dx0 < sx0 + cols && sy0 < dy1 && dy0 < sy0 + rows;
        if (cols <= 0 || rows <= 0 || overlaps)
            return;
        with (VkPipelineStageFlagBits) with (VkAccessFlagBits)
        {
            transition(*device_, commands_, target_.image, layout, VkImageLayout.VK_IMAGE_LAYOUT_GENERAL,
                stage, access, VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT);
            const colour = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT, layerCount: 1);
            const src = turnedBox(ScissorBox(sx0, sy0, cols, rows), w, h, target_.turn);
            const dst = turnedBox(ScissorBox(dx0, dy0, dx1 - dx0, dy1 - dy0), w, h, target_.turn);
            VkImageBlit region = {
                srcSubresource: colour,
                srcOffsets: [VkOffset3D(src.x, src.y, 0), VkOffset3D(src.x + src.w, src.y + src.h, 1)],
                dstSubresource: colour,
                dstOffsets: [VkOffset3D(dst.x, dst.y, 0), VkOffset3D(dst.x + dst.w, dst.y + dst.h, 1)],
            };
            device_.cmdBlitImage(commands_, target_.image, VkImageLayout.VK_IMAGE_LAYOUT_GENERAL,
                target_.image, VkImageLayout.VK_IMAGE_LAYOUT_GENERAL, 1, &region,
                VkFilter.VK_FILTER_NEAREST);
            layout = VkImageLayout.VK_IMAGE_LAYOUT_GENERAL;
            stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            access = VK_ACCESS_TRANSFER_WRITE_BIT;
        }
    }

    /// A label's size in device pixels, as `labelPx` lays it out in the
    /// cell of the last frame begun.
    int[2] labelSizePx(scope const(char)[] text) const @system => painter_.labelSizePx(text);

    /// How many glyph atlas pages are on the device: coverage pages, or colour ones.
    size_t atlasPages(bool colour = false) const @safe pure nothrow @nogc
    {
        size_t count;
        foreach (ref image; atlasImages_[colour][])
            if (image.handle !is null) ++count;
        return count;
    }

    /// Coverage blocks prepared for this frame's experimental GPU path.
    size_t gpuCoverageGlyphs() const @safe pure nothrow @nogc => directGlyphRecords_.length;

    /**
    Forgets the framebuffers made for the target views handed in so far,
    each destroyed once the frames in flight that drew through it have
    completed. For the host to call when it destroys the views — a swapchain
    rebuilt at the same size — since a framebuffer outliving its view is
    invalid, and a new view may reuse the old one's handle.
    */
    void releaseTargets() @system
    {
        foreach (ref f; framebuffers_[])
            retired_.put(Retired(framebuffer: f.framebuffer, needed: lastSerial));
        framebuffers_.clear();
    }

    /**
    Destroys everything the canvas made. The host first waits for the device
    to finish every frame the canvas recorded. Idempotent, and possible after
    a lost device (`UVK33`).
    */
    void destroy() @system
    {
        atlas_.stopPreparation();
        if (device_ is null)
            return;
        coveragePipelines_.destroy(*device_);
        coveragePipelinesReady_ = false;
        foreach (ref image; geometryImages_[]) image.destroy(*device_, *memory_);
        geometryImages_.clear();
        foreach (ref r; retired_[])
            destroyRetired(r);
        retired_.clear();
        foreach (ref f; framebuffers_[])
            device_.destroyFramebuffer(device_.device, f.framebuffer, null);
        framebuffers_.clear();
        foreach (ref e; images_[])
            if (e.handle.valid)
                e.image.destroy(*device_, *memory_);
        images_.clear();
        foreach (ref sheet; atlasImages_)
        {
            foreach (ref page; sheet[])
                page.destroy(*device_, *memory_);
            sheet.clear();
        }
        foreach (ref generations; atlasGenerations_) generations.clear();
        placeholder_.destroy(*device_, *memory_);
        foreach (ref p; pools_[])
            device_.destroyDescriptorPool(device_.device, p.pool, null);
        pools_.clear();
        uploads_.discard();
        buffers_.destroy();
        static if (canShape)
            foreach (ref slot; shapers_)
                slot.release();
        arena_.destroy();
        pipelines_.destroy(*device_);
        device_ = null;
    }

    /**
    Binds the image registry handles resolve against (`IMG3`), which must
    outlive the canvas. Cached entries are keyed by (registry, handle,
    generation), so switching registry evicts nothing; an entry goes when
    its registry no longer holds it at that generation (checked as each
    frame begins), or with `releaseCaches`.
    */
    void images(const(ImageRegistry)* registry) @system
    {
        if (registry is registry_)
            return;
        registry_ = registry;
    }

    /// The registry bound now, so a component that binds its own for part
    /// of a frame can put back the one it found (`UVX11`).
    const(ImageRegistry)* boundImages() const @safe pure nothrow @nogc => registry_;

    /// Whether the device was lost (`UVK33`).
    bool lost() const => lost_;

    /// How many images are cached on the device.
    size_t cachedImages() const
    {
        size_t n;
        foreach (ref e; images_[])
            n += e.handle.valid;
        return n;
    }

    /// How many target formats have a pipeline.
    size_t pipelineCount() const => pipelines_.formatCount + coveragePipelines_.formatCount;

    /// What making its pipelines cost, as the driver reported it (`PRF16`).
    PipelineCompiles pipelineCompiles() const
    {
        const a = pipelines_.compiles, b = coveragePipelines_.compiles;
        return PipelineCompiles(a.compiled + b.compiled, a.fromCache + b.fromCache,
            a.unreported + b.unreported, a.nanos + b.nanos);
    }

    /// How many image uploads the canvas has staged since it was created
    /// (`UVK23`).
    ulong imageUploads() const => imageUploads_;

    // -------------------------------------------------------------------
    // The canvas concept, through the batcher
    // -------------------------------------------------------------------

    static foreach (name; ["fillRect", "textRun", "textRunIn", "glyph", "line", "rule",
            "scrollbar", "image", "pushClip", "popClip", "pushShift", "popShift", "pushEffect",
            "popEffect", "fillPx", "outlinePx", "roundedPx", "shadowPx", "eraseOutsidePx", "clipPx",
            "unclipPx", "pushOffsetPx",
            "popOffsetPx", "imageQuadPx", "imageSourcePx", "clusterPx", "labelPx"])
        mixin("/// Through `Painter." ~ name ~ "`; only between `beginFrame` and `endFrame`.\n"
            ~ "void " ~ name ~ "(Args...)(auto ref Args args) @system\n"
            ~ "in (inFrame_, \"drawing outside a frame\")\n"
            ~ "{ painter_." ~ name ~ "(args); }");

    /// Shaped specimen text in pixels, returning its actual advance.
    int naturalTextPx(Args...)(auto ref Args args) @system
    {
        const before = painter_.report[Degradation.unshapedCluster];
        const advance = painter_.naturalTextPx(args);
        if (specimenActive_)
            specimenGridFallbacks_ += painter_.report[Degradation.unshapedCluster] - before;
        return advance;
    }

    /// Its advance without rasterization or drawing.
    int naturalTextWidthPx(Args...)(auto ref Args args) @system
        => painter_.naturalTextWidthPx(args);

    /**
    Inspect the glyph at a run-local pixel x using the same selected face and
    cached shaping as drawing. Call while the desired font context is active.
    The result owns its names; it borrows no font or atlas memory.
    */
    GlyphInspection inspectTextPx(scope const(char)[] text, double x,
        bool bold = false, bool italic = false,
        ClusterDirection direction = ClusterDirection.automatic, bool grid = false) @system
    {
        import sparkles.base.text.grapheme : byGraphemeCluster, emojiPresentation, visibleWidth;
        import sparkles.base.text.utf : convertPrefix, UtfMode;
        GlyphInspection result;
        if (!textMetrics_.present || x < 0) return result;
        dchar[maxClusterQuads] cps;
        const decoded = convertPrefix(text, cps[], UtfMode.replacement);
        if (!decoded.written || decoded.consumed != text.length) return result;
        auto request = GlyphRequest(cps[0], faceStyle(bold, italic),
            emojiPresentation(cast(const(uint)[]) cps[0 .. decoded.written]));
        static if (canShape)
        {
            auto r = ClusterRequest(cast(const(uint)[]) cps[0 .. decoded.written], request,
                null, true, direction);
            auto shapedFace = textRendering_.shaping && !grid ? clusterFace(r) : null;
            if (shapedFace !is null)
            {
                const glyphs = clusterGlyphs(shapedFace, r);
                bool valid = glyphs.length != 0;
                foreach (g; glyphs) valid &= g.glyph != 0;
                double pen = 0;
                foreach (g; valid ? glyphs : null)
                {
                    if (!g.glyph) break;
                    if (g.advance > 0 && x >= pen && x < pen + g.advance)
                    {
                        result = inspectFace(shapedFace, g.glyph);
                        result.shaped = true;
                        result.cluster = g.cluster;
                        result.start = g.cluster;
                        result.end = text.length;
                        foreach (other; glyphs)
                            if (other.cluster > g.cluster && other.cluster < result.end)
                                result.end = other.cluster;
                        expandInspectionSource(result, text);
                        foreach (other; glyphs)
                            if (other.cluster >= result.start && other.cluster < result.end)
                                result.glyphs ~= other.glyph;
                        result.advance = g.advance;
                        result.xOffset = g.xOffset;
                        result.yOffset = g.yOffset;
                        result.flags = g.flags;
                        return result;
                    }
                    pen += g.advance;
                }
                if (valid) return result;
            }
        }
        // Drawing fell back to cell clusters: use that exact face order too.
        request.style = FaceStyle.regular;
        double pen = 0;
        size_t offset;
        foreach (cluster; text.byGraphemeCluster)
        {
            const cells = cast(int) visibleWidth(cluster.slice);
            const width = (cells > 0 ? cells : 1) * painter_.metrics.cellW;
            if (x >= pen && x < pen + width)
            {
                dchar[maxClusterQuads] part;
                const n = convertPrefix(cluster.slice, part[], UtfMode.replacement);
                request.cp = part[0];
                request.emoji = emojiPresentation(cast(const(uint)[]) part[0 .. n.written]);
                bool needsShaping;
                foreach (cp; part[1 .. n.written]) needsShaping |= cp != 0xFE0E && cp != 0xFE0F;
                static if (canShape)
                    if (textRendering_.shaping && needsShaping)
                    {
                        auto clusterRequest = ClusterRequest(cast(const(uint)[]) part[0 .. n.written],
                            request, null, true, ClusterDirection.automatic);
                        auto serving = clusterFace(clusterRequest);
                        if (serving !is null)
                        {
                            const shaped = clusterGlyphs(serving, clusterRequest);
                            bool valid = shaped.length != 0;
                            foreach (g; shaped) valid &= g.glyph != 0;
                            if (valid)
                            {
                                result = inspectFace(serving, shaped[0].glyph);
                                result.shaped = true;
                                result.start = offset;
                                result.end = offset + cluster.slice.length;
                                result.advance = width;
                                foreach (g; shaped) result.glyphs ~= g.glyph;
                                return result;
                            }
                        }
                    }
                CellFace* face;
                uint glyph;
                foreach (position; 0 .. fallbacks_.length + 1)
                {
                    auto next = orderedFace(request, position);
                    if (auto gid = next.map.glyph(request.cp)) { face = next; glyph = gid; break; }
                }
                if (face is null) face = &faces_[FaceStyle.regular];
                result = inspectFace(face, glyph);
                result.start = offset;
                result.end = offset + cluster.slice.length;
                result.advance = width;
                result.glyphs = [glyph];
                return result;
            }
            pen += width;
            offset += cluster.slice.length;
        }
        return result;
    }

    private static void expandInspectionSource(ref GlyphInspection result,
        scope const(char)[] text) @safe pure nothrow @nogc
    {
        import sparkles.base.text.grapheme : byGraphemeCluster;
        const start = result.start, end = result.end;
        size_t at;
        foreach (grapheme; text.byGraphemeCluster)
        {
            const next = at + grapheme.slice.length;
            if (at < end && next > start)
            {
                if (at < result.start) result.start = at;
                if (next > result.end) result.end = next;
            }
            at = next;
        }
    }

    private GlyphInspection inspectFace(CellFace* face, uint glyph) @system
    {
        import sparkles.font.names : name;
        import sparkles.font.glyph_names : glyphName;
        GlyphInspection result;
        result.found = true;
        result.glyph = glyph;
        result.faceIndex = face.face.index;
        result.faceSerial = face.serial;
        result.ppem = face.ppem.numerator / cast(double) face.ppem.denominator;
        result.colour = face.colour;
        foreach (ref fallback; fallbacks_) if (face is &fallback) result.fallback = true;
        auto names = name(face.face);
        if (names.hasValue)
            foreach (id; [4, 6, 1])
            {
                foreach (record; names.value.records)
                    if (record.hasValue && record.value.nameID == id)
                    {
                        char[1024] storage;
                        auto decoded = record.value.decode(storage[]);
                        if (decoded.hasValue) { result.faceName = decoded.value.idup; break; }
                    }
                if (result.faceName.length) break;
            }
        const named = glyphName(face.face, glyph);
        if (named.hasValue && named.value.present) result.glyphName = named.value.text.idup;
        return result;
    }

    /// A run's extent in cells.
    Size measure(scope const(char)[] text) const => painter_.measure(text);

    // -------------------------------------------------------------------

    // The image `handle` as the painter draws it (`UVK23`, `UVK25`).
    package ImageOutcome resolveImage(ImageHandle handle, out uint slot, out Size size) @system
    {
        const data = registry_ is null ? null : registry_.lookup(handle);
        if (lost_ || data is null || data.rgba.length == 0 || data.size.width <= 0
            || data.size.height <= 0)
            return ImageOutcome.missing;
        size = data.size;
        if (data.size.width > facts_.maxImageExtent || data.size.height > facts_.maxImageExtent)
            return ImageOutcome.tooLarge;

        size_t free = size_t.max;
        foreach (i, ref e; images_[])
        {
            if (e.registry is registry_ && e.handle == handle
                && e.generation == data.generation)
            {
                slot = cast(uint) i + 1;
                return ImageOutcome.drawn;
            }
            if (!e.handle.valid && free == size_t.max)
                free = i;
        }
        // An upload: within the frame's budget, unless it is the frame's
        // first, so an image larger than the whole budget still arrives.
        const bytes = ulong(data.size.width) * data.size.height * 4;
        if (uploaded_ > 0 && uploaded_ + bytes > config_.uploadBudget)
            return ImageOutcome.deferred;
        if (frameError_ != VkResult.VK_SUCCESS)
            return ImageOutcome.missing;
        GpuImage image;
        auto made = GpuImage.create(image, *device_, *memory_, VkFormat.VK_FORMAT_R8G8B8A8_UNORM,
            VkExtent2D(data.size.width, data.size.height),
            VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT
            | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
        if (made.hasError)
        {
            frameError_ = made.error;
            return ImageOutcome.missing;
        }
        auto staged = uploads_.stage(slot_, image.handle, VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
            data.rgba, 4, VkOffset2D(0, 0), VkExtent2D(data.size.width, data.size.height));
        if (staged.hasError)
        {
            image.destroy(*device_, *memory_);
            frameError_ = staged.error;
            return ImageOutcome.missing;
        }
        uploaded_ += bytes;
        ++imageUploads_;

        // A replaced generation keeps its entry; the old image is retired.
        foreach (i, ref e; images_[])
            if (e.registry is registry_ && e.handle == handle)
            {
                retire(e.image);
                e = CachedImage(handle, data.generation, registry_, image);
                slot = cast(uint) i + 1;
                return ImageOutcome.drawn;
            }
        if (free == size_t.max)
        {
            free = images_.length;
            images_.put(CachedImage.init);
        }
        images_[][free] = CachedImage(handle, data.generation, registry_, image);
        slot = cast(uint) free + 1;
        return ImageOutcome.drawn;
    }

    // The serial of the latest frame that may reference what is released now.
    private ulong lastSerial() const => inFrame_ ? serial_ : serial_ - 1;

    private void retire(ref GpuImage image)
    {
        if (image.handle is null) return;
        retired_.put(Retired(image: image, needed: lastSerial));
        image = GpuImage.init;
    }

    // Destroys what no frame in flight may still read.
    private void destroyRetired() @system
    {
        size_t i;
        while (i < retired_.length)
        {
            const needed = retired_[][i].needed;
            bool safe = true;
            foreach (s; inFlight_[])
                if (s != 0 && s <= needed)
                    safe = false;
            if (!safe)
            {
                ++i;
                continue;
            }
            destroyRetired(retired_[][i]);
            auto all = retired_[];
            all[i] = all[$ - 1];
            retired_.popBack();
        }
    }

    private void destroyRetired(ref Retired r) @system
    {
        r.image.destroy(*device_, *memory_);
        if (r.framebuffer !is null)
            device_.destroyFramebuffer(device_.device, r.framebuffer, null);
    }

    // The cached images their registry no longer holds at the cached
    // generation — removed, or replaced — retired before a frame binds
    // anything, so the cache holds only what can still be drawn (`UVK23`).
    // A registry outlives the canvas (`images`), so the pointer is valid.
    private void evictGone() @system
    {
        foreach (ref e; images_[])
        {
            if (!e.handle.valid || e.registry is null)
                continue;
            const data = e.registry.lookup(e.handle);
            if (data !is null && data.rgba.length && data.generation == e.generation)
                continue;
            retire(e.image);
            e = CachedImage.init;
        }
    }

    private bool boundThisFrame(uint slot) const
    {
        foreach (ref run; painter_.runs)
            if (run.images.image == slot)
                return true;
        return false;
    }

    // Framebuffers of another format or extent belong to a target gone by.
    private void retireFramebuffersNotFor(ref const CanvasTarget target) @system
    {
        size_t i;
        while (i < framebuffers_.length)
        {
            auto f = framebuffers_[][i];
            if (f.format == target.format && f.extent == target.extent)
            {
                ++i;
                continue;
            }
            retired_.put(Retired(framebuffer: f.framebuffer, needed: lastSerial));
            auto all = framebuffers_[];
            all[i] = all[$ - 1];
            framebuffers_.popBack();
        }
    }

    // The framebuffer the target draws through: one imageless one per format
    // and extent where the device has them, else one per view.
    private VkResult framebufferFor(VkRenderPass pass, out VkFramebuffer framebuffer) @system
    {
        const imageless = facts_.imagelessFramebuffer;
        VkImageView view = imageless ? null : target_.view;
        foreach (ref f; framebuffers_[])
            if (f.view == view && f.format == target_.format && f.extent == target_.extent)
            {
                framebuffer = f.framebuffer;
                return VkResult.VK_SUCCESS;
            }
        auto format = target_.format;
        auto attachmentImage = vkInfo(VkFramebufferAttachmentImageInfo(
            usage: target_.usage,
            width: target_.extent.width,
            height: target_.extent.height,
            layerCount: 1,
            viewFormatCount: 1,
            pViewFormats: &format,
        ));
        auto attachments = vkInfo(VkFramebufferAttachmentsCreateInfo(
            attachmentImageInfoCount: 1,
            pAttachmentImageInfos: &attachmentImage,
        ));
        auto targetView = target_.view;
        auto info = vkInfo(VkFramebufferCreateInfo(
            pNext: imageless ? &attachments : null,
            flags: imageless ? VkFramebufferCreateFlagBits.VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT : 0,
            renderPass: pass,
            attachmentCount: 1,
            pAttachments: imageless ? null : &targetView,
            width: target_.extent.width,
            height: target_.extent.height,
            layers: 1,
        ));
        const r = device_.createFramebuffer(device_.device, &info, null, &framebuffer);
        if (r >= 0)
            framebuffers_.put(TargetFramebuffer(view, target_.format, target_.extent, framebuffer));
        return r;
    }

    // The descriptor set binding `images`, made once per frame and set.
    private VkResult setFor(in BoundImages images, out VkDescriptorSet set) @system
    {
        foreach (ref s; frameSets_[])
            if (s.images == images)
            {
                set = s.set;
                return VkResult.VK_SUCCESS;
            }
        SlotPool* pool;
        foreach (ref p; pools_[])
            if (p.slot == slot_ && p.used < setsPerPool)
            {
                pool = &p;
                break;
            }
        if (pool is null)
        {
            VkDescriptorPoolSize[2] sizes = [
                VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                    3 * setsPerPool),
                VkDescriptorPoolSize(VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER,
                    2 * setsPerPool),
            ];
            auto info = vkInfo(VkDescriptorPoolCreateInfo(maxSets: setsPerPool,
                poolSizeCount: sizes.length, pPoolSizes: sizes.ptr));
            VkDescriptorPool made;
            const r = device_.createDescriptorPool(device_.device, &info, null, &made);
            if (r < 0)
                return r;
            pools_.put(SlotPool(slot_, made, 0));
            pool = &pools_[][$ - 1];
        }
        auto layout = pipelines_.setLayout;
        auto allocate = vkInfo(VkDescriptorSetAllocateInfo(descriptorPool: pool.pool,
            descriptorSetCount: 1, pSetLayouts: &layout));
        const r = device_.allocateDescriptorSets(device_.device, &allocate, &set);
        if (r < 0)
            return r;
        ++pool.used;

        VkDescriptorImageInfo[5] infos;
        // A run binds at most one page of each sheet; the placeholder stands in for none.
        infos[0] = sampled(images.coveragePage == 0 ? placeholder_.view
            : images.coveragePage & directCoverageFlag ? geometryImages_[][slot_].view
            : atlasImages_[0][][images.coveragePage - 1].view);
        infos[1] = sampled(images.colourPage == 0 ? placeholder_.view
            : atlasImages_[1][][images.colourPage - 1].view);
        infos[2] = sampled(images.image == 0 ? placeholder_.view
            : images_[][images.image - 1].image.view);
        infos[3] = VkDescriptorImageInfo(sampler: pipelines_.nearest);
        infos[4] = VkDescriptorImageInfo(sampler: pipelines_.linear);
        VkWriteDescriptorSet[5] writes;
        static immutable uint[5] bindingOf = [Binding.coverage, Binding.colour, Binding.image,
            Binding.nearest, Binding.linear];
        foreach (i; 0 .. 5)
            writes[i] = vkInfo(VkWriteDescriptorSet(dstSet: set, dstBinding: bindingOf[i],
                descriptorCount: 1,
                descriptorType: i < 3 ? VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
                    : VkDescriptorType.VK_DESCRIPTOR_TYPE_SAMPLER,
                pImageInfo: &infos[i]));
        device_.updateDescriptorSets(device_.device, writes.length, writes.ptr, 0, null);
        frameSets_.put(FrameSet(images, set));
        return VkResult.VK_SUCCESS;
    }

    private bool prepareCoveragePipeline() @system
    {
        if (!geometryImages_.length) geometryImages_.length = config_.frameSlots;
        if (geometryImages_[][slot_].handle is null)
        {
            const made = GpuImage.create(geometryImages_[][slot_], *device_, *memory_,
                VkFormat.VK_FORMAT_R32G32B32A32_SFLOAT, VkExtent2D(512, 256),
                VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT | VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
            if (made.hasError)
            {
                if (made.error == VkResult.VK_ERROR_DEVICE_LOST) frameError_ = made.error;
                return false;
            }
        }
        if (!coveragePipelinesReady_)
        {
            const made = Pipelines.create(coveragePipelines_, *device_, facts_,
                modernShaders ? vertex13 : vertex11, modernShaders ? coverage13 : coverage11,
                PipelinePurpose.coverageGlyph);
            if (made.hasError)
            {
                if (made.error == VkResult.VK_ERROR_DEVICE_LOST) frameError_ = made.error;
                return false;
            }
            coveragePipelinesReady_ = true;
        }
        const pipeline = coveragePipelines_.forFormat(*device_, target_.format);
        if (pipeline.hasError && pipeline.error == VkResult.VK_ERROR_DEVICE_LOST)
            frameError_ = pipeline.error;
        return pipeline.hasValue;
    }

    private bool modernShaders() const @safe pure nothrow @nogc
        => facts_.spirv16 && !config_.baselineShaders;

    private VkResult stageGeometry() @system
    {
        if (!geometryEdges_.length) return VkResult.VK_SUCCESS;
        const rows = (geometryEdges_.length + 511) / 512;
        geometryEdges_.length = rows * 512;
        const bytes = geometryEdges_.length * vec4.sizeof;
        const pixels = (cast(const(ubyte)*)geometryEdges_[].ptr)[0 .. bytes];
        // Each slot is fenced before reuse. Geometry is frame-local, so the
        // previous contents may be discarded without an upload shadow copy.
        const staged = uploads_.stage(slot_, geometryImages_[][slot_].handle,
            VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED, pixels, 16, VkOffset2D(0, 0),
            VkExtent2D(512, cast(uint)rows));
        if (!staged.hasError) ++imageUploads_;
        return staged.hasError ? staged.error : VkResult.VK_SUCCESS;
    }

    private static VkDescriptorImageInfo sampled(VkImageView view)
        => VkDescriptorImageInfo(imageView: view,
            imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    private void beginPass(VkRenderPass pass, VkFramebuffer framebuffer) @system
    {
        VkClearValue clear;
        const srgb = isSrgb(target_.format);
        float channel(ubyte c) => srgb ? srgbToLinear(c / 255.0f) : c / 255.0f;
        clear.color.float32 = target_.transparent ? [0.0f, 0, 0, 0]
            : [channel(ground_.r), channel(ground_.g), channel(ground_.b), 1.0f];
        const area = VkRect2D(VkOffset2D(0, 0), drawnExtent(target_));
        if (pass is null)
        {
            auto colour = vkInfo(VkRenderingAttachmentInfo(
                imageView: target_.view,
                imageLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                loadOp: VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR,
                storeOp: VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE,
                clearValue: clear,
            ));
            auto rendering = vkInfo(VkRenderingInfo(renderArea: area, layerCount: 1,
                colorAttachmentCount: 1, pColorAttachments: &colour));
            if (device_.cmdBeginRendering !is null)
                device_.cmdBeginRendering(commands_, &rendering);
            else
                device_.cmdBeginRenderingKHR(commands_, &rendering);
            return;
        }
        auto view = target_.view;
        auto attached = vkInfo(VkRenderPassAttachmentBeginInfo(attachmentCount: 1,
            pAttachments: &view));
        auto info = vkInfo(VkRenderPassBeginInfo(
            pNext: facts_.imagelessFramebuffer ? &attached : null,
            renderPass: pass,
            framebuffer: framebuffer,
            renderArea: area,
            clearValueCount: 1,
            pClearValues: &clear,
        ));
        device_.cmdBeginRenderPass(commands_, &info, VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);
    }

    private void endPass() @system
    {
        if (!facts_.dynamicRendering)
            device_.cmdEndRenderPass(commands_);
        else if (device_.cmdEndRendering !is null)
            device_.cmdEndRendering(commands_);
        else
            device_.cmdEndRenderingKHR(commands_);
    }

    // Abandons the frame for `r`: a lost device stays lost; exhausted memory
    // releases the caches, so the next frame starts from less (`UVK34`).
    private VkExpected!T fail(T)(VkResult r) @system
    {
        uploads_.discard();
        placeholderStaged_ = false;
        // The discarding above may drop atlas uploads `stageAtlas` staged
        // this frame; the atlas must not keep believing they landed.
        atlas_.markUnstaged();
        if (r == VkResult.VK_ERROR_DEVICE_LOST)
            lost_ = true;
        else if (r == VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY
            || r == VkResult.VK_ERROR_OUT_OF_HOST_MEMORY)
        {
            // Nothing of this frame will be submitted. Retire every cache,
            // including replacement atlas images from the failed upload.
            releaseCaches();
        }
        return err!T(r);
    }
}

/// The stage and access that read an image in `layout` after the canvas.
private void readersOf(VkImageLayout layout, out VkPipelineStageFlags stage,
    out VkAccessFlags access) @safe pure nothrow @nogc
{
    with (VkImageLayout) switch (layout)
    {
        case VK_IMAGE_LAYOUT_PRESENT_SRC_KHR:
            stage = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
            access = 0;
            break;
        case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
            stage = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT;
            access = VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT;
            break;
        case VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL:
            stage = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            access = VkAccessFlagBits.VK_ACCESS_SHADER_READ_BIT;
            break;
        default:
            stage = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            access = VkAccessFlagBits.VK_ACCESS_MEMORY_READ_BIT
                | VkAccessFlagBits.VK_ACCESS_MEMORY_WRITE_BIT;
            break;
    }
}

// `UVK1`: a canvas, with every optional method, so the interpreter hands it
// every operation.
static assert(isCanvas!(VulkanCanvas!DeviceMemoryBackend));
static foreach (method; ["textRunIn", "rule", "scrollbar", "image", "pushClip", "popClip",
        "pushShift", "popShift", "pushEffect", "popEffect"])
    static assert(__traits(hasMember, VulkanCanvas!DeviceMemoryBackend, method));

// The cell font as the canvas draws with it: the bytes it borrows, the face,
// its character map, and the instance at the cell size.
private struct CellFace
{
    import sparkles.font : CharMap, Face, Instance, LightHints, Ppem;

    const(ubyte)[] bytes;
    Face face;
    CharMap map;
    Instance inst;
    Ppem ppem;
    uint serial; // the atlas's key for this face
    bool colour; // it has colour forms (`COLR`, `CBDT`, `sbix`): asked for them first
    LightHints hints; // its light-hinting metrics at `ppem`
    ulong contentHash; // of `bytes`, taken while they are known to live
    private HintScratch scratch;

    // `bytes` at `ppem`, or `CellFace.init` when they hold no usable face.
    static CellFace open(const(ubyte)[] bytes, Ppem size, uint index = 0,
        scope const(UserCoordinate)[] coordinates = null, CellFace* previous = null,
        ulong knownHash = 0) @system
    {
        import sparkles.font : charMap, fontOk, instance, InstanceSize, openFace;

        if (!bytes.length)
            return CellFace.init;
        const reusable = previous !is null && previous.bytes.ptr == bytes.ptr
            && previous.bytes.length == bytes.length && previous.face.index == index
            && (!knownHash || previous.contentHash == knownHash);
        auto face = reusable ? fontOk(previous.face) : openFace(bytes, index);
        if (face.hasError)
            return CellFace.init;
        auto map = charMap(face.value);
        if (map.hasError)
            return CellFace.init;
        auto inst = instance(face.value, InstanceSize.pixels(size), coordinates);
        if (inst.hasError)
            return CellFace.init;
        import sparkles.font : lightHints, OutlinePoint, OutlineSegment, OutlineWorkspace;

        auto scratch = reusable ? previous.scratch : HintScratch.init;
        scratch.reserve();
        auto ws = scratch.workspace();
        const hints = lightHints(inst.value, map.value, size, scratch.segments, ws);
        auto opened = CellFace(bytes, face.value, map.value, inst.value, size, 0,
            hasColourGlyphs(face.value), hints);
        opened.contentHash = reusable ? previous.contentHash : knownHash ? knownHash : contentHashOf(bytes);
        opened.scratch = scratch;
        return opened;
    }
}

/**
The coordinate that instances `face` bold on its weight axis: `wght` 700, or
the axis's heaviest where that is lighter. False — `wght` left untouched —
where the face has no weight axis, or none heavier than its default.
*/
bool boldOnWeightAxis(scope const Face face, out UserCoordinate weight)
    @safe pure nothrow @nogc
{
    enum int bold = 700 << 16; // 16.16, as `fvar` records its axes
    foreach (a; axes(face))
    {
        if (a.hasError)
            return false;
        const v = a.value;
        if (v.axisTag != Tag("wght"))
            continue;
        const target = bold < v.maxValue ? bold : v.maxValue;
        if (target <= v.defaultValue)
            return false;
        weight = UserCoordinate(Tag("wght"), target);
        return true;
    }
    return false;
}

///
@("ui_vulkan.canvas.boldOnWeightAxis")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : openFace, Tag;

    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    UserCoordinate w;
    // Noto Sans ships variable (wght 100–900): bold is its 700 instance.
    const variable = cast(const(ubyte)[]) read(dir.buildPath("NotoSans.ttf"));
    assert(boldOnWeightAxis(openFace(variable).value, w));
    assert(w.tag == Tag("wght") && w.value == 700 << 16);
    // A static face has no axis to instance.
    const fixed = cast(const(ubyte)[]) read(dir.buildPath("Roboto-Regular.ttf"));
    assert(!boldOnWeightAxis(openFace(fixed).value, w));
}

private struct HintScratch
{
    import sparkles.font : OutlinePoint, OutlineSegment, OutlineWorkspace;
    OutlineSegment[] segments;
    OutlinePoint[] points;
    bool[] onCurve;
    ushort[] ends;
    uint[] numbers;
    int[] dx, dy;
    int[2][] referenced;

    void reserve() @safe nothrow
    {
        if (segments.length)
            return;
        segments = new OutlineSegment[4096];
        points = new OutlinePoint[4096];
        onCurve = new bool[4096];
        ends = new ushort[1024];
        numbers = new uint[4096];
        dx = new int[4096];
        dy = new int[4096];
        referenced = new int[2][4096];
    }

    OutlineWorkspace workspace() @safe pure nothrow @nogc
        => OutlineWorkspace(points, onCurve, ends, numbers, dx, dy, referenced);
}

/// Rebinding only coordinates reuses byte identity and decoding scratch.
@("ui_vulkan.canvas.specimenPreparedFaceReusesScratch")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : Tag;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const bytes = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    const size = Ppem.fromInteger(24).value;
    auto initial = CellFace.open(bytes, size);
    assert(initial.bytes.length);
    auto changed = CellFace.open(bytes, size, 0,
        [UserCoordinate(Tag("wght"), 900 << 16)], &initial);
    assert(changed.bytes.ptr == initial.bytes.ptr);
    assert(changed.contentHash == initial.contentHash);
    assert(changed.scratch.segments.ptr == initial.scratch.segments.ptr);
    assert(changed.inst.coords != initial.inst.coords);
    assert(!CellFace.open(bytes, size, uint.max).bytes.length);
}

/// Large forward/reverse size sweeps retain the complete mixed prepared and
/// synchronous run, including the lowercase continuation from the specimen.
@("ui_vulkan.canvas.largeSizeSweepPreservesEveryGlyph")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font.cluster_shaping : ClusterDirection;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const latin = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    const glag = cast(const(ubyte)[]) read(buildPath(root, "NotoSansGlagolitic-Regular.otf"));
    foreach (workers; [1u, 2u, 4u])
    {
        VulkanCanvas!DeviceMemoryBackend canvas;
        scope (exit)
        {
            canvas.atlas_.stopPreparation();
            foreach (ref slot; canvas.shapers_) slot.release();
        }
        assert(canvas.cellFont(latin, 24, TextMetrics(ascent: 18)));
        uint[11] cps = [0x2C00, 0x2C01, 0x2C02, 0x2C03, 0x2C04, ' ',
            0x2C30, 0x2C31, 0x2C32, 0x2C33, 0x2C34];
        foreach (step; 0 .. 258)
        {
            const px = cast(uint)(step < 129 ? 256 + step : 513 - step);
            // This is the atlas reset performed by beginFrame, without a GPU.
            if (canvas.atlas_.overflowed) canvas.atlas_.reset();
            canvas.atlas_.beginFrame();
            const size = Ppem.fromInteger(px).value;
            FallbackFace[1] extras = [FallbackFace(glag, size)];
            assert(canvas.specimenFont(latin, 0, size, null, TextMetrics(ascent: px),
                0, 0, null, null, null, extras[]));
            assert(canvas.beginSpecimen(px, px * 2));
            canvas.beginGlyphPreparation(workers);

            GlyphQuad[64] quads;
            size_t count;
            double[2] measured;
            foreach (run; 0 .. 2)
                assert(canvas.resolveCluster(ClusterRequest(cps[run == 0 ? 0 : 6 .. run == 0 ? 5 : 11],
                    GlyphRequest(cps[run == 0 ? 0 : 6]), &measured[run], true,
                    ClusterDirection.ltr), quads[], count) == GlyphOutcome.drawn);
            canvas.finishGlyphPreparation();
            foreach (run; 0 .. 2)
            {
                double drawn;
                const outcome = canvas.resolveCluster(ClusterRequest(cps[run == 0 ? 0 : 6 .. run == 0 ? 5 : 11],
                    GlyphRequest(cps[run == 0 ? 0 : 6]), &drawn, false,
                    ClusterDirection.ltr), quads[], count);
                import std.conv : text;
                assert(outcome == GlyphOutcome.drawn && count == 5 && measured[run] == drawn,
                    text("size ", px, ", run ", run, ": ", outcome, ", glyphs ", count,
                        ", advances ", measured[run], " / ", drawn));
            }
            canvas.endSpecimen();

        }
    }
}

/// Script fallbacks beyond the former eight-face limit shape normally.
@("ui_vulkan.canvas.resolvedDirectionMirrorsBrackets")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font.cluster_shaping : ClusterDirection, ClusterGlyph, shapeCluster;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const latin = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    VulkanCanvas!DeviceMemoryBackend canvas;
    scope (exit) foreach (ref slot; canvas.shapers_) slot.release();
    assert(canvas.cellFont(latin, 24, TextMetrics(ascent: 18)));
    auto face = &canvas.faces_[FaceStyle.regular];
    auto shaper = canvas.shaperFor(face);
    assert(shaper !is null);
    ClusterGlyph[64] glyphs;
    assert(shapeCluster(shaper, "(", 24, 1, glyphs[], ClusterDirection.ltr) == 1);
    assert(glyphs[0].glyph == face.map.glyph('('));
    assert(shapeCluster(shaper, "(", 24, 1, glyphs[], ClusterDirection.rtl) == 1);
    assert(glyphs[0].glyph == face.map.glyph(')'), "RTL mirroring belongs to shaping");
}

/// Script fallbacks beyond the former eight-face limit shape normally.
@("ui_vulkan.canvas.textPresentationPrefersOutlineFallback")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const latin = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    const emoji = cast(const(ubyte)[]) read(buildPath(root, "NotoColorEmoji.ttf"));
    const symbols = cast(const(ubyte)[]) read(buildPath(root, "DejaVuSansMono.ttf"));
    const size = Ppem.fromInteger(24).value;
    VulkanCanvas!DeviceMemoryBackend canvas;
    scope (exit) foreach (ref slot; canvas.shapers_) slot.release();
    assert(canvas.cellFont(latin, 24, TextMetrics(ascent: 18)));
    FallbackFace[2] extras = [FallbackFace(emoji, size), FallbackFace(symbols, size)];
    assert(canvas.specimenFont(latin, 0, size, null, TextMetrics(ascent: 18),
        0, 0, null, null, null, extras[]));
    assert(canvas.beginSpecimen(14, 30));
    scope (exit) canvas.endSpecimen();
    assert(!canvas.orderedFace(GlyphRequest(0x2764), 1).colour);
    assert(canvas.orderedFace(GlyphRequest(0x2764, FaceStyle.regular, true), 0).colour);
    uint[2] text = [0x2764, 0xFE0E];
    GlyphQuad[64] quads;
    size_t count;
    double advance;
    assert(canvas.resolveCluster(ClusterRequest(text[], GlyphRequest(0x2764), &advance, true),
        quads[], count) == GlyphOutcome.drawn);
    assert(advance > 0);
}

/// Script fallbacks beyond the former eight-face limit shape normally.
@("ui_vulkan.canvas.specimenScriptFallbackBeyondEightFaces")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const latin = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    const arabic = cast(const(ubyte)[]) read(buildPath(root, "NotoSansArabic.ttf"));
    const size = Ppem.fromInteger(24).value;
    VulkanCanvas!DeviceMemoryBackend canvas;
    scope (exit) foreach (ref slot; canvas.shapers_) slot.release();
    assert(canvas.cellFont(latin, 24, TextMetrics(ascent: 18)));
    FallbackFace[9] extras;
    foreach (ref extra; extras[]) extra = FallbackFace(latin, size);
    extras[$ - 1] = FallbackFace(arabic, size);
    assert(canvas.specimenFont(latin, 0, size, null, TextMetrics(ascent: 18),
        0, 0, null, null, null, extras[]));
    assert(canvas.beginSpecimen(14, 30));
    scope (exit) canvas.endSpecimen();
    uint[4] text = [0x0633, 0x0644, 0x0627, 0x0645];
    GlyphQuad[64] quads;
    size_t count;
    double advance;
    assert(canvas.resolveCluster(ClusterRequest(text[], GlyphRequest(0x0633), &advance, true),
        quads[], count) == GlyphOutcome.drawn);
    assert(advance > 0);
    uint[2] variation = ['a', 0xE0100];
    assert(canvas.resolveCluster(ClusterRequest(variation[], GlyphRequest('a'), &advance, true),
        quads[], count) == GlyphOutcome.drawn,
        "supplementary variation selectors do not require standalone glyphs");
}

/// Inspection reuses the rendering face order and cached clusters, including
/// RTL fallbacks and missing glyphs, without touching raster or atlas state.
@("ui_vulkan.canvas.inspectionReportsServingFaceAndSource")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const latin = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    const glag = cast(const(ubyte)[]) read(buildPath(root, "NotoSansGlagolitic-Regular.otf"));
    const arabic = cast(const(ubyte)[]) read(buildPath(root, "NotoSansArabic.ttf"));
    const size = Ppem.fromInteger(24).value;
    VulkanCanvas!DeviceMemoryBackend canvas;
    scope (exit) foreach (ref slot; canvas.shapers_) slot.release();
    assert(canvas.cellFont(latin, 24, TextMetrics(ascent: 18)));
    FallbackFace[2] extras = [FallbackFace(glag, size), FallbackFace(arabic, size)];
    assert(canvas.specimenFont(latin, 0, size, null, TextMetrics(ascent: 18),
        0, 0, null, null, null, extras[]));
    assert(canvas.beginSpecimen(14, 30));
    scope (exit) canvas.endSpecimen();
    const a = canvas.inspectTextPx("ab", 0);
    assert(a.found && a.shaped && !a.fallback && a.glyph
        && a.start == 0 && a.end == 1 && a.advance > 0);
    const b = canvas.inspectTextPx("ab", a.advance + 0.01);
    assert(b.found && b.start == 1 && b.end == 2 && b.glyph != a.glyph);
    const combining = canvas.inspectTextPx("q\u0301", 0);
    assert(combining.found && combining.start == 0 && combining.end == 3
        && combining.glyphs.length == 2, "zero-advance marks remain inspectable with their base");
    const historic = canvas.inspectTextPx("ⰀⰁ", 0);
    assert(historic.found && historic.fallback && historic.faceName.canFind("Glagolitic")
        && historic.start == 0 && historic.end == 3 && historic.faceSerial != a.faceSerial);
    const rtl = canvas.inspectTextPx("سلام", 0, false, false, ClusterDirection.rtl);
    assert(rtl.found && rtl.fallback && rtl.faceName.canFind("Arabic")
        && rtl.start < rtl.end && rtl.end <= "سلام".length);
    assert(!canvas.inspectTextPx("ab", -1).found && !canvas.inspectTextPx("ab", 1000).found);
    canvas.specimenTextRendering(TextRendering(shaping: false));
    const grid = canvas.inspectTextPx("Ⰰ", 0);
    assert(grid.found && !grid.shaped && grid.fallback && grid.glyph == historic.glyph);
    const missing = canvas.inspectTextPx("\U0010FFFF", 0);
    assert(missing.found && !missing.glyph && !missing.fallback);
    assert(canvas.atlas_.length == 0, "inspection never requests raster tiles");
}

/// Measurement and painting share runs, while coordinate changes select fresh data.
@("ui_vulkan.canvas.preparedRunsFollowFontInstance")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    import sparkles.font : Tag;
    const bytes = cast(const(ubyte)[]) read(buildPath(environment.get("SPARKLES_FONTS_PATH"), "NotoSans.ttf"));
    VulkanCanvas!DeviceMemoryBackend canvas;
    scope (exit) foreach (ref slot; canvas.shapers_) slot.release();
    const size = Ppem.fromInteger(24).value;
    assert(canvas.cellFont(bytes, 24, TextMetrics(ascent: 18)));
    uint[3] text = ['a', 'b', 'c'];
    double advance;
    GlyphQuad[64] quads;
    size_t count;
    auto request = ClusterRequest(text[], GlyphRequest('a'), &advance, true);
    assert(canvas.resolveCluster(request, quads[], count) == GlyphOutcome.drawn);
    const measured = advance;
    assert(measured > 0 && canvas.preparedRuns_.misses == 1);
    request.measureOnly = false;
    assert(canvas.resolveCluster(request, quads[], count) == GlyphOutcome.drawn);
    assert(advance == measured && count == 3 && canvas.preparedRuns_.hits == 1);
    assert(canvas.specimenFont(bytes, 0, size, [UserCoordinate(Tag("wght"), 900 << 16)],
        TextMetrics(ascent: 18)));
    assert(canvas.beginSpecimen(14, 30));
    request.measureOnly = true;
    assert(canvas.resolveCluster(request, quads[], count) == GlyphOutcome.drawn);
    assert(canvas.preparedRuns_.misses == 2 && advance != measured);
    canvas.endSpecimen();
    assert(canvas.resolveCluster(request, quads[], count) == GlyphOutcome.drawn);
    assert(advance == measured && canvas.preparedRuns_.hits == 2);
}

/// Independent preview scopes restore the interface binding, even after failure.
@("ui_vulkan.canvas.specimenScopeRestoresInterface")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;
    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const bytes = cast(const(ubyte)[]) read(buildPath(root, "NotoSans.ttf"));
    VulkanCanvas!DeviceMemoryBackend canvas;
    assert(canvas.cellFont(bytes, 18, TextMetrics(ascent: 14)));
    assert(!canvas.beginSpecimen(10, 24));
    canvas.endSpecimen();
    assert(canvas.specimenFont(bytes, 0, Ppem.fromInteger(30).value, null,
        TextMetrics(ascent: 23)));
    auto previewRendering = TextRendering.init;
    previewRendering.contrast = 0.8f;
    previewRendering.hinting = Hinting.none;
    canvas.specimenTextRendering(previewRendering);
    assert(canvas.beginSpecimen(17, 40));
    assert(!canvas.beginSpecimen(17, 40));
    assert(canvas.faces_[0].ppem == Ppem.fromInteger(30).value);
    assert(canvas.painter_.metrics.cellW == 17 && canvas.textMetrics_.ascent == 23);
    assert(canvas.textRendering == previewRendering);
    canvas.endSpecimen();
    assert(canvas.faces_[0].ppem == Ppem.fromInteger(18).value);
    assert(canvas.textMetrics_.ascent == 14 && canvas.painter_.metrics.cellW == 1);
    assert(canvas.textRendering == TextRendering.init);
}

// The straight RGBA of a run's colour as the bytes colour layers take for
// the foreground.
private Colour foregroundOf(vec4 c) @safe pure nothrow @nogc
{
    static ubyte b(float x) => cast(ubyte)(x <= 0 ? 0 : x >= 1 ? 255 : x * 255 + 0.5f);
    return Colour(b(c.x), b(c.y), b(c.z), b(c.w));
}

// A face's identity by content (FNV-1a): two binds of the same bytes keep
// one atlas serial, and different bytes at a recycled address do not.
private ulong contentHashOf(scope const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    ulong h = 0xcbf2_9ce4_8422_2325;
    foreach (b; bytes)
    {
        h ^= b;
        h *= 0x0000_0100_0000_01b3;
    }
    return h;
}

@("ui_vulkan.canvas.contentHashOfDistinguishesBytes")
@safe pure nothrow @nogc unittest
{
    assert(contentHashOf(cast(const(ubyte)[]) "face") == contentHashOf(cast(const(ubyte)[]) "face"));
    assert(contentHashOf(cast(const(ubyte)[]) "face") != contentHashOf(cast(const(ubyte)[]) "facc"));
    assert(contentHashOf(cast(const(ubyte)[]) "face") != contentHashOf(cast(const(ubyte)[]) "faces"));
    assert(contentHashOf(null) != 0, "the empty face is nobody's hash by accident");
}

// `ppem` scaled by `a / b`, exactly.
private auto scaledPpem(Ppem ppem, ulong a, ulong b) @safe pure nothrow @nogc
{
    import sparkles.base.text.layout_units : I128, Rational, U128;

    return Ppem.fromRational(Rational(I128(U128(ppem.numerator * a, 0)), U128(ppem.denominator * b, 0)));
}

static if (canShape)
{
    // One face's shaper, through `sparkles.font.cluster_shaping`, whose narrow
    // interface keeps the engine's modules out of this build (see there).
    private struct ShaperSlot
    {
        import sparkles.font : Instance;
        import sparkles.font.cluster_shaping : closeClusterShaper, ClusterShaper, openClusterShaper,
            reinstanceClusterShaper;

        uint serial;
        ClusterShaper* handle;
        bool tried; // made, or found the engine unable to shape this face
        Instance instance;

        void make(uint s, in Instance inst) @system
        {
            handle = openClusterShaper(&inst);
            serial = s;
            tried = true;
            instance = inst;
        }

        void update(in Instance inst) @system
        {
            if (instance.size == inst.size && instance.coords == inst.coords) return;
            if (!reinstanceClusterShaper(handle, &inst))
            {
                const previous = serial;
                release();
                make(previous, inst);
            }
            else instance = inst;
        }

        void release() @system
        {
            closeClusterShaper(handle);
            handle = null;
            tried = false;
        }
    }
}
