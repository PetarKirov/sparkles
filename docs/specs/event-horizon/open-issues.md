# `sparkles:event-horizon` — Open specification issues

_Companion to [SPEC.md](./SPEC.md) and [PLAN.md](./PLAN.md). A running list of
behavioral questions surfaced during spec design and review that are **not yet
resolved** in the normative spec. Each entry records where it bites, the
options, and any current leaning. Resolve by folding a decision into SPEC.md,
then delete the entry here (and reference the commit)._

Settled during the initial design pass (now normative in SPEC.md, listed here
so they are not relitigated by accident): no epoll fallback (§3.4); `Buf`
not `SmallBuffer` as the tier-A transfer currency (§6.1); slab tokens, not
raw pointers, in `user_data` (§4.2); work-stealing limited to never-started
tasks (§11); flattened `Cause` (§9.2); `Effect!(T, E)` with no `R` (§12);
Schedule composition via `&`/`|` (§10.4); function-pointer callbacks at tier
A (§4.4); in-ring futex parking degrading probe-gated below kernel 6.7 (§11);
out-parameter factories for move-only owners (§9.1); the loop-side
`RootScope` alias as the blessed `Scope` instantiation (§7.2); minimal UDP
vocabulary (`sendTo`/`recvFrom`) in v1 with msghdr variants deferred (§4.1,
O19).

## O1 — Full fiber migration under work-stealing

**Where:** SPEC §11.

v1 pins every started fiber to its worker (normative). The open half: is an
explicit `allowMigration` opt-in (caller asserts the body is TLS-free) ever
worth shipping, given LDC's TLS-address caching across fiber switches
(druntime `CheckFiberMigration`) makes the contract unverifiable?

**Options:** (A) never — task-start stealing suffices; (B) opt-in after a
druntime/LDC audit, if M14 shows hot-shard imbalance that start-stealing
cannot level.

**Leaning:** (A) until the M14 matrix proves otherwise.

## O2 — Cross-thread handoff mechanism

**Where:** SPEC §11.

Futex-wake, `MSG_RING`, and eventfd differ in syscall count, wake latency,
and what state arrives with the wake.

**Options:** measured head-to-head in the M9 bench; the seam stays
mechanism-agnostic until then.

**Leaning:** futex parking for "any work available" + `MSG_RING` for targeted
completion/fd handoff; eventfd only inside the kqueue/IOCP backends.

