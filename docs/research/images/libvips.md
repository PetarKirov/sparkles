# libvips (C)

A demand-driven, horizontally threaded image-processing library in C over GObject:
partial images form a lazy graph, and sinks pull pixels through it in regions.
Streaming pipelines avoid full intermediates, but memory also depends on image width,
codec behaviour and operations that require the whole image.

| Field         | Value                                                                                              |
| ------------- | -------------------------------------------------------------------------------------------------- |
| Language      | C (`gnu11`), with C++ for the Highway SIMD kernels and the `cplusplus/` binding                    |
| License       | LGPL-2.1-or-later ([`LICENSE`][license], [`README.md`][readme])                                    |
| Repository    | [libvips/libvips][repo]                                                                            |
| Revision read | `b8242162f09585ce5b4029cdb7fe95de186dde1a` (`meson.build` version `8.19.0`, "Merge branch '8.18'") |
| Documentation | [libvips.org/API/current][docs]; the `doc/` tree, in particular [`how-it-works.md`][hiw]           |
| Category      | Generic libraries                                                                                  |
| Tier          | A                                                                                                  |
| Last reviewed | November 15, 2026                                                                                  |

> [!NOTE]
> libvips supplies the survey's run-time [pull pipeline][concepts-pushpull]: C
> callbacks fill rectangles, with per-operation geometry hints. [Halide][halide]
> instead separates algorithm and schedule before compilation. Behaviour marked
> **verified** below was independently rerun on November 15, 2026 against the pinned
> `8.19.0` source, built with nixpkgs packaging and dependencies. Memory figures
> describe that build and machine, not portable bounds.

---

## Overview

### What it solves

Image-server and slide-scanner pipelines can exceed RAM if every intermediate is
materialised. libvips keeps regions instead ([`how-it-works.md`][hiw-intro]):

> _"Compared to most image processing libraries, libvips needs little RAM and runs
> quickly, especially on machines with more than one CPU. libvips achieves this
> improvement by only keeping the pixels currently being processed in RAM
> and by having an efficient, threaded image IO system."_

It supports about 300 operations, ten numeric band formats from 8-bit integer to
128-bit complex, arbitrary band counts within dimension limits, many codecs and
ImageMagick as a fallback ([`README.md`][readme-intro]).

### Design philosophy

1. **An image can be a function.** A partial image stores "a function which can make
   any rectangular area of pixels on demand" ([`how-it-works.md`][hiw-partial]).
2. **Non-mutating operations can be cached.** Operations normally create new images;
   mutating draw operations emit `invalidate` to flush downstream caches
   ([`how-it-works.md`][hiw-ops], [`how-it-works.md`][hiw-cache]).
3. **Sequence setup separates state from computation.** "Start and stop functions
   are mutually exclusive and a state is never used by more than one generate."
   ([`how-it-works.md`][hiw-partial]). This does not prohibit allocation or locking
   inside generate callbacks.

Images are "uninterpreted arrays": callers must supply the appropriate colour
interpretation for each operation ([`image.c`][image-c-doc]).

---

## How it works

### `VipsImage`: a descriptor that may have no pixels

`struct _VipsImage` holds `int` width, height and bands, `VipsBandFormat`,
`VipsCoding`, an advisory `VipsInterpretation`, resolution and `GValue` metadata
([`image.h`][image-h-struct]). `VipsImageType` distinguishes owned memory,
caller-owned memory, file windows, mapped files, output files and partial images
([`image.h`][image-h-types]). A partial image stores `start_fn`, `generate_fn`,
`stop_fn`, two client pointers, the start/stop mutex and a demand hint
([`image.h`][image-h-partial]). Start returns per-sequence state; generate receives
that state and an output region; stop frees it ([`image.h`][image-h-fns]).

### `VipsRegion`: a strided window with an origin

A region holds its image, a `VipsRect valid` in that image's coordinates, a `data`
pointer and `bpl` (bytes per line) ([`region.h`][region-h-struct]). Its backing may
be a buffer, borrowed image/region memory or a file window
([`private.h`][private-regiontype]). `VIPS_REGION_ADDR` offsets from `valid.left`
and `valid.top` using line stride and pixel size; only `-DDEBUG` adds bounds checks
and `abort()` ([`region.h`][region-h-addr]). `extract_area` remaps coordinates and
aliases input memory ([`extract.c`][extract-gen]). Bands remain interleaved
([stride][concepts-stride]; [layouts][concepts-planar]).

`vips_region_prepare(reg, r)` makes the intersection with the image addressable
([`region.c`][region-prepare]). Partial images fill a buffer unless already `done`;
memory/mapped images borrow existing bytes ([`region.c`][region-fill]). Worker-local
`VipsBufferCache` entries can reuse finished buffers. Buffers "can move between
caches and between threads, but not between images" ([`private.h`][private-buffer]);
non-libvips threads do not receive this cache ([`buffer.c`][buffer-workers]).

### Writing an operation

