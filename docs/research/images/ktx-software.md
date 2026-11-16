# KTX-Software (C, C++)

The Khronos reference implementation of the KTX2 GPU texture container: `libktx` parses the header, level index, Data Format Descriptor and key/value data, inflates Zstd and ZLIB supercompression, transcodes Basis Universal payloads to a block format the device supports and uploads the result to a Vulkan image, and the `ktx` tool validates files against the specification; it is the survey's example of a container whose layout is designed for streaming and direct upload, wrapped by a library that loads whole textures and trusts sizes the file declares.

| Field         | Value                                                                                                                                                                                                                |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (built as C11, [`c_std_11`][cmake-std]) for the container code (`lib/src/texture2.c`, `vkloader.c`, `checkheader.c`), C++17 for the Basis transcoder glue, the ASTC encoder glue and the `ktx` tool (`tools/ktx/`) |
| License       | Apache-2.0 for files unique to the repository; bundled dependencies carry their own licences, and `external/etcdec/etcdec.cxx` is under a non-open-source Ericsson licence ([`LICENSE.md`][license])                 |
| Repository    | [KhronosGroup/KTX-Software][repo]                                                                                                                                                                                    |
| Revision read | `d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6` (October 27, 2026; release notes head `5.0.0-rc2`, [`RELEASE_NOTES.md`][release-notes]); CTS submodule pinned at `8465c99944b0e4392fb4de6de47932262e4c2826`               |
| Documentation | [KTX 2.0 specification][ktx2-spec] (Document Revision 4) · [libktx reference][libktx-docs] · in-tree [`lib/libktx_mainpage.md`][mainpage] · [Khronos Data Format Specification][kdfs]                                |
| Category      | GPU and SIMD: GPU texture container, supercompression, Basis Universal transcoding, Vulkan upload                                                                                                                    |
| Tier          | A                                                                                                                                                                                                                    |
| Last reviewed | November 7, 2026                                                                                                                                                                                                     |

> [!NOTE]
> Claims marked **verified** come from two C probes, run against a `RelWithDebInfo` build (GCC 14.3.0,
> so `_DEBUG` is not defined) of the pinned revision in a scratch directory under `/tmp`: one
> interposes `malloc` to record the largest request, the other uploads through
> `ktxTexture2_VkUploadEx` to lavapipe (Mesa 25.2.6) with `VK_LAYER_KHRONOS_validation` (1.4.328
> in the first run, 1.4.363 in a rerun with the probes rebuilt by GCC 16.2.0; the results were the
> same). Inputs were made with `ktx create` from the repository's
> `tests/resources/input/png/color_grid.png` (1024×1024 RGBA8):
> `--format R8G8B8A8_SRGB --generate-mipmap` for the uncompressed file, plus `--zstd 18` for the Zstd one and
> `--encode basis-lz` without mipmaps for the ETC1S one. No performance number is quoted. The CTS
> submodule is not checked out locally; its README was read at the pinned submodule commit.

## Overview

### What it solves

A GPU texture is not an image file. It has mip levels, array layers, cube faces and depth slices;
its texels may be in a [block-compressed format][c-block] the GPU samples directly; and its bytes
must land in a Vulkan image whose `VkFormat`, extent and level count the file has to state exactly.
PNG and JPEG describe none of that. KTX2 is the container that does, and the README positions the
software around it ([`README.md`][readme]):

> _"KTX (Khronos Texture) is a lightweight container for textures for OpenGL®, Vulkan® and other
> GPU APIs. KTX files contain all the parameters needed for texture loading. A single file can
> contain anything from a simple base-level 2D texture through to a cubemap array texture with
> mipmaps."_

The same paragraph names the two payload families: Basis Universal (_"LZ/ETC1S, which combines
block-compression and supercompression, and UASTC, a block-compressed format"_) and _"Formats other
than LZ/ETC1S"_, which _"can be supercompressed with Zstd and ZLIB"_. The library _"can deflate and
inflate zstd and zlib compressed images, can encode and transcode the Basis Universal formats and
can encode ASTC formats"_ ([`libktx_mainpage.md`][mainpage]). The format itself is the subject of
the [GPU texture compression papers][p-texture]; this page is about the implementation.

### Design philosophy

Four commitments recur in the specification and the code.

1. **The layout serves the upload.** The header carries a `VkFormat` directly; levels are stored
   smallest first; uncompressed rows are tightly packed (_"equivalent to a GL_UNPACK_ALIGNMENT of 1"_);
   and each level starts on `lcm(texel_block_size, 4)` ([spec, `levelImages`][spec-levelimages]).
   The ordering exists because _"sending smaller mip levels first can be used together with ...
   appropriate region setting in a VkCmdCopyBufferToImage, to display a low resolution image quickly
   without waiting for the entire texture data"_ ([spec, Mip Level Array][spec-mip]).
2. **Supercompression is per level.** _"The supercompression scheme is applied independently to each
   mip level to permit streaming and random access to the levels"_ ([spec,
   `supercompressionScheme`][spec-scheme], quoted in the [papers][p-texture]). BasisLZ is the
   exception: its codebooks live in one global block every level needs.
3. **Format semantics come from the Khronos Data Format Descriptor.** The `vkFormat` field is
   `VK_FORMAT_UNDEFINED` for Basis payloads, so the [DFD][kdfs] is the authoritative description
   of colour model, channels, transfer function and primaries, and `libktx` computes block sizes
   from it rather than from the `VkFormat` ([`ktxFormatSize_initFromDfd`][init-dfd]).
4. **Length fields are the safety story.** The media-type registration says
   ([spec, IANA registration][spec-iana]): _"Because every item's length is available at its
   beginning, there is robust defense against corrupted or fraudulent data that might overflow a
   decoder's buffer"_, and then, of variable-rate supercompression: _"applications must not rely on
   this and must guard against buffer overflow and ultra large memory allocation."_ The second
   sentence is the one this page tests.

## How it works

### The container

A KTX2 file is a fixed 80-byte little-endian header, a level index, and four optional or required
regions addressed by `(offset, length)` pairs from the header ([spec, file structure][ktx2-spec]).
`libktx` mirrors the header in one struct and asserts its size at compile time
([`ktxint.h`][header2]):

