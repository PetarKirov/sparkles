# DLPack (C ABI)

The common in-memory tensor ABI of the Python array ecosystem: one header, `dlpack.h`, that describes a dense strided N-dimensional buffer on one device and a deleter-based borrowing protocol, with no code behind it.

| Field         | Value                                                                                                                                        |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (one header, C and C++ compatible); Python protocol specified in prose                                                                     |
| License       | Apache-2.0 ([`LICENSE`][license])                                                                                                            |
| Repository    | [github.com/dmlc/dlpack][repo]                                                                                                               |
| Revision read | `94485e23519bc30e22a18397a9c8ff1ea6b2b81e` (August 12, 2026, "Add kDLAscend for Huawei Ascend NPU device memory (#189)"); header version 1.3 |
| Documentation | [dmlc.github.io/dlpack/latest][docs]; [`python_spec.rst`][py-spec]; the [Python array API standard][array-api]                               |
| Category      | Generic libraries (interchange ABI)                                                                                                          |
| Tier          | B                                                                                                                                            |
| Last reviewed | November 7, 2026                                                                                                                             |

## Overview

### What it solves

Every array library has its own tensor object. DLPack fixes one C struct that any of them can fill in and any other can read, so that a buffer crosses a library boundary as a view instead of a copy. The README states the scope narrowly ([`README.md`][readme]):

> _"DLPack is an open in-memory tensor structure for sharing tensors among frameworks."_
> _"We do not intend to implement Tensor and Ops, but instead use this as common bridge to reuse tensor and ops across frameworks."_

NumPy, CuPy, PyTorch, TensorFlow/XLA, MXNet, TVM, mpi4py, Paddle and Hidet are listed as implementers ([`python_spec.rst`][py-impls]). For Sparkles the question is narrower: what an image type would have to produce to be handed to that ecosystem, and what a D binding has to get right.

### Design philosophy

- **A descriptor, not a container.** `DLTensor` is documented as a _"Plain C Tensor object, does not manage memory"_ ([`dlpack.h`][h-tensor]). Ownership lives in a separate wrapper with a deleter.
- **Borrowing, not transfer.** `DLManagedTensorVersioned` _"is intended to facilitate the borrowing of DLTensor by another framework. It is not meant to transfer the tensor. When the borrowing framework doesn't need the tensor, it should call the deleter to notify the host that the resource is no longer needed"_ ([`dlpack.h`][h-mtv]).
- **Zero-copy when possible.** _"If possible, this must be zero-copy (i.e. `y` will be a view on `x`). If not possible, that library may flag this and make a copy of the data"_ ([`python_spec.rst`][py-semantics]).
- **ABI stability by versioning the wrapper.** A major-version change _"indicates that we have changed the data layout of the ABI"_, and on a mismatch _"the consumer must call the deleter (and it is safe to do so). It is not safe to access any other fields"_ ([`dlpack.h`][h-version]).

## How it works

### The descriptor: `DLTensor`

```c
typedef struct {
  void* data;            // device pointer or opaque handle
  DLDevice device;       // { DLDeviceType device_type; int32_t device_id; }
  int32_t ndim;
  DLDataType dtype;      // { uint8_t code; uint8_t bits; uint16_t lanes; }
  int64_t* shape;        // ndim extents
  int64_t* strides;      // ndim strides, in elements
  uint64_t byte_offset;  // from data to element (0, ..., 0)
} DLTensor;
```

(Abridged from [`dlpack.h`][h-tensor], comments shortened.) The rules sit in the field comments:

- `strides` are _"in number of elements, not bytes"_ and _"can not be NULL if ndim != 0"_; the note adds that _"Before DLPack v1.2, strides can be NULL to indicate contiguous data. This is not allowed in DLPack v1.2 and later"_ ([`dlpack.h`][h-strides]). Strides are signed, so a flipped axis is legal.
- `data` _"is always aligned to 256 bytes as in CUDA"_ and `byte_offset` points to the first element, but the same comment concedes that CuPy, PyTorch, TensorFlow and TVM _"do not adhere to this 256 byte alignment requirement"_ and _"it is recommended to not rely on the data pointer being correctly aligned"_ ([`dlpack.h`][h-data]). The comment also gives the size formula `GetDataSize` (product of `shape` times `(bits * lanes + 7) / 8`) and says a zero-size tensor's `data` _"should be set to NULL"_.
- There is no per-axis origin and no capacity: a crop is a new `data` or `byte_offset` plus new `shape`, and nothing records the parent extent.

