# Queue-based spin locks (MCS, CLH, ticket, Linux `qspinlock`, OSQ, CNA)

The spin-lock lineage that made contended locking scale — every waiter spins
on its own cache line and the releaser hands the lock to exactly one successor
— traced from the 1991 MCS paper to the Linux kernel's 4-byte `qspinlock`,
the MCS-queued optimistic spinning inside the kernel `mutex`, and the
NUMA-aware CNA variant; plus what of it survives in user space, where a
waiter can be preempted.

|                       |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**              | algorithm family (papers) + kernel implementations                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **Language**          | pseudo-code (papers); C (Linux)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **License**           | Linux: GPL-2.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Repository**        | [`torvalds/linux`][linux-repo] at v7.3-rc6: `kernel/locking/`, `include/asm-generic/`                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **Papers**            | Mellor-Crummey & Scott, "Algorithms for Scalable Synchronization on Shared-Memory Multiprocessors", _ACM TOCS_ 9(1):21–65, February 1991, DOI [10.1145/103727.103729][mcs-doi]; Dice & Kogan, "Compact NUMA-aware Locks", EuroSys 2019, pp. 1–15, DOI [10.1145/3302424.3303984][cna-doi] ([arXiv:1810.05600v2][cna-arxiv])                                                                                                                                                                                       |
| **Lock word**         | MCS/CLH: one tail pointer; ticket: two counters; `qspinlock`: 32 bits = locked byte + pending + encoded MCS tail; kernel `mutex`: owner `task_struct *` with 3 flag bits; CNA: one tail pointer                                                                                                                                                                                                                                                                                                                  |
| **Parking substrate** | none — waiters spin (`cpu_relax`, `smp_cond_load_*`); the PV `qspinlock` halts the vCPU via hypercall; the kernel `mutex` sleeps on its wait list after spinning                                                                                                                                                                                                                                                                                                                                                 |
| **Source read**       | MCS paper: spin-lock sections 1, 2, 4.1–4.3 and 5 in full, barrier sections 3 and 4.4–4.5 skimmed ([`$REPOS/papers/fine-grained-locking/mellor-crummey-scott-1991.pdf`][mcs-pdf]); CNA paper §1–7.1 in full, §7.2 kernel results skimmed ([`dice-kogan-2019-cna.pdf`][cna-arxiv]); Linux [`qspinlock.c`][qs-c], [`qspinlock_types.h`][qs-types], [`qspinlock_paravirt.h`][qs-pv], [`ticket_spinlock.h`][ticket], [`osq_lock.c`][osq], [`mutex.c`][mutex-c], [`mutex.h`][mutex-h], [`mutex_types.h`][mutex-types] |

> [!NOTE]
> CLH has no full-text source on this page. Craig's report ("Building FIFO and
> priority-queuing spin locks from atomic swap", University of Washington TR
> 93-02-02, 1993) and Magnussen, Landin & Hagersten ("Queue locks on cache
> coherent multiprocessors", IPPS 1994) were not reachable as open full text.
> The CLH description below is taken from Lea's AQS paper and source (see
> [Java AQS](./java-aqs.md)), which quote and adapt it. CNA was never merged:
> the pinned Linux tree has no `qspinlock_cna.h`, and the paper's kernel patch
> is the version linked from it ([LWN][cna-lwn]).

## Overview

### What it solves

MCS's abstract names the problem and the cure ([Mellor-Crummey & Scott
1991][mcs-pdf], abstract):

> The key to these algorithms is for every processor to spin on separate
> locally-accessible flag variables, and for some other processor to terminate
> the spin with a single remote write operation at an appropriate time.

A test-and-set lock makes every waiter hammer one line, and every release
invalidates every waiter's copy; a ticket lock reduces the RMWs to one per
acquire but still has all waiters poll `now_serving`. A queue lock gives each
waiter a private flag and makes release a single write to the successor's
flag: O(1) remote references per acquisition regardless of waiter count.

### Design philosophy

