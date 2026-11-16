# libtiff (C)

The reference C library for TIFF, the tag-directory container behind GeoTIFF, DNG and most scientific and archival raster files, maintained since 1988 and still the decoder that GDAL, OpenImageIO, libvips, ITK and VIGRA delegate to.

| Field         | Value                                                                                                           |
| ------------- | --------------------------------------------------------------------------------------------------------------- |
| Language      | C (C99), with an optional C++ stream wrapper (`tif_stream.cxx`)                                                 |
| License       | libtiff license, a permissive BSD-style notice ([`LICENSE.md`][lic])                                            |
| Repository    | [libtiff/libtiff on GitLab][repo] (version 4.7.2 at this revision)                                              |
| Revision read | `d23249978a7a99ea2e0752a476611914501577de` (September 27, 2026)                                                 |
| Documentation | [libtiff.gitlab.io/libtiff][docs]; in-tree [`doc/libtiff.rst`][doc-layers] and [`doc/functions/`][doc-openopts] |
| Category      | Formats: container and codec registry, pull decoding by scanline, strip or tile into caller buffers             |
| Tier          | B                                                                                                               |
| Last reviewed | November 7, 2026                                                                                                |

> [!NOTE]
> Claims marked **verified** were demonstrated by probes in `/tmp/libtiff-probe/`
> (`src/gen.c` writes crafted files, `src/probe.c` reads them), linked against a static
> build of the clone at the pinned revision (CMake, zlib only, no JPEG/WebP/ZSTD/LERC),
> compiled with GCC under `-fsanitize=address,undefined`. Nixpkgs ships 4.7.1, which
> lacks the 4.7.2 compression-ratio check, so the pinned source was built instead. The
> clone is shallow, so CVE history is read from the release notes, not from commits. No
> performance number in this page was measured.

---

## Overview

### What it solves

TIFF is a container, not a codec ([concepts: container and bitstream][c-container]): a
header points to a chain of image file directories (IFDs), each a sorted list of numbered
tags, and two tag arrays point to the compressed strips or tiles. libtiff parses that
container, exposes the tags through a typed registry, and hands each strip or tile to one
of the codecs in a 21-entry built-in table (`None` included). The documentation describes the library as layered by cost
([`doc/libtiff.rst`][doc-layers]):

> _"At the highest level image data can be read into an 8-bit/sample, ABGR pixel raster
> format without regard for the underlying data organization, colorspace, or compression
> scheme. Below this high-level interface the library provides scanline-, strip-, and
> tile-oriented interfaces that return data decompressed but otherwise untransformed."_

Directories are independent images ([`doc/libtiff.rst`][doc-dirs]): _"each directory
stands on its own; there is no need to read an unrelated directory in order to properly
interpret the contents of an image."_ That independence is what lets GeoTIFF, DNG, EXIF
and pyramidal formats hang extra IFDs and private tags off one file.

### Design philosophy

The project's posture on hostile input is explicit ([`HOWTO-SECURITY-RELEASE`][sec-howto]):

> _"Libtiff can be a significant security risk as many tools use it to read TIFF files
> which can come from hostile sources."_

In 4.6.0 that posture became a scope cut: most command-line tools were archived
([`v4.6.0.rst`][rel460-warn]) _"due to the lack of contributors able to address reported
security issues"_, and `tiffcp -i` was removed _"because almost all fuzzer issues were
consequential errors from ignored errors"_ ([`v4.6.0.rst`][rel460-tiffcp]).

## How it works

**The handle.** `struct tiff` ([`tiffiop.h`][tiffiop-struct]) holds one active directory
(`tif_dir`), the I/O callbacks (`tif_readproc`, `tif_seekproc`, `tif_mapproc`), a raw
compressed-data buffer (`tif_rawdata`, `tif_rawcp`, `tif_rawcc`) and the codec as a
table of function pointers:

```c
// libtiff/tiffiop.h: compression scheme hooks (excerpt)
TIFFBoolMethod tif_setupdecode; /* called once before predecode */
TIFFPreMethod tif_predecode;    /* pre- row/strip/tile decoding */
TIFFCodeMethod tif_decoderow;   /* scanline decoding routine */
TIFFCodeMethod tif_decodestrip; /* strip decoding routine */
TIFFCodeMethod tif_decodetile;  /* tile decoding routine */
TIFFGetMaxCompressionRatioMethod tif_getmaxcompressionratio;
uint8_t *tif_data; /* compression scheme private data */
```

