# Haskell (GHC IO Manager, blockio-uring)

Two layers of Haskell async I/O: the threaded RTS _owns_ the event loop and parks cheap green threads on `epoll`/`kqueue` readiness (the MIO event manager) — a "runtime owns the loop" model like Go — while [`blockio-uring`][blockio-uring repo] is a separate, batching-only `io_uring` binding for block-device I/O, with no `io_uring` in the GHC RTS by default.

| Field         | Value                                                                                                                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Haskell (GHC; `blockio-uring` tested with GHC 9.2 – 9.14)                                                                                                                                                |
| License       | GHC RTS / `base`: BSD-3-Clause · `blockio-uring`: BSD-3-Clause (© Well-Typed LLP 2022–2025)                                                                                                              |
| Repository    | [well-typed/blockio-uring][blockio-uring repo] · GHC `base`/RTS [GHC][ghc repo]                                                                                                                          |
| Documentation | [`GHC.Event` (base)][ghc-event docs] · [`blockio-uring` on Hackage][blockio-uring hackage]                                                                                                               |
| Key Authors   | RTS event manager: Bryan O'Sullivan & Johan Tibell (2010); MIO multicore manager: Andreas Voellmy et al. (2013); Simon Marlow (RTS scheduler) · `blockio-uring`: Duncan Coutts & Joris Dral (Well-Typed) |
| Pattern       | RTS IO manager: **Reactor** (readiness: `epoll`/`kqueue`) parking green threads · `blockio-uring`: **Proactor** (`io_uring` completions) batching library, _no_ suspension of its own                    |

