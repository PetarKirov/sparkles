# Testing reactive pipelines

How twenty systems script the inputs of a reactive test and assert its outputs, and
what that means for the `event-horizon` reactive library's harness. Three theme
pages hold the evidence; this page lays out the design space they cover and draws
the conclusions.

**Last reviewed:** November 24, 2026

---

## The design space

A reactive test makes four choices. Each theme page covers a different region of
them.

| Axis               | The options seen in the survey                                                                                                                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Input notation** | a marble string (RxJS, Swift); recorded notifications at ticks (Rx.NET); probe calls (Pekko, Turbine); a frame-indexed plan (Reflex); `(dt, input)` samples (Yampa); plain calls on the system (Effect, Bonsai, our task-DAG)         |
| **Time**           | a virtual-time scheduler in the test (Rx.NET, cats-effect `TestControl`); a clock service per test (Effect); a dispatcher or a process-wide swap (Kotlin, Pekko); frames or samples as time (Reflex, Yampa); patched globals (RxJS 9) |
| **Assertion**      | whole-timeline equality (RxJS, Rx.NET); expect-calls on probes (Pekko, Turbine); outcome values (Effect, cats-effect); a text snapshot or expect block (ppx_expect, insta, expect-test, Bonsai); temporal-logic properties (Yampa)    |
| **Interleavings**  | one fixed order (most); permuted inputs (our task-DAG); a seeded random scheduler (cats-effect, madsim, turmoil, TigerBeetle); systematic exploration (loom, shuttle, Coyote, Lincheck, our `sync/model.d`)                           |

The pages:

- [Stream-library test DSLs][dsls]: RxJS marbles, Rx.NET `TestScheduler`, Swift
  `AsyncSequenceValidation`, Kotlin `runTest` and Turbine, Pekko probes, Effect
  `TestClock` and cats-effect `TestControl`.
- [FRP, UI and snapshot testing][snapshots]: Reflex test plans and `Reflex.Pure`,
  Yampa `embed` and its LTL predicates, ppx_expect with Incremental and Bonsai,
  insta and expect-test, elm-program-test, Compose `MainTestClock`.
- [Deterministic simulation and schedule exploration][simulation]: FoundationDB and
  TigerBeetle, madsim and turmoil, loom and shuttle, Coyote and Lincheck, Hedgehog
  and proptest state machines, and the repository's own harnesses.

---

## What the survey shows

### Cancellation is rarely observable, and joining never is in a notation

Only three systems assert cancellation directly: RxJS (`expectSubscriptions('^--!')`),
Rx.NET (`Subscribe(300, 400)`) and Pekko probes (`expectCancellation()`)
([DSLs § Comparison][dsls-cmp]). In both Rx libraries teardown is synchronous, so
"cancelled" and "finished" are the same event, and **no notation can say "the
cancelled work was joined"**. Join appears only as a value (Effect's and
cats-effect's `Outcome`) or as an ordering property (fs2: the old inner's finalizer
runs before the next inner starts). The FRP and UI systems mostly have nothing to
observe: Reflex and Yampa do not cancel, and elm-program-test has no simulated
`cancel` ([snapshots § Comparison][snap-cmp]).

### Marble strings have documented traps

