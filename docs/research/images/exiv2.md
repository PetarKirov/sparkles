# Exiv2 (C++)

A C++ metadata library and command-line tool: typed Exif, IPTC and XMP containers over a per-format `Image` class hierarchy, a TIFF parser built as a Composite walked by Visitors, a large maker-note decoder, and a security history that turned a CVE-heavy parser into a fuzzed, bounds-checked one.

| Field         | Value                                                                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++20 ([`README.md`][ex-readme-build]); XMP through the bundled Adobe XMP Toolkit (`xmpsdk/`) and expat                                              |
| License       | GPL-2.0-or-later ([`README.md`][ex-readme-license])                                                                                                  |
| Repository    | [Exiv2/exiv2][ex-repo]                                                                                                                               |
| Revision read | `be479c1b7c27409582f62eaaac3a738130d869b1` (October 27, 2026, `main`, CMake version `1.00.0.9`, the 1.0 development line); shallow clone, one commit |
| Documentation | [exiv2.org][ex-site]; Doxygen comments in `include/exiv2/`; [`README.md`][ex-readme-welcome]; [`SECURITY.md`][ex-security]                           |
| Category      | Metadata: read, write and convert Exif, IPTC, XMP and ICC across about 30 still, RAW and video containers                                            |
| Tier          | B                                                                                                                                                    |
| Last reviewed | November 7, 2026                                                                                                                                     |

> [!NOTE]
> Claims marked **verified** were demonstrated with crafted little-endian TIFF files (90 to
> 3690 bytes) in `/tmp/exiv2-probe/` against the `exiv2` 0.28.8 command-line tool from nixpkgs (the
> pinned revision is later `main`; every check exercised below is present at both).
> The clone is shallow, so the history of individual CVE fixes could not be read from
> it. No performance number in this page was measured.

---

## Overview

### What it solves

Exiv2 reads and rewrites the [image metadata][c-metadata] embedded in a file without
touching its pixels. The README states the scope in one line
([`README.md`][ex-readme-welcome]):

> _"Exiv2 is a C++ library and a command-line utility to read, write, delete and
> modify Exif, IPTC, XMP and ICC image metadata."_

Every supported format has a class that knows where that format keeps each metadata
kind (JPEG `APP1`/`APP2`/`APP13` segments, PNG chunks, TIFF IFDs, ISOBMFF boxes,
RIFF chunks), and three format-independent containers hold the decoded result. RAW
formats such as CR2, NEF, ARW, ORF and RW2 are TIFF variants, so most of the
library's depth is a TIFF and maker-note engine.

### Design philosophy

The model is **typed and keyed**: every datum is a `Key` (`Exif.Photo.ExposureTime`,
`Iptc.Application2.Caption`, `Xmp.dc.subject`) bound to a polymorphic `Value` of a
declared type, held in a container with standard C++ iterators. The top-level class
comment sets out the division of labour ([`image.hpp`][ex-image-doc]):

> _"Image has containers to store image metadata and subclasses implement read and
> save metadata from and to specific image formats. Most client apps will obtain an
> Image instance by calling a static ImageFactory method."_

Writing is conservative by default: the encoder first tries to patch the original
bytes in place and only rebuilds the structure when it must
([`exif.hpp`][ex-exifparser]). Safety is a process rather than a design principle:
[`SECURITY.md`][ex-security-qualify] defines a security bug as one reachable with
_"a simple command like: `exiv2 poc-file`"_ and adds _"We also always treat OSS-Fuzz
crashes [...] as security issues."_ The defences in the code (checked buffers,
`enforce`, overflow-checked arithmetic, recursion limits) are retrofits, visible as
comments such as `// prevent out-of-bounds read in memcmp on next line` in the JPEG
reader ([`jpgimage.cpp`][ex-jpg-read]).

## How it works

### `ImageFactory` and the format registry

`ImageFactory::open` takes a path, a memory block or a `BasicIo`, then probes a
`constexpr` registry in order; each row names a constructor, a type check and the
access mode per metadata kind ([`image.cpp`][ex-registry]):

