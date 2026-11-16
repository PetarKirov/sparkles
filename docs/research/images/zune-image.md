# zune-image (Rust)

A Rust workspace of small, separately published image codecs (`zune-jpeg`,
`zune-png`, `zune-inflate`, `zune-heic`, `zune-qoi`, `zune-ppm`, `zune-hdr`,
`zune-bmp`, `zune-psd`, `zune-farbfeld`, a JPEG XL encoder) over one shared core
crate, plus a planar `Image` type and an operations crate.

| Field         | Value                                                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | Rust ([root package][root-cargo] `rust-version = "1.88.0"`; crate requirements vary, including `1.89.0` for [`zune-heic`][heic-cargo])                       |
| License       | MIT OR Apache-2.0 OR Zlib ([`zune-image` manifest][image-cargo])                                                                                             |
| Repository    | [etemesi254/zune-image][repo]                                                                                                                                |
| Revision read | `2f9086b07cdf5a36621ce18f79d310f99b751de9` (October 24, 2026, branch `dev`; `zune-core` 0.5.3, `zune-jpeg` 0.5.16-rc3, `zune-png` 0.5.2, `zune-image` 0.5.0) |
| Documentation | [docs.rs/zune-image][docs-image] · [docs.rs/zune-jpeg][docs-jpeg] · [docs.rs/zune-core][docs-core] · the in-tree [`docs/`][docs-dir] notes                   |
| Category      | Generic libraries: codec family with a shared core and a planar image model                                                                                  |
| Tier          | A                                                                                                                                                            |
| Last reviewed | November 15, 2026                                                                                                                                            |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** come from a scratch crate built with
> `rustc 1.91.1` against the pinned sources of `zune-core`, `zune-jpeg`, `zune-png`,
> `zune-inflate` and `zune-image` (exported with `git archive`, outside this
> repository), run on the workspace's own `test-images` or generated inputs.
> Everything else was read in the source at the
> pinned revision. No performance number in this page was measured here; the ones
> quoted are the project's own published results and are labelled as such.
> Verification on November 14 repeated the options, reader, JPEG and corrupt-PNG
> probes, and added DNL, generated APNG, HDR, one-thread rayon and zero-length
> `Channel` probes under `/tmp/zune-verifier-20261114/` on x86_64 Linux. These
> probes were rebuilt from a fresh pinned export and repeated on November 15 under
> `/tmp/zune-verifier-20261115/`, with matching results. The scratch crate also
> depends on `zune-hdr`; these probes are not CI tests.
> An independent November 15 pass rebuilt and reran those probes under
> `/tmp/zune-independent-xAwTtpq4/` and added an operation-invariant probe
> (`cargo run --offline --bin invariants` in its `probe/` directory).

---

## Overview

### What it solves

`zune-image` exists because its author wanted decoders that are as fast as the C
reference libraries without their memory-safety record, and that can be used one at
a time. Formats have separately versioned crates, with codec-specific fuzz targets
and benchmarks for several of them; a program that needs only JPEG depends on
`zune-jpeg` and `zune-core`
and nothing else. The `zune-image` crate then ties the codecs into one `Image`
value, a codec registry, metadata (EXIF, ICC, transfer function, gain map), colour
and depth conversion and a `Pipeline`; `zune-imageprocs` adds about fifty
operations (blur, resize, CLAHE, median, bilateral, SSIM, premultiply, transpose
and others). Bindings exist for C (`zune-capi`), Python (`zune-python`) and
WebAssembly (`zune-wasm`), and `zune-bin` is a command-line tool.

The format coverage is uneven by design: what the project writes itself it
decodes (JPEG including progressive and arithmetic coding, PNG and APNG, HEIC with
its own HEVC intra decoder, BMP, QOI, PPM/PFM, Radiance HDR, PSD, farbfeld, and a
[`zune-gif` crate][gif-cargo] not integrated into `zune-image`). JPEG XL decoding,
WebP, JPEG 2000, JPEG encoding, colour
management and EXIF parsing are delegated to other crates through `zune-image`
features (`jxl-oxide`, `image-webp`, `hayro-jpeg2000`, `jpeg-encoder`, `moxcms`,
`kamadak-exif`) ([`zune-image/Cargo.toml`][image-cargo]).

### Design philosophy

The root README orders the goals explicitly ([`README.md`][readme-goals]):

> "The set of codecs aim to have the following features in order of priority:
>
> - Performance: Performance should be on par with or better than reference
>   libraries. For example, `zune-jpeg` should easily replace `libjpeg-turbo`
>   without any noticeable speed loss.
> - Safety: Minimal `unsafe` code, with the sole exception of SIMD intrinsics which
>   currently require `unsafe`.
> - Robustness: All decoders should be fuzz tested and found bugs fixed promptly."

and states the safety rule as a workspace policy ([`README.md`][readme-safety]):

> "This workspace **allows only 1 type of unsafe**: platform specific intrinsics
> (e.g. SIMD), and only where speed really matters. All other types are
> **explicitly forbidden**."

Three consequences shape the code:

1. **Performance comes first, then safety.** The defaults pick the fast,
   lenient path: SIMD on, checksums off, truncated files decoded best-effort
   (see [Hostile input][s-hostile]).
2. **Codecs are leaf crates with one shared vocabulary.** `zune-core` holds the
   byte reader and writer traits, `ColorSpace`, `BitDepth`, `DecoderOptions` and
   `EncoderOptions`. Most in-tree codecs depend only on this core; PNG also needs
   `zune-inflate`, and HEIC needs `zune-isobmff`. Most support `no_std`, but HDR
   currently requires `std` ([PNG manifest][png-cargo], [HEIC manifest][heic-cargo],
   [HDR][hdr-lib]).
3. **Processing wants planes.** `zune-image` stores each channel as its own
   buffer, because "this library aims to be a processing library"
   ([`deinterleave.rs`][deinterleave]); the image layer splits interleaved
   multi-component codec output into planes.

The safety rule is a goal more than an invariant. Several codec crates enforce it
with `#![forbid(unsafe_code)]` (`zune-ppm`, `zune-hdr`, `zune-jpegxl`,
`zune-isobmff`; `zune-jpeg` when built without its `x86` and `neon` features;
`zune-heic` uses `deny`), but the `zune-image` crate's `Channel` is a hand-written
untyped allocation and the parallel region helpers build slices from raw pointers
(see [Allocation and ownership][s-allocation]). Neither is a SIMD
intrinsic. HEIC also explicitly allows `unsafe` for its VideoToolbox FFI
([`lib.rs`][heic-unsafe]).

---

## How it works

### Workspace layout

| Crate             | Role                                                                                                               |
| ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| `zune-core`       | `ZByteReaderTrait`, `ZReader`, `ZCursor`, `ZByteWriterTrait`, `ColorSpace`, `BitDepth`, `DecoderOptions`, `log`    |
| `zune-inflate`    | DEFLATE/zlib/gzip decoder (one-shot and streaming); DEFLATE/zlib encoder                                           |
| `zune-jpeg`       | baseline, progressive and (feature `arith`) arithmetic JPEG; scanline, raw-plane and incremental APIs; AVX2 / NEON |
| `zune-png`        | PNG and APNG decoding over streaming inflate; experimental encoder; SSE4 / NEON filters                            |
| `zune-heic`       | HEIF container (via `zune-isobmff`) and its own HEVC intra decoder; SSE4.1 / NEON transforms; VideoToolbox         |
| `zune-qoi` …      | `zune-qoi`, `zune-ppm`, `zune-hdr`, `zune-bmp`, `zune-psd`, `zune-farbfeld`, `zune-gif` (0.5.0-rc0, not wired)     |
| `zune-jpegxl`     | a JPEG XL **encoder** only; decoding goes through `jxl-oxide`                                                      |
| `zune-image`      | `Image` / `Frame` / `Channel`, `ImageMetadata`, `DecoderTrait`, `EncoderTrait`, `OperationsTrait`, registry        |
| `zune-imageprocs` | the operations, each an `OperationsTrait` implementation                                                           |