The `negative` example's `build` validates inputs, creates the output, declares
`VIPS_DEMAND_STYLE_THINSTRIP` with `vips_image_pipelinev`, then attaches callbacks
with `vips_image_generate` ([`extending.md`][ext-build]). Its generate callback
prepares the input rectangle and fills `out->valid`; `vips_start_one` and
`vips_stop_one` create and free an input region per sequence. `gboolean *stop`
supports early termination ([`extending.md`][ext-gen]). Area operations enlarge the
input rectangle; transforms remap it; `vips_region_region` aliases existing pixels
([`extending.md`][ext-other]). `vips_image_generate` checks that the demand hint was
set, stores callbacks for `PARTIAL`, and evaluates memory/file outputs immediately
with `vips_sink_memory` or `vips_sink_disc` ([`generate.c`][gen-generate]).

### Sequences and the start/stop lock

`vips__region_start` takes `image->sslock`, calls `start_fn` and stores the result in
`region->seq`; `vips__region_stop` takes the same lock to call `stop_fn`
([`region.c`][region-start]). This serialises start and stop callbacks on the same
image; it does not lock generate calls or shared state passed through `a` and `b`.
Each sequence is used by only one generate at a time. Regions are bound to
their creating thread; [`using-threads.md`][threads-region] warns that "to reduce
locking, `[class@Region]` keeps a lot of state in per-thread storage", and moving one
needs `vips__region_no_ownership()` and `vips__region_take_ownership()`.

### Demand hints

The preference enum orders `SMALLTILE`, `FATSTRIP`, `THINSTRIP`, `ANY`
([`image.h`][image-h-dhint]; [`image.c`][image-c-dhint]).
`vips__demand_hint_array` folds the numeric minimum over the operation and its inputs,
then records invalidation links ([`generate.c`][gen-hint]):

```c
set_hint = hint;
for (i = 0, len = 0; in[i]; i++, len++)
    set_hint = (VipsDemandStyle)
        VIPS_MIN((int) set_hint, (int) in[i]->dhint);
image->dhint = set_hint;
```

`vips_get_tile_size` maps `SMALLTILE` to 128 by 128; `FATSTRIP` and `ANY` to
full-width, 16-line strips; `THINSTRIP` uses one line only above width 10000.
Buffer height derives from concurrency and rounds to tile height, independently of
image dimensions ([`thread.c`][thread-tilesize]; [`private.h`][private-tiles]).

**Verified and independently rerun** on pinned `8.19.0`, concurrency 32: 1000 by 1000,
three-band `black` reports `any`, `invert` `thinstrip`, `gaussblur` (sigma 1.5,
default integer precision) and `rotate` (45 degrees) `smalltile`. The latter two use
128 by 128 tiles and `n_lines=640`. At the pinned revision the blur chain is
`gaussblur` → `convsep` → two `conv` calls → `convi`, which requests `SMALLTILE`
([`gaussblur.c`][gaussblur-build]; [`convsep.c`][convsep-build]; [`conv.c`][conv-build];
[`convi.c`][convi-hint]). The documented `FATSTRIP` example for `conv` therefore
differs from its integer path. Hints do not constrain request sizes
([`extending.md`][ext-hint]).

### Sinks and the threadpool

"In a demand-driven system, something has to do the demanding"
([`how-it-works.md`][hiw-sinks]). The sinks are `vips_sink_disc` (stream to a file),
`vips_sink_memory`, `vips_sink` (loop over an image for statistics), `vips_sink_tile`
and `vips_sink_screen` ([`libvips-generate.md`][doc-generate]). All run on
`vips_threadpool_run` ([`threadpool.c`][tp-run]), which takes four callbacks: `start`
(per-thread state, a `VipsThreadState` subclass holding a region), `allocate` (pick the
next work unit, run under `allocate_lock`, "always single-threaded"), `work` (fill the
tile, many at once) and `progress`. The pool starts at `1 + max_workers / 2` workers
and adapts to instrumented mutex and condition waits, including loader/cache waits
(`n_waiting > 3` shrinks, `< 2` grows; [`threadpool.c`][tp-run],
[`wait accounting`][tp-waits]).

The disc sink double-buffers ([`sinkdisc.c`][sinkdisc-struct]): `Write` holds `buf`,
being filled by workers tile by tile, and `buf_back`, held by a background thread that
writes complete scanlines through the format library when the last tile of the buffer
lands ([`how-it-works.md`][hiw-sinks]). The display sink, `vips_sink_screen`, renders
in the background into a tile cache, returns immediately from `vips_region_prepare`
with "whatever is currently in cache", exposes a one-band mask of valid pixels, and
calls a `notify_fn` from a worker when new tiles land. With a `NULL` callback it
runs synchronously instead ([`sinkscreen.c`][sinkscreen]).

**Verifier measurement** on pinned `8.19.0` (x86_64, 32 hardware threads,
`getrusage` peak RSS in fresh children): a 40000 by 40000 three-band `uchar`
virtual image (4.8 GB uncompressed; `black`,
`linear1` with scale 1, offset 128 and `uchar=TRUE`, `gaussblur` sigma 1.5) streamed
to JPEG peaked at 50.4 MiB with `VIPS_CONCURRENCY=1`, 53.7 MiB with 4 and
215.0–216.8 MiB in two runs with 32; pre-write peaks were about 18 MiB.
A 40000 by 10000 run at concurrency 1 peaked at 50.2 MiB. This supports streaming
with a working set insensitive to height for this pipeline, not a bound independent
of dimensions: the disc sink buffers
full-width strips. RSS varies; these are measurements, not memory bounds.

