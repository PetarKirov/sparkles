# glibc NPTL (C)

The GNU C Library's POSIX threads: every lock is a 32-bit futex word inside a
fixed-size, process-shareable `pthread_*_t`, waiting is delegated to the Linux
kernel's futex queues, and the hard engineering is in honouring POSIX's
ordering, destruction and robustness rules — most visibly in Torvald Riegel's
2016 condition variable, which tracks waiter order with a 64-bit sequence and
two rotating groups instead of requeueing waiters onto the mutex.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | C library (POSIX threads implementation)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Language**          | C                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **License**           | LGPL-2.1-or-later                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **Repository**        | [`glibc.git`][glibc-repo] on sourceware at `b72fcafcc9d3` (2026-10-10, development toward 2.45)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Primitives**        | `pthread_mutex_t` (normal/timed, recursive, error-check, adaptive, robust, priority-inheritance, priority-protect), `pthread_cond_t`, `pthread_rwlock_t`, `pthread_once_t`, the internal `lll_lock`                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Parking substrate** | the Linux futex word (`FUTEX_WAIT`/`FUTEX_WAKE`, private by default; `FUTEX_LOCK_PI` for PI mutexes); Mach `gsync` on the Hurd                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Fairness**          | barging everywhere; no spin by default; bounded adaptive spin only for `PTHREAD_MUTEX_ADAPTIVE_NP`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| **History**           | new condvar and rwlock in 2.25 (released 2017-02); condvar lost-wakeup fix (bug 25847) and `__g_refs` removal in 2.41; lock elision deprecated in 2.42, removed in 2.43                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| **Source read**       | [`nptl/pthread_mutex_lock.c`][mutex-lock], [`nptl/pthread_mutex_unlock.c`][mutex-unlock], [`sysdeps/nptl/lowlevellock.h`][lll-h], [`nptl/lowlevellock.c`][lll-c], [`nptl/pthread_cond_wait.c`][cond-wait], [`nptl/pthread_cond_signal.c`][cond-signal], [`nptl/pthread_cond_broadcast.c`][cond-broadcast], [`nptl/pthread_cond_common.c`][cond-common], [`nptl/pthread_rwlock_common.c`][rwlock], [`nptl/pthread_once.c`][once], [`sysdeps/nptl/futex-internal.h`][futex-internal], [`nptl/pthread_mutex_conf.c`][mutex-conf], [`sysdeps/x86_64/nptl/pthread_mutex_backoff.h`][backoff-x86], struct layouts under [`sysdeps/x86/nptl/bits/`][struct-mutex], [`NEWS`][news] |

## Overview

### What it solves

NPTL must implement the POSIX contract exactly, with constraints a language
runtime can ignore: objects may live in shared memory between processes
(`PTHREAD_PROCESS_SHARED`), so nothing may allocate or point into one address
space; `PTHREAD_MUTEX_INITIALIZER` is all-zero bytes and ABI-frozen; a mutex
or condvar may be destroyed the instant the last user is done with it; robust
mutexes must survive their owner's death; PI mutexes must boost the owner.

The destruction rule shapes the whole futex layer. A `futex_wake` may land on
memory that has since been reused ([`futex-internal.h` L51–L60][futex-internal-destroy]):

> Due to POSIX requirements on when synchronization data structures such as
> mutexes or semaphores can be destroyed and due to the futex design having
> separate fast/slow paths for wake-ups, we need to consider that futex_wake
> calls might effectively target a data structure that has been destroyed and
> reused for another object, or unmapped; thus, some errors or spurious
> wake-ups can happen in correct executions that would not be possible in a
> program using just a single futex whose lifetime does not end before the
> program terminates.

### Design philosophy

The internal lock is the canonical three-state futex mutex, documented at the
top of [`lowlevellock.h`][lll-h-comment]:

> Low-level locks use a combination of atomic operations (to acquire and
> release lock ownership) and futex operations (to block until the state of a
> lock changes). A lock can be in one of three states: 0: not acquired, 1:
> acquired with no waiters; no other threads are blocked or about to block for
> changes to the lock state, >1: acquired, possibly with waiters; there may be
> other threads blocked or about to block for changes to the lock state.

Every other primitive follows a stated design note in its source file,
written as an argument about memory orders and invariants rather than a
description of code. The condvar's opening paragraph states the guarantee
it was rewritten to provide ([`pthread_cond_wait.c` L173–L179][cond-comment]):

> This condvar implementation guarantees that all calls to signal and broadcast
> and all of the three virtually atomic parts of each call to wait (i.e., (1)
> releasing the mutex and blocking, (2) unblocking, and (3) re-acquiring the
> mutex) happen in some total order that is consistent with the happens-before
> relations in the calling program.

## How it works

`pthread_mutex_lock` dispatches on `__kind` ([`pthread_mutex_lock.c`
L69–L166][mutex-lock-fast]). The four "simple" kinds share the `lll_lock`
word; everything with a robust, PI or PP bit goes to
`__pthread_mutex_lock_full`, whose word holds the owner's TID.

| Kind                                              | Lock word                                          | Wait                                    | Extra                                       |
| ------------------------------------------------- | -------------------------------------------------- | --------------------------------------- | ------------------------------------------- |
| `PTHREAD_MUTEX_TIMED_NP` (= `NORMAL` = `DEFAULT`) | 0 / 1 / 2                                          | `futex_wait(…, 2)`                      | single-thread shortcut: plain store of 1    |
| `PTHREAD_MUTEX_RECURSIVE_NP`                      | 0 / 1 / 2                                          | same                                    | `__owner`, `__count`                        |
| `PTHREAD_MUTEX_ERRORCHECK_NP`                     | 0 / 1 / 2                                          | same                                    | `EDEADLK` on self-relock                    |
| `PTHREAD_MUTEX_ADAPTIVE_NP`                       | 0 / 1 / 2                                          | spin, then same                         | `__spins` moving average                    |
| robust (`…_ROBUST_…_NP`)                          | owner TID \| `FUTEX_WAITERS` \| `FUTEX_OWNER_DIED` | `futex_wait` on TID word                | per-thread `robust_head` list; `EOWNERDEAD` |
| PI (`…_PI_…_NP`)                                  | owner TID \| `FUTEX_WAITERS`                       | `FUTEX_LOCK_PI` ([L344–L443][mutex-pi]) | kernel `rt_mutex` boosts the owner          |
| PP (`…_PP_…_NP`)                                  | ceiling in bits 19–31 + lock bits                  | `futex_wait`                            | `__pthread_tpp_change_priority`             |

