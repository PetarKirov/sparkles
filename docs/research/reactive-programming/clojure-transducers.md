# Clojure transducers (Clojure / core.async, with Java Stream Gatherers)

Reducing-function transformers: a `map`, `filter` or `dedupe` written once, as a function from one step function to another, and applied by any process that feeds inputs one at a time — a collection, a lazy sequence, an iterator, a `core.async` channel. Java's Stream Gatherers (JEP 485) are the closest mainstream descendant.

| Field             | Value                                                                                                                                                                                                                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Clojure (JVM; ClojureScript ships the same `core.async` surface); Java 24+ for Gatherers                                                                                                                                                                                                             |
| License           | EPL-1.0 ([`epl-v10.html`][clj-epl], [core.async `LICENSE`][async-license]); OpenJDK GPL-2.0 with Classpath Exception ([`LICENSE`][jdk-license])                                                                                                                                                      |
| Repository        | [clojure/clojure][clj-repo] · [clojure/core.async][async-repo] · [openjdk/jdk][jdk-repo]                                                                                                                                                                                                             |
| Documentation     | [Transducers reference][ref] · [announcement (2014-08-06)][blog] · [Strange Loop 2014 talk][talk] · [core.async reference][async-ref] · [JEP 485][jep485]                                                                                                                                            |
| Category          | Source- and sink-independent element transformation; push-driven by whichever process applies it                                                                                                                                                                                                     |
| Versions surveyed | Clojure `1.13.0-master-SNAPSHOT` ([`pom.xml`][clj-pom]; newest entry in [`changes.md`][clj-changes] is `1.12.7`) at `92ce2a8`, 2026-11-23 · core.async `1.9.865` (latest release in [`README.md`][async-readme]) at `8e6e382`, 2026-06-12 · JDK at `c35f741`, 2026-11-23 (`Gatherer` is `@since 24`) |
| Core abstraction  | A transducer `(rf) -> rf'`, where `rf` has three arities: init `()`, step `(result, input)`, completion `(result)`                                                                                                                                                                                   |

> [!NOTE]
> Line numbers are to `92ce2a8524286f765be29779fdc6f96891453dd9` (clojure), `8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b` (core.async) and `c35f74179474524a5fa013f6f425691fea3e0cf6` (jdk). Transducers shipped in Clojure 1.7; `halt-when` came in 1.9. The `core.async.flow` sources are not in the core.async tree at this commit; only its guides ([`doc/flow.md`][async-flow], [`doc/flow-guide.md`][async-flow-guide]) are, so flow is cited from those.

---

## Overview

### What it solves

Before 1.7, Clojure had one `map` per context: the lazy-sequence `map`, the reducers library's `r/map`, and core.async's channel-to-channel `map<`/`map>`/`filter<`/`unique`/`partition`. Each re-implemented the same element logic against a different carrier. Hickey's announcement names the itch ([blog]):

> _"In working recently on providing algorithmic combinators for core.async, I became more and more convinced of the superiority of reducing function transformers over channel→channel functions for algorithmic transformation. In fact, I think they are a better way to do many things for which we normally create bespoke replicas of map, filter etc."_

A transducer factors out what is common: what happens to _one_ input. The carrier — where inputs come from, what accumulates the outputs, whether the loop is eager, lazy or a channel's put path — belongs to the _transducible process_. Each core sequence function gained an arity one shorter than before that returns the transducer, and the core.async channel functions were deprecated with the message _"Use transducer instead"_ ([`async.clj` L1127–1131][async-deprecated]).

### Design philosophy

The reference defines the abstraction by its independence ([reference][ref]):

> _"Transducers are composable algorithmic transformations. They are independent from the context of their input and output sources and specify only the essence of the transformation in terms of an individual element. Because transducers are decoupled from input or output sources, they can be used in many different processes - collections, streams, channels, observables, etc."_

The announcement states it as a type ([blog]): a reducing function is `whatever, input -> whatever`, a transducer is `(whatever, input -> whatever) -> (whatever, input -> whatever)`, and _"they don't care (or know about): the 'job' being done (what the reducing function does) the context of use (what 'whatever' is) the source of inputs (where input comes from)."_ Composition is ordinary function composition (`comp`), and stateful transducers keep their state in the closure created _when the process applies them_, not when they are defined. Hickey's [Strange Loop 2014 talk][talk] derives the same design from `reduce`; this survey cites the written sources, which state each rule, and was not checked against a talk transcript.

---

## How it works

The 1-arity of `map` is the whole pattern ([`core.clj` L2772][clj-map]):

```clojure
(defn map
  ([f]
    (fn [rf]                       ; the transducer: takes the downstream rf
      (fn
        ([] (rf))                  ; init: delegate
        ([result] (rf result))     ; completion: delegate
        ([result input]            ; step: call rf 0..n times
           (rf result (f input)))))))
```

`filter` calls `rf` zero or one time ([L2838][clj-filter]). A stateful transducer allocates its state inside `(fn [rf] …)`, so each application gets fresh state. `dedupe` ([L8103][clj-dedupe]) holds `(volatile! ::none)`; `take` ([L2906][clj-take]) holds a countdown and returns `(ensure-reduced result)` after the last item; `partition-by` ([L7564][clj-partition-by]) and `partition-all` ([L7644][clj-partition-all]) hold a `java.util.ArrayList` and flush it in the completion arity:

```clojure
([result]
   (let [result (if (.isEmpty a)
                  result
                  (let [v (vec (.toArray a))]
                    (.clear a)                  ;;clear first!
                    (unreduced (rf result v))))]
     (rf result)))
```

The parts that make up the protocol:

| Piece                                     | Definition                                                                                                           | Role                                                                                              |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `reduced` / `reduced?` / `unreduced`      | [`core.clj` L2881–2904][clj-reduced]; `clojure.lang.Reduced` is a one-field box ([`Reduced.java`][clj-reduced-java]) | Early termination: a step returns a boxed result, the process stops feeding inputs                |
| `volatile!` / `vswap!` / `vreset!`        | [L2570–2591][clj-volatile]; [`Volatile.java`][clj-volatile-java] is a `volatile Object` field                        | Cheap mutable box for per-application state; _"should only be used with thread isolation"_        |
| `completing`                              | [L7205][clj-completing]                                                                                              | Adds a completion arity (default `identity`) to a 2-arity reducing function                       |
| `transduce`                               | [L7217][clj-transduce]                                                                                               | Eager: `(let [f (xform f) ret (reduce f init coll)] (f ret))` — completion always runs            |
| `into`, `sequence`, `eduction`            | [L7234][clj-into], [L2692][clj-sequence], [L8130–8150][clj-eduction]                                                 | Build a collection; a lazy seq via `TransformerIterator`; a re-runnable reducible/iterable recipe |
| `TransformerIterator`                     | [`TransformerIterator.java`][clj-ti]                                                                                 | The pull adaptor: drives the push transducer one source element at a time into a small buffer     |
| `chan` with `xform`                       | [`async.clj` L116][async-chan], [`impl/channels.clj` L289][async-channels-chan]                                      | The transducer wraps the buffer's `add!`; it runs on every put, under the channel mutex           |
| `pipeline`, `pipeline-blocking`, `-async` | [`async.clj` L573–660][async-pipeline]                                                                               | N workers between two channels; the transducer is applied to each element independently           |

The reference states the process contract as three rules ([reference][ref]): _"If a step function returns a reduced value, the transducible process must not supply any more inputs to the step function. The reduced value must be unwrapped with deref before completion."_; _"A completing process must call the completion operation on the final accumulated value exactly once."_; _"A transducing process must encapsulate references to the function returned by invoking a transducer - these may be stateful and unsafe for use across threads."_ And for stateful transducers: _"In the completion step, a transducer with reduction state should flush state prior to calling the nested transformer's completion function, unless it has previously seen a reduced value from the nested step in which case pending state should be discarded."_

---

## Evaluation model

- **Push, always.** A transducer never asks for input; the process calls its step with one input, and the step pushes zero or more outputs into `rf`. Every process is the loop that owns the source: `reduce` over `IReduceInit`, a channel's put path, the iterator's `step()`.
- **Pull is an adaptor around the push.** `sequence` and `eduction`'s `iterator()` use `TransformerIterator` ([source][clj-ti]): it applies the transducer to a terminal step that appends to a `Buffer` (`Empty` → `Single` → `Many`), and `hasNext()` pulls one source element per loop iteration until the buffer is non-empty. It calls the completion step (`xf.invoke(null)`) both when the source runs dry and when a step returned `reduced`. One pull can therefore produce several buffered outputs (`cat`, a `partition-all` flush), which is why the adaptor needs a queue, not a slot.
- **Lazy or eager is the process's choice.** `transduce` and `into` are eager loops; `sequence` is incremental (_"These sequences will consume input incrementally as needed and fully realize intermediate operations"_, [reference][ref]); `eduction` re-runs the whole transformation _"each time reduce/iterator is called"_ — a cold recipe.
- **Cold and hot do not apply to the transducer** — it is a value with no subscription. A channel is hot (puts happen whether or not anyone takes); a collection is cold.
- **No graph, so no glitches and no glitch-freedom.** A transducer has one input and one output. Multi-input `sequence` ([L2692][clj-sequence]) zips its collections in lockstep through `MultiIterator`; it never combines independent event sources.

---

## Composition

`(comp (map inc) (filter even?) (dedupe))` composes right to left as functions, but because each wraps the _downstream_ `rf`, data flows left to right — the order of a `->>` thread. The reference spends a sentence on it: _"As a mnemonic, remember that the ordering of transducer functions in comp is the same order as sequence transformations in `->>`"_ ([reference][ref]).

