# Boost.GIL (C++)

The C++ generic image library that turned Stepanov-style concepts into a pixel, locator and view hierarchy: it is the most complete static-genericity design in the survey and the reference model for an introspection-based pixel layer in D.

| Field         | Value                                                                                                                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | C++14 minimum (CI builds 14, 17, 20 and 23); header-only                                                                                                                                         |
| License       | Boost Software License 1.0 ([`LICENSE.txt`][license])                                                                                                                                            |
| Repository    | [boostorg/gil][repo]; Adobe origin in [stlab/adobe-source-libraries][asl-repo]                                                                                                                   |
| Revision read | `97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41` (`develop`, October 21, 2026); ASL at `1004bc351e7b79ab9e1ae545e50ad900eb6f81d9`                                                                      |
| Documentation | [boost.org/libs/gil][docs] · [develop docs][docs-dev] · design guide sources under `doc/modules/ROOT/pages/design/` · [Bourdev and Jin 2006 design guide][gil-guide]                             |
| Key authors   | Lubomir Bourdev and Hailin Jin (Adobe, 2005–2007); later contributors credited in `RELEASES.md` (Christian Henning, Mateusz Łoskot, Stefan Seefeld, Samuel Debionne, Pranam Lashkari and others) |
| Category      | Generic libraries: compile-time pixel and view concepts, run-time variant over a closed type set, thin I/O over C codecs                                                                         |
| Tier          | A                                                                                                                                                                                                |
| Last reviewed | November 7, 2026                                                                                                                                                                                 |

> [!NOTE]
> Claims marked **verified** were demonstrated by compiling and running probes in a
> scratch directory with GCC 14.3.0, the clone's `include/` ahead of Boost 1.87.0's
> other headers, libpng 1.6.56 and LDC 1.41.0. Everything else is read from the source
> or documentation at the pinned revision. A second agent reran the concept-check,
> AddressSanitizer, PNG, layout and D probes with GCC 16.2.0 and LDC 1.43.0 and got the
> same results, except where a section says otherwise. No performance number in this
> page was measured.

---

## Overview

### What it solves

Images vary along axes that are orthogonal to the algorithms run on them: interleaved
or planar storage, colour space and alpha, channel depth, channel order, and row
padding. Writing `copy`, `resize` or `convolve` once per combination does not scale;
writing it once over a run-time descriptor costs a branch or an indirect call per
pixel. GIL's answer is to give each axis a compile-time type, to write algorithms
against concepts, and to let the compiler produce code specialised for each
combination. Its design guide lists the five axes (structure, colour space and alpha,
channel depth, channel order, row alignment) and then states the claim
([`basics.adoc`][doc-basics]):

> _"GIL abstracts image representation from algorithms applied on images and allows
> us to write the algorithm once and have it work on any of the above image variations
> while generating code that is comparable in speed to that of hand-writing the
> algorithm for a specific image type."_

For images whose format is known only when a file is opened, the `dynamic_image`
extension wraps a closed list of image types in a variant (`any_image`) and
dispatches once per algorithm call. The `io` extension reads and writes BMP, JPEG,
PNG, PNM, RAW, Targa and TIFF on top of the platform C libraries.

### Design philosophy

The library is built bottom-up from concepts in the generic-programming tradition.
The concepts page says so in its first lines ([`concepts.adoc`][doc-concepts]):

> _"All constructs in GIL are models of GIL concepts. A concept is a set of
> requirements that a type (or a set of related types) must fulfill to be used
> correctly in generic algorithms. The requirements include syntactic and
> algorithmic guarantees."_

Three commitments follow and recur through the code:

1. **Views, not containers, are the algorithm interface.** An `image_view` is shallow
   and non-owning, "what ranges are to STL containers" ([`image_view.hpp`][view]);
   `image` owns memory and hands out views.
2. **Transformations are types, not copies.** Flips, rotations, subsampling, channel
   extraction and colour conversion return a new view type whose locator or
   dereference function does the work lazily ([`image_view_factory.hpp`][factory-geom]).
3. **Run-time polymorphism is opt-in and coarse.** `any_image_view` "does not fully
   model `ImageViewConcept`" because per-pixel access "would be inefficient to provide"
   ([`any_image_view.hpp`][any-view]).

**Adobe origin.** GIL was developed at Adobe by Lubomir Bourdev and Hailin Jin. It
first shipped inside the Adobe Source Libraries: ASL 1.0.12 (January 5, 2006) "added"
it, and the tutorial and design guide followed on January 16, 2006
([`news.dox`][asl-news-added]). It was accepted into Boost in late 2006, ASL 1.0.26
(April 5, 2007) shipped "GIL 2.0" ([`news.dox`][asl-news-boost]), and the first Boost
release was 1.35.0 (March 29, 2008) ([`RELEASES.md`][releases-135]). ASL no longer
carries GIL: ASL 1.0.43 (November 4, 2010) "Removed gil from ASL (clients can use boost
version instead)" ([`news.dox`][asl-news-removed]). At the pinned ASL revision no GIL
source remains; the only traces are release notes and links to the old
`stlab.adobe.com/gil` page in the documentation. The
original design is documented in the [2006 design guide][gil-guide], the 2007
[tutorial-length paper][gil-2007] and the [Bourdev and Järvi dispatch paper][bourdev-jarvi],
all annotated in the [generic image programming thread][p-generic].

---

## How it works

### The concept hierarchy

