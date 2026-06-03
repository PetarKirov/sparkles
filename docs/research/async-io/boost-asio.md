# Boost.Asio (C++)

The canonical C++ asynchronous I/O library: a Proactor reference implementation whose `io_context`/executor model and `async_result` customization machinery became the basis of the C++ Networking TS, and which emulates a Proactor over reactors (epoll, kqueue, `/dev/poll`, select) on most platforms while using true completion-based back-ends on Windows (IOCP) and Linux (`io_uring`).

| Field         | Value                                                                                                          |
| ------------- | -------------------------------------------------------------------------------------------------------------- |
| Language      | C++ (C++11 baseline; C++14/17/20 features detected and used opportunistically)                                 |
| License       | Boost Software License 1.0                                                                                     |
| Repository    | [Asio GitHub Repository] (standalone) · [Boost.Asio in Boost]                                                  |
| Documentation | [Boost.Asio Reference] / [Asio Standalone Documentation]                                                       |
| Key Authors   | Christopher Kohlhoff (author and maintainer)                                                                   |
| Pattern       | Proactor (completion handlers), emulated over a Reactor (epoll / kqueue / select) or native (IOCP, `io_uring`) |
| Encoding      | Completion tokens via `async_result` (callbacks, futures, `use_awaitable` coroutines, `deferred`)              |

---

## Overview

### What It Solves

Boost.Asio provides a portable, extensible foundation for asynchronous and synchronous I/O in C++. It abstracts the wildly divergent OS event-notification mechanisms — `epoll` on Linux, `kqueue` on the BSDs and macOS, `/dev/poll` on Solaris, `select` everywhere else, I/O completion ports (IOCP) on Windows, and `io_uring` on modern Linux — behind a single uniform programming model. Application code expresses an asynchronous operation (`async_read`, `async_accept`, `async_wait`, …) plus a _completion token_ describing how the result is delivered, and Asio takes care of registering the operation with the kernel, demultiplexing readiness/completion events, and invoking the right continuation on the right thread.

Asio is the de facto standard C++ networking library and was the reference implementation behind the C++ Networking Technical Specification (N4734, the "Networking TS"). Its executor model — `execution_context`, `executor`, `require`/`query`/`prefer` customization points — was developed in lockstep with the C++ executors proposals and ships as `boost::asio::execution`. (The Networking TS was ultimately not merged into the C++23 standard, but Asio remains the dominant production library and the design template that later libraries reference.)

### Design Philosophy

1. **Proactor model.** Asio exposes a _completion_-based interface even on platforms that only offer _readiness_ notification. The user always thinks "start operation, get told when it finished, with how many bytes and what error" — never "the socket is now readable, go do a `recv` yourself." This is the Proactor pattern (operation initiated, completion handler invoked) as opposed to the Reactor pattern (readiness signalled, handler does the syscall). On Windows and Linux/`io_uring` this maps to genuinely asynchronous kernel facilities; elsewhere Asio _emulates_ a Proactor on top of a readiness Reactor.

2. **Universal asynchronous model + completion tokens.** A single mechanism — `async_result<CompletionToken, Signature>` — adapts every asynchronous initiating function to many programming styles. The same `socket.async_read_some(buffer, token)` works with a plain callback, a `std::future` (`use_future`), a stackless coroutine (`yield`), a C++20 coroutine (`use_awaitable` / `co_await`), a lazy sender (`deferred`), or a cancellable lazy operation (`experimental::co_composed`). The transformation is selected by the token's type at compile time, with zero runtime overhead for the callback path.

3. **Service-based extensibility.** An `execution_context` is a type-indexed bag of _services_ (`execution_context::service`). Each I/O object (socket, timer, file) delegates to a service that owns the shared kernel resource (a reactor, a timer queue, an `io_uring` ring). New asynchronous facilities are added by writing new services, without touching the core.

4. **Don't pay for what you don't use.** Header-only by default, heavily templated, with per-operation handler allocation hooks (`associated_allocator`) and `noexcept`-aware fast paths. The Reactor emulation includes a _speculative_ fast path that tries the syscall immediately before falling back to readiness registration.

---

## Core abstractions and types

### `execution_context` and `io_context`

