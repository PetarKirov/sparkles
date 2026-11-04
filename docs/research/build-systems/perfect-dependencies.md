# Build Scripts with Perfect Dependencies (Rattle, Haskell)

Rattle inverts the usual contract: the user writes commands in a valid order and
declares no dependencies, and the engine recovers incrementality from what those
commands actually touched and parallelism from speculating on what the last run
did. The paper is the catalog's best account of what that costs — a tracer that
cannot see everything, a hazard model that decides when a guess was safe, and a
restart as the only recovery. Vocabulary is [concepts]'s; this page does not
redefine _scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_.

**Last reviewed:** November 2, 2026

| Field    | Value                                                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Authors  | Sarah Spall (Indiana University), Neil Mitchell (Facebook), Sam Tobin-Hochstadt (Indiana University)                           |
| Venue    | OOPSLA 2020 — PACMPL 4(OOPSLA), Article 169, 28 pp.                                                                            |
| DOI      | [10.1145/3428237][doi]                                                                                                         |
| License  | CC-BY 4.0 — "This work is licensed under a Creative Commons Attribution 4.0 International License." (p. 169:1)                 |
| Artifact | [`ndmitchell/rattle`][repo] at `3c935ca004ec8557ad6edb92d42f8bdf5bc78f46` (2023-10-15), version 0.2, BSD-3-Clause / Apache-2.0 |
| Category | Foundations — a _forward_ build system, not a cell in [a-la-carte]'s grid                                                      |

## Overview

### What it solves

A conventional build script names each rule's outputs and inputs, and both halves
of that declaration are routinely wrong:

> "Most build scripts have both too few dependencies (leading to incorrect build
> outputs) and too many dependencies (leading to excessive rebuilds and reduced
> parallelism)."
>
> — abstract

Too few is a correctness bug a local build hides — Vim's prototype file is the
paper's own example (§5.5). Too many is the `clean` step: work thrown away
because the declaration could not distinguish "this file changed" from "this
file's contents are the same". Rattle's answer is to stop declaring: dependencies
are _observed_, hence "always correct by construction" (abstract).

### Design philosophy

A shell script that runs the commands in a valid order is the reference
semantics; every optimisation must reproduce it (§2.1). Keeping that shape makes
the build system blind to the control logic that produced each command:

> "An important consequence of the control logic not being visible to the build
> system is that the build system has no prior knowledge of which commands are
> coming next, or if they have changed since it last executed them."
>
> — §2.2

Three consequences follow. Editing the script is safe by default, because the
engine never compares it against a cached plan — this "solves the problem of
self-tracking" left open by [a-la-carte]'s model (§2.2, citing JFP §6.5).
Anything worth caching must be a _command_, not host-language logic. And a wrong
guess about the future is a performance question, not a correctness one, which is
why the design centres on hazards.

## How it works

### A build script is a command stream

A script is a Haskell program in a `Run` monad; `cmd` hands one command to the
engine and blocks until it has run, been skipped, or been fetched (§3.1). Figure 2
is the whole of §2.2's `ls *.c | xargs gcc -c` plus a link:

```haskell
main = rattle $ do
    cs <- liftIO $ getDirectoryFiles "." [root </> "*.c"]
    forP cs $ \c ->
        cmd "gcc -c" c
    let toO x = takeBaseName x <.> "o"
    cmd "gcc -o main.exe" (map toO cs)
```

`forP` is explicit parallelism; `forM` would rely on speculation instead
(§2.7–§2.8). `cmdReadFile`/`cmdWriteFile` expose host-code file access to hazard
detection; all other Haskell is assumed to touch only files no command writes.

### Skipping: hash what was touched

Tracing reports the files a command read and wrote, and the engine records their
content hashes; a later run skips it when every recorded read and write still
hashes the same (§2.3–§2.4). Because the comparison is on content, a
whitespace-only edit that leaves the object file identical is free — the
`make clean` remedy disappears (§5.1). The price is an assumption stated rather
than hidden: each command must be a pure function from its reads to its writes.
§2.4 lists the four ways that fails — non-determinism, embedded entropy
(timestamps, GUIDs), a command that reads and writes the same file, and
simultaneous outside modification — each with a workaround (lift the entropy into
control logic, mark the command uncacheable, wrap LaTeX in one command that runs
it three times) and a residual risk. Granularity is the file: the engine cannot
tell which bytes mattered, so "never rebuilds too much" means at file level.

