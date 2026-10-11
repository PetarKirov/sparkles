# Linux futexes

The primitive every other page in this catalog is measured against: a 32-bit
word in user memory, a kernel-side compare-and-block keyed by that word's
address, and a global hash table of wait queues that exists only while someone
is waiting. Twenty years of additions — requeue, `WAKE_OP`, priority
inheritance, robust lists, `futex_waitv`, the `futex2` calls, per-process hash
tables and io_uring opcodes — all sit on the same bucket-and-key machinery.

|                     |                                                                                                                                                                                                                                                                                                                                               |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**            | kernel mechanism (OS wait primitive)                                                                                                                                                                                                                                                                                                          |
| **Language**        | C (kernel); used from glibc, Rust `std`, Go, Zig, Wine and everything else on Linux                                                                                                                                                                                                                                                           |
| **License**         | GPL-2.0 (kernel); the UAPI header is `GPL-2.0 WITH Linux-syscall-note`                                                                                                                                                                                                                                                                        |
| **Repository**      | [`torvalds/linux`][linux] at `a90ee4305c4a` (v7.3-rc6, 2026-10-04)                                                                                                                                                                                                                                                                            |
| **Versions**        | futex 2.5.7 / 2.6.0; `FUTEX_PRIVATE_FLAG` 2.6.22; `futex_waitv` 5.16 (2022-01-09); `futex_wait`/`futex_wake`/`futex_requeue` and `IORING_OP_FUTEX_*` 6.7 (2024-01-07); private hash + `FUTEX2_NUMA`/`FUTEX2_MPOL` 6.16 (2025-07-27); `FUTEX_ROBUST_UNLOCK` v7.2                                                                               |
| **Word sizes**      | 32-bit only; `FUTEX2_SIZE_U8/U16/U64` are reserved in the ABI and rejected                                                                                                                                                                                                                                                                    |
| **Process scope**   | shared by default (keyed by inode/page offset); `FUTEX_PRIVATE_FLAG` / `FUTEX2_PRIVATE` keys by `(mm, address)`                                                                                                                                                                                                                               |
| **Event-loop hook** | io_uring `IORING_OP_FUTEX_WAIT`/`WAKE`/`WAITV` (6.7) — a futex wait completes as a CQE; no fd/epoll form (`FUTEX_FD` removed in 2.6.26)                                                                                                                                                                                                       |
| **Source read**     | [`kernel/futex/waitwake.c`][waitwake], [`core.c`][core], [`futex.h`][futex-h], [`syscalls.c`][syscalls], [`requeue.c`][requeue], [`io_uring/futex.c`][io-futex], [`include/uapi/linux/futex.h`][uapi], [`futex2.rst`][futex2-rst]; man-pages 6.16 `futex(2)` and the per-op `FUTEX_*(2const)` pages; [Drepper, _Futexes Are Tricky_][drepper] |

## Overview

### What it solves

A lock word that lives in user memory can be acquired and released with one
atomic instruction; the kernel is needed only to put a loser to sleep and to
wake it. The futex is exactly that missing half. The man page states the
contract ([`futex(2)`][man-futex]):

> The loading of the futex word's value, the comparison of that value with the
> expected value, and the actual blocking will happen atomically and will be
> totally ordered with respect to concurrent operations performed by other
> threads on the same futex word. […] Analogously to an atomic
> compare-and-exchange operation that potentially changes shared memory,
> blocking via a futex is an atomic compare-and-block operation.

The kernel's own statement of the guarantee is in
[`futex_wait_setup`][waitwake-setup]:

> The basic logical guarantee of a futex is that it blocks ONLY if cond(var)
> is known to be true at the time of blocking, for any cond.

### Design philosophy

The kernel attaches no meaning to the word. Drepper's paper puts it as "The
value of the variable is fully under the control of the application. No value
has a specific meaning" ([Drepper §2][drepper]), and the whole of user-space
locking design — 3-state mutexes, sequence-counter condvars, parking lots — is
the art of choosing what the word means. The exceptions are the PI and robust
operations, where the kernel reads the low 30 bits as a TID and owns the
`FUTEX_WAITERS` (`0x80000000`) and `FUTEX_OWNER_DIED` (`0x40000000`) bits
([`uapi/linux/futex.h`][uapi-owner-died]).

