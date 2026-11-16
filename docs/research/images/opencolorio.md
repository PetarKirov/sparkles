# OpenColorIO (C++)

The Academy Software Foundation's colour-management library for film and VFX: a
declarative config of named colour spaces, roles, displays, views, looks and file
rules is compiled, per conversion, into an optimised op list that runs either as a
scanline CPU processor or as shader text generated for the caller's GPU API.

| Field         | Value                                                                                                                         |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17; Python and Java bindings ([`src/bindings`][bindings])                                                                  |
| License       | BSD-3-Clause ([`LICENSE`][license]); docs CC-BY-4.0                                                                           |
| Repository    | [AcademySoftwareFoundation/OpenColorIO][repo]                                                                                 |
| Revision read | `22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd` (September 30, 2026, "Update notes for 2.6 release"; `CMakeLists.txt` `2.7.0` dev) |
| Documentation | [opencolorio.readthedocs.io][docs]; the public header [`OpenColorIO.h`][h-usage] carries most of the API contract             |
| Category      | Colour: config-driven colour management, CPU and generated-GPU processing                                                     |
| Tier          | B                                                                                                                             |
| Last reviewed | November 7, 2026                                                                                                              |

> [!NOTE]
> Claims marked **demonstrated** come from small C++ programs in `/tmp/ocio-demo`
> built against OpenColorIO `2.4.2` from nixpkgs (`nix-shell -p opencolorio`), not the
> pinned `2.7.0` development tree. The 2.4.2 library embeds the older built-in config
> `cg-config-v2.2.0_aces-v1.3_ocio-v2.4`; the pinned tree adds the ACES 2.x configs
> and stricter LUT-size checks, as noted where they differ.

---

## Overview

### What it solves

A production renders, composites and grades in several applications, each of which
must agree on what a pixel value means and how it is shown. OCIO moves that knowledge
out of the applications into one shared file, the config, which an application
loads (usually from `$OCIO`) and queries by name. The [`README.md`][readme] says:

> "OpenColorIO (OCIO) is a complete color management solution geared towards motion
> picture production with an emphasis on visual effects and computer animation. […]
> OCIO is compatible with the Academy Color Encoding Specification (ACES) and is
> LUT-format agnostic, supporting many popular formats."

### Design philosophy

The application never sees colour mathematics. The internal-architecture page states
the split ([`internal_architecture.rst`][arch-summary]):

> "Configs and ColorSpaces are just a bookkeeping device used to get and ordered lists
> of Transforms corresponding to image color transformation. Transforms are visible to
> the person AUTHORING the OCIO config, but are NOT visible to the client
> applications. Client apps need only concern themselves with Configs and Processors."

and the same page adds that colour-space names "should NEVER be hard-coded into client
software, but should be dynamically queried at runtime from the library"
([`internal_architecture.rst`][arch-names]). The project mission lists "provide
lossless color processing wherever possible" ([`README.md`][readme-mission]). The
optimiser honours that through a named `OPTIMIZATION_LOSSLESS` preset, but the default
preset is `VERY_GOOD`, which already adds 1D-LUT composition and fast approximations
([`OpenColorTypes.h`][opt-flags]); only `GOOD` and `DRAFT` compose 3D LUTs.

---

## How it works

### The config

A config is YAML (`.ocio`, or a zipped `.ocioz` archive). Its top-level keys in the
built-in CG config include `roles`, `file_rules`, `viewing_rules`, `shared_views`,
`displays`, `looks`, `view_transforms`, `display_colorspaces`, `colorspaces` and
`named_transforms` ([`cg-config-v5.0.0`][cg-roles]; abridged):

```yaml
roles:
  aces_interchange: ACES2065-1
  scene_linear: ACEScg
  texture_paint: sRGB Encoded Rec.709 (sRGB)
file_rules:
  - !<Rule> { name: EXR, colorspace: ACES2065-1, pattern: '*', extension: exr }
  - !<Rule> { name: Default, colorspace: sRGB - Display }
```

