# Deterministic simulation testing

Deterministic simulation testing (DST) is the discipline of running the real program, unmodified, inside a single-threaded discrete-event simulator that owns every source of nondeterminism (scheduler, clock, random numbers, network, disk, process death) so that a random fault schedule drawn from one seed can be replayed byte-for-byte; it is the mature answer to "test a durable program by crashing it at every point", and the three systems below are its canonical practitioners.

| Field             | Value                                                                                                                                                                                                                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Principal sources | FoundationDB's simulator (`Sim2` + Flow + `BUGGIFY`) and the SIGMOD 2021 paper; TigerBeetle's VOPR; Antithesis's deterministic hypervisor                                                                                                                                              |
| Authors           | Zhou, Miller, Sears, Xu, Tschannen, Leach, Shraer, Atherton, Rosenthal, Namasivayam, Beamon, Dong, Wilson, Grieser, Muppana, Collins, Liu, Su, Scherer, Moore, Yadav (paper); Apple / FoundationDB contributors (simulator); TigerBeetle, Inc. (VOPR); Antithesis (docs, blog)         |
| Venue / year      | SIGMOD 2021 (paper); `apple/foundationdb` at `10a002f6bc47996fb378da0fb2d93df5e0187e32` (September 9, 2026); `tigerbeetle/tigerbeetle` at `47aeb2212a255273dda508288412e537d11e4b7c` (August 31, 2026); Antithesis docs read September 11, 2026 and the March 20, 2024 hypervisor post |
| DOI or URL        | [10.1145/3448016.3457559][doi] · [author PDF][fdb-pdf] · [FoundationDB testing docs][fdb-testing] · [TigerBeetle safety docs][tb-vopr] · [How Antithesis works][anti-how] · [Will Wilson, "Testing Distributed Systems w/ Deterministic Simulation"][wilson-talk]                      |
| Category          | theory                                                                                                                                                                                                                                                                                 |
| Grounds           | 3 (determinism: what a runtime must own for a run to be replayable) and 8 (testing: the fault model, the oracles, seed reproduction, time compression). Touches 6 (concurrency: the scheduler as the only interleaving source). Silent on 1, 2, 4, 5, 7.                               |

**Last reviewed:** September 12, 2026.

## What it establishes

DST establishes that a program whose every nondeterministic input flows through one seam can be tested against a fault model far harsher than production, with every failure reproducible from a seed. The FoundationDB paper states the thesis in one sentence: "the real database software is run, together with randomized synthetic workloads and fault injection, in a deterministic discrete-event simulation. The harsh simulated environment quickly provokes bugs (including but not limited to distributed systems bugs) in the database, and determinism guarantees that every bug found this way can be reproduced, diagnosed, and fixed" ([paper][fdb-pdf], §4). The prerequisite is architectural, not a test-harness detail: "All database code is deterministic; accordingly multithreaded concurrency is avoided (instead, one database node is deployed per core)" (§4, "Deterministic simulator"). TigerBeetle says the same in its docs: "In the simulator, all non-deterministic parts of the system are stubbed out. This includes the clock, network, and disk operations" ([`docs/internals/vopr.md`][tb-vopr-md]).

The definitions that recur across the three systems:

- **Seed.** One integer from which every random choice in a run derives: the cluster shape, the workload, the fault schedule, the scheduling jitter. Replaying the seed on the same binary replays the run.
- **Fault schedule.** The sequence of injected faults (kills, reboots, partitions, clogs, disk corruption, delays) as a function of the seed. It is drawn, not enumerated.
- **Oracle.** What decides a run failed: in-code assertions, a workload's `check` phase, a cluster-wide state checker, a liveness deadline.
- **Time compression.** Virtual time jumps to the next scheduled event when nothing is runnable, so an hour of simulated time costs seconds of CPU. "Discrete-event simulation can run arbitrarily faster than real-time if CPU utilization within the simulation is low, as the simulator can fast-forward clock to the next event" ([paper][fdb-pdf], §4, "Latency to bug discovery").
- **Crash at any point.** A process may be killed between any two scheduled tasks; what its writes look like after the kill is itself a fault-model decision (FoundationDB's `AsyncFileNonDurable`, TigerBeetle's `crash_fault_probability`).

