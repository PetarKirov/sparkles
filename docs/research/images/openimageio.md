# OpenImageIO (C++)

The Academy Software Foundation's format-agnostic image I/O stack for film
production: a runtime-typed image description (`ImageSpec`), plugin readers and
writers behind one virtual interface, an in-memory `ImageBuf` with an algorithm
library, and a tile cache with a filtered texture system on top.

| Field         | Value                                                                                   |
| ------------- | --------------------------------------------------------------------------------------- |
| Language      | C++17 (Python bindings; plugins as shared objects or embedded)                          |
| License       | Apache-2.0 ([`LICENSE.md`][license]); documentation CC-BY-4.0                           |
| Repository    | [AcademySoftwareFoundation/OpenImageIO][repo]                                           |
| Revision read | `e7eb5d1091142cb69d99c72b85da2734fcf390a7` (October 27, 2026; version string `3.3.0.0`) |
| Documentation | [openimageio.readthedocs.io][docs]; the in-tree sources under `src/doc/`                |
| Category      | Generic libraries                                                                       |
| Tier          | A                                                                                       |
| Last reviewed | November 14, 2026                                                                       |

> [!NOTE]
> OpenImageIO (OIIO) is the survey's reference point for the **erased, runtime-typed**
> end of the design space: one image description whose element type is a value
> (`TypeDesc`), not a type parameter. It is the opposite pole to
> [Boost.GIL][related-1] and [VIGRA][related-2]. It combines a production tile
> cache, a texture filter and an attribute-driven set of decode limits.
> Where this page says **verified**, a program was run in a scratch
> directory against the nixpkgs build of release `3.1.7.0` (not the pinned `3.3.0.0`
> development revision); the version is named each time. Everything else was read in
> the pinned tree with `git show`.

---

## Overview

### What it solves

A visual-effects pipeline reads and writes dozens of formats (OpenEXR, TIFF, DPX,
JPEG, PNG, camera RAW, HEIF, JPEG XL and more), with features most libraries do not
expose: tiles, multiple subimages, MIP levels, per-channel data types, deep
(multi-sample) pixels, data windows that differ from display windows, and arbitrary
named metadata. Renderers then sample textures whose combined size is far larger than
RAM. The README states the mission and the scale target:

> _"OpenImageIO is a toolset for reading, writing, and manipulating image files of any
> image file format relevant to VFX / animation via a format-agnostic API with a feature
> set, scalability, and robustness needed for feature film production."_
> ([`README.md`][readme])

> _"An ImageCache class that transparently manages a cache so that it can access truly
> vast amounts of image data (tens of thousands of image files totaling multiple TB)
> very efficiently using only a tiny amount (tens of megabytes at most) of runtime
> memory."_ ([`README.md`][readme-ic])

The library has five cooperating layers: `TypeDesc` and `ImageSpec`
(description); `ImageInput`/`ImageOutput` and their plugins (codecs); `ImageBuf` and
`ImageBufAlgo` (whole images in memory); `ImageCache` (tiles on demand); and
`TextureSystem` (filtered MIP-map lookups). The command-line tools `oiiotool`, `iinfo`,
`iconvert`, `idiff`, `maketx` and `igrep` are thin clients of the same API.

### Design philosophy

The introduction to the manual names the trade explicitly: a small, fixed client-side
data model, with everything exotic pushed into plugins.

> _"Good design is usually a matter of deciding what *not* to do, and OpenImageIO is no
> exception. We achieve power and elegance only by making simplifying assumptions."_
> ([`src/doc/oiiointro.md`][intro])

The assumptions it lists include byte-aligned scalar samples; compression is
_"handled entirely within an OpenImageIO plugin"_; non-RGB colour models are converted
to RGB on read by default (raw values can be requested); channels are ordered R, G, B,
then alpha, then Z; and all channels of a subimage share one resolution, so subsampled
chroma is upsampled. The same passage
adds that _"these restrictions apply to data passed through the APIs, not to the files
themselves."_ A movie is admitted only as _"a sequence of separate frames within the
file, but not as movies per se"_.

Three consequences run through the code:

1. **Types are values at the plugin seam.** A pixel's channel type is a `TypeDesc`
   carried in the spec. Typed read wrappers infer the destination `TypeDesc` from
   `image_span<T>`; conversion is a library service ([`imageio.h`][read-span]).
2. **Extension is by name.** New capabilities arrive as query strings to `supports()`,
   new metadata as attribute names, new limits as global attributes. The header says
   this is deliberate: adding a query _"does not require any new API entry points"_, so
   it keeps what the comment calls link compatibility with previously compiled plugins
   ([`imageio.h`][supports-in]).
3. **Random access is promised even where the format is sequential.** A reader that
   cannot seek _"should transparently close, reopen, and sequentially read through prior
   scanlines"_ ([`imageio.h`][read-span]).

---

## How it works

### `TypeDesc` and `ImageSpec`

`TypeDesc` is an eight-byte value: `basetype` (`UINT8` through `DOUBLE`, plus `HALF`,
`STRING`, `PTR`, `USTRINGHASH`), `aggregate` (`SCALAR`, `VEC2`..`VEC4`, `MATRIX33`,
`MATRIX44`), a `vecsemantics` hint (`COLOR`, `POINT`, `NORMAL`, `TIMECODE`,
`RATIONAL`, `BOX`, ...) and an `arraylen`. Its header calls it _"not meant to be
comprehensive"_: no structs, unions or nested types ([`typedesc.h`][typedesc]). The
same type describes pixel channels and metadata values.

`ImageSpec` is a plain class with public fields ([`imageio.h`][spec]):

```cpp
// src/include/OpenImageIO/imageio.h — ImageSpec data members (abridged)
int x, y, z;                          // origin of the pixel data window
int width, height, depth;             // depth > 1 means a volume
int full_x, full_y, full_z;           // display window origin
int full_width, full_height, full_depth;
int tile_width, tile_height, tile_depth;  // 0 = scanline order
int nchannels;
TypeDesc format;                      // the common channel type
std::vector<TypeDesc> channelformats; // empty unless channels differ
std::vector<std::string> channelnames;
int alpha_channel;                    // -1 if none or unknown
int z_channel;
bool deep;                            // multiple samples per pixel
ParamValueList extra_attribs;         // everything else, by name
```

The data window and the display window are separate rectangles; their doc comment
lists crop windows and overscan as the reason. Sizes are `imagesize_t`
(`uint64_t`), strides are `stride_t` (`int64_t`, in bytes) with an `AutoStride`
sentinel, and the size helpers (`scanline_bytes`, `tile_bytes`, `image_bytes`) return
the maximum `imagesize_t` on overflow, with `size_t_safe()` to test the result on
32-bit hosts ([`imageio.h`][sizes], [`imageio.h`][stride]). Coordinates and dimensions stay `int`.

Regions are `ROI`, a half-open box over x, y, z and a channel range
(`[chbegin, chend)`), whose default value means "all" ([`imageio.h`][roi]).

### `ImageInput`: open, probe, read with conversion

A client calls `ImageInput::open(filename, config, ioproxy)` and gets a
`std::unique_ptr`. `create()` first tries the plugin named by the extension; if that
fails and the global `try_all_readers` attribute is set (the default is `1`), it asks
every other plugin's cheap `valid_file()` probe and tries each candidate in turn
([`imageioplugin.cpp`][plugin-create], [`imageioplugin.cpp`][plugin-try]). A plugin is a subclass that implements
`open`, `close`, `format_name`, optionally `seek_subimage`, and native read
primitives. The header requires scanline support plus tiles for tiled formats,
and recommends span-based range implementations with pointer wrappers. Base-class
fallbacks implement conversion and convenience reads ([`imageio.h`][native-contract]).