### The byte reader

The in-tree decoders are generic over `T: ZByteReaderTrait`. The trait is the
minimum a decoder needs from its input ([`traits.rs`][core-traits]):

```rust
// crates/zune-core/src/bytestream/traits.rs (abridged)
pub trait ZByteReaderTrait {
    fn read_byte_no_error(&mut self) -> u8;
    fn read_exact_bytes(&mut self, buf: &mut [u8]) -> Result<(), ZByteIoError>;
    fn read_bytes(&mut self, buf: &mut [u8]) -> Result<usize, ZByteIoError>;
    fn peek_bytes(&mut self, buf: &mut [u8]) -> Result<usize, ZByteIoError>;
    fn peek_exact_bytes(&mut self, buf: &mut [u8]) -> Result<(), ZByteIoError>;
    fn z_seek(&mut self, from: ZSeekFrom) -> Result<u64, ZByteIoError>;
    fn is_eof(&mut self) -> Result<bool, ZByteIoError>;
    fn z_position(&mut self) -> Result<u64, ZByteIoError>;
    fn read_remaining(&mut self, sink: &mut alloc::vec::Vec<u8>) -> Result<usize, ZByteIoError>;
}
```

It has two implementations: `ZCursor<T: AsRef<[u8]>>` for memory (works under
`no_std`) and a blanket implementation for any `std::io::BufRead + Seek`. The trait
documentation records the cost of having only those two: without specialisation
the blanket implementation cannot be overridden, so "functions like
`read_byte_no_error` are slower than they should be for `Cursor`". `ZReader<T>`
wraps a source and adds endian-aware reads, `skip`, `rewind` and `peek_at`
([`reader.rs`][core-zreader]).

Two contracts carry the rest of the design. `read_byte_no_error` returns `0` past
the end instead of failing ([`no_std_readers.rs`][core-zcursor-byte]), which keeps
the entropy decoders' hot loops branch-light. An exact read that reports
`NotEnoughBytes` rewinds, making that error retryable
([`reader.rs`][core-recoverable]); this guarantee does not cover every I/O error:

> "**Retry contract:** on `NotEnoughBytes`, the stream position is already rewound
> to where the failed read began, so the caller can append more data and retry
> the same operation without repositioning."

**Verified:** over `ZCursor::new([7u8])`, `read_u8` returns `7` then `0`, and
`read_u8_err` then returns an error. A custom `BufRead + Seek` reader that yields
one byte and then `std::io::ErrorKind::UnexpectedEof` reports recoverable EOF but
remains at byte 1: the blanket implementation forwards that I/O error without
rewinding ([`std_readers.rs`][core-std-reader]).

### Options as the policy carrier

`DecoderOptions` is one `Copy` struct shared by the in-tree decoders
([`decoder.rs`][core-options-struct]): `max_width`, `max_height` (default `1 << 14`
each), `max_scans` (progressive JPEG, default 100), `deflate_limit` (default
`1 << 30`), `hevc_max_mdat_size` (default `1 << 24`), `num_threads`, `endianness`
and a private `DecoderFlags` bag of booleans (checksums, strictness, per-ISA SIMD
switches, PNG alpha and 16-to-8 stripping, animated decoding, VideoToolbox). Some
options' documentation names the decoders that respect them ("Respected by:
`jpeg`"). The `use_avx2` style getters fold the user's flag, the `unsafe` master
switch and CPU detection into one answer ([`decoder.rs`][core-use-sse41]):
`is_x86_feature_detected!` under `std`, the compile-time `target_feature` otherwise.

### The image model

`zune-image` stores an image as nested owned buffers
([`image.rs`][image-struct], [`frame.rs`][frame-struct]):

```rust
// crates/zune-image/src/image.rs and frame.rs
pub struct Image {
    pub(crate) background_color: Color,
    pub(crate) frames: Vec<Frame>,       // more than one: animated
    pub(crate) metadata: ImageMetadata,  // width, height, colorspace, depth, ...
}
pub struct Frame {
    pub(crate) channels: Vec<Channel>,   // one plane per component
    pub(crate) numerator: usize,         // frame duration as a fraction
    pub(crate) denominator: usize,
}
```

A `Channel` is an untyped, 64-byte-aligned byte allocation that remembers the
`TypeId` it was created for ([`channel.rs`][channel-struct]):

```rust
// crates/zune-image/src/channel.rs
pub struct Channel {
    ptr: *mut u8,
    length: usize,     // in bytes, not elements
    capacity: usize,
    type_id: TypeId,   // u8, u16 or f32 in practice
    size_of: usize,
    layout: Layout,
}
```

The module header calls it "analogous to C/C++ `void *` but comes with some safety
measures". `reinterpret_as::<T>()` and `reinterpret_as_mut::<T>()` check the stored
`TypeId` and the alignment, then hand out `&[T]` or `&mut [T]`
([`channel.rs`][channel-reinterpret]). The intended plane size is `width * height`
samples, with no stride, offset or sub-view. `confirm_invariants` checks the
channel count and non-alpha plane lengths, but passes `true` to `channels_ref`
and therefore skips alpha-plane lengths ([`traits.rs`][traits-invariants],
[`frame.rs`][frame-channels]). **Verified:** a no-op operation's `execute` accepts
a 2×2 RGBA image with plane lengths `[4, 4, 4, 1]`; shortening the red plane
instead produces a dimension-mismatch error.

### Operations

An operation implements `OperationsTrait` ([`traits.rs`][traits-ops]): a `name`,
`supported_colorspaces`, `supported_types` (a slice of `BitType`) and
`execute_impl`. The provided `execute` checks the colour space and bit type
against those lists, runs `confirm_invariants`, calls `execute_impl`, and checks
the invariants again. Inside, an operation matches the run-time bit type and
monomorphises its kernel; `Brighten` is typical ([`brighten.rs`][brighten]):

```rust
// crates/zune-imageprocs/src/brighten.rs (abridged)
match depth.bit_type() {
    BitType::U8 => image.par_process_regions::<u8, _>(true, |region| {
        for channel in region.channels.iter_mut() {
            brighten(channel, self.value, /* max */ 255);
        }
    })?,
    BitType::U16 => image.par_process_regions::<u16, _>(true, |region| { /* ... */ })?,
    BitType::F32 => image.par_process_regions::<f32, _>(true, |region| { /* ... */ })?,
    _ => return Err(ImageErrors::ImageOperationNotImplemented(self.name(), depth.bit_type())),
}
```

`par_process_regions` cuts each frame into horizontal bands of whole rows (about
four bands per rayon thread) and gives each band a `PlanarRegionMut` holding one
`&mut [T]` per channel ([`planar_regions.rs`][regions]). Because the planes are
separate and unpadded, a point operation is a loop over a plain slice, and
premultiplication is a `zip` of a colour plane with the alpha plane
([`premul_alpha.rs`][premul]).

### Codec entry points

Decoders follow a naming convention rather than a common trait: `new(source)`,
`new_with_options(source, options)`, `decode_headers()` and an allocating
`decode()`. The exact surface and sample type vary: JPEG and PNG expose byte-buffer
decoding, HDR's `decode_into` takes `&mut [f32]` ([HDR decoder][hdr-decode]),
farbfeld's takes `&mut [u16]` ([farbfeld decoder][farbfeld-decode]), and PPM's
`decode` returns a tagged `DecodingResult` ([PPM decoder][ppm-decode]).
`zune-image` adapts each into `DecoderTrait`
(`decode() -> Result<Image, ImageErrors>`, `read_headers`, `dimensions`), and a
process-wide `RwLock`ed registry maps an `ImageFormat` (including
`ImageFormat::Custom(&str)`) to a factory ([`codecs.rs`][codecs-registry]).

