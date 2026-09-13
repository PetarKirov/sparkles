# Deterministic record and replay

Deterministic record and replay is the forty-year-old discipline of drawing a boundary around a computation, logging every nondeterministic input that crosses it, and re-executing the computation with the log standing in for the world; durable execution is this discipline applied at the granularity of one workflow step instead of one system call, and its boundaries (what to log, how to know replay has diverged, what concurrency costs) were mapped by the systems below long before any workflow engine existed.

| Field             | Value                                                                                                                                                                                                                                                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Principal sources | `rr` (Mozilla, now `rr-debugger/rr`) and its USENIX ATC 2017 paper; Instant Replay (1987); RecPlay (1999); Chen et al.'s ACM Computing Surveys taxonomy (2015); Go's `testing/synctest` and Tokio's `time::pause` as the clock-substitution idiom                                                                                                              |
| Authors           | O'Callahan, Jones, Froyd, Huey, Noll, Partush (rr); LeBlanc, Mellor-Crummey (Instant Replay); Ronsse, De Bosschere (RecPlay); Chen, Zhang, Guo, Li, Wu, Chen (survey)                                                                                                                                                                                          |
| Venue / year      | USENIX ATC 2017 / arXiv 1705.05937 (rr); IEEE Transactions on Computers 1987; ACM TOCS 1999; ACM Computing Surveys 2015; `rr-debugger/rr` at `5c202cd8cb678b32107fa6aaf1c6108420bc53a8` (August 17, 2026)                                                                                                                                                      |
| DOI or URL        | [rr paper (arXiv)][rr-arxiv] · [rr paper (USENIX)][rr-usenix] · [Instant Replay][instant-replay] · [RecPlay][recplay] · [Deterministic Replay: A Survey][chen-survey] · [`testing/synctest`][go-synctest] · [`tokio::time::pause`][tokio-pause]                                                                                                                |
| Category          | theory                                                                                                                                                                                                                                                                                                                                                         |
| Grounds           | 1 (what gets a record and how it is matched), 3 (determinism between records: what the runtime must own and how divergence is caught), 6 (order-driven replay of concurrency), 7 (replay versus checkpoint, and rr's hybrid). Touches 2 (the recorded trace as the divergence oracle) and 8 (clock substitution as the testing discipline). Silent on 4 and 5. |

**Last reviewed:** September 12, 2026.

## What it establishes

The body of work establishes one theorem and one taxonomy. The theorem is stated in the rr paper's design summary: "We identify a boundary around state and computation, record all sources of nondeterminism within the boundary and all inputs crossing into the boundary, and reexecute the computation within the boundary by replaying the nondeterminism and inputs. If all inputs and nondeterminism have truly been captured, the state and computation within the boundary during replay will match that during recording" ([rr paper][rr-arxiv], §2.1). The whole engineering problem is the conditional clause: enumerating the inputs, making the capture cheap, and detecting when the enumeration was incomplete.

The taxonomy is Instant Replay's, from 1987: "During program execution we save the relative order of significant events as they occur, not the data associated with such events. As a result, our approach requires less time and space to save the information needed for program replay than other methods" ([Instant Replay][instant-replay], abstract). A **data-driven** log records the values that crossed the boundary (rr's system-call results); an **order-driven** log records only the sequence in which internally deterministic parties interacted, and trusts re-execution to regenerate the values. The two are not rivals: rr is data-driven at the kernel boundary and order-driven for its threads.

The definitions that recur:

- **Boundary.** The interface at which inputs are logged. rr's is "the interface between user-space and the kernel" (§2.1); Instant Replay's is the shared object; a workflow engine's is the activity call.
- **Progress measure.** A quantity that identifies _where_ in the deterministic computation an asynchronous input arrived, so replay can deliver it at the same point. rr uses a hardware counter; a workflow engine uses the step's position in its own history.
- **Divergence.** Replay reaching a state the recording did not. Every mature system treats detection as a first-class mechanism, not an afterthought.
- **Checkpoint.** A copy of replayed state taken so a later replay need not start from the beginning. Distinct from the log, and derived from it.

## rr: user-space record and replay on stock Linux

### The boundary and what crosses it

