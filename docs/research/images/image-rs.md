# image-rs (Rust)

The Rust imaging crate: a statically typed `ImageBuffer` over an open `Pixel` trait, a closed run-time enum (`DynamicImage`) for files whose format is known only when opened, and one decoder trait shared by the format implementations; it illustrates trait-based genericity with a deliberately small built-in colour vocabulary.

| Field         | Value                                                                                                                                                 |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Rust 2021, MSRV 1.88.0 ([`Cargo.toml`][cargo-pkg])                                                                                                    |
| License       | MIT OR Apache-2.0 ([`LICENSE-MIT`][license-mit], [`LICENSE-APACHE`][license-apache])                                                                  |
| Repository    | [image-rs/image][repo]                                                                                                                                |
| Revision read | `075e65d618a323e5cb48c1d8710a2eca25d690c6` (`main`, September 15, 2026; manifest version `0.25.9`, `publish = false`, work toward 1.0)                |
| Documentation | [docs.rs/image][docs] (0.25.9 release) · crate docs in [`src/lib.rs`][lib-overview] · [`CHANGES.md`][changes]                                         |
| Category      | Generic libraries: compile-time pixel types behind traits, run-time enum over a closed buffer set, format crates behind one object-safe decoder trait |
| Tier          | A                                                                                                                                                     |
| Last reviewed | November 15, 2026                                                                                                                                     |

> [!NOTE]
> The pinned revision is `main`, not a release. Its manifest still says `0.25.9` but the
> comment above it reads "we are already working on 1.0.0 in git" ([`Cargo.toml`][cargo-pkg]),
> and the decoder protocol, `ImageReader` and `DynamicImage` differ from the 0.25.9 crate on
> crates.io. Where this page describes the 0.25.9 release it says so and cites versioned docs.rs pages.
> The original clone is shallow; the 0.24.5 manifest was fetched separately for verification. No Rust toolchain was available; nothing in
> image-rs was compiled or run. Claims marked **verified** come from a D probe compiled with LDC 1.43.0
> under `-betterC -preview=dip1000 -preview=in` in `/tmp`, independently rerun on November 15, 2026.
> The channel-to-pixel cast requires trimming to a whole-pixel prefix first. No performance number in this page was
> measured.

---

## Overview

### What it solves

A Rust program that wants to open "an image" needs two things that are separable: a decoder per
container format, and a typed buffer to put pixels in. image-rs provides both and lets either be used
alone. The crate documentation states the scope in its first lines ([`src/lib.rs`][lib-overview]):

> _"There are two core problems for which this library provides solutions: a unified interface for
> image encodings and simple generic buffers for their content. It's possible to use either feature
> without the other. The focus is on a small and stable set of common operations that can be
> supplemented by other specialized crates. The library also prefers safe solutions with few
> dependencies."_

The buffer side is `ImageBuffer<P, Container>`, generic over a `Pixel` type and any container that
dereferences to a slice of subpixels. The format side is the `ImageDecoder` and `ImageEncoder` traits,
with fourteen formats behind cargo features (AVIF, BMP, OpenEXR, Farbfeld, GIF, HDR, ICO, JPEG, PNG,
PNM, QOI, TGA, TIFF, WebP) ([`src/lib.rs`][lib-codecs]). Most decoders are separate crates (`png`,
`zune-jpeg`, `image-webp`, `gif`, `tiff`, `exr`, `qoi`, `dav1d`); BMP, ICO, HDR, PNM, TGA and Farbfeld
are implemented in-tree ([`Cargo.toml`][cargo-deps]).

### Design philosophy

Three commitments recur in the source.

1. **Stability over exposure.** The `codecs` module explains why format-specific options are wrapped,
   not re-exported: re-exporting "would run counter to this goal as it linked _all_ major version bumps
   between them and `image`", so a wrapper needs a standard that requires it, two implementations that
   agree, or a measured benefit ([`src/lib.rs`][lib-codecs]).
2. **An opinionated, closed pixel set.** `DynamicImage` does not try to cover every layout: "this type
   provides an opinionated selection with normalized channel order which can store common pixel values
   without loss" ([`dynimage.rs`][dyn-doc]). `Primitive` and `PixelWithColorType` are sealed;
   `Pixel` itself remains open ([`traits.rs`][traits-pixel], [`traits.rs`][traits-sealed],
   [`primitive_sealed.rs`][prim-sealed]).
3. **Honesty about the gaps.** `CHANGES.md` opens with a "Known issues" list whose two entries are
   _"Many decoders will panic on malicious input."_ and _"The color space information of pixels is
   not clearly communicated."_ ([`CHANGES.md`][changes-known]). Both shape sections 3 and 5 below.

## How it works

### Primitives and pixels

A channel value is a `Primitive`: a `Copy + NumCast + Num + PartialOrd + Bounded` type, sealed by the
crate-private `PrimitiveSealed`, with two associated constants that give the colour meaning of the
range ([`traits.rs`][traits-primitive]):

```rust
pub trait Primitive:
    Copy + NumCast + Num + PartialOrd<Self> + Clone + Bounded + PrimitiveSealed
{
    const DEFAULT_MAX_VALUE: Self;   // 1.0 for floats, MAX for integers
    const DEFAULT_MIN_VALUE: Self;
}
```

`Pixel` is the per-pixel trait. Its subpixel type is an associated type; its channel count, colour
model string and alpha presence are associated constants ([`traits.rs`][traits-pixel]):

```rust
pub trait Pixel: Copy + Clone {
    type Subpixel: Primitive;
    const CHANNEL_COUNT: u8;
    const COLOR_MODEL: &'static str;   // "RGB", "RGBA", "Y", "YA"
    const HAS_ALPHA: bool = false;
    fn channels(&self) -> &[Self::Subpixel];
    fn pixels_from_channels(slice: &[Self::Subpixel]) -> &[Self];
    fn to_rgba(&self) -> Rgba<Self::Subpixel>;
    fn map<F>(&self, f: F) -> Self where F: FnMut(Self::Subpixel) -> Self::Subpixel { /* … */ }
    // … apply, map_with_alpha, map2, invert, blend
}
```

