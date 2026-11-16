# ITK (C++)

The Insight Toolkit: an N-dimensional scientific imaging library whose image carries its place in physical space and three nested regions, and whose demand-driven pipeline streams large data by negotiating those regions between filters.

| Field         | Value                                                                                                                                                      |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 template library with compiled modules (CMake); Python wrapping generated through CastXML and SWIG                                                   |
| License       | Apache License 2.0 ([`LICENSE`][license])                                                                                                                  |
| Repository    | [InsightSoftwareConsortium/ITK][repo]                                                                                                                      |
| Revision read | `443d201c3b23b94999debefddda8266a177dffea` (`main`, October 27, 2026; version string 6.0.0 in [`CMake/itkVersion.cmake`][version])                         |
| Documentation | [docs.itk.org][docs] · [ITK Software Guide][guide] · [Doxygen API][doxygen] · in-tree [`AGENTS.md`][agents] and [`Documentation/AI/architecture.md`][arch] |
| Category      | Generic libraries: compile-time pixel type and dimension, run-time pipeline and I/O plugins                                                                |
| Tier          | A                                                                                                                                                          |
| Last reviewed | November 14, 2026                                                                                                                                          |

> [!NOTE]
> Claims marked **verified** were demonstrated by building `ITKCommon` (and the modules
> CMake pulled in with it) from a `git archive` of the pinned revision with GCC 14.3.0
> and CMake 4.1.2, then compiling and running two probe programs against it in a scratch
> directory under `/tmp`. The main probe's output is quoted in [How it works][verified-run].
> Everything else is read from the source or documentation at the pinned revision. No
> performance number on this page was measured.
>
> The verifier rebuilt the pinned source and three probes under `/tmp/itk-final-review`
> with GCC 14.3.0, CMake 4.1.2 and `-O2`. Configuration used
> `-DBUILD_TESTING=OFF -DITK_BUILD_DEFAULT_MODULES=OFF -DITKGroup_Core=OFF -DModule_ITKCommon=ON`;
> disabling the Core group avoids the extra modules in the original build.
> The quoted output matched exactly. A separate UBSan-enabled arithmetic probe
> confirmed unsigned 64-bit multiplication and a zero-element allocation.

---

## Overview

### What it solves

ITK exists for medical and scientific volumes: CT, MRI, microscopy, at two, three,
four or more dimensions, with voxels that are not square, axes that are not aligned with
the scanner, and datasets larger than memory. A viewer-oriented library treats an image
as a grid of pixels addressed by integer coordinates. ITK treats it as a sampling of a
continuous physical space. Every image carries an origin, a spacing per axis and a
direction-cosine matrix, so that two images of the same patient taken by different
scanners can be compared voxel by voxel only after a check that they occupy the same
space, and registration filters can map between them. The README states the scope:

> _"The Insight Toolkit (ITK) is an open-source, cross-platform toolkit for
> N-dimensional scientific image processing, segmentation, and registration."_
> ([`README.md`][readme])

The second problem is size. A 512×512×200 volume of `float` is 200 MiB; a time series or
a whole-slide microscopy image is many times that. ITK's answer is the region
negotiation of its pipeline: each image has a largest possible region (the whole
dataset), a buffered region (what is in memory) and a requested region (what a consumer
wants), and filters translate an output request into an input request so that only the
needed part of the input is read and computed. A streaming filter at the end of the
pipeline then runs the whole chain once per piece.

Segmentation, registration and the filter catalogue are out of scope here.

### Design philosophy

Three commitments shape the code. First, geometry is part of the image, not metadata
beside it. From the `ImageBase` class comment ([`itkImageBase.h`][imagebase-doc]):

> _"ImageBase manages the geometry of an image. The geometry of an image is defined by
> its position, orientation, spacing, and extent. [...] The "Origin" is the physical
> position of the pixel whose "Index" is all zeros. The "Direction" of an image is a
> matrix whose columns indicate the direction in physical space that each dimension of
> the image traverses."_

Second, computation is lazy and demand-driven. The repository's own agent guide puts the
two rules a newcomer breaks first side by side ([`AGENTS.md`][agents-pitfalls]):

> _"**Never `delete` ITK objects** — always use `SmartPointer`
> (`auto filter = FilterType::New()`)."_ and _"**`Update()` is required** — filters
> don't execute until called; parameter changes after `Update()` need another call."_

Third, both pixel type and dimension are compile-time template parameters, while the
pipeline, the I/O plugins and object creation are run-time and virtual. The
architecture note says so directly: _"Compile-time polymorphism is achieved via traits
and policy classes rather than virtual dispatch"_ ([`architecture.md`][arch-poly]),
and the same file describes _"a lazy evaluation pipeline"_. ITK is therefore two
libraries joined at the filter boundary: a generic one inside `GenerateData` and an
object-oriented, reference-counted, factory-created one outside it.

Within the survey ITK is the reference for the scientific side of
[question 1][survey-questions]: it is what VIGRA's
[`MultiArrayView`][vigra] and Julia's [ImageAxes][juliaimages] look like when
physical space and out-of-core data are first-class. Its pipeline is a run-time
counterpart of bounds inference in [Halide][halide].

---

## How it works

### The image: geometry plus a contiguous buffer

`itk::Image<TPixel, VImageDimension>` derives from `ImageBase<VImageDimension>`, which
derives from `DataObject`. `ImageBase` holds no pixels. It holds the geometry and the
three regions ([`itkImageBase.h`][imagebase-members]):

```cpp
// Modules/Core/Common/include/itkImageBase.h (protected and private members)
SpacingType   m_Spacing{ MakeFilled<SpacingType>(1.0) };
PointType     m_Origin{};
DirectionType m_Direction{ DirectionType::GetIdentity() };
DirectionType m_InverseDirection{ DirectionType::GetIdentity() };
DirectionType m_IndexToPhysicalPoint{ DirectionType::GetIdentity() };
DirectionType m_PhysicalPointToIndex{ DirectionType::GetIdentity() };
// ...
OffsetValueType m_OffsetTable[VImageDimension + 1]{};
RegionType m_LargestPossibleRegion{};
RegionType m_RequestedRegion{};
RegionType m_BufferedRegion{};
```

`ComputeIndexToPhysicalPointMatrices` caches `m_Direction * diag(m_Spacing)` and its
inverse whenever spacing or direction changes ([`itkImageBase.hxx`][imagebase-matrices]),
so `TransformIndexToPhysicalPoint` is one matrix-vector product plus the origin, and
`TransformPhysicalPointToIndex` applies the inverse and rounds with
`Math::RoundHalfIntegerUp` ([`itkImageBase.h`][imagebase-p2i]). The setters validate:
`SetSpacing` checks for zero components and, unless `ITK_LEGACY_REMOVE` is defined,
warns and stops checking at the first negative one (see [the validation gap][hostile-section]);
`SetDirection` throws when the determinant is exactly zero
([`itkImageBase.hxx`][imagebase-setters]).

