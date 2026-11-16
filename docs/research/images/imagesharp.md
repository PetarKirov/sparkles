# ImageSharp (C#)

A fully managed .NET imaging library whose `Image<TPixel>` is generic over a pixel struct constrained to `unmanaged, IPixel<TPixel>`: a mainstream analogue to a D template library, with run-time format dispatch, pooled discontiguous pixel memory and SIMD kernels written against .NET hardware intrinsics.

| Field         | Value                                                                                                                                                                 |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C# (`net10.0` target, `net11.0` in preview CI); nullable warnings are errors ([`ImageSharp.csproj`][csproj])                                                          |
| License       | Six Labors Split License 1.0: Apache 2.0 or a Six Labors commercial licence, by qualifying criteria ([`LICENSE`][license])                                            |
| Repository    | [SixLabors/ImageSharp][repo]                                                                                                                                          |
| Revision read | `b2b1ca9bda8b6b2cdd748b001f59b533f36da4db` (`main`, October 27, 2026; pre-release of major version 5, per `MinVerMinimumMajorMinor` in [`ImageSharp.csproj`][csproj]) |
| Documentation | [sixlabors.github.io/docs][docs] · [Samples repository][samples] · in-source XML doc comments                                                                         |
| Category      | Generic libraries: compile-time pixel genericity over value types, run-time codec registry, eager processor pipeline                                                  |
| Tier          | A                                                                                                                                                                     |
| Last reviewed | November 14, 2026                                                                                                                                                     |

> [!NOTE]
> Everything below was read from the source at the pinned revision with
> `git show <sha>:<path>` (a blobless clone; the source blobs were fetched in one batch
> and extracted to a scratch directory). No .NET SDK was available, so no ImageSharp
> code was compiled or run. Claims marked **verified** were demonstrated with a D probe
> compiled by LDC 1.43.0 under `-betterC -preview=dip1000`. No performance number in
> this page was measured.
>
> Independent verification on November 14, 2026 re-read the pinned sources and reran
> the D conversion, constraint-rejection and byte-round-trip checks under
> `nix develop /home/petar/code/repos/mine/sparkles-images -c ldc2` in
> `/tmp/imagesharp-verifier-final`, using `-betterC -preview=dip1000`. The identity-copy
> check required an elementwise copy; the original slice assignment failed to link
> when that previously unexecuted branch was instantiated. These probes test a D
> adaptation, not ImageSharp's implementation or its SIMD kernels.

---

## Overview

### What it solves

ImageSharp provides cross-platform image processing in managed code. Its test workflow
installs `libgdiplus` on Linux and macOS for reference codecs ([workflow][ci-gdi]).
ImageSharp decodes, processes and encodes images entirely in
managed code, across PNG, JPEG, GIF, BMP, PBM, TGA, TIFF, WebP, EXR, QOI, HEIF/AVIF, ICO,
CUR and ANI (the fourteen modules registered by `Configuration.CreateDefaultInstance`,
[`Configuration.cs`][configuration-default]). The README states the scope
([`README.md`][readme]):

> _"ImageSharp is a mature, fully featured, high-performance image processing and graphics library for .NET, built for workloads across device, cloud, and embedded/IoT scenarios."_

The design problem it solves is the one Boost.GIL ([deep-dive][gil]) solves in C++: an
algorithm should be written once and specialised for many pixel layouts. ImageSharp
answers it with C# generics constrained to value types, which the runtime compiles
separately for each struct argument, plus a per-pixel-type object of bulk conversions
that specific types override with SIMD code.

### Design philosophy

Three positions recur in the source.

1. **The pixel type is a static type parameter, not a run-time descriptor.** Every image
   is an `Image<TPixel>` and every processor is instantiated per `TPixel`. The formats
   are _"adapted and extended from"_ MonoGame and keep its naming rule
   ([`PixelFormats/README.md`][pf-readme], repeated in [`IPixel.cs`][ipixel]):

   > _"The naming convention of each pixel format is to order the color components from least significant to most significant, reading from left to right. For example in the Rgba32 pixel format the R component is the least significant byte, and the A component is the most significant."_

2. **Performance overrides convention.** `Rgba32` is a mutable struct with public fields,
   and says why ([`Rgba32.cs`][rgba32]):

   > _"This struct is fully mutable. This is done (against the guidelines) for the sake of performance, as it avoids the need to create new values for modification operations."_

3. **Vector4 is the lingua franca.** Every pixel type converts to and from a
   `System.Numerics.Vector4`; processors such as colour filters work on rows of `Vector4`, and the
   per-type `PixelOperations<TPixel>` makes the round trip fast for the common types. The
   pairwise paths (`Rgba32` to `Bgra32` and the like) are generated from T4 templates
   (`*.Generated.tt`).

Against the survey, ImageSharp is the managed-runtime member of the generic-library
family (with [Boost.GIL][gil], [VIGRA][vigra] and [JuliaImages][julia]), with a broad
managed codec set of its own.

---

## How it works

### Pixels: static abstract interface members

`IPixel<TSelf>` uses C# 11 static abstract members, so a pixel type supplies
constructors from every canonical type as static functions, the way a D template would
call `P.fromScaled(v)` on a type parameter ([`IPixel.cs`][ipixel-static]):

```csharp
// src/ImageSharp/PixelFormats/IPixel.cs (abridged)
public interface IPixel<TSelf> : IPixel, IEquatable<TSelf>
    where TSelf : unmanaged, IPixel<TSelf>
{
    public static abstract PixelOperations<TSelf> CreatePixelOperations();
    public static abstract TSelf FromScaledVector4(Vector4 source);
    public static abstract TSelf FromAssociatedScaledVector4(Vector4 source);
    public static abstract TSelf FromRgba32(Rgba32 source);
    // ... FromAbgr32, FromArgb32, FromBgra5551, FromBgr24, FromBgra32, FromL8,
    //     FromL16, FromLa16, FromLa32, FromRgb24, FromRgb48, FromRgba64
}

public interface IPixel
{
    public static abstract PixelTypeInfo GetPixelTypeInfo();
    public Rgba32 ToRgba32();
    public Vector4 ToScaledVector4();
    public Vector4 ToAssociatedScaledVector4();
    // ...
}
```

The `unmanaged` constraint admits only structs with no managed references, so a pixel
can be reinterpreted as bytes (`MemoryMarshal.Cast`) and its size taken with
`Unsafe.SizeOf<TPixel>()`. Integer pixel types use normalised `[0, 1]` scaled
vectors; native vectors are type-specific (for example a signed `NormalizedByte4`
ranges over `[-1, 1]`). This is not a universal range bound: `RgbaVector` preserves
floating-point values in both native and scaled vectors ([`RgbaVector.cs`][rgbavector]).

There are 40 pixel structs under `PixelFormats/PixelImplementations/`: 8-bit
interleaved (`Rgba32`, `Bgra32`, `Argb32`, `Abgr32`, `Rgb24`, `Bgr24`), grey (`L8`,
`L16`, `La16`, `La32`, `A8`), 16-bit (`Rgb48`, `Rgba64`), packed (`Bgr565`, `Bgra4444`,
`Bgra5551`, `Rgba1010102`, `Rg32`, `Byte4`), signed normalised (`NormalizedByte2/4`,
`NormalizedShort2/4`, `Short2/4`), half-float (`HalfSingle`, `HalfVector2/4`,
`RgbaHalf`), float (`Rgb96`, `Rgba128`, `RgbaVector`) and eight
premultiplied variants suffixed `P` (`Rgba32P`, `Bgra32P`, `Argb32P`, `Abgr32P`,
`RgbaHalfP`, `HalfVector4P`, `NormalizedByte4P`, `RgbaVectorP`).

