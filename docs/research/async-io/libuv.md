# libuv (C)

The C event-loop library behind Node.js, providing a cross-platform abstraction over readiness-based I/O multiplexers (epoll, kqueue, event ports, IOCP) with a worker threadpool for blocking operations and optional `io_uring` offload on Linux.

| Field         | Value                                                                                                                                          |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (C89/C11 hybrid; `<stdatomic.h>` used in newer paths)                                                                                        |
| License       | MIT (plus separate licenses for docs and bundled extras)                                                                                       |
| Repository    | [libuv GitHub Repository]                                                                                                                      |
| Documentation | [libuv Documentation] / [An Introduction to libuv (book)]                                                                                      |
| Key Authors   | Ben Noordhuis, Bert Belder, Saúl Ibarra Corretgé, Santiago Gimeno, Joyent/Node                                                                 |
| Pattern       | Reactor (readiness: epoll / kqueue / event ports) + Proactor (IOCP on Windows) + optional `io_uring` (completion) on Linux + worker threadpool |

> Source anchors below were read at libuv **v1.x** HEAD (`UV_VERSION_MINOR 52`, i.e. 1.52-dev). File paths are repo-relative to the [libuv GitHub Repository].

---

## Overview

### What it solves

libuv exists to give a single, portable, callback-driven asynchronous I/O API on top of platform mechanisms that are wildly different in shape:

- **Linux** has the readiness-based `epoll` family and, since kernel 5.1, the completion-based `io_uring`.
- **macOS / BSD** have `kqueue`.
- **Solaris / illumos** have event ports.
- **Windows** has I/O Completion Ports (IOCP), which are completion-based (a Proactor), not readiness-based.

These models do not agree on the most basic question — does the kernel tell you "the fd is ready, go do the syscall yourself" (a _Reactor_) or "your operation has completed, here is the result" (a _Proactor_)? libuv hides that split behind one event-loop type, `uv_loop_t`, and one handle/request taxonomy. It also papers over the fact that some operations (file system I/O, `getaddrinfo`, DNS) have **no portable non-blocking primitive at all** by running them on a worker threadpool.

libuv was extracted from Node.js (originally as a replacement for the `libev` + `libeio` pairing used in early Node) and remains the I/O substrate underneath Node.js, as well as Julia, Luvit, pyuv, neovim's `libuv`-based loop, and many others.

### Design philosophy

- **Callbacks over coroutines.** libuv is a low-level C library; it does not provide async/await or fibers. Every asynchronous operation takes a function pointer and an opaque `void* data` pointer. Higher-level concurrency (promises, async/await, fibers) is left to the embedder. This contrasts sharply with direct-style effect systems like [Eio][eio], where the runtime suspends a fiber transparently.
- **One loop per thread.** A `uv_loop_t` is not thread-safe and is meant to be driven by exactly one thread. Cross-thread communication is funnelled through a single thread-safe primitive, `uv_async_t`.
- **Reactor first, Proactor where forced.** On Unix the core is a classic Reactor (wait for readiness, then do the syscall). On Windows it is a Proactor over IOCP. The Linux `io_uring` integration adds a Proactor-style completion path _alongside_ the epoll Reactor rather than replacing it.
- **Never block the loop.** Anything that cannot be made non-blocking (file I/O, name resolution, user CPU work) is pushed to the threadpool and its completion is signalled back to the loop thread.

For where libuv sits relative to other runtimes, see the [comparison][comparison] and the [event-loops-and-effects][effects] overview; for the kernel mechanism it increasingly leans on, see [io-uring][iouring].

---

## Core abstractions and types

### The loop: `uv_loop_t`

The central object. Its public surface (`include/uv.h`, `struct uv_loop_s`) is deliberately tiny — a `void* data`, counters like `active_handles`, and a `UV_LOOP_PRIVATE_FIELDS` macro that expands to all the platform state (the backend fd, watcher table, queues, threadpool plumbing). On Unix the private fields include `backend_fd` (the epoll/kqueue/port fd), the `watchers` table indexed by file descriptor, and several intrusive queues (`pending_queue`, `idle_handles`, `async_handles`, `closing_handles`, `wq`).

```c
/* include/uv.h */
struct uv_loop_s {
  void* data;
  unsigned int active_handles;
  /* ... */
  UV_LOOP_PRIVATE_FIELDS
};
```

The loop is run with `uv_run(loop, mode)` where `uv_run_mode` is one of:

| Mode             | Behaviour                                                                |
| ---------------- | ------------------------------------------------------------------------ |
| `UV_RUN_DEFAULT` | Run until there are no more active handles or requests (the usual case). |
| `UV_RUN_ONCE`    | Run a single iteration, blocking for I/O if there is nothing else to do. |
| `UV_RUN_NOWAIT`  | Run a single iteration without blocking for I/O (poll with timeout 0).   |

### Handles vs requests: the two-axis taxonomy