### Hazards

A build of individually well-behaved commands can still be wrong, and §2.6
reduces that to one situation:

> "Writing to a file after it has already been either read or written is the only
> circumstance in which a build, where every individual command is well-formed
> (as per §2.4), is incorrect."
>
> — §2.6

| Hazard                     | Definition (§4.1)                                                                                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Read-write**             | a file is written after it has been read; since tracing cannot timestamp an access, the requirement is stronger — the writer must have _finished_ before any reader started |
| **Write-write**            | more than one command in the build writes the same file                                                                                                                     |
| **Speculative-write-read** | a speculated command writes a file, a command in the build script then reads it, before the script requires the speculated command                                          |

The first two are script defects found _before_ the rebuild they would cause:
`echo 1 > foo.txt; echo 2 > foo.txt` is malformed although each command is fine,
and so is hashing a file into another and back (§2.6). The third exists only
because of speculation (§2.8).

### Speculation and forwarding

Speculation substitutes for a dependency graph: run commands likely to be needed
later, so the script finds them already done. §3.3 narrows the prediction to
three conditions — not yet run this build; required by the previous run; no
hazard against completed commands or against the _predicted_ accesses of running
ones. If a running command has never run before, nothing is speculated: "the
build system has changed in an unknown way so we take the cautious approach". A
hazard aborts the build and restarts it with speculation off, losing the
completed work (§3.3, §4.3).

_Forwarding_ is not in the paper but is the repository's answer to §2.5's
non-deterministic outputs: a command may declare outputs whose contents should
not be compared directly, and Rattle writes a `.rattle.hash` companion holding a
hash of the command plus its reads and deterministic writes, then tracks that
file instead ([`Hash.hs`][hash]). It makes a compiler's embedded timestamp or
GUID cacheable at all, and it depends on the trace being complete.

### Tracing mechanism

No portable API answers "which files did this process touch", so §3.5 surveys
each platform and states the loss up front:

> "The consequence of a tracing tool not reporting a file access would be failing
> to re-run a build command when the true dependencies change, or speculating a
> command when it shouldn't be."
>
> — §3.5

| Platform | Mechanism                                                                       | Known blind spot                                                                                          |
| -------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Linux    | `LD_PRELOAD` a shim over the C library (`fsatrace`), forwarding to the real one | statically linked or Go binaries bypass libc; coverage is the shim's function list (at least 28 on Linux) |
| macOS    | the same `LD_PRELOAD` approach                                                  | System Integrity Protection blocks tracing system binaries, including the system compiler                 |
| Windows  | kernel-API hook, so every process is subject to it                              | assembly trampolines; no 32-bit-parent/64-bit-child support; some antivirus products flag it              |

Across all platforms, subcommands are attributed to the parent (`gcc`'s `as`
invocation), files written and deleted before completion are ignored as
temporaries, and directory _listing_ is not recorded — adding a file does not
invalidate a command that listed the directory.

The paper's own failure case is `protoc`: a Go binary that reads `hello.proto`
and writes `js/hello.js`, invisible to the shim on Linux and macOS, so Rattle
silently fails to rebuild. The escape hatch is to declare the access by hand —
`cmd … (Read ["hello.grpc"]) (Write ["js/hello.js"])` — which reintroduces the
missing-dependency problem the system exists to remove. The wishlist is a
cross-platform API with interception during execution; the README points at
`bigbro` (`ptrace`) and an unfinished FUSE tracer instead.

### Storage

§3.4 keeps three kinds of state on disk, all shareable through a mounted
directory:

| Store              | Contents                                                                      | Repo location |
| ------------------ | ----------------------------------------------------------------------------- | ------------- |
| Command traces     | per command line: files read/written with content hashes; append-only history | `command/`    |
| Speculation traces | the commands the last run required — one list per build script                | `speculate/`  |
| File contents      | hash → bytes, so an output can be copied instead of computed                  | `files/`      |

