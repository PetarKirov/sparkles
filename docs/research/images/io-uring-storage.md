# io_uring storage-to-GPU on Linux (C kernel interface)

What Linux offers for getting file bytes into memory a Vulkan device reads (registered buffers,
fixed files, `O_DIRECT`, `IOPOLL`, host-pointer and dma-buf imports), read from the kernel
documentation and the liburing man pages, checked against Sparkles' vendored binding and
measured on this machine.

| Field         | Value                                                                                                                                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (kernel UAPI, liburing); D binding `sparkles.event_horizon.sys.uring` (vendored `during` 0.6.0)                                                                                                                 |
| License       | Kernel GPL-2.0 (UAPI headers GPL-2.0 WITH Linux-syscall-note); liburing LGPL and MIT, man pages LGPL-2.0-or-later; man-pages project for `open(2)` and `statx(2)`; the binding BSL-1.0                            |
| Repository    | [torvalds/linux][linux-repo] · [axboe/liburing][liburing-repo] · [man-pages][man7] · binding: [`libs/event-horizon-sys`][binding]                                                                                 |
| Revision read | Linux `a90ee4305c4a5df72c11b31dacfdc76e00fcf78a` (7.3-rc6), plus `v6.18` = `7d0a66e4bb9081d75c82ec4957c50034cb0ea449` for the running kernel; liburing `78dce99b660fd1caaf70ef6573a88bae9bbf6476`; man-pages 6.16 |
| Documentation | [`io_uring_register(2)`][reg-bufs], [`io_uring_setup(2)`][setup-iopoll], [`open(2)`][open2], [`statx(2)`][statx2], [dma-buf][dmabuf-doc], [dma-buf heaps][heaps-doc]                                              |
| Category      | GPU and I/O: storage reads, pinned memory, external memory import                                                                                                                                                 |
| Tier          | B                                                                                                                                                                                                                 |
| Last reviewed | November 7, 2026                                                                                                                                                                                                  |

> [!NOTE]
> **Measured here** means a program run on November 14, 2026 on the [hardware matrix][hw]'s
> Vega 56 host: Linux 6.18.26, OpenZFS 2.4.1 (`/tmp` on a single-vdev pool on a Lexar NM790, PCIe 4.0 x4,
> `recordsize=128K`, `lz4`, `direct=standard`, `zfs_dio_strict=0`), RADV from Mesa 25.2.6, a
> load average between 20 and 30 from other work. Two throwaway programs in a scratch directory
> under `/tmp`, not committed: a D program on the repo's binding (`dub run --single`, `-b checked`)
> and a C program against `liburing` 2.12 and `vulkan-headers` 1.4.328 from `nix-shell`.
> Everything else is **documented**. No filesystem here is a plain block-device filesystem
> (ext4, XFS), so the classic `O_DIRECT` `EINVAL` behaviour is documented only.

---

## Overview

### What it solves

A decoder needs compressed bytes in memory; an uploader needs decoded or GPU-compressed
bytes in memory the GPU can copy from ([staging][c-staging]). Linux gives three independent
levers on that path. `io_uring` registered buffers pin a range once so each read skips page
pinning; registered (fixed) files skip the per-request descriptor lookup; `O_DIRECT` moves
data between the device and user memory without the page cache. On the GPU side, Vulkan can
adopt memory the application already owns, either a host pointer or a dma-buf
([external memory][c-extmem]; the Vulkan rules are in [Vulkan transfer][vk-import]). This
page asks which of those combine, so that a file read lands in memory a `VkBuffer` is bound to
with no copy between.

### Design philosophy

The kernel interfaces are mechanisms with few guarantees, and their man pages say so. `open(2)`
on direct I/O ([`open.2`][open2]):

> _"In Linux alignment restrictions vary by filesystem and kernel version and might be absent
> entirely. The handling of misaligned `O_DIRECT` I/Os also varies; they can either fail with
> `EINVAL` or fall back to buffered I/O."_

`io_uring_register(2)` on what may be registered ([`io_uring_register.2`][reg-bufs]):

