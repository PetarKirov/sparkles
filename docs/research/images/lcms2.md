# Little CMS 2 (C)

The reference open-source ICC colour management engine: profiles in, a compiled per-pixel transform out, with pixel layouts named by one bit-packed 32-bit descriptor and a plug-in API that can replace almost every stage of the engine.

| Field         | Value                                                                                                                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C99 (C++17-compatible); plug-ins in C                                                                                                                                                           |
| License       | MIT for the core; the `fast_float` and `threaded` plug-ins are GPL-3.0 ([`plugins/README.1ST`][plugins-readme]) with a paid alternative ([fast float, p. 3][doc-ff]; [threaded, p. 3][doc-thr]) |
| Repository    | [mm2/Little-CMS][repo]                                                                                                                                                                          |
| Revision read | `5546f1d68136f94281c9f6bfc027c6cdf4898da8` (October 27, 2026, "add a guard against too much stages"; `LCMS_VERSION 2200`, release 2.20)                                                         |
| Documentation | [`LittleCMS2.20 API.pdf`][doc-api] · [tutorial][doc-tutorial] · [Plugin API][doc-plugin] · [fast float extensions][doc-ff] (all in `doc/` and `plugins/` of the repository)                     |
| Category      | Colour: colour management module (CMM)                                                                                                                                                          |
| Tier          | A                                                                                                                                                                                               |
| Last reviewed | November 7, 2026                                                                                                                                                                                |

> [!NOTE]
> **What was run.** A scratch program, `/tmp/lcms2-dive/probe/probe.c` (outside this
> repository), compiled the core, `fast_float` and `threaded` from a `git archive` of the
> pinned revision with GCC 14.3 `-O2` on an AMD Ryzen 9 7940HX (x86_64 Linux, 32 hardware
> threads). It decoded the `TYPE_*` descriptors, listed the stages of optimised pipelines,
> compared every one of the 2²⁴ 8-bit RGB inputs of an sRGB to Adobe-RGB-like transform
> against the float transform, tried malformed format and flag combinations, and timed
> each path (best of three runs). A second program, `probe16.c`, compared 16-bit paths
> against a `TYPE_RGB_DBL` reference. Results marked **verified** come from those runs;
> the timings are one machine, one profile pair and one compiler, and say nothing beyond
> that. The profile-parsing divergence against `skcms` is measured on the
> [ICC page][icc-hostile] and not repeated here.

---

## Overview

### What it solves

An image that carries an [ICC profile][c-icc] means nothing until a colour management
module (CMM) links that profile to the destination's through the profile connection
space and applies the result to every pixel. Little CMS (lcms2) is that module across
much of the open-source desktop: its [ChangeLog][changelog] fixes bugs reported against colord and
Krita, the CVE records name OpenJDK and GIMP as users of its 1.x predecessor, and
[libvips][libvips-icc] builds its `icc_transform` on it. Its README lists printer
firmware, monitors, cameras and RIPs among its users ([`README.md`][readme-story]). It
parses profiles of every class (input, display, output, link, abstract, named colour),
builds a transform for any pair or chain of them under any of four ICC intents plus six
vendor intents, and runs it over pixel buffers in 8-bit, 16-bit, half, float or double
layouts, interleaved or planar, with or without alpha.

The README states both the scope and the priority:

> "Little CMS intends to be an **OPEN SOURCE** small-footprint color management engine,
> with special focus on accuracy and performance."
> ([`README.md`][readme])

> "Little CMS is a **FULL IMPLEMENTATION** of ICC specification 4.4, it fully supports
> all kind of V2 and V4 profiles, including abstract, devicelink and named color
> profiles." ([`README.md`][readme-conf])

The profile format itself (header, tag table, curve and LUT types, the v2/v4 Lab
encodings) is covered on the [ICC page][icc]; this page is about the engine.

### Design philosophy

Four commitments shape the code.

1. **A transform is compiled once, then applied many times.** `cmsCreateTransform`
   reads the tags, links the profiles into a `cmsPipeline` of stages, hands it to an
   optimiser that may replace the whole thing with a lookup table or a fixed-point
   matrix-shaper, and picks a formatter pair and a per-pixel loop. `cmsDoTransform` then
   does no allocation, takes no lock and logs nothing: "This function is re-entrant. It
   never fails and it never send error logs. You can re-use same transform handle in
   different threads calling this function" ([API manual, `cmsDoTransform`][doc-api]).
2. **Errors are return values.** "When a function fails, it just return the failure
   status. For example, if a color transform cannot be created, the function returns NULL
   instead of a valid handle. ... This approach is more robust and can deal with
   multithreaded environments" ([tutorial][doc-tutorial]). The log hook is a debugging
   aid that receives a code and English text.
3. **Everything is a plug-in.** Thirteen plug-in types can replace the allocator,
   interpolators, curve types, formatters, tag types, tags, intents, multi-process
   elements, the optimiser, the whole transform, the mutex, the parallel scheduler and
   (from 2.20) the profile header reader. The Plugin API manual gives the reason plainly:
   "Licensing is another compelling reason; you can move all your intellectual property
   into plug-ins and be able to upgrade the core Little CMS library, keeping it in the open
   source side" ([Plugin API, p. 4][doc-plugin]). The two plug-ins in the tree,
   `fast_float` and `threaded`, are exactly that split: GPL-3.0 in the repository, sold
   under another licence ([fast float extensions, p. 3][doc-ff]).
4. **State lives in a context.** "Each context holds its owns globals and its own
   plug-ins. There is a global context with the id = 0 for lecacy compatibility though using
   the global context is not recommended" ([`lcms2.h`][h-context]). Most constructors
   and setters have a `...THR` twin that takes a `cmsContext`.

The security policy adds a fifth, defensive stance: "This is a color library, not an arena
for your war games", and "misusing the API does not by itself make it a vulnerability. ...
C itself is unsafe" ([`SECURITY.md`][security]).

---

## How it works

### Profiles

A profile is an opaque `cmsHPROFILE`. It comes from bytes (`cmsOpenProfileFromMem`,
`...FromFile`, `...FromIOhandler2`) or is synthesised in memory: `cmsCreate_sRGBProfile`,
`cmsCreateRGBProfile(whitePoint, primaries, curves)`, `cmsCreateGrayProfile`,
`cmsCreateLab4Profile`, `cmsCreateXYZProfile`, `cmsCreateLinearizationDeviceLink`,
`cmsCreateBCHSWabstractProfile` and others ([`lcms2.h`][h-builtin]). The built-in sRGB is
itself a `cmsCreateRGBProfileTHR` call with D65 and the Rec. 709 primaries, and its curve
is the parametric type 4 that encodes the sRGB piecewise function:

```c
// src/cmsvirt.c (abridged)
Parameters[0] = 2.4;
Parameters[1] = 1. / 1.055;
Parameters[2] = 0.055 / 1.055;
Parameters[3] = 1. / 12.92;
Parameters[4] = 0.04045;
return cmsBuildParametricToneCurve(ContextID, 4, Parameters);
```