Transactional lock elision (`PTHREAD_MUTEX_ELISION_NP`, x86 RTM, POWER HTM,
s390 TX) is gone: "The support for TX lock elision of pthread mutexes has been
deprecated on all architectures and will be removed in the next release" (2.42),
then "has been removed on all architectures (powerpc, s390x, x86_64)" (2.43,
[`NEWS`][news]). Rust's pthread mutex had to opt out of it explicitly because
an elided self-relock silently succeeded ([Rust std](./rust-std-sync.md#portability)).

**`pthread_rwlock_t`** (also new in 2.25) separates the lock state from the
futex words ([`pthread_rwlock_common.c` L30–L190][rwlock-comment]). `__readers`
holds a reader count R plus three bits — `WP` (write phase), `WL` (a primary
writer holds the writer-only lock) and `RW` (readers waiting behind a preferred
writer) — forming eight documented states. Acquiring a read lock "requires a
single atomic addition if the lock is or was previously acquired by other
readers". Threads block on two other words, because "using `__readers` as a
futex word directly is not a good solution": the reader count changes so often
that `futex_wait` would keep failing its value check. `__wrphase_futex` mirrors
`WP`, `__writers_futex` lets writers wait for the primary writer, and a
`PTHREAD_RWLOCK_FUTEX_USED` bit in each word lets the releasing side skip
`futex_wake` when nobody sleeps. Phase changes use **explicit hand-over**:
waiters that may sleep on `__wrphase_futex` must sleep on it rather than spin on
`__readers`, so that the releasing thread's final store is the one that
unblocks them and a reader cannot "acquire, release, and then destroy the lock
concurrently with the pending futex unblock operations by the former primary
writer".

**`pthread_once_t`** is one `int` with three states — 0, in progress
(`__fork_generation | __PTHREAD_ONCE_INPROGRESS`), done — and a fast path of a
single acquire load ([`pthread_once.c` L42–L144][once]). Losers
`futex_wait` on the in-progress value; the winner stores `__PTHREAD_ONCE_DONE`
with release and unconditionally `futex_wake`s `INT_MAX` (there is no waiter
bit, so every completion pays a syscall). The fork generation lets a child
process reclaim an initialization interrupted by `fork`; the comment admits "an
ABA issue on the fork generation" after 2^30 forks. A cancelled initializer
resets the word to 0 and wakes all waiters through a cleanup handler.

## Analysis

### State word and fast path

`lll_lock` is a CAS 0 → 1 with acquire; on failure `__lll_lock_wait` swaps in
2 and waits while the value is 2 ([`lowlevellock.c` L40–L51][lll-c-wait]):

```c
void
__lll_lock_wait (int *futex, int private)
{
  if (atomic_load_relaxed (futex) == 2)
    goto futex;

  while (atomic_exchange_acquire (futex, 2) != 0)
    {
    futex:
      LIBC_PROBE (lll_lock_wait, 1, futex);
      futex_wait ((unsigned int *) futex, 2, private); /* Wait if *futex == 2.  */
    }
}
```

`lll_unlock` is `atomic_exchange_release(futex, 0)` and a `futex_wake(…, 1)` if
the old value was `> 1` ([`lowlevellock.h` L144–L159][lll-unlock]); the comment
notes that `private` is evaluated _before_ the release "so that we do not
violate the mutex destruction requirements". A woken thread re-acquires with
2, so the last unlocker in a burst issues one unneeded wake — the same
trade-off as [Rust](./rust-std-sync.md#state-word-and-fast-path) and
[Zig](./zig-std-sync.md#state-word-and-fast-path).

Two variants matter. `lll_cond_lock` always takes the word straight to 2,
because a thread returning from `pthread_cond_wait` cannot know whether others
sleep on the mutex. And for private mutexes in a single-threaded process,
`lll_mutex_lock_optimized` replaces the CAS with a plain store
([`pthread_mutex_lock.c` L33–L49][mutex-st]).

### Waiting: spin, yield, park

**The default mutex never spins.** `PTHREAD_MUTEX_TIMED_NP` calls `lll_lock`
and parks on first contention. Only `PTHREAD_MUTEX_ADAPTIVE_NP` spins
([L113–L147][mutex-adaptive]):

```c
int max_cnt = MIN (max_adaptive_count (),
                   mutex->__data.__spins * 2 + 10);
int spin_count, exp_backoff = 1;
unsigned int jitter = get_jitter ();
do
  {
    /* In each loop, spin count is exponential backoff plus
       random jitter, random range is [0, exp_backoff-1].  */
    spin_count = exp_backoff + (jitter & (exp_backoff - 1));
    cnt += spin_count;
    if (cnt >= max_cnt)
      {
        /* If cnt exceeds max spin count, just go to wait
           queue.  */
        LLL_MUTEX_LOCK (mutex);
        break;
      }
    do
      atomic_spin_nop ();
    while (--spin_count > 0);
    /* Prepare for next loop.  */
    exp_backoff = get_next_backoff (exp_backoff);
  }
while (LLL_MUTEX_READ_LOCK (mutex) != 0
       || LLL_MUTEX_TRYLOCK (mutex) != 0);

mutex->__data.__spins += (cnt - mutex->__data.__spins) / 8;
```

This is the only adaptive spin among the surveyed standard libraries. The
budget is per-mutex: `__spins` is an exponential moving average (weight 1/8) of
how long recent acquisitions spun, and the next attempt may spin up to
`2 × __spins + 10`, capped by the tunable `glibc.pthread.mutex_spin_count`
(default `DEFAULT_ADAPTIVE_COUNT` = 100, range 0–32 767; 0 on SuperH)
([`pthread_mutex_conf.c` L27–L32][mutex-conf], [`adaptive_spin_count.h`][adaptive-count]).
It spins read-only (`LLL_MUTEX_READ_LOCK`, a relaxed load) and only then tries
the CAS. The generic `get_next_backoff` returns 1 (no backoff) and
`get_jitter` 0; x86_64 overrides both — binary exponential backoff capped at
`MAX_BACKOFF` 16 with TSC-derived jitter ([`pthread_mutex_backoff.h`
L18–L35][backoff-x86], [`fast-jitter.h`][fast-jitter]). There is no
`sched_yield`.

### The parking substrate

The kernel futex. `futex-internal.h` wraps `FUTEX_WAIT`/`FUTEX_WAKE` (and
`__NR_futex_time64` on 32-bit), aborts on error codes that indicate a bug, and
returns the rest. `FUTEX_PRIVATE` is defined as 0 because zero-initialized
objects must default to private: "FUTEX*PRIVATE must be zero because the
initializers for pthread_mutex_t, pthread_rwlock_t, and pthread_cond_t
initialize the respective field of those structures to zero"
([L63–L70][futex-internal-private]). Waiter records live in the kernel's futex
hash; glibc keeps none, so nothing in NPTL needs allocation. Robust mutexes
add a per-thread kernel-registered list (`robust_head`) with a
`list_op_pending` slot set before each operation, so that at thread death the
kernel can mark every held mutex `FUTEX_OWNER_DIED` and wake a waiter. On the Hurd the same `lll*\*`API is built on
Mach`\_\_gsync_wait` ([`mach/lowlevellock.h`][mach-lll]).

### Fairness, handoff and starvation

No primitive hands off except the PI mutex, where the kernel's `rt_mutex`
assigns ownership in priority order. Simple mutexes barge: the unlocker stores
0 and wakes one waiter, which then competes with spinners and newcomers; there
is no starvation bound. `pthread_rwlock_t` defaults to
`PTHREAD_RWLOCK_PREFER_READER_NP`; with `PREFER_WRITER_NONRECURSIVE_NP` a
releasing primary writer can hand `WL` to a registered writer directly by
setting `PTHREAD_RWLOCK_WRHANDOVER` — "writer--to--writer lock ownership
hand-over is fairly fast and bypasses lock acquisition attempts by readers"
([`pthread_rwlock_common.c` L30–L56][rwlock-comment]). The condvar is the one
place ordering is guaranteed: a signal must wake a waiter that registered
before it.

### Condition variables and predicates

The 2.25 condvar was written by Torvald Riegel to fix bug 13165 after Austin
Group issue 609 tightened which waiters a signal may wake. His commit message
([`ed19993b5b0d`][riegel-commit], authored 2016-05-25) gives the core problem:

> We can't use the old algorithm anymore because futexes do not guarantee to
> wake in FIFO order. Thus, when we wake, we can't simply let any waiter grab
> a signal, but we need to ensure that one of the waiters happening before the
> signal is woken up. […] Unlike mutexes that have just three states, or
> semaphores that have no tokens or a limited number of them, the state of a
> condvar is the _order_ of the waiters.

The mechanism, from the design comment ([`pthread_cond_wait.c`
L181–L239][cond-groups]):

> All waiters acquire a certain position in a 64b waiter sequence (`__wseq`).
> […] Only waiters with a position less than the `__wseq` value observed by the
> signal are eligible to consume this signal. […] To deal with the blocking
> using futexes, we maintain two groups of waiters: Group G1 consists of
> waiters that are all eligible to consume signals; incoming signals will
> always signal waiters in this group until all waiters in G1 have been
> signaled. Group G2 consists of waiters that arrive when a G1 is present and
> still contains waiters that have not been signaled. When all waiters in G1
> are signaled and a new signal arrives, the new signal will convert G2 into
> the new G1 and create a new G2 for future waiters. We cannot allocate new
> memory because of process-shared condvars, so we have just two slots of
> groups that change their role between G1 and G2.

A waiter does `fetch_add(__wseq, 2)` (the low bit names the current G2 slot),
increments `__wrefs`, unlocks the mutex, then loops: if its position is below
`__g1_start` its group is closed and it leaves; if `__g_signals[g]` exceeds
`g1_start` it CASes one signal away; otherwise it `futex_wait`s on
`__g_signals[g]` ([L330–L436][cond-wait-common]). `signal` checks `__wrefs >> 3`
for waiters, takes the condvar-internal lock (two bits of `__g1_orig_size`),
adds a signal to G1 — or switches G2 to G1 if G1 is fully signaled — and wakes
one waiter on that group's futex ([`pthread_cond_signal.c` L34–L95][cond-signal]).
`broadcast` signals all of G1, switches, signals all of the new G1, and
`futex_wake`s `INT_MAX` on each ([`pthread_cond_broadcast.c`][cond-broadcast]).
Re-acquisition uses `__pthread_mutex_cond_lock`, i.e. `lll_cond_lock`, which
always marks the mutex contended.

**Requeue was dropped on purpose.** The pre-2.25 condvar used
`FUTEX_CMP_REQUEUE` to move broadcast waiters onto the mutex's futex
([wait morphing](./concepts.md#wait-morphing)); `lowlevellock.h` still carries
a comment about it. Riegel's reasons ([`ed19993b5b0d`][riegel-commit]):

> - If a program expects to wake many threads at the same time and make that
>   scalable, a condvar isn't great anyway because of how it requires waiters
>   to operate mutually exclusive (due to the mutex usage). Thus, a thundering
>   herd problem is a scalability problem with or without the optimization.
> - The scalability problem is actually at the mutex side; the condvar could
>   help (and it tries to with the requeue optimization), but it should be the
>   mutex who decides how that is done, and whether it is done at all.
> - Forcing all but one waiter into the kernel-side wait queue of the mutex
>   prevents/avoids the use of lock elision on the mutex. […]
> - Doing the requeue stuff requires all waiters to always drive the mutex into
>   the contended state. This leads to each waiter having to call futex_wake
>   after lock release, even if this wouldn't be necessary.

Rust's team cited this review when it, too, chose wake-all
([Rust std](./rust-std-sync.md#condition-variables-and-predicates)).

The algorithm was hard to get right. Bug 25847, "pthread_cond_signal failed to
wake up pthread_cond_wait due to a bug in undoing stealing", was fixed in 2.41
by a series from Frank Barrus and Malte Skarupke (authored 2024-12-04) that
also removed the per-group `__g_refs` counts — the struct now has
`__unused_initialized_1/2` in their place ([`thread-shared-types.h`
L94–L104][cond-struct]) — and collapsed the wait loop. The 2.40 code had a
spin-before-block loop with `const int maxspin = 0`, i.e. disabled; 2.41
deleted it. The long design comment still speaks of a "group reference count".

### Footprint and layout

| Type (x86_64)      | Size | Fields                                                                                                |
| ------------------ | ---- | ----------------------------------------------------------------------------------------------------- |
| `pthread_mutex_t`  | 40 B | `__lock`, `__count`, `__owner`, `__nusers`, `__kind`, `__spins`, robust-list links                    |
| `pthread_cond_t`   | 48 B | `__wseq` (64), `__g1_start` (64), `__g_size[2]`, `__g1_orig_size`, `__wrefs`, `__g_signals[2]`        |
| `pthread_rwlock_t` | 56 B | `__readers`, `__writers`, `__wrphase_futex`, `__writers_futex`, `__cur_writer`, `__shared`, `__flags` |
| `pthread_once_t`   | 4 B  | one `int`                                                                                             |

On i386 the mutex is 24 B and the rwlock 32 B ([`pthreadtypes-arch.h`][types-arch]).
The futex word is 4 bytes of a 40-byte object; the rest is ownership,
recursion, robustness and ABI padding. Nothing is cache-line aligned. Sizes are
ABI and can never shrink.

### Portability

Linux only, plus the Hurd through `gsync`. NPTL assumes Linux ≥ 2.6.22 ("since
this version, EINTR is not returned on spurious wake-ups anymore",
[`futex-internal.h`][futex-internal]). Absolute timeouts are passed to the
kernel against `CLOCK_REALTIME` or `CLOCK_MONOTONIC` (`pthread_cond_clockwait`,
`pthread_mutex_clocklock`); the condvar stores its clock in bit 1 of
`__wrefs`. Architecture variation is confined to backoff/jitter hooks and
struct layouts.

### Async and fiber integration

None. Every wait blocks the calling kernel thread in `futex(2)`; the condvar
wait is a POSIX cancellation point (`__futex_abstimed_wait_cancelable64` with a
cleanup handler), but cancellation is thread cancellation, not task
cancellation. A user-space scheduler cannot intercept the wait. What NPTL does
offer an event loop is indirect: because the waiter state is entirely in the
kernel futex table, a loop that can wait on a futex word (`io_uring`
`IORING_OP_FUTEX_WAIT`, see [Linux futex](./linux-futex.md)) can wait on the
same 3-state word glibc's `lll_unlock` wakes.

## Strengths

- Zero allocation and full process-shared support from fixed-size, zero-initialized objects.
- The condvar is the only surveyed design that guarantees signals wake waiters
  registered _before_ them, with no ABA on a 32-bit counter.
- The adaptive mutex's per-lock moving-average spin budget is a real adaptive
  policy, tunable at run time.
- Robust and PI mutexes reuse the same futex machinery with kernel cooperation.
- Unusually explicit design comments: memory orders, destruction safety and
  known limitations are argued in the source.

## Weaknesses

- Large objects (40/48/56 B) fixed by ABI; the lock word is a small part.
- Default mutex never spins; adaptive spinning is opt-in and non-portable.
- The condvar is complex enough that a lost-wakeup bug survived from 2.25 to
  2.41 (eight years); its comments lag the code.
- Every condvar signal takes an internal lock.
- Broadcast wakes all waiters onto the mutex (no requeue).
- No path for a non-thread waiter.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                                       | Trade-off                                                                |
| ---------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| 3-state `lll_lock` word, kernel owns the queue | minimal uncontended cost; process-shared works for free                         | barging, no fairness control; redundant final wake                       |
| No spin in the default mutex                   | predictable behaviour; spin only where the user opts in                         | short critical sections pay a futex round-trip under contention          |
| Adaptive spin with per-mutex moving average    | spin about as long as recent acquisitions needed                                | 2 bytes of state per mutex; opt-in only                                  |
| 64-bit `__wseq` + two rotating groups (G1/G2)  | POSIX/C++ ordering: only earlier waiters may consume a signal; avoid 32-bit ABA | 48-byte condvar, internal lock on every signal, hard-to-verify algorithm |
| No requeue on broadcast                        | herd is inherent; let the mutex decide; requeue forces contended state          | broadcast wakes everyone onto the mutex                                  |
| Explicit hand-over in the rwlock's phase futex | destroy-after-unlock safety: the last change to memory unblocks everyone        | waiters may not spin on `__readers`; more futex words                    |
| `FUTEX_PRIVATE` == 0                           | zero-initialized objects default to the cheaper private futex                   | process-shared objects must be explicitly initialized                    |
| Remove lock elision (2.43)                     | HTM deprecated in hardware; semantic hazards (silent self-relock)               | no speculative path for read-mostly critical sections                    |

## Sources

- `glibc.git` on sourceware at [`b72fcafcc9d3`][glibc-repo]: the files listed in
  the metadata table, plus [`NEWS`][news] (2.25, 2.41, 2.42, 2.43 entries).
- Torvald Riegel, "New condvar implementation that provides stronger ordering
  guarantees", commit [`ed19993b5b0d`][riegel-commit] (authored 2016-05-25;
  released in 2.25), read through the GitHub mirror `bminor/glibc` because
  sourceware's gitweb rejected automated fetches.
- 2.41 condvar series in the same mirror: Frank Barrus, "pthreads NPTL: lost
  wakeup fix 2" ([`1db84775f831`][barrus]); Malte Skarupke, "nptl: Remove
  g_refs from condition variables" ([`c36fc5078199`][skarupke-grefs]).
- glibc 2.40 `nptl/pthread_cond_wait.c` and `thread-shared-types.h`
  ([`glibc-2.40` tag][glibc-240]) for the pre-2.41 `__g_refs` and `maxspin`.

> [!NOTE]
> The glibc clone is shallow, so dates and the 2.41 series come from the
> `bminor/glibc` GitHub mirror and `NEWS`, not from local history. Sourceware
> gitweb links use `hb=<sha>`; their `#l<n>` anchors are gitweb's line anchors.

<!-- References -->

[glibc-repo]: https://sourceware.org/git/?p=glibc.git;a=tree;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[news]: https://sourceware.org/git/?p=glibc.git;a=blob;f=NEWS;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[mutex-lock]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_lock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[mutex-lock-fast]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_lock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l69
[mutex-st]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_lock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l33
[mutex-adaptive]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_lock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l113
[mutex-pi]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_lock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l344
[mutex-unlock]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_unlock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[lll-h]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/lowlevellock.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[lll-h-comment]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/lowlevellock.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l26
[lll-unlock]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/lowlevellock.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l144
[lll-c]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/lowlevellock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[lll-c-wait]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/lowlevellock.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l40
[mach-lll]: https://sourceware.org/git/?p=glibc.git;a=blob;f=mach/lowlevellock.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[cond-wait]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_wait.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[cond-comment]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_wait.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l173
[cond-groups]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_wait.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l181
[cond-wait-common]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_wait.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l330
[cond-signal]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_signal.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l34
[cond-broadcast]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_broadcast.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l38
[cond-common]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_cond_common.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[cond-struct]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/bits/thread-shared-types.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l94
[rwlock]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_rwlock_common.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[rwlock-comment]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_rwlock_common.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l30
[once]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_once.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l42
[futex-internal]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/futex-internal.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[futex-internal-destroy]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/futex-internal.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l51
[futex-internal-private]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/nptl/futex-internal.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l63
[mutex-conf]: https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_mutex_conf.c;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e#l27
[adaptive-count]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/generic/adaptive_spin_count.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[backoff-x86]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/x86_64/nptl/pthread_mutex_backoff.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[fast-jitter]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/generic/fast-jitter.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[struct-mutex]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/x86/nptl/bits/struct_mutex.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[types-arch]: https://sourceware.org/git/?p=glibc.git;a=blob;f=sysdeps/x86/nptl/bits/pthreadtypes-arch.h;hb=b72fcafcc9d307790bd24ebba65f52994ca5598e
[riegel-commit]: https://github.com/bminor/glibc/commit/ed19993b5b0d05d62cc883571519a67dae481a14
[barrus]: https://github.com/bminor/glibc/commit/1db84775f831a1494993ce9c118deaf9537cc50a
[skarupke-grefs]: https://github.com/bminor/glibc/commit/c36fc50781995e6758cae2b6927839d0157f213c
[glibc-240]: https://github.com/bminor/glibc/blob/3d1aed874918c466a4477af1da35983ab036690e/nptl/pthread_cond_wait.c
