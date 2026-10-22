# Binary format concepts

The vocabulary used by the [catalog][catalog]. Encoding, access, validation,
identity and authentication are separate dimensions: an encoding can be
canonical without being safe to traverse, and a safe view can expose bytes
that have never been authenticated.

**Last reviewed:** October 17, 2026

## Schema and description

An **interface description language** (`IDL`) gives a language-neutral source
from which tools generate host types or codecs. [Protocol Buffers][protobuf]
and [OMG IDL][cdr] define the wire formats their declarations produce.
A **description of existing bytes** instead states where fields already lie:
[Kaitai Struct][kaitai], [DFDL][dfdl] and [Construct][construct] can describe
someone else's file. The distinction is about control over bytes, not whether
the declaration happens to live in a separate file.

A **host-language schema** uses types, annotations or combinators in the
programming language. Its expressive power is not necessarily its native
memory layout: [Construct][construct] interprets Python objects, whereas the
[Flat draft][flat] proposes proving a subset of D layouts. The [serde
catalog][serde] distinguishes derivation, value-level codecs and reified
schemas; that classification is not repeated here.

## TLV and field identification

**Tag–length–value** (`TLV`) framing lets a reader identify a field and find its
end without understanding its value. [ASN.1 BER][asn1] is the direct example.
[Protobuf][protobuf] carries a field number and wire type in its key, but only
some wire types carry an explicit length. Calling all of it TLV hides that
difference. A **type marker** in [MessagePack][msgpack] identifies a value's
kind, not its application field number.

**Positional** identification derives meaning from order and an external
schema ([Avro][avro], [SBE][sbe]); **tagged** identification uses stable
numbers ([Thrift][thrift]); **named** identification carries field names
([BSON][bson]). Tags enable skipping only when the grammar also identifies the
field's extent. They do not by themselves promise compatibility.

## Varint and zig-zag

A **varint** represents an integer using a variable number of bytes. In
[protobuf base-128 varints][proto-encoding], seven payload bits travel in each
byte and the high bit indicates continuation. A decoder needs a maximum
encoded width and overflow checks, even when every individual byte fits.

**Zig-zag** maps signed integers to unsigned integers with small magnitudes:
`0 → 0`, `-1 → 1`, `1 → 2`, `-2 → 3`. This is not two's-complement
serialization. Protobuf's `sint32` and `sint64` use it; `int32` and `int64`
do not. See the [encoding specification][proto-encoding] and [Thrift's
compact protocol][thrift].

## Relative offset and region

A **relative offset** is an integer displacement interpreted against a
specified base. The base is part of the type's semantics, not recoverable from
the integer alone. [FlatBuffers][fb] offsets are relative to the offset field;
[SSZ][ssz] offsets locate variable parts within their enclosing serialized
value. OpenType uses offsets from particular table or subtable starts; the
[foreign-layout comparison][foreign] explains why those are not interchangeable.