libuv splits everything into **handles** (long-lived objects registered with the loop) and **requests** (short-lived, one-shot operations). The two base types are `uv_handle_t` and `uv_req_t`, and concrete types embed the base via the `UV_HANDLE_FIELDS` / `UV_REQ_FIELDS` macros so they can be up-cast to the base safely (C-style inheritance).

```c
/* include/uv.h */
#define UV_HANDLE_FIELDS                                                      \
  void* data;            /* public, user-owned opaque pointer */             \
  uv_loop_t* loop;       /* read-only */                                     \
  uv_handle_type type;   /* read-only */                                     \
  uv_close_cb close_cb;  /* private */                                       \
  struct uv__queue handle_queue;                                             \
  union { int fd; void* reserved[4]; } u;                                    \
  UV_HANDLE_PRIVATE_FIELDS
```

The handle types are defined by the `UV_HANDLE_TYPE_MAP` X-macro (`include/uv.h`):

| Handle          | Type enum       | Purpose                                             |
| --------------- | --------------- | --------------------------------------------------- |
| `uv_tcp_t`      | `UV_TCP`        | TCP stream socket                                   |
| `uv_udp_t`      | `UV_UDP`        | UDP socket                                          |
| `uv_pipe_t`     | `UV_NAMED_PIPE` | Unix domain socket / Windows named pipe             |
| `uv_tty_t`      | `UV_TTY`        | Terminal / console stream                           |
| `uv_poll_t`     | `UV_POLL`       | Watch a foreign fd for readiness                    |
| `uv_timer_t`    | `UV_TIMER`      | One-shot or repeating timer                         |
| `uv_prepare_t`  | `UV_PREPARE`    | Callback run _before_ polling for I/O               |
| `uv_check_t`    | `UV_CHECK`      | Callback run _after_ polling for I/O                |
| `uv_idle_t`     | `UV_IDLE`       | Callback run every iteration (keeps loop "busy")    |
| `uv_async_t`    | `UV_ASYNC`      | Thread-safe wakeup of the loop from another thread  |
| `uv_signal_t`   | `UV_SIGNAL`     | Watch Unix signals                                  |
| `uv_process_t`  | `UV_PROCESS`    | Child process with SIGCHLD-driven exit notification |
| `uv_fs_event_t` | `UV_FS_EVENT`   | File system change notifications (inotify on Linux) |
| `uv_fs_poll_t`  | `UV_FS_POLL`    | Stat-polling fallback for file change detection     |

The request types come from `UV_REQ_TYPE_MAP`:

| Request            | Type enum        | Backed by                                       |
| ------------------ | ---------------- | ----------------------------------------------- |
| `uv_connect_t`     | `UV_CONNECT`     | Reactor (writable readiness on the socket)      |
| `uv_write_t`       | `UV_WRITE`       | Reactor (queued, flushed on writable readiness) |
| `uv_shutdown_t`    | `UV_SHUTDOWN`    | Reactor                                         |
| `uv_udp_send_t`    | `UV_UDP_SEND`    | Reactor                                         |
| `uv_fs_t`          | `UV_FS`          | Threadpool _or_ `io_uring` (Linux, opt-in)      |
| `uv_work_t`        | `UV_WORK`        | Threadpool (user CPU work)                      |
| `uv_getaddrinfo_t` | `UV_GETADDRINFO` | Threadpool (slow-I/O queue)                     |
| `uv_getnameinfo_t` | `UV_GETNAMEINFO` | Threadpool (slow-I/O queue)                     |
| `uv_random_t`      | `UV_RANDOM`      | Threadpool                                      |

Both bases carry the user's `void* data` field — this is the _entire_ mechanism for associating application state with a callback. There is no closure capture; the C convention is to embed the handle/request in a larger struct and `container_of` back, or stash a pointer in `data`.

### Submission / completion primitive

On the Reactor side there is no explicit submission object exposed to users: you arm interest by starting a handle (`uv_read_start`, `uv_poll_start`) or by issuing a stream request (`uv_write`), and completion arrives as a callback. Internally the per-fd watcher is `uv__io_t`, registered into the loop's `watchers[fd]` table.

On the `io_uring` side (Linux, internal) the submission primitive is a Submission Queue Entry, modelled by libuv's own vendored `struct uv__io_uring_sqe`, and completions arrive as `struct uv__io_uring_cqe` (both in `src/unix/linux.c`). These are never seen by API users; they are an implementation detail of how `uv_fs_*` work gets dispatched.

---

## How it works

### The loop phase model

`uv_run` (`src/unix/core.c`) implements the canonical libuv iteration. Each turn of the `while` loop executes a fixed sequence of phases:

```c
/* src/unix/core.c — uv_run(), abridged */
while (r != 0 && loop->stop_flag == 0) {
  can_sleep = uv__queue_empty(&loop->pending_queue) &&
              uv__queue_empty(&loop->idle_handles);

  uv__run_pending(loop);   /* deferred I/O callbacks (e.g. write_cb) */
  uv__run_idle(loop);      /* uv_idle_t callbacks */
  uv__run_prepare(loop);   /* uv_prepare_t callbacks */

  timeout = 0;
  if ((mode == UV_RUN_ONCE && can_sleep) || mode == UV_RUN_DEFAULT)
    timeout = uv__backend_timeout(loop);

  uv__io_poll(loop, timeout);   /* block in epoll_pwait / kevent / etc. */

  /* drain a bounded number of immediate callbacks to avoid starvation */
  for (r = 0; r < 8 && !uv__queue_empty(&loop->pending_queue); r++)
    uv__run_pending(loop);

  uv__run_check(loop);            /* uv_check_t callbacks */
  uv__run_closing_handles(loop);  /* close_cb for uv_close()d handles */

  uv__update_time(loop);
  uv__run_timers(loop);           /* expired uv_timer_t callbacks */

  r = uv__loop_alive(loop);
  if (mode == UV_RUN_ONCE || mode == UV_RUN_NOWAIT)
    break;
}
```

The conceptual phase order is therefore:

1. **Timers** — run expired `uv_timer_t` callbacks. (For backwards compatibility `UV_RUN_DEFAULT` also runs timers _once before_ entering the loop; otherwise timers run at the tail, after polling, which is the conceptually correct order.)
2. **Pending callbacks** — deferred I/O callbacks that could not be invoked inline last iteration.
3. **Idle handles** — `uv_idle_t` callbacks (run every iteration; their presence forces `timeout = 0`).
4. **Prepare handles** — `uv_prepare_t` callbacks, the last hook before blocking.
5. **Poll for I/O** — `uv__io_poll` blocks in the platform multiplexer for up to `uv__backend_timeout(loop)` ms. The timeout is derived from the nearest timer, or `-1` (block forever) if only handles/requests are pending, or `0` if there is idle/pending work that must run immediately.
6. **Check handles** — `uv_check_t` callbacks, the first hook after waking. (Node.js implements `setImmediate` here.)
7. **Close callbacks** — `close_cb` for handles passed to `uv_close()` this iteration.

`uv__backend_timeout` (`src/unix/core.c`) returns `0` whenever there is pending, idle, or closing work — i.e. the loop refuses to sleep when callbacks are queued — and otherwise calls `uv__next_timeout` to sleep exactly until the next timer fires.

### The Reactor core: epoll on Linux

`uv__io_poll` is platform-specific (`src/unix/linux.c`, `src/unix/kqueue.c`, `src/unix/posix-poll.c`, plus Windows IOCP in `src/win/`). On Linux:

- The backend fd is an `epoll` instance created with `epoll_create1(O_CLOEXEC)` in `uv__platform_loop_init` (`src/unix/linux.c`).
- libuv keeps a `watcher_queue` of `uv__io_t` watchers whose interest masks changed since the last poll. Before sleeping, it applies those changes with `epoll_ctl(EPOLL_CTL_ADD | MOD)`.
- It blocks in `epoll_pwait(epollfd, events, …, timeout, sigmask)` with a millisecond `timeout` (`uv__io_poll`, `src/unix/linux.c`).
- For each returned event it looks up `loop->watchers[fd]` and dispatches via `uv__io_cb`, which fans out by watcher kind (`UV__STREAM_IO`, `UV__UDP_IO`, `UV__POLL_IO`, `UV__ASYNC_IO`, `UV__INOTIFY_READ`, …) — see `uv__io_cb` in `src/unix/core.c`.

On other platforms the same `uv__io_t` abstraction is driven by `kqueue` (`src/unix/kqueue.c`, used on macOS/BSD), Solaris **event ports** (`src/unix/sunos.c`), and AIX (`src/unix/aix.c`). Windows is structurally different: it uses **IOCP**, a true Proactor, so `src/win/` issues overlapped operations and harvests completion packets rather than waiting for readiness.

### The threadpool: `uv__work`

File I/O, name resolution, and user work cannot be done non-blockingly in a portable way, so libuv runs them on a fixed worker pool (`src/threadpool.c`). Key facts from the source:

- The default pool size is **4** threads (`static uv_thread_t default_threads[4]`), overridable via the `UV_THREADPOOL_SIZE` environment variable up to `MAX_THREADPOOL_SIZE == 1024`. Each worker is given an 8 MB stack (`config.stack_size = 8u << 20`).
- Work is submitted with `uv__work_submit(loop, w, kind, work, done)`. The `kind` is one of:

| Work kind          | Used by                             | Queue                                              |
| ------------------ | ----------------------------------- | -------------------------------------------------- |
| `UV__WORK_FAST_IO` | `uv_fs_*` operations (`POST` macro) | main work queue                                    |
| `UV__WORK_SLOW_IO` | `uv_getaddrinfo`, `uv_getnameinfo`  | a separate slow-I/O queue, capped to half the pool |
| `UV__WORK_CPU`     | `uv_queue_work` (user work)         | main work queue                                    |

