# Papers: GPU decode and storage-to-GPU streaming

The literature agrees on one shape for fast asset loading: **asynchronous,
queue-based I/O into a staging area, entropy decoding made parallel either by
the format (tiles, swizzled sub-streams, stored split states) or by a speculative
decoder that relies on self-synchronization, and a GPU or fixed-function engine
for the rest** — with a CPU fallback that is always present.

| Field             | Value                                                                                                                                                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Thread**        | `gpu-decode-streaming`                                                                                                                                                                                                |
| **Scope**         | Storage-to-GPU data paths (`io_uring`, `SPDK`, GPUDirect Storage, DirectStorage, Metal fast resource loading), GPU DEFLATE/GDeflate, GPU Huffman/ANS/JPEG decode, Vulkan memory decompression and Vulkan Video decode |
| **Entries**       | 26 (19 papers, 7 vendor or standards sources)                                                                                                                                                                         |
| **Last reviewed** | October 28, 2026                                                                                                                                                                                                      |

> [!NOTE]
> Quote page numbers ("p. N") are PDF page indices of the local copy, not the
> proceedings' printed page numbers. Quotes from web-only sources cite the page
> text as accessed on October 28, 2026; vendor pages change without notice.

## Why this thread matters to sparkles

`sparkles:{image,video}` wants a **storage-to-GPU I/O** path that does not stall
on the CPU: `event-horizon`'s `io_uring` proactor is the natural submission
engine, and `sparkles:vulkan` is where uploads, compute decompression and
Vulkan Video decode land. The **codec architecture** question is where the
serial part of decoding (bit-level entropy decode) lives: on the CPU, in a GPU
compute shader written with `sparkles:shaders`, or in a fixed-function engine
exposed through `VK_EXT_memory_decompression` or a Vulkan Video decode queue.
That choice also shapes the container: a format that records split points or
tiles (GDeflate, Recoil metadata, JPEG restart markers) is parallel by
construction, while plain DEFLATE or baseline JPEG needs speculative decoding
that must stay correct on **hostile input** — a resynchronizing decoder that
never synchronizes is a denial-of-service vector, and its bounds-checking
belongs in the same `wired`-style checked-view discipline as any other parser.
**SIMD** and **GPU compute** appear twice: the warp- or wave-cooperative
decoders here are the same algorithms a CPU SIMD decoder would use with lanes
instead of threads.

## Annotated bibliography

### Efficient IO with `io_uring` (Axboe, 2019)

| Field        | Value                                                                                           |
| ------------ | ----------------------------------------------------------------------------------------------- |
| Authors      | Jens Axboe                                                                                      |
| Venue/Year   | Self-published design note, [kernel.dk][axboe-pdf], 2019                                        |
| DOI or arXiv | none                                                                                            |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/axboe2019-efficient-io-with-io-uring.pdf` |
| Open access  | Y                                                                                               |

**Claim.** Linux `aio` is effectively limited to `O_DIRECT`, can block on
submission and copies per-I/O metadata both ways. `io_uring` replaces it with a
submission ring and a completion ring in memory shared by kernel and
application, so that submission and reaping need no copies and, with polling,
no system calls.

**Verbatim quote** (p. 3):

> As copies aren't desirable, it's clear that the kernel and the application
> have to graciously share the structures defining the IO itself, and the
> completion event.

**Relevance to sparkles.** This is the design document behind
`event-horizon`'s completion-first loop: an image loader should submit reads
as SQEs with a `user_data` that identifies the tile or chunk, and treat
completions as events that schedule decode work. Fixed (registered) buffers
map well onto a `UniqueBuffer`-owned staging arena that is later handed to a
Vulkan upload.

**Caveats.** Written for kernel 5.1; it predates registered buffer rings,
`IORING_OP_READ_FIXED` usage patterns at scale, `SQPOLL` changes, multishot
operations and `uring_cmd` NVMe passthrough. Treat it as the rationale, not as
the API reference.

### Understanding modern storage APIs: `libaio`, `SPDK` and `io_uring` (Didona et al., SYSTOR 2022)

| Field        | Value                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Authors      | Diego Didona, Jonas Pfefferle, Nikolas Ioannou, Bernard Metzler, Animesh Trivedi                        |
| Venue/Year   | SYSTOR '22, Haifa, 2022, pp. 120–127                                                                    |
| DOI or arXiv | [10.1145/3534056.3534945][didona]                                                                       |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/didona2022-understanding-modern-storage-apis.pdf` |
| Open access  | Y (author page)                                                                                         |

**Claim.** On 20 NVMe drives, polling design dominates performance. `io_uring`
with kernel-side submission polling (`SQPOLL`) approaches `SPDK`, but only when
spare cores exist for the kernel pollers; otherwise it collapses. Interrupt
mode and completion polling (`IOPOLL`) sit between.

**Verbatim quote** (p. 6):

> polling and a low system call overhead are crucial to performance, and that
> io_uring can achieve performance that is close to SPDK's, but obtaining
> io_uring's best performance requires understanding its design and applying
> careful tuning.

and, on the same page, "Our results recommend using twice as many CPU cores as
the number of drives".

**Relevance to sparkles.** `event-horizon` should expose the polling mode as a
configuration choice rather than hard-code `SQPOLL`: a desktop image viewer
with one NVMe drive and a busy UI thread is exactly the configuration where
kernel pollers steal the cores that decode needs.

**Caveats.** Raw block devices on kernel 5.13, not files through a
filesystem. It measures 4 KiB random I/O, which is far smaller than the
sequential asset reads an image library mostly issues. Ren and Trivedi (next
entry) reach a harsher verdict on Optane drives.

### Performance characterization of modern storage stacks (Ren and Trivedi, CHEOPS 2023)

| Field        | Value                                                                                                          |
| ------------ | -------------------------------------------------------------------------------------------------------------- |
| Authors      | Zebin Ren, Animesh Trivedi                                                                                     |
| Venue/Year   | CHEOPS '23, Rome, 2023, pp. 35–45                                                                              |
| DOI or arXiv | [10.1145/3578353.3589545][ren]                                                                                 |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/ren2023-performance-characterization-storage-stacks.pdf` |
| Open access  | Y                                                                                                              |

**Claim.** On Intel Optane SSDs it compares POSIX I/O, `libaio`, `io_uring`
and `SPDK`. At low load all four perform alike and polling buys 1.7× at 2.3×
the CPU instructions; at high load and scale `io_uring` is more than an order
of magnitude slower than `SPDK`; the benchmarking tool (`fio`) itself becomes
the bottleneck; and the Linux block I/O schedulers (BFQ, mq-deadline, Kyber)
add up to 50% overhead and scale poorly because of global locks.

**Verbatim quote** (p. 1):

> at low I/O loads, all APIs perform competitively with each other, with
> polling helping the performance by 1.7×, but consuming 2.3× CPU instructions

**Relevance to sparkles.** For the load an image viewer actually generates —
low queue depth, bursty — the interface choice matters less than the polling
choice, and polling has a CPU price that competes with decode. The `fio`
finding is a warning for `sparkles` benchmarks: at high IOPS the harness must
be measured too, or it measures itself.

**Caveats.** Optane devices, 4 KiB random reads; a workshop paper. The order-of-magnitude gap is at loads and core counts far beyond a
desktop asset loader.

### What modern NVMe storage can do, and how to exploit it (Haas and Leis, VLDB 2023)

| Field        | Value                                                                                   |
| ------------ | --------------------------------------------------------------------------------------- |
| Authors      | Gabriel Haas, Viktor Leis                                                               |
| Venue/Year   | PVLDB 16(9), 2023, pp. 2090–2102                                                        |
| DOI or arXiv | [10.14778/3598581.3598584][haas]                                                        |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/haas2023-modern-nvme-storage.pdf` |
| Open access  | Y                                                                                       |