The MCS lock's four claims ([§2.4][mcs-pdf]): it "guarantees FIFO ordering of
lock acquisitions; spins on locally-accessible flag variables only; requires a
small constant amount of space per lock; and works equally well (requiring
only O(1) network transactions per lock acquisition) on machines with and
without coherent caches." Its pseudo-code is short enough to quote whole
([Fig. 5][mcs-pdf]):

```text
procedure acquire_lock (L : ^lock, I : ^qnode)
    I->next := nil
    predecessor : ^qnode := fetch_and_store (L, I)
    if predecessor != nil          // queue was non-empty
        I->locked := true
        predecessor->next := I
        repeat while I->locked     // spin

procedure release_lock (L : ^lock, I : ^qnode)
    if I->next = nil               // no known successor
        if compare_and_swap (L, I, nil)
            return
        repeat while I->next = nil // spin
    I->next->locked := false
```

The same paper is explicit that FIFO spinning is the wrong tool when waiters
can be descheduled ([§4.3][mcs-pdf]):

> This guarantee of fairness is likely to be considered an advantage in many
> environments, but is likely to waste CPU resources if spinning processes may
> be preempted. […] Alternatively (for mutual exclusion), a test-and-set lock
> with exponential backoff will allow latecomers to acquire the lock when
> processes that arrived earlier are not running.

## How it works

**Ticket lock.** Two counters; acquire is `fetch_and_increment(next_ticket)`
then spin until `now_serving` equals the ticket; release increments
`now_serving`. MCS recommend proportional backoff (`my_ticket - now_serving`)
and warn that "exponential backoff is clearly a bad idea" because "overshoot
in backoff by the first processor in line will delay all others" ([§2.2][mcs-pdf]).
Linux's generic version packs both 16-bit halves into one `atomic_t`
(`atomic_fetch_add(1<<16, &lock->val)`) and "relies on atomic_fetch_add()
having well defined forward progress guarantees under contention"
([`ticket_spinlock.h`][ticket]).