The slow-I/O distinction (added so that a flood of DNS lookups cannot monopolise every worker and starve file I/O) caps concurrent slow tasks at `slow_work_thread_threshold() == (nthreads + 1) / 2` and multiplexes them through a single `run_slow_work_message` sentinel in the main queue.

- When a worker finishes, it sets `w->work = NULL`, appends the request to the loop's `wq`, and **wakes the loop thread by calling `uv_async_send(&loop->wq_async)`** (`worker()` in `src/threadpool.c`). The loop's built-in `wq_async` handle runs `uv__work_done` during the next iteration, which invokes each request's `done` callback on the loop thread. This is the key to libuv's threading model: workers never touch loop state directly; they only push results and ring the async doorbell.

The `uv_fs_*` dispatch is driven by the `POST` macro (`src/unix/fs.c`):

```c
/* src/unix/fs.c — POST macro */
#define POST                                                                  \
  do {                                                                        \
    if (cb != NULL) {                                                         \
      uv__req_register(loop);                                                 \
      uv__work_submit(loop, &req->work_req, UV__WORK_FAST_IO,                 \
                      uv__fs_work, uv__fs_done);                              \
      return 0;             /* async: callback path */                        \
    } else {                                                                  \
      uv__fs_work(&req->work_req);                                            \
      return req->result;  /* sync: run inline, no threadpool */             \
    }                                                                         \
  } while (0)
```

Note the `cb == NULL` branch: if you call a `uv_fs_*` function without a callback, it runs **synchronously on the calling thread**, bypassing the loop and threadpool entirely.

### Cross-thread wakeup: `uv_async_t`

`uv_async_t` (`src/unix/async.c`) is the _only_ loop primitive that may be triggered from another thread, and it is the mechanism the threadpool itself uses. On Linux the loop owns an `eventfd` (created `EFD_CLOEXEC | EFD_NONBLOCK` in `uv__async_start`). `uv_async_send` sets a per-handle atomic `pending` bit and then writes to the eventfd:

```c
/* src/unix/async.c — uv__async_send(), Linux path */
if (fd == -1) {
  static const uint64_t val = 1;
  buf = &val; len = sizeof(val);
  fd = loop->async_io_watcher.fd;  /* the eventfd */
}
do r = write(fd, buf, len); while (r == -1 && errno == EINTR);
```

The loop wakes from `epoll_pwait`, reads/drains the eventfd in `uv__async_io`, then walks `loop->async_handles` and, for each handle whose pending bit was set, atomically clears it (`atomic_fetch_and(pending, ~1)`) and calls `async_cb`. Coalescing is intentional: many `uv_async_send` calls between iterations collapse into a single callback invocation. On kqueue platforms libuv prefers `EVFILT_USER` (with runtime detection of broken implementations); elsewhere it falls back to a self-pipe.

### Closing handles: `uv_close` and cancellation

`uv_close(handle, close_cb)` (`src/unix/core.c`) is asynchronous. It stops the handle, performs the platform teardown, and then queues the handle onto `loop->closing_handles` via `uv__make_close_pending`. The `close_cb` runs in the _Close callbacks_ phase of a **later** iteration — never inline — so it is safe to free the handle's memory only from inside `close_cb`. This deferral guarantees that no callback for the handle can still be in flight when memory is released.

Request cancellation goes through `uv_cancel(req)` → `uv__work_cancel` (`src/threadpool.c`). It can only cancel work that is still queued (not yet picked up by a worker): it removes the request from the queue, swaps `w->work` for the `uv__cancelled` sentinel, and re-routes it through the normal completion path so the `done` callback fires with `UV_ECANCELED`. **In-flight `io_uring` file operations cannot be cancelled** — there is an explicit `TODO(bnoordhuis)` to that effect in `uv__work_cancel`.

### The io_uring integration (Linux)

This is the most intricate part of `src/unix/linux.c`, and it is best understood as **two independent rings** with very different default behaviour.

#### Ring 1 — epoll-control batching (`lfields->ctl`), on by default

Introduced in **libuv 1.45.0** ("linux: use `io_uring` to batch `epoll_ctl` calls"). At loop init libuv always tries to create a small control ring:

```c
/* src/unix/linux.c — uv__platform_loop_init() */
loop->backend_fd = epoll_create1(O_CLOEXEC);
/* ... */
uv__iou_init(loop->backend_fd, &lfields->ctl, 256, 0);  /* no SQPOLL flag */
```