## FoundationDB: `Sim2`, Flow and `BUGGIFY`

A note on the clone: at the pinned commit FoundationDB has finished migrating from its actor compiler to standard C++ coroutines, so the files the literature calls `sim2.actor.cpp` and `SimulatedCluster.actor.cpp` are [`fdbrpc/sim2.cpp`][fdb-sim2] and [`fdbserver/SimulatedCluster.cpp`][fdb-simcluster]. [`flow/README.md`][fdb-flow-readme] now opens with "Flow provides asynchronous communication and cooperative scheduling using standard C++ coroutines. … Coroutine code lives in ordinary `.cpp` and `.h` files." The 2021 paper describes the earlier state ("Flow [4], a novel syntactic extension to C++ adding async/await-like concurrency primitives"); the simulator's design is unchanged by the migration.

### How determinism is obtained

Everything runs on one OS thread inside one process, interleaved only by the simulator's task queue. `Sim2::runLoop` is the whole scheduler ([`fdbrpc/sim2.cpp`][fdb-sim2], `runLoop`): while not stopped, if the queue can sleep it advances `self->time` to the next timer (plus a tiny random jitter), then drains every ready task in priority order. Ready tasks live in a `std::priority_queue` keyed by priority, timers in one keyed by `at` ([`flow/include/flow/TaskQueue.h`][fdb-taskqueue], `OrderedTask`, `DelayedTask`); with a single thread and a single insertion order the pop order is a pure function of the run so far.

Randomness is a single seeded generator. [`flow/include/flow/DeterministicRandom.h`][fdb-detrandom] wraps `boost::random::mt19937_64` with the comment "Use boost::random::mt19937_64 to get consistent output across different compilers and therefore across different C++ standard library implementations", and [`flow/include/flow/IRandom.h`][fdb-irandom] warns at the accessor: "This generator is only deterministic if given a seed using setThreadLocalDeterministicRandomSeed". The seed comes from `-s` on the `fdbserver` command line ([`fdbserver/fdbserver.cpp`][fdb-server], `OPT_RANDOMSEED`) and is otherwise drawn from `platform::getRandomSeed()` and printed ("Random seed is …").

The clock is a plain field. `Sim2::now()` returns `time`; `timer()` may run "up to 0.1 seconds ahead of now()" by a random increment, so code that confuses the two clocks is punished ([`fdbrpc/sim2.cpp`][fdb-sim2], class `Sim2`). `delay(seconds, …)` enqueues a timer at `now() + seconds`, and with probability 0.25 first stretches `seconds` by `MAX_BUGGIFIED_DELAY * pow(random01(), 1000.0)`, a heavy-tailed jitter that occasionally makes a short sleep very long.

The network is `Sim2Conn` plus `SimClogging`: per-connection delivery delays, `clogPairFor(from, to, t)` to hold a link, `buggify()` calls in `Sim2Conn::write` that truncate a send to a random slice of at most 1000 bytes, and `rollRandomClose`, which with probability `0.00001` per call fails the connection outright, all skipped when the connection is marked stable. The disk is `AsyncFileNonDurable`, "an async file implementation which wraps another async file and will randomly destroy sectors that it is writing when killed. This is used to simulate a power failure which prevents all written data from being persisted to disk" ([`fdbrpc/include/fdbrpc/AsyncFileNonDurable.h`][fdb-nondurable]). Even `deleteFile` is half-durable: with probability 0.5 a non-`mustBeDurable` delete is logged as `Sim2DeleteFileImplNonDurable` and never happens.

### The fault model

Kills are typed. [`fdbrpc/include/fdbrpc/SimulatorKillType.h`][fdb-killtype] enumerates `KillInstantly`, `InjectFaults`, `FailDisk`, `RebootAndDelete`, `RebootProcessAndDelete`, `RebootProcessAndSwitch`, `Reboot`, `RebootProcess`, `None`. `Sim2::killProcess_internal` marks the process `failed`, or arms per-process fault injection (`fault_injection_p1 = 0.1`, `fault_injection_p2 = random01()`), or sets `failedDisk`; each branch is wrapped in a `CODE_PROBE` so the harness can count how many runs reached it ([`fdbrpc/sim2.cpp`][fdb-sim2]). The workload that drives kills is `MachineAttrition` ([`fdbserver/workloads/MachineAttrition.cpp`][fdb-attrition]), with knobs `reboot`, `killDc`, `killMachine`, `killDatahall`, `killProcess`, `killZone`, `killSelf`, `killAll`.