### Operations, introspection and the cache

Operations subclass `VipsOperation` ([`operation.h`][op-h]). `VIPS_ARG_*` declarations
record names, priorities, descriptions, flags, offsets and numeric limits for the CLI
and bindings ([`extending.md`][ext-class]; [`how-it-works.md`][hiw-db]). C varargs
calls have "almost no compile-time type checking"; wrappers add typed required
arguments ([`extending.md`][ext-call]).

`vips_cache_operation_buildp` reuses matching operations. Its hash covers type and
assigned, hashable construction inputs, excluding `VIPS_ARGUMENT_NON_HASHABLE`
([`cache.c`][cache-hash], [`cache.c`][cache-buildp]). Defaults are 100 operations,
100 tracked open files and 100 MiB tracked memory ([`cache.c`][cache-max]). Flags
include `NOCACHE`, `REVALIDATE`, `SEQUENTIAL`, `DEPRECATED`, `UNTRUSTED`, `BLOCKED`
([`operation.h`][op-flags]).

### Loaders, savers and sources

`VipsForeignLoad` subclasses declare sniffers, flags, `header` and optional `load`
methods ([`foreign.h`][foreign-h-load]). With a separate `load`, the framework defers
that method to first pixel demand ([`foreign.c`][foreign-build]) and selects backing
through `vips_foreign_load_temp` ([`foreign.c`][foreign-temp]):

| Condition                                                    | Backing                                 |
| ------------------------------------------------------------ | --------------------------------------- |
| `memory` forced                                              | `vips_image_new_memory()`               |
| loader flags `VIPS_FOREIGN_PARTIAL` (tiled TIFF, OpenEXR, …) | `vips_image_new()`: lazy, random access |
| `VIPS_FOREIGN_SEQUENTIAL` and access is not `RANDOM`         | `vips_image_new()`: lazy, top to bottom |
| decoded size above `vips_get_disc_threshold()`               | `vips_image_new_temp_file("%s.v")`      |
| otherwise                                                    | memory buffer                           |

`vips_foreign_load_iscompat` rejects differences in size, bands, format or coding
between header and load ([`foreign.c`][foreign-start]). **Verifier measurement** on
pinned `8.19.0`, concurrency 1: opening a black 12000 by 12000 one-band PNG sequentially
peaked at 18.4 MiB; `vips_avg` raised it to 24.4 MiB for 144 MB decoded pixels.
These are pipeline measurements, not fixed requirements.

Sequential mode adds a small line cache ([open strategies][open-full],
[sequential access][open-seq]). `vips_sequential` locks requests and reads skipped
lines into cache ([`sequential.c`][seq-gen]); sequential loaders in this mode are
`nocache` ([`foreign.c`][foreign-build]). Savers declare accepted colour/band models
and metadata retention through `VipsForeignSaveable` and `VipsForeignKeep`
([`foreign.h`][foreign-h-keep]). `VipsSource`/`VipsTarget` abstract byte I/O;
unseekable input is buffered for header replay ([`source.c`][source-doc]), with
pipe-to-memory reads capped at 1 GiB by default ([`source.c`][source-pipe]).

---

## Analysis

### 1. Pixel and memory model

Width, height and bands are positive `int`s, with interleaved bands and one of ten
native C band formats per image ([`how-it-works.md`][hiw-images];
[`image.c`][image-c-fmt]). There is no planar, subsampled or fourth-axis storage;
multipage images use a tall strip. One-bit TIFF samples expand to `uchar`
([`tiff2vips.c`][tiff-onebit]). `LABQ` packs Lab into four bytes; `RAD` stores
Radiance RGBE ([`image.c`][image-c-coding]).

Regions have line stride but no independent band or element stride.
`VIPS_DEFAULT_MAX_COORD` supplies a configurable 100-million limit
([`image.h`][image-h-maxcoord]); `vips_image_sanity` checks dimensions, multiplication
overflow and scanline bytes below `INT_MAX` ([`image.c`][image-sanity]). Byte sizes
use `size_t`/`guint64`. Evaluation tiles need not match storage tiles in tiled
TIFF/OpenEXR ([tiling][concepts-tiling]).

### 2. Genericity mechanism

Operation dispatch is GObject classes, properties, argument introspection and
`nickname`. Element dispatch is usually a `BandFmt` switch with per-type C macros.
`add` also keeps a ten-entry promotion table whose comment requires it to match
the switch ([`add.c`][add-loop], [`add.c`][add-table]). Format/coding checks happen
in `build` ([`extending.md`][ext-build]). Unlike [Boost.GIL][gil], this does not
encode pixel types or colour interpretation in the language's type system; compare
[generic image programming][p-generic].

### 3. Colour and metadata

`VipsInterpretation` carries an advisory colour tag ([`image.h`][image-h-interp]);
there are no independent transfer-function, primaries or alpha-mode fields.
"RGB and sRGB are treated in the same way" ([`image.c`][image-c-interp]). Alpha is
a trailing band; 2-by-2 region shrinking scales pixels by alpha to avoid fringing
([`region.h`][region-h-shrink]).

