# Vulkan transfer: from bytes to a sampled image (Vulkan)

The Vulkan specification's paths for getting pixels into a sampleable image (a staging buffer and
`vkCmdCopyBufferToImage`, a host-side copy, an imported host or dma-buf allocation, and a GPU
decompression pass before the copy), read at the 1.4.366 revision and set against what the
survey's eleven devices expose and what `sparkles:vulkan` and `ui-vulkan` already do.

| Field         | Value                                                                                                                                                                                         |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Specification: AsciiDoc chapters plus the machine-readable registry [`xml/vk.xml`][vkxml]; the API it defines is C                                                                            |
| License       | CC-BY-4.0 for the specification sources, Apache-2.0 OR MIT for `vk.xml` and some scripts ([`LICENSE.adoc`][license])                                                                          |
| Repository    | [KhronosGroup/Vulkan-Docs][repo]                                                                                                                                                              |
| Revision read | `a8b088a3fae12c8575407ea90c7c09bd653db923` ("Change log for October 23, 2026 Vulkan 1.4.366 spec update")                                                                                     |
| Documentation | [docs.vulkan.org specification][docs-spec] · in-tree [`chapters/copies.adoc`][copies] · extension proposals ([`VK_EXT_host_image_copy`][hic-prop], [`VK_EXT_memory_decompression`][dec-prop]) |
| Category      | GPU and I/O: upload, external memory, GPU decompression, YCbCr sampling, block-compressed format support                                                                                      |
| Tier          | A                                                                                                                                                                                             |
| Last reviewed | November 15, 2026                                                                                                                                                                             |

> [!NOTE]
> Every specification quote was read with `git show a8b088a3f:<path>` from a local clone. Device facts come in
> two kinds. **Verified here** means a command run on this machine on November 14, 2026: a
> Radeon RX Vega 56 and a Radeon 610M on RADV (Mesa 25.2.6) and llvmpipe (LLVM 21.1.7), queried
> with `vulkaninfo` from `nix-shell -p vulkan-tools` (instance 1.4.328), plus one C probe built
> against `vulkan-headers` 1.4.328 in `/tmp`. **Verified on device** means a cell of the
> [hardware matrix][hw] or a field of one of its raw reports; the probe ran on that device, not
> here. Everything else is **documented**: the specification says so. No timing was measured, so
> this page states no performance number.

---

## Overview

### What it solves

A decoded image starts as bytes in host memory, in a row-major layout with some row
[stride][c-stride], one or more [planes][c-plane], and possibly a block-compressed
[format][c-bcn]. A GPU samples it from an image whose memory is, in the common case,
device-local and in an implementation-defined [tiling][c-tiling]. Vulkan does not hide the
distance between the two: the application chooses where the bytes live, who rearranges them
into the tiled layout, which queue does it, how ownership and layout move between queues, and
whether the sampler converts YCbCr on the way out. The core path is the only way to reach optimal tiling without extensions, as the
`VK_EXT_host_image_copy` proposal states plainly ([`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-problem]):

> _"Copying data to optimal-layout images in Vulkan requires staging the data in a buffer first,
> and using the GPU to perform the copy."_

Each extension surveyed here removes one cost of that path: a copy (`VK_EXT_host_image_copy`,
`VK_EXT_external_memory_host`, resizable BAR), a process or API boundary
(`VK_EXT_external_memory_dma_buf` with `VK_EXT_image_drm_format_modifier`), CPU decompression
(`VK_NV_memory_decompression`, `VK_EXT_memory_decompression`), or a shader-side colour
conversion (`VK_KHR_sampler_ycbcr_conversion`).

### Design philosophy

The specification is explicit and capability-queried. Nothing is assumed about memory layout,
queue topology or format support: every one of them is a query whose answer the application
must act on. The host-copy proposal makes the stance concrete when it declines to recommend its
own extension ([`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-limits]):

> "It is therefore recommended that developers measure performance and decide whether this
> extension results in a performance gain or loss in their application. Unless specifically
> recommended on a platform, it is _not_ generally recommended for applications to perform all
> image copies through this extension." (Emphasis in the original.)

The DRM format modifier extension states the same restraint about layouts: it names layouts
rather than describing them ([`appendices/VK_EXT_image_drm_format_modifier.adoc`][drm-app-name]):

> "Modifier values typically do not _describe_ memory layouts. [...] Instead, modifiers _name_
> memory layouts; they name a small set of vendor-preferred layouts for image sharing." (Emphasis
> in the original.)

The consequence for a library is that a transfer layer is a decision table over queried facts,
not a fixed pipeline; the [hardware matrix][hw] shows that no two of the eleven devices take the
same branches.

---

## How it works

### The staging path: `vkCmdCopyBufferToImage`

The baseline path ([staging and upload][c-staging]) has four steps: write pixels into a host-visible buffer, record a layout
transition of the image to `VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL` with an image memory barrier,
record `vkCmdCopyBufferToImage`, then a second barrier to `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL`
for the stage that samples it. Each `VkBufferImageCopy` region carries the source layout in
texels, not bytes ([`chapters/copies.adoc`][copies-bic]):

> _"`bufferRowLength` and `bufferImageHeight` specify in texels a subregion of a larger two- or
> three-dimensional image in buffer memory, and control the addressing calculations. If either
> of these values is zero, that aspect of the buffer memory is considered to be tightly packed
> according to the `imageExtent`."_

The addressing equations make the stride model exact. For texel `(x, y, z, layer)` the bytes read
start at ([`chapters/copies.adoc`][copies-addr]):

```text
texelOffset = baseAddress
            + floor((x - imageOffset.x) / blockWidth)  * blockSize
            + floor((y - imageOffset.y) / blockHeight) * rowExtent
            + floor((z - imageOffset.z) / blockDepth)  * sliceExtent
            + (layer - baseArrayLayer)                 * layerExtent
rowExtent   = ceil(max(bufferRowLength,   imageExtent.width)  / blockWidth)  * blockSize
sliceExtent = ceil(max(bufferImageHeight, imageExtent.height) / blockHeight) * rowExtent
layerExtent = ceil(imageExtent.depth / blockDepth) * sliceExtent
```