`BUGGIFY` is the in-code half of the fault model. [`flow/include/flow/Buggify.h`][fdb-buggify] defines `buggify(probability)` as: enabled globally, **and** this `(file, line)` section was activated for this run (a per-section coin with `P_GENERAL_BUGGIFIED_SECTION_ACTIVATED = 0.25`, memoized in a map and traced), **and** a fresh `random01() < probability` (default `P_GENERAL_BUGGIFIED_SECTION_FIRES = 0.25`). The paper explains the intent: "At many places in its code-base, the simulation is given the opportunity to inject some unusual (but not contract-breaking) behavior such as unnecessarily returning an error from an operation that usually succeeds, injecting a delay in an operation that is usually fast, choosing an unusual value for a tuning parameter, etc." ([paper][fdb-pdf], §4, "Fault injection"). The two-level coin is swarm testing: each run enables "a different random subset of buggification points", so that runs differ in _which_ rare paths are hot, not only in when.

A test is a TOML file composing workloads. [`tests/fast/CycleTest.toml`][fdb-cycletoml] stacks `Cycle` (2500 transactions/s for 10 s) with `RandomClogging`, `Rollback` and two `Attrition` workloads (`machinesToKill = 10`, `machinesToLeave = 3`, `reboot = true`), then a second, unclogged phase. Restart tests are pairs: [`ConfigureTestRestart-1.toml`][fdb-restart1] ends with a `SaveAndKill` workload writing `simfdb/restartInfo.ini`, and [`ConfigureTestRestart-2.toml`][fdb-restart2] resumes the same cluster from disk with `runSetup=false`, which is how an upgrade across binaries is simulated: crash, then come back with different code.

### What is checked

The paper lists the oracles: workloads "have assertions built in to verify the contracts and properties of the database (for example, by checking invariants in their data that can only be maintained through transaction atomicity and isolation)"; code-level assertions check what is "verified 'locally'"; and recoverability "can be checked by returning the modeled hardware environment … to a state in which recovery should be possible and verifying that the cluster eventually recovers" ([paper][fdb-pdf], §4, "Test oracles"). Concretely, every workload has a `check` phase: `CycleWorkload::check` reads the whole ring in one transaction and `cycleCheckData` emits a `SevError` `TestFailure` trace if the ring is broken ([`fdbserver/workloads/Cycle.cpp`][fdb-cycle]). The run's exit code is derived from the count of `SevError` events logged ([`fdbserver/fdbserver.cpp`][fdb-server], `CountEventsLoggedAt(SevError)`).

### Reproduction

A failing run is `-s <seed> -b on` plus the test file. Two runs of the same seed must also agree on the **unseed**: at the end of a simulation `fdbserver` draws one more random number and prints "Unseed: N" ([`fdbserver/fdbserver.cpp`][fdb-server]). If a change introduces nondeterminism anywhere, the unseed diverges between runs of the same seed and the harness flags it before any bug is hunted. The paper's §6.2 records why this matters: "Adding additional logging, for instance, generally does not affect the deterministic ordering of events, so an exact reproduction is guaranteed."

### Time compression and scale

The docs report "about a 10-1 factor of real-to-simulated time" and "roughly one trillion CPU-hours of simulation" ([FoundationDB testing docs][fdb-testing]). The same page names the fault pattern that found the most bugs, swizzle-clogging: "you first pick a random subset of nodes in the cluster. Then, you 'clog' (stop) each of their network connections one by one over a few seconds. Finally, you unclog them in a random order, again one by one, until they are all up."

## TigerBeetle: the VOPR