The public read surface is a grid: whole image, scanline range, tile range, each with
an explicit `(subimage, miplevel)` pair and a channel range, each in a pointer-plus-
strides form and (since 3.1) a bounded `image_span` form
([`imageio.h`][read-span]). The explicit-subimage forms are documented as thread-safe
against each other. The base-class implementation shows how conversion on read works
([`imageinput.cpp`][readscan]):

```cpp
// src/libOpenImageIO/imageinput.cpp — ImageInput::read_scanlines (abridged)
bool no_type_convert = (format == spec.format && spec.channelformats.empty());
if ((native || no_type_convert) && contiguous)
    return read_native_scanlines(subimage, miplevel, ybegin, yend, dataspan);

// No such luck.  Read scanlines in chunks.
int chunk = scanline_read_chunk(spec, rps);
std::unique_ptr<std::byte[]> buf(new std::byte[chunk * native_scanline_bytes]);
for (...; ybegin < yend; ybegin += nscanlines) {
    ok &= read_native_scanlines(subimage, miplevel, ybegin, y1, chbegin, chend, bufspan);
    ...
    ok = parallel_convert_image(nchans, spec.width, nscanlines, 1, buf.get(),
                                spec.format, AutoStride, AutoStride, AutoStride,
                                data, format, xstride, ystride, zstride, threads());
}
```

So a decoded chunk lands in a native-format scratch buffer, then `convert_image`
rewrites it into the caller's type and strides; per-channel formats are converted in
runs of adjacent channels with the same type. The chunk size honours the reader's
`oiio:RowsPerChunk` hint (TIFF strips, OpenEXR chunks) ([`stdmetadata.md`][meta-hints]).

### Plugins and the capability vocabulary

Each format lives in `src/<name>.imageio/` (32 directories at this revision) and
exports C symbols by naming convention: `png_input_imageio_create()` returning
`new PNGInput`, `png_imageio_version`, `png_imageio_library_version()` and a
null-terminated `png_input_extensions[]` ([`pnginput.cpp`][pnginput]). With
`EMBED_PLUGINS`, the `PLUGENTRY`/`PLUGENTRY_RO`/`PLUGENTRY_WO` macros register the
built-in set statically ([`imageioplugin.cpp`][plugin]); otherwise the same symbols are
found by `Plugin::getsym` (`dlsym`) along a plugin search path. What a plugin can do is asked at
run time with `supports("name")`, returning an `int`. Readers answer
`arbitrary_metadata`, `exif`, `iptc`, `cicp`, `mdcv`, `ioproxy`, `procedural`,
`thumbnail`, `multiimage`, `mipmap` and `noimage` ([`imageio.h`][supports-in]);
writers add `tiles`, `rectangles`, `random_access`, `appendsubimage`, `volumes`,
`alpha`, `nchannels`, `rewrite`, `channelformats`, `displaywindow`, `origin`,
`negativeorigin`, `deepdata` and others ([`imageio.h`][out-supports]). Writers build
multi-image and MIP-mapped files by reopening with `OpenMode::AppendSubimage` or
`AppendMIPLevel` ([`imageio.h`][out-open]).

Byte sources are abstracted by `Filesystem::IOProxy`: virtual `read`, `write`,
`seek`, `tell`, `size`, and positional `pread`/`pwrite` documented as thread-safe
against each other ([`filesystem.h`][ioproxy]). `IOFile`, `IOMemReader` and
`IOVecOutput` are the stock implementations. A plugin opts in with
`supports("ioproxy")`; the RAW and FFmpeg plugins do not, because their libraries need
a file name (the fuzz harness writes a temporary file for them, see
[§10][related-3]).

### `ImageBuf` and `ImageBufAlgo`

`ImageBuf` is the in-memory image. It reads lazily, and its storage is one of
`LOCALBUFFER` (owned), `APPBUFFER` (wraps caller memory) or `IMAGECACHE` (read-only,
backed by tiles) ([`imagebuf.h`][imagebuf]). It makes one more simplification than the
I/O layer: _"all channels are the same data type"_, so a mixed `half`/`float` file is
widened on read. Writable buffers are always fully resident: _"Writable ImageBufs are
always stored entirely in memory"_. Pixel access is through `getpixel`/`setpixel`
(converting to `float`) or the templated `ImageBuf::Iterator<BUFT, USERT>` and
`ConstIterator`, which also handle `WrapMode` at the edges.

`ImageBufAlgo` (IBA) is a flat namespace of functions (`add`, `mad`, `resize`,
`warp`, `colorconvert`, `compare`, `computePixelStats`, the deep-image operations and
more), with image-producing operations taking a destination, sources, an `ROI` and a
thread count. Two pieces of
glue do the generic work ([`imagebufalgo_util.h`][ibautil-dispatch]):

- `IBAprep` resolves the ROI, allocates an uninitialised destination and checks
  preconditions selected by `IBAprep_flags` (`REQUIRE_ALPHA`, `SUPPORT_DEEP`,
  `NO_SUPPORT_VOLUME`, `REQUIRE_MATCHING_CHANNELS`, ...) ([`imagebufalgo_util.h`][ibautil-prep]).
- The `OIIO_DISPATCH_COMMON_TYPES*` macros switch on the runtime `TypeDesc` of each buffer and
  call a template instantiation for `float`, `uint8`, `half` or `uint16`; any other
  type is first **copied to a `float` buffer** and the result copied back.
  Other dispatch macros instantiate more types directly; this restriction belongs
  to the common-type paths, not all of IBA ([`imagebufalgo_util.h`][iba-alltypes]).

```cpp
// src/include/OpenImageIO/imagebufalgo_util.h — OIIO_DISPATCH_COMMON_TYPES2 (abridged)
if (!ImageBufAlgo::is_common_pixel_type(Atype)) {
    Atype = TypeDesc::FLOAT;
    Atmp.copy(A, Atype);
    Aptr = &Atmp;
}
...
switch (Atype.basetype) {
case TypeDesc::FLOAT : ret = func<float,float> (*Rptr, *Aptr, __VA_ARGS__); break;
case TypeDesc::UINT8 : ret = func<float,unsigned char> (*Rptr, *Aptr, __VA_ARGS__); break;
...
```

The kernels themselves are short loops over iterators inside `parallel_image`
([`imagebufalgo_mad.cpp`][mad]):

```cpp
// src/libOpenImageIO/imagebufalgo_mad.cpp — mad_impl_scalar (abridged)
ImageBufAlgo::parallel_image(roi, nthreads, [&](ROI roi) {
    ImageBuf::Iterator<Rtype> r(R, roi);
    ImageBuf::ConstIterator<ABCtype> a(A, roi), b(B, roi), c(C, roi);
    for (; !r.done(); ++r, ++a, ++b, ++c)
        for (int ch = roi.chbegin; ch < roi.chend; ++ch)
            r[ch] = a[ch] * b[ch] + c[ch];
});
```

### `ImageCache` and `TextureSystem`

`ImageCache` holds two sharded concurrent hash maps: file name to `ImageCacheFile`
(64 shards) and `TileID` to `ImageCacheTile` (128 shards)
([`imagecache_pvt.h`][icpvt-shards]). A file is opened on first touch and closed again
when the open-file count exceeds `max_open_files` (default 100); tiles are read on
demand and evicted when their total exceeds `max_memory_MB` (default 1024)
([`imagecache.h`][ic-attrs]). An untiled file is presented as virtual tiles when
`autotile` is set. `deduplicate` (default on) treats files whose headers carry the same
SHA-1 fingerprint, as `maketx` writes them, as one image ([`imagecache.h`][ic-dedup]).