> **Scope & the two-layer story.** Haskell's standard concurrency story is the first
> layer: the **threaded RTS IO manager**, an `epoll`/`kqueue` reactor baked into the
> runtime that lets you write _blocking-looking_ socket code on millions of cheap green
> threads. That is the analogue of [Go's netpoller][go-netpoller] — the runtime owns the
> loop and the application never sees it. The second layer, [`blockio-uring`][blockio-uring repo],
> is a _separate library_, not part of the RTS: a thin `io_uring` binding for **batched
> block-device reads/writes** (the storage engine under Well-Typed's `lsm-tree`). It is a
> _batching mechanism_ with **no fiber/continuation machinery of its own** — a
> higher-level scheduler (in `blockio-uring`'s case, ordinary GHC green threads plus a
> per-capability completion thread) drives it. Crucially, **GHC's RTS has no `io_uring`
> backend by default**; that remains an in-progress proposal (see
> [§ io_uring in the RTS](#iouring-in-the-rts-still-a-proposal)). All `blockio-uring`
> paths below are relative to the [well-typed/blockio-uring][blockio-uring repo] repo at
> tag `blockio-uring-0.2.0.0`.

---

## Overview

### What it solves

A Haskell program built with the **threaded RTS** (`-threaded`) runs a few OS threads
("capabilities", `-N`) and multiplexes potentially millions of lightweight Haskell green
threads onto them. When a green thread does a socket `recv`, the runtime does not block the
underlying OS thread: it registers the fd with an in-RTS **IO manager** and _parks_ the
green thread, freeing the capability to run other work. When the kernel reports the fd
readable, the IO manager wakes the green thread and it resumes as if the `recv` had simply
returned. The programmer writes ordinary direct-style, blocking-looking code; the runtime
turns it into event-loop-class scalability behind the curtain. This is the same philosophy
documented for the [Go runtime netpoller][go-netpoller] and contrasts with the explicit
user-facing loops of [Tokio][tokio] or libuv.

That model is excellent for _sockets_ — which have a natural readiness signal — but weak
for _regular-file_ I/O, which has no readiness model: a disk read is either pending or
done. The RTS IO manager therefore handles file I/O by handing the blocking syscall to a
separate OS thread (a "safe" FFI call), which does not scale to the tens of thousands of
concurrent random reads a modern NVMe SSD can absorb. [`blockio-uring`][blockio-uring repo]
fills exactly that gap: it uses Linux **io_uring** to submit _batches_ of block reads/writes
and reap their completions, letting a single program saturate an SSD's queue depth — the
library's own benchmark reaches ~92% of `fio`'s IOPS (see [§ Performance](#performance-approach)).

### Design philosophy

- **The runtime owns the loop (layer 1).** The application never instantiates an event
  loop. `threadWaitRead`/`threadWaitWrite` and every networking primitive are built on the
  RTS IO manager; green-thread park/unpark is the only mechanism the user sees, and only
  indirectly.
- **`blockio-uring` is a _batching library_, not a runtime (layer 2).** It deliberately has
  **no scheduler, no fiber, no continuation capture**. Its `submitIO` blocks the _calling
  green thread_ (via an `MVar`) while a dedicated completion thread reaps CQEs; concurrency
  comes from the caller spawning many green threads, each submitting a batch. The RTS IO
  manager (layer 1) is what keeps those callers cheap. A higher-level scheduler — in
  practice the storage engine `lsm-tree` — drives it.
- **Per-capability isolation.** To avoid lock contention, `blockio-uring` creates **one
  independent `io_uring` per GHC capability** (`IOCtx` is a vector of `IOCapCtx`), so threads
  on different capabilities never share a submission queue.
- **No `io_uring` in the RTS.** Disk batching via `io_uring` is opt-in through a _library_;
  the runtime's own IO manager stays on `epoll`/`kqueue`. An `io_uring` RTS backend has been
  a long-term work-in-progress for years but is not in mainline GHC.

---

## Layer 1 — the threaded RTS IO manager (MIO / `GHC.Event`)

### The reactor inside the runtime

GHC's threaded RTS ships a portable, readiness-based IO manager. Its public surface lives in
the **`GHC.Event`** module of `base`, which exposes an `EventManager` and a `TimerManager`,
plus the registration API `registerFd`, `unregisterFd`, `closeFd`, and the timer API
`registerTimeout`/`updateTimeout`/`unregisterTimeout` ([`GHC.Event` docs][ghc-event docs]).
Interest is expressed with the `Event` type (`evtRead` = "data available",
`evtWrite` = "ready to write") and a `Lifetime` of `OneShot` or `MultiShot`. The platform
backend is chosen at build time:

| Platform    | RTS IO-manager backend      | Kernel mechanism |
| ----------- | --------------------------- | ---------------- |
| Linux       | `GHC.Event.EPoll`           | `epoll`          |
| BSD / macOS | `GHC.Event.KQueue`          | `kqueue`         |
| other POSIX | `GHC.Event.Poll`            | `poll`           |
| Windows     | WinIO (`GHC.Event.Windows`) | IOCP             |

This is a **Reactor**: register interest, wait for readiness, then perform the (non-blocking)
syscall — the same shape as the [Go netpoller][go-netpoller] and the JDK's selector. For the
general "suspend on I/O, resume on its event" round-trip that this implements, see
[Effects & event loops][effects-and-event-loops].

### How a green thread parks and is woken

The user-facing primitives are `threadWaitRead` / `threadWaitWrite` (and the higher-level
networking library built on them). The flow for a socket read on the threaded RTS:

1. The green thread calls a non-blocking `recv`; the fd returns `EAGAIN`.
2. It calls `threadWaitRead fd`, which `registerFd`s interest in `evtRead` with the
   `EventManager` and **blocks the green thread** (an `MVar`-style wait), yielding the
   capability to the scheduler. The OS thread is _not_ blocked.
3. The IO manager's loop sits in `epoll_wait`/`kqueue`. When `fd` becomes readable it
   delivers the registered `IOCallback`, which wakes the parked green thread by completing
   its wait.
4. The scheduler re-runs the green thread; it retries `recv`, which now succeeds.

The key property is the same as Go's: **one OS thread can carry thousands of parked green
threads**, because parking is a cheap heap operation, not an OS-thread block.

### MIO: making the IO manager multicore

The original single-threaded event manager ("Scalable I/O Event Handling for GHC",
O'Sullivan & Tibell, Haskell Symposium 2010 [paper][scalable-io-paper]) had a single
dispatcher thread, which became a scaling bottleneck on multicore. **MIO** ("Mio: A
High-Performance Multicore IO Manager for GHC", Voellmy et al., Haskell Symposium 2013
[paper][mio-paper]) replaced it with **one event manager per capability**, each with its own
`epoll`/`kqueue` instance, plus a separate timer manager. The paper reports scaling to 40+
cores and >20M requests/s, ~6.5× the throughput of the prior design. MIO is the IO manager
in every modern threaded-RTS GHC; this is why the `-N` capability count matters for network
server throughput. Notably, `blockio-uring` mirrors MIO's _per-capability_ structure for its
own `io_uring` contexts (layer 2) for the same anti-contention reason.

### File I/O is the weak spot

Regular files have no readiness model, so the RTS IO manager cannot park a green thread on a
file read. Instead, file reads/writes go through a **"safe" FFI call**, which the RTS runs on
a _separate OS thread_ so it does not block the capability. This is correct but does not
scale to high-queue-depth random I/O: each in-flight read costs an OS thread. This is exactly
the gap `blockio-uring` was built to close — and it is the Haskell analogue of the
filesystem-pinning problem that motivates `io_uring` file backends elsewhere
([Java's JUringBlocking + Loom][java]).

---

## Layer 2 — `blockio-uring`

> Source: [`well-typed/blockio-uring`][blockio-uring repo], version `0.2.0.0` (2026-04-30).
> `blockio-uring.cabal` declares `tested-with: GHC ==9.2 || ... || ==9.14`,
> `pkgconfig-depends: liburing >=2.0 && <3` (the README requires **liburing ≥ 2.1**; the
> `>=2.0` floor is a [documented workaround][blockio-uring repo] for liburing-2.1 shipping
> `2.0` in its `.pc` file), and `license: BSD-3-Clause`, `author: Duncan Coutts`. It is the
> Linux `io_uring` backend of the higher-level [`blockio`][blockio hackage] package, the
> storage layer under [`lsm-tree`][lsm-tree repo] (developed by Well-Typed for the Cardano
> Development Foundation / Intersect).

### What it is — and what it is _not_

`blockio-uring` is a **library for submitting batches of asynchronous _disk_ I/O**. The
`.cabal` synopsis is "Perform batches of asynchronous disk IO operations", and the
description is explicit about the limits: "It only supports disk operations, not socket
operations" and "only supports recent versions of Linux, because it uses the `io_uring` kernel
API." Within `blockio`, this is the _real_ Linux implementation; on Windows/macOS `blockio`
falls back to performing each operation sequentially ([blockio Hackage][blockio hackage]).

It is **not** an event loop, a fiber runtime, or a continuation system. It has no `Suspend`
effect, no captured continuations, no scheduler. The only "suspension" is an ordinary
`takeMVar` on the _calling green thread_ — which is cheap precisely because layer 1 (the RTS
IO manager + green threads) makes blocking a green thread free. The library _batches and
reaps_; the caller (or a higher-level engine like `lsm-tree`) provides the concurrency by
spawning many submitting green threads.

### Core abstractions and types

The public API is small (`src/System/IO/BlockIO.hs`, module export list lines 4–20):
`IOCtx`, `IOCtxParams`/`defaultIOCtxParams`, `withIOCtx`/`initIOCtx`/`closeIOCtx`,
`submitIO`, the operation type `IOOp` (constructors `IOOpRead`, `IOOpWrite`), and the result
type `IOResult` (patterns `IOResult`, `IOError`).

**`IOCtx` — per-capability fan-out.** The headline structural decision:

```haskell
-- src/System/IO/BlockIO.hs
-- | IO context: a handle used by threads submitting IO batches.
--
-- Internally, each GHC capability in the program creates its own independent IO
-- context. This means that each capability can process batches of I/O
-- operations independently. As such, running with more capabilities can
-- increase throughput.
newtype IOCtx = IOCtx (V.Vector IOCapCtx) -- one per RTS capability.
```

`initIOCtx` calls `getNumCapabilities` and builds one `IOCapCtx` per capability
(`V.generateM ncaps (initIOCapCtx ...)`). It refuses to run on the non-threaded RTS:
`unless hostIsThreaded $ throwIO rtsNotThreaded` ("make sure you are passing the -threaded
flag"). The per-capability `IOCapCtx` bundles the contention-control and communication state:

```haskell
-- src/System/IO/BlockIO.hs
data IOCapCtx = IOCapCtx {
    ioctxBatchSizeLimit' :: !Int,            -- max ops processed as one sub-batch
    ioctxQSemN           :: !QSemN,          -- concurrency limit (reserve right to submit)
    ioctxURing           :: !(MVar (Maybe URing.URing)),  -- writer lock on the SQ
    ioctxChanIOBatch     :: !(Chan IOBatch), -- writers -> completion thread
    ioctxChanIOBatchIx   :: !(Chan IOBatchIx),-- completion thread -> writers (free batch ix)
    ioctxCloseSync       :: !(MVar ())       -- shutdown rendezvous
  }
```

Each `IOCapCtx` owns **one `URing`** and starts **one completion thread**, pinned to its
capability with `forkOn capno` and labelled
`"System.IO.BlockIO.completionThread (for cap N)"`. So with `-N4` there are 4 independent
rings and 4 completion threads — no cross-capability sharing of a submission queue.

**`IOOp` — the operation, with a pinned-buffer contract.**

```haskell
-- src/System/IO/BlockIO.hs
-- | The 'MutableByteArray' buffers within __must__ be pinned. Addresses into
-- these buffers are passed to @io_uring@, and the buffers must therefore not be
-- moved around. 'submitIO' will check that buffers are pinned ...
data IOOp s = IOOpRead  !Fd !FileOffset !(MutableByteArray s) !Int !ByteCount
            | IOOpWrite !Fd !FileOffset !(MutableByteArray s) !Int !ByteCount
```

Because GHC's GC can move heap objects, buffers handed to the kernel **must be pinned**;
`submitIO` enforces this with `guardPinned` (throwing `InvalidArgument` "MutableByteArray is
unpinned" otherwise). The op records the fd, file offset, buffer + offset, and byte count.

**`IOResult` — errors in-band, not as exceptions.** Defined in
`src/System/IO/BlockIO/URing.hs` as a `newtype IOResult = IOResult_ Int` with two
bidirectional pattern synonyms and a `{-# COMPLETE IOResult, IOError #-}` pragma:

```haskell
-- src/System/IO/BlockIO/URing.hs
pattern IOResult :: ByteCount -> IOResult     -- non-negative: bytes transferred
pattern IOError  :: Errno     -> IOResult     -- negative: -errno from the CQE
viewIOResult (IOResult_ c) | c >= 0    = Just (fromIntegral c) | otherwise = Nothing
viewIOError  (IOResult_ e) | e <  0    = Just (Errno (fromIntegral e)) | otherwise = Nothing
```

This mirrors the `io_uring` CQE convention exactly: `cqe.res` is bytes-transferred when ≥ 0
and `-errno` when < 0. `submitIO`'s docstring stresses that "Any I/O errors are reported in
the result list, not as IO exceptions" — each op's outcome is one `IOResult` in the returned
vector, positionally matched to the input batch.

**`IOOpId` — the SQE↔CQE tag.** A `newtype IOOpId = IOOpId Word64`, the user-data carried
through `io_uring`. `blockio-uring` packs _two_ indices into it
(`packIOOpId :: IOBatchIx -> IOOpIx -> IOOpId`): the high 32 bits are the batch index, the
low 32 bits the operation's index within its batch. On completion `unpackIOOpId` recovers the
pair, which is how the completion thread routes a CQE back to the right slot. This is the
direct analogue of the `io_job` user-data tag in [Eio's io_uring backend][eio-backend] —
except here the payload is two integers indexing tracking arrays, not a captured continuation.

### The URing binding — submit / await / completion polling

`src/System/IO/BlockIO/URing.hs` is the thin liburing wrapper. It exposes exactly three
submission primitives and one completion primitive, and the FFI layer
(`src/System/IO/BlockIO/URingFFI.hsc`) binds only the handful of `liburing` symbols they
need.

**Setup.** `setupURing` calls `io_uring_queue_init_params` with just one flag —
`IORING_SETUP_CQSIZE` — to size the completion ring; it sets no SQPOLL, no
`DEFER_TASKRUN`, no `SINGLE_ISSUER`:

```haskell
-- src/System/IO/BlockIO/URing.hs (setupURing, abridged)
flags  = FFI.iORING_SETUP_CQSIZE
params = FFI.URingParams { sq_entries = 0, cq_entries = fromIntegral sizeCQRing,
                           flags = flags, features = 0 }
```

(`URingFFI.hsc` zeroes the rest of `struct io_uring_params` with `fillBytes` before poking
the four fields it models — `sq_entries`, `cq_entries`, `flags`, `features`.)

**Submission.** Each `prepare*` grabs an SQE with `io_uring_get_sqe` (throwing "URing I/O
queue full" if it returns NULL), fills it, and attaches the `IOOpId` as user-data via
`io_uring_sqe_set_data`:

```haskell
-- src/System/IO/BlockIO/URing.hs
prepareRead URing {uringptr} fd off buf len (IOOpId ioopid) = do
    sqeptr <- throwErrResIfNull "prepareRead" fullErrorType "URing I/O queue full" $
                FFI.io_uring_get_sqe uringptr
    FFI.io_uring_prep_read sqeptr fd buf (fromIntegral len) (fromIntegral off)
    FFI.io_uring_sqe_set_data sqeptr (fromIntegral ioopid)
```

`submitIO :: URing -> IO ()` then flushes the accumulated SQEs with **one**
`io_uring_submit` (one syscall per batch), retrying on `EINTR`.

**Completion polling.** `awaitIO` is the heart of the reaping path, and its FFI choice is
what makes it cooperate with the RTS IO manager:

```haskell
-- src/System/IO/BlockIO/URing.hs (awaitIO, abridged)
peekres <- FFI.io_uring_peek_cqe uringptr cqeptrptr     -- unsafe FFI: non-blocking
when (peekres /= 0) $
  if Errno (-peekres) == eAGAIN
    then throwErrnoResIfNegRetry_ "awaitIO (blocking)" $
           FFI.io_uring_wait_cqe uringptr cqeptrptr      -- safe FFI: may block this OS thread
    else throwIO ...
cqeptr <- peek cqeptrptr
FFI.URingCQE { cqe_data, cqe_res } <- peek cqeptr
FFI.io_uring_cqe_seen uringptr cqeptr
return $! IOCompletion (IOOpId (fromIntegral cqe_data)) (IOResult_ (fromIntegral cqe_res))
```

The two-step design is deliberate (and commented in the source):

- `io_uring_peek_cqe` is imported as an **`unsafe`** FFI call — cheap, non-blocking,
  used first to drain already-available completions without paying the safe-call cost.
- `io_uring_wait_cqe` is imported as a **`safe`** FFI call — when nothing is ready
  (`EAGAIN`), the completion thread blocks here. A _safe_ call lets the RTS move that OS
  thread out of the capability so other green threads keep running while this completion
  thread sleeps in the kernel.

`awaitIO`'s comment also explains a subtle perf hack: it uses
`unsafeForeignPtrToPtr`/`touchForeignPtr` instead of `withForeignPtr` so GHC's CPR analysis
returns the `IOCompletion` in registers rather than the heap. The FFI module
(`URingFFI.hsc`) imports `io_uring_wait_cqe` as `capi safe` and `io_uring_peek_cqe` /
`io_uring_cqe_seen` / `io_uring_get_sqe` / the `prep_*` helpers as `capi unsafe`, matching
that fast/slow split.

### Which io_uring ops it uses

`blockio-uring` uses a **deliberately minimal** opcode set — block reads, block writes, and a
shutdown no-op. There are exactly three `prepare*` functions and three corresponding FFI
imports:

| `URing` primitive | liburing helper (`URingFFI.hsc`) | `io_uring` opcode | Used for                              |
| ----------------- | -------------------------------- | ----------------- | ------------------------------------- |
| `prepareRead`     | `io_uring_prep_read`             | `IORING_OP_READ`  | a block read (`IOOpRead`)             |
| `prepareWrite`    | `io_uring_prep_write`            | `IORING_OP_WRITE` | a block write (`IOOpWrite`)           |
| `prepareNop`      | `io_uring_prep_nop`              | `IORING_OP_NOP`   | shutdown sentinel (`IOOpId maxBound`) |

That is the entire op surface. There is **no** `READV`/`WRITEV`, no `*_FIXED` registered-buffer
variant, no `OPENAT`/`STATX`/`ACCEPT`/`CONNECT`/`SEND`/`RECV`, and no `ASYNC_CANCEL` — unlike
the broad opcode tables of [Eio][eio-backend] or [JUring][java]. The library buys its
performance from _batching plain reads/writes_, not from the exotic opcodes. For the full
opcode catalogue and version gating, see the [io_uring opcode reference][io-uring-opcodes].

### Version gating and fallback

`blockio-uring`'s version gating is far simpler than a full proactor runtime's, because its
op set is so small that everything it uses (`READ`/`WRITE`/`NOP`, `IORING_SETUP_CQSIZE`) has
been available since the earliest `io_uring` (Linux ≥ 5.1; the README states **liburing ≥ 2.1**
and recent Linux). There are only two conditional paths:

1. **`io_uring_set_iowait` (liburing ≥ 2.10, kernel ≥ 6.15).** New in `0.2.0.0`, the
   `ioctxIOWaitMetrics` flag toggles IOWAIT accounting. The FFI binding is guarded with a
   `CPP` `#ifdef IORING_FEAT_NO_IOWAIT`; when the symbol is absent the stub returns
   `EOPNOTSUPP`, and `setIOWait` swallows that via `callIfSupported_` — so it is a _no-op on
   older liburing_, not a build error.
2. **`io_uring_sqe_set_data` vs `_set_data64`.** `URingFFI.hsc` picks the 64-bit
   `io_uring_sqe_set_data64` when `#ifdef LIBURING_HAVE_DATA64`, else pokes
   `struct io_uring_sqe.user_data` directly.

There is **no in-library fallback to `epoll`/threadpool** the way [Eio falls back to a posix
reactor][eio-backend]: if `io_uring` (or the threaded RTS) is unavailable, `initIOCtx` simply
throws. The _fallback lives one layer up_, in the [`blockio`][blockio hackage] package, whose
non-Linux backend performs each op sequentially.

---

## How it works — submission/completion flow

Putting layer-2 together, a `submitIO ctx ops` call flows as follows. The most important
detail is that **all of `submitIO` runs in a fresh bound thread** —
`runInBoundThread` — a `0.2.0.0` bug fix: submitting from an unbound green thread that the RTS
might reschedule across capabilities could yield `EFAULT` ([CHANGELOG][blockio-uring repo]
issue #58):

1. **Pick the capability's ring.** `submitIO` finds the current capability with
   `myThreadId`/`threadCapability` and selects `capctxs V.! (capno `mod` length)`. Using the
   _same_ capability's ring is "more performant" but not required for correctness (source
   comment).

2. **Reserve concurrency.** `prepAndSubmitIOBatch` acquires `iobatchOpCount` tokens from the
   per-cap `QSemN` (`waitQSemN`), blocking the calling green thread if the
   `ioctxConcurrencyLimit` would be exceeded — this is the back-pressure mechanism. It then
   pulls a free `IOBatchIx` from `ioctxChanIOBatchIx`. Async-exception safety is handled with
   `mask_` + `onException undoAcquisition`.

3. **Split oversized batches.** A batch larger than `ioctxBatchSizeLimit` (default 64) is
   split into sub-batches of at most that size (`V.take`/`V.drop` loop); each becomes one ring
   submission. (`submitIO` itself imposes _no_ limit on the caller's batch size.)

4. **Prepare + submit SQEs.** Holding the per-cap `ioctxURing` `MVar` (the writer lock),
   `V.iforM_` over the batch calls `guardPinned` then `prepareRead`/`prepareWrite` for each op,
   tagging each SQE with `packIOOpId batchIx opIx`. One `URing.submitIO` flushes the whole
   sub-batch to the kernel in a single `io_uring_submit` syscall.

5. **Hand off to the completion thread.** Write an `IOBatch` record (carrying the batch ix,
   op count, the completion `MVar`, and `iobatchKeepAlives` = the original `IOOp` vector kept
   live so the GC won't collect the buffers the kernel is writing into) onto `ioctxChanIOBatch`.

6. **Block the caller.** The submitting green thread does `takeMVar iobatchCompletion`,
   parking until its whole batch is done. (Layer 1 makes this cheap.)

7. **Reap (the completion thread).** The per-cap `completionThread` loops on
   `URing.awaitIO`, decoding one `IOCompletion (IOOpId, IOResult)` at a time. It maintains
   four arrays indexed by `IOBatchIx` — `counts`, `results`, `completions`, `keepAlives`. For
   each completion it `unpackIOOpId`s to `(batchIx, opIx)`, writes the `IOResult` into the
   batch's result array, decrements the remaining `count`, and **when the count hits zero**
   freezes the result vector, `putMVar`s it into the batch's completion var (waking the
   submitter at step 6), releases the `IOBatchIx`, and `signalQSemN`s the reserved tokens
   back. A count of `-1` for an arriving completion means "new batch": it reads pending
   `IOBatch` records off `ioctxChanIOBatch` until it finds the needed index.

8. **Shutdown.** `closeIOCapCtx` submits a `prepareNop` tagged `IOOpId maxBound`; the
   completion thread treats `maxBound` as the stop sentinel and exits.

So the "scheduler" here is _just GHC's green threads + one completion thread per ring_. There
are no continuations: the suspension at step 6 is an `MVar` wait, woken by a `putMVar` at step 7. Contrast [Eio][eio-backend], where the CQE _resumes a captured one-shot continuation_; in
`blockio-uring` the CQE just fills in an array slot and eventually completes an `MVar`.

---

## io_uring in the RTS (still a proposal)

There is **no `io_uring` backend in the GHC RTS IO manager** as of GHC 9.14. The runtime's
networking still uses `epoll`/`kqueue` (MIO). Adding an `io_uring` RTS backend is a long-term
effort led by Duncan Coutts at Well-Typed: as the [Well-Typed GHC activities report
(Mar–May 2024)][well-typed-2024] puts it, "Duncan is gradually working on a long-term project
to introduce a new RTS I/O manager based on the `io_uring` Linux kernel system call
interface," and the recent work has been _preparatory refactoring_ of the RTS IO-manager code
to make multiple managers selectable at startup — not the `io_uring` integration itself. The
tracking issue (GHC #18390) and the draft implementation remain unmerged. So today, the only
production `io_uring` in Haskell is _library-level_ (`blockio-uring`), and it is for **block
I/O only** — there is no `io_uring`-backed socket path in standard GHC.

For the broader question of where suspension/resumption meets the kernel across runtimes —
including how Haskell's green-thread parking compares to algebraic-effect continuations and
`Future`/poll models — see [Effects & event loops][effects-and-event-loops] and the
effect-library neighbours [`haskell-eff`][haskell-eff] and
[`haskell-effectful`][haskell-effectful], which build _typed effect_ layers atop exactly the
`IO` monad that the RTS IO manager and `blockio-uring` operate in. Algebraic-effect handlers
like [Koka's][koka] are an alternative way to express the same "suspend here, resume on
completion" structure that Haskell achieves with green threads + `MVar`s.

---

## Performance approach

- **Batching amortises syscalls (layer 2).** Each `blockio-uring` sub-batch is one
  `io_uring_submit` for up to `ioctxBatchSizeLimit` (default 64) ops; reaping drains CQEs with
  cheap non-blocking `io_uring_peek_cqe` and only falls back to the blocking `io_uring_wait_cqe`
  when idle. The README reports the high-level Haskell API reaching ~**215k IOPS vs `fio`'s
  ~234k** on a 4 KiB random-read workload — about **92%** of the `fio` baseline (and matching
  `fio` on some machines).
- **Concurrency over deep queues.** The benchmark (`benchmark/Bench.hs`) spawns
  `4 × ncaps` green-thread tasks (`Async.asyncOn`), each repeatedly `submitIO`-ing 32-op
  batches, keeping many batches in flight. The README notes the _high-level_ benchmark beats
  the _low-level_ one precisely because lightweight Haskell threads keep more I/O in flight
  even on a single OS thread.
- **Per-capability rings remove contention (layer 2).** One ring + one completion thread per
  capability means submitting threads on different capabilities never contend on a shared SQ
  `MVar` — the same anti-contention idea MIO applied to the RTS IO manager (layer 1).
- **Near-zero steady-state allocation.** The benchmark reports ~**95 bytes allocated per I/O
  op**; reusable pinned `MutableByteArray` buffers and reused `IOOp` vectors
  (`mkGenerateIOOpsBatch`) keep the hot path allocation-light, and `awaitIO`'s
  register-return trick avoids heap-allocating each completion.
- **Green-thread parking is cheap (layer 1).** Both the socket reactor and `blockio-uring`'s
  `takeMVar`-based waiting rely on the RTS making a parked green thread far cheaper than a
  blocked OS thread — the foundation of the whole "blocking-looking, actually-async" model.
- **`unsafe` vs `safe` FFI split.** Non-blocking hot calls (`get_sqe`, `submit`, `peek_cqe`,
  `cqe_seen`) are `unsafe` imports (no capability hand-off); the one potentially-blocking call
  (`wait_cqe`) is `safe`, so a sleeping completion thread frees its capability.

---

## Strengths

- **Direct-style scalability for free (layer 1).** Ordinary blocking-looking socket code
  scales to millions of green threads with no callbacks, `async`/`await`, or colored
  functions — the runtime owns the loop. MIO makes that multicore.
- **SSD-saturating block I/O (layer 2).** `blockio-uring` reaches ~92% of `fio` IOPS for
  random 4 KiB reads via batching + concurrency, closing the file-I/O gap the RTS IO manager
  leaves open.
- **Clean, minimal, auditable binding.** `blockio-uring` uses only three `io_uring` opcodes
  (`READ`/`WRITE`/`NOP`) and a tiny FFI surface; errors are in-band `IOResult`s, and the
  whole library is a few hundred lines.
- **Per-capability isolation** avoids cross-thread SQ contention in both layers.
- **Composes, doesn't replace.** `blockio-uring` is a library that _rides on_ the existing
  green-thread runtime rather than introducing a new concurrency model; `blockio` adds the
  cross-platform fallback above it.
- **Careful async-exception & lifetime handling.** `mask_`/`onException`, semaphore-undo, and
  the `keepAlives` GC-pinning discipline make submit-time interruption safe.

## Weaknesses

- **No `io_uring` in the RTS.** Socket I/O is still `epoll`/`kqueue`; the `io_uring` RTS manager
  is an unmerged, multi-year work-in-progress. There is no `io_uring`-backed _network_ path in
  standard GHC.
- **Block I/O only.** `blockio-uring` does _not_ do sockets — "It only supports disk
  operations, not socket operations." It is not a general async runtime.
- **Linux-only, no in-library fallback.** `initIOCtx` throws on non-Linux or non-threaded RTS;
  the cross-platform story requires the higher-level `blockio` wrapper, whose non-Linux path is
  plain sequential I/O.
- **Manual pinning & unsafe FFI.** Buffers must be pinned by the caller (checked, but a
  runtime error), and the binding relies on `unsafe` FFI calls and `unsafeForeignPtrToPtr` —
  misuse risks corruption rather than a typed error.
- **Narrow opcode surface.** No vectored, fixed-buffer, or cancel opcodes; advanced `io_uring`
  features ([fixed buffers, multishot, SQPOLL][io-uring-features]) are intentionally absent.
- **One completion thread per ring** is a potential reaping bottleneck at extreme queue
  depths, and submission must run in a bound thread (the `EFAULT` workaround) — a slight cost.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                          | Trade-off                                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| RTS owns the loop; green threads park on `epoll`/`kqueue`  | Direct-style blocking code scales like an event loop; no colored functions         | File I/O has no readiness model → handled by a blocking safe-FFI OS thread         |
| MIO: one event manager per capability                      | Removes the single-dispatcher bottleneck; scales to 40+ cores                      | More `epoll`/`kqueue` instances and per-cap state to coordinate                    |
| `blockio-uring` is a batching _library_, not a runtime     | Rides on existing green threads; no new scheduler/continuation machinery to build  | Caller must supply concurrency (spawn many submitting threads) to fill the ring    |
| One `io_uring` + one completion thread **per capability**  | No cross-capability SQ contention; throughput scales with `-N`                     | `IOCtx` is a vector; more rings/threads; each ring reaped by a single thread       |
| Block ops only (`READ`/`WRITE`/`NOP`), errors in-band      | Tiny, auditable surface; matches the SSD-batching use case                         | No sockets, no vectored/fixed/cancel opcodes; not a general async runtime          |
| `submitIO` blocks the caller via `MVar`, woken by reaper   | Cheapest possible "suspension" given cheap green threads — no continuations needed | Per-batch `takeMVar` + handoff overhead vs a CQE directly resuming a fiber         |
| `peek_cqe` (`unsafe`) first, `wait_cqe` (`safe`) when idle | Non-blocking drain is cheap; blocking call frees the OS thread for other work      | Two FFI import flavours; subtle `EAGAIN`-then-block control flow                   |
| Run all of `submitIO` in a fresh bound thread              | Avoids `EFAULT` from green-thread rescheduling across capabilities (#58)           | Bound-thread cost on every submit; acknowledged as overly conservative (#61)       |
| `QSemN` concurrency limit + `keepAlives` GC pinning        | Back-pressure on in-flight ops; buffers stay live while the kernel uses them       | Tuning `ioctxConcurrencyLimit`/`BatchSizeLimit` is workload/hardware-specific      |
| `io_uring` stays out of the RTS (library, not runtime)     | Ship working block-I/O now without an RTS-wide redesign                            | No `io_uring` network path; the RTS `io_uring` manager is a long, unmerged project |

---

## Sources

- [well-typed/blockio-uring][blockio-uring repo] — source of all `System.IO.BlockIO*` paths quoted above (tag `blockio-uring-0.2.0.0`)
- [`blockio-uring` on Hackage][blockio-uring hackage] — package metadata, synopsis ("Perform batches of asynchronous disk IO operations")
- [`blockio` on Hackage][blockio hackage] — higher-level package; Linux backend = `blockio-uring`, non-Linux = sequential fallback
- [IntersectMBO/lsm-tree][lsm-tree repo] — the storage engine that drives `blockio-uring` (Well-Typed, for Cardano Development Foundation / Intersect)
- [`GHC.Event` documentation][ghc-event docs] — `EventManager`, `registerFd`, `evtRead`/`evtWrite`, `Lifetime`, timer API
- [Scalable I/O Event Handling for GHC (Haskell '10)][scalable-io-paper] — the original single-dispatcher event manager
- [Mio: A High-Performance Multicore IO Manager for GHC (Haskell '13)][mio-paper] — the per-capability multicore IO manager
- [Well-Typed GHC activities report, Mar–May 2024][well-typed-2024] — status of the `io_uring` RTS IO manager (preparatory refactoring; unmerged)
- [Companion: Go runtime netpoller][go-netpoller] — same "runtime owns the loop + cheap green threads" philosophy
- [Companion: io_uring overview][io-uring-index] · [opcodes reference][io-uring-opcodes] · [features][io-uring-features]
- [Companion: Effects & event loops][effects-and-event-loops]
- [Companion: Eio's io_uring backend][eio-backend] · [Java io_uring + Loom][java]
- [Neighbours: `haskell-eff`][haskell-eff] · [`haskell-effectful`][haskell-effectful] · [Koka effects][koka]

<!-- References -->

[blockio-uring repo]: https://github.com/well-typed/blockio-uring
[blockio-uring hackage]: https://hackage.haskell.org/package/blockio-uring
[blockio hackage]: https://hackage.haskell.org/package/blockio
[lsm-tree repo]: https://github.com/IntersectMBO/lsm-tree
[ghc repo]: https://github.com/ghc/ghc
[ghc-event docs]: https://hackage.haskell.org/package/base-4.19.0.0/docs/GHC-Event.html
[scalable-io-paper]: https://research.google.com/pubs/archive/36841.pdf
[mio-paper]: https://www.semanticscholar.org/paper/Mio:-a-high-performance-multicore-io-manager-for-Voellmy-Wang/0b92c2e3b28bb380bfe06202fe003d01c1b635f5
[well-typed-2024]: https://well-typed.com/blog/2024/06/ghc-activities-report-march-may-2024/
[go-netpoller]: ./go-netpoller.md
[tokio]: ./tokio.md
[eio-backend]: ./eio-backend.md
[java]: ./java.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[io-uring-index]: ./io-uring/index.md
[io-uring-opcodes]: ./io-uring/opcodes-reference.md
[io-uring-features]: ./io-uring/features.md
[haskell-eff]: ../algebraic-effects/haskell-eff.md
[haskell-effectful]: ../algebraic-effects/haskell-effectful.md
[koka]: ../algebraic-effects/koka.md