There is no action-cache key beyond the command line and its hashes, no eviction
policy, and no server: "we can store these artefacts on a shared drive, and then
use tools such as NFS or Samba". Copying outputs in costs "approximately a 10%
performance cost" without copy-on-write, which §5.4 disables to compare fairly
with Make.

## Correctness, as argued

§4 fixes the semantics — sequential execution, deterministic commands, disjoint
reads and writes per command — and proves six claims semi-formally. They are the
paper's substitute for a dependency graph:

| Claim (§4.2)              | Statement                                                                | Why it matters                                      |
| ------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------- |
| 1 Completeness            | no hazards ⇒ every command reached a fixed point                         | the second run can skip everything                  |
| 2 Unchanging builds       | deterministic control logic + no hazards ⇒ fixed point                   | a no-op rebuild is guaranteed                       |
| 3 Reordered builds        | any hazard-free reordering yields the same terminal contents             | speculation may run commands out of order           |
| 4 Parallel commands       | any hazard-free interleaving is equivalent                               | explicit parallelism is sound                       |
| 5 Additional commands     | hazard-free speculation cannot change inputs or outputs                  | guessing cannot corrupt the result                  |
| 6 Preservation of hazards | a hazard in the script's commands survives reordering and extra commands | a hazard is a defect in the _script_, not the guess |

§4.3 enumerates recovery: restart without speculation (safe, and what the code
does), restart with _less_ speculation (safe because it terminates), raise the
hazard immediately when there was no speculation, and continue when only
speculated commands were affected. The one case with no clean recovery is a
speculative write to an _input_: restarting does not restore the bytes, so a
build can stay broken "indefinitely" until the user intervenes.

## Evaluation, as reported

§5.1–§5.2 measure Rattle on small controlled builds; §5.3–§5.7 replay real Make
projects commit by commit. Hardware differs: a 4-core i7-4790 with a rotating
disk for §5.1–§5.4, a 32-core Xeon E5-4620 with RAID for §5.5–§5.7.

`gcc` was patched to sleep one second, to make parallelism visible (§5.1):

| Scenario                   | Make 1 | Rattle 1 | Make 2 | Rattle 2 | Make 3 | Rattle 3 |
| -------------------------- | ------ | -------- | ------ | -------- | ------ | -------- |
| Initial build              | 3.35   | 3.28     | 2.18   | 3.28     | 2.20   | 3.36     |
| Nothing changed            | 0.00   | 0.00     | 0.00   | 0.00     | 0.00   | 0.00     |
| `main.c` whitespace change | 2.19   | 1.12     | 2.19   | 1.12     | 2.19   | 1.10     |
| `main.c` meaningful change | 2.19   | 2.16     | 2.23   | 2.21     | 2.19   | 2.22     |
| Both C files changed       | 3.28   | 3.29     | 2.22   | 2.20     | 2.19   | 2.20     |

The first build is the predicted loss: nothing to speculate with, so Rattle runs
serially while Make overlaps two compiles. The whitespace row is the win. Minus
the sleep, "Make and Rattle are quite evenly matched, typically within a few
milliseconds" (§5.1).

§5.2 runs a fixed command list — `fsatrace`'s own, 25 commands on Windows and 9
on Linux — with successively more machinery; times are the average of the three
fastest of five runs, and percentages are against that platform's Make baseline:

| Setup                           | Windows | %    | Δ    | Linux  | %    | Δ   |
| ------------------------------- | ------- | ---- | ---- | ------ | ---- | --- |
| 1. `make -j1`                   | 9.96 s  | 100% | —    | 1.19 s | 100% | —   |
| 2. Haskell `process`            | 10.26 s | 103% | +3%  | 1.18 s | 99%  | −1% |
| 3. Shake `cmd`                  | 10.58 s | 106% | +3%  | 1.17 s | 98%  | −1% |
| 4. Shake `cmd` + `fsatrace`     | 12.66 s | 127% | +21% | 1.23 s | 103% | +5% |
| 5. Shake `cmd` + `Traced`       | 13.06 s | 131% | +4%  | 1.23 s | 103% | +0% |
| 6. Rattle, no speculation/share | 14.43 s | 145% | +14% | 1.25 s | 105% | +2% |
| 7. Rattle + everything          | 14.53 s | 146% | +1%  | 1.27 s | 107% | +2% |