`execution_context` (`boost/asio/execution_context.hpp`) is the abstract base: "a place where function objects will be executed" that "implements an extensible, type-safe, polymorphic set of services, indexed by service type." Services are reached through three free functions declared in that header:

```cpp
// boost/asio/execution_context.hpp
template <typename Service> Service& use_service(execution_context&);
template <typename Service, typename... Args>
    Service& make_service(execution_context&, Args&&...);
template <typename Service> bool has_service(execution_context&);
```

`io_context` (`boost/asio/io_context.hpp`) is the concrete, I/O-capable derivation — "the core I/O functionality for users of the asynchronous I/O objects." It owns the event loop. Threads enter the loop with one of:

```cpp
// boost/asio/io_context.hpp
count_type run();         // block until no more work / stopped
count_type run_one();     // run at most one handler
count_type poll();        // run all ready handlers, never block
count_type poll_one();    // run at most one ready handler, never block
void       stop();        // signal the loop to return ASAP
bool       stopped() const;
void       restart();     // reset after a stop()/drain, before re-running
```

Multiple threads may call `run()` on the same `io_context` to form a handler thread pool. A `run()` that returns normally implies the context is stopped; `restart()` rearms it. To keep `run()` from returning when momentarily idle, an `executor_work_guard` (via `make_work_guard`) holds an outstanding-work count.

### The executor

`io_context::executor_type` is `basic_executor_type<std::allocator<void>, 0>`. Critically, the executor _is_ the lightweight handle that gets copied around and stored in handlers — not the `io_context` itself. It packs the context pointer and three runtime property bits into a single `uintptr_t`:

```cpp
// boost/asio/io_context.hpp
struct io_context_bits
{
  static constexpr uintptr_t blocking_never            = 1;
  static constexpr uintptr_t relationship_continuation = 2;
  static constexpr uintptr_t outstanding_work_tracked  = 4;
  static constexpr uintptr_t runtime_bits              = 3;
};
// ...
uintptr_t target_;   // (io_context*) | bits
```

The executor satisfies the C++ executor concept through member `execute`, plus the `require`/`query` customization points for the standard properties: `execution::blocking` (`possibly`/`never`), `execution::relationship` (`fork`/`continuation`), `execution::outstanding_work` (`tracked`/`untracked`), `execution::mapping` (always `thread`), and `execution::allocator`. `bind_executor` associates a handler with a specific executor; `any_io_executor` is the type-erased polymorphic wrapper used by default in `awaitable<T>` and elsewhere.

### Services

Every shared kernel resource lives behind a service. The base class is `execution_context::service`; the header-only convenience bases are `detail::execution_context_service_base<Type>` (keyed by a static `service_id<Type>`) and `io_context::service`. Examples relevant to this document:

| Service                             | Owns                                          | Header                                   |
| ----------------------------------- | --------------------------------------------- | ---------------------------------------- |
| `detail::scheduler`                 | The handler queue + the scheduler task        | `detail/scheduler.hpp`                   |
| `detail::epoll_reactor`             | The `epoll` fd, timerfd, descriptor registry  | `detail/epoll_reactor.hpp`               |
| `detail::io_uring_service`          | The `io_uring` ring, SQ/CQ, timer queues      | `detail/io_uring_service.hpp`            |
| `reactive_socket_service<Protocol>` | Reactor-backed socket operations              | `detail/reactive_socket_service.hpp`     |
| `io_uring_socket_service<Protocol>` | `io_uring`-backed socket operations           | `detail/io_uring_socket_service.hpp`     |
| `io_uring_descriptor_service`       | `io_uring`-backed POSIX descriptor operations | `detail/io_uring_descriptor_service.hpp` |
| `io_uring_file_service`             | `io_uring`-backed regular-file operations     | `detail/io_uring_file_service.hpp`       |

`io_context` is constructed with a service-maker overload so that an initial set of services can be installed eagerly; services are shut down (`shutdown()`) and destroyed in reverse construction order when the context is destroyed.

### The completion-token machinery: `async_result`

The single most important customization point is `async_result` (`boost/asio/async_result.hpp`). Every asynchronous initiating function is declared roughly as:

