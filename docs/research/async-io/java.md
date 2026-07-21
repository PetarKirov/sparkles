# Java (JUring, JDK NIO, Netty io_uring, Project Loom)

The Java async-I/O landscape: a JDK baseline with no first-class `io_uring`, third-party FFI bindings (JUring) and Netty's transport that bring `io_uring` to the JVM, and Project Loom virtual threads that make blocking-style code scale as an alternative to explicit async.

| Field         | Value                                                                                                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Java (JDK 21 LTS baseline; JUring needs JDK 22+ for the FFM API; benchmarks build on JDK 25)                                                                                      |
| License       | JUring: Unlicense (public domain) · Netty: Apache-2.0 · OpenJDK: GPL-2.0 + Classpath Exception                                                                                    |
| Repository    | [JUring GitHub] · [Netty io_uring (archived incubator)] · [OpenJDK Loom]                                                                                                          |
| Documentation | [JEP 444 (Virtual Threads)] · [JEP 505 (Structured Concurrency)] · [Java FFM API]                                                                                                 |
| Key Authors   | David Vlijmincx (JUring) · Norman Maurer (Netty) · Ron Pressler, Alan Bateman (Loom)                                                                                              |
| Pattern       | JDK NIO: Reactor (epoll/kqueue/IOCP) · JDK NIO.2: Proactor-ish (`AsynchronousChannel`) · JUring/Netty: Proactor (`io_uring`) · Loom: synchronous threads over a Reactor netpoller |

---

## Overview

### What It Solves

Java has had non-blocking I/O since JDK 1.4 (NIO `Selector`) and a completion-based asynchronous channel API since JDK 7 (NIO.2 `AsynchronousChannel`). Both are mature and portable, but neither uses Linux's [io_uring][io-uring]: the JDK's selector providers are still built on `epoll` (Linux), `kqueue` (BSD/macOS) and IOCP (Windows), and the NIO.2 `AsynchronousChannelGroup` runs a thread pool that calls `epoll`/`kqueue`/IOCP under the hood. There is **no first-class `io_uring` backend in the JDK** as of JDK 25, and no targeted JEP to add one.

That gap is filled by two distinct strategies in the ecosystem, plus a third that sidesteps explicit async entirely:

