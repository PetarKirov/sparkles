# io_uring — Features by Semantic Area

A semantic catalog of the `io_uring` submission/registration surface, organized by capability rather than by opcode number. Each area states what it is, the concrete SQEs / `IOSQE_*` flags / `IORING_REGISTER_*` ops that drive it, the kernel source file(s) that implement it, and why it matters when building an event loop. For the flat opcode and register-op tables see [`./opcodes-reference.md`](./opcodes-reference.md); for the "since Linux vX.Y" provenance of every flag see [`./timeline.md`](./timeline.md). The architectural model (reactor vs. proactor, the SQ/CQ rings, task-work delivery) is covered in [`./index.md`](./index.md).

> **Scope and ground truth.** Type names, struct fields, and flag spellings in this document are quoted verbatim from a `v7.1-rc6` Linux source tree (`linux/io_uring/*` and `linux/include/uapi/linux/io_uring.h`) and a post-2.14 `liburing` checkout. Version markers ("since Linux 6.x") are cross-checked against liburing man pages and Jens Axboe's per-release update notes — see [Sources](#sources). Where a feature is brand new (kernel 6.16 / 7.x), it is flagged as such; an event loop targeting a stable distro kernel must probe (`IORING_REGISTER_PROBE` / `IORING_REGISTER_QUERY`) rather than assume.

The reader's mental model should be: `io_uring` is **two channels**. The _submission channel_ is the SQE — a fixed 64-byte (or 128-byte) struct whose 80-byte tail is a union reinterpreted per opcode (`linux/include/uapi/linux/io_uring.h:32`, `struct io_uring_sqe`). The _control channel_ is `io_uring_register(2)` — a multiplexed syscall (`linux/io_uring/register.c:739`, `__io_uring_register`) that mutates ring-wide state: fixed resource tables, buffer groups, restrictions, clocks, NAPI, BPF filters. Most "features" below live on exactly one of these two channels, and the most powerful ones (fixed buffers, provided-buffer rings, zero-copy) span both: you `register` the resource once, then reference it by index from many SQEs.

---

## Registered / fixed files and buffers

### What it is

Per-request `fget`/`fput` reference counting and per-request page pinning (`get_user_pages`) are pure overhead when the same file or buffer is used thousands of times. **Registered (a.k.a. fixed) resources** pre-pin the cost once: the application hands the kernel an array of fds or `iovec`s, and SQEs thereafter reference them by a small integer index instead of by fd or pointer. This is the single most important latency optimization for a busy event loop — it removes the file-table lock and the page-table walk from the hot path.

### SQEs, flags, and register ops

| Mechanism           | API surface                                                                           | Notes                                                                                                                                                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fixed files         | `IORING_REGISTER_FILES` (legacy), `IORING_REGISTER_FILES2` (tagged)                   | Reference with `IOSQE_FIXED_FILE` in `sqe->flags`; `sqe->fd` becomes a table index.                                                                                                                                                                                                    |
| Fixed file update   | `IORING_REGISTER_FILES_UPDATE` / `..._UPDATE2`, or `IORING_OP_FILES_UPDATE` (in-band) | Replace slots without re-registering the whole table. `IORING_REGISTER_FILES_SKIP` (`-2`) leaves a slot untouched.                                                                                                                                                                     |
| Fixed buffers       | `IORING_REGISTER_BUFFERS` / `IORING_REGISTER_BUFFERS2` (tagged)                       | Reference via `IORING_OP_READ_FIXED` / `WRITE_FIXED` with `sqe->buf_index`.                                                                                                                                                                                                            |
| Buffer update       | `IORING_REGISTER_BUFFERS_UPDATE`                                                      | Hot-swap individual fixed-buffer slots.                                                                                                                                                                                                                                                |
| Sparse registration | `IORING_RSRC_REGISTER_SPARSE` flag in `struct io_uring_rsrc_register`                 | Register an all-empty table of size `nr`; fill slots later. Avoids passing an array of `-1` fds.                                                                                                                                                                                       |
| Resource tags       | `tags` field of `struct io_uring_rsrc_register` / `io_uring_rsrc_update2`             | A `u64` per slot; when the resource is removed/replaced, a CQE carrying the tag is posted, so the app knows when it is safe to reuse the underlying object. Gated by `IORING_FEAT_RSRC_TAGS`.                                                                                          |
| Auto-slot range     | `IORING_REGISTER_FILE_ALLOC_RANGE` (`struct io_uring_file_index_range`)               | Constrain which fixed-file slots `IORING_FILE_INDEX_ALLOC` (`~0U`) may auto-allocate into, so ops like `openat`/`accept` that return a direct descriptor stay inside an app-reserved band.                                                                                             |
| Clone buffers       | `IORING_REGISTER_CLONE_BUFFERS` (`struct io_uring_clone_buffers`)                     | Share a _source_ ring's already-pinned buffer table into the current ring without re-pinning pages. `src_off`/`dst_off`/`nr` clone a sub-range; `IORING_REGISTER_SRC_REGISTERED` treats `src_fd` as a registered ring fd; `IORING_REGISTER_DST_REPLACE` overwrites existing dst slots. |
| Vectored fixed RW   | `IORING_OP_READV_FIXED` / `WRITEV_FIXED`                                              | Scatter/gather _into_ a registered buffer: the `iovec` segments must all fall within one fixed buffer (`io_prep_readv_fixed`, `io_prep_writev_fixed` in `rw.c`). Combines the registered-buffer fast path with vectored I/O.                                                           |

### Kernel source

- `linux/io_uring/rsrc.c` — registration core. `io_sqe_files_register` (`rsrc.c:529`) honors `IORING_RSRC_REGISTER_SPARSE` ("allow sparse sets", `rsrc.c:557`); `io_sqe_buffers_register` (`rsrc.c:861`); `io_register_clone_buffers` (`rsrc.c:1261`) → `io_clone_buffers` (`rsrc.c:1149`); the SPARSE flag is validated at `rsrc.c:396`.
- `linux/io_uring/filetable.c` — the fixed-file slot table and `IORING_REGISTER_FILE_ALLOC_RANGE` (`io_register_file_alloc_range`).
- `linux/io_uring/rw.c` — `io_read_fixed` (`rw.c:1222`), `io_write_fixed` (`rw.c:1233`), `io_prep_readv_fixed` (`rw.c:426`), `io_prep_writev_fixed` (`rw.c:436`).

### Why it matters for an event loop