([`cmsvirt.c`][virt-srgb])

`cmsOpenProfileFromMem` copies the caller's bytes into a block owned by a memory
`cmsIOHANDLER` (`_cmsMalloc` then `memmove`, [`cmsio0.c`][io-mem-open]), reads and checks
the header and tag directory eagerly, and leaves every tag unparsed. `cmsReadTag` parses a
tag on first access under the profile's mutex, caches the decoded object in
`Icc->TagPtrs[n]` and returns the cached pointer afterwards ([`cmsio0.c`][io-readtag]).

### The pixel-format descriptor

lcms2 names a buffer layout with one `cmsUInt32Number` whose bit fields are documented in
the public header:

```c
// include/lcms2.h
//                               2                1          0
//                        4 3 2 10987 6 5 4 3 2 1 098 7654 321
//                        M A O TTTTT U Y F P X S EEE CCCC BBB
//
//            M: Premultiplied alpha (only works when extra samples is 1)
//            A: Floating point -- With this flag we can differentiate 16 bits as float and as int
//            O: Optimized -- previous optimization already returns the final 8-bit value
//            T: Pixeltype
//            F: Flavor  0=MinIsBlack(Chocolate) 1=MinIsWhite(Vanilla)
//            P: Planar? 0=Chunky, 1=Planar
//            X: swap 16 bps endianness?
//            S: Do swap? ie, BGR, KYMC
//            E: Extra samples
//            C: Channels (Samples per pixel)
//            B: bytes per sample
//            Y: Swap first - changes ABGR to BGRA and KCMY to CMYK
```

([`lcms2.h`][h-format])

Constructor macros (`COLORSPACE_SH`, `CHANNELS_SH`, `EXTRA_SH`, `BYTES_SH`, `DOSWAP_SH`,
`SWAPFIRST_SH`, `PLANAR_SH`, `ENDIAN16_SH`, `FLAVOR_SH`, `FLOAT_SH`, `PREMUL_SH`) build a
descriptor, and `T_*` macros take it apart. The named `TYPE_*` constants are just
combinations ([`lcms2.h`][h-types]). Decoding a few (**verified**):

| Constant             | Value        | Fields set                                               |
| -------------------- | ------------ | -------------------------------------------------------- |
| `TYPE_RGB_8`         | `0x00040019` | space `PT_RGB`, 3 channels, 1 byte                       |
| `TYPE_RGBA_8`        | `0x00040099` | as above, 1 extra sample                                 |
| `TYPE_BGRA_8`        | `0x00044499` | as above, `DOSWAP` and `SWAPFIRST`                       |
| `TYPE_ARGB_8`        | `0x00044099` | as above, `SWAPFIRST` only                               |
| `TYPE_RGBA_8_PREMUL` | `0x00840099` | as `TYPE_RGBA_8`, `PREMUL`                               |
| `TYPE_RGB_16`        | `0x0004001A` | 2 bytes                                                  |
| `TYPE_RGB_HALF_FLT`  | `0x0044001A` | 2 bytes and `FLOAT`: half precision                      |
| `TYPE_RGBA_FLT`      | `0x0044009C` | 4 bytes and `FLOAT`                                      |
| `TYPE_RGB_DBL`       | `0x00440018` | 0 bytes and `FLOAT`: double, because the field is 3 bits |
| `TYPE_RGB_15`        | `0x0404001A` | `fast_float`'s bit 26 (`BIT15_SH`) on top of `RGB_16`    |

Channel order is not stored as a permutation. It is the colour space's canonical order
(RGB, CMYK) modified by two booleans: `DOSWAP` reverses the whole pixel (`RGB` to `BGR`,
`RGBA` to `ABGR`), and `SWAPFIRST` rotates the first sample to the end or back
(`ARGB`, and with `DOSWAP`, `BGRA`). Names read in memory order, so `TYPE_BGRA_8` is
blue at the lowest address, which matches Vulkan's non-packed names and Wuffs' convention
([pixel format names][c-pixfmt]). The descriptor carries the
[interleaved or planar][c-planar] choice but no [stride][c-stride]: strides are call
arguments.

### Formatters: descriptor to 16-bit or float

The descriptor is not interpreted per pixel. At transform creation `_cmsGetFormatter`
asks each formatter plug-in's factory, then falls back to stock tables that pair a
`Type` with a `Mask` of ignored bits and a function; the first entry with
`(dwInput & ~f->Mask) == f->Type` wins ([`cmspack.c`][pack-get], [`cmspack.c`][pack-stock]):

```c
// src/cmspack.c (abridged)
{ CHANNELS_SH(3)|BYTES_SH(1),                              ANYSPACE,  Unroll3Bytes},
{ CHANNELS_SH(3)|BYTES_SH(1)|DOSWAP_SH(1),                 ANYSPACE,  Unroll3BytesSwap},
{ CHANNELS_SH(3)|EXTRA_SH(1)|BYTES_SH(1)|DOSWAP_SH(1),     ANYSPACE,  Unroll3BytesSkip1Swap},
{ CHANNELS_SH(4)|BYTES_SH(1),                              ANYSPACE,  Unroll4Bytes},
```

([`cmspack.c`][pack-table])

An input formatter ("unroll") reads one pixel into `cmsUInt16Number wIn[cmsMAXCHANNELS]`
or `cmsFloat32Number[]` and returns the advanced pointer; an output formatter ("pack")
does the reverse. Specialised entries exist for common shapes and generic ones
(`UnrollChunkyBytes`, `UnrollPlanarBytes`) catch the rest. 8-bit values widen to 16 bits by
byte replication, `FROM_8_TO_16(rgb)` = `(rgb << 8) | rgb`, and narrow by a rounding
multiply ([`lcms2_internal.h`][int-8to16]). An unsupported combination fails at creation
with "Unsupported raster format" (**verified** for `BYTES_SH(3)`).

### Linking: intents, black point compensation, adaptation

`cmsCreateTransform` is a thin wrapper over `cmsCreateExtendedTransform`, which takes up
to 255 profiles, a per-profile intent, black point compensation (BPC) flag and
chromatic-adaptation state, an optional gamut-check profile, two descriptors and flags
([`lcms2.h`][h-xform-api]). It checks the colour space of each end against the descriptor
(`IsProperColorSpace`; `PT_ANY` skips the check), then calls `_cmsLinkProfiles`
([`cmsxform.c`][xf-extended]). Linking applies two policy rules before dispatching on the
first intent: absolute colorimetric never uses BPC, and "Force BPC for V4 profiles in
perceptual and saturation" ([`cmscnvrt.c`][cnvrt-link]). Intents are a linked list of
`{code, description, link function}` entries; the default list maps the four ICC intents
to `DefaultICCintents` and codes 10 to 15 to the two black-preserving CMYK handlers
([`cmscnvrt.c`][cnvrt-intents]). An intent plug-in prepends entries to that list.