Eviction is a CLOCK (second-chance) sweep. Each tile has an atomic `m_used` bit set on
access; `release()` clears it with a compare-exchange and reports whether it had been
set ([`imagecache_pvt.h`][icpvt-tile]). `check_max_mem` takes a `try_lock`, so only one
thread sweeps, remembers the `TileID` where the hand stopped instead of an iterator, and
removes cache entries whose bit was already clear. References held elsewhere can
keep their tiles alive. The comment accepts the overshoot: _"If this
means we may ephemerally be over the memory limit ... so be it."_
([`imagecache.cpp`][ic-sweep])

Each thread has an `ImageCachePerThreadInfo` with an unlocked file-name map and a
two-tile "microcache" (`tile`, `lasttile`), so consecutive lookups in the same tile take
no lock ([`imagecache_pvt.h`][icpvt-thread]). The public API exposes tiles directly
(`get_tile`, `tile_pixels`, `release_tile`) as well as `get_pixels` over a region
([`imagecache.h`][ic-tile]).

**Verified (release 3.1.7.0).** A C++ probe compiled in a scratch directory (not
committed) swept the
2048 × 2048 float RGBA level of a `maketx` texture (64 × 64 tiles, 64 MiB uncompressed)
64 rows at a time through a private `ImageCache`. The texture was generated with
`oiiotool --pattern constant:color=0.5,0.5,0.5,0.5 2048x2048 4 -d float -o constant.exr`
and `maketx --tile 64 64 -d float constant.exr -o constant.tx`:

| `max_memory_MB` set | `stat:tiles_created` | `stat:tiles_peak` | `stat:cache_memory_used` |
| ------------------- | -------------------- | ----------------- | ------------------------ |
| 4                   | 1024                 | 160               | 10422768                 |
| 16                  | 1024                 | 256               | 16715760                 |
| 256                 | 1024                 | 1024              | 67125248                 |

These results reproduced on November 14, 2026. Each tile has 64 KiB of pixels
plus 16 bytes of padding in this build. `tiles_peak` is a peak count, whereas
`cache_memory_used` is current usage: the runs ended with 159, 255 and 1024 tiles,
respectively. Thus 10422768 = 159 × (65536 + 16), not the bytes for the 160-tile
peak. The setting is an approximate tile-memory target, not a cap on total process
memory or transient allocation ([`imagecache.h`][ic-attrs],
[`imagecache.cpp`][ic-tile-memory]). The 4 MB run peaked at
160 tiles because release builds clamp the setting, as the attribute setter
shows: `size = std::max(size, 10.0f);  // Don't let users choose < 10 MB`
([`imagecache.cpp`][ic-mem]). Debug builds allow 1 MB. Reading back the effective
setting returned 10, 16 and 256 MiB. A `TextureSystem::texture` lookup of the
constant-0.5 texture returned 0.5 in all four channels.

`TextureSystem` sits on the same cache. A lookup takes `(s, t)` and the four screen
derivatives `dsdx, dtdx, dsdy, dtdy`, plus a `TextureOpt` of wrap modes, blur, width
and fill ([`texture.h`][tex-api]). `MipMode` selects `NoMIP`, `OneLevel`, `Trilinear`
or `Aniso`; `InterpMode` selects `Closest`, `Bilinear`, `Bicubic` or `SmartBicubic`
(bicubic when magnifying) ([`texture.h`][tex-modes]). The anisotropic path computes the
footprint ellipse from the derivatives, picks two MIP levels from the minor axis, and
places `max(1, int(2 × aspect − 1))` probes along the major axis, each a bilinear or bicubic
sample ([`texturesys.cpp`][texsys-lookup], [`texturesys.cpp`][texsys-ellipse],
[`texturesys.cpp`][texsys-miplevel]); a
stochastic mode takes one probe at a random position instead. A batched form
(`TextureOptBatch`, default `Tex::BatchWidth = 16`) shades sixteen lanes per call
unless overridden at build time ([`texture.h`][tex-modes], [`texture.h`][tex-batch]).

### Colour: `ColorConfig` over OpenColorIO

`ColorConfig` wraps an OpenColorIO configuration, loaded from `$OCIO` or a named file
on first use, and hands out `ColorProcessor` handles that IBA's `colorconvert`,
`ociodisplay` and `ociolook` apply ([`color.h`][color]). At this revision OCIO is
required by the CMake build (`checked_find_package (OpenColorIO REQUIRED` with
`VERSION_MIN 2.3`, [`externalpackages.cmake`][cmake-ocio]), although the class comment
still describes a fallback _"If OpenColorIO is not enabled at build time"_. The
implementation unconditionally includes the OCIO header and CMake links its target;
that fallback comment does not describe this build ([`color_ocio.cpp`][color-include],
[`CMakeLists.txt`][color-link]). The environment variable `OIIO_DISABLE_OCIO`
remains as a runtime switch ([`color_ocio.cpp`][color-ocio]). A config's colour spaces are matched against built-in
ones by transforming test colours and checking for an identity result
(`check_same_as_builtin_transform`, [`color_ocio.cpp`][color-builtin]), and 3.1–3.2
added lookups from a colour space to its Color Interop Forum identifier, CICP code,
chromaticities and pure-gamma exponent ([`color.h`][color-interop]).

---

## Analysis

### 1. Pixel and memory model

