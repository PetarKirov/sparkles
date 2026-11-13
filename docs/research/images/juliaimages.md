# JuliaImages: ImageCore, ColorTypes, FixedPointNumbers (Julia)

A family of small Julia packages in which an image is any `AbstractArray` whose element type is a colour: the pixel type, not an image header, carries meaning, and conversions between representations are zero-copy views chosen by multiple dispatch.

| Field         | Value                                                                                                                                                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Julia (compat floor `julia = "1.6"` in [`ImageCore/Project.toml`][ic-project])                                                                                                                                              |
| License       | MIT ("Expat") for ImageCore, ColorTypes, Images and FixedPointNumbers                                                                                                                                                       |
| Repository    | [ImageCore.jl][ic-repo], [ColorTypes.jl][ct-repo], [Images.jl][img-repo]; read alongside [FixedPointNumbers.jl][fpn-repo], [ImageAxes.jl][ia-repo], [ImageIO.jl][iio-repo], [FileIO.jl][fio-repo], [PNGFiles.jl][png-repo]  |
| Revision read | ImageCore `c3f8157040464b8ddffd18ffadff35c599f9e516` (v0.10.5); ColorTypes `59a21eb2307a63ac8194fd15d1f7458239cc8cd7` (v0.12.4); Images `955de10ba2a1ef502f52c165f32ff7b67d97ef6b` (v0.26.2); others in [Sources](#sources) |
| Documentation | [juliaimages.org][ji-site] (source [`juliaimages.github.io`][ji-src] at `61cf1d95a6a95aab78f09a762605d85b0273d91a`); [ImageCore docs][ic-docs-site]                                                                         |
| Category      | Generic libraries                                                                                                                                                                                                           |
| Tier          | A                                                                                                                                                                                                                           |
| Last reviewed | November 7, 2026                                                                                                                                                                                                            |

> [!NOTE]
> FixedPointNumbers, ImageAxes, ImageIO, FileIO, PNGFiles, ColorVectorSpace and the
> documentation repository are not in the catalog's clone set. They were cloned
> shallowly into a scratch directory at the upstream commits in [Sources](#sources);
> every cited path was checked with `git cat-file -e`. FixedPointNumbers is cited at
> tag `v0.8.6`, which `FixedPointNumbers = "0.8"` in ImageCore's compat resolves to; its
> default branch (`v0.9.3`) has different arithmetic (see
> [Hostile input](#_5-hostile-input-and-safety)).

---

## Overview

### What it solves

Image libraries usually define an image class: a header (width, height, format, colour
space) plus a buffer. JuliaImages defines none. The quickstart says so
([`quickstart.md`][ji-qs-array]):

> For most purposes, any `AbstractArray` can be treated as an image. For example, numeric array can be interpreted as a grayscale image.

and the arrays tutorial ([`arrays_colors.md`][ji-ac-array]): _"In Julia, an image is just
an array, and many of the ways you manipulate images come from the general methods to
work with multidimensional arrays."_

What a header would hold moves into the **element type**. ColorTypes supplies colour
types (`Gray{T}`, `RGB{T}`, `BGR{T}`, `RGBA{T}`, `HSV{T}`, `Lab{T}`, `XYZ{T}` and about
twenty more, most with alpha-first and alpha-last variants); FixedPointNumbers supplies
sample types (`N0f8`, `N0f16`, `N4f12`, …) that let an 8-, 12- or 16-bit integer mean a
value on the 0 to 1 scale; ImageCore supplies views that reinterpret one array as
another without copying (`channelview`, `colorview`, `rawview`, `normedview`) and traits
(`pixelspacing`, `coords_spatial`, `nimages`) with trivial defaults for a plain `Array`.
Meaning that does not fit an element type (physical spacing, a time axis, a metadata
dictionary) goes into wrappers: ImageAxes over [AxisArrays][axisarrays], and
ImageMetadata. Files are reached through FileIO, which detects a format by magic bytes
and extension and dispatches to a backend such as PNGFiles. Images.jl is now an
umbrella that re-exports about fifteen of these packages ([`src/Images.jl`][img-umbrella]).

### Design philosophy

ImageCore states its role as conversion, not algorithms ([`docs/src/index.md`][ic-docs-index]):

> ImageCore is the lowest-level component of the system of packages designed to support image processing and computer vision. Its main role is to simplify "conversions" between different image representations through different "view" types, and to provide some useful low-level functions (including "traits") that simplify image display, input/output, and the writing of algorithms.

and defines a view as shared storage ([`docs/src/views.md`][ic-docs-views]): _"a view is
an *interpretation* of array data, one that may change the apparent meaning of the array
but which shares the same underlying storage: change an element of the view, and you
also change the original array."_ Four rules follow:

1. **One scale.** _"This strategy ensures that `1` always means "saturated color",
   regardless of whether that value is represented as a `Float64` or with just 8 bits.
   (In the context of image-processing, this unifies "integer images" and
   "floating-point images" in a common scale.)"_ ([ColorTypes `README.md`][ct-readme-n0f8])
2. **Constructor order is not memory order.** _"for all `AbstractRGB` types, the
   constructor accepts values in the order `(r,g,b)` regardless of how they are arranged
   internally in memory"_ ([`README.md`][ct-readme-bgr]), so generic code over
   `C<:Colorant` never asks whether `C` is `RGB` or `BGR`.
3. **Types without arithmetic.** ColorTypes defines no `+`; the opt-in ColorVectorSpace
   does, and says why ([`README.md`][cvs-readme]): _"Colorspaces such as RGB, unlike XYZ,
   are technically non-linear … However, particularly in image processing it is common
   to ignore this concern, and for the sake of performance treat an RGB as if it were a
   3-vector."_
4. **Fixed-point is storage.** _"it may make most sense to think of `FixedPoint` numbers
   as *storage types* rather than computational types"_ ([FixedPointNumbers
   `README.md`][fpn-storage]).

The language mechanism underneath, code selection by multiple dispatch with
per-signature specialisation, is the Bezanson et al. 2017 entry in the
[generic image programming thread][p-generic].

---

## How it works

### The `Colorant` hierarchy

Every colour type is a subtype of `Colorant{T,N}`, `T` the sample type and `N` the
number of meaningful components ([`src/types.jl`][ct-colorant]). Concrete types are plain
immutable structs whose field order is the memory layout and whose inner constructor
fixes the argument order ([`types.jl`][ct-rgb]):

```julia
# ColorTypes.jl/src/types.jl (abridged; docstrings removed)
abstract type Colorant{T,N} end
abstract type Color{T, N} <: Colorant{T,N} end
abstract type AbstractGray{T} <: Color{T,1} end
abstract type AbstractRGB{T} <: Color{T,3} end
abstract type TransparentColor{C<:Color,T,N} <: Colorant{T,N} end
abstract type AlphaColor{C<:Color,T,N} <: TransparentColor{C,T,N} end   # alpha stored first
abstract type ColorAlpha{C<:Color,T,N} <: TransparentColor{C,T,N} end   # alpha stored last

struct BGR{T<:Fractional} <: AbstractRGB{T}
    b::T
    g::T
    r::T
    BGR{T}(r::T, g::T, b::T) where {T <: Fractional} = new{T}(b, g, r)
end
```

Aliases re-cut the abstract types by arity (`Color3{T} = Color{T,3}`,
`TransparentRGB{C<:AbstractRGB,T} = TransparentColor{C,T,4}`,
`ColorantNormed{T<:Normed,N} = Colorant{T,N}`), so a method can target "any
three-component colour" or "any colour with `Normed` samples" ([`types.jl`][ct-aliases]).
`Fractional` is `Union{AbstractFloat, FixedPoint}` ([`ColorTypes.jl`][ct-fractional]), so
`RGB{UInt8}` cannot exist. `XRGB`/`RGBX` add a padding field; `RGB24`, `ARGB32`, `Gray24`
and `AGray32` pack into one `UInt32` (`0xAARRGGBB`) for Cairo-style interop
([`types.jl`][ct-argb32]). HSV, Lab, XYZ and the other non-RGB spaces require
`T<:AbstractFloat`. Transparent types are generated: the `make_alpha` macro emits an
alpha-first and an alpha-last struct per opaque type, both taking alpha as the last
constructor argument, and registers them with the `alphacolor`/`coloralpha` traits
([`types.jl`][ct-make-alpha]); the twenty pairs (`RGB → ARGB/RGBA`, `BGR → ABGR/BGRA`,
`Lab → ALab/LabA`, …) are listed explicitly ([`types.jl`][ct-alpha-list]).

### `Normed`: integers on a 0 to 1 scale

`Normed{T<:Unsigned,f}` wraps one unsigned integer and divides by `2^f - 1`, not `2^f`,
so the all-ones pattern is exactly `1.0` ([`normed.jl`][fpn-struct],
[`README.md`][fpn-normed-doc]):

```julia
# FixedPointNumbers.jl/src/normed.jl @ v0.8.6
struct Normed{T <: Unsigned, f} <: FixedPoint{T, f}
    i::T
    function Normed{T, f}(i::Integer, _) where {T, f}
        1 <= f <= bitwidth(T) || throw(DomainError(f, "f must be between 1 and $(bitwidth(T)) (i.e. the number of bits of `T=$T`)"))
        new{T, f}(i % T)
    end
end
```

`N0f8` is `Normed{UInt8,8}`; `N4f12` is a 12-bit camera sample in a `UInt16` that reaches
`1.0` at `0x0fff`. A 12-bit and a 16-bit image are different types with the same
meaning for `1.0`, so combining them is a promotion, not a reinterpretation of 4095 as
dim grey. The quickstart's rationale ([`quickstart.md`][ji-qs-n0f8]): 0 is black and 1
white _"even for intensities encoded as 8-bit integers"_, because `N0f8` _"interprets an
8-bit "integer" as if it had been scaled by 1/255"_.

### Views

The views are thin layers over Base's `reinterpret(reshape, …)` (`Base.ReinterpretArray`)
and `MappedArrays.mappedarray`. `channelview`'s method ladder picks the cheapest form per
type ([`src/colorchannels.jl`][ic-chan]):

```julia
# ImageCore.jl/src/colorchannels.jl (abridged; trailing comments added)
channelview(A::AbstractArray{T}) where {T<:Number} = A                     # already numeric
channelview(A::RRArray{<:Colorant,<:Number}) = parent(A)                   # undo a colorview
channelview(A::AbstractArray{RGB{T}}) where {T} = reinterpretc(T, A)       # pure reinterpret
function channelview(A::AbstractArray{C}) where {C<:AbstractRGB}
    # BGR, XRGB, etc don't satisfy conditions for reinterpret
    CRGB = RGB{eltype(C)}
    channelview(of_eltype(CRGB, A))                                        # per-element mapping
end
channelview(A::AbstractArray{C}) where {C<:Color} = reinterpretc(eltype(C), A)
```

- **Reinterpretation.** `RGB{T}` and non-RGB colours become an array with a new leading
  channel dimension (`reinterpretc`, [`convert_reinterpret.jl`][ic-reinterpretc]).
- **Unwrapping.** `channelview(colorview(C, A))` returns `A`: methods match the type
  parameters of the wrapper (`RRArray`, `RRPermArray`), so composed views do not stack.
- **Mapping where memory order differs from constructor order.** `BGR`, `XRGB`, `ARGB`
  go through `of_eltype`, a `MappedArray` converting each element to `RGB` on read and
  back on write. The docstring: _"the channels of the returned array will be in
  constructor-argument order, not memory order (see `reinterpretc` if you want to use
  memory order)"_. In the other direction `colorview` reorders with a `ColorChanPerm`,
  for example `dimorder(::Type{<:BGR}) = ColorChanPerm((3, 2, 1))`
  ([`colorchannels.jl`][ic-dimorder]).

`colorview(C, A)` is the inverse; `colorview(C, gray1, gray2, …)` builds a
`MultiMappedArray` over separate planes (`StackedView`'s machinery,
[`stackedviews.jl`][ic-stacked]). `rawview` and `normedview` switch `N0f8` and `UInt8`
element types, reinterpreting a plain `Array` and wrapping anything else in a
bidirectional `MappedArray` ([`src/ImageCore.jl`][ic-raw]):

```julia
# ImageCore.jl/src/ImageCore.jl
rawview(a::AbstractArray{T}) where {T<:FixedPoint} = mappedarray(reinterpret, y->T(y,0), a)
rawview(a::Array{T}) where {T<:FixedPoint} = reinterpret(FixedPointNumbers.rawtype(T), a)
normedview(::Type{T}, a::AbstractArray{S}) where {T<:FixedPoint,S<:Unsigned} = mappedarray(y->T(y,0),reinterpret, a)
normedview(::Type{T}, a::Array{S}) where {T<:FixedPoint,S<:Unsigned} = reinterpret(T, a)
```

Channel-last layouts come from Base's lazy, writable `PermutedDimsArray`; ImageCore's docs
walk through a write via `rawview`, `channelview` and `PermutedDimsArray(v, (2,3,1))`
reaching the original ([`views.md`][ic-docs-views-perm]). Conversions that copy
(`float32.(img)`, `n0f8.(img)`) are generated in a loop over sample types
([`convert_reinterpret.jl`][ic-convert]). The traits `pixelspacing`, `coords_spatial` and
`nimages` default to `(1, 1, …)`, all axes and `1`, and forward through `MappedArray`,
`OffsetArray`, `SubArray` and `PermutedDimsArray` (permuting the answer for the last);
`spatialorder` has only forwarding methods in ImageCore, no plain-array default
([`traits.jl`][ic-traits]). ImageAxes overrides them for `AxisArray`, deriving
spacing from axis ranges (possibly `Unitful`, such as `1mm:1mm:8mm`) and time from an axis
named `:time` ([`ImageAxes.jl`][ia-traits], [axes docs][ji-axes]).

### Format dispatch through FileIO

FileIO maps each format to a type-level tag, `DataFormat{sym}`, registered with magic
bytes, extensions and an ordered list of backends ([`registry.jl`][fio-png]). `load` tries
the backends in order, loading each at run time with `Base.require`, calling its
`fileio_load` or `load` through `Base.invokelatest`, and moving on after **any**
exception ([`loadsave.jl`][fio-action]):

```julia
# FileIO.jl/src/registry.jl
add_format(format"PNG", UInt8[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a], ".png",
           [idImageIO], [idImageMagick], [idOpenCV], [MimeWriter, SAVE])

# FileIO.jl/src/loadsave.jl — action (abridged)
for library in libraries
    try
        mod = isa(library, Module) ? library : lock(() -> Base.require(library), require_lock)
        f = isdefined(mod, pkgfuncname) ? getfield(mod, pkgfuncname) : getfield(mod, call)
        return Base.invokelatest(f, file, args...; options...)
    catch e
        push!(failures, (e, library, catch_backtrace()))
    end
end
```

ImageIO, the first image backend, defers loading each codec wrapper until first use
(`@lazy import PNGFiles = "…"`, [`ImageIO.jl`][iio-lazy]), defines `load` methods for the
`File` type parameterised by each `DataFormat`, and canonicalises results to `Array` or
`IndirectArray` (paletted PNG), copying when needed. Its comment names the dynamic
boundary ([`ImageIO.jl`][iio-canonical]): _"This may not be type stable if `AT` is not a
concrete type, but it's not an issue for `load`; it can never be type stable."_

### Verified behaviour

Run, not read: Julia 1.12.4 (nixpkgs `julia-bin`) in a scratch depot, with ImageCore
0.10.5, ColorTypes 0.12.4, FixedPointNumbers 0.8.6 and ColorVectorSpace 0.11.2, the
versions the resolver chose. Output lines, verbatim except where `…` shortens a type:

```text
1 N0f8(0.8)+N0f8(0.8) = 0.596N0f8 raw=0xcc float(x)+x=1.6
2 N4f12(15)*N4f12(15) throws ArgumentError
3 sizeof RGB{N0f8}=3 RGBA{N0f8}=4 RGB{Float32}=12 isbits=true
4 size(img)=(2, 3) size(channelview)=(3, 2, 3) typeof=Base.ReinterpretArray{N0f8, 3, RGB{N0f8}, Matrix{RGB{N0f8}}, true}
  strides(channelview)=(1, 3, 6)
5 after rawview write img[1,1]=RGB{N0f8}(1.0, 0.0, 0.502) eltype(rawview)=UInt8
6 colorview(RGB, channelview(img)) === img: true
7 after PermutedDimsArray write img[2,2]=RGB{N0f8}(0.251, 0.251, 0.251) size(p)=(2, 3, 3)
8 BGR red: channelview=(1.0N0f8, 0.0N0f8, 0.0N0f8) reinterpretc(memory)=(0.0N0f8, 0.0N0f8, 1.0N0f8) typeof(channelview)=Base.ReinterpretArray{N0f8, 2, RGB{N0f8}, MappedArrays.MappedArray{…}, true}
9 RGB(255,0,0) throws ArgumentError: ArgumentError: The components of RGB are normalized to the range 0-1,
10 Gray{N0f8}+Gray{N0f8} = Gray{N0f8}(0.596) ; RGB{N0f8} sum type=RGB{N0f8}
13 specializations of mysum compiled: 4
14 premultiplied type in ColorTypes? false ; linear RGB type? false
15 planar colorview typeof=MappedArrays.MultiMappedArray{RGB{N0f8}, 2, Tuple{Matrix{N0f8}, Matrix{N0f8}, Matrix{N0f8}}, …}
   write-through planar r[1,1]=0.0N0f8
16 inferred return type of decode(::Int) = Union{Matrix{Gray{N0f8}}, Matrix{RGB{N0f8}}, Matrix{RGBA{N0f16}}}
19 colorview(RGB, 4x4x4) throws ArgumentError: ArgumentError: `reinterpret(reshape, RGB{Float32}, a)` where `eltype(a)` is Float32 requires that `axes(a, 1)` (got Base.OneTo(4)) be equal to 1:3 (from the ratio of element sizes)
```

Line 13 counts the specialisations compiled for one generic `mysum(A)` after calls with
`Gray{N0f8}`, `Gray{N0f16}`, `Gray{Float32}` and `RGB{N0f8}` matrices: one per element
type, as D template instantiation would give. Line 16 is a function whose output pixel
type depends on a run-time value, the shape of a decoder result. A warmed-up `sum` over
a `channelview` also allocated 0 bytes (`@allocated`). Line 1's `raw` is the operand's bit
pattern (`0xcc`, 204); the sum's is `0x98` (408 mod 256 = 152), as a verification rerun
printed.

---

## Analysis

### 1. Pixel and memory model

Julia's `Array`: dense, **column-major** (first index fastest), 1-based by default, with
arbitrary index ranges through OffsetArrays. Images are indexed `img[row, col]`. A colour
image is an array of packed pixel structs (`RGB{N0f8}` is 3 bytes, line 3), interleaved
in memory; `channelview` exposes it as `3 × h × w` with strides `(1, 3, 6)` for a 2 × 3
image (line 4). Channel first in index order is channel fastest in memory: the bytes a
row-major library calls HWC. The quickstart justifies the order by column-major access
([`quickstart.md`][ji-qs-chw]). Strides and sub-images are Base's (`view`, `SubArray`,
`strides`). Planar images are a `MultiMappedArray` over separate planes: zero-copy and
writable (line 15), but not strided. N-D is native; traits say which axes are spatial.

Absent: chroma-subsampled planes (`YCbCr{T}` is a per-pixel colour, so 4:2:0 has no
representation besides arrays of different sizes), tiles, and row padding inside a
view: `reinterpret(reshape, …)` requires the channel extent to equal the size ratio
exactly (line 19).

### 2. Genericity mechanism

Multiple dispatch over all argument types, with parametric types and type-level values
(`Val(N)`, `DataFormat{:PNG}`), resolved statically when types are inferred and at run
time otherwise; each concrete signature is compiled separately (line 13).

- **Method ladders.** `channelview` chooses reinterpretation, unwrapping or mapping by
  specificity. D writes the same ladder as constrained overloads or a `static if` chain.
- **Matching on wrapper parameters.** Unwrapping dispatches on
  `Base.ReinterpretArray{To,M,From,P,true}`; D's `is` expression destructures a template
  instance the same way.
- **Open extension across packages.** ImageCore adds methods to functions other packages
  own, `PaddedViews.filltype` and `MosaicViews.promote_wrapped_type`
  ([`ImageCore.jl`][ic-filltype]), and registers a `MethodError` hint for `fft` on colour
  arrays ([`ImageCore.jl`][ic-ffthint]). D has no equivalent; a generic function sees
  only its imports, and the substitute is a hook found by introspection on the type
  (the shell with hooks of the [design-by-introspection guidelines][dbi]).
- **Holy traits.** `HasDimNames{true}()`/`HasDimNames{false}()` in ImageCore and
  `TimeAxis`/`HasTimeAxis` through SimpleTraits in ImageAxes are singleton types returned
  by a function and dispatched on ([`traits.jl`][ic-hasdimnames], [`ImageAxes.jl`][ia-timeaxis]).
  D uses `enum bool` traits.
- **Generated families.** `@eval` loops and `@generated` functions (`make_alpha`, the
  `float32`/`n0f8` family) correspond to D's `mixin` and `static foreach`.

### 3. Colour and metadata

Space and range are in the type: `RGB` is documented as sRGB ([`types.jl`][ct-rgb]),
`XYZ` and `LMS` as linear ([`types.jl`][ct-xyz], [`types.jl`][ct-lms]), and `Lab`, `Luv`,
`Oklab` and DIN99 by name and component ranges; conversions live in Colors.jl (not read
here). Mixed arguments promote (`promote_args_type`, with
`eltype_default` giving `N0f8` for RGB and grey, `Float32` otherwise,
[`types.jl`][ct-eltype-default]).

Not in the type (line 14 and a reading of `types.jl`): a linear-RGB type distinct from
sRGB `RGB`, any transfer-function or primaries parameter, premultiplied alpha (`RGBA` and
`ARGB` differ only in storage order), a white-point parameter on `Lab`/`XYZ`, ICC, CICP
or HDR. ColorVectorSpace performs arithmetic on encoded values by design.

Decoders compensate invisibly. PNGFiles gamma-corrects by default ([`io.jl`][png-gamma]):
_"By default, gamma correction is applied according to a `gAMA` or `sRGB` chunks, if
present; if neither chunk is present a value of `0.45455` for the file gamma is assumed.
Screen gamma is currently always assumed to be `2.2`."_ The returned `RGB{N0f8}` holds
values transformed towards an assumed display, unrecorded. Non-colour metadata is a
property dictionary in an `ImageMeta` wrapper ([metadata docs][ji-meta]); no typed EXIF or
XMP model appears in the packages read.

### 4. I/O and codec architecture

FileIO is registry and dispatcher (magic bytes or a detector such as `detect_riff`,
extensions, ordered backends, run-time loading, first success wins); it also names
`loadstreaming`/`savestreaming` actions for formats that implement them. ImageIO binds
image formats to codec packages, mostly C wrappers (PNGFiles over libpng, JpegTurbo,
OpenEXR, WebP) and some pure Julia (Netpbm, QOI, TiffImages) ([`README.md`][iio-readme]).

The image path is whole-file pull. PNGFiles reads the header, allocates `width × height`,
decodes with `png_read_image`, then copies with `permutedims` to turn libpng's rows into
a column-major matrix ([`io.jl`][png-load-bang]):

```julia
# PNGFiles.jl/src/io.jl
function _load!(buffer::Matrix{T}, png_ptr, info_ptr) where T    # separate to support precompilation of permutedims
    png_read_image(png_ptr, map(a -> Ptr{UInt8}(pointer(a)), eachcol(buffer)))
    png_read_end(png_ptr, info_ptr)
    png_destroy_read_struct(Ref{Ptr{Cvoid}}(png_ptr), Ref{Ptr{Cvoid}}(info_ptr), C_NULL)
    return permutedims(buffer, (2, 1))
end
```

ImageIO's `load` has no incremental feed, row callback or suspension. The only lazy path
is `mmap=true`/`lazyio=true` for TIFF, which also skips canonicalisation
([`README.md`][iio-canon-readme]). The result type is known only at run time (line 16's
`Union`); Julia pays one dynamic call, then runs specialised code (the "function
barrier").

### 5. Hostile input and safety

Arrays are bounds-checked unless code opts out with `@inbounds`. ImageCore uses
`@inbounds` in `getchannels`/`setchannels!` after constructors validated the channel
dimension (`checkdim1`, `check_ncolorchan`, [`colorchannels.jl`][ic-checks]; `StackedView`
checks that planes share indices, [`stackedviews.jl`][ic-stacked]); bad shapes raise
`DimensionMismatch` or `ArgumentError` at construction (line 19).

Colour construction is checked: `RGB(255, 0, 0)` throws with a message suggesting `/255`
([`types.jl`][ct-colorerror], line 9). Arithmetic is not. At v0.8.6, `+` and `-` wrap
like the raw integer ([`FixedPointNumbers.jl`][fpn-addsub]), so `N0f8(0.8) + N0f8(0.8)`
is `0.596`, and ColorVectorSpace keeps `Gray{N0f8} + Gray{N0f8}` in `N0f8` (lines 1, 10);
`*` goes through float and a checked conversion that throws ([`normed.jl`][fpn-mul],
line 2). The default branch sets `const DEFAULT_ARITHMETIC = :wrapping`, maps `+`, `-`
and `*` to `wrapping_*` and keeps `/` checked ([`FixedPointNumbers.jl` at
v0.9.3][fpn-093-default]), while its README still shows the `N4f12` multiplication
error. Loading the v0.9.3 source in the same Julia confirms it: `N4f12(15) * N4f12(15)`
returns `0.9453` (wrapped) and `N0f8(0.8) / N0f8(0.1)` throws `OverflowError`. The
tutorial warns ([`arrays_colors.md`][ji-ac-overflow]): _"It's important to note that arithmetic with `N0f8` numbers, like arithmetic with `UInt8`, overflows"_.

Codec safety is the wrapped C library's. PNGFiles raises a Julia `error(...)` from inside
libpng's error callback ([`wraphelpers.jl`][png-errfn]) and allocates from header
dimensions; `src/` contains no `png_set_user_limits` call (only the generated binding in
`gen/`), so libpng's compiled-in defaults are the only limits: 1,000,000 × 1,000,000
pixels, 1000 cached chunks and 8,000,000 bytes per decompressed chunk in libpng's
configuration file ([`pnglibconf.dfa`][libpng-limits], read on the `libpng18` branch;
the libpng build PNGFiles links was not checked). FileIO's fallback catches every backend exception and
tries the next backend ([`loadsave.jl`][fio-action]): a file PNGFiles rejects goes to ImageMagick if
installed, so the attack surface of `load` is the union of the registered backends. No
fuzzing harness exists in the three cloned repositories.

### 6. Allocation and ownership

Everything is garbage-collected. A view is a small immutable struct referencing its
parent, which the GC keeps alive: no borrow, no lifetime, no dangling view. Outputs come
from `similar` or `Array{T}(undef, …)`; no allocator parameter exists in ImageCore,
ImageIO or PNGFiles. Loops over views allocate nothing once compiled (`@allocated` above).
FixedPointNumbers keeps results narrow: _"Because of the role of FixedPointNumbers in
domains such as image-processing, this package tries to limit the expansion of the
number of bits needed to store results"_ ([`README.md`][fpn-storage]). A PNG decode
allocates twice (buffer and `permutedims`), and ImageIO's canonicalisation may add a
third (_"there will be an extra memory allocation and thus hurt the performance"_,
[`ImageIO.jl`][iio-canonical]).

### 7. CPU parallelism and SIMD

No threading or explicit SIMD in the sources of ImageCore, ColorTypes or Images.jl (a
`grep` for `Threads`, `@threads`, `@simd` and `LoopVectorization` found only two `@simd`
loops in ImageCore's `test/benchmarks.jl`). Vectorisation is LLVM's after specialisation.
A benchmark test compares loops over `channelview`/`colorview` with plain arrays, including
`@inbounds @simd`, with tolerance factors of 3 on Julia 1.6 and later (20 for one fill
loop); it runs only off CI and only warns
([`benchmarks.jl`][ic-bench], [`runtests.jl`][ic-runtests]). It was not run here. Threads
live downstream: NEWS records ImageFiltering's _"cache-efficient tiling and
multithreading"_ ([`NEWS.md`][img-news-threads]).

### 8. GPU offload and interop

Not in these packages. Colour types are `isbits` (line 3), the property a GPU array of
them needs, and NEWS calls downstream replacements _"generic and GPU-ready"_
([`NEWS.md`][img-news-gpu]), meaning generic over any `AbstractArray`, GPU arrays from
other packages included. No GPU array was exercised in this review. Packed
`ARGB32`/`BGRA` exist for Cairo and OpenGL buffers ([`README.md`][ct-readme-alpha]).

### 9. Temporal, animation and containers

Time is an axis. ImageAxes declares a `TimeAxis` trait for `Axis{:time}` and derives
`timedim`, `nimages` and `assert_timedim_last` from it ([`ImageAxes.jl`][ia-timeaxis],
[`ImageAxes.jl`][ia-traits]),
so a movie is a 3-D or 4-D `AxisArray`. For sources where seeking is expensive,
`StreamingContainer` is _not_ an `AbstractArray` and fills a caller buffer per slice
([`ImageAxes.jl`][ia-streaming]):

> An array-like object possessing one or more axes for which changing "slices" may be expensive or subject to restrictions. A canonical example would be an AVI stream, where addressing pixels within the same frame is fast but jumping between frames might be slow.

A `StreamIndexStyle` trait marks forward-only streams as `IndexIncremental` (_"e.g., a
video stream from a webcam"_, [`ImageAxes.jl`][ia-indexstyle]). Video containers are FileIO
registrations for VideoIO (`AVI`, `MP4`, `OGG`, `MATROSKA`, [`registry.jl`][fio-video]);
GIF is registered for ImageMagick only. No timestamp type, frame duration or animation
abstraction exists in the packages read.

### 10. Testing and conformance

Type inference is a tested property. ColorTypes wraps constructors, traits and
operations in `@inferred` (about 430 occurrences under `test/`) and re-runs them in an
"inference" mode ([`runtests.jl`][ct-tests]); ImageCore does so for views (about 160),
asserting for example `@inferred(colorview(Gray, v)) === a` ([`colorchannels.jl`
tests][ic-infer]). Both run Aqua (ambiguities, unbound parameters, compat; ImageCore
leaves `piracies` disabled under a `FIXME`) and Documenter doctests
([`runtests.jl`][ic-runtests]). `mosaicview` output is compared byte-exactly
(`by=isequal`) against reference PNGs through ReferenceTests ([`views.jl`][ic-ref]).
Codec conformance is left to the C libraries; no corpus or differential oracle exists in
the three clones.

---

## Lessons for Sparkles

- **Q1. The element type can carry what a header would.** `Gray{N0f8}` versus
  `RGB{N0f16}` versus `Lab{Float32}` stops 0..255 and 0..1 values, or 12- and 16-bit
  samples, from being confused. D POD structs (`RGB!T` over a `Norm!ubyte`-style sample)
  map directly. Sparkles moves pixels as `const(ubyte)[]` with untyped conventions (G2,
  G4 in [existing code][bl-existing]); the shader vocabulary has no byte or unsigned
  pixel types (G3 in [shaders and SIMD][bl-shaders]).
- **Q1. Julia's channel-first is D's channel-last.** The column-major `3 × h × w`
  `channelview` has the bytes of a row-major `h × w × 3` slice. A D `channelView` over
  contiguous memory is a reinterpreting cast plus a mir [`Slice`][mir-slice] with a
  trailing extent-3 dimension; `BGR` reordering is index arithmetic or a lazy
  [`map`][mir-map]/[`as`][mir-as], as `of_eltype` is. mir's `transposed` turns a
  contiguous slice into a `Universal` (strided) one when the permutation moves the last
  dimension, `Canonical` otherwise ([`dynamic.d`][mir-transposed]), the same loss of
  contiguity `PermutedDimsArray` has.
- **Q1. The model stops where video and interop start.** No subsampled planes, padded
  rows or tiles. For video and DLPack-style layouts (G14 in [existing code][bl-existing])
  an array of pixel structs needs a planar, byte-strided companion; JuliaImages gives no
  evidence for its design.
- **Q2. Dispatch maps onto templates except open extension.** Ladders, wrapper matching,
  generated families and Holy traits have static D forms (constrained overloads, `is`,
  `mixin`, `enum bool` traits), with the same per-element-type instantiation (line 13).
  Adding methods to another package's function has none; the D form is a hook detected
  by introspection ([guidelines][dbi]).
- **Q2, Q9. The run-time boundary is the codec.** ImageIO's _"it can never be type
  stable"_ and line 16's `Union` are the boundary a D decoder has; a `SumType` over a
  small canonical set, matched once per call, is the static analogue the
  [generic programming thread][p-generic] reaches. ImageCore's precompile workload
  enumerates `(N0f8, N0f16, Float32, Float64)` × `(Gray, RGB)` ([`precompile.jl`][ic-precompile]):
  Julia bounds the set in practice too.
- **Q3. Writable lazy views compose without allocation.** A `MappedArray` with forward and
  inverse functions keeps `rawview`, `normedview`, `BGR` channel views and planar
  `colorview` zero-copy and writable. D ranges and mir `map` give the read side; the
  write side needs `ref` returns or `opIndexAssign`, where `@safe`, `scope` and dip1000
  will be tested. Whether such views keep LDC loops vectorised is unmeasured.
- **Q5. Types alone did not make colour correct.** No linear-RGB or premultiplied type,
  vector arithmetic on encoded sRGB by design, and a PNG decoder that gamma-corrects
  towards an assumed 2.2 display without saying so. Copying the hierarchy would not fix
  Sparkles' alpha split (G3) or untyped colour (G4) in [existing code][bl-existing];
  transfer, primaries and premultiplication need their own slot, typed or in a runtime
  descriptor (see the [resampling and colour thread][p-colour]).
- **Q5, Q8. State fixed-point arithmetic once and test it.** `+` wraps; `*` threw at v0.8
  and wraps at v0.9. In `@safe pure nothrow @nogc` code an exception on overflow is not
  available, so the choice is wrapping, saturating, or an `Expected`-returning checked
  form; JuliaImages' docs recommend float accumulators regardless.
- **Q4. A magic-byte registry is cheap; run-time plugin loading is not portable.**
  `add_format(fmt, magic, ext, backends…)` maps to a compile-time table in D. `Base.require`
  plus `invokelatest` has no counterpart in betterC, wasm or a static Android runtime,
  so a D registry is closed at link time. Header magic and layout belong to the
  [wired baseline][bl-wired].
- **Q4, Q6. Whole-file decode plus a transposing copy is the shape to avoid.** Sparkles
  has the same whole-file shape (G6, G7 in [existing code][bl-existing]); a row-major D
  library needs no transpose, and incremental feeding would come from
  [event-horizon][bl-eh]. JuliaImages offers no model for suspendable decode.
- **Q5, Q8. Fallback on error widens the attack surface.** A strict decoder's rejection
  is overridden by the next, more lenient backend. A Sparkles registry should make
  fallback explicit and off by default; the [hostile-input thread][p-hostile] records
  why lenient decoders are the exploited ones.
- **Q6. GC hides the question dip1000 forces.** Julia views keep parents alive. A D view
  over a `UniqueBuffer` ([`sparkles.base.buffer`][buffer-spec]) is `scope`-bound to it, and
  a decoder returns the owner, not a view. Nothing about ownership transfers, because
  JuliaImages never decides it.
- **Q8. Test type stability.** Hundreds of `@inferred` assertions, including that views
  compose back to the original (`colorview(C, channelview(a)) === a`), map to
  `static assert(is(typeof(…) == …))` and the attribute-checked unittests Sparkles
  already requires.
- **Q9. A fine-grained split works, at a cost.** Sample types (FixedPointNumbers), colour
  types (ColorTypes), conversions (Colors), arithmetic (ColorVectorSpace, opt-in), views
  and traits (ImageCore), axes (ImageAxes), I/O (FileIO, ImageIO) and an umbrella. Types
  can be depended on without codecs, the argument for an image-core cut in
  [existing code][bl-existing] question 6. The cost: compat pinned across packages
  (ImageCore at `FixedPointNumbers = "0.8"` while 0.9 is current) and a piracy check left
  off.

## Strengths

- One representation: any `AbstractArray` of a colour type, so all array machinery
  (views, broadcasting, reductions, offset indices) applies.
- Colour space and sample scale in the type, constructor order independent of memory
  order.
- Zero-copy, writable views between pixel and channel forms, unwrapping when composed.
- Normalised fixed-point unifies 8- to 16-bit integer images and float images on one scale.
- Small layered packages; inference and composition are tested properties.

## Weaknesses

- Colour semantics stop at the space name; arithmetic on encoded sRGB by design.
- Fixed-point arithmetic wraps silently, and `*` changed between 0.8 and 0.9.
- No subsampled planes, padded rows or tiles; video is only an axis.
- Whole-file pull I/O, a transposing copy for PNG, unrecorded decoder gamma correction,
  and fallback across backends on any error.
- Hostile-input defence delegated to C libraries; no limits, fuzzing or corpus here.
- Per-type specialisation is paid as first-call compile latency, mitigated by precompile
  workloads; cross-package method extension leaves piracy to discipline.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                         | Trade-off                                                                                    |
| ------------------------------------------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| No image type; any `AbstractArray` is an image                | Reuse all array machinery; no conversion at library boundaries    | Metadata needs wrappers that every algorithm must forward through                            |
| Colour space and sample type in the element type              | Dispatch and promotion catch unit and space mix-ups               | Only what fits a type parameter is captured; transfer, premultiplication, profiles are not   |
| `Normed` scales by `2^f - 1`                                  | All-ones is exactly `1.0`; integer and float images share a scale | Multiplication needs float or wide work; default arithmetic wraps                            |
| Constructor order fixed at `(r, g, b, alpha)`                 | Generic code ignores storage order                                | `channelview` of `BGR` is a mapped view, not a reinterpretation                              |
| Arithmetic in opt-in ColorVectorSpace                         | Types stay minimal; colorimetric code can avoid vector arithmetic | Loading it changes `+` for everyone; arithmetic on encoded values is the default once loaded |
| Views over `reinterpret` and `mappedarray`, unwrap on compose | Zero-copy conversions that do not stack                           | Correctness depends on dispatch on Base's internal wrapper types                             |
| Column-major, channel-first `channelview`                     | Channel fastest in memory, matching interleaved storage           | Index order reads reversed against row-major libraries                                       |
| Format registry by magic and extension, run-time backends     | Optional dependencies; new formats without touching the core      | Not type stable; needs a JIT runtime; error fallback widens attack surface                   |
| Time as a named axis with a trait                             | Movies are higher-dimensional arrays                              | No timestamps or durations; streaming needs a non-array container                            |

## Sources

- Catalog clones, at the revisions in the metadata table: ImageCore (`src/`, `docs/src/`,
  `test/`), ColorTypes (`README.md`, `src/`, `test/runtests.jl`), Images (`README.md`,
  `src/Images.jl`, `NEWS.md`).
- Scratch clones (paths checked with `git cat-file -e`): FixedPointNumbers tag `v0.8.6`
  `cfcedccfe30c8b0909d7868eabb046fbe6bb38c2` and default branch
  `0ec4da6ff071469f0789447c17e65ffd3c9b222f` (`v0.9.3`); ImageAxes
  `801f6f8ee0d2ead9cafe63772847a669a64a714c`; ImageIO
  `76df82e5bbdca046de1dde321cb85ce2c0627f28`; FileIO
  `6f9b1a1249524e7a876a7d6bd06a9c1162e513fb`; PNGFiles
  `912fccf374fca06dbb96fe643ba01710cf808d18`; ColorVectorSpace
  `ffc001718d28b08e7933138648a89efe61054b19`; juliaimages.github.io
  `61cf1d95a6a95aab78f09a762605d85b0273d91a`.
- mir-algorithm `2da212382e434ef86e93f7b028bc2309205ae00e` (catalog clone), for the D
  comparison.
- Run: two Julia scripts in a scratch directory; output in
  [Verified behaviour](#verified-behaviour). A verification rerun repeated lines 1, 2, 4, 6,
  8 to 10, 15, 16 and 19 and loaded FixedPointNumbers v0.9.3 from its clone.
- libpng `890812a28da480f84f3b0198d31ac611c864ed98` (catalog clone, `libpng18` branch),
  for its default limits.
- Paper threads: [generic image programming][p-generic] (Bezanson et al. 2017,
  [arXiv:1411.1607][julia-arxiv], and the JuliaImages documentation entry),
  [resampling and colour][p-colour], [hostile input][p-hostile]. Baseline:
  [existing code][bl-existing], [shaders and SIMD][bl-shaders], [wired][bl-wired],
  [event-horizon][bl-eh].

<!-- References -->

[ic-repo]: https://github.com/JuliaImages/ImageCore.jl
[ct-repo]: https://github.com/JuliaGraphics/ColorTypes.jl
[img-repo]: https://github.com/JuliaImages/Images.jl
[fpn-repo]: https://github.com/JuliaMath/FixedPointNumbers.jl
[ia-repo]: https://github.com/JuliaImages/ImageAxes.jl
[iio-repo]: https://github.com/JuliaIO/ImageIO.jl
[fio-repo]: https://github.com/JuliaIO/FileIO.jl
[png-repo]: https://github.com/JuliaIO/PNGFiles.jl
[axisarrays]: https://github.com/JuliaArrays/AxisArrays.jl
[ji-site]: https://juliaimages.org/stable/
[ji-src]: https://github.com/JuliaImages/juliaimages.github.io/tree/61cf1d95a6a95aab78f09a762605d85b0273d91a
[ic-docs-site]: https://JuliaImages.github.io/ImageCore.jl/stable
[ic-project]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/Project.toml#L16-L37
[ic-docs-index]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/docs/src/index.md#L3-L8
[ic-docs-views]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/docs/src/views.md#L5-L14
[ic-docs-views-perm]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/docs/src/views.md#L68-L205
[ic-raw]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/ImageCore.jl#L95-L123
[ic-filltype]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/ImageCore.jl#L125-L151
[ic-ffthint]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/ImageCore.jl#L163-L179
[ic-chan]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/colorchannels.jl#L47-L86
[ic-checks]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/colorchannels.jl#L227-L343
[ic-dimorder]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/colorchannels.jl#L5-L26
[ic-reinterpretc]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/convert_reinterpret.jl#L1-L13
[ic-convert]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/convert_reinterpret.jl#L19-L42
[ic-traits]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/traits.jl#L52-L214
[ic-hasdimnames]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/traits.jl#L1-L50
[ic-stacked]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/stackedviews.jl#L1-L28
[ic-precompile]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/src/precompile.jl#L19-L36
[ic-bench]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/test/benchmarks.jl#L84-L97
[ic-runtests]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/test/runtests.jl#L7-L47
[ic-ref]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/test/views.jl#L192-L196
[ic-infer]: https://github.com/JuliaImages/ImageCore.jl/blob/c3f8157040464b8ddffd18ffadff35c599f9e516/test/colorchannels.jl#L30-L40
[ct-readme-alpha]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/README.md#L34-L54
[ct-readme-n0f8]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/README.md#L70-L84
[ct-readme-bgr]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/README.md#L96-L99
[ct-colorant]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L1-L91
[ct-aliases]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L93-L109
[ct-rgb]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L111-L144
[ct-xyz]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L240-L247
[ct-lms]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L376-L384
[ct-fractional]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/ColorTypes.jl#L18
[ct-argb32]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L445-L574
[ct-eltype-default]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L592-L618
[ct-make-alpha]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L620-L647
[ct-alpha-list]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L661-L688
[ct-colorerror]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/src/types.jl#L869-L886
[ct-tests]: https://github.com/JuliaGraphics/ColorTypes.jl/blob/59a21eb2307a63ac8194fd15d1f7458239cc8cd7/test/runtests.jl#L6-L29
[img-umbrella]: https://github.com/JuliaImages/Images.jl/blob/955de10ba2a1ef502f52c165f32ff7b67d97ef6b/src/Images.jl#L7-L31
[img-news-gpu]: https://github.com/JuliaImages/Images.jl/blob/955de10ba2a1ef502f52c165f32ff7b67d97ef6b/NEWS.md#L37-L48
[img-news-threads]: https://github.com/JuliaImages/Images.jl/blob/955de10ba2a1ef502f52c165f32ff7b67d97ef6b/NEWS.md#L150-L160
[fpn-normed-doc]: https://github.com/JuliaMath/FixedPointNumbers.jl/blob/cfcedccfe30c8b0909d7868eabb046fbe6bb38c2/README.md#L46-L56
[fpn-storage]: https://github.com/JuliaMath/FixedPointNumbers.jl/blob/cfcedccfe30c8b0909d7868eabb046fbe6bb38c2/README.md#L119-L133
[fpn-struct]: https://github.com/JuliaMath/FixedPointNumbers.jl/blob/cfcedccfe30c8b0909d7868eabb046fbe6bb38c2/src/normed.jl#L13-L20
[fpn-addsub]: https://github.com/JuliaMath/FixedPointNumbers.jl/blob/cfcedccfe30c8b0909d7868eabb046fbe6bb38c2/src/FixedPointNumbers.jl#L236-L240
[fpn-mul]: https://github.com/JuliaMath/FixedPointNumbers.jl/blob/cfcedccfe30c8b0909d7868eabb046fbe6bb38c2/src/normed.jl#L251-L253
[fpn-093-default]: https://github.com/JuliaMath/FixedPointNumbers.jl/blob/0ec4da6ff071469f0789447c17e65ffd3c9b222f/src/FixedPointNumbers.jl#L326-L345
[ia-traits]: https://github.com/JuliaImages/ImageAxes.jl/blob/801f6f8ee0d2ead9cafe63772847a669a64a714c/src/ImageAxes.jl#L142-L179
[ia-timeaxis]: https://github.com/JuliaImages/ImageAxes.jl/blob/801f6f8ee0d2ead9cafe63772847a669a64a714c/src/ImageAxes.jl#L33-L114
[ia-streaming]: https://github.com/JuliaImages/ImageAxes.jl/blob/801f6f8ee0d2ead9cafe63772847a669a64a714c/src/ImageAxes.jl#L199-L271
[ia-indexstyle]: https://github.com/JuliaImages/ImageAxes.jl/blob/801f6f8ee0d2ead9cafe63772847a669a64a714c/src/ImageAxes.jl#L371-L400
[iio-readme]: https://github.com/JuliaIO/ImageIO.jl/blob/76df82e5bbdca046de1dde321cb85ce2c0627f28/README.md#L9-L18
[iio-canon-readme]: https://github.com/JuliaIO/ImageIO.jl/blob/76df82e5bbdca046de1dde321cb85ce2c0627f28/README.md#L40-L45
[iio-lazy]: https://github.com/JuliaIO/ImageIO.jl/blob/76df82e5bbdca046de1dde321cb85ce2c0627f28/src/ImageIO.jl#L8-L17
[iio-canonical]: https://github.com/JuliaIO/ImageIO.jl/blob/76df82e5bbdca046de1dde321cb85ce2c0627f28/src/ImageIO.jl#L19-L57
[fio-png]: https://github.com/JuliaIO/FileIO.jl/blob/6f9b1a1249524e7a876a7d6bd06a9c1162e513fb/src/registry.jl#L211-L219
[fio-video]: https://github.com/JuliaIO/FileIO.jl/blob/6f9b1a1249524e7a876a7d6bd06a9c1162e513fb/src/registry.jl#L275-L295
[fio-action]: https://github.com/JuliaIO/FileIO.jl/blob/6f9b1a1249524e7a876a7d6bd06a9c1162e513fb/src/loadsave.jl#L196-L229
[png-gamma]: https://github.com/JuliaIO/PNGFiles.jl/blob/912fccf374fca06dbb96fe643ba01710cf808d18/src/io.jl#L16-L20
[png-load-bang]: https://github.com/JuliaIO/PNGFiles.jl/blob/912fccf374fca06dbb96fe643ba01710cf808d18/src/io.jl#L211-L260
[png-errfn]: https://github.com/JuliaIO/PNGFiles.jl/blob/912fccf374fca06dbb96fe643ba01710cf808d18/src/wraphelpers.jl#L1
[libpng-limits]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/scripts/pnglibconf/pnglibconf.dfa#L367-L380
[cvs-readme]: https://github.com/JuliaGraphics/ColorVectorSpace.jl/blob/ffc001718d28b08e7933138648a89efe61054b19/README.md#L15-L27
[ji-qs-array]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/tutorials/quickstart.md#L21-L23
[ji-qs-chw]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/tutorials/quickstart.md#L200-L214
[ji-qs-n0f8]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/tutorials/quickstart.md#L236-L245
[ji-ac-array]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/tutorials/arrays_colors.md#L10-L13
[ji-ac-overflow]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/tutorials/arrays_colors.md#L377-L401
[ji-axes]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/pkgs/axes/index.md#L48-L66
[ji-meta]: https://github.com/JuliaImages/juliaimages.github.io/blob/61cf1d95a6a95aab78f09a762605d85b0273d91a/docs/src/pkgs/metadata/index.md#L1-L17
[mir-slice]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L669
[mir-map]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L2738
[mir-as]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L3663
[mir-transposed]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/dynamic.d#L489-L555
[julia-arxiv]: https://arxiv.org/abs/1411.1607
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[buffer-spec]: ../../specs/base/buffer.md
[p-generic]: ./papers/generic-image-programming.md
[p-colour]: ./papers/resampling-colour.md
[p-hostile]: ./papers/hostile-input-safety.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md