Nothing is allocated per futex. A waiter's queue entry (`struct futex_q`) lives
on the waiting task's kernel stack; the "futex" exists only as a key that hashes
to a bucket while a waiter is queued there ([`futex.h`][futex-h-q]).

## How it works

**Keys.** [`get_futex_key`][core-key] turns the address into a key: for a
private futex `( current->mm, address, 0 )`, for a shared one
`( inode->i_sequence, page offset within mapping, offset_within_page )`, so
two processes mapping the same file page meet in the same queue "without
keeping the page pinned for the duration of the FUTEX_WAIT". The address must
be "naturally" aligned; a misaligned word is `EINVAL`.

**Buckets.** A key hashes (`jhash2`) into a table of
`struct futex_hash_bucket { atomic_t waiters; spinlock_t lock; struct plist_head chain; } ____cacheline_aligned_in_smp`
([`futex.h`][futex-h-bucket]) — one cache line per bucket. The global table is
sized at boot to `256 * num_possible_cpus()` buckets (rounded to a power of
two), split per NUMA node ([`futex_init`][core-init]). Since 6.16 a process
also gets a **private hash** used only for process-private futexes: the
commit introducing it explains that with one system-wide table "the same
logical lock (pointer) can end up in a different hash bucket on each
invocation of the application", so unrelated programs contend on bucket
spinlocks unpredictably ([`80367ad01d93`][commit-private-hash]). The kernel
allocates it on the first `clone(CLONE_VM)` ([`fork.c`][fork-hash]) at
`roundup_pow_of_two(4 * threads)` buckets clamped to `[16, global size]`
([`futex_hash_allocate_default`][core-default]), and
`prctl(PR_FUTEX_HASH, PR_FUTEX_HASH_SET_SLOTS, n)` sets it explicitly ("Each
slot requires 64 bytes of memory", [`PR_FUTEX_HASH_SET_SLOTS(2const)`][man-set-slots]).

**Wait.** `futex_wait_setup` increments the bucket's `waiters` count, takes
the bucket lock, reads the user word with page faults disabled (falling back
to fault it in and retry), returns `-EWOULDBLOCK` if it differs, otherwise
sets the task state, enqueues the `futex_q` and drops the lock. The ordering
argument — the waiter's `waiters++` / `smp_mb` pairs with the waker's
`smp_mb` / `waiters` read, so `x==0 && y==0 is impossible` — is spelled out
in the header comment of [`waitwake.c`][waitwake] and is what lets `FUTEX_WAKE`
return without taking the lock when nobody waits.

**Wake.** [`futex_wake`][waitwake-wake] hashes, checks `futex_hb_waiters_pending`
and returns early if zero, else locks the bucket, walks the chain matching
keys and bitsets, calls each waiter's `q->wake` callback up to `nr_wake`, and
issues the actual wake-ups after dropping the lock (`wake_up_q`). The
pluggable `wake` callback is what io_uring overrides (below).

**The operations.** `FUTEX_WAIT`/`WAKE`; `FUTEX_WAIT_BITSET`/`WAKE_BITSET`
(2.6.25: a 32-bit mask per waiter, matched with `&`, and an absolute timeout);
`FUTEX_REQUEUE` (obsolete) and `FUTEX_CMP_REQUEUE` (2.6.7: wake `n`, move up to
`m` waiters to a second futex's queue, only if the first word still equals
`val3`); `FUTEX_WAKE_OP` (2.6.14: atomically modify a second word and
conditionally wake its waiters too — designed for condvars, see
[Drepper §2][drepper]); the PI family `FUTEX_LOCK_PI`/`UNLOCK_PI`/`TRYLOCK_PI`
(2.6.18), `FUTEX_LOCK_PI2` (5.14) and `FUTEX_WAIT_REQUEUE_PI`/`CMP_REQUEUE_PI`,
built on an in-kernel `rt_mutex` per contended PI futex
([`futex_pi_state`][futex-h-pi]); robust lists, a per-thread user-space list the
kernel walks at thread exit, setting `FUTEX_OWNER_DIED` and waking a waiter
([`syscalls.c`][syscalls-robust]). `FUTEX_FD` existed from 2.6.0 to 2.6.25 and
was removed "Because it was inherently racy" ([`FUTEX_FD(2const)`][man-futex-fd]).

**futex2.** `futex_waitv` (5.16) waits on up to `FUTEX_WAITV_MAX` = 128
`struct futex_waitv { __u64 val; __u64 uaddr; __u32 flags; __u32 __reserved; }`
entries and returns the index of _a_ woken one — "not necessaryily [sic] the
futex with the smallest index, nor the one most recently woken"
([`syscalls.c`][syscalls-waitv]). Its stated purpose was emulating
`WaitForMultipleObjects` for Proton ([kernelnewbies 5.16][kn-516]). 6.7 added
`futex_wait`, `futex_wake` and `futex_requeue` — "Identical to the traditional
FUTEX*WAIT_BITSET op, except it is part of the futex2 family"
([`syscalls.c`][syscalls-wait]) — taking `FUTEX2*\*` flags whose low two bits are a
size field.

## Analysis

### Semantics

Compare-and-block on one 32-bit word; wake `n` (1 and `INT_MAX` are the only
values Drepper calls sensible). Wake order is **not FIFO in general**: the
chain is a `plist` keyed by `min(normal_prio, MAX_RT_PRIO)`, so "all RT-threads
are woken first in priority order, and the others are woken last, in FIFO
order" ([`__futex_queue`][core-queue]); the man page promises nothing ("No
guarantee is provided about which waiters are awoken",
[`FUTEX_WAKE(2const)`][man-futex-wake]). Bitsets give 32 independent wait
classes per word — enough to separate readers from writers on one rwlock word.
Requeue is the kernel's form of [wait morphing](./concepts.md#wait-morphing):
Drepper's motivating case is `pthread_cond_broadcast`, which moves all but one
waiter onto the mutex's queue so "one by one wakeup, no cache line ping-pong"
([Drepper §8][drepper]).

