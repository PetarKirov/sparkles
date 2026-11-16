# CICP, ITU-T H.273 (specification)

Four small integers (colour primaries, transfer characteristics, matrix
coefficients and a full-range flag) that AV1, HEVC, AVIF, HEIF, JPEG XL and PNG
use to identify colour, read here as the tables real decoders ship rather than as
the Recommendation's prose.

| Field         | Value                                                                                                                                                                                                                                                                                                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | Specification (no code); its tables are read from C headers                                                                                                                                                                                                                                                                                                              |
| License       | ITU-T Recommendation, free to download from the ITU; the headers read carry their projects' licenses (libavif and dav1d BSD-2-Clause, FFmpeg's `libavutil` LGPL-2.1-or-later)                                                                                                                                                                                            |
| Repository    | None for the specification; code read in [AOMediaCodec/libavif][avif-repo], [videolan/dav1d][dav1d-repo], [FFmpeg/FFmpeg][ffmpeg-repo], [glennrp/libpng][libpng-repo], [libjxl/libjxl][jxl-repo] and [KhronosGroup/Vulkan-Docs][vk-repo]                                                                                                                                 |
| Revision read | H.273 (07/24), the edition in force ([ITU][h273]); libavif `9b07a9d7a874b159bb4e14b80a6f08bb469d06f7`; dav1d `c6f51c881d80b43830b7c1fff2ba0d48599e8073`; FFmpeg `a23e094488f139522c0e175e9766212a1213e486`; libpng `890812a28da480f84f3b0198d31ac611c864ed98`; libjxl `e2948747fee8e99a614066eb058e67a0b8de995f`; Vulkan-Docs `a8b088a3fae12c8575407ea90c7c09bd653db923` |
| Documentation | [ITU-T H.273][h273] · [PNG Third Edition, `cICP`][png3-cicp] · [concepts: CICP][c-cicp]                                                                                                                                                                                                                                                                                  |
| Category      | Colour: signalling vocabulary shared by video and still-image formats                                                                                                                                                                                                                                                                                                    |
| Tier          | B                                                                                                                                                                                                                                                                                                                                                                        |
| Last reviewed | November 7, 2026                                                                                                                                                                                                                                                                                                                                                         |

> [!NOTE]
> **What was run.** In `/tmp/cicp-probe`, outside this repository: a C program
> against nixpkgs libpng 1.6.56 that writes and re-reads PNGs with chosen `cICP`
> bytes; `ffprobe` from nixpkgs FFmpeg 8.0 on those PNGs; `avifenc`/`avifdec` from
> nixpkgs libavif 1.3.0 (dav1d 1.5.2, aom 3.12.1) on three AVIFs; and FFmpeg's
> `trace_headers` bitstream filter on one of them. Those builds are not the pinned
> revisions; every statement about _code_ below was read at the pinned revision,
> and results are marked **verified** where a run backs them. No performance was
> measured.

---

## Overview

### What it solves

H.273 is titled "Coding-independent code points for video signal type
identification" ([ITU][h273]). It is a registry, not a colour model: each field is
an 8-bit index into a table of named standards (BT.709, BT.2020, SMPTE ST 2084 and
so on), and the meaning lives in the cited standard. Codec specifications import
the tables instead of redefining them. The ITU records the lineage: the 2016
edition "was published as a twin text technically aligned with ISO/IEC
23001-8:2016", and after the ISO split in 2019 it stayed aligned with ISO/IEC
23091-2:2019 ([ITU][h273]). FFmpeg's headers cite that ISO twin directly:
"These values match the ones defined by ISO/IEC 23091-2_2019 subclause 8.1 and
ITU-T H.273" ([`pixfmt.h`][ff-pri]).

The four fields answer four questions about a decoded sample:

- **`colour_primaries`**: which red, green, blue and white chromaticities the
  RGB values refer to (see [colour space, primaries and white point][c-primaries]).
- **`transfer_characteristics`**: the curve between encoded values and linear
  light (see [transfer function][c-transfer]).
- **`matrix_coefficients`**: how R'G'B' became Y'CbCr, or `0` when the planes
  are R'G'B' (see [YCbCr and matrix coefficients][c-ycbcr]).
