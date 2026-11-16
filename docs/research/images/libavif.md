# libavif (C)

The reference C library for AVIF, the AV1 Image File Format: an ISOBMFF/HEIF box
parser and item graph (primary item, grid, alpha auxiliary, gain map, sample
transform) wrapped around pluggable AV1 codecs, plus the YUV-to-RGB layer that
turns their planes into pixels. Read here for what a container-first still-image
decoder must get right, since in Sparkles the container would be owned in D and
libavif would be an oracle.

| Field         | Value                                                                                                                                 |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C99 library (`src/*.c`); C++ for tests, fuzz targets and the optional `compliance.cc`                                                 |
| License       | BSD-2-Clause ([`LICENSE`][license])                                                                                                   |
| Repository    | [AOMediaCodec/libavif][repo]                                                                                                          |
| Revision read | `9b07a9d7a874b159bb4e14b80a6f08bb469d06f7` (October 27, 2026; `CMakeLists.txt` says version 1.4.2 plus unreleased changes, SO 16.4.2) |
| Documentation | the header [`include/avif/avif.h`][h-io] is the API reference; [AVIF specification][avif-spec]; [`CHANGELOG.md`][changelog]           |
| Category      | Formats: still and sequence codec (container in-house, AV1 bitstream delegated)                                                       |
| Tier          | A                                                                                                                                     |
| Last reviewed | November 7, 2026                                                                                                                      |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** come from scratch C programs built
> against the nixpkgs `libavif` 1.3.0 package (dav1d 1.5.2, libaom 3.12.1, libyuv 1908) and, on re-verification, the 1.4.2 package (dav1d 1.5.3, libaom 3.15.1), run on files from the pinned tree's `tests/data/`. Both releases are older
> than the revision read; where they differ from it the text says so. Everything else
> was read in the source at the pinned revision with `git show`. No performance
> number in this page was measured.

---

## Overview

### What it solves

An AVIF file is not an AV1 stream. It is an ISOBMFF file whose `meta` box
describes **items** (coded images, derived images, metadata blobs) and their
**properties** (size, colour, codec configuration, transforms), whose `iloc` box
says where each item's bytes live, and whose `mdat` holds those bytes. A coded
image item is one AV1 temporal unit; everything else the viewer sees, such as a
grid of tiles, an alpha plane, a crop, a rotation, an HDR gain map or a 16-bit
image built from two 8-bit ones, is expressed in the container. libavif owns that
container layer completely, for reading and writing, and delegates the AV1
bitstream to one of six codec libraries. On top it provides an `avifRGBImage`
conversion layer, alpha (un)premultiplication, scaling and gain-map tone mapping,
and the `avifenc`, `avifdec` and `avifgainmaputil` tools.

The README states the aim in one sentence ([`README.md`][readme]):

> "This library aims to be a friendly, portable C implementation of the AV1 Image
> File Format"

For the [container and bitstream][c-container] split this survey keeps returning to,
libavif is the cleanest example in the catalog: the container code is about
12,000 lines (`read.c` 7,446, `write.c` 4,192), the codec adapters are 150 to 1,400
lines each, and the codecs themselves are not in the tree at all.

### Design philosophy

Four choices recur through the source.

- **Pull I/O through one callback, with "not yet" as a result.** The decoder never
  owns a file; it asks an `avifIO` for byte ranges, and the reader may answer
  `AVIF_RESULT_WAITING_ON_IO`. The header documents the contract precisely
  ([`avif.h`][h-io-read]):

  > "If the range is unavailable yet (due to network conditions or any other
  > reason), return AVIF_RESULT_WAITING_ON_IO."

- **Strict by default, with named exceptions.** `strictFlags` defaults to
  `AVIF_STRICT_ENABLED`, a set of three bits that may each be cleared; the
  comments on two of them name the producer that made the exception necessary
  (libheif v1.11.0 or older for `pixi`, avif-serialize 0.7.3 or older for the
  alpha `ispe`) ([`avif.h`][h-strict]):

  > "Some encoders (including very old versions of avifenc) do not implement the
  > AVIF standard perfectly, and thus create invalid files. However, these files
  > are likely still recoverable / decodable, if it wasn't for the strict
  > requirements imposed by libavif's decoder."