### Sizes and alignment

Four bytes, four-byte aligned, "on all platforms, including 64-bit systems"
([`futex(2)`][man-futex]). The futex2 ABI reserves room for more and the kernel
refuses it ([`futex.h`][futex-h-size]):

```c
/* Only 32bit futexes are implemented -- for now */
if ((flags & FLAGS_SIZE_MASK) != FLAGS_SIZE_32)
	return false;
```

and the UAPI header keeps `#define FUTEX_32 FUTEX2_SIZE_U32 /* historical accident :-( */`
([`uapi/linux/futex.h`][uapi-futex32]). [`futex2.rst`][futex2-rst] says the same:
"Futexes can be of different sizes: 8, 16, 32 or 64 bits. Currently, the only
supported one is 32 bit sized futex". `FUTEX2_NUMA` doubles the word: the second
u32 holds a node id (`FUTEX_NO_NODE` = -1) that picks the node-local table.
**Consequence for Sparkles:** a 1-byte parking-lot lock cannot be a futex word
directly on Linux; it must park on a hashed table of its own (or on a 32-bit
word containing it).

### Timeouts and clocks

`FUTEX_WAIT` takes a **relative** timeout, internally converted to an absolute
`CLOCK_MONOTONIC` deadline; `FUTEX_WAIT_BITSET`, `FUTEX_WAIT_REQUEUE_PI` and
`FUTEX_LOCK_PI2` take **absolute** ones, against `CLOCK_MONOTONIC` unless
`FUTEX_CLOCK_REALTIME` is set; `FUTEX_LOCK_PI` is absolute `CLOCK_REALTIME`
([`futex_init_timeout`][syscalls-timeout]). The futex2 calls and
`futex_waitv` are absolute, with an explicit `clockid` of `CLOCK_MONOTONIC` or
`CLOCK_REALTIME` only. Rust `std` uses `FUTEX_WAIT_BITSET` with a full mask
for exactly this reason: "to be able to give an absolute time rather than a
relative time" ([`futex.rs`][rust-futex-linux]). io_uring futex waits have no
timeout field at all; a linked `IORING_OP_LINK_TIMEOUT` is the only bound.

### Spurious wakeups and wake counts

