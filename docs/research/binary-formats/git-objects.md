# Git objects (C)

Stable typed object bytes beneath replaceable compressed storage, not an in-place record format.

| Field         | Value                                                                  |
| ------------- | ---------------------------------------------------------------------- |
| Language      | C                                                                      |
| License       | GPL-2.0; see upstream `COPYING`                                        |
| Repository    | [git/git][repo]                                                        |
| Documentation | [Loose objects][loose] · [Pack format][pack]                           |
| Category      | Content-addressed object framing                                       |
| D bindings    | No D binding surveyed; the inline probe uses Phobos, not a Git binding |

> [!NOTE]
> This deliberately short page concerns **encoding boundaries**. The existing
> [Git content-addressing page][ca] owns tree ordering, modes and subtree identity;
> [content-addressing concepts][ca-concepts] and [recommendations][ca-recommendations]
> own the hash/tree comparison. See also this survey's [concepts][concepts] and
> [comparison][comparison].

## Overview

### What it solves

Git lets the same logical object survive loose storage, repacking and delta
compression without changing its identifier. Its object frame commits to a type
and payload length, while its storage containers make independent choices about
compression and lookup. Those are different boundaries, not two encodings to
hash interchangeably. [Loose objects][loose] and [packs][pack] specify the distinction.

### Design philosophy

The [pack specification][pack] makes the separation explicit:

> The computation of the object ID still uses this prefix by reconstructing it
> from the type and length as needed.

The prefix is the logical object's `type`, ASCII space, decimal payload size and
NUL. A packed delta's size is instead the uncompressed **delta instruction
stream** size, not the final object's payload size. [Pack format][pack]

## How it works

### Schema source of truth

The [loose-object specification][loose] defines the outer grammar. Type-specific
parsers define `blob`, `tree`, `commit` and `tag` payloads; the [existing survey][ca]
links the tree implementation. There is no external schema compiler.

### Wire encoding

The uncompressed identity frame is `type SP decimal-size NUL payload`.
Loose files compress that entire frame with zlib. Packs start with `PACK`,
network-order version and object count, then variable-size entry headers and
zlib streams; a delta additionally identifies a base by digest or backwards
offset. **Pack entry size is not a compressed-byte extent.** Locating the next
entry requires the compressed stream boundary or an index. [Loose][loose], [pack][pack]

Local framing probe, executed with the installed Git, without writing an object:

```bash
printf abc | git hash-object --stdin
printf 'blob 3\000abc' | od -An -tx1
```

Observed output, not a benchmark:

```text
f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f
 62 6c 6f 62 20 33 00 61 62 63
```

The second command exposes the exact ten-byte **hash input**, not a loose file's
compressed bytes. It agrees with the [official `abc` example][loose].

### Access model

Object lookup is indexed, but compressed payload access is not a borrowed native
record. Delta objects require base reconstruction. The pack index supplies
offsets and fan-out lookup; it does not turn a blob into a field-addressable
schema. [Pack format][pack]

### Variable-length and optional data

Decimal lengths and NUL-terminated type headers frame arbitrary payloads.
Tree entries combine textual mode/name with a fixed-width raw object ID whose
width follows the repository algorithm. Delta instructions conditionally include
offset and size bytes according to flag bits; omitted bytes retain their fixed
significance, rather than shifting later bytes down. [Loose][loose], [pack][pack], [tree details][ca]

### Evolution and compatibility

Pack versions are explicit; the cited implementation accepts versions `2` and
`3` and emits `2`. Object hash choice is repository context, not a per-entry
algorithm tag. SHA-256 changes embedded ID widths and therefore tree payloads;
it is not merely a longer filename. [Pack format][pack], [tree details][ca]

### Determinism and canonical form

Object identity commits to exact logical bytes. Different zlib output or delta
bases can represent the same object. Canonical tree checks are separate from
outer framing; a correct outer digest does not prove canonical names or ordering.
The [content-addressing page][ca] owns those checks.

### Merkleization and content addressing

See [Git's tree analysis][ca]; it is not repeated here. For framing, the important
fact is that type and size participate in the digest, while compression and pack
offsets do not. A Git object ID establishes identity relative to a known digest,
**not signer authority**. Commit/tag signatures are an additional layer, outside
this frame's contract. [Loose][loose], [pack][pack]

### Hostile-input safety

A reader must cap inflation, validate size parsing and delta arithmetic, bound
base-chain work and verify the reconstructed logical object. Neither a pack
CRC nor an advertised uncompressed size permits unchecked allocation. These are
parser obligations implied by the [pack grammar][pack], not a claim that all
Git entry points apply identical resource policy. Structural tree validation
remains a separate operation. [Tree validation][ca]

### Describing foreign formats

Not a general format-description language. A `blob` can contain any foreign
format, but Git does not expose its fields. For a fixed-layout reader, the useful
lesson is the separation of **logical authenticated extent**, compressed extent
and storage index—not adoption of Git's variable-width grammar. [Loose][loose], [pack][pack]

### Implementation and performance evidence

The local probe establishes one ten-byte identity frame and its SHA-1 object ID.
The [pack specification][pack] supplies source evidence for delta compression and
indexed lookup. No throughput, allocation or compression-ratio measurements
were performed; the framing probe is not CI-registered.

#### CI-verified independent framing probe

This small independent probe checks the cited logical frame and SHA-1 result
with Phobos, not Git's storage codec. The upstream-tool probe above remains
separate evidence; CI compiles and runs this example.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_git_frame_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.digest : toHexString;
import std.digest.sha : sha1Of;
import std.stdio : writeln;

void main() @safe
{
    immutable frame = "blob 3\0abc";
    assert(frame.length == 10);
    assert(frame[6] == '\0' && frame[7 .. $] == "abc");
    immutable digest = sha1Of(frame).toHexString;
    assert(digest == "F2BA8F84AB5C1BCE84A7B441CB1959CFC7093B7F");
    writeln("frame bytes: ", frame.length);
    writeln("SHA-1: ", digest);
}
```

```ansi
frame bytes: 10
SHA-1: F2BA8F84AB5C1BCE84A7B441CB1959CFC7093B7F
```

## Strengths

- Type-and-length identity is independent of storage representation.
- A ubiquitous reference tool makes exact-byte differential probes inexpensive.

## Weaknesses

- Compressed and delta storage requires reconstruction, not direct record access.
- Digest width and interpretation require repository context.
- A matching hash alone says nothing about publisher authorization.

## Key design decisions and trade-offs

| Decision                            | Rationale                                      | Trade-off                                           |
| ----------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| Hash logical typed frame            | Repacking preserves identity                   | Every reader reconstructs the same frame            |
| Separate compressed storage grammar | Delta and compression can evolve independently | Multiple sizes and boundaries must not be conflated |
| Repository-level hash choice        | Compact embedded object references             | Raw tree bytes are not algorithm-self-describing    |

## Sources

- [Loose-object specification][loose] — logical prefix and compressed storage.
- [Pack specification][pack] — container boundaries, delta sizes and instructions.
- [Existing Git tree research][ca] — complementary analysis rather than duplication.

<!-- References -->

[repo]: https://github.com/git/git/tree/f78ce2f7b6df702f93d40b85d6bda92a3f65da79
[loose]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitformat-loose.adoc
[pack]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/Documentation/gitformat-pack.adoc
[ca]: ../content-addressing/git-objects.md
[ca-concepts]: ../content-addressing/concepts.md
[ca-recommendations]: ../content-addressing/recommendations.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
