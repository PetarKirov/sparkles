# Event-Loop Primitives: Minimal to Fully-Featured

A layered checklist of the primitives an event-loop library must provide, from the
smallest loop that can drive a single timer to a fully-featured thread-per-core runtime,
with each primitive mapped onto the two dominant kernel models: **readiness** (epoll /
kqueue) and **completion** (`io_uring` / IOCP).

> **Scope.** This is a _reference_ document, not a library deep-dive. It defines a tiered
> vocabulary used throughout the rest of this survey. For _how_ a given library implements
> these primitives, follow the cross-links to its deep-dive (e.g. [Tokio][tokio],
> [Glommio][glommio], [libuv][libuv], [Zig std.Io][zig-io]). For the kernel mechanics
> behind the completion column, see [io_uring features][io-uring-features] and the
> [io_uring opcode reference][io-uring-opcodes]. For the _patterns_ that combine these
> primitives (reactor vs. proactor, futures vs. fibers, etc.), see [techniques][techniques].

---

## Why a layered model

Event-loop libraries vary enormously in surface area. A teaching library might be 500
lines and expose only "poll these fds, fire these timers". A production runtime like
[Tokio][tokio] or [libuv][libuv] exposes hundreds of types. Yet almost every library, no
matter the language, accretes the _same_ primitives in roughly the _same order_, because
each tier is a precondition for the next:

- You cannot offer non-blocking `connect` (Tier 1) until you have a poller and a timer
  source (Tier 0).
- You cannot offer structured concurrency or graceful shutdown (Tier 2) until you have
  task spawning and a `run()` driver (Tier 1).
- You cannot offer multishot accept or provided buffer rings (Tier 3) until you have a
  completion-based backend at all.

Two source artifacts make excellent "what belongs in each tier" checklists:

- **[libuv]**'s `uv_handle_type` / `uv_req_type` enums (`libuv/include/uv.h`) enumerate
  every long-lived resource and every one-shot operation a mature reactor needs.
- **[Zig][zig-io]**'s `Io.VTable` (`zig/lib/std/Io.zig`) enumerates the _minimal_
  function set an I/O implementation must supply to be substitutable — a single virtual
  table covering files, networking, processes, time, randomness, and async/await/cancel.

The tiers below cross-reference both. The key claim throughout: **a readiness backend
must add a userspace operation layer on top of the kernel's "is it ready?" answer, while
a completion backend gets the operation _result_ directly from the kernel** — and that
difference reshapes nearly every primitive.

### Readiness vs. completion in one paragraph

A **readiness** API (`epoll_wait`, `kevent`, `poll`) tells you _when a file descriptor
will not block_; your code then performs the actual `read`/`write`/`accept` syscall, which
may still return `EAGAIN` (a spurious wakeup) or partial data. A **completion** API
(`io_uring`, Windows IOCP) lets you _submit the operation itself_ and later collects a
completion carrying the byte count or error — the kernel did the `read` for you, into a
buffer you handed it. This is the **reactor** vs. **proactor** split (see
[techniques][techniques]); `io_uring` can emulate readiness via `IORING_OP_POLL_ADD`, so
hybrid designs exist.

---

## Tier 0 — The minimal viable loop

The smallest set of primitives that lets a single thread sleep until _something_
happens and react to it. Without all three, you do not have an event loop.

| Primitive              | What it is                                                                                                     | Why it's needed                                                                                     |
| ---------------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Poller / driver        | A blocking call that sleeps until any registered fd is ready (or a deadline elapses) and returns the ready set | The single point where the thread gives the CPU back to the OS; everything else hangs off it        |
| Monotonic timer source | A clock immune to wall-clock jumps, plus a sorted set of pending deadlines                                     | Timeouts, retries, heartbeats; also computes the poller's max-wait so it wakes on time              |
| Cross-thread wakeup    | A way for another thread (or a signal handler) to force the poller to return _now_                             | Without it, work submitted from outside the loop thread is invisible until the next unrelated event |

### 0.1 The poller / driver

This is the loop's heartbeat: a function that computes a timeout from the nearest timer,
blocks in the kernel, and returns the set of fds (readiness) or completions (completion)
that are ready to process.

[Tokio][tokio]'s reactor is `Driver`, backed by the `mio` crate, which on Linux wraps
`epoll`. Its core is a single `poll.poll(events, max_wait)` call:

```rust
// tokio/src/runtime/io/driver.rs
pub(crate) struct Driver {
    /// Reuse the `mio::Events` value across calls to poll.
    events: mio::Events,
    poll: mio::Poll,
    // ...
}

fn turn(&mut self, handle: &Handle, max_wait: Option<Duration>) {
    // ...
    match self.poll.poll(events, max_wait) { /* dispatch ready tokens */ }
}
```

[libuv]'s equivalent is `uv_run`, parameterized by a run mode (`libuv/include/uv.h`):

