# Godot texture import (C++)

Godot's image stack seen from the engine side: one `Image` class that owns a byte vector, a format enum mixing raw and GPU block formats, and a table of function pointers that codec and compressor modules fill in; an editor-time importer that turns a source file into a `.ctex` per GPU format family; and a run-time loader that reads that file back and hands an `Image` to the renderer.

| Field         | Value                                                                                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++ (engine); bundled C and C++ libraries under `thirdparty/`                                                                                                             |
| License       | MIT ([`LICENSE.txt`][license]); bundled codecs and compressors carry their own licences, listed with their pinned versions in [`thirdparty/README.md`][thirdparty]        |
| Repository    | [godotengine/godot][repo]                                                                                                                                                 |
| Revision read | `944a3c6cbbbb88284feebcb0603464cb175fa18e` (August 18, 2026, a merge on `master`)                                                                                         |
| Documentation | In-tree class reference [`doc/classes/Image.xml`][doc-image] and [`doc/classes/ResourceImporterTexture.xml`][doc-importer]; manual page [Importing images][manual-import] |
| Category      | Consumers: game-engine asset pipeline (decode, mipmap, block-compress, serialize, upload)                                                                                 |
| Tier          | B                                                                                                                                                                         |
| Last reviewed | November 7, 2026                                                                                                                                                          |

> [!NOTE]
> Every quote was read with `git show 944a3c6cb:<path>` and every cited path checked with
> `git cat-file -e`. Claims marked **verified** were run against Godot 4.5.1 (`godot_4` from
> nixpkgs, headless, GDScript probes) in `/tmp/godot-probe`, not against a build of the pinned
> revision. 4.5.1 (`f62fdbde1`) is not an ancestor of the pin, but `git diff f62fdbde1 944a3c6cb`
> shows no change to `modules/hdr/image_loader_hdr.cpp` or to `png_to_image`, and the `int`
> size checks in `core/io/image.cpp` read the same in both.
> No performance number appears on this page.

---

## Overview

### What it solves

A game engine needs images in two shapes. At edit time it reads whatever an artist saved (PNG,
JPEG, WebP, SVG, TGA, BMP, Radiance HDR, OpenEXR, KTX, DDS), generates mipmaps and compresses to
the [block formats][c-block] each GPU family samples directly. At run time it must get those
blocks into video memory with as little work as possible. Godot does both with one class. Its
header comment states the double role ([`core/io/image.h`][image-h-head]):

> _"Image storage class. This is used to store an image in user memory, as well as providing some
> basic methods for image manipulation. Images can be loaded from a file, or registered into the
> Render object as textures."_

The importer's documentation frames the whole pipeline as a choice between five storage modes,
each a trade of quality, memory and import time ([`ResourceImporterTexture.xml`][doc-modes]):

> _"Lossless: Original quality, high memory usage, high size on disk, fast import."_ …
> _"Basis Universal: Reduced quality, low memory usage, lowest size on disk, slow import. Only use
> for textures in 3D scenes, not for 2D elements."_

### Design philosophy

- **One concrete type, no genericity.** `Image` is a reference-counted `Resource` with five
  fields; every format is a value of one enum, and every operation switches on it.
- **Plug-ins by function pointer.** Codecs, packers and block compressors are static function
  pointers on `Image` that modules assign at start-up, so a build without a module simply leaves
  the pointer `nullptr` and the operation fails with `ERR_UNAVAILABLE`.
- **Decide at import, not at load.** The editor writes one `.ctex` per GPU format family, and the
  exported game picks the variant its platform supports; the run-time path only decodes PNG,
  WebP or Basis payloads, or copies raw blocks.
- **The GPU is the limit.** The reference says plainly that _"The maximum image size is
  16384×16384 pixels due to graphics hardware limitations"_ ([`Image.xml`][doc-image-notes]).

## How it works

### The `Image` class

The private state is a format, a byte vector, two dimensions and a flag
([`image.h`][image-h-fields]):

```cpp
// core/io/image.h (excerpt)
Format format = FORMAT_L8;
Vector<uint8_t> data;
int width = 0;
int height = 0;
bool mipmaps = false;
```

