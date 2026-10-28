/**
Device memory: a sub-allocator over a few large `VkDeviceMemory` allocations.

Drivers cap the live allocations of a device (`maxMemoryAllocationCount`,
often 4096) and each allocation is slow, so buffers and images get regions of
a few large allocations instead of one each. The bookkeeping lives in CPU
memory: device memory is usually not visible to the CPU at all.

The allocator has the shape of `std.experimental.allocator`'s untyped
protocol — `allocate`, `alignedAllocate`, `deallocate`, `owns`,
`deallocateAll`, `goodAllocSize`, `Ternary` answers — but hands out
$(LREF DeviceRegion)s, a device allocation and an offset, instead of host
pointers. It talks to the driver through a backend ($(LREF isMemoryBackend)):
$(LREF DeviceMemoryBackend) over a real device, or a fake in tests.

$(UL
$(LI Long-lived objects get whole blocks of a power-of-two size, tracked by a
    bitmap per device allocation. A block is at least as large as any
    alignment a pool accepts, so a block's offset satisfies the alignment
    by construction.)
$(LI Buffers and optimally tiled images live in separate pools, so
    `bufferImageGranularity` never constrains a placement.)
$(LI A pool keeps one empty device allocation spare: freeing every empty one
    makes a region created and freed at an allocation's boundary call the
    driver every time.)
$(LI Host-visible allocations are mapped once, for their whole life.)
$(LI Per-frame data comes from a $(LREF FrameArena).))

The contract is `docs/specs/vulkan/memory.md` (`VKM1`–`VKM13`).
*/
module sparkles.vulkan.memory;

import core.memory : pureFree, pureMalloc;
import std.typecons : Ternary;

import expected : err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.vulkan.dispatch : DeviceCommands, InstanceCommands;
import sparkles.vulkan.result : VkExpected;
import sparkles.vulkan.structure_type : vkInfo;
import sparkles.vulkan.vulkan_c;

/// How a resource's memory is laid out, which decides its pool (`VKM5`).
enum Tiling : ubyte
{
    linear,  /// buffers, and linearly tiled images
    optimal, /// optimally tiled images
}

/// Whether a resource wants a device allocation of its own (`VKM8`).
enum Dedication : ubyte
{
    none,      ///
    preferred, /// `prefersDedicatedAllocation`
    required,  /// `requiresDedicatedAllocation`
}

/// What a resource needs: its memory requirements and the properties wanted.
struct MemoryRequest
{
    ulong size;                         /// bytes
    ulong alignment = 1;                /// a power of two
    uint typeBits = uint.max;           /// `VkMemoryRequirements.memoryTypeBits`
    VkMemoryPropertyFlags required;     /// properties the type must have
    VkMemoryPropertyFlags preferred;    /// properties the type should have
    Tiling tiling;                      ///
    Dedication dedication;              ///
}

/**
A region of device memory: the allocation, an offset into it, a size, and,
for host-visible memory, the mapped bytes of exactly the region.
*/
struct DeviceRegion
{
    VkDeviceMemory memory; ///
    ulong offset;          ///
    ulong size;            ///
    /// The region's mapped bytes; `null` for memory the host cannot see.
    ubyte[] host;

    package uint typeIndex = uint.max;
    package bool dedicated;

    /// The memory type the region lies in.
    uint memoryType() const @safe pure nothrow @nogc => typeIndex;

    /// `false` for `DeviceRegion.init`.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => memory !is null;
}

/// The allocator's sizes. Both are powers of two.
struct MemoryConfig
{
    /// The placement grid: every pooled region starts on a block.
    ulong blockSize = 64 * 1024;
    /// The size of each device allocation a pool adds.
    ulong allocationSize = 32 * 1024 * 1024;
}

/// Per memory type (`VKM12`).
struct TypeStats
{
    uint allocations;    /// live device allocations
    ulong allocatedBytes; /// bytes allocated from the driver
    ulong liveBytes;     /// bytes in live regions
}

/**
The driver operations the allocator needs, so a test can stand in for a
device. Every result is a `VkResult`; `map` maps a whole allocation.
*/
enum bool isMemoryBackend(B) = __traits(compiles, (ref B b) {
    VkPhysicalDeviceMemoryProperties p = b.memoryProperties;
    ulong atom = b.nonCoherentAtomSize;
    uint limit = b.maxAllocationCount;
    VkDeviceMemory m;
    VkResult r = b.allocate(0u, ulong(1), m);
    void* host;
    r = b.map(m, host);
    r = b.flush(m, ulong(0), ulong(1));
    b.unmap(m);
    b.free(m);
});

/// The real backend: one device's memory commands and limits.
struct DeviceMemoryBackend
{
    private DeviceCommands* device_;
    // `= void`: filled by the constructor. DMD otherwise references an
    // initializer symbol for the ImportC struct that it never emits.
    private VkPhysicalDeviceMemoryProperties properties_ = void;
    private ulong atom_;
    private uint limit_;

