# BitTorrent v2 (protocol / Python reference creator)

Canonical bencoded metadata binds per-file Merkle roots, while length-prefixed peer messages transport aligned blocks and hash proofs.

| Field            | Value                                                                                |
| ---------------- | ------------------------------------------------------------------------------------ |
| Language         | Protocol-independent; Python reference metadata generator                            |
| License          | BEP 52: public domain; the example generator embeds a separately attributed bencoder |
| Repository       | [bittorrent/bittorrent.org][repo]                                                    |
| Documentation    | [BEP 52][bep]                                                                        |
| Category         | Self-delimiting metadata plus authenticated block distribution                       |
| D bindings       | No D binding surveyed; the inline probe is an independent frame recognizer           |
| Version boundary | `meta version = 2`; SHA2-256 file trees and infohash                                 |

## Overview

### What it solves

BitTorrent v2 separates the identity of an individual file from the arrangement
of a torrent containing it. Per-file roots allow content verification without
making file identity depend on neighbouring files, while metadata authenticates
names, lengths and the selected piece geometry. The distribution protocol then
requests data and proof hashes independently. This is neither one flat binary
record nor one monolithic hash over all downloaded bytes. [BEP 52][bep]

### Design philosophy

[BEP 52's infohash section][bep] states an unusually important parsing rule:

> They must not perform a decode-encode roundtrip on invalid data.

The hash input is the exact `info` substring of the metainfo file. A normalized
re-encoding is equivalent only after strict validation. The same specification
requires checking `piece layers` outside `info` against the roots inside it:
placement outside the directly hashed region is not permission to trust them.

## How it works

### Schema source of truth

[BEP 52][bep] defines bencoding, metainfo fields, file trees, hash geometry and
peer messages. Its [reference generator][creator] supplies executable evidence
for encoding and root construction, but is not a normative hostile-input
validator. `info` contains `name`, `piece length`, `meta version` and `file tree`.
An empty-string key in the latter introduces file properties, including `length`
and, for non-empty files, `pieces root`.

The schema is a protocol document plus conventional dictionary keys. There is
no IDL that proves a host struct's offsets. Metadata parsing and peer-frame
parsing are separate codecs with separate length rules. [BEP 52][bep]

### Wire encoding

Bencoding has four forms: arbitrary byte strings as decimal length, colon and
bytes; integers between `i` and `e`; lists between `l` and `e`; and dictionaries
between `d` and `e`. Dictionaries contain alternating byte-string keys and
values, sorted by raw key bytes. Strings are not inherently Unicode. [BEP 52][bep]

Local reference-tool probe, executed against the [pinned generator][creator]:

```bash
PYTHONPATH="$REPOS/beps/beps" python3 -c 'import bep_0052_torrent_creator as b; print(b.encode({b"z": b"abc", b"a": 3}).hex()); print(b.decode(b"i03e")); print(b.decode(b"4:abc"))'
```

Observed output:

```text
64313a61693365313a7a333a61626365
3
b'abc'
```

The encoded string is `d1:ai3e1:z3:abce`: sorting happens before emission.
The last two outputs expose limitations of the example decoder: it accepts an
integer with a forbidden leading zero and a three-byte string claiming four
bytes. This is **observed reference-generator permissiveness**, not a relaxation
of BEP 52. Its `decode_first` uses an integer regex and slicing without an exact
string-extent check. [Generator source][creator]

Peer traffic uses another grammar: a handshake begins with one-byte `19`,
`BitTorrent protocol`, eight reserved bytes, a 20-byte truncated infohash and a
20-byte peer ID. Subsequent messages have four-byte big-endian lengths; zero
means keepalive, otherwise the first payload byte is the message ID. A `request`
has ID `6` followed by three four-byte values: piece index, begin and length.
The length prefix covers ID plus payload, not its own four bytes. [BEP 52][bep]

### Access model

Metainfo is sequentially parsed, though a reader can retain the original `info`
byte interval for hashing. Download addressing is by piece index and byte offset,
not by offsets into a serialized host object. Non-empty files start at piece
boundaries in dictionary traversal order; a short last piece creates a gap before
the next file. A piece address is therefore not simply an offset into densely
concatenated file bytes. [BEP 52][bep]

Verification can operate on 16 KiB blocks once the corresponding leaf hashes
have been authenticated. Piece availability remains expressed at the coarser
`piece length`. Hash requests can retrieve leaf or piece layers and enough
ancestor hashes to connect them to the known file root. An arbitrary requested
byte range is not itself a proof unit: it needs its enclosing hashed blocks.
[BEP 52][bep]

### Variable-length and optional data

Decimal string lengths count **bytes**; list and dictionary termination uses
sentinels rather than element counts. The grammar's mathematically unbounded
integers do not authorize unbounded machine allocations. `pieces root` is
omitted for empty files. `piece layers` maps binary roots to concatenated binary
hashes for files larger than a piece, excluding hashes used exclusively for
padding beyond EOF. [BEP 52][bep]

In hash messages the fixed fields determine the interpretation of the trailing
hash sequence. `hash request` carries a 32-byte root and four four-byte fields:
base layer, index, length and proof layers. Thus its payload is 48 bytes and its
message length, including ID `21`, is 49. This is **field-width arithmetic from
the specification**, not a captured frame. [BEP 52][bep]

### Evolution and compatibility

`meta version` is an explicit incompatible-version boundary and must be checked
before other validation can obscure an unsupported-version diagnosis. Hybrid
torrents include both v1 and v2 fields in `info`, with padding files providing
the same piece alignment for v1. A dual-mode client must validate equivalent
names, ordering and alignment, then check downloaded pieces against both hash
formats or abandon one mode on inconsistency. [BEP 52][bep]

The v2 infohash is 32 bytes, but tracker/handshake uses truncate it to 20 bytes
for specified purposes. Those widths must not leak into the file-root parser:
`pieces root` remains a full SHA2-256 value. [BEP 52][bep]

### Determinism and canonical form

Dictionary keys have raw-byte order; integer encodings forbid negative zero and
leading zeroes. The exact `info` bytes are hashed. A permissive decoder that
silently collapses malformed encodings can produce a different identity when
serializing the parsed value. Preserve and hash the original span, or reject
noncanonical input before a decode/encode path. The local probe demonstrates why
an example codec is insufficient evidence of canonical validation. [BEP 52][bep], [creator][creator]

Canonical metadata does not mean every field is included in the same digest.
`announce` and `piece layers` sit outside `info`. The latter receives indirect
integrity through recomputation against authenticated file roots, while tracker
location is not covered by the infohash. [BEP 52][bep]

### Merkleization and content addressing

Each non-empty file has a binary SHA2-256 tree over 16 KiB blocks. The final
block is hashed at its actual length; it is not zero-filled to 16 KiB. Missing
leaves needed to balance the tree are **32 zero bytes**, not the digest of a
zero-filled data block. Internal hashes are SHA2-256 of concatenated child
hashes. The [generator's `FileHasher` and `root_hash`][creator] show these cases
and the different padding needed for files smaller than a piece.

Unlike [CT][ct], these leaf and internal hashes have no explicit `0x00`/`0x01`
domain-separation prefixes. Interpretation relies on the authenticated geometry
and file length in `info`; it is incorrect to transplant CT's hash formula or
treat a root alone as a fully typed, self-describing file description. The
infohash commits to that metadata; neither it nor the file root is a publisher
signature. Authentic selection of the expected torrent remains an external
trust decision. [BEP 52][bep]

### Hostile-input safety

Validate decimal overflow, recursion depth, total tokens, string extents and
dictionary ordering before allocating or normalizing. Reject unsafe output
paths independently: BEP 52 explicitly discusses invalid UTF-8, reserved names,
`.` and `..`, and sanitizing after relevant normalization. Cryptographically
valid metadata can still name dangerous filesystem paths. [BEP 52][bep]

Hash requests require index to be a multiple of length, length to be a power of
two at least two, and recommend a maximum of 512 hashes. A `hashes` response must
correlate with a request. Check tree-layer arithmetic and expected proof count
before accepting trailing hashes; proof layers already implied by a requested
subtree are omitted on wire but still counted in the requested layer number.
Unsolicited piece messages require connection closure. [BEP 52][bep]

The generator probe's accepted `4:abc` is a concrete negative oracle for a new
parser: a safe exact-length implementation must not imitate it. Its acceptance
does not constitute an exploit assessment of production torrent clients.

### Describing foreign formats

BitTorrent wraps foreign **payload bytes**, not foreign layouts. Bencoding can
represent arbitrary nested dictionaries, but cannot declaratively describe an
existing packed record's offsets or byte order. A [Flat-style reader][flat]
could describe fixed parts of peer frames, while decimal bencoding and proof
semantics require a stream parser and verifier outside the layout proof.

### Implementation and performance evidence

The local Python probe executed encoding and two malformed decoding cases at
the pinned source revision. The [reference generator][creator] also exposes
block reads, SHA2-256 leaf hashing and pairwise root reduction for inspection.
No swarm was contacted, no peer frame was captured, and no production client
was benchmarked. The reproducible command is not registered in repository CI.

The structural costs are nevertheless concrete: one leaf hash per 16 KiB block,
32 bytes per transmitted hash, and aligned power-of-two hash requests.
These are format parameters, not measured throughput or an assertion that all
clients use identical caching strategies. [BEP 52][bep]

#### CI-verified independent framing probe

This small independent recognizer checks one exact bencoded byte-string frame,
including decimal overflow, canonical prefix spelling and truncation. It is not
a bencoding codec, torrent validator or upstream-tool execution. The malformed
`4:abc` accepted by the example tool above is rejected here.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "binary_bep_string_probe"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln;

bool exactStringFrame(in char[] frame) @safe pure nothrow @nogc
{
    size_t count;
    size_t pos;
    while (pos < frame.length && frame[pos] >= '0' && frame[pos] <= '9')
    {
        if (pos > 0 && frame[0] == '0')
            return false;
        const digit = cast(size_t) (frame[pos] - '0');
        if (count > (size_t.max - digit) / 10)
            return false;
        count = count * 10 + digit;
        ++pos;
    }
    return pos > 0 && pos < frame.length && frame[pos] == ':'
        && count == frame.length - pos - 1;
}

void main() @safe
{
    assert(exactStringFrame("3:abc"));
    assert(exactStringFrame("0:"));
    assert(exactStringFrame("3:a\0b"));
    assert(!exactStringFrame("4:abc"));
    assert(!exactStringFrame("03:abc"));
    assert(!exactStringFrame("3:abcd"));
    assert(!exactStringFrame("999999999999999999999999999999999999:"));
    writeln("accepted: 3 exact byte-string frames");
    writeln("rejected: truncation, leading zero, trailing byte, length overflow");
}
```

```ansi
accepted: 3 exact byte-string frames
rejected: truncation, leading zero, trailing byte, length overflow
```

## Strengths

- File roots survive changes to torrent grouping and piece length.
- Exact hash-input and canonical parsing requirements are explicit.
- Piece layers can be distributed outside directly hashed metadata and checked
  against roots, avoiding a second metadata identity for every transport choice.
- Hybrid compatibility has explicit content-equivalence obligations.

## Weaknesses

- Bencoding's small grammar still needs strict length, ordering and resource checks.
- Transport message length, file length, piece geometry and proof counts are
  distinct quantities a parser must not conflate.
- Roots lack explicit leaf/internal prefix separation; context must retain geometry.
- A trusted digest is not a signature, and neither prevents path traversal.

## Key design decisions and trade-offs

| Decision                           | Rationale                                             | Trade-off                                                   |
| ---------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------- |
| Hash exact `info` bytes            | Make torrent identity reproducible                    | Permissive decode/encode can change identity                |
| Per-file Merkle roots              | Reuse file identity across collections                | File ordering and download addresses need separate metadata |
| Piece layers outside `info`        | Deliver hash material without embedding the full tree | Every supplied layer must be checked against roots          |
| Power-of-two aligned hash requests | Bound proof shape and uncle hashes                    | Small arbitrary ranges need alignment and additional hashes |
| Hybrid v1/v2 metadata              | Reuse storage across swarms                           | Both identities and alignment claims must be checked        |

## Sources

- [BEP 52][bep] — normative byte grammar, canonicalization, trees and peer frames.
- [Reference torrent creator][creator] — executed bencoding probe; source-level tree evidence.
- [Flat draft][flat] — reader scope used only for design contrast, not claimed implementation.

<!-- References -->

[repo]: https://github.com/bittorrent/bittorrent.org/tree/7b7b41f46d57ff1d1cb1e24ed6e9bacfbf958c06
[bep]: https://github.com/bittorrent/bittorrent.org/blob/7b7b41f46d57ff1d1cb1e24ed6e9bacfbf958c06/beps/bep_0052.rst
[creator]: https://github.com/bittorrent/bittorrent.org/blob/7b7b41f46d57ff1d1cb1e24ed6e9bacfbf958c06/beps/bep_0052_torrent_creator.py
[ct]: ./certificate-transparency.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
