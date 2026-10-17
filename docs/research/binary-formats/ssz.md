# Simple Serialize / SSZ (Ethereum / Python)

A schema-directed binary encoding with a separate typed-value Merkle commitment and explicit proof positions.

| Metadata         | Value                                                                   |
| ---------------- | ----------------------------------------------------------------------- |
| Language         | Python reference specification; implementations in multiple languages   |
| License          | MIT for `ethereum/ssz-specs`                                            |
| Repository       | [`ethereum/ssz-specs`][repo]                                            |
| Documentation    | [Reference README][readme]; [historical `v1.6.0` specification][legacy] |
| Category         | Consensus serialization and typed-value Merkleization                   |
| Reference pin    | `c68b96a852559284cc4311b6c14105bcf51ac6ce`                              |
| Historical pin   | Consensus specs `v1.6.0`, `f96d3e7acf35125295d234da4b0c67591fdef49c`    |
| Extension status | EIP-7495 and EIP-7916: Review; EIP-8016: Draft at the [EIPs pin][eips]  |

## Overview

### What it solves

Ethereum consensus needs compact wire values and commitments that support
proofs about individual fields. SSZ supplies both, but they are different
algorithms: serialization writes the value using a known type;
`hash_tree_root` builds a tree determined by that type. It is not simply
SHA-256 of the wire bytes ([historical specification][legacy], [root code][roots]).

This distinction matters for a binary-format survey. Offsets are wire-layout
metadata; list capacities determine tree shape; neither makes the resulting
root a self-describing schema identifier. The shared [content-addressing
concepts][ca] and [serde concepts][serde] supply the broader vocabulary.

### Design philosophy

The official [reference README][readme] states:

> Simple Serialize (SSZ) is a serialization and hashing scheme used by Ethereum.

It immediately identifies the Python project as the reference implementation
serving as the official specifications. In the [historical specification][legacy],
objects implicitly carry their types. That assumption is essential: a bare
buffer or root is not sufficient to recover an SSZ type.

## How it works

SSZ separates three related views:

```text
schema + value -> serialize -> little-endian fields / offsets / tails
schema + value -> hash_tree_root -> 32-byte root
schema + path  -> generalized index -> proof location
```

A basic integer root can be its little-endian encoding padded to 32 bytes,
with no SHA-256 invocation at all. Collections pack basic values into chunks,
but use one recursively computed root per composite element. Consequently
wire-byte adjacency and proof adjacency need not coincide ([layout code][layout]).

### Schema source of truth

The schema fixes integer widths, container field order, vector lengths,
list bounds and union alternatives. The [reference types][readme] declare
these through Python subclasses and class constants; the historical text
uses parameterized mathematical types. The schema is external to the wire.

There are no general field names, type descriptors or schema hashes in an
SSZ buffer. Container field names help path resolution and compatibility
checks, while ordinary container serialization remains positional. A root
must therefore be interpreted under an independently agreed type/fork.

### Wire encoding

Unsigned integers use fixed-width little-endian bytes; booleans are exactly
`00` or `01`. Fixed-width fields appear inline. Each variable-width field
occupies a four-byte little-endian offset in the fixed part; its payload is
appended in field order. Offsets are relative to the containing value's
start, not process addresses ([container implementation][container]).

For a variable-element list the first offset also determines the number of
offset entries: divide it by four. Element extents come from adjacent
offsets and the enclosing byte scope. A list of fixed-width elements instead
gets its count from byte length divided by element width. A decoder needs
the total scope; SSZ is not generally self-delimiting.

Bitvectors pack low bit first. Bitlists add a final set delimiter bit to
encode the actual bit length. The delimiter is part of the wire encoding
but excluded from the data bits used for Merkleization ([historical spec][legacy]).

### Access model

The Python reference decodes values to objects. The offset layout permits
specialized readers to locate some variable fields without decoding every
payload, but SSZ does not promise an aligned native object overlay.
Little-endian values and unaligned fields still require appropriate loads.

Proofs use [generalized indices][gindex] to name tree nodes. Packed basic
elements can share a chunk; proving one such element ordinarily reveals its
whole chunk plus a path. A byte offset alone is not a generalized index,
and a wire slice alone is not a complete proof.

### Variable-length and optional data

`List[T,N]` has a declared maximum and an actual count. Vectors have a fixed
count. A union is always considered variable-width, including when every
alternative happens to have equal width ([historical spec][legacy]).

The historical `Union[None,T,...]` uses selector zero for `None`, permitted
only as the first alternative. A none value serializes as the selector byte
alone; other alternatives serialize `selector || payload`. It is not the
same construct as `CompatibleUnion`, whose selectors are declared mappings
in the range 1 through 127 and whose alternatives must Merkleize compatibly
([union implementation][union]).

`ProgressiveContainer` does not attach an arbitrary runtime presence bitmap
to every serialized value. `ACTIVE_FIELDS` is part of the declared type,
assigning stable positions and gaps; only active fields consume wire space.
The bitmap participates in the root ([container][container], [layout][layout]).

