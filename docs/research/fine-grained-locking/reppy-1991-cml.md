# Reppy 1991 — CML: A Higher-Order Concurrent Language

Synchronous operations as first-class values. CML makes a potential
rendezvous — "receive on this channel", "this fd is readable", "this time has
passed" — into an `event` value that can be combined (`choose`, `wrap`,
`guard`, `wrapAbort`) _before_ any thread commits to it, and only `sync` makes
it happen. The combinators are the prior art for a select over heterogeneous
synchronization objects; the 2009 parallel implementation (read alongside,
below) is the prior art for running that select across threads with one
claim word per waiter.

|                 |                                                                                                                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (PLDI '91)                                                                                                                                                                                      |
| **Year**        | 1991 (June)                                                                                                                                                                                           |
| **Authors**     | John H. Reppy (Cornell University)                                                                                                                                                                    |
| **Venue**       | Proceedings of the ACM SIGPLAN 1991 Conference on Programming Language Design and Implementation (PLDI '91), pp. 293–305; [DOI 10.1145/113445.113470][doi]                                            |
| **Language**    | Standard ML (SML/NJ 0.67), CML 0.9.3                                                                                                                                                                  |
| **License**     | not stated (academic paper); CML itself was distributed freely by anonymous ftp                                                                                                                       |
| **Platforms**   | SPARCstation 1, Sun 4/490 (SunOS), DECstation 5000/200 (ULTRIX) — uniprocessors                                                                                                                       |
| **Primitive**   | first-class `event` values with `sync`; combinators `choose`, `wrap`, `guard`, `wrapAbort`, `wrapHandler`, `poll`; base events for channels, thread exit, fd readiness, time                          |
| **Source read** | `pldi-cml.pdf` ([author copy][pdf]), all 13 pages; cross-read: Reppy, Russo & Xiao, "Parallel Concurrent ML", ICFP '09 ([author copy][pcml-pdf]) §1–10 for `withNack` and the multiprocessor protocol |

> [!NOTE]
> `withNack` is **not** in the 1991 paper: the 1991 cancellation combinator is `wrapAbort`, which spawns
> an abort thread when the wrapped event is not chosen (§2.4). `withNack`
> (`(unit event -> 'a event) -> 'a event`) replaced it in later CML — it
> appears in the CML signature quoted by Reppy, Russo & Xiao 2009
> ([Figure 3][pcml-pdf]) and in Reppy's book _Concurrent Programming in ML_
> (Cambridge University Press, 1999), which was not accessible and was not
> read. Everything this page says about `withNack` comes from the 2009 paper.

## Overview

### What it solves

The conflict between procedural abstraction and selective communication
([§2, p. 2][pdf]). A client that wraps an RPC protocol in a function
(`fun clientCall x = (send(reqCh, x); accept replyCh)`) has hidden too much:

> If a client blocks on a call to `clientCall` (e.g., if the server is not
> available), then it cannot respond to other communications. The client
> would like to use selective communication in this situation, but cannot,
> because the synchronous aspect of the protocol has been hidden by the
> function abstraction.

A function value is opaque — it can be called, not inspected — so it cannot
take part in a `select`. Something between "a description of a blocking
operation" and "performing it" is needed.

### Design philosophy

Treat synchronous operations exactly as SML treats functions ([§2.1][pdf]):

> Just as SML supports functions as first-class values, CML supports
> synchronous operations as first-class values. These values, called events,
> provide the tools for building new synchronization abstractions.

Table 1 of the paper makes the analogy literal: functions are introduced by
λ-abstraction, eliminated by application, and combined by composition; events
are introduced by `receive`/`transmit`, eliminated by `sync`, and combined by
`choose`/`wrap`. The blocking primitives are then derived, not primitive:
`val accept = sync o receive`, `val send = sync o transmit`.

## How it works

### The event algebra

```sml
val sync     : 'a event -> 'a
val receive  : 'a chan -> 'a event
val transmit : ('a chan * 'a) -> unit event
val choose   : 'a event list -> 'a event
val wrap     : ('a event * ('a -> 'b)) -> 'b event
val guard    : (unit -> 'a event) -> 'a event          (* §2.4 *)
val wrapAbort   : ('a event * (unit -> unit)) -> 'a event
val wrapHandler : ('a event * (exn -> 'a)) -> 'a event
val poll     : 'a event -> 'a option event
```

- **`choose`** is _generalized_ (symmetric) selective communication: a choice
  may mix input and output. If several base events are enabled at once, one is
  "chosen non-deterministically" ([§2.1][pdf]). The buffered-channel example
  (Figure 3) needs exactly this — the buffer thread offers `receive inCh` and
  `transmit(outCh, x)` in one `choose`; with input-only selection (occam's
  `ALT`) `bufferReceive` could not itself be used in a client's selection.
- **`wrap`** attaches a post-synchronization action (the _wrapper_) that runs
  in the synchronizing thread after commit.
- **`guard`** is "the dual of `wrap`": code run at `sync` time, before the
  commit point, which "can include communications" ([§2.4][pdf]). It moves
  the commit point:
  `guard (fn () => (send(reqCh, x); receive replyCh))` commits on the
  _reply_, not the request. `timeout` is
  itself `guard (fn () => waitUntil (add_time (t, currentTime())))`, so the
  deadline is computed when `sync` runs, not when the event is built.
- **`wrapAbort`** is the complement of `wrap`: "if the wrapped event is not
  chosen in a `sync` operation, then a new thread is spawned to evaluate the
  second argument, called the abort function". It lets a non-idempotent server
  learn that a client chose something else.
- **`poll`** builds an always-enabled event returning `SOME v` if the argument
  would have been chosen, else `NONE`.

### Base events beyond channels

The point that matters most for a `WaitWord`: anything that can block is a
base event, so it composes with everything else ([§2.3][pdf]).

```sml
val wait         : thread_id -> unit event   (* thread join *)
val syncOnInput  : int -> unit event         (* fd readable *)
val syncOnOutput : int -> unit event
val syncOnExcept : int -> unit event
val waitUntil    : time -> unit event
val timeout      : time -> unit event
```

The concurrent stream I/O library (§2.5) is built from these, so
`getpasswd` — a `choose` of `wrap (timeout 60s, fn () => NONE)` and
`wrap (input_line std_in, SOME)` — is a password prompt with a timeout:
I/O readiness, a timer and a channel in one selection, with no separate
"select" API.

### Implementation on a uniprocessor

CML is ~1,380 lines of SML over two SML/NJ extensions — first-class
continuations and asynchronous signals — plus a ten-line compiler change so
that `sync` preserves tail recursion ([§4][pdf]). Threads are continuations
(SML/NJ has no run-time stack, so `callcc`/`throw` are constant time);
pre-emption is a timer signal. Without `choose` an event could be just
`'a cont -> 'a` with `sync` = `callcc`; with `choose` it must support
polling, so an event is "a list of base events, with each base event
represented by a polling function, a function to call for immediate
synchronization and a function for blocking". `guard` is a suspension forced
recursively at `sync`; `wrap` of a guard pulls the suspension up one level
(`fun wrap (GUARD g, f) = GUARD (fn() => wrap(g(), f))`).

`wrapAbort` is "the most difficult CML feature to support": with an abort on
a choice of `n` events, every element gets an abort function, one is the
_leader_, and the leader runs the user's abort only after collecting messages
from all the others — so it fires "if, and only if, none of the events was
selected".

### Cross-reference: the Parallel CML protocol

The 1991 `sync` relies on being atomic on a uniprocessor. Reppy, Russo &
Xiao (ICFP '09) give the multiprocessor protocol; it is summarized here
because it is the design the bearing asks about ([§3.2, §5][pcml-pdf]):

1. **Representation.** Each base event is a record of three functions:
   `pollFn` ("is it enabled?"), `doFn` (commit to an enabled event), `blockFn`
   (enqueue a waiter). The single-threaded protocol is _poll all → commit one
   → else block on all_.
2. **One state word per `sync`.** Each dynamic synchronization allocates an
   event-state variable, `WAITING | CLAIMED | SYNCHED`, and passes the same
   variable to every `blockFn`, so the waiter appears on several channel
   queues at once. "A variable may change from `WAITING` to `SYNCHED` at any
   time (once it is made visible to other threads), but a `CLAIMED` variable
   is only changed by its owner."
3. **Commit = CAS.** A partner that finds the waiter in a queue does
   `CAS(b, WAITING, SYNCHED)`; success means it owns the wake-up. A thread
   that is itself mid-`sync` and finds a partner first CASes its _own_ word
   `WAITING → CLAIMED`, then the partner's `WAITING → SYNCHED`, rolling back
   its own to `WAITING` if the partner was `CLAIMED` (spin) or `SYNCHED`
   (try the next). "This protocol is somewhat similar to a two-variable STM
   transaction."
4. **Only one lock at a time.** Each channel has a spin lock protecting its
   queues; the protocol never holds two, avoiding the lock-ordering deadlock
   of `choose(ch1, ch2)` racing `choose(ch2, ch1)`.
5. **Dead entries.** A `SYNCHED` item is dead but stays in the other queues;
   queues are swept on insert when their length passes a threshold reset to
   `max(n + k1, k2 * n)` (`k1 = 10`, `k2 = 1.5`) (§8.3).
6. **`withNack` by bookkeeping outside `sync`.** Following Fluet, nacks are
   write-once condition variables created at `sync` time; an event becomes a
   thunk returning `(cvar list * (cvar list * 'a thunk) evt)`, and after
   commit the losing branches' cvars are signalled (§4).
7. **Callbacks instead of blocking.** The C# port adds `Async(k)`: the same
   poll/commit/block logic, but the continuation passed to `blockFn` is an
   `AsyncCont` whose `Throw` queues a task instead of waking a blocked thread
   (§9.2).

## Analysis

### State word and fast path

In the 1991 design there is no state word: `sync` is atomic because the
whole runtime is a single-threaded continuation scheduler, and the fast path
is the polling phase — if a base event's poll function says it is enabled,
commit immediately without ever enqueuing. The 2009 protocol adds the word:
one `WAITING/CLAIMED/SYNCHED` cell per synchronization, with uncontended
commit a single CAS by the partner. That cell is the "which branch won" flag
any multi-object wait needs, and it is per-_waiter_, not per-object.

### Waiting: spin, yield, park

1991: a thread that cannot commit is parked by enqueuing its continuation on
every base event (the blocking function) and dispatching another thread; no
spinning. Pre-emption by timer signal bounds a thread's run. 2009: the only
spinning is on a partner's `CLAIMED` state, which is transient by
construction (the owner is executing `sync` and will move it to `WAITING`
or `SYNCHED`); §8.4 notes CAS-spinning causes bus traffic and should spin on
plain loads first ([concepts: spinning](./concepts.md#spinning)). Manticore
masks local pre-emption during `sync` so a spin-lock holder is never
pre-empted (§8.1) — the [lock-holder preemption](./concepts.md#lock-holder-preemption)
problem solved by being the scheduler.

### The parking substrate

Waiter records are heap continuations living in **per-object queues** (each
channel has a send queue and a receive queue; each condition variable a
waiting list). One waiter appears in many queues; the shared state word
arbitrates. The thread's "parking" is just the scheduler not running its
continuation. This is the nsync model — one waiter, many queue entries
pointing at it ([`nsync_wait_n`](./nsync.md#async-and-fiber-integration)) —
but with the claim word instead of a semaphore.

### Fairness, handoff and starvation

Choice is "non-deterministic" in 1991. The 2009 reference `sync` is a single
pass over the base events and so "implements a biased choice that always
favors the left alternative over the right"; the authors note the structure
allows priorities or fairness but do not describe it. Channel queues are
FIFO, so among waiters on one channel service is in arrival order. Wake-up is
a **direct handoff** of the value — the partner throws the message to the
waiter's resume continuation — so there is no
[barging](./concepts.md#barging-and-handoff) and no
[spurious wakeup](./concepts.md#spurious-wakeups) by construction.

### Condition variables and predicates

CML has no mutexes, so no monitor-style condvar. The 2009 implementation has
an internal write-once `cvar` (wait blocks until signalled; once signalled
never blocks again) used for `withNack`, and `waitEvt` on it is just another
base event. Predicates are expressed as `guard` (compute at `sync` time),
the `always`/`never` base events of later CML ([Figure 3][pcml-pdf]) for
satisfiable/unsatisfiable conditions, and the "thread encapsulates state" idiom — the buffer thread of
Figure 3 plays "the same role that monitors do in some shared-memory
concurrent languages".

### Footprint and layout

Threads are heap objects: "tens of bytes compared to kilo-bytes for PML"
([§6][pdf]); channels and blocked threads are ordinary heap values, so a
buffer thread that becomes unreachable is garbage-collected along with its
channels. Each `sync` allocates (the state word, queue items, in 2009 the
nack cvars) — there is no attempt at an allocation-free wait.

### Portability

Pure SML on SML/NJ (four architectures at the time). Fd readiness is the
runtime's job: `syncOnInput` and friends are base events the scheduler
services. The 2009 C# port shows the protocol needs only CAS, spin locks and
some way to suspend and resume a thread (a monitor-based `SyncCont<T>` per
blocked thread).

### Async and fiber integration

This is the paper's subject: CML threads _are_ fibers, and the scheduler
dispatches them over I/O readiness, timers and channel rendezvous uniformly.
Two lessons transfer to an event loop. First, I/O readiness and time are base
events in the same algebra as channel rendezvous — one `sync` covers both, so
a loop does not need a separate select for "word changed" versus "fd ready"
versus "timer fired". Second, the 2009 `Async(k)` shows the cross-thread wake
path: the waker's CAS on the state word decides ownership, then the
continuation it resumes can be a "post a task" rather than "wake a blocked
thread". That is exactly the shape a `WaitWord` wake from a foreign thread to a
loop-resident fiber needs.

## Evaluation

Each operation run 100,000 times (loops unrolled ten times) on three
uniprocessors; times in µs ([Tables 2–6][pdf]):

| Operation (CPU / GC µs) | SPARCstation 1 | Sun 4/490 | DECstation 5000/200 |
| ----------------------- | -------------- | --------- | ------------------- |
| Null function call      | 1.9 / 0        | 1.0 / 0   | 0.7 / 0             |
| Thread switch           | 26 / 8         | 13 / 4    | 8 / 7               |
| Thread spawn + exit     | 85 / 13        | 38 / 7    | 22 / 12             |
| `send`/`accept`         | 94 / 19        | 45 / 12   | 27 / 18             |
| Event rendezvous        | 163 / 24       | 77 / 14   | 44 / 22             |

- **Cost of abstraction** (Table 5): event rendezvous costs 1.62–1.73× plain
  rendezvous; event RPC 1.25–1.27× plain RPC.
- **Versus a C thread library** (µSystem, Table 6): task switch 131 µs
  (SPARC 1) vs CML's 26; send/receive 292 µs vs 94 — "CML provides as good or
  better performance" despite a higher-level model with selective
  communication.
- A CML thread switch is ~100 instructions; the measured SPARC 1 time implies
  ~5 CPI, blamed on its write-through cache. GC overhead comes from SML/NJ's
  store list hammered by "a small number of very frequently updated objects:
  the thread ready queue, current thread pointer and channel waiting queues".

Parallel CML 2009 ([§10][pcml-pdf]): the Manticore parallel protocol on one
processor is ~2.5× slower than single-threaded CML (ping-pong 697,800 vs
1,608,000 msg/s), and cross-processor ping-pong drops to 271,400 msg/s; eight
independent ping-pong pairs reach 1,000,000 msg/s on 8 processors (1.38× the
1-processor protocol).

## Relevance to Sparkles

- **(d) the `WaitWord` registry.** The `pollFn`/`doFn`/`blockFn` triple is the
  minimal interface a waitable needs to join a multi-object wait, and it
  matches nsync's `ready_time`/`enqueue`/`dequeue`. The 2009 one-claim-word
  protocol is the arbitration a fiber waiting on several words needs: register
  the fiber in each word's waiter list with a shared `WAITING` cell; a waker
  wins with `CAS(WAITING → SYNCHED)` and then posts the fiber's resumption to
  its loop. Losers find `SYNCHED` and skip — no global lock, no
  lock-ordering problem.
- **Dead entries must be reaped.** A multi-registration leaves stale entries
  behind in every losing queue; Parallel CML's threshold sweep (or explicit
  dequeue on wake, as nsync does) must be part of the registry design, or a
  loop re-waiting on `(hot, cold)` leaks entries on `cold`.
- **Timeouts and cancellation compose as events.** `timeout` as a `guard`
  over an absolute deadline, and `withNack` as "signal the losers" give a
  model for a `WaitWord` API where a deadline or a cancellation token is just
  another branch of the choice rather than a parameter on every call.
- **The post-commit action runs in the waiter.** `wrap` runs after commit in
  the synchronizing thread, so the waker does minimal work (one CAS, one
  enqueue). That keeps the wake path safe to call from any thread, which is
  what a cross-thread → loop wake requires.
- Not a design for (a)–(c): CML has no mutex word, no condvar over a mutex and
  no spin policy beyond the transient `CLAIMED` state.

## Strengths

- **Composability**: protocols are packaged as values without hiding their
  synchronous nature; `choose` sees through any number of `wrap`/`guard`
  layers.
- **One algebra for channels, joins, fd readiness and time** — no separate
  select/poll API.
- **Moves the commit point** (`guard`) and **notifies the losers**
  (`wrapAbort`, later `withNack`), which is what makes RPC-with-timeout
  correct.
- **Cheap**: abstraction costs 1.25–1.73× a raw rendezvous and still beat a C
  thread library of its day.
- The later parallel protocol needs only CAS and per-object spin locks, and
  was model-checked.

## Weaknesses

- **Uniprocessor-only in 1991**: `sync` atomicity comes from the scheduler;
  the parallel version took 18 years and costs ~2.5×.
- **Allocation per `sync`** (state, queue items, guards' closures) — natural
  under a GC, a cost in `@nogc` code.
- **`wrapAbort` is expensive and awkward** (a thread per losing branch plus a
  leader); it was superseded by `withNack`.
- **Biased or unspecified choice fairness**; no starvation bound.
- **Stale queue entries** after a multi-way block must be swept.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                               | Trade-off                                                              |
| --------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Synchronous operations as first-class `event` values      | Abstraction without losing participation in selective communication     | An extra layer: event rendezvous 1.6–1.7× a direct one                 |
| Generalized `choose` (input and output)                   | Buffered channels and servers need to offer both sides                  | Harder to implement on multiprocessors (needs the claim protocol)      |
| `guard` runs pre-commit code at `sync` time               | Lets the commit point be any message in a protocol; deadlines are fresh | Guard side effects happen even if another branch wins                  |
| `wrapAbort` spawns abort threads for losers               | Non-idempotent servers must learn they were not chosen                  | A thread per branch plus a leader; replaced by `withNack`              |
| fd readiness and time as base events                      | One `sync` covers I/O, timers and channels                              | The runtime must own the I/O multiplexer                               |
| (2009) One `WAITING/CLAIMED/SYNCHED` word per `sync`, CAS | Lock-free arbitration over many queues; one channel lock at a time      | Two-word "transaction" with rollback; dead queue entries need sweeping |

## Sources

- [Reppy, "CML: A Higher-order Concurrent Language", PLDI '91][pdf] ([DOI][doi]) — §1 motivation; §2 primitives and the abstraction/selection conflict; §2.1 events, Table 1, Figure 2; §2.2 buffered channels (Figure 3); §2.3 `wait`, `syncOnInput`/`Output`/`Except`, `waitUntil`, `timeout`, `poll`; §2.4 `guard`, `wrapAbort`, `wrapHandler`; §2.5 stream I/O; §3 eXene and distributed ML; §4 implementation (continuations, poll/commit/block functions, `wrapAbort` leader); §5 Tables 2–6; §6 related work and footprint
- [Reppy, Russo & Xiao, "Parallel Concurrent ML", ICFP '09][pcml-pdf] ([DOI][pcml-doi]) — §2 CML API with `withNack`; §3 single-threaded protocol (`pollFn`/`doFn`/`blockFn`); §4–5 the optimistic `WAITING/CLAIMED/SYNCHED` protocol; §6 reference code; §8 locally-atomic `sync`, affinity, dead-entry sweeping, bus traffic; §9 Manticore and C# (`SyncCont`, `AsyncCont`) ports; §10 benchmarks
- [nsync][nsync] — `nsync_wait_n`, the C analogue of a select over synchronization objects
- [Ziarek, Sivaramakrishnan & Jagannathan 2011][ziarek] — asynchronous events built on this algebra
- [Li & Zdancewic 2007][lz] — compares itself to CML: "its thread scheduler is still hidden from the programmer"

<!-- References -->

[pdf]: http://people.cs.uchicago.edu/~jhr/papers/1991/pldi-cml.pdf
[doi]: https://doi.org/10.1145/113445.113470
[pcml-pdf]: http://people.cs.uchicago.edu/~jhr/papers/2009/icfp-parallel-cml.pdf
[pcml-doi]: https://doi.org/10.1145/1596550.1596588
[nsync]: ./nsync.md
[ziarek]: ./ziarek-2011-async-events.md
[lz]: ./li-zdancewic-2007.md