```cpp
constexpr Registry registry[] = {
    // image type       creation fct     type check  Exif mode    IPTC mode    XMP mode     Comment mode
    {ImageType::jpeg, newJpegInstance, isJpegType, amReadWrite, amReadWrite, amReadWrite, amReadWrite},
    // ...
    {ImageType::crw, newCrwInstance, isCrwType, amReadWrite, amNone, amNone, amReadWrite},
    // ...
    {ImageType::arw, newTiffInstance, isTiffType, amRead, amRead, amRead, amNone},
    // ...
    {ImageType::bmff, newBmffInstance, isBmffType, amRead, amRead, amRead, amNone},
```

The matching row's constructor receives the IO object and an `ImageCtorParams`
carrying `max_recursion_depth`, fixed at `1000` by the factory
([`image.cpp`][ex-factory-open]). Subclasses (`JpegImage`, `PngImage`, `TiffImage`,
`Cr2Image`, `BmffImage`, `QuickTimeVideo`, …) implement the pure virtuals
`readMetadata()` and `writeMetadata()` and fill `exifData_`, `iptcData_`, `xmpData_`,
`xmpPacket_`, `comment_` and `iccProfile_` ([`image.hpp`][ex-image-api]).

### `BasicIo`: one abstract stream

`BasicIo` is a seekable byte stream with `read`, `write`, `seek`, `tell`, and an
`mmap()` that gives "direct access to the IO data. For files, this is done by mapping
the file into the process's address space; for memory blocks, this allows direct
access to the memory block" ([`basicio.hpp`][ex-basicio-mmap]). Implementations are
`FileIo`, `MemIo`, `XPathIo` (stdin or a data URI spooled to a temporary file) and
`RemoteIo` with `HttpIo` and `CurlIo`. `RemoteIo` fetches in blocks and offers
`populateFakeData()` to "avoid allocating memory for parts of the file that contain
image-date (non-metadata/pixel data)" ([`basicio.hpp`][ex-basicio-fake]), so a remote
JPEG can be inspected without downloading its scan data.

Writes never edit the target in place at the stream level. `JpegBase::writeMetadata`
renders the whole new file into a `MemIo` and swaps it in with `transfer`
([`jpgimage.cpp`][ex-jpg-write]):

```cpp
  MemIo tempIo;

  doWriteMetadata(tempIo);  // may throw
  io_->close();
  io_->transfer(tempIo);  // may throw
```

### The three containers and the value model

`ExifData` is a `std::list` of `Exifdatum` ([`exif.hpp`][ex-exifdata]); `operator[]`
inserts a missing key, so lookups that should not mutate go through `findKey`.
`IptcData` and `XmpData` follow the same shape. Each datum's `Value` is created from a
`TypeId` ([`types.hpp`][ex-typeid]) that merges the twelve TIFF field types, the
BigTIFF 8-byte types, IPTC `string`/`date`/`time`, and XMP `xmpText`, `xmpAlt`,
`xmpBag`, `xmpSeq` and `langAlt`. The numeric values are one template,
`ValueType!T` in D terms, instantiated as `UShortValue`, `URationalValue`,
`DoubleValue` and so on ([`value.hpp`][ex-valuetype]).

Tag knowledge is compiled data. A `TagInfo` row holds tag number, name, title,
description, IFD, section, expected type, expected count and a `PrintFct` that turns
the raw value into a human string ([`tags.hpp`][ex-taginfo]); the IFD0 table opens
with `ProcessingSoftware` at `0x000b` ([`tags_int.cpp`][ex-ifdtaginfo]).
`Metadatum::print(const ExifData*)` passes the whole container to that function
([`metadatum.hpp`][ex-print]), because interpreting a maker-note lens id needs the
camera make, model and other tags.

Cross-standard mapping is a table of pairs in `convert.cpp`, for example
`Exif.Image.Orientation` to `Xmp.tiff.Orientation` ([`convert.cpp`][ex-convert]),
exposed as `copyExifToXmp`, `syncExifWithXmp`, `copyIptcToXmp` and their inverses.

### The TIFF engine: Composite plus Visitor

