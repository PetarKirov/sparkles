# Papers: Generic image programming

Thirty years of generic image libraries say the same thing: write an
algorithm against a small set of capabilities (a domain of sites, a value at
each site, a way to step between sites), keep representation and execution
policy apart from it, and let the compiler pick the specialised path.

| Field              | Value                                                                                                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Thread**         | `generic-image-programming`                                                                                                                                |
| **Scope**          | Concepts, traits and type classes for pixels, views, iterators and ranges; N-D arrays and strided views; functional image models; run-time format dispatch |
| **Entries**        | 27 (22 papers, books or chapters; 2 library design documents; 3 web sources)                                                                               |
| **Last reviewed:** | October 28, 2026                                                                                                                                           |

> [!NOTE]
> Quote page numbers ("p. N") are **PDF page indices** of the local copy,
> counted from the first page of the file, not printed page numbers. Quotes
> from web sources are from the page text as retrieved on October 28, 2026.
> Two entries have no local PDF text to quote (Ritter 1990 has no open PDF;
> the Köthe 2000 PDF has no extractable text), and both say where their quote
> comes from instead.

## Why this thread matters to sparkles

`sparkles:{image,video}` needs one vocabulary that a JPEG decoder, a resampler,
a colour converter and a Vulkan upload path can all share without converting
every frame to a single canonical pixel format. That is the **generic image
abstraction** problem these papers address: what an image _is_ (a function
from a domain to values, a strided block of memory, or both), how algorithms
discover capabilities (direct row access, contiguity, writability), and how
**codec architecture** hands back an image whose pixel type is known only at
run time. The array-language half of the thread (Repa, Accelerate, Halide)
covers **SIMD** and **GPU compute**: delayed and manifest representations,
fusion, and the separation of an algorithm from its schedule, which bears on
`sparkles:shaders` and `shader-compile`. Border handling and bounds checks
matter for **hostile input**, because a decoder's output dimensions are
attacker-controlled. Typed channels (normalised fixed-point, colour-space tags)
are the hook for **colour** correctness. Strides, foreign memory, views
without copies and chunked streams are prerequisites for **storage-to-GPU
I/O** through `event-horizon` and `sparkles:vulkan`.

## Annotated bibliography

### Ritter, Wilson and Davidson 1990: Image algebra: an overview

| Field        | Value                                                                 |
| ------------ | --------------------------------------------------------------------- |
| Authors      | Gerhard X. Ritter, Joseph N. Wilson, Jennifer L. Davidson             |
| Venue/Year   | _Computer Vision, Graphics, and Image Processing_ 49(3):297–331, 1990 |
| DOI or arXiv | [10.1016/0734-189X(90)90106-6][ritter-doi]                            |
| Local PDF    | no open PDF                                                           |
| Open access  | N                                                                     |

**Claim.** Image processing operations can be written in a single algebra in
which an image is a map from a point set (with its own topology) to a value
set (with its own algebra). Operations on images are induced from operations
on the points and on the values, together with generalised templates for
neighbourhood operations. Mathematical morphology and linear convolution
become instances of the same machinery.

**Verbatim quote** (from the University of Florida image-algebra project page,
[`ia-theory.html`][ritter-web], not from the paper):

> Image algebra, on the other hand, models an image as a maps from a set of points drawn from an underlying topological space, into values in an underlying algebraic set.

**Relevance to sparkles.** This is the mathematical root of the
"image = domain → values" definition that Milena, ImgLib2, Pan and Halide all
reuse. For D, it argues for keeping the _domain_ (`Box2`, a mask, a tile set)
and the _value type_ as independent template parameters with their own traits,
so an algorithm can require "values form a lattice" without also requiring
"domain is a dense rectangle".

**Caveats.** No open PDF; the claim rests on the project page and on how later
papers cite it (Milena 2010 explicitly likens its design to an image algebra).
The algebra describes operations; it says nothing about memory layout or
performance.

### Köthe 1999: Reusable software in computer vision

| Field        | Value                                                                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Ullrich Köthe                                                                                                                              |
| Venue/Year   | Chapter 6 in Jähne, Haußecker, Geißler (eds.), _Handbook of Computer Vision and Applications_, vol. 3, Academic Press, 1999 (author draft) |
| DOI or arXiv | none (book chapter)                                                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/koethe1999-reusable-software-in-computer-vision.pdf`                            |
| Open access  | Y (author draft, [Wayback snapshot of the author's page][koethe1999-pdf])                                                                  |

**Claim.** The chapter names the two problems that block reuse in vision code:
flexibility usually costs run time, and reusable components come welded into
frameworks. It extends STL iterators to two dimensions (with explicit rules for
past-the-border positions), adds _data accessors_ that separate "where" from
"how to read or write", and adds traits for meta-information. A benchmark of a
7×7 averaging filter shows the iterator version near hand-written pointer code,
while virtual-call image interfaces are much slower.

**Verbatim quote** (p. 9):

> Therefore, additional interface objects, called data accessors, are needed to encapsulate actual data access (Kühl and Weihe [3]).

**Relevance to sparkles.** Data accessors are what lets one algorithm read
just the red band of an RGB image, or read RGB as grey, without a proxy
reference type. In D, this is a small struct with `get`/`set` (or a
`colorMap`-style lazy view) passed as an alias or template parameter. It
avoids the planar-proxy-reference complexity that GIL later needed, and it
maps directly onto `@nogc` value semantics.

**Caveats.** Benchmarks are on late-1990s compilers and hardware. VIGRA itself
later moved from 2-D iterators toward array views (see the 2012 entry). The
draft may differ from the printed chapter.

### Köthe 2000: STL-style generic programming with images

| Field        | Value                                                                                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------- |
| Authors      | Ullrich Köthe                                                                                                        |
| Venue/Year   | _C++ Report_ 12(1), January 2000; earlier abstract at Dagstuhl Seminar 98171 on Generic Programming (1998)           |
| DOI or arXiv | none                                                                                                                 |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/koethe2000-stl-style-generic-programming-with-images.pdf` |
| Open access  | Y (author copy, [Wayback snapshot][koethe2000-pdf])                                                                  |

**Claim.** VIGRA meets three reuse requirements (no performance loss, strong
support for reusing algorithms, independent combinable components) by applying
STL design principles to images. New iterator categories cover 2-D and cyclic
access, and promotion traits plus data accessors let scalar and multi-band
images share one implementation. The author reports source-size reductions of
up to 90%.

**Verbatim quote** (from the Dagstuhl abstract of the same work on Musser's
[generic programming seminar pages][koethe-dagstuhl]; the local PDF uses
Type 3 fonts and has no extractable text):

> To further decouple our algorithms from the underlying data representations, we have found promotion traits and data accessors extremely useful, because they allow us to treat scalar and multi-spectral (e.g., RGB) images uniformly.

**Relevance to sparkles.** _Promotion traits_ (what type does `u8 + u8`
accumulate into, what does a `u16` blur produce) are an early form of
something D needs explicitly: a `PromoteTraits!(T)`-style template so a
convolution over `ubyte` pixels accumulates in `int` or `float` without
silent wrap-around, which is a correctness and hostile-input concern.

**Caveats.** Claims come from the abstract; the 90% figure is self-reported
and was not replicated independently.

### Köthe 2012: The VIGRA image analysis library

| Field        | Value                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Authors      | Ullrich Köthe                                                                                           |
| Venue/Year   | IPOL 2012 workshop on image-processing libraries (4-page overview)                                      |
| DOI or arXiv | none                                                                                                    |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/koethe2012-vigra-image-analysis-library.pdf` |
| Open access  | Y ([IPOL][vigra-ipol])                                                                                  |

**Claim.** A retrospective on 15 years of VIGRA. The original 2-D iterators
(`++i.x`, `i.y += 5`) did not generalise to N dimensions, so VIGRA added
hierarchical iterators and then `MultiArrayView` with Matlab-style slicing,
which implementers preferred. The paper also notes that abstraction penalties
that mattered ten years earlier had been removed by better compilers.

**Verbatim quote** (p. 1):

> Multidimensional arrays provide two abstract interfaces – hierarchical iterators and array views – and the latter turned out to be much more convenient for algorithm implementers.

**Relevance to sparkles.** This is first-hand evidence from the main
iterator-based image library: build the generic layer on **N-D views** (shape,
strides, element pointer), with iterators derived from them, not on 2-D
iterators. D slices and Mir's `Slice` already lean this way.

**Caveats.** A short self-report without measurements. VIGRA is C++03-era, and
its keyword-argument option objects predate C++ designated initialisers (D has
named arguments).

### Bourdev and Jin 2006: Generic Image Library design guide

| Field        | Value                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------- |
| Authors      | Lubomir Bourdev, Hailin Jin (Adobe Systems)                                                  |
| Venue/Year   | Adobe Open Source technical documentation, version 1.0, May 5, 2006 (became `Boost.GIL`)     |
| DOI or arXiv | none                                                                                         |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/bourdev2006-gil-design-guide.pdf` |
| Open access  | Y ([stlab.adobe.com][gil-guide])                                                             |

