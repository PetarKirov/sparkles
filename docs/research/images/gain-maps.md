# HDR gain maps (specifications; C and C++ implementations)

One file that renders as SDR everywhere and as HDR where the display has headroom:
a base image, a second "gain map" image and at most eighteen numbers and a flag,
specified by Android's Ultra HDR JPEG format and by ISO 21496-1, and read here
through the three open implementations that parse and apply them (libavif, Skia, libultrahdr).

| Field         | Value                                                                                                                                                                                                                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | Specifications; implementations in C (libavif), C++ (Skia, libultrahdr)                                                                                                                                                                                                                                |
| License       | Ultra HDR: a public web specification ([Android][uhdr]). ISO 21496-1: a paid ISO standard, read here only through implementations. libavif BSD-2-Clause, Skia BSD-3-Clause, libultrahdr MIT and Apache-2.0 (its `LICENSE`: "both"); Skia and libultrahdr carry an Adobe notice ([NOTICE][uhdr-notice]) |
| Repository    | [AOMediaCodec/libavif][avif-repo], [google/skia][skia-repo], [google/libultrahdr][uhdr-repo]                                                                                                                                                                                                           |
| Revision read | libavif `9b07a9d7a874b159bb4e14b80a6f08bb469d06f7`; Skia `3ad790ab4d6d596efae0d70e4b8bf7d339121984`; libultrahdr `5f117294cb701170b9198ed8eae16270aa84896c` (October 26, 2026, shallow clone of `main`)                                                                                                |
| Documentation | [Ultra HDR Image Format v1.1][uhdr]; WWDC24 session 10177 [Use HDR for dynamic image experiences in your app][wwdc24]; the comment blocks of [`avif.h`][avif-gm-struct] and [`SkGainmapInfo.h`][sk-info-math]                                                                                          |
| Category      | Colour: HDR representation and metadata (a format feature spanning JPEG, AVIF, HEIF and JPEG XL)                                                                                                                                                                                                       |
| Tier          | B                                                                                                                                                                                                                                                                                                      |
| Last reviewed | November 7, 2026                                                                                                                                                                                                                                                                                       |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** were run in `/tmp/gainmap-demo`:
> nixpkgs `libavif` 1.3.0's `avifgainmaputil` on files from libavif's pinned
> `tests/data/`, `exiftool` 13.52 on Skia's `resources/images/gainmap_iso21496_1.jpg`,
> and a 30-line D decoder for the ISO 21496-1 payload (`/tmp/gainmap-tools/iso_dump.d`,
> built with nixpkgs `ldc2`). The 1.3.0 binary is older than the libavif revision
> read; where they differ the text says so. ISO 21496-1 itself was not read; its
> syntax is quoted from the field-by-field comments in libavif's parser. No
> performance number in this page was measured.

---

## Overview

### What it solves

