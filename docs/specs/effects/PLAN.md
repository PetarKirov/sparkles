# `sparkles:effects` — Delivery plan

Companion to [SPEC.md](./SPEC.md). This is a specification delivery, not an
implementation. M0's bounded investigation is complete with its acceptance gate
unmet; M1–M7 remain unstarted. Each
milestone must be independently green and retain its gate evidence here; a site
build does not establish protocol or compiler correctness.

## M0 — Purity and protocol feasibility {#m0-purity-and-protocol-feasibility}

**Investigated; gate not passed.** [M0 evidence](./m0.md) records 80 successful
compiler/runtime checks, both live-supervision attribute checks, generated-code
inspection and five protocol walkthroughs. No optimizer failure was observed in
the tested weak-purity bridge. The general semantic justification remains
unproved, and live supervision fails the required attribute checks. The
proposed pure request/data boundary awaits user acceptance. M1/M2 are independent;
M3 onward remain gated.

Before building around the direct-style `pure` API, establish whether its single
journaling bridge is sound under supported D compiler semantics. This milestone
is an implementation prerequisite, not permission to implement during the
original specification task. The user subsequently authorized M0's experiments.

The bounded experiment must test a mutable, opaque row with a handler reached
only inside the bridge. Test both LDC and DMD in debug and checked builds, with
inlining enabled, repeated identical calls, discarded results, row aliasing,
fresh per-episode input, mutable hidden delegate context and exception/control
propagation. Inspect generated code around actual handler invocation. Include
negative compilation cases for ambient clock/I/O, escaping a raw handler and
serializing live resources. Verify that debug-only impurity cannot be presented
as an enforced replay guarantee.

Gate: record compiler versions, commands, outcomes and a language-semantics
argument covering observable external effects. A cast that compiles or survives
one optimization pass does not pass the gate. A negative result blocks the pure
API; propose and obtain acceptance for a revised boundary (for example an
explicit description/interpreter interface) before implementing durability.
Extraction and supervision do not depend on this result.

Also walk manually derived histories for a crash after external mutation, a
lost append acknowledgement, a cancelled wait, compensation failure and fork
publication. Gate: each has exactly one permitted next transition or an explicit
pause, and no hidden retry authority. Covers EFF1, EFF6, EFF13–EFF16, EFF34.

## M1 — Extract the existing effects substrate

Move exactly the eleven modules listed in SPEC §2, add `libs/effects/dub.sdl`,
register the root package and update dependency locks. Preserve old imports as
re-export shims and type identity. Audit every cross-package `package` symbol,
including executor-visible context and cancellation helpers. Add a transitive
import guard; a grep of direct imports alone does not prove the dependency
boundary. Update event-horizon's spec/module map and the repository package
catalog when the package actually exists.

Gate: `dub build :effects`, `dub test :effects` and `dub test :event-horizon`
pass in the supported toolchains; a standalone consumer builds against effects
without `during` or event-horizon. Old and new imports can be used in the same
program without duplicate types. Existing capability, scope, schedule and
channel examples pass unchanged. Covers EFF2–EFF3.

## M2 — Supervision through `isProc`

Add the required supervised-call expression to `isProc`, the forwarding method
to `RingProc`, and a scripted `SimProc` implementation. Keep the free function
as the implementation/compatibility seam. Extend scripts to exact argv, config
and stdin, ordered stdout/stderr/sample/exit events, virtual delays, failures,
truncation and invocation accounting. Publish the third-party concept migration.

Gate: run one application policy over both a scripted handler and live local
processes; compare result and event contracts, including borrowed-line lifetime,
spawn failure, timeout, cancellation, output caps and lost reap ownership.
Existing supervision tests remain green. Unscripted calls must fail. Prove the
double imports no scheduler or process-spawn implementation. Covers EFF4.

## M3 — Values, schemas and in-memory journal

After M0 accepts the program boundary, implement model, bounded codecs, the
registry and `isJournalStore`, plus `MemoryJournal`. Add hand-authored wire
vectors with fixed expected bytes; do not generate all expected bytes with the
encoder under test. Model durable and volatile state separately and inject
lost acknowledgements and competing claims.

Gate: independent vectors, malformed headers/lengths/tags, semantic-reference
errors, unknown versions, transaction-ID conflict, stale epoch, atomic batch
failure, ownership lifetime and limit tests pass. Every EFF11/EFF12 field and
enum has a vector or rejection case. Crash inside a frame must expose neither
half a result/registration nor half a wait acceptance. Covers EFF5,
EFF11–EFF12, EFF17–EFF18, EFF30–EFF31.

## M4 — Sequential durable runner and recovery

Implement the one journaling combinator, strict named/order matching, attempts,
retry deadlines, latched control outcomes and the program entry. Add decision
checkpoints, terminal comparison, pinned manifests, read-only candidate replay
and audited code adoption. Implement each recovery class with domain-neutral
scripted-world examples: a repeatable transformation, a deduplicated write and
a mutation requiring reconciliation.

Gate: crash at every logical record boundary and every effect/commit seam;
compare normalized histories, program outputs and the independent world's
invariants. Mutate the world between crash and resume. Verify completed effects
never rerun, ambiguous effects pause, argument drift cannot create a new effect,
ignored stop results cannot resume I/O, and read-only validation never executes
a live handler. Include a silent internal-change counterexample documenting
what checkpoints do not cover. Covers EFF7–EFF10, EFF13–EFF16, EFF32–EFF34.

## M5 — Durable scopes, waits and operator recovery

