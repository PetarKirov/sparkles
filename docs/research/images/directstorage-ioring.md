# DirectStorage and IoRing (Windows)

Windows' two storage paths for bulk asset loading: DirectStorage, a queue of read requests that
lands bytes in system memory or a D3D12 resource and can decompress GDeflate on the GPU on the
way, and IoRing, the Win32 kernel submission/completion ring of the same shape, read at the
SDK-samples revision and from Microsoft Learn.

| Field         | Value                                                                                                                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | C++ (nano-COM API in `dstorage.h`), HLSL (GPU decompressors), C (Win32 `ioringapi.h`)                                                                                                      |
| License       | Samples MIT ([`LICENSE`][license]); GDeflate reference codec Apache-2.0 ([`GDeflate/GDeflate/LICENSE`][gd-license]); the runtime itself is a binary NuGet package                          |
| Repository    | [microsoft/DirectStorage][repo] (samples, GDeflate and zstd reference code); runtime [`Microsoft.Direct3D.DirectStorage`][nuget] on NuGet                                                  |
| Revision read | `32f9411bccab60cec8d7054edbf186219d9bfdf2` ("Merge development branch into main (#165)", October 20, 2026); `dstorage.h` from the 1.3.0 NuGet package the `HelloDirectStorage` sample pins |
| Documentation | [Developer guidance][guidance] · [GDeflate stream format][gd-spec] · [`ioringapi.h` on Microsoft Learn][learn-ioring] · [BypassIO for filter drivers][learn-bypass]                        |
| Category      | Storage to GPU: request queues, GPU decompression, kernel I/O rings                                                                                                                        |
| Tier          | B                                                                                                                                                                                          |
| Last reviewed | November 7, 2026                                                                                                                                                                           |

> [!NOTE]
> Sparkles has no Windows machine, so every statement about DirectStorage, IoRing and BypassIO
> behaviour is **documented**: it comes from the samples, the header comments or Microsoft Learn,
> not from a run. Quotes from the repository were read with `git show 32f9411bc:<path>`. The one
> **verified here** result is the GDeflate reference CPU codec, which builds on Linux: it was
> compiled with AddressSanitizer (GCC 14.3 from `nix-shell -p gcc`) against NVIDIA's `libdeflate`
> fork at the submodule's pinned `8ba9502fb30d2bf728592d121f0d402e40c8cb05`, in a scratch
> directory under `/tmp`, on November 14, 2026. No timing was measured.

---

## Overview

### What it solves

DirectStorage targets the cost of many small reads and of decompressing them on the CPU. The
repository README states the problem ([`README.md`][readme-why]):

> _"Although it is possible to saturate a drive using traditional ReadFile-based IO the CPU
> overhead increases non-linearly as the size of individual reads decreases. Additionally, most
> games choose to store their assets compressed on disk in order to reduce the install footprint,
> with these assets being decompressed on the fly as load time."_

Its answer has three parts: a request queue that batches reads and reports completion per batch,
destinations that are D3D12 buffers and textures rather than host pointers, and a compression
format (GDeflate) designed to decompress on GPU compute. It is read-only by design: "DirectStorage
only supports read operations" ([`README.md`][readme-ro]). IoRing is the Win32 kernel interface
of the same shape without the GPU: "I/O rings maintain a submission queue of I/O operations to be
performed asynchronously and a completion queue containing the results of the completed
operations" ([`ioringapi.h`][learn-ioring]).

### Design philosophy

The API mirrors Xbox, and one large departure is that the driver, not the file, owns texture
layout. The developer guidance puts it as ([`Docs/DeveloperGuidance.md`][guid-dest]):

> _"This is necessary because the graphics driver is responsible for determining the actual
> layout of the resources in memory, and so the assets must be stored on disk in an unswizzled
> format."_

The second principle is batch-granular notification: requests complete in any order, and only a
status entry or fence enqueued after them orders anything. The third is that compression is
per request, never per file: "each section of the file must be compressed in isolation"
([`Docs/DeveloperGuidance.md`][guid-compressed]).

## How it works

### Queues, requests and the four operations

