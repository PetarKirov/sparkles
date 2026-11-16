# libheif (C++)

The reference open-source reader and writer for HEIF and its relatives: one ISOBMFF item model (`heif_context`, image handles, grids, overlays, auxiliary images) in front of a priority-ranked set of codec plugins for HEVC, AV1, VVC, AVC, JPEG, JPEG 2000 and the built-in ISO/IEC 23001-17 uncompressed codec, guarded by a versioned `heif_security_limits` struct and per-decode amplification budgets.

| Field         | Value                                                                                                                                   |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++20 core behind a C API (`libheif/api/libheif/*.h`); a header-only C++ wrapper (`heif_cxx.h`)                                         |
| License       | LGPL-3.0-or-later for the library (file headers); MIT for the sample applications and the Go and C++ wrappers ([`COPYING`][copying])    |
| Repository    | [strukturag/libheif][repo] (version 1.23.7 in [`CMakeLists.txt`][cmake])                                                                |
| Revision read | `12a259a5882dd99d45ec5fc77e296a3b620d1e2e` (October 26, 2026)                                                                           |
| Documentation | [`README.md`][readme]; the public headers; [`SECURITY.md`][security]; the scanner threat model [`.oss-scanner/threat_model.md`][threat] |
| Category      | Formats: container (ISOBMFF) plus codec dispatch                                                                                        |
| Tier          | B                                                                                                                                       |
| Last reviewed | November 7, 2026                                                                                                                        |

> [!NOTE]
> Every quote was read with `git show 12a259a58:<path>` and every cited path checked with `git cat-file -e`. Claims marked **verified** were run in `/tmp/libheif-demo`: the pinned tree was built with CMake and GCC 14.3.0 from `nix-shell` (built-in `libde265` and `dav1d` back ends, `WITH_UNCOMPRESSED_CODEC=ON`, plugin loading off), and a 60-line C program and `heif-info` were run against it. The verification pass rebuilt the pinned tree from `git archive` with the same options (GCC from `nix-shell`, `libde265` 1.0.18, `dav1d` 1.5.2) and reran both, with two more nesting depths and a stride probe added. Everything else is documented, not run.

## Overview

### What it solves

