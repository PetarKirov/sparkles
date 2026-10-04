---
status: draft
owner: sparkles:base
reviewed: 2026-10-04
---

# Owned text delivery plan

## Abstract

This plan delivers the [owned text contract](./SPEC.md) through executable slices:
owned codecs, reproducible data and unbounded graphemes first; complete Unicode
algorithms and source maps next; consumer cutovers and independent acceptance last.
It also tracks the shared [wrapping contract](./wrapping.md), without duplicating
its requirements. Passing a slice does not certify the rest of the target.

## Introduction

Encoding, table generation, and segmentation can be implemented and falsified
without a font subsystem. They are the first production slice because every later
measurement, transformation, and paragraph consumer needs a stable source model.
Consumer migration follows complete mechanisms, not replacement aliases that hide
old behavior behind a new module name.

This is the sole milestone tracker for the base text target. [Testing](./testing.md)
owns expected observations and evidence; [decisions](./decisions.md) owns choices.
All proposed operation names in the specification remain proposed until delivered.

## 1. State and gates

| Milestone                         | State                                    | Acceptance boundary                                                                                                             |
| --------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Stage 0: contract and scope       | scope approved; contract review complete | Independent reviews and repaired-trace rechecks are recorded in testing.md; integrated publication validation remains separate. |
| M1a: owned encoding               | not started                              | TXT-OWN1/3 and TXT-UTF1–12, through real prefix/stream/whole operations.                                                        |
| M1b: reproducible Unicode 18 data | not started                              | TXT-DATA1–6, offline regeneration, license retention, upgrade invalidation, and raw-data independent checks.                    |
| M1c: unbounded graphemes          | not started                              | TXT-SEG1–4, including chunk partitions and source-span behavior.                                                                |
| M2: complete Unicode algorithms   | not started                              | TXT-SEG5/6, TXT-BIDI1/2, TXT-ALG1, TXT-NORM1–3, TXT-CASE1, TXT-PROV1/2.                                                         |
| M3: cell policy and maps          | not started                              | TXT-CELL1–3, TXT-MAP1–4, TXT-CACHE1–3.                                                                                          |
| M4: wrapping mechanisms           | not started                              | Full wrapping.md scope; W1/W2/W3/W5 mechanisms, W4 under M5 cutover, W6 contextual integration above base.                      |
| M5: caller cutover and removal    | not started                              | TXT-MIG1/2 and real consumer integration; no competing owning helpers.                                                          |
| M6: independent acceptance        | not started                              | Complete promised suite, review, publication, and bounded-cost evidence.                                                        |

States refer to this target, not absence of useful existing code. Existing validators,
transactional UTF-16 converters, SIMD paths, generated Unicode 17 analysis tables,
and conformance/benchmark infrastructure are assets to migrate. They do not satisfy
an owned Unicode 18 claim by naming similarity. No new implementation or tests are
claimed by this documentation change.

Stage 0 publication and independent semantic review are separate gates. The owner
scope decision is recorded, but no reviewer identity, implementation signoff, or
verified evidence is inferred from that decision. Review must walk the malformed
stream, long-cluster, provenance, stale-cache, and public selection scenarios in
[testing](./testing.md).

## 2. M1a: owned codecs, operation by operation

M1a has no font or UI dependency. Use the existing modules
[utf8](../../../../libs/base/src/sparkles/base/text/utf8.d),
[utf16](../../../../libs/base/src/sparkles/base/text/utf16.d), and
[utf](../../../../libs/base/src/sparkles/base/text/utf.d) as seams. Preserve observable
strict-validation offsets and transactional UTF-16 behavior while extending the
owner to all specified modes and streams.

1. Add the scalar reference operation and structured statuses first. Strict UTF-8,
   UTF-16, and UTF-32 decoder/encoder tests must assert published byte/code-unit
   vectors, not encoder/decoder agreement. Establish one-token capacity failure
   without writes and invalid-scalar rejection before exposing optimized paths.
2. Replace `decodeReplacement`'s Phobos malformed path with owned maximal-subpart
   consumption. Exercise all invalid lead/second-byte windows and truncated-final
   examples; preserve source spans. Move opaque-byte analysis decoding to the same
   owner while retaining its distinct one-byte preservation behavior.