A factory (`DStorageGetFactory`) opens files (`IDStorageFile`) and creates queues
(`IDStorageQueue`). Each queue is bound at creation to one source type (file or memory), one
priority and, through `DSTORAGE_QUEUE_DESC::Device`, to an `ID3D12Device` or to system memory
([`Docs/DeveloperGuidance.md`][guid-queues]). The queue takes four kinds of entries: a request, a
fence signal (`EnqueueSignal`), a status write (`EnqueueStatus`) and an event set
(`EnqueueSetEvent`). Each entry holds a slot until it completes; capacity is
`DSTORAGE_MIN_QUEUE_CAPACITY` (`0x80`) to `DSTORAGE_MAX_QUEUE_CAPACITY` (`0x2000`) in the 1.3.0
header, and "If Enqueue is called when there are no free slots then it will block until a slot
becomes available." Requests start only on `Submit()`, or automatically "when the queue is half
full" ([`Docs/DeveloperGuidance.md`][guid-queues]).

The minimal sample reads a whole file into a default-heap buffer and waits on a fence
([`Samples/HelloDirectStorage/HelloDirectStorage.cpp`][hello-req]):

```cpp
DSTORAGE_REQUEST request = {};
request.Options.SourceType = DSTORAGE_REQUEST_SOURCE_FILE;
request.Options.DestinationType = DSTORAGE_REQUEST_DESTINATION_BUFFER;
request.Source.File.Source = file.get();
request.Source.File.Offset = 0;
request.Source.File.Size = fileSize;
request.UncompressedSize = fileSize;
request.Destination.Buffer.Resource = bufferResource.get();
...
queue->EnqueueRequest(&request);
...
queue->EnqueueSignal(fence.get(), fenceValue);
queue->Submit();
```

`DSTORAGE_REQUEST` carries `Options` (an 8-bit `CompressionFormat`, a 1-bit `SourceType`, a 7-bit
`DestinationType`), `Source`, `Destination`, a 32-bit `UncompressedSize`, a 64-bit
`CancellationTag` matched by `CancelRequestsWithTag(mask, value)`, and an optional debug `Name`
(1.3.0 `dstorage.h`). The header's rule for sizes: "if the destination is memory, then the
uncompressed size must exactly equal the destination size. For other destination types, the
uncompressed size may be greater than the destination size."

### Destinations

Six destination types exist ([`Docs/DeveloperGuidance.md`][guid-dest]): `MEMORY` (a pointer and
size), `BUFFER` (resource, offset, size, written with `CopyBufferRegion`), `TEXTURE_REGION` (one
subresource region, data "laid out in a format suitable for CopyTextureRegion" as reported by
`ID3D12Device::GetCopyableFootprints()`), `MULTIPLE_SUBRESOURCES` (from a first subresource to the
end, for mip tails or whole textures), `MULTIPLE_SUBRESOURCES_RANGE` (a counted range) and `TILES`
(a region of a tiled resource, data arranged for `CopyTiles()`). The `EnqueueRequestsDemo` loads a
mip range into a reserved resource and orders it after `UpdateTileMappings` by passing a fence
into `EnqueueRequests(requests, count, fence, value, DSTORAGE_ENQUEUE_REQUEST_FLAG_NONE)`
([`Samples/EnqueueRequestsDemo/EnqueueRequestsDemo.cpp`][enq-demo]).

### Completion: status arrays, fences and error records

An `IDStorageStatusArray` entry covers every request between it and the previous status entry.
The 1.3.0 header documents `GetHResult(index)` as `E_PENDING` until all are done, then "the
failure code of the first failed request in the enqueue order", else `S_OK`; `IsComplete(index)`
is "equivalent to `GetHResult(index) != E_PENDING`". `BulkLoadDemo` gives each model file one
status array with one entry per phase (metadata, CPU data, GPU data) and checks them when the
phase's event fires ([`Samples/BulkLoadDemo/BulkLoadDemo/MarcFile.cpp`][marc-status]).
`HelloDirectStorage` instead reads the queue-wide `DSTORAGE_ERROR_RECORD` (`FailureCount`,
`FirstFailure`) after the fence ([`HelloDirectStorage.cpp`][hello-err]). Error locality is the
cost of batching: "read errors are bound to the following IDStorageQueue/ID3D12Fence entry, the
error could be from any of the previous reads" ([`Docs/DeveloperGuidance.md`][guid-donts]).

### Staging buffers