Little CMS 2 handles ICC. `vips_icc_build` shares a transform with `cmsFLAGS_NOCACHE`
to disable its one-pixel cache for thread safety ([`icc_transform.c`][icc-build]).
The profile is an `icc-profile-data` blob; libvips's PCS is Lab D65 or XYZ
([`icc_transform.c`][icc-pcs]). CICP travels as metadata; `CICP2scRGB` applies a
transfer LUT and primaries matrix to tagged RGB ([`CICP2scRGB.c`][cicp-build]).
Its matrix-coefficient and full-range fields are unused, so this is not general
YCbCr matrix/range conversion ([`CICP2scRGB.c`][cicp]). UltraHDR uses libultrahdr
as SDR plus gain-map metadata or full HDR scRGB ([`uhdr.md`][uhdr]). EXIF, XMP,
IPTC, Photoshop and orientation metadata travel separately ([`header.h`][header-meta]).
See [ICC][concepts-icc], [CICP][concepts-cicp], [gain maps][concepts-gainmap]
and the [colour papers][p-colour].

### 4. I/O and codec architecture

Pulling rectangles is incremental where the wrapped codec permits it: sequential
JPEG/PNG can stream, tiled TIFF/OpenEXR allow random access, and other paths decode
the whole image to memory or a temporary `.v` file ([open strategies][open-full],
[sequential access][open-seq]). `vips_region_prepare` blocks its calling thread;
libvips adds no suspend/resume protocol ([`region.c`][region-prepare]). `VipsSource`
wraps file, memory or custom read/seek callbacks; unseekable replay buffering ends
after the header phase ([`source.c`][source-doc]).

The `.v` spill format has a 64-byte header, contiguous pixels and an XML metadata
extension; rolling mapped windows let it exceed RAM ([`how-it-works.md`][hiw-v]).
Spilling supplies random access at the cost of full decoding and temporary storage.
See [pull decoding][concepts-pushpull] and [incremental decoding][concepts-incremental].

### 5. Hostile input and safety

- **Trust policy.** `UNTRUSTED` marks operations not hardened for hostile input
  ([`operation.c`][op-flags-doc]). `vips_block_untrusted_set(TRUE)` sets `BLOCKED`
  on them ([`init.c`][init-block]); `VIPS_BLOCK_UNTRUSTED` applies this at init
  ([`init.c`][init-block-env]). Subtree blocking can disable `VipsForeignLoad`
  then re-enable JPEG ([`operation.c`][op-block]). Blocked operations fail
  ([`operation.c`][op-build]); blocked loaders are excluded before sniffing
  ([`foreign.c`][foreign-file-add]). A pinned-tree search finds 26 loader/saver
  files setting `UNTRUSTED`; `foreign.c` only prints it. The security policy
  excludes reports against these loaders ([`SECURITY.md`][security]).
- **Strictness.** `VipsFailOn` orders `NONE`, `TRUNCATED`, `ERROR`, `WARNING`;
  each includes earlier levels ([`foreign.h`][foreign-h-failon]). Default `NONE`
  permits decoder recovery but does not guarantee truncated inputs load.
- **Limits.** Loader-specific limits include PNG text-chunk handling and failure
  at 100 JPEG warnings ([`vipspng.c`][png-text]; [`jpeg2vips.c`][jpeg-warn]).
  `unlimited` defaults to `vips_unlimited_get()`; fuzz builds remove that argument
  and make `vips_unlimited_set` a no-op ([`jpegload.c`][jpegload-unlimited];
  [`init.c`][init-unlimited]).
- **Geometry.** Sanity checks reject invalid dimensions/enums; header/load checks
  reject inconsistent dimensions, coding and format ([`image.c`][image-sanity];
  [`foreign.c`][foreign-start]). Pixel access remains unchecked without `DEBUG`.

**Verified and independently rerun** on pinned `8.19.0`: `VIPS_BLOCK_UNTRUSTED=1` prevents
loading a 64 by 64 PPM (unknown format), while PNG loads; PPM loads without it.
`vips -l` lists 68 untrusted classes in this build, dependent on enabled codecs.
See [hostile input][concepts-hostile] and the [safety papers][p-hostile-synth].

### 6. Allocation and ownership

GObjects are reference counted; regions retain their image and release attached buffers
([`region.c`][region-ownership]). Region buffers use `vips_tracked_aligned_alloc`
([`buffer.c`][tracked]); codec allocations need not be tracked. Each worker's per-image
cache reserves up to two spare buffers ([`buffer.c`][buffer-reserve]). Allocation reuse
is a design goal, not a guarantee for every callback ([`how-it-works.md`][hiw-join]).

`vips_region_region` aliases memory, as in the loader's copy ([`foreign.c`][foreign-gen]).
`VIPS_IMAGE_SETBUF_FOREIGN` leaves caller memory unfreed ([`image.h`][image-h-types]).
Errors return `-1`/`NULL` with messages in a process-wide buffer; a thread cannot
reliably associate its error return with one message ([`using-threads.md`][threads-errors]).

### 7. CPU parallelism and SIMD

Workers run private pipeline state on their tiles. The documentation claims
"four lock operations per output tile, regardless of the pipeline length or complexity"
([`how-it-works.md`][hiw-join]); sequential loaders add their own locking.
Concurrency defaults to hardware threads, clipped to 1..1024; Apple Silicon
prefers performance cores when discoverable. API, CLI and `VIPS_CONCURRENCY`
override it ([`thread.c`][thread-concurrency]). Threadpool pre-creation is supported
for wasm ([`threadpool.c`][tp-init]).

