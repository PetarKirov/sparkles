# io_uring — Programming Model

The shared-memory, completion-based asynchronous I/O interface for Linux: two ring buffers shared between user space and the kernel let an application batch arbitrary syscalls and reap their results without a syscall per operation.

> **Scope.** This is the entry point for the `io_uring` sub-section. It explains the model from first principles — the submission and completion rings, the SQE/CQE entry layouts, the three syscalls, the head/tail producer-consumer protocol and its memory ordering, the submission→kernel→completion lifecycle, and the operating modes (default task-work, SQPOLL, IOPOLL/`HYBRID_IOPOLL`, the `*_TASKRUN`/`SINGLE_ISSUER` tuning knobs, and io-wq offload). It contrasts `io_uring`'s _completion_ (Proactor) model against epoll's _readiness_ (Reactor) model. For the feature surface and capability flags see [Features & Flags][features]; for the historical progression of kernel versions see [Timeline][timeline]; for a per-opcode catalog see [Opcodes Reference][opcodes]. For where this sits among other async-I/O techniques across the survey, see [Techniques][techniques].

| Field         | Value                                                                                          |
| ------------- | ---------------------------------------------------------------------------------------------- |
| System        | `io_uring` — Linux kernel asynchronous I/O interface                                           |
| Since         | Linux 5.1 (May 2019)                                                                           |
| Author        | Jens Axboe (with Christoph Hellwig)                                                            |
| License       | UAPI header: `GPL-2.0 WITH Linux-syscall-note OR MIT`; liburing: `MIT`/`LGPL-2.1`              |
| Syscalls      | `io_uring_setup(2)`, `io_uring_enter(2)`, `io_uring_register(2)`                               |
| User library  | [liburing] (`io_uring_queue_init`, `io_uring_get_sqe`, `io_uring_submit`, `io_uring_wait_cqe`) |
| Repository    | [Linux kernel `io_uring/`][linux-io_uring] · [liburing]                                        |
| Documentation | [io_uring.7][io_uring7] · [io_uring_setup.2][setup2] · [io_uring_enter.2][enter2]              |
| Pattern       | Proactor (completion-based) over two shared SPSC ring buffers; optional kernel-side SQ polling |

---

## Overview

### What it solves

The classic Unix model issues one syscall per I/O operation: `read(2)`, `write(2)`, `recvmsg(2)`. Each crossing of the user/kernel boundary costs a mode switch, and post-Spectre/Meltdown mitigations made that crossing markedly more expensive. The readiness-based multiplexers (`select(2)`, `poll(2)`, `epoll(7)`) reduce _blocking_ syscalls but not the _count_ of syscalls: you still call `epoll_wait` to learn that a descriptor is ready, then a separate `read` to actually move the bytes, and `epoll` only ever worked well for sockets/pipes — never for regular-file I/O, which is always "ready" yet still blocks. The previous kernel AIO interface (`io_submit(2)` / `libaio`) was narrow (effectively `O_DIRECT` only), still cost a syscall per submission batch, and copied a control block per request.

`io_uring`, merged in Linux 5.1, attacks all of these at once. It establishes two ring buffers in memory shared between the application and the kernel: a **submission queue (SQ)** the application writes to, and a **completion queue (CQ)** the kernel writes to. In the steady state the application fills submission entries, advances a tail pointer with a release store, and — at most — makes a single `io_uring_enter(2)` call that both submits a batch and waits for completions. With submission-queue polling enabled, even that one syscall disappears. The interface is _generic_: nearly any syscall-shaped operation has an opcode (see [Opcodes Reference][opcodes]), so buffered file reads, `openat`, `accept`, `connect`, `recvmsg`, `fsync`, `statx`, timeouts, and even `ioctl`-style passthrough all flow through the same rings.

### Design philosophy

Three ideas drive the design:

1. **Communicate through shared memory, not syscalls.** The rings _are_ the API surface. Syscalls degrade from "one per operation" to "one per batch" to, under SQPOLL, "zero." The `io_uring.7` man page makes this explicit: "rather than just communicate between kernel and user space with system calls, ring buffers are used as the main mode of communication."

2. **Completion, not readiness.** Unlike epoll, which tells you _when you may act_, `io_uring` tells you _that an action finished_. The application hands the kernel a complete description of the work (buffer, length, offset, flags) and later receives a result. This is the Proactor pattern, and it is what lets buffered file I/O, which has no meaningful "readiness," participate at all.

3. **Batch and amortize.** A single `io_uring_enter` can submit N entries and reap M completions. Fixed (pre-registered) files and buffers, multishot operations, linked SQEs, and ring-provided buffers all exist to push more work across each boundary crossing and to eliminate per-request setup cost.

---

## Core abstractions and types

### The two rings

The interface is built from a small number of UAPI structures declared in `linux/include/uapi/linux/io_uring.h`. The application never manipulates kernel objects directly; it reads and writes a handful of shared `__u32` cursors and two arrays of entries.

| Object                | Producer    | Consumer    | Entry type     | Default size |
| --------------------- | ----------- | ----------- | -------------- | ------------ |
| Submission Queue (SQ) | application | kernel      | `io_uring_sqe` | 64 bytes     |
| Completion Queue (CQ) | kernel      | application | `io_uring_cqe` | 16 bytes     |