- A **colour space** defines its relation to one of two reference spaces
  (`REFERENCE_SPACE_SCENE` or `REFERENCE_SPACE_DISPLAY`, [`OpenColorTypes.h`][ref-space])
  through `from_scene_reference` / `to_scene_reference` transform chains. It also
  carries `aliases`, `family`, `categories`, `encoding` (`sdr-video`, `log`,
  `scene-linear`, …), `isdata`, and since 2.5 an `interop_id`
  ([`cg-config` sRGB entry][cg-srgb]).
- A **role** is an indirection (`scene_linear`, `compositing_log`, `data`,
  `color_picking`, …) that lets an application ask for "the working space" without
  knowing its name ([`OpenColorTypes.h`][roles]).
- A **display** lists **views**; a view pairs a `view_transform` (scene-referred to
  display-referred, for example an ACES output transform) with a display colour space.
  `viewing_rules` filter which views apply to a source by its `encoding`.
- A **look** is a named creative grade applied in a process space.
- **File rules** map a path to a colour space by glob, extension or regex,
  consulted by `Config::getColorSpaceFromFilepath` ([`OpenColorIO.h`][h-filepath]).

`Config::CreateFromEnv` reads `$OCIO`; `CreateFromBuiltinConfig` and the `ocio://` URI
load configs compiled into the library ([`OpenColorIO.h`][h-create]). The pinned tree
embeds five CG and five studio ACES configs, from `ocio-v2.1` to `ocio-v2.6`
([`builtinconfigs/configs`][builtin-configs]).

### Transforms and builtin transforms

The transform vocabulary is a closed set of classes in `OpenColorTransforms.h`:
`MatrixTransform`, `ExponentWithLinearTransform`, `LogCameraTransform`,
`FileTransform` (24 registered formats from 19 readers in [`fileformats/`][fileformats], ICC
matrix/TRC display profiles among them), `FixedFunctionTransform` (ACES algorithms
in code), the `Grading*` transforms, `GroupTransform`, and the indirections
`ColorSpaceTransform`, `DisplayViewTransform` and `LookTransform`.

OCIO v2 added `BuiltinTransform`: a string `style` resolved against a registry of
op-building functors, so a config can name a standard conversion without shipping a
LUT. Registration is per family (ACES, six camera vendors, displays,
[`BuiltinTransformRegistry.cpp`][builtin-reg]):

```cpp
registry.addBuiltin("DISPLAY - CIE-XYZ-D65_to_sRGB",
                    "Convert CIE XYZ (D65 white) to sRGB (piecewise EOTF)",
                    CIE_XYZ_D65_to_SRGB_MONCURVE);
```

([`Displays.cpp`][builtin-srgb]). Each functor appends matrix and curve ops computed
from primaries and the adaptation method, so the builtin is analytic.

### Processors

`Config::getProcessor` takes two colour-space names, a display and view, a named
transform, or an arbitrary transform tree, and returns a `Processor`: the transform
tree flattened into an `OpRcPtrVec` ([`OpenColorIO.h`][h-getproc]). The `Processor`
is a description; execution needs one of its derivatives
([`OpenColorIO.h`][h-processor]):

```cpp
ConstGPUProcessorRcPtr getDefaultGPUProcessor() const;
ConstCPUProcessorRcPtr getDefaultCPUProcessor() const;
ConstCPUProcessorRcPtr getOptimizedCPUProcessor(BitDepth inBitDepth,
                                                BitDepth outBitDepth,
                                                OptimizationFlags oFlags) const;
```

Deriving an optimised processor runs `finalize`, `optimize(oFlags)` and, for the CPU,
`optimizeForBitdepth` on a copy of the op list ([`Processor.cpp`][proc-opt]).

### The optimiser

`OptimizationFlags` is a bit set of named rewrites ([`OpenColorTypes.h`][opt-flags]):
remove identities, remove adjacent inverse pairs per op type (`PAIR_IDENTITY_LUT3D`,
…), compose adjacent pairs (`COMP_MATRIX`, `COMP_LUT1D`, `COMP_LUT3D`, …), replace
separable prefixes by one 1D LUT for integer and half inputs (`COMP_SEPARABLE_PREFIX`),
and fast approximations (`LUT_INV_FAST`, `FAST_LOG_EXP_POW`). Presets group them:
`OPTIMIZATION_LOSSLESS`, `VERY_GOOD` (the default: lossless plus `COMP_LUT1D`,
`LUT_INV_FAST`, `FAST_LOG_EXP_POW` and `COMP_SEPARABLE_PREFIX`), `GOOD` (adds 3D LUT composition)
and `DRAFT` (everything). `OpRcPtrVec::optimize` iterates `RemoveNoOps`,
`ReplaceOps`, `ReplaceIdentityOps`, `RemoveInverseOps` and `CombineOps` until no pass
makes progress, capped at `MAX_OPTIMIZATION_PASSES = 80`
([`OpOptimizers.cpp`][opt-loop]).