TigerBeetle's simulator, the Viewstamped Operation Replicator, is [`src/vopr.zig`][tb-vopr-zig] over the test cluster in [`src/testing/cluster.zig`][tb-cluster]. Its docs make the reproducibility contract explicit: "Because our simulator is deterministic based on a _seed_ number and the Git commit, we can perfectly reproduce any bugs discovered in testing for easy local debugging. Crucially, VOPR can speed up time arbitrarily. One minute of VOPR time is equivalent to days of real-world testing" ([`docs/internals/vopr.md`][tb-vopr-md]).

### How determinism is obtained

There is no scheduler to seed because there are no tasks: the whole cluster is ticked. `Simulator.tick` calls `cluster.tick()`, then `tick_requests`, `tick_upgrade`, `tick_crash`, `tick_pause` in fixed order ([`src/vopr.zig`][tb-vopr-zig]); `Cluster.tick` interleaves storage and network steps "to allow for faster-than-a-tick IO" ([`src/testing/cluster.zig`][tb-cluster]). Every replica's I/O is an in-memory double that completes on a later tick. The clock is [`src/testing/time.zig`][tb-time], whose `TimeSim` has a `resolution` per tick and an `OffsetType` of `linear`, `periodic`, `step` or `non_ideal`, so replicas drift relative to each other by a seeded formula. The network is [`src/testing/packet_simulator.zig`][tb-packetsim] with `one_way_delay_mean`, `packet_loss_probability`, `packet_replay_probability`, `partition_mode` and `partition_symmetry`. The disk is [`src/testing/storage.zig`][tb-storage], "In-memory storage, with simulated faults and latency", with `read_fault_probability`, `write_fault_probability`, `write_misdirect_probability` and `crash_fault_probability`.

The seed is parsed from `--seed` or drawn from `std.crypto.random`; `stdx.PRNG.from_seed(seed)` ([`src/stdx/prng.zig`][tb-prng]) then generates every option: `options_swarm` draws cluster shape, `packet_loss_probability = ratio(prng.int_inclusive(u8, 30), 100)`, partition probabilities and stabilities, storage latencies and fault ratios, and separate sub-seeds for the cluster, network and storage doubles ([`src/vopr.zig`][tb-vopr-zig], `options_swarm`). When no seed is given the binary refuses `Debug` builds ("no seed provided: the simulator must be run with -OReleaseSafe"), because unseeded runs are for throughput, seeded ones for debugging.

### The fault model

A crash is one tick's coin toss. `tick_crash_up` takes `replica_crash_probability` (`ratio(2, 10_000_000)` per tick in swarm mode), multiplies it by ten if the replica has writes in flight, and on success calls `cluster.replica_crash` ([`src/vopr.zig`][tb-vopr-zig]). That function is short and is the whole "what does a crash mean" model ([`src/testing/cluster.zig`][tb-cluster], `replica_crash`):

```zig
// Reset the storage before the replica so that pending writes can (partially) finish.
cluster.storages[replica_index].reset();

cluster.replicas[replica_index].deinit(cluster.allocator);
cluster.network.process_disable(.{ .replica = replica_index });
cluster.replica_health[replica_index] = .down;
```

`Storage.reset` walks the pending writes and, with `crash_fault_probability` (drawn from 80 to 100 percent in swarm mode), corrupts one random sector each write targeted ([`src/testing/storage.zig`][tb-storage], `reset`). The storage doc comment bounds this per zone so the cluster can always repair: "One read/write fault is permitted per area … An additional fault is permitted at the target of a pending write during a crash." Restarts follow a `replica_restart_probability`; there are also pause/unpause, reformat and release-upgrade faults, all ticked from the same seed.

### What is checked

