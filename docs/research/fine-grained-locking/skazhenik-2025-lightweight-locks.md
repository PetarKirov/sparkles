# Skazhenik et al. 2025 — Basic Lock Algorithms in Lightweight Thread Environments

What happens to TTAS and MCS when the "threads" are stackful user-level threads
on a cooperative scheduler. Pure spinning can **deadlock**: the holder yields
inside its critical section, and the waiters never yield back. The paper adds a
three-stage **spin → yield → suspend** backoff and a lock-free suspend/resume
handshake on the queue node. It reports that the best stage mix depends on the
library and the critical section, and it recommends a **cohort lock**: one TTAS
flag over N MCS queues.

|                 |                                                                                                                                                                                         |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (arXiv preprint, cs.DC)                                                                                                                                                           |
| **Year**        | 2025 (arXiv v1 dated 2025-12-09)                                                                                                                                                        |
| **Authors**     | Taras Skazhenik, Nikolai Korobenikov, Vitaly Aksenov (ITMO University); Andrei Churbanov, Anton Malakhov (Huawei, Russia)                                                               |
| **Venue**       | arXiv:2512.08563 [cs.DC] — no peer-reviewed venue at the time of reading; [abstract page][abs]                                                                                          |
| **Language**    | C++ (Argobots, Boost.Fiber)                                                                                                                                                             |
| **License**     | not stated (arXiv preprint)                                                                                                                                                             |
| **Platforms**   | Linux on four Intel Xeon Gold 5218 (4 × 16 cores, NUMA); runs on 4, 16 and 64 cores                                                                                                     |
| **Primitive**   | TTAS and MCS with a `BackoffPolicy` (spin → yield → suspend); `TTAS-MCS-N` cohort lock                                                                                                  |
| **Source read** | `skazhenik-2025-lightweight-locks.pdf` ([arXiv PDF][pdf]), all 15 pages. The cited code repository (`github.com/tarasska/nasl-tools`) returned HTTP 404 on 2026-10-11 and was not read. |