- **`video_full_range_flag`**: whether codes span the full integer range or
  leave headroom and footroom (see [full and limited range][c-range]).

### Design philosophy

The design is deliberately thin. PNG's third edition adopts the four bytes
verbatim, "Each of the fields of the cICP chunk corresponds to the parameter of
the same name in [ITU-T-H.273]", and narrows only what its pixel model cannot
express: "RGB is currently the only supported color model in PNG, and as such
Matrix Coefficients shall be set to 0" ([PNG Third Edition][png3-cicp]).

## How it works

### The tables, as decoders spell them

The same numbers appear in every codec header read. libavif's enums are the
fullest, because they carry the aliases each community uses
([`avif.h`][avif-cp]):

```c
// libavif include/avif/avif.h (excerpt)
AVIF_COLOR_PRIMARIES_BT709 = 1,
AVIF_COLOR_PRIMARIES_SRGB = 1,
AVIF_COLOR_PRIMARIES_UNSPECIFIED = 2,
AVIF_COLOR_PRIMARIES_BT2020 = 9,
AVIF_COLOR_PRIMARIES_BT2100 = 9,
AVIF_COLOR_PRIMARIES_SMPTE432 = 12,
AVIF_COLOR_PRIMARIES_DCI_P3 = 12,
```

The code points that recur as defaults, presets and examples across the sources
are few:

| Field     | Code | Name                    | Where it recurs                                                                          |
| --------- | ---- | ----------------------- | ---------------------------------------------------------------------------------------- |
| primaries | 1    | BT.709 / sRGB           | MIAF default; AV2 presets 1, 4 and 5; PNG example 3                                      |
| primaries | 9    | BT.2020 / BT.2100       | AV2 presets 2 and 3 (PQ, HLG); PNG examples 1 and 2                                      |
| primaries | 12   | SMPTE EG 432-1 (P3 D65) | PNG example 4, "to compactly signal a Display P3 image"                                  |
| transfer  | 1    | BT.709                  | AV2 preset 1; PNG example 3                                                              |
| transfer  | 13   | sRGB (IEC 61966-2-1)    | MIAF default; AV2 presets 4 and 5; `mini` box default without ICC                        |
| transfer  | 16   | SMPTE ST 2084 (PQ)      | AV2 preset 2; PNG example 1; `VK_COLOR_SPACE_HDR10_ST2084_EXT`                           |
| transfer  | 18   | ARIB STD-B67 (HLG)      | AV2 preset 3; PNG example 2; `VK_COLOR_SPACE_HDR10_HLG_EXT`                              |
| matrix    | 0    | identity (GBR)          | PNG (mandatory); AV2 preset 4; the AV1 sRGB shortcut                                     |
| matrix    | 1    | BT.709                  | AV2 preset 1; `VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709`                              |
| matrix    | 6    | BT.601 (5 is the same)  | MIAF default "5 or 6 (which are functionally identical)"; `mini` box default with chroma |
| matrix    | 9    | BT.2020 non-constant    | AV2 presets 2 and 3; `VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_2020`                      |

The evidence for "these are the ones that matter" is structural, not a usage
count. The AV2 content-interpretation OBU adds a variable-length
`color_description_idc` in front of the triple: 0 still signals the three bytes
explicitly, and the presets 1 to 5 are exactly BT.709 SDR (1/1/1), BT.2100 PQ
(9/16/9), BT.2100 HLG (9/18/9), sRGB (1/13/0) and sYCC (1/13/5), as libavif
expands them ([`obu.c`][avif-av2]). PNG's four examples are
9/16/0/1, 9/18/0/1, 1/1/0/0 and 12/13/0/1 ([PNG Third Edition][png3-cicp]).
Vulkan's sampler offers only three YCbCr matrices (709, 601, 2020) plus identity
([`vk.xml`][vk-ycbcr]).