Data does not move from disk to a resource directly in the documented model. The runtime keeps a
system-memory staging buffer and an upload-heap staging buffer, plus, for GPU decompression, an
input and an output staging buffer in VRAM, each of the size set by
`IDStorageFactory::SetStagingBufferSize`. A request's uncompressed data must fit one of them:
"Requests that need to go through a staging buffer with an uncompressed size that is larger than
the staging buffer size will fail" ([`Docs/DeveloperGuidance.md`][guid-staging]). The default is
`DSTORAGE_STAGING_BUFFER_SIZE_32MB`; `BulkLoadDemo` sets 256 MiB, and its archive tool takes
`-stagingbuffersize` to split regions so no request exceeds it
([`Samples/BulkLoadDemo/README.md`][bulk-readme]).

### Compression formats and the custom decompression queue

`DSTORAGE_COMPRESSION_FORMAT` has `NONE`, `GDEFLATE` and custom values from
`DSTORAGE_CUSTOM_COMPRESSION_0` (`0x80`) in 1.3.0; the benchmark sample, pinned to
`1.4.0-preview2-2606.904`, also uses `DSTORAGE_COMPRESSION_FORMAT_ZSTD`
([`GpuDecompressionBenchmark.cpp`][bench-cases]). `IDStorageQueue2::GetCompressionSupport` reports
the path the runtime chose as flags: `GPU_OPTIMIZED` (a driver metacommand), `GPU_FALLBACK` (the
built-in shader), `CPU_FALLBACK`, and whether it uses a compute or a copy queue (1.3.0
`dstorage.h`). Custom formats, and built-in formats when built-in CPU threads are disabled, are
handed to the application through `IDStorageCustomDecompressionQueue1`: an event signals
availability, `GetRequests1` pulls a batch, and `SetRequestResults` reports each one. The sample
wires this to the Windows thread pool and decompresses zlib, copying through a scratch buffer
when `DSTORAGE_CUSTOM_DECOMPRESSION_FLAG_DEST_IN_UPLOAD_HEAP` is set because "ZLib decompression
tends to read from the destination buffer, which is extremely slow from write-combined memory"
([`Samples/BulkLoadDemo/BulkLoadDemo/DStorageLoader.cpp`][loader-custom]).

### GDeflate: the format

GDeflate keeps DEFLATE's LZ77 and Huffman coding and permutes the bitstream into 32 interleaved
sub-streams ([`GDeflate/GDeflate/README.md`][gd-spec-def]):

> _"The bit swizzling is done by first splitting the DEFLATE stream into 32 sub-streams and then
> serializing them to get the final GDeflate stream that allows for up to 32 way parallelism
> during decompression."_

Decoding runs in rounds, one Huffman symbol per sub-stream per round; a sub-stream that decoded a
length code decodes its distance in the next round and takes no new literal. Each sub-stream
keeps a 64-bit bit buffer refilled 32 bits at a time, and the serialization order guarantees that
the refills of one round "appear consecutively in the serialized stream in the same order as the
sub-streams", so reads are dense ([`GDeflate/GDeflate/README.md`][gd-spec-serial]). The stream
ends with zero padding, most simply "128 bytes (32 4B chunks) of zeros"
([`GDeflate/GDeflate/README.md`][gd-spec-end]). Above the bitstream sits a [tiling][c-tiling]
container: an 8-byte `TileStream` header (`id`, `magic` equal to `id ^ 0xff`, a 16-bit
`numTiles`, an 18-bit `lastTileSize`), then a table of 32-bit tile offsets, then the tiles, each
decompressing to at most `kDefaultTileSize` (64 KiB) ([`TileStream.h`][gd-tilestream],
[`config.h`][gd-config]). Tiles are the unit of parallelism across workgroups or threads;
sub-streams are the unit within one.

### GDeflate: the shader decompressor

`GDeflate.hlsl` runs one 32-thread group per tile (`NUM_THREADS` equals `NUM_BITSTREAMS`). Build
switches select wave intrinsics (`USE_WAVE_INTRINSICS`, shader model 6.0), `WaveMatch`
(`USE_WAVE_MATCH`, 6.5) and a `SIMD_WIDTH`; when the wave is at least 32 lanes the decoder keeps
its tables in registers (`IN_REGISTER_DECODER`), otherwise in `groupshared` memory
([`GDeflate/shaders/GDeflate.hlsl`][hlsl-config]). Bindings are raw byte-address buffers: `input`,
a `control` buffer listing streams with their input and output offsets, `output`, and a `scratch`
buffer of per-stream tile counters ([`GDeflate.hlsl`][hlsl-bind]). The entry point is a
persistent work-stealing loop ([`GDeflate.hlsl`][hlsl-main]):