**Claim.** GIL separates image representation from algorithms across five
axes: planar or interleaved layout, colour space and alpha, channel depth,
channel order, and row alignment. Each layer is a C++ concept (channel, colour
space, pixel, pixel iterator, locator, view, image), and an image view is an
N-D generalisation of an STL range that does not own its data. A
`dynamic_image` extension wraps a fixed set of image types in `any_image` so
that file I/O can return a run-time-typed image and dispatch to a compiled
instantiation.

**Verbatim quote** (p. 20):

> An image view is a generalization of STL's range concept to multiple dimensions. Similar to ranges (and iterators), image views are shallow, don't own the underlying data and don't propagate their constness over the data.

**Relevance to sparkles.** This is the most direct blueprint for a D
`isImageView` capability family. The five representation axes become
compile-time parameters of a `Pixel`/`View` template. Planar pixels need proxy
references in C++; in D, a planar view can expose `opIndex` returning a small
value struct plus `opIndexAssign`, which avoids most of the proxy problem. The
`any_image` pattern is exactly what a decoder needs: a `SumType` over the
pixel formats the codec can emit, with `match` dispatching once per image, not
once per pixel.

**Caveats.** It is a design guide, not a peer-reviewed paper. It is written in
pre-C++11 pseudo-concepts. Combinatorial `any_image` sets cause code bloat
(see Bourdev and Järvi 2011). Later `Boost.GIL` versions changed some APIs.

### Bourdev 2007: Generic Image Library

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Lubomir Bourdev (the text credits development of the library to Bourdev and Hailin Jin)           |
| Venue/Year   | Author manuscript, 2007 (the text says the library is "planned for inclusion in Boost 1.35.0")    |
| DOI or arXiv | none                                                                                              |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/bourdev2007-generic-image-library.pdf` |
| Open access  | Y ([author PDF][gil-2007])                                                                        |

**Claim.** A tutorial-length account of GIL for practitioners. It motivates
the representation axes with concrete cases (interleaved versus planar, a
16-bit 565 RGB pixel whose channels have different bit widths, video formats
that share channels across pixels), then shows composable views
(`subsampled_view`, `rotated180_view`, `nth_channel_view`) and a _virtual_
view whose pixels come from a function object. For run-time formats,
`any_image` instantiates an algorithm for every type in a declared set and
selects one per call; dynamic views deliberately do not allow per-pixel
access. Generic algorithms carry performance overloads: `copy_pixels` becomes
`memmove` for two contiguous interleaved views, one `memmove` per plane for
planar views, and one per row when rows are padded.

**Verbatim quote** (p. 9):

> Thus, the polymorphic check is performed only once per call to the algorithm. Since image algorithms typically run in time at least linear on the number of pixels, such a constant overhead results in no measurable effect on performance.

Second quote (p. 9):

> When invoked for two contiguous interleaved views, copy_pixels resolves to memmove.

**Relevance to sparkles.** This fixes the cost model for the decoder front
door: a run-time pixel format costs one dispatch per algorithm call, never one
per pixel, so a D `SumType` of views should expose whole-image operations and
no per-pixel `opIndex`. The `copy_pixels` overload ladder (contiguous, then
per plane, then per row, then the generic loop) is the shape a D `copy` facade
should have, selected by `static if` on contiguity traits. The virtual view
shows the functional (Pan) model fitting inside the same view concept as
stored images.

**Caveats.** No formal venue or peer review; the date comes from the
document itself and is not otherwise confirmed. Performance evidence is
argument and assembly comparison, not benchmarks. Nothing addresses GPU
buffers or hostile headers.

### Bourdev and Järvi 2011: Efficient run-time dispatching in generic programming with minimal code bloat

| Field        | Value                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------- |
| Authors      | Lubomir Bourdev, Jaakko Järvi                                                                             |
| Venue/Year   | _Science of Computer Programming_ 76(4):243–257, 2011 (received 2007, online 2008)                        |
| DOI or arXiv | [10.1016/j.scico.2008.06.003][bourdev-jarvi-doi]                                                          |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/bourdev2011-efficient-runtime-dispatching.pdf` |
| Open access  | Y (Elsevier open archive)                                                                                 |

**Claim.** C++ templates need exact types at compile time, so the paper gets
run-time polymorphism by instantiating a generic algorithm over a
comprehensive, closed set of parameter types and choosing the instantiation at
run time. Done naively this causes template bloat, because many of the
instantiations are identical at the assembly level, and multi-argument
algorithms multiply the count. The fix is _type reduction_: for each algorithm,
a `reduce` metafunction partitions the types into equivalence classes and only
one representative per class is instantiated; binary algorithms first reduce
each argument on its own (pre-reduction) and then reduce the pair. In GIL this
cut executable sizes by up to 70%. Type reduction relies on an unchecked cast
between a type and its representative.

**Verbatim quote** (p. 2):

> In C++ all template instantiations, and code generation that they trigger, occur at compile time—dynamic dispatching to templated functions is not (directly) supported.

Second quote (p. 1):

> We observed a notable reduction, up to 70% at times, in executable sizes of our test programs.

**Relevance to sparkles.** A D decoder returning
`SumType!(Image!RGB8, Image!RGBA16, …)` and a two-argument `match` over
source × destination grows quadratically. The lesson for D is to canonicalise
before instantiating: a per-algorithm `Reduce!(Op, T)` template maps pixel
formats to _layout-equivalent_ representatives (bytes per pixel, channel
count, planar or not), so memory-only algorithms such as copy, crop and flip
are instantiated once per representative. In D, `static foreach` over an
`AliasSeq` builds the dispatch table. The paper's unchecked cast becomes a
`@trusted` reinterpretation, justified by a `static assert` that the two
layouts are identical.

**Caveats.** C++ MPL machinery with no direct D equivalent. Code-size numbers
are compiler- and era-specific. The closed type set means an unlisted format
must be rejected by the decoder's format validation, not silently converted.

### Levillain, Géraud and Najman 2009: Milena: write generic morphological algorithms once, run on many kinds of images

| Field        | Value                                                                                                                 |
| ------------ | --------------------------------------------------------------------------------------------------------------------- |
| Authors      | Roland Levillain, Thierry Géraud, Laurent Najman                                                                      |
| Venue/Year   | ISMM 2009, LNCS 5720, pp. 295–306                                                                                     |
| DOI or arXiv | [10.1007/978-3-642-03613-2_27][milena09-doi]                                                                          |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/levillain2009-milena-generic-morphological-algorithms.pdf` |
| Open access  | Y ([LRE author copy][milena09-pdf])                                                                                   |

**Claim.** An image is defined as a function from a domain of _sites_ (points,
graph vertices, complex faces) to a value set, supplemented by orthogonal
traits for topology, value-set properties and neighbourhoods. The same
`dilation` code then runs on 2-D grids, graphs and simplicial complexes.
Specialised fast paths are chosen by static dispatch on properties, not on
concrete types.

**Verbatim quote** (p. 9):

> instead of dispatching with respect to types, it dispatches with respect to one or several properties attached to one or several types [21].

**Relevance to sparkles.** This is Design by Introspection described in C++
terms. In D, a generic `fill`/`copy`/`convolve` should test capabilities
(`hasContiguousRows!V`, `isWritableView!V`, `hasSupremum!(ViewColor!V)`) with
`static if` and choose a scanline or SIMD path, never a list of concrete
types. Restriction (`ima | mask`) as a lazy view is a cheap, safe way to apply
an operation to a region of interest of untrusted size.

**Caveats.** Morphology-centred; few performance numbers. Milena's C++
SCOOP/`exact()` machinery is heavy, and D gets the same effect with
templates and `static if`.

### Levillain, Géraud and Najman 2010: Why and how to design a generic and efficient image processing framework: the case of the Milena library

| Field        | Value                                                                                                                      |
| ------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Roland Levillain, Thierry Géraud, Laurent Najman                                                                           |
| Venue/Year   | IEEE ICIP 2010, pp. 1941–1944                                                                                              |
| DOI or arXiv | [10.1109/ICIP.2010.5649620][milena10-doi]                                                                                  |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/levillain2010-generic-efficient-image-processing-framework.pdf` |
| Open access  | Y ([LRE author copy][milena10-pdf])                                                                                        |