Three consequences follow. The row stride must be a whole number of texels (or texel blocks for
BCn, ETC2 and ASTC), so a byte pitch that is not a multiple of the texel size, which some
decoders produce, cannot be expressed and needs a repack. A sub-rectangle of a larger decoded
image can be uploaded in place by pointing `bufferOffset` at its first texel and setting
`bufferRowLength` to the parent width. And a planar image is copied one plane per region: the
aspect mask "must only have a single bit set" ([`buffer_or_memory_image_copy_common.adoc`][cv-bomic]),
and for a multi-planar format "addressing calculations are performed using the compatible format
for that plane" ([`chapters/copies.adoc`][copies-planar]).

Offsets have their own alignment rules, which depend on the queue
([`copy_bufferimage_to_imagebuffer_buffer_alignment_common.adoc`][cv-align],
[`copy_buffer_to_image_command_buffer_common.adoc`][cv-cbti]):

- `bufferOffset` must be a multiple of the texel block size; for a multi-planar format, of the
  element size of the plane's compatible format; for depth/stencil, of 4.
- On a queue family that supports neither graphics nor compute (a transfer-only queue), and
  without `maintenance11`, `bufferOffset` must also be a multiple of 4.
- `imageOffset` and `imageExtent` must respect the queue family's
  `minImageTransferGranularity`. Graphics and compute families (and, with `maintenance11`,
  transfer families) report `(1,1,1)`; other families
  "are only required to support whole mip level transfers, thus `minImageTransferGranularity`
  for queues belonging to such queue families may be `(0,0,0)`" ([`devsandqueues.adoc`][dq-gran]).

`optimalBufferCopyOffsetAlignment` and `optimalBufferCopyRowPitchAlignment` are hints, not
rules. Verified on device, the row-pitch hint is 1 on the AMD and NVIDIA GPUs and on the M4 Max,
64 on both Adrenos, the UHD 770 and the Arc A380, and 128 on Lunar Lake and llvmpipe (raw
reports in [`hardware/reports/`][hw-devices]).

### Tiling and layouts

`VkImageTiling` has three values ([`chapters/resources.adoc`][res-tiling]): `OPTIMAL`, "texels are
laid out in an implementation-dependent arrangement"; `LINEAR`, "row-major order, possibly with
some padding on each row"; and `DRM_FORMAT_MODIFIER_EXT`, whose layout is named by a Linux
modifier. Linear images are a weak fallback for sampling: their creation "may not be supported
unless" the image is 2-D, single-mip, single-layer, single-sample and used only as a transfer
source or destination ([`chapters/resources.adoc`][res-linear]). A linear image can be mapped
and written directly, but a sampleable, mipmapped, compressed or planar image is optimal-tiled
in practice, so something must swizzle. In the staging path the GPU's copy engine does it; in
the host-copy path the CPU does. Image layouts are a separate axis from tiling: a layout names
the access pattern an image is prepared for (`TRANSFER_DST_OPTIMAL`, `SHADER_READ_ONLY_OPTIMAL`,
`GENERAL`), and the barriers above move it between them.

### Transfer queues and queue-family ownership

Any family with graphics or compute can run transfer commands; reporting `VK_QUEUE_TRANSFER_BIT`
there "is optional" ([`devsandqueues.adoc`][dq-transfer-note]), though Vulkan 1.4 requires it
on every graphics or compute queue ([`appendices/VK_EXT_host_image_copy.adoc`][hic-promo]). A dedicated transfer family (no
graphics, no compute) maps on many GPUs to a DMA engine that copies while the graphics queue
renders. Using it costs an ownership transfer for every `VK_SHARING_MODE_EXCLUSIVE` resource
([`chapters/synchronization.adoc`][sync-qfot]):

> _"Resources created with a `VkSharingMode` of `VK_SHARING_MODE_EXCLUSIVE` must have their
> ownership explicitly transferred from one queue family to another in order to access their
> content in a well-defined manner on a queue in a different queue family."_

The transfer is two barriers with the same `srcQueueFamilyIndex` and `dstQueueFamilyIndex`: a
release recorded on the source queue and an acquire on the destination queue, ordered by a
semaphore ([`chapters/synchronization.adoc`][sync-release]). Skipping it leaves the contents
"undefined for any read accesses performed by the second queue family"
([`chapters/synchronization.adoc`][sync-undefined]). The alternative,
`VK_SHARING_MODE_CONCURRENT`, removes the barriers and may cost access performance.

Vulkan 1.4 ties transfer queues to host image copy. The promotion note of
`VK_EXT_host_image_copy` says ([`appendices/VK_EXT_host_image_copy.adoc`][hic-promo]):

> _"A Vulkan 1.4 implementation that has a `VK_QUEUE_GRAPHICS_BIT` queue must support either:
> the `hostImageCopy` feature; or an additional queue that supports `VK_QUEUE_TRANSFER_BIT`."_

The verified reports obey this in both directions: the RADV 1.4 devices lack `hostImageCopy` and
expose a four-queue compute-and-transfer family; the Arc A380 and the UHD 770 expose a single
queue family and enable `hostImageCopy`.

### Host image copy (`VK_EXT_host_image_copy`, core 1.4)

`vkCopyMemoryToImage` "is functionally similar to `vkCmdCopyBufferToImage2`, except it is
executed on the host and reads from host memory instead of a buffer"
([`chapters/copies.adoc`][copies-hic]). The region struct `VkMemoryToImageCopy` replaces the buffer
offset with `pHostPointer` and keeps the stride fields as `memoryRowLength` and
`memoryImageHeight`, with the same addressing equations. The image needs
`VK_IMAGE_USAGE_HOST_TRANSFER_BIT`; `vkTransitionImageLayout` moves it between a small set of
layouts on the host without a command buffer; there is no queue-family ownership because the
physical layout does not vary between families ([`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-qfot]).
The appendix resolves two limits that matter for strided sources: "No alignment requirements for
the host memory pointer" and "No granularity requirements"
([`appendices/VK_EXT_host_image_copy.adoc`][hic-issues]).

The cost moves rather than vanishes. The CPU now does the swizzle, the image's memory must be
mappable by the driver, and the driver may pick a less efficient layout for host-transferable
images. `VkHostImageCopyDevicePerformanceQuery`, chained to
`vkGetPhysicalDeviceImageFormatProperties2`, reports `optimalDeviceAccess` and
`identicalMemoryLayout` per format and usage, and "block-compressed formats are required to set
`optimalDeviceAccess` to `VK_TRUE`" ([`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-bc]).
Synchronisation is the application's: the command "does not check whether the device memory
associated with `dstImage` is currently in use" ([`chapters/copies.adoc`][copies-hic-sync]).

