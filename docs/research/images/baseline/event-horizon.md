# Sparkles baseline: event-horizon and storage I/O

What `sparkles:event-horizon` and `sparkles:event-horizon-sys` give an image and
video library today for reading many files, offloading CPU-bound decode, and
handing finished bytes to a GPU upload, and where the specification and the code
stop short of that.

| Field          | Value                                                                                                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Packages       | `sparkles:event-horizon` (`libs/event-horizon`), `sparkles:event-horizon-sys` (`libs/event-horizon-sys`), consumers `sparkles:http`, `apps/hue` (picker)                             |
| Specs read     | [event-horizon `SPEC.md`][spec] (accepted), [`PLAN.md`][plan], [`open-issues.md`][open], [`benchmarks.md`][bench], [fiber parker][parker] (draft), [VFS backends][vfsb] (draft)      |
| Status summary | Linux io_uring backend, fibers, blocking pool, work-stealing pool and `RawCpuPool` are shipped; Windows and macOS cover sockets and timers only; no mmap, no `O_DIRECT`, no GPU seam |
| Last reviewed  | October 27, 2026                                                                                                                                                                     |

> [!NOTE]
> This is a baseline, not a recommendation. Statuses are used strictly:
> **SHIPPED** means code on branch `feat/images` that I read; **SPECIFIED**
> means normative spec text; **DRAFT** means a spec whose front matter says
> `status: draft`; **PLANNED** means a plan or open-issue entry with no code.
> Test results were not run for this document; "shipped" means the code exists
> and, where stated, that a `unittest` or example names it.

## What exists today

### Shipped

- **A completion-first io_uring loop with no epoll fallback.** `EventLoop!Backend`
  in `libs/event-horizon/src/sparkles/event_horizon/loop.d`, `UringBackend` in
  `backend/uring.d`, three-tier probing into `BackendCaps` in `backend/probe.d`.
  The kernel floor is `kernelFloor = KernelVersion(6, 1)`.
- **File-shaped ops on the ring.** `op.d` defines `OpRead`, `OpWrite`, `OpFsync`,
  `OpStatx`, `OpOpenAt`, `OpOpenAt2`, `OpClose`, `OpMkdirAt`, `OpUnlinkAt`,
  `OpRenameAt`, `OpSymlinkAt`; `backend/uring.d` lowers each through the matching
  `prepXxx` call. A positioned read is `OpRead.offset`; the tier-B verb is
  `read(h, buf, offset)` in `io.d`.
- **Registered buffers.** `BufferPool` (`buffer.d`) carves same-size `Buf`s from
  one slab; `UringBackend.registerBuffers` / `unregisterBuffers` pin the slabs, and
  `trySubmit(OpRead)` selects `prepReadFixed` when `slot.pinned.isRegistered`
  (`backend/uring.d:181-210`). `benchmarks.md` records "registered vs plain 4 KiB
  read ~1.36x" on a single cached page.
- **Provided buffer rings.** `BufRing`, `OpRecvSelect`, `registerBufRing` /
  `unregisterBufRing`, and the tier-B `recvSelect` verb. This is socket-shaped
  (`recvSelect(ref Stream, ...)` in `io.d`); there is no file-read equivalent
  (`READ_MULTISHOT` is not lowered).
- **Move-only pinned buffers.** `Buf` with `BufOrigin` of `none`, `pool`,
  `registered`, `ringLease`, `foreign`; `Buf.fromForeign(ubyte[], BufDeleter)` is
  `@system nothrow @nogc` (`buffer.d:116`).
- **Three tiers on one loop.** Tier A (`@nogc nothrow` function-pointer callbacks,
  `OpCallback`), tier B (`Sched`, `FiberTask`, `io` verbs; every verb a cancellation
  checkpoint), tier C (`effect.d`).