`zune-jpeg` goes further than the shared shape. It offers a pull-style scanline
session that writes converted rows into caller storage with a caller-chosen row
stride ([`lib.rs`][jpeg-scanline]); a raw session whose `layout()` returns one
`PlaneInfo` per component with sampling factors, logical size, `stride` and
`byte_size`, and `decode_into_planes_strided` for subsampled YCbCr planes
([`decoder.rs`][jpeg-planeinfo], [`decoder.rs`][jpeg-planes-strided]); an
incremental mode ([I/O and codec architecture][s-io]);
and cooperative cancellation through a `CancelCheck` trait with a default polling
interval of 1,024 MCUs (also checked at header boundaries)
([`cancel.rs`][jpeg-cancel]).

---

## Analysis

### 1. Pixel and memory model

Two models coexist. The codecs hand out **interleaved** samples, as byte buffers
or typed arrays depending on the codec. JPEG can select an output `ColorSpace`
(`RGB`, `RGBA`, `BGRA`, `Luma`, `YCbCr`, `CMYK`, …); PNG's byte output supports a
configurable 16-bit byte order. `zune-image` holds **planar** images
([concepts: interleaved, planar and semi-planar][c-planar]): `Image` → `Vec<Frame>`
→ `Vec<Channel>`, each channel a dense `width * height` array of `u8`, `u16` or `f32`.
Multi-component interleaved output must be deinterleaved (SSE2, SSE4.1 and AVX2
kernels in `deinterleave/`), and `Frame::flatten` re-interleaves for encoding.
The delegated JPEG XL adapter instead copies already-planar `f32` channels
([`jpeg_xl.rs`][jxl-planar]).

What the planar model leaves out is as instructive as what it has:

- **No [stride][c-stride] and no views.** A plane is exactly `width * height`
  samples; a crop is a copy ([`crop.rs`][crop]), and nothing borrows a window of a
  larger image. Contrast mir's `Slice` ([mir-algorithm][mir]) and Boost.GIL's views
  ([Boost.GIL][gil]).
- **No subsampled planes.** All channels share one size, so 4:2:0 YCbCr cannot be
  represented; `ColorSpace::YCbCr` means full-resolution planes. `zune-jpeg`'s own
  raw API, by contrast, returns subsampled planes with explicit strides and
  8-sample padding (`PlaneInfo`), so the codec layer has the richer model and the
  image layer discards it.
- **No N-D extent.** `ColorSpace::MultiBand(NonZeroU32)` allows any number of
  channels (the README's ["up to 4 billion bands"][readme-bands]), but an image
  stays 2-D. Many operations assume at most four (`MAX_CHANNELS = 4`); the region
  helpers assert at most 16 ([`planar_regions.rs`][regions]).
- **Depth is three storage cases.** `BitDepth` is `Eight`, `Sixteen`, `Float32` or
  `Unknown` ([`bit_depth.rs`][bitdepth]); there is no separate 10- or 12-bit tag,
  and sub-byte PNG expands to `u8`. `Float32` is documented as "range is 0.0 to 1.0",
  but the HDR decoder can return values above 1.0 ([`decoder.rs`][hdr-values]).

Planes are 64-byte aligned (`MIN_ALIGNMENT`, chosen "for AVX-512"
([`channel.rs`][channel-align])), so every kernel may assume an aligned start; with
no padding, row starts after the first need not retain that alignment.

### 2. Genericity mechanism

Genericity is **run-time tags plus monomorphised kernels**. The element type is not
a type parameter of `Image`: it is `BitDepth` in `ImageMetadata`, checked against
the `TypeId` in each `Channel`. Each operation `match`es on `BitType` and
instantiates a generic kernel for `u8`, `u16` and `f32`, bounded by
`ZuneInts<T>` (a `depth()` and `max_value()` per sample type) and `bytemuck::Pod`.
Capability is declared as data: `supported_colorspaces()` and `supported_types()`
return static slices, and `execute` refuses an image outside them, except that a
`MultiBand` image is let through with a warning and treated as colour without
alpha ([`traits.rs`][traits-ops]).

Codecs are generic over the reader (`JpegDecoder<T: ZByteReaderTrait>`), so concrete
in-memory and stream readers can compile separately without virtual I/O calls.
Encoders take `T: ZByteWriterTrait`. At the `zune-image` boundary everything is
erased again: the registry boxes its reader as `dyn BoxableReader`
and returns `Box<dyn DecoderTrait>` ([`codecs.rs`][codecs-registry]). `Pipeline`
instead stores `Box<dyn IntoImage>` and `Box<dyn OperationsTrait>`
([`pipelines.rs`][pipeline]), erasing the input and operation types.

Some declared capability is unused. `OperationsTrait::alpha_state()` documents that
it lets an operation choose the alpha state "the image will be converted into
before carrying out an operation" ([`traits.rs`][traits-alpha]), but the provided
`execute` does not read it; `operation_color_values()` (gamma versus linear) is
likewise declared by operations such as `Brighten` and never consulted by
`execute`. A search of the pinned Rust sources finds hook definitions and
overrides but no calls, including in the bindings; this does not establish how
external consumers use the public trait.

### 3. Colour and metadata

`zune-core` has the vocabulary: `ColorSpace` (component order and model, including
`HSL`, `HSV`, `YCCK` and `MultiBand`), `ColorCharacteristics` (sRGB, Rec.709,
gamma 2.2/2.8, linear, PQ, HLG and other CICP transfer characteristics, with an
`Unknown(u8)` fallback), `ColorPrimaries` and `RenderingIntent`
([`colorspace.rs`][core-colorspace], [`colorspace.rs`][core-trc]).
`ImageMetadata` carries the per-image state ([`metadata.rs`][metadata]):
`color_trc`, `default_gamma`, `is_linear`, `color_primaries` (from `cHRM`),
`color_standard` (the CICP primaries code), `max_cll`, `icc_chunk`, `exif`
(parsed by `kamadak-exif`), an `AlphaState` (premultiplied or not) and a
`GainMapImage` field. That field defaults to `None`; the JPEG adapter's Ultra HDR
path decodes and applies the gain map rather than assigning it to the field
([`jpeg.rs`][jpeg-gainmap]).

The mapping from files is partial. The PNG adapter keeps the CICP transfer function
and primaries but drops `matrix_coefficients` and `video_full_range_flag`, which
`zune-png`'s `CicpInfo` does read ([`png.rs`][png-glue-meta],
[`decoder.rs`][png-cicp]); see [concepts: CICP][c-cicp]. XMP and IPTC are exposed
by `zune-jpeg` (`xmp()`, `iptc()`) but not stored in `ImageMetadata`. No colour
management happens in the core: ICC profiles travel as bytes, and conversion
between profiles is the `cms` feature of `zune-imageprocs` over `moxcms`. Ultra
HDR handling (`uhdr` feature) comes from `gainforge`. The colour conversions in
`core_filters/colorspace/` work on code values; the HSL and HSV ones are
documented as matching Python's `colorsys`. Compare the typed colour model in
[color (TurkeyMan)][color] and [JuliaImages][julia].

### 4. I/O and codec architecture

The baseline is **pull over a seekable reader**: the decoder calls `read_*` and
`z_seek` on its source. Since 0.5 that source may be a file through `BufReader`
rather than a whole-file slice; the migration notes say the earlier design, which
"accepted byte slices that represent the whole data as contiguous", was "not
ideal ... increasing memory e.g on massive files" ([`lib.rs`][jpeg-scanline]).
Seeking is required, so a forward-only stream must be buffered.

