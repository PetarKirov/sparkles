# Basis Universal (C++)

A GPU texture distribution system: an encoder that writes compact, block-structured
intermediate formats (ETC1S, UASTC, XUASTC, XUBC7) into `.basis` or KTX2 files, and a
dependency-free transcoder that turns them at load time into whichever block format
the device samples (BC1 to BC7, ETC1/ETC2, ASTC, PVRTC) or into raw pixels; the
catalog's reference for "ship one asset, transcode to the GPU's format".

| Field         | Value                                                                                                                                                     |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 (encoder, transcoder, tool); Emscripten and WASI builds of both; a pure C API for WASM and Python                                                   |
| License       | Apache-2.0 (Binomial LLC); third-party encoder modules and Zstandard under their own licences, listed in `.reuse/dep5` ([README][readme-license])         |
| Repository    | [BinomialLLC/basis_universal][repo]                                                                                                                       |
| Revision read | `ee771a7f913a3233a252eb6d281b4446f6a3c9f5` (October 23, 2026; the README names the release "basis_universal v2.5"; the clone is a single squashed commit) |
| Documentation | [`README.md`][readme], the project [wiki][wiki] (codec specifications), [`webgl/README.md`][webgl-readme], [`readme_wasi.md`][readme-wasi]                |
| Category      | GPU and SIMD: GPU texture supercompression and transcoding                                                                                                |
| Tier          | A                                                                                                                                                         |
| Last reviewed | November 7, 2026                                                                                                                                          |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** come from a scratch program under
> `/tmp`, outside this repository, built with GCC 14.3.0 (`nix-shell -p gcc`) against
> the pinned `transcoder/basisu_transcoder.cpp` and `zstd/zstddeclib.c`. It opened the
> sample `.basis` and `.ktx2` files the repository ships under `webgl/` and
> `shader_deblocking_glfw/bin/`, printed what each container declares, and transcoded
> level 0 to a fixed list of targets. No malformed or mutated input was run, and no
> performance figure on this page was measured here: the README's bitrate and speed
> statements are the project's own and are labelled as such. Everything else was read
> at the pinned revision with `git show`.

---

## Overview

### What it solves

No compressed texture family is sampled by every GPU. The [hardware matrix][hw-matrix]
shows it for the machines this work targets: BCn is absent on the Adreno 660, ASTC on
every AMD part, ETC2 on the RDNA parts, and only three devices have all three. A
renderer that ships one block format must either keep a copy per family or decompress
to RGBA and lose the memory and bandwidth savings. Basis Universal ships one file and
converts at load time. The [README][readme-intro] states the scope:

> "Basis Universal™ v2.5 is an open source supercompressed LDR/HDR GPU compressed
> texture interchange system from Binomial LLC that supports two intermediate file
> formats: the .KTX2 open standard from the Khronos Group, our own ".basis" file
> format, and Microsoft's .DDS file format. These file formats support rapid
> transcoding to virtually any compressed GPU texture format released over the past
> quarter century."

At this revision the system has eight codecs ([README][readme-modes]): ETC1S, UASTC LDR
4x4, UASTC HDR 4x4, ASTC HDR 6x6, UASTC HDR 6x6 intermediate, standard ASTC LDR
4x4–12x12, XUASTC LDR 4x4–12x12 and XUBC7. Three of them (UASTC HDR 4x4, ASTC HDR 6x6,
ASTC LDR) write standard ASTC blocks; the others are custom intermediates the
transcoder converts. The transcoder also reads LDR `.dds` files and converts them to
the same targets ([README][readme-dds]).

### Design philosophy

The intermediate formats are designed _for the transcoder_: each is a subset or a
latent of a hardware format, chosen so that conversion to the others is a table lookup
or a cheap analytical encode rather than a decode and a full re-encode. UASTC LDR 4x4 is
the clearest case ([README][readme-uastc]):

> "UASTC LDR is a 19 mode subset of the standard ASTC LDR 4x4 (8bpp) texture format,
> but with a custom block format containing transcoding hints. Transcoding UASTC LDR to
> ASTC LDR and BC7 is particularly fast and simple, because UASTC LDR is a common subset
> of both BC7 and ASTC."

The second commitment is integration cost. The transcoder is meant to be dropped into
an engine or a browser with nothing else ([README][readme-build]):

> "The transcoder is a single .cpp source file (in `transcoder/basisu_transcoder.cpp`)
> which has no 3rd party dependencies."