This is the only comparison against Shake, and it compares _plumbing_: rows 3–5
execute the same commands with no incrementality test at all. Linux totals 7%
overhead, 5 points of it tracing; Windows totals 46%, 21 points the kernel hook
and much of the rest path canonicalisation (Windows Defender alone raises the
baseline by 11%), which is why later benchmarks are Linux-only.

Real projects, Rattle scripted from the commands Make actually ran; no per-task
counts are reported, only wall-clock curves:

| Project  | Window, threads                  | As reported                                                                                                                                                                                                                                      |
| -------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| FSATrace | 100 commits, 12 interesting; 1–4 | first build "always > 1s for Rattle", Make "as low as 0.33s with 4 threads"; otherwise competitive. Commit 2 is slower at 4 threads than 1: a changed link command triggers a write-write hazard on `fsatrace.so` and a restart                  |
| Redis    | 1–4 threads (chart to 34)        | with the content store on, "about 10% slower"; with copying disabled, "very similarly to Make, despite properly checking external dependencies"                                                                                                  |
| Vim      | 35 commits; 1, 4, 32             | similar except commit 20, where Make rebuilt every object after an unchanged `osdef.h` and Rattle skipped them, and commit 29, where Rattle rebuilt on a prototype file Make did not track                                                       |
| tmux     | 39 commits; 1, 4, 32             | commits 11, 22, 23 changed the script, so speculation had nothing valid to guess from and each took "approximately as long as a full single-threaded build"; a write-write hazard occurred at all three                                          |
| Node.js  | 38 commits; 1, 4, 32             | from scratch both about 94 minutes at one thread; Make takes 24 minutes at 4 threads and 4.8 at 32, Rattle stays at 92–93. On the lightest commits Make bottoms out near 25 s against Rattle's 10 s, because Make always regenerates GYP outputs |

§5.8's summary is more useful than any row: mostly equivalent; the systematic
loss is the cold build at high parallelism; hazards are "relatively rare, but
when they do occur, they do impact the build time"; every Make project managed
dependencies differently (`gcc -MMD`, stamp files, a tracking layer built on
Make); and only Node.js rebuilds when the build file changes, via its
`FORCE_DO_CMD`/`do_cmd` machinery — Rattle's own skip, implemented on top of
Make and, in the authors' reading, not quite working.

## Limitations the authors state

- **Tracing is incomplete, and the gap is silent.** Static/Go binaries, macOS
  system binaries, directory listings and temporaries are outside the trace
  (§3.5); the failure is a missed rebuild, not an error.
- **Speculation can cost more than it saves.** A recoverable hazard discards
  completed work and restarts without speculation; tmux's script changes and
  FSATrace's commit 2 are the measured cases.
- **Recovery is narrow.** §4.3 allows four responses; the code restarts without
  speculation or rethrows a hazard it judges non-recoverable, and a speculative
  write to an input cannot be undone.
- **Scale is untested.** "only one project in the hours range. It is as yet
  unclear whether similar benefits could be achieved on larger code bases" (§7);
  the store keeps one speculation trace, which "would definitely not scale to
  more users" (§3.4).
- **Cloud hygiene is manual.** Machine-specific outputs, relative directories and
  non-determinism each need a workaround, and a disconnected non-deterministic
  build can poison a cache until a clean rebuild (§2.5).
- **No security model.** Traces must be written only by trusted users, and "We
  have not yet implemented any security restrictions" (§3.4).
- **No remote execution, only a design note.** Bazel's model sends the files a
  command needs, which Rattle cannot enumerate; BuildXL's guess-and-request model
  would fit, and speculative writes would then never touch the local disk (§6.2).
- **Commands must be deterministic.** §2.4 assumes it and §4 assumes it again;
  LaTeX is the named tool outside it.

