# CImg (C++)

GREYC's single-header image-processing toolkit: one class template `CImg<T>` holding
a planar 4-D `(x, y, z, c)` grid of one value type, a `CImgList<T>` for anything with a
fifth axis, a preprocessor plugin mechanism, and codec support that falls back to
spawning external tools.

| Field         | Value                                                                              |
| ------------- | ---------------------------------------------------------------------------------- |
| Language      | C++ (C++11 verified with GCC 16.2.0; one header, `CImg.h`, 71,779 lines)           |
| License       | CeCILL-C or CeCILL v2.1, at the user's choice ([`CImg.h` header][license])         |
| Repository    | [GreycLab/CImg][repo]                                                              |
| Revision read | `38bb024dec319ddc6c78241614fc479af0ed6e11` (`cimg_version 407`, reported as 4.0.7) |
| Documentation | [cimg.eu][docs]; Doxygen comments inside `CImg.h`                                  |
| Category      | Generic libraries                                                                  |
| Tier          | B                                                                                  |
| Last reviewed | November 15, 2026                                                                  |

> [!NOTE]
> CImg is the counter-example to most of this catalog. Where [Boost.GIL][gil],
> [VIGRA][vigra] and [mir-algorithm][mir] separate the pixel type, the memory layout
> and the algorithm, CImg fixes the layout (planar, dense, four axes), parameterises
> only the sample type, and puts image algorithms and codecs into that container's
> members, with display types and an expression language in the same header. It is
> relevant to Sparkles for what that buys (an approachable container for scientific
> volumes) and for what it costs at the I/O boundary.

---

## Overview

### What it solves

CImg gives a C++ program a single container for 1-D signals, 2-D colour images,
3-D volumes and multi-spectral data, with loading, saving, display, filtering and
drawing attached. The README states the shape of the design
([`README.md`][readme]):

> **CImg** defines a single image class able to represent datasets having up to _4-dimensions_ (from 1d scalar signals to 3d hyperspectral volumetric images), with _template pixel types_ (`bool,char,int,float,...`). It also handles image _collections_ and _sequences_.

Its packaging is a single header included in the caller's source
([`README.md`][readme]).

### Design philosophy

The class comment fixes the axes and puts colour on the fourth one
([`CImg.h` L10746-L10755][class-doc]):

> The image grid can have up to 4 dimensions: width, height, depth
> and number of channels.

Three choices follow. The value type is the only template parameter, defaulting to
`float` ([L10760-L10765][class-doc]). Colour is
not a type: an RGB image is a `CImg<unsigned char>` whose `_spectrum` is 3. And the
layout is not a parameter: "Pixel data is stored in memory, in a non-interleaved
mode" ([L10787][class-doc]).

## How it works

### The container

`CImg<T>` is six public fields ([L10831-L10836][fields]):

```cpp
template<typename T>
struct CImg {
  unsigned int _width, _height, _depth, _spectrum;
  bool _is_shared;
  T *_data;
```

There is no stride field. Addressing is a fixed formula over the four extents
([`offset`, L13529-L13531][offset]):

```cpp
longT offset(const int x, const int y=0, const int z=0, const int c=0) const {
  return x + (longT)y*_width + (longT)z*_width*_height + (longT)c*_width*_height*_depth;
}
```

so `c` is the slowest axis and each channel is one contiguous plane (the
[planar layout][concepts-layout]). The iterator is a
raw `T*` ([L10853][fields]). A scratch program built against the pinned header
(`g++ 16.2.0 -std=c++11 -O1`, under `/tmp/cimg-verify.dNzJEH`) printed the planar offsets
of a 4 x 2 x 1 x 3 image:

```text
offset(1,0,0,1) = 9
offset(1,0,0,2) = 17
```

### Views are shared instances, not a separate type

A sub-image that can alias the parent is the same `CImg<T>` with `_is_shared` set.
`get_shared_channel`, `get_shared_rows`, `get_shared_points` and `get_shared` build one
from a pointer into `_data` ([L40249-L40430][shared]):

