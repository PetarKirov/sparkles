# Apache Pekko Streams (Scala / Java)

The Apache-licensed fork of Akka Streams. A stream is an immutable _blueprint_ (`Source`, `Flow`, `Sink`, `RunnableGraph`) that does nothing until a `Materializer` turns it into running `GraphStageLogic` state machines, fused into actors, wired by Reactive Streams demand. Each `run()` also returns a typed _materialized value_.

| Field             | Value                                                                                                                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Scala 2.13 / 3 with a parallel Java DSL; Java 17+ ([`releases-2.0.md`][rn-2-0])                                                                                                                                                 |
| License           | Apache-2.0 ([`LICENSE`][pekko-license])                                                                                                                                                                                         |
| Repository        | [apache/pekko][pekko-repo], module `stream/` (+ `stream-testkit/`, `stream-typed/`)                                                                                                                                             |
| Documentation     | [pekko.apache.org/docs/pekko/current/stream/][pekko-docs], sources in [`docs/src/main/paradox/stream/`][docs-index]                                                                                                             |
| Category          | Pull-demand (Reactive Streams) dataflow graphs with explicit materialization, run by an actor-hosted graph interpreter                                                                                                          |
| Versions surveyed | `main` at `df133f7de2d5` (2026-11-23). The newest upstream tag is `v2.0.0-RC1`, and the tree already carries the `2.0.0` release notes. Version numbers come from `@since` tags and the release notes                           |
| Core abstraction  | `Graph[S <: Shape, +M]`, specialised as `Source[+Out, +Mat]`, `Flow[-In, +Out, +Mat]`, `Sink[-In, +Mat]` and `RunnableGraph[+Mat]`; user operators are `GraphStage` + `GraphStageLogic` with `InHandler`/`OutHandler` callbacks |

> [!NOTE]
> **Why Pekko rather than Akka.** On September 7, 2022 Lightbend announced that _"The new license for Akka is the Business Source License (BSL) v1.1"_. Under it each release becomes Apache 2.0 only after three years ([Bonér, "Why we are changing the license for Akka"][akka-bsl]). Pekko's README says it _"is a fork of [Akka] 2.6.x, prior to the Akka project's adoption of the Business Source License. Pekko 2.x now contains most of the features up to and including Akka 2.9.0 (Apache 2.0 Licensed now)"_ ([`README.md`][pekko-readme]). This survey cites the code we can freely read and copy from. Apart from the additions noted below (`switchMap`, `doOnCancel`, `Sink.source`), the Streams design is the same as Akka's.

---

## Overview

### What it solves

Pekko Streams handles bounded-memory processing of possibly infinite sequences across asynchronous boundaries: sockets, files, actors, other Reactive Streams libraries. Back-pressure is guaranteed end to end. It is the transport layer under Pekko HTTP, Pekko Connectors and Artery remoting. The model is one where the same pipeline description is built in one place, shared freely, and run many times elsewhere ([`stream-flows-and-basics.md`][flows-basics]):

> _"no data will flow through it until it is materialized. Materialization is the process of allocating all resources needed to run the computation described by a Graph (in Pekko Streams this will often involve starting up Actors). Thanks to Flows being a description of the processing pipeline they are immutable, thread-safe, and freely shareable"_

### Design philosophy

The design-principles page is unusually explicit ([`general/stream/stream-design.md`][stream-design]):

> _"Pekko is built upon a conscious decision to offer APIs that are minimal and consistent—as opposed to easy or intuitive. The credo is that we favor explicitness over magic, and if we provide a feature then it must work always, no exceptions."_

It then states the consequence that drives the whole API:

> _"The representation of these pieces must therefore be an immutable blueprint that is materialized in an explicit step in order to start the stream processing. … The process of materialization will often create specific objects that are useful to interact with the processing engine once it is running, for example for shutting it down or for extracting metrics. This means that the materialization function produces a result termed the materialized value of a graph."_

Two further principles matter for sparkles. First, **Reactive Streams is treated as an SPI, not an API.** `Source`/`Sink`/`Flow` deliberately do not extend `Publisher`/`Subscriber`, so that _"Pekko Streams to perform optimizations like fusing and dispatcher configuration during the materialization step"_. Second, **libraries must return blueprints, not run them**. _"compositionality would be destroyed if different libraries only accepted operators and expected to materialize them … materialization can only happen once"_ ([`stream-design.md`][stream-design]).

---

## How it works

**Blueprint layer.** Every piece is a `Graph[S, M]`: a `Shape` (its typed `Inlet`s/`Outlet`s) plus a traversal builder, and a materialized-value type `M`. `Source` has one outlet, `Sink` one inlet, `Flow` one of each, and `BidiFlow` two of each ([`stream-design.md`][stream-design]). Attaching both ends gives a `RunnableGraph[Mat]`. Linear composition is `via`/`to`; non-linear composition is `GraphDSL` (below). Graphs are values: _"since operators are immutable, connecting them returns a new operator"_ ([`stream-flows-and-basics.md`][flows-basics]).

**Materialization.** `run()`, `runWith(sink)` and sugar such as `runForeach` are the _"terminal operations"_. _"Materialization is performed synchronously on the materializing thread by an `ActorSystem` global `Materializer`"_ ([`stream-flows-and-basics.md`][flows-basics]). For each `GraphStage` the materializer calls `createLogic(attributes)`, producing a fresh `GraphStageLogic` per run: _"All mutable state needs to be confined to the GraphStageLogic that is created for every materialization"_ ([`stream-customize.md`][customize]).

**Fusion and islands.** By default all operators are _fused_ into one `GraphInterpreter` hosted by one actor (`ActorGraphInterpreter`). Elements are passed by direct method calls, and _"fused stream operators do not run in parallel to each other, meaning that only up to one CPU core is used for each fused part"_ ([`stream-flows-and-basics.md`][flows-basics]). `.async` adds an `Attributes.asyncBoundary` that closes an _island_: _"attributes always work by adding information to the flow graph that has been constructed up to this point"_. Each island is a separate actor, and islands exchange batched Reactive Streams demand with input buffers between them (`initial-input-buffer-size = 4`, `max-input-buffer-size = 16` in [`reference.conf`][reference-conf]).