**Header and BigTIFF.** `TIFFHeaderClassic` is magic, version 42 and a 32-bit offset;
`TIFFHeaderBig` is magic, version 43, an offset size (8), a reserved word and a 64-bit
offset ([`tiff.h`][tiff-header]). BigTIFF changes only offset and count widths; the
`TIFF_IFD8` type lets the tag table write a 32-bit or 64-bit pointer according to the
file kind ([`tiff.h`][tiff-types]). Writers choose with the `8` mode flag.

**Directories and tags.** `TIFFDirectory` ([`tif_dir.h`][tifdir-dir]) stores the
well-known tags as typed fields (`td_imagewidth`, `td_bitspersample`, `td_sampleformat`,
`td_photometric`, `td_planarconfig`, `td_rowsperstrip`, `td_tilewidth`, `td_extrasamples`,
`td_ycbcrsubsampling`) and everything else as `td_customValues`. Each tag is described by
a `TIFFField` ([`tif_dir.h`][tifdir-field]): tag number, read and write counts
(`TIFF_VARIABLE`, `TIFF_SPP`), on-disk type, the `TIFFSetGetFieldType` used by the
variadic `TIFFGetField`, a bit in the `td_fieldsset` vector, and an optional child
`TIFFFieldArray` for tags that point at sub-IFDs (`SubIFD`, `EXIFIFDOffset`,
[`tif_dirinfo.c`][dirinfo-subifd]). Unknown tags become anonymous fields
(`_TIFFCreateAnonField`); applications add their own with `TIFFSetTagExtender`
([`tiffio.h`][tiffio-extender]) and `TIFFMergeFieldInfo` ([`tiffio.h`][tiffio-ext]).

**Strips and tiles ("striles").** A strip is `RowsPerStrip` full-width rows; a tile is a
`TileWidth` by `TileLength` (by `TileDepth`) block whose sides the default sizer rounds up
to a multiple of 16 _"per the spec"_ ([`tif_tile.c`][tile-16]). Both are addressed by one
index into the `StripOffsets`/`TileOffsets` and byte-count arrays; the struct comment
admits that _"td_stripsperimage is the number of striles (=strips or tiles) per plane"_
([`tif_dir.h`][tifdir-dir]). `TIFFComputeTile` maps (x, y, z, sample) to that index with
overflow-checked arithmetic ([`tif_tile.c`][tile-compute]).

**Planar configuration.** `PLANARCONFIG_CONTIG` interleaves samples; `PLANARCONFIG_SEPARATE`
stores each sample as its own plane of striles, so the strile index gains a
`sample * striles_per_plane` term ([`tif_tile.c`][tile-compute]) and the read calls take a
`sample` argument ([concepts: interleaved, planar and semi-planar][c-planar]).

**The read API, from cheapest to most converted.** All write into caller memory:

| Call                                                          | Unit           | Output                                                                |
| ------------------------------------------------------------- | -------------- | --------------------------------------------------------------------- |
| `TIFFReadRawStrip`, `TIFFReadRawTile`                         | strile         | compressed bytes as stored                                            |
| `TIFFReadFromUserBuffer`                                      | strile         | decompressed from a caller-supplied input buffer                      |
| `TIFFReadEncodedStrip`, `TIFFReadEncodedTile`, `TIFFReadTile` | strile         | decompressed, byte-swapped, predictor undone, otherwise untransformed |
| `TIFFReadScanline(tif, buf, row, sample)`                     | row            | as above, sequential within a strip                                   |
| `TIFFReadRGBAImage`, `TIFFReadRGBAStrip`, `TIFFReadRGBATile`  | image / strile | 8-bit packed ABGR, `uint32_t` per pixel                               |

`TIFFReadScanline` decodes through `tif_decoderow` and then `tif_postdecode` (byte swap)
([`tif_read.c`][read-scanline]); it cannot seek backwards inside a compressed strip, which
the manual spells out for `PLANARCONFIG_SEPARATE` loops ([`doc/libtiff.rst`][doc-scanline]).
`TIFFReadFromUserBuffer` decouples I/O from decoding: the caller reads the strile bytes
itself and libtiff only decompresses ([`TIFFReadFromUserBuffer.rst`][doc-userbuf]).