The mip chain lives in the same `data` vector, level after level, and
`_get_dst_image_size` walks it, rounding each level up to the format's block size
([`image.cpp`][image-dst-size]). There is no stride: rows are tightly packed. `Format`
([`image.h`][image-h-format]) has 49 formats before `FORMAT_MAX`: 8-bit `L8`, `LA8`, `R8` … `RGBA8`; packed
`RGBA4444` and `RGB565`; 32-bit float `RF` … `RGBAF`; half float `RH` … `RGBAH`; shared-exponent
`RGBE9995`; 16-bit unsigned-normalised and integer `R16` … `RGBA16I`; and the block formats
`DXT1`/`DXT3`/`DXT5` (BC1–BC3), `RGTC_R`/`RGTC_RG` (BC4/BC5), `BPTC_RGBA` (BC7), `BPTC_RGBF`/`BPTC_RGBFU`
(BC6H), ETC1, seven ETC2 variants, ASTC 4×4, 6×6 and 8×8 (LDR and HDR), plus two swizzled
normal-map forms, `ETC2_RA_AS_RG` and `DXT5_RA_AS_RG`. The size constants are
([`image.h`][image-h-limits]):

```cpp
MAX_WIDTH = (1 << 24), // Force a limit somehow.
MAX_HEIGHT = (1 << 24), // Force a limit somehow.
MAX_PIXELS = 268435456 // 16384 ^ 2
```

Pixel-level operations (`get_pixel`, `resize`, `blend_rect`, `generate_mipmaps`) work on raw
formats only; the reference warns that _"Methods that modify the image data cannot be used on
VRAM-compressed images"_ ([`Image.xml`][doc-image-notes]).

### Codecs and compressors as function pointers

`Image` declares five groups of static pointers: savers (`save_png_func`, `save_webp_func`, …),
memory loaders (`_png_mem_loader_func`, `_jpg_mem_loader_func`, `_ktx_mem_loader_func`, …),
VRAM compressors, VRAM decompressors, and the packers and unpackers used inside `.ctex`
([`image.h`][image-h-ptrs]):

```cpp
// core/io/image.h (excerpt)
static void (*_image_compress_bc_func)(Image *, UsedChannels p_channels);
static void (*_image_compress_bptc_func)(Image *, UsedChannels p_channels, BPTCFormat p_bptc_format);
static void (*_image_compress_etc2_func)(Image *, UsedChannels p_channels);
static void (*_image_compress_astc_func)(Image *, UsedChannels p_channels, CompressProfile p_profile);
...
static Vector<uint8_t> (*basis_universal_packer)(const Ref<Image> &p_image, UsedChannels p_channels, const BasisUniversalPackerParams &p_basisu_params);
static Ref<Image> (*basis_universal_unpacker)(const Vector<uint8_t> &p_buffer);
```

Each module fills its slots: `etcpak` provides ETC1, ETC2, BC1, BC3, BC4 and BC5 encoding (no BC2; behind
`ETCPAK_COMPRESS_ENABLED`) and ETC decoding ([`etcpak/register_types.cpp`][reg-etcpak]); `astcenc`
encodes ASTC only under `TOOLS_ENABLED` but always decodes ([`astcenc/register_types.cpp`][reg-astcenc]);
`cvtt` encodes BC6H/BC7 and is built only for the editor unless `cvtt_export_templates` is set
([`cvtt/config.py`][cfg-cvtt]); `bcdec` decodes BC; `basis_universal` packs only in the editor
and unpacks everywhere ([`basis_universal/register_types.cpp`][reg-basisu]). `betsy` is the GPU
path: it registers `_image_compress_bc_rd_func` and `_image_compress_bptc_rd_func`
([`betsy/register_types.cpp`][reg-betsy]), compute shaders run through a private
`RenderingDevice` ([`image_compress_betsy.h`][betsy-h]). `Image::_compress_from_channels` tries
the GPU first when the project setting asks, and falls back to the CPU encoder on failure
([`image.cpp`][image-compress]):

```cpp
// core/io/image.cpp (excerpt)
if (GLOBAL_GET("rendering/textures/vram_compression/compress_with_gpu")) {
    switch (p_mode) {
        case COMPRESS_BPTC: {
            // BC7 is unsupported currently.
            if ((format >= FORMAT_RF && format <= FORMAT_RGBE9995) && _image_compress_bptc_rd_func) {
```

