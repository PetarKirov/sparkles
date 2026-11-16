# Image requirements for wired's binary description

Non-binding requirements, `IMW1` to `IMW25`, that the [Flat fit experiment][exp] yields for the binary description format of `sparkles:wired`, each with its evidence, whether the Flat draft already meets it, and a priority.

**Last reviewed:** November 15, 2026

> [!IMPORTANT]
> The wired design decisions belong to the wired specification: the
> [base spec][wired-spec], the [expressiveness spec][expr-spec] and, if adopted, the
> Flat draft ([SPEC][flat] at `8a454ce151c23b3608467cf8e19821678583ecb3`). This list
> only informs them. It answers catalog question [Q4][umbrella] from the side of image
> formats; nothing here is accepted, scheduled or owned, and the wired design it reads
> is work in progress.

## How to read the list

- **Requirement**: one line, stated as a capability, not as an API.
- **Evidence**: links into the [experiment][exp] (whose tables give the format clause
  and the program output) and into the deep-dives.
- **Flat**: whether the draft as written already meets it: **yes** (a cited `WFL`
  requirement covers it), **partly** (it covers part, or the draft is silent on a case
  that decides it), or **no**. Every Flat verdict is an assessment of draft text; no
  Flat code exists.
- **Priority**: **v1** (needed for the first image codecs: PNG and the AVIF/HEIF
  container), **later** (needed once a second consumer or streaming input arrives;
  v1 codecs can do it in code meanwhile), or **nice** (nice to have).

Three formats were studied: PNG with APNG, QOI, and ISOBMFF as AVIF and HEIF use it.
Formats with runtime byte order (TIFF), varints (EBML, LEB128) or JPEG-style escapes
were not, so this list says nothing for or against those needs; the
[wired baseline][bl-wired] (G5) and the [Wuffs table][wuffs-desc] record them.

## Leaves and records

| ID     | Requirement                                                                                                                                                  | Evidence                                                                                                                                                                                 | Flat                                                                                                                                                                                                                                   | Priority |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `IMW1` | A binary backend reads and writes records by the shared schema, with each leaf's byte order resolved from data indexed by schema nodes, not from the marker. | [prototype][exp-proto]: byte order had to live in the `BeFixed` marker because `SchemaNode` has no such field; [baseline][bl-wired] G1                                                   | **yes**: `WFL2`, `WFL5`, `WFL6`                                                                                                                                                                                                        | v1       |
| `IMW2` | 24-bit integers and constant-valued byte arrays (signatures, magics, end markers) are admissible leaves.                                                     | [ISOBMFF][exp-isobmff] FullBox `bit(24) flags`; [PNG][exp-png] signature; [QOI][exp-qoi] magic and end marker                                                                            | **partly**: `FlatU24` (`WFL1`); `@FlatConst` on a `ubyte[8]` is plausible under `WFL1` and `WFL25` but never shown                                                                                                                     | v1       |
| `IMW3` | Check descriptors (`isBetween` bounds, `isOneOf` members) reach the schema as data, so a backend or emitter can use them without calling the predicate.      | [prototype][exp-proto]: the annotation reads `WireCheck!(isBetween, "", AnyFormat)`; [expressiveness §6.4][expr-check] promises the descriptor; the [plan][expr-plan] lists it open (E6) | **no**: Flat relies on `@WireCheck` (`WFL28`)                                                                                                                                                                                          | later    |
| `IMW4` | Checks on the binary read path run without GC allocation.                                                                                                    | [prototype][exp-proto]: `wireCheckFailures` appends to an array; [baseline][bl-wired]                                                                                                    | **partly**: `WFL22` makes reads `@nogc` when the description's checks are, and `WFL56` the error path; `WFL28` reuses `@WireCheck`, whose shipped runner (`wireCheckFailures`) appends failures to a GC array and so cannot be `@nogc` | v1       |
| `IMW5` | Errors carry kind, absolute offset, field path and the offending value, and building one does not allocate.                                                  | all three programs report kind, offset and a path, but build the text by concatenation; [libavif hostile input][libavif-hostile]                                                         | **yes**: `WFL51`, `WFL56`                                                                                                                                                                                                              | v1       |

## Lengths, regions and widths