The four concrete pixels are generated by one macro, `define_colors!`, as `#[repr(transparent)]`
newtypes over a fixed array: `Rgb<T>([T; 3])`, `Rgba<T>([T; 4])`, `Luma<T>([T; 1])` and
`LumaA<T>([T; 2])` ([`color.rs`][color-define], [`color.rs`][color-instances]). The slice
reinterpretations (`from_slice`, `pixels_from_channels`, `pixels_as_channels`) are `unsafe` pointer
casts inside the macro, justified by the transparent representation ([`color.rs`][color-unsafe]).
0.25.0 recorded the change: "Pixel types are now `repr(transparent)` rather than `repr(C)`"
([`CHANGES.md`][changes-0250]).

`PixelWithColorType` ties a pixel to the run-time `ExtendedColorType` with a `const COLOR_TYPE`, and
is implemented for exactly the twelve combinations of {`Rgb`, `Rgba`, `Luma`, `LumaA`} × {`u8`, `u16`,
`f32`}; its sealed supertrait carries a `TransformableSubpixel` used to select colour transforms
([`traits.rs`][traits-pwct]). A comment there records the cost of doing this with traits: written
directly, the dispatch fails because "the type checker is mightily confused", and a helper function
exists because it "essentially introduces that missing unknown which can unify the available impl
set" ([`traits.rs`][traits-unify]).

### `ImageBuffer` and its views

`ImageBuffer` stores dimensions as `u32`, a phantom pixel type, a colour space and the container
([`buffer.rs`][buf-struct]):

```rust
pub struct ImageBuffer<P: Pixel, Container> {
    width: u32,
    height: u32,
    _phantom: PhantomData<P>,
    color: CicpRgb,
    data: Container,
}
```

`from_raw` returns `None` unless `CHANNEL_COUNT * width * height` computed with `checked_mul` fits the
container ([`buffer.rs`][buf-fromraw], [`buffer.rs`][buf-fits]); that single check is what makes the
unchecked index arithmetic in `pixel_indices_unchecked` sound, as its comment says: "If in bounds,
this can't overflow as we have tested that at construction!" ([`buffer.rs`][buf-indices]). The
layout is always row-major and packed; there is no row stride.

Two traits abstract over images: `GenericImageView` (dimensions, `get_pixel`, `view`, `pixels`) and
`GenericImage` (`put_pixel`, `copy_from`, `sub_image`) ([`generic_image.rs`][gi-view],
[`generic_image.rs`][gi-image], [`sub_image`][gi-subimage]). `GenericImageView` is object safe for the per-pixel calls, and its
doc example coerces a buffer to `&dyn GenericImageView<Pixel = Rgb<u8>>`. Its fast path is an
optional method, `to_pixel_view`, which "by default return `None`" and otherwise hands back a
strided descriptor so that `copy_from` can skip per-pixel calls ([`generic_image.rs`][gi-fastpath],
[`generic_image.rs`][gi-copyfrom]).

`SubImage<I>` is an offset-and-extent view over any `I` that dereferences to an image. It is
deliberately _not_ a `GenericImage` itself but dereferences to a nominally public inner type that is
([`sub_image.rs`][sub-doc]): "For reasons relating to coherence, this is not itself a `GenericImage`
or a `GenericImageView`. In short, we want to reserve the ability of adding traits implemented for
_all_ generic images but in a different manner for `SubImage`. This may be required to ensure that
stacking sub-images comes at no double indirect cost." An inherent `view` method on `SubImage`
re-bases nested views onto the underlying image instead of wrapping them again
([`sub_image.rs`][sub-view]).

`FlatSamples<Buffer>` is the strided, FFI-facing layout: a `repr(C)` `SampleLayout` of channel, width
and height strides counted in samples, not bytes ([`flat.rs`][flat-samples], [`flat.rs`][flat-layout]).
It can describe planar data, column-major data and broadcasts (zero strides). `NormalForm`
classifies layouts as `Unaliased`, `PixelPacked`, `ImagePacked`, `RowMajorPacked` or
`ColumnMajorPacked` ([`flat.rs`][flat-normal]). `as_view` checks channel count and buffer bounds;
it does not require one of those normal forms ([`flat.rs`][flat-asview]).

### `DynamicImage`

`DynamicImage` is a `#[non_exhaustive]` enum with one variant per supported buffer: twelve at the
pinned revision (`ImageLuma8` through `ImageRgba32F`) ([`dynimage.rs`][dyn-enum]). The unreleased
"Version Next" adds `Luma32F` and `LumaA32F`, so 0.25.9 has ten ([`CHANGES.md`][changes-next]).
Operations dispatch through a `dynamic_map!` macro that expands to a twelve-arm `match`
([`dynimage.rs`][dyn-map]); `imageops` includes functions generic over `GenericImageView`, and
`DynamicImage` re-exposes them.

### The decoder protocol

At the pinned revision `ImageDecoder` is a stateful, object-safe protocol whose call order is written
as a grammar in its documentation ([`decoder.rs`][dec-protocol]):

```text
decoding sequence = configure, { decode image }, "finish", { metadata }
decode image = "prepare_image", { metadata | "prepare_image" }, "read_image"
configure = "set_limits"
metadata = "xmp_metadata" | "icc_profile" | "exif_metadata" | "iptc_metadata"
```

`prepare_image` reads the header and returns a `DecoderPreparedImage` holding an `ImageLayout`
(width, height, `ColorType`) and is idempotent ([`decoder.rs`][dec-prepare]). `read_image(&mut self, buf: &mut [u8])`
fills a caller buffer of exactly `total_bytes()` in native endian and returns
`DecodedImageAttributes` (frame offset, delay, orientation, original colour type)
([`decoder.rs`][dec-read], [`decoder.rs`][dec-attrs]). Metadata getters return owned `Vec<u8>` blobs,
and `FormatAttributes` tells the caller whether each kind lives `InHeader` or `PerImage`
([`decoder.rs`][dec-hint]). Multi-image files repeat `prepare_image`/`read_image` until
`more_images` returns `SequenceControl::None` or a `NoMoreData` error.

The 0.25.9 release has a different, one-shot trait: required methods `dimensions`, `color_type`,
`read_image(self, buf: &mut [u8])` consuming the decoder, and `read_image_boxed(self: Box<Self>, …)`
for object safety ([docs.rs `ImageDecoder` 0.25.9][docs-decoder-025]). 0.25.0 itself had made the
trait object safe and "Removed incremental decoding support" ([`CHANGES.md`][changes-0250]); the
`ImageDecoderRect` trait is gone in "Version Next" ([`CHANGES.md`][changes-next]).

### `ImageReaderOptions`, `ImageReader` and the decoding order

