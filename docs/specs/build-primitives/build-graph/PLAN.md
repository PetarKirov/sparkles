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
2. **Complete dependency output:** moved to E3, where the input manifest
   (§5) first reads it.
3. **dub as a library.**
   - _Question:_ which resolved fields does `dub describe` not expose, and can
     the pinned dub be linked as a library to obtain them?
   - _Decision:_ the oracle's second source, or a recorded gap.
4. **Directive scan.** Scan every recipe in scope for directives and variable
   references, and complete BGR2's list.

Gate: each spike's result is recorded.

Done: spikes 1, 3 and 4 are recorded as D18–D21. The fork's dependency output
was never a spike. No milestone before E3 reads a compiler's dependency
output, so it moved to E3, beside the fork's content digests (BGK2).

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
fixture is reported, and the repository reports no hidden edge.
`dub test :build-primitives` is green.

Done: strict reading, resolution, the registry and libraries are delivered, and
oracle 1 covers all 631 requests in scope, single-file packages included, with
zero unaccepted disagreements. The repository's recipes now declare their
`sparkles:math` dependencies, the DQL test moved out of `ui`, and `ui`'s
tests no longer compile `dql`'s sources. The out-of-process runner (TRD1)
removed the test runner's source includes, and the counters' tests moved into
the harness, which depends on the counters, so BGR8 reports no hidden edge.
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
- **File access through the VFS (§12):** planning reads through the roots
  BGF2 names (BGF1–BGF3), and every listing is a fileset resolution (BGF5).
  The resolver's half is delivered: the fileset-native workspace's W1–W4
  moved discovery and resolution onto the capability VFS, with listings as
  shared fileset resolutions and digests in the read set
  ([fileset-native workspace](./fileset-native-workspace.md), D55). What
  remains is planning's own reads: the source scans of BGV1 and BGV5.

Gate: a test-only planner prints a deterministic action graph for the
repository's test selection, with one compile per variant. Oracle 8's planning
scenarios, oracle 14, oracle 20 and oracle 24's planning steps pass.

Done: variant keys, roles, pruning and dedup across requests are delivered
(`build_graph/variants.d`), with the `isVersion` and divergent-mode lints, on
`sparkles:d-source` (D56). Over this repository's 75 test roots, 1,053
targets plan to 167 variants, against 393 without pruning; the scan follows
imports (D57). The layout lint (`sparkles:unittest-layout`) gates planning
through a callback, after the repository's 190 in-tree violations were
fixed; findings in registry packages are reported (D58). The action graph
(`build_graph/actions.d`) lowers the variants to compile, archive, link, generate
and test actions, exposed as task nodes in OBD2's id form, with coverage
attempts and their plain fallbacks (CIC7). Planning reads through a tree
over BGF2's roots, records the links it crosses and its `pkg-config`
queries, and resolves libraries (D59).

The test-only planner is `apps/ci/tools/plan-graph.d`; `--check` runs the
gate over this repository's test selection: 168 variants (one a generator's
tool), 168 compiles and 488 actions. Oracle 8's planning scenarios, oracle 14's two scenarios,
oracle 20's three steps (a trace of about 196,000 lookups, 20 edits, and
2,372 reads against `ci`'s invalidators) and oracle 24's planning steps
(1–4) pass. What the gate leaves to E3: oracle 8's revert check, oracle 24's
store step, and a stored result serving both graphs of invariant 7.

## E3: Local execution and the shared store

- Compile, archive, link and test actions on the task-DAG executor, with the
  explicit environment, relocation and argument normalization (BGA4–BGA7),
  the publication rules for failed and interrupted actions (BGA9), and
  deterministic archives (BGA10).
- Declared keys, manifests and result keys (§5), with the execution-time
  hidden-edge check (BGK8) and the library search inputs (BGK9).
- The shared store (§6): staging, leases, eviction with digest records and
  separate bounds, format versions, inspection and repair, miss explanations
  and the determinism check (BGS1–BGS10), on the VFS beneath its own root
  (BGF4).
- Digest caching and stat proxies from the VFS's `Stat` (BGF6), after the
  VFS's identity amendment to VFO6 is delivered.
- Registry sources without Nix: fetched by the lockfile's URL into the store
  and verified by its hash (BGR4).
