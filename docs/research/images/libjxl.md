# libjxl (C++)

The ISO/IEC 18181-4 reference implementation of JPEG XL: a push-fed, event-driven
decoder with a row-streaming render pipeline, its own colour model (XYB) and a
format designed for progressive, parallel and region-addressable decoding; the
most complete example of a modern codec a D reimplementation would have to match.

| Field         | Value                                                                                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17, C API (`lib/include/jxl/*.h`); SIMD through [Highway][hwy-repo] (submodule at `457c891775a7397bdb0376bb1031e6e027af1c48`)                                          |
| License       | BSD-3-Clause, with an additional patent grant ([`PATENTS`][patents])                                                                                                      |
| Repository    | [libjxl/libjxl][repo]                                                                                                                                                     |
| Revision read | `e2948747fee8e99a614066eb058e67a0b8de995f` (October 27, 2026; after release 0.12.0 of July 1, 2026; the build at this revision names itself `libjxl.so.0.13.0`)           |
| Documentation | [libjxl.readthedocs.io][rtd] · in-tree [`doc/format_overview.md`][fmt-overview], [`doc/fuzzing.md`][fuzzing-doc], [`doc/vuln_playbook.md`][playbook] · [the paper][p-jxl] |
| Category      | Formats: stills codec (lossy VarDCT, lossless Modular, JPEG recompression, animation)                                                                                     |
| Tier          | A                                                                                                                                                                         |
| Last reviewed | November 7, 2026                                                                                                                                                          |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** come from a build of the pinned
> revision (exported with `git archive` into a scratch directory under `/tmp`,
> configured with CMake against nixpkgs' Highway 1.0.7, Brotli and lcms2, release
> mode) and a 60-line C probe linked against it. The probe feeds a file in chunks,
> subscribes to every informative event, counts allocations through a
> `JxlMemoryManager` and can cap them. Test inputs were made by the same build's
> `cjxl` from a synthetic 1024 by 768 PPM. Everything else was read in the source
> at the pinned revision. No timing is reported; the memory figures are from one
> machine and one image and are labelled as such. A verifier rebuilt the pinned
> revision independently against the same nixpkgs libraries, wrote a separate
> probe, and reran the progression, truncation, allocator-cap, corruption,
> memory-peak and row-callback claims; the figures below are the rerun's.

---

## Overview

### What it solves

JPEG XL is a still-image and animation format meant to replace JPEG, PNG and
GIF at once: lossy coding with variable-size DCTs (VarDCT), lossless and
near-lossless coding with integer transforms and context modelling (Modular),
byte-exact recompression of existing JPEG files, HDR and wide gamut, up to
4,096 extra channels, layers and animation. `libjxl` is the reference encoder
and decoder; the README places it in the four-part standard
([`README.md`][readme-std]):

> "The core codestream is specified in 18181-1, the file format in 18181-2.
> Decoder conformance is defined in 18181-3, and 18181-4 is the reference
> software." (link markup removed)

The same README opens with a warning that is itself a finding about the
library's hostile-input record ([`README.md`][readme-security]):

> "**Security Update:** It is highly recommended to update to v0.12 ASAP due to
> numerous security fixes."

For Sparkles the interest is not the API as a dependency (the agreed stance is
that codecs are owned in D, with C libraries as oracles and benchmarks) but the
structure a D decoder must reproduce: the section table of contents, the
render pipeline, the colour model, the entropy layer, the limits and the
conformance procedure.

### Design philosophy

Two principles recur in the in-tree format overview. First, everything that
changes how an image looks belongs to the codestream, not to metadata
([`doc/format_overview.md`][fmt-metadata]):

> "Everything that is needed to correctly display an image is considered to be
> image data, and is part of the core codestream. This includes elements that
> have traditionally been considered 'metadata', such as ICC profiles and Exif
> orientation. [...] By including this functionality in the codestream itself,
> the decoder can provide output in a normalized way (e.g. in RGBA, orientation
> already applied, frames blended and coalesced), simplifying things and making
> it less error-prone for applications."

Second, the frame is a set of independently decodable sections addressed by a
table of contents ([`doc/format_overview.md`][fmt-groups]):

> "In both modes (Modular and VarDCT), the frame data is signaled as a sequence
> of groups. These groups can be decoded independently, and the frame header
> contains a table of contents (TOC) with bitstream offsets for the start of
> each group. This enables parallel decoding, and also partial decoding of a
> region of interest or a progressive preview."

The consequences shape the library: the decoder owns colour conversion,
orientation, blending, upsampling and alpha handling, so its output is "display
ready" by default; and the unit of parallelism, suspension and progressive
refinement is the TOC section, not the byte or the scanline.

---

## How it works

### The event loop the caller drives

The public decoder is a state machine behind an opaque `JxlDecoder`. The caller
subscribes to informative events with a bit mask, hands in bytes, and calls
`JxlDecoderProcessInput` until it returns `JXL_DEC_SUCCESS` or `JXL_DEC_ERROR`
([`decode.h`][h-status]). Every other return value is either a request
(`JXL_DEC_NEED_MORE_INPUT`, `JXL_DEC_NEED_PREVIEW_OUT_BUFFER`,
`JXL_DEC_NEED_IMAGE_OUT_BUFFER`, `JXL_DEC_JPEG_NEED_MORE_OUTPUT`,
`JXL_DEC_BOX_NEED_MORE_OUTPUT`) or a subscribed event (`JXL_DEC_BASIC_INFO`,
`JXL_DEC_COLOR_ENCODING`, `JXL_DEC_PREVIEW_IMAGE`, `JXL_DEC_FRAME`,
`JXL_DEC_FULL_IMAGE`, `JXL_DEC_JPEG_RECONSTRUCTION`, `JXL_DEC_BOX`,
`JXL_DEC_FRAME_PROGRESSION`, `JXL_DEC_BOX_COMPLETE`).

```c
// The probe's loop, reduced (C; see "What was run").
JxlDecoderSubscribeEvents(d, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING |
                             JXL_DEC_FRAME | JXL_DEC_FRAME_PROGRESSION |
                             JXL_DEC_FULL_IMAGE);
JxlDecoderSetInput(d, buf, n);
for (;;) {
  JxlDecoderStatus s = JxlDecoderProcessInput(d);
  if (s == JXL_DEC_NEED_MORE_INPUT) {
    size_t unprocessed = JxlDecoderReleaseInput(d);   // re-supply these bytes
    JxlDecoderSetInput(d, next_start, next_len);
  } else if (s == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
    JxlDecoderSetImageOutBuffer(d, &fmt, out, out_size); // or an out callback
  } else if (s == JXL_DEC_FRAME_PROGRESSION) {
    JxlDecoderFlushImage(d);                          // preview into `out`
  } else if (s == JXL_DEC_SUCCESS || s == JXL_DEC_ERROR) break;
}
```

The input contract is the interesting part. The caller owns the input buffer;
on `JXL_DEC_NEED_MORE_INPUT` it releases it, and must re-supply the unconsumed
tail followed by new bytes ([`decode.h`][h-needmore]):

> "[...] before a next call to @ref JxlDecoderProcessInput all unprocessed bytes
> must be provided again (the address need not match, but the contents must),
> and more bytes must be concatenated after the unprocessed bytes. In most
> cases, @ref JxlDecoderReleaseInput will return no unprocessed bytes at this
> event, the only exceptions are if the previously set input ended within (a)
> the raw codestream signature, (b) the signature box, (c) a box header, or (d)
> the first 4 bytes of a `brob`, `ftyp`, or `jxlp` box. In any of these cases
> the number of unprocessed bytes is less than 20."