The model is a dense 2-D or 3-D box of interleaved channels with byte strides
(see [Stride][related-4] and [Tiling][related-5]). Tiles are a
property of the **file** (`tile_width` etc.); in memory, `ImageBuf` is a single strided
block or a cache-backed view. A data window can sit anywhere in a signed `int`
coordinate space and need not match the display window; `check_open` rejects an origin
whose `origin + size` would overflow `int` ([`imageinput.cpp`][checkopen-impl]).
Planar files are normally interleaved by the plugin (the `planarconfig` attribute
records the file's layout), and subsampled channels are upsampled. There is no
description for independently sized planes or chroma subsampling
([`oiiointro.md`][intro]). Bit depths below 8 are widened to
`UINT8`, with `oiio:BitsPerSample` recording the original ([`stdmetadata.md`][meta-hints]).

`image_span<T, Rank>` (3.1) is the new non-owning view: channel, x, y, z sizes as
`uint32_t` and byte strides as `int64_t`, rank 2 to 4 with channels as the first
dimension ([`image_span.h`][imagespan]). Its channel stride can describe planar memory
when channels have the same dimensions; this does not give planes independent extents.
It is the bounded replacement for raw pointers
in `read_image` and the `ImageBuf` constructors. Deep images are a separate
`DeepData` object holding a per-pixel sample count and per-channel types
([`deepdata.h`][deepdata]); `ImageSpec::deep` flags them. Compare the compile-time view
of [Boost.GIL][related-1] and the N-D view of
[mir-algorithm][related-6]: OIIO supports at most three spatial dimensions.
`image_span<T, Rank>` itself has a compile-time element type and rank; the
plugin seam uses `image_span<std::byte>` with a separate runtime `TypeDesc`.

### 2. Genericity mechanism

Two mechanisms meet at one seam. At the plugin seam the description is **runtime**: virtual
plugin classes, `TypeDesc` values, string-keyed `supports()` queries and named
attributes. Inside IBA it is **C++ templates**, reached in common-type kernels
through the `OIIO_DISPATCH_COMMON_TYPES*` switch over four common types with a float round-trip for the rest
([`imagebufalgo_util.h`][ibautil-dispatch]). The cost of that bridge is a closed
instantiation list (`float`, `uint8`, `half`, `uint16`) and a full
copy for `int16`, `uint32` or `double` images on those paths. Other macros support
those types directly ([`imagebufalgo_util.h`][iba-alltypes]). It is the same trade
[Boost.GIL's `any_image`][related-1] makes with a variant, done here with macros.
Capability discovery by string (`supports("ioproxy")`) is a run-time analogue of design
by introspection: the caller asks the object what it can do, and the vocabulary grows
without breaking the ABI.

### 3. Colour and metadata

Colour identity is one string attribute, `oiio:ColorSpace`, whose values are Color
Interop Forum tokens (`lin_rec709_scene`, `srgb_rec709_display`, `lin_ap1_scene`, ...)
or any OCIO name, alias or role ([`stdmetadata.md`][meta-colour]). Beside it sit
`CICP` (`int[4]`, H.273), the ten `mdcv_*` mastering-display integers and `ICCProfile`
as a raw `uint8[]` blob; decoded `ICCProfile:...` fields are informational only, and
the doc says setting them does not change the blob, _"the sole piece of durable ICC
profile information"_ ([`stdmetadata.md`][meta-cicp]). See
[CICP][related-7] and [ICC profile][related-8]. Alpha state is
a flag: `oiio:UnassociatedAlpha` says the file stored straight alpha, and readers
premultiply by default unless the `oiio:UnassociatedAlpha` configuration hint asks them
not to ([`imageinput.md`][ii-alpha]; [Straight and premultiplied alpha][related-9]).

Metadata is a flat `ParamValueList` of `(name, TypeDesc, value)`, values up to
16 bytes stored inline and larger ones on the heap ([`paramlist.h`][paramlist]).
Namespaces are name prefixes: unprefixed names are the cross-format standard set
(`ImageDescription`, `Orientation`, `Make`), `Exif:` and `GPS:` mirror EXIF tags,
`IPTC:` the IIM fields, `oiio:` library hints, and every format its own prefix
(`jpeg:subsampling`, `gif:LoopCount`); plugin authors are told to prefix their names
_"much like the `"Exif:"` and `"IPTC:"` metadata"_ ([`stdmetadata.md`][meta-ext]).
EXIF, IPTC IIM and XMP are decoded by shared helpers (`decode_exif`, `decode_iptc_iim`,
`decode_xmp`) into that flat list ([`tiffutils.h`][tiffutils]).

**Verified (release 3.1.7.0).** `oiiotool --create 32x16 3 --attrib Exif:FocalLength
45.7 --attrib IPTC:City Sofia --attrib Make Probe --attrib Orientation 6 -o m.jpg`,
read back with `iinfo -v`, lists `Make`, `Orientation: 6 (rotated 90 deg CW)`,
`Exif:FocalLength: 45.7 (45.7 mm)`, `IPTC:City: "Sofia"`, `jpeg:subsampling: "4:2:0"`
and `oiio:ColorSpace: "srgb_rec709_scene"`. Converting that JPEG to PNG carried
`jpeg:subsampling` into the PNG's metadata: a format-prefixed attribute outlived its
format. Writing `myapp:note` (string) and `myapp:count` (int) to three formats kept both
in OpenEXR, only the string in PNG, and neither in TIFF as exposed by `iinfo -v`.
These results reproduced on November 14, 2026; the TIFF observation establishes
loss through OIIO's metadata interface, not the absence of every possible raw-file
encoding. Arbitrary metadata survival is
per plugin, which is what `supports("arbitrary_metadata")` advertises.

### 4. I/O and codec architecture

Decoding is **pull** and **random access**: the client asks for scanlines, tiles or a
region by coordinate, at any subimage and MIP level, and the plugin seeks or re-reads
to satisfy it ([Push and pull decoding][related-10]). There is
no incremental feed and no suspension: `read_*` blocks until the bytes are decoded, and
a backward scanline request may require reopening a sequential format. A truly
non-seekable source need not support that fallback. The byte source is `IOProxy`,
whose `pread` is positional and thread-safe, so a cache can issue concurrent tile reads
on one file ([`filesystem.h`][ioproxy]). The API takes "fully elaborated,
non-compressed data" only; the compressed bitstream never crosses the API, so there is
no passthrough of a JPEG or a block-compressed texture
([`oiiointro.md`][intro]). A `ProgressCallback` returning `true` cancels a whole-image
read or write at the chunk boundaries the base class loops over
([`imageio.h`][stride]). Format detection is extension first, then `valid_file()`
probes of every plugin when `try_all_readers` is on ([`imageioplugin.cpp`][plugin-try]).
Compare the [VIGRA scanline seam][related-2] and the
[suspendable-decoding concept][related-11],
which OIIO does not attempt.

### 5. Hostile input and safety

OIIO's defences are runtime checks in the base class, tuned by global attributes, with
defaults in `imageio.cpp` ([`imageio.cpp`][globals]):

```cpp
// src/libOpenImageIO/imageio.cpp
int limit_channels(1024);
int limit_imagesize_MB(std::min(32 * 1024,
                                int(Sysutil::physical_memory() >> 20)));
int limit_resolution(1 << 20);  // max pixels along any single dimension
```

Every plugin's `open()` is expected to call `check_open(spec, range)` before it
allocates, where `range` is the format's own ceiling (PNG passes `1 << 30` per side and
4 channels). The checks, in order: non-empty resolution, the format range,
`limits:channels`, `limits:resolution` per dimension, `limits:imagesize_MB` on
the whole image, origin-plus-size overflow, non-negative and in-range tile sizes,
display-window sanity, then `limits:imagesize_MB` again on the whole image and
on one tile
([`imageinput.cpp`][checkopen-impl]). A comment says memory tests go last because the
default _"depends on the machine's physical memory, so doing the deterministic checks
first ensures a corrupt file fails the same way on every machine."_ The earlier
whole-image size test contradicts that ordering guarantee: it can fire before the
origin, tile and display-window checks. Of 30 file-reader plugin directories,
29 call the reader's `check_open`; `ptex.imageio` is the exception. The other two
directories are write-only `term` and procedural `null`, which also calls the
reader's guard ([`nullimageio.cpp`][null-checkopen]).

The pinned revision adds a second guard against decompression bombs,
`check_compression_ratio(declared_bytes, filesize)`, which fails a header claiming more
than 10000 times the file size when the claim is at least 1 GiB, with these default
thresholds overridable by each caller
([`imageio.h`][ratio-doc], [`imageinput.cpp`][ratio-impl]); 25 plugin directories call
it. Bounded `image_span` reads check the span size at run time (`check_span_size`,
[`imageinput.cpp`][readimage-span]); `image_span`'s `span<T>`-based constructor fit check is an
`OIIO_DASSERT`, compiled out under `NDEBUG` ([`image_span.h`][imagespan],
[`dassert.h`][dassert]). Element access instead uses `OIIO_CONTRACT_ASSERT`,
enforced by default even under `NDEBUG`; neither proves that caller-declared
dimensions fit the actual allocation ([`image_span.h`][span-access],
[`dassert.h`][contracts]).

**Verified (release 3.1.7.0).** With `--oiioattrib limits:imagesize_MB 16`, opening a
2048 × 2048 four-channel float TIFF failed at open, even for `--info`, with
_"Uncompressed image size 64.0 MB exceeds the 16 MB limit. ... Possible corrupt
input?"_. The 353-byte `testsuite/png-bomb/src/bomb.png` (an IHDR declaring
46340 × 46340 × 3) **opened** under 3.1.7.0 and reported its size, because about 6 GiB is under
that machine's default limit; the pinned revision's reference output expects
_"png header claims a 6143 MB image from a 353 byte file; probably a corrupt or
malicious header"_ ([`png-bomb/ref/out.txt`][pngbomb-ref]). The ratio check is the
difference. Both 3.1.7.0 results reproduced on November 14, 2026 using
`oiiotool --oiioattrib limits:imagesize_MB 16 --info -v large.tif` and
`oiiotool --info -v bomb.png`; the latter checks the header, not pixel decoding.

