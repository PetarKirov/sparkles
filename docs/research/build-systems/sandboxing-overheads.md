# Sandboxing & Interception Overheads (Theme)

Every build system that discovers dependencies at run time must intercept
_something_ — a libc call, a syscall, a path lookup — and every mechanism pays a
tax that scales with the work the build does, not with the work the build system
does. This page separates the two products those mechanisms are usually asked to
deliver (isolation and observation), inventories the mechanisms the catalog's
systems actually use, and collects the overhead numbers their own authors
published. Where a number does not exist, the page says so: a sandbox that costs
1% on one platform and 21% on another is not described by one figure.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                       |
| ---------- | ------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                     |
| Question   | What does observing an action's file I/O cost, and what does it buy over a declaration?     |
| Mechanisms | interposition, `ptrace`+`seccomp`, FUSE, namespaces, Landlock/`seccomp` policy, eBPF        |
| Systems    | BuildXL, tup, Bazel (`linux-sandbox`, `sandboxfs`), Please, Pants, Buck2, Rattle/`fsatrace` |
| Vocabulary | [concepts] — this page does not redefine _scheduler_, _rebuilder_, _trace_ or _minimality_  |

## Overview

### What it solves

Two problems get one mechanism and should not. **Isolation** answers "may this
action do that?" and its output is a denial. **Observation** answers "what did
this action touch?" and its output is an edge set, which becomes the cache key or
the next build's graph. A system that only isolates still has to be told its
inputs; a system that observes can check, or replace, what it was told.
[concepts] §6 records that the JFP paper treats environment control as a cache-hit
remedy rather than a mechanism with a cost; this page is the treatment that
vocabulary deliberately omits. The value is concrete: BuildXL turns observation
into a cache key, so an under-declared legacy build (MSBuild, CMake, JavaScript
task graphs) still caches correctly and a read nobody declared becomes an error
rather than a stale artifact ([buildxl] §2), while tup turns observation into the
read set that decides staleness ([tup] §3).

### Design philosophy

The observing camp states the stake, the tracing camp states the risk:

> "BuildXL relies on runtime file-access monitoring for correct caching and
> distribution."
>
> — BuildXL [`CoreConcepts.md`][bxl-core]

> "The consequence of a tracing tool not reporting a file access would be failing
> to re-run a build command when the true dependencies change, or speculating a
> command when it shouldn't be."
>
> — Rattle §3.5, quoted in [perfect-dependencies]

Neither quote is about cost, and that asymmetry is why cost matters: a missed
access is silent, a spurious one merely slow.

## How it works — the mechanism families

| Family                | Intercepts                        | Sees                                                | Edges? |
| --------------------- | --------------------------------- | --------------------------------------------------- | ------ |
| libc interposition    | function calls in `libc`          | paths, flags, return values, `readdir`              | yes    |
| kernel-API hooking    | Win32 file APIs                   | the same, one layer up                              | yes    |
| `ptrace` + `seccomp`  | syscalls on a `seccomp` allowlist | syscall arguments and return values                 | yes    |
| FUSE                  | path lookups under a mount view   | every operation in the view                         | yes    |
| namespaces + remounts | nothing — visibility only         | nothing                                             | **no** |
| Landlock / `seccomp`  | nothing — permission only         | nothing                                             | **no** |
| eBPF                  | kernel-internal functions         | VFS/LSM calls, including paths with no libc wrapper | yes    |

The two rows marked **no** are the page's central distinction: **a policy
mechanism is not an observation mechanism**.

> "Landlock is purely restrictive: it can only deny what the traditional check
> would have allowed, never grant additional privileges."
>
> — Linux kernel, [`landlock.rst`][landlock]

A Landlock sandbox can therefore turn an undeclared read into `EACCES`, and that
is all: nothing hands the denied path back as a dependency. Fail-closed and
observe are orthogonal, and only one of them fixes a graph.

### 1. User-space interposition

