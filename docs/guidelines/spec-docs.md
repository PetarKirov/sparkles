# Writing Specification Docs

A specification is a reviewable agreement about behavior, boundaries, and the
evidence required to accept an implementation. Its quality is measured by the
ambiguities and defects it prevents, not its length, number of tables, or resemblance
to an existing tree. Write enough that an implementer and an independent tester can
reach the same conclusion without privately inventing missing policy.

This guide governs new specifications and substantial revisions under
`docs/specs/`. Existing trees need not be mechanically reorganized. Apply these
rules to the work being changed; repair contradictions that affect it.

## Separate the Jobs

| Document kind         | Question it answers                                             | Location                                             |
| --------------------- | --------------------------------------------------------------- | ---------------------------------------------------- |
| Research              | What do sources and experiments tell us, with what limitations? | `docs/research/<topic>/`                             |
| Specification         | What behavior do we require, under which assumptions?           | `docs/specs/<lib-name>/`                             |
| Decision record       | Why this choice rather than the alternatives?                   | With the owning specification                        |
| Delivery plan         | In what slices will we establish the contract?                  | With the owning specification                        |
| Verification evidence | What was checked, how, and what remains unknown?                | With the owning specification; linked test artifacts |
| User documentation    | How do I use and understand the shipped library?                | `docs/libs/<name>/`                                  |

Research proposals are inputs, not accepted contracts. API sketches are not shipped
APIs. A merged implementation is not proof of conformance. Keep these distinctions
visible even when a small feature fits all its design material into one page.

### Learn From Research, Not Its Template

[Writing Research Docs](./research-docs.md) usefully emphasizes primary sources,
reproducible examples, shared vocabulary, and shallow trees that deepen on demand.
Those practices transfer; several stronger claims and conventions do not:

- **Imitation is not a quality criterion.** A fixed skeleton, mandatory quote,
  timeline, or taxonomy can produce filler. Include a section because it resolves
  a reader's question, not because every previous document has one.
- **A quote establishes what a source says, not that it is true.** Check the
  relevant implementation or experiment, its revision, and conflicting evidence.
  Citation density and a synthesized "consensus" do not settle design trade-offs.
- **Runnable examples can drift semantically.** An example may still pass while
  exercising the wrong configuration, missing an edge case, skipping execution, or
  printing output without asserting the claimed behavior. It establishes only the
  property it actually checks in the environment that ran it.
- **Publication checks are not semantic review.** Valid URLs, pinned paths, a
  review date, and a green site build do not validate an algorithm or contract.
- **Navigation should aid reading.** Define specialized vocabulary and link its
  first important use; do not link every repeated identifier or force long prose
  into dense tables for stylistic uniformity.

Do not inherit blanket hook-bypass or "skip and exit successfully" advice as a
verification policy. Missing evidence stays missing even when a job exits zero.

## Start With Scope and Risk

Before prescribing types or files, establish:

- The user or consumer problem, representative workloads, and observable success.
- The first delivery target, supported configurations, explicit non-goals, and
  deferred capabilities with entry conditions. "Future" is not a commitment.
- Existing facilities verified against the current code, not just historical
  research or milestone summaries.
- Related active or superseded work at consequential integration boundaries,
  including prerequisites not yet landed. Distinguish proposed symbols and APIs
  from existing ones; do not infer availability or acceptance from branch names.
- External compatibility requirements: API, wire, persisted data, or behavior;
  exact versions, revisions, extensions, and intentional divergences.
- Trust boundaries, attacker-controlled inputs, failure domains, and the most
  consequential uncertainties.

Review omissions in consumer and operational needs, but propose additions for
acceptance rather than silently expanding scope. Where diagnosis affects usable
behavior, specify how consumers distinguish important failures, exhaustion, and
stalled progress through structured errors, counters, hooks, or procedures. Assign
diagnostic ownership explicitly; a low-level library need not own a monitoring
stack. Diagnostic surfaces need privacy, cost, and stability contracts too.

Resolve architectural blockers through bounded feasibility experiments before
building around them. Each spike states a question, an experiment, and a decision
criterion. Record a negative result as useful evidence. A prototype is not silently
promoted into production design.

### Library Boundaries