rr records "the user-space execution of a group of processes"; on replay "user-space memory and register values are preserved exactly", while "only a minimal amount of kernel state is reproduced during replay. For example, file descriptors are not opened, signal handlers are not installed, and filesystem operations are not performed. Instead the recorded user-space-visible effects of those operations, and future related operations, are replayed" ([rr paper][rr-arxiv], §2.1). The inputs are the results of system calls (return values plus every out-parameter the kernel wrote into tracee memory), the timing and content of signals, and the few nondeterministic instructions. `RDTSC` is trapped through `prctl(PR_SET_TSC, PR_TSC_SIGSEGV)` so the recorder can "record the tsc and replay it deterministically" ([`src/Task.cc`][rr-task], `disable_tsc`). Shared memory written by unrecorded parties is the one input rr cannot log, so it is configured away: rr disables shared-memory transports with PulseAudio and the X server, blocks direct GPU access, and patches vDSO fast paths, which read "memory shared with the kernel and updated asynchronously by the kernel", back into real system calls (§2.5).

The trace format shows exactly what a record is. [`src/rr_trace.capnp`][rr-capnp] defines a `Frame` carrying `tid`, `ticks`, `monotonicSec`, a `memWrites` list, the full `registers` and `extraRegisters`, and an `event` union whose arms include `syscall` (with `number`, `state`, `failedDuringPreparation` and an `extra` union for `writeOffset`, `openedFds`, socket addresses), `signal`, `signalDelivery`, `signalHandler`, `sched`, `instructionTrap`, `patchSyscall`, `syscallbufAbortCommit`, `syscallbufReset`, `growMap` and `exit`. A record is therefore an identified event plus the complete register state at which it occurred, and the memory the kernel wrote.

### One thread at a time

rr does not record true parallelism. "With threads running on multiple cores, racing read-write or write-write accesses to the same memory location by different threads would be a source of nondeterminism. Therefore we take the common approach … running only one thread at a time. RR preemptively schedules these threads, so context switch timing is nondeterminism that must be recorded" ([rr paper][rr-arxiv], §2.2). The `--num-cores` flag's help text says it plainly: "pretend to have N cores (rr will still only run on a single core)" ([`src/RecordCommand.cc`][rr-recordcmd]), and the scheduler returns one core by default "since effectively we really only have one core" ([`src/Scheduler.cc`][rr-scheduler-cc], `set_enable_chaos`). The scheduler exists only in one direction: "The scheduler only runs during recording. During replay we're just replaying the recorded scheduling decisions" ([`src/Scheduler.h`][rr-scheduler-h]). Each `sched` frame in the trace is an order record in Instant Replay's sense: which thread ran next, at what tick count.

### Cheap capture: `syscallbuf`, seccomp-bpf and desched events

A `ptrace` stop per system call costs two context switches, so the common calls are recorded in-process. The preload library "replaces libc syscall wrappers with our own implementation that saves nondeterministic outparams in a fixed-size buffer. When the buffer is full or the recorded application invokes an un-buffered syscall or receives a signal, we trap to rr and it records the state of the buffer. During replay, rr simply refills the buffer with the recorded data when it reaches the 'flush-buffer' events that were recorded" ([`src/preload/syscallbuf.c`][rr-syscallbuf], header comment). Which calls trap and which run untraced is decided by "a seccomp-bpf which examines the syscall and decides how to handle it" (same comment).

An untraced call may block, and the recorder must then schedule another thread. rr monitors `PERF_COUNT_SW_CONTEXT_SWITCHES` per thread: "The kernel raises one of these events every time it deschedules a thread from a CPU core. The interception library monitors these events for each thread and requests that the kernel send a signal to the blocked thread every time the event occurs" ([rr paper][rr-arxiv], §3.3). The event is armed only around a possibly-blocking untraced call and disarmed after it; the recorder's `advance_to_disarm_desched_syscall` steps the tracee "until the tracee syscall that disarms the desched event", stashing any signal that arrives meanwhile ([`src/RecordSession.cc`][rr-recordsession]). The desched signal is the recorder learning, from the kernel, that a step it was not watching has stalled.

### Ticks: the progress measure for asynchronous events

