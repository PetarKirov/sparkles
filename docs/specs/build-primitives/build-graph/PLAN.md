---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone is independently green, and
its gate names the oracles in [testing.md](./testing.md) it must pass._

The first consumer is `apps/ci`. Its `ci test` command moves onto the build
graph directly after E3; see the [`apps/ci` task DAG plan](../../ci/task-dag/PLAN.md).
The task-DAG executor that runs the actions is specified in
[the task DAG](../task-dag/SPEC.md).

## E0: Feasibility spikes

Three spikes, each with a question and a decision criterion:

1. **Relocation.**
   - _Question:_ do LDC's `--ffile-prefix-map` and root-relative sources remove
     every absolute worktree path from objects, archives and test binaries,
     including `-cov` and `-checkaction=context` builds?
   - _Decision:_ if any path survives, BGA5's fallback (the root path in the
     key) applies to the affected variants, and the spike records which ones.
2. **Manifest.**
   - _Question:_ do `--makedeps` and `--deps` together list every file
     `strace` shows an LDC and a DMD compile reading?
   - _Decision:_ a gap that cannot be closed from compiler output makes the
     affected inputs declared inputs instead.
3. **dub as a library.**
   - _Question:_ which §2 fields does `dub describe` not expose, and can the
     pinned dub be linked as a library to obtain them?
   - _Decision:_ the oracle's second source, or a recorded gap.

Gate: each spike's result is recorded in [decisions.md](./decisions.md).

## E1: Recipe resolution and the oracle

- Resolved settings (§2) on top of `dub_manifest`'s typed recipes, for every
  directive BGR2 lists.
- Registry packages from the dub lockfile's store paths (BGR4) and `pkg-config`
  libraries (BGR5).
- The dub agreement oracle over every package and request in the repository.

Gate: oracle 1 has zero unaccepted disagreements. `dub test :build-primitives`
is green.

## E2: Variants and the action graph

- Variant keys and roles (BGV1–BGV3), with dedup across requests.
- The unittest layout rule and lint (BGV4–BGV5). The repository's remaining
  violations are fixed first, so the lint gates from its first commit.
- The action graph (BGA1–BGA3, BGA7) as task nodes, without execution.

Gate: a dry-run planner prints a deterministic action graph for `ci test`'s
selection, with one compile per variant. Oracle 8 passes.

## E3: Local execution and the shared cache

- Compile, archive, link and test actions on the task-DAG executor, with the
  explicit environment and relocatable invocation (BGA4–BGA6).
- Declared keys, input manifests and result keys (§5).
- The shared store with atomic publication, concurrency, size bound and
  inspection (§6).
- Typed generators for the shader compiler (§7).
- Toolchain identity for store and host toolchains (§8).
- Test actions without result reuse (BGX1–BGX2).

Gate:

- Oracles 2–5 and 7 pass.
- A second `ci test` run in another worktree, with no source change, compiles
  nothing.
- An edit to one `sparkles:base` module recompiles only the variants whose
  manifests contain it.

## E4: The Nix backend

- Content-addressed source inputs and derivations created without evaluation
  (BGN1–BGN4).
- Remote builders from `/etc/nix/machines`.
- Sandboxed test actions whose results may be reused (BGX2).

Gate: oracle 6 passes for the repository's test roots on x86_64-linux, with
one remote builder of another system type.

## Progress

| Milestone | State       |
| --------- | ----------- |
| E0        | not started |
| E1        | not started |
| E2        | not started |
| E3        | not started |
| E4        | not started |
