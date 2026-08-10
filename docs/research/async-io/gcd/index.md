# Grand Central Dispatch / libdispatch (macOS, Darwin)

The concurrency substrate macOS actually runs on: a user-space queue library whose thread pool, event demultiplexer and priority model all live in the kernel — so the "event loop" is a kernel-delivered upcall onto a thread the process never created.

| Field         | Value                                                                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | C (with Objective-C, C++, Swift and blocks surfaces)                                                                                                   |
| License       | Apache 2.0 with the LLVM runtime exception ([`LICENSE`][sc-license])                                                                                   |
| Repository    | [`swiftlang/swift-corelibs-libdispatch`][sc-repo] (the Apple-authored portable tree) · [`apple-oss-distributions/libdispatch`][apple-oss]              |
| Documentation | [`dispatch(3)`][man-dispatch] · [Dispatch (Apple Developer)][apple-dispatch]                                                                           |
| Key authors   | Apple Inc. (Dave Zarzycki, Daniel A. Steffen, Pierre Habouzit and contributors)                                                                        |
| Pattern       | Queue-and-handler; hierarchical serial/concurrent lanes over a kernel-managed pool                                                                     |
| Encoding      | **Reactor** over kqueue, with the loop inverted — the kernel delivers kevents directly onto workqueue threads (`kevent_qos`/`kevent_id`)               |
| First shipped | Mac OS X 10.6 "Snow Leopard" (2009); open-sourced the same year; ported to Linux/Windows for Swift 3 (2016); `dispatch_workloop` public in macOS 10.14 |