```cpp
CImg<T> get_shared() {
  return CImg<T>(_data,_width,_height,_depth,_spectrum,true);
}
```

Because there is no stride, only subsets that stay contiguous under the fixed formula
can be shared: whole channels, whole rows within a plane, whole slices within a channel,
or a run of points within a row. A narrower multi-row rectangle cannot be a view;
[`get_crop`][crop] copies. The destructor frees only
non-shared data (`if (!_is_shared) delete[] _data;`, [L10983-L10985][dtor]), the plain
copy constructor propagates sharing (`if (_is_shared) _data = const_cast<T*>(img._data);`,
[L11498-L11517][copy]). The dimension-taking `assign` rejects a change to a different
nonzero element count in a shared instance; reshaping at the same count and clearing
are allowed ([L11663-L11690][assign]). Nothing tracks the parent's lifetime. The demo program
filled a shared green channel and read the parent back:

```text
is_shared=1, img(0,0,0,1)=7, img(0,0,0,0)=42
```

### In-place and `get_` pairs, with value-type promotion

Many image transformations come in pairs: a mutating member returning `CImg<T>&` for
chaining, and a `get_` form returning a new image whose type may be widened
([`blur`, L42940-L42950][blur]; abridged):

```cpp
CImg<T>& blur(const float sigma, const unsigned int boundary_conditions=1, const bool is_gaussian=true) { … }
CImg<Tfloat> get_blur(const float sigma, const unsigned int boundary_conditions=1,
                      const bool is_gaussian=true) const {
  return CImg<Tfloat>(*this,false).blur(sigma,boundary_conditions,is_gaussian);
}
```

`Tfloat` and its siblings are member typedefs computed by `cimg::superset<T,t>`, a
hand-written table of specialisations ([L3190-L3200][superset];
[typedefs, L10882-L10906][typedefs]). The demo confirmed that `get_blur` on a
`CImg<unsigned char>` returns `float32` samples.

### Loop macros and the expression evaluator

Many algorithm loops use macros: `cimg_forXY`, `cimg_foroff`,
and neighbourhood macros such as `cimg_for3x3`, which keep a sliding `I[9]` array
of neighbours updated as `x` advances ([L1502-L1518][for3x3]). The neighbourhood macro
family is generated by [`examples/generate_loop_macros.cpp`][genloops]. Beside this, the header
embeds `_cimg_math_parser`, a compiler of expression strings to an opcode list and its
interpreter, spanning L15942 to L29612 ([`_cimg_math_parser`][mathparser]); it backs
`fill(const char *expression, …)` ([L33502-L33505][fill]).

### Plugins

The extension point is textual inclusion. Inside the class body, `CImg.h` includes up to
nine user headers named by macros ([L10938-L10963][plugins]):

```cpp
#ifdef cimg_plugin
#include cimg_plugin
#endif
#ifdef cimg_plugin1
#include cimg_plugin1
#endif
```

so a plugin adds member functions with full access to the private-by-convention fields.
File formats hook in through a second family, `cimg_load_plugin(filename)`, expanded at
the top of `load` ([L55294-L55320][load]). The shipped template
[`plugins/add_fileformat.h`][addfmt] shows the whole contract:

```cpp
#ifndef cimg_load_plugin
#define cimg_load_plugin(filename) \
  if (!cimg::strncasecmp(cimg::split_filename(filename),"foo",3)) return load_foo(filename);
#endif
```

### Codec dispatch

`load(filename)` dispatches on the extension first, then on a magic-number sniff by
`cimg::ftype`, then on `load_other` ([L55276-L55455][load]). Native readers exist for
simple formats (PNM, BMP, PFM, INR, Analyze, the `.cimg` format); compressed formats
use a library only when its `cimg_use_*` macro is defined at compile time, and
otherwise reach external programs. Without `cimg_use_png`, `load_png` on a filename is
`return load_other(filename);` ([L56254-L56265][png]). `load_other` then tries Magick++,
the `magick`/`convert` executable, GraphicsMagick's `gm`, and the `.cimg` reader in turn
([L59097-L59130][other]). The ImageMagick path runs a shell command and parses its PNM
or PNG output from a pipe ([L58699-L58740][magick]; abridged):

