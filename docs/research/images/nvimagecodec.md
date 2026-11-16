# nvImageCodec (C++, CUDA)

NVIDIA's open-source dispatch layer over its closed GPU codec libraries (`nvJPEG`, `nvJPEG2000`, `nvTIFF`) and CPU fallbacks (`libjpeg-turbo`, `libtiff`, OpenCV): a C API of opaque handles and versioned descriptor structs, a priority-ordered plugin registry with per-sample fallback, batched asynchronous decode into CUDA device buffers, and Python bindings that exchange images through DLPack and `__cuda_array_interface__`.

| Field         | Value                                                                                                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 and CUDA behind a C header, [`include/nvimgcodec.h`][hdr] (2,124 lines); Python bindings in pybind11 ([`python/`][py-dir])                                                  |
| License       | Apache-2.0 ([`LICENSE.txt`][license]); the `nvJPEG`, `nvJPEG2000`, `nvTIFF` and `nvCOMP` libraries it loads at run time are separate NVIDIA binaries ([`README.md`][readme-deps]) |
| Repository    | [NVIDIA/nvImageCodec][repo]                                                                                                                                                       |
| Revision read | `e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f` (merge of `release_v0.9`, July 14, 2026; [`VERSION.txt`][version] `0.9.0`)                                                             |
| Documentation | [docs.nvidia.com/cuda/nvimagecodec][docs] · the header's Doxygen comments · [`example/`][example-dir] (C++ transcoders and Python notebooks)                                      |
| Category      | GPU and SIMD: GPU-accelerated codec framework with CPU fallback                                                                                                                   |
| Tier          | B                                                                                                                                                                                 |
| Last reviewed | November 7, 2026                                                                                                                                                                  |

> [!NOTE]
> The clone is blobless with no checkout; every file was read with `git show` at the pinned
> revision. The host has no NVIDIA GPU, so no decode was run. One claim is **demonstrated**: a
> C++ probe compiled with GCC 14.3.0 against the pinned [`nvimgcodec.h`][hdr] and
> [`safe_arithmetic.h`][safe-arith] (with a two-line stub for `cuda_runtime_api.h`), in
> `/tmp/nvimgcodec-probe`. The codec kernels themselves live in the closed `nvJPEG`,
> `nvJPEG2000` and `nvTIFF` libraries; this page describes what the open layer does around them.
> No performance number appears here.

---

## Overview

### What it solves

Each NVIDIA codec library has its own handle types, its own stream parser and its own output
descriptor. A data-loading pipeline (training, medical slides, transcoding) wants one call that
takes a heterogeneous batch of files and returns device images, using the hardware JPEG engine
where the GPU has one, CUDA kernels where it does not, and a CPU library when neither accepts a
particular file. The README states the shape in its first lines ([`README.md`][readme-intro]):

> _"The nvImageCodec is an open-source library of accelerated codecs with unified interface.
> It is designed as a framework for extension modules which delivers codec plugins."_

and lists among its features _"Batch processing, with variable shape and heterogeneous formats
images"_ and _"Codec prioritization with automatic fallback"_ ([`README.md`][readme-features]).

### Design philosophy

Three choices recur. First, everything is a **C ABI of descriptor structs**: each public struct
opens with `struct_type`, `struct_size` and `struct_next`, the Vulkan idiom for versioned,
chainable parameters ([`nvimgcodec.h`][hdr-props]). Second, the **library is mostly a scheduler**:
format detection, decoder selection, fallback, thread and stream management, and the batching
heuristics are open; the bit-level decoding is delegated. Third, **decoders negotiate**: before
decoding, each decoder answers `canDecode` with a bitmask that says either "no" or "yes, if you
ask for a different format", and the scheduler walks a priority chain on that answer. The header
documents the chain ([`nvimgcodec.h`][hdr-priority]):

> _"Decoding process starts with selecting highest priority decoder and checks whether it can
> decode particular code stream. In case decoding could not be handled by selected decoder, there
> is fallback mechanism which selects next in priority decoder."_