On top of the pull reader, `zune-jpeg` builds **retry-based incremental decoding**
([concepts: incremental, progressive and suspendable decoding][c-incremental]),
documented in its crate root ([`lib.rs`][jpeg-incremental]):

> "`JpegDecoder` can be retried on the same decoder when the underlying reader can
> see more bytes later. Call `set_incremental_mode(true)` before scan decoding to
> make scan EOF recoverable in non-strict mode. Callers should treat
> `DecodeErrors::is_recoverable_eof()` as the signal to feed more input and retry;
> any other error is a hard decode failure."

Suspension is by checkpoint, not by coroutine: baseline Huffman scans record
"stream position, next MCU row/column, restart countdown, SOS parameters, DC
predictors, and bitstream state", and a retry resumes from the last checkpoint.
`decoded_scanlines()` reports the stable prefix of the caller's buffer; progressive
images instead report a replaceable full-frame preview built from committed scans.
**Verified:** on a 40% prefix (509,687 of 1,274,218 bytes) of the 7680×4320 baseline
`speed_bench.jpg`, incremental `decode_into` returned a recoverable EOF with
`decoded_scanlines() == Some(1864)` of 4320. The project's own Darwin benchmark
reports 47.58 ms with incremental mode against 84.38 ms without
([`benchmark-results.md`][bench-jpeg]). Its "first retry" benchmark measures
decoder setup, headers, output allocation, an initial decode at 80% visibility
and a retry with all input visible, using a different fixture,
`speed_bench_hv_subsampling.jpg` ([benchmark code][bench-retry]). These are combined
times, not isolated retry latency.

`zune-png` decodes IDAT through `zune_inflate::StreamingDecoder` row by row into
the output, so the compressed stream is never concatenated
([`streaming.rs`][png-streaming]); it has no comparable public retry contract.
The other decoders are whole-image. Only `zune-jpeg` has the scanline and
cancellation APIs; they are not part of `DecoderTrait`, so `zune-image` users get
whole-image decodes. The project's guide to adding a decoder is in
[`docs/AddingNewDecoder.md`][adding-decoder]. Wuffs is the comparison point for
suspendable decoding in this catalog (wave 3).

### 5. Hostile input and safety

The [hostile-input][c-hostile] defences are memory safety by language, explicit
limits, and fuzzing.

**Limits.** The in-tree decoders check declared `max_width` and `max_height` before
allocating pixel output (`zune-jpeg` [`headers.rs`][jpeg-limit], `zune-png`
[`readers.rs`][png-limit], and the BMP, GIF, HDR, HEIC, PPM, PSD, QOI and farbfeld
decoders). The limits are per axis, not per pixel or per byte: at the defaults a
legal header may request 16384 × 16384 × 4 samples, 1 GiB at 8 bits or 4 GiB as
`f32` in `zune-image`. **Verified:** with `set_max_width(100)` the 7680-wide JPEG
fails in `decode_headers` with "Image width 7680 greater than width limit 100".
Other budgets are format-specific: `max_scans` for progressive and multi-scan JPEG
([`mcu.rs`][jpeg-scans]), `deflate_limit` for text and ICC chunks, `hevc_max_mdat_size`
because the `mdat` box is read into memory. A JPEG with a `DNL` marker (height
unknown until entropy decoding) makes `decode()` allocate for `max_height` rows up
front ([`decoder.rs`][jpeg-dnl]). **Verified:** the bundled 8192-wide
[`dnl_image.jpg`][dnl-fixture]
returned 184,909,824 bytes, but retained capacities of 196,608,000 and 245,760,000
bytes with `max_height` set to 8000 and 10000 respectively. APNG has no
configurable frame-count budget; `zune-image`
composites each frame into a full-canvas copy ([`png.rs`][png-glue-frames]), so
retained pixel storage grows as frames × canvas. **Verified:** generated 1×1
8-bit greyscale APNGs with 2, 20 and 200 frames retained 2, 20 and 200 plane bytes
respectively, in addition to frame and channel overhead.

**Leniency is the default.** `DecoderOptions::default()` uses
`decoder_error_tolerance_mode()`, which returns `fast_options()`: checksums off,
non-conformance tolerated, SIMD flags enabled ([`decoder.rs`][core-options-fast],
[`decoder.rs`][core-options-default]). A truncated JPEG decodes "with best-effort
output" unless strict or incremental mode is set. **Verified:** the 40% prefix above
decodes with `decode()` to `Ok` with a full 99,532,800-byte buffer by default,
and fails with a recoverable EOF under `set_strict_mode(true)`.

**Documentation and behaviour disagree in three places.** All three were
**verified** against the pinned sources:

- `DecoderOptions::new_safe()` is documented as the variant that "disables
  platform specific intrinsics" ([`decoder.rs`][core-options-new]), but it returns
  `default()`, whose `use_unsafe()` and `use_avx2()` were `true` on this AVX2 host.
- `png_set_confirm_crc(true)` has no effect on decoding: a PNG with a corrupted
  `IHDR` CRC and one with a corrupted `IDAT` CRC both decode successfully with it
  set. `calc_crc` is called only from the encoder's chunk writers
  ([`crc.rs`][png-crc]).
- `inflate_set_confirm_adler(true)` does not reach image data: with a corrupted
  zlib Adler-32 the PNG still decodes. The check exists only in the one-shot
  `DeflateDecoder` ([`decoder.rs`][inflate-adler]), which `zune-png` uses for
  `iCCP` and `zTXt`; those paths use `DeflateOptions`' own default checksum policy
  without consulting this flag ([`readers.rs`][png-ancillary]). IDAT uses the
  streaming decoder.

`strict_mode()` ORs `jpg_error_on_non_conformance`, `png_confirm_crc` and
`inflate_confirm_adler` ([`decoder.rs`][core-strict]), so in PNG it means less than
it says. On the `unsafe` side, `set_use_unsafe(false)` disables option-controlled
dispatch such as JPEG's IDCT. It is not a workspace-wide SIMD prohibition: PNG's
NEON Sub/Average filters and HEIC's transform dispatch detect CPU features directly
([`de_filter.rs`][png-neon], [`idct.rs`][heic-dispatch]).
`zune-jpeg` without its `x86` and `neon`
features is `forbid(unsafe_code)` ([`lib.rs`][jpeg-forbid]). Counting matching
lines with `git grep unsafe 2f9086b07 -- crates/zune-jpeg/src | wc -l` gives 101;
the corresponding counts are 78 for `zune-image/src`, 55 for `zune-imageprocs/src`
and 25 for `zune-core/src`, and zero for `zune-inflate`, `zune-qoi` and `zune-bmp`.
These include comments and identifiers such as `use_unsafe`; they do not count
`unsafe` blocks or measure the size of the trusted code.

**Fuzzing** has per-format GitHub Actions triggered by pushes and pull requests to
`main` or `dev` that touch the corresponding crate, and by a daily schedule.
Budgets differ: JPEG uses 600 s per target nightly and 90 s per change, whereas BMP
uses 120 s on both ([`fuzz_jpeg.yml`][fuzz-jpeg-yml], [`fuzz_bmp.yml`][fuzz-bmp-yml]).
The JPEG targets cover the plain decode, the incremental API, the other entry
points, and a differential
IDCT target (see [Testing][s-testing]). The plain target uses
default options, so it fuzzes the lenient, SIMD-enabled configuration that users get
([`decode_buffer.rs`][fuzz-jpeg-buffer]). The [hostile-input papers][p-hostile]
put this kind of fuzzing in context.

### 6. Allocation and ownership