A [gain map](./concepts.md#hdr-gain-map) stores one rendition (usually SDR) as an
ordinary image, so every legacy decoder shows something correct, plus a per-pixel
log-ratio image that turns it into the other rendition. The Ultra HDR page states
the constraints the design answers: the file must "Be backward compatible, so that on
naive viewers, the conventional SDR image is displayed", and the display technique
must "Be able to adapt to any ratio between a display's HDR and SDR white points,
which can vary significantly between devices, or even temporally on a single
device" ([Ultra HDR, Motivation][uhdr]).

### Design philosophy

The gain is applied in log space and scaled by how much headroom the display has
now, not by a fixed target. The Android page is explicit that this is load-bearing:
"The gain map must be applied as shown earlier (using exponentiation) to properly
produce the needed relative tonal relationships ... If the Gain Map is applied any
other way, such as via simple linear interpolation, then the relative tonal
relationships within the image are correct only at max content boost"
([Ultra HDR, Display][uhdr]). libavif's header names the three parts the rest of
this page uses: "base image: main image stored in the file, shown by viewers that do
not support gain maps"; "alternate image: image obtained by combining the base image
and the gain map"; "gain map: data structure that contains pixels and metadata used
for conversion between the base image and the alternate image"
([`avif.h`][avif-gm-struct]).

## How it works

### The metadata

Every implementation carries the same per-channel quintuple and two headrooms;
they differ in units. libavif stores ISO 21496-1's rationals as read
([`avif.h`][avif-gm-struct]; abridged, with the trailing `// log2` comments
condensing the header's "log2-encoded"):

```c
// gainMapLog2 = lerp(gainMapMin, gainMapMax, pow(gainMapEncoded, 1/gainMapGamma));
avifSignedFraction gainMapMin[3];    // log2
avifSignedFraction gainMapMax[3];    // log2
avifUnsignedFraction gainMapGamma[3];
// toneMappedLinear = ((baseImageLinear + baseOffset) * exp2(gainMapLog * w)) - alternateOffset;
avifSignedFraction baseOffset[3];
avifSignedFraction alternateOffset[3];
avifUnsignedFraction baseHdrHeadroom;      // log2
avifUnsignedFraction alternateHdrHeadroom; // log2
avifBool useBaseColorSpace;
```

| Concept                   | Ultra HDR XMP (`hdrgm:`)                  | ISO 21496-1 / libavif                                | Skia `SkGainmapInfo`                | libultrahdr public struct                         |
| ------------------------- | ----------------------------------------- | ---------------------------------------------------- | ----------------------------------- | ------------------------------------------------- |
| Gain range                | `GainMapMin`, `GainMapMax` (log2)         | `gain_map_min`, `gain_map_max` (log2 rationals)      | `fGainmapRatioMin`, `Max` (linear)  | `min_content_boost`, `max_content_boost` (linear) |
| Encoding gamma            | `Gamma`                                   | `gamma`                                              | `fGainmapGamma` (stored as 1/gamma) | `gamma`                                           |
| Offsets                   | `OffsetSDR`, `OffsetHDR`                  | `base_offset`, `alternate_offset`                    | `fEpsilonSdr`, `fEpsilonHdr`        | `offset_sdr`, `offset_hdr`                        |
| Where the map is fully on | `HDRCapacityMin`, `HDRCapacityMax` (log2) | `base_hdr_headroom`, `alternate_hdr_headroom` (log2) | `fDisplayRatioSdr`, `Hdr` (linear)  | `hdr_capacity_min`, `max` (linear)                |
| Which rendition is stored | `BaseRenditionIsHDR` (must be `False`)    | implied by headroom order                            | `fBaseImageType` `kSDR` or `kHDR`   | no field (SDR base assumed)                       |
| Colour space of the math  | the base image's                          | `use_base_colour_space` flag                         | `fGainmapMathColorSpace`            | `use_base_cg`                                     |

Sources: [Ultra HDR XMP table][uhdr], [`read.c`][avif-parse-meta],
[`SkGainmapInfo.h`][sk-info-fields], [`ultrahdr_api.h`][uhdr-api-meta]. Skia's
parser converts on the way in, `info.fGainmapRatioMin[i] = std::exp2(gainMapMin[j])`
and `info.fGainmapGamma[i] = 1.f / gamma[j]` ([`SkGainmapInfo.cpp`][sk-parse]).

### Applying it for a display

The renderer supplies one number, the display's current HDR headroom H (log2 of HDR
white over SDR white). libavif's weight ([`gainmap.c`][avif-weight]):

```c
const float w = AVIF_CLAMP((hdrHeadroom - baseHdrHeadroom) / (alternateHdrHeadroom - baseHdrHeadroom), 0.0f, 1.0f);
return (alternateHdrHeadroom < baseHdrHeadroom) ? -w : w;
```

and the per-channel kernel, in linear light after the base's transfer function is
undone ([`gainmap.c`][avif-apply-loop]):

```c
const float gainMapLog2 = lerp(gainMapMin[c], gainMapMax[c], powf(gainMapValue, gammaInv[c]));
const float toneMappedLinear = (baseLinear + baseOffset[c]) * exp2f(gainMapLog2 * weight) - alternateOffset[c];
```

A negative weight runs the map backwards, so an HDR base tone-maps down to SDR with
the same code. Skia states the same rule in its header, with `W - 1` for an HDR base:
"D = (B + fEpsilonHdr) * exp(L * (W - 1)) - fEpsilonSdr", and notes that "the base
used for the log() and exp() functions does not affect the results"
([`SkGainmapInfo.h`][sk-info-math]). The Ultra HDR page writes the HDR-base case as
`weight_factor = 1.0 - clamp(unclamped_weight_factor, 0.0, 1.0)`, a non-negative
weight; read literally that disagrees in sign with both implementations, but the
same page requires `BaseRenditionIsHDR` to be `False` ([Ultra HDR, Display][uhdr]).

**Verified:** `avifgainmaputil printmetadata` on `seine_sdr_gainmap_srgb.avif` prints
base headroom 0, alternate headroom 1.3 (`13/10`), min -0.256907, max 1.27718,
offsets `1/64`, gamma 0.953784 and "Use Base Color Space: True";
`seine_hdr_gainmap_srgb.avif` has the headrooms swapped (1.3 and 0). Tone-mapping the
SDR-base file to BT.2020 PQ PNGs with `tonemap --headroom H --cicp-output 9/16/9`
gives normalised mean/max of 0.4668/0.5843 at H = 0, 0.4871/0.6275 at 0.65 and
0.5073/0.6745 at 1.3, and a byte-identical PNG at H = 3: the weight saturates at the
alternate headroom. (Without `--cicp-output` the tool writes sRGB at H = 0 and
BT.709 PQ above it, so those outputs are not comparable across H.)

The gain map is usually smaller than the base. The Android page recommends "¹⁄₁₆ of
the size (¼ on each dimension)" and requires upsampling to be "bilinear or better"
([Ultra HDR, Encode][uhdr]); libavif rescales the whole gain map to the base size
with `avifImageScale` before the loop ([`gainmap.c`][avif-rescale]), while Skia's
shader samples it through its own `SkSamplingOptions` and rect, so the image shader's sampler
does the upsampling ([`SkGainmapShader.h`][sk-shader-h]).

### Containers

| Container        | Where the gain map image lives                                                                                                                      | Where the metadata lives                                                                                                                                                        |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ultra HDR JPEG   | a second JPEG appended after the primary's EOI, indexed by CIPA MPF (`APP2 "MPF\0"`) and by a GContainer `Container:Directory` in the primary's XMP | `hdrgm:` XMP in the gain map JPEG; `hdrgm:Version="1.0"` in the primary signals the format                                                                                      |
| ISO 21496-1 JPEG | the same MPF secondary image                                                                                                                        | `APP2` with signature `urn:iso:std:iso:ts:21496:-1`: version only in the primary, full payload in the gain map ([`SkJpegConstants.h`][sk-jpeg-sig], [`jpegr.cpp`][uhdr-layout]) |
| AVIF / HEIF      | an image item that is the second `dimg` input of a `tmap` derived item, which is grouped with the primary in an `altr` entity group                 | the `tmap` item's payload (version byte, then the ISO structure); alternate colour as the `tmap` item's `colr`, `clli`, `pixi` ([`read.c`][avif-find-tmap])                     |
| AVIF `mini`      | fields of the low-overhead box: `gainmap_flag`, dimensions, bit depth, `tmap_icc_flag`, explicit CICP ([`read.c`][avif-mini])                       | inline in the same box                                                                                                                                                          |
| JPEG XL          | a naked JPEG XL codestream inside a `jhgm` box                                                                                                      | the ISO 21496-1 blob plus an optional `JxlColorEncoding` and a compressed alternate ICC ([`gain_map.h`][jxl-bundle])                                                            |

**Verified:** `exiftool -v1` on Skia's `gainmap_iso21496_1.jpg` (1,996 bytes) lists,
in the primary, `APP0`, a 534-byte `APP2` (ICC), a 32-byte `APP2` and, after the
quantisation, frame and Huffman tables, an 86-byte `APP2` (MPF, `NumberOfImages = 2`, second image of 879 bytes at offset 1117), and no
XMP at all; the second image has `APP0`, an ICC `APP2` and a 169-byte `APP2`. The D
decoder reads the primary's ISO segment as `min_version 0 writer_version 0` with
nothing after it, and the gain map's as multichannel, `use_base_colour_space`
false, base headroom 2 (`8192/4096`), alternate headroom 1 and, for red, min
4.6438 (`19021/4096`) and max 1.

libultrahdr's own comment gives the Ultra HDR JPEG order: optional `EXIF`, "(Required,
XMP package) APP1", "(Required, ISO 21496-1 metadata, version only) APP2", "(Required,
MPF package) APP2", the primary, then the gain map JPEG with its XMP and "(Required,
ISO 21496-1 metadata) APP2" ([`jpegr.cpp`][uhdr-layout]). Its build defaults
disagree with that comment and with the Android page's advice that an encoder
"should encode both metadata formats": `UHDR_WRITE_XMP` defaults to `FALSE` and
`UHDR_WRITE_ISO` to `TRUE` ([`CMakeLists.txt`][uhdr-cmake]); the Skia fixture above
likewise has no XMP. On decode the page says "If both types of metadata are
present ... prefer using the ISO 21496-1 metadata" ([Ultra HDR, ISO 21496-1
Compatibility][uhdr]); Skia does so, trying ISO first and Adobe XMP only if it fails
([`SkJpegMetadataDecoderImpl.cpp`][sk-extract]).

