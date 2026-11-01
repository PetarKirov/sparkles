---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Task DAG — Decisions

The owner accepted T1–T4 on 2026-11-01, in a design interview held to rework
the `apps/ci` task DAG. T5–T7 were settled while delivering M4–M6 and are
recorded in the SPEC.

## T1: Package edges are not ordering edges for tests

**Question.** Must a dependency's test succeed before a dependent's test
starts?

**Alternatives.**

- Hard `onSuccess` edges between tests: less wasted work when a dependency
  fails, but every dependency chain serializes.
- No ordering between tests: each test is authoritative for its own package.

**Choice.** No ordering between tests. A test waits only for the builds its
binary needs. Package edges remain selection data for the closures.

**Revisit when** a measured run shows that tests of failed dependencies waste
more than the serialization would cost.

## T2: One executor fiber owns the graph

**Choice.** One fiber owns admission, edge resolution and outcomes, while
actions run on any worker and report over cross-worker channels.

**Alternative.** Distributed admission from a shared structure. It makes the
"lowest presentation key wins" rule hard to keep, and admission is cheap next
to the work it admits. It may be revisited for very large graphs.

## T3: Interlaced output and provider groups in CI

**Question.** Buffered blocks are deterministic but hide a hung task's output
until the end. What should a CI log show?

**Choice.**

- CI workflows run `--interlaced`.
- The deterministic block transcript stays the local non-TTY default.
- A provider module adds collapsible groups, annotations and masks for the
  common CI services, and degrades to plain output elsewhere.

## T4: The generic layers live in `sparkles:build-primitives`

**Choice.**

- The model, graph, executor, process adapter, plain reporter, workspace
  selection and the CI-provider module live in `sparkles:build-primitives`.
- Commands, the CLI and the TTY reporter stay in `apps/ci`.

**Alternatives rejected.**

- Keeping the layers in `apps/ci` would make the build graph depend on an
  application.
- A new package for the layers would duplicate the dependency on Event Horizon
  that `sparkles:build-primitives` already plans for its filesets.

## T5: No backfilling past a capacity-blocked task

**Choice.** A ready task that waits for capacity stops admission of later
tasks. A task that waits only for an exclusive key does not.

## T6: An interrupted failure is a cancellation

**Choice.** A task the executor interrupted that then reports `Failed` is
recorded as `Cancelled(interrupted)`. The interrupt caused the failure, and
counting it would invent a second primary cause.

## T7: Events hold no pointers

**Choice.** Outcomes and event payloads name tasks by graph index, and an
output line travels beside the payload. A `SumType` holding a pointer is
`@system` to assign, and pointer-free events cross channels without borrowing.

## T8: The CI-provider module lives in `sparkles:base` (proposed)

**Question.** `sparkles:build-primitives`' unittest configuration depends on the
test runner, so the test runner cannot import a module of that package without
a dependency cycle. Yet the test runner is a natural second consumer: its
failures can become provider annotations.

**Alternatives.**

- Keep the module in `sparkles:build-primitives`, unused by the test runner.
- Put it in `sparkles:base`, which the test runner already includes through
  its cycle-safe integration.
- Create a new leaf package.

**Choice.** `sparkles:base`, as `sparkles.base.ci_provider`. Provider detection
and log syntax depend on nothing else.

## T9: An unneeded fallback is not a failure

**Choice.** A node behind an `onFailure` edge whose prerequisite succeeded is
`Blocked(conditionUnmet)`. It never fails the command, and summaries count it
apart from blocks caused by failures. Without this, every green coverage run
would report one blocked plain retry per package.