**The interpreter.** [`GraphInterpreter.scala`][graph-interpreter] keeps a table of `Connection`s, one per outlet→inlet edge. Each holds a `portState` bitfield (`InReady`, `Pulling`, `Pushing`, `OutReady`, `InClosed`, `OutClosed`, `InFailed`), a `slot` for the in-flight element, failure or cancellation cause, and the two handlers. _"there can be only one event in flight for a given Connection"_. A `pull`/`push` flips the bits and enqueues the connection on a circular event queue. `execute(eventLimit)` drains it by calling the target handler's `onPull`/`onPush`. The `sync-processing-limit = 1000` setting interrupts long synchronous runs so the actor stays responsive ([`reference.conf`][reference-conf]).

```scala
// The three linear building blocks and what each type parameter means.
val src:  Source[Int, NotUsed]                 = Source(1 to 10)               // Out = Int, Mat = NotUsed
val dbl:  Flow[Int, Int, NotUsed]              = Flow[Int].map(_ * 2)          // In, Out, Mat
val sum:  Sink[Int, Future[Int]]               = Sink.fold(0)(_ + _)           // In, Mat = the result
val g:    RunnableGraph[Future[Int]]           = src.via(dbl).toMat(sum)(Keep.right)
val r1:   Future[Int]                          = g.run()                       // run #1
val r2:   Future[Int]                          = g.run()                       // run #2: new actors, new Future
```

---

## Evaluation model

**Pull-demand with push delivery ("dynamic push/pull").** Between islands, Reactive Streams `request(n)` bounds what a publisher may send. The docs call the result _"'dynamic push / pull mode', since it will switch between push and pull based back-pressure models depending on the downstream being able to cope"_ ([`stream-flows-and-basics.md`][flows-basics]). Inside a fused island the same rule holds at granularity 1. An outlet may be pushed only after `onPull`, and `pull` twice before a push throws: _"There can only be one outstanding request at any given time"_ ([`GraphStage.scala` `pull`][gs-pull]).

**Lazy and cold.** A blueprint is inert; each materialization is an independent running instance with fresh state and a fresh materialized value. Hot sources such as `Source.queue`, `Source.actorRef` and `MergeHub.source` are hot _per materialization_. Their "handle" exists only as a materialized value.

**Not a value-propagation model.** There are no derived cells, so glitch-freedom does not apply. `zipLatest`/`mergeLatest`/`combineLatest`-style operators emit on every input, and the 2.0 notes list _"MergeLatest does not backpressure upstreams and buffers without bound"_ as a known issue ([`releases-2.0.md`][rn-2-0-known]). Propagation inside an island is synchronous and depth-first through the event queue. Across islands it is batched by demand windows.

## Composition

Linear composition uses methods on `Source`/`Flow` (`map`, `filter`, `mapAsync`, `via`, `to`). Fan-in/fan-out and cycles use `GraphDSL`, a mutable builder that is sealed into an immutable graph:

```scala
val g = RunnableGraph.fromGraph(GraphDSL.createGraph(Sink.seq[Int]) { implicit b => out =>
  import GraphDSL.Implicits._
  val bcast = b.add(Broadcast[Int](2))    // fan-out: every element to every output
  val merge = b.add(Merge[Int](2))        // fan-in: first-come
  Source(1 to 3) ~> bcast ~> Flow[Int].map(_ + 1)  ~> merge ~> out
                    bcast ~> Flow[Int].map(_ * 10) ~> merge
  ClosedShape
})
```

The junctions in [`scaladsl/Graph.scala`][scaladsl-graph] are `Merge`, `MergePreferred`, `MergePrioritized`, `Interleave`, `MergeSorted`, `Concat`, `OrElse`, `MergeSequence`, `Zip`/`ZipWith`/`ZipLatest`/`ZipN` (fan-in), and `Broadcast`, `Balance`, `Partition`, `WireTap`, `Unzip`/`UnzipWith` (fan-out). `~>` is defined on port ops for an inlet, a `Flow`, a uniform fan-in or a fan-out shape ([`Graph.scala#L1849`][graph-tilde]). `GraphDSL.create` has an arity-N overload family generated from [`GraphApply.scala.template`][graph-apply]; it exists only to thread the N materialized values in.

**Operator surface.** The [operator index][ops-index] lists 231 rows in 17 categories (row counts at this SHA; an operator offered on `Source` and `Flow` is one row):

| Category                                     | Rows | Examples                                                                      |
| -------------------------------------------- | ---: | ----------------------------------------------------------------------------- |
| Source operators                             |   37 | `single`, `tick`, `queue`, `unfold`, `lazySource`, `future`                   |
| Sink operators                               |   35 | `foreach`, `fold`, `seq`, `last`, `queue`, `source`                           |
| Additional Sink and Source converters        |    8 | `asInputStream`, `fromJavaStream`                                             |
| File IO Sinks and Sources                    |    2 | `FileIO.fromPath`, `toPath`                                                   |
| Simple operators                             |   51 | `map`, `filter`, `scan`, `statefulMap`, `throttle`, `take`                    |
| Flow operators composed of Sinks and Sources |    2 | `Flow.fromSinkAndSource`, `…Coupled`                                          |
| Asynchronous operators                       |    4 | `mapAsync`, `mapAsyncUnordered`, `mapAsyncPartitioned{,Unordered}`            |
| Timer driven operators                       |    7 | `delay`, `delayWith`, `initialDelay`, `groupedWithin`, `takeWithin`           |
| Backpressure aware operators                 |    8 | `conflate`, `conflateWithSeed`, `batch`, `batchWeighted`, `expand`, `buffer`  |
| Nesting and flattening operators             |    9 | `flatMapConcat`, `flatMapMerge`, `switchMap`, `flatMapPrefix`, `groupBy`      |
| Time aware operators                         |    5 | `idleTimeout`, `completionTimeout`, `keepAlive`                               |
| Fan-in operators                             |   21 | `merge`, `zip`, `zipLatest`, `mergeLatest`, `concat`, `orElse`                |
| Fan-out operators                            |    4 | `Broadcast`, `Balance`, `Partition`, `Unzip`                                  |
| Watching status operators                    |    2 | `watchTermination`, `monitor`                                                 |
| Actor interop operators                      |   16 | `ActorFlow.ask`, `ActorSource.actorRef`                                       |
| Compression operators                        |    6 | `gzip`, `deflate`, `zstd`                                                     |
| Error handling                               |   14 | `recover`, `recoverWithRetries`, `onErrorResume`, `RestartSource.withBackoff` |

