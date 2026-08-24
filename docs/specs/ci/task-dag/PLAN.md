# `apps/ci` task DAG delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone is independently green: the
tool builds, its tests pass, existing repository invocations keep working, and
the milestone can be reviewed without relying on a later commit._

## Delivery rules

- Add the smallest module split needed by the current milestone. The target
  layout in SPEC section 13 is a destination, not permission for empty files.
- Full `sparkles.wired.sdl` and Event Horizon M19 are hard prerequisites for the
  production cutover. `apps/ci` does not carry a second process executor.
- Pure models and tests may land before those prerequisites, but canonical
  commands become executable only when their DAG path is complete.
- Switch one work family at a time without retaining flat-mode aliases or a
  fallback from the Event Horizon executor.
- Every graph/executor test uses stable task ids and deliberately scrambled
  completion order where ordering is under test.

## M0: Specification

- Add this specification and plan.
- Record all current work classes, canonical commands, removed mode mappings,
  selection algebra, graph models, cancellation, reporting, and isolation.
- Do not change the sidebar or implementation.

Gate: only `docs/specs/ci/task-dag/{SPEC,PLAN}.md` change; Markdown formatting is
clean; the two documents are internally consistent.

## M1: Pure task vocabulary and graph validation

- Add `task/model.d` with `TaskId`, `TaskNode`, `TaskEdge`, `ResourceClaim`,
  outcomes, and events.
- Add `task/graph.d` with a builder, duplicate/unknown-edge checks, cycle
  detection, stable presentation order, and edge-condition resolution helpers.
- Add an action vocabulary sufficient for inert test actions and dry-run
  rendering. Do not execute commands yet.
- Unit-test graph validation, stable topological order, conditional edges,
  blocked propagation, id formatting, and associative-array-order independence.

Gate: `dub test :ci` and `dub build :ci` pass; existing CLI behavior is
unchanged; pure graph tests import neither Event Horizon nor UI modules.

## M2: SDL-backed package graph and focused selectors

- Decode root and package `dub.sdl` files through the completed
  `sparkles.wired.sdl` backend; add package identities and configuration-aware
  in-tree dependency discovery.
- Implement exact/glob `--from` matching over short name, qualified name, and
  path.
- Implement `--since [REF]`, changed-path ownership, and the declarative global
  invalidator list.
- Implement dependency and dependent closure with fixed-point union semantics.
- Add selection reasons to the dry-run projection.
- Test union of `--from` and `--since`, deleted paths, root invalidators,
  both closures, empty matches, cycles, and platform-skipped seeds.

Gate: a test-only planner API can print deterministic selected package ids and
edges for fixture repositories; production commands still use the old executor.

## M3: Prerequisite integration gate

- Require the complete `sparkles.wired.sdl` backend and Event Horizon M19
  supervised-process surface in `apps/ci`'s dependency closure.
- Add integration probes for typed repository discovery, supervised line
  streaming, cancellation, process-tree teardown, resource events, and the
  scheduler-integrated blocking pool.
- Do not expose a partial canonical CLI or route production work through the old
  executor in this milestone.

Gate: prerequisite package tests pass on Linux, macOS, and Windows/Wine; the
probes leave no process behind and use no
`sparkles.core_cli.process_utils` execution path.

## M4: Event Horizon executor core

- Add the `sparkles:event-horizon` dependency and lockfile changes in a dedicated
  preparation commit.
- Implement weighted admission, exclusive keys, ready-queue tie-breaking,
  conditional edge resolution, outcomes, and event publication.
- Use one `LoopGroup`, root scope, bounded event channel, and fake typed actions.
- Implement structured fail-fast and external cancellation with protected
  cleanup for in-process fixture tasks.
- Add deterministic tests with a fake clock/action driver for capacity,
  starvation resistance, claims larger than capacity, simultaneous failures,
  blocked propagation, and no admission after cancellation.

