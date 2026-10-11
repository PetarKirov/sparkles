# Fine-Grained Locking

A primary-source survey of how locks, condition variables and their
asynchronous cousins are built today: the futex-word locks of Rust, Zig and
glibc; the parking lots of WebKit, `parking_lot` and Go's runtime; the queue
locks behind Abseil, nsync, Java's `AbstractQueuedSynchronizer` and Linux; the
operating systems' wait-on-address primitives; the task-level primitives of
tokio, smol, Seastar, Trio and kotlinx.coroutines; and the papers, from
Concurrent ML in 1991 to combine-and-exchange locks in 2025, that bear on
waiting across threads and fibers. Thirteen lock implementations, four OS
primitives, four async runtimes, twelve papers, and two [runnable
benchmarks][examples].

It is the evidence base for `sparkles.base.sync` — wait-on-address-based
`Mutex`, `Condition`, `Once`, `Event` and `Semaphore` for D, `@nogc nothrow`,
on Linux, Windows, macOS and FreeBSD — and for event-horizon's `WaitWord`,
which lets fibers on a completion-based loop wait on a word another thread
wakes.

This survey answers four questions:

1. **What should the mutex word be?** A parking-lot lock — two bits plus a
   designated-waker bit — over a fixed table of address-keyed queues: faster
   than the three-state futex word once one waiter at a time is woken, and the
   only design that permits wait morphing and handoff. See
   [comparison § (a)][q-a].
2. **What condition-variable algorithm?** Wait morphing: requeue waiters onto
   the mutex's queue, with exact notifications. See [comparison § (b)][q-b].
3. **How fair, and how much spinning?** Barge, bound starvation by a count of
   failed wakes with a handoff to the designated waker, and spin briefly
   before parking. See [comparison § (c)][q-c].
4. **How do loop-resident fibers wait on a word?** In the same parking lot: a
   queue node carries a thread's parker or a fiber's loop waker, so every
   primitive becomes fiber-aware on every OS. See [comparison § (d)][q-d].

**Last reviewed:** October 12, 2026

## Master catalog

| Subject                                 | Category        | Language / OS | Primitive / contribution                                                          | Link             |
| --------------------------------------- | --------------- | ------------- | --------------------------------------------------------------------------------- | ---------------- |
| Rust `std::sync`                        | thread locks    | Rust          | 3-state futex mutex, sequence-counter condvar, queue-based fallbacks              | [→][rust-std]    |
| Zig `std.Io` sync                       | thread locks    | Zig           | futex locks through the `Io` vtable; a parking futex on Windows                   | [→][zig]         |
| glibc NPTL                              | thread locks    | C             | `lll_lock`, adaptive mutexes, the 2016 G1/G2 condvar                              | [→][glibc]       |
| `parking_lot`                           | thread locks    | Rust          | one-byte locks over a global hashed parking table; condvar requeue                | [→][parking-lot] |
| WebKit `WTF::Lock`                      | thread locks    | C++           | two-bit locks, `ParkingLot`, randomized eventual fairness                         | [→][wtf]         |
| Go `sync` and `sema.go`                 | thread locks    | Go            | starvation mode after 1 ms; the runtime's address-keyed semaphore treap           | [→][go]          |
| Abseil `absl::Mutex`                    | thread locks    | C++           | queue pointer in the word, `Await` predicates, `Fer` condvar transfer             | [→][abseil]      |
| nsync                                   | thread locks    | C             | predicate waits without condvars; wake-count starvation bound; `nsync_wait_n`     | [→][nsync]       |
| Folly `synchronization`                 | thread locks    | C++           | `DistributedMutex` combining, `ParkingLot`, `fibers::Baton`                       | [→][folly]       |
| Java `AbstractQueuedSynchronizer`       | thread locks    | Java          | CLH-style queue, `LockSupport.park`, virtual threads unchanged                    | [→][aqs]         |
| `os_unfair_lock`                        | thread locks    | Darwin        | owner in the word, priority inheritance, no spinning                              | [→][unfair]      |
| `SRWLOCK` and `CONDITION_VARIABLE`      | thread locks    | Windows       | pointer-sized, zero-initialized; the 2005–2024 shared-mode bug                    | [→][srw]         |
| Queue locks (MCS, CLH, `qspinlock`)     | thread locks    | Linux, papers | local spinning, the MCS tail in a 32-bit word, `HANDOFF`, CNA                     | [→][queue]       |
| Linux futexes                           | OS wait         | Linux         | futex, PI, requeue, futex2, io_uring futex ops                                    | [→][futex]       |
| Windows `WaitOnAddress`                 | OS wait         | Windows       | user-mode waiter table over thread alerts; IOCP bridges                           | [→][woa]         |
| Darwin `__ulock` and `os_sync`          | OS wait         | Darwin        | private SPI, the macOS 14.4 public API, `EVFILT_USER` bridging                    | [→][ulock]       |
| FreeBSD `_umtx_op`                      | OS wait         | FreeBSD       | `UMTX_OP_WAIT_UINT_PRIVATE`; libthr's user-space condvar queue                    | [→][umtx]        |
| tokio `sync`                            | async           | Rust          | intrusive FIFO semaphore; cancellation that passes the permit on                  | [→][tokio]       |
| smol `event-listener` / `async-lock`    | async           | Rust          | one list for task wakers and thread unparkers; 500 µs starvation mode             | [→][smol]        |
| Seastar                                 | async           | C++           | shard-local primitives; `membarrier` wakeups                                      | [→][seastar]     |
| Trio                                    | async           | Python        | a per-object `ParkingLot`; FIFO handoff; `from_thread`                            | [→][trio]        |
| Reppy 1991 — CML                        | paper           | ML            | first-class synchronous events; `choose`; the Parallel CML protocol               | [→][reppy]       |
| von Behren et al. 2003 — Capriccio      | paper           | C             | user-level threads over async I/O; the cost of the idle path                      | [→][capriccio]   |
| Li & Zdancewic 2007                     | paper           | Haskell       | threads as a monad over an event loop                                             | [→][li]          |
| Ziarek et al. 2011                      | paper           | ML            | composable asynchronous events: register now, resume when matched                 | [→][ziarek]      |
| Tardieu, Wang & Lin 2012                | paper           | X10           | work stealing with suspendable tasks                                              | [→][tardieu]     |
| Seo et al. 2018 — Argobots              | paper           | C             | user-level threads and tasklets for HPC runtimes                                  | [→][argobots]    |
| Enberg, Rao & Tarkoma 2019              | paper           | C++           | thread-per-core; the cross-core wakeup protocol and its lost-wakeup hazard        | [→][enberg]      |
| Karsten & Barghi 2020                   | paper           | C++           | M:N threading; benaphore idle sleep; one wakeup function                          | [→][karsten]     |
| Koval, Khalanskiy & Alistarh 2023 — CQS | paper           | Kotlin        | fair, abortable, verified waiter queues; kotlinx.coroutines' `Mutex`, `Semaphore` | [→][cqs]         |
| Skazhenik et al. 2025                   | paper           | C++           | spin → yield → suspend for locks under cooperative scheduling                     | [→][skazhenik25] |
| Skazhenik et al. 2026                   | paper (Russian) | C++           | the journal study: `BackoffType` for TTAS, MCS and HMCS on coroutines             | [→][skazhenik26] |
| König, Epple & Becker 2025 — CES        | paper           | C++           | combine-and-exchange: resume the waiter locally, requeue the releaser             | [→][koenig]      |

