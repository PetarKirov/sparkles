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

**Leaning:** (A) suffices for v1; deeper integration designed with the
window-system work after M8.

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

**Leaning:** (B) — the consumer's needs should shape it; the cancel-function
dispatch in M5 must simply not preclude additional park types.

## O21 — How far the `Allocator` parameters spread

**Where:** SPEC §4.2, §6.3, §13 (memory-management policy).

`BufferPool`, `OpSlab`, and `EventLoop` are generic over their allocator
(M8). Unplumbed: `SchedOptions` (the fiber slab stays GC by design, but a
future arena+`addRange` knob would enter here) and `LoopGroupConfig` (M9 —
per-worker allocators for thread-per-core NUMA locality are the interesting
case).

**Options:** (A) stop at the three current types until M9's `LoopGroupConfig`
forces the question; (B) plumb `Sched`/`LoopGroup` now.

**Leaning:** (A) — M9 decides with real per-worker requirements on the table.