```cpp
cimg_snprintf(command,command._width,"%s%s \"%s\" %s:-",
              magick_path, …, s_filename.data(), "pnm");
std::FILE *file = popen(command,"r");
```

A filename beginning `http://` or `https://` is downloaded first with `curl` or `wget`
through `cimg::load_network` ([L55282-L55287][load]; [implementation][network]). With
`cimg_use_curl`, it uses libcurl instead; `cimg::network_mode(false)` disables network
loading. `CImgList<T>::load_ffmpeg_external` runs `ffmpeg` to write numbered PPM
frames into the temporary directory and loads them one by one ([L66379-L66420][ffmpeg]).

## Analysis

### 1. Pixel and memory model

CImg is the dense, planar, stride-free end of the design space. Four `unsigned int`
extents and one pointer describe every image; there is no row pitch or alignment
parameter, no tile and no interleaved form. That makes the 3-D volume and the multi-spectral cube
first-class (the case [VIGRA][vigra-1] and [mir-algorithm][mir] reach through general
N-D strides), and it makes every interleaved source a copy: the libpng path reads RGBA
rows into temporary buffers and scatters each sample into its plane
([L56337-L56418][png-read]). A consumer requiring interleaved rows needs a layout
conversion; a consumer accepting separate planes does not. The fifth axis uses
`CImgList<T>`, an array of independent `CImg<T>` objects ([L62931-L62933][list]),
which is how frames and sequences are held.

### 2. Genericity mechanism

