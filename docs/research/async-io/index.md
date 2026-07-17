# Async I/O & Event Loops

A breadth-first survey of asynchronous I/O and event-loop design across languages and
runtimes, mapped against the Linux `io_uring` feature surface, to inform a `@nogc`/`@safe`,
completion-first event-loop library for Sparkles ("event-horizon").

This survey answers five questions:

1. **Primitives** — what building blocks does an event loop need, from the smallest loop
   that fires one timer to a fully-featured thread-per-core runtime? See [primitives][primitives].
2. **Techniques** — what do state-of-the-art runtimes build _on top_ of the kernel's
   notification primitives (reactor/proactor, schedulers, wakers, timer wheels, buffer
   ownership, cancellation, feature probing)? See [techniques][techniques].
3. **Cross-language design differences** — how do Tokio, Glommio, monoio, Boost.Asio,
   Seastar, libuv, Zig `std.Io`, .NET, Java, Go, Python, and OCaml Eio differ in I/O model,
   backend, and concurrency model? See the [catalog](#master-catalog) and [comparison][comparison].
4. **`io_uring` features** — exactly which operations, setup flags, and registration opcodes
   exist, and in which kernel version they landed, through **Linux v7.1-rc6**. See the
   [io_uring reference](#io_uring-reference).
5. **Interplay with algebraic effect systems** — how do effect handlers, fibers, and
   continuations resume suspended computations from a completion, and how does that relate
   to poll-based futures and green threads? See [effects-and-event-loops][effects] and the
   [algebraic-effects corpus][ae-index].

> **Scope note.** This is the master index for the async-io research tree. Each row links
> to a deep-dive that was written and fact-checked independently; where this index
> summarizes a system, the deep-dive is the source of truth. `io_uring` version markers here
> are kept consistent with the [chronology][uring-timeline], which was checked against a
> Linux **v7.1-rc6** tree paired with **liburing 2.15** — markers at `6.13` and later are
> forward-dated relative to general public knowledge ("as observed in this checkout").

**Last reviewed:** June 2, 2026

---

## Master Catalog

One row per surveyed system. **I/O model** is the reactor/proactor classification from
[techniques][techniques] (Reactor = readiness, Proactor = completion, Hybrid = both, behind
one API). **Abstraction layer** places the system on the stack _raw syscall binding →
driver/reactor → runtime/executor → effect system_ (see [the abstraction taxonomy](#by-abstraction-layer)).

| System           | Language   | I/O model                                  | Backend(s)                                                                         | Concurrency model                                             | Abstraction layer            | Link                                        |
| ---------------- | ---------- | ------------------------------------------ | ---------------------------------------------------------------------------------- | ------------------------------------------------------------- | ---------------------------- | ------------------------------------------- |
| **Tokio**        | Rust       | Reactor (+ experimental Proactor)          | mio (epoll/kqueue/IOCP); `io-uring` (unstable, files)                              | Work-stealing M:N; poll-based `Future`/`Waker`                | Runtime / executor           | [tokio.md][tokio]                           |
| **Glommio**      | Rust       | Proactor                                   | `io_uring` only (Linux); no reactor fallback                                       | Thread-per-core, share-nothing; `async`/`.await`              | Runtime / executor           | [glommio.md][glommio]                       |
| **monoio**       | Rust       | Proactor (+ Reactor fallback)              | `io_uring`; epoll/kqueue via mio fallback                                          | Thread-per-core, `!Send`; owned-buffer "rent"                 | Runtime / executor           | [monoio.md][monoio]                         |
| **Boost.Asio**   | C++        | Proactor (emulated or native)              | epoll/kqueue/select (emulated); IOCP & `io_uring` (native)                         | Completion tokens (callbacks/futures/coroutines)              | Runtime / executor           | [boost-asio.md][boost-asio]                 |
| **Seastar**      | C++        | Hybrid (pluggable)                         | epoll (reactor); linux-aio & `io_uring` (proactor)                                 | Thread-per-core, share-nothing; future/promise                | Runtime / executor           | [seastar.md][seastar]                       |
| **libuv**        | C          | Reactor (+ Proactor)                       | epoll/kqueue/event-ports; IOCP; `io_uring` (fs offload)                            | Callbacks + worker threadpool; runtime owns loop              | Driver / reactor + runtime   | [libuv.md][libuv]                           |
| **Zig `std.Io`** | Zig        | Hybrid (vtable, per-backend)               | Threaded; Uring; Kqueue; Dispatch (GCD)                                            | Capability vtable; stackful fibers (evented)                  | Driver vtable + runtime      | [zig-io.md][zig-io]                         |
| **.NET runtime** | C#/C       | Reactor (Proactor in PR)                   | epoll/kqueue (`SocketAsyncEngine`); IOCP; `io_uring` (PR)                          | `Task`/`ValueTask` over managed ThreadPool                    | Runtime / executor           | [dotnet.md][dotnet]                         |
| **Java**         | Java       | Reactor / Proactor (varies)                | NIO epoll/kqueue/IOCP; JUring/Netty `io_uring` (FFI)                               | NIO selectors; Loom virtual threads                           | Driver + runtime             | [java.md][java]                             |
| **Go runtime**   | Go         | Reactor                                    | epoll/kqueue/IOCP netpoller (no `io_uring`)                                        | Integrated runtime; goroutines (M:N green threads)            | Integrated runtime           | [go-netpoller.md][go]                       |
| **Python**       | Python     | Reactor (Proactor on Windows)              | selectors epoll/kqueue; libuv (uvloop); IOCP                                       | `async`/`await` coroutines; Trio structured-concurrency       | Runtime / executor           | [python-async.md][python]                   |
| **OCaml Eio**    | OCaml      | Proactor (+ Reactor fallback)              | `io_uring` (`eio_linux`); `poll`/`ppoll` (`eio_posix`)                             | Effect handlers; one-shot delimited continuations             | Effect system                | [eio-backend.md][eio]                       |
| **Cats Effect**  | Scala      | Reactor (+ Proactor PR)                    | epoll/kqueue selector; `io_uring` (Netty/native PR)                                | `IO` monad fibers; work-stealing                              | Effect system                | [cats-effect][cats-effect] · effects corpus |
| **ZIO**          | Scala      | Reactor                                    | JVM NIO selectors / Netty                                                          | `ZIO` fibers; structured concurrency                          | Effect system                | [ZIO][zio] · effects corpus                 |
| **Effect-TS**    | TypeScript | Reactor (host loop)                        | Node/Deno/Bun event loop (libuv et al.)                                            | Generators-as-fibers; structured concurrency                  | Effect system                | [Effect-TS][effect-ts] · effects corpus     |
| **Haskell**      | Haskell    | Reactor (RTS) + Proactor (`blockio-uring`) | RTS IO manager epoll/kqueue/IOCP (MIO); `io_uring` for block I/O (`blockio-uring`) | Green threads (M:N) park on RTS loop; `blockio-uring` batches | Integrated runtime + library | [haskell.md][haskell]                       |
| **Lean 4**       | Lean       | Reactor                                    | libuv (epoll/kqueue/event-ports/IOCP); no `io_uring`                               | Monadic `Task`/`IO.Promise`; await = `Task.bind`              | Runtime / executor           | [lean.md][lean]                             |

> The three Scala/TypeScript effect libraries are surveyed in depth in the
> [algebraic-effects corpus][ae-index]; the rows above cross-link rather than duplicate.
> For D's own existing options (vibe.d/eventcore, Photon, `during`, `core.thread.Fiber`)
> and the gap a Sparkles loop would fill, see [d-landscape][d-landscape].

### Backend capabilities at a glance

A coarser cut of the same systems by _which kernel facilities they actually exercise_. "`io_uring`
depth" sketches how far past the v5.1 baseline (read/write/fsync/poll) a backend reaches — see
the [features][uring-features] and [timeline][uring-timeline] docs for the precise op-by-op
support and the per-runtime configuration each adopts.

| System                   |      epoll/kqueue       |     IOCP      |      `io_uring`       |    Worker threadpool    | `io_uring` depth (if used)                                                   |
| ------------------------ | :---------------------: | :-----------: | :-------------------: | :---------------------: | ---------------------------------------------------------------------------- |
| [Tokio][tokio]           |      ✅ (default)       |      ✅       |      ⚠️ unstable      |   ✅ (blocking pool)    | files only, behind `tokio_unstable` + `io-uring`                             |
| [Glommio][glommio]       |            —            |       —       |        ✅ only        |            —            | deep: 3 rings/CPU, registered buffers, `IOPOLL` for `O_DIRECT` NVMe          |
| [monoio][monoio]         |       ✅ fallback       |  ✅ fallback  |      ✅ primary       |            —            | owned-buffer "rent" model; deferred batched SQE submission; `poll-io` bridge |
| [Boost.Asio][boost-asio] | ✅ (emulated proactor)  |   ✅ native   |   ✅ native (Linux)   |  ✅ (resolver, files)   | `io_uring_service` for file & descriptor ops                                 |
| [Seastar][seastar]       |  ✅ (reactor backend)   |       —       | ✅ (proactor backend) |   ✅ (syscall thread)   | pluggable; linux-aio or `io_uring`; userspace busy-poll                      |
| [libuv][libuv]           |      ✅ (default)       |      ✅       |    ✅ (fs offload)    | ✅ (fs/DNS/getaddrinfo) | filesystem-op offload only; sockets stay on epoll                            |
| [Zig `std.Io`][zig-io]   |       ✅ (Kqueue)       |       —       |      ✅ (Uring)       |      ✅ (Threaded)      | full Uring backend pairs `io_uring` with stackful fibers                     |
| [.NET][dotnet]           |      ✅ (default)       |      ✅       |      ⚠️ PR only       |     ✅ (ThreadPool)     | opt-in completion engine ([PR #124374][PR #124374]), not merged              |
| [Java][java]             |        ✅ (NIO)         |      ✅       | ✅ (JUring/Netty FFI) |    ✅ (NIO.2 group)     | FFI to liburing: fixed buffers, registered files, multishot accept           |
| [Go][go]                 |     ✅ (netpoller)      |      ✅       |           —           |    ✅ (cgo/syscall)     | not used — netpoller is readiness-only                                       |
| [Python][python]         |     ✅ (selectors)      | ✅ (Proactor) |     — (no stdlib)     |      ✅ (executor)      | none in stdlib; uvloop uses libuv (which offloads fs to `io_uring`)          |
| [OCaml Eio][eio]         | ✅ (`eio_posix` `poll`) |       —       |   ✅ (`eio_linux`)    |            —            | full backend; CQE carries the suspended continuation tag                     |

---

## Taxonomy

### By I/O model

The single most important axis is _who issues the I/O syscall and who gets told_ — the
**Reactor** (readiness) vs **Proactor** (completion) split, named in Schmidt et al.'s POSA2
patterns. See [techniques][techniques] and [primitives][primitives] for the full treatment.

| I/O model                 | Kernel tells you                                                                   | Canonical backends                      | Systems                                                                                                                                                       |
| ------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Reactor (readiness)**   | "fd is _ready_ — you may syscall without blocking now"                             | epoll, kqueue, event ports, poll/select | [Tokio][tokio] (default), [Go][go], [Python][python] (Unix), [.NET][dotnet] (today), Java NIO, [Cats Effect][cats-effect], [ZIO][zio], [Effect-TS][effect-ts] |
| **Proactor (completion)** | "your operation _finished_ — here is the result/bytes"                             | `io_uring`, IOCP, POSIX AIO             | [Glommio][glommio], [monoio][monoio] (primary), [OCaml Eio][eio] (Linux), [Boost.Asio][boost-asio] (model), JUring/Netty ([Java][java])                       |
| **Hybrid**                | Both, behind one API (often a reactor emulating a proactor, or pluggable backends) | mixed                                   | [libuv][libuv], [Seastar][seastar], [Zig `std.Io`][zig-io], [Boost.Asio][boost-asio] (emulated proactor over epoll)                                           |

> `io_uring` can _also_ be driven readiness-style via `IORING_OP_POLL_ADD` (especially its
> multishot form), which several runtimes use as a migration bridge — see the
> [primitives][primitives] readiness/completion paragraph and monoio's `poll-io` feature in
> [techniques][techniques].

### By concurrency model

How a suspended computation is represented and resumed when the I/O completes. See
[effects-and-event-loops][effects] for how completions map back onto each representation.

| Concurrency model                     | Suspended computation is…                               | Systems                                                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Callbacks**                         | A registered continuation function invoked on the event | [libuv][libuv], [Boost.Asio][boost-asio] (callback token), asyncio's `add_reader`/`add_writer` floor ([Python][python])                                     |
| **Futures / promises**                | A promise resolved by the loop; continuations chained   | [Seastar][seastar] (future/promise), [Boost.Asio][boost-asio] (`use_future`), [.NET][dotnet] (`Task`/`ValueTask`)                                           |
| **`async`/`await` state machines**    | A compiler-lowered state machine polled by an executor  | [Tokio][tokio], [Glommio][glommio], [monoio][monoio], [Python][python] (coroutines), C++20 coroutines on [Boost.Asio][boost-asio]                           |
| **Stackful fibers / green threads**   | A parked stack resumed on its OS thread/carrier         | [Zig `std.Io`][zig-io] (evented backends), Java [Loom][java-loom] virtual threads ([Java][java]), D's `core.thread.Fiber` ([d-landscape][d-landscape])      |
| **Algebraic effects / continuations** | A one-shot delimited continuation captured by a handler | [OCaml Eio][eio] (`Effect.Deep`), and the broader [effects corpus][ae-index] ([Cats Effect][cats-effect], [ZIO][zio], [Effect-TS][effect-ts], [Koka][koka]) |
| **Integrated runtime (goroutines)**   | A goroutine parked by the runtime; no user-visible loop | [Go][go] netpoller + G-M-P scheduler                                                                                                                        |

### By abstraction layer

Where a system sits on the stack. Higher layers are built atop lower ones; many systems
span two layers (e.g. libuv is both a reactor _and_ a runtime).

| Layer                   | Concern                                                          | Systems / artifacts                                                                                                                                                                  |
| ----------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Raw syscall binding** | SQE/CQE building blocks, no scheduling                           | D's [`during`][d-landscape]; [liburing] under libuv/Glommio/monoio; JUring's `liburing` FFI ([Java][java])                                                                           |
| **Driver / reactor**    | Demultiplex readiness/completion across OSes                     | mio (under [Tokio][tokio]), [libuv][libuv] `uv_loop_t`, .NET `SocketAsyncEngine` ([dotnet][dotnet]), Go netpoller, [Zig][zig-io] `Io.VTable`, eventcore ([d-landscape][d-landscape]) |
| **Runtime / executor**  | Schedule tasks, drive the loop, integrate timers & blocking pool | [Tokio][tokio], [Glommio][glommio], [monoio][monoio], [Seastar][seastar], [Boost.Asio][boost-asio], [Python][python] asyncio/Trio, [Go][go]                                          |
| **Effect system**       | Express I/O & concurrency as a typed/handled effect              | [OCaml Eio][eio], [Cats Effect][cats-effect], [ZIO][zio], [Effect-TS][effect-ts], [Koka][koka] (see [effects corpus][ae-index])                                                      |

---

## Milestones

A high-confidence timeline interleaving **`io_uring` kernel milestones** (cross-checked
against the [chronology][uring-timeline]) with **event-loop / runtime milestones**. Dates
at `6.13` and later are forward-dated "as observed in the v7.1-rc6 checkout" — see the
[timeline][uring-timeline] for the caveat.

| Date           | `io_uring` kernel milestone                                                                   | Event-loop / runtime milestone                                                                                          |
| -------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 2011           | —                                                                                             | **libuv** extracted from Node.js (epoll/kqueue/IOCP reactor)                                                            |
| 2014–2015      | —                                                                                             | **Seastar** announced by ScyllaDB (thread-per-core C++)                                                                 |
| Dec 2016       | —                                                                                             | **Python `asyncio`** stable in CPython 3.6 ([PEP 3156]); **Tokio** 0.1 announced (Rust readiness reactor over mio)      |
| 2017           | —                                                                                             | **Trio** 0.1 — nurseries & cancel scopes define structured concurrency                                                  |
| **May 2019**   | **v5.1** — `io_uring` debuts (SQ/CQ rings, `setup`/`enter`/`register`; read/write/fsync/poll) | —                                                                                                                       |
| Jan 2020       | **v5.5** — accept/connect, async-cancel, link-timeout                                         | —                                                                                                                       |
| Mar 2020       | **v5.6** — filesystem/syscall expansion; `REGISTER_PROBE` (feature detection)                 | —                                                                                                                       |
| May 2020       | **v5.7** — splice, provided buffers, `FEAT_FAST_POLL` (competitive readiness)                 | —                                                                                                                       |
| Nov 2020       | —                                                                                             | **Tokio 1.0** released                                                                                                  |
| 2020           | —                                                                                             | **Glommio** (Datadog) & **Monoio** (ByteDance) thread-per-core runtimes emerge                                          |
| Jul 2022       | **v5.19** — provided **buffer rings**, big SQE/CQE, `IORING_OP_SOCKET`                        | —                                                                                                                       |
| Oct 2022       | **v6.0** — `SEND_ZC` zero-copy send, multishot recv, `SETUP_SINGLE_ISSUER`                    | —                                                                                                                       |
| Dec 2022       | **v6.1** — `SENDMSG_ZC`, `SETUP_DEFER_TASKRUN` (the high-perf config)                         | —                                                                                                                       |
| 2022–2023      | —                                                                                             | **OCaml 5.0** ships effect handlers; **Eio** built on `io_uring` + effects                                              |
| Sep 2023       | —                                                                                             | **Java 21 LTS** — **Project Loom** virtual threads GA ([JEP 444])                                                       |
| Jan 2024       | **v6.7** — futex, waitid, read-multishot                                                      | —                                                                                                                       |
| May 2025\*     | **v6.15** — zero-copy receive (`RECV_ZC` + `ZCRX_IFQ`), `EPOLL_WAIT`, vectored fixed I/O      | —                                                                                                                       |
| 2025–2026      | —                                                                                             | **.NET `io_uring` engine** proposed ([PR #124374], opt-in, not merged); **Zig `std.Io`** vtable in development for 0.16 |
| Apr 2026\*     | **v7.0** — SQ rewind                                                                          | —                                                                                                                       |
| **May 2026\*** | **v7.1-rc6** — current checkout (liburing 2.15)                                               | This survey's ground truth                                                                                              |

<sub>\* Forward-dated relative to general public knowledge — see the [timeline caveat][uring-timeline].</sub>

---

## Quick Navigation

### Suggested reading paths

- **"I want the model first."** [primitives][primitives] → [techniques][techniques] → [io_uring programming model][uring-index] → one proactor deep-dive ([Glommio][glommio] or [monoio][monoio]).
- **"I want the `io_uring` details."** [io_uring programming model][uring-index] → [features][uring-features] → [opcodes reference][uring-opcodes] → [timeline][uring-timeline].
- **"I want the cross-language comparison."** [Master catalog](#master-catalog) → [comparison][comparison] → individual rows of interest.
- **"I care about effects & resumption."** [effects-and-event-loops][effects] → [OCaml Eio backend][eio] → [algebraic-effects corpus][ae-index].
- **"I'm designing the Sparkles loop."** [d-landscape][d-landscape] → [comparison][comparison] → [techniques][techniques] (buffer ownership, cancellation, feature probing).

### Concepts

- **[Event-Loop Primitives][primitives]** — the layered checklist (Tier 0 → Tier 3), readiness vs completion mapped per primitive.
- **[Implementation Techniques][techniques]** — reactor/proactor, ring batching, scheduler topologies, wakers, timer wheels, buffer ownership, cancellation, feature probing.
- **[Comparison][comparison]** — the head-to-head matrix and design recommendations for Sparkles.
- **[Effects & Event Loops][effects]** — how completions resume fibers, continuations, and effect handlers.
- **[D Landscape][d-landscape]** — existing D options (vibe.d/eventcore, Photon, `during`, `core.thread.Fiber`) + gap analysis.

### io_uring reference

- **[Programming Model][uring-index]** — rings, SQE/CQE layout, syscalls, operating modes (SQPOLL/IOPOLL/`DEFER_TASKRUN`/io-wq).
- **[Features & Flags][uring-features]** — `io_uring` features grouped by semantic area.
- **[Timeline][uring-timeline]** — kernel-version chronology v5.1 → v7.1-rc6 + a feature/version/library matrix.
- **[Opcodes Reference][uring-opcodes]** — full `IORING_OP_*` / flag reference tables.

### Library deep-dives

| System                   | One-line                                                                                            |
| ------------------------ | --------------------------------------------------------------------------------------------------- |
| [Tokio][tokio]           | Rust's dominant runtime: readiness reactor over mio + work-stealing scheduler; unstable `io_uring`. |
| [Glommio][glommio]       | Rust thread-per-core, `io_uring`-only proactor (Datadog), inspired by Seastar.                      |
| [monoio][monoio]         | Rust thread-per-core completion runtime (ByteDance) with owned-buffer "rent" model.                 |
| [Boost.Asio][boost-asio] | C++ Proactor reference; emulated over epoll, native on IOCP & `io_uring`.                           |
| [Seastar][seastar]       | C++ thread-per-core share-nothing framework (ScyllaDB); future/promise.                             |
| [libuv][libuv]           | C reactor behind Node.js; epoll/kqueue/IOCP + worker pool + `io_uring` fs offload.                  |
| [Zig `std.Io`][zig-io]   | Zig's new vtable I/O capability: Threaded/Uring/Kqueue/Dispatch backends.                           |
| [.NET][dotnet]           | `SocketAsyncEngine` epoll reactor today; opt-in `io_uring` completion engine in PR.                 |
| [Java][java]             | JDK NIO + JUring/Netty `io_uring` (Panama FFI) + Loom virtual threads.                              |
| [Go][go]                 | Runtime netpoller + goroutines (epoll/kqueue/IOCP; no `io_uring`).                                  |
| [Python][python]         | asyncio readiness loop + uvloop (libuv) + Trio structured concurrency.                              |
| [OCaml Eio][eio]         | `io_uring` backend resuming OCaml 5 effect continuations from CQEs.                                 |
| [Haskell][haskell]       | GHC RTS IO manager (epoll/kqueue green threads, MIO) + `blockio-uring` `io_uring` block I/O.        |
| [Lean 4][lean]           | `Std.Async` over libuv; each I/O op resolves an `IO.Promise` (a `Task` token); no `io_uring`.       |

### Effects & synthesis

- **[Effects & Event Loops][effects]** — the synthesis tying completion-driven resumption to fibers, continuations, and algebraic effects.
- **[Algebraic Effects corpus][ae-index]** — the parallel research tree; deep-dives for [Cats Effect][cats-effect], [ZIO][zio], [Effect-TS][effect-ts], [Koka][koka], [Loom][java-loom], [OCaml effects][ocaml-effects].
- **[Comparison][comparison]** — cross-system matrix + Sparkles design recommendations.
- **[D Landscape][d-landscape]** — what D already has and what an `io_uring`-first Sparkles loop would add.

---

## Sources

Each deep-dive carries its own primary-source citations; the authoritative artifacts behind
this index's classifications are:

- **io_uring** — Linux UAPI header `include/uapi/linux/io_uring.h` (v7.1-rc6 tree), [liburing] man pages (`io_uring_enter/setup/register`), Jens Axboe's ["Efficient IO with io_uring"][axboe-pdf], and LWN's ["The rapid growth of io_uring"][lwn-growth]. See the [chronology][uring-timeline] for per-version provenance.
- **Reactor/Proactor taxonomy** — Schmidt et al., _Pattern-Oriented Software Architecture, Vol. 2_ (POSA2), as applied in [techniques][techniques].
- **Per-system sources** — repository trees, official docs, and design write-ups cited in each linked deep-dive ([Tokio][tokio], [Glommio][glommio], [monoio][monoio], [Boost.Asio][boost-asio], [Seastar][seastar], [libuv][libuv], [Zig][zig-io], [.NET][dotnet], [Java][java], [Go][go], [Python][python], [OCaml Eio][eio]).

<!-- References -->

<!-- Concept & reference docs (siblings) -->

[primitives]: ./primitives.md
[techniques]: ./techniques.md
[comparison]: ./comparison.md
[effects]: ./effects-and-event-loops.md
[d-landscape]: ./d-landscape.md

<!-- io_uring sub-section -->

[uring-index]: ./io-uring/index.md
[uring-features]: ./io-uring/features.md
[uring-timeline]: ./io-uring/timeline.md
[uring-opcodes]: ./io-uring/opcodes-reference.md

<!-- Library deep-dives (siblings) -->

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
[eio]: ./eio-backend.md
[haskell]: ./haskell.md
[lean]: ./lean.md

<!-- Algebraic-effects corpus (cross-tree) -->

[ae-index]: ../algebraic-effects/index.md
[cats-effect]: ../algebraic-effects/scala-cats-effect.md
[zio]: ../algebraic-effects/scala-zio.md
[effect-ts]: ../algebraic-effects/typescript-effect.md
[koka]: ../algebraic-effects/koka.md
[java-loom]: ../algebraic-effects/java-loom.md
[ocaml-effects]: ../algebraic-effects/ocaml-effects.md

<!-- External -->

[liburing]: https://github.com/axboe/liburing
[axboe-pdf]: http://web.archive.org/web/20260624135046/https://kernel.dk/io_uring.pdf
[lwn-growth]: https://lwn.net/Articles/810414/
[PEP 3156]: https://peps.python.org/pep-3156/
[JEP 444]: https://openjdk.org/jeps/444
[PR #124374]: https://github.com/dotnet/runtime/pull/124374