Pixel storage is an `ImportImageContainer<SizeValueType, TPixel>` held through a
`SmartPointer` ([`itkImage.h`][image-container]). The buffer covers the buffered region
only and is always dense: the offset table is computed from the buffered region's size,
`{1, N1, N1*N2, ...}`, and the last entry is the element count that `Allocate` reserves
([`itkImageBase.hxx`][imagebase-offsets], [`itkImage.hxx`][image-allocate]). There is
no stride field. A region of interest is not a view of the buffer with its own strides;
it is a region that an iterator walks inside the buffer. `ComputeOffset` subtracts the
buffered region's start index, so indices are absolute in the dataset's index space and
the buffer can be a window anywhere in it ([`itkImageBase.h`][imagebase-offset]).

The memory order is fixed and documented on `Image`:

> _"The data in an image is arranged in a 1D array as `[][][][slice][row][col]` with the
> column index varying most rapidly. The Index type reverses the order so that with
> Index[0] = col, Index[1] = row, Index[2] = slice, ..."_
> ([`itkImage.h`][image-doc])

Index components are signed (`IndexValueType`, `long` or `int64_t`), sizes unsigned
(`SizeValueType`), offsets signed (`OffsetValueType`) ([`itkIntTypes.h`][inttypes]).
Region start indices can therefore be negative.

### Regions and the three pipeline passes

The `DataObject` comment is the specification of the pipeline. Its core paragraph
([`itkDataObject.h`][dataobject-doc]):

> _"These three regions can be different but must satisfy the relationship
> RequestedRegion <= BufferedRegion <= LargestPossibleRegion. For instance, an Image
> could be 512x512x200 on disk (LargestPossibleRegion) but the application may only
> have a 256x256x50 section of the dataset in memory (BufferedRegion) and the user wants
> to operate on a 100x100x1 section of the buffer (RequestedRegion)."_

`DataObject::Update` is three calls, `UpdateOutputInformation`,
`PropagateRequestedRegion` and `UpdateOutputData` ([`itkDataObject.cxx`][dataobject-update]):

1. **Information pass.** `UpdateOutputInformation` walks upstream comparing modified
   times and, on the way back, each filter's `GenerateOutputInformation` sets its
   output's largest possible region, spacing, origin and direction. A reader fills these
   from the file header without reading pixels.
2. **Request pass.** `ProcessObject::PropagateRequestedRegion` calls three hooks in
   order, then recurses into each input ([`itkProcessObject.cxx`][po-propagate]):
   `EnlargeOutputRequestedRegion` (a filter that can only produce everything widens its
   own output request), `GenerateOutputRequestedRegion` (multi-output filters align
   their outputs), and `GenerateInputRequestedRegion` (a filter states what input it
   needs for the requested output).
3. **Data pass.** `UpdateOutputData` executes only the filters whose output is out of
   date or whose requested region falls outside the buffered region
   (`RequestedRegionIsOutsideOfTheBufferedRegion`).

A neighbourhood filter's `GenerateInputRequestedRegion` takes the input's requested
region, calls `PadByRadius(m_Radius)`, crops it to the input's largest possible region
and throws `InvalidRequestedRegionError` if nothing remains
([`itkBoxImageFilter.hxx`][box-request]).

`ImageToImageFilter::VerifyInputInformation` refuses multi-input filters whose inputs
are not congruent in physical space, within a tolerance scaled by the first spacing
component (_"Inputs do not occupy the same physical space!"_,
[`itkImageToImageFilter.hxx`][i2i-verify]). Some registration filters override it to
allow differing input geometries ([`itkDemonsRegistrationFilter.h`][demons-verify]).

### Streaming

`StreamingImageFilter` sits at the tail. Its `UpdateOutputData` allocates the full
output, asks a splitter (`ImageRegionSplitterSlowDimension` by default) for pieces, and
for each piece sets the input's requested region, propagates it and updates the
upstream pipeline, then copies the piece into its output
([`itkStreamingImageFilter.hxx`][streaming]):

```cpp
// Modules/Core/Common/include/itkStreamingImageFilter.hxx (abridged)
for (; piece < numDivisions && !this->GetAbortGenerateData(); ++piece)
{
  InputImageRegionType streamRegion = outputRegion;
  m_RegionSplitter->GetSplit(piece, numDivisions, streamRegion);

  inputPtr->SetRequestedRegion(streamRegion);
  inputPtr->PropagateRequestedRegion();
  inputPtr->UpdateOutputData();

  ImageAlgorithm::Copy(inputPtr, outputPtr, streamRegion, streamRegion);
}
```

Streaming-capable upstream stages can buffer one piece plus its margins. This does
not bound the whole pipeline's memory: `StreamingImageFilter` retains the full requested
output, and a non-streaming stage can enlarge its request to the whole image. A writer
that can stream (`CanStreamWrite`) can instead consume pieces and write them to the file.

### Execution inside a filter

`ImageSource::GenerateData` allocates outputs, calls `BeforeThreadedGenerateData`, then
either splits the requested region into a fixed number of pieces with a thread id
(`ThreadedGenerateData`, the classic mode) or hands the region to
`MultiThreaderBase::ParallelizeImageRegion`, which calls
`DynamicThreadedGenerateData(region)` once per work unit ([`itkImageSource.hxx`][source-gen]):

```cpp
// Modules/Core/Common/include/itkImageSource.hxx
this->GetMultiThreader()->template ParallelizeImageRegion<OutputImageDimension>(
  this->GetOutput()->GetRequestedRegion(),
  [this](const OutputImageRegionType & outputRegionForThread) {
    this->DynamicThreadedGenerateData(outputRegionForThread);
  },
  this);
```

The header explains the difference: the dynamic variant _"can split the requested
region into different number of pieces depending on current multi-processing load"_,
while only the platform threader _"guarantees that each piece will be processed in its
own specific thread"_ ([`itkImageSource.h`][source-doc]). Four threaders exist,
`Platform`, `Pool`, `TBB` and `Single`, selected globally or by the `ITK_GLOBAL_DEFAULT_THREADER`
environment variable ([`itkMultiThreaderBase.h`][mt-enum], [selection][mt-select]). The
pool threader defaults to four work units per thread when there is more than one thread,
capped by `ITK_MAX_THREADS` ([`itkPoolMultiThreader.cxx`][pool]).

### Iterators and neighbourhoods

`ImageRegionIterator` walks a region inside the buffer in memory order. Its increment is
a pointer offset with a span check; crossing the end of a row calls
`Increment` that steps to the next row of the region
([`itkImageRegionConstIterator.h`][region-iter-inc]). `ImageScanlineIterator` exposes
the row structure to the caller instead. `ImageBufferRange` and `ImageRegionRange` are
newer standard-conforming ranges for range-`for` and `<algorithm>`
([`itkImageBufferRange.h`][buffer-range]).

