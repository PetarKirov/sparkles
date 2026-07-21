# Cross-Library Synthesis & Design Recommendations for Sparkles

The capstone of the async-I/O survey. Part 1 distils the eighteen deep-dives and the
two concept docs ([primitives][primitives], [techniques][techniques]) into a head-to-head
comparison across the axes that actually decide a runtime's character: the
**reactor/proactor** kernel-model split, **scheduler topology**, the **concurrency /
programming model**, **cancellation & structured concurrency**, and **buffer management**.
Part 2 turns that synthesis into concrete, opinionated design recommendations for the
**Sparkles event-horizon library** — an `io_uring`-first, `@nogc`/`@safe` D event loop — with
every recommendation justified against this repo's [agent guidelines][agents] and the
[D landscape][d-landscape].

> **Scope.** This is the _synthesis + recommendations_ leaf of the survey. It assumes the
> kernel mechanics ([io_uring overview][uring-index], [features][uring-features],
> [opcodes][uring-opcodes], [timeline][uring-timeline]), the tiered primitive vocabulary
> ([primitives][primitives]), and the implementation techniques ([techniques][techniques])
> as given, and cross-links rather than re-derives them. For the breadth-first map of all
> systems see [the index][index]; for how completions resume suspended computations
> (fibers, continuations, algebraic effects, virtual threads) see
> [effects and event loops][effects].

---

## Part 1 — Cross-library synthesis

### 1.1 The systems at a glance

| System                            | Language | Kernel model                                         | Scheduler                          | Concurrency unit                      | Top tier ([primitives][primitives]) |
| --------------------------------- | -------- | ---------------------------------------------------- | ---------------------------------- | ------------------------------------- | ----------------------------------- |
| [Tokio][tokio]                    | Rust     | Reactor (mio epoll/kqueue) + experimental `io_uring` | Work-stealing                      | Stackless `Future`                    | Tier 2–3                            |
| [Glommio][glommio]                | Rust     | Proactor (`io_uring`)                                | Thread-per-core                    | Stackless `Future` (`!Send`)          | Tier 3                              |
| [Monoio][monoio]                  | Rust     | Proactor (`io_uring`) + epoll/kqueue fallback        | Thread-per-core                    | Stackless `Future` (`!Send`)          | Tier 3                              |
| [Boost.Asio][boost-asio]          | C++      | Proactor over reactors; true IOCP / `io_uring`       | Executor / thread pool             | Callbacks / C++20 coroutines          | Tier 2–3                            |
| [Seastar][seastar]                | C++      | Proactor (`io_uring`) + aio/epoll                    | Thread-per-core + NUMA             | Future/promise/continuation           | Tier 3                              |
| [libuv][libuv]                    | C        | Reactor (epoll/kqueue/IOCP) + `io_uring` fs          | Single-threaded loop + threadpool  | Callbacks                             | Tier 2–3                            |
| [Zig std.Io][zig-io]              | Zig      | Pluggable (Threaded / Uring / Kqueue / Dispatch)     | Backend-dependent                  | Stackful fibers (evented)             | Tier 3                              |
| [.NET][dotnet]                    | C#       | Reactor (epoll/kqueue) + proposed `io_uring`         | ThreadPool                         | `Task` / `async`-`await`              | Tier 2–3                            |
| [Java][java]                      | Java     | Reactor (NIO/Netty) + FFI `io_uring`; Loom           | ForkJoin / carrier threads         | `CompletableFuture` / virtual threads | Tier 2–3                            |
| [Go netpoller][go]                | Go       | Reactor (epoll/kqueue/IOCP), **no io_uring**         | Integrated runtime (work-stealing) | Stackful goroutines                   | Tier 2                              |
| [asyncio / uvloop / Trio][python] | Python   | Reactor (selectors / libuv)                          | Single-threaded                    | Stackless coroutines                  | Tier 2                              |
| [Eio][eio]                        | OCaml    | Proactor (`io_uring`) + posix                        | Single-threaded per domain         | Stackful fibers via effects           | Tier 2–3                            |
| [vibe-core][d-landscape]          | D        | Reactor (epoll) + experimental `io_uring`            | Multi-thread fiber pool            | Stackful fibers                       | Tier 2                              |
| [Photon][d-landscape]             | D        | Reactor (epoll/kqueue)                               | M:N fiber pool                     | Stackful fibers                       | Tier 2                              |
| [during][d-landscape]             | D        | Proactor (`io_uring` binding only)                   | none                               | none (raw SQE/CQE)                    | substrate                           |

The single most useful lens on this table: **kernel model and scheduler topology are
orthogonal**. Tokio is reactor + work-stealing; Glommio is proactor + thread-per-core; Eio
is proactor + single-threaded-per-domain; Go is reactor + integrated-runtime. Every cell of
that 2×N grid is occupied by _something_, and the choice in each dimension is governed by
different forces — the kernel model by _what the OS offers and what file I/O needs_, the
scheduler by _latency vs. throughput vs. ease of programming_.

---

### 1.2 Reactor (readiness) vs. Proactor (completion)

The defining axis. A **reactor** is told "fd X is _ready_"; the application then issues the
real `read`/`write` syscall. A **proactor** is told "operation X _finished_; here is the
result"; the kernel already moved the bytes. The full mechanics are in
[primitives §readiness-vs-completion][primitives] and [techniques §reactor-vs-proactor][techniques];
the `io_uring`-vs-epoll table is in [io_uring overview][uring-index]. The synthesis:

| Aspect             | Reactor (readiness)                                                        | Proactor (completion)                                           |
| ------------------ | -------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Kernel tells you   | "you may now syscall without blocking"                                     | "your operation finished — here is the byte count / error"      |
| Who issues the I/O | application, _after_ the event                                             | kernel, on the application's behalf                             |
| Syscalls per op    | ≥ 2 (notify + the real read/write)                                         | ≤ 1 amortized; 0 under SQPOLL                                   |
| Regular-file I/O   | **impossible** (files always "ready", `epoll_ctl` → `EPERM`) → thread pool | first-class (`READ`/`WRITE`/`OPENAT`/`STATX`)                   |
| Buffer lifetime    | **borrowed** — touched only during the synchronous syscall                 | **owned** — handed to the kernel for the whole in-flight window |
| Spurious wakeups   | possible (readiness ≠ data)                                                | none (a CQE is definitive)                                      |
| Cancellation       | implicit ("just stop calling `read`")                                      | explicit (`ASYNC_CANCEL`; buffer may still be in kernel use)    |
| Canonical backends | `epoll`, `kqueue`, `poll`/`select`, `WSAPoll`                              | `io_uring`, Windows `IOCP`, POSIX AIO                           |