The result is a `cmsPipeline`: a doubly evaluable list of `cmsStage`s (curve sets
`cvst`, matrices `matf`, CLUTs `clut`, Lab/XYZ conversions, named colours), each with a
16-bit and a float evaluator.

### Optimisation

`_cmsOptimizePipeline` first runs `PreOptimize` (drop identities, join adjacent matrices,
remove Lab/XYZ round trips), then tries the optimisation plug-ins, then the built-in list
in order, stopping at the first that claims the pipeline ([`cmsopt.c`][opt-entry]):

```c
// src/cmsopt.c
static _cmsOptimizationCollection DefaultOptimization[] = {

    { OptimizeByJoiningCurves,            &DefaultOptimization[1] },
    { OptimizeMatrixShaper,               &DefaultOptimization[2] },
    { OptimizeByComputingLinearization,   &DefaultOptimization[3] },
    { OptimizeByResampling,               NULL }
};
```

([`cmsopt.c`][opt-list])

- **Joining curves**: a pipeline of curves only becomes one table per channel.
- **Matrix-shaper**: RGB to RGB with 8-bit input and the shape curve, matrix (or two),
  curve becomes `MatShaperEval16`, which looks up a first shaper into 1.14 signed fixed
  point, multiplies by the matrix in integers and looks up a second shaper over 16 385
  entries. Its comment: "Actually it takes 256x3 16 bits tables and 16385 x 3 tables of 8
  bits, in total about 50K, and the performance boost is huge!" ([`cmsopt.c`][opt-matsh]).
- **Linearisation**: pre-linearisation curves plus a CLUT, for chunky RGB to RGB when
  the derived curves are monotonic, not degenerate and invertible; on 16-bit input only if the
  caller sets `cmsFLAGS_CLUT_PRE_LINEARIZATION` ([`cmsopt.c`][opt-linear]).
- **Resampling**: sample the whole pipeline into a CLUT whose grid size comes from
  `_cmsReasonableGridpointsByColorspace` (33 points for RGB by default, 49 with
  `cmsFLAGS_HIGHRESPRECALC`, 17 with `LOWRESPRECALC`, or `cmsFLAGS_GRIDPOINTS(n)`), with
  white-point fix-up; it states "This is a lossy optimization! does not apply in
  floating-point cases" ([`cmsopt.c`][opt-resample], [`cmspcs.c`][pcs-grid]).

`cmsFLAGS_NOOPTIMIZE` keeps the full pipeline; `cmsFLAGS_FORCE_CLUT` forces resampling.
Float descriptors on either side skip the lossy optimisations, and a 16-bit transform
whose first profile is RGB with a detected gamma below 1.6 disables optimisation, since a
CLUT on linear data loses the shadows ([`cmsxform.c`][xf-linear]).

### The per-pixel loop

`AllocEmptyTransform` lets a transform plug-in take the whole job first; otherwise it
selects formatters and one of seven loops: `FloatXFORM`, `NullFloatXFORM`, `NullXFORM`,
`PrecalculatedXFORM`, `CachedXFORM` and the gamut-check variants of the last two
([`cmsxform.c`][xf-alloc]). The 16-bit loop is three indirect calls per pixel:

```c
// src/cmsxform.c, PrecalculatedXFORM
accum = p->FromInput(p, wIn, accum, Stride->BytesPerPlaneIn);
p->Lut->Eval16Fn(wIn, wOut, p->Lut->Data);
output = p->ToOutput(p, wOut, output, Stride->BytesPerPlaneOut);
```

([`cmsxform.c`][xf-precalc])

`CachedXFORM` adds a one-pixel cache: if the unrolled input equals the previous pixel's,
it reuses the output. The cache is copied from the transform into a stack local at the
start of each call, `memcpy(&Cache, &p->Cache, sizeof(Cache))`, so concurrent calls on
one transform never write shared state ([`cmsxform.c`][xf-cached]). Alpha and other extra
channels are untouched unless `cmsFLAGS_COPY_ALPHA` is set, in which case
`_cmsHandleExtraChannels` copies them and the descriptors must agree on the extra count
(**verified**: without the flag the output alpha byte kept its previous value; with it,
the input alpha was copied; with `TYPE_RGBA_8` in and `TYPE_RGB_8` out, creation failed
with "Mismatched alpha channels").

`cmsDoTransform(xform, in, out, n)` processes one line; `cmsDoTransformLineStride` takes
pixels per line, line count, bytes per line and bytes per plane for both sides, through a
`cmsStride` record ([`cmsxform.c`][xf-do], [`lcms2_plugin.h`][plug-xform]).

### Plug-ins and contexts

A plug-in is a static struct that begins with `cmsPluginBase`: magic `'acpp'`, expected
library version, a type signature and a `Next` pointer, so one entry point can register a
chain of plug-ins of different types ([`lcms2_plugin.h`][plug-base]). A context
(`struct _cmsContext_struct`) is a sub-allocator plus an array of per-subsystem "chunks",
one per `_cmsMemoryClient` value: user data, logger, alarm codes, adaptation state and one
slot per plug-in type; a `NULL` chunk falls back to the global context
([`lcms2_internal.h`][int-context]). `cmsCreateContext(plugin, userData)` installs plug-ins
at creation; `cmsDupContext` clones one. Profiles and transforms remember their context
and allocate through its memory handler.

`fast_float` registers a formatter factory (the 15-bit Photoshop and dithered 8-bit
formats, on descriptor bits 26 and 27 that the core leaves unused) and a full-transform
factory, `Floating_Point_Transforms_Dispatcher`, which tries eleven specialised
optimisers in order: 15-bit matrix-shaper, 8-bit joined curves, an SSE2 8-bit
matrix-shaper, a scalar 8-bit matrix-shaper, float curves, float matrix-shaper, 8-bit and
16-bit prelinearisation plus tetrahedral, and float RGB, CMYK and Lab CLUTs
([`fast_float_sup.c`][ff-dispatch], [`lcms2_fast_float.h`][ff-header]). `threaded`
registers a parallelisation plug-in whose scheduler wraps whatever loop was chosen
([`threaded_scheduler.c`][thr-sched]).

---

## Analysis

### 1. Pixel and memory model

