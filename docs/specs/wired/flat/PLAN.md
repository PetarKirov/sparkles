---
status: draft
owner: sparkles:wired
reviewed: 2026-10-16
---

# `sparkles.wired.flat` — Delivery plan

This is the single milestone tracker for the [Flat specification](./SPEC.md).
Each milestone is independently green: the repository builds, `dub test
:wired` passes, formatting is clean, and no later milestone is needed to make
an earlier commit valid. FL-numbers are local to this format and do not replace
the base M-series, the expressiveness E-series or the SDL S-series.

## Progress

| Slice | Obligations                                                   | Status      | Required result                                                          |
| ----- | ------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------ |
| FL0   | Scope, vocabulary, oracles, the O10 spike, publication        | in progress | Reviewed draft; `WFL2` feasible (O10 spike); owner accepts scope, issues |
| FL1   | WFL1–WFL22, WFL25–WFL27, WFL41, WFL51–WFL56 for fixed records | planned     | Layout proof and bounded in-place and per-leaf reads of fixed records    |
| FL2   | WFL23, WFL24, WFL28–WFL40, WFL42, WFL55 for dynamic members   | planned     | Arrays, offsets, conditions, unions, validation; the OpenType set        |
| FL3   | WFL43–WFL50                                                   | planned     | Arena header, opening, builder, deterministic output                     |
| FL4   | WFL9, WFL10, WFL44 at the real boundary                       | planned     | Catalog and atlas cache built by Nix, read in place on Android and Linux |

## Delivery dependencies

```text
FL0 specification review + O10 spike
  -> FL1 layout proof + fixed records
  -> FL2 dynamic members + OpenType set     (needs O3: @WireCheck; O4: fontTools)
  -> FL3 arena + builder
  -> FL4 first consumer                     (needs O1: byte source; O2: content key;
                                             font MS S1/S3 as the producer of records)
```

