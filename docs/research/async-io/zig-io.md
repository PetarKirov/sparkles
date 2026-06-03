# Zig `std.Io` (the new `Io` interface)

A vtable-based I/O and concurrency capability, passed explicitly as a value, that decouples ordinary direct-style code from whichever concrete blocking or evented implementation runs it -- write the I/O once, pick the execution model at the call site.

| Field         | Value                                                                                                                                                                                                 |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Zig (standard library, in development for 0.16.0)                                                                                                                                                     |
| License       | MIT                                                                                                                                                                                                   |
| Repository    | [ziglang/zig]                                                                                                                                                                                         |
| Documentation | [Zig 0.16.0 Release Notes] / [Zig's New Async I/O (Andrew Kelley)] / [Loris Cro: Zig's New Async I/O]                                                                                                 |
| Key Authors   | Andrew Kelley, Loris Cro, Zig contributors                                                                                                                                                            |
| Pattern       | Capability interface (`userdata + *const VTable`) over interchangeable backends: Threaded (thread pool + blocking syscalls), Uring (`io_uring` + stackful fibers), Kqueue (BSD), Dispatch (macOS GCD) |
| Encoding      | Non-generic vtable; eager-result `async`, fallible `concurrent`, `await`/`cancel`; stackful fibers on evented backends                                                                                |

---

## Overview

### What it solves

Zig had a `async`/`await` system built on stackless coroutines and compiler-rewritten state machines. It was removed several releases ago: the team concluded the design coupled every async function to a single execution model (stackless coroutines), produced "function coloring" -- where a function's async-ness leaks into its type and forces all callers to be async too -- and could not serve the full spread of targets Zig cares about, from a single-threaded microcontroller to a millions-of-connections event-driven server.

The replacement is `std.Io`: not a language feature but a plain value. An `Io` is a fat pointer -- a `userdata` plus a pointer to a `VTable` of function pointers -- threaded explicitly through code that performs I/O or concurrency. Code calls `io.async(...)`, `file.readStreaming(io, ...)`, `io.sleep(...)`; the concrete behaviour is determined entirely by which `Io` value was passed in. The same source compiles and runs unchanged whether the backing implementation does blocking syscalls on a thread pool or submits to an `io_uring` ring and parks a stackful fiber.

This is the same "capability passed as a value" intuition that [Eio][ocaml-eio] reaches through OCaml 5 effect handlers, but Zig does it without effects and without a language coroutine transform: the interface is an ordinary struct of function pointers, and concurrency is provided by the implementation rather than by the type system. See [Effects and event loops][effects-and-event-loops] for how these two strategies relate.

### Design philosophy

The module doc comment in [`lib/std/Io.zig`][Io.zig] states the scope plainly: a cross-platform interface abstracting "all I/O operations and concurrency", spanning file system, networking, processes, time/sleeping, randomness, `async`/`await`/`concurrent`/`cancel`, concurrent queues, wait groups and `select`, mutexes/futexes/events/conditions, and memory-mapped files, so that "programmers... write optimal, reusable code while participating in these operations."

Three properties fall out of that decision:

1. **No function coloring.** Async-ness is not in a function's type. A function that takes an `Io` parameter can be driven synchronously or asynchronously; the caller decides by choosing an `Io` implementation. There is no `async fn` versus `fn` split.
2. **Devirtualization when monomorphic.** The vtable cost is real, but a documented side effect of the supporting language work (proposal #23367) is guaranteed devirtualization when a program links exactly one `Io` implementation -- the indirect calls collapse to direct calls, even in debug builds.
3. **Backend pluralism.** The standard library ships several implementations behind the one interface, each tuned to a platform, and selects `Io.Evented` automatically per OS while keeping `Io.Threaded` available everywhere.

> **Status (June 2026).** `std.Io` is the headline feature of the in-development Zig 0.16.0. The threaded backend is, per the [0.16.0 release notes][Zig 0.16.0 Release Notes], "feature-complete and well-tested, including Cancelation". `Io.Evented` (and its `Io.Uring`, `Io.Kqueue`, `Io.Dispatch` members) is explicitly "work-in-progress, experimental, serving to inform the evolution of the interface", with the `io_uring` and kqueue backends labelled "proof-of-concept". Andrew Kelley's [text write-up][Zig's New Async I/O (Andrew Kelley)] (2025-10-29) calls the API "a preview" and warns "these APIs are not set in stone." The non-async half -- the `Reader`/`Writer` rework -- shipped earlier, in Zig 0.15.1 (the "Writergate" change). Treat every type and function name below as accurate to the 0.16.0 development tree but subject to churn.