Each ring is a single-producer / single-consumer circular buffer described by a set of offsets the kernel returns from `io_uring_setup(2)`. The SQ has one extra layer: an _indirection array_ (`sq->array`) of indices into the SQE array, so submitted entries need not be contiguous (more below).

### Submission Queue Entry (SQE)

The SQE is the universal request descriptor — one struct that, depending on `opcode`, plays the role of any of dozens of syscalls. From `linux/include/uapi/linux/io_uring.h` (`struct io_uring_sqe`, abridged; many fields are unions reused per-opcode):

```c
struct io_uring_sqe {
        __u8    opcode;         /* type of operation for this sqe */
        __u8    flags;          /* IOSQE_ flags */
        __u16   ioprio;         /* ioprio for the request */
        __s32   fd;             /* file descriptor to do IO on */
        union {
                __u64   off;    /* offset into file */
                __u64   addr2;
                /* ... cmd_op for URING_CMD ... */
        };
        union {
                __u64   addr;   /* pointer to buffer or iovecs */
                __u64   splice_off_in;
                /* ... level/optname for socket opts ... */
        };
        __u32   len;            /* buffer size or number of iovecs */
        union {
                __u32   rw_flags;
                __u32   fsync_flags;
                __u32   poll32_events;
                __u32   timeout_flags;
                /* ... one per opcode family ... */
        };
        __u64   user_data;      /* data to be passed back at completion time */
        union { __u16 buf_index; __u16 buf_group; } __attribute__((packed));
        __u16   personality;
        union { __s32 splice_fd_in; __u32 file_index; /* ... */ };
        union {
                struct { __u64 addr3; __u64 __pad2[1]; };
                __u8 cmd[0];    /* SQE128: 80 bytes of command data */
        };
};
```

Key fields:

- **`opcode`** — one of `enum io_uring_op` (`IORING_OP_READ`, `IORING_OP_WRITE`, `IORING_OP_ACCEPT`, `IORING_OP_OPENAT`, `IORING_OP_RECVMSG`, …; see [Opcodes Reference][opcodes]).
- **`flags`** — `IOSQE_*` per-request modifiers: `IOSQE_FIXED_FILE` (use a registered file slot), `IOSQE_IO_LINK` / `IOSQE_IO_HARDLINK` (sequence dependent SQEs), `IOSQE_IO_DRAIN` (barrier), `IOSQE_ASYNC` (force async offload), `IOSQE_BUFFER_SELECT` (pick a provided buffer), `IOSQE_CQE_SKIP_SUCCESS` (suppress the CQE on success).
- **`user_data`** — an opaque 64-bit cookie the kernel copies verbatim into the matching CQE. This is the _sole_ correlation mechanism: see [user_data correlation](#user_data-correlation).
- The remaining unions overlay per-opcode operands so the struct stays exactly 64 bytes.

The SQE is 64 bytes by default. With `IORING_SETUP_SQE128` it doubles to 128 bytes — the trailing `cmd[0]` flexible member becomes 80 bytes of arbitrary command payload, required by `IORING_OP_URING_CMD` passthrough (e.g. NVMe). The newer `IORING_SETUP_SQE_MIXED` (Linux 6.19) allows a ring to hold both 64- and 128-byte SQEs, with 128-byte entries marked by a dedicated 128-bit opcode.

### Completion Queue Entry (CQE)

The CQE is deliberately tiny — `struct io_uring_cqe` (`linux/include/uapi/linux/io_uring.h`):

```c
struct io_uring_cqe {
        __u64   user_data;      /* sqe->user_data value passed back */
        __s32   res;            /* result code for this event */
        __u32   flags;
        __u64 big_cqe[];        /* present only with CQE32 */
};
```

- **`user_data`** echoes the SQE's cookie.
- **`res`** is the operation result, _exactly as the equivalent syscall would have returned it_: a non-negative byte count / fd on success, or a negated `errno` (`-EINVAL`, `-EAGAIN`, `-ECANCELED`, …) on failure.
- **`flags`** carries `IORING_CQE_F_*` bits: `IORING_CQE_F_BUFFER` (upper 16 bits hold the selected buffer ID, shifted by `IORING_CQE_BUFFER_SHIFT`), `IORING_CQE_F_MORE` (the originating SQE will post more CQEs — used by multishot poll/accept/recv), `IORING_CQE_F_SOCK_NONEMPTY`, `IORING_CQE_F_NOTIF` (zero-copy send notification), `IORING_CQE_F_32` (this is a 32-byte CQE in a mixed-mode ring).

Default CQEs are 16 bytes. `IORING_SETUP_CQE32` widens them to 32 bytes (the `big_cqe[]` tail), needed by passthrough commands that return extra status. `IORING_SETUP_CQE_MIXED` (Linux 6.19) lets a ring post both sizes; a 32-byte CQE sets `IORING_CQE_F_32`, and the kernel may insert a filler 16-byte CQE marked `IORING_CQE_F_SKIP` to avoid wrapping a large entry across the ring boundary.

### Ring offsets and parameters

`io_uring_setup(2)` takes and returns `struct io_uring_params`, which embeds the two offset descriptors:

```c
struct io_uring_params {
        __u32 sq_entries;
        __u32 cq_entries;
        __u32 flags;            /* IORING_SETUP_* */
        __u32 sq_thread_cpu;
        __u32 sq_thread_idle;
        __u32 features;         /* IORING_FEAT_* filled in by kernel */
        __u32 wq_fd;
        __u32 resv[3];
        struct io_sqring_offsets sq_off;
        struct io_cqring_offsets cq_off;
};

struct io_sqring_offsets {
        __u32 head; __u32 tail; __u32 ring_mask; __u32 ring_entries;
        __u32 flags; __u32 dropped; __u32 array; __u32 resv1;
        __u64 user_addr;
};

struct io_cqring_offsets {
        __u32 head; __u32 tail; __u32 ring_mask; __u32 ring_entries;
        __u32 overflow; __u32 cqes; __u32 flags; __u32 resv1;
        __u64 user_addr;
};
```

Each `*_off` field is a _byte offset into the mmap'd region_ at which the corresponding shared `__u32` lives. The application adds the offset to the base pointer to obtain, e.g., `&sq->tail` or `&cq->head`. This indirection lets the kernel evolve the layout without breaking the ABI.

### liburing's view

Almost nobody touches the rings by hand; the [liburing] library wraps them. In `liburing/src/include/liburing.h`, `struct io_uring` bundles a `struct io_uring_sq` and a `struct io_uring_cq`, each caching the kernel pointers (`khead`, `ktail`, `kflags`, …), the mmap base (`ring_ptr`), and locally cached `ring_mask` / `ring_entries`. The user-facing flow is:

```c
struct io_uring ring;
io_uring_queue_init(QD, &ring, 0);                 /* setup + mmap */

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe, fd, buf, len, offset);     /* fill the SQE */
io_uring_sqe_set_data(sqe, my_ctx);                /* set user_data */

io_uring_submit(&ring);                            /* io_uring_enter() */

struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);                    /* block for one */
void *ctx = io_uring_cqe_get_data(cqe);
int   result = cqe->res;
io_uring_cqe_seen(&ring, cqe);                     /* advance CQ head */
```

`io_uring_get_sqe` returns the next free SQE (or `NULL` if the SQ is full); `io_uring_submit` issues `io_uring_enter`; `io_uring_wait_cqe` / `io_uring_peek_cqe` read completions; and `io_uring_cqe_seen` calls `io_uring_cq_advance(ring, 1)` to release the slot back to the kernel.

---

## How it works

### The three syscalls

`io_uring` exposes exactly three syscalls. After setup, the hot path uses only `io_uring_enter` (or none, under SQPOLL).

| Syscall                | Role                                                                                                                                                    | Frequency        |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `io_uring_setup(2)`    | Create a ring of `entries` SQEs; kernel allocates SQ/CQ memory and returns a ring fd plus `io_uring_params` offsets.                                    | Once per ring    |
| `io_uring_register(2)` | Register/unregister long-lived resources: fixed files, fixed buffers, eventfd, provided-buffer rings, the ring fd itself, restrictions, NAPI busy-poll. | Setup / rarely   |
| `io_uring_enter(2)`    | Submit up to `to_submit` SQEs and/or wait for `min_complete` CQEs; the single hot-path syscall.                                                         | Per batch (or 0) |

`io_uring_setup(entries, params)` rounds `entries` up to a power of two, allocates the rings (by default `CQ` is twice the `SQ`), maps the requested `IORING_SETUP_*` flags into kernel state, and writes back `sq_entries`, `cq_entries`, the negotiated `features`, and the two offset blocks. It returns a file descriptor.

The application then `mmap(2)`s the shared regions at three magic offsets defined in the UAPI header:

```c
#define IORING_OFF_SQ_RING   0ULL
#define IORING_OFF_CQ_RING   0x8000000ULL
#define IORING_OFF_SQES      0x10000000ULL
```

`io_uring_enter(fd, to_submit, min_complete, flags, sig, sigsz)` does the work. `to_submit` tells the kernel how many new SQEs to consume from the SQ tail; `IORING_ENTER_GETEVENTS` plus `min_complete` makes the call block until that many CQEs are available. Other flags include `IORING_ENTER_SQ_WAKEUP` (kick a sleeping SQPOLL thread), `IORING_ENTER_SQ_WAIT`, `IORING_ENTER_EXT_ARG` (pass a `struct io_uring_getevents_arg` carrying both a sigmask and a timeout, since Linux 5.11 via `IORING_FEAT_EXT_ARG`), and `IORING_ENTER_REGISTERED_RING` (the fd is a registered index, not a real fd).

### Single-mmap memory layout

A naive setup maps three regions: the SQ ring, the CQ ring, and the SQE array. Since Linux 5.4 the kernel sets `IORING_FEAT_SINGLE_MMAP` in `params.features` to advertise that the SQ and CQ rings occupy _one_ contiguous region — the application maps `IORING_OFF_SQ_RING` once (sized to span both) and derives the CQ pointers from the same base, cutting the mmap count from three to two. The SQEs are always mapped separately at `IORING_OFF_SQES`. liburing's setup checks the feature bit and elides the second mapping accordingly.

Two later flags push memory management further:

- **`IORING_SETUP_NO_MMAP`** (Linux 6.5) inverts ownership: the _application_ allocates the ring and SQE memory (typically a huge page) and passes the addresses in `sq_off.user_addr` / `cq_off.user_addr`; the kernel pins them instead of allocating its own. The `mmap(2)` step is skipped entirely. The `memmap.c` machinery (`io_create_region`, `io_region_pin_pages`) handles both kernel-allocated and caller-supplied regions through one code path.
- **`IORING_SETUP_REGISTERED_FD_ONLY`** (Linux 6.5, requires `NO_MMAP`) returns a registered ring-fd _index_ rather than an installed file descriptor, avoiding even the fd-table slot.

### Head/tail producer-consumer protocol and memory ordering

Each ring is governed by a `head` and a `tail`, both shared `__u32` counters that increase monotonically (the _masked_ value `index = counter & ring_mask` selects a slot). The producer advances the tail; the consumer advances the head; the ring is empty when `head == tail` and full when `tail - head == ring_entries`.

**Submission side** (application is producer, kernel is consumer). The `io_uring.7` man page gives the canonical sequence:

```c
unsigned tail  = *sqring->tail;
unsigned index = tail & (*sqring->ring_mask);
struct io_uring_sqe *sqe = &sqring->sqes[index];
describe_io(sqe);                       /* fill in opcode, fd, addr, len, ... */
sqring->array[index] = index;           /* publish via the indirection array */
tail++;
atomic_store_explicit(sqring->tail, tail, memory_order_release);
```

The **release store** to `tail` is the publication point: it guarantees that all the writes filling the SQE (and the `array[]` slot) are visible to the kernel _before_ the kernel observes the new tail. The kernel performs a corresponding **acquire load** of the tail.

**Completion side** (kernel is producer, application is consumer). The application reads CQEs from `head` up to the kernel-published `tail`, then releases the slots with a release store to `head`. liburing's `io_uring_cq_advance` shows the exact ordering (`liburing/src/include/liburing.h`):

```c
IOURINGINLINE void io_uring_cq_advance(struct io_uring *ring, unsigned nr)
{
        if (nr) {
                struct io_uring_cq *cq = &ring->cq;
                /*
                 * Ensure that the kernel only sees the new value of the head
                 * index after the CQEs have been read.
                 */
                io_uring_smp_store_release(cq->khead, *cq->khead + nr);
        }
}
```

The acquire/release pairing is the whole correctness story: it is a lock-free SPSC handoff with no syscall in the steady state. The application must load the kernel-updated counter (CQ tail, or the SQ `flags` word) with **acquire** semantics and store its own counter (SQ tail, CQ head) with **release** semantics. The man page defers the full treatment to `Documentation/memory-barriers.txt` and the C11/kernel memory models, but the two snippets above are the load-bearing primitives.

**The SQ indirection array.** Unlike the CQ, where the ring directly indexes the CQE array, the SQ ring holds indices into a separate `array[]` that in turn indexes the SQE array. This decoupling lets an application pre-fill SQEs in arbitrary slots and submit them in any order, or reuse SQE slots across submissions. The kernel reads it in `io_get_sqe` (`linux/io_uring/io_uring.c`):

```c
static bool io_get_sqe(struct io_ring_ctx *ctx, const struct io_uring_sqe **sqe)
{
        unsigned mask = ctx->sq_entries - 1;
        unsigned head = ctx->cached_sq_head++ & mask;

        if (!(ctx->flags & IORING_SETUP_NO_SQARRAY)) {
                head = READ_ONCE(ctx->sq_array[head]);
                if (unlikely(head >= ctx->sq_entries)) {
                        /* bogus index → bump sq_dropped, skip */
                        return false;
                }
        }
        if (ctx->flags & IORING_SETUP_SQE128)
                head <<= 1;             /* 128B SQEs occupy two slots */
        *sqe = &ctx->sq_sqes[head];
        return true;
}
```

`IORING_SETUP_NO_SQARRAY` (Linux 6.6) removes this indirection — the SQ ring then indexes SQEs directly, and `sq_off.array` is zero. `IORING_SETUP_SQ_REWIND` (Linux 7.0) goes further still: the kernel ignores head/tail and always fetches SQEs starting at index 0, keeping the hot SQEs cache-resident for small frequent batches.

### Submission → kernel → completion lifecycle

1. **Acquire** an SQE (`io_uring_get_sqe`), fill it (`io_uring_prep_*`), set `user_data`.
2. **Publish** by advancing the SQ tail (release store). liburing batches this internally and the actual tail update happens inside `io_uring_submit`.
3. **Submit** via `io_uring_enter(fd, n, …)`. The kernel runs `io_submit_sqes` (`linux/io_uring/io_uring.c`), consuming up to `n` entries, allocating an `io_kiocb` request per SQE, and issuing each operation.
4. **Execute.** Most operations attempt to complete inline (synchronously). If the file/socket is not ready, `IORING_FEAT_FAST_POLL` (Linux 5.7) lets the kernel arm an internal poll and resume the op on readiness, without tying up a worker thread. Operations that _cannot_ be done non-blockingly are punted to **io-wq** (below).
5. **Complete.** When an operation finishes, the kernel fills a CQE (`user_data`, `res`, `flags`) and advances the CQ tail. Posting the CQE may go through _task work_ (next section) so it lands in the submitter's context.
6. **Reap.** The application observes the new CQ tail (via `io_uring_enter` with `IORING_ENTER_GETEVENTS`, or by reading the shared tail directly), processes each CQE, and **releases** the slots by advancing the CQ head (`io_uring_cqe_seen` / `io_uring_cq_advance`).

The kernel posts **exactly one CQE per SQE** by default. The exceptions are deliberate: `IOSQE_CQE_SKIP_SUCCESS` suppresses the CQE on success; multishot operations (poll, accept, recv, with `IORING_CQE_F_MORE`) post _many_ CQEs from one SQE until the operation is cancelled or errors.

### user_data correlation

`io_uring` imposes no ordering between submissions and completions — a later-submitted op may complete first. The _only_ link between an SQE and its CQE is the 64-bit `user_data` field, copied verbatim from SQE to CQE. Applications typically store a tagged pointer to a request context (`io_uring_sqe_set_data` / `io_uring_cqe_get_data`) or an index. Because the value is opaque and uninterpreted, it is also the application's responsibility to keep the referenced context alive until the matching CQE arrives, and to handle the multishot case where one `user_data` produces a stream of completions.

### CQE overflow (NODROP) and eventfd

What happens if completions arrive faster than the application reaps them and the CQ fills? Originally (pre-5.5) the kernel simply _dropped_ events, incrementing the `cq_off.overflow` counter — a lost completion, which for I/O is catastrophic. Since Linux 5.5, `IORING_FEAT_NODROP` guarantees this essentially never happens: when the CQ ring is full the kernel stashes overflowing completions in an internal list and flushes them into the ring as space frees up (`__io_cqring_overflow_flush`, `io_cqe_overflow` in `linux/io_uring/io_uring.c`). The `IORING_SQ_CQ_OVERFLOW` bit in the SQ `flags` word signals that a backlog exists. Only genuine kernel OOM can still drop an event (at which point, as the man page dryly notes, you have larger problems). On newer kernels (5.19+) a backlogged ring returns `-EBADR` from `io_uring_enter` the next time it would otherwise sleep, prompting the app to drain.

For integration with existing event loops, `io_uring_register(2)` with `IORING_REGISTER_EVENTFD` attaches an `eventfd` that the kernel signals whenever a CQE is posted. The application can then `epoll`/`poll` that single fd inside a legacy loop and only drain the CQ when it fires. `IORING_REGISTER_EVENTFD_ASYNC` restricts notifications to events that completed asynchronously. The CQ `flags` bit `IORING_CQ_EVENTFD_DISABLED` lets the application temporarily suppress eventfd signalling.

---

## Operating modes

`io_uring`'s behavior is tuned by `IORING_SETUP_*` flags at `io_uring_setup` time. The choice governs _who runs submissions_, _how completions are delivered into your context_, and _how the CPU is spent waiting_. (Each flag's full description and version gating is in [Features & Flags][features].)