**Demonstrated** with the 2.4.2 built-in CG config: `srgb_tx` to `ACEScg` has three
unoptimised ops and two after `OPTIMIZATION_DEFAULT`; a `GroupTransform` of
`ACEScg` to `srgb_tx` and back has six ops, `isNoOp()` returns `false`, and the
`OPTIMIZATION_LOSSLESS` processor has zero ops. `isNoOp` reports on the unoptimised
list, so a caller that wants to skip identity work must ask the optimised processor.

### CPU processing

The CPU path takes a non-owning `ImageDesc` ([`OpenColorIO.h`][h-imagedesc]):

> "This is a light-weight wrapper around an image, that provides a context for pixel
> access. This does NOT claim ownership of the pixels or copy image data."

`PackedImageDesc` accepts 3 or 4 channels, a `ChannelOrdering` (`RGBA`, `BGRA`,
`ABGR`, `RGB`, `BGR`), a `BitDepth` (`UINT8` to `UINT16`, `F16`, `F32`) and byte
strides for channel, x and y; `PlanarImageDesc` takes four plane pointers
([`OpenColorIO.h`][h-packed], [`OpenColorTypes.h`][bitdepth]). `CPUProcessor::apply`
walks the image one row at a time through a `ScanlineHelper`: the row is unpacked to
packed RGBA `float`, every op runs over it in place, and the row is packed back
([`CPUProcessor.cpp`][cpu-apply]):

```cpp
while(true)
{
    scanlineBuilder->prepRGBAScanline(&rgbaBuffer, numPixels);
    if(numPixels == 0) break;

    const size_t numOps = m_cpuOps.size();
    for(size_t i = 0; i<numOps; ++i)
    {
        m_cpuOps[i]->apply(rgbaBuffer, rgbaBuffer, numPixels);
    }

    scanlineBuilder->finishRGBAScanline();
}
```

When the destination is already packed RGBA `F32` the destination row is the working
buffer; otherwise `init` allocates three `4 * width` scratch vectors per call, with the
comment "TODO: Re-use memory from thread-safe memory pool"
([`ScanlineHelper.cpp`][scanline]). The first and last ops absorb the bit-depth
conversion (`inBitDepthOp`, `outBitDepthOp`), often as a 1D LUT indexed by the
integer input.

### GPU processing: generated shader text

The GPU path does not run anything. `GPUProcessor::extractGpuShaderInfo` writes into a
`GpuShaderDesc`: a shader function as text in the requested `GpuLanguage` (Cg, GLSL
1.2 to 4.0, `GLSL_VK_4_6`, GLSL ES, HLSL SM 5.0, OSL, MSL 2.0,
[`OpenColorTypes.h`][gpu-lang]), a list of 1D/2D and 3D LUT textures with their float
values, and uniforms for dynamic properties ([`OpenColorIO.h`][h-gpudesc]). The
caller allocates the textures, splices the function into its own fragment shader and
binds everything. `setFunctionName` and `setResourcePrefix` keep two OCIO functions
in one program from clashing; `setDescriptorSetIndex` and
`getUniformBufferSize` serve Vulkan, where uniforms live in a block and binding 0 is
reserved for it ([`OpenColorIO.h`][h-vk], [`GpuShaderDesc`][h-gpudesc]). Analytic ops (matrices, curves, ACES fixed
functions) become inline code; only LUT ops need textures. A separate
`getOptimizedLegacyGPUProcessor(oFlags, edgelen)` reproduces the v1 approach of baking
into one 3D LUT, documented as "less accurate" ([`OpenColorIO.h`][h-legacy]).

