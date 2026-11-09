# Fileset delivery plan

_The reviewable implementation sequence for [SPEC.md](./SPEC.md). Each
milestone lands code, tests and the evidence its gate names. Decisions and open
questions live in [decisions.md](./decisions.md)._

**Status (November 8, 2026):** M0 is delivered (PR #507), with its
`git check-ignore -v` parity gate. M1–M5, with E0, are delivered
with their gates;
the state of each requirement is in the SPEC's
[evidence ledger](./SPEC.md#evidence-ledger).
The work resumes as the file-system layer of the
[build graph](../build-graph/SPEC.md#_12-file-system-access): every listing
the graph makes is a fileset resolution, so the build graph's E2 needs M1–M3,
and M5 for the listing digests its planning read set records
([D44](../build-graph/decisions.md#d44-the-build-graph-reaches-files-through-the-vfs-accepted)).

## Dependency graph

```text
E0  event-horizon admission primitive  (decisions.md A6)
 │
M0  GitIgnoreRule provenance ───────────────┐
 │                                          │
M1  IR + algebra + in-memory driver         │
 │                                          │
M2  prefix lattice + verdicts               │
 │                                          │
M3  resolution machine + three drivers ◄────┘ (needs E0)
 │
M4  ignore scopes on the immutable chain  ── behaviour-preservation gate
 │
M5  FSO vocabulary + scheme declarations
 │
M6  content-addressing schemes            ── decided by decisions.md A19
 │
M7  subtree cache
 │
M9  consumer migration + deletion of the old modules
```

`M0` is independent of everything and useful on its own. `E0` gates only `M3`.
The Merkle decision that blocked `M6` is A19.

## Milestones

### M0 — `GitIgnoreRule` provenance

**Scope.** Each parsed rule gains the path of the `.gitignore` that declared it
and its 1-based line number. No other behaviour changes.

**Why first.** It is a prerequisite for [`FSI3`](./SPEC.md#9-ignore-scopes-fsi)
and for any decision-trace tooling, it is independently useful (it gives the
existing walker `git check-ignore -v` parity), and retrofitting provenance into
a compiled matcher later is expensive.

**Gate.** On a fixture with nested `.gitignore` files, the reported file and
line match `git check-ignore -v` for every path.

### M1 — The IR, the algebra, and the in-memory driver

**Scope.** [`FSV1`–`FSV5`](./SPEC.md#4-the-fileset-value-fsv),
[`FSG1`–`FSG4`](./SPEC.md#5-matching-fsg), the D combinator API, and the
in-memory driver ([`FSD2`](./SPEC.md#11-drivers-fsd)) with its tree-literal
fixture format.

**Gate.** The brute-force differential oracle agrees with the compiled
predicate on the whole fixture set. Allocation instrumentation shows zero
allocation on the evaluation path.

**Delivered.** Modules `fileset/pattern.d`, `value.d`, `tree_literal.d`;
oracles and fixtures in `fileset/testing.d`; the audit in
`fileset/allocation_audit.d`. Two scope items finish in M3, because both need
a resolution: [`FSV4`](./SPEC.md#4-the-fileset-value-fsv)'s empty-directory
report is part of the resolution result, and `FSD2`'s driver is M3's adapter
instantiated over `MemVfs`. M1 delivers the tree-literal format and the
`MemVfs` it builds. [`FSG2`](./SPEC.md#5-matching-fsg) is checked by M4's
differential gate.

### M2 — The prefix lattice and verdicts

**Scope.** [`FSA1`–`FSA6`](./SPEC.md#6-analysis-and-planning-fsa): root
derivation, the three directory verdicts, `undecided`, forced entry, static
emptiness.

**Gate — the load-bearing one.** For every fileset in the fixture set, the
planned resolution and a brute-force walk that ignores all verdicts produce the
same member set. Any member the plan misses is a `FSA1` violation. This gate is
what makes the optimizer safe to make cleverer later, and it must run on every
fixture for the life of the library.

**Delivered.** `fileset/plan.d`: `plan` derives the start roots and the
static-emptiness diagnostic, and `rootState` positions an evaluator at a
root. The gate lives in `fileset/testing.d` beside M1's and runs over the same
fixture set: `plannedWalk` follows the plan and the verdicts, and is the
reference the M3 machine must match. `FSA5` is partial until M4. Only a root
`.gitignore` exists as a leaf before then.

### M3 — The resolution machine and three drivers

**Scope.** [`FSM1`–`FSM7`](./SPEC.md#7-the-resolution-machine-fsm), the
synchronous driver, and the `event-horizon` driver. Depends on `E0`.

**Gate.** All three drivers produce byte-identical results over one fixture
set. The machine's modules import nothing that performs I/O — checked by grep,
not by inspection.

**Delivered.** `fileset/machine.d` (the machine), `driver.d` (the one
adapter and `PathCollector`) and `driver_loop.d` (the event-horizon
executor); E0 is `sparkles.event_horizon.admission`. The machine reports
units, incomplete entries and errors. A `Plan` start root whose directory is
absent holds no member and is not reported. The gate is
`fileset.gate.m3.threeBackends`, beside `fileset.gate.m3.machineAgreesWithOracles`,
which holds the machine to M1's and M2's oracles on the whole fixture set.
`FSV4` and `FSD2`, moved from M1, are delivered here. `FSM5`'s order and
`FSE1`, `FSE2` and `FSS6`'s scheme halves wait for M5.

### M4 — Ignore scopes, and the behaviour-preservation gate

**Scope.** [`FSI1`–`FSI4`](./SPEC.md#9-ignore-scopes-fsi) — the immutable
arena-backed chain replacing the push/pop stack.

**Gate (a milestone gate, not merely a test).** The old walker and the new
machine are run over real repository trees, and their results compared. Every
divergence is either explained by
[`FSG2`](./SPEC.md#5-matching-fsg) (the anchoring change) and recorded, or
fixed. Nothing is deleted until this evidence exists.

Delivered as `fileset.gate.m4.behaviourPreservation`. Two more classes are
accepted beside `FSG2`: a divergence where git agrees with the machine (the
old walker's defect) and one `FSA5`'s forced entry explains. The record, over
this repository and ten others, linux among them, is
[A17](./decisions.md#a17-the-m4-divergence-record).

### M5 — The FSO vocabulary and scheme declarations

**Scope.** [`FSO1`–`FSO4`](./SPEC.md#3-the-file-system-object-vocabulary-fso),
[`FSS1`–`FSS8`](./SPEC.md#8-the-scheme-seam-fss).

**Gate.** A scheme declaring no metadata provably issues no `stat`. The `a`
versus `a.b` fixture distinguishes `narOrder` from `gitTreeOrder`. A fold
scheme with `none` ordering fails to compile.

Delivered: `fileset/fso.d` (the vocabulary and the declarations) and
`fileset/scheme.d` (`resolveScheme`, `FsoRef`, `PathScheme`). The machine
orders units, requests declared metadata, reads link targets, and hands a
fold the directories above its start roots
([A18](./decisions.md#a18-the-scheme-seam-as-built)). The three gate
conditions are `fileset.scheme.FSS2.metadata`,
`fileset.scheme.FSS1.orders` and `fileset.scheme.FSS5.foldNeedsOrder`.
`FSS8` stays partial until M6 gives the supplied tree a type.

### M6 — Content-addressing schemes

**Decided by [A19](./decisions.md#a19-content-addressing-is-a-family-of-schemes-with-snix-castore-as-the-default).**

**Scope.** The generic parts of A19 (`MerkleFold`, `Serial`, `Tee`), the
castore, NAR and git instances (BLAKE3 from `sparkles.base.hash.blake3`), and the
sibling contract under `docs/specs/build-primitives/content-addressing/`.
`FSS8` gets its type: a supplied bao outboard, verified instead of read.

**Order within the milestone.**

1. The oracles in the dev shell: Snix from its own repository, and Nix's
   `nix hash path`, which every Nix host has.
2. `MerkleFold`, with the D1 spike refactored into its git instance, which
   `git write-tree` checks without new tooling.
3. castore with BLAKE3, the default identity.
4. `Serial` and NAR, which may need the stream's `leave` from A19.
5. `Tee` of castore and NAR, so NarHash is stored beside the identity (D2).

**Gate.** Each instance matches its oracle on the fixture set, including the
ordering fixture and a case-collision fixture. A `Tee` reads each file once.

Progress: all five steps are delivered. `content_addressing/merkle.d` holds the
shell, `git.d` and `castore.d` the instances; `content_addressing.git.writeTree`
checks SHA-1 and SHA-256 against `git write-tree`, and
`content_addressing.castore.snix` checks castore against Snix, on the hazard,
case-collision, fixture and 200 random trees. `nar.d` holds NAR, a stream
declaring the new `leave`; `content_addressing.nar.dump` checks it against
`nix-store --dump` on the same trees. The tee is `NarScheme!(H, Ref, Dirs)`,
NAR with Merkle encodings beside it, and `CastoreNar` stores the `NarHash`
beside the identity; `content_addressing.tee.readsOnce` is the gate's "reads
each file once". The sibling contract is a draft in
[content-addressing/](../content-addressing/SPEC.md); left are its acceptance,
with C1, and `FSS8`'s type, `CAO1` and `CAO2`, whose layout C2 leaves open.

### M7 — The subtree cache

**Scope.** Cross-run caching of subtree digests plus a staleness heuristic,
under [A9](./decisions.md#a9-incremental-invalidation-stops-at-level-2).

**Gate.** The cache is advisory: with the cache deleted, results are identical
and only slower. A fault-injection case in which the heuristic reports
"unchanged" for changed content must fail the suite — the oracle is tested, not
only the implementation.

### M9 — Migration and deletion

**Scope.** `apps/hue` (`picker_sources.d`, `site.d`, `picker_grep.d`),
`libs/docs/source_set.d`, `libs/core-cli/examples/tree.d`, and the
build-primitives example. `passesGlobs` is imported directly by two of those
and needs its own answer — most likely it becomes a fileset expression and
those call sites lose their bespoke glob layer.

**Gate.** M4's divergence record is closed, all consumers are on the new API,
and the old modules are deleted in the same PR that removes the last consumer.

## What is deliberately not here

The textual query language is a separate track, grounded by
[fileset-languages](../../../research/fileset-languages/index.md). It targets
this IR and must not constrain it; the parser lands only once the IR is stable,
which is after M2.