HEIF (ISO/IEC 23008-12) is not a codec but a [container](./concepts.md#container-and-bitstream): an ISOBMFF file whose `meta` box describes a graph of items (coded images, derived images, metadata) with properties attached through `ipma`, and whose coded bytes sit in `mdat` or `idat`. AVIF is the same container with AV1 payloads. libheif implements the container once and hands the payload to whichever codec library is installed:

> libheif is an ISO/IEC 23008-12 HEIF and AVIF (AV1 Image File Format) file format decoder and encoder. [...] On top of HEIC and AVIF, libheif also supports HEIF images coded with VVC, AVC, JPEG, JPEG-2000, and ISO/IEC 23001-17. ([`README.md`][readme-intro])

The supported-feature list covers alpha, depth and thumbnail auxiliary images, multiple images per file, image sequences and MP4 video, tiled images with per-tile decode, HDR with colour profiles, crop/mirror/rotate transformations, overlays, EXIF and XMP, region annotations, and streaming through a data-reader interface ([`README.md`][readme-features]).

### Design philosophy

Two commitments run through the tree. The first is one decode API for every payload: "The decoder automatically supports both HEIF and AVIF (and the other compression formats) through the same API" ([`README.md`][readme-api]). The second, now dominant, is treating the container itself as the attack surface. The security policy explains why:

> **Flexibility.** A file is a graph of boxes and items that reference each other [...] Almost every feature can be combined with almost every other feature, references can be nested and shared, and the decoder has to detect cycles, duplicated references and amplification through reference chains, none of which the specification forbids explicitly. ([`SECURITY.md`][security-why])

and, on the codec seam:

> **Multiple codecs behind one container.** The container makes claims (dimensions, chroma format, bit depth, color information) that the embedded HEVC, AV1, JPEG, JPEG 2000 or VVC bitstream may contradict. libheif has to reconcile both before any pixel buffer is touched. ([`SECURITY.md`][security-why])

The README's status note puts a number on the cost: "89 security advisories had to be investigated, fixed and released in 2026 alone", by "a single independent developer" ([`README.md`][readme-status]).

## How it works

### Reading: stream, ranges, boxes

Input arrives through a `StreamReader` (`StreamReader_istream`, `StreamReader_memory`, or `StreamReader_CApi` wrapping a caller's `heif_reader` callbacks). Box parsing never touches the stream directly; it reads through a `BitstreamRange`, which knows its parent range, its remaining byte count and its nesting depth ([`bitstream.h`][bitstream-range]). A short read sets a sticky error flag and zeroes the remaining count up the parent chain (`set_eof_while_reading`), so a parser reads a run of fields and checks `range.error()` once.

`Box::read` parses a header, switches on the four-character code, with 106 `case` labels (a few behind build options), to construct the box class (an unknown type becomes `Box_other`), then applies the structural checks before calling the box's own `parse` ([`box.cc`][box-read]):

```cpp
if (range.get_nesting_level() > MAX_BOX_NESTING_LEVEL) {
  return Error(heif_error_Memory_allocation_error,
               heif_suberror_Security_limit_exceeded,
               "Security limit for maximum nesting of boxes has been exceeded");
}
// ... box size >= header size, fits int64, fits the parent range ...
BitstreamRange boxrange(range.get_istream(), box_size_without_header, &range);
err = box->parse(boxrange, limits);
boxrange.skip_to_end_of_box();
```

A box whose `parse` fails is replaced by a `Box_Error` that records the error and a `parse_error_fatality` of `fatal`, `ignorable` or `optional` ([`box.h`][box-fatality]). The default is `fatal`; in `box.h` the transformations (`irot`, `imir`, `clap`, `iscl`), `pymd` and the GIMI content-id box are `ignorable`, and descriptive properties (`pixi`, `pasp`, `lsel`, `clli`, `mdcv`, `amve`, `cclv`, `ndwt`, `cmin`, `cmex`, `udes`, `elng`) are `optional`, so a file with a broken optional property still opens. `read_children` caps the number of children at `max_items` for `iinf` and `max_children_per_box` for everything else, and rejects a declared count larger than the remaining bytes could hold ([`box.cc`][box-children]).

**Verified** (and reproduced in the verification pass): `heif-info -d` on the fuzzing-corpus file `colors-with-alpha-thumbnail.heic` prints the box tree. Its `iref` box is the whole item graph of a HEIC with an alpha plane and a thumbnail that has its own alpha:

```text
| Box: iref ----- (Item Reference)
| size: 54   (header size: 12)
| reference with type 'auxl' from ID: 2 to IDs: 1
| reference with type 'auxl' from ID: 4 to IDs: 3
| reference with type 'thmb' from ID: 3 to IDs: 1
```

### The item model: `heif_context` and image handles

`HeifContext` interprets the parsed `HeifFile` into `ImageItem` objects. The factory switches on the `infe` item type: `hvc1`, `av01`, `vvc1`, `avc1`, `jpeg` (or a `mime` item of type `image/jpeg`), `j2k1` and `unci` (an `ImageItem_Error` when built without `WITH_UNCOMPRESSED_CODEC`) are coded items; `grid`, `iovl` and `iden` are derived items; `mski` is a mask; `tili` is behind `HEIF_ENABLE_EXPERIMENTAL_FEATURES`; `lhv1` (layered HEVC) becomes an `ImageItem_Error` that says it is unsupported; any other type returns `nullptr` and is skipped ([`image_item.cc`][item-factory]). The context then walks `iref`: a `thmb` reference attaches a thumbnail to its master, and an `auxl` reference with an `auxC` URN attaches alpha (`urn:mpeg:hevc:2015:auxid:1`, `urn:mpeg:avc:2015:auxid:1`, or MIAF's `urn:mpeg:mpegB:cicp:systems:auxiliary:alpha`) or depth, rejecting non-existing and recursive targets ([`context.cc`][ctx-aux]). A `prem` reference sets the premultiplied-alpha flag ([`context.cc`][ctx-prem]).

The C API exposes this as opaque structs that hold `shared_ptr`s: a `heif_image_handle` holds both the `ImageItem` and its `HeifContext` "to keep the context alive while we are using the handle" ([`api_structs.h`][api-structs]). The caller sees three lifetimes: the context (the file), handles (items), and `heif_image` (decoded pixels), each released separately as in the README's loading example ([`README.md`][readme-api]).

### Decoding: one entry, a traversal state, then colour conversion

`HeifContext::decode_image` is the single top-level entry. It first runs `verify_decodable`, which rejects a cycle in the graph of `dimg` and `auxl` edges, because "A reference cycle would otherwise let two parallel grid-tile workers take two item mutexes in opposite order and deadlock (GHSA-prgh-72vc-3xmc)" ([`image_item.h`][item-decode]). Cycles are not rejected at load, "so that a file's independently valid items stay decodable". It then seeds a `DecodeTraversalState` and calls `ImageItem::decode_image`, which recurses through derived items, applies the transformative properties, checks the decoded size against `ispe`, and finally converts to the requested `heif_colorspace` and `heif_chroma` ([`context.cc`][ctx-decode]).

A grid (`ImageGrid::parse`) is 8 or 12 bytes: version, a flag selecting 16- or 32-bit output dimensions, rows and columns stored minus one ([`grid.cc`][grid-parse]). With `ENABLE_PARALLEL_TILE_DECODING`, tiles are decoded with `std::async(std::launch::async, ...)`, at most `get_max_decoding_threads()` in flight, each pasting into the shared output image; the first error drains the remaining futures ([`grid.cc`][grid-threads]). The public [tiling](./concepts.md#tiling) API (`heif_image_handle_get_image_tiling`, `heif_image_handle_decode_image_tile`) describes grids, `tili` items and tiled `unci` items uniformly, in tile indices, optionally in transformed coordinates ([`heif_tiling.h`][tiling-h]).

### Codec plugins

A decoder is a `heif_decoder_plugin` struct of function pointers with a `plugin_api_version`; each version appends fields, and the header carries a release table and a minimum accepted version (`heif_decoder_plugin_minimum_version 5`, latest 6) ([`heif_plugin.h`][plugin-h]). The lifecycle is `new_decoder2` with options, one or more `push_data2` calls, `flush_data`, then `decode_next_image2`, which returns a `heif_image` built through the public API. Version 6 added the limits to the options:

```c
typedef struct heif_decoder_plugin_options
{
  heif_compression_format format;
  int strict_decoding; // bool
  int num_threads; // 0 - undefined, use decoder default

  // --- added in plugin_api_version 6 ---
  // Security limits the plugin must enforce for image allocations during decoding.
  // The pointee must outlive the decoder instance (typically the context's limits).
  // Only read by plugins reporting plugin_api_version >= 6.
  const heif_security_limits* limits;

} heif_decoder_plugin_options;
```

Selection is by priority: `does_support_format` returns 0 for "cannot" or a priority (100 by default), the highest wins, and a caller can force a back end by `id_name` through `heif_decoding_options::decoder_id` ([`plugin_registry.cc`][registry]). The dav1d glue shows how limits cross into a codec: it copies `max_image_size_pixels` into `Dav1dSettings::frame_size_limit` and passes `num_threads` through ([`decoder_dav1d.cc`][dav1d]). Plugins are compiled in or loaded at run time (`ENABLE_PLUGIN_LOADING`, `plugins_unix.cc`, `plugins_windows.cc`); the README's codec table lists libde265 for HEIC, libaom and dav1d for AVIF, vvdec for VVC, openh264 for AVC, libjpeg(-turbo) for JPEG and OpenJPEG for JPEG 2000 and HTJ2K, with FFmpeg as an alternative decoder for every one of them ([`README.md`][readme-features]).

## Analysis

### 1. Pixel and memory model

`HeifPixelImage` is a set of planes keyed by `heif_channel` (`Y`, `Cb`, `Cr`, `R`, `G`, `B`, `Alpha`, `interleaved`, filter-array and others) plus a colourspace and a chroma tag. Each plane's `ComponentStorage` records a datatype, a logical bit depth "1-256", the interleaved component count, the visible size and a separately allocated memory size, and a [stride](./concepts.md#stride) ([`pixelimage.h`][pix-storage]). The allocated width is the visible width rounded up to an even number and to at least 64 pixels ([`pixelimage.cc`][pix-round]); the row is then padded to 16 bytes, "use 16 byte alignment (enough for 128 bit data-types)", and a stride that comes out as a multiple of 512 bytes gets one extra 64-byte cache line so that consecutive rows do not map to the same L1 set ([`pixelimage.cc`][pix-align]). The allocation is zero-filled (`calloc`) so padding is never uninitialised. **Verified:** a 72 by 72 image decoded to `heif_chroma_interleaved_RGBA` reports a stride of 288 bytes (72 times 4, already a multiple of 16). The verification pass created interleaved RGBA images with `heif_image_add_plane` and read back strides of 256 bytes for width 2 (the 64-pixel minimum), 576 for width 128 (512 plus 64) and 1088 for width 256. The model is [planar](./concepts.md#plane) first, with [subsampled chroma](./concepts.md#chroma-subsampling) planes carrying their own size, because that is what HEVC and AV1 decoders emit; interleaved RGB is one of several output targets of colour conversion.

### 2. Genericity mechanism

Run-time tags and virtual dispatch, not templates. A pixel image is described by the `heif_colorspace`, `heif_chroma` and `heif_channel` enums plus a per-plane bit depth and `heif_component_datatype`; the codec seam is the `heif_decoder_plugin` function-pointer table; items are a class hierarchy (`ImageItem_HEVC`, `ImageItem_Grid`, ...) chosen by item type; colour conversion is a pool of `ColorConversionOperation` subclasses whose virtual `state_after_conversion` reports the reachable states and costs ([`colorconversion.h`][color-op]). Templates appear inside kernels, instantiated per sample type (`Op_YCbCr444_to_YCbCr420_average<uint8_t>` and `<uint16_t>`, [`colorconversion.cc`][color-ops-pool]). Nothing is specialised on a pixel type at the API level.

### 3. Colour and metadata

Colour arrives as `colr` properties of two kinds: `nclx` ([CICP](./concepts.md#cicp) primaries, transfer, matrix and full-range flag) and `rICC`/`prof` ([ICC](./concepts.md#icc-profile) bytes). An image may carry both, and the old single-answer query admits it: "If there is an ICC profile and an NCLX profile, the ICC profile is returned. TODO: we need a new API for this function as images can contain both NCLX and ICC at the same time" ([`heif_color.h`][color-type]); the same comment points to `heif_image_handle_get_raw_color_profile` and `heif_image_handle_get_nclx_color_profile` for reading both. The `nclx` struct stores the four code points and, read-only, the decoded primaries' chromaticities ([`heif_color.h`][color-nclx]).

libheif uses CICP to compute pixels but treats ICC as payload: a `grep` for `lcms`, `cmsCreate` or `skcms` in `libheif/` finds nothing, so ICC bytes are returned raw to the application. CICP drives only the YCbCr matrix and range: no registered operator converts between primaries or transfer curves (the operators are YCbCr/RGB matrix steps, chroma resampling, alpha handling, Bayer demosaicing and bit-depth shifts), `ColorState::operator==` compares the `nclx` only for YCbCr states ([`colorconversion.cc`][color-eq]), and HDR-to-8-bit is a bit shift, not tone mapping. The decode-options comment that libheif converts "YCbCr matrix, primaries, range" to the requested `nclx` therefore holds for the matrix and range only. Conversion is a graph search. `ColorState` holds colourspace, chroma, a bit depth per plane and an `nclx` ([`colorconversion.h`][color-state]); `ColorConversionPipeline::construct_pipeline` runs "Dijkstra search for the minimum-cost conversion pipeline" over registered `ColorConversionOperation`s, each declaring its output state and a speed cost ([`colorconversion.cc`][color-dijkstra]). The decode options choose the target `nclx` (default sRGB), chroma up- and down-sampling filters (sharp YUV is a down-sampling choice, used when encoding RGB to 4:2:0), HDR-to-8-bit reduction, and an `autocorrect_broken_input` switch for files whose `colr` range disagrees with the HEVC VUI ([`heif_decoding.h`][decoding-options]). [Image metadata](./concepts.md#image-metadata) (EXIF, XMP, MIME items) is exposed as raw blocks by item id; compressed metadata items are accounted against the memory limits only when read (tested by [`decompression_bomb.cc`][test-bomb]). HDR gain maps appear only as fields of the low-overhead `mini` box ([`mini.h`][mini]), and a search of the whole tree finds `tmap` and `gainmap` nowhere else in `libheif/`, so nothing consumes those fields; the item factory has no `tmap` derived image, whereas [libavif](./libavif.md) parses `tmap` into an `avifGainMap` ([`read.c`][avif-tmap]).

### 4. I/O and codec architecture

The architecture is a container front end and a codec back end joined by a narrow push interface: libheif extracts the bitstream, pushes it into a plugin, and receives a `heif_image`. `Decoder::get_compressed_data` prepends the codec configuration (`read_bitstream_configuration_data`: the headers stored in `hvcC`, `avcC`, `vvcC` or `av1C`, and a JPEG item's `jpgC` data; JPEG 2000 has none) to the item data; a still image always gets it, a sequence only with its first sample ([`decoder.cc`][decoder-cfg]). Container claims are reconciled with the codec on both sides of the push. Before it, `get_max_coded_image_size` scans the buffer about to be pushed for the coded size (the SPS, the AV1 sequence header OBU, the JPEG SOF, the JPEG 2000 SIZ) and checks it against the limits, and more than eight coded pictures in one decode are refused ([`decoder.cc`][decoder-scan]); `tighten_image_size_limit_for_ispe` lowers the plugin's size limit to the declared `ispe` plus one coding unit per axis (128 for AV1 and VVC, 64 for HEVC, 64 for AVC, JPEG, JPEG 2000 and HTJ2K to cover FFmpeg's stride rounding), with a floor of 65 536 pixels (256 by 256) for hardware encoders that pad tiny images ([`security_limits.cc`][limits-tighten], [`security_limits.h`][limits-tighten-h]). After it, `check_decoded_image_size` validates the output against `ispe` before any transform.

I/O is pull-by-callback, not suspendable. A caller-supplied `heif_reader` implements `read`, `seek` and `wait_for_file_size`; version 2 adds `request_range`, `preload_range_hint` and `release_file_range` so a network reader can fetch only the byte ranges a tile needs ([`heif_context.h`][reader]). The parser blocks inside these callbacks; there is no "need more data, call again" state (see [push and pull](./concepts.md#push-and-pull-decoding) and [suspendable decoding](./concepts.md#incremental-progressive-and-suspendable-decoding)). [libavif](./libavif.md) also pulls by callback (`avifIO::read(offset, size)` returning a borrowed span, [`avif.h`][avif-io]), but its callback may return `AVIF_RESULT_WAITING_ON_IO` for a range that has not arrived, and the decoder passes that result to the caller, who calls again later; it parses each box from an in-memory `(raw, rawLen)` slice with one hand-written function per box in a single `read.c`, and handles AV1 payloads only (plus experimental AV2 through AVM). libheif's class-per-box parser and plugin table are what let one front end serve seven codecs (six coded families and the uncompressed codec). Contrast [Wuffs](./wuffs.md), whose coroutine decoders suspend.

### 5. Hostile input and safety

This is where libheif teaches most. Limits live in one C struct, `heif_security_limits`, with a `version` byte and fields grouped by the release that added them ([`heif_security.h`][sec-h]); 0 disables a limit, a global default set is read-only, and each context gets a mutable copy. The defaults ([`security_limits.cc`][limits-defaults]):

| Field                              | Default       | Field                       | Default    |
| ---------------------------------- | ------------- | --------------------------- | ---------- |
| `max_image_size_pixels`            | 32768 × 32768 | `max_items`                 | 1000       |
| `max_number_of_tiles`              | 4096 × 4096   | `max_children_per_box`      | 100        |
| `max_memory_block_size`            | 4 GiB         | `max_iloc_extents_per_item` | 32         |
| `max_total_memory`                 | 4 GiB         | `max_color_profile_size`    | 100 MiB    |
| `max_components`                   | 256           | `max_sequence_frames`       | 18 000 000 |
| `max_iso23001_17_pixel_size_bytes` | 256           | `max_bad_pixels`            | 1000       |

Beyond the struct sit compile-time constants: `MAX_BOX_NESTING_LEVEL = 20` (against stack exhaustion), `MAX_OVERLAY_NESTING_LEVEL = 3`, `MAX_TRANSFORMATIONS_PER_DECODE_PATH = 32`, and `MAX_OVERLAY_IMAGES = 5`, which the source calls "a hardcoded stopgap until a configurable security-limit field can be added to heif_security_limits in the next major release" ([`security_limits.h`][limits-consts]). The eight-coded-picture cap in `decoder.cc` is another such constant: "v1.23.x cannot extend the public security-limits struct" ([`decoder.cc`][decoder-scan]). The distinctive part is that limits bound **work**, not just size. A `DecodeTraversalState` travels down every decode path with a per-path cycle set, overlay and transformation counters, and two shared budgets: an atomic count of sub-image decodes (at most `2 × max_items`), and a `DecodePixelBudget` capping total decoded pixels at twice the summed size of the distinct items involved, that sum counted as at least 2048 × 2048 pixels and at most `max_image_size_pixels` ([`security_limits.h`][traversal]). The comment motivating it is a concrete attack: "A grid of 660 1x1 tiles, each the same 'clap' of a 16384x16384 overlay canvas, stays within the decode-operation budget but builds the canvas 660 times" ([`security_limits.h`][limits-consts]). Memory is accounted through `MemoryHandle`, which checks `count * element_size` for overflow, then the per-block cap, then a per-context running total kept in a mutex-guarded global map ([`security_limits.cc`][memhandle]); total-memory accounting applies to a context's own limits, not to the global set.

**Verified** (`/tmp/libheif-demo/prog/limits_demo.c`, rerun in the verification pass with depths 20, 21 and 22 added):

```text
global: version=4 max_image_size_pixels=1073741824 max_items=1000 max_children_per_box=100 max_total_memory=4294967296
read, 19 nested 'dinf' boxes       code=2 subcode=111: Invalid input: No 'iinf' box
read, 20 nested 'dinf' boxes       code=2 subcode=111: Invalid input: No 'iinf' box
read, 21 nested 'dinf' boxes       code=6 subcode=1000: Memory allocation error: Security limit exceeded: Security limit for maximum nesting of boxes has been exceeded
read, 22 nested 'dinf' boxes       code=6 subcode=1000: Memory allocation error: Security limit exceeded: Security limit for maximum nesting of boxes has been exceeded
read, 25 nested 'dinf' boxes       code=6 subcode=1000: Memory allocation error: Security limit exceeded: Security limit for maximum nesting of boxes has been exceeded
decode, global limits              code=0 subcode=0: Success
  -> 72x72 RGBA, stride 288, first pixel 255,2,0,217
decode, max_image_size_pixels=5112 code=6 subcode=1000: Memory allocation error: Security limit exceeded: Image size 72x72 exceeds the maximum image size 5112
```

The crafted file is an `ftyp` plus a `meta` holding N nested `dinf` boxes: up to 20 the structure parses and fails only on the missing `iinf`; from 21 the nesting limit fires, matching `MAX_BOX_NESTING_LEVEL = 20`. The same 72 by 72 HEIC decodes with the defaults and is refused when the context's limit is lowered to 72 × 71 pixels. Errors are a `heif_error` triple (`code`, `subcode`, message); violations of the configurable limits share `heif_suberror_Security_limit_exceeded`, while some hard-coded checks use other codes (the eight-picture cap reports `heif_error_Invalid_input` with `heif_suberror_Unspecified`). For comparison, [libavif](./libavif.md) exposes three limits on its decoder (`imageSizeLimit` defaulting to 16384 × 16384, `imageDimensionLimit` 32768, `imageCountLimit` 12 hours at 60 fps) ([`avif.h`][avif-limits]); its reader handles only the `grid` and `sato` derived items, not `iovl` or `iden`, and has no derived-image amplification budget.

See [hostile input](./concepts.md#hostile-input) and the [hostile-input papers](./papers/hostile-input-safety.md).

### 6. Allocation and ownership

Ownership is `shared_ptr` throughout: items, boxes, pixel images, and the C handles that wrap them. Allocations of pixel memory go through `MemoryHandle` so that every large buffer is attributable to a context's budget; plugins allocate their output planes through `heif_image_add_plane_safe(..., limits)` so the decoded frame is charged the same way ([`decoder_dav1d.cc`][dav1d-plane]). What libheif cannot charge is the codec library's own internal buffers, which is why the file fuzzer additionally caps the image size: "the codec libraries allocate their frame buffers before libheif sees anything (dav1d needs ~12.5 bytes/pixel for a frame header alone)" ([`file_fuzzer.cc`][fuzz-file]).

### 7. CPU parallelism and SIMD

Parallelism is coarse: grid tiles on `std::async` threads up to a context-wide maximum, and a `num_codec_threads` hint passed to plugins. The shared `DecodeTraversalState` budgets are atomics or mutex-guarded for exactly this reason. Pixel kernels in `color-conversion/` are plain C++ (a `grep` for x86 or NEON intrinsics in `libheif/` finds none); SIMD lives in the codec libraries and, optionally, in `libsharpyuv` for sharp RGB-to-YUV.

### 8. GPU offload and interop

Not applicable. The tree has no GPU path: a search of `libheif/` for Vulkan, CUDA, OpenGL, Metal, VA-API or FFmpeg hardware-device setup finds nothing. Decoded images are CPU `HeifPixelImage` planes, and any hardware decode would have to sit inside a codec plugin, which none of the in-tree plugins does.

### 9. Temporal, animation and containers

The same context reads `moov`/`trak` sequences (`libheif/sequences/`): `heif_context_get_track`, `heif_track_decode_next_image`, raw-sample access, sample auxiliary info and TAI timestamps ([`heif_sequences.h`][seq]). Edit lists are applied by default, with one sharp consequence documented in the header: "iterating until end-of-sequence on an infinite-loop file therefore never terminates", so a client should set `ignore_sequence_editlist` and loop itself ([`heif_sequences.h`][seq-loop]). Still images and tracks share one plugin path (`push_data2`, `decode_next_image2` with a `user_data` tag per sample), and plugin API version 5 added `flush_data` and the per-sample `user_data` tags for that purpose ([`heif_plugin.h`][plugin-h]).

### 10. Testing and conformance

Testing is regression-driven. `tests/` holds 129 `.cc` files on Catch2, many named after a fixed defect (`alpha_cycle_deadlock.cc`, `overlay_amplification.cc`, `transformation_amplification.cc`, `decompression_bomb.cc`, `sequence_timing_overflow.cc`); many build their hostile file in code. `fuzzing/` has seven libFuzzer targets (file, box, API, colour conversion, encoder, sequence, tile) with a seed corpus that includes minimised ClusterFuzz cases and named crash reproducers; [`cifuzz.yml`][cifuzz] runs them on pull requests and weekly under address, undefined-behaviour and memory sanitizers on x86_64 and address on i386. There is no external conformance corpus in the tree. [zune-image](./zune-image.md) treats libheif 1.17 as its byte-exact oracle for HEIC.

## Lessons for Sparkles

- **Q4** A container and its payload codecs are separable layers with a narrow seam (push bytes, get planes). An ISOBMFF item model in D could serve HEIF, AVIF and MP4-family stills the way libheif does, with codec back ends behind it. Which back ends are native D and which are ImportC is a separate question.
- **Q4** The `heif_reader` range callbacks (`request_range`, `preload_range_hint`, `release_file_range`) are the right vocabulary for tile-on-demand from a slow source, but they block. A suspendable parser (Wuffs-style, libavif's `AVIF_RESULT_WAITING_ON_IO` restart, or a D fiber on `sparkles:event-horizon`) would need the same three hints expressed as returned I/O requests rather than callbacks.
- **Q4, Q8** The parse tolerance table (`fatal`, `ignorable`, `optional` per box type) is a cheap, explicit policy for real-world files. A proposal, not something the [wired baseline](./baseline/wired.md) offers today (it has no binary backend): a `sparkles:wired` description of boxes could carry it as a per-box attribute.
- **Q8** Limits must bound work as well as bytes. Reference graphs need cycle detection at decode time, a shared decode-count budget and a decoded-pixel budget, all threaded through recursion and across worker threads. Today's Sparkles PNG decoders bound only declared size ([baseline G7](./baseline/existing-code.md)).
- **Q8** Put limits in one versioned, extensible structure from the start. libheif's ABI-frozen struct forced compile-time stopgaps (`MAX_OVERLAY_IMAGES`, the eight-coded-picture cap) and a deferred MIAF check; a D struct with defaulted fields and named arguments avoids the freeze but still needs a policy for which limits are per-context and which are global.
- **Q8** A size claimed by the container should tighten the limit handed to the codec (the `ispe`-plus-coding-unit rule), because the codec allocates before the container can check its output; libheif also reads the coded size out of the bitstream headers and checks it before pushing a byte.
- **Q5** Carry CICP and ICC side by side and never pick one silently; libheif's own header marks its single-answer query as needing a new API and sends callers to two separate getters. Gain maps are an item relationship (`tmap`) and need a place in the item model even if the first reader ignores them.
- **Q1** A plane map keyed by channel, with per-plane bit depth and size and 16-byte row alignment (plus libheif's 512-byte stride skew), covers HEVC/AV1 output, alpha and depth as separate images, and 23001-17's arbitrary components. Whether that maps onto mir `Slice` per plane is open.
- **Q9** libheif is evidence that a format container library naturally depends on many codec libraries but on no colour engine and no image algorithms; container parsing, codecs and colour management are three different dependency footprints.

## Strengths

- One API decodes six coded payload families (HEVC, AV1, VVC, AVC, JPEG, JPEG 2000 with HTJ2K) and the uncompressed codec, with grids, overlays, `iden`, alpha, depth, thumbnails and sequences handled uniformly.
- The most explicit hostile-input design of any container library surveyed: versioned limits, per-context memory accounting, decode-count and decoded-pixel budgets, decode-time cycle checks.
- Plugin ABI with version table and priority selection; limits passed into plugins.
- Range-aware reader interface for partial, tile-on-demand loading.
- Regression tests and fuzz corpus record each advisory as a reproducible file.

## Weaknesses

- Size and age of the attack surface: 89 advisories in 2026, one maintainer ([`README.md`][readme-status]).
- C ABI freeze pushes new limits into hard-coded constants and delays checks (MIAF derivation constraints, `TODO(v1.24.x)` in [`image_item.cc`][verify]; the eight-coded-picture cap in [`decoder.cc`][decoder-scan]).
- Blocking reader callbacks; no suspendable parse.
- No colour management: ICC is passed through and no operator converts primaries or transfer curves; the colour-profile type query returns one profile where two may exist (separate getters read both).
- Codec-internal allocations escape the memory budget; safety ultimately depends on whichever codec versions a distribution ships.
- LGPL licensing constrains static linking for some consumers.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                    | Trade-off                                                                                   |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| One container front end, codecs behind a plugin table  | HEIF, AVIF and the other payloads share one item model and one decode API    | Safety depends on every codec version a distribution ships; codec buffers escape the budget |
| Limits in one versioned C struct, per-context copies   | Callers tune limits per file; new fields append without breaking old callers | Point releases cannot add fields, so new limits arrive as hard-coded constants first        |
| Work budgets (decode count, decoded pixels) per decode | Reference graphs amplify work without exceeding any size limit               | Budget factors are heuristics (2 times `max_items`, 2 times distinct pixels)                |
| Cycle check at decode time, not at load                | Independently valid items in a file with a cycle stay decodable              | Every top-level decode re-walks the reference graph                                         |
| Per-box parse fatality levels                          | Real-world files with a broken optional property still open                  | Tolerance policy is spread across `get_parse_error_fatality` overrides                      |
| Blocking `heif_reader` callbacks with range hints      | Simple to implement; a network reader can still fetch only a tile's ranges   | No suspend and resume; an async caller needs a thread per decode                            |
| Colour conversion as a Dijkstra search over operators  | Any input state reaches any target without hand-written pairwise paths       | No ICC or primaries conversion; CICP only selects matrix and range                          |

## Sources

- [strukturag/libheif][repo] at `12a259a5882dd99d45ec5fc77e296a3b620d1e2e`: [`README.md`][readme], [`SECURITY.md`][security], [`.oss-scanner/threat_model.md`][threat], [`libheif/box.cc`][box-read], [`libheif/box.h`][box-fatality], [`libheif/bitstream.h`][bitstream-range], [`libheif/context.cc`][ctx-decode], [`libheif/image-items/image_item.cc`][item-factory], [`libheif/image-items/grid.cc`][grid-parse], [`libheif/security_limits.h`][limits-consts], [`libheif/security_limits.cc`][limits-defaults], [`libheif/api/libheif/heif_security.h`][sec-h], [`heif_plugin.h`][plugin-h], [`heif_color.h`][color-type], [`heif_decoding.h`][decoding-options], [`heif_tiling.h`][tiling-h], [`heif_sequences.h`][seq], [`libheif/image/pixelimage.h`][pix-storage], [`libheif/color-conversion/colorconversion.cc`][color-dijkstra], [`libheif/codecs/decoder.cc`][decoder-cfg], [`libheif/color-conversion/colorconversion.h`][color-op], [`libheif/image/pixelimage.cc`][pix-align], [`libheif/plugins/decoder_dav1d.cc`][dav1d], [`fuzzing/file_fuzzer.cc`][fuzz-file], [`.github/workflows/cifuzz.yml`][cifuzz].
- [AOMediaCodec/libavif][avif-repo] at `9b07a9d7a874b159bb4e14b80a6f08bb469d06f7`, for the container comparison: [`include/avif/avif.h`][avif-limits] ([I/O contract][avif-io]), [`src/read.c`][avif-tmap].
- Demonstration: `/tmp/libheif-demo/prog/limits_demo.c` and `heif-info -d` on `fuzzing/data/corpus/colors-with-alpha-thumbnail.heic`, built from the pinned tree; rerun by the verification pass on an independent build, with extra nesting depths and a stride probe.
- Related pages: [concepts](./concepts.md), [libavif](./libavif.md), [Wuffs](./wuffs.md), [zune-image](./zune-image.md), [SAIL](./sail.md), [existing Sparkles image code](./baseline/existing-code.md), [`sparkles:event-horizon` baseline](./baseline/event-horizon.md), [wired baseline](./baseline/wired.md), [hostile-input papers](./papers/hostile-input-safety.md).

<!-- References -->

[repo]: https://github.com/strukturag/libheif/tree/12a259a5882dd99d45ec5fc77e296a3b620d1e2e
[cmake]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/CMakeLists.txt#L3
[readme]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/README.md
[readme-intro]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/README.md#L5-L16
[readme-status]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/README.md#L18-L21
[readme-features]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/README.md#L23-L49
[readme-api]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/README.md#L51-L82
[copying]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/COPYING#L1-L5
[security]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/SECURITY.md
[security-why]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/SECURITY.md#L8-L40
[threat]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/.oss-scanner/threat_model.md#L18-L66
[bitstream-range]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/bitstream.h#L276-L423
[box-read]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/box.cc#L466-L1024
[box-children]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/box.cc#L1107-L1135
[box-fatality]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/box.h#L186-L190
[item-factory]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image-items/image_item.cc#L196-L260
[verify]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image-items/image_item.cc#L1162-L1180
[item-decode]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image-items/image_item.h#L390-L425
[ctx-aux]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/context.cc#L882-L1000
[ctx-prem]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/context.cc#L1175-L1191
[ctx-decode]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/context.cc#L1460-L1560
[api-structs]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api_structs.h#L63-L104
[grid-parse]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image-items/grid.cc#L37-L76
[grid-threads]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image-items/grid.cc#L410-L464
[tiling-h]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_tiling.h#L37-L94
[plugin-h]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_plugin.h#L36-L169
[decoder-cfg]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/codecs/decoder.cc#L285-L317
[decoder-scan]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/codecs/decoder.cc#L585-L615
[registry]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/plugin_registry.cc#L262-L287
[dav1d]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/plugins/decoder_dav1d.cc#L96-L114
[dav1d-plane]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/plugins/decoder_dav1d.cc#L355-L365
[pix-storage]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image/pixelimage.h#L385-L434
[pix-round]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image/pixelimage.cc#L292-L301
[pix-align]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/image/pixelimage.cc#L489-L600
[color-type]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_color.h#L114-L129
[color-nclx]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_color.h#L195-L212
[color-op]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/color-conversion/colorconversion.h#L154-L175
[color-ops-pool]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/color-conversion/colorconversion.cc#L498-L543
[color-eq]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/color-conversion/colorconversion.cc#L419-L434
[color-state]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/color-conversion/colorconversion.h#L31-L53
[color-dijkstra]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/color-conversion/colorconversion.cc#L559-L710
[decoding-options]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_decoding.h#L63-L136
[mini]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/mini.h#L32-L118
[reader]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_context.h#L142-L234
[sec-h]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_security.h#L34-L108
[limits-defaults]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/security_limits.cc#L28-L67
[limits-tighten]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/security_limits.cc#L76-L129
[memhandle]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/security_limits.cc#L258-L345
[limits-consts]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/security_limits.h#L37-L96
[traversal]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/security_limits.h#L99-L191
[limits-tighten-h]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/security_limits.h#L196-L226
[seq]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_sequences.h#L35-L230
[seq-loop]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/libheif/api/libheif/heif_sequences.h#L169-L194
[test-bomb]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/tests/decompression_bomb.cc
[fuzz-file]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/fuzzing/file_fuzzer.cc#L104-L118
[cifuzz]: https://github.com/strukturag/libheif/blob/12a259a5882dd99d45ec5fc77e296a3b620d1e2e/.github/workflows/cifuzz.yml
[avif-repo]: https://github.com/AOMediaCodec/libavif/tree/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7
[avif-limits]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L93-L101
[avif-io]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1089-L1106
[avif-tmap]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2301-L2372