---

## How it works

### The object model: instance, code stream, image, decoder, future

An `nvimgcodecInstance_t` owns the plugin registry. An `nvimgcodecCodeStream_t` wraps encoded
bytes (`nvimgcodecCodeStreamCreateFromFile`, `...FromHostMem`); creating it asks the codec
registry for a parser that accepts the bytes and keeps the match
([`code_stream.cpp`][cs-parser]). An `nvimgcodecImage_t` wraps a caller-provided output buffer
described by `nvimgcodecImageInfo_t`. An `nvimgcodecDecoder_t` is created with
`nvimgcodecExecutionParams_t` (device, allocators, executor, allowed backends) and decodes a batch
with `nvimgcodecDecoderDecode(decoder, streams, images, batch_size, params, &future)`
([`nvimgcodec.h`][hdr-decode]). The future reports one `nvimgcodecProcessingStatus_t` per sample,
and its readiness means host work only ([`nvimgcodec.h`][hdr-future]):

> _"Please note that when future is ready, it only means that all host work was done and it can be
> that some work was scheduled to be executed on device (depending on codec). To further
> synchronize work on device, there is cuda_stream field available in nvimgcodecImageInfo_t which
> can be used to specify cuda_stream to synchronize with."_

Sub-images and regions are selected by deriving a child code stream with
`nvimgcodecCodeStreamGetSubCodeStream` and an `nvimgcodecCodeStreamView_t` (`image_idx`, a
`region`, or a TIFF IFD `bitstream_offset`) ([`nvimgcodec.h`][hdr-view]).

### The image descriptor

`nvimgcodecImageInfo_t` is a flat struct: `color_spec`, `chroma_subsampling`, `sample_format`,
`orientation`, `num_planes`, an inline array of `NVIMGCODEC_MAX_NUM_PLANES` (32) plane
descriptors, one `void* buffer`, a `buffer_kind` (`STRIDED_DEVICE` or `STRIDED_HOST`) and the
`cuda_stream` to synchronize with ([`nvimgcodec.h`][hdr-imageinfo]). Each plane carries `width`,
`height`, `row_stride` in bytes, `num_channels`, `sample_type` and `precision`
([`nvimgcodec.h`][hdr-plane]). Planes of a planar image sit back to back in the one buffer, each
with its own stride ([`safe_arithmetic.h`][safe-offsets]). `nvimgcodecSampleFormat_t` names the
layout and component order together (`I_RGB`, `P_RGB`, `I_BGR`, `P_YUV`, `I_CMYK`, plus
`*_UNCHANGED`) ([`nvimgcodec.h`][hdr-sampleformat]). The sample type encodes its size in its value:
bits 8 to 15 hold the bit depth, so `NVIMGCODEC_SAMPLE_DATA_TYPE_UINT8` is `0x0802` and the
decoder computes bytes per sample as `sample_type >> 11` ([`nvimgcodec.h`][hdr-sampletype],
[`cuda_decoder.cpp`][cuda-roi]).

```text
$ ./probe                                   # demonstrated, /tmp/nvimgcodec-probe
sizeof(nvimgcodecImageInfo_t) = 2160 bytes (32 plane slots inline)
sizeof(nvimgcodecImagePlaneInfo_t) = 56 bytes
UINT8 >> 11 = 1, UINT16 >> 11 = 2, FLOAT32 >> 11 = 4
```

### The extension interface

