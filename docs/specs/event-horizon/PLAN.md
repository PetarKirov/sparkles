# `sparkles:event-horizon` — Delivery plan

_Companion to [SPEC.md](./SPEC.md): the milestones that build the library to the
specification. Each milestone is independently green (builds + tests + lints).
Benchmarks start as a baseline in M3 and grow per milestone; M14 is where the
cross-runtime matrix and the results doc land._

## M1 — Specification

[SPEC.md](./SPEC.md) — the normative surface: the backend seam (§3), the op and
completion vocabulary (§4), the callback tier (§5), buffers (§6), the fiber tier
(§7), structured concurrency (§8), errors (§9), capabilities and effect rows
(§10), scheduler topologies (§11), the `Effect!T` veneer sketch (§12), and the
public API (§16). Spec examples that need not-yet-implemented modules are parked
with `<!-- md-example-skip -->` directives; the implementation milestones
unpark them and make them pass under `nix run .#ci -- --verify`.

Gate: `nix run .#ci -- --verify --files docs/specs/event-horizon/SPEC.md` and
`npm run docs:build` are green.

## M2 — Scaffold + ring substrate

Preparation commits first: add `during ~>0.5.0` to the relevant `dub.sdl` /
`dub.selections.json` / `nix/dub-lock.json`; then the `libs/event-horizon`
package (dub template from `libs/wired/dub.sdl`) with
`sparkles.event_horizon.backend.uring` wrapping `during`'s ring setup, and the
three-tier probe (backend selection → opcode probe → feature flags) surfaced as
a `BackendCaps` value (SPEC §3). On Linux without a working `io_uring`, setup
returns the hard probe error of SPEC §3 — there is no epoll path.

Gate: `dub test :event-horizon` green on Linux (probe + ring round-trip
unittests, `SKIP`-degrading on unsupported kernels).

## M3 — Callback completion core (tier A)

`loop.d` + `op.d` + `buffer.d`: the single-threaded `EventLoop` with the public
callback API — submit op + completion callback/context, in-ring timers
(`TIMEOUT`), per-op deadlines (`LINK_TIMEOUT`), op-level cancellation handles,
`run()`/`runOnce()`/`stop()`; `accept`/`connect`/`read`/`write`/`recv`/`send`
plus the datagram pair `sendTo`/`recvFrom` in callback style with owned-buffer
transfer (SPEC §5–§6). Callback-style echo-server example.

Gate: unittests + the callback echo example verified by
`nix run .#ci -- --verify`; first benchmark baseline recorded under
`libs/event-horizon/bench/`.

## M4 — Fiber scheduler + direct-style I/O (tier B)

`sched.d` + `io.d`: the fiber run queue over the callback core —
suspend/resume keyed by op slots, `spawn`, fiber pooling (`Fiber.reset`
recycling) — and the same I/O surface in direct style (SPEC §7). Direct-style
echo-server example (README-able). Base prerequisite: a `length` setter
(grow-with-default) on `SmallBuffer` in `sparkles:base`, used by the spec
overview example. (`handle.d` — the erased `LoopHandle` — is deferred to its
first consumer, the M12 veneer; tiers B/C hold the concrete loop.)

Gate: both echo styles green; fiber-vs-callback overhead measured in the bench.

## M5 — Structured concurrency + cancellation + errors

`scope_.d` + `cause.d` (no ring/loop imports): `Scope` spawn/join/fail
semantics, the cancellation tree + `protect`, deadlines as cancel scopes, the
`ASYNC_CANCEL` slot discipline (slot + buffer stay alive until the terminal
CQE), graceful shutdown (cancel accept → drain → unregister), and the
`Cause`/`IoResult` error model finalized (SPEC §8–§9). The callback tier keeps
its op-level cancellation from M3.

Gate: the cancellation/timeout/shutdown test matrix is green — axes: park type
(I/O / join / timer) × cancel source (explicit / deadline / sibling failure /
shutdown) × race outcome (cancel wins / completion wins, SPEC §8.5 provenance)
× `protect` (inside / outside).

## M6 — Effect capabilities + DI

`capability.d` + `clock.d` + `net.d` + `schedule.d` + `testing.d`: capability
structs and the effect-row convention (template introspection helpers, subset
projection), handler swapping, `TestClock`, `isNet`/`isByteStream` + `SimNet`,
the deterministic `TestSched` executor with `advanceAndSettle`, `Schedule`
(retry/backoff) values, and `retry`/`timeout`/`race` as ordinary functions over
fibers (SPEC §10).

Gate: a unit test exercising a nontrivial workflow entirely under
`TestClock`/`SimNet` — no real I/O.

## M7 — Files, subprocess, signals, watch

`fs.d` + `proc.d` + `signals.d` + `watch.d`: `OPENAT`/`READ`/`WRITE`/`STATX`/
`FSYNC` file capability; `Proc` (spawn, piped stdio, `WAITID` reap); signals
(`signalfd` driven through the ring); `Watch` (inotify fd driven through the
ring). Exposed at both tiers (callback + capability).