A value character occupies a frame (RxJS's "subtract 1 ms" rule), a group `(abc)`
advances time by its width, RxJS 7 has two dialects, and Swift restricts values to
`String`. Swift's own newest latest-wins operator, `flatMapLatest`, is tested with
real `Task.sleep` rather than its diagram DSL ([DSLs][dsls-swift]).

### Exhaustive assertion catches what selective assertion misses

Whole-timeline equality and Turbine's `ensureAllEventsConsumed` fail on an extra
emission or a forgotten cancel. A text transcript of every event has the same
property for free. Expect-test systems add the workflow: the actual output is
written beside the expected one (`.corrected`, `.snap.new`) or patched into the
source when an environment variable asks for it (`UPDATE_EXPECT=1`), and **no
system promotes in CI** ([snapshots § Rust][snap-rust],
[snapshots § Jane Street][snap-js]).

### Time that escapes the virtual clock is the commonest complaint

Turbine's wall-clock await timeout grew from none to 1 s to 3 s; `runTest`'s whole-
test timeout from 10 s to 60 s; Pekko probes wait in real time. The systems that
avoid it keep the clock per test (Effect) or detect deadlock instead of hanging
(cats-effect `TestControl`). Off-by-one advancing is the second complaint: Kotlin's
`advanceTimeBy` is half-open, so a task due exactly at the target needs a trailing
`runCurrent()` ([DSLs § Kotlin][dsls-kotlin]).

### One scenario can be scripted and explored

Lincheck runs hand-written scenarios before generated ones, and Hedgehog uses the
same commands for a fixed and a generated sequence. A scripted run asserts an exact
result; an explored run asserts invariants or that the result does not depend on
the schedule ([simulation § Lessons][sim-lessons]). The repository already contains
an explorer for its sync primitives, [`sync/model.d`][sync-model] (DPOR with a
preemption bound, PCT, replay), whose design, not code, carries over to `TestSched`.
Replay is the fragile part: shuttle's replay tests are disabled because the failing
schedule was never printed ([simulation § loom and shuttle][sim-shuttle]).

### Failure output decides whether a long transcript is usable

Swift re-renders both timelines as diagrams; Rx.NET prints aligned
`Expected`/`Actual` lists; insta prints a line-numbered diff. The repository's
[`checkWriter`][buffer] prints the whole expected block and then the whole actual
block, and the task-DAG's transcript test prints only the actual text
([snapshots § Lessons][snap-lessons]).

---

## Conclusions for the harness

1. **Scenarios are plain D calls**, not a marble DSL: no notation expresses join, the
   string DSLs carry their own traps, and calls on cells, the clock and the
   `TestCpuPool` compose with ordinary D control flow.
2. **The assertion is a byte-exact transcript with virtual timestamps**, which is
   exhaustive by construction. Cancellation is three lines: requested, observed by
   the work, and joined.
3. **`checkWriter` gains a real line diff**, so a transcript mismatch shows the first
   diverging line, not two whole blocks.
4. **Expected text can be promoted** from the actual output when an environment
   variable asks for it, using `__FILE__`/`__LINE__` as expect-test does, and never
   in CI.
5. **Time never leaks.** No harness API waits in wall time. A test that awaits with
   no ready fiber, no pending timer and no pending job fails with a deadlock report.
   Advancing to a target runs everything due at the target.
6. **The same scenario runs under a `Chooser`**: choice 0 is today's FIFO order and
   is what the transcript asserts; other strategies (random with a seed, PCT,
   exhaustive within a bound) assert invariants or schedule-independence. A failing
   schedule prints a replay string, and replay has a regression test of its own.

<!-- References -->

[dsls]: ./testing-stream-dsls.md
[dsls-cmp]: ./testing-stream-dsls.md#comparison
[dsls-swift]: ./testing-stream-dsls.md#swift-async-algorithms-asyncsequencevalidation
[dsls-kotlin]: ./testing-stream-dsls.md#kotlin-kotlinx-coroutines-test-and-turbine
[snapshots]: ./testing-frp-and-snapshots.md
[snap-cmp]: ./testing-frp-and-snapshots.md#comparison
[snap-rust]: ./testing-frp-and-snapshots.md#rust-insta-and-expect-test
[snap-js]: ./testing-frp-and-snapshots.md#jane-street-ppx-expect-incremental-and-bonsai
[snap-lessons]: ./testing-frp-and-snapshots.md#lessons-for-the-d-harness
[simulation]: ./testing-deterministic-simulation.md
[sim-lessons]: ./testing-deterministic-simulation.md#lessons-for-the-d-harness
[sim-shuttle]: ./testing-deterministic-simulation.md#loom-and-shuttle-rust-schedule-exploration
[sync-model]: ../../../libs/base/src/sparkles/base/sync/model.d
[buffer]: ../../../libs/base/src/sparkles/base/buffer.d
