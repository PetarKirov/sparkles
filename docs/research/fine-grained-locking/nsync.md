# nsync (C)

Google's portable C synchronization library: a two-word reader/writer mutex
whose waiter queue hangs off the lock itself and is guarded by a spinlock bit
inside the lock word, a Mesa condition variable that transfers waiters onto
the mutex, and **conditional critical sections** — `nsync_mu_wait(mu,
predicate)` — where the unlocking thread evaluates waiters' predicates so no
one has to signal.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | library (locks, condition variables, once, waitable counters and notes, multi-object wait)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **Language**          | C (C90 plus atomics; compiles as C++ in its own namespace)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **License**           | Apache-2.0; "It is not an offical Google product" ([`README`][readme])                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Repository**        | [`google/nsync`][ns-repo], `VERSION` 1.30.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Lock word**         | `nsync_mu`: `uint32_t word` (`MU_WLOCK`, `MU_SPINLOCK`, `MU_WAITING`, `MU_DESIG_WAKER`, `MU_CONDITION`, `MU_WRITER_WAITING`, `MU_LONG_WAIT`, `MU_ALL_FALSE`, reader count from bit 8) + `waiters` list pointer; `nsync_cv`: `uint32_t word` (`CV_SPINLOCK`, `CV_NON_EMPTY`) + `waiters` pointer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Parking substrate** | per-lock intrusive doubly-linked list of `waiter` structs (per-thread cached, else from a global free list, else `malloc`), each sleeping on its own `nsync_semaphore`: a futex word on Linux, a GCD semaphore or pthread mutex+cond elsewhere on POSIX, a Win32 semaphore on Windows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Source read**       | [`README`][readme]; [`public/nsync_mu.h`][mu-h], [`nsync_cv.h`][cv-h], [`nsync_mu_wait.h`][muwait-h], [`nsync_waiter.h`][waiter-h], [`nsync_note.h`][note-h], [`nsync_counter.h`][counter-h], [`nsync_once.h`][once-h]; [`internal/common.h`][common-h], [`common.c`][common-c], [`mu.c`][mu-c], [`mu_wait.c`][muwait-c], [`cv.c`][cv-c], [`wait.c`][wait-c], [`wait_internal.h`][waitint-h], [`sem.h`][sem-h], [`sem_wait.c`][semwait-c], [`once.c`][once-c], [`counter.c`][counter-c]; [`platform/linux/src/nsync_semaphore_futex.c`][sem-futex], [`platform/macos/src/nsync_semaphore_gcd.c`][sem-gcd], [`platform/posix/src/nsync_semaphore_mutex.c`][sem-posix], [`platform/win32/src/nsync_semaphore_win32.c`][sem-win32], [`platform/posix/src/per_thread_waiter.c`][ptw-posix]; [`CMakeLists.txt`][cmake] |

## Overview

### What it solves

The README positions nsync against pthreads ([`README`][readme]):

> nsync may be desirable in place of pthread primitives in some cases:
>
> - nsync locks are reader-writer locks (but are as efficient as mutexes).
> - nsync locks and condition variables occupy only two words each.
> - nsync works on Unix-like systems and Windows. It should be portable to
>   other platforms straightforwardly.
> - nsync provides conditional critical sections. These fill the same role as
>   condition variables, but are usually easier to use, and in most common
>   cases are comparable in speed.

and argues the reader/writer point directly: "There is no particular reason
why a reader/writer lock need be significantly slower than a simple mutex. In
both cases, the lock can be acquired or released with a single atomic
read-modify-write sequence. Thus, the type nsync_mu is a reader/writer lock."

### Design philosophy

**Predicates instead of signals.** With `nsync_mu_wait`, "it's not necessary
to surround the 'wait' operation in a while loop" and "it's not necessary to
wake or signal explicitly when the condition(s) become true; they are checked
automatically." The README states the cost honestly: "The primary cost is that
the implementation must check whether any waiters' conditions have become true
when releasing the lock. This cost becomes most noticable when threads wait on
many distinct, false conditions" — and notes the mechanism dates "back to the
1960s".

**Mesa semantics, defended.** The `nsync_cv.h` header explains why imprecise
wakeups are preferred over Hoare monitors ([`nsync_cv.h`][cv-h]):

> Imprecise wakeups make more efficient use of the critical section, because
> threads can enter it while a woken thread is still emerging from the
> scheduler, which may take thousands of cycles. Further, they make the
> programme easier to read and debug by making the predicate explicit locally
> at the wait, where the predicate is about to be assumed.