| Concept (header)                                                  | Refines                                       | Key requirements                                                                                          |
| ----------------------------------------------------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ChannelConcept` ([`concepts/channel.hpp`][c-channel])            | `EqualityComparable`                          | `channel_traits<T>` with `value_type`, `reference`, `pointer`, `is_mutable`, `min_value()`, `max_value()` |
| `ColorBaseConcept` ([`concepts/color_base.hpp`][c-colorbase])     | `CopyConstructible`, `EqualityComparable`     | `layout_t`, `kth_element_type<K>`, `at_c<K>` (physical), construction from compatible colour bases        |
| `PixelConcept` ([`concepts/pixel.hpp`][c-pixel])                  | `ColorBaseConcept`, `PixelBasedConcept`       | `is_pixel<P>`, every element a channel, `value_type`/`reference`/`const_reference`, `is_mutable`          |
| `PixelLocatorConcept` ([`concepts/pixel_locator.hpp`][c-locator]) | `RandomAccess2DLocatorConcept` → N-D, Regular | `difference_type` (a point), `axis<D>::iterator`, `cached_location_t`, `add_deref<Deref>`, `operator[]`   |
| `ImageViewConcept` ([`concepts/image_view.hpp`][c-view])          | `RandomAccess2DImageViewConcept` → N-D        | `locator`, `iterator` (1-D over all pixels), `axis_iterator<D>`, `dimensions()`, `is_1d_traversable()`    |
| `ImageConcept` ([`concepts/image.hpp`][c-image])                  | `RandomAccessNDImageConcept`, Regular         | `view_t`, `allocator_type`, construction and `recreate` with dimensions and alignment                     |

Each concept appears twice in the source: as N2081-style pseudo-code in a comment, and
as a Boost.ConceptCheck class whose `constraints()` member uses the required names
([`concepts/channel.hpp`][c-channel]):

```cpp
// include/boost/gil/concepts/channel.hpp (abridged)
template <typename T>
struct ChannelConcept
{
    void constraints()
    {
        gil_function_requires<boost::EqualityComparableConcept<T>>();
        using v = typename channel_traits<T>::value_type;
        using r = typename channel_traits<T>::reference;
        // ...
        channel_traits<T>::min_value();
        channel_traits<T>::max_value();
    }
    T c;
};
```

**The checks are off by default.** `gil_function_requires` and
`BOOST_GIL_CLASS_REQUIRE` expand to nothing unless `BOOST_GIL_USE_CONCEPT_CHECK` is
defined ([`concept_check.hpp`][concept-check]):

```cpp
// include/boost/gil/concepts/concept_check.hpp
#ifdef BOOST_GIL_USE_CONCEPT_CHECK
    #define BOOST_GIL_CLASS_REQUIRE(type_var, ns, concept) \
        BOOST_CLASS_REQUIRE(type_var, ns, concept);
    template <typename Concept>
    void gil_function_requires() { function_requires<Concept>(); }
#else
    #define BOOST_GIL_CLASS_REQUIRE(type_var, ns, concept)
    template <typename C>
    void gil_function_requires() {}