The cheapest thing to build. On Windows, BuildXL runs the process suspended and
hooks Win32 file APIs with a hardened Detours fork; on Linux it interposes the
`libc` wrappers by `LD_PRELOAD` — the same device it documents as a limitation,
since it covers only "executables that are **dynamically linked** to `libc`"
([`Sandboxing.md`][bxl-sandboxing]). tup ships an `LD_PRELOAD` shim as the no-FUSE
fallback ([tup] §3), and Rattle's `fsatrace` does the same. Interposition sees what
a function-call boundary exposes — path, mode, return value (so a failed `open` is
an absent probe), directory enumeration — and nothing a process does without
calling `libc`.

### 2. `ptrace` behind a `seccomp` filter

Raw `ptrace` stops the tracee twice per syscall with a context switch each way.
BuildXL's variant is more careful than "strace attached to a process":

- **Dispatch is conditional.** On every `exec`, BuildXL asks `objdump` whether the
  binary statically links `libc`; only then is the `ptrace` sandbox used, "due the
  Linux function interpose based sandbox not being able to detect file accesses
  from binaries that statically link libc" ([`PTraceSandbox.md`][bxl-ptrace]).
  Dynamically linked binaries never pay the tracer, and a daemon spawns the tracer
  runner and `waitpid`s it, so no zombie accumulates.
- **`seccomp` selects what traps.** The child installs a BPF program returning
  `SECCOMP_RET_TRACE` for an allowlist of syscalls and `SECCOMP_RET_ALLOW`
  otherwise, so the tracer wakes on ~52 calls rather than all of them, with
  `PTRACE_O_TRACESECCOMP`, the three clone/fork options and `EXITKILL` set
  ([`PTraceSandbox.cpp`][bxl-ptrace-cpp]):

  ```c
  // Only the syscalls in here will be signalled to the main process by seccomp
  TRACE_SYSCALL(open), TRACE_SYSCALL(openat), TRACE_SYSCALL(stat),
  TRACE_SYSCALL(writev), TRACE_SYSCALL(renameat2), ...
  BPF_STMT(BPF_RET+BPF_K, SECCOMP_RET_ALLOW),
  ```

So `seccomp` is a **cost filter in front of `ptrace`**, not a security boundary
— worth remembering when the two are discussed as alternatives. The kernel
documents the coupling point, and its warning is this family's TOCTOU note:

> "The seccomp check will not be run again after the tracer is notified. (This
> means that seccomp-based sandboxes MUST NOT allow use of ptrace, even of other
> sandboxed processes, without extreme care; ptracers can use this mechanism to
> escape.)"
>
> — Linux kernel, [`seccomp_filter.rst`][seccomp]

### 3. FUSE

