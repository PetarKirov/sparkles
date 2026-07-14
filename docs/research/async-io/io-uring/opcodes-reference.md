# io_uring — Opcode & Flag Reference

A complete lookup table for the `io_uring` UABI: every `IORING_OP_*` opcode, every SQE/CQE/setup/feature/enter flag, the `io_uring_register(2)` opcode space, the per-op flag enums, and the liburing helper surface that builds it all.

**Scope.** This is the reference companion to the [io_uring feature catalog][features] and the [io_uring timeline][timeline]. It enumerates the on-the-wire interface directly from the kernel UABI header and the kernel opcode dispatch table — it is _ground-truth_ rather than narrative. Where the feature/timeline docs explain _why_ and _when_, this doc answers _what is the exact name, value, flag bit, and helper_. Higher-level event loops that drive these primitives — [Tokio][tokio]'s `io-uring` backend, [Glommio][glommio], [Monoio][monoio], [Seastar][seastar], and the effects-based [OCaml Eio][eio] `eio_linux` backend — all bottom out in the symbols tabulated here.

The interface tables below are transcribed from a specific source snapshot:

| Source                                               | Version / commit                                    | Repo-relative path                    |
| ---------------------------------------------------- | --------------------------------------------------- | ------------------------------------- |
| Kernel UABI header (all enums/flags)                 | Linux **v7.1-rc6**                                  | `linux/include/uapi/linux/io_uring.h` |
| Kernel opcode dispatch table (handler/attrs)         | Linux **v7.1-rc6**                                  | `linux/io_uring/opdef.c`              |
| liburing user-space helpers (`prep_*`, `register_*`) | liburing **2.15-dev** (`40999f52`, post-`2.14` tag) | `liburing/src/include/liburing.h`     |