    /// Reads the physical device's memory table and limits.
    this(ref const InstanceCommands instance, VkPhysicalDevice physical,
        ref DeviceCommands device) @system nothrow @nogc
    {
        device_ = &device;
        instance.getPhysicalDeviceMemoryProperties(physical, &properties_);
        VkPhysicalDeviceProperties properties = void;
        instance.getPhysicalDeviceProperties(physical, &properties);
        atom_ = properties.limits.nonCoherentAtomSize;
        limit_ = properties.limits.maxMemoryAllocationCount;
    }

    ///
    ref const(VkPhysicalDeviceMemoryProperties) memoryProperties() const return
        @safe pure nothrow @nogc => properties_;
    ///
    ulong nonCoherentAtomSize() const @safe pure nothrow @nogc => atom_;
    ///
    uint maxAllocationCount() const @safe pure nothrow @nogc => limit_;

    ///
    VkResult allocate(uint typeIndex, ulong size, out VkDeviceMemory memory)
        @system nothrow @nogc
    {
        auto info = vkInfo(VkMemoryAllocateInfo(allocationSize: size, memoryTypeIndex: typeIndex));
        return device_.allocateMemory(device_.device, &info, null, &memory);
    }

    ///
    void free(VkDeviceMemory memory) @system nothrow @nogc
    {
        device_.freeMemory(device_.device, memory, null);
    }

    ///
    VkResult map(VkDeviceMemory memory, out void* host) @system nothrow @nogc
        => device_.mapMemory(device_.device, memory, 0, VK_WHOLE_SIZE, 0, &host);

    ///
    void unmap(VkDeviceMemory memory) @system nothrow @nogc
    {
        device_.unmapMemory(device_.device, memory);
    }

    ///
    VkResult flush(VkDeviceMemory memory, ulong offset, ulong size) @system nothrow @nogc
    {
        auto range = vkInfo(VkMappedMemoryRange(memory: memory, offset: offset, size: size));
        return device_.flushMappedMemoryRanges(device_.device, 1, &range);
    }
}

static assert(isMemoryBackend!DeviceMemoryBackend);

private enum hostVisible = VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
private enum hostCoherent = VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

/// One device allocation of a pool, and the bitmap of its blocks.
private struct Chunk
{
    VkDeviceMemory memory;
    ulong size;
    ubyte* mapped;
    uint blocks;
    uint freeBlocks;
    ulong* bitmap; // bit set = block in use; `pureMalloc`'d, one bit per block
}

/// A dedicated allocation: one region, one device allocation.
private struct Dedicated
{
    VkDeviceMemory memory;
    ulong size;
    uint typeIndex;
    ubyte* mapped;
}

/// A live region, recorded in debug builds for `destroy`'s report (`VKM13`).
private struct LiveRegion
{
    VkDeviceMemory memory;
    ulong offset;
    ulong size;
}