and the licence section qualifies it: "The transcoder utilizes no 3rd party libraries
or dependencies, other than Zstd (which is optional but limits the transcoder to
non-Zstd utilizing codecs)" ([README][readme-license]). Section
[4](#_4-i-o-and-codec-architecture) shows that "single file" means one translation
unit with ten included table files and five other included sources, not one file on disk.

The encoder is the opposite: large, multithreaded, with optional OpenCL and SSE paths
and its own image readers. The asymmetry is the point. Expensive search happens once,
offline; the device pays only a bounded, per-block conversion.

---

## How it works

### The layers

A Basis texture passes through four layers between the file and the GPU, the
two-layer split the [GPU texture compression thread][p-texture] describes, with a
container on top and a conversion step at the bottom:

```text
container        .basis header + slice descriptors   |  KTX2 header + level index + DFD + KVD + SGD
supercompression ETC1S: Huffman + codebooks (BasisLZ) |  UASTC: optional Zstd   |  XUASTC: Zstd, arithmetic or hybrid
intermediate     ETC1S blocks | UASTC 128-bit blocks | ASTC blocks (HDR, LDR) | XUASTC / XUBC7 latents
target           BC1-7, ETC1/2, EAC, ASTC (block size must match), PVRTC1/2, ATC, FXT1, RGBA32, 565, 4444, half, 9E5
```

The [concepts page][concepts-block] defines block-compressed formats and
supercompression.

### ETC1S: codebooks and per-block indices

ETC1S is ETC1 restricted to one base colour and one intensity table per 4x4 block (no
sub-block split, the flip bit forced off). Every block is a pair of indices: one into a
global **endpoint codebook** (5-bit-per-channel colour and a 3-bit intensity table) and
one into a **selector codebook** (sixteen 2-bit selectors). The encoder's frontend
builds both codebooks by vector-quantising the blocks of every image in the file
(`basisu_frontend::generate_endpoint_clusters`, `generate_endpoint_codebook`,
`compute_selector_clusters_within_each_parent_cluster` in
[`encoder/basisu_frontend.h`][frontend-h]); the README notes that this lets the
compressor "exploit color and pattern correlations across all the images in the entire
file using global endpoint/selector codebooks" ([README][readme-other]).

The transcoder decodes the codebooks once per file in
`basisu_lowlevel_etc1s_transcoder::decode_palettes`
([`basisu_transcoder.cpp` L8257–L8439][etc1s-palettes]): endpoints arrive as
Huffman-coded deltas from the previous entry, selectors either raw or as Huffman-coded
XOR deltas. The slice decoder
([`transcode_slice`, L8511 onward][etc1s-slice]) then walks blocks in raster order.
For each 2x2 group of blocks it decodes a predictor symbol: reuse the left, upper or
upper-left endpoint index, or, in video, the previous frame's block (conditional
replenishment); otherwise a Huffman-coded delta. Selector indices come from the
codebook or from a move-to-front history buffer with run-length coding:

```cpp
// basisu_transcoder.cpp, ETC1S slice decode (excerpt)
else if (pred == 2)
{
    if (is_video)
    {
        assert(pred == CR_ENDPOINT_PRED_INDEX);
        endpoint_index = (*pPrev_frame_indices)[block_x + block_y * num_blocks_x];
        selector_index = endpoint_index >> 16;
        endpoint_index &= 0xFFFFU;
    }
```

Conversion to the target happens per block from the decoded (endpoint, selector) pair.
For BC1, `convert_etc1s_to_dxt1` ([L2271][etc1s-dxt1]) handles single-colour blocks
through `g_bc1_match5_equals_1`-style tables (a source comment credits
`ryg_dxt` for the idea) and the general case through precomputed solution tables
indexed by base colour, intensity table, selector range and selector mapping
(`g_etc1_to_dxt_5`/`g_etc1_to_dxt_6`, included from
`basisu_transcoder_tables_dxt1_5.inc` and `_6.inc`, [L1210–L1216][etc1s-tables]). BC7
mode 5, ASTC 4x4, ATC, PVRTC2, EAC and FXT1 have their own tables or small encoders.
Because the ETC1S block space is small (32 levels per channel, 8 intensity tables, a
handful of selector ranges), the optimal target encoding of each case can be
precomputed offline; the `BASISD_WRITE_NEW_*_TABLES` switches at
[L162–L167][write-tables] regenerate them.

### UASTC LDR 4x4: an ASTC subset with hints

A UASTC block is 128 bits. The first seven bits Huffman-code one of 19 modes
(`TOTAL_UASTC_MODES`, [`basisu_transcoder_uastc.h` L12][uastc-h]); each mode fixes the
number of subsets, planes, endpoint and weight ranges, and which **hint** fields
follow: an ETC1 bias, BC1 hints and partition-pattern indices restricted to the
patterns ASTC and BC7 share (`TOTAL_ASTC_BC7_COMMON_PARTITIONS2 = 30`,
`TOTAL_ASTC_BC7_COMMON_PARTITIONS3 = 11`). `unpack_uastc`
([L15282][unpack-uastc]) rejects mode numbers out of range. Conversion to ASTC
repacks the same endpoints and weights (`transcode_uastc_to_astc`,
[L16014][uastc-astc]); conversion to BC7 maps each mode to a BC7 mode
(`transcode_uastc_to_bc7`, [L16034][uastc-bc7]):

```cpp
// basisu_transcoder.cpp, transcode_uastc_to_bc7 (excerpt)
// MODE 0: DualPlane: 0, WeightRange: 8 (16), Subsets: 1, EndpointRange: 19 (192) - BC7 MODE6 RGB
// MODE 5: DualPlane: 0, WeightRange : 5 (8), Subsets : 1, EndpointRange : 20 (256) - BC7 MODE6 RGB
...
dst_blk.m_mode = 6;
```

The other targets (BC1, BC3–BC5, ETC1, ETC2, EAC, PVRTC) run real-time encoders that
the hints accelerate. UASTC on its own is 8 bits per pixel; its file size comes from
an optional RDO pass in the encoder (`-uastc_rdo_l`) that makes blocks more alike, so
that Zstandard in KTX2 shrinks them. The decoder sees ordinary UASTC blocks either way.

### HDR and the ASTC family