**Claim.** An array of eight NVMe SSDs delivers 12.5M IOPS, but existing
storage engines reach a fraction. With asynchronous I/O issued directly from
worker threads (user-space task switching rather than I/O threads), the kernel
interfaces get close; `io_uring` with completion polling is the only kernel
path that saturates the array, while `SPDK` wins on CPU cycles per I/O.

**Verbatim quote** (p. 12):

> io_uring with I/O polling enabled was the only kernel interface that could
> achieve the full bandwidth of our NVMe array.

**Relevance to sparkles.** Its design rule — I/O submitted by the same workers
that do the compute, no dedicated I/O threads — matches a fiber-based
`event-horizon` decode pipeline in which a decode task suspends on its own
read. It also gives a concrete warning: `IOPOLL` needs `nvme.poll_queues`
configured, so a library must detect and fall back, not assume.

**Caveats.** Database page-sized random reads with a buffer manager; `SPDK`
needs root and an exclusive device, so it is not a deployable option for a
general-purpose image library.

### Asynchronous I/O: with great power comes great responsibility (Pestka et al., 2024)

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | Constantin Pestka, Marcus Paradies, Matthias Pohl                                                    |
| Venue/Year   | arXiv preprint, 2024                                                                                 |
| DOI or arXiv | [arXiv:2411.16254][pestka]                                                                           |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/pestka2024-asynchronous-io-responsibility.pdf` |
| Open access  | Y                                                                                                    |

**Claim.** Completion-based APIs (`io_uring`, I/O Rings, `SPDK`) move the
scheduling between submission and completion from the kernel into the
application, and that responsibility — not raw performance — explains their
low adoption. One thread cannot saturate a single PCIe 5.0 SSD, so parallelism
is mandatory; IOPS fall steeply when a few microseconds of other work run on
the polling thread; each ring with `SQPOLL` costs a kernel thread; and the
application must prevent submission-queue overflow and handle ordering and
cancellation. The paper then compares task-partitioning schemes (full,
callback, coroutines) and thread layouts (dedicated I/O threads versus M-to-N
sharing of rings).

**Verbatim quote** (p. 4):

> executing any non-I/O related subtask on the same thread that submits I/O
> (inline execution) will reduce the API instance utilization to a degree
> proportional to the execution time of the non-I/O tasks executed.

**Relevance to sparkles.** It is the checklist for `event-horizon`'s storage
side: bounded in-flight requests with backpressure when the submission queue
or the GPU decode queue is full, buffer ownership across submission and
completion, and a decision about whether entropy decoding runs inline on the
ring's thread or is handed to workers. With polling enabled, decoding inline
is exactly the case the paper shows collapsing.

**Caveats.** A short discussion paper; its measurements come from one desktop machine
(Ryzen 3900X, Samsung 990 Pro, Linux 6.8) and illustrate rather than prove.
Database-centric in its architectural examples.

### High-performance DBMSs with `io_uring`: when and how to use it (Jasny et al., VLDB 2026)

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | Matthias Jasny, Muhammad El-Hindi, Tobias Ziegler, Viktor Leis, Carsten Binnig                       |
| Venue/Year   | PVLDB 19(9), 2026, pp. 2317–2330                                                                     |
| DOI or arXiv | [10.14778/3819518.3819553][jasny]                                                                    |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/jasny2026-high-performance-dbmss-io-uring.pdf` |
| Open access  | Y (CC BY-NC-ND)                                                                                      |

**Claim.** Swapping `libaio` or `epoll` for `io_uring` in a buffer manager or
a network shuffle gains only 1.06× and 1.10×; designing around batching and
using registered buffers, NVMe passthrough and polling gains 2.05× and 2.31×.
In the buffer manager each feature adds a measured step (registered buffers
about 11%, passthrough 20%, `IOPOLL` 21%, `SQPOLL` about 32%), but in a
memory-resident TPC-C configuration `IOPOLL` is slightly worse and `SQPOLL`
gives nothing, because I/O is sporadic. Its guidelines improve PostgreSQL's
`io_uring` backend by 14%.

**Verbatim quote** (p. 1):

> Simply replacing traditional I/O interfaces with io_uring does not
> necessarily yield substantial performance benefits.

**Relevance to sparkles.** An `event-horizon` loader that wraps one-shot reads
in `io_uring` should be expected to measure as a wash; the gain comes from
keeping many chunks in flight, adaptive batching and registered staging
buffers. `IOPOLL` also disables non-polled I/O such as sockets on the same
ring and typically works only with `O_DIRECT`, so storage polling wants a ring
of its own, enabled only when the workload keeps the device busy.

**Caveats.** Database workloads (YCSB, TPC-C, shuffles) on server hardware;
NVMe passthrough bypasses the filesystem, which an asset loader reading
ordinary files cannot do.

### GPU-initiated on-demand storage access: BaM (Qureshi et al., ASPLOS 2023)