**Demonstrated** (2.4.2, `GPU_LANGUAGE_GLSL_4_0`): the `ACEScg` to `sRGB - Display` /
`ACES 1.0 - SDR Video` processor optimises to 15 ops (matrices, ranges, logs, two
`GradingRGBCurve`s, three `FixedFunction`s, one `ExponentWithLinear`) and generates a
277-line, 12,279-byte GLSL function with zero textures and zero uniforms; the B-spline
knots are emitted as `const float` arrays.

### Caching

Caches sit at two levels, each a mutex-guarded `std::map` (`GenericCache`,
[`Caching.h`][caching]). The config caches `Processor`s under a hash of the used
context variables, the transform's printed form and the direction
([`Config.cpp`][cfg-cache]); the comment notes the key includes "just the arguments of
the FileTransforms for LUTs", so edited LUT files need `clearProcessorCache()`. When
a new processor's op-list `getCacheID` matches an existing entry, the existing one is
reused so its derived processors come along. Each `Processor` caches its optimised,
CPU and GPU derivatives keyed by bit depths and flags ([`Processor.cpp`][proc-cpu]).
`ProcessorCacheFlags` and the environment variables `OCIO_DISABLE_ALL_CACHES` and
`OCIO_DISABLE_PROCESSOR_CACHES` turn this off; by default processors with dynamic
properties are shared, and the caller "must then always set the dynamic property
values prior to any color processing call" ([`OpenColorTypes.h`][cache-flags]).

**Demonstrated**: `getProcessor("srgb_tx", "ACEScg")` and
`getProcessor("sRGB Encoded Rec.709 (sRGB)", "scene_linear")` (an alias and a role
naming the same pair) return the same `Processor` instance, and two
`getDefaultCPUProcessor()` calls return the same `CPUProcessor`.

### Consumers: OpenImageIO and Blender

[OpenImageIO][oiio] wraps OCIO in `ColorConfig`; its `ColorProcessor_OCIO` holds
`getOptimizedCPUProcessor(ocio_optimization)` and applies it to a `PackedImageDesc`
built from OIIO's own strides ([`color_ocio.cpp`][oiio-proc]). OIIO adds what OCIO
leaves out: an own processor cache keyed by colour-space names and context
([`color_ocio.cpp`][oiio-cache]), unpremultiplication and threading through
`parallel_image` over regions ([`color_ocio.cpp`][oiio-par]). It also masks out
`OPTIMIZATION_COMP_GAMMA` before OCIO 2.5.0 because "OCIO 2.3 and 2.4 compose
back-to-back gamma/exponent ops in the wrong direction" ([`color_ocio.cpp`][oiio-gamma]).

Blender (read at `049750f9fa83`) ships its own config, the AgX views among its
displays ([`config.ocio`][bl-config]), and an embedded fallback config that "uses only
built-in transforms, so that loading it depends on no file"
([`libocio_fallback_config.cc`][bl-fallback]). Its viewport chains two OCIO GPU
functions, `OCIO_to_scene_linear` and `OCIO_to_display`, both generated as
`GPU_LANGUAGE_GLSL_1_3` with distinct resource prefixes and compiled by Blender's own
GPU module, which uploads 1D LUTs as 2D textures and every LUT, 3D ones included, in
half-float formats ([`libocio_gpu_shader_binder.cc`][bl-binder], [texture setup][bl-tex]).
OIIO's `ColorProcessor_OCIO::isNoOp` forwards to the unoptimised `Processor::isNoOp`
([`color_ocio.cpp`][oiio-proc]).

---

## Analysis

### 1. Pixel and memory model

OCIO has no image type. `ImageDesc` is a borrowed view of RGB(A) with byte strides
per channel, x and y, packed or planar (see [stride][c-stride] and
[interleaved, planar and semi-planar][c-planar]); channels beyond the fourth are
ignored, and there is no notion of YCbCr, chroma subsampling or more than one
row-major 2D region. Internally every op sees one representation: a row of packed
RGBA `float`. The design trades generality of storage for a single kernel signature,
`apply(const void * in, void * out, long numPixels)`.

### 2. Genericity mechanism

Runtime polymorphism throughout: `ImageDesc` and `GpuShaderCreator` are abstract
classes, ops are `OpCPU` objects behind `shared_ptr`, and `ScanlineHelper` is the one
place templates appear (`GenericScanlineHelper<InType, OutType>`, instantiated per
bit-depth pair, [`CPUProcessor.cpp`][scanline-tmpl]). The genericity that matters is
data: a config is a program written in transforms, and the optimiser is a
peephole rewriter over that program.