File loaders are a second, object-oriented layer: `ImageFormatLoader` with a virtual
`load_image(Ref<Image>, Ref<FileAccess>, flags, scale)` and `get_recognized_extensions`
([`image_loader.h`][loader-h]). `ImageLoader::load_image` picks loaders **by file extension**, not
by content, and tries the next one only on `ERR_FILE_UNRECOGNIZED`
([`image_loader.cpp`][loader-cpp]). The two flags are `FLAG_FORCE_LINEAR` and
`FLAG_CONVERT_COLORS`; scripts can add loaders through `ImageFormatLoaderExtension`.

### The importer: `ResourceImporterTexture`

The import options ([`resource_importer_texture.cpp`][imp-options]) include `compress/mode`
(`Lossless`, `Lossy`, `VRAM Compressed`, `VRAM Uncompressed`, `Basis Universal`),
`compress/high_quality`, `compress/hdr_compression`, `compress/normal_map`,
`compress/channel_pack`, `mipmaps/generate` and `mipmaps/limit`, `roughness/mode`,
`process/channel_remap/*`, `process/fix_alpha_border`, `process/premult_alpha`,
`process/hdr_as_srgb`, `process/size_limit` and `detect_3d/compress_to`, beside Basis
(`compress/uastc_level`, `compress/rdo_quality_loss`), lossy, SVG and editor-icon options. For `VRAM Compressed`,
`import` writes one file per family and reports each as a platform variant
([`resource_importer_texture.cpp`][imp-vram]):

```cpp
// editor/import/resource_importer_texture.cpp (excerpt)
// Must import in desktop and mobile formats in order of priority, so platform chooses the best supported one (e.g. s3tc over etc2 on desktop).
```

Desktop gets BC1/BC3 (`s3tc`), or BC7/BC6H (`bptc`) when `high_quality` is set or the source is
HDR; mobile gets ETC2 (`etc2`), or ASTC (`astc`) under the same conditions. HDR with alpha cannot
be block-compressed, so unless the user forces it (by dropping alpha) the importer converts to
`RGBE9995` and stores it uncompressed; it does the same for any HDR source when
`compress/hdr_compression` is disabled. Before compression `_save_ctex` resizes to a power of two when asked, generates
mipmaps (renormalising for normal maps), folds normal-map variance into roughness mipmaps
(`generate_mipmap_roughness`), and calls `detect_used_channels` so a greyscale or two-channel image
gets a one- or two-channel block format ([`resource_importer_texture.cpp`][imp-save-ctex]).

### The `.ctex` format

`_save_ctex` writes a fixed header, then `save_to_ctex_format` writes an inner image header and
the payload ([`resource_importer_texture.cpp`][imp-ctex-format]). The loader side is
`CompressedTexture2D::_load_data` and `load_image_from_file`
([`compressed_texture.cpp`][ctex-load-data], [`compressed_texture.cpp`][ctex-load-image]):

| Offset | Field                                                                                      | Written by       |
| ------ | ------------------------------------------------------------------------------------------ | ---------------- |
| 0      | magic `GST2` ("Godot Streamable Texture 2D")                                               | `store_8` ×4     |
| 4      | `FORMAT_VERSION` (1)                                                                       | `store_32`       |
| 8, 12  | original width, height                                                                     | `store_32`       |
| 16     | flags: `FORMAT_BIT_STREAM`, `HAS_MIPMAPS`, `DETECT_3D`, `DETECT_NORMAL`, `DETECT_ROUGNESS` | `store_32`       |
| 20     | mipmap limit                                                                               | `store_32`       |
| 24–35  | three reserved words                                                                       | `store_32(0)` ×3 |
| 36     | `DataFormat`: `IMAGE`, `PNG`, `WEBP`, `BASIS_UNIVERSAL`                                    | `store_32`       |
| 40, 42 | width, height of the stored image                                                          | `store_16`       |
| 44, 48 | mipmap count, `Image::Format`                                                              | `store_32`       |
| 52     | payload                                                                                    | see below        |

`PNG` and `WEBP` store each mip level as its own length-prefixed file; `BASIS_UNIVERSAL` stores
one length-prefixed `.basis` blob; `IMAGE` stores `Image::get_data()` raw, which for a block
format is the block stream ready for upload. The flag bits start at bit 22 and the
"detect" bits are editor callbacks: on first use in 3D, as a normal map or with a roughness
texture, the editor reimports the texture with new settings
([`compressed_texture.h`][ctex-h]).

### Run-time loading