**Verified here.** A 90-line C probe (`/tmp/vk-transfer-demo/hic.c`) found `hostImageCopy`
false on both RADV devices and true on llvmpipe. On llvmpipe it created an `R8G8B8A8_UNORM`
optimal image with `SAMPLED | HOST_TRANSFER`, moved it to `GENERAL` with
`vkTransitionImageLayout`, uploaded a 5×3 region from a host array whose rows are 8 texels apart
(`memoryRowLength = 8`, padding texels filled with `0xDEADBEEF`), read it back tightly with
`vkCopyImageToMemory`, and compared: identical, padding skipped. The performance query returned
`optimalDeviceAccess = 1` and `identicalMemoryLayout = 1` for `R8G8B8A8_UNORM`,
`BC1_RGBA_UNORM_BLOCK` and `G8_B8R8_2PLANE_420_UNORM`, all three with
`VK_FORMAT_FEATURE_2_HOST_IMAGE_TRANSFER_BIT`. llvmpipe's memory is host memory, so this shows the
API contract, not the cost on a discrete GPU.

```text
device 2: llvmpipe (LLVM 21.1.7, 256 bits) hostImageCopy=1
  R8G8B8A8_UNORM           query=0 hostTransferFeature=1 optimalDeviceAccess=1 identicalMemoryLayout=1
  BC1_RGBA_UNORM_BLOCK     query=0 hostTransferFeature=1 optimalDeviceAccess=1 identicalMemoryLayout=1
  G8_B8R8_2PLANE_420_UNORM query=0 hostTransferFeature=1 optimalDeviceAccess=1 identicalMemoryLayout=1
strided host upload (row length 8 texels, region 5x3): read back identical, padding texels skipped
```

### Host-visible device-local memory (resizable BAR)

The specification guarantees only one host-visible coherent type and one device-local type
([`chapters/memory.adoc`][mem-types]); a type with both `DEVICE_LOCAL` and `HOST_VISIBLE` is
optional. With resizable BAR the CPU can map all of VRAM, and drivers then report that type on
the whole device-local heap; without it, a small (typically 256 MiB) window is reported as a
separate heap. That is driver behaviour, not specification text; the reports below show both
shapes. A staging buffer in that memory lets the CPU write pixels where the GPU reads
them, saving a PCIe crossing during the copy, but the swizzle into optimal tiling still needs a
copy command or a host image copy.

**Verified here.** The Vega 56's PCI BAR0 is 8192 MiB (`/sys/bus/pci/devices/0000:03:00.0/resource`),
and RADV lists memory types 3 and 4 as `DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT` on the 7.98 GiB
device-local heap. The 610M iGPU's BAR0 is 256 MiB, irrelevant for an integrated part.
**Verified on device** (heap layout in the reports, read as above): the 9070 XT, RTX 4060 and
RTX 4090 put a `DEVICE_LOCAL | HOST_VISIBLE` type on their full device-local heap; the Arc A380,
on a Kaby Lake host, puts it on a separate 256 MiB heap; the Intel iGPUs, the M4 Max and llvmpipe
report one unified heap. The Adreno reports carry no memory-type flags (vkjson over `adb`).

### Importing memory: host pointers, dma-buf and DRM modifiers

`VK_EXT_external_memory_host` ([external memory][c-extmem]) imports a host allocation as `VkDeviceMemory` through
`VkImportMemoryHostPointerInfoEXT`. The pointer and `allocationSize` must both be multiples of
`minImportedHostPointerAlignment` ([`chapters/memory.adoc`][mem-host-align],
[`chapters/memory.adoc`][mem-alloc-align]), and the specification gives the lifetime to the
application ([`chapters/memory.adoc`][mem-host-life]):

> _"Whether device memory objects imported from a host pointer hold a reference to their payload
> is undefined. As such, the application must ensure that the imported memory range remains
> valid and accessible for the lifetime of the imported memory object."_

An imported host range binds to a `VkBuffer`, which then serves as a staging buffer with no copy
into it: a decoder or a file read can write straight into memory the GPU copies from.

`VK_EXT_external_memory_dma_buf` does one thing, by its own account: "the ability to
import/export between `dma_buf` and `VkDeviceMemory`", which with `VK_KHR_external_memory_fd` "is
sufficient to bind a `VkBuffer` to `dma_buf`" ([`appendices/VK_EXT_external_memory_dma_buf.adoc`][dmabuf-one]).
Binding an image needs its layout, which `VK_EXT_image_drm_format_modifier` supplies: the image
is created with `VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT` and either a list of acceptable
modifiers or an explicit modifier with per-plane offsets and pitches
(`VkImageDrmFormatModifierExplicitCreateInfoEXT`, one entry per memory plane). This is the route
by which a VA-API decoder's NV12 surface or a camera frame reaches a Vulkan image without a copy.
The import is cross-instance, so ownership moves to and from `VK_QUEUE_FAMILY_EXTERNAL` or, for a
different device or driver, `VK_QUEUE_FAMILY_FOREIGN_EXT`, which "applications should expect
[...] to be more expensive" ([`chapters/synchronization.adoc`][sync-foreign]).

### GPU decompression: the NV and EXT extensions

Both extensions ([GPU decompression][c-gpudec]) add a command that reads compressed bytes from one device address and writes
decompressed bytes to another, with GDeflate 1.0 as the only method. The EXT proposal frames it as
CPU relief ([`proposals/VK_EXT_memory_decompression.adoc`][dec-prop-problem]):

> _"Compressed game assets which could be a very large amount of data, are usually decompressed
> on the CPU before uploading to the GPU. This takes away CPU utilization which can be used for
> other tasks if the decompression is moved to the GPU."_