> [!NOTE]
> The paper is by **Skazhenik, Korobenikov, Churbanov, Malakhov and Aksenov**
> (ITMO University and Huawei), posted to arXiv on 2025-12-09 with no venue.
> Shintaro Iwasaki co-authored a work it
> cites (Shiina et al., PPoPP '21), not this paper.

## Overview

### What it solves

Locks designed for preemptive OS threads assume a holder always makes progress.
With cooperative user-level threads that assumption breaks
([§1, p. 2][pdf]):

> In cooperative environments, one may yield or spawn a new thread inside the
> critical section. [...] Unfortunately, if we use existing lock
> implementations, a thread holding a lock may yield execution while others
> spin indefinitely, causing a deadlock. Thus, one has to adapt them for
> lightweight threads.

The motivating case is a critical section that calls a parallelized library
routine (an OpenBLAS threading-backend change is cited): the holder spawns
lightweight threads and joins them. Any waiter spinning on the same carrier
thread starves those children.

### Design philosophy

The question is not the lock algorithm but **what a waiter does inside its
wait loop** ([§3.1, p. 4][pdf]). For OS threads the answers are `cpu_relax`,
`sched_yield` (which "the scheduler can ignore"), `nanosleep`, and a
[futex](./concepts.md#futex), which "uses kernel-level queue and should be
regarded as an independent low-level primitive". In Argobots and Boost.Fiber,
the user-level analogues are reduced to **yield** and **suspend/resume**.
Timer sleep is not universal: Argobots lacks it, and "for short durations,
[it] may be nearly equivalent to a yield." The stages are then ordered by cost
([§3.2, p. 5][pdf]):

> The key idea is that the time spent at each stage should be smaller than the
> overhead spent on the next threading mechanism. For example, if spinning
> takes longer than performing a yield and regaining control, the algorithm
> should use yield rather than making active spinning.

## How it works

### The backoff policy

Every wait loop calls `OnSpinWait()`. An iteration counter selects the stage
(Listing 2, [p. 7][pdf]):

```text
OnSpinWait():
  iterations++
  if iterations < YIELD_LIMIT:                    Spin(min(1 << iterations, SPIN_LIMIT))   # exponential
  elif iterations < SUSPEND_LIMIT or node == nil: Yield()
  else:                                           TrySuspend(node)
```

The exact backoff function is "not crucial"; they use exponential backoff.
TTAS creates the policy with `node == nil`, so it **never suspends**: there is
no queue node to carry a wake handle.

### The suspend/resume handshake

Argobots' `suspend`/`resume` has a lost-wakeup hazard: "invoking resume before
suspend will result in the thread sleeping indefinitely" ([§3.1, p. 5][pdf]).
The paper contrasts this with Java, where an `unpark` before `park` is
remembered (see [`java-aqs`][java-aqs]). The fix is a one-word, lock-free
handshake on the MCS node's `atomic<uintptr_t> resumeHandle`, with two reserved
values, `READY_FOR_SUSPEND = 0` and `KEEP_ACTIVE = 1` (Listing 2,
[§3.2.1, p. 6–7][pdf]):

```text
TrySuspend(node):  if CAS(node.resumeHandle, READY_FOR_SUSPEND, handle): library_suspend(handle)
Resume(node):      h = EXCHANGE(node.resumeHandle, KEEP_ACTIVE)
                   if h > KEEP_ACTIVE: library_resume(h)
```

The waiter publishes its handle with a CAS from 0. A waker that arrives first
leaves `KEEP_ACTIVE`, so the CAS fails and the waiter keeps polling its
`locked` flag. A waker that arrives after the CAS sees a real handle and owns
the resume. The waker's exchange and the waiter's CAS serialize on one word,
so exactly one of "do not sleep" and "must resume" happens. The paper notes
the design is "compatible with any queue-lock structure."

> [!WARNING]
> As listed, the CAS succeeds and _then_ the library suspend runs. A waker that
> exchanges between those two steps calls `library_resume` on a thread that has
> not yet suspended, which is the exact hazard described for Argobots. The
> listing relies on "suspend" being safe to race with "resume", for example a
> scheduler that defers the resume until the thread has parked. The paper does
> not say how this window is closed for either library.

### MCS and TTAS adaptations

In MCS (Listing 1, [p. 6][pdf]), the policy wraps two loops. In `lock`, the
waiter waits on `node.locked`, using all three stages. In `unlock`, the
releaser waits for a successor that has swapped `tail` but not yet linked
`next`; that wait "is expected to be resolved within a very short time;
therefore, suspension is unnecessary and may even be detrimental", so it uses
spin and yield only. After `node.next.locked = false` the releaser calls
`Resume(node.next)`. TTAS uses the same policy without suspension.

### The cohort lock `TTAS-MCS-N`

An outer atomic flag owns the lock. Under it sit N MCS queues
([§3.2.2, p. 7][pdf]). Acquire makes one try-lock on the flag (the fast path).
On failure the thread joins an MCS queue, picked by core ID mod N or at random,
with no measured difference. The head of each queue then competes for the flag
in a TTAS loop (spin and yield, no suspension). Release clears the flag and
passes queue ownership. With N = 1 it is "the main choice when writing the code
in Java and is known as unfair `ReentrantLock`".

## Analysis

### State word and fast path

TTAS: one boolean. The cohort lock adds N MCS tail pointers, and its fast path
is a single try-lock on the flag. The MCS node gains a third word,
`resumeHandle`, beside `locked` and `next`. Memory orders are not specified in
the pseudo-code; the paper writes `CAS`/`EXCHANGE` without orderings.

### Waiting: spin, yield, park

This is the paper's subject. On a cooperative scheduler, **spinning alone is
unsafe**, not just wasteful, because the holder may need the waiter's carrier
thread. Yield is cheap while there are about as many lightweight threads as
cores, but its cost "increases" with the thread count. Suspension costs more
per wait but releases the carrier. The measured answer (below) depends on the
library: on Boost.Fiber the stages differ sharply, while on Argobots "the costs
of yield and suspend [...] do not differ significantly". Immediate suspension,
as in the library mutexes, is "not an effective strategy" for latency.

### The parking substrate

A suspended lightweight thread waits on its MCS node, with the library's
resume handle stored in `resumeHandle`. There is no global table: the node,
usually on the waiter's stack, _is_ the waiter record, as in
[queue locks](./concepts.md#queue-locks). The library mutexes in Argobots and
Boost.Fiber use "an external flag used as a fast path and a waitlist of
suspended threads protected by a spinlock" ([§2, p. 4][pdf]).

### Fairness, handoff and starvation

MCS is FIFO among waiters on one queue. The cohort lock is FIFO within a queue
and barging across queue heads and newcomers, so newcomers can take the outer
flag first ([barging](./concepts.md#barging-and-handoff)). The paper frames its
latency plots (p99 lock-acquire time) as the fairness proxy: the cohort lock
"combines the high throughput of TTAS with the low latency characteristic of
fair queue-based locks" ([§5.2, p. 12][pdf]). It states no starvation bound.

### Condition variables and predicates

Not addressed. The paper studies mutexes only.

### Footprint and layout

TTAS: one flag. MCS: one tail pointer plus a per-waiter node of `locked`,
`next` and `resumeHandle`. `TTAS-MCS-N`: one flag plus N tails. The best N in
short-critical-section runs was 8 (4 on 4 cores), since "allocating more
queues than cores provides no benefit". The workload pads its protected data
to cache lines; the paper does not discuss lock padding.

### Portability

Two C++ libraries with different APIs: Argobots (`yield`, `suspend`/`resume`,
no timed sleep) and Boost.Fiber (`yield`, scheduler-level suspend via a stored
handle, `sleep_for`). The paper argues that a lock "that works well for any
library" needs a policy object per library, and that the cohort lock is the
robust default.

### Async and fiber integration

The paper is about fibers, not event loops. Its contribution here is the
`resumeHandle` handshake. A waker on any carrier thread hands a suspended
fiber back to its scheduler through one exchange, without a lock, and without
a lost wakeup when the resume beats the suspend. That is the same contract a
`WaitWord` needs, with "library resume" replaced by "post to the fiber's
loop". Go (asynchronous preemption since 1.14) and Java (virtual threads park,
never spin-yield) are discussed as related designs ([§2, p. 3–4][pdf]).

## Evaluation

Custom harness, because standard benchmark frameworks assume OS threads. Each
point is the median of 50 runs of 10 s, after about 3 s of warm-up, with one
carrier OS thread per core ([§4–5, p. 8–9][pdf]). Two workloads:

- **Cache line increment CS**: increment two padded four-integer structures,
  then context-switch _inside_ the critical section. Parallel work is 100 × (1000
  no-ops + yield).
- **Parallelizable CS**: spawn 12 lightweight threads of 10,000 no-ops each
  inside the critical section and join them. Parallel work is 10 × (1000 no-ops
  - yield).

Findings:

- **Boost.Fiber, 16 cores** (Fig. 1): for the parallelizable critical section,
  **yield-only MCS** beats every other variant, including the library mutex, up
  to about 16 threads, then degrades as yield cost grows. For the short critical
  section, the **spin + yield + suspend** MCS stays stable while yield-only
  degrades. The library mutex (flag + immediate suspend) has slightly better
  throughput there but "consistently exhibits the worst" p99 latency.
- **Argobots, 16 cores** (Fig. 2): all waiting-strategy variants are nearly
  identical.
- **Cohort lock, Boost.Fiber** (Fig. 3–6): for short critical sections,
  `S-TTAS-MCS-8` (`-4` on 4 cores) is "near-optimal" on both throughput and
  latency. For long critical sections on many cores, the yield-only
  `Y-TTAS-MCS` wins, and on 64 cores throughput rises with the number of
  queues, landing between suspend-MCS and yield-MCS.
- **Argobots, 64 cores** (Fig. 7): the most TTAS-like variants win the
  parallelizable critical section. Throughput on the short critical section
  depends on the number of queues, not on the waiting mechanism.
- Overall: "the performance of lock primitives in lightweight threading
  environments [...] often depends more on the underlying library than on the
  lock's design itself" ([§5, p. 9][pdf]).

## Relevance to Sparkles

- **(c) spin policy for fiber waiters.** A fiber must never spin unboundedly on
  a word whose releaser may share its carrier thread. The default for an
  event-horizon fiber waiting on a `WaitWord` is to suspend, with at most a
  short bounded spin when the waker is known to run on another core. A
  yield-only middle stage is a library-specific tuning knob, not a correctness
  requirement.
- **(d) the `resumeHandle` handshake is a `WaitWord` waiter record.** One word
  per waiter, with the states "polling", "parked with handle H" and "woken
  early", resolved by CAS (waiter) against exchange (waker). This avoids both a
  bucket lock and a lost wakeup. Sparkles must also close the CAS→suspend
  window the [warning](#the-suspend-resume-handshake) describes. In a
  completion loop the "suspend" is the fiber yielding to its loop, and the
  loop must tolerate a resume that arrives before the yield completes.
- **(a) the cohort shape fits a thread/fiber split.** A word-sized fast-path
  flag with queued waiters behind it is the structure a 1-byte parking-lot lock
  already has. The paper's evidence is that per-core sub-queues help on NUMA
  but matter less than the waiting policy.
- **(b) no data on condition variables.**

## Strengths

- Identifies a correctness problem (spin deadlock under cooperative
  scheduling) that OS-thread lock studies never face, and a realistic trigger:
  nested parallelism in a critical section.
- A library-neutral, lock-free suspend/resume handshake that plugs into any
  queue lock.
- Measures two libraries, three core counts and lightweight-thread counts from
  1 to 2048, reporting both throughput and p99 latency.

## Weaknesses

- Preprint without peer review. The cited code repository is unavailable, so
  constants (`YIELD_LIMIT`, `SUSPEND_LIMIT`, `SPIN_LIMIT`) and memory orders
  are unknown.
- The suspend handshake as written leaves a CAS→suspend window open, which the
  paper does not discuss.
- Conclusions are qualitative ("near-optimal", "far less intriguing"). Argobots
  results are mostly omitted as indistinguishable.
- Mutex only: no condition variables, no reader/writer locks, no timeouts.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                        | Trade-off                                                                |
| ----------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Spin → yield → suspend with exponential spin                | Each stage costs less than the next mechanism's overhead         | Three constants to tune per library and machine                          |
| No suspension in the MCS `unlock` link-wait or in TTAS      | That wait is short; TTAS has no node to hold a handle            | A TTAS waiter on a busy carrier can only yield                           |
| `resumeHandle` word with `0`/`1` sentinels, CAS vs exchange | Lock-free; a resume before suspend becomes "keep active"         | A window between a successful CAS and the actual suspend                 |
| Cohort `TTAS-MCS-N`: flag fast path, N MCS queues           | TTAS throughput with queue-lock latency; robust across libraries | Barging across queues; N must be tuned (no benefit above the core count) |
| Queue choice by core ID mod N or at random                  | Spreads queue heads; no measured difference                      | Core ID is unstable for migrating lightweight threads                    |

## Sources

- [Skazhenik, Korobenikov, Churbanov, Malakhov & Aksenov, "Basic Lock Algorithms in Lightweight Thread Environments", arXiv:2512.08563, 2025][pdf] ([abstract][abs]) — §1 the cooperative-deadlock motivation; §2 related work (Go and Java lock designs, Argobots and Boost.Fiber mutexes, lock cohorting); §3.1 waiting primitives for OS and lightweight threads; §3.2 the backoff policy, MCS adaptation (Listings 1–2), `TTAS-MCS-N`; §4 benchmark design; §5 results (Fig. 1–7); §6 conclusion.
- Related catalog pages: [`queue-locks`][queue-locks] (MCS, CLH and cohort/NUMA locks for OS threads), [`java-aqs`][java-aqs] (park/unpark permits, the `ReentrantLock` the paper equates with `TTAS-MCS-1`), [`go-sync`][go-sync] (spin-then-park with a runtime semaphore), [`karsten-barghi-2020`][karsten] (an M:N runtime whose waiters suspend rather than spin), [`koenig-2025-combine-and-exchange`][koenig] (a different answer for cooperative tasks: hand the critical section to the unlocker's thread).
- See also [Skazhenik et al. 2026][skazhenik-2026], the Russian-language journal follow-up (Userver, HMCS, a two-socket machine, harness pitfalls).

<!-- References -->

[pdf]: https://arxiv.org/pdf/2512.08563v1
[abs]: https://arxiv.org/abs/2512.08563
[queue-locks]: ./queue-locks.md
[java-aqs]: ./java-aqs.md
[go-sync]: ./go-sync.md
[karsten]: ./karsten-barghi-2020.md
[koenig]: ./koenig-2025-combine-and-exchange.md
[skazhenik-2026]: ./skazhenik-2026-coroutine-sync.md