**The codec registry.** `_TIFFBuiltinCODECS` is a static table of name, `Compression`
tag value and an init function ([`tif_codec.c`][codec-table]):

```c
// libtiff/tif_codec.c (excerpt)
{"LZW", COMPRESSION_LZW, TIFFInitLZW},
{"JPEG", COMPRESSION_JPEG, TIFFInitJPEG},
{"Deflate", COMPRESSION_DEFLATE, TIFFInitZIP},
{"ZSTD", COMPRESSION_ZSTD, TIFFInitZSTD},
{"WEBP", COMPRESSION_WEBP, TIFFInitWebP},
{"LERC", COMPRESSION_LERC, TIFFInitLERC},
```

A codec compiled out maps to `NotConfigured`, which installs `_notConfigured` hooks so the
directory still opens and only the pixel read fails ([`tif_codec.c`][codec-notconf]).
`TIFFRegisterCODEC` adds or overrides schemes at run time ([`tiffio.h`][tiffio-codec]).
LZW, PackBits, CCITT, ThunderScan, NeXT and LogLuv are implemented in-tree; JPEG and
old-style JPEG (libjpeg), Deflate and PixarLog (zlib), ZSTD, LZMA, WebP, JBIG and LERC wrap
external libraries, and `tif_zip.c` may use libdeflate
_"but only for whole strips and tiles"_, falling back to zlib for scanlines
([`tif_zip.c`][zip-libdeflate]). Predictors (`PREDICTOR_HORIZONTAL`,
`PREDICTOR_FLOATINGPOINT`, [`tiff.h`][tiff-predictor]) are a layer that codecs chain in
with `TIFFPredictorInit`.

**`TIFFRGBAImage`.** The convenience path is a small state machine
([`tiffio.h`][tiffio-rgba]): `TIFFRGBAImageOK` checks the combination, `TIFFRGBAImageBegin`
picks a `get` routine (`gtStripContig`, `gtStripSeparate`, `gtTileContig`,
`gtTileSeparate`, [`tif_getimage.c`][getimage-get]) and a `put` routine per photometric
and bit depth, with lookup tables for palette, bilevel, YCbCr, CIELab and
unassociated-to-associated alpha (`UaToAa`).

## Analysis

### 1. Pixel and memory model

The file format, not the library, defines the layout: samples of any width
(`BitsPerSample`), `SampleFormat` `UINT`, `INT`, `IEEEFP`, `VOID`, `COMPLEXINT` and
`COMPLEXIEEEFP` ([`tiff.h`][tiff-sampleformat]), `SamplesPerPixel` with `ExtraSamples`
marking alpha as associated or unassociated, contiguous or separate planes, and a third
spatial axis (`ImageDepth`, `TileDepth`). libtiff returns those bytes unchanged: its
memory model below `TIFFReadRGBAImage` is "a caller buffer of `TIFFStripSize` or
`TIFFTileSize` bytes", with sizes computed by `TIFFScanlineSize64`, `TIFFVStripSize64` and
`TIFFVTileSize64`. Sub-byte samples stay packed, and the pixel type is the triple
(`BitsPerSample`, `SampleFormat`, `SamplesPerPixel`), not a C type. The RGBA path is the
opposite extreme: one fixed `uint32_t` ABGR raster, bottom-left origin by default, scaled
to 8 bits ([`TIFFReadRGBAImage.rst`][doc-rgba-raster]). Tiles in the file are the
[tiling][c-tiling] concept at storage level: a reader fetches a region by computing
`TIFFComputeTile` for its corners.

### 2. Genericity mechanism

Run-time tables throughout: codecs are `TIFFCodec` records whose init function fills the
handle's method pointers; tags are `TIFFField` records consulted by a variadic
`TIFFGetField`; the RGBA converter selects `put` functions by `switch`. Nothing is generic
at compile time, so adding a sample format means another `put` routine and another case.

### 3. Colour and metadata