SIMD uses Highway dynamic dispatch; vector helpers select Orc when Highway is
absent ([`vector.cpp`][vector-init]). Kernel files re-include themselves through
`foreach_target.h`, use `ScalableTag` and export `HWY_DYNAMIC_DISPATCH` wrappers
([`shrinkv_hwy.cpp`][hwy-head], [`shrinkv_hwy.cpp`][hwy-export]). The shrink kernel
has scalar tails and SVE/RVV demotion workarounds ([`shrinkv_hwy.cpp`][hwy-body]).
Its vector path is selected in `build` for `uchar` when `vips_vector_isenabled()`;
other formats use the C loop ([`shrinkv.c`][shrinkv-choose]). Six kernel files cover
`convi`, `morph`, `reduceh`, `reducev`, `shrinkh` and `shrinkv`.
`vips_vector_get_supported_targets` excludes `HWY_EMU128` and `HWY_SCALAR`;
`VIPS_VECTOR` disables selected targets for testing ([`vector.cpp`][vector-targets]).
`composite.cpp` separately uses GCC vector arithmetic for RGBA `uchar`, `ushort`
and `float` ([`composite.cpp`][composite-vector]). The documented SIMD speedup of three or four is not measured here
([`how-it-works.md`][hiw-simd]).

### 8. GPU offload and interop

Not applicable: there is no GPU code path at this revision. A search of `libvips/`,
`doc/` and the build files for OpenCL, CUDA, Vulkan or GPU finds one comment in
`nohalo.cpp` referring to a paper title. The evaluation model assumes host memory:
a generate function fills a host buffer synchronously, one tile at a time, and nothing
in the tree addresses batching tiles for a device or measures a break-even. The
display sink's tile cache and `notify_fn` are the nearest thing to an interop
seam: an application uploads tiles as they become ready.

### 9. Temporal, animation and containers

Animation and multipage are "tall, thin strips of frames, like a strip of movie film"
([`multipage-and-animated-images.md`][multipage]): `page-height`, `n-pages`, `loop`
and a `delay` array in milliseconds are metadata; `n=-1` loads all frames and `page`
selects one. GIF, WebP and JPEG XL animate; APNG needs APNG-capable libpng
([`PNG support`][apng]); TIFF, PDF, HEIC, AVIF and `.v` are multipage. Ordinary pixel
operations see the strip; vertical filtering must handle frame boundaries explicitly.
One strip requires equal page sizes; unequal PDF/TIFF pages load individually.
There is no standard per-frame timestamp, public disposal state or video-frame abstraction
([`multipage documentation`][multipage-sizes]; [`video.h`][video-header]).

### 10. Testing and conformance

Two layers ([`test/README.md`][test-readme]): shell scripts under `meson test`
(threading, sequential access, stall, timeouts for GIF and WebP savers, CLI) and a
pytest suite over `pyvips` with 94 sample files under `test/test-suite/images`. The
arithmetic oracle is pixel-against-scalar: `run_cmp` reads one pixel, applies the
Python function to the number and to the image, and compares with `pytest.approx(..., abs=0.0001)`
([`helpers.py`][helpers-cmp]), across all ten formats ([`test_arithmetic.py`][test-arithmetic]). Codec tests save, reload and
assert a maximum absolute difference, `0` for lossless formats and a per-test bound
for lossy ones (`save_load_file` and friends, [`test_foreign.py`][test-foreign]);
there is no external conformance corpus pinned in the tree.

Fuzzing runs on OSS-Fuzz ([`README.md`][readme] badge, [`oss_fuzz_build.sh`][ossfuzz]).
`generic_buffer_fuzzer.cc` opens arbitrary bytes with `vips_image_new_from_buffer`,
rejects width/height above 100 or bands above 4, then saves at concurrency 1 to the format
selected by `SAVE_SUFFIX`. Separate targets select JPEG, PNG, TIFF and other savers
([`generic_buffer_fuzzer.cc`][fuzz-generic], [`fuzz/meson.build`][fuzz-build]); further targets cover thumbnail,
sharpen, smartcrop, mosaic and a JPEG save. Fuzz builds compile out `unlimited` and the
`system` operation ([`init.c`][init-fuzz-system]).

---

## Lessons for Sparkles

- **Q3 — Type the sequence contract.** Worker-owned state can replace `void *seq`,
  with optional start/stop hooks. Shared callback data and region thread affinity
  still need explicit rules ([thread rules][threads-region]; [baseline G7][bl-existing-gaps]).
- **Q1 — Use regions as a view model.** Pointer, stride and owning-image rectangle
  support crops and aliases. A checked `@safe` view needs more than one preparation
  check to justify inner-loop access ([baseline G2][bl-existing-gaps]; [mir][mir]; [Halide][halide]).
- **Q3 — Demand hints are a coarse schedule.** D could fold an enum over stage
  types without an IR; default integer `gaussblur` shows one stage changing sink
  geometry ([scheduling][concepts-schedule]; [DSL synthesis][p-dsl-synth]).