Kernel-side, a wait that is woken by a signal or spuriously retries unless a
signal is actually pending ([`__futex_wait`][waitwake-wait]); of `EINTR` the
man page says "Before Linux 2.6.22, this error could also be returned for a
spurious wakeup; since Linux 2.6.22, this no longer happens"
([`FUTEX_WAIT(2const)`][man-futex-wait]).
But a return of 0 is still not proof: "a wake-up can also be caused by common
futex usage patterns in unrelated code that happened to have previously used
the futex word's memory location […] callers should always conservatively
assume that a return value of 0 can mean a spurious wake-up". `FUTEX_WAKE`
returns the number woken; `FUTEX_CMP_REQUEUE` returns woken plus requeued;
`futex_wake` (futex2) and `IORING_OP_FUTEX_WAKE` use `FLAGS_STRICT` so that
"waking 0 futexes yields a 0 result" ([`io_futex_wake`][io-futex-wake]).

### Process scope

Shared is the default: a wait without `FUTEX_PRIVATE_FLAG` looks up the VMA
and, for a shared mapping, keys by inode; the flag "allows the kernel to make
some additional performance optimizations" ([`futex(2)`][man-futex]) — and
since 6.16 it also selects the per-process hash. Private and shared waiters on
the same address do not meet. PI futexes add a cross-mm check
(`59b3732f95dd`, "Reject cross-mm private futex owners").

### Cost