`ConstNeighborhoodIterator<TImage, TBoundaryCondition>` holds a `Neighborhood` of
pixel pointers around the centre and defaults its boundary policy to
`ZeroFluxNeumannBoundaryCondition`, which repeats the nearest edge pixel
([`itkConstNeighborhoodIterator.h`][nbr-iter], [`itkZeroFluxNeumannBoundaryCondition.h`][zfn]).
Boundary conditions derive from a virtual `ImageBoundaryCondition`: `GetPixel` is pure
virtual, and `GetInputRequestedRegion` (default: the whole largest possible region)
states how much input a policy needs ([`itkImageBoundaryCondition.h`][bc-virtual]). To
avoid paying for the boundary check on interior pixels,
`NeighborhoodAlgorithm::ImageBoundaryFacesCalculator` splits a region into one inner
region, where _"out-of-bounds values are never required and bounds checking is not
necessary"_, and the boundary faces ([`itkNeighborhoodAlgorithm.h`][faces]); an iterator
over the inner region can switch the check off with `NeedToUseBoundaryConditionOff`.
**Verified:** a radius-1 neighbourhood at the corner of a 3×3 image holding 1 to 9 reads
`1 1 2 1 1 2 4 4 5`, the edge values repeated.

### Objects, `New()` and factories

Every pipeline class derives from `LightObject`, which carries an atomic intrusive
reference count (`std::atomic<int> m_ReferenceCount`, [`itkLightObject.h`][lightobject]).
`itkNewMacro` expands to a static `New()` that first asks the object factory for an
override by `typeid` name (`ObjectFactory<x>::Create()`) and only then calls `new x()`
([`itkMacro.h`][newmacro], [`itkObjectFactory.h`][objfactory]), so any class, `Image`
included, can be replaced at run time by a registered factory. The same mechanism registers `ImageIOBase` plugins: `ImageIOFactory::CreateImageIO`
collects every registered instance of `itkImageIOBase`, probes those whose advertised
extension matches the path with `CanReadFile`, then probes the rest
([`itkImageIOFactory.cxx`][iofactory]).

### A verified run

The probe built a three-stage pipeline (a recording source producing a 100×80 `float`
image, a pass-through filter that pads its input request by 2, and a
`StreamingImageFilter` with four divisions), then exercised geometry, overflow, a
neighbourhood and the pixel types. **Verified** output with four threads:

```text
threader: itk::MultiThreaderBaseEnums::Threader::Pool
source GenerateData runs: 4
  requested index=[0, 0] size=[100, 22]
  requested index=[0, 18] size=[100, 24]
  requested index=[0, 38] size=[100, 24]
  requested index=[0, 58] size=[100, 22]
source work units: 46
output buffered size=[100, 80] spacing=[0.5, 2] pixel(7,33)=33007
source output buffered after stream=[100, 22]
index (3,1) -> point [8, 21.5]
point (8,21.5) -> index [3, 1]
zero spacing: exception
singular direction: exception
offset table for 2^32 x 2^32 x 1: [1, 4294967296, 0, 0]
neighbourhood at (0,0): 1 1 2 1 1 2 4 4 5
luminance(1,0,0)=0.3
VectorImage buffer[3..5]=1 2 3 sizeof(RGBPixel<uchar>)=3
```

The source ran once per piece, each time on a 20-row strip padded by two rows and cropped
at the image edges; its buffer after the run held only the last strip. Spacing set in
`GenerateOutputInformation` reached the end of the pipeline. Index `(3, 1)` with origin
`(10, 20)`, spacing `(0.5, 2)` and a 90-degree direction maps to `(8, 21.5)` and back.
The offset table is discussed under [hostile input][hostile-section]. The 46 work-unit
calls are an observation for this Pool configuration, not a thread-count guarantee.

---

## Analysis

### 1. Pixel and memory model

An image is a dense, first-index-fastest buffer covering the buffered region,
plus geometry. Dimension is a template parameter (`VImageDimension`, default 2), so N-D
is the native case and 2-D is an instantiation; `ITK_TEST_DIMENSION_MAX` is 6 in the
test driver ([`itkTestDriverInclude.h`][testdriver-h]). There are no strides, no
planes and no tiles in the container. A sub-region is addressed through the region an
iterator walks, never through a view with its own [stride][concept-stride]. Extraction
normally copies (`ExtractImageFilter`, `RegionOfInterestImageFilter`) or relies on the
pipeline to compute just that region. `ExtractImageFilter` can instead reuse the dense
buffer with `InPlaceOn()` when the input and output requested regions match
([header][extract-inplace]); it defaults to `InPlaceOff()` ([constructor][extract-default]).
A buffer may sit anywhere in index space because offsets are
taken relative to the buffered region's start, and indices are signed.

Multi-component pixels come in two layouts. `Image<RGBPixel<T>, N>` and
`Image<Vector<T, k>, N>` store a fixed-size struct per pixel (`RGBPixel` is a
`FixedArray<T, 3>`; verified `sizeof(RGBPixel<unsigned char>) == 3`). `VectorImage<T, N>`
stores a run-time number of components interleaved in one buffer of `T`, and returns a
`VariableLengthVector<T>` that points into the buffer
([`itkVectorImage.h`][vectorimage-doc], [`GetPixel`][vectorimage-get]). Its comment
records why: an `Image<VariableLengthVector<T>>` would hold a pointer per pixel,
_"a fragmented organization"_. Verified: after `SetPixel({1, 0}, {1, 2, 3})` with vector
length 3, buffer elements 3 to 5 are `1 2 3`. There is no planar layout in the core
image type; a planar dataset is a set of scalar images or one more dimension. Physical
geometry (origin, spacing, direction) adds physical meaning to the
[axis-order][concept-axes]
question: ITK's geometry makes the meaning of each axis explicit, but its index order is
the reverse of NumPy's, so the Python bridge reverses the shape unless `keep_axes=True`
([`PyBuffer.i.in`][pybuffer]).

### 2. Genericity mechanism

Inside a filter, genericity is C++ templates over the image type, with traits:
`NumericTraits<T>` for accumulation and real types, `DefaultConvertPixelTraits` for
component access during I/O conversion ([`itkDefaultConvertPixelTraits.h`][convtraits]),
`PixelTraits`, and accessor functors (`DefaultPixelAccessor`,
`DefaultVectorPixelAccessor`) that let the same iterator code serve `Image` and
`VectorImage`. `ImageAdaptor<TImage, TAccessor>` presents a lazily transformed image
(one channel, `abs`, a cast) through an accessor without copying
([`itkImageAdaptor.h`][adaptor]); it is the closest ITK comes to a view. Rebinding a
pixel type uses `RebindImageType`; the older nested `Rebind` template remains available
([`itkVectorImage.h`][vectorimage-rebind]).

