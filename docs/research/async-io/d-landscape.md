# D Language: Existing Async I/O & Event-Loop Options

A survey of what the D ecosystem already provides for asynchronous I/O and event loops — the dominant fiber framework (vibe.d / vibe-core / eventcore), transparent fiber schedulers (Photon), the low-level `io_uring` binding ([during]), and the druntime primitives a new loop would build on — to frame what an `io_uring`-first Sparkles event-horizon library would add.

> **Scope.** This is a _landscape / reference_ doc, not a single-library deep-dive. It maps the field, names real types and file paths from the cloned source trees, verifies version/maintenance status against the upstream repos and the [DUB] registry, and ends with a gap analysis. For the `io_uring` mechanics referenced throughout, see [io_uring overview][io-uring]; for cross-language framing of the same patterns (Tokio, Glommio, Seastar, libuv, …) see the [comparison][comparison].

---

## Overview

D occupies an unusual position in the async-I/O design space. Like Rust and C++, it is a systems language with manual-memory and `@nogc` paths, RAII, and templates; but unlike them, it ships **stackful fibers in its runtime** (`core.thread.Fiber`) and a garbage collector by default. That combination has historically pushed D's async story toward **fiber-per-connection, direct-style blocking-looking code** rather than the `async`/`await` state-machine model of Rust or C#. You write code that _looks_ synchronous; the framework parks the fiber on a would-block and resumes it on readiness.

The ecosystem has three layers worth separating:

| Layer                      | Concern                                         | Representative                           |
| -------------------------- | ----------------------------------------------- | ---------------------------------------- |
| **Runtime primitives**     | Stackful context switch, message passing        | `core.thread.Fiber`, `std.concurrency`   |
| **Event-loop abstraction** | Readiness/completion demultiplexing across OSes | eventcore (drivers), Photon scheduler    |
| **High-level framework**   | Sockets, HTTP, files, RPC with fiber scheduling | vibe-core / vibe.d, Photon + photon-http |
| **Raw kernel binding**     | Direct `io_uring` SQE/CQE access, no scheduling | [during]                                 |

The crucial observation for Sparkles is that **none of the mainstream D frameworks are `io_uring`-first**. vibe.d's default Linux backend is `epoll` (reactor-style readiness), with an _experimental_ `UringEventDriver`; Photon's DLang implementation drives `epoll` on Linux and `kqueue` on macOS. The only mature, up-to-date `io_uring` code is [during] — and it is deliberately a _binding_, not a loop: it provides SQE/CQE building blocks and leaves scheduling to the caller. There is a clear, unoccupied slot for a `@nogc`/`@safe`, completion-first (Proactor) event loop built on a modern `io_uring` feature set.

---

## Options at a glance

| Project                 | Mechanism                                               | Backend(s)                                                                      | `@nogc`/`betterC`                               | Status (mid-2026) | Link                                     |
| ----------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------- | ---------------------------------------- |
| **vibe.d / vibe-core**  | Stackful fibers, direct-style I/O                       | via eventcore                                                                   | No (GC, exceptions)                             | Active, dominant  | [repo][vibe-core] · [docs][vibe-docs]    |
| **eventcore**           | Proactor (callback) driver abstraction                  | epoll, kqueue, IOCP, CFRunLoop, select, libasync, **`io_uring` (experimental)** | Partial (`@nogc`-friendly API, GC handle store) | Active            | [repo][eventcore] · [API][eventcore-api] |
| **Photon (DLang)**      | Stackful fibers + transparent libc syscall interception | epoll (Linux), kqueue (macOS)                                                   | No (GC default)                                 | Active (v0.19.x)  | [repo][photon] · [DUB][photon-dub]       |
| **[during]**            | Low-level `io_uring` SQE/CQE binding (no scheduler)     | `io_uring` only (Linux)                                                         | **Yes** (`@nogc nothrow betterC`)               | Active (v0.5.0)   | [repo][during-repo] · [DUB][during-dub]  |
| **`core.thread.Fiber`** | Stackful coroutines (no I/O integration)                | n/a                                                                             | `nothrow @nogc` (most ops)                      | druntime stdlib   | [docs][fiber-docs]                       |
| **`std.concurrency`**   | Actor-style message passing between threads/fibers      | n/a (OS threads)                                                                | No (GC messages)                                | Phobos stdlib     | [docs][concurrency-docs]                 |
| **libasync**            | Callback event loop                                     | epoll, kqueue, IOCP                                                             | No                                              | Low activity      | [repo][libasync]                         |