Signals and preemptions must land at the same instruction on replay. "We require that every execution of a given sequence of user-space instructions changes the counter value by an amount that depends only on the instruction sequence, not system state invisible to user space … Fortunately, modern Intel CPUs have exactly one deterministic performance counter: 'retired conditional branches' ('RCB'), so we use that. We cannot just count the number of RCBs during recording and deliver the signal after we have executed that number of RCBs during replay, because the RCB count does not uniquely determine the execution point to deliver the signal at. Therefore we pair the RCB count with the complete state of general-purpose registers (including the program counter) to identify an execution point" ([rr paper][rr-arxiv], §2.4.1). The code names the quantity: "we monitor a single kind of event that we use as a proxy for progress, which we call 'ticks'. Currently this is the count of retired conditional branches" ([`src/PerfCounters.h`][rr-perfcounters]). Because the interrupt skids, replay programs it `SKID_SIZE` ticks early, then single-steps and breakpoints to the exact recorded registers ([`src/ReplaySession.cc`][rr-replaysession], the `SKID_SIZE` comment; [rr paper][rr-arxiv], §2.4.3).

### Divergence detection

Replay is checked, not trusted. At every event, `ReplayTask::validate_regs` compares the live registers with the frame's recorded registers and aborts on any difference: `ASSERT(this, !comparison.mismatch_count) << "Mismatched registers, replay vs rec: "` ([`src/ReplayTask.cc`][rr-replaytask]). The `SKID_SIZE` comment describes the failure as it appears in the log: "Error: Replay diverged. Dumping register comparison." followed by "overshot target ticks=[target] by [i]" ([`src/ReplaySession.cc`][rr-replaysession]). The oracle is the trace itself: the recording carried the full register file at each event precisely so replay can be compared against it. The paper is candid that the identifier is not unique in theory (`inc [global var]; jmp label` has no conditional branch) and that when it fails "replay would probably diverge and fail" (§2.4.1). Detection, not prevention, is the guarantee.

### Checkpoints by `fork`

rr is a replay system, but reverse-execution debugging needs to rewind cheaply, so it checkpoints replayed state: "we use fork to copy address spaces and delay creating the non-main threads until the checkpoint is resumed (and most checkpoints are never resumed). fork is (mostly) copy-on-write and is very well optimized on Linux, so creating a checkpoint typically takes less than ten milliseconds" ([rr paper][rr-arxiv], the checkpointing discussion preceding "Lessons Learned"). In the code this is `ReplaySession::clone`: "Return a semantic copy of all the state managed by this, that is the entire tracee tree and the state it depends on. … This operation is also called 'checkpointing' the replay session", guarded by `can_clone` because "we can't clone in some syscalls" ([`src/ReplaySession.h`][rr-replaysession-h]); [`src/ReplayTimeline.h`][rr-timeline] manages "checkpoints along this timeline and navigating to specific events". A checkpoint is a cache over the replay, never the source of truth; the trace remains authoritative and any checkpoint can be discarded and regenerated.

### Cost

Table 1 of the paper reports recording overheads of 1.49×–1.79× and replay overheads of 0.72×–1.56× on the `cp`, `octane`, `htmltest` and `sambatest` workloads; `make`, which forks 2430 mostly short-lived processes, records at 7.85× and replays at 11.93×, and "Forcing make onto a single core imposes major slowdown" ([rr paper][rr-arxiv], §4.2). Serialization is the price of not recording data races.

## Instant Replay and RecPlay: order-driven replay

Instant Replay's premise is that in a shared-memory parallel program the values a process reads are a deterministic function of the version of the shared object it read, so it suffices to log, per object, the sequence of writers and the count of readers between writes; on replay each process waits until the object reaches the recorded version. "Our technique is not dependent on any particular form of interprocess communication. It provides for replay of an entire program, rather than individual processes in isolation. No centralized bottlenecks are introduced and there is no need for synchronized clocks or a globally consistent logical time" ([Instant Replay][instant-replay], abstract). The log is small because it contains ordinals, not payloads, and it assumes every access to shared state goes through the instrumented protocol.

RecPlay narrows the log further and adds the missing check. "This combination enables us to limit the record phase to the more efficient recording of the synchronization operations, while deferring the time-consuming data race detection to the replay phase. As the record phase is highly efficient, there is no need to switch it off, hereby eliminating the possibility of Heisenbugs because tracing can be left on all the time" ([RecPlay][recplay], abstract). The order of lock acquisitions is enough to replay a _race-free_ program; the replay phase then detects, at full cost, whether the program was in fact race-free, which is exactly the assumption Instant Replay could not verify. Two lessons carry over: log the cheapest thing that determines the rest, and put the expensive validation on the replay side, where it can run as often as needed.