`PhotometricInterpretation` carries the colour model: `MINISWHITE`, `MINISBLACK`, `RGB`,
`PALETTE`, `MASK`, `SEPARATED` (CMYK and inks), `YCBCR`, `CIELAB`, `ICCLAB`, `ITULAB`,
`CFA` (DNG raw mosaics), `LOGL` and `LOGLUV` ([`tiff.h`][tiff-photometric]). Colour
management is left to the caller: the [ICC profile][c-icc] is an opaque byte tag
(`TIFFTAG_ICCPROFILE`, with DNG's `AsShotICCProfile` beside it), XMP is `XMLPacket`
([`tif_dirinfo.c`][dirinfo-icc]), and EXIF and GPS are sub-IFDs read with
`TIFFReadEXIFDirectory` and `TIFFReadGPSDirectory` ([`tiffio.h`][tiffio-fields]). The
RGBA path converts YCbCr and CIELab but states that _"Raster pixels are returned
uncorrected by any colorimetry information present in the directory"_
([`TIFFReadRGBAImage.rst`][doc-rgba-raster]). There is no [CICP][c-cicp] tag; GeoTIFF's
georeferencing is likewise private tags interpreted by libgeotiff or GDAL, not libtiff.
TIFF is therefore the clearest case in the catalog of [image metadata][c-metadata] as an
open, typed tag namespace rather than a fixed struct.

### 4. I/O and codec architecture

Pull, random-access and synchronous: every read seeks through `TIFFSeekProc` or a memory
map, and a strile is the unit of decode. The `D` and `O` open flags defer loading the
offset and byte-count arrays, and `O` loads only the entries for the requested strile
([`TIFFOpen.rst`][doc-defer]), which is what makes Cloud Optimized GeoTIFF over HTTP range
requests practical: opening a file no longer costs a read of every tile's offset. Within a strip, scanline reads are incremental
(the codec keeps state between rows), but nothing suspends: a short read is an error, not
"need more input" ([concepts: incremental and suspendable decoding][c-incremental]; contrast
[Wuffs][wuffs]). The `C` flag's "strip chopping" splits one huge uncompressed strip into
roughly 8 KB virtual strips; it is on by default, a compile-time setting
([`TIFFOpen.rst`][doc-chop]). `TIFFReadFromUserBuffer` is the
seam a caller with its own I/O (io_uring, HTTP, a cache) uses, since the decode then never
touches the handle's file callbacks.

### 5. Hostile input and safety

Everything is checked arithmetic and heuristics over C ([concepts: hostile input][c-hostile]):

- **Overflow-checked size helpers.** `_TIFFMultiply32` and `_TIFFMultiply64` return 0 on
  overflow after reporting an error ([`tif_aux.c`][aux-mul]), and callers such as
  `TIFFComputeTile` test for that 0 ([`tif_tile.c`][tile-compute]).
- **IFD loops.** `_TIFFCheckDirNumberAndOffset` keeps two hash sets of seen directory
  numbers and offsets ([`tif_dirread.c`][dirread-loop]), capped at `TIFF_MAX_DIR_COUNT`
  (1,048,576, [`tiffiop.h`][tiffiop-maxdir]). **Verified:** a 1 by 1 image whose next-IFD
  pointer is its own offset yields three warnings (twice _"TIFF directory 0 has IFD looping
  to directory 0"_ from `_TIFFCheckDirNumberAndOffset`, then _"might be an IFD loop.
  Treating directory 0 as last directory"_ from `TIFFAdvanceDirectory`), and
  `TIFFNumberOfDirectories` returns 1.
- **Growing reads.** `TIFFReadAndRealloc` reads a strile in 1 MB, 10 MB, 100 MB steps on
  64-bit hosts so a lying byte count on a short file cannot force one huge allocation
  ([`tif_read.c`][read-realloc]).
- **Compression-ratio plausibility** (new in 4.7.2, [`v4.7.2.rst`][rel472]). Each codec
  reports a maximum ratio, estimated from all-zero images made with GDAL
  ([`README_for_libtiff_developpers.md`][devreadme]); LZW returns 1400 from documented ratios of
  562 to 1362 ([`tif_lzw.c`][lzw-ratio]). When a strip would decode to more than 100 MB and
  its byte count is below size divided by ratio, `TIFFFillStrip` refuses it
  ([`tif_read.c`][read-ratio]); `TIFFFillTile` and the `_TIFFReadEncodedStripAndAllocBuffer`
  and `_TIFFReadEncodedTileAndAllocBuffer` helpers apply the same test. **Verified:** a 222-byte file declaring a 20000 by 20000
  8-bit LZW strip of 100 bytes opens, then `TIFFReadScanline` fails with _"Likely invalid
  strip byte count for strip 0. Uncompressed strip size is 400000000, compressed one is
  100"_.
- **Memory limits, off by default.** `TIFFOpenOptionsSetMaxSingleMemAlloc` (4.5.0) and
  `TIFFOpenOptionsSetMaxCumulatedMemAlloc` (4.6.1) bound allocations made through
  `_TIFFmallocExt`; 0 means unlimited ([`tif_open.c`][open-setters],
  [`TIFFOpenOptions.rst`][doc-openopts]). The cumulative limit is tracked by prefixing each
  block with its size ([`tif_open.c`][open-mallocext]). Caller buffers are outside both
  limits, and so are most codec libraries' own allocations: libjpeg allocates through its
  own memory manager (libtiff uses it for its downsampled buffers too,
  [`tif_jpeg.c`][jpeg-alloc]), and libzstd and liblzma get no allocator hooks. zlib is the
  exception: the Deflate codec installs `TIFF_zalloc`, which allocates through
  `_TIFFmallocExt` ([`tif_zip.c`][zip-zalloc]).
  **Verified** on a valid 4000 by 4000 Deflate image in one strip (16 MB decoded, 15,686
  bytes on disk): with an 8 MiB single limit, `TIFFReadScanline` still reads all 4000 rows,
  because only the compressed strip is buffered, while `TIFFReadRGBAImage` fails with
  _"Memory allocation of 16000000 bytes is beyond the 8388608 byte limit"_, because the
  RGBA path decodes whole strips. A 4096-byte cumulative limit lets the file open and
  fails the first scanline in `ZIPSetupDecode`, when zlib's inflate state (7,160 bytes,
  through `TIFF_zalloc`) would exceed it: _"Cumulated memory allocation of 1680 + 7160
  bytes is beyond the 4096 cumulated byte limit"_.
- **Fuzzing.** Four libFuzzer harnesses live in-tree (`tiff_decode_fuzzer`,
  `tiff_read_rgba_fuzzer`, `tiff_packbits_fuzzer`, `write_fuzzer`) and OSS-Fuzz builds them
  with zlib, libjpeg-turbo, JBIG and LZMA ([`build.sh`][fuzz-build]). The RGBA harness
  refuses inputs whose tile size exceeds `MAX_SIZE = 500000000` before decoding
  ([`tiff_read_rgba_fuzzer.cc`][fuzz-rgba]): the guard lives in the harness, not the
  library. The 4.7.2 release notes cite OSS-Fuzz issues up to `506737072`
  ([`v4.7.2.rst`][rel472]).
- **CVEs.** The in-tree release notes (`doc/releases/`) name 15 CVE identifiers (3 in
  4.0.7, 10 in 4.5.0, 2 in 4.7.0, for example `CVE-2023-52356` and `CVE-2024-7006`); the
  in-tree `ChangeLog`, whose identifiers run from 2008 to 2019, names 51, for 63 distinct
  in all. Most recent fixes are cited by OSS-Fuzz or GitLab issue number instead, so even
  that count understates the history.

The pattern is a mature C codebase hardening by accretion: every limit is a reaction to a
class of reports, the strongest one (the allocation cap) is opt-in, and the plausibility
ratio is self-described as _"experimentally determined. Might be fragile..."_
([`tif_read.c`][read-ratio]). Compare [stb_image][stb] (no limits, public disclosure) and
[Wuffs][wuffs] (memory-safe by construction).

### 6. Allocation and ownership

Pixel memory is the caller's in every API except the internal `...AndAllocBuffer` helpers
the RGBA path uses. libtiff owns the directory, tag values (for array tags `TIFFGetField` returns
pointers into the handle, valid until the directory changes), the raw strile buffer and
the codec state; `TIFFReadBufferSetup` lets the caller supply the raw buffer. All go
through `_TIFFmallocExt`/`_TIFFfreeExt`, which the build enforces by hiding the plain
allocators (`TIFF_DO_NOT_USE_NON_EXT_ALLOC_FUNCTIONS`, [`tif_open.c`][open-mallocext]).

### 7. CPU parallelism and SIMD

A `TIFF *` is single-threaded ([`doc/libtiff.rst`][doc-threads]): _"It is not possible
(safe) to edit a single TIFF file with multiple threads at the same time."_ Since 4.5 the
per-handle error handlers make one handle per thread safe. Parallel decode of one image is
the caller's job: read striles' bytes, then call `TIFFReadFromUserBuffer` on per-thread
handles. The tree's only SIMD is an SSE2 byte-interleave in `fpAcc`, the floating-point
predictor's decode path, for 4-byte samples on x86-64 ([`tif_predict.c`][predict-sse2]);
the rest of vectorised decode comes from libjpeg-turbo, libdeflate, libwebp and libzstd.

### 8. GPU offload and interop

Not applicable, because libtiff has no GPU path or interop: every API returns pixels in
host memory, and uploading them is the caller's job.

### 9. Temporal, animation and containers

Multi-page TIFF is a linked list of IFDs walked with `TIFFReadDirectory`, `TIFFSetDirectory`
and `TIFFSetSubDirectory`, plus SubIFD trees for reduced-resolution overviews; there is no
timing, so a TIFF "sequence" (microscopy stacks, fax pages) is pages, not animation.
Random access to page n is a walk of n links unless the offset is already in
`tif_map_dir_number_to_offset` ([`tiffiop.h`][tiffiop-struct]).

### 10. Testing and conformance

`test/` holds C unit tests (`test_open_options.c` for both memory limits
([`test_open_options.c`][test-openopts]), `test_ifd_loop_detection.c`, `test_RGBAImage.c`,
`defer_strile_loading.c`) and 129 shell tests that run the 36 reference files under
`test/images` (including `test_ifd_loop_to_self.tif`) through `tiffcp`, `tiff2rgba`,
`tiff2bw`, `tiffcrop` and other tools.
There is no external conformance suite for TIFF comparable to PngSuite; regression files
come from fuzzing. OSS-Fuzz plus the release-note issue references are the conformance
story.

## Lessons for Sparkles

- **Q1** The strile is a natural storage unit for a scientific pipeline: a tile index is
  computable from (x, y, z, sample) and maps to one byte range. A `sparkles:image` view
  over a TIFF would page tiles into a strided `Slice` rather than decode whole images.
  libtiff's own memory model (opaque byte buffers sized by helper functions) does not
  transfer; Sparkles wants typed planes.
- **Q1** `PLANARCONFIG_SEPARATE`, sub-byte packed samples, complex samples and a depth
  axis are all real in TIFF. A pixel model that cannot name them cannot round-trip GeoTIFF
  or microscopy data without conversion.
- **Q4** The container/codec split is clean: directory parsing never depends on whether
  the codec is compiled in (`NotConfigured`). A D TIFF reader can parse IFDs natively
  (the header and IFD entries are a fixed binary layout `sparkles:wired` could describe,
  with byte order chosen at run time and a 32/64-bit offset width chosen by the version
  field) and dispatch striles to codecs, D or C.
- **Q4** `TIFFReadFromUserBuffer` is the seam to copy: decode takes bytes the caller
  fetched, so I/O can be io_uring, HTTP ranges or a cache. libtiff's synchronous seek/read
  callbacks are what not to copy.
- **Q5** TIFF argues for metadata as an open, typed tag table (number, type, count,
  bytes) with ICC, XMP, EXIF and GeoTIFF keys layered on top, rather than a closed struct.
  It also shows the cost: libtiff never applies the ICC profile, so colour correctness is
  everyone's problem.
- **Q6** Strile offset arrays let a reader issue direct, aligned reads of compressed
  tiles, the shape io_uring and GPU decompression want; deferred (`D`/`O`) loading of
  those arrays matters for files with millions of tiles.
- **Q8** Ship limits on by default where libtiff could not for compatibility: a single
  allocation cap and a cumulative cap, both enforced by the allocator, and a
  plausibility check of declared decoded size against compressed size. The probes in this
  page are ready-made hostile-input fixtures (self-looping IFD, implausible ratio,
  memory-cap file) for a D reader and for a differential test against libtiff.
- **Q9** libtiff is a container library with pluggable codecs; OpenImageIO and libvips
  wrap it, while image-rs uses its own Rust `tiff` crate instead. That favours a split where a TIFF container package depends on
  codec packages, not the reverse.

## Strengths

- Covers the whole TIFF surface: BigTIFF, tiles, separate planes, every sample format,
  YCbCr subsampling, sub-IFDs, EXIF/GPS, and twenty codec-table entries besides `None`.
- Layered API from raw striles to ABGR, all writing into caller buffers.
- Container parsing independent of codec availability; codecs replaceable at run time.
- Deferred and on-demand strile-array loading suits cloud and huge files.
- Thirty-plus years of fuzz-driven hardening, OSS-Fuzz integration, explicit IFD-loop,
  overflow and ratio checks.

## Weaknesses

- C with no memory safety; the security record is a long CVE and OSS-Fuzz list, and the
  project retired most tools rather than secure them.
- Memory limits are opt-in and default to unlimited; libjpeg's, libzstd's and liblzma's
  allocations escape them (zlib's are counted).
- Synchronous seek/read I/O; no suspendable decoding.
- No colour management: ICC and XMP are opaque bytes; the RGBA path ignores colorimetry
  and flattens everything to 8-bit ABGR.
- Variadic `TIFFGetField` has no type checking; a wrong pointer type is undefined behaviour.
- One handle is not thread-safe; parallel decode needs caller orchestration.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                 | Trade-off                                                              |
| ------------------------------------------------ | --------------------------------------------------------- | ---------------------------------------------------------------------- |
| Container and codecs separate, codecs in a table | directories open even when a codec is compiled out        | method pointers and run-time dispatch; no compile-time specialisation  |
| Tags as a run-time `TIFFField` registry          | private tags (GeoTIFF, DNG, EXIF) need no library change  | variadic `TIFFGetField` cannot type-check its arguments                |
| Pixels returned untransformed below the RGBA API | scientific data keeps its sample format, depth and planes | callers interpret packing, planes and colour themselves                |
| One fixed 8-bit ABGR convenience raster          | one call reads almost any TIFF for display                | drops precision and ignores colorimetry                                |
| Synchronous seek/read callbacks                  | simple, portable I/O for files and memory maps            | no suspendable decode; other I/O goes through `TIFFReadFromUserBuffer` |
| Allocation limits opt-in, default unlimited      | existing callers keep working unchanged                   | a default caller gets no cap; the ratio heuristic is "fragile"         |

## Sources

- libtiff/libtiff at `d23249978a7a99ea2e0752a476611914501577de`:
  [`libtiff/tiffiop.h`][tiffiop-struct], [`libtiff/tiff.h`][tiff-header],
  [`libtiff/tif_dir.h`][tifdir-field], [`libtiff/tiffio.h`][tiffio-rgba],
  [`libtiff/tif_codec.c`][codec-table], [`libtiff/tif_read.c`][read-ratio],
  [`libtiff/tif_open.c`][open-mallocext], [`libtiff/tif_dirread.c`][dirread-loop],
  [`libtiff/tif_dirinfo.c`][dirinfo-icc], [`libtiff/tif_tile.c`][tile-compute],
  [`libtiff/tif_aux.c`][aux-mul], [`libtiff/tif_lzw.c`][lzw-ratio],
  [`libtiff/tif_zip.c`][zip-libdeflate], [`libtiff/tif_getimage.c`][getimage-get],
  [`libtiff/tif_predict.c`][predict-sse2], [`libtiff/tif_jpeg.c`][jpeg-alloc],
  [`libtiff/README_for_libtiff_developpers.md`][devreadme].
- Documentation in the same tree: [`doc/libtiff.rst`][doc-layers],
  [`doc/functions/TIFFOpen.rst`][doc-defer], [`doc/functions/TIFFOpenOptions.rst`][doc-openopts],
  [`doc/functions/TIFFReadRGBAImage.rst`][doc-rgba-raster],
  [`doc/functions/TIFFReadFromUserBuffer.rst`][doc-userbuf],
  [`doc/releases/v4.6.0.rst`][rel460-warn], [`doc/releases/v4.7.2.rst`][rel472],
  [`HOWTO-SECURITY-RELEASE`][sec-howto], [`LICENSE.md`][lic].
- Fuzzing and tests: [`contrib/oss-fuzz/build.sh`][fuzz-build],
  [`contrib/oss-fuzz/tiff_read_rgba_fuzzer.cc`][fuzz-rgba],
  [`test/test_open_options.c`][test-openopts].
- Catalog: [umbrella][umbrella], [concepts][concepts], [stb_image][stb], [Wuffs][wuffs],
  [libvips][libvips], [OpenImageIO][oiio], [image-rs][image-rs], [Go image][go-image].

<!-- References -->

[repo]: https://gitlab.com/libtiff/libtiff/-/tree/d23249978a7a99ea2e0752a476611914501577de
[docs]: https://libtiff.gitlab.io/libtiff/
[lic]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/LICENSE.md
[sec-howto]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/HOWTO-SECURITY-RELEASE#L4-9
[tiffiop-struct]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffiop.h#L114-263
[tiffiop-maxdir]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffiop.h#L61-62
[tiff-header]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiff.h#L105-123
[tiff-types]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiff.h#L134-144
[tiff-photometric]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiff.h#L221-233
[tiff-predictor]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiff.h#L304-306
[tiff-sampleformat]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiff.h#L334-339
[tifdir-dir]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_dir.h#L81-153
[tifdir-field]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_dir.h#L342-358
[tiffio-rgba]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffio.h#L215-251
[tiffio-codec]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffio.h#L316-320
[tiffio-fields]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffio.h#L338-396
[tiffio-ext]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffio.h#L654-666
[tiffio-extender]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tiffio.h#L556
[codec-table]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_codec.c#L83-108
[codec-notconf]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_codec.c#L110-133
[read-realloc]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_read.c#L43-94
[read-scanline]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_read.c#L489-517
[read-ratio]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_read.c#L834-878
[open-setters]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_open.c#L89-110
[open-mallocext]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_open.c#L160-198
[dirread-loop]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_dirread.c#L5762-5772
[dirinfo-subifd]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_dirinfo.c#L146
[dirinfo-icc]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_dirinfo.c#L163-186
[tile-compute]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_tile.c#L35-103
[tile-16]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_tile.c#L268-276
[aux-mul]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_aux.c#L35-57
[lzw-ratio]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_lzw.c#L1395-1408
[zip-libdeflate]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_zip.c#L36-39
[zip-zalloc]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_zip.c#L684-701
[jpeg-alloc]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_jpeg.c#L774-779
[predict-sse2]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_predict.c#L687-723
[getimage-get]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/tif_getimage.c#L35-40
[devreadme]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/libtiff/README_for_libtiff_developpers.md#L4-10
[doc-layers]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/libtiff.rst#L13-24
[doc-dirs]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/libtiff.rst#L187-198
[doc-scanline]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/libtiff.rst#L536-548
[doc-threads]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/libtiff.rst#L702-726
[doc-openopts]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/functions/TIFFOpenOptions.rst#L47-63
[doc-rgba-raster]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/functions/TIFFReadRGBAImage.rst#L36-71
[doc-chop]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/functions/TIFFOpen.rst#L219-236
[doc-defer]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/functions/TIFFOpen.rst#L256-265
[doc-userbuf]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/functions/TIFFReadFromUserBuffer.rst#L15-25
[rel460-warn]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/releases/v4.6.0.rst#L23-37
[rel460-tiffcp]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/releases/v4.6.0.rst#L128-130
[rel472]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/doc/releases/v4.7.2.rst
[fuzz-build]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/contrib/oss-fuzz/build.sh#L61-76
[fuzz-rgba]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/contrib/oss-fuzz/tiff_read_rgba_fuzzer.cc#L39-77
[test-openopts]: https://gitlab.com/libtiff/libtiff/-/blob/d23249978a7a99ea2e0752a476611914501577de/test/test_open_options.c#L160-230
[umbrella]: ./index.md
[concepts]: ./concepts.md
[c-container]: ./concepts.md#container-and-bitstream
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-tiling]: ./concepts.md#tiling
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-metadata]: ./concepts.md#image-metadata
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[stb]: ./stb-image.md
[wuffs]: ./wuffs.md
[libvips]: ./libvips.md
[oiio]: ./openimageio.md
[image-rs]: ./image-rs.md
[go-image]: ./go-image.md