This ring is used purely to submit `IORING_OP_EPOLL_CTL` operations in batches instead of one `epoll_ctl` syscall per fd-state change. `uv__epoll_ctl_prep` queues `EPOLL_CTL_ADD` / `EPOLL_CTL_MOD` into the ring; `EPOLL_CTL_DEL` is always done immediately and synchronously (closed fds must be removed before the syscall returns). The actual _waiting_ is still `epoll_pwait` — the ring only batches the control-plane mutations. Whether this ring is created is gated by `uv__use_io_uring(0)`, which returns `1` (enabled) on supported kernels when the SQPOLL flag is absent. Since **1.50.0** ("always use `io_uring` for epoll batching") this path is unconditional on capable kernels.

#### Ring 2 — file-operation offload (`lfields->iou`), opt-in since 1.49.0

Introduced in **1.45.0** as well ("linux: introduce `io_uring` support") and expanded in **1.46.0** ("add some more iouring backed fs ops"). This ring lets `uv_fs_*` operations be submitted directly to the kernel as SQEs and completed via CQEs, _bypassing the worker threadpool_. Originally it was enabled by default; this caused enough trouble in the wild (Node.js shipped it disabled, kernel bugs, security concerns around SQPOLL) that **libuv 1.49.0 reverted it to opt-in**: the fs-ops ring is created lazily, and only when the loop is configured with `UV_LOOP_USE_IO_URING_SQPOLL`:

```c
/* src/unix/linux.c — uv__iou_get_sqe(), lazy ring creation */
if (iou->ringfd == -2) {                       /* uninitialized */
  if (loop->flags & UV_LOOP_ENABLE_IO_URING_SQPOLL)
    if (uv__use_io_uring(UV__IORING_SETUP_SQPOLL))
      uv__iou_init(loop->backend_fd, iou, 64, UV__IORING_SETUP_SQPOLL);
  if (iou->ringfd == -2)
    iou->ringfd = -1;                           /* mark "failed/disabled" */
}
if (iou->ringfd == -1)
  return NULL;                                  /* -> caller falls back to threadpool */
```

You opt in via `uv_loop_configure(loop, UV_LOOP_USE_IO_URING_SQPOLL)` (`src/unix/loop.c`), which sets `UV_LOOP_ENABLE_IO_URING_SQPOLL`. In the current source the SQPOLL fs ring additionally requires the `UV_USE_IO_URING` environment variable to be set to a positive number — `uv__use_io_uring(UV__IORING_SETUP_SQPOLL)` returns true only when `val != NULL && atoi(val) > 0`, so the loop flag alone is not sufficient and an absent or non-positive value disables it. The libuv docs are blunt about the default: _"All file operations are run on the threadpool."_

#### Which fs ops use io_uring, and their kernel gates

When the fs-ops ring _is_ active, `src/unix/fs.c` tries `io_uring` first and falls back to the threadpool (`POST`) if the helper returns `0`. Each helper (`uv__iou_fs_*` in `src/unix/linux.c`) version-gates itself via `uv__kernel_version()` (encoded as hex `0xMMmmpp`):

| `uv_fs_*` operation               | `io_uring` opcode            | Kernel gate (from source)                                                              |
| --------------------------------- | ---------------------------- | -------------------------------------------------------------------------------------- |
| `uv_fs_read` / `uv_fs_write`      | `IORING_OP_READV` / `WRITEV` | ring availability (≈5.1; see ring init below); writes with `nbufs > IOV_MAX` fall back |
| `uv_fs_open`                      | `IORING_OP_OPENAT`           | ring availability                                                                      |
| `uv_fs_close`                     | `IORING_OP_CLOSE`            | `>= 5.15.90`; _disabled_ in `[5.16.0, 6.1.0)` (ETXTBSY / data-race workaround)         |
| `uv_fs_fsync` / `uv_fs_fdatasync` | `IORING_OP_FSYNC`            | ring availability                                                                      |
| `uv_fs_ftruncate`                 | `IORING_OP_FTRUNCATE`        | `>= 6.9`                                                                               |
| `uv_fs_stat` / `fstat` / `lstat`  | `IORING_OP_STATX`            | ring availability (statx post-processed via `uv__statx_to_stat`)                       |
| `uv_fs_rename`                    | `IORING_OP_RENAMEAT`         | ring availability                                                                      |
| `uv_fs_unlink`                    | `IORING_OP_UNLINKAT`         | ring availability                                                                      |
| `uv_fs_mkdir`                     | `IORING_OP_MKDIRAT`          | `>= 5.15.0`                                                                            |
| `uv_fs_link`                      | `IORING_OP_LINKAT`           | `>= 5.15.0`                                                                            |
| `uv_fs_symlink`                   | `IORING_OP_SYMLINKAT`        | `>= 5.15.0`                                                                            |