Separate libraries when they have independently useful contracts, consumers,
dependency constraints, or lifecycles. Use modules for cohesive implementation
details; do not create a package for every noun in the research catalog.

Draw a dependency graph and define its arrow direction. Distinguish **package
dependencies** from **delivery dependencies**: an application integration may need
an event loop without its pure algorithm library depending on that loop.

Assign each cross-library contract one owner. Consumers link to it and state their
required capabilities; they do not duplicate its normative text. Explicitly assign
policy, resource ownership, error translation, and cancellation responsibilities at
the boundary. Keep generic mechanisms free of consumer-specific identity and policy.

## Use the Smallest Useful Tree

For a substantial library, this is a useful starting layout, not a file quota:

```text
docs/specs/<lib-name>/
    SPEC.md         # Authoritative contract and requirement IDs
    PLAN.md         # Delivery slices, dependencies, gates, milestone progress
    testing.md      # Test strategy, oracles, evidence, and verification gaps
    decisions.md    # Consequential choices and unresolved questions
```

A small extension can be one topic page in an existing library's tree, with these
concerns in clearly labeled sections. Add `index.md` only when it supplies useful
navigation. Split `wire.md`, `security.md`, or other topic pages when they own a
coherent contract; link them from `SPEC.md`. Separate `benchmarks.md` or
`open-issues.md` only when their content warrants it.

An effort spanning libraries can have an integration overview, but it must identify
the owning library for each obligation. Do not create a second normative copy of
the same contract in an umbrella document.

Prefer short prose and requirement blocks for semantics; tables suit finite
matrices and comparisons. Avoid giant status cells containing implementation diaries.

## Write Falsifiable Contracts

At the top of the specification, identify its scope, acceptance state, and owning
package or integration area. Distinguish normative requirements from explanatory
examples and rationale. Use **must** for obligations, **may** for permitted behavior,
and **should** only for recommendations with an explicit exception policy. Avoid
ambiguous future tense such as "will support" in an accepted contract.

Give stable IDs to externally observable obligations and consequential architectural
invariants. IDs should be unique within the library's spec tree, including topic
pages; qualify cross-library references with a link. Do not renumber IDs when moving
sections or reuse retired IDs for unrelated requirements. Existing document-local ID
schemes can remain if references identify the owning page unambiguously.

Each requirement needs a subject, triggering conditions, required result, and a way
to detect violation. Split obligations that can fail independently. Avoid IDs for
every explanatory sentence or incidental file name.

### Operation and State Contracts

For each relevant operation or transition, specify:

- Valid inputs, units, ranges, preconditions, and initial state.
- Resulting state, output ordering, and the point at which effects become committed.
- Ownership transfer, borrowing duration, aliasing, copying, and invalidation rules.
- Failure outcomes and effects: unchanged state, partial progress, retryable
  backpressure, connection closure, or another explicitly named transition.
- Behavior on duplicate, stale, late, unsupported, and out-of-order inputs.
- Allocation and work bounds, configured limits, arithmetic overflow, and exhaustion
  behavior. `@nogc` does not mean allocation-free or bounded memory.

State diagrams and transition tables help only if their guards, outputs, and invalid
transitions are defined. Distinguish hostile-input validation from programmer
contracts: malformed external input must not become an assertion failure.

Specify values and relationships before choosing storage. Regular events and IDs
support comparison and replay; live resources need not be copyable. A struct
containing mutable slices is not automatically an independently owned value. See
[local reasoning](../research/sean-parent/local-reasoning.md) and
[contracts](../research/sean-parent/contracts.md) for the underlying principles.

### Example: Make Failure Observable

Weak: "The queue is bounded and handles backpressure safely."

Better, for an illustrative non-blocking queue contract:

**QCAP1: Full-queue rejection.** For an open queue of capacity `C`, when exactly
`C` items are queued, `tryPut(item)` must return `full`, leave the queue unchanged,
and leave ownership of `item` with the caller. `C` is a positive item count fixed at
construction. This requirement does not prescribe the backing container.

**QCAP2: Closed-queue rejection.** Once closed, `tryPut(item)` must return `closed`
and preserve caller ownership and queued contents, regardless of remaining capacity.