Each operator page carries a fixed _"Reactive Streams semantics"_ callout: **emits** when / **backpressures** when / **completes** when / **cancels** when. The same four lines appear in every Scaladoc ([`switchMap.md`][switchmap-doc]). It is the most transferable documentation convention in this survey.

### API structure and naming

**Source / transform / sink are three types, separated by shape.** The separation is _static_ (a `Shape` with one outlet, one inlet+outlet, or one inlet), not a separate API layer. Transforms are written once in the `FlowOps[+Out, +Mat]` trait and shared by `Source`, `Flow`, `SubFlow` and `SubSource` through an abstract type member: `type Repr[+O] <: FlowOps[O, Mat]`, and `type Closed` (_"result of closing a Source is RunnableGraph, closing a Flow is Sink"_) ([`Flow.scala#L853`][flowops]). So `source.map(f)` returns a `Source` and `flow.map(f)` returns a `Flow` from one method body. That is the Scala equivalent of our "operator returns a concrete struct" rule. `FlowOpsMat` adds the `ReprMat[+O, +M]`/`ClosedMat[+M]` members for operators that change `Mat` ([`Flow.scala#L4097`][flowopsmat]). Sources are factories on the `Source` companion; sinks are factories on `Sink`. Running is on the blueprint (`run`, `runWith`, `runFold`, `runForeach` are `Sink.xxx` sugar).

**Type parameters.** `In` is the element type consumed and `Out` the type produced (contravariant / covariant in `scaladsl`). `Mat` is the value `run()` hands back for this piece, `NotUsed` when there is none. `NotUsed` is a sealed singleton type rather than `Unit`, so Java has a nameable value ([`NotUsed.scala`][notused]).

**The `Mat` plumbing family.** Every combinator that joins two graphs comes in two forms. The plain one keeps the left value; the `…Mat` twin takes a combine function `(Mat, Mat2) => Mat3`, usually `Keep.left`, `Keep.right`, `Keep.both` or `Keep.none` ([`Materialization.scala`][keep]). `scaladsl/Flow.scala` alone has 27 such twins: `viaMat`, `toMat`, `zipMat`, `zipWithMat`, `zipLatestMat`, `zipLatestWithMat`, `zipAllMat`, `mergeMat`, `mergeLatestMat`, `mergePreferredMat`, `mergePrioritizedMat`, `mergeSortedMat`, `interleaveMat`, `concatMat`, `concatLazyMat`, `prependMat`, `prependLazyMat`, `orElseMat`, `alsoToMat`, `wireTapMat`, `divertToMat`, `monitorMat`, `flatMapPrefixMat`, `joinMat`, `fromSinkAndSourceMat`, `fromSinkAndSourceCoupledMat` and `fromProcessorMat`. The `viaMat` doc even asks users to prefer `Keep.left`/`Keep.right` as _"internally optimized"_ ([`Flow.scala#L4097`][flowopsmat]).