## Chen et al.: the taxonomy

The 2015 survey frames the field: "Deterministic replay is a type of emerging technique dedicated to providing deterministic executions of computer programs in the presence of nondeterministic factors. … existing deterministic replay schemes can be classified into two categories, single-processor (SP) schemes and multiprocessor (MP) schemes … we summarize and compare how existing schemes address technical issues such as log size, record slowdown, replay slowdown, implementation cost, and probe effect" ([Deterministic Replay: A Survey][chen-survey], abstract). The SP/MP split is the same line rr draws with one-thread-at-a-time: single-processor schemes only need the inputs and the interrupt points; multiprocessor schemes must additionally capture memory-access interleavings, which is where hardware support or race-freedom assumptions enter. The five metrics (log size, record slowdown, replay slowdown, implementation cost, probe effect) are the evaluation axes a journal design should also be scored on.

## Substituting the clock: `synctest` and `time::pause`

Language runtimes have converged on one narrow piece of the discipline for tests: own the clock, and advance it only when nothing else can happen. Go's `testing/synctest` (added in Go 1.25) runs a function "in an isolated 'bubble'"; "Within a bubble, the time package uses a fake clock. Each bubble has its own clock. The initial time is midnight UTC 2000-01-01", and "Time in a bubble only advances when every goroutine in the bubble is durably blocked", where "A goroutine in a bubble is 'durably blocked' when it is blocked and can only be unblocked by another goroutine in the same bubble" ([`testing/synctest`][go-synctest]). Tokio's `time::pause` does the same for its scheduler: "The current value of `Instant::now()` is saved and all subsequent calls to `Instant::now()` will return the saved value"; "If time is paused and the runtime has no work to do, the clock is auto-advanced to the next pending timer"; and it "requires the `current_thread` Tokio runtime" ([`tokio::time::pause`][tokio-pause]). Both refuse multi-threaded execution for the same reason rr does, and both make quiescence, not wall time, the trigger for the next event. This is the same rule the discrete-event simulators in [deterministic simulation testing][dst] apply.

## Relevance to durable execution

### 1. Step identity and replay matching

rr identifies a record by position in a per-thread event stream plus the complete register state at that point; a system-call result is matched to the _n_-th system call the replayed thread issues, and the registers are the check that it is the same call. A workflow engine's activity result is the direct analogue of a system-call result: a value from outside the boundary, consumed by deterministic code. The lesson is that identity by position is adequate only if every event that could change position is also in the log (rr's `sched` frames are there for this reason), and that a cheap fingerprint of the caller's state at the call site is what turns "the _n_-th record" into "the record for this call".

### 2. Journal versus world

rr never re-observes the world; the trace wins absolutely, and it can, because the boundary is total. A workflow engine whose boundary leaks (a git tag another process created) has no such option; rr's answer to leaks is to close them by configuration (PulseAudio, X, vDSO) or to widen the recorded group. The transferable point is that every leak must be either logged or declared out of the boundary and reconciled by a rule, never left implicit.

### 3. Determinism enforcement

Between records, rr enforces nothing at the language level and everything at the runtime level: user-space code runs unmodified, and the ticks counter plus the register comparison at each event is the runtime's check that the code did the same thing. The paper's condition for a usable progress counter, that its value "depends only on the instruction sequence, not system state invisible to user space", is the property any divergence oracle needs. A workflow engine has no hardware counter; its only progress measure is the sequence of ops the code issues, so divergence in code that never issues a differing op is invisible to it. rr can catch that class because it checks registers at every event, including scheduling events the code did not ask for.

### 6. Concurrency under replay

rr serializes threads and logs the schedule; Instant Replay and RecPlay log the order of interactions with shared state and regenerate values by re-execution. Both are order-driven at the concurrency level: what is journaled is which party went next, not what it computed. This is what a workflow engine's history does when it records completions in arrival order and replays them in that order, and it inherits the same constraint: the parties must be deterministic given the order, so no step may read anything not in the log.

### 7. Replay or snapshot

rr is a pure replay system with `fork`-based checkpoints layered on top as a cache. The trace is the truth; a checkpoint is cheap (copy-on-write, under ten milliseconds), disposable, and only valid because replay to that point is deterministic. The hybrid shows that replay and snapshot are not a choice between two persistence models but a base and an optimization: a snapshot is always derivable from the log, and a log is never derivable from a snapshot.

