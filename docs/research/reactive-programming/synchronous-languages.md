# Synchronous reactive languages: Esterel and Céu (Esterel, Céu, HipHop.js)

The imperative synchronous languages: programs are sequential threads of control that `await` events, run in parallel with `||`/`par`, and are killed lexically by `abort`/`watching`, all under the hypothesis that a reaction takes zero logical time.

| Field             | Value                                                                                                                                                                                     |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Esterel (standalone, compiled to C or circuits); Céu (compiled to C via a Lua compiler); HipHop.js (a JavaScript DSL)                                                                     |
| License           | Céu: MIT ([`LICENSE`][ceu-license]); Esterel v5: academic distribution (INRIA / Ecole des Mines); HipHop.js: license file present, GitHub reports `NOASSERTION`                           |
| Repository        | [ceu-lang/ceu][ceu-repo] (surveyed at `5e0c8d3`, 2019-07-17); [manuel-serrano/hiphop][hh-repo] (at `7236e0a`, 2026-11-20); [atmos-lang/atmos][atmos-repo] (Céu's successor, at `a06998a`) |
| Documentation     | [Esterel v5 Language Primer][primer] (v5.91, 2000-06-05); [Céu manual v0.30][ceu-manual]; HipHop.js docs at `hop.inria.fr/hiphop` (unreachable)                                           |
| Category          | Imperative synchronous language: control-flow reactivity, not dataflow                                                                                                                    |
| Versions surveyed | Esterel v5.91; Céu v0.30 (manual) at the repository head; HipHop.js at master                                                                                                             |
| Core abstraction  | The **instant** (Esterel) / **reaction chain** (Céu): one atomic, run-to-completion step of all awakened **trails** in response to one input event                                        |

> [!NOTE]
> This page covers the _imperative_ synchronous family. The dataflow synchronous languages (Lustre, Signal, Lucid Synchrone) belong to the same school but match the signal/FRP deep-dives ([Sodium][sodium], [Elm][elm]) more closely. They are not surveyed here.

---

## Overview

### What it solves

The worked pipeline in this survey is a control problem, not a data problem: _wait_ for a keystroke, _wait_ some milliseconds unless another keystroke comes first, _run_ a job unless another keystroke or a toggle kills it. Dataflow libraries ([RxJS][rxjs], [Kotlin Flow][kotlin-flow]) express this as an operator chain (`debounceTime` → `switchMap`). Synchronous languages express it as a program text whose **lexical structure is the state machine**. Berry's ABRO example is the canonical demonstration. The specification "emit `O` as soon as `A` and `B` have occurred; reset each time `R` occurs" compiles to an automaton whose states grow as 2ⁿ in the number of awaited signals, yet the program stays three lines ([primer][primer] §3.1.3):

```text
module ABRO:
input A, B, R;
output O;
loop
   [ await A || await B ];
   emit O
each R
end module
```

The primer calls Mealy machines "in no way good programs" and names the five ingredients of the Esterel version: "delay, signal emission, sequencing, concurrency, and abortion". The worked pipeline uses exactly these five.

### Design philosophy

The **synchronous hypothesis** (Berry's _perfect synchrony_) says that a program reacts to an input event in zero logical time, so its outputs belong to the same instant as the input ([primer][primer] §3.1.1):

> _"the output part of an event occurs at the same logical time as the input: only bookkeeping actions are performed in a reaction, and such actions should not consume logical input time. This model is called the perfectly synchronous or zero delay model."_

Céu restates it for software trails ([`synchronous_execution_model.md`][ceu-sync]):

> _"The synchronous execution model of Céu is based on the hypothesis that reaction chains run *infinitely faster* in comparison to the rate of input events. … In practice, if a new input event occurs while a reaction chain is running (step 2), it is enqueued to run in the next reaction."_

Determinism is the second axiom. Esterel's primer states that "reactivity and determinism are the minimal requirements a program should obey" (§5.1.1). Céu gets determinism by scheduling trails in source order: _"When multiple trails are active at a logical time … Céu schedules them in the order they appear in the program text. This policy is arbitrary, but provides a priority scheme for trails, and also ensures deterministic and reproducible execution"_ ([`synchronous_execution_model.md`][ceu-sync]).

Céu calls its own position _Structured Synchronous Reactive Programming_ ([overview][ceu-overview]): _"Reactive: code executes in reactions to events. Structured: code uses structured control-flow mechanisms, such as `spawn` and `await` … Synchronous: event reactions run atomically and to completion on each line of execution."_ This makes Céu the synchronous-language sibling of the [structured coroutines][coroutines] surveyed elsewhere.

---

## How it works

### Esterel: signals, instants, preemption

An Esterel program reacts in discrete **instants**. In each instant, every signal is either _present_ or _absent_ ("a signal is present if and only if it is emitted", §5.1.1), and a valued signal `S` exposes its value as `?S`. The kernel statements are:

| Statement                       | Meaning (primer section)                                                                                                                                           |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `emit S` / `emit S(v)`          | Make `S` present in the current instant, broadcast to all threads                                                                                                  |
| `present S then p else q end`   | Test `S` in the current instant                                                                                                                                    |
| `await S` / `await immediate S` | Pause until a _later_ instant where `S` is present (the `immediate` form also accepts the current instant); `await 3 Meter` counts occurrences (§4.7.9)            |
| `p ‖ q` (written `\|\|`)        | Synchronous parallel; terminates when both branches do                                                                                                             |
| `abort p when S`                | **Strong preemption**: "the body does not receive the control at abortion time" (§4.7.10)                                                                          |
| `weak abort p when S`           | **Weak preemption**: "the body receives the control for a last time at abortion time … (p has rights to its 'last wills')" (§4.7.10)                               |
| `suspend p when S`              | Freeze `p` in each instant where `S` is present: "Abortion violently preempts … like ^C … Suspension has a milder action, like ^Z" (§4.7.12)                       |
| `loop p each S`, `every S do p` | Restart `p` on every `S`. `every S do p end` "is actually not a primitive statement, but an abbreviation for" `await S; loop abort p; halt when S end loop` (§3.6) |
| `exec T(...) return R`          | Run an external **task** asynchronously; `R` is its return signal (§4.7.17)                                                                                        |

Because signal status is decided _within_ an instant, a program can contradict itself. `present O else emit O end` is **non-reactive** (no consistent status for `O`), and `present O then emit O end` is **non-deterministic** (two consistent statuses). The compiler rejects both through **constructive causality** analysis (primer ch. 5): a program is accepted only if every signal status can be derived by forward propagation of facts, never by guessing. This compile-time causality check has no counterpart in any library-level reactive system in this survey. It is the price of instantaneous broadcast with same-instant reaction to absence.

### Céu: trails, reaction chains, lexical abortion

Céu removes Esterel's same-instant absence test and the causality problem that comes with it. An `await` only wakes on a _future_ occurrence. Internal `emit` is a stack-based nested reaction ([`internal_reactions.md`][ceu-internal]), not a fixpoint. The execution model has four steps ([`synchronous_execution_model.md`][ceu-sync]):

1. The boot reaction starts the program in a single trail.
2. "Active trails, one after another, execute until they await or terminate. This step is named a _reaction chain_, and always runs in bounded time."
3. The program goes idle.
4. "On the occurrence of a new input event, _all_ trails awaiting that event awake." Then go to step 2.

Parallel composition supports _"awaiting in parallel, rather than executing in parallel"_ ([`parallel_compositions_and_abortion.md`][ceu-par-abort]). There are three rejoin policies: `par/and` (all), `par/or` (_"rejoins after any trail in parallel terminates, aborting all other trails automatically"_), and `par` (never). `watching e do body end` is sugar for `par/or do await e; with body end` ([`parallel_compositions.md`][ceu-par]). Bounded reaction time is enforced statically: _"Céu requires every path inside the body of a `loop` statement to contain at least one `await` or `break` statement"_ ([`bounded_execution.md`][ceu-bounded]). Unbounded computation goes to [`async`](#concurrency-and-cancellation).

Abortion runs **finalizers**, and the compiler requires them where C resources are involved: _"A finalization statement unconditionally executes a series of statements when its associated block terminates or is aborted"_. A native call that receives or returns a pointer _"does not compile without the `finalize` statement"_ ([`c_integration.md`][ceu-cint]). The SenSys 2013 paper names the design goal: _"The finalization mechanism is fundamental to preserve the orthogonality of the par/or construct, i.e., an aborted trail does not require clean up code outside it."_ It also calls `par/or` _"an orthogonal preemption primitive"_, adding that _"traditional (asynchronous) multi-threaded languages cannot express thread abortion safely"_ ([Sant'Anna et al. 2013][sensys13]).

### HipHop.js: Esterel embedded in JavaScript

HipHop.js (Berry & Serrano, PLDI 2020) is _"a synchronous reactive language that adds synchronous concurrency and preemption to JavaScript. Inspired from Esterel …"_ and _"compiled into plain sequential JavaScript"_ ([PLDI 2020][hh-pldi]). The host drives instants explicitly with `mach.react("S")` ([`test/exec-susp-res.hh.js`][hh-test-susp]). Its kernel mirrors Esterel: `fork { } par { }`, `abort { } when (L.now)`, `suspend { } when (S.now)`, `do { } every (I.now)` ([`doc/lang/flow.md`][hh-flow]). Its `async` form is the modern counterpart of Esterel's `exec` (see below).

> [!WARNING]
> The HTML documentation host `hop.inria.fr/hiphop` refused connections on 2026-11-22 (unverified). Every HipHop.js claim here cites the Markdown sources in the repository instead.

---

## Evaluation model

- **Push, event-driven, discrete.** The environment pushes one input event; the runtime runs one reaction; the program goes idle. There is no pull and no lazy evaluation. Nothing is "cold" or "hot": a trail that is not currently `await`ing an event cannot observe it. Céu: _"An input event is broadcast to all active trails, which share the event as an unique and global time reference"_ ([overview][ceu-overview]).
- **One event per logical instant (Céu).** _"Only a single input event is handled at a logical time"_ ([`synchronous_execution_model.md`][ceu-sync]). Esterel instead allows several simultaneous input signals per instant (ABRO must decide what `A` and `B` mean when they coincide with `R`, §3.1.1).
- **Glitch-freedom is structural.** A reaction is atomic, so no other trail or the environment ever observes an intermediate state. In Esterel the output event of an instant is a single consistent vector of statuses, guaranteed by constructive causality. In Céu the source-order scheduler makes intra-reaction ordering deterministic, but within a reaction a later trail _does_ see an earlier trail's writes. Céu warns about such accesses statically: the SenSys paper's algorithm detects concurrent accesses to variables and _"conflicting weak and strong abortions"_ ([sensys13]).
- **Synchronous, run-to-completion propagation.** There is no batching beyond the reaction itself. Céu queues inputs that arrive mid-reaction for later reactions.

---

## Composition

Composition happens through **statements, not operators**. The whole surface is a dozen control constructs:

| Need                    | Esterel                   | Céu                          | Rx equivalent (for comparison)         |
| ----------------------- | ------------------------- | ---------------------------- | -------------------------------------- |
| Wait for one event      | `await S`                 | `var T v = await E;`         | `first()`                              |
| Run concurrently, join  | `p ‖ q`                   | `par/and`                    | `zip` / `forkJoin`                     |
| Race, first wins        | `abort p when S`          | `par/or`, `watching`         | `race` / `takeUntil`                   |
| Restart on event        | `loop p each S`           | `loop do … par/or … await E` | `switchMap`                            |
| Repeat on event         | `every S do p end`        | `every v in E do … end`      | `subscribe`                            |
| Freeze / resume         | `suspend p when S`        | `pause/if e do … end`        | none (`windowToggle` / `bufferToggle`) |
| Derived value           | `?S` + `emit` in a thread | a `var` updated by a trail   | `map` / `scan`                         |
| Fire-and-forget subtask | (none; all is lexical)    | `spawn do … end` (scoped)    | `subscribe` (unscoped)                 |

Derived values are ordinary variables written by a dedicated trail. There is no memoised dependency graph: these languages trade derivation for control flow. A `map`/`filter`/`scan` pipeline is written as a loop around `await`. Céu's successor Atmos adds _"Functional Streams (à la ReactiveX)"_ with _"Safe finalization of stateful streams"_ on top of the task core ([Atmos README][atmos-readme]), which suggests that control-flow composition alone was found too low-level for data transformation.

Céu's `every` body _cannot_ contain synchronous control statements (`await`, `par/or`, `watching`, …) _"ensuring that no occurrences of the specified event are ever missed"_ ([`loops.md`][ceu-loops]). A body that waits, as debounce does, must be a `loop do … await … end`, and the program must then cope with events that arrive while it waits (see [the worked pipeline](#the-worked-pipeline)).

---

## Time and scheduling

- **Time is logical: input events _are_ the clock.** Céu treats wall-clock time as one more input: the host calls `ceu_input(CEU_INPUT__WCLOCK, &dt)`, and the runtime asks back for its next deadline through `CEU_CALLBACK_WCLOCK_MIN`, _"whenever a next minimum timer is required"_ ([`c_api.md`][ceu-capi]). This is exactly the shape of a frame loop that sleeps with `wakeIn`: the program reports its earliest deadline, and the host wakes at that deadline or on input.
- **Timers are countdowns with residual compensation.** `ceu_wclock_` ([`src/c/ceu.c`][ceu-wclock]) stores `dt - wclk_late` when an `await` starts, subtracts the elapsed `dt` on each clock input, and reports the minimum outstanding timer to the host. An expired `await` evaluates to the _residual_ delta, and _"if a program awaits timers in sequence (or in a `loop`), the residual `dt` from the preceding timer is reduced from the timer in sequence"_ ([`event_handling.md`][ceu-events]). Periodic loops therefore do not drift.
- **Debounce is not a primitive; it is an idiom.** `par/or do await (interval)ms; … with await QUERY; end` is the whole implementation. The code generator `Await_Wclock` ([`src/lua/codes.lua`][ceu-codes-wclock]) evaluates the `WCLOCKE` expression (`(t)ms`) **when the `await` starts**: _"`await (t)ms;` awaits the current value of the variable "t" in milliseconds"_ ([`event_handling.md`][ceu-events]). So **the duration can change at runtime**, and each new debounce picks up the current value. A debounce already pending keeps its old deadline unless the program also races it against the `INTERVAL` event.
- **Esterel time** is a signal like any other. `await 3 Meter` and `abort p when 2 Second` count occurrences of the input signals `Meter` and `Second` (§4.7.10). A debounce is `abort … when N MS` with `MS` a millisecond-tick input. There is no ambient clock, so a test simply feeds ticks.
- **Scheduler.** Esterel compiles to a single automaton or circuit, so its notion of scheduling is a static order. Céu's scheduler walks trails in lexical order ([`synchronous_execution_model.md`][ceu-sync]). Neither has threads, dispatchers or priorities beyond source order.

---

## Concurrency and cancellation

### Latest-wins is a control-flow construct

`par/or` (Céu), `abort … when` and `loop … each` (Esterel) _are_ latest-wins. The work trail and the "newer query" trail race inside one lexical block; the first to finish ends the block and **aborts the other in the same reaction**. Nothing is subscribed, so there is nothing to unsubscribe. Abortion is lexical and total: everything nested inside the aborted block dies, and its `finalize` clauses run, innermost first. In Esterel the strong/weak distinction decides whether the body gets one last instant at abortion time. Céu's `par/or` is strong for the losing trails and runs only their finalizers.

### CPU-bound work: `async`, `async/thread`, Esterel `exec`

Synchronous reactions must be bounded, so CPU-bound work needs a separate mechanism ([`asynchronous_execution.md`][ceu-async]):

> _"Asynchronous execution supports tight loops while keeping the rest of the application, aka the *synchronous side*, reactive to incoming events. … Even though asynchronous blocks execute in separate, they are still managed by the program hierarchy and are also subject to lexical scope and abortion."_

| Form                               | Runs where                                                                                                            | How abortion reaches it                                                                                                                                                                                                                                                                                                        | Does abort wait?                                                                                                              |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| Céu `await async (vars) do`        | Same thread, interleaved: "Start/Resume whenever the synchronous side is idle", "Suspend after each `loop` iteration" | The async trail `HALT`s on `CEU_INPUT__ASYNC` after each loop iteration ([`__loop_async`][ceu-codes-async]), and the host resumes it with `ceu_input(CEU_INPUT__ASYNC, NULL)` ([`ceu_loop`][ceu-loop]). An aborted async is simply **never resumed**, so cancellation is exact at iteration granularity                        | No: abortion is synchronous and immediate                                                                                     |
| Céu `await async/thread (vars) do` | A real `pthread`, _"completely detached from the synchronous side"_                                                   | Abortion runs the block's generated finalizer, which sets `has_aborted = 1` and calls `CEU_THREADS_CANCEL` → `pthread_cancel` ([`Async_Thread`][ceu-codes-thread], [`env/threads.h`][ceu-threads-h]). Each `atomic do` inside the thread first checks `has_aborted` and jumps to the exit label ([`Atomic`][ceu-codes-atomic]) | **No**: the thread is reaped later by `ceu_threads_gc`, which uses `pthread_tryjoin_np`, not `join` ([`src/c/ceu.c`][ceu-gc]) |
| Esterel `exec T(..) return R`      | The environment, "asynchronously with the Esterel program"                                                            | _"During its execution, an exec statement can be suspended or aborted. This is signaled to the external task by sending appropriate suspension and abortion signals"_ (§4.7.17)                                                                                                                                                | No: the abort is logical, and the environment honours it later                                                                |
| HipHop.js `async { } kill { }`     | A JS async action (timer, promise, worker)                                                                            | _"The optional arguments `kill`, `suspend`, and `resume` are JavaScript statements that are executed when the HipHop statement state changes. They give the opportunity to the JavaScript program to cleanup a computation if the `async` block is preempted"_ ([`doc/lang/async.md`][hh-async])                               | No: `kill` is a synchronous callback                                                                                          |

> [!IMPORTANT]
> Every system here makes cancellation **logically instantaneous and physically cooperative**. The synchronous side stops caring at once, and the worker stops when it next checks. In Céu, `pthread_cancel` uses deferred cancellation by default, and a pure hashing loop contains no POSIX cancellation point. The effective check is therefore the `has_aborted` test at each `atomic` entry. A thread that never enters `atomic` runs to completion after its scope is gone, and the source contains no `pthread_setcanceltype` that would change this (searched at `5e0c8d3`). A D design should state this split explicitly: a cancellation _token_ checked at chunk boundaries, plus a scope that does not join.

---

## Errors and completion

- **Completion is termination of a block.** A trail completes when its code falls off the end. `par/and`/`par/or` define how completions combine. An `await` on a code instance evaluates to its return value, and a `do … end` can `escape v` to produce a value ([`blocks.md`][ceu-blocks]). There are no streams to complete, only control reaching the end of a block.
- **Errors are mostly compile-time.** Esterel rejects non-constructive programs. Céu rejects tight loops, missing `finalize`, and synchronous control statements in forbidden positions ([`synchronous_control_statements.md`][ceu-sync-ctl]). Runtime errors are C-level asserts.
- **Exceptions are immature in Céu.** `throw`/`catch` exist in the v0.30 grammar, but the section reads only `TODO` ([`exceptions.md`][ceu-exceptions]), and the generator warns `'exception inside \`async/thread\`'` ([`codes.lua`][ceu-codes-exc]). Esterel has `trap T in … exit T … end trap`, a structured, statically scoped exit that preempts like a weak abort (§3.11: _"At exit time, all statements in the trap body are weakly aborted, as for a weak abort statement (weak abort is actually a macro-statement built using traps)"_).
- **Typed error values are absent from both languages.** A D library would carry `Expected` through the same `escape`/return path.

---

## State and sharing

- **Value cells:** Esterel valued signals keep their last value, readable as `?S` (the basis of the _speed measure_ and _counting_ examples, §3.3–3.5). Céu uses ordinary `var`s in lexical scope, shared freely among trails because _"accesses to shared variables among trails are deterministic and do not require synchronization primitives"_ ([overview][ceu-overview]).
- **Multicast is the default.** Every `emit` is a broadcast to every awaiting trail. There is no subscription, no replay, and no buffer: an event that nobody awaits in that reaction is lost (the "empty reaction chain" at _t2_ in [`synchronous_execution_model.md`][ceu-sync]).
- **Conflation is implicit.** Because only the current reaction's event is visible, latest-wins and conflation are the natural semantics. Accumulation (a queue) has to be programmed explicitly.
- **Threads break the model.** `async/thread` shares the listed variables by memory and _"require[s] explicit atomic blocks on accesses to variables to avoid race conditions"_ ([`asynchronous_execution.md`][ceu-async]).

---

## Lifetime and ownership

Lifetime here is **pure lexical scope**, the strongest form in this survey:

- _"Céu provides static memory management based on lexical scope and does not require a garbage collector"_ ([overview][ceu-overview]). Trail memory is a statically sized union, because parallel trails are known at compile time.
- `spawn do … end` is _scoped_: _"When the enclosing block terminates, the spawned block is aborted"_ ([`parallel_compositions.md`][ceu-par]). There is no unscoped fire-and-forget: leaks of the `subscribe`-without-`unsubscribe` kind cannot be written.
- `finalize` attaches cleanup to the scope that owns a C resource, and the compiler forces it for pointer-carrying calls ([`c_integration.md`][ceu-cint]). The `_send_request` / `_send_cancel` example is precisely "cancel the in-flight external operation when the scope dies".
- The one leak is `async/thread`: its OS thread can outlive its scope, as described [above](#cpu-bound-work-async-asyncthread-esterel-exec).

This is the same contract as structured concurrency (a scope does not end until its children have ended), with one difference that matters: here a child "ends" **logically** at the abort, not when its physical work stops.

---

## Testing

The synchronous model makes tests deterministic by construction. A test is an input trace, and the expected output is a function of that trace.

- **Simulation in the language.** A Céu `async` may `emit` inputs _and time_ toward the synchronous side: _"An `async` block can emit input and timer events towards the synchronous side, providing a way to test programs in the language itself. Every time an `async` emits an event, it suspends until the synchronous side reacts to the event"_ ([`asynchronous_execution.md`][ceu-async]). The manual's example `emit 1s35ms;` advances virtual time and asserts that a 10 ms loop ran _exactly_ 103 times. This is the counterpart of `TestClock`: virtual time is just an input.
- **Debounce test.** `emit QUERY(1); emit 100ms; emit QUERY(2); emit 300ms;` is a complete, wall-clock-free debounce test. The second query aborts the first timer, and only query 2 is hashed.
- **Esterel / HipHop** tests are sequences of `react` calls with the present inputs listed, each followed by an assertion on the emitted outputs (`mach.react("S")` in [`test/exec-susp-res.hh.js`][hh-test-susp]).
- **The limit:** real `async/thread` and `exec` work is non-deterministic, so tests stub it out with an input event that plays the return signal.

---

## The worked pipeline

### The naive shape and its bug

The shape that comes to mind first, `loop do var q = await QUERY; par/or do await (interval)ms; <hash> with await QUERY end end`, **loses the newer query**. The `await QUERY` in the second branch _consumes_ the keystroke that aborts the debounce. When control loops back to the top `await QUERY`, that reaction is already in progress. Céu wakes only the trails that were awaiting when the event occurred (step 4 of the model). The runtime implements this in two phases: `ceu_bcast_mark` first flags matching trails `CEU_INPUT__STACKED`, and only then are the flagged trails run ([`src/c/ceu.c`][ceu-bcast]). As a result, the top `await` waits for the _next_ keystroke, and the latest text is never hashed. The fix is to carry the winning event's value out of the `par/or`, which is what Esterel's `loop … each QUERY` + `?QUERY` does for free.

### Céu

```c
// Céu v0.30 (fenced as `c` for highlighting); compile with --ceu-features-thread
input  int  QUERY;          // payload: handle of the query text (string handling elided)
input  int  INTERVAL;       // new debounce interval, ms (from the numeric field)
input  none TOGGLE_ON;
input  none TOGGLE_OFF;
output u64  RESULT;

var int interval = 300;

par do
    var int v;
    every v in INTERVAL do              // `every` bodies may not await: just store
        interval = v;                   // read by the next `await (interval)ms`
    end
with
    loop do                             // the toggle: off ⇒ abort the whole pipeline
        await TOGGLE_ON;
        watching TOGGLE_OFF do
            var int q = await QUERY;
            loop do
                q = do                  // value of the newest query: latest-wins
                    par/or do
                        await (interval)ms;              // debounce
                        var u64  acc  = 0;
                        await async/thread (q, acc) do   // CPU-bound hash, real thread
                            var int i;
                            loop i in [0 -> _nfiles(q)[ do
                                var u64 h = _hash_file(q, i);
                                atomic do                // also the cancellation check
                                    acc = acc ^ h;
                                end
                            end
                        end
                        emit RESULT(acc);
                        escape await QUERY;              // idle until the next keystroke
                    with
                        var int nq = await QUERY;        // newer query: abort the left trail
                        escape nq;
                    end
                end;
            end
        end
    end
end
```

### Pseudo-Esterel (labelled: v5 syntax, untested)

```text
module Pipeline:
input  QUERY : integer, TOGGLE_ON, TOGGLE_OFF, MS;
input  INTERVAL : integer;            % assume an initial emission at boot
output RESULT : integer;
task   Hash (integer) (integer);
return HASHED;
loop
   await TOGGLE_ON;
   abort                               % strong: off kills timer and task
      await QUERY;
      loop
         var res : integer in
            await ?INTERVAL MS;         % debounce: count MS ticks
            exec Hash (res) (?QUERY) return HASHED;
            emit RESULT(res)
         end var;
         halt
      each QUERY                        % strong abort + restart; ?QUERY is the new text
   when TOGGLE_OFF
end loop
```

### Per-event trace (Céu version)

| Event (one reaction each)      | What happens                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TOGGLE_ON`, then `QUERY(1)`   | The `watching` body starts; `q = 1`; the `par/or` arms a 300 ms timer (`ceu_wclock_` reports the new minimum to the host, which sets `wakeIn(300ms)`) and awaits `QUERY`.                                                                                                                                                                                  |
| `QUERY(2)` **during debounce** | The right trail wakes, `escape 2` ends the `do`, the `par/or` aborts the left trail and its timer disappears with it, `q = 2`, and the loop re-enters `par/or` with a fresh `await (interval)ms`. All of this happens in one reaction, with no intermediate state visible.                                                                                 |
| Timer expires                  | The host feeds `WCLOCK(dt)`; the left trail wakes, spawns the hashing thread, and halts awaiting `CEU_INPUT__THREAD`. The UI stays responsive because the synchronous side is idle.                                                                                                                                                                        |
| `QUERY(3)` **during hash**     | The right trail wins. Aborting the left trail runs the `async/thread` finalizer: `has_aborted = 1`, `pthread_cancel`. The synchronous side does **not** wait; it re-arms the debounce for `q = 3` at once. The old thread exits at its next `atomic` (between files), and `ceu_threads_gc` reaps it on a later loop iteration. Its `acc` is never emitted. |
| `INTERVAL(500)`                | The first trail stores `interval = 500`. A debounce **already pending keeps its old deadline**; the next `await (interval)ms` uses 500. Adding `with await INTERVAL; escape q;` as a third `par/or` branch would restart the pending debounce with the new value.                                                                                          |
| `TOGGLE_OFF`                   | The `watching` aborts everything nested: the pending timer, or the hashing thread (via its finalizer). Control returns to `await TOGGLE_ON`. Keystrokes while off wake nobody and are dropped, which is the intended semantics.                                                                                                                            |
| `RESULT(acc)` reaches the UI   | `emit` of an output event calls the host's output callback synchronously within the reaction; the widget tree reads the stored result on the next frame.                                                                                                                                                                                                   |

### Fit with a per-frame UI

- **Good fit:** a frame is a natural instant. The host loop already has the right shape: collect input, call `ceu_input` once per event, ask for the next timer deadline (`CEU_CALLBACK_WCLOCK_MIN` ↔ `wakeIn`), render. The pipeline's state lives in which `await` each trail is parked on, not in flags, so a toggle-off cannot leave a stale "debouncing" bit behind.
- **Mismatch 1, one event per instant:** Céu handles one input per reaction, while a frame may carry several (a keystroke _and_ a toggle). The host must serialise them, and their order becomes semantics. Esterel's multi-signal instant matches a frame better but brings causality analysis with it.
- **Mismatch 2, retained vs immediate mode:** trails are retained, long-lived state machines. In an immediate-mode tree they live _beside_ the per-frame widget rebuild as a controller, and the widgets read their results. This is the pattern [Elm][elm] and [Jetpack Compose][compose] formalise from the other side.
- **Mismatch 3, the physical/logical gap:** an aborted hash keeps burning a core until its next check. The language hides this behind "instantaneous" abortion, so the D library must make it observable (for example, a scope that can optionally `join` its cancelled worker).

---

## Strengths

- **Lexical, total abortion.** One `par/or`/`watching`/`abort` kills an arbitrary subtree of timers, awaits and nested parallels, and runs its finalizers. Nothing like `takeUntil` placement or forgotten `unsubscribe` can go wrong.
- **Latest-wins without operators.** `switchMap` semantics fall out of control flow, and the code reads like the specification.
- **Determinism and reproducibility.** Source-order scheduling (Céu) or constructive semantics (Esterel) make every input trace replayable. Tests need no clock mocking: time is an input.
- **Bounded reactions are checked statically** (Céu's tight-loop rule, Esterel's instantaneous-loop rejection), so a reaction cannot hang the UI frame.
- **No GC, static memory** (Céu): trail storage is computed at compile time, and the language targets wireless-sensor nodes: reimplemented drivers and protocols came within _"an increase in ROM and RAM below 10%"_ of nesC ([sensys13]).
- **The host interface fits an event loop.** Input events in, next deadline out. `event-horizon`'s `wakeIn` maps onto this one to one.

## Weaknesses

- **No dataflow vocabulary.** Derived values, `map`/`scan`/`combineLatest` and memoisation are hand-written loops. Atmos later bolted on Rx-style streams ([atmos-readme]).
- **Consuming awaits lose events.** The naive pipeline drops the newest query, because an `await` reached mid-reaction does not see that reaction's event. Programs must thread the winning value out explicitly.
- **Real parallelism is second-class.** `async/thread` gives up determinism, needs `atomic`, and its cancellation is cooperative and unjoined. The plain `async` is cooperative and single-core.
- **Causality analysis (Esterel) is subtle.** Rejected programs are hard to explain: the primer devotes a whole chapter (ch. 5) to why `present O else emit O end` has no meaning. Reports that HipHop.js users still hit hard-to-locate causality cycles were seen only in search-result summaries (unverified).
- **Small ecosystems and stalled tools.** Céu's last commit on this repository is 2019-07-17, and `exceptions.md` and `deterministic_execution.md` are still `TODO`. Its author moved on to d-Ceu (announced February 2023) and Atmos (announced 2025-08-17, [ceu-lang list][atmos-ann]).

---

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                          | Trade-off                                                                                                        |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Synchronous hypothesis: reactions take zero logical time           | Outputs are a function of the input trace; no interleavings to reason about        | Real work must be bounded or exiled to `async`/`exec`; the physical cost of a reaction is invisible in the model |
| Abortion is a lexical block (`abort`, `par/or`, `watching`)        | Cancellation composes like `if`; finalizers make it safe for resources             | Only tree-shaped lifetimes; work that outlives its scope needs an explicit escape (`spawn` is still scoped)      |
| Strong vs weak preemption (Esterel)                                | Lets the programmer choose whether the body gets "last wills" in the abort instant | Two near-identical constructs whose difference is one instant: easy to choose wrongly                            |
| Abort vs suspend as distinct primitives                            | ^C vs ^Z: kill state, or freeze it (timers included)                               | The toggle must choose: `pause/if` would resume a stale debounce, `watching` discards it                         |
| Same-instant absence tests (Esterel) vs non-immediate awaits (Céu) | Esterel: maximal expressiveness, reaction to absence; Céu: no causality cycles     | Esterel needs constructive causality analysis; Céu needs explicit value threading (the lost-event pitfall)       |
| Source-order trail scheduling (Céu)                                | Deterministic without an analysis; doubles as priority                             | Behaviour depends on textual order of `par` branches                                                             |
| Time as an input event                                             | Virtual time for free; host controls the clock (`WCLOCK_MIN` ↔ `wakeIn`)           | Every timer depends on the host delivering `dt` accurately; residual-`dt` compensation is needed against drift   |
| CPU work via `async` (cooperative) or `async/thread` (pthread)     | Keeps the synchronous side bounded; abortion still reaches the work lexically      | Thread abort is `pthread_cancel` + flag checked at `atomic`; no join, so the work runs on after the abort        |
| Static memory per trail (Céu)                                      | No GC; runs on microcontrollers                                                    | Dynamic fan-out needs `pool`s with declared bounds                                                               |

---

## Sources

- Gérard Berry, [_The Esterel v5 Language Primer_, v5.91, 2000-06-05][primer] (read in full; quotes above are verbatim from this copy).
- Gérard Berry & Georges Gonthier, ["The Esterel synchronous programming language: design, semantics, implementation", _Science of Computer Programming_ 19(2):87–152, 1992][berry-gonthier] (bibliographic details confirmed; publisher page returned HTTP 403, full text not read).
- Gérard Berry & Manuel Serrano, ["HipHop.js: (A)Synchronous Reactive Web Programming", PLDI 2020][hh-pldi] (abstract read).
- HipHop.js sources: [`README.md`][hh-readme], [`doc/lang/async.md`][hh-async], [`doc/lang/flow.md`][hh-flow], [`test/loopeach.hh.js`][hh-test-each], [`test/exec-susp-res.hh.js`][hh-test-susp]; HTML docs at `hop.inria.fr/hiphop` (unreachable on 2026-11-22 and 2026-11-24, with no archived copy).
- Francisco Sant'Anna, Noemi Rodriguez, Roberto Ierusalimschy, Olaf Landsiedel, Philippas Tsigas, ["Safe System-level Concurrency on Resource-Constrained Nodes", SenSys 2013][sensys13] ([copy read][sensys13-pdf]).
- Francisco Sant'Anna, Roberto Ierusalimschy, Noemi Rodriguez, ["Structured Synchronous Reactive Programming with Céu", Modularity 2015][modularity15] (bibliographic details via DBLP/Wikipedia; full text not read).
- Céu manual v0.30: [overview][ceu-overview], [synchronous execution model][ceu-sync], [parallel compositions and abortion][ceu-par-abort], [bounded execution][ceu-bounded], [internal reactions][ceu-internal], [parallel compositions][ceu-par], [event handling][ceu-events], [loops][ceu-loops], [asynchronous execution][ceu-async], [C integration / finalization][ceu-cint], [blocks][ceu-blocks], [synchronous control statements][ceu-sync-ctl], [exceptions][ceu-exceptions], [C API][ceu-capi].
- Céu runtime and compiler: [`src/c/ceu.c` — `ceu_wclock_`][ceu-wclock], [`ceu_bcast_mark`/`ceu_bcast`][ceu-bcast], [`ceu_threads_gc`][ceu-gc], [`ceu_loop`][ceu-loop]; [`src/lua/codes.lua` — `Await_Wclock`][ceu-codes-wclock], [`__loop_async`][ceu-codes-async], [`Async_Thread`][ceu-codes-thread], [`Atomic`][ceu-codes-atomic]; [`env/threads.h`][ceu-threads-h].
- Successors: [Atmos README][atmos-readme]; [Atmos announcement on the ceu-lang list, 2025-08-17][atmos-ann].
- Related: [RxJS][rxjs] · [Effect-TS][effect-ts] · [Kotlin Flow][kotlin-flow] · [Elm][elm] · [Sodium][sodium] · [Jetpack Compose][compose] · [Concepts][concepts] · [Comparison][comparison] · [Structured coroutines][coroutines] · [Async I/O survey][async-io]

<!-- References -->

[primer]: https://www.rw.cdl.uni-saarland.de/people/kaestner/private/es0203/esterel_primer.pdf
[berry-gonthier]: https://doi.org/10.1016/0167-6423(92)90005-V
[hh-pldi]: https://pldi20.sigplan.org/details/pldi-2020-papers/24/HipHop-js-A-Synchronous-Reactive-Web-Programming
[hh-repo]: https://github.com/manuel-serrano/hiphop/tree/7236e0a1508bf9dc2ec1ad822169d73937e8ecba
[hh-readme]: https://github.com/manuel-serrano/hiphop/blob/7236e0a1508bf9dc2ec1ad822169d73937e8ecba/README.md
[hh-async]: https://github.com/manuel-serrano/hiphop/blob/7236e0a1508bf9dc2ec1ad822169d73937e8ecba/doc/lang/async.md
[hh-flow]: https://github.com/manuel-serrano/hiphop/blob/7236e0a1508bf9dc2ec1ad822169d73937e8ecba/doc/lang/flow.md
[hh-test-each]: https://github.com/manuel-serrano/hiphop/blob/7236e0a1508bf9dc2ec1ad822169d73937e8ecba/test/loopeach.hh.js
[hh-test-susp]: https://github.com/manuel-serrano/hiphop/blob/7236e0a1508bf9dc2ec1ad822169d73937e8ecba/test/exec-susp-res.hh.js
[sensys13]: https://doi.org/10.1145/2517351.2517360
[sensys13-pdf]: https://www.cs.virginia.edu/~bjc8c/class/cs6501-f18/papers/santanna13ceu.pdf
[modularity15]: https://doi.org/10.1145/2724525.2724571
[atmos-repo]: https://github.com/atmos-lang/atmos/tree/a06998ab3f2d1f41046ff89fd14f602ca6ead4fa
[atmos-readme]: https://github.com/atmos-lang/atmos/blob/a06998ab3f2d1f41046ff89fd14f602ca6ead4fa/README.md
[atmos-ann]: https://groups.google.com/g/ceu-lang/c/oqxaFaxWINw
[ceu-repo]: https://github.com/ceu-lang/ceu/tree/5e0c8d3004ad98658ffe82823ad8303a8d371064
[ceu-license]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/LICENSE
[ceu-manual]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/index.md
[ceu-overview]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/overview/index.md
[ceu-sync]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/overview/synchronous_execution_model.md
[ceu-par-abort]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/overview/parallel_compositions_and_abortion.md
[ceu-bounded]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/overview/bounded_execution.md
[ceu-internal]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/overview/internal_reactions.md
[ceu-par]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/parallel_compositions.md
[ceu-events]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/event_handling.md
[ceu-loops]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/loops.md
[ceu-async]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/asynchronous_execution.md
[ceu-cint]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/c_integration.md
[ceu-blocks]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/blocks.md
[ceu-sync-ctl]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/synchronous_control_statements.md
[ceu-exceptions]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/statements/exceptions.md
[ceu-capi]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/docs/manual/v0.30/docs/compilation/c_api.md
[ceu-wclock]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/c/ceu.c#L463-L493
[ceu-bcast]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/c/ceu.c#L729-L968
[ceu-gc]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/c/ceu.c#L636-L674
[ceu-loop]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/c/ceu.c#L1071-L1094
[ceu-codes-wclock]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/lua/codes.lua#L1533-L1557
[ceu-codes-async]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/lua/codes.lua#L843-L856
[ceu-codes-thread]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/lua/codes.lua#L1646-L1746
[ceu-codes-atomic]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/lua/codes.lua#L1807-L1836
[ceu-codes-exc]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/src/lua/codes.lua#L772-L774
[ceu-threads-h]: https://github.com/ceu-lang/ceu/blob/5e0c8d3004ad98658ffe82823ad8303a8d371064/env/threads.h
[rxjs]: ./rxjs.md
[effect-ts]: ./effect-ts.md
[kotlin-flow]: ./kotlin-flow.md
[elm]: ./elm.md
[sodium]: ./sodium.md
[compose]: ./jetpack-compose.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[coroutines]: ../coroutines/index.md
[async-io]: ../async-io/index.md