`CompressedTexture2D::load` reads the image and passes it straight to the rendering server
([`compressed_texture.cpp`][ctex-load]):

```cpp
// scene/resources/compressed_texture.cpp (excerpt)
RETURN_IF_ERROR(_load_data(p_path, lw, lh, image, request_3d, request_normal, request_roughness, mipmap_limit));

if (texture.is_valid()) {
    RID new_texture = RS::get_singleton()->texture_2d_create(image);
```

The whole file passes through an `Image` in CPU memory; there is no direct file-to-GPU path. A
Basis payload is transcoded at load to whichever format the device reports through
`has_os_feature` (`bptc`, `astc`, `rgtc`, `s3tc`, `etc2`, `astc_hdr`), falling back to `RGBA8`
([`image_compress_basisu.cpp`][basisu-unpack]); the KTX2 loader makes the same choice for
Basis-supercompressed KTX2 files but transcodes sRGB-tagged ones to `RGBA32` with the comment
`// TODO srgb native support` ([`texture_loader_ktx.cpp`][ktx-srgb]).
`PortableCompressedTexture2D` offers the same modes for textures built at run time
(`COMPRESSION_MODE_LOSSLESS` … `COMPRESSION_MODE_ASTC`, [`portable_compressed_texture.h`][portable-h]).

## Analysis

### 1. Pixel and memory model

One buffer, one format value, a boolean "has mipmaps" and no stride, views, planes or
array layers: layered and 3D textures are `Vector<Ref<Image>>` validated by `validate_3d_image`.
What Godot adds that the codec libraries lack is a **block-format-aware size model**:
`_get_dst_image_size`, `get_format_block_size` and `get_format_pixels_shifted` give each level's
byte size for raw and compressed formats alike, which is what a GPU upload needs
(compare [KTX-Software][ktx-doc] and the [block formats concept][c-block]). The model is an
engine's, not a library's: no sub-image views, no YCbCr, no planar data.

### 2. Genericity mechanism