Exif is a TIFF structure, so every TIFF-family format and the Exif payload of JPEG,
PNG, WebP and HEIF go through `TiffParserWorker`. The parsed tree is a Composite of
`TiffComponent` nodes, each "uniquely identified by a tag, group tuple" and
implemented "as a NVI (Non-Virtual Interface) [with] an interface for visitors
(Visitor pattern)" ([`tiffcomposite_int.hpp`][ex-tiffcomponent]). Node classes
distinguish plain entries (`TiffEntry`), entries that point at data elsewhere
(`TiffDataEntry`, `TiffImageEntry` for strips and tiles, `TiffSizeEntry` for their
lengths), directories, sub-IFDs, maker-note entries (`TiffMnEntry`,
`TiffIfdMakernote`) and binary arrays (`TiffBinaryArray`, `TiffBinaryElement`).

Which node a tag becomes is decided by `TiffCreator::tiffGroupTable_`, keyed by
(tag, group) ([`tiffimage_int.cpp`][ex-grouptable]):

```cpp
    // IFD0
    {{0x8769, IfdId::ifd0Id}, &newTiffSubIfd<IfdId::exifId>},
    {{0x8825, IfdId::ifd0Id}, &newTiffSubIfd<IfdId::gpsId>},
    {{0x0111, IfdId::ifd0Id}, &newTiffImageData<0x0117, IfdId::ifd0Id>},
    {{0x0117, IfdId::ifd0Id}, &newTiffImageSize<0x0111, IfdId::ifd0Id>},
    // ...
    {{0xc634, IfdId::ifd0Id}, &newTiffMnEntry},
    {{Tag::next, IfdId::ifd0Id}, &newTiffDirectory<IfdId::ifd1Id>},
    {{Tag::all, IfdId::ifd0Id}, &newTiffEntry},
```

Operations are visitors over that tree ([`tiffvisitor_int.hpp`][ex-visitor]):
`TiffReader` builds it from bytes, `TiffDecoder` copies it into `ExifData`/`IptcData`/
`XmpData` (decoding embedded XMP at tag `0x02bc` and IPTC on the way),
`TiffEncoder` writes container changes back into it, `TiffCopier` and `TiffFinder`
support rewriting and lookup. A visitor can stop traversal or flag an unknown maker
note through two `GoEvent` flags.

### Maker notes

A maker note is a vendor blob inside Exif tag `0x927c`, usually an IFD with its own
header, sometimes its own byte order, and sometimes offsets relative to the maker
note instead of the TIFF header. `TiffRwState` carries exactly those two degrees of
freedom, with the comment that "some camera vendors encode their makernotes in TIFF
IFDs using offsets relative to (somewhere near) the start of the makernote data"
([`tiffvisitor_int.hpp`][ex-rwstate]). `TiffMnCreator::registry_` selects a parser by
prefix of `Exif.Image.Make` (`"Canon"`, `"NIKON"`, `"OLYMPUS"`, `"SONY"`, …) and a
second set of rows rebuilds a maker note by group when writing
([`makernote_int.cpp`][ex-mnregistry]). Each vendor has an `MnHeader` subclass that
reads its signature and reports `ifdOffset()`, `byteOrder()` and `baseOffset()`.
Vendor sub-records that are packed arrays rather than IFDs are described by
`ArrayCfg`/`ArrayDef` tables, including element type, size element, fillers and an
optional `CryptFct` (Nikon's `nikonCrypt`) ([`tiffimage_int.cpp`][ex-arraycfg]).

### Writing: non-intrusive first

`ExifParser::encode` "is parsed and updated in-place if possible ('non-intrusive'
writing). If that is not possible (e.g., if new tags were added), the entire Exif
structure is re-written" ([`exif.hpp`][ex-exifparser]). For JPEG it then fits the
result into one `APP1` segment of at most 65527 bytes, dropping preview tags over
32 kB, then unknown tags over 4 kB and known tags over 20 kB ([`exif.cpp`][ex-app1cap];
the header comment says 40 kB), and "succeeds even if the end result is still larger
than the allowed size" ([`exif.hpp`][ex-exifparser]). **Verified:**
setting `Exif.Image.Make` from `Abc` to `Xyz` in a 90-byte TIFF changed three bytes
and kept the size; adding a 21-byte `Exif.Image.Artist` rebuilt the file to 60 bytes, dropping
the 64 unreferenced trailing bytes the original carried.