It can promise that because the decoder copies partial codestream data into an
internal buffer, `codestream_copy` ([`decode.cc`][cc-copy]): "We copy the input
data in order to be able to release it all through the API it when returning
`JXL_DEC_NEED_MORE_INPUT`." The library therefore absorbs the suspension cost:
the caller never holds bytes for it, and the decoder may hold up to a section's
worth.

### Sections, the table of contents and suspension

Inside a frame, `JxlDecoderProcessSections` walks the TOC, builds a `BitReader`
for every section whose bytes are fully present, and hands the batch to
`FrameDecoder::ProcessSections`; a section that is not complete is simply not
offered ([`decode.cc`][cc-sections]):

```cpp
// lib/jxl/decode.cc, JxlDecoderProcessSections (excerpt)
for (size_t i = dec->next_section; i < toc.size(); ++i) {
  if (dec->section_processed[i]) { pos += toc[i].size; continue; }
  size_t id = toc[i].id;
  size_t size = toc[i].size;
  if (OutOfBounds(pos, size, span.size())) {
    break;
  }
  auto* br = new jxl::BitReader(jxl::Bytes(span.data() + pos, size));
  section_info.emplace_back(jxl::FrameDecoder::SectionInfo{br, id, i});
```

After decoding, a reader that reports an out-of-bounds read is an error, not a
request for more input: "we ensure only bit readers containing a complete
section are provided to the FrameDecoder". This is the design decision that
makes the decoder suspendable without coroutines: **suspension happens only at
section boundaries**, and inside a section the entropy decoder runs to
completion over a bounded, fully buffered span. Every complete section in the
available bytes goes to the frame decoder as one batch, which it may decode in
parallel; the consumed prefix advances only over completed sections. The cost is that a suspended decode keeps a whole group's
bytes buffered and a whole frame's intermediate state allocated.

### The render pipeline

Decoded groups do not go straight to the caller. `PassesDecoderState::PreparePipeline`
builds a chain of `RenderPipelineStage`s for each frame, in a fixed order:
chroma upsampling, Gaborish, the edge-preserving filter (`EPF0`..`EPF2`),
extra-channel upsampling, patches, splines, upsampling, noise, the colour
transform (`YCbCr` or `XYB`), blending, spot colours, tone mapping, the CMS
stage, and finally a write stage ([`dec_cache.cc`][cc-pipeline]). Each stage
declares the border it reads and the shift it applies, and whether a channel is
ignored, modified in place or read into a new buffer
([`render_pipeline_stage.h`][stage-table]):

```text
// render_pipeline_stage.h (selected rows, separator lines dropped)
| class                           | b | b | x | y | mode                    |
|                                 | x | y | s | s |                         |
| UpsamplingStage                 | 2 | 2 | N | N | InOut, Ignored          |
| EPF0Stage                       | 3 | 3 | 0 | 0 | InOut, Ignored          |
| GaborishStage                   | 1 | 1 | 0 | 0 | InOut, Ignored          |
| BlendingStage                   | 0 | 0 | 0 | 0 | InPlace                 |
| XYBStage                        | 0 | 0 | 0 | 0 | InPlace, Ignored        |
| WriteToOutputStage              | 0 | 0 | 0 | 0 | Input, Ignored          |
```

