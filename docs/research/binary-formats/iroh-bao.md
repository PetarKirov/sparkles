# iroh / Bao (Rust)

Verified streaming frames whose tree geometry comes from a claimed length and an externally known root.

| Field         | Value                                                                  |
| ------------- | ---------------------------------------------------------------------- |
| Language      | Rust                                                                   |
| License       | Bao: CC0-1.0 OR Apache-2.0; iroh-blobs and bao-tree: MIT OR Apache-2.0 |
| Repository    | [iroh-blobs][iroh] · [bao-tree][tree] · [Bao][bao]                     |
| Documentation | [Bao encoding specification][spec] · [iroh protocol][protocol]         |
| Category      | Authenticated streaming and range framing                              |
| D bindings    | No D binding surveyed; the inline probe checks framing only            |

> [!NOTE]
> This short page owns the **frame and length trust** discussion. Hash internals,
> outboards and tree composition belong to the [existing Bao/BLAKE3 page][ca],
> [content-addressing concepts][ca-concepts] and [recommendations][ca-recommendations].
> Original Bao's 1 KiB leaves and iroh's 16 KiB chunk-group transmission are
> distinct profiles; the bytes below are not an iroh request vector.

## Overview

### What it solves

An ordinary whole-file hash cannot authenticate a prefix before the rest of the
file arrives. Bao transmits enough intermediate hashes to verify each selected
portion against a known BLAKE3 root. Its wire framing must therefore distinguish
bytes that can already be released from metadata that remains untrusted.
[Bao decoder contract][spec]

### Design philosophy

The [Bao specification][spec] states the crucial boundary:

> The length itself is considered validated _when and only when_ the decoder
> validates the final chunk

It further prohibits exposing that length before this validation. iroh's
[protocol goals][protocol] put the same priority plainly: “Be paranoid about
data integrity.” Authenticating some returned bytes is not authenticating every
property of the enclosing object.

## How it works

### Schema source of truth