Deletion is the sharpest paper/code mismatch. The paper only carves out files
written _and deleted_ before a command completes, discarded as temporaries
(§3.5). The repository generalises that into a rule for authors — "Don't delete
files that have been produced. Each command should make new files, not delete old
files" ([`Rattle.hs`][module-doc]) — and the implementation shows why: `fsaTrace`
records `FSADelete` as a **write** ([`Types.hs`][types]), so deleting an output
is a write-write hazard with the command that produced it. The paper does not
claim that deleting an _input_ is mishandled; a missing file fails the hash
comparison and forces a rebuild.

## The paper and the repository today

The clone is the artifact three years on, and the deltas are maintenance rather
than design. `CHANGES.txt` stops at 0.2 (2020-05-27); `rattle.cabal` tests with
GHC 9.2–9.6 and still says 0.2. The README's own status line is the honest one:

> `_{Fast, Correct, Simple, Unfinished} - Choose four._`
>
> — [`README.md`][readme]

| Aspect            | Paper (2020)                                                     | Repository at `3c935ca`                                                                                                          |
| ----------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Entry point       | `rattle :: Run a -> IO a` (Fig. 3)                               | `rattleRun :: RattleOptions -> Run a -> IO a` — options were not in the paper's API                                              |
| Hazard vocabulary | two hazards plus speculative-write-read, in prose                | `Hazard` has `ReadWriteHazard` and `WriteWriteHazard` constructors, each tagged `Recoverable`, `NonRecoverable` or `Restartable` |
| Recovery          | four strategies (§4.3)                                           | restart without speculation; a hazard judged unrecoverable is rethrown ([`Server.hs`][server])                                   |
| Speculation test  | three conditions (§3.3)                                          | five, adding "a worker is free" and "no conflict with earlier speculation" ([`Server.hs`][server])                               |
| Persistent state  | command traces, speculation trace, file contents                 | the same three plus a monotonic per-machine `run/` index ([`Shared.hs`][shared])                                                 |
| Cache topology    | shared directory over NFS/Samba                                  | `rattleFiles` path plus a `rattleShare` boolean; no network layer ([`Options.hs`][options])                                      |
| Non-determinism   | lift entropy into control logic, or mark uncacheable (§2.4–§2.5) | `HashNonDeterministic` + `.rattle.hash` forwarding ([`Hash.hs`][hash])                                                           |
| Tests             | examples in §5.9                                                 | `test/Test/{Simple,Trace}.hs` plus the FSATrace and Stack ports ([`test/Test.hs`][tests])                                        |

Two repository additions matter. The hazard disposition is not cosmetic:
`Recoverable` (a speculated read was invalidated) can be retried, `Restartable`
(a speculated write, or a reordered required pair) can be retried with
speculation dropped, and `NonRecoverable` (two required commands in script order)
is a bug no retry fixes; the speculative-write-read case is encoded as a
`ReadWriteHazard` whose writer was speculated. And the speculation predicate reads
the _predicted_ accesses of running commands, which is the only way to guess more
than one step ahead safely.

## Relation to à la carte

Rattle is the case [a-la-carte] says it cannot place: "forward build systems do
not naturally fit into the design space, lacking the features that a build
system requires" (§6.2). In [concepts]'s terms:

| Dimension       | Rattle                                                                                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Task model      | not `Tasks c k v`: no keys, no targets, no `fetch`. The unit is a `Cmd` (command line + options), streamed in the author's order                |
| Scheduler       | a fourth kind — a user-supplied total order, weakened at run time by speculation. No topological sort, no restart-on-missing-key, no suspension |
| Rebuilder       | constructive traces in spirit: the store holds output bytes and can supply them, but keyed on a command line rather than a target key           |
| Dependency list | the previous run's read/write sets. This is `track`, not `dependencies`, and it is the only dependency source                                   |
| Minimality      | no. Every command is considered each build, so "a rebuild scales with the size of the build" (§6.1), not with the affected subgraph             |
| Store           | content-addressed by SHA-256 plus per-command history; no eviction, no action key                                                               |