### Evolution and compatibility

For bounded lists, the maximum capacity affects tree depth. For ordinary
containers, crossing a power-of-two field-count boundary changes existing
field positions in the tree. Wire appendability alone does not preserve
proof coordinates ([EIP-7495][progressive-container]).

Progressive types address this through a spine of subtrees with capacities
1, 4, 16, 64 and so on. Field/chunk generalized indices can remain stable
as the populated extent grows. This preserves **locations**, not old proof
bytes or old roots: appending changes ancestor hashes and proofs against
the updated root still need updated siblings.

> [!IMPORTANT]
> Status is versioned. The `v1.6.0` text marks progressive types and compatible
> unions “currently unused.” At the separately pinned [consensus README][consensus],
> Gloas and Heze remain unstable; their presence in specification code is not
> evidence of a deployed fork. The pinned EIPs classify progressive containers
> and lists as Review and compatible unions as Draft.

### Determinism and canonical form

Serialization is injective **within a type**. Strict decoding rejects
gaps, overlaps, malformed offsets and trailing bytes. It does not mean that
the same bytes identify one type across all schemas. The source includes
cross-layout confusion tests precisely because wire encodings and roots
answer different identity questions ([canonicality tests][canonicality]).

The [new reference tree implementation][trees] places each progressive
level's bounded subtree on the **left**, and the successor spine on the
**right**. The historical `v1.6.0` prose describes those operands in the
opposite order. Likewise, the new [selector helper][mixins] explicitly
zero-extends a selector to 32 bytes and calls out the historical literal
`uint8` reading. There is also an inactive-position difference: the historical
progressive-container formula Merkleizes the roots of present values, while
the new reference explicitly inserts zero roots at inactive field positions.
For `ACTIVE_FIELDS = [1,0,1]`, a literal reading of the historical formula
supplies two roots; the new layout supplies three positions including the gap
([historical text][legacy], [new layout][layout]).
Implementers must pin the chosen specification and test
vectors; this page does not silently assert these snapshots are identical.

### Merkleization and content addressing

For ordinary SSZ, chunks are 32 bytes. `merkleize` pads with zero chunks
to the next power of two of the type's chunk limit, then computes binary
parents as `SHA256(left || right)`. A single chunk is its own root. Basic
values are packed; composite children are recursively rooted ([trees][trees]).

```text
three field roots r0,r1,r2:
R = SHA256(SHA256(r0||r1) || SHA256(r2||ZERO32))

bounded list:
R = SHA256(merkleize(data-chunks, capacity-chunks) || LE256(actual-count))
```

For bitlists the count is in bits; for lists it is in elements, not serialized
bytes. List length mixing distinguishes trailing zero values from padding.
Vectors do not mix a length. SSZ does not prepend CometBFT-style `00` and
`01` domain bytes to every leaf and branch: its type-directed layout and
mix-ins provide the relevant structural context ([mix-ins][mixins]).

At the new reference pin, a progressive list uses the progressive tree plus
the actual-count mix-in. A progressive container inserts zero roots at its
inactive positions and mixes in the 256-bit active-fields word. A compatible
union mixes the selected option's root with its zero-extended selector word.
The bitmap prevents an absent field from collapsing into an active zero
field ([layout][layout]).

SSZ roots are typed-value commitments, not [CID][ipld] wrappers and not
input-derived build keys. Some distinct types deliberately share a root,
including summary/expansion forms where a nested value is replaced with
its root. Type identity or fork identity therefore needs external binding.
Proofs authenticate a subtree/chunk under that agreed layout, not the
meaning or authorization of the enclosing consensus root.

### Hostile-input safety

Check the exact enclosing scope, minimum fixed-part size, first offset,
monotonic offsets, divisibility, list limits and valid boolean/bit padding.
The [container decoder][container] validates the offset table before reading
variable payloads. A wrong selector must fail before choosing an option.

Progressive “unbounded” means no type-level capacity, not unlimited safe
resource consumption. The [EIP][progressive-list] still cites offset-width,
network and execution limits. Depth, work and allocation limits remain
necessary for hostile nested values. Hash verification does not replace
syntax/type validation.

### Describing foreign formats

Not a foreign-layout language. SSZ's integer byte order, offset width,
container rules and tree semantics are prescribed. A codec cannot describe
an existing big-endian font table by merely annotating an SSZ integer.
Such input needs a separate parser and conversion into the SSZ value model.

For the [Flat draft][flat], the lesson is architectural rather than a wire
format to adopt: keep layout identity, output-byte integrity and the opaque
hash of build inputs separate. Adopting SSZ Merkleization would require
an explicit typed commitment policy, proof API and schema/fork context.

### Implementation and performance evidence

**Runnable independent invariant check, not a reference implementation.**
This checks padding versus hashing and list-length mixing, not a full SSZ
codec, generalized indices or progressive-type conformance.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "research_ssz_commitment_invariants"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.digest.sha : sha256Of;
import std.stdio : writeln;