The limits are **process-global** and bound declared size, not work: there is no
per-call budget, no time or operation limit, and decoding is in C and C++ (`libpng`,
`libjpeg-turbo`, `libtiff`, OpenEXR) with no memory-safe core. See
[Hostile input][related-12] and the
[hostile-input paper thread][p-hostile].

### 6. Allocation and ownership

Ownership is C++ RAII with heap allocation throughout. Readers and writers are
`std::unique_ptr` with a custom deleter; `ImageCache::create` and
`TextureSystem::create` return `std::shared_ptr` (`OIIO_IMAGECACHE_CREATE_SHARED`);
tiles are intrusively ref-counted (`RefCnt`), and a tile stays alive while a thread's
microcache holds a reference ([`imagecache_pvt.h`][icpvt-tile],
[`imagecache_pvt.h`][icpvt-thread]). The conversion path allocates a native scratch buffer per
call with `new std::byte[]` ([`imageinput.cpp`][readscan]); the texture filter uses
`OIIO_ALLOCA` for its per-lookup sample arrays ([`texturesys.cpp`][texsys-lookup]).
`ImageBuf` either owns (`LOCALBUFFER`), borrows (`APPBUFFER`, the caller keeps
ownership) or defers to the cache (`IMAGECACHE`), and a write to a cache-backed buffer
pulls the whole image into memory permanently ([`imagebuf.h`][imagebuf]). Errors are
strings: each object has `geterror()`, and failures before an object exists go to a
per-thread global, _"separate threads will not clobber each other's global error
messages"_ ([`imageio.h`][geterror]). There is no typed error value.

### 7. CPU parallelism and SIMD

Threading is a process-wide pool sized by the `threads` attribute (default: core
count), with optional TBB (`paropt::ParStrategy::TryTBB`, off unless enabled)
([`thread.cpp`][tbb], [`parallel.h`][paropt]). `parallel_image` splits an `ROI` into
bands (Y by default; X, tile or longest-edge on request) and limits thread count
using `minitems` (1024 for the default `paropt` constructor, despite the loop's
16k comment, _"or it's not worth the thread startup/teardown cost"_)
([`parallel.h`][paropt], [`imagebufalgo_util.h`][ibautil-par]). Readers convert
chunks with `parallel_convert_image`; `ImageInput::threads(n)` caps a reader's
internal parallelism. The cache is designed for many shading threads: sharded maps,
per-thread microcaches and a single sweeper.

SIMD comes in two layers. `simd.h` is OIIO's own wrapper (`vfloat4`, `vfloat8`,
`vfloat16`, `vint4`, ...) whose width is fixed **at compile time** from the compiler's
predefined macros (`__SSE4_1__`, `__AVX2__`, `__AVX512F__`) ([`simd.h`][simd]); the
texture batch width is a build constant. Google Highway is an optional, newer back end
for a handful of IBA kernels (in `imagebufalgo_addsub.cpp`, `_muldiv.cpp`, `_mad.cpp`
and the resampling path of `_xform.cpp`), behind both
a build option and a runtime flag that defaults off: _"While we're still testing,
default to disabled"_ (`OPENIMAGEIO_ENABLE_HWY`, [`imageio.cpp`][globals]). It uses the
static `hwy::HWY_NAMESPACE` target, not Highway's dynamic dispatch
([`imagebufalgo_hwy_pvt.h`][hwy]). Most entry points use `HwySupports`: matching
type, expected channel count, contiguous scanlines, 2-D, in-memory
([`imagebufalgo_hwy_pvt.h`][hwy-sup]). Some also support an RGB region in RGBA;
the constant-multiply branch tests only `localpixels()` and does not use that
guard ([`imagebufalgo_muldiv.cpp`][hwy-mul]). Interpolating `resample` selects
the Highway path; nearest-neighbour sampling does not ([`imagebufalgo_xform.cpp`][hwy-resample]).
`platform.h` has `cpuid`-based `cpu_has_sse2()` ... `cpu_has_avx512f()` probes, but a
grep of `src/` found them used only in `imageio.cpp` to build a reported capability
list ([`imageio.cpp`][hwcaps]), not to select kernels. No performance figures are given
here; none were measured.

### 8. GPU offload and interop

The image algorithms have no general GPU compute backend. The `OIIO_HOSTDEVICE` macro expands to `__host__ __device__` under
`__CUDACC__`, so `TypeDesc`, `ustring` hashes, `fmath.h` helpers and parts of
`texture.h` can be compiled into CUDA code ([`platform.h`][hostdevice]); the
image-processing library has no corresponding device launch path. A prototype in
the test suite, `testsuite/texture-device/`, whose `SPEC.md` describes a texture system
for "the device" behind a `MockDevice` whose `copy_to`/`copy_from` _"will just be
`memcpy`"_, with a kernel-side binary that _"must **not** link against OIIO"_ so that
CMake enforces independence from the host library ([`SPEC.md`][texdev]). This is
a host C++ build gate, not proof of actual CUDA compilation; the prototype runs
on `MockDevice` and its CUDA arena is a sketch ([`README.md`][texdev-readme]).
The viewer `iv` does run GLSL colour processing, including gain/gamma and OCIO
display/view transforms ([`ivgl.cpp`][iv-gamma], [`ivgl_ocio.cpp`][iv-ocio]).
There is no GPU decode or GPU texture format output. `maketx` requires a tiled-output
plugin (TIFF and OpenEXR are examples), rather than producing BCn blocks
([`maketexture.cpp`][maketx-output]). There is no Vulkan, Metal or
staging-buffer interop ([Staging and upload][related-13]).

### 9. Temporal, animation and containers

Time is modelled as **subimages**. Animated GIF, animated WebP and FFmpeg movies present
each frame as a subimage. `oiio:Movie` identifies a time sequence;
`FramesPerSecond` is a `TypeRational` ([`stdmetadata.md`][meta-movie]). The GIF reader
turns a nonzero frame delay into a per-subimage rate, `{ 100, delay }`
([`gifinput.cpp`][gif]); WebP sets the movie flag and loop count but exposes no
frame-rate or duration attribute ([`webpinput.cpp`][webp-time]). FFmpeg's reader
reports the stream rate and `oiio:subimages` frame count, and stores a timecode as
`ffmpeg:TimeCode` ([`ffmpeginput.cpp`][ffmpeg]). There is no standardized per-frame
presentation timestamp exposed by this image API, no
audio, no seeking by time and no container model separate from the image: the intro's
_"not as movies per se"_ is literal. MIP levels are a second index under each subimage,
and multi-part OpenEXR maps to subimages too.

### 10. Testing and conformance

Three layers.

- **Unit tests**: 29 `*_test.cpp` files under `src/` (for example `imagespec_test.cpp`,
  `imagebufalgo_test.cpp`), using OIIO's own `unittest.h`.
