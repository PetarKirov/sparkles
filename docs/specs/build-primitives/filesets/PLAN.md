# Fileset delivery plan

_The reviewable implementation sequence for [SPEC.md](./SPEC.md). Each
milestone lands code, tests and the evidence its gate names. Decisions and open
questions live in [decisions.md](./decisions.md)._

**Status (September 21, 2026):** nothing implemented. Every requirement in
`SPEC.md` is `unverified`.

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
M6  content-addressing schemes            ── blocked on decisions.md D1
 │
M7  subtree cache
 │
M9  consumer migration + deletion of the old modules
```

`M0` is independent of everything and useful on its own. `E0` gates only `M3`.
`M6` is the only milestone the open Merkle decision blocks.

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

### M2 — The prefix lattice and verdicts

**Scope.** [`FSA1`–`FSA6`](./SPEC.md#6-analysis-and-planning-fsa): root
derivation, the three directory verdicts, `undecided`, forced entry, static
emptiness.

**Gate — the load-bearing one.** For every fileset in the fixture set, the
planned resolution and a brute-force walk that ignores all verdicts produce the
same member set. Any member the plan misses is a `FSA1` violation. This gate is
what makes the optimizer safe to make cleverer later, and it must run on every
fixture for the life of the library.

### M3 — The resolution machine and three drivers

**Scope.** [`FSM1`–`FSM7`](./SPEC.md#7-the-resolution-machine-fsm), the
synchronous driver, and the `event-horizon` driver. Depends on `E0`.

**Gate.** All three drivers produce byte-identical results over one fixture
set. The machine's modules import nothing that performs I/O — checked by grep,
not by inspection.

### M4 — Ignore scopes, and the behaviour-preservation gate

**Scope.** [`FSI1`–`FSI4`](./SPEC.md#9-ignore-scopes-fsi) — the immutable
arena-backed chain replacing the push/pop stack.

**Gate (a milestone gate, not merely a test).** The old walker and the new
machine are run over real repository trees, and their results compared. Every
divergence is either explained by
[`FSG2`](./SPEC.md#5-matching-fsg) (the anchoring change) and recorded, or
fixed. Nothing is deleted until this evidence exists.

### M5 — The FSO vocabulary and scheme declarations

**Scope.** [`FSO1`–`FSO4`](./SPEC.md#3-the-file-system-object-vocabulary-fso),
[`FSS1`–`FSS8`](./SPEC.md#8-the-scheme-seam-fss).

**Gate.** A scheme declaring no metadata provably issues no `stat`. The `a`
versus `a.b` fixture distinguishes `narOrder` from `gitTreeOrder`. A fold
scheme with `none` ordering fails to compile.

### M6 — Content-addressing schemes

**Blocked on [D1](./decisions.md#d1-which-merkle-shape).**

**Scope.** The first two schemes, and the sibling contract under
`docs/specs/build-primitives/content-addressing/`.

**Order within the milestone.** Merkle first, NAR second — the Merkle oracle
needs only tooling this repository already requires, while NAR's needs Nix on
the host. If D1 selects the git shape, `git write-tree` is that oracle;
Software Heritage's `swh.core.nar` is a second, independent NAR implementation
if a cross-check is wanted offline.

**Gate.** Digests match the chosen oracle on the fixture set, including the
ordering fixture and a case-collision fixture.

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
