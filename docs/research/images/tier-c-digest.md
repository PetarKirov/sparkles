# Tier C digest

The [master catalog](./index.md#master-catalog) puts eight subjects in Tier C: closed
implementations that Sparkles cannot read or run (Apple ImageIO, vImage and Metal fast
resource loading; Intel IPP; NVIDIA GPUDirect Storage and nvCOMP), plus two open subjects
whose lesson for the image library is narrow enough for one entry (Open3D with PCL, and
the QOI format). Each entry is read from the vendor's or project's official
documentation and reference, and covers what the subject is, its pixel or buffer model
and its API shape in the reference's own type and function names. It then says what
transfers to Sparkles and what does not, tagged with the nine
[questions](./index.md#questions-this-survey-answers) (**Q1**..**Q9**). Where
a subject has a sibling deep-dive that reads an open counterpart, the summary table names
it.

**Last reviewed:** November 15, 2026

> [!NOTE]
> Every claim on this page is **documented, not verified**. Sparkles has none of these
> platforms' closed implementations to test, so the page reports what each reference
> says, not what a program observed. Where the [hardware matrix][hw] has a verified fact
> that bears on a claim, the entry says so: the Apple M4 Max (unified memory, SME and
> SME2, VideoToolbox, MoltenVK) for the three Apple subjects, and the RTX 4060 and
> RTX 4090 laptops (GDeflate 1.0 through `VK_NV_memory_decompression` and
> `VK_EXT_memory_decompression`) for nvCOMP. No device in the matrix was probed for
> GPUDirect Storage, and no x86 host was probed for IPP's dispatch path. Open3D, PCL and
> the QOI reference decoder are open source: their file citations are pinned to the
> revisions in [`sources.tsv`](./sources.tsv) (Open3D `b6c5e1963`, PCL `dd4edf371`) or to
> the `qoi.h` commit named below, but nothing from them was built or run for this page.

## Summary

| Subject                                                     | Vendor        | Platform                                         | What it does for images                                                                                  | Questions it informs | Closest deep-dive                                                                              |
| ----------------------------------------------------------- | ------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------- |
| [Open3D and PCL](#open3d-and-pcl)                           | Open3D, PCL   | C++ and Python; CPU and CUDA                     | depth and RGB-D images, organized point clouds and range images as spatial data next to images           | Q1, Q2, Q4, Q8, Q9   | [ROS `image_transport`](./ros-image-transport.md), [DLPack](./dlpack.md)                       |
| [Apple ImageIO](#apple-imageio)                             | Apple         | macOS, iOS, iPadOS, tvOS, visionOS, watchOS      | the system codec layer: incremental decoding, encoding, thumbnails, metadata dictionaries, HEIC and AVIF | Q4, Q5, Q8, Q9       | [OpenImageIO](./openimageio.md), [libheif](./libheif.md)                                       |
| [Apple vImage](#apple-vimage-in-accelerate)                 | Apple         | Apple platforms, CPU vector units                | strided-buffer image kernels: conversion, convolution, geometry, histograms, alpha compositing           | Q1, Q3, Q7, Q9       | [Highway](./highway.md), [libvips](./libvips.md)                                               |
| [Intel IPP](#intel-ipp)                                     | Intel         | x86-64 Windows and Linux                         | step-and-ROI image primitives with per-CPU binary dispatch, tiled threading wrappers                     | Q1, Q3, Q7, Q9       | [OpenCV](./opencv.md), [Highway](./highway.md)                                                 |
| [GPUDirect Storage](#nvidia-gpudirect-storage)              | NVIDIA        | Linux (and a Windows handle type), CUDA GPUs     | DMA from storage into GPU memory without a CPU bounce buffer, synchronous, batched and stream-ordered    | Q6                   | [Vulkan transfer](./vulkan-transfer.md), [DirectStorage and IoRing](./directstorage-ioring.md) |
| [nvCOMP and GDeflate](#nvcomp-and-gdeflate)                 | NVIDIA        | CUDA GPUs; GDeflate also in DirectStorage/Vulkan | batched GPU decompression; GDeflate, a bit-swizzled DEFLATE decodable 32 ways in parallel                | Q4, Q6, Q7           | [Vulkan transfer](./vulkan-transfer.md), [DirectStorage and IoRing](./directstorage-ioring.md) |
| [Metal fast resource loading](#metal-fast-resource-loading) | Apple         | macOS 13, iOS 16 and later                       | file-to-`MTLBuffer`/`MTLTexture` command queues with chunked compressed packs                            | Q4, Q6               | [Vulkan transfer](./vulkan-transfer.md), [DirectStorage and IoRing](./directstorage-ioring.md) |
| [QOI](#qoi)                                                 | qoiformat.org | specification and a single-header C reference    | a one-page lossless RGB(A) format: 14-byte header, six chunk kinds, 8-byte end marker                    | Q4, Q5, Q8           | [Wuffs](./wuffs.md)                                                                            |

## Open3D and PCL

[Open3D][o3d-docs] and the [Point Cloud Library][pcl-docs] are the two open C++ libraries
for 3D data from depth sensors: point clouds, meshes, registration and reconstruction.
They are Tier C here because only their image-adjacent types matter to Sparkles: a depth
map is an image whose samples are distances, an RGB-D frame is two registered images,
and an organized point cloud is an image whose pixels are 3D points. Both libraries
treat those as geometry first, and their image types show what an image library must
hand over at that boundary.

Open3D has two image models. The legacy [`open3d::geometry::Image`][o3d-image-h] holds
`width_`, `height_`, `num_of_channels_`, `bytes_per_channel_` and a
`std::vector<uint8_t> data_`: an owning, dense buffer whose row size `BytesPerLine()` is
computed from the other fields, so there is no stride and no view. The tensor-based
[`open3d::t::geometry::Image`][o3d-t-image-h] wraps a `core::Tensor data_` of shape
`(rows, cols, channels)` with a dtype and a device; its header says "Row-major storage is
used, similar to OpenCV. Use (row, col, channel) indexing order", and asks callers to
"avoid using width, height, u, v, x, y for coordinates" ([Python reference][o3d-t-image]).
`To(device)` moves an image between CPU and CUDA, and the underlying
[`Tensor`][o3d-tensor-h] exports `ToDLPack()`, which links it to the
[DLPack](./dlpack.md) exchange. [`RGBDImage`][o3d-rgbd-h] is "a pair of registered color
and depth images, viewed from the same view, of the same resolution", built by
`CreateFromColorAndDepth(color, depth, depth_scale = 1000.0, depth_trunc = 3.0,
convert_rgb_to_intensity = true)` and by dataset-specific factories
(`CreateFromRedwoodFormat`, `CreateFromTUMFormat`, `CreateFromSUNFormat`,
`CreateFromNYUFormat`) ([tutorial][o3d-rgbd-tut]). `PointCloud::CreateFromRGBDImage`
and the tensor image's `CreateVertexMap(intrinsics)` turn pixels into points.
**Q1**: Open3D's own move from the legacy type to an N-D tensor with a device is
evidence for the N-D, device-aware view the survey is weighing; the legacy type's
missing stride is the cost it paid. **Q2**: the depth units (`depth_scale`) and
truncation travel as loose function parameters, not as part of the image's type.

PCL's [`pcl::PointCloud<PointT>`][pcl-pc-h] is a `std::vector<PointT>` of `points` plus
`width`, `height` and `is_dense`: "The point cloud width (if organized as an
image-structure)", and `isOrganized()` returns `height > 1`. An organized cloud is
indexed `at(column, row)` like an image. The type-erased
[`pcl::PCLPointCloud2`][pcl-pc2-h] is closer still to a strided image: `height`, `width`,
a list of `fields` (name, offset, datatype, count), `point_step`, `row_step`,
`is_bigendian` and a `std::vector<std::uint8_t> data`, which is a self-describing record
layout with a row stride. [`pcl::PCLImage`][pcl-image-h] copies the ROS `Image` message
(`encoding`, `step`), and [`RangeImage`][pcl-range] is a `PointCloud<PointWithRange>` built
by `createFromPointCloud` with an angular resolution. **Q1**, **Q2**: a pixel whose type
is a runtime list of named fields with offsets is the same description problem as a
planar or packed pixel format; PCL solves it with both a compile-time `PointT` and a
run-time field table, and converts between them.

PCL's [PCD file format][pcl-pcd] states the image link directly: `WIDTH` "can specify the
width (total number of points in a row) of an organized point cloud dataset", and an
organized dataset is one that "resemble[s] an organized image (or matrix) like
structure". Its `DATA` line selects `ascii`, `binary` or `binary_compressed`, the last
LZF-compressed behind two 32-bit words at the start of the body, the compressed and the
uncompressed size; the reader rejects an uncompressed size that differs from the one the
header implies or from what LZF produced ([`pcd_io.cpp`][pcl-pcd-io]). **Q4**: a text header followed by a raw or compressed body
is the same shape as Netpbm and is a small test of how `sparkles:wired` describes a
header whose fields choose the body's layout.

What transfers: a depth image is an ordinary single-channel `u16` or `f32` image with
units and an invalid value, and an organized cloud is an image of 3- or 4-float pixels,
so both fit an N-D view with a record pixel type (**Q1**), and Open3D's dataset factories
name the RGB-D corpora (TUM, Redwood, SUN, NYU) a correctness suite could borrow
(**Q8**). What does not: reconstruction, registration, k-d trees and meshes belong in a
geometry package that consumes image views, not in image-core (**Q9**).

## Apple ImageIO

[Image I/O][imageio] is Apple's system codec framework: it "allows applications to read
and write most image file formats" and offers "color management, and access to image
metadata". Its functions are documented as available from macOS 10.4 and iOS 4 on every
Apple platform, and it is closed source. Applications see two opaque types, [`CGImageSource`][cgis] for reading
and [`CGImageDestination`][cgid] for writing, and receive decoded pixels as Core
Graphics `CGImage` objects, so the pixel model is whatever `CGImage` and its bitmap info
describe; ImageIO itself exposes no buffer.

Reading starts from `CGImageSourceCreateWithURL`, `CGImageSourceCreateWithData` or
`CGImageSourceCreateWithDataProvider`. A source holds a count of images
(`CGImageSourceGetCount`, `CGImageSourceGetPrimaryImageIndex`), each decoded by
`CGImageSourceCreateImageAtIndex` with an options dictionary. Incremental loading is a
separate constructor: [`CGImageSourceCreateIncremental`][cgis-incr] "creates an empty
image source container, which you use to accumulate data downloaded in chunks from the
network", fed by `CGImageSourceUpdateData` or `CGImageSourceUpdateDataProvider`, and
polled with `CGImageSourceGetStatus`/`CGImageSourceGetStatusAtIndex`, which return a
[`CGImageSourceStatus`][cgis-status] (`statusUnexpectedEOF`, `statusInvalidData`,
`statusUnknownType`, `statusReadingHeader`, `statusIncomplete`, `statusComplete`). The
update call is not a push of new bytes: "Each time you call the method, you must specify
all of the accumulated image data, not just the new data you received"
([`CGImageSourceUpdateData`][cgis-update]). **Q4**: this is incremental decoding without
suspension; the caller owns a growing buffer and the framework may re-parse it, which is
the opposite trade from [Wuffs](./wuffs.md#the-image-decoder-interface)'s suspendable
coroutine over a sliding buffer.

Thumbnails and reduced decoding are options, not separate APIs.
[`CGImageSourceCreateThumbnailAtIndex`][cgis-thumb] honours
`kCGImageSourceCreateThumbnailFromImageIfAbsent` (use an embedded thumbnail if present),
[`kCGImageSourceCreateThumbnailFromImageAlways`][cgis-thumb-always] (decode the full image,
bounded by `kCGImageSourceThumbnailMaxPixelSize`; without that key "the image source
creates the thumbnail using the image's full size, which in most cases is not
desirable") and `kCGImageSourceCreateThumbnailWithTransform`.
[`kCGImageSourceSubsampleFactor`][cgis-subsample] asks for 2, 4 or 8 times smaller output
and is supported "only for JPEG, HEIF, TIFF, and PNG images"; when unsupported, "the image
source provides a larger or full-size normal image". Decoding is lazy by default:
[`kCGImageSourceShouldCacheImmediately`][cgis-cache] defaults to false, "which causes
decoding and caching to happen only when you render the image". **Q4**, **Q9**: a viewer
needs decode-at-scale and embedded-thumbnail extraction as first-class requests, and
ImageIO's contract that a codec may silently return more pixels than requested is one
the Sparkles decoder interface would have to state explicitly.

Metadata is a dictionary per container and per image. `CGImageSourceCopyProperties`
returns the [container properties][imageio-props] (`kCGImagePropertyFileSize`,
`kCGImagePropertyImageCount`, `kCGImagePropertyPrimaryImage`, …) and
[`CGImageSourceCopyPropertiesAtIndex`][cgis-props-at] the per-image ones
(`kCGImagePropertyPixelWidth`, `kCGImagePropertyDepth`, `kCGImagePropertyHasAlpha`,
`kCGImagePropertyOrientation`, `kCGImagePropertyNamedColorSpace`, plus nested EXIF, IPTC,
GPS, maker-note and per-format dictionaries). HEIF has
[`kCGImagePropertyHEICSDictionary`][imageio-heics] (macOS 10.15, iOS 13) with canvas size,
frame info, delay and loop count; AVIF has
[`kCGImagePropertyAVISDictionary`][imageio-avis] (macOS 13, iOS 16), which is the
documented evidence of AVIF support; the reference lists no keys under it. For writing,
`CGImageDestinationAddImage`, `CGImageDestinationAddImageFromSource`,
`CGImageDestinationSetProperties` and `CGImageDestinationAddAuxiliaryDataInfo` precede
`CGImageDestinationFinalize`, with options such as
`kCGImageDestinationLossyCompressionQuality`, `kCGImageDestinationEmbedThumbnail`,
`kCGImageDestinationPreserveGainMap` and `kCGImageMetadataShouldExcludeGPS`
([`CGImageDestination`][cgid]). **Q5**: auxiliary data (depth, gain maps) and metadata
merge-on-copy are part of the writer, which the [gain maps](./gain-maps.md) entry treats
in its own right.

What transfers: a source/destination split, an image index within a container, status
values that separate "incomplete" from "invalid", and options-dictionary requests for
thumbnails and subsampling (**Q4**). On macOS ImageIO is also a differential oracle for
HEIC, AVIF and JPEG decoding (**Q8**); the hardware matrix's M4 Max reports VideoToolbox
decoding H.264, HEVC, AV1, VP9, ProRes and JPEG ([platform media APIs][hw-media]), but
whether ImageIO's HEIC or AVIF decode uses that hardware is not documented. What does not:
the `CFDictionary` string-key property model and the re-feed-everything incremental
contract.

## Apple vImage in Accelerate

[vImage][vimage] is the image part of Accelerate: "a high-performance image processing
framework" with "convolutions, geometric transformations, histogram operations,
morphological transformations, and alpha compositing" and "format conversions", which
"optimizes image processing by using the CPU's vector processor". It is closed source,
present since macOS 10.3, and runs on the CPU only.

Its pixel model is one struct. [`vImage_Buffer`][vimage-buffer] "stores an image's pixel
data, dimensions, and row stride" in four fields, `data`, `height`, `width` and
`rowBytes`; the pixel format is not in the struct but in the function name
(`_ARGB8888`, `_Planar8`, `_PlanarF`, …). [`vImageBuffer_Init`][vimage-init] allocates
"memory that the vImage library sizes and aligns for the best performance" and may pad
rows: the reference's example asks for a 10-pixel 8-bit row and gets 16 bytes; with
`kvImageNoAllocate` it only reports the preferred alignment and `rowBytes`. A region of
interest is a second `vImage_Buffer` whose `data` points into the first with a smaller
`width` and `height` and the same `rowBytes` ([ROI article][vimage-roi]); neighbourhood
functions add explicit offsets, as in [`vImageConvolve_ARGB8888`][vimage-conv]
`(src, dest, tempBuffer, srcOffsetToROI_X, srcOffsetToROI_Y, kernel, kernel_height,
kernel_width, divisor, backgroundColor, flags)`, so the kernel can read source pixels
outside the ROI. **Q1**: this is the minimal strided view (pointer, extent, row stride)
with views made by pointer arithmetic, and the same four numbers the
[`Slice` experiment](./mir-algorithm/slice-experiment.md) maps to mir; the planar versus
interleaved choice is a function-name axis, and Apple's own
[performance article][vimage-perf] recommends converting to planar when only some
channels matter.

Format conversion is a reusable object. [`vImage_CGImageFormat`][vimage-cgformat]
describes a Core Graphics layout (`bitsPerComponent`, `bitsPerPixel`, `colorSpace`,
`bitmapInfo`, `version`, `decode`, `renderingIntent`), and
[`vImageConverter_CreateWithCGImageFormat`][vimage-conv-create]`(srcFormat, destFormat,
backgroundColor, flags, error)` builds a [`vImageConverter`][vimage-converter] that "is
intended to be used and reused with" [`vImageConvert_AnyToAny`][vimage-anytoany]
`(converter, srcs, dests, tempBuffer, flags)`. Converters "are thread safe", may be
expensive to create, and take arrays of buffers, so a planar or YCbCr format is several
`vImage_Buffer`s; the conversion is documented as one where "conversion passes are
vectorized and multithreaded". Chunked formats (YCbCr 4:2:2 and 4:2:0, sub-byte pixels)
are handled with a written rule for odd widths: when writing an incomplete chunk "vImage
copies the rightmost valid pixel color into the unused part of the chunk". **Q2**, **Q3**:
a converter compiled once from two format descriptions and applied to many buffers is
the run-time analogue of a templated conversion kernel, and it is the shape a
format-generic `convert(src, dst)` with a cached plan would take.

Threading and tiling are on by default and switched off by flag:
[`kvImageDoNotTile`][vimage-notile] "disables vImage internal tiling routines. Set this
flag if you want to perform your own tiling or your own multithreading". Scratch memory
follows a two-call protocol: pass `kvImageGetTempBufferSize` to get the size, allocate,
then pass the buffer on later calls, or pass `nil` to let vImage allocate per call
([`vImageConvolve_ARGB8888`][vimage-conv]). **Q7**: an internal scheduler that a caller
can disable when it schedules tiles itself is the contract a Sparkles kernel needs when
it runs inside `sparkles:event-horizon`'s pools, and the explicit temp-buffer query keeps
the kernel `@nogc`-friendly. The M4 Max in the [hardware matrix][hw-simd] reports NEON
with dot product, I8MM, BF16 and SME/SME2; which of these vImage uses is not documented.

What does not transfer: the pixel format living in the function name rather than in a
type (one entry point per format and operation), Core Graphics as the only format vocabulary for the
converter, and a CPU-only scope (**Q9**: vImage is the evidence that an
algorithms package can be useful with no GPU path at all, not that it should have none).

## Intel IPP

[Intel Integrated Performance Primitives][ipp] is a closed-source C library of signal and
image primitives for x86-64. Its image model is a typed pointer plus a byte step: "The
data storage for an image can be either pixel-oriented or plane-oriented (planar)", with
1 to 4 channels in pixel order, "All channels in an image must have the same data type",
and alpha either last (`AC4`) or first (`A0C4`) ([data types][ipp-types]). The element
types are `Ipp8u`, `Ipp16u`, `Ipp16s`, `Ipp32f` and so on, and a function name spells the
whole format: `8u_C3R` is 8-bit unsigned, three interleaved channels, with an ROI.

Every image function is an ROI function. A call passes `pSrc` and `pDst` "pointers to
the starts of source and destination ROI buffers", `srcStep` and `dstStep`, "distances in
bytes between the starting points of consecutive lines", and an `IppiSize roiSize`
([regions of interest][ipp-roi]). The reference insists the step is in bytes: "it is not
recommended to use step/SizeOf(Ipp32f) as in a general case step value may be not a
multiple of 4". Neighbourhood functions read outside the ROI and "assume that the points
in the neighborhood exist"; if those border pixels are not defined, "you may get memory
violation errors". The modern filters take a border mode instead:
[`ippiFilterGaussian`][ipp-gauss] is declared as
`ippiFilterGaussian_<mod>(pSrc, srcStep, pDst, dstStep, roiSize, borderType, borderValue, pSpec, pBuffer)`
with `mod` from `8u_C1R` to `32f_C3R`, an opaque `IppFilterGaussianSpec` built by
`FilterGaussianInit` after sizing it with `FilterGaussianGetSpecSize` and
`FilterGaussianGetBufferSize` (the non-platform-aware functions size both with
`FilterGaussianGetBufferSize`), and errors such as `ippStsStepErr` ("an error when srcStep
or dstStep is less than" `roiSize.width*<pixelSize>`) and `ippStsNotEvenStepErr`. **Q1**: pointer, byte
stride and extent, with views made by pointer offset, is the same view as vImage's; IPP
adds that bounds are the caller's problem and that the border mode is a parameter.
**Q3**: the spec/init/buffer split separates a reusable plan from per-call scratch.

Size and threading come in suffixes. "Platform-aware" functions end in `_L` and take
`IppSizeL` and `IppiSizeL` so that images can exceed "32-bit integer size"
([platform-aware][ipp-pa]). Threading Layer functions end in `_LT` or `_T`, are
"implemented as wrappers over Intel IPP functions by using tiling and multithreading with
OpenMP* or the Intel® Threading Building Blocks", and ship both as pre-built
libraries and as source samples ([Threading Layer][ipp-tl]) with helpers `SplitUniform2D`, `ParallelFor`,
`GetTilePointer` and `GetTileParamsByIndex` ([TL functions][ipp-tl-fns]). They replace the
older [Integration Wrappers][ipp-iw-ov], whose `IwiImage`, `IwiTile` and C++
`iwiFilterGaussian(srcImage, dstImage, kernelSize, sigma, auxParams, border, tile)`
handled temporary buffers and border flags per tile. The wrappers' [tiling
guide][ipp-iw-tile] states the hard case precisely: for a filter border larger than 1 pixel,
borders overlap a tile edge when `tile_size < border_size` (left and top borders) or
`(image_size%tile_size > 0) && (image_size%tile_size < border_size)` (right and bottom
borders), and ignoring the overlap gives up "the bit-exact quality of tiling around image
boundaries". **Q7**: that pair of conditions is a ready test oracle for any Sparkles
tiled filter.

CPU dispatch is per binary path. "A single Intel IPP function, for example
`ippsCopy_8u()`, may have many versions", prefixed by CPU code (`y8` for SSE4.2, `l9` for
AVX2, `k0` for AVX-512, with `m7` and the deprecated `n8` and `e9`), and "during normal
operation the dispatcher determines the best version and you can call a generic
function" ([dispatching][ipp-dispatch]). **Q3**, **Q7**: one exported name, several
compiled bodies and a load-time choice is the shape [Highway](./highway.md) and
`intel-intrinsics` give in source form; the matrix's [CPU SIMD][hw-simd] table shows why
the choice matters on Sparkles' hosts: AVX-512 on Zen 4 only, AVX2 with FMA everywhere
x86. How IPP dispatches on AMD CPUs is not stated on the dispatching page, which names
Intel processors throughout.

What transfers: the byte-step ROI view, a border-mode parameter rather than a precondition,
plan/scratch/execute, and tiling as an optional outer layer over unthreaded kernels
(**Q9**: IPP keeps threading out of the primitive library). What does not: the format in
the function name, `int` sizes in the base API, and a closed binary whose dispatch rules
are only partly documented.

## NVIDIA GPUDirect Storage

[GPUDirect Storage][gds-overview] "enables a direct data path for direct memory access
(DMA) transfers between GPU memory and storage, which avoids a bounce buffer through the
CPU". Applications use it through the [cuFile API][gds-api] (reference v1.20); the
reference names the `nvidia-fs.ko` kernel driver as the provider of the direct path, and
the user-space library is closed source.

The API has four layers ([specification][gds-spec], [functional
specification][gds-func]). Driver: `cuFileDriverOpen()` and `cuFileDriverClose()`, plus
property setters such as `cuFileDriverSetMaxDirectIOSize` and `cuFileDriverSetPollMode`,
whose sizes are in KB and "must be 4K aligned". Files: `cuFileHandleRegister(CUfileHandle_t
*fh, CUfileDescr_t *descr)` takes a `CUfileDescr_t` holding a `CUfileFileHandleType`
(`CU_FILE_HANDLE_TYPE_OPAQUE_FD`, `CU_FILE_HANDLE_TYPE_OPAQUE_WIN32`,
`CU_FILE_HANDLE_TYPE_USERSPACE_FS`), a union of `fd` or `handle`, and an `fs_ops` table;
`cuFileHandleDeregister` releases it. Buffers: `cuFileBufRegister(const void
*bufPtr_base, size_t size, int flags)` "registers existing cuMemAlloc'd (pinned) memory for GDS IO operations or
host memory for IO operations", "incurs a
significant performance cost, so registration costs should be amortized", but is
optional: without it "cuFile-managed and internally pinned buffers are used". I/O:
`ssize_t cuFileRead(fh, bufPtr_base, size, file_offset, bufPtr_offset)` and `cuFileWrite`,
synchronous, working "correctly for unaligned offsets and any data size, although the
performance might not match the performance of aligned reads".

Two asynchronous forms sit on top. The batch API, `cuFileBatchIOSetUp(&batch, max_nr)`,
`cuFileBatchIOSubmit(batch, nr, CUfileIOParams_t *iocbp, flags)`,
`cuFileBatchIOGetStatus(batch, min_nr, &nr, CUfileIOEvents_t *events, timeout)`,
`cuFileBatchIOCancel` and `cuFileBatchIODestroy`, submits arrays of
`CUfileIOParams_t` (mode, buffer, file offset, buffer offset, size, file handle, opcode,
`cookie`) and reaps `CUfileIOEvents_t` (`cookie`, status, `ret`). The stream API,
`cuFileReadAsync` and `cuFileWriteAsync`, enqueues on a `CUstream` and takes pointers to
size and offsets so they can be filled in later; `cuFileStreamRegister(stream, flags)`
declares which are "valid at submission time" and whether all are 4K aligned, with
`0xf` documented to "perform best". **Q6**: the batch API is `io_uring`'s submission and
completion queues with a cookie for `user_data`, and the stream API is the GPU-queue-ordered
variant that [Metal](#metal-fast-resource-loading) and DirectStorage also offer; a
Sparkles file-to-GPU seam that models "submit a list, reap by cookie" and "enqueue on a
GPU timeline" covers all three (see [registered buffers and direct I/O][c-regbuf] and the
[event-horizon baseline](./baseline/event-horizon.md)).

Fallback is configuration, not code: "The default behavior for all paths where GDS is not
supported is for the cuFile IO API to attempt IO using file system supported posix mode
APIs when `properties.allow_compat_mode` is set to true", set in `/etc/cufile.json`, and
"For any batch I/O size bigger than the bounce buffer size … cuFile uses compatible
mode". Since GDS 1.7 (CUDA 12.2) a file need not be opened with `O_DIRECT`; an `O_DIRECT`
path is used if one exists. **Q6**: one API whose fast path silently degrades to a
bounce-buffer path is convenient but hides the cost; the Sparkles seam should report
which path it took. What does not transfer: CUDA as the only consumer (Sparkles' GPU API
is Vulkan, which has no storage-to-device DMA; see [Vulkan transfer][vk-transfer]), and the
dependency on a vendor kernel module. No device in the [hardware matrix][hw] was probed
for `nvidia-fs`, so whether GDS runs on the RTX 4060 or 4090 laptops is unknown.

## nvCOMP and GDeflate

[nvCOMP][nvcomp] "provides fast lossless data compression and decompression using a
GPU". It is a closed-source CUDA library with standard formats (LZ4, Snappy, Deflate,
Gzip, Zstandard), NVIDIA formats (Cascaded, Bitcomp, ANS) and
[GDeflate][nvcomp-gdeflate], "a new compression stream format that closely matches the
DEFLATE format". GDeflate is the format shared with DirectStorage's GPU decompression and
with Vulkan's `VK_NV_memory_decompression` and `VK_EXT_memory_decompression`, whose only
method is GDeflate 1.0 (see [Vulkan transfer][vk-decomp] and
[DirectStorage and IoRing](./directstorage-ioring.md)).

The format: "The GDeflate stream is essentially a bit-swizzled version of any DEFLATE
stream where the swizzling is done in a particular way to extract 32-way parallelism",
keeping "the exact same compression ratio of DEFLATE (with some small caveats about end
effects)". The stream is "a serialization of 32 independent sub-streams"; literal and
length-plus-distance codes are dealt to sub-streams in groups of at most 32, "All bits
required for a single match copy (length + distance) are always assigned to the same
sub-stream", and each decoding thread keeps "a 64-bit state" refilled "in 32-bit / 4-byte
chunks" in thread order, which fixes the serialization ([nvCOMP GDeflate][nvcomp-gdeflate]).
An open CPU reference encoder and decoder live in the DirectStorage repository's
[`GDeflate/`][ds-gdeflate] directory, whose tiles default to `kDefaultTileSize = 64 * 1024`
([`config.h`][ds-gdeflate-tile]). **Q7**: GDeflate is a worked example of reshaping an
entropy-coded bitstream for SIMT decoding without changing its model, the move the
[GPU decode papers](./papers/gpu-decode-streaming.md) discuss for image codecs.

The API is batched and stream-ordered. [`nvcompBatchedGdeflateDecompressAsync`][nvcomp-capi]
takes `device_compressed_chunk_ptrs`, `device_compressed_chunk_bytes`,
`device_uncompressed_buffer_bytes`, an output array of actual sizes, `num_chunks`, a temp
buffer and size, `device_uncompressed_chunk_ptrs`, a `nvcompBatchedGdeflateDecompressOpts_t`,
per-chunk `device_statuses` and a `cudaStream_t`; the sizes and pointers themselves live in
device memory. Scratch and alignment are queried first
(`nvcompBatchedGdeflateDecompressGetTempSize`, `…GetTempSizeSync`,
`nvcompBatchedGdeflateDecompressGetRequiredAlignments` returning
`nvcompAlignmentRequirements_t`), and `nvcompBatchedGdeflateGetDecompressSizeAsync`
recovers output sizes. Chunks may be large:
`nvcompGdeflateCompressionMaxAllowedChunkSize = 1u << 31` and
`nvcompGdeflateDecompressionMaxAllowedChunkSize = (1ULL << 32) + 288`, against the 64 KiB
output cap the Vulkan extensions impose for GDeflate 1.0. **Q6**: a chunk table resident on
the GPU is what lets decompression follow a storage read without a CPU round trip; a
Sparkles pack format that targets both nvCOMP and Vulkan must use the smaller,
64 KiB chunk.

**Q4**: the reference is explicit that this path is not hostile-input safe: an invalid
chunk sets `nvcompStatusCannotDecompress`, but "Providing a corrupt buffer for
decompression will result in undefined behavior", and "Violating any of the conditions
listed in the parameter descriptions below may result in undefined behaviour". GPU
decompression therefore belongs only behind integrity checks (a hash or a trusted pack
built by the application), never on untrusted downloads. The [hardware matrix][hw-compute]
verifies the driver path on two devices only: the RTX 4060 laptop exposes GDeflate 1.0
through `VK_NV_memory_decompression`, and the RTX 4090 laptop through both the NV and EXT
extensions; nvCOMP itself was not run.

## Metal fast resource loading

Metal 3 adds [input/output command queues][mtl-loading] "that make the most of a device's
storage hardware, including flash storage and the unified memory architecture of Apple
silicon": a dedicated queue loads file contents directly into Metal buffers and textures
while the GPU works, synchronised with Metal shared events. It is available from macOS 13
and iOS 16, closed source, and Apple-only.

The objects: an [`MTLIOCommandQueueDescriptor`][mtl-iodesc] (`priority`, `type`,
`maxCommandsInFlight`, `maxCommandBufferCount`, `scratchBufferAllocator`) passed to
`MTLDevice`'s `makeIOCommandQueue(descriptor:)` yields an
[`MTLIOCommandQueue`][mtl-ioqueue] ("schedules input/output commands for reading files in
the file system, and writing to GPU resources and memory"), with `makeCommandBuffer()`,
`makeCommandBufferWithUnretainedReferences()` and `enqueueBarrier()`. An
[`MTLIOCommandBuffer`][mtl-iocb] records `load(_:offset:size:sourceHandle:sourceHandleOffset:)`
into an `MTLBuffer`,
`load(_:slice:level:size:sourceBytesPerRow:sourceBytesPerImage:destinationOrigin:sourceHandle:sourceHandleOffset:)`
into an `MTLTexture`, and `loadBytes(_:size:sourceHandle:sourceHandleOffset:)` into CPU
memory, plus `addBarrier()`, `signalEvent(_:value:)`, `waitForEvent(_:value:)`,
`copyStatus(buffer:offset:)`, `commit()`, `tryCancel()` and `waitUntilCompleted()`. Sources
are [`MTLIOFileHandle`][mtl-iofh]s, "a raw or compressed file", made by
`makeIOFileHandle(url:)` or [`makeIOFileHandle(url:compressionMethod:)`][mtl-iofh-make]
(both macOS 14 and iOS 17). They replace the macOS 13 and iOS 16 `makeIOHandle(url:)`
spellings, which the symbol pages mark deprecated from macOS 14 and iOS 17 and the
[overview article][mtl-loading] still names. **Q6**: the texture load takes `sourceBytesPerRow` and
`sourceBytesPerImage`, so the file holds linear, strided rows and Metal performs the
retiling a Vulkan application does with `vkCmdCopyBufferToImage`; the queue carries GPU
event waits and signals, so a load can be ordered against compute work without a CPU
fence.

Compressed packs are produced offline with three C functions:
[`MTLIOCreateCompressionContext`][mtl-cc-create]`(const char *path, MTLIOCompressionMethod
type, size_t chunkSize)`, `MTLIOCompressionContextAppendData` per asset, and
`MTLIOFlushAndDestroyCompressionContext` to write the file;
[`MTLIOCompressionContextDefaultChunkSize()`][mtl-cc-chunk] supplies a default chunk size.
[`MTLIOCompressionMethod`][mtl-iocm] is `zlib`, `lzfse`, `lz4`, `lzma` or `lzBitmap`, the
Compression framework's codecs; nothing in the reference says where decompression runs,
and none of the methods is GDeflate. **Q4**: a pack is a chunked, random-access container
whose chunk size is a parameter, the same shape as DirectStorage's 64 KiB GDeflate tiles
and KTX2's supercompression, which suggests one container description in
`sparkles:wired` with the codec as a field.

What transfers: a load queue that is a peer of the GPU queues, with priority, cancellation
and event-based ordering (**Q6**), and linear-rows-in-file as the on-disk texture layout. What
does not: the API is Metal-only, and Vulkan has no file-to-resource queue for MoltenVK to map it to. The
[hardware matrix][hw-compute] verifies the relevant M4 Max memory facts: a 36 GiB unified
device-local heap and a 16 KiB `VK_EXT_external_memory_host` alignment, measured through
MoltenVK 1.4.2; the matrix does not probe Metal I/O queues themselves.

## QOI

The [Quite OK Image Format][qoi-site] is a lossless RGB and RGBA format whose site claims
it "losslessly compresses images to a similar size of PNG, while offering 20x-50x faster
encoding and 3x-4x faster decoding", with a reference encoder and decoder that "fits in
about 300 lines of C" and a specification that "is a single page PDF". The
[specification][qoi-spec] is version 1.0, dated 2022-01-05, and released under CC0; the
reference [`qoi.h`][qoi-h] is MIT-licensed. Unlike the other subjects here it is fully
open; it is Tier C because one page states the whole format. Its benchmark claims were
not reproduced.

The format, from the specification: "A QOI file consists of a 14-byte header, followed by
any number of data 'chunks' and an 8-byte end marker." The header is `char magic[4]`
(`"qoif"`), `uint32_t width` and `uint32_t height` (big-endian), `uint8_t channels` (3 or 4)
and `uint8_t colorspace` (0 for sRGB with linear alpha, 1 for all channels linear), and
"The colorspace and channel fields are purely informative. They do not change the way data
chunks are encoded." Pixels run row by row from a previous pixel of `{r: 0, g: 0, b: 0, a:
255}`, with straight ("un-premultiplied") alpha. A 64-entry array of seen pixels is indexed
by `(r * 3 + g * 5 + b * 7 + a * 11) % 64`. Six chunk kinds are byte-aligned:
`QOI_OP_RGB` (tag `0xfe`) and `QOI_OP_RGBA` (tag `0xff`), and four with 2-bit tags,
`QOI_OP_INDEX` (`00`, a 6-bit index), `QOI_OP_DIFF` (`01`, three 2-bit differences biased
by 2), `QOI_OP_LUMA` (`10`, a 6-bit green difference and two 4-bit differences relative
to it) and `QOI_OP_RUN` (`11`, a run of 1 to 62 biased by -1). "The 8-bit tags have
precedence over the 2-bit tags. A decoder must check for the presence of an 8-bit tag
first", which is why run lengths 63 and 64 are illegal. The stream ends with seven `0x00`
bytes and one `0x01`.

The reference API is four functions behind `QOI_IMPLEMENTATION`: `qoi_encode(const void
*data, const qoi_desc *desc, int *out_len)`, `qoi_decode(const void *data, int size,
qoi_desc *desc, int channels)`, and the stdio pair `qoi_write` and `qoi_read` (omitted under
`QOI_NO_STDIO`), with a `qoi_desc` of `width`, `height`, `channels` and `colorspace` and
allocation through overridable `QOI_MALLOC`/`QOI_FREE`. Its only resource limit is
`QOI_PIXELS_MAX`, 400 million pixels (an image must have fewer), chosen because "2GB is the max file size that this
implementation can safely handle"; `qoi_decode` rejects a zero dimension, a channel count
other than 3 or 4, a colour space above 1, a wrong magic and an oversized image before it
allocates ([`qoi.h`][qoi-h-decode]). **Q4**: those five header checks plus a pixel budget
are the minimal hostile-input contract, and a whole-image, one-shot decode with no
incremental mode is what the reference gives up for its size.

Why it matters to Sparkles. **Q4**: the header is the simplest case for a `sparkles:wired`
description: a fixed 14-byte big-endian record with a magic, two `u32` extents and two
small enums, where validation (non-zero extents, enum ranges, a pixel budget) is part of
the description. The chunk stream is the next case up: a tagged union whose tag width
varies (8 bits checked before 2), with bit fields biased by constants; the decoder state
(previous pixel, 64-entry index) is codec logic that a format description should not try
to express. The wave 3 [Flat fit experiment](./wired-flat-fit/index.md#qoi) takes QOI as one
of its three formats. **Q8**: [Wuffs](./wuffs.md) ships a QOI decoder
([`std/qoi/decode_qoi.wuffs`][wuffs-qoi]) behind its suspendable image-decoder interface, so
`qoi.h` and Wuffs are two independent decoders for differential testing of a Sparkles
QOI decoder, and the format is small enough that a fuzzer reaches every chunk kind
quickly. **Q5**: QOI also shows what a minimal codec omits: no metadata, no ICC profile,
no animation, no tiling and no random access.

## Sources

- Open3D and PCL: the official documentation at [open3d.org][o3d-docs] and
  [pointclouds.org][pcl-docs] (the [`t.geometry.Image`][o3d-t-image] and
  [`geometry.Image`][o3d-image] Python references, the [RGBD tutorial][o3d-rgbd-tut], the
  [`RGBDImage` C++ reference][o3d-rgbd-cpp], the [`PointCloud`][pcl-pc] and
  [`RangeImage`][pcl-range] class references and the [PCD file format][pcl-pcd] tutorial),
  with header citations pinned to the Open3D and PCL revisions in
  [`sources.tsv`](./sources.tsv).
- Apple: the developer.apple.com references for [Image I/O][imageio],
  [vImage][vimage] and [Metal resource loading][mtl-loading]. The pages are rendered by
  JavaScript; their content was read from the documentation's JSON form of the same
  pages, which carries the declarations, availability and discussion text quoted above.
- NVIDIA: the [GPUDirect Storage overview][gds-overview] and
  [cuFile API reference][gds-api] (v1.20, the [API specification][gds-spec] and
  [functional specification][gds-func]); the [nvCOMP documentation][nvcomp], its
  [GDeflate page][nvcomp-gdeflate] and its [C API][nvcomp-capi].
- Intel: the IPP Developer Guide and Reference, 2022.2 edition ([data types][ipp-types],
  [regions of interest][ipp-roi], [`FilterGaussian`][ipp-gauss], [dispatching][ipp-dispatch],
  [platform-aware functions][ipp-pa], [Threading Layer][ipp-tl]), and the 2020 Integration
  Wrappers reference ([overview][ipp-iw-ov], [tiling and threading][ipp-iw-tile],
  [`iwiFilterGaussian`][ipp-iw-gauss]). Intel marks 2022.2 as superseded by a newer edition;
  the names above were not re-checked against it. The `iwiFilterGaussian` page's
  description says it "applies a Laplacian filter", an apparent copy error in Intel's
  reference; its syntax and parameters describe a Gaussian.
- QOI: the [site][qoi-site], the [specification PDF][qoi-spec] and the reference
  [`qoi.h`][qoi-h] at commit `ffb2d2cb74a1de60819b21b939f7209aa53e91c1`.
- GDeflate's CPU reference: the DirectStorage clone at `32f9411bc` from
  [`sources.tsv`](./sources.tsv).
- The [hardware matrix][hw] for every verified device fact.

<!-- References -->

[hw]: ./hardware/index.md
[hw-simd]: ./hardware/index.md#cpu-simd
[hw-compute]: ./hardware/index.md#compute
[hw-media]: ./hardware/index.md#platform-media-apis
[c-regbuf]: ./concepts.md#registered-buffers-and-direct-io
[vk-transfer]: ./vulkan-transfer.md
[vk-decomp]: ./vulkan-transfer.md#gpu-decompression-the-nv-and-ext-extensions
[o3d-docs]: https://www.open3d.org/docs/release/
[o3d-image]: https://www.open3d.org/docs/release/python_api/open3d.geometry.Image.html
[o3d-t-image]: https://www.open3d.org/docs/release/python_api/open3d.t.geometry.Image.html
[o3d-rgbd-tut]: https://www.open3d.org/docs/release/tutorial/geometry/rgbd_image.html
[o3d-rgbd-cpp]: https://www.open3d.org/docs/release/cpp_api/classopen3d_1_1geometry_1_1_r_g_b_d_image.html
[o3d-image-h]: https://github.com/isl-org/Open3D/blob/b6c5e196384ad71e75b6e6f9c5da22d046221f1d/cpp/open3d/geometry/Image.h#L215-L224
[o3d-t-image-h]: https://github.com/isl-org/Open3D/blob/b6c5e196384ad71e75b6e6f9c5da22d046221f1d/cpp/open3d/t/geometry/Image.h#L25-L35
[o3d-tensor-h]: https://github.com/isl-org/Open3D/blob/b6c5e196384ad71e75b6e6f9c5da22d046221f1d/cpp/open3d/core/Tensor.h#L1246-L1248
[o3d-rgbd-h]: https://github.com/isl-org/Open3D/blob/b6c5e196384ad71e75b6e6f9c5da22d046221f1d/cpp/open3d/geometry/RGBDImage.h#L21-L111
[pcl-docs]: https://pointclouds.org/documentation/
[pcl-pc]: https://pointclouds.org/documentation/classpcl_1_1_point_cloud.html
[pcl-range]: https://pointclouds.org/documentation/classpcl_1_1_range_image.html
[pcl-pcd]: https://pointclouds.org/documentation/tutorials/pcd_file_format.html
[pcl-pc-h]: https://github.com/PointCloudLibrary/pcl/blob/dd4edf371e058ab914d385c2ff417eea68c2691d/common/include/pcl/point_cloud.h#L392-L404
[pcl-pc2-h]: https://github.com/PointCloudLibrary/pcl/blob/dd4edf371e058ab914d385c2ff417eea68c2691d/common/include/pcl/PCLPointCloud2.h#L20-L32
[pcl-image-h]: https://github.com/PointCloudLibrary/pcl/blob/dd4edf371e058ab914d385c2ff417eea68c2691d/common/include/pcl/PCLImage.h#L12-L27
[pcl-pcd-io]: https://github.com/PointCloudLibrary/pcl/blob/dd4edf371e058ab914d385c2ff417eea68c2691d/io/src/pcd_io.cpp#L567-L600
[imageio]: https://developer.apple.com/documentation/imageio
[cgis]: https://developer.apple.com/documentation/imageio/cgimagesource
[cgid]: https://developer.apple.com/documentation/imageio/cgimagedestination
[cgis-incr]: https://developer.apple.com/documentation/imageio/cgimagesourcecreateincremental(_:)
[cgis-update]: https://developer.apple.com/documentation/imageio/cgimagesourceupdatedata(_:_:_:)
[cgis-status]: https://developer.apple.com/documentation/imageio/cgimagesourcestatus
[cgis-thumb]: https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)
[cgis-thumb-always]: https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimagealways
[cgis-subsample]: https://developer.apple.com/documentation/imageio/kcgimagesourcesubsamplefactor
[cgis-cache]: https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately
[cgis-props-at]: https://developer.apple.com/documentation/imageio/cgimagesourcecopypropertiesatindex(_:_:_:)
[imageio-props]: https://developer.apple.com/documentation/imageio/image-properties
[imageio-heics]: https://developer.apple.com/documentation/imageio/kcgimagepropertyheicsdictionary
[imageio-avis]: https://developer.apple.com/documentation/imageio/kcgimagepropertyavisdictionary
[vimage]: https://developer.apple.com/documentation/accelerate/vimage-library
[vimage-buffer]: https://developer.apple.com/documentation/accelerate/vimage_buffer
[vimage-init]: https://developer.apple.com/documentation/accelerate/vimagebuffer_init(_:_:_:_:_:)
[vimage-roi]: https://developer.apple.com/documentation/accelerate/applying-vimage-operations-to-regions-of-interest
[vimage-perf]: https://developer.apple.com/documentation/accelerate/optimizing-image-processing-performance
[vimage-conv]: https://developer.apple.com/documentation/accelerate/vimageconvolve_argb8888(_:_:_:_:_:_:_:_:_:_:_:)
[vimage-cgformat]: https://developer.apple.com/documentation/accelerate/vimage_cgimageformat
[vimage-conv-create]: https://developer.apple.com/documentation/accelerate/vimageconverter_createwithcgimageformat(_:_:_:_:_:)
[vimage-converter]: https://developer.apple.com/documentation/accelerate/vimageconverter
[vimage-anytoany]: https://developer.apple.com/documentation/accelerate/vimageconvert_anytoany(_:_:_:_:_:)
[vimage-notile]: https://developer.apple.com/documentation/accelerate/kvimagedonottile
[ipp]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/overview.html
[ipp-types]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/image-data-types-and-ranges.html
[ipp-roi]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/regions-of-interest-in-intel-ipp.html
[ipp-gauss]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/filtergaussian.html
[ipp-dispatch]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/dispatching.html
[ipp-pa]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/ipp-using-platform-aware-functions.html
[ipp-tl]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/ipp-using-threading-layer-functions.html
[ipp-tl-fns]: https://www.intel.com/content/www/us/en/docs/ipp/developer-guide-reference/2022-2/threading-layer-functions-001.html
[ipp-iw-ov]: https://www.intel.com/content/www/us/en/docs/ipp/developer-reference-integration-wrapper/2020/key-features.html
[ipp-iw-tile]: https://www.intel.com/content/www/us/en/docs/ipp/developer-reference-integration-wrapper/2020/tiling-and-threading.html
[ipp-iw-gauss]: https://www.intel.com/content/www/us/en/docs/ipp/developer-reference-integration-wrapper/2020/iwifiltergaussian-001.html
[gds-overview]: https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html
[gds-api]: https://docs.nvidia.com/gpudirect-storage/api-reference-guide/index.html
[gds-spec]: https://docs.nvidia.com/gpudirect-storage/api-reference-guide/cufile-api-specification.html
[gds-func]: https://docs.nvidia.com/gpudirect-storage/api-reference-guide/cufile-api-functional-specification.html
[nvcomp]: https://docs.nvidia.com/cuda/nvcomp/index.html
[nvcomp-gdeflate]: https://docs.nvidia.com/cuda/nvcomp/gdeflate.html
[nvcomp-capi]: https://docs.nvidia.com/cuda/nvcomp/c_api.html
[ds-gdeflate]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md
[ds-gdeflate-tile]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/config.h#L28
[mtl-loading]: https://developer.apple.com/documentation/metal/resource-loading
[mtl-iodesc]: https://developer.apple.com/documentation/metal/mtliocommandqueuedescriptor
[mtl-ioqueue]: https://developer.apple.com/documentation/metal/mtliocommandqueue
[mtl-iocb]: https://developer.apple.com/documentation/metal/mtliocommandbuffer
[mtl-iofh]: https://developer.apple.com/documentation/metal/mtliofilehandle
[mtl-iofh-make]: https://developer.apple.com/documentation/metal/mtldevice/makeiofilehandle(url:compressionmethod:)
[mtl-iocm]: https://developer.apple.com/documentation/metal/mtliocompressionmethod
[mtl-cc-create]: https://developer.apple.com/documentation/metal/mtliocreatecompressioncontext
[mtl-cc-chunk]: https://developer.apple.com/documentation/metal/mtliocompressioncontextdefaultchunksize()
[qoi-site]: https://qoiformat.org/
[qoi-spec]: https://qoiformat.org/qoi-specification.pdf
[qoi-h]: https://github.com/phoboslab/qoi/blob/ffb2d2cb74a1de60819b21b939f7209aa53e91c1/qoi.h
[qoi-h-decode]: https://github.com/phoboslab/qoi/blob/ffb2d2cb74a1de60819b21b939f7209aa53e91c1/qoi.h#L488-L528
[wuffs-qoi]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/qoi/decode_qoi.wuffs