| Field        | Value                                                                                                                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Zaid Qureshi, Vikram Sharma Mailthody, Isaac Gelado, Seungwon Min, Amna Masood, Jeongmin Park, Jinjun Xiong, C. J. Newburn, Dmitri Vainbrand, I-Hsin Chung, Michael Garland, William Dally, Wen-mei Hwu |
| Venue/Year   | ASPLOS '23, 2023, pp. 325–339                                                                                                                                                                           |
| DOI or arXiv | [10.1145/3575693.3575748][bam-doi]; [arXiv:2203.04910][bam-arxiv]                                                                                                                                       |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/qureshi2023-bam-gpu-initiated-storage-access.pdf`                                                                                                 |
| Open access  | Y                                                                                                                                                                                                       |

**Claim.** For data-dependent access patterns, CPU-orchestrated transfers into
GPU memory waste bandwidth and add latency. BaM places NVMe submission and
completion queues and a software cache in GPU memory so GPU threads issue
storage requests themselves, coalescing requests to the same cache line.

**Verbatim quote** (p. 1):

> CPU initiation of storage access is unsuitable for these applications due to
> high CPU-GPU synchronization overheads, I/O traffic amplification, and long
> CPU processing latencies.

**Relevance to sparkles.** It is the far end of the design space — GPU-driven
sparse-texture or tiled-image paging — and it states the cost model clearly:
whoever decides _which_ tile to read should be close to whoever consumes it.
For `sparkles` the near-term analogue is a GPU-produced list of needed tiles
read back once per frame and turned into `io_uring` SQEs, not GPU-resident
NVMe queues. Several of its authors also wrote CODAG (below).

**Caveats.** Requires a custom kernel driver that hands the NVMe device to the
GPU (the artifact was tested on Linux 5.8), datacenter GPUs and raw block
access; nothing here is portable to consumer Vulkan.

### NVIDIA GPUDirect Storage design guide (NVIDIA, 2026)

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | NVIDIA                                                                                               |
| Venue/Year   | Product documentation, Release v1.19.1, September 17, 2026 ([docs.nvidia.com][gds])                  |
| DOI or arXiv | none                                                                                                 |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/nvidia2026-gpudirect-storage-design-guide.pdf` |
| Open access  | Y                                                                                                    |

**Claim.** GDS sets up a DMA path from NVMe (or a NIC) directly into GPU memory
through the `cuFile` API, eliminating the CPU bounce buffer; the CPU still owns
the control path. The destination must be pinned `cudaMalloc` memory, and the
DMA engines reach it through the GPU's BAR1 aperture: a transfer larger than
the aperture is chunked through an intermediate GPU buffer, and only some GPUs
expose BAR1 at all.

**Verbatim quote** (p. 7):

> GDS enables a direct DMA data path between GPU memory and storage, thus
> avoiding a bounce buffer through the CPU.

**Relevance to sparkles.** It names the cost that a portable path cannot avoid
— one copy through host memory — and lists what removing it buys (PCIe switch
locality, less CPU memory bandwidth). On consumer Vulkan the equivalent
optimization is reading straight into a host-visible, device-local
(resizable-BAR) or host-mapped staging buffer, so the bounce buffer _is_ the
upload source. Its conditions (aperture size, supported GPUs, pinned memory)
are a model of what a capability query must report rather than assume.

**Caveats.** CUDA- and Linux-specific, with `O_DIRECT` requirements on the
filesystem and supported PCIe topologies; no Vulkan interface.

### DirectStorage 1.1 and 1.2 (Microsoft DirectX blog, web)

| Field        | Value                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------ |
| Authors      | Cassie Hoef (Microsoft DirectX team)                                                                   |
| Venue/Year   | [DirectStorage 1.1 Now Available][ds11] (November 7, 2022); [DirectStorage 1.2][ds12] (April 18, 2023) |
| DOI or arXiv | none                                                                                                   |
| Local PDF    | web source                                                                                             |
| Open access  | Y                                                                                                      |

**Claim.** DirectStorage queues compressed requests, reads them unbuffered into
a staging buffer, and decompresses GDeflate on a compute queue (vendor
metacommand or a DirectCompute fallback), with two copy queues around it; a
request whose destination is system memory is decompressed on the CPU. 1.2
adds buffered I/O for hard drives and a query reporting which path (GPU
optimized, GPU fallback, CPU fallback) was selected.

**Verbatim quotes** (1.1 page text):

> If the request is for system memory – REQUEST_DESTINATION_BUFFER – then the
> CPU will be used to decompress the stream.

> staging buffer sizes of around 128 MiB are required to fully saturate the IO
> stack.

and (1.2 page text): "There are scenarios where a CPU based fallback path is
chosen."

**Relevance to sparkles.** The routing rule is directly reusable: decide CPU
versus GPU decompression from the _destination_ of the request, and make the
chosen path observable (`IDStorageQueue2::GetCompressionSupport` is the
precedent for a `sparkles` capability query). The batch tail effect described
in 1.1 argues for large batches and work stealing over per-request
dispatches.

**Caveats.** Windows-only, D3D12-only; numbers come from vendor blogs, not
independent measurement.

### GDeflate: tiled, sub-stream-swizzled DEFLATE (NVIDIA and Microsoft, web)

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | Yury Uralsky (NVIDIA blog); Microsoft DirectStorage team (reference implementation)                  |
| Venue/Year   | [NVIDIA Technical Blog][gdeflate-blog], November 7, 2022; [GDeflate reference README][gdeflate-spec] |
| DOI or arXiv | none                                                                                                 |
| Local PDF    | web source                                                                                           |
| Open access  | Y (reference code under Apache 2.0)                                                                  |

**Claim.** GDeflate keeps DEFLATE's LZ77 and Huffman coding but splits data
into independent 64 KB tiles (thread-group parallelism, random access) and,
inside a tile, deals codes round-robin into 32 interleaved sub-streams so a
32-wide SIMD group decodes one symbol per lane per round. Neither source
quantifies the compression-ratio cost of the tiling relative to plain DEFLATE.

**Verbatim quotes** (blog page text, then reference README):

> First, the original data stream is segmented into 64 KB tiles, which are
> processed independently.

> GDeflate extracts parallelism from a DEFLATE stream by swizzling (or
> permuting) the bits in the bitstream in such a way that Huffman codes can be
> naturally read in parallel.

**Relevance to sparkles.** This is the most practical format for a
`sparkles` asset container: a D CPU decoder and a `sparkles:shaders` compute
decoder can share one bitstream, the 64 KB tile matches the sparse-resource
page size, and the format is exactly what `VK_EXT_memory_decompression`
accepts. The sub-stream assignment rules are a small, testable spec that a
`wired`-style checked reader can validate tile by tile.

**Caveats.** Not a standard outside DirectStorage and Vulkan; the reference
code is Microsoft's and the bitstream is defined by its README rather than an
RFC. Throughput figures are vendor-reported.

### `VK_EXT_memory_decompression` (Khronos, Vulkan registry)

| Field        | Value                                                                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Vikram Kushwaha, Daniel Koch, Jeff Bolz, Christoph Kubisch, Piers Daniell (NVIDIA); Spencer Fricke (LunarG)                                             |
| Venue/Year   | Vulkan registry, [`VK_EXT_memory_decompression`][vk-ext] (ratified, last modified 2025-01-23); predecessor [`VK_NV_memory_decompression`][vk-nv] (2022) |
| DOI or arXiv | none                                                                                                                                                    |
| Local PDF    | web source                                                                                                                                              |
| Open access  | Y                                                                                                                                                       |

**Claim.** The extension adds `vkCmdDecompressMemoryEXT` and an indirect-count
variant that decompress buffer-device-address regions on a command buffer,
with a dedicated pipeline stage and access flags. The only defined method is
`VK_MEMORY_DECOMPRESSION_METHOD_GDEFLATE_1_0_BIT_EXT`. The registry marks
`VK_NV_memory_decompression` as promoted to this extension.

**Verbatim quote** (registry page text, Issue 1):