- **Whole-transfer helpers.** `transfer.d` ("complete-transfer conveniences over the
  direct-style completion API"), returning a `TransferResult` that carries
  ownership and the completed prefix even on failure.
- **Three offload mechanisms for CPU or blocking work.**
  1. `BlockingPool` (`blocking_pool.d`, Posix only): `run(ref Sched, BlockingCall,
void*)` parks the calling fiber, a worker thread runs the call, completion
     returns through the scheduler's blocking-completion inbox plus `Waker`
     (`sched.d`: `BlockingJob`, `postBlockingCompletion`). `BlockingCall` is
     `void function(void* context) nothrow` (not `@nogc`). The public lane is
     bounded; saturation returns `EAGAIN` immediately. Once a job is accepted the
     caller waits under `protect`, so a started call is not cancellable.
  2. `RawCpuPool` (`raw_pool.d`): closure-free `RawJob`s over caller-owned
     contexts, fixed-capacity MPMC submission and completion rings, completions
     are _polled_ (`pollCompletion`). It has no connection to a loop waker. Its
     worker count default is `std.parallelism.totalCPUs` (`raw_pool.d:100`), not
     `hwParallelism()`.
  3. `WorkStealingPool` (`pool.d`) and `LoopGroup` (`group.d`): per-worker rings and
     schedulers, lock-free Chase-Lev deques of never-started tasks,
     `submit(delegate)` as a fiber, `submitBlocking(void delegate())` inline, and
     `LoopGroupConfig.cpuBound` for ring-less workers.
- **Capability VFS file system.** `RingVfs` in `vfs.d` is the `fs` member of the
  row. It lowers `OpMkdirAt`, `OpStatx`, `OpSymlinkAt`, `OpUnlinkAt` and `OpRenameAt`
  (`vfs.d:95-199`) and `OpOpenAt2` for `resolveWhole` (`vfs.d:236-247`);
  `openFileAt`, `read`, `write`, `sync`, `close` and listing go through
  `offload(...)` onto the blocking pool (`vfs.d:88-92, 217-224`). A VFS `File` lends its descriptor to the `io` verbs.
- **Futex-based waker only.** `UringBackend.submitFutexWait()` arms one
  `prepFutexWait` on the loop's own wake word. No general futex op type exists in
  `op.d`: a search for `OpFutex` over `libs/event-horizon/src` found nothing.
- **A fork server.** `forkserver.d`: zygote plus per-request grandchild, anonymous
  `MAP_SHARED | MAP_ANON` arena, crash reported as `-signal`, serial, refuses to
  start in a multi-threaded process. First consumer is hue's format preview.
- **A UI-frame handoff precedent.** `apps/hue/src/picker.d` drains
  `RawCpuPool.pollCompletion` "once per UI frame" in `poll(...)`.
- **Peer backends, partially.** `backend/kqueue.d` (macOS, plus a `libkqueue`
  configuration on Linux) covers `nop`, `recv`/`send`, `read`/`write` on
  pipes and sockets, `accept`, `connect`, timers. `backend/iocp.d` covers
  `AcceptEx`, `ConnectEx`, `WSARecv`/`WSASend`, timers; its imports from `op.d` are
  `OpAccept, OpConnect, OpNop, OpRecv, OpSend, OpTimeout` only (`iocp.d:39-40`).

### Specified

- Accepted `SPEC.md`: completion contract (section 4), buffer ownership (section 6),
  fiber scheduler (section 7), cancellation (section 8), capability row and `fs`
  (section 10), topologies (section 11), `RawCpuPool` (section 11.1), UI loop
  (section 15), fork server (section 17).
- Specified and shipped as described: section 6.3 registered buffers, section 11
  pinning invariant, section 11.1 `RawCpuPool`.

### Draft / unmerged

- The [fiber parker][parker] spec (`status: draft`, EFP1-EFP23), whose ring path
  requires `OpFutexWait`, `OpFutexWaitv`, `OpFutexWake`. `PLAN.md` M20 delivers it.
  No such ops exist in `op.d` (see above), so the parker is not shipped.
- The VFS backends spec (`status: draft`), including VFB5, which says `RingVfs`
  "on macOS and Windows ... runs every operation through `BlockingVfs` on the
  blocking pool".

### Planned only

- Zero-copy and polling modes: `SEND_ZC`, `RECV_ZC`, SQPOLL, NAPI, `uring_cmd`
  (open-issues O6, "post-v1 series").
- A `-betterC` configuration of tier A (O3, leaning "ship later if demand appears").
- A GC-safe blocking wait to replace `GC.disable` in the work-stealing pool (O22,
  tracked as issue 171).
- A kqueue regular-file worker pool ("the remaining refinement", `kqueue.d` header).
- Windows file I/O: `PLAN.md` M11 says it "shipped socket/timer/waker parity only".
  A Windows IoRing backend is not mentioned in `SPEC.md`, `PLAN.md` or
  `open-issues.md` (a search for `IoRing` found only `io_uring` hits); not verified
  elsewhere.

## Contracts that constrain image and video work

`SPEC.md` has no requirement identifiers; its decisions are cited by section and,
for unresolved ones, by `O` number in `open-issues.md`. The fiber parker (`EFP`)
and VFS (`VFB`) specs do use identifiers.

| Contract                                  | Quote                                                                                                                                                                                                | Source                                             | Consequence for image and video work                                                                                                       |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Completion buffers (section 4.3)          | "Invariant: **a slot and its pinned buffer stay alive until the terminal completion arrives — always**, including after cancellation (the kernel may still write to the buffer until the CQE lands)" | `docs/specs/event-horizon/SPEC.md:518-520`         | A decoder that reads into a buffer cannot free or reuse it on cancel; cancellation of a file read does not release memory early.           |
| Tier-A currency (section 6.1)             | "The tier-A currency is `Buf` — a **move-only handle over pinned, stable memory**"                                                                                                                   | `SPEC.md:751-752`                                  | A pixel buffer that crosses the submission boundary at tier A must be `Buf`-shaped (pool, registered, ring lease, or foreign).             |
| No inline storage at tier A (section 6.1) | "A buffer with inline storage is **not** a valid tier-A transfer currency"                                                                                                                           | `SPEC.md:770`                                      | `InlineBuffer`/small-buffer types cannot be the target of a tier-A read.                                                                   |
| Tier-B buffers (section 6.5)              | "At tier B the moved-in buffer lives in the suspended verb's stack frame, and the fiber resumes **only at the terminal completion**"                                                                 | `SPEC.md:829-830`                                  | Borrowed slices are sound at tier B; a future "kill a fiber without resumption" is excluded by the same text.                              |
| Fiber pinning (section 11)                | "migrating a started `core.thread.Fiber` between threads is undefined behavior under LDC when any live frame has cached a TLS address"                                                               | `SPEC.md:1554-1556`                                | A decoder written as a fiber stays on its worker for life; only unstarted tasks are stealable.                                             |
| Backend failure (section 5.2)             | "**Hard backend failure is process-fatal.**"                                                                                                                                                         | `SPEC.md:644`                                      | A failing submit/flush/wait aborts the process through `LoopConfig.fatalHook`; an image service cannot treat it as a per-file error.       |
| No epoll (section 3.4)                    | "**There is no epoll fallback.**"                                                                                                                                                                    | `SPEC.md:390`                                      | On kernels below 6.1 or under `io_uring_disabled`, loop creation errors; the library must supply its own synchronous path for those hosts. |
| Verbs are checkpoints (section 7.3)       | "Every verb is a cancellation checkpoint, parks at most once, and resumes only at its terminal completion"                                                                                           | `SPEC.md:977`                                      | Cancellation granularity is one I/O; there is no mid-decode checkpoint unless the codec adds one.                                          |
| The `fs` row (section 10.5)               | "The `fs` member of the root row **must** be a `RingVfs` on every loop backend"                                                                                                                      | `SPEC.md:1463-1465`                                | File opens go through directory capabilities, not path strings.                                                                            |
| VFS async backend (VFB5)                  | "On macOS and Windows it runs every operation through `BlockingVfs` on the blocking pool."                                                                                                           | `docs/specs/base/vfs/backends.md:65-71`            | Outside Linux, file opens (and by default reads through the VFS) are thread-pool operations.                                               |
| Raw CPU jobs (section 11.1)               | "`RawCpuPool` does not change `WorkStealingPool.run`, `submit`, or `submitBlocking`. It is available anywhere DRuntime threads are available; it does not require `io_uring`, kqueue, or IOCP."      | `SPEC.md:1634-1636`                                | The only offload surface that is `@nogc`, closure-free and platform-neutral.                                                               |
| Raw pool fallback (section 11.1)          | "A consumer must retain a synchronous bounded fallback for thread-start failure and queue saturation."                                                                                               | `SPEC.md:1636-1637`                                | A codec scheduler built on it needs an inline path, as hue's picker has.                                                                   |
| Raw pool completions (section 11.1)       | "A worker never drops a completion: before accepting a job the pool reserves one completion slot when `complete` is non-null"                                                                        | `SPEC.md:1619-1620`                                | Backpressure is a submission outcome (`queueFull`, `completionFull`), so decode scheduling can apply it.                                   |
| Parker pinning (EFP20, draft)             | "A pinned fiber's parks go through the thread parker and block its worker."                                                                                                                          | `docs/specs/event-horizon/fiber-parker.md:257-258` | A decode task that holds a `base.sync` lock across a park blocks the whole worker.                                                         |
| Deferred zero-copy (section 3.3)          | "`SEND_ZC`, kernel 6.0, is floor-guaranteed but deliberately outside v1 for lifetime-complexity reasons"                                                                                             | `SPEC.md:352-353`                                  | No zero-copy send/receive for streaming video in v1.                                                                                       |
| GC and stacks (section 7.1)               | "Every live fiber stack is a conservative-GC scan root"                                                                                                                                              | `SPEC.md:849`                                      | Large decode scratch on a fiber stack is scanned; keep pixel storage off fiber stacks.                                                     |

## Capability table

| Capability                                                    | Where                                                                     | Status                                                                | Evidence                                                                                             |
| ------------------------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Positioned file read/write on a ring                          | `io.d` (`read`, `write`), `op.d` (`OpRead`, `OpWrite`), `backend/uring.d` | Shipped (Linux); kqueue pipes/sockets only; IOCP none                 | `uring.d:176-210`; `kqueue.d:307-326`; `iocp.d` imports                                              |
| Open/stat/close/mkdir/rename/unlink on ring                   | `op.d`, `backend/uring.d`                                                 | Shipped (Linux)                                                       | `OpOpenAt`, `OpStatx`, ..., `prepOpenat`, `prepStatx` in `uring.d`                                   |
| Capability VFS `fs` row                                       | `vfs.d` (`RingVfs`), `event-horizon-sys/.../sys/vfs.d` (`BlockingVfs`)    | Shipped; most opens on the blocking pool                              | `vfs.d:88-92`; VFB5                                                                                  |
| Registered (fixed) buffers                                    | `buffer.d` (`BufferPool`), `uring.d` (`registerBuffers`)                  | Shipped                                                               | `uring.d:619-637`; `loop.d:185-193`; `loop.registeredBuffers.fixedReadPath`                          |
| Registered (fixed) files / direct descriptors                 | `BackendCaps.registeredFiles` only                                        | Planned: flag exists, no register call or `FIXED_FILE` lowering found | `probe.d:68, 201`; `concept.d:84-86` says `hasDirectFds` "land[s] with the features that consume" it |
| Provided buffer rings                                         | `buffer.d` (`BufRing`), `io.d` (`recvSelect`)                             | Shipped for sockets; not for files                                    | `SPEC.md:806-817`; `io.d:140`                                                                        |
| `O_DIRECT`, `fadvise`, readahead, `READ_MULTISHOT`, `READV`   | none                                                                      | Not found in `libs/event-horizon*/src`                                | search for `O_DIRECT`, `fadvise`, `readahead`, `READV` returned nothing                              |
| mmap of files; `MappedFile`                                   | none in the event-horizon or base libraries searched                      | Not found (only `forkserver.d`'s `MAP_SHARED \| MAP_ANON` arena)      | search of `libs/base/src`, `libs/event-horizon*`, `libs/vulkan`                                      |
| Backpressure on submit                                        | `loop.d`                                                                  | Shipped: `EAGAIN` on full SQ, `ENOBUFS` on full slab                  | `SPEC.md:619-626`                                                                                    |
| Cancellation of in-flight I/O                                 | `scope_.d`, `loop.d`                                                      | Shipped; guaranteed on a driven loop                                  | `SPEC.md:628-640`; section 8.5                                                                       |
| Structured concurrency (scopes, deadlines)                    | `scope_.d`                                                                | Shipped                                                               | `SPEC.md` section 8                                                                                  |
| Blocking-call offload from a fiber                            | `blocking_pool.d` (`BlockingPool.run`)                                    | Shipped (Posix); not `@nogc`; not cancellable once accepted           | `blocking_pool.d:1-40, 120-123`                                                                      |
| Closure-free CPU job pool                                     | `raw_pool.d` (`RawCpuPool`)                                               | Shipped; polled completions; `totalCPUs` sizing                       | `raw_pool.d:15, 100`; `picker.d:474`                                                                 |
| Work-stealing of unstarted tasks                              | `pool.d`, `group.d`                                                       | Shipped (Linux)                                                       | `pool.d` header; `SPEC.md` section 11                                                                |
| Started-fiber migration                                       | none                                                                      | Specified as forbidden; open as O1 (leaning "never")                  | `SPEC.md:1551-1558`; O1                                                                              |
| Fiber parker for `base.sync`                                  | `fiber-parker.md`                                                         | Draft; no futex op types in `op.d`                                    | `fiber-parker.md:2`; `PLAN.md` M20                                                                   |
| Loop wake from other threads                                  | `Waker`, `backend/concept.d`                                              | Shipped                                                               | `SPEC.md` section 5.6; O29                                                                           |
| UI frame handoff                                              | `Ticker`, `Channel`, `Sched.tick`, `OpPollAdd`                            | Shipped / specified                                                   | `SPEC.md` sections 7.2, 7.3, 15                                                                      |
| Process isolation of hostile work                             | `forkserver.d` (`ForkServer`)                                             | Shipped; serial; single-threaded start only                           | `forkserver.d:1-31`; `SPEC.md` section 17                                                            |
| Windows file I/O on a completion port                         | `backend/iocp.d`                                                          | Not shipped (sockets/timers only)                                     | `PLAN.md` M11 closing paragraph                                                                      |
| macOS regular-file worker pool                                | `backend/kqueue.d`                                                        | Planned                                                               | `kqueue.d` header                                                                                    |
| Windows IoRing                                                | none                                                                      | Not mentioned in specs; not verified                                  | search for `IoRing`                                                                                  |
| Zero-copy, SQPOLL, IOPOLL                                     | none                                                                      | Planned (O6); IOPOLL not mentioned in event-horizon specs             | `open-issues.md` O6                                                                                  |
| Vulkan-importable host memory (`VK_EXT_external_memory_host`) | none                                                                      | Not found in `libs` or in `docs` outside `docs/research/images`       | search; `libs/vulkan/.../memory.d` allocates and maps its own memory                                 |
| Completion-to-GPU-submit handoff                              | `apps/hue/src/picker.d` pattern only                                      | Precedent for CPU results, not for GPU                                | `picker.d:465-480`                                                                                   |
| Buffer wrapping foreign (e.g. Vulkan-mapped) memory           | `Buf.fromForeign`                                                         | Shipped; lifetime is the caller's                                     | `buffer.d:116`                                                                                       |

## Gaps and tensions

**G1. Whole-file and ranged reading has no helper layer (Q6, Q4).** The ring has
`OpRead` with an offset, and `transfer.d` offers complete-transfer helpers, but I found
no readahead, `fadvise`, `READV`, `READ_MULTISHOT`, `O_DIRECT`, sparse-file handling,
or "read this range into N slots" API. An incremental decoder that wants a chunked
stream with a bounded number of reads in flight has to build that scheduling itself on
`BufferPool` and `OpRead`.

**G2. Registered files are advertised, not implemented (Q6).** `BackendCaps.registeredFiles`
is set from `caps.supports(OpKind.read)` (`probe.d:201`), the flag is not backed by a
`register`/`FIXED_FILE` path, and `concept.d:84-86` defers `hasDirectFds`. For a
workload of many small image files, per-op `fget` cost is the unmeasured part; the
repo has only a 4 KiB cached-read benchmark (`benchmarks.md`), not a many-small-files
read benchmark.

**G3. mmap and O_DIRECT are absent, and the memory model is unspecified (Q1, Q6).** Neither
exists in the I/O layer. `Buf` can wrap foreign memory (`fromForeign`) but a mapped
file is not a `Buf` the kernel writes into; it is a read-only view. Which of mapped
file, pool slab, or GPU-mapped staging is the image library's source of pixels or
compressed bytes is open, and the loop's `Buf` currency answers only the second and
third.

**G4. The storage-to-GPU seam does not exist (Q6, Q7).** Vulkan code in `libs/vulkan`
allocates and maps its own memory (`DeviceMemoryBackend.allocate` / `map`,
`memory.d:158-175`) and `sparkles.ui_vulkan.upload` stages by copying pixels into a
frame slot ("`stage` copies pixels into the frame slot's buffers"). No code imports
host pointers into Vulkan (`VK_EXT_external_memory_host` appears nowhere in `libs`), and
event-horizon never sees Vulkan memory. The only existing bridge is a
`Buf.fromForeign` over `FrameBuffers` memory, which is feasible by the type but unused
and subject to the section 4.3 lifetime rule: the staging slot cannot be recycled until
the terminal CQE, including after cancellation.

**G5. CPU-bound decode offload is split three ways with different contracts (Q2, Q3, Q4).**
`BlockingPool` is fiber-aware but its call type is `void function(void*) nothrow`
(not `@nogc`) and it cannot cancel once started; `RawCpuPool` is `@nogc`, closure-free,
and cancellable only at the queue, but its completions are polled and it does not
wake a loop; `WorkStealingPool` takes `void delegate()`, runs tasks as fibers or
inline, and is described as "batch-scoped" (by the `raw_pool.d` header). None of them composes a "run this decode
slice, then resume my fiber" with a cooperative cancel flag. This is in tension with the
standing rule against package-local copies of shared infrastructure: an image package
that needs a job queue today must either pick one of the three or add a fourth.

**G6. A decoder cannot be a suspendable fiber that migrates (Q4).** Started fibers are
pinned (section 11, O1 leaning "never"). A long decode that parks on I/O between
strips stays on its worker; work-stealing can only rebalance task starts. This
is in tension with imbalance: one worker holding the biggest images keeps them. A
codec architecture that wants to resume a decode on a different worker must be a
state machine in a plain struct (resumable by any thread), not a stackful fiber.

**G7. The raw pool is unwired to the loop and mis-sized (Q3, Q7).** `RawCpuPool` uses
`std.parallelism.totalCPUs` (`raw_pool.d:100`) although O30 decided that sizing
belongs to `hwParallelism()` in `sparkles.base.hw_caps` because `totalCPUs` ignores cgroup
quotas; `pool.d` and `blocking_pool.d` already use `hwParallelism`. Its completions have
to be polled by the loop's owner (as hue does per frame). A server-shaped consumer
would need to bridge `pollCompletion` to a `Waker`. Related rule: AGENTS.md says
"extend shared infra, not fork".

**G8. Fiber stacks are conservative-GC scan roots and `GC.disable` is the pool's
workaround (Q1, Q4).** Section 7.1 and O22 together mean large pixel scratch on a fiber
stack is both scanned and risky, and the work-stealing pool disables the collector for
its lifetime. Image buffers therefore need to be off-GC (`HeapBuffer`/`mmap`), and a
decode inside `WorkStealingPool.run` must be `@nogc`-clean for the lifetime of the run.
O22 records a 1-in-40 hang without `GC.disable`.

**G9. Hostile-input isolation exists but at process granularity only (Q4, Q8).** The
`ForkServer` gives crash containment with zero-copy shared slots, but it is serial,
refuses multi-threaded hosts, and has one registered handler. A parallel image-batch
tool that has already started threads cannot start it. Whether a decoder's crash
(not an `Expected` error) is acceptable to take down a worker is not addressed by the
event-horizon specs beyond the section 5.2 fatal-hook rule for backend failure.

**G10. Non-Linux platforms cannot read files on the loop (Q6, Q9).** kqueue maps `read`/`write`
to `EVFILT_READ`/`EVFILT_WRITE` readiness, which the header itself says regular files
lack; IOCP imports no file ops; `RingVfs` falls back to the blocking pool for every
operation on macOS and Windows (VFB5). Image I/O portable to those targets is thread-pool
I/O with no completion-based behaviour. Windows IoRing is not mentioned in any spec
read. Android builds exist (`bionic.d`, `libkqueue` configuration) but the file path
there is not described.

**G11. The failure model is process-fatal for backend errors and `IoError` for the rest (Q4, Q8).**
This fits AGENTS.md ("Expected for errors") and `IoResult` is `Expected`-shaped.
In tension: a hostile or oversized request can exhaust the op slab (`ENOBUFS`) or SQ
(`EAGAIN`) and the library has no spec for how a caller sheds load beyond returning
those errors; "Submit backpressure policy" is open-issue O9 (I read its title; not read
in full).

**G12. The only `@nogc` offload pool does not consume `Effect`/scope cancellation (Q4).**
`RawCpuPool` jobs consult "caller-owned atomics" for cancellation ("the pool gives no
implicit generation or cancellation semantics"), whereas fiber verbs honor the
cancellation tree. Cancelling a decode in a scope will not reach a job already running.

**G13. betterC/wasm reach is limited (Q9).** O3 says tier A is `@nogc nothrow` but
druntime-linked and a betterC configuration is deferred; `during` is a
`platform="linux"` dependency (`libs/event-horizon/dub.sdl:16`). A format
library meant to run under `--better-c` or `--wasm` test modes must keep the codec core
independent of event-horizon and accept bytes through a narrow interface.

**G14. Windows/macOS parity for futex-style waits is draft (Q6).** The parker's ring
path is Linux 6.7+ only; the inbox path covers other backends; both are draft (M20).

## Questions for the design grill

1. **Where does the codec stop and event-horizon start? (Q9, Q4.)**
   - (a) Codecs are pure synchronous or resumable-state-machine libraries that consume
     byte slices; an adapter package binds them to `read`/`BlockingPool`.
   - (b) Codecs are written as fibers on `Sched`.
   - (c) Codecs expose both, with a state machine as the core and a fiber wrapper.
   - Recommendation: (c) with the core independent of event-horizon, so `--better-c`,
     wasm and Windows builds do not depend on the Linux backend.

2. **Which offload primitive does decode use? (Q3, Q7.)**
   - (a) `RawCpuPool` extended with a loop-waker completion path.
   - (b) `BlockingPool.run` as is.
   - (c) A new image-specific pool.
   - Recommendation: (a), fixing `totalCPUs` to `hwParallelism()` first; (c) conflicts
     with the "no package-local copies of shared infra" rule.

3. **Is the unit of cancellation an I/O or a decode slice? (Q4.)**
   - (a) I/O only (current).
   - (b) Decode slices with an atomic flag the job checks between strips.
   - (c) Process isolation via `ForkServer` for untrusted input.
   - Recommendation: (b) as the default; (c) as an opt-in for formats with a bad
     hostile-input record, once the fork server can fan out.

4. **Source of compressed bytes: read into a pool slab, mmap, or `O_DIRECT`? (Q6.)**
   - (a) Pool slab via registered-buffer `OpRead` (exists).
   - (b) A read-only mapped file (new).
   - (c) `O_DIRECT` into page-aligned `MmapAllocator` slabs (needs new open flags and
     alignment contracts).
   - Recommendation: (a) first, measured against (b) on a real many-file corpus;
     do not choose (c) before a benchmark exists.

5. **Does file data land directly in Vulkan-importable memory? (Q6, Q7.)**
   - (a) No: read to CPU slab, decode, copy into the existing frame-slot staging.
   - (b) Read into a `Buf.fromForeign` view of the mapped staging buffer.
   - (c) Import host allocations via `VK_EXT_external_memory_host` (needs a new
     `sparkles:vulkan` memory backend and alignment to `minImportedHostPointerAlignment`).
   - Recommendation: (a) now, (b) for the decoded-pixel write path, and treat (c) as
     a measured follow-up; not verified here that the target drivers expose the extension.

6. **Who drives backpressure between reader, decoder, and uploader? (Q4, Q6.)**
   - (a) Bounded `Channel!T` between stages inside a scope.
   - (b) Slab or pool exhaustion (`ENOBUFS`, `queueFull`) as the signal.
   - (c) A credit scheme owned by the image library.
   - Recommendation: (a), with the pool sizes as the budget.

7. **Registered files for many-small-files workloads: implement or drop the flag? (Q6.)**
   - (a) Implement `IORING_REGISTER_FILES` with a per-loop table.
   - (b) Keep opening per file, measure first.
   - Recommendation: (b), then (a) only if the benchmark shows it matters.

8. **What does non-Linux file reading promise? (Q6, Q9.)**
   - (a) The same API, honest degradation to the blocking pool (the VFB5 position).
   - (b) A kqueue worker pool and a Windows overlapped-file path under the loop.
   - Recommendation: (a), recording the degradation in `BackendCaps`.

## Sources

- [`docs/specs/event-horizon/SPEC.md`][spec]: sections 3.3-3.5, 4.3, 5.2, 6, 7, 8.5, 10.5, 11, 11.1, 13.8, 15, 17.
- [`docs/specs/event-horizon/PLAN.md`][plan]: M7, M8, M9, E0, M10, M11, M18, M20.
- [`docs/specs/event-horizon/open-issues.md`][open]: O1, O2, O3, O5, O6, O16, O22, O23, O30.
- [`docs/specs/event-horizon/benchmarks.md`][bench]: section 1 table.
- [`docs/specs/event-horizon/fiber-parker.md`][parker]: EFP20 and front matter.
- [`docs/specs/base/vfs/backends.md`][vfsb]: VFB5, VFB6.
- [`docs/research/async-io/io-uring/index.md`][uring-index], [`features.md`][uring-features], [`opcodes-reference.md`][uring-opcodes]: for `READ_MULTISHOT`, `FADVISE`, `IOPOLL`, registered files (research, not code).
- Code read: `libs/event-horizon/src/sparkles/event_horizon/{op,buffer,io,transfer,vfs,loop,blocking_pool,raw_pool,pool,forkserver,package}.d`, `backend/{uring,probe,concept,iocp,kqueue}.d`, `libs/event-horizon/dub.sdl`; `libs/vulkan/src/sparkles/vulkan/memory.d`; `libs/ui-vulkan/src/sparkles/ui_vulkan/upload.d`; `apps/hue/src/picker.d`.
- Not read in full: `supervise.d`, `live.d`, `sampling.d`, `cgroup.d`, `sched.d` beyond the blocking-job section, `libs/http` beyond its import lines, O9 and O16-O21, O25-O29 bodies.

<!-- References -->

[spec]: ../../../specs/event-horizon/SPEC.md
[plan]: ../../../specs/event-horizon/PLAN.md
[open]: ../../../specs/event-horizon/open-issues.md
[bench]: ../../../specs/event-horizon/benchmarks.md
[parker]: ../../../specs/event-horizon/fiber-parker.md
[vfsb]: ../../../specs/base/vfs/backends.md
[uring-index]: ../../async-io/io-uring/index.md
[uring-features]: ../../async-io/io-uring/features.md
[uring-opcodes]: ../../async-io/io-uring/opcodes-reference.md