- Typed generators, the test-root module and content-addressed generated
  sources (§7), with the shader compiler's direct invocation mode and its
  specification amended. The shader compiler is keyed by its manifest (BGG5)
  and built as a host variant (BGG6).
- Toolchain identity (§8), with the toolchain's store paths remapped (BGA11).
- **The LDC fork:** its dependency output is completed, with each addition
  tested by a test that fails without it, and the toolchain is bumped to the
  result. The additions are:
  - the ImportC headers in `--makedeps`;
  - an opt-in list of absent candidates;
  - coverage registration that honours the prefix map;
  - for each file, the content digest of the bytes the compiler read (BGK2).

  BGK7's check then compares those digests. A gap the fork cannot close keeps
  BGK6's conservative key for the affected compiles.

- **Isolation spike (D39):** Landlock write confinement and an unshared
  network namespace for local build actions, with the list of test actions
  that write into the tree and a decision for each. The result is recorded in
  D39 before E3's gate.
- Test actions with declared runtime inputs, no reuse, and the test runner
  taking its import paths, string import paths, dflags, versions and probe
  directory as arguments, never calling dub (BGX1–BGX2). This includes making
  `sparkles.base.source_uri` work with root-relative `__FILE_FULL_PATH__`.

Gate:

- The LDC fork's tests pass in the toolchain the flake pins.
- Oracles 2–5, 7, 9, 10 and 16–19, steps 1–2 of oracle 11, oracle 13's
  execution-time scenario, oracle 8's revert check and oracle 24's store
  step pass through the test-only driver. Oracle 3 includes its write check.
- Oracle 21 passes over a replay of at least the last 50 commits of `main`
  and a seeded run of its edit sequences.
- Oracle 4's mid-compile scenarios (step 5) pass, before the store is shared
  by more than the test-only driver.
- A second run of the driver in another worktree, with no source change,
  compiles nothing.
- An edit to one `sparkles:base` module recompiles only the variants whose
  manifests contain it.

Progress, by the gate's items:

- **Execution:** `build_graph/execute.d` runs an action graph on the task-DAG
  executor with BGA4's complete environment (`TMPDIR` the action's own),
  its tools by absolute path, the root mapped to `.` (BGA5) and the
  compiler's own tree to `/ldc` (BGA11). A library's LDC compile writes its
  archive (`-lib`), byte-identical across run directories. Tests run in the
  root with the runner's arguments and never call dub (BGX1, oracle 11
  step 1).
- **Generators:** `dmd`'s `config.d` (D60) and the shader compiler (shader
  build SHP11) are typed generators built by the graph; the shader compiler
  is keyed on its import roots (BGG5).
- **The store** (`build_graph/store.d`): declared keys with consumed outputs by
  digest, manifests from the fork's dependency output (BGK2, `7bee3fbdeb`),
  conservative keys without it and for ImportC compiles (BGK6), library
  search keys (BGK9), reads outside the declared roots failing (BGK8), a
  digest cache (BGK5), publication by rename with leases and adoption of a
  winner (BGS2–BGS4), eviction with digest records (BGS5), verification,
  removal and inspection through `plan-graph --cache-op` (BGS6, BGS7), miss
  explanations (BGS8) and the determinism check (BGS9). The toolchain
  identity is the tools' store-path closure (BGT1, BGT2).
- **Registry sources without Nix** (BGR4): `plan-graph --fetch-sources`
  builds and tests from a fetched tree equal to Nix's.
- **Isolation (D39):** builds confined by Landlock and a network namespace
  at no measurable cost; the whole test selection's list is still to run.
- **Gate checks so far:** a second run in another worktree compiles nothing;
  an edit to one `sparkles:base` module recompiles exactly the compiles whose
  manifests list it; oracle 3 passes for `build-primitives` and `ui-app`
  (`--trace-compiles`); two concurrent producers of one graph both succeed,
  the loser adopting the winner's entries (oracle 7 step 1, one file system).

Next: a consumer served from a digest record alone, `ci cache`, `pkg-config`'s
absent candidates, and the remaining oracles over the whole test selection
(2, 4, 5, 7, 9, 10, 16–19, 21).

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
| E0        | done        |
| E1a       | superseded  |
| E1        | done        |
| E2        | done        |
| E3        | in progress |
| E4        | not started |