#endif
```

The guide gives the reason: _"It is unset by default, because there is a significant
increase in compile time when using concept checks"_ ([`image_view.adoc`][doc-view-check]).
**Verified:** `gil_function_requires<ImageViewConcept<not_a_view>>()` on an empty
struct compiles and links in a default build, and fails with
"no type named `xy_locator` in `struct not_a_view`" once the macro is defined. The
real models (`rgb8_view_t`, `bgr8_pixel_t`) pass with the macro on. The test suite
turns the macro on ([`test/CMakeLists.txt`][test-cmake-cc], [`test/core/Jamfile`][test-core-jam]), and one test switches it
off again because a range-as-pixel case does not satisfy the pixel concepts
([`std_fill.cpp`][test-stdfill]). No C++20 `concept` or `requires` clause appears
anywhere under `include/`: the concepts are still syntax checks that only the test
build runs, and dispatch inside algorithms is by traits and overloading.

### Channels

Any built-in arithmetic type is a channel; `channel_traits` supplies the range from
`std::numeric_limits` for non-class types. Two channel families need classes:

- **Scoped channels** change the nominal range of a base type.
  `scoped_channel_value<BaseChannelValue, MinVal, MaxVal>` stores the base value and
  answers `min_value()`/`max_value()` from two policy types ([`channel.hpp`][channel-scoped]).
  GIL's floating-point channels are scoped: `float32_t` is
  `scoped_channel_value<float, float_point_zero<float>, float_point_one<float>>`, so
  `channel_convert` maps `1.0f` to `255` or `65535` ([`typedefs.hpp`][typedefs-float]).
- **Packed (sub-byte) channels** live in a bit range of an integral. Their values
  cannot be the underlying integer, because "Two channels are declared compatible if
  they have the same value type. That means that a packed channel is incorrectly
  declared compatible with an integral type" ([`channel.hpp`][channel-packed-why]).
  References are proxies: `packed_channel_reference<BitField, FirstBit, NumBits, IsMutable>`
  fixes the offset at compile time, `packed_dynamic_channel_reference` keeps it at run
  time ([`channel.hpp`][channel-packed]). `packed_pixel` and
  `bit_aligned_pixel_reference` build RGB565 or 1-bit pixels from them. **Verified:**
  `packed_pixel_type<uint16_t, mp_list_c<unsigned,5,6,5>, rgb_layout_t>::type` has
  `sizeof` 2.

### Colour spaces, layouts and colour bases

A colour space is a type list of empty tag structs, and a layout pairs it with a
permutation from semantic to physical order ([`rgb.hpp`][rgb], [`utilities.hpp`][layout]):

```cpp
// include/boost/gil/rgb.hpp
using rgb_t = mp11::mp_list<red_t, green_t, blue_t>;
using rgb_layout_t = layout<rgb_t>;
using bgr_layout_t = layout<rgb_t, mp11::mp_list_c<int, 2, 1, 0>>;
```

A colour base is indexed two ways: `at_c<K>` by memory position, `semantic_at_c<K>` by
position in the colour space, and `get_color(p, red_t())` by tag
([`concepts/color_base.hpp`][c-colorbase]). Assignment between compatible pixels
(same colour space, same channel types) copies by colour, not by position.
**Verified:** for `bgr8_pixel_t b(10, 20, 30)`, `at_c<0>(b)` is 10 (blue),
`semantic_at_c<0>(b)` and `get_color(b, red_t())` are 30, and `rgb8_pixel_t r = b`
gives `at_c<0>(r) == 30`. Each `pixel<uint8_t, rgb_layout_t>` is 3 bytes with no
padding.

### Interleaved and planar pixels

An interleaved pixel is a `pixel<Channel, Layout>` value and its iterator a plain
pointer. A planar pixel has no address, so GIL represents its reference and its
iterator as colour bases of channel references and channel pointers
([`planar_pixel_reference.hpp`][planar-ref], [`planar_pixel_iterator.hpp`][planar-it]):

```cpp
// include/boost/gil/planar_pixel_reference.hpp (abridged)
template <typename ChannelReference, typename ColorSpace>
struct planar_pixel_reference : detail::homogeneous_color_base
    <ChannelReference, layout<ColorSpace>, mp11::mp_size<ColorSpace>::value>
{
    using value_type = pixel<channel_t, layout<ColorSpace>>;
    // ...
};
```

The proxy cannot bind to a non-const lvalue reference, so generic code must take
pixels by value or forwarding reference, and the proxy declares its assignment
`const` ([`technicalities.adoc`][doc-tech]). **Verified:** the reference returned by
`view(rgb8_planar_image_t(2, 1))(0, 0)` is 24 bytes (three pointers), and writing
`rgb8_pixel_t(1,2,3)` through it lands in three separate planes. The planar iterator
is now built on Boost.STLInterfaces' `iterator_interface`, with a
`BOOST_STL_INTERFACES_USE_DEDUCED_THIS` branch for C++23's explicit object parameter.

### Locators, step iterators and views

A **step iterator** advances by a run-time number of memory units (bytes, or bits for
bit-aligned pixels); "Common use is a vertical traversal, where the step is the row
stride" ([`step_iterator.hpp`][step]). A `memory_based_2d_locator` is a step iterator
whose base iterator moves along x ([`locator.hpp`][locator-doc]). A view is a locator
plus dimensions; its 1-D `iterator` (`iterator_from_2d`) walks rows in order, and
`is_1d_traversable()` asks whether rows have no gap so one flat loop suffices
([`locator.hpp`][locator-1d]). **Verified:** on x86-64 an `rgb8_view_t` is 32 bytes and
its locator 16 (pointer plus row stride); at C++14 and C++17 a planar CMYK locator is
40 bytes and its subsampled variant 48. A rerun with GCC 16.2.0 gave 48 and 64 for the
same two types at C++20 and C++23; the cause was not investigated. The header comment's "8 bytes total" for the RGB locator is a
32-bit figure.

Views compose by changing the locator type. The factory functions
([`image_view_factory.hpp`][factory-geom]) build:

| Function                                                   | Mechanism                                                                    |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `subimage_view(v, x, y, w, h)`                             | same type; new top-left locator and dimensions                               |
| `subsampled_view(v, sx, sy)`                               | `dynamic_xy_step_type`: x step of `sx` pixels, y step of `sy` rows           |
| `flipped_up_down_view`, `flipped_left_right_view`          | negative y or x step from the last row or column                             |
| `transposed_view`, `rotated90cw_view`, `rotated90ccw_view` | swapped steps (`transpose = true`) with signs                                |
| `rotated180_view`                                          | both steps negative                                                          |
| `nth_channel_view(v, n)`                                   | gray view with step `pixel_size` over interleaved data, or a plane pointer   |
| `color_converted_view<DstP>(v[, cc])`                      | `add_deref` with `color_convert_deref_fn`; the identity when the types match |
| `kth_channel_view<K>(v)`                                   | as `nth_channel_view`, with the channel fixed at compile time                |

`nth_channel_view` picks its representation by a trait: channels "adjacent in memory"
(planar or single-channel, no step) become a plain interleaved gray view over one
plane; otherwise a step iterator with step `pixel_size()` walks one channel of
interleaved data ([`image_view_factory.hpp`][factory-nth]). **Verified:**
`nth_channel_view(view(rgb8 image), 1)` reports `iterator_is_step` true and reads the
green channel; `rotated90cw_view` of a 4×2 view is 2×4; and
`color_converted_view<gray8_pixel_t>` of `(5, 6, 7)` reads 6.

A `virtual_2d_locator` calls a function object with the coordinates on dereference, so
procedural images (the guide's Mandelbrot example) are views too
([`virtual_locator.hpp`][virtual-locator]).

### Images and allocation

`image<Pixel, IsPlanar, Alloc>` owns one allocation obtained from an allocator rebound
to `unsigned char`, with an optional row alignment in bytes. Planar images put all
planes in that one block, `plane_size` apart ([`image.hpp`][image-planar]). The row
size is `width * memunit_step` rounded up to the alignment; the total is row size times
height, times the channel count for planar images, plus alignment slack
([`image.hpp`][image-size]). `recreate` reuses the block when it is large enough. Since
Boost 1.80 there are `pmr::` image typedefs over `std::pmr::polymorphic_allocator`
([`RELEASES.md`][releases-pmr]).

### Run-time types: `any_image` and `any_image_view`

```cpp
// include/boost/gil/extension/dynamic_image/any_image.hpp (abridged)
template <typename ...Images>
class any_image : public variant2::variant<Images...>
{
    using view_t = mp11::mp_rename<detail::images_get_views_t<any_image>, any_image_view>;
    void recreate(point_t const& dims, unsigned alignment=1)
    {
        variant2::visit(detail::recreate_image_fnobj(dims, alignment), *this);
    }
    // ...
};
```

Since Boost 1.74 the variant is Boost.Variant2 ([`RELEASES.md`][releases-variant2]) and
the old `apply_operation` is a `[[deprecated("Use variant2::visit instead.")]]` forwarder
([`apply_operation.hpp`][apply-op]). Algorithms such as `copy_pixels` and
`copy_and_convert_pixels` have `any_image_view` overloads that visit once and call the
static version. The guide warns that variants "instantiate the algorithm for every
possible model that the variant can take. This can take a toll on compile time and
executable size" ([`dynamic_image.adoc`][doc-dynamic]). The original answer to that,
Bourdev and Järvi's type reduction, existed as `extension/dynamic_image/reduce.hpp` and
was removed in Boost 1.73 "as unused and possibly unfinished"
([`RELEASES.md`][releases-reduce]). Today every member of the type list, and every pair
in a binary visit, is instantiated.

### The I/O extension

The I/O layer ("I/O v2", accepted into Boost in 2011 and shipped in 1.68,
[`RELEASES.md`][releases-io2]) is organised per
format into a tag (`png_tag`), `image_read_info`, `image_read_settings`,
`image_write_info`, a `reader_backend` (header parsing), a `reader` (pixels), a
`scanline_reader`, and a writer pair ([`io/base.hpp`][io-base]). Devices wrap `FILE*`
(`file_stream_device`), `std::istream` and `std::ostream` ([`io/device.hpp`][io-device]).
The front door is a family of free functions:

| Function                           | Behaviour                                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------------------------- |
| `read_image_info(file, tag)`       | parse the header only; returns the backend with `_info`                                   |
| `read_image(file, img, settings)`  | allocate `img` to the file's (or the requested) size; fail if `is_read_supported` says no |
| `read_view(file, view, settings)`  | decode into caller-owned pixels after `check_image_size`                                  |
| `read_and_convert_image` / `_view` | decode, then colour-convert per row through a conversion policy                           |
| `read_image(file, any_image, tag)` | pick the first type in the list the file can produce (`construct_matched`), then visit    |
| `make_scanline_reader(file, tag)`  | an input iterator over raw rows (`scanline_read_iterator`)                                |
| `write_view(file, view, info)`     | encode a view                                                                             |

Partial reads are a pair of points on `image_read_settings_base` (`_top_left`, `_dim`).
In the PNG reader the decoder still runs over every row: it skips `_top_left.y` rows,
copies `_dim.y` rows starting at column `_top_left.x`, then reads "the rest of the image.
libpng needs that" ([`png/detail/read.hpp`][png-read]). Run-time format matching walks
the `any_image` list with a predicate (`construct_matched`, [`io/detail/dynamic.hpp`][dyn-io]),
and each format's reader throws "No matching image type" if none fits
([`png/detail/read.hpp`][png-read-any]).

**Verified:** an 8×8 non-interlaced gray PNG read with `_top_left = (2,3)`,
`_dim = (3,2)` yields `26 27 28 34 35 36`, as expected. Reading it into
`any_image<gray8_image_t, rgb8_image_t, rgba16_image_t>` selects index 0; into
`any_image<rgb8_image_t, rgba16_image_t>` it throws "No matching image type between
those of the given any_image and that of the file"; into a plain `rgb8_image_t` it
throws "Image types aren't compatible."; `read_and_convert_image` into `rgb8_image_t`
gives `(11, 11, 11)` at `(3, 1)`.

---

## Analysis

### 1. Pixel and memory model

The model is a 2-D strided grid of pixels with the stride in memory units and the
pixel layout in the type. Interleaved, planar (one pointer per plane, shared row
stride), packed and bit-aligned layouts are first-class; steps can be negative, which
is how flips and rotations are free. The N-D concepts (`RandomAccessNDLocatorConcept`,
`RandomAccessNDImageViewConcept`) exist, but every shipped model is 2-D
(`image_view::num_dimensions = 2`). There are no tiles, no per-plane dimensions and
no per-plane strides: planar images share one row stride and one extent, so 4:2:0
chroma does not fit the core model. The toolbox's `subchroma_image` is a separate,
special-purpose type. Coordinates are `std::ptrdiff_t`. The design favours iteration
(locators, `x_iterator`, `y_iterator`, `cached_location_t` for repeated neighbourhood
offsets) over an extents-plus-strides descriptor; the [paper thread][p-generic] records
VIGRA's later move the other way.

### 2. Genericity mechanism

Concepts as documentation plus opt-in Boost.ConceptCheck classes; traits and
metafunctions (`channel_traits`, `color_space_type`, `is_planar`, `num_channels`,
`dynamic_x_step_type`, `transposed_type`, `iterator_is_step`) for introspection;
tag dispatch, partial specialisation and `std::enable_if` for selection; Boost.Mp11
type lists for colour spaces and layouts. Optional capabilities are expressed as
separate concepts (`HasDynamicXStepTypeConcept`, `HasTransposedTypeConcept`,
`MemoryBasedIteratorConcept`) whose metafunction answers decide which view a
transformation returns, which is design by introspection in C++14 form. What it lacks
is a checked boundary: with checks off, a non-model fails deep inside an
instantiation, and with them on, only syntax is checked. Planar and sub-byte pixels
force proxy references through the whole hierarchy, so every concept carries
`reference` and `const_reference` beside `value_type`.

### 3. Colour and metadata

Colour spaces are tags without semantics. `default_color_converter` is a table of
specialisations, and the source says "Accurate color conversion using color profiles
can be supplied separately in a dedicated module" ([`color_convert.hpp`][color-convert]).
RGB to gray applies 0.30/0.59/0.11 weights directly to the stored (gamma-encoded)
values, with a fixed-point 8-bit path ([`color_convert.hpp`][color-convert-luma]); no
transfer function is applied. The toolbox `xyz` space states "rgb_t is assumed to be
sRGB D65" and applies the sRGB curve ([`xyz.hpp`][xyz]). Alpha is an ordinary channel;
`premultiply.hpp` offers an explicit `channel_premultiply` step, and no type records
whether a pixel is premultiplied. Metadata is per format and partial: PNG exposes gamma,
`iCCP` profile bytes, `sRGB` intent, chromaticities and text chunks as `image_read_info`
fields ([`png/tags.hpp`][png-tags]); nothing models EXIF, XMP, CICP or HDR, and the ICC
bytes are carried but never applied.

### 4. I/O and codec architecture

Pull, whole-image and synchronous. The reader drives the C library to the end of the
image inside one call; the only incremental surface is `scanline_reader`, an input
iterator that yields raw rows. There is no push or suspendable decode, no
cancellation, no progress callback and no async device. Format support is resolved at
compile time (`is_read_supported<Pixel, FormatTag>`, `is_allowed`) and at run time by
matching the header against a closed type list. Errors are exceptions:
`io_error` throws `std::ios_base::failure` ([`io/error.hpp`][io-error]), and the PNG
reader installs an error callback that throws through libpng's C frames
([`png/detail/reader_backend.hpp`][png-reader-backend]). TIFF can select a directory
(page) and reads tiled files ([`tiff/detail/reader_backend.hpp`][tiff-dir],
[`tiff/detail/read.hpp`][tiff-tiled]). Partial reads clip rows and columns after
decoding, so they save memory, not decode work.

**Verified defects in the PNG path.** A gray 8×8 Adam7-interlaced PNG, written with
libpng directly and decoded correctly by libpng's simplified API, reads back through
GIL's `read_image` with 32 of 64 pixels wrong; a partial read of it returns
`0 0 4 0 0 4` instead of `26 27 28 34 35 36`. The reader calls
`png_set_interlace_handling` ([`png/detail/read.hpp`][png-read-interlace]) but reads earlier passes into a single reused row buffer
and discards them ([`png/detail/read.hpp`][png-read]), and libpng's interlace handling
combines each pass with the row's previous contents; the 32 correct pixels are the odd
rows that Adam7's last pass fills alone. Writing with `_interlace_method =
PNG_INTERLACE_ADAM7` fails with "libpng error: No IDATs written into file" and then
segfaults. The writer emits each row once ([`png/detail/write.hpp`][png-write]), and its
`setjmp` sits in the backend constructor ([`png/detail/writer_backend.hpp`][png-writer-backend]),
so libpng's later `longjmp` targets a frame that has already returned. The mechanisms
are read from source; the outcomes were run.

### 5. Hostile input and safety

GIL trusts dimensions. Bounds checks are `BOOST_ASSERT` calls on `operator()`, `at`
and `xy_at` ([`image_view.hpp`][view-access]), compiled out under `NDEBUG`, and
`subimage_view` does not check its extent at all ([`image_view_factory.hpp`][factory-sub]).
Size arithmetic in `image` multiplies `width * memunit_step` and the row size by the
height in `std::size_t` without an overflow check ([`image.hpp`][image-size]). Header
parsers accept the codec's dimensions with no upper bound; the BMP reader reads width,
height and colour count straight from the file ([`bmp/detail/reader_backend.hpp`][bmp-backend]),
and no maximum-size setting exists in `io/`. Codec memory safety is inherited from
libpng, libjpeg and libtiff. No fuzzing harness exists in the tree and the CI workflow
runs no sanitizer job ([`ci.yml`][ci-yml]).

**Verified, under AddressSanitizer at `-O0` with assertions live:**

- `subimage_view(view(gray8 4×4), 2, 2, 64, 64)` constructs without an assertion, and
  `copy_pixels` from it reads past the 16-byte allocation (`heap-buffer-overflow`).
- `gray8_image_t img((1 << 62) + 1, 4)` wraps the size to 4 bytes; the view still
  reports width 2⁶²+1, so `view(img)(1000, 0) = 7` passes `BOOST_ASSERT` and writes 996
  bytes past the allocation.

GIL also overloads `std::copy` for `pixel` pointers inside `namespace std`
([`algorithm.hpp`][algo-std]). Adding declarations to `std` is undefined behaviour
unless the standard says otherwise ([`[namespace.std]`][cpp-namespace-std]), though it
works on the compilers in CI.

### 6. Allocation and ownership

Ownership is binary: `image` owns one block from an allocator; everything else
(views, locators, iterators, `any_image_view`) borrows with no lifetime tracking, and
"It is the user's responsibility that the underlying data remains valid for the
lifetime of the image view" ([`image_view.hpp`][view]). The allocator is a template
parameter, so arenas and PMR work without changes to algorithms. Algorithms allocate
internally where they need scratch: the row convolution builds a `std::vector` buffer
per call ([`image_processing/convolve.hpp`][convolve]) and the PNG writer a
`std::vector` row ([`png/detail/write.hpp`][png-write]). The I/O front door allocates
the destination unless `read_view` is used with caller pixels. Constness follows the
STL range rule: a `const` view can still write pixels; only a view over `const` values
cannot.

### 7. CPU parallelism and SIMD

None in the library. There is no thread, no `std::execution` policy, no OpenMP pragma
and no intrinsic under `include/` (a search for `simd`, `_mm_`, `std::execution`,
`#pragma omp` and `std::thread` returns nothing). Performance comes from the compiler
seeing concrete types and from overload ladders: `copy_pixels` calls `std::copy` once
for two 1-D-traversable views and once per row otherwise, and GIL's `std::copy`
overloads reduce same-type interleaved pixels to a byte copy and planar pixels to one
copy per plane, so the header says it "may result in a single call to `memmove`"
([`algorithm.hpp`][algo-doc]). The integer
fast path for RGB-to-gray luminance is the only hand-specialised arithmetic. Vectorising
or parallelising is left to the optimiser or to the caller, who can split a view into
`subimage_view` strips.