| Mode / flag                  | What it changes                                                                                       | Since |
| ---------------------------- | ----------------------------------------------------------------------------------------------------- | ----- |
| _(default)_                  | Interrupt-driven; submission via `io_uring_enter`; completions posted via IPI + task work.            | 5.1   |
| `IORING_SETUP_SQPOLL`        | Kernel thread polls the SQ and submits without any `io_uring_enter`.                                  | 5.1   |
| `IORING_SETUP_SQ_AFF`        | Pin the SQPOLL thread to `sq_thread_cpu`.                                                             | 5.1   |
| `IORING_SETUP_IOPOLL`        | Busy-poll the device for completions (NVMe / `O_DIRECT`) instead of IRQ.                              | 5.1   |
| `IORING_SETUP_HYBRID_IOPOLL` | Like IOPOLL but sleep briefly before busy-polling, trading a little latency for much less CPU.        | 6.13  |
| `IORING_SETUP_COOP_TASKRUN`  | Don't IPI-interrupt the submitter for completions; run task work at the next kernel transition.       | 5.19  |
| `IORING_SETUP_TASKRUN_FLAG`  | Surface pending task work via `IORING_SQ_TASKRUN` so peek-style loops know to enter the kernel.       | 5.19  |
| `IORING_SETUP_SINGLE_ISSUER` | Promise that only one task submits; kernel drops locking it would otherwise need.                     | 6.0   |
| `IORING_SETUP_DEFER_TASKRUN` | Defer completion task work until the submitter explicitly waits (`GETEVENTS`); needs `SINGLE_ISSUER`. | 6.1   |