Notes:

- "Backend(s)" is the OS demultiplexing primitive. eventcore is the only project listing an `io_uring` driver, and it is flagged _experimental, Linux-only_ in its own README.
- Photon's **DLang** project (`DmitryOlshansky/photon`) is distinct from **PhotonLibOS** (`alibaba/PhotonLibOS`, C++), which _does_ drive `io_uring`. Conflating them is a common error; only the C++ project has an `io_uring` engine today.

---

## vibe.d / vibe-core / eventcore — the dominant framework

### Layering

vibe.d is split into three packages with a clean dependency stack:

```
vibe.d (HTTP, web, RPC, DB drivers)
  └── vibe-core (fibers, tasks, sockets, files, channels — the scheduler)
        └── eventcore (OS event-loop driver abstraction)
```

`eventcore` is described by its authors as a **"high-performance native event loop abstraction for D"** following a **Proactor** (callback-on-completion) shape, even though most of its concrete drivers sit on _reactor_ primitives (epoll/kqueue) and synthesize completion callbacks on top. `vibe-core` is the layer that turns those callbacks into **stackful-fiber suspension**: a `Task` (a vibe fiber) issues a read, eventcore registers the FD, the fiber yields, and vibe-core resumes the task from the completion callback. To user code the call simply _blocks_.

Both `eventcore` and `vibe-core` are MIT-licensed (© Sönke Ludwig).

### eventcore drivers

eventcore selects a driver per platform. The driver names from its README:

| Driver                 | Platform                | Underlying primitive                      |
| ---------------------- | ----------------------- | ----------------------------------------- |
| `SelectEventDriver`    | cross-platform fallback | `select(2)`                               |
| `EpollEventDriver`     | Linux / Android         | `epoll` (level/edge readiness)            |
| `KqueueEventDriver`    | macOS / \*BSD           | `kqueue`                                  |
| `WinAPIEventDriver`    | Windows                 | IOCP / overlapped I/O                     |
| `CFRunloopEventDriver` | macOS / iOS             | CoreFoundation run loop (GUI integration) |
| `LibasyncEventDriver`  | any                     | libasync (experimental)                   |
| `UringEventDriver`     | Linux                   | **`io_uring` (experimental)**             |

The `EventDriver` interface (`source/eventcore/driver.d`) decomposes the loop into sub-driver interfaces — `EventDriverCore`, `EventDriverSockets`, `EventDriverFiles`, `EventDriverTimers`, `EventDriverEvents`, `EventDriverSignals`, `EventDriverDNS` — each returning opaque integer-keyed handles (`StreamSocketFD`, `FileFD`, `TimerID`, …) rather than pointers, which keeps the hot API `@nogc`-friendly even though callback closures and the handle store touch the GC.

### io_uring status