### 8. GPU offload and interop

Not applicable: GIL has no GPU code, no device-memory allocator and no interop
descriptor. What transfers is the memory model: an interleaved view's
`interleaved_view_get_raw_data` and `planar_view_get_raw_data` expose base pointers and
the row stride ([`image_view_factory.hpp`][factory-raw]), which is the information an
upload path needs. Nothing records alignment requirements beyond the row alignment
chosen at construction.

### 9. Temporal, animation and containers

Not applicable: there is no frame, timestamp, animation or sequence type. The formats
are stills; GIF is not supported. The nearest feature is TIFF directory selection for
multi-page files. Multi-image containers would be ranges of images outside GIL.

### 10. Testing and conformance

The core tests (109 `.cpp` files under `test/core`) are unit and compile tests,
built with concept checks on. The I/O tests have three tiers gated by macros:
`BOOST_GIL_IO_TEST_ALLOW_READING_IMAGES` and `_WRITING_IMAGES` (enabled in the
Jamfiles; the CMake build compiles one I/O smoke test only,
[`test/extension/io/CMakeLists.txt`][test-io-cmake]), and `BOOST_GIL_IO_USE_PNG_TEST_SUITE_IMAGES`, which no build defines; the
PNG Jamfile carries "TODO: Download PNG test suite images"
([`png/Jamfile`][test-png-jam]). The repository holds 9 PngSuite files; the
interlaced cases (`BASI0G01.PNG` …) are referenced only inside the disabled block
([`png_read_test.cpp`][test-png-interlaced]). The per-file check is a round trip, read,
write, read again and `equal_pixels` ([`png_read_test.cpp`][test-png]), which cannot
catch a decoder that is consistently wrong, and no reference decoder is compared.
That is how the Adam7 defect in §4 coexists with a green suite. Coverage is reported
to Codecov; there is no fuzzing.