**Cancellation is an object, not a thread property.** Every timed wait takes
an absolute deadline and an `nsync_note` — "conceptually a boolean that makes
a single transition from false to true", notified explicitly, by timeout, or
by its parent — so a request tree can be cancelled as a whole.

**Queues belong to the lock.** Unlike the parking-lot designs
([parking_lot](./parking-lot.md), [WebKit](./webkit-wtf-lock.md)), there is no
global table: the second word of `nsync_mu` and `nsync_cv` points at the lock's
own waiter list, and the word's `MU_SPINLOCK`/`CV_SPINLOCK` bit is the queue
lock. That is what lets the unlocker walk the list and evaluate predicates.

## How it works

`nsync_mu` ([`nsync_mu.h`][mu-h]):

```c
typedef struct nsync_mu_s_ {
	nsync_atomic_uint32_ word; /* internal use only */
	struct nsync_dll_element_s_ *waiters; /* internal use only */
} nsync_mu;
```

Zero is unlocked. The bits, documented at length in
[`internal/common.h`][common-h-bits]:

| Bit                      | Meaning                                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `MU_WLOCK` (1)           | writer lock held                                                                                                 |
| `MU_SPINLOCK` (2)        | "spinlock that must be held when manipulating the waiter queue"                                                  |
| `MU_WAITING` (4)         | waiter queue non-empty                                                                                           |
| `MU_DESIG_WAKER` (8)     | "a former waiter has been woken, but has neither acquired the lock nor gone back to sleep"                       |
| `MU_CONDITION` (16)      | some waiter may have a predicate                                                                                 |
| `MU_WRITER_WAITING` (32) | readers that have not yet blocked must not acquire, "in order not to starve waiting writers"                     |
| `MU_LONG_WAIT` (64)      | "a waiter has been woken many times but repeatedly failed to acquire"; only threads that have waited may acquire |
| `MU_ALL_FALSE` (128)     | "a complete scan of the waiter list found no waiters with true conditions" since the last writer                 |
| `MU_RLOCK` (256)         | low bit of the reader count, "which uses rest of word"                                                           |

Reader and writer acquisition share one generic slow path parameterized by a
`lock_type` record (`zero_to_acquire`, `add_to_acquire`, `set_when_waiting`,
`clear_on_acquire`, …): a writer needs `MU_WLOCK | readers | MU_LONG_WAIT`
zero and adds `MU_WLOCK`; a reader needs `MU_WLOCK | MU_WRITER_WAITING |
MU_LONG_WAIT` zero and adds `MU_RLOCK`.

Each blocked thread is represented by a `waiter` ([`common.h`][common-h-waiter]):
an `nsync_semaphore sem`, an embedded `struct nsync_waiter_s nw` (the list
link, an atomic `waiting` flag, a pointer to the semaphore to V, flags), the
`cv_mu` it belongs to if it came from a condvar, its `l_type`, a
`remove_count`, its `wait_condition_s cond` (`f`, `v`, optional `eq`), and a
`same_condition` ring linking queue neighbours with equal predicates. The
protocol is in the comment: queue it, then `while (ATM_LOAD_ACQ (&w.waiting) !=
0) { nsync_mu_semaphore_p (&w.sem); }`; to wake, unlink, `ATM_STORE_REL
(&w.waiting, 0); nsync_mu_semaphore_v (&w.sem)`.

## Analysis

### State word and fast path