The minimality row is where Rattle and [pie] trade places: PIE makes rebuild cost
proportional to the affected subgraph, and its algorithm "cannot be applied to
Rattle" because there is no graph to walk (§6.1). Rattle buys a simpler
specification and pays a linear scan; at the measured scale the scan is not the
bottleneck, and the paper says it was never profiled as one.

## Analysis spine

### 1. Task model & scheduling

A command stream in the author's order, `forP` for declared parallelism,
speculation for the rest. `cmd` blocks, so the script _is_ the schedule. Two
structural limits: no target means no subtree build, and no key means a command's
identity is its command line, so a changed flag is a different, uncacheable
command.

### 2. Rebuilding & correctness

Per-command read/write sets with content hashes; skip iff all match; a trace is
written only after concurrent commands finish, so a hazard cannot be recorded as
clean ([`Server.hs`][server]). Correctness is argued against sequential
execution rather than against a `compute` function, and covers reordering and
speculation rather than composition with other engines. Early cutoff falls out of
hashing and is measured in §5.1 and §5.5.

### 3. Dependency discovery

Traced at the strongest granularity the catalog surveys: syscall-level
interposition, no declaration needed, none possible for the blind spots. This is
the cleanest statement of the trade — perfect dependencies when tracing works,
silently missing ones when it does not, and a manual `Read`/`Write` escape that
reintroduces Make's problem. [concepts] notes Fabricate as the one tracing system
à la carte cannot model; Rattle is that line of work with the hazards made
explicit.

### 4. Store & caching

A shared directory with three keyed stores and a hash→bytes map. Deduplication is
by content hash; no eviction, no size accounting, no protocol. Copying in is the
one measured cost (§3.4, §5.4). The store is also the trust boundary: a trace
fetched from another user is relied upon, which §3.4 calls safe only among
trusted users.

### 5. Hermeticity & provenance

No sandbox. Hermeticity is replaced by observation plus detection: the build does
not prevent an undeclared access, it records it and calls the result a
dependency. That gives up the guarantee a sandbox provides and gains the ability
to run commands that cannot be sandboxed, at the cost of the `protoc` class of
silent error. Provenance is absent; §3.4's integrity argument authenticates
bytes, not actions.

### 6. Distribution

Cache sharing over a mounted file system; remote execution is analysed and
rejected for Bazel's model, with BuildXL's file service named as compatible
(§6.2). The interesting claim is that remote execution would _remove_
speculative-write-read hazards, because speculative writes would land in a remote
sandbox rather than the local tree — an argument for combining Rattle's
speculation with an execution service, not for Rattle as a distributed system.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG — `TaskNode`,
`TaskEdge` with an `EdgeCondition`, `ResourceClaim`, `OutputPolicy` — plus a
multi-worker executor, and keeps no record of a previous run. Three borrowings
survive contact with Rattle's evidence.

1. **A trace is the minimum viable rebuilder, and it is small.** A command's
   identity plus the hashes of what it read and wrote is enough to skip it: a
   table, not a cache service, addable without touching the graph planner.
2. **The hazard set is a cheap lint for a static DAG.** Sparkles prevents
   _concurrent_ write-write conflicts for declared rewrites via
   `ResourceClaim.exclusiveKeys` (`workspace-write:<path>`), but cannot see a
   subprocess writing an unclaimed path, nor two sequential nodes writing one
   output. Rattle's checks are the same predicate over observed accesses, so a
   run's trace can validate the plan it was meant to follow.
3. **Speculation is the wrong first borrow.** Sparkles already has the graph, so
   it has the order; what it lacks is the content comparison that makes early
   cutoff possible and the record that makes a second run cheap.

Worth stealing outright is the disposition taxonomy: a conflict between two
required actions is a specification bug and should fail, while a conflict
involving a speculative action is a scheduling artefact and should retry.
`FailurePolicy` classifies outcomes, not conflicts, so neither it nor
`EdgeCondition` can express "retry: the clash was speculative".

## Strengths and weaknesses

- **The strongest dependency statement available.** When tracing works no
  declaration can be wrong, and the measurements show the ceiling: a whitespace
  edit costs one compile, not a cascade.