### Apple

Apple has three generations. "Since 2020, iPhone cameras have been capturing
images with embedded gain maps" ([WWDC24 session 10177][wwdc24]); in the older
files the headroom sits in two Apple maker-note EXIF tags (33 and 48), and libavif turns
them into stops with the piecewise formula from Apple's documentation
([`avifjpeg.c`][avif-apple-exif]), and later files add `HDRGainMap:HDRGainMapHeadroom`
to the gain map's XMP ([libavif `tests/data/README.md`][avif-apple-tests]). The two
open readers do not agree on that legacy curve: libavif maps it onto the ISO model
with min 0, max log2 of the headroom and gamma 1 ([`avifjpeg.c`][avif-apple-xmp]),
while Skia keeps a `Type::kApple` and evaluates
`L = log(1.0 + (appleH - 1.0) * pow(G.r, appleG))` with `appleG = 1.961`
([`SkGainmapShader.cpp`][sk-shader-sksl], [`SkGainmapShader.cpp`][sk-shader-apple]).
At WWDC24 Apple said "With the release of iOS 18, we are transitioning to Adaptive
HDR Gain Maps and related metadata. This new generation is based on the latest
draft", that "JPEG files also fully support Adaptive HDR, with a slightly different
syntax compared to HEIF", and named `kCGImageAuxiliaryDataTypeISOGainMap` for
writing ([WWDC24 session 10177][wwdc24]). The session says "Adaptive HDR has now
reached Committee Draft at ISO" but leaves the document number to a slide;
reading "Adaptive HDR" as ISO 21496-1 is an inference from that statement and the
key's name.

