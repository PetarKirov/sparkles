---
status: draft
owner: sparkles:event-horizon
---

# The fiber parker — Specification

## Abstract

event-horizon's scheduler installs a fiber
[parker](../../glossary.md#parker), so that a fiber that waits on a
`sparkles.base.sync` primitive suspends instead of blocking its loop's
thread. This page specifies that parker against the parker contract of
[base.sync SPEC §4](../base/sync/SPEC.md#_4-parkers) and
[§4a](../base/sync/SPEC.md#_4a-cancellation): how the scheduler installs it,
where its records live, how a wake from any thread reaches the fiber's own
worker, how deadlines and cancellation resume a sleep, and what a pinned fiber
may do. On Linux 6.7 and later a parked fiber waits in the kernel through
io_uring's futex operations; everywhere else it waits in its scheduler, and a
wake reaches it through an inbox.

## Introduction

`sparkles.base.sync` keeps every waiter, thread or fiber, in one parking lot
and leaves sleeping and waking to the waiter's parker. A thread parker sleeps
on a word through the kernel; a fiber parker must instead suspend one fiber,
let its loop run others, and resume the fiber on the worker that owns it,
whichever thread delivers the wake. The unparker may be a fiber on another
worker, a blocking-pool thread, or a thread that event-horizon has never
seen.

Three properties of the scheduler shape the design. A started fiber never
leaves its worker (SPEC §11), so a parked fiber's owner is fixed. A worker's
state is touched only by its own thread (§7.2), so a foreign thread can only
post to it. And cancellation is latched on the fiber (§8.4): it stays pending
until the fiber's scope ends, and cleanup that must wait runs inside
`protect`.

event-horizon uses every kernel facility that makes its work cheaper, and
io_uring's futex operations (Linux 6.7) fit a fiber park exactly. A park
becomes an ordinary I/O park on the fiber's own word: one terminal
completion resumes it, a linked timeout is its deadline, a wake from another
worker is a submission on that worker's ring with no system call of its own,
and a wake from a foreign thread is one `futex` call. `IORING_OP_FUTEX_WAITV`
adds the fiber's cancellation node to the same wait, so cancelling a scope
wakes all its parked fibers with one wake per node. Where the operations are
missing — other backends, older kernels — the parker uses the path the
blocking pool already posts through (§13.8): a lock-free inbox and the loop's
coalescing `Waker`. Which path wins is measured, not assumed (§7).

The parker does not decide outcomes. Whether a resumed sleep was a wake, a
timeout or a cancellation is settled by the parking lot under the bucket
lock (base.sync SYP4, SYP5); the parker only resumes the fiber with the
reason it saw first.

## 1. Terms

- **Park word**: a 32-bit atomic word in each fiber task's slab entry,
  holding the task's park generation and whether it is sleeping.
- **Park generation**: a counter in the park word, incremented at every
  sleep; a wake, timer or cancellation names the generation it was issued
  for.
- **Owner**: the worker whose scheduler runs a fiber.
- **Ring path**, **inbox path**: the two ways a sleep waits and a wake reaches
  the owner (§3, §4).
- **Cancel word**: a 32-bit atomic word in each cancellation node (§8.2),
  changed and woken when the node is cancelled.

## 2. Installation, sleeping and waking

**EFP1: Current parker.** A scheduler **must** install its fiber parker as
base.sync's current parker (SYK1) whenever it resumes a fiber, and restore
the thread parker whenever the fiber suspends or ends. Code the loop runs
outside any fiber, such as tier-A callbacks, **must** see the thread parker.

_Rationale:_ A callback has no fiber to suspend; waiting there blocks the
loop, which is the thread parker's documented behaviour, not a fiber parker's
to hide.

**EFP2: Records and words.** A fiber's parker record and park word **must**
live in its fiber task, in the scheduler's task slab, and need no allocation.
A task that is recycled (§7.1) **must** have retired every registration of
its record (base.sync SYP15) and reaped the terminal completion of every
operation that names its park word before it is reused.

**EFP3: Park generations.** `prepare` **must** increment the generation in
the park word and mark it sleeping; `commitWake` **must not** change the
word. Every resumption — a delivered wake, a deadline, a cancellation —
**must** move the word out of sleeping in its generation, to woken, timed
out or cancelled, by one atomic compare-and-swap. Only the resumption whose
swap succeeds **may** make the fiber runnable and report its reason. A
delivery that finds its generation timed out or cancelled **must** still
move the word to woken, and **must not** make the fiber runnable; any other
losing resumption **must** have no effect. A sleep that begins in a generation
already woken **must** return woken at once; one that begins timed out or
cancelled **must** move the word back to sleeping and wait. A delivery
delayed across a wrap-around of the generation can at worst resume a later
park spuriously, which the parking lot absorbs (base.sync SYP4).

A park sleeps again in one of two ways. While its record is still enqueued,
base.sync calls `prepare` under the bucket lock first, which begins a new
generation (SYK2, SYP4). Once an unparker has dequeued the record, the park
sleeps again, without a deadline or cancellation, in the same generation,
waiting for that unparker's delivery (SYP5).

_Rationale:_ This is the late-delivery rule of base.sync SYP10 and SYK8 made
concrete: a delivery that names an old generation cannot match, so it cannot
resume a later park. A delivery that loses to its own generation's deadline
is not stale: the parking lot has dequeued the record and waits for exactly
that delivery, so it is recorded, and the second sleep consumes it, rather
than lost, which would leave the park asleep forever.

**EFP4: Wake handles.** `commitWake` **must** return a handle naming the
owner scheduler, the task's slab index and the park generation, and
**must not** refer to the record. The scheduler **must** count the
deliveries committed and not yet completed, and **must not** free its slab,
its inbox or itself while that count is non-zero. A delivery is complete once
the deliverer can no longer touch the owner's storage: when its inbox push and
`Waker.wake()` have returned, when its `futex` call has returned, or when the
completion of its `IORING_OP_FUTEX_WAKE` has been reaped on the deliverer's ring.

**EFP5: Sleep.** `sleep(deadline, interruptible)` **must** suspend only the
calling fiber and return the reason its winning resumption carried: woken,
timed out, or cancelled — or woken, if a delivery for its generation arrived
before it returned, since that delivery means an unparker has dequeued the
record (EFP3). The reason is tentative; the parking lot decides the
park's outcome under the bucket lock (base.sync SYI3), and the parker's
`settle` has nothing to consume, since cancellation stays latched (EFP16). Its deadline and its cancellation **must** be
resumptions of the sleep's generation, and neither **may** take effect after
`sleep` returns.

**EFP6: Path selection.** A scheduler **must** use the ring path for an
operation — the sleep, the cancellation of EFP10, the bucket wait of EFP11 —
when its backend reports `futexOps` (SPEC §3.3) and either
`LoopGroupConfig.fiberPark` is `ring`, or it is `auto` and §7's recorded decision
chooses the ring path for that operation; until FB1–FB7 are recorded, `auto`
chooses the ring path wherever it is supported. Otherwise it **must** use the
inbox path. `fiberPark = inbox` **must**
force the inbox path on any backend, so that tests and benchmarks run both on
one kernel. Both paths **must** satisfy every other requirement here.

The cancellation's ring route (EFP10) **must** be selected only together with
the ring sleep. With the ring sleep and the inbox cancellation, an
interruptible sleep waits with `IORING_OP_FUTEX_WAIT` alone, and node
cancellation reaches each member as a direct interruption (EFP10). The bucket
wait is selected on its own. A recorded decision that names ring cancellation
with the inbox sleep **must** be rejected when the scheduler starts.

## 3. The ring path

**EFP7: Waiting in the kernel.** A sleep **must** wait with
`IORING_OP_FUTEX_WAIT` on its park word, expecting the sleeping value of its
generation, with `FUTEX2_SIZE_U32` and `FUTEX2_PRIVATE`, as an I/O park (§7.3):
the operation's terminal completion resumes the fiber. Its cancellation
follows EFP10, not §7.3's per-operation `ASYNC_CANCEL`. A
deadline **must** be an `IORING_OP_LINK_TIMEOUT` linked to the wait. Every
terminal completion of the wait, a wake included, **must** read the park
word. If a resumption's swap has already won, the sleep **must** report that
resumption's reason. Otherwise a deadline's completion **must** perform
EFP3's swap as a timeout, and a wake's completion, which can come from an
earlier generation because the kernel matches wakes by address, **must**
write the wait again for the remaining deadline.

**EFP8: Deferred submission.** The scheduler **must** write a sleep's wait
only at the tick's submission point (§7.2), and **must not** write it if the
park word has left the sleeping value by then, or, for an interruptible
sleep, if the fiber's interrupt is latched or its node is cancelling; such a
sleep performs EFP3's swap with the corresponding reason, if no swap has
won, and resumes without an operation. A wake that a fiber on the owner delivers within the same tick
therefore never reaches the kernel.

_Rationale:_ Same-worker handoffs are the common case, and the inbox path
handles them with one enqueue; deferring the wait keeps the ring path from
costing them an operation.

**EFP9: Delivery.** `deliverWake` **must** perform EFP3's swap and, if it
wins and the wait may have been written, wake the park word: from a thread
that owns a ring, with an `IORING_OP_FUTEX_WAKE` on that ring, submitted no
later than its next submission point; from any other thread, with one
`futex(FUTEX_WAKE_PRIVATE)` call. A ring thread whose ring has no free slot or
submission entry **must** make the `futex` call instead, so that delivery never
fails. On the owner, before the wait is written, a winning swap **must**
enqueue the fiber at the tail of the ready queue.
`deliverWake` **must** be `nothrow @nogc` and never block.

**EFP10: Cancellation in the same wait.** An interruptible sleep **must**
wait with `IORING_OP_FUTEX_WAITV` on its park word and on the cancel word of
the fiber's current cancellation node, expecting for the cancel word the value
the sleep read before suspending, and cancellation reaches it by one of two
routes:

- **Node cancellation.** `cancelTree` (§8.2) **must**, for each node it marks
  cancelling, latch every member fiber's interrupt, then change the node's
  cancel word with release ordering and wake every waiter on it with one
  wake (EFP23). Each member cancel function it fires **must** be told that a
  node sweep fired it, and **must not** wake, or submit an `ASYNC_CANCEL`
  for, a fiber whose wait on that word has been written; for any other
  member it acts as a direct interruption.
- **Direct interruption** of one fiber: its cancel function **must** latch the
  interrupt, perform EFP3's swap as a cancellation and, if it wins, wake the
  park word as EFP9 does.

A completion caused by the cancel word — its wake, or `EAGAIN` for its entry
— **must** perform EFP3's swap as a cancellation only if the node is
cancelling; otherwise the wake was stray, and the sleep **must** write its
wait again for the remaining deadline.

**EFP11: Bucket waits in the kernel.** `bucketWait(word, expected)` **must**
wait with `IORING_OP_FUTEX_WAIT` on the bucket word, expecting `expected`,
which base.sync's bucket unlock
wakes through its seam (SYP13), and **must not** be a cancellation
checkpoint.

## 4. The inbox path

**EFP12: Delivery.** `deliverWake` **must** perform EFP3's swap. From a fiber
of the owner, a winning swap **must** enqueue the fiber at the tail of the
ready queue. From anywhere else — another thread, or the owner's thread
outside its fibers, as in a loop callback — it **must** push the task onto
the owner's wake inbox and then, if the push found the inbox empty, call the owner's
`Waker.wake()` (SPEC §5.6); a push onto a non-empty inbox follows one whose
wake has not yet been drained. It **must not** touch other scheduler state.

**EFP13: Inbox drain.** The owner **must** drain its wake inbox at every
point where it drains the blocking-completion inbox, enqueueing the drained
tasks at the tail of the ready queue in the order they were pushed. Each task
**must** use one inbox link, which a winning swap alone may push, so a task is
in the inbox at most once.

**EFP14: Deadlines and cancellation.** A deadline **must** arm a scheduler
timer whose expiry is a resumption of the sleep's generation; an
interruptible sleep **must** install the fiber's one-shot cancel function
(§8.2), whose call is one too, and clear it before returning.

**EFP15: Bucket waits.** `bucketWait` **must** yield the fiber to the tail of
the ready queue and **must not** be a cancellation checkpoint.

_Rationale:_ A bucket is held only for queue edits (base.sync SYP13), so the
yield loop spins only while the holder is preempted; FB6 measures that
against the ring path's kernel wait.

## 5. Cancellation

**EFP16: Sticky cancellation.** A sleep with `interruptible` true **must**
return cancelled at once, without suspending, if the fiber's interrupt is
latched (§8.4) and the fiber is not inside `protect`. The parker **must not**
clear the latch: every later interruptible sleep in the same scope returns
cancelled too.

_Rationale:_ The fiber shell treats the latch as authoritative, so that a
body that ignores a `cancelled` result still ends interrupted (§8.4). That is
the scheduler rule base.sync SYI3 leaves to the parker.

**EFP17: Non-interruptible sleeps.** A sleep with `interruptible` false
**must not** wait on a cancel word, **must not** install a cancel function and
**must not** return cancelled; a cancellation that arrives during it stays
latched.

**EFP18: Protected regions.** The parker's protected-region query (base.sync
SYI4) **must** report whether the fiber runs inside `protect`. A shielded child
(§8.2) is not masked: a shield stops cancellation propagating from its
ancestors, while cancellation aimed at the shield's node, or at the fiber
itself, reaches its interruptible sleeps.

## 6. Spinning, pinning, shutdown and resources

**EFP19: Relax.** `relax(step)` **must** issue a processor pause hint for the
first steps and yield the fiber to the scheduler for the rest (base.sync
SYK7).

**EFP20: Pinned fibers.** The scheduler **must** keep base.sync's pin count
per thread and **must**, in builds with assertions, fail any suspension of a
fiber while the count is non-zero (base.sync SYK9). A pinned fiber's parks
go through the thread parker and block its worker.

_Rationale:_ A fiber suspends only at a verb, a yield or a park, and none of
those is allowed while pinned, so the count of the thread is the count of
its running fiber.

**EFP21: Retention at shutdown.** A scheduler **must not** be destroyed while
any of these remain: a committed delivery not yet complete (EFP4); an
operation naming a park word, a cancel word or a bucket word before its
terminal completion; a record of one of its fibers queued or registered in
the parking lot (base.sync SYP15); a task in its wake inbox; or a live fiber.
If `LoopGroup.shutdown`'s grace period (§11) expires with any of them — a fiber
parked non-interruptibly on an event nobody sets, say — shutdown **must**
return its timeout error and leak the scheduler, its task slab, its inbox and
its loop, wake routing included, rather than free them, so that a later wake
from any thread touches live memory. A run a defect ends early, with fibers
still live, **must** likewise leak its loop and its tasks rather than free
them; if a fiber is then parked on a base.sync primitive, its record and
every later wake name the scheduler the defect unwound, so the scheduler
**must** report the defect and end the process through the loop's fatal hook.

**EFP22: Reserved resources.** The scheduler **must** reserve, for each task
in its slab, the op slot a park needs on its path. A timed park on the ring
path **must** obtain both submission entries for its wait and linked timeout
before writing either, flushing the submission queue until two are free, and
**must** publish the queue's tail only after both are written; a flush that
frees no entry **must** be retried after the completion queue has been
reaped. `LoopGroup.start` **must** reject the ring path with fewer than two
submission entries. So a park never fails for lack of a slot or an entry. It **must**
arm its wake routing — its inbox and its loop's `Waker` — before any of its
fibers can park. A slot a park holds **must** count as live work in drain
accounting (§5.6).

**EFP23: Cancel-word wakes.** The kernel **must** never hold a cancel word's
address after its node's scope exits (SPEC §8.3). `cancelTree` **must** wake
a cancel word through a scheduler hook, with one `futex(FUTEX_WAKE_PRIVATE)`
call that has returned before `cancelTree` does, and only while the node
counts a member whose wait on that word has been written; it **must not**
queue a ring operation naming the word.

_Rationale:_ A cancellation node lives on a fiber's stack (§8.1). A wake
still queued when its scope exits would name whatever node next takes that
stack slot, and only EFP10's stray-wake rule would stand between it and a
false cancellation. The hook keeps the effects side free of ring code.

## 7. Benchmarks

The two paths are measured against each other on the reference machine (the
host [benchmarks.md](./benchmarks.md) reports), with `fiberPark` forced to
each. Every workload runs on two workers unless it says otherwise.

| Bench | Workload                                                                                      | Records                                                         |
| ----- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| FB1   | two fibers on one worker hand a `Semaphore` permit back and forth                             | ns per handoff; operations submitted per handoff                |
| FB2   | the same handoff between fibers on two workers                                                | ns per handoff; system calls per handoff                        |
| FB3   | an unregistered thread releases a `Semaphore` a parked fiber waits on                         | wake-to-resume latency, median and 99th percentile              |
| FB4   | one `Event` set wakes `n` fibers spread over all workers, `n` from 1 to 256                   | time until the last resumes; system calls and wakes per set     |
| FB5   | a scope with `n` fibers in interruptible waits is cancelled, `n` from 1 to 1024               | time until the last resumes; system calls per cancellation      |
| FB6   | eight workers' fibers contend for mutexes whose keys share a bucket                           | CPU time of the waiting workers; throughput of the other fibers |
| FB7   | the same-worker and cross-worker handoffs with a 100 µs deadline on every wait, none expiring | ns per handoff, against FB1 and FB2                             |

`auto` **must** choose the ring path only where FB1–FB7 show it no slower
than the inbox path beyond the run-to-run spread; where one workload loses,
the choice is made per operation (the sleep, the cancellation of EFP10, the
bucket wait of EFP11), and recorded here with the numbers.

## Testing

| Requirement       | Check                                                                                                                                                                                                                                                                                                                                                             | Oracle                     |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| EFP1              | a tier-A callback and a fiber on one loop each report their current parker                                                                                                                                                                                                                                                                                        | unit                       |
| EFP3, EFP5        | on each path, a wake delivered after the sleep timed out does not resume the fiber's next park; a wake, a deadline and a cancellation race for one generation, and one wins                                                                                                                                                                                       | base.sync oracle 1, stress |
| EFP2, EFP4, EFP21 | a foreign thread's delivery is delayed past the fiber's return and the scheduler's shutdown begins; a fiber parked non-interruptibly on an unset event outlives the grace period, shutdown times out, and a thread then sets the event; AddressSanitizer sees no use after free                                                                                   | ASan stress                |
| EFP6              | on Linux 6.18, `ring` waits in the kernel and `inbox` does not, and `auto` follows §7's recorded decision per operation; each allowed combination of per-operation choices passes the EFP10/EFP14 row, and a decision naming ring cancellation with the inbox sleep fails to start; the kqueue and IOCP backends use the inbox path                               | unit, `strace`             |
| EFP7, EFP9, EFP12 | a fiber waiting for a `Mutex` is woken by a fiber on another worker, a blocking-pool thread and an unregistered thread; each resumes on its owner, on each path                                                                                                                                                                                                   | native, every backend      |
| EFP8              | a same-tick same-worker handoff submits no operation                                                                                                                                                                                                                                                                                                              | unit, submission counter   |
| EFP10, EFP14      | cancelling a scope with parked interruptible fibers resumes each once, on the ring path with one wake per cancelled node and no `ASYNC_CANCEL`; directly interrupting one fiber of an uncancelled node resumes it alone                                                                                                                                           | unit, submission counter   |
| EFP11, EFP15      | a thread holds a bucket lock by a test hook while a fiber contends for it; another fiber on that loop keeps running, and on the ring path the waiting fiber burns no CPU                                                                                                                                                                                          | native                     |
| EFP16–EFP18       | after a cancellation, every interruptible wait in the scope returns cancelled, a `Mutex` lock still succeeds, and an interruptible wait inside `protect` sleeps; a shielded child waiting interruptibly on a `Semaphore` survives its ancestor's cancellation and returns cancelled when its owner cancels the shield, on each path                               | unit, every path           |
| EFP3              | a test build with a 2-bit generation keeps an old wake handle across a wrap-around: the current waiter neither gains ownership nor loses a legitimate wake                                                                                                                                                                                                        | base.sync oracle 1         |
| EFP19             | `relax` issues its pause steps and then yields, counted; a holder on the same loop releases during the yields                                                                                                                                                                                                                                                     | unit, counter              |
| EFP22             | with the op slab and submission queue exhausted by I/O, parks on both workers still succeed and every wake is delivered; with `sqEntries = 2`, and with one free entry when a timed park arrives, the wait and its linked timeout reach the kernel in one submission and the deadline fires; `sqEntries = 1` with `fiberPark = ring` fails to start               | unit, `strace`             |
| EFP3, EFP7        | a test hook holds a `futex` wake for generation g−1 until the fiber has parked in generation g, then releases it: the fiber does not resume while its word is sleeping in g, and the wake for g then resumes it exactly once                                                                                                                                      | unit, ring path, stress    |
| EFP8, EFP10       | a fiber enters an interruptible ring sleep and, in the same tick before the submission point, another fiber on its worker cancels the scope: the sleep returns cancelled with no wait written; a fiber in a written wait is cancelled by a node sweep, with one wake on its node and none on its park word, and by a direct interruption, with one park-word wake | unit, submission counter   |
| EFP10, EFP23      | a scope is cancelled while none of its fibers has a written wait and exits in the same tick; a new scope's node takes the same stack slot with a fiber in an interruptible ring sleep: that fiber is not cancelled, and no futex operation names the slot after the first scope exits                                                                             | unit, `strace`             |
| EFP20             | a fiber that suspends while holding a `Mutex` fails its assertion                                                                                                                                                                                                                                                                                                 | unit                       |

## Evidence ledger

| Requirements                                                        | State                                        | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Gap                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EFP1, EFP3–EFP5, EFP16–EFP20 (both paths); EFP12–EFP14 (inbox path) | verified on Linux x86-64, `io_uring` backend | the white-box tests of `libs/event-horizon/src/sparkles/event_horizon/fiber_park.d`: a delivery that loses to its own deadline enqueues nothing; a sleep begun after it returns woken, and one begun before it waits for it; a stale or aliased generation neither owns nor loses a wake; a delivery outlives its fiber and holds off `destroy`; `relax` pauses, then yields. The scenarios of `libs/event-horizon/src/sparkles/event_horizon/fiber_park_test.d`: wakes from the same worker, another worker, a blocking-pool thread and an unregistered thread; one event set waking more fibers than a commit round; inbox order; deadlines; sticky scope cancellation; direct interruption; `protect`; shields; the pin assertion; each context's parker. Both pass under AddressSanitizer. Undoing the delivery protocol, the inbox reversal, the parker installation, the pin contract or sticky cancellation each fails a test | the kqueue and IOCP backends build, but their unit-test builds do not compile (`loop.d`'s `io_uring`-only tests), so "every backend" is unmet; no stress run; EFP3's 2-bit-generation build is replaced by a forced aliased generation                                    |
| EFP2, EFP21, EFP22 (inbox path)                                     | partly verified                              | a fiber that ends holding a parking-lot registration fails its assertion; `destroy` waits out committed deliveries; the waker is armed when the scheduler is created; a defect that ends a run while a fiber sleeps on a timer leaks the run and keeps its message, and one that strands a fiber parked on a `Semaphore` ends the process after reporting the defect                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | EFP21's timed-out shutdown has no path: `run` returns only once every fiber has finished, so a fiber parked on an event nobody sets is reachable only through a shutdown requested during the run; EFP22's slab and submission-entry reservations belong to the ring path |
| EFP6–EFP9, EFP22 (ring path)                                        | verified on Linux 6.18 x86-64                | the scenarios of `libs/event-horizon/src/sparkles/event_horizon/fiber_park_test.d` run on both paths, and on the ring path: only it waits in the kernel; a same-tick handoff and a foreign wake before the submission point submit nothing; a stray wake writes the wait again; fewer than two submission entries fail to start. Undoing the wake of a written wait, the submission point's recheck, a busy tick's reap or the stray-wake rewrite each fails a test                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | a delivery from a loop callback on a ring thread wakes with the `futex` call, not a ring wake; the fallback when the deliverer's ring has no slot has no scenario                                                                                                         |
| EFP10                                                               | partly verified                              | direct interruption ends a written ring wait through a wake of the park word, and scope cancellation reaches each member that way, which EFP6 allows beside the ring sleep                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | the node-cancellation route, `FUTEX_WAITV` on the cancel word, is not built                                                                                                                                                                                               |
| EFP11, EFP15                                                        | open                                         | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | both bucket waits are built, the ring one in the kernel; no test holds a bucket lock through a test hook, which base.sync does not offer                                                                                                                                  |
| EFP23                                                               | planned                                      | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | lands with EFP10's node-cancellation route                                                                                                                                                                                                                                |
| FB1–FB7                                                             | planned                                      | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | no ring path to compare against yet; `auto`'s choice is unmade until they run                                                                                                                                                                                             |
