# ICC v4 and iccMAX (specification)

The International Color Consortium's profile format: a tagged binary container that
describes a colour encoding as data, read here from the ICC.1:2022 (v4.4) and ICC.2:2023
(iccMAX) texts and through two implementations at opposite ends, Google's `skcms` and
Little CMS 2.

| Field         | Value                                                                                                                                                                                                                                  |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Specification (binary format); implementations read in C and C++                                                                                                                                                                       |
| License       | Specification free to download from the ICC; `skcms` BSD-3-Clause (Skia); Little CMS MIT                                                                                                                                               |
| Repository    | none for the specification; implementations [google/skia `modules/skcms`][skcms-tree] and [mm2/Little-CMS][lcms-repo]                                                                                                                  |
| Revision read | [ICC.1:2022][icc1] (profile version 4.4.0.0) and [ICC.2:2023][icc2] (profile version 5.0.0.0); Skia `3ad790ab4d6d596efae0d70e4b8bf7d339121984` (`skcms` roll `6010f358`); Little CMS `5546f1d68136f94281c9f6bfc027c6cdf4898da8` (2.20) |
| Documentation | [ICC specifications][icc-specs] · [`skcms_public.h`][sk-public] · Little CMS [`README.md`][lcms-readme]                                                                                                                                |
| Category      | Colour: profile format                                                                                                                                                                                                                 |
| Tier          | B                                                                                                                                                                                                                                      |
| Last reviewed | November 7, 2026                                                                                                                                                                                                                       |

> [!NOTE]
> **What was run.** A scratch program, `/tmp/icc-demo/probe.cc` (outside this repository),
> compiled `skcms` and Little CMS 2.20 from `git archive` exports of the pinned
> revisions (GCC, x86_64 Linux, `skcms` baseline path only), generated a v4.3 sRGB
> profile with `cmsCreate_sRGBProfile`, mutated it in twelve ways and fed the original
> and every variant to `skcms_Parse` and `cmsOpenProfileFromMem`. Results marked **verified**
> come from that run. No performance number on this page was measured.

---

## Overview

### What it solves