Three layers. First, the thousands of assertions in production code, which stay on in release builds ([`docs/internals/vopr.md`][tb-vopr-md]: "it is far better to stop operating than to continue operating in an incorrect state"). Second, the cluster-wide `StateChecker` ([`src/testing/cluster/state_checker.zig`][tb-statechecker]): on every commit it records the prepare header and its checksum in a global `commits` list, and `check_state` demands that a replica's `commit_min` moves by exactly one, that the new header's `parent` is the previous checksum, and that any state not yet in the history is justified by a live client's in-flight request, otherwise `error.ReplicaTransitionedToInvalidState`. Its comment states the invariant: "the cluster as a whole may not transition to the same state more than once, and once transitioned may not regress." Storage, journal, grid and manifest checkers sit beside it under `src/testing/cluster/`. Third, liveness: after the safety phase the simulator picks a random `core` of replicas, calls `transition_to_liveness_mode` (restart the core's crashed replicas, heal partitions among them, disable their storage faults, zero every crash and restart probability), and then requires convergence within `ticks_max_convergence`; if `pending()` still names a reason and `cluster_recoverable` says the core should have been able to recover, the run fails with "no state convergence" and "you can reproduce this failure with seed=…" ([`src/vopr.zig`][tb-vopr-zig]).

### Reproduction and the style rule

The output format itself is designed for replay reading: [`docs/internals/testing.md`][tb-testing-md] documents the per-replica event column (`!` crash, `^` recover, ` ` commit, `$` sync, `[`/`]` checkpoint). The house style makes the division of labour explicit ([`docs/TIGER_STYLE.md`][tb-style]): "a fuzzer can prove only the presence of bugs, not their absence. Therefore: Build a precise mental model of the code first, encode your understanding in the form of assertions, … and use VOPR as the final line of defense, to find bugs in your and reviewer's understanding of code." The same file ties determinism to memory hygiene: a buffer bleed "may cause deterministic guarantees as required by TigerBeetle to be violated."

Beyond random search, two sibling harnesses matter here. [`src/vsr/replica_test.zig`][tb-replicatest] scripts "specific cases that are hard or slow to replicate through random simulation" on the same cluster double. [`src/testing/exhaustigen.zig`][tb-exhaustigen] is "An utility for exhaustive generation of arbitrary data": a loop that re-runs a body while a generator `g` enumerates every choice the body asked for through `g.index(pool)`, so a test that asks "crash here or not?" at each site enumerates all crash placements instead of sampling them.

## Antithesis

Antithesis moves the determinism boundary from the program to the machine. Its docs: "The Antithesis environment is fully deterministic. This makes every bug we find perfectly reproducible", and the exploration model is a tree: "Each event potentially starts a new timeline. In one universe, the network partitioned at time=t, and in many others, it didn't" ([How Antithesis works][anti-how]). The mechanism is a hypervisor, described in its March 20, 2024 engineering post ([Antithesis blog][anti-hv]): "Everything in the hypervisor's guest environment sees a single linear history"; "Every attempt to access a time source from inside the guest – reading TSC, reading HPET, etc. – returns a virtual time value computed by the hypervisor"; "Each instance of the deterministic hypervisor runs on just one physical CPU core"; and "The points in execution history where the guest ingests input from the Antithesis platform become possible branch points for future execution", so "The external view of the exploration of a system is an input tree."

The fault catalogue is the same as FoundationDB's and TigerBeetle's, applied to unmodified containers ([Controlling faults][anti-faults]): network latency, partitions, clogs; node pause, node kill/stop, throttling; forward and backward clock skips; thread pausing (with instrumentation); CPU modulation. "By default, faults are injected throughout the test timeline, interleaved randomly with your workload." What this buys over an in-process simulator is that third-party code, the kernel and the filesystem are inside the deterministic box, exactly the limitation the FoundationDB paper concedes ("It is also unable to test third-party libraries or dependencies, or even first-party code not implemented in Flow", [paper][fdb-pdf], §4, "Limitations"). What it costs is that the program cannot be made faster than the guest CPU: time compression comes from fast-forwarding an idle guest, not from skipping a scheduler queue.

## Relevance to durable execution

### 3. Determinism enforcement