[Bao's specification][spec] defines combined, outboard and slice encodings.
[iroh's protocol module][protocol] adds requests, collection selection and chunk
ranges. [`bao-tree`][tree] implements geometry and traversal for selectable block
sizes. This is a specialized protocol, not a general-purpose data schema.

### Wire encoding

Original Bao's combined frame starts with an eight-byte little-endian unsigned
payload length, then a preorder interleave of parent records and payload chunks.
A parent is exactly two 32-byte chaining values. Outboards omit payload chunks;
slices omit unvisited subtrees but still include selected payload inline.
[Bao encoding specification][spec]

**Precise upstream vector, not locally executed:**
[`tests/test_vectors.json`][vectors] specifies `input_len: 0`, `output_len: 8`
and BLAKE3 root
`af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`.
The [format rule][spec] makes that entire encoding:

```text
00 00 00 00 00 00 00 00
```

There is no parent record for this one empty leaf. A decoder still verifies the
empty leaf against the expected root before returning EOF; eight zero bytes are
not a universal valid empty encoding under arbitrary roots. [Decoder][spec]

### Access model

Sequential combined decoding needs no seeking. Outboard decoding reads metadata
and original bytes separately. Range verification follows the traversal for
the requested offsets; transport bytes are not a native-memory view. iroh
requests are in 1024-byte BLAKE3 chunks and may round byte requests outward;
transmission has a minimum 16 KiB chunk-group granularity. The application must
discard authenticated surrounding bytes it did not request. [Bao][spec], [iroh][protocol]

### Variable-length and optional data

Node positions and extents are reconstructed from length, range selection and
block size, not per-node tags. Original Bao treats a zero-byte slice request as
selecting a chunk, and an offset at or past EOF includes the final chunk. This
is a security-relevant boundary rule, not conventional empty-range semantics.
[Slice format][spec]

### Evolution and compatibility

The [Bao specification][spec] distinguishes its BLAKE3 profile from the earlier
BLAKE2-based format. An eight-byte length is not a version discriminator. A
consumer must select the agreed format/profile outside this prefix; it must not
assume an original Bao frame and an iroh chunk-group response are interchangeable.
[iroh protocol][protocol]

### Determinism and canonical form

Traversal is determined by the agreed profile, ranges and length, but successful
decoding does **not** imply a unique transport byte string. Bao explicitly allows
trailing bytes because it need not read transport EOF once the selected content
is decoded. A containing protocol needing an exact frame must separately enforce
consumption. Payload identity and canonical envelope identity are different
contracts. [Malleability discussion][spec]

### Merkleization and content addressing

The [existing tree analysis][ca] owns BLAKE3's chunk/parent/root domain separation.
For framing, parent chaining values are not arbitrary calls to the public root
hash function. Verification is rooted in a separately obtained expected hash;
the response does not acquire authority by sending its own root. Bao supplies
integrity, not a signature or publisher trust policy. [Decoder][spec]

### Hostile-input safety

The length header is initially a claim. Do not allocate that amount or report it
as authenticated merely because an earlier group verified. Before exposing EOF,
end-relative seek results or length, validate the final chunk. Handle short reads
with exact-read loops; a nine-byte read must not satisfy a claimed ten-byte final
leaf. Cap traversal/work independently of eventual hash failure. These are
explicit failure modes in the [decoder/security discussion][spec].

### Describing foreign formats

Not applicable as a schema mechanism: Bao authenticates arbitrary bytes but
does not describe their fields. A mapped foreign-format record can be placed
inside a Bao blob, but field availability then depends on verified range
coverage, including chunk-group expansion. Bounds-safe access and authenticated
access remain separate predicates. [Range selection][protocol]

### Implementation and performance evidence

The cited [upstream vectors][vectors] specify empty, boundary and multi-chunk
cases; no Bao encoder was built locally. iroh's [protocol comments][protocol]
claim about two chunk groups of worst-case range overfetch; this is a source
claim, not a local bandwidth benchmark. No throughput measurements are reported.
See the [broader iroh survey][iroh-survey] for implementation context.

#### CI-verified independent framing probe

This small independent probe checks the cited empty vector's length header and
an exact outer-frame boundary. It does **not** implement BLAKE3, authenticate
the empty leaf, or require Bao decoders to reject trailing bytes; that last
condition belongs to this probe's stricter containing-frame policy.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_bao_frame_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.digest : toHexString;
import std.stdio : writeln;

bool exactEmptyFrame(in ubyte[] frame) @safe pure nothrow @nogc
{
    if (frame.length != 8)
        return false;
    foreach (b; frame)
        if (b != 0)
            return false;
    return true;
}

void main() @safe
{
    immutable ubyte[8] emptyFrame = 0;
    immutable ubyte[9] trailingByte = 0;
    immutable ubyte[8] nonemptyClaim = [1, 0, 0, 0, 0, 0, 0, 0];
    assert(exactEmptyFrame(emptyFrame));
    assert(!exactEmptyFrame(trailingByte));
    assert(!exactEmptyFrame(nonemptyClaim));
    writeln("empty frame: ", emptyFrame[].toHexString);
    writeln("outer boundary checked; root verification not performed");
}
```

```ansi
empty frame: 0000000000000000
outer boundary checked; root verification not performed
```

## Strengths

- Bytes can be authenticated before the entire blob is downloaded.
- Separate outboards leave original payload usable as-is.
- Length exposure and EOF have an explicit cryptographic contract.

## Weaknesses

- Frame length is not immediately trustworthy.
- Range verification includes aligned surrounding bytes and proof traffic.
- Correct payload decoding does not enforce canonical transport termination.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                        | Trade-off                                                  |
| ------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------- |
| Derive traversal from geometry              | Avoid per-record tags and offsets                | Claimed length controls parsing before it is authenticated |
| Validate final chunk before exposing length | Bind observable EOF to original content          | End-relative operations may require extra verification I/O |
| Permit transport trailing bytes             | Compose decoders without requiring transport EOF | Outer frame exactness must be checked separately           |
| iroh chunk groups                           | Reduce proof and I/O overhead                    | Fine byte ranges overfetch data                            |

## Sources

- [Bao specification][spec] and [vectors][vectors] — frame and decoder contract.
- [iroh protocol][protocol] and [bao-tree source][tree] — range/profile boundary.
- [Existing Bao content-addressing research][ca] — complementary hash/tree details.

<!-- References -->

[iroh]: https://github.com/n0-computer/iroh-blobs/tree/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc
[protocol]: https://github.com/n0-computer/iroh-blobs/blob/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc/src/protocol.rs
[tree]: https://github.com/n0-computer/bao-tree/tree/2be9abd144783455606424424c29bd3a57f926f8
[bao]: https://github.com/oconnor663/bao/tree/3466bb34287f10f746d29d899d92429b81cf4302
[spec]: https://github.com/oconnor663/bao/blob/3466bb34287f10f746d29d899d92429b81cf4302/docs/spec.md
[vectors]: https://github.com/oconnor663/bao/blob/3466bb34287f10f746d29d899d92429b81cf4302/tests/test_vectors.json
[ca]: ../content-addressing/bao-blake3.md
[ca-concepts]: ../content-addressing/concepts.md
[ca-recommendations]: ../content-addressing/recommendations.md
[iroh-survey]: ../iroh/blobs.md
