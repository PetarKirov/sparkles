---
status: draft
owner: sparkles:vulkan
reviewed: 2026-10-19
---

# `sparkles:vulkan` — Device memory

## Introduction

Every Vulkan buffer and image needs device memory bound to it, and a program
that asks the driver for one allocation per object soon fails: drivers cap
the live allocations of a device (`maxMemoryAllocationCount`, often 4096),
and each allocation is slow. Renderers therefore allocate a few large blocks
of device memory and hand out regions of them. The bookkeeping must live in
CPU memory, because device memory is usually not visible to the CPU at all.

This page specifies that sub-allocator for `sparkles:vulkan`. It has the
shape of `std.experimental.allocator`'s untyped protocol — `allocate`,
`alignedAllocate`, `deallocate`, `owns`, `deallocateAll`, `goodAllocSize`,
with `Ternary` answers — so its pieces compose the way the
[allocator guide](../../guidelines/allocators/index.md#_6-showcase-sub-allocating-gpu-device-memory)
describes, but it hands out regions that name a device allocation and an
offset rather than host pointers. Long-lived objects get fixed-size blocks
tracked by a bitmap in CPU memory, one bitmap per device allocation; growth
adds device allocations the way `AllocatorList` adds allocators; per-frame
data comes from a range reset once per frame; host-visible memory is mapped
once, for its whole life.

The allocator decides where objects go. Creating buffers and images, binding
them and recording uploads belong to their consumers, such as
[`sparkles:ui-vulkan`](../ui-vulkan/SPEC.md). Defragmentation, sparse
binding, aliasing of transient attachments and memory budgets are out of
scope.

## Requirements

**VKM1: Requests and regions.** `alignedAllocate(request, alignment)`
**must** take a size, a memory-type bit mask and the required and preferred
property flags, and return a region: the `VkDeviceMemory`, an offset into it,
the size, and for host-visible memory a host slice of exactly the region. The
offset **must** be a multiple of the alignment. `allocate(request)` is
`alignedAllocate` with the request's own alignment.

**VKM2: Type choice.** The allocator **must** choose the first memory type
in the device's order whose bit is set in the mask and which has every
required property, preferring one that also has every preferred property. A
request no memory type satisfies **must** fail with
`VK_ERROR_FEATURE_NOT_PRESENT` and change nothing.

**VKM3: Bookkeeping in CPU memory.** The allocator's state **must** live in
CPU memory it owns. It **must not** dereference a device allocation's memory;
only a host-visible region's slice is ever dereferenced, by its user.

**VKM4: Blocks and alignment.** A pool **must** place regions on a block
grid whose block size is a power of two at least as large as every alignment
the pool accepts; a region's offset is its first block's index times the
block size. A request whose alignment exceeds the block size **must** receive
a dedicated allocation (`VKM8`).

**VKM5: Linear and optimal pools.** Buffers and optimally tiled images
**must** be placed in separate pools, so `bufferImageGranularity` never
constrains a placement.

**VKM6: Growth.** A request no pool's existing device allocations can satisfy
**must** add one device allocation of the pool's allocation size, or of the
request's size rounded up to blocks when that is larger, and place the
request in it. When `vkAllocateMemory` fails, the request **must** return its
result and leave every pool unchanged.

**VKM7: Release.** `deallocate(region)` **must** return the region's blocks
to their device allocation. A pool **must** free an empty device allocation
only while another empty one remains, so one spare is always kept.

_Rationale:_ This is `AllocatorList`'s rule. Freeing every empty allocation
at once makes a region repeatedly created and freed at an allocation's
boundary call the driver every time.

**VKM8: Dedicated allocations.** A request whose memory requirements prefer
or require a dedicated allocation, or whose alignment exceeds its pool's
block size, **must** receive a device allocation of its own, outside the
pools, freed with its region.

**VKM9: Mapping.** A host-visible device allocation **must** be mapped once,
when it is made, and unmapped when it is freed. For memory that is not
host-coherent, `flush(region)` **must** flush the region widened to whole
`nonCoherentAtomSize` units, and regions **must** start on such a unit.

**VKM10: Frame arenas.** A `FrameArena` **must** keep one host-visible,
persistently mapped range per frame slot, of a size fixed at creation, and
hand out regions from it by bumping an offset. A request that does not fit
**must** be served from an extra range added to that slot. `reset(slot)`
**must** make the slot's whole first range reusable at once and free its
extra ranges.

**VKM11: Limits.** The allocator **must** count its live device allocations,
dedicated ones included, and refuse one past `maxMemoryAllocationCount` with
`VK_ERROR_TOO_MANY_OBJECTS`, without calling the driver.

**VKM12: Statistics.** `stats()` **must** report, per memory type, the device
allocations, the bytes allocated from the driver and the bytes in live
regions.

**VKM13: Shutdown.** `destroy()` **must** free every device allocation.
Destroying with regions still live is a programmer error, reported in debug
builds with each live region's size and offset.
