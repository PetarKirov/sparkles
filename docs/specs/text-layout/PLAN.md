---
status: draft
owner: sparkles:text-layout
reviewed: 2026-10-04
---

# `sparkles:text-layout` — Delivery plan

## Abstract

This plan delivers paragraph composition in independently executable slices. A
font-independent rich paragraph plan comes first; physical text composition waits
for real font matching and shaping, not a placeholder provider. Later slices add
interaction and publication interfaces with actual-font and host-boundary evidence.

## Introduction

The [specification](./SPEC.md) owns the behavioral requirements, [testing](./testing.md)
owns acceptance scenarios and evidence, and [decisions](./decisions.md) owns the
architectural trade-offs. This is the sole milestone tracker for text-layout. Its
slices run from Stage 0 review through fixed-object plans (TL-M1), cell-grid
integration (TL-M2), shaped flow (TL-M3), interaction (TL-M4), publication
typography (TL-M5) and the alternatives/page/export handoff (TL-M6).

## 1. Progress and dependencies

Approval of the scope, contract review, feasibility, the package's existence and
font integration are separate gates; passing one does not imply another.

| Gate                                                | State                                                                       | Passes when                                                                                                  |
| --------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Owner approves owned text foundations and this seam | passed (scope discussion, 2026-10-04)                                       | —                                                                                                            |
| Independent contract review of the specification    | passed through TL-038 ([testing](./testing.md#independent-contract-review)) | a recheck covers TL-039–TL-058, split from reviewed text, and TL-052's cell-grid reordering rule             |
| Owner acceptance of the specification               | pending                                                                     | the owner records acceptance after Stage 0's exit gate                                                       |
| `libs/font` exists with real shaping                | absent                                                                      | [font M4](../font/PLAN.md#m4-shaping) and [font M7](../font/PLAN.md#m7-discovery-and-fallback) are delivered |
| `libs/text-layout` exists                           | absent                                                                      | TL-M1 delivers its first executable operation                                                                |

| Slice                                                   | State                                         | Delivery prerequisite                                                                           |
| ------------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Stage 0: contract review and bounded feasibility        | contract review complete; feasibility pending | Repaired-trace review recorded in testing.md; experiments require actual base/font capabilities |
| TL-M1: fixed-object plan and projections                | not started                                   | Stage 0; actual base rich primitive/solver APIs                                                 |
| TL-M2: analysis and cell-grid paragraph integration     | not started                                   | Actual base owned Unicode/cell behavior and conformance                                         |
| TL-M3: real shaped-flow paragraphs                      | not started                                   | Actual font M2/M4/M7; contextual measurement feasibility                                        |
| TL-M4: source/visual interaction and consumer cutover   | not started                                   | TL-M2/TL-M3 for each enabled mode                                                               |
| TL-M5: publication typography and object composition    | not started                                   | TL-M3/TL-M4; actual font publication capabilities                                               |
| TL-M6: alternatives, fragmentation and page/export seam | not started                                   | Actual base exact alternatives; TL-M5 for enabled typography                                    |

Package dependencies and delivery dependencies are different. The proposed package
imports base and font. TL-M1's fixed-object operations must execute without loading
font bytes or linking a fabricated engine; organizing those operations into a
font-independent module is permitted, but creating an empty `font` package to make
a build succeed is not. A shaped public configuration must not be released until
[font M4](../font/PLAN.md#m4-shaping) and
[font M7](../font/PLAN.md#m7-discovery-and-fallback) actually run. Font M2 supplies
instances/metrics; later publication data gates are additional, not substitutes.

Downstream consumers wait on these slices without becoming text-layout milestones.
[Design-system M9](../design-system/PLAN.md)'s proportional documentation runs
([GLY7](../design-system/glyphs.md)) wait on TL-M3, which itself waits on font M4
and M7; no interim `raylib-text` paragraph engine stands in for it.

## 2. Stage 0: agreement and experiments

**Scope.** Review SPEC boundaries and TL-001–TL-013 at operation level before the
first implementation slice; review contextual/publication contracts before their
slices. Keep the contract draft until an independent adversarial reviewer walks
success, failure and boundary traces and the owner records dispositions.

**Experiments.** These are planned, not results. Each names its question, its
bounded experiment and the criterion that decides it.

1. **Can a rich plan and projection be independently useful without fonts?**
   - _Experiment:_ execute fixed box/glue/kern/discretionary/anchor paragraphs
     through the actual base exact solver, then project selected branches into
     caller storage. Include a negative kern and overflow/capacity rejection.
   - _Criterion:_ exact output/source identities and the exhaustive small-model
     optimum agree, with no font invocation or unresolved fake text width.
     Otherwise, change the first-slice interface before implementation.
2. **Can candidate metrics equal realized line metrics with a real engine?**
   - _Experiment:_ once the font prerequisites exist, measure and realize Arabic
     joining, a Latin ligature, an Indic conjunct and discretionary replacements
     at several widths using the same engine request and exact-measure token.
     Compare to independent one-line reference shaping.
   - _Criterion:_ every selected candidate reproduces origins, advance and
     glyph/cluster identities. Any disagreement blocks an exact provider claim;
     investigate source, context and scale rather than widen tolerances.
3. **Does exact contextual search fit bounded workloads?**
   - _Experiment:_ measure candidate count, solver states, font calls and
     workspace for 1 KiB, 16 KiB and 256 KiB mixed paragraphs, at fixed and
     varying measures, on named hardware and toolchain with cold and reused font
     caches.
   - _Criterion:_ resource counters conform to the stated bounds and a proposed
     workload budget can be reviewed. Exhaustion is a valid failure, not a
     justification for undeclared greedy fallback.
4. **Are the publication handoffs sufficient?**
   - _Experiment:_ a throwaway host chooses among real composed alternatives,
     fragments at a line boundary, changes exclusion geometry and consumes
     glyph/source export records without a renderer handle.
   - _Criterion:_ the host can distinguish continuation, changed geometry,
     nonconvergence and synthetic/source text. An inability identifies a missing
     contract, not a reason to implement page policy here.

These spikes establish feasibility for the specified configuration only. Neither a
manually measured box nor a dependency fake counts as real-font evidence. Negative
results and minimized stimuli are retained in testing's evidence ledger before any
contract changes.

**Exit gate.** Ownership and non-goals agreed; first-slice success/failure/work-limit
traces independently reviewed; base interface compatibility checked; feasibility
results recorded; unresolved shaped gates acknowledged. Owner acceptance changes
contract status only after the review, not merely after this documentation merges.

## 3. TL-M1: fixed-object plans and projections

**Obligations.** TL-004–TL-013, TL-038–TL-044 and TL-046 for fixed-object content,
TL-032/TL-033 only to the
extent of base exact solver choices and already composed fixed-object lines.

**Deliverable.** Real executable paragraph validation, immutable plans, selected
branch projection, anchor placement and source-copy/projection export for fixed
objects. Use base's units, primitives and solver; no new width algorithm. A fixed
box-only optimization has value but must be labelled fixed-object mode, not shaped
text. Text, ruby or objects without resolved metrics return the specified missing
capability outcome.

**Acceptance.** Run scenarios P1–P5 and R1 from [testing](./testing.md). Exercise the
public plan → base solver → selected projection path with manually derived item
advances and source associations. Exact small graphs match a separately written
exhaustive enumerator including post-break continuations and path-dependent costs.
Byte-for-byte unchanged prior outputs are checked on every injected failure.

**Excluded.** Unicode text itemization, font fallback/shaping, glyph carets,
script-aware justification and claims of publication-grade text output.

## 4. TL-M2: owned analysis and cell-grid integration

**Obligations.** TL-001–TL-003, TL-005, TL-009–TL-015, TL-020/TL-022–TL-025,
TL-039–TL-044, TL-046–TL-048, TL-052–TL-054 and TL-056 for cell-grid mode, TL-037
for projected choices, and TL-036 for a selected cell consumer.

**Prerequisites.** Base delivers its owned codec, grapheme, script/line/bidi and
cell projection contracts with the versioned corpus and limits; dependency tests
alone are not this integration's proof. Audit all selected consumer helpers before
cutover, including measurement and source offset reconstruction.

**Deliverable.** Whole-paragraph analysis and cell-grid plan/result operations using
actual base APIs; source maps retain wide cells, controls and synthetic branches.
Font-independent cell occupancy remains useful without shaping. An optional ink
adapter, if included, requires real font prerequisites and does not redefine cell
geometry.

**Acceptance.** Run A1–A4, I1/I3 in cell-grid mode and C1. Exercise accent, CJK, flag,
ZWJ and long Indic/combining cases through a public consumer surface and observe
source hits and reflow, not just a dependency conformance runner. Reflow at a new
cell measure preserves snapshot-qualified logical identities.

## 5. TL-M3: real contextual shaped flow

**Obligations.** TL-001–TL-003, TL-006–TL-009, TL-014–TL-023, TL-037, TL-039–TL-041,
TL-045 and TL-047–TL-054.

**Prerequisites.** Real font M2, M4 and M7, including the refined contextual input,
flags, physical scale and whole-span fallback contracts. The font engine's Unicode
callbacks/version reconciliation and its error behavior must be recorded. A direct
layout-only HarfBuzz binding would be a second owner and cannot satisfy the gate.

**Deliverable.** Itemization over base analysis; font matching/fallback; exact
candidate provider for base; line realization with actual bidi and alignment;
physical metrics and independent cache keys. Exact and explicitly bounded alternative
search modes are reported distinctly. There is no “initial” ASCII-only shaper that
stands in for Arabic/Indic correctness.

**Acceptance.** Run A1/A3/A4, S1–S6 and R1 with a manifest of actual Latin, Arabic,
Hebrew, Indic, CJK and variable fonts. A public command composes and exports the
same paragraph at two widths and two device scales; independent one-line shaping
matches chosen candidate traces, bidi maps match manually derived fixtures, and
changing device scale alone leaves physical line choices unchanged. Validate
font-cache reuse and width-cache invalidation separately.

**Blocked release claims.** Until these checks run, no shaped path, RTL interaction,
contextual optimum, font fallback or renderer-neutral physical text layout is
verified. TL-M1 must not be renamed to satisfy this milestone.

## 6. TL-M4: interaction and clean consumer migration

**Obligations.** TL-004–TL-007, TL-013, TL-023–TL-025, TL-036, TL-055, TL-056.

**Deliverable.** Source/glyph/logical/visual mappings, caret affinity, selection and
raw-source versus visible-text copy. Migrate one actual consumer end-to-end, naming
its measurement, painting, hit-test and copy call sites in the evidence record.
Delete competing width/paragraph/source-position helpers in the migrated slice;
no aliases, dual layout trees or renderer-based fallback.

**Acceptance.** Run I1–I4 and C1. Render a real-font LTR/RTL mixed paragraph, select
across a ligature and bidi transition, copy logical source, resize and repeat with
source IDs unchanged and visual IDs invalidated. Record actual visual proof and
public hit-test outputs; pure geometry tests do not replace this surface check.

## 7. TL-M5: publication typography and inline composition

**Obligations.** TL-026–TL-031, TL-057 and the corresponding
TL-017/TL-018/TL-021/TL-023 consequences.

**Prerequisites.** Font exposes tested physical design metrics, safe elongation,
justification trial shaping, baselines/vertical data and optional ligature carets.
Vertical typography profiles wait for required vertical-orientation policy and real fonts;
math objects require real host-composed metrics, with font MATH parsing owned by
font. Absence must produce a named unsupported capability, not a fallback claiming
the requested feature.

**Deliverable.** Finite bounded typography profiles, explicit protrusion, baseline
unions, writing-mode transforms, ruby and inline objects with provenance. A full
mathematical composer is excluded; the font MATH interface and measured-object
handoff are mandatory prerequisites for math consumers, not delivered formulae.

**Acceptance.** Run U1–U5 against actual fonts and independent hand-derived layouts.
Show that every width-affecting adjustment participates in candidate measurement,
vertical caret geometry follows the transform, ruby/object extents participate in
line fitting, and unprovided capabilities reject without mutating prior output.

## 8. TL-M6: alternatives and publication handoff

**Obligations.** TL-032–TL-035, TL-058, and TL-004/TL-007/TL-009/TL-039 for all
handoff operations.

**Deliverable.** Real alternative layouts with objective provenance/completeness,
immutable fragments and revisioned continuations, finite host geometry feedback,
and glyph/source/logical-order export. Build only a bounded exercise host to prove
the boundary; do not make it a second page, document, math or PDF owner.

**Acceptance.** Run F1–F5 with actual shaped paragraphs. Enumerate small alternative
graphs independently; fragment/rejoin unchanged layouts; vary suffix geometry,
include an anchor/float exclusion feedback loop and observe fixed-point or
nonconverged outcome. An export exercise reconstructs logical text and recognizes
synthetic hyphens from actual records. No test substitutes a mocked layout summary
for real composition. Remove the exercise scaffolding after recording reproducible
proof, keeping behavior regressions at the real interface.

## 9. Release and handoff

Each accepted slice needs source revision or explicit dirty-tree snapshot, command,
configuration, actual execution count, artifacts and remaining gaps in
[testing](./testing.md). Tests alone do not prove an integrated surface: execute a
public paragraph operation or actual consumer at the changed path.

Do not add compatibility shims for proposed APIs. When a slice disproves a contract
assumption, update the owning contract and acceptance scenario before proceeding.
The next executable work for this tree is Stage 0 review and the real fixed-object
feasibility experiment once base's relevant implementation exists; shaped work
cannot begin by inventing the absent font library.