- **The `testsuite/`**: 159 directories with a `run.py` at the pinned revision
  (counted with `git ls-tree -r --name-only`), driving the
  command-line tools and a `ref/` of expected text and images. `runtest.py` compares
  text exactly and images with `idiff`, and a test passes if its output matches **any**
  file named `ref/<name>` or matching `ref/<stem>-*<extension>*` (platform and library-version variants such as
  `out-libpng15.txt`) ([`runtest.py`][runtest-ref], [`TESTSUITE-README.md`][tsreadme]).
  The default image tolerance fails when more than 0.02 % of pixels have a channel
  exceeding both absolute error `0.004` and relative error `0.001`; the relative
  error divides by the mean absolute magnitude of the pair. A maximum error above
  `0.012` also fails. `CI` or `DEBUG` doubles the absolute threshold, allowed
  percentage and hard ceiling, but not the relative threshold
  ([`runtest.py`][runtest], [`runtest.py`][runtest-ci], [`idiff.cpp`][idiff-rule],
  [`imagebufalgo_compare.cpp`][compare-rule]). Large
  sample images live in separate repositories (`oiio-images`, `openexr-images`) that
  `runtest.py` expects as sibling checkouts (`../oiio-images`) or through
  `OIIO_TESTSUITE_IMAGEDIR`, and tests whose images are absent are not added
  ([`testing.cmake`][testing-cmake]). Format-hostility tests are
  ordinary test directories: `png-bomb`, `png-damaged`, `openexr-bomb` (`bomb.exr`,
  `bigtile.exr`, `bigdisplay.exr`, `bigattr.exr`), `jpeg-corrupt`, `openvdb-damaged`.
- **Fuzzing**: one libFuzzer target, `fuzz_image.cpp`, opens the input through
  `IOMemReader` and reads every subimage and MIP level as `UINT8`; the format is fixed per
  process; RAW and FFmpeg use a temporary file instead ([`fuzz_image.cpp`][fuzz],
  [`fuzz_image.cpp`][fuzz-dispatch]).
  Its initialiser forces one thread and lowers the limits under the fuzzer's own
  RSS budget, because _"OIIO's default decode-bomb guards ... are far larger than that
  budget, so a corrupt header claiming a multi-GB image would trip the fuzzer's OOM kill
  *before* OIIO's own guard rejects it"_ ([`fuzz_image.cpp`][fuzz]). A nightly workflow
  runs each format for 60 minutes (tier 1: OpenEXR, TIFF, JPEG, PNG, DPX, PSD, HEIF, JPEG
  XL, JPEG 2000, RAW) or 30 minutes (tier 2), seeded from `oiio-images`
  ([`fuzz.yml`][fuzz-yml], [`build-steps.yml`][fuzz-seeds]).

`idiff` is the comparison oracle and a reusable tool: `-fail`, `-failpercent`,
`-failrelative`, `-hardfail`, `-allowfailures`, the matching `-warn` set, `-p` for a
perceptual test (`compare_Yee`), and `-o` to write a scaled difference image
([`idiff.cpp`][idiff]). It reports `CompareResults` (mean, RMS, PSNR, max error and its
location, warn and fail counts) from `ImageBufAlgo::compare` ([`imagebufalgo.h`][compare]).

