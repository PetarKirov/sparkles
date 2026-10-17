# Plutus Core Data (Cardano / Haskell)

A small recursive smart-contract data algebra encoded in CBOR, whose datum hash is not a recursive Merkle root.

| Metadata      | Value                                                                        |
| ------------- | ---------------------------------------------------------------------------- |
| Language      | Haskell                                                                      |
| License       | Apache-2.0 for the surveyed Plutus repository                                |
| Repository    | [`IntersectMBO/plutus`][repo]; [Cardano ledger][ledger]                      |
| Documentation | [`PlutusCore.Data` implementation][data]; [ledger data wrapper][ledger-data] |
| Category      | Contract data serialization and whole-datum commitments                      |
| Plutus pin    | `7ab93b9ddb3ec11c2d89b9dc9c6d6e6af4544917`                                   |
| Ledger pin    | `178bd36839dcb57f257efc0e96615284d1632088`                                   |
| Commitment    | Ledger `DataHash`, using BLAKE2b-256 over stored serialized datum bytes      |

## Overview

### What it solves

Contract parameters, redeemers and datums need a language-independent value
representation with constructors, integers and binary payloads. Plutus Core
[`Data`][data] provides that algebra. It is not the complete encoding of
an executable Plutus script, and it is not an arbitrary Haskell heap dump.

The ledger can store a datum hash, an inline datum or no datum. Those choices
belong to the enclosing transaction-output representation. A recursive
`Data` value remains ordinary CBOR serialization unless an application
explicitly introduces hashes and a verification algorithm of its own
([ledger wrapper][ledger-data]).

### Design philosophy

The source's description of its central constructor is precise:

> The main constructor 'Constr' represents a datatype value in sum-of-products form: @Constr i args@ represents a use of the @i@th constructor along with its arguments.

This quote is from [`PlutusCore/Data.hs`][data]. The source then supplies a
custom `Serialise` instance rather than trusting a generic derived encoding.
Constructor numbering and binary compatibility are protocol decisions,
not incidental properties of a Haskell declaration.

## How it works

The entire primitive algebra is:

```haskell
data Data
  = Constr Integer [Data]
  | Map [(Data, Data)]
  | List [Data]
  | I Integer
  | B ByteString
```

`Map` is represented as an ordered list of pairs in this host type, not an
automatically sorted unique-key container. There is no primitive text,
boolean, floating-point or null constructor. A higher-level schema can
represent those concepts using constructors and fields, but must define
that mapping separately ([data implementation][data]).

### Schema source of truth

The five-way algebra and its custom CBOR encoder/decoder are the primitive
schema. User datatypes map through the [PlutusTx `IsData` interface][isdata]
and associated instances/generation. The application fixes constructor
indices, argument order and interpretation of each integer or byte string.

Generic decoding recovers `Constr 0 [...]`, not the original source-language
datatype name or the meaning of its fields. Like the [serde distinction][serde],
successful structural decoding and successful conversion into an expected
application type are separate checks.

### Wire encoding

[`encodeData`][data] uses a tag scheme for constructor alternatives:

| Constructor index       | CBOR wrapper                                           |
| ----------------------- | ------------------------------------------------------ |
| 0–6                     | Tag `121 + index`, followed by its argument array      |
| 7–127                   | Tag `1280 + index - 7`, followed by its argument array |
| Other encodable indices | Tag `102`, followed by `[index, arguments]`            |

The extended constructor decoder requires an unsigned 64-bit index and
exactly two outer array elements. The Haskell constructor accepts arbitrary
`Integer`, but negative/out-of-range indices emitted by the encoder's
fallback do **not** therefore have a successful decoder round trip. The
source explicitly comments on this soft-failure case.

`I` uses CBOR major types 0/1 when within their unsigned-argument ranges.
Larger magnitudes use tags 2/3 and big-endian magnitude byte strings;
negative bignums encode `-1-i`. `B` uses CBOR byte strings. `Map` writes a
definite pair count and iterates the supplied pairs in order; `List` and
constructor argument arrays use the list `Serialise` implementation.

### Access model

The reference decoder recursively builds `Data` values. There is no declared
field-offset table, native aligned overlay or lazy mmap access contract.
To retrieve a field from a CBOR constructor array, a generic reader must
parse or skip earlier variable-sized items.

The ledger wraps decoded `PlutusData` in [`MemoBytes`][ledger-data], retaining
the serialized bytes. It also has `BinaryData` for compact inline storage.
This is byte preservation for encoding/hashing and storage efficiency,
not an SSZ-style tree of independently addressable child roots.

### Variable-length and optional data

Lists, argument arrays, maps and byte strings can have variable sizes.
The decoder accepts both definite and indefinite collection forms. For
byte strings it imposes a special per-chunk limit: each definite chunk
must contain at most 64 bytes ([bounded decoder][data]).

The encoder writes a byte string of at most 64 bytes directly; a longer one
becomes an indefinite byte string of chunks no larger than 64 bytes,
terminated by a break. The same machinery applies to bignum magnitude bytes.
This is not a 64-byte cap on the whole `Data` value or even on the total
decoded byte string.

