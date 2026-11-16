# NumPy `ndarray` and the buffer protocol (Python)

The strided N-D array used across Python imaging: a data
pointer, a shape, byte strides and a type descriptor, exchanged through
`__array_interface__` and the Python buffer protocol of PEP 3118.

| Field         | Value                                                                                                     |
| ------------- | --------------------------------------------------------------------------------------------------------- |
| Language      | C (the `ndarray` core) and Python                                                                         |
| License       | BSD 3-Clause ([`LICENSE.txt`][license])                                                                   |
| Repository    | [numpy/numpy][repo]                                                                                       |
| Revision read | `b833c1b9bf6712cc8a03bb301b77c48984a2373d` (`2.6.0.dev0` in [`pyproject.toml`][version])                  |
| Documentation | [The array interface protocol][iface-doc]; [PEP 3118][pep3118]; [CPython buffer protocol][cpython-buffer] |
| Category      | Generic libraries                                                                                         |
| Tier          | B                                                                                                         |
| Last reviewed | November 7, 2026                                                                                          |

> [!NOTE]
> This page reads three things: the `ndarray` memory model (`PyArrayObject_fields`,
> the flags, `base`), the NumPy-specific `__array_interface__`, and NumPy's export
> and import of PEP 3118 buffers (`buffer.c`, `ctors.c`). It does not read ufuncs,
> dtypes beyond their buffer format, or `__dlpack__`, which is DLPack's subject.
> The behaviour demonstrations ran NumPy `2.3.4` on CPython `3.13.12` from nixpkgs,
> not a build of the pinned revision; the source quoted is the pinned revision.

## Overview

### What it solves

NumPy solves one problem that matters to every image library with a Python
binding: describing a block of memory as a homogeneous N-D array without
copying it. An image is `(height, width, channels)` of `uint8` with byte strides
`(row_pitch, bytes_per_pixel, 1)`; a crop, a flipped image, a single channel and
a `CHW` transpose share the allocation with different shapes and strides.
Crops and flips can also shift the pointer to the first logical element.
The [stride concept page][c-stride] describes the idea.

### Design philosophy

The array interface states its own purpose ([`arrays.interface.rst`][iface-intro]):

> The array interface (sometimes called array protocol) was created in 2005 as
> a means for array-like Python objects to reuse each other's data buffers
> intelligently whenever possible. The homogeneous N-dimensional array interface
> is a default mechanism for objects to share N-dimensional array memory and
> information.

