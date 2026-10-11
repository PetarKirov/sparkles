# Skazhenik et al. 2026 — Performance Evaluation of Synchronization Algorithms in Lightweight Thread Environments in C++

The Russian-language journal companion to the same group's arXiv preprint,
[Skazhenik et al. 2025][s2025]. The waiting mechanism is the same: a pluggable
spin → `yield` → `suspend` policy and a suspend/resume handshake on the
queue-lock node, both described on the 2025 page and not repeated here. This
page records only what the journal article adds: a third fiber library
(Userver), the hierarchical NUMA lock HMCS, a two-socket machine, a
benchmark-harness design with its measurement pitfalls, and a different
workload, in which the algorithm ranking changes from one library to the next.

|                 |                                                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Kind**        | paper (journal article, in Russian with English abstract)                                                                                                                      |
| **Year**        | 2026 (published 2026-02-25; received 2025-06-25, accepted 2026-01-20)                                                                                                          |
| **Authors**     | Taras M. Skazhenik, Vitaly E. Aksenov (ITMO University), Anton A. Malakhov (Neimark University), Andrey V. Churbanov (independent researcher)                                  |
| **Venue**       | Scientific and Technical Journal of Information Technologies, Mechanics and Optics 26(1), pp. 125–134; [DOI 10.17586/2226-1494-2026-26-1-125-134][doi]                         |
| **Language**    | C++ (Argobots, Boost.Fiber, Userver)                                                                                                                                           |
| **License**     | CC BY-NC (article); the `nasl-tools` artifact repository it cites was not reachable on 2026-10-11                                                                              |
| **Platforms**   | 2× Intel Xeon Gold 5220R (2 NUMA nodes, 96 hardware threads); timers given for x86 (`rdtsc`) and ARM (`cntvct_el0`)                                                            |
| **Primitive**   | `BackoffType` (spin → `yield` → `suspend`) plugged into TTAS, MCS and HMCS — the 2025 preprint's mechanism, see [Skazhenik et al. 2025][s2025]                                 |
| **Source read** | `skazhenik-2026-itmo.pdf` — [journal PDF][pdf] ([article page][page]), all 10 pages, read in the Russian original; quotes are the authors' English abstract or our translation |