### Default mode — interrupt + task work

With no flags, submission is an `io_uring_enter` call and completion is interrupt-driven. The subtlety is _where_ the completion (filling the CQE, freeing the request) runs. To make completions appear in the submitting task's context — important for credentials, cancellation, and cache locality — the kernel uses the **task-work** mechanism (`io_req_task_work_add` in `linux/io_uring/io_uring.c`). By default delivering task work may fire an **inter-processor interrupt (IPI)** to force the target CPU to run it promptly, which is why the default is sometimes called "interrupt-driven."

### The TASKRUN family — taming task-work cost

The IPI and forced kernel transition are pure overhead when the submitter is going to enter the kernel soon anyway. The `*_TASKRUN` flags progressively relax this:

- **`IORING_SETUP_COOP_TASKRUN`** (5.19): skip the IPI; run pending task work whenever the task next transitions into the kernel for any reason. Saves the interrupt and avoids preempting userspace, at the cost of slightly later completion delivery. The man page notes this "will improve performance" for most single-ring-per-thread use cases.
- **`IORING_SETUP_TASKRUN_FLAG`** (5.19): because COOP/DEFER can leave completions pending without any signal, this flag sets `IORING_SQ_TASKRUN` in the SQ `flags` word when task work is waiting. liburing checks this bit even on `io_uring_peek_cqe` and enters the kernel to flush, making peek-style reaping safe.
- **`IORING_SETUP_SINGLE_ISSUER`** (6.0): a hint — enforced with `-EEXIST` — that only one task ever submits. This lets the kernel elide submission-path locking. The submitting task is the creator (or, with `IORING_SETUP_R_DISABLED`, the task that enables the ring).
- **`IORING_SETUP_DEFER_TASKRUN`** (6.1, requires `SINGLE_ISSUER`): the strongest knob. Instead of running task work at _every_ kernel transition, the kernel defers it until the submitter calls `io_uring_enter` with `IORING_ENTER_GETEVENTS`, i.e. exactly when the app is ready to process completions. This batches completion processing, eliminates spurious wakeups, and is widely the highest-throughput configuration for a dedicated I/O thread — at the cost that the application _must_ periodically wait for events or completions will not be delivered.

