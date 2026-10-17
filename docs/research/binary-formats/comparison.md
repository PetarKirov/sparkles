# Binary formats: comparison and Flat design delta

The strongest precedent for Flat is **a checked view over a restricted layout,
with an independently specified arena producer**. The survey supports keeping
foreign-format descriptions and owned arenas in one vocabulary, but not giving
them the same acceptance, canonicalization or evolution policy. It also
contradicts two tempting shortcuts: repeatable builder calls are not a
canonical value encoding, and an input-derived cache key does not authenticate
the resulting file.

**Last reviewed:** October 17, 2026

> [!NOTE]
> This is a research recommendation, not an amendment to the specification.
> Every `WFL` reference describes the [draft at the pinned revision][flat].
> Its [plan][plan] marks implementation as planned; the proposed compile-time
> proof and code-generation tests are not evidence of delivered behaviour.
> The first consumer is the [font startup slice][startup].

## At a glance

| Family                             | Representative systems                                                               | Most useful lesson for Flat                                    | What not to inherit accidentally                                      |
| ---------------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------- | --------------------------------------------------------------------- |
| Existing-byte descriptions         | [Kaitai][kaitai], [DFDL][dfdl], [Construct][construct]                               | Make bases, counts, context and variant selection explicit     | General interpreters, arbitrary seeks and unbudgeted computation      |
| Verified accessor layouts          | [FlatBuffers][fb], [Cap'n Proto][capnp]                                              | Separate opening, structural verification and access costs     | Assuming a verifier authenticates input or validates domain semantics |
| Fixed block with tails             | [SBE][sbe], [SSZ][ssz], [Bebop][bebop]                                               | Distinguish fixed-stride access from sequential variable data  | Calling every nested variable list random-access                      |
| Evolvable object protocols         | [protobuf][protobuf], [Thrift][thrift], [Avro][avro], [CDR][cdr]                     | Compatibility needs identity, framing, presence and skip rules | Treating a layout fingerprint as a migration system                   |
| Generic value encodings            | [MessagePack][msgpack], [CBOR][cbor], [BSON][bson], [Smile][smile], [UBJSON][ubjson] | Explicit type grammars still need semantic and resource policy | Equating self-description with canonical or safe decoding             |
| Canonical and signed profiles      | [DER][asn1], [COSE/dCBOR][cose], [TUF/in-toto][tuf]                                  | State exactly which representations and bytes signatures cover | Normalizing signed bytes before verifying their signature             |
| Typed/content-addressed structures | [SSZ][ssz], [IPLD][ipld], [Plutus][plutus], [Git][git]                               | Distinguish schema, typed value and encoded-object identity    | Calling every datum digest a Merkle root                              |
| Verified distribution and logs     | [Bao][bao], [BitTorrent v2][bt], [CT][ct], [CometBFT][comet], [Hypercore][hypercore] | Choose tree shape for the access and trust problem             | Adding append-only log machinery to an immutable cache                |

## 1. In-place access and bounded validation

**Keep checked lazy access and make eager validation's work contract more
explicit.** There is no universal “zero-copy verifier” algorithm to copy.

| System               | Opening and access                                                                                                           | How work is bounded                                                                                             | Consequence for `validateFlat`                                                                     |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| [FlatBuffers][fb]    | Root/table/vector access without object materialization; unchecked access requires a successful verifier or trusted producer | Verifier checks ranges/alignment and has nesting/table limits; details and defaults are implementation-specific | Test node count and depth, not just buffer length; verify the chosen generated API's preconditions |
| [Cap'n Proto][capnp] | Segment/pointer readers check as objects are reached; packed transport must first be unpacked                                | Traversal size charged on dereference, nesting bound, special handling of zero-size structures                  | Repeated aliases must cost work; bytes physically present do not bound the expanded graph          |
| [SBE][sbe]           | Fixed fields at generated offsets; groups and variable data traverse in schema order                                         | Frame bounds and application/codec checks; no universal recursive whole-message verifier                        | Cheap flyweights are not evidence that hostile frames are safe without framing and limits          |
| [SSZ][ssz]           | Fixed fields are located by type; offsets delimit variable parts                                                             | Schema maximum lengths, monotone and valid offsets, exact extents; implementations supply resource budgets      | Type bounds and strict extent checks complement, rather than replace, work accounting              |

`WFL11`–`WFL17` and `WFL23` correctly keep bounds safety independent of eager
validation. `WFL24` correctly charges repeated visits and at least one byte
for zero-size elements. Depth-first offset traversal with a budget rejects
cycles without requiring an allocating visited set. A visited-set optimization
would change costs and semantics: the key must include the target type,
parameters, offset base and any contextual rules, not just its address.

Narrow `WFL23`'s validation-success postcondition to applicable accesses with
valid caller selections and operation-specific eligibility. As written, its
sole exception is `indexOutOfRange`, while `WFL55` requires `get!R` to return
`unknownVariant` when the caller asks for a different variant. Structural
validation also does not automatically establish the actual address alignment
needed by `native`. Separate structural validity, semantic/UTF-8 checks and
native-reference eligibility rather than promising that every operation on a
validated root becomes infallible.

### Recommended accounting contract

The reference probes recorded [FlatBuffers][fb] defaults of nesting `64`,
`1,000,000` table visits and enabled alignment checks; a generated empty
`Monster` passed normally and failed with `max_tables = 0`. Table visits are
not a count of every scalar vector element. The [Cap'n Proto][capnp] probe
recorded `8,388,608` traversal words (`67,108,864` bytes) and nesting `64`;
that probe observed defaults, not enforcement against an adversarial graph.
These measurements establish concrete implementation policy, not interchangeable
accounting units or benchmark results.

Retain the provisional depth of `64` and HarfBuzz-inspired budget only as
**initial policy to measure**, not as a derived security constant. The
[draft's O7][issues] already requires real-font measurements. Neither
FlatBuffers nor Cap'n Proto establishes that “64 times file length” accepts
the right Flat inputs; their accounting units and grammars differ.

Add a precise accounting specification and adversarial tests:

- Define whether charging a record's complete extent and then its contained
  members deliberately charges their bytes twice. Either can be bounded; they
  produce different thresholds on valid deeply nested data.
- Charge loops over counts, offset aliases, UTF-8 bytes and attempts to produce
  accumulated errors. Bound caller-supplied error sinks separately if the
  sink can retain or render every error.
- Check the remaining budget before work or arithmetic whose cost it bounds.
  A rejected charge must not overflow. Include depth through inline nesting
  where schema-generated code can recurse, not only runtime offset following.
- Specify the extent-discovery cost. Finding a later dynamic member after a
  sequential, variable-extent array requires visiting earlier elements unless
  an index or total byte length exists. `WFL14`'s no-other-data-loop rule and
  `WFL31`'s back-to-back members need a worked trace for this case; the
  [SBE][sbe] and [SSZ][ssz] layouts expose this trade-off instead of erasing it.
- State a separate precondition on user-supplied count, selector and
  `@WireCheck` functions: declared D attributes do not prove bounded running
  time. A `pure nothrow @nogc` loop can still run forever. Callback work needs
  a documented restriction or explicit accounting hook.

### Runnable sequential-tail counterexample

This independent framing probe is not a Flat implementation. It models a
one-byte count followed by that many one-byte-length-prefixed records, then a
tail. Knowing only the count and the fixed header cannot locate the tail: the
reader must inspect both length prefixes. This is the same structural issue
that [SBE's sequential groups][sbe] make explicit. An enclosing byte length or
offset index would change the answer.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_formats_sequential_tail"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

import std.stdio : writeln;

void main() @safe
{
    immutable ubyte[] bytes = [2, 1, 'a', 2, 'b', 'c', 255];
    size_t at = 1;
    size_t inspected = 0;
    foreach (i; 0 .. bytes[0])
    {
        if (at >= bytes.length)
        {
            writeln("truncated prefix");
            return;
        }
        const length = bytes[at++];
        ++inspected;
        if (length > bytes.length - at)
        {
            writeln("truncated element");
            return;
        }
        at += length;
    }
    if (at >= bytes.length)
    {
        writeln("truncated tail");
        return;
    }
    writeln("tail offset: ", at);
    writeln("length prefixes inspected: ", inspected);
    writeln("tail byte: ", bytes[at]);
}
```

```ansi
tail offset: 6
length prefixes inspected: 2
tail byte: 255
```

An attainable complexity claim is `O(charged visits + checked bytes + bounded
schema/check work)`, with an explicit stack bound and no hidden memoization.
Distinguish two claims. An acceptance-or-rejection attempt can be bounded by
a file-size-derived work budget alone: it may return `limitExceeded` on a
structurally valid but expensive graph. Completing validation of every valid
alias graph in `O(file length)` is stronger and may require memoizing
contextual states within caller-owned bounded storage. The budget does not
establish that stronger acceptance guarantee.
Record maximum budget use and depth over real fonts, then test
zero-stride arrays, alias fans, cycles, long strings and truncations at every
boundary. Those are validation gates, not benchmark claims.

## 2. Relative offsets and foreign layouts

**One description mechanism is reasonable; one wire convention is not.** The
critical capability is expressing the right base and context, not merely
having a 16- or 32-bit integer called an offset.

| System                 | Offset/tail mechanism                                                                                         | OpenType-style description?                                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| [Kaitai][kaitai]       | Positioned instances, substreams, expressions, parent/root context and type switches                          | Yes, with explicit seek bases and sibling-count expressions; generated object parsing is a separate access model |
| [DFDL][dfdl]           | Length/occurrence/alignment properties, expressions and choice discrimination over an existing representation | Many structured layouts; arbitrary pointer-graph traversal is not its general wire model                         |
| [Construct][construct] | Context expressions, `Pointer`, counted arrays, `Switch`, `Tell` and bounded substreams                       | Yes for explicit base arithmetic and contextual counts; Python objects are not native mapped views               |
| [FlatBuffers][fb]      | Own field-relative offsets, signed table-to-vtable displacement, vectors                                      | No general declaration of arbitrary OpenType bytes; converting to FlatBuffers changes the format                 |
| [Cap'n Proto][capnp]   | Own word-relative pointers, segments and far-pointer landing pads                                             | No general description of packed big-endian foreign records                                                      |
| [SSZ][ssz]             | Enclosing-value-relative 32-bit offsets in a fixed section, serialized variable parts in order                | Its own encoding, not arbitrary parent-relative pointer graphs                                                   |

`WFL29`–`WFL40` address the right foreign-format requirements: sibling counts,
parameters inherited from a parent, ancestor-relative bases, format tags and
version-dependent tails. `WFL42` is valuable precisely because a real
`ItemVariationData` is harder than a toy length-prefixed list. Keep its
independent oracle gate. The [font parser contract][font] also establishes
why a region may be a table slice rather than the complete font.

Use two profiles of the shared layout vocabulary:

1. **Foreign reader:** explicit byte order and packed fields, external
   conventions for null offsets and padding, possible sharing/cycles, and
   format-specific checks. Never require producer canonicality to read a
   legitimate foreign file.
2. **Owned arena:** restricted alignment and offset widths, zeroed padding,
   specified traversal and allocation policy, versioned root/header, and a
   deterministic producer. Canonicality or acyclicity can be stronger here
   without making the foreign reader less useful.

The proposed builder rejects targets before the declared offset base and
distances exceeding the offset width (`WFL48`). This does **not** prohibit
every allocation-order backward link: a region- or ancestor-relative offset
can name an earlier record while remaining nonnegative. Equality with the base
is not generally excluded either. Do not infer acyclicity from unsigned offsets.
Foreign readers follow any target permitted by their region and description
(`WFL36`); the builder is deliberately narrower, not a general inverse of
every foreign description. Arena examples should establish that its base and
width restrictions permit the intended sharing pattern.

## 3. Host-language schema versus IDL

**Keep D declarations and `wireSchemaOf`, but demand a portable artifact from
them.** The choice is not “reflection or code generation”: compile-time
introspection itself generates specialized code.

| Approach                          | Gains                                                                         | Costs / evidence                                                                                                                                                   |
| --------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| D layout proof + attributes       | One declaration, compiler-enforced field types, shared schema node identities | Native aliases and ABI rules can leak target dependence; arbitrary functions cannot be fingerprinted by their spelling alone; [Flat `WFL2`, `WFL8`, `WFL41`][flat] |
| Python combinators                | Context-sensitive counts and selection can be ordinary code                   | Interpreter/object overhead and weaker portable layout proof; [Construct][construct]                                                                               |
| Rust derivation and layout traits | Compiler-checked conversion properties, type-directed borrowing               | A valid byte pattern, initialized output bytes, alignment and immutability are distinct obligations; [zerocopy 0.8.63][zerocopy]                                   |
| Separate IDL + generator          | Language-neutral schema, shared evolution rules, generated documentation      | Generator/runtime version agreement, a second tool and build phase; [SBE][sbe], [protobuf][protobuf], [FlatBuffers][fb]                                            |
| Reified schema shared by tools    | One structural artifact drives emitters and diagnostics                       | The artifact must retain the facts consumers need; [serde's tier analysis][serde-concepts]                                                                         |

Zerocopy explicitly separates `FromBytes` (“Types for which any bit pattern is
valid”) from `TryFromBytes` (“Types for which some bit patterns are valid”),
and separates both from `IntoBytes`, `KnownLayout`, `Immutable` and
`Unaligned` ([official API][zerocopy]). That supports `WFL7`'s conservative
native-reference eligibility and `WFL3`'s explicit pads; a single “POD” flag
would collapse different proofs.

Generation is not itself a safety property. [Construct's compilation
guide][construct] warns that omitted checks make its compiled parsers
unsuitable for untrusted input. For Flat, compile-time layout admission and
runtime bounds/work enforcement therefore need independent evidence; a
generated accessor is not safe merely because its description compiled.

Retain the [O10 spike's][plan] ordinal schema walk, but cover offset targets,
recursive type graphs, selectors and parameters before declaring the shared
schema integration complete. The draft itself says the spike did not cover
those. Export a stable layout manifest and golden bytes for non-D tools even
if an independent IDL is not introduced. That gives a reviewer something to
compare across targets without reverse-engineering template diagnostics.

## 4. Evolution and cache rebuilds

**“Rebuild, never migrate” is sound for disposable, reproducible caches, not
as a universal file-format evolution strategy.** It requires the producer's
inputs and tool version to remain available, and a useful failure path on the
device. [Font MS][startup] supplies a real cache consumer; `WFL44` and
`WFL54` should remain explicit about that scope.

| Strategy                                       | Surveyed evidence                                               | What Flat would need for durable files                                                     |
| ---------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Stable field numbers, skippable unknown fields | [protobuf][protobuf], [Thrift][thrift], [Bebop messages][bebop] | Field framing and unknown-field policy, stable IDs, reserved removals                      |
| Writer/reader schema resolution                | [Avro][avro]                                                    | Writer schema identity and availability, resolution/default rules                          |
| Missing slots/defaults, stable ordinals        | [FlatBuffers][fb], [Cap'n Proto][capnp]                         | Presence and default semantics, append-only field rules, compatibility tests               |
| Version + block length / extensibility mode    | [SBE][sbe], [CDR/XCDR2][cdr]                                    | Acting version/extent, stable offsets for old fields, skip boundaries                      |
| Exact layout rejection                         | [Flat draft][flat]                                              | No migration machinery for caches; deterministic rebuild and explicit stale-file rejection |

Keep pins and golden files. A pin history prevents an accidental unchanged
version when its computed digest changes; it cannot prevent someone editing
both the digest and the last pin, nor catch a semantic change excluded from the
digest. `WFL41` excludes `@WireCheck`, and names callback rules by shape and
the positions they reference, not an executable semantic proof. A change to a
function's body may change interpretation without changing field layout.

Therefore distinguish **layout version**, **semantic format/producer version**
and **build-input identity**. Include relevant producer, rasterizer and
configuration versions in the cache key; enforce semantic changes by review
and golden fixtures. A 64-bit FNV-1a layout digest is an accidental mismatch
guard, not a hostile schema identifier. Leave its role narrow rather than
claiming it authenticates compatibility.

Supporting durable Flat files later requires a separately specified profile:
major/minor rules, old/new reader matrix, field or section extents, unknown
variant policy, stable defaults, and a way to locate the writer's schema.
Adding a version integer alone supplies none of those. Defer that profile
until a non-cache consumer exists, as [O8][issues] proposes.

## 5. Determinism, canonicality and hashing

**Hash bytes for byte integrity; define value equivalence before claiming
value identity.** The first arena does not need a canonical value encoding to
be a useful deterministic cache.

| Contract                                                  | Systems                                                              | Lesson                                                                      |
| --------------------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| One encoding for a specified type/profile                 | [DER][asn1], [SSZ][ssz], [DAG-CBOR][ipld]                            | Type/profile identity is part of the agreement                              |
| Deterministic profile with additional application choices | [CBOR §4.2][cbor], [dCBOR][cose], [canonical JSON for metadata][tuf] | Numeric equivalence, strings, keys and duplicate handling must be explicit  |
| Deterministic serialization, not canonical                | [protobuf][protobuf], [FlatBuffers builder][fb]                      | Stable output from one producer is weaker than cross-producer normalization |
| Signature over an exact representation                    | [COSE][cose], [DSSE][tuf]                                            | Verify the specified signed bytes/envelope, not a convenient re-encoding    |
| Exact encoded block/blob identity                         | [Git][git], [IPLD][ipld], [Bao][bao], [BitTorrent][bt]               | Different bytes can correctly have different identities                     |

`WFL49` promises identical bytes for the same builder call sequence and
arguments. Two call sequences that reserve objects in different orders can
describe the same logical records at different offsets and still satisfy it.
Zeroed gaps prevent uninitialized data leakage; they do not choose an object
order, sharing policy, string normalization, float equivalence or unused-tail
policy. `WFL18` preserves floating-point bit patterns, including NaN payloads;
that is a defensible byte-preservation policy, not semantic NaN normalization.

Canonicality claims also need revision-specific differential fixtures. The
[SSZ survey][ssz] records historical/new-reference differences in progressive
tree orientation, selector padding and inactive-field positions. The
[dCBOR survey][cose] records a draft-vector/Rust-implementation disagreement
at the negative-integer boundary. A named profile and plausible round trips
are not enough to establish that two chosen implementations agree.

### Recommended identity contract

- Keep `WFL43.contentKey` opaque and call it a **build-input key**. Specify the
  consumer's framed input-key recipe: domain/version, font bytes or hashes,
  rasterizer/version, face/instance, exact rational ppem and all output-affecting
  configuration. The [startup plan][startup] already names much of that state.
- If corrupted or untrusted cache bytes must be detected, add an **encoding
  digest** in a separate integrity layer or manifest. State whether it covers
  the whole file, how a digest field is excluded/zeroed if embedded, and how
  the expected digest becomes trusted. A checksum supplied by the same attacker
  as the bytes is not authentication.
- If logical-value deduplication is needed, define a canonical arena profile:
  object traversal/allocation order, alias and duplicate policy, padding,
  strings, numeric bit patterns, unreachable bytes and header fields. Require
  strict acceptance or canonical re-encoding only in that profile.
- If a future root is typed like SSZ, give it a distinct domain and API. It
  must not silently replace a whole-file BLAKE3 digest or an input cache key.

The [content-addressing catalog][ca] already records why cache keys and content
addresses differ. That distinction is more important here than choosing
between cryptographic hash algorithms.

## 6. Merkleization and partial verification

**For immutable mapped atlases, prefer an external byte-range verification
layer before redesigning the arena as a typed Merkle graph.** The problem is
to verify requested byte ranges; it is not necessarily to prove application
field membership or append-only history.

| Construction                  | Shape and domain rules                                                                                                | Best use / mismatch                                                                              |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| [RFC 6962 / CT][ct]           | Ordered leaves, split at the largest power of two below the size; `0x00` leaf / `0x01` node prefixes                  | Inclusion and append-only consistency; useful log semantics, excess machinery for a static atlas |
| [CometBFT simple tree][comet] | RFC 6962-style leaf/node separation and ordered recursive split                                                       | Consensus commitments; protobuf serialization rules remain separately relevant                   |
| [SSZ][ssz]                    | Typed 32-byte chunks, padded capacity, length/selector mixing where defined; progressive rules are revision-sensitive | Field/element proofs under a known type; schema bounds affect roots                              |
| [Bao/BLAKE3][bao]             | Byte chunks under BLAKE3 flags, counters and root rules; outboards and grouped transfer                               | Verified ranges without changing the application file layout                                     |
| [BitTorrent v2][bt]           | Per-file SHA-256 binary trees with 16 KiB block leaves and specified padding/piece layers                             | Distribution-sized pieces and independently identified files                                     |
| [Hypercore][hypercore]        | Flat-tree addressing, leaf/parent commitments and signed tree metadata                                                | Append/truncate/replication protocol, not simply immutable-file hashing                          |
| [IPLD][ipld]                  | Codec-defined blocks linked by CIDs; CID includes codec and multihash information                                     | Object-level dedup and graph retrieval; needs a block/layout boundary policy                     |
| [Git][git]                    | Typed objects whose encodings carry child IDs                                                                         | Whole-object verification; no intrinsic byte-range proof within one blob                         |
| [Plutus `Data`][plutus]       | Ledger encoding and datum hash                                                                                        | A datum hash alone supplies no child proof API or chunk tree                                     |

The repeated rule is **commit to unambiguous structure, lengths and domains**,
not “all systems use the same binary tree.” Padding, empty-tree rules and
length mixing differ. Proofs cannot be transplanted by reusing only a node
hash function or array-index convention.

For a later Flat experiment, choose between two falsifiable options:

1. **Byte-range outboard:** keep the arena unchanged; publish a trusted BLAKE3
   root plus the compatible outboard/length metadata. Verify complete required
   chunks before exposing a requested range. Bind the header and offsets too:
   an authenticated pixel block with an unauthenticated offset table is not a
   verified lookup. Measure proof size, verified-byte amplification and latency
   against a full-file hash.
2. **Typed arena DAG:** identify immutable records/blocks and commit to their
   type/version, lengths and child identities. Define whether equal values
   share a node and how offsets map to authenticated blocks. Compare proof cost
   and random-access locality with the outboard approach before adoption.

Neither makes a bare `mmap` fault authenticate pages. Verification must
actually mediate exposure, or the byte source must supply an independently
enforced integrity mechanism. Keep this out of the initial Flat reader and
builder; [Bao][bao] and [the existing intra-file survey][ca-bao] supply the
closest prior art without duplicating a new hashing protocol.

## 7. Byte order and alignment

**The evidence supports naturally aligned native references plus unaligned,
byte-order-aware accessors. It does not prove four bytes is a universal
format ceiling.**

| Format                         | Byte order                                                                        | Alignment policy                                                                                                           |
| ------------------------------ | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| [FlatBuffers][fb]              | Little-endian                                                                     | Scalars aligned within its buffer; actual buffer-base alignment remains a caller obligation                                |
| [Cap'n Proto][capnp]           | Little-endian                                                                     | Word-oriented, normally 8-byte-aligned representation; packed transport is distinct                                        |
| [SBE][sbe]                     | Schema-selected order                                                             | Schema offsets/block layout; generated access primitives handle representation rather than relying on native struct layout |
| [CDR / XCDR2][cdr]             | Representation selects little or big endian                                       | Stream alignment and padding rules; XCDR2 changes maximum primitive alignment relative to classic CDR                      |
| [SSZ][ssz]                     | Little-endian integers/offsets                                                    | Serialization itself does not promise a naturally aligned host struct                                                      |
| [CBOR][cbor], [BSON][bson]     | CBOR multibyte arguments use network order; BSON numeric primitives little-endian | Token/document layouts are not native-reference alignment proofs                                                           |
| [Foreign descriptions][kaitai] | Declared per format or field                                                      | Packed data can require byte assembly or legal unaligned loads                                                             |

The [Android `zipalign` documentation][zipalign] says ordinary uncompressed
files “should be aligned to 4 bytes on both 32-bit and 64-bit systems”; the
alignment is its mandatory command argument. It distinguishes shared-library
page alignment (`-P 16`) from the ordinary `4` argument. Thus four-byte asset
alignment is a defensible **packaging profile**, not a physical limit imposed
on every possible APK or byte source. Do not generalize it into a promise about
all `AAsset_getBuffer` results without testing the actual asset path and
compression mode.

Keep `WFL45` for the initial APK arena if simplicity wins: split 64-bit fields
into two `uint` halves as the header does. Consider making the ceiling an arena
profile rather than a property of all future owned files. In either case,
retain `WFL16`'s runtime address check; source alignment is not established by
record-relative offsets alone. A four-byte-aligned base does not make an
eight-byte field naturally aligned just because its offset is divisible by
eight.

`WFL52`'s one-load code-generation rule is a performance acceptance test on
x86_64/aarch64, not a language-level safety theorem or an instruction-count
promise on armv7. Keep explicit cross-target layout and generated-code probes,
and retain accessor fallbacks when byte order or alignment prevents native
references. [Zerocopy's separate alignment and bit-validity traits][zerocopy]
reinforce that separation.

## 8. Hostile input: incidents and requirement coverage

**Implementation incidents demonstrate missing checks, not that one encoding
family is intrinsically unsafe.** The subject pages retain the primary
advisory or source evidence, affected implementation and the distinction
between a reproduced probe and a documentary incident. Do not turn a
single-language parser defect into a claim about all implementations.

| Failure class                                                   | Evidence                                                        | Flat coverage / remaining gap                                                                                                               |
| --------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| ASN.1 permissiveness versus strict signed representation        | [ASN.1 BER/DER analysis and incidents][asn1]                    | `WFL11`/`WFL12` stop out-of-bounds/crashes, not semantic disagreement. Foreign tolerance and a strict arena profile need distinct policies  |
| Protobuf recursive structures / stack exhaustion                | [Protobuf safety evidence][protobuf]                            | `WFL24` bounds followed offsets, but stack use through generated inline traversal and callbacks still needs proof/tests                     |
| Pointer aliases amplify a tiny buffer into much traversal       | [Cap'n Proto security model][capnp], [FlatBuffers verifier][fb] | Repeated charging and positive minimum charge in `WFL24` are essential; byte bounds alone do not stop it                                    |
| BSON length/depth/parser differentials                          | [BSON parser safety evidence][bson]                             | `WFL11`, `WFL19`, `WFL30`, `WFL24` address range/value/arithmetic/work; they do not determine unknown-field or duplicate interpretation     |
| CBOR nested containers, lengths and inconsistent value handling | [RFC 8949 security and implementation evidence][cbor]           | Same bounds/work requirements; a canonical arena validator needs its own acceptance rules rather than importing generic CBOR permissiveness |
| Token dictionary/reference state and nesting                    | [Smile][smile], [UBJSON][ubjson], [MessagePack][msgpack]        | Flat avoids these specific token grammars, but count/offset loops need equivalent progress and budget checks                                |
| Signed but stale or incorrectly scoped metadata                 | [TUF/in-toto][tuf], [COSE][cose]                                | None of `WFL1`–`WFL56` is a freshness, signature-authority or rollback protocol; keep this outside the layout layer                         |
| Verified offsets followed into unauthenticated payloads         | [Bao][bao], [IPLD][ipld], [CT][ct]                              | `WFL43.contentKey` supplies no byte-integrity check; add a separate trusted integrity boundary if required                                  |

### Concrete incident ledger

These are documentary findings, not exploits reproduced by this catalog.
The linked records are publisher/CNA or maintainer advisories, not secondary
vulnerability summaries.

| Incident                                                  | Affected path and failure                                                                                                                                                                          | Requirement mapping                                                                                                                                           |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [OpenSSL `CVE-2016-2108`][openssl-2016]                   | Before the fixes released in `1.0.2c` / `1.0.1o`, a large universal tag could become negative zero in `d2i_ASN1_TYPE`, then trigger an out-of-bounds write when re-encoded                         | `WFL19` checks restricted leaves and `WFL12` forbids undefined behaviour; `WFL50` round-trip success alone would not establish independent reader correctness |
| [OpenSSL `CVE-2016-2109`][openssl-2016]                   | ASN.1 BIO functions could allocate excessively from a short invalid encoding; memory-buffer functions and normal TLS parsing were not affected                                                     | Allocation-free reads (`WFL22`) avoid that mechanism; builder storage and validation work still need `WFL47` / `WFL24` limits                                 |
| [Protobuf Java `CVE-2024-7254`][proto-java-cve]           | Nested unknown groups, discard-unknown and map/Lite paths bypassed effective recursion bounds; fixed branches include `3.25.5`, `4.27.5`, `4.28.2`                                                 | `WFL24` accounting must cover every skip/variant/target path, not only ordinary record traversal                                                              |
| [Protobuf pure Python `CVE-2025-4565`][proto-python-cve]  | Recursive messages/groups could reach Python recursion failure; mitigations include `4.25.8`, `5.29.5`, `6.31.1`                                                                                   | `nothrow` and depth bounds are separate obligations; explicit limits must return `limitExceeded`, not rely on host stack exceptions                           |
| [libbson `CVE-2025-0755`][bson-overflow-cve]              | `bson_append` operations could overflow when the final document exceeded `INT32_MAX`; libbson before `1.27.5` affected, with separately listed server branches                                     | `WFL30` and `WFL48` need checked final-size arithmetic in producer paths too, not only reads                                                                  |
| [MongoDB `CVE-2026-9740`][bson-depth-cve]                 | BSONColumn interleaved-reference validation mutually recursed while re-entry reset depth tracking; affected branches `7.0` before `.35`, `8.0` before `.24`, `8.2` before `.10`, `8.3` before `.3` | `WFL24` needs one propagated validation context across nested validators; resetting limits at a target would defeat the bound                                 |
| [`cbor2` `CVE-2026-26209`][cbor-depth-cve]                | Before `5.9.0`, deeply nested arrays in Python/C backends lacked the required data-driven depth limit                                                                                              | `WFL24` must bound data depth independently of language/runtime recursion protection                                                                          |
| [`serde_cbor` `CVE-2019-25001`][cbor-tags-cve]            | Before `0.10.2`, excessive nested semantic tags could overflow the stack with less than 1 KiB input                                                                                                | Byte-size checks do not replace depth accounting; every wrapper/selector traversal needs the same bounded context                                             |
| [`go-ipld-prime` `CVE-2026-35480`][ipld-allocation-cve]   | Before `0.22.0`, collection headers became uncapped map/list preallocation hints outside the allocation budget                                                                                     | `WFL22` avoids read allocation; `WFL24` must charge logical counts even when little data exists, and `WFL47` must bound output reservations                   |
| [`go-ipld-prime` `CVE-2026-42328`][ipld-recursion-cve]    | Before `0.23.0`, DAG-CBOR/DAG-JSON nesting could grow a goroutine stack until fatal process termination                                                                                            | `WFL24` needs an explicit depth/context bound; language-managed stacks are not a replacement                                                                  |
| [Cap'n Proto amplification advisories, March 2015][capnp] | Aliased references and additional zero-size/list cases made traversal work much larger than physical bytes                                                                                         | `WFL24` repeated charging and minimum-one charges are directly relevant; test the accounting implementation, not only the nominal limit                       |
| [CometBFT ASA-2025-002][comet]                            | Block-part acceptance needed to bind the enclosing part index to the Merkle proof index, not just accept a valid generic proof                                                                     | `WFL28` supports within-record cross-checks, but a layout proof or byte-range digest does not establish protocol index consistency                            |
| [CometBFT `CVE-2025-24371`][comet-sync-cve]               | Decreasing blocksync height reports could leave synchronization waiting indefinitely; fixed in `0.38.17` and `1.0.1`                                                                               | No Flat requirement is a multi-message progress/state-machine guarantee; keep it in the surrounding protocol                                                  |

The [BEP reference decoder][bt] accepting `4:abc` and the [illustrative DSSE
Python implementation][tuf] counting non-ASCII payload-type characters rather
than UTF-8 bytes are additional _locally observed differentials_, not CVE or
production exploit claims. They support independent exact-byte fixtures and
strict extent checks rather than treating any upstream example as an oracle
for hostile-input acceptance.

### Acceptance evidence Flat still needs

Keep the [plan's][plan] every-truncation and mutation tests under sanitizers,
independent reader fixtures and cross-target compilation. Extend the corpus
with a primary incident's _failure shape_, not an unrelated exploit payload:

- A short active path with enormous fan-out, and many aliases to one large
  target, distinguish depth and traversal limits.
- A zero-extent uniform array with a huge count distinguishes iteration work
  from physical byte length; a zero-extent sequential element must fail to
  progress and be rejected.
- Checked `base + offset`, `count * stride`, accumulated extent and diagnostic
  `regionBase + position` arithmetic must all be tested at maximum values on
  both 32- and 64-bit targets.
- Bool/enum invalid bit patterns must never become native typed values before
  checks (`WFL7`, `WFL19`); explicit pad bytes must not expose uninitialized
  producer memory (`WFL3`, `WFL26`, `WFL49`).
- Validation followed by mutation must remain memory-safe under `WFL10`; a
  successful validation is not a capability to bypass all later bounds checks
  on caller-mutable storage.

The [font byte-source issue O1][issues] is another boundary: file truncation
can fault a mapping beneath D-level range checks. Atomic replacement and
mapping lifetime are byte-source/publication obligations. A serialization
verifier cannot solve that problem by checking the header more thoroughly.

## 9. Delta table against Flat

**Keep** preserves the draft's direction; **change** narrows or repairs an
existing claim; **add** requests a missing contract or test; **defer** rejects
scope growth until a consumer justifies it. These are owner-review inputs,
not claims that surveyed implementations prove Flat correct.

| Capability                                      | Flat as drafted                                                                                  | Survey evidence                                                                  | Recommendation                                                                                                              |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Host types as description                       | `WFL1`–`WFL6`, `WFL2` shared schema walk                                                         | [Construct][construct], [serde][serde-concepts], [zerocopy][zerocopy]            | **Keep**; export a portable layout manifest and test offset-target/recursive schema walks                                   |
| Fixed widths, explicit pads, no hidden pointers | `WFL1`, `WFL3`, `WFL4`, `WFL53`                                                                  | [zerocopy][zerocopy], [SBE][sbe], [Cap'n Proto][capnp]                           | **Keep**; distinguish readable bytes from valid native references and initialized output                                    |
| Target-independent layout                       | `WFL6`, `WFL8`, `WFL53`; aliases remain a documented gap                                         | [CDR][cdr], [SBE][sbe] own wire layouts rather than ABI                          | **Keep / add** cross-target manifest goldens; avoid pretending alias provenance can be proven on one host                   |
| Declared byte order                             | `WFL5`, `WFL17`, `WFL18`                                                                         | [CDR][cdr], [SBE][sbe], [FlatBuffers][fb]                                        | **Keep**; test both orders and bit-preserving floating-point reads                                                          |
| Native reference eligibility                    | `WFL7`, `WFL16`; alignment and all-bit-pattern validity                                          | [zerocopy][zerocopy], [Cap'n Proto][capnp]                                       | **Keep** conservative eligibility; accessors are not second-class copying                                                   |
| Cheap opening versus complete verification      | `WFL14`, `WFL15`, `WFL23`, `WFL44`                                                               | [FlatBuffers][fb], [Cap'n Proto][capnp]                                          | **Keep** separation; **change** `WFL23` to account for wrong-variant caller selections and native-alignment eligibility     |
| Bounds and error-as-value discipline            | `WFL11`–`WFL13`, `WFL19`–`WFL22`, `WFL51`, `WFL55`–`WFL56`                                       | [Font parser][font], [parser incidents][incidents]                               | **Keep**; test diagnostic arithmetic and compact path truncation as well as data arithmetic                                 |
| Eager-validation work limits                    | `WFL24`; provisional HarfBuzz-derived defaults                                                   | [Cap'n Proto][capnp], [FlatBuffers][fb], [SSZ][ssz]                              | **Change / add** explicit units, nested double-charge policy, callback limits and measured corpus headroom                  |
| Dynamic member lookup cost                      | `WFL14`, `WFL31`, `WFL33`; sequential elements supported                                         | [SBE][sbe], [SSZ][ssz]                                                           | **Change** cost claim or restrict/index later tails after variable sequential data                                          |
| Foreign relative offsets and counts             | `WFL29`–`WFL36`, `WFL40`, `WFL42`                                                                | [Kaitai][kaitai], [Construct][construct], [DFDL][dfdl]                           | **Keep**; test region containment and ancestor context explicitly                                                           |
| Tagged variants and conditional tails           | `WFL37`–`WFL40`                                                                                  | [Kaitai][kaitai], [SBE][sbe], [Bebop][bebop], [SSZ][ssz]                         | **Keep** strict unknown-variant errors for the declared profile; don't equate this with schema evolution                    |
| Foreign-reader / owned-writer separation        | `WFL36` reads region targets; `WFL48` rejects targets before their declared base or beyond width | [Foreign-layout comparison][foreign]                                             | **Add** profile and inverse-law boundaries; unsigned offsets imply neither allocation-order forwardness nor acyclicity      |
| Arena version/layout rejection                  | `WFL41`, `WFL43`, `WFL44`, `WFL54`                                                               | [Avro][avro], [SBE][sbe], [protobuf][protobuf] show stronger evolution machinery | **Keep** for caches; **defer** durable schema evolution                                                                     |
| Layout digest versus semantic identity          | `WFL41` omits checks and does not prove callback semantics                                       | [Avro fingerprint][avro], [typed roots][ssz]                                     | **Add** semantic producer/version coverage to cache keys and review gates; keep FNV's role accidental, not adversarial      |
| Four-byte arena alignment ceiling               | `WFL45`; halves for 64-bit values                                                                | [zipalign][zipalign], [CDR][cdr], [Cap'n Proto][capnp]                           | **Keep** initial APK profile; **change** universal rationale to a tested deployment constraint; defer configurable profiles |
| Unaligned one-load access                       | `WFL17`, `WFL52`; selected ISAs/build type                                                       | [SBE][sbe], [zerocopy][zerocopy]                                                 | **Keep** codegen gate; do not substitute instruction shape for a language-level safety proof                                |
| Deterministic construction                      | `WFL26`, `WFL48`, `WFL49`                                                                        | [FlatBuffers][fb], [protobuf][protobuf]                                          | **Keep** same-call-sequence guarantee; **add** explicit statement that this is not value canonicality                       |
| Canonical arena profile                         | Not specified by `WFL49`                                                                         | [DER][asn1], [CBOR][cbor], [DAG-CBOR][ipld], [dCBOR][cose]                       | **Defer** normalization until cross-producer value identity is required; zero every producer gap regardless                 |
| Build-input content key                         | `WFL43`, `WFL49`; opaque caller key, [O2][issues]                                                | [Cache versus content address][ca], [TUF][tuf]                                   | **Change** terminology/contract to input key; **add** consumer-framed recipe and all producer dependencies                  |
| Output integrity/authentication                 | No payload digest verification in `WFL44`                                                        | [Bao][bao], [Git][git], [COSE][cose], [TUF/in-toto][tuf]                         | **Add** separate trusted manifest/digest boundary if threat model requires it; never imply input key provides it            |
| Partial byte verification                       | No tree in `WFL43`–`WFL49`                                                                       | [Bao][bao], [BitTorrent v2][bt]                                                  | **Defer**; test an outboard layer before altering arena memory layout                                                       |
| Typed-value proofs or object DAGs               | Not specified                                                                                    | [SSZ][ssz], [IPLD][ipld], [Plutus distinction][plutus]                           | **Defer**; need stable type/domain/block grammar and demonstrated field-level proof consumer                                |
| Append-only history, signing, freshness         | Outside scope                                                                                    | [CT][ct], [CometBFT][comet], [Hypercore][hypercore], [TUF][tuf]                  | **Defer** from Flat; root trust belongs to a surrounding protocol                                                           |
| Byte source, lifetime and stable mapping        | `WFL9`, `WFL10`; [O1][issues]                                                                    | [Font borrowing rules][font], [zipalign][zipalign]                               | **Keep** separate source contract; test real asset address, compression and atomic publication                              |

## Consensus standard and architectural trade-offs

The field's consensus is procedural rather than a single format: define wire
widths and boundaries independently of host ABI; say what a reader may skip;
separate structural validity from application meaning; budget hostile work;
and specify exact hash/signature coverage. The field does **not** agree on
byte order, alignment, canonical value equivalence, schema declaration style
or Merkle shape. Those choices follow the consumer.

For Flat the trade-off is unusually clear. Owning the arena layout permits
alignment, deterministic allocation and cheap rejection of stale caches.
Describing OpenType requires packed layouts and contextual offsets the arena
would not choose for itself. Share the declarative vocabulary and error model;
keep profile-specific promises visible. The next design review should settle
validation accounting, dynamic-tail cost and identity terminology before
considering new serialization features or a Merkle format.

## Sources

- [Pinned Flat specification][flat], [delivery plan and spike limitations][plan],
  [open issues][issues]: the baseline, not modified by this catalog.
- [Font startup slice][startup] and [parsing common rules][font]: the actual
  consumer and foreign-reader discipline.
- Subject deep-dives carry pinned implementation evidence, official standards,
  reference probes, incident provenance and limitations.
- [Zerocopy 0.8.63 API][zerocopy] and [Android `zipalign`][zipalign]: additional
  primary evidence for host-type proofs and packaging alignment.

<!-- References -->

[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[plan]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/PLAN.md
[issues]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/open-issues.md
[startup]: ../../specs/font/PLAN.md#ms-startup-slice
[font]: ../../specs/font/parsing.md#_1-common-rules
[kaitai]: ./kaitai-struct.md
[dfdl]: ./dfdl.md
[construct]: ./construct.md
[fb]: ./flatbuffers.md
[capnp]: ./capnproto.md
[sbe]: ./sbe.md
[ssz]: ./ssz.md
[bebop]: ./bebop.md
[protobuf]: ./protobuf.md
[thrift]: ./thrift.md
[avro]: ./avro.md
[cdr]: ./omg-idl-cdr.md
[msgpack]: ./messagepack.md
[cbor]: ./cbor.md
[bson]: ./bson.md
[smile]: ./smile.md
[ubjson]: ./ubjson.md
[asn1]: ./asn1.md
[cose]: ./cbor-cose-dcbor.md
[tuf]: ./tuf-in-toto.md
[ipld]: ./ipld.md
[plutus]: ./plutus-data.md
[git]: ./git-objects.md
[bao]: ./iroh-bao.md
[bt]: ./bittorrent-v2.md
[ct]: ./certificate-transparency.md
[comet]: ./cometbft.md
[hypercore]: ./hypercore.md
[zerocopy]: https://docs.rs/zerocopy/0.8.63/zerocopy/
[zipalign]: https://developer.android.com/tools/zipalign
[serde-concepts]: ../serde/concepts.md#the-three-tiers
[ca]: ../content-addressing/recommendations.md
[ca-bao]: ../content-addressing/bao-blake3.md
[openssl-2016]: https://www.openssl.org/news/secadv/20160503.txt
[proto-java-cve]: https://cveawg.mitre.org/api/cve/CVE-2024-7254
[proto-python-cve]: https://cveawg.mitre.org/api/cve/CVE-2025-4565
[bson-overflow-cve]: https://cveawg.mitre.org/api/cve/CVE-2025-0755
[bson-depth-cve]: https://cveawg.mitre.org/api/cve/CVE-2026-9740
[cbor-depth-cve]: https://cveawg.mitre.org/api/cve/CVE-2026-26209
[cbor-tags-cve]: https://rustsec.org/advisories/RUSTSEC-2019-0025.html
[foreign]: #_2-relative-offsets-and-foreign-layouts
[incidents]: #_8-hostile-input-incidents-and-requirement-coverage
[ipld-allocation-cve]: https://cveawg.mitre.org/api/cve/CVE-2026-35480
[ipld-recursion-cve]: https://cveawg.mitre.org/api/cve/CVE-2026-42328
[comet-sync-cve]: https://cveawg.mitre.org/api/cve/CVE-2025-24371