Codecs allocate their own scratch (`Vec`) and expose caller-buffer decoding
(`decode_into`) or return owned decoded samples (`decode`); the `alloc` crate is
required even under `no_std` ([`zune-core/src/lib.rs`][core-lib]). There is no allocator
parameter. Encoders write to any `ZByteWriterTrait`, which has a
`reserve_capacity` hint, so output can go to a file, a `Vec` or a fixed slice.

`zune-image` owns everything: `Image` owns `Frame`s owns `Channel`s, and `Clone`
deep-copies (threaded per channel for large frames when `threads` is enabled).
There are no borrowed images and no reference counting. `Channel` manages its
memory by hand with
`alloc_zeroed`, `realloc` and `dealloc` at 64-byte alignment
([`channel.rs`][channel-alloc]). Source inspection shows two contract problems:
`alloc` passes a caller-supplied size straight to `alloc_zeroed`, and a size of
zero is reachable (the [`new_with_bit_type(0, BitType::U8)` documentation example][channel-new]),
whereas the `GlobalAlloc` contract says "`layout` must have non-zero size.
Attempting to allocate for a zero-sized `layout` will result in undefined behavior"
([`GlobalAlloc`][rust-globalalloc]); and neither `alloc` nor `realloc` checks for a
null return. **Verified:** creating, reading and dropping the zero-length channel
returned normally with an empty slice on this system allocator. The allocation
still violates the documented contract. This is
`unsafe` outside SIMD, which the workspace policy forbids. The region helpers also
build `&mut [T]` from `ThreadSafePtr` raw pointers to give each rayon task a
disjoint band ([`planar_regions.rs`][regions]).

### 7. CPU parallelism and SIMD

**SIMD** is hand-written per ISA and chosen at run time: AVX2 IDCT and colour
conversion in `zune-jpeg` (`#[target_feature(enable = "avx2")]`,
[`avx2.rs`][jpeg-avx2]), NEON versions for AArch64, SSE4 and NEON PNG filters,
SSE2/SSE4.1/AVX2 deinterleaving and greyscale conversion in `zune-image`, SSE4.1 and
NEON transposition and x86-64/AArch64 Gaussian blur in `zune-imageprocs`, SSE4.1
and NEON HEVC transforms in `zune-heic`. JPEG's IDCT dispatch uses a function pointer
selected from the options ([`idct.rs`][jpeg-idct]); HEIC instead checks CPU
features at its transform entry points ([`idct.rs`][heic-dispatch]):

```rust
// crates/zune-jpeg/src/idct.rs (abridged)
pub fn choose_idct_func(options: &DecoderOptions) -> IDCTPtr {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    #[cfg(feature = "x86")]
    if options.use_avx2() {
        return |a, b, c| unsafe { avx2::idct_avx2(a, b, c) };
    }
    #[cfg(target_arch = "aarch64")]
    #[cfg(feature = "neon")]
    if options.use_neon() {
        return |a, b, c| unsafe { neon::idct_neon(a, b, c) };
    }
    return idct_int;
}
```

`portable_simd` (nightly `std::simd`) backs alternative paths (premultiply, PNG
filters, JPEG upsampling, HEVC IDCT) behind opt-in features; the README expects the
`unsafe` count to ["reduce when portable-simd becomes mainstream"][readme-portable].
Where no intrinsics exist the code relies on plain loops over planes, which planar storage
makes easy to auto-vectorise. The project's own Darwin run measures the JPEG
intrinsics against none at 54.81 ms versus 55.44 ms ([`benchmark-results.md`][bench-jpeg]),
a difference of about 1% on that machine; the README's "should easily replace
`libjpeg-turbo` without any noticeable speed loss" sits beside rows in the same
file where `mozjpeg` (a `libjpeg-turbo` derivative) is 1.1 to 1.34 times faster on
baseline JPEG and `zune-jpeg` is faster on two progressive cases. These numbers are
the project's, not measured here.

**Threads.** `zune-image` and `zune-imageprocs` depend on `rayon` unconditionally
(the image crate's `threads` feature also gates threaded frame cloning and
enables threading in `jxl-oxide` and `zune-jpegxl`;
[`zune-image/Cargo.toml`][image-cargo], [`zune-imageprocs/Cargo.toml`][imageprocs-cargo],
[`Frame::clone`][frame-clone]). Operations
parallelise over row bands
(above); `zune-heic` decodes grid tiles and wavefront CTU rows in parallel. The
codecs themselves are single-threaded except HEIC and JPEG XL.
**Verified:** a 2×2 `par_process_regions` probe succeeded with `RAYON_NUM_THREADS=1`.

### 8. GPU offload and interop

There is no GPU compute. [`crates/README.md`][crates-readme] lists `zune-opencl`
("Experimental OpenCL bindings"), but the directory does not exist at this revision.
Apart from that list, its only source-text reference is a commented-out dependency
in `zune-bin/Cargo.toml`. The one hardware path
is decode offload: `zune-heic` can hand HEVC to Apple VideoToolbox, on by default on
macOS (`hvec_use_apple_videotoolbox()`). Software decoding is a separately selected
path; hardware errors propagate without an automatic software retry
([`decoder.rs`][heic-hardware]). For GPU upload the useful artefacts are
`zune-jpeg`'s caller-stride scanline output and its strided raw YCbCr planes, which
could write directly into a mapped staging buffer; `zune-image`'s dense planes need
re-interleaving or per-plane upload. Not applicable beyond that, because the
project's goal is CPU decoding speed.

### 9. Temporal, animation and containers

An animated image is `Image` with several `Frame`s, each with a duration
`numerator / denominator` (seconds) ([`frame.rs`][frame-struct]); `is_animated()` is
"more than one frame" ([`image.rs`][image-animation]). APNG is decoded by `zune-png`
frame by frame (`more_frames`, `frame_info`) and composited by `ApngContext`
honouring `DisposeOp` and `BlendOp` ([`apng.rs`][apng-composition]); the `zune-image`
adapter stores each composited canvas as a full frame
([`png.rs`][png-glue-frames]). JPEG XL animation comes through
`jxl-oxide`, but the adapter reads and discards `render.duration()` and constructs
frames with the `Frame::new` default of `1 / 1`
([`jpeg_xl.rs`][jxl-planar], [`frame.rs`][frame-new]). GIF has a crate that
`zune-image` does not use. Loop count, frame
offsets and blend operators are not kept once frames are composited, so an
animation cannot be re-encoded losslessly as deltas. Containers are handled per
codec; `zune-isobmff` parses generic ISOBMFF box headers, with payload interpretation
left to the HEIF decoder ([`lib.rs`][isobmff-lib]). There is no video, and no
timestamp model beyond per-frame durations.

### 10. Testing and conformance

Four mechanisms, each tied to a source:

- **Hash regression corpus.** `tests/tests/{format}.json` lists files in
  `test-images/` with an xxhash of the decoded output; the harness decodes each and
  compares ([`tests/src/png.rs`][tests-png]). The guide tells contributors to take
  the hash from a failing run once they "have ensured the output is correct(matches other libraries)"
  ([`AddingATest.md`][adding-test]), so the oracle is a
  manual comparison frozen into a hash.
- **Differential tests against other decoders.** `zune-png`'s tests decode with the
  `png` crate and compare ([`test_basic.rs`][png-differential]); `zune-heic` runs a
  CI job that requires RGB
  byte-identical to `libheif` 1.17 and YCbCr byte-identical to `libde265`, pinning
  the runner image because "zune-heic's YCbCr -> RGB follows libheif 1.17 exactly"
  ([`heic_conformance.yml`][heic-conf]). PngSuite is vendored under
  `crates/zune-png/tests/png_suite/`.
- **SIMD against scalar.** The `fuzz_idct` target feeds random coefficient blocks
  to the dispatched IDCT and the scalar `idct_int` and asserts equal output, with
  each input coefficient clamped to −255…255
  ([`fuzz_idct.rs`][fuzz-idct]); unit tests in `idct.rs` do the same on fixed
  inputs.