UASTC HDR 4x4 is "100% standard ASTC texture data" ([README][readme-hdr4x4]), a
24-mode subset chosen to share BC6H's 27 partition patterns, so it is either passed
through to ASTC HDR or converted to BC6H. ASTC HDR 6x6 is plain ASTC; UASTC HDR 6x6
intermediate supercompresses it. All HDR codecs target only BC6H (unsigned), ASTC HDR
of the matching block size, or raw half-float and 9E5 pixels ([README][readme-hdr-targets]).

XUASTC LDR and XUBC7 are the two newest codecs (the README lists the eight "in the
order they were implemented"). XUASTC supercompresses any of the 14 ASTC
block sizes with a DCT over the weight grid and one of three entropy profiles
(Zstandard, arithmetic, hybrid); XUBC7 does the same for BC7 with weight-grid DPCM and
always uses Zstandard ([README][readme-modes]). Both carry a "latent" that the
transcoder can map directly into another format's latent for common cases (XUASTC 4x4,
6x6 and 8x6 to BC7, `cDecodeFlagXUASTCLDRDisableFastBC7Transcoding` turns that off,
[`basisu_transcoder.h` L283–L286][decode-flags]), and otherwise unpack to texels and
run an analytical encoder (`bc7f`, `etc1f`). For block sizes of 10x8 and above the
transcoder applies a deblocking filter when converting to non-ASTC formats, controlled
by the KTX2 key `DeblockFilterID` and the decode flags.

### The transcoder API

The public surface is two classes in [`basisu_transcoder.h`][bt-h], plus a DDS
transcoder:

- `basisu_transcoder` for `.basis` data: `validate_header`, `get_file_info`,
  `get_image_level_info`, `start_transcoding` (decodes ETC1S codebooks),
  `transcode_image_level` ([L921–L926][transcode-image-level]).
- `ktx2_transcoder` for KTX2: `init`, `start_transcoding`, `get_image_level_info`,
  `transcode_image_level` per level, layer and face.
- `basisu_transcoder_init()` must run once per process to build lookup tables
  ([L975–L976][transcoder-init-decl]).

Every call takes the whole file as `(const void*, uint32_t)`, returns `bool`, and
writes into a caller buffer sized in blocks or pixels, with an optional row pitch.
Targets are the 41-entry `transcoder_texture_format` enum
([L49–L141][tf-enum]); `basis_is_format_supported(target, source)` says which pairs
exist. **Verified** on the shipped samples: LDR sources (ETC1S, UASTC LDR, XUASTC,
XUBC7) reached BC1, BC3, BC7, ETC1, ETC2 and RGBA32, and were refused BC6H; HDR
sources (UASTC HDR 4x4, UASTC HDR 6x6 intermediate) reached BC6H, their own ASTC HDR
size and RGBA half, and were refused every LDR target; XUASTC 12x12 reached ASTC 12x12
but not ASTC 4x4 or 6x6, and XUBC7 reached ASTC 4x4. For the two UASTC HDR 4x4
`.basis` samples (`kodim23_hdr.basis`, `desk.basis`), the ASTC HDR 4x4 output was
byte-identical to the slice payload stored in the file, a pass-through.

A pure C API (`bt_ktx2_open`, `bt_ktx2_transcode_image_level`, handles as `uint64_t`)
exists in [`encoder/basisu_wasm_transcoder_api.h`][c-api] for WASI modules and the
Python binding; its header comment notes that DDS is not yet exposed through it.

---

## Analysis

### 1. Pixel and memory model

The model is a block grid, not a pixel grid. `basisu_image_level_info` carries the
original size (`m_orig_width`, not necessarily a multiple of the block), the padded
size, the block footprint (4x4 to 12x12) and `m_num_blocks_x`/`m_num_blocks_y`
([`basisu_transcoder.h`][image-level-info]). Output is a dense array of target blocks
in raster order with an optional row pitch in blocks, or of pixels for raw targets;
PVRTC1 ignores the pitch because its blocks are swizzled. There are no planes, no
sub-image views and no N-D extents beyond the container's levels, layers, faces and,
for `.basis`, "non-uniform texture arrays, where each image in the file can have a
different resolution" ([README][readme-other]). Sizes are `uint32_t` throughout, and
`BASISU_MAX_SUPPORTED_TEXTURE_DIMENSION` is 16384 ([L38][max-dim]). This is the
"block planes as a first-class image kind" the [texture thread][p-texture-synthesis]
asks a D design to model; Sparkles' upload path has no such kind today
([Vulkan baseline][bl-vk], G1).

### 2. Genericity mechanism

None in the template sense. Formats are enum values dispatched through large
`switch` statements; per-target converters are free functions (`convert_etc1s_to_*`,
`transcode_uastc_to_*`); codec families are separate `basisu_lowlevel_*_transcoder`
classes with the same `transcode_slice`/`transcode_image` shape but no common base.
Feature selection is compile-time and coarse: `BASISD_SUPPORT_*` macros remove whole
targets or codecs ([L75–L160][support-macros]), which the WASM build uses to drop ATC,
PVRTC2, FXT1 and EAC RG11 ([`webgl/transcoder/CMakeLists.txt` L55–L62][wasm-cmake]).
The capability query that a design-by-introspection library would express as traits
is a runtime predicate, `basis_is_format_supported`.

### 3. Colour and metadata