Acceptance scenarios fill a capacity-two queue, attempt a third insertion, drain
and compare the original items, then retry the rejected item. Separate scenarios
close an empty and a full queue and check `closed`, not `full`. Payload lifetime
instrumentation checks for premature destruction or duplicate ownership.

These are example contracts, not claims about an existing Sparkles queue. The rest
of a real queue spec would separately define draining, closure, and concurrency.

### Concurrency and Sans-I/O

Separate deterministic state transitions from scheduling and external effects where
the domain permits. Make time, entropy, external-operation results, and application
commands explicit inputs; expose outputs, deadlines, and continuation work explicitly.
Do not require whole-state copying to achieve local reasoning.

Define mutation ownership, reentrancy, suspension boundaries, timer replacement,
equal-time event ordering, and stale-completion handling. Specify whether producing
an output consumes it, when submission succeeds, and how submission failure is fed
back. Cancellation is not rollback and is not permission to free borrowed resources.

Separate **safety** (something bad never happens) from **liveness** (progress occurs
under stated assumptions). "Eventually completes" needs delivery, fairness, and
resource assumptions. A deterministic test scheduler does not prove all real
interleavings safe. Build the simulator around actual contracts rather than inventing
a general runtime before its first tested transition.

## Promote Sources Into Requirements Deliberately

For externally derived obligations, identify their authority:

| Authority               | What to record                                                     |
| ----------------------- | ------------------------------------------------------------------ |
| Standard                | Edition or RFC, section, applicable options and errata             |
| Interoperability target | Pinned implementation revision and exact observed behavior         |
| Local policy            | Decision, rationale, limits, and permitted variation               |
| Hypothesis              | Missing evidence and the work it blocks; not an accepted guarantee |

Do not treat implementation accidents as protocol requirements. When a standard and
an interoperability target disagree, record the conflict and explicit resolution.
Pin GitHub source citations to full commit SHAs and verify the cited paths. Keep
the underlying survey in research rather than copying it into the specification.

For binary formats, specify lengths, endianness, canonicalization, unknown fields,
version negotiation, validation order where observable, and malformed-input behavior.
For persistence, also specify crash consistency, upgrade/downgrade behavior, and data
migration. Do not add compatibility machinery without an actual compatibility need.

## Design the Evidence Before the Implementation

The essential trace is:

```text
requirement -> falsifying scenario -> test/oracle -> scoped evidence
```

An oracle is the source of expected results. Explain its independence from the
implementation: published vectors, a simpler reference algorithm, exhaustive small
models, manually derived traces, or a separately implemented interoperating peer.
Round trips alone allow an encoder and decoder to share a bug. Two instances of the
same engine can agree on the same incorrect protocol. Differential tests can inherit
upstream defects. Combine evidence appropriate to the risk.

For each delivery slice:

1. Write the observable contract and concrete acceptance/failure scenarios.
2. Write the failing test and confirm it fails for the intended missing behavior.
3. Implement the smallest correct change, then refactor under the tests.
4. Add boundary, property, fault-injection, or integration cases as warranted.
5. Record the result and residual gaps; revisit the contract if evidence disproves it.

Retain deterministic seeds and minimized counterexamples for generated tests. For
high-risk state machines, review transition coverage and use bounded exhaustive
exploration where tractable. Test the oracle and harness too: deliberate faults or
known-bad cases should be rejected. Formal models are useful when risk warrants
them, but their assumptions and correspondence to production code remain obligations.

Use a risk-driven matrix, not a promise to exhaust every Cartesian product. Name
omitted combinations and justify sampling. Include invalid inputs, limit boundaries,
partial progress, saturation, teardown, and the interleavings that threaten ownership.

### Exercise the Real Boundary

Where a behavior spans layers, reuse scenario data across the pure engine, its
adapter, and the public consumer boundary. Describe initial conditions, actions,
and expected observations at meaningful steps. Share stimuli and independently
derived contract expectations, not production code that computes its own expected
answer. Identify what each layer cannot observe; a model-level lifetime check does
not replace a native completion test.

Start with ordinary data and small drivers, not a universal scenario language.
Fakes and mocks are useful for deterministic failures and scheduling, but document
their assumptions and the real-boundary checks needed to validate them. Neither
blanket mock bans nor mock-only integration suites establish correctness.