An extension is a shared library exporting one symbol, `nvimgcodecExtensionModuleEntry`, which
fills an `nvimgcodecExtensionDesc_t` (`id`, `version`, `ext_api_version`, `create`, `destroy`)
([`nvimgcodec.h`][hdr-ext]). The framework scans `NVIMGCODEC_EXTENSIONS_PATH` (or an
`extensions/` directory next to the loaded library) ([`plugin_framework.cpp`][pf-path]),
`dlopen`s each module and looks the symbol up ([`plugin_framework.cpp`][pf-load]). It refuses an
extension whose `ext_api_version` is newer than the framework, and between two copies of the same
`id` keeps the newer `version` ([`plugin_framework.cpp`][pf-version]). `create` receives an
`nvimgcodecFrameworkDesc_t` with `registerDecoder`, `registerEncoder` and `registerParser`,
each taking a priority. A decoder is an `nvimgcodecDecoderDesc_t` of function pointers, of
which `decodeBatch` and `getMiniBatchSize` are the optional batched path
([`nvimgcodec.h`][hdr-decoderdesc]). Parsers for JPEG, JPEG 2000, TIFF, BMP, PNG, PNM and WebP
are a built-in extension ([`builtin_modules.cpp`][builtin]).

The JPEG extension shows the ladder. It loads `libnvjpeg.so.<major>` at run time
([`dynlink_nvjpeg.cpp`][dynlink]), checks its version, then registers the hardware decoder at
`NVIMGCODEC_PRIORITY_VERY_HIGH` (only when the platform has the engine) and the CUDA and lossless
decoders at `HIGH` ([`nvjpeg_ext.cpp`][nvjpeg-ext]); `libjpeg-turbo` registers at `NORMAL`
([`libjpeg_turbo_ext.cpp`][ljt-ext]) and OpenCV at `LOW` ([`opencv_ext.cpp`][opencv-ext]).

### Negotiation: the processing-status bitmask

`nvimgcodecProcessingStatus` packs two answers into one word. Bit 0 set with bit 1 clear means
"supported": `SUCCESS` is `0x1`, and `COLOR_SPEC_UNSUPPORTED` (`0x5`), `ROI_UNSUPPORTED`
(`0x11`) or `SAMPLE_FORMAT_UNSUPPORTED` (`0x81`) mean the decoder could process the stream with
different parameters. Bits 0 and 1 both set mean failure: `FAIL` (`0x3`), `IMAGE_CORRUPTED`
(`0x7`), `CODEC_UNSUPPORTED` (`0xb`). `SATURATED` (`0x2`, bit 1 alone) is documented as "could
potentially process image but is saturated", with a pointer to `load_hint`
([`nvimgcodec.h`][hdr-status]); no file under `src/`, `extensions/` or `python/` returns it at
this revision.
`nvimgcodecDecoderCanDecode` exposes the choice: with `force_format` 0 it stops at the highest
priority decoder and returns which parameter to change, with 1 it falls through to a lower
priority decoder that accepts the format as asked ([`nvimgcodec.h`][hdr-candecode]).

```text
$ ./probe                                   # demonstrated, continued
SUCCESS                    0x0001  bit0=1 bit1=0
FAIL                       0x0003  bit0=1 bit1=1
IMAGE_CORRUPTED            0x0007  bit0=1 bit1=1
COLOR_SPEC_UNSUPPORTED     0x0005  bit0=1 bit1=0
SAMPLE_FORMAT_UNSUPPORTED  0x0081  bit0=1 bit1=0
```

### The scheduler: `ImageGenericCodec`

Decoder and encoder share one CRTP template, `ImageGenericCodec<Impl, Factory, Processor>`
([`image_generic_codec.h`][igc-class]). For each call to `process` it waits for the previous
batch, sorts the samples, sizes each batched processor's share, then runs a setup phase in which
every worker thread probes `canDecode` down the fallback chain for the samples it claims
([`image_generic_codec.h`][igc-setup]). Samples whose chosen decoder has no batched API are then
pulled from an atomic index by the executor's threads and decoded one at a time; if a decoder
fails at decode time, `processSample` re-probes and retries the next one in the chain
([`image_generic_codec.h`][igc-process]). Samples routed to a batched decoder are collected and
handed to its `decodeBatch` on the main thread; a sample the batched decoder fails is rescheduled
on the executor with the next non-batched decoder ([`image_generic_codec.h`][igc-batch]).