```c
// lib/src/ktxint.h
typedef struct KTX_header2 {
    ktx_uint8_t  identifier[12];
    ktx_uint32_t vkFormat;
    ktx_uint32_t typeSize;
    ktx_uint32_t pixelWidth;
    ktx_uint32_t pixelHeight;
    ktx_uint32_t pixelDepth;
    ktx_uint32_t layerCount;
    ktx_uint32_t faceCount;
    ktx_uint32_t levelCount;
    ktx_uint32_t supercompressionScheme;
    ktxIndexEntry32 dataFormatDescriptor;
    ktxIndexEntry32 keyValueData;
    ktxIndexEntry64 supercompressionGlobalData;
} KTX_header2;

/* This will cause compilation to fail if the struct size doesn't match */
typedef int KTX_header2_SIZE_ASSERT [sizeof(KTX_header2) == KTX2_HEADER_SIZE];
```

- **Identifier.** `«KTX 20»\r\n\x1A\n` (`KTX2_IDENTIFIER_REF`, [`ktxint.h`][ident]), modelled on
  PNG's signature: byte 0 is non-ASCII to catch transfers that clear bit 7, the CR-LF pair and the
  final LF catch line-ending conversion in either direction, and the control-Z stops display under
  MS-DOS ([spec, identifier][spec-identifier]).
- **`vkFormat` and `typeSize`.** The Vulkan format enum value, or `0` for Basis payloads.
  `typeSize` is the size of the data type for endian conversion (1 for block formats); the file is
  little-endian, and `libktx` swaps 16, 32 or 64-bit words on big-endian hosts by `typeSize`
  ([`loadImageDataInt`][load-int]).
- **Dimensions, layers, faces, levels.** `pixelHeight == 0` means 1-D, `pixelDepth == 0` means not
  3-D, `layerCount == 0` means not an array, `faceCount` is 1 or 6, and `levelCount == 0` asks the
  loader to generate mipmaps. `ktxCheckHeader2_` derives the dimensionality, rejects cube maps that
  are not square 2-D, refuses 3-D arrays as `KTX_UNSUPPORTED_FEATURE`, and bounds `levelCount` by
  `1 + log2(max dimension)` and by 32 ([`checkheader.c`][check-header2]).
- **Supercompression scheme.** `KTX_SS_NONE` (0), `KTX_SS_BASIS_LZ` (1), `KTX_SS_ZSTD` (2),
  `KTX_SS_ZLIB` (3), and at this revision `KTX_SS_UASTC_HDR_6x6_INTERMEDIATE` (4) from the draft
  Revision 5; `0x10000`–`0x1ffff` is a vendor range ([`ktx.h`][ss-enum]).
- **Level index.** `levelCount` entries of three `uint64`: `byteOffset` from the start of the file,
  `byteLength` as stored and `uncompressedByteLength` after inflation ([`ktxint.h`][levelidx]).
  Index 0 is the largest level, which is stored last in the file.
- **Data Format Descriptor.** A `uint32` total size followed by descriptor blocks
  ([spec, DFD][spec-dfd]); `libktx` requires the first block to be a basic descriptor block
  (descriptor type and vendor 0) at version 1.3 with at least one sample
  ([`ktxFormatSize_initFromDfd`][init-dfd]), and the validator reports the same faults as issues
  6008 and 6011 ([`validation_messages.h`][dfd-issues]).
- **Key/value data.** Length-prefixed, NUL-terminated keys with 4-byte padding: `KTXorientation`,
  `KTXswizzle`, `KTXwriter`, `KTXanimData`, `KTXmapRange` and others ([`ktx.h`][keys]).
- **Supercompression global data.** Present only for BasisLZ and the UASTC HDR 6×6 intermediate
  scheme, 8-byte aligned; for BasisLZ it holds the endpoint and selector codebooks, the Huffman
  tables and one image descriptor per image ([spec, BasisLZ global data][spec-bgd]).

### Construction: `ktxTexture2_CreateFromMemory`

`ktxTexture2_CreateFromMemory(bytes, size, createFlags, &texture)` wraps the bytes in a read-only
memory `ktxStream` and runs `ktxTexture2_constructFromStreamAndHeader`
([`ktx.h`][create-mem], [`texture2.c`][construct]). A `ktxStream` is a struct of seven function
pointers (`read`, `skip`, `write`, `getpos`, `setpos`, `getsize`, `destruct`) over a `FILE*`, a
memory block or a custom pointer ([`ktx.h`][stream]). The memory stream's `read` is a `memcpy`
out of the caller's buffer ([`memstream.c`][memstream-read]). Construction does, in order:

1. `ktxCheckHeader2_` on the 80 bytes.
2. Read the level index; then, if the stream knows its size, check that the DFD, the key/value data,
   the global data and every level lie inside the file, _"before memory is allocated for it"_
   ([`texture2.c`][bounds]). A pipe has no size, and the check is skipped.
3. Rebase level offsets to the first level, require `byteLength == uncompressedByteLength` when
   there is no supercompression, and require every level to end inside level 0's extent.
4. Read the DFD, require `dfdByteLength == dfdTotalSize`, and run `ktxFormatSize_initFromDfd`, which
   walks the descriptor blocks and stops before any read past the declared size. Its own comment
   on one check: _"This is essential to avoid heap-buffer-overflow accesses which are UB!"_
   ([`texture2.c`][ub-comment]). Then check the transfer function against the format's sRGB-ness,
   the colour model against the scheme (BasisLZ requires `KHR_DF_MODEL_ETC1S`), and, with
   `KTX_TEXTURE_CREATE_CHECK_GLTF_BASISU_BIT`, the `KHR_texture_basisu` rules
   ([`texture2.c`][dfd-read]).
5. Parse the key/value data into a hash list unless `KTX_TEXTURE_CREATE_SKIP_KVDATA_BIT` or
   `RAW_KVDATA_BIT` is set, and lift `KTXorientation` and `KTXanimData` into fields
   ([`texture2.c`][kvd]).
6. Read the supercompression global data, refusing it for schemes that do not use one
   ([`texture2.c`][sgd]).
7. If `KTX_TEXTURE_CREATE_LOAD_IMAGE_DATA_BIT` is set, load and inflate all levels now.

Without step 7 the texture keeps its stream and loads later. The doc comment says why
([`texture2.c`][doc-noload]): the flag _"should not be set, if the ktxTexture is ultimately to be
uploaded to OpenGL or Vulkan. This will minimize memory usage by allowing, for example, loading the
images directly from the source into a Vulkan staging buffer."_

### Inflation: Zstd and ZLIB