Security scenarios must name the attacker-controlled input or authority, the
enforcement boundary, and the forbidden observation or side effect. Exercise that
boundary and assert that the forbidden effect did not occur, rather than accepting
any error as success. For example, an authentication failure must not expose
protected application data or apply mutations that require authenticated authority;
explicitly permitted rejection accounting is a separate effect. Retain the attack
path when repairing the test, and isolate resources with synthetic credentials.
An unavailable reproduction does not establish safety.

### Keep Evidence Scoped and Honest

Separate model tests, compiler/safety checks, native integration, interoperability,
human testing, and performance measurements. A pass in one class does not certify
another. Link named tests and reproducible commands; file-to-requirement tables are
navigation, not a substitute for verification.

An evidence record identifies requirement IDs, the checked source revision or
explicit dirty-tree snapshot, command/test, relevant configuration and environment,
result/artifact, and remaining gap. Never store secrets in traces or fixtures.
For small local checks, a concise entry suffices; do not duplicate full CI logs.

Use `unverified`, `partial`, and `verified` for requirement evidence. `partial` names
the missing case; `verified` means the declared acceptance suite passed for the named
configuration, not a universal proof. A failed regression invalidates the affected
verification claim. Historical evidence remains historical after relevant changes
until revalidated. Commit hashes establish provenance, not correctness by themselves.