/**
The sub-allocator, over a backend `B` (`VKM1`–`VKM13`).

Not copyable: it owns its device allocations. `destroy` frees them; a live
region at that point is a programmer error.
*/
struct DeviceMemory(B)
if (isMemoryBackend!B)
{
    private B backend_;
    private MemoryConfig config_;
    private UniqueBuffer!Chunk[2][VK_MAX_MEMORY_TYPES] pools_;
    private UniqueBuffer!Dedicated dedicated_;
    private TypeStats[VK_MAX_MEMORY_TYPES] stats_;
    private uint liveAllocations_;
    debug private UniqueBuffer!LiveRegion live_;

    @disable this(this);

    /// Takes the backend and the sizes; allocates nothing yet.
    this(B backend, MemoryConfig config = MemoryConfig.init)
    in (config.blockSize && !(config.blockSize & (config.blockSize - 1)),
        "the block size must be a power of two")
    in (config.allocationSize >= config.blockSize
        && config.allocationSize % config.blockSize == 0,
        "the allocation size must be a whole number of blocks")
    {
        backend_ = backend;
        config_ = config;
    }

    ~this()
    {
        destroy();
    }

    /// The backend, for the caller that also creates resources on it.
    ref inout(B) backend() inout return => backend_;

    /// The memory type for `request`, or `uint.max` when none fits (`VKM2`).
    uint chooseType(in MemoryRequest request) const
    {
        const props = &backend_.memoryProperties();
        uint fallback = uint.max;
        foreach (uint i; 0 .. props.memoryTypeCount)
        {
            if (!(request.typeBits & (1u << i)))
                continue;
            const flags = props.memoryTypes[i].propertyFlags;
            if ((flags & request.required) != request.required)
                continue;
            if ((flags & request.preferred) == request.preferred)
                return i;
            if (fallback == uint.max)
                fallback = i;
        }
        return fallback;
    }

    /// `allocate` with the request's own alignment (`VKM1`).
    VkExpected!DeviceRegion allocate(in MemoryRequest request)
        => alignedAllocate(request, request.alignment);

    /**
    A region of `request.size` bytes whose offset is a multiple of
    `alignment`, in a memory type `request` admits (`VKM1`, `VKM2`, `VKM4`–
    `VKM8`, `VKM11`).
    */
    VkExpected!DeviceRegion alignedAllocate(in MemoryRequest request, ulong alignment)
    in (request.size > 0, "an empty request")
    in (alignment && !(alignment & (alignment - 1)), "the alignment must be a power of two")
    {
        const type = chooseType(request);
        if (type == uint.max)
            return err!DeviceRegion(VkResult.VK_ERROR_FEATURE_NOT_PRESENT);
        if (request.dedication != Dedication.none || alignment > config_.blockSize)
            return allocateDedicated(request, type);

        const blocks = blocksFor(request.size);
        auto pool = &pools_[type][request.tiling];
        foreach (ref chunk; (*pool)[])
        {
            const first = findFree(chunk, blocks);
            if (first != uint.max)
                return place(chunk, type, first, blocks, request.size);
        }

        // Grow (`VKM6`): one more device allocation, of the pool's size or
        // of the request's, whichever is larger.
        const size = blocks * config_.blockSize > config_.allocationSize
            ? blocks * config_.blockSize : config_.allocationSize;
        Chunk chunk;
        auto made = newAllocation(type, size, chunk.memory, chunk.mapped);
        if (made < 0)
            return err!DeviceRegion(made);
        chunk.size = size;
        chunk.blocks = cast(uint)(size / config_.blockSize);
        chunk.freeBlocks = chunk.blocks;
        chunk.bitmap = newBitmap(chunk.blocks);
        if (chunk.bitmap is null)
        {
            releaseAllocation(type, chunk.memory, chunk.size, chunk.mapped);
            return err!DeviceRegion(VkResult.VK_ERROR_OUT_OF_HOST_MEMORY);
        }
        pool.put(chunk);
        return place((*pool)[][$ - 1], type, 0, blocks, request.size);
    }

    /**
    Returns `region`'s memory (`VKM7`, `VKM8`). A pool frees an emptied device
    allocation only while another empty one remains. `false` for a region this
    allocator does not own.
    */
    bool deallocate(ref DeviceRegion region)
    {
        if (!region)
            return true;
        scope (success)
            region = DeviceRegion.init;
        debug forgetLive(region);
        if (region.dedicated)
        {
            foreach (i, ref d; dedicated_[])
                if (d.memory is region.memory)
                {
                    releaseAllocation(d.typeIndex, d.memory, d.size, d.mapped);
                    stats_[d.typeIndex].liveBytes -= d.size;
                    removeAt(dedicated_, i);
                    return true;
                }
            return false;
        }
        foreach (tiling; 0 .. 2)
        {
            auto pool = &pools_[region.typeIndex][tiling];
            foreach (i, ref chunk; (*pool)[])
            {
                if (chunk.memory !is region.memory)
                    continue;
                const first = cast(uint)(region.offset / config_.blockSize);
                const blocks = blocksFor(region.size);
                setBits(chunk.bitmap, first, blocks, false);
                chunk.freeBlocks += blocks;
                stats_[region.typeIndex].liveBytes -= region.size;
                if (chunk.freeBlocks == chunk.blocks && emptyCount(*pool) >= 2)
                {
                    releaseChunk(region.typeIndex, chunk);
                    removeAt(*pool, i);
                }
                return true;
            }
        }
        return false;
    }

    /// Whether `region` is one of this allocator's live regions.
    Ternary owns(in DeviceRegion region) const
    {
        if (!region || region.typeIndex >= VK_MAX_MEMORY_TYPES)
            return Ternary.no;
        if (region.dedicated)
        {
            foreach (ref d; dedicated_[])
                if (d.memory is region.memory)
                    return Ternary.yes;
            return Ternary.no;
        }
        foreach (tiling; 0 .. 2)
            foreach (ref chunk; pools_[region.typeIndex][tiling][])
                if (chunk.memory is region.memory)
                    return region.offset + region.size <= chunk.size
                        ? Ternary.yes : Ternary.no;
        return Ternary.no;
    }

    /// `size` rounded up to whole blocks: what a pooled region occupies.
    ulong goodAllocSize(ulong size) const => blocksFor(size) * config_.blockSize;

    /// Frees every device allocation; every region becomes invalid.
    bool deallocateAll()
    {
        foreach (type; 0 .. VK_MAX_MEMORY_TYPES)
            foreach (tiling; 0 .. 2)
            {
                foreach (ref chunk; pools_[type][tiling][])
                    releaseChunk(cast(uint) type, chunk);
                pools_[type][tiling].clear();
            }
        foreach (ref d; dedicated_[])
            releaseAllocation(d.typeIndex, d.memory, d.size, d.mapped);
        dedicated_.clear();
        foreach (ref s; stats_)
            s.liveBytes = 0;
        debug live_.clear();
        return true;
    }

    /**
    Flushes `region`'s bytes to the device, widened to whole
    `nonCoherentAtomSize` units (`VKM9`). A no-op for coherent memory.
    */
    VkExpected!() flush(DeviceRegion region)
    {
        if (!region || !region.host.length || isCoherent(region.typeIndex))
            return ok!VkResult();
        const atom = backend_.nonCoherentAtomSize;
        const begin = region.offset / atom * atom;
        const end = (region.offset + region.size + atom - 1) / atom * atom;
        auto r = backend_.flush(region.memory, begin, end - begin);
        return r < 0 ? err!void(r) : ok!VkResult();
    }

    /// Statistics for memory type `type` (`VKM12`).
    TypeStats stats(uint type) const => stats_[type];

    /// Live device allocations, dedicated ones included (`VKM11`).
    uint liveAllocations() const => liveAllocations_;

    /**
    Frees every device allocation (`VKM13`). In debug builds, a region still
    live is reported with its size and offset.
    */
    void destroy()
    {
        debug
        {
            import core.stdc.stdio : fprintf, stderr;

            foreach (ref r; live_[])
                () @trusted {
                    fprintf(stderr, "sparkles.vulkan.memory: a region of %llu bytes at offset %llu is still live\n",
                        cast(ulong) r.size, cast(ulong) r.offset);
                }();
        }
        deallocateAll();
    }

    // ── internals ──────────────────────────────────────────────────────────

    debug private void forgetLive(in DeviceRegion region)
    {
        foreach (i, ref r; live_[])
            if (r.memory is region.memory && r.offset == region.offset)
            {
                removeAt(live_, i);
                return;
            }
    }

    private ulong blocksFor(ulong size) const
        => (size + config_.blockSize - 1) / config_.blockSize;

    private bool isCoherent(uint type) const
        => (backend_.memoryProperties().memoryTypes[type].propertyFlags & hostCoherent) != 0;

    private bool isHostVisible(uint type) const
        => (backend_.memoryProperties().memoryTypes[type].propertyFlags & hostVisible) != 0;

    private VkExpected!DeviceRegion place(ref Chunk chunk, uint type, uint first,
        ulong blocks, ulong size)
    {
        setBits(chunk.bitmap, first, blocks, true);
        chunk.freeBlocks -= cast(uint) blocks;
        DeviceRegion region;
        region.memory = chunk.memory;
        region.offset = first * config_.blockSize;
        region.size = size;
        region.typeIndex = type;
        if (chunk.mapped !is null)
            region.host = (() @trusted => chunk.mapped[region.offset .. region.offset + size])();
        stats_[type].liveBytes += size;
        debug live_.put(LiveRegion(region.memory, region.offset, region.size));
        return ok!VkResult(region);
    }

    private VkExpected!DeviceRegion allocateDedicated(in MemoryRequest request, uint type)
    {
        Dedicated d;
        d.size = request.size;
        d.typeIndex = type;
        auto made = newAllocation(type, request.size, d.memory, d.mapped);
        if (made < 0)
            return err!DeviceRegion(made);
        dedicated_.put(d);
        DeviceRegion region;
        region.memory = d.memory;
        region.size = request.size;
        region.typeIndex = type;
        region.dedicated = true;
        if (d.mapped !is null)
            region.host = (() @trusted => d.mapped[0 .. request.size])();
        stats_[type].liveBytes += request.size;
        debug live_.put(LiveRegion(region.memory, region.offset, region.size));
        return ok!VkResult(region);
    }

    // Allocates and, if host-visible, maps one device allocation (`VKM9`,
    // `VKM11`). On failure nothing is left allocated.
    private VkResult newAllocation(uint type, ulong size, out VkDeviceMemory memory,
        out ubyte* mapped)
    {
        if (liveAllocations_ >= backend_.maxAllocationCount)
            return VkResult.VK_ERROR_TOO_MANY_OBJECTS;
        auto r = backend_.allocate(type, size, memory);
        if (r < 0)
            return r;
        if (isHostVisible(type))
        {
            void* host;
            r = backend_.map(memory, host);
            if (r < 0)
            {
                backend_.free(memory);
                memory = null;
                return r;
            }
            mapped = cast(ubyte*) host;
        }
        ++liveAllocations_;
        ++stats_[type].allocations;
        stats_[type].allocatedBytes += size;
        return VkResult.VK_SUCCESS;
    }

    private void releaseAllocation(uint type, VkDeviceMemory memory, ulong size,
        ubyte* mapped)
    {
        if (mapped !is null)
            backend_.unmap(memory);
        backend_.free(memory);
        --liveAllocations_;
        --stats_[type].allocations;
        stats_[type].allocatedBytes -= size;
    }

    private void releaseChunk(uint type, ref Chunk chunk)
    {
        releaseAllocation(type, chunk.memory, chunk.size, chunk.mapped);
        freeBitmap(chunk.bitmap);
        chunk = Chunk.init;
    }
}