Gate: executor tests pass under `TestSched` or the deterministic action driver;
there is no child-process integration yet; existing production work remains on
the old path.

## M5: Event Horizon subprocess actions

- Implement `task/process.d` as the CI adapter over Event Horizon M19's
  supervised-process API, without reimplementing line assembly or process
  lifecycle policy.
- Preserve argv boundaries and redact marked environment values in events and
  dry-runs.
- Implement bounded output memory with sandbox spill files.
- Route compiler thread caps and resource-usage observations through action
  metadata.
- Exercise exit, signal, timeout, large output, no-final-newline, descendant
  termination, cancellation races, and spawn failure.

Gate: real short-lived process integration tests leave no child behind and pass
under sanitizers where available; executor modules contain no `TaskPool`,
detached thread, sleep polling, or `std.process.execute` task path.

## M6: Reporter stack

- Add the reporter interface and shared ordered block buffer.
- Add `TaskReporter` TTY rendering with bounded tails and protected finish.
- Add deterministic non-TTY transitions, output blocks, failure replay, and
  summary.
- Add interlaced line-atomic prefixed output for TTY and non-TTY.
- Add degraded/skipped/blocked/cancelled visual and plain-text vocabulary.
- Snapshot-test plain output under many completion permutations. Test terminal
  capability degradation and interrupted live-region cleanup.

Gate: fake-action graphs are usable interactively and through a pipe; default
plain transcripts are identical across completion permutations; interlaced
tests assert line atomicity rather than cross-task order.

## M7: Canonical CLI and package build/test cutover

- Add `cli.d` with the core-cli nested command tree and common execution fields.
- Add `--jobs`, `--interlaced`, and `--dry-run`; add test-command-only
  `--from`, `--since`, `--dependencies`, and `--dependents`.
- Implement `ci test` mode validation for ordinary, `--build-only`, and
  `--special-modes betterc|wasm|all` modes.
- Implement `commands/test_.d` planners for build-only and ordinary tests.
- Create private run/task sandboxes, writable `DUB_HOME`s, and temp build roots.
- Add induced dependency edges and package eligibility outcomes.
- Preserve `$DC`, checked/debug build policy, empty child stdin, timeouts, and
  failure diagnostics.
- Switch package validation to the canonical command and remove the old flat
  package mode flags and loops in the same change.
- Delete only the superseded package build/test loops after parity tests pass.

Gate: `ci test --build-only --jobs 1`, `ci test --no-coverage --jobs 1`, and
their parallel forms are green; a stress test proves concurrent
tasks have disjoint writable locations; fail-fast kills a deliberately nested
child tree.

## M8: Coverage and special test modes

- Plan isolated coverage attempts, conditional plain retries, and package
  classification nodes.
- Implement deterministic listing merge, package ownership, atomic publication,
  and degraded no-coverage semantics.
- Ensure provisional coverage failure does not trigger fail-fast.
- Plan `--special-modes betterc|wasm|all` nodes from marker scans and
  test-runner integration, always requiring the toolchain.
- Remove the old extracted-test flag and loop.

Gate: ordinary tests pass with and without coverage; a fixture that fails only
under coverage is degraded and exits zero; a true fallback failure exits one;
parallel listings never share a destination; all three special-mode values and
core-cli value help are green.

## M9: Markdown and standalone example cutover

- Implement markdown extraction and per-example nodes shared by `docs run`,
  `docs verify`, and `docs update`.
- Preserve wildcard verification, ANSI/raw output, skipped directives, in-tree
  dependency rewriting, and normalized comparisons.
- Make updates whole-file, success-gated, exclusive, and atomic.
- Implement `ci docs examples` standalone run/build-only nodes, directive
  arguments, host platform skips, and file selection.
- Switch the canonical docs commands atomically, remove the old flat example
  flags/default mode, and delete `TaskPool` example execution.

Gate: README verification, a multi-file update fixture, standalone build-only
and run fixtures, timeout behavior, and parallel duplicate example names are
green. No `std.parallelism` import remains in `apps/ci`.