- **Spec text next to the check.** Nearly every rejection in `read.c` quotes the
  clause of ISO/IEC 14496-12, 23008-12 (HEIF), 23000-22 (MIAF) or the AVIF
  specification that it enforces (examples under
  [How it works](#the-item-graph-meta-iinf-iloc-ipco-ipma)).
- **Extensible structs, opaque internals.** `avifImage`, `avifDecoder` and
  `avifGainMap` must be allocated by the library, and each carries
  "Version 1.x.0 ends here" markers so fields can be appended without breaking the
  ABI ([`avif.h`][h-image]).

---

## How it works

### Two-phase decoding

A decode is `avifDecoderCreate`, `avifDecoderSetIO*`, `avifDecoderParse`, then
`avifDecoderNextImage` (or `avifDecoderNthImage`) in a loop
([`avif.h`][h-decoder-usage]). `avifDecoderRead*` wraps the sequence for a single
image. The decoder is created with its limits already set
([`read.c`][read-create]):

```c
decoder->maxThreads = 1;
decoder->imageSizeLimit = AVIF_DEFAULT_IMAGE_SIZE_LIMIT;
decoder->imageDimensionLimit = AVIF_DEFAULT_IMAGE_DIMENSION_LIMIT;
decoder->imageCountLimit = AVIF_DEFAULT_IMAGE_COUNT_LIMIT;
decoder->strictFlags = AVIF_STRICT_ENABLED;
decoder->imageContentToDecode = AVIF_IMAGE_CONTENT_DECODE_DEFAULT;
```

**Parse** reads boxes and builds the item graph, checks every item's `ispe`
against the limits ([`read.c`][read-decoderparse]), then calls `avifDecoderReset`,
which selects the colour item, finds alpha and gain-map items, validates their
properties, creates tiles and fills `decoder->image` with everything known before
any AV1 data is decoded (size, depth, format, CICP, ICC, EXIF, XMP, transforms).
**NextImage** reads the samples for the next frame of every tile, hands each to
its codec, and assembles the result.

### The top-level box loop

`avifParse` reads at most 32 bytes for each top-level box header, then reads the
whole body only for `ftyp`, `meta`, `moov` (and the experimental `mini`); every
other box, `mdat` included, is skipped by offset arithmetic
([`read.c`][read-parse-loop]). Parsing stops as soon as the brands say enough has
been seen: `avif` needs `meta`, `avis` needs `moov`, `tmap` needs a tone-mapped
item ([`read.c`][read-parse-early]):

```c
avifBool sawEverythingNeeded = ftypSeen && (!needsMeta || metaSeen) && (!needsMoov || moovSeen) && (!needsTmap || tmapSeen);
```

So a well-formed file whose `meta` precedes `mdat` parses from its first few
kilobytes, and the pixel data is fetched only when a frame is decoded.

### The item graph: `meta`, `iinf`, `iloc`, `ipco`, `ipma`

`avifParseMetaBox` requires `hdlr` first with handler `pict`, and allows each of
`iloc`, `pitm`, `idat`, `iprp`, `iinf`, `iref` and `grpl` at most once through a
bit set (`uniqueBoxSeen`) ([`read.c`][read-meta], [`read.c`][read-unique]).

- **`iloc`** ([`read.c`][read-iloc]) accepts versions 0 to 2 and construction
  methods 0 (file offset) and 1 (`idat` offset); method 2 (item offset) is
  rejected. Field sizes must be 0, 4 or 8 bytes. Each extent's
  `base_offset + extent_offset` and the running `item->size` are checked for
  overflow, and on 32-bit hosts an extent longer than `SIZE_MAX` is refused.
- **`ipco`** ([`read.c`][read-ipco]) parses the properties libavif understands
  (`ispe`, `auxC`, `colr`, `av1C`, `pasp`, `clap`, `irot`, `imir`, `pixi`,
  `a1op`, `lsel`, `a1lx`, `clli`) into a tagged union and keeps every other
  property as an opaque byte copy.
- **`ipma`** ([`read.c`][read-ipma]) enforces increasing item IDs, rejects an
  essential flag on property index 0, rejects `a1lx` marked essential and
  `a1op`, `lsel`, `clap`, `irot`, `imir` not marked essential, each with its
  clause quoted. An **unsupported essential property** does not fail the file;
  it marks the item `hasUnsupportedEssentialProperty`, and
  `avifDecoderItemShouldBeSkipped` then ignores it, together with empty items,
  unknown types and thumbnails ([`read.c`][read-skip]). Unsupported
  non-essential properties are forwarded to the caller through
  `avifImage.properties`.

### From items to tiles

`avifDecoderReset` turns the chosen items into an array of `avifTile`, grouped by
`avifItemCategory`: colour, alpha, gain map, sample transform and four
sample-transform inputs ([`internal.h`][int-category]). A `grid` item becomes
one tile per `dimg` reference; the grid box itself is a few bytes
([`read.c`][read-grid]):

```c
grid->rows = (uint32_t)rowsMinusOne + 1;
grid->columns = (uint32_t)columnsMinusOne + 1;
```

and its output size goes through the same `avifDimensionsTooLarge` check as an
`ispe`. When the first tile is decoded, `avifDecoderDataAllocateImagePlanes`
checks that the cells cover the canvas and that the last row and column overlap
it (HEIF 6.6.2.3.1, MIAF 7.3.11.4.2) before allocating the full canvas
([`read.c`][read-alloc-planes]).

The **alpha** item is the one with an `auxl` reference to the colour item and an
`auxC` whose URN is the alpha URN ([`read.c`][read-alpha]); for a grid colour
item, alpha may instead be a set of `auxl` items, one per cell. The **gain map**
is found through a `tmap` derived item whose inputs are the base image and the
gain-map image; its payload is the ISO 21496-1 metadata read by
`avifParseGainMapMetadata` ([`read.c`][read-tmap]).

### Reading item bytes: extents, `persistent` and partial reads

`avifDecoderItemRead` is where the I/O model meets memory ([`read.c`][read-itemread]).
If the item has a single extent and the source is either the `idat` buffer or a
`persistent` `avifIO`, the decoder points at the caller's bytes. Otherwise it
allocates the item's **full** declared size once and copies extents into it:

```c
avifBool singlePersistentBuffer = ((item->extents.count == 1) && (idatBuffer || io->persistent));
if (!singlePersistentBuffer) {
    // Always allocate the item's full size here, as progressive image decodes will do partial
    // reads into this buffer and begin feeding the buffer to the underlying AV1 decoder, but
    // will then write more into this buffer without flushing the AV1 decoder (which is still
    // holding the address of the previous allocation of this buffer). This strategy avoids
    // use-after-free issues in the AV1 decoder and unnecessary reallocs as a typical
    // progressive decode use case will eventually decode the final layer anyway.
    AVIF_CHECKRES(avifRWDataRealloc(&item->mergedExtents, item->size));
```

`partialByteCount` lets a caller read a prefix of an item; the decoder uses that
to harvest CICP from the AV1 sequence header when no `colr` box exists, reading
the first sample in 64-byte steps up to 4,096 bytes ([`read.c`][read-cicp-harvest]).

### Codec adapters

A codec is a small vtable, `avifCodec`, with `getNextImage`, `encodeImage`,
`encodeFinish` and `destroyInternal`, plus the decoder options it must honour:
`maxThreads`, `imageSizeLimit`, `imageDimensionLimit`, `operatingPoint`,
`allLayers` ([`internal.h`][int-codec]). The registry is a compile-time table in
preference order ([`avif.c`][avif-codecs]): dav1d, libgav1, libaom (decode and
encode), rav1e and SVT-AV1 (encode only), and the experimental AV2 `avm`.
`AVIF_CODEC_CHOICE_AUTO` takes the first entry with the needed capability,
skipping `avm`, which must be chosen explicitly.

The dav1d adapter shows the contract ([`codec_dav1d.c`][dav1d-settings]): it
passes `imageSizeLimit` to dav1d's `frame_size_limit` (capped at 8192 × 8192 on
32-bit hosts), selects the operating point, sends the sample, drains every
buffered frame so that none leaks into the next sample, and then **borrows**
dav1d's planes instead of copying them ([`codec_dav1d.c`][dav1d-steal]):

```c
// Steal the pointers from the decoder's image directly
avifImageFreePlanes(image, AVIF_PLANES_YUV);
...
    image->yuvPlanes[yuvPlane] = dav1dImage->data[yuvPlane];
    image->yuvRowBytes[yuvPlane] = (uint32_t)dav1dImage->stride[(yuvPlane == AVIF_CHAN_Y) ? 0 : 1];
image->imageOwnsYUVPlanes = AVIF_FALSE;
```

For a non-grid image, `avifDecoderDecodeTiles` then steals those planes again into
`decoder->image`; for a grid it copies each cell into the canvas
([`read.c`][read-decodetiles]).

### YUV to RGB

`avifImageYUVToRGB` ([`reformat.c`][reformat-entry]) decides the alpha multiply
mode, splits the image into at most eight horizontal bands for threads, and calls
`avifImageYUVToRGBImpl`, which tries three tiers in order
([`reformat.c`][reformat-impl]):

1. **libyuv**, unless `avoidLibYUV` is set, for 8-bit RGB output from 8, 10 or 12
   bit YUV, when a `YuvConstants` table exists for the CICP matrix and range
   (BT.601, BT.709, BT.2020 NCL, and chroma-derived NCL mapped onto those)
   ([`reformat_libyuv.c`][libyuv-entry]).
2. **Built-in "fast" loops** per depth pair (`avifImageYUV8ToRGB8Color` and seven
   siblings, plus one 8-bit identity-matrix path), only for non-grey output with
   nearest-neighbour chroma or 4:4:4, and only when any alpha (un)multiply can
   run as a separate post-pass.
   They convert through a per-image float lookup table and float matrix maths
   ([`reformat.c`][reformat-8to8]).
3. **`avifImageYUVAnyToRGBAnySlow`**, which handles every combination, including
   bilinear chroma upsampling and premultiplication.

Half-float output (`isFloat`) is a post-pass over 16-bit output.

---

## Analysis

### 1. Pixel and memory model

`avifImage` is planar YUV with a per-plane [stride][c-stride]
(`yuvRowBytes[3]`, `alphaRowBytes`) and a shared `depth`
([`avif.h`][h-image]):

> "all planes must share this depth; if depth>8, all planes are uint16_t internally"

[Chroma subsampling][c-subsampling] is a format enum (`YUV444`, `YUV422`,
`YUV420`, `YUV400`) plus `yuvChromaSamplePosition`. Ownership is a flag per plane
group (`imageOwnsYUVPlanes`, `imageOwnsAlphaPlane`), which is what lets a codec's
buffer be borrowed and a crop be a view: `avifImageSetViewRect` makes a shallow,
non-owning sub-rectangle, and the threaded RGB conversion uses it to hand each
band to a worker ([`reformat.c`][reformat-entry]). There is no tiling in the
memory model: a grid is assembled into one contiguous canvas.

`avifRGBImage` is the interleaved side: a `format` (RGB, RGBA, ARGB, BGR, BGRA,
ABGR, RGB565, grey variants), `depth` of 8, 10, 12 or 16, `rowBytes`, and flags
for premultiplied alpha and half floats ([`avif.h`][h-rgbimage]). Its pixels are
always full range.

Extents and strides are `uint32_t` throughout the public structs. That is the root
of a CVE class: products such as `j * rgbRowBytes` overflowed in 32-bit arithmetic
before they were widened (see [Hostile input](#_5-hostile-input-and-safety)).

### 2. Genericity mechanism

Not compile-time. Pixel depth is run-time (`depth`, with `uint8_t` or `uint16_t`
storage selected by `avifImageUsesU16`), and every converter is a hand-written
function per depth pair, chosen by `if` chains ([`reformat.c`][reformat-impl]).
Codecs are run-time polymorphic through the `avifCodec` function-pointer table
([`internal.h`][int-codec]). Capability is data: each table entry carries
`AVIF_CODEC_FLAG_CAN_DECODE` or `CAN_ENCODE` ([`avif.c`][avif-codecs]), and libyuv
availability is probed per call by returning `AVIF_RESULT_NOT_IMPLEMENTED`, which
the caller treats as "try the next tier". That return-code fallback is the C form
of the optional-primitive pattern in
[design by introspection][dbi]: the generic path always exists, and a faster
primitive is used when it reports it can handle the case.

### 3. Colour and metadata

**[CICP][c-cicp].** `avifImage` carries `colorPrimaries`, `transferCharacteristics`,
`matrixCoefficients` and `yuvRange`. Three sources fill them, in precedence order:
the `colr` box of type `nclx` ([`read.c`][read-colr]); failing that, the AV1
sequence header parsed by `obu.c` before decoding ([`read.c`][read-cicp-harvest]);
failing that, the first decoded tile ([`read.c`][read-alloc-planes]). When the
`colr` range and the AV1 `color_range` disagree, the container wins, and the code
explains why the mismatch is tolerated rather than rejected: SVT-AV1 wrote files
without the range for years ([`read.c`][read-decodetiles]).

**[ICC][c-icc].** At most one `colr` of type `prof` or `rICC` and one of type
`nclx` are accepted per item ([`read.c`][read-colour-props]). The ICC payload is
recorded as an offset and size during parsing and re-read through `avifIO` later,
because the parse buffer may not be persistent ([`read.c`][read-colr]). libavif
never interprets the profile; it is surfaced as bytes, and the header warns
callers to check for it before trusting CICP ([`avif.h`][h-image]). Gain-map
application refuses ICC outright ([`gainmap.c`][gainmap-icc]):

> "Tone mapping for images with ICC profiles is not supported"

**Transfer functions and primaries** are implemented in `colr.c` (sRGB, BT.709,
PQ, HLG, SMPTE 428, log curves and others) and `colrconvert.c` (primaries to XYZ
D50 with a Bradford adaptation, RGB-to-RGB matrices), used by gain-map maths
rather than by the YUV-to-RGB path, which does no colour management.

**HDR.** `clli` (content light level) is parsed into `avifImage.clli`; `mdcv`
(mastering display) and other HDR boxes are not parsed: in an ordinary `ipco`
they reach the caller as opaque properties, and the experimental `mini` path
skips them.
**[Gain maps][c-gainmap]** follow ISO 21496-1: `avifGainMap` holds the gain-map
image, per-channel `gainMapMin`, `gainMapMax`, `gainMapGamma`, `baseOffset`,
`alternateOffset` as rational numbers, base and alternate headroom, and the
alternate image's colorimetry ([`avif.h`][h-gainmap]). The header gives the
formula in a comment:

> "toneMappedLinear = ((baseImageLinear + baseOffset) \* exp2(gainMapLog \* w)) -
> alternateOffset;"

`avifImageApplyGainMap` and `avifRGBImageApplyGainMap` implement it per pixel in
float ([`gainmap.c`][gainmap-apply]). A `tmap` with an unsupported `version` or
`minimum_version` yields `AVIF_RESULT_NOT_IMPLEMENTED`, so the file still decodes
as SDR ([`read.c`][read-tmap]).

**[EXIF and XMP][c-metadata]** are items linked to the colour item by `cdsc`
references: type `Exif`, or type `mime` with the XMP content type
([`read.c`][read-metadata]). libavif checks that the EXIF header's
`exif_tiff_header_offset` matches the TIFF header it finds, copies the payload,
and parses nothing else except, on encode, the orientation tag. Transforms
(`clap`, `irot`, `imir`, `pasp`) are exposed with `transformFlags` and **not
applied** to pixels; the header puts the duty on the caller ([`avif.h`][h-decoder-output]).

### 4. I/O and codec architecture

**API shape.** [Pull][c-pushpull]: the decoder calls `avifIO.read(offset, size)`;
the caller never pushes bytes. `AVIF_RESULT_WAITING_ON_IO` makes every call
**suspendable** in the sense of the
[concepts page][c-incremental]: the call returns, and the same call is repeated
once more bytes exist. Without `allowIncremental` this is idempotent at frame
granularity ([`read.c`][read-nextimage]):

> "Acquire all sample data for the current image first, allowing for any read call
> to bail out with AVIF_RESULT_WAITING_ON_IO harmlessly / idempotently, unless
> decoder->allowIncremental."

**Incremental.** With `allowIncremental`, `avifDecoderNextImage` decodes every
tile whose sample is complete and returns `AVIF_RESULT_WAITING_ON_IO` for the
rest; `avifDecoderDecodedRowCount` reports how many top rows are final
([`avif.h`][h-rowcount]). The granularity is the **grid cell row**: a non-grid
image reports 0 rows until it is complete, and a grid reports
`decodedTileCount / columns * tileHeight` ([`read.c`][read-rowcount]). There is
no row callback inside a tile, because the AV1 codecs are called once per whole
temporal unit. The header still labels the feature "WARNING: Experimental feature"
([`avif.h`][h-incremental]).

**Verified:** a probe `avifIO` that exposes a growing prefix of the file in ten
steps, non-persistent and with `sizeHint` set:

| File (bytes)                                                 | Parse succeeds at | Rows reported while waiting               | Complete at  |
| ------------------------------------------------------------ | ----------------- | ----------------------------------------- | ------------ |
| `sofa_grid1x5_420.avif` (25,409), 1×5 grid of 1024×154 cells | 2,540 bytes (10%) | 0, 154, 154, 154, 308, 308, 308, 462, 616 | 25,409 bytes |
| `paris_icc_exif_xmp.avif` (21,132), single item              | 6,339 bytes (30%) | 0 at every step                           | 21,132 bytes |

Both releases give the same rows. The second file needs 30% of its bytes before
parse succeeds because `avifDecoderReset` reads the EXIF and XMP item payloads,
which sit in `mdat`, during parsing (the ICC profile is a `colr` property inside
`meta`). With `ignoreExif` and `ignoreXMP` set, the 1.4.2 parse succeeds at the
first step (2,113 bytes). The header recommends those two flags to streaming
callers for exactly this reason ([`avif.h`][h-incremental]); `ignoreICC`, added
after 1.4.2, skips the ICC profile the same way ([`avif.h`][h-ignoreicc]).

**Progressive.** "Progressive" in libavif means AV1 layered images (`a1lx`,
`lsel`, operating points). With `allowProgressive`, each layer is exposed as a
frame of a sequence, and `progressiveState` distinguishes that from animation
([`avif.h`][h-progressive]). This is the only route to a lower-resolution image:
there is **no region decode and no downscaled decode** of a normal item. The
smallest unit of work is a grid cell or a whole AV1 frame; `avifImageScale`
(libyuv box filter) and `avifImageSetViewRect` operate after decoding.

**Codec architecture.** Container in C, bitstream behind `avifCodec`. One codec
instance can serve all tiles of a category when `avifTilesCanBeDecodedWithSameCodecInstance`
allows it; otherwise one per tile. Writing (`write.c`) mirrors reading through
`avifRWStream`, and an optional build validates every encoder output against GPAC's
ComplianceWarden ([`CMakeLists.txt`][cmake-cw]).

### 5. Hostile input and safety

**Bounded reads.** All box parsing goes through `avifROStream`, a cursor whose
every read checks `byteCount <= size - offset` first ([`stream.c`][stream-bounds]);
box headers reject a declared size smaller than the header or larger than
`SIZE_MAX` ([`stream.c`][stream-boxheader]); children are parsed inside their
parent's declared size. Top-level reads are checked against `io->sizeHint` when it
is non-zero ([`read.c`][read-parse-loop]).

**Configurable limits and defaults** ([`avif.h`][h-limits], [`avif.h`][h-limit-fields]):

| Limit                 | Default                                                 | Enforced at                                                                                  |
| --------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `imageSizeLimit`      | 16384 × 16384 pixels                                    | every `ispe`, the `grid` output, track `tkhd` sizes, scaling, and passed to dav1d and libaom |
| `imageDimensionLimit` | 32768 per axis                                          | same sites                                                                                   |
| `imageCountLimit`     | 2,592,000 (12 h at 60 fps)                              | sample tables and progressive layer counts ([`read.c`][read-countlimit])                     |
| `strictFlags`         | all three bits                                          | `pixi` required, `clap` valid, `ispe` required on alpha                                      |
| `io->sizeHint`        | caller's (file or buffer size for the built-in readers) | top-level offsets, item size, extent offsets                                                 |

The comment on the size default gives its reason: "to avoid out-of-memory errors or
integer overflow in (32-bit) int or unsigned int arithmetic operations"
([`avif.h`][h-limits]). The check itself divides rather than multiplies
([`avif.c`][avif-dims]). The header notes that only "some underlying AV1 codecs
support a configurable size limit (such as dav1d and libaom v3.14.0 or later)"
([`avif.h`][h-limit-fields]).

**Verified** (1.3.0 and 1.4.2): with `imageDimensionLimit = 100`, or with
`imageSizeLimit = 10000`, parsing the 1024×770 grid fails with "Item ID [1]
dimensions are too large [1024x770]". In both releases, `imageSizeLimit = 0`, or
any value above the default, makes parsing return `Not implemented`; their
headers say the limit "can be set to a smaller value. The value 0 is reserved."
At the pinned revision the header says "0 means unlimited", and `CHANGELOG.md`
lists "Allow setting avifDecoder::imageSizeLimit to any value" as unreleased
([`CHANGELOG.md`][changelog-limit]), so the limit's domain changes after 1.4.2.

**What is not limited.** There is no configurable limit on metadata size, ICC
size, item count, extent count or property count; only the field widths of the
boxes bound them. An item's buffer is allocated at its
declared `iloc` size, and the only bound is `sizeHint`. **Verified:** patching the
first `iloc` extent of the EXIF item in `paris_icc_exif_xmp.avif` to
`0x7FFFFFF0` bytes and parsing under a 1 GiB address-space limit gives
"Item ID 2 reported size failed size hint sanity check" when `sizeHint` is the
file size, and `Out of memory` when `sizeHint` is 0 (non-persistent reader, both
releases): the decoder tried to allocate
2 GiB before reading a byte. A streaming caller that cannot know the size and sets
`sizeHint` to 0 therefore gives up the main memory bound. Item lookup
(`avifMetaFindOrCreateItem`) is a linear scan per ID ([`read.c`][read-finditem]),
so the cost of an `iloc` or `ipma` with many items grows quadratically; this was
read, not measured.

**Leniency where files in the wild need it.** Limited-range alpha (legal in AVIF
1.0.0) is converted to full range; the `colr`/AV1 range mismatch is tolerated;
unsupported essential properties skip the item instead of failing the file
([`read.c`][read-decodetiles], [`read.c`][read-ipma]).

**Fuzzing.** libavif is an [OSS-Fuzz][ossfuzz-dockerfile] project. Since the move to
Google [FuzzTest][fuzztest], every FuzzTest target declared in
`tests/CMakeLists.txt` is a fuzzer: `avif_fuzztest_dec`, `_dec_incr`, `_enc_dec`,
`_enc_dec_anim`, `_enc_dec_layered`, `_enc_dec_incr`, `_properties`,
`_read_image` and `_yuvrgb` ([`tests/CMakeLists.txt`][tests-fuzz],
[`tests/oss-fuzz/README.md`][ossfuzz-readme]). The parse target fuzzes both
`persistent` settings and asserts only that `AVIF_RESULT_INTERNAL_ERROR` (a broken
invariant) never occurs ([`avif_fuzztest_dec.cc`][fuzz-dec]). dav1d is built with
the same sanitizer; under MSan its assembly is disabled and libaom is built for a
generic CPU ([`build.sh`][ossfuzz-build]). A separate CI workflow runs the FuzzTest targets in
unit-test mode on each change ([`ci-fuzztest.yml`][ci-fuzztest]).

**CVE history.** Three entries show where the bugs lived:

- [CVE-2020-36407][cve-2020-36407]: "libavif 0.8.0 and 0.8.1 has an out-of-bounds
  write in avifDecoderDataFillImageGrid", found by OSS-Fuzz
  ([OSV-2020-1597][osv-2020-1597]). Grid assembly, the copy of cells into a
  canvas, is exactly where the cover and overlap checks now sit
  ([`read.c`][read-alloc-planes]).
- [CVE-2025-48174][cve-2025-48174]: "In libavif before 1.3.0, makeRoom in stream.c
  has an integer overflow and resultant buffer overflow in stream->offset+size."
  The fixed `makeRoom` checks `size <= SIZE_MAX - stream->offset` before adding
  ([`stream.c`][stream-makeroom]).
- [CVE-2025-48175][cve-2025-48175]: "avifImageRGBToYUV in reformat.c has integer
  overflows in multiplications involving rgbRowBytes, yRowBytes, uRowBytes, and
  vRowBytes." The current loops widen to `size_t` before multiplying
  ([`reformat.c`][reformat-rowbytes]).

None of the three is in the box parser proper, and only the first is on the
decode path, in assembling decoded cells. Both 2025 entries are on the encode
path: CVE-2025-48175 is `uint32_t` arithmetic over row strides in RGB-to-YUV
conversion (the fix declares the `*RowBytes` locals `size_t`
([`64d956ed`][fix-48175])), and CVE-2025-48174 is an unchecked `size_t` addition
when growing an `avifRWStream`, the writer's output buffer, which only
`stream.c` and `write.c` use. The project's
[`SECURITY.md`][security] asks for private reports through GitHub advisories with
a 90-day window. The [hostile-input papers][p-hostile] put these classes in
context.

### 6. Allocation and ownership

All allocation goes through `avifAlloc`, `avifCalloc` and `avifFree`, which are
thin wrappers over `malloc`, `calloc` and `free` with no user hook
([`mem.c`][mem]); a caller cannot supply an arena or a budget. Ownership is
explicit: `avifIO` is owned by the decoder only if its `destroy` is set
([`avif.h`][h-decoder-usage]); planes carry `imageOwns*` flags; codec planes are
borrowed until the next `getNextImage`, which is why the header tells callers to
copy `decoder->image` before advancing ([`avif.h`][h-decoder-output]).

`persistent` is the main lever over copies. A persistent `avifIO` lets single-extent
items and track samples be used in place; a non-persistent one makes the decoder
copy every sample and metadata payload ([`read.c`][read-preparesample]). The
built-in memory reader is persistent and the file reader is not
([`io.c`][io-mem], [`io.c`][io-file]). Grids always allocate a canvas and copy
cells; non-grid images steal the codec's planes.

### 7. CPU parallelism and SIMD

libavif itself contains **no SIMD intrinsics and no CPU detection**: a search of
`src/` and `include/` for `immintrin`, `arm_neon`, `_mm_` or `cpuid` finds
nothing. Vector code comes from its dependencies, each with its own run-time
dispatch: the AV1 decoders (dav1d's assembly) and libyuv for colour conversion,
scaling and alpha (un)premultiplication. When libyuv is absent or lacks a
conversion, the fallback is scalar C with float arithmetic per sample
([`reformat.c`][reformat-8to8]).

Threads come from two places. `maxThreads` (default 1) is passed to the codec
(`n_threads` in dav1d), and the header defines it as a bound on threads "active
and taking CPU time", not on threads that exist ([`avif.h`][h-maxthreads]).
`avifRGBImage.maxThreads` splits YUV-to-RGB into up to eight row bands, but only
when chroma is not bilinear-upsampled 4:2:0, because bands would then depend on
each other's border rows ([`reformat.c`][reformat-entry]). Grid cells are decoded
sequentially by libavif; parallelism within a frame is the codec's.

### 8. GPU offload and interop

Not applicable in the library. There is no GPU path, no hardware AV1 decoder
adapter (no VA-API, Vulkan Video, MediaCodec or VideoToolbox entry in the codec
table), and no texture-format output. What makes GPU use possible downstream is
the planar output: borrowed, strided Y, U and V planes in 8 or 16 bits with CICP
tags are the shape a YUV texture upload or a shader-side conversion wants, and the
grid canvas is one allocation. The [GPU decode thread][p-gpu-decode] covers AV1 in
Vulkan Video, which a Sparkles AVIF path could feed with the same item graph.

### 9. Temporal, animation and containers

Image sequences are ISOBMFF tracks (`moov`, `trak`, `stbl`), parsed into sample
tables with chunk offsets, sample sizes, time-to-sample, sync samples and edit
lists. `avifDecoderNthImage` seeks by decoding from `avifDecoderNearestKeyframe`;
`avifImageTiming` gives per-frame `pts` and duration; `repetitionCount` comes from
the edit list ([`avif.h`][h-progressive]). A file can carry both a track and a
primary item; `avifDecoderSetSource` chooses, and `AVIF_DECODER_SOURCE_AUTO`
follows the major brand. Alpha in a sequence is a second track referenced by
`auxl`, decoded by a second codec instance, which is why `maxThreads` is documented
as an activity bound ([`avif.h`][h-maxthreads]).

Within one image, the container composes: grid cells, alpha, the gain map and the
`sato` sample-transform items that combine two coded images into a deeper one
(the bit-depth extension behind 16-bit AVIF) are all separate AV1 frames tied
together by references. `avifDecoderNthImageMaxExtent` reports the byte range a
frame needs, which lets a caller prefetch ([`read.c`][read-maxextent]).

### 10. Testing and conformance

The test suite is 54 GoogleTest files under `tests/gtest/` (round-trip
encode/decode, incremental decoding against a full decode, grids, gain maps,
CICP, `clap`, properties, 16-bit, alpha premultiplication) beside the FuzzTest
targets and shared helpers, shell tests
for the command-line tools, and golden tests that encode reference inputs and
compare the box structure dumped by MP4Box against XML goldens in
`tests/data/goldens/` ([`tests/CMakeLists.txt`][tests-golden]). The incremental
helper feeds a file in steps of a ten-thousandth of its size (at least one byte),
checks that the decoded row count never decreases, and compares every reported
row with a full decode ([`avifincrtest_helpers.h`][incr-helpers],
[`avifincrtest_helpers.cc`][incr-helpers-cc]).

`tests/data/` (about a hundred files, each documented with provenance and licence
in its [`README.md`][data-readme]) is a corpus of **edge cases** rather than a
conformance suite: missing `ispe` on alpha, `irot` on colour but not alpha,
non-essential `clap`, reversed and repeated `dimg` order, unsupported gain-map
versions, an extent pointing at a null byte, and fuzz reproducers such as
`poc_b_506387278.avif`. There is no AV1 conformance-stream corpus in the tree
(bitstream conformance is the codecs' concern), and encoder output conformance is
checked by ComplianceWarden rather than by a corpus ([`compliance.cc`][compliance]).
The AVIF specification's own test files live in the [av1-avif][avif-spec]
repository, not here.

---

## Lessons for Sparkles

- **Q4.** The `avifIO` contract is the clearest pull-with-suspension design in the
  catalog so far: one `read(offset, size)` callback, three outcomes (bytes, EOF,
  `WAITING_ON_IO`), a `persistent` bit that tells the decoder whether it may keep
  pointers, and a `sizeHint` that bounds allocations. It maps onto a D struct of
  `@nogc nothrow` function pointers or a template parameter with an optional
  `persistent` enum, which [design by introspection][dbi] expresses directly, and
  onto `sparkles:event-horizon` offset reads ([event-horizon baseline][bl-eh]).
  What does not transfer: re-entry is by **repeating the whole call**, so the
  decoder's progress lives in counters spread across `avifDecoderData`, and
  incrementality stops at grid-cell granularity. The baseline's decision 5A (a
  push parser with an explicit state struct) is the alternative this evidence
  should be weighed against ([existing-code baseline][bl-existing], G7).
- **Q4.** The two-phase split (parse the container and fill every descriptor
  before touching the bitstream) is what makes `IMG2`-style layout from pixel size
  alone possible. A Sparkles AVIF reader can expose size, depth, CICP, alpha
  presence and transforms after reading `meta` only, provided ICC and metadata
  payloads are read lazily, which libavif learned late (`ignoreICC` is
  unreleased at the pinned revision).
- **Q4, Q9.** Container and bitstream are separable even in a C library: twelve
  thousand lines of item-graph code sit beside codec adapters of 150 to 1,400
  lines. For the
  agreed stance (codecs owned in D), the HEIF/ISOBMFF item graph is a natural
  first deliverable that is useful before any AV1 decoding exists in D, because
  HEIC, AVIF and future HEIF-family formats share it; libavif, with dav1d, is the
  oracle. Whether that graph belongs in a formats package or a container package
  is a Q9 question this evidence informs but does not settle.
- **Q4, Q8.** The box schema (fixed-width fields chosen by 4-bit size codes,
  versions that change field widths, bit-packed flags, unique-child rules,
  essential flags) is a concrete requirement list for `sparkles:wired`
  ([wired baseline][bl-wired]): `iloc` alone needs size-coded integers and
  version-dependent layouts. libavif writes each parser by hand, with the spec
  clause quoted next to each check; a declarative description could carry the
  clause as a UDA.
- **Q5.** The colour model to copy is libavif's precedence rule, not its storage:
  container `nclx` over bitstream sequence header over decoded frame, ICC as
  opaque bytes that disable CICP-based processing, transforms as metadata with an
  explicit "apply before rendering" duty. That gives the descriptor the
  [existing-code baseline][bl-existing] (G4, G5, decision 3B) asks for, with one
  more field than PNG needs: the gain map as a second image plus rational
  metadata.
- **Q5.** ISO 21496-1 gain-map application is a per-pixel float kernel over two
  images of possibly different size with linearisation, an optional primaries
  matrix and an exponential. It is a natural candidate for the shared
  per-pixel-function form the [shaders baseline][bl-shaders] recommends (question
  1, option A), and a correctness oracle exists (`avifImageApplyGainMap`).
- **Q8, Q4.** The CVE record argues for `size_t` (D's index type) in every
  geometry product and for checked addition on buffer growth: CVE-2025-48175 was
  32-bit arithmetic over row strides and CVE-2025-48174 an unchecked addition
  when growing the writer's stream, both on the encode side. In
  D, `@safe` slicing turns the out-of-bounds write of CVE-2020-36407 into a range
  error, but the overflow before the slice still needs `core.checkedint` or
  `size_t` widening.
- **Q8.** Limits should be a budget, not only dimensions. libavif's
  pixel-count and per-axis limits are checked before allocation, but metadata,
  item and extent counts are unbounded and a declared item size is allocated in
  full; the demonstration above shows `sizeHint = 0` removing the only memory
  bound. A Sparkles decoder options struct can carry a byte budget for
  allocations and a count budget for items and properties, checked by the parser.
- **Q8.** The fuzzing setup transfers in shape: property-based fuzz targets that
  double as unit tests in normal CI, both `persistent` modes fuzzed, invariant
  violations (`INTERNAL_ERROR`) as the oracle, and an incremental-decode target
  checking every reported row against a full decode. The edge-case corpus in
  `tests/data/`, with a README entry per file, is the model for a Sparkles corpus
  read through flake-input variables.
- **Q3, Q7.** libavif delegates all SIMD and pays for it: when libyuv cannot
  handle a case (16-bit output, bilinear premultiplied conversion, exotic
  matrices), the fallback is scalar float code. A D implementation that owns
  YUV-to-RGB needs the bilinear 4:2:0 path vectorised, since that is the default
  upsampling and also the case that blocks band threading. The dispatch
  question belongs to the [shaders baseline][bl-shaders] (G5).
- **Q1.** `avifImage` is evidence for a planar view with per-plane strides,
  subsampling as a format field, a shared depth and an ownership bit per plane
  group, which is close to the erased interchange type of the baseline's decision
  2A/2C ([existing-code baseline][bl-existing], G2). Its `uint32_t` extents and
  the absence of an allocator hook are the parts not to copy under Sparkles'
  `size_t` and `sparkles.base.buffer` conventions.

---

## Strengths

- Complete coverage of the AVIF item model: grids, alpha (item and per-cell),
  gain maps, layered images, sequences with alpha tracks, sample transforms,
  opaque property forwarding.
- One I/O abstraction serves memory, file and network sources, with suspension
  built into the result type.
- Container metadata is available after parsing `meta`, before any pixel decode.
- Strict by default, with the producers that need a relaxation named beside its flag.
- Spec clauses quoted beside checks; diagnostics name the box and item.
- Codec back ends are swappable at build time and at run time.
- Extensive tests: round-trip, incremental, golden box dumps, a documented
  edge-case corpus, and FuzzTest targets that run in CI and on OSS-Fuzz.

## Weaknesses

- Incremental decoding is experimental and stops at grid-cell rows; a single
  large AV1 image shows nothing until complete.
- No region or downscaled decode of an ordinary image.
- No memory budget: metadata and item sizes are bounded only by `sizeHint`, and
  allocation cannot be redirected.
- `uint32_t` geometry in public structs; CVE-2025-48175 was an overflow in it.
- ICC is carried but never applied, and gain-map maths refuses ICC-tagged images.
- Performance depends on libyuv being present and supporting the case; the
  in-tree fallback is scalar float code.
- Defaults and domains drift across releases (`imageSizeLimit = 0`, `ignoreICC`),
  so behaviour under one version is not a contract for the next.

---

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                               | Trade-off                                                                                 |
| ------------------------------------------------------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Pull `avifIO` with `AVIF_RESULT_WAITING_ON_IO`               | One interface for memory, files and networks; streaming without threads | Re-entry repeats whole calls; progress state is implicit in decoder internals             |
| `persistent` flag on the reader                              | Zero-copy when the caller guarantees lifetime                           | Non-persistent readers copy every sample and metadata payload                             |
| Allocate an item's full declared size for multi-extent reads | Codecs hold pointers across partial reads; avoids use-after-free        | Declared sizes drive allocation; unbounded when `sizeHint` is 0                           |
| Container in-house, AV1 behind `avifCodec`                   | Reuse mature decoders; choose per platform and licence                  | Limits, threading and safety depend on the codec chosen; no region decode below the codec |
| Parse first, decode later                                    | Size, colour and metadata known before pixels                           | Metadata at the end of a file delays parse for streaming callers unless ignored           |
| Strict by default, named strict bits                         | Reject malformed files; document known-bad producers                    | Callers must know which bits to clear for legacy files                                    |
| Unsupported essential property skips the item                | Follows HEIF 10.2.1; lets the rest of the file decode                   | A file can silently lose its preferred item and fall back                                 |
| CICP precedence: `colr`, then sequence header, then frame    | Matches ISOBMFF 12.1.5.1; tolerates encoders that omit `colr`           | Container and bitstream may disagree, and range mismatches are accepted                   |
| Transforms and ICC exposed, not applied                      | Keeps the decoder lossless and colour-management-free                   | Every caller must apply `clap`, `irot`, `imir` and ICC itself                             |
| libyuv first, then built-in fast paths, then a slow path     | Fast common cases; one path that handles everything                     | Behaviour and speed vary with the libyuv version present                                  |

---

## Sources

- [AOMediaCodec/libavif repository][repo], read at `9b07a9d7a874b159bb4e14b80a6f08bb469d06f7`
- [`README.md`][readme]; [`SECURITY.md`][security]; [`CHANGELOG.md`][changelog]
  ([limit change][changelog-limit]); [`LICENSE`][license]
- [`include/avif/avif.h`][h-io]: [limits defaults][h-limits]; [`avifGainMap`][h-gainmap];
  [`avifImage`][h-image]; [`maxThreads`][h-maxthreads]; [`avifRGBImage`][h-rgbimage];
  [`avifIOReadFunc`][h-io-read]; [`avifStrictFlag`][h-strict];
  [`avifProgressiveState`][h-progressive]; [`allowIncremental`][h-incremental];
  [limit fields][h-limit-fields]; [decoder output][h-decoder-output];
  [call order][h-decoder-usage]; [`avifDecoderDecodedRowCount`][h-rowcount];
  [`ignoreICC`][h-ignoreicc]
- [`include/avif/internal.h`][int-codec]: `avifCodec`; [`avifItemCategory`][int-category]
- `src/read.c`: [`avifDecoderCreate`][read-create]; [`avifParse` box loop][read-parse-loop];
  [early exit][read-parse-early]; [`avifParseMetaBox`][read-meta]; [`uniqueBoxSeen`][read-unique];
  [`iloc`][read-iloc]; [`ipco`][read-ipco]; [`ipma`][read-ipma]; [item skipping][read-skip];
  [`grid`][read-grid]; [`tmap` and gain-map metadata][read-tmap]; [`colr`][read-colr];
  [colour properties][read-colour-props]; [CICP harvest][read-cicp-harvest];
  [`avifDecoderItemRead`][read-itemread]; [`avifDecoderPrepareSample`][read-preparesample];
  [`avifDecoderParse`][read-decoderparse]; [plane allocation and grid checks][read-alloc-planes];
  [alpha item][read-alpha]; [EXIF and XMP][read-metadata]; [image count limit][read-countlimit];
  [item lookup][read-finditem]; [`avifDecoderDecodeTiles`][read-decodetiles];
  [`avifDecoderNextImage`][read-nextimage]; [decoded row count][read-rowcount];
  [max extent][read-maxextent]
- [`src/avif.c` codec table][avif-codecs]; [`avifDimensionsTooLarge`][avif-dims]
- [`src/codec_dav1d.c` settings][dav1d-settings]; [plane borrowing][dav1d-steal]
- [`src/reformat.c` dispatch][reformat-impl]; [threaded entry][reformat-entry];
  [8-bit fast path][reformat-8to8]; [row-byte arithmetic][reformat-rowbytes];
  [`src/reformat_libyuv.c`][libyuv-entry]
- [`src/gainmap.c` apply][gainmap-apply]; [ICC refusal][gainmap-icc]
- [`src/stream.c` bounds][stream-bounds]; [box header][stream-boxheader]; [`makeRoom`][stream-makeroom]
- [`src/mem.c`][mem]; [`src/io.c` memory reader][io-mem]; [file reader][io-file]
- [`src/compliance.cc`][compliance]; [`CMakeLists.txt` ComplianceWarden option][cmake-cw]
- [`tests/CMakeLists.txt` fuzz targets][tests-fuzz]; [golden tests][tests-golden];
  [`avif_fuzztest_dec.cc`][fuzz-dec]; [`avifincrtest_helpers.h`][incr-helpers];
  [`avifincrtest_helpers.cc`][incr-helpers-cc];
  [`tests/oss-fuzz/README.md`][ossfuzz-readme]; [`build.sh`][ossfuzz-build];
  [`tests/data/README.md`][data-readme]; [`ci-fuzztest.yml`][ci-fuzztest]
- OSS-Fuzz: [`projects/libavif/Dockerfile`][ossfuzz-dockerfile]; [FuzzTest][fuzztest]
- NVD: [CVE-2020-36407][cve-2020-36407]; [CVE-2025-48174][cve-2025-48174];
  [CVE-2025-48175][cve-2025-48175] (fix [`64d956ed`][fix-48175]); OSV: [OSV-2020-1597][osv-2020-1597]
- [AV1 Image File Format specification][avif-spec]
- Related in this catalog: [Concepts][concepts] · [zune-image][zune] · [image-rs][image-rs] ·
  [Skia][skia] · [libvips][libvips] · [OpenImageIO][oiio] · [entropy-coding papers][p-entropy] ·
  [resampling and colour papers][p-colour] · [umbrella][umbrella]

<!-- References -->

[repo]: https://github.com/AOMediaCodec/libavif/tree/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7
[readme]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/README.md#L3-L6
[security]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/SECURITY.md#L1-L16
[changelog]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/CHANGELOG.md
[changelog-limit]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/CHANGELOG.md#L36
[license]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/LICENSE
[h-io]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1080-L1131
[h-limits]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L93-L101
[h-gainmap]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L613-L712
[h-image]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L774-L857
[h-maxthreads]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L899-L922
[h-rgbimage]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1000-L1024
[h-io-read]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1089-L1099
[h-strict]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1140-L1172
[h-progressive]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1185-L1231
[h-incremental]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1277-L1298
[h-limit-fields]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1299-L1318
[h-ignoreicc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1396-L1398
[h-decoder-output]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1320-L1344
[h-decoder-usage]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1411-L1447
[h-rowcount]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/avif.h#L1460-L1474
[int-category]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/internal.h#L413-L425
[int-codec]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/include/avif/internal.h#L606-L624
[read-create]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5185-L5199
[read-parse-loop]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L4935-L5021
[read-parse-early]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5094-L5104
[read-meta]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L3552-L3617
[read-unique]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L826-L846
[read-iloc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2076-L2204
[read-ipco]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L3012-L3077
[read-ipma]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L3079-L3245
[read-skip]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5388-L5398
[read-grid]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2206-L2256
[read-tmap]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2258-L2335
[read-colr]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2590-L2627
[read-colour-props]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5737-L5799
[read-cicp-harvest]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L6749-L6780
[read-itemread]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L1515-L1660
[read-preparesample]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5329-L5386
[read-decoderparse]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5400-L5462
[read-alloc-planes]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L1829-L1915
[read-alpha]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5593-L5600
[read-metadata]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L1979-L2041
[read-countlimit]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L593-L620
[read-finditem]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L980-L991
[read-decodetiles]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L6887-L7015
[read-nextimage]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L7133-L7223
[read-rowcount]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L7350-L7407
[read-maxextent]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L5280-L5327
[avif-codecs]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/avif.c#L1187-L1243
[avif-dims]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/avif.c#L646-L655
[dav1d-settings]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/codec_dav1d.c#L57-L166
[dav1d-steal]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/codec_dav1d.c#L204-L211
[reformat-impl]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat.c#L1449-L1599
[reformat-entry]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat.c#L1653-L1751
[reformat-8to8]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat.c#L1315-L1365
[reformat-rowbytes]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat.c#L286-L298
[libyuv-entry]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/reformat_libyuv.c#L932-L951
[gainmap-apply]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L73-L200
[gainmap-icc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/gainmap.c#L339-L341
[stream-bounds]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/stream.c#L31-L77
[stream-boxheader]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/stream.c#L248-L295
[stream-makeroom]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/stream.c#L335-L348
[mem]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/mem.c#L8-L28
[io-mem]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/io.c#L136-L143
[io-file]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/io.c#L236-L242
[compliance]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/compliance.cc#L24-L34
[cmake-cw]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/CMakeLists.txt#L124-L127
[tests-fuzz]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/CMakeLists.txt#L177-L227
[tests-golden]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/CMakeLists.txt#L278-L295
[fuzz-dec]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/gtest/avif_fuzztest_dec.cc#L23-L45
[incr-helpers]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/gtest/avifincrtest_helpers.h#L46-L66
[incr-helpers-cc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/gtest/avifincrtest_helpers.cc#L305-L385
[ossfuzz-readme]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/oss-fuzz/README.md#L30-L32
[fix-48175]: https://github.com/AOMediaCodec/libavif/commit/64d956ed5a602f78cebf29da023280944ee92efd
[ossfuzz-build]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/oss-fuzz/build.sh#L41-L91
[data-readme]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/tests/data/README.md
[ci-fuzztest]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/.github/workflows/ci-fuzztest.yml
[ossfuzz-dockerfile]: https://github.com/google/oss-fuzz/blob/2e0110a1e36a4cdc18f0d91f48475a7759e7e80a/projects/libavif/Dockerfile
[fuzztest]: https://github.com/google/fuzztest
[cve-2020-36407]: https://nvd.nist.gov/vuln/detail/CVE-2020-36407
[cve-2025-48174]: https://nvd.nist.gov/vuln/detail/CVE-2025-48174
[cve-2025-48175]: https://nvd.nist.gov/vuln/detail/CVE-2025-48175
[osv-2020-1597]: https://osv.dev/vulnerability/OSV-2020-1597
[avif-spec]: https://aomediacodec.github.io/av1-avif/
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[concepts]: ./concepts.md
[c-container]: ./concepts.md#container-and-bitstream
[c-stride]: ./concepts.md#stride
[c-subsampling]: ./concepts.md#chroma-subsampling
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-gainmap]: ./concepts.md#hdr-gain-map
[c-metadata]: ./concepts.md#image-metadata
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[bl-wired]: ./baseline/wired.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
[p-entropy]: ./papers/entropy-codecs.md
[p-colour]: ./papers/resampling-colour.md
[zune]: ./zune-image.md
[image-rs]: ./image-rs.md
[skia]: ./skia.md
[libvips]: ./libvips.md
[oiio]: ./openimageio.md
[umbrella]: ./index.md