---

## Lessons for Sparkles

- **Q2.** GIL's concept list is the right inventory for a D trait family: one trait per
  layer (`isChannel`, `isColorBase`, `isPixel`, `isLocator`, `isImageView`, `isImage`)
  plus capability traits (`hasDynamicStep`, `isTransposable`, `isMemoryBased`,
  `isOneDTraversable`). What does not transfer is the opt-in check: a D trait is an
  `enum bool` over `is(typeof(...))`, checked on every build at negligible cost, so a
  constraint failure is reported at the call. **Verified:** a D `isImageView` trait
  accepts a planar view struct and rejects an unrelated struct in `static assert`s,
  compiled with `-betterC -preview=dip1000`. As with GIL, it checks syntax only;
  negative tests and documented axioms are still needed ([papers][p-generic],
  [DbI guidelines][dbi]).
- **Q1, Q2.** Planar and sub-byte pixels are where GIL's complexity comes from: proxy
  references, `const` assignment operators and a `reference` type on every concept. D
  can avoid most of it with `opIndex` returning a value plus `opIndexAssign`, and `ref`
  returns for interleaved storage. **Verified:** a planar RGB8 view with that pair runs
  `@safe pure nothrow @nogc` under `-betterC -preview=dip1000`. The probe also showed
  the cost: a view over stack planes is `scope`, so its members must be `scope` or
  dip1000 rejects the calls. Element-wise mutation through a proxy (`p.r += 1`) has no
  equivalent; the [baseline][bl-existing] has no view type at all yet (G2).