/// The real allocator over a device.
alias VulkanDeviceMemory = DeviceMemory!DeviceMemoryBackend;

// ── the block bitmap ──────────────────────────────────────────────────────────

// `n` rounded up to a multiple of `alignment`, a power of two.
private ulong roundUpTo(ulong n, ulong alignment) @safe pure nothrow @nogc
    => (n + alignment - 1) & ~(alignment - 1);

private ulong* newBitmap(uint blocks) @trusted pure nothrow @nogc
{
    const words = (blocks + 63) / 64;
    auto p = cast(ulong*) pureMalloc(words * ulong.sizeof);
    if (p !is null)
        p[0 .. words] = 0;
    return p;
}

private void freeBitmap(ulong* bitmap) @trusted pure nothrow @nogc
{
    pureFree(bitmap);
}

private bool bit(const(ulong)* bitmap, ulong i) @trusted pure nothrow @nogc
    => (bitmap[i / 64] >> (i % 64) & 1) != 0;

private void setBits(ulong* bitmap, ulong first, ulong count, bool value)
    @trusted pure nothrow @nogc
{
    foreach (i; first .. first + count)
        if (value)
            bitmap[i / 64] |= 1UL << (i % 64);
        else
            bitmap[i / 64] &= ~(1UL << (i % 64));
}