## M10: Documentation command cutover

- Plan and switch reference dedup reporting and fixing.
- Plan and switch VCS URL checks, sidebar consistency, local blob-path checks,
  and fence audit/JSON output.
- Preserve all file defaults, include/exclude semantics, source-position
  diagnostics, local-clone behavior, `srcExclude`, and audit scopes.
- Represent missing blob clone/revision evidence as degradation and a confirmed
  missing path as failure.
- Keep pure domain modules intact unless a move clearly reduces coupling.

Gate: every `ci docs` command has a parity fixture; mutating
commands make no writes under dry-run and use atomic writes otherwise; the
pre-commit hook invocations remain green without configuration changes.

## M11: Statistics and compact hook command

- Plan stats fetch pages, per-run job fetches, normalization, aggregation, and
  rendering as task nodes.
- Route blocking HTTP through an Event Horizon-owned CPU-job adapter until a
  native async client is available.
- Implement partial-population and optional-view degradations exactly as SPEC
  section 6.7 defines, including JSON `degradations[]`.
- Route commit-scope input/query/policy through the compact common reporter.
- Expose the canonical `ci stats` and `ci commit-scope` commands and remove the
  old flat mode flags.

Gate: complete, partial, empty-comparison, authentication-failure, and optional
metadata fixtures have the specified outcomes and exits; tokens are absent from
events/dry-runs; commit hook output remains concise.

## M12: Remove the legacy orchestration path

- Verify every production mode constructs a graph and uses the common executor.
- Remove superseded worker pools, serial mode loops, atomic polling slots,
  duplicate fail-fast code, and command-owned live regions.
- Keep reusable parsers, reducers, and render fragments.
- Audit imports to enforce the module firewall from SPEC section 13.
- Measure idle behavior, peak memory, weighted saturation, and output buffering.

Gate:

- `dub test :ci` and `dub build :ci -b checked` pass.
- Repository package tests, extracted tests, standalone examples, markdown
  verification, docs checks, and stats fixtures pass through the new executor.
- Forced cancellation leaves no child process or live-region control residue.
- Default non-TTY output is stable across a randomized completion stress run.
- `apps/ci` has no `std.parallelism` import and no task-execution polling loop.

## M13: Repository migration and documentation reconciliation

- Change workflows, hooks, and developer docs to canonical subcommands in the
  same cutover series.
- Reconcile `docs/specs/ci/stats/` terminology with `ci stats` and the common
  reporter without weakening its domain contract.
- Update this SPEC and PLAN for implementation discoveries before declaring the
  architecture complete.

Gate: full repository CI is green using canonical commands; executable scripts,
hooks, workflows, and user-facing documentation contain no old mode spellings.

## Milestone summary

| Milestone | Deliverable                      | Independently green gate              |
| --------- | -------------------------------- | ------------------------------------- |
| M0        | Normative SPEC and PLAN          | Documentation-only diff               |
| M1        | Models and graph validation      | Pure tests; no behavior change        |
| M2        | Package graph and selection      | Deterministic fixture plans           |
| M3        | Prerequisite integration gate    | SDL + EH M19 probes green             |
| M4        | Event Horizon executor core      | Deterministic fake-action tests       |
| M5        | Async subprocess adapter         | Kill/drain/reap integration tests     |
| M6        | TTY/plain/interlaced reporters   | Permutation and terminal tests        |
| M7        | Build and ordinary test cutover  | Isolated serial/parallel parity       |
| M8        | Coverage and special modes       | Fallback/degradation parity           |
| M9        | Markdown and standalone examples | Verification/update/run parity        |
| M10       | All docs commands                | Audit/rewrite/check parity            |
| M11       | Stats and commit hook            | Complete/degraded/error fixtures      |
| M12       | Legacy executor removal          | Full command matrix green             |
| M13       | Consumer migration               | Canonical-only repository invocations |