All three systems enforce determinism by **the runtime**, and all three discovered that the runtime can only enforce what it owns. FoundationDB owns the scheduler, the RNG, both clocks, the network and the disk, and pays for it by forbidding threads and third-party I/O libraries; TigerBeetle owns them by having no scheduler at all (a tick loop) and a `Storage`/`Network`/`TimeSim` triple that the production code never bypasses; Antithesis owns them by virtualizing the CPU. None enforces determinism **by discipline** alone, and FoundationDB adds a mechanical detector for discipline failures: the unseed check, which turns "someone read the wall clock" into a diff between two runs of one seed. For durable execution this is the sharpest lesson in the catalog: replay-based engines (see [`./burckhardt-durable-functions-semantics.md`][burckhardt], whose bisimulation theorem assumes deterministic replay as a lemma) need exactly the property DST tests for, and DST is the only technique here that checks it rather than assuming it. A workflow that is deterministic between journaled steps is, by construction, one that can run under a `Sim2`-style executor; if it cannot, replay will eventually diverge in production too.

### 6. Concurrency under replay

DST's answer is that the scheduler is the single source of interleavings, so concurrency is replayable iff the ready queue's pop order is a function of the seed. FoundationDB's `TaskQueue` orders by priority and arrival; TigerBeetle has no tasks, only ticks. A durable engine that lets concurrent steps race for the journal has to make the same choice: either serialize completion order through one seeded queue in tests, or accept that a journal can only replay the interleaving it recorded.

### 8. Testing

The three answers to "how is a durable program tested" share a shape that the catalog's other subjects lack:

- **Faults are drawn from a seed, not listed.** A crash is a per-tick coin (`replica_crash_probability`), a kill is a workload parameter (`machinesToKill`), a rare branch is `buggify()`; the tester writes distributions and the harness explores. Both FoundationDB and TigerBeetle tune those distributions on purpose ("carefully tuned to avoid driving the system into a small state-space caused by an excessive fault rate", [paper][fdb-pdf], §4).
- **A crash has a disk model.** Neither system treats "kill" as "the last write is either fully there or fully absent": `AsyncFileNonDurable` shreds sectors of in-flight writes, `Storage.reset` corrupts one sector per pending write. An append-only journal under DST would see torn tail records, not just missing ones.
- **Oracles are layered.** Local assertions, workload `check`, a global state checker, and a liveness phase that heals the fault-free core and demands convergence. TigerBeetle's liveness mode is the direct analogue of "resume after the crash and require completion".
- **The seed is the bug report.** "you can reproduce this failure with seed=…"; `-s <seed> -b on`; the Antithesis input tree. Every failing run is a two-integer artifact (seed, commit).
- **Coverage of the fault space is measured**, via `CODE_PROBE` counts per run, so a fault that never fires is visible as a number.

## Relevance to sparkles