**Who is which.** Pure reactors: [libuv][libuv], [Go netpoller][go], stock [asyncio][python],
[Tokio][tokio]'s default path (mio), [.NET][dotnet]'s `SocketAsyncEngine`, [Photon][d-landscape].
Pure / native proactors: [Glommio][glommio], [Monoio][monoio] (with an epoll fallback),
[Eio][eio]'s `eio_linux`, [during][d-landscape]. Hybrids that _present_ a completion API over
a reactor: [Boost.Asio][boost-asio] (emulates a Proactor over epoll/kqueue, uses true IOCP on
Windows and a real `io_uring_service` on Linux), [Seastar][seastar] (pluggable
`reactor_backend`: `io_uring` → linux-aio → epoll), [vibe.d's eventcore][d-landscape] (a
"Proactor" callback shape mostly synthesized on top of epoll).

**Why `io_uring` and IOCP enable a _true_ proactor while epoll forces readiness.** With epoll
the kernel has no place to put the result — the `epoll_ctl` interest set is a _set of fds to
watch_, and the readiness notification carries no bytes. The application must own the buffer
and call `recv` itself. `io_uring` inverts this: the SQE describes the _whole_ operation (fd +
buffer + length + offset), and the CQE carries the `res` (byte count or `-errno`) — the data
is already in your buffer when you observe the completion. IOCP works identically: `WSARecv`
with an `OVERLAPPED` + buffer, dequeued from a completion port. Critically, epoll _cannot_
report readiness for **regular files** at all — they are always "ready" yet `read` still
blocks on disk — which is exactly why every reactor runtime ([Tokio][tokio], [libuv][libuv])
shunts file I/O to a **blocking thread pool**, and why completion backends are decisively
better for file-heavy workloads (see [primitives §files][primitives]).

**The buffer-ownership consequence of completion I/O.** This is the most important
downstream effect and it propagates into the entire API surface. In a reactor,
`read(fd, &mut buf)` is _synchronous_: the kernel touches `buf` only during the call, so a
borrowed slice is sound. In a proactor, the buffer is handed to the kernel at _submission_
and may be written any time before the CQE; if the task holding the buffer is dropped or the
buffer freed while the op is in flight, the kernel writes into freed memory. The borrow
checker (or, in D, `scope`/lifetime reasoning) cannot express "this borrow lasts until a
runtime event." The fix is **ownership transfer**, analysed in §1.6 below. `io_uring` can also
be driven _in a readiness style_ via `IORING_OP_POLL_ADD` (especially multishot) — which
[Monoio][monoio]'s `poll-io` feature uses as a migration bridge — but that throws away the
proactor's advantages and exists only for backward compatibility.

---

### 1.3 Scheduler architectures

Once the submission/completion plumbing exists, the runtime must decide _which thread runs
which task_. Four dominant topologies, ordered by how much they share (full taxonomy in
[techniques §scheduler-architectures][techniques]):

| Architecture                        | Task placement                                       | Sync on hot path               | Latency                                            | Throughput                            | Load balancing                  | Exemplars                                                                                  |
| ----------------------------------- | ---------------------------------------------------- | ------------------------------ | -------------------------------------------------- | ------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------ |
| **Single-threaded**                 | one queue, one thread                                | none                           | low, predictable (one core)                        | capped at one core                    | n/a (manual sharding)           | [Node/libuv][libuv], [asyncio/Trio][python], `tokio` current-thread, one [Eio][eio] domain |
| **Work-stealing**                   | per-worker local queue + shared overflow             | atomics only when stealing     | higher variance (steal jitter, cross-core wakeups) | excellent, automatic                  | automatic (idle workers steal)  | [Tokio][tokio] multi-thread, [Go][go], [Cats-Effect][cats-effect] / [ZIO][zio] fiber pools |
| **Thread-per-core / share-nothing** | one reactor + queues _pinned_ per core; no migration | none (no shared mutable state) | **lowest, most predictable** (no migration)        | excellent _if work is evenly sharded_ | manual (hot shard = bottleneck) | [Seastar][seastar], [Glommio][glommio], [Monoio][monoio]                                   |
| **Integrated runtime**              | language runtime owns the loop + steals              | atomics on steal               | good                                               | excellent                             | automatic                       | [Go netpoller][go] (per-P run queues + netpoller)                                          |

**Work-stealing** (Tokio, Cats-Effect, Go) gives each worker a bounded local run queue plus
a shared injection queue; a worker prefers its own queue and only _steals_ from a random peer
when empty. Tokio sharpens this with a per-worker **LIFO slot** (the most-recently-woken task
runs immediately on the same core for cache-hot message handoff) and a periodic global-queue
check to avoid starvation. The trade-off is **tail-latency variance**: a task can migrate
between cores, trashing L1/L2, and cross-core wakeups bounce cache lines. The upside is
automatic load balancing — uneven task sizes self-level.

