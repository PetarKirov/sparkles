# Process Supervision in Event Loops

How completion-first and readiness-first runtimes spawn a child, own its output, its tree and its
exit, and how a supervisor stays honest when the OS refuses to cooperate — the survey behind
`sparkles:event-horizon`'s supervised runs ([SPEC §13.5–§13.8][spec-13]).

| Field    | Value                                                                                                                  |
| -------- | ---------------------------------------------------------------------------------------------------------------------- |
| Scope    | child creation, exit observation, output draining, tree containment, termination policy, resource accounting           |
| Systems  | libuv, Go, .NET, Java, Tokio, systemd, Erlang/OTP ports, Bazel, kqueue/`EVFILT_PROC`, Linux `pidfd`/`waitid`/cgroup v2 |
| Category | Concept / technique (cross-cutting over the [master catalog][index])                                                   |
| Feeds    | [SPEC §13][spec-13]; [PLAN M19][plan-m19]                                                                              |

**Last reviewed:** September 5, 2026

> [!NOTE]
> This is a technique survey, not a per-system deep-dive: each section names the systems that
> made a given choice and cites the mechanism, then states what `event-horizon` took from it.
> The deep-dives for the runtimes themselves ([libuv][libuv], [Tokio][tokio], [Go][go],
> [.NET][dotnet], [Java][java]) remain the source of truth for those systems.

---

## Overview

### What it solves

A supervised run is not "spawn and wait". Every runtime that grew a process API discovered the
same set of problems in the same order:

1. **A child that writes faster than you read deadlocks the wait.** A pipe buffer is finite; a
   child blocked in `write` never exits; a parent blocked in `waitpid` never reads. Every mature
   API drains both output pipes _concurrently_ with the wait.
2. **The exit is an event, the reap is a right.** A child's termination can be observed
   without consuming it (`waitid(WNOWAIT)`, `EVFILT_PROC`, `pidfd` readability) and must be
   consumed exactly once; a second consumer (`SIGCHLD=SIG_IGN`, a library that calls
   `wait(-1)`) steals it and turns every later pid-based operation into a hazard.
3. **A child is a tree.** Shells fork; build tools fork; daemons double-fork. Killing the root
   does not kill the tree, and a descendant that inherited the pipe holds EOF hostage.
4. **Blocking calls do not belong on the loop thread.** `waitpid`, cgroupfs waits, a `/proc`
   walk — anything the completion backend cannot express must go to a pool, and the pool must
   not be able to refuse the one job that ends a run.
5. **Accounting must say what it is the truth about.** Sampled peaks are lower bounds; kernel
   cumulative counters are exact only over an enforced boundary; a replacement process with a
   reused pid must never be folded as the original.

### Design philosophy — what the field agrees on

Across the systems below, four positions hold with remarkable consistency:

- **Concurrent drains, single reap.** Go's [`os/exec`][go-exec] copies each pipe in its own
  goroutine, and `Cmd.Wait` is documented to wait for the exit _and_ for the stdin/stdout/
  stderr copying to complete before releasing the command's resources; libuv's
  [`uv_process_t`][libuv-process] delivers the exit through the loop while the pipes are
  ordinary streams; Tokio's [`tokio::process`][tokio-process] documents that dropping a
  `Child` does not by default kill the process (`kill_on_drop` opts in) and that its stdio
  handles are independent `AsyncRead`/`AsyncWrite` objects.