### 3. Colour and metadata

This is the subject's whole domain. Colour identity is a name in a config, not a
tagged value: a pixel buffer carries no colour state, and the application tracks
which colour space each image is in. Two reference spaces separate scene-referred
from display-referred data, and the display/view pair names the rendering intent that
an [ICC profile][c-icc] would otherwise carry. OCIO reads only matrix/TRC display ICC
profiles: "Other types of ICC profiles are not currently supported in this reader"
([`FileFormatICC.cpp`][icc]). It does not read [CICP][c-cicp] codes; the bridge to
file metadata is the Color Interop Forum `interop_id`, "intended to identify color
spaces in a way that is portable across different configs, making it suitable for use
in various file formats" ([`OpenColorIO.h`][h-interop]). Since 2.6,
`Config::findColorSpaceForID` resolves an ID with the Color Interop Forum's fallback
rules and `Config::LocateBuiltinColorSpace` finds the built-in equivalent of a colour
space by fingerprinting ([`OpenColorIO.h`][h-findid]). OpenImageIO maps those IDs to
CICP on its side ([deep-dive][oiio]). Alpha is passed through untouched;
premultiplication is the caller's concern.

### 4. I/O and codec architecture

OCIO reads no images. Its I/O is configs and LUT files, through a `ConfigIOProxy`
hook that can supply them from memory or an archive instead of the file system
([`OpenColorIO.h`][h-ioproxy]); `getColorSpaceFromFilepath` is the only point where
an image file meets the library, and it looks only at the path.

### 5. Hostile input and safety

Configs and LUTs are trusted-by-convention studio data, but LUT parsers do bound
sizes: `Max1DLUTLength = 300000` and `Max3DLUTLength = 129`
([`LutLimits.h`][lut-limits]), and at the pinned revision the `.cube` reader rejects
a `LUT_3D_SIZE` outside that range before it reserves storage
([`FileFormatIridasCube.cpp`][cube-limit]). **Demonstrated** against 2.4.2, which lacks
that check in the `.cube` reader: a 23-byte file declaring `LUT_3D_SIZE 1000` reached
`vector::reserve` and surfaced as a `std::length_error` wrapped in an OCIO
`Exception` (message `vector::reserve`); `LUT_3D_SIZE 200` was accepted up to the entry count ("Found 1, expected
8000000"); a cube with a `nan` entry loaded and produced `0` for that channel. Errors
are C++ exceptions; every registered format is tried in turn, and the exception lists
one error per reader registered for the file's extension (`iridas_cube` and
`resolve_cube` for `.cube`). No fuzz harness exists at this revision (no path
matches `fuzz`). See [hostile input][c-hostile].

### 6. Allocation and ownership

OCIO never owns pixels: `ImageDesc` borrows the caller's buffer and `apply` works in
place or into a second caller buffer. What OCIO does own (configs, processors,
transforms) it hands out as `shared_ptr` handles (`ConstConfigRcPtr`,
`ConstProcessorRcPtr`, …), shared across threads and caches. The only per-image
allocation is the `ScanlineHelper`'s three `4 * width` float vectors, made on each
`apply` unless the destination is packed RGBA `F32` ([`ScanlineHelper.cpp`][scanline]).

### 7. CPU parallelism and SIMD

OCIO starts no threads ([`src/OpenColorIO`][src] has no `std::thread` beyond a debug
lock); `CPUProcessor` is shared and the caller splits the image, as OIIO does with
`parallel_image`. SIMD is runtime-dispatched per op: the 1D and 3D LUT renderers have
SSE2, AVX, AVX2 and AVX-512 variants chosen through `CPUInfo`, which also skips AVX
on CPUs flagged `AVXSlow` and AVX2 gathers on `AVX2SlowGather`
([`Lut3DOpCPU.cpp`][lut3d-dispatch], [`CPUInfo.h`][cpuinfo]).
`OPTIMIZATION_FAST_LOG_EXP_POW` swaps in SSE approximations of `log`, `exp` and
`pow`. **Demonstrated**: the default (`VERY_GOOD`) processor maps sRGB 0.5 to
`0.214037` in `ACEScg`, beside `0.214041` from the exact sRGB EOTF; the same default
flags with `OPTIMIZATION_FAST_LOG_EXP_POW` cleared give `0.214041`, so the residue is
that approximation.