```cpp
template <typename CompletionToken, /* ... */>
auto async_read_some(const MutableBufferSequence& buffers,
    CompletionToken&& token)
  -> decltype(async_initiate<CompletionToken, void(error_code, size_t)>(
        /* initiation */, token, /* args... */));
```

`async_initiate<Token, Signature>(init, token, args...)` invokes `async_result<decay_t<Token>, Signature>::initiate(...)`, and the token's specialization decides what the call _returns_ and how the result is _delivered_. The header also defines the `completion_signature` traits (`is_completion_signature`, `are_completion_signatures`) and, under C++20 concepts, `completion_handler_for<Token, Signatures...>` used to constrain handler arguments. This is the mechanism that lets one operation serve callbacks, futures, and coroutines with no virtual dispatch.

### Coroutines: `awaitable<T>` and `use_awaitable`

`awaitable<T, Executor = any_io_executor>` (`boost/asio/awaitable.hpp`) is the return type of an Asio C++20 coroutine — "the return type of a coroutine or asynchronous operation." It is gated on `BOOST_ASIO_HAS_CO_AWAIT` and uses `std::coroutine_handle` (or the TS `<experimental/coroutine>` fallback when `BOOST_ASIO_HAS_STD_COROUTINE` is absent). The awaiter members are the standard trio:

```cpp
// boost/asio/awaitable.hpp
bool await_ready() const noexcept { return false; }
template <class U>
void await_suspend(coroutine_handle<awaitable_frame<U, Executor>> h)
{ frame_->push_frame(&h.promise()); }
T await_resume() { return awaitable(std::move(*this)).frame_->get(); }
```

A coroutine is launched with `co_spawn(executor, my_coro(), token)`; inside it, operations are awaited by passing the `use_awaitable` completion token (`co_await socket.async_read_some(buf, use_awaitable)`). The internal `awaitable_thread`/`awaitable_frame` machinery threads the coroutine's executor and an associated `cancellation_state` through every suspension point, which is what makes structured per-coroutine cancellation possible.

---

## How it works

### The scheduler at the centre

The `io_context`'s implementation type is `detail::scheduler` (on Windows/IOCP it is `win_iocp_io_context` instead — see `io_context.hpp`):

```cpp
// boost/asio/io_context.hpp
#if defined(BOOST_ASIO_HAS_IOCP)
  typedef win_iocp_io_context io_context_impl;
#else
  typedef scheduler io_context_impl;
#endif
```

The scheduler (`detail/scheduler.hpp`) owns an `op_queue<operation>` of ready handlers, an `atomic_count outstanding_work_`, and a single `scheduler_task* task_`. The task is the platform demultiplexer — an `epoll_reactor`, `kqueue_reactor`, `io_uring_service`, etc., each of which derives from `scheduler_task` and implements `run(long usec, op_queue<operation>& ops)`. A `task_operation_` marks the task's position in the run queue.

The loop in `scheduler::do_run_one` works approximately as follows:

1. If the ready-handler queue has a real handler at its head, pop it, release the lock, and invoke it via its `complete` virtual (in Asio every pending operation is a `scheduler_operation` with a function-pointer completion, not a heap `std::function`).
2. Otherwise the head is the `task_operation_`. One thread becomes the task runner, calls `task_->run(usec, private_op_queue)` (e.g. `epoll_wait` or `io_uring` completion reaping), and splices the operations that became ready back onto the main queue.
3. `work_finished()` decrements `outstanding_work_`; reaching zero calls `stop()`, which is how `run()` returns when all work drains.

Handlers reach the queue through `post_immediate_completion` / `post_deferred_completion` (and the `dispatch`/`post`/`defer` free functions, which differ in whether they may run inline and how they affect the `relationship` property).

### Timers: `timer_queue_set`