> _"The buffers associated with the iovecs will be locked in memory and charged against the
> user's `RLIMIT_MEMLOCK` resource limit. [...] Currently, the buffers must be anonymous,
> non-file-backed memory, such as that returned by `malloc(3)` or `mmap(2)` with the
> `MAP_ANONYMOUS` flag set."_

Both rules decide the storage-to-GPU seam: memory a GPU driver maps for you is not anonymous,
and direct-I/O alignment is a per-file query, not a constant.

## How it works

### Registered buffers and fixed files

`IORING_REGISTER_BUFFERS` takes an `iovec` array; a later `IORING_OP_READ_FIXED` names one entry
by `buf_index` and must stay inside it. The kernel pins the range long-term
(`pin_user_pages_fast` with `FOLL_WRITE | FOLL_LONGTERM`, [`io_uring/memmap.c`][memmap-pin]),
and a partial pin becomes `EFAULT`. The per-buffer size cap moved: the running 6.18 kernel
rejects a buffer over 1 GiB with `EFAULT` ([`v6.18 io_uring/rsrc.c`][rsrc-618]), and 7.3-rc6
caps at 1 TiB with `EINVAL` ([`io_uring/rsrc.c`][rsrc-73]); the liburing man page still
documents "`iov_len` is greater than 1GiB" under `EFAULT` ([`io_uring_register.2`][reg-efault]).

**Measured here** (6.18, 1 MiB each unless stated): `MAP_ANONYMOUS` registers; a memfd
`MAP_SHARED` mapping (shmem) registers; a `MAP_SHARED` mapping of a ZFS file fails with `EFAULT`;
a `MAP_PRIVATE` mapping of the same file registers; one 2 GiB anonymous `iovec` fails with
`EFAULT` and one 1 GiB `iovec` registers.

```c
/* Linux 7.3-rc6, io_uring/rsrc.c */
    /* cap to 1TB for 64-bit */
    if (ulen > SZ_1T)
        return -EINVAL;
```

`IORING_REGISTER_FILES` installs a descriptor table; an SQE with `IOSQE_FIXED_FILE` puts the
table index in `fd` ([`io_uring_register.2`][reg-files]). Direct descriptors (`OPENAT` into a
slot, `FIXED_FD_INSTALL`) extend the idea; the [async-io catalog][aio-fixed] covers them.

### `O_DIRECT` and `STATX_DIOALIGN`

Since Linux 6.1, `statx(2)` with `STATX_DIOALIGN` returns `stx_dio_mem_align` (buffer address)
and `stx_dio_offset_align` (file offset and length), or zero for "not supported"; ext4, f2fs and
XFS report it, other filesystems vary ([`statx.2`][statx2]). XFS adds a read-only offset
alignment no larger than that one, `stx_dio_read_offset_align` (`STATX_DIO_READ_ALIGN`), from 6.14. Block devices allow
`dma_alignment + 1` bytes for memory: this host's NVMe queues report `dma_alignment` 3 and a
512-byte logical block in `/sys/block/*/queue`.

**Measured here**, `statx(STATX_DIOALIGN)`:

| File              | `stx_dio_mem_align` | `stx_dio_offset_align`  | Misaligned `O_DIRECT` reads (buffer +1, offset 1, length 1000) |
| ----------------- | ------------------- | ----------------------- | -------------------------------------------------------------- |
| ZFS, `/tmp`       | 4096                | 131072 (the recordsize) | all succeeded                                                  |
| tmpfs, `/dev/shm` | 0 (mask bit unset)  | 0                       | all succeeded                                                  |

ZFS reports a 128 KiB offset alignment and then serves misaligned requests anyway (its
`zfs_dio_strict` is 0 here); tmpfs accepts the flag without reporting support. A reader that
trusts "it worked" learns nothing about the alignment a different filesystem enforces.

### `IOPOLL`