A transform sees a buffer as a base pointer, a pixel count per line, a line count, and
byte strides between lines and between planes, with the per-sample layout fixed in the
32-bit descriptor at creation. Interleaved ("chunky") and planar are both supported;
there is no tiling, no subsampled chroma (`PT_YCbCr` is a colour space; the descriptor has no subsampling field, so every pixel carries all its samples, which is 4:4:4), no
N-D extent and no bit depth other than 8, 16, half, float, double and `fast_float`'s 15.
Up to 15 colour channels plus up to 7 extra samples fit in the fields (`cmsMAXCHANNELS`
is 16). The descriptor packs colour model, component order, sample type, alpha
association and plane arrangement into one integer that two programs can exchange, which
is the same idea as [Wuffs' pixel format][wuffs-pixfmt] (a `uint32_t` with colour model,
order, transparency, float and four 4-bit channel depths). The differences are telling:
Wuffs stores per-channel depths and therefore packed formats such as RGB 565; lcms2
stores one byte count for all samples and has no packed formats at all, but it stores the
colour space, which Wuffs leaves to metadata. `skcms` goes the other way again: a closed
enum of 42 concrete formats, `skcms_PixelFormat_RGBA_8888`, `..._RGBA_1010102`,
`..._RGB_hhh_Norm`, `..._BGRA_10101010_XR`, which includes packed and extended-range
formats but no planar or CMYK ones ([`skcms_public.h`][sk-fmt]).

### 2. Genericity mechanism

Runtime dispatch on data, everywhere. The descriptor is matched against mask tables to
pick formatter function pointers; pipelines are linked lists of stages with function
pointers for 16-bit and float evaluation; optimisers, intents, interpolators and tag types
are linked lists searched in order, plug-ins first. There is no compile-time
specialisation beyond the hand-written fast paths (`Unroll3Bytes`, `MatShaperEval16`,
`fast_float`'s kernels). The cost is one indirect call per pixel for each of unroll,
evaluate and pack in the generic loop, which the optimisers mitigate by making
`Eval16Fn` itself cheap and `fast_float` removes by replacing the loop. The design fits
a C library whose consumers choose formats at run time from file headers. It is the
opposite of the D approach the catalog's [generic-programming thread][p-generic]
examines, where a format would be a template parameter and the loop specialised per
instantiation; the descriptor is still useful in D as a runtime value that a
`static foreach` over supported formats can switch on.

### 3. Colour and metadata

This is the library's whole purpose. Intents follow ICC (perceptual, relative and
absolute colorimetric, saturation) plus Adobe-style black point compensation and six
K-preserving intents; absolute colorimetric honours an adaptation state
(`cmsSetAdaptationState`, 0 for no adaptation to 1 for full); proofing transforms add a
third profile and an out-of-gamut alarm colour ([`lcms2.h`][h-intents],
[`lcms2.h`][h-flags]). Profiles can be written as well as read, including device links
from a transform (`cmsTransform2DeviceLink`), and CGATS/IT8 measurement files are parsed
by `cmscgats.c`. Transfer functions are ICC curves: parametric types 1 to 5 and sampled
tables, with segmented float curves for v4 multi-process elements; lcms2 also
registers its own parametric types 6 to 8, 108 and 109 ([`cmsgamma.c`][gamma-types]). lcms2 knows the
`cicp` tag (the 2.18 ChangeLog says "Fix CICp tag size") and the Microsoft `MHC2` tag,
but a CICP code point is metadata to it: there is no built-in PQ or HLG profile, and HDR
headroom, [gain maps][gain-maps] and EXIF are outside its scope. Alpha is opaque payload
unless a descriptor says `PREMUL`, in which case the formatters divide on input and
multiply on output ([straight and premultiplied alpha][c-alpha]). See [ICC][icc] for the
profile model and [CICP][cicp] for the enumerated alternative.

### 4. I/O and codec architecture

Not a codec; it decodes one format, ICC, from a `cmsIOHANDLER` that wraps memory, a
`FILE*`, a stream or a user callback table, with `Read`, `Seek`, `Tell`, `Write`, `Close`
([`lcms2_plugin.h`][plug-io], [`cmsio0.c`][io-memread]). Reading is pull-based and random-access (tags are seeked to
by offset), so it is not incremental or suspendable: the whole profile must be in memory
or seekable. That is cheap in practice because profiles are kilobytes to a few
megabytes, and the image codec that found the profile already holds the bytes. Profile
writing (`cmsSaveProfileToMem`, `cmsMD5computeID`) uses the same handler. The 2.20 header
plug-in lets a context read or write private header fields and set the accepted ICC
version ([`cmsio0.c`][io-header-plugin], [`lcms2_plugin.h`][plug-header]).

### 5. Hostile input and safety

The parser is defensive at the byte level and tolerant at the structure level.

- **Reads**: `MemoryRead` checks `size * count` for overflow, rejects reads past the
  block and returns 0 with "Read from memory error" ([`cmsio0.c`][io-memread]).
- **Header**: `_cmsReadHeader` clamps the header's size field to the real buffer size,
  rejects more than `MAX_TABLE_TAG` (100) tags, and skips (with
  `cmsERROR_CORRUPTION_DETECTED`) any tag whose `offset + size` exceeds the size or wraps
  ([`cmsio0.c`][io-header]).
- **Tags**: `cmsReadTag` rejects tags under 8 bytes, checks the tag type against the
  tag's allowed types, and fails if a reader returned fewer elements than the tag
  descriptor requires ([`cmsio0.c`][io-readtag]).
- **LUTs**: `CubeSize` computes CLUT entry counts in 64 bits and rejects anything over
  `UINT_MAX / 15` ([`cmslut.c`][lut-cube]); channel counts are capped at `cmsMAXCHANNELS`;
  a multi-process element tag is capped at 50 stages,
  `if (ElementCount > 50) goto Error;` ([`cmstypes.c`][types-mpe]). That line is the
  whole of the pinned commit, "add a guard against too much stages" (a two-line diff to
  `Type_MPE_Read`, read by fetching the commit with its parent), so the cap is new at
  this revision.
- **Transforms**: channel counts from the linked pipeline must equal the colour spaces'
  ("Channel count doesn't match. Profile is corrupted", [`cmsxform.c`][xf-extended]).

In-tree fuzzing arrived late. The 2.17 ChangeLog records "Add fuzzers foundation. Many thanks to
Amir Montazery and Open Source Technology Improvement Fund (ostif.org), Google, for
funding that" ([`ChangeLog`][changelog-217]). The in-tree harness opens a profile, reads
every tag cooked and raw, every intent's input, output and device-link LUT, black points,
TAC, and PostScript CSA and CRD ([`fuzzers.c`][fuzz]). It calls no transform API itself;
black-point detection and the PostScript generators build small internal transforms
over fixed Lab or colorant values ([`cmssamp.c`][samp-xform]), so caller-chosen
descriptors, buffers and strides are never exercised. OSS-Fuzz is older: its oldest
commit touching `projects/lcms` is dated November 29, 2016 (a rename from `targets/`,
[`a143b9b3`][ossfuzz-rename]), and transform fuzzing lives there (fifteen
harnesses, including `cms_transform_fuzzer.c` from PDFium, which links a fuzzed profile
to sRGB and transforms one pixel) under ASan, UBSan and MSan with libFuzzer, AFL and
honggfuzz ([`project.yaml`][ossfuzz-yaml], [`cms_transform_fuzzer.c`][ossfuzz-xform]).
The test suite does not exercise these.