### Devices

`DLDeviceType` lists `kDLCPU = 1`, `kDLCUDA = 2`, `kDLCUDAHost = 3`, `kDLOpenCL = 4`, `kDLVulkan = 7`, `kDLMetal = 8`, `kDLVPI`, `kDLROCM`, `kDLROCMHost`, `kDLExtDev`, `kDLCUDAManaged`, `kDLOneAPI`, `kDLWebGPU`, `kDLHexagon`, `kDLMAIA`, `kDLTrn`, `kDLTPU`, `kDLTPUHost` and, newest, `kDLAscend = 21` ([`dlpack.h`][h-device]); values 5 and 6 are unassigned. `DLDevice.device_id` is 0 for host, pinned and managed memory. The meaning of `data` is given only for three back ends: _"CUDA device pointer, `cl_mem` handle in OpenCL, or `id<MTLBuffer>` for Metal. It may be opaque on some device types"_ (backticks added) ([`dlpack.h`][h-data]). `kDLVulkan` is described as _"Vulkan buffer for next generation graphics"_ and nothing says whether `data` is a `VkBuffer`, a `VkDeviceMemory` or a device address. The Python spec also warns that `device_id` numbering is the producer's and _"that is not guaranteed"_ to match the consumer's ([`python_spec.rst`][py-devid]).

### Element types: code, bits, lanes

`DLDataType` packs `code` (a `DLDataTypeCode` kept as `uint8_t` _"for minimal memory footprint"_), `bits` and `lanes` into four bytes ([`dlpack.h`][h-dtype]). The codes are `kDLInt`, `kDLUInt`, `kDLFloat`, `kDLOpaqueHandle`, `kDLBfloat`, `kDLComplex`, `kDLBool`, eight FP8 variants, two FP6, one FP4 and `kDLBcomplex` ([`dlpack.h`][h-codes]). The header's examples include `float4(vectorized 4 float): type_code = 2, bits = 32, lanes = 4` and `bool: type_code = 6, bits = 8, lanes = 1`. Sub-byte types are packed by default, little bit-endian: _"for a packed data set D ((D >> (i * bits)) && bit_mask) stores the i-th element"_. Byte order is native only: _"An explicit error message should be raised when attempting to export an array with non-native endianness"_.

`lanes` lets an RGBA8 pixel be one element (`kDLUInt`, 8 bits, 4 lanes), but NumPy's `from_dlpack` rejects `lanes != 1` with `BufferError` ([`dlpack.c`][np-dlpack-lanes]); a channel axis (`shape = [H, W, 4]`) is the portable form.

### Ownership: two managed wrappers

```c
typedef struct DLManagedTensorVersioned {
  DLPackVersion version;   // { uint32_t major, minor; }
  void *manager_ctx;       // producer's owner object, may be NULL
  void (*deleter)(struct DLManagedTensorVersioned *self);
  uint64_t flags;          // READ_ONLY | IS_COPIED | IS_SUBBYTE_TYPE_PADDED
  DLTensor dl_tensor;
} DLManagedTensorVersioned;
```

(Abridged from [`dlpack.h`][h-mtv].) The legacy `DLManagedTensor` is `dl_tensor`, `manager_ctx`, `deleter`, with no version or flags, and is _"deprecated after DLPack v0.8"_ ([`dlpack.h`][h-mt]). In the versioned struct the version and deleter come first and the `flags` comment says _"Future ABI changes should keep everything until this field stable, to ensure that deleter can be correctly called"_: the prefix up to `flags` is the permanent ABI, so a consumer that rejects a major version can still free the tensor.

The three flag bits ([`dlpack.h`][h-flags]):