---

## Core abstractions and types

### The `Io` value

From [`lib/std/Io.zig`][Io.zig] (line 25):

```zig
const Io = @This();

userdata: ?*anyopaque,
vtable: *const VTable,
```

That is the whole interface as seen by callers: an opaque `userdata` (the implementation's state -- a `*Threaded`, a `*Uring.Evented`, etc.) and a pointer to a shared `VTable`. Methods on `Io` and on its helper types (`File`, `Dir`, `net.Socket`, `Clock`, `Mutex`, ...) are thin wrappers that forward to `io.vtable.<op>(io.userdata, ...)`.

### Backend selection

`Io.zig` wires the platform default at comptime (lines 28-39):

```zig
pub const Threaded = @import("Io/Threaded.zig");

pub const fiber = @import("Io/fiber.zig");
pub const Evented = if (fiber.supported) switch (builtin.os.tag) {
    .linux => Uring,
    .dragonfly, .freebsd, .netbsd, .openbsd => Kqueue,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => Dispatch,
    else => void,
} else void; // context-switching code not implemented yet
pub const Dispatch = @import("Io/Dispatch.zig");
pub const Kqueue = @import("Io/Kqueue.zig");
pub const Uring = @import("Io/Uring.zig");
```

A program constructs the implementation it wants, then calls its `.io()` method to obtain the `Io` value. `Io.Threaded` is always available; `Io.Evented` resolves to the OS-appropriate evented backend, or to `void` where stackful fibers are unsupported (`fiber.supported` is true only on `aarch64`, `riscv64`, and `x86_64`).

### The `VTable`

`VTable` (line 51) is a large flat struct of function pointers. The concurrency primitives form the minimal required core; the rest are the "operate surface" for the file system, networking, processes, time, and randomness. The concurrency core:

| Group             | VTable fields                                                       | Purpose                                                                |
| ----------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Task lifecycle    | `async`, `concurrent`, `await`, `cancel`                            | Spawn a task (eager or guaranteed-concurrent), join it, or cancel+join |
| Groups            | `groupAsync`, `groupConcurrent`, `groupAwait`, `groupCancel`        | Structured sets of tasks awaited/cancelled as a whole                  |
| Cancellation      | `recancel`, `swapCancelProtection`, `checkCancel`                   | Re-arm, block, and poll cancellation                                   |
| Futex             | `futexWait`, `futexWaitUncancelable`, `futexWake`                   | Primitive blocking/wakeup for building `Mutex`, `Condition`, `Event`   |
| Operation surface | `operate`, `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel` | Submit one or many low-level `Operation`s                              |
| File / Dir / net  | `dir*`, `file*`, `net*`, `process*`, `now`/`sleep`, `random*`       | The concrete syscall-shaped operations                                 |

The `async` field is documented as returning `null` "if `result` has been already populated and `await` will be a no-op" -- the **eager-result optimization**. Its signature carries the result buffer, the context buffer, and a type-erased `start` thunk (lines 58-70):

```zig
async: *const fn (
    userdata: ?*anyopaque,
    /// The pointer of this slice is an "eager" result value.
    /// The length is the size in bytes of the result type.
    result: []u8,
    result_alignment: std.mem.Alignment,
    /// Copied and then passed to `start`.
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*AnyFuture,
```

`concurrent` is the same shape but returns `ConcurrentError!*AnyFuture` -- it may fail with `error.ConcurrencyUnavailable`. That single difference encodes the whole design: `async` is infallible and may run the work inline (eagerly, on the current stack), whereas `concurrent` guarantees the work proceeds independently of the caller.

### `AnyFuture` and `Future(T)`

`AnyFuture` is an opaque handle (line 1191). The typed wrapper `Future(Result)` (line 1193) stores `any_future: ?*AnyFuture` plus an inline `result: Result`. The eager case is visible in `await` and `cancel`: if `any_future` is `null`, the result is already present and the call is a no-op.

```zig
pub fn await(f: *@This(), io: Io) Result {
    const any_future = f.any_future orelse return f.result;
    io.vtable.await(io.userdata, any_future, @ptrCast(&f.result), .of(Result));
    f.any_future = null;
    return f.result;
}
```

### `Group`, `Select`, `Batch`

- **`Group`** (line 1235) -- "An unordered set of tasks which can only be awaited or canceled as a whole." Resources for each task are released when that task returns, so a long-lived group that tasks are repeatedly added to is not a leak. Its state is just `token: std.atomic.Value(?*anyopaque)` plus an implementation-private `state: usize`; a `null` token means no pending work, so `await`/`cancel` short-circuit.
- **`Select(U)`** (line 1393) -- the task-level wait-for-first primitive. `U` is a tagged union whose fields name the possible result types; `select.async(.field, fn, args)` / `select.concurrent(...)` spawn tasks, and `await()` returns the first `U` produced. It is built on a `Group` plus a `Queue(U)`.
- **`Batch`** (line 484) -- the low-level counterpart that operates on `Operation` rather than tasks. A caller pre-allocates `[]Operation.Storage`, `add`s operations, then `awaitAsync` (concurrency optional) or `awaitConcurrent` (concurrency required, can time out) and iterates completions with `next()`. This is the portable way to express "submit N reads, wake on the first completion" and maps directly onto an `io_uring` submission batch.

### The `Operation` surface

`Operation` (line 248) is a tagged union of the low-level, syscall-shaped requests the implementation knows how to perform:

```zig
pub const Operation = union(enum) {
    file_read_streaming: FileReadStreaming,
    file_write_streaming: FileWriteStreaming,
    device_io_control: DeviceIoControl,
    net_receive: NetReceive,
    net_read: NetRead,
    ...
};
```

`Io.operate` (line 462) performs one synchronously (with respect to the caller's logical thread of control); `Io.operateTimeout` wraps a single op in a one-element `Batch` and awaits it concurrently with a timeout. Each variant carries its own `Error` set and a `Result` type, and the union's `Result` is computed at comptime by mapping each field to its `.Result`.

### `Cancelable`, `CancelProtection`, `Timeout`

- `Cancelable = error{Canceled}` (line 721) is the marker error returned at cancellation points.
- `CancelProtection` (line 1348) is a `u1` enum -- `unblocked` (default; any cancelable `Io` call is a cancellation point) or `blocked` (no `Io` call introduces a cancellation point). `swapCancelProtection` installs a new state and returns the old one, the idiom being a `defer` to restore it.
- `Timeout` (line 1149) is a union of a relative `Duration` or an absolute `Clock.Timestamp` deadline, feeding `sleep`, `futexWaitTimeout`, and `operateTimeout`.

---

## How it works

### The async/await contract

The free function `Io.async` (line 2407) type-erases the user function into a `start` thunk that calls it and stores its return value into the result pointer, then forwards to the vtable:

```zig
pub fn async(io: Io, function: anytype, args: ...) Future(Result) {
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @ptrCast(@alignCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = io.vtable.async(
        io.userdata, @ptrCast(&future.result), .of(Result),
        @ptrCast(&args), .of(Args), TypeErased.start,
    );
    return future;
}
```

`Io.concurrent` (line 2446) is identical except it returns `ConcurrentError!Future(...)` and calls `vtable.concurrent`. Its doc comment is the crux of the whole design:

> This has stronger guarantee than `async`, placing restrictions on what kind of `Io` implementations are supported. By calling `async` instead, one allows, for example, stackful single-threaded blocking I/O.

So `async` is the portable choice (it always works, even on a backend with no real concurrency, by running the task inline); `concurrent` is the choice you make when correctness _requires_ overlap (e.g. two halves of a deadlock-prone protocol) and you are willing to receive `error.ConcurrencyUnavailable`.

### Cancellation model

Cancellation is cooperative and edge-triggered. `Future.cancel` requests cancellation and then awaits, causing the task to receive `error.Canceled` from its **next** cancellation point -- "a call to a function in `Io` which can return `error.Canceled`." Crucially (line 1202): "only the next cancellation point in that task will return `error.Canceled`: future points will not re-signal the cancellation. As such, it is usually a bug to ignore `error.Canceled`." `recancel` (line 1336) re-arms the request after a deliberately handled cancellation; `checkCancel` (line 1382) is a pure cancellation point for long CPU-bound loops; `swapCancelProtection` brackets a region that must finish before observing cancellation. This mirrors the structured cancellation of [Eio's `Switch`][ocaml-eio] and [Tokio's][tokio] cancellation tokens, but is expressed as a per-task one-shot flag rather than a propagating exception.

### Threaded backend: thread pool + blocking syscalls

[`lib/std/Io/Threaded.zig`][Threaded.zig] is the universal, feature-complete implementation. Its state is a classic worker pool: an `allocator`, a `Mutex`/`Condition`, a `run_queue`, an `async_limit`/`concurrent_limit`, and an atomic `worker_threads` list. Tasks become closures placed on the run queue and picked up by worker threads that perform ordinary **blocking** syscalls (`preadv`/`pwritev` and friends, with `nonblocking` flags handled for sockets).

The eager-result path is what lets the threaded backend honor the "stackful single-threaded blocking I/O" allowance. `Threaded.async` (line 2070) runs the work inline whenever it cannot or need not spawn:

```zig
fn async(userdata, result, ..., start) ?*Io.AnyFuture {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    if (builtin.single_threaded) {
        start(context.ptr, result.ptr);  // run now, return null future
        return null;
    }
    ...
    if (busy_count >= @intFromEnum(t.async_limit)) {
        // pool saturated: run inline rather than queue
        start(context.ptr, result.ptr);
        return null;
    }
    ...
}
```

`Threaded.concurrent` (line 2126) makes no such concession: under `builtin.single_threaded` it returns `error.ConcurrencyUnavailable` immediately, and it never runs the task inline. This is precisely the contract from `Io.concurrent`'s doc comment, realized in one backend.

### Uring backend: io_uring + stackful fibers

[`lib/std/Io/Uring.zig`][Uring.zig] (internally named `Evented`) is the Linux evented implementation. It combines an `io_uring` instance **per worker thread** with **stackful fibers** for the M:N scheduling, so blocking-looking code suspends a fiber instead of a thread.

**Ring setup.** `init` (line 813) creates the main thread's ring with two flags (line 893):

```zig
.io_uring = try .init(
    @as(u16, 1) << ev.log2_ring_entries,
    linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER,
),
```

`IORING_SETUP_COOP_TASKRUN` (kernel **5.19+**, [io_uring_setup(2)][io_uring_setup man]) tells the kernel not to forcibly IPI-interrupt the issuing task to run completions -- they are processed at the next kernel/user transition, which is exactly what a cooperative fiber scheduler wants. `IORING_SETUP_SINGLE_ISSUER` (kernel **6.0+**) promises only one task submits to each ring, which is true here because each ring is owned by exactly one worker thread; the kernel enforces this with `-EEXIST`. The default ring depth is `1 << log2_ring_entries` with `log2_ring_entries = 3` (8 entries).

**Fibers.** [`lib/std/Io/fiber.zig`][fiber.zig] is the stackful-coroutine machinery: a `Context` (saved `sp`/`fp`/`pc`, named `rsp`/`rbp`/`rip` on x86-64) and a hand-written `contextSwitch` in inline assembly for `aarch64`, `riscv64`, and `x86_64`, clobbering essentially the entire register file so the switch is a full CPU-state save/restore. A `Fiber` (Uring.zig line 149) holds its `context`, an `awaiter`/`group` link, a status union, and a `cancel_status`/`cancel_protection`. Each worker `Thread` (line 94) has its own `io_uring`, an `idle_context`, and `ready_queue`/`free_queue`, plus work-stealing search indices -- it can steal ready fibers and free fiber stacks from sibling threads.

**Submission/completion flow.** This is the heart of the backend, and it is uniform across every operation. To do a read, `preadv` (line 5683) parks the fiber on the ring, fills one SQE tagged with the fiber pointer as `user_data`, yields, and on resume reads the completion:

```zig
fn preadv(ev, cancel_region, fd, iov, offset) File.Reader.Error!usize {
    const gather = iov.len > 1 or iov[0].len > 0xfffff000;
    while (true) {
        const thread = try cancel_region.awaitIoUring();
        thread.enqueue().* = .{
            .opcode = if (gather) .READV else .READ,
            .fd = fd,
            .off = offset orelse std.math.maxInt(u64),
            .addr = if (gather) @intFromPtr(iov.ptr) else @intFromPtr(iov[0].base),
            .len = @intCast(if (gather) iov.len else iov[0].len),
            .user_data = @intFromPtr(cancel_region.fiber),  // <-- fiber is the token
            ...
        };
        ev.yield(null, .nothing);              // suspend this fiber
        const completion = cancel_region.completion();
        switch (completion.errno()) {
            .SUCCESS => return @bitCast(completion.result),
            .INTR, .CANCELED => {},            // retry loop
            ...
        }
    }
}
```

`ev.yield` (line 963) does a fiber context switch to the next ready fiber, or to the thread's `idle_context`. The idle loop `idle` (line 1146) is the reactor: it `submit_and_wait(1)`s the ring, drains CQEs with `copy_cqes`, and for each completion recovers the parked fiber from the low bits of `cqe.user_data`, writes the result into the fiber's result slot, and re-queues it as ready (lines 1188-1196):

```zig
0b00 => {
    const ready_fiber: *Fiber = @ptrFromInt(cqe.user_data & ~@as(usize, 0b11));
    ready_fiber.resultPointer(Completion).* = .{ .result = cqe.res, .flags = cqe.flags };
    break :ready_fiber ready_fiber;
},
```

The two low bits of `user_data` are a discriminator: `0b00` = a fiber to resume, `0b01` = an async-cancel follow-up, `0b10` = a `Batch` completion, `0b11` = a timeout. This is how one ring multiplexes single-op fibers, batched ops, cancellations, and timers without separate bookkeeping.

**Opcodes used.** The Uring backend issues a broad set of `io_uring` opcodes directly, including `READ`/`READV`, `WRITE`/`WRITEV`, `FSYNC`, `FTRUNCATE`, `STATX`, `OPENAT`, `CLOSE`, `MKDIRAT`, `UNLINKAT`, `SYMLINKAT`, `LINKAT`, `RENAMEAT`, `SOCKET`, `BIND`, `SHUTDOWN`, `RECVMSG`, `TIMEOUT`/`TIMEOUT_REMOVE`/`LINK_TIMEOUT`, `FUTEX_WAIT`/`FUTEX_WAKE`, `ASYNC_CANCEL`, `MSG_RING`, `URING_CMD`, `WAITID`, and `NOP`. (Some path operations that have no `io_uring` opcode -- e.g. `readlink`, which the kernel never exposed as an `IORING_OP` -- fall back to a direct syscall such as `readlinkat`.) Notably `FUTEX_WAIT`/`FUTEX_WAKE` (line 1961+) mean the `Io.Mutex`/`Condition`/`Event` primitives ride the ring too, and `MSG_RING` is how one worker wakes a fiber owned by another thread's ring.

**Fallback path.** Several `net*` vtable slots in `Uring.io()` (lines 774-788) are wired to `*Unavailable` stubs -- `netListenIpUnavailable`, `netAcceptUnavailable`, `netConnectIpUnavailable`, `netSendUnavailable`, `netWriteUnavailable`, `netLookupUnavailable`, etc. -- while `netBindIp`, `netClose`, `netShutdown` and the file ops are implemented. This is the "proof-of-concept" caveat made concrete: the `io_uring` backend does not yet cover the full networking surface, and `net_read` `operate` returns `error.NetworkDown` with a `// TODO`. Production code that needs the missing operations runs on `Io.Threaded`, which implements them with blocking syscalls. The eager-`async` design is what makes that substitution invisible to callers.

There is also a coarser fallback at task-spawn granularity: `Uring.async` (line 1428) is literally `concurrent(...) catch { start(...); return null; }` -- if it cannot create a fiber (out of memory), it runs the work inline and returns a null future, exactly like the threaded backend.

### Kqueue and Dispatch backends

- **[`Io/Kqueue.zig`][Kqueue.zig]** is the BSD evented backend (DragonFly, FreeBSD, NetBSD, OpenBSD). Same fiber machinery as Uring, but the reactor is a per-thread `kq_fd` and a `kevent` change/event buffer; multiple fibers waiting on the same `(ident, filter)` share one kevent via a `wait_queues` map. It is marked proof-of-concept.
- **[`Io/Dispatch.zig`][Dispatch.zig]** (internally `Evented`) targets Apple platforms by layering the fibers on top of **Grand Central Dispatch**: it holds a `dispatch.queue_t`, a `dispatch.semaphore_t` for exit, a small main-loop stack, and a `futexes` table. Work is dispatched onto GCD queues rather than a hand-rolled thread pool, while the fiber context switch still provides the "blocking-looking suspension" semantics.

### The Reader/Writer rework

`std.Io.Reader` and `std.Io.Writer` were redesigned in Zig 0.15.1 (the change nicknamed "Writergate") and are part of the same `std.Io` surface. The pivotal structural decision, visible in [`Io/Reader.zig`][Reader.zig] and [`Io/Writer.zig`][Writer.zig], is that **the buffer lives in the interface, above the vtable**:

```zig
// Io/Writer.zig
vtable: *const VTable,
/// If this has length zero, the writer is unbuffered, and `flush` is a no-op.
buffer: []u8,
end: usize = 0,
```

Because `buffer` is a concrete field of the non-generic interface, the hot path (append into `buffer`) is a direct memory operation; the vtable's `drain`/`stream` callbacks fire only when the buffer fills or on an explicit `flush`. This keeps the types transparent to optimization despite being non-generic, and makes buffered I/O the default -- at the cost of requiring callers to supply a buffer and remember to `flush`. `File.reader(io, buffer)` / `File.writer(io, buffer)` ([`Io/File.zig`][File.zig], lines 563/597) bind a file plus an `Io` plus a buffer into these interfaces, so reads and writes flow through whichever backend the `Io` carries -- the file Reader/Writer is itself `Io`-parameterized.

---

## Performance approach

- **Devirtualization for the common case.** A single-implementation program pays no virtual-call overhead after the supporting language work; the indirect calls become direct.
- **Buffer-in-interface Reader/Writer.** The redesign exists "in the name of performance and reducing unneeded copies": the buffered hot path never touches the vtable.
- **`io_uring` batching and cooperative completions.** The Uring backend submits via SQEs and reaps via `copy_cqes` in bulk; `IORING_SETUP_COOP_TASKRUN` and `IORING_SETUP_SINGLE_ISSUER` shave IPIs and enable kernel-side single-issuer optimizations. The `Batch` API lets callers submit many ops and wake on first completion without per-op thread overhead.
- **Stackful fibers over OS threads on the evented backends.** Suspending an I/O-bound task is a register-file context switch within a worker thread, not an OS thread park; work-stealing of ready fibers and free stacks balances load across cores.
- **Eager inline execution.** When concurrency is unavailable or unnecessary, `async` runs the closure on the current stack, avoiding allocation and scheduling entirely -- the null-future fast path.
- **`@nogc`-friendly, allocator-explicit.** Backends take a backing allocator explicitly; the threaded pool grows lazily and the Uring backend pre-reserves thread/stack storage in one aligned allocation.

---

## Strengths

- **No function coloring.** I/O code is colorless; the same function works synchronously or asynchronously depending only on the `Io` passed in.
- **One interface, many execution models.** Blocking thread pool, `io_uring`, kqueue, and GCD all sit behind the identical surface; choosing is a construction-site decision.
- **Explicit capability passing.** Like [Eio][ocaml-eio], dependence on I/O is visible in signatures and trivially mockable (`Io.failing` provides a vtable whose every op is `unreachable`/`error`, useful for asserting code performs no I/O).
- **Structured concurrency built in.** `Group`, `Select`, and integrated `Cancelable` cancellation give scoped task lifetimes and first-completion waiting without external libraries.
- **Low-level and high-level layers.** `Operation`/`Batch` for ring-shaped control; `async`/`concurrent`/`Future`/`Group`/`Select` for task-shaped control.
- **Devirtualization keeps the abstraction cheap** when a program is monomorphic in its `Io`.

## Weaknesses

- **In development and explicitly unstable.** The async half targets unreleased 0.16.0; the authors say the APIs "are not set in stone." Names and shapes will change.
- **Evented backends are proof-of-concept.** `Io.Uring`, `Io.Kqueue`, and `Io.Dispatch` are experimental; the Uring backend's networking surface is largely `*Unavailable` stubs and `net_read` is a TODO. Only `Io.Threaded` is feature-complete.
- **Fibers are arch-limited.** `fiber.supported` covers only `aarch64`/`riscv64`/`x86_64`; elsewhere `Io.Evented` is `void` and you fall back to threads.
- **Verbosity of capability passing.** Every I/O function grows an `io: Io` parameter -- the same threading-through cost [Eio][ocaml-eio] pays.
- **Manual buffer/flush discipline.** The Reader/Writer rework makes buffering the default; forgetting `flush()` silently drops output, a documented sharp edge of "Writergate".
- **Cancellation is a footgun if ignored.** Because a cancellation is delivered once, swallowing `error.Canceled` without `recancel` can hang a task.
- **Runtime vtable cost when polymorphic.** Programs that genuinely mix multiple `Io` implementations forgo devirtualization.

---

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                                                | Trade-off                                                                                       |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `Io` as an explicit value (`userdata + *const VTable`)   | Kills function coloring; one source compiles for blocking or evented; testable/mockable                  | Every I/O API gains an `io` parameter; runtime vtable cost unless devirtualized                 |
| Non-generic vtable + comptime devirtualization (#23367)  | Avoids generic code bloat while reclaiming direct-call speed for single-implementation programs          | Polymorphic-`Io` programs keep the indirect-call cost                                           |
| `async` infallible + eager, `concurrent` fallible        | `async` is portable to blocking/single-threaded backends; `concurrent` states a real overlap need        | Callers must choose correctly; `concurrent` can return `error.ConcurrencyUnavailable`           |
| Eager-result null future                                 | Lets a backend run a task inline (no alloc/schedule) when concurrency is unavailable or pointless        | `async` gives no concurrency guarantee; reasoning about ordering needs care                     |
| Stackful fibers on evented backends                      | Blocking-looking direct-style code with cheap intra-thread suspension; no compiler coroutine transform   | Hand-written context switch per arch; only `aarch64`/`riscv64`/`x86_64`; per-fiber stack memory |
| Per-thread `io_uring` + `SINGLE_ISSUER`/`COOP_TASKRUN`   | Single-issuer kernel optimizations; cooperative completions avoid IPIs; cross-thread wake via `MSG_RING` | Requires Linux 6.0 for `SINGLE_ISSUER` (5.19 for `COOP_TASKRUN`); ring-per-thread memory        |
| Backend-specific `*Unavailable` stubs (Uring net)        | Ship the working subset now; defer hard ops; let callers use `Io.Threaded` for the rest                  | Surprising runtime errors if you assume full coverage on the evented backend                    |
| One-shot, edge-triggered cancellation (`error.Canceled`) | Cheap per-task flag; explicit `recancel`/`CancelProtection` for control                                  | Ignoring `error.Canceled` can hang; differs from propagating-exception models                   |
| Buffer-in-interface Reader/Writer ("Writergate")         | Direct hot path, fewer copies, buffered-by-default, transparent to optimization despite non-generic      | Caller-managed buffers; missing `flush()` drops output                                          |

---

## Sources

- [ziglang/zig] -- the Zig compiler and standard library (source of all type/function references below)
- [`lib/std/Io.zig`][Io.zig] -- `Io`, `VTable`, `Operation`, `Batch`, `Future`, `Group`, `Select`, `async`/`concurrent`/`await`/`cancel`, cancellation, futex
- [`lib/std/Io/Uring.zig`][Uring.zig] -- `io_uring` + fibers backend: ring setup, idle reactor, `preadv`/`pwritev`, opcode usage, net `*Unavailable` stubs
- [`lib/std/Io/Threaded.zig`][Threaded.zig] -- thread-pool + blocking-syscall backend; eager-inline `async`, fallible `concurrent`
- [`lib/std/Io/fiber.zig`][fiber.zig] -- stackful-coroutine `Context` and `contextSwitch` assembly
- [`lib/std/Io/Kqueue.zig`][Kqueue.zig] / [`lib/std/Io/Dispatch.zig`][Dispatch.zig] -- BSD kqueue and macOS GCD backends
- [`lib/std/Io/Reader.zig`][Reader.zig] / [`lib/std/Io/Writer.zig`][Writer.zig] / [`lib/std/Io/File.zig`][File.zig] -- buffer-in-interface Reader/Writer rework
- [Zig 0.16.0 Release Notes] -- `std.Io` overview; Threaded "feature-complete", Evented/Uring/Kqueue/Dispatch "experimental"/"proof-of-concept"
- [Zig 0.15.1 Release Notes] -- the Reader/Writer ("Writergate") rework
- [Zig's New Async I/O (Andrew Kelley)] -- text write-up of the design (2025-10-29); "preview", `async`/`concurrent`/`cancel`
- [Loris Cro: Zig's New Async I/O] -- companion blog: vtable, devirtualization (#23367), backend pluralism
- [io_uring_setup(2)][io_uring_setup man] -- `IORING_SETUP_COOP_TASKRUN` (5.19+), `IORING_SETUP_SINGLE_ISSUER` (6.0+)

Related siblings in this survey: the [io_uring overview][io-uring-index] and [io_uring features/opcodes][io-uring-features]; [Tokio][tokio] (Rust reactor + work-stealing), [Glommio][glommio] and [Monoio][monoio] (thread-per-core `io_uring`), [libuv][libuv] (the C event-loop baseline); the effect-based counterpart [Eio][ocaml-eio]; the cross-cutting [primitives][primitives], [techniques][techniques], [effects and event loops][effects-and-event-loops], and the [D landscape][d-landscape] for how this informs Sparkles.

<!-- References -->

[ziglang/zig]: https://codeberg.org/ziglang/zig
[Io.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io.zig
[Uring.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Uring.zig
[Threaded.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Threaded.zig
[fiber.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/fiber.zig
[Kqueue.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Kqueue.zig
[Dispatch.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Dispatch.zig
[Reader.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Reader.zig
[Writer.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/Writer.zig
[File.zig]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/Io/File.zig
[Zig 0.16.0 Release Notes]: https://ziglang.org/download/0.16.0/release-notes.html
[Zig 0.15.1 Release Notes]: https://ziglang.org/download/0.15.1/release-notes.html
[Zig's New Async I/O (Andrew Kelley)]: https://andrewkelley.me/post/zig-new-async-io-text-version.html
[Loris Cro: Zig's New Async I/O]: https://kristoff.it/blog/zig-new-async-io/
[io_uring_setup man]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[ocaml-eio]: ../algebraic-effects/ocaml-eio.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[libuv]: ./libuv.md
[io-uring-index]: ./io-uring/index.md
[io-uring-features]: ./io-uring/features.md
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[d-landscape]: ./d-landscape.md