Implement persisted scope membership, atomic compensation registration and the
explicit LIFO sweep. Add durable waits, input deduplication, deadline arbitration
and host wake descriptors. Implement projection, the audited command surface,
cancel/terminate distinction, operator resolution and fork creation with
replacement inputs and immutable ancestry.

Gate: crash during every compensation and fork publication phase; restart with
a new registry instance so no old closure survives. Repeated compensation must
not undo itself or pass a failed entry. Cover late and duplicate input, deadline
ties, wrong schema, cancellation during replay/live/wait, stale command offset,
duplicate command ID with changed args, terminated runs, unknown handlers,
inherited compensation exclusion and deleted parent files after fork creation.
Rebuild each projection from scratch and compare its offset and state. A host
restart must discover expired waits without receiving a new wake notification.
Covers EFF20–EFF29 and remaining EFF32–EFF34 cases.

## M6 — Persistent local adapter and host integration

Implement `event_horizon.durable_file` with the process-lifetime kernel lock,
durable epochs, frame flushes, directory barriers and bounded recovery. Use
event-horizon's blocking seam where needed. Connect the runner to
`Topology.single`; the durable library must still build without the host.

Gate: a fresh process recovers after kills at instrumented write/flush/rename
boundaries. Test two independently spawned writers, short writes, disk full,
corrupt complete frames, incomplete final frames, lost acknowledgements and
claim reacquisition. Observe that rejected stale journal writes do not imply
the old process stopped touching the world. Run a host process with a long wait,
kill it, deliver input through a fresh owner and resume. Record filesystem and
kernel configuration. Process-kill evidence alone does not establish power-loss
durability. Covers EFF17–EFF19, EFF23–EFF26, EFF30, EFF34.

## M7 — First consumer and migration

Adapt `apps/release` only after the generic tests and two domain-neutral examples
pass. Write the consumer mapping in the release spec, keeping git/forge identity
and reconciliation rules out of effects. The existing stage flag remains a
requested stopping point; it is not evidence that an earlier effect happened.
Agent output, plan decisions, notes and human replies become recorded values;
tags, pushes, publication and app-store operations declare their own recovery
and conditional-write policies. A changed tag or remote reference must not be
treated as success merely because the name exists.

Replace the four recovery conventions with one run journal through an explicit
migration. Saved plans and app-store manifests remain importable only where
their evidence identifies completed work; missing outcomes become explicit
uncertainty, never invented completed results. Retire the old resume paths only
after parity and migration tests pass. Decide reconfirmation at application
boundaries and bind approvals to the intended release content. Preserve
existing artifact/progress presentation through the projection.

Gate: use a local repository and fake forge/app-store/agent handlers to crash at
every publication boundary, then mutate tags, notes, remote state and approvals.
Demonstrate that expensive completed agent steps do not rerun, uncertain
publication does not duplicate silently, and the old artifacts can be imported
without assuming that the world still matches them. A real-host smoke test must
use disposable resources; no public release is required for acceptance. Update
user docs and runnable examples. Covers the application obligations of EFF1,
EFF4–EFF5, EFF14–EFF16, EFF23–EFF29.

## Evidence and remaining risks

| Item                           | Status         | Evidence or next gate                                                                                                                                 |
| ------------------------------ | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Four policy forks              | Accepted       | User accepted all four recommendations on September 14, 2026; SPEC §3                                                                                 |
| Existing substrate             | Inspected      | Baseline `2ef4d520d`; capability/proc/supervise sources and event-horizon module map                                                                  |
| Pure direct-style bridge       | Gate unmet     | [M0](./m0.md): 80 checks pass, but general semantic justification and live-handler attributes do not meet the gate                                    |
| Replay protocol                | Walked through | [M0 §4](./m0.md#_4-protocol-walkthroughs): five traces; wait-cancel ordering and compensation retry clarified; implementation evidence still required |
| External-effect equivalence    | Conditional    | Only under each operation's explicit recovery/deduplication assumptions                                                                               |
| File-store power-loss behavior | Unproven       | M6; process-kill testing alone is insufficient                                                                                                        |
| Publication checks             | Passed         | In-tree sidebar check (1,373 pages), formatting, local links and pinned URLs; full site build with an 8 GiB Node heap                                 |

Publication validation on September 14, 2026: `dub run :ci --
--check-docs-sidebar` passed, as did the applicable pre-commit formatting,
local-link and permalink checks. `NODE_OPTIONS=--max-old-space-size=8192 npm run
docs:build` passed after the default 4 GiB Node heap exhausted during rendering.
The existing source-listing generator reported `twoslash-extract` status -11 for
`libs/ui/src/sparkles/ui/layout.d` and omitted that listing; that is a degraded
source-listing result, not an effects-spec failure or a successful extraction.
Future API fences are explicitly skipped. The M0 experiment's compiler evidence
is separately scoped in [m0.md](./m0.md); it is not a conformance claim for the
future API.

M0 validation also passed the final 80-case matrix, the live-surface probe under
both compilers, and the in-tree sidebar check (1,376 Markdown files checked).
The full docs build passed with the same 8 GiB Node heap. In this build the
source-listing extractor additionally omitted
`docs/specs/effects/experiments/m0/live_surface.d` after status -11, despite its
successful compilation and execution under both compilers. This is recorded as
a documentation-extraction limitation; it does not weaken the compiler probe's
assertions or count as successful source extraction.

No milestone is complete merely because a source file exists or a publication
check passes. The implementation owner records configurations, skipped cases,
failing cases and residual risks here at each gate. No parallel agents are
required for this plan or its review.