**Thread-per-core / share-nothing** (Seastar, Glommio, Monoio) is the opposite philosophy:
**never share mutable state between cores.** Each core runs its own reactor, queues,
allocator arena, timers, and slice of the data; cross-core communication is _explicit message
passing_ over lock-free SPSC queues (Seastar's `smp_message_queue`). There are no locks on the
hot path because there is nothing shared to lock. This yields the lowest, most predictable
tail latency and eliminates nearly all cache-coherency traffic — which is why databases and
proxies (ScyllaDB/Redpanda on Seastar) choose it. The cost is that **load balancing becomes
the application's problem**: a hot shard is a bottleneck with no automatic relief, and tasks
need not (cannot, usefully) be `Send`. Glommio layers a userspace-CFS fair scheduler
(`Shares`/`Latency`-weighted `TaskQueue`s with a preempt timer) _within_ each core so a
CPU-bound queue cannot starve a latency-critical one.

**Integrated runtime** (Go) is work-stealing fused into the language: the runtime owns the
loop, goroutines are stackful green threads multiplexed M:N onto OS threads with per-P local
run queues and a netpoller that parks/unparks goroutines on readiness. The programmer never
sees the loop. The cost is loss of control (no pluggable backend, no `io_uring`; the
[Go netpoller issue][go] for it remains _Unplanned_) and a mandatory GC.

**Single-threaded** (Node/libuv, asyncio, one Eio domain) is the simplest and has _excellent_
single-core cache behaviour and no synchronization at all, at the cost of a one-core
throughput ceiling — scaled out by running N independent loops (the manual version of
thread-per-core).

| Concern             | Work-stealing                 | Thread-per-core                   | Integrated runtime | Single-threaded     |
| ------------------- | ----------------------------- | --------------------------------- | ------------------ | ------------------- |
| Tail latency        | variance from steal/migration | **best** (no migration)           | moderate           | best on one core    |
| Peak throughput     | excellent                     | excellent (if sharded well)       | excellent          | one core only       |
| Fairness            | automatic                     | manual (per-shard)                | automatic          | trivial (one queue) |
| `Send`/sharing cost | tasks must be `Send`; atomics | no `Send` needed; message passing | runtime-managed    | none                |
| Programming model   | spawn anywhere                | pin + shard explicitly            | spawn anywhere     | spawn on the loop   |

---

### 1.4 Concurrency / programming models

_How_ you express "do this, then await its result" is the axis users feel most directly. Six
families, from lowest- to highest-level (the deep theory of how each resumes a suspended
computation is in [effects and event loops][effects]):

| Model                  | What suspends             | Stack                | Function coloring                         | Composability                | Cancellation                         | Backtraces                    | Per-task overhead    | Exemplars                                                                                    |
| ---------------------- | ------------------------- | -------------------- | ----------------------------------------- | ---------------------------- | ------------------------------------ | ----------------------------- | -------------------- | -------------------------------------------------------------------------------------------- |
| **Callbacks**          | nothing (CPS by hand)     | none                 | n/a                                       | poor ("callback hell")       | manual                               | shredded                      | minimal              | [libuv][libuv], stock [asyncio][python] transports, [Asio][boost-asio] handlers              |
| **Futures / promises** | a polled state machine    | none                 | viral (`.then`)                           | combinator-based             | drop/abort the future                | partial                       | tiny (struct)        | [Seastar][seastar], [Java `CompletableFuture`][java], [Asio][boost-asio] `deferred`          |
| **async/await**        | a compiler state machine  | none                 | **viral** ("what color is your function") | good (linear-looking)        | drop the future at `.await`          | reconstructed by the compiler | tiny (no stack)      | [Tokio][tokio], [Glommio][glommio], [Monoio][monoio], [.NET][dotnet], [asyncio/Trio][python] |
| **Stackful fibers**    | a full stack switch       | heap stack           | **none** (direct style)                   | excellent (any fn can block) | inject an exception at a yield point | natural (real stack)          | a stack (KBs)        | [Go][go], [vibe-core][d-landscape], [Photon][d-landscape], `core.thread.Fiber`               |
| **Algebraic effects**  | a delimited continuation  | reified continuation | none                                      | excellent + typed            | structural (handler-scoped)          | natural                       | continuation capture | [Eio][eio], [Koka][effects]                                                                  |
| **Virtual threads**    | a runtime-unmounted stack | managed stack        | none                                      | excellent                    | interrupt + structured scopes        | natural                       | small managed stack  | [Java Loom][loom]                                                                            |

The headline trade-offs:

- **Function coloring.** `async`/`await` and futures _color_ functions: an async function
  can only be awaited from another async function, splitting the world in two ([the classic
  "what color is your function" problem][effects]). Stackful fibers, effects, and virtual
  threads have _no coloring_ — ordinary-looking synchronous code suspends transparently. This
  is the single biggest ergonomic divide, and it is why Go, Loom, Eio, and the D fiber
  frameworks all chose direct-style.
- **Overhead.** Stackless models (futures, async/await) cost _zero_ per-task stack and have no
  stack-overflow risk; the suspended state is a compact struct. Stackful models pay a
  per-fiber stack reservation (the "memory tax") and a context switch, but allow _any_
  function to block without coloring. D's `core.thread.Fiber` defaults to 4 pages on Linux
  (see [D landscape §Fiber][d-landscape]).
- **Composability & cancellation.** Effects and virtual threads compose best and cancel most
  cleanly (structural, scoped). Callbacks compose worst and cancel by ad-hoc bookkeeping.
- **Backtraces.** Stackful models (fibers, effects, Loom) preserve a real call stack, so a
  crash backtrace is meaningful. Stackless `async`/`await` reconstructs a logical stack at
  compile time; raw callbacks lose it entirely.

A full treatment of how a completed CQE _reconnects_ to the suspended computation — wakers vs.
continuations vs. effect resumptions vs. fiber switches — is the subject of
[effects and event loops][effects].

---

### 1.5 Cancellation & structured concurrency

A robust runtime must stop in-flight work cleanly and guarantee spawned work cannot outlive
its parent. These are two faces of one concern; the modern answer is **structured
concurrency** (child lifetimes are lexical scopes). The constructs compared:

| Construct                                             | System                    | Mechanism                                                                                                           | Structured?              | Cancellation granularity                                          |
| ----------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------ | ----------------------------------------------------------------- |
| **Nursery**                                           | [Trio][python] (Python)   | `async with open_nursery()`; block exit awaits all children                                                         | **yes** (pioneer)        | per-scope; cancel scope cancels the subtree                       |
| **Cancel scope**                                      | [Trio][python]            | `move_on_after` / `fail_after`; a deadline _is_ a cancel scope                                                      | **yes**                  | nestable region cancelled as a unit                               |
| **`TaskGroup` / `timeout`**                           | [asyncio][python] (3.11+) | direct port of Trio's nursery                                                                                       | **yes** (retrofit)       | per-group                                                         |
| **`Switch`**                                          | [Eio][eio] (OCaml)        | fibers forked into a switch; exit joins/cancels all; `Cancel.protect` shields                                       | **yes**                  | switch-scoped; `Switch.fail` cancels all fibers                   |
| **`StructuredTaskScope`**                             | [Java Loom][loom]         | `fork()` children, `join()`, scope close cancels stragglers                                                         | **yes**                  | scope-scoped (e.g. `ShutdownOnFailure`)                           |
| **`cancellation_slot`**                               | [Asio][boost-asio] (C++)  | per-op slot; `co_spawn`/`parallel_group` carry a `cancellation_state`; `total`/`partial`/`terminal` types           | **partial → structured** | per-operation, composes up groups; maps to `io_uring_prep_cancel` |
| **`CancellationToken`**                               | [.NET][dotnet]            | cooperative token threaded through `async` calls                                                                    | library-level            | per-token; checked at await points                                |
| **`JoinHandle::abort` / `JoinSet`**                   | [Tokio][tokio]            | sets a `CANCELLED` state bit; task dropped at next poll                                                             | **no** (unstructured)    | per-task; `abort_all` for a set                                   |
| **`Group` / `checkCancel`**                           | [Zig std.Io][zig-io]      | `groupAsync`/`groupCancel`; every op a cancellation point unless `swapCancelProtection`                             | **yes**                  | per-group + per-op checkpoints                                    |
| **Shard-scoped draining** (Seastar `gate`/`when_all`) | [Seastar][seastar]        | the share-nothing shard drains its in-flight futures before shutting down; Seastar's `gate`/`when_all` express this | **yes**                  | shard-scoped                                                      |

The spectrum runs from **unstructured** (Tokio's `abort`, raw callbacks — cancellation is
ad-hoc bookkeeping, takes effect only at the next poll point, and `select!`
cancellation-safety is a recurring footgun) to **structured** (Trio nurseries, Eio switches,
Loom scopes — failing or cancelling a scope cancels its entire subtree and guarantees cleanup
at scope exit). The completion-backend subtlety from §1.2 reappears here: cancelling an
`io_uring` op is _not free_ — you submit `IORING_OP_ASYNC_CANCEL`, but the kernel may still own
the buffer, so the slot/buffer must outlive the cancellation CQE (see
[techniques §cancellation][techniques]). Trio, Eio, and Loom are the reference designs;
Sparkles should aim for their structural guarantees (§2.4).

---

### 1.6 Buffer management

Where the reactor/proactor split has the most visible _API_ consequence (full analysis in
[techniques §buffer-management][techniques]):

| Model                             | Buffer ownership                                             | API shape                                                           | Cancellation hazard                                                                   | Used by                                                                                                        |
| --------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **Borrowed**                      | `&mut [u8]` lent during a synchronous syscall                | `read(&mut buf) -> Result<usize>`                                   | none (kernel done when call returns)                                                  | [Tokio][tokio] (epoll), [libuv][libuv], [Asio][boost-asio] readiness paths, [Go][go]                           |
| **Owned (transfer)**              | buffer _moved in_, _moved back out_                          | `read(buf) -> (Result<usize>, buf)`                                 | buffer must outlive the op; if future dropped, runtime holds the buffer until the CQE | [Monoio][monoio] (`IoBuf`), `tokio-uring`, [Glommio][glommio] (`DmaBuffer`), [.NET][dotnet] (IOCP), [Eio][eio] |
| **Kernel-provided (buffer ring)** | kernel picks a buffer from a registered pool _at completion_ | submit with `IOSQE_BUFFER_SELECT`; CQE reports the chosen buffer id | replenish ring by advancing a tail                                                    | high-throughput `io_uring` servers                                                                             |

**Borrowed** is the reactor's gift: because the kernel touches the buffer only during the
synchronous `read`, a borrowed slice is sound and ergonomic. **Owned transfer** is the
proactor's tax: [Monoio][monoio] encodes it as an `unsafe IoBuf: 'static` trait so its read
API is `read(buf) -> (Result, buf)` — you give the runtime your buffer and get it back with
the result. If a future is dropped mid-op, the runtime keeps the buffer alive (Monoio's
`Lifecycle::Ignored(Box<dyn Any>)`) until the CQE lands. This _BufResult_ pattern is shared by
`tokio-uring`, Glommio, and IOCP wrappers. **Provided buffer rings** (`IORING_REGISTER_PBUF_RING`,
Linux 5.19) solve the receive-side waste: instead of committing a buffer per pending recv (so
100k idle connections waste 100k buffers), you hand the kernel a _ring_ of buffers and it picks
one only when data arrives, reporting the id in the CQE. This decouples buffer count from
in-flight-op count and is essential for C10K-style servers. **Zero-copy** send (`SEND_ZC`,
Linux 6.0) sends directly from user pages with a two-CQE protocol: a first CQE carrying the send
result (with `IORING_CQE_F_MORE` set to signal that a notification follows), then a second
`IORING_CQE_F_NOTIF` CQE once the kernel is done with the pages and they are reusable; zero-copy
receive (`RECV_ZC`/zcrx, Linux 6.15) maps NIC buffers into userspace. Both are completion-only and
add the most lifetime complexity (see [io_uring features][uring-features]).

---

### 1.7 Summary comparison matrix

| System                   | Kernel model                   | Scheduler                | Concurrency model               | Buffer model              | Cancellation                           | `io_uring`?                  |
| ------------------------ | ------------------------------ | ------------------------ | ------------------------------- | ------------------------- | -------------------------------------- | ---------------------------- |
| [Tokio][tokio]           | reactor (+ exp. uring)         | work-stealing            | async/await (stackless)         | borrowed (owned on uring) | unstructured `abort`                   | experimental                 |
| [Glommio][glommio]       | proactor                       | thread-per-core          | async/await (`!Send`)           | owned transfer            | drop-based                             | **native**                   |
| [Monoio][monoio]         | proactor (+ epoll)             | thread-per-core          | async/await (`!Send`)           | owned (`IoBuf`)           | `ASYNC_CANCEL` + `Ignored`             | **native**                   |
| [Boost.Asio][boost-asio] | proactor (emulated/IOCP/uring) | executor                 | callbacks / coroutines          | borrowed                  | `cancellation_slot` (structured)       | **yes** (`io_uring_service`) |
| [Seastar][seastar]       | proactor (+ aio/epoll)         | thread-per-core + NUMA   | future/continuation             | owned (per-shard)         | shard-scoped drain (`gate`/`when_all`) | **yes**                      |
| [libuv][libuv]           | reactor (+ uring fs)           | single loop + threadpool | callbacks                       | borrowed                  | handle close                           | fs offload only              |
| [Zig std.Io][zig-io]     | pluggable                      | backend-dependent        | stackful fibers (evented)       | implementation-defined    | `Group` + `checkCancel`                | **yes** (PoC)                |
| [.NET][dotnet]           | reactor (+ proposed uring)     | ThreadPool               | async/await                     | owned (IOCP)              | `CancellationToken`                    | proposed PR                  |
| [Java][java]             | reactor + FFI uring; Loom      | ForkJoin / carriers      | futures / **virtual threads**   | borrowed (ByteBuffer)     | `StructuredTaskScope`                  | via JUring/Netty             |
| [Go][go]                 | reactor                        | integrated runtime       | stackful goroutines             | borrowed                  | `context` cancellation                 | **no** (Unplanned)           |
| [asyncio][python]        | reactor                        | single-threaded          | async/await                     | borrowed                  | `TaskGroup` (3.11)                     | no                           |
| [Trio][python]           | reactor                        | single-threaded          | async/await                     | borrowed                  | **nurseries** (pioneer)                | no                           |
| [Eio][eio]               | proactor (+ posix)             | per-domain               | **stackful fibers via effects** | owned                     | **`Switch`** (structured)              | **native**                   |
| [vibe-core][d-landscape] | reactor (+ exp. uring)         | fiber pool               | stackful fibers                 | borrowed-ish              | `Task` scopes                          | experimental                 |
| [during][d-landscape]    | proactor (binding)             | none                     | none                            | raw                       | raw `prepCancel`                       | **native binding**           |

Three structural conclusions fall out of this matrix and shape Part 2:

1. **The fastest `io_uring` runtimes are proactor + thread-per-core + owned-buffer** (Glommio,
   Monoio, Seastar). That combination is not an accident: thread-per-core removes the cross-core
   sync that would otherwise eat `io_uring`'s syscall savings, and owned buffers are _forced_ by
   completion semantics anyway.
2. **Direct-style ergonomics (no function coloring) are achievable without async/await** via
   stackful fibers (Go, vibe-core, Photon) or effects (Eio) — and D already ships the fiber
   primitive (`core.thread.Fiber`).
3. **Structured concurrency is the consensus modern cancellation model** (Trio, Eio, Loom,
   Seastar gates), and it must be designed in from the start because retrofitting it (asyncio)
   is painful.

---

## Part 2 — Design recommendations for the Sparkles event-horizon library

Sparkles' niche, per the [D landscape gap analysis][d-landscape], is precise and unoccupied:
**no D project unifies a completion-first, `@nogc`/`@safe`, `io_uring`-native event loop with
modern feature usage and structured cancellation.** vibe-core and Photon prove the _ergonomic_
model (stackful fibers, direct-style) but are GC-coupled and reactor-on-epoll; [during][d-landscape]
provides the _raw kernel surface_ (`@nogc nothrow betterC` SQE/CQE) but no scheduler. The
recommendations below fill the gap between them, justified against the [agent guidelines][agents]
(`@safe`/`@nogc`/`pure`/`nothrow`, `-preview=in`/`-preview=dip1000`, `-betterC`-friendliness,
range/UFCS style, `SmallBuffer`).

### 2.1 Master recommendation table

| Decision                                                                             | Rationale                                                                                                                                                                                                                                  | Trade-off                                                                                                                                 |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Completion-first (Proactor) core on io_uring**                                     | The whole point of the library; gets first-class file I/O, batched submission, registered resources, multishot — none available to epoll. Aligns with the fastest runtimes (Glommio/Monoio/Seastar).                                       | Linux-only at full power; forces owned-buffer APIs (§2.5); ABI is large and subtle.                                                       |
| **Readiness/epoll fallback behind a runtime probe**                                  | Old kernels (< 5.x features), seccomp/container lockdowns, and macOS need a path; Seastar/Monoio/Eio all ship one.                                                                                                                         | A second backend to maintain; the fallback can't expose Tier-3 features, so the API must degrade gracefully.                              |
| **Thread-per-core (share-nothing) as the primary topology**                          | Lowest tail latency, no cross-core sync to erode `io_uring`'s savings, no `Send`/shared-state cost — and it pairs naturally with `DEFER_TASKRUN + SINGLE_ISSUER`.                                                                          | Load balancing becomes the app's problem; uneven sharding = hot-shard bottleneck. Offer a single-threaded mode too.                       |
| **`DEFER_TASKRUN + SINGLE_ISSUER` per-core ring**                                    | Highest-throughput config for a dedicated I/O thread: no IPIs, no spurious wakeups, batched completion processing ([io_uring overview §operating-modes][uring-index]).                                                                     | The app _must_ periodically wait for events or completions stall; one issuer per ring (enforced with `-EEXIST`).                          |
| **Stackful fibers (`core.thread.Fiber`) for the concurrency model**                  | Direct-style, **no function coloring**, real backtraces, and D already ships the primitive `nothrow @nogc` for `yield`/`getThis`. Matches vibe-core/Photon/Go/Eio ergonomics.                                                              | Per-fiber stack memory tax (4 pages default); a context switch per resume; `betterC` needs a custom fiber if druntime is excluded (§2.3). |
| **Build on [during][d-landscape] + `core.thread.Fiber`, not vibe-core/Photon**       | `during` is the only `@nogc nothrow betterC` SQE/CQE substrate with current opcode coverage; `Fiber` is the cheap suspension primitive. vibe-core/Photon are GC- and exception-coupled.                                                    | `during` has _no_ scheduler/await/timer/cancellation — that entire layer is the work.                                                     |
| **Layer primitives in Tier order (0→3)**                                             | Each tier is a precondition for the next ([primitives][primitives]); ship a usable echo server (Tier 1) before chasing zero-copy.                                                                                                          | Resisting the temptation to wire `SEND_ZC`/zcrx early; they add the most lifetime complexity for the least early payoff.                  |
| **Owned-buffer (move/`scope`) API for I/O**                                          | Completion semantics _force_ it — a borrowed slice is unsound across submission→CQE. Mirror Monoio's `IoBuf`/BufResult with D move semantics.                                                                                              | Less ergonomic than borrowed `read(buf[])`; users must thread buffers through; needs a clean `SmallBuffer`/pool story.                    |
| **Structured concurrency (scopes) over `IO_LINK` + `LINK_TIMEOUT` + `ASYNC_CANCEL`** | Trio/Eio/Loom consensus; cancellation must propagate structurally and clean up on scope exit.                                                                                                                                              | Must hold buffers/slots alive until the cancellation CQE; more bookkeeping than unstructured `abort`.                                     |
| **Three-tier feature probing (backend → opcode → feature flag)**                     | The general pattern every portable uring runtime follows (Seastar/Tokio/Monoio); `during` already exposes `Uring.probe()` and the negotiated `SetupFeatures` bitset via `Uring.params()` (e.g. `params.features & SetupFeatures.EXT_ARG`). | A probe/dispatch layer on every capability; testing the matrix across kernels is hard.                                                    |

### 2.2 Backend strategy: completion-first with a readiness fallback

The core loop should be **natively completion-based** on `io_uring` — submit ops, reap CQEs,
correlate by `user_data` — _not_ readiness emulated on epoll (the thing vibe.d does today).
Concretely, mirror the canonical hand-rolled completion loop already shown in `during`'s
`examples/echo_server` (`io.wait(1)` → dispatch on `io.front.user_data` → `io.popFront()`;
see [D landscape §during][d-landscape]) and replace its manual dispatch with a fiber
scheduler (§2.3).

The **operating mode** should target, per [io_uring overview §operating-modes][uring-index]:

- **`IORING_SETUP_SINGLE_ISSUER` + `IORING_SETUP_DEFER_TASKRUN`** for the thread-per-core
  model — one ring per core, one issuing thread per ring, completions deferred until the loop
  explicitly waits. This is the highest-throughput dedicated-I/O-thread configuration and a
  perfect fit for share-nothing (no other thread submits to this ring anyway).
- **`IORING_SETUP_COOP_TASKRUN` + `IORING_SETUP_TASKRUN_FLAG`** as a gentler default for the
  single-threaded mode (skip the IPI, surface pending task-work so peek loops stay correct).
- Leave **SQPOLL** and **IOPOLL** as opt-in tuning knobs — they only win under sustained load
  and burn a dedicated core.

The **fallback chain** follows the field consensus (Seastar's `io_uring → linux-aio → epoll`,
Monoio's `iouring`/`legacy` cfg split, Eio's `eio_linux`/`eio_posix`):

| Probe outcome                                     | Sparkles behaviour                                                 |
| ------------------------------------------------- | ------------------------------------------------------------------ |
| `io_uring_setup` succeeds, required feats present | full proactor path (Tier 3 features enabled per-op probe)          |
| `io_uring_setup` → `ENOSYS` / `EPERM` (seccomp)   | fall back to an epoll readiness backend (Tier 1–2 only)            |
| `IORING_REGISTER_PROBE` → opcode unsupported      | per-op fallback for _that_ op (e.g. multishot → single-shot loop)  |
| feature flag absent (e.g. no `EXT_ARG`)           | use the older-kernel path (timeout SQE instead of inline timespec) |
| non-Linux (macOS)                                 | kqueue readiness backend                                           |

The fallback backend will only ever reach Tier 1–2 (no registered buffers, no provided rings,
no multishot — epoll has _no_ analogue, see [primitives Tier 3][primitives]), so the public API
must be designed so those features degrade gracefully (e.g. a "provided-buffer-ring" abstraction
that transparently becomes per-op buffers on epoll).

**Why thread-per-core _pairs_ with `io_uring` specifically.** The two choices reinforce each
other and are not independent. `io_uring`'s whole performance story is _eliminating per-op cost_
(syscall amortization, lock-free SPSC rings, registered resources — [`io_uring` overview
§performance][uring-index]). A work-stealing scheduler would claw much of that back: stealing a
task between cores reintroduces the cross-core cache-line bouncing and the atomic synchronization
that the lock-free ring was designed to avoid, and it would force tasks to be thread-safe.
Pinning one ring per core with `SINGLE_ISSUER` means the _kernel itself_ drops submission-path
locking (the promise that only one task submits), and `DEFER_TASKRUN` means completions land in
exactly the context that will process them, with no IPI. This is why every native `io_uring`
runtime that chases peak throughput — [Glommio][glommio], [Monoio][monoio], [Seastar][seastar] —
is thread-per-core, while the work-stealing runtimes ([Tokio][tokio]) keep `io_uring` experimental
and layered over their existing reactor.

### 2.3 Concurrency model: stackful fibers over `during`

**Recommendation: stackful fibers via `core.thread.Fiber`, exposing a direct-style
("blocking-looking") API, with the proactor underneath.** Justification:

- **No function coloring.** The biggest ergonomic win in §1.4. A `read` that _looks_
  synchronous but parks the fiber on submission and resumes it from the CQE is exactly the
  vibe-core/Photon/Go/Eio model, and it composes with ordinary D control flow, UFCS range
  pipelines, and `scope(exit)` cleanup without an `async` keyword splitting the codebase.
- **D ships the primitive.** `core.thread.Fiber` provides `yield`/`getThis`/`state` as
  `nothrow @nogc` (only construction allocates the stack via `mmap` + guard page; see
  [D landscape §Fiber][d-landscape]). The loop pattern is mechanical: each connection runs in a
  `Fiber`; on a would-block the I/O shim submits an SQE with `user_data` = the parked fiber's
  identity and calls `Fiber.yield()`; the completion handler maps `cqe.user_data` → fiber and
  calls `fib.call()` to resume.
- **Real backtraces and direct error handling.** A crash inside a fiber has a real stack;
  errors can be `nothrow` error-as-value (matching `during`'s `-errno` returns) rather than
  exceptions, keeping the hot path `@nogc nothrow`.

Why **not** stackless awaitables: D has no first-class `async`/`await` state-machine transform.
Emulating one (hand-rolled coroutine structs, or a library combinator monad) re-introduces
function coloring and loses the direct-style ergonomics that are D's existing strength, for no
proportionate gain over fibers in a `@nogc` setting.

The one real cost is the **per-fiber stack memory tax** (4 pages default on Linux). Mitigations:
small default stacks with guard pages, fiber pooling/recycling (`Fiber.reset` on a `TERM`
fiber), and — for a strict `-betterC` configuration that excludes druntime — a thin custom
stackful-context primitive over the same `switch_context_asm.S`-style register save/restore, or
documenting that fibers require druntime while keeping the _raw submit/reap_ layer pure
`-betterC` (so `during`-style users who want manual correlation can stay below the fiber layer).

| Layer                                              | `@safe`/`@nogc`/`nothrow`/`betterC` reach                            |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| Raw ring (submit/reap, `during` substrate)         | `@nogc nothrow @safe` (`@trusted` at syscall edge), `-betterC` clean |
| Scheduler (fiber park/resume keyed by `user_data`) | `@nogc nothrow`; needs druntime for `Fiber` (or a custom context)    |
| Direct-style I/O API (`read`/`write`/`accept`)     | `@nogc nothrow`; `@safe` surface over `@trusted` ring ops            |
| Structured-concurrency scopes / timers             | `@nogc nothrow`; allocation via `SmallBuffer`/pools                  |

**Illustrative API shape.** The target ergonomics — direct-style, owned-buffer, structured —
sketched (D pseudocode, _not_ runnable; it presumes the scheduler and scope types of §2.4):

```d
// One ring per core; SINGLE_ISSUER + DEFER_TASKRUN configured internally.
void serve(ref Loop loop) @safe nothrow
{
    loop.scope_((ref Scope sc) {           // structured: all child fibers join here
        auto listener = loop.listenTcp(8080);
        // multishot accept: one SQE, a fiber resumed per connection
        foreach (conn; listener.acceptMultishot)
            sc.spawn(() => echo(conn));    // child fiber, lifetime bound to `sc`
    });                                     // scope exit cancels/drains in-flight ops
}

void echo(TcpConn conn) @safe nothrow
{
    auto buf = SmallBuffer!(ubyte, 4096)(); // or a pooled / registered buffer
    for (;;)
    {
        // owned-buffer transfer: `buf` moves in, comes back with the result.
        // Looks blocking; actually submits an SQE and yields the fiber until the CQE.
        BufResult r = conn.read(move(buf));
        if (r.res <= 0) break;             // error-as-value (-errno), no exception
        buf = conn.write(r.buf[0 .. r.res]).buf; // get the buffer back to reuse
    }
}
```

The key properties visible here map one-to-one to the recommendations: no `async`/`await`
coloring (§2.3), `BufResult` ownership transfer (§2.5), a lexical `scope_` that joins its
children (§2.4), multishot accept (§2.4 Tier 3), and `@nogc nothrow` throughout with
`SmallBuffer`/pooled buffers (the [agent guidelines][agents]).

### 2.4 Primitive layering and the structured-concurrency story

Follow the [tier model][primitives] strictly, mapping each tier to `io_uring` features per the
order in [io_uring features][uring-features]:

| Tier  | Sparkles deliverable                                                                                         | `io_uring` features wired                                                                                                                        | Notes                                            |
| ----- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| **0** | poller/driver, monotonic timer, cross-thread wakeup                                                          | `io_uring_enter` (`submit_and_wait`); ring timeout (`TIMEOUT`/`LINK_TIMEOUT`); `MSG_RING` or eventfd wakeup                                      | the minimal loop; one ring per core              |
| **1** | non-blocking connect/accept/read/write/UDP; per-op timeout; fiber spawn; `run()` driver                      | `CONNECT`/`ACCEPT`/`READ`/`WRITE`/`RECV`/`SEND`; `LINK_TIMEOUT` for per-op deadlines                                                             | usable echo server; **first milestone**          |
| **2** | files, DNS (thread-pool), signals, subprocess, cancellation, deadlines, structured scopes, graceful shutdown | `OPENAT`/`STATX`/`FSYNC` (native files!); `WAITID` (6.7) for child reap; `ASYNC_CANCEL`; `IOSQE_IO_LINK`                                         | files are the proactor's headline win over epoll |
| **3** | registered files/buffers, provided buffer rings, multishot accept/recv, thread-per-core sharding             | `REGISTER_FILES`/`REGISTER_BUFFERS` → `READ_FIXED`/`WRITE_FIXED`; `REGISTER_PBUF_RING`; multishot `ACCEPT`/`RECV`; `MSG_RING` cross-core handoff | the throughput payoff                            |

**Feature order within the tiers** (what to target first vs. defer):

- **Target early (high payoff, manageable lifetime):** registered files and registered buffers
  (`during`'s `registerFiles`/`registerBuffers` are ready), provided buffer rings
  (`registerBufRing`, the C10K enabler), multishot accept/recv (eliminate the re-arm syscall),
  linked timeouts (`prepLinkTimeout` for per-op deadlines with no userspace timer).
- **Defer (highest lifetime complexity, narrow early benefit):** zero-copy send (`SEND_ZC`,
  two-CQE `F_MORE`/`F_NOTIF` protocol), zero-copy receive (zcrx, NIC-buffer mapping), NAPI
  busy-poll, and `uring_cmd` passthrough (NVMe, needs SQE128). These pay off only at extreme
  throughput and each adds a correctness hazard (buffer-reuse-after-notif, SQE128 layout) that
  is not worth carrying through the early API.

**Structured concurrency** must be designed in from Tier 2, taking Trio/Eio/Loom as the model
(§1.5). A Sparkles **scope** (working name — analogous to an Eio `Switch` / Trio nursery) owns
its child fibers; the scope does not exit until all children finish or are cancelled. Map it
onto `io_uring` primitives:

- **Linked sequences** (`IOSQE_IO_LINK`) express "connect, then send, then recv" as one
  submission that aborts the chain on first error.
- **Deadlines** are a scope with a `LINK_TIMEOUT` attached, or a timer-driven `ASYNC_CANCEL` —
  exactly Trio's "a deadline _is_ a cancel scope."
- **Cancellation** submits `IORING_OP_ASYNC_CANCEL` referencing the op's `user_data`, but
  (critically, per §1.2/§1.6) keeps the buffer and slab slot alive until the cancellation CQE
  arrives — Monoio's `Lifecycle::Ignored` discipline. `Eio.Cancel.protect`-style shielding
  should exist for critical sections.
- **Graceful shutdown** stops accepting (cancel the multishot accept), drains in-flight CQEs,
  then reclaims registered files/buffers — mirroring Seastar's shard-drain-before-shutdown
  discipline (its `gate`/`when_all` idiom).

### 2.5 Buffer-ownership API

Because the core is a proactor, buffers **must** transfer ownership across submission→CQE
(§1.6). The recommended D shape mirrors Monoio's `IoBuf`/BufResult but uses **D move semantics
and `scope`** instead of Rust's `'static`:

- An I/O op _takes_ a buffer (by move / `scope` transfer) and _returns_ it alongside the
  result: `BufResult = (long res, Buf buf)` — the caller gets the buffer back when the op
  completes, never holds a dangling borrow.
- For the common case, back buffers with `SmallBuffer` (the repo's `@nogc` dynamic buffer) or a
  pooled slab; pair pooling with **registered buffers** (`READ_FIXED`/`WRITE_FIXED`) and
  **provided buffer rings** so long-lived reusable buffers serve double duty.
- On the **receive** path, prefer provided buffer rings: submit `recv` _without_ a buffer and
  let the kernel pick one from the registered pool at completion (the CQE reports the id),
  decoupling buffer count from connection count.
- `-preview=dip1000` `scope`/`return ref` (already used in `during`'s prep helpers) should
  enforce that any _pointer-carrying_ SQE operand (iovecs, `timespec`, `msghdr`) outlives the
  op — the classic SQPOLL/async-offload use-after-free hazard ([io_uring overview §weaknesses][uring-index]).
- The epoll fallback can present the _same_ owned API (it simply borrows internally), so user
  code is portable across backends; the abstraction cost is hidden in the backend, not the API.

### 2.6 Feature-probe / fallback strategy

Adopt the **three-tier probe** that every portable uring runtime uses
([techniques §feature-probing][techniques]):

1. **Backend selection** — try `io_uring_setup`; on `ENOSYS`/`EPERM` fall to epoll (Linux) or
   kqueue (macOS). Apply Seastar-style version-aware guards if needed.
2. **Opcode probing** — `Uring.probe()` (already in `during`, wraps `IORING_REGISTER_PROBE`)
   gates Tier-3 ops; an unsupported opcode falls back per-op (multishot → single-shot re-arm
   loop, `READ_FIXED` → plain `READ`).
3. **Feature-flag probing** — read the negotiated `IORING_FEAT_*` bitset returned by
   `io_uring_setup` (in `during`, `Uring.params().features & SetupFeatures.EXT_ARG`; monoio's
   equivalent is `params().is_feature_ext_arg()`) to choose, e.g., inline-timespec waits
   (`IORING_FEAT_EXT_ARG`, 5.11) vs. a `Timeout` SQE; `during`'s per-field `since Linux x.y`
   annotations make these gating decisions readable straight from the binding.

The kernel-version-to-feature matrix lives in [io_uring timeline][uring-timeline]; the per-op
flag semantics in [io_uring opcodes][uring-opcodes].

### 2.7 Honest trade-offs and open questions

| Tension                           | The trade-off                                                                               | Stance / open question                                                                                                                                  |
| --------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Completion-first vs. portability  | Full power is Linux-only; the fallback can't reach Tier 3                                   | Accept it: Sparkles is _io_uring-first_ by name; the fallback is correctness, not parity.                                                               |
| Thread-per-core vs. work-stealing | Lower tail latency, but manual load balancing and hot-shard risk                            | Default thread-per-core; offer single-threaded; **work-stealing is out of scope** unless a clear need emerges (it would reintroduce `Send`/sync costs). |
| Fibers vs. stackless              | Direct-style + backtraces, but a per-fiber stack tax                                        | Fibers win for D; **open:** how small can default stacks be, and is a `betterC` custom-context primitive worth building vs. requiring druntime?         |
| Owned buffers vs. ergonomics      | Sound, but less convenient than borrowed slices                                             | Owned is non-negotiable for a proactor; invest in `SmallBuffer`/pool ergonomics + provided rings to soften it.                                          |
| `@nogc`/`betterC` reach           | Raw ring is `betterC`-clean; `Fiber` needs druntime                                         | **Open:** layer so the raw submit/reap API is usable below the scheduler in pure `-betterC`.                                                            |
| Structured cancellation cost      | Clean propagation, but buffers/slots must outlive cancel CQEs                               | Worth it; encode the Monoio `Ignored`-style lifecycle in the scheduler, not the user API.                                                               |
| `io_uring` security surface       | A steady stream of CVEs; some environments disable it (`io_uring_disabled` sysctl, seccomp) | The epoll fallback _is_ the mitigation; detect the lockdown at probe time and degrade silently.                                                         |
| Cross-core handoff mechanism      | `MSG_RING` (5.18+) vs. eventfd vs. a `@nogc` channel                                        | **Open:** benchmark `MSG_RING` against an eventfd-wakeup `std.concurrency`-style channel for inter-shard work; `during` exposes `prepMsgRing`.          |
| Verifying the kernel matrix       | Behaviour varies wildly by kernel version                                                   | **Open:** how to CI-test the probe/fallback paths without a fleet of kernels (qemu matrix? feature-flag injection?).                                    |

The summary: Sparkles should be a **completion-first, thread-per-core, fiber-scheduled
`io_uring` loop built on [during][d-landscape] + `core.thread.Fiber`**, with owned-buffer
APIs, structured-concurrency scopes mapped onto `IO_LINK`/`LINK_TIMEOUT`/`ASYNC_CANCEL`, and
a three-tier probe that degrades to an epoll/kqueue readiness fallback — occupying the exact
niche the [D landscape gap analysis][d-landscape] identifies and combining the best ideas
from [Glommio][glommio]/[Monoio][monoio] (thread-per-core + owned buffers),
[Eio][eio]/[Trio][python] (structured concurrency), and the direct-style ergonomics that D's
fibers already make idiomatic.

---

## Sources

- Cross-cutting concept docs: [primitives][primitives], [techniques][techniques],
  [effects and event loops][effects]
- `io_uring` references: [overview][uring-index], [features][uring-features],
  [opcodes][uring-opcodes], [timeline][uring-timeline]
- Per-library deep-dives: [Tokio][tokio], [Glommio][glommio], [Monoio][monoio],
  [Boost.Asio][boost-asio], [Seastar][seastar], [libuv][libuv], [Zig std.Io][zig-io],
  [.NET][dotnet], [Java][java], [Go netpoller][go], [Python async][python], [Eio][eio]
- D ecosystem: [D landscape][d-landscape]
- Effect-system corpus: [OCaml Eio][eio], [Java Loom][loom], [Cats-Effect][cats-effect],
  [ZIO][zio], [TypeScript Effect][ts-effect]
- Repo conventions: [agent guidelines][agents]
- Survey index: [the async-io index][index]

<!-- References -->

[index]: ./index.md
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[effects]: ./effects-and-event-loops.md
[d-landscape]: ./d-landscape.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[boost-asio]: ./boost-asio.md
[seastar]: ./seastar.md
[libuv]: ./libuv.md
[zig-io]: ./zig-io.md
[dotnet]: ./dotnet.md
[java]: ./java.md
[go]: ./go-netpoller.md
[python]: ./python-async.md
[eio]: ../algebraic-effects/ocaml-eio.md
[loom]: ../algebraic-effects/java-loom.md
[cats-effect]: ../algebraic-effects/scala-cats-effect.md
[zio]: ../algebraic-effects/scala-zio.md
[ts-effect]: ../algebraic-effects/typescript-effect.md
[uring-index]: ./io-uring/index.md
[uring-features]: ./io-uring/features.md
[uring-opcodes]: ./io-uring/opcodes-reference.md
[uring-timeline]: ./io-uring/timeline.md
[agents]: ../../guidelines/AGENTS.md