No milestone adds a dependency from `sparkles:wired` to `sparkles:font`. The
OpenType descriptions of FL2 live in `sparkles:wired`'s tests, with fonts
reached through flake inputs as [AGENTS.md](../../../guidelines/AGENTS.md#flake-input-store-paths)
prescribes. Moving `sparkles:font` onto these descriptions is excluded from
this plan; it needs its own milestone in the [font plan](../../font/PLAN.md).
Encoding D values whose size lives only in a stream, as cerealed does, and
bit-granular packing ([O9](./open-issues.md#o9-sub-byte-fields-and-stream-codecs))
are excluded from every milestone.

## Evidence common to every milestone

- **Compile-time rejections** are tested with a `static assert` that
  `__traits(compiles, …)` is false over a fixture type per rejection rule, and
  one single-file example per rule whose expected compiler message fragment
  (type, field path, fact) is checked by `ci --verify`. A rejection without a
  message test is unverified.
- **Attributes** are asserted per acceptance description: attribute traits
  over every view accessor, `flatDecode` and `validateFlat`, plus a
  `@safe pure nothrow @nogc` unittest that drives them.
- **Hostile input** runs under `DC=ldc2 nix run .#ci -- --test-sanitize`
  (ASan): a deterministic mutation corpus per fixture (every truncation length,
  every single-bit flip of the fixed part, offsets and counts rewritten to 0,
  1, the region length, and the maximum of their width). The oracle is the
  contract, not a golden: no crash, no `RangeError` or assertion, every result
  either a value or a `FlatError` whose offset lies within the region or names
  its end. Seeds and minimized failures are kept as fixtures.
- **Independence.** A round trip through the builder never stands alone as
  evidence for a reader requirement: builder and reader can share a bug.
  Reader requirements are established by bytes written by hand or by another
  implementation.
- **Targets.** Layout and digest tests run on x86_64 and, through the cross
  toolchains of the dev shell, compile for i686, aarch64 and armv7; their
  printed `flatLayoutOf` and `flatLayoutDigest` values are compared.

## FL0: Specification, review and the O10 spike

Write SPEC, PLAN and open issues; run a cold read of the abstract and
introduction ([spec prose](../../../guidelines/spec-prose.md#test-the-opening-with-a-cold-read));
review the specification adversarially, with worked traces, by a reader other
than the author (see [Review](#review)); record the owner's dispositions of
[open-issues](./open-issues.md).

The O10 spike answers whether the layout can walk `T` in lockstep with
`wireSchemaOf!(Flat, T)` as `WFL2` requires: a throwaway walker over
`Head`, `CoverageFormat1` and `ItemVariationData` that prints each schema node
index next to the D field it names, its `offsetof`, and an alias-carrying
attribute (`@FlatCount!(narrowCount, …)`) re-read from that field. It also
checks that a rejected type reaches Flat's message before the schema builder's
`static assert`. Decision criterion: all three walk without a parallel
description of the type; otherwise `WFL2` is revised before FL1 starts.

**Spike result (2026-10-17): feasible, with no change to `sparkles:wired`.**
A single-file program outside the repository, built with
`dub run --single flat_spike.d` against this worktree's `sparkles:wired`, ran
with LDC 1.42.0 and DMD 2.112.1 on x86_64 with identical output. It declared
`struct Flat {}`, checked admissibility over `T.tupleof` first, then built
`wireSchemaOf!(Flat, T)` and walked `T` beside it with `WireWalk.child`, the way the JSON codec's `decodeNative` does. Observed:

- `wireSchemaOf` accepts the unknown `Flat` marker unchanged. An `E[0]`
  member reifies as a `staticArray` node of length 0 with an element child,
  and nested records as `aggregate` nodes, so field ordinals map to child
  edges one to one (an `hhea`-like record of 17 nodes, `head`-like of 19,
  Coverage-like of 5, a nested `Point` of 6).
- Offsets, sizes and canonical alignments come from the declaration each node
  names: `head.created` at 20 with alignment 8, so the record is packed;
  `hhea` and the Coverage record natural; `struct { ulong a; uint b; }` and
  `struct { uint a; ulong b; }` rejected.
- The schema keeps the alias-carrying `@FlatCountFn!(narrowCount, …)` only as its spelling; re-reading `__traits(getAttributes, …)` on
  the field reached the alias and called it (`narrowCount(10, 3) == 7`).
  Value attributes (`@FlatCount("glyphCount")`, `@FlatEndian`) are read the
  same way.
- Running Flat's check first wins the diagnostic: a pointer field reports
  `Flat: WithPointer.p: int* is not a Flat leaf …`, where `wireSchemaOf`
  alone reports `wired: unsupported schema type int* under format Flat` with no
  path. A function-local struct with a method reports that `Local` carries a
  context pointer, which the schema alone would have hidden: its root node has
  1 child for a `tupleof` of 2. A local struct without methods has no context
  pointer and is correctly admitted.
- A digest over the walked entries without names was equal for a record and a
  copy with every field renamed.

Limitations: the lockstep sanity check compared each node's wire key with the
field identifier, which `@WireName` or `@WireCase` would break, so the
implementation pairs by ordinal only. The spike covered neither `Offset`
targets, `FlatTagged` nor recursion. Its code is kept in the session's
scratch directory, not in the repository. The reviewer then cross-compiled the
spike's checker with LDC 1.42 for x86_64, i686, armv7 and aarch64: the digests
of the `hhea`-like, `head`-like, Coverage-like and nested records were
identical on all four, and both `struct { ulong a; uint b; }` and
`struct { uint a; ulong b; }` were rejected on all four.

Gate: owner acceptance recorded in the pull request; the spike's result
recorded in [O10](./open-issues.md#o10-alias-carrying-attributes-through-the-shared-schema);
publication checks (`ci --check-docs-sidebar`, `--check-spec-evidence`,
`--check-glossary`, `--check-vcs-urls`, prettier) green. Publication checks are
not semantic acceptance.

## FL1: Layout proof and fixed records

**Deliverable.** `sparkles.wired.flat` with `Flat`, the attributes needed by
fixed records (`@FlatEndian`, `@FlatConst`, `@FlatPad`, `@FlatBits`,
`@FlatLayoutPin`), `FlatU24`/`FlatI24`, `flatLayoutOf`, `flatAlignOf`,
`isFlatRecord`, `isFlatInPlace`, `FlatView` with fixed-part accessors and
`native`, `flatDecode`, `flatLayoutDigest` and `FlatError`.

**Acceptance scenarios and oracles.**

| Scenario                                                                                                                                                                                                                                                                                                                                                                                                        | Oracle                                                                                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `head` and `hhea` prove to 54 and 36 bytes, with every field offset as the OpenType tables list; `Head` is packed, `Hhea` natural                                                                                                                                                                                                                                                                               | The offsets transcribed by hand from the OpenType `head` and `hhea` pages, as constants in the test             |
| A hand-built `head` decodes every field through accessors and `flatDecode` on a little-endian host                                                                                                                                                                                                                                                                                                              | A byte array written field by field from chosen values; the values are the expected result                      |
| `isFlatInPlace` is false for `Head` under either forced byte order, and for `Hhea` true only with `Endian.bigEndian` forced                                                                                                                                                                                                                                                                                     | The rule of `WFL7`, applied by hand                                                                             |
| A naturally aligned little-endian twin of `hhea` is read through `native` and through accessors, with equal results                                                                                                                                                                                                                                                                                             | Hand-built bytes; the in-place branch runs because the twin's order is the host's                               |
| `native` on the twin at a start one byte past an aligned address reports `misaligned`; its accessors still succeed                                                                                                                                                                                                                                                                                              | A buffer sliced at offset 1 of an aligned array                                                                 |
| Accessors for 2-, 4- and 8-byte leaves of host and foreign order compile to one load, plus one byte swap for the foreign order (a rotate by 8 for 16 bits; a move to an FP register allowed for `float` and `double`)                                                                                                                                                                                           | The assembly LDC emits for x86_64 and aarch64 under the `checked` build type, matched by a codegen test         |
| Implicit padding; `struct { uint a; ulong b; }` and `struct { ulong a; uint b; }` and `struct { uint n; ulong[0] xs; }` rejected alike on i686 and x86_64; a nested record with a dynamic member that is not its parent's last field; a static array of two records with dynamic members, even as the last field; pointer and slice fields; a context-carrying nested struct; missing or conflicting byte order | Compile-fail fixtures with expected message fragments, built for both targets where the rule concerns alignment |
| Layout and digest are equal on x86_64, i686, aarch64 and armv7, and the digest changes after reordering, retyping or re-ordering bytes of a field, but not after renaming one                                                                                                                                                                                                                                   | Printed values compared across targets; the reorder, retype, re-order and rename fixtures                       |
| A pin history whose last digest is stale, whose versions do not increase, or that repeats a digest fails to compile; the first prints the computed digest                                                                                                                                                                                                                                                       | Compile-fail fixture                                                                                            |
| Every truncation of `head` from 0 to 53 bytes reports `truncated` at offset 0 with the needed length                                                                                                                                                                                                                                                                                                            | The contract (`WFL11`, `WFL51`)                                                                                 |
| `@FlatConst` mismatch on the magic number reports both values and renders the path `$.magicNumber`                                                                                                                                                                                                                                                                                                              | The contract (`WFL25`, `WFL56`)                                                                                 |
| A `bool` leaf holding 2 and an `enum` leaf holding a non-member value report `invalidValue`                                                                                                                                                                                                                                                                                                                     | Hand-built bytes                                                                                                |
| Signalling-NaN `float` and `double` bit patterns survive a swapped read                                                                                                                                                                                                                                                                                                                                         | The bit pattern written by hand                                                                                 |
| `FlatError.sizeof <= 160`; a path of 10 hops renders its first and 7 innermost with `…` between                                                                                                                                                                                                                                                                                                                 | A static assertion; a fixture nested 10 arrays deep                                                             |
| Mutation corpus over `head` and `hhea` under ASan                                                                                                                                                                                                                                                                                                                                                               | The common hostile-input oracle                                                                                 |

**Excluded.** Dynamic members, offsets, unions, eager validation, the builder.
No available machine is big-endian, so `native` on a big-endian host is never
compiled and the swapped path never runs for a little-endian description; the
evidence for `WFL16` and `WFL17` stays `partial`
([O6](./open-issues.md#o6-no-big-endian-host)).

## FL2: Variable-length members and the OpenType set

**Deliverable.** `@FlatCount`, `@FlatBytes`, `@FlatRest`, `FlatArray` and
`FlatSeq`, `Offset` with the three bases and null handling, `@FlatSince`,
`@FlatPresentIf`, `FlatTagged`, `FlatSelect`, `@FlatParam` and `@FlatArgs`,
Flat use of `@WireCheck`, `validateFlat` with `FlatLimits` and the error sink,
and the four OpenType descriptions of SPEC §6 in tests.

**Acceptance scenarios and oracles.**

| Scenario                                                                                                                                 | Oracle                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Coverage format 1 and 2 fixtures: glyph arrays, range records, empty arrays, unknown format 3, `get!` of the other variant               | Hand-built bytes; `unknownVariant` carrying 3, and for the wrong `get!`                                                                                                                |
| Every Coverage table reachable from `GSUB`, `GPOS` and `GDEF` of the bundled fonts lists the same glyphs                                 | `sparkles:font`'s coverage reader, and fontTools `ttx` dumps recorded as goldens by a committed command ([O4](./open-issues.md#o4-fonttools-is-not-in-the-dev-shell))                  |
| `ItemVariationData` fixtures with `LONG_WORDS` clear and set, `wordCount` 0, equal to and greater than `regionIndexCount`, `itemCount` 0 | Hand-built rows; the expected deltas written by hand; `checkFailed` for the greater case, as HarfBuzz's sanitize rejects it                                                            |
| Row `i` of `deltaSets` starts at `6 + 2·regionIndexCount + i·rowSize`                                                                    | HarfBuzz's row size, `(wordCount + regionIndexCount) · (longWords ? 2 : 1)`, cited in SPEC §6                                                                                          |
| Every `ItemVariationStore` reachable from `HVAR`, `MVAR` and `GDEF` of the bundled variable fonts yields the same deltas                 | fontTools `ttx` goldens; end to end, advance widths at sampled coordinates through `HVAR` against `hb_font_get_glyph_h_advance` via `sparkles:font-oracle`                             |
| A description of `OS/2` version 5 opens tables of versions 0–5 and reads exactly the fields each version has, the rest absent            | Hand-built fixtures per version, a version-0 table being 78 bytes; fontTools goldens for bundled fonts                                                                                 |
| `@FlatSince` thresholds that decrease are rejected at compile time                                                                       | Compile-fail fixture                                                                                                                                                                   |
| A non-empty range starting exactly at the region's end, and one starting past it                                                         | The contract: `truncated` and `badOffset` respectively                                                                                                                                 |
| Offsets outside the region, overflowing offsets, a zero non-nullable offset that points at its own record                                | The contract: `badOffset` with the offset's position; the self-reference stops at `maxDepth` during validation                                                                         |
| Amplification: a 1 KiB input whose offsets share targets to describe a tree of 2^40 extents                                              | `limitExceeded` naming `traversalBytes` within a bounded number of steps                                                                                                               |
| `deltaSets` with both counts 0 and `itemCount` 60,000, in a 1 KiB input                                                                  | Indexing any row is constant time; validation charges a byte per row, so it passes under the default budget of 65,536 and stops with `limitExceeded` under an explicit budget of 1,000 |
| `validateFlat` with default limits over every bundled font's `GSUB`, `GPOS`, `GDEF` and `HVAR`                                           | Every table is accepted; the largest traversal charge and depth per table are recorded against the defaults ([O7](./open-issues.md#o7-provisional-validation-limits))                  |
| An error inside `ItemVariationData` reached through the store renders `$.itemVariationDataOffsets[3].regionIndexes`                      | The contract (`WFL56`): two hops across one followed offset                                                                                                                            |
| A sequential array and a `@FlatRest` whose element has extent zero                                                                       | `invalidLength`; the range never stalls                                                                                                                                                |
| Accumulating validation lists every failure of a fixture with three independent faults, each with its path                               | The three faults, chosen by hand                                                                                                                                                       |
| Mutation corpus over every fixture above and one real table of each kind, under ASan                                                     | The common hostile-input oracle                                                                                                                                                        |

**Excluded.** The arena header and builder; any change to `sparkles:font`.

## FL3: Arena header and builder

**Deliverable.** `@FlatArena`, the header record, `FlatSpan`, `FlatString`,
`openFlatArena`, and `FlatBuilder` over growable and fixed storage.

**Acceptance scenarios and oracles.**

| Scenario                                                                                                                                                                                                 | Oracle                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| A two-record arena with a string table is built and compared byte for byte                                                                                                                               | The expected file written by hand, header included                                               |
| Round trip: generated catalog-shaped values are built, opened and read back                                                                                                                              | The generated values, from recorded seeds                                                        |
| Determinism: the same calls twice give identical bytes; gaps and pads are zero                                                                                                                           | Byte comparison                                                                                  |
| Each header check fails alone, in the order of `WFL44`; a 10-byte unrelated file is `notThisFormat`                                                                                                      | Hand-edited headers, one field each                                                              |
| The golden file of each test arena's current version opens, and older versions' goldens report `unsupportedVersion`; rewriting the last pin in place makes the current golden fail with `layoutMismatch` | Golden files committed when each pin was added (`WFL54`)                                         |
| Opening a valid arena does not depend on its size                                                                                                                                                        | Opening a 1 MiB and a 1 KiB arena performs the same header checks; validation is a separate call |
| A record needing 8-byte alignment under `@FlatArena`, and a root without `@FlatArena`                                                                                                                    | Compile-fail fixtures                                                                            |
| An arena opened from a buffer at a 4-byte but not 8-byte boundary reads in place                                                                                                                         | A buffer sliced at offset 4 of an 8-aligned array                                                |
| A link backwards from its base, a link too far for its width, foreign and unwritten slots                                                                                                                | The contract: `offsetOverflow`, `invalidSlot`                                                    |
| Exhausted fixed storage, then a retry into larger storage                                                                                                                                                | `limitExceeded` with the size needed; the builder's bytes unchanged by the failed call           |
| A string with invalid UTF-8 through the plain and `checked` accessors and through validation                                                                                                             | Plain returns the bytes; `checked` and validation report `invalidUtf8` at its position           |
| Mutation corpus over the built arena, under ASan                                                                                                                                                         | The common hostile-input oracle                                                                  |

## FL4: First consumer: catalog and atlas cache

**Deliverable.** The face catalog (font MS S1) and glyph-atlas cache (S3) as
arena formats with pinned layouts; the Nix precompute step (S4) writing them
with `FlatBuilder`; the app reading them in place through the byte source of
[O1](./open-issues.md#o1-the-byte-source), from an mmapped file on Linux and an
uncompressed APK asset on Android.

**Acceptance.** The precompute step is reproducible: two independent builds
produce identical files (`nix build --rebuild`). The Android emulator and an
arm64 phone open the asset without copying it, verified by the byte source's
own evidence that the slice points into the mapping. A corrupted, truncated or
stale file is rejected with the structured error and the consumer falls back to
building the data, verified by the consumer's test. The S0 harness records the
time to open the catalog; this plan claims no performance threshold until the
startup slice's S5 sets one.

**Excluded.** On-device cache invalidation policy beyond the header checks,
which belongs to the startup slice.

## Review

### First adversarial review

On 2026-10-16 an independent reviewer walked the first draft of `SPEC.md`,
`PLAN.md` and `open-issues.md` against `sparkles.wired.schema`,
`sparkles.wired.policy`, the JSON and SDL codecs, `sparkles.font.bytes` and
`parsing.md`, with probes compiled by LDC 1.42 and DMD 2.112 for x86_64 and
cross-compiled for armv7, aarch64 and i686. The probes covered the emitted
loads of `align(1)` records, the sizes of structs whose only fields are
zero-length arrays, alignment of 64-bit fields on i686, `wireSchemaOf` and
`wireSchemaDigest` on Flat-shaped types, and the code of byte-assembled reads.
It found 3 blockers, 10 major and 7 minor defects and judged the draft not
ready for FL1. Its findings and their dispositions:

| Finding                                                                                                                                                                             | Disposition                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blocker: `ref const(T)` over an `align(1)` record is undefined behaviour; `T.alignof` is 1, LDC loads `head.created` at offset 20 with 8-byte alignment, and armv7 faults           | Fixed. `WFL7` admits only naturally aligned records; `WFL16` checks `flatAlignOf!T`; packed records are accessor-only; new `WFL52` states the one-load rule per leaf, kept as an FL1 codegen test.                                                                   |
| Blocker: a struct with only `E[0]` fields has size 1, so `WFL3` rejected `DeltaSet`                                                                                                 | Fixed. §2.1 defines the fixed part and declared size; `WFL3` accepts size 1 for an empty declared size.                                                                                                                                                              |
| Blocker: the fixed part ran to `T.sizeof`, so a version-5 `OS/2` description rejected a valid version-0 table; absent fields' decoded value and non-monotone absence were undefined | Fixed. The fixed part excludes conditional fields; `WFL15` checks only it; `WFL37` range-checks conditional fields on read, requires non-decreasing `@FlatSince` thresholds, and makes a field after an absent one absent; `WFL20` decodes absent fields as `.init`. |
| Major: the shared schema has no offsets or typed attributes, and its builder's message wins over Flat's, so `WFL2` was not implementable as written                                 | Fixed. `WFL2` walks `T` in lockstep with schema node indices, as JSON and SDL do, and runs Flat's checks first; the O10 spike moves into FL0.                                                                                                                        |
| Major: `wireSchemaDigest` hashes names and omits offsets and offset targets, with no rule for recursion                                                                             | Fixed. `WFL41` defines a Flat-specific serialization with targets, enum values not names, and back-references.                                                                                                                                                       |
| Major: per-field alignment is target-dependent, so `struct { uint a; ulong b; }` proved on i686 and failed on x86_64                                                                | Overstated; completed by recheck N1 and N2. Canonical alignment in §2.1; `WFL6` excludes `alignof`; new `WFL53` rejects such a struct on every target.                                                                                                               |
| Major: an FL1 scenario read big-endian bytes in place on a little-endian host                                                                                                       | Fixed. FL1 tests the trait with the forced parameter and the in-place branch with a little-endian twin of `hhea`.                                                                                                                                                    |
| Major: zero-extent sequential and rest elements stall, and zero-stride arrays let a count drive unbounded validation                                                                | Fixed. `WFL32` and `WFL33` make zero extents `invalidLength`; `WFL24` charges `max(extent, 1)` per element.                                                                                                                                                          |
| Major: result types of accessors, arrays, sequences and unions were unstated, and `WFL17` conflicted with O5                                                                        | Fixed. New `WFL55` tabulates every read's result; fixed-part reads return plain values; O5 narrows to the remaining fallible reads.                                                                                                                                  |
| Major: path storage was unspecified and an inline path would bloat every result                                                                                                     | Overstated; completed by recheck N4. New `WFL56`: a layout index plus at most 8 array indices, at most 128 bytes, rendered on demand.                                                                                                                                |
| Major: nothing forced a version bump when a layout changed; cerealed-like value codecs and bit packing were neither in nor out of scope                                             | Overstated; completed by recheck N5. New `WFL54` pins; the introduction, FL plan and [O9](./open-issues.md#o9-sub-byte-fields-and-stream-codecs) exclude both.                                                                                                       |
| Minor: a non-empty range starting exactly at the end had no stated kind                                                                                                             | Fixed in `WFL11`: `truncated`.                                                                                                                                                                                                                                       |
| Minor: the bit-range mask overflowed for widths of 32 and more; rule results and bit-range types were loose                                                                         | Fixed in `WFL27` (computed in `ulong`, width 64 special-cased, leaf-typed values), `WFL29` (`FlatResult!ulong` only) and `WFL40`.                                                                                                                                    |
| Minor: an arena root without `@FlatArena`, eager validation making opening linear, lazy `FlatString` UTF-8, a short unrelated file                                                  | Fixed in `WFL44`–`WFL46`: compile-time rejection, validation separate, unchecked and `checked` string accessors, magic before full length.                                                                                                                           |
| Minor: backward links, builder state after a failure, and `finish` without a root type                                                                                              | Fixed in `WFL47`–`WFL49`: `offsetOverflow`, failed calls change nothing, `FlatBuilder!(Root, Storage)`.                                                                                                                                                              |
| Minor: errors could not give the file-absolute and table-relative offsets `FTP14` needs                                                                                             | Fixed in `WFL15`, `WFL44` and `WFL51`: a `regionBase` argument; the mapping to font's `cycle` and table tag is stated.                                                                                                                                               |
| Minor: the §3 example message named the wrong preceding field                                                                                                                       | Fixed: the example is `Pair.b`, checked against an LDC probe.                                                                                                                                                                                                        |
| Minor: a `size_t` field never fails to compile; `native` on an emulated big-endian host; which limit a cycle trips; O7's defaults                                                   | Partly fixed; recheck N6 and N10 complete it. Fixed in `WFL8`, `WFL16` and `WFL24`: stated as an evidence gap, `native` absent, `maxDepth` first, defaults set.                                                                                                      |
| Unverifiable locally: Cap'n Proto's limits, zerocopy's wording, zipalign's 4-byte rule                                                                                              | Kept and marked as documented behaviour not reproduced locally; `WFL45` adds that the alignment holds only for uncompressed assets, at the asset's file offset.                                                                                                      |

### Recheck

On 2026-10-17 the same reviewer rechecked the repaired draft with new probes
and confirmed that the three blockers are resolved. Three dispositions above
had claimed more than the text delivered: target-independent alignment, paths
across offsets, and the forced version bump. The recheck found 5 major and 5
minor defects, plus two wording points. Its findings and their dispositions:

| Finding                                                                                                                                                                     | Disposition                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| N1, major: tail padding is target-dependent; `struct { ulong a; uint b; }` is 12 bytes on i686 and 16 on x86_64, armv7 and aarch64                                          | Fixed. A naturally aligned record's declared size is a multiple of `flatAlignOf!T` (§2.1); `WFL53`'s rationale names the case, and the O10 spike rejects it.                                                                                              |
| N2, major: canonical alignment was undefined for dynamic members, `FlatSelect`, `FlatTagged`, `Offset` and `FlatSpan`, so `ItemVariationData` read literally failed `WFL53` | Fixed in §2.1: dynamic members and zero-size markers contribute 1, an `Offset` its integer's alignment; `FlatSpan` is a record of two `uint`s.                                                                                                            |
| N3, major: an inline record with dynamic members or conditional fields, followed by other fields, overlaps them                                                             | Fixed in `WFL4`: such a record must be its parent's last field.                                                                                                                                                                                           |
| N4, major: one layout index and 8 array indices cannot render a path that crosses an offset or repeats a recursive record                                                   | Fixed in `WFL56`: up to 8 hops into the root's visit table (`WFL41`), the first and 7 innermost kept with `…` between; the bound is recomputed as 160 bytes.                                                                                              |
| N5, major: the pin did not force a version bump, since the version was a run-time argument                                                                                  | Fixed in `WFL54`: `@FlatLayoutPin(version, digest)` histories with increasing versions and distinct digests; `openFlatArena` and `finish` take the version from the pin and the magic from `@FlatArena`; FL3 golden files catch a pin rewritten in place. |
| N6, major: validation defaults were set without measurement, shared targets are charged at every visit, and FL2's 65,535-row scenario failed under them                     | Fixed. `WFL24` adopts HarfBuzz's sanitizer budget (64 per byte, clamped to 16,384–`0x3FFFFFFF`) and nesting limit as provisional defaults; FL2 gains a gate over every bundled font's tables; the scenario uses 60,000 rows; O7 reopens.                  |
| N7, minor: the pin was inside the digest it pins                                                                                                                            | Fixed in `WFL41`: pins, `@FlatArena` and `@WireCheck` are excluded.                                                                                                                                                                                       |
| N8, minor: opening did not run the checks of nested records in the fixed part                                                                                               | Fixed in `WFL15`.                                                                                                                                                                                                                                         |
| N9, minor: `WFL23` excepted strings validation "was told to skip", an option that did not exist                                                                             | Fixed: the exception is deleted.                                                                                                                                                                                                                          |
| N10, minor: depth did not always trip before the traversal budget                                                                                                           | Fixed in `WFL24`: depth is checked before a target is charged; the false claim is gone.                                                                                                                                                                   |
| Wording: `WFL52`'s single byte swap; `FlatSpan` called a leaf and a record                                                                                                  | Fixed: a 16-bit rotate and a floating-point register move are allowed; `FlatSpan` is a record.                                                                                                                                                            |

After the recheck, FL0's O10 spike ran and found the lockstep walk feasible
(see [FL0](#fl0-specification-review-and-the-o10-spike)). The reviewer's
verdict on this round is the final recheck below.

### Final recheck

On 2026-10-17 the reviewer checked the third revision and found FL0 ready for
owner acceptance after two must-fixes, with no further review round. Both, and
the points it suggested, are applied and were self-checked against the
acceptance descriptions:

| Finding                                                                                                                                            | Disposition                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Must-fix, completes N1: `struct { uint n; ulong[0] xs; }` puts `xs` at offset 4 on i686 and 8 elsewhere, so it proved on i686 only                 | Fixed in §2.1: in a naturally aligned record each dynamic member's offset is a multiple of its element's canonical alignment. `ItemVariationData`, both Coverage formats and `DeltaSet` still prove. |
| Must-fix, N11: a static array of two or more records with dynamic members or conditional fields overlaps each element's tail with the next element | Fixed in `WFL4`: rejected wherever it appears; FL1 has a compile-fail fixture.                                                                                                                       |
| Suggested: a 12-byte hop struct pads to 16 bytes on 64-bit targets and breaks the 160-byte bound; a missing array index needs a representation     | Fixed in `WFL56`: three parallel arrays and a named sentinel.                                                                                                                                        |
| Suggested: offset targets and union variants have no nodes in the root's schema                                                                    | Fixed in `WFL2`: each record of the visit table walks in lockstep with its own schema; recursion ends at back-references.                                                                            |
| Suggested: distinct pinned digests forbid returning to an earlier layout                                                                           | Stated in `WFL54`'s rationale.                                                                                                                                                                       |
| Evidence: the spike's checker cross-compiled for i686, armv7 and aarch64                                                                           | Recorded in FL0 and O10.                                                                                                                                                                             |

FL1 starts once the owner accepts FL0.