In 0.25.9 the builder is `ImageReader<R: Read + Seek>` with `new`, `with_guessed_format`, `limits` and
a consuming `decode` ([docs.rs `ImageReader` 0.25.9][docs-reader-025]). At the pinned revision that
builder is renamed `ImageReaderOptions`, and `ImageReader` is a new type wrapping a
`Box<dyn ImageDecoder>` with its own limits and metadata cache ([`image_reader_type.rs`][rdr-struct]).
The order of a typical `ImageReader::open(path)?.decode()` is:

1. **Format from the path.** `open_impl` opens the file and records the extension without reading its contents
   ([`image_reader_type.rs`][rdr-open]).
2. **Optional format from content.** `ImageReader::open` skips sniffing; use
   `ImageReaderOptions::open(...).with_guessed_format()` to request it. `ImageReader::new` always sniffs
   ([`image_reader_type.rs`][rdr-entrypoints]): read at
   most 16 bytes, seek back, try registered detection hooks first, then the built-in `MAGIC_BYTES`
   table of 21 masked signatures ([`image_reader_type.rs`][rdr-guess], [`free_functions.rs`][magic]).
   Built-in sniffing does not detect TGA; choose it by extension or explicit format.
3. **Decoder construction.** `make_decoder` checks extension hooks, then matches the format to a boxed
   decoder behind its cargo feature, passing `SpecCompliance` (default `Lenient`) to JPEG, BMP, ICO and
   HDR ([`image_reader_type.rs`][rdr-make], [`image_reader_type.rs`][rdr-spec]).
4. **Limits.** `ImageReader::set_limits` halves `max_alloc`, keeps one half for itself and gives the
   other to the decoder ([`image_reader_type.rs`][rdr-limits]).
5. **Header, then budget, then pixels.** `decode_to_dynimage` calls `prepare_image`, buffers header
   metadata, checks dimensions, `reserve`s `total_bytes()` from its own half, then allocates a zeroed
   `Vec` and calls `read_image` ([`image_reader_type.rs`][rdr-decode], [`free_functions.rs`][dec-to-vec]).
6. **Colour and orientation.** `decoder_to_image` stamps sRGB on the result unconditionally
   ([`dynimage.rs`][dyn-srgb]); `apply_metdata` can replace it with a `Cicp` extracted from an ICC
   profile through moxcms, and applies EXIF orientation by default
   ([`image_reader_type.rs`][rdr-meta]).

`decode_into(&mut [u8])` is the caller-storage path: it checks the buffer length against the layout and
calls `read_image` without reserving from the reader's budget ([`image_reader_type.rs`][rdr-into]).

### Limits

`Limits` has three fields ([`limits.rs`][limits]):

```rust
pub struct Limits {
    pub max_image_width: Option<u32>,   // strict
    pub max_image_height: Option<u32>,  // strict
    pub max_alloc: Option<u64>,         // non-strict; Default is 512 MiB
}
```

A decoder that cannot uphold a strict limit must fail with `error::LimitErrorKind::Unsupported`;
non-strict limits are best effort, though "it is still considered a bug if a non-strict limit is
exceeded". `reserve` and
`free` turn `max_alloc` into a running budget ([`limits.rs`][limits-reserve]). The defaults differ by
entry point: `Limits::default()` caps allocation at 512 MiB, and both builders start from it, but
direct decoder defaults vary. JPEG, PNG and GIF use `Limits::no_limits()`, while AVIF uses
`Limits::default()` ([JPEG][jpeg-new], [PNG][png-default], [GIF][gif-default], [AVIF][avif-default]).
JPEG's comment overgeneralises: "Limits are disabled by default in the constructor for all decoders"
([`jpeg/decoder.rs`][jpeg-new]). The trait itself
warns "By default, _no_ limits are defined" ([`decoder.rs`][dec-limits]).

### Colour space and CICP

Every `ImageBuffer` carries a `CicpRgb` (primaries, transfer, derived luminance), defaulting to
`Cicp::SRGB`; setters reinterpret without converting, and `set_color_space` rejects a CICP with a
non-identity matrix or narrow range ([`buffer.rs`][buf-cicp]). `Cicp` is the four-field H.273 tuple
([`cicp.rs`][cicp-struct]). Conversions go through `CicpTransform::new(from, into)`, which delegates to
a crate-private `CmsProvider` implemented by moxcms ([`metadata.rs`][cms-provider],
[`cicp.rs`][cicp-transform], [`moxcms.rs`][moxcms]). The transform refuses any space that fails
`qualify_stability`: full range, identity or chromaticity-derived matrix, and supported primaries and
transfer ([`cicp.rs`][cicp-stable]). SMPTE ST 2084 (PQ) is excluded from the supported transfers,
with a comment citing a patent that does not disclose the method ([`cicp.rs`][cicp-transfer]). This
work landed in 0.25.7, whose notes add: "The support for transforming is limited for now and will be
gradually expanded." ([`CHANGES.md`][changes-0257]).

## Analysis

### 1. Pixel and memory model