A batched backend's share is a `load_hint` fraction of the batch, rounded to the nearest sample
and then up to a multiple of the decoder's preferred mini-batch. Under
`NVIMGCODEC_LOAD_HINT_POLICY_ADAPTIVE_MINIMIZE_IDLE_TIME` the header promises that the hint "is
recalculated on every iteration to reduce the idle time of threads"
([`nvimgcodec.h`][hdr-backend]). The code compares the previous call's main-thread time with its
overall time and moves the hint by a decaying step when one exceeds the other by more than 2 ms
([`image_generic_codec.h`][igc-adjust]). As read at this revision the mechanism is inert: both
timestamps (`last_activity_main_thread_` and `last_activity_`) are assigned only on two consecutive
lines at the end of `process` on the main thread ([`image_generic_codec.h`][igc-timestamps]), so
the two durations never differ by 2 ms and the step is zero; and the share derived from the hint
(`assigned_batch_size_`) is computed only while it is still 0, then kept. This was read, not run.

### Streams and buffers

Executor threads map round-robin onto internal non-blocking CUDA streams, one per thread by
default; `NVIMGCODEC_DEFAULT_NUM_CUDA_STREAMS` or the `num_cuda_streams` option makes several
threads share one ([`image_generic_codec.h`][igc-streams]). Before a sample is decoded the
internal stream waits on an event recorded on the caller's `cuda_stream` (unless
`skip_pre_sync`); afterwards the caller's stream waits on the internal stream, once per stream per
batch ([`image_generic_codec.h`][igc-presync], [`image_generic_codec.h`][igc-sync]):

> _"Multiple worker threads can share one CUDA stream to reduce overhead and improve throughput"_

The CUDA JPEG decoder splits each image into the three `nvJPEG` phases,
`nvjpegDecodeJpegHost` (Huffman on the CPU, or, for baseline JPEGs above a pixel-count threshold
of `1000u * 1000u`, the GPU-hybrid backend), `nvjpegDecodeJpegTransferToDevice` and
`nvjpegDecodeJpegDevice` ([`cuda_decoder.cpp`][cuda-roi]), and double-buffers the pinned staging
memory per thread ([`cuda_decoder.cpp`][cuda-phases]):

> _"Some of them are double-buffered, so that we can simultaneously decode the host part of the
> next sample, while the GPU part of the previous is still consuming the data from the previous
> iteration pinned buffer."_

Device and pinned memory go through caller-replaceable `nvimgcodecDeviceAllocator_t` and
`nvimgcodecPinnedAllocator_t`, each a stream-ordered `malloc`/`free` pair with a padding size
([`nvimgcodec.h`][hdr-alloc]).

### Python bindings and DLPack