Outside the inner loop, everything is virtual and dynamically typed: `ProcessObject`
holds inputs and outputs as `DataObject` pointers keyed by name, the pipeline calls
virtual hooks, `New()` consults a run-time factory, and neighbourhood boundary handling
calls a virtual `operator()` ([accessor][boundary-accessor], [interface][bc-virtual]). Which pixel types a program supports is
fixed when it is compiled; the Python wrapping fixes it when ITK is built, through
CMake switches such as `ITK_WRAP_unsigned_char`, `ITK_WRAP_float` and
`ITK_WRAP_rgb_unsigned_char`, with dimensions `2;3` by default
([`WrappingOptions.cmake`][wrapopts]). Like Boost.GIL ([`boost-gil.md`][boost-gil]),
ITK has macro-based concept checks: `itkConceptMacro` instantiates constraints, and
`AddImageFilter` checks additive operators ([implementation][concept-checks], [use][add-concept]).
`ITK_CONCEPT_NO_CHECKING` disables these checks.
The `Image` comment says a pixel type
that lacks an operator _"becomes apparent at compile-time"_ as a template error
([`itkImage.h`][image-doc]), and the in-tree guide's first pitfall is _"Template errors
are verbose"_.

### 3. Colour and metadata

ITK's metadata model is spatial, not colourimetric. Origin, spacing and direction are
typed fields with validation and tolerance-based comparison
(`IsCongruentImageGeometry`, `DefaultImageCoordinateTolerance = 1e-6`,
[`itkImageBase.h`][imagebase-doc], [comparison][imagebase-congruence]). Everything else goes into a `MetaDataDictionary`, a
copy-on-write `std::map<std::string, MetaDataObjectBase::Pointer>` of type-erased values
written with `EncapsulateMetaData` and read with `ExposeMetaData`
([`itkMetaDataDictionary.h`][metadict]). The reader copies the IO's dictionary onto the
output image ([`itkImageFileReader.hxx`][reader-info]). The TIFF reader stores tags in
it.

There is no typed colour-space model on `RGBPixel`, and its `GetLuminance`
is `0.30 * R + 0.59 * G + 0.11 * B` on the stored values whatever their encoding
(verified `0.3` for pure red, [`itkRGBPixel.hxx`][rgb-lum]). A grep of the PNG and
TIFF readers' sources at the pinned revision finds no explicit ICC-profile or
gamma-management calls. This does not establish that all colour tags are ignored:
the TIFF wrapper reads generic tags and can delegate conversion to
`TIFFReadRGBAImageOriented` ([tag handling][tiff-tags], [fallback][tiff-rgba]).
The JPEG reader recognises `JCS_CMYK` to flag it and optionally convert
it to RGB ([`itkJPEGImageIO.cxx`][jpeg-cmyk]). The PNG reader takes spacing only from an
`sCAL` chunk and otherwise sets it to 1 ([`itkPNGImageIO.cxx`][png-scal]). Default component
assignment is not a colour transform:
`DefaultConvertPixelTraits` _"does a simple assignment operator, so if you are going
from a higher bit representation to a lower bit one (int to char), you may want to
specialize and add some sort of transfer function"_ ([`itkDefaultConvertPixelTraits.h`][convtraits]).
Pixel conversion also includes fixed formulas: `ConvertPixelBuffer::ConvertRGBToGray`
uses 0.2125/0.7154/0.0721, different from `RGBPixel::GetLuminance`, without consulting a
colour profile ([implementation][convert-gray]).
For ITK's domain this is coherent: a CT voxel is a Hounsfield value, not a colour. For a
viewer it is the whole of [question 5][survey-questions] left
open.

### 4. I/O and codec architecture

`ImageIOBase` is a virtual class with a fixed protocol: `CanReadFile(path)`,
`ReadImageInformation()` (header only: dimensions, component type, pixel type, spacing,
origin, direction, dictionary) and `Read(void * buffer)` into memory the caller sized
([`itkImageIOBase.h`][iobase-read]). Pixel description is a run-time pair,
`IOPixelEnum` (`SCALAR`, `RGB`, `RGBA`, `VECTOR`, `COMPLEX`, `DIFFUSIONTENSOR3D`, ...)
and `IOComponentEnum` (`UCHAR` through `LDOUBLE`, with fixed-width aliases;
[enums][io-enums]), and the templated `ImageFileReader`
converts into the compile-time pixel type with `ConvertPixelBuffer` when they differ,
reading into a temporary buffer first ([`itkImageFileReader.hxx`][reader-read]). Formats
are plugins: 49 directories under `Modules/IO` include image, mesh and transform I/O
(PNG, JPEG, TIFF, NIfTI, NRRD, MetaImage, DICOM through GDCM and DCMTK, HDF5, MINC,
JPEG 2000, ...), each image format registering an `ImageIOBase` subclass with the
object factory.

Streaming read is region-based, not byte-incremental. During the request pass the
reader's `EnlargeOutputRequestedRegion` asks the IO for
`GenerateStreamableReadRegionFromRequestedRegion(requested)`; the IO answers with the
smallest region it can read that contains the request ([`itkImageFileReader.hxx`][reader-stream]).
The default answer is the whole image ([`itkImageIOBase.cxx`][iobase-streamable]), so
formats without random access (PNG, JPEG) read entirely and the pipeline crops.
`StreamingImageIOBase` provides sub-region I/O support. VTK, MRC, HDF5 and JPEG 2000
subclass it, with format-specific read implementations; MetaImage, NIfTI and Scanco
override the region negotiation themselves. Its raw-layout helper
`StreamReadBufferAsBinary` grows the chunk across every leading
dimension the region spans completely, then seeks and reads one chunk at a time
([`itkStreamingImageIOBase.h`][streaming-io], [`.cxx`][streaming-io-cxx]). This is the [pull][concept-pull]
model at region granularity: the IO opens the file by name (`SetFileName`), reads
synchronously, and cannot suspend for more bytes. It is not
[suspendable][concept-suspendable] and takes
no byte buffer from the caller.

### 5. Hostile input and safety

No hostile-input threat model is stated in the files read. ITK wraps vendored codec
libraries (`Modules/ThirdParty/PNG`, `JPEG`, `TIFF`, `GDCM`, `HDF5`, ...),
so safety depends on both those libraries and ITK's wrappers. The PNG reader handles
`libpng` errors through `setjmp` and turns them into `itkExceptionMacro`
([`itkPNGImageIO.cxx`][png-setjmp]). The size arithmetic in ITK's own code is unchecked.
`ComputeOffsetTable` multiplies the buffered region's sizes into a signed
`OffsetValueType` accumulator with no overflow test ([`itkImageBase.hxx`][imagebase-offsets]).
**Verified:** for a `char` image of size 2^32 × 2^32 × 1 the table is
`[1, 4294967296, 0, 0]`, so `Allocate` would reserve zero elements for a declared
2^64-pixel image. On this 64-bit build, the unsigned `SizeValueType` operand makes the
multiplication unsigned; 2^64 wraps to zero modulo 2^64, rather than causing signed
overflow ([types][inttypes]). The reader computes its load buffer size as pixels times component
size times components with no overflow check ([`itkImageFileReader.hxx`][reader-read]).
These are allocation-size hazards in ITK itself. The probe does not establish that a
particular codec accepts such a header or writes beyond the resulting allocation.