### 8. GPU offload and interop

The decisive design choice: OCIO owns the colour mathematics and none of the GPU
plumbing. It emits source text and LUT arrays; the host compiles, allocates,
uploads and binds. That is why one library serves OpenGL, Vulkan, Metal and DirectX
hosts, and why Blender can force 2D textures for 1D LUTs and half-float storage on its side.
The cost is that the host must accept shader source at run time (or bake it per
config), and that CPU and GPU agree only within a tolerance, which the GPU tests
check by rendering the same values on both and comparing
([`GPUUnitTest.cpp`][gpu-test]).

### 9. Temporal, animation and containers

Not applicable: OCIO processes one image at a time and knows no sequences or
containers. The nearest feature is dynamic properties (exposure, contrast, gamma and
the grading transforms, [`OpenColorTypes.h`][dyn-props]), which let a host change a
parameter per frame on an existing processor without rebuilding it.

### 10. Testing and conformance

The tree carries CPU unit tests per op and format (`tests/cpu`), a GPU suite that
validates each op family against the CPU result (`tests/gpu`, 17 files), Python and
Java binding tests, and an OSL target (`tests/osl`). The built-in configs double as
regression fixtures for config parsing. The CPU path is the oracle for the GPU path.

---

## Lessons for Sparkles

- **Q5** A minimum colour model can separate _identity_ (a name or interop ID with a
  reference space and an encoding class) from _mathematics_ (the op list). OCIO shows
  the encoding classes (`scene-linear`, `log`, `sdr-video`, `hdr-video`, `data`) are
  enough to pick views automatically; Sparkles would still need to decide whether that
  identity rides on the pixel view (the [baseline gap G4][bl-gaps]) or beside it, which
  OCIO leaves to applications.
- **Q5** Interop IDs, CICP and ICC are three keys to the same identity. OCIO accepts
  only the first natively; a D layer that reads PNG `cICP` and `iCCP` must map them
  itself, as OpenImageIO does. Matrix/TRC ICC is the subset OCIO found worth parsing.
- **Q3** A transform chain as data plus a peephole optimiser (remove inverse pairs,
  compose matrices, fold separable prefixes into a 1D LUT for integer input) is
  directly expressible in D, and could run at compile time when the chain is static,
  which OCIO cannot do; the runtime-config case still needs the runtime optimiser.
- **Q3** Named precision levels are a usable contract: `LOSSLESS` keeps every op
  exact, the default `VERY_GOOD` already trades exactness for speed (1D-LUT
  composition, fast `log`/`exp`/`pow`), and `GOOD` and `DRAFT` bake into 3D LUTs. A
  Sparkles layer has to choose whether its default is the exact level. OIIO's
  workaround for a composition bug shows each rewrite needs its own differential test.
- **Q7** One kernel signature over a row of packed RGBA `float` makes every op
  SIMD-able and every op GPU-emittable; the same op list producing both a CPU loop
  and shader code is the shape a D design could get from one source with
  [`sparkles:shaders`][bl-shaders] and D-to-SPIR-V instead of text GLSL. OCIO's text
  output does not fit a pipeline that compiles shaders at build time without a runtime
  GLSL compiler.
- **Q6** The GPU interface (shader function, textures, uniform block size, descriptor
  set index) is small enough to map onto the Vulkan baseline; `GLSL_VK_4_6` already
  reserves binding 0 for the uniform block.
- **Q4** Processor caching keyed by a canonical transform description, with reuse
  across contexts by op-list hash, avoids re-optimising on every frame; the stale-LUT
  hazard (keys omit LUT contents) is a reason to key on content hashes instead.
- **Q8** OCIO's CPU processor is a ready oracle for a Sparkles colour layer: the
  differential test is "same input, same config, compare within tolerance", the same
  pattern OCIO uses between its own CPU and GPU paths.
- **Q9** OCIO is a separate library from any image I/O, and both of its large
  consumers keep it behind their own wrapper; evidence for colour management as its own
  package that image-core depends on, not the reverse. Binding OCIO itself from D
  would bring C++ exceptions, `shared_ptr` handles and YAML parsing, none `@nogc`.

