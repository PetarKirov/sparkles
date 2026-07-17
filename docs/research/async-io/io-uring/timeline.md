# io_uring — Chronology by Kernel Version

A version-by-version chronology of the Linux `io_uring` interface, from its v5.1 introduction through the v7.1-rc6 development tree, recording exactly when each operation (`IORING_OP_*`), setup flag (`IORING_SETUP_*`), registration opcode (`IORING_REGISTER_*`), and feature flag (`IORING_FEAT_*`) first appeared.

> **Scope and ground truth.** This document is a chronology, not a tutorial — for what these primitives _do_, see [io_uring features][doc-features]; for the opcode catalog, see [opcodes reference][doc-opcodes]. Version markers here are cross-checked against four sources: the [kernel UAPI header][io_uring.h] enum order (which is roughly chronological), the [liburing] man pages' "Available since" notes, the kernel git history (`git tag --contains` on the commit that adds each enum value), and external authorities (LWN, man7.org, kernel.dk). Where a marker is uncertain or where the liburing man page disagrees with the kernel git history, the discrepancy is called out inline rather than glossed over.

> **About the checkout.** The figures here are taken from a Linux tree at **v7.1-rc6** (`VERSION=7 PATCHLEVEL=1 SUBLEVEL=0 EXTRAVERSION=-rc6` in `linux/Makefile`, "Baby Opossum Posse") paired with **liburing 2.15** (`IO_URING_VERSION_MAJOR 2`, `IO_URING_VERSION_MINOR 15` in `liburing/src/include/liburing/io_uring_version.h`). That tree's git tags run `… v6.12 → v6.13 → v6.14 → … → v6.18 → v6.19 → v7.0 → v7.1-rc6`; the jump to the `7.x` series happened _after_ `6.19`, not by skipping `6.13+`. **Markers at `6.13` and later are forward-dated relative to general public knowledge** (those tags carry 2025–2026 commit dates in this tree) and should be treated as "as observed in this checkout" rather than long-settled history. Everything through `~6.12` is independently corroborated by stable external sources.

---

## How to read the "since" markers

The kernel exposes a feature the moment its commit lands in a merge window; the _first stable release that contains it_ is what "since vX.Y" means throughout this document. Three caveats:

