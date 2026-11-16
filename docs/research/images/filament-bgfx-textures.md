# Filament and bgfx texture pipelines (C++)

Two rendering engines that each embed a texture path from file to GPU: Filament (Google) splits it into an engine-side `Texture` object, offline tools that bake mips and KTX files, and a runtime KTX2 reader that transcodes Basis Universal to whatever block format the device has; bgfx (with its sibling `bimg`) takes a whole DDS, KTX or PVR file as the texture-creation argument, parses it inside the renderer, and decodes unsupported block formats to BGRA8 on the CPU.

| Field         | Value                                                                                                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++ (both); Filament also ships Java/Kotlin and JavaScript bindings                                                                                                                                                             |
| License       | Filament: Apache-2.0 ([`LICENSE`][f-license]); bgfx: BSD-2-Clause ([`LICENSE`][b-license]); `bimg` not read                                                                                                                     |
| Repository    | [google/filament][f-repo] · [bkaradzic/bgfx][b-repo] (and `bkaradzic/bimg`, not cloned)                                                                                                                                         |
| Revision read | Filament `4e2df5e24d745a332faacccd5dd10660f232e514` (October 26, 2026; blobless clone, read with `git show`) · bgfx `695330f32141739e79549d340f70bd44abd21266` (October 27, 2026)                                               |
| Documentation | Filament: in-tree headers and [`tools/mipgen/README.md`][f-mipgen-readme], [`tools/cmgen/README.md`][f-cmgen-readme] · bgfx: [API reference][b-api-docs], [`docs/tools.rst`][b-tools] (`texturec`), [`docs/build.rst`][b-build] |
| Category      | GPU and SIMD: engine texture APIs, offline mip and compression tools, container parsing, runtime transcoding                                                                                                                    |
| Tier          | B                                                                                                                                                                                                                               |
| Last reviewed | November 7, 2026                                                                                                                                                                                                                |