- **Q6, Q7 — Budget concurrency and buffering together.** The 4.8 GB pipeline
  peaked at 50.4 MiB on one thread and 215.0–216.8 MiB on 32. Full-width buffers couple
  memory to width and concurrency ([event-horizon baseline][bl-eh-gaps]).
- **Q4 — Separate header and pixel phases, then re-check geometry.** Two D
  operations can return `Expected`; resumability still needs storage or re-decoding
  for arbitrary access ([incremental decoding][concepts-incremental]; [baseline G1/G7][bl-existing-gaps]; [wired][bl-wired]).
- **Q4, Q8 — Filter probes by codec trust.** Codec UDAs or enums can feed a probe
  registry. Subtree blocking and ordered fail levels separate deployment trust from
  strictness ([baseline G1/G11][bl-existing-gaps]).
- **Q8 — Keep limits active in fuzz builds.** Removing `unlimited` tests the
  production limits. Arbitrary bytes, size rejection and re-encoding supply a first
  harness ([baseline G11][bl-existing-gaps]; [safety synthesis][p-hostile-synth]).
- **Q2 — Derive dynamic and typed interfaces together.** Argument UDAs could feed
  `sparkles:core-cli` and typed calls; element templates can replace the hand-kept
  format switch/promotion table ([generic programming][p-generic]; [SIMD baseline][bl-shaders-gaps]).
- **Q3, Q7 — Expose SIMD selection for testing.** Highway's scalable kernels extend
  the per-`@target` pattern; capability probes and target masks are useful controls.
  Its six kernels do not cover all libvips SIMD ([compositor][composite-vector]; [SIMD baseline][bl-shaders-gaps]).
- **Q5 — Blobs do not replace typed colour contracts.** Interpretation, ICC, CICP
  and gain maps support conversion without an alpha-mode type. lcms sharing requires
  cache discipline ([baseline G3/G4/G5][bl-existing-gaps]; [color][color]).
- **Q6 — Display sinks can expose tiles and validity.** A completion could carry
  `vips_sink_screen`-style tile notifications to a viewer
  ([image consumers][bl-existing-gaps]; [Vulkan][bl-vk]).
- **Q9 — Scheduling suggests a package seam.** libvips integrates engine and codecs
  with global state; it does not demonstrate an independent engine package. Global
  state alone does not exclude wasm ([threadpool][tp-init]; [baseline question 6][bl-existing-gaps]).

---

## Strengths

- Streaming avoids full intermediates for suitable pipelines; a 4.8 GB image
  streamed in 50.4 MiB on one thread in the verifier run, with width-dependent buffers.
- Region chaining needs no compiler: links are function calls, and small
  intermediates can fit in cache ([`how-it-works.md`][hiw-join]).
- Sequence-local state reduces shared mutable state; loaders can still add locks.
- Operation cache and invalidation follow from side-effect freedom; run-time
  introspection yields a uniform CLI and dynamic bindings.
- Explicit hostile-input policy: untrusted tagging, subtree blocking, fail levels,
  DoS limits that fuzz builds cannot disable, OSS-Fuzz coverage.
- Highway kernels cover x86, Arm (including SVE) and RISC-V from one source.
- Breadth: ten numeric formats including complex, many bands, about 300
  operations and a wide set of formats.

## Weaknesses

- No type safety for pixels or colour: an RGB image passed to `Lab2XYZ` "you'll just
  get nonsense" ([`image.c`][image-c-doc]); format/promotion invariants are kept by
  comments.
- `int` coordinates; unchecked pixel addressing in release builds; a global error
  buffer that cannot be matched to the failing call; implicit region thread affinity.
- Demand hints are coarse and can be dominated by one stage; documentation and code
  disagree on `conv`.
- Random access to a sequential codec requires full decode to memory or a temporary
  file; sequential pipelines can instead stream.
- Interleaved bands only; no planar, subsampled or N-D storage; animation as a strip
  with no timestamps.
- Highway acceleration covers six kernels for `uchar`; it is not the only SIMD path.
- No GPU path; deep GLib/GObject dependency rules out freestanding builds.

---

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                           | Trade-off                                                                                          |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Partial images: a function from rectangle to pixels           | Streaming can avoid full intermediates; separate header/load methods defer decoding | Whole-image algorithms (FFT, flood fill) need `wio_input`; memory images also permit direct access |
| Start/generate/stop with a per-image start/stop lock          | Serial setup/teardown and private sequence state reduce locking                     | Shared callback data needs its own discipline; regions need explicit thread handover               |
| Demand hint, folded by minimum                                | A schedule with one parameter, chosen at run time, no compiler                      | One `SMALLTILE` stage can dominate sink geometry                                                   |
| Double-buffered disc sink, full-width strips                  | Writers that need scanlines get them while workers fill the next buffer             | Buffer memory scales with image width times threads                                                |
| Side-effect-free operations with a hash-keyed cache           | Reuse across calls and threads; cheap repeated thumbnails                           | Stale results for replaced files (`revalidate` needed); mutation needs an invalidate signal        |
| GObject classes and run-time argument introspection           | One declaration feeds the CLI, `vips_call` and dynamic bindings                     | Little compile-time checking; varargs wrappers per operation                                       |
| Band format as a run-time tag with per-format macro loops     | Ten formats from one source file per operation                                      | Hand-kept promotion tables; Highway kernels specialise `uchar`                                     |
| Untrusted flag plus block list, filtered at sniffing          | Applications choose a hardened subset without rebuilding                            | Safety is a deployment setting; the default leaves untrusted loaders enabled                       |
| Spill non-random-access decodes to memory or a temp `.v` file | Any codec can feed a random-access pipeline                                         | Disc traffic and latency for large JPEG/PNG used out of order                                      |
| Highway dynamic dispatch, scalar fallback                     | One source per kernel across x86, Arm and RISC-V                                    | C++ in a C library; only a few kernels vectorised                                                  |