A **region** is the caller-selected slice against which access is bounded.
Being inside the whole file is weaker than being inside the intended table.
The [font parser's common rules][font-rules] require checked arithmetic before
access. A **count** measures elements; a **byte length** measures bytes;
confusing the two is a multiplication and overflow bug.

## Vtable and far pointer

A [FlatBuffers **vtable**][fb] stores per-field offsets, allowing a table to
omit fields and allowing older readers to ignore added fields. The table's
signed displacement locates the vtable; ordinary object offsets have different
semantics. This is serialized metadata, not a native C++ virtual-method table.

A [Cap'n Proto **far pointer**][capnp] reaches a landing pad in another segment
when the ordinary relative pointer cannot name the target in its own segment.
Segment bounds and landing-pad rules belong to the validation argument. A file
with offsets is not automatically a one-segment, directly castable object.

## In-place access and zero-copy

**In-place access** reads encoded fields where they lie, without materializing
the complete application object graph first. It may still decode an integer,
check a bound or swap bytes. **Zero-copy** is a claim about a particular data
path: a borrowed string can be zero-copy even when its enclosing object was
parsed. Neither term implies zero work, aligned native references, validated
UTF-8, or authenticated contents. See [FlatBuffers][fb], [Cap'n Proto][capnp]
and the [access comparison][access].

Native references impose stronger requirements than accessor-based views:
alignment, lifetime, valid bit patterns and host byte order must all hold.
The [Flat draft's layout proof][flat] treats these separately from the bounds
proof. A read-only mapping's lifetime does not protect it from another process
truncating the backing file; that is a byte-source and publication problem.

## Verifier and traversal limit

A **verifier** checks structural conditions needed by later operations. Its
postcondition depends on what it checks: a [FlatBuffers verifier][fb] is not
an application semantic validator. Eager verification and per-access checks
are alternative placements of work, not substitutes for an explicit threat
model.

A **traversal limit** budgets work while following references. [Cap'n Proto][capnp]
charges repeatedly reached objects again because those visits cost work.
A **depth limit** bounds the active path; it does not bound a shallow graph's
fan-out. Charging at least one unit per element also prevents zero-size
elements from consuming unbounded loop iterations for zero charged bytes.
See the [validation comparison][access] for the proposed Flat policy.

## Determinism and canonical encoding

Use the existing [canonical-form definition][canonical] for the shared
concept. This catalog distinguishes three contracts:

| Contract                   | Input held equal                                   | What it guarantees                           |
| -------------------------- | -------------------------------------------------- | -------------------------------------------- |
| Deterministic producer     | Same implementation inputs and operation sequence  | Repeatable output bytes                      |
| Canonical encoding profile | Same value under an explicitly defined equivalence | One permitted representation                 |
| Strict canonical decoder   | Received bytes                                     | Rejects representations outside that profile |

[CBOR §4.2][cbor-det] supplies deterministic encoding rules, with application
choices still required. [DER][asn1] constrains BER for a given ASN.1 type.
[Protobuf][protobuf] explicitly separates deterministic serialization from a
canonical form. [COSE][cose] can sign an exact byte string without making every
CBOR representation canonical. A signature over bytes is meaningful without
canonicalization; semantic deduplication across encoders needs the stronger
contract.

## Three different hashes

The [identity-versus-provenance discussion][identity] and [build-input cache
survey][cache] already distinguish cache keys from content addresses. For a
Flat arena, keep three domains explicit:

1. **Build-input key:** identifies fonts, rasterizer version, configuration and
   other declared producer inputs. It does not prove that the output bytes
   match those inputs.
2. **Encoding digest:** commits to exact file bytes, including representation
   choices, padding and metadata. The covered range and treatment of an embedded
   digest field must be specified.
3. **Typed-value root:** commits to the value under a specified type and tree
   grammar, as [SSZ `hash_tree_root`][ssz] does. It need not equal a hash of the
   serialized bytes.

A **layout fingerprint** identifies a schema representation for compatibility
checking ([Avro][avro], the [Flat draft][flat]). A non-cryptographic fingerprint
is not an authenticity mechanism, and even a cryptographic schema hash says
nothing about whether a particular payload satisfies application invariants.

## Domain separation

**Domain separation** makes different classes of hashed input distinguishable.
[RFC 6962 §2.1][ct-tree] prefixes leaf input with `0x00` and internal-node
input with `0x01`. [Bao][bao] instead inherits BLAKE3's compression flags and
root rules; transplanting only its binary tree shape does not transplant its
security construction. [SSZ][ssz] relies on typed structure, fixed chunks and
length or selector mixing; its root is not self-describing across all types.

The domain includes the protocol's type, version, lengths and tree parameters
where the construction requires them. Inventing a separator byte is not a
replacement for defining an unambiguous encoding of the rest of the frame.

## Inclusion and consistency proof

An **inclusion proof** demonstrates that a leaf belongs under a trusted root.
A **consistency proof** demonstrates that a later log tree extends an earlier
one without changing its prefix ([RFC 6962 §§2.1.1–2.1.2][ct-tree]). Inclusion
alone does not establish append-only history, freshness or the authority of the
root. [Certificate Transparency][ct] and [Hypercore][hypercore] add root
authentication and protocol rules around the hash tree.

## Flat-tree, tiles and outboards

**Flat-tree** is an indexing scheme for a binary tree, used by [Hypercore][hypercore];
it is unrelated to the name of `sparkles:wired`'s Flat format. An index says
where nodes are addressed, not which bytes or signatures the nodes commit to.

A **tile** groups log nodes or entries into independently retrievable storage
units ([tiled logs][ct]). An **outboard** stores verification nodes separately
from blob data ([iroh/Bao][bao]). Both separate proof distribution from the
encoded application's access layout. That separation lets a catalog remain
memory-mappable while another layer verifies requested byte ranges.

## Sources

- [RFC 8949 §4.2][cbor-det]: deterministic encoding terminology.
- [Protobuf encoding guide][proto-encoding]: keys, varints and zig-zag.
- [RFC 6962 §2.1][ct-tree]: tree grammar and proofs.
- Subject pages provide pinned implementation evidence; [comparison][comparison]
  maps these concepts to Flat requirements.

<!-- References -->

[catalog]: ./index.md
[comparison]: ./comparison.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[serde]: ../serde/concepts.md
[protobuf]: ./protobuf.md
[proto-encoding]: https://protobuf.dev/programming-guides/encoding/
[cdr]: ./omg-idl-cdr.md
[kaitai]: ./kaitai-struct.md
[dfdl]: ./dfdl.md
[construct]: ./construct.md
[asn1]: ./asn1.md
[msgpack]: ./messagepack.md
[avro]: ./avro.md
[sbe]: ./sbe.md
[thrift]: ./thrift.md
[bson]: ./bson.md
[fb]: ./flatbuffers.md
[capnp]: ./capnproto.md
[ssz]: ./ssz.md
[cose]: ./cbor-cose-dcbor.md
[bao]: ./iroh-bao.md
[ct]: ./certificate-transparency.md
[hypercore]: ./hypercore.md
[font-rules]: ../../specs/font/parsing.md#_1-common-rules
[foreign]: ./comparison.md#_2-relative-offsets-and-foreign-layouts
[access]: ./comparison.md#_1-in-place-access-and-bounded-validation
[canonical]: ../content-addressing/concepts.md#canonical-form
[identity]: ../content-addressing/concepts.md#identity-versus-provenance
[cache]: ../content-addressing/build-input-caches.md
[cbor-det]: https://www.rfc-editor.org/rfc/rfc8949#section-4.2
[ct-tree]: https://www.rfc-editor.org/rfc/rfc6962#section-2.1