- **Tree ownership is an OS capability, not a pid list.** .NET's [`Process.Kill(entireProcessTree:
true)`][dotnet-kill] walks descendants on Unix but uses a Job Object on Windows; Java's
  [`ProcessHandle.descendants()`][java-processhandle] is explicitly a snapshot; systemd puts
  every service in its own cgroup because a pid list cannot track a forking tree, and its
  [`KillMode=control-group`][systemd-kill] default signals the whole cgroup
  ([`cgroup.kill`][cgroup-v2]); Bazel's [sandboxing][bazel-sandbox] relies on a PID
  namespace so that killing the sandbox init kills everything.
- **Two-stage termination with a monotonic grace.** systemd's `KillMode`/`TimeoutStopSec`
  (`SIGTERM`, then `SIGKILL` after the timeout, to the whole cgroup), Go's
  [`Cmd.WaitDelay`][go-exec], .NET's `Kill` after `WaitForExit(timeout)`, Erlang's port
  `{exit_status, ...}` with `os:cmd` kill-on-timeout — the shape is always request, wait a
  bounded time, force.
- **Never poll the loop thread.** libuv routes blocking file and DNS work to its threadpool;
  Tokio has `spawn_blocking`; Go's `os` package observes a child's exit with
  `waitid(WNOWAIT)` (its `wait_waitid.go`) before the consuming `wait4`, so the observation
  never steals the reap right; Java's Loom parks virtual threads on a `ProcessHandle`
  completion rather than spinning.

---

## How it works — the mechanisms

### Observing exit without consuming it

| Mechanism                           | Platforms   | Consumes the status? | Used by                                                                   |
| ----------------------------------- | ----------- | -------------------- | ------------------------------------------------------------------------- |
| `waitid(P_PID, WEXITED \| WNOWAIT)` | POSIX       | No                   | Go ([`os.Process.Wait`][go-wait]), `event-horizon`'s root observer        |
| `IORING_OP_WAITID`                  | Linux ≥ 6.7 | Yes (or `WNOWAIT`)   | `event-horizon` (`OpWaitid`, [SPEC §13.2][spec-13])                       |
| `pidfd_open` + poll                 | Linux ≥ 5.3 | No                   | Tokio (`pidfd` reaper, [tokio][tokio]), systemd                           |
| `EVFILT_PROC` / `NOTE_EXIT`         | BSD, macOS  | No                   | libuv (kqueue), `event-horizon`'s kqueue lowering ([kqueue][kqueue-ptys]) |
| `SIGCHLD` + `waitpid(WNOHANG)`      | POSIX       | Yes                  | libuv (Unix), Node                                                        |
| Process handle wait → IOCP post     | Windows     | Yes (handle)         | libuv, .NET, [SPEC §13.9][spec-13]                                        |

The non-consuming observation is what makes **sample-before-reap** possible: `/proc/<pid>`
exists until the zombie is reaped, so the final resource sample must run while the observed
exit is still pinned. `event-horizon` orders it explicitly — observation, final sample, reap
([SPEC §13.8][spec-13]) — and treats a post-observation `ECHILD` as _lost to an external
reaper_ rather than as success or failure, because only `ECHILD` proves the right is gone.

### Draining and framing

Every system drains the two pipes concurrently; they differ in what they hand the caller.
Go returns whole buffers or lets the caller attach a `Scanner`; .NET's
[`OutputDataReceived`][dotnet-output] delivers _lines_ (with the known `null`-at-EOF sentinel);
libuv delivers raw chunks. `event-horizon` frames lines independently per stream
([SPEC §13.6][spec-13]) with a **payload-byte cap**: a line longer than the cap is emitted once
as a truncated head and the remainder discarded until the next terminator, so a hostile
child cannot make the supervisor's buffer grow without bound, and the framer stays linear
(the shipped one was quadratic on long lines — a scan restarted from the buffer's start on
every chunk).

### Tree containment: pgid, cgroup, job object, namespace

| Boundary      | Recursive?      | Escapable by the child?             | Kill primitive               | Systems                                      |
| ------------- | --------------- | ----------------------------------- | ---------------------------- | -------------------------------------------- |
| Process group | Yes (inherited) | Yes (`setsid`/`setpgid`)            | `kill(-pgid, sig)`           | every POSIX runtime; `event-horizon` belt    |
| cgroup v2     | Yes (inherited) | Only with write access to the tree  | `cgroup.kill` (Linux ≥ 5.14) | systemd, Docker, `event-horizon` tier B/A    |
| Job Object    | Yes (inherited) | Not once `KILL_ON_JOB_CLOSE` is set | `TerminateJobObject`         | .NET, libuv (Windows), [SPEC §13.9][spec-13] |
| PID namespace | Yes             | No                                  | kill the namespace init      | Bazel sandbox, bubblewrap                    |

The consensus is **belt and braces**: the process group is always there (cheap, portable,
escapable), and a stronger boundary is used where the host grants it. `event-horizon`'s
tiers ([SPEC §13.7][spec-13]) follow that exactly — `none` (pgid only), `owned`
(`cgroup.kill` + `cgroup.events` + `cgroup.procs`), `accounted` (controller-backed peaks) —
and issue **both** the pgid `SIGKILL` and `cgroup.kill` on every hard kill, because a
`populated 0` reading is authoritative only at its instant.

One consequence is easy to miss: a post-spawn `cgroup.procs` write is not containment by
construction. The kernel migrates the named process only, and a child that forked before the
write lands stays outside (its zombie parent, if it already exited, migrates as a silent
no-op). systemd avoids the race by having the service manager itself sit in the target cgroup
before it forks, and Linux ≥ 5.7 offers `clone3(CLONE_INTO_CGROUP)` so the child is born
inside. A `posix_spawn`-based library cannot use either without re-implementing spawn; it can
only issue the write inline the moment the spawn returns (microseconds against the hundreds a
fresh program needs to reach its first fork) and say so. `event-horizon` does, and names the
`clone3` path as the by-construction answer ([PLAN M19][plan-m19]).

### Termination policy and the residual tree

What happens to descendants that outlive the root is a _policy_, and the field offers three:

| Policy            | Semantics                                                                    | Prior art                                                        |
| ----------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Own the tree      | root exit + EOF ⇒ kill what remains; pipe-holders get a bounded output grace | systemd `KillMode=control-group`; Go `WaitDelay`                 |
| Wait for the tree | return only when the boundary reads empty                                    | systemd `KillMode=none` + `cgroup.events`; Bazel sandbox reaping |
| Detach            | never kill residuals; force the pipes closed after a window                  | Go `Cmd.WaitDelay` with a detached child; nohup-style daemons    |

`event-horizon`'s `ResidualPolicy { bounded, wait, detach }` is that table verbatim, with two
refinements the survey argued for: the grace under `bounded` is an **output** grace (a
daemon that cleanly closed stdio gets no lifetime grace, so `sh -c 'x & exit'` returns at
once), and `wait` is **cgroup-scoped by definition** — a descendant that left the cgroup while
staying in the pgid is neither waited for nor killed, and the policy degrades to `bounded`
with telemetry when the evidence is unavailable.

### Blocking work and the one job that must not be refused

libuv's threadpool, Tokio's `spawn_blocking`, and Java's `ForkJoinPool` are all _bounded_
pools with backpressure; none distinguishes a reap from an ordinary job. `event-horizon`'s
`BlockingPool` ([SPEC §13.8][spec-13]) adds a **termination-critical lane**: intrusive,
frame-resident admission (no queue slot to run out of), a reserved worker that takes nothing
else, and a fairness rule under which ordinary workers help the lane only while the public
queue is empty. Its guarantee is eventual FIFO service under finite jobs — which is why the
lane is used for `cgroup.kill` (one kernel write) and the `waitpid` fallback, and why the
cleanup's `populated` wait is deadline-bounded on the `cgroup.events` descriptor rather than
open-ended.

### Resource accounting that says what it means

Go's `ProcessState.SysUsage()` returns the child's own `rusage`; systemd's `systemd-cgtop`
reads cgroup counters; Bazel's `--experimental_collect_local_sandbox_action_metrics` reads
`cgroup` and `rusage`. None of them accounts a tree that mutates under a sampler. The
survey's position, adopted in [SPEC §13.8][spec-13]: every metric carries a **source** and a
**quality**; sampled peaks are lower bounds by construction; tree CPU is always a lower bound
while containment is unenforced; only the run cgroup's own cumulative counters are exact. Two
mechanisms make that honest under pid reuse:

- a **fail-closed root anchor** — `/proc/<pid>` held open from spawn to reap, its start time
  validated before _and after_ each scan, the whole sample discarded on a mismatch (a
  replacement root with fresh descendants satisfies every numeric test);
- a **bounded CPU ledger** — a live map with its own capacity, a scalar of retired
  contributions, a bounded retired-key set; disappearance (or a changed start time) retires an
  identity, omission never does, and once the retired set fills a later death becomes a
  zero-CPU tombstone in the same merge, so the total never jumps.

---

## Analysis spine

Applied uniformly to the systems this survey draws on:

| Dimension          | libuv                              | Go `os/exec`                   | .NET `Process`                   | Tokio `process`      | systemd                            | `event-horizon`                                             |
| ------------------ | ---------------------------------- | ------------------------------ | -------------------------------- | -------------------- | ---------------------------------- | ----------------------------------------------------------- |
| Exit observation   | `SIGCHLD` + `waitpid`; kqueue proc | `waitid(WNOWAIT)` then `wait4` | `SIGCHLD` reaper thread / handle | `SIGCHLD` or `pidfd` | `SIGCHLD` + cgroup notifications   | `IORING_OP_WAITID` (`WNOWAIT`), `EVFILT_PROC`               |
| Drain model        | streams on the loop                | goroutine per pipe             | thread per pipe, line events     | `AsyncRead` per pipe | journal capture                    | shielded drain fiber per pipe, framed on the supervisor     |
| Tree boundary      | pgid (opt-in), Job Object          | pgid via `SysProcAttr`         | pgid walk / Job Object           | pgid (opt-in)        | cgroup                             | pgid + cgroup v2 tiers                                      |
| Termination policy | caller's                           | `WaitDelay`                    | `Kill(entireProcessTree)`        | `kill_on_drop`       | TERM → timeout → KILL, cgroup-wide | `ResidualPolicy`, TERM+CONT → grace → KILL, both mechanisms |
| Blocking work      | threadpool                         | runtime threads                | thread pool                      | `spawn_blocking`     | n/a                                | `BlockingPool` + termination-critical lane                  |
| Accounting         | `uv_getrusage`                     | `rusage` of the child          | `TotalProcessorTime`, peak WS    | none                 | cgroup counters                    | sourced, qualified metrics; ledger; anchor                  |

---

## Strengths (of the consensus)

- The **observe-then-reap** split is available on every platform `event-horizon` targets and
  is what makes the final sample, the sample-before-reap rule and the "lost to an external
  reaper" diagnosis possible.
- **Belt-and-braces containment** degrades gracefully: a host without cgroup delegation still
  gets the process-group semantics every runtime has shipped for a decade.
- **Bounded two-stage termination** is universally understood by the programs being
  supervised (`SIGTERM` handlers are the convention) and by operators (systemd's timeouts).

## Weaknesses (of the consensus)

- **No runtime accounts the tree honestly.** They report the child's `rusage` or a snapshot
  and let a reader assume it is the whole story.
- **Post-spawn containment is racy** everywhere `posix_spawn` is the spawn primitive; only a
  spawn path that starts the child inside the boundary closes it.
- **Pools treat the reap like any job.** A saturated `spawn_blocking` can refuse the one call
  that ends a run; a dedicated lane is the missing piece.
- **`SIGCHLD` is process-global.** Any library that installs a handler or sets `SIG_IGN`
  breaks every other supervisor in the process; completion-based observation (`waitid` in
  the ring, `pidfd`, `EVFILT_PROC`) is the way out, and `event-horizon` uses nothing else.

---

## Key design decisions and trade-offs (as adopted)

| Decision                                                   | Rationale                                                                                      | Trade-off                                                                              |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Observe with `WNOWAIT`, reap at the terminal boundary only | the zombie pins pid and pgid identity for the whole run; no post-reap group signal exists      | a zombie lingers until streams are terminal and the tree is resolved                   |
| pgid + `cgroup.kill` on every hard kill, unconditionally   | a `populated 0` reading is authoritative only at its instant; kernel idempotence makes it safe | a trivial run pays one `kill(-pgid, SIGKILL)` against a group holding only the zombie  |
| Output grace, not lifetime grace, under `bounded`          | a daemon that closed stdio has nothing left to say; waiting idles the caller                   | a daemon that wanted to finish silently is killed at root exit + EOF                   |
| Inline `cgroup.procs` write, documented window             | microseconds against a fresh program's first fork; the only lever without a new spawn path     | not containment by construction until `clone3(CLONE_INTO_CGROUP)` lands                |
| Termination-critical pool lane with a reserved worker      | the reap and `cgroup.kill` must never be refused by a full public queue                        | one extra thread per process; eventual-FIFO, no numeric bound                          |
| Fail-closed root anchor + transactional samples            | a replacement root passes every numeric test; nothing may fold until both validations pass     | a run whose `/proc/<pid>` handle cannot be opened loses pid-based sampling entirely    |
| Bounded CPU ledger with tombstones                         | O(live members) per sample; no overcount under pid reuse or saturation                         | retired contributions are last-known values — lower bounds, never exact lifetime usage |
| Sourced, qualified metrics                                 | a consumer reads what a number is the truth about                                              | a wider result struct; "exact" is claimable only for the run cgroup's own counters     |

---

## Sources

- Go — [`exec.Cmd`][go-exec] (`Wait`, `WaitDelay`) and [`os.Process.Wait`][go-wait]; the
  `waitid(WNOWAIT)` observation lives in the `os` package's `wait_waitid.go`.
- libuv — [`uv_process_t`][libuv-process] (`uv_spawn`, `uv_process_kill`,
  `UV_PROCESS_DETACHED`), and the [libuv deep-dive][libuv].
- .NET — [`Process.Kill(Boolean)`][dotnet-kill] and [`OutputDataReceived`][dotnet-output];
  the [.NET deep-dive][dotnet].
- Java — [`ProcessHandle`][java-processhandle] (`descendants`, `onExit`); the
  [Java deep-dive][java].
- Tokio — [`tokio::process`][tokio-process] (`kill_on_drop`, the reaper); the
  [Tokio deep-dive][tokio].
- systemd — [`systemd.exec(5)`][systemd-exec] and [`systemd.kill(5)`][systemd-kill].
- Linux — [cgroup v2 documentation][cgroup-v2] (`cgroup.kill`, `cgroup.events`,
  `cgroup.procs`, the no-internal-process constraint), [`waitid(2)`][waitid],
  [`pidfd_open(2)`][pidfd], [`clone3` / `CLONE_INTO_CGROUP`][clone3].
- Bazel — [sandboxing][bazel-sandbox] (the PID-namespace sandbox and its init).
- kqueue — [`EVFILT_PROC`][kqueue-ptys] as surveyed for macOS.
- The design these fed: [SPEC §13][spec-13], [PLAN M19][plan-m19].

<!-- References -->

<!-- Siblings -->

[index]: ./index.md
[libuv]: ./libuv.md
[tokio]: ./tokio.md
[go]: ./go-netpoller.md
[dotnet]: ./dotnet.md
[java]: ./java.md
[kqueue-ptys]: ./kqueue-and-ptys.md

<!-- Sparkles -->

[spec-13]: ../../specs/event-horizon/SPEC.md#13-processes
[plan-m19]: ../../specs/event-horizon/PLAN.md#m19--cross-platform-supervised-processes-for-appsci

<!-- External -->

[go-exec]: https://pkg.go.dev/os/exec#Cmd
[go-wait]: https://pkg.go.dev/os#Process.Wait
[libuv-process]: https://docs.libuv.org/en/v1.x/process.html
[dotnet-kill]: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill
[dotnet-output]: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.outputdatareceived
[java-processhandle]: https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/ProcessHandle.html
[tokio-process]: https://docs.rs/tokio/latest/tokio/process/index.html
[systemd-exec]: https://man7.org/linux/man-pages/man5/systemd.exec.5.html
[systemd-kill]: https://man7.org/linux/man-pages/man5/systemd.kill.5.html
[cgroup-v2]: https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
[waitid]: https://man7.org/linux/man-pages/man2/waitid.2.html
[pidfd]: https://man7.org/linux/man-pages/man2/pidfd_open.2.html
[clone3]: https://man7.org/linux/man-pages/man2/clone.2.html
[bazel-sandbox]: https://bazel.build/docs/sandboxing