---

## Sources

- [libvips/libvips repository][repo] at `b8242162f09585ce5b4029cdb7fe95de186dde1a`; [API documentation][docs]
- [`README.md`][readme] · [`LICENSE`][license] · [`SECURITY.md`][security]
- [`doc/how-it-works.md`][hiw] — evaluation; [`doc/how-it-opens-files.md`][open-full] — open strategies
- [`doc/extending.md`][ext-build] — operations; [`doc/using-threads.md`][threads-region] — threads and errors
- [`doc/multipage-and-animated-images.md`][multipage] · [`doc/uhdr.md`][uhdr]
- Headers: [`image.h`][image-h-struct] · [`region.h`][region-h-struct] · [`private.h`][private-buffer] · [`operation.h`][op-h] · [`foreign.h`][foreign-h-load] · [`header.h`][header-meta]
- Engine (`libvips/iofuncs/`): [`generate.c`][gen-generate] · [`region.c`][region-prepare] · [`buffer.c`][tracked] · [`threadpool.c`][tp-run] · [`thread.c`][thread-tilesize] · [`sinkdisc.c`][sinkdisc-struct] · [`sinkscreen.c`][sinkscreen] · [`operation.c`][op-flags-doc] · [`init.c`][init-block] · [`cache.c`][cache-buildp] · [`vector.cpp`][vector-targets] · [`source.c`][source-doc]
- Operations and codecs: [`foreign.c`][foreign-build] · [`jpeg2vips.c`][jpeg-warn] · [`vipspng.c`][png-text] · [`jpegload.c`][jpegload-unlimited] · [`sequential.c`][seq-gen] · [`convi.c`][convi-hint] · [`add.c`][add-table] · [`shrinkv_hwy.cpp`][hwy-export] · [`shrinkv.c`][shrinkv-choose] · [`icc_transform.c`][icc-build] · [`CICP2scRGB.c`][cicp]
- Tests and fuzzing: [`generic_buffer_fuzzer.cc`][fuzz-generic] · [`oss_fuzz_build.sh`][ossfuzz] · [`test/README.md`][test-readme] · [`helpers.py`][helpers-cmp]
- Related in this survey: [Halide][halide] · [Boost.GIL][gil] · [mir-algorithm][mir] · [color][color] · [Concepts][concepts]

<!-- References -->