`IORING_SETUP_IOPOLL` busy-polls for completions instead of taking an interrupt. It needs
`O_DIRECT` and a device configured for polling; for NVMe "the nvme driver must be loaded with
the `poll_queues` parameter set" ([`io_uring_setup.2`][setup-iopoll]). The kernel check is
one line ([`io_uring/rw.c`][rw-iopoll]):

```c
    if (ctx->flags & IORING_SETUP_IOPOLL) {
        if (!(kiocb->ki_flags & IOCB_DIRECT) || !file->f_op->iopoll)
            return -EOPNOTSUPP;
```

**Measured here:** an `IOPOLL` ring returned `EOPNOTSUPP` for direct and buffered reads on both
ZFS and tmpfs; `/sys/module/nvme/parameters/poll_queues` is 0 and `io_poll` is 0 on both
drives. `IOPOLL` is a deployment property, not something a library can assume.

### Memory a GPU can see

Three routes put file bytes in memory a `VkBuffer` uses:

1. **Read into driver-mapped memory** (`vkMapMemory`). The pointer comes from an `mmap` of the
   DRM device file, which is neither anonymous nor long-term pinnable.
2. **Read into a page-aligned host allocation, then import it** with
   `VK_EXT_external_memory_host` (`VkImportMemoryHostPointerInfoEXT`; pointer and size multiples
   of `minImportedHostPointerAlignment`, lifetime the application's, see
   [Vulkan transfer][vk-import]).
3. **Read into a memfd, export it as a dma-buf** with `/dev/udmabuf`, and import that with
   `VK_EXT_external_memory_dma_buf`. `udmabuf` takes only shmem or hugetlbfs memfds sealed
   against shrinking and not sealed against writes ([`drivers/dma-buf/udmabuf.c`][udmabuf-seals]):

```c
#define SEALS_WANTED (F_SEAL_SHRINK)
#define SEALS_DENIED (F_SEAL_WRITE|F_SEAL_FUTURE_WRITE)
```

dma-buf heaps (`/dev/dma_heap/system`, "virtually contiguous, cacheable, buffers") are the other
user-space dma-buf allocator ([`dma-buf-heaps.rst`][heaps-doc]); this host has no
`/dev/dma_heap`. CPU access to an `mmap`ed dma-buf is bracketed by `DMA_BUF_IOCTL_SYNC`, which
"can fail with -EAGAIN or -EINTR, in which case it must be restarted" ([`dma-buf.c`][dmabuf-cpu]);
the probe below wrote through the memfd mapping and issued no sync ioctl.

The only dma-buf path inside io_uring at 7.3-rc6 is network receive: zero-copy RX accepts an
area flagged `IORING_ZCRX_AREA_DMABUF` with a `dmabuf_fd` ([`zcrx.h`][zcrx-uapi]). No storage
opcode reads into a dma-buf, and `IORING_REGISTER_BUFFERS` takes user addresses only.

**Measured here** (C probe, 4 MiB per route, file on ZFS; each GPU check runs `vkCmdCopyBuffer`
from the imported buffer and compares against the file):

| Route                                                  | RX Vega 56, Radeon 610M (RADV)                               | llvmpipe                     |
| ------------------------------------------------------ | ------------------------------------------------------------ | ---------------------------- |
| 1. `vkMapMemory`, `HOST_VISIBLE \| HOST_COHERENT`      | register: `EFAULT`; plain `READ` ok                          | register ok; `READ_FIXED` ok |
| 1. `vkMapMemory`, `DEVICE_LOCAL \| HOST_VISIBLE` (BAR) | register: `EFAULT`; plain `READ` ok                          | register ok; `READ_FIXED` ok |
| 2. `posix_memalign(4096)` + host-pointer import        | `READ_FIXED` ok; import ok; GPU copy matches (types `0x20`)  | same (type `0x1`)            |
| 3. memfd + `UDMABUF_CREATE` + dma-buf import           | `READ_FIXED` ok; import ok; GPU copy matches (types `0x420`) | same (type `0x1`)            |

