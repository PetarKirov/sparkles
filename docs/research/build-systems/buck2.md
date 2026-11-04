# Buck2 (Rust, Starlark)

Buck2's engine in one sentence: a daemon hosting a single demand-driven graph —
`DICE` — in which files, build files, targets, providers and action results are
all just keys, and whose execution layer is a REAPI client that treats the local
machine as one more (unsandboxed) executor. This is the engine companion to the
workspace survey; it stays inside `dice/` and `app/buck2_execute*`.

**Last reviewed:** November 3, 2026

| Field          | Value                                                                             |
| -------------- | --------------------------------------------------------------------------------- |
| Language       | Rust (engine, `dice/`, `app/`), Starlark (all rules, `prelude/`), Python tooling  |
| License        | MIT **OR** Apache-2.0 (dual)                                                      |
| Repository     | [meta/buck2][repo] — origin says `meta`; in-tree links still say `facebook/buck2` |
| Documentation  | [buck2.build][docs-site]; in-tree `docs/` plus an 839-line `DICE` spec            |
| Category       | Industry — polyglot orchestrator; RE-first engine on a monadic graph              |
| Clone (pinned) | `$REPOS/build-systems-research/src/buck2`                                         |
| Commit         | `08b403b138373f506de90d15370162677526e388`                                        |

## Overview

### What it solves

Buck2 inherits Buck1's problem — a monorepo spanning C++, Python, Rust, Kotlin,
Swift, Objective-C, Haskell and OCaml — and rejects Buck1's answer, a Java binary
with the rules compiled in. Every rule moves to Starlark and the build onto one
incremental graph, so "what is dirty" and "what is a target" stop being separate
questions.

### Design philosophy

**Remote execution first.** "[L]ocal execution is considered a special case of
remote execution", so "things such as directory hashes can be pre-computed ready
to send to remote execution" ([`docs/about/why.md`][why]).

**One graph, no phases.** Buck2 refuses the Bazel-shaped split between a target
graph and an action graph: "there are no target graph/action graph phases, just a
series of dependencies" in a single DICE graph, which "result[s] in whatever the
user requested" ([`why.md`][why]).

**Soundness is a contract.** `DICE`'s core state is a judgment with a theorem, and
the theorem "is unconditional: it assumes nothing about the caller"
([`incrementality.md`][dice-doc] §1) — not determinism of computes, not
completeness of change reporting. Those are the _environment's_ obligations.

> [!NOTE]
> **Delta against the workspace page.** [buck2 (monorepo-tooling)][mono-buck2]
> covers cells, labels, `BUCK` files, the target→action narrative, `BXL`,
> daemon/isolation and the five workspace dimensions; this page goes one level
> down: the certificate/slot/branch structure, ε, the action digest and
> materialization policy, and what the local executor actually does.

## How it works

### `DICE`: certificates, revisions, ε

Every node is a `Key` with an async `compute`; reading another key yields a
`Revision` (an interned identity for the value), and `(key, revision)` is what the
graph remembers. A completed computation leaves a certificate — key, result
revision, the dependency premises with the revisions they were read at, and `ε`,
"the revision of `key`'s untracked input the value was computed under"
([`dice/dice_core/src/cert.rs`][dice-cert]). `deps` keeps the _series-parallel_
shape of the reads, so re-verification fails fast on an early premise and fans out
on parallel groups ([`incrementality.md`][dice-doc] App. B).

**ε is the escape hatch for the untracked.** Every key implicitly has an untracked
input `k′` standing for everything outside the graph its compute consumed. It
cannot be named, only dirtied: a force-dirty mints a fresh revision for `k′` and
invalidates `k` without saying why. Buck2's instance is the file system — the
baseline is "the state of the project's files that the changes recorded on a DICE
branch are relative to" ([`baseline.rs`][baseline]) — and the watcher's
batch of changed paths lands there: `ctx.changed(self.files_to_dirty)?`
([`io.rs`][file-io]).

### Slots, claims, branches, attachment

The core state memoizes the justification judgment in three stores: **slots** (per
key × branch), **assertion histories**, and a **branch tree** giving versions their
meaning. A slot holds a _claim_ — one certificate valid over a contiguous window
`[valid_from, valid_until)` — plus the key's untracked-input history. An open-ended
claim is **attached**, and attachment is the trick: "we wish to make `commit`ting
some changes and looking up the values of unaffected keys take time proportional to
the rdeps of the changed keys, not the deps of the requested ones"
([`incrementality.md`][dice-doc] §4.6).