Pixel access is unchecked by design: `SetPixel` and `GetPixel` note that _"for
efficiency, this function does not check that the image has actually been allocated
yet"_ and `ComputeOffset` that _"the index is not checked as to whether it is inside the
current buffer"_ ([`itkImage.h`][image-pixel], [`itkImageBase.h`][imagebase-offset]).
Geometry setters are checked (zero spacing and singular direction throw, both verified),
with one gap: `SetSpacing` leaves its validation loop at the first negative component
after the warning, so a later zero is not tested there ([`itkImageBase.hxx`][imagebase-setters]).
**Verified:** `SetSpacing({-1, 0})` warns, assigns the spacing, and only then throws
_"Singular matrix. Determinant is 0."_ from the matrix inverse ([`itkMatrix.h`][matrix-inverse]), leaving the image with
spacing `[-1, 0]` in this build with `ITK_LEGACY_REMOVE` disabled. Requested regions outside the largest possible region throw
`InvalidRequestedRegionError`. A grep for `fuzz` outside `Modules/ThirdParty` at the
pinned revision finds no fuzz harness, only unrelated names. The PNG tests include two
corrupt inputs, `corrupted.png` and `cthead1-257-corrupt.png`, that a test expects to
fail cleanly ([`Modules/IO/PNG/test/CMakeLists.txt`][png-tests], [test body][png-corrupt-test]).
This source search does not establish whether external fuzzing exists.

### 6. Allocation and ownership

Every pipeline object (images, containers, filters, IOs) is heap-allocated and
intrusively reference-counted through `SmartPointer`, while `Index`, `Size` and
`ImageRegion` are plain values; copy and move are deleted on images (`ITK_DISALLOW_COPY_AND_MOVE`,
[`itkImage.h`][image-doc]). Pixel buffers are `new TElement[size]` (value-initialised on
request), and allocation failure throws `MemoryAllocationError`
([`itkImportImageContainer.hxx`][container-alloc]). External memory enters through
`ImportImageContainer::SetImportPointer(ptr, num, LetContainerManageMemory)`, which either
borrows or adopts a caller's array ([`itkImportImageContainer.h`][container-import]). The
NumPy bridge offers an array view of an image (`GetArrayViewFromImage`), whose
[`NDArrayITKBase`][ndarray-owner] keeps the image alive. In the other direction, `GetImageViewFromArray`
shares C-contiguous input but copies non-C-contiguous arrays, retaining the resulting
array through `_SetBase` ([`PyBuffer.i.in`][pybuffer], [array-to-image path][pybuffer-input]).

Buffer lifetime is pipeline-managed. Grafting lets a filter share a buffer with a
mini-pipeline's output; `InPlaceImageFilter` lets a filter overwrite its input's
buffer; `ReleaseDataFlag` frees an intermediate output once its consumer has run, and
`ProcessObject` temporarily disables input release while it executes
([`itkProcessObject.cxx`][po-release]). `Image::Initialize` replaces the container rather
than freeing it, because _"the same container can be shared by multiple images (e.g.
Grafted outputs and in place filters)"_ ([`itkImage.hxx`][image-allocate]). Streaming-capable
sources allocate for their requested piece; cached regions and in-place sharing can
avoid a new allocation. There is no allocator parameter or caller-provided scratch in
this allocation path.

### 7. CPU parallelism and SIMD

Parallelism is region splitting. A filter writes `DynamicThreadedGenerateData(region)`
and must write only within its region; the threader decides the number of pieces.
Verified: with four threads and the pool threader, four streaming pieces produced 46
work-unit calls in the source. The threader is a global run-time choice (`Platform`,
`Pool`, `TBB`, `Single`), and `ParallelizeArray` covers non-image loops
([`itkMultiThreaderBase.h`][mt-parallelize]). No general SIMD dispatch layer was found in
the core image loops. A search for x86 or NEON intrinsics and `omp simd` in production
`Modules` code outside `Modules/ThirdParty` finds only
`itkMathDetail.h`, which uses SSE2 scalar conversions for rounding
([`itkMathDetail.h`][mathdetail]). Inner loops rely on compiler auto-vectorisation of
iterator code, which the per-row span check in `ImageRegionIterator` and the
`ImageScanlineIterator` row form make possible but do not guarantee. Eigen and VNL are
vendored for linear algebra, not pixel loops.

### 8. GPU offload and interop

`ITKGPUCommon` is an OpenCL module, excluded from default builds (`EXCLUDE_FROM_DEFAULT`,
[`itk-module.cmake`][gpu-module]). `GPUImage<TPixel, N>` derives from `Image` and keeps a
`cl_mem` mirror with CPU and GPU dirty flags; CPU-side accessors mark the GPU copy dirty
or synchronise the CPU copy on demand ([`itkGPUImage.h`][gpu-image],
[`itkGPUDataManager.h`][gpu-dm]). Kernels are OpenCL sources (`GPUImageOps.cl`,
`GPUReduction.cl`) compiled at run time through [`GPUKernelManager`][gpu-build]. The design is implicit transfer behind the CPU image API, not
explicit staging. No Vulkan, CUDA, DLPack or external-memory import path was found in
the inspected in-tree GPU module.

### 9. Temporal, animation and containers

Time is either one more image dimension (a 4-D `Image<T, 4>` for a time series) or the
separate `ITKVideoCore` module. `TemporalDataObject` extends the region idea to time:
largest possible, requested and buffered temporal regions over frame numbers or real
time, with frames held in a `RingBuffer` of `DataObject` pointers
([`itkTemporalDataObject.h`][temporal]). [`VideoStream`][video-stream] is a temporal object of images,
[`VideoIOBase`][video-io] extends `ImageIOBase`, and OpenCV and VXL bridges provide video I/O.
No APNG, GIF or WebP frame API was found in the inspected still-image IO modules, nor a container
abstraction separate from the IO plugin; `ImageSeriesReader` stacks a file list into one
higher-dimensional image.

### 10. Testing and conformance