## Strengths

- One config drives every application in a pipeline; applications ask by role or name.
- Analytic builtin transforms remove LUT files from standard conversions.
- The optimiser composes and cancels ops under explicit, documented precision levels.
- GPU output is API-neutral source text plus LUT data, tested against the CPU path.
- Borrowed, strided `ImageDesc` lets callers keep their own buffers.
- Built-in ACES configs and the `ocio://` URI give a working default with no files.

## Weaknesses

- Pixels carry no colour state; every consumer re-invents the tagging.
- No CICP, and ICC limited to matrix/TRC display profiles.
- No internal threading; per-call scratch allocation in `ScanlineHelper`.
- Processor cache keys omit LUT contents; edited LUTs need a manual cache clear.
- `isNoOp` on an unoptimised processor misses identities that the optimiser removes.
- LUT readers are not fuzzed; size limits were missing from some readers in released
  versions (2.4.2 `.cube`).
- Run-time shader text does not suit a build-time SPIR-V pipeline.
- C++ exceptions and reference-counted handles throughout the API.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                  | Trade-off                                                                  |
| ------------------------------------------------ | ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| Colour identity lives in a config, not in pixels | One file governs every application in a pipeline           | Every consumer tracks which space each buffer is in                        |
| Transforms compile to an optimised op list       | Inverse pairs cancel and matrices compose before any pixel | Default `VERY_GOOD` is not exact; `isNoOp` reports on the unoptimised list |
| GPU output is shader text plus LUT arrays        | One library serves OpenGL, Vulkan, Metal and DirectX hosts | Hosts must compile shader source at run time                               |
| Borrowed, strided `ImageDesc`, one row at a time | Callers keep their buffers; one kernel signature per op    | Scratch rows allocated per call; no threading inside the library           |
| Processor cache keyed by transform text          | Repeated `getProcessor` calls cost a hash lookup           | Edited LUT files are not noticed without `clearProcessorCache()`           |

## Sources

- Source at the pinned revision: [`OpenColorIO.h`][h-usage], [`OpenColorTypes.h`][opt-flags],
  [`Config.cpp`][cfg-cache], [`Processor.cpp`][proc-opt], [`CPUProcessor.cpp`][cpu-apply],
  [`ScanlineHelper.cpp`][scanline], [`OpOptimizers.cpp`][opt-loop], [`Caching.h`][caching],
  [`LutLimits.h`][lut-limits], [`FileFormatIridasCube.cpp`][cube-limit],
  [`FileFormatICC.cpp`][icc], [`Lut3DOpCPU.cpp`][lut3d-dispatch],
  [`BuiltinTransformRegistry.cpp`][builtin-reg], [`Displays.cpp`][builtin-srgb],
  [`cg-config-v5.0.0_aces-v2.1_ocio-v2.6.ocio`][cg-roles], [`GPUUnitTest.cpp`][gpu-test].
- Documentation: [`README.md`][readme], [`internal_architecture.rst`][arch-summary],
  [`compatible_software.rst`][compat], [opencolorio.readthedocs.io][docs].
- Consumers: OpenImageIO [`color_ocio.cpp`][oiio-proc] at `e7eb5d1091142cb6`
  ([deep-dive][oiio]); Blender [`libocio_gpu_shader_binder.cc`][bl-binder],
  [`libocio_fallback_config.cc`][bl-fallback], [`config.ocio`][bl-config] at
  `049750f9fa83416e8bf9ae24e44b869f5ff46584`.
- Catalog: [concepts][concepts], [baseline: existing code][bl-gaps],
  [colour and resampling papers][p-colour].

<!-- References -->

