# Go Runtime Netpoller

Go's I/O concurrency has no user-facing event loop: the runtime owns the loop. Blocking-looking socket calls on cheap goroutines are transparently multiplexed by an integrated, readiness-based **netpoller** (`epoll` on Linux, `kqueue` on BSD/macOS, IOCP on Windows) that parks and unparks goroutines as the OS signals readiness.

| Field         | Value                                                                                                      |
| ------------- | ---------------------------------------------------------------------------------------------------------- |
| Language      | Go (analysis tracks `gc` toolchain `tip`, June 2026; design stable since Go 1.x)                           |
| License       | BSD-3-Clause                                                                                               |
| Repository    | [golang/go]                                                                                                |
| Documentation | [runtime/netpoll.go source] / [Go runtime package docs]                                                    |
| Key Authors   | Dmitry Vyukov (netpoller design), the Go runtime team                                                      |
| Pattern       | **Reactor (readiness)**: integrated network poller + G-M-P scheduler; goroutine park/unpark, not callbacks |
| Encoding      | Synchronous-looking blocking calls on M:N green threads; runtime owns the loop, app never sees it          |

---

## Overview

### What it solves

Most async runtimes surveyed here expose an _explicit_ event loop. [Tokio][tokio] gives you `Runtime::block_on`; [libuv][libuv] gives you `uv_run`; [Boost.Asio][boost-asio] gives you `io_context::run`; Node, Python's `asyncio`, and .NET all hand the application some object on which the loop spins. Code written against them must be re-expressed in terms of futures, promises, callbacks, or `async`/`await`, because a function that "blocks" would stall the single OS thread driving the loop.

Go takes the opposite stance: **there is no user-facing event loop at all.** You write code that _looks_ blocking —

```go
n, err := conn.Read(buf) // looks like it blocks the thread; it blocks only the goroutine
```

— and the runtime makes it cheap. The goroutine appears to block, but under the hood the runtime parks that goroutine off its OS thread, runs other goroutines on that thread, and resumes the parked goroutine when the kernel reports the socket is readable. The programmer never registers a callback, never threads a future through a combinator, and never names the poller. This is the "goroutine-per-connection + the runtime owns the loop" model: concurrency is expressed by spawning goroutines (`go f()`), and I/O multiplexing is an invisible runtime service.

This is conceptually the same _direct-style_ win that effect-based runtimes like [OCaml's Eio][ocaml-eio] and [Java's Project Loom][java-loom] pursue — write straight-line code, let the runtime suspend and resume the continuation — but Go reached it a decade earlier by baking green threads (goroutines) and a readiness poller directly into the language runtime, rather than via algebraic effects or delimited continuations on the JVM. See [effects-and-event-loops.md][effects-and-event-loops] for that cross-cutting comparison.

### Design philosophy

1. **The runtime owns the loop.** The netpoller is not a library you instantiate; it is a singleton initialized lazily on first pollable FD (`netpollGenericInit` in `src/runtime/netpoll.go`) and driven from the scheduler. Application code cannot see it, configure it, or run it.

2. **Synchronous code, asynchronous execution.** The unit of concurrency is the goroutine — a stackful, growable, ~few-KB green thread. Blocking a goroutine on I/O is cheap because it costs a park/unpark, not an OS thread. This is what makes "spawn a goroutine per connection" idiomatic in Go where it would be ruinous with OS threads.