Tests are CTest entries driven by `itkTestDriver`, which runs a test executable and then
compares its output images against baselines with tolerances on intensity, pixel count,
neighbourhood radius, origin and direction (`--compare`, `--compareIntensityTolerance`,
`--compareNumberOfPixelsTolerance`, `--compareRadiusTolerance`, `--compare-MD5`,
[`itkTestDriverInclude.cxx`][testdriver-cxx], [`RegressionTestImage`][testdriver-h]).
Content-addressed inputs and baselines use `.cid` links holding IPFS content identifiers,
resolved by CMake's `ExternalData` at build time (for example
[`corrupted.png.cid`][png-cid], [fetch configuration][externaldata]). Some test fixtures
are stored directly in the tree, such as [`cake_easy.png`][inline-fixture].
`PipelineMonitorImageFilter` records requested
and buffered regions and update counts, so a test can assert that a filter streams
(`VerifyAllInputCanStream`) ([`itkPipelineMonitorImageFilter.h`][monitor]). GoogleTest
drivers sit beside the CTest ones. Results are published to CDash. No fuzz harness or
systematic differential oracle against another imaging library was identified in the
inspected non-ThirdParty tree. Baselines are reference images; their provenance must
be checked individually.

---

## Lessons for Sparkles

- **Q1** — ITK is the evidence that a scientific consumer needs **geometry as typed
  fields of the image**: origin, per-axis spacing and a direction matrix, with
  validation (non-zero spacing, non-singular direction) and a tolerance-based congruence
  test before two images are combined pixel by pixel. The
  [existing-code baseline][bl-existing] records no such thing (G2: pixels travel as
  `const(ubyte)[]` plus a `Size`). In D this is a small value type beside a view, not a
  base class: the cached index-to-physical matrices are a pure function of spacing and
  direction and fit `@safe pure nothrow @nogc`. Whether a viewer-oriented core carries it
  or a scientific layer wraps the view is the open decision; JuliaImages chose the
  wrapper ([`juliaimages.md`][juliaimages]), ITK the base class.
- **Q1** — ITK's container has **no strides**: a sub-region is something an iterator
  walks. Extraction normally copies or uses a pipeline request; eligible in-place
  extraction can share the dense buffer. This is
  where Sparkles should not follow, since the [paper thread][p-generic] and
  [VIGRA][vigra] argue for strided views, and [mir's `Slice`][mir-algorithm]
  gives them. What does transfer is ITK's separation of three regions: the dataset
  extent, the resident window (a buffer whose start index need not be zero, with signed
  indices) and the requested region. A D view with signed `ptrdiff_t` start indices and
  `size_t` lengths can express all three without ITK's mutable per-object region fields.
- **Q3** — The request pass (`GenerateInputRequestedRegion` padding by a radius, then
  cropping) is run-time bounds inference, comparable to the bounds inference in
  [Halide][halide]. For `sparkles:image` algorithms it suggests that each neighbourhood
  operation declare its footprint as data, so a tiled or streamed caller can compute the
  input window. The boundary-faces split (one unchecked interior loop, checked faces)
  is a cheap, transferable technique for `@nogc` kernels and a candidate for the shared
  algorithm layer [`existing-code.md` G10][bl-existing] calls for.
- **Q3/Q7** — Region splitting with `DynamicThreadedGenerateData(region)` is a simple,
  general parallel contract: a kernel writes only its region. It maps onto
  `sparkles:event-horizon` offload pools ([baseline][bl-eh]) without per-pixel
  synchronisation. The inspected core image loops provide no SIMD dispatch to borrow,
  so the [shaders-SIMD baseline G5][bl-shaders] gap stays open; these loops rely on the
  compiler for vectorisation, which was not measured here.
- **Q4/Q6** — ITK streams by **region**, not by bytes: an IO either reads a requested
  sub-region (raw layouts, HDF5, JPEG 2000) or decodes the whole image. That fits volumes
  and tiled formats on random-access storage, and it is the shape an `io_uring` offset
  read in [`event-horizon`][bl-eh] serves well. It does not answer the suspendable,
  byte-incremental decoding [question 4][survey-questions] asks
  about, and its file-name-based `ImageIOBase` is the opposite of the caller-storage,
  byte-range shape [`existing-code.md` G6 and G7][bl-existing] call for.
- **Q4/Q9** — The `ImageIOBase` split of `ReadImageInformation` (header, no pixels) from
  `Read(buffer)` into caller-sized memory is the transferable part of the plugin layer,
  and it is what an IMG2-style layout pass needs (pixel size without pixels). The
  run-time factory, creating the registered IO instances and probing until one accepts
  the file (extension matches first),
  does not fit `@nogc`, betterC or wasm builds, and D can select codecs at compile time
  instead.
- **Q5** — ITK is a negative result for colour. `RGBPixel` has no space, luminance uses
  fixed 0.30/0.59/0.11 weights, and the inspected PNG/TIFF wrappers supply no typed ICC
  transform pipeline. Default component conversion is assignment. Its
  `MetaDataDictionary` (string keys, type-erased, copy-on-write)
  carries arbitrary tags but no typed model, which confirms rather than closes
  [`existing-code.md` G4 and G5][bl-existing]. The typed, validated spatial fields are the
  part worth copying: they show what "metadata as data with invariants" looks like.
- **Q8** — Three practices transfer to Sparkles' oracle work
  ([`existing-code.md` G11][bl-existing]): tolerance-parameterised image comparison
  (intensity, pixel count, radius, geometry) in the test driver; content-addressed test
  data fetched outside the repository; and a pipeline monitor that asserts streaming
  behaviour. The inspected sources establish neither an ITK fuzz harness nor a
  systematic external oracle to borrow.
- **Q5/Q8** — The **verified** offset-table wrap (2^32 × 2^32 gives a zero element
  count) is a concrete regression case for any Sparkles extent type: the element count
  must be computed with checked `size_t` multiplication and reported as an error, as
  `sparkles.font.png` already reports `arithmeticExhausted` ([baseline][bl-existing]).
- **Q9** — ITK's module split (`ITKCommon` for the image and pipeline, format-specific
  `ITKIO*` modules, filtering modules on top, separate GPU and video modules) is evidence for a
  core/formats/algorithms division. Its cost is visible in the wrapping: the Python
  wheels must choose pixel types and dimensions at build time. Native D callers could
  instantiate generic algorithms directly; foreign-language bindings would still need
  their own type strategy.

---

## Strengths

- Physical space (origin, spacing, direction) is part of every image; the default
  multi-input filter geometry check refuses inputs that differ beyond its tolerances.
- N-D is the native image model; many filters are parameterised by image type and dimension.
- The three-region pipeline limits intermediate memory when its stages support streaming
  and re-executes only the stages a request invalidates; an accumulating output still
  consumes the full output size.
- Neighbourhood filters state their input footprint, so streaming and threading compose
  with boundary handling without per-filter special cases.
- The boundary-faces split keeps interior loops free of bounds checks.
- A broad plugin set of scientific and medical formats behind one header-then-pixels
  protocol.
- Mature regression testing with tolerance-aware image comparison and content-addressed
  data.

## Weaknesses