### SQPOLL — submission-queue polling

`IORING_SETUP_SQPOLL` spawns a dedicated kernel thread (`io_sq_thread` in `linux/io_uring/sqpoll.c`) that busy-monitors the SQ tail and submits entries on the application's behalf. In steady state the application writes SQEs and advances the tail and the kernel thread picks them up with _zero_ syscalls — the holy grail for high-IOPS, latency-sensitive workloads.

To avoid burning a core forever, the thread sleeps after `sq_thread_idle` milliseconds of inactivity, setting `IORING_SQ_NEED_WAKEUP` in the SQ `flags`. The application must guard submission with the documented load-acquire dance:

```c
unsigned flags = atomic_load_relaxed(sq_ring->flags);
if (flags & IORING_SQ_NEED_WAKEUP)
        io_uring_enter(fd, 0, 0, IORING_ENTER_SQ_WAKEUP, ...);
```

liburing's `io_uring_submit` handles this transparently. `IORING_SETUP_SQ_AFF` pins the poller to `sq_thread_cpu`; `IORING_SETUP_ATTACH_WQ` shares one poller thread across multiple rings. Originally SQPOLL required pre-registered (fixed) files; since Linux 5.11 (`IORING_FEAT_SQPOLL_NONFIXED`) any fd works, and since 5.13 SQPOLL no longer needs special privileges. Note that with SQPOLL the kernel consumes the SQE _asynchronously_, so any memory referenced by pointer (iovecs, `timespec`, `msghdr`) must stay valid until _completion_, not merely until submit returns.

### IOPOLL / HYBRID_IOPOLL — busy-polling completions

`IORING_SETUP_IOPOLL` switches completion delivery from device IRQs to _busy polling_: the application calls `io_uring_enter` with `IORING_ENTER_GETEVENTS` and the kernel actively polls the device queue for finished I/O. This shaves interrupt latency on fast storage but spins a CPU. It is restricted to pollable storage — currently descriptors opened `O_DIRECT` and read/write-family opcodes — and the device must be configured for polling (for NVMe, the `nvme` driver loaded with `poll_queues`). `IORING_SETUP_HYBRID_IOPOLL` (Linux 6.13, requires IOPOLL) sleeps for a tuned interval before polling, recovering most of the CPU while keeping most of the latency win. Both pair naturally with SQPOLL for an all-polling, syscall-free hot path.

### io-wq — async offload for blocking operations

Not every operation can complete without blocking. Buffered file reads that miss the page cache, `getdents`, `openat`, `statx`, and anything for which fast-poll is unavailable would otherwise stall the submitting thread. `io_uring` offloads these to **io-wq** (`linux/io_uring/io-wq.c`), a per-ring pool of kernel worker threads that run blocking work on the application's behalf and post the CQE when done. `IOSQE_ASYNC` forces an operation onto io-wq unconditionally. Since Linux 5.12 (`IORING_FEAT_NATIVE_WORKERS`) these workers behave like ordinary process threads rather than impersonating the owning task. `IORING_SETUP_ATTACH_WQ` shares one worker backend across rings, and `io_uring_register(2)` with `IORING_REGISTER_IOWQ_MAX_WORKERS` / `IORING_REGISTER_IOWQ_AFF` caps and pins the pool. Fast-poll (5.7) was specifically introduced to keep _socket_ I/O off io-wq, since pollable fds can be driven by the internal poll machinery instead of consuming a worker.