**Claim.** The paper lists the parts of a generic image-processing library:
concepts (Image, Site, Value, Neighbourhood, more than 40 in all) with
associated types, models, _properties_ attached to models, algorithms written
against concepts, and syntactic sugar. Efficiency comes from static
genericity, with costs paid at compile time, plus property-based selection of
specialised implementations, for example pointer loops over a linear buffer.

**Verbatim quote** (pp. 3–4, the sentence crosses the page break):

> Each algorithm facade may inspect its inputs’ properties and use them to possibly select an implementation more efficient than the generic one.

**Relevance to sparkles.** This is a template for module layout: a facade
function per algorithm that dispatches on view properties to a fast
implementation (`fillContiguous`, `fillStrided`, `fillGeneric`). Its 2010 list
of requirements (generic, modular, efficient, easy to use, close to theory,
handles gigabyte inputs, reproducible) is a useful acceptance checklist for
the `sparkles:image` spec.

**Caveats.** A 4-page position paper with no benchmarks.

### Pietzsch, Preibisch, Tomančák and Saalfeld 2012: ImgLib2: generic image processing in Java

| Field        | Value                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------- |
| Authors      | Tobias Pietzsch, Stephan Preibisch, Pavel Tomančák, Stephan Saalfeld                         |
| Venue/Year   | _Bioinformatics_ 28(22):3009–3011, 2012 (applications note)                                  |
| DOI or arXiv | [10.1093/bioinformatics/bts543][imglib2-doi]                                                 |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/pietzsch2012-imglib2-generic.pdf` |
| Open access  | Y (CC BY 3.0)                                                                                |

**Claim.** ImgLib2 rests on three concepts: _accessibles_ (images, defined as
any mapping from a subset of n-dimensional space to a pixel type, with integer
or real coordinates and bounded or infinite domains), _accessors_ (iterating
or random-access cursors, with iteration order chosen per memory layout), and
_types_ (a hierarchy of algebraic interfaces such as `NumericType`). Storage is
pluggable: `ArrayImg` uses one primitive array, `CellImg` splits the domain
into cells to pass Java's 2³¹-element array limit. Views do slicing, windowing,
axis permutation, 90° rotation and affine transforms without copying, and
_extending_ views generate out-of-bounds values (padding, mirroring) on
demand. Generic code matches special-purpose code on simple per-pixel
operations and is on average 1.6 times slower on an operation with an inner
loop over an unknown number of dimensions.

**Verbatim quote** (p. 3):

> The core paradigm is a clean separation of pixel algebra (how sample values are manipulated), data access (how sample coordinates are traversed) and data representation (how the samples are stored, laid out in memory or paged to disc).

Second quote (p. 2):

> This is achieved by extending views, whose accessors generate outside values on demand.

**Relevance to sparkles.** The three-way split maps onto D directly: pixel
algebra is the pixel type and its traits, data access is the view and cursor
traits, and data representation is the storage (`sparkles.base.buffer`,
mapped files, tiled cells). Extending views are the border mechanism expressed
as a view wrapper, so a filter kernel never clamps coordinates itself; paired
with the Lippmeier and Keller interior/border split, only the border region
pays for the extension. The measured 1.6× cost of a dimension-generic inner
loop says where D should specialise: make the rank a template parameter in hot
kernels and keep run-time rank only at composition boundaries. Cell storage is
the model for tiled codec output and for images too large for one allocation.

**Caveats.** A 3-page note; the benchmark table is in the supplementary data.
Performance parity depends on the Java JIT inlining proxy types, which does
not carry over literally to ahead-of-time D. Bioimaging workloads, not video
rates or untrusted input.

### Elliott, Finne and de Moor 2000: Compiling embedded languages

| Field        | Value                                                                                                       |
| ------------ | ----------------------------------------------------------------------------------------------------------- |
| Authors      | Conal Elliott, Sigbjørn Finne, Oege de Moor                                                                 |
| Venue/Year   | SAIG 2000, LNCS 1924, pp. 9–26; extended version in _Journal of Functional Programming_ 13(3):455–481, 2003 |
| DOI or arXiv | [10.1007/3-540-45350-4_5][elliott00-doi] (SAIG); [10.1017/S0956796802004574][elliott00-jfp-doi] (JFP)       |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/elliott2000-compiling-embedded-languages.pdf`    |
| Open access  | Y ([conal.net][elliott00-pdf], SAIG version)                                                                |

**Claim.** An embedded domain-specific language need not be interpreted: if
its primitives build syntax through smart constructors that rewrite as they
construct, the host program becomes an optimising compiler that is almost as
simple to write as an interpreter. Pan, the image-synthesis language, is the
demonstration. Full inlining creates large redundant expression trees (the
paper's `swirling` example replicates the same distance computation many
times), so the compiler adds common-subexpression elimination and hoists
loop-invariant code. Pan's first compiler generated a per-pixel function, and
that was not fast enough; the fix was to expose the 2-D sampling loop to the
optimiser.

**Verbatim quote** (p. 10):

> While this version was much faster than an interpretive implementation, its efficiency was not satisfactory. For one thing, it requires a function call per pixel. More seriously, it prevent any optimization across several pixels or rows of pixels.

Second quote (p. 6):

> In our experience with Pan, the trees resulting from inlining and simplification tend to be enormous, compared to their underlying representation as graphs.

**Relevance to sparkles.** The functional image model and a fast
implementation are separate deliverables. A D image view that is only an
opaque `(x, y) => pixel` delegate repeats Pan's first compiler: one call per
pixel and no optimisation across rows. Composed views should therefore be
inspectable types that the compiler inlines into a row loop, with a scanline
primitive exposed wherever a view can provide it. The tree-blow-up result
warns that nested lazy views can recompute shared inputs, which is a reason to
give materialisation points explicit names. For GPU paths, the same staging
problem belongs to `sparkles:shaders` and `shader-compile`, where D kernels are
lowered to SPIR-V.

**Caveats.** The local PDF is the workshop version; the journal version is
longer. The technique targets a Haskell embedding that generates C, and it
says nothing about strided storage or untrusted extents.

### Elliott 2001: Functional image synthesis

| Field        | Value                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------ |
| Authors      | Conal Elliott                                                                                          |
| Venue/Year   | Bridges 2001 (Mathematical Connections in Art, Music, and Science)                                     |
| DOI or arXiv | none                                                                                                   |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/elliott2001-functional-image-synthesis.pdf` |
| Open access  | Y ([conal.net][elliott-bridges])                                                                       |

**Claim.** A short, example-driven introduction to Pan for a general
audience. Images are functions from the plane to colours, regions are boolean
images, and spatial transforms, masking and blending are function composition.
It states the inverse-mapping rule explicitly: transforming an image means
transforming its sample points backwards.

**Verbatim quote** (p. 11):

> In general, to transform an image, we must inversely transform sample points before feeding them to the image being transformed:

**Relevance to sparkles.** The inverse-mapping rule fixes the direction of
every geometric operation (resize, rotate, lens correction): a D `warp` view
maps output coordinates back to source coordinates. Using the same convention
in shader code makes CPU and GPU resampling agree.

**Caveats.** The author's page notes that its technical content is a subset of
the 2003 chapter. No memory model and no performance data.

### Elliott 2003: Functional images

| Field        | Value                                                                                                    |
| ------------ | -------------------------------------------------------------------------------------------------------- |
| Authors      | Conal Elliott                                                                                            |
| Venue/Year   | Chapter 7 in Gibbons and de Moor (eds.), _The Fun of Programming_, Palgrave Macmillan, 2003, pp. 131–150 |
| DOI or arXiv | [10.1007/978-1-349-91518-7_7][elliott03-doi]                                                             |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/elliott2003-functional-images.pdf`            |
| Open access  | Y ([conal.net][elliott-fop])                                                                             |