3. Implement stateless prefix conversion and caller-owned encoding carry. Exhaust
   every split of two-, three-, and four-byte scalars and surrogate pairs, then
   malformed/chunk-boundary examples. Assert the precise consumed/written/carry
   state at every feed, `outputFull` retry, empty feed, finalize, failed feed, and
   reset. A prefix test is not a stream-carry test.
4. Extend whole bounded conversion to the specified encoding pairs and modes,
   overflow/overlap errors, and `z` termination. Preflight must check the complete
   input before touching destination; exact-capacity and one-short tests assert
   unchanged sentinels and error precedence.
5. Feed the same operation-level cases through scalar, CTFE where supported, and
   existing runtime dispatch. Keep accelerated code only when exact statuses,
   offsets, memory bounds, and output are identical. Reuse
   [utf_memory_test](../../../../libs/base/src/sparkles/base/text/utf_memory_test.d)
   and the [UTF benchmark package](https://github.com/PetarKirov/sparkles/blob/d43f88a39191eaaa3c743f02a2b9dd49ef059442/libs/base/bench/utf/README.md).
6. Migrate all base codec consumers off `std.utf` and transitive auto-decoding in
   this slice, removing obsolete decoder bodies rather than keeping a legacy
   mode. Delete tests that pin incidental Phobos malformed-byte consumption rather
   than re-pinning those assertions to the replacement implementation. Independent
   comparisons may remain isolated as supplementary diagnostics, not expectations.

Acceptance uses scenarios C01–C10 in testing.md, real bounded buffers, and a small
executable conversion driver which prints and asserts decoded tokens, source spans,
and each streaming result. Permanent regressions retain plausible failure paths;
throwaway driver and allocations are not production APIs. Run the target operations
before reporting delivery, and record actual selected test counts. No invented test
filter is a completion command: add deterministic named cases through the existing
runner and record the command which discovers and executes them.

## 3. M1b: one manifest-driven property pipeline

M1b can share M1a work on explicit byte parsing; it does not wait for shaping.
Refactor [gen_unicode_tables.d](../../../../libs/base/tools/gen_unicode_tables.d)
into the owner rather than introducing an unrelated generator convention.

1. Fetch final Unicode 18 inputs and tests from versioned paths, record their actual
   SHA-256 values in a reviewed manifest, and pin the algorithm editions from SPEC.
   Include the actual license artifact/hash and required redistribution attribution.
   Keep acquisition separate from the offline parser/emitter, and prove a release/
   schema upgrade rejects earlier cached identities rather than mixing tables.
2. Parse ASCII data fields through explicit byte operations. Implement `@missing`,
   ranges, aliases, First/Last pairs, Hangul formulas, and conflicts as independent
   cases. Remove generator dependencies on `CodepointSet`, compiler categories,
   `isWhite`, and auto-decoding Unicode iterators.
3. Generate the property families needed by the complete scope, retaining existing
   analysis lookup seams where sound. One manifest may emit multiple modules;
   generated metadata must never pretend a Phobos-probed table is Unicode 18.
4. Regenerate in two empty output directories with supported toolchains/locales,
   compare bytes, and query the full scalar domain against raw-source interpretation.
   Hash mismatch, missing input, and malformed source must leave installed output
   unchanged. Run entirely offline after initial fetch.
5. Retire [gen_grapheme_tables.d](../../../../libs/base/tools/gen_grapheme_tables.d)'s
   compiler-probe pipeline and compiler-version cache gates when its consumers
   move to owned tables. Remove unused generated constants/modules, not aliases.
   Update conformance configuration to one manifest identity rather than two
   compiler-versus-width Unicode axes.

Acceptance uses D01–D06, actual generated artifacts, and the existing generator CLI
with explicit local source/output arguments. Record the final implemented command,
manifest revision, all hashes, and outputs; command examples for the old six-file
pipeline alone cannot certify the enlarged pipeline. No SHA-256 is fabricated in
this plan. Unicode final-artifact availability is evidenced in decisions.md; the
missing manifest is implementation work, not a missing external release.

## 4. M1c: forward and streaming extended graphemes

M1c requires M1a decoding and M1b GCB, Extended_Pictographic, and InCB properties.
It changes [grapheme.d](../../../../libs/base/src/sparkles/base/text/grapheme.d),
not just a width cache around Phobos.

1. Implement the full UAX #29 break-state transitions with borrowed source spans;
   manually trace CRLF, Hangul, Prepend, SpacingMark, Extend, EP/ZWJ, RI parity,
   and revised Unicode 18 GB9c before relying on generated cases.
2. Remove the decoded 16/32-code-point window as a semantic limit. Long runs must
   consume finite state, not a cluster-sized copied scalar array. Preserve styled
   escape interpretation in its adapter; plain segmentation owns Unicode input.
3. Add streaming boundary events with explicit carry, delayed cluster completion,
   retryable event backpressure, and caller source-retention requirements. Reuse
   whole-source corpus expectations across every small chunk partition.
4. Run all Unicode 18 GraphemeBreakTest rows without a default-algorithm allowlist,
   including the historical Indic failures. Add long synthesized traces because
   official corpora alone cannot disprove a fixed-window cap.
5. Cut over base width/wrap/analyzer consumers to the owned grapheme owner and
   remove `graphemeStride`, stale singleton compiler probes, and duplicated partial
   boundary rules. Default grapheme conformance must not be conflated with terminal
   width compatibility.

Acceptance uses G01–G05, conformance layer 0 configured for Unicode 18, and a real
scanner driver displaying the source byte spans of long/chunked examples. Existing
harness command shape is recorded in testing.md; delivery must report the actual
post-cutover command/configuration and counts, not the historical Unicode 17 run.

## 5. M2–M4: complete mechanisms

M2 has no external font prerequisite. It delivers complete default word/sentence
boundaries and UAX #14 opportunities, UAX #9 paragraph/line operations, all four
normalization forms, full/default/selected-locale casing, exact provenance, and the
bounded analysis cutover. These are not optional expansions of M1. Refine each
streaming transform's workspace and publication operation before its implementation;
acceptance includes all relevant official corpora, contextual casing examples,
long combining sequences, and non-monotonic provenance traces A01–A06.

M3 delivers the named `terminalKitty` revision-1 local profile using owned Unicode
properties and cell fitting/maps. It preserves the delivered width algorithm while
removing compiler-data skew. Pinned kitty/Ghostty comparisons classify interoperability
differences; they are evidence gates for those adapters, not external prerequisites
for the pure profile or maps. Complete scalar/UTF-16/grapheme/cell maps and stale-cache
behavior before integrating public selection; scenarios P01–P06 and X01–X03 own
acceptance. A storage maximum produces exhaustion without redefining a boundary.

M4 delivers the entire [wrapping contract](./wrapping.md). Its first cell slice
reuses owned measurement, complete opportunities, source spans, and affinity. Its
rich generic paragraph solver slice exercises exact state, boxes/glue/kerns/penalties,
discretionaries, anchors, fit objectives, and exhaustion with independent small
models; it must not add a font dependency to base. Contextual shaped candidates,
visual maps, mathematical composition, and publication are consumers above base.
The wrapping document's W1 cell, W2 balanced, W3 measurable Knuth–Plass, and W5
hyphenation-resource slices fall under M4 mechanisms. W4 caller/table cutover belongs
to M5; W6 actual contextual/font integration is accepted by the text-layout owner
after its real font prerequisites. All are not started. Its operation and scenario
requirements govern acceptance; this tracker must record executed slice results,
not a second milestone-progress tracker elsewhere.

## 6. M5: concrete clean cutovers

Each row is a migration boundary, not evidence of delivery. All listed paths exist;
old module names in comments are not locations to edit.

| Consumer surface                                                                                         | Required cutover                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libs/base/src/sparkles/base/text/{utf,utf8,utf16,analysis,width,grapheme,wrap,case_style}.d`            | Owned codecs/properties/breaks; remove malformed Phobos decoder, category CTFE data, partial word rules, and stale cached probes. Preserve explicit ASCII casing where that is the declared operation.                                                                                               |
| `libs/ui/src/sparkles/ui/{geometry,wrap,layout,display_list,canvas,cmd_buffer}.d`                        | Replace `cellsOf`/`takeCells` code-point authority and competing wrapping with base measure/fit/plan; migrate every caller and remove obsolete owning functions. Rendering extent and clipping must use the same profile as hit mapping.                                                             |
| `libs/ui/src/sparkles/ui/components/table/{layout,widgets,render}.d`                                     | Unify string/widget widths and wrapping; replace `columnToByte` with affinity-aware grapheme/cell maps. Selection must not land in accents, flags, or wide interiors.                                                                                                                                |
| `libs/doc-view/src/sparkles/doc_view/{viewer_model,dsv_view,table_select,ansi_model,ansi_decode,pane}.d` | Use relocated doc-view paths, not historical `apps/hue/gui_*` names. Carry source spans through ANSI fences/DSV and table selection; source bytes copied from highlighted text must match the map. Replace scalar-stride editing where the consumer promises grapheme editing.                       |
| `libs/tui/src/sparkles/tui/{cell,render,input,terminal}.d`                                               | Put whole clusters and profile advances in the grid; replace byDchar/codepoint advance. Inline cell storage must use owned overflow storage or explicit complete-render exhaustion, never silently truncate a long grapheme. Negotiate/record mode 2027 consistently with terminal profile evidence. |
| `libs/android/src/sparkles/android/{clipboard,http,intents,jni,text_input}.d`                            | Owned UTF-16 conversion and explicit native modified-UTF-8 distinction; verify payload versus terminator counts and source/UTF-16 map units.                                                                                                                                                         |
| Base examples, core-cli/table consumers, source-view integration, and remaining repository callers       | Audit direct and transitive auto-decoding, cell counts, and coordinate assumptions after the named boundaries; migrate all production callers, not only the observed failing example.                                                                                                                |

The source-view/core-cli integration is a caller inventory task, not a claim that
all its paths import Phobos. Inspect actual callsites when the slice starts.
Consumer-specific adapter ownership and source-view parsing remain unchanged unless
obsolete competing text semantics are being removed. No font fallback or stub is
permitted to masquerade as shaped rendering. Actual font M4/M7 delivery is a
prerequisite for shaped text-layout integration, not for base cell/Unicode work.

M5 acceptance launches the real table/UI/TUI/doc-view surfaces, performs fit, hit,
drag, and copy actions using shared Unicode scenario inputs, and observes byte
ranges, widths, and long-cluster preservation. GUI configurations unavailable to the
implementer remain unverified, with a named prerequisite, not silently replaced by
pure model tests. Existing implementation-detail tests that assert code-point width
or copied strings instead of the intended contract must be removed, not re-pinned.
Keep behavior regressions at public boundaries.

## 7. M6 and handoff

M6 requires independent review of every promised obligation, full requested corpus
execution, scoped platform evidence, generator reproducibility, memory-bound checks,
and documented benchmark setup/comparison. No numerical speed promise supersedes
correctness; record performance regressions and decide with actual workloads.
Update delivered usage docs and the changelog only when corresponding implementation
has landed. Remove temporary drivers, stale helpers, old aliases, and obsolete
policy explanations during each completed cutover.

### Resume boundary

- Contract scope: approved on 2026-10-04; draft target contracts have completed
  independent adversarial review with dispositions in testing.md. Publication
  checks and PR review remain separate from implementation acceptance.
- Implementation target: all milestones not started; historical observations in
  testing.md are baselines only.
- Checked material: existing codec, generator, analysis, grapheme, width, conformance,
  benchmark, UI/table, relocated doc-view, and TUI source sections inspected for
  contract seams. This documentation-only batch runs no implementation validation.
- Next executable action after specification review: write C01/C02 strict and
  maximal-subpart regressions in the existing runner, confirm intended failure of
  the owned replacement requirement, then implement M1a without production Phobos.
- External dependencies: none for M1a/M1b/M1c or pure M3. Terminal interoperability
  evidence requires pinned real engines; shaped integration above base requires
  actual font M4/M7. Missing review/evidence is an unmet gate, not a fabricated pass.