PEP 3118 extended Python's existing buffer protocol. Its rationale contrasts
NumPy's constant strides with the Python Imaging Library's arrays of pointers
to image segments ([PEP 3118][pep3118]). The PEP keeps both: strides for NumPy, `suboffsets` for PIL-style
row pointers. NumPy itself exports only the first and refuses to import the
second (see [Hostile input](#_5-hostile-input-and-safety)).

The design philosophy is minimal description plus a lifetime anchor: a consumer
receives a raw pointer and the metadata to index it, and holds a reference to an
owner object that keeps the memory alive. Nothing in the protocol describes
colour, alpha or axis meaning.

## How it works

### The array object

`PyArrayObject_fields` ([`ndarraytypes.h`][fields]) is five layout fields, a
lifetime field and bookkeeping:

```c
// numpy/_core/include/numpy/ndarraytypes.h (abridged; comments shortened)
char *data;                 /* Pointer to the raw data buffer */
int nd;                     /* The number of dimensions, also called 'ndim' */
npy_intp *dimensions;       /* The size in each dimension, also called 'shape' */
npy_intp *strides;          /* Number of bytes to jump to get to the next element */
PyObject *base;             /* For views it points to the original array,
                               collapsed so no chains of views occur. */
PyArray_Descr *descr;       /* Pointer to type structure */
int flags;
void *_buffer_info;         /* private buffer info, tagged to allow warning */
PyObject *mem_handler;      /* For malloc/calloc/realloc/free per object */
```

Strides are signed `npy_intp` **bytes**, so a negative stride flips an axis and a
zero stride broadcasts. `itemsize` lives on `descr`. `NPY_MAXDIMS` is `64`
([`ndarraytypes.h`][maxdims]); the legacy iterators stop at
`NPY_MAXDIMS_LEGACY_ITERS` (`32`).

### Flags

Contiguity and alignment flags cache derived layout facts; ownership and
writability flags record separate state
([`ndarraytypes.h`][flags]): `NPY_ARRAY_C_CONTIGUOUS` (`0x0001`, "last index
varies the fastest"), `NPY_ARRAY_F_CONTIGUOUS` (`0x0002`), `NPY_ARRAY_OWNDATA`
(`0x0004`, ownership of the allocation), `NPY_ARRAY_ALIGNED` (`0x0100`), `NPY_ARRAY_NOTSWAPPED` (`0x0200`, a constructor request),
`NPY_ARRAY_WRITEABLE` (`0x0400`) and `NPY_ARRAY_WRITEBACKIFCOPY` (`0x2000`).
Others (`FORCECAST`, `ENSURECOPY`, `ENSURENOCOPY`) are only requests to the
constructors. Contiguity ignores length-1 axes ([`ndarraytypes.h`][flags]):

> A higher dimensional array always has the same contiguity flags as
> `array.squeeze()`; dimensions with `array.shape[dimension] == 1` are
> effectively ignored when checking for contiguity.

`_UpdateContiguousFlags` ([`flagsobject.c`][contig]) walks the axes from the
last, skipping `dim == 1`, and records any stride that differs from the running
product of `itemsize` and the inner extents before updating `C_CONTIGUOUS`. A zero-length axis
makes the array contiguous both ways.

### Views and `base`

Slicing, transposing and `broadcast_to` create a new header over the same
allocation with `OWNDATA` clear and `base` set (basic slicing; advanced indexing
can copy). `PyArray_SetBaseObject`
([`arrayobject.c`][setbase]) collapses chains:

> Don't allow infinite chains of views, always set the base to the first owner
> of the data. That is, either the first object which isn't an array, or the
> first object which owns its own data.

The `base` is set once ("Cannot set the NumPy array 'base' dependency more than
once"), and the collapse stops at a subclass boundary. The owner can be any
Python object: a `bytes`, a `memoryview`, a capsule wrapping a C allocation.

### `__array_interface__`

A dictionary with three required keys (`shape`, `typestr`, `version`) and
optional `descr`, `data`, `strides`, `mask` and `offset`
([`arrays.interface.rst`][iface-keys]). `typestr` is byte order (`<`, `>`, `|`),
a kind character and a byte count: `|u1` is an 8-bit sample, `<f2` a
little-endian half float. `descr` describes structured items; the document's own
example is a pixel ([`arrays.interface.rst`][iface-rgb]):

```text
* RGB Pixel data
    typestr == '|V3'
    descr == [('r','|u1'), ('g','|u1'), ('b','|u1')]
```

`data` is either a `(pointer_as_int, read_only)` tuple or an object exposing the
buffer protocol; `strides` is `None` for C-contiguous data. NumPy's own getter
returns `None` whenever the array is C-contiguous
(`array_protocol_strides_get`, [`getset.c`][strides-get]). The C-side twin,
`__array_struct__`, a `PyCapsule` around `PyArrayInterface`, is documented as
legacy; new code should use the buffer protocol or `numpy.from_dlpack`
([`arrays.interface.rst`][iface-struct]).

### PEP 3118 export

The current `Py_buffer` layout includes an owner reference, `obj`
([CPython buffer documentation][cpython-buffer]). The historical PEP's sketch
omits it. In ABI field order:

```c
typedef struct {
     void *buf;
     PyObject *obj;
     Py_ssize_t len;
     Py_ssize_t itemsize;
     int readonly;
     int ndim;
     char *format;
     Py_ssize_t *shape;
     Py_ssize_t *strides;
     Py_ssize_t *suboffsets;
     void *internal;
} Py_buffer;
```

The consumer asks with `PyBUF_*` request flags; the exporter fills what it can
or fails. `array_getbuffer` ([`buffer.c`][getbuffer]) refuses with
`"ndarray is not C-contiguous"` when `PyBUF_C_CONTIGUOUS` is requested and not
true, refuses a strideless request on a non-C-contiguous array ("Non-strided
N-dim buffers must be C-contiguous" is the source comment), sets `suboffsets = NULL` always, and
points `shape` and `strides` at a cached `_buffer_info_t`. The file header
explains why the cache exists ([`buffer.c`][buffer-header]): NumPy does not use
`bf_releasebuffer`, and must "Behave correctly when array is reshaped in-place,
or it's dtype is altered", so it tracks the memory for each distinct shape,
strides and format it has handed out. For contiguous arrays it rewrites the
strides so length-1 axes get "well formatted strides"
([`buffer.c`][info-new]), because some consumers expect them.

`_buffer_format_string` ([`buffer.c`][format]) maps each dtype to the `struct`
module grammar PEP 3118 extends: `B` for `uint8`, `e` for half, `f` and `d`,
`Zf` for complex64 and `T{...}` for structured types with `:name:` fields.
Prefixes track byte order and alignment: even native data may need `=`, `@`
or `^` when the active format state changes. Not every dtype is exportable;
overlapping fields and unsupported dtypes are rejected.

### PEP 3118 import

`_array_from_buffer_3118` ([`ctors.c`][from3118]) wraps a `memoryview` as an
array with that `memoryview` as `base`. It refuses `suboffsets`, checks that the
format's item size matches `itemsize` (with a ctypes workaround), checks
`0 <= ndim <= NPY_MAXDIMS`, derives C strides when the exporter gave none, and
clears `WRITEABLE` for a read-only buffer.

### Demonstrated

A scratch script (`/tmp/np-demo/demo.py`) exercised these paths; the output,
trimmed:

```text
shape (480, 640, 4) strides (2560, 4, 1) itemsize 1
C True F False OWNDATA True
crop strides (2560, 4, 1) C False OWNDATA False base is img True
view of view base is img True
red plane strides (2560, 4)
vflip strides (-2560, 4, 1)
CHW view strides (1, 2560, 4) C False
memoryview format B shape (10, 20, 4) strides (2560, 4, 1) suboffsets () c_contig False
cast: TypeError memoryview: casts are restricted to C-contiguous views
iface strides contiguous None
f4 fmt >f e
struct fmt T{B:r:B:g:B:b:} |V3 [('r', '|u1'), ('g', '|u1'), ('b', '|u1')]
65 dims: ValueError maximum supported dimension for an ndarray is currently 64, found 65
broadcast strides (0, 0) writeable False
oversized shape over 16-byte buffer accepted, size 1048576
```

The crop of a crop points its `base` at the original, a vertical flip is a
negative row stride, a broadcast is stride 0 and read-only, and a PEP 3118 view
of a crop keeps the parent's row pitch. The last line is the hostile case below.

## Analysis

### 1. Pixel and memory model

The model is one pointer, N extents and N signed byte strides; a pixel is
whatever `descr` says, either a trailing channel axis (`(H, W, 4)` of `u1`) or a
structured item (`|V4` for four byte channels). A consumer must explicitly
support the spelling it accepts. Byte strides, unlike mir's element strides or Halide's (see
[mir's memory model][mir-1] and [Halide][halide]), express odd row pitches and
packed 24-bit pixels without a separate pitch field; negative strides express
flips. A `CHW` transpose of interleaved storage is still interleaved storage;
true planar storage has a dense plane and a larger channel stride. Semi-planar YUV (a
full-resolution Y plane and a half-resolution interleaved UV plane) is not one
image-shaped array: the planes need separate views with different extents.
Neither protocol assigns plane semantics to a group of views. Tiled storage can
use extra tile axes, but general tiled addressing is not an affine `(H, W)`
view. Row-pointer images are not directly expressible in `ndarray`; PEP 3118 can carry
the latter through `suboffsets`, and NumPy refuses them.

### 2. Genericity mechanism

The genericity at the boundary is run time: `descr` in NumPy and a format
string for buffer consumers that request type information.
There is no compile-time pixel type. The cost is visible in the code: two type
grammars (`typestr` and PEP 3118 `format`) and a translator between them, with a
fast path for single-element formats and a fallback that imports Python code
(`_dtype_from_pep3118`, [`buffer.c`][desc-from-fmt]). For a D library the
lesson is the seam, not the mechanism: whatever the static pixel types are, the
boundary to C and Python needs a run-time description that one function
translates.

### 3. Colour and metadata

No standard colour or axis semantics. `descr` field names (`'r'`, `'g'`, `'b'`) are labels;
channel order, alpha convention, transfer function and axis meaning travel out
of band. Compare [VIGRA's `axistags`][vigra] and the [colour subject][colour],
which provide richer image semantics. Structured fields can carry application
data, but the protocols do not interpret it as colour metadata.

### 4. I/O and codec architecture

Not applicable to the protocols: they share memory descriptions, with no
incremental decoder or I/O scheduling contract. NumPy file I/O is outside this
page's scope.

### 5. Hostile input and safety

The protocol is a trust boundary with very little checking. `PyArray_FromInterface`
([`ctors.c`][from-iface]) accepts a raw integer pointer, checks `len(shape)`
against `NPY_MAXDIMS` and converts each entry to `npy_intp`, takes a buffer
object's pointer and then calls `PyBuffer_Release` with the comment "It is up
to the object that supplies the buffer to guarantee that the buffer sticks
around after the release", adds `offset`, and copies `strides` in. It never
compares `shape`, `strides` and `offset` with the buffer's `len`. The
demonstration above built a `(1 << 20,)` array over a 16-byte `bytearray`
without an error; indices 16 and above would read outside the allocation.
The demonstration does not read those indices. The PEP 3118 path is stricter
on structure (item size, `ndim`, `suboffsets`) but also trusts the exporter's
`shape` and `strides`, as does mir's `fromPythonBuffer` ([mir § 8][mir-8]). The
import side of a Sparkles binding needs an allocation extent from a trusted
owner before it can validate addresses. `Py_buffer.len` is the logical packed
size, not the physical allocation span for a strided view; it cannot serve as
a general capacity bound ([CPython documentation][cpython-buffer]). Raw
pointer interfaces provide no capacity at all.

### 6. Allocation and ownership

Ownership is a reference to `base` plus `OWNDATA`; the `base` collapse keeps
chains flat. Allocation is pluggable per array since `mem_handler`:
`PyDataMem_Handler` holds a `PyDataMemAllocator` with `malloc`, `calloc`,
`realloc` and a `free` that receives the size ([`ndarraytypes.h`][allocator]).
NumPy permits in-place metadata changes and caches distinct exported
`_buffer_info_t` records on the array ([cache][buffer-cache]), freeing the list
with the array ([destruction][buffer-free]). A D binding
holding `Py_buffer` must call `PyBuffer_Release`; NumPy's import of
`__array_interface__` data releases at once and relies on the owner.

### 7. CPU parallelism and SIMD

Not applicable to the protocols: they specify neither kernel scheduling nor
SIMD dispatch. NumPy's numerical kernels are outside this page's scope.

### 8. GPU offload and interop

Both protocols describe host memory only: no device field, no stream. The
interface documentation points new C-side exchange code to [DLPack][dlpack].
For host memory, adapters can share compatible buffers: [ITK's NumPy bridge][itk]
has view APIs but copies non-C-contiguous input. [OpenCV][opencv] and [GIL][gil]
also use byte strides, but sharing that convention does not guarantee that a
consumer accepts arbitrary strides, formats or PEP 3118 objects without copying.
Device memory needs a device-aware protocol such as DLPack, whose strides are
in elements, not bytes ([`dlpack.h`][dlpack-strides]).

### 9. Temporal, animation and containers

Not applicable as a temporal protocol: a time axis can be an ordinary array
dimension, but frame timing, disposal and multi-plane grouping have no standard
fields ([array interface keys][iface-keys], [buffer fields][cpython-buffer]).

### 10. Testing and conformance

The demonstrations above check layout, ownership and rejection behavior on
NumPy 2.3.4, not conformance of the pinned development revision. Pinned NumPy
tests cover buffer formats, strides and contiguity requests
([`test_multiarray.py`][buffer-tests]); this verification did not run that suite.

## Lessons for Sparkles

- **Q1** A strided `(pointer, extents, strides)` header is a common
  interop model. NumPy, PEP 3118 and [OpenCV][opencv] use byte strides;
  [DLPack][dlpack] needs element strides. `ImageData` today carries `rgba` and a `Size` without a stride, and
  `ColourRegion` carries a byte `stride` per row ([baseline][bl-existing]); a
  view type exportable through PEP 3118 needs per-axis signed byte strides.
- **Q1** Contiguity as a derived, cached property (ignoring length-1 axes)
  rather than a type parameter is NumPy's choice; mir encodes it in the type
  (`Contiguous`, `Canonical`, `Universal`). A D design can do both: static kind
  for kernels, a run-time check at the export boundary.
- **Q1** Neither protocol assigns meaning to a group of planes. A container
  of views is a design option for semi-planar and multi-plane video frames.
- **Q2** Run-time element descriptions (`typestr`, PEP 3118 `format`) are
  unavoidable at the C and Python boundary. A single translator from a static D
  pixel type to a format string (`B`, `e`, `T{B:r:B:g:B:b:}`) is the transferable
  piece; the two-grammar duplication is not.
- **Q5** No colour, alpha or axis semantics travel with the array. If Sparkles
  exports images, the colour model needs a side channel, and imported arrays
  arrive with unknown alpha convention.
- **Q8** Validate the minimum and maximum reachable byte offsets, including
  item size, negative strides, empty extents and arithmetic overflow, against
  a trusted allocation span ([CPython's example][cpython-buffer]). Logical
  `len` alone is insufficient. The oversized array-interface demonstration is
  a test case for a binding's differential or fuzz harness.
- **Q8** Export semantics are testable with Python through CPython's
  `memoryview` rules, for example the refusal to `cast` a non-C-contiguous view.
- **Q9** A language-neutral strided header could sit in the image core; this
  is a design inference from the layout model. Format translation and Python
  ownership handling belong to a binding with a CPython dependency.

## Strengths

- One layout model for direct strided buffers in Python.
- Byte strides express crops, flips, broadcasts, channel selection and
  transposes as views without copying.
- `base` collapsing shortens ownership chains within its type constraints;
  contiguity is derived from shape, strides and item size.
- PEP 3118 is part of CPython, so the protocol needs no NumPy dependency.

## Weaknesses

- Array-interface import does not check metadata against the supplied buffer
  capacity; strided buffer imports rely on the exporter for valid addresses.
- No device, no stream, no colour, alpha or axis semantics.
- Two type grammars and a cache of exported metadata exist to work around the
  protocol's own constraints (`bf_releasebuffer` avoided, mutable shape).
- NumPy refuses `suboffsets`, so row-pointer images do not directly
  round-trip; neither protocol standardizes multi-plane image grouping.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                               | Trade-off                                                             |
| ------------------------------------------------------ | ------------------------------------------------------- | --------------------------------------------------------------------- |
| Signed byte strides ([layout][fields])                 | Describe affine views without copying                   | General tiled addressing and row pointers need another representation |
| An owner reference ([`base`][setbase])                 | Keep shared storage alive                               | External owners must preserve pointer validity                        |
| Cached export metadata ([design notes][buffer-header]) | Support mutable array metadata and historical consumers | Cache storage remains until array destruction                         |
| Runtime type formats ([translator][format])            | Describe elements across language boundaries            | Consumers need format support; some dtypes cannot be exported         |

## Sources

- [`numpy/_core/include/numpy/ndarraytypes.h` — `PyArrayObject_fields`][fields]
- [`numpy/_core/include/numpy/ndarraytypes.h` — array flags][flags]
- [`numpy/_core/include/numpy/ndarraytypes.h` — `NPY_MAXDIMS`][maxdims]
- [`numpy/_core/include/numpy/ndarraytypes.h` — `PyDataMem_Handler`][allocator]
- [`numpy/_core/src/multiarray/flagsobject.c` — `_UpdateContiguousFlags`][contig]
- [`numpy/_core/src/multiarray/arrayobject.c` — `PyArray_SetBaseObject`][setbase]
- [`numpy/_core/src/multiarray/buffer.c` — design notes][buffer-header]
- [`numpy/_core/src/multiarray/buffer.c` — `_buffer_format_string`][format]
- [`numpy/_core/src/multiarray/buffer.c` — `_buffer_info_new`][info-new]
- [`numpy/_core/src/multiarray/buffer.c` — `array_getbuffer`][getbuffer]
- [`numpy/_core/src/multiarray/buffer.c` — `_descriptor_from_pep3118_format`][desc-from-fmt]
- [`numpy/_core/src/multiarray/ctors.c` — `_array_from_buffer_3118`][from3118]
- [`numpy/_core/src/multiarray/ctors.c` — `PyArray_FromInterface`][from-iface]
- [`numpy/_core/src/multiarray/getset.c` — `array_protocol_strides_get`][strides-get]
- [`doc/source/reference/arrays.interface.rst` — the array interface][iface-intro]
- [PEP 3118 — Revising the buffer protocol][pep3118]
- [CPython documentation — Buffer Protocol][cpython-buffer]

<!-- References -->

[repo]: https://github.com/numpy/numpy
[version]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/pyproject.toml#L8-L10
[license]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/LICENSE.txt
[iface-doc]: https://numpy.org/doc/stable/reference/arrays.interface.html
[pep3118]: https://peps.python.org/pep-3118/
[cpython-buffer]: https://docs.python.org/3/c-api/buffer.html
[fields]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/include/numpy/ndarraytypes.h#L787-L836
[flags]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/include/numpy/ndarraytypes.h#L910-L1021
[maxdims]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/include/numpy/ndarraytypes.h#L35-L43
[allocator]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/include/numpy/ndarraytypes.h#L756-L773
[contig]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/flagsobject.c#L116-L160
[setbase]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/arrayobject.c#L156-L226
[buffer-header]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/buffer.c#L26-L44
[buffer-cache]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/buffer.c#L645-L748
[buffer-free]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/arrayobject.c#L391-L396
[format]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/buffer.c#L191-L460
[info-new]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/buffer.c#L463-L545
[getbuffer]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/buffer.c#L755-L848
[desc-from-fmt]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/buffer.c#L917-L995
[from3118]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/ctors.c#L1227-L1360
[from-iface]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/ctors.c#L2130-L2437
[strides-get]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/getset.c#L231-L237
[iface-intro]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/doc/source/reference/arrays.interface.rst#L23-L35
[iface-keys]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/doc/source/reference/arrays.interface.rst#L50-L195
[iface-struct]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/doc/source/reference/arrays.interface.rst#L197-L261
[iface-rgb]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/doc/source/reference/arrays.interface.rst#L282-L284
[buffer-tests]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/tests/test_multiarray.py#L9477-L10020
[dlpack-strides]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L275-L290
[dlpack]: ./dlpack.md
[c-stride]: ./concepts.md#stride
[mir-1]: ./mir-algorithm/index.md#_1-pixel-and-memory-model
[mir-8]: ./mir-algorithm/index.md#_8-gpu-offload-and-interop
[halide]: ./halide.md
[vigra]: ./vigra.md
[colour]: ./color.md
[itk]: ./itk.md
[opencv]: ./opencv.md
[bl-existing]: ./baseline/existing-code.md
[gil]: ./boost-gil.md