- **Q1.** GIL's locator stores a byte stride, not an element stride, and supports
  negative steps, so flips, rotations, channel extraction and subsampling are
  zero-copy. A D view should keep both properties. GIL's single shared row stride and
  extent for all planes is the part that fails YUV 4:2:0 and tiled formats; per-plane
  extents and strides are the gap to close ([baseline][bl-existing] G2,
  [shaders-simd][bl-shaders] G10).
- **Q3.** The `copy_pixels` ladder (one `std::copy` that the STL can reduce to `memmove`,
  one per plane, one per row) selected by `is_1d_traversable` and pixel identity maps onto `static if`
  over contiguity traits. In GIL the 1-D check is a run-time comparison of row size and
  width; a D view could carry contiguity in its type as mir's `SliceKind` does, making
  the choice static. GIL's lack of any SIMD or threading layer means it offers no model
  for [shaders-simd][bl-shaders] G4 and G5.
- **Q4, Q9.** `any_image` is exactly a `SumType` over image types with `match` per
  call. GIL's history is the warning: the type-reduction header that bounded
  instantiation count was removed as unfinished, and binary visits multiply the set.
  A D design that wants a run-time decoder front door needs its own reduction, a
  closed and canonicalised output set per codec, or both, decided with a measured
  binary size.
- **Q4.** The I/O split (info, settings, backend, reader, scanline reader, devices)
  separates the right concerns, but it is pull-only, whole-image and exception-based,
  and partial reads still decode every row. Sparkles' `nothrow @nogc` and
  `Expected` rules ([AGENTS][agents-expected]) and the need for suspendable decode
  ([wired baseline][bl-wired] G3) both point away from it. The C-library error bridge
  is also a hazard: GIL throws through libpng frames on read and `longjmp`s into a dead
  frame on write.
- **Q5.** Untyped colour-space tags let gamma-encoded RGB be averaged as if linear (the
  0.30/0.59/0.11 luminance) and leave premultiplication to convention. Sparkles already
  has a premultiplied/straight split ([baseline][bl-existing] G3, G4); GIL is evidence
  for putting transfer function and alpha state in the pixel type rather than in tags.
- **Q5.** Colour conversion as a lazy view (`color_converted_view`) and as the policy
  inside `read_and_convert_*` is a good shape: one auditable conversion hook used both
  for I/O and for algorithms. An output-range writer version would let it feed
  `sparkles.base.buffer` storage without an intermediate image.
- **Q8.** GIL's bounds model is debug assertions and a trusted header. Both verified
  overflows (unchecked `subimage_view` extent, wrapping `width * height`) are what a
  hostile header produces. Validate stride times extent against the backing buffer at
  view construction, with checked multiplication, and keep `size_t` indices
  ([papers][p-hostile]).
- **Q8.** A round-trip test cannot catch a decoder that is wrong both ways, and an
  opt-in corpus is a corpus nobody runs. The Sparkles PNG oracle compares against
  stb_image over PngSuite and asserts the file count ([baseline][bl-existing] G11), which
  is the stronger shape; GIL's Adam7 defect is a concrete case it would catch.
- **Q9.** GIL is one library with optional extensions (`io`, `dynamic_image`,
  `numeric`, `toolbox`), where core headers never include I/O and each format pulls in
  only its C library. The split runs along dependencies, not along "core versus
  algorithms": the algorithms live in core, the numeric extension's convolution has
  moved into core `image_processing` and its old header now only emits a deprecation
  ([`extension/numeric/convolve.hpp`][convolve-deprecated]). That is evidence that the
  algorithm layer does not stay separate from the pixel layer for long.
- **Q2, Q9.** GIL needs Boost.Mp11, Variant2, STLInterfaces and ConceptCheck, and its
  I/O needs Boost.Filesystem or C++17. D gets the equivalent (type lists, `SumType`,
  ranges, constraints) from the language and Phobos, which keeps the betterC, wasm and
  Android builds within reach in a way GIL's dependency set would not.

## Strengths

- The most complete concept decomposition of images in the survey: channel, colour
  base, pixel, iterator, locator, view and image, each with mutable and value
  refinements.
- Layout, depth, order and planarity are compile-time parameters, and algorithms
  written once work over all of them, including user-defined pixel types.
- Zero-copy view transformations (flip, rotate, transpose, subsample, subimage,
  channel, colour conversion, virtual images) compose by type.
- Physical versus semantic channel indexing makes BGR and RGB interoperate correctly by
  construction.