Gate: the agent-tooling demo (run a subprocess, stream its output, watch a
directory) as a verified example.

## M8 — Tier-3 single-ring throughput

Multishot accept/recv, provided buffer rings, registered files/buffers, and the
`DEFER_TASKRUN + SINGLE_ISSUER` operating mode (SPEC §3, §6). All of these are
guaranteed by the kernel ≥ 6.1 floor (SPEC §3.3) — there are no per-op runtime
fallbacks on Linux; instead, fault-injection tests fake probe/caps results to
exercise the gating plumbing itself (open-issues O5).

Gate: the benchmark suite shows the expected step-change; the probe/caps
fault-injection tests are green.

## M9 — Multi-thread topologies

`group.d` + `live.d`: (a) thread-per-core sharding (one ring per core,
`MSG_RING` handoff); (b) the work-stealing scheduler — per-worker rings,
stealing of never-started tasks only, idle workers parked via in-ring
`FUTEX_WAIT` so one wait observes CQEs and steal wakes, `FUTEX_WAKE`
signalling (SPEC §11); (c) the live capability row — `RingClock`/`RingNet` and
the `Env` alias handed out by `LoopGroup.run` (the milestone that unparks the
SPEC §1 overview example). Benchmark futex-wake vs `MSG_RING` vs eventfd;
measure thread-per-core vs work-stealing tail latency/throughput on the echo
bench.

Gate: all three topologies selectable via loop-group config (done — single +
thread-per-core via `LoopGroup.runEach` + work-stealing via `WorkStealingPool`);
the SPEC §1 example unparked and green under `--verify`; benchmarks committed.

## M10 — kqueue backend (macOS)

`backend/kqueue.d`: the completion-synthesizing proactor over kqueue readiness;
files via a small worker pool (regular files have no readiness); scheduler
parking via `os_sync_wait_on_address`; the same public API at both tiers.
Verified on `mac-bsn` (built via `ldc2` directly).

Gate met: the FULL EventLoop!KqueueBackend integration (tier-A loop + tier-B
fibers + accept/connect/recv/send verbs) verified green two ways — the data path
on real macOS (Darwin 25.3.0, scripts/verify-kqueue-macos.sh), and a complete
fiber TCP echo on Linux over mheily/libkqueue (scripts/verify-kqueue-linux.sh).
The loop-portability refactor (loop/sched/io/scope/live/group/pool → version(Posix),
DefaultBackend selection in backend/select.d) landed to enable it. Regular-file
worker pool + native EV_DELETE cancel remain as refinements.

## M11 — IOCP backend (Windows, Wine-tested)

`backend/iocp.d`: native completion mapping (`OVERLAPPED` ⇄ op slots);
scheduler parking via `WaitOnAddress`; the Win32 cross shell ported from the
window-system research branch (`win32-ldc2` + headless `wine64`), findings
labelled `A[wine]`; optional `windows-latest` CI job.

Gate: the echo example green under Wine.

## M12 — Monadic veneer (tier C)

`effect.d`: the `Effect!T` pipeline layer monomorphized onto the direct core
(SPEC §12), with parity tests (same behavior direct vs veneer) and a
microbenchmark bounding the veneer's overhead.

Gate: the parity suite is green; the overhead bound is documented.

## M13 — Showcases

1. HTTP/1.1 building blocks (parser + minimal handler API) as the new
   `sparkles:http` sub-package at `libs/http`.
2. `apps/terminal` ported onto the loop: PTY read, child reap, timers replace
   the per-frame non-blocking drain.

Gate: all examples verified.

## M14 — Cross-runtime benchmark suite

A `libs/event-horizon/bench/` harness (model: `libs/wired/bench/`; competitor
orchestration + RSS/CPU collection via `sparkles.core_cli.process_utils`)
comparing event-horizon — all three tiers, both topologies — against pinned
competitor implementations: D vibe.d, Rust Tokio, Rust Glommio, C++ Boost.Asio,
libuv (raw C), Node.js and Bun, and OCaml Eio, each via a reproducible Nix
devshell pin. Workloads: TCP echo (throughput + p50/p99/p999 tail latency,
few-large and many-small connections), HTTP/1.1 plaintext via `sparkles:http`
where the competitor has an equivalent, a file-I/O scan, and the internal
microbenchmarks (effect-op dispatch, fiber switch, callback vs fiber vs veneer
overhead).

