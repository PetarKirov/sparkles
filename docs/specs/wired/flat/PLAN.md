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

| Slice | Obligations                             | Status      | Required result                                                          |
| ----- | --------------------------------------- | ----------- | ------------------------------------------------------------------------ |
| FL0   | Scope, vocabulary, oracles, publication | in progress | Reviewed draft; owner accepts scope and the open-issue dispositions      |
| FL1   | WFL1–WFL22, WFL25–WFL27, WFL41, WFL51   | planned     | Layout proof and bounded in-place and swapped reads of fixed records     |
| FL2   | WFL23, WFL24, WFL28–WFL40, WFL42        | planned     | Arrays, offsets, conditions, unions, validation; the OpenType set        |
| FL3   | WFL43–WFL50                             | planned     | Arena header, opening, builder, deterministic output                     |
| FL4   | WFL9, WFL10, WFL44 at the real boundary | planned     | Catalog and atlas cache built by Nix, read in place on Android and Linux |

## Delivery dependencies

```text
FL0 specification review
  -> FL1 layout proof + fixed records       (needs the O10 spike)
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

## Evidence common to every milestone

- **Compile-time rejections** are tested with `static assert(!__traits(compiles,
…))` over a fixture type per rejection rule, and one single-file example per
  rule whose expected compiler message fragment (type, field path, fact) is
  checked by `ci --verify`. A rejection without a message test is unverified.
- **Attributes** are asserted per acceptance description:
  `static assert(isSafe!…)`-style checks over every view accessor, `flatDecode`
  and `validateFlat`, plus a `@safe pure nothrow @nogc` unittest that drives
  them.
- **Hostile input** runs under `DC=ldc2 nix run .#ci -- --test-sanitize`
  (ASan): a deterministic mutation corpus per fixture (every truncation length,
  every single-bit flip of the fixed part, offsets and counts rewritten to 0,
  1, the region length, and the maximum of their width). The oracle is the
  contract, not a golden: no crash, no `RangeError` or assertion, every result
  either a value or a `FlatError` whose offset lies within the region or names
  the end of it. Seeds and minimized failures are kept as fixtures.
- **Independence.** A round trip through the builder never stands alone as
  evidence for a reader requirement: builder and reader can share a bug.
  Reader requirements are established by bytes written by hand or by another
  implementation.

## FL0 — Specification and review