The output is a buffer, not an image: the decompressed bytes are then copied to an image with
`vkCmdCopyBufferToImage`, so decompression replaces the CPU inflate, not the upload. Every region
is capped at 64 KiB of output for GDeflate 1.0 ([`chapters/memory_decompression.adoc`][dec-cap]),
and the last block's size must come from the bitstream: setting `decompressedSize` too low "will
cause issues and is undefined behavior", and validation layers cannot detect it
([`appendices/VK_EXT_memory_decompression.adoc`][dec-issue]).

The two specifications differ in these ways (read from [`chapters/memory_decompression.adoc`][dec-chapter]
and the two `extension` entries in [`vk.xml`][vkxml-nv] and [`vk.xml`][vkxml-ext]):

| Aspect                    | `VK_NV_memory_decompression` (2022, number 428)                                 | `VK_EXT_memory_decompression` (2025, number 551, ratified)                                                                  |
| ------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Status in `vk.xml`        | `promotedto="VK_EXT_memory_decompression"`                                      | `ratified="vulkan"`, author `EXT`                                                                                           |
| Direct command            | `vkCmdDecompressMemoryNV(cmd, count, pRegions)`                                 | `vkCmdDecompressMemoryEXT(cmd, pDecompressMemoryInfoEXT)`, an extensible info struct with `pNext`                           |
| Where the method is named | per region, `VkDecompressMemoryRegionNV::decompressionMethod`                   | once per call, `VkDecompressMemoryInfoEXT::decompressionMethod`; regions carry only addresses and sizes                     |
| Indirect command          | `vkCmdDecompressMemoryIndirectCountNV(cmd, addr, countAddr, stride)`            | adds `decompressionMethod` and `maxDecompressionCount`; the count executed is the minimum of the GPU count and that cap     |
| Buffer usage              | no dedicated usage flag                                                         | source and destination buffers need `VK_BUFFER_USAGE_2_MEMORY_DECOMPRESSION_BIT_EXT`                                        |
| Synchronisation           | no dedicated stage or access bit                                                | `VK_PIPELINE_STAGE_2_MEMORY_DECOMPRESSION_BIT_EXT`, `VK_ACCESS_2_MEMORY_DECOMPRESSION_READ_BIT_EXT` and `..._WRITE_BIT_EXT` |
| Dependencies              | `get_physical_device_properties2` (or 1.1) plus `buffer_device_address`, or 1.2 | `get_physical_device_properties2` plus `buffer_device_address`                                                              |
| Queues                    | graphics or compute                                                             | graphics or compute                                                                                                         |

The feature and property structures are shared: the NV structure-type enums are aliases of the
EXT ones, and the probe reads `VkPhysicalDeviceMemoryDecompressionPropertiesEXT` for both. The
last row is the trap for a transfer design: in `vk.xml` all four commands carry
`queues="VK_QUEUE_GRAPHICS_BIT,VK_QUEUE_COMPUTE_BIT"` ([`vk.xml`][vkxml-cmds]), so decompression
cannot run on a transfer-only queue. A pipeline that reads compressed data on a DMA queue and
decompresses it needs an ownership transfer to a compute family in between.

### YCbCr sampling

`VK_KHR_sampler_ycbcr_conversion` (core 1.1, its feature required from 1.4,
[`appendices/VK_KHR_sampler_ycbcr_conversion.adoc`][ycbcr-app]) "is mainly used for processing
inputs from video decoders and cameras". It adds the multi-planar formats
(`G8_B8R8_2PLANE_420_UNORM` for NV12, `G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16` for P010, and so
on), the plane aspects `VK_IMAGE_ASPECT_PLANE_0_BIT`..`PLANE_2_BIT` for copies, and a
`VkSamplerYcbcrConversion` object that fixes the [matrix][c-ycbcr] (`ycbcrModel`), the
[range][c-range] (`ycbcrRange`), chroma siting (`xChromaOffset`, `yChromaOffset`) and the chroma
filter. The conversion is baked into the pipeline ([`chapters/samplers.adoc`][samp-immutable]):

> _"Conversion must be fixed at pipeline creation time, through use of [...] a combined image
> sampler with an immutable sampler in `VkDescriptorSetLayoutBinding`."_

A `LINEAR` chroma filter needs `VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER_BIT`
([`chapters/samplers.adoc`][samp-chroma]); the matrix's `Y` flag records exactly that bit. Images of
these formats are restricted like linear ones: 2-D, one mip, one layer unless `ycbcrImageArrays`
([`chapters/resources.adoc`][res-ycbcr]).

### Format feature queries for block formats

`textureCompressionBC`, `textureCompressionETC2` and `textureCompressionASTC_LDR` each promise
sampling, blit-source and linear filtering in optimal tiling for their whole family
([`chapters/features.adoc`][feat-bc]); otherwise `vkGetPhysicalDeviceFormatProperties` answers per
format. The [hardware matrix][hw-formats] already records the result (verified on device): BCn on
every device except the Adreno 660; ETC2 on the Vega 56, the M4 Max, both Adrenos and the Intel
GPUs, but not on the RDNA parts or NVIDIA; ASTC LDR only on the M4 Max, both Adrenos and the UHD 770. It also records that the RTX 4060 reports `ASTC_4x4_SFLOAT_BLOCK` as sampleable without the
ASTC features, so the feature bit must be checked with the format bit.

---

## Analysis

### 1. Pixel and memory model