Structural: one syscall, one `jhash2`, one bucket spinlock, a page-faults-off
user read; nothing allocated. The `waiters` counter lets a wake on an empty
bucket skip the lock, but not the syscall. Measured locally (AMD Ryzen 9
7940HX, Linux 6.18.26, LDC 1.41 `-O2`, 2·10⁶ iterations, three runs, a
throwaway program — not a CI example): `FUTEX_WAKE_PRIVATE` with no waiters
**≈ 272 ns**, `FUTEX_WAIT_PRIVATE` with a mismatched value **≈ 324 ns**, an
uncontended `cas` + release store **≈ 1.6 ns**, and a two-thread futex
ping-pong round trip **≈ 5.1–5.4 µs**. The two-orders-of-magnitude gap is why
every design here keeps a "has waiters" state in the word: Drepper's `mutex2`
exists to turn the unlock-side syscall into an atomic op ("We traded one
system call for an atomic operation", [Drepper §5][drepper]).

The hash is also a contention point: the private-hash work exists because
bucket-lock collisions between unrelated processes caused "high latency's to
acquire the futex_hash_bucket::lock especially if the lock owner is limited to
a CPU and can not be effectively PI boosted" ([`80367ad01d93`][commit-private-hash]).

### Event-loop integration

There is no readiness form: `FUTEX_FD` died because a file descriptor cannot
carry the expected value — "None of the three interfaces, select, poll, and
epoll, supports passing such information down" ([Drepper §9][drepper]). The
completion form is io_uring (6.7):

- **`IORING_OP_FUTEX_WAIT`** — `addr` is the word, `addr2` the expected value,
  `addr3` the bitset, and the `FUTEX2_*` flags travel in `sqe->fd`
  (`flags = READ_ONCE(sqe->fd)`, [`io_futex_prep`][io-futex-prep]; the
  `futex_flags` field must be zero). [`io_futex_wait`][io-futex-wait] calls the
  same `futex_wait_setup` as the syscall but with `task == NULL` and
  `q.wake = io_futex_wake_fn`; on success it parks the request on
  `ctx->futex_list` and returns `IOU_ISSUE_SKIP_COMPLETE`. A value mismatch
  completes immediately with `-EAGAIN` as a CQE.
- **The wake path** is an ordinary `futex_wake` from any thread or process.
  When it finds the io_uring `futex_q`, `io_futex_wake_fn` unqueues it, sets
  the result to 0 and queues task_work; the CQE is posted when the ring's task
  next runs task_work ([`io_futex_wake_fn`][io-futex-wake-fn]). So a plain
  thread calling `futex(FUTEX_WAKE)` wakes a ring-resident waiter with no
  knowledge of the ring — the property a cross-thread `WaitWord` needs.
- **`IORING_OP_FUTEX_WAITV`** is `futex_waitv` as one SQE; the CQE's `res` is
  the woken index. A claim bit (`io_futexv_claim`) arbitrates between a wake on
  one entry, a wake on another and cancellation
  ([`io_futexv_wait`][io-futexv-wait]).
- **Cancellation**: `IORING_OP_ASYNC_CANCEL` reaches
  [`__io_futex_cancel`][io-futex-cancel], which unqueues the `futex_q` (or
  claims the vector) and completes with `-ECANCELED`; if the wake already won,
  cancel fails — the classic wake/cancel race resolved by "whoever unqueues
  first".
- **`IORING_OP_FUTEX_WAKE`** submits a wake from the ring itself.

Each pending wait holds one `struct io_futex_data` (a `futex_q` plus a request
pointer) from a per-ring cache of 32; there is no per-waiter thread.

### Availability and versions

Linux only (Android included). Every op except `FUTEX_FD` survives; glibc
does not wrap `futex(2)`, so callers use `syscall(SYS_futex, …)`. io_uring
futex ops need 6.7 and an io_uring that is not disabled by policy
(`kernel.io_uring_disabled`, seccomp, container profiles). `FUTEX2_NUMA`,
`FUTEX2_MPOL` and the private hash need 6.16; man-pages 6.16 dates
`PR_FUTEX_HASH` to "Linux 6.17", while the kernel tree contains the
introducing commit in `v6.16-rc1` — the code, not the man page, is the
reference here. `FUTEX_ROBUST_UNLOCK` (unlock-and-clear-pending in one
syscall, closing an exit-time race in robust mutexes) landed for v7.2
([`3ca9595d9fb6`][commit-robust-unlock]).

## Strengths

- **The minimal interface**: one word, compare-and-block, wake-n; every lock,
  condvar, once, event and semaphore in this catalog can be built on it.
- **Zero per-object kernel state** until contention; waiter records on the
  waiting task's stack.
- **Process-shared for free** by keying on the physical page.
- **A real completion form**: io_uring turns the same `futex_q` into a CQE,
  woken by unmodified wakers — no eventfd, no helper thread.
- Requeue, `WAKE_OP` and bitsets give kernel-side wait morphing and
  multi-class waits on one word.

## Weaknesses

- **32 bits only**, despite the futex2 size field; a 1-byte lock or a 64-bit
  pointer-sized state cannot be waited on directly.
- **Multiplexed syscall with inconsistent timeouts** (relative for `WAIT`,
  absolute for `WAIT_BITSET`, realtime for `LOCK_PI`).
- **Global hash contention** between unrelated processes until 6.16's private
  hash.
- `FUTEX_WAIT` returning 0 does not mean "woken by my waker"; callers must
  re-check.
- io_uring futex waits carry no timeout and no wake count; `FUTEX_FD` is gone,
  so epoll-based loops have no futex hook at all.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                                        | Trade-off                                                                           |
| ---------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Kernel never interprets the word (except PI)   | Any user-space protocol fits; no per-object kernel state                         | Correct protocols are hard — Drepper's take-1 mutex livelocks and overflows         |
| Hashed bucket table keyed by address           | O(1) memory regardless of how many words exist                                   | Unrelated futexes collide; bucket spinlock contention (hence the 6.16 private hash) |
| Read the word under the bucket lock            | Atomic compare-and-block; no lost wakeups                                        | Page faults must be handled by drop-lock-fault-retry                                |
| `waiters` counter checked before locking       | Wake with no waiters avoids the bucket lock                                      | Still a syscall; user space must track waiters itself to skip it                    |
| `plist` ordering by RT priority                | RT tasks are woken first                                                         | Non-RT waiters are FIFO among themselves only                                       |
| Pluggable `futex_q.wake`                       | io_uring reuses the whole wait path; the waker needn't know the waiter is a ring | Completion is deferred to task_work on the ring's task                              |
| futex2 size field present, only `U32` accepted | ABI room for 8/16/64-bit futexes                                                 | Users designing around small words get `EINVAL` today                               |

## Sources

- [`kernel/futex/waitwake.c`][waitwake] — ordering proof, `futex_wake`, `futex_wait_setup`, `__futex_wait`
- [`kernel/futex/core.c`][core] — keys, hashing, `__futex_queue`, private hash, `futex_init`
- [`kernel/futex/futex.h`][futex-h] — `futex_hash_bucket`, `futex_q`, size validation
- [`kernel/futex/syscalls.c`][syscalls] — timeouts, `futex_waitv`, futex2 calls, robust lists
- [`kernel/futex/requeue.c`][requeue] — requeue and requeue-PI state machine
- [`io_uring/futex.c`][io-futex] — io_uring futex wait/wake/waitv and cancellation
- [`include/uapi/linux/futex.h`][uapi], [`Documentation/userspace-api/futex2.rst`][futex2-rst]
- man-pages 6.16: [`futex(2)`][man-futex], [`FUTEX_WAIT(2const)`][man-futex-wait], [`FUTEX_WAKE(2const)`][man-futex-wake], [`FUTEX_FD(2const)`][man-futex-fd], [`PR_FUTEX_HASH_SET_SLOTS(2const)`][man-set-slots]
- Ulrich Drepper, [_Futexes Are Tricky_][drepper], Red Hat, version 1.6, 2011-11-05 (first draft 2003-10-12); local copy `$REPOS/papers/fine-grained-locking/drepper-futexes-are-tricky.pdf`, read in full
- [kernelnewbies Linux 5.16][kn-516], [6.7][kn-67], [6.16][kn-616] — release dates and feature summaries
- Rust `std` [`sys/pal/unix/futex.rs`][rust-futex-linux] — absolute timeouts via `FUTEX_WAIT_BITSET`

> [!NOTE]
> The local clone is shallow (history from 2024 on), so release versions
> older than that come from man-pages 6.16 and kernelnewbies rather than from
> `git describe`. The man7.org host was unreachable during research; the man
> pages were read from the `man-pages-6.16` Nix package and are linked at
> man7.org.

<!-- References -->

[linux]: https://github.com/torvalds/linux/tree/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a
[waitwake]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/waitwake.c#L11
[waitwake-wake]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/waitwake.c#L178
[waitwake-setup]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/waitwake.c#L636
[waitwake-wait]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/waitwake.c#L701
[core]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/core.c
[core-key]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/core.c#L526
[core-queue]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/core.c#L860
[core-default]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/core.c#L1980
[core-init]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/core.c#L2089
[futex-h]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/futex.h
[futex-h-size]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/futex.h#L98
[futex-h-bucket]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/futex.h#L151
[futex-h-pi]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/futex.h#L160
[futex-h-q]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/futex.h#L208
[syscalls]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/syscalls.c
[syscalls-robust]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/syscalls.c#L11
[syscalls-timeout]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/syscalls.c#L178
[syscalls-waitv]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/syscalls.c#L314
[syscalls-wait]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/syscalls.c#L401
[requeue]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/futex/requeue.c
[io-futex]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c
[io-futex-cancel]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c#L92
[io-futex-prep]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c#L127
[io-futex-wake-fn]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c#L230
[io-futexv-wait]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c#L243
[io-futex-wait]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c#L296
[io-futex-wake]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/io_uring/futex.c#L341
[uapi]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/uapi/linux/futex.h
[uapi-futex32]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/uapi/linux/futex.h#L101
[uapi-owner-died]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/uapi/linux/futex.h#L193
[futex2-rst]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/Documentation/userspace-api/futex2.rst
[fork-hash]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/fork.c#L2002
[commit-private-hash]: https://github.com/torvalds/linux/commit/80367ad01d93ac781b0e1df246edaf006928002f
[commit-robust-unlock]: https://github.com/torvalds/linux/commit/3ca9595d9fb6cce6633a5b03d98c2aecb5499838
[man-futex]: https://man7.org/linux/man-pages/man2/futex.2.html
[man-futex-wait]: https://man7.org/linux/man-pages/man2/FUTEX_WAIT.2const.html
[man-futex-wake]: https://man7.org/linux/man-pages/man2/FUTEX_WAKE.2const.html
[man-futex-fd]: https://man7.org/linux/man-pages/man2/FUTEX_FD.2const.html
[man-set-slots]: https://man7.org/linux/man-pages/man2/PR_FUTEX_HASH_SET_SLOTS.2const.html
[drepper]: https://www.akkadia.org/drepper/futex.pdf
[kn-516]: https://kernelnewbies.org/Linux_5.16
[kn-67]: https://kernelnewbies.org/Linux_6.7
[kn-616]: https://kernelnewbies.org/Linux_6.16
[rust-futex-linux]: https://github.com/rust-lang/rust/blob/3bf5c6d99bc8a0c0d5b2f69826ed4f6d256a0a21/library/std/src/sys/pal/unix/futex.rs#L70
