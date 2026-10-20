/**
Per-frame buffer space: a `VkBuffer` over each range of a `FrameArena`.

The frame arena of `sparkles:vulkan` hands out device memory; a copy or a
vertex fetch needs a buffer over it. `FrameBuffers` binds one buffer to each
of the arena's ranges, the first per slot when it is created and an extra
range's on first use, so a per-frame allocation becomes a buffer and an
offset into it (`UVK28`). A slot's extra buffers are destroyed before its
extra ranges are freed.
*/
module sparkles.ui_vulkan.frame_buffers;

import expected : err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.vulkan;

/// Space in a frame slot's buffer: the buffer, the offset into it, and the
/// mapped bytes.
struct BufferSlice
{
    VkBuffer buffer;     ///
    ulong offset;        ///
    ubyte[] host;        /// the slice's mapped bytes
    DeviceRegion region; /// its memory, for `DeviceMemory.flush`
}

/// Buffers over a `FrameArena`'s ranges, for `usage`.
struct FrameBuffers(B)
{
    private static struct Bound
    {
        uint slot;
        uint range; // the arena's range number
        VkBuffer buffer;
    }

    private DeviceCommands* device_;
    private FrameArena!B* arena_;
    private VkBufferUsageFlags usage_;
    private UniqueBuffer!Bound bound_;

    @disable this(this);

    ~this()
    {
        destroy();
    }

    /**
    Buffers over every first range of `arena`, which, like `device`, must
    outlive this and not move.
    */
    static VkExpected!() create(out FrameBuffers buffers, ref DeviceCommands device,
        ref FrameArena!B arena, uint slots, VkBufferUsageFlags usage) @system
    {
        buffers.device_ = &device;
        buffers.arena_ = &arena;
        buffers.usage_ = usage;
        foreach (uint slot; 0 .. slots)
        {
            VkBuffer buffer;
            auto r = buffers.bind(slot, 0, buffer);
            if (r < 0)
            {
                buffers.destroy();
                return err!void(r);
            }
        }
        return ok!VkResult();
    }

    /// `size` bytes at a multiple of `alignment` in `slot`'s buffers.
    VkExpected!BufferSlice allocate(uint slot, ulong size, ulong alignment) @system
    {
        uint range;
        auto region = arena_.allocate(slot, size, alignment, range);
        if (region.hasError)
            return err!BufferSlice(region.error);
        VkBuffer buffer;
        auto r = bind(slot, range, buffer);
        if (r < 0)
            return err!BufferSlice(r);
        const start = arena_.rangeRegion(slot, range).offset;
        return ok!VkResult(BufferSlice(buffer, region.value.offset - start,
            region.value.host, region.value));
    }

    /// Destroys `slot`'s extra buffers, then resets its arena slot.
    void reset(uint slot) @system
    {
        size_t i;
        while (i < bound_.length)
        {
            auto b = bound_[][i];
            if (b.slot != slot || b.range == 0)
            {
                ++i;
                continue;
            }
            device_.destroyBuffer(device_.device, b.buffer, null);
            auto items = bound_[];
            items[i] = items[$ - 1];
            bound_.popBack();
        }
        arena_.reset(slot);
    }

    /// Destroys every buffer; the arena keeps its memory. Idempotent.
    void destroy() @system
    {
        if (device_ is null)
            return;
        foreach (ref b; bound_[])
            device_.destroyBuffer(device_.device, b.buffer, null);
        bound_.clear();
        device_ = null;
    }

    // The buffer over `slot`'s range `range`, made and bound on first use.
    private VkResult bind(uint slot, uint range, out VkBuffer buffer) @system
    {
        foreach (ref b; bound_[])
            if (b.slot == slot && b.range == range)
            {
                buffer = b.buffer;
                return VkResult.VK_SUCCESS;
            }
        auto whole = arena_.rangeRegion(slot, range);
        auto info = vkInfo(VkBufferCreateInfo(size: whole.size, usage: usage_,
            sharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE));
        auto r = device_.createBuffer(device_.device, &info, null, &buffer);
        if (r < 0)
            return r;
        VkMemoryRequirements needs;
        device_.getBufferMemoryRequirements(device_.device, buffer, &needs);
        // The arena chose its memory before any buffer existed; a buffer it
        // cannot back is a configuration the caller has to change.
        if (!(needs.memoryTypeBits & (1u << whole.memoryType)) || whole.offset % needs.alignment
            || needs.size > whole.size)
        {
            device_.destroyBuffer(device_.device, buffer, null);
            return VkResult.VK_ERROR_FEATURE_NOT_PRESENT;
        }
        r = device_.bindBufferMemory(device_.device, buffer, whole.memory, whole.offset);
        if (r < 0)
        {
            device_.destroyBuffer(device_.device, buffer, null);
            return r;
        }
        bound_.put(Bound(slot, range, buffer));
        return VkResult.VK_SUCCESS;
    }
}