## Analysis

### 1. Pixel and memory model

Not applicable, because Exiv2 never decodes pixels. `Image` records only
`pixelWidth_` and `pixelHeight_`, read from headers such as the JPEG `SOFn` segment
([`jpgimage.cpp`][ex-jpg-icc]).

### 2. Genericity mechanism

Not applicable to pixels. The genericity that exists is over metadata: a polymorphic
`Value` hierarchy with one `ValueType` template for the numeric types, and virtual
dispatch over the `Image` subclasses and the TIFF visitors.

### 3. Colour and metadata

Exiv2 is the clearest example in this catalog of the metadata half of **Q5** done in
full, and of the colour half left out. Exif, IPTC and XMP get typed keys, typed values,
per-tag print functions and a conversion table between standards; the
[ICC profile][c-icc] is an opaque `DataBuf` whose only check is that the length in its
first four bytes equals the buffer size ([`image.cpp`][ex-icccheck]). JPEG `APP2`
chunks are appended in file order, and the chunk and count bytes only decide when the
length check runs ([`jpgimage.cpp`][ex-jpg-icc], [`image.cpp`][ex-icc-append]); nothing
parses tags, primaries or the transfer curve, and there is no [CICP][c-cicp] model.
Orientation, the one tag a viewer must act on, is a convenience lookup that "will
return expected/desired metadata most of the time" ([`easyaccess.hpp`][ex-easy]).
`PreviewManager` extracts the embedded JPEG previews that RAW files carry, which is
how a viewer can show a RAW file without a RAW decoder.

Compared with [ExifTool][exiftool], the split is where tag knowledge lives. ExifTool's
tables are Perl hashes interpreted at run time, with per-tag write rules and
conversion code inline ([`Exif.pm`][et-exif-main], [`Exif.pm`][et-exif-make]); Exiv2
compiles the same kind of knowledge into `constexpr` C++ arrays (`TagInfo`,
`tiffGroupTable_`, `ArrayCfg`) and adds a class per structural role. ExifTool changes
by editing a table; Exiv2 gives a typed API, an
in-process library and static dispatch, at the price of a recompile per new tag and a
much larger C++ surface to secure.

### 4. I/O and codec architecture

The format layer is a closed, ordered registry of probe functions plus virtual
`readMetadata`/`writeMetadata`; there is no plugin interface. All parsing is **pull**
over `BasicIo` or over a fully buffered metadata block (`ExifParser::decode` takes a
pointer and a size and "no checks are performed" on the format
([`exif.hpp`][ex-exifparser])); nothing is suspendable in the sense of
[push and pull decoding][c-pushpull]. The [container and bitstream][c-container]
split is clean in one direction only: Exiv2 parses containers and never decodes a
bitstream.

The TIFF engine is the part with lessons for a declarative binary description
(**Q4**). Its table rows describe what a binary-format DSL would have to express:
byte order chosen at run time from the header, a second byte order and a second base
offset inside a nested record (maker notes), offset/size tag pairs that must be
resolved together (`newTiffImageData<0x0117,…>` with `newTiffImageSize<0x0111,…>`),
packed arrays with optional size elements and encryption, and loops that the reader
must break. The [wired baseline][bl-wired] lists the run-time byte order as gap G5 and
names EXIF among the offset-addressed structures no acceptance set covers (G15); the
nested base offset, the paired tags and cycle detection are not among its listed gaps.

### 5. Hostile input and safety

Exiv2 is a case study in retrofitting [hostile-input][c-hostile] defences onto a
parser written for cooperative files. The tree carries 37 regression tests named
after CVEs in `tests/bugfixes/github/` (for example
[`test_CVE_2017_11336.py`][ex-cve-test], which pins the exact stderr for a 60-byte
proof of concept) among 296 bug-fix test scripts in all
(224 under `github/`, 72 under `redmine/`). The defences now present:

- **Checked buffers.** `DataBuf::read_uint8`, `cmpBytes` and `c_data` throw
  `std::out_of_range` on an out-of-range offset ([`types.cpp`][ex-databuf]);
  `Slice` is a range-checked view ([`slice.hpp`][ex-slice]).
- **`enforce` and `Safe::add`.** `enforce(cond, ErrorCode::kerCorruptedMetadata)`
  throws on a failed precondition ([`enforce.hpp`][ex-enforce]); `Safe::add` and
  friends wrap compiler overflow builtins ([`safe_op.hpp`][ex-safeop]).
- **Structural limits.** `TiffReader` rejects an IFD with more than 256 entries,
  refuses a directory it has already visited, and skips an entry whose count is at
  least `0x10000000` ([`tiffvisitor_int.cpp`][ex-visitdir],
  [`tiffvisitor_int.cpp`][ex-circular], [`tiffvisitor_int.cpp`][ex-readentry]).
  `BmffImage::boxHandler` throws on a revisited box address, too many visits or depth
  past `max_recursion_depth_` ([`bmffimage.cpp`][ex-bmff-visits]).
- **Degrade, do not fail.** Most TIFF violations log and truncate rather than throw,
  so damaged camera files still yield their good tags.

**Verified** with crafted little-endian TIFFs (exit status 0 in every case):

| Input                                      | `exiv2 -pa` result                                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------------------- |
| IFD0's next pointer points back at IFD0    | `Thumbnail pointer references previously read Image directory; ignored.`; `Make` still read |
| IFD0 entry count 300                       | `Directory Image with 300 entries considered invalid; not read.`; no tags                   |
| ASCII entry, count 64, offset `0x7fffffff` | `… is out of bounds: Offset = 0x7fffffff; truncating the entry`; empty `Software`           |
| RATIONAL entry, count `0xffffffff`         | `… has invalid size 4294967295*8; skipping entry.`                                          |

The 256-entry cap is a heuristic ("Sanity check with an 'unreasonably' large number"),
not a format rule, so a legal TIFF with more entries loses its whole IFD silently
except for a log line. Limits are not caller-configurable beyond the recursion depth,
which `ImageFactory` hard-codes; a caller can choose it only by constructing the format
class itself with an `ImageCtorParams` ([`image.hpp`][ex-ctorparams]). See the [hostile-input papers][p-hostile].

### 6. Allocation and ownership

Ownership is `std::unique_ptr` for `Image` and `BasicIo` and `std::shared_ptr` for
TIFF tree children (`TiffComponent::Components`). Metadata lives in node-based
`std::list` containers of heap-allocated `Value` objects, and writes build the whole
output file in a `MemIo` before swapping. That suits a desktop tool editing one file;
it is the opposite of a `@nogc` decoder.

### 7. CPU parallelism and SIMD

There is no internal parallelism. The README's guarantee is per instance: "Different
instances of the same class can safely be used concurrently in multiple threads", with
two exceptions, `XmpParser::initialize` and `XmpProperties::registerNs`, which the
application must serialize before starting threads ([`README.md`][ex-readme-threads]).
There is no SIMD code.

### 8. GPU offload and interop

Not applicable, because Exiv2 has no pixel data to move to a GPU.

### 9. Temporal, animation and containers

The video classes (`QuickTimeVideo`, `AsfVideo`, `RiffVideo`, `MatroskaVideo`) read
container metadata only, with no write support, and only when built with `EXV_ENABLE_VIDEO`
([`image.cpp`][ex-registry]). There is no frame or animation model.

### 10. Testing and conformance

Three layers: GoogleTest unit tests in `unitTests/` (including `test_safe_op.cpp`,
`test_enforce.cpp`, `test_slice.cpp` and XMP concurrency tests), a Python system-test
runner in `tests/` whose cases pin exact stdout and stderr per proof-of-concept file in
`test/data/`, and libFuzzer targets in `fuzz/`. The main target opens, prints every
datum, prints all six structure views and writes back
([`fuzz-read-print-write.cpp`][ex-fuzz-target]); it runs "for a short period of time
on every pull request", with a dictionary generated by a CodeQL query that collects
"string literals that are used in conditions" ([`fuzz/README.md`][ex-fuzz-readme]),
and on OSS-Fuzz, whose crashes count as security issues ([`SECURITY.md`][ex-security-qualify]). Fuzzing the write path, not only the read path,
is the notable choice: round-trip writes are where in-place patching meets corrupt
offsets.