An attached key is implicitly valid at every newly committed version until a change
reaches it, so a warm build costs a reverse-dependency walk over the changed keys
and nothing else. `commit` detaches that walk's frontier, `fork` copies the parent's
rdep map and partitions candidates, and `delete` copies claims down to children. Two
properties travel well: `lookup` is one-directional — "`Unknown` claims nothing and
is therefore always a sound answer" (§2.2), so eviction and restart are trivially
sound — and the core is a standalone crate with a brute-force oracle and a shrinking
fuzzer ([`fuzz.rs`][dice-fuzz]).

The evidence stack is worth separating because it is stronger than a paper
proof sketch but weaker than mechanized correctness. `dice_core`'s tests are
organised by sections of `incrementality.md`, and every mutating test call
re-checks core invariants ([`dice_core/src/tests.rs`][dice-tests]). A second,
system-level harness, `fuzzy_dice`, generates `SetValue`, `ForceDirty`,
`ReinjectEquivalent`, transient-step, and query sequences and checks the
engine against a reference model on two properties: values must be correct,
and the set of evaluated variables must be within a permitted-recompute
bound ([`fuzzy_dice/README.md`][fuzzy-dice]). The bound is deliberately an
upper bound tuned so today's implementation produces no violations; it can
therefore catch unsound reuse, but does not prove maximal early cutoff. A
bounded fixed-size fuzz runs in CI and deep runs are manual. That is a
differential oracle over the shipped incremental engine — unusually good
engineering evidence, still bounded by the generator's operation vocabulary
and explicitly gated known-buggy scenarios.

### Files enter the graph as nodes, not contents

`IoReadFileKey` returns a _path check_, not file text, and is declared
`AlwaysUnequal`: "The contents of a file are read by the caller, after computing this
key, so that they are never held in the graph. The key is therefore never equal to
its previous value: a change to the file must recompute whoever read it"
([`io.rs`][file-io]). The graph never interns megabytes of source, and early cutoff
moves one level up, where the _consumer's_ value (a parsed module, a configured
target) can still come out equal. Equality is per-key policy, and the trait doc is
blunt: "Returning equality for different values would produce inconsistent graph
state" ([`api/key.rs`][dice-key]). Errors are excluded by `validity()`, which
`BuildKey` uses to cache no error at all ([`calculation.rs`][build-key]).

### Remote-execution-first execution and materialization