```c
typedef enum {
  UV_RUN_DEFAULT = 0,   /* run until no referenced handles remain */
  UV_RUN_ONCE,          /* poll once, block if no work is pending */
  UV_RUN_NOWAIT         /* poll once, never block (for embedding) */
} uv_run_mode;

UV_EXTERN int uv_run(uv_loop_t*, uv_run_mode mode);
UV_EXTERN int uv_backend_fd(const uv_loop_t*);   /* the epoll/kqueue fd itself */
```

The `UV_RUN_NOWAIT` / `UV_RUN_ONCE` modes and the exposed `uv_backend_fd` are how libuv
embeds inside _another_ loop (e.g. inside Node's or a GUI toolkit's). [trio][trio]'s
epoll backend documents at length (`trio/_core/_io_epoll.py`) why a readiness poller must
defend against _stale_ fds: because epoll keys on `(fd, file object)` tuples and is
level-triggered by default, a closed-then-reopened fd can deliver spurious events, so the
manager interrupts `wait_readable` rather than trusting the interest set blindly.

| Backend              | Mechanism                               | Triggering                 | Notes                                                                                  |
| -------------------- | --------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------- |
| `epoll` (Linux)      | Readiness                               | Level or edge (`EPOLLET`)  | Cannot watch regular files (see Tier 2); rejects them with `EPERM`                     |
| `kqueue` (BSD/macOS) | Readiness                               | Level or edge (`EV_CLEAR`) | Unified filter model also covers signals, timers, vnodes                               |
| `IOCP` (Windows)     | Completion                              | n/a                        | Proactor-native; readiness is the awkward case here                                    |
| `io_uring` (Linux)   | Completion (+ readiness via `POLL_ADD`) | n/a                        | One `io_uring_enter` can submit _and_ reap; see [io_uring features][io-uring-features] |

### 0.2 Monotonic timer source

Two halves: a **monotonic clock** (never goes backwards, unaffected by NTP/DST) and a
**timer heap** of pending deadlines. The nearest deadline determines the poller's
`max_wait`, so the loop wakes precisely when a timer expires even if no I/O happens.

- [libuv]: `uv_now()` (cached loop time), `uv_update_time()`, `uv_hrtime()` (raw
  monotonic ns), and the `uv_timer_t` handle with `uv_timer_start`.
- [Tokio][tokio]: `tokio::time::{Instant, Sleep, Interval, sleep, timeout}`
  (`tokio/src/time/`); a `Sleep` "does no work and completes at a specific `Instant`".
- [trio][trio]: `trio.current_time()` plus `sleep`, `sleep_until`, `sleep_forever`
  (`trio/_timeouts.py`), all expressed in terms of a single monotonic clock so that the
  `MockClock` can replace it for deterministic tests.
- [Zig][zig-io]: the VTable exposes `now(Clock) Timestamp`, `clockResolution`, and
  `sleep(Timeout)` directly (`zig/lib/std/Io.zig`), with a `Clock` enum distinguishing
  monotonic from wall-clock.

On `io_uring` the timer source can be _internal_ to the ring: `IORING_OP_TIMEOUT` and
`IORING_OP_LINK_TIMEOUT` arm deadlines as ring operations, so a single `io_uring_enter`
both waits for I/O and enforces timeouts without a separate `timerfd`. A readiness loop
instead either passes the timeout to `epoll_wait`/`kevent` or registers a `timerfd`.

### 0.3 Cross-thread wakeup

The poller is asleep in the kernel. When another thread enqueues a task, or a signal
fires, the loop must be _interrupted_. Three classic mechanisms:

| Mechanism      | Platform      | How it works                                                              |
| -------------- | ------------- | ------------------------------------------------------------------------- |
| `eventfd`      | Linux 2.6.22+ | A counter fd; `write(8 bytes)` makes it readable, the loop watches it     |
| Self-pipe      | POSIX         | A non-blocking `pipe`/`socketpair`; write one byte to wake, drain on wake |
| `io_uring` msg | Linux 5.18+   | `IORING_OP_MSG_RING` posts a CQE to another ring with no fd at all        |

[libuv] exposes this as the `uv_async_t` handle: `uv_async_init` registers a callback,
and `uv_async_send` is the _only_ libuv function safe to call from another thread
(`libuv/include/uv.h`). [Tokio][tokio]'s reactor reserves `mio::Token(0)` as
`TOKEN_WAKEUP` and uses a `mio::Waker` (an `eventfd` on Linux).

[trio][trio] uses the classic **self-pipe trick**, and its implementation
(`trio/_core/_wakeup_socketpair.py`) is instructive: it shrinks the socket buffers to the
minimum so a flood of wakeups cannot block the writer, and reuses the _same_ fd as the
signal `set_wakeup_fd` target so signal delivery and cross-thread wakeups share one path:

```python
# trio/_core/_wakeup_socketpair.py
class WakeupSocketpair:
    def __init__(self):
        self.wakeup_sock, self.write_sock = socket.socketpair()
        self.wakeup_sock.setblocking(False)
        # Set the socket's internal buffers as small as possible, so a
        # flood of wakeups can never make us block.
        self.wakeup_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1)
        self.write_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1)
```

**Tier 0 coverage by library:** every loop here has all three. The minimal expression is
[Zig][zig-io]'s `Threaded` and `Evented` implementations, which satisfy the entire
`Io.VTable` — including a Tier 0 poller — behind one interface.

---

## Tier 1 — Usable async

Tier 0 plus the primitives that make the loop _useful_ for ordinary network programs:
sockets, timeouts on operations, task spawning, and a top-level driver. This is the
minimum to write an echo server.

| Primitive               | Readiness mapping (epoll/kqueue)                                     | Completion mapping (`io_uring`)                              |
| ----------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------ |
| Non-blocking `connect`  | `connect` returns `EINPROGRESS`; wait for writable; check `SO_ERROR` | `IORING_OP_CONNECT`; completion carries the result directly  |
| Non-blocking `accept`   | wait for readable, then `accept4(SOCK_NONBLOCK)`                     | `IORING_OP_ACCEPT` (one-shot) — or multishot at Tier 3       |
| `read` / `recv`         | wait for readable, then `recv`, handle `EAGAIN` / partial            | `IORING_OP_READ` / `RECV`; completion is the byte count      |
| `write` / `send`        | wait for writable, then `send`, loop on partial writes               | `IORING_OP_WRITE` / `SEND`; kernel drains the buffer         |
| UDP `sendto`/`recvfrom` | same readiness dance with datagram boundaries                        | `IORING_OP_SEND`/`RECVMSG` with address                      |
| Unix-domain sockets     | identical to TCP at the syscall level                                | identical opcodes; `AF_UNIX` is just an address family       |
| Per-operation timeout   | `epoll_wait` max-wait + a timer entry; cancel on completion          | `IORING_OP_LINK_TIMEOUT` chained to the op                   |
| Task spawning           | push a future/coroutine onto the run queue                           | same; orthogonal to the backend                              |
| `run()` driver          | loop: compute timeout → poll → run timers → run ready tasks          | loop: submit batch → `io_uring_enter` → dispatch completions |

### 1.1 Sockets and the non-blocking handshake

In the readiness model, _every_ socket operation is a two-step dance: register interest,
get told "ready", perform the syscall, cope with `EAGAIN`. [Tokio][tokio] structures this
around `mio` registrations and the `AsyncFd` wrapper; its public surface is
`tokio::net::{TcpStream, TcpListener, UdpSocket}` plus `tokio::net::unix::*`
(`tokio/src/net/`). The `Registration` type (`tokio/src/runtime/io/registration.rs`) ties
an fd to the reactor and parks the task until the readiness event fires.

In the completion model, the operation _is_ the request. [Zig][zig-io]'s VTable shows the
completion-shaped signatures (`zig/lib/std/Io.zig`): no readiness step appears in the
interface at all —

```zig
// zig/lib/std/Io.zig — VTable (excerpt)
netConnectIp: *const fn (?*anyopaque, address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket,
netAccept:    *const fn (?*anyopaque, server: net.Socket.Handle,
    options: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket,
netListenIp:  *const fn (?*anyopaque, address: *const net.IpAddress,
    net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Socket,
```

A `netConnectIp` call _returns the connected socket or an error_ — the implementation
chooses whether that is a blocking `connect` on a thread, an epoll readiness wait, or an
`IORING_OP_CONNECT` submission. The same interface backs both the `Threaded` and `Uring`
implementations. [libuv] models the long-lived endpoints as handles (`uv_tcp_t`,
`uv_udp_t`, `uv_pipe_t`) and the in-flight operations as requests (`uv_connect_t`,
`uv_write_t`, `uv_shutdown_t`, `uv_udp_send_t`) — the handle/request split _is_ the
reactor/proactor seam (`libuv/include/uv.h`).

### 1.2 Per-operation timeouts

A timeout is "this operation, but cancelled if it takes longer than D". Readiness loops
implement it by inserting a timer that, on expiry, deregisters the fd and fails the
pending future. [Tokio][tokio]'s `tokio::time::timeout(dur, fut)` wraps any future this
way (`tokio/src/time/timeout.rs`). On `io_uring` the kernel does it: `IORING_OP_LINK_TIMEOUT`
attaches to the preceding linked SQE and cancels it on expiry, so no userspace timer is
needed (see [io_uring features][io-uring-features]).

### 1.3 Task spawning and the `run()` driver

Spawning is mostly _orthogonal_ to the I/O backend — it concerns the scheduler, not the
kernel. But the `run()` driver is where scheduling and I/O meet: it interleaves _running
ready tasks_ with _polling for new readiness/completions_. The canonical shapes:

- **libuv** (`uv_run`): a fixed phase order — timers, pending callbacks, poll for I/O,
  check handles, close callbacks — repeated until no referenced handles remain.
- **Tokio**: a multi-threaded work-stealing scheduler whose worker threads each
  periodically `turn` the I/O driver; `block_on` drives the root future.
- **trio**: a single-threaded scheduler that runs all ready tasks, then sleeps in the I/O
  manager until the next deadline or readiness event.

See [techniques][techniques] for the scheduler taxonomy (work-stealing vs.
thread-per-core vs. single-threaded) and [comparison][comparison] for which library picks
which.

---

## Tier 2 — Production-grade

The primitives that separate a toy from something you would run a service on:
files, name resolution, signals, subprocesses, pipes/TTYs, and the whole family of
_lifecycle_ concerns — cancellation, deadlines, structured concurrency, graceful
shutdown. [libuv]'s handle/request taxonomy is almost entirely a Tier 2 checklist:
`uv_fs_t`, `uv_getaddrinfo_t`, `uv_getnameinfo_t`, `uv_signal_t`, `uv_process_t`,
`uv_pipe_t`, `uv_tty_t`, `uv_fs_event_t`, `uv_fs_poll_t` (`libuv/include/uv.h`).

### 2.1 Files — the central asymmetry

This is the single most important place where readiness and completion _diverge_, and it
is worth stating precisely:

> **epoll cannot report readiness for regular files.** `epoll_ctl(EPOLL_CTL_ADD, …)` on a
> regular-file fd fails with `EPERM`. Regular files are "always ready" to `select`/`poll`,
> yet the `read` can still block on disk I/O, cache misses, or a network filesystem —
> there is no kernel notion of a regular file being "not ready". This is documented in
> [epoll(7)][epoll(7) manual page] and is a fundamental property of the readiness model.

Consequently, **readiness-based runtimes do file I/O on a blocking thread pool.**
[Tokio][tokio] is explicit (`tokio/src/fs/mod.rs`):

```rust
//! Be aware that most operating systems do not provide asynchronous file system
//! APIs. Because of that, Tokio will use ordinary blocking file operations
//! behind the scenes. This is done using the [`spawn_blocking`] threadpool ...
//! Currently, Tokio will always use [`spawn_blocking`] on all platforms, but it
//! may be changed to use asynchronous file system APIs such as io_uring in the
//! future.
```

[libuv] does the same: every `uv_fs_*` call is a `uv_work_t`-style request dispatched to
its internal thread pool (with a `uv_fs_t` request object), _unless_ the loop was
configured for `io_uring` — recent libuv can offload `read`/`write`/`fsync`/`statx`/etc. to
`io_uring`, gated by `UV_LOOP_USE_IO_URING_SQPOLL` (`libuv/include/uv.h`).

**Completion backends do not have this problem.** `io_uring`'s `IORING_OP_READ`,
`IORING_OP_WRITE`, `IORING_OP_OPENAT`, `IORING_OP_STATX`, `IORING_OP_FSYNC` work on regular
files natively, asynchronously, with no thread pool. This is one of the headline reasons to
prefer a completion backend for file-heavy workloads (databases, build systems). [Tokio]
now ships an experimental `io_uring` file path: `tokio/src/fs/read_uring.rs` reads a whole
file via chained `IORING_OP_READ` submissions, gated behind the `io-uring` feature and
`tokio_unstable`. [Glommio][glommio] and [Monoio][monoio] are `io_uring`-native and treat
file I/O as a first-class async operation from the start.

| Aspect                 | epoll / kqueue (readiness)                    | `io_uring` (completion)                      |
| ---------------------- | --------------------------------------------- | -------------------------------------------- |
| Regular-file readiness | Not supported (`EPERM`); files "always ready" | n/a — submit the op directly                 |
| Async file read/write  | Offloaded to a blocking thread pool           | `IORING_OP_READ`/`WRITE` natively async      |
| `open`/`stat`/`fsync`  | Thread pool                                   | `OPENAT`/`STATX`/`FSYNC` opcodes             |
| Ordering & overhead    | Thread hop per op; pool contention            | Batched into ring submissions, no thread hop |

See [Tokio][tokio], [libuv][libuv], and [Glommio][glommio] deep-dives for the per-library
specifics.

### 2.2 DNS resolution

`getaddrinfo` is blocking and has no async kernel API, so it is universally run on a
thread pool. [libuv]: `uv_getaddrinfo` / `uv_getnameinfo` (request types
`uv_getaddrinfo_t` / `uv_getnameinfo_t`). [Tokio][tokio]: `tokio::net::lookup_host`
(`tokio/src/net/lookup_host.rs`), which delegates to `spawn_blocking`. [Zig][zig-io]'s
VTable exposes `netLookup(HostName, *Queue(LookupResult), …)` so the implementation can
stream results. The pattern is the same on both backends: there is no `IORING_OP_GETADDRINFO`,
so DNS is a thread-pool job regardless (`io_uring`-native runtimes still offload it or use a
pure-Rust async resolver).