| Macro                                        | Bit | Meaning                                                                                             |
| -------------------------------------------- | --- | --------------------------------------------------------------------------------------------------- |
| `DLPACK_FLAG_BITMASK_READ_ONLY`              | 0   | the consumer must not write                                                                         |
| `DLPACK_FLAG_BITMASK_IS_COPIED`              | 1   | _"the tensor is considered solely owned throughout its lifetime by the consumer"_ until the deleter |
| `DLPACK_FLAG_BITMASK_IS_SUBBYTE_TYPE_PADDED` | 2   | a sub-byte type is stored one element per byte, not packed                                          |

The deleter _"deletes the argument self as well"_, so the managed struct, the `shape` and `strides` arrays and the owner reference are released together; NumPy allocates the struct, `shape` and `strides` in one `PyMem_Malloc` block ([`dlpack.c`][np-dlpack-alloc]) and its deleter frees `self` and decrements the array's reference count, after acquiring the GIL and leaking instead if Python is already finalised ([`python_spec.rst`][py-deleter], [`dlpack.c`][np-dlpack-deleter]).

### The Python exchange: `__dlpack__` and `__dlpack_device__`

`from_dlpack(x, *, device=..., copy=...)` queries `x.__dlpack_device__()` (a `(device_type, device_id)` tuple) when it needs the device to select a stream and calls `x.__dlpack__(stream=..., max_version=..., dl_device=..., copy=...)` ([`python_spec.rst`][py-syntax], [`python_spec.rst`][py-semantics], [`dlpack.c`][np-dlpack-args]). The result is a `PyCapsule` named `"dltensor"`, or `"dltensor_versioned"` when the consumer's `max_version` allows the versioned struct ([`python_spec.rst`][py-versioned]). Ownership moves by renaming ([`python_spec.rst`][py-capsule]):

> _"The consumer must transer ownership of the `DLManagedTensor` from the capsule to its own object. It does so by renaming the capsule to `"used_dltensor"` to ensure that `PyCapsule_Destructor` will not get called"_

The capsule destructor therefore checks the name and calls the deleter only if the capsule was never consumed. Streams apply to CUDA and ROCm: _"The consumer must pass the stream it will use to the producer; the producer must synchronize or wait on the stream when necessary"_ ([`python_spec.rst`][py-semantics]). Version 1.3 adds `__dlpack_c_exchange_api__`, a `PyCapsule` named `"dlpack_exchange_api"` on the type, holding a `DLPackExchangeAPI` table of five function pointers (`managed_tensor_allocator`, `managed_tensor_from_py_object_no_sync`, `managed_tensor_to_py_object_no_sync`, `dltensor_from_py_object_no_sync`, `current_work_stream`) behind a `DLPackExchangeAPIHeader` with a version and a `prev_api` chain ([`dlpack.h`][h-xapi]). `DLPackDLTensorFromPyObjectNoSync` fills a stack `DLTensor` whose liveness _"is only guaranteed until control is returned"_ ([`dlpack.h`][h-nosync]), a non-owning fast path beside the owning one.

### Demonstrated: NumPy 2.3.4 as producer and consumer

A scratch script (`np_probe.py`, run with NumPy 2.3.4 from nixpkgs) printed:

```text
device (1, 0)
view shares memory: True
uint8 HWC with 16-byte pitch -> (16, 3, 1)
float32 pitch 22: BufferError DLPack only supports strides which are a multiple of itemsize.
read-only, max_version None -> BufferError Cannot export readonly array since signalling readonly is unsupported by DLPack (supported by newer DLPack version).
read-only, max_version (1, 0) -> <capsule object "dltensor_versioned" at 0x...>
from_dlpack(read-only).writeable = False
negative stride view -> (15, -3, 1)
copy=True ok, shares: False
big-endian int32: BufferError DLPack only supports native byte order.
```

The capsule address is elided. Padded rows survive as a `uint8` channel axis; a `float32` image whose row pitch is not a multiple of four bytes cannot be exported at all; read-only export needs the versioned struct; negative strides pass through.

### Demonstrated: a D binding against ImportC