The rest of each table is real but narrow: BT.470 and SMPTE 240 for legacy video,
XYZ (10) and SMPTE 431 DCI-P3 (11) for cinema, logarithmic transfers 9 and 10,
the constant-luminance matrices 10 and 13, ST 2085 (11), chromaticity-derived
non-constant luminance (12), ICtCp (14), IPT-C2 (15, named only in FFmpeg's
header among those read), and the YCgCo family (8, 16, 17). libavif lists the primaries with chromaticities in one table
([`colr.c`][avif-prim-table]) and the matrices it can apply as `kr`/`kb` pairs,
with the non-linear ones commented out: BT.2020 constant luminance "is not an
linear transformation", ST 2085 and ICtCp "can't represent using Kr and Kb"
([`colr.c`][avif-mc-table]). Its RGB conversion refuses code 3 ("CICP reserved"),
10, 11, 13, 14, values past `AVIF_MATRIX_COEFFICIENTS_LAST`, and limited-range
YCgCo ([`reformat.c`][avif-reformat]).

### Carriers

| Carrier                    | Field widths                        | Where the bytes sit                                             | Source                                          |
| -------------------------- | ----------------------------------- | --------------------------------------------------------------- | ----------------------------------------------- |
| AV1 sequence header        | 3 × 8 bits, 1-bit `color_range`     | `color_config`, behind `color_description_present_flag`         | [dav1d `obu.c`][dav1d-obu], [libavif][avif-av1] |
| AV2 content interpretation | preset index or 3 × 8 bits          | `color_description_idc`                                         | [libavif `obu.c`][avif-av2]                     |
| HEVC VUI                   | 3 × 8 bits, 1-bit full range        | `colour_primaries`, `transfer_characteristics`, `matrix_coeffs` | [Vulkan `video.xml`][vk-h265]                   |
| HEIF / AVIF `colr` `nclx`  | 3 × 16 bits, 1 bit, 7 reserved bits | item property                                                   | [libavif `read.c`][avif-colr]                   |
| AVIF `mini` box            | 3 × 8 bits, optional, with defaults | condensed header                                                | [libavif `read.c`][avif-mini]                   |
| PNG `cICP`                 | 4 × 8 bits                          | ancillary chunk before `PLTE` and `IDAT`                        | [PNG Third Edition][png3-cicp]                  |
| JPEG XL `JxlColorEncoding` | separate enums, some valued as CICP | codestream header                                               | [libjxl `color_encoding.h`][jxl-enc]            |

The `nclx` parse in libavif shows the container form exactly, including the check
on the reserved bits ([`read.c`][avif-colr]):

```c
// libavif src/read.c, avifParseColourInformationBox (excerpt)
AVIF_CHECK(avifROStreamReadU16(&s, &colr->colorPrimaries));          // unsigned int(16) colour_primaries;
AVIF_CHECK(avifROStreamReadU16(&s, &colr->transferCharacteristics)); // unsigned int(16) transfer_characteristics;
AVIF_CHECK(avifROStreamReadU16(&s, &colr->matrixCoefficients));      // unsigned int(16) matrix_coefficients;
uint8_t full_range_flag;
AVIF_CHECK(avifROStreamReadBitsU8(&s, &full_range_flag, /*bitCount=*/1)); // unsigned int(1) full_range_flag;
```

The AV1 bitstream couples CICP to the pixel layout. When the triple is 1/13/0 the
sequence header carries no `color_range` bit and no subsampling bits: range is
full and the layout is 4:4:4, and dav1d rejects the shortcut outside the profiles
that allow 4:4:4 ([`obu.c`][dav1d-obu]). With strict compliance on, dav1d also
rejects matrix 0 with any layout but 4:4:4. A CICP value therefore changes how
many bits follow it.

### Precedence when two carriers disagree

A HEIF or AVIF file carries CICP twice, in the `colr` property and in the codec
bitstream. libavif follows the container, quoting MIAF section 7.3.6.4: "The
colour information property takes precedence over any colour information in the
image bitstream" ([`read.c`][avif-cicpset]). Absent `colr`, it parses the first
sample's sequence header ([`read.c`][avif-harvest]). A range mismatch between the
two is tolerated, not rejected, because "codec_svt.c was not encoding the
color_range field for multiple years" ([`read.c`][avif-range-mismatch]). With no
colour information at all, MIAF's default is 1/13/5-or-6/full, as libavif's
comment quotes ([`colr.c`][avif-default]). The [libavif deep-dive][libavif]
covers this flow.