`ktxTexture2_LoadImageData(texture, buffer, size)` sizes its destination by
`ktxTexture2_GetDataSizeUncompressed`, which, for Zstd and ZLIB, is the sum of the levels'
`uncompressedByteLength` padded to the post-inflation alignment ([`texture2.c`][size-uncompressed]).
It then reads all compressed levels into one temporary buffer and inflates level by level, smallest
first, into the destination ([`texture2.c`][load-int]). The Zstd loop uses one `ZSTD_DCtx` and
checks each result against the index ([`texture2.c`][inflate-zstd]):

```c
// lib/src/texture2.c, ktxTexture2_inflateZstdInt()
    for (int32_t level = This->numLevels - 1; level >= 0; level--) {
        size_t levelByteLength =
            ZSTD_decompressDCtx(dctx, pInflatedData + levelOffset,
                              inflatedDataCapacity,
                              &pDeflatedData[cindex[level].byteOffset],
                              cindex[level].byteLength);
        ...
        if (This->_private->_levelIndex[level].uncompressedByteLength != levelByteLength) {
            result = KTX_DECOMPRESS_LENGTH_ERROR;
            goto cleanup;
        }
```

After success the texture is rewritten in place: a new level index, `dataSize`, and
`supercompressionScheme = KTX_SS_NONE`. ZLIB takes the same path through `mz_uncompress` from a
bundled miniz ([`texture2.c`][inflate-zlib], [`miniz_wrapper.cpp`][miniz]). The writer side,
`ktxTexture2_DeflateZstd`, compresses each level independently with `ZSTD_compressCCtx` into a
buffer sized by `ZSTD_compressBound` ([`writer2.c`][deflate-zstd]). Zstd itself is the copy bundled
with Basis Universal (`BASISU_ZSTD TRUE` in [`lib/CMakeLists.txt`][cmake-basisu]).

### Transcoding Basis payloads: `ktxTexture2_TranscodeBasis`

`ktxTexture2_NeedsTranscoding` is true for the ETC1S, UASTC and UASTC HDR 6×6 colour models. `TranscodeBasis(texture,
fmt, flags)` takes one of the `ktx_transcode_fmt_e` targets (`KTX_TTF_BC7_RGBA`, `KTX_TTF_ETC2_RGBA`,
`KTX_TTF_ASTC_4x4_RGBA`, `KTX_TTF_RGBA32`, the HDR targets and others, [`ktx.h`][ttf-enum]) and
maps it to a `VkFormat`, picking the `_SRGB` variant when the DFD's transfer function is sRGB. It
then creates a prototype `ktxTexture2` of the target format with full storage, uses it for sizes
and the new DFD, and moves its data into the source texture on success ([`basis_transcode.cpp`][transcode-main]).
For ETC1S, it validates that the global data is long enough for the image descriptors and tables,
decodes the codebooks once with `basisu_lowlevel_etc1s_transcoder::decode_palettes` and
`decode_tables`, and transcodes every image of every level, smallest level first, with one
`transcode_image` call per image ([`basis_transcode.cpp`][transcode-etc1s]). The validation is
marked incomplete in the source ([`basis_transcode.cpp`][fixme]):

```cpp
// lib/src/basis_transcode.cpp, ktxTexture2_transcodeLzEtc1s()
    if (BGD_TABLES_ADDR(0, bgdh, imageCount) + bgdh.tablesByteLength > priv._sgdByteLength) {
        return KTX_FILE_DATA_ERROR;
    }

    // FIXME: Do more validation.
```

The transcoder's global tables are initialised once behind an atomic flag and a mutex, because
_"By deliberate choice basisu_transcoder_init() does not have its own mutex"_
([`basis_transcode.cpp`][transcode-init]).

**Verified:** the ETC1S file made by `ktx create --encode basis-lz` (71,692 bytes, one level,
`vkFormat` 0, `KTX_SS_BASIS_LZ`, `NeedsTranscoding` true) transcodes to `KTX_TTF_BC7_RGBA`, after
which the texture reports `vkFormat` 146 (`VK_FORMAT_BC7_SRGB_BLOCK`), scheme `KTX_SS_NONE` and
1,048,576 bytes of data, and uploads to lavapipe.

### Vulkan upload: `ktxTexture2_VkUploadEx`

The caller fills a `ktxVulkanDeviceInfo` (instance, physical device, device, queue, command pool,
allocator, and a `ktxVulkanFunctions` table loaded through `vkGetInstanceProcAddr`,
[`ktxvulkan.h`][vk-funcs]) and calls `ktxTexture2_VkUploadEx(texture, vdi, &vkTexture, tiling,
usage, finalLayout)`. The function ([`vkloader.c`][vk-upload]):

1. Maps dimensionality, `isArray` and `isCubemap` to `VkImageType`, `VkImageViewType` and
   `VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT`; refuses `VK_FORMAT_UNDEFINED` (a Basis texture must be
   transcoded first).
2. Asks `vkGetPhysicalDeviceImageFormatProperties` for the format, tiling and usage, and refuses
   when the format is unsupported or `maxArrayLayers`/`maxMipLevels` are exceeded
   ([`vkloader.c`][vk-format-query]).
3. Creates a host-visible, host-coherent staging buffer of `ktxTexture_GetDataSizeUncompressed`
   bytes, maps it, and, if the data is not loaded yet, calls `ktxTexture_LoadImageData` with the
   mapped pointer as destination, so the file's bytes (or the Zstd output) land in the staging
   buffer without an intermediate heap copy ([`vkloader.c`][vk-staging]).
4. Builds one `VkBufferImageCopy` per level through `ktxTexture_IterateLevels`, with
   `bufferRowLength = 0`, `layerCount = numLayers * numFaces`,
   `aspectMask = VK_IMAGE_ASPECT_COLOR_BIT` and the level's extent ([`vkloader.c`][vk-region]).
5. Creates the optimal-tiling image in device-local memory, records a barrier to
   `TRANSFER_DST_OPTIMAL`, `vkCmdCopyBufferToImage` for all regions, then either `vkCmdBlitImage`
   mipmap generation or a barrier to `finalLayout`.
6. Submits, creates a fence and blocks on `vkWaitForFences` with a 100-second timeout, then frees
   the staging buffer ([`vkloader.c`][vk-fence]).

`ktxVulkanTexture` returns the `VkImage`, its memory, format, view type, extent and level and layer
counts ([`ktxvulkan.h`][vk-texture]); `ktxTexture2_VkUploadEx_WithSuballocator` replaces the two
`vkAllocateMemory` calls with six caller callbacks (allocate, bind buffer, bind image, map, unmap,
free) and rejects allocations that span more than one page with `KTX_UNSUPPORTED_FEATURE`
([`ktxvulkan.h`][suballoc], [`vkloader.c`][vk-staging]).

