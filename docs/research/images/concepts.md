# Image and video concepts

The shared vocabulary of the images and video catalogs. Each term is defined once
here, and the deep-dives link to it rather than redefining it. Where ecosystems
use different names for one idea, the entry lists them, because a reader moving
between Vulkan, a codec and a C++ library meets all of them.

**Last reviewed:** November 15, 2026

> [!NOTE]
> Wave 1 started this page with the terms the spine needs. Wave 5 completed it
> with the terms the deep-dives introduced: generic programming, codec
> internals, colour management, SIMD dispatch, GPU interop and testing. Each
> added entry links the deep-dives that use the term. A term used by one
> deep-dive only is defined there.

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

### Strips, tiles and striles

TIFF stores pixel data in independently compressed units. A **strip** is
`RowsPerStrip` full-width rows; a **tile** is a `TileWidth` by `TileLength`
block (by `TileDepth` for volumes). One offset array and one byte-count array
address either kind, so libtiff calls the unit a **strile**: its struct comment
reads "td_stripsperimage is the number of striles (=strips or tiles) per plane"
([`tif_dir.h`][tiff-dir]). With separate planes each sample has its own set of
striles. A strile is the granularity of random access: a reader fetches and
decodes only the striles that cover the region it needs. Used by
[libtiff][d-libtiff], [GDAL][d-gdal] and [Exiv2][d-exiv2]; OpenEXR's
equivalent is the chunk ([OpenEXR][d-openexr-file]).

### Data window and display window