- **Confirms the row-of-capabilities design as the DST seam.** `sparkles:event-horizon` already has the three doubles DST needs: `TestClock` (virtual `now`, `sleep` parks a fiber on a deadline, `advance` wakes sleepers in deadline order, `advanceToNext` jumps to the next deadline), `SimNet` (in-memory pipes, `partition(a, b, severed)` as "the fault-injection knob") and `SimProc` (scripted `argv[0]` → stdout bytes + exit status, `ENOENT` when unscripted), all parked through the `isWaker` seam of `TestSched` (`libs/event-horizon/src/sparkles/event_horizon/clock.d`, `net.d`, `proc.d`, `testing.d`; spec §10.3 in `../../../specs/event-horizon/SPEC.md`). `advanceAndSettle` is `Sim2::runLoop` in miniature: settle, advance virtual time to the next deadline, repeat. That is exactly FoundationDB's time compression and TigerBeetle's "speed up time arbitrarily", and the workflow rewrite gets it for free by running under the row.
- **The planned tests are the right two oracles, but they sample the wrong distribution.** "Crash at every event index then resume" enumerates crash points **between** journal events; "mutate the world between crash and resume" is a hand-written fault list. DST says the interesting crash points are **inside** an op: after `started` is appended but before the side effect, after the effect but before `completed`, during the append itself (a torn `journal.jsonl` line, per `AsyncFileNonDurable`), and during the compensation. Enumerating between-event indices proves the resume rule table; it does not exercise the durability of the append or the idempotency of the op.
- **`TestSched` is FIFO and unseeded, which is a gap.** `enqueue`/`dequeue` in `testing.d` are a plain linked-list queue; there is no seed anywhere in `TestSched`, `TestClock`, `SimNet` or `SimProc`. FoundationDB's task queue is deterministic _and_ jittered by the seed (`MAX_RUNLOOP_SLEEP_DELAY`, buggified `delay`); TigerBeetle's latencies and drift are drawn per seed. The cheapest DST addition to event-horizon is a `seed` on `TestSched` that shuffles same-priority ready tasks and lets `SimNet`/`SimProc` draw latencies and failures from it, plus a `buggify(p)`-style probe in the journaling combinator so the seed decides where the crash lands.
- **`SimProc` has no failure vocabulary.** It scripts a fixed stdout and exit status per command. DST's process double needs the `KillType` spectrum for the child (hung, killed by signal, partial stdout, exit after a delay) and for the parent (the `release` process dying while the child runs, which is where `supervise` §13.5 and compensations meet). Scripts should be drawn, not fixed: "with probability p this `git push` returns after the tag exists on the remote but reports failure."
- **Add the unseed check.** Run the workflow twice under one seed and compare the journal bytes; any divergence is a nondeterminism leak (a wall-clock read, a map iteration order, an unjournaled observation) surfaced _before_ it becomes a replay mismatch in production. This is the one DST idea that directly tests question 3 rather than assuming it, and it costs one extra run per seed.
- **Use exhaustive generation for the small crash spaces and seeds for the large ones.** TigerBeetle keeps both: `exhaustigen` enumerates every choice a short test makes, the VOPR samples the long runs. The crash-at-every-index test should be the exhaustive form over one op's internal crash sites (started/effect/completed/compensation, times torn/clean), and a seeded VOPR-style loop should sample crash schedules across a whole `--split` run.
- **Argues against trusting the state-machine alone.** TigerBeetle's `StateChecker` is not the replicas' own consistency check; it is a global history that every replica is checked against, and the liveness phase is a second, separate oracle. The `release` analogue is an external model of the world (tags that should exist, releases that should be published, notes that should be attached) that the journal projection is compared to after every crash-and-resume, plus a "heal everything and require completion" phase at the end of every seeded run.

## Sources

- FoundationDB source at `$REPOS/foundationdb`, commit `10a002f6bc47996fb378da0fb2d93df5e0187e32`: [`fdbrpc/sim2.cpp`][fdb-sim2], [`fdbrpc/include/fdbrpc/simulator.h`][fdb-simulator-h], [`fdbrpc/include/fdbrpc/SimulatorKillType.h`][fdb-killtype], [`fdbrpc/include/fdbrpc/AsyncFileNonDurable.h`][fdb-nondurable], [`fdbserver/SimulatedCluster.cpp`][fdb-simcluster], [`fdbserver/fdbserver.cpp`][fdb-server], [`fdbserver/workloads/Cycle.cpp`][fdb-cycle], [`fdbserver/workloads/MachineAttrition.cpp`][fdb-attrition], [`flow/include/flow/Buggify.h`][fdb-buggify], [`flow/include/flow/DeterministicRandom.h`][fdb-detrandom], [`flow/include/flow/IRandom.h`][fdb-irandom], [`flow/include/flow/TaskQueue.h`][fdb-taskqueue], [`flow/README.md`][fdb-flow-readme], [`design/coroutines.md`][fdb-coroutines], [`documentation/sphinx/source/testing.rst`][fdb-testing-rst], [`tests/fast/CycleTest.toml`][fdb-cycletoml], [`tests/restarting/from_7.2.0_until_7.3.0/ConfigureTestRestart-1.toml`][fdb-restart1] and [`-2.toml`][fdb-restart2].
- Jingyu Zhou et al., "FoundationDB: A Distributed Unbundled Transactional Key Value Store", SIGMOD 2021: [DOI][doi], [author PDF][fdb-pdf]. Quoted from §4 "Simulation Testing" and §6.2.
- [FoundationDB "Simulation and Testing" documentation][fdb-testing].
- Will Wilson, ["Testing Distributed Systems w/ Deterministic Simulation"][wilson-talk] (video).
- TigerBeetle source at `$REPOS/tigerbeetle`, commit `47aeb2212a255273dda508288412e537d11e4b7c`: [`src/vopr.zig`][tb-vopr-zig], [`src/testing/cluster.zig`][tb-cluster], [`src/testing/cluster/state_checker.zig`][tb-statechecker], [`src/testing/storage.zig`][tb-storage], [`src/testing/packet_simulator.zig`][tb-packetsim], [`src/testing/time.zig`][tb-time], [`src/testing/exhaustigen.zig`][tb-exhaustigen], [`src/stdx/prng.zig`][tb-prng], [`src/vsr/replica_test.zig`][tb-replicatest], [`docs/internals/vopr.md`][tb-vopr-md], [`docs/internals/testing.md`][tb-testing-md], [`docs/TIGER_STYLE.md`][tb-style].
- Antithesis: [How Antithesis works][anti-how], [Controlling faults][anti-faults], ["So you think you want to write a deterministic hypervisor?"][anti-hv] (March 20, 2024).
- `sparkles:event-horizon` in this repository: `libs/event-horizon/src/sparkles/event_horizon/testing.d`, `clock.d`, `net.d`, `proc.d`; [SPEC §10.3][eh-spec].
- Catalog neighbours: [Durable Functions semantics][burckhardt], the [catalog umbrella][catalog], the [algebraic-effects topic][topic].