That is the ergonomic cost. Three hot sources merged give `((Q1, Q2), Q3)` nested tuples. Escape hatches have kept arriving to avoid threading a value to the top: `preMaterialize` (obtain a `Source`'s value _before_ wiring it), `mapMaterializedValue`, and in 2.0 `Sink.source`/`materializeIntoSource` ([`releases-2.0.md`][rn-2-0-streams]). `MergeHub.source` has type `Source[T, Sink[T, NotUsed]]`, a source whose materialized value _is_ a sink, and `BroadcastHub.sink` is the mirror ([`Hub.scala#L77`][hub-merge], [`#L487`][hub-broadcast]). The model is coherent, but a reader must type-check two parallel pipelines (elements and materialized values) in every expression.

> [!NOTE]
> The "ergonomic complaint" is inferred from the API's own shape: the twin count, the escape hatches added over time, and the nested `Keep.both` tuples in the project's own tests ([`FlowSwitchSpec.scala`][switch-spec]). No upstream design document conceding it was found at this SHA.

**Variant naming families** (all from `scaladsl/Flow.scala`):

| Suffix / prefix             | Meaning                                             | Examples                                                                     |
| --------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------- |
| `xxxMat`                    | also combine materialized values                    | `viaMat`, `zipMat`, `alsoToMat`                                              |
| `flatMapXxx`                | flattening _strategy_ named in the suffix           | `flatMapConcat`, `flatMapMerge`, `flatMapPrefix`; latest-wins is `switchMap` |
| `flattenXxx`                | the same, for an already-nested stream              | `flattenMerge`                                                               |
| `xxxUnordered`              | drop order preservation                             | `mapAsyncUnordered`, `mapAsyncPartitionedUnordered`                          |
| `xxxWithin`                 | bounded by a time window                            | `groupedWithin`, `takeWithin`, `dropWithin`                                  |
| `xxxWeighted`               | bounded by a cost function rather than a count      | `batchWeighted`, `groupedWeighted`, `groupedWeightedWithin`, `limitWeighted` |
| `xxxWith`                   | the "user function" variant of a fixed one          | `zipWith`, `zipLatestWith`, `delayWith`, `conflateWithSeed`                  |
| `xxxLatest`                 | combine the latest value of each side               | `zipLatest`, `mergeLatest`                                                   |
| `xxxLazy` / `lazyXxx`       | defer the other side's materialization until needed | `concatLazy`, `prependLazy`; `Source.lazySource`, `lazyFuture`, `lazySingle` |
| `xxxAll`                    | n-ary form taking a sequence                        | `mergeAll`, `interleaveAll`, `concatAllLazy`, `alsoToAll`                    |
| `onErrorXxx` / `recoverXxx` | failure handling                                    | `onErrorComplete`, `onErrorResume`, `onErrorContinue`, `recoverWithRetries`  |
| `doOnXxx`                   | side-effect taps                                    | `doOnFirst`, `doOnCancel`                                                    |

**A user-defined operator** is either a composition (`def debounced[T](d: FiniteDuration): Flow[T, T, NotUsed] = Flow[T].switchMap(…)`, returned as a reusable blueprint, per the library rule) or a `GraphStage`. The `GraphStage` is the one place where Pekko's contract resembles our `Step next(ref FiberContext, ref T)`, so it is analysed in detail here:

```scala
final class TakeWhileLatest[T](p: T => Boolean) extends GraphStage[FlowShape[T, T]] {
  val in  = Inlet[T]("in");  val out = Outlet[T]("out")
  override val shape = FlowShape(in, out)
  override def createLogic(attrs: Attributes) = new GraphStageLogic(shape) with InHandler with OutHandler {
    override def onPull(): Unit = pull(in)                       // demand flows up
    override def onPush(): Unit = {                              // an element arrived
      val x = grab(in)
      if (p(x)) push(out, x) else completeStage()
    }
    // inherited defaults: onUpstreamFinish = completeStage(); onUpstreamFailure(ex) = failStage(ex);
    //                     onDownstreamFinish(cause) = cancelStage(cause)
    setHandlers(in, out, this)
  }
}
```

- **Inverted control.** The stage never asks "give me the next value". It receives `onPull` (downstream wants one), calls `pull(in)`, and later receives `onPush` and calls `grab`/`push`. One `next()` call in our design is split into a request half and a reply half. That split is what lets one interpreter thread multiplex many stages without fibers. In our design the fiber stack does that job, so `next` can simply block.
- **Termination is three distinct callbacks**, matching our `Step` arms: `onUpstreamFinish()` corresponds to `done`, `onUpstreamFailure(ex)` to an error value, and `onDownstreamFinish(cause: Throwable)` to `cancelled`, _with a cause_ ([`GraphStage.scala#L2115`][gs-handlers]). The defaults complete, fail or cancel the whole stage. Cancellation is upstream-flowing, distinct from completion, and carries a reason (`SubscriptionWithCancelException.NoMoreElementsNeeded` versus `StageWasCompleted` versus a real error; [`GraphStage.scala#L735`][gs-pull]).
- **Port state machines are enforced at run time.** `push` before `onPull`, or `pull` twice, throws `IllegalArgumentException` ([`#L872`][gs-push]). The docs draw the legal transitions as state diagrams ([`stream-customize.md`][customize]). Our `Step` return type encodes the same protocol in the type, so it cannot be violated.
- **Teardown is `postStop`, not the handlers.** _"This is the only tear down callback that is guaranteed to happen, if the actor system or the materializer is terminated the handlers may never see any callbacks"_ ([`GraphStage.scala#L550`][gs-logic]). This matches scope-exit cleanup in a structured design.
- **Foreign threads enter through `getAsyncCallback`**, which marshals a value back onto the interpreter: _"the passed handler will be invoked eventually in a thread-safe way by the execution environment"_ ([`#L1433`][gs-async]). Timers come from `TimerGraphStageLogic.scheduleOnce(key, delay)`, whose `afterPostStop` cancels every outstanding timer ([`#L1952`][gs-timer]). The concurrency guarantee is actor-like: _"The callbacks exposed by all of these classes are never called concurrently"_ ([`stream-customize.md`][customize]).

**The Scala/Java split.** `javadsl` is a parallel set of wrapper classes. `javadsl.Flow[In, Out, Mat](delegate: scaladsl.Flow[In, Out, Mat])` is invariant and forwards each method by hand, for example `def switchMap(…) = new Flow(delegate.switchMap(o => sourceGraph(f(o))))` ([`javadsl/Flow.scala#L381`][jflow], [`#L3053`][jflow-switchmap]). The wrappers are large: `javadsl/Flow.scala` 4,725 lines and `javadsl/Source.scala` 5,152, against 4,574 and 1,152 for `scaladsl`. Every operator is written twice, and the docs show every signature twice (`@apidoc[…] { scala="…" java="…" }`). 2.0 spent a release cleaning the Java side: _"Java APIs no longer leak Scala types"_, wildcard bounds added _"without casts or `upcast`"_, and `pekko.japi.function` types used throughout ([`releases-2.0.md`][rn-2-0]).

**Regrets, renames and removals.** 2.0 removed _"the Future based operators, stream converters, `OverflowStrategy.dropNew`, `SubstreamCancelStrategy`, the old `splitWhen`/`splitAfter` overloads, `GraphStage.onDownstreamFinish()` and the stream testkit `probe` methods"_ ([`releases-2.0.md#L384`][rn-2-0-removed]). The cause-less `onDownstreamFinish()` was replaced by `onDownstreamFinish(cause)`, so cancellation now always carries a reason. `TestSource.probe` became `TestSource()`. `gunzip` was replaced by `gzipDecompress` ([`#L269`][rn-2-0-streams]). The `Source.queue(bufferSize, overflowStrategy)` overloads are deprecated because their _"asynchronous `offer` can hang indefinitely under `OverflowStrategy.backpressure`"_. The replacement `Source.queue(bufferSize)` gives a `BoundedSourceQueue` with synchronous feedback ([`Source.scala#L1014`][source-queue-deprecated], [`migration-guide-1.x-2.x.md`][migration-2]). `switchMap` itself was only added in 1.2.0 ([`releases-1.2.md#L74`][rn-1-2]), so for about a decade the Akka/Pekko line had no latest-wins flatten.

## Time and scheduling

All time comes from the `ActorSystem` scheduler. `TimerGraphStageLogic.scheduleOnce` calls `interpreter.materializer.scheduleOnce`, which calls `system.scheduler.scheduleOnce` ([`PhasedFusingActorMaterializer.scala#L472`][materializer-schedule]). Timer callbacks re-enter the stage as async events. Operators run on the actor's dispatcher, which can be selected per island with `ActorAttributes.dispatcher(...)` or `.async(dispatcher)`. There is no frame clock.

**There is no `debounce`.** `git grep -i debounce` over the whole tree returns nothing. The time operators are `delay`, `delayWith`, `initialDelay`, `groupedWithin`, `throttle`, `idleTimeout` and `keepAlive`, plus the rate adapters `conflate`/`batch`/`expand`. None of these restarts a timer on every input. A trailing restart-on-input debounce is written with the latest-wins flatten:

```scala
def debounce[T](d: => FiniteDuration): Flow[T, T, NotUsed] =
  Flow[T].switchMap(x => Source.single(x).initialDelay(d))   // `d` re-read per element
```

`initialDelay` is a `TimerGraphStageLogic` that calls `scheduleOnce(GraphStageLogicTimer, delay)` in `preStart` and pulls only after `onTimer` ([`Timers.scala#L210`][timers-initial]). Each element materializes a fresh substream, so **the duration can change at runtime**: `d` is evaluated when the substream is built. The old substream's timer dies in `afterPostStop` when `switchMap` cancels it. `delayWith(() => DelayStrategy[T], …)` is the built-in per-element dynamic delay ([`delayWith.md`][delaywith-doc]), but it delays every element rather than dropping superseded ones. `throttle` (token bucket over `TimerGraphStageLogic`, [`impl/Throttle.scala`][throttle-impl]) and `conflate` are rate limiters, not debouncers.

## Concurrency and cancellation

**Latest-wins: `switchMap` (since 1.2.0).** The doc: _"the current (now previous) substream is cancelled while the `Source` resulting from the input element is subscribed to and flattened into the output stream … (which is why this operator is sometimes also called 'flatMapLatest')"_. Its callout says **backpressures: never** ([`switchMap.md`][switchmap-doc], [`Flow.scala#L2898`][flow-switchmap]). The implementation [`Switch.scala`][switch-impl] always `tryPull(in)`s after a push. On each new element, `setupCurrentSource` calls `src.cancel()` on the current `SubSinkInlet`, discards it, and immediately calls `subFusingMaterializer.materialize(...)` on the new source. Empty sources are not materialized at all (the 1.2.0 fix _"Avoid materialize an empty source in switchMap"_, [`releases-1.2.md`][rn-1-2]). The test suite states the contract: _"not wait for the previous / non-last substream to complete"_ and _"cancel previous substream once a next substream arrives"_ ([`FlowSwitchSpec.scala`][switch-spec]).

**Cancel does not wait.** Cancellation is a signal: the cancelled substream's stages get `onDownstreamFinish(cause)` and then `postStop`, while the new substream is already running. Nothing joins the old one, and there is no "cancel and await" primitive anywhere in the stage API.

**How cancellation reaches running work, and where it stops.** Cancellation reaches every _stage_ upstream, and timers and stage-owned resources are released in `postStop`. It does **not** reach a computation started by `mapAsync`. `MapAsync` registers `future.onComplete(holder)` and has no `postStop` cancellation ([`Ops.scala#L1355`][mapasync-impl]), and Scala's `Future` has no cancel at all. The work runs to completion, and its result is posted to a stopped stage and dropped. CPU-bound work therefore runs as `mapAsync(parallelism)(x => Future(work(x))(blockingEc))`, where `parallelism` is the in-flight bound. Making it cancellable means passing a token yourself. `doOnCancel((cause, wasNormal) => …)`, added in 1.3.0, is the hook to flip that token ([`Flow.scala#L1634`][flow-doOnCancel]). The alternative, `.async` plus a dedicated dispatcher, moves a fused island to other threads, but a running `map` callback still cannot be interrupted.

**External cancellation: kill switches.** `KillSwitches.single[T]` is a pass-through `Flow` whose materialized value is a `UniqueKillSwitch`. It _"always controls that graph and operator which yielded the materialized value"_. `KillSwitches.shared(name)` is created _before_ materialization and controls every flow it is placed in. Both expose `shutdown()` (complete downstream, cancel upstream) and `abort(ex)` (fail downstream) ([`KillSwitch.scala`][killswitch]). The kill switch is how a UI toggle kills a whole running graph from outside.

## Errors and completion

The design separates _errors_ (data elements) from _failures_ (`onError`, the stream collapsing). _"data elements emitted before a failure can still be lost if the `onError` overtakes them"_, because failure must be able to tear down a back-pressured stream ([`stream-design.md`][stream-design]). Recovery operators act as _"a bulkhead that confines a stream collapse to a given region of the stream topology"_: `recover`, `recoverWithRetries`, `mapError`, `onErrorComplete`/`Resume`/`Continue`.

**Supervision** (`Supervision.Stop` / `Resume` / `Restart`, [`Supervision.scala`][supervision]) is set as an attribute, but each operator must implement it: _"if there is nothing in the documentation of an operator saying that it adheres to the supervision strategy it means it fails rather than applies supervision"_ ([`stream-error.md`][stream-error]). 2.0 is still adding support to `batch`, `expand` and `groupedWeightedWithin` ([`releases-2.0.md`][rn-2-0-streams]). `Restart` means _"accumulated state is cleared"_. **`RestartSource.withBackoff(settings)(() => source)`** / `onFailuresWithBackoff` re-materializes a source factory with exponential backoff ([`RestartSource.scala#L46`][restart-source]). Completion of a running graph is observed through a materialized value (`Sink.seq`'s `Future`, `watchTermination`'s `Future[Done]`).

## State and sharing

There is **no value cell** and no "current value" concept. Values live inside stages (`scan`, `statefulMap`) or outside the stream. Conflation is an operator: `conflate((_, b) => b)` keeps the latest element while downstream is slow, `batch`/`batchWeighted` bound the summary, and `expand`/`extrapolate` repeat the last element for a faster downstream ([operator index][ops-index]).

Fan-out within one graph is explicit (`Broadcast`, `Balance`, `Partition`). Every materialized processor accepts a single subscriber, and _"all fan-out is done using explicit elements like `Broadcast[T]`"_ ([`stream-design.md`][stream-design]). Dynamic multicast across independently materialized graphs uses hubs: `BroadcastHub.sink` (materializes a `Source` that consumers attach to), `MergeHub.source` (materializes a `Sink` that producers attach to) and `PartitionHub` ([`Hub.scala`][hub-merge]).

## Lifetime and ownership

A running graph is owned by its island actors, which are children of the materializer's supervisor. Its lifetime is the graph's: it ends when every stage has stopped. A stage stops when all its ports are closed (unless `setKeepGoing(true)`), and `postStop` is the guaranteed cleanup hook ([`GraphStage.scala#L550`][gs-logic]). A materializer created inside an actor (`Materializer(context)`) ties all its streams to that actor and stops them when the actor stops ([`stream-flows-and-basics.md`][flows-basics]). That is the nearest thing to a structured scope, and it is per-materializer, not lexical.

Leaks happen in three ways: a never-terminated infinite stream with no kill switch, a materialized value (`BoundedSourceQueue`, `UniqueKillSwitch`) dropped on the floor, and in-flight `Future`s that outlive cancellation. The 2.0 notes include memory-retention fixes (_"Release references to completed stage logics and to the initial interpreter shell"_, [`releases-2.0.md`][rn-2-0]).

## Testing

`stream-testkit` provides `TestSource[T]()` and `TestSink[T]()` ([`TestSource.scala`][test-source], [`TestSink.scala`][test-sink]). They materialize to `TestPublisher.Probe`/`TestSubscriber.Probe`, which script demand and signals (`request`, `sendNext`, `sendError`, `expectNext`, `expectRequest`, `expectCancellation`). These are themselves an instance of the materialized-value pattern. The `switchMap` suite uses them to observe cancellation directly:

```scala
val (mainPub, probe) =
  TestSource[Source[Int, NotUsed]]().switchMap(identity).toMat(TestSink())(Keep.both).run()
val subPub = TestPublisher.probe[Int]()
probe.request(1)
mainPub.sendNext(Source.fromPublisher(subPub))
subPub.expectRequest()
mainPub.sendError(new Exception("buh"))
subPub.expectCancellation()
```

**Virtual time is a process-wide scheduler swap.** Setting `pekko.scheduler.implementation = "org.apache.pekko.testkit.ExplicitlyTriggeredScheduler"` replaces the `ActorSystem` scheduler. `timePasses(d)` then runs due tasks on the calling thread ([`ExplicitlyTriggeredScheduler.scala`][ets]). The typed testkit wraps the swap as `ManualTime.config` and `ManualTime().timePasses(d)` ([`ManualTime.scala`][manual-time]). Stream timers ride on the system scheduler, so a debounce is testable deterministically. `stream-tests` does this for `aggregateWithBoundary`, with a telling caveat: _"To run multiple tests in parallel using simulated timer, the tests must be in separate Specs with different instances of the ActorSystem"_ ([`AggregateWithBoundarySpec.scala#L173`][aggregate-spec]). The clock is global to the system, not scoped to the test. Pekko's stream testkit page ([`stream-testkit.md`][stream-testkit]) does not mention virtual time.

## The worked pipeline

One `BoundedSourceQueue` carries tagged UI events. `statefulMap` folds them into commands, and `switchMap` gives the debounce, the latest-wins hash and the toggle in one operator, because emitting `Source.empty` cancels whatever is running.

```scala
sealed trait Ev
final case class Query(q: String)             extends Ev
final case class Interval(n: FiniteDuration)  extends Ev
final case class Enabled(on: Boolean)         extends Ev

sealed trait Cmd
final case class Run(q: String, n: FiniteDuration) extends Cmd
case object Stop                                   extends Cmd

final case class St(n: FiniteDuration, on: Boolean, last: Option[String])

val hashEc: ExecutionContext = system.dispatchers.lookup("hash-dispatcher")   // CPU pool
val latest = new AtomicReference[Option[Digest]](None)                        // read by the UI each frame

val (ui, done) =
  Source.queue[Ev](bufferSize = 64)                                           // Mat: BoundedSourceQueue[Ev]
    .statefulMap(() => St(250.millis, on = true, last = None))(
      (s, ev) => ev match {
        case Query(q)    => val s2 = s.copy(last = Some(q)); (s2, if (s.on) Some(Run(q, s.n)) else None)
        case Interval(n) => (s.copy(n = n), None)                             // affects the *next* debounce
        case Enabled(b)  => (s.copy(on = b),
                             if (!b) Some(Stop) else s.last.map(Run(_, s.n)))
      },
      _ => None)
    .collect { case Some(c) => c }
    .switchMap {
      case Stop        => Source.empty                                       // cancels debounce + hash
      case Run(q, n)   =>
        val cancelled = new AtomicBoolean(false)                              // per-query token
        Source.single(q)
          .initialDelay(n)                                                    // the debounce
          .mapAsync(parallelism = 1)(q => Future(hashFileSet(q, cancelled))(hashEc))
          .doOnCancel((_, _) => cancelled.set(true))                          // cancel -> token
    }
    .toMat(Sink.foreach(d => { latest.set(Some(d)); wakeUi() }))(Keep.both)
    .run()

ui.offer(Query("ab"))    // from the UI thread; returns QueueOfferResult synchronously
```

**Trace.**

1. _Keystroke during debounce._ `ui.offer(Query("abc"))` returns `Enqueued` at once. On the stream actor, `statefulMap` emits `Run("abc", n)` and `Switch.onPush` calls `cancelCurrentSource()`. The old substream gets `onDownstreamFinish(NoMoreElementsNeeded)` through `doOnCancel` (which sets a token nobody is using yet) and `mapAsync`, then reaches `initialDelay`. Its `postStop` → `afterPostStop` cancels the pending timer. A new substream is materialized with a fresh `n` timer. The input is dropped and nothing is hashed.
2. _Keystroke during hash._ Same path, but the old `mapAsync` holds a running `Future`. `doOnCancel` sets `cancelled`, and the stage stops at once without waiting. The worker keeps hashing until `hashFileSet` next polls the flag. Meanwhile the new substream's debounce timer is already running, so for a while two hashes can occupy `hashEc`. The old result, if it arrives, goes to a stopped `AsyncCallback` and is discarded. Latest-wins holds for _output_, but not for _resources_.
3. _Interval change._ `statefulMap` stores `n` and emits nothing, so a pending debounce keeps its old deadline and the next query uses the new `n`. Restarting the pending timer with the new duration would mean emitting `Run(last, n)` instead. That also restarts an in-flight hash, because `switchMap` cannot tell "same query, new delay" apart from a new query.
4. _Toggle off._ `Stop` reaches `switchMap`, which cancels the current substream (debounce timer or hash token, as above). It then sees `Source.empty` via `TraversalBuilder.isEmptySource` and materializes nothing. Queries while off only update `last`. _Toggle on_ re-runs the last query. A heavier alternative wraps the graph in `KillSwitches.single` and re-materializes on enable, which loses all stage state.

**Fit with a per-frame UI.** The fit is reasonable but indirect. The stream runs on actor threads, so the UI must cross threads twice. Input goes in through `BoundedSourceQueue.offer`, which is synchronous and frame-friendly. Output comes back through an `AtomicReference` plus a wake, or through `Sink.queue`'s `pull(): Future[Option[T]]`. Every handle the UI needs (`ui`, `done`, a kill switch) exists only as a materialized value of one `run()`. A widget tree rebuilt every frame must store them across frames and must never re-run the blueprint. There is no frame clock and no conflating "current value" sink built in, and the debounce and the cancellation token are both user code.

---

## Strengths

- **Blueprint/run separation is total and principled.** Graphs are immutable values that can be shared and run many times. Libraries return blueprints, and resources are acquired only at materialization. This is the cleanest statement of "description versus running" in the survey.
- **One trait, many shapes.** `FlowOps` with `type Repr[+O]` writes each operator once for `Source`, `Flow` and `SubFlow`, each returning its own concrete type.
- **`GraphStage` is a well-specified, documented operator SPI.** It has explicit port state machines, three distinct termination callbacks, cancellation with a cause, a guaranteed `postStop`, actor-like non-concurrency and an async-callback door.
- **Operator documentation discipline.** A categorised index of about 230 entries, plus fixed emits/backpressures/completes/cancels callouts on every operator.
- **Bounded by construction.** Demand bounds every hop, every buffer is explicit (`buffer`, `conflate`, `batch`), and fusion makes the common case free of per-element messages.

## Weaknesses

- **The materialized-value channel doubles the type-level surface.** There are 27 `xxxMat` twins, `Keep.*` tuples, arity-generated `GraphDSL.create`, and a stream of escape hatches (`preMaterialize`, `Sink.source`).
- **There is no structured cancellation of user work.** `Future`s are not cancellable, `mapAsync` cannot stop them, `switchMap` does not wait for the cancelled substream, and resources overlap after a switch.
- **There is no debounce and no value cell.** Latest-wins arrived only in 1.2.0. UI-shaped streams are assembled from `switchMap`, `initialDelay` and an outside `AtomicReference`.
- **The Java DSL is a hand-maintained mirror.** About 10,000 lines of forwarding code, two signatures per operator in the docs, and a major version spent fixing leaked Scala types.
- **Supervision is opt-in per operator**, and absence means "fails"; users must check each operator's page.
- **Virtual time is per `ActorSystem`**: tests that use it cannot share a system or run in parallel inside one.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                          | Trade-off                                                                          |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Immutable blueprints, explicit materialization              | Reuse, shareability, library composability; optimisation at materialize time       | Handles to a running stream exist only as materialized values                      |
| A typed `Mat` channel on every graph                        | Expose control objects (queues, kill switches, results) type-safely                | `xxxMat` twins, `Keep` combinators, nested tuples; a second pipeline to type-check |
| Reactive Streams as hidden SPI                              | Freedom to fuse and swap `java.util.concurrent.Flow`; hard-to-implement SPI hidden | Interop needs explicit `asPublisher`/`fromSubscriber` adapters                     |
| Fuse by default, `.async` to split                          | No per-element messaging; one actor per island                                     | One core per island; boundaries are coarse attributes, not per-operator            |
| Callback stages (`onPull`/`onPush`) on a shared interpreter | Thousands of stages per thread without stacks                                      | Inverted control; protocol violations are runtime exceptions                       |
| Cancellation as a signal with a cause, no join              | Fast teardown of back-pressured graphs                                             | Cancelled work overlaps new work; `Future`s are never interrupted                  |
| Supervision implemented per operator                        | Only meaningful where state can be dropped/reset                                   | Inconsistent coverage; users read each operator page                               |
| Parallel `scaladsl`/`javadsl` wrappers                      | Idiomatic types (variance, `CompletionStage`, `Optional`) per language             | Double maintenance; Java API lagged and leaked Scala types until 2.0               |

## Sources

- [apache/pekko][pekko-repo] at `df133f7de2d535c138a2ed6c943995ef93ac529d`: [`README.md`][pekko-readme], [`LICENSE`][pekko-license].
- Design and guide pages: [`stream-design.md`][stream-design], [`stream-flows-and-basics.md`][flows-basics], [`stream-customize.md`][customize], [`stream-error.md`][stream-error], [`stream-testkit.md`][stream-testkit], [`operators/index.md`][ops-index], [`switchMap.md`][switchmap-doc], [`delayWith.md`][delaywith-doc].
- Release notes and migration: [`releases-1.2.md`][rn-1-2], [`releases-2.0.md`][rn-2-0], [`migration-guide-1.x-2.x.md`][migration-2].
- Source: [`scaladsl/Flow.scala`][flowops], [`scaladsl/Materialization.scala`][keep], [`scaladsl/Graph.scala`][scaladsl-graph], [`GraphApply.scala.template`][graph-apply], [`scaladsl/Hub.scala`][hub-merge], [`scaladsl/RestartSource.scala`][restart-source], [`scaladsl/Source.scala`][source-queue-deprecated], [`javadsl/Flow.scala`][jflow], [`stage/GraphStage.scala`][gs-handlers], [`impl/fusing/GraphInterpreter.scala`][graph-interpreter], [`impl/fusing/Switch.scala`][switch-impl], [`impl/fusing/Ops.scala`][mapasync-impl], [`impl/Timers.scala`][timers-initial], [`impl/Throttle.scala`][throttle-impl], [`impl/PhasedFusingActorMaterializer.scala`][materializer-schedule], [`KillSwitch.scala`][killswitch], [`Supervision.scala`][supervision], [`reference.conf`][reference-conf], [`NotUsed.scala`][notused].
- Testing: [`TestSource.scala`][test-source], [`TestSink.scala`][test-sink], [`ExplicitlyTriggeredScheduler.scala`][ets], [`ManualTime.scala`][manual-time], [`FlowSwitchSpec.scala`][switch-spec], [`AggregateWithBoundarySpec.scala`][aggregate-spec].
- External: [Pekko Streams documentation][pekko-docs]; Jonas Bonér, [_Why we are changing the license for Akka_][akka-bsl] (September 7, 2022).
- Related deep-dives: [RxJS][rxjs], [Rx.NET][rx-dotnet], [Kotlin Flow][kotlin-flow], [fs2][fs2], [Rust streams][rust-streams], [Swift Async Algorithms][swift-async-algorithms], [Effect-TS][effect-ts], [Cats Effect][ce-deep-dive]; umbrella [index][index], [concepts][concepts], [comparison][comparison]; [async I/O survey][async-io].

<!-- References -->

[pekko-repo]: https://github.com/apache/pekko/tree/df133f7de2d535c138a2ed6c943995ef93ac529d
[pekko-readme]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/README.md
[pekko-license]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/LICENSE
[pekko-docs]: https://pekko.apache.org/docs/pekko/current/stream/
[akka-bsl]: https://akka.io/blog/why-we-are-changing-the-license-for-akka
[docs-index]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/index.md
[stream-design]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/general/stream/stream-design.md
[flows-basics]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/stream-flows-and-basics.md
[customize]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/stream-customize.md
[stream-error]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/stream-error.md
[stream-testkit]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/stream-testkit.md
[ops-index]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/operators/index.md
[switchmap-doc]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/operators/Source-or-Flow/switchMap.md
[delaywith-doc]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/stream/operators/Source-or-Flow/delayWith.md
[rn-1-2]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/release-notes/releases-1.2.md#L74
[rn-2-0]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/release-notes/releases-2.0.md
[rn-2-0-streams]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/release-notes/releases-2.0.md#L261
[rn-2-0-removed]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/release-notes/releases-2.0.md#L384
[rn-2-0-known]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/release-notes/releases-2.0.md#L419
[migration-2]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/docs/src/main/paradox/migration/migration-guide-1.x-2.x.md
[flowops]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Flow.scala#L853
[flowopsmat]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Flow.scala#L4097
[flow-switchmap]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Flow.scala#L2898
[flow-doOnCancel]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Flow.scala#L1634
[keep]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Materialization.scala
[scaladsl-graph]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Graph.scala
[graph-tilde]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Graph.scala#L1849
[graph-apply]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/boilerplate/org/apache/pekko/stream/scaladsl/GraphApply.scala.template
[hub-merge]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Hub.scala#L77
[hub-broadcast]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Hub.scala#L487
[restart-source]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/RestartSource.scala#L46
[source-queue-deprecated]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/scaladsl/Source.scala#L1014
[jflow]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/javadsl/Flow.scala#L381
[jflow-switchmap]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/javadsl/Flow.scala#L3053
[gs-handlers]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/stage/GraphStage.scala#L2115
[gs-logic]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/stage/GraphStage.scala#L550
[gs-pull]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/stage/GraphStage.scala#L735
[gs-push]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/stage/GraphStage.scala#L872
[gs-async]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/stage/GraphStage.scala#L1433
[gs-timer]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/stage/GraphStage.scala#L1952
[graph-interpreter]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/impl/fusing/GraphInterpreter.scala#L231
[switch-impl]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/impl/fusing/Switch.scala
[mapasync-impl]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/impl/fusing/Ops.scala#L1355
[timers-initial]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/impl/Timers.scala#L210
[throttle-impl]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/impl/Throttle.scala
[materializer-schedule]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/impl/PhasedFusingActorMaterializer.scala#L472
[killswitch]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/KillSwitch.scala
[supervision]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/scala/org/apache/pekko/stream/Supervision.scala
[reference-conf]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream/src/main/resources/reference.conf
[notused]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/actor/src/main/scala/org/apache/pekko/NotUsed.scala
[test-source]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-testkit/src/main/scala/org/apache/pekko/stream/testkit/scaladsl/TestSource.scala
[test-sink]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-testkit/src/main/scala/org/apache/pekko/stream/testkit/scaladsl/TestSink.scala
[ets]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/testkit/src/main/scala/org/apache/pekko/testkit/ExplicitlyTriggeredScheduler.scala
[manual-time]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/actor-testkit-typed/src/main/scala/org/apache/pekko/actor/testkit/typed/scaladsl/ManualTime.scala
[switch-spec]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-tests/src/test/scala/org/apache/pekko/stream/scaladsl/FlowSwitchSpec.scala
[aggregate-spec]: https://github.com/apache/pekko/blob/df133f7de2d535c138a2ed6c943995ef93ac529d/stream-tests/src/test/scala/org/apache/pekko/stream/scaladsl/AggregateWithBoundarySpec.scala#L173
[rxjs]: ./rxjs.md
[rx-dotnet]: ./rx-dotnet.md
[kotlin-flow]: ./kotlin-flow.md
[fs2]: ./fs2.md
[rust-streams]: ./rust-streams.md
[swift-async-algorithms]: ./swift-async-algorithms.md
[effect-ts]: ./effect-ts.md
[ce-deep-dive]: ../algebraic-effects/scala-cats-effect.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[async-io]: ../async-io/index.md