Each type describes itself with a `PixelTypeInfo` ([`PixelTypeInfo.cs`][pti]): bits
per pixel, a `PixelComponentInfo` (component count and per-component bit widths), a
`PixelColorType` flag set and a `PixelAlphaRepresentation` (`None`, `Associated`,
`Unassociated`, [`PixelAlphaRepresentation.cs`][alpha]). `Rgba32` declares
([`Rgba32.cs`][rgba32-info]):

```csharp
// src/ImageSharp/PixelFormats/PixelImplementations/Rgba32.cs
public static PixelTypeInfo GetPixelTypeInfo()
    => PixelTypeInfo.Create<Rgba32>(
        PixelComponentInfo.Create<Rgba32>(4, 8, 8, 8, 8),
        PixelColorType.RGB | PixelColorType.Alpha,
        PixelAlphaRepresentation.Unassociated);
```

The record is admitted to be overloaded; its header says
([`PixelTypeInfo.cs`][pti]): _"TODO: Review this type as it's used to represent 2
different things. 1. The encoded image pixel format. 2. The pixel format of the decoded
image."_

### Bulk conversion: `PixelOperations<TPixel>`

`PixelOperations<TPixel>` is a class with one lazily created instance per pixel type,
obtained through the static abstract factory ([`PixelOperations{TPixel}.cs`][pixops-head]):

```csharp
// src/ImageSharp/PixelFormats/PixelOperations{TPixel}.cs
public partial class PixelOperations<TPixel>
    where TPixel : unmanaged, IPixel<TPixel>
{
    private static readonly Lazy<PixelOperations<TPixel>> LazyInstance
        = new(TPixel.CreatePixelOperations, true);
    public static PixelOperations<TPixel> Instance => LazyInstance.Value;
```

Its methods are `virtual`, and a pixel type's nested `PixelOperations` subclass
overrides them. There are three tiers:

- **Generic fallback.** `From<TSourcePixel>` converts any pixel type into any other via
  `Vector4`, in slices of at most 1024 pixels, with a temporary vector buffer from the
  configured `MemoryAllocator`, and inserts premultiply or unpremultiply when the
  source and destination alpha representations differ ([`From`][pixops-from]).
- **Per-canonical-type loops.** The generated base (`PixelOperations{TPixel}.Generated.cs`)
  has canonical conversion methods; `FromArgb32` is a scalar loop calling the
  static `TPixel.FromArgb32` ([generated base][pixops-gen]).
- **Specialised overrides.** `Rgba32.PixelOperations` replaces `ToVector4` with
  `SimdUtils.ByteToNormalizedFloat` over the reinterpreted bytes and `FromVector4Destructive`
  with `SimdUtils.NormalizedFloatToByteSaturate` ([`Rgba32.PixelOperations.cs`][rgba32-ops]);
  the generated file maps `ToArgb32` to a byte shuffle, `PixelConverter.FromRgba32.ToArgb32`
  ([generated `Rgba32`][rgba32-gen]).

`To<TDestinationPixel>` short-circuits identical types to a copy and otherwise forwards
to the destination's `From` ([`To`][pixops-to]):

```csharp
// src/ImageSharp/PixelFormats/PixelOperations{TPixel}.cs
if (typeof(TPixel) == typeof(TDestinationPixel))
{
    MemoryMarshal.Cast<TPixel, TDestinationPixel>(source).CopyTo(destination);
    return;
}
PixelOperations<TDestinationPixel>.Instance.From(configuration, source, destination);
```

The pattern is a shell with hooks, in the terms of the
[design-by-introspection guidelines][dbi], expressed with virtual dispatch on a
singleton rather than with compile-time presence tests.

### Memory: `Buffer2D<T>` over a `MemoryGroup<T>`

A frame's pixels live in a `Buffer2D<T>` ([`Buffer2D{T}.cs`][buffer2d]): a `Size`, a
`RowStride` in elements and a `MemoryGroup<T>`, which is a list of
`Memory<T>` buffers. The allocator sizes buffers so that **rows never straddle a
buffer boundary**: `MemoryGroup<T>.Allocate` takes a `bufferAlignmentInElements`
(the row width, passed by `Allocate2D`) and rounds each buffer to a whole number of rows
([`MemoryGroup{T}.cs`][memgroup-alloc]):

```csharp
// src/ImageSharp/Memory/DiscontiguousBuffers/MemoryGroup{T}.cs
int blockCapacityInElements = bufferCapacityInBytes / ElementSize;
// ...
int numberOfAlignedSegments = blockCapacityInElements / bufferAlignmentInElements;
int bufferLength = numberOfAlignedSegments * bufferAlignmentInElements;
```

So `DangerousGetRowSpan(y)` always returns one `Span<T>`, but the image as a whole is
contiguous only if the group has one buffer. `DangerousTryGetSingleMemory` reports
whether it does, and fails for padded strides too ([`DangerousTryGetSingleMemory`][buffer2d-single]).
A `RowStride` larger than the width is supported only for single-buffer groups (wrapped
external memory): `DangerousGetRowSpan` indexes `FastMemoryGroup[0]` whenever
`RowStride != Width` ([`DangerousGetRowSpan`][buffer2d-row]).