`nvidia.nvimgcodec.Image` exposes `__dlpack__`, `__dlpack_device__`, `__cuda_array_interface__`,
`__array_interface__`, `cpu()` and `cuda()` ([`image.cpp`][py-image-api]). Export follows the
[DLPack](./dlpack.md) protocol: each `__dlpack__` call makes a fresh `DLManagedTensor` whose
`manager_ctx` holds a shared reference to the tensor state that owns the image buffer, and when the
consumer passes a stream other than `-1` (and different from the image's), the consumer stream is
made to wait on an event recorded on the image's stream ([`dlpack_utils.cpp`][py-dlpack-sync]).
Import accepts a DLPack capsule, `__cuda_array_interface__` (version 2 or later, honouring its
`stream` from version 3), `__array_interface__` (host memory), or `__dlpack__`, the last only for
CUDA-accessible devices ([`image.cpp`][py-image-import]).

---

## Analysis

### 1. Pixel and memory model

The model is a 2-D image of up to 32 [planes][c-plane], each pitch-linear with its own
[stride][c-stride], packed in one buffer, tagged with a buffer kind (host or device). Layout
(interleaved or planar) and component order share one enum. There is no N-D extent beyond the
`NVIMGCODEC_MAX_NUM_DIM` (5) used for regions, no view type, and no block-linear or tiled GPU
layout: the output is always a CUDA linear allocation, in contrast to a sampled Vulkan image
([vulkan-transfer.md](./vulkan-transfer.md)). The 2,160-byte fixed descriptor (demonstrated)
trades size for an allocation-free C ABI.

### 2. Genericity mechanism

Runtime polymorphism through C function-pointer tables, priorities and a capability bitmask; C++
CRTP only inside the scheduler. Pixel types are runtime values (`sample_type`, `sample_format`),
not template parameters. The `struct_type`/`struct_size`/`struct_next` header lets a descriptor
grow without breaking the ABI, the same mechanism Vulkan uses.

### 3. Colour and metadata

`nvimgcodecColorSpec_t` is a small enum (`SRGB`, `GRAY`, `SYCC`, `CMYK`, `YCCK`, `PALETTE`,
`ICC_PROFILE`) with no [CICP][c-cicp] or HDR fields ([`nvimgcodec.h`][hdr-colorspec]).
Orientation is a decoded struct (rotation, flips) that the decoder can apply
(`apply_exif_orientation`). `nvimgcodecDecoderGetMetadata` returns typed records whose kinds lean
towards TIFF and whole-slide imaging (`TIFF_TAG`, `GEO`, `MED_APERIO`, `MED_PHILIPS`, ...); EXIF
is marked "reserved for future use" ([`nvimgcodec.h`][hdr-metadata]), and XMP appears only as the
format of Ventana slide records read from TIFF tag 700 ([`metadata_extractor.cpp`][tiff-xmp]).
The [ICC profile][c-icc] is surfaced from TIFF tag 34675 by the `nvTIFF` extension
([`metadata_extractor.cpp`][tiff-icc]); the JPEG 2000 parser declines restricted ICC: _"We don't
parse ICC profiles, so just mark as unsupported"_ ([`jpeg2k.cpp`][j2k-icc]). No colour management
happens. See [icc.md](./icc.md) and [cicp.md](./cicp.md) for what the minimum model would add.

### 4. I/O and codec architecture

The [container and bitstream][c-container] are both parsed by the format's parser, header only;
the decoder then pulls whole encoded images through `nvimgcodecIoStreamDesc_t`, which offers
`read`, `seek` and `map` ([`nvimgcodec.h`][hdr-iostream]). Files opened for reading are
memory-mapped on Linux ([`code_stream.cpp`][cs-mmap], [`file_io_stream.cpp`][fileio]). Decoding is
batch-asynchronous but not incremental: there is no partial-input or suspend path, so a
truncated file is an error, not a "need more data" state, unlike [Wuffs](./wuffs.md). Region
decoding goes through the code-stream view, and JPEG 2000 decodes [tiles][c-tiling] in parallel
(`num_parallel_tiles`, default 16) ([`nvjpeg2k/cuda_decoder.cpp`][j2k-tiles]).

### 5. Hostile input and safety

The open parsers are hand-written C++ over the I/O stream, and newer code uses checked arithmetic
for sizes derived from headers ([`safe_arithmetic.h`][safe-arith]):

> _"Use whenever attacker-controlled metadata (image dimensions, channel counts, tile geometry,
> ...) is multiplied to produce a buffer size or element count: an unchecked product can wrap and
> produce an undersized allocation that subsequent decode writes overrun."_

The probe confirms that `SafePlaneByteSize` rejects a 2^40-byte stride times 2^30 rows. There
are no dimension or memory limits in the API, no fuzzing harness in the tree (no path matches
`fuzz`), and the decoders themselves are closed binaries whose robustness cannot be inspected.
Corrupt-input fixtures exist (`resources/tiff/error/`, `resources/pnm/corrupted/int_overflow.pnm`).
Compare [hostile input][c-hostile] and the [hostile-input papers](./papers/hostile-input-safety.md).

### 6. Allocation and ownership

The caller owns output buffers; the library owns staging (pinned) and scratch (device) memory,
through replaceable stream-ordered allocators whose allocations are padded to a multiple of a
caller-set size ([`nvimgcodec.h`][hdr-alloc]). The Python `Image` is reference-counted, and
each DLPack export holds a shared reference so the buffer outlives the capsule.