## Lessons for Sparkles

- **Q5.** The minimum metadata model has more than one standard in it: Exif, IPTC and
  XMP each need their own key space and value types, plus a mapping table between them
  (`convert.cpp`). ICC can start as an opaque, length-checked blob, as Exiv2's does,
  provided the colour model elsewhere parses it.
- **Q5.** Human-readable printing needs context beyond the tag
  (`print(const ExifData*)`); a D inspector built on the font-explorer `inspect` template needs the
  same access to sibling tags.
- **Q4.** Exif and maker notes are a stress test for a `sparkles:wired` binary
  description: run-time byte order, nested base offsets, paired offset/size tags,
  packed vendor arrays and cycle detection. Exiv2 handles them with hand-written
  classes plus `constexpr` tables; a D description could make the tables the single
  source and generate the walkers by introspection.
- **Q4, Q6.** Exiv2's pull-over-`BasicIo` design with whole-file rewrite through a
  temporary does not transfer to a completion-based loop. What does transfer is
  `RemoteIo`'s block map: fetch metadata ranges, mark pixel ranges as not needed.
- **Q8.** The CVE-named regression corpus with pinned stderr, and a fuzz target that
  exercises read, print and write, are directly reusable practices; Exiv2's
  `test/data/` proofs of concept can serve as a differential corpus for a D Exif
  reader (license permitting).
- **Q8.** The retrofit history argues for limits and checked reads from the first
  commit. D's bounds-checked slices give the `DataBuf`/`Slice` guarantees for free in
  `@safe` code; `Expected` replaces `enforce`-and-throw in `nothrow @nogc` paths.
- **Q9.** Exiv2 is a metadata library separate from any codec, and it still needs a
  container parser per format. That is evidence that format container parsing is
  shared between a metadata package and a pixel codec package, whichever owns it.

## Strengths

- Typed, iterable containers for Exif, IPTC and XMP with one key syntax.
- Maker-note decoders for 15 camera-make prefixes in its registry, with per-vendor headers, offsets
  and encrypted binary arrays.
- Non-intrusive in-place Exif updates that preserve unknown structures.
- Remote and memory IO behind one `BasicIo` interface.
- A mature security process: OSS-Fuzz, per-PR fuzzing, CVE regression tests, overflow
  helpers.

## Weaknesses

- GPL-2.0-or-later, which rules out vendoring into permissively licensed code.
- A large hand-written C++ parser surface with a long CVE record; defences are
  retrofits and heuristics (the 256-entry cap).
- No caller-configurable limits; `ImageFactory` fixes the recursion depth at 1000.
- Exceptions everywhere, `std::list` of heap `Value` objects, whole-file rewrite
  through memory.
- ICC is a blob; no CICP or colour semantics.
- XMP depends on the Adobe XMP Toolkit, whose initialisation is not thread-safe.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                                    | Trade-off                                                   |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Compiled tag tables (`TagInfo`, `tiffGroupTable_`) | Typed keys and static dispatch ([`tags.hpp`][ex-taginfo])                                    | A new tag needs a recompile                                 |
| Composite tree walked by visitors                  | One parse serves read, decode, encode and copy ([`tiffcomposite_int.hpp`][ex-tiffcomponent]) | A large class surface to secure                             |
| Non-intrusive writing first                        | Preserves unknown structures ([`exif.hpp`][ex-exifparser])                                   | Two write paths; the intrusive one drops data to fit `APP1` |
| Log and truncate on violations                     | Damaged camera files still yield their good tags                                             | Silent data loss, such as the 256-entry cap                 |

## Sources

- Exiv2 source at `be479c1b7c27409582f62eaaac3a738130d869b1`: `include/exiv2/`,
  `src/`, `fuzz/`, `tests/`, `README.md`, `SECURITY.md`.