Colour is two bits and a scale. `.basis` has `cBASISHeaderFlagSRGB`, whose comment is
candid: "In reality, we have no idea if the texture data is actually linear or sRGB.
This is the m_perceptual parameter passed to the compressor."
([`basisu_file_headers.h` L65–L67][srgb-flag]). KTX2 files carry a Khronos Data Format
Descriptor; the transcoder reads the colour model, primaries and transfer function from
it (`get_dfd_color_model`, `get_dfd_transfer_func`), and `is_srgb()` is "transfer
function equals sRGB". HDR files record how LDR input was upconverted in key-value
pairs (`LDRUpconversionMultiplier`, `LDRUpconversionSRGBToLinear`, `KTXmapRange`,
[`basisu_transcoder.h`][kv-keys]); the README explains that LDR input is linearised and
scaled to 100 nits by default because the HDR 6x6 encoders work in ICtCp. There is no
ICC, CICP, EXIF or XMP, and the transcoder converts no colour: an sRGB source is
written to sRGB-capable target blocks and the API's sampler choice is left to the
caller. Two samples, `kodim23_hdr.basis` and `desk.basis`, reported the sRGB flag set
on an HDR (UASTC HDR 4x4) file (**verified**), which shows the flag is the encoder's
`perceptual` setting rather than a transfer function.

### 4. I/O and codec architecture

Whole-buffer and synchronous. Every entry point takes the complete file in memory and
returns after writing one level. There is no streaming input, no suspension and no
incremental output; the unit of work is a slice (`.basis`) or a level, layer and face
(KTX2). KTX2's per-level offsets mean a caller can read only the levels it needs
before calling the transcoder, but the transcoder itself expects the whole file. Video
state between frames lives in a caller-owned `basisu_transcoder_state`
([L221–L246][transcoder-state]): "For video, it needs to persist between image
transcodes (it holds the previous frame). For threading you can use one state per
thread."

The "single file" is one translation unit: [`basisu_transcoder.cpp`][bt-cpp] is
45,962 lines and about 1.7 MB at this revision, and it `#include`s ten table `.inc`
files (roughly 1.5 MB together) plus `basisu_idct.h`, `basisu_astc_cfgs.inl`,
`basisu_etc1_mods.inl`, `basisu_xbc7_decoder.inl` and `basisu_dds_transcoder.inl`,
beside ordinary headers (counted with `grep -n '#include'` on the pinned file). The
[`contrib/single_file_transcoder`][single-file] script amalgamates these into one
source; its README still describes excluding `basisu_transcoder_tables_bc7_m6.inc`,
a file that does not exist at this revision, so that documentation lags the code.

### 5. Hostile input and safety

The transcoder is C++ that reads attacker-supplied offsets, counts and entropy-coded
bits, and its defences are explicit checks rather than a safe language. What the
source shows:

- **Bounded bit reads.** `bitwise_decoder::peek_bits` and `decode_huffman` return
  zeros once `m_pBuf` reaches `m_pBuf_end` instead of reading past it
  ([`basisu_transcoder_internal.h` L501–L520][bitreader],
  [L627–L664][bitreader-huff]). Truncated streams therefore decode to garbage, not to
  an out-of-bounds read, and the slice decoder then relies on index checks: an
  endpoint delta wraps by one subtraction of the codebook size, a "left", "upper" or
  "upper-left" prediction on the first column or row returns "invalid datastream", and
  every block's endpoint and selector index is range-checked before use
  ([L8700–L8841][etc1s-slice-checks]).
- **Header validation.** `validate_header` checks signature, version, header size,
  total size against the buffer, non-zero image and slice counts, no more images than
  slices, the ETC1S flag and that the slice-descriptor array fits ([L11862–L11933][validate-header]).
  `validate_header_quick` repeats the size checks on every query call.
- **KTX2 hardening.** `ktx2_transcoder::init` caps dimensions at 16384, levels at 16
  and layers at 65535, and its comments name the threat: "m_byte_offset/m_byte_length
  are attacker-controlled full 64-bit values, so "offset + length > m_data_size" can
  wrap past 2^64 and pass" ([L19837–L19970][ktx2-init]). It compares against the
  remaining bytes instead, and refuses uncompressed lengths of 2 GiB or more. A
  comment in `read_slice_offset_len_global_data` adds that the expected size is validated
  "BEFORE allocating, so an attacker can't force a huge speculative allocation"
  ([L20967][sgd-alloc]). The `.basis` header path computes its expected file size as a
  plain `uint32_t` sum (`sizeof(basis_file_header) + pHeader->m_data_size`,
  [L11838][quick-sum], and again in `validate_header`) rather than the remaining-bytes
  form the KTX2 path documents: an `m_data_size` close enough to 2^32 that adding the
  header size overflows wraps the sum to a small value that passes the check, and `validate_file_checksums` with
  full validation then computes a CRC over `m_data_size` bytes. No such file was built,
  so whether this is reachable end to end was not tested here.
- **Allocation caps.** The PVRTC1 work buffer is refused above 256 MiB
  ([L8599][pvrtc-cap]); other allocations go through `basisu::vector::try_resize`.
