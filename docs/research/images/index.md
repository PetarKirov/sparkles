# Images: formats, pixel models and algorithms

A primary-source catalog for `sparkles:{image,video}`: how other ecosystems model
pixels and views, decode and encode image formats safely, run image algorithms on
SIMD and GPU compute, and move bytes from storage to the GPU. It exists to inform a
design decision that is **not yet made**: whether the library is one package or splits
into image-core, image-formats and image-algorithms. That decision follows the research
and a round of experiments, not this page.

> [!IMPORTANT]
> This tree is under construction. Wave 0 delivered the Sparkles [baseline](#sparkles-baseline)
> (what the repository already has or has specified), the [papers](#papers) and the
> [hardware matrix](#hardware). The [master catalog](#master-catalog) lists every
> subject with its tier and the wave that delivers it; a subject is linked once its
> deep-dive exists.

**Last reviewed:** November 7, 2026

## Questions this survey answers

1. **Pixel and memory model.** Which representation of planes, strides, tiles, views
   and N-D extents serves both a viewer and a scientific pipeline, and does mir's
   `Slice` fit?
2. **Generic interfaces in D.** Which mechanism (concepts, traits, type classes,
   design by introspection) carries pixel and image abstractions, and which
   cross-language ideas transfer?
3. **Generic algorithms that stay fast.** Lazy ranges, algorithm/schedule separation,
   SIMD dispatch and GPU kernels: how do they compose?
4. **Codec architecture.** What gives incremental, suspendable, hostile-input-safe
   decoding (Wuffs), and what must the `sparkles:wired` binary description format
   express?
5. **Colour, HDR and metadata.** ICC, CICP, gain maps, EXIF and XMP: what is the
   minimum model?
6. **File to GPU.** How do `sparkles:event-horizon`, io_uring/IoRing, Vulkan upload,
   GPU decompression and GPU texture formats fit together?
7. **SIMD versus GPU compute.** Where is the break-even, and what is shared between
   the two kernel forms?
8. **Correctness.** Oracles, conformance corpora, fuzzing and differential testing.
9. **Package boundaries.** Evidence for or against a split into image-core, formats
   and algorithms.

## Sparkles baseline

What the repository ships, specifies, drafts and plans in each area the image work
touches. Every doc separates those four statuses, ends with gaps tagged by the
questions above, and lists the open decisions for the design review.

| Area                                | Covers                                                                                 | Link                    |
| ----------------------------------- | -------------------------------------------------------------------------------------- | ----------------------- |
| `sparkles:wired` and Flat           | what binary description can express today versus what image headers and codecs need    | [Baseline][bl-wired]    |
| `sparkles:event-horizon`            | io_uring ops, offload pools, fibers; the file-to-GPU seam; I/O-bound and CPU-bound use | [Baseline][bl-eh]       |
| `sparkles:vulkan` and `ui-vulkan`   | bound commands and extensions, memory sub-allocator, the one upload path               | [Baseline][bl-vk]       |
| `sparkles:shaders`, math, host SIMD | graphics-only shaders, compute milestones, SIMD precedents and dispatch                | [Baseline][bl-shaders]  |
| Existing image code and consumers   | the two PNG decoders, alpha conventions, terminal images, oracles, explorer template   | [Baseline][bl-existing] |

## Papers

Seven annotated bibliographies. Each entry gives a claim, a verbatim quote checked
against the paper's text, its relevance to Sparkles and its caveats; each thread ends
with a synthesis. The PDFs live outside the repository, under
`~/code/repos/papers/image-video/<thread>/`.

| Thread                        | Covers                                                                             | Link                   |
| ----------------------------- | ---------------------------------------------------------------------------------- | ---------------------- |
| DSLs and scheduling           | algorithm/schedule separation, fusion and tiling, autoschedulers, hardware targets | [Papers][p-dsl]        |
| Generic image programming     | pixel and view concepts, N-D arrays, functional image models                       | [Papers][p-generic]    |
| Resampling and colour         | reconstruction filters, compositing, colour appearance, HDR transfer, ICC, CICP    | [Papers][p-colour]     |
| Entropy coding and codecs     | ANS and Huffman decoding speed, context modelling, JPEG XL, AV1, WebP, HEVC        | [Papers][p-entropy]    |
| GPU texture compression       | BCn, ETC2, ASTC, Basis/UASTC, KTX2, neural texture compression                     | [Papers][p-texture]    |
| Hostile input and safety      | LangSec, verified parsers, fuzzing, image-codec exploit analyses, Wuffs            | [Papers][p-hostile]    |
| Storage-to-GPU and GPU decode | `io_uring`, DirectStorage/GDeflate, GPU Huffman/ANS/DEFLATE/JPEG, Vulkan Video     | [Papers][p-gpu-decode] |

## Hardware

What the machines available to this work expose, measured with one read-only
probe: CPU SIMD, `io_uring`, Vulkan formats, Vulkan Video profiles, compute
features and the platform media API. Every cell is verified on a device.

| Page                   | Covers                                                                                                         | Link                   |
| ---------------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------- |
| Hardware matrix        | AMD, NVIDIA and Intel Linux desktops, laptops and a server, an Apple M4 Max, Snapdragon 888 and 8 Elite phones | [Matrix][hw-matrix]    |
| Run the hardware probe | the `media-hw-probe` flake app, for adding a machine                                                           | [Contribute][hw-probe] |

## Synthesis and experiments

| Page                   | Covers                                                                                                 | Link                      |
| ---------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------- |
| Comparison             | the field at a glance, by dimension, its consensus and trade-offs, answers to Q1–Q9, delta to Sparkles | [Comparison][cmp]         |
| The `Slice` experiment | mir's `Slice` as an image view, under dip1000, betterC, wasm32 and Android                             | [Experiment][slice-exp]   |
| The wired experiment   | PNG, QOI and ISOBMFF framing described in the Flat draft and in current `sparkles:wired`               | [Experiment][wired-fit]   |
| wired requirements     | the non-binding requirements IMW1–IMW25 the wired experiment yields                                    | [Requirements][wired-req] |
| Concepts               | the shared vocabulary                                                                                  | [Concepts][concepts]      |

## Master catalog

The terms the deep-dives share (stride, view, plane, transfer function,
suspendable decoding and the rest) are defined once in [Concepts](./concepts.md).

Every subject the survey covers, with the depth it gets. The tier is a working
assignment, and any subject can be promoted or demoted:

- **Tier A** is a full deep-dive: all ten [analysis dimensions](#analysis-spine),
  verbatim quotes, and citations pinned to the cloned revision.
- **Tier B** is a short deep-dive covering only the dimensions where the subject
  teaches something.
- **Tier C** is a row in the [Tier C digest](#tier-c-digest) with a paragraph,
  read from official documentation only. Closed-source subjects are always Tier C.

The **Basis** column is the revision a deep-dive reads, from
[`sources.tsv`](./sources.tsv), or `docs` where nothing is cloned. A subject
without a link is not written yet; its wave says when it is due.

| Subject                                               | Ecosystem | Cluster           | Tier | Basis             | Wave | Doc                                      |
| ----------------------------------------------------- | --------- | ----------------- | ---- | ----------------- | ---- | ---------------------------------------- |
| mir-algorithm (`Slice`, `ndslice`) and mir-core       | D         | D landscape       | A    | clone `2da212382` | 1    | [Deep-dive](./mir-algorithm/)            |
| dcv                                                   | D         | D landscape       | A    | clone `c777e2aa9` | 1    | [Deep-dive](./dcv.md)                    |
| color (TurkeyMan)                                     | D         | D landscape       | A    | clone `e9d31e416` | 1    | [Deep-dive](./color.md)                  |
| `ae.utils.graphics` (functional image processing)     | D         | D landscape       | A    | clone `7870bc3cd` | 1    | [Deep-dive](./ae-graphics.md)            |
| gamut                                                 | D         | D landscape       | B    | clone `7f07b8ca3` | 2    | [Deep-dive](./gamut.md)                  |
| arsd image modules                                    | D         | D landscape       | B    | clone `11491fa8b` | 2    | [Deep-dive](./arsd-image.md)             |
| Dplug graphics                                        | D         | D landscape       | B    | clone `f4a6d71ae` | 2    | [Deep-dive](./dplug-graphics.md)         |
| intel-intrinsics                                      | D         | D landscape       | B    | clone `2141185c6` | 4    | [Deep-dive](./intel-intrinsics.md)       |
| dcompute                                              | D         | D landscape       | B    | clone `cdb5792d4` | 4    | [Deep-dive](./dcompute.md)               |
| Boost.GIL (and its Adobe origin)                      | C++       | Generic libraries | A    | clone `97ed52cc0` | 1    | [Deep-dive](./boost-gil.md)              |
| VIGRA                                                 | C++       | Generic libraries | A    | clone `de98f930b` | 1    | [Deep-dive](./vigra.md)                  |
| Halide                                                | C++ DSL   | Generic libraries | A    | clone `85f161839` | 1    | [Deep-dive](./halide.md)                 |
| JuliaImages (ImageCore, ColorTypes)                   | Julia     | Generic libraries | A    | clone `c3f815704` | 1    | [Deep-dive](./juliaimages.md)            |
| ITK                                                   | C++       | Generic libraries | A    | clone `443d201c3` | 2    | [Deep-dive](./itk.md)                    |
| OpenCV (`cv::Mat`, `UMat`, HAL)                       | C++       | Generic libraries | A    | clone `96f8c0761` | 2    | [Deep-dive](./opencv.md)                 |
| ImageSharp                                            | C#        | Generic libraries | A    | clone `b2b1ca9bd` | 2    | [Deep-dive](./imagesharp.md)             |
| libvips                                               | C         | Generic libraries | A    | clone `b8242162f` | 2    | [Deep-dive](./libvips.md)                |
| OpenImageIO                                           | C++       | Generic libraries | A    | clone `e7eb5d109` | 2    | [Deep-dive](./openimageio.md)            |
| image-rs                                              | Rust      | Generic libraries | A    | clone `075e65d61` | 2    | [Deep-dive](./image-rs.md)               |
| zune-image                                            | Rust      | Generic libraries | A    | clone `2f9086b07` | 2    | [Deep-dive](./zune-image.md)             |
| Skia (`SkPixmap`, codecs, `SkColorSpace`)             | C++       | Generic libraries | A    | clone `3ad790ab4` | 2    | [Deep-dive](./skia.md)                   |
| CImg                                                  | C++       | Generic libraries | B    | clone `38bb024de` | 2    | [Deep-dive](./cimg.md)                   |
| SAIL                                                  | C         | Generic libraries | B    | clone `dccd2ebd5` | 2    | [Deep-dive](./sail.md)                   |
| stb_image                                             | C         | Generic libraries | B    | clone `003501f6d` | 2    | [Deep-dive](./stb-image.md)              |
| Go `image` and `x/image`                              | Go        | Generic libraries | B    | clone `b06f1de3f` | 2    | [Deep-dive](./go-image.md)               |
| NumPy `ndarray` and the buffer protocol (PEP 3118)    | Python    | Generic libraries | B    | clone `b833c1b9b` | 2    | [Deep-dive](./numpy-buffer-protocol.md)  |
| DLPack                                                | C ABI     | Generic libraries | B    | clone `94485e235` | 2    | [Deep-dive](./dlpack.md)                 |
| GDAL, GeoTIFF and Cloud Optimized GeoTIFF             | C++       | Generic libraries | B    | clone `739fcf03b` | 4    | [Deep-dive](./gdal.md)                   |
| ROS `image_transport` and `cv_bridge`                 | C++       | Generic libraries | B    | clone `faf0db265` | 4    | [Deep-dive](./ros-image-transport.md)    |
| Open3D and PCL                                        | C++       | Generic libraries | C    | clone `b6c5e1963` | 4    | [Digest](./tier-c-digest.md)             |
| Wuffs                                                 | Wuffs, C  | Formats           | A    | clone `4be865da2` | 3    | [Deep-dive](./wuffs.md)                  |
| libpng                                                | C         | Formats           | A    | clone `890812a28` | 3    | [Deep-dive](./libpng.md)                 |
| libspng                                               | C         | Formats           | A    | clone `46c81dc2b` | 3    | [Deep-dive](./libspng.md)                |
| libjpeg-turbo                                         | C         | Formats           | A    | clone `7b4993786` | 3    | [Deep-dive](./libjpeg-turbo.md)          |
| libwebp                                               | C         | Formats           | A    | clone `1844042d1` | 3    | [Deep-dive](./libwebp.md)                |
| libjxl                                                | C++       | Formats           | A    | clone `e2948747f` | 3    | [Deep-dive](./libjxl.md)                 |
| libavif                                               | C         | Formats           | A    | clone `9b07a9d7a` | 3    | [Deep-dive](./libavif.md)                |
| OpenEXR                                               | C++       | Formats           | A    | clone `b0460b224` | 3    | [Deep-dive](./openexr.md)                |
| libheif                                               | C++       | Formats           | B    | clone `12a259a58` | 3    | [Deep-dive](./libheif.md)                |
| libtiff                                               | C         | Formats           | B    | clone `d23249978` | 3    | [Deep-dive](./libtiff.md)                |
| QOI                                                   | spec      | Formats           | C    | docs              | 3    | [Digest](./tier-c-digest.md)             |
| Little CMS 2                                          | C         | Colour            | A    | clone `5546f1d68` | 4    | [Deep-dive](./lcms2.md)                  |
| OpenColorIO                                           | C++       | Colour            | B    | clone `22dd9c4fa` | 4    | [Deep-dive](./opencolorio.md)            |
| ICC v4 and iccMAX                                     | spec      | Colour            | B    | docs              | 4    | [Deep-dive](./icc.md)                    |
| CICP (ITU-T H.273)                                    | spec      | Colour            | B    | docs              | 4    | [Deep-dive](./cicp.md)                   |
| Ultra HDR and ISO 21496-1 gain maps                   | spec      | Colour            | B    | docs              | 4    | [Deep-dive](./gain-maps.md)              |
| ExifTool                                              | Perl      | Metadata          | B    | clone `2200871d9` | 3    | [Deep-dive](./exiftool.md)               |
| Exiv2                                                 | C++       | Metadata          | B    | clone `be479c1b7` | 3    | [Deep-dive](./exiv2.md)                  |
| Simd (ermig1979)                                      | C++       | GPU and SIMD      | A    | clone `37dd13062` | 4    | [Deep-dive](./simd.md)                   |
| Highway                                               | C++       | GPU and SIMD      | A    | clone `872f22991` | 4    | [Deep-dive](./highway.md)                |
| KTX-Software (KTX2)                                   | C++       | GPU and SIMD      | A    | clone `d9b1dd090` | 4    | [Deep-dive](./ktx-software.md)           |
| basis_universal                                       | C++       | GPU and SIMD      | A    | clone `ee771a7f9` | 4    | [Deep-dive](./basis-universal.md)        |
| libyuv                                                | C++       | GPU and SIMD      | B    | clone `205022c08` | 4    | [Deep-dive](./libyuv.md)                 |
| nvImageCodec                                          | C++, CUDA | GPU and SIMD      | B    | clone `e7a7ef0f5` | 4    | [Deep-dive](./nvimagecodec.md)           |
| glTF `KHR_texture_basisu` and texture extensions      | spec      | GPU and SIMD      | B    | clone `1c84b58ba` | 4    | [Deep-dive](./gltf-textures.md)          |
| Filament and bgfx texture pipelines                   | C++       | GPU and SIMD      | B    | clone `4e2df5e24` | 4    | [Deep-dive](./filament-bgfx-textures.md) |
| Godot texture import                                  | C++       | GPU and SIMD      | B    | local clone       | 4    | [Deep-dive](./godot-texture-import.md)   |
| Apple ImageIO                                         | closed    | GPU and SIMD      | C    | docs              | 4    | [Digest](./tier-c-digest.md)             |
| Apple vImage (Accelerate)                             | closed    | GPU and SIMD      | C    | docs              | 4    | [Digest](./tier-c-digest.md)             |
| Intel IPP                                             | closed    | GPU and SIMD      | C    | docs              | 4    | [Digest](./tier-c-digest.md)             |
| Vulkan transfer and memory decompression              | spec      | Storage to GPU    | A    | clone `a8b088a3f` | 4    | [Deep-dive](./vulkan-transfer.md)        |
| DirectStorage and IoRing                              | Windows   | Storage to GPU    | B    | clone `32f9411bc` | 4    | [Deep-dive](./directstorage-ioring.md)   |
| `io_uring` registered buffers, `O_DIRECT` and dma-buf | Linux     | Storage to GPU    | B    | docs              | 4    | [Deep-dive](./io-uring-storage.md)       |
| GPUDirect Storage (`cuFile`)                          | closed    | Storage to GPU    | C    | docs              | 4    | [Digest](./tier-c-digest.md)             |
| nvCOMP and GDeflate                                   | closed    | Storage to GPU    | C    | docs              | 4    | [Digest](./tier-c-digest.md)             |
| Metal fast resource loading (`MTLIOCommandQueue`)     | closed    | Storage to GPU    | C    | docs              | 4    | [Digest](./tier-c-digest.md)             |

### Analysis spine

Every deep-dive covers the same ten dimensions, in this order, and says "not
applicable, because …" where one does not apply:

1. **Pixel and memory model:** layout, planes, strides, views, tiles, N-D extents.
2. **Genericity mechanism:** concepts, traits, type classes, introspection.
3. **Colour and metadata:** ICC, CICP, HDR, EXIF and XMP.
4. **I/O and codec architecture:** push or pull, incremental, suspendable.
5. **Hostile input and safety:** bounds, limits, fuzzing.
6. **Allocation and ownership.**
7. **CPU parallelism and SIMD.**
8. **GPU offload and interop.**
9. **Temporal, animation and containers.**
10. **Testing and conformance.**

### Waves

| Wave | Delivers                                                                                                                                                                             |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0    | the baseline, the papers and the hardware matrix (done)                                                                                                                              |
| 1    | the D landscape and the generic-programming core; the [`Slice` experiment](./mir-algorithm/slice-experiment.md) (done)                                                               |
| 2    | the generic and architectural libraries; the D Tier B subjects (done)                                                                                                                |
| 3    | Wuffs, the stills codecs and metadata; the [wired experiment](./wired-flat-fit/index.md) and its [requirements](./wired-requirements.md) (done)                                      |
| 4    | colour, SIMD, GPU textures and storage-to-GPU; the [Tier C digest](./tier-c-digest.md) (done)                                                                                        |
| 5    | [`concepts.md`](./concepts.md) completed, the [taxonomy](#taxonomy), the [milestones](#milestones) and [`comparison.md`](./comparison.md) with its delta against the baseline (done) |

Each wave ends with a verification pass by an agent that did not write the doc:
every quote is re-read from the pinned clone, and `ci --check-blob-paths` runs
before the commit.

### Tier C digest

The [Tier C digest](./tier-c-digest.md) covers Open3D and PCL, Apple ImageIO and
vImage, Intel IPP, GPUDirect Storage, nvCOMP and GDeflate, Metal fast resource
loading and QOI, from official documentation only.

### Video subjects

Recorded here so the tiers can be reviewed together. They belong to the video
catalog, written after this one, which reuses this page's concepts and spine.

| Subject                                            | Tier | Basis                          |
| -------------------------------------------------- | ---- | ------------------------------ |
| FFmpeg (`libavcodec`, `libavformat`, `libswscale`) | A    | clone `a23e09448`              |
| Vulkan Video                                       | A    | clone `a8b088a3f`, `24398af37` |
| dav1d                                              | A    | clone `c6f51c881`              |
| libplacebo                                         | A    | clone `275f7dea2`              |
| GStreamer (with GES)                               | A    | clone `e91b21950`              |
| ISOBMFF (MPEG reference and mp4parse-rust)         | A    | clone `689ac096a`, `d3a9abfc9` |
| Matroska and EBML                                  | A    | clone `289c9625d`, `a4b3c4a88` |
| mpv and libmpv                                     | B    | clone `ad5877eda`              |
| AV1 specification                                  | B    | clone `5e04f3f75`              |
| SVT-AV1                                            | B    | clone `a3ca29b7b`              |
| rav1e                                              | B    | clone `31435de9d`              |
| libaom                                             | B    | clone `60ce6c892`              |
| libvpx                                             | B    | clone `fb0a26ad9`              |
| x264                                               | B    | clone `0480cb05f`              |
| OpenH264                                           | B    | clone `1bca62311`              |
| libva                                              | B    | clone `f052e984e`              |
| Intel VPL                                          | B    | clone `674d015bc`              |
| AMD AMF                                            | B    | clone `57ee0cfb0`              |
| MLT                                                | B    | clone `eca4e32d2`              |
| OpenTimelineIO                                     | B    | clone `94e1ad6c9`              |
| NVIDIA Video Codec SDK                             | C    | docs, samples `aa3544dce`      |
| VideoToolbox                                       | C    | docs                           |
| Android MediaCodec                                 | C    | docs                           |
| Media Foundation and D3D12 Video                   | C    | docs                           |
| WebCodecs                                          | C    | docs                           |
| libwebrtc                                          | C    | docs (googlesource)            |
| MPEG-TS and IVF                                    | C    | docs                           |
| HLS and DASH                                       | C    | docs                           |
| Blender VSE                                        | C    | docs                           |

## Taxonomy

The tables below re-cut the [master catalog](#master-catalog) along eight axes, one
table per axis. Each row is one normalised category; the labels come from the
[analysis spine](#analysis-spine) of every deep-dive, read back against the section
that states them. A subject appears in more than one row only when the deep-dive
describes more than one first-class model, and the Note says which is primary. The
[Tier C digest][tier-c] contributes its subjects by name where its paragraph states the
property. Grouping by category records what the field does; it does not rank the
subjects or choose a model for Sparkles.

### By pixel and memory model

| Category                                       | Subjects                                                                                                                                                                                                                                                                                                                                                  | Note                                                                                                                                                                                                                                                                                                 |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| N-D strided array, one stride per axis         | [mir-algorithm][mir-algorithm], [dcv][dcv], [Halide][halide], [VIGRA][vigra], [JuliaImages][juliaimages], [NumPy][numpy], [DLPack][dlpack], [OpenCV][opencv], [GDAL][gdal], [Open3D][tc-open3d]                                                                                                                                                           | Strides in elements (mir, VIGRA, DLPack, Halide) or bytes (NumPy, OpenCV `step`); signed in VIGRA and DLPack. mir puts the contiguity kind in the type; NumPy, DLPack and OpenCV carry a run-time element type. GDAL's N-D strided form is its multidimensional API, beside the 2-D band model below |
| N-D dense, no strides                          | [CImg][cimg], [ITK][itk]                                                                                                                                                                                                                                                                                                                                  | CImg is a fixed 4-D `(x, y, z, c)` planar block; ITK adds physical geometry (origin, spacing, direction) and three regions over one contiguous buffer                                                                                                                                                |
| 2-D interleaved view with a byte row stride    | [Boost.GIL][boost-gil], [Go `image`][go-image], [Skia][skia], [Simd][simd], [Dplug graphics][dplug-graphics], [Gamut][gamut], [`ae.utils.graphics`][ae-graphics], [libvips][libvips], [OpenImageIO][openimageio], [SAIL][sail], [ROS `image_transport`][ros], [OpenColorIO][opencolorio], [Little CMS 2][lcms2], [vImage][tc-vimage], [Intel IPP][tc-ipp] | The common viewer model: base pointer, extents and [stride][c-stride]. Boost.GIL also has planar and packed views; Gamut's pitch is signed and adds a layer axis; OpenImageIO adds [data and display windows][c-windows]; Little CMS 2 takes the strides as call arguments rather than a view type   |
| Multi-planar, per-plane stride and subsampling | [Wuffs][wuffs], [libavif][libavif], [libheif][libheif], [libyuv][libyuv], [nvImageCodec][nvimagecodec], [OpenEXR][openexr], [libwebp][libwebp], [libjpeg-turbo][libjpeg-turbo], [zune-image][zune-image]                                                                                                                                                  | The YCbCr-first model ([planes][c-plane], [chroma subsampling][c-chroma]). Wuffs carries up to four planes; OpenEXR's planes are named channels; libwebp, libjpeg-turbo and zune-image expose raw planes beside an interleaved output; Go `image` and Skia have a separate YCbCr or YUVA family      |
| Planar dense channels                          | [zune-image][zune-image], [libjxl][libjxl], [Highway][highway]                                                                                                                                                                                                                                                                                            | zune-image's `Image` layer is one dense buffer per channel; libjxl's internal planes are padded and aligned while its API is interleaved; Highway's `contrib/image` is a planar padded-row image                                                                                                     |
| Packed contiguous buffer, no stride            | [stb_image][stb-image], [libspng][libspng], [arsd image modules][arsd-image], [image-rs][image-rs], [Godot texture import][godot], [glTF textures][gltf-textures], [QOI][tc-qoi]                                                                                                                                                                          | Width × height × channels with no padding. image-rs keeps a strided `FlatSamples` as a separate type                                                                                                                                                                                                 |
| Row-addressed or segmented 2-D                 | [libpng][libpng], [libjpeg-turbo][libjpeg-turbo], [ImageSharp][imagesharp]                                                                                                                                                                                                                                                                                | libpng and libjpeg-turbo write rows through caller row pointers; ImageSharp's rows live in a group of discontiguous aligned buffers                                                                                                                                                                  |
| Tiled or chunked storage behind the view       | [libtiff][libtiff], [OpenEXR][openexr], [GDAL][gdal], [OpenImageIO][openimageio], [VIGRA][vigra], [libvips][libvips]                                                                                                                                                                                                                                      | [Tiling][c-tiling] of the file or cache, not of the in-memory view: libtiff [striles][c-strile], OpenEXR chunks and [deep data][c-deep], GDAL block-cached bands, OpenImageIO's `ImageCache`, VIGRA's chunked store, libvips' lazy regions                                                           |
| GPU texture layout (levels, layers, blocks)    | [KTX-Software][ktx-software], [Basis Universal][basis-universal], [Filament and bgfx][filament-bgfx], [Godot texture import][godot], [glTF textures][gltf-textures], [Vulkan transfer][vulkan-transfer], [DirectStorage and IoRing][directstorage-ioring]                                                                                                 | [Mip levels, layers and faces][c-mip] of [block-compressed][c-block] texels; Vulkan's device side is opaque optimal tiling, DirectStorage uses D3D12 copyable footprints                                                                                                                             |
| Element or descriptor only, no image           | [color][color], [intel-intrinsics][intel-intrinsics], [dcompute][dcompute], [gain maps][gain-maps], [CICP][cicp], [ICC v4 and iccMAX][icc], [ExifTool][exiftool], [Exiv2][exiv2], [`io_uring` storage][io-uring-storage], [ImageIO][tc-imageio]                                                                                                           | color models one pixel struct; dcompute passes raw address-space pointers; gain maps bind two images by metadata; ImageIO hands out an opaque `CGImage`; the rest are specifications, metadata or I/O with no pixel model                                                                            |

### By genericity mechanism

| Category                                          | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                 | Note                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D templates with design by introspection          | [`ae.utils.graphics`][ae-graphics], [mir-algorithm][mir-algorithm], [dcv][dcv], [color][color], [intel-intrinsics][intel-intrinsics], [dcompute][dcompute], [Dplug graphics][dplug-graphics]                                                                                                                                                                                                                             | [Design by introspection][c-dbi]: structural constraints and `static if` on optional primitives. dcv specialises on `Slice` kind without capability traits; Dplug uses traits at the leaves and run-time classes on the hot path                                                                                                                                     |
| C++ templates with concepts, traits, tag dispatch | [Boost.GIL][boost-gil], [VIGRA][vigra], [CImg][cimg], [ITK][itk], [Highway][highway]                                                                                                                                                                                                                                                                                                                                     | [Concepts, traits and tag dispatch][c-concepts]. ITK is templated inside a filter and virtual outside it; Highway's descriptor is a zero-sized tag plus a preprocessor pass per target                                                                                                                                                                               |
| Trait or type-class polymorphism                  | [image-rs][image-rs], [zune-image][zune-image], [ImageSharp][imagesharp], [JuliaImages][juliaimages]                                                                                                                                                                                                                                                                                                                     | Rust traits with associated types, C# static abstract members, Julia multiple dispatch with Holy traits. image-rs and zune-image pair them with a closed run-time enum ([type erasure][c-erasure])                                                                                                                                                                   |
| Staged DSL specialised per target                 | [Halide][halide]                                                                                                                                                                                                                                                                                                                                                                                                         | Halide compiles a pipeline per target from an [algorithm and schedule][c-schedule]; its ABI carries a run-time type tag per buffer                                                                                                                                                                                                                                   |
| Run-time tag with C function tables               | [Wuffs][wuffs], [libjpeg-turbo][libjpeg-turbo], [libwebp][libwebp], [libavif][libavif], [libheif][libheif], [libtiff][libtiff], [libjxl][libjxl], [OpenEXR][openexr], [Skia][skia], [Little CMS 2][lcms2], [KTX-Software][ktx-software], [SAIL][sail], [Gamut][gamut], [GDAL][gdal], [nvImageCodec][nvimagecodec], [Basis Universal][basis-universal], [Filament and bgfx][filament-bgfx], [Godot texture import][godot] | The codec norm: an enum or descriptor selects function pointers or a plugin vtable. Wuffs, though written in its own memory-safe language, exposes interfaces as C vtables and resolves a run-time pixel-format word to a function pointer; libjpeg-turbo also [monomorphises][c-mono] by preprocessor per sample width; libjxl uses Highway templates for SIMD only |
| Run-time type descriptor for interchange          | [NumPy][numpy], [DLPack][dlpack], [OpenCV][opencv], [OpenImageIO][openimageio], [libvips][libvips], [ROS `image_transport`][ros], [Vulkan transfer][vulkan-transfer]                                                                                                                                                                                                                                                     | A value describes the element type (`descr`, code/bits/lanes, `CV_8UC3`, `TypeDesc`, an encoding string, a `VkFormat` with `pNext` chains); OpenCV and OpenImageIO switch to templates inside algorithms                                                                                                                                                             |
| Object hierarchy and virtual dispatch             | [arsd image modules][arsd-image], [Go `image`][go-image], [OpenColorIO][opencolorio], [Exiv2][exiv2]                                                                                                                                                                                                                                                                                                                     | Interfaces or class trees; Go's closed type switches are generated by `gen.go`; OpenColorIO optimises a run-time transform graph                                                                                                                                                                                                                                     |
| Data-driven tables interpreted at run time        | [ExifTool][exiftool], [Exiv2][exiv2]                                                                                                                                                                                                                                                                                                                                                                                     | Tag tables as data (Perl hashes with code strings; `constexpr` tables in Exiv2)                                                                                                                                                                                                                                                                                      |
| Preprocessor only, or none                        | [libpng][libpng], [libspng][libspng], [stb_image][stb-image], [libyuv][libyuv], [Simd][simd], [vImage][tc-vimage], [Intel IPP][tc-ipp]                                                                                                                                                                                                                                                                                   | Format and sample type spelled in the function name or chosen by macro; Simd copies a kernel per instruction set                                                                                                                                                                                                                                                     |
| Not applicable                                    | [CICP][cicp], [ICC v4 and iccMAX][icc], [gain maps][gain-maps], [glTF textures][gltf-textures], [`io_uring` storage][io-uring-storage], [DirectStorage and IoRing][directstorage-ioring]                                                                                                                                                                                                                                 | Specifications and I/O interfaces                                                                                                                                                                                                                                                                                                                                    |

### By decode shape

| Category                                     | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Note                                                                                                                                                                                                                                                                                 |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Suspendable at any byte (coroutines)         | [Wuffs][wuffs]                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [Suspendable][c-incremental] by construction: coroutine state lives in the decoder, input and output are caller buffers                                                                                                                                                              |
| Push-fed, resumes from saved state           | [libjxl][libjxl], [libpng][libpng], [libwebp][libwebp], [`ae.utils.graphics`][ae-graphics], [ImageIO][tc-imageio]                                                                                                                                                                                                                                                                                                                                                 | [Push][c-push]: libjxl suspends at section boundaries, libpng's progressive reader per row and Adam7 pass, libwebp by [checkpoint and replay][c-checkpoint]; ae-graphics feeds libpng's progressive reader; ImageIO takes all accumulated bytes on each update and may re-parse them |
| Pull, retried when input runs short          | [libjpeg-turbo][libjpeg-turbo], [libavif][libavif], [zune-image][zune-image]                                                                                                                                                                                                                                                                                                                                                                                      | A suspending source returns "no data" and the call is repeated: libjpeg-turbo restarts the current [MCU][c-mcu], libavif returns `AVIF_RESULT_WAITING_ON_IO`, zune-image retries JPEG from a checkpoint                                                                              |
| Pull, row or chunk incremental, blocking     | [libspng][libspng], [Skia][skia], [Boost.GIL][boost-gil], [VIGRA][vigra], [SAIL][sail]                                                                                                                                                                                                                                                                                                                                                                            | Rows or frames arrive in order from a blocking reader; Skia's incremental decode is a re-call at row granularity for some codecs; SAIL decodes frame by frame                                                                                                                        |
| Pull, random access by tile, strip or region | [libtiff][libtiff], [OpenEXR][openexr], [GDAL][gdal], [OpenImageIO][openimageio], [ITK][itk], [libvips][libvips], [libheif][libheif], [ExifTool][exiftool], [Exiv2][exiv2]                                                                                                                                                                                                                                                                                        | The reader seeks to the unit it needs: libtiff [striles][c-strile], OpenEXR chunks, GDAL blocks, ITK requested regions, libvips [demand-driven][c-demand] regions, libheif byte-range hints for tiles                                                                                |
| Pull, whole file                             | [stb_image][stb-image], [image-rs][image-rs], [ImageSharp][imagesharp], [Go `image`][go-image], [Gamut][gamut], [CImg][cimg], [arsd image modules][arsd-image], [OpenCV][opencv], [Simd][simd], [KTX-Software][ktx-software], [Basis Universal][basis-universal], [Filament and bgfx][filament-bgfx], [Godot texture import][godot], [JuliaImages][juliaimages], [dcv][dcv], [Dplug graphics][dplug-graphics], [QOI][tc-qoi]                                      | Header and pixels may be split (Go's `DecodeConfig`, image-rs' decoder protocol, OpenCV's `readHeader`/`readData`), but the pixels arrive in one call. dcv and Dplug graphics delegate to Gamut                                                                                      |
| Batched asynchronous queue                   | [nvImageCodec][nvimagecodec], [DirectStorage and IoRing][directstorage-ioring], [GPUDirect Storage][tc-gds], [nvCOMP][tc-nvcomp], [Metal fast resource loading][tc-metal]                                                                                                                                                                                                                                                                                         | Requests are queued, completed out of band and often decompressed on the GPU                                                                                                                                                                                                         |
| External process                             | [`ae.utils.graphics`][ae-graphics], [CImg][cimg]                                                                                                                                                                                                                                                                                                                                                                                                                  | ImageMagick or FFmpeg as a subprocess decoder (CImg as a fallback)                                                                                                                                                                                                                   |
| Not applicable                               | [mir-algorithm][mir-algorithm], [Halide][halide], [Highway][highway], [color][color], [intel-intrinsics][intel-intrinsics], [dcompute][dcompute], [NumPy][numpy], [DLPack][dlpack], [libyuv][libyuv], [OpenColorIO][opencolorio], [Little CMS 2][lcms2], [ICC v4 and iccMAX][icc], [CICP][cicp], [gain maps][gain-maps], [glTF textures][gltf-textures], [Vulkan transfer][vulkan-transfer], [`io_uring` storage][io-uring-storage], [ROS `image_transport`][ros] | No codec of its own. ROS delivers one whole frame per message through a transport plugin                                                                                                                                                                                             |

### By hostile-input limits

| Category                        | Subjects                                                                                                                                                                                                                                                                                                                                                                                               | Note                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Caller-set limits per decoder   | [libheif][libheif], [libavif][libavif], [image-rs][image-rs], [libspng][libspng], [libpng][libpng], [zune-image][zune-image], [OpenEXR][openexr], [libjpeg-turbo][libjpeg-turbo], [ImageSharp][imagesharp], [libtiff][libtiff], [Skia][skia]                                                                                                                                                           | The [hostile input][c-hostile] defence as an API. libheif adds work budgets and memory accounting to a versioned struct; libavif caps pixels, dimensions and image count; image-rs' `max_alloc` is best-effort; libspng's limits default open; libjpeg-turbo's are opt-in through TurboJPEG; libtiff's allocation caps default to unlimited; Skia's `fMaxDecodeMemory` is honoured by few paths |
| Process-wide settings           | [OpenCV][opencv], [OpenImageIO][openimageio], [libvips][libvips], [GDAL][gdal]                                                                                                                                                                                                                                                                                                                         | Environment variables or global attributes; libvips also blocks untrusted loaders; GDAL bounds caches and band count and leaves pixel budgets to the caller                                                                                                                                                                                                                                     |
| Fixed library caps              | [Wuffs][wuffs], [stb_image][stb-image], [libjxl][libjxl], [libwebp][libwebp], [CImg][cimg], [Gamut][gamut], [Simd][simd], [Godot texture import][godot], [Basis Universal][basis-universal], [Halide][halide], [arsd image modules][arsd-image], [Little CMS 2][lcms2], [ICC v4 and iccMAX][icc], [Exiv2][exiv2], [ExifTool][exiftool], [Filament and bgfx][filament-bgfx], [QOI][tc-qoi]              | Compile-time or built-in constants. Wuffs' limits are structural (24-bit dimensions, an exact work-buffer length, fixed arrays); libjxl scales its built-in limits to the declared pixel count; Godot's checks are themselves overflowing                                                                                                                                                       |
| Bounds and overflow checks only | [Go `image`][go-image], [SAIL][sail], [ITK][itk], [KTX-Software][ktx-software], [nvImageCodec][nvimagecodec], [dcv][dcv]                                                                                                                                                                                                                                                                               | Go's contract is that the caller checks `DecodeConfig` first; dcv inherits Gamut's dimension caps                                                                                                                                                                                                                                                                                               |
| Platform or kernel limits       | [`io_uring` storage][io-uring-storage], [DirectStorage and IoRing][directstorage-ioring], [Vulkan transfer][vulkan-transfer], [nvCOMP][tc-nvcomp]                                                                                                                                                                                                                                                      | `RLIMIT_MEMLOCK` and the per-buffer registration cap, staging and queue sizes, Vulkan valid usage enforced only by validation layers, chunk-size maxima                                                                                                                                                                                                                                         |
| None                            | [`ae.utils.graphics`][ae-graphics], [Boost.GIL][boost-gil], [VIGRA][vigra], [JuliaImages][juliaimages], [mir-algorithm][mir-algorithm], [Dplug graphics][dplug-graphics], [libyuv][libyuv], [NumPy][numpy], [DLPack][dlpack], [Highway][highway], [intel-intrinsics][intel-intrinsics], [dcompute][dcompute], [glTF textures][gltf-textures], [ROS `image_transport`][ros], [OpenColorIO][opencolorio] | libyuv takes no buffer lengths at all; JuliaImages has libpng's compiled-in defaults only; ROS inherits OpenCV's; OpenColorIO has fixed LUT-size limits in its parsers only                                                                                                                                                                                                                     |
| Not applicable                  | [CICP][cicp], [color][color], [gain maps][gain-maps]                                                                                                                                                                                                                                                                                                                                                   | Gain-map metadata validation lives in the implementations (libavif, libultrahdr)                                                                                                                                                                                                                                                                                                                |

### By SIMD strategy

| Category                                      | Subjects                                                                                                                                                                                                                                                                                             | Note                                                                                                                                                                                                                                                                                                |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Portable SIMD library, run-time dispatch      | [Highway][highway], [libjxl][libjxl], [libvips][libvips], [OpenCV][opencv], [Skia][skia]                                                                                                                                                                                                             | One source compiled per target, selected by [run-time CPU dispatch][c-dispatch]. libjxl and libvips use Highway; OpenCV's universal intrinsics; Skia compiles portable source per target namespace behind three dispatchers                                                                         |
| Portable SIMD library, compile-time selection | [intel-intrinsics][intel-intrinsics], [Dplug graphics][dplug-graphics], [Gamut][gamut], [OpenImageIO][openimageio]                                                                                                                                                                                   | Intel's intrinsic API in D for any LDC or GDC target, chosen by the build; OpenImageIO's `simd.h` wrapper, with an optional static Highway that is off by default                                                                                                                                   |
| Hand-written per ISA, run-time dispatch       | [libjpeg-turbo][libjpeg-turbo], [libwebp][libwebp], [libyuv][libyuv], [Simd][simd], [zune-image][zune-image], [Wuffs][wuffs], [ImageSharp][imagesharp], [OpenColorIO][opencolorio], [OpenEXR][openexr], [Little CMS 2][lcms2], [ICC v4 and iccMAX][icc], [Go `image`][go-image], [Intel IPP][tc-ipp] | Intrinsics or assembly per target behind a CPU check. Wuffs chooses in-language (`choose cpu_arch`); ImageSharp's `IsSupported` branches fold under the JIT; OpenEXR mixes compile-time and run-time; Little CMS 2 only in its `fast_float` plug-in; ICC through skcms; Go only in `x/image/vector` |
| Hand-written per ISA, compile-time selection  | [libpng][libpng], [libspng][libspng], [stb_image][stb-image], [GDAL][gdal], [Basis Universal][basis-universal]                                                                                                                                                                                       | Chosen by compiler flags; libpng 1.6 has partial run-time checks; libspng applies `target_clones` to one function; Basis Universal's hand SIMD is in the encoder                                                                                                                                    |
| Generated from a schedule                     | [Halide][halide]                                                                                                                                                                                                                                                                                     | Vector code per target from the [schedule][c-schedule], with multi-target ahead-of-time builds dispatched at run time                                                                                                                                                                               |
| Auto-vectorisation only                       | [mir-algorithm][mir-algorithm], [dcv][dcv], [`ae.utils.graphics`][ae-graphics], [VIGRA][vigra], [ITK][itk], [CImg][cimg], [JuliaImages][juliaimages], [vImage][tc-vimage]                                                                                                                            | [Auto-vectorisation][c-autovec] by LLVM or the C++ compiler (mir's `@fmamath`, dcv's `@fastmath` on LDC); vImage vectorises internally and exposes no SIMD                                                                                                                                          |
| Delegated to dependencies                     | [image-rs][image-rs], [libavif][libavif], [libheif][libheif], [libtiff][libtiff], [SAIL][sail], [Filament and bgfx][filament-bgfx], [nvImageCodec][nvimagecodec]                                                                                                                                     | The codec libraries underneath carry the SIMD (dav1d, libyuv, libsharpyuv, libswscale)                                                                                                                                                                                                              |
| None                                          | [arsd image modules][arsd-image], [Boost.GIL][boost-gil], [color][color], [KTX-Software][ktx-software], [Exiv2][exiv2], [dcompute][dcompute], [gain maps][gain-maps], [DirectStorage and IoRing][directstorage-ioring]                                                                               | Scalar code. Gain maps' reference loop is scalar (libultrahdr uses a LUT); DirectStorage's CPU GDeflate decoder is thread-parallel across tiles                                                                                                                                                     |
| Not stated or not applicable                  | [Godot texture import][godot], [ROS `image_transport`][ros], [NumPy][numpy], [CICP][cicp], [glTF textures][gltf-textures], [`io_uring` storage][io-uring-storage], [Vulkan transfer][vulkan-transfer], [DLPack][dlpack], [ExifTool][exiftool]                                                        | The deep-dive reports no CPU kernel of the subject's own                                                                                                                                                                                                                                            |

### By GPU interop

| Category                                | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Note                                                                                                                                                                                                                                                                                             |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Vulkan upload and import                | [Vulkan transfer][vulkan-transfer], [KTX-Software][ktx-software], [`io_uring` storage][io-uring-storage], [Godot texture import][godot]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [Staging][c-staging], host image copy, [external memory][c-extmem] from host pointers and [dma-buf][c-dmabuf] with [DRM format modifiers][c-drm]; KTX-Software uploads levels into a `VkImage`; Godot compresses with compute (betsy) through `RenderingDevice`                                  |
| Several graphics back ends, upload only | [Skia][skia], [Filament and bgfx][filament-bgfx]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Ganesh and Graphite in Skia; engine back ends in Filament and bgfx; no GPU decompression                                                                                                                                                                                                         |
| GPU compute kernels from one source     | [Halide][halide], [OpenCV][opencv], [OpenColorIO][opencolorio], [dcompute][dcompute], [ITK][itk], [Basis Universal][basis-universal], [gain maps][gain-maps]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Halide targets CUDA, OpenCL, Metal, D3D12, Vulkan and WebGPU; OpenCV's OpenCL transparent API; OpenColorIO generates shader text; dcompute targets OpenCL and CUDA; ITK's OpenCL module; Basis Universal's OpenCL encoder; gain maps applied in a Skia runtime effect or libultrahdr's GLES path |
| CUDA decode and storage paths           | [nvImageCodec][nvimagecodec], [GPUDirect Storage][tc-gds], [nvCOMP][tc-nvcomp], [Open3D][tc-open3d]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Batched CUDA decode, DMA from storage into GPU memory, batched GPU decompression, device tensors                                                                                                                                                                                                 |
| Storage-to-GPU decompression            | [DirectStorage and IoRing][directstorage-ioring], [Vulkan transfer][vulkan-transfer], [nvCOMP][tc-nvcomp], [Metal fast resource loading][tc-metal]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [GPU decompression][c-gpudecomp] of [GDeflate][c-gdeflate] in HLSL, through `VK_NV_memory_decompression` and `VK_EXT_memory_decompression`, or in CUDA; Metal IO command queues load compressed packs into textures                                                                              |
| Device-tagged descriptor only           | [DLPack][dlpack]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Names CUDA, ROCm, OpenCL, Vulkan, Metal and others as devices; streams are defined for CUDA and ROCm only                                                                                                                                                                                        |
| Maps onto GPU state, no code            | [CICP][cicp], [glTF textures][gltf-textures]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | CICP values map onto Vulkan's sampler YCbCr conversion and swapchain colour spaces; glTF targets GPU block formats through KTX2                                                                                                                                                                  |
| None                                    | [`ae.utils.graphics`][ae-graphics], [arsd image modules][arsd-image], [Boost.GIL][boost-gil], [CImg][cimg], [color][color], [dcv][dcv], [Dplug graphics][dplug-graphics], [Gamut][gamut], [mir-algorithm][mir-algorithm], [VIGRA][vigra], [JuliaImages][juliaimages], [Highway][highway], [intel-intrinsics][intel-intrinsics], [Simd][simd], [libyuv][libyuv], [Go `image`][go-image], [image-rs][image-rs], [ImageSharp][imagesharp], [zune-image][zune-image], [GDAL][gdal], [NumPy][numpy], [ROS `image_transport`][ros], [Wuffs][wuffs], [libpng][libpng], [libspng][libspng], [stb_image][stb-image], [libjpeg-turbo][libjpeg-turbo], [libwebp][libwebp], [libjxl][libjxl], [libavif][libavif], [libheif][libheif], [libtiff][libtiff], [OpenEXR][openexr], [OpenImageIO][openimageio], [libvips][libvips], [SAIL][sail], [Little CMS 2][lcms2], [ICC v4 and iccMAX][icc], [ExifTool][exiftool], [Exiv2][exiv2], [ImageIO][tc-imageio], [vImage][tc-vimage], [Intel IPP][tc-ipp], [QOI][tc-qoi] | All stills codecs, the colour libraries, the CPU libraries and the D landscape apart from dcompute; dcv uses OpenGL for display only, zune-image offloads HEVC decode to VideoToolbox only, OpenImageIO has CUDA-annotated description types only                                                |

### By colour management

| Category                         | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Note                                                                                                                                                                                                                                                                    |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ICC colour management applied    | [Little CMS 2][lcms2], [ICC v4 and iccMAX][icc], [Skia][skia], [libvips][libvips], [ImageSharp][imagesharp], [libjxl][libjxl]                                                                                                                                                                                                                                                                                                                                                                                               | A [colour management module][c-cmm] transforms through the [profile connection space][c-pcs]. Skia applies skcms at decode and adds CICP, PQ, HLG and gain maps; libvips calls Little CMS 2; ImageSharp converts ICC to sRGB; libjxl's CMS sits behind a function table |
| Config-driven colour pipelines   | [OpenColorIO][opencolorio], [OpenImageIO][openimageio]                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Colour spaces and transforms come from a configuration file; OpenImageIO adds CICP, ICC blobs and Color Interop Forum identifiers                                                                                                                                       |
| CICP as the primary tag          | [CICP][cicp], [libavif][libavif], [libheif][libheif], [image-rs][image-rs], [zune-image][zune-image], [gain maps][gain-maps]                                                                                                                                                                                                                                                                                                                                                                                                | [CICP][c-cicp] values drive conversion; ICC is carried as bytes. image-rs maps ICC to CICP through moxcms; zune-image delegates its CMS to moxcms; gain maps need CICP or ICC to linearise and add a metadata record                                                    |
| Colour space in the element type | [color][color], [JuliaImages][juliaimages], [VIGRA][vigra]                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | The pixel type names its space (color's template parameters, JuliaImages' `Colorant` hierarchy, VIGRA's element types with conversion functors); color's set of spaces is a closed enum                                                                                 |
| Texture or container descriptor  | [KTX-Software][ktx-software], [Basis Universal][basis-universal], [glTF textures][gltf-textures], [Filament and bgfx][filament-bgfx], [Vulkan transfer][vulkan-transfer], [OpenEXR][openexr], [QOI][tc-qoi]                                                                                                                                                                                                                                                                                                                 | A [Data Format Descriptor][c-dfd], an sRGB bit or format suffix, a sampler [YCbCr conversion][c-ycbcrconv], OpenEXR's chromaticities and `colorInteropID`, QOI's two-value colour-space byte                                                                            |
| YCbCr matrix and range only      | [libyuv][libyuv], [Simd][simd], [dcv][dcv], [libwebp][libwebp]                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [Matrix coefficients][c-ycbcr] and [range][c-range] as fixed tables; libwebp is fixed to BT.601 limited range and passes ICC through                                                                                                                                    |
| Carried, not applied             | [Wuffs][wuffs], [libpng][libpng], [libspng][libspng], [libjpeg-turbo][libjpeg-turbo], [libtiff][libtiff], [GDAL][gdal], [Exiv2][exiv2], [ExifTool][exiftool], [OpenCV][opencv], [Boost.GIL][boost-gil], [SAIL][sail], [nvImageCodec][nvimagecodec], [ImageIO][tc-imageio], [vImage][tc-vimage]                                                                                                                                                                                                                              | ICC and CICP bytes reported or passed through. libpng applies power-law gamma only; libspng a fixed 2.2 gamma table; Wuffs reports CICP, gamma, chromaticities and ICC ranges; ImageIO and vImage tag images with named colour spaces                                   |
| None                             | [`ae.utils.graphics`][ae-graphics], [arsd image modules][arsd-image], [CImg][cimg], [Gamut][gamut], [Go `image`][go-image], [Godot texture import][godot], [Halide][halide], [Highway][highway], [intel-intrinsics][intel-intrinsics], [ITK][itk], [mir-algorithm][mir-algorithm], [NumPy][numpy], [DLPack][dlpack], [dcompute][dcompute], [Dplug graphics][dplug-graphics], [stb_image][stb-image], [ROS `image_transport`][ros], [DirectStorage and IoRing][directstorage-ioring], [`io_uring` storage][io-uring-storage] | ae-graphics has one sRGB gamma ramp; Dplug assumes sRGB with a gamma-2 approximation                                                                                                                                                                                    |

### By fuzzing

| Category                                   | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Note                                                                                                                                                                                                                                                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OSS-Fuzz and in-tree harnesses             | [Wuffs][wuffs], [libjxl][libjxl], [libavif][libavif], [libjpeg-turbo][libjpeg-turbo], [libspng][libspng], [libtiff][libtiff], [libvips][libvips], [libwebp][libwebp], [OpenEXR][openexr], [Little CMS 2][lcms2], [Simd][simd], [Exiv2][exiv2], [stb_image][stb-image], [libpng][libpng], [Skia][skia], [GDAL][gdal]                                                                                                                                                                                                                                                                                                                                                                                                                                           | [OSS-Fuzz][c-ossfuzz] runs [coverage-guided][c-fuzz] harnesses kept in the tree. libavif's FuzzTest targets also run in CI; libspng adds CIFuzz; libpng's harnesses exist on the 1.6 branch only; Skia's live under `fuzz/oss_fuzz/`; GDAL's per-format harnesses feed `/vsimem/`                       |
| OSS-Fuzz recipes outside the project       | [OpenCV][opencv]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | The `imdecode`, `imread` and core fuzzers are recipes in the OSS-Fuzz repository, cloning OpenCV's default branch                                                                                                                                                                                       |
| In-tree harness run outside OSS-Fuzz       | [libheif][libheif], [zune-image][zune-image], [OpenImageIO][openimageio], [image-rs][image-rs], [Go `image`][go-image], [Halide][halide], [gain maps][gain-maps], [ICC v4 and iccMAX][icc]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | libheif runs its libFuzzer targets on pull requests through CIFuzz with a ClusterFuzz-derived corpus; zune-image per change and nightly; OpenImageIO nightly; image-rs' cargo-fuzz targets are not run in CI; Halide fuzzes its own bounds and simplifier reasoning; ICC through Little CMS 2's harness |
| Fuzz-found inputs only, or sanitizers only | [ImageSharp][imagesharp], [SAIL][sail], [Basis Universal][basis-universal], [DirectStorage and IoRing][directstorage-ioring]                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | ImageSharp keeps regression images found by others' fuzzing; SAIL runs [sanitizers][c-sanitizers] in CI; Basis Universal has randomised self-tests; DirectStorage has an adversarial manifest for its GPU zstd decoder only                                                                             |
| None                                       | [`ae.utils.graphics`][ae-graphics], [arsd image modules][arsd-image], [color][color], [dcv][dcv], [Dplug graphics][dplug-graphics], [Gamut][gamut], [mir-algorithm][mir-algorithm], [intel-intrinsics][intel-intrinsics], [dcompute][dcompute], [Boost.GIL][boost-gil], [VIGRA][vigra], [CImg][cimg], [ITK][itk], [JuliaImages][juliaimages], [Highway][highway], [libyuv][libyuv], [DLPack][dlpack], [NumPy][numpy], [ROS `image_transport`][ros], [nvImageCodec][nvimagecodec], [OpenColorIO][opencolorio], [ExifTool][exiftool], [KTX-Software][ktx-software], [Filament and bgfx][filament-bgfx], [Godot texture import][godot], [glTF textures][gltf-textures], [CICP][cicp], [Vulkan transfer][vulkan-transfer], [`io_uring` storage][io-uring-storage] | No harness in the tree or on OSS-Fuzz; NumPy and ROS are listed because their deep-dives state none for the parts read. The Tier C digest states none for its subjects                                                                                                                                  |

## Milestones

When the capabilities and failures that shaped the field landed, in date order, as the
deep-dives record them. A date is as precise as its deep-dive: a day where a commit,
release note or advisory gives one, otherwise a month or a year. **c.** marks a date the
deep-dive gives only approximately; a date followed by _CVE year_ is the year in the
identifier, not a disclosure date. Revisions read for this survey are not events and are
left out; each deep-dive's metadata table records its own.

| Date              | Subject                            | Event                                                                                                                                    |
| ----------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 1988              | [libtiff][libtiff]                 | The reference TIFF library is maintained from this year on                                                                               |
| c. late 1990s     | [VIGRA][vigra]                     | The 2-D `ImageIterator`/accessor design is built, before the N-D array views that replaced it                                            |
| 2001-04           | [ICC v4 and iccMAX][icc]           | ICC.1:2001-04, the last specification of profile version 2                                                                               |
| 2003              | [SAIL][sail]                       | ksquirrel-libs, SAIL's predecessor codec set for the KSquirrel viewer, is founded                                                        |
| 2004              | [ICC v4 and iccMAX][icc]           | ICC.1:2004 defines profile version 4 (ISO 15076-1): `mAB `/`mBA `, parametric curves, a required `chad`                                  |
| 2005              | [NumPy][numpy]                     | The array interface (`__array_interface__`) is created                                                                                   |
| 2006              | [OpenEXR][openexr]                 | The earliest of the 88 CVEs that `CHANGES.md` cites                                                                                      |
| 2006-01-05        | [Boost.GIL][boost-gil]             | ASL 1.0.12 adds GIL to the Adobe Source Libraries; the tutorial and design guide follow on January 16                                    |
| c. late 2006      | [Boost.GIL][boost-gil]             | GIL is accepted into Boost                                                                                                               |
| 2007-04-05        | [Boost.GIL][boost-gil]             | ASL 1.0.26 ships GIL 2.0                                                                                                                 |
| 2008-03-29        | [Boost.GIL][boost-gil]             | Boost 1.35.0, the first Boost release with GIL                                                                                           |
| 2009 (_CVE year_) | [Little CMS 2][lcms2]              | CVE-2009-0723: integer overflows in lcms 1.x                                                                                             |
| 2010-11-04        | [Boost.GIL][boost-gil]             | ASL 1.0.43 removes GIL in favour of the Boost copy                                                                                       |
| 2011              | [Boost.GIL][boost-gil]             | The I/O v2 extension is accepted into Boost (shipped in 1.68)                                                                            |
| 2012              | [Halide][halide]                   | Ragan-Kelley et al. publish the separation of algorithm and schedule                                                                     |
| 2012              | [VIGRA][vigra]                     | Köthe's IPOL retrospective reports array views more convenient than hierarchical iterators for implementers                              |
| 2013              | [Halide][halide]                   | The second paper adds `compute_at` and `store_at`, the two knobs of fusion and storage folding                                           |
| 2013 (_CVE year_) | [libjpeg-turbo][libjpeg-turbo]     | CVE-2013-6629: `get_sos` leaks uninitialised memory through duplicate component identifiers in a scan                                    |
| 2014-03-18        | [`ae.utils.graphics`][ae-graphics] | "[BREAKING] Overhaul": views, `isView`, `Warp` and `Image!COLOR` replace the canvas design                                               |
| 2014-03-21        | [`ae.utils.graphics`][ae-graphics] | `parallel` lands and the article _Functional image processing in D_ is published the same day                                            |
| 2014-12-26        | [`ae.utils.graphics`][ae-graphics] | `im_convert` makes ImageMagick the general decoder                                                                                       |
| 2015-01-06        | [color][color]                     | dlang/phobos#2845, "Added std.experimental.color", is opened                                                                             |
| 2015-06-24        | [color][color]                     | Initial commit of TurkeyMan/color; `color` 0.0.1 on the registry the same day                                                            |
| 2016              | [CICP][cicp]                       | ITU-T H.273 is published as twin text with ISO/IEC 23001-8:2016                                                                          |
| 2016              | [Halide][halide]                   | Mullapudi et al.'s autoscheduler: greedy grouping over bounds analysis                                                                   |
| 2016              | [libjpeg-turbo][libjpeg-turbo]     | Commander and Markham report two resource-exhaustion scenarios that stem from the JPEG format itself                                     |
| 2016 (_CVE year_) | [Little CMS 2][lcms2]              | CVE-2016-10165: out-of-bounds read in `Type_MLU_Read`                                                                                    |
| 2016-01           | [dcv][dcv]                         | dcv is started; 546 of its 798 commits land in 2016                                                                                      |
| 2017-08-06        | [color][color]                     | The Phobos pull request closes unmerged after 160 comments and 273 review comments                                                       |
| 2018              | [Halide][halide]                   | Li et al. (gradient Halide) add a conservative autoscheduler                                                                             |
| 2018 (_CVE year_) | [Little CMS 2][lcms2]              | CVE-2018-16435: integer overflow in the CGATS parser's `AllocateDataSet`                                                                 |
| 2018-02           | [Wuffs][wuffs]                     | Wuffs fuzzing starts on OSS-Fuzz                                                                                                         |
| 2019              | [CICP][cicp]                       | After the ISO split, H.273 is aligned with ISO/IEC 23091-2:2019                                                                          |
| 2019              | [Halide][halide]                   | Adams et al.: beam search over loop nests with a learned cost model                                                                      |
| 2019-01-03        | [`ae.utils.graphics`][ae-graphics] | `viewBMP`: a BMP file becomes a zero-copy direct view; a libpng binding follows on January 9                                             |
| 2019-04           | [image-rs][image-rs]               | A published advisory documents an allocation-reinterpretation soundness bug and its removal                                              |
| 2019-11           | [Wuffs][wuffs]                     | The fuzzing note records that OSS-Fuzz has found no memory-safety bug in Wuffs                                                           |
| 2020              | [gain maps][gain-maps]             | iPhone HEIC and JPEG files carry a gain map with headroom in Apple maker-note EXIF tags 33 and 48                                        |
| 2020 (_CVE year_) | [libavif][libavif]                 | CVE-2020-36407: out-of-bounds write in grid assembly (0.8.0 and 0.8.1), found by OSS-Fuzz                                                |
| 2020-03-30        | [`ae.utils.graphics`][ae-graphics] | "[BREAKING]" 1-bit colours: `scanline` returns storage units rather than colours                                                         |
| 2020-04-14        | [color][color]                     | `v0.0.9`, the last tag                                                                                                                   |
| 2020-06           | [libspng][libspng]                 | Eleven OSS-Fuzz issues against development commits are published in OSV (June and July)                                                  |
| c. 2020–2021      | [OpenEXR][openexr]                 | An OSS-Fuzz wave against the C++ library (for example CVE-2021-3474) precedes the C core rewrite                                         |
| 2021              | [Go `image`][go-image]             | Go 1.17 adds `RGBA64Image` so per-pixel access need not allocate a `color.Color`                                                         |
| 2021              | [Halide][halide]                   | Anderson et al. extend beam search to GPU schedules                                                                                      |
| 2021 (_CVE year_) | [libjxl][libjxl]                   | CVE-2021-22564: out-of-order group decoding copies out of bounds at the right and bottom edges                                           |
| 2021-06           | [Wuffs][wuffs]                     | The Wuffs GIF decoder ships in Chrome (M93)                                                                                              |
| 2021-07-22        | [OpenEXR][openexr]                 | 3.1.0 introduces `OpenEXRCore`, a thread-safe, non-blocking C core                                                                       |
| 2022              | [Vulkan transfer][vulkan-transfer] | `VK_NV_memory_decompression` (extension 428) brings GDeflate decompression to Vulkan                                                     |
| 2022              | [dcompute][dcompute]               | Commit `af45dfa6` adds OpenCL image I/O, the library's only image support                                                                |
| 2022              | [ICC v4 and iccMAX][icc]           | ICC.1:2022 (v4.4) adds the `cicp` tag "to enable HDR metadata to be carried in the profile", `metadataTag` and the strict tag-table rule |
| 2022-01           | [dcv][dcv]                         | dcv is revived ("dcv revision 2022") with a `@nogc` memory model                                                                         |
| 2022-01-05        | [QOI][tc-qoi]                      | QOI specification version 1.0                                                                                                            |
| 2022-12-25        | [glTF textures][gltf-textures]     | Last head of the `EXT_texture_avif` draft pull request, which stays unmerged                                                             |
| 2023              | [ICC v4 and iccMAX][icc]           | ICC.2:2023, iccMAX (profile version 5): spectral PCS and a programmable transform calculator                                             |
| 2023 (_CVE year_) | [libjpeg-turbo][libjpeg-turbo]     | CVE-2023-2804: heap overflow in merged upsampling of out-of-range 12-bit lossless samples                                                |
| 2023 (_CVE year_) | [Skia][skia]                       | The same VP8L exploit reaches Chrome through libwebp                                                                                     |
| 2023-01           | [stb_image][stb-image]             | 2.28: "many error fixes, security errors"                                                                                                |
| 2023-04           | [Wuffs][wuffs]                     | v0.3, still the latest stable release at the revision read                                                                               |
| 2023-07           | [stb_image][stb-image]             | GitHub Security Lab reports seven memory-safety bugs privately; with no reply, it publishes GHSL-2023-145 to 151 in October              |
| 2023-09-07        | [libwebp][libwebp]                 | Commit `902bc91`, "Fix OOB write in BuildHuffmanTable", fixes CVE-2023-4863, exploited in the wild                                       |
| 2023-09-21        | [libwebp][libwebp]                 | Ben Hawkes' analysis _The WebP 0day_ argues coverage-guided fuzzing was very unlikely to find the bug                                    |
| 2024              | [libwebp][libwebp]                 | RFC 9649 standardises the WebP image format                                                                                              |
| 2024              | [gain maps][gain-maps]             | WWDC24 announces the iOS 18 move to Adaptive HDR gain maps, read as ISO 21496-1 from the API key's name                                  |
| 2024-01-01        | [arsd image modules][arsd-image]   | The repository starts targeting the OpenD dialect                                                                                        |
| 2024-05           | [stb_image][stb-image]             | 2.30, the latest version line                                                                                                            |
| 2024-05-28        | [dcv][dcv]                         | Last commit, version 0.4.0                                                                                                               |
| 2024-07           | [CICP][cicp]                       | H.273 (07/24), the edition in force                                                                                                      |
| 2024-09-30        | [OpenEXR][openexr]                 | 3.3.0: the C++ API reads and writes through the C core                                                                                   |
| 2025              | [Vulkan transfer][vulkan-transfer] | `VK_EXT_memory_decompression` (extension 551) is ratified                                                                                |
| 2025              | [libwebp][libwebp]                 | Clang `-fbounds-safety` annotations reach the decoder and utilities                                                                      |
| 2025 (_CVE year_) | [libavif][libavif]                 | CVE-2025-48174 (`makeRoom` integer overflow) and CVE-2025-48175 (`RGBToYUV` multiplication overflows), fixed by 1.3.0                    |
| 2025 (_CVE year_) | [OpenEXR][openexr]                 | CVE-2025-48071: a file's size field sizes an output buffer without checking the decoder's actual output                                  |
| 2025-06-12        | [dcompute][dcompute]               | `v0.1.1`, the last tagged release; development resumes untagged (BindBC CUDA back end, `UnifiedBuffer`)                                  |
| 2025-11-21        | [libpng][libpng]                   | 1.6.51 opens a run of twelve CVE fixes that ends with 1.6.59                                                                             |
| 2026              | [libheif][libheif]                 | "89 security advisories had to be investigated, fixed and released in 2026 alone", by one maintainer                                     |
| 2026              | [OpenEXR][openexr]                 | 38 of the cited CVEs date from 2026, among them the ILP32 group fixed in 3.4.14                                                          |
| 2026              | [Basis Universal][basis-universal] | XUASTC LDR and XUBC7 join the supercompressed intermediate formats                                                                       |
| 2026 (_CVE year_) | [libjpeg-turbo][libjpeg-turbo]     | CVE-2026-75466: division by zero in the PNG loader of `tj3LoadImage*`, fixed in 3.2.1                                                    |
| 2026-07-01        | [libjxl][libjxl]                   | 0.12.0: 29 hardening pull requests and out-of-order `jxlp` boxes                                                                         |
| 2026-09-28        | [libpng][libpng]                   | 1.6.59, the last of the twelve CVE fixes                                                                                                 |
| 2026-11-10        | [libspng][libspng]                 | Upstream adds state checks to `spng_decode_scanline`; a duplicate-`PLTE` check follows on November 13                                    |

## Reading paths

- **Designing the Sparkles image library.** Start with the [comparison][cmp] (its
  answers to the nine questions and the delta against the baseline), then the
  [mir-algorithm deep-dive][mir] and the [`Slice` experiment][slice-exp], [Boost.GIL][gil],
  [JuliaImages][julia] and [Halide][halide] for the view and algorithm model, and
  [Wuffs][wuffs-d] with the [wired experiment][wired-fit] for the codec model.
- **Writing a codec in D.** [Wuffs][wuffs-d], then the codec it replaces
  ([libpng][png-d], [libspng][spng-d], [libjpeg-turbo][jpeg-d], [libwebp][webp-d],
  [libjxl][jxl-d], [libavif][avif-d], [OpenEXR][exr-d]), then
  [wired requirements][wired-req].
- **Colour.** [Concepts: colour][concepts-colour], [CICP][cicp-d], [ICC][icc-d],
  [Little CMS 2][lcms-d], [gain maps][gain-d], [OpenColorIO][ocio-d].
- **Getting pixels to the GPU.** [Vulkan transfer][vk-d], [KTX-Software][ktx-d],
  [basis_universal][basisu-d], [`io_uring` storage][uring-d],
  [DirectStorage and IoRing][ds-d], and the [hardware matrix][hw-matrix].
- **SIMD.** [Highway][hwy-d], [Simd][simd-d], [intel-intrinsics][ii-d], [libyuv][yuv-d].

## Sources

- The five baseline documents above, which cite the specifications and source files
  they were read from.
- The seven paper threads above, which cite each paper by DOI or arXiv identifier.
- The four hardware reports, produced by the probe at the commit the matrix names.
- The deep-dives in the [master catalog](#master-catalog), each pinned to the revision
  in [`sources.tsv`](./sources.tsv), and the [Tier C digest][tier-c] from official
  documentation.

<!-- References -->

[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md
[bl-vk]: ./baseline/vulkan.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-existing]: ./baseline/existing-code.md
[p-dsl]: ./papers/dsl-scheduling.md
[p-generic]: ./papers/generic-image-programming.md
[p-colour]: ./papers/resampling-colour.md
[p-entropy]: ./papers/entropy-codecs.md
[p-texture]: ./papers/gpu-texture-compression.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
[hw-matrix]: ./hardware/index.md
[hw-probe]: ./hardware/contributing.md
[tier-c]: ./tier-c-digest.md
[ae-graphics]: ./ae-graphics.md
[arsd-image]: ./arsd-image.md
[basis-universal]: ./basis-universal.md
[boost-gil]: ./boost-gil.md
[cicp]: ./cicp.md
[cimg]: ./cimg.md
[color]: ./color.md
[dcompute]: ./dcompute.md
[dcv]: ./dcv.md
[directstorage-ioring]: ./directstorage-ioring.md
[dlpack]: ./dlpack.md
[dplug-graphics]: ./dplug-graphics.md
[exiftool]: ./exiftool.md
[exiv2]: ./exiv2.md
[filament-bgfx]: ./filament-bgfx-textures.md
[gain-maps]: ./gain-maps.md
[gamut]: ./gamut.md
[gdal]: ./gdal.md
[gltf-textures]: ./gltf-textures.md
[go-image]: ./go-image.md
[godot]: ./godot-texture-import.md
[halide]: ./halide.md
[highway]: ./highway.md
[icc]: ./icc.md
[image-rs]: ./image-rs.md
[imagesharp]: ./imagesharp.md
[intel-intrinsics]: ./intel-intrinsics.md
[io-uring-storage]: ./io-uring-storage.md
[itk]: ./itk.md
[juliaimages]: ./juliaimages.md
[ktx-software]: ./ktx-software.md
[lcms2]: ./lcms2.md
[libavif]: ./libavif.md
[libheif]: ./libheif.md
[libjpeg-turbo]: ./libjpeg-turbo.md
[libjxl]: ./libjxl.md
[libpng]: ./libpng.md
[libspng]: ./libspng.md
[libtiff]: ./libtiff.md
[libvips]: ./libvips.md
[libwebp]: ./libwebp.md
[libyuv]: ./libyuv.md
[mir-algorithm]: ./mir-algorithm/
[numpy]: ./numpy-buffer-protocol.md
[nvimagecodec]: ./nvimagecodec.md
[opencolorio]: ./opencolorio.md
[opencv]: ./opencv.md
[openexr]: ./openexr.md
[openimageio]: ./openimageio.md
[ros]: ./ros-image-transport.md
[sail]: ./sail.md
[simd]: ./simd.md
[skia]: ./skia.md
[stb-image]: ./stb-image.md
[vigra]: ./vigra.md
[vulkan-transfer]: ./vulkan-transfer.md
[wuffs]: ./wuffs.md
[zune-image]: ./zune-image.md
[tc-open3d]: ./tier-c-digest.md#open3d-and-pcl
[tc-imageio]: ./tier-c-digest.md#apple-imageio
[tc-vimage]: ./tier-c-digest.md#apple-vimage-in-accelerate
[tc-ipp]: ./tier-c-digest.md#intel-ipp
[tc-gds]: ./tier-c-digest.md#nvidia-gpudirect-storage
[tc-nvcomp]: ./tier-c-digest.md#nvcomp-and-gdeflate
[tc-metal]: ./tier-c-digest.md#metal-fast-resource-loading
[tc-qoi]: ./tier-c-digest.md#qoi
[c-stride]: ./concepts.md#stride
[c-plane]: ./concepts.md#plane
[c-chroma]: ./concepts.md#chroma-subsampling
[c-tiling]: ./concepts.md#tiling
[c-block]: ./concepts.md#block-compressed-formats-and-supercompression
[c-windows]: ./concepts.md#data-window-and-display-window
[c-deep]: ./concepts.md#deep-data
[c-strile]: ./concepts.md#strips-tiles-and-striles
[c-mip]: ./concepts.md#mip-levels-array-layers-and-faces
[c-dbi]: ./concepts.md#design-by-introspection
[c-concepts]: ./concepts.md#concepts-traits-and-tag-dispatch
[c-erasure]: ./concepts.md#type-erasure
[c-mono]: ./concepts.md#monomorphisation
[c-schedule]: ./concepts.md#algorithm-and-schedule
[c-push]: ./concepts.md#push-and-pull-decoding
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-checkpoint]: ./concepts.md#checkpoint-and-replay
[c-mcu]: ./concepts.md#minimum-coded-unit
[c-demand]: ./concepts.md#demand-driven-evaluation
[c-hostile]: ./concepts.md#hostile-input
[c-dispatch]: ./concepts.md#run-time-cpu-dispatch
[c-autovec]: ./concepts.md#auto-vectorisation
[c-staging]: ./concepts.md#staging-and-upload
[c-extmem]: ./concepts.md#external-memory-and-zero-copy-import
[c-dmabuf]: ./concepts.md#dma-buf
[c-drm]: ./concepts.md#drm-format-modifier
[c-gpudecomp]: ./concepts.md#gpu-decompression
[c-gdeflate]: ./concepts.md#gdeflate
[c-cmm]: ./concepts.md#colour-management-module-and-rendering-intent
[c-pcs]: ./concepts.md#profile-connection-space
[c-cicp]: ./concepts.md#cicp
[c-dfd]: ./concepts.md#data-format-descriptor
[c-ycbcrconv]: ./concepts.md#sampler-ycbcr-conversion
[c-ycbcr]: ./concepts.md#ycbcr-and-matrix-coefficients
[c-range]: ./concepts.md#full-and-limited-range
[c-ossfuzz]: ./concepts.md#oss-fuzz
[c-fuzz]: ./concepts.md#coverage-guided-fuzzing
[c-sanitizers]: ./concepts.md#sanitizers
[cmp]: ./comparison.md
[slice-exp]: ./mir-algorithm/slice-experiment.md
[wired-fit]: ./wired-flat-fit/index.md
[wired-req]: ./wired-requirements.md
[concepts]: ./concepts.md
[concepts-colour]: ./concepts.md#colour
[mir]: ./mir-algorithm/index.md
[gil]: ./boost-gil.md
[julia]: ./juliaimages.md
[wuffs-d]: ./wuffs.md
[png-d]: ./libpng.md
[spng-d]: ./libspng.md
[jpeg-d]: ./libjpeg-turbo.md
[webp-d]: ./libwebp.md
[jxl-d]: ./libjxl.md
[avif-d]: ./libavif.md
[exr-d]: ./openexr.md
[cicp-d]: ./cicp.md
[icc-d]: ./icc.md
[lcms-d]: ./lcms2.md
[gain-d]: ./gain-maps.md
[ocio-d]: ./opencolorio.md
[vk-d]: ./vulkan-transfer.md
[ktx-d]: ./ktx-software.md
[basisu-d]: ./basis-universal.md
[uring-d]: ./io-uring-storage.md
[ds-d]: ./directstorage-ioring.md
[hwy-d]: ./highway.md
[simd-d]: ./simd.md
[ii-d]: ./intel-intrinsics.md
[yuv-d]: ./libyuv.md