**Verified:** on lavapipe, the uncompressed (`VK_FORMAT_R8G8B8A8_SRGB`, 11 levels), Zstd and
transcoded BC7 files upload with `KTX_SUCCESS` and no validation-layer error. `llvmpipe` reports
`textureCompressionBC = 1`, `textureCompressionETC2 = 0`, `textureCompressionASTC_LDR = 0`.

### The `ktx` tool and its validator

`ktx` is one binary with subcommands `create`, `convert`, `encode`, `transcode`, `deflate`,
`extract`, `compare`, `info`, `validate` and `patch` ([`tools/ktx/`][tools-ktx]); the legacy
`toktx` family was removed in 5.0 ([`RELEASE_NOTES.md`][release-notes]). `ktx validate` is a
second, independent reader of the format written in C++ (`ValidationContext`), which runs nine
passes in order and only then hands the file to `libktx` ([`validate.cpp`][validate-order]):

```cpp
// tools/ktx/validate.cpp, ValidationContext::validate()
    call(&ValidationContext::validateHeader, "Header");
    call(&ValidationContext::validateIndices, "Index");
    call(&ValidationContext::calculateExpectedDFD, "Expected DFD", VkFormat(header.vkFormat));
    call(&ValidationContext::validateDFD, "DFD");
    call(&ValidationContext::validateLevelIndex, "Level Index"); // Must come after the DFD parsed
    call(&ValidationContext::validateKVD, "KVD");
    call(&ValidationContext::validateSGD, "SGD");
    call(&ValidationContext::validatePaddings, "padding");
    if (doCreateAndTranscodeChecks)
        call(&ValidationContext::validateCreateAndTranscode, "Create and Transcode");
```

Each finding is a typed issue with a numeric ID, a severity (`warning`, `error`, `fatal`), a
message and a details format string ([`validation_messages.h`][issues]); 176 are declared (three
more are commented out, and ID 7013 is used twice). The tool
prints them as text or as JSON conforming to the `validate_v0.json` schema
([`command_validate.cpp`][validate-help]). The final pass compares the two readers: when the
validator found errors but `libktx` accepted the file, it reports warning 5004, _"Non-conformant
texture file accepted by libktx"_ ([`validation_messages.h`][nonconformant],
[`validate.cpp`][validate-create]).

## Analysis

### 1. Pixel and memory model

The model is the GPU's, not an image library's. A `ktxTexture2` is one contiguous `pData` buffer of
`dataSize` bytes holding all levels, smallest first, each level the concatenation of layers, faces
and depth slices, each image a tightly packed raster of [texel blocks][c-block]
([`ktx.h`][classdefn], [spec, `levelImages`][spec-levelimages]). There is no stride field: rows are
tight by definition and levels are aligned to `lcm(blockBytes, 4)` (`lcm4`,
[`texture2.c`][align]). Addressing is by `(level, layer, faceSlice)` through
`ktxTexture_GetImageOffset`, which returns a byte offset into `pData`. Extents go up to 3-D, with
cube maps as six faces and 1-D, 2-D and cube arrays; 3-D arrays are refused at the header.

The texel is described twice, by `vkFormat` and by the DFD. `libktx` derives block footprint and
bytes per block from the DFD (`ktxFormatSize`); only the validator compares the DFD with the one
`vk2dfd` generates for the `vkFormat` (`calculateExpectedDFD`), while the library checks just the
sRGB transfer function ([`texture2.c`][dfd-read]). Multi-planar YCbCr formats are prohibited, so an
image is one plane, with `VK_IMAGE_ASPECT_COLOR_BIT` hard-coded in the upload ([`vkloader.c`][vk-region]).

### 2. Genericity mechanism

C single inheritance by macro and a vtable. `KTXTEXTURECLASSDEFN` expands the common fields into
both `ktxTexture1` and `ktxTexture2`, and `struct ktxTexture_vtbl` holds 17 function pointers
(`GetImageOffset`, `IterateLevels`, `LoadImageData`, `WriteToStream` and others); a macro such as
`ktxTexture_GetImageOffset(This, ...)` expands to `(This)->vtbl->GetImageOffset(...)`
([`ktx.h`][vtbl]). Vulkan functions sit in a second table, `vvtbl`, so `ktx.h` need not include
`vulkan.h`. Format genericity is data, not types: one `ktxFormatSize` record computed from the DFD
drives every size calculation, and every per-format decision (transcode target to `VkFormat`,
sRGB variant) is a `switch` ([`basis_transcode.cpp`][transcode-main]). I/O genericity is the
`ktxStream` function-pointer struct. Nothing is parameterised at compile time.

### 3. Colour and metadata

Colour lives in the DFD: `colorModel` (RGBSDA, YUVSDA, the block models, ETC1S, UASTC),
`colorPrimaries` (BT.709, BT.2020, Display P3 and others), `transferFunction` (linear, sRGB,
PQ, HLG and the rest) and per-sample flags such as signed, float, linear and exponent
([Khronos Data Format Specification][kdfs]). `libktx` exposes them as accessors that read one field
of the basic block each (`ktxTexture2_GetTransferFunction_e`, `GetPrimaries_e`, `GetColorModel_e`,
`GetPremultipliedAlpha`, [`texture2.c`][colour-get]), and construction rejects transfer functions
beyond `KHR_DF_TRANSFER_HLG_UNNORMALIZED_OETF` ([`texture2.c`][dfd-read]). The DFD's primaries and
transfer function correspond to [CICP][c-cicp]'s primaries and transfer characteristics; the DFD
has no matrix-coefficients field, and the only YCbCr formats KTX2 admits are single-plane `*_422_*`
ones (`KHR_DF_MODEL_YUVSDA`, [spec, DFD][spec-dfd]), the multi-plane formats being prohibited ([spec, `vkFormat`][spec-vkformat]).
There is no ICC profile, no EXIF and no XMP; the specification's key/value data carries texture
semantics instead (`KTXorientation`, `KTXswizzle`, `KTXmapRange`, `KTXastcDecodeMode`,
`KTXwriter`, `KTXwriterScParams`), and the validator registers a checker for each
([`validate.cpp`][validate-kvd]). Premultiplied alpha is a DFD flag, not a convention
([straight and premultiplied alpha][c-alpha]).

### 4. I/O and codec architecture