> For example, with GDeflate 1.0, data is streamed in 64 KB blocks, but the
> final block may be smaller.

**Relevance to sparkles.** A `sparkles:vulkan` upload path can offer
`decompressMemory` as an optional primitive (design by introspection): use the
extension when present, a compute-shader GDeflate otherwise, and a CPU decoder
last. The resolved issue also says the container must store the exact
decompressed size of the last block — a field `sparkles` must validate,
because setting it too low is undefined behaviour.

**Caveats.** Vendor coverage beyond NVIDIA is not established by the registry
page; the indirect variant reads counts from GPU memory, so hostile metadata
reaches the driver unless validated first.

### Metal 3 fast resource loading (Apple, WWDC22)

| Field        | Value                                                                   |
| ------------ | ----------------------------------------------------------------------- |
| Authors      | Jaideep Joshi (Apple)                                                   |
| Venue/Year   | WWDC22 session 10104, [Load resources faster with Metal 3][metal], 2022 |
| DOI or arXiv | none                                                                    |
| Local PDF    | web source                                                              |
| Open access  | Y                                                                       |

**Claim.** Metal 3 adds `MTLIOCommandQueue` (serial or concurrent, with
priority) and IO command buffers that load into textures, buffers or bytes,
synchronize with render work through shared events, and can be cancelled.
Assets can be packed with chunked compression (the example uses 64K chunks and
zlib) and opened through a compressed `MTLIOFileHandle`.

**Verbatim quote** (transcript text):

> Cancelling is at the command buffer granularity, so you can cancel the
> command buffer mid-execution.

**Relevance to sparkles.** Cancellation and priority are first-class in Apple's
model and absent from the Vulkan extensions; a streaming image viewer
(scrolling past a thumbnail grid) needs both, so `event-horizon`'s
cancellation must reach queued reads and pending decode batches. Apple again
chose fixed-size compressed chunks as the unit of parallelism.

**Caveats.** Apple-only; the decompression implementation and whether it runs
on the CPU, the GPU or dedicated hardware are not described.

### Parallel Huffman decoding with applications to JPEG files (Klein and Wiseman, 2003)

| Field        | Value                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------- |
| Authors      | Shmuel T. Klein, Yair Wiseman                                                                       |
| Venue/Year   | The Computer Journal 46(5), 2003, pp. 487–497                                                       |
| DOI or arXiv | [10.1093/comjnl/46.5.487][klein]                                                                    |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/klein2003-parallel-huffman-decoding-jpeg.pdf` |
| Open access  | Y (author copy via web.archive.org)                                                                 |

**Claim.** Split a Huffman bitstream into equal blocks, decode each from its
start, and let each processor overflow into the next block until its decoding
coincides with the neighbour's: Huffman codes almost always resynchronize
within a few codewords. The paper analyses the expected synchronization
distance and adapts the method to JPEG.

**Verbatim quote** (p. 1):

> A simple parallel algorithm for decoding a Huffman encoded file is presented,
> exploiting the tendency of Huffman codes to resynchronize quickly, i.e.
> recovering after possible decoding errors, in most cases.

**Relevance to sparkles.** This is the foundation every later GPU Huffman and
JPEG decoder cites. It requires no format change, so it applies to existing
baseline JPEG and DEFLATE; but the paper also notes synchronization is not
guaranteed (affix codes never synchronize), so a decoder needs a bound after
which it falls back to sequential decoding.

**Caveats.** Multi-core CPU era (2003); the JPEG adaptation must also track
DC-difference state across the boundary, which the GPU follow-ups treat more
carefully. Klein and Wiseman published CPU parallel Huffman/JPEG decoding, not
GPU DEFLATE.

### Massively parallel Huffman decoding on GPUs (Weißenberger and Schmidt, ICPP 2018)

| Field        | Value                              |
| ------------ | ---------------------------------- |
| Authors      | André Weißenberger, Bertil Schmidt |
| Venue/Year   | ICPP 2018                          |
| DOI or arXiv | [10.1145/3225058.3225076][weiss18] |
| Local PDF    | no open PDF                        |
| Open access  | N                                  |

**Claim.** It ports the self-synchronization idea to the GPU: each thread decodes
a short subsequence, synchronization points are found and propagated between
neighbouring subsequences, a prefix sum gives output offsets, and a final pass
decodes and writes. It is format-compatible with unmodified Huffman streams.

**Verbatim quote:** not verified (no open PDF). The algorithm outline above
follows the description in Rivera et al. 2022 (see that entry).

**Relevance to sparkles.** The structure — speculative decode, sync detection,
scan, write — maps onto a `sparkles:shaders` compute pipeline of three or four
dispatches, and onto a CPU SIMD decoder with lanes in place of threads.

**Caveats.** Code at [`gpuhd`][gpuhd]. Rivera et al. 2022 found the
implementation leaves performance on the table (shared memory, divergence).

### Optimizing Huffman decoding for error-bounded lossy compression on GPUs (Rivera et al., IPDPS 2022)

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Cody Rivera, Sheng Di, Jiannan Tian, Xiaodong Yu, Dingwen Tao, Franck Cappello                    |
| Venue/Year   | IPDPS 2022, pp. 717–727                                                                           |
| DOI or arXiv | [10.1109/IPDPS53621.2022.00075][rivera-doi]; [arXiv:2201.09118][rivera-arxiv]                     |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/rivera2022-optimizing-huffman-decoding.pdf` |
| Open access  | Y                                                                                                 |

**Claim.** It compares the two leading GPU Huffman decoders, self-synchronization
(Weißenberger and Schmidt) and gap arrays (Yamamoto et al., which store per-chunk
bit offsets at encode time), and optimizes both. Shared-memory staging, tuned
occupancy and less warp divergence give an average 3.64× speedup over `cuSZ`'s
decoder.

**Verbatim quote** (p. 1):

> we take full advantage of CUDA GPU architectures by using shared memory on
> decoding/writing phases, online tuning the amount of shared memory to use,
> improving memory access patterns, and reducing warp divergence.

**Relevance to sparkles.** It is the best open, side-by-side description of the
two strategies a `sparkles` format must choose between: pay a few bytes of side
data per chunk (gap array) for a deterministic one-pass decode, or pay
speculative work at decode time to stay compatible. For formats `sparkles`
controls, the gap-array choice is simpler to bound against hostile input.

**Caveats.** Scientific-data codebooks (`cuSZ`), CUDA and V100 only; the
gap-array paper itself (Yamamoto et al., ICPP 2020,
[10.1145/3404397.3404429][yamamoto]) has no open PDF.

### Revisiting Huffman coding: toward extreme performance on modern GPU architectures (Tian et al., IPDPS 2021)

