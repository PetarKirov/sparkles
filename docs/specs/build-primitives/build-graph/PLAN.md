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

## E1a: The pinned test runner (superseded)

Superseded with D16 and BGT4 by the test runner's out-of-process model (TRD1,
TRD9 and TRM8 in `docs/specs/test-runner/`), which the test runner's own plan
delivers. Its aim stands: every source include of the runner's implementation
is replaced by an ordinary dependency on the shim, so BGR8 holds without an
exception.

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

Progress: strict reading, resolution, the registry and libraries are done, and
oracle 1 covers all 621 requests in scope, single-file packages included, with
zero unaccepted disagreements. The repository's recipes now declare their
`sparkles:math` dependencies, and the DQL test moved out of `ui`. What BGR8
still reports is the test runner's source includes, which the out-of-process
runner (TRD1) removes.
`ui-app` reads its specification through a link in the package (D24), and the
migration comparison snippets are out of scope (D25).

## E2: Variants and the action graph

- Variant keys with pruned downward versions, and roles (BGV1–BGV3), with dedup
  across requests. D13's divergent mode gains its lint, which rejects a
  dependency whose sources test a version withheld from it, on the same
  source lexer. Pruning scans string import roots and string literals, and
  lints `isVersion` arguments.
- The unittest layout rule and its lint (BGV4–BGV5). The repository's remaining
  violations are fixed first, so the lint gates from its first commit.
- The action graph and its task-node exposure (BGA1–BGA3, BGA8), without
  execution.
- Planning's read set (BGP1), checked against `ci`'s invalidators (CIC5).

Gate: a test-only planner prints a deterministic action graph for the
repository's test selection, with one compile per variant. Oracle 8's planning
scenarios, oracle 14 and oracle 20 pass.

## E3: Local execution and the shared store

- Compile, archive, link and test actions on the task-DAG executor, with the
  explicit environment, relocation and argument normalization (BGA4–BGA7),
  the publication rules for failed and interrupted actions (BGA9), and
  deterministic archives (BGA10).
- Declared keys, manifests and result keys (§5), with the execution-time
  hidden-edge check (BGK8) and the library search inputs (BGK9).
- The shared store (§6): staging, leases, eviction with digest records and
  separate bounds, format versions, inspection and repair, miss explanations
  and the determinism check (BGS1–BGS10).
- Registry sources without Nix: fetched by the lockfile's URL into the store
  and verified by its hash (BGR4).
- Typed generators, the test-root module and content-addressed generated
  sources (§7), with the shader compiler's direct invocation mode and its
  specification amended. The shader compiler is keyed by its manifest (BGG5)
  and built as a host variant (BGG6).
- Toolchain identity (§8), with the toolchain's store paths remapped (BGA11).
- **The LDC fork:** its dependency output reports, for each file, the content
  digest of the bytes the compiler read (BGK2), with tests that fail without
  it, and the toolchain is bumped to it. BGK7's check then compares those
  digests.
- **Isolation spike (D39):** Landlock write confinement and an unshared
  network namespace for local build actions, with the list of test actions
  that write into the tree and a decision for each. The result is recorded in
  D39 before E3's gate.
- Test actions with declared runtime inputs, no reuse, and the test runner
  taking its import paths, string import paths, dflags, versions and probe
  directory as arguments, never calling dub (BGX1–BGX2). This includes making
  `sparkles.base.source_uri` work with root-relative `__FILE_FULL_PATH__`.

Gate:

- Oracles 2–5, 7, 9, 10 and 16–19, steps 1–2 of oracle 11, oracle 13's
  execution-time scenario, and oracle 8's revert check pass through the
  test-only driver. Oracle 3 includes its write check.
- Oracle 21 passes over a replay of at least the last 50 commits of `main`
  and a seeded run of its edit sequences.
- Oracle 4's mid-compile scenarios (step 5) pass, before the store is shared
  by more than the test-only driver.
- A second run of the driver in another worktree, with no source change,
  compiles nothing.
- An edit to one `sparkles:base` module recompiles only the variants whose
  manifests contain it.

## E4: The Nix backend

- Content-addressed source inputs, and derivations created without evaluation
  (BGN1–BGN4), with BGN2's constrained narrowing.
- Diagnostics in outputs, garbage-collector roots, and infrastructure failures
  kept apart from action failures (BGN6–BGN8).
- Remote builders from `/etc/nix/machines`.
- Sandboxed test actions whose results may be reused, recording the machine
  they ran on (BGX3).
- Shared verdicts for reusable test results (BGX4).

Gate:

- Oracles 6, 12 and 22, and step 3 of oracle 11, pass for the repository's test
  roots on x86_64-linux, with one remote builder of another system type.
- **Measurements:** the per-derivation overhead with the sandbox on, the
  number of derivations, the bytes staged, and the edit loop's time against
  the local backend's are measured and recorded. They are D2's revisit
  measurement. Their definitions belong to the build-primitives observability
  specification (`docs/specs/build-primitives/observability/`), which this
  plan does not restate.

## Progress

| Milestone | State       |
| --------- | ----------- |
| E0        | in progress |
| E1a       | superseded  |
| E1        | in progress |
| E2        | not started |
| E3        | not started |
| E4        | not started |