> **Platform.** Darwin (macOS, iOS, tvOS, watchOS) is the native target and the only one where the kernel half exists. `swift-corelibs-libdispatch` builds the same source on Linux (epoll + a user-space thread-pool monitor) and Windows (a bespoke backend) — see [Portability](#portability-the-same-source-without-the-kernel-half). This page is read against the tree at [`f92e811`][sc-tree], cross-checked against the macOS 14.4 SDK headers and measured on macOS 26.6 / Apple M4 Max.

> [!IMPORTANT]
> Six standalone D programs in `examples/` back the claims below. They are macOS-gated (`platforms "osx"`) and run on the macOS leg of `ci --example-files`, so a behavioural claim on this page that stops holding turns CI red. Each asserts its invariant rather than merely printing it.

---

## Overview

### What it solves

Every other system in this survey is a library you link and a loop you run. GCD is neither: it is the **process-wide concurrency service** on Darwin, and by 2009 Apple had concluded that asking each application to size its own thread pool was the wrong layer to solve the problem at. From the project's own README ([`README.md`][sc-readme]):

> _"libdispatch on Darwin is a combination of logic in the `xnu` kernel alongside the user-space Library. The kernel has the most information available to balance workload across the entire system."_

That sentence is the whole design. An application expresses work as _items submitted to queues_, annotates them with a _quality-of-service class_, and never states how many threads it wants. The kernel's workqueue subsystem then decides how many threads to give the process, at which priority, and — crucially — makes that decision with knowledge no single process has: thermal state, other processes' demands, and which cores are performance versus efficiency cores.

The second thing it solves is **the loop itself**. A conventional reactor ([libuv][libuv], [Go][go], [.NET][dotnet]) owns a thread that sits in `epoll_wait`/`kevent` and dispatches callbacks from there. GCD inverts this: `_pthread_workqueue_init_with_workloop` hands the kernel three function pointers, and the kernel calls _up_ into the process with a batch of kevents already in hand, on a thread it materialised for the purpose. There is no loop thread to own, and in the common configuration no manager thread either.

### Design philosophy

Three convictions, all visible in the source:

1. **A queue is not a thread.** The `dispatch_queue_create` man page is explicit that _"Queues are not bound to any specific thread of execution and blocks submitted to independent queues may execute concurrently"_ ([`dispatch_queue_create(3)`][man-queue-create]). A queue you create owns no thread, no run loop and no state beyond a lock-free intrusive list plus a 64-bit atomic word; it borrows execution from whatever is below it in the [target-queue hierarchy](#target-queues-the-hierarchy-is-the-design).

2. **Priority is a property of work, not of threads.** Work carries a QoS class; threads acquire the QoS of the work they run and are re-prioritised when a higher-QoS waiter arrives (`_dispatch_wqthread_override_start`). Priority inversion is handled by _boosting the owner_, not by the caller spinning.

3. **Mutual exclusion should be scheduling, not blocking.** The recommended replacement for a mutex is a serial queue: instead of parking a thread on a lock, the work is enqueued on a lane that runs one item at a time. [`target-queue-funnel.d`](./examples/target-queue-funnel.d) demonstrates the composed form — three independent lanes retargeted onto one, converting concurrency into serialisation with no lock anywhere:

   ```text
   three independent serial queues: peak concurrency = 2, counter = 600/600
   the same three, retargeted to one: peak concurrency = 1, counter = 600/600
   ```

Within this survey GCD is the only entry whose scheduler lives in the kernel. Compare it against [libuv][libuv] (the portable single-threaded reactor plus a user-space pool), [Go][go] (an integrated user-space scheduler that also owns its netpoller), and [Zig `std.Io`][zig-io], whose `Dispatch` backend is literally GCD behind Zig's vtable.

---

## Core abstractions and types

| Concept             | Type / function                                                    | Role                                                                                                       |
| ------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Work item           | A block `^{ }` or a `(function, context)` pair                     | The unit submitted; `dispatch_async` vs `dispatch_async_f`                                                 |
| Serial lane         | `dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL)`              | FIFO, one item at a time; the recommended mutex replacement                                                |
| Concurrent lane     | `dispatch_queue_create(label, DISPATCH_QUEUE_CONCURRENT)`          | FIFO dequeue, overlapping execution; supports `dispatch_barrier_async`                                     |
| Root queue          | `dispatch_get_global_queue(qos, flags)`                            | One of twelve static, thread-backed queues (see [below](#root-queues-twelve-of-them-all-static))           |
| Main queue          | `dispatch_get_main_queue()` + `dispatch_main()`                    | The serial queue drained by the process's main thread                                                      |
| Target queue        | `dispatch_set_target_queue(object, queue)`                         | The parent lane an object re-enqueues onto; the composition primitive                                      |
| Workloop            | `dispatch_workloop_create(label)` (macOS 10.14+)                   | A queue that re-evaluates **priority order** between items, not just FIFO                                  |
| Event source        | `dispatch_source_create(type, handle, mask, queue)`                | A kqueue filter registration with a handler attached; see [sources](#dispatch-sources-a-kqueue-vocabulary) |
| Completion tracking | `dispatch_group_create()` / `dispatch_group_wait`                  | Join over a set of submissions                                                                             |
| Counting semaphore  | `dispatch_semaphore_create(n)`                                     | The only blocking primitive in the public API                                                              |
| Data-parallel loop  | `dispatch_apply_f(iterations, queue, ctxt, fn)`                    | Parallel `for`, sized by [QoS-aware parallelism](#dispatch_apply-and-qos-aware-parallelism)                |
| One-time init       | `dispatch_once_f(&pred, ctxt, fn)`                                 | The `pthread_once` replacement, with an inlined fast path                                                  |
| Byte-stream I/O     | `dispatch_io_create(type, fd, queue, cleanup)` + `dispatch_data_t` | Channel-based file/socket I/O; see [file I/O](#file-io-dispatch_io-is-threads-and-pread-not-completions)   |
| Deferred submission | `dispatch_after_f(when, queue, ctxt, fn)`                          | One-shot timer without a source object                                                                     |

### Blocks versus the `_f` API — why a non-Objective-C language can use GCD

Almost every GCD tutorial is written with blocks (`^{ … }`), a Clang extension no other compiler implements. That would make GCD unreachable from D, Zig or plain portable C — except that **every block-taking entry point has a `_f` twin taking a plain C function pointer and a `void *` context**: `dispatch_async_f`, `dispatch_sync_f`, `dispatch_group_async_f`, `dispatch_apply_f`, `dispatch_once_f`, `dispatch_source_set_event_handler_f`, `dispatch_source_set_cancel_handler_f`, `dispatch_after_f`. The block forms are wrappers that `Block_copy` the block and call the `_f` form.

That is why all six examples on this page are ordinary D with `extern (C)` declarations and no shim library — libdispatch lives in `libSystem`, so nothing extra is linked. Two D-specific rules apply, both exercised by [`sync-on-caller-thread.d`](./examples/sync-on-caller-thread.d):

- **Handler threads are not druntime threads.** A workqueue thread was created by the kernel and is unknown to the D garbage collector. A handler must either stay allocation-free or bracket its body with `thread_attachThis()` / `thread_detachThis()`.
- **An exception must never unwind into C.** The `_f` callback types are `nothrow` from D's point of view; the example wraps its body in `try`/`catch (Throwable)` rather than relying on that.

---

## How it works

### The two-body problem: a user library and a kernel workqueue

The single most consequential fact about GCD on Darwin is where the thread pool lives. `_dispatch_root_queues_init_once` ([`src/init.c`][sc-init]) negotiates with the kernel exactly once, and what it registers is a set of **upcall entry points**:

```c
// src/init.c — _dispatch_root_queues_init_once (abridged)
int wq_supported = _pthread_workqueue_supported();

if (unlikely(!_dispatch_kevent_workqueue_enabled)) {
    r = _pthread_workqueue_init(_dispatch_worker_thread2, …);
} else if (wq_supported & WORKQ_FEATURE_WORKLOOP) {
    r = _pthread_workqueue_init_with_workloop(_dispatch_worker_thread2,
            (pthread_workqueue_function_kevent_t)   _dispatch_kevent_worker_thread,
            (pthread_workqueue_function_workloop_t) _dispatch_workloop_worker_thread, …);
} else if (wq_supported & WORKQ_FEATURE_KEVENT) {
    r = _pthread_workqueue_init_with_kevent(_dispatch_worker_thread2,
            (pthread_workqueue_function_kevent_t) _dispatch_kevent_worker_thread, …);
} else {
    DISPATCH_INTERNAL_CRASH(wq_supported, "Missing Kevent WORKQ support");
}
```

Three tiers, probed at runtime and unforgiving at the bottom: a kernel without kevent-workqueue support is a hard crash, not a fallback. The consequences ripple outward:

- **Asking for more concurrency is one syscall.** `_dispatch_root_queue_poke_slow` ([`src/queue.c`][sc-queue]) on Darwin reduces to `_pthread_workqueue_addthreads(remaining, priority)` and returns. Every `pthread_create`, semaphore-mediator and `dgq_thread_pool_size` bookkeeping path in that function is `#if DISPATCH_USE_PTHREAD_POOL` — the non-Darwin arm.
- **Threads arrive holding events.** `_dispatch_kevent_worker_thread(events, nevents)` is called by the kernel with a kevent batch already populated; the thread then merges them (`_dispatch_event_loop_merge`) and drains, and on return hands back a _deferred_ kevent array (`*nevents = ddi.ddi_nevents`) that the kernel re-registers on its behalf. Re-arming costs no extra syscall.
- **In the shipping configuration there is no manager thread at all.** `DISPATCH_USE_MGR_THREAD` is defined as `!DISPATCH_USE_KEVENT_WORKQUEUE || DISPATCH_DEBUG || DISPATCH_PROFILE` ([`src/internal.h`][sc-internal]) — so on a release Darwin build the dedicated `com.apple.libdispatch-manager` thread is compiled out, and its role is played by whichever workqueue thread the kernel elects manager (`_PTHREAD_PRIORITY_EVENT_MANAGER_FLAG`).

### Root queues: twelve of them, all static

`dispatch_get_global_queue` allocates nothing. It indexes `_dispatch_root_queues[]`, a build-time array of `DISPATCH_QOS_NBUCKETS * 2 == 12` entries — six QoS classes each paired with an overcommit twin ([`src/init.c`][sc-init]):

| QoS class          | Root queue label                      | Overcommit twin                                  |
| ------------------ | ------------------------------------- | ------------------------------------------------ |
| `MAINTENANCE`      | `com.apple.root.maintenance-qos`      | `com.apple.root.maintenance-qos.overcommit`      |
| `BACKGROUND`       | `com.apple.root.background-qos`       | `com.apple.root.background-qos.overcommit`       |
| `UTILITY`          | `com.apple.root.utility-qos`          | `com.apple.root.utility-qos.overcommit`          |
| `DEFAULT`          | `com.apple.root.default-qos`          | `com.apple.root.default-qos.overcommit`          |
| `USER_INITIATED`   | `com.apple.root.user-initiated-qos`   | `com.apple.root.user-initiated-qos.overcommit`   |
| `USER_INTERACTIVE` | `com.apple.root.user-interactive-qos` | `com.apple.root.user-interactive-qos.overcommit` |

[`root-queues.d`](./examples/root-queues.d) reads these labels back out of a live libdispatch and asserts the naming, which is the cheapest possible check that the source you are reading is the source that is running:

```text
QoS class                     root queue label
MAINTENANCE (0x05, private)   com.apple.root.maintenance-qos
                              com.apple.root.maintenance-qos.overcommit
QOS_CLASS_BACKGROUND          com.apple.root.background-qos
                              com.apple.root.background-qos.overcommit
…
observed 12 of the 12 root queues (6 QoS classes × 2)
```

`MAINTENANCE` is reachable only by spelling its numeric value: `<sys/qos.h>` declares no `QOS_CLASS_MAINTENANCE`, though libdispatch keeps a root-queue pair for it. The legacy `DISPATCH_QUEUE_PRIORITY_*` integers fold onto the same table through `_dispatch_qos_from_queue_priority`, so `dispatch_get_global_queue(0, 0)` — priority `DEFAULT`, not a `qos_class_t` at all — lands on `com.apple.root.default-qos`.

The **overcommit** distinction is the thread-explosion control. A non-overcommit root queue is kept at roughly the core count; an overcommit one is allowed to exceed it, because its work is expected to block. Which one a created queue targets is decided in `_dispatch_lane_create_with_target` ([`src/queue.c`][sc-queue]), and the comment there is the whole story:

```c
// src/queue.c — _dispatch_lane_create_with_target (abridged)
if (overcommit == _dispatch_queue_attr_overcommit_unspecified) {
    // Serial queues default to overcommit!
    overcommit = dqai.dqai_concurrent ?
            _dispatch_queue_attr_overcommit_disabled :
            _dispatch_queue_attr_overcommit_enabled;
}
```

A serial queue whose item blocks therefore cannot stall the bounded pool — and that same default is why creating hundreds of serial queues and blocking in each of them produces the classic thread explosion in a Darwin process.

Every root queue is declared with `DQF_WIDTH(DISPATCH_QUEUE_WIDTH_POOL)` — width `0xfff`, effectively unbounded — while a serial lane has width 1.

### Queues are lanes: one 64-bit word does all the work

A `dispatch_queue_s` is a two-pointer intrusive MPSC list (`dq_items_head` / `dq_items_tail`) plus `dq_state`, a single 64-bit atomic that encodes suspension, activation, barrier ownership, in-flight width, dirtiness, the enqueued bit and the owning thread. `src/queue_internal.h` documents each field in place; the width field is the interesting one:

```c
/*
 * w:  width (bits 52 - 41)
 *    This encodes how many work items are in flight. Barriers hold `dq_width`
 *    of them while they run. This is encoded as a signed offset with respect,
 *    to full use, where the negative values represent how many available slots
 *    are left, and the positive values how many work items are exceeding our
 *    capacity.
 */
#define DISPATCH_QUEUE_WIDTH_INTERVAL  0x0000020000000000ull
#define DISPATCH_QUEUE_WIDTH_MASK      0x003ffe0000000000ull
```

A **barrier is just an item that takes the full width**, which is why `dispatch_barrier_async` on a concurrent queue and `dispatch_async` on a serial queue (width 1, where every item is a barrier) are the same code path. Enqueue, dequeue, suspend, resume, activate and sync-handoff are all compare-and-swaps on this word; there is no mutex in a dispatch queue.

### Target queues: the hierarchy is the design

`dispatch_set_target_queue(object, queue)` is GCD's composition operator, and nearly every structural idiom is an application of it:

| Idiom                        | Construction                             | Effect                                                     |
| ---------------------------- | ---------------------------------------- | ---------------------------------------------------------- |
| Subsystem mutual exclusion   | N serial lanes → one serial funnel queue | One execution context, no lock, per-lane FIFO preserved    |
| Priority assignment          | lane → a root queue of the desired QoS   | Sets the floor QoS of everything on the lane               |
| Source affinity              | `dispatch_source_create(…, queue)`       | The handler runs on that lane, so handler state is private |
| Bounded concurrency          | lanes → a workloop with a QoS floor      | Priority-ordered execution across lanes                    |
| Suspending a whole subsystem | `dispatch_suspend(funnel)`               | Everything below stops after the current item              |

The chain always bottoms out at a root queue: an object's work is re-enqueued lane by lane down the chain until it reaches something thread-backed. That is why a created queue costs a few hundred bytes and no thread, and why [`target-queue-funnel.d`](./examples/target-queue-funnel.d) can convert three concurrent lanes into one serial context with a single call per lane and no change to the work itself.

### `dispatch_sync` runs on the caller's thread

The man page describes `dispatch_sync` as _"a convenient wrapper around `dispatch_async` with the addition of a semaphore to wait for completion"_ and immediately disclaims it: _"The actual implementation of the `dispatch_sync` function may be optimized and differ from the above description"_ ([`dispatch_async(3)`][man-async]). It differs a great deal.

On the fast path — an idle serial queue — `dispatch_sync_f` acquires the queue's barrier state with a compare-and-swap and invokes the function **inline, on the calling thread** (`_dispatch_lane_barrier_sync_invoke_and_complete`). No thread is woken, no context is allocated, nothing is enqueued. Only if the queue is already busy does `_dispatch_sync_f_slow` ([`src/queue.c`][sc-queue]) build a `dispatch_sync_context_s` waiter carrying the caller's thread id and priority:

```c
// src/queue.c — _dispatch_sync_f_slow (abridged)
struct dispatch_sync_context_s dsc = {
    .dc_flags    = DC_FLAG_SYNC_WAITER | dc_flags,
    .dc_priority = pp | _PTHREAD_PRIORITY_ENFORCE_FLAG,
    .dsc_func    = func,
    .dsc_ctxt    = ctxt,
    .dsc_waiter  = _dispatch_tid_self(),
};
__DISPATCH_WAIT_FOR_QUEUE__(&dsc, dq);
```

`dsc_waiter` is what makes priority inversion tractable: the current owner of the queue can be found and boosted to the waiter's QoS. And the drainer may hand the queue _back_ to the waiter rather than run the item itself, so the block still executes on the waiting thread.

[`sync-on-caller-thread.d`](./examples/sync-on-caller-thread.d) measures the thread identity directly:

```text
dispatch_sync_f  ran on the calling thread: true
dispatch_async_f ran on the calling thread: false
worker thread could allocate after thread_attachThis: true
serial queue completion order:              123450
```

Two practical consequences. `dispatch_sync` onto the queue you are already running on **deadlocks by construction** — the man page calls this out and notes it is _"bug-for-bug compatible"_ with the recursive case through an intermediate queue. And thread-local state is _not_ a safe way to identify "which queue am I on", because a sync'd block runs on a thread that belongs to something else; `dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)` is the supported answer.

### The event loop you never see: `kevent`, and the three shapes of a wait

`src/event/event_kevent.c` is GCD's demultiplexer, and it never calls plain `kevent(2)` on Darwin. `_dispatch_kq_poll` selects one of three kernel interfaces by the _workloop handle_ (`dispatch_wlh_t`) attached to the registration:

```c
// src/event/event_kevent.c — _dispatch_kq_poll (abridged)
if (wlh == DISPATCH_WLH_ANON) {
    if (_dispatch_kevent_workqueue_enabled) flags |= KEVENT_FLAG_WORKQ;
    r = kevent_qos(kqfd, ke, n, ke_out, n_out, buf, avail, flags);
} else {
    flags |= KEVENT_FLAG_WORKLOOP;
    if (!(flags & KEVENT_FLAG_ERROR_EVENTS))
        flags |= KEVENT_FLAG_DYNAMIC_KQ_MUST_EXIST;
    r = kevent_id((uintptr_t)wlh, ke, n, ke_out, n_out, buf, avail, flags);
}
```

| Interface                            | Handle                  | Who waits                                     | Used for                                   |
| ------------------------------------ | ----------------------- | --------------------------------------------- | ------------------------------------------ |
| `kevent(2)`                          | a real `kqueue()` fd    | libdispatch's own manager thread              | Debug/profile builds; non-Darwin           |
| `kevent_qos` + `KEVENT_FLAG_WORKQ`   | `DISPATCH_WLH_ANON`     | the kernel, on the process-wide workqueue     | Everything targeting a global root queue   |
| `kevent_id` + `KEVENT_FLAG_WORKLOOP` | a `dispatch_workloop_t` | the kernel, on that workloop's dynamic kqueue | Sources bound to a workloop (macOS 10.13+) |

The third row is the one with no analogue anywhere else in this survey. A **kqworkloop** is a kernel object that is simultaneously a kqueue _and_ a scheduling context: events registered against it are delivered to a thread the kernel creates for that workloop, at the workloop's QoS, with the kernel maintaining the priority ordering. `dispatch_workloop_create` (public since macOS 10.14, [`dispatch/workloop.h`][sdk-workloop]) exposes it:

> _"Between each workitem invocation, the workloop will evaluate whether higher priority workitems have since been submitted and execute these first. Serial queues targeting a workloop maintain FIFO execution of their workitems. However, the workloop may reorder workitems submitted to independent serial queues targeting it with respect to each other, based on their priorities."_ — [`private/workloop_private.h`][sc-workloop]

Note also what `_dispatch_kq_poll` does with errors: `EBADF` is `DISPATCH_CLIENT_CRASH(err, "Do not close random Unix descriptors")`. GCD treats a descriptor closed out from under a source as a programmer error worth aborting the process over, not a condition to report.

### Dispatch sources: a kqueue vocabulary with the loop removed

A `dispatch_source_t` is a kevent registration with a handler and a target queue. The descriptor tables in [`src/event/event.c`][sc-event] make the correspondence exact — `_dispatch_source_type_read` is nothing but a kqueue filter plus flags:

```c
// src/event/event.c
const dispatch_source_type_s _dispatch_source_type_read = {
    .dst_kind       = "read",
    .dst_filter     = EVFILT_READ,
    .dst_flags      = EV_UDATA_SPECIFIC|EV_DISPATCH|EV_VANISHED,
    .dst_fflags     = NOTE_LOWAT,
    .dst_data       = 1,
    .dst_action     = DISPATCH_UNOTE_ACTION_SOURCE_SET_DATA,
    .dst_create     = _dispatch_unote_create_with_fd,
    .dst_merge_evt  = _dispatch_source_merge_evt,
};
```

| Source type                                          | kqueue filter                                     | `dispatch_source_get_data()` means                           |
| ---------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------ |
| `DISPATCH_SOURCE_TYPE_READ` / `_WRITE`               | `EVFILT_READ` / `EVFILT_WRITE`                    | bytes readable / space writable                              |
| `DISPATCH_SOURCE_TYPE_SIGNAL`                        | `EVFILT_SIGNAL`                                   | number of deliveries since the last handler run              |
| `DISPATCH_SOURCE_TYPE_PROC`                          | `EVFILT_PROC`                                     | the `DISPATCH_PROC_*` mask that fired (`EXIT`, `FORK`, …)    |
| `DISPATCH_SOURCE_TYPE_VNODE`                         | `EVFILT_VNODE`                                    | the `DISPATCH_VNODE_*` mask (`WRITE`, `DELETE`, `RENAME`, …) |
| `DISPATCH_SOURCE_TYPE_TIMER`                         | `DISPATCH_EVFILT_TIMER` → a heaped `EVFILT_TIMER` | number of intervals missed                                   |
| `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`                | `EVFILT_MEMORYSTATUS`                             | the pressure level                                           |
| `DISPATCH_SOURCE_TYPE_MACH_SEND` / `_MACH_RECV`      | `EVFILT_MACHPORT`                                 | send-possible / a queued Mach message                        |
| `DISPATCH_SOURCE_TYPE_DATA_ADD` / `_OR` / `_REPLACE` | none — a pseudo-filter                            | the accumulated application-supplied value                   |

Two design choices in `dst_flags` carry most of the ergonomics:

- **`EV_DISPATCH`** auto-disables the registration on delivery and re-enables it when the handler returns. The man page states the guarantee this buys: the handler _"need not be reentrant safe, as it is not resubmitted to the target queue until any prior invocation for that dispatch source has completed"_ ([`dispatch_source_create(3)`][man-source]). One source, one handler in flight, always.
- **`EV_UDATA_SPECIFIC`** stores the per-registration `udata` in the kernel's knote rather than in a user-space table, so libdispatch keeps no fd→source hash on the delivery path.

The `DATA_ADD`/`DATA_OR`/`DATA_REPLACE` row deserves attention: those are **not** kernel filters. They are user-space pseudo-sources (`DISPATCH_EVFILT_CUSTOM_ADD` = `-EVFILT_SYSCOUNT - 3`) whose `data` word is accumulated by `dispatch_source_merge_data` and delivered coalesced. That is GCD's cross-thread wakeup and its coalescing counter in one primitive — the equivalent of an `eventfd` plus a hand-written accumulator, with suspension-safe coalescing for free (_"The data describing events which occur while a source is suspended are coalesced and delivered once the source is resumed."_).

[`source-read-pipe.d`](./examples/source-read-pipe.d) drives a pipe through readable → readable → EOF and asserts the byte counts:

```text
state 1 — writer writes 11 bytes:
  event 1: get_data()=11 read()=11
state 2 — writer writes 4 more bytes:
  event 2: get_data()=4 read()=4
state 3 — writer closes its end (the handler cancels the source):
  event 3: get_data()=0 read()=0
  cancel handler: safe to close the descriptor now
```

The parenthetical is a real hazard rather than a stylistic choice. **GCD has no EOF event.** A closed writer surfaces as an ordinary wakeup with `get_data() == 0`, and because `EV_DISPATCH` re-arms as soon as the handler returns, a source that does not cancel itself there spins at full speed. An earlier revision of that example cancelled from the main thread instead and logged six spurious zero-byte wakeups before the cancellation took effect. Cancellation is asynchronous in both directions: the **cancel handler** is the only point at which the descriptor may be closed, and closing it earlier lands in the `EBADF` client crash above.

### Timers, leeway and coalescing

`dispatch_source_set_timer(source, start, interval, leeway)` carries a parameter most loops in this survey have no equivalent for. The fourth argument is a licence for the kernel to fire **late** — up to `leeway` nanoseconds — so unrelated timers across the whole system can be merged into a single wakeup. It lowers to kqueue's `NOTE_LEEWAY`, gated by `DISPATCH_HAVE_TIMER_COALESCING` ([`src/event/event_config.h`][sc-event-config]), and `DISPATCH_HAVE_TIMER_QOS` adds `NOTE_CRITICAL`/`NOTE_BACKGROUND` so a timer's urgency is expressed to the kernel too.

`_dispatch_timer_config_create` ([`src/source.c`][sc-source]) clamps and normalises:

```c
if (interval < INT64_MAX && leeway > interval / 2) {
    leeway = interval / 2;
}
…
dtc->dtc_timer.deadline = target + leeway;
```

so the requested time and the deadline are tracked as a **range**, not a point.

Timers are **not** one kevent each. `dispatch_source_type_timer`'s filter is the pseudo-filter `DISPATCH_EVFILT_TIMER`; the real registrations are maintained by `_dispatch_event_loop_timer_program` ([`src/event/event_kevent.c`][sc-event-kevent]), which keeps a user-space heap per _(clock, timer-QoS)_ bucket — wall/uptime/monotonic × normal/critical/background — and programs only that bucket's earliest deadline into the kernel:

```c
// src/event/event_kevent.c — _dispatch_event_loop_timer_program (abridged)
dispatch_kevent_s ke = {
    .ident  = DISPATCH_KEVENT_TIMEOUT_IDENT_MASK | tidx,
    .filter = EVFILT_TIMER,
    .flags  = action | EV_ONESHOT,
    .fflags = _dispatch_timer_index_to_fflags[tidx],  // CLOCK | NOTE_ABSOLUTE | NOTE_LEEWAY | …
    .data   = (int64_t)target,
    .ext[1] = leeway,
};
```

Ten thousand timers therefore cost at most nine live `EVFILT_TIMER` registrations. Three further details are worth stealing: `start == DISPATCH_TIME_FOREVER` means "one-shot, never rearm"; an `interval` of 0 is a deprecation-warned 1 ns rather than a spin; and the whole clock choice (`DISPATCH_CLOCK_WALL` vs `UPTIME` vs `MONOTONIC`, i.e. `dispatch_walltime` vs `dispatch_time`) is a property of the timer, so a wall-clock timer survives the clock being stepped while an uptime timer does not run while the machine is asleep.

[`source-timer-leeway.d`](./examples/source-timer-leeway.d) arms a 20 ms repeating timer with a 10 ms leeway and records five arrivals. The observed shape is exactly what a coalescing timer should look like — drift up to the leeway, never before the deadline:

```text
fire  deadline (ms)  arrival (ms)  lateness (ms)
   1             20          27.3            7.3
   2             40          48.1            8.1
   3             60          69.0            9.0
   4             80          90.1           10.1
   5            100         100.8            0.8
```

### `dispatch_apply` and QoS-aware parallelism

`dispatch_apply_f` is GCD's parallel `for`, and its width is not `nproc`. From [`src/apply.c`][sc-apply]:

```c
int32_t thr_cnt = (int32_t)_dispatch_qos_max_parallelism(qos, DISPATCH_MAX_PARALLELISM_ACTIVE);
…
if (iterations < (size_t)thr_cnt) thr_cnt = (int32_t)iterations;
if (unlikely(dq->dq_width == 1 || thr_cnt <= 1))
    return dispatch_sync_f(dq, da, _dispatch_apply_serial);
```

`_dispatch_qos_max_parallelism` ([`src/shims.h`][sc-shims]) asks the kernel via `pthread_qos_max_parallelism(qos_class, flags)` and only falls back to `dispatch_hw_config(logical_cpus)` if that fails. On asymmetric hardware the kernel's answer is **per-QoS**, because the background class is confined to the efficiency cluster. Measured by [`qos-parallelism.d`](./examples/qos-parallelism.d) on an M4 Max (10 P-cores + 4 E-cores):

```text
std.parallelism.totalCPUs = 14

QoS class                     logical  physical
QOS_CLASS_BACKGROUND                4         4
QOS_CLASS_UTILITY                  14        14
QOS_CLASS_DEFAULT                  14        14
QOS_CLASS_USER_INITIATED           14        14
QOS_CLASS_USER_INTERACTIVE         14        14
```

This is a genuinely load-bearing number for any thread-per-core design on Apple silicon: a shard count derived from `sysconf(_SC_NPROCESSORS_ONLN)` is wrong for background work by more than 3×, and `std.parallelism.totalCPUs` (14) does not know it. Note also that `dispatch_apply` **runs the caller as one of its workers** and strides via an atomic index rather than partitioning up front (`_dispatch_apply_invoke2`), so a straggler iteration cannot leave a range unclaimed; and that nesting is detected (`dtc_apply_nesting`) and the inner width divided down, rather than multiplying out.

### File I/O: `dispatch_io` is threads and `pread`, not completions

GCD's I/O channel API (`dispatch_io_create`, `dispatch_io_read`, `dispatch_read`) _looks_ like a proactor — you hand it a descriptor and a handler, and byte ranges arrive as immutable `dispatch_data_t` values. The implementation is not one. `_dispatch_operation_perform` ([`src/io.c`][sc-io]) ends in exactly the syscalls a thread-pool design would use:

```c
processed = read(op->fd_entry->fd, buf, len);    // DISPATCH_IO_STREAM
processed = pread(op->fd_entry->fd, buf, len, off);  // DISPATCH_IO_RANDOM
```

The interesting parts are the scheduling around them. A `DISPATCH_IO_RANDOM` channel is bound not to the file but to its **device**: `_dispatch_disk_init` hashes `major(st.st_dev)` into a global `_dispatch_io_devs[]` table and creates one `com.apple.libdispatch-io.deviceq.<dev>` serial queue per physical device, with a bounded pending-request depth. Requests are then reordered per device and prefetched with `fcntl(fd, F_RDADVISE, …)`. So GCD's file I/O is _device-aware I/O scheduling over blocking syscalls_ — closer in spirit to [Seastar][seastar]'s per-device `io_queue` than to [libuv][libuv]'s undifferentiated worker pool, but with none of `io_uring`'s kernel-side asynchrony.

This is the corpus's cleanest statement of the macOS gap: **Darwin has no completion-based I/O interface.** There is no IOCP, no `io_uring`, and POSIX AIO (`aio_read`) is vestigial. Every "async file read" on macOS — GCD's, [libuv][libuv]'s, [Zig][zig-io]'s, [.NET][dotnet]'s — is a blocking syscall on some other thread. A proactor API on macOS is necessarily an emulation; the only question is who owns the threads, and GCD's answer is "the kernel does".

### Portability: the same source without the kernel half

`swift-corelibs-libdispatch` compiles the identical queue, source and I/O code on Linux and Windows, which makes the platform diff unusually legible. `src/event/event_config.h` picks the backend:

```c
#if defined(__linux__)
#	define DISPATCH_EVENT_BACKEND_EPOLL 1
#elif __has_include(<sys/event.h>)
#	define DISPATCH_EVENT_BACKEND_KEVENT 1
#elif defined(_WIN32)
#	define DISPATCH_EVENT_BACKEND_WINDOWS 1
#else
#	error unsupported event loop
#endif
```

and — the detail worth noting — the non-kevent arms **`#define` the kqueue constants themselves** (`EV_ADD`, `EV_DISPATCH`, `EVFILT_READ` = -1, …), so the generic layer stays written in kqueue's vocabulary and each backend translates. `DISPATCH_HAVE_TIMER_COALESCING`, `DISPATCH_HAVE_TIMER_QOS` and `DISPATCH_HAVE_DIRECT_KNOTES` all become 0 off Darwin.

What Linux cannot borrow is the thread pool. `DISPATCH_USE_INTERNAL_WORKQUEUE` turns on `src/event/workqueue.c`, whose header comment is candid about the compromise:

> _"The dynamic monitoring could be implemented using either (a) low-frequency user-level approximation of the number of runnable worker threads via reading the `/proc` file system (b) a Linux kernel extension that hooks the process change handler to accurately track the number of runnable normal worker threads. This file provides an implementation of option (a)."_

A `/proc`-scraping monitor polling for runnable-thread counts is precisely the sort of thing a kernel-integrated design makes unnecessary — and the README's aspiration that _"eventually, a Linux kernel module could be developed to support more informed thread scheduling"_ has not been realised. On Linux, GCD is a competent queue library; on Darwin it is a scheduling protocol with the kernel.

---

## Performance approach

| Technique                          | Mechanism in libdispatch                                                                                                     |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| No loop thread, no fd table        | Kernel upcalls `_dispatch_kevent_worker_thread` with the kevent batch; `EV_UDATA_SPECIFIC` keeps the knote payload in-kernel |
| Batched re-arm                     | The worker returns deferred kevents through `*nevents`; the kernel re-registers them on the way back                         |
| Lock-free queues                   | One 64-bit `dq_state` CAS covers suspend/barrier/width/enqueue; intrusive MPSC list for items                                |
| Inline `sync`                      | `dispatch_sync_f` on an idle lane runs on the caller's thread — no wakeup, no allocation                                     |
| Continuation caching               | Per-thread free list of `dispatch_continuation_s` (`_dispatch_continuation_alloc`)                                           |
| QoS-sized parallelism              | `pthread_qos_max_parallelism` instead of the CPU count; asymmetric-core aware                                                |
| Priority propagation, not spinning | Waiters carry `dsc_waiter` + QoS so the kernel boosts the current owner instead of the waiter busy-waiting                   |
| Timer coalescing                   | `leeway` → `NOTE_LEEWAY`; deadlines are ranges, merged system-wide                                                           |
| Workqueue narrowing                | `_pthread_workqueue_should_narrow` lets the kernel shrink an over-wide pool under contention                                 |
| Device-aware file I/O              | One serial queue per `major(dev)` with bounded depth and `F_RDADVISE` readahead                                              |

---

## Strengths

- **The best answer available on the platform.** On Darwin, GCD is not one option among several — it is the mechanism the kernel cooperates with. Anything else re-implements a worse thread pool beside it.
- **No loop to own.** No manager thread in release builds, no fd→handler table, no re-registration syscall; the kernel delivers events onto threads it created.
- **QoS as a first-class, system-wide currency**, with priority inversion resolved by boosting owners rather than by convention.
- **Composition by retargeting.** Mutual exclusion, priority assignment and subsystem suspension are all one operator, applied at run time.
- **Timer coalescing that actually reaches the kernel**, which matters enormously for battery life and is absent from most portable loops.
- **A complete event vocabulary**: signals, process exit with status, vnode changes, memory pressure and Mach ports, all through one source abstraction.
- **Reachable without blocks.** The `_f` family makes the whole API usable from C, D, Zig or Rust with no shim.
- **Suspension-safe coalescing** via `DATA_ADD`/`DATA_OR` sources, a primitive most loops leave to the application.

## Weaknesses

- **Readiness, not completion.** Every I/O is still a syscall the application makes after being told the descriptor is ready; there is no `io_uring`-style "the bytes are already in your buffer".
- **No async file I/O anywhere underneath.** `dispatch_io` is `pread`/`pwrite` on worker threads with device-aware scheduling on top; the kernel offers nothing better.
- **Thread explosion is a live failure mode.** Overcommit-by-default plus blocking work in serial queues is the canonical Darwin pathology, and the library gives no back-pressure signal — only the advice not to block.
- **`dispatch_sync` deadlocks are structural**, including the two-queue recursive case the man page documents as deliberately unfixed.
- **No EOF event, and no cancellation completion except the cancel handler.** Getting descriptor lifetime wrong is an abort (`"Do not close random Unix descriptors"`), not an error return.
- **Fatal-by-design error handling.** Unexpected `kevent` errors, missing kernel workqueue support and premature thread exit are all `DISPATCH_CLIENT_CRASH`/`DISPATCH_INTERNAL_CRASH`. There is no degraded mode.
- **No cancellation of a submitted work item.** Once enqueued, a block runs; `dispatch_block_cancel` exists only for the `dispatch_block_t` wrapper and only before execution starts.
- **The portable build is a shadow of the Darwin one** — no kqworkloops, no timer QoS, and a `/proc`-scraping pool monitor.
- **Blocks-first documentation** makes the function-pointer API, on which every non-Clang consumer depends, comparatively undocumented.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                  | Trade-off                                                                                 |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| Put the thread pool in the kernel (`pthread_workqueue`)    | Only the kernel sees the whole machine: thermals, other processes, P-core/E-core asymmetry | Non-portable; the Linux port must approximate it by scraping `/proc`                      |
| Deliver kevents by upcall instead of returning from a wait | No loop thread, no manager thread, no separate re-arm syscall                              | Control flow is inverted and hard to reason about; nothing to instrument in user space    |
| Queues are lanes with a target, not threads                | Creating a queue is nearly free, so structure can be expressed liberally                   | "Which thread am I on" becomes unanswerable; TLS is unusable for identity                 |
| `dispatch_sync` runs inline on the caller                  | Removes a wakeup and a context switch from the common uncontended case                     | Recursive `sync` deadlocks; the block observes the caller's thread state, not the queue's |
| Serial queue as the recommended mutex                      | Turns blocking into scheduling; composes via retargeting                                   | An accidentally-blocking item multiplied by overcommit produces thread explosion          |
| `EV_DISPATCH` on every fd source                           | Guarantees one handler invocation in flight without a user-space lock                      | EOF re-arms forever unless the handler cancels; a missed cancel is a spin loop            |
| Overcommit root queues as the default target               | A blocking serial queue cannot stall the bounded pool                                      | Removes the natural back-pressure that a bounded pool would give                          |
| `leeway` as a required timer parameter                     | System-wide timer coalescing; large battery wins                                           | Timers are ranges, so "fires every 20 ms" is not a contract callers can depend on         |
| `dispatch_io` schedules per device, not per file           | Reordering and readahead at the level that matters for a rotating or shared device         | Still blocking syscalls on threads; no kernel asynchrony to exploit                       |
| Crash on protocol violation                                | Descriptor-lifetime and kernel-support bugs are undebuggable if allowed to continue        | No graceful degradation, and no way for a library to recover on a caller's behalf         |
| A `_f` twin for every block-taking function                | Keeps the ABI usable from C and from languages without blocks                              | Two parallel APIs; the documentation only really covers one                               |

---

## What this means for `sparkles:event-horizon`

The kqueue backend ([`backend/kqueue.d`][eh-kqueue]) is a completion-synthesizing proactor: it registers readiness, performs the syscall itself, and emits a `RawCompletion`. GCD is the other macOS-native option, and reading it settles several questions the [SPEC][eh-spec] leaves open.

| Finding                                                                                                               | Consequence for the Sparkles loop                                                                                                                                                      |
| --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Darwin has no completion interface; `dispatch_io` is `pread` on threads                                               | Confirms the backend's design. The deferred "regular files go to a small worker pool" note in `backend/kqueue.d` is not a shortcut — it is what **every** macOS runtime does           |
| `pthread_qos_max_parallelism` is per-QoS and asymmetric (4 vs 14 here)                                                | The pool sizing behind [O23][eh-open] must not use `totalCPUs` on Apple silicon. A background-QoS worker set sized to 14 oversubscribes the E-cluster 3.5×                             |
| `EV_DISPATCH` gives "one handler in flight" for free                                                                  | Our one-shot `EV_ADD`/re-register cycle pays a syscall per event where `EV_DISPATCH` + a deferred re-arm would not; worth measuring against [O16][eh-open]                             |
| kevent delivery returns deferred re-registrations through the same array                                              | The batching idiom generalises past workqueues: accumulate re-arms and submit them with the _next_ `kevent` change list rather than immediately                                        |
| `DATA_ADD`/`DATA_OR` pseudo-sources are the cross-thread wakeup **and** the counter                                   | A candidate shape for [O2][eh-open] (cross-thread handoff) and [O15][eh-open] (tier-A waker): coalescing is in the primitive, not in the caller                                        |
| Timers are `(target, leeway)` ranges, heaped per _(clock, QoS)_ bucket, with only the earliest deadline in the kernel | Two answers for [O18][eh-open] at once: carry a leeway per timer (free on kqueue, buys coalescing on macOS), and keep the heap in user space so N timers cost O(buckets) registrations |
| `EVFILT_PROC` + `NOTE_EXITSTATUS` is how `DISPATCH_SOURCE_TYPE_PROC` reports exit                                     | Corroborates the `OpWaitid` lowering already landed, and [O26][eh-open]'s peer-backend child reap                                                                                      |
| A closed descriptor under a source is `DISPATCH_CLIENT_CRASH`, not an error                                           | Our `Cause` fidelity work ([O10][eh-open]) can be less generous than it currently is: descriptor-lifetime violations are not recoverable conditions                                    |
| `dispatch_sync` runs inline on the caller when the lane is idle                                                       | The same trick applies to a fiber awaiting an op that can complete synchronously: skip the park entirely rather than round-tripping the scheduler                                      |
| Overcommit-by-default is what produces thread explosion                                                               | Argues for the opposite default in the pool ([O23][eh-open]): bounded by measured parallelism, with overcommit opt-in per workload                                                     |

The strategic question this page does **not** settle is whether a macOS backend should be built _on_ GCD rather than beside it. Building on it would inherit the kernel's thread pool, QoS propagation and timer coalescing for free — and [Zig `std.Io`][zig-io] ships exactly that as its `Dispatch` backend. It would also mean giving up control of the thread the completion arrives on, which is the one thing a fiber scheduler cannot delegate: `_dispatch_kevent_worker_thread` runs on a thread the kernel owns and expects back promptly, and parking a fiber's stack on it is not something the workqueue contract permits.

### Reproducing

Every claim above with a number attached comes from `examples/`:

| Example                                                         | Verifies                                                                                |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [`root-queues.d`](./examples/root-queues.d)                     | The twelve-entry `_dispatch_root_queues[]` table, read back from a live library         |
| [`qos-parallelism.d`](./examples/qos-parallelism.d)             | Per-QoS parallelism; background confined to the efficiency cluster                      |
| [`sync-on-caller-thread.d`](./examples/sync-on-caller-thread.d) | `sync` inline on the caller, `async` on a worker, serial FIFO, the druntime attach rule |
| [`source-read-pipe.d`](./examples/source-read-pipe.d)           | `EVFILT_READ` byte counts, the zero-byte EOF wakeup, cancel-handler ordering            |
| [`source-timer-leeway.d`](./examples/source-timer-leeway.d)     | Leeway drift bounded above, never early                                                 |
| [`target-queue-funnel.d`](./examples/target-queue-funnel.d)     | Retargeting converts concurrent lanes into one serial context                           |

They run under `nix run .#ci -- --example-files` on macOS and are skipped by the platform gate on Linux.

---

## Sources

- [`swiftlang/swift-corelibs-libdispatch` @ `f92e811`][sc-tree] — the tree every quotation is taken from
- [`src/init.c` — the root-queue table and the workqueue negotiation][sc-init]
- [`src/queue.c` — `dq_state` handling, `dispatch_sync` fast/slow paths, root-queue poke, worker-thread upcalls][sc-queue]
- [`src/queue_internal.h` — the `dq_state` bit-by-bit specification][sc-queue-internal]
- [`src/internal.h` — the `HAVE_PTHREAD_WORKQUEUE_*` / `DISPATCH_USE_*` feature ladder][sc-internal]
- [`src/event/event_kevent.c` — `_dispatch_kq_init` / `_dispatch_kq_poll` / `_dispatch_kq_drain`][sc-event-kevent]
- [`src/event/event.c` — the source-type descriptor tables][sc-event]
- [`src/event/event_config.h` — the backend selection and capability macros][sc-event-config]
- [`src/event/workqueue.c` — the Linux `/proc`-scraping pool monitor][sc-workqueue]
- [`src/source.c` — timer configuration, leeway clamping, clock selection][sc-source]
- [`src/apply.c` — `dispatch_apply_f` sizing and striding][sc-apply]
- [`src/io.c` — channel operations, per-device queues, `read`/`pread`][sc-io]
- [`src/shims.h` — `_dispatch_qos_max_parallelism`][sc-shims]
- [`private/workloop_private.h` — the workloop contract][sc-workloop]
- [`README.md` — the kernel/user-space split and the Linux port's status][sc-readme]
- Manual pages: [`dispatch(3)`][man-dispatch], [`dispatch_queue_create(3)`][man-queue-create], [`dispatch_async(3)`][man-async], [`dispatch_source_create(3)`][man-source], [`dispatch_io_create(3)`][man-io]
- macOS 14.4 SDK headers: `dispatch/workloop.h` ([availability][sdk-workloop]), `dispatch/source.h`, `dispatch/queue.h`
- [`apple-oss-distributions/libdispatch`][apple-oss] — Apple's release drops, for cross-checking the Darwin-only paths

### See also

- [kqueue, PTYs & signals on macOS][kqueue-ptys] — the same kernel interface from the raw-`kevent` side
- [Event-loop primitives][primitives] — the tier ladder this page's source vocabulary maps onto
- [Implementation techniques][techniques] — reactor/proactor, wakers, timer wheels, feature probing
- [libuv][libuv] — the portable reactor that reaches the same macOS interfaces without the kernel pool
- [Zig `std.Io`][zig-io] — whose `Dispatch` backend is GCD behind a vtable
- [Comparison][comparison] — where GCD sits in the cross-system matrix

<!-- References -->

<!-- Sibling docs -->

[primitives]: ../primitives.md
[techniques]: ../techniques.md
[comparison]: ../comparison.md
[kqueue-ptys]: ../kqueue-and-ptys.md
[libuv]: ../libuv.md
[zig-io]: ../zig-io.md
[dotnet]: ../dotnet.md
[go]: ../go-netpoller.md
[seastar]: ../seastar.md

<!-- Sparkles -->

[eh-spec]: ../../../specs/event-horizon/SPEC.md
[eh-open]: ../../../specs/event-horizon/open-issues.md
[eh-kqueue]: ../../../../libs/event-horizon/src/sparkles/event_horizon/backend/kqueue.d

<!-- Pinned source files -->

[sc-tree]: https://github.com/swiftlang/swift-corelibs-libdispatch/tree/f92e811ea4df3ce2ad1bdf231d3c154797d65c48
[sc-init]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/init.c
[sc-queue]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/queue.c
[sc-queue-internal]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/queue_internal.h
[sc-internal]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/internal.h
[sc-event-kevent]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/event/event_kevent.c
[sc-event]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/event/event.c
[sc-event-config]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/event/event_config.h
[sc-workqueue]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/event/workqueue.c
[sc-source]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/source.c
[sc-apply]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/apply.c
[sc-io]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/io.c
[sc-shims]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/src/shims.h
[sc-workloop]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/private/workloop_private.h
[sc-readme]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/README.md
[sc-license]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/LICENSE

<!-- Manual pages (rendered from the same tree) -->

[man-dispatch]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/man/dispatch.3
[man-queue-create]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/man/dispatch_queue_create.3
[man-async]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/man/dispatch_async.3
[man-source]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/man/dispatch_source_create.3
[man-io]: https://github.com/swiftlang/swift-corelibs-libdispatch/blob/f92e811ea4df3ce2ad1bdf231d3c154797d65c48/man/dispatch_io_create.3

<!-- External -->

[sc-repo]: https://github.com/swiftlang/swift-corelibs-libdispatch
[apple-oss]: https://github.com/apple-oss-distributions/libdispatch
[apple-dispatch]: https://developer.apple.com/documentation/dispatch
[sdk-workloop]: https://developer.apple.com/documentation/dispatch/dispatchworkloop