None at compile time. `Image` is one non-template class; the element type is the run-time
`Format` value, and each operation switches on it or calls `get_format_pixel_size` and
`get_format_block_size`. Optional behaviour is the run-time function-pointer table described in
[Codecs and compressors as function pointers](#codecs-and-compressors-as-function-pointers),
and file loaders are virtual `ImageFormatLoader` subclasses. Templates appear only inside
`image.cpp` helpers such as `_generate_po2_mipmap`, instantiated per component type.

### 3. Colour and metadata

`Image` has no colour field. Whether a texture is sRGB is a property of how a shader samples it,
so loaders carry at most a `FLAG_FORCE_LINEAR` switch: the HDR, EXR and SVG loaders apply
`srgb_to_linear` when it is set. The PNG loader drops 16-bit precision, applies no
[ICC][c-icc] profile and leaves gamma handling to libpng's simplified API: it masks out
`PNG_FORMAT_FLAG_LINEAR` and, unless `FLAG_FORCE_LINEAR` is set, sets `PNG_IMAGE_FLAG_16BIT_sRGB`
([`png_driver_common.cpp`][png-driver]). **Verified:** a
4×4 16-bit RGB PNG loads as `FORMAT_RGB8` (format 4). The JPEG loader refuses precision above 8
and CMYK/YCCK ([`image_loader_libjpeg_turbo.cpp`][jpg-loader]) and reads no EXIF orientation.
No loader reads [image metadata][c-meta] or [CICP][c-cicp]. HDR is a format question
(`RGBAH`, `RGBE9995`, BC6H, ASTC HDR), not a colour-model question.

### 4. I/O and codec architecture

Every loader is synchronous and returns a finished `Image`. Most read the whole file into a
`Vector<uint8_t>` first: the JPEG loader's `load_image` calls `f->get_length()` and `get_buffer`
before decoding ([`image_loader_libjpeg_turbo.cpp`][jpg-loader]), and the PNG loader does the same.
The Radiance HDR loader instead reads scanlines byte by byte from the `FileAccess`
([`image_loader_hdr.cpp`][hdr-loader]), still into one whole-image buffer.
There is no incremental or suspendable decode ([push and pull][c-pushpull]). The architecture
lesson is the split: format selection, mipmap generation and block compression happen once,
offline, and the shipped [container][c-container] is engine-private (`.ctex`) with a payload
that is either another codec's file or raw upload-ready blocks.

### 5. Hostile input and safety

Godot treats imported files as trusted project assets, and the run-time `Image.load` API reaches
the same code. Three findings, all **verified** on Godot 4.5.1:

- **Allocation at the declared size.** `png_to_image` sizes its buffer from the header with
  `PNG_IMAGE_BUFFER_SIZE` before reading pixels ([`png_driver_common.cpp`][png-driver]). A
  69-byte PNG declaring 30000×30000 RGBA produced a 4,294,971,392-byte anonymous `mmap`
  (observed with `strace`) before libpng reported "Not enough image data". libpng's own limits
  are covered in the [libpng deep-dive][libpng-doc].
- **`int` overflow in the size check.** `initialize_data` tests `p_width * p_height > MAX_PIXELS`
  in `int`, and `_get_dst_image_size` computes `bw * bh` in `int` before widening
  ([`image.cpp`][image-init], [`image.cpp`][image-dst-size]). `Image.create(16385, 16385, …)` is
  rejected, but `Image.create(65536, 65536, false, FORMAT_L8)` returns a 65536×65536 image with
  `get_data_size() == 0`, and 65536×65537 gives 65,536 bytes. On that image `get_pixel(0, 1)`
  returned a value from past the buffer and `get_pixel(0, 60000)` killed the process with
  signal 11.
- **Unclamped RLE runs in the Radiance HDR loader.** The run loop checks `i < width` only before
  each run, then writes `count` pixels ([`image_loader_hdr.cpp`][hdr-loader]). An 8×1 `.hdr`
  whose first run has length 127 returned `OK` from `load` and then aborted the process with a
  glibc heap-corruption check (exit 134; the message depends on heap layout, and two runs gave
  "corrupted size vs. prev_size" and "malloc(): unaligned tcache chunk detected"). The dump branch
  has the same shape, and the buffer size `height * width * (int)sizeof(uint32_t)` is itself an
  `int` product (read from source, not exercised).

There is no fuzzing harness in the tree (outside `thirdparty/`, a search for `fuzz` finds only
`FuzzySearch`, PO "fuzzy" translation flags and the changelog). Compare
[Wuffs][wuffs-doc] and the [hostile-input concept][c-hostile].

### 6. Allocation and ownership

`Vector<uint8_t>` is copy-on-write, so `Image::duplicate`, `get_data` and passing images by
`Ref` share storage until a write. Every transform (`convert`, `resize`, `compress`) replaces
`data` in place on the object, and the importer calls `duplicate()` before each per-family
compression so one decoded source feeds several `.ctex` files. Nothing lets a caller supply the
destination buffer.

### 7. CPU parallelism and SIMD

`Image` itself has no threading or SIMD code. Parallelism sits at two other levels: the
importer declares `can_import_threaded()` as `true` ([`resource_importer_texture.h`][imp-h]), so
the editor imports several textures at once, and the `cvtt` BC6H/BC7 encoder splits rows into
tasks on the engine's `WorkerThreadPool` ([`image_compress_cvtt.cpp`][cvtt-pool]). Any SIMD lives
inside the bundled third-party encoders and decoders, which this page does not read.

### 8. GPU offload and interop

Two lessons. First, GPU block compression (`betsy`: BC1, BC4 and BC6H compute shaders plus an alpha-stitch pass) is
an optional accelerator behind the same function-pointer slot as the CPU encoder, with CPU
fallback on any error; the comment notes BC7 is not implemented on the GPU. Second, run-time
format choice is a capability query (`has_os_feature("astc")` and so on) feeding a transcoder,
which is the [Basis Universal][basisu-doc] model. Upload goes through `RenderingServer` from a
CPU `Image`; see [Vulkan transfer][vk-doc] for what a direct path would add.

### 9. Temporal, animation and containers

No animation: GIF and animated WebP are not imported as textures. The relevant container idea
is the platform variant: one source, several `.ctex` files named by suffix (`.s3tc.ctex`,
`.etc2.ctex`, …), with the variant chosen at export time.

### 10. Testing and conformance

`tests/core/io/test_image.cpp` saves a 4×4 `RGBA8` image as PNG (and EXR and JPEG), reloads the
PNG and compares bytes, checks that `icon` fixtures in BMP, EXR, JPEG, SVG, WebP, PNG and TGA load
without error, and checks instantiation, resizing, pixel access, custom mipmaps and conversion
([`test_image.cpp`][test-image]). There is no conformance corpus, no differential oracle and no
fuzzing; compression quality is measured ad hoc through `Image::compute_image_metrics`.

## Lessons for Sparkles

- **Q1:** A GPU-facing image type needs a block-aware size model (block dimensions, bytes per
  block, per-level offsets) even if its pixel API never touches compressed data. Godot's
  `get_image_mipmap_offset_and_dimensions` is that model in one function; it does not need
  Godot's lack of strides or views.
- **Q2:** Function-pointer slots filled at start-up give optional codecs without templates;
  in D, version-gated sub-packages or a registry keyed by format serve the same purpose with
  compile-time checking. Godot's slot design hides missing modules until a call fails.
- **Q4:** Separate the offline pipeline (decode, mipmap, compress, write an engine container)
  from the run-time one (read, maybe transcode, upload). Extension-based loader dispatch is the
  wrong default for untrusted input; content sniffing is cheap.
- **Q5:** An engine can ship with no colour model because the shader decides sRGB. A general
  library cannot: Godot's dropped ICC, EXIF orientation and 16-bit PNG precision are the gaps
  a viewer would hit first.
- **Q6:** `.ctex` shows the minimum a file-to-GPU container records: format, extent, mip count,
  then upload-ready bytes. KTX2 records more (level index, DFD, supercompression) and is the
  standard alternative.
- **Q7:** GPU compression as an optional accelerator with CPU fallback, sharing one entry point,
  is a concrete pattern for the SIMD-versus-GPU question.
- **Q8:** All three hostile-input findings above come from arithmetic in `int` and from trusting
  a declared size; overflow-checked size computation and a corpus of crafted headers would have
  caught each. They are cheap regression inputs for a Sparkles oracle.
- **Q9:** Godot keeps image core, codecs and compressors in separate modules joined through one
  class; the split exists, but the class depends on all of them by name.

## Strengths

- One type covers raw, float, half, shared-exponent, 16-bit and every major GPU block format,
  with correct per-level size arithmetic.
- Platform variants let one import serve desktop and mobile without run-time recompression.
- GPU compression with CPU fallback, and run-time Basis transcoding to the best supported format.
- Small, documented import options mapped directly onto engine needs (normal maps, roughness,
  channel packing, HDR policy).

## Weaknesses

- No stride, view or plane model; layered images are vectors of `Image`.
- No colour metadata; 16-bit PNG and high-precision JPEG are reduced or refused.
- Size checks computed in `int` overflow; loaders allocate at the declared size; the HDR RLE
  decoder writes past its buffer (all verified on 4.5.1).
- Extension-based loader dispatch; whole-file, synchronous decoding only.
- No fuzzing or conformance corpus.
- The `.ctex` inner header stores dimensions with `store_16` while `Image` allows up to
  2^24; the run-time size-limit branches for `PNG`/`WEBP` and for `IMAGE` compare in opposite
  directions (`sw > p_size_limit` against `p_size_limit > tw`). Both read from source; neither was
  exercised.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                             | Trade-off                                                                     |
| -------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| One `Image` class with a run-time `Format` enum    | One type serves scripts, importer and renderer; GPU block formats fit beside raw ones | No strides, views or planes; every operation switches on the format           |
| Codecs and compressors as static function pointers | Modules are optional per build; export templates drop editor-only encoders            | A missing module shows up only as `ERR_UNAVAILABLE` at the call               |
| Compress at import, one `.ctex` per GPU family     | No run-time encoding; the platform picks the variant it supports                      | Several files per texture; format choice is fixed at export                   |
| GPU compression (`betsy`) behind the CPU slot      | Offloads encoding when a `RenderingDevice` is available                               | Partial coverage (no BC7 on the GPU); two encoders per format to maintain     |
| Size checks in `int`, buffers at declared size     | Simple code for trusted project assets                                                | Overflow and huge allocations from crafted files reached through `Image.load` |

## Sources

- Source at `944a3c6cbbbb88284feebcb0603464cb175fa18e`: `core/io/image.h`, `core/io/image.cpp`,
  `core/io/image_loader.{h,cpp}`, `editor/import/resource_importer_texture.cpp`,
  `scene/resources/compressed_texture.{h,cpp}`, `scene/resources/portable_compressed_texture.h`,
  `drivers/png/png_driver_common.cpp`, the loaders and compressors under `modules/`, and
  `tests/core/io/test_image.cpp`.
- Class reference: [`Image.xml`][doc-image], [`ResourceImporterTexture.xml`][doc-importer].
- Related deep-dives: [KTX-Software][ktx-doc], [Basis Universal][basisu-doc], [libpng][libpng-doc],
  [libjpeg-turbo][libjpeg-doc], [libwebp][libwebp-doc], [OpenEXR][openexr-doc], [Wuffs][wuffs-doc],
  [Vulkan transfer][vk-doc]; paper thread [GPU texture compression][p-texture].
- Probes: Godot 4.5.1 (nixpkgs `godot_4`), headless GDScript, `strace`, in `/tmp/godot-probe`.

<!-- References -->

[repo]: https://github.com/godotengine/godot/tree/944a3c6cbbbb88284feebcb0603464cb175fa18e
[license]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/LICENSE.txt
[thirdparty]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/thirdparty/README.md
[doc-image]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/doc/classes/Image.xml
[doc-image-notes]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/doc/classes/Image.xml#L9-L10
[doc-importer]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/doc/classes/ResourceImporterTexture.xml
[doc-modes]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/doc/classes/ResourceImporterTexture.xml#L41-L49
[manual-import]: https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html
[image-h-head]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.h#L36-L40
[image-h-limits]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.h#L68-L72
[image-h-format]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.h#L74-L125
[image-h-ptrs]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.h#L216-L271
[image-h-fields]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.h#L288-L292
[image-dst-size]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.cpp#L1924-L1985
[image-init]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.cpp#L2426-L2450
[image-compress]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image.cpp#L2983-L3043
[loader-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image_loader.h#L41-L63
[loader-cpp]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/core/io/image_loader.cpp#L83-L111
[imp-options]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/import/resource_importer_texture.cpp#L236-L273
[imp-ctex-format]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/import/resource_importer_texture.cpp#L277-L355
[imp-save-ctex]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/import/resource_importer_texture.cpp#L357-L438
[imp-vram]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/import/resource_importer_texture.cpp#L891-L968
[ctex-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/scene/resources/compressed_texture.h#L42-L60
[ctex-load-data]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/scene/resources/compressed_texture.cpp#L39-L93
[ctex-load]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/scene/resources/compressed_texture.cpp#L141-L148
[ctex-load-image]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/scene/resources/compressed_texture.cpp#L297-L450
[portable-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/scene/resources/portable_compressed_texture.h#L49-L58
[png-driver]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/drivers/png/png_driver_common.cpp#L62-L126
[jpg-loader]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/jpg/image_loader_libjpeg_turbo.cpp#L36-L101
[hdr-loader]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/hdr/image_loader_hdr.cpp#L57-L124
[ktx-srgb]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/ktx/texture_loader_ktx.cpp#L290-L335
[basisu-unpack]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/basis_universal/image_compress_basisu.cpp#L220-L300
[reg-etcpak]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/etcpak/register_types.cpp#L37-L49
[reg-astcenc]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/astcenc/register_types.cpp#L35-L45
[reg-basisu]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/basis_universal/register_types.cpp#L36-L54
[reg-betsy]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/betsy/register_types.cpp#L35-L42
[imp-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/editor/import/resource_importer_texture.h#L121
[cvtt-pool]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/cvtt/image_compress_cvtt.cpp#L285-L292
[cfg-cvtt]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/cvtt/config.py
[betsy-h]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/modules/betsy/image_compress_betsy.h#L96-L122
[test-image]: https://github.com/godotengine/godot/blob/944a3c6cbbbb88284feebcb0603464cb175fa18e/tests/core/io/test_image.cpp
[c-block]: ./concepts.md#block-compressed-formats-and-supercompression
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-meta]: ./concepts.md#image-metadata
[c-container]: ./concepts.md#container-and-bitstream
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-hostile]: ./concepts.md#hostile-input
[ktx-doc]: ./ktx-software.md
[basisu-doc]: ./basis-universal.md
[libpng-doc]: ./libpng.md
[libjpeg-doc]: ./libjpeg-turbo.md
[libwebp-doc]: ./libwebp.md
[openexr-doc]: ./openexr.md
[wuffs-doc]: ./wuffs.md
[vk-doc]: ./vulkan-transfer.md
[p-texture]: ./papers/gpu-texture-compression.md
