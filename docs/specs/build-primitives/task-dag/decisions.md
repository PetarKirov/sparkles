---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Task DAG — Decisions

The owner accepted T1–T4 and T8 on 2026-11-01, in a design interview held to
rework the `apps/ci` task DAG. T5–T7 and T9 were settled while delivering and
reviewing M4–M6, and are recorded in the SPEC. T10–T12 were settled while
fixing defects an external review found in the executor.

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
  selection live in `sparkles:build-primitives`. The CI-provider module has a
  package of its own (T8).
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

## T8: The CI-provider module is a leaf package (accepted)

**Question.** `sparkles:build-primitives`' unittest configuration depends on the
test runner, so the test runner cannot import a module of that package without
a dependency cycle. Yet the test runner is a natural second consumer: its
failures can become provider annotations.

**Alternatives.**

- Keep the module in `sparkles:build-primitives`, unused by the test runner.
- Put it in `sparkles:base`.
- Create a leaf package.

**Choice.** A leaf package, `sparkles:ci-provider`. It may depend on
`sparkles:base` only if it needs something there.

**Revisit when** `sparkles:base` needs provider conventions itself.

## T9: An unneeded fallback is not a failure (accepted)

**Choice.** A node behind an `onFailure` edge whose prerequisite succeeded is
`Blocked(conditionUnmet)`. It never fails the command, and summaries count it
apart from blocks caused by failures. Without this, every green coverage run
would report one blocked plain retry per package.

## T10: A task directory is its id, percent-escaped

**Question.** A task directory was the id's segments as directories, with the
`/`s inside a segment kept and `.`/`..` components replaced by `_`. Then
`docs:verify:a/b` and `docs:verify:a:b` shared a directory, and the second
spill truncated the first; and a `\` in a segment climbed out of the root on
Windows.

**Choice.** Each id segment is one directory. Within it, `/`, `\`, `%` and a
final `.` are percent-escaped (`%2F`, `%5C`, `%25`, `%2E`). The map is
injective, no component is empty, `.` or `..`, and an ordinary id reads as
itself. A path inside a segment no longer nests (`docs%2Fguide.md`).

**Revisit when** a case-insensitive file system hosts runs whose ids differ
only in case.

## T11: Each line of a multiline secret is masked

**Choice.** Output is masked after it is framed into lines, so a multiline
redacted value (a PEM key) never appears whole in one line. Each of its
non-empty lines, without a trailing `\r`, is masked too, after the whole
value: needles are tried longest first. Unrelated output that happens to
contain such a line is masked as well; masking too much is the safe error.

## T12: A task that cannot get a fiber fails to start

**Choice.** When the scheduler's fiber slab rejects a task's fiber, the task
is settled at once as `Failed(spawnFailed, ENOBUFS)` through the ordinary
completion path: its weight and keys are released, it can trigger fail-fast,
and the run ends. Left running, it held its claim forever and the run hung.

## T13: An unasked cancellation is a failure

**Question.** A `Cancelled` outcome adds no failure, because the cause that
cancelled the run controls the exit status. A driver can still report one
when nothing cancelled the run: the process driver maps
`ProcessEnd.cancelled` to `Cancelled(interrupted)` whatever ended the child,
and an in-process action may give up on its own. Its dependents then became
`Cancelled(notAdmitted)` and the command exited 0 over work that never
finished.

**Alternatives.**

- Keep the outcome and fail the command anyway, with no failing task to
  name.
- Record it as `Failed(contract)`.
- A new failure reason for it.

**Choice.** `Failed(contract)`, mirroring T6: the executor knows whether it
interrupted a task, or whether its own fiber was interrupted by an enclosing
shutdown, and a cancellation with neither is the action breaking its
contract. Dependents are then blocked by a failure, the task can be the
primary cause and trigger fail-fast, and reporters need no new reason.

**Revisit when** a driver needs to report a cancellation it initiated itself
for a reason the run should accept.