A scratch probe (`probe.d`, built with DMD 2.112.1 and LDC 1.43.0 in the repository's dev shell) imported the pinned `dlpack.h` through ImportC beside a hand-written `extern (C)` mirror and printed:

```text
DLDevice                   D   8 / C   8 ok
DLDataType                 D   4 / C   4 ok
DLTensor                   D  48 / C  48 ok
DLManagedTensorVersioned   D  80 / C  80 ok
DLManagedTensor (C only)   D  64 / C  64 ok
offsetof flags 24 / 24, dl_tensor 32 / 32
DLDeviceType.sizeof (C enum) 4, kDLVulkan = 7, kDLBool = 6
READ_ONLY 1, IS_COPIED 2, SUBBYTE_PADDED 4
GetDataSize shape [2^32, 2^32] u8 -> 0
GetDataSize shape [-1, 3] u8 -> 18446744073709551613
GetDataSize shape [3] fp4 packed -> 3 bytes
RGB8 pitch 16 as u8x3 (lanes=3, 3 bytes/elem): row stride 5 elements, remainder 1
RGB8 pitch 16 as HWC u8: strides [16, 3, 1], exact
data pointer 256-aligned: no
logical GetDataSize 60 vs addressed span 63 bytes
deleter calls: 1
```

Two binding facts came out of it. The field `DLManagedTensorVersioned.version` is a D keyword: ImportC keeps the name, so D code reaches it only through `__traits(getMember, m, "version")`, and a hand binding must rename it (`version_` above). And the GC-allocated D buffer in this run was not 256-byte aligned, which the header requires and the field admits nobody honours.

## Analysis

### 1. Pixel and memory model

DLPack's model is one dense strided box on one device: `ndim` extents, `ndim` signed element strides and a byte offset, which is the [stride][concepts-stride] model of NumPy and mir's `Slice` in its `Universal` kind ([mir-algorithm, GPU offload and interop][mir-8]). It has no [planes][concepts-plane]: an NV12 or YUV 4:2:0 frame is two or three tensors with no link between them, and [chroma subsampling][concepts-chroma] is not expressible. It has no tiling and no axis names, so `[H, W, C]` against `[C, H, W]` is a convention the two sides must share. Against Halide's `halide_buffer_t` it lacks the per-axis `min` and the host/device dual allocation ([Halide, pixel and memory model][halide-1]).

Element strides cost images one thing: the row pitch must be a whole number of elements. The D probe above found that a 5-pixel RGB8 row padded to 16 bytes is exact as `shape [4, 5, 3]`, `strides [16, 3, 1]` with `uint8` elements, but as a 3-lane element the row stride would be `16 / 3 = 5` with remainder 1, which DLPack cannot state; NumPy refuses the analogous `float32` case (above). An image type that wants to export must choose element types such that its pitch alignment is a multiple of the element size, or export with a byte-sized element and a channel axis.

### 2. Genericity mechanism

Genericity across the boundary is a run-time value descriptor: `DLDataType` (`code`, `bits`, `lanes`) and `DLDevice` (`device_type`, `device_id`) in `DLTensor` ([`dlpack.h`][h-dtype], [`dlpack.h`][h-device]), paired with C function pointers (`deleter` and the `DLPackExchangeAPI` table, [`dlpack.h`][h-mtv], [`dlpack.h`][h-xapi]). There are no compile-time type parameters; a statically typed D view must map between `T` and `(code, bits, lanes)` at the import/export seam.

### 3. Colour and metadata

Nothing. `DLDataType` says `kDLUInt` 8 bits, never sRGB against linear, never [straight against premultiplied alpha][concepts-alpha], never a CICP tuple or an ICC profile. An exported image is numbers; colour must travel out of band or be normalised (for example to linear `float32`) before export.

### 4. I/O and codec architecture

Not applicable, because DLPack is an in-memory tensor descriptor and exchange protocol with no file format, stream I/O or codec interface ([`README.md`][readme]).

### 5. Hostile input and safety

The consumer receives raw pointers and must trust them. The header gives no limit on `ndim`, no rule that `shape` entries are non-negative, and its own size formula has no overflow check. The D probe transcribed `GetDataSize` and fed it hostile shapes: `[2^32, 2^32]` of `uint8` gives `0`, and `[-1, 3]` gives `18446744073709551613`. For packed sub-byte types the formula rounds per element, so three packed FP4 values report 3 bytes where 2 hold them. For strided views it reports the logical size, not the addressed span: the padded RGB8 image gives `60` while the last addressed byte is at offset 62. A Sparkles importer would need its own checked span computation (minimum and maximum offset over the signed strides, with overflow detection) before forming a D slice over `data`.

The protocol is also internally inconsistent at this revision. The header forbids `NULL` strides since 1.2, but [`python_spec.rst`][py-nullstrides] still says _"When the `strides` field in the `DLTensor` struct is `NULL`, it indicates a row-major compact array"_, and the repository's own examples predate the rule: `contrib/dlpack/dlpackcpp.h` leaves `strides` `nullptr` and allocates `sz` bytes for `sz` `float32` elements ([`dlpackcpp.h`][cpp]), `apps/numpy_dlpack/dlpack/to_numpy.py` handles `NULL` strides as compact ([`to_numpy.py`][to-numpy]), and `dlpack.py` maps `bool` to `kDLUInt` with 1 bit where the header says `kDLBool` with 8 ([`dlpack.py`][dlpack-py]). The `DLPackExchangeAPI` doc example assigns `header.prev_version_api`, a field the struct calls `prev_api` ([`dlpack.h`][h-xapi-doc]). A consumer should accept `NULL` strides from older producers, as the repository's own `to_numpy.py` example does.

### 6. Allocation and ownership

The deleter protocol is the transferable part. The producer allocates the managed struct and its `shape`/`strides` arrays (NumPy uses one block for all three, [`dlpack.c`][np-dlpack-alloc]), stores its owner in `manager_ctx`, and the consumer calls `deleter` exactly once. `IS_COPIED` distinguishes a view (producer still owns the pixels) from a copy (consumer owns them until the deleter). `READ_ONLY` makes `const` explicit across the boundary. There is no reference count in the ABI: sharing one export between two consumers is the producer's job (a refcounted `manager_ctx`), and the deleter may run on any thread, which is why NumPy's acquires the GIL. In Sparkles terms a [`UniqueBuffer`][buffer-spec] moved into a heap owner could be the `manager_ctx`, and a `SharedBuffer` would supply the refcount for repeated exports; a GC-owned buffer would additionally need to be registered as a GC root while only C memory references it.

### 7. CPU parallelism and SIMD

Not applicable, because DLPack defines no operators, threading model or SIMD execution ([`README.md`][readme]); `DLDataType.lanes` only tags vectorised element types in the descriptor ([`dlpack.h`][h-dtype]).

### 8. GPU offload and interop

DLPack describes device memory but does not move it. `kDLVulkan` exists with undefined `data` semantics; stream synchronisation is defined for CUDA and ROCm only, and `current_work_stream` returns a `void*` stream that has no Vulkan meaning (a timeline semaphore would be the analogue). A buffer is the only resource: there is no `VkImage`, no optimal tiling, no DRM format modifier, so the [external memory][concepts-extmem] path Sparkles would need for a decoded frame (dma-buf or `VK_EXT_external_memory_host`, both unbound per [the Vulkan baseline][bl-vk-gaps], G3 and G6) sits outside DLPack. In practice a Sparkles export is `kDLCPU` (or `kDLCUDAHost` for pinned memory, which Sparkles does not allocate), and a GPU-side exchange would go through Vulkan external memory, not DLPack.

### 9. Temporal, animation and containers

Not applicable, because DLPack describes a single tensor buffer with no frame timing, sequence metadata or multi-plane container structure ([`dlpack.h`][h-tensor]).

### 10. Testing and conformance

The repository has no tests in the conformance sense. CI builds the C and C++ mocks and runs one binary ([`main.yaml`][ci]); `contrib/mock_c.c` and `contrib/mock_main.cc` exist _"to make sure the package is C compatible"_ ([`mock_c.c`][mock-c]) and to test one flag bit ([`mock_main.cc`][mock]). [`apps/numpy_dlpack/test.py`][test-py] round-trips through TVM 10,000 times (and [`test_pure_numpy.py`][test-pure-np] through ctypes) but neither is run by CI. `NEWS.md` stops at v0.8 ([`NEWS.md`][news]), so the 1.x changes are recorded only in header notes. Conformance in practice is the array API standard's test suite and each framework's own tests, not read here.

## Lessons for Sparkles

- **Q1** An image view that keeps per-axis element strides, signed, plus a base offset, exports to DLPack without translation; one that keeps byte pitch exports only when the pitch is a multiple of the element size. The export rule "a channel axis of `ubyte`/`ushort`/`float` scalars, `[H, W, C]`" covers interleaved images; planar and semi-planar layouts export as one tensor per plane, with the relationship lost.
- **Q1** DLPack has no origin per axis and no parent extent, so a crop in the parent's coordinate system (Halide's `min`) does not survive export; that is a property the Sparkles view would hold above the interchange layer, not in it.
- **Q2** The binding is `extern (C)` data plus a `@system` deleter; a typed `@safe` view over an imported tensor needs a dtype-to-D-type map checked at runtime (`code`, `bits`, `lanes` against `T`), which is the introspection seam, not a template parameter of the ABI.
- **Q5** Nothing about colour crosses. An export API must either refuse non-linear or premultiplied data, document that it exports raw codes, or carry metadata beside the tensor; DLPack gives no slot.
- **Q4/Q8** The importer is a hostile-input surface: `ndim`, `shape`, `strides` and `byte_offset` come from another library. A checked span computation with overflow detection, an `ndim` cap, and acceptance of pre-1.2 `NULL` strides are the minimum; the header's `GetDataSize` is not a safe reference.
- **Q6** For file-to-GPU work DLPack is not the seam: `kDLVulkan` is unspecified, buffers only, CUDA/ROCm streams only. Vulkan external memory and timeline semaphores remain the GPU interop question; DLPack is the CPU-side handoff to Python and ML tooling.
- **Q9** DLPack support is a thin optional module (a binding plus `toDLPack`/`fromDLPack` over the view type), with no dependency on codecs or algorithms; it argues for the view type living in an image-core that such a module can depend on alone. A Python-facing `__dlpack__` would further need a CPython extension layer, which Sparkles does not have.