Writer lock and unlock are a single CAS each when uncontended
([`mu.c`][mu-c-lock]): `ATM_CAS_ACQ (&mu->word, 0, MU_WLOCK)`; a second
attempt with a fresh load if the word is non-zero but acquirable; else the
slow path. `nsync_mu_rlock` is the same with `MU_RLOCK`. Unlock is
`ATM_CAS_REL (&mu->word, MU_WLOCK, 0)`, then a second CAS that also clears
`MU_ALL_FALSE` ("the critical section we're just leaving may have made some
conditions true"), and the slow path only when `MU_WAITING` is set without
`MU_DESIG_WAKER`. The unlock comment explains why the release must be a CAS
and why the lock is not released before the wakeup work ([`mu.c`][mu-c-unlock]):

> C is not a garbage-collected language, so we cannot release until we can be
> sure that we will not have to touch the mutex again to wake a waiter.
> Another thread could acquire, decrement a reference count and deallocate the
> mutex before the current thread touched the mutex word again.

Misuse is checked, not assumed: unlocking a mutex held in the wrong mode calls
`nsync_panic_`.

### Waiting: spin, yield, park

There is no spin-then-park phase in front of the queue. `nsync_mu_lock_slow_`
([`mu.c`][mu-c-slow]) loops: if acquirable, CAS-acquire; else if
`MU_SPINLOCK` is clear, CAS it on (setting `MU_WAITING`), enqueue, release the
spinlock, and sleep on the semaphore; otherwise back off with
`nsync_spin_delay_` and retry. The backoff ([`common.c`][common-c-spin]):

```c
unsigned nsync_spin_delay_ (unsigned attempts) {
	if (attempts < 7) {
		volatile int i;
		for (i = 0; i != 1 << attempts; i++) {
		}
		attempts++;
	} else {
		nsync_yield_ ();
	}
	return (attempts);
}
```

— a `volatile` busy-loop of 1, 2, … 64 iterations (no `pause` hint), then
`sched_yield()` forever. Spinning happens only on failed CASes and on the
`MU_SPINLOCK` bit; a thread that sees the lock held and the spinlock free
enqueues and sleeps immediately. The **designated waker** compensates: the
unlocker sets `MU_DESIG_WAKER` when it wakes someone, and further unlocks skip
the wake path while that bit is set, so at most one woken-but-not-yet-running
thread exists per mutex.

### The parking substrate

The **queue lives in the lock** (`mu->waiters`, `cv->waiters`) and is guarded
by a spinlock bit in the same word; there is no global table and no hashing.
Waiter records are per-thread: `nsync_waiter_new_` first takes the
thread's cached `waiter` (a `THREAD_LOCAL` pointer, or a `pthread_key_t` via
[`per_thread_waiter.c`][ptw-posix] where TLS is missing), then a global
spinlocked free list `free_waiters`, then `malloc` — or a client-supplied
`nsync_malloc_ptr_`, which exists to "allow nsync's mutexes to be used inside
an implementation of malloc()" ([`common.c`][common-c-waiter]). The cached
record is skipped when it is already `WAITER_IN_USE`: a cancellable wait locks
the note's own `note_mu` while its `waiter` is queued
([`sem_wait.c`][semwait-c]), so one thread can hold two `waiter`s at once.

Each `waiter` sleeps on an `nsync_semaphore` — opaque `void *sem_space[32]`
([`sem.h`][sem-h]) — implemented per platform. On Linux it is a futex counting
semaphore ([`nsync_semaphore_futex.c`][sem-futex]): P loops `FUTEX_WAIT`
(`FUTEX_WAIT_BITSET | FUTEX_PRIVATE_FLAG | FUTEX_CLOCK_REALTIME` with an
absolute deadline when available) while the count is 0 and CAS-decrements; V
CAS-increments and then **always** issues `FUTEX_WAKE`, one syscall per wake
even if the sleeper has not reached the futex yet.

### Fairness, handoff and starvation

There is no direct handoff: an unlocker releases the lock (or converts it, see
below) and wakes; the woken thread re-competes. Starvation is bounded by
counting failures instead of time ([`mu.c`][mu-c-slow]):

> If the thread has been woken more than this many times, and still not
> acquired, it sets the MU_LONG_WAIT bit to prevent thread that have not waited
> from acquiring. This is the starvation avoidance mechanism. The number is
> fairly high so that we continue to benefit from the throughput of not having
> running threads wait unless absolutely necessary.

The threshold is `LONG_WAIT_THRESHOLD 30` ([`common.h`][common-h-longwait]).
Two queueing rules refine this: "first wait goes to end of queue", but a thread
woken and forced to wait again goes to the **front**
(`nsync_dll_make_first_in_list_`), and a thread that has waited once ignores
`MU_WRITER_WAITING` and `MU_LONG_WAIT` when trying to acquire. Writer
preference is `MU_WRITER_WAITING`: set when a writer blocks, it stops new
readers (`MU_RZERO_TO_ACQUIRE` includes it) until a writer acquires.

### Condition variables and predicates

**Condition variable.** `nsync_cv_wait_with_deadline_generic`
([`cv.c`][cv-c-wait]) takes `CV_SPINLOCK`, appends a `waiter` to `cv->waiters`,
records `remove_count`, releases the spinlock, unlocks the mutex, and sleeps on
the semaphore with the deadline and cancel note. A timeout re-takes
`CV_SPINLOCK` and uses `remove_count` to tell "still on the cv queue" from
"already dequeued by a signaller". `nsync_cv_signal` wakes the first waiter —
and if that waiter is a reader, "wake all readers and, if possible, a writer"
([`nsync_cv.h`][cv-h]). `wait` admits spurious wakeups by contract.