**Pull, whole-texture, synchronous.** The reader asks its `ktxStream` for exactly the bytes it
needs; a short read is `KTX_FILE_UNEXPECTED_EOF`, never "need more input", so the reader is a
[pull decoder][c-pushpull] and is not [suspendable][c-suspend]. Metadata is eager (step 5 above),
image data is either eager or deferred as a whole. `LoadImageData` reads all levels in one `read`
call and inflates them all; `IterateLoadLevelFaces` reads and inflates one level at a time,
smallest first, into buffers sized for level 0, but only for callers that consume every level
through a callback ([`texture2.c`][iterate-load]).

The format allows more than the library does. Because each Zstd or ZLIB level is independent and
the level index gives its `(byteOffset, byteLength)`, a reader can fetch and inflate any level
alone, smallest first, and upload it before the next arrives, which is the streaming case the
specification's rationale describes. `libktx` has no public call to load or inflate one chosen
level, and `VkUploadEx` copies all levels in one submission. BasisLZ breaks per-level independence: its global
data must be read before any level can be transcoded ([papers][p-texture]).

The codec layers are separate in code even though they ship in one library: container parsing
(`texture2.c`), supercompression (`ktxTexture2_inflate*Int`), transcoding (`basis_transcode.cpp`
over the vendored `basisu_transcoder`), and upload (`vkloader.c`, `glloader.c`).

### 5. Hostile input and safety

What `libktx` checks is thorough at the container level: every header and index entry is bounded
by the file size before allocation, level and global-data offsets are tested in subtraction form so
they cannot overflow (`entry->byteLength > fileSize - entry->byteOffset`), the DFD walker stops on
zero-sized blocks, `levelCount` is bounded, and decompressed lengths are compared with the index
([`texture2.c`][bounds], [`texture2.c`][inflate-zstd]). CI runs one Linux job under AddressSanitizer
with the CLI conformance tests ([`linux.yml`][ci-asan]). There is no fuzz target for `libktx`; the
only `LLVMFuzzerTestOneInput` functions belong to vendored dependencies (`astc-encoder`, `fmt`).

Two gaps were demonstrated and a third was read.

1. **The uncompressed size is trusted for allocation (verified).** `GetDataSizeUncompressed` sums
   `uncompressedByteLength` from the file and `loadImageDataInt` passes it to `malloc` before
   inflating, so the size is compared with reality only after the allocation
   ([`texture2.c`][load-int]). Setting level 0's `uncompressedByteLength` to 2^40 in the 814,434-byte
   Zstd file made `ktxTexture2_LoadImageData` request a 1,099,513,025,876-byte allocation and return
   `KTX_OUT_OF_MEMORY`; setting it to 6 GiB produced a 6,443,849,044-byte request, which succeeded
   under Linux overcommit, and the load then failed with `KTX_DECOMPRESS_LENGTH_ERROR`. This is
   exactly the "ultra large memory allocation" the specification tells consumers to guard against.
   `ktx validate` reports the 6 GiB file as error 4008 only through its final `libktx` pass; its
   level-index pass checks `uncompressedByteLength` exactly only for unsupercompressed files
   ([`validate.cpp`][validate-level]).
2. **Level sizes are not checked against the format and extent (verified).** Shrinking level 0's
   `byteLength` and `uncompressedByteLength` to 16 in the uncompressed 1024×1024 RGBA8 file is
   accepted by `ktxTexture2_CreateFromMemory` with `KTX_TEXTURE_CREATE_LOAD_IMAGE_DATA_BIT`
   (`dataSize` 1,398,116, while `GetImageSize(0)` is 4,194,304). `ktx validate` rejects it with
   errors 4001, 4005 and 4006 and adds warning 5004, "Non-conformant texture file accepted by
   libktx". Uploading it with `ktxTexture2_VkUploadEx` on lavapipe produced
   `VUID-vkCmdCopyBufferToImage-pRegions-00171` (a copy region outside the staging buffer) and a
   segmentation fault (exit 139, five runs out of five) in a `memmove` called from lavapipe's
   `util_copy_box` under `handle_copy_buffer_to_image` on the queue thread: the copy regions come
   from the level extents ([`vkloader.c`][vk-region]), the staging buffer from the index. Under
   Valgrind the same upload did not crash and returned `KTX_SUCCESS`, so the crash depends on
   what lies past the mapping; the out-of-bounds region does not.
3. **Vulkan errors vanish in release builds (read).** `VK_CHECK_RESULT` prints and asserts under
   `_DEBUG` and is otherwise `((void)f)` ([`vkloader.c`][vk-check]), and it wraps
   `vkCreateBuffer`, `vkCreateImage`, the bind and map calls, `vkQueueSubmit` and
   `vkWaitForFences`. The macro's comment limits it to errors _"caused by invalid usage by this
   loader"_, but out-of-memory and a fence timeout are not usage errors: in a release build the
   function carries on past them and ends in `return KTX_SUCCESS`.

The ETC1S path relies on the vendored transcoder to bounds-check slices
([`basis_transcode.cpp`][fixme]). Background is in the [hostile-input papers][p-hostile] and
[concepts][c-hostile]; [libspng][libspng] and [Wuffs][wuffs] are the counterpoints on
default-closed limits.

### 6. Allocation and ownership

The texture owns everything: `pData`, `pDfd`, the key/value hash list, the global data and the
private block (which ends in the level index, [`texture2.h`][private]) are separate `malloc`
blocks freed by `ktxTexture2_Destroy`, and
`TranscodeBasis` replaces `pData` and `pDfd` wholesale with the prototype's. There is no allocator
parameter for host memory; the only hooks are `VkAllocationCallbacks` and the sub-allocator
callbacks for device memory. `LoadImageData(texture, buffer, size)` writes into caller storage,
and `VkUploadEx` uses that to inflate straight into mapped staging memory, so a Zstd upload holds
the compressed data, the staging buffer and the device image at once. Transcoding holds source,
the prototype's full target storage and the transcoder state. `CreateFromMemory` does not take the
caller's bytes; the memory stream copies out of them, so the caller's buffer and `pData` coexist.

### 7. CPU parallelism and SIMD