All three devices report `minImportedHostPointerAlignment` 4096. `O_DIRECT` `pread` into the
route-1 mappings succeeded too, but on ZFS that proves nothing about a block-device filesystem
(see above). `vkGetMemoryHostPointerPropertiesEXT` on a pointer 64 bytes past the aligned one
returned `VK_SUCCESS` on RADV: the alignment rule is valid usage, which only the validation
layers check.

### What the binding and event-horizon provide

The [event-horizon baseline][bl-eh] lists the shipped pieces: `BufferPool.register` pins a slab
as one `iovec` per slot, and the backend lowers `OpRead` on a registered `Buf` to `READ_FIXED`.
`BackendCaps.registeredFiles` is set but nothing registers files; there is no `O_DIRECT`, no
`IOPOLL`, no `STATX_DIOALIGN` query and no Vulkan import. The vendored binding exposes all of
the kernel side: `registerBuffers`, `registerFiles` and `registerFilesUpdate`
([`package.d`][binding-pkg]), `SetupFlags.IOPOLL` ([`io_uring.d`][binding-io]), and
`prepReadFixed`.

One defect matters for the pool. The `ubyte[][]` overload of `Uring.registerBuffers` fills an
`iovec` per buffer and then passes `nr_args` 1 ([`package.d` lines 661-665][binding-pkg]):

```d
        immutable r = io_uring_register(
                payload.fd,
                RegisterOpCode.REGISTER_BUFFERS,
                cast(const(void)*)payload.regBuffers.ptr, 1
            );
```

Upstream `during` at the vendored commit has the same line. **Measured here:** registering two
4 KiB buffers through that overload returned 0; `READ_FIXED` with `buf_index` 0 read 4096
bytes and with `buf_index` 1 failed with `EFAULT`. `BufferPool.register` passes one slice per
slot, so every slot but the first is unregistered while `Buf.origin` says `registered`. The
existing test `loop.registeredBuffers.fixedReadPath` creates a two-slot pool and reads into the
first slot acquired, which is slot 0 (`pop order: 0, 1, 2, …` in `buffer.d`), so it passes.

## Analysis

### 1. Pixel and memory model

Direct I/O and registration both constrain _where_ a buffer lives, not its layout: page-aligned
start, size a multiple of `stx_dio_offset_align` (which can be 128 KiB on ZFS), and
`minImportedHostPointerAlignment` for a Vulkan import. A pixel or byte buffer that is to be read
into and then imported needs an allocator that can promise all three at once, and a size
rounded up past the image's last row. The [stride][c-stride] of the decoded image is unaffected;
the slab around it is.

### 4. I/O and codec architecture