| Field        | Value                                                                                         |
| ------------ | --------------------------------------------------------------------------------------------- |
| Authors      | Jiannan Tian, Cody Rivera, Sheng Di, Jieyang Chen, Xin Liang, Dingwen Tao, Franck Cappello    |
| Venue/Year   | IPDPS 2021, pp. 881–891                                                                       |
| DOI or arXiv | [10.1109/IPDPS49936.2021.00097][tian-doi]; [arXiv:2010.10039][tian-arxiv]                     |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/tian2021-revisiting-huffman-coding.pdf` |
| Open access  | Y                                                                                             |

**Claim.** The encoder counterpart of Rivera et al. from the same group: a
fully GPU-resident Huffman encoder, with parallel codebook construction, a
canonical codebook (decodable without the tree, with a cacheable reverse
codebook and no ratio loss) and a reduction-based merge of codewords. Data is
first cut into independent chunks per thread block. It reports up to 5.0× and
6.8× over the previous GPU encoder on an RTX 5000 and a V100, and up to 3.3×
over a multithreaded encoder on two 28-core Xeons.

**Verbatim quote** (p. 3):

> For coarse-grained parallelization, we divide the data into multiple
> independent chunks, not only because it is easy to map chunks to thread
> blocks and utilize local shared memory, but also because it will facilitate
> the reverse process, decoding.

**Relevance to sparkles.** Where `sparkles` itself produces compressed data on
the GPU (a decoded-tile cache, generated atlases), encoding should emit the
chunked, canonical-codebook layout that the decoders above consume, with chunk
count, offsets and codebook as validated header data. The canonical codebook
is also the cheaper table to validate on load.

**Caveats.** Encoding only; scientific datasets (`cuSZ`), CUDA.
Decoders are evaluated elsewhere (Rivera et al. 2022).

### Massively parallel ANS decoding on GPUs (Weißenberger and Schmidt, ICPP 2019)

| Field        | Value                              |
| ------------ | ---------------------------------- |
| Authors      | André Weißenberger, Bertil Schmidt |
| Venue/Year   | ICPP 2019                          |
| DOI or arXiv | [10.1145/3337821.3337888][weiss19] |
| Local PDF    | no open PDF                        |
| Open access  | N                                  |

**Claim.** It extends the overflow (self-synchronization) pattern to tANS
decoding, so an unmodified ANS stream decodes with arbitrary GPU parallelism
rather than the fixed number of interleaved states chosen at encode time.

**Verbatim quote:** not verified (no open PDF).

**Relevance to sparkles.** ANS is the entropy coder of JPEG XL, `zstd` and many
newer image codecs; this shows that decode-side parallelism does not have to be
fixed by the encoder, at the cost of speculative work.

**Caveats.** Claims and speedups here come from the abstract only; code at
[`multians`][multians]. Synchronization of tANS states is probabilistic in the
same way as Huffman's.

### Recoil: parallel rANS decoding with decoder-adaptive scalability (Lin et al., ICPP 2023)

| Field        | Value                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------ |
| Authors      | Fangzheng Lin, Kasidis Arunruangsirilert, Heming Sun, Jiro Katto                                 |
| Venue/Year   | ICPP 2023, pp. 31–40                                                                             |
| DOI or arXiv | [10.1145/3605573.3605588][recoil-doi]; [arXiv:2306.12141][recoil-arxiv]                          |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/lin2023-recoil-parallel-rans-decoding.pdf` |
| Open access  | Y                                                                                                |

**Claim.** Instead of encoding independent partitions (whose overhead is paid
even by a decoder that cannot use the parallelism), Recoil encodes one rANS
stream and stores intermediate decoder states and symbol indices at split
points as metadata. A decoder with less parallelism simply drops entries.

**Verbatim quote** (p. 1):

> We discover that a single rANS-encoded bitstream can be decoded from any
> arbitrary position if the intermediate states are known.

**Relevance to sparkles.** This is the cleanest pattern for a `sparkles`-owned
container that must serve a phone CPU and a desktop GPU from one file: the
entry point table is optional side data, and the serial stream remains valid
without it. The metadata is also trivially checkable (monotone offsets, state
bounds) by a `wired` verifier before any thread starts.

**Caveats.** rANS only; it assumes control of the encoder, so it does not help
with existing JPEG or PNG files.

### Massively-parallel lossless data decompression: Gompresso (Sitaridi et al., ICPP 2016)

| Field        | Value                                                                                                             |
| ------------ | ----------------------------------------------------------------------------------------------------------------- |
| Authors      | Evangelia Sitaridi, Rene Mueller, Tim Kaldewey, Guy Lohman, Kenneth A. Ross                                       |
| Venue/Year   | ICPP 2016, pp. 242–247                                                                                            |
| DOI or arXiv | [10.1109/ICPP.2016.35][sitaridi-doi]; [arXiv:1606.00519][sitaridi-arxiv]                                          |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/sitaridi2016-massively-parallel-lossless-decompression.pdf` |
| Open access  | Y                                                                                                                 |

**Claim.** It parallelizes Inflate-like decompression within a block on GPUs by
splitting each block into sub-blocks whose bit sizes are recorded in the
header, decoding Huffman tokens per thread, and resolving LZ77 back-references
cooperatively within a warp. A variant forbids nested back-references at
compression time to remove dependency chains.

**Verbatim quote** (p. 3):

> more sub-blocks per block increases parallelism and hence performance, but
> diminishes sub-block size and hence compression ratio.

**Relevance to sparkles.** Gompresso is GDeflate's academic ancestor: both
move parallelism into the format, and both pay a small ratio cost. It also
isolates the second serial dependency — LZ77 copies — that a GPU DEFLATE
decoder must handle after entropy decoding.

**Caveats.** Kepler-era GPU (Tesla K40); not DEFLATE-compatible; the comparison
is against CPU libraries of 2016.

### CODAG: characterizing and optimizing decompression algorithms for GPUs (Park et al., 2023)

| Field        | Value                                                                                                                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jeongmin Park, Zaid Qureshi, Vikram Sharma Mailthody, Andrew Gacek, Shunfan Shao, Mohammad AlMasri, Isaac Gelado, Jinjun Xiong, Chris J. Newburn, I-hsin Chung, Michael Garland, Nikolay Sakharnykh, Wen-mei Hwu |
| Venue/Year   | arXiv preprint, 2023                                                                                                                                                                                             |
| DOI or arXiv | [arXiv:2307.03760][codag]                                                                                                                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/park2023-codag-decompression-gpus.pdf`                                                                                                                     |
| Open access  | Y                                                                                                                                                                                                                |

**Claim.** Profiling the `RAPIDS` GPU decompressor shows that its design — one
compressed chunk per thread block, a single leader thread decoding, the rest
of the block writing, plus a dedicated prefetching warp — leaves most threads
waiting on the leader, exposing synchronization and compute latency rather
than saturating memory. CODAG assigns one chunk per warp instead, drops the
specialized warps, keeps reads and writes coalesced, and offers the decoding
primitives as a framework into which new codecs plug. On an A100 it reports
13.46×, 5.69× and 1.18× over `RAPIDS` for `ORC` RLE v1, RLE v2 and Deflate.

