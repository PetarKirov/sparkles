# Image and video concepts

The shared vocabulary of the images and video catalogs. Each term is defined once
here, and the deep-dives link to it rather than redefining it. Where ecosystems
use different names for one idea, the entry lists them, because a reader moving
between Vulkan, a codec and a C++ library meets all of them.

**Last reviewed:** November 7, 2026

> [!NOTE]
> Wave 1 started this page with the terms the spine needs. Wave 5 completes it
> with what the deep-dives find, so a term a deep-dive introduces may not be
> here yet.

## Pixels and memory

### Sample, channel and component

A **sample** is one number: the red intensity of one pixel, one luma value, one
alpha value. A **channel** is the set of samples of one kind across an image.
Vulkan calls a sample's position in a format a **component**
(`VK_FORMAT_R8G8B8A8_UNORM` has four). Some libraries say "channel" for both.

### Pixel and texel

A **pixel** is the set of samples at one position. A GPU calls the same thing a
**texel** when it is read through a sampler. With [chroma
subsampling](#chroma-subsampling), a pixel's samples do not all live at the same
memory location, so "pixel" names a position, not a memory cell.

### Interleaved, planar and semi-planar

- **Interleaved** (also called **packed** or **chunky**): one plane holds all of
  a pixel's samples next to each other, as in `RGBA RGBA RGBA`.
- **Planar**: each channel has its own plane (`RRR… GGG… BBB…`), the usual
  layout for YCbCr with chroma subsampling.
- **Semi-planar**: luma in one plane, and both chroma channels interleaved in a
  second plane. `NV12` is the common case, and the native output of most
  hardware video decoders.

Wuffs states the split directly: "RGBA data is usually interleaved, but YCbCr
data is usually planar, due to chroma subsampling" ([`pixel-formats.md`][wuffs-pf]).

### Plane

A **plane** is one two-dimensional array of samples with its own base address
and [stride](#stride). An interleaved image has one plane. A planar YCbCr 4:2:0
image has three, and the chroma planes have half the luma plane's width and
height. Planes of one image need not be adjacent in memory.

### Stride

The **stride** is the distance in bytes from the start of one row to the start
of the next. It is also called **pitch** (Direct3D, CUDA), **row bytes**
(Apple) or **line size** (`linesize` in FFmpeg). It is at least the width times
the bytes per pixel, and is often larger: rows are padded for alignment, and a
crop of a larger image keeps the parent's stride. N-dimensional arrays carry
one stride per axis (NumPy, mir's `Slice`, DLPack, Halide's
`halide_dimension_t`). Some libraries measure strides in elements rather than
bytes, and some allow negative strides, which flip an axis without copying.
Wuffs locates a sample as `planes[p].ptr + (j * planes[p].stride) + i`
([`pixel-subsampling.md`][wuffs-ps]).

### Image and view

An **image** owns its pixel memory. A **view** describes pixels it does not
own: a base pointer, extents and strides. A view is cheap to copy and to
derive: a crop, a flip, a transpose, a single channel or a downsampled grid is
a new view of the same memory. A **lazy view** goes one step further and
computes pixels on access (a colour conversion or a procedural pattern), with
no memory behind it. Boost.GIL, VIGRA, mir's `Slice`, `ae.utils.graphics` and
JuliaImages all centre on views.

### Extent, shape and axis order

The **extent** (or **shape**) is the size along each axis. Image libraries
disagree on axis order: `(width, height)` in most 2-D APIs, `(height, width,
channels)` in NumPy's row-major convention, `(x, y, z, c)` in CImg. The axis
whose stride is smallest is the one that is contiguous in memory.

### Tiling

**Linear** (or **row-major**) layout stores rows one after another. **Tiled**
layouts store small rectangular blocks contiguously instead, for locality in
two dimensions. Vulkan defines `VK_IMAGE_TILING_LINEAR` as "texels are laid out
in memory in row-major order, possibly with some padding on each row" and
`VK_IMAGE_TILING_OPTIMAL` as "an implementation-dependent arrangement, for more
efficient memory access" ([`resources.adoc`][vk-tiling]). On Linux, a **DRM
format modifier** names a GPU's tiled layout so that buffers can be shared
between devices and processes. File formats tile too: TIFF, OpenEXR and Cloud
Optimized GeoTIFF store tiles so a reader can fetch a region without decoding
the whole image.

### Chroma subsampling

**Chroma subsampling** stores the two chroma channels at lower resolution than
luma. In **4:4:4** every pixel has its own chroma; **4:2:2** halves chroma
horizontally; **4:2:0** halves it in both directions. **Chroma siting** says
where a chroma sample sits relative to the luma samples it covers (centred, or
co-sited with the top-left one). Getting the siting wrong shifts colour by half
a pixel when converting to RGB. Wuffs encodes the general mapping as
`i = (x + bias_x) / denominator_x` per plane ([`pixel-subsampling.md`][wuffs-ps]).

### Pixel format names and byte order

Two naming conventions coexist, and they read in opposite directions for
packed formats:

- **Memory order.** Vulkan's non-packed formats list components from the lowest
  address: in `VK_FORMAT_R8G8B8A8_UNORM` the red byte comes first. Wuffs uses
  memory order too, "regardless of endianness" ([`pixel-formats.md`][wuffs-pf]).
- **Word order.** Vulkan's `_PACKnn` formats, and Linux DRM fourcc codes such as
  `DRM_FORMAT_ARGB8888`, describe bit positions within a little-endian word, so
  the first-named component is in the highest bits
  ([`formats.adoc`][vk-formats]).

The suffix states how a stored integer becomes a value. **UNORM** maps `0` to
`0.0` and the largest value to `1.0`; **SNORM** does the same for signed
values; **SRGB** formats apply the sRGB [transfer function](#transfer-function)
on read. Julia's `N0f8` is UNORM as a number type.

### Block-compressed formats and supercompression

A **block-compressed** format (BC1 to BC7, ETC2, ASTC) stores a fixed-size
**texel block**, for example 4×4 texels in 64 or 128 bits, which the GPU
decodes on sampling, so the texture stays compressed in GPU memory
([`formats.adoc`][vk-formats]). **Supercompression** adds a second, variable-rate
layer for storage and transmission (Basis Universal's ETC1S and UASTC, or Zstd
inside a KTX2 file), which is removed before upload or transcoded to whichever
block format the GPU supports. See the [GPU texture compression][p-texture]
papers.

## Colour

### Colour space, primaries and white point

A **colour space** says what the numbers mean physically. An RGB colour space is
defined by three **primaries** (the chromaticities of pure red, green and blue),
a **white point** (D65 for sRGB and BT.709) and a [transfer
function](#transfer-function). Two images with identical bytes in different
colour spaces show different colours. sRGB, Display P3 and BT.2020 differ in
primaries; sRGB and BT.709 share primaries but differ in transfer function.

### Transfer function

A **transfer function** maps between encoded values and linear light. **Linear
light** values are proportional to physical intensity; blending, resampling and
blurring are correct only on them. Encoded values spend more codes on dark
tones, where the eye is more sensitive. Standard curves include sRGB's
piecewise gamma, BT.709 and BT.1886 for SDR video, and for HDR the **PQ** curve
(SMPTE ST 2084, absolute luminance up to 10,000 cd/m²) and **HLG** (ARIB STD-B67,
relative). A pipeline that resizes encoded sRGB values without linearising them
darkens high-contrast edges. See the [resampling and colour][p-colour] papers.

### YCbCr and matrix coefficients

**YCbCr** splits colour into luma (Y) and two colour-difference channels (Cb,
Cr). The **matrix coefficients** (BT.601, BT.709, BT.2020 non-constant
luminance, and others) define the conversion to and from RGB, so YCbCr data
cannot be converted correctly without knowing which matrix produced it.

### Full and limited range

**Full range** uses every code (0 to 255 for 8 bits). **Limited range** (also
called video or studio range) puts black at 16 and white at 235 for luma, 16 to
240 for chroma. Most video is limited range and most still images full range;
treating one as the other crushes or washes out the image.

### CICP

**CICP** (Coding-Independent Code Points, ITU-T H.273) assigns numbers to colour
primaries, transfer characteristics and matrix coefficients, plus a full-range
flag. The same four values identify colour in AV1, HEVC, AVIF, HEIF, JPEG XL and
PNG's `cICP` chunk, so one parser and one table cover them all
([ITU-T H.273][h273]).

### ICC profile

An **ICC profile** describes a colour space as data: matrices, curves or lookup
tables mapping device values to a profile connection space (CIE XYZ or Lab). It
covers what CICP's enumerations cannot, such as printers, camera profiles and
measured displays. Version 4 is the common one; iccMAX (v5) generalises it
([ICC specifications][icc]). Embedding is format-specific: PNG `iCCP`, a JPEG
`APP2` segment, a WebP `ICCP` chunk.

### HDR gain map

A **gain map** stores an SDR base image plus a second, usually low-resolution
image of per-pixel gains that reconstruct an HDR rendition. A display scales
the gains to its own headroom, so one file renders on both SDR and HDR screens.
Ultra HDR JPEG and ISO 21496-1 standardise the approach.

### Straight and premultiplied alpha

With **straight** (also called unassociated or non-premultiplied) alpha, colour
samples are stored independently of alpha. With **premultiplied** (associated)
alpha, each colour sample is already multiplied by alpha. Premultiplied is
what compositing operators and filtering need: Porter and Duff's operators are
defined on premultiplied colour, and resampling straight-alpha pixels leaks the
colour of transparent pixels into their neighbours. Most file formats store
straight alpha; OpenEXR stores premultiplied. Sparkles already meets both
conventions in one pipeline ([existing code][bl-existing]).

### Image metadata

**EXIF** carries camera and capture data, including the orientation tag that a
viewer must apply before display. **XMP** is RDF/XML metadata, extensible by
namespace. Both are embedded per format: in JPEG `APP1` segments, PNG `eXIf` and
`iTXt` chunks, and ISOBMFF items.

## Codec architecture

### Container and bitstream

A **container** frames data: it stores chunks, boxes or elements, metadata and
an index (PNG chunks, RIFF for WebP, ISOBMFF boxes for MP4, AVIF and HEIF, EBML
elements for Matroska). A **bitstream** (or coded stream) is the compressed
payload a codec decodes. AVIF is an AV1 bitstream in an ISOBMFF container; the
same AV1 bitstream can also be carried in Matroska or IVF.

### Push and pull decoding

A **pull** decoder asks for input as it needs it, through a read callback or a
stream object (`stbi_io_callbacks`, libpng's read function). A **push** decoder
is handed whatever bytes have arrived and keeps its state between calls. Push
decoding is what an asynchronous I/O loop needs: the decoder must never block
waiting for bytes.

### Incremental, progressive and suspendable decoding

- **Incremental** decoding produces output before all input is available, row by
  row or tile by tile.
- **Progressive** decoding refines the whole image in passes (interlaced PNG,
  progressive JPEG, JPEG XL), so a coarse preview appears early.
- A **suspendable** (or resumable) decoder can stop at any byte boundary when
  input runs out and continue later with no loss. Wuffs builds this into the
  language: a coroutine returns a suspension status, and "calling that function
  again will resume that function where it left off" ([`coroutines.md`][wuffs-co]).

A suspendable decoder over fixed-size buffers is incremental by construction,
and it composes with a completion-based event loop such as
[event-horizon][bl-eh].

### Hostile input

**Hostile input** is any input not known to be well formed: in practice, every
file and network payload. Image decoders have a long history of memory-safety
CVEs. Defences are bounds-checked parsing, explicit **limits** (maximum width,
height, pixel count, allocation and chunk count, set by the caller), checked
integer arithmetic for size computations, and fuzzing. A **decompression bomb**
is a small file that declares or inflates to an enormous image, so limits are
checked before allocation, not after. See the [hostile input][p-hostile] papers.

## Algorithms

### Point, neighbourhood and global operations

A **point operation** computes each output pixel from the same input pixel
(colour conversion, premultiplication, thresholding). A **neighbourhood** (or
**stencil**) operation reads a window around it (convolution, blur, morphology,
resampling). A **global** operation needs the whole image (histogram
equalisation, the Fourier transform). The class decides how an operation can be
fused, tiled and parallelised, and what it needs at image borders.

### Separable filters and resampling

A two-dimensional filter is **separable** when it equals a horizontal pass
followed by a vertical one, cutting the work per pixel from n² to 2n. Box,
Gaussian and most resampling kernels (bilinear, bicubic, Lanczos) are separable.
**Resampling** reconstructs a continuous signal from the samples with a
**reconstruction filter** and samples it on a new grid; the filter choice trades
sharpness against ringing and aliasing ([resampling and colour][p-colour]).

### Algorithm and schedule

Halide separates **what** a pipeline computes (the algorithm, as pure functions
of coordinates) from **how** (the schedule: tile sizes, vectorisation,
parallelism, which intermediate results are stored and which are recomputed).
**Fusion** computes a consumer from its producer without writing the whole
intermediate image to memory. **Tiling** processes the image in blocks small
enough to stay in cache. See the [DSL and scheduling][p-dsl] papers.

## GPU and I/O

### Staging and upload

To reach GPU-local memory, pixels are usually copied into a host-visible
**staging buffer** and then copied by a GPU command into the image, which
converts to [optimal tiling](#tiling) on the way. Where the GPU exposes
host-visible device memory (resizable BAR), the CPU can write device memory
directly. The Sparkles path is described in the [Vulkan baseline][bl-vk].

### External memory and zero-copy import

**External memory** lets one API use memory allocated by another, without a
copy. Examples are a dma-buf from a video decoder or camera imported into
Vulkan, and host memory imported with `VK_EXT_external_memory_host`. Zero-copy
paths need the producer's layout, [stride](#stride) and DRM format modifier to
match what the consumer accepts.

### GPU decompression

**GPU decompression** moves the decompression of assets (GDeflate in
DirectStorage, `VK_NV_memory_decompression` and `VK_EXT_memory_decompression`
in Vulkan) from the CPU to the GPU, so storage reads go to GPU memory still
compressed. See the [storage-to-GPU][p-gpu-decode] papers and the [hardware
matrix][hw] for which devices expose it.

### Registered buffers and direct I/O

`io_uring` can register buffers with the kernel once, so later reads into them
skip per-call page pinning. `O_DIRECT` bypasses the page cache, which suits
large sequential reads that will not be read again. Together they are Linux's
counterpart to Windows' IoRing. See the [event-horizon baseline][bl-eh].

## Sources

- Wuffs notes on [pixel formats][wuffs-pf], [subsampling][wuffs-ps] and
  [coroutines][wuffs-co], at the revision in [`sources.tsv`](./sources.tsv).
- The Vulkan specification's [image tiling][vk-tiling] and [format][vk-formats]
  chapters.
- [ITU-T H.273][h273] and the [ICC specifications][icc].
- The paper threads and baseline documents linked above.

<!-- References -->

[wuffs-pf]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-formats.md
[wuffs-ps]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-subsampling.md
[wuffs-co]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/coroutines.md
[vk-tiling]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/resources.adoc#L5110-L5118
[vk-formats]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/formats.adoc#L1643-L1729
[h273]: https://www.itu.int/rec/T-REC-H.273
[icc]: https://www.color.org/specification/index.xalter
[p-texture]: ./papers/gpu-texture-compression.md
[p-colour]: ./papers/resampling-colour.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-dsl]: ./papers/dsl-scheduling.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
[bl-existing]: ./baseline/existing-code.md
[bl-eh]: ./baseline/event-horizon.md
[bl-vk]: ./baseline/vulkan.md
[hw]: ./hardware/index.md