**CLH.** The lock is a tail pointer to a node; an acquirer swaps its node in
as the new tail and spins on its _predecessor's_ node ("The release status for
each node is kept in its predecessor node", Lea 2004 §3.3, quoted in
[Java AQS](./java-aqs.md)). Release writes the holder's own node; the holder
then reuses its predecessor's node for its next acquire. CLH needs no `next`
pointer and no CAS on release, at the cost of spinning on a remote node on
machines without coherent caches — the reason AQS chose it ("more easily
adapted to handle cancellation and timeouts").

**Linux `qspinlock`.** The kernel needed MCS behaviour inside a 4-byte
`spinlock_t`. The source's opening comment ([`qspinlock.c`][qs-c-intro]):

> In particular; where the traditional MCS lock consists of a tail pointer
> (8 bytes) and needs the next pointer (another 8 bytes) of its own node to
> unlock the next pending (next->locked), we compress both these: {tail,
> next->locked} into a single u32 value.
>
> Since a spinlock disables recursion of its own context and there is a limit
> to the contexts that can nest; namely: task, softirq, hardirq, nmi. As there
> are at most 4 nesting levels, it can be encoded by a 2-bit number. Now we can
> encode the tail by combining the 2-bit nesting level with the cpu number.

The word layout ([`qspinlock_types.h`][qs-types]):

```c
/*
 * When NR_CPUS < 16K
 *  0- 7: locked byte
 *  8-15: pending byte
 * 16-17: tail index
 * 18-31: tail cpu (+1)
 */
```

Queue nodes are per-CPU and preallocated: `qnodes[_Q_MAX_NODES]` (4, one per
context), "Exactly fits one 64-byte cacheline on a 64-bit architecture"
([`qspinlock.c`][qs-c-nodes]). The slow path
([`queued_spin_lock_slowpath`][qs-c-slow]) is a three-tier state machine over
`(tail, pending, locked)`:

1. **Pending.** With no tail and no pending, set `pending` and spin on the
   `locked` byte; the second contender never touches a queue node. A pending
   → locked handover in flight is waited out for at most `_Q_PENDING_LOOPS`
   (1, or `1 << 9` on x86).
2. **Queue.** Otherwise take this CPU's node, retry `trylock` once ("We
   touched a (possibly) cold cacheline"), publish with `xchg_tail`, link
   `prev->next = node`, and spin on `node->locked`.
3. **Head.** At the queue head, spin on the lock word until `locked` and
   `pending` clear; claim with a CAS `tail → locked` if we are also the tail,
   else `set_locked` and write `next->locked`.

The first waiter spins on the lock word, not its node, which is what keeps
unlock a plain byte store with no node: "This also makes the unlock code
simpler and faster."

**OSQ.** For sleeping locks the kernel keeps a separate MCS-like queue of
_spinners_, one per-CPU `optimistic_spin_node` with `next`/`prev` and an
encoded-CPU tail ([`osq_lock.c`][osq]): "An MCS like lock especially tailored
for optimistic spinning for sleeping lock implementations (mutex, rwsem,
etc)." Unlike MCS it supports cancellation — the waiter stops when
`need_resched()` or its predecessor's vCPU is preempted
(`smp_cond_load_relaxed(&node->locked, VAL || need_resched() ||
vcpu_is_preempted(node_cpu(node->prev)))`) and unlinks itself in three steps
([`osq_lock.c`][osq-wait]).

**Kernel `mutex`.** The mutex owner word is a `task_struct *` with three low
flag bits ([`mutex.h`][mutex-h]): "Bit0 indicates a non-empty waiter list;
unlock must issue a wakeup. Bit1 indicates unlock needs to hand the lock to
the top-waiter. Bit2 indicates handoff has been done and we're waiting for
pickup." Before sleeping, an acquirer spins only while the owner is running
([`mutex.c`][mutex-optspin]):

> We try to spin for acquisition when we find that the lock owner is currently
> running on a (different) CPU and while we don't need to reschedule. The
> rationale is that if the lock owner is running, it is likely to release the
> lock soon.
>
> The mutex spinners are queued up using MCS lock so that only one spinner can
> compete for the mutex.

**CNA.** An MCS variant whose unlock looks for a successor on the holder's
NUMA socket and moves skipped waiters to a secondary queue whose head pointer
is passed in the successor's `spin` field, so the lock stays one word
([Dice & Kogan 2019][cna-arxiv], §4):

> Instead of simply passing the lock to its successor, the current lock
> holder h would traverse the main queue and look for a thread running on the
> same socket (the socket of each thread is recorded in its node). If it finds
> one, say a thread h′, it moves all threads […] between h and h′ from the
> main queue to the secondary queue, and passes the ownership to h′.

## Analysis

### State word and fast path

| Lock         | Word                                      | Acquire (uncontended)                  | Release                                    |
| ------------ | ----------------------------------------- | -------------------------------------- | ------------------------------------------ |
| Ticket       | `next_ticket`, `now_serving`              | one `fetch_add`                        | increment `now_serving` (store-release)    |
| MCS          | tail pointer                              | `swap(L, I)`                           | `CAS(L, I, nil)` (needs the node)          |
| CLH          | tail pointer                              | `swap(L, I)`                           | store to own node                          |
| `qspinlock`  | u32: locked u8, pending u8, tail u16      | `cmpxchg(0 → _Q_LOCKED_VAL)` (acquire) | `smp_store_release(&lock->locked, 0)`      |
| Kernel mutex | `atomic_long_t owner` = task ptr \| flags | `cmpxchg_acquire(0 → current)`         | `cmpxchg_release(current → 0)` if no flags |
| CNA          | tail pointer                              | `swap` (same as MCS)                   | MCS-like `CAS`, plus queue scan            |

The trick that transfers to any word-sized lock is `qspinlock`'s: encode the
_tail of a queue whose nodes live elsewhere_ (per-CPU, per-thread) as a small
index rather than a pointer, so a queue fits beside the lock bits. It works
because the node pool is bounded (CPUs × 4 contexts); a user-space analogue
needs a bounded thread-index space.

### Waiting: spin, yield, park

Pure spin in all the queue locks, with `cpu_relax()`/`smp_cond_load_*`
(which may use `WFE` on Arm instead of polling, per
[`ticket_spinlock.h`][ticket]). There is no park; preemption is disabled while
a kernel spinlock is held or awaited, which is what makes FIFO spinning safe.
The two exceptions show how spinning is bounded once waiters can lose the
CPU:

- **Paravirt `qspinlock`**: "the general idea is to halt the vcpus instead of
  spinning them" — `pv_wait(u8 *ptr, u8 val)` "suspends the vcpu if" `*ptr == val` ([`qspinlock_paravirt.h`][qs-pv]); queue nodes spin at most `SPIN_THRESHOLD`
  (`1 << 15` on x86) iterations — and stop early "if the vCPU in the previous
  node is not running" — before halting, and the queue head likewise spins
  `SPIN_THRESHOLD` times on the lock before halting. This is a futex-shaped
  wait-on-byte, at the hypervisor.
- **Kernel `mutex`**: `mutex_spin_on_owner` loops `while (__mutex_owner(lock)
== owner)` and gives up when `!owner_on_cpu(owner) || need_resched()`
  ([`mutex.c`][mutex-spinowner]); `owner_on_cpu` also checks
  `vcpu_is_preempted`. Only the OSQ head spins on the owner; others spin on
  their OSQ node. Failing that, the task sleeps on the wait list, and when
  woken as first waiter it may spin again.

### The parking substrate

None for spin locks — that is the defining property. The kernel `mutex`
parks in `schedule_preempt_disabled()` on a wait list protected by
`wait_lock` (a `raw_spinlock_t`) inside the mutex
([`mutex_types.h`][mutex-types]); waiter records (`struct mutex_waiter`) are
on the sleeping task's stack. Queue-lock nodes play the role of waiter
records: per-CPU in `qspinlock` and OSQ, caller-supplied in MCS/CLH, per-thread
TLS in CNA ("each thread would have a preallocated (small) number of such
structures in a thread-local storage", §5).

### Fairness, handoff and starvation

Ticket, MCS and CLH are strict FIFO with direct handoff: the releaser names
the next owner. "A ticket lock is fair in a strong sense; it eliminates the
possibility of starvation" ([§2.2][mcs-pdf]). That is ideal under
no-preemption and pathological otherwise: if the designated successor is
descheduled, every later waiter waits for it — the
[lock-holder-preemption](./concepts.md#lock-holder-preemption) problem
extended to lock-_waiter_ preemption. `qspinlock` is FIFO among queued CPUs
but lets one pending CPU and the fast-path CAS barge ahead of the queue head.
The kernel `mutex` is the user-space-relevant design: it barges (optimistic
spinners and new arrivals can take an unlocked mutex) but bounds starvation
with a [handoff](./concepts.md#barging-and-handoff) flag — a woken first
waiter that fails `__mutex_trylock_or_handoff` sets `MUTEX_FLAG_HANDOFF`, and
the next unlock then transfers ownership directly (`__mutex_handoff` sets the
owner to the waiter with `MUTEX_FLAG_PICKUP`) instead of releasing
([`mutex.c`][mutex-trylock]). CNA trades strict FIFO for socket locality and
restores long-term fairness probabilistically: `keep_lock_local()` returns
`pseudo_rand() & 0xffff`, so roughly one handover in 65 536 flushes the
secondary queue back (§5, Fig. 5).

### Condition variables and predicates

Not applicable: spin locks are held with preemption disabled and cannot wait
on a condition. The kernel builds waiting on top (`wait_event`, completions)
with separate wait queues; the MCS paper's other half is barriers, not
condvars. The relevant export is the queue itself: AQS's `ConditionObject`
moves a node from a condition list onto a CLH queue — see
[Java AQS](./java-aqs.md#condition-variables-and-predicates).

### Footprint and layout

MCS, CLH and CNA locks are one pointer; ticket and `qspinlock` are 4 bytes.
The queue-node cost moves out of the lock: MCS/CLH need a node per
(thread, held-or-awaited lock) — MCS's release needs the caller's node,
which changes the API (`release_lock(L, I)`), the reason Linux made the first
waiter spin on the lock word instead. Array-based queue locks (Anderson,
Graunke–Thakkar) were rejected for "space per lock linear in the number of
processors" ([§2.3][mcs-pdf]). CNA's motivation is footprint: the kernel
"strictly limits the size of its spin lock to 4 bytes", and hierarchical
NUMA-aware locks "require space proportional to the number of sockets" (§1).
The kernel `mutex` is larger: owner word, `raw_spinlock_t`, OSQ tail,
`first_waiter` pointer.

### Portability

The algorithms need `swap` (MCS, CLH), `fetch_add` (ticket) and `CAS` (MCS
release, `qspinlock` claim). Linux's `qspinlock` additionally "only supports
architectures that allow atomic operations on smaller 8-bit and 16-bit data
types" ([`qspinlock.c`][qs-c-intro]); architectures without strong forward
progress for sub-word RMW fall back to ticket or test-and-set locks.

### Async and fiber integration

None, and by construction: a spinning waiter occupies its CPU. What user space
and an event loop take from this family is structural rather than the spin
itself:

- **Handoff as a starvation bound**, applied only after a waiter has lost a
  race (the mutex `HANDOFF`/`PICKUP` protocol), rather than always (convoys)
  or never (starvation).
- **Spin only while the owner runs**: the mutex and Darwin's adaptive ulock
  ([Apple `os_unfair_lock`](./apple-os-unfair-lock.md#waiting-spin-yield-park))
  both condition spinning on owner-on-CPU, which user space cannot observe
  without an owner id in the word or a kernel hint.
- **One spinner at a time** (OSQ) to keep contended spinning off the lock's
  cache line.
- **Tail-in-the-word**: an index-encoded tail turns a word into a queue head
  whose nodes live in a bounded per-thread (or per-fiber) pool — the shape a
  `WaitWord` registry for loop-resident fibers could use.

## Evaluation

**MCS 1991.** Measured on a BBN Butterfly 1 (up to 256 nodes, no coherent
caches) and a Sequent Symmetry Model B (up to 30 i386 CPUs, snooping caches).
On the Butterfly, time per acquire/release grew 7.4 µs per extra processor
for test-and-set and 7.0 µs for a ticket lock without backoff; above 10
processors the slopes for test-and-set with exponential backoff, ticket with
proportional backoff and MCS were 0.025, 0.021 and 0.00025 µs per processor
(§4.3). Single-processor latency on the Symmetry: test-and-set 7.0 µs,
Anderson 10.6 µs, MCS 9.2 µs ("only 31 percent higher"); on the Butterfly
34.9, 38.7 (ticket), 65.7 and 71.3 µs. Recommendation: MCS when
`fetch_and_store` exists; ticket with proportional backoff when latency
dominates; test-and-set with capped exponential backoff "if processes might be
preempted while spinning" (§5).

**CNA 2019.** Two-socket Xeon E5-2699 v3 (72 logical CPUs) and four-socket
E7-8895 v3 (144), threads unpinned. On an AVL-tree key-value map with no
external work, MCS throughput fell from 5.3 to 1.7 ops/µs between 1 and 2
threads; CNA matched MCS at 1–2 threads and was 39 % faster at 70 threads
(50 % on update-only), 97 % faster at 142 threads on four sockets. With light
contention CNA was 14 % slower than MCS at 4 threads, fixed by a "shuffle
reduction" variant. Its fairness factor stayed "for the most part … well
below 60%" (0.5 = strictly fair). In the kernel, `locktorture` gained up to
65 % (four sockets, default config) and `will-it-scale` `open1_threads` 120 %
at 142 threads.

## Relevance to Sparkles

- A user-space `Mutex` must not spin FIFO: MCS's own recommendation for
  preemptible waiters is a barging lock with bounded backoff, and every
  surveyed user-space lock ([`parking_lot`](./parking-lot.md),
  [WTF::Lock](./webkit-wtf-lock.md), [Java AQS](./java-aqs.md)) follows it.
- The kernel `mutex` handoff flag is a word-sized eventual-fairness mechanism
  that needs no timer: set by a waiter that lost after waking, honoured by the
  next unlock.
- `qspinlock`'s encoded tail shows a queue head fits in the lock word when
  nodes come from a bounded pool; a D `WaitWord` registry could index fiber
  wait records the same way.
- Spinning should be gated on evidence the owner is running; without an owner
  id in the word, a short bounded spin is the only available proxy.

## Strengths

- O(1) remote references per acquisition; local spinning; FIFO handoff.
- One-word lock state (MCS, CLH, CNA) or 4 bytes (`qspinlock`).
- `qspinlock` keeps the pre-existing API: no node passed to unlock.
- OSQ and the mutex handoff bit adapt the ideas to sleeping locks.

## Weaknesses

- FIFO spinning collapses under preemption (waiter and holder alike).
- MCS needs a per-acquire node and a node-carrying release API.
- `qspinlock`'s encoding depends on bounded nesting and a bounded CPU count.
- CNA adds a queue scan to unlock and is unmerged in mainline Linux.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                       | Trade-off                                                    |
| ----------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------ |
| Spin on a private flag (MCS/CLH)          | O(1) coherence traffic per handover             | Per-waiter node; FIFO handoff to possibly-descheduled waiter |
| Ticket counters                           | One RMW per acquire, FIFO, tiny                 | All waiters poll one line                                    |
| `qspinlock` tail index in the u32         | MCS scaling inside a 4-byte `spinlock_t`        | Needs bounded contexts × CPUs and sub-word atomics           |
| Pending bit before queueing               | Second contender skips the cold node cache line | One more state in the word                                   |
| Mutex spins only while owner on CPU       | Spinning pays off only if release is imminent   | Needs the owner identity in the word                         |
| Mutex `HANDOFF` after a lost race         | Bounds starvation without a timer               | Handoff latency (owner wakes successor) on that one transfer |
| CNA secondary queue in successor's `spin` | NUMA locality without growing the lock          | Unlock scans the queue; fairness is probabilistic            |

## Sources

- J. M. Mellor-Crummey and M. L. Scott, "Algorithms for Scalable
  Synchronization on Shared-Memory Multiprocessors", _ACM TOCS_ 9(1):21–65,
  1991, [DOI][mcs-doi], [PDF][mcs-pdf].
- D. Dice and A. Kogan, "Compact NUMA-aware Locks", EuroSys 2019,
  [DOI][cna-doi], [arXiv][cna-arxiv]; kernel patch via [LWN][cna-lwn].
- Linux v7.3-rc6: [`kernel/locking/qspinlock.c`][qs-c],
  [`qspinlock_paravirt.h`][qs-pv], [`include/asm-generic/qspinlock_types.h`][qs-types],
  [`include/asm-generic/ticket_spinlock.h`][ticket],
  [`kernel/locking/osq_lock.c`][osq], [`kernel/locking/mutex.c`][mutex-c],
  [`kernel/locking/mutex.h`][mutex-h], [`include/linux/mutex_types.h`][mutex-types].

<!-- References -->

[linux-repo]: https://github.com/torvalds/linux/tree/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a
[qs-c]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/qspinlock.c
[qs-c-intro]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/qspinlock.c#L29-L62
[qs-c-nodes]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/qspinlock.c#L66-L74
[qs-c-slow]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/qspinlock.c#L130-L399
[qs-types]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/asm-generic/qspinlock_types.h#L13-L94
[qs-pv]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/qspinlock_paravirt.h#L10-L45
[ticket]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/asm-generic/ticket_spinlock.h#L1-L45
[osq]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/osq_lock.c#L1-L45
[osq-wait]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/osq_lock.c#L93-L208
[mutex-c]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/mutex.c
[mutex-trylock]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/mutex.c#L82-L127
[mutex-spinowner]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/mutex.c#L385-L450
[mutex-optspin]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/mutex.c#L452-L476
[mutex-h]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/kernel/locking/mutex.h#L24-L37
[mutex-types]: https://github.com/torvalds/linux/blob/a90ee4305c4a5df72c11b31dacfdc76e00fcf78a/include/linux/mutex_types.h#L41-L55
[mcs-doi]: https://doi.org/10.1145/103727.103729
[mcs-pdf]: https://www.cs.rochester.edu/u/scott/papers/1991_TOCS_synch.pdf
[cna-doi]: https://doi.org/10.1145/3302424.3303984
[cna-arxiv]: https://arxiv.org/abs/1810.05600
[cna-lwn]: https://lwn.net/Articles/778235
