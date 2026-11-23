# Deterministic Simulation and Schedule Exploration

The end of the testing design space where a test does not script one interleaving but explores many, and on failure hands back a seed, a schedule string or a trace that replays the exact run.

The other testing pages script one run and compare its output. This page covers the systems that **generate** runs: deterministic simulators that draw every source of nondeterminism from one seed ([FoundationDB and TigerBeetle](#foundationdb-and-tigerbeetle-deterministic-simulation-testing), [madsim and turmoil](#madsim-and-turmoil-rust-simulation-runtimes)), schedule explorers that enumerate or randomize the interleavings of controlled threads ([loom and shuttle](#loom-and-shuttle-rust-schedule-exploration), [Coyote and Lincheck](#coyote-and-lincheck-controlled-scheduling-on-managed-runtimes)), and state-machine property tests that generate and shrink command sequences ([Hedgehog and proptest-state-machine](#hedgehog-and-proptest-state-machine-state-machine-property-testing)). It closes with the repository's own baseline ([task DAG, `TestSched`, the sync model checker](#local-baseline-the-task-dag-harness-testsched-and-the-sync-model)) and a concrete proposal for exploring its choice points.

The question is Q12.3: how a test of the reactive library scripts inputs and asserts outputs. The scenarios that matter are races (keystroke vs. hash completion vs. debounce expiry vs. toggle), so the specific sub-questions are how a failing interleaving is **reported** and **replayed**, whether a scripted test and an explored test can share **one scenario definition**, how failures **shrink**, what exploration **costs**, and what fits a fiber-based single-threaded `TestSched` plus one controllable `TestCpuPool`. There, the choice points are few and explicit: which ready fiber runs next, which pending CPU job completes next, and when the clock advances.

Every section ends with the same worked test, **keystroke during hash**: query `"ab"` debounced 500 ms → hash starts; keystroke `"abc"` while hashing → the old hash is cancelled, a new debounce runs, a new hash runs, its result is shown.

> [!NOTE]
> Versions surveyed (clones as of 2026-11-24): TigerBeetle 0.18.0 (`a2a3c706`, 2026-11-10); madsim 0.2.34 (`519950ef`); turmoil 0.7.2 (`2bdbe89d`); loom 0.7.3 (`9d549cd5`); shuttle 0.9.10 (`72bdbdb6`); Coyote 1.7.11 (`0c51dc58`); Lincheck 3.7 (`a1e02bfd`); Hedgehog 1.7 (`7845181d`); proptest 1.12.0 / proptest-state-machine 0.9.0 (`70cf37d4`). FoundationDB is cited from the [SIGMOD 2021 paper][fdb-paper] (DOI [10.1145/3448016.3457559][fdb-doi]) and [its testing page][fdb-testing]; Will Wilson's Strange Loop 2014 talk is cited by [URL][fdb-talk] but was not re-watched for this page, so no claim here rests on it alone. Every worked test is an **untested sketch**.

---

## FoundationDB and TigerBeetle: deterministic simulation testing

FoundationDB runs a whole cluster inside one process on a discrete-event simulator. TigerBeetle's VOPR is the same idea, built into a Zig database from the start. In both, the production code is the code under test, and the seed is the whole test case.

### Scripting inputs

Neither scripts inputs one at a time. FoundationDB _"runs multiple workloads (also written in Flow) that communicate with simulated FDB servers through the simulated network. These workloads include fault injection instructions, mock applications, database configuration changes, and direct internal database functionality invocations"_, and the workloads _"are composable"_ ([paper §4][fdb-paper]). The VOPR derives everything from one 64-bit seed: `options_swarm(&prng)` draws the replica count, client count, batch limits, latencies and fault probabilities from it ([`src/vopr.zig`][tb-vopr]), and the cluster then _"commits several hundred batches of operations and checks that they are applied as expected"_ ([`docs/internals/vopr.md`][tb-vopr-doc]). Scripted cases are written separately, on the same infrastructure: _"we also test for specific cases that are hard or slow to replicate through random simulation"_ (ibid.).

### Representing time

Time is a simulated quantity that jumps. FoundationDB: _"Discrete-event simulation can run arbitrarily faster than real-time if CPU utilization within the simulation is low, as the simulator can fast-forward clock to the next event"_ ([paper §4][fdb-paper]). The VOPR counts ticks (`ticks_max_requests: u32 = 40_000_000`, `ticks_max_convergence: u32 = 10_000_000`) and _"can speed up time arbitrarily. One minute of VOPR time is equivalent to days of real-world testing"_ ([`vopr.md`][tb-vopr-doc]).

### Asserting outputs

Assertions run inside the code, with checkers on top. FoundationDB's workloads _"have assertions built in to verify the contracts and properties of the database"_, and liveness is checked by _"returning the modeled hardware environment … to a state in which recovery should be possible and verifying that the cluster eventually recovers"_ ([paper §4][fdb-paper]). The VOPR splits a run into a safety phase and a liveness phase: after the requests, `transition_to_liveness_mode(core)` heals a "core" of replicas and requires convergence within `ticks_max_convergence` ([`src/vopr.zig`][tb-vopr]). Its storage checkers require caught-up replicas' data files to be _"byte-for-byte identical"_ ([`vopr.md`][tb-vopr-doc]).

### Concurrency and ordering

All concurrency is cooperative and single-threaded: _"All database code is deterministic; accordingly multithreaded concurrency is avoided (instead, one database node is deployed per core)"_, and _"all sources of nondeterminism and communication are abstracted, including network, disk, time, and pseudo random number generator"_ ([paper §4][fdb-paper]). Interleavings are not enumerated. They are sampled through randomized event times, packet reordering and _"buggification"_, where _"the simulation is given the opportunity to inject some unusual (but not contract-breaking) behavior"_. Swarm testing randomizes the configuration as well: _"Each run uses a random cluster size and configuration, random workloads, random fault injection parameters, random tuning parameters, and enables and disables a different random subset of buggification points"_ (ibid.).

### Cancellation and teardown

Neither documents a first-class "this work was cancelled" observation. Crashes and restarts are injected faults (`crash_probability`, `restart_probability` in the VOPR's printed options), and the checks are consequences such as convergence and identical state. A test sees cancellation only through its effect on the invariants.

### Failure output

Reproduction is "rerun with the seed at this commit". The VOPR prints the seed before the run (`SEED={}` followed by every derived parameter) and, on a liveness failure, `log.err("you can reproduce this failure with seed={}", .{seed})` ([`src/vopr.zig`][tb-vopr]). Replay is `./zig/zig build vopr -- 123` ([`HACKING.md`][tb-hacking]). CI passes the commit hash itself as the seed: _"we run simulator on CI … with different, "random" seeds, but the failures remain reproducible just from the commit hash!"_ ([`src/stdx/testing/fuzz.zig`][tb-fuzz]). The trace is a dense per-replica status line (`3 [ /    .        3V  71/_99/_99C …`) documented column by column ([`docs/internals/testing.md`][tb-testing-doc]). FoundationDB adds that _"Adding additional logging, for instance, generally does not affect the deterministic ordering of events, so an exact reproduction is guaranteed"_ ([paper §6.2][fdb-paper]).

### Regrets and limits

FoundationDB: _"Simulation is not able to reliably detect performance issues … It is also unable to test third-party libraries or dependencies, or even first-party code not implemented in Flow. As a consequence, we have largely avoided taking dependencies on external systems"_ ([paper §4][fdb-paper]). The coverage problem is answered with `TEST( buffer.is_full() );` macros that count how many runs reached a condition (ibid.). Seeds are not shrunk; a failure is debugged at its original size. The VOPR refuses an unseeded run in a debug build: _"no seed provided: the simulator must be run with -OReleaseSafe"_ ([`src/vopr.zig`][tb-vopr]).

### Worked test (Zig-flavoured pseudo-VOPR, untested)

```zig
// One seed drives keystroke times, hash durations and the run order.
fn keystroke_during_hash(seed: u64) !void {
    var prng = stdx.PRNG.from_seed(seed);
    var sim = Simulator.init(.{ .debounce_ms = 500 });
    sim.input_at(0, "ab");
    const hash_ms = prng.range_inclusive(u32, 1, 2000);
    sim.hash_latency(hash_ms);
    // The keystroke lands inside the first hash, at a random offset.
    sim.input_at(500 + prng.range_inclusive(u32, 0, hash_ms - 1), "abc");
    while (sim.pending()) |_| sim.tick();
    // Invariants, not a transcript: the last query wins, and nothing is left over.
    assert(std.mem.eql(u8, sim.shown(), sim.hash_of("abc")));
    assert(sim.hashes_cancelled() == 1 and sim.live_jobs() == 0);
}
```

---

## madsim and turmoil: Rust simulation runtimes

madsim is a Rust async runtime that replaces tokio under `RUSTFLAGS="--cfg madsim"`. Its _"main idea is borrowed from [FoundationDB]"_, and it _"will amplify randomness, create chaos and inject failures into your system"_ ([`README.md`][madsim-readme]). turmoil _"runs multiple concurrent hosts within a single thread and injects "hardship" … under manual control or a seeded RNG"_ ([`README.md`][turmoil-readme]).

### Scripting inputs

Both drive ordinary async code. madsim runs the test body under `#[madsim::test]` with simulated nodes. turmoil registers `sim.host(…)` and `sim.client(…)` closures and then calls `sim.run()`, or `sim.step()` for manual control. Network faults are scripted from the test with `turmoil::partition`, `hold`, `release` and `repair` ([`lib.rs`][turmoil-lib]). turmoil's **barriers** are the closest analogue to a scriptable CPU pool. Source code is annotated with `turmoil::barriers::trigger(MyBarriers::PrepareAckReceived(id)).await`, and the test builds `Barrier::build(Reaction::Suspend, |t| …)`, steps with `barrier.step_until_triggered(&mut sim)`, and releases the suspended code by dropping the handle. `Reaction` is `Noop`, `Suspend` or `Panic` ([`barriers.rs`][turmoil-barriers]).

### Representing time

madsim's clock is virtual. `advance_to_next_event` jumps to the next timer, and every poll costs a random 50–100 ns: `let dur = Duration::from_nanos(self.rand.with(|rng| rng.gen_range(50..100))); self.time.handle().advance(dur);` ([`task/mod.rs`][madsim-task]). turmoil runs each host on a tokio current-thread runtime built with `.start_paused(true)` and advances it by a fixed `tick_duration` per `step`, or by any amount with `step_by(tick)`. Each host may have _"a different sense of "now" which simulates clock skew"_ ([`rt.rs`][turmoil-rt], [`sim.rs`][turmoil-sim]).

### Asserting outputs

Assertions are plain `assert!` inside the async code, or a client returning `Err`. `Sim::run` returns early _"if any host software errors"_ ([`sim.rs`][turmoil-sim]). Neither offers a transcript or snapshot facility.

### Concurrency and ordering

madsim randomizes the order of ready tasks: `run_all_ready` drains the queue with `self.queue.try_recv_random(&self.rand)` ([`task/mod.rs`][madsim-task]). turmoil runs hosts in insertion order unless `enable_random_order()` is set: _"This allows exploration of extra state space in multi-node simulations where race conditions may arise based on message send/receive order"_. Then `running.shuffle(&mut …rng)` runs once per step ([`builder.rs`][turmoil-builder], [`sim.rs`][turmoil-sim]). Inside one host, task order is tokio's own, which turmoil seeds through `tokio::runtime::RngSeed` only under `tokio_unstable` ([`rt.rs`][turmoil-rt]). Neither enumerates anything: both sample.

### Cancellation and teardown

madsim drops a cancelled task's future the next time it is scheduled (`if info.cancelled.load(…) || info.node.killed.load(…) { drop }`), and can kill and restart whole nodes ([`task/mod.rs`][madsim-task]). turmoil models crashes and bounces of hosts. In both, a test observes a cancellation by its effects. Neither has a "was this task cancelled and joined" query.

### Failure output

madsim prints the seed and re-raises the panic: _"note: run with \`MADSIM_TEST_SEED={seed}\` environment variable to reproduce this error"_ ([`runtime/mod.rs`][madsim-runtime]). `MADSIM_TEST_NUM` runs consecutive seeds, `MADSIM_TEST_JOBS` runs them in parallel, and `MADSIM_TEST_CHECK_DETERMINISM` _"will be run at least twice with the same seed. If any non-determinism detected, it will panic as soon as possible"_ ([`builder.rs`][madsim-builder]). The check records every random draw of the first run and compares the second run against it: _"non-determinism detected at {time:?}"_ ([`rand.rs`][madsim-rand]). turmoil takes the seed through `Builder::rng_seed(u64)`. By default _"this rng is randomly seeded"_, so a failure found without a fixed seed cannot be replayed unless the test logs the seed. `build_with_rng(next_u64)` lets a caller _"continue a run from a chosen step with other latencies and failures"_ ([`builder.rs`][turmoil-builder]).

### Regrets and limits

madsim must patch the ecosystem (`getrandom`, `quanta`, `tokio-retry`, … under `[patch.crates-io]` in its [README][madsim-readme]). Any dependency that reaches the OS breaks determinism, which is why the determinism check exists. Neither runtime shrinks a failing seed. turmoil's default of an OS-seeded RNG is the opposite of the VOPR's refusal to run unseeded in debug.

### Worked test (Rust, madsim-style, untested)

```rust
#[madsim::test] // MADSIM_TEST_SEED / MADSIM_TEST_NUM select the seeds
async fn keystroke_during_hash() {
    let (query, shown) = pipeline(Duration::from_millis(500)); // debounce → spawn_blocking hash
    query.send("ab".into());
    madsim::time::sleep(Duration::from_millis(500)).await; // debounce fires, hash starts
    let mid = madsim::rand::thread_rng().gen_range(1..200); // keystroke lands inside the hash
    madsim::time::sleep(Duration::from_millis(mid)).await;
    query.send("abc".into());
    madsim::time::sleep(Duration::from_secs(5)).await; // let everything settle
    assert_eq!(shown.borrow().as_deref(), Some(hash("abc").as_str()));
    assert_eq!(HASHES_CANCELLED.load(SeqCst), 1); // counted by the hash task's drop guard
}
```

---

## loom and shuttle: Rust schedule exploration

loom _"runs tests many times, permuting the possible concurrent executions of each test according to what constitutes valid executions under the C11 memory model"_ ([`src/lib.rs`][loom-lib]). shuttle is _"an implementation of a number of *randomized concurrency testing* techniques"_, PCT among them, and states the trade-off itself: _"Shuttle is not sound (a passing Shuttle test does not prove the code is correct), but it scales to much larger test cases than Loom"_ ([`README.md`][shuttle-readme]).

### Scripting inputs

The test body is an ordinary closure run many times: `loom::model(|| { … })`, `shuttle::check_random(|| { … }, 100)`, `check_pct(f, iterations, depth)` or `check_dfs(f, max_iterations)` ([`check.rs`][shuttle-check]). The code under test must use the tools' replacement types (`loom::sync::atomic::AtomicUsize`, `shuttle::sync::Mutex`, `…::thread::spawn`), usually behind `#[cfg(loom)]`. Environmental choices are drawn through the tool (`shuttle::rand`), so they become schedule steps too.

### Representing time

Neither models time. loom's `thread` module offers `spawn`, `park`, `yield_now` and no `sleep` ([`src/thread.rs`][loom-thread]). shuttle's timeouts are wall-clock budgets on the exploration (`max_duration`), not simulated time. A debounce has to be modelled as an explicit event ("the timer fires") that the test spawns as a thread.

### Asserting outputs

Plain `assert!` in the closure, checked in every execution. loom also checks for leaks after each run (`execution.check_for_leaks()`) and reports `"Completed in {} iterations"` ([`src/model.rs`][loom-model]).

### Concurrency and ordering

loom is exhaustive within bounds. It uses CDSChecker's techniques for _"equivalent execution elimination"_ ([`src/lib.rs`][loom-lib]), with `max_threads` (default 5), `max_branches` (default 1,000 thread switches per permutation), `max_permutations`, `max_duration` and `preemption_bound`. The docs advise that _"setting the thread pre-emption bound to 2 or 3 is enough to catch most bugs"_ ([`src/model.rs`][loom-model], [`src/lib.rs`][loom-lib]). shuttle offers uniform random walk, a random scheduler, PCT _"from the paper "A Randomized Scheduler with Probabilistic Guarantees of Finding Bugs", Burckhardt et al, ASPLOS 2010"_ (following Coyote's implementation), and DFS ([`pct.rs`][shuttle-pct]). shuttle claims its `check_random` example _"detects the assertion failure with extremely high probability (over 99.9999%)"_ in 100 iterations ([`README.md`][shuttle-readme]).

### Cancellation and teardown

Not modelled as a concept. A test observes a cancel only as a store to a flag and a `join`. Both tools do see a thread that never finishes: loom fails on a deadlock, and shuttle tears down remaining tasks at the end of an execution (`ExecutionState::tear_down`, [`failure.rs`][shuttle-failure]).

### Failure output

shuttle's failure output is a **schedule string**. A `Schedule` is `{ seed: u64, steps: Vec<ScheduleStep> }`, where a step is `Task(TaskId)` or `Random` ([`scheduler/mod.rs`][shuttle-schedule]), varint- and bit-packed into a short printable string ([`serialization.rs`][shuttle-serial]). The panic hook prints `"test panicked in task '{task_name}'"` and then _"failing schedule:\n\"\n{serialized_schedule}\n\"\npass that string to \`shuttle::replay\` to replay the failure"_, or writes `schedule000.txt` for `replay_from_file` ([`failure.rs`][shuttle-failure]). `SHUTTLE_RANDOM_SEED` fixes the seed ([`shuttle-engine/src/lib.rs`][shuttle-engine-lib]). loom has no printable schedule. Isolating a failure takes a checkpoint file and a re-run with logging: `LOOM_LOG=trace LOOM_LOCATION=1 LOOM_CHECKPOINT_INTERVAL=1 LOOM_CHECKPOINT_FILE=my_test.json … cargo test`, of which the docs admit _"(yes, we know this is not great... but it works)"_ ([`src/lib.rs`][loom-lib]).

### Regrets and limits

shuttle's own replay tests are disabled at this SHA: `#[ignore = "replay mechanism is broken because the schedule is not emitted in the panic output. reintroduce once replay mechanism is fixed."]` ([`tests/basic/replay.rs`][shuttle-replay]). So the most important feature of an explorer, the replay string, is the most fragile. shuttle has no automatic schedule shrinker. Its `shrink.rs` tests replay hand-minimised schedules such as `Schedule::new_from_task_ids(0, vec![0, 0, 2])` ([`tests/basic/shrink.rs`][shuttle-shrink]). loom is intrusive: _"Any code that does not use loom's replacement types is invisible to loom"_ ([`src/lib.rs`][loom-lib]).

### Worked test (Rust, shuttle-style, untested)

```rust
#[test]
fn keystroke_during_hash() {
    shuttle::check_pct(|| {
        let p = Arc::new(Pipeline::new()); // debounce timer and hash worker are shuttle threads
        let timer = { let p = p.clone(); thread::spawn(move || p.fire_debounce()) };
        p.input("ab");
        let hash1 = { let p = p.clone(); thread::spawn(move || p.run_hash()) };
        p.input("abc"); // races hash1: cancel token set before or after it checks
        timer.join().unwrap();
        hash1.join().unwrap(); // cancel-AND-join: the old hash has stopped
        p.fire_debounce();
        p.run_hash();
        assert_eq!(p.shown(), Some(hash("abc")));
        assert!(!p.shown_stale()); // hash("ab") was never published after "abc" arrived
    }, 1_000, 3);
}
```

Note that the 500 ms vanished: with no clock, "debounce expiry" is a thread the test spawns.

---

## Coyote and Lincheck: controlled scheduling on managed runtimes

Coyote rewrites .NET binaries so that `Task`, `async`/`await` and `lock` go through its scheduler, then runs a _"concurrency unit test"_ many times: _"once a bug is found, Coyote allows you to fully reproduce the exact same trace that led to the bug 100% of the time"_ ([`concurrency-unit-testing.md`][coyote-cut]). Lincheck is _"a practical and user-friendly framework for writing deterministic and robust concurrent tests on JVM"_ ([`README.md`][lincheck-readme]).

### Scripting inputs

Coyote's test is an ordinary async method run by `TestingEngine.Create(config, CoyoteTestMethod)` or `coyote test`. Mocks express environmental choice with `CoyoteRuntime.Random()`, whose _"exact value is chosen by the tester"_ ([`concurrency-unit-testing.md`][coyote-cut], [`unit-testing.md`][coyote-ut]). Lincheck has two styles. The first is `Lincheck.runConcurrentTest { … }` around arbitrary code. The second is declarative: `@Operation fun inc() = c.inc()` on a test class, from which Lincheck generates scenarios of `actorsBefore`/`actorsPerThread`/`actorsAfter` operations over `threads` threads ([`lincheck-how-to-test-data-structures.md`][lincheck-ds], [`lincheck-testing-strategies-options.md`][lincheck-options]). The two styles meet in `customScenarios { initial { … } parallel { thread { … } } post { … } }`: hand-written scenarios that _"are executed before the randomly generated ones"_ (ibid.).

### Representing time

Neither has virtual time in the debounce sense. Coyote turns `Task.Delay(d)` into a nondeterministic pause whose length ignores `d`: `uint timeout = (uint)this.GetNextNondeterministicIntegerChoice((int)this.Configuration.TimeoutDelay, …)`, and `WithTimeoutDelay` documents that _"This value is not a unit of time"_ ([`CoyoteRuntime.cs`][coyote-runtime], [`Configuration.cs`][coyote-config]). A 500 ms debounce and a 5 ms one are explored identically. The Lincheck docs describe no clock at all.

### Asserting outputs

Coyote: `Specification.Assert(cond, msg)` plus safety and liveness monitors. Lincheck: plain assertions in `runConcurrentTest`. In the declarative style, the verdict is linearizability against a sequential run of the same operations (`sequentialSpecification` to supply a model): _"The results of one execution schedule are compared to the results of the same operations executed sequentially"_ ([`lincheck-how-to-test-data-structures.md`][lincheck-ds]).

### Concurrency and ordering

Coyote offers `random`, `probabilistic`, `prioritization` (PCT, `WithPrioritizationStrategy(isFair, priorityChangeBound)`), `delay-bounding` and Q-learning strategies, and by default _"a tuned portfolio of strategies"_ ([`Configuration.cs`][coyote-config]). Lincheck's model checking _"inserts explicit thread-switch instructions at points of shared-memory access (`read` and `write`) or at synchronization points"_, assumes sequential consistency, and is contrasted with stress testing, where _"tests are not reproducible, and Lincheck cannot provide an execution trace"_ ([`lincheck-testing-strategies.md`][lincheck-strategies]). Its defaults are `iterations` = 100 scenarios × `invocationsPerIteration` = 10,000 schedules each ([`lincheck-testing-strategies-options.md`][lincheck-options]).

### Cancellation and teardown

Lincheck is the one tool here with cancellation as a first-class explored event. `@Operation(cancellableOnSuspension = true)` makes Lincheck explore _"the scenarios where `receive()` is suspended and then gets canceled"_, and results print as `receive() + cancel` ([`lincheck-operation-execution-options.md`][lincheck-exec]). Coyote orders _"Cancellation and completion … as they are in production"_ for `WaitAsync`/`WaitAll` ([`binary-rewriting.md`][coyote-rewrite]), but its delay path carries `// TODO: support cancellations during testing.` ([`CoyoteRuntime.cs`][coyote-runtime]).

### Failure output

Coyote writes a `.txt` log and a `.trace` file. `coyote replay .\AccountManager.dll AccountManager_0_0.trace` reproduces the run (`... Reproduced 1 bug (use --break to attach the debugger).`), and `WithReproducibleTrace(trace)` does the same from a test ([`first-concurrency-unit-test.md`][coyote-tutorial], [`Configuration.cs`][coyote-config]). Its summary reports coverage of the exploration (`Explored 26 schedules: 26 fair and 0 unfair.`, `Found 3.85% buggy schedules.`). Lincheck prints the interleaving as a table, one column per thread, down to each read and write:

```text
| ------------------------------------------------------------------------------- |
|                   Main Thread                   |   Thread 1    |   Thread 2    |
| ------------------------------------------------------------------------------- |
| switch (reason: waiting for Thread 1 to finish) |               |               |
|                                                 |               | run()         |
|                                                 |               |   counter ➜ 0 |
|                                                 |               |   switch      |
|                                                 | run()         |               |
|                                                 |   counter ➜ 0 |               |
|                                                 |   counter = 1 |               |
|                                                 |               |   counter = 1 |
| assertEquals(2, 1): threw AssertionFailedError  |               |               |
```

([`lincheck-getting-started.md`][lincheck-start], abridged). For declarative tests, the failed scenario is **minimised** by default: Lincheck _"tries to minimize the failed scenario by removing the operations that do not change the behavior of the test"_, so a 3 + 3×2 + 3 scenario shrinks to `inc(): 1 | inc(): 1` ([`lincheck-testing-strategies-options.md`][lincheck-options]).

### Regrets and limits

Coyote's interleaving mode cannot express "the timer fires after 500 ms" (see above). Lincheck dropped its original package for 3.0 and _"now focuses on testing arbitrary concurrent code still providing declarative API for testing concurrent data structures"_ ([`README.md`][lincheck-readme]). Arbitrary-code tests were the ones users wanted. Lincheck's model checking misses relaxed-memory bugs by design ([`lincheck-testing-strategies.md`][lincheck-strategies]).

### Worked test (Kotlin, Lincheck `runConcurrentTest`, untested)

```kotlin
@Test
fun keystrokeDuringHash() = Lincheck.runConcurrentTest(10_000) {
    val p = Pipeline(debounceMs = 500, clock = ManualClock()) // time must be hand-rolled
    p.input("ab")
    p.clock.advance(500)                       // debounce fires; hash job starts on a thread
    val hasher = thread { p.runPendingHash() } // switch points inside the hash loop
    p.input("abc")                             // races the hasher's cancellation check
    hasher.join()                              // cancel-and-join
    p.clock.advance(500)
    p.runPendingHash()
    assertEquals(hash("abc"), p.shown)
    assertEquals(listOf("ab:cancelled", "abc:done"), p.hashLog)
}
```

---

## Hedgehog and proptest-state-machine: state-machine property testing

Here the explored dimension is the **input sequence**, not the schedule. A model plus a set of commands generates sequences, runs them against the system, and shrinks a failing one. proptest's book: it _"attempts to shrink it to a minimal sequence of transitions that still reproduce the issue"_ ([`state-machine.md`][proptest-sm]).

### Scripting inputs

Hedgehog: each `Command gen execute [callbacks]` has a generator that may return `Nothing` when the command is impossible in the current state. `Gen.sequential (Range.linear 1 100) initialState [newRef, readRef, writeRef, incRef 2]` produces the sequence and `executeSequential` runs it ([`References.hs`][hh-example]). Outputs of earlier commands are referenced through symbolic variables (`Var output Symbolic`), which _"provide a token to stand in for the actual variables at generation time"_ ([`State.hs`][hh-state]). proptest-state-machine: `ReferenceStateMachine` (`init_state`, `transitions(state)`, `apply`, `preconditions`) plus `StateMachineTest` (`init_test`, `apply`, `check_invariants`, `teardown`), run by `prop_state_machine! { fn name(sequential 1..20 => MyTest); }` ([`state-machine.md`][proptest-sm]).

### Representing time

Not modelled. For the debounce pipeline, "advance the clock by _d_" becomes one more command in the alphabet, beside `type(text)`, `completeHash`, `toggle` and `setInterval(n)`, and the model must predict what each advance releases.

### Asserting outputs

Hedgehog's callbacks are `Require` (precondition, _"mainly used during shrinking to ensure that it is still OK to run a command despite the fact that some previously executed commands may have been removed"_), `Update` (the model transition, polymorphic over `Symbolic`/`Concrete`) and `Ensure` (the postcondition on old state, new state, input and output) ([`State.hs`][hh-state]). proptest puts postconditions in `StateMachineTest::apply` and global ones in `check_invariants` ([`state-machine.md`][proptest-sm]).

### Concurrency and ordering

Hedgehog's `Gen.parallel` builds a prefix and two branches. `executeParallel` runs the branches on real threads (`Async.concurrently`) and passes if _"there is at least one sequential interleaving where all the post-conditions are met"_. `linearize` enumerates `interleave branch1 branch2` and otherwise fails with `"no valid interleaving"` ([`State.hs`][hh-state]). The schedule is not controlled, so the example wraps the property in `withRetries 10` ([`References.hs`][hh-example]). proptest-state-machine has no concurrent mode: _"Currently, only sequential strategy is supported, but a concurrent strategy is planned to be added at later point"_ ([`state-machine.md`][proptest-sm]).

### Cancellation and teardown

Only as a command the model knows (`toggleOff` → model clears the pending query). proptest's `teardown(state, ref_state)` runs per case ([`state-machine.md`][proptest-sm]). Neither library observes a join.

### Failure output

Hedgehog prints the shrunk command list and a reproduction line built by `ppReproduce`: _"This failure can be reproduced by running:"_ followed by `recheckAt <seed> <skip> <property>` ([`Report.hs`][hh-report]). Parallel failures render as `━━━ Prefix ━━━` / `━━━ Branch 1 ━━━` / `━━━ Branch 2 ━━━` with each action's result ([`State.hs`][hh-state]). proptest records failures in a checked-in regressions file that is _"automatically read and these particular cases re-run before any novel cases are generated"_, one `cc <hash> # shrinks to …` line per case ([`strategy.txt`][proptest-regress]).

### Regrets and limits

Shrinking is the payoff, and proptest documents its order: delete transitions from the back, then shrink individual transitions from the front, then shrink the initial state, with `complicate` to undo a shrink that lost the failure ([`state-machine.md`][proptest-sm]). The book cites the shrinker as `proptest/src/strategy/state_machine.rs`, a path that does not exist at this SHA. The code is `proptest-state-machine/src/strategy.rs`. Hedgehog's source carries `-- FIXME we should not abuse Show to get nice output for actions` twice ([`State.hs`][hh-state]). Readable failure output was bolted on.

### Worked test (Haskell, Hedgehog-style, untested)

```haskell
-- Commands: Type s | Advance ms | CompleteHash. The model tracks the pending query,
-- the debounce deadline and the in-flight hash; Ensure checks shown == model.
prop_keystrokeDuringHash :: Property
prop_keystrokeDuringHash = property $ do
  -- The scripted case is one fixed sequence of the same commands …
  let scripted = [Type "ab", Advance 500, Type "abc", Advance 500, CompleteHash, CompleteHash]
  -- … the explored case generates and shrinks sequences from the same alphabet.
  actions <- forAll $ Gen.sequential (Range.linear 1 30) initialModel
               [cmdType, cmdAdvance, cmdCompleteHash]
  sut <- evalIO newPipelineUnderTestClock
  executeSequential initialModel actions
  -- Ensure (inside cmdCompleteHash): a stale hash completes as Cancelled, never Shown.
```

---

## Local baseline: the task-DAG harness, `TestSched` and the sync model

The repository already has both ends of the spectrum. The task-DAG harness scrambles completion orders by enumeration. The sync primitives have a CHESS/loom-style model checker with DPOR and PCT.

### Scripting inputs

`FakeDriver` runs each task from a `Script`: `duration` (slept on the virtual clock), `outcome`, `lines` of output (a leading `!` for stderr), `yields`, `ignoresCancel` and `freshness`. `runFake(g, scripts, options, cancelAt, cancelCause)` runs a whole executor under `TestSched` and a `TestClock`, with an optional outside fiber that calls `executor.cancel(cancelCause)` at virtual time `cancelAt` ([`task/testing.d`][local-task-testing]).

### Representing time

`TestClock` holds sleepers in deadline order, _"FIFO among equals"_, and `advance`/`advanceToNext` wake them in that order ([`clock.d`][local-clock]). `advanceAndSettle` is _"settle, advance virtual time to the next deadline, repeat — until no task is ready and no sleeper is pending"_ ([`testing.d`][local-eh-testing]).

### Asserting outputs

`Run` records the event stream, `startOrder`, `peakWeight` and per-task `startedAt`/`finishedAt`, and `countOf!pred(events)` counts events. Transcripts are asserted byte-exact. `transcriptIsIdenticalAcrossCompletionOrders` renders each run through `PlainReporter` and asserts `text == expected` against one literal ([`reporter_plain.d`][local-reporter]).

### Concurrency and ordering

`TestSched` itself is fully deterministic: a FIFO ready list (`enqueue` appends, `dequeue` takes the head) and no choice anywhere ([`testing.d`][local-eh-testing]). Orders are scrambled **from outside**, through the scripts, in exactly three ways:

1. **Duration permutations.** `permutations(items)` returns every permutation _"in lexicographic order of positions"_ ([`task/testing.d`][local-task-testing]). Tests assign them as durations, so completion order follows: `foreach (durations; permutations([1, 2, 3, 4, 5]))` runs 120 executions and asserts `runs == 120` ([`reporter_plain.d`][local-reporter]). `outcomesIndependentOfCompletionOrder` does the same over `permutations([1, 2, 3])` for a diamond graph ([`executor.d`][local-executor]).
2. **Same-instant reordering with `yields`.** Equal deadlines wake FIFO, so tasks finishing at the same virtual instant are reordered by `Script.yields`: the driver calls `ctx.exec.wake(ctx.exec.currentContext()); ctx.exec.park();` that many times, moving itself to the back of the ready queue. `failFast.simultaneousFailuresPickTheLowestKey` permutes declaration order and gives every task but `c` one yield, so _"their completions reach the scheduler in one turn as c, a, b"_ ([`executor.d`][local-executor]).
3. **Two-point sweeps.** `foreach (dDuration; [2.msecs, 20.msecs])` puts one task before or after a failure ([`executor.d`][local-executor]).

The sync model checker is the explorer. Simulated threads are fibers. At each scheduling point the explorer picks the next thread, depth-first, with classic DPOR (_"Flanagan and Godefroid 2005"_) and a `preemptionBound`, or under `Strategy.pct` with `pctRuns`, `pctDepth` and a recorded `seed` ([`sync/model.d`][local-model]). Value choices (`chooseValue(n)`) are nodes on the same path as thread choices, so environment events (spurious wakes, timeouts, cancellations) are explored with the schedule.

### Cancellation and teardown

`runFake` asserts `sched.liveFibers == 0` (_"the run left a fiber behind"_) after every run, and the driver reports `Cancelled(CancelReason.interrupted)` when `ctx.cancelRequested` unless `ignoresCancel` ([`task/testing.d`][local-task-testing]). Tests then assert `countOf!((CancellationRequested c) => …) == 1, "exactly once"` and `"e" !in run.startedAt, "no admission after cancellation"` ([`executor.d`][local-executor]). The model checker fails any execution that leaves a thread _"blocked forever: a lost wakeup or a deadlock"_ ([`sync/model.d`][local-model]).

### Failure output

The task-DAG tests reproduce trivially: the loop variable **is** the schedule, so a failing permutation re-runs by itself. Its index is not printed, though. `assert(text == expected, text)` prints the whole actual transcript, not a diff, and not which permutation produced it ([`reporter_plain.d`][local-reporter]). The model checker re-runs the failing path with tracing on (`replayTrace`) and throws `"model check failed after N executions: <failure>\n<trace>"`, one `T<id>: <op>` line per step ending in `=> <failure>`. A replay that diverges fails with _"the scenario is not deterministic: a replayed schedule diverged"_ ([`sync/model.d`][local-model]). The path itself is not serialised, so a failure cannot be replayed from a string in a later process.

### Regrets and limits

Permutations grow factorially and only cover what durations can express: the order of completions, not the order of ready fibers within one turn (that takes hand-placed `yields`). The model checker is specific to the sync seam (`maxThreads = 4`, `ubyte` enabled-masks, `ModelAtomic`), so it cannot drive `TestSched` fibers as it stands. Measured on 2026-11-24 in a `dub test` debug build on this host: the 120 executor runs of `transcriptIsIdenticalAcrossCompletionOrders` take **11 ms** (about 10,000 runs/s), and the model checker's `sync.model.SYM.mutualExclusionTwoThreads` takes 2.2 ms, `SYM6.threeLockersOneDesignation` 142 ms, and the seeded-fault `SYM6.seededFault.wakeDespiteDesignation` 4.9 s.

### Worked test (D, scripted with today's tools, untested)

```d
@("reactive.pipeline.keystrokeDuringHash.scripted")
@system unittest
{
    TestSched sched;
    auto clock = TestClock!(TestSched.Waker)(sched.waker());
    TestCpuPool pool;                                 // proposed: jobs pend until run
    auto app = PipelineUnderTest(&sched, &clock, &pool, debounce: 500.msecs);
    app.query.set("ab");
    advanceAndSettle(sched, clock);                   // debounce expires; hash("ab") pends
    assert(pool.pending.length == 1);
    app.query.set("abc");                             // keystroke while hashing
    sched.settle();
    assert(pool.pending[0].cancelRequested);          // token observed; job still pending
    pool.complete(0);                                 // the job finishes anyway…
    advanceAndSettle(sched, clock);                   // …is joined, discarded; new debounce, new job
    pool.complete(0);
    sched.settle();
    checkWriter!((ref w) => app.writeTranscript(w))(
        "t=0 query ab\nt=500 hash#1 start ab\nt=500 query abc\nt=500 hash#1 cancel superseded\n"
        ~ "t=500 hash#1 joined\nt=1000 hash#2 start abc\nt=1000 shown hash(abc)\n");
    assert(sched.liveFibers == 0);
}
```

---

## Proposal: exploring `TestSched`'s choice points

In a fiber-based single-threaded harness, nondeterminism has exactly the places listed below, all inside harness code the test owns. Exploration therefore needs no binary rewriting (Coyote), replacement types (loom, shuttle) or ecosystem patches (madsim).

| Choice point                   | Where it is decided today                                                | Alternatives at that point                                                   |
| ------------------------------ | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| **Ready fiber**                | `TestSched.dequeue` takes `_readyHead` ([`testing.d`][local-eh-testing]) | any fiber on the ready list                                                  |
| **CPU job completion**         | the test calls `pool.complete(i)` (proposed `TestCpuPool`)               | any pending job; for a job whose token is set: finish anyway, or observe it  |
| **Clock advance vs. delivery** | `advanceAndSettle` advances whenever the ready list is empty             | at quiescence: advance to the next deadline, or complete a pending job first |
| **Same-deadline sleepers**     | `TestClock.insertSleeper`, FIFO among equals ([`clock.d`][local-clock])  | any order of the sleepers due at one instant                                 |
| **Scripted input timing**      | the test's own `set`/`advance` calls                                     | the input before or after the next settle (a test-declared choice)           |

1. **One `Chooser` seam.** Add `uint choose(ChoiceKind kind, uint n)` to the harness. `TestSched.settle` asks for `ChoiceKind.ready` when more than one fiber is ready, and `TestCpuPool` and a new `explore`-aware `advanceAndSettle` ask for `ChoiceKind.quiescence` with the pending jobs plus "advance the clock" as alternatives. Alternative 0 is always today's behaviour (FIFO head, advance the clock, FIFO sleeper). So `FifoChooser` (choose 0) **is** the scripted harness, and every existing test keeps its transcript byte for byte.
2. **Five strategies over one path.** `ReplayChooser(string)` replays a path. `RandomChooser(seed)` is madsim/shuttle sampling. `PctChooser(seed, depth)` is the randomized priority scheduler. `DfsChooser` is exhaustive search, reusing the shape of `sync/model.d`'s `Node`/`nextPath`/`chooseValue` (a value node per choice) without its thread masks. Because every choice point is a harness call, a path is just a `uint[]` of choices, with the `n` at each point recorded so that divergence is detected the way `model.d` detects it.
3. **Report a replayable string, then a diff.** On failure, print the strategy, the seed and the path as a short string in the spirit of shuttle's schedule, readable rather than varint-packed (`r1 q0 q2 r0` = ready #1, quiescence alternative 0, …), then the failing run's transcript **diffed** against the reference transcript (run 0, the FIFO schedule) through `checkWriter`. The shuttle regression above, where replay broke because the schedule stopped reaching the panic output, argues for a test of the report itself: a seeded-fault scenario whose printed string must replay the failure. That mirrors `exploreExpectingFailure` ([`sync/model.d`][local-model]).
4. **One scenario, two assertions.** A scenario is a D delegate over the harness (`void delegate(ref Sim)`) that performs the inputs. Run once under `FifoChooser`, it is asserted byte-exact like today's transcripts. Run under `explore`, it is asserted with **invariants** that must hold on every schedule. The invariants are: the last query's hash is shown; every started hash is either shown or `cancelled(superseded)` and joined; nothing is shown after a newer query arrived; `liveFibers == 0` and `pool.pending.length == 0`. Two transcript properties fit too: schedule-independence where it is promised (as `transcriptIsIdenticalAcrossCompletionOrders` already asserts), or membership in a small set of allowed transcripts. This is Lincheck's `customScenarios` beside generated ones, and Hedgehog's fixed sequence beside a generated one, in D.
5. **Shrink both axes.** First shrink the schedule: greedily reset non-zero choices to 0 (the FIFO default) and drop trailing choices while the failure persists. This automates what shuttle's `shrink.rs` does by hand, and the result reads as "FIFO except at these points". Then, if inputs are generated, shrink the input sequence in proptest's documented order (delete from the back, shrink elements from the front).
6. **Check determinism like madsim.** Run every explored scenario's first path twice and compare the recorded choice lists (`n` per point). A mismatch means the scenario reads something outside the harness, such as a hash-map iteration order, the real clock or a GC finaliser.
7. **Budget.** At roughly 10,000 small executor runs per second in a debug build (measured above), and with the keystroke-during-hash scenario holding perhaps four fibers and two CPU jobs, exhaustive DFS with a bound of 2 preemption-like deviations from FIFO should finish in milliseconds. The estimate is unmeasured. PCT with a fixed seed list covers whole-app pipelines, and `@slow` takes the large sweeps out of `ci test` the way the sync seeded-fault scenarios already run for seconds.

---

## Comparison

| System                     | Input notation                                       | Time                                               | Assertion style                                 | Concurrency handling                                             | Cancel observable?                                               | Failure diff                                                       |
| -------------------------- | ---------------------------------------------------- | -------------------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------ |
| FoundationDB / TigerBeetle | seed → swarm options; composable workloads           | discrete-event, fast-forward to next event (ticks) | in-code assertions + checkers, liveness phase   | single-threaded; sampled reorderings, faults, buggification      | only through invariants                                          | seed (+ commit); per-replica status trace; no diff                 |
| madsim / turmoil           | async test body; `hold`/`partition`; barriers        | virtual; madsim +50–100 ns per poll; turmoil ticks | `assert!` in tasks                              | random ready-task pick (madsim); shuffled hosts (turmoil)        | by effect; turmoil barriers can suspend code                     | `MADSIM_TEST_SEED=…` note; determinism check; no diff              |
| loom / shuttle             | closure re-run per execution                         | none                                               | `assert!` per execution                         | loom exhaustive (bounded, reduced); shuttle random/PCT/DFS       | no concept                                                       | shuttle schedule string / file; loom checkpoint JSON + `LOOM_LOG`  |
| Coyote / Lincheck          | async test method; `@Operation`s + `customScenarios` | Coyote: delay = random step count; Lincheck: none  | `Specification.Assert`; linearizability verdict | controlled scheduler; portfolio / PCT; SC model checking         | Lincheck `+ cancel` per operation; Coyote delay cancel TODO      | `.trace` + `coyote replay`; Lincheck per-thread interleaving table |
| Hedgehog / proptest-sm     | model + commands, generated sequence                 | none (a command)                                   | `Require`/`Update`/`Ensure`; `check_invariants` | Hedgehog: real threads + linearize check; proptest: none         | only as a modelled command                                       | shrunk command list; `recheckAt` seed; regressions file            |
| sparkles task DAG / sync   | `Script` per task; `permutations`; `yields`          | `TestClock`, FIFO among equal deadlines            | byte-exact transcript, `countOf`, `liveFibers`  | FIFO `TestSched`; orders scrambled via durations; sync: DPOR/PCT | `Cancelled(interrupted)` outcome; `CancellationRequested` events | whole actual transcript (no diff); sync: replayed `T<id>:` trace   |

## Lessons for the D harness

1. **Make the seed or path the complete test case, and print it before the run as well as after.** The VOPR logs `SEED=` first and rejects unseeded debug runs, while turmoil's default OS seed loses a failure that nobody logged ([FDB/TigerBeetle](#foundationdb-and-tigerbeetle-deterministic-simulation-testing), [madsim/turmoil](#madsim-and-turmoil-rust-simulation-runtimes)).
2. **Replay needs its own regression test.** shuttle's replay tests are `#[ignore]`d because the schedule stopped reaching the panic output. A seeded-fault scenario whose printed string must reproduce the failure keeps that path honest ([loom/shuttle](#loom-and-shuttle-rust-schedule-exploration); `exploreExpectingFailure` in the [local baseline](#local-baseline-the-task-dag-harness-testsched-and-the-sync-model)).
3. **Keep virtual time real.** Coyote reduces `Task.Delay(500)` to a random step count, and loom and shuttle have no clock. For a debounce, only a deadline-ordered `TestClock` makes "expiry vs. keystroke" a meaningful choice, so exploration must treat "advance the clock" as one alternative at quiescence and never shorten a duration ([Coyote/Lincheck](#coyote-and-lincheck-controlled-scheduling-on-managed-runtimes)).
4. **Make cancellation an explored event with a visible verdict.** Lincheck's `cancellableOnSuspension` and its `+ cancel` result column are the model. `TestCpuPool` should offer "finish anyway" and "observe the token" as choices for a cancelled job, and the transcript should name `cancel superseded` and `joined` ([Coyote/Lincheck](#coyote-and-lincheck-controlled-scheduling-on-managed-runtimes); `ignoresCancel` in the [local baseline](#local-baseline-the-task-dag-harness-testsched-and-the-sync-model)).
5. **One scenario, two oracles.** Scripted runs assert a byte-exact transcript, and explored runs assert invariants or schedule-independence. Lincheck's `customScenarios` run before generated ones, and Hedgehog's commands serve both a fixed and a generated sequence ([Coyote/Lincheck](#coyote-and-lincheck-controlled-scheduling-on-managed-runtimes), [Hedgehog/proptest](#hedgehog-and-proptest-state-machine-state-machine-property-testing)).
6. **Default choice 0 must equal today's FIFO behaviour,** so the explorer is a strict superset of the scripted harness and existing transcripts stay valid ([proposal](#proposal-exploring-testscheds-choice-points)).
7. **Shrink, and shrink towards the default schedule.** Lincheck minimises scenarios by default and proptest documents a delete-back/shrink-front order, while shuttle and the seed-based simulators do not shrink at all. A schedule that reads "FIFO except at choices 3 and 7" is the readable failure ([loom/shuttle](#loom-and-shuttle-rust-schedule-exploration), [Hedgehog/proptest](#hedgehog-and-proptest-state-machine-state-machine-property-testing)).
8. **Print a diff, not the whole actual output.** Today `assert(text == expected, text)` dumps the transcript without saying which permutation produced it. Route explored failures through `checkWriter` against the FIFO run's transcript, and print the path alongside ([local baseline](#local-baseline-the-task-dag-harness-testsched-and-the-sync-model)).
9. **Detect hidden nondeterminism by running twice.** madsim's `MADSIM_TEST_CHECK_DETERMINISM` and `model.d`'s "a replayed schedule diverged" both catch scenarios that read outside the harness ([madsim/turmoil](#madsim-and-turmoil-rust-simulation-runtimes), [local baseline](#local-baseline-the-task-dag-harness-testsched-and-the-sync-model)).
10. **Explore the few explicit choice points exhaustively, and sample only what does not fit.** loom's bounded exhaustive search and the repository's own DPOR explorer show that small models finish in milliseconds. PCT with recorded seeds (shuttle, Coyote, `Strategy.pct`) covers whole-app pipelines under `@slow` ([loom/shuttle](#loom-and-shuttle-rust-schedule-exploration), [local baseline](#local-baseline-the-task-dag-harness-testsched-and-the-sync-model)).
11. **Count coverage of the races you care about.** FoundationDB's `TEST(buffer.is_full())` and Coyote's "Explored 26 schedules … 3.85% buggy" make an exploration's reach visible. A counter for "keystroke arrived while a hash was pending" tells whether a strategy reaches the race at all ([FDB/TigerBeetle](#foundationdb-and-tigerbeetle-deterministic-simulation-testing), [Coyote/Lincheck](#coyote-and-lincheck-controlled-scheduling-on-managed-runtimes)).

## Sources

- FoundationDB: Zhou et al., _FoundationDB: A Distributed Unbundled Transactional Key Value Store_, SIGMOD 2021, §4 and §6.2 ([PDF][fdb-paper], DOI [10.1145/3448016.3457559][fdb-doi]); [Simulation and Testing][fdb-testing]; Will Wilson, _Testing Distributed Systems w/ Deterministic Simulation_, Strange Loop 2014 ([video][fdb-talk], not re-watched).
- TigerBeetle @ `a2a3c706`: [`src/vopr.zig`][tb-vopr], [`docs/internals/vopr.md`][tb-vopr-doc], [`docs/internals/testing.md`][tb-testing-doc], [`docs/internals/HACKING.md`][tb-hacking], [`src/stdx/testing/fuzz.zig`][tb-fuzz].
- madsim @ `519950ef`: [`README.md`][madsim-readme], [`runtime/builder.rs`][madsim-builder], [`runtime/mod.rs`][madsim-runtime], [`task/mod.rs`][madsim-task], [`rand.rs`][madsim-rand].
- turmoil @ `2bdbe89d`: [`README.md`][turmoil-readme], [`builder.rs`][turmoil-builder], [`sim.rs`][turmoil-sim], [`rt.rs`][turmoil-rt], [`barriers.rs`][turmoil-barriers], [`lib.rs`][turmoil-lib].
- loom @ `9d549cd5`: [`src/lib.rs`][loom-lib], [`src/model.rs`][loom-model], [`src/thread.rs`][loom-thread].
- shuttle @ `72bdbdb6`: [`README.md`][shuttle-readme], [`check.rs`][shuttle-check], [`pct.rs`][shuttle-pct], [`failure.rs`][shuttle-failure], [`scheduler/mod.rs`][shuttle-schedule], [`serialization.rs`][shuttle-serial], [`shuttle-engine/src/lib.rs`][shuttle-engine-lib], [`tests/basic/replay.rs`][shuttle-replay], [`tests/basic/shrink.rs`][shuttle-shrink].
- Coyote @ `0c51dc58`: [`concurrency-unit-testing.md`][coyote-cut], [`unit-testing.md`][coyote-ut], [`first-concurrency-unit-test.md`][coyote-tutorial], [`binary-rewriting.md`][coyote-rewrite], [`Configuration.cs`][coyote-config], [`CoyoteRuntime.cs`][coyote-runtime].
- Lincheck @ `a1e02bfd`: [`README.md`][lincheck-readme], [`lincheck-testing-strategies.md`][lincheck-strategies], [`lincheck-testing-strategies-options.md`][lincheck-options], [`lincheck-getting-started.md`][lincheck-start], [`lincheck-how-to-test-data-structures.md`][lincheck-ds], [`lincheck-operation-execution-options.md`][lincheck-exec].
- Hedgehog @ `7845181d`: [`Hedgehog/Internal/State.hs`][hh-state], [`Hedgehog/Internal/Report.hs`][hh-report], [`Test/Example/References.hs`][hh-example].
- proptest @ `70cf37d4`: [`book/src/proptest/state-machine.md`][proptest-sm], [`proptest-state-machine/proptest-regressions/strategy.txt`][proptest-regress].
- Local: [`task/testing.d`][local-task-testing], [`task/executor.d`][local-executor], [`task/reporter_plain.d`][local-reporter], [`event_horizon/testing.d`][local-eh-testing], [`event_horizon/clock.d`][local-clock], [`base/sync/model.d`][local-model], [sync testing spec][local-sync-spec], [`event-horizon` SPEC][eh-spec]; siblings [index], [concepts], [comparison].

<!-- References -->

[fdb-paper]: https://www.foundationdb.org/files/fdb-paper.pdf
[fdb-doi]: https://doi.org/10.1145/3448016.3457559
[fdb-testing]: https://apple.github.io/foundationdb/testing.html
[fdb-talk]: https://www.youtube.com/watch?v=4fFDFbi3toc
[tb-vopr]: https://github.com/tigerbeetle/tigerbeetle/blob/a2a3c7064519e08233abe26c54a43fca2f9ad9bc/src/vopr.zig
[tb-vopr-doc]: https://github.com/tigerbeetle/tigerbeetle/blob/a2a3c7064519e08233abe26c54a43fca2f9ad9bc/docs/internals/vopr.md
[tb-testing-doc]: https://github.com/tigerbeetle/tigerbeetle/blob/a2a3c7064519e08233abe26c54a43fca2f9ad9bc/docs/internals/testing.md
[tb-hacking]: https://github.com/tigerbeetle/tigerbeetle/blob/a2a3c7064519e08233abe26c54a43fca2f9ad9bc/docs/internals/HACKING.md
[tb-fuzz]: https://github.com/tigerbeetle/tigerbeetle/blob/a2a3c7064519e08233abe26c54a43fca2f9ad9bc/src/stdx/testing/fuzz.zig#L90-L107
[madsim-readme]: https://github.com/madsim-rs/madsim/blob/519950efb4711464f300ed7edf2967ed62d5f502/README.md
[madsim-builder]: https://github.com/madsim-rs/madsim/blob/519950efb4711464f300ed7edf2967ed62d5f502/madsim/src/sim/runtime/builder.rs
[madsim-runtime]: https://github.com/madsim-rs/madsim/blob/519950efb4711464f300ed7edf2967ed62d5f502/madsim/src/sim/runtime/mod.rs#L178-L210
[madsim-task]: https://github.com/madsim-rs/madsim/blob/519950efb4711464f300ed7edf2967ed62d5f502/madsim/src/sim/task/mod.rs#L262-L322
[madsim-rand]: https://github.com/madsim-rs/madsim/blob/519950efb4711464f300ed7edf2967ed62d5f502/madsim/src/sim/rand.rs
[turmoil-readme]: https://github.com/tokio-rs/turmoil/blob/2bdbe89d7e72359e13eb6149dcba29c8535ba39f/README.md
[turmoil-builder]: https://github.com/tokio-rs/turmoil/blob/2bdbe89d7e72359e13eb6149dcba29c8535ba39f/crates/turmoil/src/builder.rs
[turmoil-sim]: https://github.com/tokio-rs/turmoil/blob/2bdbe89d7e72359e13eb6149dcba29c8535ba39f/crates/turmoil/src/sim.rs#L389-L520
[turmoil-rt]: https://github.com/tokio-rs/turmoil/blob/2bdbe89d7e72359e13eb6149dcba29c8535ba39f/crates/turmoil/src/rt.rs
[turmoil-barriers]: https://github.com/tokio-rs/turmoil/blob/2bdbe89d7e72359e13eb6149dcba29c8535ba39f/crates/turmoil/src/barriers.rs
[turmoil-lib]: https://github.com/tokio-rs/turmoil/blob/2bdbe89d7e72359e13eb6149dcba29c8535ba39f/crates/turmoil/src/lib.rs
[loom-lib]: https://github.com/tokio-rs/loom/blob/9d549cd5357a5485900f4c53951fc1726319659f/src/lib.rs
[loom-model]: https://github.com/tokio-rs/loom/blob/9d549cd5357a5485900f4c53951fc1726319659f/src/model.rs
[loom-thread]: https://github.com/tokio-rs/loom/blob/9d549cd5357a5485900f4c53951fc1726319659f/src/thread.rs
[shuttle-readme]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/README.md
[shuttle-check]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle-schedulers/src/check.rs
[shuttle-pct]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle-schedulers/src/pct.rs
[shuttle-failure]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle-engine/src/runtime/failure.rs
[shuttle-schedule]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle-engine/src/scheduler/mod.rs
[shuttle-serial]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle-engine/src/scheduler/serialization.rs
[shuttle-engine-lib]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle-engine/src/lib.rs
[shuttle-replay]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle/tests/basic/replay.rs
[shuttle-shrink]: https://github.com/awslabs/shuttle/blob/72bdbdb612c2311905c84bbc73d59f12a5b17e43/shuttle/tests/basic/shrink.rs
[coyote-cut]: https://github.com/microsoft/coyote/blob/0c51dc58cc34cdefa24dcfabf3439e5e0ec77309/docs/concepts/concurrency-unit-testing.md
[coyote-ut]: https://github.com/microsoft/coyote/blob/0c51dc58cc34cdefa24dcfabf3439e5e0ec77309/docs/how-to/unit-testing.md
[coyote-tutorial]: https://github.com/microsoft/coyote/blob/0c51dc58cc34cdefa24dcfabf3439e5e0ec77309/docs/tutorials/first-concurrency-unit-test.md
[coyote-rewrite]: https://github.com/microsoft/coyote/blob/0c51dc58cc34cdefa24dcfabf3439e5e0ec77309/docs/concepts/binary-rewriting.md
[coyote-config]: https://github.com/microsoft/coyote/blob/0c51dc58cc34cdefa24dcfabf3439e5e0ec77309/Source/Core/Configuration.cs
[coyote-runtime]: https://github.com/microsoft/coyote/blob/0c51dc58cc34cdefa24dcfabf3439e5e0ec77309/Source/Core/Runtime/CoyoteRuntime.cs#L463-L495
[lincheck-readme]: https://github.com/JetBrains/lincheck/blob/a1e02bfda2948c02605ef7ac83c433c71c67ec6c/README.md
[lincheck-strategies]: https://github.com/JetBrains/lincheck/blob/a1e02bfda2948c02605ef7ac83c433c71c67ec6c/docs/topics/lincheck-testing-strategies.md
[lincheck-options]: https://github.com/JetBrains/lincheck/blob/a1e02bfda2948c02605ef7ac83c433c71c67ec6c/docs/topics/lincheck-testing-strategies-options.md
[lincheck-start]: https://github.com/JetBrains/lincheck/blob/a1e02bfda2948c02605ef7ac83c433c71c67ec6c/docs/topics/lincheck-getting-started.md
[lincheck-ds]: https://github.com/JetBrains/lincheck/blob/a1e02bfda2948c02605ef7ac83c433c71c67ec6c/docs/topics/lincheck-how-to-test-data-structures.md
[lincheck-exec]: https://github.com/JetBrains/lincheck/blob/a1e02bfda2948c02605ef7ac83c433c71c67ec6c/docs/topics/lincheck-operation-execution-options.md
[hh-state]: https://github.com/hedgehogqa/haskell-hedgehog/blob/7845181d887d2f082ea537b6992d37f243314c46/hedgehog/src/Hedgehog/Internal/State.hs
[hh-report]: https://github.com/hedgehogqa/haskell-hedgehog/blob/7845181d887d2f082ea537b6992d37f243314c46/hedgehog/src/Hedgehog/Internal/Report.hs#L658-L668
[hh-example]: https://github.com/hedgehogqa/haskell-hedgehog/blob/7845181d887d2f082ea537b6992d37f243314c46/hedgehog-example/src/Test/Example/References.hs
[proptest-sm]: https://github.com/proptest-rs/proptest/blob/70cf37d46b7d83393b6ed94c611f8c52209f585d/book/src/proptest/state-machine.md
[proptest-regress]: https://github.com/proptest-rs/proptest/blob/70cf37d46b7d83393b6ed94c611f8c52209f585d/proptest-state-machine/proptest-regressions/strategy.txt
[local-task-testing]: ../../../libs/build-primitives/src/sparkles/build_primitives/task/testing.d
[local-executor]: ../../../libs/build-primitives/src/sparkles/build_primitives/task/executor.d
[local-reporter]: ../../../libs/build-primitives/src/sparkles/build_primitives/task/reporter_plain.d
[local-eh-testing]: ../../../libs/event-horizon/src/sparkles/event_horizon/testing.d
[local-clock]: ../../../libs/event-horizon/src/sparkles/event_horizon/clock.d
[local-model]: ../../../libs/base/src/sparkles/base/sync/model.d
[local-sync-spec]: ../../specs/base/sync/testing.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
