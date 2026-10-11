# Concepts

The vocabulary the deep-dives share. Each term is defined once here and
grounded in the subjects that show it; the deep-dives link to these anchors
rather than redefining them.

**Last reviewed:** October 12, 2026

## Futex

A **futex** ("fast user-space mutex") is a word of ordinary memory that the
kernel lets a thread sleep on: `FUTEX_WAIT(addr, expected)` sleeps only if
`*addr` still equals `expected` — the compare and the sleep are atomic with
respect to `FUTEX_WAKE(addr, n)` — and the uncontended path never enters the
kernel at all. Every lock in this survey is built so that the uncontended
acquire and release are plain atomic instructions and the kernel is reached
only to sleep or to wake ([Linux futexes][linux-futex], [Drepper][linux-futex]).

**Wait-on-address** is the portable name for the same contract:
[`WaitOnAddress`][windows-woa] on Windows, [`__ulock_wait` and
`os_sync_wait_on_address`][darwin-ulock] on Darwin, [`_umtx_op`][freebsd-umtx]
on FreeBSD. They differ in the word sizes they accept (only Windows waits on a
byte; Linux only on 32 bits — [sizes][linux-futex-sizes]), in what a wake
reports, and in where the waiter table lives: in the kernel for Linux, Darwin
and FreeBSD, in user mode (`ntdll`) for Windows
([how it works][windows-woa-how]).

## Parking

To **park** is to put the calling thread (or task) to sleep until someone
**unparks** it, keyed by something other than the lock word's value. Two
substrates recur:

- **A futex on the lock word itself** — the waiter sleeps on the address of
  the lock ([Rust std][rust-std], [glibc][glibc], [Zig][zig]).