Vulkan's host-side pixel model is a strided N-D array with a block granularity: base address,
row length in texels, image height in rows, depth slices and array layers, one aspect per region
([equations above](#the-staging-path-vkcmdcopybuffertoimage)). It has no byte stride, no
negative stride and no axis permutation; a column-major or flipped source needs a repack. Planes
are first-class (one region per plane aspect, addressed in the plane's compatible format) and so
are block formats (strides count blocks). On the device side the layout is opaque unless the
image is linear or carries a DRM modifier, whose memory planes may differ from the format's
planes. This is the mapping [baseline G1][bl-vk-gaps] says the Sparkles pixel model must state:
`ui-vulkan`'s `Uploads.stage` takes "pixels must fill the extent exactly" and never sets
`bufferRowLength`, so it covers only the tight, single-plane case.

### 2. Genericity mechanism

Genericity is by runtime query and `pNext` extension chains, not types: a format enum plus
feature bits (`VkFormatProperties3`), per-usage image limits
(`vkGetPhysicalDeviceImageFormatProperties2`, with `VkHostImageCopyDevicePerformanceQuery` chained
in), per-family queue properties. Promotion keeps names as aliases (`vkCopyMemoryToImageEXT` and
`vkCopyMemoryToImage`; the NV decompression structure types aliasing the EXT ones), so a binding
can treat promoted and extension forms as one entry. This is design by introspection at run time;
a D layer can mirror it with capability structs filled once per device and `static if` only for
what the header declares.

### 3. Colour and metadata

Colour enters at two points. Format suffixes (`_SRGB` against `_UNORM`) decide whether sampling
applies the sRGB transfer function; `VkSamplerYcbcrConversion` decides the YCbCr matrix, range
and chroma siting. Neither carries primaries, an HDR transfer function or an ICC profile; those
belong to swapchain colour spaces and to the application. The YCbCr model covers BT.601, BT.709
and BT.2020 matrices, the CICP subset a decoder emits most, and the conversion object is
immutable per pipeline, so a viewer showing images with different matrices needs one pipeline
(or one immutable-sampler layout) per combination. Metadata (EXIF, XMP) is out of scope.

### 4. I/O and codec architecture

The specification has no file I/O. Its transfer commands are the last stage of a pipeline the
application builds: read (into a mapped staging buffer, an imported host range, or a dma-buf),
optionally decompress on the GPU, copy into the tiled image, transition, sample. Two shapes
avoid a host copy: reading directly into a persistently mapped staging range, and importing the
read buffer with `VK_EXT_external_memory_host`. The host-copy proposal names a three-copy path
("load the data to memory (one copy), then initialize the buffer (second copy) and finally copy
over to the image (third copy)", [`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-problem]) and
removes the middle copy. GPU decompression is chunked by design (64 KiB GDeflate outputs), which
fits the incremental, tile-parallel decode the [GPU decode papers][p-gpu-decode] describe.

### 5. Hostile input and safety

Transfers trust their parameters. Region bounds are valid-usage rules, checked only by
validation layers; an out-of-range `bufferRowLength` or extent is undefined behaviour, not an
error code. Two cases sharpen this for images from untrusted files. The decompression output size
must be read from the bitstream and is unvalidated, and too small a value is undefined behaviour
([`appendices/VK_EXT_memory_decompression.adoc`][dec-issue]). Host image copy dereferences
`pHostPointer` on the CPU with no bounds check against a host allocation, since the API has no
notion of one. A Sparkles transfer layer therefore has to compute every region from validated
header fields (width, height, stride, plane sizes) and check it against its own buffer lengths
before the call; `@safe` slices give that check a natural home on the D side.

### 6. Allocation and ownership

Every path has an owner the application must track. Staging memory lives until the fence or
timeline value of the copy that reads it; [`UVK28`][bl-vk-contracts] ties it to a frame slot.
Imported host memory must outlive its `VkDeviceMemory`, by the rule quoted above; a dma-buf owns a
reference to its memory ([`chapters/capabilities.adoc`][cap-dmabuf]). Host image copy removes the
staging buffer and its peak: the proposal's motivating complaint is that bulk asset loads
"momentarily have twice as much memory allocated" ([`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-peak]).
Queue-family ownership is a second ownership axis on the resource itself, independent of the
memory. The Sparkles allocator cannot hold an imported region today (`VKM3`, [baseline G6][bl-vk-gaps]).

### 7. CPU parallelism and SIMD

The CPU's part is the write into staging memory (a `memcpy` or a format conversion fused into it)
and, with host image copy, the swizzle. `vkCopyMemoryToImage` is a host call on a `VkDevice`, so
several threads can upload disjoint images or regions in parallel, which the proposal names as a
benefit: "allowing the CPU to perform some copies in parallel with the GPU"
([`proposals/VK_EXT_host_image_copy.adoc`][hic-prop-problem]). The swizzle's cost is
the implementation's and is not exposed beyond the `optimalDeviceAccess` hint. Writes into
write-combined device-local memory (the resizable-BAR case) should be sequential and never read
back; that is driver and platform folklore, not specification text, and was not measured here.

### 8. GPU offload and interop

This is the subject's centre. Per device, from the reports (verified on device) and this
machine (verified here):

| Capability                                       | AMD RDNA/GCN (RADV)             | NVIDIA (4060, 4090)                | Intel (UHD 770, A380, Lunar Lake)       | M4 Max (MoltenVK)   | Adreno 660 / 830             | llvmpipe                |
| ------------------------------------------------ | ------------------------------- | ---------------------------------- | --------------------------------------- | ------------------- | ---------------------------- | ----------------------- |
| Transfer-only queue family                       | none exposed                    | family 1, 2 queues                 | Lunar Lake only (family 2, 1 queue)     | none                | none                         | none                    |
| Async compute+transfer family                    | family 1, 4 queues              | family 2, 8 queues                 | Lunar Lake only (1 queue)               | 4 graphics families | 830: compute-only family     | none                    |
| `hostImageCopy`                                  | no                              | 4060: extension; 4090: 1.4 feature | yes                                     | yes                 | no                           | yes                     |
| Host-visible device-local on the full heap       | yes (Vega 56: BAR0 8 GiB, here) | yes                                | iGPUs unified; A380: 256 MiB window     | unified             | not reported                 | unified                 |
| `VK_EXT_external_memory_host`                    | 4 KiB                           | 4 KiB                              | 4 KiB on all three (see the note below) | 16 KiB              | absent                       | 4 KiB                   |
| `external_memory_dma_buf`, `drm_format_modifier` | yes                             | yes                                | yes                                     | no (Metal handles)  | no (AHardwareBuffer)         | yes (Mesa 24.2: no DRM) |
| Memory decompression (GDeflate 1.0)              | no                              | 4060: NV; 4090: NV and EXT         | no                                      | no                  | no                           | no                      |
| `samplerYcbcrConversion`                         | yes                             | yes                                | yes                                     | yes                 | 660: extension; 830: feature | yes                     |

Notes on the table. RADV keeps its SDMA transfer queue behind `RADV_EXPERIMENTAL=transfer_queue`,
described as "enable experimental transfer queue support (GFX9+, not yet spec compliant)" in
Mesa's [environment-variable documentation][mesa-env] (documented, read November 14, 2026), which
is why no transfer-only family appears on AMD. NVIDIA's video families also advertise
`TRANSFER`; RADV's do not. The matrix's [compute table][hw-compute] marks the UHD 770 as lacking
`VK_EXT_external_memory_host`, but its raw report ([`linux-geforce-rtx-4090-laptop.json`][r-4090],
schema 1) lists the extension with a 4 KiB alignment for "Intel(R) Graphics (RPL-S)"; the raw
report is what this table uses. The llvmpipe of Mesa 24.2.6 (LLVM 18.1.8, in the RTX 4060 report)
lacks `image_drm_format_modifier`; the Mesa 25 builds have it. The `hostImageCopy` cells match the
`enabled` feature lists of the raw reports; the RTX 4060's 1.3 driver lists only the extension.

Against the baseline: `sparkles:vulkan` binds `CmdCopyBufferToImage` and
`GetPhysicalDeviceFormatProperties` and nothing else on this page; `VulkanDevice` requests one
graphics queue; no external-memory, host-copy, decompression or YCbCr command is in `dispatch.d`
([baseline capability table][bl-vk-caps]). All of the types are present through ImportC, so each
row above is a `CommandSet` addition plus policy, not a binding project.

### 9. Temporal, animation and containers

Not applicable as specification features: Vulkan has no notion of frames in a sequence outside
Vulkan Video, which belongs to the video catalog. The transfer mechanics bear on animation
indirectly. A per-frame upload of an animated image repeats the staging cycle every frame, and
`minImageTransferGranularity` of `(0,0,0)` on a transfer-only family would force whole-mip
uploads where only a dirty rectangle changed (every family here reports `(1,1,1)`, verified on
this machine's RADV families). Video decode output arrives as NV12 or P010 images already on
the device, so it skips the upload entirely and meets this page only at the YCbCr sampler.

### 10. Testing and conformance

The Vulkan CTS is the conformance mechanism; the specification's valid-usage IDs (`VUID-...`) are
what the validation layers check, and the decompression appendix admits a gap: the layers "will
not be able to detect the minimum size of `decompressedSize` unless it decides to implement each
decompression method specification" ([`appendices/VK_EXT_memory_decompression.adoc`][dec-issue]).
For Sparkles, lavapipe is the CI oracle ([baseline][bl-vk-contracts]) and, verified here, it
covers host image copy, external host memory, dma-buf and YCbCr formats, but has no transfer-only
queue, no resizable-BAR distinction and no decompression. The host-copy probe above is the shape
of a readback test that needs no command buffer at all. Decompression has no CI device; only the
NVIDIA laptops can run it.

---

## Lessons for Sparkles

- **Q1 — The upload ABI is a strided array in texels per plane; the pixel model has to say how it
  maps.** `bufferRowLength`, `bufferImageHeight`, one aspect per region and block-granular strides
  fix what the GPU side can accept without a repack: row stride a whole number of texels or
  blocks, non-negative, row-major. A Sparkles view whose stride is in bytes needs a
  `stride % texelBytes == 0` check before it can be uploaded in place; mir's `Slice` strides in
  elements already match ([mir-algorithm][mir], [`Slice` experiment][slice-exp]). Today
  `Uploads.stage` fixes the tight case ([baseline G1][bl-vk-gaps]).
- **Q1, Q6 — Sub-image upload is free in the API and missing in Sparkles.** Pointing
  `bufferOffset` at a tile inside a larger decoded buffer, with `bufferRowLength` set to the
  parent width, is the mechanism a tiled residency ([baseline D10][bl-vk-grill], option B) would
  use, and it costs no host copy.
- **Q6 — Choose the path from queried facts; no single path covers the matrix.** Staging plus
  `vkCmdCopyBufferToImage` works everywhere; host image copy is absent on RADV and both
  Adrenos; a transfer-only queue is absent on AMD, the UHD 770, the Arc A380, the M4 and the Adrenos;
  decompression exists only on NVIDIA. Vulkan 1.4's either-or rule (host copy or an extra transfer
  queue) is the closest thing to a guarantee, and Sparkles' Android floor (Vulkan 1.1 on the
  Adreno 660, [baseline `UVX10`][bl-vk-contracts]) sits below it. This is the
  capability-struct-plus-fallback pattern the repository already uses for dynamic rendering, and
  it fits design by introspection over a per-device facts struct.
- **Q6 — A transfer queue is not free in Sparkles' synchronisation model.** It needs a second
  family, release and acquire barriers per image, and a semaphore between queues; today's device
  has one queue and v1 binary semaphores ([baseline G3, G4][bl-vk-gaps]). The 4-byte
  `bufferOffset` rule applies only on transfer-only families; `upload.d` already rounds to a
  multiple of 4 on all queues, which is safe and slightly stricter than the graphics queue needs.
- **Q6 — Import fits `sparkles.base.buffer` lifetimes only with a page-aligned owner.**
  `VK_EXT_external_memory_host` needs pointer and size aligned to 4 KiB (16 KiB on the M4) and the
  host pages to outlive the `VkDeviceMemory`. A `HeapBuffer` allocated with that alignment and
  held by the GPU-side owner until its fence signals would satisfy it; `VKM3` keeps imports out of
  the allocator today, which favours the separate `ExternalMemory` type of
  [baseline D5][bl-vk-grill] (option B). An `io_uring` read into such a buffer gives a file-to-GPU
  path with one fewer copy ([event-horizon baseline][bl-eh]). Not available on Android.
- **Q6, Q9 — dma-buf with DRM modifiers is the zero-copy seam for video and cameras, and it is
  Linux-only.** Every Linux device here has both extensions; the Mac uses Metal handles and the
  phones AHardwareBuffer. A package boundary that keeps dma-buf import in a Linux-specific module
  (versioned, as the WSI code already is per platform) keeps the image core portable.
- **Q6, Q7 — GPU decompression replaces the CPU inflate, not the upload, and it cannot run on a
  transfer queue.** Both extensions are buffer-to-buffer and graphics/compute-only, cap GDeflate
  outputs at 64 KiB and trust the caller's `decompressedSize`. Prefer the EXT spelling where present
  (per-call method, explicit stage and access bits, the `MEMORY_DECOMPRESSION` usage flag); fall
  back to NV on older NVIDIA drivers (the RTX 4060's 565.77), and to a compute or CPU decoder
  elsewhere, which is the [GPU decode papers'][p-gpu-decode] recommendation and needs the
  compute pipeline that does not exist yet ([shaders baseline G1][bl-shaders]).
- **Q5 — YCbCr conversion is pipeline state, so the colour model must be known when pipelines
  are built.** The matrix, range and siting become an immutable sampler; a viewer needs a small
  cache of pipelines keyed by those three plus the format. That argues for CICP-derived enums in
  the image core that map one-to-one onto `VkSamplerYcbcrModelConversion` and
  `VkSamplerYcbcrRange` ([concepts][c-ycbcr]), not for colour logic in `ui-vulkan`
  ([baseline G10][bl-vk-gaps]).
- **Q4, Q8 — Transfers trust their arguments, so validation lives in D.** Region extents,
  strides and decompressed sizes must come from header fields the decoder has already bounded. A
  `@safe` function that builds `VkBufferImageCopy` regions from a validated view and asserts the
  addressing equation's last byte lies within the staging slice is cheap and testable without a
  GPU.
- **Q8 — lavapipe covers more of this page than the baseline assumes** ([§10](#_10-testing-and-conformance)):
  strided, planar and host-copied readback tests can run in CI; the rest need `skipTest`.
- **Q3, Q9 — Format support is device data, not code.** No block family is universal
  ([hardware matrix][hw-formats]), and the RTX 4060 shows format bits can disagree with feature bits.
  A per-device format table filled from `vkGetPhysicalDeviceFormatProperties2` and the features,
  as [baseline D2][bl-vk-grill] proposes (option A plus C), is what every upload decision consults.

---

## Strengths

- The addressing equations make strided, sub-rectangle, planar and block-compressed uploads one
  formula, with every term defined.
- Every capability is queryable per device, family, format and usage, including whether host copy
  degrades device access (`VkHostImageCopyDevicePerformanceQuery`).
- Host image copy removes the staging buffer, its peak memory and the command-buffer round trip,
  with no pointer alignment or granularity requirements.
- External memory covers host pointers, dma-buf with explicit per-plane layouts, and
  cross-process or cross-API ownership through `VK_QUEUE_FAMILY_EXTERNAL` and `FOREIGN_EXT`.
- The EXT decompression extension fixed the NV design's rough edges: extensible info struct, a
  dedicated pipeline stage and access bits, a usage flag, and a bounded indirect count.
- Promotion keeps aliases, so code written against the extension names keeps working on 1.4.

## Weaknesses

- The staging path costs an extra copy and, transiently, double the memory for every upload;
  every alternative is optional and unevenly deployed.
- Strides are in texels, so byte-pitched sources with odd padding need a repack.
- Transfer-only queues add ownership barriers and, on AMD's Linux driver, are not exposed by
  default at all.
- Host image copy moves the swizzle to the CPU and may change the image's memory type or layout;
  its benefit is device-specific and the proposal tells applications to measure.
- GPU decompression supports one method, is NVIDIA-only on the matrix, cannot run on transfer
  queues, and leaves an unvalidated size to the caller.
- YCbCr conversion is immutable pipeline state, multiplying pipelines by colour models.
- Valid usage is enforced only by validation layers, so an incorrect region is undefined
  behaviour in production.

---

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                     | Trade-off                                                                                    |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Optimal tiling is opaque; uploads go through a copy command           | Vendors keep their swizzles private; the copy engine converts                 | One extra copy and a staging buffer per upload                                               |
| Strides in texels or blocks, not bytes                                | One equation covers uncompressed, planar and block formats                    | Byte-pitched sources that are not texel multiples must be repacked                           |
| Exclusive sharing with explicit ownership transfer                    | Lets drivers keep per-family compression and caches                           | Two barriers and a semaphore per cross-queue handoff; concurrent mode as the costly opt-out  |
| Vulkan 1.4: host image copy or an extra transfer queue                | Guarantees some upload path that does not occupy the graphics queue           | Applications still branch on which one a device chose                                        |
| Host image copy as an optional, measured path                         | CPU swizzle may beat or lose to the GPU copy depending on device              | No portable answer; `optimalDeviceAccess` is a hint, not a cost                              |
| Host pointer import without reference counting                        | Works with any allocator, including ones Vulkan cannot track                  | Lifetime is entirely the application's; 4 to 16 KiB alignment on pointer and size            |
| DRM modifiers name layouts instead of describing them                 | Small negotiated set; vendors keep internal layouts private                   | Linux-only; layouts are opaque, so negotiation must happen before allocation                 |
| GDeflate decompression buffer-to-buffer, graphics/compute queues only | Runs on shader cores; reuses the existing copy to reach images                | No transfer-queue offload; a separate copy to the image; one method; unvalidated output size |
| EXT revision of the NV extension                                      | Cross-vendor ratification, explicit sync stage, usage flag, extensible struct | Two spellings in the field; drivers before the EXT expose only NV                            |
| YCbCr conversion as immutable sampler state                           | Lets hardware fuse conversion into texture fetch                              | A pipeline per colour model and format                                                       |

---

## Sources

- Vulkan-Docs at `a8b088a3f`: [`chapters/copies.adoc`][copies], [`chapters/resources.adoc`][res-tiling],
  [`chapters/synchronization.adoc`][sync-qfot], [`chapters/devsandqueues.adoc`][dq-gran],
  [`chapters/memory.adoc`][mem-host-life], [`chapters/memory_decompression.adoc`][dec-chapter],
  [`chapters/samplers.adoc`][samp-immutable], [`chapters/features.adoc`][feat-bc],
  [`chapters/capabilities.adoc`][cap-dmabuf], the common valid-usage files
  ([`buffer_or_memory_image_copy_common.adoc`][cv-bomic], [alignment][cv-align],
  [command-buffer][cv-cbti]), [`xml/vk.xml`][vkxml], the appendices for
  [`VK_EXT_host_image_copy`][hic-app], [`VK_EXT_memory_decompression`][dec-issue],
  [`VK_NV_memory_decompression`][dec-nv-app], [`VK_EXT_external_memory_dma_buf`][dmabuf-one],
  [`VK_EXT_image_drm_format_modifier`][drm-app-name] and
  [`VK_KHR_sampler_ycbcr_conversion`][ycbcr-app], and the proposals for
  [`VK_EXT_host_image_copy`][hic-prop] and [`VK_EXT_memory_decompression`][dec-prop].
- Mesa's [environment variables][mesa-env] page (current, read November 14, 2026) for RADV's
  transfer queue.
- Commands run on this machine on November 14, 2026, in `/tmp/vk-transfer-demo`: `vulkaninfo`
  (vulkan-tools from `nix-shell -p vulkan-tools`, instance 1.4.328); the PCI resource file of each
  display controller; `hic.c`, built with GCC against `vulkan-headers` 1.4.328 and run against
  RADV and llvmpipe.
- Sparkles context: the [Vulkan][bl-vk], [event-horizon][bl-eh], [shaders and SIMD][bl-shaders]
  and [existing code][bl-existing] baselines; `libs/ui-vulkan/src/sparkles/ui_vulkan/upload.d`;
  the [hardware matrix][hw] and its raw reports; the [GPU decode][p-gpu-decode] and [texture
  compression][p-texture] paper threads; [concepts][concepts]; [Skia][skia] and [DLPack][dlpack].

<!-- References -->

[repo]: https://github.com/KhronosGroup/Vulkan-Docs/tree/a8b088a3fae12c8575407ea90c7c09bd653db923
[license]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/LICENSE.adoc
[docs-spec]: https://docs.vulkan.org/spec/latest/index.html
[vkxml]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/vk.xml
[vkxml-nv]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/vk.xml#L28552-L28567
[vkxml-ext]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/vk.xml#L30566-L30587
[vkxml-cmds]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/vk.xml#L18467-L18504
[copies]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/copies.adoc
[copies-bic]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/copies.adoc#L1104-L1110
[copies-addr]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/copies.adoc#L873-L896
[copies-planar]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/copies.adoc#L968-L973
[copies-hic]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/copies.adoc#L1474-L1507
[copies-hic-sync]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/copies.adoc#L1540-L1549
[cv-bomic]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/commonvalidity/buffer_or_memory_image_copy_common.adoc#L12-L20
[cv-align]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/commonvalidity/copy_bufferimage_to_imagebuffer_buffer_alignment_common.adoc#L12-L29
[cv-cbti]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/commonvalidity/copy_buffer_to_image_command_buffer_common.adoc#L21-L36
[dq-gran]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/devsandqueues.adoc#L1374-L1427
[dq-transfer-note]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/devsandqueues.adoc#L1521-L1529
[res-tiling]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/resources.adoc#L5112-L5124
[res-linear]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/resources.adoc#L1872-L1883
[res-ycbcr]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/resources.adoc#L1885-L1900
[sync-qfot]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/synchronization.adoc#L8032-L8038
[sync-foreign]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/synchronization.adoc#L8070-L8108
[sync-undefined]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/synchronization.adoc#L8090-L8093
[sync-release]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/synchronization.adoc#L8111-L8145
[mem-types]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/memory.adoc#L675-L681
[mem-alloc-align]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/memory.adoc#L1681-L1684
[mem-host-life]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/memory.adoc#L3006-L3009
[mem-host-align]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/memory.adoc#L3041-L3043
[cap-dmabuf]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/capabilities.adoc#L625-L628
[dec-chapter]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/memory_decompression.adoc
[dec-cap]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/memory_decompression.adoc#L56-L73
[dec-issue]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_memory_decompression.adoc#L26-L41
[dec-nv-app]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_NV_memory_decompression.adoc
[dec-prop]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_memory_decompression.adoc
[dec-prop-problem]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_memory_decompression.adoc#L14-L27
[hic-prop]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_host_image_copy.adoc
[hic-prop-problem]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_host_image_copy.adoc#L13-L30
[hic-prop-peak]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_host_image_copy.adoc#L24-L27
[hic-prop-limits]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_host_image_copy.adoc#L227-L246
[hic-prop-bc]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_host_image_copy.adoc#L248-L276
[hic-prop-qfot]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/proposals/VK_EXT_host_image_copy.adoc#L288-L290
[hic-app]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_host_image_copy.adoc#L20-L33
[hic-promo]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_host_image_copy.adoc#L43-L58
[hic-issues]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_host_image_copy.adoc#L79-L89
[dmabuf-one]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_external_memory_dma_buf.adoc#L18-L54
[drm-app-name]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_image_drm_format_modifier.adoc#L58-L64
[ycbcr-app]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_KHR_sampler_ycbcr_conversion.adoc#L31-L57
[samp-immutable]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/samplers.adoc#L780-L791
[samp-chroma]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/samplers.adoc#L1015-L1019
[feat-bc]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/features.adoc#L440-L446
[mesa-env]: https://docs.mesa3d.org/envvars.html
[hw]: ./hardware/index.md
[hw-devices]: ./hardware/index.md#devices
[hw-formats]: ./hardware/index.md#texture-and-ycbcr-formats
[hw-compute]: ./hardware/index.md#compute
[r-4090]: ./hardware/reports/linux-geforce-rtx-4090-laptop.json
[bl-vk]: ./baseline/vulkan.md
[bl-vk-gaps]: ./baseline/vulkan.md#gaps-and-tensions
[bl-vk-contracts]: ./baseline/vulkan.md#contracts-that-constrain-image-and-video-work
[bl-vk-caps]: ./baseline/vulkan.md#capability-table
[bl-vk-grill]: ./baseline/vulkan.md#questions-for-the-design-grill
[bl-eh]: ./baseline/event-horizon.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-existing]: ./baseline/existing-code.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
[p-texture]: ./papers/gpu-texture-compression.md
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-plane]: ./concepts.md#plane
[c-tiling]: ./concepts.md#tiling
[c-bcn]: ./concepts.md#block-compressed-formats-and-supercompression
[c-ycbcr]: ./concepts.md#ycbcr-and-matrix-coefficients
[c-range]: ./concepts.md#full-and-limited-range
[c-staging]: ./concepts.md#staging-and-upload
[c-extmem]: ./concepts.md#external-memory-and-zero-copy-import
[c-gpudec]: ./concepts.md#gpu-decompression
[mir]: ./mir-algorithm/
[slice-exp]: ./mir-algorithm/slice-experiment.md
[skia]: ./skia.md
[dlpack]: ./dlpack.md