### 9. Journal integrity and the single writer

**The trace is written once, by one process, and never appended to again.** Recording
and replay are separate phases with separate sessions, so the concurrency questions
this dimension usually asks do not arise: there is no second writer because there is
no writing during replay at all. That is a stronger position than any durable-execution
system can take, and it is bought by giving up the thing they exist to do.

**Integrity is checked by comparison, not by a token.** Replay re-executes the
program and compares the full register state at every recorded event; a divergence
aborts rather than being repaired. Where a durable-execution layer stamps a version on
a record so a write can be refused, `rr` verifies after the fact that the
re-derivation matched — a different and much more thorough answer to "is this record
consistent with this program".

**One thread runs at a time, and the schedule is part of the record.** _"The
scheduler only runs during recording. During replay we're just replaying the recorded
scheduling decisions."_ Ordering is therefore not an emergent property to be
reconstructed; it is data.

**Torn records are avoided by buffering, not detected.** The syscall buffer batches
records and flushes them, which bounds the loss window but means a trace from a
hard-killed recording is truncated rather than repaired.

### 10. Operator recovery and intervention

This is where `rr` is most unlike everything else in the catalog, and it is the
strongest existence proof in the survey that rewinding a replayed execution is
practical.

**Execution runs backwards, as a first-class operation.** `ReplayTimeline` _"manages a
set of ReplaySessions corresponding to different points in the same recording. It
provides an API for explicitly managing checkpoints along this timeline and navigating
to specific events"_, with an explicit `RunDirection` of `RUN_FORWARD` or
`RUN_BACKWARD` and `reverse_continue` / `reverse_singlestep` entry points
([`ReplayTimeline.h`][rr-timeline]). Backwards execution is implemented by jumping to
an earlier checkpoint and replaying forward to the target — which is exactly the
mechanism Golem's revert and Temporal's reset use, generalised to arbitrary points
and made interactive.

**Checkpoints are a cache over the record, not a substitute for it.** They are
process forks taken along the timeline to make navigation cheap; the trace remains
the authority, and a checkpoint can always be discarded and re-derived. That is the
right relationship between a snapshot and a journal, demonstrated.

**Progress is estimated so navigation can be planned.** The timeline carries a
`Progress` measure that _"should roughly correlate to the time required to replay from
the start of a session to the current point"_, which is what lets the tool decide
where to place checkpoints rather than guessing.

**The intervention is observation only.** Nothing lets an operator change a recorded
value and continue — the trace is immutable, and a modified replay would simply
diverge. Where Inngest lets a human substitute a step's input, `rr` cannot, because
its whole guarantee is that replay reproduces the recording.

### 11. Suspension and external input

**Blocking is recorded, and the record has a name for it.** A desched event marks the
point at which a buffered syscall was going to block, so replay knows the difference
between a call that returned immediately and one that waited. A durable-execution
layer that records only results loses that distinction: it knows what a step returned
and not that the step was stuck.

**There is no resumption across processes**, so suspension in the durable sense does
not apply. A replay session is a live process that can be checkpointed and forked but
not serialised and restored later.

**External input is not awaited; it is replayed.** Everything crossing the recorded
boundary — signals, syscall results, shared-memory reads — is in the trace, so during
replay there is no external party and nothing to wait for. That is the clean version
of the position every replay engine takes for activity results, applied to all input.

**The clock-substitution idiom is the transferable part.** Go's synchronous-test
facility and Tokio's paused time advance only when everything is durably blocked,
which is the same rule a deterministic scheduler needs and the same rule a
durable-execution test harness needs in order to compress virtual time safely.

---

## Implications for a durable-execution library

- **Comparing full machine state at every event is the ceiling for divergence
  detection**, and it shows how far below that ceiling an argument hash sits. A hash
  fires only when the program issues an operation; a program that consumes a replayed
  value differently and then issues an identical operation replays silently wrong.
  Closing that gap means hashing the inputs to decisions, not only the arguments of
  effects.
- **Snapshots belong as a cache over the record, never as a substitute for it.** `rr`'s
  checkpoints are forks placed along a timeline to make navigation cheap, and any one
  of them can be discarded and re-derived from the trace. That is the relationship a
  durable-execution layer should keep between a snapshot and its journal.