The file-I/O phase additionally plugs into the local
[`polyglot-walks`](https://github.com/jfly/polyglot-walks) clone: an
event-horizon implementation of the recursive count-files/dirs walker
(work-stealing topology) registered as a walker via a `flake-module.nix`, so
`nix flake check` validates correctness against the fixture and
`nix run .#benchmark` races it under hyperfine against the
rayon/go/tokio/node implementations. Caveat recorded in the results doc:
`getdents` has no `io_uring` opcode, so the walk stresses the scheduler and
`OPENAT`/`STATX` more than pure ring I/O.

Gate: one command runs the matrix locally; the results + methodology doc
(research-docs style) is committed; event-horizon lands within its target
envelopes (≥ vibe.d throughput at lower tail latency; competitive with
Tokio/Glommio on echo).

## M15 — Async process management v2

The `proc` rebuild to SPEC §13, replacing the M7 sketch: the effects-side
vocabulary (`StdioMode`/`StdioSpec`/`ProcessConfig`/`ExitStatus`), full
per-stream stdio control with heap-staged argv/env (`spawnProcess` v2),
`kill`/`killGroup`, signaled-vs-exited status decoding, PTY spawning
(`spawnPty` via `POSIX_SPAWN_SETSID` + in-child slave open, `resizePty`),
and the capability layer — `isProc` (associated-`Child` shape), `RingProc`
joining `Env`, `SimProc` as the deterministic double. Portability
refinements ride the backend milestones: kqueue `EVFILT_PROC`/`NOTE_EXIT`
lowering for `OpWaitid`, IOCP wait-packet reap.

Gate: the `agent-tooling` example upgraded to v2 (stdin round-trip, stderr
capture, kill, signaled exit); `pty-drain` reaps in-ring via `spawnPty`;
a `SimProc` unit test drives an app-shaped "run, parse, decide" path with
no process.

## M16 — UI-loop substrate

The SPEC §5.6/§14/§15 primitives, in dependency order: the external
`Waker` (eventfd / `EVFILT_USER` / `PostQueuedCompletionStatus`; drain
accounting excludes the armed wake op; `destroy` disarms), `OpPollAdd`
(single + multishot; uring `POLL_ADD`, kqueue filter-only) with the
`waitReadable`/`waitWritable` verbs, `sleepUntil` + `Ticker`
(absolute-deadline frame clock, missed ticks skipped), `Channel!T`
(bounded intra-worker; park/wake through the executor seam;
close-then-drain semantics), and `Sched.tick` (the O7 embedding hatch).

Gate: unit tests for each primitive (cross-thread wake; poll on a pipe;
tick cadence + missed-tick skip under a deliberately slow consumer;
channel producer/consumer/close/cancel; tick-driven echo identical to
`run`-driven); the `io.steadyState.zeroAllocations` gate still green with
a waker armed.

## M17 — Owning the application loops

The SPEC §15.3 shapes delivered through the UI adapters, then the
applications:

1. `sparkles:ui-tui` gains the ring-driven input source (chunked stdin
   reads through a resumable escape assembler over `sparkles:tui`'s pure
   decoders; `SignalFd([SIGWINCH])` resize; events into a `Channel`).
2. `sparkles:ui-raylib` gains the `Ticker`-paced frame driver
   (`SetTargetFPS(0)`; sampled input per tick; the plain-loop fallback arm
   for loop-creation failure — Android seccomp).
3. `apps/hue`: the workspace TUI loop moves onto the input/UI-fiber shape;
   `GitStatusCache` re-shaped from a `std.parallelism` thread to a spawned
   `git status --porcelain` child (deleting the nested 150 ms wait); the
   resident oracles' non-blocking `tryReadLine` polling becomes parked
   pipe reads. Then the `--gui` frame loop onto the frame driver.
   (Done: the loops landed with M17; the git child rides `capture` behind
   a `GitStatusCache.asyncSpawn` driver seam gated on `OpWaitid`, and the
   oracles keep their `ResidentProcess` wire while daemon watcher fibers
   park `waitReadable` on their stdout and wake the loop through the event
   channel — a ~10 s tree-open oracle-active session measures 8 ring
   waits, no 33/150 ms wakeups.)
4. `apps/terminal` follows (the M13 port, now with its substrate in
   place): PTY master reads and the child reap park instead of the
   per-frame `EAGAIN` drain; the idle no-swap behavior is preserved.
   (Done. The loop landed via the `terminal-view` extraction — the idle
   gate's 99.7→0.3% is ring parking replacing busy-wait pacing — and the
   pty/reap half shipped as [`TVW8`](../ui-app/terminal-view.md) on the
   `HST15` host errands plus this library's `waitPid` raw-pid reap:
   parked master reads with a sync burst drain, in-ring reap, idle at
   zero pty syscalls, churn +1.4 pp recorded as the saturation cost.)

Coordinate with the [`sparkles:ui-app` plan](../ui-app/PLAN.md): the host
package's `tui_loop.d`/`gui_loop.d` arms are the natural final home of
these loops (`HST9`); the adapters land the machinery so either migration
order works.

Gate: hue TUI runs with **zero** polling timeouts on an idle document
(strace-verifiable: the loop makes one blocking ring wait, no 33/150 ms
tick wakeups); the `apps/terminal` render-CPU benchmark's idle scenario
stays at its near-zero baseline after the port.