`libktx` itself is single-threaded and has no SIMD code. Encoding parallelism belongs to the
vendored encoders, configured through `threadCount` in `ktxAstcParams` and `ktxBasisParams`
([`ktx.h`][threadcount]); `BASISU_SSE` and `BASISU_OPENCL` are build options for the Basis encoder
([`lib/CMakeLists.txt`][cmake-options]). Transcoding is one `transcode_image` call per image in a
serial loop; the per-image state (`basisu_transcoder_state`) exists for thread safety and video
P-frames, and the only concurrency test is a smoke test whose own header says _"It is not clear how
useful this test actually is"_ ([`threadtests.cc`][threadtests]). Inflation is one `ZSTD_DCtx`
over all levels in sequence, although the levels are independent.

### 8. GPU offload and interop

The Vulkan path is the library's reason to exist, and it is the plain one: staging buffer,
`vkCmdCopyBufferToImage`, barriers, one submission, a blocking fence wait, all on the caller's
queue with a command buffer allocated from the caller's pool ([`vkloader.c`][vk-upload]). It uses Vulkan 1.0 entry points only
(`vkGetPhysicalDeviceImageFormatProperties`, `vkCmdPipelineBarrier`), so it runs on the oldest
drivers and Android. It does not use a transfer queue, timeline semaphores, `VK_EXT_host_image_copy`,
[external memory][c-external] or [GPU decompression][c-gpudecomp]; transcoding and inflation are
CPU work. A caller that wants an asynchronous or batched upload can use the parts (`LoadImageData`
into its own buffer, `GetImageOffset` for regions) and record the copy itself; the library's own
upload cannot overlap rendering because it waits on the fence. Format selection, which the
[hardware matrix][hw-formats] shows is necessary (no compressed family is universal across the
measured devices), is left to the caller, who picks the `ktx_transcode_fmt_e` target from the
device's features before calling `TranscodeBasis`.

### 9. Temporal, animation and containers

KTX2 is itself the container, and it has a minimal animation model: the `KTXanimData` key holds
`duration`, `timescale` and `loopcount`, valid only on array textures, where each layer is a frame;
`libktx` exposes these as `isVideo`, `duration`, `timescale` and `loopcount` on `ktxTexture2`
([`texture2.c`][anim], [`ktx.h`][tex2-struct]). For ETC1S, the transcoder keeps one state per face
when `isVideo` is set so that P-frames can reference the previous frame, but the I-frame flag is
not passed through: the call site says the _"API currently doesn't have any way to pass the
I-Frame flag"_, and a `FIXME` asks for it to be queryable ([`basis_transcode.cpp`][transcode-etc1s]). There are no per-frame
timestamps or variable frame durations. This is a sprite-sheet model, not a video model; the video
subjects in the [umbrella][index-video] cover the rest.

### 10. Testing and conformance

Three layers exist.

- **Unit and texture tests** in GoogleTest: `texturetests.cc` (120 test macros), `unittests.cc`
  (49), `streamtests.cc`, `transcodetests.cc` and `threadtests.cc`, over 36 KTX2 files in
  `tests/resources/ktx2` ([`tests/`][tests-dir]). The negative cases are mostly API misuse (null
  parameters, data already loaded), not malformed files.
- **The CTS**, a separate repository included as a submodule ([`.gitmodules`][gitmodules]):
  black-box tests of the CLI tools, one JSON file per case giving the command line, expected exit
  status, golden stdout, stderr and output files, with permutations generated from an `args`
  dictionary ([CTS README][cts-readme]). `outputTolerance` admits non-bit-exact output on
  non-primary platforms: _"BasisLZ compression relies on the undefined order of std::unordered_map
  containers"_.
- **The validator as an oracle.** `ktx validate` is a second implementation of the specification's
  rules, and its last pass runs `libktx` on the same file and reports disagreement (warning 5004).
  This is a built-in differential test between the reference reader and the reference library, and
  it is what exposed gap 2 above.

There is no fuzz target for `libktx` and no golden-image comparison of upload results; the
`ktxdiff` tool compares texture files with a tolerance.

## Lessons for Sparkles

- **Q6 — KTX2's level index is already the request list `sparkles:event-horizon` needs.** Each
  level is an independent `(byteOffset, byteLength)` with its inflated size beside it, smallest
  first, so a reader can issue one `OpRead` per level, inflate each as it lands and upload it,
  showing low mips first. `libktx`'s upload path does none of this (whole-texture load, one
  blocking submission),
  so it is evidence for the format's design, not a template for the code. Event-horizon has the
  offset read but no ranged-read helper layer (G1 in the [event-horizon baseline][bl-eh]); KTX2
  is a concrete, bounded first client for one.
- **Q6 — Inflate or read straight into the staging buffer.** `VkUploadEx`'s best idea is
  `LoadImageData` with the mapped staging pointer as destination, which removes a heap copy.
  Sparkles' `Uploads.stage` copies a caller's `ubyte[]` into the slot's host-visible arena (G1 in
  the [Vulkan baseline][bl-vk]); a KTX2 loader that writes into an arena region, or into a region
  an `io_uring` read targets, is the same move one level down. The fence-to-loop seam it would need
  is G5 there.
- **Q1, Q6 — The upload path needs levels, layers and block formats before it can carry KTX2.**
  `Uploads.stage` takes one tight extent with no layer or mip (G1 in the [Vulkan baseline][bl-vk];
  G8 in [existing code][bl-existing]); KTX2 needs a `VkBufferImageCopy` per level with
  `layerCount = layers × faces`, block-aligned offsets and compressed `VkFormat`s, and the shader side cannot
  sample a compressed or array image yet (G9 in the [shaders baseline][bl-shaders]). The per-frame
  upload budget (`UVK23`/`UVK29`, decision D10 there) maps naturally onto KTX2's per-level ordering.
- **Q6, Q8 — Query format properties before upload.** `VkUploadEx` asks
  `vkGetPhysicalDeviceImageFormatProperties` for support, `maxMipLevels` and `maxArrayLayers`;
  Sparkles binds no such query and passes only `maxImageExtent` (G13 in the
  [Vulkan baseline][bl-vk]), so a KTX2 upload has no way to refuse an unsupported format today.
- **Q4, Q8 — Bound declared sizes before allocating, and check them against the format.** Both
  demonstrated `libktx` gaps come from trusting the index: an `uncompressedByteLength` that
  allocates 1 TiB, and a level smaller than its extent that later drives an out-of-bounds GPU copy.
  For an uncompressed or Zstd/ZLIB texture with a known `vkFormat`, every level's inflated size is
  computable from extent and block size, so a reader can reject a mismatch at parse time and size
  the destination from the computation, not the file. That computation fits a
  `@safe pure nothrow @nogc` function over `size_t` with checked arithmetic; `maxPngPixels` in
  `sparkles.image.png` is the existing default-closed budget ([existing code][bl-existing]).
