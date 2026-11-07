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

| Subject                                               | Ecosystem | Cluster           | Tier | Basis             | Wave | Doc     |
| ----------------------------------------------------- | --------- | ----------------- | ---- | ----------------- | ---- | ------- |
| mir-algorithm (`Slice`, `ndslice`) and mir-core       | D         | D landscape       | A    | clone `2da212382` | 1    | planned |
| dcv                                                   | D         | D landscape       | A    | clone `c777e2aa9` | 1    | planned |
| color (TurkeyMan)                                     | D         | D landscape       | A    | clone `e9d31e416` | 1    | planned |
| `ae.utils.graphics` (functional image processing)     | D         | D landscape       | A    | clone `7870bc3cd` | 1    | planned |
| gamut                                                 | D         | D landscape       | B    | clone `7f07b8ca3` | 2    | planned |
| arsd image modules                                    | D         | D landscape       | B    | clone `11491fa8b` | 2    | planned |
| Dplug graphics                                        | D         | D landscape       | B    | clone `f4a6d71ae` | 2    | planned |
| intel-intrinsics                                      | D         | D landscape       | B    | clone `2141185c6` | 4    | planned |
| dcompute                                              | D         | D landscape       | B    | clone `cdb5792d4` | 4    | planned |
| Boost.GIL (and its Adobe origin)                      | C++       | Generic libraries | A    | clone `97ed52cc0` | 1    | planned |
| VIGRA                                                 | C++       | Generic libraries | A    | clone `de98f930b` | 1    | planned |
| Halide                                                | C++ DSL   | Generic libraries | A    | clone `85f161839` | 1    | planned |
| JuliaImages (ImageCore, ColorTypes)                   | Julia     | Generic libraries | A    | clone `c3f815704` | 1    | planned |
| ITK                                                   | C++       | Generic libraries | A    | clone `443d201c3` | 2    | planned |
| OpenCV (`cv::Mat`, `UMat`, HAL)                       | C++       | Generic libraries | A    | clone `96f8c0761` | 2    | planned |
| ImageSharp                                            | C#        | Generic libraries | A    | clone `b2b1ca9bd` | 2    | planned |
| libvips                                               | C         | Generic libraries | A    | clone `b8242162f` | 2    | planned |
| OpenImageIO                                           | C++       | Generic libraries | A    | clone `e7eb5d109` | 2    | planned |
| image-rs                                              | Rust      | Generic libraries | A    | clone `075e65d61` | 2    | planned |
| zune-image                                            | Rust      | Generic libraries | A    | clone `2f9086b07` | 2    | planned |
| Skia (`SkPixmap`, codecs, `SkColorSpace`)             | C++       | Generic libraries | A    | clone `3ad790ab4` | 2    | planned |
| CImg                                                  | C++       | Generic libraries | B    | clone `38bb024de` | 2    | planned |
| SAIL                                                  | C         | Generic libraries | B    | clone `dccd2ebd5` | 2    | planned |
| stb_image                                             | C         | Generic libraries | B    | clone `003501f6d` | 2    | planned |
| Go `image` and `x/image`                              | Go        | Generic libraries | B    | clone `b06f1de3f` | 2    | planned |
| NumPy `ndarray` and the buffer protocol (PEP 3118)    | Python    | Generic libraries | B    | clone `b833c1b9b` | 2    | planned |
| DLPack                                                | C ABI     | Generic libraries | B    | clone `94485e235` | 2    | planned |
| GDAL, GeoTIFF and Cloud Optimized GeoTIFF             | C++       | Generic libraries | B    | clone `739fcf03b` | 4    | planned |
| ROS `image_transport` and `cv_bridge`                 | C++       | Generic libraries | B    | clone `faf0db265` | 4    | planned |
| Open3D and PCL                                        | C++       | Generic libraries | C    | clone `b6c5e1963` | 4    | planned |
| Wuffs                                                 | Wuffs, C  | Formats           | A    | clone `4be865da2` | 3    | planned |
| libpng                                                | C         | Formats           | A    | clone `890812a28` | 3    | planned |
| libspng                                               | C         | Formats           | A    | clone `46c81dc2b` | 3    | planned |
| libjpeg-turbo                                         | C         | Formats           | A    | clone `7b4993786` | 3    | planned |
| libwebp                                               | C         | Formats           | A    | clone `1844042d1` | 3    | planned |
| libjxl                                                | C++       | Formats           | A    | clone `e2948747f` | 3    | planned |
| libavif                                               | C         | Formats           | A    | clone `9b07a9d7a` | 3    | planned |
| OpenEXR                                               | C++       | Formats           | A    | clone `b0460b224` | 3    | planned |
| libheif                                               | C++       | Formats           | B    | clone `12a259a58` | 3    | planned |
| libtiff                                               | C         | Formats           | B    | clone `d23249978` | 3    | planned |
| QOI                                                   | spec      | Formats           | C    | docs              | 3    | planned |
| Little CMS 2                                          | C         | Colour            | A    | clone `5546f1d68` | 4    | planned |
| OpenColorIO                                           | C++       | Colour            | B    | clone `22dd9c4fa` | 4    | planned |
| ICC v4 and iccMAX                                     | spec      | Colour            | B    | docs              | 4    | planned |
| CICP (ITU-T H.273)                                    | spec      | Colour            | B    | docs              | 4    | planned |
| Ultra HDR and ISO 21496-1 gain maps                   | spec      | Colour            | B    | docs              | 4    | planned |
| ExifTool                                              | Perl      | Metadata          | B    | clone `2200871d9` | 3    | planned |
| Exiv2                                                 | C++       | Metadata          | B    | clone `be479c1b7` | 3    | planned |
| Simd (ermig1979)                                      | C++       | GPU and SIMD      | A    | clone `37dd13062` | 4    | planned |
| Highway                                               | C++       | GPU and SIMD      | A    | clone `872f22991` | 4    | planned |
| KTX-Software (KTX2)                                   | C++       | GPU and SIMD      | A    | clone `d9b1dd090` | 4    | planned |
| basis_universal                                       | C++       | GPU and SIMD      | A    | clone `ee771a7f9` | 4    | planned |
| libyuv                                                | C++       | GPU and SIMD      | B    | clone `205022c08` | 4    | planned |
| nvImageCodec                                          | C++, CUDA | GPU and SIMD      | B    | clone `e7a7ef0f5` | 4    | planned |
| glTF `KHR_texture_basisu` and texture extensions      | spec      | GPU and SIMD      | B    | clone `1c84b58ba` | 4    | planned |
| Filament and bgfx texture pipelines                   | C++       | GPU and SIMD      | B    | clone `4e2df5e24` | 4    | planned |
| Godot texture import                                  | C++       | GPU and SIMD      | B    | local clone       | 4    | planned |
| Apple ImageIO                                         | closed    | GPU and SIMD      | C    | docs              | 4    | planned |
| Apple vImage (Accelerate)                             | closed    | GPU and SIMD      | C    | docs              | 4    | planned |
| Intel IPP                                             | closed    | GPU and SIMD      | C    | docs              | 4    | planned |
| Vulkan transfer and memory decompression              | spec      | Storage to GPU    | A    | clone `a8b088a3f` | 4    | planned |
| DirectStorage and IoRing                              | Windows   | Storage to GPU    | B    | clone `32f9411bc` | 4    | planned |
| `io_uring` registered buffers, `O_DIRECT` and dma-buf | Linux     | Storage to GPU    | B    | docs              | 4    | planned |
| GPUDirect Storage (`cuFile`)                          | closed    | Storage to GPU    | C    | docs              | 4    | planned |
| nvCOMP and GDeflate                                   | closed    | Storage to GPU    | C    | docs              | 4    | planned |
| Metal fast resource loading (`MTLIOCommandQueue`)     | closed    | Storage to GPU    | C    | docs              | 4    | planned |

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

| Wave | Delivers                                                                                                                     |
| ---- | ---------------------------------------------------------------------------------------------------------------------------- |
| 0    | the baseline, the papers and the hardware matrix (done)                                                                      |
| 1    | the D landscape and the generic-programming core; the `Slice` experiment                                                     |
| 2    | the generic and architectural libraries; the D Tier B subjects                                                               |
| 3    | Wuffs, the stills codecs and metadata; `wired-flat-fit.md` and `wired-requirements.md`                                       |
| 4    | colour, SIMD, GPU textures and storage-to-GPU; the Tier C digest                                                             |
| 5    | `concepts.md` completed, the taxonomy tables, the milestone timeline and `comparison.md` with its delta against the baseline |

Each wave ends with a verification pass by an agent that did not write the doc:
every quote is re-read from the pinned clone, and `ci --check-blob-paths` runs
before the commit.

### Tier C digest

Written in wave 4.

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

## Sources

- The five baseline documents above, which cite the specifications and source files
  they were read from.
- The seven paper threads above, which cite each paper by DOI or arXiv identifier.
- The four hardware reports, produced by the probe at the commit the matrix names.

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