// The first run of `count` free blocks, first fit; `uint.max` when none.
private uint findFree(in Chunk chunk, ulong count) pure nothrow @nogc
{
    if (count > chunk.freeBlocks)
        return uint.max;
    ulong run;
    foreach (i; 0 .. chunk.blocks)
    {
        run = bit(chunk.bitmap, i) ? 0 : run + 1;
        if (run == count)
            return cast(uint)(i + 1 - count);
    }
    return uint.max;
}

private size_t emptyCount(T)(ref T pool)
{
    size_t n;
    foreach (ref chunk; pool[])
        n += chunk.freeBlocks == chunk.blocks;
    return n;
}

private void removeAt(T)(ref T buffer, size_t index)
{
    auto items = buffer[];
    items[index] = items[$ - 1];
    buffer.popBack();
}

// ── the frame arena ───────────────────────────────────────────────────────────

/**
Per-frame memory (`VKM10`): one host-visible, persistently mapped range per
frame slot, handed out by bumping an offset. A request that does not fit gets
an extra range, freed with the slot's next `reset`.
*/
struct FrameArena(B)
if (isMemoryBackend!B)
{
    // An extra range, the slot it belongs to, and its range number: stable
    // while it lives, though removal reorders the list.
    private static struct Extra
    {
        uint slot;
        uint id;
        DeviceRegion range;
    }

    private DeviceMemory!B* memory_;
    private UniqueBuffer!DeviceRegion first_; // per slot
    private UniqueBuffer!ulong used_;         // per slot, bytes of `first_`
    private UniqueBuffer!Extra extras_;
    private uint nextExtra_ = 1;
    private ulong rangeSize_;
    private MemoryRequest request_;

    @disable this(this);

    ~this()
    {
        destroy();
    }

    /**
    `slots` ranges of `rangeSize` bytes each, in host-visible memory
    preferring `preferred`. `memory` must outlive the arena and not move.

    A caller that binds buffers over the ranges passes what such a buffer
    needs (`VkMemoryRequirements`): `typeBits`, the memory types it can live
    in, and `alignment`, to which every range's offset and size is rounded —
    no driver promises a buffer fits memory chosen without asking it.
    */
    static VkExpected!() create(out FrameArena arena, ref DeviceMemory!B memory,
        uint slots, ulong rangeSize, VkMemoryPropertyFlags preferred = 0,
        uint typeBits = uint.max, ulong alignment = 1)
    in (alignment > 0 && (alignment & (alignment - 1)) == 0, "alignment is a power of two")
    {
        arena.memory_ = (() @trusted => &memory)();
        arena.rangeSize_ = roundUpTo(rangeSize, alignment);
        arena.request_.size = arena.rangeSize_;
        arena.request_.alignment = alignment;
        arena.request_.typeBits = typeBits;
        arena.request_.required = hostVisible;
        arena.request_.preferred = preferred;
        arena.request_.tiling = Tiling.linear;
        foreach (_; 0 .. slots)
        {
            auto region = memory.allocate(arena.request_);
            if (region.hasError)
            {
                arena.destroy();
                return err!void(region.error);
            }
            arena.first_.put(region.value);
            arena.used_.put(0);
        }
        return ok!VkResult();
    }

    /// `size` bytes at a multiple of `alignment` in `slot`'s memory.
    VkExpected!DeviceRegion allocate(uint slot, ulong size, ulong alignment = 16)
    {
        uint range;
        return allocate(slot, size, alignment, range);
    }

    /**
    As above, and `range` says which of the slot's ranges the region lies in:
    0 for the first, another number for an extra range, stable while that
    range lives. `rangeRegion` returns the whole range, for a caller that
    binds a buffer to each.
    */
    VkExpected!DeviceRegion allocate(uint slot, ulong size, ulong alignment, out uint range)
    in (size > 0, "an empty request")
    {
        auto first = first_[][slot];
        const atom = memory_.isCoherent(first.typeIndex)
            ? 1 : memory_.backend_.nonCoherentAtomSize;
        const align_ = alignment > atom ? alignment : atom;
        const start = (used_[][slot] + align_ - 1) / align_ * align_;
        if (start + size <= first.size)
        {
            used_[][slot] = start + size;
            return ok!VkResult(sub(first, start, size));
        }
        // An extra range of its own (`VKM10`).
        auto request = request_;
        request.size = roundUpTo(size > rangeSize_ ? size : rangeSize_, request_.alignment);
        auto extra = memory_.allocate(request);
        if (extra.hasError)
            return err!DeviceRegion(extra.error);
        range = nextExtra_++;
        extras_.put(Extra(slot, range, extra.value));
        return ok!VkResult(sub(extra.value, 0, size));
    }

    /// Makes `slot`'s first range whole again and frees its extra ranges.
    void reset(uint slot)
    {
        used_[][slot] = 0;
        size_t i;
        while (i < extras_.length)
        {
            if (extras_[][i].slot != slot)
            {
                ++i;
                continue;
            }
            memory_.deallocate(extras_[][i].range);
            removeAt(extras_, i);
        }
    }

    /// The whole of `slot`'s range number `range`, as `allocate` reports it;
    /// `DeviceRegion.init` for a range that no longer lives.
    DeviceRegion rangeRegion(uint slot, uint range)
    {
        if (range == 0)
            return first_[][slot];
        foreach (ref e; extras_[])
            if (e.slot == slot && e.id == range)
                return e.range;
        return DeviceRegion.init;
    }

    /// The number of extra ranges `slot` holds, for tests.
    size_t extraRanges(uint slot) const
    {
        size_t n;
        foreach (ref e; extras_[])
            n += e.slot == slot;
        return n;
    }

    /// Returns every range to the allocator; idempotent.
    void destroy()
    {
        if (memory_ is null)
            return;
        foreach (i; 0 .. first_.length)
        {
            reset(cast(uint) i);
            memory_.deallocate(first_[][i]);
        }
        first_.clear();
        used_.clear();
        memory_ = null;
    }

    private static DeviceRegion sub(DeviceRegion range, ulong offset, ulong size)
    {
        DeviceRegion r;
        r.memory = range.memory;
        r.offset = range.offset + offset;
        r.size = size;
        r.typeIndex = range.typeIndex;
        if (range.host.length)
            r.host = range.host[offset .. offset + size];
        return r;
    }
}