**Verbatim quote** (p. 4):

> For Deflate, unlike the traditional view that it is memory bandwidth bound
> [1], [13], our profiling results in Figure 3 show that its memory bandwidth
> utilization is less than 25%, which indicates that it is not limited by
> memory bandwidth but is compute limited.

**Relevance to sparkles.** For a `sparkles:shaders` DEFLATE or GDeflate
decoder the lesson is architectural: map one independently decodable chunk to
one subgroup and keep many chunks in flight, rather than one chunk per
workgroup with a serial leader. Its split between codec-specific decode steps
and shared scheduling, reading and writing is the shape a D compute-decoder
interface can take.

**Caveats.** CUDA on A100 only; the DEFLATE gain over `RAPIDS` is just 1.18×,
the large gains are on run-length codes. It relies on formats that index many
independently decodable chunks (`ORC`), so it does not parallelize a single
DEFLATE stream.

### Parallel decompression of gzip-compressed files (Kerbiriou and Chikhi, HiCOMB 2019)

| Field        | Value                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------- |
| Authors      | Maël Kerbiriou, Rayan Chikhi                                                                               |
| Venue/Year   | HiCOMB 2019 (IPDPS Workshops), pp. 209–217                                                                 |
| DOI or arXiv | [10.1109/IPDPSW.2019.00042][pugz-doi]; [arXiv:1905.07224][pugz-arxiv]                                      |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/kerbiriou2019-parallel-decompression-gzip-files.pdf` |
| Open access  | Y                                                                                                          |

**Claim.** `pugz` decompresses an arbitrary-position chunk of a gzip stream by
guessing a DEFLATE block start and decoding with an unknown 32 KiB window
(placeholder "undetermined" characters), then resolving placeholders once the
preceding chunk's output is known.

**Verbatim quote** (p. 1):

> Decompressing a file made by the gzip program at an arbitrary location is in
> principle impossible, due to the nature of the DEFLATE compression algorithm.

**Relevance to sparkles.** The two-pass, placeholder-window technique is the
answer for decompressing _existing_ large DEFLATE streams (PNG `IDAT`, zlib in
TIFF) in parallel without format changes.

**Caveats.** Restricted to ASCII files: one of the checks that rejects false
block starts is that a decompressed block may only contain valid ASCII
characters, and the authors note binary files would need more careful
block-boundary detection. It does not apply to binary image data as is.

### Rapidgzip: parallel decompression and seeking in gzip files (Knespel and Brunst, HPDC 2023)

| Field        | Value                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Authors      | Maximilian Knespel, Holger Brunst                                                                       |
| Venue/Year   | HPDC '23, Orlando, 2023, pp. 295–307                                                                    |
| DOI or arXiv | [10.1145/3588195.3592992][rapidgzip-doi]; [arXiv:2308.08955][rapidgzip-arxiv]                           |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/knespel2023-rapidgzip-parallel-decompression.pdf` |
| Open access  | Y                                                                                                       |

**Claim.** It generalizes `pugz` to arbitrary data with a cache and a parallel
prefetcher that tolerate false-positive block starts by trial and error,
reaching 8.7 GB/s on 128 cores, and builds a seek index as a side effect.

**Verbatim quote** (p. 2):

> False positives for Deflate blocks cannot be prevented without knowing the
> preceding Deflate stream.

**Relevance to sparkles.** For speculative decoding of formats `sparkles` does
not control, a speculative chunk must be cheap to discard and must never be
trusted until confirmed — the same contract a checked parser offers. The
on-the-fly index is a cheap way to make later random access into large PNGs
or zlib TIFF strips fast.

**Caveats.** CPU-only; the trial-and-error search costs grow with
small DEFLATE blocks; GPU applicability is unexplored.

### Dynamic partitioning-based JPEG decompression on heterogeneous multicores (Sodsong et al., PMAM 2014)