PNG ranks `cICP` first among colour chunks: "This chunk, if understood by the
decoder, is the highest-precedence color chunk" ([PNG Third Edition][png3-cicp]),
ahead of `iCCP`, `sRGB`, `cHRM` and `gAMA`. libpng stores it and does not yet
derive gamma from it ("TODO: set png_struct::chunk_gamma when possible",
[`pngrutil.c`][png-handle]); see the [libpng deep-dive][libpng].

FFmpeg does not deliver the HEIF rule for still items. At the pinned revision
`mov_read_colr` stores an `nclx` triple only on a stream (`else if (st)`); an
item with no stream yet keeps an ICC profile but drops `nclx`
([`mov.c`][ff-mov]). **Verified** with nixpkgs FFmpeg 8.0: an AVIF written with
`avifenc --cicp 9/16/9 -r full` has an AV1 sequence header with
`color_description_present_flag` 0; the demuxer traces `nclx: pri 9 trc 16 matrix 9
full 1`, yet `ffprobe` reports both the stream and the decoded frame as
`color_primaries=unknown`, `color_transfer=unknown`, `color_space=unknown`
(range `pc`, which the bitstream also signals). `avifdec --info` on the same file
reports 9, 16 and 9. The trace line is printed inside the `else if (st)` branch
in FFmpeg 8.0's `mov_read_colr` too, so in that run the triple did reach the
item's stream and was later replaced by the bitstream's "unspecified"; the
`nclx` is lost after the demuxer reads it, not on the item path.

### The same numbers, renumbered

The values survive between libraries; the _neighbouring_ enums do not.

| Concept           | H.273 / AV1 / PNG | libavif                   | dav1d                         | FFmpeg                                 | Vulkan                                  |
| ----------------- | ----------------- | ------------------------- | ----------------------------- | -------------------------------------- | --------------------------------------- |
| unknown primaries | 2 unspecified     | `UNKNOWN = 0` sentinel, 2 | `DAV1D_COLOR_PRI_UNKNOWN = 2` | `RESERVED0 = 0`, `UNSPECIFIED = 2`     | none in sampler or swapchain            |
| full range        | flag 1            | `AVIF_RANGE_FULL = 1`     | `color_range` 1               | `AVCOL_RANGE_JPEG = 2`                 | `VK_SAMPLER_YCBCR_RANGE_ITU_FULL = 0`   |
| narrow range      | flag 0            | `AVIF_RANGE_LIMITED = 0`  | `color_range` 0               | `AVCOL_RANGE_MPEG = 1`                 | `VK_SAMPLER_YCBCR_RANGE_ITU_NARROW = 1` |
| matrix 9          | 9                 | `BT2020_NCL = 9`          | `DAV1D_MC_BT2020_NCL = 9`     | `AVCOL_SPC_BT2020_NCL = 9`             | `YCBCR_2020 = 4`                        |
| beyond H.273      | none              | none                      | `RESERVED = 255`              | `AVCOL_PRI_EXT_BASE = 256` (`V_GAMUT`) | swapchain `VkColorSpaceKHR` pairs       |

Sources: [`avif.h`][avif-range], [`headers.h`][dav1d-enums],
[`pixfmt.h`][ff-range], [`vk.xml`][vk-ycbcr]. libavif's own comment admits the
sentinel: "This is actually reserved, but libavif uses it as a sentinel value"
([`avif.h`][avif-cp]). FFmpeg adds a third range state, "unspecified", that the
1-bit flag cannot express, and extends primaries and transfer past 255 with
entries "not part of H.273, but custom extensions" ([`pixfmt.h`][ff-pri]). Vulkan
inverts the range sense and reduces the matrix to a five-value
`VkSamplerYcbcrModelConversion`, applied after swizzle and range expansion
([`textures.adoc`][vk-conv]); primaries and transfer reach Vulkan only through
the swapchain's `VkColorSpaceKHR` names such as `VK_COLOR_SPACE_DISPLAY_P3_NONLINEAR_EXT`
([`vk.xml`][vk-colorspace]). Vulkan Video, by contrast, passes the HEVC VUI and AV1
`color_config` fields through as raw `uint8_t` and enum members, whose
`StdVideoAV1ColorPrimaries` keeps `UNSPECIFIED = 2`
([`video.xml`][vk-h265], [`video.xml`][vk-av1], [`video.xml`][vk-av1-pri]).