**Update (superseded twice — read the whole entry):** per-worker deques landed
first as _mutex-guarded_ ones, and measured **no change** on the walker
(~0.103 s); the conclusion drawn at the time — "the fiber-per-task cost is the
bottleneck" — was wrong. Hardware counters later showed the real cause was
per-worker `io_uring` ring + fiber-stack setup ([O23](#o23--pool-per-worker-setup-weight-vs-short-batch-workloads)).
The deques were then rebuilt **lock-free** (Chase-Lev: owner push/pop tail,
thieves CAS the head) and given randomized victim selection, batch
(steal-half) stealing, and a `PAUSE`-based idle spin — that combination is what
made the pool beat `rust-rayon` on every walk shape (`benchmarks.md` §2), so
the mutex _was_ costing something, just not on the workload first used to judge
it. Verified race-clean under ASan (70 runs) and TSan (see
`libs/event-horizon/tsan-suppressions.txt` for why the residual reports are
false positives).

Still open here: idle parking polls a short in-ring timer, so the
futex/`MSG_RING`-driven wakeup and targeted stealing this entry is really about
remain unbuilt.

## O3 — betterC reach of tier A

**Where:** SPEC §5.

The blockers: the op-slab and timer storage (solvable via caller-supplied
memory) and whether `Expected` 0.4.x compiles under `-betterC` (unverified).

**Options:** (A) tier A is `@nogc nothrow` but druntime-linked; keep
signatures betterC-possible (function pointers, no hidden allocation) and
ship a `-betterC` configuration later if demand appears. (B) commit from M3
with caller-supplied slabs and a reduced error surface.

**Leaning:** (A); do not gate M3 on a `-betterC` CI configuration.

## O4 — Fiber stack sizing and pooling policy

**Where:** SPEC §7.1.

druntime's Linux default is 4 pages (16 KiB) + guard. D fibers cannot grow;
`SchedOptions.defaultStackSize` proposes 64 KiB. Real verb-call depths
(including `Expected` chains under `-checkaction=context`) are unmeasured.

**Options:** (A) 64 KiB default, per-spawn override, size-classed pooling;
(B) smaller default after measuring; (C) a custom growable-context primitive
(libmprompt-style) — post-v1 at best.

**Leaning:** (A) for M4, revisit with the M3+ bench; (C) only if M14 shows
footprint as the limiting factor.

## O5 — CI for the kernel-feature matrix

**Where:** PLAN M2 onward.

Kernel feature cliffs (6.1 floor, 6.7 futex) and lockdowns
(`io_uring_disabled`, seccomp) vs single-kernel CI runners.

**Options:** (A) every feature test degrades to `SKIP` (the research-examples
pattern); (B) a qemu matrix booting pinned kernels; (C) fault-injection shims
faking probe results so degradation paths run on any kernel.

**Leaning:** (A) + (C); (B) post-v1 if gaps bite.

**Update:** (A) is done — all 53 degradation sites call `skipTest`, so a
degraded host reports `N skipped` with reasons instead of a full green. (C) is
still ad-hoc: forcing `UringBackend.open` to return a `setup` error by hand is
what proved the skip paths (and found the dead guard fixed in
`group.threadPerCore.shareNothingWorkers`), but nothing in-tree does it
repeatably. A version-gated probe-result shim is the remaining work; without it
the whole skip population is exercised only by hand.

## O6 — Zero-copy, SQPOLL, NAPI, `uring_cmd`

**Where:** SPEC §3.3, deliberately absent from v1.

`SEND_ZC`'s two-CQE notif protocol, `RECV_ZC` NIC mapping, SQPOLL, NAPI, and
`uring_cmd` add the most lifetime complexity for extreme-throughput payoffs.

**Options:** (A) a post-v1 series once the multi-CQE slot shapes are proven;
(B) pull `SEND_ZC` (floor-guaranteed) into M8 alongside multishot.

**Leaning:** (A); the slot state machine already reserves multi-CQE ops
(multishot, linked pairs) so the shapes are proven in M8.

## O7 — Wayland/Vulkan frame-loop integration

**Where:** SPEC §5.4 (`runOnce` embedding), GUI use case.

**Options:** (A) `run()`/`runOnce(timeout)` as the two entry points (in spec
now); (B) a first-class external-waker capability later.

**Resolved (2026-08-07): both, folded into SPEC as §5.6 + §15 (M16).** The
external waker landed as the `eventfd`/`EVFILT_USER`/`PostQueuedCompletionStatus`
mechanism of SPEC §5.6, and the GUI/TUI integration is specified in §15:
the recommended shape is inversion (the frame loop as the root fiber over
a `Ticker`, §15.3), with `Sched.tick` (§7.2) as the embedding hatch for a
loop the application does not own, and `OpPollAdd` (§15.1) as the
foreign-fd door a real windowing connection will use. Deeper
Wayland/Vulkan-native pacing (frame callbacks as a vsync source) stays
with the window-system replacement work, as planned.

## O8 — Kernel floor: 6.1 baseline vs a compat mode

**Where:** SPEC §3.3.

The 6.1 floor guarantees both operating modes and the ≤ 5.19 tier-3 set,
deleting all per-op fallback machinery on Linux. But 5.15 LTS (and some
container hosts) remain common through v1's life.

**Options:** (A) hard 6.1 floor (current spec); (B) a `compat` LoopMode
(plain ring, per-op probing, no DEFER_TASKRUN) reintroducing the degrade
paths for 5.x.

**Leaning:** (A) — the fallback-free simplification is exactly the point of
the no-epoll decision; revisit only on real deployment pressure.

## O9 — Submit backpressure policy

**Where:** SPEC §5.2.

The implicit one-flush retry hides a syscall inside `submit`;
latency-deterministic callers may want strictness.

**Options:** (A) keep implicit-flush-then-EAGAIN only; (B) also expose
`trySubmit` (no hidden syscall).

**Leaning:** (A) for M3; add (B) if the bench shows the hidden flush
mattering.

## O10 — `Cause` fidelity

**Where:** SPEC §9.2.

Flattened first-cause + `suppressedCount` loses ZIO's `Then`/`Both` structure
(parallel failures, fail-during-finalize).

**Options:** (A) flattened forever, documented; (B) an allocator/hook-fed
side chain for full fidelity later.

**Leaning:** (A) now; the hook door stays open.

## O11 — Timeout surface

**Where:** SPEC §8.3, §10.4.

A fired deadline currently surfaces as `Cause.interrupted` with
`InterruptKind.deadline` (test via `isTimeout`); per-op `LINK_TIMEOUT`
deadlines surface as typed `IoError` failures. Two shapes for one concept.

**Options:** (A) keep the split (scope deadline = interrupt; op deadline =
Fail); (B) a typed `TimedOut` variant injected into `E` everywhere.

**Leaning:** (A) — it matches provenance (§8.5); decide before M5 tests
calcify.

## O12 — `Ctx` canonicalization and template budget

**Where:** SPEC §10.2.

Each distinct `Caps` ordering re-instantiates every generic function it
flows through (cf. the measured `Optional!T` frontend cost in this repo's
history).

**Options:** (A) document `CtxOf` (label-sorted) as the only public
constructor; (B) keep `ctx(...)` positional and accept the bloat; measure in
the M14 compile-time bench.

**Leaning:** (A), with `ctx(...)` normalizing internally.

## O13 — Hook/`NoGcHook` unification

**Where:** SPEC §9.1.

`sparkles.base.text.errors.NoGcHook` and `sparkles.event_horizon.errors.NoGcHook`
are near-identical; a third copy will appear with any new Expected
vocabulary. They are no longer _exactly_ identical: event-horizon's hook adds
`onAccessEmptyValue` to make `IoResult` instantiable with move-only payloads
(SPEC §9.1) — a unified base hook would carry that member too.

**Options:** (A) promote one shared hook into `sparkles:base` (with
`onAccessEmptyValue`); (B) accept duplication so the future
`sparkles:effects` split carries no base coupling.

**Leaning:** (A) — `base` is already a dependency everywhere that matters.

## O14 — Spawn ordering

**Where:** SPEC §7.2.

**Options:** (A) deferred-FIFO (child enqueued, parent continues — Trio-like,
fair); (B) run-child-first (Eio — better locality, deterministic startup).

**Leaning:** (A); decide before M4 tests calcify.

## O15 — Tier-A waker mechanism

**Where:** SPEC §5.1 (`Waker`), §11.

**Options:** (A) registered eventfd + persistent internal multishot-poll op;
(B) unify with the group's in-ring futex word from day one (≥ 6.7 only,
eventfd below).

**Leaning:** (A) for M3 (single-loop); group.d re-plumbs it in M9.

## O16 — Multishot backpressure and the `Incoming` range

**Where:** SPEC §4.3, §7.3.

A multishot accept/recv slot needs a bounded pending-completion queue; when
full, pause (cancel + re-arm) or degrade to single-shot? And is a fiber-tier
`Incoming` range over multishot accept worth shipping in v1?

**Options:** (A) bounded queue + pause-and-re-arm; (B) degrade to
single-shot under pressure; plus ship/defer the `Incoming` range.

**Leaning:** (A); `Incoming` deferred to M8.

## O17 — Accept peer address

**Where:** SPEC §4.1.

v1 returns the fd only (`getpeername` on demand) to keep slots small.

**Options:** (A) keep; (B) a side-arena keyed by slot index when `net.d`
wants zero-syscall peer addresses.

**Leaning:** (A) until a profiled need appears.

## O18 — Timer representation at scale

**Where:** SPEC §5.3, §7.3 (`sleep`).

One in-ring `TIMEOUT` op per timer means N sleeping fibers cost N kernel
timer ops and N op slots. The `hasNativeTimeout`-absent path already builds a
user-space heap.

**Options:** (A) one `TIMEOUT` per timer (simple, kernel-managed); (B) heap +
a single armed op for the earliest deadline (fewer slots, more userspace
bookkeeping).

**Leaning:** (A) for M3/M4; measure slot pressure in the M8/M9 bench and
switch to (B) if it bites.

## O19 — msghdr-based datagram ops

**Where:** SPEC §4.1, §7.3.

v1 ships `sendTo`/`recvFrom` (single buffer + address via the operand store).
`sendmsg`/`recvmsg` (scatter-gather iovecs, control messages/ancillary data —
needed for fd passing and UDP GSO) require iovec + msghdr storage in or
beside the slot.

**Options:** (A) defer to the milestone that needs them (proc fd-passing or
HTTP/3); (B) reserve operand-store space now.

**Leaning:** (A); the operand store is a union — adding members later is
ABI-free.

## O20 — Cross-fiber channel primitive

**Where:** SPEC §8.4; needed by M13 (the `apps/terminal` port's PTY-reader →
render-loop handoff).

v1 defines `JoinHandle` as the only non-I/O park. A producer/consumer
`Channel!T` (bounded SPSC within a worker; cross-worker via `MSG_RING`) is a
recognized gap.

**Options:** (A) design in M5 alongside the park/wake machinery it reuses;
(B) defer to M13 and let the terminal port drive the shape.

**Resolved (2026-08-07): (B) ran its course — the consumers arrived and the
shape is folded into SPEC §14 (M16).** The UI-loop work (SPEC §15.3) is
exactly the deferred-to consumer: the input-fiber → UI-fiber and
PTY-reader → render-fiber handoffs. v1 is the bounded **intra-worker**
channel parking through the executor seam (effects-side, ring-free), with
close-then-drain semantics and cancellation checkpoints; the cross-worker
variant stays open with the M9 `MSG_RING`/futex machinery it needs.

## O21 — How far the `Allocator` parameters spread

**Where:** SPEC §4.2, §6.3, §16 (memory-management policy).

`BufferPool`, `OpSlab`, and `EventLoop` are generic over their allocator
(M8). Unplumbed: `SchedOptions` (the fiber slab stays GC by design, but a
future arena+`addRange` knob would enter here) and `LoopGroupConfig` (M9 —
per-worker allocators for thread-per-core NUMA locality are the interesting
case).

**Options:** (A) stop at the three current types until M9's `LoopGroupConfig`
forces the question; (B) plumb `Sched`/`LoopGroup` now.

**Leaning:** (A) — M9 decides with real per-worker requirements on the table.

## O22 — GC stop-the-world vs threads blocked in `io_uring_enter`

**Where:** SPEC §11 (`WorkStealingPool.run`).

A GC collection stops the world by signal-suspending every thread; a worker
parked in `io_uring_enter` (`io_cqring_wait`) cannot be suspended cleanly,
so a collection triggered by another worker's allocation can deadlock the
group. M9c disables the collector for the pool's lifetime (`GC.disable`) —
sound because all pool allocations are setup-phase and the hot path is
`@nogc`, but it forfeits collection during long runs.

**Empirically confirmed load-bearing** (2026-07-06): removing `GC.disable`
and stress-running the pool fails ~1 run in 40 (vs 0/40 with it) — so this is
a real interaction, not defensive paranoia, and the workaround stays for v1.

**Options:** (A) keep `GC.disable` for v1 (bounded-work pools); (B) a
GC-safe blocking wait — register an in-ring cancellation the suspend signal
handler triggers, or use `thread_suspendHandler`-aware waiting so a
collection can proceed; (C) an arena allocator for task closures so the pool
never touches the GC at all.

**Leaning:** (A) now; (B)/(C) when a long-lived pool with steady allocation
is a real workload.

**Severity update (2026-08-04) — this flakes CI.** `GC.disable` mitigates but
does not eliminate it. Measured with the event-horizon suite pinned to **two
CPUs** (what a GitHub runner is): **1 hang in 25 runs**. Exposure is per
`pool.run`, and it compounds — a variant of
`pool.workStealing.distributesTasksAcrossWorkers` that called `pool.run` five
times hung **6 of 18**. Two consequences: (a) any pool test on a
CPU-constrained runner is a ~4 %-per-run flake, so a green CI run is not
evidence the deadlock is gone; (b) tests should call `pool.run` **once**, which
is now a stated constraint on writing them. This raises the priority of a
GC-safe blocking wait from "correctness nicety" to "CI reliability".

**Fix status (2026-08-04), tracked in [#171](https://github.com/PetarKirov/sparkles/issues/171):**

- **(C) mark the thread "in syscall"** so the collector skips signalling it
  while still scanning its stack — the Go `_Psyscall` / JVM "in native" model.
  The only option that removes the hazard instead of bounding it, but druntime
  has no such API; needs an upstream `thread_enterSyscall`/`thread_exitSyscall`
  (or `thread_suspendAll` honouring an in-syscall flag). **Chosen direction**;
  #171 is the reminder to file upstream.
- **Rejected — detach workers from the GC** (`thread_detachThis`). A detached
  thread's stack is not scanned, so `FiberTask` closures and `Buf`s would sit in
  unscanned memory: silent use-after-free. Trades a hang for corruption.
- **(E) bounded wait — attempted and reverted.** Capping each
  `io_uring_enter` at ~50 ms (looping internally so `runOnce`'s semantics are
  unchanged) is sound in principle but is **not** a drop-in: routing every wait
  through the deadline path changes _when SQEs are submitted_. The
  null-deadline path submits and waits atomically (`submitAndWait(want)`);
  the deadline path is `flush()` then `wait(want, arg)` — itself a workaround
  for a `during` 0.5.0 trap. Measured: `io.steadyState.zeroAllocations` went
  from milliseconds to **~66 ms per round**, every wait burning its full slice
  instead of waking on a completion. A correct (E) needs a backend primitive
  that submits _and_ waits with a timeout in one call — a change to the backend
  seam, not to `runOnce`.

## O23 — Pool per-worker setup weight vs short batch workloads

**Where:** SPEC §11 (`WorkStealingPool`), `benchmarks.md` §2.

Each worker creates its own `io_uring` ring + thread + scheduler. That cost is
designed to amortize over a long-lived server, but for a short CPU-bound batch
(the polyglot-walks walker: ~50 ms) fanned out to all cores it dominates —
measured optimum is 2–4 workers, and the all-CPUs default is the _worst_ point
on the scaling curve. Falsified en route: fiber-per-task overhead
(`submitBlocking` inline — no change), queue-mutex contention (per-worker
deques — no change), idle-scan thrash (exponential backoff — marginal).

**Options:** (A) document it (done) and let callers pick a worker count that
fits the workload; (B) lazily create rings (only when a worker first parks on
I/O) so a CPU-only batch pays no ring tax; (C) a separate ring-less CPU pool
(effectively `std.parallelism.taskPool`) for `submitBlocking`-only workloads;
(D) a global-quiescence scheme that isn't a single hot atomic.

**Resolved (2026-07-06):** shipped option (C) as `LoopGroupConfig.cpuBound` —
workers become plain threads running `submitBlocking` tasks inline, no
per-worker ring or fibers. Plus relaxed (`MemoryOrder.raw`) counters. Result:
the walker now BEATS rust-rayon on a real source tree (1.16× at 16 workers,
1.9× on a dense synthetic tree), and scaling turned positive. See
`benchmarks.md` §2. The default (async, per-worker rings) is unchanged — it is
the right tool for long-lived async-I/O fan-out.

## O24 — Benchmark suite: what moved, and what is superseded but not retired

**Where:** `libs/event-horizon/bench/`; `benchmarks.md`.

The benchmarks now run on **`sparkles:test-runner`**
(`libs/event-horizon/bench/suite/`, `dub test -b bench -- --bench`), which
supplies the counting pass, the metric catalog, and `--bench-json` snapshots.
Three artifacts predate that move and are **superseded but still in the tree**,
deliberately, because each still does something the suite does not:

| artifact                             | status                                                                                                                                                              |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bench/loop-bench.d`                 | superseded by `bench/suite/`. Kept only because it produced the pre/post-rebase baseline; **retire once the suite's numbers are confirmed on an idle machine**      |
| `bench/perf/` (ImportC)              | fully superseded by the runner's `--perf`; retire with `loop-bench.d`                                                                                               |
| `bench/walk-bench.sh` + `gen-tree.d` | **keep** — drives the external `rust-rayon`/`taskPool` binaries, which cannot run under the D runner, and its `strace -c` pass covers `--syscalls` (root-only here) |

Two cautions for whoever picks this up:

- The §1 tier numbers were corrected **twice** during the port (the veneer, and
  registered-vs-plain reads — both old figures were measurement artifacts, see
  the corrections in `benchmarks.md` §1). They are believed right but were
  measured on a machine also running builds; one clean confirmation run on an
  idle host before treating them as final is warranted.
- The suite's own `benchIter`/`benchCase` closures must build everything they
  need **inside** the closure — the runner defers them past the test body.
  Getting this wrong cost a deadlock, a segfault, and one silently-wrong
  published number here. The API fix is decided and specified in
  [test-runner O14](../test-runner/open-issues.md) but **not implemented**; until
  it is, this is a live footgun for anyone adding a benchmark.

**Options:** (A) retire `loop-bench.d` + `bench/perf/` after a confirmation run
(the intent); (B) keep `loop-bench.d` indefinitely as an independent
cross-check of the runner's numbers.

**Leaning:** (A) — two harnesses measuring the same thing drift, and the
runner's is the one with statistics.

## O25 — Peer-backend attribute parity is uneven (and CI cannot see most of it)

**Where:** `backend/{uring,kqueue,iocp}.d`; SPEC §3.1, §16.

macOS CI running for the first time exposed that the peer backends had drifted
from `uring`'s attribute surface, in ways Linux-only development cannot catch.
Fixed on this branch: every `trySubmit` overload plus kqueue's
`armFilter`/`armTimer`/`setNonBlocking` were missing `@nogc`, so
`EventLoop.submit` inferred non-`@nogc` off Linux and `callback-echo.d` — whose
point is a `@nogc` completion callback — failed to compile there. IOCP had the
identical gap and **no CI job would ever have shown it**: the Windows job builds
one OS-API example, not the example set.

Remaining, verified as inconsistent but not currently breaking (nothing requires
`run`/`runOnce` to be `@nogc`):

| member          | uring   | kqueue  | iocp |
| --------------- | ------- | ------- | ---- |
| `submitAndWait` | `@nogc` | —       | —    |
| `open`          | `@nogc` | `@nogc` | —    |

**Options:** (A) annotate to match `uring` and let the compiler hold the line;
(B) assert parity structurally — a `static assert` in the backend concept that
each required member carries the attributes the tier-A contract advertises, so
drift fails at the seam instead of at a distant call site; (C) leave it, and
accept that the attribute surface is per-backend.

**Decided: (B), preceded by CI coverage.** Two parts, in this order.

**1. Compile-only CI per backend — do this first.** The concept assert below
only fires when something compiles that backend, and today nothing does: **no
job builds the example set on Windows** (the Windows job is a single OS-API
example), which is exactly why IOCP's gap was undetectable. Both checks are
cheap (`-o- -c`, no macOS/Windows runner needed) and are already possible from
one Linux runner:

```bash
bash libs/event-horizon/scripts/verify-kqueue-linux.sh          # kqueue, via libkqueue
nix develop .#win32 -c win32-ldc2 -o- -c -unittest …            # IOCP, via the cross toolchain
```

This ordering matters because CI coverage would have caught **every** break
found on this branch, including the ones an attribute assert cannot see (the
`scope_.d` version gate, `io.d`'s ungated bufRing surface).

**2. Assert the attribute contract at the seam.** In `isCompletionBackend`,
for each op the backend claims to lower:

```d
enum submitIsNoGcNothrow(B, Op) =
    __traits(compiles, () @nogc nothrow {
        B b = B.init; OpSlot s;
        cast(void) b.trySubmit(Op.init, OpToken.init, s);
    });

static assert(submitIsNoGcNothrow!(B, Op),
    B.stringof ~ ".trySubmit(" ~ Op.stringof ~ ") is not @nogc nothrow"
    ~ " — tier A promises a @nogc submit path (SPEC §16)");
```

A `static assert`, **not** a `bool` folded into the constraint: a failed
constraint makes the backend silently _not a backend_, surfacing as a baffling
"no matching overload" far from the cause. The assert names the backend, the
op, and the promise broken.

What tier A actually promises needs stating in SPEC §16 as part of this: the
`@nogc nothrow` submit path is the documented headline property, so that is the
minimum the seam enforces. `submitAndWait`/`open` are deliberately **not**
included — nothing requires `run`/`runOnce` to be `@nogc`, and asserting more
than is promised would block backends for no user-visible gain.

## O26 — Peer-backend child reap: `EVFILT_PROC` and IOCP wait packets

**Where:** SPEC §13.2 (portability paragraph); PLAN M15.

`OpWaitid` is portable-shaped. **The kqueue lowering has since landed**
(`feat(event-horizon.kqueue): lower OpWaitid onto EVFILT_PROC`); IOCP is still
outstanding. The sharp edges each lowering carries:

- **kqueue `EVFILT_PROC`/`NOTE_EXIT`** delivers the exit status in `data`,
  but registering the filter races the exit: a child that dies before
  `kevent` registration returns `ESRCH`, so the lowering needs a
  register-then-`waitpid(WNOHANG)` back-check to close the window. Under
  libkqueue on Linux the filter is emulated via pidfd — semantics to
  verify, not assume. _(Shipped with the back-check; this is the same
  mechanism `DISPATCH_SOURCE_TYPE_PROC` uses — see the
  [GCD survey](../../research/async-io/gcd/index.md).)_
- **IOCP** has no process-completion primitive; the options are a
  wait-packet (`NtAssociateWaitCompletionPacket`, undocumented-ish but
  what modern runtimes use) vs a thread-pool `RegisterWaitForSingleObject`
  bounce. Job objects enter only if `killGroup` is to mean anything on
  Windows.

**Options:** (A) implement both lowerings in M15 to the semantics above;
(B) keep peer-platform reap on a helper-thread `waitpid`/`WaitForSingleObject`
bounce feeding the backend's completed queue (the kqueue worker-pool
pattern) until the native paths are proven.

**Leaning:** (B) as the correctness baseline shipped with M15, with (A) as
per-backend refinements — the API is identical either way, and the bounce
is exactly how the kqueue backend already handles regular files.

## O27 — kqueue pays a syscall per submit; batch the change list into the wait

**Where:** `backend/kqueue.d` (`armFilter`, `submitAndWait`, `flush`, `cancel`);
`backend/concept.d`; SPEC §3.1, §16.

`armFilter` issues its own `kevent(_kq, &change, 1, null, 0, null)` for every
submission, and `submitAndWait` then makes a second, separate call to collect
events. With `EV_ADD|EV_ONESHOT` the registration is consumed on delivery, so a
steady-state read loop pays **register + wait, every cycle**. That is the
mechanism behind `TVW8`'s recorded churn regression (98.2 → 99.6, "one ring
round-trip per drain cycle under saturation") — but the case for fixing it is
the flat per-op tax, not the 1.4 pp, since the tax applies to every op the
backend will ever run and grows as more of the stack moves onto the ring.

`kevent(2)` takes a changelist **and** an eventlist in one call — libdispatch's
`_dispatch_kq_drain` is built on exactly this, and its workqueue arm goes
further, returning deferred re-registrations for the kernel to re-arm on the way
back (see the [GCD survey](../../research/async-io/gcd/index.md)). libkqueue
implements the combined form too, so the Android default and the Linux CI leg
are unaffected.

A second, pre-existing defect falls out of the same change. `concept.d` documents
the submit predicate as `bool queued = … // false = SQ full` — **backpressure
only** — but `armFilter` also returns `false` when `kevent` itself fails,
conflating kernel rejection with a full queue. The loop's backpressure path
retries, so today an `EBADF` submission retries forever.

**Options:** (A) status quo; (B) accumulate changes in a fixed array, pass them
as the changelist of the next `submitAndWait`, and let submission failures arrive
as `EV_ERROR` entries synthesized into completions; (C) keep the immediate
syscall but split the return so kernel errors surface as a completion while
SQ-full stays `false`.

**Decided: (B).** It is the only option that both removes the tax and repairs the
contract, and it converges kqueue on `io_uring`, where a bad SQE also fails as a
CQE rather than at submit time. (C) is more code for less benefit.

Consequences, all decided with it:

- **`false` means "submission resource full, call `flush()`"** on either the
  op-slot freelist or the change array — the same sentence that is already true
  of uring's SQ ring.
- **`flush()` stops being a lie.** It is `=> ioOk(0u)` on kqueue today against a
  real `_io.submit(0)` on uring; it becomes a change-only `kevent`. Its return is
  the change-entry count, and `concept.d` should state the contract as
  **submission-side units flushed, backend-defined** — forcing a shared meaning
  would make kqueue count ops it did not submit, for a number no caller reads
  beyond "did progress happen".
- **Cancellation goes through the same array.** `cancel` issues its own immediate
  `kevent` today, so a submit-then-cancel before any wait would race its own
  `EV_ADD`. One FIFO array makes ordering a property of the data structure
  instead of a rule to remember.
- **The synth short-circuit must flush first.** `submitAndWait` returns early on
  `if (_synthCount > 0)` _before_ reaching `kevent`, which would starve pending
  changes for as long as synthesized completions keep arriving.

## O28 — `EV_DISPATCH` re-arming, and the recycled-slot hazard it opens

**Where:** `backend/kqueue.d` (`armFilter`, `release`, `submitAndWait`); depends
on O27.

`EV_ONESHOT` consumes the knote on delivery, so every op re-adds from scratch.
`EV_DISPATCH` instead disables the knote and leaves it registered, making the
re-arm a change entry rather than a fresh add — which is only worth having once
O27 makes change entries free. libdispatch uses it on every fd source, and
libkqueue honours it in `read`/`write`/`timer`/`user`.

Its Darwin companions are **not** portable: libkqueue carries a literal
`FIXME - Should respect EV_UDATA_SPECIFIC but that's a whole` in
`src/common/knote.c` and has no `EV_VANISHED` at all. Since Android ships
kqueue+libkqueue as its default backend, adopting them would mean two
knote-identity models with CI able to exercise only one.

**The hazard.** `release()` clears `live` and pushes the slot onto the freelist
immediately, and the reap loop matches an event to its op by
`cast(KqOp*) evs[i].udata` with no validation beyond a null check. Under today's
`EV_ONESHOT` plus a synchronous `EV_DELETE` that is safe by construction — the
knote is always gone before the slot can be recycled. O27's batched cancel and
this issue's explicit delete-on-release both push that delete into a batch,
opening a window in which an already-queued kernel event carries a `udata`
pointing at a **recycled slot** and is attributed to a different op's token.

**Options:** (A) `EV_DISPATCH` only, no `EV_UDATA_SPECIFIC`/`EV_VANISHED`;
(B) both, with the Darwin-only pair under `version (OSX)`; (C) keep
`EV_ONESHOT`. And, for the hazard: (1) check `op.live` in the reap loop —
cheap but ABA-unsafe, since the slot may be live again as a _different_ op;
(2) an index+generation value in `udata`, bumped on release and validated on
delivery; (3) flush synchronously on release, reintroducing the per-op syscall.

**Decided: (A) + (2).** `EV_VANISHED`'s payoff is diagnosing a descriptor closed
under a live registration, which libdispatch itself treats as unrecoverable
(`DISPATCH_CLIENT_CRASH(err, "Do not close random Unix descriptors")`) — a better
abort message, not a recovery path, and not worth a Darwin-only lifecycle fork.
(2) is a convergence rather than a new concept: `io_uring`'s `user_data` and this
library's own `OpToken` are already validated tokens rather than raw pointers,
and it costs one `uint` in `KqOp` plus one compare per delivered event.

`EV_DISPATCH` also makes the delete explicit — `EV_ONESHOT` removed the knote for
free — so slot release must emit one or knotes leak across successive ops on the
same fd. **The generation token lands as its own commit, before the batching**,
so the safety fix is bisectable independently of the change that makes it
necessary.

## O29 — Worker wakeup: one `wake()` capability, both backends

**Where:** `pool.d` (idle backoff), `backend/{kqueue,uring}.d`,
`backend/concept.d`. Refines O2 and O15.

Idle workers sleep on an exponential-backoff short `TIMEOUT` and re-check — on
**both** backends, since O2's `FUTEX_WAIT`/`MSG_RING` answer for uring is
unimplemented. kqueue has a native answer available now: `EVFILT_USER` +
`NOTE_TRIGGER`, which is precisely what libdispatch uses for its own manager
wakeup (`_dispatch_kq_init` registers exactly one such knote), and which
libkqueue implements in `src/linux/user.c`.

Implementing only the kqueue arm would make the peer backend strictly better than
the primary one at the thing the primary one is optimised for — the inversion O25
exists to prevent.

**Options:** (A) kqueue-only now, uring's `FUTEX_WAIT` as a follow-up;
(B) an optional backend capability (`hasWake`/`wake()`) with both arms
implemented; (C) defer until both can land together.

**Decided: (B), both arms.** The pool's idle path is then written once against a
seam rather than twice against two backends. The uring arm is testable on the
`pc2` NixOS host (kernel 6.18, 32 CPUs), comfortably past `FUTEX_WAIT`'s 6.7
floor.

**Signature: bare, coalescing, no payload.** `EVFILT_USER`/`NOTE_TRIGGER`
coalesces natively and `FUTEX_WAKE` is edge-triggered, so coalescing is what both
substrates give for free and a counted wake would mean fighting both. No payload:
one is only useful for `MSG_RING`-targeted stealing, which is a _different_ O2
optimisation, and shaping the seam around one backend's capability is the mistake
this entry chose (B) to avoid.

## O30 — CPU parallelism and affinity are asked wrongly on every platform

**Where:** `pool.d:70`, `pool.d:379`, `group.d:99`, `group.d:236`; a new
`libs/base` module.

Six call sites reach for `std.parallelism.totalCPUs`, and it is the wrong answer
twice over.

**Sizing.** On Apple silicon the kernel's parallelism answer is per-QoS, because
the background class is confined to the efficiency cluster.
`pthread_qos_max_parallelism` measured on an M4 Max reports **4 for background
against 14 for every other class**, while `totalCPUs` reports 14 — a background
worker set sized from it oversubscribes the E-cluster 3.5×. libdispatch sizes
`dispatch_apply` from exactly this call and falls back to the CPU count only if it
fails (`src/shims.h`). The same bug exists on Linux for a different reason: a
containerised process's `cpu.max` quota is invisible to `totalCPUs`. _(The cgroup
half is reasoned by analogy from the Darwin case and has not been measured here —
verify before relying on it.)_

**Pinning is worse.** `CPU_SET(cpu % totalCPUs, &set)` distributes workers
round-robin over a CPU count the process may not be permitted to use; under a
restricted affinity mask that pins a worker to a CPU it can never run on. Sizing
over-provisions, pinning can hang a worker.

**Options:** (A) one `hwParallelism()` for sizing, leave pinning; (B) two
accessors — parallelism _and_ the allowed-CPU set — with pinning selecting within
the mask.

**Decided: (B), in a new `libs/base` module (`hw_caps.d`)** beside `term_caps.d`,
which is the stated precedent for "the single place that decision is made".
`libs/base` rather than `event-horizon` because `test-runner-impl` and `apps/ci`
ask the same question and get the same wrong answer. Surface: `hwParallelism()`
(allowed-CPU count clamped by quota) and `nthAllowedCpu(uint i)` (pinning), both
`@nogc nothrow`, **uncached** — both are called at worker start, never in a hot
path, so a syscall per call is free and a stale cache is a bug waiting to happen.
A mid-run affinity change is documented as not observed.

**No QoS parameter, and no portable name for one, yet.** Nothing assigns a QoS to
a worker today, so the argument would have exactly one caller passing exactly one
value. `concept.d` already states this repo's position on the pattern — optional
capabilities are deliberately left undefined until "generic code dispatches on
them", because defining them earlier "would leave them untested". The same
applies to domain vocabulary: name it when a second caller means something
different by it.