- **A per-thread parker plus a queue** — each thread owns an event (a futex
  word, a semaphore, a mutex and condition variable), waiters queue in a
  structure keyed by the lock's address, and unpark wakes one thread's own
  event. The queue lives either in a global hashed table (a **parking lot**:
  [WebKit][wtf], [parking_lot][parking-lot], [Go's `sema.go`][go],
  [Folly][folly], [Zig on Windows][zig-substrate]) or in the lock word itself,
  which then holds a pointer ([Abseil][abseil], [nsync][nsync],
  [SRWLOCK][srwlock]).

A parking lot lets a lock occupy a byte or two bits, because the waiters live
elsewhere; the price is a shared table whose buckets collide, grow and are
leaked by design ([parking_lot § How it works][parking-lot-how]).

## Spinning

**Spinning** retries an acquire in a loop instead of sleeping, betting that
the holder releases soon. A spin costs CPU and cache traffic; a sleep costs a
system call and a wake-up latency of microseconds
([cost][linux-futex-cost], [handoff benchmark][ex-handoff]). Policies differ
widely: a fixed bound (Rust: 100), exponential `pause` bursts then yields
(parking_lot, WebKit), adaptive by recent history (glibc's
`PTHREAD_MUTEX_ADAPTIVE_NP`), spin only while another processor runs the holder
(Go), or never (Zig, nsync, `os_unfair_lock`). A spin that ignores who is
waiting can be self-defeating — see [convoys](#convoys).

## Barging and handoff

A lock **barges** when a releaser makes it free and any thread — often the
releaser itself, re-locking — may take it before the woken waiter runs. A lock
**hands off** when the releaser passes ownership directly to a chosen waiter,
which then owns the lock while it is still waking. Barging maximizes
throughput and permits starvation; handoff is FIFO-fair and turns every
release into a context switch. Most locks barge by default and add a
**starvation bound**: a time after which they hand off (Go after 1 ms,
WebKit's randomized ~1 ms per bucket, parking_lot until 0.9.12), or a wake
count (nsync after 30 failed wakeups).

## Convoys

A **convoy** forms when every acquirer of a busy lock goes to sleep and the
lock moves from thread to thread at the pace of wake-ups rather than of the
critical section. A lock that wakes a waiter on every unlock while its queue
is non-empty invites one once the cores are saturated: each woken waiter
loses the race to a running thread and parks again. The
[mutex benchmark][ex-mutex] shows a two-bit parking lock with an exact
`PARKED` bit sleeping on 76–97% of acquisitions, where a three-state futex
word, whose barging relock forgets that anyone waits, sleeps on 4%. A
**designated-waker** bit — at most one woken-but-not-running waiter per lock,
as in nsync and Abseil — cures it: the same parking lock then sleeps on 0.2%
and outruns both ([nsync § fairness][nsync-fair]).

## Lock-holder preemption

**Lock-holder preemption** is the scheduler descheduling the thread that holds
a lock, so every spinner burns its slice for nothing. It is why user-space
spin locks collapse once threads outnumber cores, why Go spins only while
another processor is running, and why queue locks that spin are a kernel tool,
used where preemption is disabled ([queue locks][queue-locks]).

## Thundering herd

A **thundering herd** is waking many waiters when only one can proceed: they
all run, all but one fail, and all go back to sleep. A condition variable's
broadcast to waiters that all need the same mutex is the classic case.
[Wait morphing](#wait-morphing) avoids it; glibc's 2016 condition variable
accepted it rather than complicate the mutex ([glibc][glibc-cv]).

## Wait morphing

**Wait morphing** (also **requeueing**) moves a condition variable's waiters
onto the mutex's wait queue instead of waking them, so a broadcast costs at
most one wake-up and the rest wake as the mutex is released. parking_lot
requeues with `unpark_requeue`; Abseil moves a signalled waiter onto the
mutex queue without waking it; FreeBSD's libthr defers the wake until the
mutex unlock. glibc, Rust std and Zig do not, and say why
([glibc § condition variables][glibc-cv]).

## Combining

**Combining** lets the thread holding a lock execute critical sections on
behalf of waiting threads, which publish their operation and receive the
result, so a burst of contended operations runs on one core with warm caches.
Flat combining, Folly's [`DistributedMutex`][folly], and combine-and-exchange
locks are instances.

## Queue locks

A **queue lock** gives each waiter its own node to spin on — MCS, CLH — so
waiting causes no shared cache-line traffic, and hands the lock along the
queue in FIFO order. Linux's `qspinlock` packs an MCS queue's tail into a
32-bit word ([queue locks][queue-locks]). User space borrows two ideas from
them: local spinning, and a word that encodes the queue.

## Spurious wakeups

A **spurious wakeup** is a return from a wait that no matching wake caused.
Every OS primitive in this survey permits them, and a wake may land on memory
that has since been freed and reused: glibc's futex layer documents that a
`FUTEX_WAKE` can reach an object destroyed after its last unlock
([glibc][glibc]). Every wait therefore re-checks its condition in a loop, and
a registry keyed by address must tolerate stale wakes.

## Priority inversion

**Priority inversion** is a high-priority thread waiting on a lock held by a
low-priority thread that cannot run. Priority inheritance raises the holder's
priority while it holds the lock; it needs the kernel to know who the holder
is — Linux PI futexes store the owner's thread id in the word, and Darwin's
`os_unfair_lock` does the same ([`os_unfair_lock`][unfair]). A lock whose word
does not name its owner cannot inherit priority.

<!-- References -->

[linux-futex]: ./linux-futex.md
[linux-futex-sizes]: ./linux-futex.md#sizes-and-alignment
[linux-futex-cost]: ./linux-futex.md#cost
[windows-woa]: ./windows-wait-on-address.md
[windows-woa-how]: ./windows-wait-on-address.md#how-it-works
[darwin-ulock]: ./darwin-ulock.md
[freebsd-umtx]: ./freebsd-umtx.md
[rust-std]: ./rust-std-sync.md
[glibc]: ./glibc-nptl.md
[glibc-cv]: ./glibc-nptl.md#condition-variables-and-predicates
[zig]: ./zig-std-sync.md
[zig-substrate]: ./zig-std-sync.md#the-parking-substrate
[wtf]: ./webkit-wtf-lock.md
[parking-lot]: ./parking-lot.md
[parking-lot-how]: ./parking-lot.md#how-it-works
[go]: ./go-sync.md
[folly]: ./folly-sync.md
[abseil]: ./abseil-mutex.md
[nsync]: ./nsync.md
[srwlock]: ./windows-srwlock.md
[unfair]: ./apple-os-unfair-lock.md
[queue-locks]: ./queue-locks.md
[ex-mutex]: ./examples/mutex-throughput.d
[ex-handoff]: ./examples/handoff-latency.d
[nsync-fair]: ./nsync.md#fairness-handoff-and-starvation