The ring itself imposes a floor higher than the bare 5.1 `io_uring` debut: `uv__iou_init` requires the `IORING_FEAT_RSRC_TAGS` (Linux **5.13**), `IORING_FEAT_SINGLE_MMAP`, and `IORING_FEAT_NODROP` features and bails out if any is missing (the `RSRC_TAGS` check is really a proxy for "STATX works correctly with SQPOLL"). On kernels older than **5.10.186** SQPOLL is refused outright (`uv__use_io_uring` returns `0`) because of a 100%-CPU sqpoll-thread bug fixed in that point release; this gate was added in **1.47.0**. `io_uring` is also hard-disabled on Android (seccomp), 32-bit ARM (`issues/4158`), and 64-bit PowerPC (`issues/4283`).

Importantly, **network I/O does not use io_uring**. Sockets stay on the epoll Reactor; only `uv_fs_*` and the epoll-control batching touch `io_uring`. (There is a long-standing feature request, `libuv/libuv#4044`, to put network I/O on `io_uring`, but it remains unimplemented in v1.x.) For a runtime that _does_ drive sockets through `io_uring`, see [Glommio][glommio], [Monoio][monoio], or [tokio-uring][tokio]; the [io-uring features][iouring-features] doc tabulates the relevant opcodes.

#### Completion harvesting

Both rings register their `ringfd` into the same epoll instance (`epoll_ctl(EPOLL_CTL_ADD, ringfd, …)` in `uv__iou_init`). So `epoll_pwait` wakes when CQEs are ready, and `uv__io_poll` notices the ring fd in its result set and calls `uv__poll_io_uring` (`src/unix/linux.c`):

```c
/* src/unix/linux.c — uv__poll_io_uring(), abridged */
for (i = head; i != tail; i++) {
  e = &cqe[i & mask];
  req = (uv_fs_t*) (uintptr_t) e->user_data;
  uv__req_unregister(loop);
  iou->in_flight--;
  if (e->res == -EOPNOTSUPP) {            /* op unsupported -> retry on pool */
    uv__iou_fs_cleanup_fallback(req);
    uv__fs_post(loop, req);
    continue;
  }
  req->result = e->res;
  /* statx-family ops translate the statx buffer here */
  req->cb(req);                            /* run on the loop thread */
}
```

Two robustness details worth noting: a CQE with `res == -EOPNOTSUPP` transparently retries the operation on the threadpool, and CQ-ring overflow (`IORING_SQ_CQ_OVERFLOW`) is detected and the kernel re-entered (`io_uring_enter(GETEVENTS)`) on a _later_ iteration to avoid loop starvation.

---

## Worked example: the life of a `uv_fs_read`

To make the dispatch concrete, here is the full path of `uv_fs_read(loop, req, fd, bufs, nbufs, off, cb)` on Linux, tracing both branches.

1. **API call.** `uv_fs_read` (`src/unix/fs.c`) runs the `INIT(READ)` macro, stashing the fd, buffers, offset, and `cb` into the `uv_fs_t`.
2. **`io_uring` attempt.** It calls `uv__iou_fs_read_or_write(loop, req, /* is_read */ 1)` (`src/unix/linux.c`). That helper:
   - caps `req->nbufs` at `IOV_MAX` for reads (writes over `IOV_MAX` return `0` and fall back);
   - calls `uv__iou_get_sqe`, which **returns `NULL` unless the fs-ops ring exists** — i.e. unless the loop was configured with `UV_LOOP_USE_IO_URING_SQPOLL`. In the default build this is the end of the `io_uring` path.
   - If a SQE is obtained, it fills `opcode = IORING_OP_READV`, `fd`, `addr = bufs`, `len = nbufs`, `off`, registers the request, and `uv__iou_submit`s it. It returns `1`.
3. **Branch A — `io_uring` (opt-in).** `uv_fs_read` sees the `1` and returns immediately; no threadpool involvement. Later, `epoll_pwait` wakes on the ring fd, `uv__poll_io_uring` reads the CQE, sets `req->result = e->res`, and calls `req->cb(req)` **on the loop thread**.
4. **Branch B — threadpool (default).** The helper returned `0`, so `uv_fs_read` falls through to `POST`. Because `cb != NULL`, `POST` registers the request and calls `uv__work_submit(…, UV__WORK_FAST_IO, uv__fs_work, uv__fs_done)`.
   - A worker thread pops the request, runs `uv__fs_work` (which performs `preadv`/`read`), then sets `w->work = NULL`, appends to `loop->wq`, and calls `uv_async_send(&loop->wq_async)`.
   - The loop thread wakes (the `wq_async` eventfd became readable during `epoll_pwait`), runs `uv__work_done`, which calls `uv__fs_done`, which finally invokes the user's `cb(req)` **on the loop thread**.
5. **Either way**, the callback always runs on the loop thread — the embedder never has to reason about which thread executed the read.

The crucial observation: in a stock libuv/Node.js build, _every_ `uv_fs_read` takes Branch B. Branch A only exists for embedders who explicitly opt into `io_uring` SQPOLL and run a recent enough kernel.

---

## Positioning: libuv vs other async runtimes

