# GDAL, GeoTIFF and Cloud Optimized GeoTIFF (C++)

The geospatial raster translator whose block cache, overview-aware `RasterIO` and virtual file systems read terabyte rasters a window at a time, locally or over HTTP range requests, and whose COG layout makes a TIFF readable in two or three GETs.

| Field         | Value                                                                                                                        |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 with a C API (`gdal.h`), bundling libtiff and libgeotiff under `frmts/gtiff/`                                          |
| License       | MIT-style for GDAL itself; third-party terms collected in [`LICENSE.TXT`][lic]                                               |
| Repository    | [OSGeo/gdal][repo] (version 3.14.0 at this revision)                                                                         |
| Revision read | `739fcf03bfcc075e300dbd45743187b380a17cdc` (October 23, 2026)                                                                |
| Documentation | [gdal.org][docs]; in-tree [raster data model][doc-rdm], [COG driver][doc-cog], [virtual file systems][doc-vsi]               |
| Category      | Generic libraries: a driver registry over a block-cached band model, with a pluggable byte layer for local, memory and cloud |
| Tier          | B                                                                                                                            |
| Last reviewed | November 7, 2026                                                                                                             |

> [!NOTE]
> Claims marked **verified** were demonstrated in `/tmp/gdal-probe/` with nixpkgs GDAL
> 3.11.4 (older than the pinned 3.14.0; the COG and `/vsicurl/` paths shown predate both)
> and `darkhttpd` serving the file on loopback. The probe writes a 4096 by 4096 noise
> COG, dumps its header, and traces the HTTP ranges three reads issue. Byte counts below
> come from that run; no timing was measured.

---

## Overview

### What it solves

GDAL describes itself as _"an open source MIT licensed translator library for raster and
vector geospatial data formats"_ ([`README.md`][readme]). It has 114 directories under
`frmts/`, most of them a driver (a few, such as `zlib/` and `iso8211/`, are shared
helpers, and `raw/` holds dozens of drivers), each turning a file format into one shared model: a `GDALDataset`
holding `GDALRasterBand`s of equal size, each band split into fixed blocks. The model
documentation states the ceiling plainly ([`raster_data_model.rst`][doc-rdm-limits]):

> _"The number of pixels and lines for a raster band is limited to 2,147,483,647 each.
> The number of bands is also limited to 2,147,483,647, although by default a limitation
> to 65,536 is applied to avoid excessive RAM consumption."_

### Design philosophy

The design premise is that a raster never has to fit in memory. A band is read through a
global least-recently-used block cache, a downsampled request is redirected to a
pre-built overview, and every byte goes through the VSI layer, so the same driver reads a
local file, a `/vsimem/` buffer or an object in S3. The COG driver turns that premise
into a file layout: _"Optimized layout of TIFF sections to minimize the number of GET
requests needed by a reader doing random read access"_ ([`cog.rst`][doc-cog-high]).

The security page is frank about the cost of breadth ([`security.rst`][doc-sec-surface]):
_"GDAL has a large attack surface, because it deals with data in a variety of file
formats."_

## How it works

**Dataset, band, block.** A driver subclasses `GDALDataset` and `GDALRasterBand` and
implements one required hook, `IReadBlock`, which fills one block in the band's native
type ([`gdal_rasterband.h`][rb-hooks]):

```cpp
// gcore/gdal_rasterband.h: the driver hooks (excerpt)
virtual CPLErr IReadBlock(int nBlockXOff, int nBlockYOff, void *pData) = 0;
virtual CPLErr IWriteBlock(int nBlockXOff, int nBlockYOff, void *pData);

virtual CPLErr
IRasterIO(GDALRWFlag eRWFlag, int nXOff, int nYOff, int nXSize, int nYSize,
          void *pData, int nBufXSize, int nBufYSize, GDALDataType eBufType,
          GSpacing nPixelSpace, GSpacing nLineSpace,
          GDALRasterIOExtraArg *psExtraArg) CPL_WARN_UNUSED_RESULT;
```