**Claim.** In Pan, an image is `Point → Colour` over continuous, infinite 2-D
space, and a region is `Image Bool`. Spatial transforms, masking, blending and
reconstructing a bitmap (bilinear interpolation plus a crop) are all function
composition. The model is polymorphic in both pixel and domain type.

**Verbatim quote** (p. 9):

> Pan’s model of images is simply functions from infinite, continuous 2D space to colours with partial opacity.

**Relevance to sparkles.** This model is the right semantics for _procedural_
and _resampling_ views: a D `procedural!((x, y) => …)` view is Pan restricted
to an integer or float lattice. It also gives a per-pixel reference semantics
that SIMD and shader implementations can be tested against.

**Caveats.** There is no memory model, and continuous infinite images hide
sampling and aliasing decisions that a real pipeline must make explicitly.
Pan's own implementation is covered by Elliott, Finne and de Moor 2000.

### Stepanov and McJones 2009: Elements of Programming (chapters 1, 6, 7)

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | Alexander Stepanov, Paul McJones                                                                     |
| Venue/Year   | Addison-Wesley 2009; authors' free PDF edition, Semigroup Press 2019                                 |
| DOI or arXiv | none (2019 edition ISBN 978-0-578-22214-1)                                                           |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/stepanov2009-elements-of-programming.pdf` |
| Open access  | Y ([elementsofprogramming.com][eop])                                                                 |

**Claim.** The book defines programming concepts axiomatically: regular types,
then `Readable` (a `source` function), `Iterator` (`successor`), and the
forward, indexed, bidirectional and random-access refinements, with bounded
and counted ranges as the interface currency. Chapter 7 generalises iteration
to _coordinate structures_ such as bifurcate coordinates, beyond linear
sequences. The authors require that reading through an iterator cost about as
much as dereferencing a pointer.

**Verbatim quote** (p. 102):

> Accessing data by calling source on an object of a readable type is as fast as any other way of accessing this data.

**Relevance to sparkles.** This is the cost contract for a pixel accessor: a
view's `opIndex` or row slice must compile to a load. It is the measurable
"zero-cost" claim the `sparkles:image` spec should test (for example,
`i[x, y]` against `i.hflip.hflip[x, y]` producing identical code). Counted
ranges (`f`, `n`) match how decoders produce rows: a pointer and a known count.
Concepts here are syntax _plus axioms_; a D trait such as `isImageView` checks
only the syntax, so the axioms need documenting and testing separately.

**Caveats.** General-purpose rather than image-specific. Multidimensional
coordinate structures are only sketched.

### Keller et al. 2010: Regular, shape-polymorphic, parallel arrays in Haskell (Repa)

| Field        | Value                                                                                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------- |
| Authors      | Gabriele Keller, Manuel M. T. Chakravarty, Roman Leshchinskiy, Simon Peyton Jones, Ben Lippmeier                     |
| Venue/Year   | ICFP 2010, pp. 261–272 (also _SIGPLAN Notices_ 45(9))                                                                |
| DOI or arXiv | [10.1145/1863543.1863582][repa-doi]                                                                                  |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/keller2010-regular-shape-polymorphic-parallel-arrays.pdf` |
| Open access  | Y ([Chalmers course copy][repa-pdf])                                                                                 |

**Claim.** Repa gives Haskell rank-generic arrays whose shapes are snoc-lists
(`Z :. Int :. Int`) indexed through type classes and families. Slices are
type-safe, and functions can carry "at least rank n" constraints. Arrays are
either _manifest_ (unboxed memory) or _delayed_ (a shape plus an index
function), so pipelines fuse by composing index functions, and `force`
materialises an array where layout or sharing pays off. Reported performance
is close to C and scales to 8 cores.

**Verbatim quote** (p. 3):

> By forcing transpose2D to produce its result as an unboxed array in memory —we call this a manifest array— instead of leaving it as a delayed array, the code will traverse both matrices by iterating over the second index in the inner loop.

**Relevance to sparkles.** The delayed/manifest split is the core decision for
a D image pipeline. Lazy views (warp, colour map, crop) are delayed; `Image!T`
and decoder output are manifest; an explicit `materialize` (`force`) is where
the user pays for memory to gain locality. Shape-rank polymorphism maps onto
`Slice!(It, N)` with `N` as a template parameter. The sequel (Repa 3) shows
that the user, not the optimiser, should choose where to force.

**Caveats.** Haskell-specific fusion relies on GHC inlining. Its performance
figures come from 2010 multicores. The representation was redesigned in Repa 3
(see below).

### Lippmeier and Keller 2011: Efficient parallel stencil convolution in Haskell

| Field        | Value                                                                                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------- |
| Authors      | Ben Lippmeier, Gabriele Keller                                                                                       |
| Venue/Year   | Haskell Symposium 2011, pp. 59–70                                                                                    |
| DOI or arXiv | [10.1145/2034675.2034684][stencil-doi]                                                                               |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/lippmeier2011-efficient-parallel-stencil-convolution.pdf` |
| Open access  | Y ([Microsoft Research copy][stencil-pdf])                                                                           |

**Claim.** Image-style stencil convolution in Repa reaches performance close to
OpenCV through two representations. _Partitioned_ arrays split the result into
an interior region and border regions, each with its own element function.
_Cursored_ arrays let adjacent stencil reads share index arithmetic. The paper
lists the costs a naive version pays: a border test on every pixel and a bounds
check on every read.

**Verbatim quote** (p. 4):

> In effect, partitioning the array allows us to lift the if-expression that tests for the border out of the main loop of our program, and have the library code construct the border and internal regions separately.

**Relevance to sparkles.** This is directly relevant to safe, fast filters. A
D `convolve` should split the output into interior and border rectangles. The
interior runs the unchecked (or SIMD) kernel, justified by a single bounds
proof per region; the border runs a clamped or mirrored kernel. This keeps
`@safe` bounds checks out of the hot loop without `@trusted` per-pixel code,
and it is the same split a compute shader uses with a guard band.

**Caveats.** Benchmarks predate AVX-512 and GPU stencils. The paper names two
common border policies (a constant value, or the nearest in-bounds element),
and its code sketch shows a `Boundary` type with `BoundConst` and `BoundWrap`;
it does not evaluate border modes against each other. Some copies of the PDF
list Simon Peyton Jones as a third author; Crossref lists two.

### Lippmeier et al. 2012: Guiding parallel array fusion with indexed types (Repa 3)

| Field        | Value                                                                                                       |
| ------------ | ----------------------------------------------------------------------------------------------------------- |
| Authors      | Ben Lippmeier, Manuel M. T. Chakravarty, Gabriele Keller, Simon Peyton Jones                                |
| Venue/Year   | Haskell Symposium 2012, pp. 25–36                                                                           |
| DOI or arXiv | [10.1145/2364506.2364511][repa3-doi]                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/lippmeier2012-guiding-parallel-array-fusion.pdf` |
| Open access  | Y ([Microsoft Research copy][repa3-pdf])                                                                    |

**Claim.** Repa 1 and 2 hid the manifest/delayed distinction behind a run-time
tag, so indexing tested the representation inside inner loops, and users
needed expert knowledge to get fast code. Repa 3 moves the representation into
a type index: `D`, `C`, `U`, `V`, `B` and `F` (foreign buffers), plus meta
indices `P`, `S`, `I` and `X`. The cost model becomes visible in source code,
and the set of representations stays open, which makes interop with Accelerate
and with OS-provided buffers possible.

**Verbatim quote** (p. 2):

> Tantalisingly, the representation of an array at a particular program point does not change from run to run. The programmer always knows which representation is expected — but, in Repa 1 & 2 they lack a convenient way to express that knowledge.

**Relevance to sparkles.** This argues strongly against a run-time-tagged
`Image` class in D. The representation (owned GC/heap, borrowed slice, mmap'd
file, GPU-mapped staging buffer, lazy view) should be a template parameter
that callers can see. A `Foreign` representation corresponds to wrapping an
`io_uring`-filled or Vulkan-mapped buffer as a view with no copy, which is the
storage-to-GPU path.

