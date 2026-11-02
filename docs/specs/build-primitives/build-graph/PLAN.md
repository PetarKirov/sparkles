---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone is independently green, and
its gate names the oracles in [testing.md](./testing.md) it must pass._

The first consumer is `apps/ci`, whose `ci test` command moves onto the build
graph after E3 (see the [`apps/ci` commands plan](../../ci/task-dag/PLAN.md)).
Until then, every gate here runs through a test-only driver in this package,
not through a `ci` command. The executor that runs the actions is specified
in [the task DAG](../task-dag/SPEC.md).

## E0: Feasibility spikes and compiler support

Each spike states a question and a decision criterion. Its result is recorded
in [decisions.md](./decisions.md).

1. **Relocation.**
   - _Question:_ does LDC's prefix map, with root-relative sources, remove every
     absolute worktree path from objects, archives and test binaries,
     including `-cov` and `-checkaction=context` builds?
   - _Question:_ do the repository's 53 uses of `__FILE_FULL_PATH__` still work
     with the root mapped to `.` and test actions run in their worktree's root?
   - _Decision:_ any surviving path, or any use that cannot be fixed, puts the
     root path in the affected variants' keys.
2. **Complete dependency output.** Add to the LDC fork:
   - the ImportC headers in `--makedeps`;
   - an opt-in list of absent candidates;
   - coverage registration that honours the prefix map.

   Each comes with tests that fail without it. Bump the toolchain to the
   result.
   - _Decision:_ a gap the fork cannot close keeps BGK6's conservative key for
     the affected compiles.

3. **dub as a library.**
   - _Question:_ which resolved fields does `dub describe` not expose, and can
     the pinned dub be linked as a library to obtain them?
   - _Decision:_ the oracle's second source, or a recorded gap.
4. **Directive scan.** Scan every recipe in scope for directives and variable
   references, and complete BGR2's list.

Gate: each spike's result is recorded; the LDC fork's tests pass in the
toolchain the flake pins.

## E1a: The pinned test runner

- Build the test runner's implementation from a pinned revision of this
  repository, expose the library and its import directory through the flake,
  and link it from the shim (D16, BGT4).
- Replace every source include of the implementation with an ordinary
  dependency on the shim.

Gate: `ci --test` and every package's `dub test` pass with the pinned runner;
oracle 15's first scenario passes.

## E1: Recipe resolution and the oracle

- `dub_manifest` rejects unknown directives, reads registry packages'
  `dub.json`, and represents every form BGR2 lists.
- Resolved settings (§2) for every directive BGR2 lists, following dub's
  configuration steps (BGR3).
- Registry packages from both lockfiles, with Nix (BGR4), and `pkg-config`
  for compiles and links (BGR5). BGR4's fetch without Nix comes with the
  store, in E3.
- The hidden-edge report (BGR8), the repository's recipes fixed to declare
  their dependencies, and test-only reaches moved (D15).
- The dub agreement oracle over every package and request in scope, comparing
  unpruned settings: pruning, and with it D13's divergent-mode lint, is E2's.

Gate: oracle 1 has zero unaccepted disagreements, and oracle 13 passes: its
fixture is reported, and so are the cycle-safe packages' source includes of
the test runner until E1a removes them. `dub test :build-primitives` is
green.

## E2: Variants and the action graph

- Variant keys with pruned downward versions, and roles (BGV1–BGV3), with dedup
  across requests. D13's divergent mode gains its lint, which rejects a
  dependency whose sources test a version withheld from it, on the same
  source lexer.
- The unittest layout rule and its lint (BGV4–BGV5). The repository's remaining
  violations are fixed first, so the lint gates from its first commit.
- The action graph and its task-node exposure (BGA1–BGA3, BGA8), without
  execution.

Gate: a test-only planner prints a deterministic action graph for the
repository's test selection, with one compile per variant. Oracle 8's planning
scenarios and oracle 14 pass.

## E3: Local execution and the shared store

- Compile, archive, link and test actions on the task-DAG executor, with the
  explicit environment, relocation and argument normalization (BGA4–BGA7).
- Declared keys, manifests and result keys (§5).
- The shared store with staging, leases, eviction and inspection (§6).
- Registry sources without Nix: fetched by the lockfile's URL into the store
  and verified by its hash (BGR4).
- Typed generators, the test-root module and content-addressed generated
  sources (§7), with the shader compiler's direct invocation mode and its
  specification amended.
- Toolchain identity (§8).
- Test actions with declared runtime inputs, no reuse, and the test runner
  taking its import paths, string import paths, dflags, versions and probe
  directory as arguments, never calling dub (BGX1–BGX2). This includes making
  `sparkles.base.source_uri` work with root-relative `__FILE_FULL_PATH__`.

Gate:

- Oracles 2–5, 7, 9 and 10, steps 1–2 of oracle 11, and oracle 8's revert
  check pass through the test-only driver.
- A second run of the driver in another worktree, with no source change,
  compiles nothing.
- An edit to one `sparkles:base` module recompiles only the variants whose
  manifests contain it.

## E4: The Nix backend

- Content-addressed source inputs, and derivations created without evaluation
  (BGN1–BGN4).
- Remote builders from `/etc/nix/machines`.
- Sandboxed test actions whose results may be reused (BGX3).

Gate: oracles 6 and 12, and step 3 of oracle 11, pass for the repository's test
roots on x86_64-linux, with one remote builder of another system type.

## Progress

| Milestone | State       |
| --------- | ----------- |
| E0        | in progress |
| E1a       | not started |
| E1        | in progress |
| E2        | not started |
| E3        | not started |
| E4        | not started |