### 2.3 Signals

Signals are asynchronous and not fd-based, so they must be funneled into the loop. Common
techniques: `signalfd` (Linux), the self-pipe trick driven by a tiny async-signal-safe
handler, or kqueue's `EVFILT_SIGNAL`. [libuv] exposes `uv_signal_t`. [Tokio][tokio] has
`tokio::signal::unix` with a `Signal` stream and `ctrl_c()` (`tokio/src/signal/`); its
reactor reserves `mio::Token(1)` as `TOKEN_SIGNAL` for the signal self-pipe
(`tokio/src/runtime/io/driver/signal.rs`). [trio][trio] exposes `open_signal_receiver`
(`trio/_signals.py`) and reuses its `WakeupSocketpair` as the `set_wakeup_fd` target, so
signal handling and cross-thread wakeups share one fd. On `io_uring`, `signalfd` can be read
via the ring, or `IORING_OP_POLL_ADD` can watch a `signalfd`.

### 2.4 Child processes / subprocess

Spawning a child and awaiting its exit (without blocking on `waitpid`) requires reaping
`SIGCHLD` or, on Linux, watching a `pidfd`. [libuv]: `uv_process_t` + `uv_spawn`, with
stdio redirected through `uv_pipe_t` handles. [Tokio][tokio]: `tokio::process::{Command,
Child}` (`tokio/src/process/`), which on Unix integrates with the signal machinery to
await child exit. [trio][trio]: `trio.run_process` / `trio.Process`
(`trio/_subprocess.py`). [Zig][zig-io]'s VTable has `processSpawnPath`, `childWait`,
`childKill`. On `io_uring`, `IORING_OP_WAITID` (Linux 6.7+) can reap a child directly in the
ring; otherwise a `pidfd` is polled.

### 2.5 Pipes and TTYs