JPEG XL is the near miss. Its enums "match a subset of CICP", "however the white
point and RGB primaries are separate enums here" ([`color_encoding.h`][jxl-enc]).
`JXL_PRIMARIES_P3 = 11` is SMPTE RP 431-2, so Display P3 in JPEG XL is primaries
11 plus `JXL_WHITE_POINT_D65`, which is CICP primaries 12, not 11. Copying the
number across silently selects the DCI white point. `JXL_TRANSFER_FUNCTION_GAMMA
= 65535` is "Not a CICP value". See the [libjxl deep-dive][libjxl].

## Analysis

### 1. Pixel and memory model

Matrix coefficients and range are pixel-model facts, not decoration. Matrix 0
means the planes are G, B, R in that order ("order of coefficients is actually
GBR", [`pixfmt.h`][ff-spc]); any other value means Y'CbCr planes, and AV1 ties
matrix 0 to 4:4:4 ([`obu.c`][dav1d-obu]). Range fixes the integer codes for
black and white: libavif documents limited range as Y 16 to 235 and UV 16 to 240
at 8 bits, Y 64 to 940 and UV 64 to 960 at 10 bits, Y 256 to 3760 and UV 256 to
3840 at 12 bits, and states that "RGB and alpha planes are
always full range" ([`avif.h`][avif-range]). A planar view type that carries a
bit depth but not the range cannot interpret its own samples.

### 2. Genericity mechanism

Not applicable: H.273 is a table of integers, not code. The headers read model it
three ways (C enums in dav1d and FFmpeg, `uint16_t` typedefs with enum constants
in libavif, XML enums in Vulkan), none of them generic.

### 3. Colour and metadata

CICP is the compact half of the colour model; the [ICC profile][c-icc] is the
general half. The formats differ in how they combine the two: PNG puts `cICP`
above `iCCP`; HEIF lets an item hold one of each, and libavif warns callers to
check for ICC "before relying on the values listed here" ([`avif.h`][avif-image]);
the AVIF `mini` box sets primaries and transfer to 2 (unspecified) when an ICC
profile is present and to 1/13 when not ([`read.c`][avif-mini]). Skia prefers
CICP over ICC but its `MakeCICP` takes no matrix or range ([skia][skia]). CICP
does not carry mastering-display or content-light-level data; those travel
beside it (`mDCV`/`cLLI` in PNG, `clli` in AVIF, `Dav1dMasteringDisplay` in dav1d,
[`headers.h`][dav1d-seq]). See [image metadata][c-metadata].

### 4. I/O and codec architecture

CICP is the cleanest example of a [container and bitstream][c-container] split:
the same triple is encoded at three widths (8-bit OBU fields, 16-bit `nclx`
fields, 8-bit `cICP` bytes) with different presence rules and a precedence rule
between levels. A binary description must express the widths, the reserved-bit
check, the conditional presence (`color_description_present_flag`, `mini`
defaults by `hasIcc` and chroma) and the AV1 case where the triple's value
decides whether the next fields exist.

### 5. Hostile input and safety

Every carrier admits any byte, so CICP fields are open sets; see
[hostile input][c-hostile]. dav1d reads the raw 8 bits into fields typed as C
enums ([`obu.c`][dav1d-obu]); libavif uses `uint16_t` typedefs rather than enum
types ([`avif.h`][avif-cp]); FFmpeg's demuxer maps unnamed values to
"unspecified" through `av_color_primaries_name` ([`mov.c`][ff-mov]), while its
PNG decoder only tests `>= AVCOL_PRI_NB` ([`pngdec.c`][ff-png-apply]).
**Verified** with the libpng probe:

- libpng's `png_set_cICP` warns "Invalid cICP matrix coefficients" for a non-zero
  matrix and leaves the chunk invalid; written as 1/1/1/0, the file is saved
  without `cICP` ([`pngset.c`][png-set]).
- libpng accepts a full-range flag of 7 and code points 200/250 unchanged; it
  validates only the matrix byte.
- FFmpeg's PNG decoder logs "invalid cICP range: 7" and reports
  `color_range=unknown` ([`pngdec.c`][ff-png-parse]); it reports 200/250 as
  unknown, and passes transfer 3, which H.273 reserves, through as `reserved`.

The safe reading is a value type that stores the integer, never a closed enum
that a `final switch` assumes complete.

### 6. Allocation and ownership

Not applicable: every carrier holds the fields inline at a fixed size (at most
three 16-bit values and a byte), so CICP never allocates; ownership questions
belong to the ICC profile that may accompany it.

### 7. CPU parallelism and SIMD

Not applicable to the signalling itself. The conversions it selects (matrix,
range, transfer) are per-pixel kernels, covered where they are implemented, as in
the [libavif deep-dive][libavif].

### 8. GPU offload and interop

On Vulkan, CICP splits in two. Matrix and range drive
`VkSamplerYcbcrConversion` (only 709, 601 and 2020 matrices, plus identity and
range-only), together with `VkChromaLocation` per axis ([`vk.xml`][vk-ycbcr],
[`samplers.adoc`][vk-sampler]). Primaries and transfer are not sampler state at
all; they decide a shader's linearisation and a swapchain `VkColorSpaceKHR`. A
`VkFormat` `_SRGB` suffix covers transfer 13 only. Every other matrix (4, 7, 8
and 10 to 17; 5 maps to the 601 model) needs a shader path; libavif's CPU path
itself refuses 3, 10, 11, 13, 14 and limited-range YCgCo
([`reformat.c`][avif-reformat]).

### 9. Temporal, animation and containers

H.273 has no time axis: one value describes a whole sequence or item. The
container question is covered above, under precedence: HEIF and AVIF carry the
values twice, in `colr` and in the bitstream. Consistency across the pieces of
one image is a container rule, not an H.273 one: libavif rejects a grid whose
tiles differ in range, primaries, transfer or matrix ("Grid image contains
mismatched tiles", [`read.c`][avif-grid]).

### 10. Testing and conformance

The tables are small enough to test exhaustively against the headers of three
independent implementations: libavif, dav1d and FFmpeg agree on every value they
share, which makes them a free differential oracle, though their coverage differs
(dav1d's matrices stop at 14, libavif has no 15, FFmpeg names 15 to 17). libavif's primaries
table supplies the chromaticities and `avifColorPrimariesFind` matches them to
three decimal places ([`colr.c`][avif-prim-table]). The divergences worth tests are
the renumbered neighbours (range, unknown), the JPEG XL white point, and
precedence between `colr` and bitstream.

## Lessons for Sparkles

- **Q5** The minimum CICP value is four integers plus a "present" bit, with names
  for the common points (primaries 1, 9, 12; transfer 1, 13, 16, 18; matrix 0, 1,
  6, 9) and room for every other byte; libavif's `uint16_t` typedefs and
  FFmpeg's sanitising lookup are the two models on offer.
- **Q5** "Unspecified" (2) and "absent" are different: MIAF turns absence into
  1/13/5-or-6/full; the `mini` box turns it into 1/13 with matrix 6 (2 for
  4:4:4) beside an always-explicit range bit, and an ICC profile into 2. A CICP type
  that cannot say "absent" forces a reader to invent defaults early.
- **Q5** The range flag belongs with matrix coefficients. Where it is stored as
  FFmpeg's three-valued enum or Vulkan's inverted one, conversions at the seam
  are named functions, not casts.
- **Q5** JPEG XL's split white point and primaries do not map one to one; a
  JPEG XL reader produces CICP through a table that checks the white point.
- **Q4** `sparkles:wired` needs conditional fields, reserved-bit checks and
  value-dependent presence to describe the AV1 `color_config`; the same logical
  record arrives in three encodings.
- **Q4** Precedence (container over bitstream) is a reader policy that the codec
  layer reports, not one it hides; FFmpeg's lost `nclx` (read, then replaced by
  the bitstream's "unspecified") shows the cost of losing a level.
- **Q1** A planar YCbCr view is incomplete without matrix, range and chroma
  location; RGB views need only primaries and transfer.
- **Q6** Upload maps CICP to `VkSamplerYcbcrConversion` where it can and to a
  shader otherwise; the mapping table is small and testable on the CPU.
- **Q8** Differential tests can compare a D table against libavif, dav1d and
  FFmpeg values, and crafted `cICP` chunks (bad matrix, flag 7, unassigned codes)
  make a cheap hostile-input corpus.
- **Q9** A CICP type with its tables depends on nothing and is needed by every
  format reader and by the GPU layer, which argues for placing it in the
  smallest shared package. What does not transfer: FFmpeg's `EXT_BASE`
  extensions, which are outside the standard.

## Strengths

- One vocabulary across AV1, HEVC, AVIF, HEIF, PNG, Vulkan Video and, partly,
  JPEG XL; the assigned numbers agree in every header read.
- Compact: four bytes signal HDR (9/16/0/1) or Display P3 (12/13/0/1) where an
  ICC profile takes a tag table and tag data.
- Extensible by registration: new matrices (YCgCo-R, 16 and 17) were added
  without changing carriers.

## Weaknesses

- Not a colour model: it names standards, and a reader still needs each curve and
  matrix implemented; libavif implements a subset.
- Neighbouring enums are renumbered across libraries (range, unknown, chroma
  location), so the shared numbers invite unsafe casts.
- Open sets: every carrier admits unassigned and reserved values, and validation
  differs by library.
- No mastering metadata, no white point independent of primaries, and nothing
  for printers, cameras or measured displays, which is why ICC persists.
- Two carriers per file (container and bitstream) can disagree, and
  implementations resolve it differently.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                    | Trade-off                                                                  |
| ---------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Index into named standards, not a colour model | Codecs share one registry; meanings live in the cited specs  | Each reader implements every curve and matrix it accepts, or refuses them  |
| Coding-independent fields                      | AV1, HEVC, HEIF and PNG import the tables without redefining | Each carrier picks its own widths and presence rules (8 or 16 bits, flags) |
| Open 8-bit sets with reserved values           | New entries (YCgCo-R 16, 17) need no carrier change          | Readers must store unknown values; validation differs by library           |
| Primaries carry their white point              | One number names a full RGB space                            | JPEG XL's split white point does not map one to one                        |
| A 1-bit range flag                             | Matches the bitstream fields it came from                    | Libraries add "unspecified" and renumber it (FFmpeg, Vulkan)               |

## Sources

- [ITU-T H.273][h273] (editions and title).
- [W3C PNG Third Edition, `cICP`][png3-cicp].
- libavif: [`avif.h` range][avif-range], [primaries][avif-cp],
  [transfer][avif-tc], [matrix][avif-mc], [`avifImage` fields][avif-image];
  [`read.c` `colr`][avif-colr], [`cicpSet`][avif-cicpset], [`mini`][avif-mini],
  [sequence-header harvest][avif-harvest], [range mismatch][avif-range-mismatch],
  [grid tiles][avif-grid];
  [`obu.c` AV1][avif-av1], [AV2][avif-av2]; [`colr.c` primaries][avif-prim-table],
  [matrices][avif-mc-table], [defaults][avif-default];
  [`reformat.c`][avif-reformat].
- dav1d: [`headers.h` enums][dav1d-enums], [sequence header][dav1d-seq],
  [`obu.c`][dav1d-obu].
- FFmpeg: [`pixfmt.h` primaries][ff-pri], [transfer][ff-trc],
  [matrix][ff-spc], [range][ff-range]; [`mov.c`][ff-mov];
  [`pngdec.c` parse][ff-png-parse], [apply][ff-png-apply].
- libpng: [`pngset.c`][png-set], [`pngrutil.c`][png-handle].
- libjxl: [`color_encoding.h`][jxl-enc].
- Vulkan-Docs: [`vk.xml` YCbCr][vk-ycbcr], [colour spaces][vk-colorspace],
  [`video.xml` H.265 VUI][vk-h265], [AV1 colour config][vk-av1],
  [AV1 primaries][vk-av1-pri],
  [`samplers.adoc`][vk-sampler], [`textures.adoc`][vk-conv].
- Related deep-dives: [libavif][libavif], [libpng][libpng], [libjxl][libjxl],
  [Skia][skia], [libheif][libheif], [image-rs][image-rs].

<!-- References -->

[h273]: https://www.itu.int/rec/T-REC-H.273
[png3-cicp]: https://www.w3.org/TR/png-3/#cICP-chunk
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-metadata]: ./concepts.md#image-metadata
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[c-primaries]: ./concepts.md#colour-space-primaries-and-white-point
[c-transfer]: ./concepts.md#transfer-function
[c-ycbcr]: ./concepts.md#ycbcr-and-matrix-coefficients
[c-range]: ./concepts.md#full-and-limited-range
[libavif]: ./libavif.md
[libpng]: ./libpng.md
[libjxl]: ./libjxl.md
[skia]: ./skia.md
[libheif]: ./libheif.md
[image-rs]: ./image-rs.md
[avif-repo]: https://github.com/AOMediaCodec/libavif
[dav1d-repo]: https://github.com/videolan/dav1d
[ffmpeg-repo]: https://github.com/FFmpeg/FFmpeg
[libpng-repo]: https://github.com/glennrp/libpng
[jxl-repo]: https://github.com/libjxl/libjxl
[vk-repo]: https://github.com/KhronosGroup/Vulkan-Docs
[avif-range]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L318-L330
[avif-cp]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L332-L357
[avif-tc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L363-L387
[avif-mc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L394-L414
[avif-image]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L798-L806
[avif-colr]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2590-L2627
[avif-cicpset]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L1071-L1076
[avif-mini]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L4265-L4286
[avif-harvest]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L6749-L6780
[avif-range-mismatch]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L6908-L6926
[avif-grid]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L1917-L1936
[avif-av1]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/obu.c#L305-L331
[avif-av2]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/obu.c#L527-L580
[avif-prim-table]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/colr.c#L10-L72
[avif-mc-table]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/colr.c#L110-L133
[avif-default]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/colr.c#L156-L184
[avif-reformat]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat.c#L125-L139
[dav1d-enums]: https://github.com/videolan/dav1d/blob/c6f51c881d80b43830b7c1fff2ba0d48599e8073/include/dav1d/headers.h#L122-L175
[dav1d-seq]: https://github.com/videolan/dav1d/blob/c6f51c881d80b43830b7c1fff2ba0d48599e8073/include/dav1d/headers.h#L183-L234
[dav1d-obu]: https://github.com/videolan/dav1d/blob/c6f51c881d80b43830b7c1fff2ba0d48599e8073/src/obu.c#L227-L279
[ff-pri]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavutil/pixfmt.h#L643-L671
[ff-trc]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavutil/pixfmt.h#L673-L705
[ff-spc]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavutil/pixfmt.h#L707-L732
[ff-range]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavutil/pixfmt.h#L734-L790
[ff-mov]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavformat/mov.c#L2211-L2296
[ff-png-parse]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavcodec/pngdec.c#L1659-L1668
[ff-png-apply]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavcodec/pngdec.c#L772-L791
[png-set]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngset.c#L136-L157
[png-handle]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1876-L1914
[jxl-enc]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/color_encoding.h#L32-L98
[vk-ycbcr]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/vk.xml#L13423-L13437
[vk-colorspace]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/vk.xml#L23280-L23293
[vk-h265]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/video.xml#L502-L512
[vk-av1]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/video.xml#L953-L971
[vk-av1-pri]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/xml/video.xml#L1653-L1656
[vk-sampler]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/samplers.adoc#L893-L908
[vk-conv]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/textures.adoc#L1125-L1136