A proactor that re-registers nothing pays `fget`/`fput` plus a GUP on every single op. Registering the listening/connected sockets and a slab of I/O buffers up front turns each subsequent SQE into a pointer-free index lookup. Resource _tags_ give the loop a safe-reclaim signal, and _sparse_ + _FILE_ALLOC_RANGE_ let `accept`/`open` return **direct descriptors** that never enter the process fd table at all — see [FIXED_FD_INSTALL](#fixed_fd_install) for moving a direct descriptor back into the regular table when an external API needs a real fd. Compare Glommio's and Tokio's buffer-pool strategies in [`../glommio.md`](../glommio.md) and [`../tokio.md`](../tokio.md).

---

## Provided buffers and buffer rings

### What it is

For receive paths the application does not know _which_ connection will have data next, so pre-assigning a buffer per in-flight `recv` wastes memory. **Provided buffers** invert ownership: the app donates a pool of buffers to a _buffer group_ (`bgid`), and the kernel picks one only at the moment data actually arrives, returning the chosen buffer ID in `cqe->flags >> IORING_CQE_BUFFER_SHIFT`. The modern form is a **buffer ring** — a mmap'd `struct io_uring_buf_ring` the app fills lock-free, eliminating the per-buffer `IORING_OP_PROVIDE_BUFFERS` SQE.

### SQEs, flags, and register ops

| Mechanism                    | API surface                                                                             | Notes                                                                                                                        |
| ---------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Classic provide/remove       | `IORING_OP_PROVIDE_BUFFERS`, `IORING_OP_REMOVE_BUFFERS`                                 | The original (5.7) SQE-driven pool. Superseded by rings for hot paths.                                                       |
| Buffer ring                  | `IORING_REGISTER_PBUF_RING` / `IORING_UNREGISTER_PBUF_RING` (`struct io_uring_buf_reg`) | App-managed ring of `struct io_uring_buf` entries; the ring `tail` is advanced by the app, `head` by the kernel.             |
| Buffer selection             | `IOSQE_BUFFER_SELECT` flag + `sqe->buf_group`                                           | Tells an op (recv, read, …) to draw from a group instead of using `sqe->addr`.                                               |
| Kernel-allocated ring memory | `IOU_PBUF_RING_MMAP` flag                                                               | Kernel allocates the ring; app `mmap`s at `IORING_OFF_PBUF_RING \| (bgid << IORING_OFF_PBUF_SHIFT)`.                         |
| Incremental consumption      | `IOU_PBUF_RING_INC` flag                                                                | A single large buffer is consumed _partially_ across many CQEs.                                                              |
| Partial-completion marker    | `IORING_CQE_F_BUF_MORE` in `cqe->flags`                                                 | Set when an INC buffer is not yet exhausted; the same `bid` will appear in a later CQE, continuing where it left off.        |
| Group status query           | `IORING_REGISTER_PBUF_STATUS` (`struct io_uring_buf_status`)                            | Reads back the kernel-side `head` for a `buf_group` — lets the app reconcile how many buffers are still owned by the kernel. |
| Minimum-left hint            | `min_left` field of `struct io_uring_buf_reg`                                           | Lower bound the kernel keeps before refusing to start a multishot op, avoiding ping-pong.                                    |

### Incremental consumption in detail

With `IOU_PBUF_RING_INC` (Linux 6.12), the app registers a few very large buffers rather than many small ones. Each completion of a given buffer ID continues from where the previous one stopped; the kernel advances an internal offset (`io_kbuf_inc_commit` in `kbuf.c:35` walks the donated length, writing back `buf->addr += this_len` and `buf->len -= this_len`). While the buffer still has room, the CQE carries `IORING_CQE_F_BUF_MORE`; only when it is exhausted does the buffer ID return to the app's control. For any _non_-incremental ring, every completion that reports a buffer ID hands that buffer fully back. The header documents this precisely at `io_uring.h:520` (`IORING_CQE_F_BUF_MORE`) and `io_uring.h:889` (`IOU_PBUF_RING_INC`).

### Kernel source

- `linux/io_uring/kbuf.c` — `struct io_uring_buf_ring` plumbing, `io_ring_head_to_buf` macro (`kbuf.c:24`), `io_kbuf_inc_commit` (`kbuf.c:35`), and `MAX_BIDS_PER_BGID = 1 << 16` (`kbuf.c:21`, the 16-bit BID limit).
- `linux/include/uapi/linux/io_uring.h:857` — `struct io_uring_buf`, `io_uring_buf_ring`, `io_uring_buf_reg`, `io_uring_buf_status`, and the `io_uring_register_pbuf_ring_flags` enum.

### Why it matters for an event loop

Buffer rings are _the_ idiom for high-fan-in servers: combined with [multishot recv](#multishot-operations) the loop arms one SQE per socket and lets the kernel deliver data into freshly-picked buffers indefinitely, with no userspace round-trip to re-provide memory. Incremental consumption further cuts the buffer count for streaming reads. liburing's `proxy.c` example drives multishot recv off a buffer ring (`io_uring_buf_ring`). See [`liburing/examples/proxy.c`].

---

## Multishot operations

### What it is

A **multishot** SQE is armed once and produces _many_ CQEs over its lifetime, each marked `IORING_CQE_F_MORE` to tell the app the originating SQE is still live. When `IORING_CQE_F_MORE` is finally clear, the operation has terminated (error, EOF, or buffer exhaustion). This amortizes submission cost to near-zero for repetitive events — the central reason `io_uring` can out-throughput an epoll loop on accept-heavy or recv-heavy workloads.

### Multishot-capable ops

| Op / flag                                              | Trigger               | Per-CQE payload                                                          |
| ------------------------------------------------------ | --------------------- | ------------------------------------------------------------------------ |
| `IORING_OP_POLL_ADD` + `IORING_POLL_ADD_MULTI`         | Readiness change      | The poll mask in `cqe->res`; level vs. edge via `IORING_POLL_ADD_LEVEL`. |
| `IORING_OP_ACCEPT` + `IORING_ACCEPT_MULTISHOT`         | New connection        | A new connected fd (or a direct descriptor) per CQE.                     |
| `IORING_OP_RECV` / `RECVMSG` + `IORING_RECV_MULTISHOT` | Inbound data          | Bytes received; pairs with `IOSQE_BUFFER_SELECT` + a buffer ring.        |
| `IORING_OP_READ_MULTISHOT`                             | File/pipe readable    | Repeated reads into provided buffers (`io_read_mshot`, `rw.c:1040`).     |
| `IORING_OP_TIMEOUT` + `IORING_TIMEOUT_MULTISHOT`       | Each interval elapses | A periodic tick; `off` is the desired completion count.                  |
| `IORING_OP_URING_CMD` + `IORING_URING_CMD_MULTISHOT`   | Driver-defined        | passthrough multishot; requires buffer select.                           |

### Kernel source

- `linux/io_uring/poll.c` — `__io_arm_poll_handler` (`poll.c:552`); multishot reposts a CQE with `IORING_CQE_F_MORE` at `poll.c:305` (`io_req_post_cqe(req, mask, IORING_CQE_F_MORE)`).
- `linux/io_uring/net.c` — `io_recv`, `io_recvmsg`, `io_accept` honor their multishot flags; `IORING_ACCEPT_MULTISHOT` is defined at `io_uring.h:456`.
- `linux/io_uring/timeout.c` — `IORING_TIMEOUT_MULTISHOT` handling (`timeout.c:85`, `timeout.c:99`).
- `linux/io_uring/rw.c` — `io_read_mshot` / `io_read_mshot_prep` (`rw.c:450`, `rw.c:1040`).

### Why it matters

Multishot is what turns `io_uring` from "batched syscalls" into a genuine **event source**. One armed `ACCEPT_MULTISHOT` SQE replaces an `accept` loop; one `RECV_MULTISHOT` + buffer ring replaces an epoll-`recv` dance. The loop's steady-state submission rate drops toward zero — it only re-arms when an op terminates. This is the closest `io_uring` gets to the green-thread "park until ready" model of Go's netpoller ([`../go-netpoller.md`](../go-netpoller.md)) or Loom ([`../../algebraic-effects/java-loom.md`](../../algebraic-effects/java-loom.md)), while staying completion-based. See [`liburing/man/io_uring_multishot.7`].

---

## SQPOLL, IOPOLL, HYBRID_IOPOLL, and NAPI busy-poll

### What it is

Four orthogonal polling strategies, each trading CPU for latency in a different place:

- **SQPOLL** — a kernel thread (`IORING_SETUP_SQPOLL`) drains the SQ ring on the app's behalf, so submission needs no `io_uring_enter(2)` syscall at all in steady state.
- **IOPOLL** — for `O_DIRECT` block I/O on a polled queue (`IORING_SETUP_IOPOLL`), completions are _polled_ from the device rather than interrupt-driven; the app reaps with `io_uring_enter(GETEVENTS)`.
- **HYBRID_IOPOLL** — `IORING_SETUP_HYBRID_IOPOLL` sleeps for part of the expected completion time before busy-polling, recovering most of IOPOLL's latency at a fraction of its CPU.
- **NAPI busy-poll** — `IORING_REGISTER_NAPI` arms network-stack busy polling so a blocking wait spins in `napi_busy_loop` instead of sleeping, shaving interrupt and wakeup latency off the receive path.

### Flags and register ops

| Strategy      | Setup flag / register op                                                         | Knobs                                                                                                                                                               |
| ------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SQPOLL        | `IORING_SETUP_SQPOLL`; `IORING_SETUP_SQ_AFF` + `sq_thread_cpu`; `sq_thread_idle` | `IORING_SQ_NEED_WAKEUP` in the SQ flags tells the app when the poller has parked and needs `IORING_ENTER_SQ_WAKEUP`.                                                |
| IOPOLL        | `IORING_SETUP_IOPOLL`                                                            | Only valid for ops with `.iopoll = 1` in `opdef.c`.                                                                                                                 |
| Hybrid IOPOLL | `IORING_SETUP_HYBRID_IOPOLL` (bit 17)                                            | Layered on IOPOLL.                                                                                                                                                  |
| NAPI          | `IORING_REGISTER_NAPI` / `IORING_UNREGISTER_NAPI` (`struct io_uring_napi`)       | `busy_poll_to` (µs, capped at 10000 → ns at `napi.c:290`), `prefer_busy_poll`, and a tracking strategy: `IO_URING_NAPI_TRACKING_DYNAMIC` / `_STATIC` / `_INACTIVE`. |

### Kernel source

- `linux/io_uring/sqpoll.c` — `io_sq_thread` (`sqpoll.c:293`), park/unpark (`io_sq_thread_park`, `sqpoll.c:49`), the per-ctx `sq_thread_idle` aggregation (`sqpoll.c:95`).
- `linux/io_uring/napi.c` — `io_register_napi` (`napi.c:304`); busy-loop end condition `io_napi_busy_loop_should_end` (`napi.c:150`); the µs→ns conversion and 10 ms cap at `napi.c:290`. The `io_uring_napi` struct and op/tracking enums live at `io_uring.h:919`–`953`.

### Why it matters

SQPOLL is the headline "syscall-free" mode — at the cost of a dedicated, busy-spinning core. NAPI busy-poll is the network-latency analogue and is what lets an `io_uring` server beat a `recvmsg`-on-epoll server on p99 under load (see `napi-busy-poll-server.c`). Hybrid IOPOLL is the pragmatic default for NVMe-class storage where pure IOPOLL's spin cost is unjustified. An event-loop author must treat these as mutually-constrained: SQPOLL forbids `IORING_SETUP_SQ_REWIND`, and `DEFER_TASKRUN`-style single-issuer modes interact with how completions are delivered. See [`liburing/examples/napi-busy-poll-server.c`].

---

## Zero-copy send and receive

### Zero-copy send (`SEND_ZC` / `SENDMSG_ZC`)

`IORING_OP_SEND_ZC` and `IORING_OP_SENDMSG_ZC` (kernel 6.0) hand the network stack the _user pages directly_ via `MSG_ZEROCOPY` semantics rather than copying into a kernel skb. Because the kernel must keep those pages pinned until the NIC has transmitted them, **completion is split in two**:

1. The ordinary CQE reports how many bytes were accepted into the send queue.
2. A second **notification CQE**, flagged `IORING_CQE_F_NOTIF`, fires later, telling the app the buffer is finally free to reuse.

The notification machinery is `struct io_notif_data` (`notif.c`), built atop the stack's `ubuf_info` ref-counted zerocopy callback. `IORING_SEND_ZC_REPORT_USAGE` asks the kernel to report, in the notif CQE's `res`, whether zerocopy actually happened — `IORING_NOTIF_USAGE_ZC_COPIED` (bit 31) means the stack fell back to copying (small payloads aren't worth pinning). `IORING_RECVSEND_FIXED_BUF` sends from a _registered_ buffer; `IORING_SEND_VECTORIZED` (`net.c:379`, `net.c:403`) lets `SEND[_ZC]` take an `iovec`.

### Zero-copy receive (`RECV_ZC` + ZCRX)

`IORING_OP_RECV_ZC` plus the **ZCRX interface-queue registration** `IORING_REGISTER_ZCRX_IFQ` (kernel 6.15) removes the kernel→user copy on the _receive_ side. The app pre-registers a memory area and a refill ring against a specific NIC hardware RX queue; the driver DMAs incoming packets straight into that area, and `RECV_ZC` completions point the app at the data in place. Completed regions are returned to the kernel via the refill ring (`struct io_uring_zcrx_rqe`).

| Concept            | Type / op                                                   | Source                                                      |
| ------------------ | ----------------------------------------------------------- | ----------------------------------------------------------- |
| ifq registration   | `IORING_REGISTER_ZCRX_IFQ` + `struct io_uring_zcrx_ifq_reg` | `zcrx.c`, `include/uapi/linux/io_uring/zcrx.h:73`           |
| Memory area        | `struct io_uring_zcrx_area_reg` (`area_ptr`)                | `io_zcrx_create_area`, `zcrx.c:440`                         |
| Refill-queue entry | `struct io_uring_zcrx_rqe`                                  | `zcrx.h:15`                                                 |
| Completion entry   | `struct io_uring_zcrx_cqe`                                  | `zcrx.h:21`                                                 |
| Aux config         | `IORING_REGISTER_ZCRX_CTRL` (`enum zcrx_ctrl_op`)           | `register.c:948`                                            |
| The recv op        | `IORING_OP_RECV_ZC`                                         | `io_recvzc` (`net.c:1283`), `io_recvzc_prep` (`net.c:1255`) |
| DMABUF area        | `IORING_ZCRX_AREA_DMABUF`                                   | `zcrx.h:39` (DMABUF support extended in 6.16)               |

### Kernel source

- `linux/io_uring/notif.c` — `io_notif_tw_complete` (`notif.c:15`) sets `IORING_NOTIF_USAGE_ZC_COPIED` (`notif.c:31`) and accounts pinned pages.
- `linux/io_uring/net.c` — a shared `io_sendmsg_zc` (`net.c:1488`) issues both `IORING_OP_SEND_ZC` and `IORING_OP_SENDMSG_ZC` (see `opdef.c`; both prep via `io_send_zc_prep`, `net.c:1335`), `io_send_zc_import` (`net.c:1458`), cleanup `io_send_zc_cleanup` (`net.c:1318`).
- `linux/io_uring/zcrx.c` — the whole ifq/area/page-pool provider (`io_zcrx_ifq_alloc`, `zcrx.c:524`).
- Flags: `IORING_CQE_F_NOTIF` (`io_uring.h:541`), `IORING_NOTIF_USAGE_ZC_COPIED` (`io_uring.h:451`), `IORING_SEND_ZC_REPORT_USAGE` (`io_uring.h:440`).

### Why it matters

Zero-copy is where `io_uring` decisively diverges from epoll: epoll can tell you a socket is readable, but you still `recv` into a kernel buffer and copy. ZCRX cuts the copy entirely for line-rate ingest, and `SEND_ZC` does the same for egress — at the cost of a **two-phase completion model** the event loop must understand (a send "completes" twice). Designs that hide this (Tokio, Seastar — [`../seastar.md`](../seastar.md)) must keep the buffer alive until the `F_NOTIF` CQE. See [`liburing/examples/send-zerocopy.c`] and [`liburing/examples/zcrx.c`], and the kernel's [io_uring zero copy Rx][zcrx-doc] document.

---

## Linked SQEs, drains, and link timeouts

### What it is

`io_uring` lets the app express _ordering and dependency_ between SQEs without round-tripping through userspace. The three primitives are **drains** (run after everything in-flight), **links** (run this chain in order), and **link timeouts** (a watchdog attached to the previous link).

### Flags and ops

| Primitive    | Flag / op                | Semantics                                                                                                                                                |
| ------------ | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Drain        | `IOSQE_IO_DRAIN`         | This SQE waits until all previously-submitted requests complete before starting; later SQEs wait for it. A full pipeline barrier.                        |
| Soft link    | `IOSQE_IO_LINK`          | The next SQE starts only after this one succeeds. On failure the rest of the chain is cancelled with `-ECANCELED`.                                       |
| Hard link    | `IOSQE_IO_HARDLINK`      | Like a link, but a _failure_ of one element does **not** break the chain — successors still run.                                                         |
| Link timeout | `IORING_OP_LINK_TIMEOUT` | A timeout SQE that, when linked _after_ another op, cancels that op if it does not complete in time. `IORING_LINK_TIMEOUT_UPDATE` modifies an armed one. |

### Kernel source

- Flags: `IOSQE_IO_DRAIN` / `IO_LINK` / `IO_HARDLINK` enumerated at `io_uring.h:143` (`enum io_uring_sqe_flags_bit`).
- `linux/io_uring/timeout.c` — `io_link_timeout_fn` (`timeout.c:401`) fires the watchdog; clock selection via `io_flags_to_clock` (`timeout.c:39`), wrapped by `io_timeout_get_clock` (`timeout.c:434`).

### Why it matters

Links let the loop fuse `accept → recv`, `connect → send`, or `openat → read → close` into one submission, so a whole protocol step costs one `io_uring_enter`. Crucially, **a direct-descriptor `accept` linked to a `recv`** never surfaces the fd to userspace at all. The trade-off is rigidity: a link chain is a fixed DAG decided at submission time — it cannot branch on a result. Higher-level effect systems express the same dependency dynamically instead (see [`../../algebraic-effects/ocaml-eio.md`](../../algebraic-effects/ocaml-eio.md)). See [`liburing/man/io_uring_linked_requests.7`].

---

## `msg_ring` and registered ring fds

### What it is

`IORING_OP_MSG_RING` (kernel 5.18) lets one ring **post a completion onto another ring** — the inter-ring IPC primitive. It carries either a data payload or a _file descriptor_. Combined with **registered ring fds** it underpins multi-threaded designs where each thread owns a ring but they must hand work to one another.

### Flags and ops

| Mechanism           | API                                                       | Notes                                                                                                                                                                            |
| ------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Send data           | `IORING_OP_MSG_RING` + `IORING_MSG_DATA`                  | `sqe->len` arrives as the target CQE's `res`, `off` as its `user_data`.                                                                                                          |
| Send fd             | `IORING_OP_MSG_RING` + `IORING_MSG_SEND_FD`               | Installs a (registered) fd into the target ring's fixed-file table.                                                                                                              |
| Suppress target CQE | `IORING_MSG_RING_CQE_SKIP`                                | Wake/interrupt the target without a visible CQE (data mode only).                                                                                                                |
| Pass flags through  | `IORING_MSG_RING_FLAGS_PASS`                              | Forward `sqe->file_index` into the target's `cqe->flags`.                                                                                                                        |
| Ringless send       | `IORING_REGISTER_SEND_MSG_RING`                           | Post a `MSG_RING` _without owning a ring_ — register-channel variant for senders that have no SQ.                                                                                |
| Register ring fd    | `IORING_REGISTER_RING_FDS` / `IORING_UNREGISTER_RING_FDS` | Register the ring's own fd so `io_uring_enter` need not re-`fget` it; max 16. `IORING_SETUP_REGISTERED_FD_ONLY` skips the real fd entirely. Gated by `IORING_FEAT_REG_REG_RING`. |

### Kernel source

- `linux/io_uring/msg_ring.c` — `io_msg_ring` dispatch (`msg_ring.c:284`) switches `IORING_MSG_DATA` → `io_msg_ring_data` (`msg_ring.c:148`) / `IORING_MSG_SEND_FD` → `io_msg_send_fd` (`msg_ring.c:234`); the ringless path `io_uring_sync_msg_ring` (`msg_ring.c:320`) rejects `MSG_SEND_FD` (`msg_ring.c:325`). Remote posting via `io_msg_data_remote` (`msg_ring.c:96`).
- Flags: `enum io_uring_msg_ring_flags` and `IORING_MSG_RING_*` at `io_uring.h:463`–`476`.

### Why it matters

`msg_ring` is `io_uring`'s answer to "how do N event loops talk to each other" — a work-stealing or sharded-acceptor design (think one acceptor thread fanning connections to worker rings) needs exactly this. Registered ring fds remove the per-`enter` file-table contention that otherwise dominates threaded programs. Glommio and Monoio ([`../glommio.md`](../glommio.md), [`../monoio.md`](../monoio.md)) build their thread-per-core models on these.

---

## Futex operations

### What it is

`IORING_OP_FUTEX_WAIT` / `FUTEX_WAKE` / `FUTEX_WAITV` (kernel 6.7) bring userspace futexes into the completion model: instead of a thread blocking in `futex(2)`, the ring asynchronously waits and posts a CQE on wake. This lets a single event loop multiplex _both_ I/O readiness and lock/condvar-style synchronization without a dedicated blocking thread.

### Flags and ops

| Op                      | Purpose                                           | Flag space                                                                                                 |
| ----------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `IORING_OP_FUTEX_WAIT`  | Async wait, like `FUTEX_WAIT_BITSET`              | `sqe->futex_flags` validated against `FUTEX2_VALID_MASK` (`futex.c:141`).                                  |
| `IORING_OP_FUTEX_WAKE`  | Wake N waiters                                    | Same flag space.                                                                                           |
| `IORING_OP_FUTEX_WAITV` | Wait on a _vector_ of futexes; first to fire wins | Backed by `struct io_futexv_data` (`futex.c:30`); claimed atomically via `io_futexv_claim` (`futex.c:85`). |

### Kernel source

- `linux/io_uring/futex.c` — `io_futex_prep` (`futex.c:127`), `io_futexv_prep` (`futex.c:174`), `io_futexv_wait` (`futex.c:223`); wake callbacks `io_futex_wake_fn` (`futex.c:210`) and the vectored `io_futex_wakev_fn` (`futex.c:157`).
- Flag union member `futex_flags` at `io_uring.h:75`.

### Why it matters

Futex-on-ring is the bridge between the I/O world and the _concurrency-primitive_ world. An event loop can now wait on a condition variable or an async mutex as just another SQE, so a fiber blocked on a lock and a fiber blocked on a socket sit in the same CQ. This is the building block several async runtimes use for cross-task signaling; cf. how effect-based runtimes model blocking ([`../effects-and-event-loops.md`](../effects-and-event-loops.md)). See LWN's [futex wait/wake][lwn-futex] writeup.

---

## Cancellation

### What it is

Two cancellation surfaces. **Asynchronous** cancellation is an SQE (`IORING_OP_ASYNC_CANCEL`) that itself completes via the CQ. **Synchronous** cancellation is a register op (`IORING_REGISTER_SYNC_CANCEL`) that blocks the caller — useful at shutdown when you have no live ring to reap from. Both share a rich match-flag vocabulary.

### Match flags (`sqe->cancel_flags` / `struct io_uring_sync_cancel_reg`)

| Flag                           | Matches by                                                           |
| ------------------------------ | -------------------------------------------------------------------- |
| `IORING_ASYNC_CANCEL_ALL`      | Cancel _every_ request matching the key, not just the first.         |
| `IORING_ASYNC_CANCEL_FD`       | The request's file descriptor rather than `user_data`.               |
| `IORING_ASYNC_CANCEL_FD_FIXED` | As above, but `fd` is a registered/fixed descriptor.                 |
| `IORING_ASYNC_CANCEL_ANY`      | Any in-flight request (mass cancel).                                 |
| `IORING_ASYNC_CANCEL_USERDATA` | `user_data` — the default key when no other is given.                |
| `IORING_ASYNC_CANCEL_OP`       | The opcode (added with the sync API), so you can cancel "all recvs". |

### Kernel source

- `linux/io_uring/cancel.c` — async path `io_async_cancel_prep` (`cancel.c:140`) → `io_async_cancel` (`cancel.c:210`) → `__io_async_cancel` (`cancel.c:174`); single-request `io_async_cancel_one` (`cancel.c:78`); sync path `io_sync_cancel` (`cancel.c:268`) → `__io_sync_cancel` (`cancel.c:247`), with a timeout loop so a sync cancel can wait for the request to actually die. Opcode match at `cancel.c:56` (`req->opcode != cd->opcode`).
- Flags: `io_uring.h:396`–`401`; `struct io_uring_sync_cancel_reg` at `io_uring.h:1007`.

### Why it matters

Structured concurrency (timeouts, "cancel the loser of a race", graceful shutdown) is only as good as the cancellation primitive underneath it. `CANCEL_FD` lets a loop tear down _all_ operations on a closing socket in one SQE; `CANCEL_OP` + `CANCEL_ALL` enables policy-level cancellation. The synchronous register variant is the clean way to drain a ring before freeing it. This is the low-level counterpart to the cancellation scopes in Eio and Loom ([`../../algebraic-effects/ocaml-eio.md`](../../algebraic-effects/ocaml-eio.md), [`../../algebraic-effects/java-loom.md`](../../algebraic-effects/java-loom.md)). See [`liburing/man/io_uring_cancelation.7`].

---

## Networking operations

### What it is

A near-complete async socket API: connection setup, data transfer, and teardown all as SQEs, so a server never leaves the ring for networking.

### Op inventory

| Category | Ops                                                                                | Notes                                                                                                         |
| -------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Setup    | `IORING_OP_SOCKET`, `IORING_OP_BIND`, `IORING_OP_LISTEN`, `IORING_OP_CONNECT`      | `SOCKET` can create a _direct descriptor_ (`io_socket`, `net.c:1699`); `BIND`/`LISTEN` are the newest (6.11). |
| Accept   | `IORING_OP_ACCEPT`                                                                 | `IORING_ACCEPT_MULTISHOT`, `IORING_ACCEPT_DONTWAIT`, `IORING_ACCEPT_POLL_FIRST` (`io_uring.h:456`).           |
| Send     | `IORING_OP_SEND`, `IORING_OP_SENDMSG`, `IORING_OP_SEND_ZC`, `IORING_OP_SENDMSG_ZC` | Flags below.                                                                                                  |
| Recv     | `IORING_OP_RECV`, `IORING_OP_RECVMSG`, `IORING_OP_RECV_ZC`                         | Multishot + buffer-select.                                                                                    |
| Teardown | `IORING_OP_SHUTDOWN`                                                               | `io_shutdown` (`net.c:137`).                                                                                  |

### Shared send/recv flags (`sqe->ioprio`)

| Flag                          | Effect                                                                                                                                                                                                         |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IORING_RECVSEND_POLL_FIRST`  | Arm poll _before_ attempting the transfer, skipping a likely-`EAGAIN` first try.                                                                                                                               |
| `IORING_RECV_MULTISHOT`       | Repeated recv completions (`IORING_CQE_F_MORE`).                                                                                                                                                               |
| `IORING_RECVSEND_FIXED_BUF`   | Use a registered buffer (`buf_index`).                                                                                                                                                                         |
| `IORING_RECVSEND_BUNDLE`      | With `IOSQE_BUFFER_SELECT`: grab _as many contiguous buffers as available_ and send/recv them in one op; `cqe->res` is the byte count, starting `bid` in `cqe->flags`. Gated by `IORING_FEAT_RECVSEND_BUNDLE`. |
| `IORING_SEND_VECTORIZED`      | `SEND[_ZC]` takes an `iovec` pointer.                                                                                                                                                                          |
| `IORING_SEND_ZC_REPORT_USAGE` | Report copy-vs-zerocopy in the notif CQE.                                                                                                                                                                      |

Plus `IORING_CQE_F_SOCK_NONEMPTY` (`io_uring.h:540`) — set on a recv CQE when the socket still has more data, so the loop knows to re-arm immediately.

### Kernel source

- `linux/io_uring/net.c` — every op above; `SENDMSG_FLAGS` mask (`net.c:421`) shows which flags `sendmsg` accepts; `BUNDLE` handling at `net.c:439`/`net.c:520`/`net.c:877`; `io_accept`/`io_connect`/`io_bind`/`io_listen` at `net.c:1608`/`1751`/`1844`/`1873`.

### Why it matters

The networking ops are the reason `io_uring` exists for server authors. BUNDLE in particular is a throughput multiplier — one `recv` SQE can drain several buffers' worth of data, and one `send` SQE can flush a whole scatter list, cutting CQE count under bursty load. Compared to the readiness-only model exposed to Go's netpoller or libuv ([`../libuv.md`](../libuv.md)), these are _completion_ ops: the data is already moved when the CQE lands.

---

## File and filesystem operations

### What it is

`io_uring` covers far more than read/write — most of the filesystem syscall surface has an async opcode, so a build tool or storage daemon can stay on the ring for metadata operations too.

### Op inventory

| Category     | Ops                                                                                                              | Source                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Open / close | `IORING_OP_OPENAT`, `OPENAT2`, `CLOSE`, `FIXED_FD_INSTALL`                                                       | `openclose.c` (`io_openat2`, `:123`; `io_close`, `:236`).                                                   |
| Read / write | `READV`, `WRITEV`, `READ`, `WRITE`, `READ_FIXED`, `WRITE_FIXED`, `READV_FIXED`, `WRITEV_FIXED`, `READ_MULTISHOT` | `rw.c`. Optional PI attributes via `IORING_RW_ATTR_FLAG_PI` + `struct io_uring_attr_pi` (`io_uring.h:123`). |
| Sync         | `FSYNC` (`IORING_FSYNC_DATASYNC`), `SYNC_FILE_RANGE`, `FALLOCATE`                                                | `sync.c` (`io_fsync`, `:72`; `io_fallocate`, `:101`).                                                       |
| Splice       | `SPLICE`, `TEE`                                                                                                  | `splice.c`; `SPLICE_F_FD_IN_FIXED` (bit 31) lets `fd_in` be a fixed descriptor (`splice.c:67`).             |
| Metadata     | `STATX`, `FSETXATTR`/`SETXATTR`/`FGETXATTR`/`GETXATTR`                                                           | `statx.c`, `xattr.c`.                                                                                       |
| Namespace    | `RENAMEAT`, `UNLINKAT`, `MKDIRAT`, `SYMLINKAT`, `LINKAT`                                                         | `fs.c`.                                                                                                     |
| Misc         | `FTRUNCATE`, `PIPE`, `FADVISE`, `MADVISE`                                                                        | `truncate.c` (`io_ftruncate`, `:37`), `openclose.c` (`io_pipe`, `:423`), `advise.c`.                        |

### Why it matters

Having `statx`, `renameat`, and `unlinkat` on the ring means a tool like a build system can issue _thousands_ of filesystem ops in a batch with one syscall — the workload that motivates Glommio's storage focus. `READV_FIXED`/`WRITEV_FIXED` (see [registered buffers](#registered--fixed-files-and-buffers)) and `IOPOLL` together give the lowest-latency `O_DIRECT` path available on Linux. `PIPE` returning direct descriptors closes a loop: you can build a pipe, splice through it, and never touch the fd table.

---

## Timeouts and clocks

### What it is

`io_uring` has first-class timers as SQEs, with selectable clock source, absolute/relative modes, multishot ticks, and a ring-wide _minimum wait_ that batches CQ reaping.

### Flags and ops (`sqe->timeout_flags`)

| Flag / feature                                         | Meaning                                                                                                                                                |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `IORING_TIMEOUT_ABS`                                   | `addr` is an absolute deadline, not a relative duration.                                                                                               |
| `IORING_TIMEOUT_BOOTTIME` / `IORING_TIMEOUT_REALTIME`  | Select `CLOCK_BOOTTIME` / `CLOCK_REALTIME` (default monotonic); `IORING_TIMEOUT_CLOCK_MASK` is their union.                                            |
| `IORING_TIMEOUT_MULTISHOT`                             | Periodic timer; `off` = number of ticks (kernel 6.4).                                                                                                  |
| `IORING_TIMEOUT_ETIME_SUCCESS`                         | Report a fired timeout as success rather than `-ETIME`.                                                                                                |
| `IORING_TIMEOUT_UPDATE` / `IORING_LINK_TIMEOUT_UPDATE` | Modify an armed timeout / link-timeout in place.                                                                                                       |
| `IORING_TIMEOUT_IMMEDIATE_ARG`                         | `addr` holds the nanosecond value inline instead of a `timespec` pointer.                                                                              |
| `IORING_REGISTER_CLOCK`                                | Register a `clockid` (`struct io_uring_clock_register`) for the ring's wait path.                                                                      |
| `min_timeout` / `IORING_FEAT_MIN_TIMEOUT`              | Via `io_uring_getevents_arg`/`io_uring_reg_wait` `min_wait_usec`: wait at least this long to _batch_ completions, but no longer than the hard timeout. |

Ops: `IORING_OP_TIMEOUT`, `IORING_OP_TIMEOUT_REMOVE`, `IORING_OP_LINK_TIMEOUT`.

### Kernel source

- `linux/io_uring/timeout.c` — clock dispatch `io_flags_to_clock` (`timeout.c:39`, mapping `BOOTTIME`/`REALTIME`; wrapped by `io_timeout_get_clock` at `timeout.c:434`); `IMMEDIATE_ARG` inline value at `timeout.c:59` (`io_parse_user_time`); flag validation masks at `timeout.c:578`; remove/update at `io_timeout_remove_prep` (`timeout.c:488`).
- Flags `io_uring.h:351`–`360`; `struct io_uring_clock_register` at `io_uring.h:838`; `min_wait_usec` in `io_uring_reg_wait`/`io_uring_getevents_arg` (`io_uring.h:984`, `:997`).

### Why it matters

Every event loop needs timers: I/O deadlines, periodic heartbeats, scheduler quanta. Doing them as SQEs keeps timers in the _same_ completion stream as I/O, so there is one wait point, not two. `min_timeout` is the subtle but high-value knob — it lets a latency-tolerant loop sleep just long enough to coalesce a batch of CQEs, trading a few microseconds of latency for far fewer wakeups. Link timeouts (above) reuse this machinery to bound any other op.

---

## `uring_cmd` passthrough

### What it is

`IORING_OP_URING_CMD` is an _escape hatch_: a device driver or socket implementation defines its own command set, and the SQE carries an opaque payload to it. This is how NVMe passthrough (raw NVMe commands from userspace) and socket-level commands (`SIOCINQ`, `getsockopt`/`setsockopt`, TX timestamping) are exposed without new opcodes.

### Flags and structures

| Mechanism       | API                                                     | Notes                                                                                                                      |
| --------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Command op      | `sqe->cmd_op` + 80-byte inline `sqe->cmd[]`             | Requires `IORING_SETUP_SQE128` (`io_uring.h:115`) for the larger payload.                                                  |
| 128-byte op     | `IORING_OP_URING_CMD128`                                | Dedicated 128-byte passthrough opcode (alongside `NOP128`) for `SQE_MIXED` rings.                                          |
| Fixed buffer    | `IORING_URING_CMD_FIXED`                                | Pass a registered buffer via `buf_index`.                                                                                  |
| Multishot       | `IORING_URING_CMD_MULTISHOT`                            | Repeated completions; needs buffer select; not combinable with `_FIXED` yet.                                               |
| Socket commands | `enum io_uring_socket_op`                               | `SOCKET_URING_OP_SIOCINQ`, `_SIOCOUTQ`, `_GETSOCKOPT`, `_SETSOCKOPT`, `_TX_TIMESTAMP`, `_GETSOCKNAME` (`io_uring.h:1037`). |
| TX timestamps   | `IORING_CQE_F_TSTAMP_HW`, `IORING_TIMESTAMP_TYPE_SHIFT` | HW vs SW timestamp type encoded in `cqe->flags` (`io_uring.h:1050`).                                                       |

### Kernel source

- `linux/io_uring/uring_cmd.c` — `io_uring_cmd_prep` (`uring_cmd.c:184`); cancelable commands via `IORING_URING_CMD_CANCELABLE` and `io_uring_cmd_mark_cancelable` (`uring_cmd.c:101`); completion `__io_uring_cmd_done` (`uring_cmd.c:150`).
- `linux/io_uring/cmd_net.c` — the socket command implementations.
- Flags: `IORING_URING_CMD_FIXED` / `_MULTISHOT` at `io_uring.h:334`.

### Why it matters

`uring_cmd` is what lets `io_uring` reach _outside_ the generic VFS/socket API — userspace NVMe drivers (SPDK-style) and fine-grained socket introspection (`SIOCINQ` to size the next recv, TX timestamps for latency measurement) all flow through it without bloating the opcode enum. For an event loop it means device- and protocol-specific fast paths can be added without a kernel ABI change. The socket-command path is exercised by liburing's test suite (`test/socket-io-cmd.c`, `test/socket-getsetsock-cmd.c`) rather than the `examples/` programs.

---

## FIXED_FD_INSTALL {#fixed_fd_install}

### What it is

`IORING_OP_FIXED_FD_INSTALL` (kernel 6.8) takes a _direct descriptor_ (a fixed-file slot index that never entered the process fd table) and installs it as a **real** numbered fd. It is the inverse of the `IORING_FILE_INDEX_ALLOC` path: you keep everything off the fd table for speed, then materialize a real fd only when handing the object to a non-`io_uring` API.

- Reference the source slot via `IOSQE_FIXED_FILE` + `sqe->fd` (the slot index).
- `IORING_FIXED_FD_NO_CLOEXEC` (`io_uring.h:483`) opts out of marking the new fd `O_CLOEXEC`.
- Kernel: `io_install_fixed_fd_prep` (`openclose.c:275`) and `io_install_fixed_fd` (`openclose.c:305`).

### Why it matters

Direct descriptors are strictly faster (no fd-table lock), so a high-performance loop wants to live in that world. But some libraries demand a real `int fd`. `FIXED_FD_INSTALL` is the bridge that keeps the fast path fast while remaining interoperable — see the [registered files](#registered--fixed-files-and-buffers) discussion of direct descriptors.

---

## epoll integration ops

### What it is

Two ops let `io_uring` and epoll coexist during migration: `IORING_OP_EPOLL_CTL` runs `epoll_ctl(2)` async, and `IORING_OP_EPOLL_WAIT` (kernel 6.15) lets a ring _wait on an epoll instance_ as just another SQE.

- `IORING_OP_EPOLL_CTL` — `io_epoll_ctl` (`epoll.c:51`) calls `do_epoll_ctl` for add/mod/del without blocking the loop.
- `IORING_OP_EPOLL_WAIT` — `io_epoll_wait` (`epoll.c:79`); completes when the epoll set has events.

### Why it matters

These are _bridging_ ops. A large codebase built around an epoll fd (or a library that exposes only an epoll fd) can be folded into an `io_uring` loop incrementally: register the epoll fd, arm `EPOLL_WAIT` as one SQE, and the epoll readiness stream merges into the CQ. It is the pragmatic on-ramp from a reactor design ([`../libuv.md`](../libuv.md)) to a proactor.

---

## Ring lifecycle and introspection

### What it is

The register channel also manages the ring _itself_: resizing, supplying memory, querying capabilities, sandboxing, and identity. These are the operations an event-loop _constructor_ and _capability probe_ use.

### Register ops

| Op                                              | Purpose                                                                                                                                                     | Source / struct                                                                                              |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `IORING_REGISTER_RESIZE_RINGS`                  | Grow/shrink SQ/CQ at runtime without tearing down the ring                                                                                                  | `io_register_resize_rings` (`register.c:498`)                                                                |
| `IORING_REGISTER_MEM_REGION`                    | App supplies a memory region (`struct io_uring_region_desc`) for ring/wait-arg storage; `IORING_MEM_REGION_REG_WAIT_ARG` exposes it as registered wait args | `io_register_mem_region` (`register.c:692`); structs at `io_uring.h:751`/`:765`                              |
| `IORING_REGISTER_QUERY`                         | Introspect capabilities (opcodes, zcrx, SQ/CQ) via `struct io_uring_query_hdr`                                                                              | `query.c`; `IO_URING_QUERY_OPCODES`/`_ZCRX`/`_SCQ` (`query.h:23`)                                            |
| `IORING_REGISTER_PROBE`                         | Legacy capability probe — which opcodes are supported (`struct io_uring_probe`)                                                                             | `register.c:808`; `io_uring.h:805`                                                                           |
| `IORING_REGISTER_RESTRICTIONS`                  | Sandbox: whitelist allowed register-ops, SQE opcodes, and SQE flags before enabling the ring                                                                | `io_uring.h:820`/`:958`; applied while disabled (`IORING_SETUP_R_DISABLED` + `IORING_REGISTER_ENABLE_RINGS`) |
| `IORING_REGISTER_PERSONALITY` / `UNREGISTER`    | Register a credential set; SQEs reference it via `sqe->personality` to act as another identity                                                              | `register.c:814`; `IORING_FEAT_CUR_PERSONALITY`                                                              |
| `IORING_REGISTER_RING_FDS`                      | See [msg_ring section](#msg_ring-and-registered-ring-fds)                                                                                                   | `register.c:867`                                                                                             |
| `IORING_REGISTER_IOWQ_AFF` / `IOWQ_MAX_WORKERS` | Pin / cap the io-wq worker pool (`IO_WQ_BOUND`/`IO_WQ_UNBOUND`)                                                                                             | `register.c:849`/`:861`; `io_uring.h:733`                                                                    |

### Capability probing

The right pattern for portable code is `IORING_REGISTER_QUERY` (new) falling back to `IORING_REGISTER_PROBE`, _plus_ checking the `features` bitmask returned by `io_uring_setup(2)` (`IORING_FEAT_*`, `io_uring.h:630`–`647`). Notable feature bits an event loop should test before relying on a behavior: `IORING_FEAT_NODROP` (CQ never silently drops), `IORING_FEAT_FAST_POLL`, `IORING_FEAT_RSRC_TAGS`, `IORING_FEAT_CQE_SKIP` (for `IOSQE_CQE_SKIP_SUCCESS`), `IORING_FEAT_RECVSEND_BUNDLE`, `IORING_FEAT_MIN_TIMEOUT`, and `IORING_FEAT_REG_REG_RING`.

### Why it matters

`RESIZE_RINGS` means a loop can react to load without dropping connections; `MEM_REGION` enables the registered-wait-argument optimization (passing the wait timeout/sigmask by index instead of by copy each `enter`); `RESTRICTIONS` + `PERSONALITY` are the security story for letting an untrusted plugin submit on a shared ring. `QUERY`/`PROBE` are non-negotiable for any library that targets a range of kernels — the feature set above spans 5.6 → 7.x and **must** be detected, not assumed. See [`./timeline.md`](./timeline.md) for the version map.

---

## BPF filtering

### What it is

`IORING_REGISTER_BPF_FILTER` (very new, kernel 7.x) attaches BPF programs that gate SQE submission: before a request is issued, registered filters run and can _reject_ it. This is a finer-grained, programmable sibling of `IORING_REGISTER_RESTRICTIONS` — instead of a static opcode whitelist, the policy is an attached program.

- Kernel: `linux/io_uring/bpf_filter.c` — `__io_uring_run_bpf_filters` (`bpf_filter.c:57`) returns 0 to _allow_; filters are an RCU-protected list (`struct io_bpf_filter`, `bpf_filter.c:17`); the comment at `bpf_filter.c:3` notes it "Supports SQE opcodes for now."
- Companion: `linux/io_uring/bpf-ops.c` defines the BPF-callable operations.

### Why it matters

For a multi-tenant or sandboxed deployment, BPF filtering lets the host express a dynamic submission policy (rate-limit a tenant's `send_zc`, forbid `uring_cmd` passthrough, log specific opcodes) without patching the kernel. It is bleeding-edge and absent from any stable distro kernel at the time of writing — an event loop must `QUERY`/`PROBE` for `IORING_REGISTER_BPF_FILTER` before use, and treat its absence as the common case.

---

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                                                            | Trade-off                                                                                                                                         |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reference resources (files, buffers) by _index_ after one-time registration | Removes `fget`/`fput` and `get_user_pages` from the per-op hot path — the dominant cost at high IOPS                 | App must manage a slot table and reclaim via tags; registration is a heavier, infrequent control-channel call                                     |
| Buffer rings with kernel-side buffer _selection_                            | Decouples memory from connections; the kernel picks a buffer only when data lands, so N idle sockets cost ~0 buffers | Two-level bookkeeping (head moved by kernel, tail by app); `IORING_CQE_F_BUF_MORE` adds a partial-completion state the app must track             |
| Multishot SQEs (`IORING_CQE_F_MORE`)                                        | One submission yields many completions — submission cost approaches zero for accept/recv-heavy loops                 | A single SQE now has open-ended lifetime and CQ pressure; CQ overflow handling (`IORING_FEAT_NODROP`, `IORING_SETUP_CQSIZE`) becomes load-bearing |
| Split-completion zero-copy send (`F_NOTIF`)                                 | True zero-copy egress requires holding pages until the NIC is done — a second CQE is the honest signal               | App must keep buffers alive past the first CQE; `IORING_NOTIF_USAGE_ZC_COPIED` reveals the stack may have copied anyway for small payloads        |
| Static link chains (`IOSQE_IO_LINK`)                                        | Express `accept→recv`, `connect→send` as one batched submission with no userspace round-trip                         | The dependency DAG is fixed at submit time — cannot branch on a result; dynamic dependencies need userspace orchestration                         |
| `uring_cmd` opaque passthrough                                              | Expose driver/socket-specific commands (NVMe, `getsockopt`, TX timestamps) without growing the opcode enum           | Loses type safety and self-description; needs `SQE128`; capabilities vary per device/driver and must be discovered out-of-band                    |
| Multiplexed `io_uring_register(2)` control channel                          | One syscall for all ring-wide state mutation keeps the SQE union lean and the fast path narrow                       | Register ops are a sprawling, versioned enum (38+ ops at 7.1) that _must_ be probed; new ops appear every release                                 |
| Direct descriptors + `FIXED_FD_INSTALL` bridge                              | Keep fds off the process table for speed, materialize a real fd only when an external API demands one                | Two descriptor namespaces to reason about; mistakes (passing a slot index where a real fd is expected, or vice versa) are easy and silent         |

---

## Sources

- [Linux kernel `io_uring/` source][linux-iou] — the canonical implementation; all function/struct references above are from a `v7.1-rc6` tree (`rsrc.c`, `kbuf.c`, `net.c`, `zcrx.c`, `notif.c`, `futex.c`, `cancel.c`, `timeout.c`, `msg_ring.c`, `sqpoll.c`, `napi.c`, `uring_cmd.c`, `openclose.c`, `epoll.c`, `register.c`, `bpf_filter.c`, `query.c`, `opdef.c`).
- [UAPI header `include/uapi/linux/io_uring.h`][uapi] — every `IORING_*` / `IOSQE_*` flag enum and on-the-wire struct quoted here.
- [io_uring zero copy Rx — kernel documentation][zcrx-doc] — ZCRX ifq/area/refill model.
- [liburing repository][liburing] — man pages and the `examples/` programs (`send-zerocopy.c`, `zcrx.c`, `proxy.c`, `io_uring-cp.c`, `napi-busy-poll-server.c`).
- [io_uring_register(2) man page][reg2] — register-op reference and version notes.
- [io_uring_multishot(7) man page][multishot7] — multishot semantics and `IORING_CQE_F_MORE`.
- [io_uring_register_buf_ring(3) man page][bufring3] — buffer rings and `IOU_PBUF_RING_INC` (since 6.12).
- [io_uring_prep_send_zc(3) man page][sendzc3] — zero-copy send and notification CQEs.
- [io_uring_prep_futex_wait(3) man page][futex3] — futex ops (since 6.7).
- ["What's new with io_uring in 6.11 and 6.12" — liburing wiki][whatsnew] — Jens Axboe's release notes (incremental provided buffers, min-timeout waits, buffer cloning, etc.). Note `IORING_RECVSEND_BUNDLE` is a 6.10 feature, documented separately.
- ["Add io_uring support for futex wait/wake" — LWN][lwn-futex] — design rationale for futex-on-ring.
- ["Zero-copy network transmission with io_uring" — LWN][lwn-zc] — background on the zero-copy send/receive model and notification CQEs.
- Sibling docs: [`./index.md`](./index.md), [`./opcodes-reference.md`](./opcodes-reference.md), [`./timeline.md`](./timeline.md), [`../comparison.md`](../comparison.md), [`../tokio.md`](../tokio.md), [`../glommio.md`](../glommio.md), [`../monoio.md`](../monoio.md), [`../seastar.md`](../seastar.md), [`../libuv.md`](../libuv.md), [`../go-netpoller.md`](../go-netpoller.md), [`../effects-and-event-loops.md`](../effects-and-event-loops.md), [`../../algebraic-effects/ocaml-eio.md`](../../algebraic-effects/ocaml-eio.md), [`../../algebraic-effects/java-loom.md`](../../algebraic-effects/java-loom.md).

<!-- References -->

[linux-iou]: https://github.com/torvalds/linux/tree/master/io_uring
[uapi]: https://github.com/torvalds/linux/blob/master/include/uapi/linux/io_uring.h
[zcrx-doc]: https://docs.kernel.org/networking/iou-zcrx.html
[liburing]: https://github.com/axboe/liburing
[reg2]: https://man7.org/linux/man-pages/man2/io_uring_register.2.html
[multishot7]: https://man7.org/linux/man-pages/man7/io_uring_multishot.7.html
[bufring3]: https://man7.org/linux/man-pages/man3/io_uring_register_buf_ring.3.html
[sendzc3]: https://man7.org/linux/man-pages/man3/io_uring_prep_send_zc.3.html
[futex3]: https://man7.org/linux/man-pages/man3/io_uring_prep_futex_wait.3.html
[whatsnew]: https://github.com/axboe/liburing/wiki/What%27s-new-with-io_uring-in-6.11-and-6.12
[lwn-futex]: https://lwn.net/Articles/934350/
[lwn-zc]: https://lwn.net/Articles/879724/
[liburing/examples/proxy.c]: https://github.com/axboe/liburing/blob/master/examples/proxy.c
[liburing/examples/send-zerocopy.c]: https://github.com/axboe/liburing/blob/master/examples/send-zerocopy.c
[liburing/examples/zcrx.c]: https://github.com/axboe/liburing/blob/master/examples/zcrx.c
[liburing/examples/napi-busy-poll-server.c]: https://github.com/axboe/liburing/blob/master/examples/napi-busy-poll-server.c
[liburing/man/io_uring_multishot.7]: https://github.com/axboe/liburing/blob/master/man/io_uring_multishot.7
[liburing/man/io_uring_linked_requests.7]: https://github.com/axboe/liburing/blob/master/man/io_uring_linked_requests.7
[liburing/man/io_uring_cancelation.7]: https://github.com/axboe/liburing/blob/master/man/io_uring_cancelation.7