The useful unit is a bounded set of in-flight reads into fixed slots, which is a scheduling
shape the codec does not see if it consumes byte slices (the baseline's gap G1). The
measurements below show that on this host the choice between `READ` and `READ_FIXED`, or plain
and fixed files, did not change throughput beyond run-to-run noise, while block size changed it
by two orders of magnitude.

**Measured here**, D program on the binding, a 2 GiB file of random bytes on ZFS, one ring,
reads issued back to back at the stated queue depth; MiB/s, median of five, run 1 / run 2:

| Block, depth | Mode       | `READ`, fd    | `READ`, fixed file | `READ_FIXED`, fd | `READ_FIXED`, fixed file |
| ------------ | ---------- | ------------- | ------------------ | ---------------- | ------------------------ |
| 4 KiB, 32    | `O_DIRECT` | 98 / 90       | 98 / 94            | 49 / 85          | 39 / 81                  |
| 4 KiB, 32    | buffered   | 780 / 2710    | 784 / 2917         | 837 / 2637       | 733 / 2651               |
| 128 KiB, 16  | `O_DIRECT` | 1652 / 3609   | 2073 / 3314        | 2933 / 3442      | 3125 / 3418              |
| 128 KiB, 16  | buffered   | 11899 / 13205 | 12045 / 11567      | 11854 / 12051    | 12880 / 12615            |
| 1 MiB, 8     | `O_DIRECT` | 9067 / 9303   | 9064 / 9118        | 9117 / 9208      | 9087 / 9454              |
| 1 MiB, 8     | buffered   | 13454 / 11924 | 13663 / 13497      | 12981 / 13077    | 13226 / 13486            |

What this does and does not show: 4 KiB `O_DIRECT` reads sit below ZFS's 128 KiB offset
alignment and run at about 90 MiB/s; the 1 MiB `O_DIRECT` rate (about 9100 MiB/s) exceeds what
the pool's single PCIe 4.0 x4 link carries (about 7500 MiB/s), so ZFS served part of it from
memory and the rows are not device throughput. The run 1 advantage of `READ_FIXED` at 128 KiB
vanished in run 2. On a loaded host with ZFS in the path, registered buffers and fixed files
were not distinguishable; the baseline's "~1.36x" for a cached 4 KiB read stays the only
in-repo figure, and an ext4 or XFS volume on an idle host is needed before deciding.

A verifier rerun on November 15, 2026 (load average 3 to 4, a C program on `liburing` with
the same block sizes and depths, best of three, not the D program above) agreed in shape:
`O_DIRECT` 4 KiB at 92 to 112 MiB/s, 128 KiB at 5527 to 6195 MiB/s and 1 MiB at 7722 to
8068 MiB/s, with `READ_FIXED` within a few percent of `READ` in every row. The 128 KiB
`O_DIRECT` rate is higher than either run above, so the table's middle rows are load-sensitive.

### 5. Hostile input and safety

The risks are resource ones. Registration pins memory against `RLIMIT_MEMLOCK` (unlimited on this
host), the size cap changed between 7.1 and 7.2, and
`kernel.io_uring_disabled` can remove the ring entirely ([hardware matrix][hw-uring]). A
`VK_EXT_external_memory_host` import need not hold a reference to its pages (the specification
leaves it undefined, see [Vulkan transfer][vk-import]), so freeing or `munmap`ing the allocation
while the `VkDeviceMemory` lives is undefined; the binding defect above
turns a bad `buf_index` into an `EFAULT` completion rather than memory corruption, because the
kernel range-checks it. A file length that is not a multiple of the direct-I/O alignment needs a
buffered tail read or a rounded-up buffer and a short-read check, which is ordinary
[hostile input][c-hostile] hygiene for a truncated file.

### 6. Allocation and ownership

Three owners meet: the io_uring slot (pinned until unregistered, and the event-horizon rule that
a buffer outlives its terminal completion), the Vulkan import (the application keeps the pages
alive for the life of the `VkDeviceMemory`), and, for udmabuf, the memfd and the dma-buf file
descriptor. Route 2 and route 3 let one allocation satisfy all three, so ownership can sit with
one slab type that frees only after the GPU fence and the last CQE. Route 1 cannot be registered
on RADV, so a design that wants `READ_FIXED` cannot start from `vkMapMemory`.

### 8. GPU offload and interop

Route 2 is the simplest zero-copy path that worked on every device measured here: a page-aligned `malloc`-style
slab, registered with io_uring, imported once as a host allocation, bound to a transfer-source
`VkBuffer`, then `vkCmdCopyBufferToImage` from it. Route 3 adds a kernel object but yields a
dma-buf, which is also the currency of VA-API surfaces, cameras and other processes. Neither moves
bytes to device-local memory; that is still a GPU copy, or a CPU write into a BAR mapping that
cannot be registered. True storage-to-VRAM transfers (GPUDirect Storage, BaM, DirectStorage) are
outside what mainline io_uring offers for files; the [storage-to-GPU papers][p-gds] cover them, the [Windows counterpart][ds-ioring] has its own page,
and [`dlpack`][dlpack] covers the tensor-side handoff of the same buffers.

### 10. Testing and conformance

Every behaviour here depends on the filesystem, the module parameters and the driver. The
documentation makes the same misaligned `O_DIRECT` request an error on one filesystem and a
buffered read on another (both filesystems probed here accepted it, whatever they reported), and
the probes show `IOPOLL` unavailable without `poll_queues`. Tests must query
(`STATX_DIOALIGN`, a probe ring with `IOPOLL`, device extensions) and call `skipTest` when the
capability is absent. The binding defect shows a second need: a registration test must exercise
the last slot, not the first.

Not covered: 2, 3, 7, 9.

## Lessons for Sparkles

- **Q6.** The binding's multi-buffer `registerBuffers` registers only the first `iovec`; any
  `BufferPool` with more than one slot currently has unregistered slots marked `registered`.
  This is a precondition for every other registered-buffer measurement.
- **Q6.** A host-pointer import of a page-aligned slab (route 2) gives a file read straight into
  memory Vulkan copies from, on RADV and llvmpipe, with the `BufferPool` slab shape that already
  exists; `vkMapMemory`ed driver memory cannot be registered on RADV and is the wrong source.
- **Q6.** udmabuf (route 3) is the route if the slab must also be a dma-buf for VA-API or another
  process; `/dev/udmabuf` permissions vary (here `root:kvm` plus an ACL), so it is an option, not a
  floor.
- **Q6.** Direct-I/O alignment is a per-file query (`STATX_DIOALIGN`) with filesystems that
  under-report (tmpfs) or over-accept (ZFS); an `O_DIRECT` reader needs the query plus a buffered
  fallback, and the baseline's advice to benchmark before choosing `O_DIRECT` stands.
- **Q6.** `IOPOLL` needs `O_DIRECT` and NVMe poll queues; on default kernels it fails with
  `EOPNOTSUPP`, so it belongs behind a capability flag, not in the default ring.
- **Q8.** Storage benchmarks for this catalog need an idle host and an ext4 or XFS volume; ZFS's
  ARC and fallback rules mask the effects being measured.
- **Q9.** None of this needs the codec: an image core that consumes byte slices stays unaware of
  pinning and import, and the read-into-importable-slab logic belongs with the I/O and GPU
  packages.

## Strengths

- All three zero-copy-into-Vulkan routes worked on this machine's GPUs with mainline interfaces.
- `STATX_DIOALIGN` makes direct-I/O alignment queryable instead of folklore.
- Registration failures are synchronous `-errno` values and bad indices fail per request, so
  capability detection is cheap.
- The vendored binding already exposes every kernel call the design needs.

## Weaknesses

- Behaviour varies by filesystem, kernel version and module parameter; the man page still states
  a 1 GiB limit that 7.2 replaced.
- No mainline io_uring storage path reads into a dma-buf or into device-local memory.
- Driver-mapped Vulkan memory is not registrable; the Vulkan host-pointer alignment rule is not
  checked at run time.
- The binding's `registerBuffers(ubyte[][])` registers one buffer, and the test that covers it
  reads only slot 0.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                              | Trade-off                                                                                  |
| ------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| Registered buffers must be anonymous user memory       | The kernel pins pages long-term with `FOLL_LONGTERM`   | Driver-mapped (`vkMapMemory`) and shared ZFS-file mappings failed; shmem memfds registered |
| Per-buffer cap raised from 1 GiB to 1 TiB in 7.2       | Large slabs register as one `iovec`                    | The error changed from `EFAULT` to `EINVAL`; the man page still documents the old limit    |
| Direct-I/O alignment reported per file by `statx`      | Filesystems and devices differ                         | Zero means "not supported" even where `O_DIRECT` succeeds (tmpfs); filesystems over-accept |
| `IOPOLL` needs `O_DIRECT` and a polling-capable device | Busy-polling works only where the file and device poll | Fails with `EOPNOTSUPP` on default NVMe module parameters                                  |
| dma-buf in io_uring only for zero-copy network receive | Storage reads target user addresses                    | File bytes reach a dma-buf only through a memfd exported by `udmabuf`                      |

## Sources

- Linux 7.3-rc6: [`io_uring/rsrc.c`][rsrc-73], [`io_uring/memmap.c`][memmap-pin],
  [`io_uring/rw.c`][rw-iopoll], [`include/uapi/linux/io_uring/zcrx.h`][zcrx-uapi],
  [`drivers/dma-buf/udmabuf.c`][udmabuf-seals], [`drivers/dma-buf/dma-buf.c`][dmabuf-cpu],
  [`Documentation/userspace-api/dma-buf-heaps.rst`][heaps-doc], [dma-buf docs][dmabuf-doc];
  Linux 6.18: [`io_uring/rsrc.c`][rsrc-618].
- liburing: [`io_uring_register.2`][reg-bufs] (buffers, [files][reg-files], [errors][reg-efault]),
  [`io_uring_setup.2`][setup-iopoll].
- man-pages 6.16: [`open(2)`][open2], [`statx(2)`][statx2].
- Sparkles: [`package.d`][binding-pkg], [`io_uring.d`][binding-io], [event-horizon
  baseline][bl-eh], [hardware matrix][hw], [Vulkan transfer][vk-import], [async-io
  io_uring features][aio-fixed], [`IOPOLL` in async-io][aio-iopoll].

<!-- References -->

[linux-repo]: https://github.com/torvalds/linux/tree/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a
[liburing-repo]: https://github.com/axboe/liburing/tree/78dce99b660fd1caaf70ef6573a88bae9bbf6476
[man7]: https://man7.org/linux/man-pages/
[open2]: https://man7.org/linux/man-pages/man2/open.2.html
[statx2]: https://man7.org/linux/man-pages/man2/statx.2.html
[reg-bufs]: https://github.com/axboe/liburing/blob/78dce99b660fd1caaf70ef6573a88bae9bbf6476/man/io_uring_register.2#L46-L69
[reg-files]: https://github.com/axboe/liburing/blob/78dce99b660fd1caaf70ef6573a88bae9bbf6476/man/io_uring_register.2#L228-L243
[reg-efault]: https://github.com/axboe/liburing/blob/78dce99b660fd1caaf70ef6573a88bae9bbf6476/man/io_uring_register.2#L1278-L1281
[setup-iopoll]: https://github.com/axboe/liburing/blob/78dce99b660fd1caaf70ef6573a88bae9bbf6476/man/io_uring_setup.2#L60-L86
[rsrc-73]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/rsrc.c#L131-L147
[rsrc-618]: https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/io_uring/rsrc.c#L84-L95
[memmap-pin]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/memmap.c#L78-L95
[rw-iopoll]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/rw.c#L876-L878
[zcrx-uapi]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/uapi/linux/io_uring/zcrx.h#L38-L49
[udmabuf-seals]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/drivers/dma-buf/udmabuf.c#L269-L288
[dmabuf-cpu]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/drivers/dma-buf/dma-buf.c#L1440-L1451
[heaps-doc]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/Documentation/userspace-api/dma-buf-heaps.rst#L7-L18
[dmabuf-doc]: https://docs.kernel.org/driver-api/dma-buf.html
[binding]: ../../../libs/event-horizon-sys/src/sparkles/event_horizon/sys/uring/package.d
[binding-pkg]: ../../../libs/event-horizon-sys/src/sparkles/event_horizon/sys/uring/package.d
[binding-io]: ../../../libs/event-horizon-sys/src/sparkles/event_horizon/sys/uring/io_uring.d
[bl-eh]: ./baseline/event-horizon.md
[hw]: ./hardware/index.md
[hw-uring]: ./hardware/index.md#io-uring
[vk-import]: ./vulkan-transfer.md#importing-memory-host-pointers-dma-buf-and-drm-modifiers
[dlpack]: ./dlpack.md
[p-gds]: ./papers/gpu-decode-streaming.md#nvidia-gpudirect-storage-design-guide-nvidia-2026
[aio-fixed]: ../async-io/io-uring/features.md#registered-fixed-files-and-buffers
[aio-iopoll]: ../async-io/io-uring/features.md#sqpoll-iopoll-hybrid-iopoll-and-napi-busy-poll
[c-staging]: ./concepts.md#staging-and-upload
[c-extmem]: ./concepts.md#external-memory-and-zero-copy-import
[c-stride]: ./concepts.md#stride
[c-hostile]: ./concepts.md#hostile-input
[ds-ioring]: ./directstorage-ioring.md