Optional application values require an explicit constructor convention.
At the ledger-output layer, `NoDatum`, `DatumHash` and `Datum` form a
separate sum type; they are not extra constructors of Plutus Core `Data`
([ledger datum type][ledger-data]).

### Evolution and compatibility

Changing a user datatype's constructor numbering or argument order changes
its interpretation. The primitive CBOR decoder cannot infer an old-to-new
schema migration from source-language names. A contract must establish
which version of the application mapping it expects.

The [data stability tests][stability] preserve acceptance of both historical
definite-list encodings and later indefinite-list encodings that decode to
equal values. They document a real representation change, not a hypothetical
CBOR permissiveness issue. Ledger `upgradeData` also explicitly notes that
re-serialization for a different era can change memoized bytes
([ledger implementation][ledger-data]).

### Determinism and canonical form

Plutus Data is **not** [DAG-CBOR][ipld] or [dCBOR][dcbor]. It uses constructor
tags, bignums and indefinite byte strings that those profiles handle
differently or prohibit. A generic “canonical CBOR” mode can therefore
produce bytes that are wrong for this protocol.

The source encoder preserves `Map` pair order instead of sorting it or
checking uniqueness. A decoder accepting definite and indefinite forms
admits multiple encodings of the same decoded `Data`. Round-trip semantic
equality does not imply byte equality, nor does deterministic output from
one encoder establish canonical acceptance across the ledger.

The ledger's retained original bytes are therefore significant. Do not
decode a received datum, normalize it with a generic CBOR library, and
assume its hash is unchanged. The [content-addressing concepts][ca] explain
the distinction between byte identity and application equality.

### Merkleization and content addressing

The relevant ledger chain is visible in code:

```text
Data era = MemoBytes (PlutusData era)
hashData = hashAnnotated
hashAnnotated = getMemoSafeHash
DataHash = SafeHash EraIndependentData
HASH = Blake2b_256
```

[`Plutus/Data.hs`][ledger-data] establishes the memoized-byte path;
[`MemoBytes/Internal.hs`][memo] constructs the cached hash from those exact bytes;
[`Hashes.hs`][hashes] establishes the algorithm and phantom index. The
commitment is over the serialized datum bytes. It does not recursively
replace each child with its hash or add leaf/branch domain prefixes.

```text
Constr i [child-A, child-B]
  -> one CBOR serialization containing both children
  -> BLAKE2b-256(serialized bytes)
  -> datum hash
```

There is no built-in datum-level binary tree shape, length mix-in, sibling
proof or generalized index. To validate a datum against its hash, provide
the complete relevant bytes. A nested `B` value containing 32 bytes is
still an uninterpreted byte string; it becomes a child commitment only
when a particular contract assigns that meaning and verifies it.

The `EraIndependentData` phantom type distinguishes hash uses in Haskell.
It is not evidence that a textual type tag is prepended to the digest
preimage. An inline datum's enclosing tag-24 representation is also a
separate wrapper: `dataToBinaryData` preserves the inner datum bytes.
Neither the datum hash nor that wrapper authenticates arbitrary field proofs.

Transaction/block commitments elsewhere in Cardano do not change this
finding about `Data`. An application's explicit Merkle scheme must specify
its own child encoding, ordering, domain separation and proof checks; it
cannot be attributed to Plutus Data merely because the host blockchain
uses cryptographic hashes.

### Hostile-input safety

The decoder rejects unsupported CBOR token kinds, unrecognized constructor
tags, byte chunks over 64 bytes and malformed extended-constructor arrays.
It checks a bignum's payload kind and tag. The ledger's `makeBinaryData`
smart constructor validates bytes before exposing the compact wrapper
([Data decoder][data], [ledger validation][ledger-data]).

The 64-byte chunk limit is not a total allocation or recursion bound.
An attacker can still supply many chunks or deeply nested lists. Transaction
size limits and script execution budgets remain separate constraints.
Application conversion must reject wrong constructor shapes rather than
treating any successfully decoded `Data` as a valid datum for the contract.

### Describing foreign formats

Not applicable as a general foreign-layout description facility. `B` can
contain a font, archive or another encoding as opaque bytes, but `Data`
does not describe that payload's fields, endianness, offsets or alignment.
A separate parser must interpret it.

For the [Flat draft][flat], the most relevant negative evidence is that a
recursive value algebra and a whole-value hash do not supply in-place
field access or partial authentication. Flat's opaque input-derived key
must likewise not be presented as an integrity hash of the emitted arena
or as a recursive Merkle commitment.

### Implementation and performance evidence

**Runnable independent representation check, not a Plutus decoder.**
This recognizes only the two empty constructor-zero forms selected here.
It demonstrates why preserving bytes matters; it does not calculate a
datum hash or claim SHA-256 is Cardano's datum-hash algorithm.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_plutus_data_byte_identity"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

