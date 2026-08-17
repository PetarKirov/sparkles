# `sparkles:fuzzy` — Delivery Plan

_The reviewable implementation sequence for [SPEC.md](./SPEC.md). Each
milestone lands code, tests, documentation, and any benchmark needed to make
its gate evaluable._

## Dependency graph

```text
D0 specification repair
 ├─ U0 sparkles:base Unicode analysis
 ├─ E0 event-horizon raw CPU jobs
 └─ M0 fuzzy scaffold
      └─ M1 query + glob
           └─ M2 exact witness
                └─ M3 ranking kernel
                     └─ M4 ranking + top-K
                          └─ M5 history
                               └─ M6 chunked search
                                    └─ M7 F0 release gate

E0 + M7 ──> hue P0 integration
M5 + P0 ──> hue P3 persistence
```

`U0`, `E0`, and `M0` may proceed independently after `D0`. The fuzzy library
does not depend on event-horizon; `E0` gates only the parallel hue host.

## Working-tree status (2026-08-17)

`D0`, `U0`, `E0`, and `M0`–`M7` are implemented and verified. Their focused
unit, differential, capacity, restart, fallback, allocation-audit, benchmark,
documentation, Nix, and repository tests pass. The five-row lifecycle-aware
benchmark baseline is recorded in [benchmarks.md](./benchmarks.md). Hue's P0
state/Finder/files/scheduler seams and the P1 shared widget tree/presets are
implemented; mounting the view as a live GUI/TUI command remains P1 host work,
and P2+ remain deferred as listed in `picker.md`.

## D0 — contract repair

- Replace the faulty traceback oracle, byte matcher, unbounded containers,
  incomplete grammar, partial ranking formula, abort pointer, and contradictory
  ownership with the contracts in SPEC §§1–10.
- Update hue's `PKQ`/`PKR`/`PKM`/`PIK` rows and event-horizon's CPU-pool
  contract.
- Keep `adversarial-review.md` as the reproduction record and map all 51
  findings in SPEC §12.

**Gate:** every finding has exactly one normative resolution and at least one
owning implementation/test milestone.

## U0 — bounded Unicode analysis in `sparkles:base`

- Add source-provenance text units, strict-plus-opaque UTF-8 decoding,
  canonical/compatibility normalization, simple/full folding, mark removal,
  word segmentation, and immutable stopword lookup.
- Extend the Unicode generator and document the pinned UCD inputs.
- Add reference and how-to documentation.

**Gate:** Unicode normalization/case-fold conformance samples, malformed-byte
round trips, provenance expansion/composition cases, capacity failures, and
explicit `@safe pure nothrow @nogc` tests pass with allocator hooks observing
zero calls.

## E0 — persistent raw CPU jobs in event-horizon

- Add a fixed-capacity persistent CPU pool with attributed function-pointer
  jobs, caller-owned contexts, a fixed completion queue, and explicit
  `notStarted`, `queueFull`, `completionFull`, `shuttingDown`, and startup
  outcomes.
- Preserve the existing batch/delegate `WorkStealingPool` surface.
- Specify context lifetime through completion and make shutdown drain or cancel
  deterministically.

**Gate:** saturation, start/stop cycles, context-lifetime, exactly-once
completion, and ThreadSanitizer stress tests pass; the existing pool benchmark
does not regress beyond its declared threshold.

## M0 — package and measurement floor

- Register `libs/fuzzy` in DUB, Nix source sets, and `AGENTS.md`.
- Land the package module, common IDs/errors/capacities, checked and benchmark
  configurations, and the `docs/libs/fuzzy/` Diátaxis skeleton immediately.
- Land deterministic small, large, Unicode, invalid-byte, and adversarial
  fixtures plus benchmark environment metadata.

**Gate:** an empty library build/test and docs build pass; the fixture generator
is byte-for-byte reproducible.

## M1 — analysis bridge, query, constraints, and glob

- Bind the two base profiles to fuzzy capacities.
- Implement bounded lexing, quoting/escaping, explicit and legacy constraint
  dispatch, locations, concrete candidate metadata, and the evaluator.