> [!NOTE]
> `bimg` is not cloned. What this page says about it comes from bgfx's documentation, its build
> scripts and the `bimg::` calls in bgfx's source at the pinned revision; the parsers themselves were
> not read. The one **demonstrated** claim (the `Ktx1Bundle` header allocation in
> [§5](#_5-hostile-input-and-safety)) was run on Filament's `libs/image/src/Ktx1Bundle.cpp`, extracted
> with `git show` and compiled with GCC against five stub headers in a scratch directory under `/tmp`.
> No performance number on this page was measured, and none is quoted.

## Overview

Both engines face the problem the [KTX-Software](./ktx-software.md) page describes from the container
side: a GPU texture has levels, layers, faces and often a [block-compressed format][c-block], and an
image file describes none of that. Each engine answers by owning the last mile itself.

Filament positions itself as mobile-first ([`README.md`][f-readme]):

> _"Filament is a real-time physically based rendering engine for Android, iOS, Linux, macOS,
> Windows, and WASM. It is designed to be as small as possible and as efficient as possible on
> Android."_

Size is why its image code is split. The engine core never decodes a file: `filament::Texture`
accepts pixels or pre-compressed blocks. Decoding lives in `libs/imageio` (PNG, HDR, PSD, EXR through
`libpng` and `tinyexr`), in `libs/ktxreader` (KTX1 and KTX2 through the Basis Universal transcoder),
and in `gltfio`'s texture providers (`stb_image`, WebP, KTX2). A further `imageio-lite` exists only to
avoid dependencies ([`libs/imageio-lite/README.md`][f-imageio-lite]):

> _"**No Third-Party Dependencies:** Unlike `imageio`, this library must NOT depend on external
> libraries like `libpng`, `tinyexr`, etc."_

bgfx describes itself as _"Cross-platform, graphics API agnostic, "Bring Your Own Engine/Framework"
style rendering library"_ ([`README.md`][b-readme]). Its texture API takes container bytes: the
documented argument of `createTexture` is _"DDS, KTX or PVR texture binary data"_
([`bgfx.h`][b-createtexture]). Image handling sits in a separate repository, `bimg`, built as three
libraries: `bimg` (containers, format tables, conversion), `bimg_decode` (file decoders) and
`bimg_encode` (block compressors), roles read from their names and from what bgfx calls, since
`bimg` itself was not read; bgfx itself links only `bimg` while `texturec` links all three ([`scripts/bgfx.lua`][b-lua],
[`scripts/texturec.lua`][b-texturec-lua]).

## How it works

### Filament: `Texture::Builder`, `setImage` and the format enum

A texture is declared, then filled level by level ([`Texture.h`][f-texture-h-doc]):

```cpp
filament::Texture* texture = filament::Texture::Builder()
            .width(64)
            .height(64)
            .build(*engine);
```

The builder takes `levels`, `sampler` (`SAMPLER_2D`, `SAMPLER_3D`, `SAMPLER_2D_ARRAY`,
`SAMPLER_CUBEMAP`, …), `format`, `usage`, `swizzle` and `import` for a native handle. The format is
`backend::TextureFormat`, 109 enumerants that follow Vulkan's convention of folding the transfer
function into the format: `RGBA8` and `SRGB8_A8`, `DXT5_RGBA` and `DXT5_SRGBA`, the ETC2/EAC family,
ASTC 4x4 to 12x12 in both encodings, BC4/BC5 as `RED_RGTC1`/`RED_GREEN_RGTC2`, BC6H and BC7 as the
`BPTC` names ([`DriverEnums.h`][f-textureformat]). `Texture::isTextureFormatSupported` and
`isTextureFormatMipmappable` ask the backend at run time ([`Texture.h`][f-texture-caps]).

Data arrives as a `PixelBufferDescriptor`: a pointer, a byte size, a release callback, a `left`/`top`
origin, a pixel `type` and a row `alignment`, plus a union whose two arms are the uncompressed
`stride` (in pixels) and `format`, or the compressed `imageSize` and `compressedFormat`
([`PixelBufferDescriptor.h`][f-pbd-union]). The callback is the ownership hand-off: `setImage` is
documented as _"The driver will invoke the callback associated with this buffer when the data has
been consumed"_ ([`Texture.h`][f-setimage]).

`generateMipmaps` is the runtime mip path; it _"requires the texture to have a color-renderable format
and usage set to BLIT_SRC | BLIT_DST"_, rejects 3D textures and non-mipmappable formats, and forwards
to the driver ([`Texture.h`][f-genmips-doc], [`Texture.cpp`][f-genmips]).

### Filament: offline tools

`mipgen` _"generates mipmaps for an image down to the 1x1 level"_ ([`README.md`][f-mipgen-readme]). It
decodes to `LinearImage`, a reference-counted float image whose _"row stride is simply width *
channels * sizeof(float)"_ ([`LinearImage.h`][f-linearimage]), resamples with one of nine filters
(`DEFAULT` picks Mitchell for magnification and Lanczos for minification;
[`ImageSampler.h`][f-filters]), and writes PNG, EXR, HDR, RGBM, PSD or DDS files, a KTX1 file of uncompressed levels, or
a KTX2 file through `BasisEncoder` with `--compression=uastc|etc1s|uastc_normals|etc1s_normals`
([`main.cpp`][f-mipgen-usage]). Each level is resampled from the source, not from the previous level
([`ImageSampler.cpp`][f-genmips-cpu]):

```cpp
// Unlike traditional mipmap generation, our implementation generates all levels from the original
// image, under the premise that this produces a higher quality result.
```

`cmgen` turns an HDR environment map into a prefiltered IBL cubemap and spherical harmonics; its KTX
output is _"always KTX1 files, not KTX2"_, _"encoded with 3-channel RGB_10_11_11_REV data"_
([`README.md`][f-cmgen-readme]). `Ktx1Bundle`, the in-memory KTX1 model the two tools write and the
runtime reads, is _"a structured set of opaque data blobs that can be passed straight to the GPU"_
([`Ktx1Bundle.h`][f-ktx1bundle-h]).

### Filament: runtime KTX2 transcoding

`ktxreader::Ktx2Reader` wraps `basist::ktx2_transcoder`. The client lists formats in priority order
with `requestFormat`; `load` picks the first one that the backend supports, whose transfer function
matches the caller's, and that Basis can transcode the file to
([`Ktx2Reader.cpp`][f-ktx2-resolve]), then transcodes and uploads every level
([`Ktx2Reader.cpp`][f-ktx2-load]). A table maps each Filament format to its Basis target; its comment
names the mismatch it bridges ([`Ktx2Reader.cpp`][f-ktx2-table]):

```cpp
// Note that Filament's internal format list mimics the Vulkan format list, which
// embeds transfer function information (i.e. sRGB or not) into the format, whereas
// the basis format list does not.
```

`gltfio`'s `Ktx2Provider` requests `ETC2_EAC_SRGBA8`, `DXT5_SRGBA`, `DXT5_RGBA` and the uncompressed
`SRGB8_A8`/`RGBA8` fallbacks, then runs `Async::doTranscoding` as a `JobSystem` job and uploads the
finished levels from the engine thread in `updateQueue` ([`Ktx2Provider.cpp`][f-ktx2provider-push],
[`Ktx2Provider.cpp`][f-ktx2provider-formats]). Cubemaps and arrays are refused: _"TODO: support
cubemaps. For now we use KTX1 for cubemaps because basisu does not support HDR."_
([`Ktx2Reader.cpp`][f-ktx2-nocube]).

For PNG and JPEG, `StbProvider` reads the header with `stbi_info_from_memory`, builds an `RGBA8` or
`SRGB8_A8` texture with `levels(0xff)`, decodes level 0 in a job and calls `generateMipmaps`
([`StbProvider.cpp`][f-stb-info], [`StbProvider.cpp`][f-stb-genmips]); the decoder itself is the
subject of [stb_image](./stb-image.md).

### bgfx: a texture is a container

Every bgfx creation path funnels into one parser. `createTexture(const Memory*)` hands a file to
`bimg::imageParse`; `createTexture2D(width, height, …, mem)` writes a private chunk (`kChunkMagicTex`
followed by a `TextureCreate` struct carrying the caller's `Memory`) and sends that through the same
path ([`bgfx.cpp`][b-create2d]). The API thread parses once to fill `TextureInfo`
([`bgfx_p.h`][b-p-create]); each renderer parses again on its own thread and walks the levels with
`bimg::imageGetRawData` ([`renderer_vk.cpp`][b-vk-create]):

```cpp
bimg::ImageContainer imageContainer;

if (bimg::imageParse(imageContainer, _mem->data, _mem->size) )
{
    const bimg::ImageBlockInfo& blockInfo = bimg::getBlockInfo(imageContainer.m_format);
    const uint8_t startLod = bx::min<uint8_t>(_skip, imageContainer.m_numMips - 1);
```

`_skip` drops top levels at parse time, a cheap quality knob. The format enum is `bimg`'s: bgfx's
`TextureFormat::Enum` (41 block formats including PVRTC and ATC, an `Unknown` sentinel, then
uncompressed and depth formats; [`bgfx.h`][b-textureformat]) is pinned to `bimg::TextureFormat` by
one `static_assert` per enumerant ([`bgfx.cpp`][b-static-assert]). sRGB is not in the format; it is
the flag `BGFX_TEXTURE_SRGB`, set from the container's `m_srgb` ([`bgfx_p.h`][b-p-srgb],
[`defines.h`][b-srgb-flag]).

At init bgfx marks every colour format (block-compressed or not, everything below `UnknownDepth`)
that the device lacks as `..._EMULATED` when `bimg::imageConvert` can turn it into BGRA8 ([`bgfx.cpp`][b-emulate]). `getViableTextureFormat` then substitutes BGRA8 (or a
depth format) and the renderer decodes each level with `bimg::imageDecodeToBgra8` into a temporary
before staging ([`bgfx.cpp`][b-viable], [`renderer_vk.cpp`][b-vk-decode]). Runtime mips exist only for
render targets, by blit chain on resolve with `BGFX_ATTACHMENT_AUTO_GEN_MIPS`
([`renderer_vk.cpp`][b-vk-automips]); sampled textures carry their levels in the file.

### bgfx: `texturec`

`texturec` (source in `bimg/tools/texturec`) converts _"PNG, TGA, DDS, KTX, and PVR textures into
bgfx-supported texture formats"_; its documented inputs also include AVIF, BMP, EXR, GIF, HDR, JPEG,
KTX2, PGM, PPM, PSD and WebP, and _"Which formats can be read depends on the image parsers compiled
into `bimg`"_ ([`tools.rst`][b-tools]). Options cover `-t` target format, `-m` mips, `--mipskip`,
`-n` normal map (implies `--linear`), `--equirect` and `--strip` cubemap inputs, `--sdf`, `--pma`,
`--max`, `--radiance` prefiltering, `--iqa` quality assessment and `--validate`, which reloads the
output and compares it. AVIF and HEIF decoding is an opt-in build (`--with-libheif`,
[`genie.lua`][b-genie-heif]).

## Analysis

### 1. Pixel and memory model

Both engines describe GPU-bound data, not CPU images. Filament's `PixelBufferDescriptor` has a
[stride][c-stride] in pixels, a row `alignment` packed into 4 bits and a `left`/`top` origin, but no
layer stride; the source carries `TODO: PBD should have a "layer stride"`
([`Texture.cpp`][f-setimage-checks]). Compressed uploads are whole blocks with no stride at all. bgfx
re-packs every level into a tightly aligned temporary (`alignment = 1`) before staging, block rows
for compressed formats and pixel rows otherwise ([`renderer_vk.cpp`][b-vk-decode]). Extents in bgfx's
public API are `uint16_t`, which caps a texture at 65535 texels per side by type.

The CPU side differs: Filament's tools work on float `LinearImage` with any channel count; bgfx's
`bimg::ImageContainer` keeps the file's own format and exposes levels as `ImageMip` views into the
source bytes.

### 2. Genericity mechanism

Neither engine is generic over pixel type. Formats are enum values with lookup tables
(`getBlockInfo`, `computeDataSize`, `getFormatSize`). bgfx's per-enumerant `static_assert` that two
libraries' enums agree is a cheap guard Sparkles could copy wherever a format enum is shared across
packages.

### 3. Colour and metadata

The only colour fact either engine carries is a one-bit [transfer function][c-transfer]. Filament
encodes it in the format and checks it against the KTX2 Data Format Descriptor: a file marked linear
loaded as sRGB, or the reverse, fails ([`Ktx2Reader.cpp`][f-ktx2-transfer]). bgfx keeps it as a flag.
No primaries, no [ICC profile][c-icc], no [CICP][c-cicp] and no [image metadata][c-metadata] reach
the texture, and neither engine converts colour at load. The one metadata field in sight is
`bimg::ImageContainer::m_orientation`, which bgfx's example loader hands back to its caller beside
the texture ([`bgfx_utils.cpp`][b-example-load]). Filament's `BasisEncoder::linear` documents
that the tag _"does not actually affect the compression process, it's basically just a hint to the
reader"_ ([`BasisEncoder.h`][f-basisenc-linear]).

The Filament format table also shows how a redundant field drifts. For the ETC2, BC1, BC3 and ASTC
4x4 entries, each of which has an sRGB twin, the `compressedPixelDataType` carried in the descriptor
is the opposite encoding of the texture's format (`ETC2_EAC_SRGBA8` is paired with
`tct::ETC2_EAC_RGBA8`, `DXT5_RGBA` with `tct::DXT5_SRGBA`); the BC7 pair and the single-encoding
BC4, BC5 and EAC entries match ([`Ktx2Reader.cpp`][f-ktx2-table]). It is harmless because the
OpenGL backend uploads with the texture's own internal format, not the descriptor's, and carries a
`TODO: maybe assert that the CompressedPixelDataType is the same as the internalFormat`
([`OpenGLDriver.cpp`][f-gl-compressed]); `VulkanDriver.cpp`, `VulkanTexture.cpp`, `MetalDriver.mm`,
`MetalHandles.mm`, `WebGPUDriver.cpp` and `WebGPUTexture.cpp` never read `compressedFormat` or
`imageSize`. The descriptor's tag is a second source of truth that nothing checks.

### 4. I/O and codec architecture

Both decode whole still-image files from memory; neither streams one (bgfx's video path, in
[§9](#_9-temporal-animation-and-containers), is the exception). Filament's split is by dependency: a
dependency-free core (`image`), a decoder library with third-party codecs (`imageio`), a
dependency-free alternative (`imageio-lite`), a GPU-container reader (`ktxreader`) and per-format
providers in `gltfio` behind a `TextureProvider` interface that _"constructs Filament Texture objects
synchronously, but populates their miplevels asynchronously"_ ([`TextureProvider.h`][f-provider]).
bgfx's split is `bimg` / `bimg_decode` / `bimg_encode`, and the renderer depends only on the first.
Filament's provider model creates the texture from header facts, then fills it; that separation of
"describe" from "fill" is the same one KTX2's level index makes possible
([KTX-Software](./ktx-software.md)).

### 5. Hostile input and safety

Filament validates the _upload_ thoroughly. `FTexture::setImageCommon` checks the region against the
level, the buffer against the region (last-pixel offset for uncompressed data, whole blocks for
compressed data), caps a single upload at `INT32_MAX` bytes because _"Vulkan stages each upload in a
buffer tracked in 32 bits"_, and guards an RGB-to-RGBA size multiply against wrap
([`Texture.cpp`][f-setimage-checks]). One comment records a bug fixed by promoting a debug-only
assert to a release check. `Ktx2Reader` checks its own size products for overflow before `malloc`
([`Ktx2Reader.cpp`][f-ktx2-transcode]).

`Ktx1Bundle` checks every offset against the buffer, but sizes its blob table from header fields
before reading any image data ([`Ktx1Bundle.cpp`][f-ktx1-header]): it accepts up to 2^32 blobs
(`numberOfMipmapLevels × numberOfArrayElements × faces`) and calls `sizes.resize` on a
`std::vector<uint32_t>`. **Demonstrated:** a 68-byte KTX1 file with 4096 mips and 4096 array
elements made the constructor allocate and zero 64 MiB (maximum resident set 69,072 KiB against
3,264 KiB for a valid one-level file; a GCC 16.2 rebuild measured 67,792 KiB against 2,760 KiB)
before rejecting it with _"KTX truncation during image sizes"_;
65535 × 65535 asked for about 16 GiB and threw `std::bad_alloc` under a 4 GB address-space limit.
The per-level loop that would reject the file runs only after that allocation. A
[hostile-input][c-hostile] parser bounds the declared work by the bytes present first.

bgfx, by contrast, checks that a `createTexture2D` buffer matches the computed storage size only
inside `BX_ENABLED(BGFX_CONFIG_DEBUG)` ([`bgfx.cpp`][b-create2d-check]); a release build relies on
`bimg` for the check, which this page did not read.

### 6. Allocation and ownership

Both engines own uploads through a release callback rather than a copy: Filament's
`PixelBufferDescriptor` callback, bgfx's `makeRef(data, size, releaseFn, userData)`, whose data
_"must be available for at least 2 `bgfx::frame` calls"_ ([`bgfx.h`][b-makeref]). bgfx's example
loader passes the parsed `ImageContainer` as the user data so the decoded image is freed when the
renderer is done ([`bgfx_utils.cpp`][b-example-load]). The renderer then allocates a second,
repacked copy per level. `Ktx2Reader::asyncCreate` copies the source file so the caller can free it.

### 7. CPU parallelism and SIMD

Parallelism is per texture, not per pixel. Filament's `Ktx2Provider` and `StbProvider` run one
`JobSystem` job per pushed texture; one transcoder per `Async` object, because Basis's
`transcode_image_level` is thread-safe but `start_transcoding` is not
([`Ktx2Reader.cpp`][f-ktx2-async]). Neither engine's texture path shows its own SIMD; the
transcoders and decoders are the [Basis Universal](./basis-universal.md) and third-party ones.

### 8. GPU offload and interop

The decisive design is **format negotiation at load**. Filament asks the client for an ordered
preference list and resolves it against `isTextureFormatSupported` and Basis's targets per file;
bgfx publishes per-format capability bits and silently falls back to CPU decode to BGRA8, so an ASTC
file still renders on a desktop GPU, at 32 bits per texel instead of the 0.89 to 8 its block formats use. Neither decompresses
on the GPU ([GPU decompression][c-gpudecomp]). Both have a native-handle import (Filament
`Builder::import`, `setExternalImage` with a plane index for biplanar camera frames; bgfx's
`_external`). Mip generation on the GPU is a blit chain (Filament's `generateMipmaps`, bgfx's
auto-gen on resolve); offline tools do the quality filtering on the CPU. The upload itself is a
[staged copy][c-staging], covered in [Vulkan transfer](./vulkan-transfer.md).

### 9. Temporal, animation and containers

Both engines treat arrays and cubemaps as layers or faces of one texture; neither has an animated
still-image model. bgfx alone has a temporal path: hardware video decode into a texture. A
`createTexture2D` buffer that starts with a `VideoDecoderInit` (codec `H264`, `H265` or `AV1`, plus
parameter sets) makes a decode-destination texture, and `updateTexture2D` then takes
`VideoDecoderFrame` batches of access units with microsecond presentation timestamps
([`bgfx.h`][b-video], [`bgfx.cpp`][b-create2d]); `src/video_{vk,d3d11,d3d12,mtl}.cpp` hold the
backends. This page did not read that path further.

### 10. Testing and conformance

Filament's image library uses golden PNGs: `updateOrCompare` compares a filter's output with
`libs/image/tests/reference/*.png` ([`test_image.cpp`][f-test-image]); `ktxreader` has one KTX1 and one
UASTC+Zstd KTX2 fixture, asserting dimensions and the resolved `DXT5_SRGBA` format
([`test_ktxreader.cpp`][f-test-ktx]). bgfx's texture path has no unit tests in-tree; `texturec
--validate` is the round-trip check.

## Lessons for Sparkles

- **Q6** Format negotiation belongs at load, against device capabilities: Filament's ordered
  `requestFormat` list resolved per file is the clean form; bgfx's silent CPU fallback hides a
  memory cost of four times or more. Sparkles' upload path is RGBA8 only today
  ([baseline G8](./baseline/existing-code.md)), so either model would be new.
- **Q6** Put the "describe, then fill" split in the API: create the GPU image from header facts,
  then fill levels from a worker as they finish (Filament's `Async::doTranscoding` and
  `uploadImages`). This fits `sparkles:event-horizon` offload pools without a new primitive.
- **Q5** A transfer-function bit in the format (Filament, Vulkan) and a flag beside it (bgfx) are
  both lossy; neither engine carries primaries or a profile. The texture layer can stay that small
  only if the image layer above it has converted colour first.
- **Q4** **Q8** Bound declared work by available bytes before allocating: Filament's `Ktx1Bundle`
  shows a parser that checks every offset and still asks for 16 GiB from a 68-byte header. A
  `sparkles:wired` description of a container should express "count × element size ≤ remaining
  bytes" as a constraint checked before any allocation.
- **Q1** A GPU upload descriptor needs row and layer strides and a block-row form; Filament's missing
  layer stride sits next to a recorded buffer over-read that a later check now prevents, and is still a `TODO`.
- **Q9** Both engines split image code by dependency weight: a dependency-free core, decoders with
  third-party libraries, encoders separately (`bimg`/`bimg_decode`/`bimg_encode`;
  `image`/`imageio`/`imageio-lite`). The renderer links only the core. This is evidence for an
  image-core / formats / tools split, with GPU containers (KTX) in the core-adjacent layer.
- **Q3** Filament resamples every level from the source rather than chaining; offline quality and
  runtime blit-chain speed are two different mip paths, and a Sparkles mip API may need both.
- **Q2** Where a format enum crosses a package boundary, bgfx's per-enumerant `static_assert` (or a
  D `static foreach` over members) keeps the two in step.

## Strengths

- Filament validates uploads in release builds, with explicit overflow reasoning in comments.
- Filament's KTX2 reader negotiates formats per file and transcodes off the engine thread.
- bgfx's single path (everything is a container) gives one parser, one level walker and `_skip`
  for free.
- bgfx's CPU emulation means any supported file format renders on any backend.
- Both separate dependency-heavy decoders and encoders from the renderer.

## Weaknesses

- Neither streams a still image: whole files in memory, whole textures uploaded.
- `Ktx1Bundle` allocates from untrusted header counts before checking them against the data.
- bgfx's buffer-size check for `createTexture2D` is debug-only, and every level is copied into a
  temporary before staging.
- Filament's `Ktx2Reader` rejects cubemaps and arrays; HDR cubemaps stay on KTX1.
- Colour is one transfer-function bit in both; no wide gamut or HDR metadata at the texture layer.
- Filament's compressed-type table pairs each sRGB/linear twin (BC7 aside) with the opposite
  encoding, unnoticed because no backend reads the field.

## Sources

- Filament at `4e2df5e24d745a332faacccd5dd10660f232e514`: `filament/include/filament/Texture.h`,
  `filament/src/details/Texture.cpp`, `filament/backend/include/backend/{DriverEnums,PixelBufferDescriptor}.h`,
  `filament/backend/src/opengl/OpenGLDriver.cpp`, `libs/image`, `libs/imageio`, `libs/imageio-lite`,
  `libs/ktxreader`, `libs/gltfio/src/{Ktx2Provider,StbProvider}.cpp`, `tools/mipgen`, `tools/cmgen`.
- bgfx at `695330f32141739e79549d340f70bd44abd21266`: `include/bgfx/{bgfx,defines}.h`,
  `src/bgfx.cpp`, `src/bgfx_p.h`, `src/renderer_vk.cpp`, `examples/common/bgfx_utils.cpp`,
  `docs/tools.rst`, `scripts/{bgfx,texturec,genie}.lua`.
- Related pages: [KTX-Software](./ktx-software.md), [Basis Universal](./basis-universal.md),
  [stb_image](./stb-image.md), [Vulkan transfer](./vulkan-transfer.md),
  [GPU texture compression papers][p-texture], [Concepts](./concepts.md).

<!-- References -->

[f-repo]: https://github.com/google/filament/tree/4e2df5e24d745a332faacccd5dd10660f232e514
[f-license]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/LICENSE
[f-readme]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/README.md#L10-L11
[f-imageio-lite]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/imageio-lite/README.md#L5-L12
[f-texture-h-doc]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/include/filament/Texture.h#L46-L73
[f-texture-caps]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/include/filament/Texture.h#L96-L103
[f-setimage]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/include/filament/Texture.h#L410-L436
[f-genmips-doc]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/include/filament/Texture.h#L698-L709
[f-textureformat]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/backend/include/backend/DriverEnums.h#L1067-L1160
[f-pbd-union]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/backend/include/backend/PixelBufferDescriptor.h#L302-L323
[f-setimage-checks]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/src/details/Texture.cpp#L451-L622
[f-genmips]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/src/details/Texture.cpp#L762-L786
[f-gl-compressed]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/filament/backend/src/opengl/OpenGLDriver.cpp#L3697-L3731
[f-mipgen-readme]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/tools/mipgen/README.md
[f-mipgen-usage]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/tools/mipgen/src/main.cpp#L62-L110
[f-cmgen-readme]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/tools/cmgen/README.md
[f-linearimage]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/image/include/image/LinearImage.h#L30-L44
[f-filters]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/image/include/image/ImageSampler.h#L38-L48
[f-genmips-cpu]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/image/src/ImageSampler.cpp#L337-L349
[f-ktx1bundle-h]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/image/include/image/Ktx1Bundle.h#L51-L66
[f-ktx1-header]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/image/src/Ktx1Bundle.cpp#L127-L228
[f-basisenc-linear]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/imageio/include/imageio/BasisEncoder.h#L59-L70
[f-ktx2-table]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L53-L109
[f-ktx2-transcode]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L116-L181
[f-ktx2-async]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L185-L216
[f-ktx2-load]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L252-L284
[f-ktx2-transfer]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L357-L373
[f-ktx2-nocube]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L375-L389
[f-ktx2-resolve]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/src/Ktx2Reader.cpp#L391-L432
[f-ktx2provider-push]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/gltfio/src/Ktx2Provider.cpp#L89-L127
[f-ktx2provider-formats]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/gltfio/src/Ktx2Provider.cpp#L233-L249
[f-stb-info]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/gltfio/src/StbProvider.cpp#L92-L103
[f-stb-genmips]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/gltfio/src/StbProvider.cpp#L185-L194
[f-provider]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/gltfio/include/gltfio/TextureProvider.h#L34-L40
[f-test-image]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/image/tests/test_image.cpp#L74-L107
[f-test-ktx]: https://github.com/google/filament/blob/4e2df5e24d745a332faacccd5dd10660f232e514/libs/ktxreader/tests/test_ktxreader.cpp#L52-L90
[b-repo]: https://github.com/bkaradzic/bgfx/tree/695330f32141739e79549d340f70bd44abd21266
[b-license]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/LICENSE
[b-readme]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/README.md#L40-L41
[b-api-docs]: https://bkaradzic.github.io/bgfx/bgfx.html
[b-build]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/docs/build.rst#L8-L16
[b-tools]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/docs/tools.rst#L231-L296
[b-lua]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/scripts/bgfx.lua#L40-L49
[b-texturec-lua]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/scripts/texturec.lua#L11-L23
[b-genie-heif]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/scripts/genie.lua#L48-L51
[b-textureformat]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/include/bgfx/bgfx.h#L176-L289
[b-createtexture]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/include/bgfx/bgfx.h#L3429-L3445
[b-video]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/include/bgfx/bgfx.h#L989-L1051
[b-makeref]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/include/bgfx/bgfx.h#L2715-L2727
[b-srgb-flag]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/include/bgfx/defines.h#L292
[b-viable]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx.cpp#L2280-L2328
[b-emulate]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx.cpp#L2642-L2656
[b-create2d]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx.cpp#L6637-L6772
[b-create2d-check]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx.cpp#L6735-L6746
[b-static-assert]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx.cpp#L7693-L7799
[b-p-create]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx_p.h#L7646-L7686
[b-p-srgb]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/bgfx_p.h#L7688
[b-vk-create]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/renderer_vk.cpp#L7996-L8031
[b-vk-decode]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/renderer_vk.cpp#L8126-L8230
[b-vk-automips]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/src/renderer_vk.cpp#L8579-L8633
[b-example-load]: https://github.com/bkaradzic/bgfx/blob/695330f32141739e79549d340f70bd44abd21266/examples/common/bgfx_utils.cpp#L186-L200
[c-block]: ./concepts.md#block-compressed-formats-and-supercompression
[c-stride]: ./concepts.md#stride
[c-transfer]: ./concepts.md#transfer-function
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-metadata]: ./concepts.md#image-metadata
[c-hostile]: ./concepts.md#hostile-input
[c-gpudecomp]: ./concepts.md#gpu-decompression
[c-staging]: ./concepts.md#staging-and-upload
[p-texture]: ./papers/gpu-texture-compression.md