bool isEmptyConstructorZero(in ubyte[] bytes) @safe pure nothrow @nogc
{
    enum ubyte[3] definite = [0xd8, 0x79, 0x80];
    enum ubyte[4] indefinite = [0xd8, 0x79, 0x9f, 0xff];
    return bytes == definite || bytes == indefinite;
}

void main() @safe
{
    const ubyte[] a = [0xd8, 0x79, 0x80];
    const ubyte[] b = [0xd8, 0x79, 0x9f, 0xff];
    assert(isEmptyConstructorZero(a) && isEmptyConstructorZero(b));
    assert(a != b);
    writeln("empty constructor-zero forms: ", a.length, " and ", b.length, " bytes");
    writeln("same selected value does not imply identical serialized bytes");
}
```

```ansi
empty constructor-zero forms: 3 and 4 bytes
same selected value does not imply identical serialized bytes
```

**Source test vectors, not local execution.** The `auction_1-1` case in
[`CBOR/DataStability.hs`][stability] asserts that these exact inputs decode
to equal `Data` values:

```text
d87982581cbd99a373075d42fe4ac9109515e46303d0940cb9620bf058b87986a9d87980
d8799f581cbd99a373075d42fe4ac9109515e46303d0940cb9620bf058b87986a9d87980ff
```

Both represent constructor zero with a 28-byte string argument and an
empty constructor-zero argument. `82` is the definite two-element array;
`9f ... ff` is its indefinite counterpart. The bytes differ, so semantic
decoder equality alone cannot justify treating their byte commitments as
identical. The test does not claim their datum hashes are equal.

No D port or binding was verified in this survey.
The source includes other larger historical fixtures and explicit bounded
byte-string decoding. No Haskell build, ledger hash probe or performance
benchmark was run locally. Comments about historic performance experiments
are not measurements reproduced by this survey.

## Strengths

- Small portable algebra with explicit constructor and bignum encodings.
- Source fixtures preserve real historical decoding compatibility.
- Ledger byte memoization makes the commitment preimage explicit.

## Weaknesses

- Application schemas and constructor numbering are external agreements.
- Multiple accepted encodings prevent assuming universal byte canonicality.
- A datum hash provides no built-in partial-value proof mechanism.

## Key design decisions and trade-offs

| Decision                           | Rationale                               | Trade-off                                           |
| ---------------------------------- | --------------------------------------- | --------------------------------------------------- |
| Sum-of-products `Constr`           | Represent user datatypes without names  | Constructor indices become a compatibility contract |
| Chunk long byte strings            | Bound contiguous on-wire payload chunks | Indefinite encodings and multiple accepted forms    |
| Preserve original serialized bytes | Keep ledger identity stable             | Decoded equality is insufficient for hash equality  |
| Whole-datum hash                   | Simple commitment boundary              | No recursive field proofs without another protocol  |

## Sources

- [`PlutusCore.Data`][data], [`IsData`][isdata] and [data stability tests][stability].
- [Ledger datum/byte wrappers][ledger-data] and [hash definitions][hashes].
- [Memoized-byte hash construction][memo].
- [Shared concepts][concepts], [comparison][comparison] and [content-addressing recommendations][recommendations].

<!-- References -->

[repo]: https://github.com/IntersectMBO/plutus/tree/7ab93b9ddb3ec11c2d89b9dc9c6d6e6af4544917
[ledger]: https://github.com/IntersectMBO/cardano-ledger/tree/178bd36839dcb57f257efc0e96615284d1632088
[data]: https://github.com/IntersectMBO/plutus/blob/7ab93b9ddb3ec11c2d89b9dc9c6d6e6af4544917/plutus-core/plutus-core/src/PlutusCore/Data.hs
[isdata]: https://github.com/IntersectMBO/plutus/blob/7ab93b9ddb3ec11c2d89b9dc9c6d6e6af4544917/plutus-tx/src/PlutusTx/IsData.hs
[stability]: https://github.com/IntersectMBO/plutus/blob/7ab93b9ddb3ec11c2d89b9dc9c6d6e6af4544917/plutus-core/plutus-core/test/CBOR/DataStability.hs
[ledger-data]: https://github.com/IntersectMBO/cardano-ledger/blob/178bd36839dcb57f257efc0e96615284d1632088/libs/cardano-ledger-core/src/Cardano/Ledger/Plutus/Data.hs
[hashes]: https://github.com/IntersectMBO/cardano-ledger/blob/178bd36839dcb57f257efc0e96615284d1632088/libs/cardano-ledger-core/src/Cardano/Ledger/Hashes.hs
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[serde]: ../serde/concepts.md
[ca]: ../content-addressing/concepts.md
[recommendations]: ../content-addressing/recommendations.md
[ipld]: ./ipld.md
[dcbor]: ./cbor-cose-dcbor.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[memo]: https://github.com/IntersectMBO/cardano-ledger/blob/178bd36839dcb57f257efc0e96615284d1632088/libs/cardano-ledger-core/src/Cardano/Ledger/MemoBytes/Internal.hs