| Concern            | libuv                                      | Cross-reference                                              |
| ------------------ | ------------------------------------------ | ------------------------------------------------------------ |
| Programming model  | Callbacks + opaque `void* data`            | Direct-style fibers: [Eio][eio]; goroutines: [Go][go]        |
| Socket I/O backend | epoll / kqueue / IOCP (readiness/Proactor) | All-`io_uring` sockets: [Glommio][glommio], [Monoio][monoio] |
| File I/O backend   | Threadpool by default; `io_uring` opt-in   | Always-`io_uring` files: [Glommio][glommio]                  |
| Threading          | One loop per thread, share-nothing         | Work-stealing multi-thread: [tokio][tokio]                   |
| Completion model   | Reactor core + Proactor where forced       | Pure Proactor designs: see [io-uring overview][iouring]      |

libuv's defining position is _portability and stability over peak Linux throughput_: it targets the lowest common denominator (readiness + threadpool) that works identically everywhere, and treats `io_uring` as an optional accelerator rather than the foundation. Thread-per-core `io_uring` runtimes such as [Glommio][glommio] and [Monoio][monoio] make the opposite bet, sacrificing portability to put both file _and_ socket I/O on the completion ring. For the broader design-space map, see the [comparison][comparison] and [event-loops-and-effects][effects] documents.

---

## Performance approach

- **Syscall batching.** The default-on epoll-control ring collapses many `epoll_ctl` calls into a single `io_uring_enter`, which matters for servers churning thousands of short-lived connections.
- **Bounded callback draining.** After polling, libuv runs at most `8` rounds of pending callbacks (`for (r = 0; r < 8 && …; r++)`) so that a busy fd cannot starve timers and the rest of the loop.
- **Threadpool sizing and slow-I/O isolation.** File I/O parallelism is bounded by `UV_THREADPOOL_SIZE` (default 4), and DNS/`getaddrinfo` work is isolated to at most half the pool so name-resolution storms cannot block file I/O completions.
- **eventfd coalescing.** Cross-thread wakeups coalesce: N `uv_async_send` calls between iterations produce one `async_cb`, and the threadpool's per-completion `uv_async_send` is similarly batched into a single `uv__work_done` sweep.
- **`io_uring` offload (opt-in).** When enabled, `uv_fs_*` operations skip the threadpool entirely, removing a thread hop and a context switch per file op; the libuv 1.45 announcement reported up to ~8× throughput on file-heavy benchmarks. In the default configuration this benefit is unavailable, and file I/O performance is governed by threadpool depth.
- **Precise backend timeouts.** `uv__backend_timeout`/`uv__next_timeout` compute the exact sleep duration (in milliseconds) until the next timer fires, so the loop blocks no longer than necessary in `epoll_pwait` and wakes promptly for the soonest deadline.

---

## Strengths

- **Genuinely portable.** One API spanning Linux, macOS, the BSDs, Solaris/illumos, AIX, and Windows — the only mainstream event loop that abstracts both Reactor (epoll/kqueue) and Proactor (IOCP) models.
- **Battle-tested.** As the engine under Node.js it is among the most heavily exercised C event loops in existence.
- **Small, embeddable, dependency-free.** Pure C with a stable ABI within a major version; trivial to vendor.
- **Clear threading contract.** "One loop per thread; cross talk only via `uv_async_t`" is simple to reason about and hard to misuse catastrophically.
- **Graceful degradation.** `io_uring`, `epoll_pwait2`, `EVFILT_USER`, etc. are all feature-detected at runtime with threadpool / self-pipe / epoll fallbacks, so a binary runs across a wide kernel range.
- **Modern Linux fast paths.** `epoll_ctl` batching is on by default; `io_uring` fs offload is available for those who opt in.

## Weaknesses