Generic over the value type only, by class template plus a lookup table of promotions
(`cimg::superset`). Built-in image transformations are member functions.
A plugin adds members; callers can also write free functions over
`CImg<T>`. There is no pixel concept, no colour-space type and no layout parameter to
specialise on. Compared with [Boost.GIL's concept hierarchy][gil-2] and
[JuliaImages' colorant types][julia], CImg trades static meaning for one
uniform container. Run-time genericity comes from the other direction, through the
expression language that `fill` compiles at run time.

### 3. Colour and metadata

Colour lives in values and conventions, not types. `sRGBtoRGB` divides by 255 whatever
`T` is ([L35586-L35598][srgb]); the demo applied it to a `CImg<float>` holding `0.5`
and to one holding `128`:

```text
sRGBtoRGB(0.5f) = 0.0386997, sRGBtoRGB(128.0f) = 55.0444
```

Passing normalised 0..1 samples directly therefore applies the wrong scale: this
function expects and returns 0..255 values even for `float`. The libpng loader does
not retrieve or apply `iCCP`, `gAMA`,
`cHRM` or `sRGB` chunks and returns 16-bit samples as raw integers
([L56337-L56418][png-read]). The six-field image object has no metadata fields for
EXIF, XMP or an ICC profile ([fields][fields]). The [color][color] library's typed
colour spaces provide a contrasting model.

### 4. I/O and codec architecture

Pull, whole-image and blocking, with three tiers: native readers, compile-time-optional
libraries, and subprocesses. Format choice trusts the extension before the bytes, and a
`CImgIOException` from the extension-selected reader triggers sniffing and then
fallback if needed ([`load`][load]). The external-tool
tier gives breadth (anything ImageMagick, `ffmpeg`, `dcraw` or `medcon` reads) at the
cost of a process spawn and a temporary file or pipe. The ImageMagick pipe uses PNG
when libpng is enabled and PNM otherwise. The still-image `load` API returns a complete
image; it exposes no incremental or suspendable decoding in the sense of
[the concepts page][concepts-decoding].

### 5. Hostile input and safety

The [dimension-taking constructor][size-ctor] and `assign` use `safe_size`. It checks
the extent product and the byte count by division and enforces
`cimg_max_buf_size`, by default 16 GiB on 64-bit targets ([L283-L289][maxbuf];
[L10908-L10930][safesize]). The demo hit both branches:

```text
overflow: CImg<float32>::safe_size(): Specified size (65536,65536,65536,65536) overflows 'size_t'.
cap: CImg<float32>::safe_size(): Specified size (70000,70000,1,1) exceeds maximum allowed buffer size of 17179869184.
```

Per-format checks are uneven. `_load_pnm` rejects a header whose `W*H*D` exceeds the
file size, but only when it was given a filename that is not standard input
([L56512-L56520][pnm-check]). Given a `FILE*`, the same 19-byte file
`P5\n10000 10000\n255\n` loaded as a 100,000,000-byte image; `cimg::fread` only warns
on a short read ([L6024-L6040][fread]) and `assign` does not zero the buffer, so the
unread samples are indeterminate. Excerpts from the demo's stderr and stdout:

```text
[CImg] *** Warning ***cimg::fread(): Only 0/25165824 elements could be read from file.
FILE*: loaded 10000x10000 (100000000 bytes) from a 19-byte file
```

The libpng path allocates `H` rows of `4*W*byte_depth` bytes before `assign` runs
`safe_size`, and if `assign` throws it frees the row array but not the rows
([L56370-L56390][png-alloc]). This was reproduced with libpng 1.6.59, a valid 20 x 20 RGB
PNG and `cimg_max_buf_size=1024`: `assign` rejected the 1,200-byte image after the
temporary rows were allocated; LeakSanitizer reported 1,600 bytes leaked in 20
allocations at L56373. The cap is therefore not a budget for all decoder allocations.
The [copy constructor][copy] also allocates from the existing image's `size()` without
calling `safe_size` again. Pixel access is unchecked unless `cimg_verbosity>=3`, and
then an offset beyond `size()` warns and returns `*_data` rather than failing
([L11996-L12075][opcall]); the demo read `42` (the first sample) at `(100,100)` of a
4 x 2 image. Finally, `load` passes untrusted filenames to `popen` and `system` after
`_system_strescape`, and an `http://` name triggers a download unless network loading
is disabled. These paths add shell and network handling to the decoder boundary;
see the [hostile-input paper thread][p-hostile].

### 6. Allocation and ownership

`new T[siz]` and `delete[]`, with no allocator parameter; `assign` reallocates only when
growing or when shrinking below half of a buffer over 4096 elements
([L11663-L11690][assign]). Ownership is a boolean: owning or shared, with no reference
count, so a shared view can outlive its parent unchecked. `move_to` and `swap`
([L11877-L11890][moveto]; [L11929-L11934][swap]) provide explicit transfers; the header
also supplies a C++11 move constructor and move assignment ([L11635-L11647][move]).

### 7. CPU parallelism and SIMD

OpenMP pragmas on per-sample loops, enabled by `cimg_use_openmp` and gated on a size
threshold scaled by `cimg_openmp_sizefactor`; on Windows the simple-loop macro is
compiled serial "due to noticed performance drop" ([L2534-L2553][openmp]). There is no
explicit SIMD; vectorisation is left to the compiler over the contiguous planes.

### 8. GPU offload and interop

Not applicable to the core algorithms: the pinned header has no OpenCL, CUDA or
Vulkan kernels or device-buffer abstraction. Interop with a consumer requiring
interleaved pixels needs conversion from CImg's planar storage ([offset][offset]).

### 9. Temporal, animation and containers

A sequence is a `CImgList<T>` of frames with no timestamps, durations or loop counts.
GIF loads through external tools, and video uses external `ffmpeg` by default or
OpenCV when enabled ([GIF loader][gif]; [video loader][video]; [ffmpeg path][ffmpeg]).
The list does not retain timing metadata.

### 10. Testing and conformance

There is no test suite in the tree. The CI workflow builds the examples on Ubuntu and
macOS and runs two of them, `image2ascii` and `generate_loop_macros`
([`Test_Build.yml`][ci]). There is no corpus, fuzzing harness or differential oracle.

## Lessons for Sparkles

- **Q1** A fixed `(x, y, z, c)` planar extent is enough for volumes and multi-spectral
  scientific data and is easy to teach, but without a stride it cannot express a
  narrower multi-row crop, a padded row or an interleaved buffer as a view. This
  supports giving Sparkles a strided view model when such consumers must interoperate
  without layout copies.
- **Q1** A shared flag in the image type loses an explicit owner/view distinction.
  Sparkles should represent borrowing explicitly and verify lifetime enforcement:
  [mir's `Slice` experiment][mir-exp] found that dip1000 alone did not prevent escape
  of views over the tested owner.
- **Q2** Value-type-only genericity with promotion typedefs (`Tfloat`) maps directly to
  D's `CommonType` and template constraints; it is a small generic layer, and
  CImg shows it is insufficient on its own once colour and layout matter.
- **Q2** Textual plugins make new algorithms members. In D, UFCS lets free functions
  over the image type use member-call syntax without reopening the class. The goal
  of user algorithms using the same call syntax as built-ins transfers.
- **Q3** Paired in-place and `get_` operations give a clear allocation story for eager
  code; they do not compose lazily the way [ae.utils.graphics][ae] views or
  [Halide][halide] pipelines do.
- **Q4** Extension-first dispatch, fall-through on error and subprocess decoding are
  what a Sparkles codec layer should not do on untrusted input; native readers with
  sniffing first is the defensible order.
- **Q5** A `0..255` convention regardless of `T` is the failure mode a
  model with explicit range information can prevent; the scale mismatch for
  normalised floats is reproducible.
- **Q8** The PNM size check that depends on the input being a named file is a concrete
  oracle case: a Sparkles decoder must bound allocation by the declared limits and the
  bytes actually available, identically for files, pipes and memory.
- **Q9** One header holding container, algorithms, codecs, display and an expression
  language is the extreme of the "one package" option; its weight (71,779 lines,
  compile-time configuration through more than twenty `cimg_use_*` macros) is evidence
  about what the unsplit option grows into.

## Strengths

- One container covers signals, 2-D colour images, volumes and hyperspectral cubes.
- Single header; `cimg_display=0` avoids platform display dependencies ([configuration][display]).
- Many transformations support chained member calls; in-place and copying forms are
  explicit.
- Dimension-based image allocation has overflow checks and a configurable per-buffer cap.
- Breadth of formats through optional libraries and external tools.
- A run-time expression language for per-pixel formulas without recompiling.

## Weaknesses

- No strides: narrower multi-row crops, padded rows and interleaved data cannot be
  represented as shared views.
- Colour space, range and alpha are conventions, not types; passing normalised floats
  directly to `sRGBtoRGB` applies the wrong scale.
- The image object has no ICC, EXIF or XMP fields; its PNG reader applies no colour management.
- Hostile-input checks are per-format and inconsistent; short reads produce images of
  uninitialised memory; subprocess and network fall-backs widen the attack surface.
- Shared images carry no lifetime link to their owner.
- Configuration by preprocessor macro; plugins by textual inclusion into the class.
- No test suite, corpus or fuzzing in the tree.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                     | Trade-off                                                  |
| ------------------------------------------- | --------------------------------------------- | ---------------------------------------------------------- |
| Fixed dense planar storage                  | One indexing formula covers four axes         | No strided or interleaved shared views                     |
| Shared flag in `CImg<T>`                    | Views reuse the image API                     | No lifetime link to the owner                              |
| In-place and copying transformation pairs   | Callers choose mutation or a new result       | Eager chains materialise intermediate images               |
| Optional codec libraries and external tools | Format breadth with configurable dependencies | Decoder behaviour and resource use depend on configuration |

## Sources

- [`CImg.h`][header] at the pinned revision, the whole library; sections cited inline.
- [`README.md`][readme], the project's own summary.
- [`plugins/add_fileformat.h`][addfmt], the format-plugin template.
- [`examples/generate_loop_macros.cpp`][genloops], the loop-macro generator.
- [`.github/workflows/Test_Build.yml`][ci], the CI build-and-run workflow.
- [cimg.eu][docs], the project site.
- Verification probes under `/tmp/cimg-verify.dNzJEH`, outside the repository, with the
  header extracted by `git show` at the pinned revision. `demo.cpp` was compiled with
  `g++ 16.2.0 -std=c++11 -O1` (`cimg_display=0`, `cimg_verbosity=3`); the output excerpts
  above reproduced. `-std=c++98` failed with this compiler (exception specifications
  and missing `std::acosh`/`std::asinh`/`std::atanh`); compatibility with older compilers
  was not established. `shared.cpp` confirmed same-count reshaping and clearing of
  shared images. `png-leak.cpp` used `cimg_use_png`, `cimg_max_buf_size=1024`, libpng
  1.6.59 and `-std=c++11 -O1 -g -fsanitize=address`, with `ASAN_OPTIONS=detect_leaks=1`,
  to reproduce the PNG leak. Commands ran through `nix develop` for this worktree.
  These scratch probes are manual evidence, not persistent CI examples.
- Catalog cross-references: [Concepts][concepts], [Boost.GIL][gil], [VIGRA][vigra],
  [mir-algorithm][mir], [JuliaImages][julia], [color][color], [ae.utils.graphics][ae],
  [Halide][halide], [hostile-input papers][p-hostile].

<!-- References -->

[repo]: https://github.com/GreycLab/CImg/tree/38bb024dec319ddc6c78241614fc479af0ed6e11
[docs]: https://cimg.eu/
[header]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h
[license]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L16-L25
[readme]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/README.md
[addfmt]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/plugins/add_fileformat.h#L50-L75
[genloops]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/examples/generate_loop_macros.cpp
[ci]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/.github/workflows/Test_Build.yml#L1-L50
[maxbuf]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L283-L289
[for3x3]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L1502-L1518
[openmp]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L2534-L2553
[superset]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L3190-L3200
[fread]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L6024-L6040
[network]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L69235-L69342
[class-doc]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L10741-L10787
[fields]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L10831-L10853
[typedefs]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L10882-L10906
[safesize]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L10908-L10930
[plugins]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L10938-L10963
[dtor]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L10983-L10985
[copy]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11498-L11517
[assign]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11663-L11690
[moveto]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11877-L11890
[swap]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11929-L11934
[opcall]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11996-L12075
[offset]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L13529-L13531
[mathparser]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L15942-L29612
[fill]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L33502-L33552
[srgb]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L35586-L35598
[shared]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L40249-L40430
[blur]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L42940-L42950
[load]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L55276-L55455
[png]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L56254-L56265
[png-read]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L56337-L56418
[png-alloc]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L56370-L56390
[pnm-check]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L56512-L56520
[magick]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L58699-L58740
[other]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L59097-L59130
[list]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L62931-L62933
[ffmpeg]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L66379-L66420
[gif]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L66425-L66478
[video]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L66232-L66247
[move]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11635-L11647
[crop]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L39611-L39630
[display]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L414-L445
[size-ctor]: https://github.com/GreycLab/CImg/blob/38bb024dec319ddc6c78241614fc479af0ed6e11/CImg.h#L11029-L11044
[concepts]: ./concepts.md
[concepts-layout]: ./concepts.md#interleaved-planar-and-semi-planar
[concepts-decoding]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[gil]: ./boost-gil.md
[gil-2]: ./boost-gil.md#_2-genericity-mechanism
[vigra]: ./vigra.md
[vigra-1]: ./vigra.md#_1-pixel-and-memory-model
[mir]: ./mir-algorithm/
[mir-exp]: ./mir-algorithm/slice-experiment.md
[julia]: ./juliaimages.md
[color]: ./color.md
[ae]: ./ae-graphics.md
[halide]: ./halide.md
[p-hostile]: ./papers/hostile-input-safety.md