## Strengths

- One small header, Apache-2.0, C and C++ compatible, adopted by every major Python array library.
- Element strides, signed, per axis: views, transposes and flips are free.
- The versioned struct puts the deleter before every field that may change, so even an incompatible tensor can be freed.
- `READ_ONLY` and `IS_COPIED` make mutability and ownership explicit; NumPy enforces the first.
- A non-owning fast path (`DLPackDLTensorFromPyObjectNoSync`) beside the owning one.

## Weaknesses

- No planes, tiles, axis names, colour, alpha convention or per-axis origin; images lose all metadata.
- Row pitch must be a multiple of the element size; some padded images are unrepresentable with wide elements.
- The documented size formula overflows silently, mishandles packed sub-byte types and ignores strides.
- Spec text, examples and header disagree on `NULL` strides; the 256-byte alignment rule is documented as widely broken.
- `kDLVulkan` has no defined `data` meaning and streams are CUDA/ROCm only, so GPU interop beyond CUDA is underspecified.
- No conformance tests in the repository; `NEWS.md` stops at v0.8.

## Key design decisions and trade-offs

| Decision                                                                             | Rationale                                                                   | Trade-off                                                                                             |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Signed element strides, non-`NULL` for `ndim != 0` ([`dlpack.h`][h-strides])         | Express views, flips and transposes without consumer compact-array branches | Row byte pitch must be a multiple of the element size; pre-1.2 producers still emit `NULL`            |
| Compact `(code, bits, lanes)` descriptor ([`dlpack.h`][h-dtype])                     | Fit scalar, vector and sub-byte types in four bytes                         | No colour space, alpha convention or non-native endianness; consumers like NumPy require `lanes == 1` |
| Versioned wrapper with stable prefix before `flags` ([`dlpack.h`][h-mtv])            | Let a consumer call `deleter` safely even when `version.major` mismatches   | Breaks ABI compatibility with legacy `DLManagedTensor`, requiring dual capsule support                |
| Single-shot deleter borrowing ([`dlpack.h`][h-mtv], [`python_spec.rst`][py-capsule]) | Avoid a cross-language reference-counting ABI                               | Producer must allocate per export; Python deleter must handle GIL acquisition and finalisation        |