The CVE record shows the shape of the risk. Older records: integer overflows leading to
heap overflow in lcms 1.x (CVE-2009-0723), NULL pointer dereferences in lcms2
before 2.5 (CVE-2013-4160), an out-of-bounds read in `Type_MLU_Read` (CVE-2016-10165) and
an integer overflow in the CGATS parser's `AllocateDataSet` (CVE-2018-16435)
([CVE records][cve-2009-0723], [2013][cve-2013-4160], [2016][cve-2016-10165],
[2018][cve-2018-16435]). Two 2025 heap-overflow reports, in `UnrollChunkyBytes` and in the
`smooth2` helper, are marked disputed by the supplier: the first as "a bug in a
third-party calling program", the second because the function "is never called on normal
color management" ([CVE-2025-29069][cve-2025-29069], [CVE-2025-29070][cve-2025-29070]). The
first dispute is the API's real hazard: a formatter trusts that the buffer holds `n`
pixels of the declared descriptor and that strides are right. Nothing in the API can check
that, which is what [the security policy][security] means by "C itself is unsafe". The
ChangeLog's 2.9 entry records "Several fixes related with security, and therefore not
detailed here" ([`ChangeLog`][changelog-29]), so the record is incomplete by design.

How tolerant the parser is, compared with `skcms`, is tabulated on the
[ICC page][icc-hostile] (lcms2 opens profiles with a bad size field, a D65 PCS
illuminant or a negative gamma that `skcms` rejects).

### 6. Allocation and ownership