Pipes and PTYs are fd-based and _do_ support readiness, but they have edge cases (a TTY
needs raw-mode setup; a pipe's writable side needs `EPIPE` handling). [libuv] gives them
dedicated handles: `uv_pipe_t` (also used for IPC and passing fds) and `uv_tty_t`. [Tokio]
exposes `tokio::net::unix::pipe` for FIFO/pipe fds and notes that `tokio::fs` should _not_
be used for them. [Zig][zig-io] has a whole `Terminal` module and `fileIsTty` /
`fileSupportsAnsiEscapeCodes` VTable entries. On `io_uring` these are ordinary `READ`/`WRITE`
opcodes; on epoll they are ordinary readiness registrations.

### 2.6 The lifecycle primitives: cancellation, deadlines, structured concurrency, shutdown

These are _cross-cutting_ — they touch every I/O operation — and they are where libraries
differ most in philosophy. They are also where the I/O backend matters surprisingly much,
because _cancellation semantics differ between readiness and completion_.

| Primitive              | What it is                                               | Readiness backend                                              | Completion backend                                                                |
| ---------------------- | -------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Cancellation           | Stop an in-flight operation and unwind cleanly           | Deregister the fd, fail the waiting task; no kernel state held | Must submit `IORING_OP_ASYNC_CANCEL`; the buffer may still be in kernel use       |
| Deadlines              | A cancellation scheduled at an absolute time             | Timer entry that triggers cancellation                         | `LINK_TIMEOUT`, or a timer-driven `ASYNC_CANCEL`                                  |
| Structured concurrency | Child tasks cannot outlive the scope that spawned them   | Scheduler bookkeeping; backend-agnostic                        | Same, but must ensure in-flight SQEs complete or are cancelled before scope exits |
| Graceful shutdown      | Stop accepting new work, drain in-flight work, then exit | Stop polling for new connections; await outstanding tasks      | Drain the completion queue; reclaim registered buffers/files                      |

The completion-backend subtlety is real and important: when you cancel a readiness-based
read, _nothing is in flight in the kernel_ — you simply never call `read`. When you cancel
an `io_uring` read, **the kernel may still own your buffer**, so you cannot free it until the
cancellation completion arrives. This "buffer ownership across cancellation" problem is the
defining ergonomic challenge of completion-based APIs and shapes the designs of
[Monoio][monoio] (owned-buffer `AsyncReadRent`/`AsyncWriteRent` traits) and Rust's broader
`io_uring` work. See [io_uring features][io-uring-features].

**Structured concurrency** is the standout Tier 2 feature in modern designs. [trio][trio]
pioneered the **nursery** (`trio.open_nursery`, `trio/_core/_run.py`): an async context
manager that does not return until _all_ child tasks spawned via `nursery.start_soon` have
finished, turning task lifetimes into lexical scopes and making leaks impossible. Its
companion is the **cancel scope** (`trio.CancelScope`, with `move_on_after`,
`move_on_at`, `fail_after`, `fail_at` in `trio/_timeouts.py`) — a nestable region that can
be cancelled as a unit, which is exactly how trio implements deadlines:

```python
# trio/_timeouts.py — a deadline is a cancel scope with a deadline
def move_on_at(deadline, *, shield=False):
    # CancelScope validates that deadline isn't math.nan
    return trio.CancelScope(deadline=deadline, shield=shield)
```

[Zig][zig-io] bakes the same ideas into its VTable: `async`/`concurrent`/`await`/`cancel`
for individual futures, `Group` (`groupAsync`/`groupAwait`/`groupCancel`) for structured
groups, and a `Cancelable` error set plus `checkCancel` / `swapCancelProtection` so every
operation is a cancellation point unless explicitly shielded (`zig/lib/std/Io.zig`). The
effect-handler languages reach the same destination by a different route — see
[Eio's `Switch`][eio] and the broader [effects-and-event-loops][effects] discussion. For
the theory, [structured concurrency as a discipline][techniques] is covered in techniques.

---

## Tier 3 — High-performance / fully-featured

These primitives exist almost exclusively on **completion** backends (`io_uring`, IOCP), or
are scheduler-level placement features. They are how thread-per-core runtimes like
[Glommio][glommio], [Monoio][monoio], and [Seastar][seastar] extract maximum throughput.
Most have _no equivalent_ in a pure readiness loop — they are the payoff for adopting the
completion model.

| Primitive                 | What it is                                                              | Backend                          | Since                |
| ------------------------- | ----------------------------------------------------------------------- | -------------------------------- | -------------------- |
| Registered files          | Pre-register fds to skip per-op fd lookup/refcount (`IOSQE_FIXED_FILE`) | `io_uring` only                  | Linux 5.1            |
| Registered buffers        | Pre-pin buffers so the kernel skips `get_user_pages` each op            | `io_uring` only                  | Linux 5.1            |
| Provided buffer rings     | Hand the kernel a ring of buffers; it picks one per recv (`PBUF_RING`)  | `io_uring` only                  | Linux 5.19           |
| Multishot accept          | One `ACCEPT` SQE yields a CQE per incoming connection                   | `io_uring` only                  | Linux 5.19           |
| Multishot recv / poll     | One `RECV`/`POLL_ADD` SQE keeps firing CQEs (`IORING_CQE_F_MORE`)       | `io_uring` only                  | recv 6.0 / poll 5.13 |
| Zero-copy send            | `IORING_OP_SEND_ZC` avoids the kernel copy; 2 CQEs (result + notif)     | `io_uring` only                  | Linux 6.0            |
| Zero-copy receive         | `io_uring` zero-copy Rx maps NIC buffers into userspace                 | `io_uring` only                  | Linux 6.15           |
| Batching / linked ops     | Submit many SQEs per `enter`; `IOSQE_IO_LINK` orders them               | `io_uring`; partial on others    | 5.1+ / link 5.3      |
| Thread-per-core placement | Pin one loop per core, shard connections, avoid cross-core sync         | Scheduler-level                  | n/a                  |
| NUMA awareness            | Allocate buffers/queues on the local NUMA node                          | Scheduler-level                  | n/a                  |
| Backpressure              | Bound in-flight work so producers slow to consumer speed                | Library-level                    | n/a                  |
| Buffer pooling            | Recycle buffers to avoid per-op allocation                              | Library-level (pairs with above) | n/a                  |

### 3.1 Registered files and buffers

Each `io_uring` operation normally pays for an fd-table lookup and refcount, and for
`get_user_pages` to pin the I/O buffer. **Registering** them up front amortizes this:
`IORING_REGISTER_FILES` (Linux 5.1) lets an SQE reference a file by _index_ with
`IOSQE_FIXED_FILE`; registered buffers let `READ_FIXED`/`WRITE_FIXED` skip page pinning.
[Glommio][glommio] and [Monoio][monoio] lean on these heavily; there is no readiness-side
analogue because epoll never touches your buffer at all.

### 3.2 Provided buffer rings and multishot

The classic completion problem: to receive, you must commit a buffer _at submission time_,
even though you do not know if or when data will arrive — so a server with 100k idle
connections wastes 100k buffers. **Provided buffer rings** (`IORING_REGISTER_PBUF_RING`,
Linux 5.19) invert this: you hand the kernel a _ring_ of buffers, and it picks one only
when data actually arrives, reporting which buffer it used in the CQE. Combined with
**multishot accept** (Linux 5.19) and **multishot recv** (Linux 6.0), a single submission
serves an unbounded stream of events — one `ACCEPT` SQE produces a CQE per connection
(flagged `IORING_CQE_F_MORE`),
slashing submission overhead. These are the marquee features behind `io_uring`'s networking
throughput; see [io_uring features][io-uring-features] and the
[opcode reference][io-uring-opcodes]. A readiness loop has _no_ counterpart: it always
performs one `accept`/`recv` syscall per event.

### 3.3 Zero-copy send/receive

`IORING_OP_SEND_ZC` (Linux 6.0) sends directly from user pages, avoiding the kernel's copy
into socket buffers; it reports completion as **two** CQEs — a first with the result and
`IORING_CQE_F_MORE`, then a notification CQE with `IORING_CQE_F_NOTIF` once the kernel no
longer needs the pages (so you know when the buffer is reusable). Zero-copy receive
(`io_uring` zero-copy Rx, Linux 6.15) maps NIC buffers into userspace. Both are completion-only.

### 3.4 Batching and linked operations

Because `io_uring` submission is decoupled from execution, a runtime can fill many SQEs and
issue **one** `io_uring_enter`, amortizing the syscall across an entire batch — the core
of its low overhead. `IOSQE_IO_LINK` (Linux 5.3) chains SQEs so they execute in order and
abort the chain on first error, enabling patterns like "connect, then send, then recv" as
one submission. [Zig][zig-io]'s VTable exposes this as a first-class `Batch` type
(`batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel`) and a generic `operate(Operation)`
entry point, so batching is part of the _interface_, not just an implementation detail
(`zig/lib/std/Io.zig`). A readiness loop "batches" only in the weak sense that one
`epoll_wait` returns many ready fds — but each still costs a separate operation syscall.

### 3.5 Thread-per-core, NUMA, backpressure, buffer pooling

These are _scheduler and memory_ concerns layered on top of the I/O backend:

- **Thread-per-core**: one event loop pinned per core, with connections sharded so a
  connection is only ever touched by one core — eliminating cross-core synchronization and
  cache-line bouncing. [Glommio][glommio] and [Seastar][seastar] are built on this model;
  [Monoio][monoio] too. Contrast [Tokio][tokio]'s default work-stealing scheduler, which
  trades locality for automatic load balancing. See [comparison][comparison] and
  [techniques][techniques].
- **NUMA awareness**: allocate each core's queues and buffers on its local NUMA node so
  memory accesses stay local. Most relevant to [Seastar][seastar]-class systems.
- **Backpressure**: bound the number of in-flight operations / queued items so a fast
  producer cannot exhaust memory waiting on a slow consumer — bounded channels, semaphores,
  and ack-based flow control. Orthogonal to the backend but essential at scale.
- **Buffer pooling**: recycle I/O buffers instead of allocating per operation; pairs
  naturally with registered buffers and provided buffer rings (§3.1–3.2), since those want
  long-lived, reusable buffers anyway.

---

## Putting it together: which library reaches which tier

| Library / system     | Backend(s)                                   | Top tier reached | Notes                                                                         |
| -------------------- | -------------------------------------------- | ---------------- | ----------------------------------------------------------------------------- |
| [libuv][libuv]       | epoll/kqueue/IOCP (+ `io_uring` fs)          | Tier 2–3         | Canonical reactor; files on a thread pool, optional `io_uring` offload        |
| [Tokio][tokio]       | epoll/kqueue (mio) + experimental `io_uring` | Tier 2–3         | Work-stealing; files via `spawn_blocking`; `io_uring` behind `tokio_unstable` |
| [trio][trio]         | epoll/kqueue/IOCP                            | Tier 2           | Structured concurrency reference (nurseries, cancel scopes)                   |
| [Glommio][glommio]   | `io_uring`                                   | Tier 3           | Thread-per-core; registered buffers, provided rings                           |
| [Monoio][monoio]     | `io_uring` (+ epoll fallback)                | Tier 3           | Thread-per-core; owned-buffer API for completion safety                       |
| [Seastar][seastar]   | epoll + `io_uring` (AIO legacy)              | Tier 3           | Thread-per-core + NUMA; the original sharded model                            |
| [Zig std.Io][zig-io] | Threaded / Uring / Kqueue / Dispatch         | Tier 3           | One VTable; backend chosen at runtime                                         |
| [Eio][eio]           | `io_uring` (`eio_linux`) / posix             | Tier 2–3         | Effects-based structured concurrency; see [effects-and-event-loops][effects]  |

For the full breadth-first index of systems, see [the async-io index][index]. For a
side-by-side feature matrix, see [comparison][comparison]. For the kernel-level details
that make Tier 3 possible, see the [io_uring features][io-uring-features],
[opcode reference][io-uring-opcodes], and [timeline][io-uring-timeline].

---

## Summary: the tier-vs-backend matrix

| Tier  | Primitive group                       | Readiness (epoll/kqueue)                    | Completion (`io_uring`/IOCP)                  |
| ----- | ------------------------------------- | ------------------------------------------- | --------------------------------------------- |
| **0** | Poller, monotonic timer, wakeup       | `epoll_wait` + timerfd + eventfd            | `io_uring_enter` + ring timeout + `MSG_RING`  |
| **1** | Sockets, timeouts, spawn, `run()`     | readiness wait → syscall, handle `EAGAIN`   | submit op → reap completion with result       |
| **2** | Files                                 | **thread pool** (epoll can't watch files)   | native `READ`/`WRITE`/`OPENAT` opcodes        |
| **2** | DNS                                   | thread pool (`getaddrinfo`)                 | thread pool (no opcode)                       |
| **2** | Signals                               | `signalfd` / self-pipe / `EVFILT_SIGNAL`    | poll a `signalfd` via the ring                |
| **2** | Subprocess                            | `SIGCHLD` / `pidfd`                         | `IORING_OP_WAITID` (Linux 6.7+)               |
| **2** | Cancellation / deadlines              | deregister fd, fail task                    | `ASYNC_CANCEL` + buffer-ownership care        |
| **2** | Structured concurrency / shutdown     | scheduler bookkeeping                       | + drain in-flight SQEs                        |
| **3** | Registered files/buffers              | n/a                                         | `REGISTER_FILES` / `READ_FIXED`               |
| **3** | Provided rings, multishot, zero-copy  | n/a                                         | `PBUF_RING`, multishot accept/recv, `SEND_ZC` |
| **3** | Batching / linked ops                 | weak (one `epoll_wait`, many fds)           | one `enter` per batch, `IOSQE_IO_LINK`        |
| **3** | Thread-per-core / NUMA / backpressure | scheduler & memory layer (backend-agnostic) | same, pairs with registered/pooled buffers    |

---

## Sources

- [libuv `uv.h` handle/request taxonomy] — `libuv/include/uv.h`
- [Tokio source: net, time, fs, signal, process] — `tokio/src/`
- [Tokio io_uring file read] — `tokio/src/fs/read_uring.rs`
- [trio nurseries and cancel scopes] — `trio/_core/_run.py`, `trio/_timeouts.py`
- [trio self-pipe wakeup] — `trio/_core/_wakeup_socketpair.py`
- [Zig `std.Io` VTable] — `zig/lib/std/Io.zig`
- [epoll(7) manual page] (regular files unsupported; `EPERM`)
- [io_uring provided buffer ring (`IORING_REGISTER_PBUF_RING`, 5.19)] (registered files since 5.1, eventfd since 5.2)
- [io_uring_prep_multishot_accept(3) manual page] (multishot accept since 5.19)
- [io_uring provided buffer ring (`IORING_REGISTER_PBUF_RING`, 5.19)]
- [io_uring_enter(2): zero-copy send `IORING_OP_SEND_ZC` since 6.0]
- [io_uring and networking in 2023 (liburing wiki)]
- Related concept docs: [techniques][techniques], [comparison][comparison],
  [io_uring features][io-uring-features], [io_uring opcodes][io-uring-opcodes],
  [effects and event loops][effects]

<!-- References -->

[index]: index.md
[techniques]: techniques.md
[comparison]: comparison.md
[tokio]: tokio.md
[glommio]: glommio.md
[monoio]: monoio.md
[seastar]: seastar.md
[libuv]: libuv.md
[trio]: python-async.md
[zig-io]: zig-io.md
[effects]: effects-and-event-loops.md
[io-uring-features]: io-uring/features.md
[io-uring-opcodes]: io-uring/opcodes-reference.md
[io-uring-timeline]: io-uring/timeline.md
[eio]: ../algebraic-effects/ocaml-eio.md
[libuv `uv.h` handle/request taxonomy]: https://github.com/libuv/libuv/blob/v1.x/include/uv.h
[Tokio source: net, time, fs, signal, process]: https://github.com/tokio-rs/tokio/tree/master/tokio/src
[Tokio io_uring file read]: https://github.com/tokio-rs/tokio/blob/master/tokio/src/fs/read_uring.rs
[trio nurseries and cancel scopes]: https://github.com/python-trio/trio/blob/main/src/trio/_core/_run.py
[trio self-pipe wakeup]: https://github.com/python-trio/trio/blob/main/src/trio/_core/_wakeup_socketpair.py
[Zig `std.Io` VTable]: https://github.com/ziglang/zig/blob/master/lib/std/Io.zig
[epoll(7) manual page]: https://man7.org/linux/man-pages/man7/epoll.7.html
[io_uring_prep_multishot_accept(3) manual page]: https://man7.org/linux/man-pages/man3/io_uring_prep_multishot_accept.3.html
[io_uring provided buffer ring (`IORING_REGISTER_PBUF_RING`, 5.19)]: https://man7.org/linux/man-pages/man2/io_uring_register.2.html
[io_uring_enter(2): zero-copy send `IORING_OP_SEND_ZC` since 6.0]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[io_uring and networking in 2023 (liburing wiki)]: https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023