### 7. CPU parallelism and SIMD

CPU parallelism is a pluggable executor (`schedule`, `run`, `wait`, `getNumThreads`) with a
default thread pool ([`nvimgcodec.h`][hdr-executor]). SIMD belongs to the CPU fallbacks
([libjpeg-turbo.md](./libjpeg-turbo.md), [opencv.md](./opencv.md)), not to this layer.

### 8. GPU offload and interop

This is the subject's centre. Three GPU forms coexist behind one interface: a fixed-function
engine (`NVIMGCODEC_BACKEND_KIND_HW_GPU_ONLY`), CUDA kernels with CPU entropy decoding
(`HYBRID_CPU_GPU`), and pure GPU (`GPU_ONLY`) ([`nvimgcodec.h`][hdr-backend]); callers can
restrict the set per decoder. The hardware decoder picks between the legacy batched
`nvjpegDecodeBatchedEx` and a per-image pipeline over leased workers depending on batch size,
engine count and chroma-subsampling mix ([`hw_decoder.cpp`][hw-dispatch],
[`hw_decoder.cpp`][hw-choose]). Interop is CUDA-only: CUDA streams, CUDA pointers, DLPack
`kDLCUDA`. There is no Vulkan, external-memory or graphics API path; see
[external memory][c-extmem] and [GPU decompression][c-gpudecomp].

### 9. Temporal, animation and containers

Not applicable, because the library decodes still images only: there is no frame, timing or
video type. Multi-image containers reduce to an image count and an index.
`nvimgcodecCodeStreamInfo_t` reports `num_images` ([`nvimgcodec.h`][hdr-csinfo]), which the TIFF
parser sets to the number of root IFDs and the PNG and WebP parsers set to 1
([`tiff.cpp`][tiff-numimages], [`png.cpp`][png-numimages]); a view's `image_idx` or
`bitstream_offset` selects one. The WebP parser defines an animation bit for the extended header
but never reads it ([`webp.cpp`][webp-anim]).

### 10. Testing and conformance

GoogleTest suites cover the API, parsers, plugin framework and scheduler with mocks
(`test/mock_*.h`), including a decoder with only a batched API
([`decode_batch_only_fallback_test.cpp`][test-batchonly]); pytest suites under `test/python/`
cover the bindings. Golden references are `.ppm` decodes (one `.pfm`) under
[`resources/ref/`][res-ref], including a nine-file EXIF orientation set for JPEG; PNG, TIFF and
WebP have nine-file orientation input sets (`resources/<format>/exif_orientation/`). No
conformance corpus is used.

---

## Lessons for Sparkles

- **Q6** The three-phase split of a JPEG decode (host entropy decode, transfer, device
  reconstruction) with double-buffered pinned staging per thread maps onto Vulkan as CPU Huffman
  into a staging buffer, a transfer command, and a compute dispatch for IDCT and colour
  conversion. The decomposition transfers; the closed `nvJPEG` kernels do not, so Sparkles would
  write the device phase itself as a shader ([baseline](./baseline/vulkan.md),
  [GPU decode papers](./papers/gpu-decode-streaming.md)).
- **Q6** The future-means-host-done contract, with device completion carried by a stream the
  caller waits on, is the CUDA analogue of returning a timeline-semaphore value; Sparkles has no
  timeline semaphores today ([baseline](./baseline/vulkan.md)).
- **Q4** Per-sample negotiation through a status bitmask that separates "cannot" from "can,
  with other parameters" is a cheap, ABI-stable way to chain a GPU decoder ahead of a CPU one; a D
  design could express the same as an `Expected` over a capability set rather than raw bits.
- **Q4**, **Q9** A registry of prioritised decoders with per-sample fallback argues for a
  formats package where a GPU decoder is one more registrant, not a separate API. The `dlopen`
  plugin discovery solves NVIDIA's packaging problem (optional closed libraries) and is less
  relevant to a D monorepo that links statically.