The surface is the 1.7 list in [`changes.md`][clj-changes] — `map`, `mapcat`, `filter`, `remove`, `take`, `take-while`, `drop`, `drop-while`, `take-nth`, `replace`, `partition-by`, `partition-all`, `keep`, `keep-indexed`, `map-indexed`, `distinct`, `interpose` — plus the new `cat`, `dedupe`, `random-sample`, and later `halt-when` (1.9). That is about twenty-one operators, all unary, none timed. **There is no `scan` transducer**: `reductions` ([L7618][clj-reductions]) has only collection arities, an absence the [Gatherers](#related-designs-java-stream-gatherers) API fills (`Gatherers.scan`).

### What can and cannot be a transducer

A transducer is a function invoked _by the process_, synchronously, once per input. That rules out three operator classes:

| Class                     | Examples                                      | Why not a transducer                                                                                                                                                                                                                                                                      |
| ------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Per-element, stateless    | `map`, `filter`, `keep`, `cat`                | Fits                                                                                                                                                                                                                                                                                      |
| Per-element, stateful     | `dedupe`, `take`, `partition-all`, `scan`     | Fits; state is created per application, flushed at completion                                                                                                                                                                                                                             |
| Time-based                | `debounce`, `throttle`, `sample`, `timeout`   | Must emit when _no_ input arrives (the timer fires). A step runs only when the process delivers an input, so the transducer cannot act between inputs. It would need the clock as a second input — a second source — or a process that owns a timer                                       |
| Concurrency / latest-wins | `switchMap`, `flatMapLatest`, `mapConcurrent` | Needs work that outlives one step (the inner computation) and the right to cancel it when the next input arrives. A step must return before the next step is called, and there is no cancel arity. core.async does this in `go`/`thread` processes and in `pipeline*`, not in transducers |
| Multi-input               | `merge`, `combineLatest`, `zip`, `race`       | A reducing function has one input slot. `merge` must interleave two independent producers, so it owns two waits — a process. Lockstep `zip` exists only as `sequence`'s multi-collection arity                                                                                            |

core.async draws exactly this line. Its element logic is all transducers (`chan` with an `xform`), while the operations that are processes stay functions over channels: `pipe`, `split`, `merge` ([L1083][async-merge]), `mult`/`tap`, `pub`/`sub`, `mix`, the multi-channel `map` ([L1045][async-map]), `take` ([L1109][async-take]), and `pipeline*`. Each of these is a `go-loop` that owns its channels. Debounce is not in the library at all (no `debounce`, `throttle` or `sample` anywhere in [`async.clj`][async-clj]); it is written by hand with `alts!` over a `timeout` channel ([worked pipeline](#the-worked-pipeline)).

### API structure and naming

- **Three roles, three vocabularies.** _Transformations_ are transducers (`(map f)`, composed with `comp`). _Sinks_ are reducing functions (`conj`, `+`, `(completing f cf)`). _Processes_ bind a transformation to a source and a sink: `transduce`, `into`, `sequence`, `eduction`, `run!`, `stream-transduce!` ([L7078][clj-stream-transduce], 1.12, for `java.util.stream`), `chan`, `promise-chan`, `pipeline*`, and core.async's own `transduce` ([L699][async-transduce]). The shape is `(process xform sink source)` throughout: `(transduce xf + 0 coll)`, `(into [] xf coll)`, `(chan 1 xf)`.
- **Same name, shorter arity.** The transducer is not a separate `mapT`: `(map f)` returns it and `(map f coll)` returns a lazy seq. The reference warns that _"this reduced arity is not currying or partial application"_ ([reference][ref]) — `(map f)` does not wait for a `coll`, it returns a different kind of value. Arity overloading is how a dynamically typed library gets one name for both; it costs nothing at a call site and confuses newcomers (`(map f)` in a `->>` thread silently returns a function).
- **A user-defined operator is a three-arity function of `rf`.** No interface, no registration: write `(fn [rf] (fn ([] (rf)) ([r] (rf r)) ([r x] …)))`, keep state in a `volatile!` inside the outer `fn`, honour `reduced` from `rf`. `cat` ([L8067][clj-cat]) shows the one subtle rule: a step that runs a nested `reduce` must wrap `rf` with `preserving-reduced` so that a `reduced` from downstream escapes the inner loop.
- **Suffixes carry effects.** `!` marks mutation or a channel effect (`volatile!`, `vswap!`, `put!`, `close!`), `!!` marks the blocking thread variant (`>!!`, `<!!`, `onto-chan!!`), and `<`/`>` on the deprecated channel ops marked the read or write side. core.async renamed `onto-chan`/`to-chan` to `onto-chan!`/`onto-chan!!` in 1.2 ([`async.clj` L752–763][async-onto-chan]: _"Deprecated - use onto-chan! or onto-chan!!"_) to make the parking-vs-blocking split visible.
- **Regrets on record.** (1) The whole channel-op family (`map<`, `map>`, `filter<`, `filter>`, `remove<`, `mapcat<`, `unique`, `partition`, `partition-by`) sits under `;;;; deprecated - do not use ;;;;` ([L1127][async-deprecated]). (2) The announcement called the recipe function `iteration` (_"`(iteration xform data)`"_, [blog]); it shipped as `eduction`, and `iteration` was reused in 1.11 for an unrelated paging generator ([`changes.md`][clj-changes] §3.4, CLJ-2555). (3) `pipeline`'s argument order is `n to xf from`, `pipe`'s is `from to`; a comment above `pipeline` still says _";;todo - switch pipe arg order to match these (to/from)"_ ([L623][async-pipe-todo]). (4) `into` once skipped completion in a way that broke `halt-when` (CLJ-2556, [`changes.md`][clj-changes]) — the completion-exactly-once rule is easy to get wrong in a process.

---

## Time and scheduling

Transducers have no clock, scheduler or thread. They run on whatever thread drives the process; for a channel, that is _"either the writer or reader thread depending on the operation and the state of the buffer"_ ([`doc/reference.md`][async-ref]), under the channel's mutex. Hence the rule: _"Channel transducers must not block, whether by issuing i/o operations or by externally synchronizing, else risk impeding or deadlocking go blocks."_

core.async's time is `(timeout ms)` ([L145][async-chan]), a channel that closes after `ms`. The implementation ([`impl/timers.clj`][async-timers]) keeps one global `java.util.concurrent.DelayQueue` drained by one daemon thread, and coalesces timeouts at `TIMEOUT_RESOLUTION_MS 10`: a `timeout` whose deadline falls less than 10 ms before an existing entry's reuses that entry's channel (`.ceilingEntry` on a `ConcurrentSkipListMap`), so it may fire up to 10 ms late. A timeout cannot be cancelled; abandoning it is the cancel. A debounce is a `go-loop` that keeps the current `timeout` channel and replaces it on each input. Since the deadline is recomputed from a loop variable on every input, the duration can change at runtime for free — the loop reads it from a channel or an atom.

Threads come from `go` (a fixed pool; running `go` on virtual threads, ASYNC-262, was reverted in `1.9.847-alpha3` per the [README][async-readme]), `thread` (`:mixed` workload), `io-thread` (virtual threads when available, ASYNC-272, `:io`), and `pipeline` workers. [`core.async.flow`][async-flow] adds a `:workload` per process (`:io`, `:compute`, `:mixed`), with `:compute` transforms submitted to a separate executor ([`doc/flow-guide.md`][async-flow-guide]).

---

## Concurrency and cancellation

**Transducers have no cancellation.** `reduced` is the only way to stop, and it is a _downstream_ decision (the consumer has enough), not an outside cancel. The process honours it and still runs completion: `transduce` calls `(f ret)` unconditionally ([L7217][clj-transduce]); `TransformerIterator` calls `xf.invoke(null)` after a `reduced`; a channel whose transducer returns `reduced` runs `abort` — committing pending puts as `true` and closing itself ([`impl/channels.clj` L58–71][async-abort]) — and `close!` then runs the completion arity `(add! buf)` once the puts are drained ([L255][async-close]).

**core.async has no cancellation either.** There is no `cancel` or `interrupt` anywhere in [`async.clj`][async-clj]. A `go` block is reclaimed only when unreachable: _"The resources associated with a go block may be reclaimed, and the block never resumed, when the channels with which it interacts are no longer referenced"_ ([`go` docstring, L485][async-go]). A `thread` or `io-thread` _"must terminate ordinarily, and will keep referenced resources alive until they do"_ ([L538][async-go]). Latest-wins is therefore written by hand — a flag the worker polls, a generation number on the result — and is [cancel-and-forget][concepts-cancel-join]: nothing waits for the superseded worker.

**`pipeline*` is where concurrency meets transducers**, and it shows the price ([L573–621][async-pipeline]). Each element gets its own `(chan 1 xf ex-handler)`: the element is put, the channel closed, the results drained. So the transducer is instantiated _per element_, and the docstring says so: _"Because it is parallel, the transducer will be applied independently to each element, not across elements, and may produce zero or more outputs per input"_. `dedupe` or `take` in a `pipeline` sees one element and forgets it — _"stateful transducer functions will likely not be useful"_ ([`doc/reference.md`][async-ref]). Order is kept by a `results` channel of per-job promise channels. `pipeline-async` takes no transducer: it takes `af`, a function of `(v, result-chan)` that must close the channel. That is a callback, not a reducing-function transformer — asynchrony does not fit the step shape.

**CPU-bound work** goes to `thread`/`pipeline` (`:compute`); a transducer that does heavy work on a channel's put path stalls whoever is putting.

---

## Errors and completion

There is no error arity. A transducer throws; the process decides. `transduce` propagates the exception and skips completion. A channel catches it in `add!` and calls `ex-handler`; _"any non-nil return value will be placed in the channel"_ ([`chan` docstring][async-chan]); without a handler the exception surfaces on whichever thread ran the put or take ([`doc/reference.md`][async-ref]). `pipeline*` passes its `ex-handler` to each per-element channel, so a failing element yields a substitute value or nothing, and the pipeline continues.

Completion is a value-level event: the completion arity flushes state (`partition-all`) and finalises the accumulator (`completing`'s `cf`, e.g. `persistent!`). A channel's completion runs on `close!`, so **closing a channel flushes it**: a `(chan 10 (partition-all 3))` closed after four puts delivers `[1 2 3]` and then `[4]`. Closing is the only stop signal core.async has, so "input ended" and "producer gave up" are the same event and both flush. `halt-when` ([L8079][clj-halt-when]) shows how much the protocol strains when it must carry a result as well as a stop: it smuggles `{::halt v}` through the accumulator and unpacks it in completion.

---

## State and sharing

A transducer owns only per-application state, so the multicast and sharing questions belong to the process. core.async's answers are channel shapes: `mult` + `tap` ([L797][async-mult]) to broadcast (the slowest tap paces all), `pub`/`sub` for topic routing, `sliding-buffer 1` ([L103][async-chan]) as [conflation][concepts-conflation], and `promise-chan` as a write-once cell. There is no observable value cell; idiomatic Clojure keeps state in an `atom` with `add-watch`, outside the transducer world.

One placement detail matters for us: a channel's transducer wraps the buffer's `add!`, so it runs at _put_ time, _before_ the sliding buffer drops anything. `dedupe` on a `sliding-buffer` channel therefore sees every put, while a taker sees a conflated subset. A stage placed after a conflating node sees only the survivors, which makes `scan` (or a counting `take`) observe a different sequence depending on take timing.

---

## Lifetime and ownership

Nothing is owned. A transducer is an immutable function; its state lives in the closure the process created and dies with that process (an `eduction` re-creates it on every `reduce`). core.async has no scopes: lifetime is channel reachability (for `go`) or the body returning (for threads), and teardown is `close!` cascading through `pipe`/`pipeline`'s `close?` flags (default `true`). A forgotten `thread` leaks until it returns. [`core.async.flow`][async-flow] (alpha, 2025–2026) is the library's own answer: a flow graph owns its processes and channels and gives them a lifecycle (`::flow/start`, `stop`, `pause`, `resume`) through a `transition` arity on the step function ([`doc/flow-guide.md`][async-flow-guide]).

---

## Testing

Transducers are the easiest part of the stack to test: `(into [] xf [1 1 2 3 3])` is a pure, synchronous call with no clock or thread, and the same `xf` then runs unchanged on a channel. That is the decoupling's practical payoff. core.async has no [virtual time][concepts-virtual-time]: `timeout` is wall-clock on a global daemon thread with 10 ms resolution, so a debounce test either sleeps or injects the timeout channel factory by hand. Flow step functions are pure `(state, in, msg) -> [state' outs]` and are, per the guide, _"tested in isolation"_ ([`doc/flow.md`][async-flow]).

---

## The worked pipeline

The element logic is transducers; debounce, latest-wins and the toggle are one `go-loop` process over `alts!`, which is what core.async idiom leaves to the user:

```clojure
(require '[clojure.core.async :as a] '[clojure.string :as str])

(def query-ch   (a/chan (a/sliding-buffer 1) (comp (map str/trim) (dedupe))))  ; xform on puts
(def delay-ch   (a/chan (a/sliding-buffer 1)))
(def enabled-ch (a/chan (a/sliding-buffer 1) (dedupe)))
(def result-ch  (a/chan (a/sliding-buffer 1)))                                   ; the UI polls this

(defn start-hash! [q gen]               ; latest-wins by hand: a flag the worker polls
  (let [stop (volatile! false)]
    {:stop stop
     :ch   (a/thread (when-some [h (hash-fileset q #(deref stop))]   ; nil = observed stop
                       [gen q h]))}))

(a/go-loop [{:keys [enabled delay q last-in tmo job gen] :as s}
            {:enabled true :delay 300 :gen 0}]
  (let [ports (cond-> [enabled-ch delay-ch query-ch]
                tmo       (conj tmo)
                (:ch job) (conj (:ch job)))
        [v port] (a/alts! ports :priority true)]       ; toggle first on ties
    (condp = port
      enabled-ch (if v
                   (recur (assoc s :enabled true))
                   (do (some-> job :stop (vreset! true))         ; flag the hash, do not wait
                       (recur (assoc s :enabled false :tmo nil :job nil))))
      delay-ch   (recur (cond-> (assoc s :delay v)                ; re-aim from the same anchor
                          tmo (assoc :tmo (a/timeout (max 0 (- (+ last-in v) (now-ms)))))))
      query-ch   (if enabled
                   (recur (assoc s :q v :last-in (now-ms) :tmo (a/timeout delay)))
                   (recur s))
      tmo        (let [g (inc gen)]                               ; debounce fired
                   (some-> job :stop (vreset! true))              ; cancel-and-forget
                   (recur (assoc s :tmo nil :gen g :job (start-hash! q g))))
      (:ch job)  (do (when (and v (= (first v) gen))             ; drop stale generations
                       (a/>! result-ch (rest v)))
                     (recur (assoc s :job nil))))))
```

The UI thread reads `(a/poll! result-ch)` each frame — non-blocking, returns `nil` when nothing is new — and a `take!` callback on the same channel can call `wakeIn(0)` so an idle UI repaints.

Event trace:

1. **Keystroke during the debounce.** `put!` on `query-ch` runs `(map str/trim)` then `(dedupe)` on the putting thread under the channel lock; a duplicate is dropped there and never wakes the loop. Otherwise the sliding buffer holds it, `alts!` returns it, the loop stamps `last-in` and replaces `tmo` with a fresh `(a/timeout delay)`. The old timeout channel is abandoned; it closes later into nothing.
2. **Keystroke during the hash.** Same as (1): the hash keeps running, because latest-wins is tied to the _debounced_ query. When the new timeout fires, the old job's `stop` is set, a new `thread` starts with `gen + 1`, and the old thread's eventual result arrives on a channel no longer in `ports` — or, if it raced in first, is dropped by the generation check. Nothing joins the old thread; if `hash-fileset` never polls the flag, it runs to the end.
3. **Interval change.** `delay-ch` delivers `v`; if a debounce is armed, a new timeout is computed from the original `last-in` anchor, so the change lengthens or shortens the pending wait rather than restarting it. The 10 ms timer coalescing is the precision floor.
4. **Toggle off.** `:priority true` puts `enabled-ch` first, so a toggle beats a simultaneous timeout. The loop drops `tmo` (the pending debounce is forgotten), flags the job, and clears `:job` so its result port leaves `ports`. The hash thread finishes when it next polls; nothing waits for it.

Fit with a per-frame UI: good at the edges — transducers on the input channels are synchronous, allocation-light filters, and `poll!` is exactly a frame-polled read. Poor in the middle — the process is a hand-written state machine, cancellation is a convention, and there is no join, so "toggle off" cannot promise the CPU is idle.

### The D angle: one stage, three processes

The question for the D library is whether `map`/`filter`/`scan`/`dedupe` can be written once and run on a D range, a fiber pull stream (`Step next(ref FiberContext, ref T)`) and `Channel`/`Cell` events. The transducer answer is yes, provided the stage is a template over its downstream, so the composed pipeline is one concrete struct with static calls: `@nogc`, `nothrow` and inlining are inferred through it, where Clojure pays an `IFn` call and a boxed value per stage. The Gatherer shape passes the downstream _per call_ rather than storing it (state and `Downstream` are separate arguments to `integrate`), and that suits D's `scope`/dip1000 rules better: a stage never holds a pointer into the process that drives it. An uncompiled sketch:

```d
enum Step { value, done, cancelled }

// A stage: state is the struct's fields, created fresh when a process copies it in.
// `put` returns false when downstream wants no more (Clojure's `reduced`).
struct Map(alias f)
{
    enum maxOut = 1;                          // outputs per step: lets a pull adaptor use one slot
    bool step(D, T)(ref D down, T x) => down.put(f(x));
    void finish(D)(ref D down) {}
}

struct Dedupe(T)
{
    enum maxOut = 1;
    private bool seen;
    private T prev;
    bool step(D)(ref D down, T x)
    {
        if (seen && x == prev) return true;
        seen = true;
        prev = x;
        return down.put(x);
    }
    void finish(D)(ref D down) {}
}

struct Chunk(T, size_t n)                     // partition-all: the one that needs finish
{
    enum maxOut = 1;
    private T[n] buf;
    private size_t len;
    bool step(D)(ref D down, T x)
    {
        buf[len++] = x;
        if (len < n) return true;
        len = 0;
        return down.put(buf[]);
    }
    void finish(D)(ref D down) { if (len) down.put(buf[0 .. len]); }  // flush on normal end only
}

// Process 1: a D range, pushed through a sink (an output range with `bool put`).
void transduce(R, X, D)(R r, X xf, ref D sink)   // xf by value: fresh state per run
{
    for (; !r.empty; r.popFront)
        if (!xf.step(sink, r.front)) return;      // downstream stopped: no flush
    xf.finish(sink);                              // upstream ended: flush
}

// Process 2: a fiber pull stream. The TransformerIterator problem, with a one-slot buffer.
struct Via(S, X, T, U)                            // T = upstream element, U = output
{
    S src;
    X xf;
    private struct Slot { U v; bool full; bool put(U x) { v = x; full = true; return true; } }
    private Slot slot;
    private bool ended;

    Step next(ref FiberContext ctx, ref U out)
    {
        static assert(X.maxOut == 1, "a stage with maxOut > 1 needs a queue here");
        while (!slot.full)
        {
            if (ended) return Step.done;
            T x;
            final switch (src.next(ctx, x))       // may park the fiber
            {
                case Step.value:     if (!xf.step(slot, x)) ended = true; break;
                case Step.done:      xf.finish(slot); ended = true; break;
                case Step.cancelled: return Step.cancelled;  // no flush, no emission
            }
        }
        slot.full = false;
        out = slot.v;
        return Step.value;
    }
}

// Process 3: push events (a Channel drained on a fiber, a Cell change callback, a frame):
// call xf.step(downstream, event) per event and xf.finish(downstream) on close.
```

Five conclusions follow from the comparison:

- **Source independence is real for per-element stages, and it is the only part that is.** `map`, `filter`, `dedupe`, `scan`, `take`, `takeWhile` and chunking fit; `debounce`, `switchLatest`/`mapLatest`, `merge`, `combineLatest` and `race` do not, for the reasons in [the table above](#what-can-and-cannot-be-a-transducer). They are processes, and in our design they are stream operators that own a fiber or a `Scope`, as `go`/`pipeline*` own threads in core.async.
- **Push vs pull is reconciled by the adaptor, not the stage.** `std.algorithm` is pull: `map` and `filter` wrap the _source_. A transducer wraps the _sink_. The pull adaptor (`Via` above, `TransformerIterator` in Clojure) costs one buffer whose capacity is the stage's maximum outputs per input, so `maxOut` is a design-by-introspection hook: one slot for `map`/`filter`/`dedupe`/`scan`, a queue only for `flatMap`-like stages. On a stackful fiber the adaptor can park inside `src.next`, so the stage never knows it is asynchronous.
- **Three endings, not two.** Clojure has _input ended_ (flush, then complete) and _downstream stopped_ (`reduced`: discard pending state, still complete). Our `Step` adds `cancelled`. The mapping: upstream `done` → `finish` (flush) → `done`; downstream stop → no flush, release upstream, `done`; `cancelled` → no `finish` and no emission. Resource release on cancel is the stage's destructor and the `Scope`'s teardown, not a protocol arity. Clojure needs completion after `reduced` because completion also _finalises the accumulator_ (`persistent!`); our sinks finalise themselves as the `Effect` result, so the stage-level `finish` only flushes, and a flush after a cancel would emit into a pipeline that no longer exists. Gatherers agree: the finisher runs after a short-circuit (guarded by `isRejecting()`) and not after an exception.
- **State is created at application, so a pipeline value is a recipe.** Copying the stage struct into the process is Clojure's `(xform rf)` call. Building a pipeline twice yields independent state, as `eduction` re-runs. `pipeline*` is the counter-example to avoid: re-instantiating per element silently disables `dedupe`/`scan`.
- **Placement relative to conflation changes meaning.** A stage before a `Cell` sees every change; after it, a conflated subset. `map`/`filter`/`dedupe` are indifferent; `scan`, counting `take` and chunking are not, so on a `Cell` they belong upstream of the write, or must be documented as sampling.

---

## Related designs: Java Stream Gatherers

JEP 485 (Viktor Klang; previewed as JEP 461 in JDK 22 and JEP 473 in JDK 23; _"We here propose to finalize the API in JDK 24, without change"_) adds `Stream::gather(Gatherer)`: _"`Stream::gather(Gatherer)` is to intermediate operations what `Stream::collect(Collector)` is to terminal operations"_ ([JEP 485][jep485]). A [`Gatherer`][jdk-gatherer] is four functions, matching the transducer arities one for one with one addition:

| Transducer                       | Gatherer                                                 | Note                                                                                                                                                                 |
| -------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| state allocated in `(fn [rf] …)` | `initializer()` → `A`                                    | Called when the op begins (`GathererOp`'s sink `begin`, [L150][jdk-gathererop])                                                                                      |
| step `(result, input)`           | `integrator().integrate(A state, T element, Downstream)` | Returns `boolean`: `false` is `reduced`                                                                                                                              |
| `(rf result x)`                  | `downstream.push(r)` → `boolean`                         | `isRejecting()` asks without pushing                                                                                                                                 |
| completion `(result)`            | `finisher()` `(A, Downstream) -> void`                   | Run in `end()` ([L179][jdk-gathererop]); _"Once a state object is passed to the combiner or finisher function, it is never passed to the integrator function again"_ |
| — (reducers' `combinef`)         | `combiner()`                                             | Enables parallel evaluation; `defaultCombiner()` means sequential only                                                                                               |

The differences are instructive. State and downstream are _arguments_, not closure captures, and the contract forbids keeping them: _"Implementations of Gatherer must not capture, retain, or expose to other threads, the references to the state instance, or the downstream `Downstream` for longer than the invocation duration of the method which they are passed to"_ ([`Gatherer.java`][jdk-gatherer]). Default values (`defaultInitializer`, `defaultFinisher`, `Integrator.ofGreedy`) are sentinels the runtime compares against to skip calls — introspection by identity, the JVM's version of `static if`. Short-circuit is _"interpreted just as if there were no more elements"_, so the finisher still runs; `windowFixed` ([`Gatherers.java` L87][jdk-gatherers-window]) guards its flush with `!downstream.isRejecting()`, the same discard-pending-state rule as Clojure's. Underneath, Java 8 streams were already push: [`Sink`][jdk-sink] (`begin`/`accept`/`end`/`cancellationRequested`) is a transducer chain with the source pulled once through a `Spliterator`.

`Gatherers.mapConcurrent(maxConcurrency, mapper)` ([L350][jdk-gatherers-mapconc]) is the one built-in that brings concurrency into a stage, and it shows where the stage contract ends. It starts one virtual thread per element, keeps a deque of in-flight `FutureTask`s, preserves input order, and on short-circuit or failure does **cancel-and-join**: _"First signal cancellation for all tasks in progress"_ (`task.cancel(true)`) and _"Then wait for all in progress task Threads to exit"_ (`thread.join()`). It is bounded, ordered concurrency (core.async's `pipeline-blocking`), not latest-wins: nothing in the integrate-per-element contract can cancel the previous element's task because a new one arrived without breaking order. Time-based gatherers are absent from `Gatherers` (`fold`, `mapConcurrent`, `scan`, `windowFixed`, `windowSliding`), and the JEP's goals stop at _"allow custom intermediate operations to manipulate streams of infinite size"_.

Naming: `Gatherer`/`Gatherers` mirrors `Collector`/`Collectors` (interface plus a factory class), families are noun-first (`windowFixed`, `windowSliding`), and factories split `of` (parallel-capable) from `ofSequential`. The JEP declines to grow `Stream` itself: _"We will not add a new intermediate operation to the `Stream` class for each of the built-in gatherers defined in the `Gatherers` class, even though for the sake of uniformity it is tempting to do so. In order to preserve the learnability of the `Stream` class we will consider adding new intermediate operations to it only after experience suggests that they are broadly useful."_ The JEP's _"Alternatives"_ section points to a separate design document this survey did not locate. Whether the JEP cites Clojure transducers as an influence is **not stated in the JEP text**; the resemblance is structural.

---

## Strengths

- One definition of each element operator for every carrier; core.async deleted its own family in favour of them.
- A tiny, explicit protocol (three arities, `reduced`, completion exactly once) that a new process can implement from the reference alone.
- Per-application state makes a transformation a reusable value; `eduction` is a cold recipe for free.
- Trivially testable: `(into [] xf input)` is pure and synchronous.
- Gatherers show the shape survives static typing and adds parallelism (`combiner`) and a built-in bounded-concurrency stage with cancel-and-join.

## Weaknesses

- Time, concurrency and multiple inputs fall outside the model; the interesting operators of a UI pipeline are all processes, written by hand in core.async.
- No cancellation, in transducers or core.async: `reduced` is consumer-side only, `close!` flushes rather than aborts, threads cannot be stopped.
- `pipeline*` re-instantiates the transducer per element, silently disabling stateful stages.
- Channel transducers run under the channel lock on an arbitrary thread; a slow stage stalls producers.
- Arity overloading (`(map f)` vs `(map f coll)`) and right-to-left `comp` with left-to-right data flow are recurring confusions; `halt-when` shows the accumulator protocol straining to carry a result.

---

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                            | Trade-off                                                                                   |
| ----------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Transform the reducing function, not the source       | One operator for collections, seqs, iterators, channels              | Only per-element logic fits; time/concurrency/multi-input stay as processes                 |
| Three arities: init, step, completion                 | Completion lets stateful stages flush and accumulators finalise      | Completion "exactly once" is a process obligation that processes get wrong (CLJ-2556)       |
| Early stop via a `reduced` box                        | Lets `take` stop an infinite source without exceptions               | Downstream-only; no outside cancel; every nested loop must convey it (`preserving-reduced`) |
| State created when the process applies the transducer | The transducer stays an immutable, shareable value                   | `pipeline*` applies per element, so stateful stages degrade silently                        |
| Same name, shorter arity (`(map f)`)                  | No second vocabulary; seq code converts by deleting the collection   | Not currying, but looks like it; a dynamically typed mistake returns a function             |
| Channel `xform` wraps the buffer's `add!`             | Transformation happens once per put, before buffering/conflation     | Runs under the channel mutex on the putter's or taker's thread; must not block              |
| Gatherers pass state and `Downstream` as arguments    | No captured references; sentinel defaults let the runtime skip calls | More verbose than closures; the JEP concedes it is less succinct than built-in operations   |
| `mapConcurrent` cancels and joins on short-circuit    | No orphaned virtual threads after the stream stops                   | Bounded, ordered concurrency only; latest-wins is not expressible as a gatherer             |

---

## Sources

- Clojure source at `92ce2a8`: [`src/clj/clojure/core.clj`][clj-core] (`map`, `filter`, `take`, `partition-by`, `partition-all`, `dedupe`, `cat`, `halt-when`, `completing`, `transduce`, `into`, `sequence`, `eduction`, `reductions`, `volatile!`, `reduced`), [`TransformerIterator.java`][clj-ti], [`Reduced.java`][clj-reduced-java], [`Volatile.java`][clj-volatile-java], [`changes.md`][clj-changes].
- core.async source at `8e6e382`: [`async.clj`][async-clj], [`impl/channels.clj`][async-channels], [`impl/protocols.clj`][async-protocols], [`impl/timers.clj`][async-timers], [`doc/reference.md`][async-ref], [`doc/rationale.md`][async-rationale], [`doc/flow.md`][async-flow], [`doc/flow-guide.md`][async-flow-guide].
- JDK source at `c35f741`: [`Gatherer.java`][jdk-gatherer], [`Gatherers.java`][jdk-gatherers], [`GathererOp.java`][jdk-gathererop], [`Sink.java`][jdk-sink], [`Stream.java`][jdk-stream].
- [Clojure reference: Transducers][ref]; Rich Hickey, [_Transducers are Coming_][blog], 2014-08-06; Rich Hickey, [_Transducers_, Strange Loop 2014][talk] (video; not transcribed for this survey).
- [JEP 485: Stream Gatherers][jep485] (Closed / Delivered, JDK 24).
- Siblings: [RxJS][rxjs] (operators as source-wrapping functions), [Kotlin Flow][kotlin-flow] (`transform` as the universal stage), [Rust streams][rust-streams] (`Stream` adaptors, `select!`), [fs2][fs2] (`Pipe` as a stream function), [C++ senders/receivers][cpp-senders-receivers] (receiver-wrapping algorithms, the closest structural cousin), [concepts][concepts], [comparison][comparison].

<!-- References -->

[clj-repo]: https://github.com/clojure/clojure/tree/92ce2a8524286f765be29779fdc6f96891453dd9
[clj-epl]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/epl-v10.html
[clj-pom]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/pom.xml
[clj-changes]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/changes.md
[clj-core]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj
[clj-volatile]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L2570-L2591
[clj-sequence]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L2692
[clj-map]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L2772
[clj-filter]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L2838
[clj-reduced]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L2881-L2904
[clj-take]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L2906
[clj-stream-transduce]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7078
[clj-completing]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7205
[clj-transduce]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7217
[clj-into]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7234
[clj-partition-by]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7564
[clj-reductions]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7618
[clj-partition-all]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L7644
[clj-cat]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L8060-L8077
[clj-halt-when]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L8079
[clj-dedupe]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L8103
[clj-eduction]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/clj/clojure/core.clj#L8130-L8150
[clj-ti]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/jvm/clojure/lang/TransformerIterator.java
[clj-reduced-java]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/jvm/clojure/lang/Reduced.java
[clj-volatile-java]: https://github.com/clojure/clojure/blob/92ce2a8524286f765be29779fdc6f96891453dd9/src/jvm/clojure/lang/Volatile.java
[async-repo]: https://github.com/clojure/core.async/tree/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b
[async-license]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/LICENSE
[async-readme]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/README.md
[async-clj]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj
[async-chan]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L91-L148
[async-go]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L485-L551
[async-pipeline]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L573-L660
[async-pipe-todo]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L623
[async-transduce]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L683-L707
[async-onto-chan]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L752-L763
[async-mult]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L797
[async-map]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L1045
[async-merge]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L1083
[async-take]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L1109
[async-deprecated]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async.clj#L1127-L1131
[async-channels]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async/impl/channels.clj
[async-abort]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async/impl/channels.clj#L58-L71
[async-close]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async/impl/channels.clj#L255-L281
[async-channels-chan]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async/impl/channels.clj#L289-L306
[async-protocols]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async/impl/protocols.clj
[async-timers]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/src/main/clojure/clojure/core/async/impl/timers.clj
[async-ref]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/doc/reference.md
[async-rationale]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/doc/rationale.md
[async-flow]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/doc/flow.md
[async-flow-guide]: https://github.com/clojure/core.async/blob/8e6e382d9eefaa3054bfa3834d4e6dbc413cbe2b/doc/flow-guide.md
[jdk-repo]: https://github.com/openjdk/jdk/tree/c35f74179474524a5fa013f6f425691fea3e0cf6
[jdk-license]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/LICENSE
[jdk-gatherer]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/Gatherer.java
[jdk-gatherers]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/Gatherers.java
[jdk-gatherers-window]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/Gatherers.java#L87
[jdk-gatherers-mapconc]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/Gatherers.java#L350
[jdk-gathererop]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/GathererOp.java#L150-L200
[jdk-sink]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/Sink.java
[jdk-stream]: https://github.com/openjdk/jdk/blob/c35f74179474524a5fa013f6f425691fea3e0cf6/src/java.base/share/classes/java/util/stream/Stream.java
[ref]: https://clojure.org/reference/transducers
[blog]: https://clojure.org/news/2014/08/06/transducers-are-coming
[talk]: https://www.youtube.com/watch?v=6mTbuzafcII
[jep485]: https://openjdk.org/jeps/485
[rxjs]: ./rxjs.md
[kotlin-flow]: ./kotlin-flow.md
[rust-streams]: ./rust-streams.md
[fs2]: ./fs2.md
[cpp-senders-receivers]: ./cpp-senders-receivers.md
[concepts]: ./concepts.md
[concepts-cancel-join]: ./concepts.md#cancel-and-join-and-cancel-and-forget
[concepts-conflation]: ./concepts.md#conflation
[concepts-virtual-time]: ./concepts.md#virtual-time
[comparison]: ./comparison.md