// ── tests: the memory scenarios of docs/specs/ui-vulkan/testing.md ───────────

version (unittest)
{
    private enum KiB = 1024UL;
    private enum MiB = 1024UL * 1024;

    private enum deviceLocal = VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    private enum hostCached = VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_CACHED_BIT;

    /**
    A device with four memory types: device-local, host-visible coherent,
    host-visible cached but not coherent, and device-local host-visible. Its
    handles point into unmapped low memory, so any dereference by the
    allocator faults (`VKM3`); host-visible allocations map to real buffers.
    */
    private struct FakeDevice
    {
        VkPhysicalDeviceMemoryProperties properties;
        ulong atom = 64;
        uint limit = 4096;
        bool failAllocate;
        uint allocateCalls, freeCalls, mapCalls;
        ulong lastAllocationSize;
        VkDeviceMemory lastFlushMemory;
        ulong lastFlushOffset, lastFlushSize;
        size_t nextHandle = 1;
        ubyte[][size_t] hostMemory;

        static FakeDevice make()
        {
            FakeDevice d;
            d.properties.memoryTypeCount = 4;
            d.properties.memoryTypes[0].propertyFlags = deviceLocal;
            d.properties.memoryTypes[1].propertyFlags = hostVisible | hostCoherent;
            d.properties.memoryTypes[2].propertyFlags = hostVisible | hostCached;
            d.properties.memoryTypes[3].propertyFlags = deviceLocal | hostVisible | hostCoherent;
            return d;
        }

        ref const(VkPhysicalDeviceMemoryProperties) memoryProperties() const return
            => properties;
        ulong nonCoherentAtomSize() const => atom;
        uint maxAllocationCount() const => limit;

        VkResult allocate(uint typeIndex, ulong size, out VkDeviceMemory memory) @trusted
        {
            ++allocateCalls;
            if (failAllocate)
                return VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY;
            lastAllocationSize = size;
            memory = cast(VkDeviceMemory) cast(void*) (0x1000 * nextHandle++);
            return VkResult.VK_SUCCESS;
        }

        void free(VkDeviceMemory memory) @trusted
        {
            ++freeCalls;
            hostMemory.remove(cast(size_t) cast(void*) memory);
        }

        VkResult map(VkDeviceMemory memory, out void* host) @trusted
        {
            ++mapCalls;
            auto bytes = new ubyte[lastAllocationSize];
            hostMemory[cast(size_t) cast(void*) memory] = bytes;
            host = bytes.ptr;
            return VkResult.VK_SUCCESS;
        }

        void unmap(VkDeviceMemory) {}

        VkResult flush(VkDeviceMemory memory, ulong offset, ulong size)
        {
            lastFlushMemory = memory;
            lastFlushOffset = offset;
            lastFlushSize = size;
            return VkResult.VK_SUCCESS;
        }
    }

    static assert(isMemoryBackend!FakeDevice);

    private MemoryRequest deviceImage(ulong size)
        => MemoryRequest(size: size, required: deviceLocal, tiling: Tiling.optimal);
}