- **Build-mode coverage.** A CI job builds `zune-core`, `zune-inflate`, `zune-jpeg`
  (with and without `arith`), `zune-png`, `zune-ppm` and `zune-qoi` for
  `x86_64-unknown-uefi` with `--no-default-features`; it also builds `zune-farbfeld`,
  `zune-psd`, `zune-bmp`, `zune-isobmff` and `zune-heic`
  ([`no_std.yml`][nostd-yml]).

Benchmarks use criterion against `mozjpeg`, `png`, `spng` (libspng),
`libdeflater`, `flate2`, `rapid-qoi`, `libvips`, `fast_image_resize`, `libblur`
and `image` ([`benchmarks/Cargo.toml`][bench-cargo]). The checksum findings in
[Hostile input][s-hostile] show what the suite does not cover:
the strict-mode flags have no test that a corrupt checksum is rejected.

---

## Lessons for Sparkles

- **Q9.** The workspace is evidence for **one crate per codec over a tiny shared
  core**: `zune-core` holds only the reader and writer traits, colour space, depth,
  options and errors. Most in-tree codecs depend on it alone; PNG adds
  `zune-inflate` and HEIC adds `zune-isobmff`. That lets a consumer take one codec
  without the image model. Most codecs support `no_std`, and codec-specific fuzz
  targets are separate. It also shows the price: the shared
  surface is a shape convention (`decode_headers`, `decode_into`), not a trait, and
  the image layer re-wraps each codec by hand. Where Sparkles' two PNG decoders and
  the draft `sparkles:image` stand is in [the existing-code baseline][bl-existing]
  (G1, decision 6).
- **Q1.** The planar, stride-free `Image` is the model to avoid for interchange and
  the model to keep in mind for point kernels. It forces deinterleaving of
  interleaved multi-component input and a copy on every crop, and it cannot hold
  4:2:0, while `zune-jpeg`'s raw
  `PlaneInfo` (sampling factors, `stride`, `byte_size`) shows the codec already has
  the richer description. A Sparkles view with per-plane strides and subsampling
  ([existing-code baseline][bl-existing], G2 and decision 2) can express both. In D
  that view would use `size_t` extents and strides, which `zune-image`'s `usize`
  matches.
- **Q2.** Run-time `BitDepth` plus a `match` that instantiates a kernel per sample
  type is the same erased-plus-typed split as the baseline's decision 2C. Two
  details transfer: capability as static data (`supported_types`,
  `supported_colorspaces`) checked by one provided `execute`, and invariant checks
  before and after operations. The latter need to cover every plane: zune's
  checks skip alpha lengths, as the probe above demonstrates. In D both map onto
  design by introspection
  (a kernel declares what it supports; the shell checks), with `static foreach`
  over the sample types replacing the hand-written `match`. The unused
  `alpha_state` hook shows that a capability nobody consults decays; Sparkles'
  rule to audit callers rather than definitions applies.
- **Q4.** `ZByteReaderTrait`'s rewind-on-`NotEnoughBytes` contract plus `zune-jpeg`'s
  scalar checkpoints is a working form of resumable decoding without coroutines:
  the decoder re-runs from a saved position with saved entropy state, and the
  caller owns the output buffer. The decoder still owns scratch and coefficient
  buffers, including persistent full-frame coefficients for progressive images
  ([`decoder.rs`][jpeg-coefficients]). That is close to the push
  parser with explicit state that the baseline recommends (decision 5A) and that
  `sparkles:event-horizon` could drive ([event-horizon baseline][bl-eh]). What does
  not transfer: the reader requires `Seek`, the fallback without checkpoints
  re-decodes from the start, and the facility is JPEG-only. A Sparkles design would
  make resumability part of every codec's contract, not a per-codec addition.
- **Q4.** The caller-stride scanline API and `CancelCheck` (a `Fn() -> bool` polled
  at a default interval of 1,024 MCUs) are separable features that fit Sparkles'
  conventions
  directly: a `@nogc nothrow` callback or a delegate-free template parameter, and an
  output range or caller slice for rows ([wired baseline][bl-wired] for the header
  side).
- **Q5.** `ImageMetadata` shows the minimum fields one project found it needed
  (transfer function, primaries, CICP primaries, MaxCLL, ICC bytes, EXIF, alpha
  state, an optional gain-map field) and also how a descriptor goes stale when an
  adapter drops
  fields: PNG's CICP matrix and range are read and discarded. A Sparkles descriptor
  ([existing-code baseline][bl-existing], G4, decision 3B) should be filled by the
  codec, not by glue, so nothing read is lost.
- **Q4, Q8.** Lenient defaults with strict opt-in match the baseline's decision 1B
  for PNG, but zune shows the failure mode: the strict flags exist, are documented,
  and do nothing for PNG CRC and IDAT Adler-32 (verified). An opt-in strict mode is
  only real with a test per flag that feeds a corrupt file and expects rejection.
  Under `Expected`-returning `@nogc nothrow` code that test is a two-line
  `checkRejects`-style unittest.
- **Q4.** Per-axis limits are not a resource budget: 16384 × 16384 passes, DNL JPEGs
  allocate for the maximum height, and APNG frames multiply the canvas. The
  [hostile-input papers][p-hostile] call resource safety an open problem; a Sparkles
  `probe` returning sizes the caller checks before allocating can budget the
  caller-owned output. Internal scratch and coefficients still need limits.
- **Q7, Q3.** JPEG's runtime ISA dispatch by function pointer chosen per decoder,
  with a scalar reference and a fuzz target asserting SIMD equals scalar, is the
  pattern to copy. Sparkles' dispatch is currently `package`-visible and repeated
  per use ([shaders and SIMD baseline][bl-shaders], G5); zune centralises the
  decision in `DecoderOptions`, which is also how a test forces the scalar path.
  The project's own numbers (intrinsics about 1% faster than none for JPEG on one
  Darwin machine) are a caution that the gain must be measured per kernel and per
  platform before it justifies `@trusted` code.
- **Q8.** Three oracle forms appear: frozen output hashes, byte-identity against a
  reference library supplied by a fixed OS release (Ubuntu 24.04's libheif and
  libde265, without exact package-version pins), and SIMD-against-
  scalar differential fuzzing. The second is the strongest and matches the
  `png_oracle.d` precedent; the first is the weakest, because the hash is only as
  correct as the manual check that produced it ([existing-code baseline][bl-existing],
  G11 and decision 9).
- **Build modes.** The `no_std` UEFI job is the Rust analogue of Sparkles' betterC
  and wasm extractions, and it covers the core, inflate and a selection of
  codec/container crates, not the image layer (which needs `std` and `rayon`).
  The same split would suit Sparkles:
  codecs `@nogc nothrow` and betterC-clean, the image layer free to use the runtime.
  `zune-hdr` requires `std`; its source comments cite floating-point `floor` and
  `exp2` as the reason ([`lib.rs`][hdr-lib]). D's math functions would need a
  separate betterC check.
- **Safety rule.** The policy restricting `unsafe` to SIMD did not hold for the
  container type, where a hand-rolled untyped allocation was written for
  flexibility. The Sparkles
  equivalents are `sparkles.base.buffer` (`UniqueBuffer`, `HeapBuffer`) holding a
  typed element and dip1000 `scope` slices handed to kernels, which give the same
  per-plane slices without a `@trusted` allocator in the image layer.

---

## Strengths

- Independent, small codec crates with one shared vocabulary; a consumer pays only
  for the formats it uses, and most in-tree codecs support `no_std`.
- `zune-jpeg` exposes whole-image decoding, caller-buffer decoding,
  caller-stride scanlines, strided subsampled planes, incremental retry with
  previews, and cooperative cancellation.
