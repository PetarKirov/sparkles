# monoio (Rust)

ByteDance's thread-per-core, completion-based Rust async runtime built natively on `io_uring`, with a fallback `epoll`/`kqueue` driver and an owned-buffer (rent) I/O model.

| Field         | Value                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------- |
| Language      | Rust (edition 2021, requires rustc ≥ 1.75)                                                                    |
| License       | MIT OR Apache-2.0                                                                                             |
| Repository    | [monoio GitHub Repository]                                                                                    |
| Documentation | [monoio on docs.rs] / [monoio design docs]                                                                    |
| Key Authors   | ByteDance ([ihciah] / Chihai Hai and contributors)                                                            |
| Pattern       | Thread-per-core executor + **Proactor** (`io_uring`) with a **Reactor** fallback (`epoll`/`kqueue` via [mio]) |
| Encoding      | Native Rust `async`/`await` `Future`s over a single-threaded (`!Send`) local task queue                       |

---

## Overview

### What It Solves

[Tokio], the de-facto Rust runtime, is a _readiness-based_ (reactor) runtime: it uses `epoll`/`kqueue` to learn _when_ a file descriptor is readable or writable, then performs the actual `read`/`write` syscall itself, copying into a **borrowed** `&mut [u8]`. This model is a poor fit for `io_uring`, Linux's _completion-based_ asynchronous I/O interface (see [io-uring/index.md]), where the kernel performs the syscall asynchronously on the application's behalf. With completion I/O the buffer must remain valid for the entire — kernel-controlled — duration of the operation, which is fundamentally incompatible with Rust's borrow-checker if the buffer is merely borrowed across an `await` point that the user can cancel by dropping the future.

monoio is a runtime designed _from scratch_ around completion-based I/O. It is, in the words of its README, "a pure `io_uring`/epoll/kqueue Rust async runtime", borrowing parts of its design from [Tokio] and [tokio-uring] but — unlike tokio-uring, which layers a `current_thread` Tokio runtime underneath — running directly on the driver with no second runtime beneath it. Its central innovation versus Tokio is the **owned-buffer ("rent") I/O model**: the caller surrenders ownership of the buffer to the runtime, which hands it to the kernel, and receives it back inside the completion tuple.

### Design Philosophy

monoio commits hard to a **thread-per-core** architecture:

1. **No work-stealing, no `Send` bounds on tasks.** Each runtime instance is pinned to one OS thread (typically one per core). Tasks, their futures, and their buffers never migrate between threads, so the task type is `!Send` and `!Sync`. The local run queue (`TaskQueue`) is explicitly marked `!Send`/`!Sync` via `PhantomData<*const ()>`. This means thread-local state can be used freely without synchronization — ideal for shared-nothing servers (the README's example is "a load balancer like NGINX").

2. **Completion-first, with a degraded fallback.** The preferred driver is `io_uring`. Where `io_uring` is unavailable (older kernels, macOS, or when the `iouring` feature is off), monoio degrades to a _legacy_ `epoll`/`kqueue` driver built on [mio] that emulates the same owned-buffer API by performing the syscall itself on readiness. The `FusionDriver`/`FusionRuntime` types let a binary pick between the two at runtime.

3. **Native `async`/`await`, no monadic or effect machinery.** Unlike the effect-handler runtimes surveyed in the [algebraic-effects corpus][ocaml-eio] (e.g. OCaml's Eio), monoio uses plain Rust `Future`s polled by a hand-written single-threaded executor. Its I/O traits (`AsyncReadRent`, `AsyncWriteRent`) use Rust's **return-position `impl Trait` in traits / async-fn-in-traits** to express `async fn` returning owned buffers — these traits formerly relied on **GATs** (generic associated types) and are still commonly described as "rent traits".

4. **Maximal throughput at the cost of compatibility.** monoio deliberately enables unstable features and a non-standard I/O abstraction. Its benchmarks claim a 2–3× improvement over Tokio/Glommio for its target workloads, accepting that the owned-buffer API is awkward and that imbalanced workloads can underperform a work-stealing runtime.

---

## Core abstractions and types

### The runtime and the scheduler

The central object is `Runtime<D>`, parameterized by a driver type `D`
(`monoio/src/runtime.rs`):

```rust
// monoio/src/runtime.rs
pub struct Runtime<D> {
    pub(crate) context: Context,
    pub(crate) driver: D,
}
```

`Context` is the per-thread execution context, stored in a `scoped_thread_local!`
named `CURRENT`. It owns the local run queue, a generated thread id, an optional
time-driver handle, and (under the `sync` feature) caches for cross-thread
wakers:

```rust
// monoio/src/runtime.rs
pub(crate) struct Context {
    /// Owned task set and local run queue
    pub(crate) tasks: TaskQueue,
    /// Thread id (not the kernel thread id but a generated unique number)
    pub(crate) thread_id: usize,
    /// Time Handle
    pub(crate) time_handle: Option<TimeHandle>,
    // ... sync-only fields elided ...
}
```

The scheduler is intentionally minimal. `LocalScheduler` is a unit struct whose
`schedule`/`yield_now` simply push the task back onto the current thread's queue
(`monoio/src/scheduler.rs`):

```rust
// monoio/src/scheduler.rs
pub(crate) struct LocalScheduler;

impl Schedule for LocalScheduler {
    fn schedule(&self, task: Task<Self>) {
        crate::runtime::CURRENT.with(|cx| cx.tasks.push(task));
    }
    fn yield_now(&self, task: Task<Self>) {
        self.schedule(task);
    }
}
```

`TaskQueue` wraps an `UnsafeCell<VecDeque<Task<LocalScheduler>>>` with a
`PhantomData<*const ()>` marker to keep it `!Send`/`!Sync`. Because everything is
single-threaded, the queue needs no locks — pushes and pops are direct
`UnsafeCell` accesses. The default capacity is 4096 tasks.

| Type                | File           | Role                                                                        |
| ------------------- | -------------- | --------------------------------------------------------------------------- |
| `Runtime<D>`        | `runtime.rs`   | Owns the `Context` + driver; `block_on` runs the event loop                 |
| `Context`           | `runtime.rs`   | Per-thread state (run queue, thread id, time handle); held in `CURRENT` TLS |
| `LocalScheduler`    | `scheduler.rs` | Pushes runnable tasks onto the current thread's queue                       |
| `TaskQueue`         | `scheduler.rs` | `!Send`/`!Sync` `VecDeque` of runnable tasks                                |
| `JoinHandle<T>`     | `task/`        | Awaitable handle returned by `spawn`                                        |
| `RuntimeBuilder<D>` | `builder.rs`   | Configures entries, timer, `io_uring::Builder`, blocking strategy           |
| `FusionRuntime`     | `runtime.rs`   | Enum wrapper choosing the uring or legacy runtime at runtime                |

### The Driver abstraction

The I/O backend is hidden behind the `Driver` trait
(`monoio/src/driver/mod.rs`):

```rust
// monoio/src/driver/mod.rs
pub trait Driver {
    /// Run with driver TLS.
    fn with<R>(&self, f: impl FnOnce() -> R) -> R;
    /// Submit ops to kernel and process returned events.
    fn submit(&self) -> io::Result<()>;
    /// Wait infinitely and process returned events.
    fn park(&self) -> io::Result<()>;
    /// Wait with timeout and process returned events.
    fn park_timeout(&self, duration: Duration) -> io::Result<()>;
    // ... sync-only Unpark associated type elided ...
}
```

Two concrete drivers implement it:

- `IoUringDriver` (`driver/uring/mod.rs`) — the completion-based proactor. Gated on `#[cfg(all(target_os = "linux", feature = "iouring"))]`.
- `LegacyDriver` (`driver/legacy/mod.rs`) — the readiness-based reactor. On Unix it polls via [mio]'s `Poll` (`epoll` on Linux, `kqueue` on macOS/BSD); on Windows it uses monoio's own AFD/IOCP-based poller in `driver/iocp/`. Gated on `#[cfg(feature = "legacy")]`.

Both wrap their per-thread state in `Rc<UnsafeCell<…>>` (`UringInner` /
`LegacyInner`) — again, single-threaded, so `Rc` not `Arc`. A `scoped_thread_local!`
named `driver::CURRENT` holds an `Inner` enum so that I/O operations anywhere in
the call stack can reach the active driver without threading a handle through:

```rust
// monoio/src/driver/mod.rs
pub(crate) enum Inner {
    #[cfg(all(target_os = "linux", feature = "iouring"))]
    Uring(std::rc::Rc<std::cell::UnsafeCell<UringInner>>),
    #[cfg(feature = "legacy")]
    Legacy(std::rc::Rc<std::cell::UnsafeCell<LegacyInner>>),
}
```

### The operation: `Op<T>`, `OpAble`, `CompletionMeta`

Every I/O action is modeled as an in-flight operation `Op<T>` whose payload `T`
implements the `OpAble` trait (`monoio/src/driver/op.rs`). `OpAble` is the seam
that lets one operation definition target _both_ drivers:

```rust
// monoio/src/driver/op.rs
pub(crate) trait OpAble {
    #[cfg(all(target_os = "linux", feature = "iouring"))]
    const RET_IS_FD: bool = false;
    #[cfg(all(target_os = "linux", feature = "iouring"))]
    const SKIP_CANCEL: bool = false;
    #[cfg(all(target_os = "linux", feature = "iouring"))]
    fn uring_op(&mut self) -> io_uring::squeue::Entry;

    #[cfg(any(feature = "legacy", feature = "poll-io"))]
    fn legacy_interest(&self) -> Option<(super::ready::Direction, usize)>;
    #[cfg(any(feature = "legacy", feature = "poll-io"))]
    fn legacy_call(&mut self) -> io::Result<MaybeFd>;
}
```

- `uring_op` builds an `io_uring::squeue::Entry` (a Submission Queue Entry, SQE) for the proactor path.
- `legacy_interest` reports which readiness direction (read/write) and which registered fd slot to wait on; `legacy_call` performs the actual blocking syscall once the fd is ready.

`Op<T>` itself records the driver, a slab index, and the operation's owned data:

```rust
// monoio/src/driver/op.rs
pub(crate) struct Op<T: 'static + OpAble> {
    pub(super) driver: driver::Inner,  // driver running the operation
    pub(super) index: usize,           // slot in the slab (unused for legacy)
    pub(super) data: Option<T>,        // per-operation data (incl. the owned buffer)
}
```

`Op<T>` _is itself a `Future`_. Polling it asks the driver whether the operation
has completed, and on completion yields a `Completion<T>` carrying back the data
and a `CompletionMeta`:

```rust
// monoio/src/driver/op.rs
pub(crate) struct CompletionMeta {
    pub(crate) result: io::Result<MaybeFd>,
    pub(crate) flags: u32,
}
```

`MaybeFd` is a small wrapper around a `u32` that remembers whether the returned
number is a file descriptor; if so and the result is dropped without being
consumed (e.g. an `accept` whose future was cancelled), it `close()`s the fd to
prevent leaks.

### The owned-buffer model: `IoBuf` / `IoBufMut`

The crux of the design. A buffer passed to an `io_uring` operation must outlive
the kernel's use of it, and its address must be stable. monoio expresses this
with two `unsafe` traits (`monoio/src/buf/io_buf.rs`):

```rust
// monoio/src/buf/io_buf.rs
pub unsafe trait IoBuf: Unpin + 'static {
    /// Pointer the kernel will READ `bytes_init()` bytes from.
    fn read_ptr(&self) -> *const u8;
    fn bytes_init(&self) -> usize;
    // slice(self, range) -> Slice<Self>  // owned slicing, see below
}

pub unsafe trait IoBufMut: Unpin + 'static {
    /// Pointer the kernel will WRITE up to `bytes_total()` bytes into.
    fn write_ptr(&mut self) -> *mut u8;
    fn bytes_total(&mut self) -> usize;
    unsafe fn set_init(&mut self, pos: usize);
}
```

Both bounds (`Unpin + 'static`) are essential: `'static` guarantees the buffer
contains no borrowed references that could dangle while the kernel works, and
the runtime takes ownership so it can keep the buffer alive for the operation's
whole life. The doc comment on `IoBuf` makes the rationale explicit:

> Because buffers are passed by ownership to the runtime, Rust's slice API (`&buf[..]`) cannot be used. Instead, `monoio` provides an owned slice API: `slice()`.

`IoBuf`/`IoBufMut` are implemented for `Vec<u8>`, `Box<[u8]>`, `Box<[u8; N]>`,
`&'static [u8]`, `&'static str`, `bytes::Bytes`/`BytesMut` (feature-gated), and
forwarding wrappers `Rc<T>`, `Arc<T>`, `ManuallyDrop<T>`. There are companion
`IoVecBuf`/`IoVecBufMut` traits for vectored `iovec`/`WSABUF` I/O, plus
`Slice`/`SliceMut` owned views (returned by `buf.slice(a..b)`) that track an
offset/length so a sub-range of an owned buffer can be submitted without losing
the whole buffer.

### The rent traits: `AsyncReadRent` / `AsyncWriteRent`

I/O is performed through "rent" traits — so named because the caller _lends_ the
buffer to the runtime and gets it back. They live in
`monoio/src/io/async_read_rent.rs` and `async_write_rent.rs`:

```rust
// monoio/src/io/async_read_rent.rs
pub trait AsyncReadRent {
    fn read<T: IoBufMut>(&mut self, buf: T)
        -> impl Future<Output = BufResult<usize, T>>;
    fn readv<T: IoVecBufMut>(&mut self, buf: T)
        -> impl Future<Output = BufResult<usize, T>>;
}

// monoio/src/io/async_write_rent.rs
pub trait AsyncWriteRent {
    fn write<T: IoBuf>(&mut self, buf: T)
        -> impl Future<Output = BufResult<usize, T>>;
    fn writev<T: IoVecBuf>(&mut self, buf_vec: T)
        -> impl Future<Output = BufResult<usize, T>>;
    fn flush(&mut self) -> impl Future<Output = std::io::Result<()>>;
    fn shutdown(&mut self) -> impl Future<Output = std::io::Result<()>>;
}
```

The return type is the key:

```rust
// monoio/src/lib.rs
pub type BufResult<T, B> = (std::io::Result<T>, B);
```

A `read` returns `(Ok(n), buf)` — the result _and the buffer back_. This is why
monoio code always reassigns the buffer:

```rust
// from monoio/README.md echo example
let mut buf: Vec<u8> = Vec::with_capacity(8 * 1024);
let mut res;
loop {
    (res, buf) = stream.read(buf).await;       // lend buf, get it back
    if res? == 0 { return Ok(()); }
    (res, buf) = stream.write_all(buf).await;  // lend it again
    res?;
    buf.clear();
}
```

There are positional variants (`AsyncReadRentAt::read_at`,
`AsyncWriteRentAt::write_at`, mirroring `pread`/`pwrite`), buffered adapters
(`BufReader`/`BufWriter`), ergonomic `…Ext` traits (`read_exact`, `write_all`),
and **cancelable** variants (`CancelableAsyncReadRent`, etc.) that take a
`CancelHandle`. The same traits also have blanket impls over in-memory sources
like `&[u8]` and `Cursor<T>`, which copy synchronously and return a
ready future — so the abstraction works without any kernel involvement too.

#### Why ownership, contrasted with Tokio

|                         | Tokio (`AsyncRead`/`AsyncWrite`)                 | monoio (`AsyncReadRent`/`AsyncWriteRent`)                                      |
| ----------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------ |
| Buffer passing          | borrowed `&mut [u8]` / `&[u8]`                   | owned `T: IoBufMut` / `T: IoBuf`                                               |
| Lifetime model          | buffer lives on the caller's stack across `poll` | buffer moved into the runtime, returned in completion                          |
| On future drop / cancel | trivial — kernel never touched the buffer        | runtime must keep the buffer alive (it owns it) and may submit an async cancel |
| Underlying mechanism    | reactor: runtime issues the syscall on readiness | proactor: kernel issues the syscall, signals completion                        |
| Cost                    | extra readiness round-trip per op                | buffer ping-pong + occasional re-allocation churn                              |

With borrowed buffers a _completion_-based backend would be unsound: if the user
drops the read future, Rust frees the stack buffer, but the kernel may still
write into it later. By transferring ownership into `Op<T>`, monoio guarantees
the buffer (and the `SharedFd`, see below) survive until the kernel finishes,
even across cancellation.

---

## How it works

### The event loop (`block_on`)

`Runtime::block_on` (`monoio/src/runtime.rs`) is a hand-rolled executor. The
shape of the loop:

```rust
// monoio/src/runtime.rs (Runtime::block_on, condensed)
self.driver.with(|| {                  // install driver into driver::CURRENT TLS
    CURRENT.set(&self.context, || {    // install runtime Context TLS
        let mut join = std::pin::pin!(future);
        loop {
            loop {
                // 1. Drain the local run queue (bounded by 2× len to avoid IO starvation)
                let mut max_round = self.context.tasks.len() * 2;
                while let Some(t) = self.context.tasks.pop() {
                    t.run();
                    if max_round == 0 { break; } else { max_round -= 1; }
                }
                // 2. Poll the top-level future
                while should_poll() {
                    if let Poll::Ready(t) = join.as_mut().poll(cx) { return t; }
                }
                // 3. Hot path: nothing runnable → break to block on IO
                if self.context.tasks.is_empty() { break; }
                // 4. Cold path: still tasks queued → flush SQ without blocking
                let _ = self.driver.submit();
            }
            // 5. Block in the kernel until at least one completion, then process CQ
            let _ = self.driver.park();
        }
    })
})
```

The loop alternates between running ready tasks and _parking_ in the kernel.
Crucially, `submit_with_data` does **not** issue an `io_uring_enter` syscall when
an op is created — it only pushes the SQE into the in-memory submission queue.
The actual submission is deferred and batched: it happens on `park`
(`submit_and_wait`) or on the cold-path `submit`. This batching ("we are not
going to do syscall now … we will submit on `park`", per the source comment) is a
major reason monoio amortizes syscall cost.

### The `io_uring` driver: submission

`UringInner` (`monoio/src/driver/uring/mod.rs`) owns the `io_uring::IoUring`
instance (from the [io-uring crate]) plus a `Slab<MaybeFdLifecycle>` tracking
in-flight ops. The default SQ/CQ depth is 1024 entries. Submitting an op:

```rust
// monoio/src/driver/uring/mod.rs (UringInner::submit_with_data, condensed)
pub(crate) fn submit_with_data<T: OpAble>(this, data) -> io::Result<Op<T>> {
    let inner = unsafe { &mut *this.get() };
    if inner.uring.submission().is_full() { inner.submit()?; } // flush if SQ full
    let mut op = Self::new_op(data, inner, Inner::Uring(this.clone()));
    let data_mut = unsafe { op.data.as_mut().unwrap_unchecked() };
    let sqe = OpAble::uring_op(data_mut)        // build the SQE
        .user_data(op.index as _);              // tag it with the slab index
    let mut sq = inner.uring.submission();
    if unsafe { sq.push(&sqe).is_err() } { unimplemented!("..."); }
    Ok(op)                                       // NOT submitted yet — see block_on
}
```

The slab index is stored in the SQE's `user_data` field; when the kernel posts a
Completion Queue Entry (CQE), `user_data` routes the result back to the right
slot. Each op definition produces a different SQE. From the actual ops in
`driver/op/` (e.g. `read.rs`):

```rust
// monoio/src/driver/op/read.rs — Read::uring_op
opcode::Read::new(
    types::Fd(self.fd.raw_fd()),
    self.buf.write_ptr(),                 // owned buffer's stable pointer
    self.buf.bytes_total() as _,
)
.offset(-1i64 as u64)                     // -1 → use+advance the fd's file position
.build()
```

### `io_uring` opcodes used

monoio maps its operations onto these `io_uring` opcodes (from
`monoio/src/driver/op/`), each with a matching `legacy_call` syscall:

| monoio op                           | `io_uring` opcode(s)                        | Legacy syscall                                  | Notes                                  |
| ----------------------------------- | ------------------------------------------- | ----------------------------------------------- | -------------------------------------- |
| `Read` / `ReadAt`                   | `opcode::Read`                              | `read(2)` / `pread(2)`                          | `offset(-1)` ≙ current file position   |
| `ReadVec`/`ReadVecAt`               | `opcode::Readv`                             | `readv(2)` / `preadv(2)` (`WSARecv` on Windows) | vectored                               |
| `Write` / `WriteAt`                 | `opcode::Write`                             | `write(2)` / `pwrite(2)`                        |                                        |
| `WriteVec`                          | `opcode::Writev`                            | `writev(2)` / `pwritev(2)`                      |                                        |
| `Recv` / `Send`                     | `opcode::Recv` / `opcode::Send`             | `recv(2)` / `send(2)`                           | sockets                                |
| `RecvMsg` / `SendMsg`               | `opcode::RecvMsg` / `opcode::SendMsg`       | `recvmsg(2)` / `sendmsg(2)`                     | datagram / ancillary                   |
| zero-copy send                      | `opcode::SendZc` / `opcode::SendMsgZc`      | — (uring-only)                                  | multi-CQE; see lifecycle below         |
| `Accept`                            | `opcode::Accept`                            | `accept4(2)`                                    | `RET_IS_FD = true`                     |
| `Connect`                           | `opcode::Connect`                           | `connect(2)`                                    |                                        |
| `Close`                             | `opcode::Close`                             | `close(2)`                                      |                                        |
| `Fsync`                             | `opcode::Fsync`                             | `fsync(2)`/`fdatasync(2)`                       |                                        |
| `Open`                              | `opcode::OpenAt`                            | `openat(2)`                                     | `RET_IS_FD = true`                     |
| `Statx`                             | `opcode::Statx`                             | `statx(2)`                                      | Linux-only; backs `fs` metadata        |
| `Splice`                            | `opcode::Splice`                            | `splice(2)`                                     | `splice` feature, Linux-only zero-copy |
| `MkDir`/`Unlink`/`Rename`/`Symlink` | `MkDirAt`/`UnlinkAt`/`RenameAt`/`SymlinkAt` | `*at(2)` syscalls                               | feature-gated filesystem ops           |

Internally the driver also uses `opcode::Timeout` and `opcode::AsyncCancel`
(reserved `user_data` values), `opcode::PollAdd` for the `poll-io` poller, and
`opcode::Read` against an `eventfd` for cross-thread wakeups under the `sync`
feature.

### The `io_uring` driver: completion and lifecycle

When parked, the driver calls `submit_and_wait(1)` and then `tick()` drains the
completion queue. `tick()` dispatches each CQE by `user_data`:

```rust
// monoio/src/driver/uring/mod.rs (UringInner::tick, condensed)
for cqe in self.uring.completion() {
    let index = cqe.user_data();
    match index {
        EVENTFD_USERDATA => self.eventfd_installed = false,    // sync wakeup
        POLLER_USERDATA  => { /* poll-io readiness */ }
        _ if index >= MIN_REVERSED_USERDATA => (),             // timeout/cancel — ignore
        _ => unsafe { self.ops.complete(index, resultify(&cqe), cqe.flags()) },
    }
}
```

Each slab slot is a `MaybeFdLifecycle` wrapping a `Lifecycle` state machine
(`monoio/src/driver/uring/lifecycle.rs`), explicitly "partly borrow[ed] from
tokio-uring":

```rust
// monoio/src/driver/uring/lifecycle.rs
enum Lifecycle {
    Submitted,                               // in-flight, future not yet polled
    Waiting(Waker),                          // future polled; waker stored
    Ignored(Box<dyn std::any::Any>),         // future dropped; keep data alive
    Completed(io::Result<MaybeFd>, u32),     // CQE arrived
    // multi-CQE states for zero-copy (SEND_ZC) ops:
    CompletedMore(io::Result<MaybeFd>, u32),
    WaitingMore(Waker, io::Result<MaybeFd>, u32),
    IgnoredMore(Box<dyn std::any::Any>),
}
```

The normal flow is `Submitted → (poll) Waiting → (CQE) Completed → (poll) Ready`.
When a CQE arrives in `Waiting`, the stored `Waker` is woken so the executor
re-polls `Op<T>::poll`, which removes the slot and returns the
`Completion { data, meta }`. The `…More` states handle **multishot/zero-copy**
ops (`SendZc`/`SendMsgZc`), where the kernel posts _two_ CQEs — a result CQE with
`IORING_CQE_F_MORE` and a later notification CQE with `IORING_CQE_F_NOTIF` — and
the op must not be considered done until the notification arrives, because only
then is the buffer no longer referenced by the kernel.

### Cancellation safety

If a future is dropped while its op is in-flight, `Op<T>::drop` calls the
driver's `drop_op`. The lifecycle moves to `Ignored`, **stowing the owned data
(buffer + `SharedFd`) in a `Box<dyn Any>` inside the slab** so it outlives the
kernel operation; when the CQE finally arrives, the slot — and the buffer — are
freed. Under the `async-cancel` feature it additionally submits an
`opcode::AsyncCancel` SQE targeting the op's slab index to ask the kernel to
abort early. This is exactly the soundness guarantee the owned-buffer model
buys: cancellation can never expose the kernel to freed memory.

The fd is itself reference-counted via `SharedFd`
(`monoio/src/driver/shared_fd.rs`): each `Op` holds a clone, so a `close` cannot
race ahead of in-flight reads/writes on the same fd.

### The legacy (epoll/kqueue) fallback

`LegacyDriver` (`monoio/src/driver/legacy/mod.rs`) implements the same `Driver`
trait over a `mio::Poll`. Its state is a `Slab<ScheduledIo>` keyed by mio
`Token`, where `ScheduledIo` tracks readiness and per-direction wakers. There is
no SQE/CQE; instead `submit_with_data` just stores the op (its `index` is
"useless for legacy"), and progress happens entirely inside `poll_op`:

```rust
// monoio/src/driver/legacy/mod.rs (LegacyInner::poll_op, condensed)
let (direction, index) = match data.legacy_interest() {
    Some(x) => x,
    None => return Poll::Ready(CompletionMeta {        // fd-less op: syscall now
        result: OpAble::legacy_call(data), flags: 0,
    }),
};
let mut scheduled_io = inner.io_dispatch.get(index).expect("scheduled_io lost");
let readiness = ready!(scheduled_io.as_mut().poll_readiness(cx, direction));
// ... cancellation check ...
match OpAble::legacy_call(data) {                       // do the real syscall
    Ok(n) => Poll::Ready(CompletionMeta { result: Ok(n), flags: 0 }),
    Err(ref e) if e.kind() == WouldBlock => {           // not ready → re-arm
        scheduled_io.clear_readiness(direction.mask());
        scheduled_io.set_waker(cx, direction);
        Poll::Pending
    }
    Err(e) => Poll::Ready(CompletionMeta { result: Err(e), flags: 0 }),
}
```

So the legacy path is a classic reactor: wait for `epoll`/`kqueue` readiness,
then invoke the same `legacy_call` syscall the `OpAble` defines, retrying on
`EWOULDBLOCK`. The owned-buffer _API_ is identical to the uring path — the buffer
is still moved in and returned in the completion tuple — but here the syscall is
synchronous and the buffer round-trip is mostly bookkeeping. `park` translates to
`mio::Poll::poll`.

### Version gating and selecting a driver

| Driver / feature path            | Platform & kernel requirement                                   | Selected by                                  |
| -------------------------------- | --------------------------------------------------------------- | -------------------------------------------- |
| `IoUringDriver`                  | Linux **5.6+** (README) with `io_uring` enabled; memlock raised | `feature = "iouring"`, `target_os = "linux"` |
| `LegacyDriver` (epoll)           | Linux (any with `epoll`)                                        | `feature = "legacy"`                         |
| `LegacyDriver` (kqueue)          | macOS / BSD                                                     | `feature = "legacy"`                         |
| `LegacyDriver` (IOCP poll)       | Windows (experimental)                                          | `feature = "legacy"`                         |
| `FusionDriver` / `FusionRuntime` | Picks uring if available at runtime, else legacy                | both features enabled                        |

Within the uring driver, the _timeout_ path is further version-gated at runtime
by probing `IORING_FEAT_EXT_ARG` (via `uring.params().is_feature_ext_arg()`):

```rust
// monoio/src/driver/uring/mod.rs (inner_park, timeout branch, condensed)
match inner.ext_arg {
    // Submit & wait using a TimeoutOp SQE. Better compatibility (5.4+).
    false => { self.install_timeout(inner, duration); inner.uring.submit_and_wait(1)?; }
    // Submit & wait passing the timeout via enter args. Better performance (5.11+).
    true => {
        let timespec = timespec(duration);
        let args = io_uring::types::SubmitArgs::new().timespec(&timespec);
        inner.uring.submitter().submit_with_args(1, &args)?; // ETIME tolerated
    }
}
```

`io_uring` itself first landed in Linux **5.1** (May 2019); `IORING_OP_TIMEOUT`
arrived in **5.4**, and `IORING_FEAT_EXT_ARG` (passing a timeout/sigmask directly
to `io_uring_enter(2)` without a dedicated timeout SQE) in **5.11**. monoio uses
the older Timeout-SQE approach as the compatible fallback and the
`submit_with_args` fast path when the kernel advertises `EXT_ARG`.

### Tasks, spawning, and integration with `async`/`await`

`monoio::spawn` creates a task and pushes it onto `CURRENT.tasks`; it requires
`T: Future + 'static` but **not** `Send`:

```rust
// monoio/src/runtime.rs
pub fn spawn<T>(future: T) -> JoinHandle<T::Output>
where T: Future + 'static, T::Output: 'static {
    let (task, join) = new_task(get_current_thread_id(), future, LocalScheduler);
    CURRENT.with(|ctx| ctx.tasks.push(task));
    join
}
```

Because tasks never leave their thread, the future and everything it captures
(buffers, `Rc`s, `RefCell`s) can be non-`Send`. This is the practical payoff of
thread-per-core: no atomics on the task hot path, no `Send`/`Sync` bounds to
fight, and free use of `thread_local!`. The cost is that load balancing across
cores is the application's responsibility (e.g. `SO_REUSEPORT` listeners, one
runtime per core). The `#[monoio::main]` macro wires up a default runtime;
`monoio::start::<D, _>(fut)` or `RuntimeBuilder::<D>::new().build()` give explicit
control over the driver and options.

---

## Performance approach

- **Deferred, batched submission.** Creating an op only enqueues an SQE; the
  `io_uring_enter` syscall is issued once per park (`submit_and_wait`),
  amortizing syscall overhead across all ops enqueued since the last park.
- **Proactor avoids the readiness round-trip.** With `io_uring` the kernel does
  the `read`/`write` directly, eliminating the "epoll says readable → do
  syscall" two-step of a reactor and reducing syscalls and context switches.
- **Shared-nothing, lock-free per core.** `Rc`/`UnsafeCell` everywhere,
  `!Send` tasks, a plain `VecDeque` run queue — no atomics or mutexes on the
  task scheduling path. State that _must_ cross threads (the `sync` feature) goes
  through an `eventfd`-backed unpark + `flume` waker channel, kept off the hot
  path.
- **Starvation guard.** The run queue is drained with a `2 × len` round cap so a
  self-rescheduling task cannot starve I/O.
- **Zero-copy and registered I/O.** `SendZc`/`SendMsgZc` use `io_uring`'s
  zero-copy send (multi-CQE), and the `splice` feature exposes kernel-space
  `splice(2)`.
- **Claimed results.** ByteDance's benchmarks report monoio outperforming Tokio
  and Glommio (see [glommio.md]) on latency and throughput for its target
  network-server workloads, with larger gains as core count rises.

---

## Strengths

- **Sound, native completion-based I/O** — the owned-buffer model makes
  `io_uring` safe under Rust's ownership rules, including cancellation.
- **True thread-per-core** with `!Send` tasks: no synchronization on the hot
  path, free thread-local state, predictable per-core scaling.
- **Single layer** — runs directly on the driver, not atop another runtime as
  tokio-uring does.
- **Graceful degradation** to `epoll`/`kqueue` via the legacy driver, so the same
  source builds on older Linux, macOS, and (experimentally) Windows.
- **Rich opcode coverage** including zero-copy send, `splice`, vectored I/O, and
  `*at` filesystem ops, all unified behind one `OpAble` trait.
- **Companion ecosystem** — `monoio-codec`, `monoio-tls`, `local-sync` provide
  codecs, TLS, and thread-local channels tuned for the model.

## Weaknesses

- **Owned-buffer API is intrusive.** Every read/write threads the buffer in and
  out (`(res, buf) = stream.read(buf).await`), which is awkward and incompatible
  with the vast `AsyncRead`/`AsyncWrite` ecosystem. A `poll-io` compatibility
  shim and `tokio-compat` exist but are partial.
- **Imbalanced workloads underperform.** With no work-stealing, a hot connection
  pinned to one core can leave others idle — the README explicitly notes possible
  regression versus Tokio in that case.
- **Buffer churn / lifetime juggling.** Moving buffers in and out can cause
  re-allocation and complicates APIs that want to retain a buffer; cancellation
  may strand a buffer in the slab until the CQE lands.
- **Unstable surface.** Targets recent rustc, enables unstable features, and the
  bespoke I/O traits limit drop-in interop.
- **Newer / narrower ecosystem** than Tokio; primarily aimed at network servers,
  less suited to general-purpose async apps.
- **`io_uring` operational caveats** — needs Linux 5.6+, raised memlock limits,
  and `io_uring` has been disabled by some hardened environments for security
  reasons (see [io-uring/index.md]).

---

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                                                | Trade-off                                                                 |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Owned-buffer (rent) traits over borrowed `&mut [u8]` | Required for sound completion I/O; buffer must outlive kernel use & survive cancellation | Intrusive API; ecosystem incompatibility; buffer ping-pong & churn        |
| Thread-per-core, `!Send` tasks, no work-stealing     | Lock-free hot path, free thread-local state, linear multi-core scaling                   | App must balance load; imbalanced workloads can regress vs Tokio          |
| `io_uring` proactor as the primary backend           | Fewer syscalls / context switches; kernel does the I/O                                   | Linux 5.6+ only; memlock tuning; security-policy friction in some envs    |
| Legacy `epoll`/`kqueue` driver behind same `OpAble`  | Portability and old-kernel support with one codebase                                     | Two code paths to maintain; reactor lacks the proactor's syscall savings  |
| Run directly on the driver (not atop Tokio)          | Avoids tokio-uring's double-runtime overhead                                             | Reimplements executor, timers, blocking pool, sync primitives             |
| Deferred, batched SQE submission (submit on `park`)  | Amortizes `io_uring_enter` cost across many ops                                          | Slightly higher latency for a lone op; cold-path re-submission logic      |
| `Rc<UnsafeCell<…>>` for driver/queue state           | No atomics needed in a single-threaded runtime                                           | `unsafe` internals; cross-thread features need a separate eventfd channel |
| `MaybeFd` + `SharedFd` ref-counting                  | Prevents fd/buffer leaks on cancellation; orders `close` after I/O                       | Extra bookkeeping per op; cancelled fd-returning ops do a stray `close`   |
| Runtime-probe `IORING_FEAT_EXT_ARG` for timeouts     | Fast `submit_with_args` path on 5.11+, Timeout-SQE fallback on 5.4+                      | Branchy park logic; behavior differs subtly across kernel versions        |

---

## Sources

- [monoio GitHub Repository] — README (design goals, thread-per-core, `io_uring`/epoll/kqueue, echo example) and source tree
- [monoio on docs.rs] — API reference for `Runtime`, `Driver`, `IoBuf`/`IoBufMut`, `AsyncReadRent`/`AsyncWriteRent`
- [monoio design docs] — platform support, memlock, legacy-driver, and benchmark docs
- [io-uring crate] — the `io_uring::{IoUring, opcode, squeue, cqueue}` bindings monoio builds on
- [tokio-uring] — the `io_uring`-on-Tokio project monoio's lifecycle borrows from and contrasts with
- [io_uring(7) man page] — `io_uring` semantics, the SQ/CQ ring buffers, and feature flags
- [io_uring_enter(2) man page] — submission/wait syscall and `IORING_ENTER_EXT_ARG` (`IORING_FEAT_EXT_ARG`, since 5.11)
- [The rapid growth of io_uring (LWN)] — history, `IORING_OP_TIMEOUT`, kernel timeline
- [io_uring (Wikipedia)] — first merged in Linux 5.1 (May 2019)
- [Introduction to Monoio (chesedo)] — third-party design overview
- [Monoio on lib.rs] — crate metadata and feature list
- Related sibling docs: [Tokio][tokio.md], [Glommio][glommio.md], the [io_uring concept doc][io-uring/index.md], and the effects-based [Eio runtime][ocaml-eio]

<!-- References -->

[monoio GitHub Repository]: https://github.com/bytedance/monoio
[monoio on docs.rs]: https://docs.rs/monoio/latest/monoio/
[monoio design docs]: https://github.com/bytedance/monoio/tree/master/docs/en
[ihciah]: https://github.com/ihciah
[mio]: https://github.com/tokio-rs/mio
[Tokio]: https://github.com/tokio-rs/tokio
[tokio-uring]: https://github.com/tokio-rs/tokio-uring
[io-uring crate]: https://docs.rs/io-uring/latest/io_uring/
[io_uring(7) man page]: https://man7.org/linux/man-pages/man7/io_uring.7.html
[io_uring_enter(2) man page]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[The rapid growth of io_uring (LWN)]: https://lwn.net/Articles/810414/
[io_uring (Wikipedia)]: https://en.wikipedia.org/wiki/Io_uring
[Introduction to Monoio (chesedo)]: https://chesedo.me/blog/monoio-introduction/
[Monoio on lib.rs]: https://lib.rs/crates/monoio
[tokio.md]: ./tokio.md
[glommio.md]: ./glommio.md
[io-uring/index.md]: ./io-uring/index.md
[ocaml-eio]: ../algebraic-effects/ocaml-eio.md
