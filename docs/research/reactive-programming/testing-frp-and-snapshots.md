# Testing FRP and UI Loops: Frames, Samples and Snapshots

How six systems script the inputs to a reactive program, represent its time, and assert what comes out: frame-indexed plans, sample streams, expect-style transcripts, snapshot files, scripted TEA programs and a frame-stepped UI clock.

> [!NOTE]
> This is a **theme page**: it uses its own spine, not the fixed deep-dive spine.
> It informs open question **Q12.3** of the reactive library design: how a test
> _scripts_ inputs (cell writes, clock advances, CPU-job completions, clicks) and
> _asserts_ outputs (values, cancellations, joins, timings). Every worked test in
> this page is an **untested sketch** in that system's idiom; the APIs it calls are
> cited, the composition is not compiled.

The systems are [Reflex](#reflex-test-plans-and-a-reference-semantics) (frame-numbered `TestPlan`s run against `Reflex.Pure`, an executable denotation, and against the Spider engine), [Yampa](#yampa-sample-streams-and-temporal-logic) (explicit `(dt, input)` sample lists, QuickCheck stream generators and LTL predicates), [Jane Street expect tests](#jane-street-ppx-expect-incremental-and-bonsai) (`ppx_expect` transcripts, and the Bonsai `Handle` that prints one diff per frame), [Rust snapshot testing](#rust-insta-and-expect-test) (`insta` and `expect-test`), [elm-program-test](#elm-elm-program-test) (a whole TEA program scripted through simulated effects), and [Jetpack Compose](#jetpack-compose-maintestclock-and-semantics-assertions) (`MainTestClock`). The local baseline is the task DAG's harness: a scripted `FakeDriver` under `TestSched` and `TestClock`, 120 scrambled completion orders, and a byte-exact transcript ([`task/testing.d`][local-testing], [`task/reporter_plain.d`][local-reporter-plain]).

Each section ends with the same scenario, **"keystroke during hash"**: the query `ab` is debounced 500 ms, then a hash of `ab` starts. The keystroke `abc` arrives while that hash is running, so the old hash must be cancelled, a new debounce must run, and a new hash must produce the result that is shown.

---

## Reflex: test plans and a reference semantics

The semantics suite of [Reflex][reflex-md] (reflex `master` at `f443526bd2a9`, 2026-11-22) is written once against a typeclass and run twice: on `Pure Int`, a denotational model, and on Spider, the production engine.

### Scripting inputs

A test is a value of `TestE a` or `TestB a`, a computation generic over a `TestPlan` instance whose one method schedules occurrences at frame numbers ([`TestPlan.hs`][r-testplan]):

```haskell
class (Reflex t, MonadHold t m, MonadFix m) => TestPlan t m where
  -- | Specify a plan of an input Event firing
  -- Occurrences must be in the future (i.e. Time > 0)
  plan :: [(Word, a)] -> m (Event t a)

planList :: TestPlan t m => [a] -> m (Event t a)
planList xs = plan $ zip [1 ..] xs
```

The Spider instance turns each `plan` into an `EventTrigger` and a `Schedule t = IntMap [Firing t]` ([`Plan/Reflex.hs`][r-plan-reflex]). The Pure instance turns it into `Event (\t -> IntMap.lookup t m)` and records the frame numbers it used ([`Plan/Pure.hs`][r-plan-pure]).

For applications, [reflex-test-host][rth-hackage] (0.1.2.3, last commit 2023-11-25) wraps a network as `AppIn t b e -> TestGuestT t m (AppOut t b e)`. `tickAppFrame` fires one optional input (`These bIn eIn`) and returns every frame the input caused ([`SimpleHost.hs`][rth-simplehost]).

### Representing time

Time is the frame index and nothing else. `Pure t` requires `t` to be dense, and identifies a behaviour with a function `t -> a` and an event with a function `t -> Maybe a` ([`Pure.hs`][r-pure]). The runner makes the schedule dense and adds a final frame _"to observe changes to behaviors after the last event"_ (`makeDense`, `testSchedule` in [`Plan/Reflex.hs`][r-plan-reflex]). Wall-clock operators are outside this model: `Reflex.Time.debounce` needs `TriggerEvent` and `forkIO`s a real `threadDelay` ([`Time.hs`][r-time]). The reflex-test-host README rules the whole class out: _"`TriggerEvent` class constraint is not supported … breaks the "pureness" of the test"_ ([`README.md`][rth-readme]).

### Asserting outputs

An event test produces `IntMap (Maybe a)`, and a behaviour test produces `IntMap a`, one entry per frame. Both are compared with `@?=` against a reference ([`Test.hs`][r-test]). The reference is the pinned list if the test has one, and the Pure result otherwise:

```haskell
data TestMeta v = TestMeta
  { expectedOutput :: Maybe (IntMap v)
  -- ^ When 'Nothing', the Pure implementation is used as the reference.
  , expectedFailures :: [String]
  -- ^ Names of implementations expected to diverge from the reference output.
  }
```

A pinned test reads as a frame transcript ([`Micro.hs`][r-micro]):

```haskell
testE' "switch-1" [(2, "b"), (5, "c"), (7, "d"), (8, "e")] $ do ...
```

**The reference semantics is wired in as a peer implementation.** `implementationLeaves` makes one tasty leaf per backend (`"pure"`, `"spider"`) under the test's name, each asserting the same `reference` ([`Test.hs`][r-test]). `xfail ["spider"]` marks a known divergence with `expectFailBecause`. The older [`CrossImpl.hs`][r-crossimpl] runs a third backend (`Reflex.Profiled`) and checks `identityResult == spiderResult && identityResult == profiledResult`. Promotion is a paste: `semantics -- --dump-expected [prefix]` prints the Pure result as _"a paste-ready `testE'`/`testB'` declaration"_, and `warnMissingExpected` nags about tests that _"pin no expected output and are only checked for agreement against the Pure implementation"_ ([`Test.hs`][r-test], [`semantics.hs`][r-semantics]).

### Concurrency and ordering

None inside a frame. A frame is one `fireEventsAndRead` call, and the outputs are forced with `evaluate . force` ([`Plan/Reflex.hs`][r-plan-reflex]). Simultaneity is part of the semantics (two `plan`s at the same frame coincide), so "ordering" means which frame something lands in. Each tasty leaf is an independent test, so the suite parallelises across cases.

### Cancellation and teardown

A test cannot observe cancellation because Reflex has none to observe: `switch` and `switchHold` stop listening to the old event, and the old work is not cancelled. A test asserts the **absence** of the stale occurrence in the output map. Teardown is checked indirectly: the harness calls `performGC` before every frame ([`CrossImpl.hs`][r-crossimpl], `testSchedule` in [`Plan/Reflex.hs`][r-plan-reflex]), and separate executables (`test/GC.hs`, `test/behaviorLeak.hs`) probe leaks.

### Failure output

On failure you get HUnit's `expected:`/`but got:` rendering of two `IntMap`s, with no diff. `CrossImpl` prints its own report: `Pure result:`, `Spider result:`, `Profiled result:` as `show`n maps, one per line ([`CrossImpl.hs`][r-crossimpl]). Long maps are compared by eye.

### Regrets and limits

- `Pure` evaluates every behaviour as a memoised function of the frame number (`memo` in [`Pure.hs`][r-pure]), so plans stay small: the micro tests span about ten frames ([`Micro.hs`][r-micro]).
- No virtual wall clock. Every timed operator is either untestable here or must be rewritten over an injected tick event (see [`reflex.md` § Testing][reflex-md-testing]).
- The pinned lists exist because agreement alone is weak. If both backends are wrong in the same way the test passes, which is why `warnMissingExpected` exists.

### Worked test: keystroke during hash

The debounce is rewritten over a planned tick event (one frame = 100 ms), and hash completions are scripted. The plan can only show that the stale result never surfaces:

```haskell
-- UNTESTED sketch. debounceTicks: fires the last value after n quiet ticks.
keystrokeDuringHash :: (String, TestCase)
keystrokeDuringHash = testE' "keystroke-during-hash" [(15, "H(abc)")] $ do
  query <- plan [(1, "ab"), (8, "abc")]              -- typed at 100 ms and 800 ms
  tick  <- plan [(t, ()) | t <- [2 .. 16]]           -- 100 ms per frame
  done  <- plan [(10, ("ab", "H(ab)")), (15, ("abc", "H(abc)"))]
  start <- debounceTicks 5 tick query                -- frames 6 and 13
  inFlight <- hold Nothing (Just <$> start)          -- latest-wins by tagging
  pure $ attachWithMaybe
    (\cur (q, h) -> if cur == Just q then Just h else Nothing) inFlight done
-- A second testE' pins `start` itself: [(6, "ab"), (13, "abc")].
```

---

## Yampa: sample streams and temporal logic

[Yampa][yampa-md] (`master` at `9dda03030c4e`, 2026-10-21) has no host loop to drive in a test. A signal function is a pure value, and `embed` runs it on a list.

### Scripting inputs

`embed :: SF a b -> (a, [(DTime, Maybe a)]) -> [b]` takes an initial sample and then `(dt, Maybe a)` steps, where `Nothing` means "input unchanged". `deltaEncode :: Eq a => DTime -> [a] -> (a, [(DTime, Maybe a)])` builds such a list from equally spaced samples ([`Simulation.hs`][y-sim]). Step-by-step evaluation (`evalAtZero`, `evalAt`, `evalFuture`) is documented as _"intended only for debugging/testing … it also breaks the FRP abstraction by making samples discrete and step based"_ ([`Simulation.hs`][y-sim]). yampa-test 0.15.1 adds `SignalSampleStream a = (a, [(DTime, a)])` with `sMerge`, `sConcat` and `sRefine` ([`Stream.hs`][y-stream]).

### Representing time

Time is the sum of the `dt`s in the input. Because `dt` is data, a test can choose it, refine it (`sRefine`) or generate it. `FRP.Yampa.QuickCheck` draws streams from a `Distribution` (`DistConstant`, `DistNormal (avg, stddev)`, `DistRandom`), a `Range` of `dt` bounds and a `Length` given as a sample count or a total time ([`QuickCheck.hs`][y-qc]).

### Asserting outputs

The regression suite compares `embed` output with literal lists. `testSF1 sf = take 25 (embed sf (deltaEncodeBy (~=) 0.25 [0.0..]))`, with `~=` an epsilon equality class `REq` over floats, tuples, `Maybe` and `Event` ([`TestsCommon.hs`][y-common], [`Delays.hs`][y-delays]). The second style is temporal logic: `TPred a` has `SP (SF a Bool)`, `And`, `Or`, `Not`, `Implies`, `Always`, `Eventually`, `Next` and `Until`, and `evalT :: TPred a -> SignalSampleStream a -> Bool` ([`LTLFuture.hs`][y-ltl]). It is combined with QuickCheck:

```haskell
propPre = forAll initialValueG $ \initialValue ->
  forAll myStream $ evalT $
    Next $ Always $ SP $ (==) <$> pre <*> iPre initialValue
```

([`Delays.hs`][y-delays]). Past-time LTL is a set of monitor SFs (`sofarSF`, `everSF`, `lastSF`, `untilSF`) in [`LTLPast.hs`][y-ltlpast]. The approach is the ICFP 2017 paper _Testing and Debugging Functional Reactive Programming_ (cited from [`yampa-test.cabal`][y-cabal]; [DOI][y-paper]).

### Concurrency and ordering

There is none. One SF is stepped by one caller, so the input list _is_ the total order.

### Cancellation and teardown

Not applicable as such. Latest-wins is a `switch`/`dSwitch` that discards the old continuation, which then becomes garbage. A test sees only the outputs. "The old hash was dropped" is expressible as an LTL property over outputs, not as an observed cancellation.

### Failure output

There is no diff. A literal-list test fails as QuickCheck's `Falsified` with the shrunk counterexample stream printed by `show`. An `evalT` property says only `False`, because `evalT` returns a `Bool` with no witness position. The `Next` case at end of stream returns `True`, with the comment _"This is important. It determines how always and next behave at the end of the stream … It should be reviewed very carefully."_ ([`LTLFuture.hs`][y-ltl]).

### Regrets and limits

- External work (a hash on a worker) cannot live inside an SF. It becomes an input event, so the test scripts the completion by hand.
- Generated `dt`s explore sampling jitter, not interleavings of concurrent work.
- Expected lists of 25 floats are opaque: _what_ differs is left to the reader.

### Worked test: keystroke during hash

```haskell
-- UNTESTED sketch. Inputs: (keystroke, hash completion); output: shown result.
-- pipeline :: SF (Event String, Event (String, String)) (Event String)
inputs :: (Ev, [(DTime, Maybe Ev)])
inputs = ( (NoEvent, NoEvent)
         , [ (0.1, Just (Event "ab",  NoEvent)) ]                       -- t=0.1
        ++ replicate 6 (0.1, Just (NoEvent, NoEvent))                   -- debounce fires t=0.6
        ++ [ (0.1, Just (Event "abc", NoEvent)) ]                       -- t=0.8, hash(ab) running
        ++ [ (0.1, Just (NoEvent, Event ("ab", "H(ab)"))) ]             -- stale completion
        ++ replicate 3 (0.1, Just (NoEvent, NoEvent))                   -- debounce fires t=1.3
        ++ [ (0.2, Just (NoEvent, Event ("abc", "H(abc)"))) ] )         -- t=1.5

shownOnlyFresh :: Bool
shownOnlyFresh = filter isEvent (embed pipeline inputs) == [Event "H(abc)"]

-- And over generated timings (QuickCheck): a shown result is never stale.
-- forAll (generateStream DistRandom (Just 0.01, Just 0.2) (Just (Right 3)))
--   (evalT (Always (SP (pipeline >>> arr (not . isStale)))))
```

---

## Jane Street: ppx_expect, Incremental and Bonsai

The tools here are `ppx_expect` (`a44cdf2b5a81`, 2026-11-03), [Incremental][jsi-md] (`371fc83a75dc`) and Bonsai's test library. The Bonsai `Handle` is in `janestreet/bonsai_test` (`742dd6954ef0`), and its guide is in `janestreet/bonsai_web` (`b41369266baa`). The `janestreet/bonsai` repository at `3a02b5736fcb` no longer contains either.

### Scripting inputs

The script is plain code. An expect test is `let%expect_test "name" = …`: ordinary OCaml that prints, interleaved with `[%expect {| … |}]` blocks ([`README.mdx`][ppx-readme]). In Incremental tests you set a `Var`, advance a `Clock` and `stabilize` ([`test_incremental.ml`][incr-test]). In Bonsai you `Handle.create (Result_spec.vdom Fn.id) component`, then drive it with `Handle.do_actions handle [ incoming… ]`, `Handle.click_on`, `Handle.input_text ~selector ~text`, or `Bonsai.Expert.Var.set` on an input ([`testing.md`][bonsai-testing], [`proc.mli`][bonsai-proc]). Asynchronous effects get a scriptable fake. `Effect.For_testing.Query_response_tracker` keeps every query pending until the test calls `maybe_respond qrt ~f:(fun _ -> Respond q)` ([`test_effect_throttling.ml`][bonsai-throttle]). That is the `TestCpuPool` shape.

### Representing time

Time is a virtual clock that the test moves. Incremental: `Clock.create ~start:Time_ns.epoch ()`, `Clock.advance_clock_by clock (sec 1.)`, then `stabilize_` ([`test_incremental.ml`][incr-test]). Bonsai: `Handle.advance_clock_by handle span` and `Handle.advance_clock ~to_`, with an optional `?start_time` on `create` ([`proc.mli`][bonsai-proc]). A **frame** is a precisely specified unit: `recompute_view` _"simulates running one frame of a Bonsai app. In particular, it will - flush the time source - flush the action queue, stabilizing between each action - do an additional stabilization - trigger lifecycles"_ ([`proc.mli`][bonsai-proc]). `recompute_view_until_stable` exists, but the guide calls needing it _"typically an antipattern"_ ([`testing.md`][bonsai-testing]).

### Asserting outputs

Each `[%expect]` _"matches all the output generated since the previous `[%expect]` block"_, after whitespace normalisation (`[%expect_exact]` skips it) ([`README.mdx`][ppx-readme]). Values print as S-expressions (`print_s [%sexp …]`). Incremental's tests print `(Clock.now clock, value o)` after each step. `Handle.show` prints the rendered vdom, and **`Handle.show_diff`** prints _"the diff of the view between now and the last time that [show] or [show_diff] was called"_, with `?diff_context` defaulting to 16 lines ([`proc.mli`][bonsai-proc]). Each step of a UI test therefore leaves one frame-to-frame patch in the source:

```ocaml
Handle.input_text handle ~get_vdom:Fn.id ~selector:(test_selector input_selector) ~text:"Bob";
Handle.show_diff handle;
[%expect
  {|
    <div>
      <input @on_input/>
  -|  <span> hello  </span>
  +|  <span> hello Bob </span>
    </div>
  |}]
```

([`testing.md`][bonsai-testing]). **Promotion** is the build system's job. The runner _"outputs a diff and creates a file with the suffix ".corrected" containing the actual output"_ ([`README.mdx`][ppx-readme]), and `dune promote` (or `dune runtest --auto-promote`) _"will copy the generated … file … directly in the source tree"_ ([dune promotion][dune-promote]). Unreached blocks become `[%expect.unreachable]`, an exception becomes `[@@expect.uncaught_exn {| … |}]`, and a block reached several times with different output is rewritten into numbered `Output 1 / 4` sections ([`README.mdx`][ppx-readme]). Non-determinism is sanitised with a per-scope `Expect_test_config.sanitize`, or post-processed through `[%expect.output]`.

### Concurrency and ordering

Bonsai's guide warns off it: _"Our expect test architecture assumes that all inline tests can run synchronously"_. Async Bonsai tests _"will be several magnitudes slower than the synchronous equivalent"_ ([`testing.md`][bonsai-testing]). Ordering is fixed by the action queue and by when the test calls `respond`. The throttling test shows the order directly: `(query 1) (result Aborted)` prints before `(query 0) (result (Finished 1))` ([`test_effect_throttling.ml`][bonsai-throttle]).

### Cancellation and teardown

Partly observable. An `Effect.t` cannot be cancelled once running, but a superseded _queued_ request is reported, because `Effect_throttling.poll` returns `Aborted` and the test prints it ([`test_effect_throttling.ml`][bonsai-throttle]). Incremental reports `Invalidated` through `Observer.on_update_exn`. Its tests collect updates with an `on_update_queue` probe and compare the list ([`test_incremental.ml`][incr-test]).

### Failure output

A failure is a patch against the test's own source ([`README.mdx`][ppx-readme]):

```text
------ foo.ml
++++++ foo.ml.corrected
File "foo.ml", line 6, characters 0-1:
 |let%expect_test "addition" =
 |  printf "%d" (1 + 2);
-|  [%expect {| 4 |}]
+|  [%expect {| 3 |}]
```

Yaron Minsky's 2015-12-02 post says expect tests were _"inspired by Mercurial's unified test format"_, and that _"you can accept the new test results by just copying the generated file over the original"_ ([Testing with expectations][js-2015]). James Somers' 2023-01-09 post: _"In expect tests, regressions are just diffs"_, and _"Bonsai will even show you how html attributes or class names change in response to user input"_ ([What if writing tests was a joyful experience?][js-2023]).

### Regrets and limits

- Over-printing. Dumping too much state _"makes it more likely that you'll pick up spurious changes. Thus the art of expect tests is in producing output that tells a concise story"_ ([js-2023][js-2023]).
- A hanging test produced no corrected file at all, so its debug prints were lost. `-verbose` (since December 2024) streams output live ([`README.mdx`][ppx-readme]).
- Formatting drift: v0.17.0 added `-expect-test-strict-indentation=true` to enforce block layout ([`CHANGES.md`][ppx-changes], [`README.mdx`][ppx-readme]).
- `show_model` carries an `[@@alert rampantly_nondeterministic]` ([`proc.mli`][bonsai-proc]). Internal state is deliberately kept out of transcripts.

### Worked test: keystroke during hash

```ocaml
(* UNTESTED sketch. [search] debounces 500 ms, then runs [hash] (a tracked effect). *)
let%expect_test "keystroke during hash" =
  let qrt = Effect.For_testing.Query_response_tracker.create () in
  let respond q h = Effect.For_testing.Query_response_tracker.maybe_respond qrt
      ~f:(fun q' -> if String.equal q q' then Respond h else No_response_yet) in
  let handle = Handle.create (Result_spec.vdom Fn.id)
      (search ~hash:(Effect.For_testing.of_query_response_tracker qrt)) in
  Handle.input_text handle ~get_vdom:Fn.id ~selector:"input" ~text:"ab";
  Handle.advance_clock_by handle (Time_ns.Span.of_ms 500.);
  Handle.show handle;
  [%expect {| <div> <input @on_input/> <span> hashing ab… </span> </div> |}];
  Handle.input_text handle ~get_vdom:Fn.id ~selector:"input" ~text:"abc";
  respond "ab" "H(ab)";                       (* stale: must not be shown *)
  Handle.advance_clock_by handle (Time_ns.Span.of_ms 500.);
  respond "abc" "H(abc)";
  Handle.show_diff handle;
  [%expect {|
    -|<span> hashing ab… </span>
    +|<span> H(abc) </span>
    |}]
```

---

## Rust: insta and expect-test

Two libraries cover the same idea: assert against a stored string and let a tool rewrite it. They are `insta` 1.49.0 (`0e17c7a6ed65`, 2026-10-25) and `expect-test` 1.5.1 (`199655fd04a3`, 2026-11-10). Neither has a notion of time or frames. Both are used with an async runtime's paused clock.

### Scripting inputs

The script is plain Rust in a `#[test]`, which accumulates whatever it will assert (often a transcript `String`). expect-test's author recommends one data-driven driver: _"I usually define a single driver function `check` and then call it from individual tests … All the variation in tests comes from the input data"_ ([`lib.rs`][et-lib]).

### Representing time

Neither library represents time. The test brings it from the runtime, for example `tokio::time::pause`/`advance` (see [`rust-streams.md`][rust-streams]).

### Asserting outputs

insta asserts a value against a named snapshot: `assert_snapshot!` (`Display`), `assert_debug_snapshot!`, and serde formats (`assert_yaml_snapshot!`, `assert_json_snapshot!`, …). Snapshots are stored _"right next to your test in a folder called `snapshots` as individual `.snap` files"_ ([`lib.rs`][insta-lib]), with a YAML header ([`doctest_runtime_rs__named.snap`][insta-snap]):

```text
---
source: insta/src/runtime.rs
expression: "vec![1, 2, 3, 4, 5]"
---
[
    1,
```

Inline snapshots are `assert_snapshot!(value, @"…")`. Serialized snapshots take redactions, `{ ".key.to.redact" => "[replacement value]" }` ([`macros.rs`][insta-macros]), or `Settings::add_redaction`. Text filters go through `Settings::add_filter(regex, replacement)` ([`settings.rs`][insta-settings], [insta redactions][insta-redactions]). Repeated asserts in one test get counter-suffixed names (`TEST_NAME_COUNTERS` in [`runtime.rs`][insta-runtime]). That makes a sequence of snapshots per test a crude frame transcript.

expect-test is _"a super-charged string literal, which can update itself"_: `expect![["…"]].assert_eq(&actual)` or `assert_debug_eq`, plus `expect_file!` for large outputs ([`lib.rs`][et-lib]).

**Promotion.** insta's `INSTA_UPDATE` modes are `auto`, `new`, `always`, `unseen`, `no` and `force`. `auto` is _"`no` for CI environments or `new` otherwise"_. `new` writes `.snap.new` files, or `.pending-snap` for inline snapshots. `cargo insta review` then accepts, rejects or skips each one interactively ([`lib.rs`][insta-lib], [cargo insta][insta-cli]). expect-test rewrites the source directly when `UPDATE_EXPECT=1` is set: _"the `expect!` macro uses `file!`, `line!` and `column!` to record source position at compile time. At runtime, this position is used to patch the file in-place"_ ([`lib.rs`][et-lib]).

### Concurrency and ordering

Both are safe under `cargo test`'s parallel test threads. insta's settings are `thread_local!` (_"per-thread (and thus per-test)"_), and its name counters sit behind a `Mutex` ([`settings.rs`][insta-settings], [`runtime.rs`][insta-runtime]). expect-test serialises source patching through a global `Mutex<Runtime>`, which keeps a per-file `Patchwork` of applied insertions and deletions. Several failing literals in one file are therefore patched consistently, against the original text ([`lib.rs`][et-lib]). Neither library orders events. The transcript must already be deterministic.

### Cancellation and teardown

Out of scope for both libraries. A test observes cancellation only if the code under test writes it into the transcript, for example a `Drop` guard that logs `cancelled`.

### Failure output

expect-test prints a block per failure, plus a hint the first time (`HELP`). The template is in `Runtime::panic` ([`lib.rs`][et-lib]). The position and values below are illustrative, blank lines are elided, and colour is stripped:

```text
error: expect test failed
   --> src/foo.rs:12:20
You can update all `expect!` tests by running:
    env UPDATE_EXPECT=1 cargo test
Expect:
----
5
----
Actual:
----
4
----
Diff:
----
54
----
```

The diff is character-level (`dissimilar`). Only colour tells the deleted `5` from the inserted `4`. insta prints a header (`Snapshot:`, `Source:`, `Expression:`), then `-old snapshot`/`+new results`, then a line-numbered **Patience** diff between `────────────┬` rules, with intra-line emphasis and `┈┈┈┼` separators between hunks. `INSTA_DIFF_TOOL=delta` delegates the rendering ([`output.rs`][insta-output], [`lib.rs`][insta-lib]).

### Regrets and limits

- expect-test warns that `assert_debug_eq` is fragile: _"stability of the debug representation is not guaranteed"_ ([`lib.rs`][et-lib]).
- insta's changelog is dominated by runner integration: nextest, doctests, and warnings that _"nextest suppresses stdout/stderr from passing tests"_ (#840 in [`CHANGELOG.md`][insta-changelog]). Promotion tooling is the expensive part, not assertion.
- Inline duplicates are refused unless wrapped in `allow_duplicates!` (`prevent_inline_duplicate` in [`runtime.rs`][insta-runtime]). The same rule holds for a `[%expect]` reached twice.

### Worked test: keystroke during hash

```rust
// UNTESTED sketch: tokio paused clock + a fake hasher whose jobs pend until
// completed; the pipeline and FakeHasher log into `log`.
#[tokio::test(start_paused = true)]
async fn keystroke_during_hash() {
    let (log, hasher) = FakeHasher::new();         // records start/cancel/complete
    let ui = Pipeline::spawn(Duration::from_millis(500), hasher.clone(), log.clone());
    ui.type_query("ab");
    tokio::time::advance(Duration::from_millis(500)).await;
    ui.type_query("abc");                           // drops hash(ab)'s future
    tokio::time::advance(Duration::from_millis(500)).await;
    hasher.complete("abc", "H(abc)");
    ui.settle().await;
    insta::assert_snapshot!(log.take(), @r"
    t=0ms     query ab
    t=500ms   hash start ab
    t=500ms   query abc
    t=500ms   hash cancelled ab
    t=1000ms  hash start abc
    t=1000ms  hash done abc
    t=1000ms  shown H(abc)
    ");
}
```

---

## Elm: elm-program-test

`avh4/elm-program-test` 4.0.1 (`195131b038ca`, 2026-02-18) scripts a whole TEA program, `init`, `update` and `view`, through its public surface ([`elm.md`][elm-md]).

### Scripting inputs

A pipeline of steps: `ProgramTest.createElement { init, update, view } |> ProgramTest.start ()`, then `clickButton`, `fillIn id label text`, `update msg`, `simulateHttpOk method url body`, `simulateHttpResponse`, `advanceTime ms` ([`ProgramTest.elm`][ept-pt], [`README.md`][ept-readme]). Effects must be inspectable, and `Cmd` is not: _"Elm does not currently provide a way to inspect `Cmd` values to see which commands they represent"_ ([`cmds.md`][ept-cmds]). The program therefore returns its own `Effect` type, `perform : Effect -> Cmd Msg` runs it in production, and the test supplies `simulateEffects : Effect -> ProgramTest.SimulatedEffect Msg` through `withSimulatedEffects`. The `SimulatedEffect.*` modules mirror `Cmd`, `Http`, `Task`, `Process`, `Time`, `Ports` and `Navigation` ([`cmds.md`][ept-cmds]).

### Representing time

`advanceTime : Int -> …` _"Simulates the passing of time … This will cause any pending `Task.sleep`s to trigger if their delay has elapsed"_, and requires `withSimulatedEffects` ([`ProgramTest.elm`][ept-pt]). `SimulatedEffect.Process.sleep` is the debounce primitive ([`Process.elm`][ept-process]). Frames do not exist: the view is a pure function of the model, queried whenever the test asserts.

### Asserting outputs

The assertions are selector queries on the current view (`expectViewHas`, `ensureViewHas`, `expectView`), on effects (`expectHttpRequestWasMade`, `ensureHttpRequestWasMade`, `ensureOutgoingPortValues`) and on the model (`expectModel`). `ensure*` returns the `ProgramTest` so a script continues, and `expect*` ends it ([`ProgramTest.elm`][ept-pt]). No snapshot is involved: each assertion names what it expects.

### Concurrency and ordering

Simulated effects run on a deterministic task queue, drained after each step (`TestState.drain`). HTTP requests stay **pending** until the test resolves them, keyed by method and URL ([`ProgramTest.elm`][ept-pt]). That is the same pend-until-the-test-says-so shape as Bonsai's tracker and a `TestCpuPool`.

### Cancellation and teardown

Not observable. The simulated request record always sets `tracker = Nothing` ([`Http.elm`][ept-http]), and `SimulatedEffect.Http` has no `cancel`. A latest-wins program tags each response with the query it answers and ignores stale ones in `update`. The test can only show that a stale response was harmless.

### Failure output

The output is a named step plus context, not a diff. A missing request reads `HttpRequestWasMade: Expected HTTP request (GET https://example.com/not-made) to have been made and still be pending, but no such requests were made.`, followed by `The following requests were made:` and the pending list ([`ProgramTestHttpTests.elm`][ept-httptests]). A view failure renders the whole HTML, a `▼ functionName` marker and the selector failure ([`Failure.elm`][ept-failure]). Misuse gets a `TEST SETUP ERROR` naming the missing `withSimulatedEffects` ([`cmds.md`][ept-cmds]).

### Regrets and limits

- The app must be restructured around an `Effect` type. The guide admits it: _"be aware of this trade-off when considering whether this type of testing is right for your program"_ ([`cmds.md`][ept-cmds]).
- There is no cancellation and no CPU work, since everything off-thread is a port or HTTP.

### Worked test: keystroke during hash

```elm
-- UNTESTED sketch: the hash runs on a worker behind POST /hash?q=…
keystrokeDuringHash : Test
keystrokeDuringHash =
    test "keystroke during hash shows only the fresh result" <|
        \() ->
            start
                |> fillIn "query" "Query" "ab"
                |> advanceTime 500
                |> ensureHttpRequestWasMade "POST" "/hash?q=ab"
                |> fillIn "query" "Query" "abc"
                |> simulateHttpOk "POST" "/hash?q=ab" "\"H(ab)\""   -- stale, ignored
                |> ensureViewHasNot [ text "H(ab)" ]
                |> advanceTime 500
                |> simulateHttpOk "POST" "/hash?q=abc" "\"H(abc)\""
                |> expectViewHas [ text "H(abc)" ]
```

---

## Jetpack Compose: MainTestClock and semantics assertions

The source is androidx `HEAD` at `296313a488a0` (2026-11-21), `compose/ui/ui-test` and `compose/ui/ui-test-junit4`. See also [`jetpack-compose.md` § Testing][compose-md].

### Scripting inputs

`ComposeTestRule.setContent { … }`, then actions on semantics nodes: `onNodeWithTag("query").performTextInput("ab")`, `performClick()`. State can also be written directly from the test.

### Representing time

`rule.mainClock: MainTestClock` _"is ultimately responsible for driving all recompositions, all subscribers to [withFrameNanos] … and all coroutines launched with [LaunchedEffect]"_. With `autoAdvance = false` the test owns it: `advanceTimeByFrame()`, `advanceTimeBy(ms)` (_"rounded up to the nearest multiple of the frame duration"_, 16 ms on the JVM) and `advanceTimeUntil { }` ([`MainTestClock.kt`][compose-clock]). The frame order is specified: _"ticking this clock will first send the new frame time to the animation, and then perform recomposition"_, and `delay`ed effects _"are resumed on their scheduled time"_. Draw on Android is not driven by the clock and needs `waitForIdle` ([`MainTestClock.kt`][compose-clock], [`ComposeTestRule.jvmAndAndroid.kt`][compose-rule]).

### Asserting outputs

Assertions run against the semantics tree: `assertTextEquals`, `assertExists`, `assertCountEquals`, and generic `assert(matcher)`. `printToString(maxDepth)` dumps a node subtree ([`Assertions.kt`][compose-assertions], [`Output.kt`][compose-output]). There is no built-in snapshot of the semantics tree. Screenshot tests are separate tooling.

### Concurrency and ordering

Effects run on the clock's `TestCoroutineScheduler`. Work on other dispatchers is real concurrency, which the rule waits for through `IdlingResource`s, unless the test injects a `TestDispatcher` through `createComposeRule(effectContext)` ([`MainTestClock.kt`][compose-clock], [`AndroidComposeTestRule.android.kt`][compose-android-rule]). `waitUntil` polls on **wall-clock** time, and `advanceTimeUntil` on test-clock time ([`ComposeTestRule.jvmAndAndroid.kt`][compose-rule]).

### Cancellation and teardown

Observable, because coroutine cancellation is real. `LaunchedEffect(query)` cancels the previous coroutine when `query` changes, and a fake suspending hasher sees `CancellationException` (or `invokeOnCompletion`). The test library itself offers no cancellation assertion.

### Failure output

The message is prose plus a tree dump. `buildGeneralErrorMessage` appends `Semantics of the node:`, `printToString()` and `Selector used: (…)` ([`ErrorMessages.kt`][compose-errors]). A missing node reads `Failed: assertExists.` / `Reason: Expected exactly '1' node but could not find any node that satisfies: (TestTag = 'MyButton3')` ([`ErrorMessagesTest.kt`][compose-errors-test]). Expected and actual tree are never diffed.

### Regrets and limits

- The v1 `createComposeRule(effectContext)` is deprecated: _"The v2 APIs use StandardTestDispatcher instead of UnconfinedTestDispatcher, which aligns with standard coroutine behavior by queuing tasks rather than executing them immediately"_ ([`AndroidComposeTestRule.android.kt`][compose-android-rule]). Eager dispatch made tests pass for the wrong order.
- Frame rounding (`advanceTimeBy(160)` yields ten 16 ms frames) and Android's draw outside the clock are both documented traps ([`MainTestClock.kt`][compose-clock]).

### Worked test: keystroke during hash

```kotlin
// UNTESTED sketch. FakeHasher.hash suspends on a CompletableDeferred per query
// and records "cancelled <q>" from a finally block.
@Test fun keystrokeDuringHash() {
    val hasher = FakeHasher()
    rule.mainClock.autoAdvance = false
    rule.setContent { Search(debounceMs = 500, hasher = hasher) }
    rule.onNodeWithTag("query").performTextInput("ab")
    rule.mainClock.advanceTimeBy(500)
    assertEquals(listOf("start ab"), hasher.log)
    rule.onNodeWithTag("query").performTextInput("c")
    rule.mainClock.advanceTimeByFrame()                 // recompose: LaunchedEffect restarts
    assertEquals(listOf("start ab", "cancelled ab"), hasher.log)
    rule.mainClock.advanceTimeBy(500)
    hasher.complete("abc", "H(abc)")
    rule.mainClock.advanceTimeByFrame()
    rule.onNodeWithTag("result").assertTextEquals("H(abc)")
}
```

---

## Comparison

| System                                                                     | Input notation                                                   | Time                                                           | Assertion style                                                  | Concurrency handling                                    | Cancel observable?                                      | Failure diff                                                           |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------- |
| [Reflex](#reflex-test-plans-and-a-reference-semantics)                     | `plan [(frame, a)]`; `tickAppFrame` per input                    | frame index only; no wall clock                                | per-frame `IntMap` vs pinned list **or** `Reflex.Pure` reference | none in a frame; simultaneity is semantic               | no (only absence of stale output)                       | none (`expected:`/`but got:` maps)                                     |
| [Yampa](#yampa-sample-streams-and-temporal-logic)                          | `(a0, [(dt, Maybe a)])`; generated streams                       | sum of `dt`; generated by QuickCheck                           | literal output lists; LTL `TPred` + `evalT`                      | none; the list is the order                             | no                                                      | none (`Falsified` + shrunk stream)                                     |
| [Jane Street](#jane-street-ppx-expect-incremental-and-bonsai)              | plain code; `do_actions`, `input_text`; `Query_response_tracker` | virtual `Clock`/`advance_clock_by`; `recompute_view` = 1 frame | printed transcript in `[%expect]`; `show_diff` per frame         | synchronous by policy; test decides `respond` order     | partly (`Aborted` for superseded queued effects)        | patch of the test source vs `.corrected`, promoted by dune             |
| [insta / expect-test](#rust-insta-and-expect-test)                         | plain Rust                                                       | external (runtime's paused clock)                              | `.snap` files / inline `@"…"`; `expect![[…]]`                    | thread-safe promotion; ordering is the test's job       | only if the code logs it                                | line Patience diff (insta); char diff + both blocks (expect-test)      |
| [elm-program-test](#elm-elm-program-test)                                  | piped steps; `simulateHttpOk`; app-defined `Effect` type         | `advanceTime ms` over simulated sleeps                         | selector queries on view; effect/model expectations              | deterministic queue; requests pend until resolved       | no (`tracker = Nothing`, no `cancel`)                   | none (step name, context, rendered HTML)                               |
| [Jetpack Compose](#jetpack-compose-maintestclock-and-semantics-assertions) | node actions; direct state writes                                | `MainTestClock` frames (16 ms), `autoAdvance = false`          | semantics matchers                                               | `TestCoroutineScheduler`; idling resources for the rest | yes, through coroutine cancellation in a fake           | none (message + tree dump)                                             |
| local task DAG ([`testing.d`][local-testing])                              | `Script` per task (duration, outcome, yields); `cancelAt`        | `TestClock` + `advanceAndSettle`                               | byte-exact transcript string; event counts                       | `TestSched`; 120 completion-order permutations          | yes (`Cancelled(interrupted)`, `CancellationRequested`) | `assert(text == expected, text)`; `checkWriter` prints Expected/Actual |

---

## Lessons for the D harness

1. **Make the transcript the unit of assertion, delimited per step.** ppx_expect's _"all the output generated since the previous `[%expect]` block"_ ([Jane Street](#asserting-outputs-2)) and Bonsai's `show_diff` both cut one long story into per-step chunks. The local `transcriptIsIdenticalAcrossCompletionOrders` already asserts one whole-run string ([`reporter_plain.d`][local-reporter-plain]). The reactive harness should append to a log as it goes and offer an `expectLog("…")` that consumes everything since the last call. That answers "keystroke during hash" step by step, not in one wall of text.
2. **Fix the current failure format: show a line diff, not two blocks.** The repository guidelines say `checkWriter` _"diff[s] on mismatch"_. `assertRendered` actually prints `Expected:` then `Actual:` in full ([`buffer.d`][local-buffer]). The transcript tests use `assert(text == expected, text)`, which shows only the actual output ([`reporter_plain.d`][local-reporter-plain]). insta's line-numbered Patience diff with hunk separators ([Rust](#failure-output-3)) is the model to copy for multi-line transcripts, with character emphasis inside a changed line.
3. **Promote, never silently rewrite, and gate it on an environment variable.** All three snapshot ecosystems write the actual output somewhere reviewable: `.corrected` plus `dune promote`, `.snap.new`/`.pending-snap` plus `cargo insta review`, or an in-place patch only when `UPDATE_EXPECT=1` ([Jane Street](#asserting-outputs-2), [Rust](#asserting-outputs-3)). D has `__FILE__`/`__LINE__` default arguments (already on `checkWriter`), which is everything expect-test's source patcher needs. It must serialise patches per file (expect-test's `Mutex` + `Patchwork`) because the runner executes tests in parallel. CI must never promote (insta's `auto` is `no` under CI).
4. **Keep a reference semantics and run every plan against it.** Reflex writes each test once against `TestPlan` and checks `Pure` and Spider against one reference, plus `--dump-expected` to pin ([Reflex](#asserting-outputs)). For the D library, a deliberately naive single-fiber interpreter of the operators (no `CpuPool`, no cancellation latency, time as a sorted event list) can serve as `Pure`. The real `TestSched` pipeline must agree with it on every script, including generated ones.
5. **Script time as data, with frames as a named unit.** Reflex's `plan [(frame, a)]` and Yampa's `(dt, Maybe a)` make the schedule a value that can be printed, generated and shrunk ([Reflex](#scripting-inputs), [Yampa](#scripting-inputs-1)). A D script should be a list of `(at, action)` executed by `advanceAndSettle` between actions. The harness must state exactly what one frame does, the way Bonsai's `recompute_view` and Compose's _"first … the animation, and then … recomposition"_ do ([Jane Street](#representing-time-2), [Compose](#representing-time-5)).
6. **Pending-until-the-test-responds fakes are the consensus for external work.** Bonsai's `Query_response_tracker`, elm-program-test's pending HTTP and the local `FakeDriver` all hand completion order to the test ([Jane Street](#scripting-inputs-2), [Elm](#concurrency-and-ordering-4)). `TestCpuPool` is that design. What the surveyed tools mostly lack is **observing cancellation**: Elm cannot, Bonsai only for queued work, and only Compose (through real coroutine cancellation) and the local `Cancelled(interrupted)` do ([Comparison](#comparison)). The D transcript should log `cancel requested`, `cancel observed by job` and `joined` as three distinct lines, since cancel-then-join is the property Q12.3 most needs to pin.
7. **Explore interleavings with generators, assert invariants with temporal predicates.** Yampa pairs QuickCheck streams with `Always`/`Eventually` ([Yampa](#asserting-outputs-1)), and the local suite enumerates 120 completion orders ([`reporter_plain.d`][local-reporter-plain]). The D harness should combine the two: generate keystroke times and `TestCpuPool` completion orders from a seed, and check invariants like "a shown result is the hash of the latest query" and "every started job is joined before its scope exits". Snapshots stay reserved for the hand-written scenarios.
8. **Sanitise at the source, not by regex.** ppx's `Expect_test_config.sanitize` and insta's redactions and filters exist because real clocks leak into output ([Jane Street](#asserting-outputs-2), [Rust](#asserting-outputs-3)). With time coming only from `TestClock`, transcripts can print virtual timestamps verbatim (`t=500ms`). Real durations are disabled the way `PlainOptions(timings: false)` already disables them ([`reporter_plain.d`][local-reporter-plain]).
9. **Run deterministically inside a test, in parallel across tests.** Bonsai's "avoid async testing" and Compose's v1→v2 move from unconfined to queued dispatch both regret eager or real concurrency inside a test ([Jane Street](#concurrency-and-ordering-2), [Compose](#regrets-and-limits-5)). One `TestSched` per test, no shared globals, and the runner's process-level parallelism keep tests independent. insta's `thread_local!` settings show what to do with per-test configuration ([Rust](#concurrency-and-ordering-3)).
10. **Scale to a whole app with frame-to-frame diffs.** elm-program-test and Bonsai test entire programs through their public surface. Bonsai's printed diffs between frames keep a large view reviewable ([Jane Street](#asserting-outputs-2), [Elm](#scripting-inputs-4)). For the per-frame-rebuilt UI, the D harness should render the widget tree (or a cell grid) to text each frame and offer `showDiff`, so a pipeline test and a UI test share one transcript mechanism.

---

## Sources

- Reflex `f443526bd2a9`: [`TestPlan.hs`][r-testplan], [`Test.hs`][r-test], [`Plan/Pure.hs`][r-plan-pure], [`Plan/Reflex.hs`][r-plan-reflex], [`CrossImpl.hs`][r-crossimpl], [`Micro.hs`][r-micro], [`semantics.hs`][r-semantics], [`Pure.hs`][r-pure], [`Time.hs`][r-time]; reflex-test-host `47a4676e3537`: [`SimpleHost.hs`][rth-simplehost], [`SimpleHostSpec.hs`][rth-spec], [`README.md`][rth-readme], [Hackage][rth-hackage].
- Yampa `9dda03030c4e`: [`Simulation.hs`][y-sim], [`LTLFuture.hs`][y-ltl], [`LTLPast.hs`][y-ltlpast], [`QuickCheck.hs`][y-qc], [`Stream.hs`][y-stream], [`Testing.hs`][y-examples], [`Delays.hs`][y-delays], [`TestsCommon.hs`][y-common], [`yampa-test.cabal`][y-cabal]; Perez & Nilsson, ICFP 2017 ([DOI][y-paper]; not fetched, the ACM site refuses automated clients).
- Jane Street: ppx_expect `a44cdf2b5a81` [`README.mdx`][ppx-readme], [`CHANGES.md`][ppx-changes]; Incremental `371fc83a75dc` [`test_incremental.ml`][incr-test]; bonsai_web `b41369266baa` [`testing.md`][bonsai-testing]; bonsai_test `742dd6954ef0` [`proc.mli`][bonsai-proc], [`test_effect_throttling.ml`][bonsai-throttle]; Yaron Minsky, [Testing with expectations][js-2015] (2015-12-02); James Somers, [What if writing tests was a joyful experience?][js-2023] (2023-01-09); [dune promotion][dune-promote].
- Rust: insta `0e17c7a6ed65` [`lib.rs`][insta-lib], [`output.rs`][insta-output], [`macros.rs`][insta-macros], [`settings.rs`][insta-settings], [`runtime.rs`][insta-runtime], [`CHANGELOG.md`][insta-changelog], [sample `.snap`][insta-snap], [insta.rs redactions][insta-redactions], [cargo insta][insta-cli]; expect-test `199655fd04a3` [`lib.rs`][et-lib].
- elm-program-test `195131b038ca`: [`README.md`][ept-readme], [`cmds.md`][ept-cmds], [`ProgramTest.elm`][ept-pt], [`SimulatedEffect/Http.elm`][ept-http], [`SimulatedEffect/Process.elm`][ept-process], [`Failure.elm`][ept-failure], [`ProgramTestHttpTests.elm`][ept-httptests].
- androidx `296313a488a0`: [`MainTestClock.kt`][compose-clock], [`ComposeTestRule.jvmAndAndroid.kt`][compose-rule], [`AndroidComposeTestRule.android.kt`][compose-android-rule], [`Assertions.kt`][compose-assertions], [`Output.kt`][compose-output], [`ErrorMessages.kt`][compose-errors], [`ErrorMessagesTest.kt`][compose-errors-test]; [Compose synchronization guide][compose-sync].
- Local baseline: [`task/testing.d`][local-testing], [`task/reporter_plain.d`][local-reporter-plain], [`task/executor.d`][local-executor], [`base/buffer.d`][local-buffer].
- Sibling pages: [Reflex][reflex-md], [Yampa][yampa-md], [Jane Street Incremental][jsi-md], [Elm][elm-md], [Jetpack Compose][compose-md], [Rust streams][rust-streams], [comparison][comparison].

<!-- References -->

[r-testplan]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/TestPlan.hs#L36-L41
[r-test]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/Test.hs#L28-L94
[r-plan-pure]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/Plan/Pure.hs
[r-plan-reflex]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/Plan/Reflex.hs#L91-L119
[r-crossimpl]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/Test/CrossImpl.hs#L75-L124
[r-micro]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/Reflex/Test/Micro.hs
[r-semantics]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/test/semantics.hs
[r-pure]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Pure.hs#L16-L57
[r-time]: https://github.com/reflex-frp/reflex/blob/f443526bd2a9d4ba43f65f3a755d21e61082f4e0/src/Reflex/Time.hs#L224
[rth-simplehost]: https://github.com/minimapletinytools/reflex-test-host/blob/47a4676e35373e59b0e8c10f724acdbebf1407eb/src/Reflex/Test/SimpleHost.hs
[rth-spec]: https://github.com/minimapletinytools/reflex-test-host/blob/47a4676e35373e59b0e8c10f724acdbebf1407eb/test/Reflex/Test/SimpleHostSpec.hs
[rth-readme]: https://github.com/minimapletinytools/reflex-test-host/blob/47a4676e35373e59b0e8c10f724acdbebf1407eb/README.md
[rth-hackage]: https://hackage.haskell.org/package/reflex-test-host
[y-sim]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa/src/FRP/Yampa/Simulation.hs#L161-L279
[y-ltl]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/src/FRP/Yampa/LTLFuture.hs#L28-L69
[y-ltlpast]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/src/FRP/Yampa/LTLPast.hs
[y-qc]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/src/FRP/Yampa/QuickCheck.hs
[y-stream]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/src/FRP/Yampa/Stream.hs
[y-examples]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/examples/Testing.hs
[y-delays]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/tests/Test/FRP/Yampa/Delays.hs
[y-common]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/tests/TestsCommon.hs
[y-cabal]: https://github.com/ivanperez-keera/Yampa/blob/9dda03030c4edfdda6e908f49b5a92d1dda5c8a3/yampa-test/yampa-test.cabal
[y-paper]: https://doi.org/10.1145/3110246
[ppx-readme]: https://github.com/janestreet/ppx_expect/blob/a44cdf2b5a81ae50551722a74bf1339d43fe6790/README.mdx
[ppx-changes]: https://github.com/janestreet/ppx_expect/blob/a44cdf2b5a81ae50551722a74bf1339d43fe6790/CHANGES.md
[incr-test]: https://github.com/janestreet/incremental/blob/371fc83a75dc691e135d36c6d3cf25aadcbf3acc/test/test_incremental.ml
[bonsai-testing]: https://github.com/janestreet/bonsai_web/blob/b41369266baa0d73a7826d5b48c71b8b3400f156/docs/how_to/testing.md
[bonsai-proc]: https://github.com/janestreet/bonsai_test/blob/742dd6954ef0b2cc72c40fc76d328aebc9222356/proc.mli#L50-L135
[bonsai-throttle]: https://github.com/janestreet/bonsai_test/blob/742dd6954ef0b2cc72c40fc76d328aebc9222356/of_bonsai_itself/test_effect_throttling.ml
[js-2015]: https://blog.janestreet.com/testing-with-expectations/
[js-2023]: https://blog.janestreet.com/the-joy-of-expect-tests/
[dune-promote]: https://dune.readthedocs.io/en/stable/concepts/promotion.html
[insta-lib]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/insta/src/lib.rs
[insta-output]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/insta/src/output.rs#L199-L306
[insta-macros]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/insta/src/macros.rs#L116-L141
[insta-settings]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/insta/src/settings.rs
[insta-runtime]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/insta/src/runtime.rs
[insta-changelog]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/CHANGELOG.md
[insta-snap]: https://github.com/mitsuhiko/insta/blob/0e17c7a6ed65b73def1101813987a053269ef4a5/insta/src/snapshots/doctest_runtime_rs__named.snap
[insta-redactions]: https://insta.rs/docs/redactions/
[insta-cli]: https://insta.rs/docs/cli/
[et-lib]: https://github.com/rust-analyzer/expect-test/blob/199655fd04a32e61ecb6655e444d0edadf447f55/src/lib.rs
[ept-readme]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/README.md
[ept-cmds]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/docs/cmds.md
[ept-pt]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L1600-L1714
[ept-http]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/SimulatedEffect/Http.elm#L60-L105
[ept-process]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/SimulatedEffect/Process.elm
[ept-failure]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest/Failure.elm#L152-L168
[ept-httptests]: https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/tests/ProgramTestHttpTests.elm#L88-L136
[compose-clock]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/MainTestClock.kt
[compose-rule]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test-junit4/src/jvmAndAndroidMain/kotlin/androidx/compose/ui/test/junit4/ComposeTestRule.jvmAndAndroid.kt
[compose-android-rule]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test-junit4/src/androidMain/kotlin/androidx/compose/ui/test/junit4/AndroidComposeTestRule.android.kt#L52-L72
[compose-assertions]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/Assertions.kt#L338-L351
[compose-output]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/Output.kt
[compose-errors]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/commonMain/kotlin/androidx/compose/ui/test/ErrorMessages.kt#L180-L197
[compose-errors-test]: https://github.com/androidx/androidx/blob/296313a488a01c84ddcb0801d4efee640a14070c/compose/ui/ui-test/src/androidDeviceTest/kotlin/androidx/compose/ui/test/ErrorMessagesTest.kt#L61-L74
[compose-sync]: https://developer.android.com/develop/ui/compose/testing/synchronization
[local-testing]: ../../../libs/build-primitives/src/sparkles/build_primitives/task/testing.d
[local-reporter-plain]: ../../../libs/build-primitives/src/sparkles/build_primitives/task/reporter_plain.d
[local-executor]: ../../../libs/build-primitives/src/sparkles/build_primitives/task/executor.d
[local-buffer]: ../../../libs/base/src/sparkles/base/buffer.d
[reflex-md]: ./reflex.md
[reflex-md-testing]: ./reflex.md#testing
[yampa-md]: ./yampa.md
[jsi-md]: ./jane-street-incremental.md
[elm-md]: ./elm.md
[compose-md]: ./jetpack-compose.md#testing
[rust-streams]: ./rust-streams.md
[comparison]: ./comparison.md