The [concepts][concepts] page defines the shared vocabulary, and the
[comparison][comparison] answers the four questions.

## Taxonomy

### By where waiters live

| Where                                     | Subjects                                                                                                        |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| The kernel, keyed by the lock word        | [Rust std][rust-std], [Zig][zig] (Linux), [glibc][glibc], [`os_unfair_lock`][unfair]                            |
| A user-space table keyed by address       | [`parking_lot`][parking-lot], [WebKit][wtf], [Go][go], [Folly `ParkingLot`][folly], [`WaitOnAddress`][woa]      |
| A queue hanging off the lock              | [Abseil][abseil], [nsync][nsync], [Java AQS][aqs], [queue locks][queue], [tokio][tokio], [event-listener][smol] |
| The waiters' own stacks                   | [Folly `DistributedMutex`][folly], [Linux `qspinlock`][queue]                                                   |
| One thread's data structures (no sharing) | [Seastar][seastar], [Trio][trio], [Enberg 2019][enberg]                                                         |

### By what a fiber or task does while it waits

| Strategy                                   | Subjects                                                                                            |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| Kernel wait as a completion                | [Zig `Io.Uring`][zig], [Linux io_uring futex ops][futex]                                            |
| One park call that knows the waiter's kind | [Java virtual threads][aqs], [Go `gopark`][go], [event-listener][smol], [Folly `Baton`][folly]      |
| Task-level primitives only                 | [tokio][tokio], [Seastar][seastar], [Trio][trio], [kotlinx (CQS)][cqs]                              |
| Blocks the OS thread                       | [Rust std][rust-std], [glibc][glibc], [`parking_lot`][parking-lot], [WebKit][wtf], [Abseil][abseil] |

## Milestones