- **Q7** The `load_hint` policy states a cheap answer to "where is the break-even" when it varies
  per machine: split each batch between the GPU and CPU decoders and move the split by measured
  idle time instead of a cost model. The implementation at this revision does not deliver it (both
  timestamps are taken together on the main thread, and the derived share is fixed after its first
  non-zero value), so the idea is evidence of intent, not of a working balancer; a Sparkles version
  would time the GPU path by its completion, not by when submission returns.
- **Q1** One flat descriptor with inline planes and a host/device buffer kind keeps the C ABI
  allocation-free, but it fixes the image to 2-D linear memory; a Vulkan target also needs
  optimal-tiling images and per-plane `VkImage` views, which this model cannot name.
- **Q5** The colour model (an enum plus ICC only from TIFF) is too thin for Sparkles' viewer and
  is evidence that a decode-for-training library can omit [CICP][c-cicp] and gain maps; it is not
  a model to copy.
- **Q8** Golden `.ppm` references and orientation fixture sets are reusable oracle patterns; the
  lack of fuzzing and of limits is the gap to avoid.
- **Q6** DLPack export with a consumer-stream event wait ([dlpack.md](./dlpack.md)) shows how a
  device image crosses a library boundary with ordering preserved; a Vulkan equivalent would carry
  a semaphore, not a stream.

## Strengths

- One C API covers hardware, CUDA, and CPU decoders, with automatic per-sample fallback across
  heterogeneous batches.
- Versioned, chainable descriptor structs keep the ABI extensible.
- The capability bitmask tells callers which parameter to change instead of failing.
- Stream-ordered allocators, caller streams and asynchronous futures fit into an existing CUDA
  pipeline without hidden synchronization.
- The `nvJPEG` integration overlaps host and device work through double-buffered pinned memory.
- DLPack and `__cuda_array_interface__` in both directions give zero-copy exchange with PyTorch,
  CuPy and CV-CUDA.

## Weaknesses

- The codecs that matter are closed binaries; the open code is a scheduler and parser set.
- CUDA-only interop: no Vulkan, no external-memory export, no GPU texture output.
- No incremental or suspendable decoding, and no resource limits in the API.
- No fuzzing harness in the tree; hostile-input defence relies on hand-written parsers and the
  closed libraries.
- A thin colour model: no CICP, no HDR, EXIF metadata reserved but not implemented, JPEG 2000 ICC
  ignored.
- Still a `0.9.0` beta ([`README.md`][readme-badge]) with a large, intricate scheduler
  (`image_generic_codec.h` is 1,222 lines of threads, barriers and events) whose adaptive
  load-balancing path is inert as read.

## Sources

- [`include/nvimgcodec.h`][hdr] — the public C API and extension API.
- [`src/image_generic_codec.h`][igc-class] — scheduler, fallback, stream sync, adaptive batching.
- [`src/plugin_framework.cpp`][pf-load] — extension discovery and versioning.
- [`extensions/nvjpeg/`][nvjpeg-ext] — `nvJPEG` hardware, CUDA and lossless decoders.
- [`src/imgproc/safe_arithmetic.h`][safe-arith] — overflow-checked size arithmetic.
- [`python/dlpack_utils.cpp`][py-dlpack-sync], [`python/image.cpp`][py-image-api] — bindings.
- [nvImageCodec documentation][docs].
- Related pages: [DLPack](./dlpack.md), [Vulkan transfer](./vulkan-transfer.md),
  [libjpeg-turbo](./libjpeg-turbo.md), [libtiff](./libtiff.md), [OpenCV](./opencv.md),
  [Wuffs](./wuffs.md), [concepts](./concepts.md).

<!-- References -->