| ID      | Requirement                                                                                                                                                                     | Evidence                                                                                                                                                                         | Flat                                                                                                                                    | Priority |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `IMW6`  | A member's extent can come from a rule that counts its own header, switches to a 64-bit field on an escape value, and means "to the end of the enclosing region" on a sentinel. | [ISOBMFF][exp-isobmff] `size`, `largesize`, `size` 0; [computed lengths][exp-lengths]; Kaitai's `quicktime_mov.ksy` writes the same rule as one expression                       | **partly**: rules in checked `ulong` (`WFL29`–`WFL31`); no value-selected `@FlatRest`; rules over absent conditional fields unspecified | v1       |
| `IMW7`  | A fixed field may follow a variable-length member (a trailer).                                                                                                                  | [PNG][exp-png]: the CRC follows the data; `WFL4` rejects it                                                                                                                      | **no**                                                                                                                                  | v1       |
| `IMW8`  | A child sequence is parsed inside its parent's declared extent, an overrun is an error at the child, and placement rules may depend on depth ("size 0 only at the top level").  | [ISOBMFF][exp-isobmff]: `ispe overruns ipco`, `size 0 inside ipco`; [libavif box header][libavif-loop]; the MPEG reference accepts size 0 at any depth ([experiment][exp-impls]) | **partly**: regions are per root (`WFL34`, `WFL36`); nesting of sequential elements is not stated                                       | v1       |
| `IMW9`  | A field's width can be a value read earlier (0, 4 or 8 bytes), and several such widths can apply in one record.                                                                 | [ISOBMFF][exp-isobmff] `iloc` `offset_size`, `length_size`, `base_offset_size`, `index_size`; [libavif `iloc`][libavif-graph]                                                    | **partly**: `FlatSelect` by one value plus parameters (`WFL39`, `WFL40`); three independent widths make 27 variants                     | v1       |
| `IMW10` | Lengths and positions are 64-bit throughout: lengths, offsets into the input, and offsets in errors.                                                                            | [ISOBMFF][exp-isobmff] `largesize` and 8-byte `iloc` fields; [Wuffs][wuffs-io] `pos + ri`; [baseline][bl-wired] G5                                                               | **partly**: rule values are `ulong` (`WFL30`); `Offset` stops at 32 bits (§5.3) and `FlatSpan` is two `uint` (`WFL46`)                  | v1       |
| `IMW11` | Bit ranges inside an integer leaf are declared once and serve both decode and encode.                                                                                           | [bit-level fields][exp-bits]; the MPEG `ipma` reader loses the essential bit in one width while its writer is right ([experiment][exp-impls]); [QOI][exp-qoi] op fields          | **partly**: decode by `@FlatBits` (`WFL27`); the builder writes leaves (`WFL48`), bit ranges on write are not stated                    | v1       |

## Dispatch, presence and checks