- **Integrity is optional.** CRC-16s cover the `.basis` header, the data after it and
  each slice. `validate_file_checksums` checks the header CRC and, on full validation,
  the data CRC ([L11798–L11823][crc-check]); `get_file_info` checks the header CRC;
  the slice CRC is only reported, and `transcode_image_level` checks none of them. The
  macro `BASISU_NO_HEADER_OR_DATA_CRC16_CHECKS` exists "for fuzz testing"
  ([L70–L72][crc-fuzz]), and the tool's `-fuzz_testing` flag skips
  `validate_file_checksums` ([`basisu_tool.cpp` L3905–L3915][tool-fuzz]).
- **Fuzzing in tree.** There is no fuzz harness: no libFuzzer entry point and no
  corpus. What exists is randomised self-testing: `example.cpp` corrupts and
  randomises UASTC HDR 4x4 blocks, 2 million tries or 100 million under AddressSanitizer
  ([`example/example.cpp` L484–L500][example-fuzz]); the tool's `-dev_astc_fuzz` mode
  generates random valid logical ASTC blocks and compares the generic ASTC decoder's
  output with the XUASTC LDR decoder's
  ([`basisu_tool.cpp` L8097][tool-astc-fuzz]). Comments in the transcoder mention a
  BC6H decoder "fuzzed vs. DirectXTex's" and a check disabled because "during fuzzing
  the ktx2 file may lie". External fuzzing (OSS-Fuzz or other) was not looked up.
- **Reporting.** [`SECURITY.md`][security] gives e-mail contacts and no further
  policy. The GitHub workflow at this revision is a manually triggered style check
  ([`static_checks.yml`][ci-yml]); the README's CI badge is AppVeyor, whose
  [`appveyor.yml`][appveyor] builds on Windows, macOS and Ubuntu with no test step.

Errors are `false` plus an optional `BASISU_DEVEL_ERROR` printf (564 call sites); the
caller learns that a call failed, not why. The [hostile-input thread][p-hostile]
gives the background for why a hand-written C++ parser of this size is the risk
profile Wuffs was built to avoid; see [Wuffs][wuffs] for the contrast.

### 6. Allocation and ownership

The caller owns the input bytes and the output buffer; the transcoder borrows both for
the duration of a call and keeps no pointer to the output. It does keep a pointer to
the input in `ktx2_transcoder` between `init` and `transcode_image_level`, so the file
must outlive the object. Internal memory is the decoded ETC1S codebooks and Huffman
tables (per `basisu_lowlevel_etc1s_transcoder`, reusable across levels), per-call
scratch (`basisu::vector`, a `vector2D` for chroma filtering, `malloc` for PVRTC1),
and Zstandard output for supercompressed levels, which `decompress_level_data` writes
into a `basisu::uint8_vec`. The transcoder uses the project's own containers
(`basisu::vector`, `basisu_containers.h`, about 95 KB) rather than STL containers,
though it still includes `<algorithm>` and takes `std::string` in the key-value
lookup API. Global
lookup tables are mutable statics initialised by `basisu_transcoder_init`, guarded by
a plain `static bool g_transcoder_initialized` ([L2108–L2116][init]): initialisation is
not itself thread-safe; transcoding afterwards is, given one transcoder state per
thread.

### 7. CPU parallelism and SIMD

The transcoder is scalar and single-threaded per call; the README says it "is
currently single threaded, although it is thread safe (i.e. it supports decompressing
multiple texture slices in parallel)" ([README][readme-threads]). Parallelism is the
caller's: one `basisu_transcoder_state` per thread, one level or face per task. XUBC7's
low-level format "supports multithreaded transcoding (up to 8 threads)"
([README][readme-modes]). The only SIMD intrinsics in the transcoder are an SSE 4.1
path in the `bc7f` analytical BC7 encoder, compiled out by default:
`BASISU_BC7F_USE_SSE41` is `0`, with the comment "only very minimally tested"
([L30153–L30154][bc7f-sse]). The other architecture switch is
`BASISD_USE_UNALIGNED_WORD_READS`, on only for x86 and off under UBSan
([L40–L56][unaligned]). The encoder is where SIMD lives:
SSE 4.1 kernels (`basisu_kernels_sse.cpp`), a `cppspmd` SPMD layer for BC1–5 encoding,
optional OpenCL for ETC1S, and a thread pool.

### 8. GPU offload and interop

The transcoder runs on the CPU and produces bytes ready for
`vkCmdCopyBufferToImage` into a block-compressed `VkFormat`; it has no graphics API
dependency. The KTX2 header carries a `vkFormat` (undefined for supercompressed
intermediates, the ASTC format for plain ASTC files), so a Vulkan loader can tell
pass-through files from transcoded ones. The UASTC specification notes that
"Transcoding can either be done using the CPU or with a GPU compute shader" (quoted in
the [texture thread][p-texture]), but no compute transcoder is in the tree. The GPU
code that is in the tree is the deblocking pixel shader for large ASTC block sizes
(`shader_deblocking_glfw/bin/shader.glsl`, a D3D11 HLSL version, a WebGL sample),
which reduces block artefacts at sampling time. For Sparkles, this means the transcoder
sits before the one upload path, which today accepts only RGBA8
([existing-code baseline][bl-existing], G8; [Vulkan baseline][bl-vk], G1, G13).

### 9. Temporal, animation and containers