The `io_uring` driver in eventcore is real but not the default. The original integration started as [PR #175 ("Use io_uring for files on linux")][eventcore-pr175] — a proof of concept that wired `io_uring` into the _existing epoll loop for files only_, with timers noted as an easy follow-up. As of mid-2026 the `UringEventDriver` is shipped but flagged **experimental, Linux-only** in the README; epoll remains the production Linux backend. This means vibe.d users today are on a **reactor (readiness)** model on Linux, not a completion model, and do not get `io_uring`'s batched-submission or registered-buffer/registered-file benefits by default.

### What it looks like

vibe-core code is direct-style: the fiber blocks, the loop multiplexes.

```d
// vibe-core: blocking-looking, fiber-scheduled (illustrative, not betterC)
// cf. vibe-d/vibe-core source/vibe/core/net.d
import vibe.core.net;
listenTCP(8080, (TCPConnection conn) {
    ubyte[256] buf;
    while (!conn.empty) {
        auto n = conn.read(buf[], IOMode.once); // fiber yields here, resumes on data
        conn.write(buf[0 .. n]);
    }
});
```

The `read`/`write` calls suspend the current `Task`; vibe-core schedules another ready fiber meanwhile. This is the same direct-style ergonomics that [Eio][eio] brings to OCaml 5 via effects and that [Java Loom][loom] brings to the JVM via virtual threads — except D achieves it with plain stackful fibers and a hand-written scheduler rather than a language-level effect or a runtime-level continuation.

### Strengths / weaknesses for framing Sparkles

- **Strengths:** mature, broad protocol support (HTTP/1+2, WebSockets, TLS, Redis, Mongo), cross-platform, direct-style ergonomics, structured `Task` lifetimes and `TaskPool`/channels.
- **Weaknesses (relative to an `io_uring`-first goal):** GC-and-exception coupling makes `@nogc`/`betterC` use impractical; the Linux backend is reactor/epoll by default; the `io_uring` path is experimental and file-only in origin; the proactor abstraction adds a callback indirection layer that a native completion loop would not need.

---

## Photon — transparent fiber scheduler

Photon (`DmitryOlshansky/photon`, Boost license, **v0.19.1** on [DUB][photon-dub] as of May 2026) takes a strikingly different approach: instead of asking you to call its socket types, it **overrides the libc syscall wrappers** so that any blocking call — including those inside third-party C libraries — is transparently rerouted through its fiber-aware pseudo-blocking runtime. It markets itself as bringing "Golang-style concurrency to D transparently."

### Model

- **Stackful fibers** (built on `core.thread.Fiber`), kept cheap with modest stacks.
- **Multi-threaded scheduler**: fibers are distributed across OS worker threads (M:N).
- **Transparent interception**: the libc syscall trampoline checks whether it is running on a Photon fiber; if so, it issues the non-blocking variant and parks the fiber on the event loop; if not, it passes through to the real syscall. This is what lets unmodified libraries (e.g. `std.net.curl`, ZeroMQ bindings) become fiber-aware without rewrites.
- **Backends:** the Linux backend lives in `src/photon/linux/` (`core.d`, `support.d`, `syscalls.d`) and is built on **epoll**; macOS support (added in the v0.15 line, Sept 2025) uses **kqueue**. The DLang Photon does **not** currently use `io_uring` (that is the separate Alibaba PhotonLibOS C++ project).

### API

```d
// Photon: transparent scheduling (illustrative)
// cf. DmitryOlshansky/photon README
import photon;
void main() {
    initPhoton();                 // initialize scheduler data structures
    go({                          // root fiber: accept/connect, spawn more fibers
        // ordinary "blocking" socket code here is transparently async
    });
    runScheduler();               // run until all fibers complete
}
```

`vibe.d-lite` is an experimental reimplementation of `vibe-core` on top of Photon's scheduler, showing the appetite for swapping vibe's loop for a different scheduler.

### Relevance to Sparkles

Photon's transparent-interception trick is powerful for retrofitting existing code but is fundamentally a **readiness/epoll** design that fights the grain of a `@nogc`/`betterC` library: it depends on libc-symbol overriding and a GC-backed scheduler. Its value to Sparkles is as a _design data point_ (M:N stackful scheduling in D is viable and performant) rather than a foundation.

---

## during — the low-level io_uring binding

[during] (`tchaloupka/during`, **BSL-1.0**, by Tomáš Chaloupka) is the most relevant existing component: a **`@nogc nothrow betterC`-capable idiomatic D wrapper over `io_uring`** that deliberately does _not_ link `liburing` and does _not_ impose a scheduler. Its README states it is "just a low level wrapper… but attempts to provide building blocks for it." The latest published release is **v0.5.0** ([DUB][during-dub], 2026-05-19), with parity up to **Linux 6.x and liburing 2.9** — full opcode and register-opcode coverage including zero-copy networking, futex ops, socket lifecycle, vectored fixed I/O, pipe, SQE128, bundles, wait registration, ring resize, buffer cloning, NAPI, and a BPF filter. (The local clone tracks unreleased work past the v0.5.0 changelog, a "Linux 7.1 catch-up" branch adding `write_stream`, CQE32/`F_32`, and other 7.0/7.1-era fields — only the published v0.5.0 surface is treated as stable here.)

This is the natural substrate for a Sparkles loop; the rest of this section reads its actual API from `source/during/`.

### The `Uring` handle

`Uring` (`source/during/package.d`) is the central object — a thin, refcounted, RAII wrapper around a `UringDesc*` payload holding the kernel ring FD plus the mmapped submission/completion rings. It is created by free function `setup`:

```d
// source/during/package.d
int setup(ref Uring uring, uint entries = 128, SetupFlags flags = SetupFlags.NONE) @safe;
int setup(ref Uring uring, uint entries, ref const SetupParameters params) @safe;
```

`Uring` then exposes the ring as a **D range plus a builder**:

| Member                                                | Role                                                                                                                   |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `put(entry)` / `put(op)` / `putWith!(FN)(args)`       | enqueue an SQE (whole entry, custom struct, or fill-in-place) — chainable, returns `ref Uring`                         |
| `next()` / `next128()`                                | advance the SQ and hand back a writable `ref SubmissionEntry` slot (the 128 variant reserves a contiguous SQE128 slot) |
| `submit(want)` / `submitAndWait(want)` / `wait(want)` | call `io_uring_enter(2)`; `want > 0` blocks for that many CQEs                                                         |
| `empty` / `front` / `popFront` / `length`             | **InputRange over completed `CompletionEntry`** values                                                                 |
| `full` / `capacity` / `dropped` / `overflow`          | SQ/CQ backpressure introspection                                                                                       |
| `probe()`                                             | returns a `Probe` (wraps `IORING_REGISTER_PROBE`) to test per-op support at runtime                                    |

The range design is what makes the README's example read so cleanly — you `copy` operations _into_ the ring and iterate completions _out_ of it:

```d
// source/during README — range + chaining
Uring io;
io.setup();

io.put(entry)                          // whole SubmissionEntry as-is
  .put(MyOp(Operation.NOP, 2))         // custom struct, fields copied by name
  .putWith!((ref SubmissionEntry e) {  // fill the next slot in place
      e.prepNop();
      e.user_data = 42;
  })
  .submit(1);                          // submit + wait for >=1 completion

assert(io.front.user_data == 1);
io.popFront();                         // consume one CQE
```

### Submission / completion primitives

`SubmissionEntry` and `CompletionEntry` (`source/during/io_uring.d`) are exact, union-rich mirrors of the kernel `struct io_uring_sqe` / `struct io_uring_cqe`:

```d
// source/during/io_uring.d (abridged)
struct SubmissionEntry {
    Operation            opcode;     // IORING_OP_*
    SubmissionEntryFlags flags;      // IOSQE_* (FIXED_FILE, IO_LINK, …)
    ushort               ioprio;
    int                  fd;
    union { ulong off; ulong addr2; /* cmd_op since 5.19 */ }
    union { ulong addr; ulong splice_off_in; /* level/optname since 6.7 */ }
    uint  len;
    union { ReadWriteFlags rw_flags; TimeoutFlags timeout_flags;
            MsgFlags msg_flags; uint open_flags; uint nop_flags; /* … */ }
    ulong user_data;                 // echoed back in the CQE
    union { ushort buf_index; ushort buf_group; }
    ushort personality;
    union { uint file_index; uint zcrx_ifq_idx; /* … */ }
    union { struct { ulong addr3; ulong[1] __pad2; } ubyte[0] cmd; }
    void clear() @safe nothrow @nogc;
}

struct CompletionEntry {
    ulong    user_data;   // copied from the SQE
    int      res;         // result (>=0) or -errno
    CQEFlags flags;       // BUFFER, MORE, SOCK_NONEMPTY, NOTIF, BUF_MORE, F_32, …
    ulong[0] big_cqe;     // present on CQE32 rings
}
```

The unions carry per-field `since Linux x.y` annotations directly in source (e.g. `msg_ring_flags` "from Linux 6.0", `install_fd_flags` "from Linux 6.7", `write_stream` "from Linux 7.1"), so version-gating decisions can be read off the binding. The `Operation` enum enumerates every opcode with its kernel name in a `///` doc-comment — `NOP=0`, `READV=1`, … `SEND_ZC=47`, `SENDMSG_ZC=48`, `RECV_ZC=58`, `READV_FIXED=60`, up to `NOP128=63`.

### Prep helpers

For each opcode `during` provides a `prepXxx` UFCS helper that fills a `SubmissionEntry` in place (chainable, mostly `@safe`/`@trusted` as the syscall surface demands). A non-exhaustive map of the families:

| Family       | Helpers (examples)                                                                                                                                                                                                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| File RW      | `prepRead`, `prepWrite`, `prepReadv`/`prepWritev`(`2`), `prepReadFixed`, `prepWriteFixed`, `prepReadvFixed`, `prepWritevFixed`                                                                                                                    |
| Sync         | `prepFsync`, `prepSyncFileRange`, `prepFallocate`, `prepFtruncate`                                                                                                                                                                                |
| Net          | `prepAccept`/`prepAcceptDirect`, `prepMultishotAccept`/`prepMultishotAcceptDirect`, `prepConnect`, `prepSend`/`prepRecv`(`Multishot`), `prepSendMsg`/`prepRecvMsg`(`Multishot`), `prepShutdown`, `prepSocket`(`Direct`), `prepBind`, `prepListen` |
| Zero-copy    | `prepSendZc`, `prepSendZcFixed`, `prepSendmsgZc`, `prepRecvZc`                                                                                                                                                                                    |
| Poll/timeout | `prepPollAdd`, `prepPollMultishot`, `prepPollRemove`/`Update`, `prepTimeout`(`Remove`/`Update`), `prepLinkTimeout`                                                                                                                                |
| Files/FS     | `prepOpenat`(`Direct`/`2`), `prepClose`(`Direct`), `prepStatx`, `prepRenameat`, `prepUnlinkat`, `prepMkdirat`, `prepSymlinkat`, `prepLinkat`, `prepFilesUpdate`, `prepFixedFdInstall`                                                             |
| Control      | `prepNop`, `prepCancel`(`Fd`), `prepSplice`, `prepTee`, `prepMsgRing`(`Fd`/`FdAlloc`), `prepProvideBuffers`/`prepRemoveBuffers`, `prepEpollCtl`/`prepEpollWait`, `prepUringCmd`(`128`), `prepFutexWait`/`Wake`/`Waitv`, `prepWaitid`              |
| User data    | `setUserData` / `setUserDataRaw` (store a pointer/value to round-trip via `user_data`)                                                                                                                                                            |

### Registration API (the io_uring superpowers)

The performance-critical `io_uring_register(2)` operations are exposed as `Uring` methods:

| Method                                                      | Wraps                     | Purpose                                                                                                      |
| ----------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `registerBuffers(T)` / `unregisterBuffers`                  | `REGISTER_BUFFERS`        | pin user buffers so `READ_FIXED`/`WRITE_FIXED` (selected via `buf_index`) skip per-op page pinning           |
| `registerFiles` / `registerFilesUpdate` / `unregisterFiles` | `REGISTER_FILES(_UPDATE)` | pre-register FDs; SQEs set `IOSQE_FIXED_FILE` and use the table index in `fd`, avoiding per-op `fget`/`fput` |
| `registerEventFD` / `unregisterEventFD`                     | `REGISTER_EVENTFD`        | wire an eventfd for CQ-change notification (loop integration)                                                |
| `registerPersonality` / `unregisterPersonality`             | `REGISTER_PERSONALITY`    | run a request under a credentials snapshot                                                                   |
| `registerBufRing`                                           | `REGISTER_PBUF_RING`      | kernel-side provided-buffer ring for `recv` buffer selection (since Linux 5.19)                              |

The bundled `examples/echo_server` shows the registered-buffer flow end to end: it `malloc`s one big slab, calls `io.registerBuffers(buf[0..total])`, carves per-connection buffers out of it with a fixed pool, and submits `prepReadFixed`/`prepWriteFixed` with `bufferIndex 0`. Its loop is the canonical hand-rolled completion loop — `io.wait(1)`, dispatch on `io.front.user_data` (a context pointer), `io.popFront()` — exactly the loop a scheduler would replace.

### What `during` deliberately does _not_ do

It has **no scheduler, no fibers, no task model, no cross-platform fallback**. There is no notion of "await this op" — you submit, you drain CQEs, you correlate by `user_data` yourself. That is the line Sparkles would cross.

---

## The druntime / Phobos primitives a new loop builds on

A from-scratch D event loop does not start from zero. Two runtime facilities matter.

### `core.thread.Fiber` — stackful coroutines

D ships stackful fibers in druntime (`core/thread/fiber/`). A `Fiber` wraps a `void function()`/`void delegate()` body on its own stack and provides a tiny cooperative-scheduling surface:

```d
// core/thread/fiber/{base,package}.d (abridged signatures)
class Fiber : FiberBase {
    this(void function() fn, size_t sz = pageSize*defaultStackPages,
         size_t guardPageSize = pageSize) nothrow;
    this(void delegate() dg, size_t sz = pageSize*defaultStackPages,
         size_t guardPageSize = pageSize) nothrow;
    static Fiber getThis() @safe nothrow @nogc;     // currently-running fiber
}
class FiberBase {
    final Throwable call(Rethrow = Rethrow.yes);    // run/resume until next yield/return
    static void yield() nothrow @nogc;              // suspend current fiber
    static void yieldAndThrow(Throwable) nothrow @nogc;
    final void reset();                             // recycle a TERM fiber
    final @property State state() const @safe pure nothrow @nogc;  // HOLD / EXEC / TERM
}
```

Key properties for a loop designer:

| Property      | Value                                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| Switch cost   | a register save/restore + stack-pointer swap (hand-written asm: `switch_context_asm.S`); no heap alloc per switch |
| Default stack | `pageSize * defaultStackPages` = 4 pages on Linux (8 on Windows/macOS-`x86_64`)                                   |
| State machine | `State.{HOLD, EXEC, TERM}`; a `TERM` fiber must be `reset` before reuse                                           |
| Safety        | `yield`/`getThis`/`state` are `nothrow @nogc`; construction allocates the stack (`mmap` with a guard page)        |
| Cost driver   | per-fiber stack reservation — the M:N "memory tax" relative to Rust/C# poll-based state machines                  |

The loop pattern is: each accepted connection runs in a `Fiber`; on a would-block the fiber's I/O shim submits an op and calls `Fiber.yield()`; the loop's completion handler looks up the parked fiber from the CQE's `user_data` and calls `fib.call()` to resume it. This is exactly how vibe-core and Photon work, and the same stackful-fiber-as-green-thread idea underpins [Java Loom][loom] virtual threads and OCaml's [Eio][eio] (though Eio reifies suspension as an algebraic effect rather than a raw context switch).

### `std.concurrency` — actor-style message passing

Phobos's `std.concurrency` provides Erlang-flavored message passing over OS threads (and integrates with fibers via a scheduler interface):

```d
// std/concurrency.d (public surface)
struct Tid;                                  // opaque thread/fiber handle
@property Tid thisTid() @safe;
Tid spawn(F, T...)(F fn, T args);            // start fn(args) in a logical thread
Tid spawnLinked(F, T...)(F fn, T args);      // + LinkTerminated on exit
void send(T...)(Tid tid, T vals);            // typed message send
void prioritySend(T...)(Tid tid, T vals);
... receive((T){...}, ...);                  // pattern-match on message type
T receiveOnly(T)();
bool receiveTimeout(Duration, ...);
```

It is GC-coupled (messages are heap values) and thread-oriented, so it is not a substrate for a `@nogc` hot loop — but it is the idiomatic D answer for _coarse-grained_ cross-loop coordination (e.g. handing work between per-core `io_uring` loops), analogous to channels in Go or the cross-thread wakers in [Tokio][tokio]. A Sparkles design that runs one `io_uring` ring per core ([thread-per-core][comparison], as in [Glommio][glommio]/[Monoio][monoio]) would use something like this — or a leaner `@nogc` channel — for inter-core messages.

### The `@nogc` / `@safe` / `-betterC` constraints

Sparkles (per the repo guidelines) targets **maximum safety attributes**, `@nogc`/`nothrow` hot paths, `-preview=in` and `-preview=dip1000` scope semantics, and `SmallBuffer`-style allocation avoidance. That constraint set rules the existing frameworks out as foundations:

| Constraint               | vibe-core                       | Photon            | during                              | Implication                          |
| ------------------------ | ------------------------------- | ----------------- | ----------------------------------- | ------------------------------------ |
| `@nogc` hot path         | No (GC `Task`/closures)         | No (GC scheduler) | **Yes**                             | only `during` is reusable as-is      |
| `nothrow`                | No (exception-based I/O errors) | No                | **Yes** (returns `-errno`)          | error-as-value fits `during`         |
| `-betterC`               | No (needs druntime/GC)          | No                | **Yes**                             | `during` works without druntime      |
| `@safe` surface          | Partial                         | Partial           | Mostly (`@trusted` at syscall edge) | `during` already isolates unsafe ops |
| `-preview=dip1000` scope | n/a                             | n/a               | uses `return ref`/`scope` in preps  | aligns with Sparkles style           |

The conclusion writes itself: **build on `during` + `core.thread.Fiber`, not on vibe-core or Photon.** `during` supplies a `@nogc nothrow betterC` SQE/CQE substrate; `Fiber` supplies cheap stackful suspension; everything between them — the scheduler, the await/suspend shim, the readiness-vs-completion bookkeeping, the timer wheel, the cancellation model — is the gap.

---

## Gap analysis — what an io_uring-first Sparkles loop could add

Mapping the landscape against an `io_uring`-first, `@nogc`/`@safe` goal, the unoccupied space is concrete:

| Capability                                        | vibe-core                         | Photon        | during                             | Sparkles opportunity                                                                                                                              |
| ------------------------------------------------- | --------------------------------- | ------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Completion (Proactor) model on Linux**          | epoll default; uring experimental | epoll only    | raw SQE/CQE                        | A loop that is _natively_ completion-based on `io_uring`, not readiness emulated on epoll                                                         |
| **`@nogc` / `betterC` end to end**                | No                                | No            | Yes (binding only)                 | First _full_ `@nogc`/`betterC` loop, not just the binding                                                                                         |
| **Scheduler over `during`**                       | (uses eventcore)                  | (own)         | None                               | The missing layer: park/resume a `Fiber` keyed by CQE `user_data`                                                                                 |
| **Modern `io_uring` features wired into the API** | minimal                           | none          | exposed but unused                 | Registered buffers/files, provided-buffer rings, multishot accept/recv, `SEND_ZC`, `MSG_RING` cross-ring wakeups, `DEFER_TASKRUN`/`SINGLE_ISSUER` |
| **Thread-per-core sharding**                      | shared loop + workers             | M:N scheduler | n/a                                | One ring per core + `MSG_RING`/eventfd handoff (à la [Glommio][glommio]/[Seastar][seastar])                                                       |
| **Structured concurrency / cancellation**         | `Task` scopes                     | none          | `prepCancel`/`prepLinkTimeout` raw | First-class scopes mapped onto `IOSQE_IO_LINK` + `LINK_TIMEOUT` + `ASYNC_CANCEL`                                                                  |
| **Direct-style ergonomics without GC**            | yes (but GC)                      | yes (but GC)  | no                                 | Blocking-looking API on stackful fibers with zero GC pressure                                                                                     |
| **Graceful kernel fallback**                      | epoll is the fallback             | epoll only    | none                               | Runtime `Uring.probe()` gating with an epoll/kqueue path for old kernels and macOS                                                                |

In short, the D ecosystem already proves the _ergonomic_ model (stackful fibers, direct-style I/O — vibe-core, Photon) and already provides the _raw kernel surface_ (`during`), but **no project unifies them into a completion-first, `@nogc`/`@safe`, `io_uring`-native event loop with modern feature usage and structured cancellation.** That union — `during`'s SQE/CQE building blocks driving a `Fiber`-based scheduler, with registered buffers/files, multishot ops, zero-copy send, and `MSG_RING` cross-core wakeups exposed as safe primitives — is precisely the Sparkles event-horizon niche.

For how this compares to the same niche in other languages — [Tokio][tokio] and [Glommio][glommio]/[Monoio][monoio] in Rust, [Seastar][seastar] and [Boost.Asio][asio] in C++, [libuv][libuv], the [Go netpoller][go], and effect-based loops like [Eio][eio] — see the [cross-language comparison][comparison] and the [io_uring feature/timeline references][io-uring].

---

## Sources

- [during — GitHub repository (tchaloupka/during)][during-repo]
- [during — DUB registry page (v0.5.0)][during-dub]
- [during README — usage example & feature list][during-readme]
- [eventcore — GitHub repository (vibe-d/eventcore)][eventcore]
- [eventcore — driver API docs][eventcore-api]
- [eventcore PR #175 — "Use io_uring for files on linux"][eventcore-pr175]
- [vibe-core — GitHub repository][vibe-core]
- [vibe.d documentation][vibe-docs]
- [Photon (DLang) — GitHub repository][photon]
- [Photon — DUB registry page][photon-dub]
- [core.thread.Fiber — druntime documentation][fiber-docs]
- [std.concurrency — Phobos documentation][concurrency-docs]
- [libasync — GitHub repository][libasync]
- [io_uring (kernel.dk PDF)][io-uring-pdf]
- [io_uring overview (sibling reference)][io-uring]
- [Cross-language comparison (sibling)][comparison]

<!-- References -->

[during]: #during--the-low-level-io_uring-binding
[during-repo]: https://github.com/tchaloupka/during
[during-dub]: https://code.dlang.org/packages/during
[during-readme]: https://github.com/tchaloupka/during/blob/4db53813842015d2d295eef1220abd70f2dad36d/README.md
[eventcore]: https://github.com/vibe-d/eventcore
[eventcore-api]: https://vibed.org/api/eventcore.driver/
[eventcore-pr175]: https://github.com/vibe-d/eventcore/pull/175
[vibe-core]: https://github.com/vibe-d/vibe-core
[vibe-docs]: https://vibed.org/docs
[photon]: https://github.com/DmitryOlshansky/photon
[photon-dub]: https://code.dlang.org/packages/photon
[fiber-docs]: https://dlang.org/library/core/thread/fiber.html
[concurrency-docs]: https://dlang.org/library/std/concurrency.html
[libasync]: https://github.com/etcimon/libasync
[io-uring-pdf]: https://kernel.dk/io_uring.pdf
[DUB]: https://code.dlang.org
[io-uring]: ./io-uring/index.md
[comparison]: ./comparison.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[seastar]: ./seastar.md
[asio]: ./boost-asio.md
[libuv]: ./libuv.md
[go]: ./go-netpoller.md
[eio]: ../algebraic-effects/ocaml-eio.md
[loom]: ../algebraic-effects/java-loom.md