**[Wait morphing][c-morph].** `wake_waiters` ([`cv.c`][cv-c-wake]) moves waiters to the
mutex's queue instead of waking them when "some thread holds the lock", the
mutex spinlock is free, and either the first waiter cannot acquire in its mode
or more than one waiter is being woken and not all are readers. A transferred
waiter has `cv_mu` set to `NULL`; when it is eventually woken from the mutex
queue it calls `nsync_mu_lock_slow_ (cv_mu, w, MU_DESIG_WAKER, …)` with the
same `waiter`. The condition "some thread holds the lock … ensures that at
least one of the transferred waiters will be woken." Like `parking_lot`'s
requeue, this avoids a herd; unlike it, it works for readers and writers and
needs no global table because both queues are reachable from the objects.

**Conditional critical sections.** `nsync_mu_wait_with_deadline(mu, condition,
condition_arg, condition_arg_eq, abs_deadline, cancel_note)`
([`mu_wait.c`][muwait-c]) returns with `mu` held and the predicate true (or
`ETIMEDOUT`/`ECANCELED`). The waiter is queued on the **mutex** with
`cond.f/v/eq` and `MU_CONDITION` set; no condvar is involved. The unlock slow
path ([`mu.c`][mu-c-unlockslow]) then does the work:

- When `MU_CONDITION` is set it **keeps the write lock** while scanning ("A
  writer lock is currently needed to test conditions because exclusive access
  is needed to the list … The spinlock cannot be used to achieve that, because
  an internal lock should not be held when calling the external predicates"),
  swapping the whole list out and dropping the spinlock during evaluation, and
  picking up newly arrived waiters in a loop.
- Waiters with equal predicates are linked by `same_condition`; a false
  predicate is evaluated once per run and the rest of its group is skipped
  (`skip_past_same_condition`). Equality is `f` equal and either `v` equal or
  `eq(v0, v1)`; hence the README's warning that C++ lambdas defeat it.
- It stops at the first writer to wake; it wakes all readers whose predicates
  hold; a writer that "could acquire if it were first" sets `MU_WRITER_WAITING`.
- A full scan that woke no one sets `MU_ALL_FALSE`, which lets later **reader**
  unlocks skip evaluation — "a reader region cannot have made any new ones
  true" — and `nsync_mu_unlock_without_wakeup` lets a writer opt out when its
  section cannot have changed any predicate.

A timed-out or cancelled conditional waiter cannot simply leave the queue
without breaking the `same_condition` invariants, so it acquires the spinlock
**and** the writer lock to remove itself, then keeps the lock and returns — "we
might as well give the lock to this waiter" — spinning to do so, because "it's
easier, and seems not to cause problems in practice, since the spinloop backs
off aggressively" ([`mu_wait.c`][muwait-c]).

### Footprint and layout

| Object                        | Size                                                                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `nsync_mu`                    | `uint32_t` + pointer (two words on LP64 after padding)                                                                                 |
| `nsync_cv`                    | `uint32_t` + pointer                                                                                                                   |
| `nsync_once`                  | `nsync_atomic_uint32_` (0 → 1 → 2); waiters share one of 64 static `{nsync_mu, nsync_cv}` pairs hashed by address ([`once.c`][once-c]) |
| `nsync_note`, `nsync_counter` | heap-allocated (`nsync_note_new`, `nsync_counter_new`)                                                                                 |
| `waiter`                      | ≥ `void *sem_space[32]` (256 bytes on LP64) plus links; one cached per thread                                                          |

The waiter's semaphore space is sized for the largest platform semaphore, so
the per-thread record is a few hundred bytes. Locks are not padded.

### Portability

Atomics come from the compiler, C11/C++11, the OS or per-architecture assembly
(`platform/<arch>/src/nsync_atm_<arch>.[csS]`), and "Where possible, the code
avoids conditional compilation (#if, etc.) … The platform-dependent Makefiles
set the appropriate include paths and specify platform-dependent modules"
([`README`][readme]). Semaphore per platform, from [`CMakeLists.txt`][cmake]
and the hand-written builds:

| Platform                         | `nsync_semaphore`                                                                                    |
| -------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Linux                            | futex counting semaphore ([`nsync_semaphore_futex.c`][sem-futex])                                    |
| macOS (CMake), BSDs, other POSIX | `pthread_mutex_t` + `pthread_cond_t` ([`nsync_semaphore_mutex.c`][sem-posix])                        |
| macOS `sem-gcd` build            | `dispatch_semaphore_t` ([`nsync_semaphore_gcd.c`][sem-gcd])                                          |
| Windows                          | `CreateSemaphore(NULL, 0, 1, NULL)` + `WaitForSingleObject` ([`nsync_semaphore_win32.c`][sem-win32]) |
| C++11 builds                     | `std::mutex` + `std::condition_variable`; `c++11.futex` keeps the Linux futex                        |

No build uses `WaitOnAddress`, `__ulock` or `_umtx_op`.

### Async and fiber integration

nsync blocks OS threads, but it is the only system on this page set whose
**waiter is decoupled from the waited-on object by a semaphore pointer**, and
it ships a multi-object wait built on that decoupling. `nsync_wait_n(mu, lock,
unlock, abs_deadline, count, waitable[])` "can be thought of as rather like
Unix's select() or poll(), except the the objects being waited for are
synchronization data structures, rather than file descriptors"
([`nsync_waiter.h`][waiter-h]). Each waitable type supplies three functions —
`ready_time`, `enqueue`, `dequeue` — and `nsync_wait_n` enqueues one
`nsync_waiter_s` per object, all pointing at the same `waiter`'s semaphore,
sleeps once, then dequeues the rest ([`wait.c`][wait-c]). Notes, counters and
condition variables implement it (`nsync_note_waitable_funcs`,
`nsync_counter_waitable_funcs`, `nsync_cv_waitable_funcs`), and `cv.c` already
handles "non-native" waiters on a condvar queue.

For an event-loop registry this is the closest prior art in the set: the
wake action is "store 0 to `waiting`, V a semaphore", so substituting a
semaphore whose V posts a completion to a loop is a local change. What does not
port: the mutex's own slow path (`nsync_mu_lock_slow_`) and conditional
critical sections evaluate predicates and hand out the lock in the unlocker's
thread, which presumes the waiter is a thread that will run soon.

## Strengths

- **Reader/writer lock at mutex cost**: one CAS to acquire or release in either
  mode.
- **Conditional critical sections** remove both the wait loop and every
  `signal` call, with same-predicate grouping and `MU_ALL_FALSE` to bound the
  cost.
- **No global state for locks**: queues hang off the lock; no table, no
  hashing, no growth.
- **Wait morphing for readers and writers**, and a designated-waker bit that
  caps wakeups in flight.
- **Deadlines and composable cancellation (`nsync_note` trees) on every wait**,
  plus `nsync_wait_n` over heterogeneous objects.
- **Starvation bound** by wake count (`LONG_WAIT_THRESHOLD`).

## Weaknesses

- **Two words per lock** where the parking-lot designs need one byte.
- **No pre-queue spinning**: a contended acquire enqueues at once; backoff is a
  `volatile` loop without a CPU `pause` hint.
- **Predicate evaluation runs in the unlocker's thread under the writer lock**,
  and degrades with many distinct false predicates (README).
- **Futex V always makes a syscall**, even when the waiter has not slept.
- **Per-thread waiter ≈ 256 bytes of semaphore space**; notes and counters are
  heap objects.
- **Spurious wakeups allowed** for `nsync_cv` by contract.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                                                 | Trade-off                                                                         |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Queue pointer in the lock, spinlock bit in the word          | Unlocker can walk and edit the queue (predicates, transfer); no global table                              | Two words per lock; a spinlock guards the queue                                   |
| Every lock is a reader/writer lock                           | "There is no particular reason why a reader/writer lock need be significantly slower than a simple mutex" | More bits and modes in every path; `lock_type` indirection                        |
| Conditional critical sections (`nsync_mu_wait`)              | No wait loops, no explicit signalling; "comparable in speed" in common cases                              | Unlock cost grows with distinct false predicates; predicates run in other threads |
| Designated waker (`MU_DESIG_WAKER`)                          | At most one woken-but-not-running thread; later unlocks take the fast path                                | A woken thread's delay delays further wakeups                                     |
| Starvation bound by count (`LONG_WAIT_THRESHOLD` = 30)       | "continue to benefit from the throughput of not having running threads wait unless absolutely necessary"  | Bound is in wakeups, not time; first 29 losses are free                           |
| Mesa condvar with transfer to the mutex queue                | Imprecise wakeups use the critical section better; transfer avoids herds                                  | Spurious wakeups permitted; callers must loop                                     |
| Deadline + `nsync_note` on every wait                        | Absolute deadlines survive loops; cancellation scoped to an activity, not a thread                        | Notes are heap objects with parent/child locking                                  |
| Pluggable waitables with a shared semaphore (`nsync_wait_n`) | `select()` over synchronization objects                                                                   | Allocates when waiting on more than 4 objects                                     |

## Sources

- [`README`][readme] — positioning, conditional critical sections, reader/writer argument, cancellation, portability, build matrix
- [`public/nsync_mu.h`][mu-h], [`nsync_cv.h`][cv-h], [`nsync_mu_wait.h`][muwait-h], [`nsync_waiter.h`][waiter-h], [`nsync_note.h`][note-h], [`nsync_counter.h`][counter-h], [`nsync_once.h`][once-h] — public contracts and design comments
- [`internal/common.h`][common-h] — the lock-word bits, `lock_type`, `waiter`, `LONG_WAIT_THRESHOLD`
- [`internal/mu.c`][mu-c] — fast paths, `nsync_mu_lock_slow_`, `nsync_mu_unlock_slow_` (predicate evaluation)
- [`internal/mu_wait.c`][muwait-c] — `nsync_mu_wait_with_deadline`, timeout removal rationale, `nsync_mu_unlock_without_wakeup`
- [`internal/cv.c`][cv-c] — condvar wait, signal, broadcast, `wake_waiters` transfer
- [`internal/common.c`][common-c], [`wait.c`][wait-c], [`sem_wait.c`][semwait-c], [`once.c`][once-c], [`counter.c`][counter-c], [`wait_internal.h`][waitint-h], [`sem.h`][sem-h]
- [`platform/linux/src/nsync_semaphore_futex.c`][sem-futex], [`platform/macos/src/nsync_semaphore_gcd.c`][sem-gcd], [`platform/posix/src/nsync_semaphore_mutex.c`][sem-posix], [`platform/win32/src/nsync_semaphore_win32.c`][sem-win32], [`platform/posix/src/per_thread_waiter.c`][ptw-posix], [`CMakeLists.txt`][cmake]

> [!NOTE]
> nsync ships no separate design document at the pinned SHA (`5b420ef`,
> 2025-10-29); the "design notes" quoted here are the `README` and the
> comments in `public/*.h` and `internal/*.c`. No benchmark numbers are
> published in the repository, so none are given. The relationship between
> nsync and Abseil's `absl::Mutex` is not stated in either tree read for this
> page and is not claimed here; see [abseil-mutex](./abseil-mutex.md).

<!-- References -->

[ns-repo]: https://github.com/google/nsync/tree/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4
[readme]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/README
[cmake]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/CMakeLists.txt#L91-L183
[mu-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_mu.h
[cv-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_cv.h
[muwait-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_mu_wait.h
[waiter-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_waiter.h
[note-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_note.h
[counter-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_counter.h
[once-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/public/nsync_once.h
[common-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.h
[common-h-bits]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.h#L103-L164
[common-h-longwait]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.h#L207-L208
[common-h-waiter]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.h#L215-L243
[common-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.c
[common-c-spin]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.c#L79-L97
[common-c-waiter]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/common.c#L139-L210
[mu-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/mu.c
[mu-c-slow]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/mu.c#L42-L126
[mu-c-lock]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/mu.c#L128-L199
[mu-c-unlockslow]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/mu.c#L264-L454
[mu-c-unlock]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/mu.c#L456-L520
[muwait-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/mu_wait.c
[cv-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/cv.c
[cv-c-wake]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/cv.c#L33-L147
[cv-c-wait]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/cv.c#L160-L312
[wait-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/wait.c
[waitint-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/wait_internal.h
[sem-h]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/sem.h
[semwait-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/sem_wait.c
[once-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/once.c
[counter-c]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/internal/counter.c
[sem-futex]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/platform/linux/src/nsync_semaphore_futex.c
[sem-gcd]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/platform/macos/src/nsync_semaphore_gcd.c
[sem-posix]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/platform/posix/src/nsync_semaphore_mutex.c
[sem-win32]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/platform/win32/src/nsync_semaphore_win32.c
[ptw-posix]: https://github.com/google/nsync/blob/5b420ef6b16532a4fad4be1fde8e483b6b7bd8f4/platform/posix/src/per_thread_waiter.c
[c-morph]: ./concepts.md#wait-morphing