[repo]: https://github.com/AcademySoftwareFoundation/OpenColorIO
[docs]: https://opencolorio.readthedocs.io/
[license]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/LICENSE
[bindings]: https://github.com/AcademySoftwareFoundation/OpenColorIO/tree/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/bindings
[src]: https://github.com/AcademySoftwareFoundation/OpenColorIO/tree/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO
[readme]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/README.md#L24-L30
[readme-mission]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/README.md#L50-L61
[arch-summary]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/concepts/overview/internal_architecture.rst#L88-L96
[arch-names]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/concepts/overview/internal_architecture.rst#L123-L127
[compat]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/docs/guides/using_ocio/compatible_software.rst#L69-L82
[h-usage]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L24-L56
[h-create]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L285-L399
[h-filepath]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L1578-L1586
[h-getproc]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L1622-L1677
[h-ioproxy]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L1805-L1830
[h-findid]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L789-L853
[h-interop]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L2258-L2269
[h-processor]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L2863-L3005
[h-legacy]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L2960-L2967
[h-imagedesc]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L3316-L3370
[h-packed]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L3376-L3495
[h-vk]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L3612-L3648
[h-gpudesc]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorIO.h#L3880-L4040
[ref-space]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L310-L314
[bitdepth]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L428-L457
[gpu-lang]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L466-L481
[opt-flags]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L635-L724
[dyn-props]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L570-L579
[cache-flags]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L730-L744
[roles]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/include/OpenColorIO/OpenColorTypes.h#L860-L921
[cfg-cache]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/Config.cpp#L5420-L5480
[proc-opt]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/Processor.cpp#L380-L415
[proc-cpu]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/Processor.cpp#L530-L576
[cpu-apply]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/CPUProcessor.cpp#L379-L405
[scanline-tmpl]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/CPUProcessor.cpp#L187-L196
[scanline]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/ScanlineHelper.cpp#L88-L111
[opt-loop]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/OpOptimizers.cpp#L684-L725
[caching]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/Caching.h#L20-L111
[lut-limits]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/LutLimits.h#L10-L15
[cube-limit]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/fileformats/FileFormatIridasCube.cpp#L244-L255
[icc]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/fileformats/FileFormatICC.cpp#L22-L31
[fileformats]: https://github.com/AcademySoftwareFoundation/OpenColorIO/tree/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/fileformats
[lut3d-dispatch]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/ops/lut3d/Lut3DOpCPU.cpp#L386-L416
[cpuinfo]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/CPUInfo.h#L64-L70
[builtin-reg]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/transforms/builtins/BuiltinTransformRegistry.cpp#L49-L121
[builtin-srgb]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/transforms/builtins/Displays.cpp#L295-L311
[builtin-configs]: https://github.com/AcademySoftwareFoundation/OpenColorIO/tree/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/builtinconfigs/configs
[cg-roles]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/builtinconfigs/configs/cg-config-v5.0.0_aces-v2.1_ocio-v2.6.ocio#L15-L33
[cg-srgb]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/src/OpenColorIO/builtinconfigs/configs/cg-config-v5.0.0_aces-v2.1_ocio-v2.6.ocio#L414-L431
[gpu-test]: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/22dd9c4faa0d1b7cfb3d64d1a6e9cb454acc6cfd/tests/gpu/GPUUnitTest.cpp#L520-L558
[oiio-proc]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L1905-L1931
[oiio-cache]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L83-L151
[oiio-par]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L3025-L3045
[oiio-gamma]: https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/e7eb5d1091142cb69d99c72b85da2734fcf390a7/src/libOpenImageIO/color_ocio.cpp#L60-L68
[bl-config]: https://github.com/blender/blender/blob/049750f9fa83416e8bf9ae24e44b869f5ff46584/release/datafiles/colormanagement/config.ocio#L11-L71
[bl-fallback]: https://github.com/blender/blender/blob/049750f9fa83416e8bf9ae24e44b869f5ff46584/source/blender/imbuf/opencolorio/intern/libocio/libocio_fallback_config.cc#L14-L20
[bl-binder]: https://github.com/blender/blender/blob/049750f9fa83416e8bf9ae24e44b869f5ff46584/source/blender/imbuf/opencolorio/intern/libocio/libocio_gpu_shader_binder.cc#L184-L215
[bl-tex]: https://github.com/blender/blender/blob/049750f9fa83416e8bf9ae24e44b869f5ff46584/source/blender/imbuf/opencolorio/intern/libocio/libocio_gpu_shader_binder.cc#L60-L86
[oiio]: ./openimageio.md
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-hostile]: ./concepts.md#hostile-input
[bl-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders]: ./baseline/shaders-simd.md
[p-colour]: ./papers/resampling-colour.md