- ExifTool source at `2200871d9cef988051d2a99d67df3bda6cbb30a8`, `lib/Image/ExifTool/Exif.pm`.
- Probes: `/tmp/exiv2-probe/gen.py` and the crafted TIFFs, run with nixpkgs `exiv2` 0.28.8;
  reproduced independently with `/tmp/exiv2-verify/gen.d` against the same binary.

<!-- References -->

[ex-repo]: https://github.com/Exiv2/exiv2/tree/be479c1b7c27409582f62eaaac3a738130d869b1
[ex-site]: https://exiv2.org/
[ex-readme-welcome]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/README.md#L17-L18
[ex-readme-build]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/README.md#L77
[ex-readme-threads]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/README.md#L649-L668
[ex-readme-license]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/README.md#L839-L847
[ex-security]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/SECURITY.md
[ex-security-qualify]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/SECURITY.md#L26
[ex-image-doc]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/image.hpp#L65-L76
[ex-image-api]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/image.hpp#L117-L130
[ex-registry]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/image.cpp#L80-L121
[ex-factory-open]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/image.cpp#L884-L893
[ex-basicio-mmap]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/basicio.hpp#L175-L191
[ex-basicio-fake]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/basicio.hpp#L220-L228
[ex-jpg-write]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/jpgimage.cpp#L578-L588
[ex-jpg-read]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/jpgimage.cpp#L191-L255
[ex-exifdata]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/exif.hpp#L367-L399
[ex-exifparser]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/exif.hpp#L486-L543
[ex-typeid]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/types.hpp#L68-L94
[ex-valuetype]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/value.hpp#L1280-L1294
[ex-taginfo]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/tags.hpp#L224-L234
[ex-ifdtaginfo]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tags_int.cpp#L471-L475
[ex-print]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/metadatum.hpp#L131-L136
[ex-convert]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/convert.cpp#L297
[ex-tiffcomponent]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffcomposite_int.hpp#L151-L159
[ex-grouptable]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffimage_int.cpp#L1434-L1461
[ex-arraycfg]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffimage_int.cpp#L32-L50
[ex-visitor]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffvisitor_int.hpp#L28-L57
[ex-rwstate]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffvisitor_int.hpp#L527-L570
[ex-mnregistry]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/makernote_int.cpp#L103-L149
[ex-circular]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffvisitor_int.cpp#L1040-L1050
[ex-visitdir]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffvisitor_int.cpp#L1066-L1088
[ex-readentry]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/tiffvisitor_int.cpp#L1256-L1330
[ex-app1cap]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/exif.cpp#L571-L655
[ex-jpg-icc]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/jpgimage.cpp#L239-L278
[ex-icc-append]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/image.cpp#L662-L672
[ex-ctorparams]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/image.hpp#L49
[ex-icccheck]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/image.cpp#L674-L682
[ex-easy]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/easyaccess.hpp#L25-L28
[ex-databuf]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/types.cpp#L120-L195
[ex-slice]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/include/exiv2/slice.hpp
[ex-enforce]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/enforce.hpp#L30-L48
[ex-safeop]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/safe_op.hpp#L15-L40
[ex-bmff-visits]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/src/bmffimage.cpp#L226-L235
[ex-cve-test]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/tests/bugfixes/github/test_CVE_2017_11336.py
[ex-fuzz-target]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/fuzz/fuzz-read-print-write.cpp#L7-L55
[ex-fuzz-readme]: https://github.com/Exiv2/exiv2/blob/be479c1b7c27409582f62eaaac3a738130d869b1/fuzz/README.md#L3-L43
[et-exif-main]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L411-L416
[et-exif-make]: https://github.com/exiftool/exiftool/blob/2200871d9cef988051d2a99d67df3bda6cbb30a8/lib/Image/ExifTool/Exif.pm#L578-L584
[exiftool]: ./exiftool.md
[bl-wired]: ./baseline/wired.md
[c-metadata]: ./concepts.md#image-metadata
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-container]: ./concepts.md#container-and-bitstream
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-hostile]: ./concepts.md#hostile-input
[p-hostile]: ./papers/hostile-input-safety.md