Every object is heap-allocated through the context's memory handler (`_cmsMalloc`,
`_cmsMallocZero`, `_cmsDupMem`), which a memory plug-in can replace; the context itself is
allocated by the plug-in if one is given ([Plugin API, p. 5][doc-plugin]). Opening a
profile from memory copies the bytes ([`cmsio0.c`][io-mem-open]); tags are allocated on
first read and freed with the profile. A transform owns its optimised pipeline (copied
from the profiles' stages), its formatters' private data and its cache, so profiles can be
closed as soon as the transform exists, as every example does. Ownership is manual:
`cmsCloseProfile`, `cmsDeleteTransform`, `cmsDeleteContext`. After creation, the 16-bit
and float loops do not allocate; the `threaded` scheduler does (`_cmsCalloc` of slices
and handles per call, [`threaded_scheduler.c`][thr-sched]). Compare `skcms`, which
borrows the caller's profile bytes and builds its op program in a 32-entry array on the
stack on every `skcms_Transform` call, so neither parsing nor transforming allocates
([`skcms.cc`][sk-program]).

### 7. CPU parallelism and SIMD

The core is scalar C: integer fixed-point for 8 and 16 bits, tetrahedral interpolation
(Sakamoto's algorithm) for 3-input CLUTs and trilinear on request
([`cmsintrp.c`][intrp]). Speed comes from choosing a cheaper evaluator, not vectors.
`fast_float` adds SSE2 for the 8-bit matrix-shaper, detected at run time
(`CMS_DONT_USE_SSE2` disables it), and scalar fast paths elsewhere ([`lcms2_fast_float.h`][ff-header]).

Thread safety is by construction for transforms: `cmsDoTransform` reads only immutable
transform state and the per-call stack copy of the cache ([`cmsxform.c`][xf-cached]).
Profiles are shared mutable state (lazy tag cache) and are serialised by a per-profile
mutex from the mutex plug-in, pthreads or Win32 by default ([`cmsio0.c`][io-readtag]).
Parallelism is a plug-in: when one is registered, `ParalellizeIfSuitable` saves the chosen
loop as `p->Worker` and installs the plug-in's scheduler as `p->xform`
([`cmsxform.c`][xf-parallel]). The `threaded` scheduler gives each worker at least 128
KiB of input plus output, splits by lines (or by pixels for one long line), spawns a
thread per slice with `pthread_create` (`CreateThread` on Windows) on every call, runs
slice 0 itself and joins
([`threaded_split.c`][thr-split], [`threaded_scheduler.c`][thr-sched]). There is no pool.
Libvips, which already parallelises by region, sets `cmsFLAGS_NOCACHE` on a shared
transform ([libvips][libvips-icc]), with the comment that this makes "calling
cmsDoTransform() from multiple threads safe" ([`icc_transform.c`][vips-nocache]). At this
lcms2 revision the cache is a per-call copy, so the flag trades the cache's benefit for
nothing in thread safety.

Measured throughput for 2²⁴ 8-bit RGB pixels, sRGB to an Adobe-RGB-like matrix-shaper
profile (**verified**, one machine, see the note at the top):

| Path                                    | Time     | Throughput   |
| --------------------------------------- | -------- | ------------ |
| core 8-bit, default (matrix-shaper)     | 242.7 ms | 69 Mpixel/s  |
| core 8-bit, `cmsFLAGS_FORCE_CLUT`       | 397.6 ms | 42 Mpixel/s  |
| core 8-bit, `cmsFLAGS_NOOPTIMIZE`       | 3 697 ms | 5 Mpixel/s   |
| core float (`TYPE_RGB_FLT`)             | 3 507 ms | 5 Mpixel/s   |
| `fast_float` 8-bit (SSE2 matrix-shaper) | 76.9 ms  | 218 Mpixel/s |
| `fast_float` float                      | 595.4 ms | 28 Mpixel/s  |
| `threaded`, core 8-bit, all 32 threads  | 22.0 ms  | 761 Mpixel/s |

A verification rerun of the same probe on the same CPU model (GCC 16.2 `-O2`, three
invocations, each best of three) put core 8-bit default between 115.8 and 201.8 ms,
`NOOPTIMIZE` between 1 848 and 3 300 ms and `threaded` between 10.2 and 51.3 ms, so the
absolute times above vary by a factor of two or more with machine state. The ratios
held: `NOOPTIMIZE` and core float 14 to 17 times the default, `fast_float` 8-bit 1.7 to
2.7 times faster than the default.

`skcms` takes the opposite route: one op-list interpreter compiled three times, baseline,
Haswell (AVX2) and Skylake-X (AVX-512), selected by `cpuid` once
([`skcms.cc`][sk-dispatch]). Its CLUT size limit exists because the gather instructions
take 32-bit indices ([ICC][icc-hostile]).

### 8. GPU offload and interop

Not applicable: lcms2 has no GPU path and no shader generation. The closest artefacts are
the ones a GPU consumer builds from it: a device link sampled into a 3D CLUT
(`cmsFLAGS_FORCE_CLUT` with `cmsFLAGS_GRIDPOINTS(n)`, then reading the `clut` stage via
`cmsGetTransformPipeline`) or a `.cube` file, which lcms2 2.16 can import as an RGB device
link ([`ChangeLog`][changelog-216]). [OpenColorIO][ocio] is the colour library in this
catalog that generates shader text for its transforms.

### 9. Temporal, animation and containers

Not applicable: lcms2 transforms buffers of pixels and knows no frames, sequences or
containers. The one temporal concern it affects is reuse: a transform is meant to be
created once per profile pair and descriptor pair and applied to every frame, and the
`fast_float` manual advises against `cmsChangeBuffersFormat` because "Transforms that are
polymorphic regarding formats are not optimizable" ([fast float extensions, p. 8][doc-ff]).

### 10. Testing and conformance

`testbed/testcms2.c` is a 10 055-line self-checking program with 167 `Check(...)` calls,
from fixed-point helpers and interpolation through curve inversion, every formatter, tag
round trips and transforms, plus `testplugin.c` for the plug-in types, `alpha_test.c`
and a C++ threading test ([`testcms2.c`][test-list]). Precision checks are tolerances,
not exact oracles: an 8-bit transform of a profile onto itself may deviate by "2 contone
of difference on 8 bits" ([`testcms2.c`][test-8bit]), and an sRGB to Lab to sRGB round
trip repeated 50 times may drift by a 16-bit distance of 20 ([`testcms2.c`][test-roundtrip]).
`fast_float` and `threaded` carry their own testbeds. The CI matrix runs
`./configure --with-fastfloat --with-threaded`, `make` and `make check` on Ubuntu and
macOS, builds and runs the Visual Studio testbed on Windows, and repeats the tests under
Meson and CMake ([`build.yml`][ci]). There is no ICC conformance corpus in the tree beyond the test
profiles in `testbed/`.

What the defaults cost in precision, against the float transform rounded to the output
depth (**verified**):

| Transform (sRGB to Adobe-RGB-like) | Evaluator chosen          | Max error            | Samples off                |
| ---------------------------------- | ------------------------- | -------------------- | -------------------------- |
| 8-bit default                      | fixed-point matrix-shaper | 2 of 255             | 1.03% of 2²⁴ × 3           |
| 8-bit `cmsFLAGS_NOOPTIMIZE`        | full pipeline, 16-bit     | 0                    | 0                          |
| 8-bit `cmsFLAGS_FORCE_CLUT`        | 33³ CLUT, tetrahedral     | 5 of 255             | 2.42%                      |
| `fast_float` 8-bit                 | SSE2 matrix-shaper        | 2 of 255             | 0.91%                      |
| 16-bit default                     | 33³ CLUT (resampled)      | 964 of 65 535 (1.5%) | mean 8.2, worst near black |
| 16-bit `cmsFLAGS_HIGHRESPRECALC`   | 49³ CLUT                  | 625                  | mean 2.3                   |
| 16-bit `cmsFLAGS_GRIDPOINTS(65)`   | 65³ CLUT                  | 334                  | mean 1.2                   |
| 16-bit `cmsFLAGS_NOOPTIMIZE`       | full pipeline             | 0                    | 0                          |

The 16-bit rows were sampled on an 86 × 52 × 37 grid of inputs (steps of 771, 1 285
and 1 799 code values) against a `TYPE_RGB_DBL` `cmsFLAGS_NOOPTIMIZE` transform; the worst input in every CLUT row was a dark red (`771, 0, 0`), where the sRGB
toe meets a gamma-2.2 output through a grid that is uniform in encoded values. The
matrix-shaper optimisation applies only to 8-bit input and linearisation needs an
explicit flag on 16-bit input, so a 16-bit RGB to RGB transform falls to resampling. The [fast float manual][doc-ff] states the general rule: "unless
both formats are float, the internal lcms2 math being used is 16 bits". One more
**verified** observation: `cmsGetTransformPipeline` on the default 8-bit transform lists
the same three stages (`cvst`, `matf`, `cvst`) as the unoptimised one; the fixed-point
evaluator is installed with `_cmsPipelineSetOptimizationParameters`, so the stage list does
not reveal which evaluator will run.

---

## Lessons for Sparkles

- **Q5** Colour management is a separate engine with its own lifecycle (parse, link,
  optimise, apply) and its own state (contexts, caches). No decoder in this catalog
  embeds one; [libvips][libvips-icc], [libjxl][libjxl] (`JxlCmsInterface`) and Skia
  consume one through an interface. The Sparkles baseline has no colour management at all
  ([existing code, G4][bl-existing-gaps]). Binding lcms2 through ImportC, porting a subset,
  or adopting `skcms`'s matrix/TRC-plus-A2B scope are the three options this evidence
  bears on; the MIT core makes binding legally simple, the GPL-3.0 fast paths do not.
- **Q1** lcms2's descriptor shows that a 32-bit runtime value can name colour space,
  channel count, extra samples, sample type, order and alpha association, and that this
  value can travel through a C ABI. It also shows the cost of a fixed field layout:
  `BYTES_SH(0)` must mean double because the field has three bits, packed formats cannot
  be expressed, and `fast_float` claims bits 26 and 27 for its own formats. A D pixel
  format that is a compile-time type ([design by introspection][dbi]) can still
  expose such a value for dispatch and FFI; [Wuffs][wuffs-pixfmt] and lcms2 together
  give two concrete bit layouts to compare, and both name channels in memory order.
- **Q3** The optimiser is the transferable idea: a general pipeline of stages, rewritten
  at creation into the cheapest evaluator that meets the precision the caller asked for
  (`NOOPTIMIZE`, `HIGHRESPRECALC`, float). In D that rewrite can happen at compile time
  when the profiles are known (sRGB to linear) and at run time otherwise; the measured
  15-fold gap between `NOOPTIMIZE` and the matrix-shaper on 8-bit data (about 50-fold
  against `fast_float`) is the price of not doing it. The 16-bit CLUT error near black is the price of doing it blindly.
- **Q3, Q7** The per-pixel loop with three indirect calls is what `fast_float` exists to
  replace. A Sparkles kernel templated on source and destination formats and evaluated over
  a whole row (or a `Slice`) avoids the indirection; the `@target` dispatch pattern the
  [SIMD baseline][bl-shaders-gaps] describes (G4, G5) is what `skcms` does with three
  compilations of one interpreter. lcms2's parallelism, a thread spawned per slice per
  call, would not suit `sparkles:event-horizon`'s pools; the 128 KiB minimum slice is a
  data point for a grain size.
- **Q5, Q8** A transform should be immutable after creation, so it can be shared across
  threads without locks; lcms2's stack copy of its cache is the detail that makes this
  true. In `@safe pure nothrow @nogc` D the same property falls out of a `const` transform
  and a scratch buffer per call, or a [`UniqueBuffer`][buffer] owned by the worker.
- **Q4, Q5** The profile parser needs the opposite property: lazy, cached tag decoding
  under a mutex is a mutable shared object. Parsing everything once into an immutable
  value (as `skcms` does into `skcms_ICCProfile`) suits `@nogc` and dip1000 better, with
  the profile bytes owned by the image's metadata buffer.
- **Q4, Q8** lcms2's hardening is a list of scattered checks, some added after reports: overflow-checked
  reads, tag bounds, `UINT_MAX / 15` on CLUT sizes, 100 tags, 50 MPE stages. A Sparkles
  parser described in `sparkles:wired` ([wired baseline][bl-wired]) would state these as
  limits in the description rather than as scattered `if`s, and the in-tree fuzzer's gap
  (no caller-built transforms, no pixel buffers) shows that the transform construction path needs fuzzing too.
  The [hostile-input papers][p-hostile] argue the same.
- **Q8** lcms2 is a ready differential oracle for a D implementation: `NOOPTIMIZE` and
  `TYPE_*_DBL` give a reference path, the testbed's tolerances (2 levels at 8 bits)
  give a starting threshold, and the optimised paths give known, measurable error to stay
  within. Such an oracle would sit beside the existing `stb_image` PNG oracle
  ([existing code][bl-existing-gaps]) as a dev-shell dependency, not a runtime one.
- **Q9** The plug-in split, MIT core plus GPL fast paths, and the separation of profile
  parsing, linking and pixel evaluation into separable modules (`cmsio*`, `cmscnvrt`,
  `cmsopt`, `cmsxform`, `cmspack`) are evidence that colour management is its own package
  boundary, consumed by formats and algorithms rather than living inside either.
- **Q2** Contexts as a struct of per-subsystem slots, inherited from a global default, are
  a C answer to "configure the library per user". The D answer the guidelines prefer is
  a policy passed as a template or a value at the call site; lcms2's experience that the
  global context is "not recommended" ([`lcms2.h`][h-context]) argues against a global.

## Strengths

- Complete ICC v2 and v4 support, including device links, abstract and named-colour
  profiles, proofing, BPC and K-preserving intents; a de facto reference.
- One compact runtime descriptor covers interleaved and planar layouts, five sample types,
  alpha, premultiplication, byte order and channel order.
- Transforms are immutable and thread-safe to apply; `cmsDoTransform` cannot fail.
- A real optimiser with selectable precision; the default 8-bit matrix-shaper path is
  within 2 levels of the float reference.
- Nearly every subsystem is replaceable per context, including the whole transform.
- MIT core, no dependencies beyond libc and optional pthreads.

## Weaknesses

- Generic loops pay three indirect calls per pixel; the fast paths are in GPL plug-ins.
- No SIMD in the core and no GPU path; the parallel plug-in spawns threads per call.
- 16-bit integer transforms default to a resampled CLUT whose error near black (964 of
  65 535 in the measured case) is far larger than the 8-bit path's.
- Buffers are trusted: descriptor, pixel count and strides cannot be checked, and the
  disputed 2025 CVE shows callers getting this wrong.
- The fuzz harness in the tree covers profile parsing and the internal transforms it
  reaches, not caller-built transforms over pixel buffers; those are fuzzed in OSS-Fuzz.
- The parser tolerates malformed profiles that a strict reader rejects, so two CMMs can
  disagree on the same file ([ICC][icc-hostile]).
- No HDR model: no PQ or HLG built-ins, no headroom, no gain maps.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                   | Trade-off                                                                                      |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Pixel layout as one bit-packed `cmsUInt32Number`                  | Runtime-selectable, ABI-stable, cheap to compare and to match against masks | Fixed field widths: no packed formats, double encoded as 0 bytes, plug-ins borrow high bits    |
| Compile a transform once; formatters and evaluator chosen then    | Per-pixel work is fixed; transforms are immutable and shareable             | Creation is costly; format-polymorphic transforms (`cmsChangeBuffersFormat`) lose optimisation |
| 16-bit integer internal precision unless both ends are float      | Fast fixed-point arithmetic and compact tables                              | Float paths are an order of magnitude slower; 16-bit CLUT resampling loses shadow precision    |
| Optimiser chain: curves, matrix-shaper, linearisation, resampling | First applicable rewrite wins; flags trade memory and accuracy              | Lossy by default; the stage list no longer tells which evaluator runs                          |
| Thirteen plug-in types, registered per context                    | Extensibility and a licensing seam for proprietary fast paths               | Fast paths are GPL; plug-in ABI is tied to `ExpectedVersion`                                   |
| Lazy tag parsing behind a per-profile mutex                       | Opening is cheap; only tags a transform needs are decoded                   | Profiles are mutable shared objects; a mutex plug-in is needed without pthreads                |
| Tolerate malformed profiles where repairable                      | Real-world profiles are often slightly wrong                                | Divergence from strict readers; hostile inputs get further into the code                       |
| Return `NULL` on failure, log text to a hook                      | Thread-friendly, no global error state                                      | Error codes are coarse families; the reason is only in English text                            |

## Sources

- Little CMS at [`5546f1d6`][repo]: [`README.md`][readme], [`SECURITY.md`][security],
  [`ChangeLog`][changelog], [`include/lcms2.h`][h-format],
  [`include/lcms2_plugin.h`][plug-base], [`src/lcms2_internal.h`][int-context],
  [`src/cmsxform.c`][xf-alloc], [`src/cmsopt.c`][opt-list], [`src/cmspack.c`][pack-table],
  [`src/cmscnvrt.c`][cnvrt-link], [`src/cmsio0.c`][io-header], [`src/cmslut.c`][lut-cube],
  [`src/cmstypes.c`][types-mpe], [`src/cmsvirt.c`][virt-srgb], [`src/cmspcs.c`][pcs-grid],
  [`src/cmsintrp.c`][intrp], [`src/cmsgamma.c`][gamma-types], [`src/cmssamp.c`][samp-xform], [`fuzzers/fuzzers.c`][fuzz], [`testbed/testcms2.c`][test-list],
  [`.github/workflows/build.yml`][ci].
- Plug-ins: [`plugins/README.1ST`][plugins-readme],
  [`fast_float_sup.c`][ff-dispatch], [`lcms2_fast_float.h`][ff-header],
  [`threaded_scheduler.c`][thr-sched], [`threaded_split.c`][thr-split].
- Manuals in the repository: [API][doc-api], [tutorial][doc-tutorial],
  [Plugin API][doc-plugin], [fast float extensions 1.7][doc-ff], [threaded extensions 1.0][doc-thr].
- OSS-Fuzz `projects/lcms` at `6410c2ab`: [`project.yaml`][ossfuzz-yaml],
  [`cms_transform_fuzzer.c`][ossfuzz-xform]; the `projects/lcms` rename [`a143b9b3`][ossfuzz-rename].
- CVE records: [CVE-2009-0723][cve-2009-0723], [CVE-2013-4160][cve-2013-4160],
  [CVE-2016-10165][cve-2016-10165], [CVE-2018-16435][cve-2018-16435],
  [CVE-2025-29069][cve-2025-29069], [CVE-2025-29070][cve-2025-29070].
- `skcms` in Skia at `3ad790ab`: [`skcms_public.h`][sk-fmt], [`skcms.cc`][sk-program].
- libvips at `b8242162`: [`icc_transform.c`][vips-nocache].
- Catalog: [ICC][icc], [CICP][cicp], [gain maps][gain-maps], [OpenColorIO][ocio],
  [libvips][libvips-icc], [libjxl][libjxl], [Wuffs][wuffs-pixfmt], [Skia][skia];
  concepts [ICC profile][c-icc], [pixel format names][c-pixfmt], [stride][c-stride],
  [planar][c-planar], [alpha][c-alpha], [hostile input][c-hostile]; baselines
  [existing code][bl-existing-gaps], [shaders and SIMD][bl-shaders-gaps],
  [wired][bl-wired]; papers [colour][p-colour], [hostile input][p-hostile],
  [generic programming][p-generic].

<!-- References -->

[repo]: https://github.com/mm2/Little-CMS/tree/5546f1d68136f94281c9f6bfc027c6cdf4898da8
[readme]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/README.md#L7
[readme-story]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/README.md#L15-L16
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[readme-conf]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/README.md#L11-L12
[security]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/SECURITY.md#L1-L15
[changelog]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/ChangeLog
[changelog-217]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/ChangeLog#L77-L80
[changelog-216]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/ChangeLog#L92-L96
[changelog-29]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/ChangeLog#L188-L190
[plugins-readme]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/README.1ST
[doc-api]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/doc/LittleCMS2.20%20API.pdf
[doc-tutorial]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/doc/LittleCMS2.20%20tutorial.pdf
[doc-plugin]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/doc/LittleCMS2.20%20Plugin%20API.pdf
[doc-ff]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/fast_float/doc/LittleCMS%20floating%20point%20extensions%201.7.pdf
[doc-thr]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/threaded/doc/LittleCMS%20threaded%20extensions%201.0.pdf
[h-format]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L694-L738
[h-types]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L775-L981
[h-context]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L1106-L1116
[h-builtin]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L1644-L1717
[h-intents]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L1728-L1739
[h-flags]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L1745-L1781
[h-xform-api]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2.h#L1785-L1846
[plug-base]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2_plugin.h#L199-L222
[plug-io]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2_plugin.h#L118-L135
[plug-xform]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2_plugin.h#L590-L653
[plug-header]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/include/lcms2_plugin.h#L694-L720
[int-8to16]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/lcms2_internal.h#L125-L126
[int-context]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/lcms2_internal.h#L478-L529
[xf-do]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L192-L249
[xf-precalc]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L402-L438
[xf-cached]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L502-L555
[xf-parallel]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L805-L820
[xf-alloc]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L851-L1010
[xf-extended]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L1121-L1213
[xf-linear]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsxform.c#L1183-L1190
[opt-resample]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsopt.c#L656-L690
[opt-linear]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsopt.c#L1055-L1170
[opt-matsh]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsopt.c#L1547-L1586
[opt-list]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsopt.c#L1835-L1842
[opt-entry]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsopt.c#L1932-L2003
[pack-table]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmspack.c#L3576-L3630
[pack-stock]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmspack.c#L3685-L3720
[pack-get]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmspack.c#L3987-L4011
[pcs-grid]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmspcs.c#L659-L710
[cnvrt-intents]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmscnvrt.c#L82-L94
[cnvrt-link]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmscnvrt.c#L1123-L1165
[io-memread]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio0.c#L148-L181
[io-mem-open]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio0.c#L260-L296
[io-header-plugin]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio0.c#L868-L899
[io-header]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio0.c#L921-L1056
[io-readtag]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsio0.c#L1837-L1977
[lut-cube]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmslut.c#L461-L483
[types-mpe]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmstypes.c#L4785-L4812
[virt-srgb]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsvirt.c#L643-L685
[gamma-types]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsgamma.c#L60-L67
[samp-xform]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmssamp.c#L104-L124
[intrp]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/src/cmsintrp.c#L620-L723
[fuzz]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/fuzzers/fuzzers.c#L180-L197
[test-list]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/testbed/testcms2.c#L9790-L10031
[test-8bit]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/testbed/testcms2.c#L5895-L5922
[test-roundtrip]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/testbed/testcms2.c#L8601-L8645
[ci]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/.github/workflows/build.yml#L12-L150
[ff-dispatch]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/fast_float/src/fast_float_sup.c#L25-L117
[ff-header]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/fast_float/include/lcms2_fast_float.h#L34-L60
[thr-sched]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/threaded/src/threaded_scheduler.c#L27-L107
[thr-split]: https://github.com/mm2/Little-CMS/blob/5546f1d68136f94281c9f6bfc027c6cdf4898da8/plugins/threaded/src/threaded_split.c#L86-L215
[ossfuzz-yaml]: https://github.com/google/oss-fuzz/blob/6410c2ab67f22d0697742f8f5d583d38d36c4b9b/projects/lcms/project.yaml
[ossfuzz-xform]: https://github.com/google/oss-fuzz/blob/6410c2ab67f22d0697742f8f5d583d38d36c4b9b/projects/lcms/cms_transform_fuzzer.c#L8-L50
[ossfuzz-rename]: https://github.com/google/oss-fuzz/commit/a143b9b39a51412d133f846688194d68fe4197ba
[vips-nocache]: https://github.com/libvips/libvips/blob/b8242162f09585ce5b4029cdb7fe95de186dde1a/libvips/colour/icc_transform.c#L451-L454
[cve-2009-0723]: https://www.cve.org/CVERecord?id=CVE-2009-0723
[cve-2013-4160]: https://www.cve.org/CVERecord?id=CVE-2013-4160
[cve-2016-10165]: https://www.cve.org/CVERecord?id=CVE-2016-10165
[cve-2018-16435]: https://www.cve.org/CVERecord?id=CVE-2018-16435
[cve-2025-29069]: https://www.cve.org/CVERecord?id=CVE-2025-29069
[cve-2025-29070]: https://www.cve.org/CVERecord?id=CVE-2025-29070
[sk-fmt]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L361-L414
[sk-program]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L2755-L2790
[sk-dispatch]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L3119-L3139
[icc]: ./icc.md
[icc-hostile]: ./icc.md#_5-hostile-input-and-safety
[cicp]: ./cicp.md
[gain-maps]: ./gain-maps.md
[ocio]: ./opencolorio.md
[libvips-icc]: ./libvips.md#_3-colour-and-metadata
[libjxl]: ./libjxl.md
[skia]: ./skia.md
[wuffs-pixfmt]: ./wuffs.md#_1-pixel-and-memory-model
[c-icc]: ./concepts.md#icc-profile
[c-pixfmt]: ./concepts.md#pixel-format-names-and-byte-order
[c-stride]: ./concepts.md#stride
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-hostile]: ./concepts.md#hostile-input
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders-gaps]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-wired]: ./baseline/wired.md
[buffer]: ../../specs/base/buffer.md
[p-colour]: ./papers/resampling-colour.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-generic]: ./papers/generic-image-programming.md
