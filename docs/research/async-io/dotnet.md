# .NET Runtime (System.Net.Sockets + io_uring)

How the .NET runtime drives asynchronous sockets on Unix today (an epoll/kqueue **readiness** engine that dispatches completions onto the managed ThreadPool), and the in-progress, opt-in **`io_uring` completion engine** proposed in [dotnet/runtime PR #124374][PR124374].

| Field         | Value                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------- |
| Language      | C# (managed) + C (PAL / native shim)                                                                          |
| License       | MIT                                                                                                           |
| Repository    | [dotnet/runtime]                                                                                              |
| Documentation | [Socket async docs][SAEA docs] / [io_uring PR #124374][PR124374] / [tracking issue #753][issue753]            |
| Key Authors   | .NET Networking team; `io_uring` PR by Ben Adams ([@benaadams][benaadams])                                    |
| Pattern       | Reactor (epoll/kqueue readiness) today; **Proactor** (`io_uring` completion) in PR — Windows is IOCP Proactor |

> **Status note.** Everything in the `io_uring` sections below describes
> **[PR #124374][PR124374]**, a work-in-progress, opt-in, **not-yet-merged**
> change. It is gated behind `DOTNET_SYSTEM_NET_SOCKETS_IO_URING=1` (or the
> `System.Net.Sockets.UseIoUring` AppContext switch) and falls back to the
> shipping epoll engine when disabled or unsupported. The epoll/kqueue
> readiness engine described first is the production behavior of .NET on Unix.

---

## Overview

### What it solves

.NET exposes a single asynchronous socket surface — `Socket.ReceiveAsync`,
`SendAsync`, `AcceptAsync`, `ConnectAsync`, returning `Task`/`ValueTask` or
driven by reusable `SocketAsyncEventArgs` (SAEA) objects — and must implement
that surface efficiently on three very different kernels:

- **Windows**: a native **Proactor**. Overlapped I/O is submitted with an
  `OVERLAPPED` structure and the kernel signals an **I/O Completion Port
  (IOCP)** when the operation _finishes_. The CLR owns a process-wide IOCP and
  binds socket handles to it (`ThreadPool.BindHandle`), so the runtime never
  has to translate readiness into completion — the OS already delivers
  completions.
- **Linux / macOS / BSD**: a **Reactor**. `epoll`/`kqueue` report _readiness_
  ("this fd is now readable/writable"), not completion. The runtime must keep
  per-socket queues of pending operations and run the actual `recv`/`send`
  syscall when readiness arrives, then translate the syscall result into a
  completion the managed layer can observe.

The shipping Unix design — `SocketAsyncEngine` + `SocketAsyncContext` — is the
Reactor half. [PR #124374][PR124374] adds a **second Unix backend** that turns
Linux into a Proactor like Windows, using **io_uring** so the kernel performs
the `recv`/`send`/`accept` itself and posts a completion, eliminating the
readiness-then-syscall round-trip on the hot path.

### Design philosophy

- **One async model, many backends.** The public API (`ValueTask`-returning
  methods + `SocketAsyncEventArgs`) is identical everywhere; the engine is a
  per-platform `partial class`. See [`SocketAsyncEngine.Unix.cs`][engineUnix]
  for the shared scaffolding and `*.Linux.cs` / `*.Windows.cs` / `*.Wasi.cs`
  for platform specializations.
- **Push completions onto the ThreadPool, not the event thread.** A small
  number of dedicated event-loop threads do nothing but harvest events and
  enqueue work; user continuations run on `ThreadPool` worker threads. This
  keeps a slow user callback from stalling event delivery for every other
  socket.
- **Capability detection over version assumptions.** The `io_uring` engine never
  assumes a feature exists from the kernel version alone — it _probes_ every
  opcode (`IORING_REGISTER_PROBE`) and negotiates setup flags by peeling
  unsupported ones and retrying, then lights up multishot/zero-copy/etc. only
  where the running kernel confirms support.
- **Always have an escape hatch.** If `io_uring` setup fails at any step, the
  engine silently reverts to the epoll path. There is no scenario where
  enabling the flag on an unsupported kernel breaks sockets.

This places .NET alongside [Tokio][tokio] and [Glommio][glommio] as a runtime
adding `io_uring` beneath an existing readiness-based abstraction; contrast with
[Seastar][seastar] (`io_uring`-native shard-per-core) and the effect-based
direct-style approach of [Eio][eio]. See [the io_uring overview][iouring] and
[comparison][comparison] for the broader landscape.

---

## Core abstractions and types

| Type                                                             | File                                      | Role                                                                                                                                                    |
| ---------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SocketAsyncEventArgs` (SAEA)                                    | `SocketAsyncEventArgs.cs`                 | Reusable, poolable operation descriptor; the zero-allocation foundation under `ValueTask`-based `Socket.*Async`.                                        |
| `SocketAsyncEngine`                                              | [`SocketAsyncEngine.Unix.cs`][engineUnix] | The event loop. One per ~30 cores (x64) / ~8 cores (ARM64); harvests epoll/`io_uring` events and schedules work. `IThreadPoolWorkItem`.                 |
| `SocketAsyncContext`                                             | [`SocketAsyncContext.Unix.cs`][ctxUnix]   | Per-socket state: the two operation queues, registration index, non-blocking handle.                                                                    |
| `OperationQueue<TOperation>`                                     | `SocketAsyncContext.Unix.cs`              | A queue of pending `AsyncOperation`s with a small `QueueState` state machine (`Ready`/`Waiting`/`Processing`/`Stopped`). One for reads, one for writes. |
| `AsyncOperation` (+ `ReadOperation`/`WriteOperation` subclasses) | `SocketAsyncContext.Unix.cs`              | A single in-flight op (`AcceptOperation`, `BufferMemoryReceiveOperation`, `SendOperation`, `ConnectOperation`, ...). Also an `IThreadPoolWorkItem`.     |
| `SocketIOEvent` / `SocketIOEventQueue`                           | `SocketAsyncEngine.Unix.cs`               | The hand-off record `(context, events)` enqueued by the event thread and drained by ThreadPool workers.                                                 |

### The central loop object: `SocketAsyncEngine`

On Unix the engine is created as a small fixed-size array
(`s_engines = CreateEngines()`), sized by `GetEngineCount()`:

```csharp
// SocketAsyncEngine.Unix.cs — engine sizing
Architecture architecture = RuntimeInformation.ProcessArchitecture;
int coresPerEngine = architecture is Architecture.Arm64 or Architecture.Arm ? 8 : 30;
return Math.Max(1, (int)Math.Round(Environment.ProcessorCount / (double)coresPerEngine));
```

Each engine owns a native event port (`_port` — an epoll fd / kqueue), an event
buffer, and a dedicated background thread named `".NET Sockets"` that runs
`EventLoop()`. Sockets are assigned to engines round-robin (or by fd→engine
affinity) in `TryRegisterSocket`.

### Per-socket queues: `SocketAsyncContext`

Each socket has exactly one `SocketAsyncContext`, holding two operation queues:

```csharp
// SocketAsyncContext.Unix.cs
private OperationQueue<ReadOperation> _receiveQueue;
private OperationQueue<WriteOperation> _sendQueue;
private SocketAsyncEngine? _asyncEngine;
```

The context is registered with an engine the first time the socket goes async
(`TryRegister` → `SocketAsyncEngine.TryRegisterSocket`). It is assigned a
`GlobalContextIndex` into a process-wide `s_registeredContexts` table; that
index is stuffed into the epoll event's user-data field so an incoming event
maps back to a context in O(1) without a dictionary lookup.

### Submission/completion primitive

- **Today (Reactor):** the "submission" is enqueuing an `AsyncOperation` onto a
  context's read/write `OperationQueue`; the "completion" is the engine
  observing readiness, the worker running the real `recv`/`send` syscall, and
  the operation's state reaching `Completed`.
- **`io_uring` PR (Proactor):** the submission primitive becomes an **SQE**
  (`IoUringSqe`, the 64-byte `struct io_uring_sqe`) written into the mmap'd
  submission ring; the completion primitive is a **CQE** (`IoUringCqe`,
  `struct io_uring_cqe`) the kernel posts to the completion ring, keyed by a
  tagged `user_data` value.

---

## How it works

### The epoll/kqueue readiness engine (shipping)

The event loop is deliberately tiny. From [`SocketAsyncEngine.Unix.cs`][engineUnix]:

```csharp
private void EventLoop()
{
    SocketEventHandler handler = new SocketEventHandler(this);
    while (true)
    {
        int numEvents = s_eventBufferCount;
        Interop.Error err = Interop.Sys.WaitForSocketEvents(_port, handler.Buffer, &numEvents);
        if (err != Interop.Error.SUCCESS) ThrowInternalException(err);

        if (numEvents > 0 && handler.HandleSocketEvents(numEvents))
            EnsureWorkerScheduled();
    }
}
```

`WaitForSocketEvents` is the PAL wrapper over `epoll_wait` (Linux) /
`kevent` (macOS/BSD). For each ready fd, `HandleSocketEvents` maps the
user-data back to a `SocketAsyncContext` and either:

- **inlines** the completion on the event thread when
  `PreferInlineCompletions` is set (opt-in via
  `DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1`); or
- **speculatively** runs the syscall and, if the operation can't complete
  synchronously, enqueues a `SocketIOEvent(context, events)` onto the
  engine's `SocketIOEventQueue`.

When work is enqueued, `EnsureWorkerScheduled()` posts the engine itself to the
ThreadPool — but only one worker request at a time, to avoid a thundering herd:

```csharp
if (Interlocked.Exchange(ref _hasOutstandingThreadRequest, 1) == 0)
    ThreadPool.UnsafeQueueUserWorkItem(this, preferLocal: false);
```

The engine implements `IThreadPoolWorkItem.Execute()`: it drains
`SocketIOEvent`s and calls `ev.Context.HandleEvents(ev.Events)`, which advances
that socket's operation queue (running the real `recv`/`send` and completing
the `AsyncOperation`). A 15 ms time-slice check yields the worker so these
items can't starve other ThreadPool work. This is the core of the Reactor: the
kernel says _ready_, .NET does the I/O and the bookkeeping in managed code.

### The Windows comparison (native Proactor)

On Windows there is no readiness translation. `SocketAsyncEventArgs.Windows.cs`
issues overlapped `WSARecv`/`WSASend`/`AcceptEx` with an `OVERLAPPED`, the
socket handle is bound to the CLR's process IOCP, and a completion is delivered
directly by the OS to an IOCP thread. The `io_uring` PR brings Linux to this same
_the-kernel-did-the-I/O_ model — the .NET runtime ends up running two Proactor
backends (IOCP on Windows, `io_uring` on Linux) and one Reactor backend
(epoll/kqueue) for everything else.

### The io_uring completion engine (PR #124374)

The PR adds `io_uring` as a set of `partial class SocketAsyncEngine` files,
keeping the `SocketAsyncEngine.Unix.cs` scaffolding and threading partial-method
hooks (`LinuxDetectAndInitializeIoUring`, `LinuxEventLoopTryCompletionWait`,
`LinuxFreeIoUringResources`, ...) into the shared event loop. The relevant
files:

| File                                                   | Responsibility                                                                   |
| ------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `SocketAsyncEngine.IoUringConfiguration.Linux.cs`      | Env-var / AppContext resolution, kernel topology detection, CPU pinning.         |
| `SocketAsyncEngine.IoUringRings.Linux.cs`              | `mmap` of SQ/CQ rings and the SQE array; teardown/unmap.                         |
| `SocketAsyncEngine.IoUringSlots.Linux.cs`              | Per-operation completion-slot pool (generation-tagged).                          |
| `SocketAsyncEngine.IoUringSqeWriters.Linux.cs`         | Functions that fill in each opcode's SQE.                                        |
| `SocketAsyncEngine.IoUringCompletionDispatch.Linux.cs` | CQE harvesting + dispatch back to `SocketAsyncContext`.                          |
| `SocketAsyncEngine.Linux.cs`                           | The large hub: setup-flag negotiation, opcode probe, recv strategy, diagnostics. |
| `SocketAsyncContext.IoUring.Linux.cs`                  | Per-socket multishot accept/recv arming, buffered early data.                    |
| `pal_io_uring_shim.{c,h}`                              | Native syscall shim (`io_uring_setup`/`enter`/`register`, `mmap`, eventfd).      |

#### Native shim — the only new native surface

[`pal_io_uring_shim.h`][shimH] exports a tiny, liburing-free C surface — the
managed engine drives the ring directly. The whole shim is three `io_uring`
syscalls plus mmap and eventfd helpers:

```c
// pal_io_uring_shim.h
PALEXPORT int32_t SystemNative_IoUringShimSetup(uint32_t entries, void* params, int32_t* ringFd);
PALEXPORT int32_t SystemNative_IoUringShimEnter(int32_t ringFd, uint32_t toSubmit, uint32_t minComplete, uint32_t flags, int32_t* result);
PALEXPORT int32_t SystemNative_IoUringShimEnterExt(int32_t ringFd, uint32_t toSubmit, uint32_t minComplete, uint32_t flags, void* arg, int32_t* result);
PALEXPORT int32_t SystemNative_IoUringShimRegister(int32_t ringFd, uint32_t opcode, void* arg, uint32_t nrArgs, int32_t* result);
PALEXPORT int32_t SystemNative_IoUringShimMmap(int32_t ringFd, uint64_t size, uint64_t offset, void** mappedPtr);
// ... Munmap, CreateEventFd, WriteEventFd, ReadEventFd, CloseFd
```

[`pal_io_uring_shim.c`][shimC] makes the raw syscalls (`syscall(__NR_io_uring_*)`),
retries on `EINTR` up to a bounded limit, and gates the whole file behind a
compile-time `SHIM_HAVE_IO_URING` macro (requires `<linux/io_uring.h>`, the
syscall numbers, and a 64-bit pointer). On unsupported build hosts every entry
point returns `Error_ENOSYS`. A block of `c_static_assert`s pins the kernel ABI
the managed structs mirror, e.g.:

```c
c_static_assert(sizeof(struct io_uring_cqe) == 16);
c_static_assert(offsetof(struct io_uring_cqe, user_data) == 0);
c_static_assert(offsetof(struct io_uring_cqe, res) == 8);
c_static_assert(offsetof(struct io_uring_cqe, flags) == 12);
c_static_assert(sizeof(struct io_uring_params) == 120);
```

`SystemNative_IoUringShimEnterExt` is notable: it passes the
`io_uring_getevents_arg` (mirrored locally as `ShimIoUringGeteventsArg`) so the
managed loop can do a **bounded-timeout** wait via `IORING_ENTER_EXT_ARG`, and
treats `ETIME` (timeout expired) as success returning `toSubmit` so the managed
pending-submission counter stays in sync.

#### Initialization, version gating, and the fallback path

`io_uring` init is **deferred onto the event-loop thread** rather than the engine
constructor — `io_uring_setup` records the calling thread as the
`submitter_task`, which `IORING_SETUP_DEFER_TASKRUN` requires. A
`ManualResetEventSlim _ioUringInitSignal` blocks socket registration until init
finishes. `LinuxDetectAndInitializeIoUring` (in `SocketAsyncEngine.Linux.cs`)
orchestrates the sequence, and any failure returns to epoll:

```csharp
partial void LinuxDetectAndInitializeIoUring()
{
    IoUringResolvedConfiguration cfg = ResolveIoUringResolvedConfiguration();
    if (!cfg.IoUringEnabled || !IsNativeMsghdrLayoutSupportedForIoUring() || !TryInitializeManagedIoUring(in cfg))
    {
        _ioUringCapabilities = ResolveLinuxIoUringCapabilities(isIoUringPort: false);
        SocketsTelemetry.Log.ReportSocketEngineBackendSelected(isIoUringPort: false, isCompletionMode: false, sqPollEnabled: false);
        return; // <-- falls back to the epoll WaitForSocketEvents path
    }
    // ... publish capabilities last, after a memory barrier
}
```

`TryInitializeManagedIoUring` runs the staged setup, **closing the ring and
returning `false` (→ epoll) on any failure**:

1. **Kernel version gate.** `IsIoUringKernelVersionSupported()` requires
   **Linux ≥ 6.1** (`MinKernelMajor=6, MinKernelMinor=1`). The 6.1 floor is
   chosen because the `SEND_ZC` deferred-completion logic depends on `NOTIF` CQE
   sequencing stabilized in 6.1, even though several lower-level features exist
   earlier. (For comparison: [multishot accept lands in 5.19, multishot recv in
   6.0][io-uring-net-2023].)
2. **`io_uring_setup` with flag negotiation.** `TrySetupIoUring` requests a rich
   flag set and peels unsupported flags on `EINVAL`, newest-first:

   ```csharp
   uint flags = SetupCqSize | SetupSubmitAll | SetupCoopTaskrun
              | SetupSingleIssuer | SetupNoSqArray | SetupCloexec;
   flags |= sqPollRequested ? SetupSqPoll : SetupDeferTaskrun;
   // Peel order on EINVAL: NO_SQARRAY (Linux 6.6), then CLOEXEC (Linux 5.19)
   ReadOnlySpan<uint> flagsToPeel = [SetupNoSqArray, SetupCloexec];
   ```

   `IORING_SETUP_SINGLE_ISSUER` (Linux 6.0) plus `DEFER_TASKRUN` (Linux 6.1)
   lets the event loop defer kernel task-work to `io_uring_enter` and avoid the
   per-syscall `COOP_TASKRUN` overhead; `SQPOLL` and `DEFER_TASKRUN` are
   mutually exclusive, so requesting SQPOLL swaps them. (The PR's
   `IORING_SETUP_CLOEXEC` flag — bit `1<<19`, annotated "Linux 5.19" in the PR —
   is **not** an upstream `io_uring` setup flag: in current mainline and liburing
   that bit is `IORING_SETUP_SQE_MIXED`, and the `io_uring` ring fd is already
   created `O_CLOEXEC` by default. The peel logic simply drops it on `EINVAL`,
   so this is harmless, but the "5.19" version marker should be treated as the
   PR's own unverified annotation rather than a confirmed kernel fact.)

3. **`mmap` the rings.** `TryMmapRings` maps the SQ ring, CQ ring (or a single
   region when `IORING_FEAT_SINGLE_MMAP` is set), and the SQE array at the
   well-known offsets (`IORING_OFF_SQ_RING=0`, `OFF_CQ_RING=0x8000000`,
   `OFF_SQES=0x10000000`), validates every kernel-reported ring offset is
   in-range, and asserts power-of-two ring sizes. It only supports the 64-byte
   SQE layout (rejects negotiated `SQE128`).
4. **Opcode probe.** `ProbeIoUringOpcodeSupport` issues
   `IORING_REGISTER_PROBE` and records per-opcode support flags for `Send`,
   `Recv`, `SendMsg`, `RecvMsg`, `Accept`, `Connect`, `SendZc`, `SendMsgZc`,
   `ReadFixed`, `AsyncCancel`. Multishot accept = `Accept` supported and not
   kill-switched; multishot recv additionally requires provided-buffer-ring
   support.
5. **Wakeup eventfd + registered ring fd.** Creates a non-blocking
   `eventfd`, arms a **multishot `POLL_ADD`** on it
   (`QueueManagedWakeupPollAdd`, tagged `TagWakeupSignal`) so other threads can
   wake the loop, and tries `IORING_REGISTER_RING_FDS` for faster `enter`.
6. **Provided buffer ring + multishot recv.**
   `InitializeIoUringProvidedBufferRingIfSupported` registers a buffer ring
   (`IORING_REGISTER_PBUF_RING`) and `RefreshIoUringMultishotRecvSupport`
   finalizes the receive strategy.

Only after all of this — behind a memory barrier — are `_ioUringCapabilities`
published, since cross-thread readers gate on `IsIoUringPort`/`IsCompletionMode`
before touching ring state.

#### Submission and completion flow

Once initialized, the same `EventLoop()` from `SocketAsyncEngine.Unix.cs` runs,
but `LinuxEventLoopTryCompletionWait` short-circuits the epoll `WaitForSocketEvents`
and instead does an `io_uring_enter` (bounded by `BoundedWaitTimeoutNanos = 50ms`
via the `EXT_ARG` path when negotiated). SQEs are written directly into the mmap'd
ring on the event-loop thread (`TryGetNextManagedSqe` enforces the
`SINGLE_ISSUER` contract via `Debug.Assert(IsCurrentThreadEventLoopThread())`),
`PublishManagedSqeTail` makes them visible, and CQEs are harvested in
`SocketAsyncEngine.IoUringCompletionDispatch.Linux.cs`.

**`user_data` tagging.** Every SQE's `user_data` is encoded with a tag byte in the
high bits plus a payload:

```csharp
private static ulong EncodeIoUringUserData(byte tag, ulong payload) =>
    ((ulong)tag << IoUringUserDataTagShift) | (payload & IoUringUserDataPayloadMask);
```

Tags discriminate dispatch: `TagWakeupSignal` (3) is handled inline on the loop;
`TagReservedCompletion` (2) routes to a generation-tagged **completion slot**.
The payload packs a 16-bit slot index + 40-bit generation, so a stale CQE for a
recycled slot is detected and dropped rather than mis-delivered.

**The SQE writers** (`SocketAsyncEngine.IoUringSqeWriters.Linux.cs`) mirror the
kernel field aliasing precisely. Accept and multishot accept share one writer:

```csharp
// WriteAcceptSqe — multishot toggles the ioprio bit
sqe->Opcode  = IoUringOpcodes.Accept;
sqe->Ioprio  = multishot ? IoUringConstants.AcceptMultishot : (ushort)0; // IORING_ACCEPT_MULTISHOT
sqe->Addr    = (ulong)(nuint)socketAddress;
sqe->Off     = (ulong)(nuint)socketAddressLengthPtr; // kernel aliases addr2 at sqe->off
sqe->RwFlags = IoUringConstants.AcceptFlags;          // SOCK_CLOEXEC | SOCK_NONBLOCK
```

Provided-buffer (multishot-capable) recv sets `IOSQE_BUFFER_SELECT` and the
`IORING_RECV_MULTISHOT` ioprio bit, passing a buffer **group id** instead of a
user buffer:

```csharp
// WriteProvidedBufferRecvSqe
sqe->Opcode   = IoUringOpcodes.Recv;
sqe->Flags    = (byte)(sqeFlags | IoUringConstants.SqeBufferSelect); // IOSQE_BUFFER_SELECT
sqe->Ioprio   = ioprio;     // IORING_RECV_MULTISHOT for the multishot strategy
sqe->Addr     = 0;          // no user buffer; kernel selects from the buffer group
sqe->BufIndex = bufferGroupId;
```

**Multishot accept/recv** mean one SQE arms a long-lived operation that posts
_many_ CQEs (each carrying `IORING_CQE_F_MORE`), so the runtime accepts
connections or receives datagrams/segments without re-submitting per event. The
per-socket arming/disarming and early-data buffering live in
`SocketAsyncContext.IoUring.Linux.cs` (`_multishotAcceptState`,
`_persistentMultishotRecvArmed`, `BufferedPersistentMultishotRecvData`).

**Receive strategy ladder.** `RecomputeIoUringRecvStrategy` picks the strongest
supported path: `MultishotProvidedBuffer` → `OneshotProvidedBuffer` →
`PlainUserBuffer`, degrading automatically under provided-buffer pressure.

**Recv buffer ownership.** With provided buffer rings the kernel selects a
buffer from a registered ring and reports the chosen buffer id in the CQE flags
(`IORING_CQE_F_BUFFER`, `>> IORING_CQE_BUFFER_SHIFT`), so receives need no buffer
posted per call — the key throughput win for many-small-reads workloads.

**Zero-copy send.** For payloads ≥ `ZeroCopySendThreshold` (16 KiB) and when
`SEND_ZC` (Linux 6.0) / `SENDMSG_ZC` (Linux 6.1) are probed-supported, the
engine uses the zero-copy opcodes. These produce a _second_ `NOTIF` CQE
(`IORING_CQE_F_NOTIF`) once the kernel no longer needs the pinned buffer; the
completion slot stays "pending" until that NOTIF arrives — the exact behavior
underpinning the 6.1 version floor.

#### Multi-engine accept distribution and CPU affinity

With `io_uring` enabled, `LinuxInitializeEngineAffinityTopology` reads
`/sys/devices/system/cpu/*/topology` to map physical cores, creates **one engine
per physical core**, and pins each event-loop thread (`SchedSetAffinity`).
Listening sockets are spread across engines via `SO_REUSEPORT` shadow listeners
(kill-switchable through `DOTNET_SYSTEM_NET_SOCKETS_IO_URING_DISABLE_REUSEPORT_ACCEPT`),
giving a shard-per-core shape reminiscent of [Glommio][glommio]/[Monoio][monoio],
while still feeding the shared managed ThreadPool for continuations.

---

## Performance approach

- **Eliminate the readiness round-trip.** The epoll engine costs (at minimum)
  one `epoll_wait` wake **plus** a `recv`/`send` syscall per ready event; the
  `io_uring` engine batches submissions and completions through shared rings and
  the kernel performs the I/O, collapsing syscalls. The PR reports an expected
  **~15–40% reduction in per-request CPU** for Kestrel HTTP/1.1 keep-alive
  (TechEmpower plaintext).
- **Batch the syscall boundary.** `DEFER_TASKRUN` + `SINGLE_ISSUER` keep kernel
  task-work off every syscall and concentrate it at the loop's
  `io_uring_enter`, lowering event-thread CPU vs. `COOP_TASKRUN`.
- **Provided buffer rings** remove per-receive buffer posting and let many
  small reads share a kernel-managed buffer pool — the dominant cost in
  connection-dense servers.
- **Multishot** amortizes submission: one `accept`/`recv` SQE serves a stream
  of connections/segments.
- **Optional `SQPOLL`** lets a kernel thread poll the SQ so the app can submit
  without any `io_uring_enter` syscall at all (opt-in; mutually exclusive with
  `DEFER_TASKRUN`).
- **Cache-friendly layout.** The 24-byte `IoUringCompletionSlot` keeps hot
  per-op state compact; pointer-heavy native state is split into separate
  storage. The `[StackTraceHidden]`/`NoInlining` event-handler split exists
  specifically to avoid the JIT extending local lifetimes and pinning
  `SocketAsyncContext`s (see [issue #37064][issue37064]).
- **Same ThreadPool dispatch.** Both engines push completions to the
  `ThreadPool` as `IThreadPoolWorkItem`s with single-worker-request throttling,
  so the `io_uring` engine inherits the existing scheduling/latency tuning rather
  than inventing a new scheduler.

---

## Strengths

- **Drop-in for users.** No public API changes; `Socket.*Async` /
  `SocketAsyncEventArgs` / `ValueTask` are unchanged. Kestrel/ASP.NET Core
  benefit transparently.
- **True Proactor on Linux**, matching the Windows IOCP model and removing the
  readiness→syscall translation that the epoll engine cannot avoid.
- **Robust capability negotiation.** Setup-flag peeling + opcode probing +
  per-feature kill switches mean it adapts to whatever the kernel offers.
- **Safe fallback.** Any init failure quietly reverts to the battle-tested
  epoll engine; flag-on on an old kernel never breaks sockets.
- **liburing-free.** A ~540-line C shim plus direct managed ring access; no
  external native dependency, minimal new attack surface, ABI pinned by
  `c_static_assert`.
- **Deep observability.** Stable PollingCounters + diagnostic metrics
  (fallback counts, provided-buffer depletion, SQPOLL-negotiated warnings)
  ship with the PR.

## Weaknesses

- **Not merged / not shipped.** [PR #124374][PR124374] is WIP and opt-in only;
  none of this is in a released .NET as of this writing.
- **Linux-only and kernel-gated.** Requires Linux ≥ 6.1; macOS/BSD stay on
  `kqueue`, Windows on IOCP.
- **Large managed surface.** ~14.5k lines of intricate, lifetime-sensitive
  unsafe C# (manual mmap, generation-tagged slots, NOTIF sequencing, CQ
  overflow recovery) — a substantial maintenance and correctness burden vs. the
  comparatively small epoll engine.
- **Memory scales with engines.** One engine + rings + slot pool per physical
  core; the slot pool alone is sized at 2× CQ entries (~8192 slots with default
  CQ sizing) per engine.
- **Feature interactions.** `SEND_ZC` NOTIF deferral, multishot lifetimes, and
  provided-buffer depletion all add edge cases (CQ-overflow recovery, orphaned
  ZC slots) the epoll engine simply doesn't have.

---

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                 | Trade-off                                                                    |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Keep one async API; swap the engine via `partial class` per platform     | Users and ASP.NET Core get `io_uring` transparently; no API churn         | Engine code forks into many `*.Linux.cs` partials; hard to follow end-to-end |
| Reactor (epoll) ships; Proactor (`io_uring`) is opt-in behind a flag     | De-risks a huge change; epoll remains the default until proven            | Two Unix backends to maintain and test in parallel                           |
| Defer `io_uring` init onto the event-loop thread                         | `SINGLE_ISSUER`/`DEFER_TASKRUN` need a stable `submitter_task`            | Socket registration must block on `_ioUringInitSignal` until init completes  |
| Negotiate setup flags by peeling on `EINVAL` (newest-first)              | One code path adapts from 6.1 up to latest kernels                        | Silent capability degradation; behavior varies by kernel                     |
| Probe every opcode (`REGISTER_PROBE`) instead of trusting kernel version | Avoids assuming features that may be backported/absent                    | Extra setup cost; more branching in the prep paths                           |
| Min kernel = 6.1 (not 5.x)                                               | `SEND_ZC` `NOTIF` CQE sequencing stabilized in 6.1                        | Leaves 5.x `io_uring` kernels on epoll despite partial `io_uring` support    |
| Direct managed ring access; tiny C shim, no liburing                     | No native dependency; ABI pinned by static asserts; small attack surface  | Must hand-mirror kernel struct layouts and ABI invariants in C#              |
| Tagged `user_data` (tag byte + slot index + generation)                  | O(1) CQE→operation routing; stale-CQE detection on slot reuse             | 16-bit slot index caps ~65 536 concurrent slots per engine                   |
| One engine per physical core + `SO_REUSEPORT` accept spread              | Shard-per-core scaling for accept-heavy servers                           | Memory and ring count scale with core count                                  |
| Dispatch completions to the shared ThreadPool (not the event thread)     | A slow user callback can't stall event delivery; reuses ThreadPool tuning | Extra hand-off + scheduling latency vs. inlining (opt-in inlining exists)    |

---

## Sources

- [dotnet/runtime — repository][dotnet/runtime]
- [PR #124374 — "Use io_uring for sockets on Linux" (benaadams, WIP)][PR124374]
- [Issue #753 — "Use io_uring instead of epoll when supported"][issue753]
- [Issue #37064 — JIT local-lifetime / context-pinning discussion][issue37064]
- [`SocketAsyncEngine.Unix.cs`][engineUnix]
- [`SocketAsyncContext.Unix.cs`][ctxUnix]
- [`pal_io_uring_shim.h`][shimH] / [`pal_io_uring_shim.c`][shimC]
- [SocketAsyncEventArgs — Microsoft Learn][SAEA docs]
- [io_uring_setup(2) — man7.org][setupman]
- [io_uring_enter(2) — man7.org][enterman]
- [io_uring_register_buf_ring(3) — man7.org][bufringman]
- [io_uring_prep_send_zc(3) — man7.org][sendzcman]
- [io_uring and networking in 2023 — liburing wiki][io-uring-net-2023]
- [Microsoft .NET on Linux io_uring patches — Phoronix][phoronix]
- Related sparkles docs: [io_uring overview][iouring] · [io_uring features][features] · [Tokio][tokio] · [Glommio][glommio] · [Monoio][monoio] · [Seastar][seastar] · [Go netpoller][go] · [comparison][comparison] · [Eio (effects)][eio]

<!-- References -->

[dotnet/runtime]: https://github.com/dotnet/runtime
[PR124374]: https://github.com/dotnet/runtime/pull/124374
[issue753]: https://github.com/dotnet/runtime/issues/753
[issue37064]: https://github.com/dotnet/runtime/issues/37064
[benaadams]: https://github.com/benaadams
[SAEA docs]: https://learn.microsoft.com/en-us/dotnet/api/system.net.sockets.socketasynceventargs
[setupman]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[enterman]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[bufringman]: https://man7.org/linux/man-pages/man3/io_uring_register_buf_ring.3.html
[sendzcman]: https://man7.org/linux/man-pages/man3/io_uring_prep_send_zc.3.html
[io-uring-net-2023]: https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023
[phoronix]: https://www.phoronix.com/news/Microsoft-dotNET-IO-uring
[engineUnix]: https://github.com/dotnet/runtime/blob/main/src/libraries/System.Net.Sockets/src/System/Net/Sockets/SocketAsyncEngine.Unix.cs
[ctxUnix]: https://github.com/dotnet/runtime/blob/main/src/libraries/System.Net.Sockets/src/System/Net/Sockets/SocketAsyncContext.Unix.cs
[shimH]: https://github.com/dotnet/runtime/blob/2f707114e84b64ac9a895c3277b5c8a413c4404e/src/native/libs/System.Native/pal_io_uring_shim.h
[shimC]: https://github.com/dotnet/runtime/blob/2f707114e84b64ac9a895c3277b5c8a413c4404e/src/native/libs/System.Native/pal_io_uring_shim.c
[iouring]: ./io-uring/index.md
[features]: ./io-uring/features.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[seastar]: ./seastar.md
[go]: ./go-netpoller.md
[comparison]: ./comparison.md
[eio]: ../algebraic-effects/ocaml-eio.md