**Caveats.** Haskell type-index machinery; the D equivalent is just struct
templates. Benchmarks are GHC-specific.

### Chakravarty et al. 2011: Accelerating Haskell array codes with multicore GPUs (Accelerate)

| Field        | Value                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------- |
| Authors      | Manuel M. T. Chakravarty, Gabriele Keller, Sean Lee, Trevor L. McDonell, Vinod Grover                            |
| Venue/Year   | DAMP 2011 (with POPL), pp. 3–14                                                                                  |
| DOI or arXiv | [10.1145/1926354.1926358][acc-doi]                                                                               |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/chakravarty2011-accelerating-haskell-array-codes.pdf` |
| Open access  | Y ([Wayback snapshot of the author PDF][acc-pdf])                                                                |

**Claim.** Accelerate is an embedded array language whose collective
operations (`map`, `zipWith`, `fold`, `permute`, `backpermute`, …) are
algorithmic skeletons, instantiated as CUDA code at run time and cached. The
type system separates host arrays (`Array sh e`) from device computations
(`Acc (Array sh e)`), and collective operations (`Acc`) from scalar ones
(`Exp`). Because scalar code cannot contain collective operations, nested
parallelism is excluded and GPU code stays flat.

**Verbatim quote** (p. 2):

> Accelerate distinguishes the types of collective and scalar computations —Acc and Exp— to achieve a stratified language.

**Relevance to sparkles.** For `sparkles:shaders`, this suggests a two-level
vocabulary: per-pixel kernels (the D functions compiled to SPIR-V by
`shader-compile`, the equivalent of `Exp`) and collective dispatches over
images (`map`, `stencil`, `reduce`, the equivalent of `Acc`). The host/device
distinction should be in the type, so an upload or readback is explicit and
can be scheduled by `event-horizon`. Skeleton instantiation with a binary
cache is the same problem as pipeline caching for SPIR-V.

**Caveats.** CUDA-only at publication; later work moved to LLVM PTX and other
back-ends. Run-time code generation latency matters for interactive use. The
benchmarks predate modern GPUs, and fusion was left to later work (McDonell et
al. 2013).

### McDonell et al. 2013: Optimising purely functional GPU programs

| Field        | Value                                                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| Authors      | Trevor L. McDonell, Manuel M. T. Chakravarty, Gabriele Keller, Ben Lippmeier                                           |
| Venue/Year   | ICFP 2013, pp. 49–60                                                                                                   |
| DOI or arXiv | [10.1145/2500365.2500595][mcdonell-doi]                                                                                |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/mcdonell2013-optimising-purely-functional-gpu-programs.pdf` |
| Open access  | Y ([UNSW repository][mcdonell-pdf])                                                                                    |

**Claim.** Naive compilation of embedded array programs causes code explosion
and too many intermediate arrays. The paper adds _sharing recovery_ (without
it, a let-bound value is recomputed at every use) and _array fusion_ to
Accelerate. Fusion classifies operations as _producers_, where each output
element depends on one input element (`map`, `zipWith`, `backpermute`,
`generate`, …), or _consumers_, where it depends on several (`fold`, `scan`,
`permute`, `stencil`). Producers are fused into producers as an AST rewrite,
and producers are fused into consumers during code generation by specialising
the consumer skeleton. A producer whose result is used more than once is left unfused.
In the Canny edge-detection benchmark the data-parallel phases are slightly
slower than OpenCV, because every stencil read is bounds-checked.

**Verbatim quote** (p. 6):

> To support the different properties of producers and consumers, our fusion transform is split into two distinct phases:

Second quote (p. 10):

> This is as our implementation of stencil convolution in Accelerate checks whether each access to the source array is out of bounds, and must have boundary conditions applied.

**Relevance to sparkles.** The producer/consumer split is the rule a D view
library can follow without a fusion pass: element-wise views (colour map,
channel swap, warp with a pure index function) compose freely as lazy views,
while operations that read many inputs per output (stencils, reductions,
scatter) are where the pipeline materialises or inlines its producers. The
same split governs kernel generation in `sparkles:shaders` and
`shader-compile`: a chain of producers becomes one kernel, and a consumer
takes it as its input function. The Canny result is independent evidence for
the Lippmeier and Keller interior/border split, which the paper itself names
as the fix.

**Caveats.** CUDA back-end with run-time compilation; 2013 GPU baselines.
Sharing recovery exists because of the Haskell embedding; a D library with
explicit, named buffers avoids most of that problem.

### Madsen et al. 2015: Functional array streams

| Field        | Value                                                                                                          |
| ------------ | -------------------------------------------------------------------------------------------------------------- |
| Authors      | Frederik M. Madsen, Robert Clifton-Everest, Manuel M. T. Chakravarty, Gabriele Keller                          |
| Venue/Year   | FHPC 2015 (ACM SIGPLAN Workshop on Functional High-Performance Computing), pp. 23–34                           |
| DOI or arXiv | [10.1145/2808091.2808094][madsen-doi]                                                                          |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/madsen2015-functional-array-streams.pdf` (preprint) |
| Open access  | N (publisher copy; the local file is an author preprint)                                                       |

**Claim.** Aggregate array languages assume every array is resident, which
limits data sets to GPU memory. The paper adds _sequences_ to Accelerate: a
`Seq` level above `Acc`, built by slicing an array (`toSeq` with a `Split`/`All`
division per dimension) or by streaming a host list, and consumed by sequence
maps and folds (`mapSeq`, `foldSeqE`, `collect`). A sequence is traversed in
order and an element cannot be revisited once the next is computed, so the
runtime may evaluate it one array at a time, all at once, or in chunks sized
to the hardware. Algorithms that permute or reduce non-linearly cannot be
written as sequences, and exposing the sequential structure is the
programmer's job.

**Verbatim quote** (p. 3):

> As sequences can only be accessed linearly, any algorithm which relies on permuting or reducing an array in a non-linear way, cannot be expressed as a sequence. It is the responsibility of the programmer, not the compiler, to expose inherent sequentialism.

**Relevance to sparkles.** This is the generic-programming answer to
storage-to-GPU streaming: frames and large images flow as a sequence of row
bands or tiles from `io_uring` reads through decode, colour conversion and
Vulkan upload, without whole-frame residency baked into every algorithm. In D
this is a range of chunk views over the per-chunk view concepts, with chunk
size chosen by memory and transfer limits rather than by the algorithm, and
with `event-horizon` scheduling the reads and uploads. Global operations
(histograms, two-pass filters) must be written as explicit folds over the
stream, and the pipeline type should make that visible.

**Caveats.** Single-GPU CUDA prototype. Chunking is regular; the variable-size,
dependency-shaped tile streams of real video codecs are outside the model, and
there is no analysis of adversarial extents.

### Ragan-Kelley et al. 2013: Halide

| Field        | Value                                                                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Jonathan Ragan-Kelley, Connelly Barnes, Andrew Adams, Sylvain Paris, Frédo Durand, Saman Amarasinghe                                             |
| Venue/Year   | PLDI 2013, pp. 519–530 ("Halide: a language and compiler for optimizing parallelism, locality, and recomputation in image processing pipelines") |
| DOI or arXiv | [10.1145/2491956.2462176][halide-doi]                                                                                                            |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/ragankelley2013-halide.pdf`                                                           |
| Open access  | Y ([author copy][halide-pdf])                                                                                                                    |

**Claim.** In Halide, images are pure functions over an infinite integer
domain, and pipelines are chains of such functions plus bounded reductions.
_How_ to compute them (tiling, vectorisation, parallelism, and where each
stage is stored and computed relative to its consumers) is a separate
_schedule_. The [`dsl-scheduling`][dsl-scheduling] thread covers the paper in
full; it appears here for its image model.

**Verbatim quote** (p. 3):

> Also, since functions are defined over an infinite domain, boundary conditions can be handled safely and efficiently by computing arbitrary guard bands of extra values as needed.

**Relevance to sparkles.** Halide's image is Pan's model restricted to an
integer lattice, and its guard bands are the border mechanism of ImgLib2's
extending views computed ahead of time. At a minimum, `sparkles:image` should
keep algorithm and schedule apart in its API, so that fusion and tiling can be
added later without changing call sites.

**Caveats.** See [`dsl-scheduling`][dsl-scheduling] for the schedule and
autotuning results and their costs.