- JPEG's run-time SIMD dispatch, off switch and differential fuzz target keep its
  fast path checkable against the scalar one.
- Continuous per-format fuzzing in CI, daily and on every change, with a corpus in
  the repository.
- CI compares HEIC output byte-for-byte against `libheif` and `libde265`.
- Planar storage makes point and per-channel operations short, data-parallel loops
  and lets operations parallelise over row bands without coordination.
- The image model supports `u8`, `u16` and `f32`; operations declare which sample
  types they accept.

## Weaknesses

- Defaults favour speed over strictness, and the strict flags for PNG CRC and IDAT
  Adler-32 are no-ops at this revision; `new_safe()` leaves intrinsics enabled
  despite its doc comment.
- Limits are per axis; there is no combined decoded-pixel, output-byte or frame
  budget, and DNL JPEG and APNG paths allocate in proportion to the maximum or the
  frame count.
- The `Image` model has no strides, views or subsampled planes, so crops copy and
  the codecs' richer layouts are lost at the image boundary.
- Operation invariant checks skip alpha-plane lengths and accept a malformed RGBA
  image in the no-op probe above.
- `Channel` is unsafe, hand-managed untyped memory, contrary to the workspace's own
  rule, with a reachable zero-size allocation and no null check.
- Several formats the README presents as supported are delegated (JPEG XL decode,
  WebP, JPEG 2000, JPEG encode, colour management).
- Incremental decoding, scanlines and cancellation are JPEG-only and invisible
  through `DecoderTrait`.
- `rayon` is unconditional in `zune-image`; disabling `threads` does not remove its
  parallel region processing. The image layer requires `std`. This does not rule
  out using a one-thread rayon pool.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                     | Trade-off                                                                                         |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| One crate per codec over `zune-core`                             | Pay-per-format dependencies, `no_std` codecs, per-codec fuzzing and versions  | Shared behaviour is convention, not a trait; the image layer adapts each codec by hand            |
| Pull reader with `Seek`, rewind on `NotEnoughBytes`              | Files need not be in memory; short-input failures can be retried              | Forward-only streams must be buffered; resumption needs per-codec checkpoint state                |
| `read_byte_no_error` returns `0` past EOF                        | Branch-light entropy loops                                                    | Truncation becomes silent zeros unless the codec checks separately                                |
| Lenient, SIMD-on defaults; strictness opt-in                     | Decode as many real-world files as possible, as fast as possible              | PNG checksum flags are no-ops; the plain JPEG decode fuzz target uses the lenient mode            |
| Per-axis `max_width` / `max_height` checked before allocation    | Simple, uniform across decoders                                               | Not a memory budget; allocation size still depends on component count, depth, DNL and frame count |
| Planar `Image` of dense `width * height` planes                  | Simple per-channel kernels, easy band parallelism, depth-agnostic ops         | Deinterleave on decode, interleave on encode, copy on crop; no subsampling or views               |
| Untyped `Channel` with run-time `TypeId`                         | One image type for `u8`, `u16`, `f32`; type erasure for bindings and pipeline | Hand-written `unsafe` allocation; type errors become run-time `ChannelErrors`                     |
| Run-time `BitType` match, monomorphised kernels                  | Static speed per sample type without a type parameter on `Image`              | Every operation repeats the match; unsupported combinations are errors, not compile failures      |
| JPEG IDCT function-pointer dispatch chosen per decoder           | CPU detection at selection; options can force the scalar path                 | Indirect call per block; HEIC uses a different dispatch policy                                    |
| Delegate secondary formats and colour management to other crates | Ship coverage without writing every codec                                     | Safety, limits and fuzzing guarantees differ per delegated crate                                  |

---

## Sources

- [etemesi254/zune-image repository][repo], read at
  `2f9086b07cdf5a36621ce18f79d310f99b751de9`
- [`README.md` — goals in priority order][readme-goals]; [safety policy][readme-safety]
- [`crates/zune-core/src/bytestream/traits.rs` — `ZByteReaderTrait`][core-traits]
- [`crates/zune-core/src/bytestream/reader.rs` — retry contract][core-recoverable];
  [`ZReader`][core-zreader]
- [`crates/zune-core/src/bytestream/reader/no_std_readers.rs` — `ZCursor` byte read][core-zcursor-byte]
- [`crates/zune-core/src/options/decoder.rs` — `DecoderOptions`][core-options-struct];
  [`fast_options`][core-options-fast]; [`new_safe`][core-options-new];
  [`Default`][core-options-default]; [`use_sse41`][core-use-sse41]
- [`crates/zune-core/src/colorspace.rs` — `ColorSpace`][core-colorspace];
  [`ColorCharacteristics`][core-trc]; [`bit_depth.rs` — `BitDepth`][bitdepth];
  [`lib.rs`][core-lib]
- [`crates/zune-image/src/image.rs`][image-struct], [`frame.rs`][frame-struct],
  [`channel.rs` — struct][channel-struct], [alignment][channel-align],
  [allocation][channel-alloc], [reinterpretation][channel-reinterpret]
- [`crates/zune-image/src/traits.rs` — `OperationsTrait`][traits-ops];
  [`alpha_state`][traits-alpha]; [`confirm_invariants`][traits-invariants]
- [`crates/zune-image/src/planar_regions.rs`][regions], [`metadata.rs`][metadata],
  [`deinterleave.rs`][deinterleave], [`codecs.rs` — registry][codecs-registry],
  [`codecs/png.rs` — APNG frames][png-glue-frames], [metadata mapping][png-glue-meta],
  [`Cargo.toml`][image-cargo]
- [`crates/zune-imageprocs/src/brighten.rs`][brighten], [`premul_alpha.rs`][premul]
- [`crates/zune-jpeg/src/lib.rs` — scanline API][jpeg-scanline]; [incremental input][jpeg-incremental];
  [`forbid(unsafe_code)`][jpeg-forbid]
- [`crates/zune-jpeg/src/decoder.rs` — `PlaneInfo`][jpeg-planeinfo];
  [`decode_into_planes_strided`][jpeg-planes-strided]; [`decode` and DNL][jpeg-dnl]
- [`crates/zune-jpeg/src/headers.rs` — size limits][jpeg-limit], [`mcu.rs` — scan limit][jpeg-scans],
  [`cancel.rs`][jpeg-cancel], [`idct.rs` — dispatch][jpeg-idct], [`idct/avx2.rs`][jpeg-avx2]
- [`crates/zune-png/src/headers/readers.rs` — size limits][png-limit],
  [`streaming.rs`][png-streaming], [`crc.rs`][png-crc], [`apng.rs`][apng],
  [`decoder.rs` — `CicpInfo`][png-cicp]
- [`crates/zune-inflate/src/decoder.rs` — Adler-32 check][inflate-adler]
- [`crates/zune-heic/src/lib.rs`][heic-lib]
- [`.github/workflows/fuzz_jpeg.yml`][fuzz-jpeg-yml],
  [`crates/zune-jpeg/fuzz/fuzz_targets/decode_buffer.rs`][fuzz-jpeg-buffer],
  [`fuzz_idct.rs`][fuzz-idct], [`.github/workflows/heic_conformance.yml`][heic-conf],
  [`.github/workflows/no_std.yml`][nostd-yml]
- [`docs/AddingATest.md`][adding-test], [`tests/src/png.rs`][tests-png],
  [`benchmarks/Cargo.toml`][bench-cargo], [`benchmarks/benchmark-results.md`][bench-jpeg]
- [Rust `GlobalAlloc` documentation][rust-globalalloc]
- [docs.rs: zune-image][docs-image] · [zune-jpeg][docs-jpeg] · [zune-core][docs-core]
- Related in this catalog: [Concepts][concepts] · [mir-algorithm][mir] ·
  [Boost.GIL][gil] · [VIGRA][vigra] · [Halide][halide] · [JuliaImages][julia] ·
  [color][color] · [dcv][dcv] · [umbrella][umbrella]