| Subtlety                         | Explanation                                                                                                                                                                                                                                                                                                                                                                              |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Enum order ≈ chronology          | New `IORING_OP_*` values are appended to `enum io_uring_op`, so reading [io_uring.h][io_uring.h] top-to-bottom roughly recovers the introduction order. It is _not_ perfectly chronological — reserved slots and re-purposed values exist.                                                                                                                                               |
| liburing ≠ kernel                | A kernel feature is usable via raw `io_uring_setup(2)`/`io_uring_enter(2)` before [liburing] ships a `io_uring_prep_*` helper. The "liburing helper" column below is the ergonomic wrapper, which may trail the kernel by a release.                                                                                                                                                     |
| Runtime probing is authoritative | The only correct way to know if a running kernel supports an opcode is `IORING_REGISTER_PROBE` (since 5.6) / `io_uring_get_probe(3)`, or `IORING_REGISTER_QUERY` (kernel git: since 6.18 — note `liburing 2.15`'s `io_uring_register.2` marks it "since 6.15"; see the 6.15 discrepancy note below). Compile-time version checks are a heuristic. See [io_uring features][doc-features]. |

---

## 5.1 — The introduction (May 2019)

`io_uring` debuts, authored by **Jens Axboe**, replacing the moribund Linux AIO (`libaio`) interface. The model is two shared, memory-mapped ring buffers — a Submission Queue (SQ) and a Completion Queue (CQ) — plus three syscalls (`io_uring_setup`, `io_uring_enter`, `io_uring_register`). The canonical design write-up is Axboe's ["Efficient IO with io_uring"][axboe-pdf]; LWN's ["The rapid growth of io_uring"][lwn-growth] tracks the early opcode additions.

**Operations** (`enum io_uring_op`, first six slots):

- `IORING_OP_NOP`
- `IORING_OP_READV` / `IORING_OP_WRITEV`
- `IORING_OP_FSYNC`
- `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED` (against pre-registered buffers)
- `IORING_OP_POLL_ADD` / `IORING_OP_POLL_REMOVE`

**Registration** (`io_uring_register(2)`): `IORING_REGISTER_BUFFERS` / `IORING_UNREGISTER_BUFFERS`, `IORING_REGISTER_FILES` / `IORING_UNREGISTER_FILES`, and `IORING_REGISTER_FILES_UPDATE` — all noted "Available since 5.1" in `liburing/man/io_uring_register.2`.

**Setup**: the base flags `IORING_SETUP_IOPOLL` (busy-poll completions for `O_DIRECT` block I/O) and `IORING_SETUP_SQPOLL` / `IORING_SETUP_SQ_AFF` (kernel-side submission polling thread) ship in the initial interface.

This is the foundation every surveyed library targets as its baseline (read/write/fsync + poll). See [Tokio's][doc-tokio] and Glommio's backends in the matrix below.

> **Worked examples.** [`nop.d`][ex-nop] walks the minimal setup → submit → wait → CQE cycle; [`read-write-fixed.d`][ex-rwfixed] round-trips a payload through a registered (fixed) buffer; [`poll-add.d`][ex-poll] arms a one-shot `POLL_ADD`. All three are runnable `during` demos.

> **Worked examples.** [`registered-files.d`][ex-regfiles] reads a file by fixed-file table index with `IOSQE_FIXED_FILE`; [`sqpoll.d`][ex-sqpoll] submits a `NOP` with no `io_uring_enter` syscall via the `IORING_SETUP_SQPOLL` kernel thread.

## 5.2 — Sync file range (July 2019)

- `IORING_OP_SYNC_FILE_RANGE` — async `sync_file_range(2)`. (`io_uring_enter.2`: "Available since 5.2".)
- `IORING_UNREGISTER_EVENTFD` (the registration counterpart for eventfd notification; "Available since 5.2").
- `IORING_FEAT_*` flags begin: the very first `IORING_FEAT_SINGLE_MMAP` actually lands in 5.4 (below) — 5.2 predates the feature-flag system.

## 5.3 — Network message ops (September 2019)

- `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG` — async `sendmsg(2)`/`recvmsg(2)`. (`io_uring_enter.2`: "Available since 5.3".)
- Linked SQEs (`IOSQE_IO_LINK`): the ability to chain dependent SQEs so the next starts only after the previous succeeds; the man page records this submission-side feature "Available since 5.3".

> **Worked example.** [`linked-sqes.d`][ex-linked] chains a write to an `fsync` on the same fd with `IOSQE_IO_LINK`, showing the kernel-guaranteed write-before-`fsync` ordering and the failure-propagation (`-ECANCELED`) semantics of linked SQEs.

> **Worked example.** [`sendmsg-recvmsg.d`][ex-sendmsg] passes a file descriptor over a unix socket with `SCM_RIGHTS` via `SENDMSG`/`RECVMSG`.

## 5.4 — Timeouts and single mmap (November 2019)

- `IORING_OP_TIMEOUT` — a timeout that completes after N completions or a wall-clock interval. (`io_uring_enter.2`: "Available since 5.4".)
- `IORING_FEAT_SINGLE_MMAP` — SQ and CQ rings can share one `mmap`, cutting setup from three `mmap` calls to two. (`io_uring_setup.2`: "Available since kernel 5.4".)
- A historical note in several `io_uring_prep_*` man pages: "Very early kernels (5.4 and earlier) required state to be stable" before submission — an early-era constraint relaxed by `IORING_FEAT_SUBMIT_STABLE` (5.5).

> **Worked example.** [`timeout-link-timeout.d`][ex-timeout] fires a standalone relative `TIMEOUT` (completing with `-ETIME`) and then uses a `LINK_TIMEOUT` (5.5) to cancel a never-ready poll.

## 5.5 — Accept/connect, cancel, link-timeout (January 2020)

A pivotal release for networking and control flow:

- `IORING_OP_TIMEOUT_REMOVE`
- `IORING_OP_ACCEPT` — async `accept4(2)`.
- `IORING_OP_ASYNC_CANCEL` — cancel a previously submitted request by `user_data`.
- `IORING_OP_LINK_TIMEOUT` — a timeout attached to the _linked_ request, cancelling it if it doesn't finish in time.
- `IORING_OP_CONNECT` — async `connect(2)`.

All five are marked "Available since 5.5" in `io_uring_enter.2`, matching the [LWN growth article][lwn-growth] inventory.

**Features**: `IORING_FEAT_NODROP` (the kernel stops silently dropping CQEs on overflow; "since kernel 5.5"), `IORING_FEAT_SUBMIT_STABLE` (SQE data may be mutated immediately after submission; "since kernel 5.5"). (The `IORING_REGISTER_FILES_SKIP` skip-semantics for `IORING_REGISTER_FILES_UPDATE` arrive later — `io_uring_register.2` marks them "since 5.12", and the define is first present in the `v5.12` kernel; see 5.12 below.)

> **Worked examples.** [`tcp-echo.d`][ex-tcp] drives a loopback `ACCEPT`+`CONNECT`+`SEND`+`RECV` round-trip through a single ring; [`async-cancel.d`][ex-cancel] cancels an in-flight poll by its `user_data` and observes the `-ECANCELED` completion.

## 5.6 — The filesystem/syscall expansion (March 2020)

The largest single-release opcode batch — `io_uring` stops being "just block I/O" and becomes a general async-syscall surface:

- `IORING_OP_FALLOCATE`
- `IORING_OP_OPENAT` / `IORING_OP_OPENAT2` / `IORING_OP_CLOSE`
- `IORING_OP_FILES_UPDATE` (the in-SQE form of file-table update)
- `IORING_OP_STATX`
- `IORING_OP_READ` / `IORING_OP_WRITE` (the simple, non-vectored variants)
- `IORING_OP_FADVISE` / `IORING_OP_MADVISE`
- `IORING_OP_SEND` / `IORING_OP_RECV` (the buffer-pointer, non-`msghdr` forms)
- `IORING_OP_EPOLL_CTL` — async `epoll_ctl(2)`.

All marked "Available since 5.6" in `io_uring_enter.2`; the [LWN growth article][lwn-growth] enumerates the same set.

**Features**: `IORING_FEAT_CUR_PERSONALITY` ("since kernel 5.6"). **Registration**: `IORING_REGISTER_PROBE` (runtime opcode capability probing — _the_ portable feature-detection mechanism, "since 5.6"), `IORING_REGISTER_PERSONALITY` / `IORING_UNREGISTER_PERSONALITY`, `IORING_REGISTER_EVENTFD_ASYNC` (all "since 5.6").

> **Worked examples.** [`openat-statx-close.d`][ex-openat] chains `OPENAT`→`STATX`→`READ`→`CLOSE` asynchronously, feeding each op's result fd into the next; [`probe.d`][ex-probe] uses `IORING_REGISTER_PROBE` to print which opcodes the running kernel supports.

## 5.7 — Splice, provided buffers, fast poll (May 2020)

- `IORING_OP_SPLICE` — async `splice(2)`. (`io_uring_enter.2`: "Available since 5.7".)
- `IORING_OP_PROVIDE_BUFFERS` / `IORING_OP_REMOVE_BUFFERS` — the application hands the kernel a pool of buffers; recv-style ops pick one via `IOSQE_BUFFER_SELECT`. (Both "since 5.7".) This is the precursor to the far more efficient ring-provided buffers of 5.19.
- `IORING_FEAT_FAST_POLL` — internally arms a poll and retries, so an op like `RECVMSG` on a socket no longer needs an async worker thread to block. (`io_uring_setup.2`: "Available since 5.7"; corroborated by [man7][man7-enter].) A major latency/scaling win that effectively makes `io_uring` a competitive readiness reactor as well as a completion proactor.

> **Worked example.** [`splice-tee.d`][ex-splicetee] does a zero-copy `SPLICE` between pipes and a `TEE` duplication.

## 5.8 — Tee (August 2020)

- `IORING_OP_TEE` — async `tee(2)`. (`io_uring_enter.2`: "Available since 5.8".)
- `IORING_REGISTER_EVENTFD` ordering semantics refined ("since 5.8").

## 5.9 — 32-bit poll events (October 2020)

- `IORING_FEAT_POLL_32BITS` — poll requests accept the full 32-bit `epoll` event mask including `EPOLLEXCLUSIVE`. (`io_uring_setup.2`: "Available since kernel 5.9"; kernel git: the `IORING_FEAT_POLL_32BITS` define is **not** present in `v5.8` and first appears in `v5.9` via commit `5769a351b89c`, "`io_uring`: change the poll type to be 32-bits".)

## 5.10 — Restrictions and deferred setup (December 2020)

- `IORING_REGISTER_ENABLE_RINGS` + `IORING_SETUP_R_DISABLED` — create a ring in a disabled state, apply restrictions, then enable it. (`io_uring_setup.2`: "Available since 5.10".)
- `IORING_REGISTER_RESTRICTIONS` — sandbox a ring by whitelisting which opcodes/registrations/SQE flags are permitted. (`io_uring_register.2`: "Available since 5.10".)
- `IORING_FEAT_EXT_ARG` groundwork (finalized 5.11).

> **Worked example.** [`restrictions.d`][ex-restrict] sandboxes a ring to a whitelist of opcodes via `IORING_REGISTER_RESTRICTIONS` + `IORING_SETUP_R_DISABLED`.

## 5.11 — Filesystem mutation ops, SQPOLL without root (February 2021)

- `IORING_OP_SHUTDOWN` — async `shutdown(2)`.
- `IORING_OP_RENAMEAT` — async `renameat2(2)`.
- `IORING_OP_UNLINKAT` — async `unlinkat(2)`.

All "Available since 5.11" (`io_uring_enter.2`).

**Features**: `IORING_FEAT_EXT_ARG` — `io_uring_enter(2)` accepts an extended argument struct (a `timespec` timeout for `GETEVENTS`), "since kernel 5.11". **SQPOLL policy change**: the man pages note that _before 5.11_ SQPOLL required registered files and root; _in 5.11_ registration is no longer required and SQPOLL is usable as non-root with `CAP_SYS_NICE` (further relaxed in 5.13). Also `IORING_OP_ASYNC_CANCEL` gains `IORING_ASYNC_CANCEL_ALL`-style behavior ("since 5.11" in the cancel discussion).

> **Worked example.** [`fs-mutations.d`][ex-fsmut] performs async `MKDIRAT`/`SYMLINKAT`/`LINKAT`/`RENAMEAT`/`UNLINKAT` directory mutations.

## 5.12 — Files-update by index, native workers (April 2021)

- `IORING_REGISTER_FILES_UPDATE` can place an fd at a _specific_ index in the registered file table; descriptors set to `IORING_REGISTER_FILES_SKIP` are left untouched at that index. (`io_uring_register.2`: both "Available since 5.12"; the `IORING_REGISTER_FILES_SKIP` define is first present in the `v5.12` UAPI header.)
- `IORING_FEAT_NATIVE_WORKERS` — `io_uring` switches from kernel threads that assumed the owning task's identity to native worker threads. (`io_uring_setup.2`: "Available since kernel 5.12".)
- `IORING_OP_RENAMEAT`/`UNLINKAT` see refinements.

## 5.13 — Resource tags, poll update (June 2021)

- `IORING_REGISTER_BUFFERS2` / `IORING_REGISTER_BUFFERS_UPDATE` and `IORING_REGISTER_FILES2` / `IORING_REGISTER_FILES_UPDATE2` — the tagged-resource registration family. (All "Available since 5.13" in `io_uring_register.2`.)
- `IORING_FEAT_RSRC_TAGS` — registered buffers/files carry tags and can be updated without unregistering first; registration no longer waits for the ring to idle. (`io_uring_setup.2`: "since kernel 5.13".)
- `IORING_POLL_UPDATE_EVENTS` / `IORING_POLL_UPDATE_USER_DATA` — `IORING_OP_POLL_ADD` can _update_ an existing poll. (`io_uring_enter.2`: poll update "available since 5.13".)
- SQPOLL fully usable without special privileges in newer kernels ("In 5.13 this requirement was also relaxed").

## 5.14 — io-wq affinity controls (August 2021)

- `IORING_REGISTER_IOWQ_AFF` / `IORING_UNREGISTER_IOWQ_AFF` — pin the async (`io-wq`) worker pool to a CPU mask. (`io_uring_register.2`: "Available since 5.14".)

## 5.15 — More filesystem ops, worker caps (October 2021)

- `IORING_OP_MKDIRAT` — async `mkdirat(2)`.
- `IORING_OP_SYMLINKAT` — async `symlinkat(2)`.
- `IORING_OP_LINKAT` — async `linkat(2)`.

All "Available since 5.15" (`io_uring_enter.2`). `io_uring` **direct descriptors** are also introduced in 5.15 (`io_uring_enter.2`: "the 5.15 kernel, where direct descriptors were introduced"). Note: the dedicated auto-allocation sentinel `IORING_FILE_INDEX_ALLOC` is a _later_ addition — the define is first present in the `v5.19` UAPI header, not 5.15.

**Registration**: `IORING_REGISTER_IOWQ_MAX_WORKERS` — cap the number of bounded/unbounded async workers. (`io_uring_register.2`: "Available since 5.15".)

> **Worked example.** [`direct-descriptors.d`][ex-directfd] opens into a fixed-file slot, uses it by index, then `FIXED_FD_INSTALL`s it back to a real fd.

## 5.17 — CQE skip, faster cancel (March 2022)

- `IORING_FEAT_CQE_SKIP` — `IOSQE_CQE_SKIP_SUCCESS` lets a successful SQE produce _no_ CQE (errors still post one). (`io_uring_setup.2`: "Available since 5.17"; git: enum value lands in the 5.17 merge window.) A throughput win for fire-and-forget links.

> **Worked example.** [`cqe-skip.d`][ex-cqeskip] suppresses a successful op's CQE in a link with `IOSQE_CQE_SKIP_SUCCESS`.

## 5.18 — Ring-fd registration, msg-ring, linked-file (May 2022)

- `IORING_OP_MSG_RING` — send a message (two `u64`s) from one ring to another, enabling ring-to-ring wakeups. (`io_uring_enter.2`: "Available since 5.18". Git: the enum value `IORING_OP_MSG_RING,` is added by commit _"`io_uring`: add support for `IORING_OP_MSG_RING` command"_, first contained in tag `v5.18`.)
- `IORING_SETUP_SUBMIT_ALL` — submit all SQEs even if one errors. (`io_uring_setup.2`: "since 5.18".)
- `IORING_REGISTER_RING_FDS` / `IORING_UNREGISTER_RING_FDS` + `IORING_REGISTER_USE_REGISTERED_RING` — register the ring fd itself so `io_uring_enter(2)` need not pass a real fd. (`io_uring_register.2`: "Available since 5.18".)
- `IORING_FEAT_LINKED_FILE` — defer file assignment in a link chain until the request actually runs. (`io_uring_setup.2`: "since" — git: enum value first in `v5.18`.)

> **Worked examples.** [`msg-ring.d`][ex-msgring] posts a `u64` from one ring into another — the cross-core wakeup primitive; [`registered-ring-fd.d`][ex-regringfd] registers the ring fd so `io_uring_enter` skips per-call `fdget`/`fdput`.

## 5.19 — Buffer rings, zero-copy groundwork, big SQE/CQE (July 2022)

A second pivotal release (alongside 5.5 and 5.6) — it lands the modern high-throughput primitives:

- `IORING_OP_SOCKET` — async `socket(2)`. (`io_uring_enter.2`: "Available since 5.19". Git confirms enum value first in `v5.19`.)
- `IORING_OP_URING_CMD` — the passthrough/command channel (used by NVMe passthrough, `ublk`, etc.). (`io_uring_enter.2`: "Available since 5.19".)
- The extended-attribute ops `IORING_OP_FSETXATTR` / `IORING_OP_SETXATTR` / `IORING_OP_FGETXATTR` / `IORING_OP_GETXATTR` ("Available since 5.19").
- Multishot **accept** (`IORING_ACCEPT_MULTISHOT` on `IORING_OP_ACCEPT`) — one SQE yields a CQE per incoming connection while `IORING_CQE_F_MORE` stays set. ([man7][man7-enter]; "multishot variants are available since 5.19".)

**Registration**: `IORING_REGISTER_PBUF_RING` / `IORING_UNREGISTER_PBUF_RING` — **ring-provided buffers**, the efficient successor to `IORING_OP_PROVIDE_BUFFERS`: the kernel consumes buffers from a mapped ring with no per-buffer SQE. (`io_uring_register.2`: "Available since 5.19".)

**Setup**: `IORING_SETUP_COOP_TASKRUN` (don't IPI the target task for completion task-work; "Available since 5.19"), `IORING_SETUP_TASKRUN_FLAG` (surface `IORING_SQ_TASKRUN` so userspace knows to reap; "since 5.19"), `IORING_SETUP_SQE128` (128-byte SQEs, required by some `URING_CMD` users like NVMe passthrough; "since 5.19"), `IORING_SETUP_CQE32` (32-byte CQEs; "since 5.19").

> **Worked examples.** [`multishot-accept.d`][ex-msaccept] serves multiple loopback connections from a single armed accept SQE (each CQE carries `CQEFlags.MORE`); [`provided-buf-ring.d`][ex-pbufring] registers an `io_uring_buf` ring and issues a buffer-selecting `RECV`.

> **Worked example.** [`uring-cmd-socket.d`][ex-uringcmd] does socket `getsockopt`/`setsockopt` through the `URING_CMD` passthrough channel.

## 6.0 — Zero-copy send, single-issuer, sync cancel (October 2022)

- `IORING_OP_SEND_ZC` — zero-copy `send`; the data is pinned and a second "notification" CQE (`IORING_CQE_F_NOTIF`) fires when the kernel is done with the buffer. (`io_uring_enter.2`: "Available since 6.0". Git: enum value first in `v6.0`.)
- Multishot **recv** (`IORING_RECV_MULTISHOT`) becomes available — confirmed "available since kernel 6.0" by the [`io_uring_prep_recv_multishot(3)`][man7-recv-ms] man page.

**Setup**: `IORING_SETUP_SINGLE_ISSUER` — promise that one task submits, enabling lock elision. (`io_uring_setup.2`: "Available since 6.0".)

**Registration**: `IORING_REGISTER_SYNC_CANCEL` (synchronous cancel from userspace; "Available since 6.0"), `IORING_REGISTER_FILE_ALLOC_RANGE` (reserve a sub-range of the direct-descriptor table; "Available since 6.0").

> **Worked example.** [`send-zc.d`][ex-sendzc] performs a zero-copy `SEND_ZC` over loopback and asserts the two-CQE pattern: a transfer-result CQE (`CQEFlags.MORE`) followed by a separate notification CQE (`CQEFlags.NOTIF`).

> **Worked examples.** [`multishot-recv.d`][ex-msrecv] arms one `RECV` posting a CQE per segment into provided-ring buffers; [`sync-cancel.d`][ex-synccancel] cancels an in-flight poll synchronously with `IORING_REGISTER_SYNC_CANCEL`.

## 6.1 — Zero-copy sendmsg, deferred task-run (December 2022)

- `IORING_OP_SENDMSG_ZC` — the `msghdr` form of zero-copy send. (`io_uring_enter.2`: "Available since 6.1". Git: enum value first in `v6.1`.)
- `IORING_SETUP_DEFER_TASKRUN` — defer completion task-work until the app calls `io_uring_enter(2)` with `IORING_ENTER_GETEVENTS`; requires `SINGLE_ISSUER`. (`io_uring_setup.2`: "Available since 6.1".) Together with `COOP_TASKRUN` this is the latency/syscall-batching configuration most high-performance libraries adopt (see Glommio/monoio in the matrix).

> **Worked example.** [`defer-taskrun.d`][ex-defer] sets up a ring with `SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN` and reaps a `NOP` and a relative `TIMEOUT` through the `GETEVENTS`-driven deferred task-run path.

## 6.3 — Registered-ring registration (April 2023)

- `IORING_FEAT_REG_REG_RING` — `io_uring_register(2)` itself may be called via a registered ring fd. (`io_uring_setup.2`: "Available since kernel 6.3"; git: enum value first in `v6.3`.)

## 6.4 — Multishot timeout (June 2023)

- `IORING_TIMEOUT_MULTISHOT` (a `timeout_flags` bit on `IORING_OP_TIMEOUT`) — a repeating timer that posts a CQE per interval. (Git: the `IORING_TIMEOUT_MULTISHOT` define is first contained in tag `v6.4`.)

> **Worked example.** [`multishot-timeout.d`][ex-mstimeout] arms one `MULTISHOT` timeout, collects three recurring `-ETIME` ticks (each with `CQEFlags.MORE`), then stops the repeats with an `ASYNC_CANCEL`.

## 6.5 — No-mmap setup (August 2023)

- `IORING_SETUP_NO_MMAP` — userspace allocates the SQ/CQ memory itself and passes pointers, avoiding the kernel `mmap`. (`io_uring_setup.2`: "Available since 6.5".)
- `IORING_SETUP_REGISTERED_FD_ONLY` — used with `NO_MMAP`; the ring is only addressable via its registered index, never a real fd. (`io_uring_setup.2`: "Available since 6.5".)

> **Discrepancy flagged.** `liburing/man/io_uring_enter.2` marks `IORING_OP_WAITID` as "Available since 6.5". This is **incorrect** for the kernel: the enum value `IORING_OP_WAITID` is added by commit `f31ecf671ddc` (Sept 2023), whose **first containing release tag is `v6.7`**, and [LWN's waitid coverage][lwn-waitid] and the upstream patch series both target 6.7. This document therefore lists `IORING_OP_WAITID` under **6.7**, not 6.5.

## 6.6 — No SQ array (October 2023)

- `IORING_SETUP_NO_SQARRAY` — drop the indirection array between the SQ ring head and the SQE array; SQEs are consumed in order. (`io_uring_setup.2`: "Available since 6.6".)

## 6.7 — Futex, waitid, read-multishot (January 2024)

- `IORING_OP_WAITID` — async `waitid(2)`; a parent gets a CQE on child state change instead of blocking. (Git: enum first in `v6.7`; [LWN][lwn-waitid].) See the 6.5 discrepancy note above.
- `IORING_OP_FUTEX_WAIT` / `IORING_OP_FUTEX_WAKE` / `IORING_OP_FUTEX_WAITV` — async `futex(2)` operations; `FUTEX_WAIT` mirrors `FUTEX_WAIT_BITSET`. (`io_uring_enter.2`: "Available since 6.7"; [LWN futex coverage][lwn-futex].)
- `IORING_OP_READ_MULTISHOT` — repeatedly read from a pollable fd into ring-provided buffers, one CQE per chunk. (`io_uring_enter.2`: "Available since 6.7"; git: enum first in `v6.7`.)

> **Worked example.** [`futex.d`][ex-futex] parks a ring on a 32-bit private futex with `IORING_OP_FUTEX_WAIT` and is woken by a helper thread issuing a legacy `futex(2)` wake on the same word.

> **Worked examples.** [`waitid.d`][ex-waitid] asynchronously reaps a child process with `IORING_OP_WAITID`; [`read-multishot.d`][ex-readms] does repeated reads from a pipe into provided-ring buffers with `READ_MULTISHOT`; [`futex-waitv.d`][ex-futexv] waits on a vector of futexes with `FUTEX_WAITV`.

## 6.8 — Fixed-fd install, pbuf status (March 2024)

- `IORING_OP_FIXED_FD_INSTALL` — convert a registered (direct) descriptor back into a normal process fd. (`io_uring_enter.2`: "Available since 6.8"; git: enum first in `v6.8`.)
- `IORING_REGISTER_PBUF_STATUS` — query how many buffers remain in a provided-buffer ring. (`io_uring_register.2`: "Available since 6.8".)

## 6.9 — NAPI busy-poll, ftruncate (May 2024)

- `IORING_OP_FTRUNCATE` — async `ftruncate(2)`. (`io_uring_enter.2`: "Available since 6.9"; git: enum first in `v6.9`.)
- `IORING_REGISTER_NAPI` / `IORING_UNREGISTER_NAPI` — configure NAPI busy-polling for network completions, trading CPU for latency. (`io_uring_register.2`: "Available since 6.9".)

> **Worked example.** [`napi.d`][ex-napi] configures NAPI busy-poll with `IORING_REGISTER_NAPI`.

## 6.10 — Send/recv bundles (July 2024)

- `IORING_FEAT_RECVSEND_BUNDLE` — bundle multiple buffers into a single send/recv using provided-buffer rings (`io_uring_prep_send_bundle(3)` etc.). (Git: the `IORING_FEAT_RECVSEND_BUNDLE` define is first contained in tag `v6.10`.)

## 6.11 — Async bind/listen (September 2024)

- `IORING_OP_BIND` — async `bind(2)`. (Git: enum first in `v6.11`; `io_uring_enter.2`: "Available since 6.11".)
- `IORING_OP_LISTEN` — async `listen(2)`. (Git: enum first in `v6.11`; "Available since 6.11".)

> **Worked example.** [`socket-bind-listen.d`][ex-socketbl] drives a full async `SOCKET` + `BIND` + `LISTEN` lifecycle through the ring.

## 6.12 — Clock source, buffer cloning, min-timeout (November 2024)

- `IORING_REGISTER_CLOCK` — select the clock source used for completion waiting (e.g. `CLOCK_MONOTONIC` vs `CLOCK_BOOTTIME`). (`io_uring_register.2`: "Available since 6.12"; git: first in `v6.12`.)
- `IORING_REGISTER_CLONE_BUFFERS` (with `IORING_REGISTER_DST_REPLACE`) — clone a registered buffer table from one ring into another. (`io_uring_register.2`; git: first in `v6.12`. The man page notes 6.12 added basic cloning and _full-range_ cloning, with offset support arriving in 6.13.)
- `IORING_FEAT_MIN_TIMEOUT` — `io_uring_submit_and_wait_min_timeout(3)`: wait for a batch with a minimum timeout that extends without extra context switches. (Git: `IORING_FEAT_MIN_TIMEOUT` first in `v6.12`.)
- `IORING_REGISTER_SEND_MSG_RING` — issue a `MSG_RING` synchronously from `io_uring_register(2)`. (`io_uring_register.2`: "Available since kernel 6.13" — note this one is 6.13, see below.)

> **Forward-dated boundary.** Everything from here on (`6.13+`) carries 2025–2026 commit dates _in this checkout's git tree_. The markers are read directly from `liburing 2.15` man pages and `git tag --contains` in the v7.1-rc6 tree; treat them as "as observed here," since they post-date widely-distributed reference material.

> **Worked example.** [`clock-min-timeout.d`][ex-clock] selects the wait clock with `IORING_REGISTER_CLOCK` and uses a min-timeout batched wait.

## 6.13 — Ring resize, mem regions, hybrid iopoll (≈ January 2025, per tree)

- `IORING_REGISTER_RESIZE_RINGS` — grow/shrink the SQ/CQ rings of a live ring without tearing it down. (`io_uring_register.2`: "Available since kernel 6.13"; git: first in `v6.13`.)
- `IORING_REGISTER_MEM_REGION` — register a memory region the kernel can map for ring/aux data. (`io_uring_register.2`: "Available since kernel 6.13".)
- `IORING_REGISTER_SEND_MSG_RING` ("Available since kernel 6.13").
- `IORING_SETUP_HYBRID_IOPOLL` — a hybrid of interrupt-driven and busy-poll completions, used with `IORING_SETUP_IOPOLL`. (Git: `IORING_SETUP_HYBRID_IOPOLL` first in `v6.13`.)
- `IORING_REGISTER_CLONE_BUFFERS` gains offset/destination-range support ("6.13 added support for specifying the offsets…").

> **Worked example.** [`resize-rings.d`][ex-resize] grows a live ring's SQ/CQ with `IORING_REGISTER_RESIZE_RINGS`.

## 6.15 — Zero-copy receive, epoll-wait, vectored fixed, query (≈ May 2025, per tree)

A large networking/throughput release in this tree:

- `IORING_OP_RECV_ZC` — zero-copy _receive_ via a pre-registered zero-copy RX interface queue (`IORING_REGISTER_ZCRX_IFQ`); data arrives in auxiliary CQEs. (`io_uring_enter.2`: "Available since 6.15"; git: enum first in `v6.15`.)
- `IORING_OP_EPOLL_WAIT` — async `epoll_wait(2)`, letting legacy epoll loops fold into `io_uring`. (`io_uring_enter.2`: "Available since 6.15"; git: enum first in `v6.15`.)
- `IORING_OP_READV_FIXED` / `IORING_OP_WRITEV_FIXED` — vectored I/O whose iovec entries point into a _registered_ buffer, combining `READV`/`WRITEV` with the fixed-buffer fast path. (`io_uring_enter.2`: "Available since 6.15"; git: enum first in `v6.15`.)
- `IORING_REGISTER_ZCRX_IFQ` — register the zero-copy RX interface queue that `RECV_ZC` consumes. (`io_uring_register.2`: "Available since kernel 6.15"; git: enum value first in `v6.15`.) A later `IORING_REGISTER_ZCRX_CTRL` control op is documented alongside it.
- `IORING_REGISTER_QUERY` — a structured capability-query registration op (a successor/companion to `IORING_REGISTER_PROBE`). **Discrepancy flagged:** `liburing 2.15`'s `io_uring_register.2` marks it "Available since kernel 6.15", but in this tree the enum value `IORING_REGISTER_QUERY` is **not** present in `v6.15`; it is added by commit `c265ae75f900` ("`io_uring`: introduce `io_uring` querying", Sept 2025), whose first containing tag is **`v6.18`**. Treat the kernel availability as **6.18**, not 6.15.

> **Worked examples.** [`epoll-wait.d`][ex-epollwait] folds a legacy epoll set into the ring with `IORING_OP_EPOLL_WAIT`; [`recv-zc.d`][ex-recvzc] does zero-copy receive via a registered ZCRX interface queue (SKIPs without a capable NIC).

## 6.16 — Async pipe (≈ July 2025, per tree)

- `IORING_OP_PIPE` — async `pipe2(2)`; can create normal _or_ direct (fixed) descriptor pairs, writing the read/write ends into a two-element array. (`io_uring_enter.2`: "Available since 6.16"; git: enum first in `v6.16`.)

> **Worked example.** [`pipe.d`][ex-pipe] creates a pipe pair through the ring with `IORING_OP_PIPE`, then round-trips a byte through the new read/write ends.

## 6.18 — Mixed-size CQE (≈ November 2025, per tree)

- `IORING_SETUP_CQE_MIXED` — a ring may carry a mix of 16-byte and 32-byte CQEs, transparently, instead of committing to `CQE32` for the whole ring. (`io_uring_setup.2`: "Available since 6.18"; git: `IORING_SETUP_CQE_MIXED` first in `v6.18`.)

> **Worked example.** [`cqe-mixed.d`][ex-cqemixed] reaps mixed 16- and 32-byte CQEs from one ring with `IORING_SETUP_CQE_MIXED`.

## 6.19 — Mixed-size SQE and 128-byte opcodes (≈ February 2026, per tree)

- `IORING_SETUP_SQE_MIXED` — analogous to `CQE_MIXED` for submission: a ring mixes 64-byte and 128-byte SQEs.
- `IORING_OP_NOP128` — a `NOP` that explicitly uses a 128-byte SQE (testing/alignment on `SQE_MIXED` rings).
- `IORING_OP_URING_CMD128` — a `URING_CMD` that explicitly uses a 128-byte SQE for command-data headroom.

(Git: all three are added by commit `1cba30bf9fdd`, _"`io_uring`: add support for `IORING_SETUP_SQE_MIXED`"_, dated 2025-10-22, whose **first containing release tag is `v6.19`** in this tree.)

> **Marker accuracy note.** The `liburing 2.15` `io_uring_enter.2` text labels `IORING_OP_NOP128` and `IORING_OP_URING_CMD128` "Available since 6.19". In this tree the `v6.19` tag does exist and contains the commit, so the man-page marker is internally consistent. There is no `6.x → 7.0` _skip_: the sequence is `… 6.18 → 6.19 → 7.0 → 7.1`. Anyone reading this against a _public_ kernel (≤ 6.13 as of early 2025) will not find these opcodes.

> **Worked example.** [`sqe-mixed.d`][ex-sqemixed] issues mixed 64/128-byte SQEs + `NOP128` with `IORING_SETUP_SQE_MIXED` (needs ≥6.19).

## 7.0 — SQ rewind (≈ April 2026, per tree)

- `IORING_SETUP_SQ_REWIND` — used with `IORING_SETUP_NO_SQARRAY`, allows the SQ tail to be rewound (re-submission of not-yet-consumed SQEs). (`io_uring_setup.2`: "Available since 7.0"; git: `IORING_SETUP_SQ_REWIND` first in `v7.0`.)

> **Worked example.** [`sq-rewind.d`][ex-sqrewind] rewinds the SQ tail to re-submit unconsumed SQEs with `IORING_SETUP_SQ_REWIND` (needs ≥7.0).

## 7.1-rc6 — Current checkout (development, ≈ May 2026)

The tip of the tree used for this document. `enum io_uring_op` ends at `IORING_OP_URING_CMD128` then `IORING_OP_LAST`; no _new_ opcode appears between `v7.0` and `v7.1-rc6` beyond what 6.19/7.0 introduced. As an `-rc`, anything attributed to `7.1` proper is not yet finalized and is intentionally omitted.

---

## Feature/version × library matrix

Columns mark which surveyed runtimes are _known to use_ a feature (✓), _can but don't by default / optional_ (○), or _do not use it_ (—). Library backends evolve; entries reflect each library's documented `io_uring` backend strategy as covered in the sibling docs ([Tokio][doc-tokio], Glommio, monoio, [Boost.Asio][doc-asio], Seastar, libuv, Zig, .NET, [Eio][doc-eio]). Where a library has _no_ `io_uring` backend at all (Go's netpoller uses epoll; Boost.Asio's `io_uring` support is opt-in and partial), that is noted in the row legend rather than per-cell.

Legend for libraries: **Tok**=Tokio (`tokio-uring`), **Glo**=Glommio, **Mon**=monoio, **Asio**=Boost.Asio, **Sea**=Seastar, **libuv**, **Zig**=Zig std `Io`, **.NET**, **Eio**=OCaml Eio (`eio_linux`).

| Feature                                         | Since kernel | liburing helper                  | Tok | Glo | Mon | Asio | Sea | libuv | Zig | .NET | Eio |
| ----------------------------------------------- | ------------ | -------------------------------- | --- | --- | --- | ---- | --- | ----- | --- | ---- | --- |
| SQ/CQ rings + `setup`/`enter`/`register`        | 5.1          | `io_uring_queue_init`            | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `READV`/`WRITEV`, `FSYNC`                       | 5.1          | `io_uring_prep_readv`            | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `READ_FIXED`/`WRITE_FIXED` (registered buffers) | 5.1          | `io_uring_prep_read_fixed`       | ✓   | ✓   | ✓   | —    | ✓   | —     | ○   | ○    | ○   |
| `POLL_ADD`/`POLL_REMOVE`                        | 5.1          | `io_uring_prep_poll_add`         | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `IORING_SETUP_SQPOLL` (kernel SQ thread)        | 5.1          | `io_uring_queue_init_params`     | ○   | ○   | ○   | —    | ○   | —     | ○   | ○    | ○   |
| `IORING_SETUP_IOPOLL` (busy-poll completions)   | 5.1          | (setup flag)                     | —   | ✓   | —   | —    | ✓   | —     | —   | —    | —   |
| `SENDMSG`/`RECVMSG`                             | 5.3          | `io_uring_prep_sendmsg`          | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `TIMEOUT` (+ `LINK_TIMEOUT` 5.5)                | 5.4 / 5.5    | `io_uring_prep_timeout`          | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `IORING_FEAT_SINGLE_MMAP`                       | 5.4          | (feat flag)                      | ✓   | ✓   | ✓   | ✓    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `ACCEPT`/`CONNECT`, `ASYNC_CANCEL`              | 5.5          | `io_uring_prep_accept`           | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `IORING_FEAT_FAST_POLL`                         | 5.7          | (feat flag)                      | ✓   | ✓   | ✓   | ✓    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `OPENAT`/`CLOSE`/`STATX`, `READ`/`WRITE`        | 5.6          | `io_uring_prep_openat`           | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `SEND`/`RECV` (buffer form)                     | 5.6          | `io_uring_prep_send`             | ✓   | ✓   | ✓   | ○    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `IORING_REGISTER_PROBE` (capability probe)      | 5.6          | `io_uring_get_probe`             | ✓   | ✓   | ✓   | ✓    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `SPLICE`/`TEE`                                  | 5.7 / 5.8    | `io_uring_prep_splice`           | ○   | ○   | ○   | —    | ○   | —     | —   | —    | —   |
| `PROVIDE_BUFFERS` (legacy provided buffers)     | 5.7          | `io_uring_prep_provide_buffers`  | ○   | ○   | ○   | —    | —   | —     | —   | —    | —   |
| `IORING_FEAT_NODROP` / `CQE_SKIP` (5.17)        | 5.5 / 5.17   | (feat flag)                      | ✓   | ✓   | ✓   | ✓    | ✓   | ✓     | ✓   | ✓    | ✓   |
| `IORING_REGISTER_RING_FDS` (registered ring)    | 5.18         | `io_uring_register_ring_fd`      | ✓   | ✓   | ✓   | —    | ✓   | —     | ○   | ✓    | ✓   |
| `MSG_RING`                                      | 5.18         | `io_uring_prep_msg_ring`         | ○   | ○   | ○   | —    | ○   | —     | —   | —    | —   |
| Ring-provided buffers (`PBUF_RING`)             | 5.19         | `io_uring_setup_buf_ring`        | ✓   | ○   | ✓   | —    | ✓   | —     | ○   | ✓    | ○   |
| Multishot `ACCEPT`                              | 5.19         | `io_uring_prep_multishot_accept` | ✓   | ○   | ✓   | —    | ✓   | —     | ○   | ○    | ○   |
| `SOCKET`, `URING_CMD`, `SQE128`/`CQE32`         | 5.19         | `io_uring_prep_socket`           | ○   | ○   | ✓   | —    | ○   | —     | ○   | ○    | —   |
| `SEND_ZC` (zero-copy send)                      | 6.0          | `io_uring_prep_send_zc`          | ○   | ○   | ✓   | —    | ✓   | —     | ○   | ○    | —   |
| Multishot `RECV`                                | 6.0          | `io_uring_prep_recv_multishot`   | ✓   | ○   | ✓   | —    | ✓   | —     | ○   | ○    | ○   |
| `IORING_SETUP_SINGLE_ISSUER`                    | 6.0          | (setup flag)                     | ✓   | ✓   | ✓   | —    | ✓   | —     | ○   | ✓    | ✓   |
| `IORING_SETUP_DEFER_TASKRUN` (+ COOP 5.19)      | 6.1          | (setup flag)                     | ✓   | ✓   | ✓   | —    | ✓   | —     | ○   | ✓    | ✓   |
| `SENDMSG_ZC`                                    | 6.1          | `io_uring_prep_sendmsg_zc`       | ○   | ○   | ✓   | —    | ✓   | —     | —   | —    | —   |
| `IORING_TIMEOUT_MULTISHOT`                      | 6.4          | `io_uring_prep_timeout` (flag)   | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | ○   |
| `IORING_SETUP_NO_MMAP`                          | 6.5          | (setup flag)                     | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `FUTEX_WAIT`/`WAKE`/`WAITV`                     | 6.7          | `io_uring_prep_futex_wait`       | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `WAITID` (man says 6.5 — actually 6.7)          | 6.7          | `io_uring_prep_waitid`           | ○   | —   | —   | —    | —   | —     | —   | ○    | —   |
| `READ_MULTISHOT`                                | 6.7          | `io_uring_prep_read_multishot`   | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `FIXED_FD_INSTALL`                              | 6.8          | `io_uring_prep_fixed_fd_install` | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `IORING_REGISTER_NAPI` (busy-poll)              | 6.9          | `io_uring_register_napi`         | ○   | ✓   | ○   | —    | ✓   | —     | —   | —    | —   |
| `FTRUNCATE`                                     | 6.9          | `io_uring_prep_ftruncate`        | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `IORING_FEAT_RECVSEND_BUNDLE`                   | 6.10         | `io_uring_prep_send_bundle`      | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `BIND`/`LISTEN`                                 | 6.11         | `io_uring_prep_bind`             | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `IORING_REGISTER_RESIZE_RINGS`                  | 6.13†        | `io_uring_resize_rings`          | ○   | ○   | ○   | —    | ○   | —     | —   | ○    | —   |
| `RECV_ZC` + `ZCRX_IFQ` (zero-copy recv)         | 6.15†        | `io_uring_register_ifq`          | —   | —   | ○   | —    | ○   | —     | —   | —    | —   |
| `EPOLL_WAIT`                                    | 6.15†        | `io_uring_prep_epoll_wait`       | —   | —   | —   | —    | —   | —     | —   | —    | —   |
| `READV_FIXED`/`WRITEV_FIXED`                    | 6.15†        | `io_uring_prep_readv_fixed`      | ○   | ○   | ○   | —    | ○   | —     | —   | —    | —   |
| `PIPE`                                          | 6.16†        | `io_uring_prep_pipe`             | —   | —   | —   | —    | —   | —     | —   | —    | —   |
| `IORING_SETUP_CQE_MIXED`                        | 6.18†        | (setup flag)                     | —   | —   | —   | —    | —   | —     | —   | —    | —   |
| `SQE_MIXED`, `NOP128`, `URING_CMD128`           | 6.19†        | `io_uring_prep_nop128`           | —   | —   | —   | —    | —   | —     | —   | —    | —   |
| `IORING_SETUP_SQ_REWIND`                        | 7.0†         | (setup flag)                     | —   | —   | —   | —    | —   | —     | —   | —    | —   |

† Markers at 6.13 and beyond are forward-dated relative to public knowledge; they are read from this checkout's `liburing 2.15` man pages and v7.1-rc6 git tags. Library-usage cells for these very-recent features are conservatively `—`/`○` because the surveyed libraries had not adopted them as of their last reviewed releases.

**Library-row caveats:**

- **Boost.Asio** (`Asio` column): `io_uring` is an _optional_ backend (`BOOST_ASIO_HAS_IO_URING`), used only as a reactor substitute; it does not exploit zero-copy or multishot. Hence mostly `○`/`—`.
- **libuv**: gained an `io_uring` backend (file ops, then some net ops) but stays conservative — read/write/fsync/poll-style usage, not the modern zero-copy/multishot surface.
- **Go**: absent from the matrix — the Go runtime netpoller is epoll/kqueue-based and does **not** use `io_uring` (see the Go netpoller sibling doc).
- **Eio** (`eio_linux`): uses a core set (rings, read/write, openat, poll, send/recv, registered fds, single-issuer/defer-taskrun) but not the newest zero-copy ops; see [Eio][doc-eio].

---

## Worked examples

Each row links a runnable, standalone [`during`][during]-based D program in the `examples/`
directory next to this file. Every example demonstrates its feature against the _live_ kernel
and degrades to a `SKIP` (exit 0) on kernels that lack it, so the whole set stays green from
the 5.1 baseline up to a bleeding-edge tree. Run them all with `ci --example-files`, or one at
a time with `dub run --single <file>`.

| Example                                | Since     | Demonstrates                                                         |
| -------------------------------------- | --------- | -------------------------------------------------------------------- |
| [`nop.d`][ex-nop]                      | 5.1       | Minimal setup → submit → wait → CQE cycle                            |
| [`read-write-fixed.d`][ex-rwfixed]     | 5.1       | Registered (fixed) buffers via `WRITE_FIXED`/`READ_FIXED`            |
| [`poll-add.d`][ex-poll]                | 5.1       | One-shot `POLL_ADD` readiness on a pipe                              |
| [`registered-files.d`][ex-regfiles]    | 5.1       | Read a file by fixed-file index with `IOSQE_FIXED_FILE`              |
| [`sqpoll.d`][ex-sqpoll]                | 5.1       | `NOP` with no `io_uring_enter` via the `SQPOLL` kernel thread        |
| [`linked-sqes.d`][ex-linked]           | 5.3       | `IOSQE_IO_LINK` write→`fsync` ordering                               |
| [`sendmsg-recvmsg.d`][ex-sendmsg]      | 5.3       | Pass an fd over a unix socket (`SCM_RIGHTS`) via `SENDMSG`/`RECVMSG` |
| [`timeout-link-timeout.d`][ex-timeout] | 5.4 / 5.5 | `TIMEOUT` (`-ETIME`) and `LINK_TIMEOUT` cancelling a poll            |
| [`tcp-echo.d`][ex-tcp]                 | 5.5 / 5.6 | Loopback `ACCEPT`+`CONNECT`+`SEND`+`RECV` on one ring                |
| [`async-cancel.d`][ex-cancel]          | 5.5       | `ASYNC_CANCEL` of an in-flight poll by `user_data`                   |
| [`openat-statx-close.d`][ex-openat]    | 5.6       | Async `OPENAT`→`STATX`→`READ`→`CLOSE` chain                          |
| [`probe.d`][ex-probe]                  | 5.6       | `IORING_REGISTER_PROBE` per-opcode capability table                  |
| [`splice-tee.d`][ex-splicetee]         | 5.7       | Zero-copy `SPLICE` between pipes and `TEE` duplication               |
| [`restrictions.d`][ex-restrict]        | 5.10      | Sandbox a ring via `REGISTER_RESTRICTIONS` + `R_DISABLED`            |
| [`fs-mutations.d`][ex-fsmut]           | 5.11      | Async `MKDIRAT`/`SYMLINKAT`/`LINKAT`/`RENAMEAT`/`UNLINKAT`           |
| [`direct-descriptors.d`][ex-directfd]  | 5.15      | Open into a fixed slot, then `FIXED_FD_INSTALL` back to a real fd    |
| [`cqe-skip.d`][ex-cqeskip]             | 5.17      | Suppress a successful op's CQE with `IOSQE_CQE_SKIP_SUCCESS`         |
| [`msg-ring.d`][ex-msgring]             | 5.18      | Post a `u64` from one ring into another (cross-core wakeup)          |
| [`registered-ring-fd.d`][ex-regringfd] | 5.18      | Register the ring fd so `io_uring_enter` skips `fdget`/`fdput`       |
| [`multishot-accept.d`][ex-msaccept]    | 5.19      | Multishot `ACCEPT` (`CQEFlags.MORE` keeps it armed)                  |
| [`provided-buf-ring.d`][ex-pbufring]   | 5.19      | Ring-provided buffers (`PBUF_RING`) selecting a `RECV`               |
| [`uring-cmd-socket.d`][ex-uringcmd]    | 5.19      | Socket `getsockopt`/`setsockopt` via `URING_CMD` passthrough         |
| [`send-zc.d`][ex-sendzc]               | 6.0       | Zero-copy `SEND_ZC` transfer-CQE → notification-CQE                  |
| [`multishot-recv.d`][ex-msrecv]        | 6.0       | Multishot `RECV` posting a CQE per segment into provided buffers     |
| [`sync-cancel.d`][ex-synccancel]       | 6.0       | Synchronous cancel of a poll via `REGISTER_SYNC_CANCEL`              |
| [`defer-taskrun.d`][ex-defer]          | 6.1       | `SINGLE_ISSUER`+`DEFER_TASKRUN`+`COOP_TASKRUN` setup                 |
| [`multishot-timeout.d`][ex-mstimeout]  | 6.4       | `IORING_TIMEOUT_MULTISHOT` recurring timer                           |
| [`futex.d`][ex-futex]                  | 6.7       | Async `FUTEX_WAIT` woken by a legacy `futex(2)` wake                 |
| [`waitid.d`][ex-waitid]                | 6.7       | Async child-process reap with `IORING_OP_WAITID`                     |
| [`read-multishot.d`][ex-readms]        | 6.7       | Repeated pipe reads into provided buffers via `READ_MULTISHOT`       |
| [`futex-waitv.d`][ex-futexv]           | 6.7       | Wait on a vector of futexes with `FUTEX_WAITV`                       |
| [`napi.d`][ex-napi]                    | 6.9       | Configure NAPI busy-poll with `REGISTER_NAPI`                        |
| [`socket-bind-listen.d`][ex-socketbl]  | 6.11      | Async `SOCKET` + `BIND` + `LISTEN` lifecycle through the ring        |
| [`clock-min-timeout.d`][ex-clock]      | 6.12      | Select the wait clock (`REGISTER_CLOCK`) + min-timeout wait          |
| [`resize-rings.d`][ex-resize]          | 6.13      | Grow a live ring's SQ/CQ with `REGISTER_RESIZE_RINGS`                |
| [`epoll-wait.d`][ex-epollwait]         | 6.15      | Fold a legacy epoll set into the ring with `EPOLL_WAIT`              |
| [`recv-zc.d`][ex-recvzc]               | 6.15      | Zero-copy receive via a registered ZCRX interface queue              |
| [`pipe.d`][ex-pipe]                    | 6.16      | `IORING_OP_PIPE` pipe-pair creation through the ring                 |
| [`cqe-mixed.d`][ex-cqemixed]           | 6.18      | Reap mixed 16- and 32-byte CQEs with `SETUP_CQE_MIXED`               |
| [`sqe-mixed.d`][ex-sqemixed]           | 6.19      | Mixed 64/128-byte SQEs + `NOP128` with `SETUP_SQE_MIXED`             |
| [`sq-rewind.d`][ex-sqrewind]           | 7.0       | Rewind the SQ tail to re-submit SQEs with `SETUP_SQ_REWIND`          |

---

## Cross-references

- Mechanics of each primitive: [io_uring features][doc-features].
- Per-opcode catalog with SQE field layouts: [opcodes reference][doc-opcodes].
- How runtimes drive the loop: [Tokio][doc-tokio].
- Completion-based I/O behind an effect system: [OCaml Eio][doc-eio].

---

## Sources

- [Linux kernel source — `include/uapi/linux/io_uring.h`][io_uring.h] (enum `io_uring_op`, flag defines; the v7.1-rc6 checkout)
- [liburing repository][liburing] (man pages `io_uring_enter.2`, `io_uring_setup.2`, `io_uring_register.2`; version header `io_uring_version.h`)
- [io_uring_enter(2) — man7.org][man7-enter]
- [io_uring_setup(2) — man7.org][man7-setup]
- [io_uring_register(2) — man7.org][man7-register]
- [io_uring_prep_recv_multishot(3) — man7.org][man7-recv-ms]
- ["Efficient IO with io_uring" — Jens Axboe (kernel.dk)][axboe-pdf]
- ["The rapid growth of io_uring" — LWN.net][lwn-growth]
- ["Add io_uring support for waitid" — LWN.net][lwn-waitid]
- ["Add io_uring support for futex wait/wake" — LWN.net][lwn-futex]
- [Linux kernel version history — Wikipedia][wiki-versions] (release dates)

<!-- References -->

[io_uring.h]: https://github.com/torvalds/linux/blob/3b029c035b34bbc693405ddf759f0e9b920c27f1/include/uapi/linux/io_uring.h
[liburing]: https://github.com/axboe/liburing
[man7-enter]: https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
[man7-setup]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[man7-register]: https://man7.org/linux/man-pages/man2/io_uring_register.2.html
[man7-recv-ms]: https://man7.org/linux/man-pages/man3/io_uring_prep_recv_multishot.3.html
[axboe-pdf]: http://web.archive.org/web/20260624135046/https://kernel.dk/io_uring.pdf
[lwn-growth]: https://lwn.net/Articles/810414/
[lwn-waitid]: https://lwn.net/Articles/940294/
[lwn-futex]: https://lwn.net/Articles/934350/
[wiki-versions]: https://en.wikipedia.org/wiki/Linux_kernel_version_history
[doc-features]: ./features.md
[doc-opcodes]: ./opcodes-reference.md
[doc-tokio]: ../tokio.md
[doc-asio]: ../boost-asio.md
[doc-eio]: ../../algebraic-effects/ocaml-eio.md
[during]: ../d-landscape.md
[ex-nop]: ./examples/nop.d
[ex-rwfixed]: ./examples/read-write-fixed.d
[ex-poll]: ./examples/poll-add.d
[ex-linked]: ./examples/linked-sqes.d
[ex-timeout]: ./examples/timeout-link-timeout.d
[ex-tcp]: ./examples/tcp-echo.d
[ex-cancel]: ./examples/async-cancel.d
[ex-openat]: ./examples/openat-statx-close.d
[ex-probe]: ./examples/probe.d
[ex-msaccept]: ./examples/multishot-accept.d
[ex-pbufring]: ./examples/provided-buf-ring.d
[ex-sendzc]: ./examples/send-zc.d
[ex-defer]: ./examples/defer-taskrun.d
[ex-mstimeout]: ./examples/multishot-timeout.d
[ex-futex]: ./examples/futex.d
[ex-pipe]: ./examples/pipe.d
[ex-regfiles]: ./examples/registered-files.d
[ex-sqpoll]: ./examples/sqpoll.d
[ex-sendmsg]: ./examples/sendmsg-recvmsg.d
[ex-splicetee]: ./examples/splice-tee.d
[ex-restrict]: ./examples/restrictions.d
[ex-fsmut]: ./examples/fs-mutations.d
[ex-directfd]: ./examples/direct-descriptors.d
[ex-cqeskip]: ./examples/cqe-skip.d
[ex-msgring]: ./examples/msg-ring.d
[ex-regringfd]: ./examples/registered-ring-fd.d
[ex-uringcmd]: ./examples/uring-cmd-socket.d
[ex-msrecv]: ./examples/multishot-recv.d
[ex-synccancel]: ./examples/sync-cancel.d
[ex-waitid]: ./examples/waitid.d
[ex-readms]: ./examples/read-multishot.d
[ex-futexv]: ./examples/futex-waitv.d
[ex-napi]: ./examples/napi.d
[ex-socketbl]: ./examples/socket-bind-listen.d
[ex-clock]: ./examples/clock-min-timeout.d
[ex-resize]: ./examples/resize-rings.d
[ex-epollwait]: ./examples/epoll-wait.d
[ex-recvzc]: ./examples/recv-zc.d
[ex-cqemixed]: ./examples/cqe-mixed.d
[ex-sqemixed]: ./examples/sqe-mixed.d
[ex-sqrewind]: ./examples/sq-rewind.d