### van der Walt, Colbert and Varoquaux 2011: The NumPy array: a structure for efficient numerical computation

| Field        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Authors      | Stéfan van der Walt, S. Chris Colbert, Gaël Varoquaux                                      |
| Venue/Year   | _Computing in Science & Engineering_ 13(2):22–30, 2011                                     |
| DOI or arXiv | [10.1109/MCSE.2011.37][numpy11-doi]; [arXiv:1102.1523][numpy11-arxiv]                      |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/vanderwalt2011-numpy-array.pdf` |
| Open access  | Y (arXiv)                                                                                  |

**Claim.** An `ndarray` is a data pointer, a dtype, a shape and byte strides.
Slicing, transposition and broadcasting only rewrite shape and strides, so they
create views without copying. Performance comes from vectorising, avoiding
copies and minimising operation counts. `__array_interface__` lets foreign
buffers be wrapped without copying.

**Verbatim quote** (p. 1):

> Underneath the hood, a NumPy array is really just a convenient way of describing one or more blocks of computer memory, so that the numbers represented may be easily manipulated.

**Relevance to sparkles.** Byte strides (not element strides) are what let a
view describe a `BGRX` buffer as three planes, a row-padded decoder output, or
a Vulkan linear-tiled image with a driver-chosen `rowPitch`. The D view type
should store byte strides, or at least allow them, and should take an existing
buffer without copying, the analogue of `__array_interface__`. This is what
makes imports from `wired` or `event-horizon` buffers cheap.

**Caveats.** Python-centric. Byte strides allow misaligned or overlapping
views, so a `@safe` D API must validate stride × extent against the backing
length once, at view construction.

### Harris et al. 2020: Array programming with NumPy

| Field        | Value                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Authors      | Charles R. Harris, K. Jarrod Millman, Stéfan J. van der Walt, Ralf Gommers, and 22 others               |
| Venue/Year   | _Nature_ 585:357–362, 2020                                                                              |
| DOI or arXiv | [10.1038/s41586-020-2649-2][numpy20-doi]                                                                |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/harris2020-array-programming-with-numpy.pdf` |
| Open access  | Y (CC BY)                                                                                               |

**Claim.** The paper reviews the array model (data type, shape, strides, views,
broadcasting, vectorisation) and NumPy's evolution into an interoperability
layer. Array _protocols_ (`__array_function__` and related) let CuPy (GPU),
Dask (distributed) and sparse arrays receive NumPy calls, so code written once
dispatches to the implementation that owns the data.

**Verbatim quote** (p. 2):

> Strides are necessary to interpret computer memory, which stores elements linearly, as multidimensional arrays.

**Relevance to sparkles.** The protocol idea carries over to D: generic
algorithms take any type that satisfies the view traits, and a GPU-resident
image type intercepts the same algorithm names (via overloads constrained on
`isGpuImage!T`) instead of being downloaded. Note also the colour-video shape
convention, `(T, M, N, 3)`, which the video side has to decide on as well.

**Caveats.** Ecosystem overview, not a design study; the protocol performance
overhead is not quantified.

### Bezanson, Edelman, Karpinski and Shah 2017: Julia: a fresh approach to numerical computing

| Field        | Value                                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------------------ |
| Authors      | Jeff Bezanson, Alan Edelman, Stefan Karpinski, Viral B. Shah                                                       |
| Venue/Year   | _SIAM Review_ 59(1):65–98, 2017                                                                                    |
| DOI or arXiv | [10.1137/141000671][julia-doi]; [arXiv:1411.1607][julia-arxiv]                                                     |
| Local PDF    | `~/code/repos/papers/image-video/generic-image-programming/bezanson2017-julia-fresh-approach.pdf` (arXiv v4, 2015) |
| Open access  | Y (arXiv)                                                                                                          |

**Claim.** Julia makes generic code fast through _code selection_: multiple
dispatch on the types of all arguments, with type inference and specialisation
per concrete signature. Type annotations are for selecting methods, not for
performance, and user-defined types are as fast as built-in ones. When an
argument's type is unknown until run time, selection happens at run time, and
the selected method then runs specialised code.

**Verbatim quote** (p. 24):

> If Julia knows an argument type early, it can make use of this information for performance. If it does not, code selection can still happen, at runtime. The reason why Julia can still perform well is that once code selection based on type occurs, Julia can return to performing well once inside the method.

**Relevance to sparkles.** This is the dynamic-language form of GIL's
`any_image` and of a D `SumType` `match`: one run-time selection at the
boundary, then specialised code inside. It also shows that the instantiation
set (Bourdev and Järvi) is paid either way, at compile time in D or at first
call in Julia, so `sparkles` should bound the set of pixel formats rather than
hope specialisation is free. Julia is the substrate for JuliaImages (next
entry).

**Caveats.** A language-design paper, not an image-library evaluation. JIT
latency and type-instability effects are specific to Julia. The local PDF is
the arXiv version, which differs from the journal text.

### JuliaImages documentation: images are arrays of colorants

| Field        | Value                                                                 |
| ------------ | --------------------------------------------------------------------- |
| Authors      | JuliaImages contributors (Tim Holy et al.)                            |
| Venue/Year   | Project documentation, retrieved October 28, 2026                     |
| DOI or arXiv | none                                                                  |
| Local PDF    | web source                                                            |
| Open access  | Y ([quickstart][juliaimages-qs], [arrays and colors][juliaimages-ac]) |

**Claim.** JuliaImages has no image type of its own. Any `AbstractArray` is an
image, and meaning comes from the _element type_: a `Colorant`
(`Gray{N0f8}`, `RGB{Float32}`, `Lab`), with normalised fixed-point numbers such
as `N0f8` reinterpreting a `UInt8` as a value in 0..1. `channelview` and
`colorview` reinterpret between `m×n` arrays of colour values and `3×m×n`
numeric arrays without copying.

**Verbatim quote** (quickstart page):

> For most purposes, any AbstractArray can be treated as an image.

**Relevance to sparkles.** This model puts colour semantics into the pixel
type, not into an image header: `Gray!(Norm8)` versus raw `ubyte` prevents
treating linear and sRGB-encoded values, or 0..255 and 0..1 values, as the same
thing. A D `colorView`/`channelView` pair over the same memory is cheap with
`cast` on slices of POD structs, and supports both "array of pixels" and
"planes of channels" algorithms.

**Caveats.** Documentation, not a paper. Julia's dynamic dispatch and JIT
differ from D's ahead-of-time templates, and the docs warn that `N0f8`
arithmetic overflows like `UInt8`.

### Mir `ndslice` documentation: `SliceKind`

| Field        | Value                                                                       |
| ------------ | --------------------------------------------------------------------------- |
| Authors      | Ilia Ki et al. (libmir; Kaleidic Associates, Symmetry Investments)          |
| Venue/Year   | `mir-algorithm` API reference, "Libmir Archive", retrieved October 28, 2026 |
| DOI or arXiv | none                                                                        |
| Local PDF    | web source                                                                  |
| Open access  | Y ([`mir.ndslice.slice`][mir-slice], [`mir_slice_kind`][mir-kind])          |

**Claim.** Mir's `Slice!(Iterator, N, kind)` is an N-dimensional view over any
random-access iterator. A three-way `SliceKind` encodes contiguity in the type:
`contiguous` (flat data, no strides), `canonical` (row dimension contiguous)
and `universal` (strides on every dimension). Algorithms can therefore require,
or specialise on, contiguity at compile time.

**Verbatim quote** (`mir_slice_kind` page, the row for `canonical`):

> A slice has >=2 dimensions and row dimension is contiguous.

**Relevance to sparkles.** This is the existing D precedent for the view
layer. Its three kinds are exactly the properties Milena dispatches on and the
representations Repa 3 indexes: `canonical` matches the typical image (padded
rows, contiguous pixels within a row) and enables `scanline` access and SIMD
row loops. Reuse the classification even if not the package: Mir is archived
("Libmir Archive"), so depending on it is a maintenance risk.

**Caveats.** Strides are in elements, not bytes, so non-multiple-of-pixel
row pitches need care. The project is archived, and the documentation is a
generated API reference rather than a design rationale.

### Panteleev 2014: Functional image processing in D