- **Hazards are a real contribution.** They turn "this build always rebuilds"
  into a diagnosable property, found before the rebuild, and they are what makes
  speculation worth doing.
- **Honest about cost.** Tracing overhead is measured on two platforms, the cold
  build loss is shown, and the one project in the hours range is flagged as the
  limit of the evidence.
- **A forward system does not compose.** No target means no subtree build and no
  reuse of the graph by another tool; the baseline is a shell script and the
  comparison is Make, not a graph-based engine.
- **Every guarantee is conditional on the tracer.** The failure mode is a missed
  rebuild — Make's failure mode — so the improvement is empirical rather than
  categorical. Linear rebuild, no eviction, no security and one machine keep it a
  research artifact.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                                     | Trade-off                                                                            |
| ------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| No declared dependencies; trace execution        | Dependencies cannot be wrong, and script edits need no invalidation           | A tracer blind spot is a silent missed rebuild; `protoc` needs manual `Read`/`Write` |
| Command stream as the task model                 | Keeps the shell script's simplicity; control logic stays in the host language | No target, no composition; rebuild cost is linear in build size                      |
| Hazards instead of a dependency graph            | Finds malformed scripts before the rebuild and makes reordering provably safe | Needs an interposer with enough coverage to see the writes                           |
| Speculation from the previous run                | Recovers parallelism without declarations                                     | One cold build per script change is serial; a hazard costs a full restart            |
| Restart-without-speculation as the only recovery | Simple, and provably equivalent to the sequential baseline                    | Discards completed work; a speculative write to an input is unrecoverable            |
| Content hashes, not mtimes                       | Early cutoff and touch-immunity (§5.1)                                        | Every command pays hashing                                                           |
| Shared directory, not a cache service            | NFS/Samba suffices for a research artifact; no protocol to build              | No eviction, no multi-tenant safety, no concurrency control beyond a lock            |

## Sources

- Spall, Mitchell & Tobin-Hochstadt, _Build Scripts with Perfect Dependencies_,
  OOPSLA 2020 — [DOI][doi]. Read in full from
  `$REPOS/papers/build-systems/spall-2020-build-scripts-perfect-dependencies-oopsla.pdf`
  (28 pp.) via `pdftotext -layout`; section and page numbers are the paper's. The
  PDF's typographic quotes and dashes extract as Latin-1 mojibake; quotations
  here reproduce the wording with ordinary punctuation.
- Rattle, clone at `$REPOS/build-systems-research/src/rattle`, commit
  `3c935ca004ec8557ad6edb92d42f8bdf5bc78f46` — [`README.md`][readme],
  [`CHANGES.txt`][changes], [`rattle.cabal`][cabal], [`Rattle.hs`][module-doc],
  [`Hazards.hs`][hazards], [`Server.hs`][server], [`Shared.hs`][shared],
  [`Types.hs`][types], [`Hash.hs`][hash], [`Options.hs`][options],
  [`Derived.hs`][derived], [`test/Test.hs`][tests]. The clone is shallow (one
  commit), so release history comes from `CHANGES.txt`, not `git log`.
- Named but **not opened**: Fabricate, Memoize, Fac, BigBro, Stroll, Pluto, PIE.
  Every statement about them here is this paper's.
- Sibling pages: [concepts] (vocabulary assumed here), [a-la-carte] (the design
  space Rattle does not fit), [pie] (the opposite traversal trade-off),
  [build-maintenance] (why dependency specification fails in practice), [index].
  Sparkles side, read for §7:
  `libs/build-primitives/src/sparkles/build_primitives/task/`.

<!-- References -->

[doi]: https://doi.org/10.1145/3428237
[repo]: https://github.com/ndmitchell/rattle/tree/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46
[readme]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/README.md
[changes]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/CHANGES.txt
[cabal]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/rattle.cabal
[module-doc]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle.hs
[hazards]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Hazards.hs
[server]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Server.hs
[shared]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Shared.hs
[types]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Types.hs
[hash]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Hash.hs
[options]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Options.hs
[derived]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Derived.hs
[tests]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/test/Test.hs
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[pie]: ./pie.md
[build-maintenance]: ./build-maintenance.md
[index]: ./index.md