| Year      | Milestone                                                                               |
| --------- | --------------------------------------------------------------------------------------- |
| 1991      | MCS queue locks; Concurrent ML's first-class events                                     |
| 2002      | Linux futexes merged (2.5.7); Drepper's "Futexes Are Tricky" follows in 2004            |
| 2003      | Capriccio: user-level threads over asynchronous I/O                                     |
| 2004      | Java 5 `java.util.concurrent` and `AbstractQueuedSynchronizer`                          |
| 2012      | Windows 8 adds `WaitOnAddress`                                                          |
| 2015–2016 | WebKit's `ParkingLot` and `WTF::Lock`; Rust's `parking_lot` follows                     |
| 2017      | glibc 2.25 ships Riegel's 2016 condition variable, which drops requeue                  |
| 2016      | macOS 10.12 adds `os_unfair_lock`                                                       |
| 2021      | Linux 5.16 adds `futex_waitv`                                                           |
| 2022      | Rust std replaces pthread with futex locks on Linux                                     |
| 2023      | Linux 6.7: futex2 syscalls and io_uring futex ops; Java 21 virtual threads; CQS at PLDI |
| 2024      | macOS 14.4 publishes `os_sync_wait_on_address`; the `SRWLOCK` shared-mode fix           |
| 2025      | JDK 24 unpins virtual threads in `synchronized` (JEP 491); combine-and-exchange locks   |
| 2026      | `parking_lot` drops automatic eventual fairness (unreleased at the time of reading)     |

Dates are as the deep-dives establish them; the 2002, 2004 and 2012 entries
come from the operating systems' documentation, the others from the cited
sources.

## Suggested reading paths

- **Designing `sparkles.base.sync`:** [concepts][concepts] →
  [Linux futexes][futex] → [Rust std][rust-std] → [glibc][glibc] →
  [`parking_lot`][parking-lot] → [comparison][comparison].
- **Designing `WaitWord`:** [Zig][zig] → [Java AQS § async][aqs-async] →
  [event-listener][smol] → [`WaitOnAddress` § event-loop
  integration][woa-loop] → [CQS][cqs] → [comparison § (d)][q-d].
- **Fairness:** [Go][go] → [WebKit][wtf] → [nsync][nsync] →
  [queue locks][queue] → [CES][koenig].
- **Locks under fibers:** [Capriccio][capriccio] → [Karsten &
  Barghi][karsten] → [Skazhenik 2025][skazhenik25] → [Argobots][argobots].

## Examples

Two runnable programs, compiled and run by `ci --example-files`:

- [`mutex-throughput.d`][ex-mutex] — throughput, fairness, and futex waits and
  wakes per acquisition for a three-state futex word, a parking lock with and
  without a designated waker, a pthread mutex and a spin lock, from one thread
  to twice the core count.
- [`handoff-latency.d`][ex-handoff] — the round trip of handing a turn between
  two sleeping threads over a futex word, an `eventfd` and a pthread condition
  variable.

## Sources

Every deep-dive cites its source trees pinned to a commit, and its papers by
DOI and full text; the PDFs are kept beside the clones, under
`$REPOS/papers/fine-grained-locking/`.

<!-- References -->

[q-a]: ./comparison.md#a-the-mutex-word
[q-b]: ./comparison.md#b-the-condition-variable
[q-c]: ./comparison.md#c-fairness-and-spinning
[q-d]: ./comparison.md#d-fibers-waiting-on-a-word-the-waitword-registry
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[examples]: #examples
[rust-std]: ./rust-std-sync.md
[zig]: ./zig-std-sync.md
[glibc]: ./glibc-nptl.md
[parking-lot]: ./parking-lot.md
[wtf]: ./webkit-wtf-lock.md
[go]: ./go-sync.md
[abseil]: ./abseil-mutex.md
[nsync]: ./nsync.md
[folly]: ./folly-sync.md
[aqs]: ./java-aqs.md
[aqs-async]: ./java-aqs.md#async-and-fiber-integration
[unfair]: ./apple-os-unfair-lock.md
[srw]: ./windows-srwlock.md
[queue]: ./queue-locks.md
[futex]: ./linux-futex.md
[woa]: ./windows-wait-on-address.md
[woa-loop]: ./windows-wait-on-address.md#event-loop-integration
[ulock]: ./darwin-ulock.md
[umtx]: ./freebsd-umtx.md
[tokio]: ./tokio-sync.md
[smol]: ./smol-event-listener.md
[seastar]: ./seastar-sync.md
[trio]: ./trio-sync.md
[reppy]: ./reppy-1991-cml.md
[capriccio]: ./von-behren-2003-capriccio.md
[li]: ./li-zdancewic-2007.md
[ziarek]: ./ziarek-2011-async-events.md
[tardieu]: ./tardieu-2012-x10-work-stealing.md
[argobots]: ./seo-2018-argobots.md
[enberg]: ./enberg-2019.md
[karsten]: ./karsten-barghi-2020.md
[cqs]: ./koval-2023-cqs.md
[skazhenik25]: ./skazhenik-2025-lightweight-locks.md
[skazhenik26]: ./skazhenik-2026-coroutine-sync.md
[koenig]: ./koenig-2025-combine-and-exchange.md
[ex-mutex]: ./examples/mutex-throughput.d
[ex-handoff]: ./examples/handoff-latency.d