@("vulkan.memory.placementReusesAFreedRegion")
@system unittest
{
    // Scenario 1 (`VKM1`, `VKM4`): first fit on the block grid.
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    auto a = mem.allocate(deviceImage(1000 * KiB)).value;
    auto b = mem.allocate(deviceImage(130 * KiB)).value;
    auto c = mem.allocate(deviceImage(2000 * KiB)).value;
    assert(a.offset == 0 && b.offset == 1024 * KiB && c.offset == 1216 * KiB);
    assert(a.memory is b.memory && b.memory is c.memory);
    const freed = b.offset;
    mem.deallocate(b);
    auto d = mem.allocate(deviceImage(150 * KiB)).value;
    assert(d.offset == freed);
    auto aligned = mem.alignedAllocate(deviceImage(10), 4 * KiB).value;
    assert(aligned.offset % (4 * KiB) == 0);
    assert(mem.goodAllocSize(1) == 64 * KiB);
    foreach (r; [&a, &c, &d, &aligned])
        mem.deallocate(*r);
}

@("vulkan.memory.typeChoiceRequiresThenPrefers")
@system unittest
{
    // Scenario 2 (`VKM2`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    const both = MemoryRequest(size: 1, required: hostVisible, preferred: deviceLocal);
    assert(mem.chooseType(both) == 3);
    const visible = MemoryRequest(size: 1, required: hostVisible);
    assert(mem.chooseType(visible) == 1);
    const masked = MemoryRequest(size: 1, required: hostVisible, typeBits: 0b0100);
    assert(mem.chooseType(masked) == 2);

    const lazy_ = MemoryRequest(size: 1,
        required: VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT);
    auto refused = mem.allocate(lazy_);
    assert(refused.hasError && refused.error == VkResult.VK_ERROR_FEATURE_NOT_PRESENT);
    assert(mem.backend.allocateCalls == 0 && mem.liveAllocations == 0);
}

@("vulkan.memory.buffersAndImagesNeverShareAnAllocation")
@system unittest
{
    // Scenario 3 (`VKM5`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    auto image = mem.allocate(deviceImage(4 * KiB)).value;
    auto buffer = mem.allocate(MemoryRequest(size: 4 * KiB, required: deviceLocal)).value;
    assert(image.memory !is buffer.memory);
    mem.deallocate(image);
    mem.deallocate(buffer);
}

@("vulkan.memory.growthAddsOneAllocationOfTheRightSize")
@system unittest
{
    // Scenario 4 (`VKM6`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make(),
        MemoryConfig(blockSize: 64 * KiB, allocationSize: 1 * MiB));
    auto a = mem.allocate(deviceImage(1 * MiB)).value;
    assert(mem.backend.allocateCalls == 1);
    auto b = mem.allocate(deviceImage(64 * KiB)).value;
    assert(mem.backend.allocateCalls == 2 && b.memory !is a.memory);
    auto big = mem.allocate(deviceImage(3 * MiB)).value;
    assert(mem.backend.allocateCalls == 3 && mem.backend.lastAllocationSize == 3 * MiB);
    assert(mem.stats(0).allocatedBytes == 5 * MiB);
    foreach (r; [&a, &b, &big])
        mem.deallocate(*r);
}

@("vulkan.memory.aFailedGrowthChangesNothing")
@system unittest
{
    // Scenario 5 (`VKM6`, `VKM12`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    auto kept = mem.allocate(deviceImage(64 * KiB)).value;
    const before = mem.stats(0);
    mem.backend.failAllocate = true;
    auto failed = mem.allocate(deviceImage(64 * MiB));
    assert(failed.hasError && failed.error == VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY);
    assert(mem.stats(0) == before && mem.liveAllocations == 1);
    mem.backend.failAllocate = false;
    mem.deallocate(kept);
}

@("vulkan.memory.oneEmptyAllocationIsKeptSpare")
@system unittest
{
    // Scenario 6 (`VKM7`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make(),
        MemoryConfig(blockSize: 64 * KiB, allocationSize: 1 * MiB));
    auto a = mem.allocate(deviceImage(1 * MiB)).value;
    auto b = mem.allocate(deviceImage(1 * MiB)).value;
    mem.deallocate(a);
    assert(mem.backend.freeCalls == 0, "the only empty allocation is kept");
    mem.deallocate(b);
    assert(mem.backend.freeCalls == 1, "a second empty one is freed");
    const calls = mem.backend.allocateCalls;
    foreach (_; 0 .. 1000)
    {
        auto r = mem.allocate(deviceImage(1 * MiB)).value;
        mem.deallocate(r);
    }
    assert(mem.backend.allocateCalls == calls, "no driver call at the boundary");
}

@("vulkan.memory.dedicatedRequestsGetTheirOwnAllocation")
@system unittest
{
    // Scenario 7 (`VKM8`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    auto request = deviceImage(10 * KiB);
    request.dedication = Dedication.preferred;
    auto preferred = mem.allocate(request).value;
    auto overAligned = mem.alignedAllocate(deviceImage(10 * KiB), 128 * KiB).value;
    assert(mem.backend.allocateCalls == 2 && preferred.offset == 0);
    assert(preferred.memory !is overAligned.memory);
    assert(mem.owns(preferred) == Ternary.yes);
    mem.deallocate(preferred);
    mem.deallocate(overAligned);
    assert(mem.backend.freeCalls == 2 && mem.liveAllocations == 0);
}