<!-- References -->

[doi]: https://doi.org/10.1145/3448016.3457559
[fdb-pdf]: https://www.foundationdb.org/files/fdb-paper.pdf
[fdb-testing]: https://apple.github.io/foundationdb/testing.html
[wilson-talk]: https://www.youtube.com/watch?v=4fFDFbi3toc
[fdb-sim2]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbrpc/sim2.cpp
[fdb-simulator-h]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbrpc/include/fdbrpc/simulator.h
[fdb-killtype]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbrpc/include/fdbrpc/SimulatorKillType.h
[fdb-nondurable]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbrpc/include/fdbrpc/AsyncFileNonDurable.h
[fdb-simcluster]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbserver/SimulatedCluster.cpp
[fdb-server]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbserver/fdbserver.cpp
[fdb-cycle]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbserver/workloads/Cycle.cpp
[fdb-attrition]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/fdbserver/workloads/MachineAttrition.cpp
[fdb-buggify]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/flow/include/flow/Buggify.h
[fdb-detrandom]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/flow/include/flow/DeterministicRandom.h
[fdb-irandom]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/flow/include/flow/IRandom.h
[fdb-taskqueue]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/flow/include/flow/TaskQueue.h
[fdb-flow-readme]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/flow/README.md
[fdb-coroutines]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/design/coroutines.md
[fdb-testing-rst]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/documentation/sphinx/source/testing.rst
[fdb-cycletoml]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/tests/fast/CycleTest.toml
[fdb-restart1]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/tests/restarting/from_7.2.0_until_7.3.0/ConfigureTestRestart-1.toml
[fdb-restart2]: https://github.com/apple/foundationdb/blob/10a002f6bc47996fb378da0fb2d93df5e0187e32/tests/restarting/from_7.2.0_until_7.3.0/ConfigureTestRestart-2.toml
[tb-vopr]: https://docs.tigerbeetle.com/concepts/safety/
[tb-vopr-zig]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/vopr.zig
[tb-cluster]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/testing/cluster.zig
[tb-statechecker]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/testing/cluster/state_checker.zig
[tb-storage]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/testing/storage.zig
[tb-packetsim]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/testing/packet_simulator.zig
[tb-time]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/testing/time.zig
[tb-exhaustigen]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/testing/exhaustigen.zig
[tb-prng]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/stdx/prng.zig
[tb-replicatest]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/vsr/replica_test.zig
[tb-vopr-md]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/docs/internals/vopr.md
[tb-testing-md]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/docs/internals/testing.md
[tb-style]: https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/docs/TIGER_STYLE.md
[anti-how]: https://antithesis.com/docs/introduction/how_antithesis_works/
[anti-faults]: https://antithesis.com/docs/product/writing_tests/controlling_faults/
[anti-hv]: https://antithesis.com/blog/deterministic_hypervisor/
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[burckhardt]: ./burckhardt-durable-functions-semantics.md
[catalog]: ./index.md
[topic]: ../index.md