- **Q4 — `sparkles:wired` cannot describe the KTX2 header today.** The header is fixed-layout
  little-endian, but the global-data index and the level index use 64-bit offsets and lengths, which
  Flat cannot express (G5 in the [wired baseline][bl-wired]), and wired has no binary backend on main
  (G1). KTX2 is a small, fully specified test case for whatever binary description wired grows: 80
  bytes, three index pairs, an array of triples, a length-prefixed key/value list.
- **Q5 — Borrow the DFD as the colour vocabulary for GPU textures.** The DFD already gives colour
  model, primaries, transfer function, premultiplication and per-sample bit layout in a Khronos
  standard; the [papers][p-texture] recommend it for block planes. The redundancy is a hazard: the
  file states the format twice (`vkFormat` and DFD), the library trusts the DFD for sizes and the
  `VkFormat` for upload, and only the validator checks they agree.
- **Q2 — Format mapping is data in disguise.** `libktx`'s target-to-`VkFormat` mapping with sRGB
  variants is a long `switch`; the D equivalent is a compile-time table checked against the header,
  option A of decision D2 in the [Vulkan baseline][bl-vk]. The macro-and-vtable class scheme exists
  to put KTX 1 and 2 behind one C API; D would express that with two types and introspection.
- **Q6, Q8 — Choose the transcode target from device features, and test on lavapipe.** The
  [hardware matrix][hw-formats] shows no compressed family covers all measured devices, which is
  the case for carrying Basis payloads and transcoding at load. `llvmpipe` reports BC support
  (verified), so a BC7 upload readback test fits the existing lavapipe oracle
  (`SPARKLES_VULKAN_READBACK=1`, decision D9 in the [Vulkan baseline][bl-vk]); ETC2 and ASTC paths
  need real hardware or a CPU decoder as the oracle.
- **Q4 — Vulkan results are values.** `VK_CHECK_RESULT` compiles away in release builds, so a
  failed `vkCreateImage` does not stop the upload. Sparkles' binding returns `Expected`
  ([Vulkan baseline][bl-vk]), and the `checked` build type keeps assertions; both avoid this class.
- **Q3, Q7 — Transcoding and inflation are serial CPU loops over independent work.** Levels, layers
  and faces transcode independently and Zstd levels inflate independently; `libktx` exploits
  neither. Whether a D port spreads them over the offload pool or moves transcoding to a compute
  shader (the [papers][p-texture] call it table and bit-field rewriting) is a Q7 measurement that
  cannot be made today: there is no compute pipeline (G1 in the [shaders baseline][bl-shaders]).
- **Q8 — A validator separate from the reader, diffed against it.** The typed issue catalogue
  (numeric IDs, severities, JSON output) and the final "accepted by libktx" pass are a reusable
  pattern: two independent readers of one format, disagreement reported as a finding. The CTS's
  BasisLZ tolerance warns that encoder output is not a stable oracle.
- **Q9 — `libktx` is one library with feature switches, and the seams show where a split would go.**
  Container, supercompression, Basis transcoding, ASTC encoding, ETC unpacking and GL and Vulkan
  upload are separate source files; KTX 1, ETC unpacking and both uploads are switched by
  `LIBKTX_FEATURE_*` options, and `LIBKTX_VERSION_READ_ONLY` drops the writers
  ([`lib/CMakeLists.txt`][cmake-options]). For Sparkles the analogous pieces are a formats-side
  KTX2 reader (betterC- and wasm-friendly if it stays `@nogc` and takes caller buffers), a
  supercompression layer that needs Zstd (a C library through ImportC, or a port), a Basis transcoder,
  and an upload layer on `sparkles:vulkan`, where the recommendation for decision D1 of the
  [Vulkan baseline][bl-vk] puts generic uploads.

## Strengths

- A container designed for GPUs: `VkFormat` in the header, tight rows, block-aligned levels,
  smallest-first ordering and per-level supercompression make streaming and direct upload possible.
- The DFD gives a standard, machine-readable description of colour model, transfer function,
  primaries and bit layout, including for block and Basis formats.
- Careful container-level bounds checks: every region is checked against the file size before
  allocation, in overflow-safe form, and the DFD walker is bounded.
- One call from file to `VkImage`, with a sub-allocator hook, on Vulkan 1.0 entry points.
- An independent validator (176 typed issues, JSON output, a differential check against the
  library) and a black-box CTS with golden outputs, run under AddressSanitizer in CI.

## Weaknesses

- Allocation sizes come from the file: an `uncompressedByteLength` of 2^40 becomes a 1 TiB
  `malloc` request (verified).
- Level sizes are not checked against the format and extent on load, and the Vulkan upload then
  records an out-of-bounds copy; on lavapipe this crashed the driver (verified).
- `VK_CHECK_RESULT` discards every `VkResult` it wraps in release builds.
- Whole-texture, blocking APIs: no load of one chosen level, no per-level upload, a fence wait inside the
  upload, no transfer queue.
- Transcoding and inflation are serial over independent work; transcoding holds source and full
  target storage at once.
- No fuzz target for `libktx`; the ETC1S path is marked `FIXME: Do more validation.`; `vkFormat`
  and DFD can disagree and only the validator checks.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                         | Trade-off                                                                                             |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Store `VkFormat` in the header and the DFD beside it       | Direct mapping to Vulkan; the DFD covers formats Vulkan cannot name (Basis)       | Two descriptions of one format; readers must check they agree, and `libktx` does not                  |
| Levels stored smallest first, indexed by offset            | Streaming low mips first; random access to any level                              | Index 0 is last in the file; every reader must handle the inversion and the rebasing                  |
| Supercompress each level independently (Zstd, ZLIB)        | Per-level streaming and random access                                             | Redundancy across levels is not exploited; BasisLZ needs global data and loses independence           |
| `uncompressedByteLength` in the index                      | Destination sizing before inflation                                               | An attacker-controlled allocation size unless the reader recomputes it from the format                |
| Transcode Basis at load into a prototype texture           | One asset for every GPU; reuse of the format-size code for the target             | Source plus full target storage at once; whole-texture granularity                                    |
| Upload with staging buffer, one submit, blocking fence     | Simple, portable to Vulkan 1.0 and Android, no queue or sync policy to impose     | Cannot overlap rendering; no transfer queue; errors hidden by `VK_CHECK_RESULT` in release            |
| Load image data straight into mapped staging memory        | Saves a heap copy and peak memory                                                 | Only when the caller defers loading; the staging size still comes from the file                       |
| C classes via macro-expanded fields and vtables            | KTX 1 and 2 behind one API in C, bindings for JS, Java and Python                 | No compile-time specialisation; per-format behaviour is `switch` code                                 |
| Validator as a separate C++ reader that also runs `libktx` | Conformance checking independent of the library; differential warning on mismatch | Two implementations to keep in step; the validator inherits the library's allocation when it calls it |