## Sources

- [`include/dlpack/dlpack.h`][h-all] at `94485e23519bc30e22a18397a9c8ff1ea6b2b81e`: every struct, enum, flag and the exchange API.
- [`docs/source/python_spec.rst`][py-spec]: the Python `__dlpack__` / `__dlpack_device__` protocol, capsule naming and deleter rules.
- [`README.md`][readme], [`NEWS.md`][news], [`LICENSE`][license].
- [`contrib/dlpack/dlpackcpp.h`][cpp], [`contrib/mock_c.c`][mock-c], [`contrib/mock_main.cc`][mock], [`.github/workflows/main.yaml`][ci].
- [`apps/numpy_dlpack/dlpack/dlpack.py`][dlpack-py], [`to_numpy.py`][to-numpy], [`test.py`][test-py], [`test_pure_numpy.py`][test-pure-np].
- NumPy's DLPack implementation [`numpy/_core/src/multiarray/dlpack.c`][np-dlpack-alloc] at `b833c1b9bf6712cc8a03bb301b77c48984a2373d`.
- The [Python array API standard][array-api] (data interchange section), not read beyond what `python_spec.rst` quotes.
- Scratch demonstrations, not committed: `np_probe.py` (NumPy 2.3.4) and `probe.d` (DMD 2.112.1, LDC 1.43.0).
- Sibling deep-dives: [Halide][halide-1], [mir-algorithm][mir-8], [concepts][concepts-stride], [existing code baseline][bl-existing-gaps], [Vulkan baseline][bl-vk-gaps].