Image files say what their numbers mean in two ways: by naming a standard encoding
([CICP][c-cicp] code points) or by shipping an [ICC profile][c-icc], a self-describing
map from device values to a common colorimetric space. The profile covers what an
enumeration cannot: measured displays, scanners, cameras, printers with CMYK or more
inks, and transforms that are lookup tables rather than formulas. ICC.1 states the
aim in its introduction: "it is usually desirable to define the transformation between
the colour data encoding and the profile connection space (PCS) at a high precision",
and "The profile format defined in this document provides that specification"
([ICC.1:2022, 0.3][icc1]). Every
stills format in this catalog carries one somewhere (see
[Embedding per format](#embedding-per-format)).

### Design philosophy

The ICC defines a file format and a reference computation, not an engine. A colour
management module (CMM) links a source profile to a destination profile through the
PCS, and the header's rendering intent is advisory: "Typically, the user or application
will set the rendering intent dynamically at runtime or embedding time. Therefore, this
flag may not have any meaning until the profile is used in some context"
([ICC.1:2022, 7.2.15][icc1]). The format is deliberately permissive about which
transform model a profile uses (matrix and curves, or lookup tables, or both), which
pushes complexity into readers. iccMAX widens the model further, to spectral PCS,
arbitrary observers and a programmable calculator element, and spends a major version
number to do so ([ICC.2:2023, 7.2.6][icc2]).

The two implementations read here take opposite positions on that permissiveness.
Little CMS claims the whole format: it "is a **FULL IMPLEMENTATION** of ICC specification
4.4, it fully supports all kind of V2 and V4 profiles, including abstract, devicelink
and named color profiles" ([`README.md`][lcms-readme]). `skcms` parses the subset a
browser meets in images and turns the rest away, returning a flat struct of the fields
it understands ([`skcms_public.h`][sk-profile]).

## How it works

### File layout: header, tag table, tag data

A profile is big-endian throughout. A fixed 128-byte header carries the size, the
preferred CMM, the version, the profile class, the data colour space, the PCS, a
creation date, the magic `acsp`, flags, the rendering intent, the PCS illuminant and a
16-byte profile ID ([ICC.1:2022, 7.2][icc1]). `skcms` maps it byte for byte, including
the tag count that follows:

```c
// modules/skcms/skcms.cc (abridged): "Maps to an in-memory profile so that fields
// line up to the locations specified in ICC.1:2010, section 7.2"
typedef struct {
    uint8_t size [ 4]; uint8_t cmm_type [ 4]; uint8_t version [ 4];
    uint8_t profile_class [ 4]; uint8_t data_color_space [ 4]; uint8_t pcs [ 4];
    ...
    uint8_t rendering_intent [ 4];
    uint8_t illuminant_X [ 4]; uint8_t illuminant_Y [ 4]; uint8_t illuminant_Z [ 4];
    uint8_t creator [ 4]; uint8_t profile_id [16]; uint8_t reserved [28];
    uint8_t tag_count [ 4]; // Technically not part of header, but required
} header_Layout;
```

([`skcms.cc`][sk-header])

The tag table is a count followed by 12-byte entries (signature, offset, size). ICC.1:2022
tightened it: "The tag table shall define a contiguous sequence of unique tag elements,
with no gaps", duplicate signatures are forbidden, partial overlaps are forbidden, and
several signatures may share one data element only if "both the offset and size ...
shall be the same" ([ICC.1:2022, 7.3.1][icc1]). Sharing is common in practice: the
profile Little CMS generates points `rTRC`, `gTRC` and `bTRC` at one `para` element at
offset 520 (**verified**, dumping the generated 588-byte profile). Each tag element
starts with a 4-byte type signature (`curv`, `para`, `XYZ `, `mAB `, `mluc`, …), so the
tag signature says what a tag means and the type signature says how it is encoded.
The profile ID is an MD5 over the whole profile with the flags, intent and ID fields
zeroed; zero means "not calculated" ([ICC.1:2022, 7.2.18][icc1]). Little CMS computes it
with `cmsMD5computeID` ([`cmsmd5.c`][lcms-md5]); `skcms` ignores it.

### Profile classes

| Class      | Signature | Direction                             | Notes                                               |
| ---------- | --------- | ------------------------------------- | --------------------------------------------------- |
| Input      | `scnr`    | device to PCS (and optionally back)   | scanners, cameras                                   |
| Display    | `mntr`    | both directions                       | monitors; `cmsCreate_sRGBProfile` writes this class |
| Output     | `prtr`    | both directions; matrix/TRC undefined | printers, CMYK and n-colour                         |
| DeviceLink | `link`    | device 1 to device 2, no PCS          | a pre-linked transform; no `wtpt` required          |
| ColorSpace | `spac`    | colour encoding to and from PCS       | e.g. a working space                                |
| Abstract   | `abst`    | PCS to PCS                            | an editing effect inserted between two profiles     |
| NamedColor | `nmcl`    | colour names to PCS and device values | spot-colour libraries                               |

The signatures are ICC.1:2022 Table 18; the directions follow Table 25 ([ICC.1:2022][icc1]).
iccMAX adds `cenc` (colour encoding space) and three multiplex classes, which Little CMS
already lists, commented "iccMAX only" ([`lcms2.h`][lcms-classes]). With the exception of
DeviceLink, every profile "shall contain" `desc`, `cprt`, `wtpt` and, when the
measurement white differs from D50, `chad` ([ICC.1:2022, 8.2][icc1]).

### The PCS: XYZ or Lab, relative to D50

The PCS is CIE XYZ or CIELAB under a D50 adopted white; the header's illuminant field
must round to X 0.9642, Y 1.0, Z 0.8249, "the nCIEXYZ values of CIE illuminant D50"
([ICC.1:2022, 7.2.16][icc1]). Profiles
made for other whites (sRGB's D65) adapt to D50 and record the adaptation in `chad`.
ICC.1:2022 also clarified "that PCSXYZ values can be negative" ([ICC.1:2022, Foreword][icc1]).
Lab has two 16-bit encodings: v4's, and a legacy v2 encoding that survives in
`lut16Type` and `namedColor2Type` "for backwards compatibility with profile version 2"
([ICC.1:2022, 10.10][icc1]). Little CMS inserts `_cmsStageAllocLabV2ToV4` stages when it
reads a `mft2` tag on a Lab PCS ([`cmsio1.c`][lcms-input-lut]).

### Two transform models

**Matrix/TRC.** Three tone response curves (`rTRC`, `gTRC`, `bTRC`) linearise the
device values, then three column vectors (`rXYZ`, `gXYZ`, `bXYZ`) form a 3×3 matrix to
PCSXYZ. Grey profiles use one `kTRC`. "Only the PCSXYZ encoding can be used with
matrix/TRC models" ([ICC.1:2022, 8.4.3][icc1]). A curve is either `curvType` (0 entries
for identity, 1 entry for a pure gamma, otherwise a sampled table) or
`parametricCurveType` with five function shapes. `skcms` folds both into one
seven-parameter function or a table:

```c
// modules/skcms/src/skcms_public.h (abridged)
//   linear = sign(encoded) *  (c*|encoded| + f)       , 0 <= |encoded| < d
//          = sign(encoded) * ((a*|encoded| + b)^g + e), d <= |encoded|
typedef struct skcms_TransferFunction {
    float g, a,b,c,d,e,f;
} skcms_TransferFunction;
```

([`skcms_public.h`][sk-tf])

**LUT-based.** `AToB0`, `AToB1`, `AToB2` (perceptual, colorimetric, saturation) map
device to PCS; `BToA0..2` go back. The v4 types `lutAToBType` (`mAB `) and
`lutBToAType` (`mBA `) chain "a set of one-dimensional curves, a 3 × 3 matrix with offset
terms, a set of one-dimensional curves, a multi-dimensional lookup table, and a set of
one-dimensional output curves", each element optional ([ICC.1:2022, 10.12.1][icc1]); the
v2 types `lut8Type` (`mft1`) and `lut16Type` (`mft2`) have a fixed matrix, input tables, a
CLUT with one grid size for every axis, and output tables. `skcms` describes the
evaluation order directly:

```c
// modules/skcms/src/skcms_public.h
//   A2B:  device -> [ "A" curves -> CLUT ] -> [ "M" curves -> matrix ] -> "B" curves -> PCS
//   B2A:  device <- [ "A" curves <- CLUT ] <- [ "M" curves <- matrix ] <- "B" curves <- PCS
```

([`skcms_public.h`][sk-a2b])

A profile may carry both models. Table 25 assigns matrix/TRC to the colorimetric intent
and leaves it "Undefined" for Output profiles ([ICC.1:2022, 9.1][icc1]). Floating-point
`DToB0..3`/`BToD0..3` tags built from `multiProcessElementsType` (`mpet`) are optional in
v4 and take precedence in Little CMS: "Float tag takes precedence"
([`cmsio1.c`][lcms-input-lut]).

### Rendering intents

Four intents, numbered 0 to 3: perceptual, media-relative colorimetric, saturation and
ICC-absolute colorimetric ([ICC.1:2022, Table 23][icc1]). Absolute colorimetric has no
tag of its own; a CMM uses the colorimetric tag and rescales by the media white point.
Little CMS maps intent 3 to `AToB1`/`BToA1` and falls back to perceptual when the
requested tag is missing ([`cmsio1.c`][lcms-input-lut]); it also adds black point
compensation (`cmsFLAGS_BLACKPOINTCOMPENSATION`, [`ComputeBlackPointCompensation`][lcms-bpc])
and six CMYK black-preserving intents numbered 10 to 15 ([`lcms2.h`][lcms-intents]), none
of which ICC.1 defines. `skcms` has no intent parameter: `skcms_Parse` prefers `A2B0` then
`A2B1` and ignores `A2B2`, and `skcms_ParseWithA2BPriority` lets the caller reorder
([`skcms_public.h`][sk-parse]).

### v2, v4 and iccMAX

- **v2** (ICC.1:2001-04 and earlier): `lut8`/`lut16` only, `textDescriptionType`, no
  parametric curves, legacy Lab encoding, no `chad` requirement. Many profiles embedded
  in old JPEGs are v2.
- **v4** (ICC.1:2004 onward, ISO 15076-1): `mAB `/`mBA `, `para`, `mluc` text, `chad`,
  profile ID, a defined perceptual reference medium. ICC.1:2022 (v4.4) added `cicp` "to
  enable HDR metadata to be carried in the profile", `metadataTag` with `dictType`, and
  the strict tag-table rule ([ICC.1:2022, Foreword][icc1]).
- **iccMAX** (ICC.2, version 5): spectral and bi-spectral PCS, profile connection
  conditions that late-bind illuminant and observer, an extended-range HDR PCS flag, and
  `multiProcessElementsType` extended with "a stack-based programmable transform
  calculator, single-segment curves, N-D lookup tables with integer encoding, colour
  appearance model (CAM) conversions, sparse matrix processing and tint arrays"
  ([ICC.2:2023, 0.2.2][icc2]). A major version change "occurs only when changes made to
  this document require that both CMMs and profile generating software be upgraded"
  ([ICC.2:2023, 7.2.6][icc2]); neither implementation read here opens a v5 profile
  (**verified**).

### Embedding per format

| Format     | Carrier                                                                    | Read in                                                    |
| ---------- | -------------------------------------------------------------------------- | ---------------------------------------------------------- |
| PNG        | one `iCCP` chunk: a name plus the zlib-compressed profile                  | [libpng][d-libpng], [libspng][d-libspng], [Wuffs][d-wuffs] |
| JPEG       | `APP2` segments tagged `ICC_PROFILE\0`, split with sequence numbers        | [libjpeg-turbo][d-libjpeg]                                 |
| WebP       | `ICCP` chunk announced by `VP8X`                                           | [libwebp][d-libwebp]                                       |
| TIFF       | the `ICCProfile` tag (`TIFFTAG_ICCPROFILE`), opaque bytes                  | [libtiff][d-libtiff]                                       |
| AVIF, HEIF | a `colr` property of type `prof` or `rICC`, beside an `nclx` (CICP) `colr` | [libavif][d-libavif], [libheif][d-libheif]                 |
| JPEG XL    | compressed ICC in the codestream header, or an enumerated colour encoding  | [libjxl][d-libjxl]                                         |
| OpenEXR    | none: chromaticities attributes instead                                    | [OpenEXR][d-openexr]                                       |

ICC.1:2022 dropped its embedding annex in favour of ICC Technical Note 10-21
([ICC.1:2022, Foreword][icc1]). Every carrier holds the profile as opaque bytes, and the
decoders in the table hand it to the caller; the one exception is libjxl, which converts
to an ICC target only through a CMS the caller plugs in with `JxlDecoderSetCms`. The CICP-or-ICC choice that AVIF and HEIF make
explicit is the subject of [`concepts.md`][c-cicp]; [Skia][d-skia] applies the profile
at decode time through `skcms`.

## Analysis

### 3. Colour and metadata

ICC is the general colour description, and its generality is the cost. A matrix/TRC
display profile is nine numbers and three curves, which a reader can reduce to a
primaries-and-transfer pair like CICP; a LUT profile is an arbitrary 1-to-15-channel
function that only a CMM can evaluate. `skcms` makes that split explicit: `has_trc`,
`has_toXYZD50`, `has_A2B`, `has_B2A` and `has_CICP` are independent flags, and a profile
is usable as a source if `has_A2B || (has_trc && has_toXYZD50)`
([`skcms.cc`][sk-usable]). As a destination it is stricter: CICP PQ or HLG first, then
`B2A`, then parametric curves only; tabulated curves fail, and the caller must run
`skcms_MakeUsableAsDestination` to fit a parametric approximation
([`skcms.cc`][sk-dest], [`skcms_public.h`][sk-make-usable]). The `cicp` tag lets one
profile carry both descriptions, and `skcms` gives the CICP transfer precedence:
"CICP-specified PQ or HLG transfer functions take precedence" ([`skcms.cc`][sk-dest]).

Alpha is outside ICC. `skcms` leaves it linear and takes it as a separate parameter,
`skcms_AlphaFormat_Opaque`, `Unpremul` or `PremulAsEncoded`, with the comment "We always
store any alpha channel linearly" ([`skcms_public.h`][sk-alpha]).

### 5. Hostile input and safety

A profile is attacker-supplied: it arrives inside a downloaded image. The format invites
overflow in three places: tag offsets and sizes, curve table lengths, and CLUT grid
products. `skcms` checks all three. The header check rejects a missing `acsp`, a size
field larger than the buffer, a tag table that does not fit, and a major version above 4;
every tag must satisfy `tag_size >= 4` and `offset + size <= profile->size`
([`skcms.cc`][sk-validate]). Curves are capped at `kMaxTableEntries = 1 << 24`
([`skcms.cc`][sk-curv]), and CLUTs at a grid product of `SKCMS_MAX_GRID_POINTS`:

```c
// modules/skcms/skcms.cc
// A potential vulnerability exists where a large CLUT can cause an integer
// overflow in skcms's transformation logic. Limit the total number of grid
// points to a safe value. 350 million ensures that 6 * index will not overflow
// a 32-bit signed integer (which is what AVX2/AVX-512 gather expects).
#define SKCMS_MAX_GRID_POINTS 350000000
```

([`skcms.cc`][sk-grid])

`skcms` also borrows rather than copies: "The buffer is not copied; it must remain valid
as long as the skcms_ICCProfile will be used. The parse will fail if there is not enough
padding (typically 1-2 bytes) past the end of the profile for internally optimized read
calls" ([`skcms_public.h`][sk-parse]). Skia now has a second answer at the same seam: a
Rust parser built on the `moxcms` crate whose README says "All ICC profile parsing
happens in Rust using the `moxcms` crate. This prevents memory safety vulnerabilities
from malformed ICC data", converting its result into `skcms_ICCProfile` for the
transform ([`rust/icc/README.md`][sk-rust-icc]). It is used by the Rust PNG and BMP
codecs, and `ColorProfile::MakeICCProfile` takes it only when built with
`SK_CODEC_COLOR_PROFILE_PARSE_WITH_RUST` ([`SkCodecColorProfile.cpp`][sk-codec-profile]).

Little CMS reads through an I/O handler and validates lazily. `_cmsReadHeader` rejects a
bad magic, an unsupported version, an unknown class, more than `MAX_TABLE_TAG` (100) tags
and duplicate signatures, but a tag pointing past the end is dropped with a
`cmsERROR_CORRUPTION_DETECTED` message and parsing continues; its comment calls this "a
small aid to diagnose malformed profiles" ([`cmsio0.c`][lcms-header]). Tags are parsed on
first `cmsReadTag`. The two libraries disagree on many inputs (**verified**):

| Variant of a v4.3 sRGB profile        | `skcms_Parse` | `cmsOpenProfileFromMem` (then sRGB transform)                      |
| ------------------------------------- | ------------- | ------------------------------------------------------------------ |
| unmodified                            | parses        | opens, transform ok                                                |
| version 5.x (iccMAX)                  | rejects       | rejects: "Unsupported profile version '0x5300000'"                 |
| version 4.5                           | parses        | rejects: "Unsupported profile version '0x4500000'"                 |
| class `prtr` (output) with matrix/TRC | parses        | opens, transform ok                                                |
| class `xxxx` (unregistered)           | parses        | rejects: "Unsupported device class '0x78787878'"                   |
| PCS `GRAY` (neither XYZ nor Lab)      | rejects       | opens; transform fails "Wrong output color space on transform"     |
| PCS illuminant D65, not D50           | rejects       | opens, transform ok                                                |
| size field 100 bytes past buffer end  | rejects       | opens, transform ok (size clamped to the buffer)                   |
| truncated to 200 bytes                | rejects       | rejects: "Read from memory error"                                  |
| `desc` tag offset past the end        | rejects       | opens with "'size' field in header seems incorrect.", transform ok |
| `rTRC` `para` with gamma -1.0         | rejects       | opens, transform ok                                                |
| 100 tags (91 private, shared offset)  | parses        | opens, transform ok                                                |
| 101 tags                              | parses        | rejects: "Too many tags (101)"                                     |

`skcms` ignores the class field and the profile ID. It rejects a profile when any
tag-table entry runs past the end, even one for a tag it never reads such as `desc`
([`skcms.cc`][sk-validate]), and fails any malformed tag it pre-parses (TRC, XYZ, A2B,
B2A, `cicp`); it also rejects any `para` curve that fails
`skcms_TransferFunction_isSRGBish` ([`skcms.cc`][sk-para]). Little CMS checks what the
specification names (class, version, tag count) and tolerates what it can repair.
Neither enforces the 2022 no-gap tag-table rule (**verified**: both accept the sRGB
profile with a 16-byte gap inserted before its last tag element). Little CMS ships a libFuzzer harness that opens a profile and reads every tag and
LUT ([`fuzzers.c`][lcms-fuzz]).

### 6. Allocation and ownership

`skcms_ICCProfile` is a fixed-size struct of pointers into the caller's buffer: curve
tables (`table_8`, `table_16`) and CLUT grids (`grid_8`, `grid_16`) are borrowed, never
copied ([`skcms_public.h`][sk-profile]). Parsing allocates nothing. Little CMS owns
everything: an opaque `cmsHPROFILE` per context, tags read into heap objects on demand
and cached, `cmsPipeline` stages duplicated for each transform (`cmsPipelineDup` in
[`_cmsReadInputLUT`][lcms-input-lut]), allocation routed through a pluggable memory
handler in a `cmsContext`.

### 7. CPU parallelism and SIMD

`skcms_Transform` compiles a profile pair into a list of ops (`lab_to_xyz`, `clut_A2B`,
`matrix_3x4`, curve ops) run over pixels by a baseline, Haswell or Skylake-X backend chosen
at runtime ([`skcms.cc`][sk-ops], [dispatch][sk-dispatch]); the CLUT grid limit exists because AVX2 and AVX-512
gathers take 32-bit indices ([`skcms.cc`][sk-grid]). Little CMS optimises a linked
pipeline (`cmsopt.c`) and keeps its faster paths in separate plug-ins under `plugins/`
(`fast_float`, `threaded`).

Not covered: 1, 2, 4, 8, 9, 10 (a profile describes colour, not pixels, so it has no
pixel model, generic pixel code, codec I/O, GPU path or animation; the test suites of
the two implementations were not read).

## Lessons for Sparkles

- **Q5** A reader that parses only matrix/TRC display profiles plus a `cicp` tag covers
  the profiles a viewer meets most; `skcms`'s `has_trc`/`has_toXYZD50`/`has_A2B`/
  `has_CICP` flags show that subset as data. Applying `mAB `, `mft2` and Lab PCS is a
  CMM's job; whether Sparkles writes one, binds Little CMS or `skcms`, or passes profiles
  through is the design review's choice (see [Little CMS][d-lcms2]).
- **Q5** Whatever the colour model is, it has to keep the profile bytes. Every carrier in
  [the embedding table](#embedding-per-format) delivers opaque bytes, and AVIF and HEIF
  can carry ICC and CICP together; a profile reduced to primaries and a curve cannot be
  re-embedded or re-evaluated.
- **Q4** ICC is a natural first target for a `sparkles:wired` binary description: a
  fixed big-endian header, an offset table, typed elements with 4-byte signatures and
  `s15Fixed16` numbers. Shared offsets, alignment padding and the no-overlap rule are
  the constraints such a description must express or check.
- **Q4, Q8** The divergence table is a ready differential oracle: the same crafted bytes
  give different verdicts in `skcms` and Little CMS, and a Sparkles parser should state
  which policy it follows per row (strict on D50, class and size field, or tolerant).
- **Q5, Q8** Limits must be explicit and checked before arithmetic: tag count, curve
  entries, CLUT grid product, channel counts. `skcms` derives its CLUT limit from the
  index width of its gather instructions; a D port has its own index widths to derive from.
- **Q1** The borrowed-buffer design (`skcms`) fits a `@nogc` parser over a decoded
  chunk's bytes, with the lifetime tied to the image's metadata buffer; the padding
  requirement past the end does not transfer to a bounds-checked D reader.
- **Q9** Colour management is a separable concern: no decoder in the embedding table
  applies ICC with its own code (libjxl delegates to a pluggable `JxlCmsInterface`),
  and `skcms` is consumed by Skia's codecs as a library. That is evidence
  for keeping profile parsing and transforms out of the format package.

## Strengths

- One format describes everything from an sRGB display to a seven-ink press, with a
  documented reference computation.
- Matrix/TRC profiles are small and cheap, and the `cicp` tag bridges to video and HDR
  enumerations.
- The profile ID gives a content hash for caching linked transforms.
- Two mature open implementations with opposite policies make a differential oracle.

## Weaknesses

- Many ways to say one thing: matrix/TRC or LUT, `curv` or `para`, v2 or v4 Lab, four
  LUT types, optional float tags; a reader must handle every combination it accepts.
- The rendering intent in the header is advisory, absolute colorimetric has no tag, and
  vendor intents (black point compensation, K preservation) live outside the format.
- Tolerance diverges between implementations; the stricter 2022 tag-table rule is
  enforced by neither library read here.
- iccMAX needs a new CMM (spectral PCS, calculator elements), and both CMMs read here
  reject version 5 profiles.
- Alpha, orientation and HDR headroom are outside the profile.

## Sources

- [ICC.1:2022][icc1]: sections 0.3, 7.2 (header), 7.3 (tag table), 8 (required tags
  per class), 9.1 Table 25, 10.10 (`lut16Type`), 10.12 (`lutAToBType`).
- [ICC.2:2023][icc2]: introduction 0.1 to 0.3 and 7.2.6 (version field).
- `skcms` in Skia: [`skcms_public.h`][sk-public], [`skcms.cc`][sk-cc]; Skia's
  [`rust/icc/README.md`][sk-rust-icc] and [`SkCodecColorProfile.cpp`][sk-codec-profile].
- Little CMS: [`README.md`][lcms-readme], [`lcms2.h`][lcms-classes],
  [`cmsio0.c`][lcms-header], [`cmsio1.c`][lcms-input-lut], [`cmscnvrt.c`][lcms-bpc],
  [`cmsmd5.c`][lcms-md5], [`fuzzers/fuzzers.c`][lcms-fuzz].
- Shared vocabulary: [ICC profile][c-icc], [CICP][c-cicp], [image metadata][c-meta],
  [container and bitstream][c-container], [hostile input][c-hostile].

<!-- References -->

[icc-specs]: https://www.color.org/specification/index.xalter
[icc1]: https://www.color.org/specification/ICC.1-2022-05.pdf
[icc2]: https://www.color.org/specification/ICC.2-2023.pdf
[skcms-tree]: https://github.com/google/skia/tree/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms
[sk-public]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h
[sk-tf]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L64-L73
[sk-a2b]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L175-L221
[sk-profile]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L159-L267
[sk-parse]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L296-L312
[sk-alpha]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L416-L445
[sk-make-usable]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L447-L456
[sk-cc]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc
[sk-grid]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L38-L42
[sk-header]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L411-L437
[sk-para]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L583-L650
[sk-curv]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L659-L705
[sk-usable]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L1406-L1409
[sk-validate]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L1438-L1468
[sk-dest]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L2702-L2753
[sk-ops]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L2896-L3010
[sk-dispatch]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L3119-L3135
[sk-rust-icc]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/rust/icc/README.md
[sk-codec-profile]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkCodecColorProfile.cpp#L62-L87
[lcms-repo]: https://github.com/mm2/Little-CMS/tree/5546f1d68136f94281c9f6bfc027c6cdf4898da8
[lcms-readme]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/README.md#L11-L12
[lcms-classes]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L511-L527
[lcms-intents]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L1728-L1756
[lcms-header]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio0.c#L838-L1055
[lcms-input-lut]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio1.c#L31-L401
[lcms-bpc]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmscnvrt.c#L82-L200
[lcms-md5]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsmd5.c#L257
[lcms-fuzz]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/fuzzers/fuzzers.c#L181
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-meta]: ./concepts.md#image-metadata
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[d-lcms2]: ./lcms2.md
[d-skia]: ./skia.md#_3-colour-and-metadata
[d-libpng]: ./libpng.md#_3-colour-and-metadata
[d-libspng]: ./libspng.md#_3-colour-and-metadata
[d-wuffs]: ./wuffs.md#_3-colour-and-metadata
[d-libjpeg]: ./libjpeg-turbo.md#_3-colour-and-metadata
[d-libwebp]: ./libwebp.md#_3-colour-and-metadata
[d-libtiff]: ./libtiff.md#_3-colour-and-metadata
[d-libavif]: ./libavif.md#_3-colour-and-metadata
[d-libheif]: ./libheif.md#_3-colour-and-metadata
[d-libjxl]: ./libjxl.md#_3-colour-and-metadata
[d-openexr]: ./openexr.md#_3-colour-and-metadata
