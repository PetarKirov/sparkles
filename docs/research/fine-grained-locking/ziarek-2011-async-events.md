# Ziarek, Sivaramakrishnan & Jagannathan 2011 — Composable Asynchronous Events

CML events, split in two. A synchronous event is "act, then wait for the
partner"; an asynchronous event performs the _act_ (deposit a value or a
receive request on the channel, in order) in the caller and runs the _wait_
and everything after it in an implicit new thread once a partner consumes it.
Combinators then address the two halves separately: `sWrap` for what runs
after the act (post-creation), `aWrap` for what runs after the partner
(post-consumption). The act/wait split is the shape of any "register now,
resume later" wait.

|                 |                                                                                                                                                                                       |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kind**        | paper (PLDI '11)                                                                                                                                                                      |
| **Year**        | 2011 (June)                                                                                                                                                                           |
| **Authors**     | Lukasz Ziarek, KC Sivaramakrishnan, Suresh Jagannathan (Purdue University)                                                                                                            |
| **Venue**       | PLDI '11, San Jose, pp. 628–639; [DOI 10.1145/1993498.1993572][doi]; full semantics in Purdue TR-11-09                                                                                |
| **Language**    | Standard ML / CML, implemented in Multi-MLton (~4K LOC of ML)                                                                                                                         |
| **License**     | not stated (academic paper); Multi-MLton is open source                                                                                                                               |
| **Platforms**   | Multi-MLton on an 8-socket, 16-core AMD Opteron 865 server, 32 GB                                                                                                                     |
| **Primitive**   | `('a, 'b) AEvent` with `aSendEvt`, `aRecvEvt`, `aSync`; combinators `sWrap`, `aWrap`, `aGuard`, `aChoose`, `sChoose`, `aTrans`, `sTrans`; derived `callbackEvt`, mailboxes, multicast |
| **Source read** | `pldi11.pdf` ([author copy][pdf]), all 12 pages                                                                                                                                       |

> [!NOTE]
> The reading list this survey started from attributed the paper to
> "Chaudhuri & Suresh". Its authors are **Lukasz Ziarek, KC Sivaramakrishnan
> and Suresh Jagannathan**. Avik Chaudhuri wrote a different CML
> paper — "A Concurrent ML Library in Concurrent Haskell", ICFP 2009 — which
> this paper cites as reference [4].

## Overview

### What it solves

Encoding asynchrony with an explicit thread inside an event breaks both
ordering and composition ([§3][pdf]). The naïve
`asyncEvt evt = wrap(alwaysEvt(), fn () => spawn(sync(evt)))` gives no
ordering — two successive `asend`s on one channel may be received in either
order — and hides the spawned thread, so a client cannot extend what happens
after the message is consumed:

> The heart of the problem is a dichotomy in language abstractions;
> asynchrony is fundamentally expressed using distinct threads of control,
> yet composablity is achieved through event abstractions that are
> thread-unaware.

### Design philosophy

Make the two temporally distinct halves of an asynchronous operation
first-class and separately extensible ([§1][pdf]): "post-creation actions —
these are actions that must be executed after an asynchronous operation has
been initiated", and "post-consumption actions — these define actions that
must be executed only after the effect of an asynchronous operation has been
witnessed". Three goals: uniform composition of pre/post-creation and
consumption actions; "sensible visibility and ordering guarantees"; and
protocols agnostic to synchrony, so synchronous and asynchronous events share
ordinary CML channels.

## How it works

### Base asynchronous events

```sml
aSendEvt : 'a chan * 'a -> (unit, unit) AEvent
aRecvEvt : 'a chan -> (unit, 'a) AEvent
aSync    : ('a, 'b) AEvent -> 'a
```

The first type parameter is the result of the post-creation part (returned
to the `aSync` caller); the second is the result of the post-consumption part
(available only to post-consumption actions) ([§4][pdf]).

- **`aSync (aSendEvt (c, v))`** places `v` on `c` and returns at once; an
  implicit thread runs any post-consumption actions when a receiver takes
  `v`.
- **`aSync (aRecvEvt c)`** does not return a value: it "enqueues the
  receiving action on the channel" and returns `unit`. Unlike a non-blocking
  poll, it _deposits itself_, so "successive asynchronous receives are
  guaranteed to receive data from a matching send in the order in which they
  were synchronized".
- Ordering: "successive communication operations performed by the same thread
  get witnessed in the order in which they were issued".

### Combinators

```sml
sWrap   : ('a, 'b) AEvent * ('a -> 'c) -> ('c, 'b) AEvent   (* post-creation *)
aWrap   : ('a, 'b) AEvent * ('b -> 'c) -> ('a, 'c) AEvent   (* post-consumption *)
aGuard  : (unit -> ('a, 'b) AEvent) -> ('a, 'b) AEvent
aChoose : ('a, 'b) AEvent list -> ('a, 'b) AEvent
sChoose : ('a, 'b) AEvent list -> ('a, 'b) AEvent
aTrans  : ('a, 'b) AEvent -> 'a Event
sTrans  : 'a Event -> (unit, 'a) AEvent
```

`sWrap` and `aWrap` commute. `aChoose` picks among asynchronous events
immediately (they are all "active", since none blocks); `sChoose` blocks
until one base event is consumed. `aTrans` hides the asynchronous half so an
`AEvent` can join an ordinary `choose`, with
`choose[aTrans e1, aTrans e2] ≡ aChoose[e1, e2]`.

A **callback** is built from both wraps ([§4.1, Figure 6][pdf]):

```sml
fun callbackEvt (ev, f) = aGuard (fn () =>
  let val clocal = channel ()
  in sWrap (aWrap (ev, fn x => (aSync (aSendEvt (clocal, x)); x)),
            fn _ => wrap (recvEvt clocal, f))
  end)
```

`aSync`-ing it performs `ev`'s act and returns a new synchronous event; that
event becomes enabled only after `ev` has been consumed, and `f` runs in
whichever thread syncs on it. The authors contrast it with `aWrap`, which
always runs in the implicit thread.

### Semantics: act and wait

The formal core ([§5, Figures 8–9][pdf]) splits every message part into two
primitives: `sendAct(c, v)` / `recvAct(c)` place the action on the channel
(or match a waiting partner), and `sendWait` / `recvWait` block until the
message identifier `m` has been matched. A synchronous send is
`sendWait ∘ sendAct(c, v)` executed by one thread; an asynchronous send is the
pair `{sendAct(c, v), sendWait}` where the second component runs in a fresh
thread created by `sync` (rule `SyncEvent`). A global communication map `Δ`
records, per message id, whether its act has been matched and with what
value. Each channel holds a FIFO of send acts or of receive acts, never both,
which is what gives the ordering guarantee.

## Analysis

### State word and fast path

Not a lock paper; there is no lock word. The analogue is the per-message
entry in the communication map `Δ`: a message id that goes from "acted" to
"matched with value `v`", which the wait half blocks on. The fast path of an
asynchronous send is constant work in the caller — deposit and return — with
the wait deferred to another thread.

### Waiting: spin, yield, park

The waiting half is always parked in an implicit thread (a Multi-MLton
lightweight thread), never spun. The synchronizing thread itself never waits
for an asynchronous event's partner. `sChoose` is the one combinator that
blocks the caller, and the paper notes transactional events could give a
non-blocking `sChoose` with the same semantics.

### The parking substrate

Waiters are queue entries on ordinary CML channels — a channel's FIFO of
pending send or receive acts — plus the implicit thread that will run the
post-consumption actions. The implementation follows the semantics and
reuses CML channels, so the parking substrate is CML's (see
[Reppy 1991 § parallel protocol](./reppy-1991-cml.md#cross-reference-the-parallel-cml-protocol)).

### Fairness, handoff and starvation

FIFO per channel and per issuing thread is the paper's ordering contract;
`aChoose` chooses "with equal probability" among events. No starvation
analysis.

### Condition variables and predicates

Does not apply directly. `alwaysEvt`/`never` (and `aAlwaysEvt`/`aNever`
built by `sTrans`) encode satisfiable/unsatisfiable conditions, and
`callbackEvt` is effectively a one-shot condition: an event that becomes
enabled once another operation has completed. The logging example uses it as
"wait until the log has received the fatal error, then flush and exit"
([§6][pdf]).

### Footprint and layout

Each asynchronous event with post-consumption actions creates an implicit
thread when consumed; callbacks allocate a local channel per `aSync` (moved
under `aGuard` so unsynchronized events allocate nothing). Everything is
GC-managed. The mailbox rewrite shrank from 240 to 70 lines and multicast
from 87 to 60.

### Portability

Multi-MLton only; no OS primitive is involved.

### Async and fiber integration

This is the paper's subject at the language level: a thread can start an
operation, keep running, and attach work that runs after a partner completes
it — exactly a fiber issuing a submission on a completion-based loop and
attaching a continuation. The I/O library of the case study is "structured
around callback events ... operating over I/O resource servers", with every
I/O request translated into callback events ([§6][pdf]).

## Evaluation

Swerve, a 16K-line CML web server, on Multi-MLton; AMD Opteron 865,
8 processors × 2 cores, 32 GB ([§6.1, Table 1][pdf]):

| Module            | LOC    | LOC modified | Improvement |
| ----------------- | ------ | ------------ | ----------- |
| Listener          | 1,188  | 11           | 2.15×       |
| File Processor    | 2,519  | 35           | 19.23×      |
| Network Processor | 2,456  | 25           | 24.8×       |
| Timeout Manager   | 360    | 15           | 4.25×       |
| Swerve (overall)  | 16,000 | 103          | 4.7×        |

- Overall: 4.7× throughput and a 15× reduction in client-observed latency
  for 103 changed lines; throughput within 10% of Apache 2.2.15 at up to 1,000
  concurrent connections and 2,000 requests/s (measured with `httperf`).
- Mailboxes rebuilt on asynchronous events: 52% faster on synthetic
  producer/consumer stress tests; multicast channels ~19% faster ([§4.1][pdf]).
- The gains come mostly from removing lock-step file/network I/O, not from a
  cheaper primitive; no per-operation cost of `aSync` is reported.

## Relevance to Sparkles

- **(d) act/wait is the `WaitWord` split.** Registering a fiber on a word
  (the act: enqueue a waiter record, possibly submit a `FUTEX_WAIT` SQE) and
  resuming it when woken (the wait) are separate steps run by different
  parties. The paper's ordering rule — acts by one thread are matched in issue
  order because they are appended to a FIFO at act time — is the property a
  registry gets by appending waiters on registration rather than on park.
- **Post-consumption actions run on the completer's side.** `aWrap`'s
  implicit thread is the analogue of a completion handler: the waker must not
  run user code in its own context. A cross-thread `WaitWord` wake should only
  hand the continuation to the owning loop, the same discipline as the
  [CML 2009 `Async`](./reppy-1991-cml.md#cross-reference-the-parallel-cml-protocol)
  path.
- **Callbacks as first-class waitables.** `callbackEvt` turns "this async
  operation finished" into an ordinary event other code can `sync` on or put
  in a `choose`. A `WaitWord` that a fiber can select together with I/O
  completions and timeouts is the same move.
- No bearing on (a)–(c).

## Strengths

- **Extends CML's composability to asynchrony** without new channel types;
  synchronous and asynchronous operations interoperate on one channel.
- **Ordering guarantees independent of the scheduler.**
- Formal operational semantics (full version in TR-11-09).
- Large, cheap wins in a real server: 4.7× for 103 changed lines.

## Weaknesses

- **An implicit thread per consumed event with post-consumption actions** —
  cheap in Multi-MLton, a real cost elsewhere.
- **No microbenchmarks** of `aSync` or of the underlying channel protocol;
  speedups are application-level.
- `sChoose` blocks; non-blocking choice is left to future work.
- Language-level only: says nothing about how the runtime parks, wakes or
  arbitrates across cores.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                      | Trade-off                                                |
| -------------------------------------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------- |
| Split each communication into act and wait                     | Asynchrony = performing the two in different threads           | Needs a message-id map (`Δ`) to pair them                |
| Two wraps: `sWrap` (post-creation), `aWrap` (post-consumption) | Clients can extend either half of a hidden protocol            | Two result types on every `AEvent`                       |
| Asynchronous receive deposits itself on the channel            | Ordered asynchronous buffers and parallel packetizing for free | A receive that is never matched stays queued             |
| Implicit thread runs post-consumption actions                  | The issuing thread never blocks                                | Thread creation per consumption                          |
| `aTrans`/`sTrans` between `AEvent` and `Event`                 | Mix synchronous and asynchronous events in one `choose`        | `aTrans` hides post-consumption actions from the chooser |

## Sources

- [Ziarek, Sivaramakrishnan & Jagannathan, "Composable Asynchronous Events", PLDI '11][pdf] ([DOI][doi]) — §1 post-creation vs post-consumption; §2 CML background (Figure 1); §3 why thread-encoded asynchrony fails (Figures 2–3); §4 `aSendEvt`/`aRecvEvt`/`aSync` (Figures 4–5); §4.1 combinators, `callbackEvt` (Figure 6), `aChoose`/`sChoose` (Figure 7), `aTrans`/`sTrans`, mailboxes and multicast; §5 semantics (Figures 8–9); §6 Swerve case study (Figure 10, Table 1); §7 related work
- [Reppy 1991, CML][cml] — the synchronous event algebra this extends, and the 2009 parallel protocol
- [Li & Zdancewic 2007][lz] — cited by this paper as the reactive/event-loop alternative

<!-- References -->

[pdf]: https://www.cs.purdue.edu/homes/suresh/papers/pldi11.pdf
[doi]: https://doi.org/10.1145/1993498.1993572
[cml]: ./reppy-1991-cml.md
[lz]: ./li-zdancewic-2007.md