<!-- References -->

[repo]: https://github.com/dmlc/dlpack
[docs]: https://dmlc.github.io/dlpack/latest
[array-api]: https://data-apis.org/array-api/latest/index.html
[license]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/LICENSE
[readme]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/README.md#L7-L15
[news]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/NEWS.md#L1-L9
[h-all]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h
[h-version]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L42-L66
[h-device]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L68-L142
[h-codes]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L144-L192
[h-dtype]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L194-L227
[h-tensor]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L229-L290
[h-data]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L233-L262
[h-strides]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L275-L287
[h-mt]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L292-L320
[h-flags]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L322-L341
[h-mtv]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L343-L387
[h-nosync]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L443-L470
[h-xapi-doc]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L571-L590
[h-xapi]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L521-L654
[py-spec]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst
[py-syntax]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L11-L22
[py-semantics]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L25-L56
[py-versioned]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L73-L85
[py-capsule]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L87-L127
[py-deleter]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L129-L159
[py-nullstrides]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L161-L163
[py-devid]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L168-L179
[py-impls]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/docs/source/python_spec.rst#L220-L238
[cpp]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/contrib/dlpack/dlpackcpp.h#L21-L62
[mock-c]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/contrib/mock_c.c#L1-L7
[mock]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/contrib/mock_main.cc#L1-L16
[ci]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/.github/workflows/main.yaml#L38-L41
[dlpack-py]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/apps/numpy_dlpack/dlpack/dlpack.py#L85-L100
[to-numpy]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/apps/numpy_dlpack/dlpack/to_numpy.py#L11-L38
[test-py]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/apps/numpy_dlpack/test.py#L1-L36
[test-pure-np]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/apps/numpy_dlpack/test_pure_numpy.py#L1-L38
[np-dlpack-deleter]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/dlpack.c#L95-L116
[np-dlpack-alloc]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/dlpack.c#L431-L484
[np-dlpack-args]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/dlpack.c#L557-L563
[np-dlpack-lanes]: https://github.com/numpy/numpy/blob/b833c1b9bf6712cc8a03bb301b77c48984a2373d/numpy/_core/src/multiarray/dlpack.c#L818-L823
[halide-1]: ./halide.md#_1-pixel-and-memory-model
[mir-8]: ./mir-algorithm/index.md#_8-gpu-offload-and-interop
[concepts-stride]: ./concepts.md#stride
[concepts-plane]: ./concepts.md#plane
[concepts-chroma]: ./concepts.md#chroma-subsampling
[concepts-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[concepts-extmem]: ./concepts.md#external-memory-and-zero-copy-import
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-vk-gaps]: ./baseline/vulkan.md#gaps-and-tensions
[buffer-spec]: ../../specs/base/buffer.md