- Compile and execute the bounded Thompson NFA.

**Gate:** every SPEC §3 grammar row and malformed form is covered; randomized
glob results match a slow test-only oracle; adversarial brace inputs remain
within the documented state/work bounds.

## M2 — exact admission and positions

- Implement the bounded-deletion cursor DP, canonical witness reconstruction,
  multi-part semantics, range merging, and sound refinement predicate.

**Gate:** exhaustive short-alphabet and randomized cases match a conventional
LCS/witness oracle; score admission and positions accept identical sets;
endpoint deletion, two-unit, Unicode expansion, invalid-byte, and incomplete
refinement scenarios are pinned.

## M3 — bounded ranking kernel

- Add validated scoring, rolling Smith-Waterman rows, deterministic direct
  witness fallback, exact byte/source offsets, and `MatchOutcome`.
- Establish exact camel/snake/exact score goldens and lifecycle benchmarks.

**Gate:** no stale-row or capacity edge can affect results; scalar/fallback
goldens and checked arithmetic pass. Any equal-work C comparison is
informational and must use the §11 contract; it is not a correctness or merge
gate.

## M4 — composite rank and global top-K

- Implement every SPEC §6 term, exact filename/path placement, score breakdown,
  total order, bounded heap, pagination, and accumulator revisions.

**Gate:** property tests compare every page against a full stable sort under
random iteration orders, offsets, limits, ties, and overflow edges; ranking
goldens include camel/snake and directory-vs-filename cases.

## M5 — bounded history models

- Implement deterministic fixed-point access decay, modification interpolation,
  fixed-capacity frecency/combo tables, stable IDs, and LRU eviction.

**Gate:** half-life/retention knots, out-of-order/future time, saturation,
eviction, and empty-query ranking are exact and machine-independent.

## M6 — pure chunked search

- Implement concrete search cursor/status/accumulator types, dual work limits,
  candidate evaluation/match/rank composition, and conservative refinement
  with survivor-plus-tail only for a complete retained set and an explicit
  full-rescan fallback otherwise.

**Gate:** arbitrary chunk partitions produce the same final result as one full
scan; mismatched cursor fields, sink epochs, revisions, capacity exhaustion,
and every stop reason are covered.

## M7 — F0 release gate

- Complete the Diátaxis tree, public API tables, benchmark report, and
  requirement trace.
- Run package, docs, Nix source-registration, and repository tests.

**Gate:** `sparkles:fuzzy` satisfies `PKM1`–`PKM5`, `PKQ*`, `PKR1`–`PKR3`,
and the library half of `PKR4`; hue P0 consumes it without private patches.

## Hue milestones

- **P0:** picker value state, `Finder`, files source, immutable query/corpus
  generations, fixed-capacity raw-job scheduling, real duration deadline,
  generation cancellation, global partial top-K, synchronous fallback, and a
  visible score-breakdown debug toggle. Owns `PIK1`–`PIK8`, `PKS1`, and the UI
  half of `PKR4`.
- **P1/P2:** shared GUI/TUI layouts and existing document-pipeline preview.
- **P3:** versioned bounded history persistence and recent source. Owns
  `PKR5`/`PKR6`; it uses the in-memory `PKR2`/`PKR3` model delivered by F0.
- Later picker milestones remain as listed in `picker.md`.

## Deferred profiles and optimizations

- ICU locale-aware folding/stemming and CJK/bigram analysis are follow-up
  analyzer packages behind the public seam.
- SIMD score backends require bit parity and M3-style measurement.
- A content bigram index remains `PKM6`; it is not a path prefilter.

## Verification commands

Fast iteration uses `dub test :base`, `dub test :event-horizon`,
`dub test :fuzzy`, and `dub test :hue`. Before a milestone is declared done,
run its checked/benchmark gates, the Linux allocation audit
(`dub test :fuzzy --config=allocation-audit`), the docs build/sidebar checks,
and `nix run .#ci -- --test --fail-fast`.