- **Callbacks, not coroutines.** No language-level async/await or fibers; control flow inversion ("callback hell") is pushed onto the embedder. Compare the direct-style ergonomics of [Eio][eio] or [Go's netpoller][go] hidden behind goroutines.
- **File I/O is threadpool-bound by default.** Without opting into `io_uring` SQPOLL, every file operation costs a thread hop, and concurrency is capped at `UV_THREADPOOL_SIZE` (default 4). Heavy file workloads can saturate the pool and stall.
- **No network `io_uring`.** Sockets never use `io_uring`; libuv leaves the highest-throughput Linux socket path on the table, unlike Glommio/Monoio/tokio-uring.
- **`io_uring` fs ops are uncancellable.** `uv_cancel` only works on still-queued threadpool work.
- **`io_uring` history is bumpy.** Default-on in 1.45/1.46, then reverted to opt-in in 1.49 after kernel bugs and security concerns (Node.js shipped it disabled); a moving target across kernel versions.
- **Global, process-wide threadpool.** The pool is shared across all loops in a process and sized by one env var, with no per-loop tuning.
- **Manual memory & lifetime management.** Handles must be `uv_close`d and freed only from `close_cb`; getting this wrong is a classic source of use-after-free.

---

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                              | Trade-off                                                                                  |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Callback model with opaque `void* data`                   | Minimal, language-agnostic C ABI; embedders layer their own concurrency on top         | Control-flow inversion; no native async/await; state threading is manual                   |
| Handle vs request taxonomy                                | Clean split between persistent objects and one-shot operations; C-style inheritance    | Verbose; every concrete type re-declares base fields via macros                            |
| One loop per thread; `uv_async_t` for cross-thread wakeup | Loop state needs no locking on its hot path; one clearly-defined thread-safe primitive | All cross-thread coordination funnels through async handles; no shared-state shortcuts     |
| Threadpool for file I/O, DNS, and user work               | Portable: no OS offers portable non-blocking file/name-resolution primitives           | Thread-hop latency; fixed, process-global pool size (default 4) becomes a bottleneck       |
| Reactor (epoll/kqueue) core, Proactor (IOCP) on Windows   | Match each OS's native, fastest mechanism rather than emulating one model everywhere   | Two internal architectures to maintain; subtle behavioural differences across platforms    |
| `epoll_ctl` batching via `io_uring`, default-on           | Fewer syscalls per fd-state change on connection-churn workloads                       | Adds `io_uring` as a mandatory capability probe; another kernel surface to feature-detect  |
| `io_uring` fs offload opt-in (since 1.49)                 | Kernel bugs and SQPOLL security concerns made default-on too risky                     | The big file-I/O speedup is off unless the embedder explicitly configures SQPOLL           |
| `uv_close` deferred to a later iteration                  | Guarantees no callback is still in flight before memory can be freed                   | Cannot synchronously tear down a handle; teardown spans loop iterations                    |
| Per-op kernel-version gating for `io_uring`               | Run one binary safely across a wide kernel range, dodging known per-version bugs       | A web of `uv__kernel_version()` checks and quirk windows (e.g. CLOSE disabled in 5.16–6.1) |

---

## Sources

- [libuv GitHub Repository] — primary source; files read: `src/unix/core.c`, `src/unix/linux.c`, `src/unix/async.c`, `src/threadpool.c`, `src/unix/fs.c`, `src/unix/loop.c`, `src/unix/loop-watcher.c`, `include/uv.h`
- [libuv Documentation] — official API docs (design overview, `uv_loop_t`, file system operations)
- [libuv ChangeLog] — version history (1.45 `io_uring` + `epoll_ctl` batching; 1.46 more fs ops; 1.47 kernel-version gate; 1.49 `io_uring` fs offload made opt-in / SQPOLL ring created lazily; 1.50 always-on epoll batching)
- [libuv fs docs (io_uring & threadpool note)] — "All file operations are run on the threadpool"; `UV_LOOP_USE_IO_URING_SQPOLL`
- [PR #3952: linux: introduce io_uring support] — the original `io_uring` integration
- [Issue #4044: use io_uring for network i/o] — open request; confirms sockets are not on `io_uring`
- [Phoronix: libuv adds io_uring support] — the ~8× throughput claim and 1.45 context
- [io_uring (kernel.dk)] — Jens Axboe's reference on the `io_uring` submission/completion model
- [An Introduction to libuv (book)] — the canonical narrative explanation of the loop and handles
- [io-uring overview (companion)][iouring]
- [io-uring feature/opcode reference (companion)][iouring-features]
- [Async I/O comparison (companion)][comparison]
- [Event loops and effect systems (companion)][effects]
- [Eio (OCaml) — direct-style contrast][eio]
- [tokio (companion)][tokio] · [Glommio (companion)][glommio] · [Monoio (companion)][monoio] · [Go netpoller (companion)][go]

<!-- References -->

[libuv GitHub Repository]: https://github.com/libuv/libuv
[libuv Documentation]: https://docs.libuv.org/en/v1.x/
[libuv ChangeLog]: https://github.com/libuv/libuv/blob/2cadaa40167050baf7c6905ac897e6fb57afb2c6/ChangeLog
[libuv fs docs (io_uring & threadpool note)]: https://docs.libuv.org/en/v1.x/fs.html
[PR #3952: linux: introduce io_uring support]: https://github.com/libuv/libuv/pull/3952
[Issue #4044: use io_uring for network i/o]: https://github.com/libuv/libuv/issues/4044
[Phoronix: libuv adds io_uring support]: https://www.phoronix.com/news/libuv-io-uring
[io_uring (kernel.dk)]: http://web.archive.org/web/20260624135046/https://kernel.dk/io_uring.pdf
[An Introduction to libuv (book)]: https://docs.libuv.org/en/v1.x/guide.html
[iouring]: ./io-uring/index.md
[iouring-features]: ./io-uring/features.md
[comparison]: ./comparison.md
[effects]: ./effects-and-event-loops.md
[eio]: ../algebraic-effects/ocaml-eio.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[go]: ./go-netpoller.md