3. **Readiness, not completion.** Go uses `epoll`/`kqueue` to learn _when_ a descriptor is ready, then performs the `read`/`write` syscall itself in user space. It does **not** use the kernel-driven completion model of `io_uring` (see [io-uring/index.md][io-uring]). This is a deliberate, still-current choice (Go issue [#31908][go-31908] remains open and _Unplanned_).

4. **Integrated with scheduling and GC.** The poller is polled at multiple, carefully chosen points: opportunistically in `findRunnable`, blockingly when a P has nothing else to do, periodically by the `sysmon` watchdog, and once at every `startTheWorld` (GC safepoint). It is never a separate thread spinning in `epoll_wait`.

---

## Core abstractions and types

There are three layers, each in a different package, bridged by `//go:linkname`:

| Layer          | Package / file                               | Central type / function                            | Role                                                            |
| -------------- | -------------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------- |
| Public net API | `net` (`src/net/fd_posix.go`)                | `netFD`                                            | A network connection's FD; `Read`/`Write` methods               |
| Poll bridge    | `internal/poll` (`fd_unix.go`)               | `poll.FD`, `pollDesc`                              | Wraps the syscall + retry loop; bridges to runtime via linkname |
| Runtime poller | `runtime` (`netpoll.go`, `netpoll_epoll.go`) | `runtime.pollDesc`, `netpoll`, `gopark`, `goready` | The actual epoll/kqueue loop and goroutine park/unpark          |

### The `runtime.pollDesc` — the per-FD poll descriptor

The heart of the design is `runtime.pollDesc` (`src/runtime/netpoll.go`). One exists per pollable file descriptor. It carries two binary-semaphore-like fields, `rg` and `wg`, that hold the goroutine waiting to **r**ead and to **w**rite respectively:

```go
// src/runtime/netpoll.go
type pollDesc struct {
    _     sys.NotInHeap
    link  *pollDesc      // in pollcache, protected by pollcache.lock
    fd    uintptr        // constant for pollDesc usage lifetime
    fdseq atomic.Uintptr // protects against stale pollDesc
    // ...
    // rg, wg are accessed atomically and hold g pointers.
    rg atomic.Uintptr // pdReady, pdWait, G waiting for read or pdNil
    wg atomic.Uintptr // pdReady, pdWait, G waiting for write or pdNil

    lock    mutex // protects the following fields
    closing bool
    rt      timer // read deadline timer
    rd      int64 // read deadline (a nanotime in the future, -1 when expired)
    wt      timer // write deadline timer
    wd      int64 // write deadline
    // ...
}
```

Each of `rg`/`wg` is a tiny state machine, documented in the source:

| State       | Constant   | Meaning                                                                               |
| ----------- | ---------- | ------------------------------------------------------------------------------------- |
| `pdNil`     | `0`        | Nothing waiting, no notification pending.                                             |
| `pdReady`   | `1`        | An I/O readiness notification is pending; a goroutine consumes it by storing `pdNil`. |
| `pdWait`    | `2`        | A goroutine is _about_ to park but hasn't committed yet.                              |
| _G pointer_ | `> pdWait` | A goroutine is parked on this slot; readiness or timeout/close will unpark it.        |

`pollDesc`s are allocated from a `pollCache` in non-GC `persistentalloc` memory and never freed back to the heap, because "we can get ready notification from epoll/kqueue after the descriptor is closed/reused" — they must be **type-stable**, with an `fdseq` counter detecting stale notifications.

### `internal/poll.FD` — the syscall + retry wrapper

`internal/poll.FD` (`src/internal/poll/fd_unix.go`) is what the `net` and `os` packages actually hold. It embeds an opaque `pollDesc{ runtimeCtx uintptr }` (`src/internal/poll/fd_poll_runtime.go`) whose `runtimeCtx` is the address of the `runtime.pollDesc`. The bridge functions are declared in `internal/poll` and _defined_ in the runtime, wired by linkname:

```go
// src/internal/poll/fd_poll_runtime.go — declarations only
func runtime_pollOpen(fd uintptr) (uintptr, int)
func runtime_pollWait(ctx uintptr, mode int) int
func runtime_pollSetDeadline(ctx uintptr, d int64, mode int)
func runtime_pollUnblock(ctx uintptr)
```

```go
// src/runtime/netpoll.go — definitions, exported back via linkname
//go:linkname poll_runtime_pollWait internal/poll.runtime_pollWait
func poll_runtime_pollWait(pd *pollDesc, mode int) int { /* ... */ }
```

### Goroutine, M, P (the scheduler context)

The poller plugs into Go's **G-M-P** scheduler (`src/runtime/proc.go`):

- **G** — a goroutine (its stack and saved state). This is what gets parked/unparked.
- **M** — an OS thread ("machine"). Runs goroutines, makes syscalls.
- **P** — a logical processor / scheduling context. There are `GOMAXPROCS` of them; an M needs a P to run Go code, and each P owns a local run queue and a per-P timer heap.

---

## How it works

### 1. A blocking-looking read, end to end

Consider `conn.Read(buf)` on a TCP connection. The path is:

`net.(*conn).Read` → `netFD.Read` (`src/net/fd_posix.go`) → `poll.FD.Read` (`src/internal/poll/fd_unix.go`).

The real logic lives in `poll.FD.Read`. The crucial detail — and the defining property of a _readiness_ runtime — is that **Go itself issues the `read(2)` syscall**, in a loop, in user space:

```go
// src/internal/poll/fd_unix.go
func (fd *FD) Read(p []byte) (int, error) {
    // ... locking, zero-length and maxRW handling elided ...
    if err := fd.pd.prepareRead(fd.isFile); err != nil {
        return 0, err
    }
    for {
        n, err := ignoringEINTRIO(syscall.Read, fd.Sysfd, p)
        if err != nil {
            n = 0
            if err == syscall.EAGAIN && fd.pd.pollable() {
                if err = fd.pd.waitRead(fd.isFile); err == nil {
                    continue
                }
            }
        }
        err = fd.eofError(n, err)
        return n, err
    }
}
```

Step by step:

1. The socket FD is **non-blocking** at the OS level (set when the socket is created in `src/net/sock_posix.go`'s `socket` → `netFD.init` → `poll.FD.Init`, which registers the FD with the runtime poller via `runtime_pollOpen` → `netpollopen`).
2. `prepareRead` resets the read-side state (`runtime_pollReset` clears `rg` to `pdNil`).
3. The code calls `syscall.Read` directly. If data is available, it returns immediately — **no parking, no poller involvement.** This is the fast path.
4. If the kernel returns `EAGAIN` (no data yet), `waitRead` → `runtime_pollWait` is called. _This_ is where the goroutine parks.
5. When `waitRead` returns `nil` (the FD became readable), the loop `continue`s and re-issues `syscall.Read`. The `read` then copies bytes from the kernel socket buffer into `p` in user space.

Note the consequence highlighted in [the comparison][comparison] and [techniques.md][techniques]: even on the "async" path, **the data copy happens via a synchronous `read` syscall in the goroutine's own context.** Go's poller saves you the _thread_, not the _syscall_ or the _copy_. A completion runtime like [monoio][monoio], [glommio][glommio], or [Eio's `eio_linux`][ocaml-eio] backend would have the kernel perform the copy asynchronously via `io_uring` and hand back the filled buffer.

### 2. Parking the goroutine: `runtime_pollWait` → `netpollblock` → `gopark`

`poll_runtime_pollWait` (`src/runtime/netpoll.go`) loops on `netpollblock`, which arms the wait and parks:

```go
// src/runtime/netpoll.go
func netpollblock(pd *pollDesc, mode int32, waitio bool) bool {
    gpp := &pd.rg
    if mode == 'w' {
        gpp = &pd.wg
    }
    // set the gpp semaphore to pdWait
    for {
        if gpp.CompareAndSwap(pdReady, pdNil) {
            return true // notification already pending — don't park
        }
        if gpp.CompareAndSwap(pdNil, pdWait) {
            break
        }
        // ... corruption check ...
    }
    // recheck error states, then park
    if waitio || netpollcheckerr(pd, mode) == pollNoError {
        gopark(netpollblockcommit, unsafe.Pointer(gpp), waitReasonIOWait, traceBlockNet, 5)
    }
    old := gpp.Swap(pdNil)
    // ...
    return old == pdReady
}
```

`gopark` (`src/runtime/proc.go`) is the universal "suspend this goroutine" primitive — the same one used by channels, mutexes, and `time.Sleep`. It records an _unlock function_ and a _wait reason_, then does `mcall(park_m)` to switch off the goroutine's stack onto the M's scheduling stack:

```go
// src/runtime/proc.go
func gopark(unlockf func(*g, unsafe.Pointer) bool, lock unsafe.Pointer, reason waitReason, traceReason traceBlockReason, traceskip int) {
    // ...
    mp.waitlock = lock
    mp.waitunlockf = unlockf
    gp.waitreason = reason
    // ...
    mcall(park_m) // never returns here; resumes only when goready'd
}
```

The unlock function here is `netpollblockcommit`, which performs the final CAS of the `rg`/`wg` slot from `pdWait` to the G pointer, _committing_ the park. If it succeeds it bumps `netpollWaiters` — a global counter the scheduler reads to decide whether it is worth blocking in `netpoll` at all:

```go
// src/runtime/netpoll.go
func netpollblockcommit(gp *g, gpp unsafe.Pointer) bool {
    r := atomic.Casuintptr((*uintptr)(gpp), pdWait, uintptr(unsafe.Pointer(gp)))
    if r {
        netpollAdjustWaiters(1)
    }
    return r
}
```

After `gopark`, the M is free to grab another runnable goroutine from its P's run queue. **The OS thread is never blocked on the read.** The `waitReasonIOWait` reason is what shows up as `[IO wait]` in goroutine stack dumps.

### 3. Polling the kernel: `netpoll(delay)` on Linux

The Linux backend lives in `src/runtime/netpoll_epoll.go`. At init (`netpollinit`) it creates the epoll instance and an eventfd for wakeups:

```go
// src/runtime/netpoll_epoll.go
func netpollinit() {
    epfd, errno = linux.EpollCreate1(linux.EPOLL_CLOEXEC)
    // ...
    efd, errno := linux.Eventfd(0, linux.EFD_CLOEXEC|linux.EFD_NONBLOCK)
    // ... register efd with EPOLLIN for netpollBreak ...
    netpollEventFd = uintptr(efd)
}
```

`epoll_create1` with `EPOLL_CLOEXEC` and `eventfd` with `EFD_CLOEXEC|EFD_NONBLOCK` are both available [since Linux 2.6.27][epoll-create1-man], which Go's minimum kernel comfortably predates. Each FD is registered **edge-triggered** for both directions plus RDHUP:

```go
// src/runtime/netpoll_epoll.go
func netpollopen(fd uintptr, pd *pollDesc) uintptr {
    var ev linux.EpollEvent
    ev.Events = linux.EPOLLIN | linux.EPOLLOUT | linux.EPOLLRDHUP | linux.EPOLLET
    tp := taggedPointerPack(unsafe.Pointer(pd), pd.fdseq.Load())
    *(*taggedPointer)(unsafe.Pointer(&ev.Data)) = tp
    return linux.EpollCtl(epfd, linux.EPOLL_CTL_ADD, int32(fd), &ev)
}
```

The `EPOLLET` flag selects **edge-triggered** mode — events fire only on a _transition_ to readable/writable, not continuously while readable. This is what makes the "issue `read` in a loop until `EAGAIN`, only then wait" structure correct: the level returns to "not ready" exactly when `read` drains the buffer to `EAGAIN`, so the next edge will fire. The `pollDesc` pointer is smuggled through `ev.Data` as a _tagged pointer_ carrying `fdseq`, so a stale notification for a closed-and-reused FD can be detected and dropped.

`netpoll(delay)` is the actual `epoll_wait` call. The `delay` argument encodes the scheduler's intent — block forever, poll without blocking, or block for a bounded time (driven by the nearest timer):

```go
// src/runtime/netpoll_epoll.go
// delay < 0: blocks indefinitely
// delay == 0: does not block, just polls
// delay > 0: block for up to that many nanoseconds
func netpoll(delay int64) (gList, int32) {
    // ... translate delay (ns) to epoll_wait timeout (ms) ...
    var events [128]linux.EpollEvent
    n, errno := linux.EpollWait(epfd, events[:], int32(len(events)), waitms)
    var toRun gList
    for i := int32(0); i < n; i++ {
        ev := events[i]
        // ... eventfd wakeup handling elided ...
        var mode int32
        if ev.Events&(linux.EPOLLIN|linux.EPOLLRDHUP|linux.EPOLLHUP|linux.EPOLLERR) != 0 {
            mode += 'r'
        }
        if ev.Events&(linux.EPOLLOUT|linux.EPOLLHUP|linux.EPOLLERR) != 0 {
            mode += 'w'
        }
        if mode != 0 {
            tp := *(*taggedPointer)(unsafe.Pointer(&ev.Data))
            pd := (*pollDesc)(tp.pointer())
            if pd.fdseq.Load() == tp.tag() { // not stale
                pd.setEventErr(ev.Events == linux.EPOLLERR, tp.tag())
                delta += netpollready(&toRun, pd, mode)
            }
        }
    }
    return toRun, delta
}
```

Crucially, `netpoll` does **not** run any goroutines or do any I/O itself. It returns a `gList` — a list of goroutines that just became runnable — for the caller (the scheduler) to inject. `EPOLLHUP`/`EPOLLERR` deliberately map to _both_ read and write so that a hung-up or errored FD wakes any goroutine waiting in either direction.

### 4. Unparking: `netpollready` → `netpollunblock` → `goready`

For each ready FD, `netpollready` flips the `rg`/`wg` slot to `pdReady` and recovers the parked goroutine pointer:

```go
// src/runtime/netpoll.go
//go:nowritebarrier
func netpollready(toRun *gList, pd *pollDesc, mode int32) int32 {
    delta := int32(0)
    var rg, wg *g
    if mode == 'r' || mode == 'r'+'w' {
        rg = netpollunblock(pd, 'r', true, &delta)
    }
    if mode == 'w' || mode == 'r'+'w' {
        wg = netpollunblock(pd, 'w', true, &delta)
    }
    if rg != nil {
        toRun.push(rg)
    }
    if wg != nil {
        toRun.push(wg)
    }
    return delta
}
```

`netpollunblock` CAS-es the slot to `pdReady` (when `ioready` is true) and returns the previously stored G pointer. The scheduler then transitions each returned goroutine from `_Gwaiting` to `_Grunnable` and either runs one directly or `injectglist`s them onto run queues. When the netpoller wakes a goroutine through the normal scheduler path it uses `netpollgoready` → `goready`:

```go
// src/runtime/netpoll.go
func netpollgoready(gp *g, traceskip int) {
    goready(gp, traceskip+1)
}
```

The unparked goroutine resumes execution _inside_ `netpollblock`, just after `gopark` — it observes `old == pdReady`, returns `true` up through `runtime_pollWait`, and the `for` loop in `poll.FD.Read` re-issues `syscall.Read`, which now succeeds.

### 5. Where the scheduler actually calls `netpoll`

The poller is integrated into the scheduler at four distinct sites, all in `src/runtime/proc.go`. This is what "the runtime owns the loop" means concretely — there is no dedicated poller thread; whichever M finds itself idle does the polling.

| Site                      | `netpoll` call   | Mode / delay                                                      | Purpose                                                                                                                                      |
| ------------------------- | ---------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `findRunnable` (early)    | `netpoll(0)`     | non-blocking, guarded by `netpollAnyWaiters()` + `pollingNet` CAS | Cheap opportunistic check before trying to steal work; only one M polls at a time to avoid kernel contention.                                |
| `findRunnable` (blocking) | `netpoll(delay)` | `delay = pollUntil - now` (or `-1`)                               | When a P has nothing to do, the M blocks in `epoll_wait` until I/O or the next timer fires; the _only_ place an idle M sleeps in the kernel. |
| `sysmon`                  | `netpoll(0)`     | non-blocking, "if not polled for >10ms"                           | The monitor thread guarantees the poller is serviced even if every P is busy in long CPU loops.                                              |
| `startTheWorldWithSema`   | `netpoll(0)`     | non-blocking                                                      | At every GC restart (a safepoint), drain ready FDs so freshly-runnable goroutines aren't starved.                                            |

The blocking call in `findRunnable` is the linchpin:

```go
// src/runtime/proc.go (findRunnable, blocking poll branch)
delay := int64(-1)
if pollUntil != 0 {
    // ... delay = pollUntil - now, clamped to >= 0 ...
}
list, delta := netpoll(delay) // block until new work is available
now = nanotime()
sched.lastpoll.Store(now)
// ... acquire an idle P, pop one g to run, injectglist the rest ...
```

The early, non-blocking poll is gated so that only one M ever does it concurrently:

```go
// src/runtime/proc.go (findRunnable, opportunistic poll branch)
if netpollinited() && netpollAnyWaiters() && sched.lastpoll.Load() != 0 && sched.pollingNet.Swap(1) == 0 {
    list, delta := netpoll(0)
    sched.pollingNet.Store(0)
    if !list.empty() {
        gp := list.pop()
        injectglist(&list)
        // ... return gp to run immediately ...
    }
}
```

And `sysmon` (`src/runtime/proc.go`) is the safety net — a special M that runs without a P and force-polls if 10 ms have elapsed, so that a program busy-looping on every P still drains network readiness:

```go
// src/runtime/proc.go (sysmon)
lastpoll := sched.lastpoll.Load()
if netpollinited() && lastpoll != 0 && lastpoll+10*1000*1000 < now {
    sched.lastpoll.CompareAndSwap(lastpoll, now)
    list, delta := netpoll(0) // non-blocking - returns list of goroutines
    if !list.empty() {
        incidlelocked(-1)
        injectglist(&list)
        incidlelocked(1)
        netpollAdjustWaiters(delta)
    }
}
```

### 6. Deadlines and the timer system

Go does not have per-operation timeouts at the syscall level; instead `SetReadDeadline`/`SetWriteDeadline`/`SetDeadline` (`src/internal/poll/fd_poll_runtime.go`) arm runtime timers that _unpark_ a parked goroutine with a timeout error. `setDeadlineImpl` computes a nanosecond deadline and calls `runtime_pollSetDeadline` → `poll_runtime_pollSetDeadline` (`src/runtime/netpoll.go`), which installs a `timer` on the `pollDesc`:

```go
// src/runtime/netpoll.go (poll_runtime_pollSetDeadline, excerpt)
rtf := netpollReadDeadline
if combo { // single timer covers both r+w deadline when equal
    rtf = netpollDeadline
}
pd.rt.modify(pd.rd, 0, rtf, pd.makeArg(), pd.rseq)
```

When the timer fires, `netpolldeadlineimpl` sets `pd.rd = -1` (marking the deadline expired via `publishInfo`), then `netpollunblock`s the goroutine. It wakes inside `netpollblock`, `netpollcheckerr` now returns `pollErrTimeout`, and `convertErr` (`src/internal/poll/fd_poll_runtime.go`) turns that into the public `os.ErrDeadlineExceeded`. The `rseq`/`wseq` sequence numbers guard against a stale timer firing after the deadline was changed or the FD reused.

The timer machinery itself (`src/runtime/time.go`) is a **per-P min-heap** of `timer` values, ordered by `when`:

```go
// src/runtime/time.go
type timers struct {
    mu              mutex
    heap            []timerWhen // ordered by heap[i].when
    len             atomic.Uint32
    minWhenHeap     atomic.Int64 // = heap[0].when, read lock-free
    minWhenModified atomic.Int64
    // ...
}
```

`timers.wakeTime()` returns the next deadline, which the scheduler feeds into `netpoll`'s `delay` so a blocking `epoll_wait` wakes exactly when the soonest timer is due. This is the same heap that backs `time.Sleep`:

```go
// src/runtime/time.go
//go:linkname timeSleep time.Sleep
func timeSleep(ns int64) {
    // ... allocate/reuse gp.timer with func goroutineReady ...
    gp.sleepWhen = when
    gopark(resetForSleep, nil, waitReasonSleep, traceBlockSleep, 1)
}
```

So `time.Sleep`, network deadlines, and `context` cancellation all converge on the same park/heap/`netpoll`-delay mechanism: timers and I/O readiness are unified through one scheduler loop.

### 7. Correctness invariants worth noting

The netpoller is small but its concurrency is subtle; a few invariants encoded in the source explain why it is robust:

- **Stale-notification safety.** Because `pollDesc`s are recycled (`pollCache.free`/`alloc`) but epoll can deliver an event for a _closed and reused_ FD, every `pollDesc` carries an `fdseq` counter that is bumped on free. The epoll event smuggles the `fdseq` in its tagged-pointer `ev.Data`; `netpoll` compares `pd.fdseq.Load() == tp.tag()` and silently drops the event on mismatch. The same `rseq`/`wseq` counters guard deadline timers (`netpolldeadlineimpl` checks `seq != currentSeq`).
- **No lost wakeups across `gopark`.** `netpollblock` re-checks error state _after_ committing to `pdWait` but _before_ parking, because `runtime_pollUnblock`/`SetDeadline` do the opposite ordering (store to `closing`/`rd`/`wd`, `publishInfo`, then load `rg`/`wg`). The `publishInfo` → atomic `pollInfo` summary is what lets `netpollcheckerr` read closing/deadline state _without_ taking `pd.lock`, which the lock-free park path requires.
- **Close unblocks in-flight I/O.** `poll.FD.Close` calls `pd.evict()` → `runtime_pollUnblock`, which sets `closing`, unparks both waiters with `pollErrClosing`, and stops the deadline timers. The FD's underlying `Sysfd` is only closed once all references drop (`csema` semaphore), so a parked goroutine can never observe a reused kernel FD.
- **The eventfd / `netpollBreak` channel.** A blocking `epoll_wait` must be interruptible when a _new_ timer is set with an earlier deadline than the current poll. `netpollBreak` writes to the registered `eventfd`; the blocked M wakes, sees the eventfd in the event list, drains the 8-byte counter, and recomputes its `delay`. `netpollWakeSig` CAS dedups concurrent break requests.

These are the kinds of invariants a hand-rolled event loop (as in [libuv][libuv] or [Boost.Asio][boost-asio]) must also maintain, but Go folds them into the runtime so application code never reasons about them.

### 8. Why epoll readiness and not io_uring

This is the most-asked question about Go's I/O, and the answer is a deliberate, _current_ (June 2026) design choice:

- **The model is readiness-based by construction.** As shown above, the contract is "tell me when the FD is ready, I'll do the syscall." `io_uring` (see [io-uring/index.md][io-uring] and [io-uring/features.md][io-uring-features]) is _completion_-based: you submit an op + buffer to a shared ring and the kernel performs it. Retrofitting completion semantics would require reworking the `pollDesc`/`netpollblock` park-on-readiness core and the ownership of every buffer crossing a syscall boundary — the same buffer-lifetime problem that forced [monoio][monoio] and `tokio-uring` into owned-buffer ("rent") APIs.
- **It still costs a syscall and a copy per read.** Go accepts this. The win it wants — and gets — is _not blocking an OS thread per connection_, which is what makes goroutine-per-connection viable. The marginal syscall/copy cost is judged acceptable for the portability and simplicity it buys.
- **Portability.** The same readiness abstraction maps cleanly onto `epoll` (Linux), `kqueue` (BSD/macOS, `netpoll_kqueue.go`), `event ports` (Solaris/illumos, `netpoll_solaris.go`), AIX `poll` (`netpoll_aix.go`), and Windows IOCP. `io_uring` is Linux-only.
- **Security and stability.** `io_uring` has had a turbulent security history; major operators (Google's Android/ChromeOS, per their 2023 disclosure) restricted it. A language runtime that must run untrusted-adjacent workloads everywhere is conservative here.
- **It is not in the runtime, and there is no committed plan to add it.** The standing proposal, [go-31908][go-31908] ("internal/poll: transparently support new linux `io_uring` interface"), remains **open**, labeled _NeedsInvestigation_ and in the _Unplanned_ milestone. Third-party libraries (e.g. `iouring-go`, `go-uring`) provide `io_uring` _outside_ the runtime, but none is integrated into `gc`'s scheduler. Note: this is the readiness-vs-completion contrast that [.NET][dotnet] (which also debated `io_uring` in dotnet/runtime #753) and the [Tokio/monoio split][monoio] illustrate elsewhere in this survey.

---

## Performance approach

- **No thread-per-connection, no callback machinery.** The dominant cost saved is OS-thread context switches and stacks. A goroutine park/unpark is a couple of atomic CAS operations plus a stack switch (`mcall`); there is no kernel transition to suspend a goroutine.
- **Fast path skips the poller entirely.** `poll.FD.Read` tries `syscall.Read` _first_. On a busy connection where data is usually already buffered, the goroutine never parks and the poller is never touched — only `EAGAIN` triggers `runtime_pollWait`.
- **Edge-triggered epoll** minimizes `epoll_wait` churn: an FD is reported once per readiness edge, and Go drains it (`read` until `EAGAIN`) before re-waiting, rather than being re-notified on every loop while data remains.
- **One poller call serves many goroutines.** A single `epoll_wait` returning up to 128 events (`var events [128]linux.EpollEvent`) can wake a batch of goroutines via one syscall, amortizing cost across connections.
- **Single-poller discipline.** `sched.pollingNet` ensures at most one M does the opportunistic non-blocking poll concurrently, avoiding thundering-herd contention on the epoll FD across many cores.
- **Per-P timer heaps** keep deadline/sleep management local and lock-light, and integrate with the poll `delay` so an idle machine sleeps in `epoll_wait` for _exactly_ the right duration rather than busy-polling.

What Go does **not** optimize, relative to completion runtimes: it does not avoid the per-I/O syscall, does not do zero-copy kernel-side transfers, and does not batch submissions. For workloads bottlenecked on syscall overhead (millions of tiny reads), an `io_uring` runtime like [glommio][glommio] or [monoio][monoio] can pull ahead — see [comparison.md][comparison].

---

## Strengths

- **Zero-ceremony concurrency.** Direct, blocking-looking code with no `async`/`await` coloring, no futures, no callbacks. The poller is completely invisible.
- **Cheap goroutines** make "one goroutine per connection" the idiomatic, scalable design rather than an anti-pattern.
- **Unified suspension model.** I/O wait, channel ops, mutex contention, `time.Sleep`, and `context` deadlines all use the same `gopark`/`goready` core, so the runtime can reason about all blocking uniformly.
- **Deadlines built in.** Every pollable FD supports `SetDeadline`, integrated with the timer heap, giving cancellable I/O without per-call timeout syscalls.
- **Highly portable** across epoll/kqueue/IOCP/event-ports/poll with one readiness abstraction.
- **Integrated with the scheduler and GC**, so the poller is serviced at the right moments (idle Ps, sysmon, safepoints) without a dedicated thread.
- **Mature and battle-tested** — this design has powered large-scale Go network servers for over a decade.

## Weaknesses

- **Readiness, not completion**: every network `read`/`write` is still a userspace syscall with a kernel→user copy; no `io_uring`-style zero-syscall batched I/O in the runtime.
- **Regular files are not pollable.** `epoll`/`kqueue` don't usefully report readiness for disk files, so `os.File` reads block a real OS thread (the runtime spins up more Ms). True async file I/O is exactly where `io_uring` shines and Go does not (see Go issue [#6222][go-6222]).
- **No user control over the loop.** You cannot tune, replace, or hook the poller; there's no `io_context` to share or run on a specific thread, unlike [Boost.Asio][boost-asio] or [libuv][libuv].
- **Syscall-per-operation overhead** can dominate for extreme small-I/O workloads where a completion runtime wins.
- **`sysmon` 10 ms floor**: in pathological all-Ps-busy situations, network readiness can be delayed up to the sysmon polling interval before any M services it.
- **Goroutine stacks still cost memory**; "millions of connections" is feasible but not free, versus event-loop-with-state-machine designs.

---

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                                           | Trade-off                                                                                         |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Runtime owns the loop (no user-facing event loop)     | Code stays direct/blocking-looking; concurrency = spawn a goroutine; nothing to wire up             | No tuning, replacement, or hook points; can't share an `io_context` across libraries              |
| Readiness model (`epoll`/`kqueue`), not completion    | Portable across all OSes; lets Go own the syscall + retry loop; avoids buffer-lifetime hazards      | Every read/write is a userspace syscall + kernel→user copy; no zero-copy batched I/O              |
| Park goroutine on `EAGAIN`, never block the OS thread | One OS thread multiplexes thousands of connections; goroutine-per-connection becomes idiomatic      | Goroutine stacks cost memory; park/unpark adds scheduling work versus a hand-rolled state machine |
| Edge-triggered epoll (`EPOLLET`) registering both r/w | One registration per FD; minimal re-notification; drain-until-`EAGAIN` is correct                   | Requires careful "loop until EAGAIN" discipline; missed-drain bugs would stall an FD              |
| Poll from the scheduler (findRunnable/sysmon/STW)     | No dedicated poller thread; whichever M is idle polls; sysmon guarantees liveness                   | Up to ~10 ms latency floor when every P is CPU-bound; only one M polls opportunistically          |
| Per-P timer heap unified with the poll `delay`        | `time.Sleep`, deadlines, `context` all share one mechanism; idle M sleeps exactly until next timer  | Cross-P timer access needs locking; deadline machinery adds per-`pollDesc` state                  |
| `io_uring` left out of the runtime ([#31908] open)    | Security history, Linux-only, completion model clashes with readiness core; readiness "good enough" | Misses `io_uring` throughput wins; async file I/O remains a gap; third-party libs fill it         |

---

## Comparison anchors

- Within this corpus, Go's "runtime owns the loop" sits between explicit-loop libraries — [libuv][libuv], [Boost.Asio][boost-asio], [Python asyncio][python-async], [Node][libuv] — and other transparent-suspension runtimes: [Java Project Loom virtual threads][java-loom] reach the same direct-style goal on the JVM, and [.NET][dotnet]'s `SocketAsyncEngine` is a closer epoll-readiness cousin (also debating `io_uring`).
- On the _readiness vs. completion_ axis, Go is firmly in the readiness camp with [Tokio][tokio] (default) and [.NET][dotnet]; the completion camp is [glommio][glommio], [monoio][monoio], [Seastar][seastar], and [Eio's `eio_linux`][ocaml-eio] backend. See [primitives.md][primitives] and [techniques.md][techniques] for the underlying mechanisms.
- For the deeper effect-system framing of "synchronous code, asynchronous execution," see [effects-and-event-loops.md][effects-and-event-loops] and [../algebraic-effects/java-loom.md][java-loom].

---

## Sources

- [golang/go] — the Go source repository (analysis tracked `tip`, June 2026)
- [runtime/netpoll.go source] — platform-independent netpoller, `pollDesc`, `netpollblock`, `netpollready`, `netpollunblock`
- [runtime/netpoll_epoll.go source] — Linux epoll backend: `netpollinit`, `netpollopen`, `netpoll`
- [runtime/proc.go source] — G-M-P scheduler: `gopark`, `goready`, `findRunnable`, `sysmon`, `startTheWorldWithSema`
- [runtime/time.go source] — per-P timer heap, `timers`, `timeSleep`, `wakeTime`
- [internal/poll/fd_poll_runtime.go source] — `internal/poll` ↔ runtime linkname bridge, deadline conversion
- [internal/poll/fd_unix.go source] — `poll.FD.Read`/`Write`, the `EAGAIN` → `waitRead` retry loop
- [Go runtime package docs] — runtime overview
- [The Go netpoller (Morsing)] — early conceptual write-up of the netpoller/scheduler integration
- [go-31908] — "internal/poll: transparently support new linux `io_uring` interface" (open, Unplanned)
- [go-6222] — "runtime: poller should be used for file system operations"
- [epoll(7) man page] — edge-triggered semantics, `EPOLLET`/`EPOLLIN`/`EPOLLOUT`
- [epoll_create1(2) / eventfd(2) man pages] — `EPOLL_CLOEXEC`, `EFD_*` since Linux 2.6.27
- [io_uring (Wikipedia)] — completion model and security background

<!-- References -->

[golang/go]: https://github.com/golang/go
[runtime/netpoll.go source]: https://github.com/golang/go/blob/master/src/runtime/netpoll.go
[runtime/netpoll_epoll.go source]: https://github.com/golang/go/blob/master/src/runtime/netpoll_epoll.go
[runtime/proc.go source]: https://github.com/golang/go/blob/master/src/runtime/proc.go
[runtime/time.go source]: https://github.com/golang/go/blob/master/src/runtime/time.go
[internal/poll/fd_poll_runtime.go source]: https://github.com/golang/go/blob/master/src/internal/poll/fd_poll_runtime.go
[internal/poll/fd_unix.go source]: https://github.com/golang/go/blob/master/src/internal/poll/fd_unix.go
[Go runtime package docs]: https://pkg.go.dev/runtime
[The Go netpoller (Morsing)]: https://morsmachine.dk/netpoller
[go-31908]: https://github.com/golang/go/issues/31908
[go-6222]: https://github.com/golang/go/issues/6222
[epoll(7) man page]: https://man7.org/linux/man-pages/man7/epoll.7.html
[epoll_create1(2) / eventfd(2) man pages]: https://man7.org/linux/man-pages/man2/eventfd.2.html
[epoll-create1-man]: https://man7.org/linux/man-pages/man2/epoll_create.2.html
[io_uring (Wikipedia)]: https://en.wikipedia.org/wiki/Io_uring

<!-- Sibling async-io docs -->

[index]: ./index.md
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[comparison]: ./comparison.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[boost-asio]: ./boost-asio.md
[seastar]: ./seastar.md
[libuv]: ./libuv.md
[dotnet]: ./dotnet.md
[python-async]: ./python-async.md
[io-uring]: ./io-uring/index.md
[io-uring-features]: ./io-uring/features.md

<!-- Effect-system corpus -->

[ocaml-eio]: ../algebraic-effects/ocaml-eio.md
[java-loom]: ../algebraic-effects/java-loom.md