- The `copy_pixels` overload ladder shows how generic code reaches `memmove` without
  giving up genericity.
- Allocator-aware images, including PMR, with one block per image.
- Builds on C++14 through C++23 unchanged (verified with GCC 14.3.0 and 16.2.0 for the
  core probes; CI covers 14 to 23, C++23 with Clang 18 to 20).

## Weaknesses

- Concept checks are off by default and verify syntax only; a non-model fails deep in an
  instantiation.
- Proxy references for planar and sub-byte pixels leak into every concept and every
  generic signature.
- Bounds checks are debug assertions; size arithmetic and `subimage_view` extents are
  unchecked (both verified as heap overflows).
- No colour management, no transfer functions, untyped alpha state, and luminance
  computed on encoded values.
- Run-time dispatch instantiates every variant member and every pair; the type-reduction
  work was removed unfinished.
- Pull-only, exception-based, whole-image I/O; partial reads do not save decode work.
- Interlaced PNG reading is wrong and interlaced PNG writing crashes (verified); the
  tests that would catch the first are disabled and round-trip only.
- No SIMD, threading, GPU or temporal model; a planar model with one shared extent cannot
  express chroma subsampling.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                            | Trade-off                                                                                    |
| -------------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Pixel layout, depth, order and planarity in the type           | Code specialised per format, written once                            | Instantiation count and compile time grow with every format; run-time formats need a variant |
| Concepts as Boost.ConceptCheck classes, off by default         | Readable requirements without paying compile time in user builds     | Errors surface deep in instantiations; only the test build checks; syntax, not semantics     |
| Proxy references for planar and sub-byte pixels                | Planar and packed pixels model the same concepts as interleaved ones | Every concept carries `reference`; proxies cannot bind to `T&`; harder user-defined models   |
| Layout as a colour space plus a permutation                    | BGR, ARGB and others share the RGB colour space and convert by tag   | Channel order is a type parameter, multiplying instantiations further                        |
| Views as locator plus dimensions; transformations as new types | Flips, rotations, channel and colour views are zero-copy and inlined | Each transformation changes the static type; deep compositions produce long, opaque types    |
| Byte (memory-unit) strides with negative steps                 | One locator type covers padding, flips and channel extraction        | Shared stride and extent for all planes; no per-plane geometry for subsampled formats        |
| `any_image` as a variant over a closed type list               | One dispatch per algorithm call, static code inside                  | Every member and pair instantiated; type reduction removed; per-pixel access unavailable     |
| I/O as thin per-format layers over C codecs                    | Mature decoders, small own code, format-specific metadata exposed    | Inherits C-library error models (exceptions through C, `longjmp`); no suspendable decode     |
| Bounds checks as `BOOST_ASSERT`                                | No run-time cost in release builds                                   | Hostile dimensions and bad extents become silent out-of-bounds access                        |
| Algorithms delegate to STL with overloads, no SIMD layer       | Portable, compiler-optimised, simple                                 | No explicit vectorisation, threading or GPU path; overloads in `namespace std`               |

---

## Sources

- [boostorg/gil repository][repo] at `97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41`
- [Boost.GIL documentation][docs] · [develop documentation][docs-dev]
- [`README.md` — C++14 requirement][readme] · [`RELEASES.md` — release history][releases-186] · [`CMakeLists.txt` — standard selection][cmake-std]
- Concepts: [`concept_check.hpp`][concept-check] · [`channel.hpp`][c-channel] · [`color_base.hpp`][c-colorbase] · [`pixel.hpp`][c-pixel] · [`pixel_locator.hpp`][c-locator] · [`image_view.hpp`][c-view] · [`image.hpp`][c-image]
- Models: [`channel.hpp` scoped][channel-scoped] · [`channel.hpp` packed][channel-packed] · [`rgb.hpp`][rgb] · [`planar_pixel_reference.hpp`][planar-ref] · [`planar_pixel_iterator.hpp`][planar-it] · [`step_iterator.hpp`][step] · [`locator.hpp`][locator-doc] · [`virtual_locator.hpp`][virtual-locator] · [`image_view.hpp`][view] · [`image.hpp`][image-size]
- Views and algorithms: [`image_view_factory.hpp`][factory-geom] · [`algorithm.hpp`][algo-doc] · [`color_convert.hpp`][color-convert] · [`image_processing/convolve.hpp`][convolve]
- Dynamic images: [`any_image.hpp`][any-image] · [`any_image_view.hpp`][any-view] · [`apply_operation.hpp`][apply-op]
- I/O: [`io/base.hpp`][io-base] · [`io/device.hpp`][io-device] · [`io/detail/dynamic.hpp`][dyn-io] · [`png/detail/read.hpp`][png-read] · [`png/detail/writer_backend.hpp`][png-writer-backend] · [`bmp/detail/reader_backend.hpp`][bmp-backend]
- Design guide pages: [`basics.adoc`][doc-basics] · [`concepts.adoc`][doc-concepts] · [`image_view.adoc`][doc-view-check] · [`dynamic_image.adoc`][doc-dynamic] · [`technicalities.adoc`][doc-tech]
- Tests and CI: [`test/CMakeLists.txt`][test-cmake-cc] · [`png_read_test.cpp`][test-png-main] · [`png/Jamfile`][test-png-jam] · [`ci.yml`][ci-yml]
- Adobe origin: [stlab/adobe-source-libraries][asl-repo] at `1004bc351e7b79ab9e1ae545e50ad900eb6f81d9`, [`news.dox`][asl-news-removed]
- Bourdev and Jin, [Generic Image Library design guide][gil-guide] (2006) · Bourdev, [Generic Image Library][gil-2007] (2007) · Bourdev and Järvi, [Efficient run-time dispatching in generic programming with minimal code bloat][bourdev-jarvi] (2011)
- Related in this catalog: [umbrella][umbrella] · [generic image programming papers][p-generic] · [hostile input papers][p-hostile] · baselines [existing code][bl-existing], [shaders and SIMD][bl-shaders], [wired][bl-wired]

<!-- References -->