void main() @safe
{
    ubyte[32] scalarRoot;
    scalarRoot[0] = 42; // uint64(42), little-endian, then zero padding
    const ubyte[8] wire = [42, 0, 0, 0, 0, 0, 0, 0];
    assert(scalarRoot != sha256Of(wire[]));
    ubyte[32] lengthOne, lengthTwo;
    lengthOne[0] = 1;
    lengthTwo[0] = 2;
    const one = sha256Of(scalarRoot[] ~ lengthOne[]);
    const two = sha256Of(scalarRoot[] ~ lengthTwo[]);
    assert(one != two);
    writeln("scalar root is padded bytes, not SHA256(wire)");
    writeln("equal data chunks with lengths 1 and 2 have different roots");
}
```

```ansi
scalar root is padded bytes, not SHA256(wire)
equal data chunks with lengths 1 and 2 have different roots
```

**Source vectors, not local execution.** The [progressive-bitlist tests][bits]
assert these exact wire encodings:

| Data bits, low bit first | Hex    |
| ------------------------ | ------ |
| Empty                    | `01`   |
| `1`                      | `03`   |
| `0,1,0`                  | `0a`   |
| `1,1,0,1,0,1,0,0`        | `2b01` |

The same tests cover delimiter movement at 255, 256 and 257 bits. These are
wire vectors, not root vectors; hashing the displayed byte strings would
not reproduce `hash_tree_root`. The [reference README][readme] describes
release fixtures carrying encoded values, roots and generalized indices.

No D port or binding was verified in this survey. No local Python suite or
performance benchmark was run. The reference's
root memoization and cached zero subtrees are implementation evidence,
not a throughput comparison with native implementations. The historical
versus reference orientation/selector/inactive-position differences remain explicit
interoperability limitations of comparing these pins.

## Strengths

- Wire layout and typed Merkle layout are independently specified.
- Length mixing, packed leaves and generalized indices have concrete rules.
- Progressive proposals address stable proof coordinates explicitly.

## Weaknesses

- Roots and wire bytes do not self-identify their type or fork.
- Capacity choices can become proof-compatibility commitments.
- Extension status and historical/reference differences demand exact pins.

## Key design decisions and trade-offs

| Decision                     | Rationale                           | Trade-off                                          |
| ---------------------------- | ----------------------------------- | -------------------------------------------------- |
| External schema              | Avoid per-value type metadata       | Wrong schema can reinterpret bytes                 |
| Separate typed Merkleization | Enable field/subtree proofs         | Not the hash of serialized bytes                   |
| Capacity-sized bounded trees | Fixed positions under a schema      | Large limits add zero-subtree hashing              |
| Progressive spine and bitmap | Stable positions across growth/gaps | Different tree family and revision-sensitive rules |

## Sources

- [Official reference][readme], [root][roots], [tree][trees], [layout][layout] and [mix-in][mixins] code.
- [Historical specification][legacy] and [consensus fork-status table][consensus].
- [EIP-7495][progressive-container], [EIP-7916][progressive-list], [EIP-8016][compatible-union].
- [Shared concepts][concepts] and [comparison][comparison].

<!-- References -->

[repo]: https://github.com/ethereum/ssz-specs/tree/c68b96a852559284cc4311b6c14105bcf51ac6ce
[readme]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/README.md
[legacy]: https://github.com/ethereum/consensus-specs/blob/f96d3e7acf35125295d234da4b0c67591fdef49c/ssz/simple-serialize.md
[consensus]: https://github.com/ethereum/consensus-specs/blob/460fd37c3a58f6baf8a9a285d2adf71c4f818929/README.md
[roots]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/roots.py
[trees]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/trees.py
[layout]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/layout.py
[mixins]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/mixins.py
[container]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/container.py
[union]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/union.py
[gindex]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/src/ssz/gindex.py
[canonicality]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/tests/test_canonicality.py
[bits]: https://github.com/ethereum/ssz-specs/blob/c68b96a852559284cc4311b6c14105bcf51ac6ce/tests/test_bitfields.py
[eips]: https://github.com/ethereum/EIPs/tree/5930e94b0cdb7b88f8c96c75555cf4fc2b3cb3b0
[progressive-container]: https://github.com/ethereum/EIPs/blob/5930e94b0cdb7b88f8c96c75555cf4fc2b3cb3b0/EIPS/eip-7495.md
[progressive-list]: https://github.com/ethereum/EIPs/blob/5930e94b0cdb7b88f8c96c75555cf4fc2b3cb3b0/EIPS/eip-7916.md
[compatible-union]: https://github.com/ethereum/EIPs/blob/5930e94b0cdb7b88f8c96c75555cf4fc2b3cb3b0/EIPS/eip-8016.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[ca]: ../content-addressing/concepts.md
[serde]: ../serde/concepts.md
[ipld]: ./ipld.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