**Verified (release 3.1.7.0; reproduced November 14, 2026).** With the test suite's
absolute threshold, failure percentage and hard ceiling
(`-fail 0.004 -failpercent 0.02 -hardfail 0.012 -warn 0.008`; this probe omits the
suite's `-failrelative 0.001`), two 64 × 64 float
images differing by `0.003` in red compared as `PASS` (exit 0); differing by `0.02` they
reported `Peak SNR = 38.7506`, `Max error = 0.02 @ (0, 0, R)`, 100 % of pixels over the
threshold and `FAILURE` (exit 2).

---

## Lessons for Sparkles

- **Q1** — One erased description (`ImageSpec`: data window, display window, tiles,
  channel names, per-channel types, deep flag, named extras) carries OIIO's whole format
  set, at the cost of a fixed rank and `int` coordinates. That is evidence for the
  **runtime interchange type** the [existing-code baseline][bl-existing] leaves open (G2,
  design question 2: what a plugin returns, the registry stores and an upload reads), and
  against it as a kernel type, since its element type is a value. A D version would use
  `size_t` extents and `ptrdiff_t` byte strides; `image_span`'s channel-first, byte-stride
  layout matches the byte-stride argument in [VIGRA][related-2]'s lessons. Its
  constructor-fit assertion is debug-only, while element-access contracts are
  enforced by default in release builds. Sparkles' `checked` build keeps assertions
  and array bounds checks in shipped artifacts. Neither language can infer an
  allocation's true size from a raw pointer. The data/display window pair covers
  crops, overscan and tiled reassembly; the baseline's `ImagePixels` has no
  data/display-window origin.
- **Q2** — String-keyed `supports()` queries are run-time design by introspection that
  keeps a plugin ABI stable. For compile-time codecs the D form is
  `static if (__traits(hasMember, Codec, "readTile"))`; for codecs found at run time
  (option B of the baseline's design question 4) a capability enum or bit set would
  catch the typo that `supports("ioproxi")` silently answers with 0.
- **Q2/Q3** — IBA's common-type kernels show the price of erasing types at the
  algorithm boundary: a four-type vocabulary and a silent full-image `float` copy
  for anything else. Other dispatch paths instantiate more types directly. The D
  equivalents are a `static foreach` over an `AliasSeq` (adding `ushort` is one edit, not
  a macro) and an explicit rejection in place of the copy. This bears on the
  [shaders-simd baseline][bl-shaders] G3 (no byte or half types) and G10 (no view type).
- **Q4** — Random-access pull with silent reopen-and-rescan suits a cache and hides
  unbounded rereads from a hostile-input budget; [existing-code][bl-existing] G7
  (whole-file, single-shot) and [wired][bl-wired] G3 (no suspendable decode) sit at the
  other end. What transfers is the split: native read primitives per plugin
  (`read_native_tile`, `read_native_scanline`) with conversion, channel subsetting and
  chunking written once above it, which in D could be a generic `@nogc` layer writing
  into caller storage or an output range.
- **Q4/Q6** — `IOProxy`'s positional, thread-safe `pread` is what lets a cache fetch
  tiles of one file concurrently, and it is the ranged-read layer the
  [event-horizon baseline][bl-eh] G1 says is missing. Its blocking virtual call does not
  fit a completion loop as is; the completion-shaped form takes a buffer and an offset
  and completes with an `Expected` later.
- **Q5** — The metadata model (flat `name → (TypeDesc, value)`, prefixes as namespaces,
  ICC as an opaque blob with read-only decoded mirrors, CICP and mastering-display as
  integers) is close to the minimum [existing-code][bl-existing] G4 and G5 ask for. The
  verified runs show its two hazards: `jpeg:subsampling` survives into a PNG, and some
  writers drop arbitrary attributes without an error. Colour identity as one Color
  Interop Forum token plus CICP answers the baseline's design question 3 with data, not
  types; OIIO needs OCIO to interpret most names, and OCIO is the piece with no `@nogc`,
  betterC or wasm counterpart ([existing-code][bl-existing] G12).
- **Q5/Q8** — `limits:imagesize_MB` defaults to `min(32 GiB, physical memory)`, so the
  same file can pass on one host and fail on another. The source comment promises
  deterministic checks first, but an early memory check violates that order. The
  alternative is a limit value passed to the decoder
  with fixed defaults, as the [hostile-input thread][p-hostile] asks ("expose resource
  limits (max pixels, max bytes, max frames) in the public API"); a value also suits
  `@safe pure` decoders, which cannot read mutable globals.
- **Q8** — Library limits must sit below the fuzzer's memory budget, or bombs surface as
  fuzzer OOMs instead of clean rejections; `OIIO_FUZZ_INIT` lowers them for that reason,
  and bomb files are kept as named tests (`png-bomb`, `openexr-bomb`). No fuzz harness
  exists in Sparkles yet ([existing-code][bl-existing] G11).
- **Q8** — `idiff`'s rule (per-value threshold, allowed fraction, hard ceiling, plus a
  difference image) and `CompareResults` fit option B of the baseline's design question 9.
  The parts to weigh are the "any matching reference variant" policy, which lets
  variants drift apart, and CI-wide doubling of the absolute threshold, failure
  percentage and hard ceiling while the relative threshold stays fixed.
- **Q6/Q7** — The cache (sharded maps, a CLOCK sweep with one non-blocking sweeper,
  per-thread two-tile microcaches, open-file limits) is the most transferable subsystem
  for a viewer, and lines up with `sparkles.base.pool` handles and the `IMG3` registry
  contract ([existing-code][bl-existing]). Its blocking read on the shading thread does
  not transfer: a miss in Sparkles would be an `event-horizon` read and a deferred upload
  under `UVK29`'s per-frame budget ([Vulkan baseline][bl-vk]).
- **Q7** — OIIO selects SIMD at compile time (`simd.h` widths from compiler macros,
  Highway's static target) and ships its Highway path disabled, so it is no evidence for
  runtime dispatch; the repository's BLAKE3 pattern ([shaders-simd][bl-shaders] G5) is
  the nearer precedent. With no general IBA GPU backend it says nothing about the SIMD-versus-GPU
  break-even, beyond the `texture-device` rule that device code must compile without
  linking the host library.
- **Q9** — OIIO is one project with two libraries (`OpenImageIO_Util`: `TypeDesc`,
  `ustring`, threads, `IOProxy`; `OpenImageIO`: the rest) and formats as embedded or
  loadable plugins. The description layer is separately linkable and annotated for CUDA
  device compilation (`OIIO_HOSTDEVICE`). Algorithms are not separable from I/O:
  `ImageBuf` reads files lazily, so IBA depends on the plugin layer.

## Strengths

- One description (`ImageSpec`) covers tiles, volumes, subimages, MIP levels, deep
  data, per-channel types and windows, so tools such as `oiiotool` and `iinfo` share
  an interface across formats.
- Conversion on read to supported numeric types and byte strides, implemented once in the base
  class; plugins write only native primitives.
- A production tile cache and texture filter with a tunable approximate memory
  target (verified: a 64 MiB sweep peaked at 256 tiles with a 16 MiB setting)
  and documented concurrency design.
- Decode limits as named, tunable attributes, checked in a shared `check_open` that
  almost every plugin calls, plus a compression-ratio guard against bombs.
- A documented, prefix-namespaced metadata vocabulary with EXIF, IPTC, XMP, CICP,
  mastering-display and ICC conventions in one chapter.
- A large regression suite with tolerant image comparison, explicit bomb and damage
  tests, and nightly per-format fuzzing.

## Weaknesses

- Element type is erased at the plugin seam; common-type IBA paths recover it through
  a four-type switch, with a full float copy for other types on those paths.
- Fixed rank (at most x, y, z plus channels), `int` coordinates, no independently sized planes or
  chroma-subsampled layouts, no sub-byte samples: video and scientific layouts are
  converted, not represented.
- Pull, blocking, random-access decoding only; no incremental feed, no suspension,
  sequential formats rescanned on backward seeks.
- Decode limits and the default thread count are process-global; operations can
  override thread counts. Memory defaults depend on the host.
- Errors are strings; there is no typed error to branch on.
- C and C++ codecs underneath; the safety story is runtime checks and fuzzing, not a
  memory-safe core.
- Metadata survival is per plugin and silent, and format-prefixed attributes can leak
  across formats (verified on 3.1.7.0).
- No general GPU compute or decode backend; the viewer's GLSL colour processing
  is separate. SIMD selection is compile-time, and the Highway path is off by default.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                   | Trade-off                                                                     |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Runtime `TypeDesc` instead of a pixel type parameter              | One API and ABI across all formats, plugins and languages (Python bindings) | Kernels need dispatch; common-type paths convert uncommon types to `float`    |
| Few fixed client-side assumptions (RGB order, upsampled channels) | Keeps the API small; exotic features stay inside plugins                    | No independently sized planes, sub-byte samples or compressed blocks          |
| Capability queries and options by string                          | Adding capability names preserves the query interface                       | Typos fail silently; no compile-time checking of names                        |
| Random-access pull reads with reopen-and-rescan                   | Callers and the cache need any tile at any time                             | Hidden, unbounded rereads for sequential formats; not suspendable             |
| Conversion and chunking in the base class                         | Plugins implement native read primitives                                    | A heap scratch buffer per converting call and an extra copy                   |
| Global `limits:*` attributes checked in `check_open`              | One guard for every plugin; tunable without recompiling                     | Process-wide state; host-dependent default for image size                     |
| CLOCK eviction with a non-blocking single sweeper                 | Low contention for many shading threads                                     | Memory can exceed the budget transiently; 10 MB floor in release builds       |
| Metadata as a flat, prefix-namespaced attribute list              | Any format's fields fit without schema changes                              | Survival is per writer and silent; prefixes do not stop cross-format leaks    |
| OpenColorIO as the colour engine                                  | Studio-controlled colour math via `$OCIO` configs                           | Required by CMake; most colour names need a config                            |
| Image tolerance by threshold, percentage and hard ceiling         | Lossy decoders and platforms differ by low bits                             | CI doubles absolute, percentage and hard limits; reference variants can drift |

## Sources

- [AcademySoftwareFoundation/OpenImageIO][repo] at `e7eb5d109`, its [documentation][docs]
  and [`LICENSE.md`][license]; the manual's [introduction][intro] and
  [metadata conventions][meta-colour] (`src/doc/`).
- Public headers in `src/include/OpenImageIO/`: [`imageio.h`][spec], [`typedesc.h`][typedesc],
  [`image_span.h`][imagespan], [`paramlist.h`][paramlist], [`deepdata.h`][deepdata],
  [`filesystem.h`][ioproxy], [`tiffutils.h`][tiffutils], [`imagebuf.h`][imagebuf],
  [`imagebufalgo_util.h`][ibautil-dispatch], [`imagebufalgo.h`][compare],
  [`imagecache.h`][ic-doc], [`texture.h`][tex-modes], [`color.h`][color], [`simd.h`][simd],
  [`parallel.h`][paropt], [`platform.h`][hostdevice], [`dassert.h`][dassert].
- Implementation: [`imageinput.cpp`][checkopen-impl], [`imageio.cpp`][globals],
  [`imageioplugin.cpp`][plugin], [`imagebufalgo_mad.cpp`][mad],
  [`imagebufalgo_hwy_pvt.h`][hwy], [`color_ocio.cpp`][color-ocio],
  [`imagecache.cpp`][ic-sweep], [`imagecache_pvt.h`][icpvt-tile],
  [`texturesys.cpp`][texsys-lookup], [`thread.cpp`][tbb], and the
  [PNG][pnginput], [GIF][gif] and [FFmpeg][ffmpeg] plugins.
- Build and test: [`externalpackages.cmake`][cmake-ocio], [`testing.cmake`][testing-cmake],
  [`fuzz_image.cpp`][fuzz], [`fuzz.yml`][fuzz-yml], [`runtest.py`][runtest],
  [`TESTSUITE-README.md`][tsreadme], [`png-bomb` reference output][pngbomb-ref],
  [`idiff.cpp`][idiff], [`texture-device/SPEC.md`][texdev].
- Runs (release `3.1.7.0` from nixpkgs, scratch directory): `oiiotool` and `iinfo`
  metadata round-trips, the `limits:imagesize_MB` rejection and the `bomb.png` open,
  `idiff` at the test suite's thresholds, and a C++ `ImageCache` sweep at three budgets.
- Related Sparkles research: [concepts][related-14] · [Boost.GIL][related-1] ·
  [VIGRA][related-2] · [color][related-15] ·
  [mir-algorithm][related-6] · [hostile-input thread][p-hostile] ·
  [resampling-colour thread][p-colour] · baselines: [existing code][bl-existing],
  [shaders and SIMD][bl-shaders], [event-horizon][bl-eh], [wired][bl-wired], [Vulkan][bl-vk]

<!-- References -->

[repo]: https://github.com/AcademySoftwareFoundation/OpenImageIO
[docs]: https://openimageio.readthedocs.io/
[license]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/LICENSE.md
[readme]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/README.md#L16-L19
[readme-ic]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/README.md#L55-L63
[intro]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/oiiointro.md#L56-L124
[meta-colour]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/stdmetadata.md#L219-L245
[meta-cicp]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/stdmetadata.md#L257-L310
[meta-hints]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/stdmetadata.md#L314-L352
[meta-movie]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/stdmetadata.md#L160-L213
[meta-ext]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/stdmetadata.md#L1539-L1545
[spec]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L251-L313
[roi]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L88-L140
[sizes]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L400-L466
[stride]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L47-L82
[supports-in]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L1094-L1153
[read-span]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L1372-L1446
[ratio-doc]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L2288-L2393
[out-supports]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L2510-L2640
[out-open]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L2643-L2662
[geterror]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L3796-L3806
[typedesc]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/typedesc.h#L40-L131
[imagespan]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/image_span.h#L16-L108
[dassert]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/dassert.h#L199-L212
[paramlist]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/paramlist.h#L349-L359
[deepdata]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/deepdata.h#L18-L110
[ioproxy]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/filesystem.h#L424-L475
[tiffutils]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/tiffutils.h#L176-L241
[hostdevice]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/platform.h#L550-L558
[readscan]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageinput.cpp#L395-L520
[readimage-span]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageinput.cpp#L1253-L1328
[checkopen-impl]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageinput.cpp#L1707-L1891
[ratio-impl]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageinput.cpp#L1895-L1909
[globals]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageio.cpp#L38-L68
[hwcaps]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageio.cpp#L166-L195
[plugin]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageioplugin.cpp#L256-L305
[plugin-create]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageioplugin.cpp#L608-L720
[plugin-try]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imageioplugin.cpp#L721-L795
[pnginput]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/png.imageio/pnginput.cpp#L115-L134
[imagebuf]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagebuf.h#L60-L148
[ibautil-par]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagebufalgo_util.h#L25-L80
[ibautil-prep]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagebufalgo_util.h#L188-L250
[ibautil-dispatch]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagebufalgo_util.h#L461-L549
[mad]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imagebufalgo_mad.cpp#L29-L91
[hwy]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imagebufalgo_hwy_pvt.h#L13-L21
[hwy-sup]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imagebufalgo_hwy_pvt.h#L95-L116
[simd]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/simd.h#L148-L210
[paropt]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/parallel.h#L77-L103
[tbb]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libutil/thread.cpp#L660-L676
[compare]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagebufalgo.h#L1537-L1560
[ic-doc]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagecache.h#L31-L35
[ic-attrs]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagecache.h#L86-L153
[ic-dedup]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagecache.h#L185-L192
[ic-tile]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagecache.h#L1205-L1234
[icpvt-shards]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/imagecache_pvt.h#L35-L36
[icpvt-tile]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/imagecache_pvt.h#L746-L826
[icpvt-thread]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/imagecache_pvt.h#L869-L901
[ic-mem]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/imagecache.cpp#L2504-L2519
[ic-sweep]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/imagecache.cpp#L2912-L2988
[tex-modes]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/texture.h#L105-L136
[tex-api]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/texture.h#L860-L907
[tex-batch]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/texture.h#L280-L305
[texsys-lookup]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/texturesys.cpp#L2264-L2320
[texsys-ellipse]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/texturesys.cpp#L2196-L2236
[color]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/color.h#L66-L96
[color-interop]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/color.h#L439-L477
[color-ocio]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L56-L68
[color-builtin]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L594-L611
[cmake-ocio]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/cmake/externalpackages.cmake#L174-L177
[gif]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/gif.imageio/gifinput.cpp#L259-L279
[ffmpeg]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/ffmpeg.imageio/ffmpeginput.cpp#L628-L636
[ii-alpha]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/doc/imageinput.md#L900-L905
[fuzz]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/fuzz/fuzz_image.cpp#L22-L66
[fuzz-yml]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/.github/workflows/fuzz.yml#L8-L63
[runtest]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/runtest.py#L145-L153
[runtest-ref]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/runtest.py#L398-L433
[runtest-ci]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/runtest.py#L533-L538
[tsreadme]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/TESTSUITE-README.md#L30-L46
[pngbomb-ref]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/png-bomb/ref/out.txt
[testing-cmake]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/cmake/testing.cmake#L120-L130
[idiff]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/idiff/idiff.cpp#L56-L110
[texdev]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/texture-device/SPEC.md#L1-L40
[native-contract]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imageio.h#L1973-L2012
[iba-alltypes]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/imagebufalgo_util.h#L274-L306
[ic-tile-memory]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/imagecache.cpp#L1870-L1898
[null-checkopen]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/null.imageio/nullimageio.cpp#L321-L330
[hwy-mul]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imagebufalgo_muldiv.cpp#L173-L205
[hwy-resample]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imagebufalgo_xform.cpp#L1651-L1664
[texdev-readme]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/testsuite/texture-device/README.md#L50-L58
[iv-gamma]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/iv/ivgl.cpp#L194-L207
[iv-ocio]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/iv/ivgl_ocio.cpp#L73-L124
[webp-time]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/webp.imageio/webpinput.cpp#L189-L204
[idiff-rule]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/idiff/idiff.cpp#L323-L341
[compare-rule]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/imagebufalgo_compare.cpp#L235-L260
[fuzz-dispatch]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/fuzz/fuzz_image.cpp#L69-L102
[span-access]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/image_span.h#L270-L292
[contracts]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/include/OpenImageIO/dassert.h#L37-L118
[color-include]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L27-L32
[color-link]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/CMakeLists.txt#L157-L162
[fuzz-seeds]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/.github/workflows/build-steps.yml#L281-L286
[maketx-output]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/maketexture.cpp#L1206-L1219
[texsys-miplevel]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libtexture/texturesys.cpp#L1965-L2001
[p-hostile]: ./papers/hostile-input-safety.md
[p-colour]: ./papers/resampling-colour.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[bl-wired]: ./baseline/wired.md
[bl-vk]: ./baseline/vulkan.md
[related-1]: ./boost-gil.md
[related-2]: ./vigra.md
[related-3]: #_10-testing-and-conformance
[related-4]: ./concepts.md#stride
[related-5]: ./concepts.md#tiling
[related-6]: ./mir-algorithm/index.md
[related-7]: ./concepts.md#cicp
[related-8]: ./concepts.md#icc-profile
[related-9]: ./concepts.md#straight-and-premultiplied-alpha
[related-10]: ./concepts.md#push-and-pull-decoding
[related-11]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[related-12]: ./concepts.md#hostile-input
[related-13]: ./concepts.md#staging-and-upload
[related-14]: ./concepts.md
[related-15]: ./color.md