Two containers and one temporal mode. `.basis` is Binomial's own: a packed header
(`basis_file_header`, [`basisu_file_headers.h` L208–L252][basis-header]) with
CRC-16s, codebook and table offsets, a slice-descriptor array (one slice per image
and level, two with alpha in ETC1S), a texture type (2D, 2D array, cubemap array,
video frames, volume), `m_us_per_frame`, user data and, since v2.20, key-value pairs.
KTX2 is the Khronos container: header, level index, DFD, key-value data and
supercompression global data, with `KTX2_SS_BASISLZ` (ETC1S), `KTX2_SS_ZSTANDARD`
(UASTC), `KTX2_SS_UASTC_HDR_6x6I` and two schemes this project numbers 5 and 6 for
XUASTC and XUBC7 with the comment "coordinate with Khronos, not in KTX-Software yet as
of 2/19/2026" ([`basisu_transcoder.h` L1140–L1148][ktx2-ss]). The README adds that
"we are working with Khronos on the exact details of how we embed XUASTC LDR
supercompressed texture data into the KTX2 file format" ([README][readme-ktx2]).
KTX2 is limited to 2D, cubemaps and arrays: `init` rejects `m_pixel_depth > 0`.

Texture video is ETC1S with conditional replenishment: P-frames reuse the previous
frame's endpoint and selector index for unchanged blocks, I-frames do not
(`cSliceDescFlagsFrameIsIFrame`). The README links an XUASTC LDR texture-video guide
as well. There is no timing beyond a fixed frame duration and no audio, and the KTX2
transcoder documents no seeking: "ETC1S videos must always be transcoded from first to
last frame (or KTX2 "layer"), in order, with no skipping of frames"
([`basisu_transcoder.h` L1408][ktx2-video-order]). It is a texture animation format,
not a video container.

### 10. Testing and conformance