[repo]: https://github.com/boostorg/gil
[docs]: https://www.boost.org/libs/gil
[docs-dev]: https://boostorg.github.io/gil/develop/
[license]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/LICENSE.txt
[readme]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/README.md#L21-L23
[releases-186]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/RELEASES.md#L6-L31
[releases-pmr]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/RELEASES.md#L46-L54
[releases-variant2]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/RELEASES.md#L100-L108
[releases-io2]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/RELEASES.md#L242-L254
[releases-reduce]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/RELEASES.md#L138-L141
[releases-135]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/RELEASES.md#L269-L276
[cmake-std]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/CMakeLists.txt#L40-L84
[concept-check]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/concept_check.hpp#L38-L56
[c-channel]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/channel.hpp#L41-L91
[c-colorbase]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/color_base.hpp#L83-L135
[c-pixel]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/pixel.hpp#L37-L90
[c-locator]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/pixel_locator.hpp#L50-L101
[c-view]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/image_view.hpp#L51-L100
[c-image]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/concepts/image.hpp#L33-L54
[channel-scoped]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/channel.hpp#L134-L224
[channel-packed-why]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/channel.hpp#L226-L233
[channel-packed]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/channel.hpp#L440-L465
[typedefs-float]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/typedefs.hpp#L153-L157
[rgb]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/rgb.hpp#L20-L40
[layout]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/utilities.hpp#L254-L271
[planar-ref]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/planar_pixel_reference.hpp#L28-L63
[planar-it]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/planar_pixel_iterator.hpp#L31-L59
[step]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/step_iterator.hpp#L116-L175
[locator-doc]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/locator.hpp#L208-L230
[locator-1d]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/locator.hpp#L283-L292
[virtual-locator]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/virtual_locator.hpp#L18-L38
[view]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_view.hpp#L21-L51
[view-access]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_view.hpp#L254-L310
[image-size]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image.hpp#L422-L471
[image-planar]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image.hpp#L473-L498
[factory-raw]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_view_factory.hpp#L104-L125
[factory-geom]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_view_factory.hpp#L149-L275
[factory-sub]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_view_factory.hpp#L277-L326
[factory-nth]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_view_factory.hpp#L328-L381
[any-image]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/dynamic_image/any_image.hpp#L76-L139
[any-view]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/dynamic_image/any_image_view.hpp#L59-L72
[apply-op]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/dynamic_image/apply_operation.hpp#L15-L39
[io-base]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/io/base.hpp#L38-L104
[io-error]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/io/error.hpp#L15-L24
[io-device]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/io/device.hpp#L46-L49
[dyn-io]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/io/detail/dynamic.hpp#L20-L96
[png-reader-backend]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/detail/reader_backend.hpp#L589-L619
[png-read]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/detail/read.hpp#L250-L325
[png-read-interlace]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/detail/read.hpp#L137-L140
[png-read-any]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/detail/read.hpp#L400-L412
[png-write]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/detail/write.hpp#L100-L119
[png-writer-backend]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/detail/writer_backend.hpp#L56-L93
[png-tags]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/png/tags.hpp#L310-L395
[bmp-backend]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/bmp/detail/reader_backend.hpp#L90-L169
[tiff-dir]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/tiff/detail/reader_backend.hpp#L132-L134
[tiff-tiled]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/io/tiff/detail/read.hpp#L392-L394
[algo-doc]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/algorithm.hpp#L55-L72
[algo-std]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/algorithm.hpp#L139-L158
[color-convert]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/color_convert.hpp#L27-L47
[color-convert-luma]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/color_convert.hpp#L61-L83
[xyz]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/toolbox/color_spaces/xyz.hpp#L46-L56
[convolve]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/image_processing/convolve.hpp#L87-L133
[convolve-deprecated]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/include/boost/gil/extension/numeric/convolve.hpp#L10-L17
[doc-basics]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/doc/modules/ROOT/pages/design/basics.adoc#L26-L38
[doc-concepts]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/doc/modules/ROOT/pages/design/concepts.adoc#L1-L15
[doc-view-check]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/doc/modules/ROOT/pages/design/image_view.adoc#L304-L312
[doc-dynamic]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/doc/modules/ROOT/pages/design/dynamic_image.adoc#L208-L215
[doc-tech]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/doc/modules/ROOT/pages/design/technicalities.adoc#L3-L48
[test-cmake-cc]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/CMakeLists.txt#L21
[test-core-jam]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/core/Jamfile#L15
[test-io-cmake]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/extension/io/CMakeLists.txt#L11-L19
[test-stdfill]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/core/algorithm/std_fill.cpp#L8-L12
[test-png]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/extension/io/png/png_read_test.cpp#L34-L57
[test-png-interlaced]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/extension/io/png/png_read_test.cpp#L388-L396
[test-png-main]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/extension/io/png/png_read_test.cpp#L752-L775
[test-png-jam]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/test/extension/io/png/Jamfile#L15-L25
[ci-yml]: https://github.com/boostorg/gil/blob/97ed52cc034a68f0b1a3af0feb2fe3f49e9a8b41/.github/workflows/ci.yml#L20-L80
[asl-repo]: https://github.com/stlab/adobe-source-libraries
[asl-news-removed]: https://github.com/stlab/adobe-source-libraries/blob/1004bc351e7b79ab9e1ae545e50ad900eb6f81d9/documentation/structure/news.dox#L46-L71
[asl-news-boost]: https://github.com/stlab/adobe-source-libraries/blob/1004bc351e7b79ab9e1ae545e50ad900eb6f81d9/documentation/structure/news.dox#L525-L528
[asl-news-added]: https://github.com/stlab/adobe-source-libraries/blob/1004bc351e7b79ab9e1ae545e50ad900eb6f81d9/documentation/structure/news.dox#L743-L751
[cpp-namespace-std]: https://eel.is/c++draft/namespace.std
[gil-guide]: https://stlab.adobe.com/gil_design_guide.pdf
[gil-2007]: http://lubomir.org/pdfs/GIL_SDJ.pdf
[bourdev-jarvi]: https://doi.org/10.1016/j.scico.2008.06.003
[umbrella]: ./index.md
[p-generic]: ./papers/generic-image-programming.md
[p-hostile]: ./papers/hostile-input-safety.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[agents-expected]: ../../guidelines/idioms/expected/index.md