The default `IRasterIO` assembles any window from cached blocks, converts type with
`GDALCopyWords64`, and resamples when the source window and buffer differ in size. A
driver overrides `IRasterIO` only when it can do better (the GTiff driver does, for
multi-range and multi-threaded reads). The dataset-level form adds `nBandCount`,
`panBandMap` and `nBandSpace`, so one call writes pixel-, line- or band-interleaved
output into any caller buffer ([`gdal_dataset.h`][ds-rasterio]).

**The block cache.** `GDALRasterBlock` is one cached block: offsets, size, a `pData`
pointer, a dirty flag, a `volatile int nLockCount` changed through atomic operations, and the `poNext`/`poPrevious` links of a
process-wide LRU list ([`gdal_rasterblock.h`][rblock-h]). The class comment
([`gdalrasterblock.cpp`][rblock-doc]) describes the design:

> _"The cache holds some blocks of raster data for zero or more GDALRasterBand objects
> across zero or more GDALDataset objects in a global raster cache with a least recently
> used (LRU) list and an upper cache limit (see GDALSetCacheMax()) under which the cache
> size is normally kept."_

The limit comes from `GDAL_CACHEMAX`, defaulting to `"5%"` of usable RAM
([`gdalrasterblock.cpp`][rblock-cachemax]). `Internalize()` charges a new block against
the limit and walks the list from `poOldest`, claiming victims with
`CPLAtomicCompareAndExchange(&nLockCount, 0, -1)`; dirty blocks are written back before
being freed, and the first pass evicts only clean blocks and dirty blocks of the same
dataset (another dataset's dirty block is the fallback) to make less likely a
read-after-evict race documented inline ([`gdalrasterblock.cpp`][rblock-evict]). Each
band indexes its blocks in a `GDALArrayBandBlockCache` (a two-level array with 64 by 64
sub-blocks, [`gdalarraybandblockcache.cpp`][arraycache]) or, once a dataset has a million
blocks or more, a `GDALHashSetBandBlockCache`; `GDAL_BAND_BLOCK_CACHE` overrides the
choice ([`gdalrasterband.cpp`][rb-cachechoice]).

**Overviews and resampling.** A band may own overview bands, each a free-standing
`GDALRasterBand` covering the same area at lower resolution. When a request is
downsampled, `GDALBandGetBestOverviewLevel2` picks the coarsest overview that is not
much coarser than asked, with a 1.2 oversampling threshold for nearest neighbour and 1.0
for the other kernels ([`rasterio.cpp`][rio-bestovr]), then rescales the window,
including the fractional window in `GDALRasterIOExtraArg`. The documented selection
table ([`gdalrasterband.cpp`][rb-ovrdoc]):

```text
target_downscaling_factor  | selected_overview
]0,       2 / 1.2]         | full resolution band
]2 / 1.2, 4 / 1.2]         | 2x downsampled band
]4 / 1.2, 8 / 1.2]         | 4x downsampled band
]8 / 1.2, infinity[        | 8x downsampled band
```

The resampling kernel travels in `GDALRasterIOExtraArg::eResampleAlg`: nearest,
bilinear, cubic, cubic spline, Lanczos, average, mode, Gauss and RMS
([`gdal.h`][gdalh-resample]). The struct is versioned (`nVersion`) and only grows at the
end ([`gdal.h`][gdalh-extraarg]).

**The driver registry.** `GDALOpenInfo` opens the file once, ingests at least 1024
header bytes (`GDAL_INGESTED_BYTES_AT_OPEN`, clamped to 10 MiB,
[`gdalopeninfo.cpp`][openinfo-ingest]) and offers them to each registered driver's
`pfnIdentify`, which answers true, false or unknown ([`gdal_driver.h`][drv-identify]).
GTiff's `Identify` checks `II`/`MM` and the version word 42 (classic) or 43 (BigTIFF)
([`gtiffdataset_read.cpp`][gtiff-identify]). The first driver whose `pfnOpen` succeeds
owns the dataset. See [container and bitstream][c-container]: identification reads the
container, never the codec.

**VSI: the byte layer.** Every driver reads through `VSIVirtualHandle`
([`cpl_vsi_virtual.h`][vsi-handle]), whose methods go beyond `Seek`/`Read`:
`ReadMultiRange` fetches many ranges in one call, `AdviseRead` prefetches them in the
background, `PRead` reads positionally, and `GetRangeStatus` reports sparse holes.
Handlers are selected by prefix and chain (`/vsizip//vsicurl/https://…`,
[`virtual_file_systems.rst`][doc-vsi]). `/vsimem/` is a mutex-guarded in-process
filesystem whose `VSIMemFile` can borrow a caller buffer (`bOwnData = false`,
[`cpl_vsi_mem.cpp`][vsimem]); the fuzz harness hands each input to GDAL that way.

`/vsicurl/` _"allows on-the-fly random reading of files available through HTTP/FTP web
protocols, without prior download of the entire file"_ ([`virtual_file_systems.rst`][doc-vsicurl]).
It reads in 16 KiB chunks (`CPL_VSIL_CURL_CHUNK_SIZE`, range 1 KiB to 10 MiB) into a
process-wide region cache of 1000 chunks by default (`CPL_VSIL_CURL_CACHE_SIZE`,
[`cpl_vsil_curl.cpp`][curl-chunk]). Sequential reads trigger read-ahead
([`cpl_vsil_curl.cpp`][curl-readahead]):

```cpp
// port/cpl_vsil_curl.cpp: VSICurlHandle::Read (excerpt)
if (nOffsetToDownload == lastDownloadedOffset)
{
    // In case of consecutive reads (of small size), we use a
    // heuristic that we will read the file sequentially, so
    // we double the requested size to decrease the number of
    // client/server roundtrips.
    constexpr int MAX_CHUNK_SIZE_INCREASE_FACTOR = 128;
    if (nBlocksToDownload < MAX_CHUNK_SIZE_INCREASE_FACTOR)
        nBlocksToDownload *= 2;
}
else
{
    // Random reads. Cancel the above heuristics.
    nBlocksToDownload = 1;
}
```

`ReadMultiRange` sorts the ranges, merges consecutive ones
(`GDAL_HTTP_MERGE_CONSECUTIVE_RANGES`, default true) and issues them in parallel
([`cpl_vsil_curl.cpp`][curl-multirange]): it hands the vector of easy handles to the
filesystem handler's `Perform`, which queues them on one `curl_multi` handle and waits
until all complete ([`cpl_vsil_curl.cpp`][curl-perform]), while a background `Run` loop
drives that handle with `curl_multi_perform` and `curl_multi_poll`
([`cpl_vsil_curl.cpp`][curl-run]).

**COG layout.** A COG is a tiled TIFF or BigTIFF (512 pixel tiles by default) with
overviews halved until both dimensions are at most the block size
([`cogdriver.cpp`][cog-ovrloop]; the probe's 4096-pixel image got 2048, 1024 and 512),
laid out so that all IFDs, then all tile index
arrays, come first and tile data follows, smallest overview first and full resolution
last ([`cog.rst`][doc-cog-low]). Between the 8-byte header (16 bytes for BigTIFF) and the first IFD sits a
"ghost area" that TIFF readers skip but GDAL parses ([`cog.rst`][doc-cog-ghost]). The
probe's file (no mask) starts with (**verified**):

```text
GDAL_STRUCTURAL_METADATA_SIZE=000140 bytes
LAYOUT=IFDS_BEFORE_DATA
BLOCK_ORDER=ROW_MAJOR
BLOCK_LEADER=SIZE_AS_UINT4
BLOCK_TRAILER=LAST_4_BYTES_REPEATED
KNOWN_INCOMPATIBLE_EDITION=NO
```

Each tile is preceded by a 4-byte little-endian size and followed by a repeat of its last
4 bytes. A reader that sees the flags fetches tile `i` as
`[TileOffset[i] - 4, TileOffset[i+1])` without loading `TileByteCounts`, and the trailer
lets it detect a file rewritten by an unaware tool and fall back
([`cog.rst`][doc-cog-leader]); `CheckTrailer` implements that check
([`gtiffdataset_read.cpp`][gtiff-trailer]). On open, the GTiff driver parses the ghost
area with `strstr`, warns on `KNOWN_INCOMPATIBLE_EDITION=YES`, and refuses update mode
on an intact COG unless `IGNORE_COG_LAYOUT_BREAK=YES` is given
([`gtiffdataset_read.cpp`][gtiff-structmd]). It also opens libtiff with `"rDOC"`, the
deferred and on-demand strile flags, so an IFD with millions of tile offsets is not read
whole ([`gtiffdataset_read.cpp`][gtiff-defer]; see [libtiff][libtiff]).

**Multidimensional API.** Added in 3.1 and _"strongly inspired from the netCDF and HDF5
API and data models"_ ([`multidim_raster_data_model.rst`][doc-mdim]): a `GDALGroup` tree
of `GDALMDArray`s over named `GDALDimension`s with types (`HORIZONTAL_X`, `TEMPORAL`, …)
and indexing variables. Reads take a start, count, step and buffer stride per dimension
([`gdal_multidim.h`][mdim-iread]); arrays expose `GetBlockSize`, `GetProcessingChunkSize`,
lazy `GetView`/`Transpose`, and `AsClassicDataset` to present a 2-D slice as a classic
dataset ([`gdal_multidim.h`][mdim-views]).

## Analysis

### 1. Pixel and memory model

The model is band-major and block-tiled: the unit of storage and caching is one block of
one band in its native `GDALDataType` (eleven real and five complex types,
[`raster_data_model.rst`][doc-rdm-types]). Nothing in
the core holds a whole image. The caller-facing buffer is described by three `GSpacing`
strides (pixel, line, band) in bytes, so one `RasterIO` call fills planar, interleaved or
arbitrarily padded memory; this is the [stride][c-stride] concept with the band axis
made explicit. Band dimensions are `int`, which caps a band at 2^31 - 1 pixels a side;
the multidimensional API uses `GUInt64` extents and element strides
([`gdal_multidim.h`][mdim-iread]), closer to [mir `Slice`][mir] and the
[buffer protocol][numpy]. The row-major convention is the default, but the API _"is
mostly agnostic about that convention"_ ([`multidim_raster_data_model.rst`][doc-mdim-order]).

### 2. Genericity mechanism

Runtime dispatch throughout: a `GDALDataType` enum, virtual hooks on the dataset and
band, and a C function-pointer table per driver. Type conversion is one central switch
(`GDALCopyWords64`) rather than templates exposed to drivers, which is what lets every
driver share one resampling and caching core. Proxy and virtual datasets (VRT, the
overview dataset, the thread-safe wrapper) are further `GDALDataset` subclasses, so
composition is by wrapping, not by type parameters. Configuration is stringly typed:
`CPLGetConfigOption("GDAL_CACHEMAX", "5%")`, open options and creation options are
name/value strings validated per driver.

### 3. Colour and metadata

Metadata is a set of string domains on every object: the default domain travels with
the data, `IMAGE_STRUCTURE` describes storage and _"should not normally be copied to new
formats"_ ([`raster_data_model.rst`][doc-rdm-imgstruct]), and drivers add domains such
as `EXIF`, `xml:XMP` and GTiff's `COLOR_PROFILE`, which carries a Base64
`SOURCE_ICC_PROFILE` or primaries, white point and transfer tables
([`gtiff.rst`][doc-gtiff-icc]). Colour is otherwise a per-band `GDALColorInterp` label;
there is no colour management and no [CICP][c-cicp] model, and the documentation warns
that the profile _"can only be used on the original raw pixel data"_. The geospatial
metadata (geotransform, spatial reference, GCPs, nodata, scale and offset) is first-class
API, the opposite priority of a photo library. See [ICC profile][c-icc] and
[image metadata][c-meta].

### 4. I/O and codec architecture

Pull, block-granular and random-access: the core asks a driver for block (x, y), and the
driver asks VSI for bytes. Two features make that efficient on high-latency storage.
First, overview selection moves a downsampled read to a smaller image before any block
is touched. Second, the byte layer accepts batches: GTiff computes every tile offset a
window needs, calls `AdviseRead` or `ReadMultiRange`, and `/vsicurl/` coalesces adjacent
ranges. The probe shows the effect on a COG of about 21.4 MB (21,398,328 bytes in the
recorded run; DEFLATE over random bytes, so the size varies a little per run)
(**verified**): `gdalinfo` issues a HEAD for the size and one 16 KiB GET (`0-16383`),
because the IFDs sit in the first chunk, plus a HEAD for a `.vat.dbf` sidecar that
answers 404; a 256 by 256
thumbnail selects the 512 by 512 overview (`GDAL: Selecting overview 512 x 512`) and
adds one GET (`16384-180223`); a 100 by 100 window straddling four 512-pixel tiles costs
two GETs of 524,370 bytes each, one per tile row, since row-major tiles are adjacent in
the file. Decoding is not suspendable in the [Wuffs][wuffs] sense; latency is hidden by
batching and prefetch, not by resumable state. A streaming mode exists
(`/vsicurl_streaming/`), but the block model assumes random access.

### 5. Hostile input and safety

GDAL's posture is defence by configuration plus fuzzing. The security guide asks
deployers to build only needed drivers, set `GDAL_SKIP`, disable curl, sandbox the
process and _"Check the raster dimensions and number of bands just after opening"_
([`security.rst`][doc-sec-mitigate]). The core helpers are thin:
`GDALCheckDatasetDimensions` only rejects non-positive sizes, and `GDALCheckBandCount`
caps bands at `GDAL_MAX_BAND_COUNT` (65536) ([`gdal_misc.cpp`][misc-checks]). The probe
shows the cap on an ENVI header declaring 70000 one-pixel bands (**verified**):

```text
ERROR 1: Invalid band count : 70000. Maximum allowed currently is 65536. Define
GDAL_MAX_BAND_COUNT to a higher level if it is a legitimate number.
```

With `GDAL_MAX_BAND_COUNT=70000` the same file opens. A size budget lives in callers: the
OSS-Fuzz harness sets `GDAL_CACHEMAX` to 1000 MB ([`gdal_fuzzer.cpp`][fuzz-budget]) and
skips the pixel checksum when the blocks covering the read would exceed 10 MiB
([`gdal_fuzzer.cpp`][fuzz-checksum]). The network layer is a second surface: the guide
lists unwanted network access as a vulnerability class and credential handling as a
known issue, and since 3.13.2 the `header_file` key of a `/vsicurl?` filename is
restricted by default to files under `/vsimem/`, `/tmp` or `TEMP`/`TMP`
(`CPL_VSIL_CURL_HEADER_FILE_KVP_ENABLED`, [`configoptions.rst`][doc-cfg-headerfile]). The
COG trailer check is a small, honest integrity measure: an optimised reader trusts the
leader only when the trailer agrees. Compare [libtiff's limits][libtiff-hostile].

### 6. Allocation and ownership

The block cache is the owner of pixel memory. A block is pinned by `AddLock`/`DropLock`
while in use and evicted only at lock count zero, by a compare-and-exchange to -1 that
makes eviction and reacquisition race-free without a per-block mutex. The budget is one
process-wide number, so a viewer with many open datasets shares a single memory cap.
`/vsicurl/` keeps a second cache of downloaded regions keyed by URL, with its own budget
(`CPL_VSIL_CURL_CACHE_SIZE`), so compressed and decoded bytes are capped separately.
Dataset and band lifetime is manual (`GDALClose`), with reference counting on shared
datasets; the multidimensional API uses `std::shared_ptr`, and its root group _"can be
used after the dataset has been closed"_ ([`multidim_raster_data_model.rst`][doc-mdim-life]).

### 7. CPU parallelism and SIMD

The API is _"re-entrant, but (generally) not thread-safe"_
([`multithreading.rst`][doc-mt]): one dataset per thread, because a dataset owns a file
handle and its block structures. Since 3.10, `GDAL_OF_THREAD_SAFE` returns a read-only
wrapper that lazily opens one underlying dataset per thread. Inside a read, GTiff's
`MultiThreadedRead` submits one `ThreadDecompressionFunc` job per intersected tile to a
worker pool after issuing `AdviseRead` for the compressed bytes
([`gtiffdataset_read.cpp`][gtiff-mtread]); the `NUM_THREADS` open option enables it
(since 3.6, [`gtiff.rst`][doc-gtiff-threads]). SIMD is local: SSE2 and SSSE3 kernels for
word copying and deinterleaving (`GDALDeinterleave3Byte_SSSE3`, [`rasterio_ssse3.h`][ssse3])
and AVX2 in specific algorithms.

### 8. GPU offload and interop

Not applicable, because GDAL has no GPU path or interop: every read fills a
caller-supplied host buffer, and uploading pixels is the caller's job.

### 9. Temporal, animation and containers

There is no animation model. Time enters as data: a `TEMPORAL` dimension of a
`GDALMDArray` with an indexing variable, as netCDF, HDF5 and Zarr store it. Containers
are handled at the VSI level (`/vsizip/`, `/vsitar/`, `/vsigzip/`, `/vsisubfile/`) and by
subdatasets, a string-addressed list of the images inside one file. This keeps the
[container][c-container] concern below the driver, so a GeoTIFF inside a zip on S3 needs
no driver support.

### 10. Testing and conformance

The pytest suite under `autotest/` has 79 Python modules besides `__init__.py` in
`autotest/gcore/` alone,
including COG writer tests ([`autotest/gcore/cog.py`][test-cog]). Conformance for COG is
a separate validator, `validate_cloud_optimized_geotiff.py` ([source][cog-validate]),
which checks IFD order, tiling and overview presence rather than pixels. Fuzzing runs on
OSS-Fuzz with per-format harnesses that feed GDAL through `/vsimem/`
([`fuzzers/README.TXT`][fuzz-readme]). The debug logs used by the probe (`CPL_DEBUG=ON`
reporting every `VSICURL: Downloading a-b` range and every overview selection) double as
a test oracle for I/O behaviour: a test can assert how many requests a read costs.

## Lessons for Sparkles

- **Q1** A huge or remote image is a grid of independently decodable blocks, not a
  buffer. GDAL's block (x, y) of band b is the unit that I/O, cache, decode and threading
  all agree on; a Sparkles view type over a tiled source needs the same unit, with the
  window-to-blocks mapping in the core rather than in each codec.
- **Q1** Three byte strides (pixel, line, band) let one read fill any destination
  layout. This maps onto a strided mir `Slice` with the band axis explicit; GDAL's `int`
  extents are a limit Sparkles should not copy.
- **Q4** Overview selection belongs to the read API. A caller asks for a window at a
  buffer size and the library picks the pyramid level with a documented threshold; a
  viewer zooming out never decodes full resolution. Sparkles' tiled-image design can
  take the threshold table verbatim as a testable rule.
- **Q4** The byte layer needs batch verbs (`ReadMultiRange`, `AdviseRead`), not only
  `read(offset, len)`. A tiled decoder that can announce all its ranges up front lets
  HTTP coalesce them and lets `io_uring` submit them together. This is the seam the
  [event-horizon baseline][bl-eh] lacks (gap G7 in the [existing-code baseline][bl-existing]).
- **Q4** A layout convention can make random access cheap without changing the format:
  IFDs first, index arrays next, tiles in order, size leaders and trailer checks in
  ghost bytes. A Sparkles writer for tiled TIFF, or a native tiled container, can adopt
  the same "header in the first fetch" rule.
- **Q5** A metadata model can be domains of strings and still carry ICC bytes, but GDAL
  shows the cost: no colour management and no CICP. The geospatial fields (transform,
  CRS, nodata, scale and offset) are a separate requirement if scientific rasters are in
  scope.
- **Q6** The cache budget is global and the byte cache separate. A Sparkles image cache
  should state whether compressed bytes, decoded blocks and GPU tiles share one budget;
  GDAL's two separately budgeted caches show what an implicit split looks like.
- **Q8** Request counts are a property worth testing. GDAL's debug ranges make "a
  thumbnail costs two GETs" checkable; a Sparkles remote reader can expose the same
  trace to its tests.
- **Q8** Limits enforced by a library (band count) and limits left to callers (pixel
  budget in the fuzz harness) should be explicit in the API, as `GDALCheckDatasetDimensions`
  shows by checking almost nothing.
- **Q9** GDAL is evidence for a split between a format-agnostic core (dataset, band,
  block cache, `RasterIO`, VSI) and many format drivers registered at runtime. The driver
  count is the payoff; the attack surface is the price.

## Strengths

- Windows of any size, at any scale, from any storage, through one call.
- Overviews and resampling built into reads, with a documented selection rule.
- The VSI layer: prefix-chained handlers, multi-range and advisory reads, in-memory files
  that borrow buffers.
- COG layout and its ghost-area flags let an optimised reader skip index arrays while a
  plain TIFF reader still works.
- Mature fuzzing on OSS-Fuzz and an extensive pytest suite.

## Weaknesses

- A large attack surface by design; core sanity checks are thin and the security guide
  pushes budgets onto deployers.
- `int` raster dimensions and a classic model limited to 2-D bands; N-D is a separate,
  less integrated API.
- Datasets are not thread-safe; parallel reads need one dataset per thread or the
  read-only wrapper.
- Stringly typed configuration (config options, open and creation options) with global
  state such as `GDAL_CACHEMAX`.
- No colour management, no HDR model, no GPU path.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                         | Trade-off                                                                |
| -------------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------ |
| One band model (dataset, band, block) for every driver         | All drivers share caching, resampling and `RasterIO`              | Runtime dispatch and a type switch on every copy; `int` extents          |
| A global LRU block cache with one budget (`GDAL_CACHEMAX`)     | Memory stays bounded however many datasets are open               | Datasets compete for one cap; concurrent writers contend on its lock     |
| Overview selection inside `RasterIO` with a 1.2 threshold      | A zoomed-out read never touches full resolution                   | The chosen level depends on a config option and on the resampling kernel |
| Batch verbs on the byte layer (`ReadMultiRange`, `AdviseRead`) | HTTP range coalescing and parallel fetches                        | Each handler implements them or falls back to serial reads               |
| COG ghost-area flags in an otherwise ordinary TIFF             | Optimised readers skip `TileByteCounts`; plain readers still work | An unaware rewrite loses the layout; the trailer only detects it         |
| Limits and budgets left to deployers                           | The library stays general                                         | Hostile-input safety depends on configuration the caller must know about |

## Sources

- [OSGeo/gdal at `739fcf03b`][repo]: `gcore/` (dataset, band, block cache, `RasterIO`,
  multidimensional API), `port/` (VSI, `/vsicurl/`, `/vsimem/`), `frmts/gtiff/` (GTiff
  and COG), `fuzzers/`, `autotest/`.
- Documentation in `doc/source/`: [raster data model][doc-rdm], [multidimensional data
  model][doc-mdim], [virtual file systems][doc-vsi], [COG driver][doc-cog],
  [GTiff driver][doc-gtiff-icc], [security][doc-sec-surface], [multithreading][doc-mt].
- Probe: `/tmp/gdal-probe/run.sh`, `serve.sh` and `bands.sh`, run with nixpkgs GDAL 3.11.4
  and darkhttpd 1.17.
- Related deep-dives: [libtiff][libtiff], [OpenImageIO's `ImageCache`][oiio-cache],
  [libvips demand hints][vips-demand], [Concepts: tiling][c-tiling].

<!-- References -->

[repo]: https://github.com/OSGeo/gdal/tree/739fcf03bfcc075e300dbd45743187b380a17cdc
[docs]: https://gdal.org/
[lic]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/LICENSE.TXT#L13-L33
[readme]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/README.md#L23
[doc-rdm]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/raster_data_model.rst
[doc-rdm-limits]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/raster_data_model.rst#L14
[doc-rdm-imgstruct]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/raster_data_model.rst#L143-L148
[doc-cog]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/cog.rst
[doc-cog-high]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/cog.rst#L583-L592
[doc-cog-low]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/cog.rst#L597-L619
[doc-cog-ghost]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/cog.rst#L621-L652
[doc-cog-leader]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/cog.rst#L704-L734
[doc-vsi]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/virtual_file_systems.rst#L1-L40
[doc-vsicurl]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/virtual_file_systems.rst#L448-L451
[doc-mdim]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/multidim_raster_data_model.rst#L7-L17
[doc-mdim-order]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/multidim_raster_data_model.rst#L45-L52
[doc-gtiff-icc]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/gtiff.rst#L428-L449
[doc-gtiff-threads]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/drivers/raster/gtiff.rst#L546-L557
[doc-sec-surface]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/security.rst#L11-L13
[doc-sec-mitigate]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/security.rst#L63-L100
[doc-mt]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/multithreading.rst#L7-L62
[rb-hooks]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal_rasterband.h#L243-L250
[ds-rasterio]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal_dataset.h#L138-L143
[rblock-h]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal_rasterblock.h#L32-L59
[rblock-doc]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalrasterblock.cpp#L326-L348
[rblock-cachemax]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalrasterblock.cpp#L228
[rblock-evict]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalrasterblock.cpp#L871-L955
[arraycache]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalarraybandblockcache.cpp#L31-L33
[rb-cachechoice]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalrasterband.cpp#L1609-L1635
[rb-ovrdoc]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalrasterband.cpp#L150-L178
[rio-bestovr]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/rasterio.cpp#L4640-L4676
[gdalh-resample]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal.h#L135-L163
[gdalh-extraarg]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal.h#L165-L222
[openinfo-ingest]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdalopeninfo.cpp#L298-L303
[drv-identify]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal_driver.h#L192-L201
[gtiff-identify]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/frmts/gtiff/gtiffdataset_read.cpp#L3431-L3468
[gtiff-defer]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/frmts/gtiff/gtiffdataset_read.cpp#L3819-L3826
[gtiff-structmd]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/frmts/gtiff/gtiffdataset_read.cpp#L3873-L3935
[gtiff-trailer]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/frmts/gtiff/gtiffdataset_read.cpp#L6804-L6819
[gtiff-mtread]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/frmts/gtiff/gtiffdataset_read.cpp#L1449-L1460
[vsi-handle]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsi_virtual.h#L128-L210
[vsimem]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsi_mem.cpp#L117-L139
[curl-chunk]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsil_curl.cpp#L181-L255
[curl-readahead]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsil_curl.cpp#L2922-L2936
[curl-perform]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsil_curl.cpp#L1111-L1136
[curl-run]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsil_curl.cpp#L1245-L1275
[cog-ovrloop]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/frmts/gtiff/cogdriver.cpp#L1091-L1111
[doc-cfg-headerfile]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/configoptions.rst#L650-L662
[curl-multirange]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/port/cpl_vsil_curl.cpp#L3035-L3086
[mdim-iread]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/multidim/gdal_multidim.h#L561-L566
[mdim-views]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/multidim/gdal_multidim.h#L1037-L1093
[misc-checks]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/gdal_misc.cpp#L4892-L4936
[ssse3]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/gcore/rasterio_ssse3.h#L21-L28
[fuzz-budget]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/fuzzers/gdal_fuzzer.cpp#L80
[fuzz-checksum]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/fuzzers/gdal_fuzzer.cpp#L261-L357
[doc-rdm-types]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/raster_data_model.rst#L302
[doc-mdim-life]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/doc/source/user/multidim_raster_data_model.rst#L120-L125
[fuzz-readme]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/fuzzers/README.TXT#L1-L13
[test-cog]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/autotest/gcore/cog.py
[cog-validate]: https://github.com/OSGeo/gdal/blob/739fcf03bfcc075e300dbd45743187b380a17cdc/swig/python/gdal-utils/osgeo_utils/samples/validate_cloud_optimized_geotiff.py
[libtiff]: ./libtiff.md
[libtiff-hostile]: ./libtiff.md#_5-hostile-input-and-safety
[wuffs]: ./wuffs.md
[mir]: ./mir-algorithm/
[numpy]: ./numpy-buffer-protocol.md
[oiio-cache]: ./openimageio.md#imagecache-and-texturesystem
[vips-demand]: ./libvips.md#demand-hints
[bl-eh]: ./baseline/event-horizon.md
[bl-existing]: ./baseline/existing-code.md#gaps-and-tensions
[c-container]: ./concepts.md#container-and-bitstream
[c-stride]: ./concepts.md#stride
[c-tiling]: ./concepts.md#tiling
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-meta]: ./concepts.md#image-metadata