The tool has built-in round-trip tests (`basisu -test`, `-test_hdr_4x4`,
`-test_hdr_6x6`, `-test_hdr_6x6i`, `-test_xuastc_ldr`, and since v2.5 `-test_codecs`,
[README][readme-test]), [`readme_wasi.md`][readme-wasi] shows the WASI build running
`basisu -test` under wasmtime, and Python tests
cover the native and WASM bindings (`python/tests/`). Quality is reported as PSNR (and
PSNR-HVS-M for the XUASTC rate-distortion graph); `basisu -compare` computes it for
two images. External oracles are named rather than wired in: ARM's `astcenc` to unpack
ASTC for verification, and viewers such as RenderDoc and Compressonator for BCn. There
is no committed golden-output corpus and no conformance suite for the intermediates;
the specifications are wiki pages. The "Testing" signal at this revision is therefore
the encoder's own round trip plus the randomised block tests in
[section 5](#_5-hostile-input-and-safety).

---

## Lessons for Sparkles

- **Q6.** The transcoding model is what the [hardware matrix][hw-matrix] argues for: a
  device-independent asset and a per-device target. Read against the matrix, the
  targets that matter are few. BC7 and BC6H cover every desktop GPU in it, the M4 Max
  and the Adreno 830; ASTC LDR 4x4 (or the source's ASTC block size, for XUASTC and
  ASTC LDR files) covers both Adreno parts, the M4 Max and the UHD 770; ETC2 is the
  fallback for the Adreno 660 where ASTC is not wanted; RGBA8 and half-float are the
  last resort. PVRTC, ATC and FXT1 have no device in the matrix. HDR is BC6H or ASTC
  HDR only, and the matrix records the RTX 4060 reporting ASTC HDR sampling without the
  feature bit, so a Sparkles loader must choose by feature as well as by format query.
  Today the upload path has no block formats at all ([Vulkan baseline][bl-vk], G1, G13).
- **Q4, Q9.** A D port is large but separable. The container parsers (`.basis`
  header, KTX2 header, level index, DFD, key-value data) are small and are the part
  the [wired baseline][bl-wired] says a binary description format should express. The
  codecs are not: ETC1S decoding plus its target tables, UASTC plus its hint-driven
  converters, and the ASTC LDR/HDR block decoders are separate units of thousands of
  lines each (the `bc7f` analytical BC7 encoder alone spans L30157–L39480), and
  XUASTC/XUBC7 add DCT, arithmetic coding, deblocking and analytical
  BC7/ETC1 encoders on top. A minimal port for the matrix above is ETC1S and UASTC LDR
  to BC7, ASTC 4x4 and ETC2, plus UASTC HDR 4x4 to BC6H and ASTC HDR; XUASTC is the
  part most likely to change, given the KTX2 embedding is still being agreed. The
  precomputed `.inc` tables port as data, but their generators
  (`BASISD_WRITE_NEW_*_TABLES`) are the source of truth and would need porting or
  re-running to keep a D copy honest.
- **Q4, Q8.** The decoder's safety rests on patterns that map onto Sparkles' rules:
  a bit reader that returns zeros past the end becomes a `@safe pure nothrow @nogc`
  reader over a `const(ubyte)[]` slice where the bound is the slice length; the KTX2
  "compare against remaining bytes" checks are what `size_t` arithmetic on slices
  gives for free; the per-codec error `bool` becomes `Expected` with a reason. What a
  port would have to add is what the C++ lacks: a fuzz harness and a corpus. The
  [existing-code baseline][bl-existing] (G11) records that Sparkles has no image fuzz
  harness yet; the upstream CRC-off macro shows the one hook a harness needs.
- **Q8.** Basis gives Sparkles two oracles without porting anything: the C++ transcoder
  itself, built from source in the dev shell, for differential tests of a D transcoder
  block by block; and the sample `.basis`/`.ktx2` files in the repository as a small
  corpus. **Verified:** the pinned transcoder and `zstddeclib.c` build with GCC as two
  translation units and transcode every shipped sample, so the oracle is cheap to
  stand up. Because the code is C++, D's ImportC does not apply; the C API in
  `basisu_wasm_transcoder_api.h` is the boundary an `extern(C)` binding or a test-only
  oracle package would use, following the `font-oracle` template the existing-code
  baseline describes.
- **Q1.** The block-grid descriptor (original size, padded size, block footprint,
  blocks per row and column, bytes per block, row pitch in blocks) is the minimum a
  Sparkles image model needs to represent compressed textures beside pixel views. It
  is not a pixel view and should not pretend to be one: no per-texel access, no
  sub-rectangle except on block boundaries.
- **Q2, Q3.** Basis uses macros to cut targets and runtime enums to dispatch. In D,
  each (source, target) converter is a function over fixed-size block arrays
  (`ubyte[16]`), and a static table of converters keyed by enum would let a build
  include only the targets it needs without the preprocessor. The
  [texture thread][p-texture-synthesis] recommends exactly that shape: total block
  decoders over `ubyte[8]`/`ubyte[16]`.
- **Q7.** The transcoder is scalar and per-block independent except for ETC1S's
  row-to-row prediction state and PVRTC1's whole-image pass. UASTC and the ASTC paths
  parallelise per block; that makes them the candidates for SIMD or a compute kernel,
  and ETC1S the one that stays serial per slice. The [shaders and SIMD
  baseline][bl-shaders] (G1) records that Sparkles has no compute path to put such a
  kernel on yet.
- **Q5.** Colour metadata here is a flag and a DFD transfer function; the
  `kodim23_hdr.basis` observation in section 3 shows that a flag recorded as "perceptual
  metrics were used" is not colour information. A Sparkles texture descriptor should
  take colour from KTX2's DFD where present and treat the `.basis` flag as a hint.
- **Q9.** Upstream keeps encoder and transcoder in one repository but as separate
  build products with separate dependency footprints, and the transcoder never depends
  on the encoder. That is evidence for keeping a Sparkles texture transcoder in an
  image-formats layer independent of any encoder, and the encoder (if ever wanted)
  out of the default build.

---

## Strengths

- One asset reaches every texture family in the hardware matrix, with HDR covered by
  BC6H and ASTC HDR.
- The intermediates are designed for cheap conversion: subsets of BC7 and ASTC, hint
  bits, precomputed optimal conversions for ETC1S.
- Three codecs emit standard ASTC, so on ASTC devices those files need no transcoding.
- The transcoder needs no third-party code except optional Zstandard, and builds for
  native, Emscripten and WASI with feature macros that trim unused targets.
- KTX2 support aligns with the Khronos container and `KHR_texture_basisu`.
- Recent hardening in the KTX2 parser is explicit and commented with the threat it
  addresses.

## Weaknesses

- A 46,000-line hand-written C++ translation unit with large included tables; the
  "single file" is one translation unit, not one small file.
- Errors are `bool` with optional debug prints; callers learn nothing about the cause.
- No fuzz harness, corpus or golden outputs in the tree; CI at this revision is a
  manual style check plus an AppVeyor build with no test step.
- Integrity checks are optional and validation differs between the `.basis` and KTX2
  paths.
- Whole-file, synchronous API; no streaming input or suspension.
- Colour is a flag; no ICC, CICP or EXIF.
- XUASTC and XUBC7 KTX2 embeddings are not yet agreed with Khronos at this revision, and
  some in-tree documentation (the single-file script README) lags the code.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                     | Trade-off                                                                         |
| --------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Intermediate formats designed as subsets or latents       | Conversion is a lookup or a cheap analytical encode, not decode-and-re-encode | Quality is capped by the subset (UASTC LDR below full ASTC 4x4, ETC1S below ETC1) |
| Global endpoint/selector codebooks for ETC1S              | Exploits redundancy across all images and levels in a file; very small files  | Slow, memory-hungry encoding; codebooks must be decoded before any level          |
| Precomputed per-target conversion tables                  | Optimal target blocks for a small source space at near-zero run-time cost     | Roughly 1.5 MB of generated tables in the source; generators must be kept in step |
| Hint bits inside UASTC blocks                             | Accelerate conversion to BC1, ETC1 and others                                 | Bits not spent on quality; the format is not plain ASTC                           |
| Emit standard ASTC for three codecs                       | No transcoding on ASTC hardware; interoperable KTX2 files                     | Other targets need a full ASTC decode and re-encode                               |
| One translation unit, macros to trim targets              | Drop-in integration for engines and the web; small WASM builds                | Preprocessor configuration; no type-level capability model                        |
| Whole-file, synchronous, `bool` API                       | Simple to bind from C, JavaScript and Python                                  | No streaming, no suspension, no error detail                                      |
| CRC-16 integrity, optional at transcode time              | Cheap corruption detection for callers who want it                            | Not validation; the decoder must be robust without it                             |
| Own KTX2 supercompression scheme numbers for new codecs   | Ship XUASTC and XUBC7 before standardisation                                  | Files may not be read by other KTX2 tools until the scheme numbers are agreed     |
| CPU transcoder only, GPU deblocking as an optional shader | Portable to every platform including plain WASM                               | No compute-shader transcoding in tree; CPU cost at load                           |

---

## Sources

- [BinomialLLC/basis_universal][repo], read at
  `ee771a7f913a3233a252eb6d281b4446f6a3c9f5`: [`README.md`][readme],
  [`SECURITY.md`][security], [`readme_wasi.md`][readme-wasi],
  [`webgl/README.md`][webgl-readme], [`webgl/transcoder/CMakeLists.txt`][wasm-cmake],
  [`contrib/single_file_transcoder/README.md`][single-file],
  [`.github/workflows/static_checks.yml`][ci-yml], [`appveyor.yml`][appveyor].
- Transcoder: [`transcoder/basisu_transcoder.cpp`][bt-cpp],
  [`transcoder/basisu_transcoder.h`][bt-h],
  [`transcoder/basisu_transcoder_internal.h`][bitreader],
  [`transcoder/basisu_file_headers.h`][basis-header],
  [`transcoder/basisu_transcoder_uastc.h`][uastc-h].
- Encoder and tools: [`encoder/basisu_frontend.h`][frontend-h],
  [`encoder/basisu_wasm_transcoder_api.h`][c-api], [`basisu_tool.cpp`][tool-fuzz],
  [`example/example.cpp`][example-fuzz].
- Specifications (project wiki, archived in the [texture thread][p-texture]): UASTC LDR
  4x4, `.basis`/ETC1S, and "The Three Generations of GPU Texture Distribution".
- Background: the [GPU texture compression thread][p-texture] (Callow 2019 on KTX2 and
  Basis Universal; Geldreich on Crunch and RDO), the [hostile-input thread][p-hostile],
  and the [hardware matrix][hw-matrix].
- Baselines: [existing code][bl-existing], [Vulkan][bl-vk],
  [shaders and SIMD][bl-shaders], [wired][bl-wired].

<!-- References -->

[repo]: https://github.com/BinomialLLC/basis_universal/tree/ee771a7f913a3233a252eb6d281b4446f6a3c9f5
[wiki]: https://github.com/BinomialLLC/basis_universal/wiki
[readme]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md
[readme-intro]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L14
[readme-modes]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L20-L30
[readme-license]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L39-L41
[readme-hdr-targets]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L74-L82
[readme-dds]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L85-L87
[readme-uastc]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L94
[readme-hdr4x4]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L100
[readme-other]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L140-L142
[readme-build]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L153
[readme-test]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L246-L258
[readme-threads]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L355
[readme-ktx2]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/README.md#L520-L525
[readme-wasi]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/readme_wasi.md
[webgl-readme]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/webgl/README.md
[wasm-cmake]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/webgl/transcoder/CMakeLists.txt#L55-L62
[single-file]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/contrib/single_file_transcoder/README.md
[security]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/SECURITY.md
[ci-yml]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/.github/workflows/static_checks.yml
[appveyor]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/appveyor.yml
[bt-cpp]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp
[unaligned]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L40-L56
[crc-fuzz]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L70-L72
[support-macros]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L75-L160
[write-tables]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L162-L167
[etc1s-tables]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L1210-L1216
[init]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L2108-L2116
[etc1s-dxt1]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L2271
[etc1s-palettes]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L8257-L8439
[etc1s-slice]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L8511
[pvrtc-cap]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L8599
[crc-check]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L11798-L11823
[etc1s-slice-checks]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L8700-L8841
[quick-sum]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L11838
[validate-header]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L11862-L11933
[unpack-uastc]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L15282
[uastc-astc]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L16014
[uastc-bc7]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L16034
[bc7f-sse]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L30153-L30154
[ktx2-init]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L19837-L19970
[sgd-alloc]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.cpp#L20967
[bt-h]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h
[max-dim]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L38
[tf-enum]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L49-L141
[transcoder-state]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L221-L246
[decode-flags]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L249-L287
[image-level-info]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L680-L709
[kv-keys]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L754-L772
[transcode-image-level]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L910-L926
[transcoder-init-decl]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L975-L976
[ktx2-ss]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L1140-L1148
[ktx2-video-order]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder.h#L1408
[bitreader]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder_internal.h#L501-L520
[bitreader-huff]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder_internal.h#L627-L664
[srgb-flag]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_file_headers.h#L65-L67
[basis-header]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_file_headers.h#L208-L252
[uastc-h]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/transcoder/basisu_transcoder_uastc.h#L12-L17
[frontend-h]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/encoder/basisu_frontend.h#L329-L341
[c-api]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/encoder/basisu_wasm_transcoder_api.h
[tool-fuzz]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/basisu_tool.cpp#L3905-L3915
[tool-astc-fuzz]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/basisu_tool.cpp#L8097
[example-fuzz]: https://github.com/BinomialLLC/basis_universal/blob/ee771a7f913a3233a252eb6d281b4446f6a3c9f5/example/example.cpp#L484-L500
[hw-matrix]: ./hardware/index.md
[concepts-block]: ./concepts.md#block-compressed-formats-and-supercompression
[p-texture]: ./papers/gpu-texture-compression.md
[p-texture-synthesis]: ./papers/gpu-texture-compression.md#thread-synthesis
[p-hostile]: ./papers/hostile-input-safety.md
[wuffs]: ./wuffs.md
[bl-existing]: ./baseline/existing-code.md
[bl-vk]: ./baseline/vulkan.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