- **Rewinding a replayed execution to an arbitrary point is practical.** Jump to an
  earlier checkpoint and replay forward, which is what makes reverse execution work at
  interactive speed (§10). A library that already replays deterministically has most of
  this machinery and usually exposes none of it.
- **Record why the runtime advanced, not only what it returned.** A desched event
  marks a call that was about to block, which lets replay distinguish "returned
  immediately" from "waited" (§11). A record of results alone cannot tell a stalled
  program from a fast one.
- **Order-driven recording is cheaper than data-driven and needs more from the
  program.** Recording the order of interactions and re-deriving the values requires
  every party to be deterministic; recording the values does not. A durable-execution
  layer that journals results has chosen the expensive, permissive option, and should
  know it made that choice.
- **A total boundary makes the journal-versus-world question vanish**, and the cost is
  visible in what `rr` has to do to keep it total: close leaks to the window system,
  the audio server and the GPU by configuration or by enlarging the recorded group. A
  library whose effects reach a world it cannot enclose does not have that option.
- **Advance virtual time only when everything is durably blocked.** The rule Go's and
  Tokio's test clocks follow is the one a deterministic test harness needs to compress
  time without changing behaviour.
- **Score the design on the survey's five axes** — log size, recording slowdown, replay
  slowdown, implementation cost, and probe effect. The last matters most for a library
  that supervises child processes, because recording changes their timing.

---

## Sources

- O'Callahan, Jones, Froyd, Huey, Noll, Partush, "Engineering Record And Replay For Deployability" (USENIX ATC 2017; extended report arXiv 1705.05937), read from the arXiv PDF on September 11, 2026.
- `rr-debugger/rr` at `5c202cd8cb678b32107fa6aaf1c6108420bc53a8` (`$REPOS/rr`): `src/RecordSession.cc`, `src/ReplaySession.cc`, `src/ReplaySession.h`, `src/ReplayTask.cc`, `src/PerfCounters.h`, `src/Task.cc`, `src/Scheduler.h`, `src/Scheduler.cc`, `src/RecordCommand.cc`, `src/ReplayTimeline.h`, `src/preload/syscallbuf.c`, `src/rr_trace.capnp`.
- LeBlanc, Mellor-Crummey, "Debugging Parallel Programs with Instant Replay", IEEE Transactions on Computers 36(4), 1987 (abstract, read via the DOI record).
- Ronsse, De Bosschere, "RecPlay: a fully integrated practical record/replay system", ACM TOCS 17(2), 1999 (abstract, read via the DOI record).
- Chen, Zhang, Guo, Li, Wu, Chen, "Deterministic Replay: A Survey", ACM Computing Surveys 48(2), 2015 (abstract, read via the DOI record).
- Go `testing/synctest` package documentation and Tokio `time::pause` documentation, read September 11, 2026.
- Sibling pages: [deterministic simulation testing][dst], [replay versus snapshot][replay-vs-snapshot], the [catalog index][catalog].

<!-- References -->

[rr-arxiv]: https://arxiv.org/abs/1705.05937
[rr-usenix]: https://www.usenix.org/conference/atc17/technical-sessions/presentation/ocallahan
[rr-recordsession]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/RecordSession.cc
[rr-replaysession]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/ReplaySession.cc
[rr-replaysession-h]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/ReplaySession.h
[rr-replaytask]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/ReplayTask.cc
[rr-perfcounters]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/PerfCounters.h
[rr-task]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/Task.cc
[rr-scheduler-h]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/Scheduler.h
[rr-scheduler-cc]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/Scheduler.cc
[rr-recordcmd]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/RecordCommand.cc
[rr-timeline]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/ReplayTimeline.h
[rr-syscallbuf]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/preload/syscallbuf.c
[rr-capnp]: https://github.com/rr-debugger/rr/blob/5c202cd8cb678b32107fa6aaf1c6108420bc53a8/src/rr_trace.capnp
[instant-replay]: https://doi.org/10.1109/TC.1987.1676929
[recplay]: https://doi.org/10.1145/312203.312214
[chen-survey]: https://doi.org/10.1145/2790077
[go-synctest]: https://pkg.go.dev/testing/synctest
[tokio-pause]: https://docs.rs/tokio/latest/tokio/time/fn.pause.html
[dst]: ./deterministic-simulation-testing.md
[replay-vs-snapshot]: ./replay-vs-snapshot.md
[catalog]: ./index.md
