# Binary formats, schemas and verifiable encodings

A primary-source catalog of twenty-nine systems for describing bytes,
serializing values and committing to data with hashes. Its purpose is to
inform a reconsideration of the [`sparkles:wired` Flat draft][flat], not to
revise that specification. The first consumers are a [font catalog and
glyph-atlas cache][startup], built at package-build time and read from mapped
files or Android assets. Describing [OpenType's bounded foreign layouts][font]
is a separate stress test from designing that cache's own arena.

This survey answers nine questions:

1. **Which in-place formats bound verification work?** [Access and
   validation][q1] separates eager verification, checked views and traversal
   accounting, then evaluates `WFL23`–`WFL24`.
2. **Can one mechanism describe foreign bytes and build an arena?** [Relative
   offsets and foreign layouts][q2] compares base-relative pointers, sibling
   counts and tagged layouts with formats that own their encoding.
3. **Host-language schema or separate IDL?** [Declaration strategy][q3]
   prices Flat's D-types-and-attributes bet against generators and combinators.
4. **Is rebuilding instead of migrating sound?** [Evolution][q4] distinguishes
   disposable caches from separately distributed, long-lived files.
5. **What exactly should a content key identify?** [Determinism and
   hashing][q5] distinguishes repeatable builders, canonical values, output
   digests and build-input keys.
6. **Which Merkle structure fits partial atlas verification?** [Tree
   constructions][q6] compares typed roots, byte-range proofs, object DAGs and
   append-only logs.
7. **What do byte order and alignment really require?** [Alignment][q7]
   separates portable accessors from native references and examines the APK
   alignment constraint.
8. **Which real parser failures matter to Flat?** [Hostile input][q8] maps
   implementation incidents and differential risks to requirements and gaps.
9. **What should the owner keep, change, add or defer?** The [delta table][q9]
   names the draft's `WFL` IDs and links each recommendation to evidence.

**Last reviewed:** October 17, 2026

> [!IMPORTANT]
> Flat is a draft, not a delivered implementation. The baseline is pinned at
> `8a454ce151c23b3608467cf8e19821678583ecb3` from the `docs/wired-flat` branch.
> Its [specification][flat], [delivery plan][flat-plan] and [open issues][flat-issues]
> are cited externally because this catalog is independent of that branch.
> Performance claims about Flat remain proposed acceptance criteria.

## Master catalog

The **category** describes the system's primary role, not an exclusivity
claim: [CDDL][cddl] describes [CBOR][cbor], while [DAG-CBOR][ipld] constrains
CBOR for content addressing. All deep-dives use the same [ten dimensions][spine].

| Subject                           | Category                      | Schema or framing authority                  | Distinguishing property                                  | Link                   |
| --------------------------------- | ----------------------------- | -------------------------------------------- | -------------------------------------------------------- | ---------------------- |
| ASN.1: BER, DER, PER              | Description language          | ASN.1 types + encoding rules                 | Canonical restrictions versus schema-driven bit packing  | [Deep-dive][asn1]      |
| DFDL                              | Description language          | Annotated XML Schema                         | Describes existing text and binary representations       | [Deep-dive][dfdl]      |
| CDDL                              | Description language          | Data-definition grammar                      | Constrains CBOR values, not native memory layout         | [Deep-dive][cddl]      |
| OMG IDL / CDR / XCDR2             | Description language          | IDL + representation and extensibility rules | Alignment, byte order and evolution are protocol choices | [Deep-dive][cdr]       |
| Kaitai Struct                     | Description language          | Declarative `.ksy`                           | Seeks, counts and switches over foreign bytes            | [Deep-dive][kaitai]    |
| Construct                         | Description language          | Python combinator objects                    | Context-sensitive parsing and building                   | [Deep-dive][construct] |
| Protocol Buffers                  | Schema-driven protocol        | `.proto` field numbers                       | Tagged fields; deterministic is not canonical            | [Deep-dive][protobuf]  |
| Apache Thrift                     | Schema-driven protocol        | Thrift IDL + chosen protocol                 | Binary and compact encodings share field IDs             | [Deep-dive][thrift]    |
| Apache Avro                       | Schema-driven protocol        | Writer schema + reader resolution            | Positional encoding and schema fingerprints              | [Deep-dive][avro]      |
| FlatBuffers                       | Schema-driven protocol        | `.fbs`                                       | Vtable-based in-place access with explicit verifier      | [Deep-dive][fb]        |
| Cap'n Proto                       | Schema-driven protocol        | `.capnp`                                     | Word-oriented pointers; traversal budgets                | [Deep-dive][capnp]     |
| Simple Binary Encoding            | Schema-driven protocol        | XML message schema                           | Fixed block plus sequential groups and tails             | [Deep-dive][sbe]       |
| Bebop                             | Schema-driven protocol        | `.bop`                                       | Fixed structs versus evolvable framed messages           | [Deep-dive][bebop]     |
| MessagePack                       | Self-describing encoding      | Type-marker grammar                          | Compact dynamically typed values                         | [Deep-dive][msgpack]   |
| CBOR                              | Self-describing encoding      | RFC 8949                                     | Generic encoding plus deterministic profiles             | [Deep-dive][cbor]      |
| BSON                              | Self-describing encoding      | Document grammar                             | Length-delimited typed elements with names               | [Deep-dive][bson]      |
| Smile                             | Self-describing encoding      | Jackson Smile grammar                        | JSON tokens with shared-name/value references            | [Deep-dive][smile]     |
| UBJSON                            | Self-describing encoding      | Marker grammar                               | JSON model with typed/counted container optimization     | [Deep-dive][ubjson]    |
| Ethereum SSZ                      | Merkleized format             | Consensus types and bounds                   | Canonical serialization and separate typed Merkle roots  | [Deep-dive][ssz]       |
| IPLD                              | Content-addressed formats     | Data model + codec + CID                     | DAG-CBOR / DAG-PB and algorithm-labelled links           | [Deep-dive][ipld]      |
| Tendermint / CometBFT             | Merkleized protocol           | Protobuf schemas and consensus rules         | Amino migration; simple RFC 6962-style tree              | [Deep-dive][comet]     |
| COSE / deterministic CBOR / dCBOR | Signing and encoding profiles | RFCs and versioned dCBOR work                | Exact signed bytes versus value-normalization rules      | [Deep-dive][cose]      |
| Git objects                       | Content-addressed framing     | Type, size and payload                       | Object identity precedes zlib storage                    | [Deep-dive][git]       |
| Plutus Core `Data`                | Ledger encoding               | Algebraic values + ledger CBOR rules         | Datum hashes are not automatically a Merkle tree         | [Deep-dive][plutus]    |
| iroh / Bao                        | Verified byte framing         | BLAKE3 tree and transfer grammar             | Range verification with separate outboard nodes          | [Deep-dive][bao]       |
| BitTorrent v2                     | Merkleized distribution       | BEP 52                                       | Per-file SHA-256 piece trees                             | [Deep-dive][bt]        |
| Certificate Transparency          | Verifiable log framing        | RFC 6962 and tiled/static APIs               | Typed leaves, signed roots and append-only proofs        | [Deep-dive][ct]        |
| TUF / in-toto                     | Signed metadata               | Metadata schemas, canonical JSON, envelopes  | Authentication and rollback policy above payload layout  | [Deep-dive][tuf]       |
| Hypercore                         | Signed append-only log        | Block/tree and manifest encodings            | Flat-tree indexing with signed commitments               | [Deep-dive][hypercore] |

## Taxonomy

### By encoding style

| Encoding style                            | Subjects                                                                                                                                                               | Important boundary                                         |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Describes another format                  | [DFDL][dfdl], [Kaitai][kaitai], [Construct][construct]                                                                                                                 | Description power does not imply allocation-free views     |
| Schema-defined positional or bit-oriented | [PER][asn1], [CDR][cdr], [Avro][avro], [SBE][sbe], [SSZ][ssz]                                                                                                          | Writer and reader must share enough schema context         |
| Tagged fields or values                   | [BER/DER][asn1], [protobuf][protobuf], [Thrift][thrift], [Bebop messages][bebop], [MessagePack][msgpack], [CBOR][cbor], [BSON][bson], [Smile][smile], [UBJSON][ubjson] | A value type marker is not an application field ID         |
| Pointer/offset layout                     | [FlatBuffers][fb], [Cap'n Proto][capnp], [SSZ variable parts][ssz]                                                                                                     | Offset base and target extent differ across formats        |
| Encoding profile or data model            | [CDDL][cddl], [IPLD][ipld], [COSE/dCBOR][cose], [Plutus `Data`][plutus]                                                                                                | Schema, canonicalization and signing need separate rules   |
| Object, blob or log framing               | [Git][git], [Bao][bao], [BitTorrent v2][bt], [CT][ct], [TUF/in-toto][tuf], [Hypercore][hypercore], [CometBFT][comet]                                                   | Integrity structure is not the application's memory layout |

### By access model

| Access model                      | Examples                                                                                                                                                                | Cost that remains                                                    |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Direct accessor views             | [FlatBuffers][fb], [Cap'n Proto][capnp], [SBE fixed blocks][sbe]                                                                                                        | Bounds/verification, pointer following, version or byte-order checks |
| Fixed part plus variable tail     | [SSZ][ssz], [SBE][sbe], [Bebop][bebop]                                                                                                                                  | Dynamic-element boundaries or sequential scans                       |
| Sequential token/object decoding  | [protobuf][protobuf], [Thrift][thrift], [Avro][avro], [MessagePack][msgpack], [CBOR][cbor], [BSON][bson], [Smile][smile], [UBJSON][ubjson], [BER/PER][asn1], [CDR][cdr] | Materialization and indexing depend on implementation                |
| Declarative parsing or validation | [Kaitai][kaitai], [DFDL][dfdl], [Construct][construct], [CDDL][cddl]                                                                                                    | Generated/interpreted parse work; not a native-reference proof       |
| Authenticated retrieval           | [IPLD][ipld], [Git][git], [Bao][bao], [BitTorrent][bt], [CT][ct], [CometBFT][comet], [Hypercore][hypercore], [TUF/in-toto][tuf], [COSE][cose], [Plutus][plutus]         | Fetching, hashing or signature verification before trust             |

### By canonical-form contract

| Contract                                                    | Examples                                                                                                                                                | Caution                                                                                       |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Encoding constrained for a specified type/profile           | [DER][asn1], [SSZ][ssz], [DAG-CBOR][ipld], [dCBOR][cose]                                                                                                | Type, profile revision and value equivalence remain part of the contract                      |
| Generic format with deterministic/canonical profile         | [CBOR][cbor], [Cap'n Proto][capnp], [TUF canonical JSON][tuf]                                                                                           | Ordinary valid input need not satisfy the profile                                             |
| Repeatable producer, not general canonicality               | [protobuf][protobuf], [FlatBuffers][fb]                                                                                                                 | Field order, builder history or representations can differ                                    |
| Exact-byte commitment                                       | [Git][git], [Bao][bao], [BitTorrent][bt], [COSE][cose], [DSSE][tuf], [CT][ct], [CometBFT][comet], [Hypercore][hypercore], [Plutus datum hashes][plutus] | A different encoding legitimately has a different identity                                    |
| No general canonical profile established by the base format | [Thrift][thrift], [Avro][avro], [SBE][sbe], [Bebop][bebop], [MessagePack][msgpack], [BSON][bson], [Smile][smile], [UBJSON][ubjson], [CDR][cdr]          | Schema canonicalization or one encoder's stable output is not a universal value-encoding rule |
| Description, not a unique byte encoding                     | [DFDL][dfdl], [CDDL][cddl], [Kaitai][kaitai], [Construct][construct]                                                                                    | Canonicality belongs to the described format/profile, not to the declaration mechanism        |

The [synthesis][q5] examines formats without a single general canonical form,
including name order, numeric representations, optional defaults and
implementation-specific settings; absence is not permission to hash decoded
values without defining their equivalence.

### By merkleization

| Structure                                                     | Subjects                                                                                                                                                                                                                                                                                                         | What the root means                                        |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Typed value tree                                              | [SSZ][ssz]                                                                                                                                                                                                                                                                                                       | A value under its type, bounds and mixing rules            |
| Content-addressed object DAG                                  | [IPLD][ipld], [Git][git]                                                                                                                                                                                                                                                                                         | Encoded blocks linked by hashes                            |
| Byte chunk tree                                               | [Bao][bao], [BitTorrent v2][bt]                                                                                                                                                                                                                                                                                  | Byte ranges under a particular tree construction           |
| Append-only log tree                                          | [CT][ct], [CometBFT simple tree][comet], [Hypercore][hypercore]                                                                                                                                                                                                                                                  | Ordered leaves; log protocols add history and signatures   |
| Whole encoded value or signed metadata, not inherently a tree | [Plutus datum hash][plutus], [COSE/dCBOR][cose], [TUF/in-toto][tuf]                                                                                                                                                                                                                                              | Exact scope and signature envelope must be read separately |
| No built-in Merkle construction                               | [ASN.1][asn1], [DFDL][dfdl], [CDDL][cddl], [CDR][cdr], [Kaitai][kaitai], [Construct][construct], [protobuf][protobuf], [Thrift][thrift], [Avro][avro], [FlatBuffers][fb], [Cap'n Proto][capnp], [SBE][sbe], [Bebop][bebop], [MessagePack][msgpack], [CBOR][cbor], [BSON][bson], [Smile][smile], [UBJSON][ubjson] | Applications may layer one on top                          |

## Analysis spine

Every deep-dive answers these ten dimensions, including why an absent capability
does not apply:

1. Schema source of truth.
2. Wire encoding.
3. Access model.
4. Variable-length and optional data.
5. Evolution and compatibility.
6. Determinism and canonical form.
7. Merkleization and content addressing.
8. Hostile-input safety.
9. Describing foreign formats.
10. Implementation and performance evidence.

## Milestones

These are dated standards or first-party historical markers, not claims about
which implementation invented an idea. Edition-specific details live in the
linked deep-dives.

| Date               | Milestone                                                                                                                       | Evidence                            |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| 1988               | ASN.1 / BER appear in the X.208 / X.209 lineage                                                                                 | [ASN.1 standards history][asn1]     |
| 2005               | Git makes typed, size-framed objects the unit of identity                                                                       | [Git objects][git]                  |
| June 2013          | RFC 6962 standardizes Certificate Transparency's tree and signed structures                                                     | [RFC 6962][rfc6962]                 |
| October 2013       | RFC 7049 publishes CBOR                                                                                                         | [RFC 7049][rfc7049]                 |
| June 2019          | RFC 8610 publishes CDDL                                                                                                         | [RFC 8610][rfc8610]                 |
| December 2020      | RFC 8949 replaces RFC 7049, specifying core deterministic encoding                                                              | [RFC 8949][rfc8949]                 |
| August 2022        | RFC 9052 / RFC 9053 specify the revised COSE structures and algorithms                                                          | [COSE][cose]                        |
| Revision-dependent | SSZ progressive types, dCBOR and static/tiled log APIs must be read at the surveyed revision, not as timeless deployment claims | [SSZ][ssz], [dCBOR][cose], [CT][ct] |

## Suggested reading paths

- **“I'm revisiting `sparkles:wired` Flat.”** [Concepts][concepts] →
  [comparison and delta table][comparison] → [FlatBuffers][fb] → [Cap'n Proto][capnp]
  → [Kaitai][kaitai] → [Construct][construct] → [SSZ][ssz] → [Bao][bao]. Read
  [the pinned draft][flat] beside the findings, not as their conclusion.
- **“I need to describe OpenType.”** [Foreign-layout comparison][q2] →
  [Kaitai][kaitai] → [DFDL][dfdl] → [Construct][construct] →
  [font parser contract][font].
- **“I need portable signatures or content identity.”** [Canonicality][q5] →
  [ASN.1 DER][asn1] → [CBOR][cbor] → [COSE/dCBOR][cose] → [IPLD][ipld] →
  [TUF/in-toto][tuf].
- **“I need partial verification.”** [Tree comparison][q6] → [Bao][bao] →
  [BitTorrent v2][bt] → [SSZ][ssz] → [CT][ct] → [Hypercore][hypercore].
- **“I need language integration, not another wire format.”** [Declaration
  strategy][q3] → [serde catalog][serde] → [Construct][construct] → [SBE][sbe].

## Sources

Each subject page names its source revision, official specification sections,
implementation paths and evidence limitations. Tool-produced bytes are labelled
as observations; upstream vectors and illustrative derivations are not claimed
as local benchmark measurements. Cross-subject recommendations are in
[comparison][comparison].

Existing research is linked rather than replicated: [content addressing][ca]
owns file-tree hashing and [serde][serde] owns the lineage of
`sparkles:wired`'s shared schema. This catalog adds byte framing, access
contracts, canonical encodings and typed or intra-file verification.

<!-- References -->

[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[flat-plan]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/PLAN.md
[flat-issues]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/open-issues.md
[startup]: ../../specs/font/PLAN.md#ms-startup-slice
[font]: ../../specs/font/parsing.md#_1-common-rules
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[q1]: ./comparison.md#_1-in-place-access-and-bounded-validation
[q2]: ./comparison.md#_2-relative-offsets-and-foreign-layouts
[q3]: ./comparison.md#_3-host-language-schema-versus-idl
[q4]: ./comparison.md#_4-evolution-and-cache-rebuilds
[q5]: ./comparison.md#_5-determinism-canonicality-and-hashing
[q6]: ./comparison.md#_6-merkleization-and-partial-verification
[q7]: ./comparison.md#_7-byte-order-and-alignment
[q8]: ./comparison.md#_8-hostile-input-incidents-and-requirement-coverage
[q9]: ./comparison.md#_9-delta-table-against-flat
[asn1]: ./asn1.md
[dfdl]: ./dfdl.md
[cddl]: ./cddl.md
[cdr]: ./omg-idl-cdr.md
[kaitai]: ./kaitai-struct.md
[construct]: ./construct.md
[protobuf]: ./protobuf.md
[thrift]: ./thrift.md
[avro]: ./avro.md
[fb]: ./flatbuffers.md
[capnp]: ./capnproto.md
[sbe]: ./sbe.md
[bebop]: ./bebop.md
[msgpack]: ./messagepack.md
[cbor]: ./cbor.md
[bson]: ./bson.md
[smile]: ./smile.md
[ubjson]: ./ubjson.md
[ssz]: ./ssz.md
[ipld]: ./ipld.md
[comet]: ./cometbft.md
[cose]: ./cbor-cose-dcbor.md
[git]: ./git-objects.md
[plutus]: ./plutus-data.md
[bao]: ./iroh-bao.md
[bt]: ./bittorrent-v2.md
[ct]: ./certificate-transparency.md
[tuf]: ./tuf-in-toto.md
[hypercore]: ./hypercore.md
[ca]: ../content-addressing/index.md
[serde]: ../serde/index.md
[rfc6962]: https://www.rfc-editor.org/rfc/rfc6962
[rfc7049]: https://www.rfc-editor.org/rfc/rfc7049
[rfc8610]: https://www.rfc-editor.org/rfc/rfc8610
[rfc8949]: https://www.rfc-editor.org/rfc/rfc8949
[spine]: #analysis-spine