| ID      | Requirement                                                                                                                                                                     | Evidence                                                                                                                                                               | Flat                                                                                                                  | Priority |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | -------- |
| `IMW12` | Tag dispatch has a default branch that keeps an unknown element as sized raw bytes, with a policy keyed on the tag (PNG's ancillary bit; skipping unknown boxes).               | [PNG][exp-png]: "can safely ignore" unknown ancillary chunks; [ISOBMFF][exp-isobmff] unknown boxes; [libavif][libavif-graph] keeps unknown properties as opaque copies | **no**: an unmatched tag "must produce `unknownVariant`" (`WFL38`)                                                    | v1       |
| `IMW13` | Tag matching may use a mask and a precedence order.                                                                                                                             | [QOI][exp-qoi]: "The 8-bit tags have precedence over the 2-bit tags"                                                                                                   | **no**: one exact value per variant (`WFL38`)                                                                         | nice     |
| `IMW14` | A condition may test a four-character code or a flag bit read earlier in the record.                                                                                            | [ISOBMFF][exp-isobmff] `uuid` usertype, `ipma` `flags & 1`                                                                                                             | **partly**: `@FlatPresentIf` and `@FlatBits` (`WFL37`, `WFL27`) if a code is read as `uint`                           | v1       |
| `IMW15` | A check may see values from enclosing or earlier records, so cross-record rules (a frame region inside the canvas, `tRNS` bounded by the `PLTE` count) are declared, not coded. | [PNG][exp-png] `fcTL` and `tRNS` rows; [value constraints][exp-constraints]; Kaitai reaches them with `_root`; [expressiveness §7.2][expr-ctx] defers sibling access   | **partly**: parameters (`WFL40`) bring values in, but whether a `WFL28` check sees them is not stated; siblings never | v1       |
| `IMW16` | Rules over a sequence are declarable: first, last, at most once, a consecutive run, before another kind, and counters (APNG sequence numbers, `num_frames`).                    | [ordering and cardinality][exp-order]; [PNG §5.6, Table 7][png-order]; [libavif][libavif-graph] allows each `meta` child at most once                                  | **no**: checks do not see dynamic members (`WFL20`, `WFL28`)                                                          | later    |
| `IMW17` | A field can be declared an ID or a 1-based index, and another field a reference to it, resolved after the tree is read, with an error naming both sites.                        | [references by ID][exp-refs]; [ISOBMFF][exp-isobmff] `pitm`, `iloc`, `ipma`, `ipco`; libavif's linear lookup per ID ([hostile input][libavif-hostile])                 | **no**: offsets name byte positions (`WFL34`)                                                                         | later    |

## Payloads, checksums and limits

| ID      | Requirement                                                                                                                                                                                         | Evidence                                                                                                                                                                                                 | Flat                                                                                                                                                 | Priority |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `IMW18` | A checksum is declared over one or more byte ranges (PNG: type and data, not length), computed incrementally, with a policy per element class (error, discard, ignore).                             | [checksums][exp-crc]; [libspng][libspng-crc] (critical error, ancillary discard); [Wuffs][wuffs-desc] `mark`/`since` and `QUIRK_IGNORE_CHECKSUM`; Daffodil's checksum layer pulls the region into memory | **no**: a check cannot see payload bytes (`WFL20`, `WFL28`)                                                                                          | v1       |
| `IMW19` | A member can be handed to codec code as a borrowed byte range with its absolute offset.                                                                                                             | [QOI][exp-qoi] op stream; [ISOBMFF][exp-isobmff] item extents; [Wuffs][wuffs-desc] `io_limit`                                                                                                            | **partly**: byte arrays from `@FlatBytes` and `@FlatRest` borrow the input (`WFL9`, `WFL31`, `WFL32`); no accessor for a member's position is stated | v1       |
| `IMW20` | The payloads of a run of framed elements can be exposed as one logical stream, minus per-element headers (the `IDAT` run; `fdAT` after its sequence number).                                        | [compressed payloads][exp-stream]; [PNG §10.2][png-fsl]; Kaitai's `process: zlib` covers one field, not a run                                                                                            | **no**: the sequential range yields elements (`WFL33`); joining is code                                                                              | v1       |
| `IMW21` | A member's extent can be reported by the code that consumed it, after which the description resumes.                                                                                                | [QOI][exp-qoi]: the end marker follows an op stream measured in pixels                                                                                                                                   | **no**                                                                                                                                               | nice     |
| `IMW22` | Caller-declared limits on quantities derived from fields (pixels, dimensions, chunk and metadata sizes, item, extent and property counts, depth) are checked before allocation and named in errors. | [resource limits][exp-limits]; [QOI][exp-qoi] pixel budget; [libavif][libavif-hostile] has no item, extent or property count limit; [libspng][libspng-hostile]                                           | **partly**: `traversalBytes` and `maxDepth` (`WFL24`), named in errors (`WFL51`); no field-derived limits                                            | v1       |
| `IMW23` | Values derived from header fields (an expected inflated size) are available to the code that checks a payload against them.                                                                         | [PNG][exp-png] expected inflated size; [Wuffs][wuffs-desc] `workbuf_len`                                                                                                                                 | **no**                                                                                                                                               | nice     |

## Input in pieces and encode

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                  | Evidence                                                                                                                                                                                                                                                                           | Flat                                                                              | Priority                                      |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------- |
| `IMW24` | Reading from a prefix of the input reports "need more", with the byte count when it is known, distinctly from truncation, which needs the caller to say the input is closed; then a walk over a sequence resumes from state kept in a struct, with fields that straddle pieces collected in scratch, as values that coexist with `Expected`. | [streaming][exp-streaming]; [QOI][exp-qoi] pieces of 1, 3 and 7 bytes; Wuffs `"$short read"` ([coroutines][wuffs-coro]) and `closed` ([I/O][wuffs-closed]); libavif reads at most 32 bytes per top-level header ([libavif][libavif-loop])                                          | **no**: `truncated` is final (`WFL11`); the input is one borrowed region (`WFL9`) | v1 for the outcome, later for resumable walks |
| `IMW25` | Encode of foreign formats computes lengths, back-patches enclosing sizes, writes checksums, resolves offsets and picks minimal field widths, and a round trip through decode is tested; a test-only path can write invalid bytes for negative fixtures.                                                                                      | [encode][exp-encode]; the programs' `putChunk` and `BoxWriter`; the MPEG `iloc` width choice; Kaitai writing "does not eliminate placement/size work" ([Kaitai][bf-kaitai-write]); DFDL `outputValueCalc` ([DFDL][bf-dfdl-vl]); Construct `Rebuild` ([Construct][bf-construct-vl]) | **no**: the builder writes the library's own arenas (`WFL47`–`WFL50`)             | v1 for PNG, later for ISOBMFF                 |

## Notes outside the list

- **Toolchain.** Passing a `WireSchema` to a CTFE helper as an `in` parameter made
  DMD 2.112.1 reject the code and LDC 1.43.0 crash with an assertion in
  `dmd/dinterpret.d` ([experiment][exp-proto]). That is a compiler defect, not a format
  requirement; a binary layer built on CTFE over the schema needs both compilers in its
  tests.
- **Agreement with the Wuffs table.** Of the thirteen behaviours in the
  [Wuffs deep-dive][wuffs-desc], all but two arose in the three formats; the two that
  did not, bit fields that cross bytes and escape removal, belong to entropy-coded
  payloads and JPEG markers, which no format studied here has in its framing.
- **Most of the list is codec-shaped.** `IMW16`, `IMW17`, `IMW20`, `IMW21`, `IMW23`
  and the resumable half of `IMW24` are things every implementation read does in code.
  Whether wired should describe them or offer a bounded reader for the code that does
  is the design question; the experiment's [conclusion][exp-conclusion] gives the
  evidence for both.

<!-- References -->

[exp]: ./wired-flat-fit/index.md
[exp-proto]: ./wired-flat-fit/index.md#how-the-prototype-works
[exp-png]: ./wired-flat-fit/index.md#png
[exp-qoi]: ./wired-flat-fit/index.md#qoi
[exp-isobmff]: ./wired-flat-fit/index.md#isobmff
[exp-impls]: ./wired-flat-fit/index.md#what-the-two-implementations-show
[exp-bits]: ./wired-flat-fit/index.md#bit-level-fields
[exp-lengths]: ./wired-flat-fit/index.md#computed-lengths-and-offsets
[exp-crc]: ./wired-flat-fit/index.md#checksums
[exp-constraints]: ./wired-flat-fit/index.md#value-constraints-and-dependent-presence
[exp-order]: ./wired-flat-fit/index.md#ordering-and-cardinality-rules
[exp-stream]: ./wired-flat-fit/index.md#a-payload-that-is-itself-a-compressed-stream
[exp-refs]: ./wired-flat-fit/index.md#references-by-id-across-the-tree
[exp-streaming]: ./wired-flat-fit/index.md#streaming-and-suspendable-parsing
[exp-limits]: ./wired-flat-fit/index.md#resource-limits-declared-by-the-caller
[exp-encode]: ./wired-flat-fit/index.md#encode-as-well-as-decode
[exp-conclusion]: ./wired-flat-fit/index.md#conclusion-the-evidence
[umbrella]: ./index.md#questions-this-survey-answers
[bl-wired]: ./baseline/wired.md
[wuffs-desc]: ./wuffs.md#what-a-binary-description-format-would-have-to-express
[libavif-graph]: ./libavif.md#the-item-graph-meta-iinf-iloc-ipco-ipma
[libavif-loop]: ./libavif.md#the-top-level-box-loop
[libavif-hostile]: ./libavif.md#_5-hostile-input-and-safety
[libspng-crc]: ./libspng.md#chunk-parsing-and-the-undo-log
[libspng-hostile]: ./libspng.md#_5-hostile-input-and-safety
[bf-kaitai-write]: ../binary-formats/kaitai-struct.md#weaknesses
[bf-dfdl-vl]: ../binary-formats/dfdl.md#variable-length-and-optional-data
[bf-construct-vl]: ../binary-formats/construct.md#variable-length-and-optional-data
[wired-spec]: ../../specs/wired/SPEC.md
[expr-spec]: ../../specs/wired/expressiveness/SPEC.md
[expr-check]: ../../specs/wired/expressiveness/SPEC.md#_6-4-validation-wirecheck
[expr-ctx]: ../../specs/wired/expressiveness/SPEC.md#_7-2-context
[expr-plan]: ../../specs/wired/expressiveness/PLAN.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[png-order]: https://www.w3.org/TR/png-3/#5ChunkOrdering
[png-fsl]: https://www.w3.org/TR/png-3/#10CompressionFSL
[wuffs-io]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L63-L73
[wuffs-closed]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L76-L86
[wuffs-coro]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/coroutines.md#L23-L50