@("vulkan.memory.hostMemoryIsMappedOnceAndFlushedByAtoms")
@system unittest
{
    // Scenario 8 (`VKM9`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    const cached = MemoryRequest(size: 100, required: hostVisible | hostCached);
    auto first = mem.allocate(cached).value;
    auto second = mem.allocate(cached).value;
    assert(mem.backend.mapCalls == 1, "one allocation, mapped once");
    assert(second.host.length == 100 && second.offset % mem.backend.atom == 0);
    second.host[] = 7;
    assert(!mem.flush(second).hasError);
    assert(mem.backend.lastFlushOffset == second.offset && mem.backend.lastFlushSize == 128);

    // Coherent memory needs no flush.
    auto coherent = mem.allocate(MemoryRequest(size: 100, required: hostVisible | hostCoherent)).value;
    mem.backend.lastFlushSize = 0;
    assert(!mem.flush(coherent).hasError && mem.backend.lastFlushSize == 0);
    foreach (r; [&first, &second, &coherent])
        mem.deallocate(*r);
}

@("vulkan.memory.frameArenaBumpsAndResetsPerSlot")
@system unittest
{
    // Scenario 9 (`VKM10`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    FrameArena!FakeDevice arena;
    assert(!FrameArena!FakeDevice.create(arena, mem, 2, 4 * KiB).hasError);

    uint rangeA, rangeB;
    auto a = arena.allocate(0, 3 * KiB, 16, rangeA).value;
    auto b = arena.allocate(0, 2 * KiB, 16, rangeB).value;
    assert(arena.extraRanges(0) == 1 && b.memory !is null);
    assert(rangeA == 0 && rangeB != 0);
    assert(arena.rangeRegion(0, rangeB).memory is b.memory);
    assert(arena.rangeRegion(0, 0).offset == a.offset);
    auto other = arena.allocate(1, 1 * KiB).value;
    other.host[] = 42;

    arena.reset(0);
    assert(arena.extraRanges(0) == 0);
    assert(!arena.rangeRegion(0, rangeB), "a freed extra range is gone");
    auto again = arena.allocate(0, 4 * KiB).value;
    assert(again.offset == a.offset, "the first range is whole again");
    assert(other.host[0] == 42 && other.host[$ - 1] == 42, "slot 1 is untouched");

    // Non-coherent memory bumps by atoms.
    FrameArena!FakeDevice cached;
    assert(!FrameArena!FakeDevice.create(cached, mem, 1, 4 * KiB, hostCached).hasError);
    auto x = cached.allocate(0, 10).value;
    auto y = cached.allocate(0, 10).value;
    assert(x.typeIndex == 2 && (y.offset - x.offset) % mem.backend.atom == 0);
    cached.destroy();
    arena.destroy();
}

@("vulkan.memory.frameArenaRangesFitTheBuffersBoundOverThem")
@system unittest
{
    // A buffer over a range may need memory types, an alignment and a
    // rounded size of its own (Adreno's do): the arena allocates every range,
    // first and extra, to them.
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    FrameArena!FakeDevice arena;
    assert(!FrameArena!FakeDevice.create(arena, mem, 1, 5000, typeBits: 1u << 2,
        alignment: 4 * KiB).hasError);
    const first = arena.rangeRegion(0, 0);
    assert(first.typeIndex == 2, "only the type the buffer allows");
    assert(first.size == 8 * KiB && first.offset % (4 * KiB) == 0);
    uint range;
    cast(void) arena.allocate(0, 9000, 16, range).value;
    const extra = arena.rangeRegion(0, range);
    assert(range != 0 && extra.typeIndex == 2);
    assert(extra.size == 12 * KiB && extra.offset % (4 * KiB) == 0, "an extra range is rounded too");
    arena.destroy();
}

@("vulkan.memory.theAllocationLimitIsEnforcedWithoutTheDriver")
@system unittest
{
    // Scenario 10 (`VKM11`).
    auto device = FakeDevice.make();
    device.limit = 2;
    auto mem = DeviceMemory!FakeDevice(device,
        MemoryConfig(blockSize: 64 * KiB, allocationSize: 1 * MiB));
    auto a = mem.allocate(deviceImage(1 * MiB)).value;
    auto b = mem.allocate(deviceImage(1 * MiB)).value;
    auto refused = mem.allocate(deviceImage(1 * MiB));
    assert(refused.hasError && refused.error == VkResult.VK_ERROR_TOO_MANY_OBJECTS);
    assert(mem.backend.allocateCalls == 2);
    mem.deallocate(a);
    mem.deallocate(b);
}

@("vulkan.memory.destroyFreesEveryAllocation")
@system unittest
{
    // Scenario 11 (`VKM13`).
    auto mem = DeviceMemory!FakeDevice(FakeDevice.make());
    auto a = mem.allocate(deviceImage(64 * KiB)).value;
    auto b = mem.allocate(MemoryRequest(size: 64 * KiB, required: deviceLocal)).value;
    auto request = deviceImage(64 * KiB);
    request.dedication = Dedication.required;
    auto c = mem.allocate(request).value;
    mem.deallocate(a);
    mem.deallocate(b);
    mem.deallocate(c);
    mem.destroy();
    assert(mem.backend.freeCalls == mem.backend.allocateCalls && mem.liveAllocations == 0);
}