> The interface is append-only and ABI-stable: every value below has the same numeric meaning on every kernel that defines it. Newer kernels add opcodes/flags at the end of each enum; they never renumber existing entries. The "Since" columns give the kernel release that first shipped each symbol (verified against `io_uring_enter(2)`, kernel.dk and LWN — see [Sources](#sources)). A current kernel will reject an unknown opcode with `-EINVAL` and report support via `IORING_REGISTER_PROBE`, so probe rather than assume.

---

## 1. `IORING_OP_*` — submission opcodes

The opcode is `sqe->opcode` (a `__u8`). Values are the ordinal position in `enum io_uring_op` (`io_uring.h:255`). The terminal sentinel is `IORING_OP_LAST`. The kernel maps each opcode to a `prep`/`issue` handler pair in the `io_issue_defs[]` table (`opdef.c:54`) and to a human-readable name + `cleanup`/`fail` hooks in `io_cold_defs[]` (`opdef.c:594`). `io_uring_get_opcode()` (`opdef.c:852`) returns the name; `io_uring_op_supported()` (`opdef.c:859`) reports whether a `prep` other than `io_eopnotsupp_prep` is wired up (opcodes behind `CONFIG_NET`/`CONFIG_FUTEX`/`CONFIG_EPOLL` compile out to `-EOPNOTSUPP`).

The "Kernel handler" column is the `.issue` function from `io_issue_defs[]`; the "liburing prep" column is the primary `io_uring_prep_*` helper. Many ops also have `_direct`/`_fixed`/`_multishot` variant helpers (see [§10](#10-liburing-prep_-helper-families)).

| Val | `IORING_OP_*`      | Purpose (one-line)                                  | Since | Kernel handler (`opdef.c`) | liburing prep                              |
| --: | ------------------ | --------------------------------------------------- | ----- | -------------------------- | ------------------------------------------ |
|   0 | `NOP`              | No-op; useful for ring testing/fencing              | 5.1   | `io_nop`                   | `io_uring_prep_nop`                        |
|   1 | `READV`            | Vectored read (`preadv2`)                           | 5.1   | `io_read`                  | `io_uring_prep_readv` / `readv2`           |
|   2 | `WRITEV`           | Vectored write (`pwritev2`)                         | 5.1   | `io_write`                 | `io_uring_prep_writev` / `writev2`         |
|   3 | `FSYNC`            | `fsync`/`fdatasync` of a file                       | 5.1   | `io_fsync`                 | `io_uring_prep_fsync`                      |
|   4 | `READ_FIXED`       | Read into a pre-registered buffer                   | 5.1   | `io_read_fixed`            | `io_uring_prep_read_fixed`                 |
|   5 | `WRITE_FIXED`      | Write from a pre-registered buffer                  | 5.1   | `io_write_fixed`           | `io_uring_prep_write_fixed`                |
|   6 | `POLL_ADD`         | Arm a poll on an fd (one-shot or multishot)         | 5.1   | `io_poll_add`              | `io_uring_prep_poll_add`                   |
|   7 | `POLL_REMOVE`      | Remove/update an existing poll                      | 5.1   | `io_poll_remove`           | `io_uring_prep_poll_remove`                |
|   8 | `SYNC_FILE_RANGE`  | `sync_file_range(2)`                                | 5.2   | `io_sync_file_range`       | `io_uring_prep_sync_file_range`            |
|   9 | `SENDMSG`          | `sendmsg(2)` on a socket                            | 5.3   | `io_sendmsg`               | `io_uring_prep_sendmsg`                    |
|  10 | `RECVMSG`          | `recvmsg(2)` on a socket                            | 5.3   | `io_recvmsg`               | `io_uring_prep_recvmsg`                    |
|  11 | `TIMEOUT`          | Fire a CQE after a timeout / N completions          | 5.4   | `io_timeout`               | `io_uring_prep_timeout`                    |
|  12 | `TIMEOUT_REMOVE`   | Remove or update a pending timeout                  | 5.5   | `io_timeout_remove`        | `io_uring_prep_timeout_remove` / `_update` |
|  13 | `ACCEPT`           | `accept4(2)`; one-shot or multishot                 | 5.5   | `io_accept`                | `io_uring_prep_accept`                     |
|  14 | `ASYNC_CANCEL`     | Cancel an in-flight request by `user_data`/fd       | 5.5   | `io_async_cancel`          | `io_uring_prep_cancel` / `cancel64`        |
|  15 | `LINK_TIMEOUT`     | Attach a timeout to the next linked SQE             | 5.5   | _(none — `io_no_issue`)_   | `io_uring_prep_link_timeout`               |
|  16 | `CONNECT`          | `connect(2)` on a socket                            | 5.5   | `io_connect`               | `io_uring_prep_connect`                    |
|  17 | `FALLOCATE`        | `fallocate(2)`                                      | 5.6   | `io_fallocate`             | `io_uring_prep_fallocate`                  |
|  18 | `OPENAT`           | `openat(2)`                                         | 5.6   | `io_openat`                | `io_uring_prep_openat`                     |
|  19 | `CLOSE`            | `close(2)` (incl. fixed-fd slot)                    | 5.6   | `io_close`                 | `io_uring_prep_close`                      |
|  20 | `FILES_UPDATE`     | Update fixed-file table slots                       | 5.6   | `io_files_update`          | `io_uring_prep_files_update`               |
|  21 | `STATX`            | `statx(2)`                                          | 5.6   | `io_statx`                 | `io_uring_prep_statx`                      |
|  22 | `READ`             | `pread(2)` (non-vectored)                           | 5.6   | `io_read`                  | `io_uring_prep_read`                       |
|  23 | `WRITE`            | `pwrite(2)` (non-vectored)                          | 5.6   | `io_write`                 | `io_uring_prep_write`                      |
|  24 | `FADVISE`          | `posix_fadvise(2)`                                  | 5.6   | `io_fadvise`               | `io_uring_prep_fadvise` / `fadvise64`      |
|  25 | `MADVISE`          | `madvise(2)`                                        | 5.6   | `io_madvise`               | `io_uring_prep_madvise` / `madvise64`      |
|  26 | `SEND`             | `send(2)` on a socket                               | 5.6   | `io_send`                  | `io_uring_prep_send` / `sendto`            |
|  27 | `RECV`             | `recv(2)` on a socket                               | 5.6   | `io_recv`                  | `io_uring_prep_recv`                       |
|  28 | `OPENAT2`          | `openat2(2)` with `struct open_how`                 | 5.6   | `io_openat2`               | `io_uring_prep_openat2`                    |
|  29 | `EPOLL_CTL`        | `epoll_ctl(2)`                                      | 5.6   | `io_epoll_ctl`             | `io_uring_prep_epoll_ctl`                  |
|  30 | `SPLICE`           | `splice(2)` between two fds                         | 5.7   | `io_splice`                | `io_uring_prep_splice`                     |
|  31 | `PROVIDE_BUFFERS`  | Donate buffers to a legacy buffer group             | 5.7   | `io_manage_buffers_legacy` | `io_uring_prep_provide_buffers`            |
|  32 | `REMOVE_BUFFERS`   | Remove buffers from a legacy buffer group           | 5.7   | `io_manage_buffers_legacy` | `io_uring_prep_remove_buffers`             |
|  33 | `TEE`              | `tee(2)` (pipe duplication)                         | 5.8   | `io_tee`                   | `io_uring_prep_tee`                        |
|  34 | `SHUTDOWN`         | `shutdown(2)` on a socket                           | 5.11  | `io_shutdown`              | `io_uring_prep_shutdown`                   |
|  35 | `RENAMEAT`         | `renameat2(2)`                                      | 5.11  | `io_renameat`              | `io_uring_prep_renameat` / `rename`        |
|  36 | `UNLINKAT`         | `unlinkat(2)`                                       | 5.11  | `io_unlinkat`              | `io_uring_prep_unlinkat` / `unlink`        |
|  37 | `MKDIRAT`          | `mkdirat(2)`                                        | 5.15  | `io_mkdirat`               | `io_uring_prep_mkdirat` / `mkdir`          |
|  38 | `SYMLINKAT`        | `symlinkat(2)`                                      | 5.15  | `io_symlinkat`             | `io_uring_prep_symlinkat` / `symlink`      |
|  39 | `LINKAT`           | `linkat(2)`                                         | 5.15  | `io_linkat`                | `io_uring_prep_linkat` / `link`            |
|  40 | `MSG_RING`         | Post a message/fd to another ring                   | 5.18  | `io_msg_ring`              | `io_uring_prep_msg_ring` / `msg_ring_fd`   |
|  41 | `FSETXATTR`        | `fsetxattr(2)`                                      | 5.19  | `io_fsetxattr`             | `io_uring_prep_fsetxattr`                  |
|  42 | `SETXATTR`         | `setxattr(2)`                                       | 5.19  | `io_setxattr`              | `io_uring_prep_setxattr`                   |
|  43 | `FGETXATTR`        | `fgetxattr(2)`                                      | 5.19  | `io_fgetxattr`             | `io_uring_prep_fgetxattr`                  |
|  44 | `GETXATTR`         | `getxattr(2)`                                       | 5.19  | `io_getxattr`              | `io_uring_prep_getxattr`                   |
|  45 | `SOCKET`           | `socket(2)` (incl. direct/fixed-fd)                 | 5.19  | `io_socket`                | `io_uring_prep_socket` / `socket_direct`   |
|  46 | `URING_CMD`        | Pass-through driver command (NVMe, sockets, …)      | 5.19  | `io_uring_cmd`             | `io_uring_prep_uring_cmd`                  |
|  47 | `SEND_ZC`          | Zero-copy `send`                                    | 6.0   | `io_sendmsg_zc`            | `io_uring_prep_send_zc` / `_fixed`         |
|  48 | `SENDMSG_ZC`       | Zero-copy `sendmsg`                                 | 6.1   | `io_sendmsg_zc`            | `io_uring_prep_sendmsg_zc`                 |
|  49 | `READ_MULTISHOT`   | Multishot read using provided buffers               | 6.7   | `io_read_mshot`            | `io_uring_prep_read_multishot`             |
|  50 | `WAITID`           | `waitid(2)` (async child wait)                      | 6.7   | `io_waitid`                | `io_uring_prep_waitid`                     |
|  51 | `FUTEX_WAIT`       | `futex` wait                                        | 6.7   | `io_futex_wait`            | `io_uring_prep_futex_wait`                 |
|  52 | `FUTEX_WAKE`       | `futex` wake                                        | 6.7   | `io_futex_wake`            | `io_uring_prep_futex_wake`                 |
|  53 | `FUTEX_WAITV`      | Vectored `futex` wait (`futex_waitv`)               | 6.7   | `io_futexv_wait`           | `io_uring_prep_futex_waitv`                |
|  54 | `FIXED_FD_INSTALL` | Install a fixed-fd slot into the real fd table      | 6.8   | `io_install_fixed_fd`      | `io_uring_prep_fixed_fd_install`           |
|  55 | `FTRUNCATE`        | `ftruncate(2)`                                      | 6.9   | `io_ftruncate`             | `io_uring_prep_ftruncate`                  |
|  56 | `BIND`             | `bind(2)` (needed for direct-fd sockets)            | 6.11  | `io_bind`                  | `io_uring_prep_bind`                       |
|  57 | `LISTEN`           | `listen(2)` (needed for direct-fd sockets)          | 6.11  | `io_listen`                | `io_uring_prep_listen`                     |
|  58 | `RECV_ZC`          | Zero-copy receive via registered ifq                | 6.15  | `io_recvzc`                | _(`uring_cmd` / zcrx path)_                |
|  59 | `EPOLL_WAIT`       | `epoll_wait(2)` (unify legacy epoll into the ring)  | 6.15  | `io_epoll_wait`            | `io_uring_prep_epoll_wait`                 |
|  60 | `READV_FIXED`      | Vectored read into registered buffers               | 6.15  | `io_read`                  | `io_uring_prep_readv_fixed`                |
|  61 | `WRITEV_FIXED`     | Vectored write from registered buffers              | 6.15  | `io_write`                 | `io_uring_prep_writev_fixed`               |
|  62 | `PIPE`             | `pipe2(2)` (incl. direct-fd variant)                | 6.16  | `io_pipe`                  | `io_uring_prep_pipe`                       |
|  63 | `NOP128`           | No-op that consumes a 128-byte SQE (mixed-SQE test) | 6.19  | `io_nop`                   | `io_uring_prep_nop128`                     |
|  64 | `URING_CMD128`     | `URING_CMD` that always uses a 128-byte SQE         | 6.19  | `io_uring_cmd`             | `io_uring_prep_uring_cmd128`               |
|  65 | `LAST`             | _Sentinel — count of defined opcodes_               | —     | —                          | —                                          |

**Per-opcode dispatch attributes** (selected fields from `io_issue_defs[]`, `opdef.c`). These govern how the core loop treats each request and explain which ops can be async-poll-driven, buffer-selected, or IO-polled:

| Attribute (`io_issue_def`) | Meaning                                                               | Example opcodes                                                       |
| -------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `needs_file`               | SQE must reference a valid fd (or fixed-fd slot)                      | `READV`, `SEND`, `ACCEPT`, `MSG_RING`, `URING_CMD`                    |
| `unbound_nonreg_file`      | May run on an io-wq _unbound_ worker if the fd is non-regular         | `READV`, `RECV`, `ACCEPT`, `CONNECT`                                  |
| `pollin` / `pollout`       | Eligible for fast-poll arming on `-EAGAIN` (read-ready / write-ready) | `pollin`: `READ`,`RECV`,`ACCEPT`; `pollout`: `WRITE`,`SEND`,`CONNECT` |
| `buffer_select`            | Honors `IOSQE_BUFFER_SELECT` (provided/ring buffers)                  | `READV`, `READ`, `RECV`, `RECVMSG`, `SEND`, `URING_CMD`               |
| `ioprio`                   | `sqe->ioprio` carries op flags rather than I/O priority               | `SEND`/`RECV` (RECVSEND flags), `ACCEPT` (accept flags), `POLL`       |
| `iopoll`                   | Supports `IORING_SETUP_IOPOLL` (busy-poll completion)                 | `READ`, `WRITE`, `READ_FIXED`, `NOP`, `URING_CMD`                     |
| `vectored`                 | Vectored variant (iovec array)                                        | `READV`, `WRITEV`, `READV_FIXED`, `WRITEV_FIXED`                      |
| `hash_reg_file`            | Serialize writes to the same registered file via io-wq hashing        | `WRITEV`, `WRITE`, `WRITE_FIXED`, `FALLOCATE`, `FTRUNCATE`            |
| `plug`                     | Wrap issue in a block-layer plug for batching                         | `READV`, `WRITE`, `READ_FIXED`, `URING_CMD`                           |
| `poll_exclusive`           | Use exclusive poll wakeups (thundering-herd avoidance)                | `ACCEPT`                                                              |
| `audit_skip`               | Skip the syscall audit hook (hot path)                                | `NOP`, `READ`, `SEND`, `TIMEOUT`, `POLL_ADD`                          |
| `is_128`                   | Request always consumes a 128-byte SQE                                | `NOP128`, `URING_CMD128`                                              |
| `async_size`               | Bytes of per-request async state preallocated                         | `READV` → `io_async_rw`; `SENDMSG` → `io_async_msghdr`                |

> `LINK_TIMEOUT` is unique: its `.issue` is `io_no_issue` (`opdef.c:42`), which `WARN`s and returns `-ECANCELED` — the request is never issued directly. It only takes effect as the timeout attached to a preceding `IOSQE_IO_LINK`ed SQE, consumed by the link-handling fast path.

---

## 2. `IOSQE_*` — per-SQE submission flags (`sqe->flags`, `__u8`)

Bit positions come from `enum io_uring_sqe_flags_bit` (`io_uring.h:143`); the macros (`io_uring.h:157`) are `(1U << bit)`. Set via `io_uring_sqe_set_flags()`.

| Bit | Macro                    | Effect                                                                         | Since |
| --: | ------------------------ | ------------------------------------------------------------------------------ | ----- |
|   0 | `IOSQE_FIXED_FILE`       | `sqe->fd` is an index into the registered fixed-file table, not a real fd      | 5.1   |
|   1 | `IOSQE_IO_DRAIN`         | Wait for all prior in-flight requests to finish before issuing this one        | 5.2   |
|   2 | `IOSQE_IO_LINK`          | Link the next SQE; it starts only after this one completes successfully        | 5.3   |
|   3 | `IOSQE_IO_HARDLINK`      | Like `IO_LINK`, but the chain continues even if this request fails             | 5.5   |
|   4 | `IOSQE_ASYNC`            | Force issue on an io-wq worker instead of attempting inline + poll             | 5.6   |
|   5 | `IOSQE_BUFFER_SELECT`    | Pick a buffer from the group in `sqe->buf_group` (requires `buffer_select` op) | 5.7   |
|   6 | `IOSQE_CQE_SKIP_SUCCESS` | Don't post a CQE if the request succeeds (only on failure)                     | 5.17  |

> `IOSQE_CQE_SKIP_SUCCESS` requires the `IORING_FEAT_CQE_SKIP` feature bit ([§4](#4-ioring_feat_-feature-flags)) to be present in `io_uring_params.features`.

---

## 3. `IORING_SETUP_*` — `io_uring_setup(2)` flags (`io_uring_params.flags`)

From `io_uring.h:172`. Passed via `struct io_uring_params` (or `io_uring_queue_init_params()`).

| Bit | Macro                             | Effect                                                                                   | Since |
| --: | --------------------------------- | ---------------------------------------------------------------------------------------- | ----- |
|   0 | `IORING_SETUP_IOPOLL`             | Busy-poll for completions (storage); no interrupts/CQE events                            | 5.1   |
|   1 | `IORING_SETUP_SQPOLL`             | Kernel SQ-poll thread submits SQEs without `io_uring_enter`                              | 5.1   |
|   2 | `IORING_SETUP_SQ_AFF`             | `sq_thread_cpu` pins the SQPOLL thread to a CPU                                          | 5.1   |
|   3 | `IORING_SETUP_CQSIZE`             | App sizes the CQ ring via `cq_entries`                                                   | 5.5   |
|   4 | `IORING_SETUP_CLAMP`              | Clamp SQ/CQ sizes to the kernel max instead of erroring                                  | 5.6   |
|   5 | `IORING_SETUP_ATTACH_WQ`          | Share the io-wq backend of an existing ring (`wq_fd`)                                    | 5.6   |
|   6 | `IORING_SETUP_R_DISABLED`         | Create the ring disabled; enable later with `IORING_REGISTER_ENABLE_RINGS`               | 5.10  |
|   7 | `IORING_SETUP_SUBMIT_ALL`         | Continue submitting the batch even if one SQE fails prep                                 | 5.18  |
|   8 | `IORING_SETUP_COOP_TASKRUN`       | Run completion task-work on the next kernel transition; skip the IPI                     | 5.19  |
|   9 | `IORING_SETUP_TASKRUN_FLAG`       | Surface pending task-work via `IORING_SQ_TASKRUN` (needs `COOP_TASKRUN`/`DEFER_TASKRUN`) | 5.19  |
|  10 | `IORING_SETUP_SQE128`             | SQEs are 128 bytes (for `URING_CMD` pass-through payloads)                               | 5.19  |
|  11 | `IORING_SETUP_CQE32`              | CQEs are 32 bytes (extra `big_cqe[]` payload)                                            | 5.19  |
|  12 | `IORING_SETUP_SINGLE_ISSUER`      | Promise only one task submits — enables scheduling fast paths                            | 6.0   |
|  13 | `IORING_SETUP_DEFER_TASKRUN`      | Defer task-work until the app calls `io_uring_enter(GETEVENTS)` (needs `SINGLE_ISSUER`)  | 6.1   |
|  14 | `IORING_SETUP_NO_MMAP`            | App supplies ring memory; no `mmap` of magic offsets                                     | 6.5   |
|  15 | `IORING_SETUP_REGISTERED_FD_ONLY` | Return a registered ring-fd index instead of a real fd                                   | 6.5   |
|  16 | `IORING_SETUP_NO_SQARRAY`         | Drop the SQ index indirection array; SQEs submitted in ring order                        | 6.6   |
|  17 | `IORING_SETUP_HYBRID_IOPOLL`      | Hybrid (sleep-then-poll) IOPOLL to cut busy-poll CPU                                     | 6.13  |
|  18 | `IORING_SETUP_CQE_MIXED`          | Allow both 16- and 32-byte CQEs; big CQEs flagged `IORING_CQE_F_32`                      | 6.18  |
|  19 | `IORING_SETUP_SQE_MIXED`          | Allow both 64- and 128-byte SQEs (128b ops use the `*128` opcodes)                       | 6.19  |
|  20 | `IORING_SETUP_SQ_REWIND`          | Ignore SQ head/tail; always fetch SQEs from index 0 (needs `NO_SQARRAY`, excl. `SQPOLL`) | 7.0   |

See [features.md][features] for the COOP/DEFER taskrun and `SINGLE_ISSUER` scheduling story, and [timeline.md][timeline] for how SQPOLL → `COOP_TASKRUN` → `DEFER_TASKRUN` evolved.

---

## 4. `IORING_FEAT_*` — feature flags (`io_uring_params.features`, output)

From `io_uring.h:629`. The kernel fills `features` on a successful `io_uring_setup(2)`; applications must check these bits before relying on the corresponding behavior.

| Bit | Macro                         | What it advertises                                                              | Since |
| --: | ----------------------------- | ------------------------------------------------------------------------------- | ----- |
|   0 | `IORING_FEAT_SINGLE_MMAP`     | SQ and CQ rings can share one `mmap` (offsets coincide)                         | 5.4   |
|   1 | `IORING_FEAT_NODROP`          | CQEs are never silently dropped on overflow; overflow is tracked                | 5.5   |
|   2 | `IORING_FEAT_SUBMIT_STABLE`   | SQE data is fully consumed at submit; app may reuse the SQE immediately         | 5.5   |
|   3 | `IORING_FEAT_RW_CUR_POS`      | Offset `-1` means "use the file's current position" for read/write              | 5.6   |
|   4 | `IORING_FEAT_CUR_PERSONALITY` | Requests run with the personality of the submitting task by default             | 5.6   |
|   5 | `IORING_FEAT_FAST_POLL`       | Internal async poll for non-ready fds (the "fast poll" backbone of network I/O) | 5.7   |
|   6 | `IORING_FEAT_POLL_32BITS`     | `poll_add` accepts 32-bit (`EPOLLEXCLUSIVE` etc.) poll masks                    | 5.9   |
|   7 | `IORING_FEAT_SQPOLL_NONFIXED` | SQPOLL works with non-registered files                                          | 5.11  |
|   8 | `IORING_FEAT_EXT_ARG`         | `io_uring_enter(2)` accepts the extended-arg struct (timeout + sigmask)         | 5.11  |
|   9 | `IORING_FEAT_NATIVE_WORKERS`  | io-wq workers are native kernel threads (not kthreads)                          | 5.12  |
|  10 | `IORING_FEAT_RSRC_TAGS`       | Registered resources support update tags for lifetime tracking                  | 5.13  |
|  11 | `IORING_FEAT_CQE_SKIP`        | `IOSQE_CQE_SKIP_SUCCESS` is honored                                             | 5.17  |
|  12 | `IORING_FEAT_LINKED_FILE`     | Linked SQEs resolve the file lazily, after the prior link completes             | 5.18  |
|  13 | `IORING_FEAT_REG_REG_RING`    | A registered ring-fd may itself be used for `IORING_REGISTER_*`                 | 6.3   |
|  14 | `IORING_FEAT_RECVSEND_BUNDLE` | `IORING_RECVSEND_BUNDLE` (grab many provided buffers per send/recv)             | 6.10  |
|  15 | `IORING_FEAT_MIN_TIMEOUT`     | Wait supports a "min-wait" window (`min_wait_usec`)                             | 6.12  |
|  16 | `IORING_FEAT_RW_ATTR`         | Read/write attribute pointer (`attr_ptr`/`attr_type_mask`, e.g. PI metadata)    | 6.14  |
|  17 | `IORING_FEAT_NO_IOWAIT`       | `IORING_ENTER_NO_IOWAIT` is honored (skip iowait accounting on wait)            | 6.15  |

---

## 5. `IORING_ENTER_*` — `io_uring_enter(2)` flags

From `io_uring.h:600`. Passed as the `flags` argument of the `io_uring_enter(2)` syscall (liburing's `io_uring_submit*` / `io_uring_wait_cqe*` wrap these).

| Bit | Macro                          | Effect                                                                          | Since |
| --: | ------------------------------ | ------------------------------------------------------------------------------- | ----- |
|   0 | `IORING_ENTER_GETEVENTS`       | Block until at least `min_complete` CQEs are available                          | 5.1   |
|   1 | `IORING_ENTER_SQ_WAKEUP`       | Wake the SQPOLL thread if it has gone to sleep                                  | 5.1   |
|   2 | `IORING_ENTER_SQ_WAIT`         | Wait for the SQPOLL thread to consume the SQ before returning                   | 5.10  |
|   3 | `IORING_ENTER_EXT_ARG`         | `arg`/`argsz` point at `struct io_uring_getevents_arg` (timeout + sigmask)      | 5.11  |
|   4 | `IORING_ENTER_REGISTERED_RING` | `fd` is a registered ring index, not a real fd                                  | 5.18  |
|   5 | `IORING_ENTER_ABS_TIMER`       | Treat the wait timeout as an absolute time                                      | 6.12  |
|   6 | `IORING_ENTER_EXT_ARG_REG`     | `arg` is an index into a pre-registered fixed wait region (`io_uring_reg_wait`) | 6.13  |
|   7 | `IORING_ENTER_NO_IOWAIT`       | Don't account the wait as iowait (avoids inflating load averages)               | 6.15  |

---

## 6. `IORING_CQE_F_*` — completion flags (`cqe->flags`, `__u32`)

From `io_uring.h:538`. The upper 16 bits of `cqe->flags` carry the buffer ID when `IORING_CQE_F_BUFFER` is set (`IORING_CQE_BUFFER_SHIFT == 16`, `io_uring.h:546`).

| Bit | Macro                        | Meaning                                                                         | Since |
| --: | ---------------------------- | ------------------------------------------------------------------------------- | ----- |
|   0 | `IORING_CQE_F_BUFFER`        | Upper 16 bits hold the provided-buffer ID that was consumed                     | 5.7   |
|   1 | `IORING_CQE_F_MORE`          | The parent SQE will generate more CQEs (multishot still armed)                  | 5.13  |
|   2 | `IORING_CQE_F_SOCK_NONEMPTY` | After a socket recv, more data remains to be read                               | 5.19  |
|   3 | `IORING_CQE_F_NOTIF`         | This is the zero-copy notification CQE (distinct from the send CQE)             | 6.0   |
|   4 | `IORING_CQE_F_BUF_MORE`      | An incremental (`IOU_PBUF_RING_INC`) buffer is partially consumed; more to come | 6.12  |
|   5 | `IORING_CQE_F_SKIP`          | Padding CQE — the application/liburing must ignore it                           | 6.18  |
|  15 | `IORING_CQE_F_32`            | This is a 32-byte (big) CQE, posted in a `IORING_SETUP_CQE_MIXED` ring          | 6.18  |

> A related socket-timestamp flag, `IORING_CQE_F_TSTAMP_HW` (`io_uring.h:1054`), lives at bit 16 (`IORING_TIMESTAMP_HW_SHIFT`) and is only meaningful for `SOCKET_URING_OP_TX_TIMESTAMP` `URING_CMD` completions, where it overlaps the buffer-ID region.

`sq_ring->flags` (`io_uring.h:576`) and `cq_ring->flags` (`io_uring.h:597`) carry the kernel-side ring status bits the app polls without a syscall:

| Macro                        | Ring | Meaning                                                    |
| ---------------------------- | ---- | ---------------------------------------------------------- |
| `IORING_SQ_NEED_WAKEUP`      | SQ   | SQPOLL thread sleeping — call enter with `SQ_WAKEUP`       |
| `IORING_SQ_CQ_OVERFLOW`      | SQ   | CQ overflowed; enter the kernel to flush the overflow list |
| `IORING_SQ_TASKRUN`          | SQ   | Task-work pending (set when `TASKRUN_FLAG` is on)          |
| `IORING_CQ_EVENTFD_DISABLED` | CQ   | eventfd notifications are currently suppressed             |

---

## 7. `IORING_REGISTER_*` — `io_uring_register(2)` opcodes

From `enum io_uring_register_op` (`io_uring.h:652`). The high bit `IORING_REGISTER_USE_REGISTERED_RING` (`1U << 31`) is OR-ed into the opcode to operate on a _registered_ ring-fd index instead of a real fd. The sentinel is `IORING_REGISTER_LAST`.

| Val | `IORING_REGISTER_*`         | Purpose                                                  | Since |
| --: | --------------------------- | -------------------------------------------------------- | ----- |
|   0 | `REGISTER_BUFFERS`          | Register fixed I/O buffers                               | 5.1   |
|   1 | `UNREGISTER_BUFFERS`        | Drop all fixed buffers                                   | 5.1   |
|   2 | `REGISTER_FILES`            | Register a fixed-file table                              | 5.1   |
|   3 | `UNREGISTER_FILES`          | Drop the fixed-file table                                | 5.1   |
|   4 | `REGISTER_EVENTFD`          | Attach an eventfd for completion notifications           | 5.2   |
|   5 | `UNREGISTER_EVENTFD`        | Detach the eventfd                                       | 5.2   |
|   6 | `REGISTER_FILES_UPDATE`     | Update slots in the fixed-file table                     | 5.5   |
|   7 | `REGISTER_EVENTFD_ASYNC`    | eventfd notifications only for async (io-wq) completions | 5.6   |
|   8 | `REGISTER_PROBE`            | Query which opcodes the kernel supports                  | 5.6   |
|   9 | `REGISTER_PERSONALITY`      | Register a credential set; returns a personality ID      | 5.6   |
|  10 | `UNREGISTER_PERSONALITY`    | Drop a personality                                       | 5.6   |
|  11 | `REGISTER_RESTRICTIONS`     | Restrict allowed ops/flags (for sandboxing a ring)       | 5.10  |
|  12 | `REGISTER_ENABLE_RINGS`     | Enable a ring created with `IORING_SETUP_R_DISABLED`     | 5.10  |
|  13 | `REGISTER_FILES2`           | Register files with resource tags                        | 5.13  |
|  14 | `REGISTER_FILES_UPDATE2`    | Tagged fixed-file update                                 | 5.13  |
|  15 | `REGISTER_BUFFERS2`         | Register buffers with resource tags                      | 5.13  |
|  16 | `REGISTER_BUFFERS_UPDATE`   | Tagged fixed-buffer update                               | 5.13  |
|  17 | `REGISTER_IOWQ_AFF`         | Set io-wq worker CPU affinity                            | 5.14  |
|  18 | `UNREGISTER_IOWQ_AFF`       | Clear io-wq worker affinity                              | 5.14  |
|  19 | `REGISTER_IOWQ_MAX_WORKERS` | Get/set max bound & unbound io-wq workers                | 5.15  |
|  20 | `REGISTER_RING_FDS`         | Register ring-fds for `IORING_ENTER_REGISTERED_RING`     | 5.18  |
|  21 | `UNREGISTER_RING_FDS`       | Unregister ring-fds                                      | 5.18  |
|  22 | `REGISTER_PBUF_RING`        | Register a provided-buffer _ring_ (the modern fast path) | 5.19  |
|  23 | `UNREGISTER_PBUF_RING`      | Unregister a provided-buffer ring                        | 5.19  |
|  24 | `REGISTER_SYNC_CANCEL`      | Synchronous cancel API (cancel from the register path)   | 6.0   |
|  25 | `REGISTER_FILE_ALLOC_RANGE` | Reserve a fixed-file slot range for auto-allocation      | 6.0   |
|  26 | `REGISTER_PBUF_STATUS`      | Query head/consumption status of a provided-buffer group | 6.8   |
|  27 | `REGISTER_NAPI`             | Configure NAPI busy-poll for the ring                    | 6.9   |
|  28 | `UNREGISTER_NAPI`           | Disable NAPI busy-poll                                   | 6.9   |
|  29 | `REGISTER_CLOCK`            | Choose the clock source for ring timeouts                | 6.12  |
|  30 | `REGISTER_CLONE_BUFFERS`    | Clone registered buffers from another ring               | 6.12  |
|  31 | `REGISTER_SEND_MSG_RING`    | Send an `MSG_RING` without owning a source ring          | 6.13  |
|  32 | `REGISTER_ZCRX_IFQ`         | Register a netdev hw RX queue for zero-copy receive      | 6.15  |
|  33 | `REGISTER_RESIZE_RINGS`     | Resize the SQ/CQ rings in place                          | 6.13  |
|  34 | `REGISTER_MEM_REGION`       | Register a user memory region (e.g. fixed wait args)     | 6.13  |
|  35 | `REGISTER_QUERY`            | Query `io_uring` attributes (`linux/io_uring/query.h`)   | 6.18  |
|  36 | `REGISTER_ZCRX_CTRL`        | Auxiliary zero-copy-RX control (`enum zcrx_ctrl_op`)     | 6.19  |
|  37 | `REGISTER_BPF_FILTER`       | Register a BPF filtering program for the ring            | 7.0   |
|  38 | `REGISTER_LAST`             | _Sentinel_                                               | —     |

Auxiliary register-path enums:

| Enum / flag                                       | Where (`io_uring.h`) | Meaning                                                       |
| ------------------------------------------------- | -------------------- | ------------------------------------------------------------- |
| `IO_WQ_BOUND` / `IO_WQ_UNBOUND`                   | `:734`               | io-wq worker categories for `REGISTER_IOWQ_MAX_WORKERS`       |
| `IORING_RSRC_REGISTER_SPARSE`                     | `:775`               | Register an all-sparse (placeholder) resource table           |
| `IORING_REGISTER_FILES_SKIP` (`-2`)               | `:801`               | "Leave this fd-table slot unchanged" sentinel in an update    |
| `IO_URING_OP_SUPPORTED` (`1U << 0`)               | `:803`               | `io_uring_probe_op.flags` bit set when an opcode is supported |
| `IORING_REGISTER_SRC_REGISTERED` / `_DST_REPLACE` | `:843`               | Flags for `REGISTER_CLONE_BUFFERS`                            |
| `IORING_MEM_REGION_TYPE_USER` (`1`)               | `:746`               | Memory region backed by user-provided memory                  |
| `IORING_MEM_REGION_REG_WAIT_ARG` (`1`)            | `:760`               | Expose the region as registered wait arguments                |
| `IORING_REG_WAIT_TS` (`1U << 0`)                  | `:975`               | `io_uring_reg_wait.flags`: the embedded timespec is valid     |

`enum io_uring_register_restriction_op` (`io_uring.h:958`) drives `REGISTER_RESTRICTIONS`:

| Val | Macro                                   | Restriction                                 |
| --: | --------------------------------------- | ------------------------------------------- |
|   0 | `IORING_RESTRICTION_REGISTER_OP`        | Whitelist a `io_uring_register(2)` opcode   |
|   1 | `IORING_RESTRICTION_SQE_OP`             | Whitelist an SQE opcode                     |
|   2 | `IORING_RESTRICTION_SQE_FLAGS_ALLOWED`  | Whitelist SQE flags                         |
|   3 | `IORING_RESTRICTION_SQE_FLAGS_REQUIRED` | Require these SQE flags on every submission |

---

## 8. Per-op flag enums

Each op family squeezes its own flags into a free SQE field. The table below records _which field_ each lives in — a common source of bugs, since the same field is unioned across opcodes (`struct io_uring_sqe`, `io_uring.h:32`).

### 8.1 recv / send — `sqe->ioprio` (`io_uring.h:437`)

| Bit | Macro                         | Effect                                                                | Since |
| --: | ----------------------------- | --------------------------------------------------------------------- | ----- |
|   0 | `IORING_RECVSEND_POLL_FIRST`  | Arm poll up-front; skip the initial transfer attempt                  | 5.19  |
|   1 | `IORING_RECV_MULTISHOT`       | Multishot recv — keep posting CQEs (sets `IORING_CQE_F_MORE`)         | 6.0   |
|   2 | `IORING_RECVSEND_FIXED_BUF`   | Use a registered buffer (`buf_index`) for the transfer                | 6.0   |
|   3 | `IORING_SEND_ZC_REPORT_USAGE` | Report zero-copy usage in the notification `cqe->res`                 | 6.2   |
|   4 | `IORING_RECVSEND_BUNDLE`      | With `BUFFER_SELECT`, grab many contiguous provided buffers in one op | 6.10  |
|   5 | `IORING_SEND_VECTORIZED`      | `SEND[_ZC]` takes an iovec pointer for vectored sends                 | 6.17  |

Companion: `IORING_NOTIF_USAGE_ZC_COPIED` (`1U << 31`, `io_uring.h:451`) in the notification `cqe->res` means data was copied (zero-copy did _not_ happen).

### 8.2 accept — `sqe->ioprio` (`io_uring.h:456`)

| Bit | Macro                      | Effect                                            | Since |
| --: | -------------------------- | ------------------------------------------------- | ----- |
|   0 | `IORING_ACCEPT_MULTISHOT`  | Keep accepting connections from one SQE           | 5.19  |
|   1 | `IORING_ACCEPT_DONTWAIT`   | Non-blocking accept (`-EAGAIN` if none pending)   | 6.10  |
|   2 | `IORING_ACCEPT_POLL_FIRST` | Arm poll up-front before the first accept attempt | 6.10  |

### 8.3 poll — `sqe->len` (`io_uring.h:380`)

`POLL_ADD` puts the poll mask in `sqe->poll32_events` (the flag field), so its _command_ flags live in `sqe->len`:

| Bit | Macro                          | Effect                                     | Since |
| --: | ------------------------------ | ------------------------------------------ | ----- |
|   0 | `IORING_POLL_ADD_MULTI`        | Multishot poll (sets `IORING_CQE_F_MORE`)  | 5.13  |
|   1 | `IORING_POLL_UPDATE_EVENTS`    | Update the event mask of an existing poll  | 5.13  |
|   2 | `IORING_POLL_UPDATE_USER_DATA` | Update the `user_data` of an existing poll | 5.13  |
|   3 | `IORING_POLL_ADD_LEVEL`        | Level-triggered (vs. edge-triggered) poll  | 6.0   |

### 8.4 timeout — `sqe->timeout_flags` (`io_uring.h:351`)

| Bit | Macro                          | Effect                                                    | Since |
| --: | ------------------------------ | --------------------------------------------------------- | ----- |
|   0 | `IORING_TIMEOUT_ABS`           | Timeout value is absolute, not relative                   | 5.5   |
|   1 | `IORING_TIMEOUT_UPDATE`        | This is a timeout _update_, not a new timeout             | 5.11  |
|   2 | `IORING_TIMEOUT_BOOTTIME`      | Use `CLOCK_BOOTTIME`                                      | 5.15  |
|   3 | `IORING_TIMEOUT_REALTIME`      | Use `CLOCK_REALTIME`                                      | 5.15  |
|   4 | `IORING_LINK_TIMEOUT_UPDATE`   | Update a linked timeout                                   | 5.15  |
|   5 | `IORING_TIMEOUT_ETIME_SUCCESS` | Report `-ETIME` expiry as a success completion            | 5.16  |
|   6 | `IORING_TIMEOUT_MULTISHOT`     | Repeating timeout (fires periodically)                    | 6.4   |
|   7 | `IORING_TIMEOUT_IMMEDIATE_ARG` | `sqe->addr` _is_ the nanosecond value, not a timespec ptr | 7.1   |

Masks: `IORING_TIMEOUT_CLOCK_MASK` (`BOOTTIME|REALTIME`), `IORING_TIMEOUT_UPDATE_MASK` (`UPDATE|LINK_TIMEOUT_UPDATE`).

### 8.5 async-cancel — `sqe->cancel_flags` (`io_uring.h:396`)

Also used by `struct io_uring_sync_cancel_reg.flags` for `REGISTER_SYNC_CANCEL`.

| Bit | Macro                          | Match key                                                  | Since |
| --: | ------------------------------ | ---------------------------------------------------------- | ----- |
|   0 | `IORING_ASYNC_CANCEL_ALL`      | Cancel _all_ requests matching the key, not just the first | 5.19  |
|   1 | `IORING_ASYNC_CANCEL_FD`       | Match on `sqe->fd` instead of `user_data`                  | 5.19  |
|   2 | `IORING_ASYNC_CANCEL_ANY`      | Match any in-flight request                                | 5.19  |
|   3 | `IORING_ASYNC_CANCEL_FD_FIXED` | The `fd` to match is a fixed-fd slot                       | 6.0   |
|   4 | `IORING_ASYNC_CANCEL_USERDATA` | Match on `user_data` (the default if no other key)         | 6.6   |
|   5 | `IORING_ASYNC_CANCEL_OP`       | Match on opcode                                            | 6.6   |

### 8.6 provided-buffer ring — `enum io_uring_register_pbuf_ring_flags` (`io_uring.h:897`)

`struct io_uring_buf_reg.flags` for `REGISTER_PBUF_RING`:

| Val | Macro                | Effect                                                                          | Since |
| --: | -------------------- | ------------------------------------------------------------------------------- | ----- |
|   1 | `IOU_PBUF_RING_MMAP` | Kernel allocates the ring; app `mmap`s it at `IORING_OFF_PBUF_RING\|(bgid<<16)` | 6.4   |
|   2 | `IOU_PBUF_RING_INC`  | Buffers may be _incrementally_ consumed (pairs with `IORING_CQE_F_BUF_MORE`)    | 6.12  |

### 8.7 other per-op flags

| Field / enum                     | Macro(s)                                                                                        | Where         |
| -------------------------------- | ----------------------------------------------------------------------------------------------- | ------------- |
| `sqe->uring_cmd_flags`           | `IORING_URING_CMD_FIXED`, `IORING_URING_CMD_MULTISHOT` (mask `_MASK`)                           | `:334`        |
| `sqe->fsync_flags`               | `IORING_FSYNC_DATASYNC`                                                                         | `:342`        |
| `sqe->splice_flags`              | `SPLICE_F_FD_IN_FIXED` (`1U << 31`)                                                             | `:365`        |
| `sqe->msg_ring_flags`            | `IORING_MSG_RING_CQE_SKIP`, `IORING_MSG_RING_FLAGS_PASS`                                        | `:474`        |
| `sqe->addr` (`MSG_RING` command) | `IORING_MSG_DATA` (0), `IORING_MSG_SEND_FD` (1)                                                 | `:463`        |
| `sqe->install_fd_flags`          | `IORING_FIXED_FD_NO_CLOEXEC`                                                                    | `:483`        |
| `sqe->nop_flags`                 | `IORING_NOP_INJECT_RESULT`, `_FILE`, `_FIXED_FILE`, `_FIXED_BUFFER`, `_TW`, `_CQE32`            | `:490`        |
| `sqe->attr_type_mask` (PI)       | `IORING_RW_ATTR_FLAG_PI`                                                                        | `:123`        |
| `socket` `URING_CMD` sub-op      | `SOCKET_URING_OP_SIOCINQ/SIOCOUTQ/GETSOCKOPT/SETSOCKOPT/TX_TIMESTAMP/GETSOCKNAME`               | `:1037`       |
| NAPI op / tracking               | `IO_URING_NAPI_REGISTER_OP/STATIC_ADD_ID/STATIC_DEL_ID`; `..._TRACKING_DYNAMIC/STATIC/INACTIVE` | `:919`,`:928` |

`IORING_FILE_INDEX_ALLOC` (`~0U`, `io_uring.h:141`) in `sqe->file_index` asks the kernel to auto-pick a free fixed-fd slot for opcodes that instantiate one (`OPENAT`, `ACCEPT`, `SOCKET`, …); the chosen slot is returned in `cqe->res`.

---

## 9. mmap offsets & ring memory

The SQ ring, CQ ring, SQE array, and provided-buffer rings live at magic `mmap(2)` offsets (`io_uring.h:551`). These are the addresses liburing maps internally during `io_uring_queue_init()`:

| Macro                  | Offset       | Maps                                                               |
| ---------------------- | ------------ | ------------------------------------------------------------------ |
| `IORING_OFF_SQ_RING`   | `0`          | SQ ring header + index array                                       |
| `IORING_OFF_CQ_RING`   | `0x8000000`  | CQ ring header + CQE array                                         |
| `IORING_OFF_SQES`      | `0x10000000` | The SQE array itself                                               |
| `IORING_OFF_PBUF_RING` | `0x80000000` | A provided-buffer ring; OR in `bgid << IORING_OFF_PBUF_SHIFT` (16) |
| `IORING_OFF_MMAP_MASK` | `0xf8000000` | Mask selecting which region an offset refers to                    |

---

## 10. liburing `io_uring_prep_*` helper families

User space rarely fills `struct io_uring_sqe` by hand. `liburing/src/include/liburing.h` provides `static inline` setters; all of them ultimately call the workhorse `io_uring_prep_rw(int op, struct io_uring_sqe *sqe, int fd, const void *addr, unsigned len, __u64 offset)` (`liburing.h:592`), which sets only `opcode`/`fd`/`off`/`addr`/`len`. The remaining fields are cleared separately by `io_uring_initialize_sqe()` (`liburing.h:579`), which `io_uring_get_sqe()` invokes when handing out a fresh SQE. Families:

| Family                  | Representative helpers                                                                                                                                              | Notes                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| **Read/Write**          | `read`, `write`, `readv`/`readv2`, `writev`/`writev2`, `read_fixed`, `write_fixed`, `readv_fixed`, `writev_fixed`, `read_multishot`                                 | `*_fixed` set `buf_index`; `*2` take RWF flags            |
| **File sync**           | `fsync`, `sync_file_range`, `fallocate`, `ftruncate`                                                                                                                | `fsync` sets `fsync_flags`                                |
| **Open/Close**          | `openat`, `openat2`, `open`, `close`, plus `*_direct` / `close_direct` for fixed-fd slots                                                                           | `_direct` set `file_index` (or `IORING_FILE_INDEX_ALLOC`) |
| **FS namespace**        | `renameat`/`rename`, `unlinkat`/`unlink`, `mkdirat`/`mkdir`, `symlinkat`/`symlink`, `linkat`/`link`                                                                 | thin wrappers over the `*at` syscalls                     |
| **Metadata**            | `statx`, `fadvise`/`fadvise64`, `madvise`/`madvise64`                                                                                                               | `64` variants take a 64-bit length                        |
| **xattr**               | `setxattr`, `fsetxattr`, `getxattr`, `fgetxattr`                                                                                                                    | —                                                         |
| **Network — connect**   | `socket`, `socket_direct`, `socket_direct_alloc`, `bind`, `listen`, `connect`, `accept`, `accept_direct`, `multishot_accept`, `multishot_accept_direct`, `shutdown` | `_direct` create fixed-fd slots                           |
| **Network — transfer**  | `send`, `sendto`, `send_bundle`, `send_set_addr`, `sendmsg`, `recv`, `recv_multishot`, `recvmsg`, `recvmsg_multishot`                                               | set `msg_flags` / RECVSEND flags                          |
| **Network — zero-copy** | `send_zc`, `send_zc_fixed`, `sendmsg_zc`, `sendmsg_zc_fixed`                                                                                                        | post a `IORING_CQE_F_NOTIF` CQE                           |
| **Poll**                | `poll_add`, `poll_multishot`, `poll_remove`, `poll_update`, `poll_mask` (internal mask byte-swap)                                                                   | set `poll32_events` + `IORING_POLL_*` in `len`            |
| **Timeout**             | `timeout`, `timeout_remove`, `timeout_update`, `link_timeout`                                                                                                       | set `timeout_flags`                                       |
| **Cancel**              | `cancel`, `cancel64`, `cancel_fd`                                                                                                                                   | set `cancel_flags` (`IORING_ASYNC_CANCEL_*`)              |
| **epoll**               | `epoll_ctl`, `epoll_wait`                                                                                                                                           | —                                                         |
| **Splice/Tee**          | `splice`, `tee`                                                                                                                                                     | set `splice_fd_in` / `splice_off_in`                      |
| **Buffers (legacy)**    | `provide_buffers`, `remove_buffers`                                                                                                                                 | superseded by `register_buf_ring`                         |
| **Files update**        | `files_update`, `fixed_fd_install`                                                                                                                                  | manage the fixed-file table inline                        |
| **Pipe**                | `pipe`, `pipe_direct`                                                                                                                                               | `_direct` installs fixed-fd slots                         |
| **futex / waitid**      | `futex_wait`, `futex_wake`, `futex_waitv`, `waitid`                                                                                                                 | —                                                         |
| **Message ring**        | `msg_ring`, `msg_ring_cqe_flags`, `msg_ring_fd`, `msg_ring_fd_alloc`                                                                                                | cross-ring messaging                                      |
| **Pass-through cmd**    | `uring_cmd`, `uring_cmd128`, `cmd_sock`, `cmd_discard`, `cmd_getsockname`                                                                                           | NVMe / socket control via `URING_CMD`                     |
| **No-op**               | `nop`, `nop128`                                                                                                                                                     | `nop128` exercises 128-byte SQEs                          |

### Queue, submit, completion & data helpers

| Helper                                                   | Role                                                        |
| -------------------------------------------------------- | ----------------------------------------------------------- |
| `io_uring_queue_init` / `_params` / `_mem`               | Set up the ring (flags / full params / app-supplied memory) |
| `io_uring_queue_exit`                                    | Tear down the ring                                          |
| `io_uring_get_sqe`                                       | Grab the next free SQE                                      |
| `io_uring_sqe_set_data` / `_data64` / `set_flags`        | Stash `user_data` / set `IOSQE_*`                           |
| `io_uring_submit`                                        | `io_uring_enter` to submit pending SQEs                     |
| `io_uring_submit_and_wait` / `_timeout` / `_min_timeout` | Submit, then block for completions (optionally bounded)     |
| `io_uring_submit_and_get_events` / `_and_wait_reg`       | Submit + flush; registered-wait-region variant              |
| `io_uring_wait_cqe` / `_nr` / `_timeout` / `wait_cqes`   | Block for one / N / time-bounded / batched completions      |
| `io_uring_peek_cqe`                                      | Non-blocking CQE peek                                       |
| `io_uring_cqe_get_data` / `_data64` / `cqe_seen`         | Read back `user_data` / mark a CQE consumed                 |

### Register API surface

These wrap the [§7](#7-ioring_register---io_uring_register2-opcodes) opcodes:

| Helper                                                                      | Backing opcode(s)                                |
| --------------------------------------------------------------------------- | ------------------------------------------------ |
| `io_uring_register_buffers` / `_sparse` / `_tags` / `_update_tag`           | `REGISTER_BUFFERS`, `BUFFERS2`, `BUFFERS_UPDATE` |
| `io_uring_register_files` / `_sparse` / `_tags` / `_update` / `_update_tag` | `REGISTER_FILES`, `FILES2`, `FILES_UPDATE(2)`    |
| `io_uring_register_file_alloc_range`                                        | `REGISTER_FILE_ALLOC_RANGE`                      |
| `io_uring_register_eventfd` / `_async`                                      | `REGISTER_EVENTFD`, `EVENTFD_ASYNC`              |
| `io_uring_register_probe`                                                   | `REGISTER_PROBE`                                 |
| `io_uring_register_personality`                                             | `REGISTER_PERSONALITY`                           |
| `io_uring_register_restrictions`                                            | `REGISTER_RESTRICTIONS`                          |
| `io_uring_register_buf_ring`                                                | `REGISTER_PBUF_RING`                             |
| `io_uring_register_ring_fd`                                                 | `REGISTER_RING_FDS`                              |
| `io_uring_register_iowq_aff` / `_max_workers`                               | `REGISTER_IOWQ_AFF`, `IOWQ_MAX_WORKERS`          |
| `io_uring_register_sync_cancel` / `_sync_msg`                               | `REGISTER_SYNC_CANCEL`, `SEND_MSG_RING`          |
| `io_uring_register_napi`                                                    | `REGISTER_NAPI`                                  |
| `io_uring_register_clock`                                                   | `REGISTER_CLOCK`                                 |
| `io_uring_register_region` / `_wait_reg`                                    | `REGISTER_MEM_REGION` (+ fixed wait args)        |
| `io_uring_register_ifq`                                                     | `REGISTER_ZCRX_IFQ`                              |
| `io_uring_register_bpf_filter` / `_task`                                    | `REGISTER_BPF_FILTER`                            |

### Provided-buffer ring helpers

For the modern ring-based provided-buffer fast path (no per-batch syscall):

| Helper                                      | Role                                      |
| ------------------------------------------- | ----------------------------------------- |
| `io_uring_buf_ring_init`                    | Initialize the `io_uring_buf_ring` tail   |
| `io_uring_buf_ring_mask`                    | Compute the ring index mask               |
| `io_uring_buf_ring_add`                     | Add a buffer entry                        |
| `io_uring_buf_ring_advance` / `_cq_advance` | Publish added buffers to the kernel       |
| `io_uring_buf_ring_head` / `_available`     | Inspect head / count of available buffers |

---

## Field-overlap cheat sheet

The single biggest UABI footgun is the `struct io_uring_sqe` unions: the _same byte range_ means different things per opcode. The most-used overlaps:

| Field                        | Plain meaning          | Reused by                                                                                        |
| ---------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------ |
| `sqe->off`                   | file offset            | `addr2`; `cmd_op`+`__pad1` (for `URING_CMD`)                                                     |
| `sqe->addr`                  | buffer / iovec pointer | `splice_off_in`; `level`+`optname` (socket cmd)                                                  |
| `sqe->ioprio`                | I/O priority           | RECVSEND flags, ACCEPT flags, poll command flags                                                 |
| `*_flags` union (`rw_flags`) | per-op flags           | `fsync_flags`, `timeout_flags`, `accept_flags`, `cancel_flags`, `msg_ring_flags`, `nop_flags`, … |
| `buf_index`                  | fixed-buffer index     | `buf_group` (for `IOSQE_BUFFER_SELECT`)                                                          |
| `splice_fd_in`               | splice source fd       | `file_index`, `zcrx_ifq_idx`, `optlen`, `addr_len`                                               |
| `addr3`                      | third address          | `attr_ptr`+`attr_type_mask` (PI), `optval`, `cmd[]` (SQE128)                                     |

For the design rationale behind these primitives — submission/completion rings, fixed files/buffers, multishot, provided buffers, zero-copy, and the io-wq fallback — see the [feature catalog][features]; for the chronological "when did X land" view, see the [timeline][timeline]. For how language runtimes consume this UABI, see [Tokio][tokio], [Glommio][glommio], [Monoio][monoio], [Seastar][seastar], and the effects-based [OCaml Eio][eio].

---

## Sources

- [io_uring_enter(2) — Linux manual page (per-opcode "Available since" notes)][man-enter]
- [io_uring_setup(2) — Linux manual page (setup flags, mixed SQE/CQE)][man-setup]
- [io_uring(7) — Linux manual page (overview, structures)][man7]
- [Linux kernel UABI header: include/uapi/linux/io_uring.h][uapi]
- [Linux kernel opcode dispatch table: io_uring/opdef.c][opdef]
- [liburing — Axboe's user-space library (headers, prep/register helpers)][liburing]
- ["Efficient IO with io_uring" — Jens Axboe (kernel.dk)][axboe-pdf]
- [What's new with io_uring in 6.11 and 6.12 (liburing wiki)][wiki-611]
- [Add io_uring futex/futexv support (LWN)][lwn-futex]
- [io_uring zero-copy Rx — kernel.org documentation (6.18)][zcrx]
- [io_uring feature catalog (companion)][features]
- [io_uring timeline (companion)][timeline]

<!-- References -->

[features]: ./features.md
[timeline]: ./timeline.md
[tokio]: ../tokio.md
[glommio]: ../glommio.md
[monoio]: ../monoio.md
[seastar]: ../seastar.md
[eio]: ../../algebraic-effects/ocaml-eio.md
[man-enter]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[man-setup]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[man7]: https://man7.org/linux/man-pages/man7/io_uring.7.html
[uapi]: https://github.com/torvalds/linux/blob/3b029c035b34bbc693405ddf759f0e9b920c27f1/include/uapi/linux/io_uring.h
[opdef]: https://github.com/torvalds/linux/blob/3b029c035b34bbc693405ddf759f0e9b920c27f1/io_uring/opdef.c
[liburing]: https://github.com/axboe/liburing/blob/e50e32a6b9030faba2e30fa0ba999571a0cffe28/src/include/liburing.h
[axboe-pdf]: https://kernel.dk/io_uring.pdf
[wiki-611]: https://github.com/axboe/liburing/wiki/What%27s-new-with-io_uring-in-6.11-and-6.12
[lwn-futex]: https://lwn.net/Articles/945891/
[zcrx]: https://docs.kernel.org/networking/iou-zcrx.html