An action's identity is a digest "of an action's command and all its inputs"
([`architecture.md`][arch]), and the input side is built as a REAPI `Directory` tree
_before_ execution even locally — `inputs_directory()` constructs exactly the
structure that would be uploaded ([`inputs_directory.rs`][inputs-dir]). Execution
then has four shapes: local, remote, **hybrid** (race both; "whichever claims the
request first will get to execute it", [`hybrid.rs`][hybrid]), and stacked.

Outputs are the interesting half. `buck-out` is not a content-addressed store but a
working area per isolation directory; the authoritative bytes live in the RE CAS. So
Buck2 **defers materialization**: "Buck2 will avoid downloading outputs until they
are required by a local action" ([`deferred_materialization.md`][deferred]). The
price is coupling to backend policy — it "expects that the TTL returned from action
cache entries by your Remote Execution backend always exceeds the TTL of all output
artifacts it references", and an expired blob's documented recovery is restarting the
daemon (`CasNotFoundError` says run `buck2 killall`, [`materializer.rs`][materializer]).

The implementation is a lease-and-index subsystem, not merely "download
later". `MaterializeRequest` asks for artifacts plus output paths, returns a
response whose lease must be held while reading, and distinguishes final
(required/not-required) from intermediate purposes. `[buck2] materializations`
accepts `all`, `deferred`, and `deferred_skip_final_artifacts`; the last can
report a non-required final artifact successful without putting it on disk.
Daemon configuration also carries TTL refresh (by default every 1,800 s for
entries under a 3,600 s remaining TTL, rollout-gated), access-time updates,
stale-artifact cleaning, optional read-only outputs, strict leases, and an
`fsck` stream for paths that no longer match the materializer index
([`materializer.rs`][materializer], [`daemon/state.rs`][daemon-state]). Deferred
materialization thus shifts work from bytes to metadata consistency: Buck2
must keep leases, TTLs, clean-stale decisions, and on-disk reality in agreement
for the life of the daemon.

### Dep files: a per-action read set

The second discovery mechanism is a post-hoc read set, the shape [concepts] calls
_recorded execution_ rather than _traced_: "Dep files allow commands to declare which
subset of their inputs were used when the command executed"
([`dep_files.md`][depfiles]). If an action is invalidated and every changed input is
outside the declared set, the previous result is reused and nothing runs. Three
caveats keep it honest: dep files are **lazy** (unparsed and undownloaded unless a
re-run is considered), **not covering** (a subset is fine, but within it every used
input must appear), and **daemon-scoped** (dropped on restart or by
`buck2 debug flush-dep-files`).

## Analysis spine

**Suspending × verifying traces** — the `Shake` cell of [concepts]'s Table 2, not the
`Buck` cell (topological × deep constructive) the paper assigns to Buck1. `compute`
awaits its dependencies, so a late discovery suspends the caller rather than
restarting it: the continuation is a Rust future, not a saved position. The trace is
verifying — result revision plus dependency revisions, no terminal-input hashing —
and early cutoff is revision re-finding: a recompute producing an equal value
re-finds the same revision, so dependents' certificates still hold.

Two deviations keep it off the cell exactly. The graph is **branch-structured and
concurrent** — several versions and forked lineages live at once, which the paper's
single-store model does not express. And a constructive layer sits _beside_ the
graph: the RE action cache keyed by action digest is the `Bazel`/`CloudBuild`
mechanism grafted on, not derived from the rebuilder.

### 1. Task model & scheduling

Static at the action level: a rule declares inputs and outputs, and the action graph
is a DAG. Dynamic dependencies exist but are narrow — `ctx.actions.dynamic_output(...)`
is "restricted in their power compared to fully generic dynamic dependencies"
([`dynamic_dependencies.md`][dyndeps]).

### 2. Rebuilding & correctness

Constructed, not checked: an undeclared read is an unregistered edge, and the
README's "it is required for a build rule to correctly declare all of its inputs"
([`README.md`][readme]) is enforced by RE refusing to run, not by observation. The
spec names the obligations that restore the classical picture: functional
certificates give uniqueness, honest traces plus complete change reporting give
from-scratch consistency ([`incrementality.md`][dice-doc] §3.4).

### 3. Dependency discovery

Declared, with dep files the only post-hoc mechanism and `dynamic_output` the only
analysis-time one. **No tracing exists**: no `ptrace`, no FUSE mount around an action,
no syscall filter, and — since local actions run in the project directory with no
filesystem isolation — nothing that _could_ observe a read. The local hermeticity
story is an environment allow-list (`PATH`, `HOME`, `TMPDIR`, …) plus output-path
cleaning, and the README is candid: "Buck2 currently does not sandbox _local-only_
build steps; in contrast, Buck2 using Remote Execution is _always_ hermetic by
design" ([`README.md`][readme]).

### 4. Store & caching

`buck-out/v2` per isolation directory, plus the RE CAS as the real store. The local
side is an artifact tree and a materializer index, not a CAS: identical bytes in two
output paths are two files unless the SQLite state says otherwise. The action-cache
key is the action digest; the graph-level key is the `ActionKey` of the `BuildKey`
node, so a warm graph answers before any digest is computed. Eviction is the
backend's job; the client-side answer is `clean --stale`, which "does not fully wipe
buck-out but it should not negatively impact build performance"
([`deferred_materialization.md`][deferred]).

### 5. Hermeticity & provenance

Hermetic by construction under RE, non-hermetic by construction locally — the
sharpest contrast in the catalog, since [Bazel][bazel], [BuildXL][buildxl] and
[Rattle][rattle] all treat local correctness as something to be enforced. Provenance
in the SLSA/in-toto sense is **absent**: `attestation` and `in-toto` appear nowhere in
`docs/` or `app/`, `provenance` means a config setting's origin, and the one SLSA
mention is a _draft_ observability RFC ([`oss-observability.md`][obs-rfc]).

### 6. Distribution

A REAPI v2 client and nothing else: `engine_address`, `action_cache_address`,
`cas_address`, `instance_name`, TLS, and SHA256/BLAKE3/SHA1 via `digest_algorithms`
([`remote_execution.md`][re-doc]). No proprietary executor protocol; the only
invention above it is the politics of the race — hybrid execution, remote-first
claim ordering, fallback — plus materialization policy.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static DAG executed once per process, so the
transferable pieces are structural. Worth taking: the **certificate shape**
`(key, revision, deps, ε)` — the minimum a task record needs to be both verifiable
and forgettable, with ε the cleanest answer in this catalog to "my task read
something the DAG cannot see": one extra premise, always present, never named. Also
**attachment as a validity shortcut** (a clean node should not be re-walked),
**`AlwaysUnequal` as an explicit opt-out** from value comparison, and the
**oracle-plus-fuzzer** harness, a cheap and decisive test oracle. Worth avoiding: the
daemon dependency — graph persistence, dep-file reuse, deferred materialization and
error recovery all assume a process that outlives the command.

## Strengths

- **One graph, genuinely.** Targets, providers and action results are the same kind
  of node, so one mechanism tracks change and phases can overlap.
- **A specified core with a proof and a fuzzer.** `dice_core` implements a documented
  judgment and is checked against a brute-force oracle — the strongest correctness
  artefact in this catalog.
- **Dep files make declarations two-level** — coarse at analysis, precise after
  execution — without pretending the coarse level was right.

## Weaknesses

- **No local sandbox at all.** Local actions see the whole filesystem and an inherited
  environment, and nothing can detect a violation.
- **The daemon is load-bearing.** Graph state, dep files and materializer state all
  degrade on restart, and the remedy for an expired CAS blob is `buck2 killall`.
- **Young surface.** No stable tag, rules in-tree but toolchains not open-sourced, and
  an open-source RE binding the docs call "less polished".

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                      | Trade-off                                                            |
| ---------------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------- |
| One graph on `DICE`, no phases           | Uniform invalidation; phases overlap; one dirty mechanism      | Analysis and action nodes compete for memory and lifetime            |
| Certificates keyed by interned revisions | Verification is pointer-scale; early cutoff falls out          | Values must be interned and refcounted; a cold process has no trace  |
| ε untracked input on every key           | Models "this compute read the world" without naming it         | Coarse: any change under a watched root dirties its readers          |
| File contents never in the graph         | No megabyte interning; the graph stays small                   | `IoReadFileKey` is always-unequal, so cutoff moves to the consumer   |
| RE-first; local as a special case        | Digests precomputed; one code path for both                    | Per-action digest work even for purely local builds                  |
| No local sandbox                         | Speed; no `ptrace`/namespace tax per action                    | Undeclared reads are invisible; hermeticity requires RE              |
| Deferred materialization                 | Remote builds stop downloading intermediates (~2.5× at Meta)   | Soundness depends on backend TTL; expiry is an unrecoverable error   |
| Dep files as a second declaration layer  | Unused inputs stop causing rebuilds without target-graph churn | Daemon-scoped, lazily validated, wrong in the stale-output direction |

## Sources

- [`meta/buck2`][repo] at commit `08b403b138373f506de90d15370162677526e388`, clone at
  `$REPOS/build-systems-research/src/buck2` (HEAD dated 2026-11-02); every quote is
  verbatim from the file cited inline, opened at that SHA.
- Docs and engine: [`README.md`][readme], [`why.md`][why], [`architecture.md`][arch],
  [`remote_execution.md`][re-doc], [`deferred_materialization.md`][deferred],
  [`dep_files.md`][depfiles], [`dynamic_dependencies.md`][dyndeps],
  [`oss-observability.md`][obs-rfc], [`incrementality.md`][dice-doc],
  [`cert.rs`][dice-cert], [`fuzz.rs`][dice-fuzz], [`api/key.rs`][dice-key],
  [`calculation.rs`][build-key], [`io.rs`][file-io], [`baseline.rs`][baseline],
  [`inputs_directory.rs`][inputs-dir], [`materializer.rs`][materializer],
  [`hybrid.rs`][hybrid].
- Sibling pages: [concepts] for the scheduler × rebuilder grid, [mono-buck2] for the
  workspace treatment, and [bazel], [buildkit], [shake], [rattle] for adjacent engines.

<!-- References -->

[repo]: https://github.com/meta/buck2
[docs-site]: https://buck2.build
[readme]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/README.md
[why]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/about/why.md
[arch]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/concepts/architecture.md
[deferred]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/users/advanced/deferred_materialization.md
[re-doc]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/users/remote_execution.md
[depfiles]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/rule_authors/dep_files.md
[dyndeps]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/rule_authors/dynamic_dependencies.md
[obs-rfc]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/rfcs/drafts/oss-observability.md
[dice-doc]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/docs/incrementality.md
[dice-cert]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/dice_core/src/cert.rs
[dice-fuzz]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/dice_core/src/fuzz.rs
[dice-tests]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/dice_core/src/tests.rs
[fuzzy-dice]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/fuzzy_dice/README.md
[daemon-state]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_server/src/daemon/state.rs
[dice-key]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/dice/src/api/key.rs
[build-key]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_build_api/src/actions/calculation.rs
[file-io]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_common/src/file_ops/io.rs
[baseline]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_common/src/file_ops/baseline.rs
[inputs-dir]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_execute/src/execute/inputs_directory.rs
[materializer]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_execute/src/materialize/materializer.rs
[hybrid]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_execute_impl/src/executors/hybrid.rs
[concepts]: ./concepts.md
[mono-buck2]: ../monorepo-tooling/buck2/
[bazel]: ./bazel.md
[buildxl]: ./buildxl.md
[buildkit]: ./buildkit.md
[shake]: ./shake.md
[rattle]: ./rattle.md