A FUSE filesystem answers every lookup, `open`, `create`, `unlink`, `rename` and
`mkdir` in userspace, so the filesystem call _is_ the event. tup mounts a view
under `.tup/mnt`, turns each operation into an access record, and stages writes to
a per-command temp name until the set is validated and renamed into place ([tup]
§2, [`fuse_fs.c`][tup-fuse]). Bazel's `sandboxfs` was the other end of the design
space: a reusable FUSE tree, reconfigurable at run time over a JSON stream,
presenting "an arbitrary view into the host's file system with different access
privileges per directory" ([`sandboxfs.1`][sandboxfs-man]). Its cost differs in
kind — one userspace round trip per operation, so the tax scales with the files an
action touches rather than with the number of actions. Bazel eventually priced
that and withdrew the mechanism ([Overhead](#overhead-as-published)).

### 4. Namespaces — isolation without observation

Bazel's `linux-sandbox` strategy is `clone(2)` with
`CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWIPC | CLONE_NEWPID`, plus `CLONE_NEWNET`
when network isolation is asked for and `CLONE_NEWUTS` for a fake hostname; PID 1
bind-mounts declared inputs and remounts everything read-only except the working
directory, writable outputs and tmpfs ([bazel] §2, [`linux-sandbox.cc`][bazel-lsb]).
Please does the same with a read-only root and a private `/tmp` ([please] §3). It
is cheap, needs no tracer, and buys nothing for the graph: an undeclared read
succeeds invisibly, so correctness rests on declarations. **Catalog inference.**

### 5. eBPF

BuildXL's newest Linux sandbox moves the hook into the kernel, for a gap
interposition structurally cannot close:

> "eBPF allows to trace very low level kernel-side functions, which reduces the
> list of functions to trace significantly. […] `io_uring` is a clear example of
> an API that is being increasingly used by tools for which there is no libc
> wrapper yet, and direct syscalls are being performed."
>
> — BuildXL [`Sandboxing.md`][bxl-sandboxing]

The mechanism is a set of `fentry`/`fexit` programs on VFS and LSM functions
(`security_file_open`, `security_path_rename`, `path_lookupat`, …), with
`ksyscall/execve` as a kprobe because "reading the filename and argv requires
reading user memory which cannot be done in fentry programs"
([`sandbox.bpf.c`][bxl-bpf]). Programs load once per build from a daemon and each
pip gets its own ring buffer, so per-access cost is a map lookup and a record, not
a process switch.

## Overhead, as published

Every number is the source's own, quoted rather than recomputed. _None_ means the
project published no figure for that mechanism.

| Mechanism             | System            | Published statement                                                                                                                | Source                                  |
| --------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| Win32 kernel/API hook | BuildXL           | "In terms of performance, this implementation adds 1-5% of time overhead to running a process."                                    | [`Sandboxing.md`][bxl-sandboxing]       |
| libc interposition    | Rattle            | Linux: "7% overhead, 5 points of it tracing"; Windows: "46%, 21 points the kernel hook and much of the rest path canonicalisation" | [perfect-dependencies] §5.2             |
| FUSE view             | Bazel `sandboxfs` | "setup costs are lower, but you have to pay a penalty for the use of each input"                                                   | [`CHANGELOG.md`][bazel-changelog] 7.0.0 |
| `ptrace` + `seccomp`  | BuildXL           | _none_ for the Linux path; the 1–5% row is Windows only                                                                            | [`PTraceSandbox.md`][bxl-ptrace]        |
| eBPF                  | BuildXL           | _none_; described as the eventual replacement for interposition                                                                    | [`Sandboxing.md`][bxl-sandboxing]       |

- **They measure different things.** BuildXL's 1–5% is per process on Windows
  against an unspecified workload; Rattle's 7%/46% is a fixed 9-command (Linux)
  and 25-command (Windows) list, averaged over the three fastest of five runs,
  against that platform's `make -j1` baseline.
- **The tracing component is separated where the author bothered.** Rattle's
  Windows total is 46%, but only 21 points are the kernel hook, and "Windows
  Defender alone raises the baseline by 11%".
- **FUSE's two cost curves are the interesting published claim.** `sandboxfs` made
  action _setup_ cheaper (no symlink forest) and per-access I/O more expensive —
  "further I/O within `execroot/` may be slower due to FUSE overhead" in Bazel's
  own pre-removal docs, which also promised it "without time penalties". Bazel
  removed it in 7.0.0 because it "was not consistently faster while being complex
  to set up", a judgement, not a measurement; the project is archived at
  `37033d0` ([`sandboxfs`][sandboxfs]).

## Correctness risks

### Missed accesses are silent

| Mechanism    | Documented blind spot                                                                                                | Result                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `LD_PRELOAD` | static and Go binaries bypass `libc`; `io_uring` has no wrapper ([bxl-sandboxing], [perfect-dependencies] §3.5)      | a missing edge, no error                              |
| Win32 hook   | "no 32-bit-parent/64-bit-child support; some antivirus products flag it" ([perfect-dependencies] §3.5)               | a missing edge or a killed build                      |
| `ptrace`     | the `seccomp` allowlist is the coverage boundary; no `read`/`pread64`, `openat2` or `statx` in it ([bxl-ptrace-cpp]) | catalog inference: a static binary using them escapes |
| FUSE         | paths outside the view; without namespacing, "some dependencies may be missed" ([`master_fork.c`][tup-fork])         | a missing edge, with a warning                        |
| namespaces   | nothing is reported at all                                                                                           | every undeclared read is invisible                    |
| Landlock     | deny-only, and files "opened before the sandboxing are not subject to these restrictions" ([landlock])               | a deny, or nothing                                    |
| eBPF         | hooks are kernel-internal and move between releases                                                                  | a missing edge on some kernels                        |

**No surveyed mechanism is complete** — Rattle documents the gap and ships a manual
override (`cmd … (Read ["hello.grpc"])`), BuildXL escalates interposition →
`ptrace` → eBPF, Bazel declines to observe, tup makes an undeclared read fatal.
Two further edge classes decide whether a trace is usable: BuildXL also records
`DirectoryEnumeration` and three probe kinds — `ExistingFileProbe`,
`ExistingDirectoryProbe`, `AbsentPathProbe` — because a compiler's include search
is a set of _negative_ facts ([`ObservedInput.cs`][bxl-obs], [buildxl] §2), while
Rattle records no directory _listing_, so adding a file does not invalidate a
command that listed the directory ([perfect-dependencies] §3.5).
**Catalog inference:** the same covers globs, and only tup models environment
variables, via `ACCESS_VAR` ([tup] §2).

### TOCTOU, snapshots and granularity

- **Observation and enforcement are not atomic in `seccomp`.** The filter is not
  re-run after the tracer is notified, so a `ptrace` sandbox that also permits
  `ptrace` can be escaped ([seccomp]); BuildXL narrows the window with fork/clone
  tracing and `EXITKILL`, not by re-checking.
- **A write to an input cannot be undone.** Rattle allows four responses to a
  hazard and admits one with no clean recovery: a speculative write to an input
  leaves the build broken "indefinitely" until a human intervenes
  ([perfect-dependencies] §4.3).
- **Read races are a first-class violation class.** BuildXL grades undeclared
  writes as `DoubleWrite`, `ReadRace`, `UndeclaredOrderedRead` and friends
  ([buildxl] §2): the race is detected in analysis, not prevented by the sandbox.
- **Catalog inference — the name/inode gap.** Every mechanism records the
  _pathname_ the process used, so a symlink retarget or bind mount means "read X"
  and "read Y's bytes" can both be true. BuildXL's three-level key is the repair:
  pathsets "list only pathname hits […] not actual file hashes" ([buildxl] §2).

### Kernel-version coupling

An in-kernel observer is only as stable as the functions it hooks. BuildXL's eBPF
source carries the maintenance cost in comments: "Before Linux 7.0, `step_into`
was the single funnel point for both fast and slow path component resolution.
Linux 7.0 inlined its fast path" — so one hook became two, and programs are
declared `SEC("?fexit/…")` to attach only where the target exists, with others
conditioned on `LINUX_KERNEL_VERSION` and BTF availability
([`sandbox.bpf.c`][bxl-bpf]). Landlock's version is milder: a versioned ABI probed
with `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`
([landlock]). **Catalog inference:** an edge set that depends on kernel
configuration makes build correctness a function of the host. Every observing
system also ships allowlists — BuildXL's `cacheableFileAccessAllowlist` caches
what `fileAccessAllowlist` merely ignores, and tup's only escape is the `^` flag
([buildxl] §5, [tup] §3) — which is where that argument leaks.

## Versus declared I/O

| Model                   | Cost paid                                   | Failure mode when wrong                | Systems                     |
| ----------------------- | ------------------------------------------- | -------------------------------------- | --------------------------- |
| Declare only            | developer precision; no per-access tax      | undeclared read caches stale, silently | Bazel, Buck2, Pants, Please |
| Observe only            | per-access tax; platform-specific mechanism | incomplete observation, silently       | Rattle (`fsatrace`), tup    |
| Hybrid: check both      | tax plus developer work                     | mismatch becomes a violation           | BuildXL                     |
| Policy only (deny list) | one-time ruleset, near-zero per access      | action fails, graph learns nothing     | Landlock/`seccomp` designs  |

The declare-only camp is not naive; it buys a different property. Bazel's sandbox
is not an oracle — nothing observes reads, so a command that opens an undeclared
file succeeds while the graph stays wrong ([bazel] §3) — a design statement, not a
bug report. Buck2 refuses to sandbox local actions at all: "Buck2 currently does
not sandbox _local-only_ build steps; in contrast, Buck2 using Remote Execution is
_always_ hermetic by design" ([buck2] §3). Please's sandbox is a write boundary —
read-only root, paths outside the repo still readable — and it records no read, so
an undeclared input leaves no evidence ([please] §3).

The trade is not "fast versus correct" but **who pays, and when**. Declaration
moves cost into the build file, where a mistake is a review comment, and into the
toolchain, which must emit `.d` files or scan includes; it keeps the graph static,
hence schedulable before work starts (the `Applicative` bargain of [concepts] §2).
Observation moves cost onto every access and every host and buys the edges nobody
wrote down; it makes the graph dynamic, hence restarting (Bazel) or suspending
(Nix, Shake). **Catalog inference:** mature systems converge on a hybrid, but
asymmetrically — observation validates declarations and feeds the key, while
declarations still gate scheduling.

## Strengths and weaknesses

- **Observation is the only mechanism that finds an under-declared input**, and it
  needs no cooperation from the toolchain — which the document-driven frontends
  (MSBuild, CMake, npm scripts) cannot give ([buildxl] §1).
- **The cost is real, uneven, and mostly unpublished.** One project publishes
  1–5%; one publishes a 5-point Linux and 21-point Windows tracing tax; both FUSE
  deployments publish no percentage, and one withdrew the mechanism.
- **A sandbox without observation cannot correct a graph**: it stops an action
  writing where it should not, and tells the engine nothing about what it read.
- **The mechanism is platform-shaped.** BuildXL's Linux story alone changed twice
  (interposition → `ptrace` for static binaries → eBPF), and each mechanism has a
  host prerequisite: a 64-bit parent, `PR_SET_PTRACER`, `fuse3`/`osxfuse` and a
  macOS `user_allow_other` tweak ([sandboxfs-man]), or an apparmor profile — which
  is why tup warns instead of failing ([tup-fork]).

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                        | Trade-off                                                        |
| --------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------- |
| Interpose `libc` rather than trace syscalls   | Cheap, sees paths and return values, no privileges               | Blind to static binaries and to syscalls with no wrapper         |
| Escalate to `ptrace` only for static binaries | Keeps the tracer off the hot path; `objdump` per `exec` is cheap | A second mechanism with its own allowlist                        |
| Filter `ptrace` with `seccomp`                | ~52 traps instead of one per syscall                             | The allowlist is the coverage boundary, and it drifts            |
| FUSE over a mount view                        | Every filesystem operation is an event; reusable across actions  | Per-access round trip; setup and portability; withdrawn by Bazel |
| Namespaces without a tracer                   | Near-zero setup, no kernel instrumentation                       | No edges at all; undeclared reads succeed silently               |
| eBPF for kernel-side hooks                    | Covers `io_uring` and any path the VFS/LSM sees                  | Kernel-version coupling, BTF dependence, no published overhead   |
| Keep the graph static, observe the key        | Scheduling stays computable up front; enforcement is an error    | Every legitimate new read is a build break someone must declare  |

## Sparkles relevance

`sparkles.build_primitives.task` has no sandbox, no declared inputs and no
persisted graph: a `TaskAction` runs through an action driver that knows nothing
about what the action touches
(`libs/build-primitives/src/sparkles/build_primitives/task/executor.d`).
That places the project in the declare-only column — with the declaration itself
still to come — and the corpus says that column is defensible for a
single-language toolchain: [buildxl] §7 already concludes a D toolchain cannot pay
a `ptrace` tax, and `dub`'s actions are compiler invocations whose depfile is
cheaper and more precise than any interception. Two things port, both cheap:

- **Model negativity.** If a task ever declares inputs, the declaration must say
  "this directory contains no matching files" — the absent-probe lesson without the
  syscall machinery.
- **Keep isolation and observation as separate vocabulary.** A future sandbox for
  untrusted actions is policy; it must not be described as making the graph more
  correct.

## Sources

In-corpus pages synthesized: [concepts] (§6 defers sandbox mechanism and cost
here), [buildxl] (sandbox-as-oracle, mechanism dispatch, the 1–5% figure,
observed-input taxonomy, violation classes, allowlists), [tup] (FUSE read set,
no-FUSE fallback), [bazel] (`linux-sandbox`, not-an-oracle reading), [please],
[pants] and [buck2] (declare-only postures), [perfect-dependencies] (tracing
survey, blind spots, published overhead table). Primary sources came from clones
under `$REPOS/build-systems-research/src/` at these SHAs:

- BuildXL `ea34998661867b5959d7f496f8b5650611a3e446`: [`Sandboxing.md`][bxl-sandboxing],
  [`PTraceSandbox.md`][bxl-ptrace], [`PTraceSandbox.cpp`][bxl-ptrace-cpp],
  [`ebpf/sandbox.bpf.c`][bxl-bpf], [`ObservedInput.cs`][bxl-obs], [`CoreConcepts.md`][bxl-core].
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`: [`CHANGELOG.md`][bazel-changelog],
  [`sandboxing.mdx` 7.6.1][bazel-sandbox-doc], [`linux-sandbox.cc`][bazel-lsb];
  `sandboxfs` `37033d0099adb247547f19535f01b3951116aaf0`: [`man/sandboxfs.1`][sandboxfs-man].
- tup `c6f565e216a0820e39d65fa84ddaf830be03a476`: [`fuse_fs.c`][tup-fuse],
  [`master_fork.c`][tup-fork]. Linux kernel docs: [`landlock.rst`][landlock] (ABI
  12, October 2026), [`seccomp_filter.rst`][seccomp].

<!-- References -->

[concepts]: ./concepts.md
[buildxl]: ./buildxl.md
[tup]: ./tup.md
[bazel]: ./bazel.md
[please]: ./please.md
[pants]: ./pants.md
[buck2]: ./buck2.md
[perfect-dependencies]: ./perfect-dependencies.md
[bxl-core]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/CoreConcepts.md
[bxl-sandboxing]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Specs/Sandboxing.md
[bxl-ptrace]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Wiki/LinuxDevelopment/PTraceSandbox.md
[bxl-ptrace-cpp]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Sandbox/Linux/PTraceSandbox.cpp
[bxl-bpf]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Sandbox/Linux/ebpf/sandbox.bpf.c
[bxl-obs]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Public/Src/Engine/Scheduler/Fingerprints/ObservedInput.cs
[bazel-changelog]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/CHANGELOG.md
[bazel-sandbox-doc]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/versions/7.6.1/docs/sandboxing.mdx
[bazel-lsb]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/tools/linux-sandbox.cc
[sandboxfs]: https://github.com/bazelbuild/sandboxfs/blob/37033d0099adb247547f19535f01b3951116aaf0/README.md
[sandboxfs-man]: https://github.com/bazelbuild/sandboxfs/blob/37033d0099adb247547f19535f01b3951116aaf0/man/sandboxfs.1
[tup-fuse]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/server/fuse_fs.c
[tup-fork]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/server/master_fork.c
[landlock]: https://docs.kernel.org/userspace-api/landlock.html
[seccomp]: https://docs.kernel.org/userspace-api/seccomp_filter.html