One layout: interleaved, row-major, packed, `u32` extents, element-typed container
([`buffer.rs`][buf-struct]). There are no row strides, no planes, no extra alignment guarantee
(`read_image`'s buffer "must not be assumed to be aligned" ([`decoder.rs`][dec-read])), no sub-byte
storage and no N-D extent. Sub-byte and exotic file layouts exist only as `ExtendedColorType` tags
(`L1`, `Rgb5x1`, `Cmyk16`, `YCbCr8`, `Unknown(u8)`) describing what the file held; decoders expand
them to one of twelve `ColorType`s before the caller sees pixels ([`color.rs`][color-ext],
[`color.rs`][color-type]). `SubImage` can forward a strided sample view from its underlying image
([`sub_image.rs`][sub-fastpath]). `FlatSamples` and its `View`/`ViewMut` wrappers supply strides,
in sample units and as separate types ([`flat.rs`][flat-layout], [`flat.rs`][flat-views]); compare GIL's byte-stride locator
([Boost.GIL][boost-gil]) and mir's `Slice` ([mir-algorithm][mir]). YUV from AVIF is converted to
RGB inside the decoder ([`avif/decoder.rs`][avif-imports]). Built-in pixel types do not expose YUV;
`FlatSamples` can represent equal-sized planes, but not separate chroma-subsampled extents
([concepts][c-subsampling]).

### 2. Genericity mechanism

Rust traits with associated types and associated constants, statically dispatched where the type is
known and boxed (`dyn ImageDecoder`, `dyn GenericImageView`) where it is not. `Pixel` is open, but the traits that would
let a user add a channel type or a colour-typed pixel are sealed ([`primitive_sealed.rs`][prim-sealed],
[`traits.rs`][traits-sealed]), so the set of `ColorType`s, `DynamicImage` variants and
`PixelWithColorType` impls stay in lockstep. Optional capabilities are runtime: `to_pixel_view`
returns `Option`, `FormatAttributes` reports per-decoder metadata support, and `copy_from` tries the
fast path before the per-pixel loop ([`generic_image.rs`][gi-copyfrom]). Specialisation is absent from
stable Rust, so `SubImage` uses an inner-type trick to keep coherence room ([`sub_image.rs`][sub-doc]).
The cost is visible in the type-checker workaround ([`traits.rs`][traits-unify]) and in the reverted
`load_from_memory` generalisation, which was meant to avoid monomorphising all decoders but broke type
inference "quite large in the ecosystem" ([`dynimage.rs`][dyn-load], [`CHANGES.md`][changes-0258]).
The [generic-programming thread][p-generic] places this between GIL's concepts and Julia's
parametric types ([JuliaImages][julia]).

### 3. Colour and metadata

The model is CICP-first: each buffer carries primaries and transfer, conversions are explicit
transforms via moxcms, and ICC tagging requires the parsed profile to contain CICP information
([`moxcms.rs`][moxcms-icc], [`image_reader_type.rs`][rdr-meta]).
Gaps are documented in the type itself: `imageops` "operate in _encoded_ space … and do _not_ linearize
colors", and "The IO functions do _not yet_ write ICC or CICP indications" ([`dynimage.rs`][dyn-doc]).
The decoder trait and its returned attributes expose no CICP tag; `decoder_to_image` explicitly
marks that API as missing and presumes sRGB ([`dynimage.rs`][dyn-srgb], [`decoder.rs`][dec-attrs]).
The reader can replace that tag from ICC. This does not mean all colour information is ignored:
AVIF uses matrix coefficients and range when converting YUV to RGB ([`avif/decoder.rs`][avif-yuv]).
RGB to luma uses the Rec. 709 weights `2126, 7152, 722` on encoded values ([`primitive_sealed.rs`][rgb-luma]),
which the colour-space docs acknowledge ([`buffer.rs`][buf-cicp]); `DynamicImage::to` carries a
**WARNING** that it "always uses sRGB coefficients" ([`dynimage.rs`][dyn-to]). Alpha is stored
straight; `blend` and `resize` premultiply transiently ([`color.rs`][color-blend], [`resize.rs`][resize-premul]).
Metadata is four opaque byte blobs (ICC, EXIF, XMP, IPTC) plus a parsed `Orientation`
([`decoder.rs`][dec-meta], [`metadata.rs`][orientation]); broader EXIF parsing requires a third-party
crate such as `kamadak-exif`.
HDR gain maps and 16-bit-half samples are absent (`// TODO f16 types?` in [`color.rs`][color-ext]).
See [color (D)][color-d] and [concepts: CICP][c-cicp].

### 4. I/O and codec architecture

Pull over `BufRead + Seek` (0.25.0 added that bound "on many decoders" ([`CHANGES.md`][changes-0250])),
whole-image, synchronous. There is no push interface and no suspension: a short read is an I/O error,
and incremental decoding was removed in 0.25.0. The protocol at the pinned revision does separate
header from pixels (`prepare_image` then `read_image`) and supports caller storage
(`decode_into`), which is the shape [Wuffs][p-hostile] also uses, but the decoder still owns the
read loop. Format selection uses the extension or an optional 16-byte content sniff; runtime hooks
in global `RwLock` tables can override built-in detection and decoder selection ([`hooks.rs`][hooks],
[`image_reader_type.rs`][rdr-guess]). The `image-extras` crate uses those hooks for further
formats ([`README.md`][readme-formats]). Encoding is the mirror (`ImageEncoder::write_image` with an
`ExtendedColorType`); `save` converts the pixel format automatically since 0.25.7
([`CHANGES.md`][changes-0257]). Codec choice: 0.25.0 "Switched to zune-jpeg for JPEG decoding" (the 0.24 line used the
`jpeg` dependency name for the `jpeg-decoder` package, confirmed in [0.24.5's manifest][cargo-0245]), "Switched to image-webp for WebP encoding" and removed DXT ([`CHANGES.md`][changes-0250]); JPEG encoding is
`jpeg-encoder`, AVIF encoding is `ravif`, AVIF decoding needs the C `dav1d` and `mp4parse` behind
`avif-native` ([`Cargo.toml`][cargo-features], [`src/lib.rs`][lib-codecs]). See
[concepts: push and pull][c-pushpull] and [suspendable decoding][c-suspend].

### 5. Hostile input and safety

Memory safety is mostly structural: `git grep -w unsafe` finds 16 lines in `src/`, among them the
pixel casts in [`color.rs`][color-unsafe], the `unsafe_get_pixel` trait methods and one
`read_unaligned` in AVIF, and
the `docs/` advisory shows how one was found and removed ([`memory-unsafety.md`][advisory]).
Resource safety is the weak side. Panics are an acknowledged failure mode
([`CHANGES.md`][changes-known]). Limits are opt-out at the reader but opt-in at several direct decoders, the
only strict limits are width and height, and `max_alloc` is best effort; `tests/limits.rs` states
"There are several such buggy APIs in the crate. The tests for them are written but commented out" and
that "a maliciously crafted file could bypass these checks" ([`limits.rs` test][test-limits]).
JPEG sets zune's own maximum dimensions to `usize::MAX` and stores, but does not consult, its
`max_alloc` ([`jpeg/decoder.rs`][jpeg-new], [`jpeg/decoder.rs`][jpeg-limits]). Allocation failure is
partly fallible: clippy forbids `Vec::with_capacity` in favour of a helper using `try_reserve_exact`
([`clippy.toml`][clippy], [`utils/mod.rs`][try-vec]), and `decoder_to_vec` rejects sizes above
`isize::MAX` but still uses infallible `vec!` allocation ([`free_functions.rs`][dec-to-vec]). No common
work-budget API is exposed. AVIF's `read_until_ready` fails after one drained retry because "a crafted file can spin
here forever" ([`avif/decoder.rs`][avif-spin], [`avif_termination.rs`][test-avif]).
[concepts: hostile input][c-hostile] and the [hostile-input thread][p-hostile] frame the gap.

### 6. Allocation and ownership

`ImageBuffer` owns or borrows through its `Container` parameter: `Vec<T>`, `&[T]` or `&mut [T]` all
work, since only `Deref<Target = [P::Subpixel]>` is required ([`buffer.rs`][buf-fromraw]). The
reader always allocates a fresh zeroed `Vec` per image; `decoder_to_image` carries
`FIXME: this should reuse existing buffers` ([`dynimage.rs`][dyn-srgb]), while `decode_into` and
`ImageDecoder::read_image` take caller storage. The 2019 advisory explains why allocation reuse across
pixel types was abandoned: `Vec::from_raw_parts` requires the same size and alignment the memory "was
allocated with", which the advisory's `Rgb<u8>` allocation reinterpreted as `u8` violated ([`memory-unsafety.md`][advisory]).
Animation frames are owned `RgbaImage`s ([`animation.rs`][animation]). Present cached metadata is
cloned into a `Vec<u8>` on access ([`image_reader_type.rs`][rdr-struct]).

### 7. CPU parallelism and SIMD

Parallelism is `rayon`, on by default: `par_enumerate_pixels` and `par_enumerate_pixels_mut` on
buffers ([`buffer_par.rs`][buffer-par]), and threading inside `ravif` and `exr` when the feature is on
([`Cargo.toml`][cargo-features]). The README warns that the default "would also enable
multithreading which may cause unexpected behavior when running for inherently single-threaded
environments such as `wasm` targets" ([`README.md`][readme-features]). The crate has no explicit SIMD
of its own: the only `target_feature` use selects fused multiply-add at compile time
([`math/utils.rs`][fma]). Vector code lives in dependencies (`zune-jpeg`, `jpeg-encoder` with `simd`,
moxcms' AVX/SSE/NEON shaper paths, `pic-scale-safe` for resizing) ([`Cargo.toml`][cargo-deps]).
There is no runtime dispatch layer to compare with Sparkles' ([shaders-simd baseline][bl-shaders] G5).

### 8. GPU offload and interop

Not applicable, by scope. There is no GPU code, no texture-format vocabulary and no compressed-texture
support (DXT was removed in 0.25.0 ([`CHANGES.md`][changes-0250])). The only interop hook is
`FlatSamples`, which the `ImageBuffer` docs say can "map it as a GPU host buffer"
([`buffer.rs`][buf-doc]). `ImageBuffer` cannot select a padded row pitch, but `FlatSamples` can describe
one through `height_stride` in samples ([`flat.rs`][flat-layout]); neither guarantees base-address
alignment or performs GPU upload. See [concepts: staging and upload][c-staging].

### 9. Temporal, animation and containers

Animation is a frame iterator of composited RGBA: `Frame` holds a `Delay` (a reduced rational in
milliseconds), a left/top offset and an `RgbaImage` ([`animation.rs`][animation]). GIF, APNG and animated
WebP produce it; `into_frames` drives the multi-image protocol ([`image_reader_type.rs`][rdr-frames]).
Each decoded frame passes through `into_rgba8()`, so a 16-bit APNG loses precision on that path; the
`apng_16_bits_per_channel` test decodes `rgba16.png` and asserts 8-bit `Rgba([255, 0, 0, 255])`
frames ([`png.rs`][png-apng16]). `FormatAttributes` distinguishes
`supports_animation` from `supports_sequence` (an unrelated image sequence) and
`DecodedAnimationAttributes` carries the loop count ([`decoder.rs`][dec-hint]). There is no timeline,
no seeking and no video; containers are handled per format (`mp4parse` for AVIF only).

### 10. Testing and conformance

Five layers, none of them differential against another decoder:

- **Reference renders.** `tests/reference_images.rs` decodes every file under `tests/images/` and
  compares bytes with a PNG (or TIFF for float) under `tests/reference/`, decoded by image-rs itself
  ([`reference_images.rs`][test-ref]). The harness does not establish how every golden image was
  generated; it is not a live comparison with an independent decoder. It deliberately uses PNG
  references for TIFF inputs to avoid using the same codec on both sides ([`reference_images.rs`][test-tiff-ref]).
  `tests/images/` holds 192 files at the pinned revision (66 BMP,
  31 PNG, 19 TGA, 14 TIFF and smaller sets) and `tests/reference/` 267.
- **Truncation.** `truncate_images.rs` feeds prefixes at a 37-byte step of the first 1000 bytes of
  every test file, for fourteen formats, and requires no panic ([`truncate_images.rs`][test-trunc]).
- **Known-bad and regression files**, several named after [OSS-Fuzz][c-ossfuzz] and ClusterFuzz testcases
  (`tests/regression/jpg/oss-fuzz-36829.jpeg`, `tests/regression/tiff/clusterfuzz-testcase-…`).
- **Limits** tests that encode a 256×256 image and expect each API to reject tight limits
  ([`limits.rs` test][test-limits]).
- **Fuzzing.** `fuzz/` holds thirteen `cargo-fuzz` targets ([`fuzz/Cargo.toml`][fuzz-cargo]): nine
  one-line `load_from_memory_with_format` calls ([`fuzzer_script_png.rs`][fuzz-png]), one
  format-guessing `load_from_memory` call, an EXR decode-encode-decode consistency check, a lossless
  WebP round-trip ([`roundtrip_webp.rs`][fuzz-rt]), and a TGA target that drives `TgaDecoder`
  directly and skips any image above 4,000,000 bytes itself ([`fuzzer_script_tga.rs`][fuzz-tga]),
  a harness-side work-around for the missing per-decoder limit. `fuzz-afl/` adds AFL targets for PNM
  and WebP. Format crates fuzz themselves: the AFL README says the harnesses are "intended for
  integration fuzzing and those decoders that do not yet live in their own crate"
  ([`fuzz-afl/README.md`][fuzz-readme]). External [OSS-Fuzz][c-ossfuzz] enrolment under
  `projects/image-rs` builds the `cargo-fuzz` targets with libFuzzer and AddressSanitizer
  ([`project.yaml`][ossfuzz-project], [`build.sh`][ossfuzz-build]); in-repo CI only checks that the
  targets build (`cargo fuzz check`, `cargo afl check`) ([`rust.yml`][ci-fuzz]) and does not run them.

CI also runs `cargo-semver-checks`, `cargo-deny`, minimal-version builds and cross-architecture tests
under QEMU ([`rust.yml`][ci-yml]), which serve the stability goal rather than decode correctness.

## Lessons for Sparkles

- **Q2.** Associated types and constants map directly onto D: `alias Subpixel` and `enum channelCount`
  inside the pixel struct, checked by an `enum bool isPixel(P)` trait. **Verified:** a
  probe with `Rgb!T`, `Rgba!T` and `Luma!T` passes `static assert(isPixel!(Rgb!ubyte))` and rejects
  `int` under `-betterC -preview=dip1000`. Rust's `Pixel` is also open; sealing applies to `Primitive`
  and `PixelWithColorType`. A D structural trait ([guidelines][dbi]) can likewise accept custom
  pixels while keeping the run-time colour tags and transform table restricted to a known set.
- **Q2.** image-rs needs `unsafe` for `pixels_from_channels`; D does not. **Verified:** casting
  the first twelve bytes of a thirteen-byte `const(ubyte)[]` to `const(Rgb!ubyte)[]` compiles in a
  `@safe pure nothrow @nogc` function and yields four pixels, the last holding `10, 11, 12`.
  Matching the "longest prefix of whole pixels" contract ([`traits.rs`][traits-pixel]) requires
  explicit trimming: a direct cast of all thirteen bytes compiled but aborted at runtime because
  thirteen is not divisible by three. These probe element types hold no pointers.
- **Q2, Q3.** `to_pixel_view` returning `Option` is image-rs's way of offering an optional fast path
  without specialisation. D can make the same choice at compile time (`static if` on a
  `hasPixelView` trait), which removes the branch and lets the fast path be `@nogc` while the slow
  path stays generic. The runtime form remains useful behind a `SumType`, where the variant is
  unknown until match time.
- **Q1, Q9.** `DynamicImage` is the case for a closed run-time set: twelve variants, one macro to
  dispatch, a `#[non_exhaustive]` escape hatch. **Verified:** a `SumType` over three `ImageBuffer`
  instances dispatches with `match` inside a `@safe pure nothrow @nogc` function under `-betterC`. The
  [baseline][bl-existing] has no comparable run-time image union (G2); image-rs suggests keeping that set small and
  normalised, and keeping per-file exotica in a tag (`ExtendedColorType`) rather than in variants.
- **Q1.** image-rs shows the cost of no strides and no planes: AVIF YUV is converted to RGB inside the
  decoder and `FlatSamples` is a separate FFI type. `SubImage` forwards a sample view when available,
  falling back to per-pixel calls otherwise ([`sub_image.rs`][sub-fastpath]). A
  Sparkles view that carries strides and per-plane extents from the start avoids splitting into
  `ImageBuffer` versus `FlatSamples` ([baseline][bl-existing] G2, [shaders-simd][bl-shaders] G10).
  `u32` extents and `usize` indices also transfer poorly to Sparkles' `size_t` convention.
- **Q1, Q4.** `from_raw` checks `channels * width * height` with checked multiplication against the
  container once, then computes in-bounds indices without checked multiplication. Ordinary
  `get_pixel` still checks bounds ([`buffer.rs`][buf-getpixel]). **Verified:** the D form with `core.checkedint.mulu` returns
  "None" for a 3×2 image over 13 bytes and for `uint.max` squared. dip1000 rejected the `out`-parameter
  shape for a borrowed container ("assigning scope variable `buf` to `ref` variable `result`"); a
  returned option-like struct with a `return scope` parameter compiles. That is evidence for
  `Expected`-returning constructors ([AGENTS][agents-expected]).
- **Q4.** The pinned-revision protocol (configure, prepare, metadata, read, finish) is a better
  starting point than GIL's whole-image read: it separates header from pixels, takes caller storage
  and advertises when metadata is valid. It is still pull-only and non-suspendable, and 0.25.0 removed
  incremental decoding rather than fixing it. The [wired baseline][bl-wired] G3 gap (no suspended
  status) and [event-horizon][bl-eh] both need a push form that image-rs does not offer.
- **Q4, Q8.** Limits as an API are worth copying; the enforcement model is not. A per-decoder default
  of "no limits" for JPEG, PNG and GIF, a non-strict `max_alloc`, and commented-out failing tests
  show gaps in enforcement. Sparkles' existing PNG pixel cap and the draft Flat traversal-byte
  budget bound different resources ([wired baseline][bl-wired] G8); the lesson is to make each decoder's budget a required
  input and to add a common work budget, which image-rs does not expose; AVIF has a local spin guard.
- **Q5.** A CICP tag on every buffer, defaulting to sRGB, with transforms that refuse unsupported
  spaces, is a minimal colour model that fits [baseline][bl-existing] G4. image-rs also shows the
  failure mode: decoders do not report CICP, so the tag is a presumption that the ICC path may
  overwrite. A Sparkles design should make "unknown" the decoder default and have each codec report
  what it parsed. Transfer-function awareness in point operations (image-rs works in encoded space)
  is the open question ([resampling-colour thread][p-colour]).
- **Q5.** Decoder metadata getters expose opaque owned `Vec<u8>` blobs; the reader clones cached
  blobs on access and separately parses ICC and EXIF orientation. Sparkles' draft `wired` Flat descriptions and borrowed byte ranges
  ([wired baseline][bl-wired] G15) could return slices into the source instead.
- **Q7.** image-rs has no SIMD dispatch of its own; vectorisation is delegated to codec and resize
  crates. It offers no model for [shaders-simd][bl-shaders] G4 or G5.
- **Q8.** A golden-image corpus plus prefix truncation plus OSS-Fuzz harnesses that in-repo CI only
  compile-checks is the image-rs test shape. Sparkles' PNG oracle against stb_image ([baseline][bl-existing]
  G11) is already the stronger differential form; image-rs's truncation sweep and named fuzz
  regressions are cheap additions worth copying.
- **Q9.** image-rs keeps core types, `imageops` and the format front door in one crate, and splits
  along dependencies: each codec is a feature, most codecs are their own crate, and further formats
  arrive through runtime hooks. Its stability rule ("wrappers, not direct re-exports") is evidence
  that a format layer should own its public types even when the codecs are external. The README's
  advice to disable default features in libraries ([`README.md`][readme-features]) is evidence that
  default-on threading and formats work against wasm and minimal builds.

## Strengths

- Four built-in pixel families, twelve `DynamicImage` variants, one buffer type and one decoder trait.
- Header and pixel phases are separate at the pinned revision, with caller storage and documented
  call order.
- `from_raw` validates the size with checked arithmetic, making later in-bounds index arithmetic safe from overflow.
- Explicit CICP colour tagging and moxcms transforms that refuse spaces they cannot handle.
- Codecs are separate crates with their own fuzzing; format support is per cargo feature.
- Little `unsafe`, a fallible allocation helper and a clippy ban on `Vec::with_capacity`, plus
  a public advisory documenting an allocation-reinterpretation soundness issue.
- Strong API-stability machinery: `#[non_exhaustive]` enums, sealed traits, `cargo-semver-checks`.

## Weaknesses

- No strides, planes, extra alignment guarantee or N-D extents in the main buffer; AVIF YUV is converted to RGB.
- Pull-only, non-suspendable decoding; incremental decoding was removed in 0.25.0.
- Several direct decoders disable limits by default, `max_alloc` is best effort, and panics on malicious input are a
  listed known issue.
- Decoders do not report CICP; buffers presume sRGB; `imageops` work in encoded space.
- Animation is always 8-bit RGBA; no f16 sample type.
- The release API and `main` differ substantially (`ImageReader` renamed, decoder protocol rewritten),
  and the README example still shows the old builder ([`README.md`][readme-example],
  [`ImageReader::new`][rdr-entrypoints]).
- Reference tests compare golden images through image-rs; fuzz targets are built in CI but not run there.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                 | Trade-off                                                                                       |
| ------------------------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Sealed `Primitive`, `Pixel`-with-colour-type traits           | Keep `ColorType`, `DynamicImage` and transform tables complete and stable | Users cannot add sample types or colour-typed pixels; type-checker workarounds inside the crate |
| Packed row-major `ImageBuffer`, strides only in `FlatSamples` | Simple sound indexing after one checked construction                      | Planar, subsampled, padded and tiled data need conversion or a second type                      |
| Closed `DynamicImage` enum, `#[non_exhaustive]`               | One run-time type for "an opened file" with lossless common formats       | Exotic formats are normalised on decode; downstream exhaustive matches are unavailable          |
| Object-safe `ImageDecoder`, boxed in the reader               | Format chosen at run time; external crates plug in via hooks              | Virtual calls per phase; capability negotiation moves to runtime `FormatAttributes`             |
| Remove incremental decoding (0.25.0)                          | The release notes pair its removal with making the trait object safe      | Whole-image output; no suspend/resume or async decoder protocol                                 |
| `Limits` strict for dimensions, best effort for bytes         | Implementable across heterogeneous external codecs                        | A crafted file may exceed `max_alloc`; several direct decoders default to "no limits"           |
| CICP tag per buffer, moxcms behind `CmsProvider`              | Minimal explicit colour model with a replaceable engine                   | Decoders do not populate it; sRGB is a presumption; PQ is unsupported                           |
| Wrap, do not re-export, codec options                         | Insulate users from dependency major versions                             | Format-specific features lag until two implementations or a standard justify a wrapper          |
| `rayon` and all formats on by default                         | Batteries-included application experience                                 | Libraries must opt out; wasm and single-threaded targets see unexpected threading               |

## Sources

- image-rs source at `075e65d618a323e5cb48c1d8710a2eca25d690c6`, read with `git show`: `src/lib.rs`,
  `src/traits.rs`, `src/primitive_sealed.rs`, `src/color.rs`, `src/images/{buffer,buffer_par,dynimage,flat,generic_image,sub_image}.rs`,
  `src/io/{decoder,limits,image_reader_type,free_functions}.rs`, `src/io.rs`, `src/metadata.rs`,
  `src/metadata/{cicp,moxcms}.rs`, `src/codecs/{jpeg/decoder,png,avif/decoder}.rs`, `src/hooks.rs`,
  `src/animation.rs`, `src/math/utils.rs`, `src/imageops/resize.rs`, `src/utils/mod.rs`.
- Project files: `Cargo.toml`, `CHANGES.md`, `README.md`, `clippy.toml`,
  `docs/2019-04-23-memory-unsafety.md`, `.github/workflows/rust.yml`.
- Tests and fuzzing: `tests/{reference_images,truncate_images,limits,avif_termination}.rs`,
  `fuzz/{Cargo.toml,README.md}`, `fuzz/fuzzers/*.rs`, `fuzz-afl/README.md`.
- The 0.25.9 release API on [docs.rs][docs]: [`ImageDecoder`][docs-decoder-025] and
  [`ImageReader`][docs-reader-025]; the 0.24.5 [`Cargo.toml`][cargo-0245] on docs.rs.
- OSS-Fuzz `image-rs` project: [`project.yaml`][ossfuzz-project], [`build.sh`][ossfuzz-build].
- The [baseline][bl-existing] and paper threads ([generic programming][p-generic],
  [hostile input][p-hostile], [resampling and colour][p-colour]) for the Sparkles side.
- D probes independently recompiled in `/tmp` with LDC 1.43.0
  `-betterC -preview=dip1000 -preview=in` on November 15, 2026: pixel-trait assertions,
  explicitly trimmed channel-to-pixel cast, checked `fromRaw` and `SumType` dispatch passed.
  The untrimmed thirteen-byte cast aborted; the borrowed `out`-parameter constructor failed dip1000.

<!-- References -->

[repo]: https://github.com/image-rs/image
[docs]: https://docs.rs/image/0.25.9/image/
[docs-decoder-025]: https://docs.rs/image/0.25.9/image/trait.ImageDecoder.html
[docs-reader-025]: https://docs.rs/image/0.25.9/image/struct.ImageReader.html
[license-mit]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/LICENSE-MIT
[license-apache]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/LICENSE-APACHE
[cargo-pkg]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/Cargo.toml#L1-L13
[cargo-0245]: https://docs.rs/crate/image/0.24.5/source/Cargo.toml#38
[cargo-deps]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/Cargo.toml#L42-L72
[cargo-features]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/Cargo.toml#L82-L112
[changes]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/CHANGES.md
[changes-known]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/CHANGES.md#L3-L5
[changes-next]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/CHANGES.md#L9-L22
[changes-0258]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/CHANGES.md#L46-L53
[changes-0257]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/CHANGES.md#L55-L74
[changes-0250]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/CHANGES.md#L162-L182
[readme-formats]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/README.md#L38-L47
[readme-features]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/README.md#L49-L60
[readme-example]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/README.md#L19-L35
[lib-overview]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/lib.rs#L1-L12
[lib-codecs]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/lib.rs#L191-L232
[traits-primitive]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/traits.rs#L37-L49
[traits-pwct]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/traits.rs#L173-L223
[traits-sealed]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/traits.rs#L225-L267
[traits-unify]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/traits.rs#L353-L379
[traits-pixel]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/traits.rs#L425-L581
[prim-sealed]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/primitive_sealed.rs#L1-L26
[rgb-luma]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/primitive_sealed.rs#L187-L199
[color-type]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/color.rs#L11-L42
[color-ext]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/color.rs#L95-L178
[color-define]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/color.rs#L344-L377
[color-unsafe]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/color.rs#L388-L418
[color-instances]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/color.rs#L507-L519
[color-blend]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/color.rs#L879-L918
[buf-doc]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L430-L447
[buf-struct]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L491-L498
[buf-fromraw]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L500-L523
[buf-fits]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L628-L642
[buf-indices]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L644-L659
[buf-getpixel]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L604-L626
[buf-cicp]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer.rs#L1063-L1104
[buffer-par]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/buffer_par.rs#L185-L215
[gi-view]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/generic_image.rs#L7-L106
[gi-fastpath]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/generic_image.rs#L135-L150
[gi-image]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/generic_image.rs#L214-L233
[gi-subimage]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/generic_image.rs#L355-L364
[gi-copyfrom]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/generic_image.rs#L235-L285
[sub-doc]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/sub_image.rs#L9-L46
[sub-view]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/sub_image.rs#L120-L145
[sub-fastpath]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/sub_image.rs#L221-L232
[flat-samples]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/flat.rs#L59-L95
[flat-layout]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/flat.rs#L97-L118
[flat-normal]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/flat.rs#L1099-L1130
[flat-asview]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/flat.rs#L604-L645
[flat-views]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/flat.rs#L1025-L1059
[dyn-doc]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L27-L70
[dyn-enum]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L71-L109
[dyn-map]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L111-L128
[dyn-to]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L288-L295
[dyn-srgb]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L1790-L1893
[dyn-load]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/images/dynimage.rs#L1959-L1968
[dec-protocol]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L6-L29
[dec-limits]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L30-L49
[dec-prepare]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L74-L87
[dec-read]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L89-L114
[dec-meta]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L116-L162
[dec-attrs]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L213-L237
[dec-hint]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/decoder.rs#L179-L271
[limits]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/limits.rs#L9-L56
[limits-reserve]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/limits.rs#L103-L162
[rdr-spec]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L19-L28
[rdr-make]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L171-L246
[rdr-guess]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L293-L321
[rdr-open]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L370-L382
[rdr-struct]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L385-L468
[rdr-entrypoints]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L720-L779
[rdr-decode]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L541-L566
[rdr-into]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L591-L612
[rdr-limits]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L800-L810
[rdr-frames]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L812-L853
[rdr-meta]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/image_reader_type.rs#L904-L949
[magic]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/free_functions.rs#L106-L164
[dec-to-vec]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/io/free_functions.rs#L166-L186
[cms-provider]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata.rs#L17-L24
[orientation]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata.rs#L26-L52
[cicp-struct]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata/cicp.rs#L17-L42
[cicp-transfer]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata/cicp.rs#L175-L201
[cicp-transform]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata/cicp.rs#L285-L332
[cicp-stable]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata/cicp.rs#L1139-L1198
[moxcms]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata/moxcms.rs#L13-L21
[moxcms-icc]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/metadata/moxcms.rs#L85-L89
[jpeg-new]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/jpeg/decoder.rs#L27-L49
[png-default]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/png.rs#L44-L50
[gif-default]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/gif.rs#L64-L77
[avif-default]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/avif/decoder.rs#L143-L151
[jpeg-limits]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/jpeg/decoder.rs#L173-L179
[avif-imports]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/avif/decoder.rs#L18-L25
[avif-yuv]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/avif/decoder.rs#L459-L470
[avif-spin]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/avif/decoder.rs#L789-L815
[hooks]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/hooks.rs#L1-L20
[animation]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/animation.rs#L38-L67
[fma]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/math/utils.rs#L7-L30
[resize-premul]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/imageops/resize.rs#L27-L33
[try-vec]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/utils/mod.rs#L109-L114
[clippy]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/clippy.toml#L1-L3
[advisory]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/docs/2019-04-23-memory-unsafety.md#L1-L40
[test-ref]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/tests/reference_images.rs#L129-L175
[test-tiff-ref]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/tests/reference_images.rs#L72-L90
[test-trunc]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/tests/truncate_images.rs#L34-L46
[test-limits]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/tests/limits.rs#L1-L14
[test-avif]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/tests/avif_termination.rs#L1-L28
[fuzz-cargo]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/fuzz/Cargo.toml
[fuzz-png]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/fuzz/fuzzers/fuzzer_script_png.rs#L1-L7
[fuzz-tga]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/fuzz/fuzzers/fuzzer_script_tga.rs#L9-L18
[png-apng16]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/src/codecs/png.rs#L1161-L1182
[fuzz-rt]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/fuzz/fuzzers/roundtrip_webp.rs#L1-L2
[fuzz-readme]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/fuzz-afl/README.md#L1-L4
[ci-fuzz]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/.github/workflows/rust.yml#L126-L165
[ci-yml]: https://github.com/image-rs/image/blob/075e65d618a323e5cb48c1d8710a2eca25d690c6/.github/workflows/rust.yml
[ossfuzz-project]: https://github.com/google/oss-fuzz/blob/fe1478d57b3b5e66acdff48abbab6adcb6e7ff37/projects/image-rs/project.yaml#L1-L10
[ossfuzz-build]: https://github.com/google/oss-fuzz/blob/fe1478d57b3b5e66acdff48abbab6adcb6e7ff37/projects/image-rs/build.sh#L31-L43
[boost-gil]: ./boost-gil.md
[mir]: ./mir-algorithm/index.md
[julia]: ./juliaimages.md
[color-d]: ./color.md
[c-subsampling]: ./concepts.md#chroma-subsampling
[c-cicp]: ./concepts.md#cicp
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-suspend]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[c-ossfuzz]: ./concepts.md#oss-fuzz
[c-staging]: ./concepts.md#staging-and-upload
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md
[p-generic]: ./papers/generic-image-programming.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-colour]: ./papers/resampling-colour.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[agents-expected]: ../../guidelines/idioms/expected/index.md