## Sources

- KTX-Software at the pinned revision: [`texture2.c`][construct], [`checkheader.c`][check-header2],
  [`vkloader.c`][vk-upload], [`basis_transcode.cpp`][transcode-etc1s], [`writer2.c`][deflate-zstd],
  [`ktx.h`][create-mem], [`ktxvulkan.h`][vk-texture], [`validate.cpp`][validate-order],
  [`validation_messages.h`][issues]; [KTX-Software-CTS][cts] and its [README][cts-readme].
- [KTX File Format Specification 2.0][ktx2-spec] (Document Revision 4) and the
  [Khronos Data Format Specification][kdfs].
- This catalog's [GPU texture compression][p-texture], [hostile-input][p-hostile] and
  [storage-to-GPU][p-gpu-decode] paper threads.
- Probes run for this page (see the note under the metadata table).

<!-- References -->

[repo]: https://github.com/KhronosGroup/KTX-Software
[readme]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/README.md#L19
[license]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/LICENSE.md
[release-notes]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/RELEASE_NOTES.md#L5-L17
[mainpage]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/libktx_mainpage.md#L9-L15
[gitmodules]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/.gitmodules
[ci-asan]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/.github/workflows/linux.yml#L71-L88
[cmake-options]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/CMakeLists.txt#L51-L75
[cmake-basisu]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/CMakeLists.txt#L517-L524
[cmake-std]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/CMakeLists.txt#L291-L294
[ident]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/ktxint.h#L39-L40
[header2]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/ktxint.h#L110-L127
[levelidx]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/ktxint.h#L134-L140
[keys]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L119-L139
[classdefn]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L260-L281
[vtbl]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L517-L555
[ss-enum]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L713-L724
[tex2-struct]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L734-L744
[stream]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L911-L934
[create-mem]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L1153-L1156
[threadcount]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L1370-L1480
[ttf-enum]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktx.h#L1657-L1800
[vk-funcs]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktxvulkan.h#L63-L96
[vk-texture]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktxvulkan.h#L107-L129
[suballoc]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/include/ktxvulkan.h#L131-L151
[check-header2]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/checkheader.c#L185-L308
[memstream-read]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/memstream.c#L239-L258
[init-dfd]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L258-L380
[private]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.h#L33-L47
[ub-comment]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L298-L302
[construct]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L699-L1135
[bounds]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L778-L826
[dfd-read]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L828-L950
[kvd]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L952-L1061
[anim]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L1026-L1048
[sgd]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L1063-L1114
[doc-noload]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L1143-L1146
[align]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L1790-L1858
[colour-get]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L2022-L2115
[size-uncompressed]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L2252-L2289
[iterate-load]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L2450-L2638
[load-int]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L2687-L2800
[inflate-zstd]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L2905-L3004
[inflate-zlib]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/texture2.c#L3023-L3100
[deflate-zstd]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/writer2.c#L797-L860
[miniz]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/miniz_wrapper.cpp#L129-L140
[transcode-main]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/basis_transcode.cpp#L183-L482
[transcode-init]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/basis_transcode.cpp#L422-L437
[transcode-etc1s]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/basis_transcode.cpp#L546-L724
[fixme]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/basis_transcode.cpp#L586-L594
[vk-check]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/vkloader.c#L42-L63
[vk-region]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/vkloader.c#L451-L483
[vk-upload]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/vkloader.c#L824-L1462
[vk-format-query]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/vkloader.c#L925-L975
[vk-staging]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/vkloader.c#L1018-L1180
[vk-fence]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/lib/src/vkloader.c#L1285-L1313
[tools-ktx]: https://github.com/KhronosGroup/KTX-Software/tree/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx
[validate-order]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validate.cpp#L374-L395
[validate-level]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validate.cpp#L650-L742
[validate-kvd]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validate.cpp#L1415-L1430
[validate-create]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validate.cpp#L1884-L1925
[issues]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validation_messages.h#L17-L64
[nonconformant]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validation_messages.h#L317-L320
[dfd-issues]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/validation_messages.h#L366-L384
[validate-help]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tools/ktx/command_validate.cpp#L27-L40
[threadtests]: https://github.com/KhronosGroup/KTX-Software/blob/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tests/threadtests/threadtests.cc#L14-L24
[tests-dir]: https://github.com/KhronosGroup/KTX-Software/tree/d9b1dd090f4df6b998bfcd9d6a38b21e94f3c4c6/tests
[cts]: https://github.com/KhronosGroup/KTX-Software-CTS/tree/8465c99944b0e4392fb4de6de47932262e4c2826
[cts-readme]: https://github.com/KhronosGroup/KTX-Software-CTS/blob/8465c99944b0e4392fb4de6de47932262e4c2826/README.md#L8-L42
[libktx-docs]: https://github.khronos.org/KTX-Software/libktx/
[ktx2-spec]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html
[spec-identifier]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_identifier
[spec-scheme]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_supercompressionscheme
[spec-dfd]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_data_format_descriptor
[spec-vkformat]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_vkformat
[spec-levelimages]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#levelImages
[spec-mip]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_mip_level_array
[spec-bgd]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#basislz_gd
[spec-iana]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html#_iana_media_type_registration_information
[kdfs]: https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html
[c-block]: ./concepts.md#block-compressed-formats-and-supercompression
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-suspend]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[c-cicp]: ./concepts.md#cicp
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-external]: ./concepts.md#external-memory-and-zero-copy-import
[c-gpudecomp]: ./concepts.md#gpu-decompression
[bl-vk]: ./baseline/vulkan.md
[bl-eh]: ./baseline/event-horizon.md
[bl-wired]: ./baseline/wired.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-existing]: ./baseline/existing-code.md
[p-texture]: ./papers/gpu-texture-compression.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
[hw-formats]: ./hardware/index.md#texture-and-ycbcr-formats
[index-video]: ./index.md#video-subjects
[libspng]: ./libspng.md
[wuffs]: ./wuffs.md