> [!NOTE]
> **This is not "Design of Mutex and Event Synchronization Primitives for a
> Multithreaded Managed Runtime with Stackful Coroutines".** The DOI
> `10.17586/2226-1494-2026-26-1-125-134` resolves to _Оценка производительности
> алгоритмов синхронизации в средах исполнения с легкими потоками на языке С++_
> ("Performance evaluation of synchronization algorithms in lightweight thread
> environments in C++"). It covers mutexes only — no event primitive and no
> managed runtime. The "Design of Mutex and Event…" title was not found in
> Crossref, OpenAlex, arXiv, the ITMO journal's 2025–2026 issues, or a general
> web search on 2026-10-11, and this page does not describe it.

## Overview

### What it solves

The same problem as the preprint: classic mutexes deadlock under cooperative
scheduling ([English abstract][doi]):

> Moreover, reusing existing code is often infeasible due to the explicit
> marking of context-switching points required by coroutines, their absence may
> lead to deadlocks between lightweight threads.

The journal article frames the contribution as a method plus a testing tool:
"Due to the absence of existing solutions, a dedicated tool was developed for
testing and performance evaluation of the modified mutexes" ([abstract][doi]).

### Design philosophy

As in the preprint: keep each lock algorithm and abstract only the wait, here
as a template parameter `BackoffType` whose one mandatory member is `yield`
(p. 128). In the article's words, the waiting mechanism "acts as an additional
abstraction layer between lightweight threading libraries and mutex
implementations" ([abstract][doi]).

## What the journal article adds

### Userver and a three-library survey

Besides Argobots and Boost.Fiber, the article covers **Userver**, Yandex's
framework built on `Boost.Coroutine2`, "chosen because of its active use in
domestic companies" (p. 127, translated). Its settings are narrower than
Boost.Fiber's because it targets microservices. The survey states the ordering
hazard behind the handshake: in Argobots "a call to resume before suspend leads
to falling asleep, whereas, for example, in Java, in the analogous situation,
suspend will be ignored" (p. 127, translated). The handshake itself is
described on the [2025 page][s2025-handshake].

### HMCS and a two-socket machine

The adapted locks are TTAS, MCS and **HMCS** (hierarchical MCS) plus each
library's own mutex, on two 24-core Xeon Gold 5220R sockets with 96 OS threads
(one per hardware thread), p. 131. HMCS replaces the preprint's cohort lock as
the NUMA-aware entry; the preprint ran on four 16-core sockets.

### The benchmark harness and its pitfalls

Google Benchmark and Catch2 assume OS threads, so the authors built a harness
in which each fiber library is a separate CMake project overriding only
library-specific hooks (p. 129). The measurement traps it documents apply to any
fiber benchmark:

- `std::chrono::high_resolution_clock` was too costly, so the harness reads
  `rdtsc` or `cntvct_el0` directly. But a fiber can migrate between OS threads,
  and so between cores, during a wait, and per-core counters "are not
  synchronized during operation on most NUMA devices" (p. 130, translated), so
  per-acquisition latency percentiles come out wrong.
- Fairness is therefore measured without clocks: a counter incremented in the
  critical section, differenced per fiber between its own acquisitions, shows
  "how many competing threads managed to obtain the lock earlier" (p. 130,
  translated).
- Migration happens only at `yield` and `suspend`, so the harness logs debug
  events there into per-OS-thread arrays and renders them in Google Trace Viewer.
  Thread-local storage itself is wrong for fibers: "the compiler caches the
  access to such variables within a function and cannot track the moment the
  platform thread changes. The lightweight thread migrates but keeps accessing
  the previous value" (p. 131, translated). The fix hides the address behind an
  abstraction the compiler may not cache.

### A cooperative workload

Each loop iteration is lock, critical section, unlock, parallel work, `yield`
(Listing 1). The parallel section is 10 steps of 1000 empty instructions with a
`yield` each; the critical section spawns 12 fibers of 1000 empty instructions,
"simulating parallelization of a processing loop", so an efficient mutex "must
make waiting threads quickly release processor resources" (p. 131, translated).
50 runs per point, up to 10 s each, after a warm-up of about a third of that.

## Analysis

The state word, the spin/yield/park policy, the parking substrate and the
handoff fairness are the preprint's; see [Skazhenik et al. 2025][s2025]. The
article adds no condition variable, no event, and no footprint or portability
discussion beyond the x86/ARM timer code. Only the points where it extends the
preprint are listed below.

- **Waiting: spin, yield, park.** The escalation rule is stated as a principle
  (p. 129, translated): "If the lock will be handed over soon, active waiting is
  most efficient. For medium waits, yielding to the scheduler matters… for long
  waits — for example, when the thread is near the end of the queue — … it is
  more efficient to suspend it", chosen by a counter of failed checks. No
  thresholds are published.
- **Fairness.** The clock-free fairness metric is defined; no fairness numbers
  are reported.
- **Async and fiber integration.** Fibers only; no cross-thread wake into an
  event loop and no OS-level parking.

## Evaluation

Throughput in operations per millisecond against the number of fibers (1–2048),
one panel per library ([Figure, p. 132][pdf]):

| Library     | Y-axis range  | Ranking                                                                                                  |
| ----------- | ------------- | -------------------------------------------------------------------------------------------------------- |
| Argobots    | 0–30 op/ms    | TTAS best; the MCS-based locks next (close to TTAS below the OS-thread count); Argobots' own mutex worst |
| Boost.Fiber | 1–5 op/ms     | TTAS best; MCS and HMCS low, by hypothesis a non-optimal choice of when to suspend                       |
| Userver     | 0.4–1.6 op/ms | TTAS **worst**; HMCS lower at few fibers and improving once a second NUMA node is used, from 24 fibers   |

The authors conclude that no mutex is universally best, "but for each case
separately one can identify a mutex that does not lose to, and mostly
outperforms, the library implementation" (p. 133, translated). Only throughput
is reported; there are no latency, fairness or ARM results.

## Relevance to Sparkles

- **Question (c).** The ranking flips between libraries — TTAS first on
  Argobots and Boost.Fiber, last on Userver — so the spin/yield/suspend
  thresholds for event-horizon fibers must be tuned against event-horizon's own
  scheduler, not borrowed from another runtime.
- **Measuring fibers.** The traps (fibers migrating across unsynchronized
  per-core clocks, the compiler caching thread-local access across a yield)
  apply directly to benchmarking `WaitWord` waits on a multi-threaded loop. The
  clock-free fairness metric is cheap to copy.
- The library mutexes lose to adapted TTAS; see [Seo et al. 2018][argobots] for
  the Argobots mutex's broadcast-on-unlock design.

## Strengths

- Extends the preprint to a third library, a NUMA lock and a two-socket machine.
- Documents fiber-specific measurement pitfalls and a clock-free fairness
  metric.

## Weaknesses

- Short (10 pages) and in Russian; no `BackoffType` code or thresholds, and the
  artifact repository was unreachable.
- One synthetic workload, throughput only; the Boost.Fiber and Userver
  explanations are hypotheses.
- Mutex only, despite the title's "synchronization algorithms".

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                  | Trade-off                                                    |
| -------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------ |
| One harness core, one CMake project per library    | New fiber libraries plug in by overriding hooks            | Results still differ per library and must be re-measured     |
| CPU tick counters instead of `std::chrono`         | `high_resolution_clock` overhead distorted short intervals | Unsynchronized across NUMA nodes once fibers migrate         |
| Fairness as "acquisitions between my acquisitions" | Robust to unsynchronized clocks                            | No latency distribution                                      |
| Workload that spawns fibers inside the lock        | Rewards waiters that free the CPU quickly                  | Rankings may not carry over to other critical-section shapes |

## Sources

- [Skazhenik, Aksenov, Malakhov & Churbanov, "Performance evaluation of synchronization algorithms in lightweight thread environments in C++", Sci. Tech. J. Inf. Technol. Mech. Opt. 26(1), 2026][pdf] ([DOI][doi], [article page][page]) — abstract (Russian and English); library survey including Userver (pp. 126–128); the `BackoffType` method (pp. 128–129); the harness, timing and TLS pitfalls (pp. 129–131); the experiment (pp. 131–132, Figure); conclusion (p. 133)
- [Skazhenik et al. 2025, "Basic Lock Algorithms in Lightweight Thread Environments"][s2025] — the preprint whose mechanism this article reuses
- [Seo et al. 2018, Argobots][argobots] — the threading library and the library mutex measured here
- [Koval et al. 2023, CQS][cqs] — a resume-before-suspend contract that removes the handoff race

<!-- References -->

[doi]: https://doi.org/10.17586/2226-1494-2026-26-1-125-134
[pdf]: https://ntv.elpub.ru/jour/article/viewFile/571/565
[page]: https://ntv.elpub.ru/jour/article/view/571
[s2025]: ./skazhenik-2025-lightweight-locks.md
[s2025-handshake]: ./skazhenik-2025-lightweight-locks.md#the-suspend-resume-handshake
[argobots]: ./seo-2018-argobots.md
[cqs]: ./koval-2023-cqs.md