Write SPEC, PLAN and open issues; run a cold read of the abstract and
introduction ([spec prose](../../../guidelines/spec-prose.md#test-the-opening-with-a-cold-read));
review the OpenType descriptions of SPEC §6 against the OpenType specification
by a reader other than the author; record the owner's dispositions of
[open-issues](./open-issues.md) O1–O10.

Gate: owner acceptance recorded in the pull request; publication checks
(`ci --check-docs-sidebar`, `--check-spec-evidence`, `--check-glossary`,
`--check-vcs-urls`, prettier) green. Publication checks are not semantic
acceptance.

## FL1 — Layout proof and fixed records

**Deliverable.** `sparkles.wired.flat` with `Flat`, the attributes needed by
fixed records (`@FlatEndian`, `@FlatConst`, `@FlatPad`, `@FlatBits`),
`FlatU24`/`FlatI24`, `flatLayoutOf`, `isFlatRecord`, `isFlatInPlace`,
`flatView` with accessors and `native`, `flatNativeArray`, `flatDecode`,
`flatLayoutDigest` and `FlatError`. The O10 spike runs first and decides how
the layout reads alias-carrying attributes through the shared schema.

**Acceptance scenarios and oracles.**

| Scenario                                                                                                                                                                                     | Oracle                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `head` and `hhea` prove to 54 and 36 bytes, with every field offset as the OpenType tables list                                                                                              | The offsets transcribed by hand from the OpenType `head` and `hhea` pages, as constants in the test                   |
| A hand-built `head` decodes every field, swapped on a little-endian host                                                                                                                     | A byte array written field by field from chosen values; the values are the expected result                            |
| The same bytes read in place under `isFlatInPlace!(Head, Endian.bigEndian)`                                                                                                                  | The same values: the test forces the host-endian parameter, so both branches of `WFL7` and `WFL17` run on one machine |
| `head` and `hhea` of every bundled font read the same values as `sparkles:font`                                                                                                              | `sparkles:font`'s hand-written reader, an independent implementation over `sparkles.font.bytes`                       |
| Implicit padding, pointer and slice fields, a context-carrying nested struct, `bool` or `enum` leaves in place, and missing or conflicting byte order are each rejected with the named field | Compile-fail fixtures with expected message fragments                                                                 |
| Every truncation of `head` from 0 to 53 bytes reports `truncated` at offset 0 with the needed length                                                                                         | The contract (`WFL11`, `WFL51`)                                                                                       |
| `@FlatConst` mismatch on the magic number reports both values and the path `$.magicNumber`                                                                                                   | The contract                                                                                                          |
| A misaligned in-place view reports `misaligned`; the accessor view of the same bytes succeeds                                                                                                | A buffer sliced at offset 1 of an aligned array                                                                       |
| Signalling-NaN `float` and `double` bit patterns survive a swapped read                                                                                                                      | The bit pattern written by hand                                                                                       |
| Layout digests are equal on x86_64 and i686, and differ after reordering, retyping or re-ending a field, but not after renaming one                                                          | A 32-bit build through the i686 LDC cross toolchain, comparing printed digests; the reorder/retype/rename fixtures    |
| Mutation corpus over `head` and `hhea` under ASan                                                                                                                                            | The common hostile-input oracle                                                                                       |

**Excluded.** Dynamic members, offsets, unions, eager validation, the builder.
The in-place path on a big-endian host is not exercised by any available
machine; the forced host-endian parameter checks the selection logic, and the
gap is recorded as evidence `partial` for `WFL16` ([O6](./open-issues.md#o6-no-big-endian-host)).

## FL2 — Variable-length members and the OpenType set

**Deliverable.** `@FlatCount`, `@FlatBytes`, `@FlatRest`, uniform and
sequential arrays, `Offset` with the three bases and null handling,
`@FlatSince`, `@FlatPresentIf`, `FlatTagged`, `FlatSelect`, `@FlatParam` and
`@FlatArgs`, Flat use of `@WireCheck`, `validateFlat` with `FlatLimits` and
the error sink, and the four OpenType descriptions of SPEC §6 in tests.

**Acceptance scenarios and oracles.**

| Scenario                                                                                                                                 | Oracle                                                                                                                                                                |
| ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Coverage format 1 and 2 fixtures: glyph arrays, range records, empty arrays, unknown format 3                                            | Hand-built bytes; `unknownVariant` carrying 3 for the last                                                                                                            |
| Every Coverage table reachable from `GSUB`, `GPOS` and `GDEF` of the bundled fonts lists the same glyphs                                 | `sparkles:font`'s coverage reader, and fontTools `ttx` dumps recorded as goldens by a committed command ([O4](./open-issues.md#o4-fonttools-is-not-in-the-dev-shell)) |
| `ItemVariationData` fixtures with `LONG_WORDS` clear and set, `wordCount` 0, equal to and greater than `regionIndexCount`, `itemCount` 0 | Hand-built rows; the expected deltas written by hand; `checkFailed` for the greater case, as HarfBuzz's sanitize rejects it                                           |
| Row `i` of `deltaSets` starts at `6 + 2·regionIndexCount + i·rowSize`                                                                    | HarfBuzz's row size, `(wordCount + regionIndexCount) · (longWords ? 2 : 1)`, cited in SPEC §6                                                                         |
| Every `ItemVariationStore` reachable from `HVAR`, `MVAR` and `GDEF` of the bundled variable fonts yields the same deltas                 | fontTools `ttx` goldens; end to end, advance widths at sampled coordinates through `HVAR` against `hb_font_get_glyph_h_advance` via `sparkles:font-oracle`            |
| Version-dependent tail: a description of `OS/2` versions 0–5 reads exactly the fields its version has                                    | Hand-built fixtures per version; fontTools goldens for bundled fonts                                                                                                  |
| Offsets outside the region, overflowing offsets, a zero non-nullable offset that points at its own record                                | The contract: `badOffset` with the offset's position; the self-reference stops at `maxDepth` during validation                                                        |
| Amplification: a 1 KiB input whose offsets share targets to describe a tree of 2^40 extents                                              | `limitExceeded` naming `traversalBytes` within a bounded number of steps                                                                                              |
| Accumulating validation lists every failure of a fixture with three independent faults, each with its path                               | The three faults, chosen by hand                                                                                                                                      |
| Mutation corpus over every fixture above and one real table of each kind, under ASan                                                     | The common hostile-input oracle                                                                                                                                       |

**Excluded.** The arena header and builder; any change to `sparkles:font`.

## FL3 — Arena header and builder

**Deliverable.** `@FlatArena`, the header record, `FlatSpan`, `FlatString`,
`openFlatArena`, and `FlatBuilder` over growable and fixed storage.

**Acceptance scenarios and oracles.**

| Scenario                                                                             | Oracle                                                                              |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| A two-record arena with a string table is built and compared byte for byte           | The expected file written by hand, header included                                  |
| Round trip: generated catalog-shaped values are built, opened and read back          | The generated values, from recorded seeds                                           |
| Determinism: the same calls twice give identical bytes; gaps and pads are zero       | Byte comparison                                                                     |
| Each header check fails alone, in the order of `WFL44`                               | Hand-edited headers, one field each                                                 |
| A record needing 8-byte alignment under `@FlatArena` is rejected at compile time     | Compile-fail fixture                                                                |
| An arena opened from a buffer at a 4-byte but not 8-byte boundary reads in place     | A buffer sliced at offset 4 of an 8-aligned array                                   |
| Offsets wider than their field, foreign and unwritten slots, exhausted fixed storage | The contract: `offsetOverflow`, `invalidSlot`, `limitExceeded` with the size needed |
| Invalid UTF-8 in a string table                                                      | `invalidUtf8` at the string's position                                              |
| Mutation corpus over the built arena, under ASan                                     | The common hostile-input oracle                                                     |

## FL4 — First consumer: catalog and atlas cache

**Deliverable.** The face catalog (font MS S1) and glyph-atlas cache (S3) as
arena formats; the Nix precompute step (S4) writing them with `FlatBuilder`;
the app reading them in place through the byte source of
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
