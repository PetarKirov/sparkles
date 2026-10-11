# von Behren et al. 2003 — Capriccio: Scalable Threads for Internet Services

"Fix threads" rather than switch to events. Capriccio is a user-level,
cooperatively scheduled POSIX threads library for Linux whose scheduler is an
event loop over `epoll` and Linux AIO, with compiler-inserted linked stacks
and a scheduler that learns the program's blocking points. Its
synchronization story is the one every cooperative runtime starts from — on
one CPU a lock is "a boolean locked/unlocked flag" — and its stated limits
are exactly where a multi-loop runtime has to go further.

|                 |                                                                                                                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**        | paper (SOSP '03)                                                                                                                                                                                       |
| **Year**        | 2003 (October)                                                                                                                                                                                         |
| **Authors**     | Rob von Behren, Jeremy Condit, Feng Zhou, George C. Necula, Eric Brewer (UC Berkeley)                                                                                                                  |
| **Venue**       | Proceedings of the 19th ACM Symposium on Operating Systems Principles (SOSP '03), Bolton Landing, NY, pp. 268–281; [DOI 10.1145/945445.945471][doi]                                                    |
| **Language**    | C (library), CIL-based whole-program source-to-source analysis                                                                                                                                         |
| **License**     | not stated in the paper                                                                                                                                                                                |
| **Platforms**   | Linux on x86: 2.5.70 for microbenchmarks (epoll, AIO, vsyscall), stock 2.4.20 for the web benchmark; built on Edgar Toernig's coroutine library                                                        |
| **Primitive**   | M:1 cooperative user threads behind the POSIX API; blocking I/O intercepted and mapped to `epoll`/AIO; linked stack chunks via call-graph checkpoints; resource-aware scheduling over a blocking graph |
| **Source read** | `capriccio-sosp-2003.pdf` ([project copy][pdf]), all 15 pages                                                                                                                                          |

## Overview

### What it solves

High-concurrency servers moved to events (SEDA) because thread packages did
not scale, at the cost of "stack ripping" and hidden control flow ([§1][pdf]).
The paper's position:

> In this paper, we advocate a different solution: instead of switching to an
> event-based model to achieve high concurrency, we should fix the
> thread-based model. We believe that a modern thread package will be able to
> provide the same benefits as an event system while also offering a better
> programming model for Internet services.

Goals: existing thread APIs, "scalability to hundreds of thousands of
threads", and application-specific flexibility.

### Design philosophy

Decouple logical threads from kernel threads ([§1.1][pdf]): "Kernel threads
are primarily useful for enabling true concurrency via multiple devices, disk
requests, or CPUs. User-level threads are really logical threads that should
provide a clean programming model with useful invariants and semantics." A
user-level package can then exploit cooperative scheduling, new asynchronous
I/O interfaces and compiler support "all without changing application code".

## How it works

### Thread runtime and I/O

- **Context switch** from Toernig's coroutine library, fast "for the common
  case in which threads voluntarily yield, either explicitly or through making
  a blocking I/O call". No pre-emption yet ([§2.2][pdf]).
- **I/O interception**: blocking calls are caught by overriding glibc's
  system-call stubs; internally `epoll` for pollable fds and Linux AIO for
  disk, falling back to `poll()` and a kernel-thread pool for disk.
- **Scheduler** "looks very much like an event-driven application,
  alternately running application threads and checking for new I/O
  completions", hidden behind the thread API, with pluggable schedulers.
- **O(1)** everything except the sleep queue (a linked list).

### Synchronization

The whole synchronization design is one paragraph ([§2.2][pdf]):

> Capriccio takes advantage of cooperative scheduling to improve
> synchronization. At present, Capriccio supports cooperative threading on
> single-CPU machines, in which case inter-thread synchronization primitives
> require only simple checks of a boolean locked/unlocked flag. For cases in
> which multiple kernel threads are involved, Capriccio employs either spin
> locks or optimistic concurrency control primitives, depending on which
> mechanism best fits the situation.

The rationale is in §2.1.2: "In the simplest case of cooperative scheduling
on a single CPU, synchronization is nearly free, since neither user threads
nor the thread scheduler can be interrupted while in a critical section", and
even with pre-emption, user-level threads "do not require kernel crossings
for mutex acquisition or release" — footnoting that "the futexes in recent
Linux kernels allow operations on uncontended mutexes to occur entirely in
user space" but "highly contended mutexes still require kernel crossings".
The authors flag the limit themselves (§2.1.3): "purely user-level
synchronization mechanisms are ineffective in the face of true concurrency
and may lead to starvation", citing scheduler activations.

### Linked stacks

A whole-program weighted call graph (CIL) bounds stack use between
**checkpoints** inserted at call sites: one on every back edge (so every
recursive cycle has one), then more wherever the longest checkpoint-free path
exceeds `MaxPath` ([§3.1–3.2][pdf]). At run time a checkpoint checks whether
the current chunk has room to reach the next checkpoint; if not it links a new
chunk (minimum `MinChunk`) and switches the stack pointer before pushing
arguments, unlinking it to a free list on return. Unbounded external library
calls get either annotated bounds or a shared large chunk. The free chunk list
needs no lock — "Mutual exclusion for accessing the free stack chunk list is
ensured by our cooperative threading approach."

### Resource-aware scheduling and the blocking graph

The scheduler records a **blocking graph**: nodes are blocking points
identified by call chain (a stack backtrace), edges are consecutive blocking
points, annotated with exponentially weighted averages of cycle counts and
resource deltas (memory, file descriptors, stack) ([§4.1–4.2][pdf]). Each node
has its own run queue; nodes are prioritized periodically by predicted
resource effect and picked by stride scheduling — prefer nodes that release a
scarce resource, prefer consumers when it is plentiful — which yields
admission control. The same edge timings expose code that fails to yield
("yield profiling", §4.3): Apache's nonblocking `close()` sometimes took 5 ms,
fixed by yields around the call.

## Analysis

### State word and fast path

A boolean locked/unlocked flag, read and written without atomics because a
cooperative uniprocessor scheduler cannot interleave a critical section. The
measured uncontended lock is 0.04 µs against NPTL's 0.15 µs and
LinuxThreads' 0.14 µs (Table 1), attributed to "no kernel crossings are
involved". (NPTL's uncontended futex path does not enter the kernel either —
the paper's own footnote says so — so the gap is presumably the atomic
read-modify-write and call overhead; the paper does not break it down.)

### Waiting: spin, yield, park

No spinning on one CPU: a thread that finds a lock held yields to the
scheduler (the paper does not detail the waiter queue). With multiple kernel
threads the paper names "spin locks or optimistic concurrency control
primitives" without specifying policy. The real waiting mechanism is the
scheduler's: blocked threads are parked per blocking-graph node and woken by
I/O completions.

### The parking substrate

Per-node run queues in the scheduler plus I/O readiness/completion from
`epoll_wait` and AIO events, harvested "periodically, transferring as many
events as possible on each call" ([§2.6][pdf]). When no thread is runnable
the scheduler issues more `epoll_wait` calls, which is why Capriccio is up to
37% slower than NPTL at very low concurrency (2 tokens, 8 threads).

### Fairness, handoff and starvation

Cooperative: a thread that does not yield starves everyone, mitigated only by
"all of the threads are part of the same application and are therefore
mutually trusting" and by yield profiling (§4.3). Resource-aware scheduling
deliberately reorders threads by blocking point, not arrival. Lock fairness
is not discussed. The related-work section notes scheduler activations could
address "difficult problems like priority inversion and the convoy
phenomenon" ([convoys](./concepts.md#convoys),
[priority inversion](./concepts.md#priority-inversion)).

### Condition variables and predicates

Provided through the POSIX API (the producer–consumer benchmark uses
"condition variables and mutexes"), but no algorithm is described. On one
CPU a condvar is a scheduler queue; nothing more can be read from the paper.

### Footprint and layout

Locks: a flag. Threads: a linked stack starting at a small chunk —
Apache with `MaxPath` = 2 KB and `MinChunk` = 4 KB ran 200 threads in under
8 MB of stack (800 KB initial chunks, 1 MB of 16 KB chunks — a mean peak of
66 — and three 2 MB chunks for external calls) ([§3.6][pdf]). Checkpoints cost
6–27 instructions, ~3–4% overall on Apache. No guard pages.

### Portability

Linux only; depends on glibc ≤ 2.2 stub interception (glibc 2.3 bypasses the
stubs internally, breaking dynamically linked apps), `epoll` and Linux AIO
with `poll()`/thread-pool fallbacks selected by environment variable.

### Async and fiber integration

The design _is_ fibers on an event loop: a POSIX thread that blocks becomes a
parked user thread, and the loop resumes it on an `epoll` or AIO completion.
Locks never interact with the loop because on one CPU they never block in the
kernel. What it does not have — and lists as future work (§7) — is the case
that matters for a multi-loop runtime: M:N threading, where "we can no longer
rely on the cooperative threading model to provide atomicity", and wake-ups
crossing between kernel threads.

## Evaluation

Microbenchmarks: 2 × 2.4 GHz Xeon, 1 GB, Linux 2.5.70, gcc 3.3, glibc 2.3;
Capriccio vs LinuxThreads vs NPTL 0.53 ([§2.3–2.6, Table 1][pdf]).

| Primitive (µs)         | Capriccio | Capriccio, no tracing | LinuxThreads | NPTL |
| ---------------------- | --------- | --------------------- | ------------ | ---- |
| Thread creation        | 21.5      | 21.5                  | 37.9         | 17.7 |
| Thread context switch  | 0.56      | 0.24                  | 0.71         | 0.65 |
| Uncontended mutex lock | 0.04      | 0.04                  | 0.14         | 0.15 |

- **Producer–consumer** over mutexes and condvars (Figure 1): LinuxThreads
  degrades after 20 threads, NPTL after 100 and is unstable beyond 64;
  Capriccio scales to 32K producers and 32K consumers.
- **Pipe token passing** (Figure 2): within 10% of raw `epoll` above 256
  pipes, more than 2× LinuxThreads and NPTL above 1,000 threads, scaling to
  64K threads; 37% slower than NPTL at 2 tokens / 8 threads.
- **Disk**: random 4 KB `O_DIRECT` reads gain from kernel head scheduling like
  kernel threads (Figure 3); with a buffer cache and very low miss rate
  Capriccio reaches only ~50% of NPTL because every AIO request, hit or miss,
  pays a completion event and a separate system call (Figure 4).
- **Linked stacks**: 800 threads each touching a 1 MB stack buffer take
  3.33 s with private stacks and 1.04 s sharing one linked chunk; private
  stacks thrash at 1,000 threads while linked stacks scale linearly to 100,000.
- **Web server** (4 × 500 MHz Pentium, Linux 2.4.20, `poll()` + thread pool,
  SPECweb99-like 3.2 GB file set; Figure 9): Apache 2.0.44 gains ~15% under
  Capriccio; Knot (1,290 lines of threaded C) matches the event-based Haboob.
- **Blocking-graph overhead** (Table 2): edge statistics ~673 cycles per edge
  (<2% for Apache, ~0.1% with 1/20 sampling); stack backtraces ~2,447 cycles,
  ~8% of Apache's and 36% of Knot's execution time.

## Relevance to Sparkles

- **(a)/(c) the cooperative-lock shortcut does not survive multiple loops.**
  Capriccio's 0.04 µs lock is a plain flag because one CPU runs one loop.
  Once loops run on several threads and threads outside any loop share the
  data, `sparkles.base.sync` needs a real atomic word; Capriccio itself defers the multi-CPU case to unspecified spin
  locks and optimistic concurrency, and warns of starvation.
- **(d) parking = scheduler queue, wake = completion.** Blocked user threads
  sit in scheduler queues and are resumed by harvesting `epoll`/AIO
  completions in batches. A `WaitWord` should look the same to the loop: a
  wake from another thread arrives as one more completion in the batch, not a
  separate mechanism.
- **Batch harvesting costs latency at low load.** The 37% low-concurrency
  penalty comes from extra `epoll_wait` calls when nothing is runnable — a
  reminder that a loop's idle path (block in the kernel until any completion,
  including a cross-thread wake) dominates latency when contention is low.
- **Blocking points as identities.** The blocking graph shows the value of
  knowing _where_ a fiber is parked; a `WaitWord` registry that records the
  waiting site (or at least the word) gives the same diagnostics
  (yield-profiling-style stall detection) cheaply.
- **Never block the loop thread.** Yield profiling found 5 ms nonblocking
  `close()` calls stalling all threads; any `sparkles.base.sync` primitive that
  can block in the kernel must not be called from loop-resident fibers without
  a fiber-aware slow path.

## Strengths

- **Threads with event-system performance**: 100K threads, within 10% of raw
  `epoll`, unmodified Apache ~15% faster.
- **Linked stacks** bound by compile-time analysis — small stacks without
  guard pages and without overflow risk, ~3–4% overhead.
- **Resource-aware scheduling** derived automatically from blocking points,
  giving admission control without tuning APIs.
- **Near-free synchronization** on one CPU (0.04 µs uncontended lock).

## Weaknesses

- **Single CPU only**: synchronization's cheapness depends on it; the
  multi-kernel-thread story is one unspecific sentence.
- **No pre-emption**: a thread that fails to yield stalls the system.
- **Fragile interception**: glibc 2.3 bypasses the overridden stubs for
  dynamically linked programs.
- **AIO overhead on cache hits** halves throughput versus NPTL at low miss
  rates.
- **Backtrace cost** (8–36%) for the blocking graph.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                   | Trade-off                                                                     |
| --------------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------- |
| User-level cooperative M:1 threads                  | Cheap switches, scheduler and I/O decoupled from the kernel | One CPU; no pre-emption; starvation if code fails to yield                    |
| Locks as plain flags on one CPU                     | No critical section can be interleaved                      | Breaks under true concurrency; spin locks / OCC otherwise, unspecified        |
| Intercept blocking calls, use `epoll` and Linux AIO | Unmodified POSIX apps get event-loop I/O                    | Extra system calls at low concurrency; AIO cost on cache hits; glibc-specific |
| Linked stacks via call-graph checkpoints            | Small, safe, growable stacks without guard pages            | Whole-program analysis; function pointers and external calls need annotations |
| Blocking graph from run-time backtraces             | Learn stages and resource use automatically for scheduling  | 8–36% backtrace overhead; static analysis proposed as future work             |

## Sources

- [von Behren, Condit, Zhou, Necula & Brewer, "Capriccio: Scalable Threads for Internet Services", SOSP '03][pdf] ([DOI][doi]) — §1 "fix threads"; §1.1 decoupling logical from kernel threads; §2.1 flexibility, performance (synchronization "nearly free", futex footnote) and disadvantages (scheduler activations, starvation); §2.2 implementation (context switches, I/O interception, scheduling, synchronization); §2.3–2.6 microbenchmarks (Table 1, Figures 1–4); §3 linked stacks (Figures 5–7); §4 blocking graph, resource-aware scheduling, yield profiling (Figure 8); §5 web server and admission control (Figure 9, Table 2); §6 related work; §7 future work (M:N, atomicity)
- [Li & Zdancewic 2007][lz] — reuses Capriccio's disk benchmark; replaces linked stacks with heap closures

<!-- References -->

[pdf]: http://capriccio.cs.berkeley.edu/pubs/capriccio-sosp-2003.pdf
[doi]: https://doi.org/10.1145/945445.945471
[lz]: ./li-zdancewic-2007.md