**Verified (version skew):** nixpkgs `avifgainmaputil convert` 1.3.0 reports
`apple_gainmap_new.jpg` "does not contain a gain map", and also rejects the ISO-only
Skia JPEG, because its JPEG reader looks only at XMP. libavif 1.3.0's
`apps/shared/avifjpeg.c` contains no Apple parser; 1.4.0 added one ("Add support for
converting jpeg files with Apple style gain maps", `CHANGELOG.md` at the pinned
revision), and nixpkgs `avifgainmaputil` 1.4.2 converts `apple_gainmap_new.jpg`
(alternate headroom 2.1804) while still rejecting the ISO-only Skia JPEG: the pinned
`avifjpeg.c` has no ISO 21496-1 `APP2` reader either. Converting the XMP-carrying
`paris_exif_xmp_gainmap_bigendian.jpg` works and prints min 0, max 3.5 (`7/2`),
offsets 0, gamma 1, headrooms 0 and 3.5.

## Analysis

### 1. Pixel and memory model

A gain-mapped image is two images of different sizes and formats bound by
metadata: the base keeps its own planes, the gain map is 8-bit JPEG in Ultra HDR
("must be encoded using 8-bit, unsigned integer values", [Ultra HDR][uhdr]), any AV1
depth in AVIF, and single-channel or three-channel. libavif's `avifGainMap::image` is
a full `avifImage` whose "colorPrimaries and transferCharacteristics fields shall be
2" because gains carry no colour ([`avif.h`][avif-gm-struct]). libavif's incremental
decoder reports gain-map rows in proportion to colour rows: "the number of available
gain map rows is at least:
`roundf((float)decoded_row_count / decoder->image->height * decoder->image->gainMap->image->height)`"
([`avif.h`][avif-rows]).