[repo]: https://github.com/libvips/libvips
[docs]: https://www.libvips.org/API/current/
[readme]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/README.md#L1-L15
[readme-intro]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/README.md#L17-L28
[license]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/LICENSE
[security]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/SECURITY.md#L14-L25
[hiw]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md
[hiw-intro]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L3-L7
[hiw-images]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L11-L15
[hiw-partial]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L61-L80
[hiw-ops]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L96-L102
[hiw-simd]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L104-L113
[hiw-join]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L125-L146
[hiw-v]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L163-L174
[hiw-sinks]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L178-L213
[hiw-cache]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L215-L228
[hiw-db]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-works.md#L230-L245
[open-full]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-opens-files.md#L21-L77
[open-seq]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/how-it-opens-files.md#L79-L119
[ext-class]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/extending.md#L73-L129
[ext-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/extending.md#L138-L166
[ext-hint]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/extending.md#L184-L188
[ext-gen]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/extending.md#L200-L265
[ext-call]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/extending.md#L286-L321
[ext-other]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/extending.md#L323-L348
[threads-errors]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/using-threads.md#L24-L39
[threads-region]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/using-threads.md#L41-L57
[multipage]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/multipage-and-animated-images.md#L3-L57
[uhdr]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/uhdr.md
[doc-generate]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/libvips-generate.md#L16-L30
[image-h-maxcoord]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L57-L65
[image-h-dhint]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L71-L77
[image-h-types]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L82-L92
[image-h-interp]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L94-L133
[image-h-fns]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L151-L154
[image-h-struct]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L189-L265
[image-h-partial]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/image.h#L250-L260
[image-c-doc]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/image.c#L98-L109
[image-c-dhint]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/image.c#L166-L201
[image-c-interp]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/image.c#L204-L236
[image-c-fmt]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/image.c#L239-L256
[image-c-coding]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/image.c#L258-L271
[image-sanity]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/image.c#L664-L723
[region-h-shrink]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/region.h#L65-L90
[region-h-struct]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/region.h#L96-L130
[region-h-addr]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/region.h#L201-L237
[private-buffer]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/private.h#L71-L109
[private-regiontype]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/private.h#L134-L142
[private-tiles]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/private.h#L144-L153
[op-flags]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/operation.h#L44-L54
[op-h]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/operation.h#L73-L102
[foreign-h-failon]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/foreign.h#L100-L127
[foreign-h-load]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/foreign.h#L144-L269
[foreign-h-keep]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/foreign.h#L304-L386
[header-meta]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/header.h#L46-L205
[gen-hint]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/generate.c#L276-L323
[gen-generate]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/generate.c#L679-L788
[region-start]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/region.c#L210-L267
[region-ownership]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/region.c#L273-L310
[region-fill]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/region.c#L845-L875
[region-prepare]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/region.c#L1760-L1846
[buffer-reserve]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/buffer.c#L86
[tp-init]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/threadpool.c#L108-L129
[tp-run]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/threadpool.c#L607-L717
[thread-concurrency]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/thread.c#L164-L270
[thread-tilesize]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/thread.c#L272-L352
[sinkdisc-struct]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/sinkdisc.c#L66-L97
[sinkscreen]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/sinkscreen.c#L1157-L1202
[op-flags-doc]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/operation.c#L163-L207
[op-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/operation.c#L587-L608
[op-block]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/operation.c#L1513-L1546
[init-fuzz-system]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/init.c#L596-L600
[init-block-env]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/init.c#L677-L678
[init-unlimited]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/init.c#L1326-L1344
[init-block]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/init.c#L1361-L1396
[cache-max]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/cache.c#L81-L94
[cache-hash]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/cache.c#L418-L470
[cache-buildp]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/cache.c#L1040-L1110
[vector-init]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/vector.cpp#L44-L107
[vector-targets]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/vector.cpp#L133-L187
[source-doc]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/source.c#L75-L105
[source-pipe]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/source.c#L117-L122
[tracked]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/buffer.c#L480-L502
[foreign-file-add]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/foreign.c#L430-L448
[foreign-temp]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/foreign.c#L913-L973
[foreign-start]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/foreign.c#L975-L1077
[foreign-gen]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/foreign.c#L1079-L1100
[foreign-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/foreign.c#L1102-L1202
[jpeg-warn]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/jpeg2vips.c#L350-L359
[png-text]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/vipspng.c#L958-L967
[tiff-onebit]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/tiff2vips.c#L1241-L1258
[jpegload-unlimited]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/jpegload.c#L201-L216
[seq-gen]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/conversion/sequential.c#L114-L184
[extract-gen]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/conversion/extract.c#L110-L134
[gaussblur-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/convolution/gaussblur.c#L80-L186
[convsep-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/convolution/convsep.c#L79-L112
[conv-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/convolution/conv.c#L94-L113
[convi-hint]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/convolution/convi.c#L1218-L1219
[add-loop]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/arithmetic/add.c#L93-L161
[add-table]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/arithmetic/add.c#L176-L182
[hwy-head]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/resample/shrinkv_hwy.cpp#L49-L67
[hwy-body]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/resample/shrinkv_hwy.cpp#L89-L198
[hwy-export]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/resample/shrinkv_hwy.cpp#L205-L228
[shrinkv-choose]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/resample/shrinkv.c#L535-L547
[icc-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/colour/icc_transform.c#L440-L469
[icc-pcs]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/colour/icc_transform.c#L119-L126
[cicp]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/colour/CICP2scRGB.c#L1-L75
[fuzz-generic]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/fuzz/generic_buffer_fuzzer.cc#L13-L67
[fuzz-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/fuzz/meson.build#L17-L102
[ossfuzz]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/fuzz/oss_fuzz_build.sh
[test-readme]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/test/README.md#L1-L5
[test-foreign]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/test/test-suite/test_foreign.py#L64-L110
[helpers-cmp]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/test/test-suite/helpers/helpers.py#L209-L235
[test-arithmetic]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/test/test-suite/test_arithmetic.py#L11-L43
[halide]: ./halide.md
[gil]: ./boost-gil.md
[mir]: ./mir-algorithm/index.md
[color]: ./color.md
[concepts]: ./concepts.md
[concepts-stride]: ./concepts.md#stride
[concepts-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[concepts-tiling]: ./concepts.md#tiling
[concepts-icc]: ./concepts.md#icc-profile
[concepts-cicp]: ./concepts.md#cicp
[concepts-gainmap]: ./concepts.md#hdr-gain-map
[concepts-pushpull]: ./concepts.md#push-and-pull-decoding
[concepts-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[concepts-hostile]: ./concepts.md#hostile-input
[concepts-schedule]: ./concepts.md#algorithm-and-schedule
[p-generic]: ./papers/generic-image-programming.md
[p-colour]: ./papers/resampling-colour.md
[p-dsl-synth]: ./papers/dsl-scheduling.md#thread-synthesis
[p-hostile-synth]: ./papers/hostile-input-safety.md#thread-synthesis
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders-gaps]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-eh-gaps]: ./baseline/event-horizon.md#gaps-and-tensions
[bl-vk]: ./baseline/vulkan.md
[bl-wired]: ./baseline/wired.md
[buffer-workers]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/buffer.c#L313-L355
[tp-waits]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/iofuncs/threadpool.c#L453-L475
[composite-vector]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/conversion/composite.cpp#L1362-L1415
[cicp-build]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/colour/CICP2scRGB.c#L357-L445
[multipage-sizes]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/doc/multipage-and-animated-images.md#L83-L89
[video-header]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/include/vips/video.h#L41-L46
[apng]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/foreign/pngsave.c#L480-L504