The default allocator is `UniformUnmanagedMemoryPoolMemoryAllocator`
([factory][allocator-create], [source][uumpa]). Requests up to 1 MiB come from the
shared managed `ArrayPool`; up to 4 MiB from a pool of uniform 4 MiB unmanaged blocks (_"4 MB seemed to perform slightly
better in benchmarks than 2MB or higher values"_); larger images become a group of pool
blocks or, if the pool is exhausted, a group of 32 MiB unmanaged buffers. The pool's
ceiling is one eighth of `GCMemoryInfo.TotalAvailableMemoryBytes` on 64-bit
([`GetDefaultMaxPoolSizeBytes`][uumpa-pool]).

The byte limits are explicit allocator policy ([`MemoryAllocator`][allocator-limits]):
`SingleBufferAllocationLimitBytes` defaults to 1 GiB and is an `int`, so the allocator
cannot permit more than `int.MaxValue` bytes per single allocation. A memory group
(such as one frame's pixels) defaults to a 4 GiB cap on 64-bit and 1 GiB on 32-bit;
`AccumulativeAllocationLimitBytes` optionally caps the combined live allocations
through that allocator. The group cap alone does not cap all frames of an animation.
`Configuration.PreferContiguousImageBuffers` requests one buffer, and
`Allocate2D` takes that path only while `width * height` is below `int.MaxValue`,
subject to the single-buffer byte limit
([`Allocate2D`][allocate2d]).

### Configuration and format modules

`Configuration` holds the `MemoryAllocator`, `MaxDegreeOfParallelism` (default
`Environment.ProcessorCount`), `StreamProcessingBufferSize`, an `ImageFormatManager`
and a property bag ([`Configuration.cs`][configuration]). Formats are plugged in by
`IImageFormatConfigurationModule.Configure(Configuration)`, each registering an
`IImageFormat`, a decoder, an encoder and an `IImageFormatDetector`. Detection reads
up to `MaxHeaderSize` bytes (the largest `HeaderSize` of the registered detectors) and asks
each detector whose header fits to `TryDetectFormat(ReadOnlySpan<byte> header, out IImageFormat? format)`
([`ImageFormatManager.cs`][formatmanager], [`Image.Decode.cs`][detect-read],
[detector dispatch][detect-dispatch], [`IImageFormatDetector.cs`][detector]).

`IImageDecoder` has three synchronous entry points, each with an asynchronous counterpart:
`Identify` (dimensions, pixel type and metadata without decoding pixels),
`Decode<TPixel>` and a non-generic `Decode` that chooses the
pixel type ([`IImageDecoder.cs`][idecoder]). PNG's non-generic path is an identify, a
rewind and a `switch` that selects a generic decoder instantiation. JPEG instead
directly chooses `Rgb24` without an identify pass ([`JpegDecoder.cs`][jpegdecoder]). For PNG
([`PngDecoder.cs`][pngdecoder]):

```csharp
// src/ImageSharp/Formats/Png/PngDecoder.cs (abridged)
ImageInfo info = decoder.Identify(options.GeneralOptions.Configuration, stream, cancellationToken);
stream.Position = 0;
PngMetadata meta = info.Metadata.GetPngMetadata();
switch (meta.ColorType)
{
    case PngColorType.Rgb:
        if (meta.BitDepth == PngBitDepth.Bit16)
            return !meta.TransparentColor.HasValue
                ? this.Decode<Rgb48>(options, stream, cancellationToken)
                : this.Decode<Rgba64>(options, stream, cancellationToken);
        // ...
```

`DecoderOptions` ([source][decoderoptions]) carries `TargetSize` and `Sampler` (decode
then resize, except where a codec scales natively: JPEG's `SpectralConverter` takes the
target size, [`JpegDecoderCore.cs`][jpeg-spectral]), `SkipMetadata`, `MaxFrames`,
`SegmentIntegrityHandling` (`Strict`, `IgnoreAncillary` by default, `IgnoreImageData`)
and `ColorProfileHandling` (`Preserve`, `Compact`, `Convert`). Codec-specific options
derive from `ISpecializedDecoderOptions` (`PngDecoderOptions`, `JpegDecoderOptions`, ...).

### Processing: `Mutate`, `Clone` and `IImageProcessor`

`image.Mutate(x => x.Resize(...).Grayscale())` and `image.Clone(...)` hand a lambda an
`IImageProcessingContext`. Each extension method (`Resize`, `Grayscale`, `GaussianBlur`)
calls `ApplyProcessor` with a non-generic `IImageProcessor`, a parameter record whose one
method is `CreatePixelSpecificProcessor<TPixel>` ([`IImageProcessor.cs`][iprocessor]).
The default context runs each processor **immediately**; there is no graph and no
fusion ([`DefaultImageProcessorContext{TPixel}.cs`][context]):

```csharp
// src/ImageSharp/Processing/DefaultImageProcessorContext{TPixel}.cs (abridged)
// (a Clone context first copies the source, or lets a cloning processor build the copy)
using (IImageProcessor<TPixel> specificProcessor =
    processor.CreatePixelSpecificProcessor(this.Configuration, this.destination!, rectangle))
{
    specificProcessor.Execute();
}
```

The context can avoid an interim clone when its first processor implements
`ICloningImageProcessor`, such as resize; this is not restricted to size changes.
`ImageProcessor<TPixel>` then loops over frames and calls `OnFrameApply` for each
([`ImageProcessor{TPixel}.cs`][improc]).

A typical point operation converts a row to `Vector4`, transforms it and converts
back, inside a row operation struct ([`FilterProcessor{TPixel}.cs`][filter]):

```csharp
// src/ImageSharp/Processing/Processors/Filters/FilterProcessor{TPixel}.cs (abridged)
private readonly struct RowOperation : IRowOperation<Vector4>
{
    public int GetRequiredBufferLength(Rectangle bounds) => bounds.Width;

    public void Invoke(int y, Span<Vector4> span)
    {
        Span<TPixel> rowSpan = this.source.DangerousGetRowSpan(y).Slice(this.startX, span.Length);
        PixelOperations<TPixel> pixelOperations = PixelOperations<TPixel>.Instance;
        pixelOperations.ToVector4(this.configuration, rowSpan, span,
            PixelConversionModifiers.Scale | PixelConversionModifiers.UnPremultiply);
        ColorNumerics.Transform(span, ref Unsafe.AsRef(in this.matrix));
        pixelOperations.FromVector4Destructive(this.configuration, span, rowSpan,
            PixelConversionModifiers.Scale | PixelConversionModifiers.UnPremultiply);
    }
}
```

`ParallelRowIterator.IterateRows<T, TBuffer>` takes `in T operation` with
`where T : struct, IRowOperation<TBuffer>`, splits the rectangle into horizontal bands
using `ceil(pixelCount / MinimumPixelsProcessedPerTask)` to bound the partition count
(default threshold 4096), together with `MaxDegreeOfParallelism`; the threshold is not
a strict minimum band size ([partition calculation][rowiter-steps]). It runs bands with
`Parallel.For`; each nonempty band allocates its own `TBuffer` scratch row
([`ParallelRowIterator.cs`][rowiter], [band wrapper][rowiter-wrapper],
[`ParallelExecutionSettings.cs`][parsettings]).
The struct constraint is what makes the per-row call direct: the operation is a value
type argument, so its `Invoke` is compiled for that type rather than called through an
interface.

### SIMD: `SimdUtils` over `System.Runtime.Intrinsics`

`SimdUtils` is split into a portable front (`SimdUtils.Convert.cs`), shuffles, packing and
an `HwIntrinsics` class (1,028 lines). A front function hands the largest
vector-multiple prefix to the intrinsic path and finishes the tail with scalar code
([`SimdUtils.Convert.cs`][simd-convert]). The kernel branches on ISA predicates in
order ([`SimdUtils.HwIntrinsics.cs`][simd-hw]):

```csharp
// src/ImageSharp/Common/Helpers/SimdUtils.HwIntrinsics.cs (abridged)
if (Vector512.IsHardwareAccelerated && Avx512F.IsSupported)
{
    Vector512<int> i0 = Avx512F.ConvertToVector512Int32(Vector128.LoadUnsafe(ref sourceBase, si));
    Vector512<float> f0 = Avx512F.ConvertToVector512Single(i0);
    // The residual term restores the correctly rounded byte / 255F result without paying for vector division.
    f0 = Vector512.FusedMultiplyAdd(f0, high, f0 * low);
}
else if (Avx2.IsSupported) { /* same with Vector256 */ }
else if (Vector128.IsHardwareAccelerated) { /* cross-platform Vector128 */ }
```

The implementation credits PhotoSauce's MagicScaler in a comment. `Vector128`, `Vector256`
and `Vector512Utilities.cs` hold shuffles and packs with per-ISA branches (SSE, AVX2,
AVX-512, Arm64 `AdvSimd` and, in `Vector128Utilities.cs`, WebAssembly `PackedSimd`).

---

## Analysis

### 1. Pixel and memory model

The model is interleaved, 2-D and per frame: an `Image<TPixel>` is a list of
`ImageFrame<TPixel>` of identical size (`ValidateFrame` in
[`ImageFrameCollection{TPixel}.cs`][framecoll]), each a `Buffer2D<TPixel>`. There are no
planes, no chroma subsampling, no tiles and no N-D extent in the public model; YCbCr
planes exist only inside decoders (JPEG's spectral buffers, HEIF's AV1 pipeline) and are
converted to interleaved pixels before an `Image` exists. `Rgba32.PixelOperations` has
a `PackFromRgbPlanes` hook that decoders use to interleave three byte planes
([`Rgba32.PixelOperations.cs`][rgba32-ops]).

Views are thin: `Buffer2DRegion<T>` is a rectangle over a buffer, and processors take a
`Rectangle` argument rather than a sub-image type. The stride is in elements, not bytes
([concepts: stride][c-stride]), so a row cannot start mid-pixel, a view cannot have a
negative step, and flips and rotations materialise their result rather than returning
a negative-stride view. A flip can rearrange pixels in place without any `Vector4`
conversion ([`FlipProcessor{TPixel}.cs`][flip]). The discontiguous `MemoryGroup` is the
unusual part: it is a deliberate departure from one-pointer-plus-stride
([concepts: image and view][c-view]), chosen so that large images do not need one large
allocation, at the cost that "the whole image as one span" is a fallible query.

### 2. Genericity mechanism

Constrained generics over value types. `where TPixel : unmanaged, IPixel<TPixel>`
plays the role of a D template constraint (`if (isPixel!P)`), static abstract members
play the role of static member functions found on a type parameter, and the `struct`
constraint on row operations plays the role of an alias or template parameter, giving one
compiled body per operation. The runtime compiles a generic separately for each value
type argument; `AotCompilerTools` shows the cost of this when there is no JIT: it lists
explicit instantiations so that an ahead-of-time compiler emits them
([`AotCompilerTools.cs`][aot]):

> _"Unlike traditional Mono/.NET, code on the iPhone is statically compiled ahead of time instead of being compiled on demand by a JIT compiler. This means there are a few limitations with respect to generics, these are caused because not every possible generic instantiation can be determined up front at compile time."_

Its legacy `SeedPixelFormats` calls `Seed<A8>()`, `Seed<Argb32>()` and so on, each
seeding a broad codec and processor graph. Modern `Configuration` constructors instead
root `SeedPixelOperations`, whose comment explicitly avoids that larger legacy graph
and whose calls retain selected bulk pixel-operation instantiations
([`Configuration.cs`][configuration], [modern seed graph][aot-modern]). Both inventories
list 39 pixel types; `RgbaVectorP` is absent despite being one of the 40 implementations.
This is evidence of an explicit AOT inventory, not a measurement of code-size growth.

Two mechanisms differ from D. First, the hooks are virtual methods on a singleton, not
compile-time presence tests: every pixel type has every conversion, through the base
class, and an override replaces it. Second, C# generics cannot test for an optional
member through these interface constraints, so the "does this pair have a fast path"
question is answered by overriding,
and identity is a run-time `typeof` comparison the JIT may fold. **Verified:** the same
shape in D (a pixel trait, a generic `convert!(S, D)` that goes through `float[4]` in
1024-pixel slices, a direct path chosen when `D.from(S)` compiles, and an identity copy
under `static if`) selects each path statically, rejects a non-pixel with a constraint
failure, and its direct and generic paths agree on 3,000 pixels, all
`@safe pure nothrow @nogc` under `-betterC -preview=dip1000`.
The independent rerun confirmed these checks and all 256 byte round trips with
LDC 1.43.0. The original probe only asserted the identity path's selection: actually
instantiating its slice assignment failed to link on `_d_array_slice_copy`.
Replacing that assignment with an elementwise loop made the 3,000-pixel identity
check pass under the same flags. The compile-time selection is the
[design-by-introspection][dbi] reading of `PixelOperations<TPixel>`.

### 3. Colour and metadata

Alpha is typed. `PixelAlphaRepresentation` and the `P` pixel types make premultiplication
part of the pixel type, and conversions insert premultiply or unpremultiply when the
representations differ ([`From`][pixops-from]); colour operations request
`UnPremultiply` explicitly ([`FilterProcessor{TPixel}.cs`][filter]). This is the
declared-state model [concepts: straight and premultiplied alpha][c-alpha] describes.

Colour space is not typed. Pixel types do not bind primaries or a transfer function;
`PixelConversionModifiers.SRgbCompand` linearises on request, and resampling exposes a
`Compand` option. `ImageMetadata` carries the profiles as optional objects
(`ExifProfile`, `XmpProfile`, `IccProfile`, `IptcProfile`, `CicpProfile`,
[`ImageMetadata.cs`][imagemeta]). `CicpProfile` stores three H.273 enumerated code points
and a full-range Boolean. Unknown enumerated values become `Unspecified`; an absent
range flag defaults to full range for the identity matrix and limited range otherwise
([`CicpProfile.cs`][cicp]). PNG reads `cICP`
into it and ignores a short chunk ([`ReadCicpChunk`][png-cicp]). `ColorProfileHandling.Convert`
transforms pixels from an embedded ICC profile to a compact sRGB v4 profile through
`ColorProfileConverter` and removes the original profile. `Compact` removes a canonical
sRGB profile without transforming its pixels. There is an implementation caveat:
`TryGetIccProfileForColorConversion` also returns noncanonical profiles under `Compact`,
and PNG calls the conversion helper unconditionally; that mode can therefore transform
PNG pixels with a noncanonical profile ([`ImageDecoderCore.cs`][decodercore-icc],
[`DecoderOptions.cs`][decoderoptions], [PNG conversion call][png-icc],
[profile removal][decoder-icc]). No gain-map API was found in the pinned source.
HDR support does exist: the HEIF converter preserves floating-point HDR range, and
`HeifMetadata` carries mastering-display, content-light and viewing-environment records
([float packing][heif-float], [`HeifMetadata.cs`][heif-metadata]). The transfer and
primaries remain metadata rather than pixel-type guarantees.

`ExifProfile` holds the raw bytes and parses values on first access (`InitializeValues`
from the `Values` getter, [`ExifProfile.cs`][exif]). Per-format metadata is a dictionary
keyed by `IImageFormat`; asking for another format's metadata converts through
`FormatConnectingMetadata` (encoding type, quality, pixel type, colour table mode,
background, repeat count, [`ImageMetadata.cs`][imagemeta-format],
[`FormatConnectingMetadata.cs`][fcm]), which is how a GIF saved as WebP keeps its loop
count. The [colour deep-dive][colour] covers the conversion maths this page does not.

### 4. I/O and codec architecture

Pull, synchronous and whole-image. A decoder core reads from a `BufferedReadStream`
and returns a complete `Image<TPixel>` ([`ImageDecoderCore.cs`][decodercore]); there is
no row callback, no partial result and no resumable state
([concepts: push and pull decoding][c-pushpull]). A non-seekable stream is first copied
into a `ChunkedMemoryStream` from the allocator. The asynchronous API does not make the
decoder asynchronous; for streams other than `MemoryStream` and `ChunkedMemoryStream`,
it copies the remaining input into memory before decoding synchronously
([`ImageDecoder.cs`][decoder-async]). The comment states:

> _"NOTE: We are explicitly not executing the action against the stream here as we do in WithSeekableStream() because that would incur synchronous IO reads which must be avoided in this asynchronous method. Instead, we will *always* run the code below to copy the stream to an in-memory buffer before invoking the action."_

The code immediately below that comment bypasses copying for those two known memory
stream types. `Identify` reads headers and metadata without pixels. PNG's non-generic
`Decode` uses it to choose a pixel type, then rewinds and parses again; JPEG's
non-generic path directly chooses `Rgb24`. `CancellationToken` is threaded into the
cores; the PNG decoder checks it in its scanline loop
([`PngDecoderCore.cs`][png-cancel]). The format registry is a
run-time table per `Configuration`; trimming behaviour was not tested here.
Against [Wuffs-style suspendable decoding][c-suspend] this is the opposite end: simple
to call, impossible to feed incrementally.

### 5. Hostile input and safety

Memory safety comes mostly from the runtime: `Span<T>` indexing is bounds-checked, and
the codecs use `Unsafe.Add` and `MemoryMarshal.GetReference` (unchecked) in hot loops,
so safety there rests on the surrounding length checks. Resource limits are set in
the allocator, not in `DecoderOptions`: there is no maximum width, height or pixel
count option, and an oversized image fails when `AllocateGroup` exceeds
`MemoryGroupAllocationLimitBytes` ([`AllocateGroup`][allocator-group]). The decoder
core turns that into an `InvalidImageContentException` carrying the declared
dimensions ([`ImageDecoderCore.cs`][decodercore]). PNG exposes
`MaxUncompressedAncillaryChunkSizeBytes`, defaulting to 8 MiB
([`PngDecoderOptions.cs`][png-options]). Despite that property's broader XML summary,
the implementation applies the threshold to decompressed iCCP, zTXt and compressed
iTXt data, not to every ancillary chunk. The inflater checks the accumulated length
before writing the next buffer, so accepted output can exceed the threshold by one
stream buffer ([decompression loop][png-decompress], [compressed text][png-text],
[iTXt and text helper][png-itxt]). Raw chunk allocation is bounded by the remaining
input and the allocator's single-buffer limit, not this threshold
([`ReadChunkData`][png-chunkdata]).
`MaxFrames` bounds frame count, and cancellation provides caller control; there is
no general decode-time or work-budget option in `DecoderOptions`.

Integrity is a policy. `SegmentIntegrityHandling` decides which recoverable errors are
fatal, and states that _"Structural errors that prevent safe decoding remain fatal
regardless of the selected mode"_ ([`SegmentIntegrityHandling.cs`][sih]). PNG checks
CRCs of chunks the policy treats as critical: header and palette always, image data
unless `IgnoreImageData`, ancillary chunks only under `Strict`
([`PngChunk.cs`][png-critical], [`ValidateChunk`][png-crc]). Ancillary parsing runs
inside a catch in non-strict modes of `ImageFormatException`, `InvalidIccProfileException`,
`InvalidImageContentException`, `InvalidOperationException` and `NotSupportedException`
([`ExecuteAncillarySegmentAction`][decodercore-segments]).

Fuzzing is visible as a regression corpus, not a harness: test image names such as
`TestImages.Jpeg.Issues.Fuzz.AccessViolationException922` and
`NullReferenceException823` are listed under `Fuzz` in decoder regression cases
([`JpegDecoderTests.Images.cs`][jpeg-fuzz]); no fuzz target or OSS-Fuzz configuration
was found in the files read. `SECURITY.md` supports only the latest major version
([`SECURITY.md`][security]). The [hostile-input papers][p-hostile] frame what is
missing: limits by declared size, not by work, and no grammar-level parser.

### 6. Allocation and ownership

Ownership is `IDisposable`: an `Image` owns its frames, a frame owns its `Buffer2D`, and
the buffer returns its group to the pool on `Dispose`. Pooled unmanaged buffers carry
lifetime guards with finalizers (`UnmanagedBufferLifetimeGuard`,
`RefCountedMemoryLifetimeGuard`), so a leaked image is eventually returned rather than
lost; `Gen2GcCallback` trims the pool on garbage collections. Borrowed access is scoped
by reference counting: `ProcessPixelRows` increments the group's counts and passes a
`PixelAccessor<TPixel>`, a `ref struct` that cannot escape to the heap
([`Image{TPixel}.cs`][processrows], [`PixelAccessor{TPixel}.cs`][accessor]).
The `Memory<T>` and pointer overloads of `Image.WrapMemory` borrow caller memory;
the `IMemoryOwner<T>` overloads transfer ownership to the image
([memory overload][wrapmemory-borrow], [pointer overload][wrapmemory],
[owning overload][wrapmemory-owner]). Scratch rows in processors come
from the allocator per band.

The `Memory<T>` / `Span<T>` split is analogous to scoped borrowing with dip1000:
`Span<T>` cannot be stored in a heap object, while `Memory<T>` can. A D design can use
`scope` slices and an owner type; the probe above uses a 1024-element `float[4]`
stack scratch buffer (16 KiB) in betterC.

### 7. CPU parallelism and SIMD

Two levels. Parallelism is row bands over `Parallel.For`, bounded by
`MaxDegreeOfParallelism` and `MinimumPixelsProcessedPerTask` ([`ParallelRowIterator.cs`][rowiter]);
there is no tiling across operations and no task graph. SIMD is hand-written per ISA in
`SimdUtils`, `Vector*Utilities` and codec-specific code (JPEG colour conversion and
IDCT, PNG filters, WebP lossless transforms), with a `Vector128` portable tier and
predicate branches for AVX2, AVX-512, Arm64 and WebAssembly. Selection is expressed as
inline conditions rather than a dispatch table. Optimized JIT compilation treats
`IsSupported` checks as constants and removes unused paths
([Microsoft's intrinsics documentation][dotnet-intrinsics]); the source conditions
do not establish a per-call runtime check. Colour filters pay `TPixel` to `Vector4`
and back for each processed row; this is not a universal processor cost (flips rearrange `TPixel`
directly). **Verified (numerics only):** ImageSharp's scalar formula, `x / 255`
then `(byte)Clamp(v * 255 + 0.5, 0, 255)` ([`SimdUtils.Convert.cs`][simd-convert]),
returns every byte value unchanged after the round trip, reimplemented in the D probe;
the SIMD kernels' FMA residual trick was not run.

The [Halide deep-dive][halide] is the contrast: ImageSharp fixes the schedule (row
bands, a full pass per processor) inside each processor and never fuses two of them.

### 8. GPU offload and interop

Not applicable: a search of `src/` for Vulkan, OpenGL, CUDA, Direct3D and GPU found no
match. ImageSharp is a CPU library. Its interop surface is memory: `WrapMemory` over a
pointer or `Memory<T>`, `DangerousTryGetSinglePixelMemory`, `CopyPixelDataTo(Span<byte>)`
and `LoadPixelData`. With one tightly packed buffer, a caller can obtain CPU pixel memory
without first copying it into a flat staging array; this does not eliminate the GPU
upload itself. A GPU consumer needing a single span must check
that query or copy; a consumer supporting separate row or block uploads can also use
the discontiguous storage. `PreferContiguousImageBuffers` requests contiguous allocation
subject to its byte limit.

### 9. Temporal, animation and containers

Frames are first-class but eager. GIF, APNG, WebP, ANI, TIFF pages and HEIF sequences
decode every frame (up to `MaxFrames`) into the `ImageFrameCollection`, each a full
canvas: the GIF decoder starts each frame from a copy of the previous one or from the
background, applying disposal before the next frame is composited
([`GifDecoderCore.cs`][gif-compose]). Timing and compositing are per-frame metadata,
`FormatConnectingFrameMetadata` with `Duration` (`TimeSpan`), `BlendMode`,
`DisposalMode` and `ColorTableMode` ([`FormatConnectingFrameMetadata.cs`][fcfm]), so
formats convert animation parameters between each other. The `ImageProcessor<TPixel>`
base runs on every frame ([frame loop][improc]). The public frame model offers duration
rather than presentation timestamps, and no streaming frame or seeking API. HEIF's
internal sequence parser does calculate composition times, while `HeifFrameMetadata`
exports frame delays ([composition times][heif-times], [frame metadata][heif-frame]).
There is no audio or general video API.

### 10. Testing and conformance

Large and oracle-based. The test project references `Magick.NET-Q16-AnyCPU`,
`System.Drawing.Common`, `SharpZipLib` and `Wacton.Unicolour`
([`ImageSharp.Tests.csproj`][tests-csproj]); `MagickReferenceDecoder` and
`SystemDrawingReferenceDecoder` decode the same file for comparison, and reference
output images live in Git LFS under `tests/Images/External/ReferenceOutput/`. Comparison
is configurable: `TolerantImageComparer` uses normalised Manhattan RGBA64 distance,
summing channel errors and dividing by `pixelCount * 4 * 65535`. Its default threshold
is `257 / (10000 * 65535)`, equivalent on a 100x100 image to about one 8-bit unit in
each channel of one pixel, not 1% of the pixels; the source's short comment is misleading
([`TolerantImageComparer.cs`][tolerant]). Pixel types are a test axis (`PixelTypes`
flags drive the same test over many `TPixel`).

SIMD paths are tested by re-running tests in child processes with intrinsics disabled
through `DOTNET_Enable*` environment variables, one process per ISA level
([`FeatureTestRunner.cs`][feature]). When the remote executor is unsupported the runner
returns early, so the test passes without running. CI declares Ubuntu, Ubuntu ARM,
macOS and Windows runners for `net10.0` and `net11.0`, but every matrix entry passes
`-x64` as its test runtime; this is not evidence of successful native ARM execution
([`build-and-test.yml`][ci]).

---

## Lessons for Sparkles

- **Q2.** C# constrained generics over `unmanaged` structs are a close analogue
  to a D pixel template, and they show which parts carry over. A D `isPixel`
  trait can require what `IPixel<TSelf>` requires (scaled float conversion, type
  metadata as an `enum`), and `PixelTypeInfo` maps to compile-time enums (`alpha`,
  component bit widths). What does not transfer is the virtual-singleton hook:
  in D, presence tests (`static if (is(typeof(D.from(S.init))))`) select fast paths
  with no base-class fallback and no dispatch. **Verified** in the probe described in
  [§2][analysis-genericity], with an elementwise identity copy,
  `@safe pure nothrow @nogc` under `-betterC`. The
  [baseline][bl-existing] has no pixel type at all (G2); the
  [generic-programming papers][p-generic] and [Boost.GIL][gil] give the concept list.
- **Q2, Q9.** `AotCompilerTools` demonstrates the maintenance burden of explicit
  instantiation inventories. Its legacy codec/processor graph and modern bulk-operation
  graph are different; neither is a code-size measurement. D also compiles ahead of
  time, so pixel-type specialisation warrants measuring object size. PNG's run-time
  front door (identify, then `switch` to eight output types, [`PngDecoder.cs`][pngdecoder])
  bounds its selected output types and suggests a D `SumType` result; it costs a second
  parse of the headers. JPEG instead fixes the output to `Rgb24` without that pass.
- **Q1.** Rows that never straddle a buffer are a usable middle ground between one
  contiguous slab and arbitrary tiles: a D image could be a list of row-aligned
  `Buffer` blocks with `size_t` row indexing, keeping every row a slice. The price is
  that "the whole image as one slice" becomes a fallible query
  (`DangerousTryGetSingleMemory`); padded strides require a single-buffer group and
  also fail that tightly packed query. Consumers needing one span must handle that
  case. ImageSharp's element stride, missing planes and missing negative steps
  are the gaps [Boost.GIL][gil] and [mir][mir] do not have; the
  [baseline][bl-existing] G2 and [shaders-simd][bl-shaders] G10 record that Sparkles has
  no view type yet.
- **Q1, Q5.** Typed alpha transfers: making premultiplication a property of the pixel
  type (`Rgba32` versus `Rgba32P`) and inserting conversions automatically when types
  differ would remove the straight-versus-premultiplied split the
  [baseline][bl-existing] records (G3). Colour space as metadata only (`CicpProfile`,
  `IccProfile` objects) does not give the same guarantee; the
  [colour deep-dive][colour] covers typed alternatives.
- **Q4, Q6.** ImageSharp's codec boundary exposes a limitation relevant to
  `sparkles:event-horizon`: async decode buffers input other than known memory streams
  and then decodes synchronously. A Sparkles codec that should overlap I/O and decode, or decode a huge
  image in bounded memory, needs a push or suspendable decoder, which ImageSharp does not
  model. `Identify` without pixels and `TargetSize` passed into the JPEG IDCT are worth
  keeping as separate operations ([JPEG scaling][jpeg-scale],
  [event-horizon baseline][bl-eh]).
- **Q4, Q8.** Limits live in the allocator (a group byte cap, an optional cumulative
  cap) plus codec-specific decompression thresholds and a `MaxFrames` option. PNG's
  metadata threshold is neither universal nor exact. The group cap alone does not
  bound a multi-frame result. For a `@nogc` Sparkles codec the same
  idea maps to a caller-supplied budget checked before allocation and reported through
  `Expected`, not an exception; the [baseline][bl-existing] G7 notes that both existing
  PNG decoders bound bytes and neither bounds work, which ImageSharp does not solve
  either. The `SegmentIntegrityHandling` enum (which CRC and parse failures are fatal)
  is a small, testable policy surface worth evaluating.
- **Q3, Q7.** The row-operation struct plus `ParallelRowIterator` is a compact model of
  "algorithm as a value-type callback, schedule fixed by the iterator": in D, an alias
  template parameter does the same with no interface. Colour filters incur a per-row
  `TPixel`-to-`Vector4` round trip, and the default context has no fusion between processors; see
  [Halide][halide] for the alternative. The SIMD code is hand-written per ISA with
  inline predicates, the same pattern as the BLAKE3 backends in `sparkles:base`
  ([shaders-simd][bl-shaders] G4, G5); it does not offer a shared dispatch facility either.
- **Q8.** `FeatureTestRunner` re-runs the same test with ISA tiers switched off, which
  is the [baseline][bl-shaders]'s BLAKE3 loop over backends done at process level. Its
  early `return` when the executor is unavailable is the degraded-environment pass that
  Sparkles' `skipTest` rule forbids. Tolerant comparison with a stated threshold and
  external reference decoders (ImageMagick, GDI+) is the oracle shape
  [baseline][bl-existing] G11 lacks; ImageSharp keeps fuzzer finds as named regression
  files rather than running a fuzzer in CI.
- **Q9.** ImageSharp's project builds codecs, processors and colour management into
  one assembly and declares trimming support (`IsTrimmable`,
  [`ImageSharp.csproj`][csproj]). Its layering (pixels, memory, formats, processing)
  is by namespace, not by package. The default configuration registers every format,
  and its constructors explicitly root bulk-operation seeds. No trimmed application
  was built here, so this establishes a single-package design, not that unused codecs
  disappear or that a D linker would achieve the same result.

## Strengths

- **One static pixel type parameter throughout**, with static abstract members giving
  template-like calls, so codecs and processors compile per pixel type.
- **Typed alpha representation** and premultiplied pixel variants, with conversions
  inserted automatically.
- **Broad managed codec set** (fourteen format modules, including HEIF/AVIF and EXR)
  with no native codec dependency and a multi-platform CI configuration.
- **Pooled, limit-enforcing allocator** with row-aligned discontiguous groups that avoid
  very large single allocations.
- **`Identify` without decoding** and a format-connecting metadata layer that carries
  quality, loop count and frame timing across formats.
- **ISA-tier testing** that runs the same tests with intrinsics disabled.

## Weaknesses

- **No planes, no subsampling, no tiles, no N-D**: only interleaved 2-D frames reach the
  public API.
- **Synchronous, whole-image decoding**; the async API buffers streams other than the
  two known memory-stream types, and PNG's non-generic path parses headers twice.
- **Eager processor pipeline** with no fusion; colour filters make a separate
  `Vector4` round trip, while other processors can work directly on pixels.
- **No general work-budget option** or width, height or pixel-count option;
  controls include allocation bytes, `MaxFrames` and cancellation.
- **Padded strides only for single-buffer images**, and contiguity is a fallible query,
  which complicates zero-copy interop.
- **Manual AOT inventories** for selected built-in pixel types and operations;
  code-size growth was not measured.
- **Colour space is metadata**, not part of the pixel type; HDR values and metadata
  are supported, but no gain-map API was found.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                              | Trade-off                                                                              |
| ------------------------------------------------------------ | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `Image<TPixel>` with `TPixel : unmanaged, IPixel<TPixel>`    | Per-type compiled code; pixels reinterpretable as bytes                | AOT uses explicit inventories; resulting code size needs measurement                   |
| `Vector4` as the universal intermediate                      | Every type converts to every other through common conversion functions | Colour filters pay a per-row float round trip; direct pixel operations need not        |
| Virtual `PixelOperations<TPixel>` singleton with overrides   | Fast paths for common types without changing callers                   | Virtual dispatch per bulk call; no compile-time knowledge of which paths are fast      |
| Row-aligned discontiguous `MemoryGroup<T>`                   | Large images without huge allocations; pooled 4 MiB blocks             | Whole-image contiguity and padded strides are conditional; GPU and interop must check  |
| Limits as allocator byte caps (4 GiB group, 1 GiB buffer)    | Common allocation-budget mechanism                                     | A group cap is per allocation, not all animation frames; no general work-budget option |
| PNG identifies, then switches to a closed pixel-type set     | Run-time format to compile-time type with bounded output choices       | PNG headers parsed twice; other codecs can choose a fixed type without identifying     |
| Eager `Mutate` / `Clone` contexts with `IImageProcessor`     | Simple mental model; each processor self-contained                     | No fusion or graph; traversal and scratch depend on the processor                      |
| Async decode buffers unknown stream types                    | Avoids synchronous external reads without rewriting decoders           | Extra memory proportional to remaining input; no I/O/decode overlap on this path       |
| `SegmentIntegrityHandling` policy; CRC checks by criticality | Tolerates damaged metadata by default; strict mode available           | Default skips ancillary CRC checks; behaviour differs by mode                          |

---

## Sources

- [SixLabors/ImageSharp repository][repo] · [documentation][docs] · [samples][samples]
- [`src/ImageSharp/PixelFormats/IPixel.cs` — `IPixel<TSelf>`, static abstract members][ipixel]
- [`src/ImageSharp/PixelFormats/PixelOperations{TPixel}.cs` — bulk conversion shell][pixops-head]
- [`src/ImageSharp/PixelFormats/PixelTypeInfo.cs` and `PixelAlphaRepresentation.cs`][pti]
- [`src/ImageSharp/PixelFormats/PixelImplementations/Rgba32.cs` and its pixel operations][rgba32]
- [`src/ImageSharp/Memory/Buffer2D{T}.cs` — 2-D buffer, stride, row spans][buffer2d]
- [`src/ImageSharp/Memory/DiscontiguousBuffers/MemoryGroup{T}.cs` — row-aligned groups][memgroup-alloc]
- [`src/ImageSharp/Memory/Allocators/MemoryAllocator.cs` — limits][allocator-limits]
- [`src/ImageSharp/Memory/Allocators/UniformUnmanagedMemoryPoolMemoryAllocator.cs` — pool][uumpa]
- [`src/ImageSharp/Configuration.cs` — modules, parallelism, contiguity][configuration]
- [`src/ImageSharp/Advanced/AotCompilerTools.cs` — AOT instantiation seeding][aot]
- [`src/ImageSharp/Formats/IImageDecoder.cs`, `ImageDecoder.cs`, `ImageDecoderCore.cs`, `DecoderOptions.cs`][idecoder]
- [`src/ImageSharp/Formats/Png/PngDecoder.cs` and `PngDecoderCore.cs`][pngdecoder]
- [`src/ImageSharp/Processing/DefaultImageProcessorContext{TPixel}.cs` — eager pipeline][context]
- [`src/ImageSharp/Advanced/ParallelRowIterator.cs` — row bands][rowiter]
- [`src/ImageSharp/Common/Helpers/SimdUtils.HwIntrinsics.cs` — ISA kernels][simd-hw]
- [`src/ImageSharp/Metadata/ImageMetadata.cs` and `Profiles/CICP/CicpProfile.cs`][imagemeta]
- [`tests/ImageSharp.Tests/TestUtilities/FeatureTesting/FeatureTestRunner.cs`][feature]
- [`tests/ImageSharp.Tests/TestUtilities/ImageComparison/TolerantImageComparer.cs`][tolerant]
- [`.github/workflows/build-and-test.yml` — CI matrix][ci]
- [Microsoft: hardware intrinsics and JIT folding of `IsSupported`][dotnet-intrinsics]
- Related in this survey: [Concepts][concepts] · [Boost.GIL][gil] · [VIGRA][vigra] ·
  [Halide][halide] · [JuliaImages][julia] · [mir-algorithm][mir] · [Colour][colour] ·
  [ae.utils.graphics][ae] · [DCV][dcv] · [Generic image programming papers][p-generic] ·
  [Hostile-input papers][p-hostile]
- Sparkles baseline: [existing image code][bl-existing] · [shaders and host SIMD][bl-shaders] ·
  [event-horizon][bl-eh]

<!-- References -->

[repo]: https://github.com/SixLabors/ImageSharp
[docs]: https://sixlabors.github.io/docs/
[samples]: https://github.com/SixLabors/Samples
[license]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/LICENSE#L1-L43
[readme]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/README.md#L18
[pf-readme]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/README.md#L1-L6
[png-cancel]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L1016-L1022
[security]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/SECURITY.md#L1-L14
[csproj]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/ImageSharp.csproj#L13-L42
[ci]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/.github/workflows/build-and-test.yml#L62-L112
[ci-gdi]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/.github/workflows/build-and-test.yml#L115-L131
[ipixel]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/IPixel.cs#L8-L16
[ipixel-static]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/IPixel.cs#L14-L220
[pti]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelTypeInfo.cs#L6-L63
[alpha]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelAlphaRepresentation.cs#L9-L31
[rgba32]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelImplementations/Rgba32.cs#L13-L45
[rgba32-info]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelImplementations/Rgba32.cs#L226-L233
[rgbavector]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelImplementations/RgbaVector.cs#L11-L163
[pixops-head]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelOperations%7BTPixel%7D.cs#L14-L32
[pixops-from]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelOperations%7BTPixel%7D.cs#L378-L432
[pixops-to]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelOperations%7BTPixel%7D.cs#L442-L459
[pixops-gen]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelOperations%7BTPixel%7D.Generated.cs#L10-L29
[rgba32-ops]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelImplementations/PixelOperations/Rgba32.PixelOperations.cs#L18-L64
[rgba32-gen]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelFormats/PixelImplementations/PixelOperations/Generated/Rgba32.PixelOperations.Generated.cs#L41-L53
[buffer2d]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Buffer2D%7BT%7D.cs#L9-L86
[buffer2d-single]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Buffer2D%7BT%7D.cs#L175-L186
[buffer2d-row]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Buffer2D%7BT%7D.cs#L292-L307
[memgroup-alloc]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/DiscontiguousBuffers/MemoryGroup%7BT%7D.cs#L99-L156
[allocator-limits]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Allocators/MemoryAllocator.cs#L14-L91
[allocator-create]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Allocators/MemoryAllocator.cs#L100-L115
[allocator-group]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Allocators/MemoryAllocator.cs#L221-L236
[allocate2d]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/MemoryAllocatorExtensions.cs#L24-L48
[uumpa]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Allocators/UniformUnmanagedMemoryPoolMemoryAllocator.cs#L9-L145
[uumpa-pool]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Memory/Allocators/UniformUnmanagedMemoryPoolMemoryAllocator.cs#L149-L160
[configuration]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Configuration.cs#L31-L168
[configuration-default]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Configuration.cs#L233-L247
[aot]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Advanced/AotCompilerTools.cs#L42-L128
[aot-modern]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Advanced/AotCompilerTools.cs#L134-L245
[formatmanager]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/ImageFormatManager.cs#L14-L216
[detect-read]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Image.Decode.cs#L49-L78
[detect-dispatch]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Image.Decode.cs#L124-L137
[detector]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/IImageFormatDetector.cs#L11-L26
[idecoder]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/IImageDecoder.cs#L11-L73
[decoder-async]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/ImageDecoder.cs#L186-L296
[decoder-icc]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/ImageDecoder.cs#L325-L355
[decodercore]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/ImageDecoderCore.cs#L112-L198
[decodercore-segments]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/ImageDecoderCore.cs#L40-L102
[decodercore-icc]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/ImageDecoderCore.cs#L200-L235
[decoderoptions]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/DecoderOptions.cs#L11-L109
[sih]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/SegmentIntegrityHandling.cs#L6-L26
[pngdecoder]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoder.cs#L46-L101
[png-options]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderOptions.cs#L14-L18
[png-decompress]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L1970-L2023
[png-text]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L1548-L1585
[png-itxt]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L2147-L2183
[png-chunkdata]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L2518-L2544
[png-critical]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngChunk.cs#L45-L52
[png-crc]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L2463-L2484
[png-cicp]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L1621-L1647
[png-icc]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Png/PngDecoderCore.cs#L331-L338
[jpegdecoder]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Jpeg/JpegDecoder.cs#L32-L51
[jpeg-spectral]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Jpeg/JpegDecoderCore.cs#L203-L203
[jpeg-scale]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Jpeg/Components/Decoder/SpectralConverter%7BTPixel%7D.cs#L224-L289
[gif-compose]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Gif/GifDecoderCore.cs#L657-L718
[iprocessor]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Processing/Processors/IImageProcessor.cs#L8-L29
[context]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Processing/DefaultImageProcessorContext%7BTPixel%7D.cs#L63-L91
[improc]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Processing/Processors/ImageProcessor%7BTPixel%7D.cs#L46-L67
[filter]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Processing/Processors/Filters/FilterProcessor%7BTPixel%7D.cs#L33-L86
[flip]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Processing/Processors/Transforms/Linear/FlipProcessor%7BTPixel%7D.cs#L85-L130
[rowiter]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Advanced/ParallelRowIterator.cs#L86-L164
[rowiter-wrapper]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Advanced/ParallelRowIterator.Wrappers.cs#L88-L107
[rowiter-steps]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Advanced/ParallelRowIterator.cs#L289-L300
[parsettings]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Advanced/ParallelExecutionSettings.cs#L14-L16
[simd-convert]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Common/Helpers/SimdUtils.Convert.cs#L11-L97
[simd-hw]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Common/Helpers/SimdUtils.HwIntrinsics.cs#L650-L832
[imagemeta]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Metadata/ImageMetadata.cs#L142-L172
[imagemeta-format]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Metadata/ImageMetadata.cs#L185-L208
[fcm]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/FormatConnectingMetadata.cs#L8-L65
[fcfm]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/FormatConnectingFrameMetadata.cs#L16-L48
[cicp]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Metadata/Profiles/CICP/CicpProfile.cs#L26-L32
[heif-float]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Heif/Components/ColorConverters/HeifPlanarColorConverter.cs#L712-L724
[heif-metadata]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Heif/HeifMetadata.cs#L74-L108
[heif-times]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Heif/HeifSequenceParser.cs#L1988-L2005
[heif-frame]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Formats/Heif/HeifFrameMetadata.cs#L27-L57
[exif]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Metadata/Profiles/Exif/ExifProfile.cs#L14-L122
[framecoll]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/ImageFrameCollection%7BTPixel%7D.cs#L391-L410
[processrows]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Image%7BTPixel%7D.cs#L213-L231
[accessor]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/PixelAccessor%7BTPixel%7D.cs#L41-L45
[wrapmemory]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Image.WrapMemory.cs#L517-L569
[wrapmemory-owner]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Image.WrapMemory.cs#L146-L175
[wrapmemory-borrow]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/src/ImageSharp/Image.WrapMemory.cs#L18-L59
[tests-csproj]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/tests/ImageSharp.Tests/ImageSharp.Tests.csproj#L45-L52
[tolerant]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/tests/ImageSharp.Tests/TestUtilities/ImageComparison/TolerantImageComparer.cs#L10-L120
[feature]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/tests/ImageSharp.Tests/TestUtilities/FeatureTesting/FeatureTestRunner.cs#L52-L80
[jpeg-fuzz]: https://github.com/SixLabors/ImageSharp/blob/b2b1ca9bda8b6b2cdd748b001f59b533f36da4db/tests/ImageSharp.Tests/Formats/Jpg/JpegDecoderTests.Images.cs#L14-L74
[dotnet-intrinsics]: https://devblogs.microsoft.com/dotnet/hardware-intrinsics-in-net-core/
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-view]: ./concepts.md#image-and-view
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-suspend]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[gil]: ./boost-gil.md
[vigra]: ./vigra.md
[halide]: ./halide.md
[julia]: ./juliaimages.md
[mir]: ./mir-algorithm/index.md
[colour]: ./color.md
[ae]: ./ae-graphics.md
[dcv]: ./dcv.md
[p-generic]: ./papers/generic-image-programming.md
[p-hostile]: ./papers/hostile-input-safety.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[analysis-genericity]: #_2-genericity-mechanism