### 2. Genericity mechanism

Not applicable: both specifications define a fixed record, not an interface. The
implementations model it as one concrete struct each (`avifGainMap`,
`SkGainmapInfo`, `uhdr_gainmap_metadata_t`) with float or rational fields and no
type parameters.

### 3. Colour and metadata

The metadata is small, but it reaches into the colour model in three places. The
math runs in linear light, so the base's transfer function must be known
([CICP](./concepts.md#cicp) or an [ICC profile](./concepts.md#icc-profile)). The
math colour space is either the base's or the alternate's primaries
(`use_base_colour_space`), and the alternate's colour is described separately: libavif
keeps `altICC`, `altColorPrimaries`, `altTransferCharacteristics`, `altCLLI` and
`altDepth` ([`avif.h`][avif-gm-struct]); when `use_base_colour_space` is false, Skia
takes the math primaries from the gain map JPEG's own ICC profile
([`SkJpegMetadataDecoderImpl.cpp`][sk-extract]),
whereas the Ultra HDR page says "If present, the gain map's color profile isn't
used" ([Ultra HDR][uhdr]). libavif's `avifImageApplyGainMap` refuses a base or alternate that carries ICC
(the lower-level `avifRGBImageApplyGainMap` takes CICP enums only):
"Tone mapping for images with ICC profiles is not supported"
([`gainmap.c`][avif-icc]). The output needs an SDR-white reference to become
absolute light: libavif's `clli` computation uses `#define SDR_WHITE_NITS 203.0f`
([`gainmap.c`][avif-weight]). The metadata itself travels as
[image metadata](./concepts.md#image-metadata) (XMP) in Ultra HDR and as a binary
blob or derived item elsewhere.

### 4. I/O and codec architecture

Gain maps are a [container](./concepts.md#container-and-bitstream) feature: no codec
bitstream changes. That makes discovery the hard part. Skia's
`findGainmapImage` walks MPF secondary images, parses each one's metadata to see
whether it "identifies itself as a gainmap", and falls back to the GContainer
offset ([`SkJpegMetadataDecoderImpl.cpp`][sk-find]). libavif finds the `tmap` item
whose first `dimg` input is the colour item and requires it to precede the primary
in an `altr` group ([`read.c`][avif-find-tmap], [`read.c`][avif-altr]). Decoding the
gain map is opt-in: `AVIF_IMAGE_CONTENT_DECODE_DEFAULT` is colour and alpha only
([`avif.h`][avif-content]). Unknown versions degrade to SDR: "Unsupported gain map
version. Simply ignore the gain map." ([`read.c`][avif-ignore]).

### 5. Hostile input and safety

The payload is a few dozen rationals, so the risks are division by zero, NaN and
contradictory ranges ([hostile input](./concepts.md#hostile-input)).
`avifGainMapValidateMetadata` rejects zero denominators, max less than min, zero
gamma and zero headroom denominators ([`gainmap.c`][avif-validate]), and the apply
loop still fails on NaN: "Degenerate gain map parameters produce NaN at pixel"
([`gainmap.c`][avif-apply-loop]). **Verified:** `seine_sdr_gainmap_gammazero.avif`
fails with "Invalid tone mapped image item (Per-channel gamma is 0 in gain map
metadata)". Skia's ISO parser checks only that bytes are present and that
`minimum_version` is 0; it divides by the raw denominator and accepts any range
([`SkGainmapInfo.cpp`][sk-parse]). Its own test fixture expects a red channel with
ratio min 25 and max 2 ([`JpegGainmapTest.cpp`][sk-test-iso]), which the decoder
above confirms as log2 min 4.6438 over max 1, and which libavif's validator would
reject as "Per-channel max is less than per-channel min". The Android page's policy
for bad metadata is to fall back: "the gain map should be ignored and the SDR image
should be displayed" ([Ultra HDR, Decode][uhdr]).

### 6. Allocation and ownership

The metadata is a fixed-size record, so only the gain map image and the alternate
ICC allocate. libavif's `avifGainMap` owns its `image`, which "gets freed when calling
avifGainMapDestroy()", and must itself come from `avifGainMapCreate()` because the
struct may grow ([`avif.h`][avif-gm-struct]). libjxl's `JxlGainMapBundle` is the
opposite, a non-owning view: "The pointers in this structure do not take ownership of
the memory they point to" ([`gain_map.h`][jxl-bundle]).

### 7. CPU parallelism and SIMD

libavif's reference apply is a nested scalar loop with `powf` and `exp2f` per channel
per pixel ([`gainmap.c`][avif-apply-loop]). libultrahdr hoists the transcendental out:
`GainLUT` precomputes `exp2(logBoost * gainmapWeight)` at 1024 points
(`kGainFactorNumEntries = 1 << 10`) over the normalised gain range for a given display
weight, so the per-pixel work is a table lookup and a multiply-add
([`gainmapmath.h`][uhdr-lut]); since the weight is constant per frame, the table need
be rebuilt only when headroom changes.

### 8. GPU offload and interop

Applying a gain map is a two-texture fragment shader. Skia builds an `SkRuntimeEffect`
whose body is `half3 H = (S.rgb + epsilonBase.rgb) * exp(L * W) - epsilonOther.rgb;`
and returns the base shader unchanged when `W == 0`
([`SkGainmapShader.cpp`][sk-shader-sksl], [`SkGainmapShader.cpp`][sk-shader-weight]).
libultrahdr ships a GLES path with the same kernel as `applyGainMapSample`
([`applygainmap_gl.cpp`][uhdr-gl]). Display headroom is a per-frame uniform, so
re-rendering on a brightness change does not re-decode anything.

### 9. Temporal, animation and containers

The headroom input is temporal even for a still: the Android page notes that max
display boost "can change over time based on device settings and other factors"
([Ultra HDR, Definitions][uhdr]). The AVIF binding reuses ISOBMFF's `altr` group, so a
reader that does not know `tmap` picks the primary item as the alternative it can
display. libavif's lookup "Assumes that there is a single tmap item, and not, e.g.,
a grid of tmap items", although base and gain map may each be a grid
([`read.c`][avif-find-tmap]; test files `color_grid_gainmap_different_grid.avif`).

### 10. Testing and conformance

There is no public conformance corpus for ISO 21496-1 in these trees; each project
carries fixtures. libavif has 22 `*gainmap*` files in `tests/data/`, including the
gamma-zero and wrong-`altr` cases asserted in [`avifgainmaptest.cc`][avif-tests] and
old and new Apple JPEGs ([`tests/data/README.md`][avif-apple-tests]). Skia asserts
parsed `SkGainmapInfo` values for JPEG fixtures across unseekable, seekable and
memory-mapped streams ([`JpegGainmapTest.cpp`][sk-test-iso]) and for PNG fixtures
([`PngGainmapTest.cpp`][sk-test-png]). libultrahdr has
`gainmapmetadata_test.cpp` and three fuzzers (`ultrahdr_dec_fuzzer.cpp`,
`ultrahdr_enc_fuzzer.cpp`, `ultrahdr_legacy_fuzzer.cpp`). The three implementations
are natural differential oracles for each other, since they disagree on validation
and on Apple's legacy curve.

## Lessons for Sparkles

- **Q5** The minimum model is a base image, an optional gain map image and an eight-field
  record (five per-channel triples, two headrooms, one colour-space flag), plus the
  alternate rendition's colour description. Keeping it as rationals as read (libavif)
  preserves round-trips; Skia's float conversion with its fixed `0x10000000` or `0x1000`
  denominators on write does not ([`SkGainmapInfo.cpp`][sk-write]).
- **Q5** Three unit conventions coexist for one quantity (log2 rationals, linear
  ratios, natural log in the shader); a D type that fixes one unit and converts at
  each format boundary removes a class of bugs the table above shows.
- **Q5** Gain-map application needs the base's transfer function and primaries, so it
  depends on whatever colour model Sparkles adopts; the baseline has none
  ([existing code, G4][baseline]).
- **Q4** Discovery differs per container (MPF plus XMP or APP2 in JPEG, `tmap` plus
  `altr` in HEIF/AVIF, `jhgm` in JPEG XL), but the record is the same; this argues for
  one gain-map type that format readers populate, as [libavif](./libavif.md),
  [libjxl](./libjxl.md) and Skia's [`SkCodec`](./skia.md) each do in their own way, and
  for ignoring rather than failing on an unknown version.
- **Q4** `sparkles:wired` would need to express the ISO payload's mixed bit fields and
  big-endian rationals with a channel count that depends on a flag, and the JPEG
  side's multi-segment and MPF offset arithmetic.
- **Q7** The apply kernel is a natural first shared CPU/GPU kernel: per-pixel, two
  inputs at different resolutions, one per-frame uniform. libultrahdr's LUT shows the
  CPU form; Skia's runtime effect shows the GPU form.
- **Q8** libavif, Skia and libultrahdr disagree on validation and on Apple's legacy
  maps, so differential tests against all three are informative; libavif's
  `tests/data/` and Skia's `resources/images/gainmap*` are ready fixtures.
- **Q9** Gain maps touch format readers, the colour model and the renderer; placing
  the record with colour metadata rather than in any one format package matches how
  all three implementations keep it codec-independent.

## Strengths

- Backward compatible by construction: a legacy reader shows the base image.
- One file adapts continuously to any display headroom, including changing headroom.
- Small: the Android page recommends a map at a quarter of each dimension.
- The apply step is a cheap, embarrassingly parallel per-pixel formula.
- ISO 21496-1 gives one metadata record across JPEG, HEIF, AVIF and JPEG XL.

## Weaknesses

- Two JPEG metadata syntaxes (XMP and ISO `APP2`) plus Apple's legacy forms, and
  writers that emit only one ([`CMakeLists.txt`][uhdr-cmake]).
- The standard is paywalled; open readers learn the syntax from each other's comments.
- Validation is implementation-defined in practice: Skia accepts ranges libavif rejects.
- Correct application needs a full colour pipeline (linearisation, primaries
  conversion, output encoding); libavif still declines ICC-tagged images.
- Rendering needs the display's live headroom; all three implementations take it as
  a parameter (`hdrHeadroom`, `dstHdrRatio`, `uhdr_dec_set_out_max_display_boost`),
  so obtaining it is left to the caller.
- Skia and libultrahdr carry an Adobe technology notice
  ([NOTICE][uhdr-notice], [`SkGainmapInfo.h`][sk-info-math]).

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                    | Trade-off                                                                  |
| ------------------------------------------ | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Store one rendition plus a log-ratio map   | Legacy decoders show the base unchanged                      | Two images to locate, decode and resample; discovery is per container      |
| Weight by live display headroom            | One file adapts to any and to changing headroom              | The renderer must know the headroom every frame                            |
| Exponential, not linear, interpolation     | Tonal relationships hold at every boost (Ultra HDR, Display) | A transcendental per channel per pixel, or a LUT                           |
| Rationals in ISO 21496-1, reals in XMP     | Exact binary round-trips in the ISO form                     | Two syntaxes for one record; float writers lose exactness (Skia)           |
| Symmetric base (SDR or HDR) in ISO 21496-1 | An HDR base can tone-map down with the same formula          | Ultra HDR XMP forbids it; implementations differ on the HDR-base sign form |
| Versioned payload, ignore when unknown     | Old readers fall back to the base image                      | Unknown versions silently lose the HDR rendition                           |

## Sources

- Android, [Ultra HDR Image Format v1.1][uhdr], including the ISO 21496-1
  compatibility section and change log.
- Apple, [WWDC24 session 10177][wwdc24]; Apple's legacy headroom formula as cited in
  [`avifjpeg.c`][avif-apple-exif].
- libavif at `9b07a9d7`: [`avif.h`][avif-gm-struct], [`read.c`][avif-parse-meta],
  [`gainmap.c`][avif-apply-loop], [`apps/shared/avifjpeg.c`][avif-apple-xmp],
  [`avifgainmaptest.cc`][avif-tests].
- Skia at `3ad790ab`: [`SkGainmapInfo.h`][sk-info-math],
  [`SkGainmapInfo.cpp`][sk-parse], [`SkGainmapShader.cpp`][sk-shader-sksl],
  [`SkJpegMetadataDecoderImpl.cpp`][sk-find], [`SkXmp.cpp`][sk-xmp].
- libultrahdr at `5f117294`: [`README.md`][uhdr-readme], [`ultrahdr_api.h`][uhdr-api-meta],
  [`jpegr.cpp`][uhdr-layout], [`gainmapmath.cpp`][uhdr-apply].
- libjxl at `e2948747`: [`gain_map.h`][jxl-bundle].

<!-- References -->

[uhdr]: https://developer.android.com/media/platform/hdr-image-format
[wwdc24]: https://developer.apple.com/videos/play/wwdc2024/10177/
[baseline]: ./baseline/existing-code.md#gaps-and-tensions
[avif-repo]: https://github.com/AOMediaCodec/libavif
[skia-repo]: https://github.com/google/skia
[uhdr-repo]: https://github.com/google/libultrahdr
[avif-gm-struct]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L612-L718
[avif-content]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1236-L1251
[avif-rows]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1464-L1469
[avif-parse-meta]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2258-L2334
[avif-mini]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L4326-L4381
[avif-find-tmap]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5801-L5851
[avif-altr]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5853-L5876
[avif-ignore]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5895-L5918
[avif-weight]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L51-L71
[avif-rescale]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L195-L221
[avif-apply-loop]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L248-L303
[avif-icc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L339-L342
[avif-validate]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L441-L468
[avif-apple-exif]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/apps/shared/avifjpeg.c#L455-L476
[avif-apple-xmp]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/apps/shared/avifjpeg.c#L797-L892
[avif-apple-tests]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/data/README.md#L651-L669
[avif-tests]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/gtest/avifgainmaptest.cc#L862-L893
[sk-info-math]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/private/SkGainmapInfo.h#L16-L42
[sk-info-fields]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/private/SkGainmapInfo.h#L43-L95
[sk-parse]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkGainmapInfo.cpp#L49-L182
[sk-write]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkGainmapInfo.cpp#L27-L47
[sk-jpeg-sig]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkJpegConstants.h#L58-L66
[sk-extract]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkJpegMetadataDecoderImpl.cpp#L111-L173
[sk-find]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkJpegMetadataDecoderImpl.cpp#L176-L247
[sk-xmp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkXmp.cpp#L518-L637
[sk-shader-h]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/private/SkGainmapShader.h#L21-L57
[sk-shader-sksl]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/shaders/SkGainmapShader.cpp#L24-L75
[sk-shader-weight]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/shaders/SkGainmapShader.cpp#L124-L144
[sk-shader-apple]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/shaders/SkGainmapShader.cpp#L183-L185
[sk-test-iso]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/tests/JpegGainmapTest.cpp#L526-L551
[sk-test-png]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/tests/PngGainmapTest.cpp#L71-L117
[uhdr-readme]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/README.md#L1-L14
[uhdr-notice]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/adobe-hdr-gain-map-license/NOTICE#L1
[uhdr-api-meta]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/ultrahdr_api.h#L266-L283
[uhdr-layout]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/lib/src/jpegr.cpp#L1066-L1106
[uhdr-cmake]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/CMakeLists.txt#L76-L77
[uhdr-apply]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/lib/src/gainmapmath.cpp#L816-L822
[uhdr-lut]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/lib/include/ultrahdr/gainmapmath.h#L452-L470
[uhdr-gl]: https://github.com/google/libultrahdr/blob/5f117294cb701170b9198ed8eae16270aa84896c/lib/src/gpu/applygainmap_gl.cpp#L128-L142
[jxl-bundle]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/gain_map.h#L24-L63
