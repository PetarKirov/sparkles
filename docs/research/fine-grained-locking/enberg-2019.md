# Enberg, Rao & Tarkoma 2019 — The Impact of Thread-Per-Core Architecture on Application Tail Latency

The shared-nothing answer to locking: do not share the data, so there is no
lock. Enberg et al. partition a key-value store's keys and sockets across one
pinned thread per core and forward each request to the owning core over
single-producer/single-consumer rings. They measure up to 71% lower tail
latency than Memcached. What remains of synchronization is the **cross-core
wakeup**, and the paper names it the bottleneck.

|                 |                                                                                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (ANCS '19, short paper)                                                                                                                                           |
| **Year**        | 2019 (September)                                                                                                                                                        |
| **Authors**     | Pekka Enberg, Ashwin Rao, Sasu Tarkoma (University of Helsinki)                                                                                                         |
| **Venue**       | 2019 ACM/IEEE Symposium on Architectures for Networking and Communications Systems (ANCS), pp. 1–8; [DOI 10.1109/ANCS.2019.8901874][doi]                                |
| **Language**    | C++ (the Sphinx prototype)                                                                                                                                              |
| **License**     | paper: not stated; Sphinx: Apache-2.0                                                                                                                                   |
| **Platforms**   | Linux on two Intel Xeon servers (E5-2680 v3, 48 hardware threads; E5540, 16 hardware threads)                                                                           |
| **Primitive**   | no lock: application-level partitioning + per-pair SPSC rings + an `eventfd` wakeup guarded by a per-thread "sleeping" flag                                             |
| **Source read** | `enberg-2019.pdf` ([author copy][pdf]), all 8 pages; Sphinx at branch `ancs19` ([`07c91393`][sphinx]) — `reactor.h`, `reactor.cpp`, `reactor-epoll.cpp`, `spsc_queue.h` |

## Overview

### What it solves

Synchronization overhead in multi-threaded servers, attacked by removing
sharing rather than by making the lock cheaper. The paper frames the
thread-per-core architecture as conditional on independence
([§I, p. 1][pdf]):

> This reduces the overheads from CPU multiplexing and synchronization, and
> allows threads to be scheduled and balanced at coarse granularity for
> latency-sensitive applications. However, this approach is effective only when
> the threads can run independently.

The two obstacles are "thread synchronization and blocking OS services"
([§I][pdf]). Partitioning removes the first; asynchronous OS interfaces remove
the second.

### Design philosophy

The paper sorts thread-per-core designs into three resource models
([§III-A, p. 2–3][pdf]):

- **Shared-everything**: threads are pinned but data is shared, so the
  application "requires applications to exclude thread synchronization that
  block and starve the CPU cores" (lock-free and wait-free structures). The cost
  is "data bounces between CPU caches and [...] thread synchronization limits
  multicore scalability."
- **Shared-nothing**: "Each thread only accesses the resources assigned to it.
  This eliminates the need for locks because each thread is independent of the
  other threads." The cost is that a request for a key a thread does not own
  "must [be forwarded] to the appropriate thread", and skewed workloads cannot
  spread "because only one CPU core can operate on a specific part of the
  application data."
- **Shared-something**: a hybrid in which more than one core may reach the same
  data, in the spirit of sub-NUMA clustering.

Sphinx is the shared-nothing point, after Seastar ([`seastar-sync`][seastar])
and Barrelfish, which "have exemplified scenarios where partitioning and message
passing are less expensive than shared memory and locking."

## How it works

### Partitioning

Sphinx spawns one thread per configured core. It assigns each key to a core by
"hashing the key with MurmurHash3 and taking the modulo of the number of
threads" ([§IV-A, p. 3][pdf]; [`find_target`][find-target]). Each thread owns a
log-structured memory region of 2 MiB segments, evicted whole in FIFO order.
Sockets are partitioned too: `SO_REUSEPORT` lets the kernel spread connections
across threads "to avoid OS internal lock contention from multiple threads
accessing the same socket" ([§IV-A][pdf]). The thread that owns a connection
serves keys it owns locally. Otherwise it forwards the request to the owning
thread and later relays the response.

### Inter-thread messaging

The forwarding channel is a full mesh of bounded SPSC rings, one per ordered
thread pair ([§IV-A, p. 4][pdf]):

> Sphinx implements message passing in userspace with shared memory and system
> calls for waking up a receiver thread to eliminate IPC overheads. The threads
> communicate with each other using a bounded, lock-free, and single-producer
> single-consumer (SPSC) queue [29] which eliminates the need for cache line
> sharing between producers. Furthermore, we chose eventfd over signals as the
> wakeup mechanism because the latter acquires a process-wide signal handler
> spinlock.

In the source, the mesh is a static
`Queue<void*, 10000> _msg_queues[64][64]` ([`reactor.h` L146][reactor-h-q]).
Each ring has its `_head` and `_tail` on separate cache lines. The producer
publishes with a `release` store of `_tail`, and the consumer frees a slot with
a `release` store of `_head` ([`spsc_queue.h` L53–L98][spsc]). `send_msg`
returns `false` when the ring is full ([`reactor.cpp` L347–L359][send-msg]).
Every caller wraps it in `assert(...)` and marks it `// FIXME`
([`sphinxd.cpp` L148][sphinxd-assert]). There is no backpressure, and the
forward runs only because the build defines no `NDEBUG`.

### The wakeup protocol

Each reactor owns one `eventfd`, registered in its `epoll` set, and one
`std::atomic<bool> _thread_is_sleeping` flag ([`reactor.h` L144][reactor-h-flag]).
The producer half batches wakeups. `send_msg` only sets a bit in a per-thread
`_pending_wakeups` bitset. At the top of each loop iteration,
`wake_up_pending` visits every pending target and, only if that target's flag
reads `true`, clears the flag and `eventfd_write`s 1
([`reactor.cpp` L361–L381][wake-pending]). The consumer half is a Dekker-style
announce-then-recheck ([`reactor-epoll.cpp` L81–L100][run]):

```cpp
wake_up_pending();
if (poll_messages()) {
  nr_events = ::epoll_wait(_epollfd, events.data(), events.size(), 0);
} else {
  _thread_is_sleeping[_thread_id].store(true, std::memory_order_seq_cst);
  if (has_messages()) {
    // Raced with producers, restart:
    _thread_is_sleeping[_thread_id].store(false, std::memory_order_seq_cst);
    continue;
  }
  nr_events = ::epoll_wait(_epollfd, events.data(), events.size(), -1);
  _thread_is_sleeping[_thread_id].store(false, std::memory_order_seq_cst);
}
```

Two properties follow. A wakeup costs a syscall **only when the target has
announced it will sleep**. The waker clears the flag before writing, so a
later producer in the same sleep usually skips the syscall. The clear is a
plain store, not an exchange, so two racing producers can both write; that is
harmless with an `eventfd` counter. Batching per loop turn deduplicates further
wakes to the same target.

> [!WARNING]
> Our reading of the source, not a claim of the paper: the handshake is a
> store-buffering pattern. The consumer does a `seq_cst` store of the flag and
> then an `acquire` load of `_tail`. The producer does a `release` store of
> `_tail` and then a `seq_cst` load of the flag. Under the C++ memory model,
> `seq_cst` on only one side of each pair does not forbid both loads reading the
> old values. On x86 the producer's plain `mov` store can sit in the store
> buffer past its flag load. The producer then sees "awake", the consumer sees
> "empty", and the consumer blocks in `epoll_wait(-1)` with a message queued
> until unrelated I/O arrives. A `seq_cst` fence after the ring publish, or a
> `seq_cst` RMW on the flag, closes it. The same store→load ordering is the
> crux of any `WaitWord` wake protocol.

## Analysis

### State word and fast path

There is no lock word: shared-nothing replaces mutual exclusion with ownership.
The only shared mutable words are each ring's `_head`/`_tail` indices, each
owned by one writer and one reader and each on its own line
([`spsc_queue.h` L53–L54][spsc]), plus the per-thread sleeping flag. The local
fast path is a key lookup in a private `unordered_map`. A remote request costs
two ring hops: a forward and a response.

### Waiting: spin, yield, park

There is no spin in the lock sense. The reactor does **speculate**: after a
loop iteration that found messages, it calls `epoll_wait` with timeout `0`
instead of sleeping, betting "that there will be more message"
([`reactor-epoll.cpp` L88–L90][run]). Only an empty poll leads to the announce,
re-check, and block sequence. The paper's discussion calls the cost of this path
the limit of the design ([§V, p. 6][pdf]):

> software-based request steering, such as message passing between threads
> used by Seastar and our prototype KV store, suffer from high overheads
> because of thread wake-ups [24]. The lack of OS interfaces to perform the
> wake-up forces applications to use POSIX signals or OS-specific interfaces,
> such as eventfd, to perform the wake-up.

### The parking substrate

A thread parks in `epoll_wait(-1)` on a set that contains its own `eventfd`
alongside its sockets. Wakeup sources therefore merge into the I/O wait for
free. This is the [parking](./concepts.md#parking) shape a loop-resident
waiter needs: one kernel wait for all reasons to run. The waiter record is the
per-thread flag in a static array of 64 entries. The `eventfd` costs an
`epoll` registration and a `write`/`read` pair per wakeup. The signal
alternative was rejected because it serializes on a process-wide spinlock
([§IV-A][pdf]).

### Fairness, handoff and starvation

The paper does not address fairness. Each SPSC ring is FIFO, and
`poll_messages` drains rings in fixed thread-id order, emptying each ring
before moving to the next ([`reactor.cpp` L402–L422][poll]). A flooding
low-numbered peer can therefore delay higher-numbered peers within an
iteration. Partitioning makes load imbalance the fairness problem instead: "a
weakness of the thread-per-core model for workloads that do not distribute work
to all cores" ([§IV-C, p. 5][pdf]).

### Condition variables and predicates

Does not apply. There are no blocking waits on shared state. A forwarded
request's continuation is encoded in the message (`Opcode::SetOk`, `GetOk`), so
the "condition" is the arrival of a reply message, not a predicate over shared
memory.

### Footprint and layout

Per thread pair, one ring of 10,000 `void*` slots (about 80 KB) plus two padded
index lines. The `[64][64]` mesh is therefore about 320 MB of address space,
reserved statically ([`reactor.h` L146][reactor-h-q]). Rings grow O(n²) with
the thread count.

### Portability

Linux only: `eventfd`, `epoll`, `SO_REUSEPORT`, IRQ affinity and `irqbalance`.
The paper names the portability gap as the lack of a standard cross-thread
wake interface ([§V][pdf]).

### Async and fiber integration

The design is the event-loop end of the spectrum: each core runs one loop, and
cross-core work arrives as messages, not as lock acquisitions. A cross-thread
wakeup is "push to the target's ring, then write its `eventfd` if it announced
sleep". That shape transfers to io_uring (a ring message, or a write to an
`eventfd` the ring polls), IOCP (`PostQueuedCompletionStatus`) and kqueue
(`EVFILT_USER`).

## Evaluation

Memcached (thread pool sized to the cores, standing in for shared-everything)
versus Sphinx. Load from Mutilate with 24 workers, 30-byte keys and 200-byte
values, read-only (set/get 0.0) and update-only (1.0) mixes, and 24–384
connections. Each test ran 50 s and was repeated 5 times
([§IV-B, p. 4][pdf]). Each machine was tested in three IRQ configurations.

| Configuration (vs Memcached)        | Read p99, modern | Read p99, legacy | Update p99, modern | Update p99, legacy |
| ----------------------------------- | ---------------- | ---------------- | ------------------ | ------------------ |
| `irqbalance` on, no affinity        | up to 16% lower  | up to 9% lower   | up to 67% lower    | up to 47% lower    |
| IRQ affinity on, `irqbalance` off   | up to 20% lower  | up to 54% lower  | —                  | —                  |
| Update p99 vs baseline, affinity on | —                | —                | up to 71% lower    | up to 66% lower    |

- Sphinx is **slower** at low connection counts in the baseline configuration:
  idle partitions cannot help busy ones.
- Disabling `irqbalance` alone cut Memcached's read tail by up to 23% (modern)
  and left Sphinx unchanged. Dedicating 8 of 48 (or 4 of 16) CPUs to NIC IRQs
  helped Sphinx most.
- The gain is largest for **updates**. The paper reads this as "the effectiveness of Sphinx's architecture
  in the eliminating overheads of user space locking."
- Initial YCSB runs found the messaging "inefficient for larger request sizes
  because packet steering involves a memory copy" ([§V][pdf]).

## Relevance to Sparkles

- **(d) the `WaitWord` registry.** Sphinx's wake path is the minimal correct
  shape for a loop-resident waiter: the waiter publishes "I am about to block"
  in a word, re-checks its queue, then blocks in the loop's one kernel wait,
  with the `eventfd` in the same interest set. The waker posts, then reads the
  word and pays the syscall only when it sees "parked". Sparkles' `WaitWord`
  needs the same announce/recheck. The [warning above](#the-wakeup-protocol)
  says how to make it sound: the waker's publish and its read of the waiter's
  state must be ordered by a `seq_cst` fence or RMW.
- **Batch wakeups per loop turn.** Setting a bit per target during a turn and
  issuing at most one wake per target at the turn boundary amortizes the
  syscall the paper names as the bottleneck. A Sparkles loop that wakes other
  loops can coalesce in the same way.
- **Partitioning is the alternative to (a)–(c), not a replacement.** The paper
  shows shared-nothing wins on update-heavy load and loses on skew and low
  concurrency. A `sparkles.base.sync` mutex remains necessary for
  shared-everything code. Thread-per-core designs mostly need the
  cross-thread wake primitive, not the lock.
- **Unbounded push is a bug, not a policy.** `assert(send_msg(...))` shows that
  a bounded ring needs a decided overflow behaviour: block, spill, or fail.
  Sparkles' cross-loop channel must choose one explicitly.

## Strengths

- Measures the claim end-to-end on a real protocol against a production
  baseline, separating IRQ placement from architecture.
- Removes locks entirely from the data path; the update-tail improvement (up to
  71%) isolates what shared-data synchronization costs.
- Names the residual cost precisely: cross-core wakeups and the missing OS
  interface for them.
- Ships its code (Apache-2.0), so the wake protocol can be read, not inferred.

## Weaknesses

- Short paper: a single workload with tiny values, 99th percentile only, and no
  throughput or CPU-efficiency figures.
- Sphinx implements a subset of the Memcached protocol; the comparison is
  architecture versus a full server, not like for like.
- No load balancing: skew and low concurrency penalize it, and the paper defers
  the fix to programmable NICs.
- The prototype has no backpressure (`assert` on a full ring), and its
  sleep/wake handshake lacks the ordering a Dekker pattern requires (see the
  [warning](#the-wakeup-protocol)).

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                                | Trade-off                                                                      |
| ------------------------------------------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Partition keys and sockets per core (hash % n)   | No locks, no cache-line bouncing, no kernel socket-lock contention       | Skewed keys pin load to one core; remote keys cost two message hops            |
| Full mesh of SPSC rings                          | Each index has one writer; no producer-side cache-line sharing           | O(n²) memory (about 320 MB at 64 threads); fixed capacity with no backpressure |
| `eventfd` wakeup inside the loop's `epoll` set   | One kernel wait for I/O and messages; avoids the signal-handler spinlock | A syscall per wakeup — the paper's named bottleneck                            |
| Sleeping flag + recheck before blocking          | Wake syscall only when the target is parked; the waker clears the flag   | Needs store→load ordering on both sides to be free of lost wakeups             |
| Speculative non-blocking poll after a busy turn  | Avoid sleeping when more messages are likely                             | Burns a turn of CPU when the burst has ended                                   |
| Dedicate cores to NIC IRQs, disable `irqbalance` | Keep softirq work off application cores                                  | Fewer cores serve requests (40 of 48, 12 of 16)                                |

## Sources

- [Enberg, Rao & Tarkoma, "The Impact of Thread-Per-Core Architecture on Application Tail Latency", ANCS 2019][pdf] ([DOI][doi]) — §I the independence premise; §II network-stack, affinity and IPI costs; §III-A shared-everything/nothing/something; §III-B IRQ affinity; §IV-A Sphinx partitioning, SPSC messaging, `eventfd` rationale, log-structured memory; §IV-B setup; §IV-C tail-latency results (Fig. 3); §V request steering, wakeup overhead, OS interfaces, Arachne and Shenango.
- Sphinx, branch `ancs19` at [`07c91393ee5e697cac2c9b723363dfd0389c94cb`][sphinx] (last commit 2018-09-06): [`spsc_queue.h`][spsc], [`reactor.h`][reactor-h-flag], [`reactor.cpp`][send-msg], [`reactor-epoll.cpp`][run], [`sphinxd.cpp`][find-target].
- Related catalog pages: [`seastar-sync`][seastar] (the shared-nothing framework the paper follows), [`linux-futex`][futex] (the in-kernel wait a non-loop design would use instead of `eventfd`), [`karsten-barghi-2020`][karsten] (a user-level-threading reply to the same Memcached comparison).

<!-- References -->

[pdf]: https://penberg.org/papers/tpc-ancs19.pdf
[doi]: https://doi.org/10.1109/ANCS.2019.8901874
[sphinx]: https://github.com/penberg/sphinx/tree/07c91393ee5e697cac2c9b723363dfd0389c94cb
[spsc]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/include/sphinx/spsc_queue.h#L53-L98
[reactor-h-flag]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/include/sphinx/reactor.h#L144
[reactor-h-q]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/include/sphinx/reactor.h#L146
[send-msg]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/src/reactor.cpp#L347-L359
[wake-pending]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/src/reactor.cpp#L361-L381
[poll]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/src/reactor.cpp#L402-L422
[run]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/src/reactor-epoll.cpp#L81-L100
[sphinxd-assert]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/src/sphinxd.cpp#L148
[find-target]: https://github.com/penberg/sphinx/blob/07c91393ee5e697cac2c9b723363dfd0389c94cb/sphinxd/src/sphinxd.cpp#L335-L343
[seastar]: ./seastar-sync.md
[futex]: ./linux-futex.md
[karsten]: ./karsten-barghi-2020.md