- No arbitrary spatial strides or transposed buffer views: sub-regions use iterators,
  copies, pipeline requests or eligible in-place extraction. Channel adaptors provide
  views of pixel components.
- Heavy object model: heap allocation, atomic reference counts, virtual hooks and a
  run-time factory for every object, including images.
- Unchecked size arithmetic in the offset table and the reader's buffer size can produce
  undersized counts (verified wrap; codec reachability untested). A failed `SetSpacing`
  can leave the image half-updated (verified with `{-1, 0}`).
- No colour space on `RGBPixel`, fixed luminance weights, and no typed ICC transform
  pipeline in the inspected PNG/TIFF wrappers.
- Streaming is region-granular and synchronous; IOs open files by name and cannot
  suspend or read from caller bytes.
- No general SIMD dispatch identified in the core image loops; vectorisation depends
  on the compiler.
- The GPU path is OpenCL only, off by default, with implicit transfers.
- Template error messages and the wrapped type matrix are recurring usability costs, as
  the in-tree guide states.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                              | Trade-off                                                                                  |
| ------------------------------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Origin, spacing and direction stored on `ImageBase`          | Medical images are samplings of physical space; registration needs it  | Every image carries four N×N matrices, even when a consumer does not use physical geometry |
| Largest possible, buffered and requested regions             | Data larger than memory; compute only what is requested                | Mutable per-object state; region bugs surface as `InvalidRequestedRegionError` at run time |
| Dense buffer, no strides, offsets relative to buffer start   | Dense iteration; buffer can be a window anywhere in index space        | No arbitrary spatial-stride or transposed buffer view; channel adaptors remain available   |
| Demand-driven three-pass pipeline with modified times        | Lazy evaluation, minimal re-execution, streaming by piece              | Explicit `Update()` everywhere; control flow spread across virtual hooks                   |
| Pixel type and dimension as template parameters              | Zero-overhead inner loops, N-D generic algorithms                      | Supported types fixed at build time; wrapping must enumerate them; long compile times      |
| Intrusive `SmartPointer` and factory-created `New()`         | Shared ownership across a pipeline graph; run-time overrides (GPU, IO) | Heap allocation for every object; no value semantics; incompatible with `@nogc`-style code |
| `ImageIOBase` plugins with header and pixel phases           | Uniform reader for dozens of formats; geometry without pixels          | File-name-based, synchronous, whole-image for non-random-access formats                    |
| Region splitting for threads (`DynamicThreadedGenerateData`) | One contract for every filter; threader chosen at run time             | No SIMD guidance; per-work-unit overhead; the classic and dynamic modes coexist            |
| Vendored codec libraries                                     | Format coverage and maturity                                           | Safety depends on codecs and wrappers; no ITK fuzz harness identified outside ThirdParty   |

---

## Sources

- [InsightSoftwareConsortium/ITK][repo] · [documentation][docs] ·
  [ITK Software Guide (PDF)][guide] · [Doxygen API][doxygen]
- Scope and conventions: [`README.md`][readme] · [`AGENTS.md`][agents-pitfalls] ·
  [`Documentation/AI/architecture.md`][arch]
- Image model: [`itkImageBase.h`][imagebase-doc] · [`itkImageBase.hxx`][imagebase-setters] ·
  [`itkImage.h`][image-doc] · [`itkImage.hxx`][image-allocate] ·
  [`itkImportImageContainer.h`][container-import] · [`itkVectorImage.h`][vectorimage-doc] ·
  [`itkRGBPixel.hxx`][rgb-lum] · [`itkDefaultConvertPixelTraits.h`][convtraits] ·
  [`itkIntTypes.h`][inttypes] · [`itkImageAdaptor.h`][adaptor]
- Pipeline: [`itkDataObject.h`][dataobject-doc] · [`itkProcessObject.cxx`][po-propagate] ·
  [`itkImageSource.hxx`][source-gen] · [`itkStreamingImageFilter.hxx`][streaming] ·
  [`itkBoxImageFilter.hxx`][box-request] · [`itkImageToImageFilter.hxx`][i2i-verify]
- Threading: [`itkMultiThreaderBase.h`][mt-enum] · [`itkPoolMultiThreader.cxx`][pool]
- Iteration: [`itkImageRegionConstIterator.h`][region-iter-inc] ·
  [`itkImageBufferRange.h`][buffer-range] · [`itkConstNeighborhoodIterator.h`][nbr-iter] ·
  [`itkImageBoundaryCondition.h`][bc-virtual] · [`itkNeighborhoodAlgorithm.h`][faces]
- Objects: [`itkLightObject.h`][lightobject] · [`itkMacro.h`][newmacro] ·
  [`itkObjectFactory.h`][objfactory] · [`itkMetaDataDictionary.h`][metadict]
- I/O: [`itkImageIOBase.h`][iobase-read] · [`itkImageIOBase.cxx`][iobase-streamable] ·
  [`itkImageIOFactory.cxx`][iofactory] · [`itkImageFileReader.hxx`][reader-read] ·
  [`itkStreamingImageIOBase.h`][streaming-io] · [`itkPNGImageIO.cxx`][png-setjmp]
- GPU, video, testing, wrapping: [`itkGPUImage.h`][gpu-image] ·
  [`itkTemporalDataObject.h`][temporal] · [`itkTestDriverInclude.cxx`][testdriver-cxx] ·
  [`itkPipelineMonitorImageFilter.h`][monitor] · [`PyBuffer.i.in`][pybuffer] ·
  [`WrappingOptions.cmake`][wrapopts]
- Related Sparkles research: [concepts][concepts] · [VIGRA][vigra] ·
  [Halide][halide] · [JuliaImages][juliaimages] · [Boost.GIL][boost-gil] ·
  [mir-algorithm][mir-algorithm] · [generic-image-programming papers][p-generic] ·
  [hostile-input papers][p-hostile] · [existing-code baseline][bl-existing] ·
  [shaders-SIMD baseline][bl-shaders] · [event-horizon baseline][bl-eh]

<!-- References -->