OpenEXR gives an image two rectangles: the **display window**, the frame a
viewer shows, and the **data window**, the region where pixels exist. The data
window may be larger (overscan kept for blurs and camera shake), smaller (a
re-rendered region of interest) or offset into negative coordinates
([OpenEXR Technical Introduction][exr-windows]). OpenImageIO carries the same
pair in `ImageSpec` as `x, y, z` with `width, height, depth` for the data window
and `full_x` to `full_depth` for the display window ([OpenImageIO][d-oiio-spec]).
A pixel model with only `(width, height)` cannot represent either offset, so
the rectangle origin is part of the [view](#image-and-view), not metadata.
Used by [OpenEXR][d-openexr-file] and [OpenImageIO][d-oiio-spec].

### Deep data

A **deep** image stores a variable-length list of samples at each pixel rather
than one value per channel: "Deep data images store an arbitrarily long list of
data at each pixel location", and "each pixel stores a different amount of
data" ([OpenEXR Technical Introduction][exr-deep]). Each sample has a fixed set
of channels, typically colour and depth, which is what deep compositing merges.
The memory model needs a per-pixel sample count and an offset table, not a
[stride](#stride) alone. Used by [OpenEXR][d-openexr-file] and
[OpenImageIO][d-oiio-pixel].

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
  `DRM_FORMAT_ARGB8888`, describe bit positions within a word, so the
  first-named component is in the highest bits. Vulkan stores that word in host
  byte order ([`formats.adoc`][vk-formats]); a DRM fourcc code is little-endian
  unless it carries `DRM_FORMAT_BIG_ENDIAN` ([`drm_fourcc.h`][drm-fourcc]).

The suffix states how a stored integer becomes a value. **UNORM** maps `0` to
`0.0` and the largest value to `1.0`; **SNORM** does the same for signed
values; **SRGB** formats apply the sRGB [transfer function](#transfer-function)
on read. Julia's `N0f8` is UNORM as a number type.

### Data Format Descriptor

The **Data Format Descriptor** (DFD) of the [Khronos Data Format
Specification][kdfs] describes a format as data instead of by name: the colour
model, primaries and transfer function, an alpha-premultiplied flag, the texel
block dimensions, and for each sample its channel, bit offset, bit length and
value range. KTX2 stores one in every file. For a Basis Universal payload the
header's `vkFormat` is `VK_FORMAT_UNDEFINED`, so the DFD is the only description
of what the texels mean, and `libktx` computes block sizes from it rather than
from the `VkFormat` ([KTX-Software][d-ktx-container]; [KTX 2.0, Data Format
Descriptor][ktx2-dfd]). It carries for textures what [CICP](#cicp) carries for
video, plus the sample layout. Used by [KTX-Software][d-ktx-container],
[Basis Universal][d-basis], [glTF textures][d-gltf], [Filament and
bgfx][d-filament] and [Godot texture import][d-godot].

### Block-compressed formats and supercompression

A **block-compressed** format (BC1 to BC7, ETC2, ASTC) stores a fixed-size
**texel block**, for example 4×4 texels in 64 or 128 bits, which the GPU
decodes on sampling, so the texture stays compressed in GPU memory
([`formats.adoc`][vk-bc]). **Supercompression** adds a second, variable-rate
layer for storage and transmission (Basis Universal's ETC1S and UASTC, or Zstd
inside a KTX2 file), which is removed before upload or transcoded to whichever
block format the GPU supports. See the [GPU texture compression][p-texture]
papers.

### Mip levels, array layers and faces

A **mip level** is one image of a **mipmap** chain: level 0 is full size and
each further level halves each dimension, down to one texel, so a sampler can
read the level whose texel size matches the screen footprint. **Array layers**
stack images of one size, and a cube map has six **faces**. A GPU texture is
therefore indexed by level, layer and face before any pixel coordinate, and a
GPU container records all of them: the KTX2 header carries `layerCount`,
`faceCount` and `levelCount`, and its level index gives each level's byte
offset and length ([KTX 2.0, mip level array][ktx2-mip];
[KTX-Software][d-ktx-container]). OpenEXR tiles add RIP-maps, which reduce x and
y independently ([OpenEXR][d-openexr-pixel]). Used by
[KTX-Software][d-ktx-container], [Vulkan transfer][d-vk-pixel], [glTF
textures][d-gltf], [Filament and bgfx][d-filament], [Godot texture
import][d-godot], [Skia][d-skia], [OpenImageIO][d-oiio-pixel] and [Dplug
graphics][d-dplug].

### Transcoding

A supercompressed texture is **transcoded** at load time: an intermediate
format (Basis Universal's ETC1S or UASTC) is rewritten directly into whichever
[block-compressed](#block-compressed-formats-and-supercompression) format the
device supports, without decoding to pixels and re-encoding.
`ktxTexture2_TranscodeBasis` takes the target (`KTX_TTF_BC7_RGBA`,
`KTX_TTF_ETC2_RGBA`, `KTX_TTF_ASTC_4x4_RGBA` and others) and picks the `_SRGB`
`VkFormat` when the [DFD](#data-format-descriptor) says the transfer function is
sRGB ([KTX-Software][d-ktx-transcode]). The choice of target is a device query,
which ties the decode step to the [GPU format support][hw] of the machine. Used
by [Basis Universal][d-basis], [KTX-Software][d-ktx-transcode], [glTF
textures][d-gltf] and [Filament and bgfx][d-filament].

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

### ICtCp and YCgCo

Two colour-difference encodings in the [CICP](#cicp) matrix table are not
plain YCbCr matrices. **ICtCp** (matrix code 14) is defined on PQ- or
HLG-encoded LMS values, so it is a non-linear transform; **YCgCo** (code 8,
with the lossless YCgCo-R variants 16 and 17) uses luma, a green and an
orange difference with integer-friendly coefficients. libavif's matrix table
says ICtCp "can't represent using Kr and Kb" and its RGB conversion refuses
code 14 and limited-range YCgCo ([CICP][d-cicp-tables];
[`reformat.c`][avif-reformat]). A converter built on a `(Kr, Kb)` pair
therefore covers most of the table but not all of it. Used by [CICP][d-cicp-tables]
and [Basis Universal][d-basis].

### Full and limited range

**Full range** uses every code (0 to 255 for 8 bits). **Limited range** (also
called video or studio range) puts black at 16 and white at 235 for luma, 16 to
240 for chroma. Most video is limited range and most still images full range;
treating one as the other crushes or washes out the image.

### CICP

**CICP** (Coding-Independent Code Points, ITU-T H.273) assigns numbers to colour
primaries, transfer characteristics and matrix coefficients, plus a full-range
flag. The same four values identify colour in AV1, HEVC, AVIF, HEIF and PNG's
`cICP` chunk, so one parser and one table cover them all
([ITU-T H.273][h273]). JPEG XL is the near miss: its colour encoding reuses
CICP numbers for a subset but keeps white point and primaries as separate
enums, so its values need a mapping table ([CICP][d-cicp-carriers]).

### ICC profile

An **ICC profile** describes a colour space as data: matrices, curves or lookup
tables mapping device values to a profile connection space (CIE XYZ or Lab). It
covers what CICP's enumerations cannot, such as printers, camera profiles and
measured displays. Version 4 is the common one; iccMAX (v5) generalises it
([ICC specifications][icc]). Embedding is format-specific: PNG `iCCP`, a JPEG
`APP2` segment, a WebP `ICCP` chunk.

### Profile connection space

The **profile connection space** (PCS) is the colour space every ICC profile
converts to or from, so any two profiles connect through it without knowing
each other. It is CIE XYZ or CIELAB under a D50 adopted white: the header's
illuminant field must round to "the nCIEXYZ values of CIE illuminant D50"
([ICC.1:2022][icc-v44], 7.2.16). Profiles for other whites, such as sRGB's D65,
are adapted to D50 and record the adaptation (see [chromatic
adaptation](#chromatic-adaptation)). Lab has a v4 and a legacy v2 16-bit
encoding, and iccMAX adds spectral connection spaces ([ICC v4 and
iccMAX][d-icc-pcs]). Used by [ICC v4 and iccMAX][d-icc-pcs], [Little
CMS 2][d-lcms2] and [libvips][d-libvips-colour].

### Colour management module and rendering intent

A **colour management module** (CMM) is the engine that links a source and a
destination profile through the [PCS](#profile-connection-space) into one
transform and applies it to pixels; Little CMS 2 and Skia's `skcms` are the two
open ones the survey reads. The **rendering intent** says how colours outside
the destination gamut are handled. ICC defines four, numbered 0 to 3:
perceptual, media-relative colorimetric, saturation and ICC-absolute
colorimetric ([ICC.1:2022][icc-v44], Table 23). A profile may hold a different
lookup table per intent; Little CMS 2 falls back to perceptual when the
requested one is missing, while `skcms` takes no intent parameter and prefers
`A2B0` ([ICC v4 and iccMAX][d-icc-intents]). Formats carry an intent too:
PNG's `sRGB` chunk holds one ([libpng][d-libpng-colour]), and so does libjxl's
colour encoding ([libjxl][d-libjxl-colour]). Used by [ICC v4 and
iccMAX][d-icc-intents], [Little CMS 2][d-lcms2], [libpng][d-libpng-colour] and
[libjxl][d-libjxl-colour].

### Chromatic adaptation

**Chromatic adaptation** converts colours measured under one white point to
the colours that look the same under another, with a linear transform in a
cone-response space (Bradford and von Kries are the common ones). ICC profiles
record the adaptation they applied to reach the D50
[PCS](#profile-connection-space) in the `chad` tag, which version 4 requires
whenever the measurement's adopted white differs from the PCS white
([ICC.1:2022][icc-v44]; [ICC v4 and iccMAX][d-icc-pcs]). A conversion that
skips the step is wrong in a way tests catch at once: the color library defines
`chromaticAdaptationMatrix` but no conversion calls it, so linear sRGB (D65)
white arrives in D50 Lab with `b*` of about -19.4 ([color][d-color-colour]). Used by [ICC v4 and iccMAX][d-icc-pcs], [Little
CMS 2][d-lcms2] and [color][d-color-colour].

### HDR gain map

A **gain map** stores an SDR base image plus a second, usually low-resolution
image of per-pixel gains that reconstruct an HDR rendition. A display scales
the gains to its own headroom, so one file renders on both SDR and HDR screens.
Ultra HDR JPEG and ISO 21496-1 standardise the approach.

### HDR headroom

**HDR headroom** is how much brighter than SDR white a display can show at
this moment, expressed as log2 of HDR white over SDR white. It is the one
number a renderer supplies to a [gain map](#hdr-gain-map): the file records the
headroom of its base and alternate renditions, and libavif weights the gain by
`(hdrHeadroom - baseHdrHeadroom) / (alternateHdrHeadroom - baseHdrHeadroom)`,
clamped to 0 to 1 and negated when the alternate rendition has less headroom
than the base ([gain maps][d-gainmap-apply]). The Ultra HDR specification
requires the gain to be applied "using exponentiation" so that tonal
relationships survive ([Ultra HDR image format][uhdr]). Headroom changes with
display brightness, so the same file renders differently over time. Used by
[gain maps][d-gainmap-apply] and [libavif][d-libavif-colour].

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

### PNG chunks, CRC-32 and Adler-32

A PNG file is an 8-byte signature followed by **chunks**, each a 4-byte length,
a 4-byte type, the data and a CRC-32 over type and data ([PNG Third
Edition][png3]). `IHDR` comes first and `IEND` last; the image data is split
across one or more `IDAT` chunks whose payloads concatenate into a single zlib
stream, which ends with an Adler-32 of the decompressed bytes. The two checksums
cover opposite sides of the decoder: Wuffs hashes the CRC over consumed input
and the Adler-32 over produced output, both incrementally across suspensions,
and verifies critical-chunk CRCs while ignoring ancillary ones, which its
source likens to libpng's default of warning and discarding the chunk
([Wuffs][d-wuffs-png]). Used by [libpng][d-libpng],
[libspng][d-libspng], [stb_image][d-stb], [Wuffs][d-wuffs-png] and
[zune-image][d-zune].

### ISOBMFF boxes and items

The ISO base media file format (ISOBMFF, ISO/IEC 14496-12) is a tree of
**boxes**, each a size, a four-character type and a payload that may hold
further boxes. MP4, HEIF, AVIF and the JPEG XL container use it. HEIF and AVIF
add **items** on top: a `meta` box lists coded images, thumbnails, alpha planes,
Exif and XMP blobs as items, locates their bytes, attaches properties to them
and links them with typed references, so one file is an item graph rather than
one image. libheif parses each box through a byte range that knows its nesting
depth and constructs one of 106 known box types, rejecting a file that nests too
deeply ([libheif][d-libheif-read]; [`box.cc`][heif-box]). Used by
[libheif][d-libheif-read], [libavif][d-libavif-io], [libjxl][d-libjxl-io],
[gain maps][d-gainmap-containers], [Exiv2][d-exiv2], [ExifTool][d-exiftool-walk]
and [zune-image][d-zune].

### IFD and BigTIFF

A TIFF file is a header and a linked list of **image file directories** (IFDs).
An IFD is a count of tag entries, each a tag number, a type, a count and a value
or an offset to it, followed by the offset of the next IFD; each page or
sub-image is one IFD, and tags such as `SubIFD` and `EXIFIFDOffset` point at
further directories ([libtiff][d-libtiff]). The classic header holds version 42
and 32-bit offsets; **BigTIFF** holds version 43 and 64-bit offsets and counts,
with 8-byte field types (`LONG8`, `SLONG8`, `IFD8`) to hold them, and keeps the
rest of the structure ([`tiff.h`][tiff-header]). EXIF reuses the structure
inside JPEG and other containers (`IFD0`, the Exif IFD, `IFD1` for the
thumbnail). Because every link is an offset, an IFD can point at itself or at an
earlier one: libtiff records the directory numbers and offsets it has seen and
caps their count ([libtiff][d-libtiff]), and ExifTool reports "IFD1 pointer
references previous IFD0 directory" ([ExifTool][d-exiftool-hostile]). Used by
[libtiff][d-libtiff], [GDAL][d-gdal], [ExifTool][d-exiftool-hostile],
[Exiv2][d-exiv2] and [nvImageCodec][d-nvimagecodec].

### Cloud Optimized GeoTIFF

A **Cloud Optimized GeoTIFF** (COG) is an ordinary tiled TIFF or BigTIFF laid
out for reading over HTTP range requests: 512-pixel tiles by default, overviews
down to about one tile, all IFDs and tile index arrays first and tile data after
them, smallest overview first and full resolution last ([`cog.rst`][gdal-cog]).
A client reads the header region once and then fetches only the
[striles](#strips-tiles-and-striles) of the overview level and region it
displays. GDAL adds a "ghost area" of structural metadata that other TIFF readers
skip ([GDAL][d-gdal]). Used by [GDAL][d-gdal] and [libtiff][d-libtiff].

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

### Checkpoint and replay

Short of coroutines, a decoder can be made resumable by **checkpoint and
replay**: it saves its state at a unit boundary, and when input runs out it
restores the checkpoint and reports suspension, so the next call re-decodes
the unit from the start. libwebp saves the macroblock context and token reader
before each lossy macroblock and restores them on a short read, and re-parses a
lossless header from scratch on each attempt ([libwebp][d-libwebp-idec];
[`idec_dec.c`][webp-idec]). libjpeg-turbo's suspending data source is the same
shape at the [MCU](#minimum-coded-unit): the decompressor "will backtrack to"
the restart point, so the caller must keep the unconsumed bytes ([`libjpeg.txt`,
suspension][jpeg-susp]). zune-image retries JPEG from its last checkpoint. The
cost is repeated work per unit and a buffer of unconsumed input; the gain is
that no suspension point is needed inside the entropy decoder. Used by
[libwebp][d-libwebp-idec], [libjpeg-turbo][d-jpeg-susp] and
[zune-image][d-zune-io].

### Adam7 interlacing

**Adam7** is PNG's interlace method: the image is transmitted in seven passes
over an 8 by 8 pattern, the first pass carrying one pixel in 64 and each later
pass filling in between, so a decoder can show a coarse preview after the first
passes ([PNG Third Edition][png3]; `PNG_INTERLACE_ADAM7` and
`PNG_INTERLACE_ADAM7_PASSES` in [`png.h`][png-h-adam7]). Each pass is a
sub-image with its own rows and filters, which complicates row-by-row output:
libpng's progressive reader hands each row to the caller with its pass number
and offers `png_progressive_combine_row` for a replicated preview ([libpng][d-libpng-io]).
Used by [libpng][d-libpng-io], [libspng][d-libspng], [Wuffs][d-wuffs-png],
[stb_image][d-stb], [arsd image modules][d-arsd] and [Boost.GIL][d-gil].

### Minimum coded unit

A JPEG scan is coded in **minimum coded units** (MCUs): the smallest group of
8 by 8 blocks that covers every component of one region. Without subsampling an
interleaved MCU covers 8 by 8 pixels; with 4:2:0 it holds four luma blocks and
one block of each chroma channel and covers 16 by 16 pixels ([ITU-T
T.81][t81]). Restart markers fall between MCUs, and so do libjpeg-turbo's
suspension restart points ([libjpeg-turbo][d-jpeg-susp]). An MCU row is the
natural unit of incremental output. Used by [libjpeg-turbo][d-jpeg-susp] and
[zune-image][d-zune-io].

### Fancy upsampling

**Fancy upsampling** reconstructs subsampled chroma by interpolation instead of
repeating each chroma sample. libjpeg-turbo's version is "linear interpolation
between component centers, also known as a 'triangle filter'", with output
centres a quarter and three quarters of the way between input centres
([`jdsample.c`][jpeg-fancy]); `do_fancy_upsampling` selects it, and the
alternative is "a faster but sloppier method" ([`libjpeg.txt`][jpeg-fancy-flag]).
The cheaper path in libjpeg-turbo is **merged upsampling**, which fuses
replication with colour conversion; it has been the site of repeated defects
([libjpeg-turbo][d-jpeg-hostile]). libwebp exposes the same choice as
`no_fancy_upsampling` ([libwebp][d-libwebp-api]). The choice changes output
pixels, so a [differential oracle](#differential-oracle) has to fix it on both
sides. Used by [libjpeg-turbo][d-jpeg-pipeline] and [libwebp][d-libwebp-api].

### Hostile input

**Hostile input** is any input not known to be well formed: in practice, every
file and network payload. Image decoders have a long history of memory-safety
CVEs. Defences are bounds-checked parsing, explicit **limits** (maximum width,
height, pixel count, allocation and chunk count, set by the caller), checked
integer arithmetic for size computations, and fuzzing. A **decompression bomb**
is a small file that declares or inflates to an enormous image, so limits are
checked before allocation, not after. See the [hostile input][p-hostile] papers.

## Generic programming

### Design by introspection

**Design by introspection** writes a generic component as a shell that asks,
at compile time, which optional primitives its argument provides and adapts to
them, instead of requiring a fixed interface. In D the questions are traits
(`__traits(compiles, …)`, `is(…)`, `hasMember`) and the adaptation is
`static if`; the repository's [guidelines][dbi-guide] call the pattern "shell
with hooks". `ae.utils.graphics` is the image-library case: three predicates
(`isView`, `isWritableView`, `isDirectView`), optional primitives such as
`scanline` propagated through each adapter by `static if`, and `static assert`
to prove the propagation ([`ae.utils.graphics`][d-ae-generic]). mir's `Slice`
specialises on its contiguity kind the same way ([mir-algorithm][d-mir-generic]).
Used by [`ae.utils.graphics`][d-ae-generic], [mir-algorithm][d-mir-generic],
[dcv][d-dcv-generic], [intel-intrinsics][d-intel-generic] and [Dplug
graphics][d-dplug].

### Concepts, traits and tag dispatch

C++ generic libraries state requirements as **concepts** (named sets of valid
expressions and associated types), compute properties with **trait classes**,
and select an overload with **tag dispatch**: an empty tag type, produced by a
trait, picks the implementation. Boost.GIL defines a hierarchy of pixel,
locator and view concepts checked with Boost.ConceptCheck when
`BOOST_GIL_USE_CONCEPT_CHECK` is set ([Boost.GIL][d-gil-concepts];
[`concept_check.hpp`][gil-concept-check]). VIGRA's `StridedArrayTag` and
`UnstridedArrayTag` select an iterator ([VIGRA][d-vigra-generic]). Julia's
**Holy traits** are the run-time-free equivalent: a function returns a singleton
type such as `HasDimNames{true}()` and methods dispatch on it
([JuliaImages][d-julia-generic]; [`traits.jl`][julia-traits]). Used by
[Boost.GIL][d-gil-concepts], [VIGRA][d-vigra-generic],
[JuliaImages][d-julia-generic] and [Highway][d-highway-tags].

### Monomorphisation

**Monomorphisation** compiles one copy of generic code per concrete type, so
each copy runs at the speed of hand-written code and the binary grows with the
number of instantiations. zune-image keeps the sample type out of its `Image`
type, matches on a run-time `BitType`, and instantiates each kernel for `u8`,
`u16` and `f32` ([zune-image][d-zune-generic]). libjpeg-turbo does it with the
preprocessor: each precision-dependent file is compiled up to three times, for
8, 12 and 16-bit samples, and the API spells every row function three ways
([libjpeg-turbo][d-jpeg-widths]). image-rs once generalised `load_from_memory` to
avoid monomorphising all decoders, and reverted it when it broke type inference
downstream ([image-rs][d-imagers-generic]). Gamut's
README uses "monomorphic" in the opposite sense: one run-time-typed `Image`
struct for every pixel type, with no instantiation at all ([Gamut][d-gamut]).
Used by [zune-image][d-zune-generic], [libjpeg-turbo][d-jpeg-widths] and
[image-rs][d-imagers-generic].

### Type erasure

**Type erasure** hides a set of static types behind one run-time value, so a
decoder can return "an image" whose pixel type is known only after reading the
header. The closed form is a tagged union over a fixed list: image-rs'
`DynamicImage` is a `#[non_exhaustive]` enum of twelve buffer types with a macro
that expands every operation to a twelve-arm `match` ([`dynimage.rs`][rs-dynimage]),
and Boost.GIL's `any_image` is a `variant2::variant` over a type list
([Boost.GIL][d-gil-anyimage]). The open form is an interface or trait object,
as in zune-image's `dyn` boundary, or ITK's type-erased metadata dictionary.
Either way an algorithm dispatches once per call and runs static code inside.
`ae.utils.graphics` has no erased image at all, so a program must choose its
colour type at compile time and let the codec convert ([`ae.utils.graphics`][d-ae-generic]).
Used by [image-rs][d-imagers-dyn], [Boost.GIL][d-gil-anyimage],
[zune-image][d-zune-generic] and [ITK][d-itk].

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

### Bounds inference

**Bounds inference** works out, from the outputs back to the inputs, which
region of each intermediate image a pipeline must compute. Halide's lowering
pass injects "expressions defining those bounds" ([`BoundsInference.h`][halide-bi]):
for each producer at its `compute_at` level it defines symbolic `min` and
`extent` variables from the interval of coordinates its consumers read, as
axis-aligned boxes ([Halide][d-halide-bi]). One check per buffer dimension at
pipeline entry then replaces bounds checks in the inner loops. ITK's pipeline is
a run-time counterpart: each filter turns a requested output region into the
input region it needs, before any pixel is computed ([ITK][d-itk-regions]).
Used by [Halide][d-halide-bi] and [ITK][d-itk-regions].

### Halo and border handling

A [neighbourhood](#point-neighbourhood-and-global-operations) operation on a tile
needs pixels from outside it: the **halo** (or apron), as wide as the kernel's
radius. Tiled and parallel execution either reads the halo from neighbouring
tiles, recomputes it, or copies tiles with a border. VIGRA's blockwise layer
decomposes an N-D array into blocks with a border halo, filters each block in
parallel and writes the core back ([VIGRA][d-vigra-par]; [`multi_blockwise.hxx`][vigra-blockwise]).
At the image edge the halo has no source pixels, so a border mode (clamp,
mirror, wrap, constant) defines them. `ae.utils.graphics` splits work into row
bands with no halo, which serves only point operations
([`ae.utils.graphics`][d-ae-par]). OpenCV's `locateROI` and `adjustROI` widen a region-of-interest view
into its parent to take in a halo without copying ([OpenCV][d-opencv]). Used by
[VIGRA][d-vigra-par], [Halide][d-halide-bi], [OpenCV][d-opencv] and
[`ae.utils.graphics`][d-ae-par].

### Demand-driven evaluation

In a **demand-driven** pipeline nothing is computed until a sink asks for a
region; the request travels upstream and each stage computes only the pixels
that region needs, in small pieces, so a large image never has to be in memory.
libvips represents an image that "may have no pixels": a partial image holds
`start`, `generate` and `stop` callbacks and a demand hint, and generate fills
one output region at a time ([libvips][d-libvips-image]). The hints
(`SMALLTILE`, `FATSTRIP`, `THINSTRIP`, `ANY`) are combined across a pipeline to
choose the region shape ([`image.h`][vips-dhint]). ITK streams the same way
through requested regions ([ITK][d-itk-regions]). Used by
[libvips][d-libvips-image] and [ITK][d-itk-regions].

## SIMD and dispatch

### Auto-vectorisation

**Auto-vectorisation** is the compiler turning a scalar loop into SIMD
instructions without source changes ([LLVM vectorizers][llvm-vec]). It needs
loops whose trip count, aliasing and floating-point rules allow reordering, so
libraries help it with contiguous inner loops and relaxed-math attributes: mir
marks kernels `@fmamath`, dcv uses `@fastmath` on LDC
([`mir.math.common`][mir-fmamath]; [dcv][d-dcv-simd]). It is the strategy of
most generic libraries in the survey, and its result depends on the compiler
version and flags. Used by [mir-algorithm][d-mir-simd], [dcv][d-dcv-simd],
[VIGRA][d-vigra-par], [ITK][d-itk-simd], [libpng][d-libpng-simd],
[libspng][d-libspng], [Simd][d-simd] and [zune-image][d-zune].

### Portable SIMD

A **portable SIMD** library gives one source-level vector API that compiles to
each instruction set. Highway's descriptors (`ScalableTag`, `CappedTag`,
`FixedTag`) are zero-sized types that carry the lane type and count, so the same
kernel compiles for x86, Arm NEON and the scalable Arm SVE and RISC-V V targets
([Highway][d-highway-tags]; [Highway README][hwy-readme]). OpenCV's universal
intrinsics follow the same idea. intel-intrinsics takes the other route for D:
it gives Intel's intrinsic names one fixed meaning and chooses at compile time
how to produce it on DMD, LDC or GDC, for x86, AArch64, 32-bit ARM or
WebAssembly ([intel-intrinsics][d-intel-generic]). Used by [Highway][d-highway-tags],
[libjxl][d-libjxl-simd], [libvips][d-libvips-simd], [OpenCV][d-opencv],
[intel-intrinsics][d-intel-generic], [Dplug graphics][d-dplug] and
[OpenImageIO][d-oiio-simd].

### Run-time CPU dispatch

**Run-time CPU dispatch** compiles a kernel for several instruction sets and
picks one when the program runs, so one binary uses AVX2 or AVX-512 where the
CPU has it and still runs elsewhere. The check must include the operating
system: Halide's x86 detection tests `XCR0` before trusting a CPUID bit, since
the OS has to save the wider registers ([`x86_cpu_detect.h`][halide-xcr0]).
Highway re-includes a translation unit once per target and dispatches through a
table ([Highway][d-highway-dispatch]; [quick reference][hwy-dispatch]). Hand
SIMD codecs (libjpeg-turbo, libwebp, libyuv, zune-image) choose per function at
run time, through a function pointer or a CPU-flag test; D's intel-intrinsics
selects at compile time only. Used by
[Highway][d-highway-dispatch], [Halide][d-halide-targets], [libjpeg-turbo][d-jpeg-simd],
[libwebp][d-libwebp-simd], [Simd][d-simd], [OpenCV][d-opencv] and
[OpenColorIO][d-ocio].

## GPU and I/O

### Staging and upload

To reach GPU-local memory, pixels are usually copied into a host-visible
**staging buffer** and then copied by a GPU command into the image, which
converts to [optimal tiling](#tiling) on the way. Where the GPU exposes
host-visible device memory (resizable BAR), the CPU can write device memory
directly. The Sparkles path is described in the [Vulkan baseline][bl-vk].

### Write-combined memory

Host-visible device memory, and upload heaps generally, are usually mapped
**write-combined**: CPU writes are buffered and sent across the bus in bursts,
and CPU reads are uncached and very slow. Code that writes there must write
sequentially and never read back. DirectStorage's sample copies through a
scratch buffer when decompressing into an upload heap because "ZLib
decompression tends to read from the destination buffer, which is extremely
slow from write-combined memory" ([DirectStorage and IoRing][d-ds-formats];
[`DStorageLoader.cpp`][ds-loader]). A decoder that writes its output straight
into a mapped staging buffer is subject to the same rule
([Vulkan transfer][d-vk-cpu]). Used by [DirectStorage and IoRing][d-ds-formats]
and [Vulkan transfer][d-vk-cpu].

### External memory and zero-copy import

**External memory** lets one API use memory allocated by another, without a
copy. Examples are a dma-buf from a video decoder or camera imported into
Vulkan, and host memory imported with `VK_EXT_external_memory_host`. Zero-copy
paths need the producer's layout, [stride](#stride) and DRM format modifier to
match what the consumer accepts.

### dma-buf

A **dma-buf** is the Linux kernel's handle for a buffer shared between
devices and processes, passed as a file descriptor. One driver exports it
(a GPU, a video decoder, a camera), and others import it and access the same
pages; CPU access to an `mmap`ed dma-buf is bracketed by `DMA_BUF_IOCTL_SYNC`
([kernel dma-buf documentation][dmabuf-doc]). Vulkan imports one as
`VkDeviceMemory` with `VK_EXT_external_memory_dma_buf`, which by its own
account adds only "the ability to import/export between `dma_buf` and
`VkDeviceMemory`" ([`VK_EXT_external_memory_dma_buf`][vk-dmabuf]). User space
can make a dma-buf from a sealed memfd with `/dev/udmabuf`, which lets a file
read land in memory the GPU then imports without a copy; no `io_uring` storage
opcode reads into a dma-buf directly ([`io_uring` storage][d-uring-gpu]). Used
by [`io_uring` storage][d-uring-gpu], [Vulkan transfer][d-vk-import] and
[DLPack][d-dlpack-gpu].

### DRM format modifier

A **DRM format modifier** is a 64-bit code that names a GPU's tiled,
compressed or otherwise vendor-specific memory layout of an image, alongside
the fourcc that names its pixel format. Modifiers "do not **describe** memory
layouts"; they "**name** memory layouts", a small vendor-preferred set for
sharing ([`VK_EXT_image_drm_format_modifier`][vk-drm]). Importing a
[dma-buf](#dma-buf) as an image needs the modifier plus per-plane offsets and
pitches: Vulkan creates the image with `VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT`
and either a list of acceptable modifiers or one explicit modifier, which is how
a VA-API decoder's NV12 surface reaches a Vulkan image without a copy ([Vulkan
transfer][d-vk-import]). Producer and consumer must agree on a modifier both
support, so the pair is negotiated, not chosen by one side. Used by [Vulkan
transfer][d-vk-import] and [DLPack][d-dlpack-gpu].

### Sampler YCbCr conversion

Vulkan samples [planar](#interleaved-planar-and-semi-planar) YCbCr images
through a **sampler YCbCr conversion** (`VkSamplerYcbcrConversion`, core since
1.1), which "is mainly used for processing inputs from video decoders and
cameras" ([`VK_KHR_sampler_ycbcr_conversion`][vk-ycbcr-app]). The object fixes
the [matrix](#ycbcr-and-matrix-coefficients) (`ycbcrModel`), the
[range](#full-and-limited-range) (`ycbcrRange`), the [chroma
siting](#chroma-subsampling) and the chroma filter, and it must be baked into
the pipeline as an immutable sampler ([`samplers.adoc`][vk-immutable]). So the
[CICP](#cicp) values of a decoded frame select pipeline state, not shader
parameters. Used by [Vulkan transfer][d-vk-ycbcr] and [CICP][d-cicp-carriers].

### GPU decompression

**GPU decompression** moves the decompression of assets (GDeflate in
DirectStorage, `VK_NV_memory_decompression` and `VK_EXT_memory_decompression`
in Vulkan) from the CPU to the GPU, so storage reads go to GPU memory still
compressed. See the [storage-to-GPU][p-gpu-decode] papers and the [hardware
matrix][hw] for which devices expose it.

### GDeflate

**GDeflate** is DEFLATE reorganised for parallel decoding. It keeps DEFLATE's
LZ77 and Huffman coding and permutes the bitstream: "splitting the DEFLATE
stream into 32 sub-streams and then serializing them", which "allows for up to
32 way parallelism during decompression" ([GDeflate stream format][gd-spec]).
A decoder takes one Huffman symbol per sub-stream per round, one GPU lane per
sub-stream. Above the bitstream, a tile container splits the data into tiles of
at most 64 KiB, the unit of parallelism across workgroups or threads
([DirectStorage and IoRing][d-ds-gdeflate]). DirectStorage, nvCOMP and the
Vulkan memory-decompression extensions decode the same format
([Vulkan transfer][d-vk-decomp]; [Tier C digest][d-tc-nvcomp]). Used by
[DirectStorage and IoRing][d-ds-gdeflate], [Vulkan transfer][d-vk-decomp] and
the [Tier C digest][d-tc-nvcomp].

### Timeline semaphore

A **timeline semaphore** is a GPU synchronisation object with "a strictly
increasing 64-bit unsigned integer payload": work waits until the counter
reaches a value and signals by raising it ([`synchronization.adoc`][vk-timeline]).
One semaphore can then order a whole stream of uploads and decodes, and the host
can wait on or signal it too. It is the Vulkan counterpart of a CUDA stream
event: nvImageCodec's decode future and DLPack's stream exchange are the CUDA
form of the same hand-off, and neither has a Vulkan one ([nvImageCodec][d-nvimagecodec];
[DLPack][d-dlpack-gpu]). Sparkles does not use timeline semaphores yet
([Vulkan baseline][bl-vk]), nor does KTX-Software's Vulkan upload
([KTX-Software][d-ktx]), and Halide's host/device protocol of two dirty bits
has no notion of queues or timelines ([Halide][d-halide-gpu]). Used by
[nvImageCodec][d-nvimagecodec] and [DLPack][d-dlpack-gpu].

### Registered buffers and direct I/O

`io_uring` can register buffers with the kernel once, so later reads into them
skip per-call page pinning. `O_DIRECT` bypasses the page cache, which suits
large sequential reads that will not be read again. Together they are Linux's
counterpart to Windows' IoRing. See the [event-horizon baseline][bl-eh].

## Testing and correctness

### Coverage-guided fuzzing

A **coverage-guided fuzzer** runs a small harness function on generated inputs
in-process, keeps the inputs that reach new code, and mutates them further;
[libFuzzer][libfuzzer] is the common engine, with AFL++ and honggfuzz as
alternatives and Google's [FuzzTest][fuzztest] as a unit-test-style front end.
A decoder harness usually decodes the input bytes with limits set, and a crash
or [sanitizer](#sanitizers) report is the failure. Its blind spot is depth:
Hawkes argues the WebP Huffman-table overflow behind CVE-2023-4863 was very
unlikely to be found this way ([libwebp][d-libwebp-hostile]). Halide fuzzes its
own compiler reasoning (bounds, simplification) rather than inputs
([Halide][d-halide-test]). Used by the deep-dives listed under
[fuzzing](./index.md#by-fuzzing) in the taxonomy.

### OSS-Fuzz

[OSS-Fuzz][ossfuzz] is Google's continuous fuzzing service for open-source
projects. A project contributes a build script and harnesses; the service builds
them with libFuzzer, AFL and honggfuzz under AddressSanitizer, MemorySanitizer
and UndefinedBehaviorSanitizer, fuzzes continuously and files reports, which
are later disclosed. libpng's project file lists exactly that matrix
([`project.yaml`][ossfuzz-libpng]). Its CI integration, CIFuzz, runs the
harnesses on pull requests. OSS-Fuzz found libavif's CVE-2020-36407 and
libspng's eleven 2020 issues; it has fuzzed Wuffs since February 2018, and
Wuffs' notes say that as of November 2019 it had found no memory-safety bug
([libavif][d-libavif-hostile]; [libspng][d-libspng-hostile];
[Wuffs][d-wuffs-hostile]). Used by [libpng][d-libpng-hostile],
[libspng][d-libspng-hostile], [libavif][d-libavif-hostile],
[Wuffs][d-wuffs-hostile], [libjxl][d-libjxl], [libjpeg-turbo][d-jpeg-hostile],
[libwebp][d-libwebp-hostile], [libtiff][d-libtiff], [OpenEXR][d-openexr-hostile],
[Skia][d-skia-test], [GDAL][d-gdal], [stb_image][d-stb], [libheif][d-libheif-test]
and others.

### Sanitizers

A **sanitizer** is compiler instrumentation that turns silent undefined
behaviour into a report at the faulting instruction. AddressSanitizer (ASan)
catches out-of-bounds accesses and use after free, MemorySanitizer reads of
uninitialised memory, and UndefinedBehaviorSanitizer (UBSan) signed overflow,
bad shifts and similar ([Clang AddressSanitizer][asan]). Fuzzers run under them
so that a corrupting write fails immediately instead of crashing later or not
at all. The survey's own probes used them: building stb_image with
`-fsanitize=address,undefined` turned a hand-built GIF with vertical flipping on
into a reported heap-buffer-overflow in `stbi__vertical_flip`
([stb_image][d-stb-hostile]), and the GDeflate reference codec under ASan
reported a heap-buffer-overflow write ([DirectStorage and IoRing][d-ds-hostile]). D's
bounds-checked slices give the same signal for array accesses in `@safe` code.
Used by [stb_image][d-stb-hostile], [libpng][d-libpng-hostile],
[OpenEXR][d-openexr-hostile], [libheif][d-libheif-test], [SAIL][d-sail],
[DirectStorage and IoRing][d-ds-hostile] and others.

### PngSuite

**PngSuite** is Willem van Schaik's set of small PNG files that exercise every
colour type and bit depth, interlacing, gamma, ancillary chunks and deliberately
corrupt files; libpng vendors the basic subset in `contrib/pngsuite`, whose
README calls it "the much larger PngSuite test-set of images, available for
developers of PNG supporting software" ([`contrib/pngsuite`][pngsuite]). It is
the most shared conformance corpus in the survey: libspng runs a
[differential](#differential-oracle) test against libpng over 175 of its images
([libspng][d-libspng-test]), stb_image keeps a reference-results table to diff
after loader changes and seeds its OSS-Fuzz targets with it
([stb_image][d-stb-test]), and Go checks each decode against a textual `.sng`
dump ([Go `image`][d-go-test]). Used by [libpng][d-libpng-test],
[libspng][d-libspng-test], [stb_image][d-stb-test], [Go `image`][d-go-test],
[zune-image][d-zune-test], [Boost.GIL][d-gil] and [dcv][d-dcv]. The survey ran
it against the [arsd image modules][d-arsd], which do not use it themselves;
[`ae.utils.graphics`][d-ae-test] uses no corpus, and [libtiff][d-libtiff] notes
that TIFF has no comparable suite.

### Differential oracle

A **differential oracle** checks an implementation against another one on the
same input instead of against expected outputs written by hand. It needs only
two implementations, and it finds disagreement rather than proving either right,
so a pair of mature decoders with opposite policies is the strongest form.
GDeflate's test compares the open reference codec with the closed DirectStorage
runtime in all four compression and decompression pairings
([`GDeflateTest.cpp`][gd-test]); libspng requires bit-identical output with
libpng per image, output format and flag combination, within 2% per sample for
gamma-corrected images ([libspng][d-libspng-test]);
the ICC deep-dive's table of where Little CMS 2 and `skcms` diverge is a ready
oracle for crafted profiles ([ICC v4 and iccMAX][d-icc-lessons]). Halide's form
is "same algorithm, different schedule": a vectorised result against a scalar
one ([Halide][d-halide-test]). Lossy codecs and resamplers need a tolerance
rather than equality, which ImageSharp's tolerant image comparison provides
([ImageSharp][d-imagesharp-test]). Used by [libspng][d-libspng-test],
[DirectStorage and IoRing][d-ds-test], [ICC v4 and iccMAX][d-icc-lessons],
[Halide][d-halide-test], [ImageSharp][d-imagesharp-test], [zune-image][d-zune-test],
[stb_image][d-stb-test] and others.

## Sources

- Wuffs notes on [pixel formats][wuffs-pf], [subsampling][wuffs-ps] and
  [coroutines][wuffs-co], at the revision in [`sources.tsv`](./sources.tsv).
- The Vulkan specification's [image tiling][vk-tiling] and [format][vk-formats]
  chapters.
- [ITU-T H.273][h273] and the [ICC specifications][icc], including
  [ICC.1:2022][icc-v44].
- The Vulkan specification's [DRM format modifier][vk-drm], [dma-buf
  import][vk-dmabuf], [YCbCr conversion][vk-ycbcr-app] and [timeline
  semaphore][vk-timeline] text, and the [kernel dma-buf documentation][dmabuf-doc].
- The [Khronos Data Format Specification][kdfs] and the [KTX 2.0
  specification][ktx2-dfd]; the [PNG Third Edition][png3] and [ITU-T T.81][t81].
- Source files at the revisions in [`sources.tsv`](./sources.tsv): libtiff
  [`tif_dir.h`][tiff-dir] and [`tiff.h`][tiff-header]; libjpeg-turbo
  [`jdsample.c`][jpeg-fancy] and [`libjpeg.txt`][jpeg-fancy-flag]; libwebp
  [`idec_dec.c`][webp-idec]; libheif [`box.cc`][heif-box]; Halide
  [`BoundsInference.h`][halide-bi] and [`x86_cpu_detect.h`][halide-xcr0];
  Highway's [README][hwy-readme] and [quick reference][hwy-dispatch]; the
  DirectStorage [GDeflate format][gd-spec] and [`GDeflateTest.cpp`][gd-test];
  libpng's [`png.h`][png-h-adam7] and [`contrib/pngsuite`][pngsuite]; OpenEXR's
  Technical Introduction on [windows][exr-windows] and [deep data][exr-deep].
- Tool documentation: [OSS-Fuzz][ossfuzz], [libFuzzer][libfuzzer],
  [FuzzTest][fuzztest], [AddressSanitizer][asan] and the [LLVM
  vectorizers][llvm-vec].
- The paper threads, baseline documents and deep-dives linked above.

<!-- References -->

[wuffs-pf]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-formats.md
[wuffs-ps]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-subsampling.md
[wuffs-co]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/coroutines.md
[vk-tiling]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/resources.adoc#L5110-L5118
[vk-formats]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/formats.adoc#L1643-L1777
[vk-bc]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/formats.adoc#L497-L558
[drm-fourcc]: https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/include/uapi/drm/drm_fourcc.h#L108-L198
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
[icc-v44]: https://www.color.org/specification/ICC.1-2022-05.pdf
[kdfs]: https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html
[ktx2-dfd]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_data_format_descriptor
[ktx2-mip]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_mip_level_array
[png3]: https://www.w3.org/TR/png-3/
[png-h-adam7]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L605
[pngsuite]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/contrib/pngsuite/README#L9-L13
[t81]: https://www.w3.org/Graphics/JPEG/itu-t81.pdf
[tiff-dir]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_dir.h#L81-121
[tiff-header]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiff.h#L48-163
[gdal-cog]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/cog.rst#L584-L619
[heif-box]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/box.cc#L466-L1024
[webp-idec]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/idec_dec.c#L307-L322
[jpeg-susp]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L1874-L1990
[jpeg-fancy]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdsample.c#L281-L286
[jpeg-fancy-flag]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L1479-L1482
[exr-windows]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/TechnicalIntroduction.rst#L26-L70
[exr-deep]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/TechnicalIntroduction.rst#L327-L346
[avif-reformat]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat.c#L125-L139
[uhdr]: https://developer.android.com/media/platform/hdr-image-format
[dbi-guide]: ../../guidelines/design-by-introspection-00-intro.md#the-core-pattern-shell-with-hooks
[gil-concept-check]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/concept_check.hpp#L38-L56
[julia-traits]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/traits.jl#L1-L50
[rs-dynimage]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L71-L127
[halide-bi]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/BoundsInference.h#L23-L26
[halide-xcr0]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/x86_cpu_detect.h#L228-L245
[vigra-blockwise]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_blockwise.hxx#L180-L222
[vips-dhint]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L71-L77
[llvm-vec]: https://llvm.org/docs/Vectorizers.html
[mir-fmamath]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/math/common.d#L28
[hwy-readme]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L211-L240
[hwy-dispatch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/quick_reference.md#L24-L66
[ds-loader]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/BulkLoadDemo/BulkLoadDemo/DStorageLoader.cpp#L71-L226
[dmabuf-doc]: https://docs.kernel.org/driver-api/dma-buf.html
[vk-dmabuf]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_external_memory_dma_buf.adoc#L18-L54
[vk-drm]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_EXT_image_drm_format_modifier.adoc#L58-L64
[vk-ycbcr-app]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/appendices/VK_KHR_sampler_ycbcr_conversion.adoc#L31-L57
[vk-immutable]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/samplers.adoc#L780-L791
[vk-timeline]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/synchronization.adoc#L3710-L3716
[gd-spec]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md#L13-L22
[gd-test]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflateTest/GDeflateTest.cpp#L174-L243
[ossfuzz]: https://google.github.io/oss-fuzz/
[ossfuzz-libpng]: https://github.com/google/oss-fuzz/blob/fe1478d57b3b5e66acdff48abbab6adcb6e7ff37/projects/libpng/project.yaml
[libfuzzer]: https://llvm.org/docs/LibFuzzer.html
[fuzztest]: https://github.com/google/fuzztest
[asan]: https://clang.llvm.org/docs/AddressSanitizer.html
[d-ae-generic]: ./ae-graphics.md#_2-genericity-mechanism
[d-ae-par]: ./ae-graphics.md#_7-cpu-parallelism-and-simd
[d-ae-test]: ./ae-graphics.md#_10-testing-and-conformance
[d-arsd]: ./arsd-image.md
[d-basis]: ./basis-universal.md
[d-cicp-carriers]: ./cicp.md#carriers
[d-cicp-tables]: ./cicp.md#the-tables-as-decoders-spell-them
[d-color-colour]: ./color.md#_3-colour-and-metadata
[d-dcv]: ./dcv.md
[d-dcv-generic]: ./dcv.md#_2-genericity-mechanism
[d-dcv-simd]: ./dcv.md#_7-cpu-parallelism-and-simd
[d-dlpack-gpu]: ./dlpack.md#_8-gpu-offload-and-interop
[d-dplug]: ./dplug-graphics.md
[d-ds-formats]: ./directstorage-ioring.md#compression-formats-and-the-custom-decompression-queue
[d-ds-gdeflate]: ./directstorage-ioring.md#gdeflate-the-format
[d-ds-hostile]: ./directstorage-ioring.md#_5-hostile-input-and-safety
[d-ds-test]: ./directstorage-ioring.md#_10-testing-and-conformance
[d-exiftool-hostile]: ./exiftool.md#_5-hostile-input-and-safety
[d-exiftool-walk]: ./exiftool.md#walking-containers
[d-exiv2]: ./exiv2.md
[d-filament]: ./filament-bgfx-textures.md
[d-gainmap-apply]: ./gain-maps.md#applying-it-for-a-display
[d-gainmap-containers]: ./gain-maps.md#containers
[d-gamut]: ./gamut.md#design-philosophy
[d-gdal]: ./gdal.md
[d-gil]: ./boost-gil.md
[d-gil-anyimage]: ./boost-gil.md#run-time-types-any-image-and-any-image-view
[d-gil-concepts]: ./boost-gil.md#the-concept-hierarchy
[d-gltf]: ./gltf-textures.md
[d-godot]: ./godot-texture-import.md
[d-go-test]: ./go-image.md#_10-testing-and-conformance
[d-halide-bi]: ./halide.md#lowering-and-bounds-inference
[d-halide-gpu]: ./halide.md#_8-gpu-offload-and-interop
[d-halide-targets]: ./halide.md#targets-and-features
[d-halide-test]: ./halide.md#_10-testing-and-conformance
[d-highway-dispatch]: ./highway.md#dynamic-dispatch-re-including-the-translation-unit
[d-highway-tags]: ./highway.md#descriptors-simd-scalabletag-cappedtag-fixedtag
[d-icc-intents]: ./icc.md#rendering-intents
[d-icc-lessons]: ./icc.md#lessons-for-sparkles
[d-icc-pcs]: ./icc.md#the-pcs-xyz-or-lab-relative-to-d50
[d-imagers-dyn]: ./image-rs.md#dynamicimage
[d-imagers-generic]: ./image-rs.md#_2-genericity-mechanism
[d-imagesharp-test]: ./imagesharp.md#_10-testing-and-conformance
[d-intel-generic]: ./intel-intrinsics.md
[d-itk]: ./itk.md#_3-colour-and-metadata
[d-itk-regions]: ./itk.md#regions-and-the-three-pipeline-passes
[d-itk-simd]: ./itk.md#_7-cpu-parallelism-and-simd
[d-jpeg-hostile]: ./libjpeg-turbo.md#_5-hostile-input-and-safety
[d-jpeg-pipeline]: ./libjpeg-turbo.md#the-decompression-pipeline
[d-jpeg-simd]: ./libjpeg-turbo.md#simd-dispatch
[d-jpeg-susp]: ./libjpeg-turbo.md#data-source-managers-and-suspension
[d-jpeg-widths]: ./libjpeg-turbo.md#one-source-file-three-sample-widths
[d-julia-generic]: ./juliaimages.md#_2-genericity-mechanism
[d-ktx]: ./ktx-software.md
[d-ktx-container]: ./ktx-software.md#the-container
[d-ktx-transcode]: ./ktx-software.md#transcoding-basis-payloads-ktxtexture2-transcodebasis
[d-lcms2]: ./lcms2.md
[d-libavif-colour]: ./libavif.md#_3-colour-and-metadata
[d-libavif-hostile]: ./libavif.md#_5-hostile-input-and-safety
[d-libavif-io]: ./libavif.md#_4-i-o-and-codec-architecture
[d-libheif-read]: ./libheif.md#reading-stream-ranges-boxes
[d-libheif-test]: ./libheif.md#_10-testing-and-conformance
[d-libjxl]: ./libjxl.md
[d-libjxl-colour]: ./libjxl.md#_3-colour-and-metadata
[d-libjxl-io]: ./libjxl.md#_4-i-o-and-codec-architecture
[d-libjxl-simd]: ./libjxl.md#_7-cpu-parallelism-and-simd
[d-libpng]: ./libpng.md
[d-libpng-colour]: ./libpng.md#_3-colour-and-metadata
[d-libpng-hostile]: ./libpng.md#_5-hostile-input-and-safety
[d-libpng-io]: ./libpng.md#_4-i-o-and-codec-architecture
[d-libpng-simd]: ./libpng.md#_7-cpu-parallelism-and-simd
[d-libpng-test]: ./libpng.md#_10-testing-and-conformance
[d-libspng]: ./libspng.md
[d-libspng-hostile]: ./libspng.md#_5-hostile-input-and-safety
[d-libspng-test]: ./libspng.md#_10-testing-and-conformance
[d-libtiff]: ./libtiff.md#how-it-works
[d-libvips-colour]: ./libvips.md#_3-colour-and-metadata
[d-libvips-image]: ./libvips.md#vipsimage-a-descriptor-that-may-have-no-pixels
[d-libvips-simd]: ./libvips.md#_7-cpu-parallelism-and-simd
[d-libwebp-api]: ./libwebp.md#the-public-decode-api
[d-libwebp-hostile]: ./libwebp.md#_5-hostile-input-and-safety
[d-libwebp-idec]: ./libwebp.md#the-incremental-state-machine
[d-libwebp-simd]: ./libwebp.md#_7-cpu-parallelism-and-simd
[d-mir-generic]: ./mir-algorithm/#_2-genericity-mechanism
[d-mir-simd]: ./mir-algorithm/#_7-cpu-parallelism-and-simd
[d-nvimagecodec]: ./nvimagecodec.md
[d-oiio-pixel]: ./openimageio.md#_1-pixel-and-memory-model
[d-oiio-simd]: ./openimageio.md#_7-cpu-parallelism-and-simd
[d-oiio-spec]: ./openimageio.md#typedesc-and-imagespec
[d-opencv]: ./opencv.md
[d-openexr-file]: ./openexr.md#file-structure
[d-openexr-hostile]: ./openexr.md#_5-hostile-input-and-safety
[d-openexr-pixel]: ./openexr.md#_1-pixel-and-memory-model
[d-sail]: ./sail.md
[d-simd]: ./simd.md
[d-skia]: ./skia.md
[d-skia-test]: ./skia.md#_10-testing-and-conformance
[d-stb]: ./stb-image.md
[d-stb-hostile]: ./stb-image.md#_5-hostile-input-and-safety
[d-stb-test]: ./stb-image.md#_10-testing-and-conformance
[d-tc-nvcomp]: ./tier-c-digest.md#nvcomp-and-gdeflate
[d-uring-gpu]: ./io-uring-storage.md#memory-a-gpu-can-see
[d-vigra-generic]: ./vigra.md#_2-genericity-mechanism
[d-vigra-par]: ./vigra.md#_7-cpu-parallelism-and-simd
[d-vk-cpu]: ./vulkan-transfer.md#_7-cpu-parallelism-and-simd
[d-vk-decomp]: ./vulkan-transfer.md#gpu-decompression-the-nv-and-ext-extensions
[d-vk-import]: ./vulkan-transfer.md#importing-memory-host-pointers-dma-buf-and-drm-modifiers
[d-vk-pixel]: ./vulkan-transfer.md#the-staging-path-vkcmdcopybuffertoimage
[d-vk-ycbcr]: ./vulkan-transfer.md#ycbcr-sampling
[d-wuffs-hostile]: ./wuffs.md#_5-hostile-input-and-safety
[d-wuffs-png]: ./wuffs.md#a-png-decode-end-to-end
[d-zune]: ./zune-image.md
[d-zune-generic]: ./zune-image.md#_2-genericity-mechanism
[d-zune-io]: ./zune-image.md#_4-i-o-and-codec-architecture
[d-zune-test]: ./zune-image.md#_10-testing-and-conformance
[d-ocio]: ./opencolorio.md#_7-cpu-parallelism-and-simd