Timers do not consume a kernel descriptor each. Every reactor/`io_uring_service` holds one `timer_queue_set` (`detail/timer_queue_set.hpp`), a linked list of per-clock `timer_queue<TimeTraits>` instances (one for `steady_timer`'s monotonic clock, one for `system_timer`/`deadline_timer`, etc.). The set computes the soonest deadline across all queues:

```cpp
// boost/asio/detail/timer_queue_set.hpp
long wait_duration_msec(long max_duration) const;
long wait_duration_usec(long max_duration) const;
void get_ready_timers(op_queue<operation>& ops);
```

That duration becomes the timeout passed to `epoll_wait` / the `io_uring` timeout. On Linux the `epoll_reactor` also keeps a `timerfd` (`BOOST_ASIO_HAS_TIMERFD`) so that timer changes made by another thread can interrupt a blocked `epoll_wait`. `basic_waitable_timer` (`steady_timer`, `system_timer`, `high_resolution_timer`) and the legacy `deadline_timer` all funnel into `schedule_timer` / `cancel_timer` on the active reactor.

### Reactor back-ends and Proactor emulation

The platform reactor is selected entirely at compile time in `detail/reactor.hpp`:

```cpp
// boost/asio/detail/reactor.hpp
#if defined(BOOST_ASIO_HAS_IOCP) || defined(BOOST_ASIO_WINDOWS_RUNTIME)
typedef null_reactor reactor;
#elif defined(BOOST_ASIO_HAS_IO_URING_AS_DEFAULT)
typedef null_reactor reactor;
#elif defined(BOOST_ASIO_HAS_EPOLL)
typedef epoll_reactor reactor;
#elif defined(BOOST_ASIO_HAS_KQUEUE)
typedef kqueue_reactor reactor;
#elif defined(BOOST_ASIO_HAS_DEV_POLL)
typedef dev_poll_reactor reactor;
#else
typedef select_reactor reactor;
#endif
```

On Linux the default is `epoll_reactor` (`detail/epoll_reactor.hpp`). A reactor reports _readiness_, but Asio's public interface is _completion_-based, so the socket service emulates a Proactor:

1. The user calls `async_read_some`. The `reactive_socket_service` first tries the syscall _speculatively_ (`start_op(..., allow_speculative=true)`): if the socket is already readable, the `recv` succeeds immediately and the completion handler is posted without ever touching `epoll`.
2. If the syscall would block (`EWOULDBLOCK`), the `reactor_op` is queued on the descriptor's per-op queue and the fd is registered with `epoll` (edge-triggered, `EPOLLET`, in `register_descriptor`).
3. When `epoll_wait` later reports the fd ready, `epoll_reactor::descriptor_state::perform_io` runs the queued `reactor_op`s — _now_ doing the actual `recv` — and the ones that complete are spliced onto the scheduler's ready queue, where the `do_complete` for each invokes the user's handler with `(error_code, bytes_transferred)`.

The `descriptor_state` holds three op queues (`read_op`, `write_op`/`connect_op`, `except_op`) and `try_speculative_[max_ops]` flags. This "register readiness, then synthesize a completion" dance is precisely what makes Asio a Proactor _interface_ over a Reactor _kernel facility_. On Windows, `win_iocp_io_context` skips all of this: IOCP is already a completion port, so the OVERLAPPED completion _is_ the Asio completion — a native Proactor with no emulation layer.

### The io_uring back-end: a native Proactor on Linux

The `io_uring_service` (`detail/io_uring_service.hpp`, included only when `BOOST_ASIO_HAS_IO_URING` is defined) is Asio's true completion-based Linux back-end. It is both an `execution_context_service_base<io_uring_service>` and a `scheduler_task`, owning a single `::io_uring ring_` initialized via `liburing`:

```cpp
// boost/asio/detail/io_uring_service.hpp
#include <liburing.h>
// ...
enum { ring_size           = 16384 };  // io_uring_queue_init hint
enum { submit_batch_size   = 128 };
enum { complete_batch_size = 128 };
// ...
::io_uring ring_;
int        event_fd_;     // registered with the (null on AS_DEFAULT) reactor
```

Per I/O object, the service keeps an `io_object` with three serial `io_queue`s (`read_op`, `write_op`, `except_op`). Submission goes through `get_sqe()` (which flushes the ring with `submit_sqes()` if full), and the loop's `run(long usec, op_queue<operation>& ops)` waits on the ring and reaps up to `complete_batch_size` CQEs at a time, dispatching each completed `io_uring_operation` back to the scheduler.

Each operation type provides a static `do_prepare(io_uring_operation*, ::io_uring_sqe*)` that fills an SQE. The opcodes Asio actually emits (grep of `detail/io_uring_*_op.hpp` and `detail/impl/io_uring_service.ipp`):

| Operation                        | Primary SQE opcode (liburing helper)         | Fallback / readiness opcode       | Source header                                   |
| -------------------------------- | -------------------------------------------- | --------------------------------- | ----------------------------------------------- |
| Stream/dgram receive             | `io_uring_prep_recvmsg`                      | `io_uring_prep_poll_add(POLLIN)`  | `io_uring_socket_recv_op.hpp`                   |
| Receive into a registered buffer | `io_uring_prep_read_fixed`                   | —                                 | `io_uring_socket_recv_op.hpp`                   |
| Stream/dgram send                | `io_uring_prep_sendmsg`                      | `io_uring_prep_poll_add(POLLOUT)` | `io_uring_socket_send_op.hpp`                   |
| Send from a registered buffer    | `io_uring_prep_write_fixed`                  | —                                 | `io_uring_socket_send_op.hpp`                   |
| `recvfrom` / `recvmsg`           | `io_uring_prep_recvmsg`                      | `io_uring_prep_poll_add`          | `io_uring_socket_recvfrom_op.hpp`               |
| Accept                           | `io_uring_prep_accept`                       | `io_uring_prep_poll_add(POLLIN)`  | `io_uring_socket_accept_op.hpp`                 |
| Connect                          | `io_uring_prep_connect`                      | —                                 | `io_uring_socket_connect_op.hpp`                |
| Descriptor / file read           | `io_uring_prep_readv` / `…_read_fixed`       | `io_uring_prep_poll_add(POLLIN)`  | `io_uring_descriptor_read_op.hpp`               |
| Descriptor / file write          | `io_uring_prep_writev` / `…_write_fixed`     | `io_uring_prep_poll_add(POLLOUT)` | `io_uring_descriptor_write_op.hpp`              |
| Generic wait / null-buffers      | `io_uring_prep_poll_add(poll_flags)`         | —                                 | `io_uring_wait_op.hpp`, `…_null_buffers_op.hpp` |
| Cancellation                     | `io_uring_prep_cancel`                       | —                                 | `impl/io_uring_service.ipp`                     |
| Internal timeout                 | `io_uring_prep_timeout` / `…_timeout_remove` | —                                 | `impl/io_uring_service.ipp`                     |
| Ring interrupt                   | `io_uring_prep_nop`                          | —                                 | `impl/io_uring_service.ipp`                     |

A representative `do_prepare`, showing the registered-buffer fast path and the readiness fallback for non-blocking sockets:

```cpp
// boost/asio/detail/io_uring_socket_recv_op.hpp
static void do_prepare(io_uring_operation* base, ::io_uring_sqe* sqe)
{
  io_uring_socket_recv_op_base* o = static_cast<io_uring_socket_recv_op_base*>(base);

  if ((o->state_ & socket_ops::internal_non_blocking) != 0)
  {
    bool except_op = (o->flags_ & socket_base::message_out_of_band) != 0;
    ::io_uring_prep_poll_add(sqe, o->socket_, except_op ? POLLPRI : POLLIN);
  }
  else if (o->bufs_.is_single_buffer
      && o->bufs_.is_registered_buffer && o->flags_ == 0)
  {
    ::io_uring_prep_read_fixed(sqe, o->socket_,
        o->bufs_.buffers()->iov_base, o->bufs_.buffers()->iov_len,
        -1, o->bufs_.registered_id().native_handle());
  }
  else
  {
    ::io_uring_prep_recvmsg(sqe, o->socket_, &o->msghdr_, o->flags_);
  }
}
```

Buffers can be pre-registered with the kernel via `io_uring_service::register_buffers(const ::iovec*, unsigned)` / `unregister_buffers()`, after which `…_read_fixed`/`…_write_fixed` avoid per-op buffer mapping.

#### Version gating and the two enablement modes

The whole `io_uring` tree is behind `BOOST_ASIO_HAS_IO_URING`, and on Linux Asio enforces a hard minimum kernel:

```cpp
// boost/asio/detail/config.hpp
#if defined(BOOST_ASIO_HAS_IO_URING)
#  if LINUX_VERSION_CODE < KERNEL_VERSION(5,10,0)
#   error Linux kernel 5.10 or later is required to support io_uring
#  endif
#endif
```

There are two distinct ways to turn it on, and the difference is captured by `BOOST_ASIO_HAS_IO_URING_AS_DEFAULT`:

```cpp
// boost/asio/detail/config.hpp
#if !defined(BOOST_ASIO_HAS_IO_URING_AS_DEFAULT)
# if !defined(BOOST_ASIO_HAS_EPOLL) && defined(BOOST_ASIO_HAS_IO_URING)
#  define BOOST_ASIO_HAS_IO_URING_AS_DEFAULT 1
# endif
#endif
```

| Build configuration                                        | Effect                                                                                                                                                                 |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| (nothing defined)                                          | `epoll_reactor`. `io_uring` code is not compiled. Files (`stream_file`, `random_access_file`) are unavailable on Linux.                                                |
| `BOOST_ASIO_HAS_IO_URING` only                             | epoll stays the default for sockets/timers; `io_uring` is _available_ and is used for facilities that _require_ it — notably regular-file I/O.                         |
| `BOOST_ASIO_HAS_IO_URING` **+** `BOOST_ASIO_DISABLE_EPOLL` | `BOOST_ASIO_HAS_IO_URING_AS_DEFAULT` becomes 1; `reactor` is typedef'd to `null_reactor` and `io_uring` backs _all_ I/O objects (sockets, timers, descriptors, files). |

This support depends on `liburing` at compile and link time — add `-luring`. The `io_uring` back-end was introduced in **Asio 1.22.0 / Boost 1.78.0** (December 2021), and was the enabling change that brought first-class regular-file I/O (`basic_stream_file`, `basic_random_access_file`, gated on `BOOST_ASIO_HAS_FILE`) to Linux; on Windows the same file classes are backed by IOCP.

Even when `AS_DEFAULT`, the `io_uring_service` still creates an `event_fd_` and registers it with a (null) reactor for cross-thread wakeups, and falls back to `io_uring_prep_poll_add` when a socket is in non-blocking mode — so the design is genuinely a completion engine that can degrade to readiness polling per-operation when needed.

### Strands: handler serialization

A strand guarantees that handlers dispatched through it never run concurrently, while still allowing them to run on any thread of the `io_context`'s pool. Asio offers two forms: the modern executor adaptor `strand<Executor>` (`boost/asio/strand.hpp`, used as `make_strand(ctx)` or `bind_executor(strand, handler)`), and the legacy `io_context::strand` (`boost/asio/io_context_strand.hpp`, available unless `BOOST_ASIO_NO_TS_EXECUTORS` is defined). Internally a strand keeps a small lock-protected queue and an atomic "locked" flag: the first handler to arrive runs immediately and drains the queue; handlers that arrive while the strand is "locked" are appended and run later by the draining thread. This provides mutual exclusion without an OS mutex on the fast path, the standard way to write lock-free-looking multi-threaded Asio servers.

### Cancellation: `cancellation_signal` / `cancellation_slot`

Per-operation cancellation is propagated through _cancellation slots_ rather than by closing the I/O object. A `cancellation_signal` (`boost/asio/cancellation_signal.hpp`) owns a `cancellation_slot`; the slot is associated with a completion handler (via `associated_cancellation_slot` / `bind_cancellation_slot`), and emitting the signal invokes the operation's registered cancellation handler. The granularity is described by `cancellation_type` (`boost/asio/cancellation_type.hpp`):

```cpp
// boost/asio/cancellation_type.hpp
enum cancellation_type
{
  none     = 0,
  terminal = 1,   // after success, object only safe to close/destroy
  partial  = 2,   // may have partial side effects; object in known state
  total    = 4,   // no observable side effects; object unchanged
  all      = 0xFFFFFFFF
};
```

Composed operations and coroutines carry a `cancellation_state` that combines an incoming slot with optional filters, so `co_spawn`'d coroutines and `parallel_group`/`awaitable_operators` (`||`, `&&`) get structured cancellation: cancelling the group cancels the children. On the `io_uring` back-end a `total`/`partial` cancel can be turned into a real `io_uring_prep_cancel` SQE targeting the in-flight operation; on the epoll back-end cancellation removes the queued `reactor_op` and completes it with `operation_aborted`.

---

## Performance approach

- **Speculative syscalls.** On reactors, Asio attempts the read/write/accept inline before registering for readiness, eliding `epoll_wait` round-trips for already-ready sockets. Edge-triggered `epoll` (`EPOLLET`) minimizes wakeups.
- **No `std::function` per operation.** Pending operations are intrusive `scheduler_operation`s with a function-pointer vtable-like `complete`/`destroy` and small-object handler allocation through the associated allocator. Handlers can be allocated from per-connection memory pools.
- **Single timer demultiplex point.** All timers share one `timer_queue_set` and one kernel timeout; no per-timer fd (the lone `timerfd` is only an interrupt mechanism).
- **Batched `io_uring`.** SQEs are submitted in batches of up to 128 and CQEs reaped up to 128 at a time, amortizing `io_uring_enter` syscalls; registered buffers (`read_fixed`/`write_fixed`) skip per-op buffer setup.
- **Concurrency hints.** `io_context(concurrency_hint)` and `BOOST_ASIO_CONCURRENCY_HINT_*` let single-threaded contexts elide internal locking entirely (the `conditionally_enabled_mutex` becomes a no-op).
- **Compile-time backend selection.** All platform dispatch (`reactor.hpp`, the IOCP typedef) is `#if`-resolved; there is no runtime backend indirection.

In typical network benchmarks Asio is competitive with hand-written `epoll` loops, since the emulation layer adds little beyond the speculative path. The `io_uring` back-end's advantage is most visible for high-syscall-rate workloads and for regular-file I/O, which has no efficient readiness model. Compared to thread-per-core runtimes like [Glommio][glommio] / [Seastar][seastar], Asio's default model is a _shared_ `io_context` (work-stealing-ish across `run()` threads), not a sharded one — though sharded designs are easy to build by running one `io_context` per core.

## Strengths

- **Portability with one model.** The same code targets Linux (epoll/`io_uring`), macOS/BSD (kqueue), Solaris (`/dev/poll`), Windows (IOCP), and fallback `select`.
- **Completion-token flexibility.** Callbacks, futures, stackless coroutines (`yield`), C++20 coroutines (`use_awaitable`), and lazy senders (`deferred`) all from one API surface, with the callback path being zero-overhead.
- **Mature, battle-tested, ubiquitous.** Two decades of production use; the reference for the Networking TS; vast ecosystem (Beast for HTTP/WebSocket, many libraries built on top).
- **Native Proactor where it counts.** IOCP and `io_uring` give true asynchronous completion for sockets and files; the Proactor _interface_ never changes.
- **Fine-grained resource control.** Custom allocators per handler, concurrency hints, custom executors and services.
- **Structured cancellation and concurrency** via `cancellation_slot`, `co_spawn`, `parallel_group`, and the awaitable operators.

## Weaknesses

- **Steep learning curve.** The executor model, `async_result`/`async_initiate`, associated allocators/executors/cancellation-slots, and template-heavy errors are notoriously hard for newcomers.
- **Heavy compile times and header bloat.** Header-only-by-default plus deep templates inflate build times; the `boost::asio::execution` layer is large.
- **Reactor emulation is not a true Proactor on most Unixes.** Without `io_uring`, Asio still issues the read/write itself on readiness — fine for sockets, but it cannot do genuinely asynchronous regular-file I/O on plain epoll (hence the `io_uring` requirement for files).
- **`io_uring` is opt-in and version-sensitive.** Requires Boost ≥ 1.78, `liburing`, `-luring`, kernel ≥ 5.10, and explicit macros; it is not the default and won't be picked up automatically.
- **No built-in structured-concurrency scope by default.** Lifetime safety relies on convention (`shared_ptr`-bound handlers, `enable_shared_from_this`), unlike effect-system runtimes such as [Eio][eio] that enforce structured concurrency.
- **Executor proposal churn.** The C++ executors story shifted repeatedly (and the Networking TS was not standardized), leaving Asio with both TS-era and `execution`-era APIs.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                  | Trade-off                                                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Expose a Proactor (completion) interface everywhere             | One mental model; portable to IOCP/`io_uring` without API change                           | On reactors Asio must _emulate_ completion, and can't do true async file I/O without `io_uring` |
| Emulate Proactor over a readiness Reactor (epoll/kqueue)        | Reuse the best-available readiness mechanism per OS while keeping the completion interface | Extra synthesized-completion bookkeeping; per-op queues and speculative-syscall logic           |
| Completion tokens via `async_result`/`async_initiate`           | One API serves callbacks, futures, coroutines, senders; callback path is zero-overhead     | Deep templates, opaque return types, hard error messages                                        |
| Service-indexed `execution_context`                             | Extensible: new I/O facilities = new services; shared kernel resources owned centrally     | Indirection and type-erasure boilerplate; service lifetime ordering must be respected           |
| Executor as a packed `uintptr_t` handle, not the context        | Cheap to copy/store in every handler; properties carried in pointer tag bits               | Property set is fixed by the bit layout; the indirection obscures "what runs where"             |
| Single `timer_queue_set` + one kernel timeout                   | O(1) extra fds regardless of timer count; soonest-deadline drives the wait                 | Timer changes from other threads need a `timerfd`/eventfd interrupt to re-arm the wait          |
| `io_uring` opt-in, gated on kernel 5.10 + `liburing` + macros   | Avoid silently depending on a new kernel/lib; keep epoll as the safe default               | Users must knowingly enable it; files on Linux are unavailable without it                       |
| Strands serialize without an OS mutex on the fast path          | Lock-free-feeling multithreaded servers; one thread drains the strand queue                | Still allocates a small queue; long handlers serialize throughput on that strand                |
| Per-operation cancellation via slots, not by closing the object | Cancel one operation, leave others/the object usable; maps to `io_uring_prep_cancel`       | Must thread slots through handlers; cancellation _type_ semantics add conceptual surface area   |

---

## Sources

- [Asio GitHub Repository] — Christopher Kohlhoff's standalone Asio; source of all quoted headers.
- [Boost.Asio in Boost] — the `boostorg/asio` packaging in the Boost super-project.
- [Boost.Asio Reference] — official reference for `io_context`, executors, `async_result`, `awaitable`, strands, and cancellation.
- [Boost.Asio Using/Configuring] — the `BOOST_ASIO_HAS_*` / `BOOST_ASIO_DISABLE_*` macro catalog, including the `io_uring` enablement macros.
- [Boost.Asio Revision History] — the 1.22.0 / Boost 1.78.0 entry documenting the `io_uring` backend, `BOOST_ASIO_HAS_IO_URING`, `BOOST_ASIO_DISABLE_EPOLL`, the `-luring` link requirement, and `io_uring`-backed files.
- [liburing] — the userspace library (`<liburing.h>`, `io_uring_prep_*`) that the `io_uring` service is built on.
- [io_uring(7) man page] — semantics of the SQE opcodes Asio emits and the ring/SQ/CQ model.
- [C++ Networking TS (N4734)] — the standard-track draft for which Asio was the reference implementation.
- [Eio (companion effect-system doc)][eio] — contrast with an effects-based, structured-concurrency runtime.
- For the `io_uring` opcode/feature landscape and per-kernel availability, see the [io_uring reference][io-uring]; for other completion/reactor runtimes see [Tokio][tokio], [Glommio][glommio], [Seastar][seastar], [libuv][libuv], and the [primitives][primitives] and [techniques][techniques] overviews.

<!-- References -->

[Asio GitHub Repository]: https://github.com/chriskohlhoff/asio
[Boost.Asio in Boost]: https://github.com/boostorg/asio
[Boost.Asio Reference]: https://www.boost.org/doc/libs/release/doc/html/boost_asio/reference.html
[Asio Standalone Documentation]: https://think-async.com/Asio/
[Boost.Asio Using/Configuring]: https://www.boost.org/doc/libs/latest/doc/html/boost_asio/using.html
[Boost.Asio Revision History]: https://www.boost.org/doc/libs/1_78_0/doc/html/boost_asio/history.html
[liburing]: https://github.com/axboe/liburing
[io_uring(7) man page]: https://man7.org/linux/man-pages/man7/io_uring.7.html
[C++ Networking TS (N4734)]: https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/n4734.pdf
[eio]: ../algebraic-effects/ocaml-eio.md
[io-uring]: ./io-uring/index.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[seastar]: ./seastar.md
[libuv]: ./libuv.md
[primitives]: ./primitives.md
[techniques]: ./techniques.md