[repo]: https://github.com/InsightSoftwareConsortium/ITK
[docs]: https://docs.itk.org/
[guide]: https://itk.org/ItkSoftwareGuide.pdf
[doxygen]: https://itk.org/Doxygen/html/
[license]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/LICENSE
[version]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/CMake/itkVersion.cmake#L1-L4
[readme]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/README.md#L44-L51
[agents]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/AGENTS.md
[agents-pitfalls]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/AGENTS.md#L31-L35
[arch]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Documentation/AI/architecture.md
[arch-poly]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Documentation/AI/architecture.md#L29-L50
[imagebase-doc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.h#L47-L112
[imagebase-offset]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.h#L351-L399
[imagebase-p2i]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.h#L448-L498
[imagebase-members]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.h#L856-L927
[imagebase-setters]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.hxx#L62-L160
[imagebase-matrices]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.hxx#L163-L178
[imagebase-offsets]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.hxx#L181-L198
[image-doc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImage.h#L34-L98
[image-container]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImage.h#L140-L166
[image-pixel]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImage.h#L207-L244
[image-allocate]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImage.hxx#L37-L64
[container-import]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImportImageContainer.h#L28-L81
[container-alloc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImportImageContainer.hxx#L153-L182
[vectorimage-doc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkVectorImage.h#L32-L56
[vectorimage-rebind]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkVectorImage.h#L170-L201
[vectorimage-get]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkVectorImage.h#L218-L247
[rgb-lum]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkRGBPixel.hxx#L145-L154
[convtraits]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkDefaultConvertPixelTraits.h#L29-L45
[inttypes]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkIntTypes.h#L65-L91
[dataobject-doc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkDataObject.h#L133-L205
[dataobject-update]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/src/itkDataObject.cxx#L289-L295
[po-propagate]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/src/itkProcessObject.cxx#L1464-L1516
[po-release]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/src/itkProcessObject.cxx#L1741-L1771
[source-doc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageSource.h#L257-L304
[source-gen]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageSource.hxx#L184-L262
[mt-enum]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMultiThreaderBase.h#L55-L70
[mt-select]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMultiThreaderBase.h#L201-L216
[mt-parallelize]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMultiThreaderBase.h#L320-L367
[pool]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/src/itkPoolMultiThreader.cxx#L88-L93
[streaming]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkStreamingImageFilter.hxx#L29-L182
[box-request]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Filtering/ImageFilterBase/include/itkBoxImageFilter.hxx#L50-L93
[i2i-verify]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageToImageFilter.hxx#L170-L220
[region-iter-inc]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageRegionConstIterator.h#L28-L262
[buffer-range]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBufferRange.h#L38-L73
[nbr-iter]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkConstNeighborhoodIterator.h#L33-L55
[zfn]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkZeroFluxNeumannBoundaryCondition.h#L26-L58
[bc-virtual]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBoundaryCondition.h#L91-L155
[faces]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkNeighborhoodAlgorithm.h#L28-L62
[lightobject]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkLightObject.h#L118-L166
[newmacro]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMacro.h#L291-L308
[objfactory]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkObjectFactory.h#L56-L65
[metadict]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMetaDataDictionary.h#L30-L67
[iobase-read]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/include/itkImageIOBase.h#L497-L576
[iobase-streamable]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/src/itkImageIOBase.cxx#L1050-L1106
[iofactory]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/src/itkImageIOFactory.cxx#L27-L110
[reader-info]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/include/itkImageFileReader.hxx#L214-L243
[reader-stream]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/include/itkImageFileReader.hxx#L291-L330
[reader-read]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/include/itkImageFileReader.hxx#L382-L440
[streaming-io]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/include/itkStreamingImageIOBase.h#L28-L52
[streaming-io-cxx]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/src/itkStreamingImageIOBase.cxx#L35-L110
[png-setjmp]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/PNG/src/itkPNGImageIO.cxx#L150-L173
[png-scal]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/PNG/src/itkPNGImageIO.cxx#L463-L481
[jpeg-cmyk]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/JPEG/src/itkJPEGImageIO.cxx#L390-L405
[png-tests]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/PNG/test/CMakeLists.txt#L210-L226
[png-cid]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/PNG/test/Input/corrupted.png.cid
[mathdetail]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMathDetail.h#L140-L159
[adaptor]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/ImageAdaptors/include/itkImageAdaptor.h#L28-L56
[gpu-module]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/GPUCommon/itk-module.cmake
[gpu-image]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/GPUCommon/include/itkGPUImage.h#L28-L180
[gpu-dm]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/GPUCommon/include/itkGPUDataManager.h#L90-L166
[temporal]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Video/Core/include/itkTemporalDataObject.h#L32-L62
[testdriver-h]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/TestKernel/include/itkTestDriverInclude.h#L59-L73
[testdriver-cxx]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/TestKernel/src/itkTestDriverInclude.cxx#L181-L340
[monitor]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/TestKernel/include/itkPipelineMonitorImageFilter.h#L28-L60
[pybuffer]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Bridge/NumPy/wrapping/PyBuffer.i.in#L4-L40
[wrapopts]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Wrapping/WrappingOptions.cmake#L30-L256
[p-generic]: ./papers/generic-image-programming.md
[p-hostile]: ./papers/hostile-input-safety.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[hostile-section]: #_5-hostile-input-and-safety
[concept-checks]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkConceptChecking.h#L33-L109
[add-concept]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Filtering/ImageIntensity/include/itkAddImageFilter.h#L103-L106
[tiff-tags]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/TIFF/src/itkTIFFImageIO.cxx#L1049-L1266
[tiff-rgba]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/TIFF/src/itkTIFFImageIO.cxx#L1320-L1336
[convert-gray]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/ImageBase/include/itkConvertPixelBuffer.hxx#L181-L203
[png-corrupt-test]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/IO/PNG/test/itkPNGImageIOTest3.cxx#L26-L51
[pybuffer-input]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Bridge/NumPy/wrapping/PyBuffer.i.in#L64-L122
[boundary-accessor]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkNeighborhoodAccessorFunctor.h#L81-L89
[imagebase-congruence]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkImageBase.hxx#L390-L407
[io-enums]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkCommonEnums.h#L49-L106
[juliaimages]: ./juliaimages.md
[halide]: ./halide.md
[concept-stride]: ./concepts.md#stride
[verified-run]: #a-verified-run
[concept-suspendable]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[boost-gil]: ./boost-gil.md
[concepts]: ./concepts.md
[concept-axes]: ./concepts.md#extent-shape-and-axis-order
[vigra]: ./vigra.md
[concept-pull]: ./concepts.md#push-and-pull-decoding
[survey-questions]: ./index.md#questions-this-survey-answers
[mir-algorithm]: ./mir-algorithm/index.md
[extract-inplace]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkExtractImageFilter.h#L105-L109
[extract-default]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkExtractImageFilter.hxx#L28-L34
[demons-verify]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Registration/PDEDeformable/include/itkDemonsRegistrationFilter.h#L142-L149
[externaldata]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/CMake/ITKExternalData.cmake#L35-L68
[inline-fixture]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Filtering/FastBilateral/test/Input/cake_easy.png
[matrix-inverse]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/Common/include/itkMatrix.h#L328-L337
[ndarray-owner]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Bridge/NumPy/wrapping/PyBuffer.i.init#L4-L14
[gpu-build]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Core/GPUCommon/src/itkGPUKernelManager.cxx#L106-L122
[video-stream]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Video/Core/include/itkVideoStream.h#L28-L42
[video-io]: https://github.com/InsightSoftwareConsortium/ITK/blob/443d201c3b23b94999debefddda8266a177dffea/Modules/Video/IO/include/itkVideoIOBase.h#L50-L71