[repo]: https://github.com/NVIDIA/nvImageCodec
[docs]: https://docs.nvidia.com/cuda/nvimagecodec/
[license]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/LICENSE.txt
[version]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/VERSION.txt
[readme-intro]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/README.md#L17-L18
[readme-features]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/README.md#L22-L27
[readme-deps]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/README.md#L136-L175
[example-dir]: https://github.com/NVIDIA/nvImageCodec/tree/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/example
[py-dir]: https://github.com/NVIDIA/nvImageCodec/tree/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/python
[hdr]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h
[hdr-props]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L226-L235
[hdr-alloc]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L238-L316
[hdr-sampletype]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L348-L373
[hdr-sampleformat]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L393-L431
[hdr-colorspec]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L433-L451
[hdr-plane]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L469-L485
[hdr-imageinfo]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L547-L583
[hdr-view]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L585-L600
[hdr-backend]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L700-L756
[hdr-status]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L758-L794
[hdr-metadata]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L906-L985
[hdr-executor]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L1066-L1138
[hdr-iostream]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L1140-L1263
[hdr-decoderdesc]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L1461-L1568
[hdr-priority]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L1570-L1588
[hdr-ext]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L1675-L1722
[hdr-future]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L1808-L1819
[hdr-candecode]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L2022-L2040
[hdr-decode]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L2042-L2058
[cs-parser]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/code_stream.cpp#L169-L195
[cs-mmap]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/code_stream.cpp#L184-L188
[fileio]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/file_io_stream.cpp#L27-L46
[builtin]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/builtin_modules.cpp
[pf-load]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/plugin_framework.cpp#L347-L405
[pf-version]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/plugin_framework.cpp#L204-L234
[igc-sync]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L205-L212
[igc-class]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L283-L285
[igc-setup]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L730-L811
[igc-process]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L950-L997
[igc-batch]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L1070-L1145
[igc-adjust]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L1160-L1218
[safe-arith]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/imgproc/safe_arithmetic.h#L28-L52
[safe-offsets]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/imgproc/safe_arithmetic.h#L78-L96
[dynlink]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/dynlink/dynlink_nvjpeg.cpp#L35-L36
[nvjpeg-ext]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvjpeg/nvjpeg_ext.cpp#L60-L100
[ljt-ext]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/libjpeg_turbo/libjpeg_turbo_ext.cpp#L32
[opencv-ext]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/opencv/opencv_ext.cpp#L50-L54
[cuda-phases]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvjpeg/cuda_decoder.cpp#L131-L150
[cuda-roi]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvjpeg/cuda_decoder.cpp#L716-L787
[hw-dispatch]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvjpeg/hw_decoder.cpp#L66-L75
[j2k-tiles]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvjpeg2k/cuda_decoder.cpp#L331-L348
[j2k-icc]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/parsers/jpeg2k.cpp#L333-L334
[tiff-icc]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvtiff/metadata_extractor.cpp#L310-L318
[py-image-import]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/python/image.cpp#L270-L326
[py-image-api]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/python/image.cpp#L956-L1082
[py-dlpack-sync]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/python/dlpack_utils.cpp#L480-L572
[test-batchonly]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/test/api/decode_batch_only_fallback_test.cpp
[res-ref]: https://github.com/NVIDIA/nvImageCodec/tree/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/resources/ref
[readme-badge]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/README.md#L3
[pf-path]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/plugin_framework.cpp#L120-L124
[igc-streams]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L415-L480
[igc-presync]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L640-L703
[igc-timestamps]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/image_generic_codec.h#L1065-L1066
[hw-choose]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvjpeg/hw_decoder.cpp#L1012-L1052
[hdr-csinfo]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/include/nvimgcodec.h#L605-L616
[tiff-numimages]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/parsers/tiff.cpp#L968-L976
[png-numimages]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/parsers/png.cpp#L230
[webp-anim]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/src/parsers/webp.cpp#L35-L42
[tiff-xmp]: https://github.com/NVIDIA/nvImageCodec/blob/e7a7ef0f5ef4ce6b9f4c37b6287278e8bb5df48f/extensions/nvtiff/metadata_extractor.cpp#L405-L423
[c-plane]: ./concepts.md#plane
[c-stride]: ./concepts.md#stride
[c-tiling]: ./concepts.md#tiling
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[c-extmem]: ./concepts.md#external-memory-and-zero-copy-import
[c-gpudecomp]: ./concepts.md#gpu-decompression