1. **FFI bindings to liburing** — [JUring][JUring GitHub] uses the [Foreign Function & Memory (FFM) API][Java FFM API] (Project Panama) to call `liburing` directly, exposing a Proactor-style submission/completion ring to Java with off-heap, GC-free hot paths.
2. **A production network transport** — [Netty's io_uring transport][Netty io_uring (archived incubator)] reimplements Netty's `EventLoopGroup` over `io_uring`, transparently swapping in for the epoll transport behind the same channel API.
3. **Loom virtual threads** — [Project Loom][OpenJDK Loom] makes the thread-per-request, blocking-style programming model scale to millions of threads. It is an _alternative_ to explicit async I/O: code reads as synchronous, while the JDK multiplexes virtual threads onto a small carrier pool using the existing NIO netpoller. Loom does not itself use `io_uring`, but it composes with `io_uring`-backed clients.

### Design Philosophy

The three approaches embody three philosophies. JUring is _maximal control_: it surfaces SQEs, CQEs, fixed buffers, registered files, and multishot accept almost one-to-one with `liburing`, trading portability and safety for raw throughput. Netty is _transparent substitution_: keep the channel/pipeline API, change only the transport. Loom is _conservative integration_: don't introduce a new programming model at all — make `java.lang.Thread` cheap enough that blocking code scales. For deeper treatment of Loom as a concurrency mechanism (continuations, structured concurrency), see [Project Loom in the effects corpus][java-loom].

---

## The JDK baseline (no io_uring)

### NIO Selectors — Reactor

Introduced in JDK 1.4, `java.nio.channels.Selector` is a readiness-based (Reactor) API. An application registers `SelectableChannel`s with interest sets (`OP_READ`, `OP_WRITE`, `OP_ACCEPT`, `OP_CONNECT`), calls `select()` to block until channels are ready, and then performs the actual non-blocking `read`/`write`. The platform `SelectorProvider` is chosen at runtime:

| Platform    | Selector provider         | Async channel provider               | Kernel mechanism |
| ----------- | ------------------------- | ------------------------------------ | ---------------- |
| Linux       | `EPollSelectorProvider`   | `LinuxAsynchronousChannelProvider`   | `epoll`          |
| BSD / macOS | `KQueueSelectorProvider`  | `BsdAsynchronousChannelProvider`     | `kqueue`         |
| Other Unix  | `PollSelectorProvider`    | —                                    | `poll`           |
| Windows     | `WindowsSelectorProvider` | `WindowsAsynchronousChannelProvider` | IOCP             |

This is the _netpoller_ that nearly every Java networking framework (Netty's default NIO transport, Jetty, Vert.x, gRPC-Java) sits on, and the same mechanism that Loom's virtual-thread scheduler uses to park a virtual thread on a socket without blocking a carrier.

### NIO.2 AsynchronousChannel — Proactor-ish

JDK 7 added `java.nio.channels.AsynchronousSocketChannel` / `AsynchronousFileChannel`, a completion-based API closer to a Proactor: operations return a `Future<Integer>` or invoke a `CompletionHandler<V,A>` when the operation finishes. On Linux, however, this is _not_ kernel-async — the `AsynchronousChannelGroup` owns a thread pool that performs the blocking syscall (or an `epoll` readiness wait plus a non-blocking transfer) and dispatches the completion callback. So the API shape is Proactor, but the implementation is a Reactor-plus-threadpool emulation. This is precisely the kind of emulation that a real `io_uring` Proactor (JUring, Netty `io_uring`) makes unnecessary on Linux.

A comparison of these readiness vs completion models across runtimes lives in [primitives][primitives] and [techniques][techniques]; the broader cross-language picture is in [the index][index] and [comparison][comparison].

---

## JUring — a Panama/FFM binding to liburing

> Source: `java/JUring/src/main/java/com/davidvlijmincx/lio/api/`. The repository's own `README.md` lists requirements as **Linux kernel 5.1+**, **liburing installed**, and **Java 22+** (for the FFM API); the build `pom.xml` targets Java 25.

### Core abstractions and types

JUring is layered into three records/classes:

- **`JUring`** (`JUring.java`) — the public, GC-friendly submission API. Each `prepare*` method writes one SQE and returns a `long` **operation id** the caller later matches against a completion. It also owns the registered-buffer index pool and the optional `ReadBufferPool`.
- **`LibUringDispatcher`** (`LibUringDispatcher.java`) — a `record` holding the `liburing` `MethodHandle`s and the off-heap ring; it does the actual `liburing` calls, decodes CQEs and constructs `Result` objects.
- **`LibCDispatcher`** (`LibCDispatcher.java`) — a sibling `record` binding raw libc (`malloc`/`calloc`/`free`, `socket`/`bind`/`listen`/`setsockopt`, `open`/`close`, `strerror`) for the buffers and sockets JUring manages itself.

Every native function is modeled as a tiny single-method interface under `functions/` (e.g. `PrepareRead`, `PrepareMultishotAccept`, `GetSqe`, `WaitCqe`, `PeekBatchCqe`, `CqAdvance`, `RegisterBuffers`, `RegisterFiles`). The dispatcher binds each symbol once and adapts the resulting `MethodHandle` into that interface with `MethodHandleProxies.asInterfaceInstance`:

```java
// LibUringDispatcher.java
private static <T> T libLink(Class<T> type, String name, FunctionDescriptor descriptor, boolean critical) {
    MemorySegment symbol = liburing.findOrThrow(name);
    MethodHandle handle = linker.downcallHandle(symbol, descriptor, Linker.Option.critical(critical));
    return MethodHandleProxies.asInterfaceInstance(type, handle);
}
```

The library is loaded as `liburing-ffi.so` via `SymbolLookup.libraryLookup(...)` — note this is the `liburing-ffi` flavour, the build of liburing whose `io_uring_prep_*` helpers are real exported functions (rather than `static inline` in headers) so that an FFI caller can link them.

`Linker.Option.critical(...)` marks the hottest calls (`io_uring_get_sqe`, `io_uring_submit`, `io_uring_sqe_set_flags`, `io_uring_cq_advance`, `io_uring_cqe_seen`, libc `malloc`/`free`) as _critical downcalls_, which skip the thread-state transition for short, non-blocking native calls — a measurable win on the submission hot path.

### Submission API — the `prepare*` family

The `JUring` surface maps directly onto `io_uring` opcodes. Each method has overloads taking either a `FileDescriptor` (regular fd) or an `int indexFD` (a slot in the _registered files_ table, which sets `IOSQE_FIXED_FILE`):

| `JUring` method                            | liburing helper                              | Notes                                                                |
| ------------------------------------------ | -------------------------------------------- | -------------------------------------------------------------------- |
| `prepareRead` / `prepareWrite`             | `io_uring_prep_read` / `_write`              | malloc'd buffer per op; freed/returned on completion                 |
| `prepareReadPooled`                        | `io_uring_prep_read`                         | buffer drawn from `ReadBufferPool`, returned via `checkInReadBuffer` |
| `prepareReadFixed` / `prepareWriteFixed`   | `io_uring_prep_read_fixed` / `_write_fixed`  | uses a _registered_ buffer by index                                  |
| `prepareReadv` / `prepareWritev`           | `io_uring_prep_readv` / `_writev`            | scatter/gather over an `iovec` block                                 |
| `prepareReadvFixed` / `prepareWritevFixed` | `io_uring_prep_readv` / `_writev`            | iovec bases point into registered buffers                            |
| `prepareOpen` / `prepareOpenDirect`        | `io_uring_prep_openat` / `_openat_direct`    | direct variant places the fd into a registered slot                  |
| `prepareClose` / `prepareCloseDirect`      | `io_uring_prep_close` / `_close_direct`      |                                                                      |
| `prepareAccept` / `prepareMultishotAccept` | `io_uring_prep_accept` / `_multishot_accept` | multishot keeps one SQE producing many CQEs                          |
| `prepareConnect`                           | `io_uring_prep_connect`                      | malloc's a `sockaddr_in` that outlives the stack frame               |
| `prepareRecv` / `prepareSend`              | `io_uring_prep_recv` / `_send`               | `*_EXT` variants pass a caller-owned buffer not freed on completion  |
| `prepareCancel`                            | `io_uring_prep_cancel64`                     | cancels by 64-bit `user_data` value                                  |

A `prepare*` call does three things: allocate off-heap user-data, grab and configure an SQE, and attach the user-data pointer as the SQE's `user_data`:

```java
// JUring.java — the read path (simplified)
private long prepareReadInternal(int fdOrIndex, int readSize, long offset,
                                 SqeOptions[] sqeOptions, boolean fixedFile) {
    long address  = NativeDispatcher.C.mallocAddress(readSize);
    long userData = ioUring.allocateUserData(address, fdOrIndex, OperationType.READ, address);
    MemorySegment sqe = getSqe(sqeOptions, fixedFile);   // io_uring_get_sqe + set flags
    ioUring.prepareRead(sqe, fdOrIndex, address, readSize, offset);
    ioUring.setUserData(sqe, userData);                  // io_uring_sqe_set_data
    return address;                                       // op id returned to caller
}
```

`getSqe` combines the per-op `SqeOptions` flags (`IOSQE_FIXED_FILE`, `IOSQE_IO_LINK`, `IOSQE_ASYNC`, `IOSQE_CQE_SKIP_SUCCESS`, …, from the `SqeOptions` enum) and, for registered-file ops, ORs in `IOSQE_FIXED_FILE`. Ring setup flags (`IORING_SETUP_SQPOLL`, `IORING_SETUP_COOP_TASKRUN`, `IORING_SETUP_DEFER_TASKRUN`, `IORING_SETUP_SINGLE_ISSUER`, etc.) are the `IoUringOptions` enum, passed at `new JUring(queueDepth, ...)`.

### The ZeroGc layer — off-heap CQE and user-data

The defining characteristic of JUring is that the completion hot path touches **no Java heap and allocates no per-op objects** beyond the returned `Result` record. Two helper classes decode native structs directly through `VarHandle`s anchored on a single "global" segment that re-interprets all of memory:

```java
// ZeroGcCqe.java — reading io_uring_cqe fields by raw address
private static final MemorySegment GLOBAL_MEMORY =
        MemorySegment.ofAddress(0L).reinterpret(Long.MAX_VALUE);

static long getUserData(long cqeAddress) { return (long) VH_USER_DATA.get(GLOBAL_MEMORY, cqeAddress); }
static int  getRes(long cqeAddress)      { return (int)  VH_RES.get(GLOBAL_MEMORY, cqeAddress); }
static int  getFlags(long cqeAddress)    { return (int)  VH_FLAGS.get(GLOBAL_MEMORY, cqeAddress); }
```

`ZeroGcUserData` defines the off-heap control block JUring associates with each in-flight op — `{ long id; void* buffer; int fd; int type; int bindex; }` — and reads/writes its fields the same way. The `type` field stores an `OperationType` ordinal so the completion handler knows how to interpret `res` and how to reclaim the buffer. Crucially, these control blocks are _pooled_, not malloc'd per op:

```java
// UserDataPool.java — a free-list of pre-allocated off-heap control blocks
long checkOut() {
    if (top == 0) return NativeDispatcher.C.mallocAddress(ZeroGcUserData.getByteSize());
    return slots[--top];
}
void checkIn(long address) {
    if (top < slots.length) slots[top++] = address;
    else NativeDispatcher.C.free(address);
}
```

`IovecBlockPool` and `ReadBufferPool` apply the same pooling idea to the `iovec` arrays used by scatter/gather and to read buffers, so steady-state operation does no allocation on either the JVM or the C heap.

### Result sealed types

Completions are decoded into a closed algebra. `Result` is a sealed interface with one `id()` accessor; each operation family yields a specific `record`:

```java
// Result.java
public sealed interface Result permits AcceptResult, CloseResult, ConnectResult, OpenResult,
        ReadResult, ReadResultFixed, ReadvResult, RecvResult, SendResult, WriteResult {
    long id();
}
```

`LibUringDispatcher.getResultFromCqe` is a single exhaustive `switch` over `OperationType` that (a) builds the right `Result`, (b) frees or retains the buffer per ownership rules, and (c) returns the user-data block to the pool. The ownership policy is encoded per case:

- `READ`/`RECV` return a `ReadResult`/`RecvResult` wrapping the malloc'd buffer; the caller frees it (`ReadResult` is `AutoCloseable`, calling `freeBuffer()`).
- `WRITE`/`SEND`/`OPEN`/`CONNECT` free their malloc'd buffer immediately.
- `*_FIXED` and `*_EXT` variants leave registered or caller-owned buffers untouched.
- `MULTISHOT_ACCEPT` inspects `IORING_CQE_F_MORE` and only reclaims the user-data block when no further CQEs will arrive:

```java
// LibUringDispatcher.java
case MULTISHOT_ACCEPT -> {
    boolean morecoming = (cqeFlags & IORING_CQE_F_MORE) != 0;
    if (!morecoming) {           // multishot finished/cancelled/errored — reclaim
        long addr = ZeroGcUserData.getBufferAddress(userDataAddress);
        if (addr != 0L) libCDispatcher.free(addr);
        userDataPool.checkIn(userDataAddress);
    }
    yield new AcceptResult(id, (int) result);   // result = accepted fd or -errno
}
```

### Completion reaping

Three reaping modes mirror `liburing`:

| `JUring` method         | liburing helpers                                                           | Semantics                      |
| ----------------------- | -------------------------------------------------------------------------- | ------------------------------ |
| `waitForResult()`       | `io_uring_wait_cqe` + `io_uring_cqe_seen`                                  | block for one completion       |
| `waitForBatchResult(n)` | `io_uring_wait_cqe_nr` + `io_uring_peek_batch_cqe` + `io_uring_cq_advance` | block until `n`, drain a batch |
| `peekForBatchResult(n)` | `io_uring_peek_batch_cqe` + `io_uring_cq_advance`                          | non-blocking drain             |

### Fixed files, fixed buffers, shared work queues

JUring exposes the full set of `io_uring` registration optimizations:

- **Registered files** — `registerFiles(FileDescriptor...)` / `registerFilesUpdate` populate the kernel's fixed-file table; subsequent ops use the `int indexFD` overloads with `IOSQE_FIXED_FILE`, avoiding per-op fd refcount churn. The README attributes the headline "+489% vs pre-opened FileChannel at 4 KB reads" number to this path.
- **Registered (fixed) buffers** — `registerBuffers(size, n)` pins buffers with the kernel; `checkOutBuffer`/`checkInBuffer` manage an index free-list, and `prepareReadFixed`/`prepareWriteFixed` use them to skip per-op page pinning.
- **Shared worker ring** — `getSharedWorkerRing(queueDepth)` creates a second ring with `IORING_SETUP_ATTACH_WQ` and `io_uring_params.wq_fd` set to the parent ring's fd, so multiple rings share one async worker-thread backend.

### Blocking facade for virtual threads

`JUringBlocking` wraps a `JUring` with a daemon poller thread and a `ConcurrentHashMap<Long, CompletableFuture<? extends Result>>` keyed by op id. Each `prepare*` returns a `Future<…>`; the poller calls `peekForBatchResult(100)` in a loop and completes the matching future. This is the bridge to Loom: a **virtual thread** can call `future.get()` and block in idiomatic synchronous style while the single platform poller thread drives the ring. The repo's own benchmarks include a "JUring Blocking + VThreads" category that beats `FileChannel` + virtual threads by up to ~138% at 64 KB reads.

```java
// JUringBlocking.java — poller completes futures by op id
jUring.peekForBatchResult(100).forEach(result -> {
    var request = requests.remove(result.id());
    switch (result) {
        case ReadResult r  -> ((CompletableFuture<ReadResult>) request).complete(r);
        case WriteResult r -> ((CompletableFuture<WriteResult>) request).complete(r);
        // ... one case per Result subtype (exhaustive over the sealed hierarchy)
    }
});
```

---

## Netty io_uring transport

[Netty's io_uring transport][Netty io_uring (archived incubator)] started life as a separate incubator artifact (`io.netty.incubator:netty-incubator-transport-native-io_uring`), reaching `0.0.25.Final` in February 2024. The incubator repository was **archived on 3 April 2025** and the transport was **merged into the Netty 4.2 line**, graduating from incubator to a supported transport.

Architecturally it is a drop-in `EventLoopGroup` implementation: an application that ran on the epoll transport via `EpollEventLoopGroup` + `EpollSocketChannel` swaps in the `io_uring` equivalents (historically `IOUringEventLoopGroup` + `IOUringSocketChannel` / `IOUringServerSocketChannel`; the 4.2 line moves to the unified `IoEventLoopGroup` + `IoUringIoHandler` factory model used across Netty's native transports). The channel/pipeline/`ByteBuf` programming model is unchanged; only the readiness-vs-completion machinery behind the event loop differs.

Each `io_uring` event loop owns one ring. Instead of an `epoll_wait` readiness loop followed by non-blocking `read`/`write`, the loop submits read/write/accept/connect SQEs and reaps CQEs, mapping completions back onto Netty's channel callbacks. Netty's own benchmarking has repeatedly shown the `io_uring` transport offering little or no throughput advantage over the highly tuned epoll transport for typical request/response network workloads — the win is workload-dependent — which is part of why it incubated for years before merging. For the Reactor framework this competes with conceptually, compare [libuv][libuv] and the Rust/Go runtimes in [tokio][tokio] and [go-netpoller][go-netpoller].

---

## Project Loom — virtual threads as the async alternative

### Virtual threads (JEP 444, final in Java 21)

A _virtual thread_ is a `java.lang.Thread` scheduled by the JVM, not the OS. Millions can exist at once; they are multiplexed onto a small pool of **carrier threads** (a `ForkJoinPool` of platform threads). When a virtual thread performs a blocking operation that the JDK knows how to make non-blocking — a socket `read`, a `Future.get`, a `BlockingQueue.take`, `Thread.sleep` — the runtime _unmounts_ it from its carrier, parks a continuation, and lets the carrier run another virtual thread. The blocked operation is registered with the same NIO netpoller (`epoll`/`kqueue`/IOCP) that selectors use; when it becomes ready, the virtual thread is re-mounted and resumes. The result: thread-per-request code with the scalability of an event loop, but no callbacks, no `CompletableFuture` chains, no colored functions.

```java
// Idiomatic Loom: a virtual thread per connection, blocking style
try (var serverChannel = ServerSocketChannel.open()) {
    serverChannel.bind(new InetSocketAddress(8080));
    while (true) {
        var ch = serverChannel.accept();           // parks the carrier-free vthread
        Thread.startVirtualThread(() -> handle(ch)); // cheap: millions are fine
    }
}
```

### Structured concurrency (JEP 505) and the relationship to io_uring

`StructuredTaskScope` (a preview API; fifth preview is **JEP 505** in JDK 25, which replaced the public constructors with static factory methods) lets a parent fork subtasks as virtual threads and join them as a unit, with guaranteed termination and propagation of errors/cancellation when the scope closes. This is Java's answer to the structured-concurrency model that [Eio's `Switch`][ocaml-eio] provides in OCaml and that Loom's design notes explicitly cite.

Loom does **not** use `io_uring` and there is no announced plan to back the netpoller with it. But the two compose cleanly along two axes:

1. **Loom over a netpoller for sockets.** For network I/O the carrier-free unmounting already gives event-loop-class scalability using `epoll`; an `io_uring` netpoller would be an _implementation_ swap invisible to user code, not a new API. No JEP targets this today.
2. **Loom over an `io_uring` client for files.** Loom's weak spot is the **filesystem**: regular-file reads/writes have no readiness model, so `FileInputStream`/`FileChannel` operations historically **pin** the virtual thread to its carrier and block it. This is exactly where an `io_uring`-backed blocking facade shines — `JUringBlocking` lets a virtual thread `future.get()` on a real kernel-async file read, so the carrier is freed even for file I/O. JUring's own "Blocking + VThreads" benchmark is built on this combination.

### Pinning, and how it has shrunk

Early Loom pinned virtual threads inside `synchronized` blocks and certain native calls. **JEP 491** (final in JDK 24) removes nearly all monitor-related pinning, so blocking inside a `synchronized` region no longer holds the carrier. Filesystem operations and a few class-loading edge cases remain the notable pinning sources — reinforcing why a kernel-async file path (`io_uring` via JUring) is complementary to Loom rather than redundant. A fuller treatment of continuations, scoped values, and the scheduler is in [the Loom effects deep-dive][java-loom]; the broader relationship between effects/continuations and event loops is in [effects-and-event-loops][effects-and-event-loops].

---

## How it works — submission/completion flow (JUring)

Putting the JUring pieces together, a single read op flows as:

1. **Prepare.** `prepareRead(...)` checks out an off-heap `ZeroGcUserData` block from `UserDataPool`, allocates or pools the data buffer, grabs an SQE with `io_uring_get_sqe`, sets flags, calls `io_uring_prep_read`, and stores the user-data block's address as the SQE's `user_data` via `io_uring_sqe_set_data`. Returns a `long` op id.
2. **Submit.** `submit()` calls `io_uring_submit`, handing the batch of SQEs to the kernel in one syscall (or zero syscalls under `IORING_SETUP_SQPOLL`).
3. **Kernel.** The kernel performs the read asynchronously and posts a CQE with `{user_data, res, flags}`.
4. **Reap.** `waitForResult()` / `peekForBatchResult(n)` reads the CQE through `ZeroGcCqe` by raw address, looks up `OperationType` from the user-data block, and `getResultFromCqe` builds the `Result`, applies buffer-ownership rules, advances the CQ ring (`io_uring_cq_advance`), and returns the user-data block to the pool.
5. **Match.** The caller (or `JUringBlocking`'s poller) matches `result.id()` to the originating op.

Exactly which opcodes are used, their kernel-version gating, and the multishot/registered-resource features referenced here are catalogued in [the io_uring opcode reference][opcodes-reference], [features][features], and [timeline][timeline].

---

## Performance approach

- **Syscall amortization.** Batched submission (`io_uring_submit` for many SQEs) and optional `IORING_SETUP_SQPOLL` reduce or eliminate per-op syscalls — the core `io_uring` advantage over the per-op `read`/`write` syscalls behind `FileChannel`.
- **Zero steady-state allocation.** JUring's `UserDataPool`, `IovecBlockPool`, and `ReadBufferPool` mean the hot path allocates nothing on the JVM or C heap after warm-up; CQE/user-data decoding goes through `VarHandle`s on a reinterpreted global segment, never copying structs into Java objects.
- **Critical downcalls.** `Linker.Option.critical(true)` on the short non-blocking calls skips the JNI-style thread-state transition.
- **Registered files/buffers.** Pinning fds and buffers with the kernel removes per-op refcounting and page-pinning; the README's largest speedups (+231% to +489%) come from the registered-files read path.
- **Loom's contribution** is orthogonal: it doesn't speed up an individual I/O, it removes the cost of having one (cheap) thread blocked per in-flight request, so a synchronous JUringBlocking + virtual-threads design scales without an explicit reactor.

JUring's README also documents the honest losses: write throughput at **20+ concurrent threads** can fall _behind_ `FileChannel` (−16% to −33% at large buffers), and ring initialization costs a few milliseconds. Netty's `io_uring` transport similarly shows negligible network throughput gains over epoll in Netty's own tests.

---

## Strengths

- **Real kernel-async I/O on the JVM**, including for files, which the JDK's NIO.2 emulates with a thread pool.
- **Full `io_uring` feature surface in JUring** — fixed files, fixed buffers, multishot accept, linked SQEs, cancellation, shared work queues — exposed almost one-to-one with `liburing`.
- **GC-free hot path**: pooled off-heap control blocks and `VarHandle` struct decoding, no per-op Java garbage.
- **Type-safe completions** via a sealed `Result` hierarchy and exhaustive pattern-match decoding.
- **Pure-Java FFM bindings** (no JNI, no native build step in JUring beyond a present `liburing-ffi.so`).
- **Netty path is transparent**: existing channel/pipeline code runs unchanged.
- **Loom makes synchronous code scale**, sidestepping callback hell entirely, and composes with `io_uring`-backed blocking facades.

## Weaknesses

- **No first-class JDK io_uring** — every `io_uring` path is third-party, with the versioning and support implications that follow.
- **Linux-only and kernel-version-sensitive** (JUring: 5.1+ baseline, with newer features needing newer kernels); JUring also needs JDK 22+ for the FFM API.
- **Manual memory and lifetime management in JUring** — off-heap buffers, `user_data` blocks, and `sockaddr` structs are freed by hand per opcode; misuse is a native crash, not a Java exception. `MemorySegment.ofAddress(0L).reinterpret(Long.MAX_VALUE)` is an all-of-memory escape hatch with no bounds checking.
- **Maturity**: JUring is a single-author `0.1-SNAPSHOT` (public domain), not a hardened production library.
- **Netty `io_uring` shows little net win** over epoll for common network workloads.
- **Loom still pins on filesystem I/O** and a few class-loading edge cases; it does not itself bring `io_uring`.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                          | Trade-off                                                            |
| --------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------- |
| JDK has no `io_uring` backend                       | Portability; epoll/kqueue/IOCP cover all platforms uniformly       | Java misses `io_uring`'s syscall/batching wins without third parties |
| JUring binds `liburing` via FFM (Panama), not JNI   | No native glue code; `MethodHandle`s + critical downcalls are fast | Needs JDK 22+; requires the `liburing-ffi` build of liburing         |
| `ZeroGc*` off-heap structs + `VarHandle` decoding   | No per-op GC garbage; near-C completion latency                    | Unsafe raw-address access; bounds are unchecked                      |
| Pooled `UserDataPool` / `IovecBlockPool`            | Steady-state zero allocation on both heaps                         | Pool sizing tied to queue depth; overflow falls back to malloc/free  |
| Sealed `Result` + exhaustive opcode `switch`        | Type-safe, total decoding and per-op buffer-ownership rules        | Adding an opcode touches the sealed set and the central switch       |
| `JUringBlocking` poller → `CompletableFuture` by id | Lets virtual threads block synchronously over the ring             | A single platform poller thread per ring is a throughput bottleneck  |
| Netty `io_uring` as a drop-in `EventLoopGroup`      | Existing channel/pipeline code is unchanged                        | Net gain over epoll is workload-dependent, often marginal            |
| Loom = cheap threads, not a new async model         | Keeps `Thread`/`synchronized`/debuggers working; no colored fns    | Filesystem I/O still pins; relies on the netpoller, not `io_uring`   |

---

## Sources

- [JUring GitHub] — David Vlijmincx's FFM binding to liburing
- [Netty io_uring (archived incubator)] — incubator repo, archived April 2025, merged into Netty 4.2
- [Netty io_uring 0.0.25.Final release notes]
- [OpenJDK Loom]
- [JEP 444 (Virtual Threads)] — final in Java 21
- [JEP 505 (Structured Concurrency)] — fifth preview, JDK 25
- [JEP 491 (Synchronize Virtual Threads without Pinning)] — final in JDK 24
- [Java FFM API] — `java.lang.foreign` (Project Panama)
- [JVM network servers backed by io_uring (Martin Grigorov)] — selector-provider survey
- [Loom in the effects corpus][java-loom]
- [Eio structured concurrency][ocaml-eio]

<!-- References -->

[JUring GitHub]: https://github.com/davidtos/JUring
[Netty io_uring (archived incubator)]: https://github.com/netty/netty-incubator-transport-io_uring
[Netty io_uring 0.0.25.Final release notes]: https://netty.io/news/2024/02/19/io_uring_0-0-25-Final.html
[OpenJDK Loom]: https://openjdk.org/projects/loom/
[JEP 444 (Virtual Threads)]: https://openjdk.org/jeps/444
[JEP 505 (Structured Concurrency)]: https://openjdk.org/jeps/505
[JEP 491 (Synchronize Virtual Threads without Pinning)]: https://openjdk.org/jeps/491
[Java FFM API]: https://docs.oracle.com/en/java/javase/22/core/foreign-function-and-memory-api.html
[JVM network servers backed by io_uring (Martin Grigorov)]: https://martin-grigorov.medium.com/jvm-network-servers-backed-by-io-uring-244fea58bb19
[index]: ./index.md
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[comparison]: ./comparison.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[tokio]: ./tokio.md
[libuv]: ./libuv.md
[go-netpoller]: ./go-netpoller.md
[io-uring]: ./io-uring/index.md
[features]: ./io-uring/features.md
[timeline]: ./io-uring/timeline.md
[opcodes-reference]: ./io-uring/opcodes-reference.md
[java-loom]: ../algebraic-effects/java-loom.md
[ocaml-eio]: ../algebraic-effects/ocaml-eio.md