<!-- References -->

[repo]: https://github.com/etemesi254/zune-image/tree/2f9086b07cdf5a36621ce18f79d310f99b751de9
[docs-image]: https://docs.rs/zune-image/latest/zune_image/
[docs-jpeg]: https://docs.rs/zune-jpeg/latest/zune_jpeg/
[docs-core]: https://docs.rs/zune-core/latest/zune_core/
[docs-dir]: https://github.com/etemesi254/zune-image/tree/2f9086b07cdf5a36621ce18f79d310f99b751de9/docs
[readme-goals]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/README.md#L6-L13
[readme-safety]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/README.md#L101-L106
[core-traits]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/bytestream/traits.rs#L16-L88
[core-recoverable]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/bytestream/reader.rs#L121-L137
[core-zreader]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/bytestream/reader.rs#L139-L282
[core-zcursor-byte]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/bytestream/reader/no_std_readers.rs#L54-L60
[core-std-reader]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/bytestream/reader/std_readers.rs#L16-L40
[core-options-struct]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/options/decoder.rs#L76-L172
[core-options-fast]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/options/decoder.rs#L15-L45
[core-options-new]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/options/decoder.rs#L174-L195
[core-options-default]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/options/decoder.rs#L689-L731
[core-use-sse41]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/options/decoder.rs#L532-L560
[core-colorspace]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/colorspace.rs#L11-L58
[core-trc]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/colorspace.rs#L123-L195
[core-lib]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/lib.rs#L7-L48
[bitdepth]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/bit_depth.rs#L13-L48
[image-struct]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/image.rs#L30-L47
[frame-struct]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/frame.rs#L22-L37
[channel-struct]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/channel.rs#L9-L104
[channel-align]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/channel.rs#L30-L41
[channel-alloc]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/channel.rs#L219-L261
[channel-reinterpret]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/channel.rs#L470-L533
[traits-ops]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/traits.rs#L110-L204
[traits-alpha]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/traits.rs#L205-L216
[traits-invariants]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/traits.rs#L249-L282
[regions]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/planar_regions.rs#L9-L124
[metadata]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/metadata.rs#L21-L92
[deinterleave]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/deinterleave.rs#L9-L19
[codecs-registry]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/codecs.rs#L61-L149
[png-glue-frames]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/codecs/png.rs#L45-L81
[png-glue-meta]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/codecs/png.rs#L155-L200
[image-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/Cargo.toml#L1-L90
[brighten]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-imageprocs/src/brighten.rs#L83-L119
[premul]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-imageprocs/src/premul_alpha.rs#L260-L270
[jpeg-scanline]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/lib.rs#L40-L200
[jpeg-incremental]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/lib.rs#L73-L137
[jpeg-forbid]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/lib.rs#L281-L313
[jpeg-planeinfo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/decoder.rs#L69-L88
[jpeg-planes-strided]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/decoder.rs#L1598-L1630
[jpeg-dnl]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/decoder.rs#L2092-L2119
[jpeg-limit]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/headers.rs#L386-L392
[jpeg-scans]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/mcu.rs#L287-L292
[jpeg-cancel]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/cancel.rs#L18-L56
[jpeg-idct]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/idct.rs#L51-L77
[jpeg-avx2]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/idct/avx2.rs#L79-L88
[png-limit]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/headers/readers.rs#L38-L52
[png-streaming]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/streaming.rs#L56-L165
[png-crc]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/crc.rs#L47-L52
[apng]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/apng.rs#L17-L72
[png-cicp]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/decoder.rs#L256-L262
[inflate-adler]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-inflate/src/decoder.rs#L318-L339
[heic-lib]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-heic/src/lib.rs#L1-L35
[fuzz-jpeg-yml]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/.github/workflows/fuzz_jpeg.yml#L1-L50
[fuzz-jpeg-buffer]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/fuzz/fuzz_targets/decode_buffer.rs
[fuzz-idct]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/fuzz/fuzz_targets/fuzz_idct.rs
[heic-conf]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/.github/workflows/heic_conformance.yml#L1-L100
[nostd-yml]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/.github/workflows/no_std.yml#L25-L38
[adding-test]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/docs/AddingATest.md
[tests-png]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/tests/src/png.rs
[bench-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/benchmarks/Cargo.toml
[bench-jpeg]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/benchmarks/benchmark-results.md#L82-L111
[rust-globalalloc]: https://doc.rust-lang.org/std/alloc/trait.GlobalAlloc.html
[root-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/Cargo.toml#L1-L6
[png-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/Cargo.toml#L24-L26
[heic-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-heic/Cargo.toml#L1-L28
[hdr-lib]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-hdr/src/lib.rs#L33-L35
[hdr-values]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-hdr/src/decoder.rs#L460-L509
[hdr-decode]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-hdr/src/decoder.rs#L248-L295
[farbfeld-decode]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-farbfeld/src/decoder.rs#L120-L155
[ppm-decode]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-ppm/src/decoder.rs#L529-L562
[heic-unsafe]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-heic/src/lib.rs#L233-L270
[jxl-planar]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/codecs/jpeg_xl.rs#L180-L211
[jpeg-gainmap]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/codecs/jpeg.rs#L457-L544
[jpeg-coefficients]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/src/decoder.rs#L399-L423
[png-neon]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/filters/de_filter.rs#L10-L137
[heic-dispatch]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-heic/src/hevc_decoder/idct.rs#L271-L344
[isobmff-lib]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-isobmff/src/lib.rs#L1-L12
[adding-decoder]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/docs/AddingNewDecoder.md
[frame-clone]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/frame.rs#L48-L108
[frame-new]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/frame.rs#L128-L136
[fuzz-bmp-yml]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/.github/workflows/fuzz_bmp.yml
[crates-readme]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/README.md#L16
[dnl-fixture]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-jpeg/tests/images/dnl_image.jpg
[readme-bands]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/README.md#L43
[readme-portable]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/README.md#L69-L70
[bench-retry]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/benchmarks/benches/decode_jpeg.rs#L348-L405
[heic-hardware]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-heic/src/decoder.rs#L735-L810
[image-animation]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/image.rs#L91-L100
[apng-composition]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/apng.rs#L314-L487
[frame-channels]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/frame.rs#L272-L279
[channel-new]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/channel.rs#L273-L329
[core-strict]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-core/src/options/decoder.rs#L221-L228
[png-ancillary]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/src/headers/readers.rs#L311-L453
[pipeline]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-image/src/pipelines.rs#L63-L104
[crop]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-imageprocs/src/crop.rs#L151-L214
[imageprocs-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-imageprocs/Cargo.toml#L16-L25
[gif-cargo]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-gif/Cargo.toml#L1-L15
[png-differential]: https://github.com/etemesi254/zune-image/blob/2f9086b07cdf5a36621ce18f79d310f99b751de9/crates/zune-png/tests/test_basic.rs#L20-L46
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-stride]: ./concepts.md#stride
[c-cicp]: ./concepts.md#cicp
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[concepts]: ./concepts.md
[mir]: ./mir-algorithm/index.md
[gil]: ./boost-gil.md
[vigra]: ./vigra.md
[halide]: ./halide.md
[julia]: ./juliaimages.md
[color]: ./color.md
[dcv]: ./dcv.md
[umbrella]: ./index.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md
[p-hostile]: ./papers/hostile-input-safety.md
[s-hostile]: #_5-hostile-input-and-safety
[s-allocation]: #_6-allocation-and-ownership
[s-io]: #_4-i-o-and-codec-architecture
[s-testing]: #_10-testing-and-conformance