```hlsl
// Leader grabs the tile index
if (tid == 0)
{
    scratch.InterlockedAdd(ScratchStreamTileIndexOffset(streamIdx), 1u, tileIdx);
}
...
if (tileIdx >= tileStream.GetNumTiles())
    break;
TileParams params = tileStream.GetTileParams(streamInPos, streamOutPos, tileIdx);
DecompressTile(params, tid);
```

When a stream's tiles are exhausted the group decrements the stream count with
`InterlockedCompareExchange` and moves to the next stream. The demo dispatches a fixed number of
groups, `(SIMDLaneCount / SIMDWidth) * 8`, not one per tile
([`GDeflate/GDeflateDemo/GpuDecompressor.cpp`][gd-dispatch]). The repository does not say whether
the runtime's built-in GDeflate fallback shader is this one; the header says only that a driver
metacommand (`GPU_OPTIMIZED`) is preferred over the built-in shader (`GPU_FALLBACK`). A ZStandard
GPU decoder sits in `zstd/` with the warning that it "should NOT be used in production
environments", and its README states that versions of those zstd shaders are compiled into the
runtime as its fallback ([`zstd/README.md`][zstd-readme]).

### BypassIO

BypassIO is the kernel half of the file path. Microsoft Learn: "The BypassIO feature offers an
optimized I/O path for reading from files ... BypassIO is part of the infrastructure that supports
DirectStorage on Windows. It's available starting in Windows 11" ([BypassIO][learn-bypass]). Its
documented scope is client systems, NVMe devices, NTFS, noncached reads and file handles only.
A read on a fully enabled handle goes from the I/O manager to NTFS, the disk driver and
`stornvme`, skipping file-system, volume and storage filters. It is per handle and fragile: a
second handle doing cached or memory-mapped I/O suspends it, as do sparse marking and
defragmentation, and a minifilter that has not opted in blocks it for the whole volume; BitLocker
gives "partial" BypassIO. `fsutil bypassIo state` names the vetoing driver. DirectStorage exposes
the switches in `DSTORAGE_CONFIGURATION1`: `DisableBypassIO`, `ForceMappingLayer` (force "the
Windows 10 I/O stack") and `ForceFileBuffering`, which drops `FILE_FLAG_NO_BUFFERING` and
requires BypassIO disabled (1.3.0 `dstorage.h`; [`Docs/DeveloperGuidance.md`][guid-config]).

### IoRing

`CreateIoRing(ioringVersion, flags, submissionQueueSize, completionQueueSize, &h)` returns an
`HIORING`. The system "may round up" the submission queue size to a power of two, and rounds the
completion queue up to
"a power of two that is no less than two times the actual submission queue size"
([`CreateIoRing`][learn-create]). Operations are built into the submission queue with `BuildIoRing*`
calls; `BuildIoRingReadFile(ioRing, fileRef, dataRef, numberOfBytesToRead, fileOffset, userData,
sqeFlags)` takes an `IORING_HANDLE_REF` and an `IORING_BUFFER_REF`, each either a raw
handle/pointer or an index into a registered table ([`BuildIoRingReadFile`][learn-read]; the
`IoRingHandleRefFromIndex` and `IoRingBufferRefFromIndexAndOffset` helpers on
[`ioringapi.h`][learn-ioring]).
`BuildIoRingRegisterBuffers` and `BuildIoRingRegisterFileHandles` install those tables; for
buffers this "allows the kernel implementation to perform the validation and internal mapping
just once avoiding the overhead on each I/O operation" ([`BuildIoRingRegisterBuffers`][learn-regbuf]).
`IORING_OP_REGISTER_FILES` and `IORING_OP_REGISTER_BUFFERS` "implicitly" have "link" semantics:
later entries wait for them ([`IORING_OP_CODE`][learn-opcode]). `SubmitIoRing(ioRing,
waitOperations, milliseconds, &submitted)` submits everything built and optionally waits; on any
error but `IORING_E_WAIT_TIMEOUT` "all entries remain in the submission queue", while an error in
one entry becomes a synchronous error completion ([`SubmitIoRing`][learn-submit]). Completions are
`IORING_CQE { UserData, ResultCode, Information }` ([`IORING_CQE`][learn-cqe]), popped with
`PopIoRingCompletion` or signalled by an event registered with `SetIoRingCompletionEvent`
([`ioringapi.h`][learn-ioring]). The `IORING_OP_CODE`
syntax lists `NOP`, `READ`, `REGISTER_FILES`, `REGISTER_BUFFERS`, `CANCEL`, `WRITE`, `FLUSH`,
`READ_SCATTER` and `WRITE_GATHER`, but the page describes only the first five, and the
`ioringapi.h` index lists no write, flush, scatter or gather builder; the minimum client for the
API is Windows build 22000.
Capability is queried, not assumed: `QueryIoRingCapabilities`, `IsIoRingOpSupported`.

## Analysis

### 1. Pixel and memory model

DirectStorage has no pixel model of its own; it defers to D3D12's. A texture request carries bytes
already in `GetCopyableFootprints` layout, so the on-disk form is the driver's linear copy layout
for that format and subresource, not a packed image. A [block-compressed][c-bcn] texture is
"unswizzled" BCn on disk, GDeflate-compressed per request. Tiled resources use 64 KiB tiles, the
same size as a GDeflate tile; the header's size rule for `TILES` is "64k \* number of tiles".

### 2. Genericity mechanism

Not applicable, because DirectStorage and IoRing move untyped bytes: a request names a byte range
and a destination, and the element type exists only in the D3D12 resource description. Custom
compression formats are told apart by an enum value (`DSTORAGE_CUSTOM_COMPRESSION_0` and up),
not by a type.

### 3. Colour and metadata

Not applicable, because no layer here interprets pixels: colour space, ICC and HDR metadata
belong to whatever format the application stores in the request's bytes and to the D3D12
resource's `DXGI_FORMAT`.

### 4. I/O and codec architecture

Three designs are worth separating. The request queue is batch-oriented and order-free; ordering
and error reporting attach to explicit fence or status entries, and dependency chains are named an
anti-pattern ("Don't use DirectStorage with dependency change assets", with a worked 8 ms, 512 KiB,
64 MB/s example; [`Docs/DeveloperGuidance.md`][guid-donts]). The codec seam is a pull queue: the
runtime owns staging memory and hands out `(SrcBuffer, SrcSize, DstBuffer, DstSize, Flags)`; the
application decodes in place and posts a result. And GDeflate is a [container and
bitstream][c-container] split: a self-describing tile index over independently decodable 64 KiB
pages, each internally parallel. The file format of the sample archive (`.marc`) is built around
the request: "A 'Region' describes a part of the file that can be read with a single
DirectStorage request" and chooses its own compression ([`MarcFileFormat.h`][marc-format]).

### 5. Hostile input and safety

DirectStorage is designed for a title's own packaged assets, and nothing read describes it as a
[hostile-input][c-hostile] decoder. The reference CPU codec demonstrates the risk of reusing it
for untrusted data. `GDeflate::Decompress(output, outputSize, in, inSize, numWorkers)` checks only
that the pointers are non-null, the sizes non-zero, `id == magic ^ 0xff` and `id` equals
`kGDeflateId` (4); it then discards the caller's `outputSize` in favour of the header's
(`context.outputSize = header->GetUncompressedSize();`), writes each tile at
`tileIndex * kDefaultTileSize`, and never consults `inSize` when reading the tile-offset table or
tiles ([`GDeflateDecompress.cpp`][gd-decompress]). Verified here under AddressSanitizer, with a
197,608-byte input compressed at level 9 (four tiles, the last 1,000 bytes); a rebuild from the
pinned sources on November 15, 2026 gave the same three results:

```text
$ probe roundtrip
in=197608 compressed=32676 header: id=4 magic=0xfb numTiles=4 lastTileSize=1000
decompress=1 equal=1
$ probe small-output        # outputSize = 65536, header says 197608
ERROR: AddressSanitizer: heap-buffer-overflow ... WRITE of size 1
    #2 TileDecompressionJob GDeflateDecompress.cpp:95
0x531000024800 is located 0 bytes after 65536-byte region
$ probe truncated-input     # inSize = 16 of 32676 bytes
ERROR: AddressSanitizer: heap-buffer-overflow ... READ of size 4
0x502000000088 is located 8 bytes after 16-byte region
```

The HLSL decompressor likewise trusts the `numTiles` it loads from `input` and the offsets in the
`control` buffer. The runtime's own validation is not visible (it is a binary); the header's
`UncompressedSize` and staging-size failure rules are the documented bounds. The zstd CI harness
has a hook for adversarial files: an `adversarial_manifest` maps "known-adversarial fuzz files to
their expected demo exit code" ([`adversarial_manifest.h`][zstd-adv]); the repository ships the
loader and a sample manifest, not the fuzz files.

### 6. Allocation and ownership

The runtime owns every intermediate buffer, sized once by `SetStagingBufferSize`, and the
guidance frames the size as a trade between bandwidth and "your application's rendering budget"
([`Docs/DeveloperGuidance.md`][guid-staging-size]). Requests larger than a staging buffer fail
rather than spill, which pushes chunking into the asset format. Queues are long-lived ("Don't
constantly create IDStorageQueue objects"), and queue slots, not memory, are the back-pressure
mechanism: enqueue blocks when full, and the advice is capacity of "~2x your expected maximum".
IoRing makes the same choice in the kernel: a new buffer registration "replaces the previous
registration completely", and entries with a NULL address and zero length are sparse, unused
slots ([`BuildIoRingRegisterBuffers`][learn-regbuf]).

### 7. CPU parallelism and SIMD

The CPU GDeflate decoder parallelises across tiles only: up to `kMaxWorkers = 31` threads pull
tile indices from an atomic counter, and one thread is used unless there are more than twice as
many tiles as workers ([`GDeflateDecompress.cpp`][gd-decompress]). Sub-stream interleaving buys
nothing on a scalar CPU decoder; it exists for 32-lane groups. The same tile-counter idiom is the
GPU's work-stealing loop, so one container serves both executors.

### 8. GPU offload and interop

In DirectStorage the file read, the decompression and the copy into a sampled resource are one
request completed by one fence. The decompression runs on a compute or copy queue chosen by the
runtime and reported by `GetCompressionSupport`, with a driver metacommand preferred over the
built-in shader and a CPU fallback when neither GPU path is available. Synchronisation is plain
D3D12: `EnqueueSignal` writes an `ID3D12Fence` the graphics queue waits on, and `EnqueueRequests`
waits on one before writing. The Vulkan counterpart is narrower: `VK_NV_memory_decompression` and
`VK_EXT_memory_decompression` decode GDeflate 1.0 buffer to buffer and leave the file read and the
image copy to the application ([Vulkan transfer][vk-decomp]). Vulkan regions are raw GDeflate
pages capped at 64 KiB of output, the size of a DirectStorage tile; the `TileStream` header is not
part of the Vulkan interface, so an application reading the same files through Vulkan parses the
tile table itself and issues one region per tile.

### 9. Temporal, animation and containers

Not applicable to animation, because nothing here has a time axis. The container side is covered
under [I/O and codec architecture][s-io]: the GDeflate tile stream and the sample's `.marc`
regions.

### 10. Testing and conformance

`GDeflateTest` is a differential oracle between the open reference codec and the closed runtime:
for fixed sizes (1, 2, 123, 64 KiB and its neighbours, 4 MiB) and five random sizes up to 32 MiB,
it compares compressed bytes and runs all four cross-decompressions, DS to DS, reference to DS, DS
to reference and reference to reference ([`GDeflateTest.cpp`][gd-test]). The zstd GPU decoder has
a manifest format for adversarial inputs with expected exit codes and per-GPU scenario skips (a
sample manifest and no fuzz files at this revision). No conformance corpus or fuzz input for
GDeflate appears in the repository.

## Lessons for Sparkles

- **Q6.** The unit of a storage-to-GPU pipeline is the request, sized to a staging buffer and
  decodable in isolation; formats are built around it (`.marc` regions, 64 KiB GDeflate tiles).
  An image library that wants this path needs a container whose index names independently
  decodable byte ranges, which a monolithic PNG `IDAT` or a single zlib stream does not provide.
- **Q6.** Batch completion with first-failure error reporting (status arrays, fences) suits loads
  of many small pieces with one consumer. `sparkles:event-horizon` reports per operation; a
  batch aggregate would sit above it rather than in it ([event-horizon baseline][bl-eh]).
- **Q6, Q9.** On Windows the [event-horizon baseline][bl-eh-gaps] records IOCP with sockets and
  timers only and no IoRing anywhere in the specs. IoRing's surface (power-of-two rings,
  registered buffer and handle tables, a `UserData` correlation word, an event for completion
  wake-ups) maps onto the `io_uring` concepts the Linux backend already uses
  ([io_uring storage][io-uring]); its `IORING_OP_CODE` syntax lists reads, writes, flush,
  scatter and gather, though Microsoft Learn documents a builder only for reads, and its floor is
  Windows build 22000. Whether it is an event-horizon backend or a
  separate file path is a design question this page does not settle.
- **Q4.** The custom decompression queue is a codec seam where the I/O layer owns memory and the
  codec decodes from one span into another. That inverts the usual decoder-owns-reader design and
  fits a `@nogc` decoder taking caller storage, as `sparkles.font.png` does
  ([existing code][bl-existing]).
- **Q4, Q8.** The GDeflate reference CPU decoder is not a hostile-input decoder (demonstrated
  above). If Sparkles reads GDeflate, its decoder must check the header against caller sizes and
  each tile offset against the input length, and a fuzz target is required; the reference codec
  is useful as a differential oracle only for well-formed streams.
- **Q7.** GDeflate shows the shape of a format designed for both executors: coarse independent
  tiles for CPU threads and GPU workgroups, fine 32-way interleave for lanes. The break-even
  between them is not measured anywhere in the repository read, and none is claimed here.
- **Q1.** The disk layout of a GPU-bound texture is the API's copy footprint, not the image's
  natural stride. A Sparkles view type that can describe a footprint (row pitch, subresource
  offsets) can target DirectStorage, Vulkan buffer-to-image copies and KTX2 alike
  ([Vulkan transfer][vk-transfer]).
- **Q8.** A two-implementation differential test (open reference against closed runtime, all
  cross pairs) is a cheap pattern Sparkles can repeat for any codec it ships beside a system one.

## Strengths

- One request covers read, decompression and placement into a buffer, texture region, mip range
  or tiles, with D3D12 fences for synchronisation.
- Completion is batch-granular and order-free, which matches how assets are consumed.
- The decompression path is chosen at run time (metacommand, shader, CPU) and reported to the
  application.
- The GDeflate format, reference CPU codec and HLSL decoder are open, and the format is reused by
  Vulkan's memory-decompression extensions.
- Custom formats plug into the same queue through a pull interface.
- IoRing gives Windows a documented kernel submission/completion ring with registered buffers and
  handles.

## Weaknesses

- Windows and D3D12 only; the runtime is closed, so its validation and scheduling cannot be read.
- Read only; no write path in DirectStorage.
- BypassIO is NVMe, NTFS, client-only, per handle, and silently degraded by filters, encryption,
  other handles or defragmentation.
- Errors are reported per batch as the first failure, so finding the failing request needs extra
  status entries.
- Requests larger than the staging buffer fail; chunking falls to the asset format.
- The GDeflate reference CPU decoder ignores `outputSize` and `inSize` (verified here); the
  repository has no GDeflate fuzzing or corpus.
- The zstd GPU decoder is explicitly not production quality at this revision.

## Sources

- microsoft/DirectStorage at `32f9411bccab60cec8d7054edbf186219d9bfdf2`: [`README.md`][readme-why],
  [`Docs/DeveloperGuidance.md`][guidance], [`HelloDirectStorage.cpp`][hello-req],
  [`DStorageLoader.cpp`][loader-custom], [`MarcFile.cpp`][marc-status],
  [`EnqueueRequestsDemo.cpp`][enq-demo], [`GpuDecompressionBenchmark.cpp`][bench-cases],
  [`GDeflate/GDeflate/README.md`][gd-spec], [`TileStream.h`][gd-tilestream],
  [`GDeflateDecompress.cpp`][gd-decompress], [`GDeflate.hlsl`][hlsl-main],
  [`GDeflateTest.cpp`][gd-test], [`zstd/README.md`][zstd-readme].
- `dstorage.h` from [`Microsoft.Direct3D.DirectStorage` 1.3.0][nuget] (NuGet package, read locally).
- NVIDIA `libdeflate` fork at [`8ba9502fb30d2bf728592d121f0d402e40c8cb05`][libdeflate] (submodule,
  used for the AddressSanitizer probe).
- Microsoft Learn: [`ioringapi.h`][learn-ioring], [`CreateIoRing`][learn-create],
  [`BuildIoRingReadFile`][learn-read], [`BuildIoRingRegisterBuffers`][learn-regbuf],
  [`SubmitIoRing`][learn-submit], [`IORING_CQE`][learn-cqe], [`IORING_OP_CODE`][learn-opcode],
  [BypassIO for filter drivers][learn-bypass].
- Survey context: [storage-to-GPU papers][p-gpu-decode], [Vulkan transfer][vk-transfer],
  [event-horizon baseline][bl-eh], [concepts][concepts].

<!-- References -->

[repo]: https://github.com/microsoft/DirectStorage/tree/32f9411bccab60cec8d7054edbf186219d9bfdf2
[license]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/LICENSE
[gd-license]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/LICENSE
[readme-why]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/README.md#L2
[readme-ro]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/README.md#L8
[guidance]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md
[guid-queues]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L44-L59
[guid-dest]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L61-L84
[guid-compressed]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L86-L87
[guid-staging]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L89-L106
[guid-staging-size]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L108-L109
[guid-config]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L181-L200
[guid-donts]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Docs/DeveloperGuidance.md#L202-L243
[hello-req]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/HelloDirectStorage/HelloDirectStorage.cpp#L103-L128
[hello-err]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/HelloDirectStorage/HelloDirectStorage.cpp#L134-L151
[loader-custom]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/BulkLoadDemo/BulkLoadDemo/DStorageLoader.cpp#L71-L226
[marc-status]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/BulkLoadDemo/BulkLoadDemo/MarcFile.cpp#L62-L297
[marc-format]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/BulkLoadDemo/BulkLoadDemo/MarcFileFormat.h#L76-L80
[bulk-readme]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/BulkLoadDemo/README.md#L40-L48
[enq-demo]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/EnqueueRequestsDemo/EnqueueRequestsDemo.cpp#L594-L647
[bench-cases]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/Samples/GpuDecompressionBenchmark/GpuDecompressionBenchmark.cpp#L418-L458
[gd-spec]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md
[gd-spec-def]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md#L13-L22
[gd-spec-serial]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md#L26-L37
[gd-spec-end]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md#L107-L109
[gd-tilestream]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/TileStream.h#L31-L81
[gd-config]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/config.h#L24-L29
[gd-decompress]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/GDeflateDecompress.cpp#L72-L169
[gd-dispatch]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflateDemo/GpuDecompressor.cpp#L12
[gd-test]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflateTest/GDeflateTest.cpp#L174-L243
[hlsl-config]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/shaders/GDeflate.hlsl#L19-L29
[hlsl-bind]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/shaders/GDeflate.hlsl#L31-L37
[hlsl-main]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/shaders/GDeflate.hlsl#L892-L960
[zstd-readme]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/zstd/README.md#L7-L15
[zstd-adv]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/zstd/zstdgpu_ci_tests/adversarial_manifest.h#L10-L25
[libdeflate]: https://github.com/NVIDIA/libdeflate/tree/8ba9502fb30d2bf728592d121f0d402e40c8cb05
[nuget]: https://www.nuget.org/packages/Microsoft.Direct3D.DirectStorage/1.3.0
[learn-ioring]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/
[learn-create]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-createioring
[learn-read]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-buildioringreadfile
[learn-regbuf]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-buildioringregisterbuffers
[learn-submit]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-submitioring
[learn-cqe]: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/ns-ioringapi-ioring_cqe
[learn-opcode]: https://learn.microsoft.com/en-us/windows/win32/api/ntioring_x/ne-ntioring_x-ioring_op_code
[learn-bypass]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ifs/bypassio
[io-uring]: ./io-uring-storage.md
[vk-transfer]: ./vulkan-transfer.md
[vk-decomp]: ./vulkan-transfer.md#gpu-decompression-the-nv-and-ext-extensions
[bl-eh]: ./baseline/event-horizon.md
[bl-eh-gaps]: ./baseline/event-horizon.md#gaps-and-tensions
[bl-existing]: ./baseline/existing-code.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
[concepts]: ./concepts.md
[c-tiling]: ./concepts.md#tiling
[c-bcn]: ./concepts.md#block-compressed-formats-and-supercompression
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[s-io]: #_4-i-o-and-codec-architecture