Skipped, unavailable, and not-run checks are not passes. Optional environment checks
may skip with an explicit reason, but a release gate requiring that configuration
remains unmet until evidence exists. Use the repository's
[test runner conventions](./AGENTS.md#testing); verify discovery and execution counts
so zero matching tests cannot silently satisfy a gate.

Record flaky results as unreliable evidence. Quarantine, retries, or replacement
tests require a reason and an explicit account of the remaining obligation. Retain
failed attempts; a later pass does not erase them. Do not delete the only check for
an obligation merely to restore green.

Performance requirements specify workload, size distribution, lifecycle/setup costs,
hardware/toolchain, metric, baseline, and acceptance threshold. Separate hard bounds
from measured distributions and aspirational targets. Follow
[Benchmarking & Profiling](./benchmarking-and-profiling.md); do not use "fast" or
"zero overhead" as unqualified guarantees.

## Plan Incrementally and Maintain Authority

`PLAN.md` owns delivery order and milestone progress, not a second copy of the
requirements. Each milestone names its obligations, prerequisites, deliverable,
acceptance commands/scenarios, and exclusions. A smoke example is insufficient for
a milestone promising cancellation, resource limits, and platform parity.

Prefer narrow end-to-end slices that expose integration risks early. Detail the next
slice; leave distant milestones coarse until decisions justify more precision. Keep
commits independently green rather than leaving an intentionally failing TDD test as
a completed milestone.

When handing off or interrupting a slice, update one compact section in the existing
tracker: obligation IDs and contract links, checked revision, completed versus
unverified work, evidence links, blockers, and the next executable action. State
the permitted scope when delegating. The next implementer must be able to resume
without the previous conversation, and must revalidate assumptions against the
current tree. Do not accumulate session diaries or duplicate evidence and decisions.

### Stage 0 Gate

For a new substantial effort, Stage 0 includes writing the specification, not merely
researching or scaffolding it. Its gate requires:

- Agreed scope, library ownership, compatibility baseline, and non-goals.
- Explicit architectural invariants and first-slice operation/failure contracts.
- An oracle and acceptance scenarios for every first-slice obligation.
- Feasibility evidence for blockers; unresolved questions identify which later work
  must not start. No unresolved blocker is hidden behind a confident API sketch.
- Adversarial review using worked success, failure, and boundary traces.
- Publication validation, separately reported from semantic acceptance.

Stage 0 is not a claim to have solved every later algorithm. Refine each later
contract before implementing it. Record who accepted consequential scope/design
choices, for example through a linked review or decision record; silence is not approval.

### Acceptance Review and Closure

An implementation completion report is a request for acceptance, not acceptance
itself. For high-risk slices, require a reviewer other than the implementer to
inspect the contract, implementation, tests, and claimed evidence afresh. A separate
review session alone does not guarantee independence. Review all promised obligations,
not just changed files, and verify that deviations received the required approval.
If independent review is unavailable, record that gate as unmet.

Check test integrity explicitly: did changes to assertions, fixtures, tolerances,
discovery, CI selection, or production test-mode branches make the gate easier
without an accepted contract change? Inspect relevant `version(unittest)` branches,
debug blocks, compiler flags, and platform configurations. A test can overspecify
incidental behavior; correcting it requires contract-based justification, not a
presumption that every relaxed assertion is wrong.

Each review finding states the affected obligation or missing contract, concrete
discrepancy, supporting evidence, impact, and proposed correction. Verify consequential
claims before changing the design. Give each finding an explicit disposition:

- **Fixed:** link the correction and its validation.
- **Rejected:** record the evidence or contract reasoning that resolves the claim.
- **Deferred:** name the owner, affected gate, and decision or delivery point.

Bound review effort by risk and an explicit stopping point. Repeated unresolved
blockers require a decision or escalation, not automatic dismissal. Budget exhaustion
ends the review session, not the acceptance criteria; deferred blockers keep their
gates unmet unless scope is explicitly revised.

Review and validate the final changed artifact. A final repair batch is not covered
by the review that prompted it: recheck affected obligations or label those changes
unreviewed. Reviewers who edit become authors of those edits; independent acceptance
must cover the resulting combined artifact. Review authority does not imply permission
to modify files, expand scope, or waive requirements.

### Decisions and Change Control

A consequential decision records its question, alternatives, constraints, evidence,
choice, trade-offs, and conditions for revisiting it. Use `proposed`, `accepted`, or
`superseded`; these are decision states, not implementation states. An open question
names the affected requirements, resolver or owning area, and decision point.

When evidence changes a decision, update the authoritative contract and affected
tests, consumers, and delivery gates together. Preserve a compact supersession link
and explain compatibility consequences. Do not silently weaken a requirement to turn
a failing test green. Distinguish a contract correction from a conformance fix.

Keep one evidence ledger and one milestone tracker. Link summaries to them rather
than repeating status across introductions, tables, and plans. A review date means
the named scope was actually reviewed; do not refresh it merely for formatting.

## Publication and Review Checklist

Register published pages in `docs/.vitepress/sidebar.json`, following
[the sidebar rules](./AGENTS.md#the-docs-sidebar-is-data). Use relative links to
owning sections, backtick identifiers, and label code fences. Keep literal angle
brackets and Vue interpolation syntax in safe fenced examples. Do not expand
dead-link exclusions just to hide unresolved references.

Label illustrative pseudocode and future API sketches explicitly. Runnable examples
follow the [example conventions](./AGENTS.md#runnable-readme-examples); skipped
future examples retain an owning milestone and count as no implementation evidence.
Review golden-output changes against the contract rather than blessing output blindly.

Run applicable checks from the repository root:

```bash
dub run :ci -- --check-docs-sidebar
npm run docs:build
```

Also run the repository Markdown formatter/checker, focused example verification
when runnable examples changed, and pinned-source checks when citations changed.
Use the in-tree `ci` tool rather than assuming a PATH wrapper reflects current code.
Report blocked checks and their causes; never present a publication pass as a
correctness verdict.

Before accepting a specification or substantial revision, ask:

- [ ] Can an independent implementer and tester agree on observable behavior?
- [ ] Are scope, exclusions, assumptions, trust boundaries, and owners explicit?
- [ ] Does each obligation have one authoritative definition and stable reference?
- [ ] Are failures, ownership, limits, and relevant ordering rules specified?
- [ ] Are upstream observations distinguished from standards and local choices?
- [ ] Can the acceptance tests falsify the claim without sharing its implementation?
- [ ] Are evidence classes, configurations, skips, and residual gaps visible?
- [ ] Do milestone gates cover all promised obligations, not just the happy path?
- [ ] Do security tests check forbidden effects at the actual enforcement boundary?
- [ ] Are test-integrity changes justified and completion claims independently reviewed
      where required?
- [ ] Are findings dispositioned and the final edits covered by review and validation?
- [ ] Are unresolved decisions blocking only explicitly named work?
- [ ] Are change consequences, user-doc updates, and publication checks accounted for?

The final review question is not "does this follow the template?" It is **"what
could two reasonable readers implement differently, and what would detect it?"**