| Field        | Value                                                     |
| ------------ | --------------------------------------------------------- |
| Authors      | Vladimir Panteleev                                        |
| Venue/Year   | Blog post, March 21, 2014, describing `ae.utils.graphics` |
| DOI or arXiv | none                                                      |
| Local PDF    | web source                                                |
| Open access  | Y ([blog post][panteleev])                                |

**Claim.** The post defines an image _view_ as any type with `w`, `h` and
`[x, y]`, checked by an `enum isView(T)` predicate in the style of
`isInputRange`. It refines this with `isWritableView` and `isDirectView` (which
has `scanline(y)` returning a slice), and builds lazy, composable views
(`procedural`, `crop`, `warp`, `hflip`, `colorMap`) that conditionally expose
writability and `scanline` through `static if`. `blitTo` uses `scanline` when
both sides support it. A `parallel` helper splits a view into row segments for
`std.parallelism`.

**Verbatim quote** (blog post):

> Because the abstraction we use does not rely on runtime polymorphism, the compiler is free to inline calls across all transformation layers.

**Relevance to sparkles.** This is the closest prior art in D and should be
the baseline design: capability traits (`isView`, `isWritableView`,
`isDirectView`) with DbI propagation of optional primitives through adapters.
For sparkles, add what it lacks: byte strides and planar layouts, `@nogc`
ownership via `sparkles.base.buffer`, region-split borders, colour-typed
channels and a GPU-resident image kind.

**Caveats.** A blog post with no benchmarks. It uses GC-allocated `COLOR[]` and
`int` coordinates, and its claim of identical machine code for
`hflip().hflip()` is anecdotal.

## Thread synthesis

**Consensus.** Every library here converges on the same three-part model,
whatever its language:

1. a _domain_ (rectangle, mask, graph, infinite lattice);
2. a _value type_ carrying its own algebra and semantics (promotion traits,
   lattice properties, `Colorant` types, ImgLib2's type hierarchy);
3. an _access protocol_ whose cost is that of a pointer dereference (Stepanov's
   `source`, GIL's locator, ImgLib2's accessors, NumPy's strides).

ImgLib2 states the split most plainly as pixel algebra, data access and data
representation. Algorithms are written against concepts and specialised by
_properties_ (contiguity, writability, linear buffer), not by enumerating
concrete types: VIGRA, GIL, Milena, Mir and Panteleev all say this. Lazy
(delayed) views compose transforms without allocating, and an explicit
materialisation point controls locality (Repa `force`, Halide
`compute_root`/`compute_at`). Views do not own their data and are cheap to
copy. Every fast functional system adds a compilation step on top of the
function model (Pan's compiler, Accelerate's fusion, Halide's schedules); none
executes the per-pixel function as written.

**Disagreements.**

- _Static versus dynamic genericity._ The C++, D and Haskell line puts pixel
  type, layout and rank in the type system and pays in instantiation count,
  compile time and code size (Bourdev and Järvi). NumPy and Julia keep one
  dynamic descriptor or select code at run or JIT time and pay in
  per-operation overhead and weaker static guarantees, later adding protocols
  to recover specialisation. GIL's `any_image` and Julia's code selection meet
  in the middle: one run-time choice per call, specialised code inside.
- _Iterators versus views._ Köthe 1999 and GIL build on 2-D or N-D iterators
  and locators; VIGRA's own retrospective, NumPy, Julia and Mir build on
  shape-plus-strides views, and VIGRA reports that views were easier for
  implementers.
- _How general the domain is._ Milena and ImgLib2 make the domain abstract
  (graphs, sparse samples, real coordinates); GIL, NumPy and the array
  languages assume regular grids. The grid systems are simpler and faster; the
  abstract-domain systems are the ones that express regions, tiles and
  transforms as views.
- _Continuous versus discrete domains._ Pan uses continuous space (sampling is
  implicit); Halide and Repa use integer lattices (sampling is the caller's
  problem).
- _Proxy references versus accessors_ for planar and sub-byte pixels: GIL uses
  proxy references, VIGRA uses `get`/`set` accessors, ImgLib2 reuses one proxy
  object per accessor.
- _Where representation and laziness live._ Repa 1/2 used a run-time tag and
  Repa 3 a type index. GIL makes it compile-time, with `any_image` as an opt-in
  variant; Julia leaves it to dynamic dispatch. Laziness is a distinct delayed
  type (Repa, Accelerate's producers), view composition resolved by inlining
  (GIL, Panteleev), or absent (NumPy's whole-array operations with temporaries).

**Open problems.**

- Code bloat when run-time pixel formats meet multi-argument algorithms
  (Bourdev and Järvi). Type reduction helps but relies on unchecked casts.
- Choosing a schedule automatically for fused pipelines (Halide autotuning) is
  still expensive.
- Bounds safety without per-pixel checks is solved for stencils by region
  partitioning (Lippmeier and Keller), and McDonell et al. measure the cost of
  not doing it. No paper here treats _untrusted_ dimensions and strides from a
  decoder as a security boundary.
- Colour semantics under genericity: when a generic operation may assume
  linear light, premultiplied alpha or a known transfer function, and how a
  pixel concept states it. GIL tags colour spaces and JuliaImages types them;
  the rest ignore it.
- Subsampled multi-plane formats and data-dependent tile streams fit none of
  the models; Madsen et al. cover only regular chunk sequences.
- Trait checks in D (and pre-concepts C++) verify syntax, not Stepanov's
  axioms; none of the entries offers a way to test semantic conformance beyond
  examples.
- No source unifies CPU-view and GPU-image algorithms behind one name set
  without an embedded language or array protocol (Accelerate, NumPy).

**What a D implementation should take from this.**

- Define capability traits in the `isInputRange` style: `isImageView`,
  `isWritableView`, `hasScanlines` (direct rows), `isContiguous` and
  `isPlanar`. Adapters propagate optional primitives with `static if`
  (Panteleev, Milena properties, DbI guidelines). Document each trait's axioms
  and pair it with negative tests (types that must _not_ satisfy it), since the
  trait only checks syntax (Stepanov).
- Make the base representation an N-D strided view: pointer, extents and
  **byte** strides, with a `SliceKind`-like contiguity tag in the type (NumPy,
  Mir, VIGRA 2012). Validate stride × extent against the backing buffer once,
  at construction, so a hostile decoder header cannot create an out-of-bounds
  view.
- Keep delayed and manifest images as distinct _types_, with an explicit
  `materialize` into a `sparkles.base.buffer`-owned image. Never use a run-time
  representation tag inside loops (Repa, Repa 3). Let element-wise views
  compose lazily, and materialise or inline at multi-input operations
  (McDonell et al.'s producers and consumers). Expose a scanline primitive so
  composed views run as row loops, not one call per pixel (Elliott, Finne and
  de Moor).
- Put colour semantics (space, transfer function, premultiplication, value
  range) in the pixel type (`Gray!Norm8`, `RGB!(float, Linear)`) with promotion
  traits for accumulation (JuliaImages, Köthe). Make generic assignment between
  compatible pixel types the single, auditable colour-conversion hook, so a
  generic `copy` between formats is a colour conversion (GIL). Offer zero-copy
  `channelView`/`colorView` casts.
- Represent decoder output as a `SumType` of a _small, canonicalised_ set of
  image types, and dispatch once per algorithm call, never per pixel (GIL
  `any_image`, Julia). Reduce layout-equivalent formats to one representative
  before instantiating, to bound code size (Bourdev and Järvi). Reject formats
  outside the set.
- Give each algorithm a facade with an overload ladder: contiguous, per plane,
  per row, then generic (GIL `copy_pixels`, Milena facades).
- Have stencil and filter facades split work into interior and border regions:
  checked-free (and SIMD) interior, border from an extending view (Lippmeier
  and Keller, ImgLib2, Halide guard bands).
- Layer a range of chunk views over the per-chunk concepts for storage-to-GPU
  paths, with chunk size set by memory and transfer limits and global
  operations written as explicit folds over the stream (Madsen et al.).
- Keep algorithm and schedule apart in the API (tile size, vector width,
  CPU/GPU target), and type the host/device distinction explicitly
  (`HostImage` versus `GpuImage`, the equivalent of Accelerate's
  `Array`/`Acc`). Per-pixel kernels written once in D can then target both the
  CPU loop and `sparkles:shaders` SPIR-V via `shader-compile`.
- Define geometric transforms by inverse-mapping output coordinates (Pan), and
  use the same convention in shader code, so CPU and GPU resampling agree to
  the pixel.

## Sources

- Ritter, Wilson, Davidson, "Image algebra: an overview", CVGIP 1990:
  [DOI][ritter-doi]; [UF image algebra theory page][ritter-web]
- Köthe, "Reusable software in computer vision" (1999 handbook chapter draft):
  [Wayback PDF][koethe1999-pdf]; [VIGRA home page][vigra-home]
- Köthe, "STL-style generic programming with images" (C++ Report 2000):
  [Wayback PDF][koethe2000-pdf]; [Dagstuhl abstract][koethe-dagstuhl]
- Köthe, "The VIGRA image analysis library" (IPOL 2012): [PDF][vigra-ipol]
- Bourdev, Jin, "Generic Image Library design guide" (2006): [PDF][gil-guide]
- Bourdev, "Generic Image Library" (2007 manuscript): [PDF][gil-2007]
- Bourdev, Järvi, "Efficient run-time dispatching in generic programming with
  minimal code bloat" (SCP 2011): [DOI][bourdev-jarvi-doi]
- Levillain, Géraud, Najman, "Milena: write generic morphological algorithms
  once, run on many kinds of images" (ISMM 2009): [DOI][milena09-doi];
  [PDF][milena09-pdf]
- Levillain, Géraud, Najman, "Why and how to design a generic and efficient
  image processing framework" (ICIP 2010): [DOI][milena10-doi];
  [PDF][milena10-pdf]
- Pietzsch, Preibisch, Tomančák, Saalfeld, "ImgLib2: generic image processing
  in Java" (Bioinformatics 2012): [DOI][imglib2-doi]
- Elliott, Finne, de Moor, "Compiling embedded languages" (SAIG 2000; JFP
  2003): [SAIG DOI][elliott00-doi]; [JFP DOI][elliott00-jfp-doi];
  [PDF][elliott00-pdf]
- Elliott, "Functional Image Synthesis" (Bridges 2001): [PDF][elliott-bridges]
- Elliott, "Functional Images" (The Fun of Programming, 2003):
  [DOI][elliott03-doi]; [PDF][elliott-fop]
- Stepanov, McJones, _Elements of Programming_: [book site][eop]
- Keller et al., "Regular, shape-polymorphic, parallel arrays in Haskell"
  (ICFP 2010): [DOI][repa-doi]; [PDF][repa-pdf]
- Lippmeier, Keller, "Efficient parallel stencil convolution in Haskell"
  (Haskell 2011): [DOI][stencil-doi]; [PDF][stencil-pdf]
- Lippmeier et al., "Guiding parallel array fusion with indexed types"
  (Haskell 2012): [DOI][repa3-doi]; [PDF][repa3-pdf]
- Chakravarty et al., "Accelerating Haskell array codes with multicore GPUs"
  (DAMP 2011): [DOI][acc-doi]; [PDF][acc-pdf]
- McDonell et al., "Optimising purely functional GPU programs" (ICFP 2013):
  [DOI][mcdonell-doi]; [UNSW repository][mcdonell-pdf]
- Madsen et al., "Functional array streams" (FHPC 2015): [DOI][madsen-doi]
- Ragan-Kelley et al., "Halide" (PLDI 2013): [DOI][halide-doi];
  [PDF][halide-pdf]; full entry in [`dsl-scheduling`][dsl-scheduling]
- van der Walt, Colbert, Varoquaux, "The NumPy array" (CiSE 2011):
  [DOI][numpy11-doi]; [arXiv][numpy11-arxiv]
- Harris et al., "Array programming with NumPy" (Nature 2020):
  [DOI][numpy20-doi]
- Bezanson, Edelman, Karpinski, Shah, "Julia: a fresh approach to numerical
  computing" (SIAM Review 2017): [DOI][julia-doi]; [arXiv][julia-arxiv]
- JuliaImages documentation: [quickstart][juliaimages-qs];
  [arrays, numbers and colors][juliaimages-ac]
- Mir `ndslice`: [`mir.ndslice.slice`][mir-slice]; [`mir_slice_kind`][mir-kind]
- Panteleev, "Functional image processing in D" (2014): [blog post][panteleev]

<!-- References -->

[ritter-doi]: https://doi.org/10.1016/0734-189X(90)90106-6
[ritter-web]: https://www.cise.ufl.edu/~jnw/IA/ia-theory.html
[koethe1999-pdf]: https://web.archive.org/web/20040726165410/http://kogs-www.informatik.uni-hamburg.de:80/~koethe/papers/handbook.pdf
[koethe2000-pdf]: https://web.archive.org/web/20040726164958/http://kogs-www.informatik.uni-hamburg.de:80/~koethe/papers/GenericProg2DC++Report.pdf
[koethe-dagstuhl]: https://cs.rpi.edu/~musser/gp/dagstuhl/gpdag_26.html
[vigra-home]: https://ukoethe.github.io/vigra/
[vigra-ipol]: https://www.ipol.im/event/2012_imlib/docs/vigra.pdf
[gil-guide]: https://stlab.adobe.com/gil_design_guide.pdf
[gil-2007]: http://lubomir.org/pdfs/GIL_SDJ.pdf
[bourdev-jarvi-doi]: https://doi.org/10.1016/j.scico.2008.06.003
[milena09-doi]: https://doi.org/10.1007/978-3-642-03613-2_27
[milena09-pdf]: https://lre.epita.fr/dload/papers/levillain.09.ismm.pdf
[milena10-doi]: https://doi.org/10.1109/ICIP.2010.5649620
[milena10-pdf]: https://lre.epita.fr/dload/papers/levillain.10.icip.pdf
[imglib2-doi]: https://doi.org/10.1093/bioinformatics/bts543
[elliott00-doi]: https://doi.org/10.1007/3-540-45350-4_5
[elliott00-jfp-doi]: https://doi.org/10.1017/S0956796802004574
[elliott00-pdf]: http://conal.net/papers/saig00/
[elliott-bridges]: http://conal.net/papers/bridges2001/
[elliott03-doi]: https://doi.org/10.1007/978-1-349-91518-7_7
[elliott-fop]: http://conal.net/papers/functional-images/
[eop]: http://elementsofprogramming.com/
[repa-doi]: https://dl.acm.org/doi/10.1145/1863543.1863582
[repa-pdf]: https://www.cse.chalmers.se/edu/course.2014/pfp/Papers/rarrays.pdf
[stencil-doi]: https://dl.acm.org/doi/10.1145/2034675.2034684
[stencil-pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/07/Stencil.pdf
[repa3-doi]: https://dl.acm.org/doi/10.1145/2364506.2364511
[repa3-pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/07/haskell12-lippmeier.pdf
[acc-doi]: https://dl.acm.org/doi/10.1145/1926354.1926358
[acc-pdf]: https://web.archive.org/web/20110411181218/http://www.cse.unsw.edu.au/~chak/papers/acc-cuda.pdf
[mcdonell-doi]: https://doi.org/10.1145/2500365.2500595
[mcdonell-pdf]: https://handle.unsw.edu.au/1959.4/55818
[madsen-doi]: https://doi.org/10.1145/2808091.2808094
[halide-doi]: https://dl.acm.org/doi/10.1145/2491956.2462176
[halide-pdf]: https://people.csail.mit.edu/jrk/halide-pldi13.pdf
[dsl-scheduling]: ./dsl-scheduling.md
[numpy11-doi]: https://doi.org/10.1109/MCSE.2011.37
[numpy11-arxiv]: https://arxiv.org/abs/1102.1523
[numpy20-doi]: https://doi.org/10.1038/s41586-020-2649-2
[julia-doi]: https://doi.org/10.1137/141000671
[julia-arxiv]: https://arxiv.org/abs/1411.1607
[juliaimages-qs]: https://juliaimages.org/stable/tutorials/quickstart/
[juliaimages-ac]: https://juliaimages.org/latest/tutorials/arrays_colors/
[mir-slice]: http://mir-algorithm.libmir.org/mir_ndslice_slice.html
[mir-kind]: http://mir-algorithm.libmir.org/mir.ndslice.slice.mir_slice_kind.html
[panteleev]: https://blog.cy.md/2014/03/21/functional-image-processing-in-d/