The default implementation, `LowMemoryRenderPipeline`, is described in its
header as "A multithreaded, low-memory rendering pipeline that only allocates a
minimal amount of buffers" ([`low_memory_render_pipeline.h`][lowmem]): it runs
each group plus its borders through the chain row by row, with per-thread row
buffers, instead of materialising each stage's full image. The simple
implementation (`UseSimpleImplementation`) materialises everything and exists
for testing. This is a concrete instance of the
[algorithm and schedule](./concepts.md#algorithm-and-schedule) split: the stage
list is the algorithm, the low-memory pipeline is a fused, tiled schedule.

### The final write: buffers or row callbacks

The write stage targets either a caller buffer described by `JxlPixelFormat`
(`num_channels` 1 to 4, `JXL_TYPE_UINT8`, `UINT16`, `FLOAT16` or `FLOAT`,
`endianness`, row `align`) or a callback ([`decode.h`][h-callback]):

> "The callback receives a horizontal stripe of pixel data, `1` pixel high,
> xsize pixels wide, called a scanline. The xsize here is not the same as the
> full image width, the scanline may be a partial section, and xsize may
> differ between calls. [...] The callback may be called simultaneously by
> different threads when using a threaded parallel runner, on different
> pixels."

`JxlDecoderSetMultithreadedImageOutCallback` adds `init`, `run` and `destroy`
callbacks so the consumer learns the thread count and the maximum stripe width
up front and can allocate per-thread scratch. **Verified:** for the 1024 by
768 progressive test image with four threads, `init` reported 4 threads and at
most 1,024 pixels per call, yet the widest stripe delivered was 288 pixels (272
with one thread, 256 for the lossless file): stripes are about a group wide
(256 pixels plus border), not full rows. One complete pass is 3,072 calls (768
rows by 4 stripes); with a flush at each of the three progression events the
chunked decode made 12,294 calls (the author's run counted 12,288).

### Headers as visited fields

Every header bundle (`SizeHeader`, `ImageMetadata`, `ToneMapping`,
`FrameHeader`, the JPEG reconstruction `JPEGData`) is a `Fields` subclass with
one `VisitFields(Visitor*)` method, and separate visitors read, write, compute
sizes, set defaults and check `AllDefault` ([`field_encodings.h`][fields-base]).
Validation lives in the same method as the layout
([`image_metadata.cc`][tonemapping]):

```cpp
// lib/jxl/image_metadata.cc (excerpt)
Status ToneMapping::VisitFields(Visitor* JXL_RESTRICT visitor) {
  if (visitor->AllDefault(*this, &all_default)) {
    visitor->SetDefault(this);
    return true;
  }
  JXL_QUIET_RETURN_IF_ERROR(
      visitor->F16(kDefaultIntensityTarget, &intensity_target));
  if (intensity_target <= 0.f) {
    return JXL_FAILURE("invalid intensity target");
  }
  JXL_QUIET_RETURN_IF_ERROR(visitor->F16(0.0f, &min_nits));
```

The authors record why the visitor is virtual ([`fields.h`][fields-why]):
"Templates used to be used for this but dynamic polymorphism produces more
compact executables than template reification did."

---

## Analysis

### 1. Pixel and memory model

Internally everything is planar. `Plane<T>` is a single-channel 2-D array whose
rows are aligned and padded, and `Image3<T>` is three planes
([`image.h`][plane-doc]):

> "'Single channel' (one 2D array per channel) simplifies vectorization
> (repeating the same operation on multiple adjacent components) without the
> complexity of a hybrid layout (8 R, 8 G, 8 B, ...). [...] 'Padding' is still
> relevant because vectors could potentially be larger than a cache line. By
> rounding up row sizes to the vector size, we allow reading/writing ALIGNED
> vectors whose first lane is a valid sample. This avoids needing a separate
> loop to handle remaining unaligned lanes."

`BytesPerRow` adds `vec_size - sizeof_t` bytes so the last valid sample can
start a full vector, rounds to the vector and cache-line size, and adds one
alignment unit when the row size is a multiple of 2 KiB to avoid 4K-aliasing
stalls ([`memory_manager_internal.cc`][bytes-per-row]). Extents are `uint32_t`,
the [stride](./concepts.md#stride) is `bytes_per_row_` in bytes, and copy
construction is deleted ("to avoid inadvertent copies"). The VarDCT path works
in `float`; Modular works in `pixel_type`, an `int32_t` with a widened
`pixel_type_w` of `int64_t`, and each Modular `Channel` carries `hshift` and
`vshift`, so subsampled and squeezed channels are first-class
([`modular_image.h`][modular-channel]). The render pipeline offsets the first
pixel by `kRenderPipelineXOffset` (32 samples, 24 on Arm; it indexes `float`
rows, [`render_pipeline_stage.h`][xoffset]) so filters can read left padding.

The public output, by contrast, is interleaved: one buffer of up to four
channels in a `JxlPixelFormat`, plus one buffer per requested extra channel
(`JxlDecoderSetExtraChannelBuffer`), each with its own row alignment. The
caller never sees a plane or a stride other than the row alignment it chose.

The frame is tiled ([tiling](./concepts.md#tiling)): VarDCT groups are 256 by
256 pixels, LF (DC) groups cover 2048 by 2048 pixels at 1:8, and Modular
groups are 128, 256, 512 or 1024 square ([`doc/format_overview.md`][fmt-groups]).

### 2. Genericity mechanism

There is little type-level genericity. Sample types are a closed set chosen at
run time (`JxlDataType`, four values), and the internal planes are
instantiated for a handful of `T` (`ImageB`, `ImageS`, `ImageU`, `ImageI`,
`ImageF`, and the `Image3` variants) ([`image.h`][image-aliases]). Variation is
carried by run-time composition: the render pipeline is a vector of
`unique_ptr` stages selected from the frame header; header parsing is one
`Visitor` interface; colour management is a `JxlCmsInterface` table of function
pointers; threading is a `JxlParallelRunner` function pointer. The one place
where the code is generic at compile time is SIMD: kernels are templates over a
Highway descriptor `D` and vector `V` (see [§7](#_7-cpu-parallelism-and-simd)),
instantiated once per target by re-including the translation unit.

The `fields.h` comment above is the strongest piece of evidence in this survey
on the template-versus-dynamic trade-off for format headers: the authors moved
_away_ from templates for code size.

### 3. Colour and metadata

Colour is part of the codestream. A `JxlColorEncoding` is a structured,
[CICP](./concepts.md#cicp)-like description: colour space (`RGB`, `GRAY`, `XYB`,
`UNKNOWN`), white point and primaries as enums or custom CIE xy values,
transfer function (`709`, `LINEAR`, `SRGB`, `PQ`, `DCI`, `HLG`, or a custom
`GAMMA`) and rendering intent ([`color_encoding.h`][color-encoding]). The enum
values "match a subset of CICP", but primaries and white point are separate
enums, so the mapping is not one to one. Alternatively an arbitrary
[ICC profile](./concepts.md#icc-profile), including CMYK, is stored compressed
in the codestream.

The two modes give the header two meanings ([`doc/format_overview.md`][fmt-colour]):

> "In the first case (non-XYB), the signaled colorspace defines the
> interpretation of the pixel data. In the second case (XYB), the signaled
> colorspace is merely a _suggestion_ of a target colorspace to represent the
> image in [...]"

XYB is an absolute, cube-root-compressed opsin space. Decoding it to linear RGB
is a bias subtraction, a cube and a 3 by 3 matrix ([`dec_xyb-inl.h`][xyb-inl]):

```cpp
// lib/jxl/dec_xyb-inl.h, XybToRgb (excerpt)
auto gamma_r = Add(opsin_y, opsin_x);
auto gamma_g = Sub(opsin_y, opsin_x);
auto gamma_b = opsin_b;
// ... subtract opsin_biases_cbrt ...
// Undo gamma compression: linear = gamma^3 for efficiency.
const auto mixed_r = MulAdd(gamma_r2, gamma_r, neg_bias_r);
// ... then multiply by the 3x3 inverse opsin matrix
```

The comment above it states that it "Avoids clamping to [0, 1] - out of (sRGB)
gamut values may be in-gamut after transforming to a wider space". Because XYB
is absolute, the decoder can emit any enum-described space without a CMS;
emitting to an ICC target requires `JxlDecoderSetCms`. The API exposes the
difference honestly: `JxlDecoderGetColorAsEncodedProfile` fails when only ICC
exists, and `JxlDecoderGetColorAsICCProfile` synthesises an ICC profile from
the enums when only enums exist, with a long caveat about HDR
([`decode.h`][h-icc-hdr]):

> "This is especially detrimental to PQ which will then be interpreted as if
> the maximum signal value represented SDR white instead of 10000 cd/m^2,
> meaning that the image will be displayed two orders of magnitude (5-7 EV)
> too dim."

**Verified:** for the lossy test file the decoder reported an XYB-encoded image
(`uses_original_profile` false), an encoded profile with
`JXL_TRANSFER_FUNCTION_SRGB` for the output data, and a synthesised 504-byte
ICC profile.

HDR is described by `ToneMapping` in the image header (`intensity_target`,
`min_nits`, `relative_to_max_display`, `linear_below`), surfaced through
`JxlBasicInfo`. `JxlDecoderSetDesiredIntensityTarget` asks the decoder to tone
map to a display peak, with the explicit disclaimer that the mapping "is not
meant to be considered authoritative in any way. It may change from version to
version" ([`decode.h`][h-tonemap]); `ToneMappingStage` runs in the pipeline.
[HDR gain maps](./concepts.md#hdr-gain-map) are carried in a `jhgm` box;
`gain_map.h` only serialises and parses the bundle (ISO 21496-1 metadata, a
colour encoding, a compressed ICC profile and a JPEG XL codestream for the gain
map) ([`gain_map.h`][gain-map]). A grep of `decode.cc` for `jhgm` finds nothing:
the decoder does not apply a gain map; the application must.

Alpha is an extra channel with an `alpha_premultiplied` flag;
`JxlDecoderSetUnpremultiplyAlpha` converts associated alpha back to straight on
request ([straight and premultiplied alpha](./concepts.md#straight-and-premultiplied-alpha)).
Orientation is applied by default and `JxlBasicInfo` then reports the oriented
size; `JxlDecoderSetKeepOrientation` opts out.

[Metadata](./concepts.md#image-metadata) that does not affect rendering lives
in container boxes: `Exif`, `xml ` (XMP) and `jumb` (JUMBF), each optionally
Brotli-compressed in a `brob` box. The decoder emits `JXL_DEC_BOX` for every
box, including the codestream boxes; the caller reads type and size and, if it
wants the payload, supplies a buffer and grows it on
`JXL_DEC_BOX_NEED_MORE_OUTPUT` ([`decode.h`][h-boxes]). "The Exif orientation
should be ignored by applications; the JPEG XL codestream orientation takes
precedence" ([`decode.h`][h-boxtype]). libjxl does not parse EXIF or XMP.

### 4. I/O and codec architecture

The decoder API answers the codec questions as follows.

| Question              | Answer at the pinned revision                                                                                                                                                       |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Push or pull          | [Push](./concepts.md#push-and-pull-decoding): the caller supplies bytes and receives status codes; there is no reader callback                                                      |
| Incremental           | Yes, with any chunk size. **Verified:** 1-byte chunks decoded the lossless file (3,539 `JXL_DEC_NEED_MORE_INPUT` returns for 3,540 bytes)                                           |
| Suspendable           | Yes, at section granularity; the library buffers partial input internally (`codestream_copy`) so the caller re-supplies fewer than 20 bytes                                         |
| Progressive           | Yes: `JXL_DEC_FRAME_PROGRESSION` at levels from `kFrames` to `kGroups`, plus `JxlDecoderFlushImage` at a `JXL_DEC_NEED_MORE_INPUT` between `JXL_DEC_FRAME` and `JXL_DEC_FULL_IMAGE` |
| Row or tile callbacks | Row stripes, possibly concurrent, via `JxlDecoderSetImageOutCallback` or the multithreaded variant                                                                                  |
| Region decode         | The format allows it (independent groups and a TOC); the public API has no crop or region-of-interest call                                                                          |
| Downscaled decode     | No. Progressive flushes report a ratio (`JxlDecoderGetIntendedDownsamplingRatio`: 1, 2, 4 or 8) but write upsampled pixels into the full-size buffer                                |
| Frame access          | `JxlDecoderSkipFrames`, `JxlDecoderSkipCurrentFrame`, `JxlDecoderRewind` (keeps state that speeds up later skips), optional `jxli` frame index box in the container                 |

**Verified progression:** the progressive lossy file (24,825 bytes, encoded
with `cjxl -d 1 -p`), decoded with `JxlDecoderSetProgressiveDetail(d, kPasses)`
and fed in 4,096-byte chunks, produced `JXL_DEC_BASIC_INFO`
after the first chunk, `JXL_DEC_FRAME` and a 1:8 `JXL_DEC_FRAME_PROGRESSION`
after 16,384 bytes, 1:4 after 20,480, 1:2 after 24,576, and `JXL_DEC_FULL_IMAGE`
at the end; every flush succeeded and wrote the full 3,145,728-byte RGBA
buffer. With the default detail only the 1:8 event fires, as the header says.
Truncated at 18,000 bytes, the decoder returned `JXL_DEC_NEED_MORE_INPUT` with a
usable 1:8 preview already flushed, and further flushes at that point also
succeeded (each rewrote the 1:8 preview).

This is [incremental, progressive and suspendable](./concepts.md#incremental-progressive-and-suspendable-decoding)
in the sense the concepts page defines, with two caveats. The suspension state
is the whole `JxlDecoder` object, opaque and not serialisable; and the decoder
is not cancellable mid-section, because a section is decoded in one call.

The container ([container and bitstream](./concepts.md#container-and-bitstream))
is ISOBMFF-shaped: a naked codestream starts `0xFF0A`; a container starts with
the `JXL ` signature box and `ftyp`, then `jxlc` or a sequence of `jxlp` boxes
that concatenate to the codestream, plus `jbrd`, `jxli`, `jxll` (level),
metadata and `brob` boxes ([`doc/format_overview.md`][fmt-container]; [box
list][fmt-boxes]; [`decode.h`][h-boxtype] for `jxll`). Release
0.12.0 added out-of-order `jxlp` boxes (`ftyp` minor version 1) so an encoder
can stream without seeking; the decoder buffers early boxes in a map keyed by
index ([`CHANGELOG.md`][changelog-012]).

JPEG lossless recompression keeps the JPEG's quantised DCT coefficients as a
VarDCT frame restricted to 8 by 8 blocks, and stores everything else needed to
rebuild the original file byte for byte (marker order, Huffman tables, padding
bits, tail data) in the `jbrd` box as a `JPEGData` bundle
([`doc/format_overview.md`][fmt-jbrd], [`jpeg_data.h`][jpeg-data]). On decode,
`JXL_DEC_JPEG_RECONSTRUCTION` lets the caller set a JPEG output buffer, and
`JxlToJpegDecoder` with `WriteJpeg` re-serialises the JPEG instead of rendering
pixels. The whole feature compiles out with `JPEGXL_ENABLE_TRANSCODE_JPEG`.

Two coding modes share one entropy layer. VarDCT uses DCT sizes from 2 by 2 to
256 by 256 (`AcStrategy::kMaxCoeffBlocks = 32` blocks of 8), adaptive
quantisation, chroma-from-luma, and up to 11 passes (`kMaxNumPasses`); its LF
image and extra channels are themselves Modular sub-bitstreams. Modular is
integer-only, with reversible colour transforms, palette and the Squeeze
(modified Haar) transform for progressive lossless, and meta-adaptive (MA)
decision trees that select a context per pixel. Both encode tokens with the
"hybrid integer" scheme over prefix codes or rANS with optional LZ77; the
[entropy-codecs thread][p-jxl] records that the final rANS state "acts like a
checksum". `ANSSymbolReader::CheckANSFinalState` implements it, and is compiled
to `return true` under `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` so fuzzers
reach past it ([`dec_ans.h`][ans-final]).

### 5. Hostile input and safety

[Hostile input](./concepts.md#hostile-input) is handled by explicit checks in
C++, a caller-supplied allocator, sanitiser-backed fuzzing, and a CVE process;
there is no memory-safe core. The configurable and built-in limits found at the
pinned revision:

| Limit                                | Value and where                                                                                                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Image dimensions                     | No policy limit. `CheckSizeLimit` only rejects overflow of 32-padded width times height in `size_t` ([`decode.cc`][cc-sizelimit])                             |
| Memory                               | No byte budget in the API; the caller's `JxlMemoryManager` may return `NULL`, which surfaces as `JXL_DEC_ERROR`                                               |
| Codestream levels                    | Level 5 and 10 are signalled (`jxll`) and checked by the encoder; `decode.cc` has no level check                                                              |
| MA tree size                         | `min(1 << 22, 1024 + xsize * ysize * channels / 16)` nodes ([`dec_modular.cc`][tree-limit]); depth at most 2,048 (`kHeightLimit`, [`dec_ma.cc`][tree-height]) |
| Spline control points                | `min(1 << 20, xsize * ysize / 2)` ([`splines.cc`][spline-limit])                                                                                              |
| Decoded ICC profile                  | 1 << 28 bytes ([`icc_codec.cc`][icc-limit]; the comment beside it says "64 MiB")                                                                              |
| EXIF or XMP box kept for JPEG output | 64 MiB (`kBlockSizeLimit`, [`decode.cc`][cc-exif-limit])                                                                                                      |
| Out-of-order `jxlp` buffers          | 1 << 20 boxes, 1 << 48 total bytes on 64-bit (`kNumBuffersLimit`, `CanAddBuffer`, [`decode.cc`][cc-jxlp-limit])                                               |
| Passes, reference frames             | 11 and 4 ([`common.h`][common-limits])                                                                                                                        |

The pattern worth noting is that **limits scale with the declared image size**:
the tree, spline and patch budgets are bounded by pixel count, so a small image
cannot carry a large decoding workload. The gap is the converse: nothing bounds
the pixel count itself, and a source comment says so
([`decode.cc`][cc-oom]): "TODO(eustas): no CodecInOut -> no image size
reinforcement -> possible OOM." The streaming fuzzer carries the matching
"TODO(eustas): update when API will provide OOM status"
([`streaming_fuzzer.cc`][streaming-oom]).

**Verified:** with a `JxlMemoryManager` that refused allocations past 4 MB, the
progressive test file decoded its basic info, frame header and 1:8 progression,
then `JxlDecoderProcessInput` returned `JXL_DEC_ERROR` once an allocation was
refused (one refusal in the rerun, two in the author's run). Flipping four bytes in the middle of the same file also returned
`JXL_DEC_ERROR`. The two failures are indistinguishable through the API; the
status enum's own comment reads "TODO(lode): add function to get error
information from decoder" ([`decode.h`][h-status]).

The fuzzing setup is described in [`doc/fuzzing.md`][fuzzing-doc]: libjxl is the
OSS-Fuzz project `libjxl`, and "The main one is `djxl_fuzzer`, which uses the
public C decoder API [...] the last few bytes of the fuzzer input are used to
decide _how_ will the API be used (if preview is requested, the pixel format
requested, if the .jxl input data is provided altogether, etc)". The fuzzer
also picks the SIMD target from the input
(`hwy::SetSupportedTargetsForTest(targets[getFlag(...)])`), caps pixels at
`1 << 21` per frame and memory at 1 GiB through a tracking manager
([`djxl_fuzzer.cc`][djxl-fuzzer]). `tools/CMakeLists.txt` defines ten fuzz
targets ([`tools/CMakeLists.txt`][fuzzer-list]), and the OSS-Fuzz project's own
build script, kept in the `google/oss-fuzz` repository, builds all ten in
release mode with `-DJXL_IS_DEBUG_BUILD=1` so `JXL_DASSERT` stays live
([`projects/libjxl/build.sh`][ossfuzz-project]). The in-tree
`tools/scripts/ossfuzz-build.sh`, which `ci.sh` mounts into the OSS-Fuzz image
for local reproduction ([`ci.sh`][ci-ossfuzz]), lists only six of them
(`color_encoding_fuzzer`, `djxl_fuzzer`, `fields_fuzzer`, `icc_codec_fuzzer`,
`rans_fuzzer`, `transforms_fuzzer`) ([`ossfuzz-build.sh`][ossfuzz-build]).

The project's vulnerability playbook draws the line between assertions and
bugs in a way that matters for D's build modes ([`doc/vuln_playbook.md`][playbook-dassert]):

> "When considering the impact of a bug, "release" mode should be assumed. In
> non-release mode `JXL_DASSERT` is enabled. This means that if a `JXL_DASSERT`
> protects an out-of-bounds (OOB) write, then the impact of a bug hitting the
> `JXL_DASSERT` is at least an OOB write."

Three CVEs illustrate the classes a reimplementation must design out (all
descriptions from NVD):

- [CVE-2021-22564][cve-2021-22564] (heap out-of-bounds copy): "when processing
  the groups out of order the decoder can perform an out of bounds copy of
  image pixels [...] when processing the right or bottom edges of the image".
  Parallel, out-of-order group decoding plus partial edge groups is where
  bounds arithmetic breaks.
- [CVE-2024-11498][cve-2024-11498] (stack exhaustion, CWE-400): "A
  specifically-crafted file can cause the JPEG XL decoder to use large amounts
  of stack space (up to 256mb is possible, maybe 512mb)". The fix is the
  2,048-deep explicit stack in `ValidateTree` above; recursion over an
  attacker-shaped tree is the bug class.
- [CVE-2025-12474][cve-2025-12474] (uninitialised read, CWE-908): patches
  referencing an area outside the image bounds made the decoder read
  uninitialised memory, because "An incorrect optimization causes the decoder
  to omit populating those areas". The 0.11.2 changelog entry that names this
  CVE is a fix to the tile dimension of the low-memory pipeline
  ([`CHANGELOG.md`][changelog-0112]): the fused schedule's skipping of
  "unobservable" work is itself an attack surface.

The 0.12.0 changelog lists 29 further hardening pull requests ("integer
overflows/underflows, out-of-bounds reads/writes, buffer overflows, and null
pointer guards") without individual CVEs ([`CHANGELOG.md`][changelog-012-sec]).

### 6. Allocation and ownership

The caller owns the input buffer, every output buffer (pixels, extra channels,
preview, JPEG, box payloads) and the runner; the decoder borrows them between a
`Set...` and the matching `Release...` or event. Internal memory goes through
`JxlMemoryManager`, two function pointers and an opaque pointer, whose header
promises "All dynamic memory will be allocated and freed with these functions
if they are not NULL" ([`memory_manager.h`][memory-manager]). The promise is
broader than the code: `decode.cc` keeps `std::vector` and `std::map` members
(`frame_required`, `exif_metadata`, `jxlp_ooo_buffer`) and the render pipeline
uses `std::vector` row tables, which go through the global allocator. Planes
and padded byte buffers do use the manager (`AlignedMemory::Create`).

**Verified** (one image, one machine): decoding the 1024 by 768 progressive
file, the bytes in use through the manager peaked at about 11.3 MB (11,274,042
bytes in the rerun) with the
default single-threaded runner and about 15.5 MB with a four-thread runner,
beside the caller's 3 MB RGBA output buffer. The working set is several times
the output, and grows with the thread count because of per-thread pipeline
buffers.

### 7. CPU parallelism and SIMD

Threading is inverted: the library never creates threads. It calls a
caller-provided `JxlParallelRunner` with an `init(num_threads)` callback and a
`func(opaque, value, thread_id)` to run for every `value` in a range
([`parallel_runner.h`][parallel-runner]):

```c
typedef JxlParallelRetCode (*JxlParallelRunner)(
    void* runner_opaque, void* jpegxl_opaque, JxlParallelRunInit init,
    JxlParallelRunFunction func, uint32_t start_range, uint32_t end_range);
```

The header explains the shape: "When tasks are identical or differ only by an
integer input parameter, it is much faster to store just one function of an
integer parameter and call it for each value." A `NULL` runner runs
everything on the calling thread. The shipped `ThreadParallelRunner` is a
fixed pool that load-balances with an atomic counter
([`thread_parallel_runner_internal.h`][thread-runner]). Work units are groups,
rows of a plane, or pipeline tiles; the thread id indexes per-thread scratch
allocated in `init`.

SIMD is [Highway][hwy-repo] with static and dynamic dispatch. A translation
unit defines `HWY_TARGET_INCLUDE` as its own path and includes
`hwy/foreach_target.h`, which re-includes the file once per enabled target
inside `HWY_NAMESPACE`; a `HWY_ONCE` section then exports a table and calls
through `HWY_DYNAMIC_DISPATCH` ([`dec_xyb.cc`][dec-xyb-dispatch]):

```cpp
// lib/jxl/dec_xyb.cc (excerpt)
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "lib/jxl/dec_xyb.cc"
#include <hwy/foreach_target.h>
// ... kernels in namespace jxl::HWY_NAMESPACE ...
#if HWY_ONCE
HWY_EXPORT(OpsinToLinear);
Status OpsinToLinear(/* ... */) {
  return HWY_DYNAMIC_DISPATCH(OpsinToLinear)(opsin, rect, pool, linear,
```

53 files under `lib/jxl` use this pattern (a `git grep` count of
`foreach_target.h`). The kernels loop `for (x = 0; x < xsize; x += Lanes(d))`
with no tail: the padded rows of §1 make that safe. Some paths are
target-specific by design: `FastXYBTosRGB8` is NEON intrinsics with 16-bit
fixed point, enabled only `#if HWY_TARGET == HWY_NEON` and not under
`JXL_HIGH_PRECISION`. Conformance and fuzzing exercise each target (§10).

### 8. GPU offload and interop

Not applicable at this revision: there is no GPU code path, no GPU-friendly
output format (no planar YUV output, no texture format), and no hook in the
render pipeline for an external device. The design does contain what GPU decode
would need, and a reimplementation could use it: independent groups with known
byte offsets, an absolute colour space whose inverse is a cube and a matrix,
and stages declared with their borders. The [GPU decode thread][p-gpu-decode]
covers GPU entropy decoding; nothing in libjxl attempts it.

### 9. Temporal, animation and containers

Animation is native to the codestream: `JxlBasicInfo` has `have_animation` and
a tick rate, each displayed frame has a duration (and an optional timecode and
name) in `JxlFrameHeader`, and loops are signalled in the header. Frames can be
smaller than or offset from the canvas, blended with one of several modes onto
one of four saved reference frames (`kMaxNumReferenceFrames`), and zero-duration
frames are layers ([`doc/format_overview.md`][fmt-frames]). By default the
decoder coalesces, so every emitted frame is canvas-sized and blended;
`JxlDecoderSetCoalescing(JXL_FALSE)` returns raw layers with crop offsets for
editors. Frames of type `kReferenceOnly` and `kLfFrame` are never returned.
Seeking uses `JxlDecoderSkipFrames` after `JxlDecoderRewind`, helped by an
optional `jxli` keyframe index box. There is no audio, timeline or container
for other codecs; the container is single-image ISOBMFF.

Extra channels make the image N-channel: `JxlExtraChannelType` lists alpha,
depth, spot colour, selection mask, black (for CMYK), colour filter array,
thermal and reserved types ([`codestream_header.h`][extra-channels]), each
with its own bit depth and a `dim_shift` that lets it be stored at reduced
resolution and upsampled in the pipeline.

### 10. Testing and conformance

The decoder conformance corpus is a separate repository, `libjxl/conformance`,
pinned in CI by `CONFORMANCE_REPO_HASH: 4bf053529c7cefd2951be453475bb3dccc7e7be8`.
The workflow builds `djxl` once per SIMD target and runs the corpus for both
codestream levels on each ([`conformance.yml`][conformance-yml]):

```text
# .github/workflows/conformance.yml (test matrix)
name: [level5, level10]
target: [AVX3, AVX2, SSE4, SSSE3, EMU128, SCALAR, SCALAR_ASAN, SVE2_128, SVE2, SVE, NEON_WITHOUT_AES]
```

AVX3 runs under Intel SDE on the hosted x86 runners; the Arm targets run on
Arm runners, the SVE ones under `qemu-aarch64` ([`conformance.yml`][conformance-emu]). The
runner `tools/conformance/conformance.py` compares decoded NumPy arrays against
reference arrays with a per-test RMSE limit and a peak-error limit, compares
reconstructed JPEGs byte for byte, and checks ICC and metadata
([`conformance.py`][conformance-py]). Conformance is therefore tolerance-based
for pixels and exact for bitstream reconstruction, which matches how 18181-3
defines precision bounds ([`doc/format_overview.md`][fmt-conformance]).

Unit tests (53 `*_test.cc` files in `lib/jxl`) use GoogleTest, and eight files
use Highway's `HWY_EXPORT_AND_TEST_P` to run each test once per compiled SIMD
target (for example `dct_test.cc`). Test images come from the `libjxl/testdata`
submodule. `ci.sh` provides ASan and MSan builds and the OSS-Fuzz
reproduction recipes (`ossfuzz_asan`, `ossfuzz_msan`, `ossfuzz_ubsan`).

Two independent decoders exist outside this repository and are oracles in
their own right. [`jxl-rs`][jxl-rs] describes itself as "a high-performance,
conforming, and memory-safe JPEG XL decoder written in Rust" and "the JPEG XL
decoder implementation used in **Google Chrome / Chromium** and **Mozilla
Firefox**", developed within the JPEG XL project but "not (yet) an official
reference implementation". [`jxl-oxide`][jxl-oxide] is "A spec-conforming JPEG
XL decoder written in pure Rust", and is the JPEG XL backend that
[zune-image](./zune-image.md) delegates to. Neither is mentioned anywhere in the
libjxl tree at the pinned revision (a `git grep` for both names returns nothing).

---

## Lessons for Sparkles

- **Q4.** Section-granular suspension is the cheapest suspendable design that
  works for an entropy-coded format: the TOC gives each group's byte size up
  front, the decoder decodes only complete sections, and an out-of-bounds read
  inside a complete section is an error rather than "need more". A D decoder
  can keep its inner entropy loop `@nogc nothrow` over a bounded `const(ubyte)[]`
  with no resumable state, and put suspension in a thin outer state machine.
  What does not transfer is libjxl's internal copy of partial input: under
  Sparkles' caller-owned-storage rule the copy should be a caller-provided
  `Buffer` sized from the TOC, so the budget is visible. Where the event loop
  and reading stand is in the [event-horizon baseline][bl-eh] (G1, G6).
- **Q4.** The `Fields`/`Visitor` pattern (one visit method describes a header,
  and read, write, size and default visitors interpret it) is the same idea as
  a declarative binary description in `sparkles:wired`. The libjxl comment that
  dynamic dispatch beat templates on code size is evidence to weigh against
  instantiating a template per header in D; design by introspection can produce
  one compact interpreter as easily as N specialisations. Bit-level fields
  (`U32Enc` selectors, `F16`, conditional fields, extensions) are exactly what
  the [wired baseline][bl-wired] marks as missing (G2, G3).
- **Q8.** The limits that scale with declared pixel count (MA tree nodes,
  spline points) are a pattern to copy, and the missing pixel-count limit is a
  pattern to avoid: a D decoder should take an explicit limits value (pixels,
  bytes of working memory, ICC and metadata sizes) whose defaults are stated,
  like `maxPngPixels` in the draft `sparkles:image`
  ([existing-code baseline][bl-existing], G1). Error results should distinguish
  "limit" from "malformed" from "allocation failed"; libjxl's single
  `JXL_DEC_ERROR` and its own TODOs show the cost of not doing so, and
  `sparkles.base.expected` with a typed error kind already does.
- **Q8.** The vulnerability playbook's rule that a check compiled only into
  non-release builds (`JXL_DASSERT`) is no check maps directly onto Sparkles'
  build policy: `checked` keeps
  assertions in shipping builds, so a bounds `assert` in a D decoder remains a
  guard in production. The OSS-Fuzz practice of fuzzing release builds with
  debug assertions forced on is the equivalent of fuzzing the `checked` build.
- **Q8.** Fuzzing the SIMD target selection from the input bytes, and running
  the conformance corpus once per target, are both directly transferable to the
  BLAKE3-style per-target dispatch that the [shaders and SIMD baseline][bl-shaders]
  describes (G4, G5): a D codec with `@target` kernels needs the dispatch
  choice to be overridable for tests, which BLAKE3's is (`Blake3.withBackend`
  takes a `Blake3Backend`) and a shared facility is not yet. Disabling the rANS final-state check under a
  fuzzing version flag is a technique to copy deliberately, with the same flag
  name visible in the code.
- **Q8.** `libjxl/conformance` gives a ready oracle: reference arrays with
  stated RMSE and peak tolerances per test, plus byte-exact JPEG reconstruction.
  A D decoder can be held to the same bar without linking libjxl. `jxl-rs` and
  `jxl-oxide` are two further independent decoders for differential testing,
  which the [existing-code baseline][bl-existing] (G11) shows Sparkles has no
  harness for yet.
- **Q1.** libjxl keeps two models: aligned, padded single-channel planes
  internally (so SIMD loops need no tail), and an interleaved, caller-shaped
  buffer at the boundary. Padding rows to a vector multiple is a constraint a
  Sparkles view type would have to express (a minimum row pitch and alignment).
  libjxl stores `uint32_t` extents and checks every narrowing and every
  `size_t` product (`JXL_ENSURE(xsize32 == xsize)`, `SafeMul`, `CheckSizeLimit`);
  a D view type needs the same checks whatever its extent type. Sub-sampled channels as `hshift`/`vshift` on a
  plane are the model the [existing-code baseline][bl-existing] lacks (G2).
- **Q3.** The render pipeline is a fused, tiled, row-streaming schedule over a
  declared stage list with per-stage borders and shifts: the shape that Halide
  calls algorithm and schedule ([halide](./halide.md)). It is evidence that a
  codec's post-processing can share an algorithm library's stage abstraction
  if stages declare their footprint. CVE-2025-12474 is the warning: skipping
  work the scheduler believes unobservable produced an uninitialised read, so
  the schedule needs its own tests against the simple, unfused pipeline, which
  libjxl keeps for that purpose.
- **Q5.** The minimum colour model libjxl needs is a CICP-like structure (space,
  primaries, white point, transfer, intent) with custom xy values and a gamma
  escape, plus an ICC blob, plus a tone-mapping block, plus an
  absolute-to-display conversion that needs no CMS. Synthesising ICC from the
  structure is possible but lossy for PQ and HLG, as the header's caveat says.
  Gain maps arrive as a box the decoder does not apply, so a Sparkles colour
  layer has to own gain-map application whatever codec feeds it. The
  [existing-code baseline][bl-existing] records that colour is untyped today
  (G4) and metadata discarded (G5).
- **Q7.** Threading through a caller-supplied range runner with an `init` that
  reports the thread count is a good fit for Sparkles: an event-horizon offload
  pool can implement `JxlParallelRunner`'s contract, and a D decoder can take
  the same "run f over 0..n" capability as a template parameter. The
  per-thread scratch that grows the working set (15.5 MB against 11.3 MB in the
  probe) is the cost to budget.
- **Q9.** libjxl is one library with compile-time feature switches
  (`JPEGXL_ENABLE_TRANSCODE_JPEG`, boxes, CMS) and three link units (`libjxl`,
  `libjxl_cms`, `libjxl_threads`). The split that matters is the CMS and the
  thread pool, both behind C function-pointer interfaces, which is weak evidence
  for keeping colour management and scheduling outside an image-formats
  package and reaching them through narrow interfaces.

## Strengths

- A complete, documented incremental decoder: push-fed, suspendable at section
  boundaries, progressive with explicit flush, row-callback output that can be
  concurrent.
- The format's TOC and independent groups make parallel decode, out-of-order
  arrival and (in principle) region decode cheap.
- Colour is never ambiguous: every image has a defined space, and XYB can be
  rendered to any enum-described space without a CMS.
- Threading and allocation are injected by the caller; the library creates no
  threads.
- Conformance is run per SIMD target and per level against a pinned external
  corpus with numeric tolerances; fuzzing covers SIMD target choice and API
  usage, not just bytes.
- Workload limits scale with declared image size for trees and splines.

## Weaknesses

- No pixel-count or memory budget in the API; out-of-memory and malformed input
  share one status code, and the source admits the OOM gap.
- A long CVE history in a C++ codebase, with a 0.12.0 release that bundles 29
  hardening fixes; memory safety rests on checks and fuzzing.
- No public region or downscaled decode, although the format supports both.
- `JxlMemoryManager` does not see every allocation; standard containers bypass it.
- The working set is a multiple of the output size and grows with thread count.
- Gain maps, EXIF and XMP are passed through, not interpreted; tone mapping is
  explicitly non-authoritative.
- The in-tree OSS-Fuzz reproduction script lists six of the ten fuzz targets
  that the OSS-Fuzz project builds, so `ci.sh ossfuzz_*` reproduces a subset.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                   | Trade-off                                                                            |
| --------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Push API with internal copy of partial input              | Caller never holds bytes for the decoder; any chunk size works              | Hidden buffering; suspension state is an opaque object                               |
| Suspend only at TOC section boundaries                    | Entropy decoding runs over complete, bounded spans; no resumable inner loop | A whole section must be buffered; no mid-section cancellation                        |
| Decoder applies orientation, blending, colour and alpha   | Output is display-ready and unambiguous; metadata can be stripped safely    | Large decoder; editors must opt out (`SetCoalescing`, `SetKeepOrientation`)          |
| XYB as an absolute internal space                         | Perceptual quantisation; conversion to any enum space without a CMS         | ICC targets need a CMS; ICC synthesis is approximate for PQ and HLG                  |
| Fused low-memory render pipeline of declared stages       | Bounded working set, cache locality, parallel tiles                         | Skipping "unobservable" work has caused a CVE; a simple pipeline is kept for testing |
| Planar, padded, aligned internal planes                   | SIMD loops without tails; no false sharing                                  | Interleaving and copying at the API boundary                                         |
| Virtual `Visitor` for headers                             | Smaller binaries than per-header template instantiation                     | Run-time dispatch in header parsing                                                  |
| Caller-supplied runner and allocator as C function tables | Embeds in any threading and memory model                                    | Allocator coverage is partial; no budget semantics                                   |
| Highway static plus dynamic dispatch per translation unit | One kernel source, many targets, run-time selection                         | Every target must be tested; conformance runs eleven builds                          |
| Limits scaled to declared pixel count, no pixel-count cap | Small images cannot carry large workloads                                   | A huge declared image is accepted until allocation fails                             |

## Sources

- [libjxl/libjxl repository][repo], read at `e2948747fee8e99a614066eb058e67a0b8de995f`
- [`README.md` — the standard's parts][readme-std]; [security banner][readme-security]
- [`lib/include/jxl/decode.h` — status and events][h-status]; [input contract][h-needmore];
  [colour profiles and the HDR caveat][h-icc-hdr]; [tone mapping][h-tonemap];
  [row callbacks][h-callback]; [box events][h-boxes]; [box types and Exif orientation][h-boxtype]
- [`lib/include/jxl/color_encoding.h`][color-encoding]; [`codestream_header.h` — extra channels][extra-channels];
  [`gain_map.h`][gain-map]; [`memory_manager.h`][memory-manager]; [`parallel_runner.h`][parallel-runner]
- [`lib/jxl/decode.cc` — input copy][cc-copy]; [`CheckSizeLimit`][cc-sizelimit];
  [section processing][cc-sections]; [OOM comment][cc-oom]; [EXIF/XMP limit][cc-exif-limit];
  [`jxlp` buffer limits][cc-jxlp-limit]
- [`lib/jxl/dec_cache.cc` — `PreparePipeline`][cc-pipeline];
  [`render_pipeline/render_pipeline_stage.h` — stage table][stage-table];
  [`render_pipeline/low_memory_render_pipeline.h`][lowmem]; [`kRenderPipelineXOffset`][xoffset]
- [`lib/jxl/image.h` — `Plane` rationale][plane-doc]; [type aliases][image-aliases];
  [`memory_manager_internal.cc` — `BytesPerRow`][bytes-per-row];
  [`modular/modular_image.h` — `Channel`][modular-channel]
- [`lib/jxl/field_encodings.h` — `Fields`][fields-base]; [`fields.h` — `Visitor`][fields-why];
  [`image_metadata.cc` — `ToneMapping::VisitFields`][tonemapping]
- [`lib/jxl/dec_xyb.cc` — Highway dispatch][dec-xyb-dispatch]; [`dec_xyb-inl.h` — `XybToRgb`][xyb-inl];
  [`dec_ans.h` — final-state check][ans-final]; [`common.h` — pass and reference limits][common-limits]
- [`lib/jxl/modular/encoding/dec_ma.cc` — tree height][tree-height];
  [`dec_modular.cc` — tree size][tree-limit]; [`splines.cc`][spline-limit]; [`icc_codec.cc`][icc-limit];
  [`jpeg/jpeg_data.h`][jpeg-data]
- [`lib/threads/thread_parallel_runner_internal.h`][thread-runner]
- [`doc/format_overview.md` — metadata][fmt-metadata]; [colour][fmt-colour]; [frames][fmt-frames];
  [groups][fmt-groups]; [JPEG reconstruction][fmt-jbrd]; [container][fmt-container]; [boxes][fmt-boxes];
  [conformance][fmt-conformance]
- [`doc/fuzzing.md`][fuzzing-doc]; [`doc/vuln_playbook.md`][playbook-dassert];
  [`tools/djxl_fuzzer.cc`][djxl-fuzzer]; [`tools/streaming_fuzzer.cc`][streaming-oom];
  [`tools/scripts/ossfuzz-build.sh`][ossfuzz-build]; [`ci.sh` OSS-Fuzz reproduction][ci-ossfuzz];
  [`tools/CMakeLists.txt`][fuzzer-list]
- OSS-Fuzz: [`projects/libjxl/build.sh`][ossfuzz-project] at `631d777e53ff3d9c5cdc24f46b45d05b3424ddbb`
- [`.github/workflows/conformance.yml`][conformance-yml]; [emulators][conformance-emu];
  [`tools/conformance/conformance.py`][conformance-py]
- [`CHANGELOG.md` — 0.12.0][changelog-012]; [0.12.0 security][changelog-012-sec]; [0.11.2][changelog-0112]
- NVD: [CVE-2021-22564][cve-2021-22564], [CVE-2024-11498][cve-2024-11498], [CVE-2025-12474][cve-2025-12474]
- [`jxl-rs` README][jxl-rs] at `87620c4f566a7204865b3bcdc160033114a9a253`;
  [`jxl-oxide` README][jxl-oxide] at `c0cc4c7ea57c1207f38ff2970d94757470613be4`
- Sparkles: [existing-code baseline][bl-existing], [shaders and SIMD baseline][bl-shaders],
  [wired baseline][bl-wired], [event-horizon baseline][bl-eh];
  papers: [entropy coding][p-jxl], [GPU decode][p-gpu-decode]

<!-- References -->

[repo]: https://github.com/libjxl/libjxl/tree/e2948747fee8e99a614066eb058e67a0b8de995f
[hwy-repo]: https://github.com/google/highway/tree/457c891775a7397bdb0376bb1031e6e027af1c48
[rtd]: https://libjxl.readthedocs.io/en/latest/
[patents]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/PATENTS
[readme-std]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/README.md#L32-L36
[readme-security]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/README.md#L25-L26
[h-status]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L116-L326
[h-needmore]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L143-L157
[h-icc-hdr]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L721-L771
[h-tonemap]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L830-L841
[h-callback]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L1087-L1132
[h-boxes]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L268-L303
[h-boxtype]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/decode.h#L1315-L1341
[xoffset]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/render_pipeline/render_pipeline_stage.h#L23-L30
[fmt-boxes]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L225-L284
[ossfuzz-project]: https://github.com/google/oss-fuzz/blob/631d777e53ff3d9c5cdc24f46b45d05b3424ddbb/projects/libjxl/build.sh#L61-L91
[ci-ossfuzz]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/ci.sh#L804-L816
[conformance-emu]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/.github/workflows/conformance.yml#L260-L267
[color-encoding]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/color_encoding.h
[extra-channels]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/codestream_header.h#L40-L62
[gain-map]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/gain_map.h
[memory-manager]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/memory_manager.h#L46-L65
[parallel-runner]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/include/jxl/parallel_runner.h#L26-L129
[cc-copy]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/decode.cc#L528-L543
[cc-jxlp-limit]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/decode.cc#L553-L571
[cc-sizelimit]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/decode.cc#L725-L732
[cc-sections]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/decode.cc#L1157-L1221
[cc-oom]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/decode.cc#L1223
[cc-exif-limit]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/decode.cc#L1719-L1737
[cc-pipeline]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/dec_cache.cc#L117-L371
[stage-table]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/render_pipeline/render_pipeline_stage.h#L48-L81
[lowmem]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/render_pipeline/low_memory_render_pipeline.h#L25-L26
[plane-doc]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/image.h#L118-L136
[image-aliases]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/image.h#L186-L191
[bytes-per-row]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/memory_manager_internal.cc#L60-L104
[modular-channel]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/modular/modular_image.h#L25-L38
[fields-base]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/field_encodings.h#L31-L39
[fields-why]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/fields.h#L186-L196
[tonemapping]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/image_metadata.cc#L385-L412
[dec-xyb-dispatch]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/dec_xyb.cc#L19-L112
[xyb-inl]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/dec_xyb-inl.h#L32-L86
[ans-final]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/dec_ans.h#L219-L223
[common-limits]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/common.h#L37-L40
[tree-height]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/modular/encoding/dec_ma.cc#L57-L64
[tree-limit]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/dec_modular.cc#L226-L231
[spline-limit]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/splines.cc#L232-L235
[icc-limit]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/icc_codec.cc#L110-L114
[jpeg-data]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/jxl/jpeg/jpeg_data.h
[thread-runner]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/lib/threads/thread_parallel_runner_internal.h#L7-L25
[fmt-overview]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md
[fmt-metadata]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L47-L67
[fmt-colour]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L72-L104
[fmt-frames]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L106-L123
[fmt-groups]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L180-L222
[fmt-jbrd]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L251-L269
[fmt-container]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L25-L35
[fmt-conformance]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/format_overview.md#L37-L40
[fuzzing-doc]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/fuzzing.md#L11-L30
[playbook]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/vuln_playbook.md
[playbook-dassert]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/doc/vuln_playbook.md#L192-L220
[djxl-fuzzer]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/tools/djxl_fuzzer.cc#L588-L598
[streaming-oom]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/tools/streaming_fuzzer.cc#L284
[ossfuzz-build]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/tools/scripts/ossfuzz-build.sh#L20-L52
[fuzzer-list]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/tools/CMakeLists.txt#L348-L361
[conformance-yml]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/.github/workflows/conformance.yml#L186-L192
[conformance-py]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/tools/conformance/conformance.py#L32-L81
[changelog-012]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/CHANGELOG.md#L10-L36
[changelog-012-sec]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/CHANGELOG.md#L162-L170
[changelog-0112]: https://github.com/libjxl/libjxl/blob/e2948747fee8e99a614066eb058e67a0b8de995f/CHANGELOG.md#L172-L182
[cve-2021-22564]: https://nvd.nist.gov/vuln/detail/CVE-2021-22564
[cve-2024-11498]: https://nvd.nist.gov/vuln/detail/CVE-2024-11498
[cve-2025-12474]: https://nvd.nist.gov/vuln/detail/CVE-2025-12474
[jxl-rs]: https://github.com/libjxl/jxl-rs/blob/87620c4f566a7204865b3bcdc160033114a9a253/README.md
[jxl-oxide]: https://github.com/tirr-c/jxl-oxide/blob/c0cc4c7ea57c1207f38ff2970d94757470613be4/README.md
[bl-existing]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md#gaps-and-tensions
[p-jxl]: ./papers/entropy-codecs.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