| Field        | Value                                                                                                                         |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Wasuwee Sodsong, Jingun Hong, Seongwook Chung, Yeongkyu Lim, Shin-Dug Kim, Bernd Burgstaller                                  |
| Venue/Year   | PMAM '14, 2014, pp. 80–91; extended in Concurrency and Computation: Practice and Experience ([10.1002/cpe.3620][sodsong-cpe]) |
| DOI or arXiv | [10.1145/2560683.2560684][sodsong-doi]; [arXiv:1311.5304][sodsong-arxiv]                                                      |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/sodsong2014-dynamic-partitioning-jpeg-decompression.pdf`                |
| Open access  | Y                                                                                                                             |

**Claim.** Built on `libjpeg-turbo`, it keeps Huffman decoding on the CPU and
splits IDCT, upsampling and colour conversion between CPU and an OpenCL GPU
using a profiled performance model of image size and entropy; up to 4.2× over
SIMD `libjpeg-turbo` in the arXiv version.

**Verbatim quote** (p. 1):

> Our runtime partitioning and scheduling scheme exploits task, data and
> pipeline parallelism by scheduling the non-parallelizable entropy decoding
> task on the CPU, whereas inverse cosine transformations (IDCTs), color
> conversions and upsampling are conducted on both the CPU and the GPU.

**Relevance to sparkles.** It is the reference for the hybrid split that
`nvJPEG`'s non-hardware backend also uses, and it shows the split must be
chosen per image (small images never pay for the GPU). A `sparkles` scheduler
needs a cheap per-device calibration, not a fixed rule.

**Caveats.** Treats entropy decoding as non-parallelizable, which later work
disproved; 2013 GPUs; journal and arXiv versions report different speedups.
Sodsong's later JParEnt work (PMAM '16, CPE 2017) moved entropy decoding to the
integrated GPU and is not covered here.

### Accelerating JPEG decompression on GPUs (Weißenberger and Schmidt, HiPC 2021)

| Field        | Value                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------ |
| Authors      | André Weißenberger, Bertil Schmidt                                                                           |
| Venue/Year   | HiPC 2021, pp. 121–130                                                                                       |
| DOI or arXiv | [10.1109/HiPC53243.2021.00026][weiss21-doi]; [arXiv:2111.09219][weiss21-arxiv]                               |
| Local PDF    | `~/code/repos/papers/image-video/gpu-decode-streaming/weissenberger2021-accelerating-jpeg-decompression.pdf` |
| Open access  | Y                                                                                                            |

**Claim.** It applies the self-synchronizing overflow pattern to JPEG
entropy decoding, making the whole decoder GPU-resident. It reports up to 51×
over `libjpeg-turbo` and 8.0× over `nvJPEG` on an A100, and up to 3.4× over the
A100's hardware JPEG engine; the bottleneck moves to IDCT and dequantization.

**Verbatim quote** (p. 2):

> GPUJPEG [6] takes advantage of restart markers that allow for fast parallel
> decoding. Unfortunately, these markers are not used in JPEG-encoded images
> by most libraries and cameras, which limits the use cases of this approach.

**Relevance to sparkles.** A `sparkles` JPEG decoder should use restart
markers when present (cheap, exact) and fall back to self-synchronizing
speculation when absent; only the second path needs a synchronization budget.
Moving the whole pipeline to the GPU also means uploading compressed bytes
only, which matters more than kernel speed when PCIe is the bottleneck.

**Caveats.** CUDA-only and, in its own words, implements "an important subset"
of the JPEG standard; check which modes before relying on it. Batch-oriented
benchmarks.

### `nvJPEG` and the A100 hardware JPEG decoder (NVIDIA Technical Blog, web)

| Field        | Value                                          |
| ------------ | ---------------------------------------------- |
| Authors      | Mahesh Khadatare, Zoheb Khan, Harun Bayraktar  |
| Venue/Year   | [NVIDIA Technical Blog][nvjpeg], June 15, 2020 |
| DOI or arXiv | none                                           |
| Local PDF    | web source                                     |
| Open access  | Y                                              |

**Claim.** `nvJPEG` offers a hybrid CPU+GPU backend on all NVIDIA GPUs and a
hardware backend on the A100's five-core JPEG engine, which decodes baseline
JPEG in batches while the SMs do other work.

**Verbatim quote** (page text):

> Previously, there was no such hardware unit on datacenter GPUs, and JPEG
> decoding was a pure software CUDA solution that used both CPU and GPU.

**Relevance to sparkles.** It confirms the three-backend pattern (CPU, hybrid,
fixed-function) that a `sparkles` decoder interface should expose behind one
batch API, and that fixed-function units cover only the baseline profile.

**Caveats.** Vendor marketing numbers; CUDA-only; hardware path limited to
baseline JPEG on specific GPUs.

### Vulkan Video decode (Khronos blog and registry)

| Field        | Value                                                                                                                                                                                                                           |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Khronos Vulkan Working Group                                                                                                                                                                                                    |
| Venue/Year   | [An Introduction to Vulkan Video][vk-video] (April 13, 2021, provisional); registry pages for [`VK_KHR_video_decode_queue`][vk-decode], [`VK_KHR_video_decode_av1`][vk-av1], [`VK_KHR_video_decode_vp9`][vk-vp9] (all ratified) |
| DOI or arXiv | none                                                                                                                                                                                                                            |
| Local PDF    | web source                                                                                                                                                                                                                      |
| Open access  | Y                                                                                                                                                                                                                               |

**Claim.** Vulkan Video exposes fixed-function decode engines as queues: the
application parses the bitstream, creates session parameters from parameter
sets (SPS/PPS and their analogues), manages the decoded picture buffer as
ordinary `VkImage`s, and records `vkCmdDecodeVideoKHR` per picture. The
2021 provisional release covered H.264 decode and encode and H.265 decode;
AV1 and VP9 decode are now ratified KHR extensions.

**Verbatim quote** (blog page text):

> Video decode hardware acceleration is typically needed only for the
> bitstream segments related to images/pictures or their sub-regions, while
> segments related to parameter sets are designed for simple CPU-based
> decoding or parsing.

**Relevance to sparkles.** The split of labour is explicit: `sparkles:video`
owns container and parameter-set parsing (hostile input, so `wired`-checked),
DPB slot management and synchronization; the driver owns slice decoding.
Decoded images are already `VkImage`s, so colour conversion and display stay
in `sparkles:ui-vulkan` without a copy.

**Caveats.** The blog describes the provisional API (EXT codec extensions,
names since changed to KHR); the registry pages are authoritative. Encode,
AV1 encode and queue-family availability vary by driver.

## Thread synthesis

**Consensus.** Every production system (DirectStorage, Metal 3, GDeflate in
Vulkan, `nvJPEG`, Vulkan Video) puts parallelism into the _format_ or into
fixed-function hardware, and every one keeps a CPU fallback and reports which
path was chosen. Fixed 64 KB chunks recur independently (GDeflate tiles,
Metal's example chunk size, the sparse-resource page size). On the I/O side,
`io_uring` is the right kernel interface, but polling mode decides whether it
approaches `SPDK` or falls far behind it, and the right mode depends on spare
cores. The academic line from Klein and Wiseman through Weißenberger and
Schmidt shows that unmodified Huffman and ANS streams _can_ be decoded in
parallel with speculative, self-synchronizing threads. On the GPU side, chunk
independence is the unit of scheduling everywhere: Tian et al. chunk at encode
time to make decoding possible, and CODAG gets its gains by putting many such
chunks in flight at once.

**Disagreements.** Whether to change the format: Gompresso, GDeflate, gap
arrays and Recoil add side data or reorder bits; the self-synchronization line
and `pugz`/Rapidgzip keep compatibility and pay speculative work. Where the
CPU belongs: Sodsong et al. keep entropy decoding on the CPU, Weißenberger and
Schmidt move everything to the GPU, and the 2020 `nvJPEG` hardware engine was
reportedly beaten by the 2021 software decoder on the same A100. Whether GPU
decompression is memory-bound: `RAPIDS` dedicates warps to prefetching on that
assumption, CODAG measures DEFLATE at under 25% of memory bandwidth and calls
it compute- and synchronization-latency bound, while Rivera et al. still win
by staging through shared memory — the answer depends on codec and kernel
design. Didona et al. and Ren and Trivedi disagree on how close `io_uring`
gets to `SPDK`, largely because of different devices and load levels. And
whether `io_uring` helps at all: Haas and Leis find it the only kernel path
that saturates an NVMe array, but Jasny et al. measure a drop-in swap as a
wash (1.06×) and find polling worse when I/O is sporadic, and Pestka et al.
argue the restructuring it demands is the real cost.

**Open problems.** Bounds on synchronization distance for adversarial
streams (a crafted affix-like code defeats the speculation); none of the GPU
decoders here is evaluated end to end on hostile or malformed input.
Reported speedups are not comparable: each is against a different baseline
(`cuSZ`'s decoder, `RAPIDS`, `libjpeg-turbo`, `nvJPEG`, CPU libraries of its
era) on a different GPU, and none is measured from storage to a displayed
texture. Portable cancellation and priority for GPU-side decompression (Metal
has them, the Vulkan extension does not); a vendor-neutral GPU decompression
format beyond GDeflate; and parallel LZ77 back-reference resolution across
chunks without a format change on GPUs.

**What a D implementation should take from this**

- Make chunked, independently decodable units (64 KiB) the native unit of the
  `sparkles` asset container, and store per-chunk offsets and exact
  decompressed sizes as `wired`-verified metadata before any decode starts.
- Model decompression as a capability with three implementations — fixed
  function (`VK_EXT_memory_decompression`, Vulkan Video, vendor engines),
  compute shader, CPU — selected by introspection and by the request's
  destination, and expose which one ran.
- Prefer GDeflate for GPU-bound assets: one bitstream serves the D CPU
  decoder, a `sparkles:shaders` compute decoder and the Vulkan extension.
- In the compute decoder, give each chunk to one subgroup and keep many chunks
  in flight (CODAG), rather than one chunk per workgroup behind a serial
  leader thread; keep codec-specific decode steps separate from the shared
  read, write and scheduling code.
- For existing formats (baseline JPEG, PNG `IDAT`), use exact split points
  when the file provides them (restart markers, flush points) and fall back to
  self-synchronizing speculation with an explicit bit budget, after which the
  decoder goes sequential — never an unbounded retry.
- Drive reads through `event-horizon`'s `io_uring` ring with fixed buffers
  that double as upload staging; make `SQPOLL`/`IOPOLL` opt-in and detected,
  never assumed, and keep a polled storage ring separate from socket I/O.
- Design the loader around `io_uring` rather than swapping it in: bound the
  requests in flight, apply backpressure when the submission queue or the
  decode queue is full, and keep heavy decode work off a polling thread
  (Jasny et al., Pestka et al.).
- Batch decode work and let threads or waves steal tiles; size the staging
  arena so a batch is large enough to hide the tail (DirectStorage recommends
  about 128 MiB).
- Carry cancellation and priority from the UI down to queued reads and decode
  batches, following Metal's command-buffer granularity.
- Keep parameter-set and container parsing on the CPU even when Vulkan Video
  does the decode; that is where hostile-input checks belong.
- Benchmark end to end, from file to uploaded image, against a stated
  baseline; a kernel-only speedup does not answer the design question.

## Sources

- Papers: [Axboe 2019][axboe-pdf], [Didona et al. 2022][didona],
  [Ren and Trivedi 2023][ren], [Haas and Leis 2023][haas],
  [Pestka et al. 2024][pestka], [Jasny et al. 2026][jasny],
  [Qureshi et al. 2023][bam-doi], [Klein and Wiseman 2003][klein],
  [Weißenberger and Schmidt 2018][weiss18], [Rivera et al. 2022][rivera-doi],
  [Yamamoto et al. 2020][yamamoto], [Tian et al. 2021][tian-doi],
  [Weißenberger and Schmidt 2019][weiss19], [Lin et al. 2023][recoil-doi],
  [Sitaridi et al. 2016][sitaridi-doi], [Park et al. 2023][codag],
  [Kerbiriou and Chikhi 2019][pugz-doi], [Knespel and Brunst 2023][rapidgzip-doi],
  [Sodsong et al. 2014][sodsong-doi], [Weißenberger and Schmidt 2021][weiss21-doi].
- Vendor and standards pages: [GPUDirect Storage design guide][gds],
  [DirectStorage 1.1][ds11], [DirectStorage 1.2][ds12],
  [GDeflate blog][gdeflate-blog], [GDeflate reference README][gdeflate-spec],
  [`VK_EXT_memory_decompression`][vk-ext], [`VK_NV_memory_decompression`][vk-nv],
  [Metal 3 fast resource loading][metal], [`nvJPEG` on A100][nvjpeg],
  [Vulkan Video introduction][vk-video], [`VK_KHR_video_decode_queue`][vk-decode],
  [`VK_KHR_video_decode_av1`][vk-av1], [`VK_KHR_video_decode_vp9`][vk-vp9].
- Code: [`gpuhd`][gpuhd], [`multians`][multians].

<!-- References -->

[axboe-pdf]: https://kernel.dk/io_uring.pdf
[didona]: https://doi.org/10.1145/3534056.3534945
[ren]: https://doi.org/10.1145/3578353.3589545
[haas]: https://doi.org/10.14778/3598581.3598584
[pestka]: https://arxiv.org/abs/2411.16254
[jasny]: https://doi.org/10.14778/3819518.3819553
[bam-doi]: https://doi.org/10.1145/3575693.3575748
[bam-arxiv]: https://arxiv.org/abs/2203.04910
[gds]: https://docs.nvidia.com/gpudirect-storage/design-guide/index.html
[ds11]: https://devblogs.microsoft.com/directx/directstorage-1-1-now-available/
[ds12]: https://devblogs.microsoft.com/directx/directstorage-1-2-available-now/
[gdeflate-blog]: https://developer.nvidia.com/blog/accelerating-load-times-for-directx-games-and-apps-with-gdeflate-for-directstorage/
[gdeflate-spec]: https://github.com/microsoft/DirectStorage/blob/32f9411bccab60cec8d7054edbf186219d9bfdf2/GDeflate/GDeflate/README.md
[vk-ext]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_memory_decompression.html
[vk-nv]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_NV_memory_decompression.html
[metal]: https://developer.apple.com/videos/play/wwdc2022/10104/
[klein]: https://doi.org/10.1093/comjnl/46.5.487
[weiss18]: https://doi.org/10.1145/3225058.3225076
[gpuhd]: https://github.com/weissenberger/gpuhd/tree/6f2cd2071e025713c6bee091470aeba19fe02d2c
[rivera-doi]: https://doi.org/10.1109/IPDPS53621.2022.00075
[rivera-arxiv]: https://arxiv.org/abs/2201.09118
[yamamoto]: https://doi.org/10.1145/3404397.3404429
[tian-doi]: https://doi.org/10.1109/IPDPS49936.2021.00097
[tian-arxiv]: https://arxiv.org/abs/2010.10039
[weiss19]: https://doi.org/10.1145/3337821.3337888
[multians]: https://github.com/weissenberger/multians/tree/55515d8df486d726c79fdb09f0c16837041e3433
[recoil-doi]: https://doi.org/10.1145/3605573.3605588
[recoil-arxiv]: https://arxiv.org/abs/2306.12141
[sitaridi-doi]: https://doi.org/10.1109/ICPP.2016.35
[sitaridi-arxiv]: https://arxiv.org/abs/1606.00519
[codag]: https://arxiv.org/abs/2307.03760
[pugz-doi]: https://doi.org/10.1109/IPDPSW.2019.00042
[pugz-arxiv]: https://arxiv.org/abs/1905.07224
[rapidgzip-doi]: https://doi.org/10.1145/3588195.3592992
[rapidgzip-arxiv]: https://arxiv.org/abs/2308.08955
[sodsong-doi]: https://doi.org/10.1145/2560683.2560684
[sodsong-arxiv]: https://arxiv.org/abs/1311.5304
[sodsong-cpe]: https://doi.org/10.1002/cpe.3620
[weiss21-doi]: https://doi.org/10.1109/HiPC53243.2021.00026
[weiss21-arxiv]: https://arxiv.org/abs/2111.09219
[nvjpeg]: https://developer.nvidia.com/blog/leveraging-hardware-jpeg-decoder-and-nvjpeg-on-a100/
[vk-video]: https://www.khronos.org/blog/an-introduction-to-vulkan-video
[vk-decode]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_video_decode_queue.html
[vk-av1]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_video_decode_av1.html
[vk-vp9]: https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_video_decode_vp9.html