---

## Completion vs. readiness — io_uring against epoll

The cleanest way to place `io_uring` is against `epoll(7)`, the dominant Linux readiness multiplexer. They sit on opposite sides of the Reactor/Proactor divide.

| Aspect                 | `epoll` (Reactor / readiness)                                   | `io_uring` (Proactor / completion)                         |
| ---------------------- | --------------------------------------------------------------- | ---------------------------------------------------------- |
| What you're told       | "fd X is _ready_ to read/write"                                 | "operation X _finished_; here is its result"               |
| Who moves the bytes    | Application, in a follow-up `read`/`write` syscall              | Kernel, before posting the CQE                             |
| Syscalls per operation | ≥ 2 (`epoll_wait` + the actual I/O)                             | ≤ 1 amortized; 0 under SQPOLL                              |
| Regular-file I/O       | Not supported (files are always "ready" yet still block)        | First-class (buffered and `O_DIRECT`)                      |
| Batching               | One wait returns many ready fds; I/O still issued one at a time | One `enter` submits N ops and reaps M completions          |
| Buffer lifetime        | App owns buffers; supplies them at I/O time                     | Buffer described at submit, possibly registered/pre-pinned |
| Cancellation           | Implicit (just stop calling `read`)                             | Explicit (`IORING_OP_ASYNC_CANCEL`, link timeouts)         |

The practical upshot: epoll only ever covered the _socket/pipe_ half of async I/O, and even there cost a second syscall to do the transfer. `io_uring` is uniform across sockets _and_ files, and collapses submission+completion of many operations into a single boundary crossing — or none. `io_uring` can even _subsume_ epoll: `IORING_OP_POLL_ADD` (especially multishot) and `IORING_OP_EPOLL_CTL` / `IORING_OP_EPOLL_WAIT` let a ring perform readiness-style waiting when that's genuinely what you want. This is why effect-system and async runtimes increasingly prefer it as a Linux backend — e.g. OCaml's [Eio][eio] uses `io_uring` in `eio_linux`, and Rust's [Tokio][tokio] integrates it via `tokio-uring`/compio-style designs (see also [Techniques][techniques]).

---

## Performance approach

`io_uring`'s performance model is about _eliminating per-operation cost_ at three layers:

1. **Syscall amortization.** Batching turns N syscalls into 1 (`io_uring_enter` with a large `to_submit`), and SQPOLL turns it into 0. Each saved boundary crossing avoids a mode switch plus speculation-mitigation overhead.
2. **Copy elimination.** The rings live in shared memory, so submitting work and reading results involves no copy-in/copy-out of control structures (unlike libaio's per-request `iocb`). Registered (fixed) buffers (`IORING_REGISTER_BUFFERS`) are pinned once so the kernel skips per-I/O `get_user_pages`; registered files (`IORING_REGISTER_FILES`) skip per-I/O `fget`/`fput` and reference-count churn. Provided-buffer rings let the kernel pick a buffer at completion time, avoiding speculative per-connection allocation.
3. **Thread avoidance.** Fast-poll (5.7) keeps pollable I/O off worker threads; only genuinely blocking work hits io-wq. The TASKRUN/`DEFER_TASKRUN` knobs remove IPIs and spurious wakeups from completion delivery; IOPOLL removes interrupts from the storage path entirely.

Stacking these — SQPOLL + IOPOLL + fixed files/buffers + `DEFER_TASKRUN` — yields a configuration where a steady stream of NVMe I/O runs with effectively no syscalls and no interrupts, which is how `io_uring` reaches multi-million-IOPS figures in storage benchmarks. The trade-off is that polling modes consume dedicated CPU, so they pay off only when offered enough I/O to keep the polled core busy.

---

## Strengths

- **Generic.** One interface for buffered files, direct I/O, sockets, timers, polling, and syscall passthrough — not a socket-only or `O_DIRECT`-only niche.
- **Completion-based.** Works for regular-file I/O, which readiness interfaces fundamentally cannot drive.
- **Syscall-frugal.** Batched submission; with SQPOLL the steady-state I/O path makes zero syscalls.
- **Lock-free hot path.** SPSC rings with acquire/release ordering; no kernel lock contention to submit or reap in the common case.
- **Composable requests.** Linked SQEs, drains, timeouts, multishot, and provided buffers express complex dependencies without round-trips.
- **No-copy resource registration.** Fixed files/buffers and ring-provided buffers remove repeated per-I/O setup costs.
- **Robust completions.** `IORING_FEAT_NODROP` makes completion loss practically impossible short of OOM.
- **Tunable.** A rich flag matrix lets workloads dial in the right CPU/latency/throughput balance.

## Weaknesses

- **Complexity.** The ABI is large and subtle: memory ordering, SQE union overlays, per-opcode flag spaces, and resource lifetime rules are easy to get wrong by hand (most users rely on liburing).
- **Buffer-lifetime hazards.** Pointers in SQEs (iovecs, `timespec`, `msghdr`) must outlive the operation; under SQPOLL or async offload they must live until _completion_, a classic source of use-after-free bugs.
- **Kernel-version sprawl.** Capabilities are gated by kernel version and advertised via `IORING_FEAT_*`; portable code must probe and fall back (see [Timeline][timeline]).
- **Security surface.** The breadth and complexity have produced a steady stream of CVEs; some hardened/container environments disable `io_uring` outright via `io_uring_disabled` sysctl or seccomp.
- **Polling burns CPU.** SQPOLL/IOPOLL only win under sustained load; on bursty or low-IOPS workloads they waste cycles.
- **Cancellation and ordering semantics** are explicit and non-trivial — there is no implicit "just stop reading" as with epoll.
- **Not portable.** Linux-only; cross-platform runtimes still need an epoll/kqueue/IOCP fallback path.

---

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                            | Trade-off                                                                           |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Communicate via two shared rings, not per-op syscalls      | Amortize/eliminate mode-switch cost; enable batching and zero-syscall steady state   | Lock-free shared-memory protocol with explicit memory ordering is hard to get right |
| Completion (Proactor) over readiness (Reactor)             | Covers buffered file I/O; kernel does the transfer; one notification per finished op | Buffers/contexts must stay alive until completion, not until submit                 |
| SQ indirection array (`sq->array`)                         | Submit SQEs in any order; reuse slots; decouple SQE layout from submission order     | Extra cache line + bounds check per submission (removable via `NO_SQARRAY`)         |
| 64-byte SQE / 16-byte CQE fixed sizes (with 128/32 opt-in) | Compact, cache-friendly, ABI-stable; unions overlay per-opcode operands              | Some ops need `SQE128`/`CQE32`; opaque unions are error-prone for hand-coders       |
| `user_data` is the only SQE↔CQE correlation                | Maximally flexible; kernel never interprets it                                       | App owns lifetime + multishot fan-out bookkeeping                                   |
| `IORING_FEAT_NODROP` overflow backlog                      | Losing an I/O completion is catastrophic; near-guarantee delivery                    | Kernel must hold a backlog list and signal `IORING_SQ_CQ_OVERFLOW`                  |
| SQPOLL kernel thread                                       | Remove submission syscalls entirely for high-IOPS workloads                          | A dedicated CPU is spent polling; idle-wakeup handshake required                    |
| IOPOLL / HYBRID busy-poll completions                      | Cut interrupt latency on fast NVMe storage                                           | Spins CPU; restricted to `O_DIRECT` pollable devices                                |
| TASKRUN / `DEFER_TASKRUN` / `SINGLE_ISSUER` knobs          | Eliminate IPIs and spurious wakeups; batch completion processing                     | App must promise single-issuer and explicitly drive completions                     |
| io-wq offload + fast-poll                                  | Handle genuinely blocking ops without stalling the submitter                         | Worker threads cost memory/scheduling; pool needs tuning under load                 |
| Resource registration (fixed files/buffers, regions)       | Remove repeated per-I/O page-pinning and fd refcount overhead                        | Up-front setup; pinned memory; re-registration on changes                           |

---

## Sources

- [io_uring(7) — Linux manual page][io_uring7]
- [io_uring_setup(2) — Linux manual page][setup2]
- [io_uring_enter(2) — Linux manual page][enter2]
- [io_uring_register(2) — Linux manual page][register2]
- [Linux kernel `io_uring/` source tree][linux-io_uring]
- [UAPI header `include/uapi/linux/io_uring.h`][uapi]
- [liburing — user-space library][liburing]
- ["Efficient IO with io_uring" (Jens Axboe, kernel.dk)][kernel-dk]
- [The rapid growth of io_uring (LWN)][lwn-growth]
- [io_uring — Wikipedia (history / merge in 5.1)][wikipedia]
- [Features & Flags (companion)][features]
- [io_uring Timeline (companion)][timeline]
- [Opcodes Reference (companion)][opcodes]
- [Async I/O Techniques (survey)][techniques]
- [Tokio (sibling)][tokio]
- [Eio — effects-based I/O over io_uring (effect-system corpus)][eio]

<!-- References -->

[features]: ./features.md
[timeline]: ./timeline.md
[opcodes]: ./opcodes-reference.md
[techniques]: ../techniques.md
[tokio]: ../tokio.md
[eio]: ../../algebraic-effects/ocaml-eio.md
[io_uring7]: https://man7.org/linux/man-pages/man7/io_uring.7.html
[setup2]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[enter2]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[register2]: https://man7.org/linux/man-pages/man2/io_uring_register.2.html
[linux-io_uring]: https://github.com/torvalds/linux/tree/master/io_uring
[uapi]: https://github.com/torvalds/linux/blob/master/include/uapi/linux/io_uring.h
[liburing]: https://github.com/axboe/liburing
[kernel-dk]: https://kernel.dk/io_uring.pdf
[lwn-growth]: https://lwn.net/Articles/810414/
[wikipedia]: https://en.wikipedia.org/wiki/Io_uring
